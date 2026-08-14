// shell.js — everything that must exist BEFORE there is a connection.
//
// ===================================================================================================
// WHAT THIS FILE IS FOR
// ===================================================================================================
//
// The client used to be one 329 KB page published to nsite.  Every client change meant a new tag, a
// publish, a check-deploy, a re-pointed site-url.env and a user reloading at a NEW url — because
// publishing REPLACES the manifest and the previous tag 404s.  That happened four times in one day.
//
// So the page is split in two along the only line that is actually forced:
//
//   SHELL    what must run before a connection exists, and therefore cannot arrive over one.
//            Signalling (nostr-tools), the PeerConnection and its channels, credentials, the
//            progress screen, error reporting, and the desktop-name display.  This is published
//            to nsite, and the whole point is that it stops changing.
//
//   PAYLOAD  everything that only matters once the connection is up: noVNC, the trackpad, the
//            modifier row, paste, the quality ladder, the warp panel, the repaint watchdog.  This
//            is served by the box over a data channel, so changing it is a gateway restart.
//
// THE SPLIT IS NOT ARBITRARY AND IT IS NOT SECURITY.  Nothing here survives a first-load MITM of
// the nsite gateway and nothing is designed as though it might; the user ruled that out of scope.
// The line is drawn at "can this byte arrive over the connection it is used to set up", and that
// question has exactly one answer per feature.
//
// ===================================================================================================
// WHY THE DESKTOP IS VISIBLE BEFORE THE PAYLOAD ARRIVES
// ===================================================================================================
//
// In VIDEO_PRIMARY mode the desktop image is VP8/RTP into a <video> element.  Decoding and painting
// it is the browser's job end to end: `vidEl.srcObject = stream` and pixels appear.  noVNC is NOT in
// that path — its canvas is kept at opacity:0 and exists only so the trackpad can map touches into
// framebuffer coordinates, and so the RFB handshake can tell us the desktop's name.
//
// The monolith nonetheless could not show a frame without noVNC, for one incidental reason: it
// positioned the video by copying the CANVAS's bounding rect, so with no canvas the video stayed at
// the 1x1 box it is initialised with.  That is a layout convenience, not a dependency.
//
// So the shell owns the video's geometry itself, from `videoWidth`/`videoHeight`, which arrive with
// the first frame and are the only inputs the job actually needs.  The payload takes geometry over
// when it lands (it has to — it adds pan and zoom, which the shell knows nothing about) by calling
// `api.video.setGeometryOwner`.  Until then the picture is letterboxed to the viewport, which is
// exactly what an untransformed noVNC canvas with scaleViewport would have produced anyway.
//
// The consequence worth having: TIME-TO-FIRST-PIXEL NO LONGER WAITS FOR 190 KB OF noVNC.  Input
// lights up a moment later, when the payload lands.
//
// ===================================================================================================
// THE VERSION CONTRACT  (the part that decides whether the shell really stabilises)
// ===================================================================================================
//
// The shell is supposed to stop changing, so it must tolerate payloads NEWER than itself.  The
// interface is one object, `api`, passed to the payload's exported `init(api)`.
//
//   * SHELL_API is an integer that increments whenever a member is ADDED.
//   * The payload exports `needs` — the lowest SHELL_API it can run against.
//   * The shell runs the payload iff `needs <= SHELL_API`.
//
// THE RULE THAT MAKES THAT SAFE IS THAT `api` IS APPEND-ONLY.  A member, once shipped, keeps its
// name, its shape and its meaning forever.  Adding is free and needs no publish, because an old
// payload simply does not reach for the new member.  REMOVING or REDEFINING one is the only change
// that forces a new shell onto nsite — which is the honest statement of what "the shell stopped
// changing" costs, and it is checkable: it is a diff of this object.
//
// A payload that needs more than we are gets REFUSED rather than run half-working: it is reported on
// screen, with the two numbers, and the desktop stays visible in view-only mode.  Running it and
// hoping would produce an undebuggable page at the far end of a link nobody can attach a console to.
//
// ===================================================================================================
// FALLBACK
// ===================================================================================================
//
// If the payload never arrives the shell is ALL THE USER HAS, so it may not sit on a spinner.  It
// says what happened, in words, and offers Retry.  The desktop stays visible throughout if video is
// flowing — view-only is a much better failure than a blank page, and it is the failure this design
// makes possible.

import { generateSecretKey, getPublicKey, finalizeEvent, getEventHash } from 'https://esm.sh/nostr-tools@2.15.0/pure';
import { SimplePool } from 'https://esm.sh/nostr-tools@2.15.0/pool';
import { getConversationKey, encrypt as nip44Encrypt } from 'https://esm.sh/nostr-tools@2.15.0/nip44';
import { wrapEvent, unwrapEvent } from 'https://esm.sh/nostr-tools@2.15.0/nip59';
import { decode } from 'https://esm.sh/nostr-tools@2.15.0/nip19';

// The shell's half of the version contract.  APPEND-ONLY — see the header.
const SHELL_API = 1;

// Ask glass for 16-bit RGB555 (see novnc/core/rfb.js): ~1/3 fewer bytes per pixel through ZRLE.
// Read by the payload's RFB, so it has to be set before the payload runs — which is here.
window.__glassFbDepth = 16;
const log = (...a) => console.log('[glass-shell]', ...a);

// A STUN server so the browser also gathers a server-reflexive (public) candidate for NAT
// traversal; host candidates still cover the LAN case.  Non-trickle: we gather fully before
// signaling, since our answer is one-shot.
const pc = new RTCPeerConnection({ iceServers: [
  { urls: 'stun:stun.cloudflare.com:3478' },   // reachable through WARP (WARP is Cloudflare)
  { urls: 'stun:stun.l.google.com:19302' },
  // TURN relay for the symmetric-NAT / cellular case (coturn behind the frps).
  { urls: 'turn:turn.ynniv.com:3478', username: 'glass', credential: 'ro0DmshIO9HX7yTiKjWlBkvQalQNkAn' },
] });
pc.oniceconnectionstatechange = () => log('ice', pc.iceConnectionState);
pc.onconnectionstatechange = () => log('conn', pc.connectionState);

// ---- ALL FOUR CHANNELS ARE CREATED HERE, BEFORE THE OFFER ------------------------------------
// This is the one piece of ordering the split absolutely may not get wrong.  Signalling is
// ONE-SHOT and NON-TRICKLE and there is no renegotiation path anywhere in the system, so a channel
// that does not exist by the time `createOffer` runs can never exist at all.  The payload arrives
// long after that — so the payload cannot create its own channels, and the shell creates every
// channel any payload might want and hands them over.
//
// Only `rfb` affects the SDP (it is DCEP-negotiated, and it is what puts the m=application section
// there at all).  The other three are `negotiated: true` on fixed stream ids, which cost ZERO bytes
// to create — there is no handshake — so creating them for a payload that never comes is free.
const ch = pc.createDataChannel('rfb', { ordered: true });        // stream 0, DCEP — raw RFB
ch.binaryType = 'arraybuffer';
const ctrl = pc.createDataChannel('control', { ordered: true, negotiated: true, id: 100 });
const warpCh = pc.createDataChannel('warp', { ordered: true, negotiated: true, id: 102 });
// 104 and not 103: negotiated ids are the application's to choose, and the convention already in
// this system is "even, near the one that already works" (control 100, warp 102).  Even ids also
// stay clear of the DCEP-allocated ids the browser hands out from the bottom.
const payloadCh = pc.createDataChannel('payload', { ordered: true, negotiated: true, id: 104 });
payloadCh.binaryType = 'arraybuffer';

