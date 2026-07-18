#!/usr/bin/env python3
"""Third-party peer for the TURN relay round-trip proof.

Binds a fixed source port (so the CL client can pre-bind a channel to it), sends datagrams to the
CL client's relayed address, and prints the echoes that come back THROUGH the allocation.  This is
a plain UDP peer — it has no TURN client; it just talks to the relayed transport address, exactly
as any host on the internet would.
"""
import os, socket, sys, time

DIR = os.environ.get("TURN_DIR", "/tmp/turn-rig/")
PORT = int(os.environ.get("PEER_PORT", "45999"))

for _ in range(100):
    if os.path.exists(os.path.join(DIR, "relay.addr")):
        break
    time.sleep(0.1)
else:
    print("@@ no relay.addr", flush=True); sys.exit(2)
time.sleep(0.5)
ip, port = open(os.path.join(DIR, "relay.addr")).read().strip().split(":")
relay = (ip, int(port))
print(f"@@ peer: relay address = {relay}, my source port = {PORT}", flush=True)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", PORT))
s.settimeout(3)

ok = 0
for i in range(3):
    msg = f"PING-{i}".encode()
    s.sendto(msg, relay)
    print(f"@@ peer: sent {msg!r} -> relay", flush=True)
    try:
        data, src = s.recvfrom(4096)
        print(f"@@ peer: got {data!r} from {src}", flush=True)
        if data == b"ECHO:" + msg:
            ok += 1
    except socket.timeout:
        print("@@ peer: TIMEOUT waiting for echo", flush=True)
    time.sleep(0.3)

print(f"@@ peer: ROUND-TRIPS OK = {ok}/3", flush=True)
sys.exit(0 if ok == 3 else 2)
