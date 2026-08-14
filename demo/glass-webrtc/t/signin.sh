#!/bin/bash
# t/signin.sh — build the real client into /tmp, then drive it in a real headless Chromium.
#
# Same shape as warp's t/browser.sh and t/panel.sh: everything it makes and everything it writes is
# under /tmp, it binds only free ports, and THE GATEWAY IS NEVER LOADED, STARTED OR CONTACTED —
# loading gateway-nostr.lisp would subscribe to three relays as the box's own identity and race the
# session somebody is using.  The gateway's half of this change is asserted from its TEXT, in
# admission-test.lisp.
#
# The build goes to a /tmp dir with node_modules symlinked out of the real one, so a test run never
# touches the artefacts a publish would ship.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/.." && pwd)"
out="${GLASS_SIGNIN_OUT:-/tmp/glass-signin-out}"
build="${GLASS_SIGNIN_BUILD:-/tmp/glass-signin-build}"
real="${NSITE_BUILD:-/home/claude/nsite-build}"
mkdir -p "$out" "$build"

[ -d "$real/node_modules/nostr-tools" ] || {
  echo "no nostr-tools in $real/node_modules — see DEPLOY.md, \"Where the build dir is\""; exit 1; }
ln -sfn "$real/node_modules" "$build/node_modules"
[ -d "$real/novnc" ] && ln -sfn "$real/novnc" "$build/novnc"

esb="$(command -v esbuild || true)"
if [ -z "$esb" ]; then
  for c in "$real"/node_modules/esbuild/bin/esbuild \
           /home/claude/.npm/_npx/*/node_modules/esbuild/bin/esbuild \
           /home/claude/.npm/_npx/*/node_modules/@esbuild/linux-x64/bin/esbuild; do
    [ -f "$c" ] && esb="$c" && break
  done
fi
[ -n "$esb" ] || { echo "no esbuild binary found (see DEPLOY.md)"; exit 1; }

echo "== building the client (the same mksplit.py a publish runs) =="
NSITE_BUILD="$build" python3 "$src/mksplit.py"

echo "== bundling the box and the signer =="
cp "$here/box.entry.mjs" "$here/signer.entry.mjs" "$build/"
(cd "$build" && "$esb" box.entry.mjs --bundle --format=iife --minify \
     --platform=browser --outfile=box.js >/dev/null)
(cd "$build" && "$esb" signer.entry.mjs --bundle --format=iife --global-name=NSIGNER --minify \
     --platform=browser --outfile=signer.js >/dev/null)

GLASS_SIGNIN_OUT="$out" python3 "$here/signin.py" "$build"