// ---- the connecting overlay: the connect sequence as a checklist -------------------------------
const connEl = document.getElementById('connstatus');
const connMsg = connEl.querySelector('.msg');
const stepEls = [...connEl.querySelectorAll('.steps li')];
if (stepEls[0]) stepEls[0].classList.add('now');   // the first step is live from page load
let curStep = 0;
// Advance to step I, never backwards: everything before it reads as done, it reads as current,
// everything after stays dimmed — so the list answers "what is left?" as well as "where are we?".
const setStep = (i, label) => {
  if (i > curStep) curStep = i;
  stepEls.forEach((el, k) => {
    el.classList.toggle('done', k < curStep);
    el.classList.toggle('now', k === curStep);
  });
  if (label && stepEls[curStep]) stepEls[curStep].querySelector('.lbl').textContent = label;
};
// The second line on a completed step: the one fact worth keeping from that phase.  Setting it also
// marks the step done, because knowing the answer IS the completion.
const setDetail = (i, text) => {
  const el = stepEls[i]; if (!el) return;
  el.querySelector('.det').textContent = text;
  if (i >= curStep) setStep(i + 1);
  el.classList.add('done');
};
const setConnRaw = m => { connMsg.textContent = m; };
// Stop the sequence where it stands.  The step we never finished keeps its label but stops spinning
// and turns red, so the list itself says WHICH stage failed.
const failConn = () => {
  const el = stepEls[curStep];
  stepEls.forEach(e => e.classList.remove('now'));
  if (el) el.classList.add('fail');
};
let connHidden = false;
const hideConn = () => { if (connHidden) return; connHidden = true; connEl.style.opacity = '0';
  setTimeout(() => { connEl.style.display = 'none'; setLink(linkState); }, 440); };

// ---- diagnostics ------------------------------------------------------------------------------
// Mobile has no console, so the whole connection lifecycle goes on the page.  The payload appends
// to the SAME log through api.ui.diag, so a report copied off a phone is one timeline rather than
// two — which matters most in exactly the case this split introduces, where the interesting
// question is what the shell was doing when the payload did or did not arrive.
const hud = document.getElementById('hud');
const diagEl = document.getElementById('diag');
diagEl.style.top = '90px';
const diagLines = [], tStart = performance.now();
const stamp = () => ((performance.now() - tStart) / 1000).toFixed(1).padStart(5, ' ');
function diag(msg) {
  const line = `${stamp()} ${msg}`;
  diagLines.push(line); if (diagLines.length > 60) diagLines.shift();
  diagEl.textContent = diagLines.slice(-20).join('\n');
  console.log('[diag]', line);
}
window.addEventListener('error', e => diag('JS-ERROR ' + (e.message || e.error)));
window.addEventListener('unhandledrejection', e => diag('REJECT ' + ((e.reason && e.reason.message) || e.reason)));

// ---- the link-status pill ----------------------------------------------------------------------
const linkEl = document.getElementById('linkstat');
const linkTxt = linkEl.querySelector('.txt');
const linkBtn = linkEl.querySelector('button');
const LINK_TEXT = {
  live: 'Connected',
  checking: 'Checking the connection…',
  stalled: 'No data from your desktop',
  dropped: 'Connection lost',
  reconnecting: 'Reconnecting…',
};
let linkState = 'live', linkSaidLive = false, linkArmed = false;
// ONE function writes the status and it writes BOTH surfaces — the pill and, while the full-screen
// overlay is up, the overlay's message line.  The two cannot drift into different vocabularies for
// the same condition because there is only one place either of them is set.
function setLink(state, text) {
  const label = text || LINK_TEXT[state] || state;
  if (state !== linkState) diag('link ' + state + (text ? ' — ' + text : ''));
  linkState = state;
  linkEl.dataset.state = state;
  if (linkTxt.textContent !== label) linkTxt.textContent = label;
  linkEl.hidden = !connHidden;
  if (!connHidden && state !== 'live') setConnRaw(label);
}

// ---- the video element: THE DESKTOP, before anything else has loaded ---------------------------
const vidEl = document.createElement('video');
vidEl.autoplay = true; vidEl.playsInline = true; vidEl.muted = true;
vidEl.style.cssText = 'position:fixed;right:14px;bottom:140px;z-index:22;width:128px;height:128px;' +
  'border-radius:10px;background:#000;object-fit:contain;display:none;pointer-events:none;box-shadow:0 0 0 1px rgba(255,255,255,.25)';
document.body.appendChild(vidEl);
// PRESENTED frames, which are not decoded frames.  getStats' framesDecoded says the decoder
// consumed the RTP; requestVideoFrameCallback fires when a frame has actually been handed to the
// compositor.  Blank WITH this climbing is a LAYOUT fault; blank WITH it stopped is a PLAYBACK
// fault.  Same symptom, opposite fixes, so both are counted rather than guessed.
let vidPresented = 0, vidPresentAt = 0;
if (vidEl.requestVideoFrameCallback) {
  const onPresent = () => { vidPresented++; vidPresentAt = performance.now();
                            markAlive('video');
                            vidEl.requestVideoFrameCallback(onPresent); };
  vidEl.requestVideoFrameCallback(onPresent);
}
// A REJECTED play() IS A MESSAGE.  autoplay+muted+playsInline satisfies every current policy, but a
// track swap, a lost media session or an iOS resume can still leave the element paused — and a
// paused <video> keeps showing its last frame, which is indistinguishable from a dead link.
let playFails = 0, lastPlayTry = 0;
const tryPlay = (why, force) => {
  if (!vidEl.play) return;
  const t = performance.now();
  if (!force && t - lastPlayTry < 400) return;
  lastPlayTry = t;
  const p = vidEl.play();
  if (p && p.catch) p.catch(err => { playFails++;
    diag(`play() rejected (${why}): ${(err && err.name) || err}`); });
};
for (const ev of ['loadedmetadata', 'loadeddata', 'canplay', 'pause', 'stalled', 'suspend'])
  vidEl.addEventListener(ev, () => { if (vidEl.paused) tryPlay(ev); });
// A TOUCH IS A USER GESTURE and a user gesture is the one thing an autoplay policy cannot refuse.
// CAPTURE on window, because the payload's trackpad handlers are capture+stopPropagation on
// #screen; PASSIVE, so this can never preventDefault and cannot change what that layer does.
window.addEventListener('touchstart', () => { if (vidEl.paused) tryPlay('touch', true); },
                        { capture: true, passive: true });

const videoPrimary = new URLSearchParams(location.search).get('video') !== '0';

