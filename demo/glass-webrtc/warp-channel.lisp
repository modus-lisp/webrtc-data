;;;; warp-channel.lisp — the device manager, as a warp projection on a third data channel.
;;;;
;;;; ==============================================================================================
;;;; WHAT THIS IS
;;;; ==============================================================================================
;;;;
;;;; The gateway already keeps a set of enrolled terminals, in a file it writes itself
;;;; (`.glass-devices`), and already administers them over gift-wrapped DMs: `devices` lists them,
;;;; `revoke <prefix|all>` drops them, and both are allowlist-only.  That is a command set on a
;;;; type with a real authorization rule, which is exactly what warp is for — so this file gives
;;;; that same set a SECOND surface, on the connection the phone already has, with the
;;;; authorization written once and enforced in the same place.
;;;;
;;;; No bridge, no IPC, no second process: warp runs INSIDE the gateway, over the gateway's own
;;;; enrolments.  It can, because :warp depends on bordeaux-threads and nothing else — no glass,
;;;; no framebuffer, no gesso — which is the whole reason the protocol was lifted out of the glass
;;;; package in the first place.
;;;;
;;;; ==============================================================================================
;;;; WHY ALMOST NOTHING IS IN HERE
;;;; ==============================================================================================
;;;;
;;;; This gateway carries a live session and MAY NOT BE RUN to check anything.  Every line here is
;;;; verified by reading and by nothing else, so the design goal is to have as few of them as
;;;; possible.  Everything that could be tested offline was pushed into warp-dom's channel module
;;;; and is asserted there against a fake transport (warp/t/channel.lisp): the clock, the lock over
;;;; ticks and messages, the send that must not signal, the close that runs on every unwind path,
;;;; the budget, the deferral, the garbage handling, and the owner/guest refusal.
;;;;
;;;; What is left here is the three things that genuinely cannot be: which stream id, which peer,
;;;; and which query.
;;;;
;;;; ==============================================================================================
;;;; OFF UNLESS ASKED, AND INERT WHEN OFF
;;;; ==============================================================================================
;;;;
;;;; WARP_CHANNEL must be set for any of this to do anything.  Unset — the default, and what the
;;;; running gateway has — the warp systems are never loaded, no projection is built, no thread is
;;;; started, nothing is sent, and the startup banner does not mention it.  The one new branch in
;;;; the session's message dispatch matches only stream 102, which no deployed client has ever sent
;;;; on; for streams 0 and 100 the dispatch is what it was, one NIL test earlier.
;;;;
;;;; What that branch is NOT is gated on the flag — see WARP-SID-P.  Disabled has to mean the bytes
;;;; are DROPPED, not that the clause is skipped, because skipping it would let them fall into the
;;;; RFB branch and reach a desktop as input.
;;;;
;;;; That gate is not timidity about the feature.  It is that "prove it changes nothing" is a claim
;;;; someone has to be able to CHECK, and "the code is not loaded" is the only version of it that
;;;; can be checked by looking rather than by running.
;;;;
;;;; ==============================================================================================
;;;; THE STREAM ID
;;;; ==============================================================================================
;;;;
;;;;   rfb      stream 0     DCEP-negotiated by the browser   raw RFB bytes, binary
;;;;   control  stream 100   negotiated: true                 flat JSON, the video ladder
;;;;   warp     stream 102   negotiated: true                 warp's JSON delta frames
;;;;
;;;; 102 and not 101: `control` is 100, and a negotiated channel's id is chosen by the application
;;;; rather than by the DCEP parity rule, so the useful convention here is simply "even, near the
;;;; one that already works".  It is out of reach of the DCEP-allocated ids the browser hands out
;;;; from the bottom, and it will not collide with a third channel that follows the same habit.
;;;;
;;;; A negotiated channel COSTS NOTHING TO OPEN — there is no DCEP handshake, so the browser
;;;; creating it puts zero bytes on the wire.  The gateway therefore learns the channel exists the
;;;; only way it can: a message arrives on 102.  That is the same discipline `control` already
;;;; uses, and it is what makes "the client never opened it" and "the client does not have it"
;;;; indistinguishable and equally free.
;;;;
;;;; ==============================================================================================
;;;; TWO APPS ON IT, AND WHY NOT A SECOND CHANNEL
;;;; ==============================================================================================
;;;;
;;;; There is a second warp app now — warp-files, a Miller-column file browser — and one stream to
;;;; put it on.  The two ways to do that are a channel of its own and a projection id multiplexed
;;;; onto this one, and on paper the channel is the simpler of the two.  It is not available:
;;;;
;;;;   * EVERY DATA CHANNEL HAS TO EXIST BEFORE THE OFFER.  Signalling here is one-shot and
;;;;     non-trickle and nothing in this system renegotiates, so all four channels are created in
;;;;     shell.js before `createOffer`.  The payload may not create one — it says so at the top of
;;;;     payload.js, in the same breath as "it may not assume it is first".
;;;;   * shell.js IS ON NSITE.  So a fifth channel is a publish under a new tag, which invalidates
;;;;     every login link minted against the old one (§8.9), needs the desktop restarted for
;;;;     LOGIN_URL_BASE (§8.8), and is the whole cost §9 exists to avoid.  A projection id costs a
;;;;     file copy and this restart.
;;;;   * AND IT IS WHAT A THIRD APP WOULD WANT ANYWAY.  Stream ids are a fixed resource negotiated
;;;;     once; app ids are not.
;;;;
;;;; So: a client message may carry `a`, the app it is for, and a frame carries `a` back.  THE
;;;; DEVICE MANAGER IS THE APP WITH NO NAME — a message with no `a` routes to it and its frames go
;;;; back unlabelled, so every byte on this channel is what it was before any of this, and a phone
;;;; holding an older payload is a phone that asks for one app and gets it.
;;;;
;;;; The routing itself is NOT in this file.  WARP-DOM:MAKE-MUX is one app id -> one channel, driven
;;;; over a fake transport in warp/t/channel.lisp and over a real browser in warp/t/two-apps.sh,
;;;; because the discipline that governs everything here is that a gateway is a thing we may not
;;;; run.  What is left below is what genuinely cannot be tested from outside: which apps this box
;;;; serves, and where each one's rows come from.
;;;;
;;;; gateway-nostr.lisp IS UNCHANGED BY ANY OF IT.  Its state for this channel was already an opaque
;;;; value it gets from WARP-ON-MESSAGE and hands back to WARP-CLOSE; that value is now a link with
;;;; a mux in it instead of a single channel, and neither the dispatch clause nor the close nor the
;;;; banner had a reason to know.

