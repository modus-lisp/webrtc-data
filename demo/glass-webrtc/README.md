# Demo: glass over WebRTC (remote desktop in a browser)

Serve a [glass](https://github.com/modus-lisp/glass) desktop/terminal to a plain browser
(iPhone Safari included) over the from-scratch WebRTC data-channel stack — no plugins, no
Tor, P2P. cl-webrtc is a transparent RFB pipe: **noVNC** (in the browser) is the RFB client,
**glass** is the RFB server, and the bytes ride our ICE → DTLS → SCTP → data channel.

```
browser (noVNC on an RTCDataChannel)
   │   SDP offer/answer over HTTP (hunchentoot)
   ▼
cl-webrtc gateway  ──TCP──▶  glass RFB server (:5900)
   (ICE-lite · DTLS 1.2 · SCTP/DCEP)
```

## Run
1. A glass RFB server on :5900 — e.g. `(glass-term:run :port 5900)`.
2. A noVNC 1.7+ checkout. Put it at `../novnc/` (next to this demo) or set `NOVNC_DIR`.
3. `(ql:quickload :hunchentoot)` is used for the page + one `POST /signal`.
4. Load the gateway:
   ```
   CL_SOURCE_REGISTRY="(:source-registry (:tree \"/path/to/repos\") :inherit-configuration)" \
     sbcl --load gateway.lisp
   ```
5. Open `http://<host>:8765/` in a browser. noVNC rides the data channel directly
   (`new RFB(el, dataChannel)` — noVNC 1.7 accepts an RTCDataChannel as its transport).

Env overrides: `GW_PORT` (8765), `GLASS_HOST` (127.0.0.1), `GLASS_PORT` (5900), `NOVNC_DIR`.

## How it works
- `POST /signal` carries the browser's offer SDP; the gateway sets up an ICE-lite answerer,
  runs DTLS then SCTP, and returns the answer SDP.
- On DCEP open (`:on-ready`) the gateway TCP-connects to glass and pumps both ways. glass→browser
  is chunked to ≤1024 B because our SCTP doesn't fragment; browser→glass is small RFB messages.
- Verified end-to-end against headless Chromium: framebuffer renders and typed keystrokes reach
  the shell.