// ---- video geometry, and who owns it -----------------------------------------------------------
// THE SHELL'S OWNER IS DELIBERATELY THE SIMPLEST THING THAT IS CORRECT: letterbox the frame into
// the viewport from its own intrinsic size.  It needs no canvas, so it works from the first
// presented frame — which is the whole reason the desktop is visible before the payload lands.
//
// The payload REPLACES this (it must: it adds pan and zoom, and it glues the picture to noVNC's
// canvas so touches land where they look like they land).  One slot, one owner, so the two can
// never both be writing the element's box — which is the failure mode the monolith's comments
// spend forty lines on.
let geometryOwner = null;
const shellGeometry = () => {
  if (!videoPrimary) return;
  const vw = vidEl.videoWidth, vh = vidEl.videoHeight;
  if (!vw || !vh) return;                        // no frame yet: nothing to letterbox
  const W = innerWidth, H = innerHeight;
  const s = Math.min(W / vw, H / vh);
  const w = vw * s, h = vh * s;
  vidEl.style.transform = '';
  vidEl.style.left = Math.round((W - w) / 2) + 'px';
  vidEl.style.top = Math.round((H - h) / 2) + 'px';
  vidEl.style.width = Math.round(w) + 'px';
  vidEl.style.height = Math.round(h) + 'px';
};
let syncPending = false;
const syncVideoNow = () => { syncPending = false; (geometryOwner || shellGeometry)(); };
const syncVideo = () => { if (!syncPending) { syncPending = true; requestAnimationFrame(syncVideoNow); } };
window.__syncVideo = syncVideo;
window.addEventListener('resize', syncVideo);
window.addEventListener('orientationchange', syncVideo);
// iOS Safari will occasionally keep a video layer whose box was set imperatively out of the next
// composite; a property change on the element forces it back in.  Opacity is the one to poke
// because it is orthogonal to both the transform (zoom) and the box.
const nudgeLayer = () => {
  vidEl.style.opacity = '0.999'; void vidEl.offsetHeight;
  requestAnimationFrame(() => { vidEl.style.opacity = ''; });
};

pc.addEventListener('track', (e) => {
  const stream = e.streams[0] || new MediaStream([e.track]);
  if (e.track.kind === 'video') {
    diag('VIDEO track from box (VP8)');
    vidEl.srcObject = stream;
    if (videoPrimary) {
      // pointer-events:none is essential — the payload's trackpad listens on #screen BENEATH this
      // element, so without it the video swallows every touch that lands on the desktop.
      vidEl.style.cssText = 'position:fixed;z-index:5;background:#000;object-fit:fill;' +
        'pointer-events:none;left:0;top:0;width:1px;height:1px';
      window.__vidEl = vidEl; window.__videoPrimary = true;
      syncVideo();
      // Dismiss on a REAL first frame.  requestVideoFrameCallback fires per PRESENTED frame, so it
      // is the only honest signal here — 'playing' and 'unmute' both fire on negotiation, before
      // any pixels exist.  In video-primary mode there are no framebuffer updates to dismiss on.
      const firstFrame = () => { syncVideo(); hideConn();
        diag(`first video frame — ${vidEl.videoWidth}x${vidEl.videoHeight} rs${vidEl.readyState}` +
             `${vidEl.paused ? ' PAUSED' : ''}`); };
      if (vidEl.requestVideoFrameCallback) vidEl.requestVideoFrameCallback(firstFrame);
      else vidEl.addEventListener('loadeddata', firstFrame, { once: true });
      // A timed failsafe must NOT hide the overlay: a blank screen with no explanation is worse
      // than a spinner.  If nothing has arrived by now, say what state we are actually in.
      setTimeout(() => {
        if (connHidden) return;
        if (pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed') {
          setConnRaw('Connected — waiting for the first frame…');
        } else {
          setConnRaw('Could not reach your desktop');
          connMsg.insertAdjacentHTML('afterend',
            '<div style="max-width:22em;font-size:13px;line-height:1.5;opacity:.75;margin-top:2px">' +
            'The connection did not establish (ICE ' + pc.iceConnectionState + ').<br>' +
            'Tap ≡ for the log, or reload to try again.</div>');
          failConn();
        }
      }, 12000);
      diag('video is the primary view');
    } else {
      vidEl.style.display = '';
    }
    tryPlay('track', true);
    e.track.addEventListener('unmute', () => { diag('video track unmuted (negotiated)'); if (videoPrimary) syncVideo(); });
    return;
  }
  diag('audio track from box (muted)');
  const au = document.createElement('audio'); au.autoplay = true; au.playsInline = true;
  au.muted = true; au.srcObject = stream;                 // muted: does not take the audio session
  document.body.appendChild(au);
  window.__boxAudio = au; window.__boxStream = stream;
  const p = au.play && au.play(); if (p && p.catch) p.catch(() => {});
});

// ---- liveness --------------------------------------------------------------------------------
// The pill is the shell's, because the pill is what says "the payload never came" as well as what
// says "the link died" — and a status surface that can only be drawn by code which may not have
// arrived is not a status surface.  The parts that need getStats (the ICE-counter signal, the
// repaint watchdog) are the PAYLOAD's, and they feed this through api.markAlive.
const LINK_PING_MS = 10000, LINK_URGE_MS = 2500, LINK_STALL_MS = 14000, LINK_DROP_MS = 30000;
const LINK_RESUME_GRACE_MS = 9000, LINK_BG_GAP_MS = 10000;
let lastAlive = performance.now();
let lastAliveWall = Date.now();
let lastPingAt = 0, probeUntil = 0;

function markAlive(why) {
  lastAlive = performance.now(); lastAliveWall = Date.now(); probeUntil = 0;
  // ...but NOT once a reload is already scheduled.  A failing link can still land the odd consent
  // response, and without this guard the pill flapped between "Reconnecting…" and "Connected" once
  // a second right up until the reload.
  if (linkState !== 'live' && !reconnecting) { diag('link alive again (' + why + ')'); setLink('live'); }
  if (why === 'control' && !linkSaidLive) { linkSaidLive = true; clearReconnAttempts(); }
}
ctrl.addEventListener('message', () => markAlive('control'));

// ---- THE RFB GREETING ARRIVES BEFORE noVNC EXISTS, AND USED TO BE LOST ------------------------
// This is the one thing the split genuinely breaks, and it is invisible until you look for it.
//
// The `rfb` channel is opened by the shell, at the top of the file, because it has to be in the
// offer.  The box's session bridges it to glass the moment it opens, and glass — like any RFB
// server — sends its protocol-version greeting immediately.  But noVNC is in the PAYLOAD, and does
// not exist for another second or several.  Nothing is listening, so the greeting goes on the floor
// and the handshake deadlocks: the box is waiting for a version reply to a greeting the client
// never saw, and the client is waiting for a greeting that already came and went.
//
// The symptom is a session that looks entirely healthy — video playing, control channel answering,
// buttons drawn — with no desktop name, no keyboard and no mouse.  Which is exactly what the
// end-to-end test found.
//
// So the shell holds the early bytes and the payload replays them into noVNC once it has one.  The
// buffer is bounded: an RFB handshake is a few hundred bytes, and if something is pouring data at
// us before the payload has landed then keeping it is not going to help.
const rfbEarly = [];
let rfbHandedOver = false, rfbDropped = 0;
ch.addEventListener('message', e => {
  markAlive('rfb');
  if (rfbHandedOver) return;
  if (rfbEarly.length < 64) rfbEarly.push(e.data); else rfbDropped++;
});

