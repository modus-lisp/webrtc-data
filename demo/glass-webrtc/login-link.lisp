;;;; login-link.lisp — DM a one-time glass login link to a Nostr identity.
;;;;
;;;;   NOSTR_SEC=<box 64-hex> sbcl --script login-link.lisp <npub | hex | name@domain> [ttl-seconds]
;;;;
;;;; Mints a one-time code (login-token.lisp), builds the nsite URL with the box npub +
;;;; code in the #hash fragment, and gift-wraps it as a NIP-17 DM to the target.  Only
;;;; that npub can decrypt the DM, so receiving the code is the login — no browser signer
;;;; is needed.  The gateway (same box secret) verifies the code and answers.  Override the
;;;; hosting nsite with NSITE_NPUB, the relays with NOSTR_RELAYS.

(require :asdf)
(let ((here (or *load-pathname* *default-pathname-defaults*)))
  (load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
  (handler-bind ((warning #'muffle-warning))
    (let ((*standard-output* (make-broadcast-stream)))
      (funcall (read-from-string "ql:quickload") '(:cl-nostr :ironclad))))
  (load (merge-pathnames "login-token.lisp" here)))

(defpackage #:login-link-cli (:use #:cl))
(in-package #:login-link-cli)

;; REQUIRED, and for a sharper reason here than in the gateway: this script MINTS credentials.
;; With the old committed fallback it would cheerfully issue a link signed by a secret anyone can
;; read — a link that looks exactly like a real one and admits anybody who copies it.  A minter
;; with no key must fail, never improvise.  See gateway-nostr.lisp's note.
(defparameter *box-secret*
  (let ((s (uiop:getenv "NOSTR_SEC")))
    (unless (and s (= (length s) 64) (every (lambda (c) (digit-char-p c 16)) s))
      (format *error-output*
              "~&login-link: NOSTR_SEC unset or not 64 hex chars — refusing to mint a link.~@
                 ~&  Use the same secret the gateway runs on (gw-keepalive.sh), or the code will~@
                 ~&  not verify:  NOSTR_SEC=$(...) sbcl --script login-link.lisp <npub|email>~%")
      (finish-output *error-output*)
      (sb-ext:exit :code 2))
    s))
(defparameter *site*
  (or (uiop:getenv "NSITE_NPUB")
      "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc"))
(defparameter *relays*
  (let ((e (uiop:getenv "NOSTR_RELAYS")))
    (if e (remove "" (uiop:split-string e :separator ",") :test #'string=)
        '("wss://relay.damus.io" "wss://nos.lol" "wss://relay.primal.net"))))

(defun target->hex (s)
  "npub / 64-hex / name@domain -> 64-hex pubkey."
  (cond ((cl-nostr.nip05:nip05-address-p s) (cl-nostr.nip05:resolve-pubkey s))
        ((and (>= (length s) 4) (string-equal (subseq s 0 4) "npub"))
         (cl-nostr.util:bytes->hex (cl-nostr.bech32:npub-decode s)))
        (t (string-downcase s))))

(let* ((arg (second sb-ext:*posix-argv*))
       ;; 600 s, matching GLASS:*LOGIN-TTL* — a LINK is a credential in transit and its TTL is the
       ;; only bound on a leaked one.  These used to disagree (900 here, 1800 there) with nothing
       ;; saying which was meant.  Still overridable as the second argument.
       (ttl (or (ignore-errors (parse-integer (or (third sb-ext:*posix-argv*) ""))) 600)))
  (unless arg
    (format *error-output* "usage: login-link <npub | 64-hex | name@domain> [ttl-seconds]~%")
    (sb-ext:exit :code 1))
  (handler-case
      (let* ((target (or (target->hex arg) (error "could not resolve ~a to a pubkey" arg)))
             (box-kp (cl-nostr.keys:keypair-from-secret *box-secret*))
             (box-npub (cl-nostr.bech32:npub-encode (cl-nostr.keys:public-hex box-kp)))
             (token (glass-login:mint-token *box-secret* :ttl ttl))
             ;; LOGIN_URL_BASE overrides the page location (e.g. a Blossom blob URL while an
             ;; nsite gateway's cache catches up); default is the nsite site URL.
             (base (or (uiop:getenv "LOGIN_URL_BASE")
                       (format nil "https://~a.nsite.lol/" *site*)))
             (url (format nil "~a#box=~a&code=~a" base box-npub token))
             (msg (format nil "Your one-time glass desktop link (expires in ~a min):~%~%~a"
                          (max 1 (round ttl 60)) url))
             (wrap (cl-nostr.nip59:build-giftwrap box-kp target msg))
             (pool (cl-nostr.pool:make-pool *relays*)))
        (cl-nostr.pool:pool-publish pool wrap)
        (sleep 2)                                   ; let the relays ack before we exit
        (format t "~&@@ DM'd a one-time login link to ~a…~%@@ ~a~%" (subseq target 0 8) url))
    (error (e) (format *error-output* "login-link: ~a~%" e) (sb-ext:exit :code 1))))
