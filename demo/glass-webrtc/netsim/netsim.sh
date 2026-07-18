#!/bin/bash
# netsim.sh — run the glass-over-WebRTC demo across a sweep of emulated network conditions.
#
# No Docker required: a rootless unshare(1) rig — two network namespaces joined by a veth,
# with kernel netem shaping delay / jitter / loss / reordering on BOTH egress directions.
# The gateway + glass run on one side (their link to each other stays clean), a headless
# Chromium runs on the other, so what's impaired is exactly the browser<->server path.
#
# Requirements: sbcl, python3 with playwright (chromium installed), iproute2 (tc/netem),
# a userns-with-netns-capable kernel (unshare -Urn), and:
#   CL_SOURCE_REGISTRY  so ASDF can find cl-webrtc + seal + glass   (e.g. a :tree over your repos)
#   NOVNC_DIR           a noVNC 1.7+ checkout
# Usage:  NOVNC_DIR=/path/to/noVNC CL_SOURCE_REGISTRY='(:source-registry (:tree "/path") :inherit-configuration)' ./netsim.sh [profiles.txt]
# Results (per-profile JSON + logs) land in $OUT (default /tmp/netsim-out).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
export GATEWAY="$DIR/../gateway.lisp" GLASS="$DIR/glass-run.lisp" MEASURE="$DIR/measure-netsim.py"
export PROFILES="${1:-$DIR/profiles.txt}" OUT="${OUT:-/tmp/netsim-out}"
mkdir -p "$OUT"
: "${NOVNC_DIR:?set NOVNC_DIR to a noVNC checkout}"
: "${CL_SOURCE_REGISTRY:?set CL_SOURCE_REGISTRY so ASDF finds cl-webrtc/seal/glass}"

timeout -s KILL 600 unshare -Umrn bash -c '
ip link set lo up
unshare -n sleep 1200 & BPID=$!          # side B: a keeper process holds a second netns
sleep 0.4
ip link add veth-a type veth peer name veth-b && ip link set veth-b netns $BPID
ip addr add 10.0.0.1/24 dev veth-a && ip link set veth-a up
nsenter -t $BPID -n ip addr add 10.0.0.2/24 dev veth-b
nsenter -t $BPID -n ip link set veth-b up && nsenter -t $BPID -n ip link set lo up
export ICE_LOCAL_IP=10.0.0.1
sbcl --dynamic-space-size 2048 --non-interactive --load "$GLASS"   > "$OUT/glass.log"   2>&1 &
sbcl --dynamic-space-size 2048 --non-interactive --load "$GATEWAY" > "$OUT/gateway.log" 2>&1 &
for i in $(seq 1 55); do (exec 3<>/dev/tcp/10.0.0.1/8765) 2>/dev/null && break; sleep 2; done
sleep 2; echo "== stack up =="
while IFS="|" read -r label netem; do
  [ -z "$label" ] && continue
  tc qdisc replace dev veth-a root netem $netem
  nsenter -t $BPID -n tc qdisc replace dev veth-b root netem $netem
  echo "== $label : $netem =="
  nsenter -t $BPID -n env HOME="$HOME" python3 "$MEASURE" \
    "http://10.0.0.1:8765/" "$OUT/out-$label.json" 12 | grep -aE "RESULT"
done < "$PROFILES"
kill $BPID 2>/dev/null
'
echo "results in $OUT"