function checkLink() {
  const now = performance.now();
  // NOT ARMED UNTIL THERE HAS BEEN A CONNECTION.  Getting one takes 10-20 s of relay round trips
  // during which nothing has arrived and nothing is wrong; judging that as a stall would overwrite
  // the connect sequence's own message every time.
  if (!linkArmed) {
    const ice = pc.iceConnectionState;
    if (pc.connectionState !== 'connected' && ice !== 'connected' && ice !== 'completed') return;
    linkArmed = true; lastAlive = now; lastAliveWall = Date.now();
    diag('link watch armed');
  }
  if (reconnecting) return;
  const visible = document.visibilityState === 'visible';
  const quiet = now - lastAlive;
  if (visible && ctrl.readyState === 'open' &&
      now - lastPingAt >= ((quiet > 6000 || probeUntil) ? LINK_URGE_MS : LINK_PING_MS)) {
    lastPingAt = now;
    try { ctrl.send('{"get":1}'); } catch (_) {}
  }
  // Ask to reconnect ON THE TRANSITION only: scheduleReconnect refuses when there is no usable
  // credential, and that refusal does not latch.
  const drop = (label, why) => {
    const first = linkState !== 'dropped';
    setLink('dropped', label);
    if (first) scheduleReconnect(why);
  };
  const st = pc.connectionState, ist = pc.iceConnectionState;
  if (st === 'failed' || st === 'closed' || ist === 'failed' || ist === 'closed') {
    drop('Connection lost', 'pc ' + st + '/' + ist); return;
  }
  if (probeUntil) {
    if (now < probeUntil) { setLink('checking'); return; }
    probeUntil = 0;
    drop('Connection lost while you were away', 'no proof of life on resume'); return;
  }
  if (quiet >= LINK_DROP_MS) { drop('Connection lost', 'silent ' + Math.round(quiet / 1000) + 's'); return; }
  if (ist === 'disconnected' && quiet < LINK_STALL_MS) { setLink('stalled', 'Connection interrupted'); return; }
  if (quiet >= LINK_STALL_MS) { setLink('stalled', 'No data for ' + Math.round(quiet / 1000) + 's'); return; }
  setLink('live');
}

// RETURNING TO THE FOREGROUND.  An iOS tab that has been away has had its timers throttled or
// stopped, so none of the ages above mean anything at the moment we wake: they say we stopped
// looking, not that anything stopped arriving.  Throw them away, ask for proof NOW, judge on the
// answer within a bounded window.
function onResume() {
  const gap = Date.now() - lastAliveWall;
  if (ctrl.readyState === 'open') { lastPingAt = performance.now(); try { ctrl.send('{"get":1}'); } catch (_) {} }
  if (!linkArmed || reconnecting) { pollHook(); return; }
  if (gap < LINK_BG_GAP_MS) { pollHook(); return; }
  lastAlive = performance.now(); lastAliveWall = Date.now();
  probeUntil = performance.now() + LINK_RESUME_GRACE_MS;
  if (api.onResumeHooks) for (const h of api.onResumeHooks) { try { h(); } catch (_) {} }
  setLink('checking');
  diag('resumed after ' + (gap / 1000).toFixed(0) + 's away — probing the link');
  pollHook();
}
// The payload installs the getStats poll here; until then there is nothing to poll and the
// control-channel ping above is the whole of the liveness check, which is enough on its own.
let pollHook = () => {};

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible') return;
  const dead = pc.connectionState === 'failed' || pc.connectionState === 'closed' ||
               pc.iceConnectionState === 'failed' || pc.iceConnectionState === 'closed';
  if (dead) {
    diag('returned to foreground — session is ' + pc.connectionState + '/' + pc.iceConnectionState);
    scheduleReconnect('dead on resume');
    return;
  }
  tryPlay('resume', true);
  if (videoPrimary) syncVideo();
  if (ctrl.readyState === 'open') {
    ctrl.send(JSON.stringify({ request: 'keyframe' }));
    diag('returned to foreground — play() + keyframe requested');
  }
  onResume();
});
// iOS Safari can restore a page from the back/forward cache without a visibilitychange.
window.addEventListener('pageshow', e => {
  if (!e.persisted) return;
  diag('restored from bfcache — probing the link');
  onResume();
});
setInterval(() => { pollHook(); checkLink(); }, 1000);

pc.addEventListener('iceconnectionstatechange', () => {
  diag('ice ' + pc.iceConnectionState);
  if (pc.iceConnectionState === 'failed') {
    if (!connHidden) { setConnRaw('Could not reach your desktop'); failConn(); }
    scheduleReconnect('ice failed');
  }
});
pc.addEventListener('connectionstatechange', () => diag('conn ' + pc.connectionState));
pc.addEventListener('icegatheringstatechange', () => diag('gather ' + pc.iceGatheringState));
pc.addEventListener('icecandidateerror', e => diag(`cand-err ${e.errorCode} ${e.url || ''} ${(e.errorText || '').slice(0,40)}`));
ch.addEventListener('open', () => { diag('datachannel OPEN'); setStep(3); });
ch.addEventListener('close', () => diag('datachannel CLOSE'));
ctrl.addEventListener('open', () => { diag('control channel OPEN'); ctrl.send('{"get":1}'); });

// ---- the box's identity, and which box this is -------------------------------------------------
const params = new URLSearchParams(location.search);
const hraw = location.hash.replace(/^#/, '');
const hp = new URLSearchParams(hraw.includes('=') ? hraw : ('box=' + hraw));
const BOX_KEY = 'glass-box';
const storeBox = b => { try { localStorage.setItem(BOX_KEY, b); } catch (_) {} };
const loadBox = () => {
  try {
    const b = localStorage.getItem(BOX_KEY);
    if (b) return b;
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i) || '';
      const m = k.match(/^glass-(?:device|code):(.+)$/);
      if (m && m[1] !== 'default') return m[1];
    }
  } catch (_) {}
  return '';
};
const urlBox = hp.get('box') || params.get('box') || '';
if (urlBox) storeBox(urlBox);
// ROTATION SITE: derived from the gateway's NOSTR_SEC.  Rotate that and this is stale, and a fresh
// browser silently dials a box that no longer exists.  Rotated 2026-08-12.
const boxArg = urlBox || loadBox() ||
  '804f867fba14b70a9a84542a982a79d3775356a3d105e03af4bf4fd6ed7cfb55';

// ---- LEARNT-NAME: which box is this? -----------------------------------------------------------
// The question worth answering while someone watches the progress list is "is this the right
// desktop", and it has to be answered BEFORE the first packet — which rules out the box telling us,
// because glass sends its name in the RFB handshake, three steps too late.  So the box tells us
// once and we remember it, against this box's pubkey.
//
// IT IS SHELL-RESIDENT BY DEFINITION: it renders before the first byte.  Only `learnWho` — which
// runs on the RFB handshake — belongs to the payload's half of the session, so it is on `api`.
const nameKey = 'glass-name:' + boxArg;
const whoNm = document.querySelector('#connstatus .who .nm');
const whoId = document.querySelector('#connstatus .who .id');
const showWho = () => {
  let known = '';
  try { known = localStorage.getItem(nameKey) || ''; } catch (_) {}
  whoNm.textContent = known || 'this desktop — not seen before';
  whoNm.classList.toggle('unknown', !known);
  whoId.textContent = boxArg.slice(0, 12) + '…';
};
const learnWho = name => {
  const n = (name || '').trim();
  if (!n) return;
  let had = '';
  try { had = localStorage.getItem(nameKey) || ''; } catch (_) {}
  if (n === had) return;
  try { localStorage.setItem(nameKey, n); } catch (_) {}
  showWho();
  diag('desktop name: ' + n + (had ? ' (was "' + had + '")' : ''));
};
showWho();

// ---- credentials -------------------------------------------------------------------------------
// The token is nonce.exp.mac with exp a unix time, so the browser can judge its own credential
// without asking anyone: an expired link is reported as expired instead of surfacing later as a
// mysterious connection failure.
const codeExp = c => { const p = String(c || '').split('.'); const e = parseInt(p[1], 10);
                       return (p.length === 3 && isFinite(e)) ? e * 1000 : 0; };
