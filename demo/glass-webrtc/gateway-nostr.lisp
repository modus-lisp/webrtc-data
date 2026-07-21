;;;; gateway-nostr.lisp — serve glass over WebRTC, signaled by NIP-59 gift-wrapped Nostr DMs.
;;;;
;;;; No HTTP, no tunnel, no port-forward, NOTHING inbound: the box only makes OUTBOUND
;;;; connections (to public Nostr relays + STUN).  A phone (loaded from an nsite, or any
;;;; https page) gift-wraps an SDP OFFER to the box's npub; we unwrap it, run the webrtc-data
;;;; answerer (ICE srflx + full-agent checks → DTLS → SCTP), bridge the data channel to glass,
;;;; and gift-wrap the ANSWER back to the phone.  The WebRTC data channel itself is direct P2P
;;;; (the box's home NAT is cone, so srflx works); Nostr carries only the signaling.
;;;;
;;;;   GLASS_PORT=5902 NOSTR_SEC=<64hex> sbcl --load gateway-nostr.lisp
;;;;   (NOSTR_SEC fixes the box's identity so its npub is stable; omit for a dev key.)

(require :asdf)
#+sbcl (setf (sb-ext:bytes-consed-between-gcs) (* 256 1024 1024))   ; fewer GCs on the send path
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system "webrtc-data")
  (asdf:load-system "cl-nostr"))
(load (merge-pathnames "login-token.lisp" (or *load-pathname* *default-pathname-defaults*)))

