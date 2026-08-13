# glass over WebRTC — how it works, and how to stand it up

`DEPLOY.md` covers publishing the web client. This covers everything else: what the pieces
are, how a phone reaches a desktop, and what someone starting from an empty machine has to do.

**`README.md` in this directory is stale** — it documents the retired `gateway.lisp` (hunchentoot,
`POST /signal`, port 8765). That path still works and is the shortest way to see the system run
locally (see "The short path"), but it is not what serves the live desktop.

---

## 1. The shape of it

Two long-lived processes, and no inbound port on either.

```
gw-keepalive.sh                       supervisor: re-sources config, respawns forever
  └─ sbcl … gateway-nostr.lisp        signalling + WebRTC + encode.  NO listening TCP port.
       ├─ out: wss to 3 Nostr relays          (OFFERS only — commands are the desktop's)
       ├─ out: UDP to STUN, and to coturn     (media)
       └─ out: TCP to the desktop  :5903 RFB (twice) · :5913 audio · :5914 mic · :5915 admission

sbcl … desktop-5903.lisp              the glass desktop.  NOT supervised by anything.
       ├─ 0.0.0.0:5903    RFB
       ├─ 127.0.0.1:5913  session audio mix out
       ├─ 127.0.0.1:5914  peer microphone in
       ├─ 127.0.0.1:5915  admission: who may open this desktop  (:glass/nostr)
       └─ out: wss to 3 Nostr relays          (the DM command bot)
```

**The identity, the enrolment store and the DM command surface are the DESKTOP's** (§2.1). They
used to be the gateway's, which meant the box stopped answering DMs in exactly the situation you
would DM it — the gateway restarts on every config change, respawns on every crash, and crashloops
on a missing `NOSTR_SEC`. The desktop stays up for days.

The browser is served as a static page from an **nsite** gateway (Nostr + Blossom), so there is no
web server either. The consequence worth internalising: **nothing here needs a port forwarded, a
DNS record, or a TLS certificate.** The only public infrastructure is a TURN server, and that is
only needed for clients behind symmetric NAT (i.e. cellular).

---

## 2. Signalling and the DM bot

Everything — signalling *and* administration — rides **NIP-59 gift wrap (kind 1059)**. There is no
NIP-04 anywhere. The gateway subscribes to `kinds:(1059) #p:(box-pubkey)` and unwraps with
`cl-nostr.nip59:unwrap-giftwrap`, which yields the **verified seal signer** — a forged rumour pubkey
is rejected before the gateway sees it.

Relays default to `relay.damus.io`, `nos.lol`, `relay.primal.net` (`NOSTR_RELAYS` overrides). Fan-out
means one offer arrives three or more times; duplicates are dropped by wrap event id.

### 2.1 Commands — answered by the desktop, not by the gateway

**The four commands live in glass**, in `:glass/nostr` (`glass/src/nostr.lisp`), together with the
enrolment store, the token mint and the allowlist. Both processes subscribe to the same box pubkey
for kind 1059; they split the traffic by size, and the split is total: a command is a DM of **≤80
characters** and an SDP offer is thousands. The gateway answers offers and says nothing else.

That split is a **swap and not an addition**. If the gateway still answered `link` while the desktop
also did, every request would get two magic links from two processes. `admission-test.lisp` asserts
by reading the gateway's own source that its command surface is gone.

| command | effect | who |
|---|---|---|
| `link` | mint a token, reply with a full magic link | allowlist or enrolled device |
| `devices` | list enrolled terminals with expiries | allowlist only |
| `revoke <prefix\|all>` | drop an enrolment | allowlist only |
| `help` / `?` | usage | allowlist or device |

`devices` and `revoke` are allowlist-only **on purpose**: a device key is a bearer credential that
can be lifted out of a browser, and it must not be able to keep itself alive, revoke the others, or
enumerate the fleet.

A denied command produces **no reply at all**, only a local log line — an answer would tell an
unknown sender that the box is here, is listening, and understood them. That silence is why the
browser has its own fallback (below).

The desktop also ignores a command whose rumour is older than `*NOSTR-COMMAND-MAX-AGE*` (600 s).
The gateway never had that guard, so restarting it could re-answer a `link` from hours ago in the
relay backlog with a fresh live credential.

### 2.2 Three ways in — and the gateway asks, it does not decide

Checked in this order, **by the desktop**, and the first match wins:

