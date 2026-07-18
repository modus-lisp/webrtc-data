#!/bin/bash
# run.sh — rootless NAT-traversal A/B proof for webrtc-data's full-agent ICE.
#
# Topology (rootless: unshare -Umrn userns w/ CAP_NET_ADMIN over child netns; keeper-PID trick
# because /run/netns is not writable):
#
#     S (answerer, behind NAT)          R (router, MASQUERADE)              P (public side)
#     10.1.0.2/24  --- veth --- 10.1.0.1 | 10.0.0.1 --- veth --- 10.0.0.2 (STUN)  +  10.0.0.3 (peer)
#     default via 10.1.0.1              ip_forward=1, SNAT S->10.0.0.1        aiortc offerer
#
# Two distinct public IPs: STUN at 10.0.0.2, peer at 10.0.0.3.  S learns its public mapping by
# querying 10.0.0.2; a restricted (conntrack) NAT then only admits inbound that matches a flow S
# initiated.  The peer at 10.0.0.3 is an address S never sent to under ice-lite -> blocked.  Only
# full-agent checks (S -> 10.0.0.3) open the mapping toward the peer.
#
# Runs the answerer in three modes across the same rig and prints a RESULT line per arm.
# Requires: sbcl, python3+aiortc, iproute2, iptables, a userns-capable kernel.
set -u
RIG="$(cd "$(dirname "$0")" && pwd)"
: "${CL_SOURCE_REGISTRY:=(:source-registry (:tree \"/home/claude\") :inherit-configuration)}"
export CL_SOURCE_REGISTRY
export RIG
SHARE="$(mktemp -d /tmp/nat-rig.XXXXXX)"
export SHARE

timeout -s KILL 300 unshare -Umrn bash -c '
set -u
say(){ printf "\n=== %s ===\n" "$*"; }

ip link set lo up
# Sibling netns held open by keeper processes (named netns needs writable /run/netns; PID trick).
unshare -n sleep 3000 & S_NS=$!
unshare -n sleep 3000 & R_NS=$!
unshare -n sleep 3000 & P_NS=$!
sleep 0.5

# veth S<->R and R<->P
ip link add veth-s  type veth peer name veth-rs
ip link add veth-rp type veth peer name veth-p
ip link set veth-s  netns $S_NS
ip link set veth-rs netns $R_NS
ip link set veth-rp netns $R_NS
ip link set veth-p  netns $P_NS

nS(){ nsenter -t $S_NS -n "$@"; }
nR(){ nsenter -t $R_NS -n "$@"; }
nP(){ nsenter -t $P_NS -n "$@"; }

# S: private host + default route via router
nS ip link set lo up
nS ip addr add 10.1.0.2/24 dev veth-s
nS ip link set veth-s up
nS ip route add default via 10.1.0.1

# R: router with both subnets, forwarding + MASQUERADE of S toward the public side
nR ip link set lo up
nR ip addr add 10.1.0.1/24 dev veth-rs
nR ip link set veth-rs up
nR ip addr add 10.0.0.1/24 dev veth-rp
nR ip link set veth-rp up
nR sysctl -qw net.ipv4.ip_forward=1
if nR iptables -t nat -A POSTROUTING -s 10.1.0.0/24 -o veth-rp -j MASQUERADE 2>/tmp/ipt.err; then
  NATTOOL=iptables
elif nR nft add table ip nat 2>/dev/null \
     && nR nft add chain ip nat post "{ type nat hook postrouting priority 100 ; }" \
     && nR nft add rule ip nat post ip saddr 10.1.0.0/24 oif "veth-rp" masquerade; then
  NATTOOL=nft
else
  echo "@@ FATAL: could not install MASQUERADE"; cat /tmp/ipt.err; exit 1
fi
echo "@@ MASQUERADE installed via $NATTOOL"

# P: public side — peer at 10.0.0.3, STUN at 10.0.0.2 (secondary addr, distinct IP)
nP ip link set lo up
nP ip addr add 10.0.0.3/24 dev veth-p       # primary = peer address
nP ip addr add 10.0.0.2/24 dev veth-p       # secondary = STUN address
nP ip link set veth-p up

