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
  (asdf:load-system "webrtc-media/rtc")     ; SRTP audio (G.711 both ways) over the same transport
  (asdf:load-system "glass/audio-stream")   ; the DESKTOP's mix, over a socket — we listen on it
  (asdf:load-system "glass/mic-stream")     ; ...and the phone's microphone, back the other way
  ;; ...and WHO MAY OPEN IT AT ALL.  Same relationship as the two above and the same argument:
  ;; the desktop owns its identity, its enrolled terminals and its login tokens, and this
  ;; process ASKS.  Loading the system gets the client half (ADMISSION-ADMIT and friends) —
  ;; it starts nothing, subscribes to nothing, and listens on nothing.
  (asdf:load-system "glass/nostr")
  (asdf:load-system "cl-nostr"))
(load (merge-pathnames "glass-capture.lisp" (or *load-pathname* *default-pathname-defaults*)))
;; the video profiles + the control channel that switches between them mid-session
(load (merge-pathnames "video-profiles.lisp" (or *load-pathname* *default-pathname-defaults*)))

(in-package #:webrtc-data)

(defparameter *glass-host* (or (uiop:getenv "GLASS_HOST") "127.0.0.1")
  "Where the desktop is, in either form.

A hostname beside GLASS_PORT — `127.0.0.1', which is what it has always been and still is by
default — or a SOCKET FILE: `unix:/home/claude/.glass/run/seat-0.rfb', or a bare absolute path.

The second form is worth having because 127.0.0.1 IS NOT A BOUNDARY: every process of every uid
on the box can open a loopback port, so `the gateway and the desktop are both on this machine'
was the whole of the access control on the screen, the mix, the microphone and admission.  A
socket file at mode 0600 is owner-only, decided by the kernel on connect(), and the desktop can
additionally ask WHO connected (SO_PEERCRED) — which is this gateway, by pid, with no key
material anywhere.  Nothing in glass or here changes what a TCP configuration does.")
(defparameter *glass-port* (or (ignore-errors (parse-integer (uiop:getenv "GLASS_PORT"))) 5900))

(defparameter *glass-path*
  (multiple-value-bind (kind host port path) (glass:parse-endpoint *glass-host* *glass-port*)
    (declare (ignore host port))
    (and (eq kind :unix) path))
  "The desktop's RFB SOCKET FILE, or NIL when GLASS_HOST names a port.")

(defun glass-endpoint (env type port)
  "Where one of the desktop's other three sockets is, as a HOST for GLASS:OPEN-CONNECTION.

ENV (GLASS_AUDIO_HOST and friends) wins if it is set — an operator who has put the sockets
somewhere unusual must be able to say so.  Otherwise it FOLLOWS THE SCREEN, which is what it has
always done and the only thing that keeps four endpoints from drifting apart in two files:

  a port -> the same host, PORT beside it        (5903 -> 5913 / 5914 / 5915, unchanged)
  a path -> the name beside it in the same directory  (seat-0.rfb -> seat-0.audio / .mic / .admit)

GLASS:SOCKET-SIBLING is that second derivation, and it lives in glass rather than here for the
reason both ends of glass-audio/1 already do: a convention with a copy on each side of the wire
is a convention that drifts."
  (declare (ignorable port))
  (let ((e (uiop:getenv env)))
    (cond ((and e (plusp (length e))) e)
          (*glass-path* (format nil "unix:~a" (glass:socket-sibling *glass-path* type)))
          (t *glass-host*))))
(defparameter *relays*
  (let ((e (uiop:getenv "NOSTR_RELAYS")))
    (if e (remove "" (uiop:split-string e :separator ",") :test #'string=)
        '("wss://relay.damus.io" "wss://nos.lol" "wss://relay.primal.net"))))
;; The box's identity.  REQUIRED — there is deliberately no fallback.
;;
;; There used to be one: "a fixed secret so the box's npub is stable (bake it into the page),
;; NOSTR_SEC overrides".  A dev convenience meant to be overridden, which never was — so this
;; gateway ran for months on a secret committed to a PUBLIC repo.  That is not merely an identity
;; leak, because the same secret is the HMAC key for login tokens (login-token.lisp): anyone who
;; read the repo could mint a code, and a valid code authorises INDEPENDENTLY of the allowlist and
;; then enrols the caller as a device for 24h.  Full desktop access, from a git clone.
;;
;; So it refuses, the way publish.lisp already refuses without a site key.  Note the consequence
;; and accept it: gw-keepalive.sh respawns on exit, so a missing NOSTR_SEC is a restart loop that
;; prints this message every three seconds.  That is the correct failure — a box with no identity
;; of its own must not serve, and a loud loop is easier to diagnose than a gateway quietly running
;; as somebody else.
(defparameter *box-secret*
  (let ((s (uiop:getenv "NOSTR_SEC")))
    (unless (and s (= (length s) 64) (every (lambda (c) (digit-char-p c 16)) s))
      (format *error-output*
              "~&@@ FATAL: NOSTR_SEC unset or not 64 hex chars.~@
                 @@ This box has no identity of its own and will not serve.~@
                 @@   openssl rand -hex 32   -> export NOSTR_SEC=... in gw-keepalive.sh~@
                 @@ Rotating it changes the box npub: every issued login link and every enrolled~@
                 @@ device is invalidated, and the client's baked fallback pubkey needs updating.~%")
      (finish-output *error-output*)
      (sb-ext:exit :code 2))
    s))

;; ---- pubkey auth: NOSTR_ALLOW is the DESKTOP's list now ----------------------
;; The allowlist, the enrolment store and the login-token key all moved to glass with the command
;; surface, and admission moved with them: this process no longer decides who may open the desktop,
;; it ASKS the desktop.  See ASK-ADMISSION below for what that costs and what it buys.
;;
;; NOSTR_ALLOW is read by the desktop launcher instead (GLASS_NOSTR_ALLOW falls back to it, so a
;; launcher that already exports it needs no change) — and there it can be re-read at run time,
;; where here it was resolved once at start inside IGNORE-ERRORS and failed open-to-empty on a
;; transient DNS failure.

;; ---- the DM command surface is NOT HERE ANY MORE -----------------------------
;; `link', `devices', `revoke' and `help' used to be answered by this file.  They are answered by
;; the DESKTOP now — glass's :glass/nostr system, src/nostr.lisp — for the same reason the audio
;; mixer is the desktop's and not this file's: WHO MAY OPEN THIS DESKTOP is a property of the
;; desktop, not of whichever wire somebody arrived on.  Three costs made it worth moving:
;;
;;   * THE DIAGNOSTIC CHANNEL DIED WITH THE THING BEING DIAGNOSED.  gw-keepalive.sh restarts this
;;     process on every config change and respawns it on every crash, and a missing NOSTR_SEC is a
;;     deliberate crashloop — so in exactly the situation where somebody would DM the box to ask
;;     what is wrong, nothing was listening.  The desktop stays up for days.
;;   * IT DID NOT SURVIVE A SECOND TRANSPORT.  The LAN gateway.lisp path, a native client, or a
;;     second gateway would each have needed the box secret and its own copy of the enrolment
;;     store: two writers to one file synchronised by mtime.
;;   * warp WANTED IT.  warp-channel.lisp's device manager ran in here only because the data did.
;;
;; THIS IS A SWAP AND NOT AN ADDITION.  Both processes subscribe to the same box pubkey for the
;; same kind, so if this file went on answering commands every DM would get TWO replies, from two
;; processes, with two different tokens in them.  The halves are disjoint by construction: a
;; command is a DM of 80 characters or fewer, and an SDP offer is thousands.  This file answers
;; offers; the desktop answers commands; neither can see the other's traffic as its own.
;;
;; (LINK-REQUEST-P went with them.  It was dead code — nothing had called it since the command
;; parser replaced it — and leaving a dead command matcher behind in the file that no longer has a
;; command surface is exactly the kind of thing that reads as a live feature a year from now.)

(defun %unix-now () (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0)))

(defparameter *nsite-npub*
  (or (uiop:getenv "NSITE_NPUB")
      "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc"))
;; LOGIN_URL_BASE and LINK_TTL went with the `link' command and with the mint.  The desktop reads
;; both now (GLASS_LOGIN_URL_BASE / GLASS_LOGIN_TTL, each falling back to the old name, so a
;; launcher that already exports them needs no change), and it is the desktop that mints the
;; renewal token riding back with every ANSWER — this process only copies it into the envelope.

;; ---- who may open the desktop: the DESKTOP's answer, over a socket -----------
;; The enrolment store used to be here — a hash table, a file, an mtime check and a lock — and it
;; is glass's now (:glass/nostr, glass/src/nostr.lisp).  This process keeps NO copy of it, on
;; purpose: a second copy is a second writer to a file synchronised by mtime, which is exactly the
;; arrangement that stops working the moment there are two transports.
;;
;; So one call replaces all of it.  ADMISSION-ADMIT hands the desktop a pubkey and whatever code
;; came in the offer envelope, and the desktop decides (code / allowlist / device, first match),
;; enrols or renews the terminal, and mints the renewal token that rides back with the answer —
;; one round trip on loopback, once per offer.
;;
;; IT FAILS CLOSED, and that is a decision worth writing down rather than a default.
;;
;; The alternative would be to keep a local store as a fallback and log loudly when it is used.
;; It is rejected because THE DESKTOP IS ALREADY A HARD DEPENDENCY OF THIS PROCESS, and demonstrably
;; so: RUN-SESSION's channel callback opens (GLASS-CONNECT) with no IGNORE-ERRORS around it, so a
;; session admitted while the desktop is down dies the instant its data channel opens.  Everything
;; a peer connects FOR — the screen on :5903, the mix on :5913, the microphone on :5914 — is that
;; process.  Admitting somebody to a desktop that is not there does not give them access; it gives
;; them a session that fails a second later, with a denial that never happened to explain it.
;;
;; So the fallback would buy nothing real, and it would cost the whole point of the move: a second
;; store, drifting, with two writers.  Fail closed, count it, and say so in a line that names the
;; port — because "no answer" and "no" arrive differently on this protocol, which is the property
;; that makes a closed failure diagnosable instead of mysterious.
;;
;; The one case it genuinely costs: a desktop running WITHOUT :glass/nostr answers nothing, and
;; then nobody can connect at all.  That is the same posture as a gateway with no NOSTR_SEC, which
;; already crashloops rather than serve as nobody, and it is visible in one line at startup.

(defparameter *admission-port* (or (ignore-errors (parse-integer (uiop:getenv "GLASS_ADMISSION_PORT")))
                                   5915)
  "Where the desktop answers admission questions.  Beside the screen by the same convention the
audio ports follow: 5903 -> 5913 mix out, 5914 microphone in, 5915 who may open any of it.")
(defparameter *admission-host* (glass-endpoint "GLASS_ADMISSION_HOST" "admit" *admission-port*)
  "...and on which host, or in which socket file.  A socket file is worth most HERE: this is the
question `may this person open the desktop', and on a loopback port the qualification to ask it —
including to ask it as somebody else — was a process on this machine.")

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

;; What the desktop last told us, so the stats file and the monitor still have the number they had
;; when this process owned the store.  A COUNT and not a copy: it is read from the admission reply
;; and never consulted for a decision.
(defvar *devices-known* 0)
(defvar *admission-refusals* 0 "Offers refused because the desktop could not be asked.")

(defun ask-admission (pubkey code)
  "Ask the desktop whether PUBKEY, holding CODE, may connect.  Returns (values VIA TOKEN EXPIRES):

  VIA      :code / :allowlist / :device, or NIL — and NIL is the only thing this function's caller
           is allowed to act on, whether the desktop said no or said nothing at all.
  TOKEN    the renewal code to put in the answer envelope, or NIL.
  EXPIRES  when the desktop says this peer's ENROLMENT runs out, unix, or NIL from a desktop that
           does not send one.  It rides the same envelope for the same reason the token does — the
           browser has no other channel to learn it on, because a DENIAL IS ANSWERED WITH SILENCE.
           Without it a client holding a lapsed device key can only offer into the dark and
           conclude by timeout; with it, its next cold load shows the ways back in immediately and
           still offers, because a prediction must never pre-empt a working credential.

           COPIED, NOT COMPUTED.  This process does not know *ENROLMENT-TTL*, does not hold the
           store, and must not guess: the desktop decides and this repeats what it said.

FAILS CLOSED.  A service that cannot be reached refuses the offer and says so loudly, naming the
port, because a silent refusal here would be diagnosed for an hour in the wrong process."
  (multiple-value-bind (via token plist)
      (glass:admission-admit pubkey code :host *admission-host* :port *admission-port*)
    (let ((n (and plist (ignore-errors (parse-integer (getf plist :devices))))))
      (when n (setf *devices-known* n)))
    (when (eq token :unreachable)
      (incf *admission-refusals*)
      (setf *last-error* (format nil "admission service ~a unreachable"
                                (glass:endpoint-string :host *admission-host* :port *admission-port*)))
      (format t "~&@@ ADMISSION UNREACHABLE at ~a — refusing ~a... (FAIL CLOSED).~@
                 @@   The desktop owns the enrolment store; this gateway keeps no copy on purpose.~@
                 @@   Start it there:  (glass:start-session-nostr)  — or load :glass/nostr in the~@
                 @@   desktop launcher.  Nothing this peer wants (screen, audio, mic) is up either.~%"
              (glass:endpoint-string :host *admission-host* :port *admission-port*)
              (subseq pubkey 0 8))
      (finish-output))
    ;; ---- and one top-up, for the allowlist only ------------------------------------------------
    ;; ADMIT-PEER mints a renewal for :code and :device and deliberately not for :allowlist — "an
    ;; owner has a signer and does not need a bearer credential pushed at them".  That is true of
    ;; the OWNER and false of the BROWSER they are sitting in front of, and the gap is what sends
    ;; somebody back to their signer on every cold load:
    ;;
    ;;   the browser signs offers with a DEVICE key it generates and keeps in localStorage; the
    ;;   signer signs as the owner's real npub.  An allowlist admission therefore enrols the NPUB
    ;;   — which the browser will never present again, because the next load has no signer in it
    ;;   unless somebody taps for one.  The device key stays unenrolled, the enrolment it needed
    ;;   was granted to a pubkey it does not hold, and the whole exchange leaves it exactly where
    ;;   it started.
    ;;
    ;; A login token closes it because IT IS NOT BOUND TO A PUBKEY: the MAC is over
    ;; "glass-login|nonce|exp" and nothing else (glass's %TOKEN-MAC), so it is a bearer credential
    ;; the browser can present under its OWN device key on the next load — where it is admitted
    ;; :code and the device key is enrolled for *ENROLMENT-TTL*, renewed by use from then on.  So
    ;; one signature buys a durable terminal, which is what signing in is supposed to mean.
    ;;
    ;; MINTED ON THE PEER'S AUTHORITY and not the device's, because the peer's pubkey is the only
    ;; one this process has ever seen — the device key is never on the wire — and `mint' is
    ;; allowlist-or-enrolled, which an admitted allowlist peer is by construction.
    ;;
    ;; GUARDED, and NIL-safe: ADMISSION-MINT never signals and answers NIL when refused or
    ;; unreachable, IGNORE-ERRORS covers the rest, and a NIL leaves TOKEN exactly as ADMIT-PEER
    ;; left it — i.e. today's behaviour.  This is a supervised process; a new failure mode here is
    ;; a crashloop, not a missing feature.  It costs one extra loopback round trip on allowlist
    ;; admissions only, which are the owner's own logins and rare.
    (when (and (eq via :allowlist) (not (stringp token)))
      (let ((minted (ignore-errors
                     (glass:admission-mint pubkey :host *admission-host* :port *admission-port*))))
        (when (stringp minted)
          (setf token minted)
          (format t "~&@@ allowlist ~a... — minted a device credential to ride the answer~%"
                  (subseq pubkey 0 8))
          (finish-output))))
    ;; PARSED HERE AND NOWHERE ELSE, and NIL-safe both ways: an older desktop sends no `expires' and
    ;; a garbled one sends something that is not a number.  Both answer NIL, the envelope leaves the
    ;; field out, and the client falls back to the heuristic it had before this existed.
    (values via (and (stringp token) token)
            (and plist (ignore-errors (parse-integer (getf plist :expires)))))))

(defun parse-offer (payload)
  "An offer PAYLOAD is either a {\"sdp\",\"code\"} JSON envelope or a bare SDP string.
Return (values SDP CODE).  (Uses IF, not OR: OR would keep only the primary value and
silently drop CODE.)"
  (let ((j (ignore-errors (com.inuoe.jzon:parse payload))))
    (if (and (hash-table-p j) (gethash "sdp" j))
        (values (gethash "sdp" j) (gethash "code" j))
        (values payload nil))))

(defun glass-connect ()
  ;; GLASS:OPEN-CONNECTION takes the endpoint in either form and sets TCP_NODELAY where there is
  ;; a Nagle to disable (there is none on a socket file, and it ignores the ENOPROTOOPT).  No
  ;; Nagle on the tiny FBUR/input path is the same reason it always was.
  (values (glass:open-connection :host *glass-host* :port *glass-port*)))

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
;; VIDEO_TARGET_KBS is not only a rate: the sender paces a big frame's packets at that rate, and
;; the pacing sleeps in the encode loop — so it also bounds how often the screen is looked at at
;; all.  Set too low, a scroll is answered by fewer, larger jumps and the viewer falls behind.
;; VIDEO_MAX_FRAME_KB bounds a SINGLE frame (latency, not average rate); macroblocks that do not
;; fit are carried into the next one.  VIDEO_CLEANUP_MS is how long the screen must be quiet
;; before coarsely-coded macroblocks are re-coded at VIDEO_QI.
(defparameter *video-max-frame-kb* (or (ignore-errors (parse-integer (uiop:getenv "VIDEO_MAX_FRAME_KB"))) 32))
(defparameter *video-cleanup-ms* (or (ignore-errors (parse-integer (uiop:getenv "VIDEO_CLEANUP_MS"))) 700))

;; ---- the warp channel: the device manager, on a third data channel ------------
;; Loaded HERE and not at the top because it reads this file's device store and this file's
;; allowlist predicate, and putting it after their definitions is what keeps the load silent.
;;
;; It is INERT unless WARP_CHANNEL is set: with the variable unset the warp systems are never
;; loaded, no projection is built and no thread is started, and WARP-SID-P answers NIL from a
;; single comparison — so the one branch it adds to the session dispatch below cannot be taken.
;; See warp-channel.lisp's header for the whole of the argument.
;;
;; GUARDED, unlike the VIDEO-PROFILES load above it, and for a reason that is about the
;; supervisor rather than about this feature: gw-keepalive.sh respawns the gateway on exit, so
;; an unguarded failure here is not a missing terminal list — it is a crashloop, with no remote
;; desktop at all, until somebody reaches a shell.  A feature nobody has used yet does not get
;; to take the desktop down with it.
;;
;; The fallbacks keep the four names the session dispatch calls, and keep stream 102 CLAIMED.
;; Dropping a frame the phone sends is correct; letting 102 fall through to the RFB branch would
;; hand glass a JSON blob as desktop input (0x7B is not an RFB message type).  The literal 102 is
;; deliberate — +WARP-STREAM-ID+ is exactly what we may not have.
(handler-case
    (load (merge-pathnames "warp-channel.lisp" (or *load-pathname* *default-pathname-defaults*)))
  (error (e)
    (format *error-output* "~&@@ warp: channel unavailable (~a) — serving without it~%" e)
    (finish-output *error-output*)
    (defparameter *warp-channel-enabled* nil)
    (defun warp-sid-p (sid) (eql sid 102))
    (defun warp-on-message (state assoc sid payload pub)
      (declare (ignore assoc sid payload pub))
      state)
    (defun warp-close (state) (declare (ignore state)) nil)))

;; ---- the payload channel: the browser client, on the connection it is the client for ----------
;; Guarded exactly like the warp load above it, and for exactly the same reason: gw-keepalive.sh
;; respawns this process on exit, so an unguarded failure here is not a client that fails to load —
;; it is a crashloop with no remote desktop at all until somebody reaches a shell.
;;
;; The fallbacks keep the four names the session dispatch calls, and keep stream 104 CLAIMED.  The
;; literal 104 is deliberate: +PAYLOAD-STREAM-ID+ is exactly what we may not have.  Letting 104 fall
;; through to the RFB branch would hand glass `{"t":"hello",...}` as desktop input.
;;
;; INERT unless PAYLOAD_CHANNEL is set: no file is read, no thread is started, and a phone that asks
;; is answered `none` so it can say so and offer Retry.  See payload-channel.lisp.
(handler-case
    (load (merge-pathnames "payload-channel.lisp" (or *load-pathname* *default-pathname-defaults*)))
  (error (e)
    (format *error-output* "~&@@ payload: channel unavailable (~a) — serving without it~%" e)
    (finish-output *error-output*)
    (defparameter *payload-channel-enabled* nil)
    (defun payload-sid-p (sid) (eql sid 104))
    (defun payload-on-message (state assoc sid payload pub)
      (declare (ignore assoc sid payload pub))
      state)
    (defun payload-close (state) (declare (ignore state)) nil)))

;;; ---- one live session per terminal ------------------------------------------
;; A phone never says goodbye.  It locks its screen, changes network, or just reloads the page and
;; offers again — and nothing in WebRTC tells the answerer the old session died.  Sessions used to run
;; to their full DURATION regardless, so every reconnect STACKED another live one: another TURN
;; allocation (coturn enforces a per-user quota over a finite relay-port range), another RFB
;; connection to glass, and another VP8 encoder pumping frames at a peer that stopped listening.
;; Three reconnects in, we are competing with ourselves for the bandwidth we are trying to measure.
;;
;; So: at most one session per terminal, enforced two ways.  A new offer retires that pubkey's
;; previous session before answering, and every session also dies on its own once the peer goes quiet
;; — which is the case a registry cannot catch, the phone that leaves and never comes back.
;;
;; A DUPLICATE OFFER IS NOT A RECONNECT, and telling them apart is what makes any of this safe.  We
;; subscribe to three relays, so one published offer reaches us three-plus times; retiring on each
;; copy closes the very agent the phone is completing checks against, and the connection dies with
;; "ice failed / no pair" while the box logs a perfectly healthy answer.  The ICE ufrag is the
;; discriminator: it is minted per PeerConnection, so copies of one offer share it and a genuine new
;; offer never does.  Same ufrag => re-send the SAME answer and touch nothing, which is also the
;; right response to a phone that simply missed the first one.

(defstruct (sess (:conc-name sess-)) ufrag agent answer (at 0))

(defvar *live* (make-hash-table :test 'equal))     ; phone pubkey -> its live SESS
(defvar *live-lock* (bt:make-lock))
(defparameter *peer-silence-limit* 30.0)           ; RFC 7675 consent is 30s; match it

(defun forget-session (pub agent)
  "Drop PUB's registry entry, but only if it is still AGENT — a reconnect may already have replaced it."
  (bt:with-lock-held (*live-lock*)
    (let ((s (gethash pub *live*)))
      (when (and s (eq agent (sess-agent s))) (remhash pub *live*)))))

(defun retire-session (pub &key (why "superseded"))
  "Close PUB's live session, if any.  Closing the ICE agent is what ends it: the session loop's
ALIVE-P sees the agent stopped and unwinds, which is what releases the TURN allocation."
  (let ((old (bt:with-lock-held (*live-lock*)
               (prog1 (gethash pub *live*) (remhash pub *live*)))))
    (when old
      (format t "~&@@ retiring previous session for ~a... (~a)~%" (subseq pub 0 8) why)
      (finish-output)
      (ignore-errors (ice-close (sess-agent old))))))

(defun peer-alive-p (agent)
  "NIL once the agent is closed or the peer has been silent past the consent limit."
  (and (not (ice-agent-stop agent))
       (let ((quiet (ice-silent-secs agent)))
         (or (null quiet) (< quiet *peer-silence-limit*)))))

;; ---- the desktop's sound -----------------------------------------------------
;; What the peer hears is what the DESKTOP is playing, and the desktop is a different process:
;; glass runs one mixer beside its framebuffer, in the image its applications live in, and serves
;; it on a socket (:glass/audio-stream).  A mixer in HERE could only ever carry what this gateway
;; itself decided to play — which is a demo, not the box's sound — and the next listener would
;; build a second one.  So this file is a LISTENER: one connection per session, which is one
;; MIXER-SUBSCRIBE on the far side, which is that peer's own cursor and its own 48k->8k
;; conversion.  Two phones dialed in hear the same desktop and neither advances the other's mix.
;;
;; The tap never blocks the sender: a reader thread fills a small queue, the source thunk pops
;; one frame, and an empty queue is silence — so a desktop that is down, restarting, or simply
;; not running audio costs a quiet stream and nothing else.

(defparameter *audio-port*
  (or (ignore-errors (parse-integer (uiop:getenv "GLASS_AUDIO_PORT"))) 5913)
  "Where the glass desktop serves its mix.  Beside the VNC port by convention (5903 -> 5913).")
(defparameter *audio-host* (glass-endpoint "GLASS_AUDIO_HOST" "audio" *audio-port*)
  "...and on which host, or in which socket file — see GLASS-ENDPOINT.")
(defparameter *mic-port*
  (or (ignore-errors (parse-integer (uiop:getenv "GLASS_MIC_PORT"))) 5914)
  "Where the glass desktop takes a peer's MICROPHONE — the other direction, one port past the mix.

The phone's audio has been decoded on the receive path since webrtc-media grew :ON-RX-PCM, and
until now it was measured for a level meter and dropped on the floor.  It goes to the desktop for
the same reason the mix comes FROM the desktop: what would listen to it — the ear, an application,
anything — lives in the image the desktop's applications live in, and a microphone consumed in
here could only ever be heard by this gateway.")
(defparameter *mic-host* (glass-endpoint "GLASS_MIC_HOST" "mic" *mic-port*)
  "...and on which host, or in which socket file — see GLASS-ENDPOINT.")

(defparameter *audio-gain*
  (or (ignore-errors (let ((e (uiop:getenv "AUDIO_GAIN"))) (and e (float (read-from-string e) 1d0))))
      1.0d0)
  "This listener's gain, applied by the desktop in OUR sink — it changes what this peer hears,
not what the desktop is playing to everyone else.")

(defun %connect-tone-then (tap)
  "880 Hz for 120 ms, then the desktop's mix.

A peer that hears nothing cannot tell 'the desktop is quiet' from 'this stream is not carrying
audio at all', and those want very different debugging.  One beep at the start answers it.  It is
LOCAL to this peer deliberately: playing it into the session mix would beep at every listener for
a connection that is not theirs, and would put a sound on the desktop that the desktop did not
make."
  (let ((intro (reed:make-buffer-source (glass:audio-tone 880 0.12 :rate 8000) :frame-samples 160)))
    (lambda () (or (funcall intro) (glass:tap-next-frame tap)))))

;; ---- route attribution: which route a session used, and how it ended -------------------------
;;
;; THE QUESTION THIS EXISTS TO ANSWER is "do some routes die more often than others", and it was
;; unanswerable — not for want of data, but because the two halves lived apart.  The box knew the
;; selected peer (ICE-AGENT-PEER) and it knew a session had ended ("peer silent 30s" in the log),
;; and nothing ever wrote the two down together, so no amount of grepping could turn a pile of
;; closes into "relay sessions last four minutes and direct ones last an hour".  One record per
;; session with the route AND the ending in it makes that a group-by instead of an investigation.
;;
;; THE CONFOUNDER, stated up front because it will otherwise dominate every number here: from this
;; end, a phone whose screen locked is INDISTINGUISHABLE from a route that broke.  Both are silence
;; and both end as "peer silent 30s".  The client is on a phone, so ordinary backgrounding is by a
;; wide margin the commonest cause of silence, and charging it to whatever route happened to be
;; selected would make relay look terrible on cellular purely because people put their phones down
;; outdoors.  So the client sends a best-effort hint before it goes quiet (see CONTROL-AWAY-P), and
;; a close that follows one is recorded as :AWAY.
;;
;; ITS ABSENCE PROVES NOTHING, and the naming is deliberate about that.  A phone that is genuinely
;; cut off — the exact case we are trying to count — cannot send the hint either.  So the two
;; outcomes are :AWAY (voluntary, excludable) and :SILENT (UNEXPLAINED), never "voluntary" versus
;; "route died".  Any analysis that reads :SILENT as "the route broke" has reintroduced the bug
;; this comment exists to prevent; :SILENT is the CANDIDATE POOL for route failure, not evidence.
(defvar *last-video-stats* nil
  "The most recent video stats, kept so the stats file can be rewritten at session close — when the
video sender has already stopped and will never call ON-STATS again.  Without this the one write
that matters most, the one carrying the finished session's record, would carry no video at all.")
(defparameter *session-log-max* 24)
(defvar *session-log* '() "Most recent session records, newest first.")
(defvar *session-log-lock* (bt:make-lock "session-log"))

(defun note-session (record)
  "Add RECORD to the bounded ring of finished sessions."
  (bt:with-lock-held (*session-log-lock*)
    (push record *session-log*)
    (let ((tail (nthcdr (1- *session-log-max*) *session-log*)))
      (when tail (setf (cdr tail) nil)))))

(defun session-log ()
  (bt:with-lock-held (*session-log-lock*) (copy-list *session-log*)))

(defun stats-plist ()
  "The whole stats file as one form.  Factored out of the video ON-STATS callback because the
session record has to be written at CLOSE, which is after the video sender that used to be the
only caller has stopped.

Note :ICE and not :PATH.  This file already has a :PATH — inside :GLASS, where it means the glass
socket — and a second one meaning an ICE route would make the two impossible to tell apart in the
one place they would both be read."
  (list :video *last-video-stats*
        :sessions-ok *sessions-ok*
        :sessions-failed *sessions-failed*
        :no-relay *no-relay-count*
        :last-error *last-error*
        :devices *devices-known*
        :glass (list :host *glass-host* :port *glass-port* :path *glass-path*)
        :ice (list :sessions (session-log))
        :qi-base *video-qi* :target-kbs *video-target-kbs*))

(defun control-away-p (payload)
  "T if this control message is the client's best-effort \"I am going away\" hint.

Matched as a substring rather than parsed: this runs on the receive thread for every control
message, the hint carries no arguments, and a false positive costs one session recorded as
voluntary — which is the SAFE direction to be wrong, because the failure mode we are protecting
is over-counting route deaths, not under-counting them."
  (handler-case
      (let ((s (if (stringp payload) payload (map 'string #'code-char (as-u8vec payload)))))
        (and (search "\"away\"" s) t))
    (error () nil)))

(defun session-record (agent &key established-at away err)
  "One session as a plist: the route it used AND how it ended, in the same form.

CAUSE is the single most important field and it is ordered most-specific-first:
  :NEVER-SELECTED  ICE never picked a pair — an establishment failure, no route to blame.
  :ERROR           the session threw (the string is in :ERR).
  :AWAY            the client said it was going away: VOLUNTARY, exclude from route health.
  :SILENT          the peer went quiet past the consent limit with NO hint.  UNEXPLAINED.
  :CLOSED          ended without any of the above (ran its duration, or a clean teardown)."
  (let* ((now (get-internal-real-time))
         (quiet (ice-silent-secs agent))
         (life (when established-at
                 (/ (float (- now established-at)) internal-time-units-per-second)))
         (cause (cond ((null (ice-agent-selected-at agent)) :never-selected)
                      (err :error)
                      (away :away)
                      ((and quiet (>= quiet *peer-silence-limit*)) :silent)
                      (t :closed))))
    (list :at (get-universal-time)
          :outcome (if established-at :ok :failed)
          ;; the group-by key: "relay/relay", "direct/srflx", … or NIL when nothing was selected
          :route (ice-route-label agent (ice-agent-selected-first agent))
          ;; and where it ENDED, which differs from :ROUTE exactly when the peer re-paired
          :route-end (ice-route-label agent)
          :route-changes (ice-agent-route-changes agent)
          ;; what the peer said it could be reached at — the other half of attributing a failure
          :offered (ice-offered-counts agent)
          :select-s (let ((s (ice-selection-secs agent))) (when s (float s 1.0)))
          :life-s (when life (float life 1.0))
          :cause cause
          ;; T only when the hint actually arrived.  NIL is NOT evidence of the opposite.
          :hinted (and away t)
          :silent-s (when quiet (float quiet 1.0))
          :err err)))

(defun run-session (conn agent &key pub)
  "Drive DTLS, run the data channel, and bridge it to glass once the channel opens.
Closes AGENT on exit so its TURN allocation is released (not leaked for ~600s)."
  (let ((glass nil) (audio-stop nil) (video-stop nil) (cap nil) (tap nil) (mic nil)
        ;; This peer's warp channel, or NIL — which is what it stays unless the phone sends on
        ;; stream 102, which it only does if somebody opens the panel.
        (warp nil)
        ;; ...and its payload transfer, which is NIL until the phone's shell says hello on 104.
        (payload-ch nil)
        ;; ---- what the session record is built from, all three session-local on purpose: a
        ;; global would attribute one phone's ending to another phone's route the moment two
        ;; terminals overlap, which is the exact class of mistake this whole record exists to fix.
        (established-at nil)                    ; when the data channel opened, or NIL if it never did
        (away nil)                              ; the client's "going away" hint, if it arrived
        (err nil))                              ; the error that ended the session, as a short string
    (unwind-protect
         (handler-case
             (progn
               (webrtc-dtls-run conn)
               ;; audio rides the same transport: derive SRTP keys from the DTLS session, then
               ;; send this peer its own cursor on the DESKTOP's mix + report what it sends back.
               ;; PRIME 2 frames of queue: this process also encodes video, so its sender thread
               ;; gets preempted, and 40 ms of cushion is cheaper than a gap every time it does.
               (setf tap (ignore-errors
                          (glass:make-audio-tap
                           :host *audio-host* :port *audio-port*
                           :name (if pub (subseq pub 0 8) "peer")
                           :rate 8000 :frame-samples 160 :prime 2 :gain *audio-gain*
                           :log (lambda (m) (format *error-output* "~&[audio] ~a~%" m)))))
               ;; ...and the microphone the other way.  MIC-SEND is called from ON-RX-PCM, which
               ;; runs on the thread that decrypts every inbound packet — audio AND video — so it
               ;; may not block for anything: it copies into a bounded ring and returns, a writer
               ;; thread owns the socket, and a desktop that is down, restarting, or simply not
               ;; reading costs dropped frames and nothing else.  Made even when the desktop has
               ;; no ear: the microphone arriving is not this file's business to have an opinion
               ;; about, and a port with nobody behind it is exactly the silence case above.
               (setf mic (ignore-errors
                          (glass:make-mic-sender
                           :host *mic-host* :port *mic-port*
                           :name (if pub (subseq pub 0 8) "peer")
                           :rate 8000 :frame-samples 160
                           :log (lambda (m) (format *error-output* "~&[mic] ~a~%" m)))))
               (multiple-value-bind (astop ctx)
                   (ignore-errors
                     (webrtc-media:start-audio
                      agent (dtls-conn-session conn)
                      :source (and tap (%connect-tone-then tap))
                      ;; the samples first — the meter is derived from the same frame anyway
                      :on-rx-pcm (and mic (glass:mic-feed mic))
                      :on-rx-level (let ((n 0))
                                     (lambda (lvl)
                                       (when (zerop (mod (incf n) 50))   ; ~1x/s
                                         (format *error-output* "~&[audio] rx level ~,2f (mic from browser)~%" lvl)
                                         (finish-output *error-output*))))
                      :log (lambda (m) (format *error-output* "~&[audio] ~a~%" m))))
                 (setf audio-stop astop)
                 (format *error-output* "~&[gw-nostr] audio started — ~a -> browser, browser mic -> ~a~%"
                         (if tap
                             (format nil "desktop mix from ~a @8k"
                                     (glass:endpoint-string :host *audio-host* :port *audio-port*))
                             "NO TAP (silence)")
                         (if mic (glass:endpoint-string :host *mic-host* :port *mic-port*)
                             "NOWHERE (dropped)"))
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
                            :max-frame-kb *video-max-frame-kb* :cleanup-ms *video-cleanup-ms*
                            ;; RESOLUTION FOLLOWS DAMAGE.  The sender publishes the divisor it
                            ;; wants (WEBRTC-MEDIA:VIDEO-SCALE, decided from the damage its own
                            ;; encoder measured) and the capture box-filters the desktop down to
                            ;; it.  A source that ignored this would simply never change size,
                            ;; which is the behaviour this had before.
                            :source (when cap
                                      (lambda ()
                                        (capture-take cap :scale (webrtc-media:video-scale))))
                            :on-stats (lambda (v)
                                        (setf *last-video-stats* v)
                                        (write-stats (stats-plist)))
                            :log (lambda (m)
                                   (let ((cs (and cap (capture-stats cap))))
                                     (format *error-output* "~&[video] ~a~@[ | glass wait ~,0fms conv ~,0fms upd ~a px ~a copies ~a rc ~a scale 1/~a (~a downscales)~]~%"
                                             m (and cs (getf cs :wait-ms)) (and cs (getf cs :convert-ms))
                                             (and cs (getf cs :updates)) (and cs (getf cs :px)) (and cs (getf cs :copies)) (and cs (getf cs :reconnects))
                                             (and cs (getf cs :scale)) (and cs (getf cs :scaled))))))))
                   (format *error-output* "~&[gw-nostr] video started — VP8 pt=~a qi=~a fps=~a maxqi=~a target=~aKB/s frame<=~aKB cleanup=~ams backlog-qi=~a/~ax~%"
                           *video-pt* *video-qi* *video-fps* *video-max-qi* *video-target-kbs*
                           *video-max-frame-kb* *video-cleanup-ms*
                           webrtc-media.vp8::*backlog-qi* webrtc-media.vp8::*backlog-x*)))
               (webrtc-serve-datachannel
                conn :duration 3600.0 :alive-p (lambda () (peer-alive-p agent))
                :on-ready
                (lambda (assoc sid)
                  (setf glass (glass-connect) *last-assoc* assoc)
                  (incf *sessions-ok*)
                  ;; The session is ESTABLISHED here, and this is the clock the survival number is
                  ;; measured from: not the offer (which includes however long ICE spent choosing)
                  ;; but the moment the link actually started working.
                  (setf established-at (get-internal-real-time))
                  (format *error-output* "~&[gw-nostr] channel open -> glass ~a~%"
                          (glass:endpoint-string :host *glass-host* :port *glass-port*))
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
                    ((control-sid-p sid)
                     ;; Read the going-away hint off the control stream before handing the message
                     ;; on, so the hint costs one substring search and needs no change to the
                     ;; control protocol's own handler.  Recorded as a TIME, not a flag, so a
                     ;; later "it came back" could be told apart from "it never did".
                     (when (control-away-p payload) (setf away (get-internal-real-time)))
                     (handle-control-message assoc sid payload))
                    ;; The phone's THIRD channel (stream 102) is warp: the enrolled-terminal list
                    ;; as a delta stream, and the commands on it.  A negotiated channel has no
                    ;; handshake, so the first message IS the open.
                    ;;
                    ;; This clause claims stream 102 WHETHER OR NOT WARP_CHANNEL IS SET, on
                    ;; purpose: with the feature off WARP-ON-MESSAGE drops the bytes, and dropping
                    ;; them is the point — gating the clause instead would let a phone that has the
                    ;; panel, talking to a box that does not have the channel, fall through to the
                    ;; RFB branch below and hand glass a JSON object as desktop input.
                    ;; Streams 0 and 100 — the only two any deployed client uses — are matched
                    ;; before and after this line exactly as they were.
                    ((warp-sid-p sid) (setf warp (warp-on-message warp assoc sid payload pub)))
                    ;; The phone's FOURTH channel (stream 104) is the client payload: the shell on
                    ;; nsite asks for the rest of itself, and we push it from disk.  Claimed
                    ;; whether or not PAYLOAD_CHANNEL is set, for the same reason 102 is — see
                    ;; PAYLOAD-SID-P.  With the feature off the phone is answered `none`, which is
                    ;; what lets it say so instead of spinning.
                    ((payload-sid-p sid)
                     (setf payload-ch (payload-on-message payload-ch assoc sid payload pub)))
                    ((and glass (plusp (length payload)))
                     (let ((bytes (as-u8vec payload)))
                       ;; in video-primary mode drop FramebufferUpdateRequest (type 3, 10 bytes) so
                       ;; glass sends no pixels over SCTP; everything else (input) passes through
                       (if (and *video-primary* (= 10 (length bytes)) (= 3 (aref bytes 0)))
                           nil
                           (progn
                             ;; AND TELL THE VIDEO SENDER, which is otherwise looking at a screen
                             ;; that has not changed yet.  Its idle passes — sharpening what was
                             ;; sent coarse, draining what did not fit — start once the desktop has
                             ;; been quiet a moment, and a desktop is perfectly quiet for the whole
                             ;; round trip between a click arriving here and the repaint coming
                             ;; back.  That is exactly the window in which starting one puts it in
                             ;; front of the answer.  A keystroke is the earliest warning the box
                             ;; can have that the picture is about to change, and it is already in
                             ;; our hands.
                             (setf webrtc-media:*video-input-at* (get-internal-real-time))
                             ;; ... and WHERE, when the event says so.  These bytes are on their
                             ;; way to the desktop either way; this only reads them, and only for
                             ;; the last PointerEvent in the buffer, so the sender can know where
                             ;; the user's attention is without anything extra crossing the link.
                             ;; What reads it is WEBRTC-MEDIA:*CURSOR-PRIORITY*, which is off by
                             ;; default — see its docstring for what happened when it was on.
                             (webrtc-media:note-rfb-input bytes)
                             (sb-bsd-sockets:socket-send glass bytes (length bytes))))))))))
           (error (e)
             (incf *sessions-failed*)
             (setf *last-error* (let ((s (princ-to-string e)))
                                  (subseq s 0 (min 72 (length s)))))
             (setf err *last-error*)
             (format *error-output* "~&[gw-nostr] session error: ~a~%" e)))
      (let ((quiet (ice-silent-secs agent)))
        (when (and quiet (>= quiet *peer-silence-limit*))
          (format *error-output* "~&[gw-nostr] peer silent ~,0fs — closing session~%" quiet)))
      ;; THE ROUTE AND THE ENDING, WRITTEN DOWN TOGETHER.  Everything above this line has already
      ;; been logged separately at one time or another; what was missing was one record carrying
      ;; both, which is what makes "which routes die frequently" a group-by.  Written to the log
      ;; AND to the stats file, and unconditionally: a session that failed to establish is the
      ;; one whose record is most worth having, and it is exactly the one an "on success" hook
      ;; would drop.  Best-effort throughout — instrumentation may not be what ends a session.
      (ignore-errors
       (let ((rec (session-record agent :established-at established-at :away away :err err)))
         (note-session rec)
         (format *error-output*
                 "~&[route] ~a ~a — ~a | offered h~a/s~a/r~a | select ~a | life ~a~@[ | changes ~a~]~@[ | silent ~ds~]~%"
                 (or (getf rec :route) "none")
                 (getf rec :outcome) (getf rec :cause)
                 (getf (getf rec :offered) :host) (getf (getf rec :offered) :srflx)
                 (getf (getf rec :offered) :relay)
                 (let ((s (getf rec :select-s))) (if s (format nil "~,1fs" s) "never"))
                 (let ((s (getf rec :life-s))) (if s (format nil "~,0fs" s) "-"))
                 (let ((n (getf rec :route-changes))) (when (and n (plusp n)) n))
                 (let ((s (getf rec :silent-s))) (when s (round s))))
         (finish-output *error-output*)
         ;; and into the stats file, which the video callback can no longer do: its sender is
         ;; stopped by the time this runs.
         (write-stats (stats-plist))))
      (when pub (forget-session pub agent))
      ;; This peer's warp consumer dies with the session, deliberately: its STREAM is its memory of
      ;; what the far end holds, and a phone that comes back is a phone holding nothing.  Keeping it
      ;; would hand the returning peer somebody else's high-water mark, which is rule 8's
      ;; late-joiner bug with the roles reversed.  NIL when the channel was never opened.
      (when warp (setf warp (warp-close warp)))
      ;; ...and stop a payload transfer that is still in flight.  A phone that drops mid-transfer
      ;; leaves a thread pushing 16 KB at a time into an association nobody is reading; the sender
      ;; checks this between chunks and unwinds.
      (when payload-ch (setf payload-ch (payload-close payload-ch)))
      (when cap (ignore-errors (capture-stop cap)))
      (when video-stop (ignore-errors (funcall video-stop)))
      (when audio-stop (ignore-errors (funcall audio-stop)))
      ;; drop this peer's listening cursor (closing the connection is what unsubscribes it on the
      ;; desktop).  The mix itself keeps running — it is the desktop's, not this session's, and
      ;; the next dial-in joins it where it is.
      (when tap
        (format *error-output* "~&[audio] ~a~%" (glass:tap-report tap))
        (ignore-errors (glass:tap-stop tap)))
      ;; and this peer's microphone: closing the connection is what tells the desktop the
      ;; microphone is gone, which is what sends its ear back to whatever it was listening to
      (when mic
        (format *error-output* "~&[mic] ~a~%" (glass:mic-sender-report mic))
        (ignore-errors (glass:mic-sender-stop mic)))
      (when glass (ignore-errors (sb-bsd-sockets:socket-close glass)))
      (ignore-errors (ice-close agent)))))   ; release the TURN allocation + ICE socket


;;; ---- replay defence ----------------------------------------------------------
;; The subscription asks each relay for :limit 20 of the backlog, and the pool reconnects on an idle
;; drop — so every reconnect re-delivers up to 20 old gift-wraps, per relay, indefinitely.  Those are
;; real, correctly-signed, authorised offers from PeerConnections that died hours ago.  Answering them
;; wastes an ICE agent and a TURN allocation each, and — far worse, once sessions supersede — a replay
;; arriving behind a live offer RETIRES THE SESSION THE PHONE IS CURRENTLY CHECKING AGAINST.  The box
;; logs a healthy answer and the phone reports "ice failed / no pair", with nothing connecting the two.
;;
;; Three guards, cheapest first.  The rumor's created_at is the honest clock here: NIP-59 randomises
;; the seal and wrap timestamps to resist correlation, but the rumor keeps real time, and it is inside
;; the signed seal so a relay cannot forge it.
(defvar *seen-wraps* (make-hash-table :test 'equal))
(defvar *seen-lock* (bt:make-lock))
;; 10 minutes, not 3: the real replays are HOURS old, so a wide window kills them just as dead, and
;; the cost of being wrong is asymmetric — too tight and a phone whose clock lags rejects every offer
;; with no way to tell from the far end, which is the failure mode we just spent an afternoon on.
(defparameter *offer-max-age* 600)

(defun wrap-seen-p (id)
  "T if we have already processed wrap ID.  Also the 3-relay fan-out deduplicator."
  (when id
    (bt:with-lock-held (*seen-lock*)
      (prog1 (gethash id *seen-wraps*)
        (when (> (hash-table-count *seen-wraps*) 4096) (clrhash *seen-wraps*))
        (setf (gethash id *seen-wraps*) t)))))

(defun process-offer (offer-sdp &key pub (at 0))
  "Parse an SDP OFFER, run the answerer (srflx + full-agent checks for off-LAN), spawn the
   glass-bridged session, and return the ANSWER SDP.  PUB is the offering terminal, whose previous
   session is retired first — before we allocate, so its relay port is free for reuse."
  (let* ((probe (parse-sdp offer-sdp))
         (ufrag (sdp-ice-ufrag probe))
         (dup (and pub ufrag
                   (let ((s (bt:with-lock-held (*live-lock*) (gethash pub *live*))))
                     (and s (equal ufrag (sess-ufrag s)) s)))))
    (when dup
      (format t "~&@@ duplicate offer from ~a... (ufrag ~a) — re-sending the same answer~%"
              (subseq pub 0 8) ufrag)
      (finish-output)
      (return-from process-offer (sess-answer dup))))
  ;; Supersede only for an offer at least as new as the live one.  Without this a replay retires a
  ;; live session; with it, an out-of-order replay is simply ignored.
  (when pub
    (let ((live (bt:with-lock-held (*live-lock*) (gethash pub *live*))))
      (cond ((null live) nil)
            ((>= at (sess-at live)) (retire-session pub))
            (t (format t "~&@@ ignoring offer older than the live session for ~a... (~a < ~a)~%"
                       (subseq pub 0 8) at (sess-at live))
               (finish-output)
               (return-from process-offer nil)))))
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
    (when pub
      (bt:with-lock-held (*live-lock*)
        (setf (gethash pub *live*)
              (make-sess :ufrag (sdp-ice-ufrag offer) :agent agent :answer answer :at at))))
    (bt:make-thread (lambda () (run-session conn agent :pub pub)) :name "webrtc-session")
    answer))

;;; ---- Nostr signaling loop --------------------------------------------------
(let* ((kp      (cl-nostr.keys:keypair-from-secret *box-secret*))
       (box-pub (cl-nostr.keys:public-hex kp))
       (box-npub (ignore-errors (cl-nostr.bech32:npub-encode (cl-nostr.keys:public-key-of-secret *box-secret*))))
       (pool    (cl-nostr.pool:make-pool *relays*)))
  (format t "~&@@ nostr gateway  (glass ~a)~%"
          (glass:endpoint-string :host *glass-host* :port *glass-port*))
  (format t "@@ box npub:   ~a~%" (or box-npub "(npub encode failed; use hex)"))
  (format t "@@ box pubkey: ~a~%" box-pub)
  (when box-npub
    (format t "@@ share URL:  https://~a.nsite.lol/#~a~%"
            (or (uiop:getenv "NSITE_NPUB")
                "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc")
            box-npub))
  ;; ASK THE DESKTOP WHO IT IS, ONCE, AT STARTUP.  Not because anything here needs the answer —
  ;; every admission asks again — but because this is where "nobody can connect" is diagnosed, and
  ;; a gateway that refuses every offer for an hour without ever having said the service was down
  ;; is the failure mode that makes fail-closed a bad idea.  It is a report, not a gate: the
  ;; gateway starts either way, and the desktop may simply not be up yet.
  (let ((posture (glass:admission-ping :host *admission-host* :port *admission-port*)))
    (if posture
        (progn
          (format t "@@ admission:  ~a — ~a enrolled, ~a allowed, device ttl ~ah~%"
                  (glass:endpoint-string :host *admission-host* :port *admission-port*)
                  (getf posture :devices) (getf posture :allow)
                  (round (or (ignore-errors (parse-integer (getf posture :ttl))) 86400) 3600))
          (setf *devices-known* (or (ignore-errors (parse-integer (getf posture :devices))) 0))
          (unless (equal (string-downcase (getf posture :box)) (string-downcase box-pub))
            ;; A DIFFERENT BOX SECRET ON THE TWO SIDES.  Codes minted there will not verify... they
            ;; will, in fact, verify there and only there — but the npub a link names is OURS, so a
            ;; person would be sent to a box that is not the one holding their credential.  Loud,
            ;; and not fatal, because the desktop is what people are trying to reach.
            (format t "@@ WARNING:   the desktop's box key is ~a, ours is ~a — the secret is~%~
                       @@            SHARED by design; these disagreeing means one of the two~%~
                       @@            launchers has a different NOSTR_SEC.~%"
                    (subseq (or (getf posture :box) "?") 0 12) (subseq box-pub 0 12))))
        (format t "@@ admission:  ~a NOT ANSWERING — every offer will be REFUSED until it is.~%~
                   @@            The desktop owns the enrolment store (:glass/nostr); this~%~
                   @@            gateway keeps no copy.  Nothing a peer wants is up either.~%"
                (glass:endpoint-string :host *admission-host* :port *admission-port*)))
    (finish-output))
  (format t "@@ relays:     ~a~%" *relays*)
  (format t "@@ login-link: sbcl --script login-link.lisp <npub|email> [ttl]  (DMs a code)~%")
  ;; Said out loud, because "the box stopped answering `link'" is otherwise diagnosed here, in the
  ;; process that no longer has the answer.  The DM surface is the DESKTOP's; this process answers
  ;; offers and nothing else.
  (format t "@@ commands:   answered by the DESKTOP (glass :glass/nostr), not by this process~%")
  ;; Printed ONLY when the channel is enabled, so a gateway that is not offering it logs exactly
  ;; what it logged before — the banner is the last place a "changes nothing" claim could leak.
  (when *warp-channel-enabled*
    (format t "@@ warp:       stream ~a, ~a B/pass at ~a Hz (device manager)~%"
            +warp-stream-id+ *warp-budget* *warp-hz*))
  (when *payload-channel-enabled*
    (format t "@@ payload:    stream ~a, ~a (client served from disk, ~a B/chunk)~%"
            +payload-stream-id+ *payload-file* *payload-chunk*))
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
         ;; Guard 1: have we already handled this exact wrap?  Catches both the 3-relay fan-out and
         ;; every backlog re-delivery after a relay reconnect.
         (if (wrap-seen-p (ignore-errors (cl-nostr.event:event-id wrap)))
             nil
         (multiple-value-bind (payload phone-pub rumor-at) (cl-nostr.nip59:unwrap-giftwrap kp wrap)
           (multiple-value-bind (offer-sdp code) (parse-offer payload)
             (cond
               ;; Guard 2: an offer older than *OFFER-MAX-AGE* names a PeerConnection that is long
               ;; gone.  Answering it cannot succeed and can only disturb a live session.
               ((and (stringp offer-sdp) (search "m=application" offer-sdp)
                     (plusp rumor-at)
                     (> (- (%unix-now) rumor-at) *offer-max-age*))
                (format t "~&@@ stale offer from ~a... (~ds old) — ignored~%"
                        (subseq phone-pub 0 8) (- (%unix-now) rumor-at))
                (finish-output))
               ((and (stringp offer-sdp) (search "m=application" offer-sdp))   ; a data-channel offer
                ;; WHO MAY CONNECT IS THE DESKTOP'S ANSWER.  Three ways in, with deliberately
                ;; different lifetimes — a code (a magic link, valid for its own TTL, and it
                ;; authorises independently of the allowlist), the allowlist (permanent), or an
                ;; enrolment (a browser admitted earlier on a code, renewed by use and lapsing
                ;; without it) — and all three are decided over there, in one round trip, along
                ;; with the enrolment and the renewal token.  See ASK-ADMISSION: no answer refuses.
                (multiple-value-bind (via renewal expires) (ask-admission phone-pub code)
                  (cond
                    ((null via)
                     ;; RENEWAL carries the reason here: :absent / :bad / :expired from the desktop,
                     ;; or :unreachable, which ASK-ADMISSION has already said out loud.
                     (format t "~&@@ DENIED ~a... — ~(~a~)~%" (subseq phone-pub 0 8) renewal)
                     (finish-output))
                    (t
                     (format t "~&@@ offer from ~a... (via ~(~a~)) -> answering~%"
                             (subseq phone-pub 0 8) via)
                     (finish-output)
                     (let* ((answer (process-offer offer-sdp :pub phone-pub :at rumor-at))
                            ;; NIL means the offer was ignored (older than the live session) — there
                            ;; is nothing to reply with, and replying NIL would hand the phone a
                            ;; malformed answer.
                            (skip (null answer))
                            ;; RENEW: a client that authenticated with a code, or as an enrolled
                            ;; terminal, gets a fresh one back with the answer, so simply
                            ;; reconnecting before it expires keeps the credential alive and a
                            ;; dropped session never needs a new magic link.  Renewal rides the
                            ;; exchange that already proved who they are — no new message type and
                            ;; no new crypto — and the token was MINTED BY THE DESKTOP, in the same
                            ;; call that admitted them, because the desktop holds the store the
                            ;; credential is a credential against.  An allowlisted owner gets one
                            ;; too, on a second call ASK-ADMISSION makes for exactly that case and
                            ;; explains there — the browser they signed in from holds a device key,
                            ;; not their npub, and without a bearer code it would be back at the
                            ;; signer on the next load.
                            ;; ALWAYS an envelope, and it carries the OFFER'S ICE UFRAG back.  A
                            ;; gift-wrapped answer lives on the relays forever, and the phone's
                            ;; subscription has no since/limit — so on the next connection the relays
                            ;; replay every old answer and the page applies whichever arrives first.
                            ;; Its checks then run against a dead allocation and ICE fails with no
                            ;; pair, while this box logs a perfectly good answer nobody used.  The
                            ;; ufrag is minted per PeerConnection, so echoing it lets the phone tell
                            ;; OUR answer from a ghost of one.  Old backlog answers have no ufrag
                            ;; field at all, which is exactly how they get rejected.
                            (payload (let ((ht (make-hash-table :test 'equal)))
                                       (setf (gethash "sdp" ht) answer
                                             (gethash "ufrag" ht)
                                             (ignore-errors (sdp-ice-ufrag (parse-sdp offer-sdp))))
                                       (when renewal (setf (gethash "code" ht) renewal))
                                       ;; WHEN THIS ENROLMENT RUNS OUT, from the desktop that
                                       ;; decided it.  The client stores it against this box and
                                       ;; can then tell, at its next cold load and before it has
                                       ;; spoken to anybody, whether the credential it is about to
                                       ;; offer is one this box still honours — which a denial,
                                       ;; being silence, can never tell it.  Absent from the
                                       ;; envelope when the desktop did not say, and the client
                                       ;; treats absence as "no better than the guess I had".
                                       (when expires (setf (gethash "expires" ht) expires))
                                       (com.inuoe.jzon:stringify ht)))
                            (reply  (and (not skip)
                                         (cl-nostr.nip59:build-giftwrap kp phone-pub payload
                                                                        :after rumor-at))))
                       (when reply (cl-nostr.pool:pool-publish pool reply))
                       (format t "@@ answer gift-wrapped -> ~a...~%" (subseq phone-pub 0 8))
                       (finish-output))))))
               ;; ---- anything that is not an offer ----
               ;; A command DM lands here, and this file does NOTHING with it: the desktop's
               ;; :glass/nostr bot is subscribed to the same box pubkey for the same kind and is
               ;; the one that answers.  Replying here as well would send every `link' TWO magic
               ;; links, minted by two processes, in two DMs — which is why removing this branch
               ;; was a condition of adding that one and not a separate tidy-up.
               ;;
               ;; It stays a CLAUSE rather than becoming an absent one so the shape of the dispatch
               ;; still says what happens to a DM that is not an offer: nothing, silently, which is
               ;; also what happens to somebody's chatter and to a relay's backlog.
               (t nil)))))
       (error (e) (format t "~&@@ signal error: ~a~%" e) (finish-output)))))
  (format t "@@ subscribed; waiting for gift-wrapped offers~%")
  (finish-output)
  (loop (sleep 5)))
