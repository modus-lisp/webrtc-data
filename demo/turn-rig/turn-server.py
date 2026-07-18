#!/usr/bin/env python3
"""A minimal RFC 5766 TURN server for testing webrtc-data's TURN client.

Long-term credentials only: an unauthenticated Allocate draws 401 (realm+nonce); a retry with
USERNAME/REALM/NONCE/MESSAGE-INTEGRITY is verified with key = MD5(user:realm:pass).  Supports
Allocate, CreatePermission, ChannelBind, Refresh, ChannelData + Send/Data indications, relaying
UDP both directions through a per-allocation relayed socket.

Usage: turn-server.py <listen-ip> <listen-port> <relay-ip> [user] [pass] [realm]
  <relay-ip> is the address advertised in XOR-RELAYED-ADDRESS (must be reachable by the peer).
"""
import hashlib, hmac, os, socket, struct, sys, threading, time

MAGIC = 0x2112A442
REALM = "webrtc-data.test"
# methods/classes -> full 14-bit message type
ALLOCATE, REFRESH, CREATE_PERM, CHANNEL_BIND = 0x003, 0x004, 0x008, 0x009
SEND_IND, DATA_IND = 0x006, 0x007
CLS_REQ, CLS_IND, CLS_SUCC, CLS_ERR = 0x00, 0x01, 0x02, 0x03

# attributes
A_MAPPED = 0x0001; A_USERNAME = 0x0006; A_MI = 0x0008; A_ERROR = 0x0009
A_CHANNEL = 0x000C; A_LIFETIME = 0x000D; A_XPEER = 0x0012; A_DATA = 0x0013
A_REALM = 0x0014; A_NONCE = 0x0015; A_XRELAY = 0x0016; A_REQTRANS = 0x0019
A_XMAPPED = 0x0020; A_SOFTWARE = 0x8022


def mtype(method, cls):
    return (((method & 0xf80) << 2) | ((method & 0x70) << 1) | (method & 0xf)
            | ((cls & 0x2) << 7) | ((cls & 0x1) << 4))


def parse_type(t):
    method = ((t >> 2) & 0xf80) | ((t >> 1) & 0x70) | (t & 0xf)
    cls = ((t >> 7) & 0x2) | ((t >> 4) & 0x1)
    return method, cls


def pad4(n):
    return (4 - (n & 3)) & 3


def parse_attrs(msg):
    attrs = {}
    pos, end = 20, 20 + struct.unpack(">H", msg[2:4])[0]
    while pos + 4 <= end:
        atype, alen = struct.unpack(">HH", msg[pos:pos + 4])
        val = msg[pos + 4:pos + 4 + alen]
        attrs.setdefault(atype, val)
        if atype == A_MI:
            attrs['_mi_off'] = pos
        pos += 4 + alen + pad4(alen)
    return attrs


def build(mtype_val, tid, attrs, key=None):
    body = b""
    for atype, val in attrs:
        body += struct.pack(">HH", atype, len(val)) + val + (b"\x00" * pad4(len(val)))
    if key is not None:
        hdr = struct.pack(">HHI", mtype_val, len(body) + 24, MAGIC) + tid
        mi = hmac.new(key, hdr + body, hashlib.sha1).digest()
        body += struct.pack(">HH", A_MI, 20) + mi
    return struct.pack(">HHI", mtype_val, len(body), MAGIC) + tid + body


def xor_addr(ip, port):
    xport = port ^ (MAGIC >> 16)
    xaddr = struct.unpack(">I", socket.inet_aton(ip))[0] ^ MAGIC
    return struct.pack(">BBH I", 0, 1, xport, xaddr)


def parse_xor_addr(val):
    xport, xaddr = struct.unpack(">H I", val[2:8])
    port = xport ^ (MAGIC >> 16)
    ip = socket.inet_ntoa(struct.pack(">I", xaddr ^ MAGIC))
    return ip, port