const codeAlive = (c, marginMs = 0) => { const e = codeExp(c); return e > 0 && (e - marginMs) > Date.now(); };
const CODE_KEY = 'glass-code:' + boxArg;
const storeCode = c => { try { if (codeAlive(c)) localStorage.setItem(CODE_KEY, c); } catch (_) {} };
const loadCode = () => { try { const c = localStorage.getItem(CODE_KEY); return codeAlive(c) ? c : ''; } catch (_) { return ''; } };
const urlCode = hp.get('code') || params.get('code') || '';
if (urlCode && codeAlive(urlCode)) storeCode(urlCode);
let code = (codeAlive(urlCode) ? urlCode : '') || loadCode() || urlCode;
window.__expiredCode = Boolean(code) && !codeAlive(code);
const boxPub = boxArg.startsWith('npub') ? decode(boxArg).data : boxArg;
const relays = (params.get('relays') ||
  'wss://relay.damus.io,wss://nos.lol,wss://relay.primal.net').split(',');
const nowSec = () => Math.floor(Date.now() / 1000);
const pastTs = () => nowSec() - Math.floor(Math.random() * 172800);

const hex = u8 => [...u8].map(b => b.toString(16).padStart(2, '0')).join('');
const unhex = h => new Uint8Array(h.match(/../g).map(x => parseInt(x, 16)));
const DEV_KEY = 'glass-device:' + boxArg;
const hasDevice = () => { try { const h = localStorage.getItem(DEV_KEY); return !!h && h.length === 64; }
                          catch (_) { return false; } };
const deviceSecret = () => {
  try {
    let h = localStorage.getItem(DEV_KEY);
    if (!h || h.length !== 64) { h = hex(generateSecretKey()); localStorage.setItem(DEV_KEY, h); }
    return unhex(h);
  } catch (_) { return generateSecretKey(); }
};

// ---- signing in: A TAP, AND NEVER OTHERWISE ----------------------------------------------------
// A NIP-07 signer is not a fallback and must not be reached for as one.  Touching window.nostr pops
// the signer's approval sheet, and doing that on a cold load — which is what "try the signer when
// there is no code and no device" amounts to — is a prompt nobody asked for, on a page that has not
// yet established there is anything wrong.  So the signer is offered as a BUTTON on the failure
// screen and nowhere else, and THIS FLAG is the entire record of "somebody tapped it".
//
// sessionStorage because the retry is a RELOAD (see SCHEDULERECONNECT for why every retry in this
// file is): it has to survive the navigation and it has to die with the tab.  CONSUMED on read, so
// one tap is one attempt — a flag that stuck would turn a single tap into a signer prompt on every
// subsequent load of that tab, which is the thing it exists to prevent.
const SIGNIN_KEY = 'glass-signin:' + boxArg;
const askSignIn = () => { try { sessionStorage.setItem(SIGNIN_KEY, '1'); } catch (_) {} };
const takeSignIn = () => {
  let w = false;
  try { w = sessionStorage.getItem(SIGNIN_KEY) === '1'; sessionStorage.removeItem(SIGNIN_KEY); }
  catch (_) {}
  return w;
};
// Reading the PROPERTY is free — an extension injects an object, and no sheet appears until one of
// its methods is called.  So this is the whole of what the failure screen is allowed to ask.
const haveSigner = () => { try { return Boolean(window.nostr); } catch (_) { return false; } };

// ---- reconnect ---------------------------------------------------------------------------------
const reconnKey = () => 'glass-reconn:' + boxArg;
const reconnAttempts = () => { try { return +(sessionStorage.getItem(reconnKey()) || 0) || 0; }
                               catch (_) { return 0; } };
const setReconnAttempts = n => { try { sessionStorage.setItem(reconnKey(), String(n)); } catch (_) {} };
const clearReconnAttempts = () => { try { sessionStorage.removeItem(reconnKey()); } catch (_) {} };
let reconnecting = false;
function scheduleReconnect(why) {
  if (reconnecting) return;
  if (!(codeAlive(loadCode()) || hasDevice())) {
    diag('not reconnecting: no usable credential (' + why + ')');
    if (window.__showNoCredential) window.__showNoCredential();
    return;
  }
  const n = reconnAttempts();
  if (n >= 6) {
    setLink('dropped', 'Could not reconnect — tap Reconnect to retry');
    setConnRaw('Could not reconnect');
    failConn();
    diag('giving up after ' + n + ' reconnect attempts (' + why + ')');
    return;
  }
  reconnecting = true;
  setReconnAttempts(n + 1);
  const delay = Math.min(30000, 1000 * Math.pow(2, n));
  const label = 'Reconnecting…' + (n ? ' (attempt ' + (n + 1) + ')' : '');
  connEl.style.display = ''; connEl.style.opacity = '';
  connHidden = false;
  setLink('reconnecting', label);
  diag('reconnect in ' + delay + 'ms — ' + why + ' (attempt ' + (n + 1) + ')');
  // A RELOAD, so there is nothing to leak: every peer connection, interval, listener and decoder in
  // this page dies with the document.
  setTimeout(() => location.reload(), delay);
}
linkBtn.addEventListener('click', e => {
  e.stopPropagation();
  diag('reconnect requested by hand');
  clearReconnAttempts();
  reconnecting = false;
  scheduleReconnect('manual');
});

// ===================================================================================================
// THE API HANDED TO THE PAYLOAD.  APPEND-ONLY.  See the version contract in the header.
// ===================================================================================================
const api = {
  v: SHELL_API,
  pc,
  chans: { rfb: ch, ctrl, warp: warpCh, payload: payloadCh },
  // Everything that arrived on the RFB channel before there was anything to receive it — see the
  // note at RFB-EARLY.  Called once, by the payload, immediately after it constructs noVNC; it
  // stops the buffering and hands over what was held.  Calling it twice returns nothing, which is
  // the right answer to "replay it again".
  takeEarlyRfb() {
    if (rfbHandedOver) return [];
    rfbHandedOver = true;
    const held = rfbEarly.splice(0);
    if (held.length) diag(`replaying ${held.length} early RFB message(s)` +
                          (rfbDropped ? ` (${rfbDropped} dropped)` : ''));
    return held;
  },
  video: {
    el: vidEl,
    primary: videoPrimary,
    // ONE owner at a time.  Returns the owner it replaced, so a payload could in principle chain,
    // and so "who is drawing this box" is always a single answer.
    setGeometryOwner(fn) { const prev = geometryOwner; geometryOwner = fn || null; syncVideo(); return prev; },
    sync: syncVideo,
    nudge: nudgeLayer,
    play: tryPlay,
    presented: () => vidPresented,
    presentedAt: () => vidPresentAt,
    playFails: () => playFails,
  },
  ui: { diag, setLink, setStep, setDetail, setConnRaw, failConn, hideConn,
        connEl, connMsg, hud, diagEl, linkEl,
        isConnHidden: () => connHidden, linkState: () => linkState },
  markAlive,
  scheduleReconnect,
  learnWho,
  // the payload's getStats poll; the shell calls it once a second and on resume
  setPoll(fn) { pollHook = fn || (() => {}); },
  onResumeHooks: [],
  box: boxArg,
  code: () => code,
  params, hp,
  stamp: () => performance.now() - tStart,
};
window.__glass = api;

