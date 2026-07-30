# Deploying the browser client

**Read this before editing any client code.** The page your phone loads is *not* built from
the `index*.html` files in this directory.

## Two sources, one of them deployed

| file | what it is | reaches the phone? |
|---|---|---|
| `index.html`, `index-ws.html`, `index-nostr.html` | standalone pages; each carries its own copy of the gesture/cursor layer | **no** — only if you open them directly (local HTTP, `gateway.lisp`) |
| `entry.mjs` (in the nsite build dir, see below) | the real client source: ES module, `import`s noVNC + nostr-tools | **yes** — bundled, published, loaded from `…nsite.lol` |

The touch layer (cursor ring, hold-to-right-click, two-finger scroll-lock, pan/zoom) exists in
**both**, copied by hand. Editing one does not change the other. A fix applied only to
`index*.html` will look correct in the repo and have no effect on the device — this has already
happened once.

## The pipeline

```
entry.mjs ──esbuild──▶ bundle.js ──inline──▶ nsite-index.html ──Blossom──▶ nsite manifest (kind 15128)
                                                                            └─▶ https://<site-npub>.nsite.lol/
```

`nsite-index.html` is a ~2.2 KB HTML shell (viewport meta, CSS, `<script type="module">`) with the
bundle inlined as the script body — the script body is byte-identical to `bundle.js`.

## Build

The build dir (`entry.mjs`, `node_modules/`, `nsite-index.html`) currently lives in a scratchpad
outside this repo; `publish.lisp` sits beside it and holds the absolute path. Its local
`node_modules/.bin/esbuild` symlink is **broken** (package removed) — use any esbuild 0.28+:

```sh
cd <build-dir>
esbuild entry.mjs --bundle --minify --format=esm --outfile=bundle.js
```

`--format=esm` is required: the shell's script tag is `type="module"`. Sanity check: the bundle is
~295 KB; a wildly different size means wrong flags. Then splice it into the shell, replacing the
existing `<script>` body (keep the shell — do not regenerate it).

## Publish

```sh
SITE_VERSION=<tag> sbcl --script publish.lisp
```

It uploads the HTML to the Blossom servers (one success is enough — `nostr.download` often times
out), then publishes the nsite manifest mapping `/<tag>.html`, `/index.html` and `/` to that blob,
plus relay (10002) and server (10063) lists. The site key is a 64-hex secret in `publish.lisp` —
publishing rewrites the whole site's root, so treat it as a deploy, not a test.

**Always bump `SITE_VERSION` and hand out `/<tag>.html`.** A query string (`/?v=…`) resolves to the
same path in the manifest, so the browser is free to serve its cached copy — that is why `?v=`
never busted anything. A new path cannot be mistaken for the previous build.

Keep `LOGIN_URL_BASE` (in the gateway's keepalive env) pointing at a path that exists; the box mints
login links from it.

## Recommendation

Move `entry.mjs` (and a small build script) into this directory and make the standalone pages import
the shared gesture layer instead of copying it. The build dir is in `/tmp` — a scratchpad cleanup
would take the only copy of the deployed client's source with it.
