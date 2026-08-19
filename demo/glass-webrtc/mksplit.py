"""Build the split client: a small stable SHELL for nsite, and a PAYLOAD the box serves.

    python3 mksplit.py            # sources beside this script, BUILD from $NSITE_BUILD or ./nsite-build

`mkbundle.py` builds the single-page client from index-nostr.html and still works; this builds the
two-part one from index-shell.html + shell.js + payload.js.  See DEPLOY.md.

WHAT COMES OUT, and why there are three artefacts rather than two:

    nsite-shell.html    the page published to nsite.  Self-contained: the shell module is SPLICED
                        IN, replacing the <script src="./shell.js"> placeholder, for exactly the
                        reason mkbundle.py does the same thing — a published page that fetches a
                        second file at runtime is a blank screen with nothing in the log.

    payload.js          what the gateway serves over data channel 104.  Goes beside the gateway;
                        PAYLOAD_FILE overrides where it looks.
    payload.js.gz       the same, gzipped.  The gateway prefers it when the browser says it can
                        inflate (every browser with DecompressionStream, which is iOS 16.4+), and
                        falls back to the raw file otherwise.  COMPRESSION IS DONE HERE rather than
                        in the gateway on purpose: the gateway has no deflate in its image, and
                        adding one to a process that is supervised by a respawn loop is a much
                        worse trade than writing a second file at build time.

    standalone.html     shell and payload in ONE page, both inline, no data channel involved.
                        This is the escape hatch and it is worth the twenty lines: if the payload
                        channel is ever the problem, publishing this puts you exactly where the
                        single-page client was, from the same sources, with no second copy of the
                        client to keep in step.  It is also the easiest way to test a payload
                        change in a browser without a box.

The self-check at the end is the same one mkbundle.py prints and means the same thing: a non-zero
count is a failed build.
"""
import re, subprocess, pathlib, os, gzip, hashlib, shutil, glob as _glob

HERE = pathlib.Path(__file__).resolve().parent
BUILD = pathlib.Path(os.environ.get("NSITE_BUILD") or (HERE / "nsite-build"))
BUILD.mkdir(parents=True, exist_ok=True)

ESB = shutil.which("esbuild")
if not ESB:
    npx = os.path.expanduser("~/.npm/_npx")
    for c in _glob.glob(npx + "/*/node_modules/esbuild/bin/esbuild") + \
             _glob.glob(npx + "/*/node_modules/@esbuild/linux-x64/bin/esbuild"):
        if pathlib.Path(c).is_file():
            ESB = c
            break
if not ESB:
    raise SystemExit("no esbuild binary found (see DEPLOY.md)")


def bundle(src_text, name):
    """esbuild one module, from the BUILD dir so node_modules and ./novnc resolve."""
    entry = BUILD / (name + ".entry.mjs")
    out = BUILD / (name + ".bundle.js")
    # point the esm.sh imports at the locally-installed package (esbuild inlines them)
    entry.write_text(src_text.replace("https://esm.sh/nostr-tools@2.15.0/", "nostr-tools/"))
    r = subprocess.run([ESB, str(entry), "--bundle", "--format=esm", "--minify",
                        "--platform=browser", "--outfile=" + str(out)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("ESBUILD FAILED (%s):\n" % name, r.stderr[:3000])
        raise SystemExit(1)
    return out.read_text()


shell_src = (HERE / "shell.js").read_text()
payload_src = (HERE / "payload.js").read_text()
page = (HERE / "index-shell.html").read_text()

shell_js = bundle(shell_src, "shell")
payload_js = bundle(payload_src, "payload")

# ---- the nsite page: splice the shell in place of its placeholder tag ----------------------------
TAG = re.compile(r'<script type="module" src="\./shell\.js"></script>')
if not TAG.search(page):
    raise SystemExit('index-shell.html: could not find the <script src="./shell.js"> placeholder')
shell_page = TAG.sub(lambda _: '<script type="module">\n' + shell_js + '\n</script>', page)
(BUILD / "nsite-shell.html").write_text(shell_page)

# ---- the payload, as the gateway will serve it ---------------------------------------------------
(BUILD / "payload.js").write_text(payload_js)
raw = payload_js.encode()
# mtime=0 so an unchanged payload produces an identical file — the gateway hashes what it reads, and
# a hash that changed because a timestamp changed would push a pointless transfer to every phone.
gz = gzip.compress(raw, 9, mtime=0)
(BUILD / "payload.js.gz").write_bytes(gz)

# ---- standalone: both halves inline, no channel ---------------------------------------------------
# The payload module is inlined as a second module that calls init() against window.__glass, which is
# exactly what the loader does with the blob — so this exercises the same seam, minus the transport.
#
# Bundled from a WRAPPER ENTRY rather than by appending `await init(...)` to the payload bundle.
# That reads like a pointless extra step and is not: esbuild minifies the exported binding to a
# short name and re-exports it (`export { Hc as init }`), so `init` is not in scope in the emitted
# code and the appended call fails with "init is not defined" — at load, on the page that exists to
# be the safe fallback.  Importing it by name makes esbuild resolve it.
#
# `__glassPayloadInline` is what stops the shell ALSO asking the box for a copy — see askPayload.
# It is set before the shell module runs, because the shell reads it when channel 104 opens.
inline_js = bundle('import { init } from %r;\nawait init(window.__glass);\n'
                   % str(HERE / "payload.js"), "inline")
standalone = TAG.sub(
    lambda _: ('<script>window.__glassPayloadInline = true;</script>\n'
               '<script type="module">\n' + shell_js + '\n</script>\n'
               '<script type="module">\n' + inline_js + '\n</script>'),
    page)
(BUILD / "standalone.html").write_text(standalone)

sha_raw, sha_gz = hashlib.sha256(raw).hexdigest(), hashlib.sha256(gz).hexdigest()
print("nsite-shell.html: %d  (shell bundle %d)" % (len(shell_page), len(shell_js)))
print("payload.js:       %d  sha256 %s" % (len(raw), sha_raw[:16]))
print("payload.js.gz:    %d  sha256 %s  (%.0f%% of raw)" % (len(gz), sha_gz[:16], 100.0 * len(gz) / len(raw)))
print("standalone.html:  %d" % len(standalone))
print("leftover esm.sh:", shell_page.count("esm.sh") + payload_js.count("esm.sh"),
      "| import-from-url:", len(re.findall(r'from\s*["\']https?:', shell_page + payload_js)))
