# cl-webrtc

A **from-scratch WebRTC data-channel peer in pure Common Lisp** — so a browser (or aiortc) can
open an `RTCDataChannel` straight to your Lisp with no plugins, no Tor, no signaling service
beyond one HTTP POST. Data channels only (no SRTP, no video codec).

It exists to carry [glass](https://github.com/modus-lisp/glass) — a pure-CL VNC/RFB server — to
a bare browser (iPhone Safari included) as a **remote desktop**, P2P. The transport is written
from scratch; the browser reuses [noVNC](https://github.com/novnc/noVNC) and the server reuses
glass, so cl-webrtc is a transparent RFB pipe over its own ICE/DTLS/SCTP.

Clean-room, and **verified against a spec-compliant peer at every layer** — aiortc/aioice for
the protocol, pynacl for the crypto, then a real headless browser end to end.

## The stack

```
   browser  ──  RTCDataChannel  ──▶  glass (RFB desktop)
      │                                  ▲
      ▼   SDP offer/answer (1 HTTP POST) │  transparent RFB byte-pipe
   ┌──────────────────────────────────────────────┐
   │  SDP  ·  ICE/STUN  ·  DTLS 1.2  ·  SCTP · DCEP │   ← all pure CL, this repo
   └──────────────────────────────────────────────┘
```

| Layer | What we do | Verified by |
|---|---|---|
| **SDP** | parse the data-channel offer, generate the answer | round-trips real aiortc offers |
| **STUN** | messages + MESSAGE-INTEGRITY (HMAC-SHA1) + FINGERPRINT (CRC32) | **aioice** validates our Binding Request byte-for-byte |
| **ICE** | ICE-lite UDP agent (answers connectivity checks) | aiortc → `iceConnectionState: completed` |
| **DTLS 1.2** | client handshake, ECDHE + AES-128-GCM, X25519, mutual auth | aiortc → `connectionState: connected` |
| **SCTP + DCEP** | reliable, flow-controlled association (responder) + data channels | aiortc fires `datachannel.onopen`; echo round-trips |
| **glass demo** | RFB framebuffer + input over the channel | headless Chromium: renders **and** keystrokes reach the shell |

DTLS 1.2 lives in [seal](https://github.com/modus-lisp/seal) (already a TLS 1.2/1.3 client — DTLS
reuses its PRF, key schedule, AES-GCM, X25519 and cert parsing, adding only the record/flight/
cookie layer + client-cert auth). seal is now a **TLS + DTLS** library.

## Reliable transport, with monitoring

The SCTP layer is a real reliable transport, not a toy responder: congestion + flow control
(cwnd slow-start/avoidance, peer `rwnd`), inbound SACK handling, RTO + fast retransmit, in-order
delivery with an out-of-order buffer and gap-ack SACKs, and peer-death detection.

- **Loss resilience** — with `*sctp-drop-rate*` set to 0.15 (15 % of outbound packets dropped),
  the glass desktop still renders **completely**; retransmission recovers. The prior "blast and
  hope" version wedged to a blank screen under the same loss.
- **Performance** — `sctp-stats` exposes counters + live window state; the demo shows a live HUD
  (real rendered FPS, throughput, backpressure). On localhost the transport tracks the source
  1:1 with **zero buffered bytes and 0 % retransmit** — FPS is bounded by glass's 60 Hz render,
  not the pipe (~33 fps flat-out @ 28 KB/s).

## Quick start

```lisp
;; deps: ironclad, bordeaux-threads, sb-bsd-sockets, and seal (all in the modus-lisp dist)
(ql:quickload "cl-webrtc")
```

Run the remote-desktop demo (`demo/glass-webrtc/`):

1. Start a glass RFB server on :5900 — e.g. `(glass-term:run :port 5900)`.
2. Point it at a [noVNC](https://github.com/novnc/noVNC) 1.7+ checkout: `NOVNC_DIR=/path/to/noVNC`.
3. `sbcl --load demo/glass-webrtc/gateway.lisp` (uses hunchentoot for the page + one `POST /signal`).
4. Open `http://<host>:8765/` in any browser. noVNC rides the data channel directly —
   `new RFB(el, dataChannel)`, no shim. See `demo/glass-webrtc/README.md`.

## API sketch

```lisp
(webrtc-dtls-setup agent &key remote-fingerprint)   ; -> dtls-conn; put its fingerprint in the answer
(webrtc-dtls-run   conn)                             ; drive the DTLS client handshake
(webrtc-serve-datachannel conn &key on-message on-ready log)  ; run SCTP+DCEP; bridge on :on-ready
(sctp-send-string / sctp-send-binary assoc stream-id data)    ; push
(sctp-stats assoc)                                  ; -> plist of counters + window health
```

## Scope (honestly)

Implemented: data channels over a single ordered/reliable SCTP stream. **Not** implemented (and
not needed for this use): SRTP / audio-video media, SCTP fragmentation & PR-SCTP / FORWARD-TSN,
RE-CONFIG, multihoming; ICE is lite (we answer checks, the peer nominates). Under *brutal* packet
loss (~15 %) recovery has occasional multi-second RTO hitches — correctness is always preserved;
normal LAN loss doesn't trigger them.

## Credits

Built on the [modus-lisp](https://github.com/modus-lisp) pure-CL stack — **seal** (TLS/DTLS +
crypto) and **glass** (RFB desktop). Browser side is **noVNC**. Verified against **aiortc** /
**aioice** / **pynacl** as reference peers.

MIT.
