// t/box.entry.mjs — THE BOX, as a page: the desktop's admission rules and the gateway's answer.
//
// It is here rather than in Python because the honest version of this needs NIP-44, NIP-59 and a
// real SDP answer, and all three exist already in the browser.  So the box is a Nostr client of the
// same relay the phone talks to, unwrapping the phone's ACTUAL gift wraps with the box secret and
// gift-wrapping a REAL RTCPeerConnection answer back.  Nothing about the signalling is simulated;
// what is simulated is the desktop's store, which is a Map here and a file there.
//
// WHAT IT MIRRORS, and where each rule comes from:
//
//   ADMIT-PEER            glass/src/nostr.lisp — code / allowlist / device, first match, and any
//                         admitted peer is enrolled.  The renewal is minted for :code and :device.
//   ASK-ADMISSION         gateway-nostr.lisp — and then the top-up this change adds: an allowlist
//                         admission with no token gets one minted on the peer's own authority,
//                         which glass's `mint' verb grants to allowlist-or-enrolled.
//   MINT-LOGIN-TOKEN      nonce.exp.HMAC-SHA256(secret, "glass-login|nonce|exp") — the real format,
//                         so a code this file mints is one the desktop would accept, and the
//                         no-pubkey-in-the-MAC property the whole design turns on is exercised
//                         rather than asserted.
//   WRAP-SEEN-P           the gateway's duplicate guard: a relay replays its store on every REQ.
//
// Configuration rides the query string: ?relay=&sec=&secret=&allow=&ttl=
// Everything it did is on window.__box for the driver to read.
import { getPublicKey, verifyEvent } from 'nostr-tools/pure';
import { getConversationKey, decrypt as nip44Decrypt } from 'nostr-tools/nip44';
import { wrapEvent } from 'nostr-tools/nip59';

const q = new URLSearchParams(location.search);
const unhex = h => new Uint8Array(h.match(/../g).map(x => parseInt(x, 16)));
const hex = u8 => [...u8].map(b => b.toString(16).padStart(2, '0')).join('');

const boxSec = unhex(q.get('sec'));
const boxPub = getPublicKey(boxSec);
const hmacSecret = unhex(q.get('secret'));
const allow = new Set((q.get('allow') || '').split(',').filter(Boolean));
const TTL = parseInt(q.get('ttl') || '1800', 10);
// ?topup=0 is the box AS IT WAS: the negative control the driver runs last, so the suite can show
// that what it is measuring is the change and not the weather.
const TOPUP = q.get('topup') !== '0';

const enrolled = new Map();                       // pubkey -> expiry, the desktop's .glass-devices
const seen = new Set();                           // wrap ids, the gateway's WRAP-SEEN-P
const log = [];
window.__box = { pub: boxPub, log, enrolled, ready: false,
                 // the driver pre-enrols and pre-mints through these
                 enrol: p => enrolled.set(p, Math.floor(Date.now() / 1000) + 86400),
                 mint: (ttl) => mint(ttl) };

// ---- the token, in the format glass mints and verifies -----------------------------------------
const now = () => Math.floor(Date.now() / 1000);
async function mac(nonce, exp) {
  const k = await crypto.subtle.importKey('raw', hmacSecret, { name: 'HMAC', hash: 'SHA-256' },
                                          false, ['sign']);
  const m = new TextEncoder().encode(`glass-login|${nonce}|${exp}`);
  return hex(new Uint8Array(await crypto.subtle.sign('HMAC', k, m)));
}
async function mint(ttl = TTL) {
  const nonce = hex(crypto.getRandomValues(new Uint8Array(16)));
  const exp = now() + ttl;
  return `${nonce}.${exp}.${await mac(nonce, exp)}`;
}
async function tokenStatus(code) {
  if (!code) return 'absent';
  const p = String(code).split('.');
  if (p.length !== 3) return 'bad';
  const exp = parseInt(p[1], 10);
  if (!isFinite(exp)) return 'bad';
  if (p[2] !== await mac(p[0], exp)) return 'bad';
  return exp > now() ? 'ok' : 'expired';
}

