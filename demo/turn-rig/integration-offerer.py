#!/usr/bin/env python3
"""aiortc offerer forced to a RELAY-ONLY ICE policy, for the TURN integration proof.

aiortc supports TURN natively.  We give it the same turn: server as the CL answerer and monkeypatch
its aioice Connection to TransportPolicy.RELAY, so aiortc gathers ONLY a relay candidate and will
only pair it against the answerer's relay candidate.  Thus the session can succeed *only* via the
relay: with the answerer advertising a relay candidate -> CONNECTED; without one -> NO CONNECT.

Success = data channel opens AND the CL answerer echoes our message back — end-to-end over the relay.
Exit 0 = CONNECTED, 2 = NO CONNECT.
Env: TURN_SERVER host:port, TURN_USER, TURN_PASS, TURN_DIR, RIG_TIMEOUT.
"""
import asyncio, os, sys
import aiortc.rtcicetransport as icet
from aioice.ice import TransportPolicy
from aiortc import RTCPeerConnection, RTCConfiguration, RTCIceServer, RTCSessionDescription

DIR = os.environ.get("TURN_DIR", "/tmp/turn-rig/")
TURN = os.environ["TURN_SERVER"]
USER = os.environ.get("TURN_USER", "webrtc")
PASS = os.environ.get("TURN_PASS", "secret")
TIMEOUT = float(os.environ.get("RIG_TIMEOUT", "25"))

# Force every aioice Connection aiortc builds into relay-only mode.
_RealConnection = icet.Connection
def _relay_only_connection(*args, **kwargs):
    kwargs["transport_policy"] = TransportPolicy.RELAY
    return _RealConnection(*args, **kwargs)
icet.Connection = _relay_only_connection


def p(*a):
    print("@@", *a, flush=True)


async def main():
    host, port = TURN.split(":")
    cfg = RTCConfiguration(iceServers=[
        RTCIceServer(urls=f"turn:{host}:{port}?transport=udp", username=USER, credential=PASS)])
    pc = RTCPeerConnection(cfg)
    ch = pc.createDataChannel("chat")
    got = asyncio.Event()

    @ch.on("open")
    def _():
        p("datachannel OPEN"); ch.send("hello-over-relay")

    @ch.on("message")
    def _(m):
        p("got echo:", m); got.set()

    @pc.on("connectionstatechange")
    def _(): p("conn-state:", pc.connectionState)

    @pc.on("iceconnectionstatechange")
    def _(): p("ice-state:", pc.iceConnectionState)

    await pc.setLocalDescription(await pc.createOffer())
    with open(os.path.join(DIR, "offer.sdp"), "w") as f:
        f.write(pc.localDescription.sdp)
    p("local candidates:")
    for line in pc.localDescription.sdp.splitlines():
        if "candidate" in line:
            p("  ", line.strip())

    for _ in range(300):
        if os.path.exists(os.path.join(DIR, "answer.sdp")):
            break
        await asyncio.sleep(0.2)
    else:
        p("RESULT: NO CONNECT — no answer.sdp"); await pc.close(); return 2
    await asyncio.sleep(0.3)
    ans = open(os.path.join(DIR, "answer.sdp")).read()
    p("answerer candidates:")
    for line in ans.splitlines():
        if "candidate" in line:
            p("  ", line.strip())
    await pc.setRemoteDescription(RTCSessionDescription(ans, "answer"))

    try:
        await asyncio.wait_for(got.wait(), TIMEOUT)
        p("RESULT: CONNECTED (data channel open + echo over relay)")
        rc = 0
    except asyncio.TimeoutError:
        p("RESULT: NO CONNECT — conn=", pc.connectionState, "ice=", pc.iceConnectionState)
        rc = 2
    await pc.close()
    return rc


sys.exit(asyncio.run(main()))
