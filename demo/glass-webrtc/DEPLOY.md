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

The direction matters: `mkbundle.py` reads `index-nostr.html` and *writes* `entry.mjs`, so edits to
`entry.mjs` are destroyed by the next build. (The deployed blob carries `index-nostr.html`'s markup
verbatim, which is how to confirm this for yourself.)

`index.html` / `index-ws.html` are genuinely separate copies of the touch layer, so a fix applied
there has no effect on the device.

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
export NSITE_BUILD=/path/to/nsite-build   # node_modules + generated artefacts
python3 mkbundle.py
```

`mkbundle.py` does the whole extract → rewrite → bundle → splice, taking `index-nostr.html` from
beside itself (`$NSITE_SRC` overrides). Do not run esbuild by hand: the script also rewrites
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

## Shipping a change: the whole procedure

Edit, build, and publish are three separate steps, and stopping after any one of them leaves no
visible trace — the phone just keeps loading the old page. Do all six:

```sh
# 1. edit the source (the ONLY file you edit)
$EDITOR index-nostr.html

# 2. build — self-check must read "leftover esm.sh: 0 | import-from-url: 0"
export NSITE_BUILD=/path/to/nsite-build
python3 mkbundle.py

# 3. publish under a NEW tag — watch for at least one "accepted=T"
#    (needs the site key: $SITE_SEC or ~/.glass/site-key — see Secrets)
SITE_VERSION=k30 sbcl --script publish.lisp

# 4. verify all four hops; every line should say MATCH
sbcl --script check-deploy.lisp "$NSITE_BUILD/nsite-index.html"

# 5. restart the gateway.  publish.lisp already wrote site-url.env with the path it
#    published, and the keepalive sources that inside its loop — so this is all it takes
kill <gateway-pid>          # the keepalive respawns it

# 6. DM the box "link" and load the result
```

### The login link must point at the path you just published

Publishing **replaces** the manifest, so the previous `/<tag>.html` stops resolving the moment a new
build lands — and a login link minted against it 404s, which from the phone is indistinguishable
from the box being down. This has bitten twice.

`publish.lisp` writes `site-url.env` beside the gateway with the path it just published, and
`gw-keepalive.sh` sources it **inside its loop**, the same way it picks up `video-profile.env`. So a
publish plus the next gateway restart is enough and nothing has to be remembered.

Two ways to still get this wrong:

- `LOGIN_URL_BASE` is read **once, at gateway start** (`defparameter` + `getenv`), so a running
  gateway keeps handing out the old path until it restarts.
- Editing the `export` at the top of `gw-keepalive.sh` is **not enough on its own.** That line runs
  once, when the keepalive loop starts; the gateway respawns *inside* that loop and inherits the
  environment the loop already has. The symptom is a script that reads `k27` while the live process
  serves `k25`. Restart the keepalive, not just the gateway — or let `site-url.env` do it.

`@@ [keepalive] link=…` is printed on every start, so the log says which path is being handed out.

`check-deploy.lisp` (in this directory) walks build → Blossom → relays → gateway and prints what
each hop holds, so the first mismatch names the broken hop. It is read-only and needs no secret:

```
[build]   f05ec8fc28ba0348  …/nsite-index.html
[blossom] https://cdn.hzrd149.com    http 200 f05ec8fc28ba0348  MATCH
[relays]  kind 15128  /k24a.html -> f05ec8fc28ba0348  MATCH
[gateway] /index.html    http 200  d93fd8435746fca4  *** STALE — serving an older build ***
```

## Delivering the page: two URLs

| URL | current? | notes |
|---|---|---|
| `https://<site-npub>.nsite.lol/<tag>.html` | **only if the gateway has caught up** | the nice URL; stable origin, so an enrolled device key persists |
| `https://cdn.hzrd149.com/<blob-sha256>` | **always** | the blob itself, straight from Blossom |

The blob URL works because the published page is entirely self-contained — that is exactly what the
build's `import-from-url 0` check guarantees — and because `#box=…&code=…` is a client-side
fragment. Use it whenever the gateway is stale, or to test a build before publishing at all.

One consequence worth knowing: the blob URL is a **different origin**, so `localStorage` starts
empty there and the phone's enrolled device key does not carry over. It re-enrols on first connect
using the code in the link, which is invisible in practice — but it does mean the box will show a
second enrolled terminal for that phone.

## If the gateway will not pick it up

This has happened, and it is not something this repo can fix. What was established:

- the blob was on **both** Blossom servers, fetchable by hash, `200 text/html`
- the kind-15128 manifest was on nos.lol and relay.primal.net, naming the new blob for `/`,
  `/index.html` and `/<tag>.html`
- the site's own kind-10002 list names damus / nos.lol / primal — so a gateway following it would
  find the manifest
- the gateway nonetheless served a blob it had cached **14 hours earlier**, with
  `cache-control: max-age=3600` and a matching stale `etag`, and returned 404 for the new path
  (the signature of a cached *manifest*: it is answering from an older file list)

So: relays fine, Blossom fine, gateway stuck. **Do not switch event kinds to chase it.** Publishing
the legacy kind-34128 per-path events as an experiment changed nothing — they were accepted by
damus/nos.lol/primal, pointed at the correct blob, and the gateway still served the old build.

Fall back to the blob URL and move on. `nsite.gs` did not resolve when tried as an alternate
gateway; if another public nsite gateway is available it is worth a try, since the manifest is
already correct and public.

## Secrets

Nothing in this repo contains a key. Two secrets matter, and both are resolved at runtime:

| secret | where it lives | used by |
|---|---|---|
| site key (64 hex) | `$SITE_SEC`, else `~/.glass/site-key` (mode 600) | `publish.lisp` |
| TURN user/pass, box nsec | `gw-keepalive.sh` on the box (gitignored) | the gateway |

`publish.lisp` **refuses to run** if it cannot resolve the site key — it does not fall back to
anything. That key is the site's whole identity: whoever holds it can replace every page served at
that npub. It is deliberately single-copy; back it up somewhere you trust, because losing it means
the npub in every link you have handed out can never be updated again.

## Where the build dir is

`mkbundle.py` and `publish.lisp` live **in this directory**, in the repo, and bake in no paths:

```sh
export NSITE_BUILD=/path/to/nsite-build     # holds node_modules + generated artefacts
python3 mkbundle.py                          # SRC defaults to index-nostr.html beside the script
SITE_VERSION=k30 sbcl --script publish.lisp  # reads NSITE_BUILD too, or takes a path as argv
```

Only the build directory is outside the repo, because it carries a few hundred MB of
`node_modules` plus generated output. It needs `nostr-tools` installed (`npm install
nostr-tools@2.15.0`); a `/tmp` cleanup has eaten it before, and the symptom is
`Could not resolve "nostr-tools/pure"` with the **output hash unchanged** — so the publish that
follows would ship the previous build without a word.

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
primal and the gateway still served the old build — see "If the gateway will not pick it up".)

## Recommendation

Make the standalone pages (`index.html`, `index-ws.html`) import the shared gesture layer instead
of keeping hand-copied versions of it.