// ===================================================================================================
// THE PAYLOAD LOADER
// ===================================================================================================
//
// TRANSPORT is stream 104, negotiated, ordered.  Ordered matters: the chunks are reassembled by
// ARRIVAL ORDER and carry no sequence numbers, which is only safe because SCTP ordered delivery on
// one stream is exactly that guarantee.
//
// EXECUTION is a blob: URL and a dynamic import().  That is not a preference, it is the only route
// the nsite origin permits, and it was verified against the live response headers rather than
// assumed:
//
//     content-security-policy: default-src 'self'; script-src 'self' 'unsafe-inline' blob: https:; …
//
// `blob:` is in script-src, and there is NO 'unsafe-eval' — so `new Function` and `eval` are
// refused, and the obvious implementation of "run some JS I was handed" would have shipped a client
// that dies on the origin it is published to.  A blob URL is a real module with a real specifier,
// so the payload can also carry static imports of its own if it ever needs to.
//
// CACHING is keyed by the sha256 of the bytes the box sent, which is also how the box decides
// whether to send anything at all: we say what we have, and a box serving the same build answers
// {"t":"same"} and puts nothing on the wire.  It is an optimisation and it is written like one —
// every localStorage access is wrapped, a miss just means a transfer, and a hash mismatch throws
// the cache away rather than trusting it.

const PAYLOAD_CACHE_SHA = 'glass-payload-sha', PAYLOAD_CACHE_SRC = 'glass-payload-src';
const cacheGet = () => { try { const s = localStorage.getItem(PAYLOAD_CACHE_SHA),
                                     j = localStorage.getItem(PAYLOAD_CACHE_SRC);
                               return (s && j) ? { sha: s, src: j } : null; } catch (_) { return null; } };
const cachePut = (sha, src) => { try { localStorage.setItem(PAYLOAD_CACHE_SHA, sha);
                                       localStorage.setItem(PAYLOAD_CACHE_SRC, src); } catch (_) {} };
const cacheDrop = () => { try { localStorage.removeItem(PAYLOAD_CACHE_SHA);
                                localStorage.removeItem(PAYLOAD_CACHE_SRC); } catch (_) {} };

const sha256hex = async (bytes) => {
  const d = await crypto.subtle.digest('SHA-256', bytes);
  return hex(new Uint8Array(d));
};

let payloadState = 'idle';         // idle | asking | receiving | running | failed
let payloadRan = false;
let rxChunks = [], rxLen = 0, rxWant = null;

// The fallback surface.  A payload that never arrives leaves the shell as the whole client, so it
// has to SAY so — and offer the one thing that might help.  It deliberately does not hide the
// desktop: if video is flowing, view-only is a far better failure than a blank page, and saying
// "you can look but not touch" is only honest if you can still look.
const payloadFail = (why, detail) => {
  payloadState = 'failed';
  diag('payload: ' + why + (detail ? ' — ' + detail : ''));
  let bar = document.getElementById('payloadfail');
  if (!bar) {
    bar = document.createElement('div');
    bar.id = 'payloadfail';
    document.body.appendChild(bar);
  }
  bar.innerHTML = '';
  const txt = document.createElement('span');
  txt.textContent = (vidPresented > 0 ? 'View only — ' : '') + why;
  const btn = document.createElement('button');
  btn.type = 'button'; btn.textContent = 'Retry';
  btn.addEventListener('click', () => { bar.remove(); askPayload('retry'); });
  bar.append(txt, btn);
  if (detail) { const d = document.createElement('small'); d.textContent = detail; bar.appendChild(d); }
};

// Run a payload source string.  Everything that can go wrong here is reported rather than thrown:
// this is the far end of a link with no console on it.
const runPayload = async (src, sha) => {
  if (payloadRan) return;
  let url = null;
  try {
    url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
    const mod = await import(url);
    const needs = (typeof mod.needs === 'number') ? mod.needs : 0;
    // THE VERSION CHECK.  Refuse rather than half-run — see the contract in the header.
    if (needs > SHELL_API) {
      payloadFail('This desktop needs a newer client',
                  `payload wants shell API ${needs}, this shell is ${SHELL_API} — reload from a fresh link`);
      return;
    }
    if (typeof mod.init !== 'function') {
      payloadFail('The desktop sent something this client cannot run', 'payload exports no init()');
      return;
    }
    payloadRan = true; payloadState = 'running';
    const t0 = performance.now();
    await mod.init(api);
    diag(`payload running (api ${needs}<=${SHELL_API}, init ${Math.round(performance.now() - t0)}ms)`);
    if (sha) cachePut(sha, src);
    const bar = document.getElementById('payloadfail'); if (bar) bar.remove();
  } catch (err) {
    // A cached payload that will not run is a cache to throw away, not a permanent state.
    cacheDrop();
    payloadFail('The desktop client failed to start', (err && (err.message || err.name)) || String(err));
  } finally {
    if (url) URL.revokeObjectURL(url);
  }
};

const askPayload = (why) => {
  if (payloadRan) return;
  // THE COLLAPSED-BACK BUILD.  mksplit.py can emit both halves into one page (standalone.html),
  // which is the escape hatch if the payload channel is ever the problem — publish that and you are
  // exactly where the single-page client was.  There, the payload has already run at load time, so
  // asking the box for a second copy would run a SECOND init() over the first: two trackpads on
  // #screen, two button rows, two RFB objects on one channel.
  if (window.__glassPayloadInline) {
    payloadRan = true; payloadState = 'running';
    diag('payload is inline in this build — not asking the box');
    return;
  }
  if (payloadCh.readyState !== 'open') { diag('payload: channel ' + payloadCh.readyState); return; }
  payloadState = 'asking'; rxChunks = []; rxLen = 0; rxWant = null;
  const cached = cacheGet();
  const msg = { t: 'hello', api: SHELL_API, have: cached ? cached.sha : '',
                enc: (typeof DecompressionStream === 'function') ? ['gzip', 'raw'] : ['raw'] };
  try { payloadCh.send(JSON.stringify(msg)); } catch (err) { diag('payload: send failed ' + err); return; }
  diag('payload: asked (' + why + ')' + (cached ? ' have ' + cached.sha.slice(0, 12) : ' no cache'));
  // A box without the payload channel — an older build, or one started without PAYLOAD_CHANNEL —
  // simply never answers.  Say so rather than leaving a spinner; that is the whole fallback rule.
  setTimeout(() => {
    if (payloadRan || payloadState === 'receiving') return;
    if (payloadState === 'failed') return;
    payloadFail('This desktop is not serving the client',
                'no answer on the payload channel — the box may be running an older gateway');
  }, 12000);
};

payloadCh.addEventListener('open', () => { diag('payload channel OPEN'); askPayload('open'); });
payloadCh.addEventListener('close', () => diag('payload channel CLOSE'));
payloadCh.addEventListener('message', async (e) => {
  // Binary is a chunk of the transfer; a string is control.  They share one ordered stream, so a
  // chunk can never overtake the "begin" that describes it.
  if (typeof e.data !== 'string') {
    if (!rxWant) return;                                  // a chunk with no transfer: ignore
    const u8 = new Uint8Array(e.data);
    rxChunks.push(u8); rxLen += u8.length;
    if (rxLen >= rxWant.len) await finishTransfer();
    return;
  }
  let m = null; try { m = JSON.parse(e.data); } catch (_) { return; }
  if (!m) return;
  markAlive('payload');
  if (m.t === 'same') {
    const cached = cacheGet();
    if (cached && cached.sha === m.sha) {
      diag('payload: cache hit ' + m.sha.slice(0, 12) + ' (' + cached.src.length + ' B, nothing sent)');
      await runPayload(cached.src, cached.sha);
    } else {
      cacheDrop();
      payloadFail('The desktop client is missing', 'box says cached but this client has no copy');
    }
    return;
  }
  if (m.t === 'none') { payloadFail('This desktop is not serving the client', m.why || ''); return; }
  if (m.t === 'begin') {
    payloadState = 'receiving';
    rxWant = { sha: m.sha, len: m.len, enc: m.enc || 'raw', at: performance.now() };
    rxChunks = []; rxLen = 0;
    diag(`payload: receiving ${m.len} B ${rxWant.enc} sha ${String(m.sha).slice(0, 12)}`);
    if (!connHidden) setConnRaw('Loading the desktop client…');
  }
});

