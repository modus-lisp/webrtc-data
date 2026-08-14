// t/signer-shim.js — a NIP-07 signer in the page, and a counter on every way to reach it.
//
// Installed only when ?signer=<64-hex-secret> is present, so "the signer is not there" is a real
// page load with a real absent window.nostr rather than a flag the shell is asked to believe.
//
// TWO COUNTERS, because the claim under test needs both halves said separately:
//
//   __signerReads   how often window.nostr was LOOKED AT.  Free in a real extension — reading the
//                   property injects nothing and pops nothing — and the failure screen is allowed
//                   to do it, which is how it knows whether to offer the button at all.
//   __signerCalls   how often a METHOD was invoked.  This is what a signer prompt IS: nostash
//                   raises its approval sheet on getPublicKey, signEvent and nip44.*, and on
//                   nothing else.  The assertion "it must never prompt without a tap" is exactly
//                   `__signerCalls === 0` up to the moment the button is pressed.
(function () {
  var sec = new URLSearchParams(location.search).get('signer');
  if (!sec) return;
  var N = window.NSIGNER;
  var key = new Uint8Array(sec.match(/../g).map(function (x) { return parseInt(x, 16); }));
  var pub = N.getPublicKey(key);
  window.__signerReads = 0;
  window.__signerCalls = 0;
  window.__signerPub = pub;
  var count = function (fn) { return function () { window.__signerCalls++; return fn.apply(null, arguments); }; };
  var signer = {
    getPublicKey: count(function () { return Promise.resolve(pub); }),
    signEvent: count(function (ev) {
      return Promise.resolve(N.finalizeEvent({ kind: ev.kind, created_at: ev.created_at,
                                               tags: ev.tags || [], content: ev.content }, key));
    }),
    nip44: {
      encrypt: count(function (peer, plaintext) {
        return Promise.resolve(N.encrypt(plaintext, N.getConversationKey(key, peer)));
      }),
      decrypt: count(function (peer, ciphertext) {
        return Promise.resolve(N.decrypt(ciphertext, N.getConversationKey(key, peer)));
      }),
    },
  };
  Object.defineProperty(window, 'nostr', {
    configurable: true,
    get: function () { window.__signerReads++; return signer; },
  });
})();
