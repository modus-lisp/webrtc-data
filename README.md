# webrtc-data

A **from-scratch WebRTC data-channel peer in pure Common Lisp** — so a browser (or aiortc) can
open an `RTCDataChannel` straight to your Lisp with no plugins, no Tor, no signaling service
beyond one HTTP POST. Data channels only (no SRTP, no video codec) — hence the honest name.

It exists to carry [glass](https://github.com/modus-lisp/glass) — a pure-CL VNC/RFB server — to
a bare browser (iPhone Safari included) as a **remote desktop**, P2P and NAT-traversing. The
transport is written from scratch; the browser reuses [noVNC](https://github.com/novnc/noVNC)
(vendored, with an added TRLE decoder) and the server reuses glass, so webrtc-data is a
transparent RFB pipe over its own ICE/DTLS/SCTP.

Clean-room, and **verified against a spec-compliant peer at every layer** — aiortc/aioice for
the protocol, pynacl for the crypto, then a real headless browser end to end. The NAT-traversal
arms are each proven by an A/B network-namespace rig (see below).

## The stack

```
   browser  ──  RTCDataChannel  ──▶  glass (RFB desktop)
      │                                  ▲
      ▼   SDP offer/answer (1 HTTP POST) │  transparent RFB byte-pipe
   ┌──────────────────────────────────────────────┐
   │  SDP  ·  ICE/STUN/TURN · DTLS 1.2 · SCTP·DCEP │   ← all pure CL, this repo
   └──────────────────────────────────────────────┘
```

| Layer | What we do | Verified by |
|---|---|---|
| **SDP** | parse the data-channel offer, generate the answer | round-trips real aiortc offers |
| **STUN** | messages + MESSAGE-INTEGRITY (HMAC-SHA1) + FINGERPRINT (CRC32) | **aioice** validates our Binding Request byte-for-byte |
| **ICE** | full agent: host + srflx (STUN) + relay (TURN) candidates, sends its own connectivity checks | aiortc → `iceConnectionState: completed`; NAT rigs (below) |
| **TURN** | client: Allocate + long-term auth, CreatePermission, ChannelBind/ChannelData, Refresh | works against any RFC 5766/8656 server; turn-rig relays a real session |
| **DTLS 1.2** | client handshake, ECDHE + AES-128-GCM, X25519, **ECDSA P-256** self-signed cert, mutual auth | aiortc → `connectionState: connected` |
| **SCTP + DCEP** | reliable, flow-controlled association (responder) + data channels | aiortc fires `datachannel.onopen`; echo round-trips |
| **glass demo** | RFB framebuffer + input over the channel, ZRLE + **TRLE** encodings | headless Chromium: renders **and** keystrokes reach the shell |

DTLS 1.2 lives in [seal](https://github.com/modus-lisp/seal) (already a TLS 1.2/1.3 client — DTLS
reuses its PRF, key schedule, AES-GCM, X25519 and cert parsing, adding only the record/flight/
cookie layer + client-cert auth). seal is now a **TLS + DTLS** library, and its AES-GCM is
table-based (below).

## NAT traversal — the full ladder

The peer is a full ICE agent, not ICE-lite: it gathers every candidate type and **sends its own
connectivity checks**. Each rung is proven by an isolated A/B rig under `demo/` — same code, NAT
character varied, one arm connects and the control arm provably doesn't.

| NAT between the peers | Candidate that carries it | Proof |
|---|---|---|
| none (LAN / public host) | **host** | M3 echo + glass demo |
| full-cone | **srflx** (STUN, `$STUN_SERVER`) | reachable once the mapping exists |
| address/port-restricted cone | srflx **+ our outbound checks** open the mapping | `demo/nat-rig` — full-agent CONNECTED vs ice-lite NO CONNECT through a MASQUERADE NAT |
| symmetric | **relay** (TURN, `$TURN_SERVER/USER/PASS`) | `demo/turn-rig` — relay CONNECTED vs srflx-only NO CONNECT |

`ice-start-checks` is the difference between the second and third rows: a restricted NAT drops the
peer's checks to our public mapping until *we* have sent toward the peer, so an ICE-lite responder
that only answers checks never connects. Both rigs are rootless (`unshare -Umrn` network
namespaces, veth + `iptables`/`nft` MASQUERADE — no Docker, no real root) and print a result line
per arm; see their READMEs for topology and observed output.

Turning traversal on is opt-in, one round-trip each: `GATHER_SRFLX=1` for srflx + checks,
`TURN_SERVER=… TURN_USER=… TURN_PASS=…` to additionally Allocate a relay. Off by default (LAN
needs neither). Any standard TURN server works — run your own (coturn) or use a provider.

## Reliable transport, with monitoring

The SCTP layer is a real reliable transport, not a toy responder: congestion + flow control
(cwnd slow-start/avoidance, peer `rwnd`), inbound SACK handling, RTO + fast retransmit (RTO from
RTT per RFC 6298), in-order delivery with an out-of-order buffer and gap-ack SACKs, and
peer-death detection.

- **Loss resilience** — with `*sctp-drop-rate*` set to 0.15 (15 % of outbound packets dropped),
  the glass desktop still renders **completely**; retransmission recovers. The prior "blast and
  hope" version wedged to a blank screen under the same loss. `demo/netsim/` conditions the link
  (netem loss/delay/reorder/rate) to reproduce this on demand.
- **Handshake under loss** — the DTLS flight layer coalesces and backs off exponentially, so an
  *awful* link (15 % loss + reorder) that never completed a handshake before now connects.
- **Performance** — `sctp-stats` exposes counters + live window state; the demo shows a live HUD
  (real rendered FPS, throughput, backpressure). On localhost the transport tracks the source
  1:1 with **zero buffered bytes and 0 % retransmit** — FPS is bounded by glass's 60 Hz render,
  not the pipe.

## Fast crypto

The DTLS session crypto was the throughput ceiling; both halves are now fixed, and both live in
seal so **every** seal TLS/DTLS user benefits.

- **Table-based AES-GCM** — GHASH via Shoup's 4-bit table and AES via T-tables (Te0–Te3) replaced
  the bitwise GF multiply that was ~78 % of per-byte cost. **~72× faster** GCM (to ~22 MB/s),
  which lifted the demo transport from ~250 KB/s to ~3 MB/s. All 44 seal crypto vectors still pass.
- **ECDSA P-256 cert** — the DTLS identity is a self-signed ECDSA P-256 cert (SEC 1 signing,
  `ecdsa_secp256r1_sha256` CertificateVerify) instead of RSA-2048: **289 B vs ~800 B** on the
  wire and **~2.6 ms vs ~545 ms** to generate — ~540 ms shaved off every new session.

## A cl-transport backend

webrtc-data is also a [cl-transport](https://github.com/modus-lisp/cl-transport) provider: loading
the optional `webrtc-data/transport` system registers a **`:webrtc` inbound (EXPOSE) backend**, so
any modus-lisp code can accept WebRTC data-channel connections through the same uniform interface
as `:tcp` (built in) and `:frp` (via cl-frpc) — and never branch on how the bytes arrive:

```lisp
(ql:quickload "webrtc-data/transport")   ; registers :webrtc; core webrtc-data has no cl-transport dep

(cl-transport:expose
  (lambda (stream peer)                  ; called once per inbound data channel
    (loop for n = (read-sequence buf stream) while (plusp n)
          do (write-sequence buf stream :end n) (force-output stream)))
  :backend :webrtc :signal-port 8766)    ; peers POST their SDP offer to /signal
```

`stream` is a Gray binary stream (`(unsigned-byte 8)`) over the SCTP data channel: inbound
messages are concatenated into a blocking byte stream, outbound writes are buffered and flushed as
chunked SCTP messages on `force-output` — read/write it exactly like a TCP socket. cl-transport
and hunchentoot stay out of core webrtc-data's dependencies; only this integration system pulls
them in, mirroring how cl-frpc provides `:frp`. Verified with an aiortc peer echoing bytes straight
through `cl-transport:expose`.

## Quick start

```lisp
;; deps: ironclad, bordeaux-threads, sb-bsd-sockets, and seal (all in the modus-lisp dist)
(ql:quickload "webrtc-data")
```

Run the remote-desktop demo (`demo/glass-webrtc/`):

1. Start a glass RFB server on :5900 — e.g. `(glass-term:run :port 5900)`.
2. `sbcl --load demo/glass-webrtc/gateway.lisp` (hunchentoot serves the page + one `POST /signal`;
   noVNC is vendored under `demo/glass-webrtc/novnc/`, or point `NOVNC_DIR` at your own 1.7+ checkout).
3. Open `http://<host>:8765/` in any browser. noVNC rides the data channel directly —
   `new RFB(el, dataChannel)`, no shim. See `demo/glass-webrtc/README.md`.

For traversal across NATs, set `GATHER_SRFLX=1` (and `TURN_SERVER/USER/PASS` for symmetric NAT)
in the gateway's environment.

## API sketch

```lisp
(make-ice &key local-ip)                             ; -> ice-agent
(webrtc-dtls-setup agent &key remote-fingerprint)    ; -> dtls-conn; put its fingerprint in the answer
(ice-answer agent offer &key fingerprint gather-srflx gather-relay)  ; -> answer SDP (gathers candidates)
(ice-serve agent)                                    ; start the UDP read loop
(ice-start-checks agent)                             ; full-agent: punch our NAT mapping toward the peer
(webrtc-dtls-run  conn)                              ; drive the DTLS client handshake
(webrtc-serve-datachannel conn &key on-message on-ready duration)  ; run SCTP+DCEP; bridge on :on-ready
(sctp-send-string / sctp-send-binary assoc stream-id data)         ; push
(sctp-stats assoc)                                   ; -> plist of counters + window health
```

## Scope (honestly)

Implemented: data channels over a single ordered/reliable SCTP stream, and the full ICE
NAT-traversal ladder (host / srflx / full-agent checks / TURN relay). **Not** implemented (and
not needed for this use): SRTP / audio-video media, SCTP fragmentation & PR-SCTP / FORWARD-TSN,
RE-CONFIG, multihoming; we act as the DTLS client / ICE responder (the browser or aiortc is the
offerer). Under *brutal* packet loss (~15 %) recovery has occasional multi-second RTO hitches —
correctness is always preserved; normal loss doesn't trigger them.

## Credits

Built on the [modus-lisp](https://github.com/modus-lisp) pure-CL stack — **seal** (TLS/DTLS +
crypto) and **glass** (RFB desktop). Browser side is **noVNC**. Verified against **aiortc** /
**aioice** / **pynacl** as reference peers.

MIT.
