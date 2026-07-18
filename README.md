# cl-webrtc

A **from-scratch WebRTC data-channel peer in pure Common Lisp** — so a browser (or aiortc)
can open an `RTCDataChannel` to us with no plugins. Data channels only (no SRTP, no video
codec); built to carry [glass](https://github.com/modus-lisp/glass)'s framebuffer + input to
a bare browser (iPhone Safari included), P2P, no Tor.

Clean-room, tested against **aiortc** (a spec-compliant peer) at each layer, then a real browser.

## Status (WIP)
- [x] **SDP** — parse the data-channel offer, generate the answer (verified vs aiortc offers).
- [x] **STUN** — messages + MESSAGE-INTEGRITY (HMAC-SHA1) + FINGERPRINT (CRC32) — **validated by aioice**.
- [ ] **ICE** — UDP agent, connectivity checks → `iceConnectionState: connected`.
- [ ] **DTLS 1.2** — over seal's crypto.
- [ ] **SCTP + DCEP** — the data channel itself (`datachannel.onopen`).
- [ ] **glass** — framebuffer + input over the channel.

MIT.
