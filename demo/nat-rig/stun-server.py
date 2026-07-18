#!/usr/bin/env python3
"""Minimal STUN Binding server (RFC 5389) for the NAT-traversal rig.

Listens on UDP <bind-ip>:<port> (default 0.0.0.0:3478). For any STUN Binding
request (msg-type 0x0001, magic cookie 0x2112A442 at offset 4) it replies with a
Binding Success (0x0101), echoing the 96-bit transaction id and carrying a single
XOR-MAPPED-ADDRESS (attr type 0x0020) = the sender's transport address XOR'd per
RFC 5389.  No MESSAGE-INTEGRITY, no other attributes — enough for a peer to learn
its server-reflexive address.
"""
import socket, struct, sys

MAGIC = 0x2112A442


def xor_mapped_address(ip: str, port: int) -> bytes:
    # family 0x01 = IPv4; port XOR high 16 bits of magic; addr XOR whole magic.
    xport = port ^ (MAGIC >> 16)
    ipb = socket.inet_aton(ip)
    xaddr = bytes(b ^ m for b, m in zip(ipb, struct.pack(">I", MAGIC)))
    val = struct.pack(">BBH", 0, 0x01, xport) + xaddr  # reserved, family, xport, xaddr
    return struct.pack(">HH", 0x0020, len(val)) + val   # attr type, length, value


def main():
    bind_ip = sys.argv[1] if len(sys.argv) > 1 else "0.0.0.0"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 3478
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((bind_ip, port))
    sys.stderr.write(f"@@ stun-server listening on {bind_ip}:{port}\n")
    sys.stderr.flush()
    while True:
        data, addr = s.recvfrom(2048)
        if len(data) < 20:
            continue
        mtype, mlen, cookie = struct.unpack(">HHI", data[:8])
        if mtype != 0x0001 or cookie != MAGIC:
            continue
        tid = data[8:20]  # 96-bit transaction id
        attrs = xor_mapped_address(addr[0], addr[1])
        resp = struct.pack(">HHI", 0x0101, len(attrs), MAGIC) + tid + attrs
        s.sendto(resp, addr)
        sys.stderr.write(f"@@ stun bind req from {addr} -> reflexive {addr[0]}:{addr[1]}\n")
        sys.stderr.flush()


if __name__ == "__main__":
    main()
