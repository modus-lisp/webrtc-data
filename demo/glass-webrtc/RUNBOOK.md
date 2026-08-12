# glass over WebRTC — how it works, and how to stand it up

`DEPLOY.md` covers publishing the web client. This covers everything else: what the pieces
are, how a phone reaches a desktop, and what someone starting from an empty machine has to do.

**`README.md` in this directory is stale** — it documents the retired `gateway.lisp` (hunchentoot,
`POST /signal`, port 8765). That path still works and is the shortest way to see the system run
locally (see "The short path"), but it is not what serves the live desktop.

---

## 1. The shape of it

Two long-lived processes, and no inbound port on either.

```
gw-keepalive.sh                       supervisor: re-sources config, respawns forever
  └─ sbcl … gateway-nostr.lisp        signalling + WebRTC + encode.  NO listening TCP port.
       ├─ out: wss to 3 Nostr relays          (signalling)
       ├─ out: UDP to STUN, and to coturn     (media)
       └─ out: TCP to the desktop  :5903 RFB (twice) · :5913 audio · :5914 mic

sbcl … desktop-5903.lisp              the glass desktop.  NOT supervised by anything.
       ├─ 0.0.0.0:5903    RFB
       ├─ 127.0.0.1:5913  session audio mix out
       └─ 127.0.0.1:5914  peer microphone in
```

The browser is served as a static page from an **nsite** gateway (Nostr + Blossom), so there is no
web server either. The consequence worth internalising: **nothing here needs a port forwarded, a
DNS record, or a TLS certificate.** The only public infrastructure is a TURN server, and that is
only needed for clients behind symmetric NAT (i.e. cellular).

---

## 2. Signalling and the DM bot

Everything — signalling *and* administration — rides **NIP-59 gift wrap (kind 1059)**. There is no
NIP-04 anywhere. The gateway subscribes to `kinds:(1059) #p:(box-pubkey)` and unwraps with
`cl-nostr.nip59:unwrap-giftwrap`, which yields the **verified seal signer** — a forged rumour pubkey
is rejected before the gateway sees it.

Relays default to `relay.damus.io`, `nos.lol`, `relay.primal.net` (`NOSTR_RELAYS` overrides). Fan-out
means one offer arrives three or more times; duplicates are dropped by wrap event id.

### Commands

A DM is treated as a command only if it is a string of **≤80 characters**. Four exist:

| command | effect | who |
|---|---|---|
| `link` | mint a token, reply with a full magic link | allowlist or enrolled device |
| `devices` | list enrolled terminals with expiries | allowlist only |
| `revoke <prefix\|all>` | drop an enrolment | allowlist only |
| `help` / `?` | usage | allowlist or device |

A denied command produces **no reply at all**, only a local log line. That silence is why the browser
has its own fallback (below).

### Three ways in

Checked in this order, and **the first match wins**:

1. **code** — a valid unexpired login token in the offer envelope. Valid for its own TTL.
2. **allowlist** — `NOSTR_ALLOW`. Permanent.
3. **device** — a browser enrolled after arriving on a valid code. `DEVICE_TTL`, default 24 h,
   **renewed on every connection**, persisted to `.glass-devices`.

Note that a code authorises *independently of the allowlist*, and that any admitted connection enrols
the caller as a device. One leaked link is therefore durable access until someone runs `revoke`.

`NOSTR_ALLOW` accepts npub, 64-hex, or a NIP-05 `name@domain` — the last resolved over HTTP **once, at
gateway start**, inside `ignore-errors`. A transient DNS failure at that moment yields an empty
allowlist and a gateway that starts anyway. Prefer a raw npub.

### The login link

```
<LOGIN_URL_BASE>#box=<box-npub>&code=<nonce>.<exp>.<mac>
mac = HMAC-SHA256(box-secret, "glass-login|" nonce "|" exp)
```

The box npub and code live in the `#fragment`, which an nsite gateway never receives.