(in-package #:webrtc-data)

;;; ---- the gate ---------------------------------------------------------------------------

(defparameter *warp-channel-enabled* (and (uiop:getenv "WARP_CHANNEL") t)
  "Whether this gateway offers a warp channel at all.  Off unless WARP_CHANNEL is set.")

(defconstant +warp-stream-id+ 102)

(defun warp-sid-p (sid)
  "T iff SID is the warp stream.

DELIBERATELY NOT GATED ON *WARP-CHANNEL-ENABLED*, and getting that wrong is the one way this could
have hurt the thing it is trying not to touch.  Gated, a phone whose page HAS the panel talking to
a box that does NOT have the channel would fall past this clause into the RFB one, and its
`{\"t\":\"viewport\",...}` would be handed to glass as remote-desktop input — 0x7B is not an RFB
client message type, and the cost of finding that out is somebody's desktop connection.

So the stream id claims its own traffic unconditionally, and the DISABLED case is handled where it
belongs: WARP-ON-MESSAGE answers NIL without opening anything, the bytes are dropped, and the
phone's panel says the box is not serving the list.  For streams 0 and 100 — the only two any
deployed client has ever used — this changes nothing at all, which is the property that matters."
  (eql sid +warp-stream-id+))

;;; A cellular data channel, sharing a link with VP8.  BYTES per pass — that is DOM-CONSUMER's
;;; unit, which is the reason warp made delta cost an encoding's question rather than the grid's.
;;;
;;; The steady-state cost of this channel is ZERO, and that is a property of the data rather than
;;; of the budget: enrolments change when somebody connects for the first time or somebody revokes,
;;; which is not a thing that happens while you are watching a desktop.  A pass with nothing owed
;;; emits nothing and sends nothing.  So the budget bounds the FIRST fill and the rare change, and
;;; 1 KB at 4 Hz is a ceiling of 4 KB/s against a bottom rung of 625 B/s — reached only for the two
;;; or three passes it takes to paint a handful of rows, and never while video is doing anything.
(defparameter *warp-budget*
  (or (ignore-errors (parse-integer (uiop:getenv "WARP_BUDGET"))) 1024)
  "Bytes per pass on the warp channel.")
(defparameter *warp-hz*
  (or (ignore-errors (parse-integer (uiop:getenv "WARP_HZ"))) 4)
  "Passes per second.  A list of terminals is not a video; four is already generous.")
(defparameter *warp-rows*
  (or (ignore-errors (parse-integer (uiop:getenv "WARP_ROWS"))) 12)
  "Rows offered before the browser reports its own viewport, which it does on connect.")

(defvar *warp-invoking-pubkey* nil
  "The peer whose message is being applied, bound for the duration of CHANNEL-RECEIVE.

A command reaches warp-monitor's handler with the OBJECT it acts on and the INVOKER's role, which
is all warp's own authorization needs — but the desktop checks the rule again on its own side, and
for that it needs the identity rather than the role.  There is exactly one place that identity
exists at this depth, and this is how it gets down there: WARP-DOM's ON-MESSAGE runs synchronously
inside CHANNEL-RECEIVE, on this thread, so a dynamic binding around the call is in scope for the
whole invocation and for nothing else.")

(defvar *warp-loaded* nil "T once :warp-dom and :warp-monitor are in the image.")
(defvar *warp-projection* nil "The shared projection — one query, however many phones.")
(defvar *warp-lock* (bt:make-lock "warp-gateway"))

;;; ---- the second app: the file browser ----------------------------------------------------
;;;
;;; OFF UNLESS ASKED, like everything else here, and for a sharper reason than the channel itself:
;;; :warp-files depends on warren, which drags gesso, scribe and pigment into this image.  That is
;;; a fine dependency for an optional client system and an absurd one to take on a box whose owner
;;; only ever wanted the terminal list, so the load happens at the FIRST MESSAGE NAMING THE APP —
;;; not at gateway start, and never at all with WARP_FILES unset.
;;;
;;; A FAILED LOAD IS REMEMBERED.  The device-manager load retries on every message, which is cheap
;;; when the systems are simply absent; a half-second of ASDF per message is not, so this one
;;; records that it failed and answers from the record.  The phone's panel then says the box is not
;;; serving the file browser, which is exactly what has happened.

(defparameter *warp-files-enabled* (and (uiop:getenv "WARP_FILES") t)
  "Whether this gateway serves the file browser at all.  Off unless WARP_FILES is set.")

(defvar *warp-files-loaded* nil "T, NIL, or :FAILED once the load has been tried and lost.")
(defvar *warp-files-projection* nil
  "The shared projection — ONE browser for the whole box, which is rule 8 read exactly: the column
stack is an argument to the query, so it is shared, and two phones looking at the files drill in
together.  A second, private one would be a second projection, and nothing here asks for that.")

(defun warp-files-ensure-loaded ()
  "Load :warp-files/dom, once.  Returns T on success.  Never signals: an app that will not load is
an app this box does not serve, not a gateway that stops serving the desktop."
  (case *warp-files-loaded*
    ((t) t)
    (:failed nil)
    (t (handler-case
           (progn
             (handler-bind ((warning #'muffle-warning))
               (let ((*standard-output* (make-broadcast-stream)))
                 (asdf:load-system "warp-files/dom")))
             (setf *warp-files-loaded* t))
         (error (e)
           (setf *warp-files-loaded* :failed)
           (format *error-output* "~&[warp] the file browser is not available: ~a~%" e)
           (finish-output *error-output*)
           nil)))))

(defun warp-files-projection ()
  "The file browser's shared projection, rooted where WARP-FILES:DEFAULT-ROOT says.

WHERE IT OPENS IS A DEFAULT AND NOT A CONFINEMENT, and pretending otherwise would be theatre: the
desktop next door has a terminal in its root menu, so anything that can reach this panel can already
reach a shell.  What the default is for is that `/` is useless to open at, and $HOME is where a
person's files are — the same answer warren's pixel browser gives, which is rule 9's two facets of
one app agreeing about something small.  WARP_FILES_ROOT overrides it."
  (bt:with-lock-held (*warp-lock*)
    (or *warp-files-projection*
        (setf *warp-files-projection*
              (funcall (find-symbol "BROWSE-PROJECTION" "WARP-FILES")
                       (funcall (find-symbol "MAKE-BROWSER" "WARP-FILES")))))))

;;; ---- which apps this box serves ------------------------------------------------------------
;;; One function, because the answer depends on what has managed to load and that is only knowable
;;; at the moment somebody asks.  NIL is the device manager: the app with no name, the one a client
;;; that has never heard of any of this is talking to.

(defun warp-app (id)
  "The spec for app ID — a plist of :PROJECTION :VIEW :ATTACH — or NIL if this box does not serve it.
NIL for an unknown id is the whole of the refusal: MUX-RECEIVE drops the message and the phone's
panel says nobody answered, which is the honest report."
  (cond
    ((null id)
     (list :projection (warp-projection)
           :view (find-symbol "MONITOR-VIEW" "WARP-MONITOR")))
    ((and (equal id "files") *warp-files-enabled* (warp-files-ensure-loaded))
     (list :projection (warp-files-projection)
           :view (find-symbol "FILES-VIEW" "WARP-FILES")
           ;; the file browser's consumer class is its own — a Miller layout mixed in FRONT of
           ;; DOM-CONSUMER — and OPEN-CHANNEL takes the function that makes one rather than knowing
           ;; about it
           :attach (fdefinition (find-symbol "ATTACH-DOM" "WARP-FILES-DOM"))))
    (t nil)))

;;; ---- the query --------------------------------------------------------------------------
;;; DESIGN.md: views subscribe to RESULT-SETS, not to objects they happen to enumerate.  So this is
;;; a query returning the currently-enrolled terminals — and now that the store is the DESKTOP's,
;;; the implementation behind it is one line on a socket instead of one line on a hash table.  That
;;; is the whole of what moving it cost this file, and it is the shape the projection was written
;;; for: a query is a query wherever the rows come from.
;;;
;;; THE DESKTOP RE-READS ITS OWN FILE, so a revoke performed anywhere — this panel, the DM surface,
;;; a shell one-liner — is honoured on the next pass with no restart anywhere.  The mechanism the
;;; store was designed around, used rather than worked around; it has simply moved one process over.
;;;
;;; A DESKTOP THAT CANNOT BE REACHED YIELDS NO ROWS, and there is nothing better available: an
;;; unreachable service and an empty store are different facts, but a projection's contract is a
;;; list.  What keeps that honest is that the difference is LOGGED here rather than silently
;;; rendered as "no terminals are enrolled" — and that a phone which cannot reach the desktop is a
;;; phone whose screen, audio and microphone are all coming from the same place.

(defvar *warp-query-complained* nil)

(defun warp-enrolments ()
  "The current result-set: enrolled terminals that have not lapsed, as domain objects."
  (multiple-value-bind (rows why)
      (glass:admission-devices :host *glass-host* :port *admission-port*)
    (cond
      ((eq why :unreachable)
       (unless *warp-query-complained*
         (setf *warp-query-complained* t)
         (format *error-output* "~&[warp] the desktop's admission service (~a:~a) is not answering~
                                 ~% — the terminal list is empty because it cannot be asked~%"
                 *glass-host* *admission-port*)
         (finish-output *error-output*))
       '())
      (t
       (setf *warp-query-complained* nil)
       ;; a stable order, so the list does not reshuffle under a finger between passes (rule 6
       ;; depends on layouts not shifting) and so a re-sort is never mistaken for a change
       (mapcar (lambda (r)
                 (make-instance (find-symbol "ENROLMENT" "WARP-MONITOR")
                                :pubkey (car r) :expires (cdr r)))
               (sort (copy-list rows) #'string< :key #'car))))))

;;; ---- who is asking ----------------------------------------------------------------------

(defun warp-invoker-for (pubkey)
  "The warp invoker for an authenticated peer.

:ALLOWLIST FOR A CRYPTOGRAPHIC IDENTITY ON THE ALLOWLIST, :DEVICE FOR EVERYTHING ELSE.  This is
the DESKTOP's allowlist, asked as a question — literally the predicate the DM surface calls
`admin`, in the process that owns it — and asking it rather than answering it here is the point of
the exercise: `revoke` is one command with one authorization rule, and a second surface that
computed its own answer would be the drift this architecture exists to prevent.  It used to be a
local AUTHORIZED-P over a local NOSTR_ALLOW, which was the same rule only for as long as the two
copies of the list agreed.

A DESKTOP THAT CANNOT BE REACHED MAKES EVERYBODY A GUEST, which is the safe direction: the invoker
decides what a hold-menu offers, and offering `revoke` to somebody whose authority could not be
checked is the one mistake here that has consequences.

IT IS DELIBERATELY NOT THE SESSION'S `via`.  The session classifies a connection code / allowlist /
device and takes the FIRST match, so an owner who happens to arrive holding a valid login code is
classified \"code\" — and mapping that string onto an invoker would quietly demote the owner on
every connection made from a magic link.  Worse in the other direction: a code is a BEARER
credential that anyone who obtained the link holds, and treating one as ownership would hand the
allowlist's authority to whoever the link leaked to.  Both mistakes disappear by asking the
question the policy actually asks — is this pubkey on the allowlist — instead of reusing an answer
computed for a different one.

So an enrolled guest is never offered `revoke`, and rule 6 refuses it at invocation if it asks
anyway.  Menu filtering is courtesy; INVOKE is the enforcement point, in warp, once."
  (if (glass:admission-allowed-p pubkey :host *glass-host* :port *admission-port*)
      :allowlist :device))

;;; ---- loading, once, lazily ---------------------------------------------------------------
;;; At FIRST USE rather than at gateway start.  With the feature off this never runs at all, which
;;; is what makes the no-change claim checkable; with it on, the cost lands on the first phone that
;;; opens the panel rather than on every gateway restart.

(defun warp-ensure-loaded ()
  "Load :warp-dom and :warp-monitor if they are not already in the image.  Returns T on success.
Never signals: a missing system is a warp channel that does not work, not a gateway that does not
start, and the systems live in a sibling checkout that a given box may simply not have."
  (or *warp-loaded*
      (handler-case
          (progn
            (handler-bind ((warning #'muffle-warning))
              (let ((*standard-output* (make-broadcast-stream)))
                (asdf:load-system "warp-monitor")
                (asdf:load-system "warp-dom")))
            ;; REVOKE-IN-FILE is warp-monitor's seam, and it is aimed HERE.  It used to rewrite a
            ;; file — this gateway's .glass-devices — because that is where the store was; the
            ;; store is the desktop's now, and a panel that went on rewriting a local file would
            ;; revoke a terminal nobody is enforcing.  So the one function that WRITES is replaced
            ;; with the service call, and warp's own authorization (DEFINE-COMMAND-AUTHORIZATION
            ;; revoke-terminal, :allowlist only) is joined by the desktop's, which checks the
            ;; invoking pubkey again on its own side.  Replaced rather than edited in warp because
            ;; the transport is what knows where its desktop is; warp-monitor stays a reader of
            ;; rows and a namer of commands, which is what it is for.
            ;;
            ;; The pubkey is the OWNER's — the invoker whose authority the desktop is being asked
            ;; to check — and there is exactly one place it can come from at this depth, so it is
            ;; bound per invocation by WARP-ON-MESSAGE below.
            (setf (fdefinition (find-symbol "REVOKE-IN-FILE" "WARP-MONITOR"))
                  (lambda (pubkey)
                    (glass:admission-revoke (or *warp-invoking-pubkey* "")
                                            pubkey
                                            :host *glass-host* :port *admission-port*)))
            (setf *warp-loaded* t))
        (error (e)
          (format *error-output* "~&[warp] not available: ~a~%" e)
          (finish-output *error-output*)
          nil))))

(defun warp-projection ()
  "The shared projection.  ONE query for every phone that is looking — rule 8's claim, and the
reason this is a global rather than a per-session object: two terminals watching the enrolment list
cost one file check between them, each with its own stream, budget, scroll, menu and invoker."
  (bt:with-lock-held (*warp-lock*)
    (or *warp-projection*
        (setf *warp-projection*
              ;; FDEFINITION and not the bare symbol.  ROW-TYPE-OF takes "a presentation type, or a
              ;; FUNCTION from object to presentation type", and never calls a symbol — because
              ;; presentation types ARE symbols, so only a function can mean "ask".  Handing it the
              ;; symbol makes every row's type literally WARP-MONITOR:ROW-TYPE, which has no key
              ;; function, and rule 1 refuses to guess: the pass dies with "declare one with
              ;; DEFINE-PRESENTATION-KEY" every tick.  Loudly, which is the right failure and is how
              ;; this was caught, but it is a failure that only happens once a phone is connected.
              (funcall (find-symbol "MAKE-PROJECTION" "WARP") #'warp-enrolments
                       :type-fn (fdefinition (find-symbol "ROW-TYPE" "WARP-MONITOR")))))))

;;; ---- the three calls a session makes ------------------------------------------------------

;;; ONE PEER'S SHARE OF THE STREAM.  A class rather than a cons because it grew a third field and
;;; will grow a fourth, and because a class migrates its live instances if this file is ever
;;; redefined under a running image — which is the only way anything here is ever going to change
;;; on a box that is carrying somebody's session.
(defclass warp-link ()
  ((mux :initform nil :accessor warp-link-mux
        :documentation "WARP-DOM's app id -> channel router, one per peer.")
   (closed :initform nil :accessor warp-link-closed
           :documentation "Set by WARP-CLOSE before the clocks stop.  Every app's send lambda reads
it, because they all share one association: when the session goes, all of them stop, and the flag is
per LINK rather than per channel for exactly that reason."))
  (:documentation "One peer's warp channel: however many apps it opened, over the one stream."))

(defun warp-open (link assoc sid pub app)
  "Seat this peer as a consumer of APP.  Returns a channel, or NIL if this box does not serve that
app — in which case the peer's messages for it are dropped and its panel shows no answer, which is
the honest report of a box that does not have this."
  (let ((spec (handler-case (warp-app app) (error () nil))))
    (when spec
      (handler-case
          (let* ((invoker (warp-invoker-for pub))
                 (ch (apply (find-symbol "OPEN-CHANNEL" "WARP-DOM")
                            (getf spec :projection)
                            :view (getf spec :view)
                            :app app
                            :rows *warp-rows*
                            :budget *warp-budget*
                            :invoker invoker
                            :hz *warp-hz*
                            :name (format nil "~a~@[/~a~]" (if pub (subseq pub 0 8) "peer") app)
                            :log (lambda (m)
                                   (format *error-output* "~&[warp] ~a~%" m)
                                   (finish-output *error-output*))
                            ;; THE WHOLE OF THE TRANSPORT.  Guarded on the association's own state
                            ;; because SCTP-SEND-DATA blocks while the ready queue is full, and a
                            ;; queue that will never drain again is a thread that never returns:
                            ;; refusing early turns a hung sender into a counted send error, which
                            ;; is what the channel is built to absorb.
                            :send (lambda (frame)
                                    (when (or (warp-link-closed link)
                                              (eq (getf (sctp-stats assoc) :state) :aborted))
                                      (error "warp: association is gone"))
                                    (sctp-send-string assoc sid frame))
                            (let ((attach (getf spec :attach)))
                              (when attach (list :attach attach))))))
            (format *error-output*
                    "~&[warp] channel open for ~a... app ~a as ~(~a~) (~a B/pass at ~a Hz)~%"
                    (if pub (subseq pub 0 8) "peer") (or app "devices") invoker
                    *warp-budget* *warp-hz*)
            (finish-output *error-output*)
            ch)
        (error (e)
          (format *error-output* "~&[warp] could not open ~a: ~a~%" (or app "devices") e)
          (finish-output *error-output*)
          nil)))))

(defun warp-on-message (state assoc sid payload pub)
  "One message on the warp stream.  Opens this peer's link if this is the first one — a negotiated
channel has no handshake, so the first message IS the open — and hands the rest to the mux, which
routes it to the app the message names and opens THAT the first time it is named.

Returns the (possibly new) link, which the caller keeps and hands back to WARP-CLOSE.  It is opaque
to the caller and always was, which is why gateway-nostr.lisp needed no line for any of this.

NEVER SIGNALS.

THE FEATURE GATE IS HERE, not in WARP-SID-P: with the channel off these bytes are dropped on the
floor rather than falling through to the RFB stream.  See WARP-SID-P for why that distinction is
the difference between a panel that says nothing and a desktop connection that breaks."
  (unless *warp-channel-enabled* (return-from warp-on-message nil))
  (handler-case
      (let ((link state))
        (when (and (null link) (warp-ensure-loaded))
          (setf link (make-instance 'warp-link))
          (setf (warp-link-mux link)
                (funcall (find-symbol "MAKE-MUX" "WARP-DOM")
                         (lambda (app) (warp-open link assoc sid pub app)))))
        (when link
          (let ((text (if (stringp payload) payload (map 'string #'code-char (as-u8vec payload))))
                ;; who is invoking, for the desktop's own check on the far side of REVOKE-IN-FILE
                (*warp-invoking-pubkey* pub))
            (funcall (find-symbol "MUX-RECEIVE" "WARP-DOM") (warp-link-mux link) text)))
        link)
    (error (e)
      (format *error-output* "~&[warp] message: ~a~%" e)
      (finish-output *error-output*)
      state)))

(defun warp-close (state)
  "Unseat this peer, on every app it opened.  Called from the session's unwind path, so it may not
signal and may be called with nothing to close."
  (when state
    (ignore-errors (setf (warp-link-closed state) t))   ; stop the senders before the clocks
    (ignore-errors
     (dolist (cell (funcall (find-symbol "MUX-CHANNELS" "WARP-DOM") (warp-link-mux state)))
       (let ((stats (funcall (find-symbol "CHANNEL-STATS" "WARP-DOM") (cdr cell))))
         (format *error-output* "~&[warp] channel closed — app ~a, ~a frames, ~a B, ~a in~%"
                 (or (car cell) "devices")
                 (getf stats :frames) (getf stats :bytes) (getf stats :received)))
       (finish-output *error-output*)))
    (ignore-errors (funcall (find-symbol "MUX-CLOSE" "WARP-DOM") (warp-link-mux state))))
  nil)
