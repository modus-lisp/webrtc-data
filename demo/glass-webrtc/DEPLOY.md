# Deploying the browser client

**Read this before editing any client code.** Edit `index-nostr.html`. Everything else in the
pipeline is generated from it.

## One source, several generated files

| file | what it is | edit it? |
|---|---|---|
| `index-nostr.html` | **the source.** Both the HTML shell *and* the client script, in one `<script type="module">` | **yes** |
| `entry.mjs` (build dir) | that script body, extracted, with the `esm.sh` import rewritten to the local package | no — **overwritten on every build** |
| `bundle.js` (build dir) | `entry.mjs` run through esbuild | no — generated |
| `nsite-index.html` (build dir) | `index-nostr.html` with the bundle spliced back in place of the module body | no — generated |
| `index.html`, `index-ws.html` | older standalone pages, each with its own hand-copied gesture layer | only for local `gateway.lisp` testing |

An earlier version of this file had the relationship backwards — it named `entry.mjs` as the real
source and said `index-nostr.html` never reaches the phone. Following that would mean editing a
generated file and losing the work at the next build. The deployed blob demonstrably carries
`index-nostr.html`'s markup (its overlay and diag strings are present verbatim).

`index.html` / `index-ws.html` *are* separate copies, and the warning holds for them: a touch-layer
fix applied there has no effect on the device.

## The pipeline

```
index-nostr.html ──extract──▶ entry.mjs ──esbuild──▶ bundle.js
       │                                                 │
       └────────── shell ──────────▶ splice ◀────────────┘
                                       │
                                 nsite-index.html ──Blossom──▶ manifest (kind 15128)
                                                                └─▶ https://<site-npub>.nsite.lol/
```

## Build

```sh
cd <build-dir> && python3 mkbundle.py
```

`mkbundle.py` does the whole extract → rewrite → bundle → splice, and holds the absolute path to
`index-nostr.html`. Do not run esbuild by hand: the script also rewrites
`https://esm.sh/nostr-tools@2.15.0/` to the locally-installed package, and works around the build
dir's dangling `node_modules/.bin/esbuild` symlink by finding a real binary under `~/.npm/_npx/`.

It prints a self-check — treat a non-zero count as a failed build:

```
entry.mjs: … | bundle.js: … | nsite-index.html: …
leftover esm.sh: 0 | import-from-url: 0
```

Both must be **0**. The published page is a single self-contained blob; a surviving
`from "https://…"` means the phone would try to fetch a module at runtime from a page that has no
business making that request, and the failure appears as a blank screen with nothing in the log.

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
login links from it. It is read **once, at gateway start** (`defparameter` + `getenv`), so editing
the keepalive script is not enough — restart the gateway or it keeps handing out the old path.

## Knowing what is actually live

Editing the source, building, and publishing are three separate steps, and stopping after step one
or two leaves no visible trace. The only source of truth for what the phone gets is the blob hash:

```sh
sha256sum <build-dir>/nsite-index.html      # what you built
grep 'site hash' <publish log>              # what was published
```

If they differ, the build was never published. As of this writing they *do* differ — the build dir
holds `5337f775…` while the live `/k23.html` is `d93fd843…`, and `index-nostr.html` has been edited
again since that build. So there are two generations of changes not on the device, which is exactly
the state that produces "I fixed it but the phone still misbehaves."

Nothing warns you about this. Publishing is cheap (~50 s); when in doubt, rebuild and republish
under a new tag.

## Where the build dir is

```
/tmp/claude-1001/-home-claude-cl-consensus/<session-uuid>/scratchpad/
  mkbundle.py                 build script (holds the absolute path to index-nostr.html)
  publish.lisp                publisher (holds the site's 64-hex secret + the absolute build path)
  nsite-build/                entry.mjs, bundle.js, nsite-index.html
  node_modules/               nostr-tools, noVNC
```

The session UUID changes per session, so these paths are not stable — check `mkbundle.py`'s `SRC`
and `BUILD` constants before trusting them.

## The publisher was silently dropping events (fixed)

`publish.lisp` called `pool-publish` immediately after `make-pool`. The pool connects
**asynchronously**, so any relay whose socket was not up yet never received the event — and
`pool-publish` was called without its `:on-ok` callback, so nothing reported the loss. The script
printed `[done]` and the blob hash either way. Two publishes (`k22a`, `k24a`) were lost this way;
`k23` survived on timing luck. That is the failure mode behind "I published it and the phone still
has the old page".

Fixed in `publish.lisp` (backup alongside as `publish.lisp.bak-*`): a 3 s wait after `make-pool`,
and `:on-ok` logging so each relay's verdict is printed:

```
[manifest] wss://nos.lol accepted=T
[manifest] wss://relay.primal.net accepted=T
[manifest] wss://user.kindpag.es accepted=NIL blocked: the event doesn't match the allowed filters
```

A relay that blocks by policy is fine; **zero `accepted=T` lines means nothing was published**,
regardless of what the script prints afterwards.

## Tooling: cl-nostr, not nsyte

The gateway's 404 page suggests nsyte, but neither `nsyte` nor `deno` is installed here and there is
no nsyte config — `k23` was published with this same `publish.lisp`. So kind **15128** is the format
this site actually uses and it does work; do not switch formats to chase a 404. (Publishing legacy
kind-34128 per-path events as an experiment changed nothing — they were accepted by damus/nos.lol/
primal and the gateway still served the old build.)

## Current state — built and published, not yet served

As of this writing the pipeline is verified end to end **except** the last hop:

| stage | state |
|---|---|
| source `index-nostr.html` | has both pending fixes (committed) |
| build `nsite-index.html` | `f05ec8fc28ba0348…`, clean self-check (`esm.sh 0 / import-from-url 0`) |
| Blossom | `f05ec8fc…` fetchable, `200 text/html`, from `cdn.hzrd149.com` |
| relays | manifest accepted (`accepted=T`), and a query returns it with `path /k24a.html -> f05ec8fc…` |
| **gateway** | **still serves `d93fd843…` (k23) at `/index.html`, 404 on `/k24a.html`** |

So the manifest is live and correct on the relays; the gateway has not picked it up. Cause not
established — most likely gateway-side caching. Left for whoever deploys next: re-publish under a
fresh tag with the fixed publisher and see whether it appears; if it still does not, the question is
which relays *the gateway* reads (its view came from somewhere) rather than anything in this repo.

**Not yet on the device**, waiting on that last hop:
- scroll-lock no longer moves the cursor to the two-finger midpoint (the ring stays at the pointer,
  where it can actually be seen)
- `rfb.showDotCursor = true` so a desktop mouse user is never left with no pointer at all

**Serving the blob directly bypasses the gateway** — the page is self-contained (that is what the
build's `import-from-url 0` check guarantees), and the `#box=…&code=…` fragment is client-side:

```
https://cdn.hzrd149.com/<blob-sha256>#box=<box-npub>&code=<code>
```

Useful for testing a build before, or instead of, waiting on the gateway.

## Recommendation

Move `mkbundle.py`, `publish.lisp` and `node_modules/` into this directory (or a sibling
`client/`), and make the standalone pages import the shared gesture layer instead of copying it.
The build dir is in `/tmp` under a session-scoped path — a scratchpad cleanup takes the build
script, the publisher, **and the site key** with it. `index-nostr.html` is in the repo and would
survive; nothing else in the pipeline would.