1. **code** — a valid unexpired login token in the offer envelope. Valid for its own TTL.
2. **allowlist** — `NOSTR_ALLOW` (`GLASS_NOSTR_ALLOW` overrides). Permanent.
3. **device** — a browser enrolled after arriving on a valid code. `DEVICE_TTL`
   (`GLASS_DEVICE_TTL`), default 24 h, **renewed on every connection**, persisted to
   `.glass-devices` — **the desktop's copy**, `GLASS_DEVICE_FILE`, default `~/.glass-devices`.

A code authorises *independently of the allowlist*, and any admitted connection enrols the caller as
a device. One leaked link is therefore durable access until someone runs `revoke`.

The gateway makes **one call per offer**:

```
glass:admission-admit <pubkey> <code>   →  via / token / devices-count
```

which decides, enrols or renews, and mints the renewal token that rides back in the answer — all on
the desktop, in one round trip on loopback. The gateway keeps no store, no allowlist and no mint.

**It fails closed.** No answer from `:5915` means no admission, counted, with a log line that names
the port. The reasoning, written out beside `ASK-ADMISSION`: **the desktop is already a hard
dependency** — `RUN-SESSION` opens `GLASS-CONNECT` to `:5903` with no `ignore-errors`, so a peer
admitted while the desktop is down gets a session that dies the instant its data channel opens, and
everything they connected *for* (screen, mix, microphone) is that same process. A fallback store
would buy nothing real and would cost the whole point of the move: two writers, drifting.

The cost to accept: **a desktop running without `:glass/nostr` admits nobody.** That is the same
posture as a gateway with no `NOSTR_SEC`, which already crashloops rather than serve as nobody, and
the gateway says so in one line at startup (`@@ admission: … NOT ANSWERING`).

`NOSTR_ALLOW` accepts npub, 64-hex, or a NIP-05 `name@domain`. The desktop can re-read it at run
time — `(glass:refresh-nostr-allow)` over the control socket — where the gateway resolved it once at
start inside `ignore-errors` and failed open-to-empty on a transient DNS failure.

### The admission protocol (`:5915`)

Text-framed like its neighbours on 5913/5914, so `nc` is a diagnostic:

```
client → server   glass-admit/1 <verb> [k=v …]
server → client   glass-admit/1 ok   [k=v …] [rows=<n>]   then n body lines
                  glass-admit/1 deny reason=<why>
                  glass-admit/1 err  reason=<why>

$ printf 'glass-admit/1 ping\n' | nc 127.0.0.1 5915
glass-admit/1 ok box=<64hex> allow=1 devices=2 ttl=86400
```

| verb | asks | answers |
|---|---|---|
| `ping` | is there a desktop, and what is its posture | `box` `allow` `devices` `ttl` |
| `admit pub= code=` | may this peer connect (decides + enrols + mints) | `via` `code` `token` `devices` |
| `allowed pub=` | is this pubkey on the allowlist | `allowed=1\|0` |
| `devices` | the enrolments (the shared warp query) | `rows=N` + `<pubkey> <expiry>` |
| `revoke pub= arg=` | un-enrol, on `pub`'s authority — **allowlist only** | `rows=N` + revoked keys |
| `mint pub= [ttl=]` | a login token, on `pub`'s authority | `token` |

**Three statuses and not two.** `deny` is an answer; `err`, or no connection at all, is the absence
of one. The client half returns `:UNREACHABLE` distinctly, and that distinction is the only reason
failing closed is safe rather than indistinguishable from denying everybody.

Loopback and unauthenticated on it — the same trust boundary the desktop's `:4013` eval socket
already draws, and see §10 for why that boundary is thinner than it reads.

### The login link

```
<LOGIN_URL_BASE>#box=<box-npub>&code=<nonce>.<exp>.<mac>
mac = HMAC-SHA256(box-secret, "glass-login|" nonce "|" exp)
```

The box npub and code live in the `#fragment`, which an nsite gateway never receives.

