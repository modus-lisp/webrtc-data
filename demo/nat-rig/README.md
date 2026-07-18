# NAT-traversal test rig — proving webrtc-data's full-agent ICE

An A/B proof that `webrtc-data`'s **full-agent ICE** (sending its own STUN connectivity checks,
`ice-start-checks` in `src/ice.lisp`) lets a peer connect through a restricted NAT, where
**ICE-lite alone fails**. The code is already written — this rig only demonstrates it.

## The claim

`webrtc-data` is an ICE-lite responder that can optionally act as a full agent:

- it gathers a **server-reflexive** (STUN) candidate — its public NAT mapping — and advertises it;
- **new:** it also **sends** STUN connectivity checks toward the peer's candidates
  (`ice-start-checks`). Those outbound checks punch the local NAT mapping open toward the peer.

Behind a restricted NAT (admits inbound only from addresses we've sent to):

- **ICE-lite (no checks):** the peer's checks to our public mapping are **dropped** — we never
  sent to the peer, so the NAT never opened toward it. **No connection.**
- **Full-agent (checks on):** our checks to the peer's address open the mapping, so the peer's
  checks now get in. **Connection.**

## Topology (rootless — no Docker, no real root)

`unshare -Umrn` gives a user namespace with `CAP_NET_ADMIN` over its own network namespace.
Sibling netns are held open by keeper processes (`unshare -n sleep … & PID=$!`); veth ends are
moved with `ip link set … netns $PID` and driven via `nsenter -t $PID -n …` (named `ip netns`
won't work — `/run/netns` isn't writable here).

```
  S (answerer, behind NAT)         R (router: MASQUERADE)            P (public side)
  10.1.0.2/24 ─ veth ─ 10.1.0.1 │ 10.0.0.1 ─ veth ─ 10.0.0.2  STUN server (distinct IP)
  default via 10.1.0.1           ip_forward=1, SNAT              10.0.0.3  aiortc peer (distinct IP)
                                 -s 10.1.0.0/24 -j MASQUERADE
```

**Rootless MASQUERADE:** `iptables -t nat -A POSTROUTING -s 10.1.0.0/24 -o veth-rp -j MASQUERADE`
inside R's netns (as mapped-root with CAP_NET_ADMIN). `sysctl -w net.ipv4.ip_forward=1` is
per-netns and writable. The runner falls back to an `nft` masquerade rule if `iptables` fails.

**Two distinct public IPs (critical):** S learns its public mapping by querying the STUN server at
`10.0.0.2`. A restricted NAT then only admits inbound from `10.0.0.2`. The peer is at a *different*
address, `10.0.0.3` — one S never sent to under ICE-lite — so ICE-lite is correctly blocked, and
only the full-agent checks (S → `10.0.0.3`) open the mapping.

## Components

- **`stun-server.py`** — ~40-line UDP STUN Binding server. Replies to a Binding request
  (`0x0001`, magic cookie `0x2112A442`) with a Binding Success carrying XOR-MAPPED-ADDRESS
  (RFC 5389). Bound to `10.0.0.2:3478`.
- **`answerer.lisp`** — the `webrtc-data` answerer in S. Env `RIG_MODE` selects the arm:
  - `full` — `ice-answer … :gather-srflx t` **and** `ice-start-checks` (full agent).
  - `lite` — `:gather-srflx t` but **no** checks. Advertises the public mapping so the peer has a
    real target; the only thing missing vs. `full` is the checks. This is the clean isolation.
  - `hostonly` — `:gather-srflx nil`, no checks (the literal ICE-lite: host candidate only).
- **`peer.py`** — aiortc offerer at `10.0.0.3`, `RTCIceServer(urls="stun:10.0.0.2:3478")`.
  Creates a data channel, writes `offer.sdp`, waits for `answer.sdp`, reports CONNECTED (exit 0)
  or NO CONNECT (exit 2) within 25s.
- **Signaling = shared files** (`offer.sdp` / `answer.sdp` on a shared tmpdir) — not HTTP, since
  the gateway would be unreachable behind the NAT.

## Run

```bash
./run.sh
```

It builds the topology once, runs a sanity probe, then runs the answerer in all three modes and
prints a result line per arm. Logs + per-arm SDPs land in a `/tmp/nat-rig.XXXXXX` dir.

## Observed result

```
=== sanity probe ===
S -> 10.0.0.2 (STUN IP,  through NAT): OK
S -> 10.0.0.3 (peer IP,  through NAT): OK
P(10.0.0.3) -> 10.1.0.2 (S private, unsolicited inbound): BLOCKED   ← NAT genuinely restricts

@@ full-agent: CONNECTED
@@ ice-lite:   NO CONNECT (blocked by NAT)
@@ host-only:  NO CONNECT (unroutable private candidate)
```

- **full:** answerer gathers srflx `10.0.0.1:P`, runs `ice-start-checks` toward 4 peer candidates,
  DTLS handshake completes, aiortc reports datachannel OPEN → **CONNECTED**.
- **lite:** answerer advertises the *same kind of* srflx `10.0.0.1:P`, but sends no checks; aiortc
  stalls in ICE `checking` and times out → **NO CONNECT**. The peer had our public mapping to aim
  at — the only missing ingredient was the outbound checks.
- **hostonly:** answerer advertises only its private `10.1.0.2` host candidate → **NO CONNECT**.

## NAT character (caveat)

Linux `MASQUERADE` here is **endpoint-independent mapping (cone) with address-restricted
filtering** ("restricted-cone"). A probe (one S socket → two public dests) confirmed both
destinations observed the **same** public port `10.0.0.1:45000`, so the srflx S learns from the
STUN server is exactly the mapping the peer reaches — which is why full-agent checks work. The
*filtering* is restrictive (unsolicited inbound from `10.0.0.3` is dropped until S sends there),
which is why ICE-lite fails. A **symmetric** NAT (per-destination port) would break full-agent too
and require TURN — out of scope for this rig, but noted.
