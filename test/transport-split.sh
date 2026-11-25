#!/bin/sh
# test/transport-split.sh — the :webrtc EXPOSE server on ONE Lisp, the calling side on SBCL,
# in separate processes, over loopback.  Exits 0 iff both sessions echoed and the closer ended
# every session.  SERVER_CMD runs the server file (default: sbcl --script), e.g.
#   SERVER_CMD="modus --script" test/transport-split.sh
# (on modus CL_SOURCE_REGISTRY must be a form: (:source-registry (:tree "...") ...)).
# CLIENT_CMD likewise for the client (default: sbcl --script).
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/webrtc-split.XXXXXX")
export PORT_FILE="$tmp/port" STOP_FILE="$tmp/stop"
${SERVER_CMD:-sbcl --script} "$here/transport-split-server.lisp" > "$tmp/server.log" 2>&1 &
spid=$!
i=0; while [ ! -s "$PORT_FILE" ] && [ $i -lt 1500 ]; do sleep 1; i=$((i+1)); done
${CLIENT_CMD:-sbcl --script} "$here/transport-split-client.lisp" > "$tmp/client.log" 2>&1
touch "$STOP_FILE"; wait $spid
cat "$tmp/client.log" | grep -E "session|CLIENT"; grep -E "closer" "$tmp/server.log"
if grep -q "CLIENT 2/2" "$tmp/client.log" && grep -q "closer: ok" "$tmp/server.log"; then
  echo "transport-split: PASS"; rm -rf "$tmp"; exit 0
else
  echo "transport-split: FAIL (logs in $tmp)"; exit 1
fi
