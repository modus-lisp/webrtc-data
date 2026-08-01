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
  (asdf:load-system "webrtc-media/rtc")     ; SRTP audio (beeping tone + level) over the same transport
  (asdf:load-system "cl-nostr"))
(load (merge-pathnames "login-token.lisp" (or *load-pathname* *default-pathname-defaults*)))
(load (merge-pathnames "glass-capture.lisp" (or *load-pathname* *default-pathname-defaults*)))
;; the video profiles + the control channel that switches between them mid-session
(load (merge-pathnames "video-profiles.lisp" (or *load-pathname* *default-pathname-defaults*)))

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

;; ---- self-service link refresh: an allowlisted identity can DM the box (any short
;; text containing "link") and get a fresh login link gift-wrapped back, so they don't
;; need box shell access when a code expires.
(defun link-request-p (payload)
  "T iff PAYLOAD is a short plain-text DM asking for a link (not an SDP offer)."
  (and (stringp payload) (<= (length payload) 64)
       (search "link" (string-downcase payload))))

;; ---- DM command surface ------------------------------------------------------
;; The box has no HTTP and no console, but it does have an authenticated DM channel, so that is
;; where administration lives.  Commands are short text DMs; the reply is plain text.
;;
;;   link                 -> a fresh magic link          (allowlist or an enrolled device)
;;   devices              -> list enrolled terminals     (allowlist ONLY)
;;   revoke <prefix|all>  -> un-enrol one or all         (allowlist ONLY)
;;   help                 -> this list
;;
;; Management is restricted to the allowlist on purpose: a device key is a bearer credential that
;; could be lifted from a browser, and it must not be able to keep itself alive, revoke the others,
;; or enumerate the fleet.  It can only ask for a link.
(defun parse-command (payload)
  "A short text DM -> (values VERB ARG), or NIL if it is not a command."
  (when (and (stringp payload) (<= (length payload) 80))
    (let* ((txt (string-trim '(#\Space #\Tab #\Newline #\Return) (string-downcase payload)))
           (sp (position #\Space txt))
           (verb (if sp (subseq txt 0 sp) txt))
           (arg (and sp (string-trim '(#\Space) (subseq txt (1+ sp))))))
      (cond ((zerop (length txt)) nil)
            ((search "link" verb) (values :link nil))
            ((string= verb "devices") (values :devices nil))
            ((string= verb "revoke") (values :revoke arg))
            ((or (string= verb "help") (string= verb "?")) (values :help nil))
            (t nil)))))

(defun describe-devices ()
  "Human-readable listing of enrolled terminals."
  (sync-devices)
  (let ((now (%unix-now)) (rows '()))
    (bt:with-lock-held (*devices-lock*)
      (maphash (lambda (pk exp) (when (> exp now) (push (cons pk exp) rows))) *devices*))
    (if (null rows)
        "No terminals are enrolled."
        (format nil "~a enrolled terminal~:p:~%~{~a~%~}~@
                     Use \"revoke <first-8>\" or \"revoke all\"."
                (length rows)
                (mapcar (lambda (r)
                          (let ((hrs (/ (- (cdr r) now) 3600.0)))
                            (if (< hrs 1)
                                (format nil "  ~a  expires in ~d min" (subseq (car r) 0 8)
                                        (max 1 (round (* hrs 60))))
                                (format nil "  ~a  expires in ~,1f h" (subseq (car r) 0 8) hrs))))
                        (sort rows #'> :key #'cdr))))))

(defun revoke-devices (arg)
  "Un-enrol terminals matching ARG (an 8+ char pubkey prefix, or \"all\").  Returns a reply string."
  (sync-devices)
  (let ((killed '()))
    (bt:with-lock-held (*devices-lock*)
      (cond
        ((and arg (string= arg "all"))
         (maphash (lambda (pk exp) (declare (ignore exp)) (push pk killed)) *devices*)
         (clrhash *devices*))
        ((and arg (>= (length arg) 4))
         (maphash (lambda (pk exp) (declare (ignore exp))
                    (when (and (>= (length pk) (length arg))
                               (string= arg (subseq pk 0 (length arg))))
                      (push pk killed)))
                  *devices*)
         (dolist (pk killed) (remhash pk *devices*)))))
    (save-devices)
    (cond ((null arg) "Usage: revoke <first-8-of-pubkey> | revoke all")
          ((null killed) (format nil "Nothing matched \"~a\"." arg))
          (t (format nil "Revoked ~a terminal~:p:~%~{  ~a~%~}" (length killed)
                     (mapcar (lambda (pk) (subseq pk 0 8)) killed))))))
(defparameter *nsite-npub*
  (or (uiop:getenv "NSITE_NPUB")
      "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc"))
(defparameter *link-base*                       ; LOGIN_URL_BASE lets us aim at a cache-busted ?v= URL
  (or (uiop:getenv "LOGIN_URL_BASE") (format nil "https://~a.nsite.lol/" *nsite-npub*)))
(defparameter *link-ttl* (or (ignore-errors (parse-integer (uiop:getenv "LINK_TTL"))) 1800))

;; ---- enrolled devices ("remember this terminal") -----------------------------
;; A browser cannot hold the user's Nostr identity without a signer, so instead each page keeps
;; its OWN key and signs its offers with it.  When such an offer is admitted by a valid one-time
;; code, we ENROL that sender for DEVICE_TTL (default 24h): afterwards the device can ask us for
;; a fresh magic link itself, over the same gift-wrapped DM channel, with no user involved.
;;
;; This is a deliberate trust delegation — the device key becomes a bearer credential — so it is
;; bounded two ways: it only ever comes from a session that already authenticated, and it lapses
;; unless refreshed by connecting.  Enrolments are persisted because the gateway restarts often
;; (a keepalive supervises it) and an in-memory set would silently un-enrol every device on deploy.
(defparameter *device-ttl* (or (ignore-errors (parse-integer (uiop:getenv "DEVICE_TTL"))) 86400))
;; Live pipeline stats, written as data rather than only logged, so a UI can present them instead of
;; a human grepping the log.  Same file-as-source-of-truth arrangement as the device store: any
;; process can read it, no IPC.
(defparameter *stats-file* (or (uiop:getenv "STATS_FILE") "/tmp/glass-stats.sexp"))
(defun write-stats (plist)
  (handler-case
      (with-open-file (s *stats-file* :direction :output :if-exists :supersede
                                      :if-does-not-exist :create)
        (let ((*print-readably* nil) (*print-pretty* nil))
          (prin1 plist s) (terpri s)))
    (error () nil)))
(defparameter *device-file*
  (or (uiop:getenv "DEVICE_FILE")
      ;; make-pathname with an explicit :type nil — merge-pathnames would inherit "lisp" from
      ;; gateway-nostr.lisp and write ".glass-devices.lisp", i.e. a data file that looks like
      ;; source in a directory we load source from.
      (namestring (make-pathname :name ".glass-devices" :type nil
                                 :defaults (or *load-pathname* *default-pathname-defaults*)))))
(defvar *devices* (make-hash-table :test 'equal))     ; pubkey-hex -> expiry (unix)
(defvar *devices-lock* (bt:make-lock))
(defvar *devices-mtime* nil)

(defun %unix-now () (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0)))

(defun load-devices ()
  (handler-case
      (with-open-file (s *device-file* :if-does-not-exist nil)
        (when s
          (bt:with-lock-held (*devices-lock*)
            (loop for line = (read-line s nil) while line do
              (let* ((sp (position #\Space line))
                     (pk (and sp (subseq line 0 sp)))
                     (exp (and sp (ignore-errors (parse-integer (subseq line (1+ sp)))))))
                (when (and pk exp (> exp (%unix-now)))
                  (setf (gethash (string-downcase pk) *devices*) exp)))))))
    (error () nil)))

(defun save-devices ()
  (handler-case
      (with-open-file (s *device-file* :direction :output :if-exists :supersede
                                       :if-does-not-exist :create)
        (bt:with-lock-held (*devices-lock*)
          (maphash (lambda (pk exp) (when (> exp (%unix-now)) (format s "~a ~a~%" pk exp)))
                   *devices*)))
    (error () nil)))

(defun sync-devices ()
  "Re-read DEVICE_FILE if it changed underneath us.  The file — not this process's memory — is the
source of truth, so a separate tool (a glass admin app, a shell one-liner) can list or revoke
terminals and the gateway will honour it on the next check without a restart."
  (handler-case
      (let ((mt (file-write-date *device-file*)))
        (unless (eql mt *devices-mtime*)
          (setf *devices-mtime* mt)
          (bt:with-lock-held (*devices-lock*) (clrhash *devices*))
          (load-devices)))
    (error () nil)))

(defun enrol-device (pubkey)
  "Trust PUBKEY to request its own magic links for *DEVICE-TTL*.  Renews an existing enrolment."
  (when pubkey
    (bt:with-lock-held (*devices-lock*)
      (setf (gethash (string-downcase pubkey) *devices*) (+ (%unix-now) *device-ttl*)))
    (save-devices)))

(defun device-enrolled-p (pubkey)
  (sync-devices)
  (and pubkey
       (bt:with-lock-held (*devices-lock*)
         (let ((exp (gethash (string-downcase pubkey) *devices*)))
           (and exp (> exp (%unix-now)) t)))))

;; ---- login codes (magic-link, keyed by *box-secret*) ------------------------
;; A code arrives inside the offer envelope (see PARSE-OFFER); it was delivered to a
;; user via a gift-wrapped DM (login-link), so holding a valid one is proof enough —
;; no browser signer needed.  A code is REUSABLE until it expires: its TTL (+ the
;; authenticated DM delivery) is the security boundary, and reuse is what lets a page
;; reload / retry work (single-use burned the code on the first, possibly-failed, try).
(defun code-status (code)
  "Classify CODE: :OK (valid + unexpired), :EXPIRED, :BAD (wrong MAC / malformed), or
:ABSENT.  Distinct reasons so a denied login is diagnosable."
  (if (or (not (stringp code)) (zerop (length code)))
      :absent
      (multiple-value-bind (ok nonce) (glass-login:verify-token *box-secret* code)
        (cond
          ((null nonce) :bad)                          ; bad MAC / not a token
          ((not ok) :expired)                          ; MAC good but past its expiry
          (t :ok)))))

(defun parse-offer (payload)
  "An offer PAYLOAD is either a {\"sdp\",\"code\"} JSON envelope or a bare SDP string.
Return (values SDP CODE).  (Uses IF, not OR: OR would keep only the primary value and
silently drop CODE.)"
  (let ((j (ignore-errors (com.inuoe.jzon:parse payload))))
    (if (and (hash-table-p j) (gethash "sdp" j))
        (values (gethash "sdp" j) (gethash "code" j))
        (values payload nil))))

(defun glass-connect ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-connect s (sb-bsd-sockets:make-inet-address *glass-host*) *glass-port*)
    (setf (sb-bsd-sockets:sockopt-tcp-nodelay s) t)      ; no Nagle on the tiny FBUR/input path
    s))

(defvar *last-assoc* nil)

;; Connection health, counted rather than only logged.  These ride the stats file, so the pipeline
;; monitor shows them: a failed session should be visible in the UI instead of buried in a log nobody
;; is tailing at the moment it happens.
(defvar *sessions-ok* 0)
(defvar *sessions-failed* 0)
(defvar *last-error* nil)
(defvar *no-relay-count* 0)
;; VP8 payload type the browser assigned in its offer (dynamic, varies) — bound per session.
(defvar *video-pt* nil)
;; VIDEO_PRIMARY=1 -> the desktop is delivered as VP8 video, and the RFB data channel is used for
;; INPUT ONLY: we swallow the browser's FramebufferUpdateRequests so glass never sends pixels down
;; the SCTP path.  Otherwise both paths would carry the same screen and compete for bandwidth.
(defparameter *video-primary* (and (uiop:getenv "VIDEO_PRIMARY") t))
(defparameter *video-qi* (or (ignore-errors (parse-integer (uiop:getenv "VIDEO_QI"))) 12))
(defparameter *video-fps* (or (ignore-errors (parse-integer (uiop:getenv "VIDEO_FPS"))) 4))
;; quality adapts between VIDEO_QI (sharpest) and VIDEO_MAX_QI, steering toward VIDEO_TARGET_KBS;
;; once the screen is quiet, coarsely-coded macroblocks are re-coded at VIDEO_QI.
(defparameter *video-max-qi* (or (ignore-errors (parse-integer (uiop:getenv "VIDEO_MAX_QI"))) 44))
(defparameter *video-target-kbs* (or (ignore-errors (parse-integer (uiop:getenv "VIDEO_TARGET_KBS"))) 150))

(defun run-session (conn agent)
  "Drive DTLS, run the data channel, and bridge it to glass once the channel opens.
Closes AGENT on exit so its TURN allocation is released (not leaked for ~600s)."
  (let ((glass nil) (audio-stop nil) (video-stop nil) (cap nil))
    (unwind-protect
         (handler-case
             (progn
               (webrtc-dtls-run conn)
               ;; audio rides the same transport: derive SRTP keys from the DTLS session, then
               ;; beep a tone at the browser + report the level of whatever it sends back.
               (multiple-value-bind (astop ctx)
                   (ignore-errors
                     (webrtc-media:start-audio
                      agent (dtls-conn-session conn)
                      :on-rx-level (let ((n 0))
                                     (lambda (lvl)
                                       (when (zerop (mod (incf n) 50))   ; ~1x/s
                                         (format *error-output* "~&[audio] rx level ~,2f (mic from browser)~%" lvl)
                                         (finish-output *error-output*))))
                      :log (lambda (m) (format *error-output* "~&[audio] ~a~%" m))))
                 (setf audio-stop astop)
                 (format *error-output* "~&[gw-nostr] audio started — beeping tone -> browser~%")
                 ;; video: our from-scratch VP8 keyframes, over the same SRTP keys (own SSRC)
                 (when (and ctx *video-pt*)
                   (when *video-primary*
                     (setf cap (ignore-errors (capture-start *glass-host* *glass-port*)))
                     (format *error-output* "~&[gw-nostr] desktop capture ~:[FAILED~;up~] (video-primary)~%" cap))
                   (setf video-stop
                         (ignore-errors
                           (webrtc-media:start-video
                            agent (dtls-conn-session conn) ctx :pt *video-pt*
                            :qi *video-qi* :fps *video-fps*
                            :max-qi *video-max-qi* :target-kbs *video-target-kbs*
                            :source (when cap (lambda () (capture-take cap)))
                            :on-stats (lambda (v)
                                        (write-stats
                                         (list :video v
                                               :sessions-ok *sessions-ok*
                                               :sessions-failed *sessions-failed*
                                               :no-relay *no-relay-count*
                                               :last-error *last-error*
                                               :devices (hash-table-count *devices*)
                                               :glass (list :host *glass-host* :port *glass-port*)
                                               :qi-base *video-qi* :target-kbs *video-target-kbs*)))
                            :log (lambda (m)
                                   (let ((cs (and cap (capture-stats cap))))
                                     (format *error-output* "~&[video] ~a~@[ | glass wait ~,0fms conv ~,0fms upd ~a px ~a copies ~a rc ~a~]~%"
                                             m (and cs (getf cs :wait-ms)) (and cs (getf cs :convert-ms))
                                             (and cs (getf cs :updates)) (and cs (getf cs :px)) (and cs (getf cs :copies)) (and cs (getf cs :reconnects))))))))
                   (format *error-output* "~&[gw-nostr] video started — VP8 pt=~a qi=~a fps=~a~%"
                           *video-pt* *video-qi* *video-fps*)))
               (webrtc-serve-datachannel
                conn :duration 3600.0
                :on-ready
                (lambda (assoc sid)
                  (setf glass (glass-connect) *last-assoc* assoc)
                  (incf *sessions-ok*)
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
                   :name "glass->ch")
                  ;; SCTP health: per-2s rate + cwnd/flight/outq, to spot a relay-path stall.
                  (bt:make-thread
                   (lambda ()
                     (let ((prev (sctp-stats assoc)) (tp (get-internal-real-time)))
                       (loop until (eq (getf (sctp-stats assoc) :state) :aborted) do
                         (sleep 2.0)
                         (let* ((now (sctp-stats assoc)) (tn (get-internal-real-time))
                                (dt (max 1d-3 (/ (float (- tn tp) 1d0) internal-time-units-per-second))))
                           (flet ((d (k) (- (or (getf now k) 0) (or (getf prev k) 0))))
                             (format *error-output*
                                     "~&[stats] out ~,1fKB/s in ~,1fKB/s rtx ~a cwnd ~a flight ~a outq ~a srtt ~a~%"
                                     (/ (d :bytes-out) 1024d0 dt) (/ (d :bytes-in) 1024d0 dt) (d :rtx)
                                     (getf now :cwnd) (getf now :flight) (getf now :send-q)
                                     (let ((s (getf now :srtt-ms))) (if s (format nil "~,1fms" s) "-"))))
                           (setf prev now tp tn)))))
                   :name "stats"))
                :on-message
                (lambda (assoc sid payload)
                  ;; The phone's SECOND channel (stream 100) is control, not RFB: a quality-profile
                  ;; switch, applied to the running sender and answered with what took effect.
                  ;; Keeping it off the RFB stream is the point — that one is a byte protocol with
                  ;; its own framing, and nothing here has to know how to tell the two apart.
                  (cond
                    ((control-sid-p sid) (handle-control-message assoc sid payload))
                    ((and glass (plusp (length payload)))
                     (let ((bytes (as-u8vec payload)))
                       ;; in video-primary mode drop FramebufferUpdateRequest (type 3, 10 bytes) so
                       ;; glass sends no pixels over SCTP; everything else (input) passes through
                       (if (and *video-primary* (= 10 (length bytes)) (= 3 (aref bytes 0)))
                           nil
                           (sb-bsd-sockets:socket-send glass bytes (length bytes)))))))))
           (error (e)
             (incf *sessions-failed*)
             (setf *last-error* (let ((s (princ-to-string e)))
                                  (subseq s 0 (min 72 (length s)))))
             (format *error-output* "~&[gw-nostr] session error: ~a~%" e)))
      (when cap (ignore-errors (capture-stop cap)))
      (when video-stop (ignore-errors (funcall video-stop)))
      (when audio-stop (ignore-errors (funcall audio-stop)))
      (when glass (ignore-errors (sb-bsd-sockets:socket-close glass)))
      (ignore-errors (ice-close agent)))))   ; release the TURN allocation + ICE socket

(defun process-offer (offer-sdp)
  "Parse an SDP OFFER, run the answerer (srflx + full-agent checks for off-LAN), spawn the
   glass-bridged session, and return the ANSWER SDP."
  (let* ((offer (parse-sdp offer-sdp))
         (agent (make-ice :local-ip (uiop:getenv "ICE_LOCAL_IP")))
         (conn  (webrtc-dtls-setup agent :remote-fingerprint (sdp-fingerprint offer)))
         (answer (ice-answer agent offer :fingerprint (dtls-conn-fingerprint conn)
                             :gather-srflx t                    ; advertise our public mapping
                             ;; a plist -> ice-gather-relay keys; a longer timeout so the Allocate
                             ;; reliably completes (2s was racy under load).
                             :gather-relay (and (uiop:getenv "TURN_SERVER") (list :timeout 6.0)))))
    ;; A missing relay candidate is THE failure that kills cellular: without it a hard-NAT peer has
    ;; no pairable path at all, and the symptom ("no ICE peer within 20s") appears 20 s later at the
    ;; far end, which is a terrible place to learn it.  So if gathering produced no relay, retry once
    ;; — an Allocate lost to a single dropped packet is worth ~150 ms to recover — and if it still
    ;; fails, say so loudly and count it.
    (when (and (uiop:getenv "TURN_SERVER") (null (ice-agent-relay-ip agent)))
      (format t "~&@@ WARN no relay candidate — retrying TURN allocate~%")
      (finish-output)
      (ignore-errors (ice-gather-relay agent :timeout 6.0))
      (unless (ice-agent-relay-ip agent)
        (incf *no-relay-count*)
        (setf *last-error* "no relay candidate (cellular peers cannot pair)")
        (format t "~&@@ ERROR still no relay candidate: a hard-NAT peer WILL fail to connect~%")
        (finish-output)))
    ;; What we actually advertised: without a relay line a hard-NAT (cellular) peer has no
    ;; pairable path, so log it per answer — this is the first thing to check on "ice failed".
    (format t "~&@@ ice: srflx=~a:~a relay=~a:~a  peer-cands=~a~%"
            (ice-agent-srflx-ip agent) (ice-agent-srflx-port agent)
            (ice-agent-relay-ip agent) (ice-agent-relay-port agent)
            (length (ice-agent-remote-candidates agent)))
    (ice-serve agent)
    (ice-start-checks agent)                                    ; punch our NAT toward the phone
    (setf *video-pt*                                            ; VP8 pt from the offer, if it wants video
          (let ((v (find "video" (sdp-media offer) :key #'sdp-media-type :test #'string=)))
            (and v (sdp-media-codec-pt v "VP8"))))
    (bt:make-thread (lambda () (run-session conn agent)) :name "webrtc-session")
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
  (load-devices)
  (format t "@@ devices:    ~a enrolled (ttl ~ah)~%" (hash-table-count *devices*) (round *device-ttl* 3600))
  (format t "@@ relays:     ~a~%" *relays*)
  (if *allow*
      (format t "@@ allowlist:  ~{~a~^, ~}~%" (mapcar (lambda (h) (subseq h 0 12)) *allow*))
      (format t "@@ allowlist:  (empty) — no NOSTR_ALLOW; only one-time codes admit clients.~%"))
  (format t "@@ login-link: sbcl --script login-link.lisp <npub|email> [ttl]  (DMs a code)~%")
  (finish-output)
  (cl-nostr.pool:pool-subscribe
   pool
   ;; :limit caps the initial backlog — this box pubkey has days of old gift-wraps on the
   ;; relays; live offers still stream after EOSE.  The pool now keepalives + reconnects, so
   ;; the subscription no longer dies on an idle relay drop.
   (list (cl-nostr.filter:make-filter :kinds '(1059) :tags (list (cons "p" (list box-pub)))
                                      :limit 20))
   :on-event
   (lambda (wrap relay)
     (declare (ignore relay))
     (handler-case
         (multiple-value-bind (payload phone-pub) (cl-nostr.nip59:unwrap-giftwrap kp wrap)
           (multiple-value-bind (offer-sdp code) (parse-offer payload)
             (cond
               ((and (stringp offer-sdp) (search "m=application" offer-sdp))   ; a data-channel offer
                ;; a valid one-time code OR an allowlisted signer authorizes the connection
                (let* ((cstatus (code-status code))
                       ;; Three ways in, with deliberately different lifetimes:
                       ;;   allowlist — the npub this box was started for.  Always authorised.
                       ;;   code      — a one-time magic link.  Valid for its own TTL.
                       ;;   device    — a browser we enrolled after it came in on a valid code.
                       ;;               Authorised for *DEVICE-TTL* (~24h) and renewed by use, so
                       ;;               an active terminal keeps working and an idle one lapses.
                       (via (cond ((eq cstatus :ok) "code")
                                  ((authorized-p phone-pub) "allowlist")
                                  ((device-enrolled-p phone-pub) "device")
                                  (t nil))))
                  (cond
                    ((null via)
                     (format t "~&@@ DENIED ~a... — code:~(~a~), not on the allowlist~%"
                             (subseq phone-pub 0 8) cstatus)
                     (finish-output))
                    (t
                     (format t "~&@@ offer from ~a... (via ~a) -> answering~%" (subseq phone-pub 0 8) via)
                     ;; remember this terminal, and renew it on every admitted connection: use
                     ;; keeps a device alive, disuse lets it expire
                     (enrol-device phone-pub)
                     (finish-output)
                     (let* ((answer (process-offer offer-sdp))
                            ;; RENEW: a client that authenticated with a valid code gets a fresh
                            ;; one back with the answer, so simply reconnecting before it expires
                            ;; keeps the credential alive and a dropped session never needs a new
                            ;; magic link.  Renewal rides the exchange that already proved who they
                            ;; are — no new message type, no new crypto.
                            (payload (if (or (eq cstatus :ok) (string= via "device"))
                                         (let ((ht (make-hash-table :test 'equal)))
                                           (setf (gethash "sdp" ht) answer
                                                 (gethash "code" ht)
                                                 (glass-login:mint-token *box-secret* :ttl *link-ttl*))
                                           (com.inuoe.jzon:stringify ht))
                                         answer))
                            (reply  (cl-nostr.nip59:build-giftwrap kp phone-pub payload)))
                       (cl-nostr.pool:pool-publish pool reply)
                       (format t "@@ answer gift-wrapped -> ~a...~%" (subseq phone-pub 0 8))
                       (finish-output))))))
               ;; ---- command DMs ----
               (t
                (multiple-value-bind (verb arg) (parse-command payload)
                  (when verb
                    (let* ((admin (authorized-p phone-pub))     ; the box's own npub
                           (dev   (device-enrolled-p phone-pub))
                           (who   (subseq phone-pub 0 8))
                           (reply
                             (case verb
                               (:link
                                ;; the one command an enrolled device may also use
                                (if (or admin dev)
                                    (let ((token (glass-login:mint-token *box-secret* :ttl *link-ttl*)))
                                      (format nil "Fresh glass login link (expires in ~a min):~%~%~a#box=~a&code=~a"
                                              (max 1 (round *link-ttl* 60)) *link-base* box-npub token))
                                    :denied))
                               (:devices (if admin (describe-devices) :denied))
                               (:revoke  (if admin (revoke-devices arg) :denied))
                               (:help
                                (if (or admin dev)
                                    (format nil "Commands:~%  link~%~@[~a~]"
                                            (and admin "  devices~%  revoke <first-8> | revoke all~%"))
                                    :denied))
                               (t nil))))
                      (cond
                        ((null reply) nil)
                        ((eq reply :denied)
                         (format t "~&@@ ~(~a~) DENIED ~a... (~:[not authorised~;device: management is allowlist-only~])~%"
                                 verb who dev)
                         (finish-output))
                        (t
                         (cl-nostr.pool:pool-publish
                          pool (cl-nostr.nip59:build-giftwrap kp phone-pub reply))
                         (format t "~&@@ ~(~a~) from ~a... (~a) -> replied~%"
                                 verb who (if admin "allowlist" "enrolled device"))
                         (finish-output))))))))))
       (error (e) (format t "~&@@ signal error: ~a~%" e) (finish-output)))))
  (format t "@@ subscribed; waiting for gift-wrapped offers~%")
  (finish-output)
  (loop (sleep 5)))
