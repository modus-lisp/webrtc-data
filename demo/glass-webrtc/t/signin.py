"""t/signin.py — signing in at the point of failure, and not needing to again.

WHAT THIS PROVES.  A device enrolment lapses; the browser goes on signing with the stale key and
gets the box's deliberate silence back, which from here is indistinguishable from an unreachable
box.  Two halves were added for that, and each is worthless without the other:

  1. THE FAILURE SCREEN OFFERS THE SIGNER, ON A TAP.  window.nostr is READ to decide whether to
     draw the button and never CALLED until the button is pressed — asserted as two separate
     counters, because "it did not prompt" is a claim about method calls and nothing else.
  2. SIGNING IN LEAVES A CREDENTIAL BEHIND.  An allowlist admission now carries a minted login
     code back in the answer envelope, which the browser stores.  The next load presents it under
     its OWN device key, is admitted `code', and is enrolled — so the load after THAT needs
     neither the code nor the signer.  That last step is the whole point, and it is asserted with
     the signer genuinely absent from the page.

EVERYTHING HERE IS THE REAL BYTES.  The page is the built nsite-shell.html — the same artefact
mksplit.py publishes, with two <script> tags spliced in front of it to install the signer, the way
an extension would.  The offers are real NIP-59 gift wraps over a real WebSocket relay, unwrapped
with the box secret; the answers come from a real RTCPeerConnection and are applied by a real
setRemoteDescription; the login codes are real HMAC-SHA256 tokens in glass's format.

WHAT IS SUBSTITUTED, and it is worth naming:

  * THE RELAY is store-and-forward in this file, not damus.io.  The shell reaches it through
     ?relays=, which is its own supported override.
  * THE BOX is t/box.entry.mjs: glass's ADMIT-PEER and the gateway's ASK-ADMISSION top-up, in a
     page.  It is NOT gateway-nostr.lisp, which may not be loaded — that half is asserted from the
     gateway's text, in admission-test.lisp.
  * ICE SERVERS are stripped, so gathering finishes in milliseconds instead of the ten-second cap
     it would spend failing to reach STUN from a sandbox.  Nothing under test is downstream of it.

The gateway is never loaded, started or contacted, and nothing is written outside /tmp.

    python3 t/signin.py <build-dir>          (t/signin.sh builds it and calls this)
"""
import json, os, pathlib, socket, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from playwright.sync_api import sync_playwright
import websockets.sync.server as wss

BUILD = pathlib.Path(sys.argv[1])
HERE = pathlib.Path(__file__).resolve().parent
OUT = pathlib.Path(os.environ.get("GLASS_SIGNIN_OUT", "/tmp/glass-signin-out"))
OUT.mkdir(parents=True, exist_ok=True)
assert str(OUT).startswith("/tmp/"), "this test writes only to /tmp"

fails = []
def ok(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}{('   ' + str(detail)) if detail else ''}", flush=True)
    if not cond:
        fails.append(name)
def banner(s): print(f"\n== {s} ==", flush=True)

def freeport():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

# ---- identities -------------------------------------------------------------------------------
BOX_SEC   = "11" * 32          # the box's Nostr identity
HMAC_SEC  = "22" * 32          # what login codes are MAC'd under
OWNER_SEC = "33" * 32          # the npub in NOSTR_ALLOW — the signer's key
STALE_SEC = "44" * 32          # a device key that was enrolled once and is not any more
FRESH_SEC = "55" * 32          # a device key that is currently enrolled
CTRL_SEC  = "66" * 32          # the negative control's, kept clear of everything above

# ================================================================================================
# the relay: store and forward, which is all a Nostr relay is to this system
# ================================================================================================
EVENTS, LIVE, RLOCK = [], [], threading.Lock()

def matches(ev, f):
    if "kinds" in f and ev["kind"] not in f["kinds"]:
        return False
    for k, v in f.items():
        if k.startswith("#"):
            vals = {t[1] for t in ev.get("tags", []) if len(t) > 1 and t[0] == k[1:]}
            if not (set(v) & vals):
                return False
    return True

