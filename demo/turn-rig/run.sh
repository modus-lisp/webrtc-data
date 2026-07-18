#!/bin/bash
# run.sh — TURN integration proof: aiortc (relay-only ICE) <-> webrtc-data over a TURN relay.
#
# Both peers use the same TURN server (turn-server.py).  aiortc is forced to TransportPolicy.RELAY
# so the ONLY candidate pair it will try is relay<->relay.  Two arms:
#   relay      — answerer advertises a relay candidate  -> expect CONNECTED (full stack over relay)
#   srflx-only — answerer advertises NO relay candidate  -> expect NO CONNECT (nothing to pair)
set -u
RIG="$(cd "$(dirname "$0")" && pwd)"
: "${CL_SOURCE_REGISTRY:=(:source-registry (:tree \"/home/claude\") :inherit-configuration)}"
export CL_SOURCE_REGISTRY
DIR=$(mktemp -d /tmp/turn-int.XXXXXX)
export TURN_DIR="$DIR/"
TURN_SERVER=127.0.0.1:3478 ; TURN_USER=webrtc ; TURN_PASS=secret
export TURN_SERVER TURN_USER TURN_PASS

# fresh TURN server
python3 "$RIG/turn-server.py" 127.0.0.1 3478 127.0.0.1 "$TURN_USER" "$TURN_PASS" webrtc-data.test \
    >"$DIR/turn.log" 2>&1 &
TURN_PID=$!
sleep 1

run_arm(){
  MODE="$1"; EXPECT="$2"
  echo; echo "=== ARM: $MODE (expect $EXPECT) ==="
  rm -f "$DIR/offer.sdp" "$DIR/answer.sdp"
  # Answerer starts first and blocks waiting for offer.sdp.
  RELAY_MODE="$MODE" ICE_LOCAL_IP=192.0.2.1 \
    sbcl --dynamic-space-size 1024 --non-interactive --load "$RIG/integration-answerer.lisp" \
    >"$DIR/ans-$MODE.log" 2>&1 &
  ANS_PID=$!
  sleep 8   # let SBCL finish loading before the offerer writes offer.sdp
  # Offerer writes offer.sdp (answerer proceeds -> writes answer.sdp) then drives to connect.
  RIG_TIMEOUT=25 python3 "$RIG/integration-offerer.py" >"$DIR/off-$MODE.log" 2>&1
  RC=$?
  grep -aE "RESULT:|candidates:|typ relay|conn-state:|ice-state:" "$DIR/off-$MODE.log" | sed 's/^/@@ off: /'
  grep -aE "relay=|DTLS HANDSHAKE|ANSWERER FAILED|SCTP loop" "$DIR/ans-$MODE.log" | sed 's/^/@@ ans: /'
  kill $ANS_PID 2>/dev/null; wait $ANS_PID 2>/dev/null
  sleep 1
  if [ $RC -eq 0 ]; then echo "@@ >>> $MODE: CONNECTED"; else echo "@@ >>> $MODE: NO CONNECT"; fi
  echo "$MODE $RC" >> "$DIR/results.txt"
}

# The offerer writes offer.sdp then waits for answer.sdp; the answerer waits for offer.sdp.
# So we must start the offerer to produce offer.sdp before the answerer can proceed. Do that by
# launching the offerer in run_arm; but the answerer is launched first and blocks on offer.sdp —
# fine, it just waits. However the answerer must exist before offer/answer round-trips. The order
# above (answerer bg, then offerer) works: answerer blocks until offer.sdp appears (offerer writes
# it immediately on start).

run_arm relay      "CONNECTED"
run_arm srflx-only "NO CONNECT"

echo; echo "=== SUMMARY ==="
R=$(awk '/^relay /{print $2}' "$DIR/results.txt")
S=$(awk '/^srflx-only /{print $2}' "$DIR/results.txt")
[ "${R:-1}" = 0 ] && echo "@@ relay:      CONNECTED (over TURN relay)" || echo "@@ relay:      NO CONNECT (UNEXPECTED)"
[ "${S:-0}" != 0 ] && echo "@@ srflx-only: NO CONNECT (no relay candidate to pair — expected)" || echo "@@ srflx-only: CONNECTED (UNEXPECTED)"

kill $TURN_PID 2>/dev/null
echo "logs in $DIR"
