# Deploying the browser client

**Read this before editing any client code.**

There are now **two clients in this directory**, and which one you are shipping decides everything
else on this page:

| | source | built by | how a change ships |
|---|---|---|---|
| **single page** (deployed today, k39) | `index-nostr.html` | `mkbundle.py` | edit → build → **publish under a new tag** → check-deploy → re-point `site-url.env` → restart the gateway → hand out a new URL |
| **split** (built, tested, **not deployed**) | `index-shell.html` + `shell.js` + `payload.js` | `mksplit.py` | edit `payload.js` → build → `cp payload.js* ` beside the gateway → **the user reloads the same URL** |

The split exists because the second row is the whole point: four publishes happened in one day
(k36→k39) and every one of them was a change to code that only matters after the connection is up.
See "The split client" below. Until the shell is published, **the first row is what is live** and
this page's original instructions are the ones that apply.

## The single-page client

Edit `index-nostr.html`. Everything else in that pipeline is generated from it.

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
SITE_VERSION=<tag> sbcl --script publish.lisp "$NSITE_BUILD/nsite-index.html"
```

**Pass the file path.** `$NSITE_BUILD` means two different things to the two scripts and this is the
trap: `mkbundle.py` reads it as the build **directory**, `publish.lisp` reads it as the **artefact
path** (`*path*` is argv, then `$NSITE_BUILD` verbatim, then `nsite-build/nsite-index.html` beside
the script). So `NSITE_BUILD=/path/to/nsite-build sbcl --script publish.lisp` hands `read-bytes` a
directory and dies. Give the file as argv — that is the only form that is right for both scripts.

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
#    NOTE the argv: publish.lisp wants the FILE, not the build dir.  See Publish.
SITE_VERSION=k30 sbcl --script publish.lisp "$NSITE_BUILD/nsite-index.html"

# 4. verify all four hops; every line should say MATCH
sbcl --script check-deploy.lisp "$NSITE_BUILD/nsite-index.html"

# 5. publish.lisp has just OVERWRITTEN site-url.env with an nsite.LOL url.  While nsite.lol is
#    serving a stale manifest (see "Delivering the page"), re-point that line at nsite.run —
#    otherwise the next gateway start hands out a link that 404s.
$EDITOR site-url.env

# 6. restart the gateway.  The keepalive sources site-url.env inside its loop, so this is all
#    it takes — but LOGIN_URL_BASE is read once at gateway start, so it does take this.
kill <gateway-pid>          # the keepalive respawns it

# 7. DM the box "link" and load the result
```

Steps 5 and 6 are only needed for the *login link*. A device that has connected before keeps the
box npub in `localStorage`, so handing it the bare `https://<npub>.nsite.run/<tag>.html` (no
`#box=…&code=…` fragment) is enough on its own — which is the way to ship a build without
touching a running gateway.

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
| `https://<site-npub>.nsite.run/<tag>.html` | **yes — use this one** | resolves the current manifest; stable origin, so an enrolled device key persists |
| `https://<site-npub>.nsite.lol/<tag>.html` | **no** | still answering from a manifest it cached days ago |
| `https://cdn.hzrd149.com/<blob-sha256>` | **always** | the blob itself, straight from Blossom |

**Verify on nsite.run, not nsite.lol.** nsite.lol has been serving a stale manifest for several
builds running: `/<newtag>.html` 404s there while `/index.html` returns the *previous* build with a
200, which is the worse of the two failures because it looks like a success. Re-measured each
deploy since k32; still true at k34:

```
nsite.lol /k33.html  -> 404      nsite.run /k33.html  -> 200, current bytes
nsite.lol /index.html-> 200, OLD build
```

`publish.lisp` writes the nsite.lol host into `site-url.env` regardless, so that file needs
re-pointing after every publish until nsite.lol catches up (step 5 above).

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

---

# The split client

**Status: built, tested, committed, NOT deployed.** Nothing about the running system changes until
somebody publishes the shell and sets `PAYLOAD_CHANNEL` on the box. Both halves of that are listed
under "Deploying the split" below.

## Why

Publishing **replaces** the nsite manifest, so every client change costs a new tag, a publish, a
check-deploy, a re-pointed `site-url.env`, a gateway restart and a user reloading at a *different*
URL. That is a heavy price for moving a button, and it was paid four times in one day.

But most of the client cannot possibly need to be on nsite. Split it at the only line that is
actually forced — **can this code arrive over the connection it is used to set up?**

| | what | where | size |
|---|---|---|---|
| **shell** | nostr-tools, the PeerConnection and all four channels, credentials, the progress screen, the link pill, error reporting, the desktop-name display | nsite | 109 KB raw / **~36 KB** over the wire |
| **payload** | noVNC, the trackpad, the modifier row, paste, the quality ladder, the warp panel, the debug overlay, the getStats poll | **the box, over data channel 104** | 229 KB raw / **71 KB** gzipped on the channel |