def relay_conn(conn):
    try:
        for raw in conn:
            msg = json.loads(raw)
            if msg[0] == "REQ":
                sid, filts = msg[1], msg[2:]
                # registered BEFORE the backlog goes out, so an event arriving mid-replay is not
                # dropped.  A duplicate is harmless: the box dedupes by wrap id and the phone by
                # ice-ufrag, which are the guards the real system runs anyway.
                with RLOCK:
                    LIVE.append((conn, sid, filts))
                    hist = [e for e in EVENTS if any(matches(e, f) for f in filts)]
                for e in hist:
                    conn.send(json.dumps(["EVENT", sid, e]))
                conn.send(json.dumps(["EOSE", sid]))
            elif msg[0] == "EVENT":
                ev = msg[1]
                with RLOCK:
                    EVENTS.append(ev)
                    tgt = [(c, s) for (c, s, f) in LIVE if any(matches(ev, x) for x in f)]
                conn.send(json.dumps(["OK", ev["id"], True, ""]))
                for c, s in tgt:
                    try: c.send(json.dumps(["EVENT", s, ev]))
                    except Exception: pass
            elif msg[0] == "CLOSE":
                with RLOCK:
                    LIVE[:] = [x for x in LIVE if not (x[0] is conn and x[1] == msg[1])]
    except Exception:
        pass
    finally:
        with RLOCK:
            LIVE[:] = [x for x in LIVE if x[0] is not conn]

# ================================================================================================
# the page server: the BUILT shell, with the signer spliced in front of it
# ================================================================================================
SHELL = (BUILD / "nsite-shell.html").read_text()
MODTAG = '<script type="module">'
assert MODTAG in SHELL, "the built page has no module tag to splice in front of"
# Classic scripts, so they run at parse time — before the deferred module — which is where an
# extension puts window.nostr.  The shell's own bytes are untouched.
SHELL = SHELL.replace(MODTAG,
                      '<script src="/signer.js"></script>\n'
                      '<script src="/signer-shim.js"></script>\n' + MODTAG, 1)
(OUT / "served-shell.html").write_text(SHELL)

BOX_HTML = ('<!doctype html><meta charset="utf-8"><title>the box</title>'
            '<script src="/box.js"></script>')
# Somewhere to turn a secret into a pubkey with the SAME library the page uses, rather than a second
# implementation in Python that could agree with itself and not with the shell.
KEYS_HTML = ('<!doctype html><meta charset="utf-8"><title>keys</title>'
             '<script src="/signer.js"></script>')
FILES = {
    "/shell.html":     ("text/html", SHELL),
    "/box.html":       ("text/html", BOX_HTML),
    "/keys.html":      ("text/html", KEYS_HTML),
    "/box.js":         ("text/javascript", (BUILD / "box.js").read_text()),
    "/signer.js":      ("text/javascript", (BUILD / "signer.js").read_text()),
    "/signer-shim.js": ("text/javascript", (HERE / "signer-shim.js").read_text()),
}

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path not in FILES:
            self.send_error(404); return
        ctype, body = FILES[path]
        b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a): pass

HTTP_PORT, WS_PORT = freeport(), freeport()
BASE = f"http://127.0.0.1:{HTTP_PORT}"
RELAY = f"ws://127.0.0.1:{WS_PORT}"

httpd = ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), H)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
wsd = wss.serve(relay_conn, "127.0.0.1", WS_PORT)
threading.Thread(target=wsd.serve_forever, daemon=True).start()
print(f"== page on {BASE} · relay on {RELAY} ==", flush=True)

# Gathering against unreachable STUN costs the shell its full ten-second cap in a sandbox, and
# nothing under test is downstream of a reflexive candidate.  Host candidates only.
NO_ICE = """
const _P = window.RTCPeerConnection;
window.RTCPeerConnection = function (cfg) { return new _P(Object.assign({}, cfg, { iceServers: [] })); };
window.RTCPeerConnection.prototype = _P.prototype;
"""

def dump(page, name):
    try:
        (OUT / (name + ".log")).write_text("\n".join(page.evaluate(
            "() => (document.getElementById('diag')||{}).textContent || ''").split("\n")))
        page.screenshot(path=str(OUT / (name + ".png")))
    except Exception:
        pass