async function finishTransfer() {
  const want = rxWant; rxWant = null;
  const bytes = new Uint8Array(rxLen);
  let off = 0; for (const c of rxChunks) { bytes.set(c, off); off += c.length; }
  rxChunks = [];
  const ms = Math.round(performance.now() - want.at);
  try {
    const got = await sha256hex(bytes);
    if (got !== want.sha) {
      payloadFail('The desktop client arrived damaged', `sha ${got.slice(0, 12)} != ${String(want.sha).slice(0, 12)}`);
      return;
    }
    let src;
    if (want.enc === 'gzip') {
      const ds = new DecompressionStream('gzip');
      const buf = await new Response(new Blob([bytes]).stream().pipeThrough(ds)).arrayBuffer();
      src = new TextDecoder().decode(buf);
    } else {
      src = new TextDecoder().decode(bytes);
    }
    diag(`payload: ${rxLen} B in ${ms}ms (${(rxLen / 1024 / (ms / 1000)).toFixed(0)} KB/s) -> ${src.length} B source`);
    await runPayload(src, want.sha);
  } catch (err) {
    payloadFail('The desktop client could not be unpacked', (err && (err.message || err.name)) || String(err));
  }
}

// ---- signalling --------------------------------------------------------------------------------
const stepFor = {
  'gathering ICE candidates…': 0,
  'sending one-time-code offer…': 1,
  'gift-wrapping offer to the box…': 1,
  'offer sent — waiting for the box': 1,
  'answer received — establishing WebRTC…': 2,
};
const setStatus = s => { hud.textContent = s; log(s);
  const i = stepFor[s]; if (i !== undefined) setStep(i); else setConnRaw(s); };

// NIP-07 gift wrap: sign the seal through the signer (secret never exposed), wrap under a throwaway
// key.  The code path instead uses nostr-tools wrapEvent with an ephemeral key we own.
async function giftWrap07(signer, myPub, message) {
  const rumor = { pubkey: myPub, created_at: nowSec(), kind: 14, tags: [['p', boxPub]], content: message };
  rumor.id = getEventHash(rumor);
  const sealContent = await signer.nip44.encrypt(boxPub, JSON.stringify(rumor));
  const seal = await signer.signEvent({ kind: 13, created_at: pastTs(), tags: [], content: sealContent });
  const esk = generateSecretKey();
  const wrapContent = nip44Encrypt(JSON.stringify(seal), getConversationKey(esk, boxPub));
  return finalizeEvent({ kind: 1059, created_at: pastTs(), tags: [['p', boxPub]], content: wrapContent }, esk);
}
async function giftUnwrap07(signer, wrap) {
  const seal = JSON.parse(await signer.nip44.decrypt(wrap.pubkey, wrap.content));
  if (seal.pubkey !== boxPub) return null;                            // authenticate the box
  const rumor = JSON.parse(await signer.nip44.decrypt(seal.pubkey, seal.content));
  return rumor.content;
}

async function requestFreshCode(pool, sk) {
  const mine = getPublicKey(sk);
  return new Promise(resolve => {
    let done = false, sub = null;
    const finish = v => { if (!done) { done = true; try { sub && sub.close(); } catch (_) {} resolve(v); } };
    try {
      sub = pool.subscribeMany(relays, [{ kinds: [1059], '#p': [mine] }], {
        onevent: ev => {
          try {
            const r = unwrapEvent(ev, sk);
            if (r && r.pubkey === boxPub) {
              const m = String(r.content).match(/code=([A-Za-z0-9.\-_]+)/);
              if (m && codeAlive(m[1])) finish(m[1]);
            }
          } catch (_) {}
        },
      });
      pool.publish(relays, wrapEvent({ kind: 14, content: 'link', tags: [['p', boxPub]] }, sk, boxPub));
    } catch (_) { finish(null); }
    setTimeout(() => finish(null), 15000);
  });
}

const noCredential = msg => { const e = new Error(msg); e.noCredential = true; return e; };

async function makeIdentity() {
  // THE SIGNER GOES FIRST ONLY WHEN IT WAS ASKED FOR, and TAKESIGNIN is what asking looks like —
  // set by the button on the failure screen, consumed here.  Ordered before the device branch on
  // purpose: the case this exists for is a device key that IS present and IS stale, so a signer
  // that only ran when there was no device key would never run at all.
  if (haveSigner() && takeSignIn()) {
    const signer = window.nostr;
    if (!signer.nip44)
      throw noCredential('Your Nostr signer cannot do NIP-44 encryption, which this box requires.');
    const pub = await signer.getPublicKey();
    // The stale credential is NOT sent along.  A dead code makes the box's admission answer
    // `expired' before it falls through to the allowlist, which is a denial reason in the log for
    // a login that in fact succeeded — and the offer is being signed as somebody the allowlist
    // knows, so the code was never going to be what admitted it.
    code = '';
    diag('signing in with the NIP-07 signer (asked for by hand)');
    return { pub, mode: 'nip07',
             wrapOffer: (payload) => giftWrap07(signer, pub, payload),
             unwrap: (ev) => giftUnwrap07(signer, ev) };
  }
  // hasDevice(), not deviceSecret(): the latter MINTS a key when none exists, and a brand-new key is
  // by definition not enrolled — we would sign a well-formed offer the box then refuses.
  if (code || hasDevice()) {
    const sk = deviceSecret();
    return {
      pub: getPublicKey(sk), mode: code ? 'code' : 'device',
      wrapOffer: (payload) => wrapEvent({ kind: 14, content: payload, tags: [['p', boxPub]] }, sk, boxPub),
      unwrap: (ev) => { try { const r = unwrapEvent(ev, sk); return (r && r.pubkey === boxPub) ? r.content : null; }
                        catch { return null; } },
    };
  }
  // …and with neither, this does NOT quietly reach for window.nostr.  It used to, and that was the
  // one place in the file that prompted a signer nobody had touched.  The failure screen offers it
  // instead, which costs one tap and buys the guarantee.
  throw noCredential('No login code and no enrolled device.');
}

