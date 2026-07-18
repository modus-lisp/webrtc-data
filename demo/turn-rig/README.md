# turn-rig — TURN relay proof for webrtc-data

Proves the TURN client in `src/turn.lisp`: it Allocates a relayed address, relays data both
directions (ChannelData + Data/Send indications), and lets a real WebRTC peer (aiortc) connect
**only via the relay** — the symmetric-NAT case `srflx` can't cover.

## Controlled TURN server

`turn-server.py` — a ~230-line RFC 5766 TURN server used for these tests (no `sudo`/coturn needed).
Long-term auth (401 → realm+nonce → verify `MESSAGE-INTEGRITY` with `key = MD5(user:realm:pass)`),
Allocate, CreatePermission, ChannelBind, Refresh, ChannelData + Send/Data indications, relaying UDP
through a per-allocation socket.

```
python3 turn-server.py <listen-ip> <listen-port> <relay-ip> [user] [pass] [realm]
```

## Test 1 — Allocate + relay round-trip (ChannelData)

`test2-client.lisp` Allocates a relayed address, binds a channel to a third party, echoes relayed
datagrams. `test2-peer.py` is a plain UDP host (no TURN) that talks to the relayed address.

```
python3 turn-server.py 127.0.0.1 3478 127.0.0.1 webrtc secret webrtc-data.test &
TURN_SERVER=127.0.0.1:3478 TURN_USER=webrtc TURN_PASS=secret TURN_DIR=/tmp/turn-rig/ \
  sbcl --non-interactive --load test2-client.lisp &
TURN_DIR=/tmp/turn-rig/ python3 test2-peer.py     # -> ROUND-TRIPS OK = 3/3
```

## Test 2 — aiortc connects only via the relay

`run.sh` runs two arms against the same TURN server. aiortc is forced to `TransportPolicy.RELAY`
(monkeypatched in `integration-offerer.py`), and the answerer's host candidate is a bogus
RFC-5737 address (192.0.2.1), so the only reachable path is the relay.

```
bash run.sh
# relay:      CONNECTED (over TURN relay)   — DTLS + data channel echo, answerer peer = (RELAY <chan>)
# srflx-only: NO CONNECT (no relay candidate to pair — expected)
```

Enable `WEBRTC_TURN_DEBUG=1` for the CL side to trace relayed STUN handling.
