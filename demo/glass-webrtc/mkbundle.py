"""Build the phone client: extract index-nostr.html's module, bundle it, splice it back.

    python3 mkbundle.py            # SRC beside this script, BUILD from $NSITE_BUILD or ./nsite-build

Nothing machine-specific is baked in, so this can live in the repo next to the source it builds.
BUILD needs a node_modules with nostr-tools (see DEPLOY.md); it is deliberately NOT the repo, since
it holds several hundred MB of dependencies and generated artefacts.
"""
import re, subprocess, pathlib, os
HERE = pathlib.Path(__file__).resolve().parent
SRC = os.environ.get("NSITE_SRC") or str(HERE / "index-nostr.html")
BUILD = pathlib.Path(os.environ.get("NSITE_BUILD") or (HERE / "nsite-build"))
BUILD.mkdir(parents=True, exist_ok=True)
html = pathlib.Path(SRC).read_text()
m = re.search(r'<script type="module">(.*?)</script>', html, re.S)
js = m.group(1)
# point imports at the locally-installed packages (esbuild inlines them)
js = js.replace('https://esm.sh/nostr-tools@2.15.0/', 'nostr-tools/')
(BUILD/"entry.mjs").write_text(js)
# the scratchpad's .bin/esbuild is a dangling symlink; find a real binary
import shutil, glob as _glob
ESB = shutil.which("esbuild")
if not ESB:
    npx = os.path.expanduser("~/.npm/_npx")
    for c in _glob.glob(npx + "/*/node_modules/esbuild/bin/esbuild") + \
             _glob.glob(npx + "/*/node_modules/@esbuild/linux-x64/bin/esbuild"):
        if pathlib.Path(c).is_file(): ESB = c; break
r = subprocess.run([ESB, str(BUILD/"entry.mjs"),
                    "--bundle", "--format=esm", "--minify", "--platform=browser",
                    "--outfile="+str(BUILD/"bundle.js")], capture_output=True, text=True)
if r.returncode != 0:
    print("ESBUILD FAILED:\n", r.stderr[:3000]); raise SystemExit(1)
bundle = (BUILD/"bundle.js").read_text()
out = html[:m.start()] + '<script type="module">\n' + bundle + '\n</script>' + html[m.end():]
(BUILD/"nsite-index.html").write_text(out)
print("entry.mjs:", len(js), "| bundle.js:", len(bundle), "| nsite-index.html:", len(out))
print("leftover esm.sh:", out.count("esm.sh"), "| import-from-url:", len(re.findall(r'from\s*["\']https?:', out)))