// ---- ADMIT-PEER, and then the gateway's top-up -------------------------------------------------
async function admit(pub, code) {
  const status = await tokenStatus(code);
  const via = status === 'ok' ? 'code'
            : allow.has(pub) ? 'allowlist'
            : (enrolled.get(pub) || 0) > now() ? 'device'
            : null;
  if (via) enrolled.set(pub, now() + 86400);                   // ANY admitted peer is enrolled
  let token = (via === 'code' || via === 'device') ? await mint() : null;
  // ADMIT-PEER's fourth value: when the enrolment it just granted runs out.  The desktop's own
  // number, from the store the NEXT offer will be measured against — not a TTL this side computed.
  const expires = via ? enrolled.get(pub) : null;
  // ---- gateway-nostr.lisp, ASK-ADMISSION: the one line this change adds ------------------------
  // glass declines to push a bearer credential at an owner who has a signer.  True of the owner,
  // false of the browser they are sitting in front of — which holds a device key, not their npub.
  if (TOPUP && via === 'allowlist' && !token) token = await mint();   // == glass:admission-mint
  return { via, token, status, expires };
}

// ---- unwrap: the VERIFIED SEAL SIGNER is the peer, exactly as cl-nostr yields it ---------------
function unwrap(ev) {
  const seal = JSON.parse(nip44Decrypt(ev.content, getConversationKey(boxSec, ev.pubkey)));
  if (!verifyEvent(seal)) return null;                         // a forged rumour pubkey dies here
  const rumor = JSON.parse(nip44Decrypt(seal.content, getConversationKey(boxSec, seal.pubkey)));
  return { peer: seal.pubkey, content: rumor.content };
}

// ---- the relay ---------------------------------------------------------------------------------
const ws = new WebSocket(q.get('relay'));
const publish = ev => ws.send(JSON.stringify(['EVENT', ev]));
ws.addEventListener('open', () => {
  ws.send(JSON.stringify(['REQ', 'box', { kinds: [1059], '#p': [boxPub] }]));
  window.__box.ready = true;
});
ws.addEventListener('message', async (m) => {
  let msg; try { msg = JSON.parse(m.data); } catch (_) { return; }
  if (msg[0] !== 'EVENT' || msg[1] !== 'box') return;
  const ev = msg[2];
  if (seen.has(ev.id)) return;
  seen.add(ev.id);
  let u = null;
  try { u = unwrap(ev); } catch (e) { log.push({ t: 'unwrap-failed', why: String(e) }); return; }
  if (!u) return;
  let env = null;
  try { env = JSON.parse(u.content); } catch (_) { /* a command DM, not an offer */ }
  const sdp = env && env.sdp;
  if (!sdp || !sdp.includes('m=application')) {
    // A `link' command lands here.  The desktop answers it for an allowlisted or enrolled sender
    // and SAYS NOTHING to anyone else — the silence the failure screen exists because of.
    log.push({ t: 'not-an-offer', peer: u.peer, content: String(u.content).slice(0, 40) });
    return;
  }
  const { via, token, status, expires } = await admit(u.peer, env.code);
  if (!via) { log.push({ t: 'denied', peer: u.peer, why: status }); return; }
  log.push({ t: 'admitted', peer: u.peer, via, status, gaveCode: Boolean(token), expires });
  // A REAL answer, from a real PeerConnection, so the phone's setRemoteDescription is a real one.
  const pc = new RTCPeerConnection({ iceServers: [] });
  await pc.setRemoteDescription({ type: 'offer', sdp });
  const answer = await pc.createAnswer();
  await pc.setLocalDescription(answer);
  const payload = { sdp: pc.localDescription.sdp,
                    ufrag: (sdp.match(/a=ice-ufrag:(\S+)/) || [])[1] };
  if (token) payload.code = token;
  // …and the enrolment's expiry rides with it.  ?expires=0 is the box AS IT WAS, for the control
  // that shows the client falls back to its guess rather than breaking when nothing says.
  if (expires && q.get('expires') !== '0') payload.expires = expires;
  publish(wrapEvent({ kind: 14, content: JSON.stringify(payload), tags: [['p', u.peer]] },
                    boxSec, u.peer));
  log.push({ t: 'answered', peer: u.peer, ufrag: payload.ufrag });
});