def err_attr(code):
    return struct.pack(">HBB", 0, code // 100, code % 100)


class Alloc:
    def __init__(self, relay_sock, relay_ip, relay_port):
        self.sock = relay_sock
        self.relay_ip = relay_ip
        self.relay_port = relay_port
        self.perms = {}          # peer-ip -> expiry
        self.channels = {}       # channel -> (ip, port)
        self.chan_by_peer = {}   # (ip,port) -> channel
        self.expiry = time.time() + 600


def main():
    listen_ip, listen_port = sys.argv[1], int(sys.argv[2])
    relay_ip = sys.argv[3]
    USER = sys.argv[4] if len(sys.argv) > 4 else "webrtc"
    PASS = sys.argv[5] if len(sys.argv) > 5 else "secret"
    realm = sys.argv[6] if len(sys.argv) > 6 else REALM
    key = hashlib.md5(f"{USER}:{realm}:{PASS}".encode()).digest()

    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((listen_ip, listen_port))
    print(f"@@ TURN server on {listen_ip}:{listen_port}, relay-ip={relay_ip}, "
          f"user={USER} realm={realm}", flush=True)

    allocs = {}   # client (ip,port) -> Alloc

    def verify_mi(msg, attrs):
        mo = attrs.get('_mi_off')
        if mo is None:
            return False
        patched = msg[:2] + struct.pack(">H", mo + 4) + msg[4:mo]
        expect = hmac.new(key, patched, hashlib.sha1).digest()
        return hmac.compare_digest(expect, attrs[A_MI])

    def relay_reader(alloc, client):
        while True:
            try:
                data, addr = alloc.sock.recvfrom(65536)
            except OSError:
                return
            pip, pport = addr
            chan = alloc.chan_by_peer.get((pip, pport))
            if chan is not None:
                hdr = struct.pack(">HH", chan, len(data))
                srv.sendto(hdr + data, client)
            elif pip in alloc.perms:
                ind = build(mtype(DATA_IND, CLS_IND), os.urandom(12),
                            [(A_XPEER, xor_addr(pip, pport)), (A_DATA, data)])
                srv.sendto(ind, client)

    while True:
        msg, client = srv.recvfrom(65536)
        if len(msg) < 4:
            continue
        first2 = struct.unpack(">H", msg[:2])[0]

        # ---- ChannelData from client -> relay to peer ----
        if 0x4000 <= first2 <= 0x7FFF:
            alloc = allocs.get(client)
            if not alloc:
                continue
            dlen = struct.unpack(">H", msg[2:4])[0]
            peer = alloc.channels.get(first2)
            if peer:
                try:
                    alloc.sock.sendto(msg[4:4 + dlen], peer)
                except OSError:
                    pass   # unroutable peer (e.g. a bogus host candidate) — drop, don't die
            continue

        if len(msg) < 20 or struct.unpack(">I", msg[4:8])[0] != MAGIC:
            continue
        method, cls = parse_type(first2)
        tid = msg[8:20]
        attrs = parse_attrs(msg)

        # ---- Send indication (client -> peer) ----
        if method == SEND_IND and cls == CLS_IND:
            alloc = allocs.get(client)
            if alloc and A_XPEER in attrs and A_DATA in attrs:
                pip, pport = parse_xor_addr(attrs[A_XPEER])
                try:
                    alloc.sock.sendto(attrs[A_DATA], (pip, pport))
                except OSError:
                    pass
            continue

        def reject(code, extra=None):
            a = [(A_ERROR, err_attr(code))]
            if code == 401:
                a += [(A_REALM, realm.encode()),
                      (A_NONCE, hashlib.md5(os.urandom(8)).hexdigest().encode())]
            if extra:
                a += extra
            srv.sendto(build(mtype(method, CLS_ERR), tid, a), client)

        # ---- long-term auth gate ----
        if cls == CLS_REQ:
            if A_MI not in attrs:
                reject(401)
                continue
            if not (A_USERNAME in attrs and attrs[A_USERNAME].decode() == USER
                    and A_REALM in attrs):
                reject(401)
                continue
            if not verify_mi(msg, attrs):
                print("@@ MI MISMATCH from", client, "method", hex(method), flush=True)
                reject(401)
                continue

        if method == ALLOCATE and cls == CLS_REQ:
            if client in allocs:
                a = allocs[client]
            else:
                rs = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                rs.bind((relay_ip if relay_ip != "0.0.0.0" else "0.0.0.0", 0))
                rport = rs.getsockname()[1]
                a = Alloc(rs, relay_ip, rport)
                allocs[client] = a
                threading.Thread(target=relay_reader, args=(a, client), daemon=True).start()
                print(f"@@ Allocate ok {client} -> relay {relay_ip}:{rport}", flush=True)
            resp = build(mtype(ALLOCATE, CLS_SUCC), tid,
                         [(A_XRELAY, xor_addr(a.relay_ip, a.relay_port)),
                          (A_XMAPPED, xor_addr(client[0], client[1])),
                          (A_LIFETIME, struct.pack(">I", 600))], key=key)
            srv.sendto(resp, client)

        elif method == CREATE_PERM and cls == CLS_REQ:
            a = allocs.get(client)
            if not a:
                reject(437)
                continue
            for atype, val in [(A_XPEER, attrs[A_XPEER])] if A_XPEER in attrs else []:
                pip, _ = parse_xor_addr(val)
                a.perms[pip] = time.time() + 300
            srv.sendto(build(mtype(CREATE_PERM, CLS_SUCC), tid, [], key=key), client)
            print(f"@@ CreatePermission {client} perms={list(a.perms)}", flush=True)

        elif method == CHANNEL_BIND and cls == CLS_REQ:
            a = allocs.get(client)
            if not a or A_CHANNEL not in attrs or A_XPEER not in attrs:
                reject(400)
                continue
            chan = struct.unpack(">H", attrs[A_CHANNEL][:2])[0]
            pip, pport = parse_xor_addr(attrs[A_XPEER])
            a.channels[chan] = (pip, pport)
            a.chan_by_peer[(pip, pport)] = chan
            a.perms[pip] = time.time() + 300
            srv.sendto(build(mtype(CHANNEL_BIND, CLS_SUCC), tid, [], key=key), client)
            print(f"@@ ChannelBind {client} chan={chan} -> {pip}:{pport}", flush=True)

        elif method == REFRESH and cls == CLS_REQ:
            a = allocs.get(client)
            lt = struct.unpack(">I", attrs[A_LIFETIME])[0] if A_LIFETIME in attrs else 600
            if a and lt == 0:
                a.sock.close(); del allocs[client]
            elif a:
                a.expiry = time.time() + lt
            srv.sendto(build(mtype(REFRESH, CLS_SUCC), tid,
                             [(A_LIFETIME, struct.pack(">I", lt))], key=key), client)
            print(f"@@ Refresh {client} lifetime={lt}", flush=True)


if __name__ == "__main__":
    main()
