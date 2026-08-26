// payload.js — everything that only matters once the connection is up.
//
// ===================================================================================================
// WHAT THIS IS
// ===================================================================================================
//
// The other half of the split described at the top of `shell.js`.  The shell is published to nsite
// and is meant to stop changing; THIS file is served by the box over data channel 104, so changing
// it costs a gateway restart and no publish at all.  That is the entire point of the exercise: the
// four publishes in one day that prompted it were all changes to code in this file.
//
// It holds noVNC, the virtual trackpad, the latching modifier row, paste, the quality ladder, the
// warp panel, the debug overlay and the getStats poll — every one of which is useless before there
// is a connection, and all of which the user can therefore wait a moment for.
//
// ===================================================================================================
// THE INTERFACE
// ===================================================================================================
//
// `needs` is the lowest shell API this file can run against, and it is the only thing the shell
// checks before running us.  The rule that makes a single number sufficient is that the shell's
// `api` object is APPEND-ONLY: a member, once shipped, keeps its name and meaning forever.  So a
// payload built against API 1 runs on every shell that will ever exist, and raising this number is
// a decision to require a new shell on nsite — which is exactly the cost the split exists to avoid,
// and is why it is one obvious line at the top of the file rather than something inferred.
//
// WHAT THE PAYLOAD MAY NOT DO, and both of these are properties of when it runs rather than taste:
//
//   * IT MAY NOT CREATE A DATA CHANNEL.  Signalling is one-shot and non-trickle and there is no
//     renegotiation path anywhere in the system, so every channel had to exist before the offer —
//     which was minutes ago, in the shell.  All four are on `api.chans`.
//   * IT MAY NOT ASSUME IT IS FIRST.  The desktop has been visible since the first VP8 frame, the
//     progress overlay may already be gone, and the link watchdog is already armed.  Everything
//     here therefore ADDS to a running session rather than starting one.
//
// The one thing it must TAKE OVER is the video's geometry, and it does that through the single
// `setGeometryOwner` slot rather than by writing the element: the shell letterboxes the frame into
// the viewport, which is right until there is a noVNC canvas and a zoom, and wrong the moment there
// is.  Two writers on that box is the bug the monolith's comments spend forty lines on.

import RFB from './novnc/core/rfb.js';

export const needs = 1;

