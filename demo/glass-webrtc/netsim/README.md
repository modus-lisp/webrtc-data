# netsim — network conditioning for the glass-over-WebRTC demo

Drive the remote-desktop demo across emulated bad connections and measure how the transport
holds up: time-to-connect, frame rate, and the SCTP stack's own SRTT / retransmits / congestion
window (read from `/stats`).

**No Docker.** A rootless `unshare(1)` rig: two network namespaces joined by a `veth`, with
kernel `netem` shaping delay / jitter / loss / reordering on both egress directions. glass +
the gateway run on one side (their link to each other stays clean); a headless Chromium runs on
the other — so the impaired path is exactly the browser↔server link, and any degradation is the
transport's, not a confounded RFB source.

```
 netns B (10.0.0.2)                     netns A (10.0.0.1)
 ┌───────────────┐   veth + netem   ┌──────────────────────────┐
 │ headless      │◀───delay/loss───▶│ cl-webrtc gateway ──lo──▶ │
 │ Chromium+noVNC│   (both ways)    │ glass RFB (clean)         │
 └───────────────┘                  └──────────────────────────┘
```

## Run
```sh
export NOVNC_DIR=/path/to/noVNC            # a noVNC 1.7+ checkout
export CL_SOURCE_REGISTRY='(:source-registry (:tree "/path/to/repos") :inherit-configuration)'
./netsim.sh                                # sweeps profiles.txt
```
Requirements: `sbcl`, `python3` + playwright (chromium installed), `iproute2` (`tc`/netem), and a
kernel that allows `unshare -Urn` (user + net namespaces). Per-profile JSON + logs land in
`$OUT` (default `/tmp/netsim-out`).

## Profiles
`profiles.txt` is `label|netem-args`, one per line — the args go straight to `tc qdisc … netem`:
```
good-wifi|delay 15ms 5ms loss 0.3%
satellite|delay 300ms 40ms loss 1%
awful|delay 150ms 60ms distribution normal loss 15% reorder 10%
```

## What it measures
`measure-netsim.py` loads the page, waits for the desktop to come up over the (impaired) link,
runs a flat-out screen-churn workload, then reports `connect`, median `fps`, and the session's
`srtt` / `rtx` / `drops` / `cwnd` from `/stats`. Findings from one sweep: SRTT tracks the injected
round-trip almost exactly (validating the estimator localhost can't exercise); frame rate is
bounded by RFB's one-request-per-round-trip design (≈ 1000/RTT), not by our pipe; the transport
stays correct through a 600 ms satellite link and only fails to *connect* under ~15% sustained
loss + heavy reordering (the DTLS handshake can't complete).