(async () => {
  let id;
  // ---- the failure screen, and the one thing that can be done about it -------------------------
  // Three ways to arrive here and they are all the same fact — nothing this browser holds will get
  // it in.  A denied offer is answered with SILENCE by design (the box will not confirm to an
  // unknown sender that it is listening), so "refused" and "unreachable" are indistinguishable from
  // here and the screen must not claim to know which.  What it CAN do is offer the credential the
  // page has not used: a signer, if one is present, on a tap.
  let noCredEl = null, noCredBtn = null, signerLooks = 0;
  const showNoCredential = (why) => {
    const when = codeExp(code) ? new Date(codeExp(code)) : null;
    setConnRaw(why || (code ? 'This link has expired' : 'This terminal is not enrolled'));
    // Rendered fresh each time rather than appended: the watchdog and SCHEDULERECONNECT can both
    // reach this, and a card that grew a second copy of its own advice would read as a bug.
    if (noCredEl) noCredEl.remove();
    if (noCredBtn) noCredBtn.remove();
    noCredEl = document.createElement('div');
    noCredEl.id = 'nocred';
    noCredEl.style.cssText = 'max-width:22em;font-size:13px;line-height:1.5;opacity:.75;margin-top:2px';
    const signer = haveSigner();
    noCredEl.innerHTML =
      (when ? 'It was valid until ' + when.toLocaleString() + '.<br>' : '') +
      (signer ? 'Sign in with your Nostr key to enrol this browser again, or DM <b>link</b> to the box for a new one.'
              : 'DM <b>link</b> to the box for a new one.');
    connMsg.insertAdjacentElement('afterend', noCredEl);
    if (signer) {
      const btn = noCredBtn = document.createElement('button');
      btn.type = 'button';
      btn.id = 'signin';
      btn.textContent = 'Sign in with Nostr';
      btn.style.cssText = 'margin-top:10px;align-self:flex-start;pointer-events:auto;' +
        'touch-action:manipulation;-webkit-tap-highlight-color:transparent;' +
        'border:1px solid rgba(124,252,155,.55);background:transparent;color:#7CFC9B;' +
        'border-radius:11px;padding:8px 14px;font:600 13px/1 -apple-system,system-ui,sans-serif';
      // THE ONLY PLACE THE SIGNER IS EVER ASKED FOR.  Not even here does this handler call it: it
      // records the tap and reloads, and MAKEIDENTITY does the asking on the way back up.  A reload
      // is the retry this file already uses everywhere (SCHEDULERECONNECT says why), and it is the
      // only honest one — the PeerConnection on this page has already gathered, offered and failed.
      btn.addEventListener('click', e => {
        e.stopPropagation();
        askSignIn();
        diag('sign-in requested by hand — reloading to offer as the signer');
        setConnRaw('Signing in…');
        btn.disabled = true;
        clearReconnAttempts();
        location.reload();
      });
      noCredEl.insertAdjacentElement('afterend', btn);
    } else if (signerLooks++ < 6) {
      // An extension injects window.nostr on its own schedule, and this screen can be painted on
      // the first turn of the event loop (no code, no device).  Absent-at-render is therefore not
      // absent, and the difference is a button that never appears — so look again for three
      // seconds.  This does NOT call the signer; it reads a property, which is free.
      setTimeout(() => { if (haveSigner()) showNoCredential(why); }, 500);
    }
    failConn();
    diag('no usable credential' + (when ? ' (expired ' + when.toISOString() + ')' : '') +
         (signer ? ' — offering the signer' : ' — no signer to offer'));
  };
  window.__showNoCredential = showNoCredential;
  try { id = await makeIdentity(); }
  catch (e) {
    // A signer that was tapped and then declined lands here too, and it must land on the SAME
    // screen — otherwise the one action the page offered leaves it with no way to offer it again.
    showNoCredential(e.noCredential ? undefined : ('Sign-in failed: ' + e.message));
    return;
  }
  const pool = new SimplePool();

  // REPLAY: this filter has no since/limit, so relays hand us every gift wrap ever addressed to this
  // device key — including answers from previous sessions, which decrypt perfectly and look exactly
  // like a fresh one.  So we correlate: the box echoes back the ice-ufrag of the offer it is
  // answering, and that is minted per PeerConnection.  Ours or it is not our answer.
  let answered = false, myUfrag = null;
  pool.subscribeMany(relays, [{ kinds: [1059], '#p': [id.pub] }], {
    onevent: async (ev) => {
      if (answered) return;
      try {
        let answer = await id.unwrap(ev);
        try {
          const env = JSON.parse(answer);
          if (env && env.sdp) {
            if (!myUfrag || env.ufrag !== myUfrag) {
              diag(`ignored a replayed answer (ufrag ${env.ufrag || 'none'}, want ${myUfrag || 'pending'})`);
              return;
            }
            if (env.code) { storeCode(env.code); code = env.code; diag('credential renewed'); }
            answer = env.sdp;
          }
        } catch (_) { /* not JSON — a bare SDP, which only the pre-envelope box ever sent */ }
        if (answer && answer.includes('m=application')) {
          answered = true;
          const ac = (answer.match(/a=candidate[^\r\n]*/g) || []);
          diag(`answer ${answer.length}B, ${ac.length} cand (${ac.filter(c=>c.includes('srflx')).length} srflx)`);
          clearTimeout(window.__answerWatchdog);
          await pc.setRemoteDescription({ type: 'answer', sdp: answer });
          const ms = window.__offerAt ? Math.round(performance.now() - window.__offerAt) : null;
          setDetail(1, ms != null ? `answered in ${(ms / 1000).toFixed(1)}s` : 'answered');
          setStatus('answer received — establishing WebRTC…');
        }
      } catch (_) { /* not for us / not from the box */ }
    },
  });

  // Audio starts MUTED both ways.  A sendrecv transceiver with no track still negotiates the
  // m=audio line, and replaceTrack() attaches the real mic later without renegotiation (which our
  // one-shot Nostr signalling could not do anyway).  THE TRANSCEIVER IS THE SHELL'S because it has
  // to be in the offer; the microphone BUTTON is the payload's.
  try {
    window.__micSender = pc.addTransceiver('audio', { direction: 'sendrecv' }).sender;
    diag('audio negotiated (mic muted)');
  } catch (_) { try { pc.addTransceiver('audio', { direction: 'recvonly' }); } catch (_) {} }
  try { pc.addTransceiver('video', { direction: 'recvonly' }); diag('video recvonly requested'); } catch (_) {}
  setStatus('gathering ICE candidates…');
  await pc.setLocalDescription(await pc.createOffer());
  myUfrag = ((pc.localDescription.sdp || '').match(/a=ice-ufrag:(\S+)/) || [])[1] || null;
  // Non-trickle, but a blocked/slow STUN must NOT hang gathering (seen: 49s on cellular).
  await new Promise(res => {
    let done = false;
    const finish = why => { if (!done) { done = true; diag('gather ' + why); res(); } };
    if (pc.iceGatheringState === 'complete') return finish('complete');
    pc.addEventListener('icegatheringstatechange', () => { if (pc.iceGatheringState === 'complete') finish('complete'); });
    setTimeout(() => finish('timeout-10s'), 10000);
  });
  const cands = pc.localDescription.sdp.match(/a=candidate[^\r\n]*/g) || [];
  const nSrflx = cands.filter(c => c.includes('srflx')).length;
  const nRelay = cands.filter(c => c.includes('relay')).length;
  diag(`offer ${cands.length} cand: ${cands.length - nSrflx - nRelay} host ${nSrflx} srflx ${nRelay} relay`);
  setDetail(0, `${cands.length} routes · ${nRelay} relay`);
  window.__offerAt = performance.now();
  const payload = JSON.stringify(code ? { sdp: pc.localDescription.sdp, code } : { sdp: pc.localDescription.sdp });
  setStatus(id.mode === 'code' ? 'sending one-time-code offer…' : 'gift-wrapping offer to the box…');
  const wrap = await id.wrapOffer(payload);
  await Promise.any(pool.publish(relays, wrap));
  diag('offer published (' + id.mode + ')');
  setStatus('offer sent — waiting for the box');
  window.__answerWatchdog = setTimeout(async () => {
    if (pc.remoteDescription) return;
    // A `link' DM is signed with the DEVICE key and is answered for an enrolled device or an
    // allowlisted owner — so after a signed-in offer went unanswered there is nothing left for it
    // to prove, and fifteen seconds spent finding that out is fifteen seconds the screen spends
    // lying about what it is waiting for.
    if (!hasDevice() || id.mode === 'nip07') return window.__showNoCredential();
    diag('no answer — asking the box for a fresh code');
    setConnRaw('Renewing access…');
    const fresh = await requestFreshCode(pool, deviceSecret());
    if (fresh) { storeCode(fresh); diag('renewed — reloading'); location.reload(); }
    else window.__showNoCredential();
  }, 18000);
})();
