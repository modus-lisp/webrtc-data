// t/signer.entry.mjs — the crypto a NIP-07 signer needs, as a global for the page shim beside it.
//
// The shim (signer-shim.js) is a CLASSIC script so it runs before the shell's deferred module and
// window.nostr is there when the shell looks — which is what an extension does.  A classic script
// cannot import, so the primitives come in through this bundle instead.
export { getPublicKey, finalizeEvent } from 'nostr-tools/pure';
export { getConversationKey, encrypt, decrypt } from 'nostr-tools/nip44';