**Codes are reusable until they expire** — there is no spent-nonce set. (`login-token.lisp`'s header
claims single-use is enforced by the gateway. It is not; the gateway's own comment is the truth.)

Every successful answer carries a *fresh* token back, stored in `localStorage`, so an active terminal
never needs a new link.

TTLs disagree between call sites: 900 s from the CLI (`login-link.lisp`), 1800 s
(`GLASS_LOGIN_TTL`, falling back to `LINK_TTL`) for the desktop's `link` DM and for the renewal that
rides back with each answer.

### Message formats

```
offer  phone → box   {"sdp": "<full non-trickle SDP>", "code": "<token>"}
answer box → phone   {"sdp": …, "ufrag": "<the OFFER's ice-ufrag>", "code": "<renewed token>"}
```

Signalling is **one-shot and non-trickle**: the browser gathers fully (capped at 10 s) and publishes
once. There is no renegotiation path anywhere in the system — which is why the microphone transceiver
is added up-front with no track and filled in later via `replaceTrack()`.

Duplicate copies of one offer are answered with the *identical cached answer*, keyed on ICE ufrag.
This is load-bearing: retiring the session on each copy would kill the very agent the phone is
checking against.

---

## 3. The connection

**ICE.** The box advertises ICE-lite but runs full outbound checks anyway — the point is hole
punching, not nomination. `ICE_LOCAL_IP` overrides host-candidate detection.

**TURN.** Needed for cellular. The gateway Allocates over the same ICE socket, then issues
`CreatePermission` **once per unique peer IP** — per-candidate meant ~132 blocking round trips on a
cellular offer carrying 66 candidates. `ChannelBind` is deferred to a background thread so the receive
loop cannot deadlock on its own response. `TURN_RELAY_PEER` pre-permits the address coturn sees the
phone's relayed packets arriving from; without it the first relayed check is dropped. On teardown the
allocation is released with `Refresh lifetime 0`, or it lingers ~600 s and a small port range
exhausts.

**Demux.** One UDP socket carries everything: TURN ChannelData and Data indications are stripped
first, then RFC 5764 first-byte demux splits SRTP (128–191) from DTLS (20–63). Every inbound datagram
stamps a receive time, which powers a 30 s consent timeout.

**Data channels.** Four, of which the last two are off by default:

| channel | stream | negotiation | carries |
|---|---|---|---|
| `rfb` | 0 | DCEP | raw RFB, binary. noVNC takes the `RTCDataChannel` as its transport directly |
| `control` | 100 | `negotiated: true` | flat JSON |
| `warp` | 102 | `negotiated: true` | warp delta frames — the enrolled-terminal list (§7) |
| `payload` | 104 | `negotiated: true` | the browser client's own code (§9). Off unless `PAYLOAD_CHANNEL` |

Control messages: `{"kbps":N}` to change rung, `{"get":1}` to poll, `{"request":"keyframe"}` when the
decoder is stranded. **The box answers every control message with full state**, which the client
exploits as an application-level heartbeat (~18 B/s).

A negotiated channel has **no DCEP handshake**, so creating one costs nothing and the box cannot be
told it exists — it learns by receiving a message on that stream. Both `control` and `warp` work that
way, which is why an unused channel is indistinguishable from an absent one.

A session ends at 1 hour, or after 30 s of peer silence, whichever comes first.

---

## 4. Media

**Capture** is a *second, independent* RFB client to the same desktop. It keeps Y/U/V 4:2:0 planes and
converts only the rectangles glass reports as changed; CopyRect becomes a plane-internal move, so a
window drag costs 4 bytes. Per-macroblock dirty bits come straight from RFB — the encoder never
rescans for damage. Resolution follows damage via a scale divisor restricted to {1,2,4}, because a
macroblock must divide into whole scaled pixels or damage tracking stops being exact.

**Encoding** reuses the audio's SRTP context with its own SSRC. The VP8 payload type is echoed from
the browser's offer, since it is dynamic. Three deliberately separate clocks: screen sampled, frame
encoded, packets paced. They used to be one, which is why lowering the bitrate also lowered the
capture rate.

**The ladder** (`video-profiles.lisp`) is seven rungs a factor of 3 apart —
`5 16 48 160 480 1600 4800` kbps — and **every encoder knob is derived from that one number**:
quantizer, keyframe interval, frame budget, target fps. The constants are measured against this
encoder, not modelled. Target fps caps at 12 even at the top rung, because whole-screen frames take
240–290 ms to encode and asking for more only divides the frame budget.

Changing rungs mid-session is a variable the sender re-reads each pass: no reconnect, no black frame.

**`VIDEO_PRIMARY`** puts a `<video>` element over the desktop and has the gateway **swallow the
browser's FramebufferUpdateRequest**, so glass never sends pixels down SCTP. Without that, both paths
carry the same screen and compete for bandwidth. The noVNC canvas is kept at `opacity:0` because
input still rides the data channel and the virtual trackpad maps touches through it.

There is **no RTCP anywhere** — no PLI, no receiver reports. A stranded decoder recovers only via the
control channel's keyframe request or the blind periodic resync.

---

## 5. Audio, microphone, clipboard

**Audio out.** The mix belongs to the *desktop*, not the gateway — a mixer in the gateway could only
carry what the gateway itself played. glass serves it on TCP `:5913`: a one-line ASCII header, then
raw s16le frames. One connection per session means one subscription, so each phone gets its own cursor
into the mix and neither advances the other's. To the browser it is **G.711 PCMU, 8 kHz mono, 20 ms**,
as SRTP over the same transport — not a data channel.

**Microphone in.** Inbound SRTP → PCMU decode → TCP `:5914`. The decode callback runs on the thread
that decrypts *every* inbound packet, audio and video, so it must never block: it copies under a mutex
and returns, and a writer thread owns the socket. The ring holds 0.5 s and drops oldest. Newest
microphone wins. The desktop resamples 8 k → 16 k.

**Clipboard** rides RFB — there is no separate plane. The paste button reads the clipboard inside the
click gesture (Safari requires it), sends `ClientCutText`, then synthesises Shift+Insert.

---

## 6. Standing it up from scratch

### Step zero — secrets you must mint

Do this before anything else. Two of them have committed placeholder values that the code will
silently fall back to.

| secret | where | if you skip it |
|---|---|---|
| **box Nostr identity** | `NOSTR_SEC` in **both** launchers — the gateway's and the desktop's (`GLASS_NOSTR_SEC` falls back to it) | the gateway crashloops; the desktop starts but runs **no admission service and no DM bot**, so nobody can connect. The secret is deliberately shared for now: the gateway cannot decrypt an offer without it. Making the desktop the only holder is a marked follow-up (`ADMISSION-SERVE` in `glass/src/nostr.lisp`). |
| **nsite site key** | `~/.glass/site-key`, mode 600 | `publish.lisp` refuses to run. This key *is* your site npub; losing it orphans every link ever issued |
| **TURN credential** | launcher **and** the browser bundle | cellular clients cannot connect |
| **`NOSTR_ALLOW`** | the **desktop's** launcher (`GLASS_NOSTR_ALLOW` overrides) | fails closed — nobody is authorised |
| **VNC password** | `~/.glass-vnc-pass` | the desktop listens unauthenticated. **But see dragons — setting it currently breaks video** |

`openssl rand -hex 32` produces the first two.

The box identity is duplicated in `gateway-nostr.lisp` and `login-link.lisp`, and the derived pubkey
appears again as a dev fallback in `index-nostr.html`. Rotating means touching all three, rebuilding,
republishing, and issuing a fresh link.

### The short path — LAN, no Nostr, no TURN, no publishing

Use the retired-but-working HTTP gateway: `gateway.lisp` + `index.html`, hunchentoot on `GW_PORT`
(8765), noVNC from `NOVNC_DIR`, offer over `POST /signal`. No keys, no relays, no build step. Point a
browser at `http://<host>:8765/`. Do this first to confirm the stack works at all.

### The full path

**Machine.** SBCL. Quicklisp with **three dists** — `quicklisp`, `ultralisp`, and **`modus`**
(`https://modus-lisp.github.io/dist/modus.txt`), which is how `seal`/`natrium`/`secp256k1-fast` are
reachable without hand-cloning. This is a real prerequisite and is documented nowhere else.

Systems are found by **two different mechanisms** depending on the process, and both must be set up:
the gateway uses `CL_SOURCE_REGISTRY` as an env var (a single `:tree` over the checkout root); the
desktop launcher uses `ql:quickload`, i.e. symlinks in `~/quicklisp/local-projects/`. (An ASDF
`source-registry.conf.d` entry exists in this tree but is renamed `.bak` and is *not* live — do not be
misled by it.)

Also needed: Python 3 and node/npm (`nostr-tools` + esbuild) for the client build, and `setsid` for
terminal windows. **No FFI, no ffmpeg, no web server.**

**Repos.** Minimum for a desktop on a phone: `webrtc-data`, `webrtc-media`, `glass`, `cl-nostr`,
`warren` (for the launcher), plus McCLIM — and transitively `seal`, `natrium`, `reed`, `cram`,
`scribe`, `secp256k1-fast`. Everything else is optional and guarded by `ignore-errors`, so a missing
one costs a menu item and a log line: `loom` (browser), `spool` (podcasts), `chord`/`stave` (voice and
ear, each also needing model weights built separately), `climacs` (editor), `mcclim-glass/remote`
(other desktops as windows).

**TURN.** A separate public box running coturn with `external-ip` set, one long-term credential, one A
record, 3478/udp plus a relay port range. **No coturn configuration exists in this repo** — it has to
be reconstructed. `demo/turn-rig/turn-server.py` is a small RFC 5766 server usable for local testing.

**Sequence.**

1. Desktop: `NOSTR_SEC=<box> NOSTR_ALLOW=<your npub> LOGIN_URL_BASE=<published client> cd warren && sbcl --control-stack-size 256 --dynamic-space-size 4096 --load desktop-5903.lisp` — the launcher must load `:glass/nostr` and call `(glass:start-session-nostr)`, or the box has no identity and admits nobody
2. Client: build and publish per `DEPLOY.md` (`mkbundle.py`, then `publish.lisp` **with the file as
   argv**, then `check-deploy.lisp`, then re-point `site-url.env` at nsite.run)
3. Gateway: `./gw-keepalive.sh` under nohup or tmux
4. First login: `NOSTR_SEC=<box> sbcl --script login-link.lisp <your-npub>`, or DM the box `link`
   once allowlisted

**Nothing here survives a reboot.** There is no systemd unit and no crontab entry for either process;
the desktop has no supervisor at all.

### What is hardcoded to one installation

In rough order of how badly it bites: the box secret (**three** places now — the gateway launcher,
`login-link.lisp`, and the desktop launcher's `GLASS_NOSTR_SEC`) and its derived pubkey (a fourth);
the site npub (**five** files); the TURN server, user and password (launcher *and* browser bundle,
which needs a rebuild to change); `TURN_RELAY_PEER`; `ICE_LOCAL_IP`; `NOSTR_ALLOW`; the absolute paths
in the launcher and in `desktop-5903.lisp` (including `mcclim-glass.asd`, which is *not* in
`local-projects`, so that literal path is load-bearing); voice and ear model paths under `/mnt`;
esbuild's path under one user's home; and the 5903/5913/5914/5915 port convention, which is asserted in a
docstring and enforced nowhere.

---

## 7. The warp channel — the terminal list, on the connection you already have

**Off unless `WARP_CHANNEL` is set.** With it unset the warp systems are never loaded, no projection
is built, no thread is started, nothing is sent, and the startup banner does not mention it. That is
deliberate: a claim of "this changes nothing" has to be checkable by reading, and "the code is not
loaded" is the only version of it that is.

The one branch it adds to the session's message dispatch matches **stream 102 only**, and matches it
*whether or not the flag is set* — disabled means the bytes are dropped, not that the clause is
skipped. Skipping it would let a phone that has the panel, talking to a box that does not have the
channel, fall through to the RFB branch and hand glass `{"t":"viewport",…}` as desktop input. For
streams 0 and 100 — the only two any deployed client uses — the dispatch is unchanged.

**What it is.** `revoke` and the enrolment list already exist as a command set on a type, with a
real authorization rule, reachable only over DM. This gives that same set a second surface — a ▤
button on the phone that opens a list of enrolled terminals, where a hold offers the applicable
commands and a tap invokes one. Same command, same authorization predicate, written once.

**Where it runs.** *Inside the gateway*, but over the **desktop's** store: the query is
`glass:admission-devices`, the invoker is `glass:admission-allowed-p`, and warp-monitor's
`revoke-in-file` is replaced at load time with `glass:admission-revoke` so the panel cannot rewrite
a file nobody enforces. `:warp` still depends on `bordeaux-threads` and nothing else; what changed
is where the rows come from.

With the desktop unreachable the panel shows **no rows** (logged once, not silently rendered as
"none enrolled") and **everybody is a guest** — the safe direction, since offering `revoke` to
somebody whose authority could not be checked is the one mistake here with consequences.

| file | what it is |
|---|---|
| `warp-channel.lisp` | the whole gateway side: stream id, invoker, query, open/message/close |
| `gateway-nostr.lisp` | **29 added lines** — a `load`, a `let` binding, one `cond` clause, one close, one banner line |
| `index-nostr.html` | the ▤ panel, plus `warp/dom/client.js` embedded verbatim |
| `warp/dom/channel.lisp` | everything testable: the clock, the lock, the non-signalling send, the close |

**Authorization.** The invoker is `:allowlist` iff `authorized-p` says so, and `:device` otherwise —
so an allowlisted owner is offered `revoke` and an enrolled guest is not. It is deliberately **not**
the session's `via` string: `via` takes the first match of code / allowlist / device, so an owner
arriving on a magic link classifies as `"code"` and so does a guest who was sent one. Mapping that
string would demote the owner and promote the guest at the same time. Menu filtering is courtesy;
`warp:invoke` refuses an unauthorized command whatever the surface offered.

**Cost.** `WARP_BUDGET` bytes per pass (default 1024) at `WARP_HZ` (default 4), and **zero in steady
state** — a pass with nothing owed sends nothing, and enrolments do not change while you are
watching a desktop. The budget bounds the first fill and the rare change.

**A revoke from the panel** goes to the desktop, which rewrites its `.glass-devices` and refuses
that terminal's next admission — with no restart anywhere, and with the desktop checking the
invoking pubkey against its own allowlist a second time, after warp's rule 6 already did.

**Environment.** `WARP_CHANNEL=1` to enable; `WARP_BUDGET`, `WARP_HZ`, `WARP_ROWS` to tune. warp must
be checked out beside `webrtc-data` and reachable through `CL_SOURCE_REGISTRY`; if it is not, the
load fails inside a handler, one line goes to the log, and the panel shows "no answer".

**Tests, none of which start a gateway.** `demo/glass-webrtc/warp-channel-test.lisp` lifts the
gateway's own names for *where the desktop is* out of its *text*, starts a real glass admission
service on a /tmp fixture, and runs `warp-channel.lisp` against a stubbed SCTP; `warp/t/channel.lisp` drives the channel module over a
fake transport; `warp/t/panel.sh` drives the panel's actual bytes in headless Chromium. The
untested remainder is `sctp-send-string` itself, which already carries RFB and the control channel.

---

## 8. Dragons

**Security**

1. **The box identity falls back to a committed placeholder** when `NOSTR_SEC` is unset, and that
   secret is the login-token HMAC key. `DEPLOY.md` claims nothing in the repo contains a key; that is
   true only of the *site* key.
2. **Login codes are reusable until expiry** — no spent-nonce set, contradicting `login-token.lisp`'s
   own header.
3. **Any admitted connection enrols a 24 h device that renews itself**, so one leaked link is durable
   access until revoked.
4. **The TURN long-term credential is published** in the browser bundle. Inherent to browser TURN
   without ephemeral credentials, but the box shares the same credential. The fix is coturn's
   `use-auth-secret` with time-limited HMAC credentials minted per session.
5. **Setting `~/.glass-vnc-pass` breaks video.** `glass-capture.lisp` selects RFB security type None
   unconditionally and has no VNC-auth implementation, so the capture connection fails while the
   browser's bridged RFB (which does authenticate) keeps working. It surfaces only as
   `desktop capture FAILED`. **The secure configuration is the broken one.**
6. **The desktop's control socket is an unauthenticated `eval`** on loopback — a trust boundary worth
   naming. `:5915` (admission) draws exactly the same one, deliberately: anything that can open
   loopback on this box can already eval in that image.
7. **The desktop must be started with `NOSTR_SEC` now.** It holds the identity, the store and the
   mint; a desktop without it serves a screen that nobody is admitted to.

**Operational**

8. `LOGIN_URL_BASE` is read **once at desktop start** — it is the desktop that builds a link now, so
   re-pointing the client at a new tag means restarting the desktop, not the gateway. Only the
   `site-url.env` sourced *inside* the gateway's restart loop updates a running gateway.
9. Publishing **replaces** the manifest, so the previous `/<tag>.html` stops resolving and every link
   minted against it 404s. Always publish under a new tag.
10. `publish.lisp` writes an **nsite.lol** URL into `site-url.env`, but nsite.lol serves a stale
    manifest — worse, `/index.html` returns 200 with an *older* build, which looks like success. Verify
    on nsite.run. Zero `accepted=T` lines means nothing was published.
11. NIP-05 allowlist resolution happens once at startup and fails open-to-empty — but it is now
    re-runnable: `(glass:refresh-nostr-allow)` over the desktop's control socket, no restart.

**Code smells that will confuse a reader**

12. Six `VIDEO_*` gateway parameters are **dead** — overridden by the profile from the first encoder
    pass. The `[rung]` log line is the one that tells the truth.
13. `*video-pt*` and `*last-assoc*` are process globals mutated per session, despite comments saying
    otherwise — unsafe with overlapping sessions.
14. `link` is matched by **substring**, so `blink` and `linkedin` both mint a login link. (Now in
    `glass/src/nostr.lisp`, deliberately preserved: people have it in their message history.)
15. `revoke` accepts a 4-character prefix while advertising 8. Also preserved, also in glass.
16. The seen-wrap set is flushed **wholesale** at 4096 entries, briefly reopening the replay window.
17. Control-channel JSON is hand-scraped and hand-formatted on the box; any format drift breaks it
    silently.
18. `GATHER_SRFLX` in the launcher is vestigial. (`link-request-p` was dead code and is gone; it
    left with the command surface.)
19. The FramebufferUpdateRequest filter is a magic-byte heuristic, and the RFB channel stays live in
    video-primary mode.

---

## 9. The payload channel — the client's own code, over the connection it is the client for

**Off unless `PAYLOAD_CHANNEL` is set, and not deployed at the time of writing.** With it unset no
file is read, no thread is started, and the startup banner does not mention it. The one branch it
adds to the session dispatch matches **stream 104 only**, and matches it whether or not the flag is
set — same argument as warp (§7): disabled means the bytes are answered `none`, not that they fall
through to the RFB branch and reach glass as input.

**What it is for.** Publishing to nsite **replaces** the manifest, so every client change means a
new tag, a new URL, and the whole of `DEPLOY.md`. That happened four times in one day, and every one
of those changes was to code that only matters *after* the connection is up. So the page is split at
the only line that is forced — can this code arrive over the connection it is used to set up? —
and the half that can, does.

| | contents | where |
|---|---|---|
| **shell** | nostr-tools, the PeerConnection and all four channels, credentials, the progress screen, the pill, the desktop-name display | nsite, ~36 KB over the wire (was 97 KB) |
| **payload** | noVNC, the trackpad, the modifier row, paste, the quality ladder, the warp panel, the getStats poll | the box, 71 KB gzipped on stream 104 |

**The desktop is visible before the payload arrives.** In `VIDEO_PRIMARY` the picture is VP8/RTP
into a `<video>`, which is the browser's job end to end; noVNC is only there for input coordinates
and the RFB handshake. The monolith could not show a frame without it purely because it positioned
the video from the *canvas's* rect — a layout convenience, not a dependency. The shell letterboxes
the frame from `videoWidth`/`videoHeight` instead, and hands geometry to the payload when it lands.

**Protocol.** `{"t":"hello","api":1,"have":"<sha256|>","enc":["gzip","raw"]}` up; `same` / `none` /
`begin` + 16 KB binary chunks down. Ordered stream, so chunks carry no sequence numbers. The sha is
over the bytes **as sent**, so it is both the integrity check and the cache key. A phone that
already holds that build is answered `same` and **nothing goes on the wire**.

**Shipping a payload change is `cp`.** The gateway mtime-checks the file, so a new `payload.js`
needs no restart and no publish — the phone reloads the *same* URL. That is the whole benefit.

**The version contract.** The shell's `api` object is **append-only**; `SHELL_API` increments on
each addition; the payload exports the lowest `needs` it can run against. A payload needing more is
refused out loud and the desktop stays view-only. Removing or redefining a member of `api` is the
only change that forces a new shell onto nsite.

**Where it lives.** `payload-channel.lisp` (the gateway side), `gateway-nostr.lisp` (**40 added
lines** — a guarded `load`, a `let` binding, one `cond` clause, one close, one banner line),
`shell.js` / `payload.js` / `index-shell.html` (the client), `mksplit.py` (the build),
`payload-channel-test.lisp` (40 assertions, starts no gateway).

**Cost when unused.** Zero, and checkable by reading: with the flag unset the file is never read and
`payload-on-message` returns after one string compare. A phone that never sends on 104 is
indistinguishable from one that has no such channel, because a negotiated channel has no handshake.

**One trap it had to solve.** glass sends its RFB greeting the moment the box bridges stream 0 —
which is seconds before noVNC exists in a split client. Unhandled, those bytes are dropped and the
handshake deadlocks: video plays, the control channel answers, and there is no keyboard, no mouse
and no desktop name. The shell buffers early RFB messages and the payload replays them into noVNC
(`takeEarlyRfb`). This was found by the end-to-end test, not by reading.

## 10. Sockets that are files — closing the loopback hole

`127.0.0.1` is not an access boundary. **Every process of every uid on the box can connect to a
loopback port**, so "the gateway and the desktop are both on this machine" was the whole of the
protection on five sockets: the screen (`:5903`), the mix (`:5913`), the microphone (`:5914`),
admission (`:5915`) — and `:4013`, which is an unauthenticated `READ` + `EVAL`.

glass can now carry all five on **UNIX-domain sockets** instead, as a sibling transport and not a
replacement (`GLASS:OPEN-LISTENER`, `CLIM-GLASS:OPEN-SEAT-TRANSPORT :KIND :RFB-UNIX`). What that
buys, all of it enforced by the kernel rather than intended by us:

* the socket is a **file**: `connect(2)` needs write permission on it, so mode `0600` in a `0700`
  directory is owner-only. A wrong uid gets `EACCES` at the syscall.
* **`SO_PEERCRED`**: the desktop can ask who connected — uid, gid and **pid**, filled in by the
  kernel and unforgeable by the peer. `[audio] uid=1001 pid=2486993` instead of `peer`. That is
  peer authentication with no key material anywhere near it.
* no port to bind, scan, or expose by editing an address.

**Nothing is switched on by default.** TCP is unchanged and is still what every launcher does.
Moving over is a deployment decision, and it is these two diffs.

### The gateway: one line of `gw-keepalive.sh`

```diff
-export NOSTR_ALLOW='ynniv@ynniv.com' GLASS_HOST=127.0.0.1 GLASS_PORT=5903 GATHER_SRFLX=1 ICE_LOCAL_IP=192.168.5.22
+export NOSTR_ALLOW='ynniv@ynniv.com' GLASS_HOST=unix:/home/claude/.glass/run/seat-0.rfb GATHER_SRFLX=1 ICE_LOCAL_IP=192.168.5.22
```

That is the whole of it. `GLASS_PORT`, `GLASS_AUDIO_PORT` and `GLASS_ADMISSION_PORT` become
inert but harmless, and the other three endpoints **follow the screen**, exactly as the ports did:
`GLASS-ENDPOINT` derives `seat-0.audio`, `seat-0.mic` and `seat-0.admit` beside it with
`GLASS:SOCKET-SIBLING` — the socket-file reading of `5903 -> 5913 / 5914 / 5915`. Override any one
of them with `GLASS_AUDIO_HOST` / `GLASS_MIC_HOST` / `GLASS_ADMISSION_HOST` if they are not where
the convention says.

### The desktop: four `:path` arguments in `warren/desktop-5903.lisp`

```diff
-      (addr "127.0.0.1"))
-  (start-control-socket 4013)
+      (addr "127.0.0.1")
+      (rfb (glass:socket-path "seat-0.rfb")))
+  (start-control-socket 4013 rfb)
@@
-        (funcall start :port 5913 :address "127.0.0.1" :file nil)
+        (funcall start :path (glass:socket-sibling rfb "audio") :file nil)
@@
-        (funcall start :port 5914 :address "127.0.0.1")
+        (funcall start :path (glass:socket-sibling rfb "mic"))
@@
-        (funcall start :port 5915 :address "127.0.0.1")
+        (funcall start :path (glass:socket-sibling rfb "admit"))
@@
   (clim-glass:run-wm '((:terminal :cols 80 :rows 24 :ppem 14))
                      :port 5903 :width 1280 :height 800
-                     :address addr
+                     :kind :rfb-unix :path rfb
                      :background wp :background-mode :cover))
```

...and `START-CONTROL-SOCKET` — the `EVAL` one, and the one that most wants this — becomes:

```diff
-(defun start-control-socket (&optional (port 4013))
+(defun start-control-socket (&optional (port 4013) rfb-path)
   (sb-thread:make-thread
    (lambda ()
-     (let ((listen (glass:tcp-listen port :address "127.0.0.1")))
+     (let ((listen (if rfb-path
+                       (glass:open-listener :unix :path (glass:socket-sibling rfb-path "control"))
+                       (glass:tcp-listen port :address "127.0.0.1"))))
        (loop
          (handler-case
-             (let ((s (sb-bsd-sockets:socket-make-stream
-                       (sb-bsd-sockets:socket-accept listen)
-                       :input t :output t :element-type 'character :buffering :full)))
+             (let ((s (glass:accept-stream listen :element-type 'character)))
```

`GLASS:*PEER-POLICY*` then refuses any peer that is not this uid (or root) **before** the `READ`,
which is checked in `glass/inspect/unix-socket-gate.lisp`. Reaching it by hand becomes
`nc -U ~/.glass/run/seat-0.control` in place of `nc 127.0.0.1 4013`.

### Checking it

`demo/glass-webrtc/unix-socket-test.lisp` stands a fake desktop up under `/tmp` on four socket
files and drives the gateway's four clients at it — the RFB bridge, `CAPTURE-CONNECT`, the audio
tap, the mic sender — plus admission, and the endpoint derivation read out of `gateway-nostr.lisp`
itself. It never starts a gateway: loading that file would put a second one on the live npub.
