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

(defun warp-open (assoc sid pub)
  "Seat this peer as a warp consumer.  Returns a channel, or NIL if warp is not available — in
which case the peer's messages are dropped and its panel shows no answer, which is the honest
report of a box that does not have this."
  (when (warp-ensure-loaded)
    (handler-case
        (let* ((invoker (warp-invoker-for pub))
               (closed nil)
               (ch (funcall (find-symbol "OPEN-CHANNEL" "WARP-DOM")
                            (warp-projection)
                            :view (find-symbol "MONITOR-VIEW" "WARP-MONITOR")
                            :rows *warp-rows*
                            :budget *warp-budget*
                            :invoker invoker
                            :hz *warp-hz*
                            :name (if pub (subseq pub 0 8) "peer")
                            :log (lambda (m)
                                   (format *error-output* "~&[warp] ~a~%" m)
                                   (finish-output *error-output*))
                            ;; THE WHOLE OF THE TRANSPORT.  Guarded on the association's own state
                            ;; because SCTP-SEND-DATA blocks while the ready queue is full, and a
                            ;; queue that will never drain again is a thread that never returns:
                            ;; refusing early turns a hung sender into a counted send error, which
                            ;; is what the channel is built to absorb.
                            :send (lambda (frame)
                                    (when (or closed
                                              (eq (getf (sctp-stats assoc) :state) :aborted))
                                      (error "warp: association is gone"))
                                    (sctp-send-string assoc sid frame)))))
          (format *error-output* "~&[warp] channel open for ~a... as ~(~a~) (~a B/pass at ~a Hz)~%"
                  (if pub (subseq pub 0 8) "peer") invoker *warp-budget* *warp-hz*)
          (finish-output *error-output*)
          ;; the flag the send lambda reads, handed back so CLOSE can set it
          (cons ch (lambda () (setf closed t))))
      (error (e)
        (format *error-output* "~&[warp] could not open: ~a~%" e)
        (finish-output *error-output*)
        nil))))

(defun warp-on-message (state assoc sid payload pub)
  "One message on the warp stream.  Opens the channel if this is the first one — a negotiated
channel has no handshake, so the first message IS the open — and hands the rest to warp.

Returns the (possibly new) channel state, which the caller keeps.  NEVER SIGNALS.

THE FEATURE GATE IS HERE, not in WARP-SID-P: with the channel off these bytes are dropped on the
floor rather than falling through to the RFB stream.  See WARP-SID-P for why that distinction is
the difference between a panel that says nothing and a desktop connection that breaks."
  (unless *warp-channel-enabled* (return-from warp-on-message nil))
  (handler-case
      (let ((st (or state (warp-open assoc sid pub))))
        (when st
          (let ((text (if (stringp payload) payload (map 'string #'code-char (as-u8vec payload))))
                ;; who is invoking, for the desktop's own check on the far side of REVOKE-IN-FILE
                (*warp-invoking-pubkey* pub))
            (funcall (find-symbol "CHANNEL-RECEIVE" "WARP-DOM") (car st) text)))
        st)
    (error (e)
      (format *error-output* "~&[warp] message: ~a~%" e)
      (finish-output *error-output*)
      state)))

(defun warp-close (state)
  "Unseat this peer.  Called from the session's unwind path, so it may not signal and may be
called with nothing to close."
  (when state
    (ignore-errors (funcall (cdr state)))          ; stop the sender before stopping the clock
    (ignore-errors
     (let ((stats (funcall (find-symbol "CHANNEL-STATS" "WARP-DOM") (car state))))
       (format *error-output* "~&[warp] channel closed — ~a frames, ~a B, ~a in~%"
               (getf stats :frames) (getf stats :bytes) (getf stats :received))
       (finish-output *error-output*)))
    (ignore-errors (funcall (find-symbol "CHANNEL-CLOSE" "WARP-DOM") (car state))))
  nil)