export async function init(api) {
  // The shell's members, bound to the names the code below has always used.  This is deliberately a
  // flat unpacking rather than `api.` everywhere: it keeps the bodies below textually identical to
  // the monolith they came from, which is what makes them reviewable as a move rather than a
  // rewrite.
  const pc       = api.pc;
  const ch       = api.chans.rfb;
  const ctrl     = api.chans.ctrl;
  const warpCh   = api.chans.warp;
  const diag     = api.ui.diag;
  const hud      = api.ui.hud;
  const connEl   = api.ui.connEl;
  const setStep  = api.ui.setStep;
  const setDetail = api.ui.setDetail;
  const vidEl    = api.video.el;
  const videoPrimary = api.video.primary;
  const syncVideo = api.video.sync;
  // THE PICTURE CAN CHANGE SHAPE WITHOUT THE WINDOW MOVING.  A VP8 stream changes
  // resolution mid-flight now, because the desktop resizes itself to the window looking
  // at it, and the browser reports that by firing `resize` ON THE VIDEO ELEMENT.  The
  // shell's geometry only listened to the WINDOW, so it went on letterboxing a 393x563
  // desktop as though it were still 1280x800 — full width and a third of the height.
  //
  // Also here, and not only in the shell, because of where each one lives: the shell is
  // baked into the published nsite page, the payload is served by the box.  A fix in the
  // shell alone needs a republish before anybody sees it.
  vidEl.addEventListener('resize', syncVideo);
  vidEl.addEventListener('loadedmetadata', syncVideo);
  // ...AND WATCH THE DIMENSIONS DIRECTLY, because that event is not dependable.  A VP8
  // stream changing resolution mid-flight is supposed to fire `resize` on the element;
  // Safari does not do it reliably, which showed up as a desktop that only took its new
  // shape after a page reload — a reload builds the element afresh, so it never had to
  // notice a change.
  //
  // Half a second and two integer compares.  The geometry is idempotent and rAF-coalesced
  // (syncVideo), so a spurious call costs nothing and a missed change costs the shape.
  let lastVW = 0, lastVH = 0;
  setInterval(() => {
    const w = vidEl.videoWidth, h = vidEl.videoHeight;
    if (w && h && (w !== lastVW || h !== lastVH)) {
      lastVW = w; lastVH = h;
      log('video is now', w + 'x' + h);
      syncVideo();
    }
  }, 500);
  const tStart   = performance.now() - api.stamp();   // the SHELL's clock, so the log is one timeline
  const log      = (...a) => console.log('[glass-payload]', ...a);

  // ---- ON-OPEN: register, AND catch up -----------------------------------------------------------
  // Every channel is created by the shell, before this file exists — so by the time we listen, they
  // are already open, and 'open' does not fire twice.  A plain addEventListener here is a handler
  // that will never run: it is not a race, it is a certainty, and it fails silently as a control
  // that stays disabled forever with nothing in the log.
  //
  // This is the same shape as the buffered RFB greeting: state that arrived before we did.  Bytes
  // needed replaying; an edge needs re-deriving from the level, which is what READYSTATE is for.
  //
  // Shipped disabled and found by use: paste (on `ch`) and the quality ladder (on `ctrl`) were both
  // dead in the first split build, while mic and speaker — which do not wait on a channel edge —
  // worked.  Anything else that waits on an edge the shell may already have consumed belongs here.
  // The catch-up is DEFERRED, and that is not caution — it is required.  These handlers close over
  // controls declared further down (`qBtn`, `pasteBtn`), so calling FN synchronously here reaches
  // them in their temporal dead zone and throws.  setTimeout(0) is a macrotask, so it runs after
  // this function's body has finished no matter how many awaits are in it, which is exactly the
  // guarantee "the event would have arrived later" already gave us.
  const onOpen = (c, fn) => {
    if (!c) return;
    c.addEventListener('open', fn);
    if (c.readyState === 'open') setTimeout(fn, 0);
  };

  // ---- the ICE half of the liveness check ------------------------------------------------------
  // It lives HERE and not in the shell because it is a getStats reading, and getStats is polled by
  // pollPath below — but what it produces is the shell's `markAlive`, which is why that is the only
  // thing it touches.  The shell's own half (the control-channel ping) works with or without us,
  // which is the property that lets the pill keep telling the truth in a session where the payload
  // never arrived.
  //
  // WHAT IS NOT A LIVENESS SIGNAL, and this was measured rather than assumed:
  // `candidate-pair.bytesReceived`.  ICE consent freshness (RFC 7675) does keep STUN moving both
  // ways for the life of the connection — but Chromium counts only DATA packets into bytesReceived.
  // Against a real ICE-lite answerer (which is what the box is) both bytesReceived and
  // packetsReceived sat at exactly 0 for the whole life of an idle connection while consent checks
  // ran every ~2.8 s.  WHAT IS: `responsesReceived` and `totalRoundTripTime`, which advance on every
  // consent response.  They are SUMMED rather than picked, because which of them a given browser
  // feeds is not a thing to assume — ANY of them advancing is proof something came back.
  let rxSig = -1, rxSigSeen = false;
  const noteRxSig = (pair) => {
    let sig = 0; const have = [];
    for (const k of ['bytesReceived', 'packetsReceived', 'requestsReceived', 'responsesReceived']) {
      const v = pair[k]; if (typeof v === 'number') { sig += v; have.push(k); }
    }
    // microseconds: totalRoundTripTime accumulates one sample per consent response
    if (typeof pair.totalRoundTripTime === 'number') {
      sig += Math.round(pair.totalRoundTripTime * 1e6); have.push('totalRoundTripTime');
    }
    if (!have.length) return;                // nothing usable — the control channel is the whole check
    if (!rxSigSeen) { rxSigSeen = true; diag('ice liveness counters: ' + have.join(' ')); }
    if (rxSig < 0) { rxSig = sig; return; }  // first sample is a baseline, not evidence
    if (sig !== rxSig) { rxSig = sig; api.markAlive('ice'); }
  };

  // ---- the payload's own stylesheet ------------------------------------------------------------
  // IT TRAVELS WITH THE CODE IT STYLES, which is the only arrangement that keeps the promise this
  // split is making.  If the button row's rules lived in the shell on nsite, then adding a button —
  // the single most likely change to this file — would need a publish after all, and the split
  // would have bought nothing.  So the shell's stylesheet describes only what the shell draws
  // (the progress list, the pill, the log), and everything below is injected here.
  const style = document.createElement('style');
  style.id = 'payload-css';
  style.textContent = `
    /* --- the button row: three states, told apart by SHAPE rather than by shade ---------------
       A tint is not a state.  Shaded-on against shaded-off is a difference you have to have seen
       before to read, which is why 🎙 and 🔈 sat there looking switched on while the microphone
       was off and the sound was muted.  So:
         ON        green glyph, nothing over it
         OFF       a dulled glyph AND a diagonal strike across it — the strike is the ONLY thing
                   that ever draws one, so a strike always means "off, tap me".  Two half-signals
                   read as clearly as one loud one, and neither of them has to shout.
         DISABLED  faded well past OFF, desaturated, and pointer-events:none, so it cannot be
                   mistaken for something worth tapping
       Anything that is an action rather than a toggle (📋) stays plain: it has no "off". */
    .gbtn{position:fixed;z-index:20;width:52px;height:52px;border-radius:26px;border:0;padding:0;
      background:rgba(0,0,0,.6);color:#cdd6df;font-size:22px;line-height:1;
      touch-action:manipulation;-webkit-tap-highlight-color:transparent;
      transition:color .12s ease,background .12s ease,opacity .12s ease}
    .gbtn[data-state="on"]{color:#7CFC9B}
    /* OFF dulls the glyph as well as striking it.  The glyph lives in its own .gg span for exactly
       one reason: opacity on the button would drag the strike down with it, and the strike is the
       one part that has to hold up against whatever the desktop puts behind it. */
    .gbtn .gg{transition:opacity .12s ease}
    .gbtn[data-state="off"] .gg{opacity:.72}
    .gbtn[data-state="disabled"]{color:rgba(255,255,255,.34);background:rgba(0,0,0,.3);
      opacity:.42;filter:grayscale(1);pointer-events:none}
    /* the strike is drawn TWICE — a dark stroke under a white one — for the same reason the
       trackpad cursor is: the desktop shows through these buttons, and a single-colour line
       disappears against half the things that can be behind it.  It is INSET rather than corner to
       corner, and thin: it only has to cross the glyph, not underline the whole button. */
    .gbtn::before,.gbtn::after{content:'';position:absolute;left:50%;top:50%;width:32px;
      transform:translate(-50%,-50%) rotate(45deg);opacity:0;
      transition:opacity .12s ease;pointer-events:none}
    .gbtn::before{height:5px;border-radius:2.5px;background:rgba(0,0,0,.92)}
    .gbtn::after{height:2px;border-radius:1px;background:#fff}
    .gbtn[data-state="off"]::before,.gbtn[data-state="off"]::after{opacity:1}
    /* --- latching modifier keys --------------------------------------------------------------
       ARMED is outlined: held for the next key, then it lets go by itself.
       LOCKED is filled AND breathing, because a modifier that quietly stays down is the trap
       this row exists to avoid — you should be able to see one from across the screen. */
    #mods{position:fixed;right:14px;bottom:var(--mods-bottom,78px);z-index:20;display:flex;gap:6px;
      transition:bottom .18s ease}
    .gmod{min-width:47px;height:38px;border-radius:10px;padding:0 7px;
      background:rgba(0,0,0,.6);border:1px solid rgba(255,255,255,.16);color:#cdd6df;
      font:600 13px/1 -apple-system,system-ui,sans-serif;letter-spacing:.02em;
      touch-action:manipulation;-webkit-tap-highlight-color:transparent;
      transition:background .12s ease,color .12s ease,border-color .12s ease}
    .gmod[data-mod="armed"]{color:#7CFC9B;border-color:#7CFC9B;background:rgba(124,252,155,.18)}
    .gmod[data-mod="locked"]{color:#08130c;border-color:#7CFC9B;background:#7CFC9B;
      animation:modlock 1.5s ease-in-out infinite}
    @keyframes modlock{0%,100%{box-shadow:0 0 0 0 rgba(124,252,155,.6)}
                       50%{box-shadow:0 0 0 5px rgba(124,252,155,0)}}
    /* --- the warp panel: enrolled terminals, over the third data channel ----------------------
       DISPLAY:NONE WHEN CLOSED, which is doing real work rather than saving pixels: a hidden
       element is out of hit-testing entirely, so while the panel is shut the trackpad, the
       modifier row and the desktop underneath behave exactly as they did before it existed.
       Open, it DOES take pointer events — unlike the quality panel, which is a row of buttons over
       a live desktop.  This one is a list you tap and hold, so the taps are its own; that is the
       trade the ▤ button is asking you to make when you open it.
       Class names come from warp/dom/client.js and are the same ones its standalone page styles:
       .v .l .stale on a row, .t .c on a menu item, and selected / warn / bad / destructive. */
    #warpPanel{position:fixed;left:10px;right:10px;top:52px;bottom:150px;z-index:23;display:none;
      flex-direction:column;background:rgba(8,10,14,.93);border:1px solid rgba(255,255,255,.12);
      border-radius:12px;overflow:hidden;
      font:12px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace;color:#dce4ec}
    #warpHead{display:flex;justify-content:space-between;align-items:baseline;gap:10px;
      padding:9px 12px;border-bottom:1px solid rgba(255,255,255,.1);color:#8a949c;flex:0 0 auto}
    #warpHead b{color:#dce4ec;font-weight:600;letter-spacing:.04em}
    #warpBody{flex:1 1 auto;overflow-y:auto;-webkit-overflow-scrolling:touch;position:relative}
    #warpRows{list-style:none;margin:0;padding:0}
    #warpRows li{display:flex;align-items:center;gap:12px;padding:10px 12px;
      background:#161a20;border-bottom:1px solid #0c0e12;border-left:4px solid #5abe82;
      touch-action:manipulation;-webkit-tap-highlight-color:transparent}
    #warpRows li.selected{background:#26303c}
    #warpRows li.warn{border-left-color:#fabe3c}
    #warpRows li.bad{border-left-color:#f04646}
    #warpRows li .v{font-size:14px;min-width:64px}
    #warpRows li .l{color:#8a949c;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    #warpRows li .stale{margin-left:auto;color:#5a646c;font-size:10px}
    #warpMenu{list-style:none;margin:0;padding:0;position:absolute;left:12px;right:12px;top:8px;
      box-shadow:0 10px 30px #000c;border-radius:9px;overflow:hidden}
    #warpMenu:empty{display:none}
    #warpMenu li{padding:12px 13px;background:#222c38;border-left:3px solid #dce4ec;
      border-bottom:1px solid #0c0e12;display:flex;gap:10px;touch-action:manipulation}
    #warpMenu li.destructive{background:#3a1c1c;border-left-color:#f04646;color:#ffb0b0}
    #warpMenu li .c{margin-left:auto;color:#8a949c;font-size:10px}
    #warpNote{padding:8px 12px;color:#8a949c;flex:0 0 auto;
      border-top:1px solid rgba(255,255,255,.08)}
    /* ==== BEGIN the file browser's stylesheet — lifted by warp/t/two-apps.py ==================
       THE SECOND WARP APP, ON THE SAME CHANNEL.  Everything above is the device manager; this is
       warp-files, and the only reason it needs a stylesheet of its own is that it NESTS.  The
       client creates one .container per open column, inside #filesRows, and names it in
       data-container — so Miller columns are 'display:flex' on the parent and a fixed width on the
       child, and the horizontal scroll is the browser's own.  There is no layout on the wire and
       there never was: the server sends 'in' and 'after' and this file decides what a column is.
       Class names come from warp/dom/client.js, same as the panel above: .v .l .stale on a row,
       .t .c on a menu item, and .container / .opaque / .cap / .dim for what nesting added. */
    #filesPanel{position:fixed;left:10px;right:10px;top:52px;bottom:150px;z-index:23;display:none;
      flex-direction:column;background:rgba(8,10,14,.93);border:1px solid rgba(255,255,255,.12);
      border-radius:12px;overflow:hidden;
      font:12px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace;color:#dce4ec}
    #filesHead{display:flex;justify-content:space-between;align-items:baseline;gap:10px;
      padding:9px 12px;border-bottom:1px solid rgba(255,255,255,.1);color:#8a949c;flex:0 0 auto}
    #filesHead b{color:#dce4ec;font-weight:600;letter-spacing:.04em}
    #filesBody{flex:1 1 auto;position:relative;overflow:hidden}
    #filesRows{display:flex;align-items:stretch;height:100%;overflow-x:auto;overflow-y:hidden;
      -webkit-overflow-scrolling:touch}
    #filesRows .container{list-style:none;margin:0;padding:0;flex:0 0 186px;height:100%;
      overflow-y:auto;-webkit-overflow-scrolling:touch;border-right:1px solid rgba(255,255,255,.09)}
    #filesRows li{display:flex;align-items:baseline;gap:8px;padding:7px 10px;background:#161a20;
      border-bottom:1px solid #0c0e12;border-left:3px solid transparent;
      touch-action:manipulation;-webkit-tap-highlight-color:transparent}
    /* the column HEADER is the first row of every container, which is a fact about the projection
       (row 0 is the header) and needs no class from the client to be styled as one */
    #filesRows .container li:first-child{background:#0f1319;color:#8a949c;position:sticky;top:0;
      border-bottom:1px solid rgba(255,255,255,.12);letter-spacing:.03em}
    #filesRows li.selected{background:#26303c;border-left-color:#5abe82}
    #filesRows li .v{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    #filesRows li .l{margin-left:auto;color:#6a747c;font-size:10px;flex:0 0 auto}
    #filesRows li .stale{display:none}         /* per row it is noise; the header carries the age */
    /* AN OPAQUE NODE IS A HOLE AND IS DRAWN AS ONE.  Dashed, captioned, and deliberately not
       row-shaped: the app said what this region is and this client cannot show it, so the honest
       drawing is a labelled placeholder rather than something that looks like content. */
    #filesRows .opaque{display:block;background:#12161c;border:1px dashed rgba(255,255,255,.28);
      border-left:1px dashed rgba(255,255,255,.28);margin:8px;padding:14px 12px;border-radius:8px}
    #filesRows .opaque .cap{display:block;color:#dce4ec;margin-bottom:6px;word-break:break-word}
    #filesRows .opaque .dim{display:block;color:#8a949c;font-size:10px}
    #filesRows .opaque::after{content:'not shown here — this surface cannot blit';display:block;
      margin-top:8px;color:#5a646c;font-size:10px;font-style:italic}
    #filesMenu{list-style:none;margin:0;padding:0;position:absolute;left:12px;right:12px;top:8px;
      box-shadow:0 10px 30px #000c;border-radius:9px;overflow:hidden}
    #filesMenu:empty{display:none}
    #filesMenu li{padding:12px 13px;background:#222c38;border-left:3px solid #dce4ec;
      border-bottom:1px solid #0c0e12;display:flex;gap:10px;touch-action:manipulation}
    #filesMenu li.destructive{background:#3a1c1c;border-left-color:#f04646;color:#ffb0b0}
    #filesMenu li .c{margin-left:auto;color:#8a949c;font-size:10px}
    #filesNote{padding:8px 12px;color:#8a949c;flex:0 0 auto;
      border-top:1px solid rgba(255,255,255,.08)}
    /* ==== END the file browser's stylesheet ================================================== */
    /* ==== BEGIN the app menu's stylesheet — lifted by warp/t/two-apps.py ======================
       ONE BUTTON, AND A LIST OF THE RICH APPS BEHIND IT.  The menu is modal on purpose: the
       backdrop sits above every button in the page (including ≡ at 31) so that while the list is
       up the only things that can be tapped are an entry and the way out.  A menu you can tap
       through is a menu that leaves you unsure whether the tap picked something.
       It is NOT the panels' hold-menu — that one is drawn by warp/dom/client.js from what the
       server sent and is a different thing entirely.  This one is the page's own furniture and
       never touches the wire. */
    #appsBackdrop{position:fixed;inset:0;z-index:32;display:none;background:rgba(0,0,0,.42)}
    /* bottom:142 — clear of ⊞ itself, which sits at 78 above ≡ at 14.  The menu opens UPWARD from
       the button that summoned it, which is the direction there is room in on a portrait phone and
       the direction that keeps the thumb off the list it is choosing from. */
    #appsMenu{position:fixed;left:14px;bottom:142px;z-index:33;display:none;flex-direction:column;
      min-width:236px;max-width:calc(100vw - 28px);background:rgba(8,10,14,.96);
      border:1px solid rgba(255,255,255,.14);border-radius:12px;overflow:hidden;
      box-shadow:0 12px 34px #000c;
      font:13px/1.3 ui-monospace,SFMono-Regular,Menlo,monospace;color:#dce4ec}
    #appsMenu .ttl{padding:8px 13px;color:#8a949c;font-size:10px;letter-spacing:.09em;
      border-bottom:1px solid rgba(255,255,255,.1)}
    #appsMenu button{display:flex;align-items:baseline;gap:11px;width:100%;padding:14px 13px;
      background:none;border:0;border-bottom:1px solid rgba(255,255,255,.07);color:inherit;
      font:inherit;text-align:left;cursor:pointer;
      touch-action:manipulation;-webkit-tap-highlight-color:transparent}
    #appsMenu button:last-child{border-bottom:0}
    #appsMenu .ag{font-size:18px;width:20px;flex:0 0 auto;text-align:center}
    #appsMenu .an{flex:1 1 auto}
    /* AN APP THAT DID NOT ANSWER IS STILL LISTED, and is told about rather than quietly dropped:
       struck through, dimmed, and captioned with why.  The point of the caption is that it is
       there BEFORE the tap — the bad version of this menu is the one you pick from and only then
       find out.  See the ⊞ block for why the client cannot know any earlier than that. */
    #appsMenu button[disabled]{color:#5a646c;cursor:default}
    #appsMenu button[disabled] .an{text-decoration:line-through}
    #appsMenu .aw{flex:0 0 auto;color:#8a949c;font-size:10px;font-style:italic}
    /* ==== END the app menu's stylesheet ======================================================= */
`;
  document.head.appendChild(style);

    // --- two-way audio (G.711/SRTP): level meters + play the box's track ----------------------
    let audioCtx = null;
    const ensureCtx = () => (audioCtx ||= new (window.AudioContext || window.webkitAudioContext)());
    const mkMeter = (label, color) => {
      const row = document.createElement('div');
      row.style.cssText = 'display:flex;align-items:center;gap:7px;font:11px ui-monospace,monospace;color:#cdd6df';
      const lab = document.createElement('span'); lab.textContent = label; lab.style.cssText = 'width:26px';
      const bar = document.createElement('div'); bar.style.cssText = 'flex:1;height:8px;border-radius:4px;background:rgba(255,255,255,.14);overflow:hidden';
      const fill = document.createElement('div'); fill.style.cssText = `height:100%;width:0%;background:${color};transition:width .05s linear`;
      bar.appendChild(fill); row.append(lab, bar);
      return { row, set: p => { fill.style.width = Math.max(0, Math.min(100, p * 140)) + '%'; } };
    };
    const audioPanel = document.createElement('div');
    // bottom:140 rather than 78 — the modifier row now occupies the strip directly above the
    // button row, and on a portrait phone a left panel 190px wide reaches into it
    audioPanel.style.cssText = 'position:fixed;left:14px;bottom:140px;z-index:22;width:190px;display:none;' +
      'flex-direction:column;gap:6px;background:rgba(0,0,0,.55);padding:9px 11px;border-radius:11px';
    const txM = mkMeter('mic', '#7CFC9B'), rxM = mkMeter('box', '#8fbaff');
    audioPanel.append(txM.row, rxM.row); document.body.appendChild(audioPanel);
    const showAudio = () => { audioPanel.style.display = 'flex'; };
    const meterStream = (stream, setter) => {
      const ctx = ensureCtx(); const an = ctx.createAnalyser(); an.fftSize = 256;
      ctx.createMediaStreamSource(stream).connect(an);
      const buf = new Uint8Array(an.fftSize);
      const tick = () => { an.getByteTimeDomainData(buf);
        let s = 0; for (let i = 0; i < buf.length; i++) { const v = (buf[i] - 128) / 128; s += v * v; }
        setter(Math.sqrt(s / buf.length)); requestAnimationFrame(tick); };
      tick();
    };


    // ---- noVNC, and the RFB session --------------------------------------------------------
    // The channel was created by the SHELL, before the offer — see its note on ordering.  All the
    // payload does is hand it to noVNC, which rides an RTCDataChannel as its transport directly.

    const rfb = new RFB(document.getElementById('screen'), ch, {});
    // ASK THE DESKTOP TO BE THIS SIZE, rather than only scaling a picture of one.  noVNC
    // sends SetDesktopSize when the container resizes, glass turns that into a resize of
    // THIS SEAT's screen, and the desktop becomes the shape of the window looking at it —
    // which on a phone is the difference between a letterboxed 1280x800 and a desktop.
    //
    // scaleViewport stays on with it: the server may refuse, or take a moment, and until
    // it answers the picture still has to fit.  They are not alternatives — one asks, the
    // other copes.
    rfb.resizeSession = true;
    rfb.scaleViewport = true;

    // ASK FOR THE DISPLAY'S PIXELS, NOT THE LAYOUT'S.  noVNC computes its resize request
    // in CSS pixels, so on a 3x phone it asks for a 393x563 desktop and the compositor
    // then blows it up — a desktop the size of a large phone screen, drawn soft.  What we
    // want is the panel's real resolution: ask for CSS x DPR and let scaleViewport map it
    // back down, which is exactly what a Retina display does with everything else.
    //
    // Wrapped around the REQUEST only, and restored afterwards: _screenSize also feeds
    // noVNC's clipping and canvas fitting, and scaling those would move the picture out
    // from under the touches.
    //
    // Capped, because this squares: 4x the pixels is 4x the macroblocks to encode and
    // send, and a phone on a slow link would rather have a sharp 2x than a stalled 3x.
    const dpr = Math.max(1, Math.min(2, Math.round(window.devicePixelRatio || 1)));
    if (dpr > 1 && typeof rfb._requestRemoteResize === 'function'
        && typeof rfb._screenSize === 'function') {
      const trueSize = rfb._screenSize.bind(rfb);
      const request  = rfb._requestRemoteResize.bind(rfb);
      rfb._requestRemoteResize = () => {
        rfb._screenSize = () => {
          const s = trueSize();
          return { w: Math.round(s.w * dpr), h: Math.round(s.h * dpr) };
        };
        try { request(); } finally { rfb._screenSize = trueSize; }
      };
      log('resize: asking for', dpr + 'x CSS pixels');
    }
    rfb.focusOnClick = true;
    rfb.showDotCursor = true;      // desktop: draw a dot when the remote cursor is empty, so a
                                   // mouse user is never left with no pointer at all
    rfb.addEventListener('connect', () => { log('RFB connected'); rfb.focus(); });
    rfb.addEventListener('disconnect', e => log('RFB disconnect', e.detail));

    // ---- REPLAY WHAT ARRIVED BEFORE WE EXISTED -------------------------------------------------
    // glass sends its RFB protocol-version greeting the instant the box bridges this channel, which
    // is seconds before this line runs.  The shell holds those bytes for us; without this the
    // handshake deadlocks and the session looks perfectly healthy while having no input at all.
    // See the note at RFB-EARLY in shell.js.
    //
    // Dispatched as real MessageEvents ON THE CHANNEL rather than pushed into noVNC's internals,
    // because noVNC's transport contract is "an RTCDataChannel that emits message events" and that
    // is the only part of it this file is entitled to know about.  Synchronously and in order: the
    // handshake is a state machine, and a greeting that arrives after the version reply is worse
    // than one that never arrives at all.
    for (const data of api.takeEarlyRfb())
      ch.dispatchEvent(new MessageEvent('message', { data }));

    // --- mobile soft keyboard: iOS only shows it (and delivers keys) for a focused editable
    // element, and only after a user gesture.  A ⌨ button focuses a hidden input; we translate
    // its beforeinput/keydown into RFB key events (the canvas noVNC listens on can't do this).
    const kbin = document.createElement('input');
    kbin.setAttribute('autocapitalize', 'off'); kbin.setAttribute('autocorrect', 'off');
    kbin.setAttribute('autocomplete', 'off');   kbin.setAttribute('spellcheck', 'false');
    kbin.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;border:0;padding:0;';
    document.body.appendChild(kbin);
    // Every button in the bottom row is built the same way and wears the same three states —
    // see the .gbtn rules in <style>.  SETBTN is the only thing that writes one, so "what state
    // is this in" and "what does it look like" cannot drift apart.
    //   'on'       green
    //   'off'      dulled and struck through — available, currently not doing its thing
    //   'idle'     plain — for the buttons that are ACTIONS and have no off (📋)
    //   'disabled' faded and untouchable — the session cannot carry it right now
    // the glyph goes in its own span so 'off' can dull the glyph without dulling the strike over it
    const gGlyph = glyph => {
      const s = document.createElement('span'); s.className = 'gg'; s.textContent = glyph; return s;
    };
    const mkToggle = (glyph, right, label) => {
      const b = document.createElement('button');
      b.appendChild(gGlyph(glyph));
      b.className = 'gbtn';
      b.dataset.state = 'off';
      if (label) b.setAttribute('aria-label', label);
      b.style.bottom = '14px'; b.style.right = right + 'px';
      document.body.appendChild(b);
      return b;
    };
    const setBtn = (b, state) => { b.dataset.state = state; b.disabled = state === 'disabled'; };
    const isOn = b => b.dataset.state === 'on';
    const kbBtn = mkToggle('⌨', 14, 'keyboard');
    kbBtn.addEventListener('click', () => kbin.focus());
    // the ⌨ is on exactly while the hidden field holds focus, which is exactly while the soft
    // keyboard is up — so the strike is the honest answer to "will typing go anywhere?"
    kbin.addEventListener('focus', () => setBtn(kbBtn, 'on'));
    kbin.addEventListener('blur', () => setBtn(kbBtn, 'off'));
    // --- mic / speaker toggles, both MUTED on load — and now they SAY so ----------------------
    const micBtn = mkToggle('🎙', 74, 'microphone'), spkBtn = mkToggle('🔈', 134, 'desktop sound');
    // No getUserMedia at all (an insecure origin, an old WebView) is a genuine "you can't",
    // which is a different thing from "off", and used to look identical to it.
    if (!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia)) setBtn(micBtn, 'disabled');
    micBtn.addEventListener('click', async () => {
      const on = isOn(micBtn);
      if (on) {                                              // -> mute: drop the track entirely
        if (window.__micStream) { window.__micStream.getTracks().forEach(t => t.stop()); window.__micStream = null; }
        if (window.__micSender) { try { await window.__micSender.replaceTrack(null); } catch (_) {} }
        setBtn(micBtn, 'off'); diag('mic muted');
      } else {                                               // -> unmute: NOW ask for permission
        try {
          const ms = await navigator.mediaDevices.getUserMedia(
            { audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
          window.__micStream = ms;
          if (window.__micSender) await window.__micSender.replaceTrack(ms.getAudioTracks()[0]);
          setBtn(micBtn, 'on'); showAudio(); meterStream(ms, txM.set); diag('mic live');
        } catch (err) { diag('mic denied (' + (err.name || err) + ')'); }
      }
    });
    spkBtn.addEventListener('click', () => {
      const on = isOn(spkBtn);
      const au = window.__boxAudio;
      if (on) { if (au) au.muted = true; setBtn(spkBtn, 'off'); diag('speaker muted'); }
      else {
        // Nothing has arrived to unmute yet: say so rather than lighting the button green over
        // silence.  The button stays struck through, which is the truth.
        if (!au) { diag('speaker: no audio from the box yet'); return; }
        au.muted = false; const p = au.play && au.play(); if (p && p.catch) p.catch(() => {});
        setBtn(spkBtn, 'on'); showAudio();
        if (window.__boxStream && !window.__rxMetered) { window.__rxMetered = true; meterStream(window.__boxStream, rxM.set); }
        diag('speaker on');
      }
    });

    // --- video bandwidth: a seven-rung ladder in kbps, moved on the running encoder -----------
    // The box changes its encoder's knobs mid-stream, so a tap costs nothing: same session, same
    // RTP stream, no reconnect.  The panel shows the video's OWN KB/s and fps beside the ladder,
    // because that is the number a rung actually moves — and it is the only honest check that the
    // box did what the tap asked for.
    //
    // RUNGS ARE KILOBITS/S, which is how a constrained link is described; the box works in
    // kiloBYTES/s internally and answers with both, so the detail line can show what the rate
    // turned into.  Seven across would be 30px a button, so they are laid out FOUR THEN THREE —
    // still one tap to any rung, which a stepper would not be.
    //
    // It must not eat gestures.  The touch layer listens on #screen, so anything parented to
    // <body> is already out of its way; on top of that the panel itself is pointer-events:none and
    // only the buttons take input, so a two-finger scroll or a hold that begins on the panel's
    // background still reaches the desktop underneath.
    let QRUNGS = [5, 10, 20, 40, 80, 160, 320];
    let qCurrent = null, qPending = null;
    const qPanel = document.createElement('div');
    qPanel.style.cssText = 'position:fixed;left:14px;bottom:210px;z-index:22;width:232px;display:none;' +
      'flex-direction:column;gap:6px;background:rgba(0,0,0,.55);padding:9px 11px;border-radius:11px;' +
      'font:11px ui-monospace,monospace;color:#cdd6df;pointer-events:none';
    const qHead = document.createElement('div');
    qHead.style.cssText = 'display:flex;justify-content:space-between;align-items:baseline;gap:8px';
    const qTitle = document.createElement('span'); qTitle.textContent = 'video kbps';
    const qRate = document.createElement('span');
    qRate.style.cssText = 'color:#7CFC9B;font-variant-numeric:tabular-nums';
    qRate.textContent = '– KB/s · – fps';
    qHead.append(qTitle, qRate);
    const qGrid = document.createElement('div');
    qGrid.style.cssText = 'display:flex;flex-direction:column;gap:4px';
    const qNote = document.createElement('div'); qNote.style.cssText = 'color:#8a949c;min-height:2.6em';
    const qBtns = new Map();
    const paintQ = () => {
      for (const [kbps, b] of qBtns) {
        const on = kbps === qCurrent, wait = kbps === qPending;
        b.style.color = on ? '#7CFC9B' : (wait ? '#cdd6df' : '#8a949c');
        b.style.background = on ? 'rgba(124,252,155,.16)' : 'rgba(255,255,255,.06)';
        b.style.borderColor = on ? '#7CFC9B' : (wait ? 'rgba(255,255,255,.45)' : 'rgba(255,255,255,.18)');
      }
    };
    const sendRung = kbps => {
      if (ctrl.readyState !== 'open') { qNote.textContent = 'control channel ' + ctrl.readyState; return; }
      qPending = kbps; paintQ(); qNote.textContent = 'moving to ' + kbps + ' kbps…';
      ctrl.send(JSON.stringify({ kbps }));
      diag('rung -> ' + kbps + ' kbps');
    };
    // Rebuilt from whatever ladder the box reports, so adding a rung on the box needs no new build
    // of this page — the row split follows the count rather than assuming seven.
    const buildRungs = () => {
      qGrid.textContent = ''; qBtns.clear();
      const perRow = Math.ceil(QRUNGS.length / 2);
      for (let i = 0; i < QRUNGS.length; i += perRow) {
        const row = document.createElement('div'); row.style.cssText = 'display:flex;gap:4px';
        for (const kbps of QRUNGS.slice(i, i + perRow)) {
          const b = document.createElement('button');
          b.textContent = kbps;
          // pointer-events:auto only on the button itself; touch-action stops the browser waiting
          // to see whether the tap was the start of a zoom
          b.style.cssText = 'pointer-events:auto;touch-action:manipulation;flex:1;padding:7px 2px;' +
            'border-radius:7px;border:1px solid rgba(255,255,255,.18);background:rgba(255,255,255,.06);' +
            'color:#8a949c;font:11px ui-monospace,monospace';
          b.addEventListener('click', e => { e.stopPropagation(); sendRung(kbps); });
          qBtns.set(kbps, b); row.appendChild(b);
        }
        qGrid.appendChild(row);
      }
      paintQ();
    };
    buildRungs();
    qPanel.append(qHead, qGrid, qNote); document.body.appendChild(qPanel);
    // the box answers every message with the state it is ACTUALLY in, so the highlight follows the
    // encoder rather than the tap
    // COMING BACK FROM THE BACKGROUND is the SHELL's, and deliberately so.  It has to be: an iOS
    // tab can be suspended before the payload has ever arrived, and a resume handler that only
    // exists once the payload has loaded would miss exactly the case it is for.  The shell does the
    // play(), the keyframe request and the probe; what is left for the payload is the one thing the
    // shell cannot know about — that a rate measured before a nap is not a rate.  See the
    // onResumeHooks registration at the bottom of this file.

    let lastRungLine = '';
    ctrl.addEventListener('message', e => {
      // ANY message here is the pong to checkLink()'s '{"get":1}' — the box answers every control
      // message with its state, so this doubles as the application-level proof of life.
      api.markAlive('control');
      let m = null; try { m = JSON.parse(e.data); } catch (_) { return; }
      if (!m || m.kbps == null) return;
      if (Array.isArray(m.rungs) && m.rungs.join() !== QRUNGS.join()) { QRUNGS = m.rungs; buildRungs(); }
      qCurrent = m.kbps; qPending = null; paintQ();
      // The derived settings, because on this ladder they are the whole story: the keyframe
      // quantizer sets how long the FIRST picture takes, and the resync interval is what used to
      // saturate the link.  Two lines so the note does not reflow the panel as rungs change.
      qNote.innerHTML =
        `${m.target_kbs} KB/s · frame ≤${m.max_frame_kb} KB · settle ${m.cleanup_ms} ms<br>` +
        `qi ${m.qi}/${m.max_qi} · key qi ${m.key_qi} · resync ${m.key_secs} s`;
      // ONLY WHEN IT CHANGED.  The liveness ping asks for this state every 10 s and the box always
      // answers, so logging it unconditionally would bury the log under identical lines — the same
      // reason the ♥ heartbeat above prints only on a change.  Every informative line survives.
      const rungLine = `rung = ${m.kbps} kbps (${m.target_kbs} KB/s, key qi ${m.key_qi}, resync ${m.key_secs}s)`;
      if (rungLine !== lastRungLine) { lastRungLine = rungLine; diag(rungLine); }
    });
    onOpen(ctrl, () => { diag('control channel OPEN'); setBtn(qBtn, qOn ? 'on' : 'off');
                         ctrl.send('{"get":1}'); });
    // The ladder is the box's to move, so with the control channel shut there is nothing this
    // button can do — faded, not struck, because the difference matters.
    ctrl.addEventListener('close', () => { diag('control channel CLOSE');
      qOn = false; qPanel.style.display = 'none'; setBtn(qBtn, 'disabled'); });
    // ◈ toggles the panel, like ≡ toggles the debug overlay
    const qBtn = mkToggle('◈', 194, 'video quality');
    setBtn(qBtn, 'disabled');                       // until the control channel is actually open
    let qOn = false;
    qBtn.addEventListener('click', () => {
      qOn = !qOn; qPanel.style.display = qOn ? 'flex' : 'none'; setBtn(qBtn, qOn ? 'on' : 'off');
      if (qOn && ctrl.readyState === 'open') ctrl.send('{"get":1}');
    });

    // ==== BEGIN warp/dom/client.js — VERBATIM, checked by warp/t/client-sync.py ====
// warp/dom/client.js — the DOM encoding's client.  ONE copy, two hosts, no transport.
//
// This file is loaded verbatim by two pages that have nothing else in common:
//
//   warp/dom/client.html                                a standalone page over a WebSocket
//   webrtc-data/demo/glass-webrtc/index-nostr.html      a panel over a WebRTC data channel
//
// and it is the same file in both because the client's job does not vary with the link.  A frame
// is a frame; MAKE-WARP-CLIENT takes a SEND and hands back an APPLY, which is the browser half of
// the same statement the server half makes by taking a SEND function and nothing else.
//
// It is deliberately small, and the smallness is the argument.  The client holds a Map from key to
// node and does four things with a delta: create, replace content, re-anchor, remove.  It does not
// diff, does not reconcile, does not keep a shadow tree and does not know what a projection is —
// all of that happened on the server, which is what "the stream carries state, not events" buys.
//
// It also does not decide anything about safety.  The menu it draws is whatever the server sent
// it; it cannot invent a command, and if it tried, the server would refuse it at invocation
// (DESIGN.md rule 6).
//
// THE HOST OWNS THE ELEMENTS AND THE STYLESHEET.  This file writes exactly these class names and
// nothing else, so a page can look however it likes without touching the logic:
//
//   on a row       selected | warn | bad     and cells .v (value) .l (label) .stale (as-of)
//   on a menu item destructive              and cells .t (label)  .c (cost class)
//   on an opaque node  opaque               and cells .cap (the caption) .dim (its size)
//   on a container container                and data-container="<the name the wire used>"
//
// GESTURES ARE SCOPED TO A ROOT ELEMENT, which is the one thing the standalone page did not need
// and the panel absolutely does: a listener on `document` inside a remote-desktop client would eat
// the pointer events the trackpad lives on.  ATTACHGESTURES(root) listens on root only.
//
// ONE LINK MAY CARRY SEVERAL PROJECTIONS.  A frame names the app it belongs to in `a`, and this
// client applies only the frames addressed to the app it was made for — OPTS.APP, which is null for
// the host's default one.  That is how a phone shows the device manager and the file browser at the
// same time over the one negotiated data channel it was able to open before the offer.

"use strict";
function makeWarpClient(opts) {
  const rowsEl = opts.rows;
  const menuEl = opts.menu;
  const out    = opts.send;                 // (object) -> void.  The whole of the transport.
  const onStat = opts.onStat || function () {};
  const ROWS   = opts.viewportRows || 14;   // what this viewport can show; reported to the server
  const APP    = opts.app == null ? null : opts.app;   // which projection this client is a surface for

  // Every message we send carries the app, so the host can route it back to the right consumer.  A
  // client of the default app stamps nothing, which is what keeps a one-app link byte-for-byte what
  // it was before any of this existed.
  function send(o) { if (APP != null) o.a = APP; return out(o); }

  // key -> {key, node, in, after}.  This is the client's ENTIRE model.  The server holds the
  // memory of what we have been told; we hold the nodes it named and the anchor each one was given.
  const nodes = new Map();

  // Anchor key -> the records waiting for it.  THIS IS NOT DEFENSIVE PADDING, it is load-bearing,
  // and it is the one thing an anchor-based encoding needs that a rectangle-based one does not.
  //
  // A rectangle is absolute: deltas carrying rectangles can be applied in any order at all.  An
  // anchor is RELATIVE, so "insert X after Y" is unappliable until Y exists — and two independent
  // things make that happen:
  //
  //   * the reconciler emits within a priority band in reverse layout order, so a pass that
  //     appends two rows sends `r05 after r04` before it sends `r04`;
  //   * and even in layout order, the BUDGET can defer the anchor to a later pass entirely, which
  //     no ordering rule on the server could fix.
  //
  // So a node whose place we do not know yet is held OUT of the document rather than dropped into
  // a place we invented, and it is inserted the moment its anchor lands.  Guessing would put a row
  // in the wrong place and leave it there, which is exactly the silent-wrong-order failure this
  // encoding's positions exist to prevent.
  const waiting = new Map();
  let gen = 0, frames = 0, bytes = 0, deltas = 0;
  let scroll = 0;

  // ---- containers: the wire has always named one, and only "rows" was ever real ----------------
  //
  // A delta's `in` is the NAME of the container the node belongs to.  Two of those names are the
  // encoding's own and the HOST owns an element for each: "rows" and "menu:<key>".  Every other
  // name is the APP's — "col:/tmp/foo/", "preview" — and a container for it is created here on
  // demand, inside the rows element, and removed when its last child leaves.  Until a client
  // nested, this function was `name === "rows" ? rowsEl : menuEl` and every app container in
  // existence rendered into the hold-menu, silently, because no app had ever named one.
  //
  // WHERE A CONTAINER GOES IS NOT DERIVABLE FROM THE DELTAS, and that is the whole reason `cs`
  // exists.  `after` orders siblings WITHIN a container and says nothing at all across them, and a
  // pass emits within a priority band in reverse layout order — so the rightmost Miller column's
  // rows arrive FIRST, and ordering containers by first appearance would draw the columns right to
  // left.  So the frame carries `cs`: the app's containers, in layout order, as state rather than
  // as an event.  It is the same obligation rule 4 already puts on an anchor, one level up: never
  // put a thing in a position you invented.
  //
  // Containers do not nest in containers.  `in` is a flat name and a frame says nothing about a
  // container's own parent, so `cs` is a sequence, not a tree — Miller columns want exactly that,
  // and a client that wanted a tree would need the wire to say so.
  const containers = new Map();     // name -> element, for the app's containers only
  let order = [];                   // `cs`, as the server last stated it

  function container(name) {
    if (name == null || name === "rows") return rowsEl;
    if (name.lastIndexOf("menu:", 0) === 0) return menuEl;
    let el = containers.get(name);
    if (!el) {
      el = document.createElement("ul");
      el.className = "container";
      el.dataset.container = name;
      containers.set(name, el);
      orderContainers();
    }
    return el;
  }

  // The app's containers, in the order the server last stated.  One left-to-right pass with
  // insertBefore: a container already in its place is not touched, so re-stating an unchanged
  // order costs nothing and moves nothing.  A container we hold that `cs` does not mention keeps
  // its relative place at the end rather than being guessed at.
  function orderContainers() {
    if (!containers.size || !rowsEl) return;
    const seq = order.filter((n) => containers.has(n));
    for (const n of containers.keys()) if (seq.indexOf(n) < 0) seq.push(n);
    let prev = null;
    for (const n of seq) {
      const el = containers.get(n);
      const want = prev ? prev.nextSibling : rowsEl.firstChild;
      if (el !== want) rowsEl.insertBefore(el, want);
      prev = el;
    }
  }

  // A container is the app's claim that a group EXISTS, and the only evidence it still does is that
  // something is in it.  Emptied — the column closed, the preview cleared — it goes, so the host's
  // stylesheet never has to reason about a box with nothing in it.  Anything else the client made
  // is left alone: a node parked waiting for its anchor is out of the document, and dropping the
  // container it named would be inventing an answer to a question nobody asked.
  function dropIfEmpty(el) {
    if (!el || !el.dataset || !el.dataset.container || el.firstChild) return;
    containers.delete(el.dataset.container);
    el.remove();
  }

  // The four kinds, and nothing else.  Note what is NOT here: no re-render, no keyed list diff, no
  // virtual DOM.  A :moved does not touch the node's content, which is the entire point of rule 2.
  function applyDelta(d) {
    const rec = nodes.get(d.key);
    switch (d.k) {
      case "appeared": {
        const li = document.createElement("li");
        li.dataset.key = d.key;
        paint(li, d);
        const r = {key: d.key, node: li, in: d.in, after: d.after};
        nodes.set(d.key, r);
        place(r);
        break;
      }
      case "changed": {
        if (!rec) return;
        paint(rec.node, d);
        rec.in = d.in; rec.after = d.after;
        place(rec);
        break;
      }
      case "moved": {
        if (!rec) return;
        rec.in = d.in; rec.after = d.after;
        place(rec);                   // content untouched: the node is re-anchored, not rebuilt
        break;
      }
      case "gone": {
        if (!rec) return;
        const from = rec.node.parentNode;
        rec.node.remove();
        nodes.delete(d.key);
        dropIfEmpty(from);
        break;
      }
    }
  }

  // `after` is the key of the sibling this node follows, null meaning first child.  That is the
  // whole of the DOM's positional vocabulary and it is exactly what the server sends.
  function place(rec) {
    const parent = container(rec.in);
    if (!parent) return;
    const from = rec.node.parentNode;         // where it was, so an emptied container can go
    if (rec.after == null) {
      if (rec.node.parentNode !== parent || parent.firstChild !== rec.node) {
        parent.insertBefore(rec.node, parent.firstChild);
      }
    } else {
      const a = nodes.get(rec.after);
      if (!a || a.node.parentNode !== parent) {   // the anchor has not arrived, or is itself parked
        let w = waiting.get(rec.after);
        if (!w) waiting.set(rec.after, w = []);
        if (!w.includes(rec)) w.push(rec);
        if (rec.node.parentNode) rec.node.remove();
        if (from !== parent) dropIfEmpty(from);
        return;
      }
      if (rec.node.parentNode !== parent || rec.node.previousSibling !== a.node) {
        parent.insertBefore(rec.node, a.node.nextSibling);
      }
    }
    if (from && from !== parent) dropIfEmpty(from);
    const w = waiting.get(rec.key);               // anything that was waiting on us can go in now
    if (w) { waiting.delete(rec.key); for (const r of w) place(r); }
  }

  function paint(li, d) {
    const cells = d.cells || [];
    if (d.type === "menu-item") {
      li.className = cells[2] === "destructive" ? "destructive" : "";
      li.innerHTML = "";
      li.append(cell("t", cells[0]));
      if (cells[1]) li.append(cell("c", cells[1]));
    } else if (cells[2] === "opaque") {
      // AN OPAQUE NODE IS A HOLE, AND THE CAPTION IS THE WHOLE OF WHAT WE GET (DESIGN.md rule 9).
      // The app offers this region as pixels; this client cannot blit and is not going to be given
      // a way to — the wire is JSON cells, "binary payloads" is an open design question, and
      // sneaking the bytes through here would answer it by accident.  What arrives is a caption the
      // app chose and a size, so what we draw is a labelled placeholder saying what is not shown.
      // It is not a row and must not look like one, which is why it gets its own class and cells.
      li.className = "opaque";
      li.innerHTML = "";
      li.append(cell("cap", cells[0]));
      if (cells[1]) li.append(cell("dim", cells[1]));
      if (d.as_of) { li.append(cell("stale", "as of " + d.as_of)); }
    } else {
      li.className = (d.state && d.state.selected) ? "selected " + trend(cells[2]) : trend(cells[2]);
      li.innerHTML = "";
      li.append(cell("v", cells[0]), cell("l", cells[1]));
      // as_of is on every delta because DESIGN.md makes staleness first-class: under a budget a
      // delta can arrive several passes late, and the consumer is entitled to see it.
      if (d.as_of) { li.append(cell("stale", "as of " + d.as_of)); }
    }
  }
  function trend(t) { return t === "bad" ? "bad" : t === "warn" ? "warn" : ""; }
  function cell(cls, text) {
    const s = document.createElement("span");
    s.className = cls; s.textContent = text == null ? "" : String(text);
    return s;
  }

  // One frame, as it arrived on whatever the link is.  Takes the raw string so the byte count is
  // the real one; a host that already parsed it can pass the object instead.
  function apply(data) {
    let frame = data, raw = null;
    if (typeof data === "string") { raw = data; try { frame = JSON.parse(data); } catch (_) { return null; } }
    if (!frame) return null;
    // A frame addressed to another projection on this link is not ours to apply, and not ours to
    // count either: BYTES is what THIS surface cost, which is the number a panel reports and the
    // number a budget is checked against.
    if ((frame.a == null ? null : frame.a) !== APP) return null;
    if (raw !== null) bytes += raw.length;
    frames++;
    if (!frame.deltas) return null;
    // rule 4: snapshot chunks carry a generation, and anything older than the newest is discarded.
    if (frame.gen < gen) return frame;
    if (frame.gen > gen) { gen = frame.gen; }
    // The container order comes FIRST, so a container created by the deltas below already knows
    // where it belongs and no column is ever briefly drawn in the wrong place.
    if (frame.cs) { order = frame.cs; orderContainers(); }
    for (const d of frame.deltas) { deltas++; applyDelta(d); }
    onStat(stats());
    return frame;
  }

  // A LINK THAT WENT AWAY TAKES THE SERVER'S MEMORY WITH IT.  The server detaches the consumer on
  // close, so a reconnecting client is a NEW consumer with an empty stream and will be sent a full
  // snapshot (rule 8: attaching is not a resync).  Holding our old nodes across that would leave
  // rows on screen that the new stream never mentions and can therefore never remove.
  function reset() {
    for (const r of nodes.values()) r.node.remove();
    nodes.clear(); waiting.clear();
    for (const el of containers.values()) el.remove();
    containers.clear(); order = [];
    rowsEl.innerHTML = ""; if (menuEl) menuEl.innerHTML = "";
    gen = 0; deltas = 0;
  }

  function stats() {
    return {gen, frames, bytes, deltas, nodes: nodes.size, parked: waiting.size, scroll,
            containers: containers.size};
  }

  // ---- gestures: recognized HERE, sent as semantics.  Rule 5's vocabulary is closed and this
  // file does not extend it — every browser event below lands on tap / hold / two-finger.

  let holdTimer = null, held = null, listeners = null;

  function keyAt(ev) {
    const li = ev.target.closest ? ev.target.closest("li[data-key]") : null;
    return li ? li.dataset.key : null;
  }

  function attachGestures(root) {
    detachGestures();
    const onDown = (ev) => {
      held = keyAt(ev);
      if (!held) return;
      // press-hold is a TIMING discrimination and it is timed locally, on purpose: 100-300ms of
      // jittery link would make a hold read as a tap if the server tried to time it.
      holdTimer = setTimeout(() => { holdTimer = null; send({t: "gesture", g: "hold", key: held}); },
                             400);
    };
    const onUp = () => {
      if (holdTimer) {
        clearTimeout(holdTimer); holdTimer = null;
        // A release inside the hold window is a tap.  A release AFTER it lands on whatever is under
        // the finger, which for an open menu is a menu item — that is rule 5's hold-drag-release,
        // and it needs no verb of its own because menu items are presentations you can tap.
        if (held) send({t: "gesture", g: "tap", key: held});
      }
      held = null;
    };
    const onCtx = (ev) => {                                    // right-click is a hold
      const k = keyAt(ev);
      if (k) { ev.preventDefault(); send({t: "gesture", g: "hold", key: k}); }
    };
    const onWheel = (ev) => {                                  // wheel is the two-finger pan
      const dy = ev.deltaY > 0 ? 1 : -1;
      scroll = Math.max(0, scroll + dy);
      send({t: "gesture", g: "two-finger", dy: dy});
    };
    root.addEventListener("pointerdown", onDown);
    root.addEventListener("pointerup", onUp);
    root.addEventListener("contextmenu", onCtx);
    root.addEventListener("wheel", onWheel, {passive: true});
    listeners = {root, onDown, onUp, onCtx, onWheel};
  }

  function detachGestures() {
    if (!listeners) return;
    const l = listeners; listeners = null;
    l.root.removeEventListener("pointerdown", l.onDown);
    l.root.removeEventListener("pointerup", l.onUp);
    l.root.removeEventListener("contextmenu", l.onCtx);
    l.root.removeEventListener("wheel", l.onWheel);
    if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
    held = null;
  }

  return {
    apply, reset, stats, attachGestures, detachGestures,
    // the viewport report: the consumer-negotiated slice, in ROWS, which is this encoding's axis
    hello: (rows, sc) => send({t: "viewport", rows: rows || ROWS, scroll: sc == null ? scroll : sc}),
    // the test harness drives these; a human uses the mouse
    tap: (k) => send({t: "gesture", g: "tap", key: k}),
    hold: (k) => send({t: "gesture", g: "hold", key: k}),
    cmd: (name, key, confirmed) => send({t: "cmd", name, key, confirmed: !!confirmed}),
    viewport: (rows, sc) => send({t: "viewport", rows, scroll: sc}),
    // every row this client holds, in document order — which for a flat app is the rows element's
    // own children and for a nesting one reads across its containers, left to right
    keys: () => [...rowsEl.querySelectorAll("li[data-key]")].map((li) => li.dataset.key),
    menu: () => (menuEl ? [...menuEl.children].map((li) => li.dataset.key) : []),
    // the nesting as it was RENDERED: container name -> the keys in it, in document order.  A test
    // that checks this is checking the DOM, not the client's own idea of the DOM.
    containers: () => [...rowsEl.children]
      .filter((el) => el.dataset && el.dataset.container)
      .map((el) => [el.dataset.container,
                    [...el.children].map((li) => li.dataset.key)]),
    // the anchor chain as the client believes it, so a test can check the DOM against the WIRE
    // rather than against the client's own idea of the DOM
    anchors: () => Object.fromEntries([...nodes].map(([k, r]) => [k, r.after])),
    parked: () => [...waiting.keys()]
  };
}
if (typeof window !== "undefined") window.makeWarpClient = makeWarpClient;
    // ==== END warp/dom/client.js ====

    // ==== BEGIN the app menu — lifted by warp/t/two-apps.py ===================================
    //
    // --- ⊞ one button for the rich apps, and a menu that says which ones there are -------------
    //
    // TWO WARP APPS HAD BUTTONS AND MORE ARE COMING, and the row is out of room: the right-hand
    // row is five wide and a sixth runs off a 375px phone, which is why the second app already had
    // to stack up the LEFT edge above ≡.  A third would be looking for space rather than for a
    // place, and that is the shape of a problem that does not get better by being solved once
    // more.  So the RICH APPS — the ones that open a panel over the desktop — come off the row
    // entirely and go behind one button.  The debug toggle and the input controls (paste, mic,
    // speaker, quality) are untouched: they are things you do to the session, not places you go.
    //
    // ONE ENTRY IS ONE KNOWN THING.  There is deliberately no "open the best surface for this app"
    // entry.  The facets of an app are not RANKED — warp-files' DOM columns are not a degraded
    // picture of warren's pixel browser, they are a different projection of the same store, and
    // DESIGN.md rule 9 is explicit that the consumer chooses.  An entry that means the columns
    // today and the pixels tomorrow is an entry nobody can learn, and picking on the user's behalf
    // is the surface choosing the encoder, which is the thing rule 9 exists to stop.  So: one
    // entry, one facet, named — and a menu that conveys intent instead of guessing at it.
    //
    // WHAT IT CAN HONESTLY LIST.  Which apps a box serves is decided by WARP_FILES and by whether
    // :warp-files loads, and NOTHING ON THE WIRE ANNOUNCES IT: warp-app drops an app this box does
    // not serve and the frames simply never come.  There is no discovery message, and this is not
    // the place to invent one — a probe at menu-open would put bytes on a channel this panel is
    // careful to keep silent until it is asked, and would load warren, gesso, scribe and pigment
    // into the gateway because somebody glanced at a list.
    //
    // So the menu lists what this client can ASK FOR, which is all it knows before it asks, and
    // then it REMEMBERS THE ANSWER.  An app that was opened and never answered stays in the list,
    // struck through and captioned "not served by this box": a fact this client earned, told
    // before the next tap rather than after it.  Removing the entry would be a stronger claim than
    // the evidence supports ("there is no such app") and would make it vanish with no account of
    // why.  What matters is that it stops being an OFFER the moment it stops being one.
    //
    // The memory is per-link and resets on channel close, alongside the nodes and for the same
    // reason: the box on the other end of a reconnect is entitled to say something different.
    const richApps = [];        // {id, glyph, name, served, show(on)} — pushed by each app below
    const appsBackdrop = document.createElement('div');
    appsBackdrop.id = 'appsBackdrop';
    const appsMenu = document.createElement('div');
    appsMenu.id = 'appsMenu';
    document.body.append(appsBackdrop, appsMenu);

    const appsBtn = mkToggle('⊞', 14, 'apps');
    appsBtn.style.left = '14px'; appsBtn.style.right = 'auto'; appsBtn.style.bottom = '78px';

    let appOpen = null, appsMenuOn = false;

    // EXACTLY ONE RICH PANEL IS EVER UP.  Not a rule about screen space — both panels are fixed to
    // the same rectangle and would simply stack — but about what the button means.  It is showing
    // you one app; closing puts you back on the desktop rather than into the other one.
    const showApp = a => {
      for (const b of richApps) if (b !== a) b.show(false);
      appOpen = a || null;
      if (a) a.show(true);
      setBtn(appsBtn, a ? 'on' : 'off');
    };
    // Rebuilt on every open rather than kept in step, because it is four elements and the thing it
    // reports — whether an app answered — changes underneath it.
    const drawApps = () => {
      appsMenu.textContent = '';
      const ttl = document.createElement('div');
      ttl.className = 'ttl'; ttl.textContent = 'APPS';
      appsMenu.appendChild(ttl);
      for (const a of richApps) {
        const b = document.createElement('button');
        b.dataset.app = a.id;
        b.setAttribute('aria-label', a.name);
        const g = document.createElement('span'); g.className = 'ag'; g.textContent = a.glyph;
        const n = document.createElement('span'); n.className = 'an'; n.textContent = a.name;
        b.append(g, n);
        if (a.served === false) {
          b.disabled = true;
          const w = document.createElement('span');
          w.className = 'aw'; w.textContent = 'not served by this box';
          b.appendChild(w);
        } else {
          b.addEventListener('click', () => { setAppsMenu(false); showApp(a); });
        }
        appsMenu.appendChild(b);
      }
    };
    const setAppsMenu = on => {
      appsMenuOn = on;
      // Built on open and TORN DOWN on close, rather than left hidden: a shut menu holding live
      // entries is a set of click handlers on elements nobody can see, which is how a stale offer
      // gets taken.  Four elements; rebuilding them is not a cost worth keeping state for.
      if (on) drawApps(); else appsMenu.textContent = '';
      appsMenu.style.display = on ? 'flex' : 'none';
      appsBackdrop.style.display = on ? 'block' : 'none';
      // ⊞ RIDES ABOVE THE BACKDROP while the list is up.  It is the thing you tapped and the thing
      // that puts the list away again, and a modal layer that dims the affordance it belongs to
      // reads as "this button is now unavailable" — the opposite of what it is.
      appsBtn.style.zIndex = on ? '34' : '';
      setBtn(appsBtn, (on || appOpen) ? 'on' : 'off');
    };
    appsBackdrop.addEventListener('click', () => setAppsMenu(false));
    // ONE BUTTON, ONE MEANING: put away whatever rich surface is up, and if none is up, offer the
    // list.  So closing always lands on the desktop, and switching apps is close-then-pick rather
    // than a menu that opens over a live panel and has to decide what the panel underneath it is
    // doing while you read it.
    appsBtn.addEventListener('click', () => {
      if (appsMenuOn) { setAppsMenu(false); return; }
      if (appOpen) { showApp(null); return; }
      setAppsMenu(true);
    });
    // ==== END the app menu ====================================================================

    // --- ▤ the device manager: warp, on a third data channel ---------------------------------
    //
    // The box keeps a set of enrolled terminals and already administers them over gift-wrapped
    // DMs (`devices`, `revoke <prefix|all>`, both allowlist-only).  This is that same command set
    // as a SURFACE, on the connection this page already has — so revoking a terminal is a hold and
    // a tap instead of composing a DM and waiting for a relay round trip.
    //
    // WHAT IT DOES NOT TOUCH.  This block is additive on purpose and the ways it is additive are
    // load-bearing rather than tidy:
    //
    //   * the channel is NEGOTIATED on a fixed stream id, so creating it puts ZERO bytes on the
    //     wire — there is no DCEP handshake to send.  Nothing is sent until the panel is opened
    //     for the first time, so a session where nobody taps ▤ is byte-for-byte a session from
    //     before this existed, at both ends;
    //   * it does NOT call api.markAlive().  A warp frame really is proof the box is alive, but the
    //     link watchdog's budget-clearing is deliberately tied to a CONTROL-channel pong, and a
    //     second source of liveness would change when a stalled link is noticed.  This panel is
    //     not allowed to make the watchdog more forgiving;
    //   * the panel is display:none when shut, so it is out of hit-testing entirely and the
    //     trackpad, the modifier row and the desktop behave exactly as they did.  Open, it DOES
    //     take pointer events, because it is a list you tap and hold — that is what ▤ is asking;
    //   * it never touches the video path, the RFB channel or the quality stepper.
    //
    // The client is warp/dom/client.js above, unmodified: the same file the standalone page uses.
    // A frame is a frame, and a second client kept in step by hand is how the two silently drift.
    // THE CHANNEL IS THE SHELL'S — created before the offer, like all four of them, because a
    // channel that does not exist by `createOffer` can never exist at all.  Everything else about
    // this panel is unchanged: it still puts zero bytes on the wire until somebody taps ▤.
    const warpPanel = document.createElement('div');
    warpPanel.id = 'warpPanel';
    warpPanel.innerHTML =
      '<div id="warpHead"><b>enrolled terminals</b><span id="warpStat">—</span></div>' +
      '<div id="warpBody"><ul id="warpRows"></ul><ul id="warpMenu"></ul></div>' +
      '<div id="warpNote"></div>';
    document.body.appendChild(warpPanel);
    const warpStat = warpPanel.querySelector('#warpStat');
    const warpNote = warpPanel.querySelector('#warpNote');
    const warpBody = warpPanel.querySelector('#warpBody');

    // The browser measures its own viewport and says so — the consumer-negotiated slice, in ROWS,
    // which is this encoding's scroll axis.  A framebuffer cannot do this; a browser knows.
    const warpFit = () => Math.max(3, Math.floor((warpBody.clientHeight || 360) / 42));

    const warpSend = o => {
      if (warpCh.readyState !== 'open') { warpNote.textContent = 'channel ' + warpCh.readyState; return; }
      try { warpCh.send(JSON.stringify(o)); }
      catch (err) { warpNote.textContent = 'send failed (' + (err.name || err) + ')'; }
    };
    const warp = makeWarpClient({
      rows: warpPanel.querySelector('#warpRows'),
      menu: warpPanel.querySelector('#warpMenu'),
      viewportRows: 12,
      send: warpSend,
      onStat: s => {
        warpStat.textContent = s.nodes + (s.nodes === 1 ? ' terminal · ' : ' terminals · ') + s.bytes + ' B';
        if (s.deltas) warpNote.textContent = '';
      }
    });
    warp.attachGestures(warpPanel);
    warpCh.addEventListener('message', e => warp.apply(e.data));
    // A closed channel means the box detached our consumer, and its stream WAS its memory of what
    // we hold.  Whatever comes back is a fresh snapshot from an empty stream, so keeping the old
    // nodes would leave rows on screen that the new stream can never mention and therefore never
    // remove.  Forget them; the reconnect will say what is true.
    warpCh.addEventListener('close', () => {
      warp.reset(); warpSpoke = false; warpApp.served = null;
      warpStat.textContent = '—'; warpNote.textContent = 'channel closed';
      diag('warp channel CLOSE');
    });

    let warpOn = false, warpSpoke = false;
    // ▤ IS AN ENTRY IN THE ⊞ MENU, not a button on the row any more, and that is the whole of what
    // changed here.  What opening does is unchanged down to the order of the sends — the viewport
    // report, the first-open hello, the no-answer timeout that names which thing is missing — and
    // so is every byte on the wire, every element in the panel and every authorization decision,
    // all of which are the box's.  This is a rearrangement of how the panel is REACHED.
    const warpApp = {
      id: 'devices', glyph: '▤', name: 'enrolled terminals', served: null,
      show: on => {
        warpOn = on;
        warpPanel.style.display = on ? 'flex' : 'none';
        if (!on) return;
        // The FIRST open is what puts the first byte on this channel, which is what tells the box a
        // warp consumer exists at all — a negotiated channel has no handshake, so the hello IS the
        // open.  Every later open just re-reports the viewport, which may have changed with rotation.
        warp.viewport(warpFit(), 0);
        if (!warpSpoke) {
          warpSpoke = true;
          warpNote.textContent = 'asking the box…';
          diag('warp channel: hello on stream 102');
          // A box without the warp channel — an older build, or one started without WARP_CHANNEL —
          // simply never answers.  Say so rather than showing an empty list, which is what "no
          // terminals are enrolled" looks like and is a different and much more alarming claim.
          // The menu is told too, so the next tap is spent somewhere that can answer.
          setTimeout(() => {
            if (warpOn && warp.stats().frames === 0) {
              warpNote.textContent = 'no answer — this box is not serving the terminal list';
              warpApp.served = false;
              diag('warp channel: no answer from the box');
            }
          }, 5000);
        }
      }
    };
    richApps.push(warpApp);
    window.addEventListener('resize', () => { if (warpOn) warp.viewport(warpFit(), 0); });

    // ==== BEGIN the file browser — lifted by warp/t/two-apps.py ===============================
    //
    // --- 🗀 warp's client two, on the SAME data channel as the device manager ------------------
    //
    // TWO APPS, ONE CHANNEL, AND THE CHANNEL IS NOT NEGOTIABLE.  Signalling here is one-shot and
    // non-trickle and nothing in this system renegotiates, so every data channel had to exist
    // before the offer — which happened in the shell, on nsite, minutes ago.  A second app
    // therefore cannot have a channel of its own without publishing a new shell under a new tag
    // and re-minting every login link that points at the old one.  So it shares stream 102 and the
    // frames say which projection they belong to: `a` on the way down, `a` on the way back up,
    // absent for the device manager because absent is what it has always sent.
    //
    // Two makeWarpClient instances, two panels, one send.  Each parses the frame and drops what is
    // not addressed to it, which costs one JSON.parse per app per frame at 4 Hz — and buys a client
    // that does not know the other exists.  Neither instance shares anything else: separate node
    // maps, separate viewports, separate scroll, separate menus.
    //
    // WHAT IS DIFFERENT FROM THE PANEL ABOVE is entirely that this app NESTS.  Its rows arrive in
    // containers the client creates on demand — one per open column, named `col:<path>` — so
    // #filesRows is a flex row of .container elements rather than a list, and the stylesheet is
    // where a Miller column becomes 186 pixels wide.  The server sends no geometry whatsoever.
    const filesPanel = document.createElement('div');
    filesPanel.id = 'filesPanel';
    filesPanel.innerHTML =
      '<div id="filesHead"><b>files</b><span id="filesStat">—</span></div>' +
      '<div id="filesBody"><div id="filesRows"></div><ul id="filesMenu"></ul></div>' +
      '<div id="filesNote"></div>';
    document.body.appendChild(filesPanel);
    const filesStat = filesPanel.querySelector('#filesStat');
    const filesNote = filesPanel.querySelector('#filesNote');
    const filesRowsEl = filesPanel.querySelector('#filesRows');

    // The slice is per COLUMN here, not per list: the browser says how many rows one column can
    // show and gets that many of every column.  Same report, same units (rows), different shape of
    // working set — depth x rows instead of rows.
    const filesFit = () => Math.max(4, Math.floor((filesRowsEl.clientHeight || 360) / 29));

    const files = makeWarpClient({
      app: 'files',                       // the label on this app's frames, both ways
      rows: filesRowsEl,
      menu: filesPanel.querySelector('#filesMenu'),
      viewportRows: 12,
      send: warpSend,                     // one link, and it is the panel above's
      onStat: s => {
        filesStat.textContent = s.containers + (s.containers === 1 ? ' column · ' : ' columns · ') +
                                s.nodes + ' rows · ' + s.bytes + ' B';
        if (s.deltas) filesNote.textContent = '';
      }
    });
    files.attachGestures(filesPanel);
    // A SECOND listener rather than a change to the one above: the two panels are independent
    // additions to this file and each one wires its own client to the channel the shell made.
    warpCh.addEventListener('message', e => files.apply(e.data));
    warpCh.addEventListener('close', () => {
      files.reset(); filesSpoke = false; filesApp.served = null;
      filesStat.textContent = '—'; filesNote.textContent = 'channel closed';
    });

    let filesOn = false, filesSpoke = false;
    // THE SECOND ENTRY, and the reason the ⊞ menu is a registry rather than two special cases: a
    // third app is a `richApps.push` and nothing else — no glyph hunting for a free 60 pixels, no
    // decision about which corner it stacks in.
    const filesApp = {
      id: 'files', glyph: '🗀', name: 'files', served: null,
      show: on => {
        filesOn = on;
        filesPanel.style.display = on ? 'flex' : 'none';
        if (!on) return;
        files.viewport(filesFit(), 0);
        if (!filesSpoke) {
          filesSpoke = true;
          filesNote.textContent = 'asking the box…';
          diag('warp files: hello on stream 102');
          // A box serving the device manager and not the file browser is an ordinary state — the app
          // is opt-in on the gateway — so this says which thing is missing rather than showing an
          // empty tree, which would read as "your home directory is empty".  WARP_FILES gates this
          // app on its own, so this is the ONLY way the menu can ever learn about it.
          setTimeout(() => {
            if (filesOn && files.stats().frames === 0) {
              filesNote.textContent = 'no answer — this box is not serving the file browser';
              filesApp.served = false;
              diag('warp files: no answer from the box');
            }
          }, 5000);
        }
      }
    };
    richApps.push(filesApp);
    window.addEventListener('resize', () => { if (filesOn) files.viewport(filesFit(), 0); });
    // ==== END the file browser ================================================================

    const XK = { Enter:0xff0d, Backspace:0xff08, Tab:0xff09, Escape:0xff1b,
                 ArrowLeft:0xff51, ArrowUp:0xff52, ArrowRight:0xff53, ArrowDown:0xff54,
                 Shift:0xffe1, Insert:0xff63,
                 // the latching modifiers.  Meta is Super_L (0xffeb) rather than Meta_L (0xffe7):
                 // Super is what a Linux desktop actually binds, and what a ⌘ on a phone means.
                 Control:0xffe3, Alt:0xffe9, Meta:0xffeb };
    const tap = (keysym, code) => { rfb.sendKey(keysym, code, true); rfb.sendKey(keysym, code, false); };
    const sendChar = ch => { const cp = ch.codePointAt(0); tap(cp < 0x100 ? cp : 0x01000000 + cp, null); };

    // --- latching modifier keys ----------------------------------------------------------------
    // A phone has no Ctrl.  On a terminal that means no ^C and no ^D — you can start something and
    // then have no way to stop it — and everywhere else it means no shortcut at all.
    //
    // The mobile-terminal convention is a LATCH, and it has two depths on purpose:
    //   TAP          arms the modifier for the NEXT key, then it lets go by itself.  This is the
    //                one you want almost always: Ctrl, c, done.
    //   DOUBLE-TAP   locks it down until tapped again, for the runs where it has to stay (Ctrl-W
    //                Ctrl-W, arrowing about with Shift held).
    // The two are drawn differently — outlined vs filled-and-breathing — because a lock that looks
    // like an arm is a modifier you leave on by accident and then blame the keyboard for.
    //
    // THE ROW MUST NOT TAKE FOCUS.  iOS closes the soft keyboard the instant the hidden input
    // blurs, so a press that moved focus would dismiss the very keyboard it is modifying; every
    // press therefore preventDefaults.  Tapping a modifier while the keyboard is DOWN focuses the
    // field instead, so Ctrl doubles as "open the keyboard with Ctrl already armed".
    const MODS = [
      { id: 'ctrl',  label: 'Ctrl',  sym: XK.Control, code: 'ControlLeft' },
      { id: 'alt',   label: 'Alt',   sym: XK.Alt,     code: 'AltLeft' },
      { id: 'shift', label: 'Shift', sym: XK.Shift,   code: 'ShiftLeft' },
      { id: 'meta',  label: '⌘',     sym: XK.Meta,    code: 'MetaLeft' },
    ];
    const MOD_OFF = 0, MOD_ARMED = 1, MOD_LOCKED = 2, MOD_DBL_MS = 450;
    const modRow = document.createElement('div');
    modRow.id = 'mods';
    const paintMods = () => { for (const m of MODS)
      m.btn.dataset.mod = ['off', 'armed', 'locked'][m.state]; };
    for (const m of MODS) {
      m.state = MOD_OFF; m.last = 0;
      const b = document.createElement('button');
      b.className = 'gmod'; b.textContent = m.label; b.dataset.mod = 'off';
      b.setAttribute('aria-label', m.label + ' (tap to arm, double-tap to lock)');
      const toggle = () => {
        const t = performance.now();
        if (m.state === MOD_ARMED && t - m.last < MOD_DBL_MS) m.state = MOD_LOCKED;  // second tap
        else m.state = m.state ? MOD_OFF : MOD_ARMED;                                // arm / clear
        m.last = t; paintMods();
        diag('mod ' + m.id + ' ' + ['off', 'armed', 'locked'][m.state]);
        // the keyboard is what a modifier modifies: if it is not up, bring it up.  focus() inside
        // the gesture handler is the same route the ⌨ button takes, which iOS does honour.
        if (document.activeElement !== kbin) kbin.focus();
      };
      // Two entry points, one action.  touchend is the real one on a phone — preventDefault there
      // both keeps focus where it is and suppresses the synthetic click; the click listener is for
      // a mouse, and steps aside if a touch has just been through.
      let lastTouch = 0;
      b.addEventListener('mousedown', e => e.preventDefault());   // desktop: never blur the field
      b.addEventListener('touchend', e => { e.preventDefault(); e.stopPropagation();
                                            lastTouch = performance.now(); toggle(); },
                         { passive: false });
      b.addEventListener('click', e => { e.preventDefault(); e.stopPropagation();
        if (performance.now() - lastTouch < 700) return;          // already handled as a touch
        toggle(); });
      m.btn = b; modRow.appendChild(b);
    }
    document.body.appendChild(modRow);
    // Hold everything latched, emit the key, let go again — the same down / tap / up shape the
    // Shift+Insert paste below uses, generalised over the row.  Armed modifiers then drop; locked
    // ones stay down for the next key too.  Release is in a `finally` so a throw mid-key cannot
    // leave Ctrl held on the desktop with nothing on this end still showing it.
    const withMods = emit => {
      const held = MODS.filter(m => m.state !== MOD_OFF);
      if (!held.length) { emit(); return; }
      for (const m of held) rfb.sendKey(m.sym, m.code, true);
      try { emit(); }
      finally {
        for (let i = held.length - 1; i >= 0; i--) rfb.sendKey(held[i].sym, held[i].code, false);
        let changed = false;
        for (const m of held) if (m.state === MOD_ARMED) { m.state = MOD_OFF; changed = true; }
        if (changed) paintMods();
      }
    };
    // BOTH key routes go through these, and nothing else does: `tap`/`sendChar` stay bare so the
    // paste below can spell out its own Shift+Insert without the row joining in.
    const tapMod = (keysym, code) => withMods(() => tap(keysym, code));
    // A paste is not a keystroke, and on a phone both arrive through this one hidden input.
    // PASTE_MAX caps either route: a phone's clipboard can hold a whole document, and typing one
    // is a key event per character down the data channel — a megabyte would be a million of them.
    const PASTE_MAX = 4096;
    const clampPaste = t => (t.length > PASTE_MAX ? t.slice(0, PASTE_MAX) : t);
    // Type a string, one keysym at a time.  A newline becomes Enter rather than the character
    // U+000A, or a shell gets a literal control byte where it wanted a line.
    const sendText = t => {
      for (const ch of t) {
        if (ch === '\n' || ch === '\r') tap(XK.Enter, 'Enter'); else sendChar(ch);
      }
    };
    // What the user TYPED, as opposed to what was pasted: the latched modifiers apply, and they
    // apply to the FIRST character only.  iOS usually delivers one character per event, but
    // autocorrect and dictation deliver whole words at once — and "Ctrl armed, a word arrives"
    // means Ctrl-<first letter>, not a word with Ctrl held down through all of it.
    const sendTyped = t => {
      let first = true;
      for (const ch of t) {
        const emit = () => { if (ch === '\n' || ch === '\r') tap(XK.Enter, 'Enter'); else sendChar(ch); };
        if (first) { withMods(emit); first = false; } else emit();
      }
    };
    // A REAL modifier keydown is not a key to forward.  e.key for Shift/Control/Alt/Meta is the
    // modifier's own name, which now collides with XK — forwarding it would send a press-and-
    // release of Control every time a hardware Ctrl went DOWN, which is the opposite of holding it.
    const HWMOD = { Shift: 1, Control: 1, Alt: 1, Meta: 1 };
    kbin.addEventListener('keydown', e => {          // special keys (fire keydown even on iOS)
      if (HWMOD[e.key]) return;
      if (e.key in XK) { e.preventDefault(); tapMod(XK[e.key], e.code); }
    });
    kbin.addEventListener('beforeinput', e => {      // typed characters (iOS soft keyboard)
      const it = e.inputType;
      if (it === 'insertText' && e.data) { sendTyped(e.data); e.preventDefault(); }
      // A long-press -> Paste (and a drag-and-drop) arrives as insertFromPaste / insertFromDrop,
      // NOT insertText — so it used to match no branch and the text was thrown away by the
      // kbin.value reset at the bottom, which is why pasting on iOS silently did nothing.  This
      // is also the route that needs no clipboard permission: by the time the event fires, iOS
      // has already decided to hand us the text.  Safari puts it in .data; the spec allows
      // .dataTransfer instead, so read both.
      else if (it === 'insertFromPaste' || it === 'insertFromDrop') {
        const raw = e.data || (e.dataTransfer && e.dataTransfer.getData('text/plain')) || '';
        const t = clampPaste(raw);
        if (t) sendText(t);
        e.preventDefault();
        diag('paste: typed ' + t.length + ' chars' +
             (t.length < raw.length ? ' (capped from ' + raw.length + ')' : ''));
      }
      else if (it === 'deleteContentBackward') { tapMod(XK.Backspace, 'Backspace'); e.preventDefault(); }
      else if (it && it.startsWith('insertLine') || it === 'insertParagraph') {
        tapMod(XK.Enter, 'Enter'); e.preventDefault();
      }
      kbin.value = '';
    });

    // --- 📋 paste: hand over the whole string, don't type it ---------------------------------
    // The box now keeps a SESSION clipboard beside its framebuffer, so there are two ways to get
    // text into it and the button takes the cheap one: ClientCutText carries the whole string in
    // ONE message, and Shift+Insert then asks the desktop to paste it wherever focus is — four key
    // messages regardless of length, against one per character.  Typing stays the fallback, and is
    // the whole of the long-press route above, which needs no permission at all.
    // 📋 is an ACTION, not a toggle: there is no "paste is off", so it never wears a strike.  It
    // sits plain, flashes green when a paste goes through, and fades out entirely while there is
    // no channel to paste down.
    const pasteBtn = mkToggle('📋', 254, 'paste');
    setBtn(pasteBtn, 'disabled');                   // until the RFB channel is actually open
    const sendPaste = text => {
      const t = clampPaste(text);
      const capped = t.length < text.length ? ' (capped from ' + text.length + ')' : '';
      if (typeof rfb.clipboardPasteFrom === 'function') {
        try {
          rfb.clipboardPasteFrom(t);                    // -> ClientCutText: the session's selection
          rfb.sendKey(XK.Shift, 'ShiftLeft', true);     // -> Shift+Insert: paste it at the focus
          tap(XK.Insert, 'Insert');
          rfb.sendKey(XK.Shift, 'ShiftLeft', false);
          diag('paste: ' + t.length + ' chars as cut text + Shift+Insert' + capped);
          return;
        } catch (err) { diag('paste: cut text failed (' + (err.name || err) + ') — typing it'); }
      }
      sendText(t);
      diag('paste: typed ' + t.length + ' chars' + capped);
    };
    pasteBtn.addEventListener('click', async () => {
      let text = null;
      try {
        if (!navigator.clipboard || !navigator.clipboard.readText) throw new Error('unsupported');
        text = await navigator.clipboard.readText();   // inside the gesture — Safari requires that,
                                                       // and shows its own confirmation, which is
                                                       // the user's to make and cannot be skipped
      } catch (err) {
        // Denied, dismissed, or no async clipboard at all.  Not something to swallow: fall back to
        // the route that never needed permission — focus the hidden field so a long-press offers
        // Paste — and say which, because a button that does nothing visible reads as a broken one.
        diag('paste: clipboard read refused (' + (err.name || err) +
             ') — long-press the keyboard field and choose Paste');
        kbin.focus();
        return;
      }
      if (!text) { diag('paste: clipboard is empty'); return; }
      setBtn(pasteBtn, 'on'); setTimeout(() => setBtn(pasteBtn, 'idle'), 600);
      sendPaste(text);
    });

    // Keep the desktop above the soft keyboard: when it opens the visual viewport shrinks, so pin
    // #screen to the visible height; noVNC's ResizeObserver refits the canvas and margin:auto
    // re-centers it in the remaining space above the keyboard.
    const vv = window.visualViewport;
    if (vv) {
      const screenEl = document.getElementById('screen');
      // The controls are position:fixed over the BOTTOM of #screen.  That was invisible while
      // the desktop was letterboxed — the strip sat on empty black — and became a problem the
      // moment the desktop started taking the shape of #screen: the bottom of the actual
      // desktop went under the buttons, taking the session's name in the corner with it.
      //
      // Measured, not assumed: the buttons move when the keyboard opens, and a constant here
      // would be wrong in exactly the state somebody is looking at it.
      // THE DESKTOP'S SIZE MUST NOT DEPEND ON WHERE OUR OWN BUTTONS ARE.  This used to
      // measure the topmost control and stop the desktop above it, which is what made
      // resizing wonky in every direction at once: the modifier row moves when the
      // keyboard opens, so the desktop resized to follow furniture; the measurement
      // happened two frames later, so an old one could land after a new one and leave the
      // desktop the size of the space above a keyboard that was gone; and the desktop was
      // permanently ~120px shorter than the screen to reserve room for buttons that are
      // fixed, translucent and drawn OVER it anyway.
      //
      // 100svh is the small viewport — the height with the browser's bars SHOWN.  It is
      // the largest height that is always fully visible, and unlike 100vh/dvh it does not
      // change when those bars collapse on scroll, so the desktop holds still.  No
      // measuring pass, nothing to race, and the controls float on top where they were
      // always going to be.
      const fitViewport = () => {
        const lift = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
        const up = lift > 120;                                   // keyboard (not just a rotation)
        // THE KEYBOARD MUST NOT RESIZE THE DESKTOP.  Shrinking #screen to sit above it is
        // right — the picture should stay visible — but noVNC answers any container
        // change by asking the desktop to become that size, and fb-resize CLEARS the
        // framebuffer.  So opening the keyboard to type rebuilt the desktop underneath
        // the typing, which is exactly when it is least welcome.
        //
        // The desktop's size should follow the LAYOUT viewport, which the keyboard does
        // not move.  Suppress the request while it is up, restore on the way down, and
        // let scaleViewport fit the unchanged desktop into the smaller space.
        if (typeof rfb !== 'undefined' && rfb) rfb.resizeSession = !up;
        screenEl.style.height = up ? vv.height + 'px' : '100vh';
        // iOS pins position:fixed to the LAYOUT viewport, so the modifier row would slide UNDER
        // the keyboard exactly when it is wanted.  Lift it to sit ON TOP of the keyboard instead,
        // where an accessory row belongs; at rest it drops back above the button row.
        document.documentElement.style.setProperty('--mods-bottom', (up ? lift + 10 : 78) + 'px');
        // ...then measure, because the line above is what moved them.  Two frames: the style
        // has to land before getBoundingClientRect means anything.
        // Keyboard up: sit in the space above it, and (see above) DON'T ask the desktop to
        // become that shape — the picture just scales into what is left.  Keyboard down:
        // the whole visible viewport, which is also the size the desktop already is, so
        // the request that follows is a no-op rather than a rebuild.
        screenEl.style.height = up ? vv.height + 'px' : '100svh';
      };
      vv.addEventListener('resize', fitViewport);
      vv.addEventListener('scroll', fitViewport);
      fitViewport();
    }

    // --- virtual trackpad (touch only): relative cursor motion, so your fingertip never hides the
    // target.  Drag = move cursor · quick tap = left-click · two-finger tap = right-click ·
    // pinch = zoom · two-finger drag = pan when zoomed / scroll when not · press-and-hold = grab
    // (a second concentric arc sweeps clockwise; when it closes the grab locks left, so you drag
    // windows / select until you lift).  Real mice keep noVNC's absolute pointer.
    //
    // Zoom is our own transform ON THE CANVAS (origin 0 0) — noVNC scales via the canvas's CSS
    // width/height and maps pointers with that (untransformed) scale, so our transform is free and
    // the pointer math stays exact.  vx/vy live in noVNC's element space [0, canvas.clientWidth];
    // the cursor ring maps to the screen through sx = rect.width / clientWidth (= our zoom).
    (() => {
      const screen = document.getElementById('screen');
      const canvasOf = () => screen.querySelector('canvas');
      const SENS = 1.6, TAP_MS = 250, TAP_SLOP = 10, SCROLL_PX = 24, ZMAX = 6, SL_SLOP = 30;
      const HOLD_MS = 500, ARM_AT = HOLD_MS / 2;             // press-and-hold to grab; arm at half
      let vx = 0, vy = 0, posInit = false, mask = 0;         // cursor (element px) + held buttons
      let lastX = 0, lastY = 0, startT = 0, moved = 0, fingers = 0;
      let dragging = false, scrollAcc = 0, holdRAF = 0, holdStart = 0;
      let zoom = 1, tx = 0, ty = 0;                          // our canvas transform (pan + zoom)
      let multi = false, multiT = 0, dPrev = 0, mpx = 0, mpy = 0, pinchMoved = 0;
      let slRAF = 0, slStart = 0, scrollLock = false, slAccX = 0, slAccY = 0;   // two-finger scroll-lock
      let slBaseX = 0, slBaseY = 0, slBaseD = 0;             // hold-start baseline (net-displacement arming)
      const nowMs = () => performance.now();
      const dist = ts => Math.hypot(ts[0].clientX - ts[1].clientX, ts[0].clientY - ts[1].clientY);
      // white cursor drawn as SVG: an inner ring is the pointer; an outer arc grows clockwise as the
      // press-and-hold arms and, when it closes into a full second concentric ring, the grab locks.
      const NS = 'http://www.w3.org/2000/svg', C = 2 * Math.PI * 12;
      const svgEl = (n, a) => { const el = document.createElementNS(NS, n);
        for (const k in a) el.setAttribute(k, a[k]); return el; };
      const cur = svgEl('svg', { width: 40, height: 40, viewBox: '0 0 40 40' });
      cur.style.cssText = 'position:fixed;margin:-20px 0 0 -20px;pointer-events:none;z-index:15;display:none;overflow:visible';
      // each ring is drawn twice — a wider DARK stroke behind a white one — for a crisp dark outline,
      // so the cursor reads on light AND dark backgrounds (a soft drop-shadow washed out on white).
      const DARK = 'rgba(0,0,0,.9)';
      const innerBg = svgEl('circle', { cx: 20, cy: 20, r: 8, fill: 'none', stroke: DARK, 'stroke-width': 5 });
      const inner   = svgEl('circle', { cx: 20, cy: 20, r: 8, fill: 'none', stroke: '#fff', 'stroke-width': 2 });
      const arcA = { cx: 20, cy: 20, r: 12, fill: 'none', 'stroke-linecap': 'round',
                     transform: 'rotate(-90 20 20)', 'stroke-dasharray': C, 'stroke-dashoffset': C };
      const arcBg = svgEl('circle', { ...arcA, stroke: DARK, 'stroke-width': 5 });
      const arc   = svgEl('circle', { ...arcA, stroke: '#fff', 'stroke-width': 2 });
      cur.append(arcBg, arc, innerBg, inner); document.body.appendChild(cur);    // dark backs drawn first
      const setArc = o => { arc.setAttribute('stroke-dashoffset', o); arcBg.setAttribute('stroke-dashoffset', o); };
      const ringIdle = () => setArc(C);                                          // outer arc hidden
      const ringArm  = p  => setArc(C * (1 - p));                                // grows clockwise
      const ringGrab = () => setArc(0);                                          // full second ring = grabbed
      const applyT = () => {                                 // push pan/zoom onto the canvas
        const c = canvasOf(); if (!c) return;
        if (zoom <= 1.001) { zoom = 1; tx = 0; ty = 0; c.style.transform = ''; }
        else { c.style.transformOrigin = '0 0'; c.style.transform = `translate(${tx}px,${ty}px) scale(${zoom})`; }
        syncVid(c);
      };
      // Keep the video glued to the canvas by giving it the IDENTICAL transform, rather than
      // re-positioning it from the canvas's (already transformed) rect: transforms are composited,
      // so both surfaces move together on the same frame instead of the video lagging a layout
      // behind.  The plain box is only written while unzoomed, where it is stable.
      // The trackpad OWNS the pan/zoom, so it publishes it: the module-level SYNCVIDEONOW needs it
      // to restate the video's box and its transform TOGETHER.  Without this it can only see the
      // canvas's already-zoomed rect, and writing that underneath an unchanged transform is what
      // put the picture off-screen on a resize or a resume taken while zoomed.
      window.__vidXform = () => ({ zoom, tx, ty });
      const syncVid = (c) => {
        const v = window.__vidEl; if (!v || !window.__videoPrimary) return;
        if (zoom <= 1.001) {
          const r = c.getBoundingClientRect();
          if (!r.width) return;
          v.style.transform = '';
          v.style.left = r.left + 'px'; v.style.top = r.top + 'px';
          v.style.width = r.width + 'px'; v.style.height = r.height + 'px';
        } else {
          v.style.transformOrigin = '0 0';
          v.style.transform = `translate(${tx}px,${ty}px) scale(${zoom})`;
        }
      };
      const clampPan = () => {                               // keep the zoomed canvas covering #screen
        const c = canvasOf(); if (!c || zoom <= 1.001) return;
        const s = screen.getBoundingClientRect(), r = c.getBoundingClientRect();
        let dx = 0, dy = 0;
        if (r.width <= s.width) dx = s.left + (s.width - r.width) / 2 - r.left;
        else if (r.left > s.left) dx = s.left - r.left; else if (r.right < s.right) dx = s.right - r.right;
        if (r.height <= s.height) dy = s.top + (s.height - r.height) / 2 - r.top;
        else if (r.top > s.top) dy = s.top - r.top; else if (r.bottom < s.bottom) dy = s.bottom - r.bottom;
        if (dx || dy) { tx += dx; ty += dy; c.style.transform = `translate(${tx}px,${ty}px) scale(${zoom})`;
                        syncVid(c); }
      };
      const SAFE = 0.25;                                     // cursor roams the central 50%; view pans past that
      const followCursor = (frac = SAFE) => {                // pan a zoomed view to keep the cursor in a band
        const c = canvasOf(); if (!c || zoom <= 1.001) return;
        const s = screen.getBoundingClientRect(), r = c.getBoundingClientRect();
        const sx = c.clientWidth ? r.width / c.clientWidth : 1, sy = c.clientHeight ? r.height / c.clientHeight : 1;
        const cxs = r.left + vx * sx, cys = r.top + vy * sy; // cursor's screen position
        const mx = s.width * frac, my = s.height * frac;
        let dx = 0, dy = 0;
        if (cxs < s.left + mx) dx = s.left + mx - cxs; else if (cxs > s.right - mx) dx = s.right - mx - cxs;
        if (cys < s.top + my) dy = s.top + my - cys; else if (cys > s.bottom - my) dy = s.bottom - my - cys;
        if (dx || dy) { tx += dx; ty += dy; applyT(); clampPan(); }  // clampPan stops us panning past the edge
      };
      const clampCursorToFrame = () => {                     // move the CURSOR (not the view) to keep it on-screen
        const c = canvasOf(); if (!c || zoom <= 1.001) return false;
        const s = screen.getBoundingClientRect(), r = c.getBoundingClientRect();
        const sx = c.clientWidth ? r.width / c.clientWidth : 1, sy = c.clientHeight ? r.height / c.clientHeight : 1;
        const EDGE = 24;                                      // keep the ~20px ring off the very edge
        const loX = Math.max(0, (s.left + EDGE - r.left) / sx), hiX = Math.min(c.clientWidth - 1, (s.right - EDGE - r.left) / sx);
        const loY = Math.max(0, (s.top + EDGE - r.top) / sy), hiY = Math.min(c.clientHeight - 1, (s.bottom - EDGE - r.top) / sy);
        const nvx = Math.min(Math.max(vx, loX), hiX), nvy = Math.min(Math.max(vy, loY), hiY);
        if (nvx !== vx || nvy !== vy) { vx = nvx; vy = nvy; return true; }
        return false;
      };
      const place = () => {                                  // ring at the cursor's framebuffer point
        const c = canvasOf(); if (!c) return;
        const r = c.getBoundingClientRect();
        const sx = c.clientWidth ? r.width / c.clientWidth : 1, sy = c.clientHeight ? r.height / c.clientHeight : 1;
        cur.style.left = (r.left + vx * sx) + 'px'; cur.style.top = (r.top + vy * sy) + 'px'; cur.style.display = 'block';
      };
      const ensurePos = () => {
        if (posInit) return; const c = canvasOf(); if (!c) return;
        vx = c.clientWidth / 2; vy = c.clientHeight / 2; posInit = true;
      };
      const move = () => {
        const c = canvasOf(); if (!c) return;
        vx = Math.max(0, Math.min(c.clientWidth - 1, vx)); vy = Math.max(0, Math.min(c.clientHeight - 1, vy));
        rfb._sendMouse(vx, vy, mask); followCursor(); place();
      };
      const click = bit => { rfb._sendMouse(vx, vy, mask | bit); rfb._sendMouse(vx, vy, mask); };
      // --- scroll direction (TOUCH ONLY) ---------------------------------------------------
      // Apple-style "natural" scrolling: the content follows the fingers.  Drag DOWN and the
      // content moves DOWN — which is a wheel-UP event — and drag RIGHT and it moves RIGHT,
      // a wheel-LEFT.  Traditional (the inverse) is what an unmodified wheel does.
      //
      // The whole thing is ONE sign flip, applied where the wheel bit is chosen, so the
      // handlers below stay written in the obvious "acc > 0 means the fingers went down/right"
      // form and this is a single line to revert or hang a setting off.  It does NOT touch the
      // mouse: we register no mouse/wheel/pointer listeners at all, so a real wheel goes
      // straight to noVNC's own handler and stays traditional.
      const NATURAL_TOUCH_SCROLL = true;
      const SDIR = NATURAL_TOUCH_SCROLL ? -1 : 1;
      const W_UP = 1 << 3, W_DOWN = 1 << 4, W_LEFT = 1 << 5, W_RIGHT = 1 << 6;
      const wheelV = acc => (acc * SDIR > 0 ? W_DOWN : W_UP);    // acc > 0: fingers moved DOWN
      const wheelH = acc => (acc * SDIR > 0 ? W_RIGHT : W_LEFT); // acc > 0: fingers moved RIGHT
      const cancelHold = () => { if (holdRAF) { cancelAnimationFrame(holdRAF); holdRAF = 0; } if (!dragging) ringIdle(); };
      const startHold = () => {                              // arm a grab; a plain move cancels it
        holdStart = nowMs();
        const tick = () => {
          const el = nowMs() - holdStart;
          if (el >= HOLD_MS) { dragging = true; mask |= 1; ringGrab(); move(); holdRAF = 0; return; }
          if (el >= ARM_AT) ringArm((el - ARM_AT) / (HOLD_MS - ARM_AT));
          holdRAF = requestAnimationFrame(tick);
        };
        holdRAF = requestAnimationFrame(tick);
      };
      // --- two-finger scroll-lock: the two-finger analog of press-and-hold-to-grab ---
      // Hold two fingers still and the ring arms at their midpoint; when it closes, "scroll lock"
      // engages: two-finger drag then scrolls content BOTH axes (wheel events) and no longer
      // zooms/pans the view.  Move before it closes -> arming cancels -> normal pinch/zoom/pan.
      const cancelSL = () => { if (slRAF) { cancelAnimationFrame(slRAF); slRAF = 0; } if (!scrollLock) ringIdle(); };
      const startSLHold = () => {                            // arm scroll-lock; a real pinch/pan cancels it
        slStart = nowMs();
        const tick = () => {
          const el = nowMs() - slStart;
          if (el >= HOLD_MS) { scrollLock = true; slAccX = slAccY = 0; ringGrab(); slRAF = 0; return; }
          if (el >= ARM_AT) ringArm((el - ARM_AT) / (HOLD_MS - ARM_AT));
          slRAF = requestAnimationFrame(tick);
        };
        slRAF = requestAnimationFrame(tick);
      };
      const opt = { capture: true, passive: false };
      screen.addEventListener('touchstart', e => {
        e.preventDefault(); e.stopPropagation(); ensurePos();
        fingers = e.touches.length;
        if (fingers >= 2) {                                   // second finger: begin a pinch/pan
          multi = true; multiT = nowMs(); pinchMoved = 0; cancelHold();
          dPrev = dist(e.touches);
          mpx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
          mpy = (e.touches[0].clientY + e.touches[1].clientY) / 2;
          scrollLock = false; place();
          slBaseX = mpx; slBaseY = mpy; slBaseD = dPrev; startSLHold();   // arm two-finger scroll-lock (net-displacement)
          return;
        }
        multi = false; const t = e.touches[0];               // fresh one-finger gesture
        lastX = t.clientX; lastY = t.clientY; startT = nowMs(); moved = 0; scrollAcc = 0;
        ringIdle(); move(); startHold();
      }, opt);
      screen.addEventListener('touchmove', e => {
        e.preventDefault(); e.stopPropagation();
        if (e.touches.length >= 2) {                          // pinch = zoom, translate = pan/scroll
          cancelHold();
          const d = dist(e.touches);
          const mx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
          const my = (e.touches[0].clientY + e.touches[1].clientY) / 2;
          if (scrollLock) {                                   // scroll-lock: two-finger drag scrolls H+V; no zoom/pan
            const pdx = mx - mpx, pdy = my - mpy;
            slAccY += pdy; slAccX += pdx;
            while (Math.abs(slAccY) >= SCROLL_PX) { const dn = slAccY > 0; click(wheelV(slAccY)); slAccY += dn ? -SCROLL_PX : SCROLL_PX; }
            while (Math.abs(slAccX) >= SCROLL_PX) { const rt = slAccX > 0; click(wheelH(slAccX)); slAccX += rt ? -SCROLL_PX : SCROLL_PX; }
            dPrev = d; mpx = mx; mpy = my; place(); ringGrab(); return;
          }
          if (slRAF) {                                        // ring still arming: park (no zoom/pan) unless a real pinch/pan
            if (Math.hypot(mx - slBaseX, my - slBaseY) > SL_SLOP || Math.abs(d - slBaseD) > SL_SLOP) {
              cancelSL();                                     // deliberate movement -> fall through to pinch/pan
            } else {
              dPrev = d; mpx = mx; mpy = my; place(); return;   // held still -> keep arming the ring
            }
          }
          if (dPrev > 0) {
            const z2 = Math.max(1, Math.min(ZMAX, zoom * d / dPrev));
            if (z2 !== zoom) {                                // zoom about the pinch midpoint (natural pinch)
              const r = canvasOf().getBoundingClientRect();
              tx += (mx - r.left) * (1 - z2 / zoom); ty += (my - r.top) * (1 - z2 / zoom); zoom = z2;
            }
          }
          const pdx = mx - mpx, pdy = my - mpy;
          if (zoom > 1.001) { tx += pdx; ty += pdy; applyT(); clampPan();
            // zoom gesture stays pure: slide the CURSOR back on-screen instead of panning the view
            if (clampCursorToFrame()) rfb._sendMouse(vx, vy, mask); }
          else {                                              // not zoomed: two-finger drag = scroll
            applyT(); scrollAcc += pdy;
            while (Math.abs(scrollAcc) >= SCROLL_PX) {
              const dn = scrollAcc > 0; click(wheelV(scrollAcc)); scrollAcc += dn ? -SCROLL_PX : SCROLL_PX;
            }
          }
          pinchMoved += Math.abs(d - dPrev) + Math.abs(pdx) + Math.abs(pdy);
          dPrev = d; mpx = mx; mpy = my; place(); return;
        }
        if (multi) { lastX = e.touches[0].clientX; lastY = e.touches[0].clientY; return; }  // leftover finger
        const t = e.touches[0], dx = t.clientX - lastX, dy = t.clientY - lastY;
        lastX = t.clientX; lastY = t.clientY; moved += Math.abs(dx) + Math.abs(dy);
        if (!dragging && moved > TAP_SLOP) cancelHold();      // moving = a plain cursor move, not a grab
        vx += dx * SENS / zoom; vy += dy * SENS / zoom; move();  // finer control the more you're zoomed
      }, opt);
      screen.addEventListener('touchend', e => {
        e.preventDefault(); e.stopPropagation();
        if (e.touches.length > 0) {                           // a finger lifted, others remain
          lastX = e.touches[0].clientX; lastY = e.touches[0].clientY;
          if (e.touches.length >= 2) { dPrev = dist(e.touches);
            mpx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
            mpy = (e.touches[0].clientY + e.touches[1].clientY) / 2; }
          return;
        }
        if (dragging) { dragging = false; mask &= ~1; move(); }
        else if (multi) { if (!scrollLock && pinchMoved < 14 && (nowMs() - multiT) < 350) click(1 << 2); }  // 2-finger tap = right
        else if ((nowMs() - startT) < TAP_MS && moved < TAP_SLOP) click(1 << 0);              // 1-finger tap = left
        scrollLock = false; slAccX = slAccY = 0; cancelSL(); cancelHold(); fingers = 0; multi = false;
      }, opt);
      screen.addEventListener('touchcancel', () => {
        if (dragging) { dragging = false; mask &= ~1; move(); } scrollLock = false; slAccX = slAccY = 0; cancelSL(); cancelHold(); fingers = 0; multi = false;
      }, opt);
    })();


    // ---- the counters the hud reports ------------------------------------------------------
    let frames = 0, bytesIn = 0, msgsIn = 0;

    let gotFirstFrame = false;
    const origFBU = rfb._framebufferUpdate.bind(rfb);
    rfb._framebufferUpdate = function () { const done = origFBU();
      if (done) { frames++; if (!gotFirstFrame) { gotFirstFrame = true; api.ui.hideConn(); api.clearReconnAttempts(); } } return done; };

    ch.addEventListener('message', e => { bytesIn += (e.data.byteLength ?? e.data.length ?? 0); msgsIn++; });

    // copy button: grab the whole report to the clipboard (so it's easy to paste back on mobile)
    const copyBtn = document.createElement('button');
    copyBtn.textContent = '⧉ copy';
    copyBtn.style.cssText = 'position:fixed;top:3px;right:4px;z-index:14;font:11px ui-monospace,monospace;' +
      'background:rgba(0,0,0,.8);color:#7CFC9B;border:1px solid #7CFC9B;border-radius:5px;padding:3px 8px';
    document.body.appendChild(copyBtn);
    copyBtn.addEventListener('click', async () => {
      const report = [
        'glass-webrtc diag @ ' + new Date().toISOString(),
        'ua: ' + navigator.userAgent,
        'url: ' + location.href.replace(/code=[^&]+/, 'code=…'),   // don't leak the code
        '', hud.innerText, '--- log ---', ...diagLines,
      ].join('\n');
      let ok = false;
      try { await navigator.clipboard.writeText(report); ok = true; } catch (_) {
        const ta = document.createElement('textarea');           // iOS-safe fallback
        ta.value = report; ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
        document.body.appendChild(ta); ta.focus(); ta.setSelectionRange(0, report.length);
        try { ok = document.execCommand('copy'); } catch (_) {} ta.remove();
      }
      copyBtn.textContent = ok ? '✓ copied' : '✗ failed';
      setTimeout(() => { copyBtn.textContent = '⧉ copy'; }, 1600);
    });
    // debug toggle: bottom-left button to show/hide the whole diagnostics overlay (hud + log + copy)
    const dbgBtn = document.createElement('button');
    dbgBtn.appendChild(gGlyph('≡'));
    dbgBtn.className = 'gbtn';                      // same three states as the rest of the row
    dbgBtn.dataset.state = 'off';
    dbgBtn.setAttribute('aria-label', 'diagnostics');
    dbgBtn.style.cssText += 'bottom:14px;left:14px;z-index:31;font-size:26px';
    document.body.appendChild(dbgBtn);
    let dbgOn = false;                              // debug overlay hidden by default; ≡ toggles it
    const applyDbg = () => {
      // 'block', NOT '': the shell hides #hud/#diag in ITS stylesheet so they cannot flash before
      // this file arrives, and clearing the inline style hands the decision straight back to that
      // rule.  Showing therefore has to NAME a display, or the toggle silently does nothing --
      // which is exactly what it did between the flicker fix and this one.  copyBtn keeps '',
      // because no stylesheet rule hides it and its natural display is the right one.
      const d = dbgOn ? 'block' : 'none';
      hud.style.display = d; api.ui.diagEl.style.display = d;
      copyBtn.style.display = dbgOn ? '' : 'none';
      document.body.classList.toggle('dbg', dbgOn);   // moves the link pill clear of the hud
      setBtn(dbgBtn, dbgOn ? 'on' : 'off');
      // debug view and the clean connecting overlay are mutually exclusive: showing debug hides the
      // overlay; hiding debug brings the overlay back if we're still connecting (before first frame).
      if (dbgOn) connEl.style.display = 'none';
      else if (!api.ui.isConnHidden()) { connEl.style.display = ''; connEl.style.opacity = ''; }
    };
    dbgBtn.addEventListener('click', () => { dbgOn = !dbgOn; applyDbg(); });
    applyDbg();

    onOpen(ch, () => { diag('datachannel OPEN'); setStep(3);
                       setBtn(pasteBtn, 'idle'); });
    // The session is gone, so none of these can do anything — and "cannot" has to look different
    // from "off", or the row goes on inviting taps that will not land.
    ch.addEventListener('close', () => { diag('datachannel CLOSE');
      for (const b of [pasteBtn, micBtn, spkBtn, qBtn]) setBtn(b, 'disabled'); });
    ch.addEventListener('error', e => diag('datachannel ERROR ' + ((e.error && e.error.message) || '')));
    // The handshake is the only place the box says what it is called, so it is the only place
    // that can teach the progress screen for next time.  See LEARNT-NAME.
    rfb.addEventListener('connect', () => { diag('RFB connect'); api.learnWho(rfb._fbName); });
    rfb.addEventListener('disconnect', e => diag('RFB disconnect ' + ((e.detail && e.detail.clean) ? 'clean' : 'UNCLEAN')));
    rfb.addEventListener('securityfailure', e => diag('RFB security-fail ' + ((e.detail && e.detail.reason) || '')));
    // heartbeat every 10s — but only log it when something's NOT fully healthy or the state
    // changed, so a steady-good session doesn't spam identical ♥ lines.
    let lastHb = '';
    setInterval(() => {
      const hb = `pc=${pc.connectionState} ice=${pc.iceConnectionState} dc=${ch.readyState} rfb=${rfb._rfbConnectionState || '?'}`;
      const healthy = pc.connectionState === 'connected' && ch.readyState === 'open' && rfb._rfbConnectionState === 'connected';
      if (!healthy || hb !== lastHb) diag('♥ ' + hb);
      lastHb = hb;
    }, 10000);

    // getStats: which candidate pair won (host/srflx/relay), its rtt, and transport rx bytes
    let pathStr = 'path …', lastRx = 0, lastRxT = performance.now();
    let vidKbs = 0, vidFps = 0, lastVid = null;      // the VP8 stream's own rate, for the quality panel
    let lastKeyAsk = 0;                              // rate-limits the "I still have no picture" ask
    let lastHeal = 0;                                // ... and the repaint watchdog's intervention
    async function pollPath() {
      try {
        const s = await pc.getStats(); let pair = null;
        s.forEach(r => { if (r.type === 'candidate-pair' && r.state === 'succeeded' && (r.nominated || r.selected)) pair = r; });
        if (!pair) s.forEach(r => { if (r.type === 'transport' && r.selectedCandidatePairId) pair = s.get(r.selectedCandidatePairId); });
        if (pair) {
          const lc = s.get(pair.localCandidateId), rc = s.get(pair.remoteCandidateId);
          const rtt = pair.currentRoundTripTime != null ? Math.round(pair.currentRoundTripTime * 1000) + 'ms' : '?';
          const rx = pair.bytesReceived || 0, now = performance.now();
          const rate = ((rx - lastRx) / 1024 / ((now - lastRxT) / 1000)) || 0; lastRx = rx; lastRxT = now;
          noteRxSig(pair);           // the liveness signal — see the note above checkLink()
          const path = `${lc ? lc.candidateType : '?'}→${rc ? rc.candidateType : '?'}`;
          if (pathStr.indexOf(path) < 0) diag('PATH ' + path + ' via ' + (rc ? rc.protocol + ' ' + (rc.address || '?') : '?'));
          if (!api.ui.isConnHidden()) setDetail(2, `${path.replace('→', ' → ')}${rtt !== '?' ? '  ·  ' + rtt : ''}`);
          pathStr = `path ${path} rtt ${rtt} rx ${(rx/1024).toFixed(0)}KB ${rate.toFixed(0)}KB/s`;
        } else pathStr = 'path (no pair)';
        // the VIDEO's own rate and frame rate — dc-in above is the RFB channel, which in
        // video-primary mode carries input only.  This is the number a quality profile moves.
        let v = null; s.forEach(r => { if (r.type === 'inbound-rtp' && r.kind === 'video') v = r; });
        if (v) {
          const now = performance.now();
          if (lastVid) {
            const dt = (now - lastVid.t) / 1000;
            if (dt > 0.2) {
              vidKbs = ((v.bytesReceived || 0) - lastVid.b) / 1024 / dt;
              vidFps = ((v.framesDecoded || 0) - lastVid.f) / dt;
            }
          }
          // A DECIMAL, because the bottom of the ladder is 0.61 KB/s and "0 KB/s" beside a working
          // stream reads as a dead one.  kbps too — that is the unit the rung is named in.
          const prevB = lastVid ? lastVid.b : 0;
          lastVid = { t: now, b: v.bytesReceived || 0, f: v.framesDecoded || 0 };
          qRate.textContent = `${vidKbs.toFixed(1)} KB/s · ${(vidKbs * 8.192).toFixed(0)} kbps · ` +
                              `${vidFps.toFixed(0)} fps · ${api.video.presented()} shown`;
          // ---- THE REPAINT WATCHDOG ---------------------------------------------------------
          // The user should not have to pinch.  Bytes arriving is already measured above; what
          // this adds is whether those bytes reach the GLASS, and it distinguishes the two ways
          // they can fail to, because the corrective action is different for each:
          //
          //   * PLAYBACK.  The element is paused — nothing is being presented however much
          //     arrives.  Only play() helps, and only a policy can refuse it.
          //   * LAYOUT.  Frames are being presented, into a box that is 1x1 (never synced, because
          //     noVNC's canvas was not ready when we first looked) or wholly outside the viewport
          //     (the double-applied zoom above).  play() cannot help; restating the geometry can.
          //
          // Both are checked only while bytes are actually moving, so a genuinely dead link is
          // reported as dead rather than nudged forever, and at most one intervention every 3 s.
          const moving = vidKbs > 0.05;
          const vr = vidEl.getBoundingClientRect();
          const offscreen = vr.width < 2 || vr.height < 2 || vr.right <= 0 || vr.bottom <= 0 ||
                            vr.left >= innerWidth || vr.top >= innerHeight;
          const dark = api.video.presentedAt() && (now - api.video.presentedAt() > 4000);
          if (videoPrimary && moving && now - lastHeal > 3000) {
            if (vidEl.paused) {
              lastHeal = now;
              diag(`PAUSED with ${vidKbs.toFixed(1)} KB/s arriving — play()`);
              api.video.play('watchdog', true);
            } else if (dark) {
              lastHeal = now;
              diag(`no frame presented for ${((now - api.video.presentedAt()) / 1000).toFixed(1)}s ` +
                   `(rs${vidEl.readyState} ${vidEl.videoWidth}x${vidEl.videoHeight}) — play() + resync`);
              api.video.play('stalled', true); syncVideo(); api.video.nudge();
            } else if (offscreen && api.video.presented() > 0) {
              lastHeal = now;
              diag(`presenting into an unseeable box ${Math.round(vr.width)}x${Math.round(vr.height)}` +
                   ` @ ${Math.round(vr.left)},${Math.round(vr.top)} — resync`);
              syncVideo(); api.video.nudge();
            }
          }
          // THE RECOVERY PATH.  The box parses no RTCP, so it cannot hear a PLI — if our decoder
          // never got a keyframe there is nothing to tell it except this channel, and its own blind
          // resync is minutes away at the low rungs by design.  Ask, but only when nothing is
          // already on its way: a keyframe takes 35 s to arrive at 5 kbps, and re-asking while it
          // is still in flight would restart it forever.
          if (videoPrimary && ctrl.readyState === 'open' && !(v.framesDecoded > 0) &&
              (v.bytesReceived || 0) === prevB && now - tStart > 6000 &&
              now - lastKeyAsk > 20000) {
            lastKeyAsk = now;
            ctrl.send(JSON.stringify({ request: 'keyframe' }));
            diag('no frame decoded and nothing arriving — keyframe requested');
          }
        }
      } catch (_) { pathStr = 'path stats-err'; }
    }

    let last = performance.now();
    setInterval(() => {
      // NOT pollPath() and NOT checkLink(): the SHELL owns both clocks now.  It drives pollPath
      // through api.setPoll once a second and on resume, and checkLink is its own — the pill has to
      // go on working in a session where no payload ever arrived.  This interval is the hud alone.
      const now = performance.now(), dt = (now - last) / 1000; last = now;
      const fps = frames / dt, kbs = bytesIn / 1024 / dt, mps = msgsIn / dt;
      frames = bytesIn = msgsIn = 0;
      const buf = ch.bufferedAmount || 0;
      hud.innerHTML =
        `pc <b>${pc.connectionState}</b> · ice <b>${pc.iceConnectionState}</b> · dc <b>${ch.readyState}</b>\n` +
        `${pathStr}\n` +
        `dc-in <b>${kbs.toFixed(0)}</b>KB/s ${mps.toFixed(0)}msg · buf ${(buf/1024).toFixed(0)}KB · fps <b>${fps.toFixed(0)}</b>\n` +
        // PRESENTED frames beside decoded ones, because that pair is the diagnosis: both climbing
        // and a blank screen means the layer is in the wrong place; "shown" frozen means playback.
        `vid <b>${vidKbs.toFixed(1)}</b>KB/s · <b>${vidFps.toFixed(0)}</b>fps · shown <b>${api.video.presented()}</b>` +
        `${vidEl.paused ? ' <b>PAUSED</b>' : ''}${api.video.playFails() ? ' play✗' + api.video.playFails() : ''}` +
        ` · rung <b>${qCurrent != null ? qCurrent + 'kbps' : '?'}</b>\n` +
        `rfb ${rfb._rfbConnectionState || '?'} · ${rfb._fbName || '—'}`;
      console.log(`PERF ${(now/1000).toFixed(1)} ${fps.toFixed(1)} ${kbs.toFixed(1)} ${mps.toFixed(1)} ${(buf/1024).toFixed(1)}`);
    }, 1000);

  // ---- take over the video's geometry ----------------------------------------------------------
  // THE VIDEO'S BOX IS THE CANVAS'S *UNTRANSFORMED* RECT AND THE ZOOM IS A TRANSFORM ON TOP OF IT.
  // That is the invariant, and breaking it is what produced a blank screen a pinch cured.
  //
  // The trackpad zooms by transforming the canvas and gives the video the IDENTICAL transform (see
  // SYNCVID above), so the canvas's getBoundingClientRect() ALREADY CONTAINS the zoom.  Writing that
  // rect into the video's left/top/width/height while the video still carries the transform applies
  // the zoom TWICE: at zoom 2 with any pan the picture lands wholly outside the viewport, with
  // frames still arriving, still decoding and still being presented — into a layer nobody can see.
  //
  // So read the transform the trackpad is holding (it publishes it as window.__vidXform), undo it to
  // recover the untransformed rect, and restate BOTH halves together.
  //
  // INSTALLED LAST, on purpose.  Until this line the shell's letterbox owns the box and the desktop
  // has been visible for however long the payload took to arrive; from here the canvas owns it, and
  // the canvas exists because RFB above created it.  Handing over before noVNC had drawn a canvas
  // would put the picture back at 1x1 — which is the shell's whole reason for owning it first.
  let syncTries = 0;
  api.video.setGeometryOwner(() => {
    if (!videoPrimary) return;
    const c = document.querySelector('#screen canvas');
    const r = c && c.getBoundingClientRect();
    if (!r || !r.width || !r.height) {
      // noVNC creates and sizes this canvas from its own handshake, so it may not exist yet.  Come
      // back for it rather than leaving the video wherever it happens to be.
      if (syncTries++ < 40) setTimeout(syncVideo, 250);
      return;
    }
    syncTries = 0;
    const x = (window.__vidXform && window.__vidXform()) || null;
    if (x && x.zoom > 1.001) {          // transform-origin 0 0: rect = untransformed + t, scaled
      vidEl.style.left = (r.left - x.tx) + 'px'; vidEl.style.top = (r.top - x.ty) + 'px';
      vidEl.style.width = (r.width / x.zoom) + 'px'; vidEl.style.height = (r.height / x.zoom) + 'px';
      vidEl.style.transformOrigin = '0 0';
      vidEl.style.transform = `translate(${x.tx}px,${x.ty}px) scale(${x.zoom})`;
    } else {
      vidEl.style.transform = '';
      vidEl.style.left = r.left + 'px'; vidEl.style.top = r.top + 'px';
      vidEl.style.width = r.width + 'px'; vidEl.style.height = r.height + 'px';
    }
  });

  // The shell polls once a second and on resume; this is what it polls.  Registered at the end so a
  // half-initialised payload is never called back into.
  api.setPoll(pollPath);
  // A nap is not a rate, and a counter read before one is not evidence.  Both of these are only
  // wrong in the direction that matters: without them, returning from twenty minutes in the
  // background produces a KB/s computed over twenty minutes, and an rxSig that "advanced" while
  // nothing was being asked.
  api.onResumeHooks.push(() => { lastVid = null; rxSig = -1; });

  diag('payload ready — input, trackpad, quality, panels');
}
