# Vendored noVNC 1.7.0 (+ TRLE decoder)

This is a vendored subset of [noVNC](https://github.com/novnc/noVNC) 1.7.0 (`core/` + `vendor/`),
used by the glass-over-WebRTC demo — the browser imports `core/rfb.js` and drives it straight
over the `RTCDataChannel`. MPL 2.0 (see `LICENSE.txt`).

**Local addition:** `core/decoders/trle.js` — a TRLE (encoding 15) decoder noVNC doesn't ship,
matching glass's TRLE (ZRLE's 64×64 tiles sent raw, no zlib/length). Registered + advertised in
`core/rfb.js` and `core/encodings.js`. It decodes tiles straight off the socket, resuming across
partial reads via `Websock.rQwait`'s rollback.

Note: TRLE trades compression for encode speed, so its frames are large (raw). That's a win on a
LAN VNC link but not over a bandwidth-limited WebRTC pipe for compressible content — glass only
switches to TRLE for big rects (≥16384 px); small updates stay ZRLE. See `../README.md`.
