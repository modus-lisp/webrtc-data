#!/usr/bin/env python3
"""aiortc peer (offerer) for the NAT-traversal rig — runs on the public side at 10.0.0.3.

Uses STUN at 10.0.0.2:3478 to gather its own srflx, creates a data channel, writes offer.sdp,
waits for answer.sdp, and reports whether the channel OPENs / the connection reaches `connected`
within a timeout.  Exit 0 = CONNECTED, exit 2 = NO CONNECT (timeout).

Env: RIG_DIR (shared dir), RIG_STUN (host:port, default 10.0.0.2:3478), RIG_TIMEOUT (s).
"""
import asyncio, os, sys
from aiortc import RTCPeerConnection, RTCConfiguration, RTCIceServer, RTCSessionDescription

DIR = os.environ.get("RIG_DIR", "/tmp/nat-rig/")
STUN = os.environ.get("RIG_STUN", "10.0.0.2:3478")
TIMEOUT = float(os.environ.get("RIG_TIMEOUT", "25"))


def p(*a):
    print("@@", *a, flush=True)


async def main():
    cfg = RTCConfiguration(iceServers=[RTCIceServer(urls=f"stun:{STUN}")])
    pc = RTCPeerConnection(cfg)
    ch = pc.createDataChannel("chat")
    connected = asyncio.Event()

    @ch.on("open")
    def _():
        p("datachannel OPEN")
        ch.send("hello-from-peer")
        connected.set()

    @ch.on("message")
    def _(m):
        p("got echo:", m)

    @pc.on("connectionstatechange")
    def _():
        p("conn-state:", pc.connectionState)
        if pc.connectionState == "connected":
            connected.set()

    @pc.on("iceconnectionstatechange")
    def _():
        p("ice-state:", pc.iceConnectionState)

    await pc.setLocalDescription(await pc.createOffer())
    # setLocalDescription in aiortc blocks until ICE gathering is complete, so the local SDP
    # already carries host + srflx candidates (non-trickle).
    with open(os.path.join(DIR, "offer.sdp"), "w") as f:
        f.write(pc.localDescription.sdp)
    p("wrote offer.sdp; local candidates:")
    for line in pc.localDescription.sdp.splitlines():
        if "candidate" in line:
            p("  ", line.strip())

    for _ in range(300):
        if os.path.exists(os.path.join(DIR, "answer.sdp")):
            break
        await asyncio.sleep(0.2)
    else:
        p("NO ANSWER SDP — answerer never wrote one")
        await pc.close()
        return 2
    await asyncio.sleep(0.3)
    answer = open(os.path.join(DIR, "answer.sdp")).read()
    await pc.setRemoteDescription(RTCSessionDescription(answer, "answer"))

    try:
        await asyncio.wait_for(connected.wait(), TIMEOUT)
        p("RESULT: CONNECTED (datachannel/connection up)")
        rc = 0
    except asyncio.TimeoutError:
        p("RESULT: NO CONNECT — conn-state=", pc.connectionState, "ice-state=", pc.iceConnectionState)
        rc = 2
    await pc.close()
    return rc


sys.exit(asyncio.run(main()))
