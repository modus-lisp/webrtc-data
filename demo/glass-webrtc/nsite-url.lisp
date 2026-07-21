;;;; nsite-url.lisp — print the shareable glass-over-WebRTC URL for a backend identity.
;;;;
;;;;   sbcl --script nsite-url.lisp <box-npub | 64-hex | name@domain>
;;;;
;;;; The backend (box) npub is placed in the URL's #hash fragment, which the nsite
;;;; gateway never receives (it's client-only) — so the signaling target stays out of
;;;; server logs.  A NIP-05 address (name@domain) is resolved to its pubkey first, so
;;;; you can hand this an email.  Override the hosting nsite with NSITE_NPUB=npub1<site>.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (funcall (read-from-string "ql:quickload") :cl-nostr)))

(defun arg->npub (s)
  "Coerce S (npub / hex / NIP-05 email) to an npub string."
  (cond ((cl-nostr.nip05:nip05-address-p s)
         (let ((hex (cl-nostr.nip05:resolve-pubkey s)))
           (unless hex (error "NIP-05 ~a did not resolve to a pubkey" s))
           (cl-nostr.bech32:npub-encode hex)))
        ((and (>= (length s) 4) (string-equal (subseq s 0 4) "npub")) s)
        (t (cl-nostr.bech32:npub-encode (string-downcase s)))))     ; 64-hex

(let ((arg (second sb-ext:*posix-argv*))
      (site (or (uiop:getenv "NSITE_NPUB")
                "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc")))
  (unless arg
    (format *error-output* "usage: nsite-url <box-npub | 64-hex | name@domain>~%")
    (sb-ext:exit :code 1))
  (handler-case
      (format t "https://~a.nsite.lol/#~a~%" site (arg->npub arg))
    (error (e) (format *error-output* "nsite-url: ~a~%" e) (sb-ext:exit :code 1))))