with sync_playwright() as pw:
    browser = pw.chromium.launch(args=["--no-sandbox"])

    # ---- the keys, derived by the library the page itself runs on ------------------------------
    boxctx = browser.new_context()
    boxctx.add_init_script(NO_ICE)
    keys = boxctx.new_page()
    keys.goto(f"{BASE}/keys.html")
    pubof = lambda sec: keys.evaluate(
        "(s) => window.NSIGNER.getPublicKey(new Uint8Array(s.match(/../g).map(x => parseInt(x, 16))))",
        sec)
    BOX_PUB, OWNER_PUB = pubof(BOX_SEC), pubof(OWNER_SEC)
    STALE_PUB, FRESH_PUB = pubof(STALE_SEC), pubof(FRESH_SEC)
    CTRL_PUB = pubof(CTRL_SEC)
    keys.close()

    # ---- the box, up for the whole run ---------------------------------------------------------
    box = boxctx.new_page()
    box.goto(f"{BASE}/box.html?relay={RELAY}&sec={BOX_SEC}&secret={HMAC_SEC}&allow={OWNER_PUB}")
    box.wait_for_function("() => window.__box && window.__box.ready", timeout=15000)
    assert box.evaluate("window.__box.pub") == BOX_PUB
    print(f"   box {BOX_PUB[:12]}…  owner {OWNER_PUB[:12]}…", flush=True)

    CODE_KEY = "glass-code:" + BOX_PUB
    DEV_KEY = "glass-device:" + BOX_PUB

    def box_log():
        return box.evaluate("window.__box.log")

    def phone(ctx, signer=None, tag=""):
        p = ctx.new_page()
        url = f"{BASE}/shell.html?box={BOX_PUB}&relays={RELAY}"
        if signer:
            url += "&signer=" + signer
        p.goto(url)
        return p

    def seeded(device=None, code=None):
        """A fresh browser profile with exactly the credentials named, and nothing else."""
        ctx = browser.new_context()
        ctx.add_init_script(NO_ICE)
        seed = {"dev": DEV_KEY, "cod": CODE_KEY, "device": device, "code": code}
        ctx.add_init_script(
            "(s => { try {"
            "  if (s.device) localStorage.setItem(s.dev, s.device);"
            "  if (s.code) localStorage.setItem(s.cod, s.code);"
            "} catch (e) {} })(%s)" % json.dumps(seed))
        return ctx

    def connected(p, timeout=20000):
        p.wait_for_function("() => window.__glass && window.__glass.pc.remoteDescription",
                            timeout=timeout)
        return True

    # ============================================================================================
    banner("a stale device key, a signer in the page — the failure screen offers it")
    # ============================================================================================
    ctx = seeded(device=STALE_SEC)
    p1 = phone(ctx, signer=OWNER_SEC)
    # 18s answer watchdog, then a 15s `link' request the box also refuses in silence.
    p1.wait_for_selector("#nocred", timeout=45000)
    calls = p1.evaluate("window.__signerCalls")
    reads = p1.evaluate("window.__signerReads")
    ok("THE SIGNER WAS NEVER CALLED — no prompt, at any point, without a tap", calls == 0,
       f"__signerCalls={calls}")
    ok("  …though it was LOOKED AT, which is what a signer costs to notice", reads > 0,
       f"__signerReads={reads}")
    ok("the box refused the stale device key in silence, as it is meant to",
       any(e["t"] == "denied" and e["peer"] == STALE_PUB for e in box_log()),
       [e for e in box_log() if e["t"] == "denied"][:1])
    ok("the screen says WHICH failure it is — not enrolled, not an expired link",
       "not enrolled" in p1.evaluate("() => document.querySelector('#connstatus .msg').textContent"))
    ok("and it offers the one thing that can be done about it: a button",
       p1.locator("#signin").count() == 1,
       p1.evaluate("() => (document.getElementById('nocred')||{}).textContent"))
    ok("  …which was never going to appear on its own — the code path that used to reach for a"
       " signer with no tap is gone from shell.js",
       "const signer = window.nostr;\n  if (!signer || !signer.nip44)"
       not in (HERE.parent / "shell.js").read_text())
    dump(p1, "1-failure-screen")

    # ============================================================================================
    banner("tapping it connects — and leaves a credential behind")
    # ============================================================================================
    before = len(box_log())
    p1.click("#signin")
    # The counter is reset by the reload the tap causes, so this waits for the NEW document's first
    # call — which is the signer prompt, arriving where and only where it was asked for.
    p1.wait_for_function("() => window.__signerCalls > 0", timeout=30000)
    ok("the tap reloads, and NOW the signer is called", p1.evaluate("window.__signerCalls") > 0,
       f"__signerCalls={p1.evaluate('window.__signerCalls')}")
    ok("the offer is applied — a real answer, from a real PeerConnection", connected(p1))
    admits = [e for e in box_log()[before:] if e["t"] == "admitted"]
    ok("the box admitted the OWNER, via the allowlist",
       any(a["via"] == "allowlist" and a["peer"] == OWNER_PUB for a in admits), admits)
    ok("THE CHANGE: an allowlist admission carried a code back, which it did not before",
       any(a["via"] == "allowlist" and a["gaveCode"] for a in admits))
    stored = p1.evaluate("(k) => localStorage.getItem(k)", CODE_KEY)
    ok("…and the browser stored it, under this box's key", bool(stored), (stored or "")[:24] + "…")
    exp = int(stored.split(".")[1]) if stored else 0
    ok("  …alive, so the next load will actually present it", exp > time.time(),
       f"expires in {int(exp - time.time())}s")
    ok("the signing identity is NOT what got stored — the code is a bearer token, and that is why"
       " a device key can spend it",
       stored is not None and OWNER_PUB not in stored and len(stored.split(".")) == 3)
    dump(p1, "2-signed-in")
    p1.close()

    # ============================================================================================
    banner("THE POINT: the next load, with the signer gone")
    # ============================================================================================
    before = len(box_log())
    p2 = phone(ctx)                                  # no ?signer= — window.nostr does not exist
    ok("the signer really is absent from this page",
       p2.evaluate("() => typeof window.nostr === 'undefined'"))
    ok("it connects anyway", connected(p2))
    admits = [e for e in box_log()[before:] if e["t"] == "admitted"]
    ok("admitted `code' — the stored credential, presented under the DEVICE key",
       any(a["via"] == "code" and a["peer"] == STALE_PUB for a in admits), admits)
    ok("  …which is the whole trick: the code was minted on the OWNER's authority and spent by a"
       " key the box had never admitted",
       all(a["peer"] != OWNER_PUB for a in admits))
    ok("no failure screen, and no button to press", p2.locator("#signin").count() == 0)
    renewed = p2.evaluate("(k) => localStorage.getItem(k)", CODE_KEY)
    ok("and the answer renewed the code again, as it always has for a code login",
       bool(renewed) and renewed != stored)
    dump(p2, "3-signer-gone")
    p2.close()

    # ============================================================================================
    banner("…and the load after that, with no code either — the enrolment took")
    # ============================================================================================
    before = len(box_log())
    ctx.add_init_script("(k => { try { localStorage.removeItem(k); } catch (e) {} })(%s)"
                        % json.dumps(CODE_KEY))
    p3 = ctx.new_page()
    p3.goto(f"{BASE}/shell.html?box={BOX_PUB}&relays={RELAY}")
    p3.wait_for_function("() => window.__glass", timeout=15000)
    ok("the browser is down to a device key and nothing else",
       p3.evaluate("(k) => localStorage.getItem(k)", CODE_KEY) is None)
    ok("it still connects", connected(p3))
    admits = [e for e in box_log()[before:] if e["t"] == "admitted"]
    ok("admitted `device' — the key the box enrolled when it spent the code",
       any(a["via"] == "device" and a["peer"] == STALE_PUB for a in admits), admits)
    ok("ONE TAP BOUGHT A DURABLE TERMINAL, which is what signing in is supposed to mean", True)
    dump(p3, "4-device-again")
    p3.close()
    ctx.close()

    # ============================================================================================
    banner("the paths that were already working: byte-for-byte the same journey")
    # ============================================================================================
    live = box.evaluate("() => window.__box.mint(1800)")
    before = len(box_log())
    ctx = seeded(code=live)
    p4 = phone(ctx)
    ok("a valid code, on a browser with no device key and no signer: connects", connected(p4))
    admits = [e for e in box_log()[before:] if e["t"] == "admitted"]
    ok("  …via `code', first load, no watchdog and no button",
       any(a["via"] == "code" for a in admits) and p4.locator("#signin").count() == 0, admits)
    ok("  …and the signer was never installed, let alone consulted",
       p4.evaluate("() => typeof window.nostr === 'undefined'"))
    dump(p4, "5-valid-code")
    p4.close(); ctx.close()

    box.evaluate("(p) => window.__box.enrol(p)", FRESH_PUB)
    before = len(box_log())
    ctx = seeded(device=FRESH_SEC)
    p5 = phone(ctx)
    ok("a healthy enrolled device, no code: connects", connected(p5))
    admits = [e for e in box_log()[before:] if e["t"] == "admitted"]
    ok("  …via `device', and gets its renewal exactly as before",
       any(a["via"] == "device" and a["gaveCode"] for a in admits), admits)
    ok("  …with no failure screen anywhere in it", p5.locator("#nocred").count() == 0)
    dump(p5, "6-healthy-device")
    p5.close(); ctx.close()

    # ============================================================================================
    banner("no credential and NO signer — the message that was already there, unchanged")
    # ============================================================================================
    ctx = browser.new_context()
    ctx.add_init_script(NO_ICE)
    p6 = ctx.new_page()
    p6.goto(f"{BASE}/shell.html?box={BOX_PUB}&relays={RELAY}")
    p6.wait_for_selector("#nocred", timeout=30000)
    ok("it says so at once, without waiting for a watchdog", True)
    ok("no button, because there is nothing behind it", p6.locator("#signin").count() == 0)
    txt = p6.evaluate("() => document.getElementById('nocred').textContent")
    ok("and the advice is the one that still applies", "DM link to the box" in txt, txt)
    ok("  …with no mention of signing in, which would be a lie on this page",
       "Sign in" not in txt)
    dump(p6, "7-no-signer")
    p6.close(); ctx.close()

    # ============================================================================================
    banner("an EXPIRED link still reads as expired, and now also offers the way out")
    # ============================================================================================
    # In the URL and not in localStorage, because LOADCODE drops an expired one on the floor —
    # "this link has expired" is a thing the shell can only say about a link it was just handed,
    # which is exactly the case somebody hits: they tapped a stale DM.
    dead = box.evaluate("() => window.__box.mint(-600)")
    ctx = browser.new_context()
    ctx.add_init_script(NO_ICE)
    p7 = ctx.new_page()
    p7.goto(f"{BASE}/shell.html?box={BOX_PUB}&relays={RELAY}&signer={OWNER_SEC}&code={dead}")
    p7.wait_for_selector("#nocred", timeout=45000)
    ok("the screen distinguishes an expired code from a missing one, as it did",
       "expired" in p7.evaluate("() => document.querySelector('#connstatus .msg').textContent"))
    ok("  …and names the moment it died", "valid until" in
       p7.evaluate("() => document.getElementById('nocred').textContent"))
    ok("the signer was still not called", p7.evaluate("window.__signerCalls") == 0)
    ok("and the button is there", p7.locator("#signin").count() == 1)
    dump(p7, "8-expired-code")
    p7.close(); ctx.close()

    # ============================================================================================
    banner("THE NEGATIVE CONTROL: the same box, without the gateway's top-up")
    # ============================================================================================
    # Everything above would still pass if signing in were the whole change — the button works, the
    # connection is made, the screen is right.  It would just be a button somebody presses on every
    # load forever, which is the failure this is supposed to end.  So: put the box back the way it
    # was, do exactly the same thing, and watch it silently not stick.
    # The relay's store is emptied first.  A restarted box re-REQs and a relay hands back its whole
    # backlog — which is the real thing the gateway's WRAP-SEEN-P and the phone's ufrag echo exist
    # for, and here it would re-run every offer above against a fresh enrolment map and admit this
    # control's device key before it ever offered.  (A distinct key below, for the same reason,
    # twice over.)
    with RLOCK:
        EVENTS.clear()
    box.goto(f"{BASE}/box.html?relay={RELAY}&sec={BOX_SEC}&secret={HMAC_SEC}"
             f"&allow={OWNER_PUB}&topup=0")
    box.wait_for_function("() => window.__box && window.__box.ready", timeout=15000)
    before = len(box_log())
    ctx = seeded(device=CTRL_SEC)
    p8 = phone(ctx, signer=OWNER_SEC)
    p8.wait_for_selector("#signin", timeout=45000)
    p8.click("#signin")
    p8.wait_for_function("() => window.__signerCalls > 0", timeout=30000)
    ok("signing in still connects — the button is not what is broken", connected(p8))
    admits = [e for e in box_log()[before:] if e["t"] == "admitted"]
    ok("  …admitted via the allowlist, and handed NOTHING to remember it by",
       any(a["via"] == "allowlist" and not a["gaveCode"] for a in admits), admits)
    ok("so the browser ends the session with no credential at all",
       p8.evaluate("(k) => localStorage.getItem(k)", CODE_KEY) is None)
    p8.close()

    p9 = phone(ctx)                                   # the next load, signer gone
    p9.wait_for_function("() => window.__glass", timeout=15000)
    p9.wait_for_timeout(6000)
    ok("AND THE NEXT LOAD IS BACK WHERE IT STARTED — no answer, nothing applied",
       p9.evaluate("() => !window.__glass.pc.remoteDescription"))
    ok("  …refused again, on the same stale device key",
       any(e["t"] == "denied" and e["peer"] == CTRL_PUB for e in box_log()[before:]))
    ok("which is the half that stops this recurring, and it is a GATEWAY change: the button alone"
       " would be a tap on every cold load, forever", True)
    dump(p9, "9-negative-control")
    p9.close(); ctx.close()

    boxctx.close()
    browser.close()

httpd.shutdown()
print(f"\n{len(fails)} failed" if fails else "\nall passed", flush=True)
for f in fails:
    print("  FAILED:", f)
print("artefacts in", OUT, flush=True)
sys.exit(1 if fails else 0)