(in-package #:webrtc-data)

(defparameter *glass-host* (or (uiop:getenv "GLASS_HOST") "127.0.0.1"))
(defparameter *glass-port* (or (ignore-errors (parse-integer (uiop:getenv "GLASS_PORT"))) 5900))
(defparameter *relays*
  (let ((e (uiop:getenv "NOSTR_RELAYS")))
    (if e (remove "" (uiop:split-string e :separator ",") :test #'string=)
        '("wss://relay.damus.io" "wss://nos.lol" "wss://relay.primal.net"))))
;; A fixed secret so the box's npub is stable (bake it into the page). NOSTR_SEC overrides.
(defparameter *box-secret*
  (or (uiop:getenv "NOSTR_SEC")
      "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b"))

;; ---- pubkey auth: only these clients may open the desktop --------------------
;; NOSTR_ALLOW is a comma-separated list of authorized client pubkeys (npub or 64-hex).
;; The sender is the VERIFIED seal signer from unwrap-giftwrap (a forged rumor pubkey is
;; already rejected there), so an allowlist hit is a real cryptographic identity.  Unset
;; => refuse everyone (fail closed): with no allowlist there is no one to authorize.
(defun %normalize-pubkey (s)
  "npub1... / 64-hex / name@domain (NIP-05) -> 64-hex; blank -> NIL."
  (let ((s (string-trim '(#\Space #\Tab #\Newline #\Return) s)))
    (cond ((zerop (length s)) nil)
          ((cl-nostr.nip05:nip05-address-p s)                       ; an email-style identifier
           (ignore-errors (string-downcase (cl-nostr.nip05:resolve-pubkey s))))
          ((and (>= (length s) 4) (string-equal (subseq s 0 4) "npub"))
           (ignore-errors (string-downcase (cl-nostr.util:bytes->hex (cl-nostr.bech32:npub-decode s)))))
          (t (string-downcase s)))))

(defparameter *allow*
  (let ((e (uiop:getenv "NOSTR_ALLOW")))
    (when e
      (remove nil (mapcar #'%normalize-pubkey
                          (remove "" (uiop:split-string e :separator ",") :test #'string=))))))

(defun authorized-p (pubkey)
  "T iff PUBKEY (hex) is on the allowlist.  No allowlist => NIL (deny all)."
  (and pubkey *allow* (member (string-downcase pubkey) *allow* :test #'string=) t))

;; ---- one-time codes (magic-link login, keyed by *box-secret*) ----------------
;; A code arrives inside the offer envelope (see PARSE-OFFER); it was delivered to a
;; user via a gift-wrapped DM (login-link), so holding a valid one is proof enough —
;; no browser signer needed.  We enforce single-use with a spent-nonce set.
(defvar *spent* (make-hash-table :test 'equal) "nonce -> exp, for spent one-time codes")
(defvar *spent-lock* (sb-thread:make-mutex :name "spent-codes"))

(defun code-authorized-p (code)
  "T iff CODE is a valid, unexpired, unspent one-time login code — and marks it spent."
  (and (stringp code) (plusp (length code))
       (multiple-value-bind (ok nonce exp) (glass-login:verify-token *box-secret* code)
         (and ok nonce
              (sb-thread:with-mutex (*spent-lock*)
                (let ((now (- (get-universal-time) 2208988800)))
                  (maphash (lambda (k v) (when (< v now) (remhash k *spent*))) *spent*))  ; prune
                (unless (gethash nonce *spent*)
                  (setf (gethash nonce *spent*) exp)
                  t))))))

(defun parse-offer (payload)
  "An offer PAYLOAD is either a {\"sdp\",\"code\"} JSON envelope or a bare SDP string.
Return (values SDP CODE)."
  (or (ignore-errors
        (let ((j (com.inuoe.jzon:parse payload)))
          (when (and (hash-table-p j) (gethash "sdp" j))
            (values (gethash "sdp" j) (gethash "code" j)))))
      (values payload nil)))

(defun glass-connect ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-connect s (sb-bsd-sockets:make-inet-address *glass-host*) *glass-port*)
    (setf (sb-bsd-sockets:sockopt-tcp-nodelay s) t)      ; no Nagle on the tiny FBUR/input path
    s))

(defvar *last-assoc* nil)

(defun run-session (conn)
  "Drive DTLS, run the data channel, and bridge it to glass once the channel opens."
  (let ((glass nil))
    (unwind-protect
         (handler-case
             (progn
               (webrtc-dtls-run conn)
               (webrtc-serve-datachannel
                conn :duration 3600.0
                :on-ready
                (lambda (assoc sid)
                  (setf glass (glass-connect) *last-assoc* assoc)
                  (format *error-output* "~&[gw-nostr] channel open -> glass ~a:~a~%"
                          *glass-host* *glass-port*)
                  ;; glass -> browser: one message per read (SCTP fragments it)
                  (bt:make-thread
                   (lambda ()
                     (let ((buf (make-array 16384 :element-type '(unsigned-byte 8))))
                       (handler-case
                           (loop
                             (multiple-value-bind (b n) (sb-bsd-sockets:socket-receive glass buf nil)
                               (declare (ignore b))
                               (when (or (null n) (zerop n)) (return))
                               (sctp-send-binary assoc sid (subseq buf 0 n))))
                         (error () nil))))
                   :name "glass->ch"))
                :on-message
                (lambda (assoc sid payload)
                  (declare (ignore assoc sid))
                  (when (and glass (plusp (length payload)))
                    (sb-bsd-sockets:socket-send glass (as-u8vec payload) (length payload))))))
           (error (e) (format *error-output* "~&[gw-nostr] session error: ~a~%" e)))
      (when glass (ignore-errors (sb-bsd-sockets:socket-close glass))))))

(defun process-offer (offer-sdp)
  "Parse an SDP OFFER, run the answerer (srflx + full-agent checks for off-LAN), spawn the
   glass-bridged session, and return the ANSWER SDP."
  (let* ((offer (parse-sdp offer-sdp))
         (agent (make-ice :local-ip (uiop:getenv "ICE_LOCAL_IP")))
         (conn  (webrtc-dtls-setup agent :remote-fingerprint (sdp-fingerprint offer)))
         (answer (ice-answer agent offer :fingerprint (dtls-conn-fingerprint conn)
                             :gather-srflx t                    ; advertise our public mapping
                             :gather-relay (and (uiop:getenv "TURN_SERVER") t))))
    (ice-serve agent)
    (ice-start-checks agent)                                    ; punch our NAT toward the phone
    (bt:make-thread (lambda () (run-session conn)) :name "webrtc-session")
    answer))

;;; ---- Nostr signaling loop --------------------------------------------------
(let* ((kp      (cl-nostr.keys:keypair-from-secret *box-secret*))
       (box-pub (cl-nostr.keys:public-hex kp))
       (box-npub (ignore-errors (cl-nostr.bech32:npub-encode (cl-nostr.keys:public-key-of-secret *box-secret*))))
       (pool    (cl-nostr.pool:make-pool *relays*)))
  (format t "~&@@ nostr gateway  (glass ~a:~a)~%" *glass-host* *glass-port*)
  (format t "@@ box npub:   ~a~%" (or box-npub "(npub encode failed; use hex)"))
  (format t "@@ box pubkey: ~a~%" box-pub)
  (when box-npub
    (format t "@@ share URL:  https://~a.nsite.lol/#~a~%"
            (or (uiop:getenv "NSITE_NPUB")
                "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc")
            box-npub))
  (format t "@@ relays:     ~a~%" *relays*)
  (if *allow*
      (format t "@@ allowlist:  ~{~a~^, ~}~%" (mapcar (lambda (h) (subseq h 0 12)) *allow*))
      (format t "@@ allowlist:  (empty) — no NOSTR_ALLOW; only one-time codes admit clients.~%"))
  (format t "@@ login-link: sbcl --script login-link.lisp <npub|email> [ttl]  (DMs a code)~%")
  (finish-output)
  (cl-nostr.pool:pool-subscribe
   pool
   (list (cl-nostr.filter:make-filter :kinds '(1059) :tags (list (cons "p" (list box-pub)))))
   :on-event
   (lambda (wrap relay)
     (declare (ignore relay))
     (handler-case
         (multiple-value-bind (payload phone-pub) (cl-nostr.nip59:unwrap-giftwrap kp wrap)
           (multiple-value-bind (offer-sdp code) (parse-offer payload)
             (when (and (stringp offer-sdp) (search "m=application" offer-sdp))   ; a data-channel offer
               ;; a valid one-time code OR an allowlisted signer authorizes the connection
               (let ((via (cond ((code-authorized-p code) "code")
                                ((authorized-p phone-pub) "allowlist")
                                (t nil))))
                 (cond
                   ((null via)
                    (format t "~&@@ DENIED ~a... — no valid code, not on the allowlist~%"
                            (subseq phone-pub 0 8))
                    (finish-output))
                   (t
                    (format t "~&@@ offer from ~a... (via ~a) -> answering~%" (subseq phone-pub 0 8) via)
                    (finish-output)
                    (let* ((answer (process-offer offer-sdp))
                           (reply  (cl-nostr.nip59:build-giftwrap kp phone-pub answer)))
                      (cl-nostr.pool:pool-publish pool reply)
                      (format t "@@ answer gift-wrapped -> ~a...~%" (subseq phone-pub 0 8))
                      (finish-output))))))))
       (error (e) (format t "~&@@ signal error: ~a~%" e) (finish-output)))))
  (format t "@@ subscribed; waiting for gift-wrapped offers~%")
  (finish-output)
  (loop (sleep 5)))