# ---- sanity probe: is the NAT genuinely one-way (restricting)? ----
say "sanity probe"
echo -n "@@ S -> 10.0.0.2 (STUN IP, through NAT): "
nS ping -c1 -W2 10.0.0.2 >/dev/null 2>&1 && echo "OK (forward+masq works)" || echo "FAIL"
echo -n "@@ S -> 10.0.0.3 (peer IP,  through NAT): "
nS ping -c1 -W2 10.0.0.3 >/dev/null 2>&1 && echo "OK" || echo "FAIL"
echo -n "@@ P(10.0.0.3) -> 10.1.0.2 (S private, unsolicited inbound): "
if nP ping -c1 -W2 10.1.0.2 >/dev/null 2>&1; then echo "REACHABLE (NAT NOT restricting!)"; else echo "BLOCKED (good, NAT restricts inbound)"; fi

run_arm(){
  MODE="$1"; EXPECT="$2"
  say "ARM: $MODE (expect $EXPECT)"
  rm -f "$SHARE/offer.sdp" "$SHARE/answer.sdp"
  command -v conntrack >/dev/null 2>&1 && nR conntrack -F >/dev/null 2>&1

  # STUN server on the public side, bound to the distinct STUN IP.
  nP python3 "$RIG/stun-server.py" 10.0.0.2 3478 >"$SHARE/stun-$MODE.log" 2>&1 &
  STUN_PID=$!
  sleep 0.5

  # Answerer in S (behind the NAT).
  nS env RIG_DIR="$SHARE/" RIG_MODE="$MODE" ICE_LOCAL_IP=10.1.0.2 STUN_SERVER=10.0.0.2:3478 \
       CL_SOURCE_REGISTRY="$CL_SOURCE_REGISTRY" \
       sbcl --dynamic-space-size 1024 --non-interactive --load "$RIG/answerer.lisp" \
       >"$SHARE/answerer-$MODE.log" 2>&1 &
  ANS_PID=$!
  sleep 0.3

  # Peer (aiortc offerer) in P at 10.0.0.3.
  nP env RIG_DIR="$SHARE/" RIG_STUN=10.0.0.2:3478 RIG_TIMEOUT=25 \
       python3 "$RIG/peer.py" >"$SHARE/peer-$MODE.log" 2>&1
  RC=$?

  cp -f "$SHARE/offer.sdp"  "$SHARE/offer-$MODE.sdp"  2>/dev/null
  cp -f "$SHARE/answer.sdp" "$SHARE/answer-$MODE.sdp" 2>/dev/null
  RESULT=$(grep -a "RESULT:" "$SHARE/peer-$MODE.log" | tail -1)
  echo "@@ peer: $RESULT"
  grep -aE "srflx=|ice-start-checks|DTLS HANDSHAKE|ANSWERER FAILED|answerer serving" "$SHARE/answerer-$MODE.log" | sed "s/^/@@ ans: /"

  kill $ANS_PID $STUN_PID 2>/dev/null
  wait $ANS_PID $STUN_PID 2>/dev/null
  sleep 1
  if [ $RC -eq 0 ]; then echo "@@ >>> $MODE: CONNECTED"; else echo "@@ >>> $MODE: NO CONNECT"; fi
  echo "$MODE $RC" >> "$SHARE/results.txt"
}

# Negative first (clean state), then the two positives/negatives.
run_arm lite     "NO CONNECT (srflx advertised, but no checks -> NAT drops peer)"
run_arm full     "CONNECTED (checks punch the NAT open toward the peer)"
run_arm hostonly "NO CONNECT (task-literal ice-lite: only unroutable host candidate)"

say "SUMMARY"
FULL_RC=$(awk "/^full /{print \$2}"     "$SHARE/results.txt")
LITE_RC=$(awk "/^lite /{print \$2}"     "$SHARE/results.txt")
HOST_RC=$(awk "/^hostonly /{print \$2}" "$SHARE/results.txt")
[ "${FULL_RC:-1}" = 0 ] && echo "@@ full-agent: CONNECTED"          || echo "@@ full-agent: NO CONNECT (UNEXPECTED)"
[ "${LITE_RC:-0}" != 0 ] && echo "@@ ice-lite:   NO CONNECT (blocked by NAT)" || echo "@@ ice-lite:   CONNECTED (UNEXPECTED — NAT not restricting)"
[ "${HOST_RC:-0}" != 0 ] && echo "@@ host-only:  NO CONNECT (unroutable private candidate)" || echo "@@ host-only:  CONNECTED (UNEXPECTED)"

kill $S_NS $R_NS $P_NS 2>/dev/null
'
STATUS=$?
echo
echo "logs + SDPs in $SHARE"
exit $STATUS
