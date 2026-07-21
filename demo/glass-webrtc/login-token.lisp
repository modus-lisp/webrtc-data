;;;; login-token.lisp — one-time login codes for the glass gateway.
;;;;
;;;; A code is self-authenticating and stateless to MINT + cryptographically verify:
;;;;
;;;;   token = <nonce-hex> "." <exp-unix> "." <mac-hex>
;;;;   mac   = HMAC-SHA256( box-secret-bytes, "glass-login|" nonce "|" exp )
;;;;
;;;; Whoever holds the box secret (the gateway, and the login-link minter) can verify a
;;;; token's MAC + expiry with no shared state.  SINGLE-USE is enforced separately by the
;;;; gateway, which remembers spent nonces until they expire.  The token is delivered to a
;;;; user inside a gift-wrapped DM (only that npub can read it), so holding a valid code is
;;;; the proof of identity — no browser signer needed.

(defpackage #:glass-login
  (:use #:cl)
  (:export #:mint-token #:verify-token #:token-nonce #:token-exp))

(in-package #:glass-login)

(defparameter *default-ttl* 900 "Default code lifetime, seconds (15 min).")
(defconstant +unix-epoch+ 2208988800)
(defun %now () (- (get-universal-time) +unix-epoch+))

(defun %secret-bytes (secret)
  "SECRET as 64-hex string, bytes, or integer -> (unsigned-byte 8) vector."
  (etypecase secret
    (string (ironclad:hex-string-to-byte-array secret))
    (integer (ironclad:integer-to-octets secret :n-bits 256))
    (sequence (coerce secret '(vector (unsigned-byte 8))))))

(defun %hmac-hex (key-bytes message)
  (let ((m (ironclad:make-mac :hmac key-bytes :sha256)))
    (ironclad:update-mac m (ironclad:ascii-string-to-byte-array message))
    (ironclad:byte-array-to-hex-string (ironclad:produce-mac m))))

(defun %mac (secret nonce exp)
  (%hmac-hex (%secret-bytes secret) (format nil "glass-login|~a|~a" nonce exp)))

(defun %ct-equal (a b)
  "Constant-time string compare (avoid a timing oracle on the MAC)."
  (and (stringp a) (stringp b) (= (length a) (length b))
       (loop with diff = 0
             for ca across a for cb across b
             do (setf diff (logior diff (logxor (char-code ca) (char-code cb))))
             finally (return (zerop diff)))))

(defun mint-token (secret &key (ttl *default-ttl*))
  "Mint a one-time login code valid for TTL seconds, keyed by box SECRET."
  (let* ((nonce (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))
         (exp   (+ (%now) ttl)))
    (format nil "~a.~a.~a" nonce exp (%mac secret nonce exp))))

(defun verify-token (secret token)
  "Verify TOKEN's MAC and expiry against box SECRET.  Returns (values OK NONCE EXP):
OK is T only if the MAC checks out AND the code has not expired.  (Single-use is the
caller's job — key a spent-set on NONCE.)"
  (when (stringp token)
    (let ((dots (loop for i from 0 for c across token when (char= c #\.) collect i)))
      (when (= (length dots) 2)
        (let* ((nonce (subseq token 0 (first dots)))
               (exp-s (subseq token (1+ (first dots)) (second dots)))
               (mac   (subseq token (1+ (second dots))))
               (exp   (ignore-errors (parse-integer exp-s))))
          (when (and exp (%ct-equal mac (%mac secret nonce exp)))
            (values (> exp (%now)) nonce exp)))))))