Today's single page is 330 KB raw / **97 KB** over the wire (the CDN serves it brotli'd — the raw
number is not what anyone downloads). So the shell is **37% of what nsite serves today**, and
noVNC — 61% of the old bundle on its own — never touches nsite again.

## Build

```sh
export NSITE_BUILD=/path/to/nsite-build     # needs node_modules AND a ./novnc symlink
python3 mksplit.py
```

Four artefacts, and the self-check must read `leftover esm.sh: 0 | import-from-url: 0`:

```
nsite-shell.html    -> publish this to nsite (self-contained; the shell module is spliced in)
payload.js          -> goes beside the gateway
payload.js.gz       -> ditto; the gateway prefers it when the browser can inflate
standalone.html     -> both halves in one page, no channel involved
```

`standalone.html` is the escape hatch and is worth knowing about: publishing it puts you exactly
where the single-page client is today, **from the same sources**, with no second copy of the client
to keep in step. It is also the way to test a payload change without a box.

## Shipping a payload change

This is the entire procedure, and it is the reason the split exists:

```sh
$EDITOR payload.js
python3 mksplit.py
cp "$NSITE_BUILD"/payload.js "$NSITE_BUILD"/payload.js.gz  <beside the gateway>
# ...and the user reloads the SAME url.
```

**No publish, no new tag, no `site-url.env`, and no gateway restart** — the gateway re-reads the
file when its mtime changes (`payload-bytes` in `payload-channel.lisp`). The phone asks for the
payload by hash on every connection, sees a hash it does not have, and fetches it.

## Shipping a shell change

Exactly the old procedure — build with `mksplit.py`, publish `nsite-shell.html` under a new tag,
check-deploy, re-point `site-url.env`, restart the gateway. **This is what the split is for
avoiding**, so the question to ask first is always whether the change can be made in `payload.js`
instead.

The shell's API is **append-only**, and that is what keeps the answer to that question "yes":

* `SHELL_API` (in `shell.js`) increments whenever a member is **added** to the `api` object;
* `payload.js` exports `needs` — the lowest `SHELL_API` it can run against;
* the shell runs the payload iff `needs <= SHELL_API`, and otherwise says so on screen and stays in
  view-only mode rather than half-running it.

So a payload built against API 1 runs on every shell that will ever exist. **Adding** to `api` is
free — an old payload does not reach for the new member. **Removing or redefining** a member is the
only change that forces a new shell onto nsite, and it is checkable: it is a diff of one object.

## Deploying the split

Both halves are needed; either one alone is a no-op:

1. **Publish the shell.** `SITE_VERSION=<tag> sbcl --script publish.lisp "$NSITE_BUILD/nsite-shell.html"`,
   then `check-deploy.lisp`, then re-point `site-url.env` at nsite.run, then restart the gateway so
   `LOGIN_URL_BASE` picks up the new path. (All the usual traps on this page still apply.)
2. **Put the payload on the box** and set **`PAYLOAD_CHANNEL=1`** in `gw-keepalive.sh`, plus
   `PAYLOAD_FILE` if it is not `payload.js` beside the gateway. Restart the gateway.

Order does not matter, and neither step breaks the other's absence:

* shell published, box without `PAYLOAD_CHANNEL` → the box answers `none`, and the phone shows the
  desktop **view-only** with "This desktop is not serving the client" and a Retry button;
* box serving, phones still on the old single page → nothing ever sends on stream 104, so the
  channel is byte-for-byte absent.

## The one real cost: there are now two copies of the client

`payload.js` was lifted out of `index-nostr.html` and carries the same gesture layer, modifier row,
quality ladder and warp panel — so **a fix applied to one does not reach the other**, which is
exactly the complaint this file already makes about `index.html` and `index-ws.html`.

That is tolerable only because it is meant to be temporary. **Once the shell is deployed and has
run for a while, delete `index-nostr.html` and `mkbundle.py`**: `standalone.html` is the same page,
built from the split sources, so nothing is lost by retiring the monolith. Until then, a change that
matters to both has to be made in both, and the `.gbtn`/`#mods`/`#warpPanel` CSS lives in
`payload.js` on one side and in `index-nostr.html`'s `<style>` on the other.

## Tests

```sh
sbcl --dynamic-space-size 2048 --non-interactive --load payload-channel-test.lisp
```

40 assertions over the gateway side — the stream-id gate, the file read and hash, the cache answer,
the chunking, the duplicate-hello guard, the close — plus the five added lines in
`gateway-nostr.lisp` checked against its **text**. It does not start a gateway and writes only to
`/tmp`, for the reasons in `warp-channel-test.lisp`'s header.

The browser half (a real data channel, the blob import under the real nsite CSP, the seam, the
cache, the fallback, the version contract) is a Playwright harness that was run out of tree; see
the report in the commit message for what it covered.

## Recommendation

Make the standalone pages (`index.html`, `index-ws.html`) import the shared gesture layer instead
of keeping hand-copied versions of it.