**Codes are reusable until they expire** — there is no spent-nonce set. (`login-token.lisp`'s header
claims single-use is enforced by the gateway. It is not; the gateway's own comment is the truth.)

Every successful answer carries a *fresh* token back, stored in `localStorage`, so an active terminal
never needs a new link.

TTLs disagree between call sites: 900 s from the CLI, 1800 s (`LINK_TTL`) for the `link` DM.

### Message formats

```
offer  phone → box   {"sdp": "<full non-trickle SDP>", "code": "<token>"}
answer box → phone   {"sdp": …, "ufrag": "<the OFFER's ice-ufrag>", "code": "<renewed token>"}
```

Signalling is **one-shot and non-trickle**: the browser gathers fully (capped at 10 s) and publishes
once. There is no renegotiation path anywhere in the system — which is why the microphone transceiver
is added up-front with no track and filled in later via `replaceTrack()`.

Duplicate copies of one offer are answered with the *identical cached answer*, keyed on ICE ufrag.
This is load-bearing: retiring the session on each copy would kill the very agent the phone is
checking against.

---

## 3. The connection

**ICE.** The box advertises ICE-lite but runs full outbound checks anyway — the point is hole
punching, not nomination. `ICE_LOCAL_IP` overrides host-candidate detection.

**TURN.** Needed for cellular. The gateway Allocates over the same ICE socket, then issues
`CreatePermission` **once per unique peer IP** — per-candidate meant ~132 blocking round trips on a
cellular offer carrying 66 candidates. `ChannelBind` is deferred to a background thread so the receive
loop cannot deadlock on its own response. `TURN_RELAY_PEER` pre-permits the address coturn sees the
phone's relayed packets arriving from; without it the first relayed check is dropped. On teardown the
allocation is released with `Refresh lifetime 0`, or it lingers ~600 s and a small port range
exhausts.

**Demux.** One UDP socket carries everything: TURN ChannelData and Data indications are stripped
first, then RFC 5764 first-byte demux splits SRTP (128–191) from DTLS (20–63). Every inbound datagram
stamps a receive time, which powers a 30 s consent timeout.

**Data channels.** Three, of which the third is off by default:

| channel | stream | negotiation | carries |
|---|---|---|---|
| `rfb` | 0 | DCEP | raw RFB, binary. noVNC takes the `RTCDataChannel` as its transport directly |
| `control` | 100 | `negotiated: true` | flat JSON |
| `warp` | 102 | `negotiated: true` | warp delta frames — the enrolled-terminal list (§7) |

Control messages: `{"kbps":N}` to change rung, `{"get":1}` to poll, `{"request":"keyframe"}` when the
decoder is stranded. **The box answers every control message with full state**, which the client
exploits as an application-level heartbeat (~18 B/s).

A negotiated channel has **no DCEP handshake**, so creating one costs nothing and the box cannot be
told it exists — it learns by receiving a message on that stream. Both `control` and `warp` work that
way, which is why an unused channel is indistinguishable from an absent one.

A session ends at 1 hour, or after 30 s of peer silence, whichever comes first.

---

## 4. Media

**Capture** is a *second, independent* RFB client to the same desktop. It keeps Y/U/V 4:2:0 planes and
converts only the rectangles glass reports as changed; CopyRect becomes a plane-internal move, so a
window drag costs 4 bytes. Per-macroblock dirty bits come straight from RFB — the encoder never
rescans for damage. Resolution follows damage via a scale divisor restricted to {1,2,4}, because a
macroblock must divide into whole scaled pixels or damage tracking stops being exact.

**Encoding** reuses the audio's SRTP context with its own SSRC. The VP8 payload type is echoed from
the browser's offer, since it is dynamic. Three deliberately separate clocks: screen sampled, frame
encoded, packets paced. They used to be one, which is why lowering the bitrate also lowered the
capture rate.

**The ladder** (`video-profiles.lisp`) is seven rungs a factor of 3 apart —
`5 16 48 160 480 1600 4800` kbps — and **every encoder knob is derived from that one number**:
quantizer, keyframe interval, frame budget, target fps. The constants are measured against this
encoder, not modelled. Target fps caps at 12 even at the top rung, because whole-screen frames take
240–290 ms to encode and asking for more only divides the frame budget.

Changing rungs mid-session is a variable the sender re-reads each pass: no reconnect, no black frame.

**`VIDEO_PRIMARY`** puts a `<video>` element over the desktop and has the gateway **swallow the
browser's FramebufferUpdateRequest**, so glass never sends pixels down SCTP. Without that, both paths
carry the same screen and compete for bandwidth. The noVNC canvas is kept at `opacity:0` because
input still rides the data channel and the virtual trackpad maps touches through it.

There is **no RTCP anywhere** — no PLI, no receiver reports. A stranded decoder recovers only via the
control channel's keyframe request or the blind periodic resync.

---

## 5. Audio, microphone, clipboard

**Audio out.** The mix belongs to the *desktop*, not the gateway — a mixer in the gateway could only
carry what the gateway itself played. glass serves it on TCP `:5913`: a one-line ASCII header, then
raw s16le frames. One connection per session means one subscription, so each phone gets its own cursor
into the mix and neither advances the other's. To the browser it is **G.711 PCMU, 8 kHz mono, 20 ms**,
as SRTP over the same transport — not a data channel.

**Microphone in.** Inbound SRTP → PCMU decode → TCP `:5914`. The decode callback runs on the thread
that decrypts *every* inbound packet, audio and video, so it must never block: it copies under a mutex
and returns, and a writer thread owns the socket. The ring holds 0.5 s and drops oldest. Newest
microphone wins. The desktop resamples 8 k → 16 k.

**Clipboard** rides RFB — there is no separate plane. The paste button reads the clipboard inside the
click gesture (Safari requires it), sends `ClientCutText`, then synthesises Shift+Insert.

---

## 6. Standing it up from scratch

### Step zero — secrets you must mint

Do this before anything else. Two of them have committed placeholder values that the code will
silently fall back to.

| secret | where | if you skip it |
|---|---|---|
| **box Nostr identity** | `NOSTR_SEC` in the launcher | **silently uses the committed placeholder.** That value is public, and it is also the login-token HMAC key — anyone with the source can mint valid codes. Set it. |
| **nsite site key** | `~/.glass/site-key`, mode 600 | `publish.lisp` refuses to run. This key *is* your site npub; losing it orphans every link ever issued |
| **TURN credential** | launcher **and** the browser bundle | cellular clients cannot connect |
| **`NOSTR_ALLOW`** | launcher | fails closed — nobody is authorised |
| **VNC password** | `~/.glass-vnc-pass` | the desktop listens unauthenticated. **But see dragons — setting it currently breaks video** |

`openssl rand -hex 32` produces the first two.

The box identity is duplicated in `gateway-nostr.lisp` and `login-link.lisp`, and the derived pubkey
appears again as a dev fallback in `index-nostr.html`. Rotating means touching all three, rebuilding,
republishing, and issuing a fresh link.

### The short path — LAN, no Nostr, no TURN, no publishing

Use the retired-but-working HTTP gateway: `gateway.lisp` + `index.html`, hunchentoot on `GW_PORT`
(8765), noVNC from `NOVNC_DIR`, offer over `POST /signal`. No keys, no relays, no build step. Point a
browser at `http://<host>:8765/`. Do this first to confirm the stack works at all.

### The full path

**Machine.** SBCL. Quicklisp with **three dists** — `quicklisp`, `ultralisp`, and **`modus`**
(`https://modus-lisp.github.io/dist/modus.txt`), which is how `seal`/`natrium`/`secp256k1-fast` are
reachable without hand-cloning. This is a real prerequisite and is documented nowhere else.

Systems are found by **two different mechanisms** depending on the process, and both must be set up:
the gateway uses `CL_SOURCE_REGISTRY` as an env var (a single `:tree` over the checkout root); the
desktop launcher uses `ql:quickload`, i.e. symlinks in `~/quicklisp/local-projects/`. (An ASDF
`source-registry.conf.d` entry exists in this tree but is renamed `.bak` and is *not* live — do not be
misled by it.)

Also needed: Python 3 and node/npm (`nostr-tools` + esbuild) for the client build, and `setsid` for
terminal windows. **No FFI, no ffmpeg, no web server.**

**Repos.** Minimum for a desktop on a phone: `webrtc-data`, `webrtc-media`, `glass`, `cl-nostr`,
`warren` (for the launcher), plus McCLIM — and transitively `seal`, `natrium`, `reed`, `cram`,
`scribe`, `secp256k1-fast`. Everything else is optional and guarded by `ignore-errors`, so a missing
one costs a menu item and a log line: `loom` (browser), `spool` (podcasts), `chord`/`stave` (voice and
ear, each also needing model weights built separately), `climacs` (editor), `mcclim-glass/remote`
(other desktops as windows).

**TURN.** A separate public box running coturn with `external-ip` set, one long-term credential, one A
record, 3478/udp plus a relay port range. **No coturn configuration exists in this repo** — it has to
be reconstructed. `demo/turn-rig/turn-server.py` is a small RFC 5766 server usable for local testing.

**Sequence.**

1. Desktop: `cd warren && sbcl --control-stack-size 256 --dynamic-space-size 4096 --load desktop-5903.lisp`
2. Client: build and publish per `DEPLOY.md` (`mkbundle.py`, then `publish.lisp` **with the file as
   argv**, then `check-deploy.lisp`, then re-point `site-url.env` at nsite.run)
3. Gateway: `./gw-keepalive.sh` under nohup or tmux
4. First login: `NOSTR_SEC=<box> sbcl --script login-link.lisp <your-npub>`, or DM the box `link`
   once allowlisted

**Nothing here survives a reboot.** There is no systemd unit and no crontab entry for either process;
the desktop has no supervisor at all.

### What is hardcoded to one installation

In rough order of how badly it bites: the box secret (two files) and its derived pubkey (a third);
the site npub (**five** files); the TURN server, user and password (launcher *and* browser bundle,
which needs a rebuild to change); `TURN_RELAY_PEER`; `ICE_LOCAL_IP`; `NOSTR_ALLOW`; the absolute paths
in the launcher and in `desktop-5903.lisp` (including `mcclim-glass.asd`, which is *not* in
`local-projects`, so that literal path is load-bearing); voice and ear model paths under `/mnt`;
esbuild's path under one user's home; and the 5903/5913/5914 port convention, which is asserted in a
docstring and enforced nowhere.

---

## 7. The warp channel — the terminal list, on the connection you already have

**Off unless `WARP_CHANNEL` is set.** With it unset the warp systems are never loaded, no projection
is built, no thread is started, nothing is sent, and the startup banner does not mention it. That is
deliberate: a claim of "this changes nothing" has to be checkable by reading, and "the code is not
loaded" is the only version of it that is.

The one branch it adds to the session's message dispatch matches **stream 102 only**, and matches it
*whether or not the flag is set* — disabled means the bytes are dropped, not that the clause is
skipped. Skipping it would let a phone that has the panel, talking to a box that does not have the
channel, fall through to the RFB branch and hand glass `{"t":"viewport",…}` as desktop input. For
streams 0 and 100 — the only two any deployed client uses — the dispatch is unchanged.

**What it is.** `revoke` and the enrolment list already exist as a command set on a type, with a
real authorization rule, reachable only over DM. This gives that same set a second surface — a ▤
button on the phone that opens a list of enrolled terminals, where a hold offers the applicable
commands and a tap invokes one. Same command, same authorization predicate, written once.

**Where it runs.** *Inside the gateway*, over the gateway's own `.glass-devices`. No bridge and no
second process, because `:warp` depends on `bordeaux-threads` and nothing else.

| file | what it is |
|---|---|
| `warp-channel.lisp` | the whole gateway side: stream id, invoker, query, open/message/close |
| `gateway-nostr.lisp` | **29 added lines** — a `load`, a `let` binding, one `cond` clause, one close, one banner line |
| `index-nostr.html` | the ▤ panel, plus `warp/dom/client.js` embedded verbatim |
| `warp/dom/channel.lisp` | everything testable: the clock, the lock, the non-signalling send, the close |

**Authorization.** The invoker is `:allowlist` iff `authorized-p` says so, and `:device` otherwise —
so an allowlisted owner is offered `revoke` and an enrolled guest is not. It is deliberately **not**
the session's `via` string: `via` takes the first match of code / allowlist / device, so an owner
arriving on a magic link classifies as `"code"` and so does a guest who was sent one. Mapping that
string would demote the owner and promote the guest at the same time. Menu filtering is courtesy;
`warp:invoke` refuses an unauthorized command whatever the surface offered.

**Cost.** `WARP_BUDGET` bytes per pass (default 1024) at `WARP_HZ` (default 4), and **zero in steady
state** — a pass with nothing owed sends nothing, and enrolments do not change while you are
watching a desktop. The budget bounds the first fill and the rare change.

**A revoke from the panel** rewrites `.glass-devices`, and the gateway's own `sync-devices` picks it
up on the next mtime check — the mechanism the device store was designed around. `device-enrolled-p`
then refuses that terminal's next connection with no restart.

**Environment.** `WARP_CHANNEL=1` to enable; `WARP_BUDGET`, `WARP_HZ`, `WARP_ROWS` to tune. warp must
be checked out beside `webrtc-data` and reachable through `CL_SOURCE_REGISTRY`; if it is not, the
load fails inside a handler, one line goes to the log, and the panel shows "no answer".

**Tests, none of which start a gateway.** `demo/glass-webrtc/warp-channel-test.lisp` lifts
`authorized-p` and the device store out of `gateway-nostr.lisp`'s *text* by name and runs
`warp-channel.lisp` against a stubbed SCTP; `warp/t/channel.lisp` drives the channel module over a
fake transport; `warp/t/panel.sh` drives the panel's actual bytes in headless Chromium. The
untested remainder is `sctp-send-string` itself, which already carries RFB and the control channel.

---

## 8. Dragons

**Security**

1. **The box identity falls back to a committed placeholder** when `NOSTR_SEC` is unset, and that
   secret is the login-token HMAC key. `DEPLOY.md` claims nothing in the repo contains a key; that is
   true only of the *site* key.
2. **Login codes are reusable until expiry** — no spent-nonce set, contradicting `login-token.lisp`'s
   own header.
3. **Any admitted connection enrols a 24 h device that renews itself**, so one leaked link is durable
   access until revoked.
4. **The TURN long-term credential is published** in the browser bundle. Inherent to browser TURN
   without ephemeral credentials, but the box shares the same credential. The fix is coturn's
   `use-auth-secret` with time-limited HMAC credentials minted per session.
5. **Setting `~/.glass-vnc-pass` breaks video.** `glass-capture.lisp` selects RFB security type None
   unconditionally and has no VNC-auth implementation, so the capture connection fails while the
   browser's bridged RFB (which does authenticate) keeps working. It surfaces only as
   `desktop capture FAILED`. **The secure configuration is the broken one.**
6. **The desktop's control socket is an unauthenticated `eval`** on loopback — a trust boundary worth
   naming.

**Operational**

7. `LOGIN_URL_BASE` is read **once at gateway start**; the launcher's own `export` also runs once.
   Only the `site-url.env` sourced *inside* the restart loop actually updates a running system.
8. Publishing **replaces** the manifest, so the previous `/<tag>.html` stops resolving and every link
   minted against it 404s. Always publish under a new tag.
9. `publish.lisp` writes an **nsite.lol** URL into `site-url.env`, but nsite.lol serves a stale
   manifest — worse, `/index.html` returns 200 with an *older* build, which looks like success. Verify
   on nsite.run. Zero `accepted=T` lines means nothing was published.
10. NIP-05 allowlist resolution happens once at startup and fails open-to-empty.

**Code smells that will confuse a reader**

11. Six `VIDEO_*` gateway parameters are **dead** — overridden by the profile from the first encoder
    pass. The `[rung]` log line is the one that tells the truth.
12. `*video-pt*` and `*last-assoc*` are process globals mutated per session, despite comments saying
    otherwise — unsafe with overlapping sessions.
13. `link` is matched by **substring**, so `blink` and `linkedin` both mint a login link.
14. `revoke` accepts a 4-character prefix while advertising 8.
15. The seen-wrap set is flushed **wholesale** at 4096 entries, briefly reopening the replay window.
16. Control-channel JSON is hand-scraped and hand-formatted on the box; any format drift breaks it
    silently.
17. `GATHER_SRFLX` in the launcher is vestigial, and `link-request-p` is dead code.
18. The FramebufferUpdateRequest filter is a magic-byte heuristic, and the RFB channel stays live in
    video-primary mode.
