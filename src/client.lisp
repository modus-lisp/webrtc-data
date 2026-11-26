;;;; src/client.lisp — the CALLING side: offer, dial, and hold data channels to an answerer.
;;;;
;;;; Everything else in this library answers: a browser (or aiortc) offers, the box answers
;;;; a=setup:active with an ICE-lite agent, is the DTLS client, and responds to SCTP's INIT.  This
;;;; file is the other end, the one a browser plays -- so a Lisp program can dial a box the way a
;;;; phone does:
;;;;
;;;;   SDP    an offer with one m=application section and every candidate in it (NON-TRICKLE:
;;;;          gathering finishes before the offer is returned, as the phone's shell.js does,
;;;;          because the signalling is one-shot), a=setup:actpass.
;;;;   ICE    the CONTROLLING agent (the answer is ICE-lite, so it must be): Binding requests to
;;;;          every IPv4 candidate of the answer, ICE-CONTROLLING + USE-CANDIDATE (aggressive
;;;;          nomination) + PRIORITY, MESSAGE-INTEGRITY under the answerer's password; the first
;;;;          pair that answers is the route.  We still answer the answerer's own checks (the ICE
;;;;          agent always did), and keep consent fresh with a check every few seconds (RFC 7675).
;;;;   DTLS   the SERVER role: the answer picks active, so we are passive (seal's
;;;;          dtls-server.lisp), with the same ECDSA P-256 identity and X25519/AES-128-GCM the
;;;;          answerer's client offers.  The answer's a=fingerprint is checked against the
;;;;          certificate it presents.
;;;;   SCTP   the INITIATOR (INIT -> INIT-ACK -> COOKIE-ECHO -> COOKIE-ACK, sctp.lisp), then
;;;;          everything sctp.lisp already does for the responder: reliability, congestion, SACKs.
;;;;   DCEP   channels are declared BEFORE the offer, exactly as the phone must: one in-band
;;;;          channel (DATA_CHANNEL_OPEN, answered by an ACK) on an ODD stream id -- RFC 8832 6:
;;;;          the DTLS server takes the odd ids -- and any number of NEGOTIATED ones on fixed ids
;;;;          (control 100, warp 102, payload 104, pointer 106 to a glass box), which cost nothing
;;;;          on the wire.
;;;;
;;;; ONE SESSION THREAD, AND THE CALLER HOLDS ONLY CHANNELS.  CONNECT-PEER starts the session on a
;;;; NAMED function (%CLIENT-SESSION-MAIN) with two CL-TRANSPORT.CHAN channels and plain data as
;;;; :ARGUMENTS.  That thread owns everything: it gathers, builds the ICE agent (PULL mode -- it
;;;; reads the UDP socket itself, no receive thread), sends its checks, runs the DTLS server and
;;;; the SCTP association, and keeps consent.  What the caller gets back is an RTC-PEER: a HANDLE
;;;; over the two channels.
;;;;
;;;;   session -> caller (EVENTS):  (:offer sdp) (:open ...) (:data sid payload) (:chstate sid st)
;;;;                                (:mark what secs) (:log text) (:stats plist) (:error text)
;;;;                                (:closed reason stats) -- always last
;;;;   caller -> session (COMMANDS): (:answer sdp) (:send sid data) (:stats) (:close abort-p)
;;;;
;;;; Every value crosses by copy.  This is what modus needs -- a thread there may not store an
;;;; object it made into memory another thread made, so a receive thread could not fill the
;;;; caller's queues -- and SBCL runs the same threads and channels.
;;;;
;;;; EVENTS ARE TAKEN BY THE CALLER, on its own thread, whenever it touches the peer: a read that
;;;; waits, RTC-OPEN-P, RTC-PUMP, PEER-STATS, RTC-CLOSE.  So a channel's ON-MESSAGE and the peer's
;;;; ON-CLOSE run on the caller's thread, inside one of those calls -- a program that only waits on
;;;; ON-MESSAGE must call RTC-PUMP in its loop.  The session never waits for the caller: what the
;;;; caller has not taken yet queues on the session's side.
;;;;
;;;; A CHANNEL IS A BYTE STREAM when you want one: RTC-CHANNEL-STREAM is a Gray binary stream whose
;;;; READ-SEQUENCE fills completely (CL semantics, so a protocol reader such as an RFB client can
;;;; sit on it as on a socket), and whose FORCE-OUTPUT sends what was written as one message.

(in-package #:webrtc-data)

(defconstant +client-chan-bytes+ (* 1024 1024)
  "Capacity of each of a client session's two channels: bounds one message (an SCTP message is at
most 262144 bytes, a=max-message-size).")

;;; ---- channel pairs, reused ------------------------------------------------------------------
;;;
;;; On modus a channel's ring and wait queues are never reclaimed, so a pair whose session has
;;; ended (its :CLOSED taken, both sides drained) goes back on a free list for the next dial.  The
;;; list is a global, so only a thread that may store into it reuses: a worker thread's dial on
;;; modus makes a fresh pair each time (the push is refused there, and that is all).

(defvar *client-chan-pool* '())
(defvar *client-chan-pool-lock* (bt:make-lock "webrtc client channel pool"))

(defun %take-chan-pair ()
  (or (ignore-errors (bt:with-lock-held (*client-chan-pool-lock*) (pop *client-chan-pool*)))
      (cons (cl-transport.chan:make-chan :capacity +client-chan-bytes+)
            (cl-transport.chan:make-chan :capacity +client-chan-bytes+))))

(defun %give-chan-pair (pair)
  (cl-transport.chan:chan-drain (car pair))
  (cl-transport.chan:chan-drain (cdr pair))
  (ignore-errors (bt:with-lock-held (*client-chan-pool-lock*) (push pair *client-chan-pool*))))

;;; ---- the caller's side: channel ---------------------------------------------------------------

(defclass rtc-channel ()
  ((peer :initarg :peer :reader channel-peer)
   (label :initarg :label :reader channel-label)
   (id :initarg :id :reader channel-id)
   (negotiated :initarg :negotiated :initform nil :reader channel-negotiated-p)
   (ordered :initarg :ordered :initform t :reader channel-ordered-p)
   (protocol :initarg :protocol :initform "" :reader channel-protocol)
   (state :initform :connecting :accessor channel-state)       ; :connecting :open :closed
   (on-message :initarg :on-message :initform nil :accessor channel-on-message)
   ;; inbound bytes, for the stream view: a queue of octet vectors and the read position in
   ;; the first.  Kept as messages, not copied byte-wise into one buffer, so a big update costs
   ;; a cons, not a VECTOR-PUSH-EXTEND per byte.
   (inq :initform '() :accessor %chan-inq)
   (inq-tail :initform nil :accessor %chan-inq-tail)
   (inpos :initform 0 :accessor %chan-inpos))
  (:documentation "One data channel of an RTC-PEER: a label and an SCTP stream id."))

(defmethod print-object ((c rtc-channel) s)
  (print-unreadable-object (c s :type t)
    (format s "~s id ~d ~(~a~)" (channel-label c) (channel-id c) (channel-state c))))

;;; ---- the caller's side: peer ------------------------------------------------------------------

(defclass rtc-peer ()
  ((events :initarg :events :reader %peer-events)               ; CHAN session -> caller
   (commands :initarg :commands :reader %peer-commands)         ; CHAN caller -> session
   (pair :initarg :pair :reader %peer-pair)
   (channels :initform '() :accessor peer-channels)
   (state :initform :new :accessor peer-state)    ; :new :offered :connecting :open :closed
   (reason :initform nil :accessor peer-reason)                ; why it closed
   (closing :initform nil :accessor %peer-closing)              ; RTC-CLOSE has begun
   (relay-only :initarg :relay-only :initform nil :reader peer-relay-only)
   (offer :initform nil :accessor peer-offer)
   (remote-fingerprint :initform nil :accessor peer-remote-fingerprint)
   (on-close :initarg :on-close :initform nil :accessor peer-on-close)
   (on-close-done :initform nil :accessor %peer-on-close-done)
   (log :initarg :log :initform nil :reader peer-log)
   ;; recursive: an ON-MESSAGE run by the pump may read or pump again
   (lock :initform (bt:make-recursive-lock "rtc-peer") :reader %peer-lock)
   (stats :initform nil :accessor %peer-stats)
   (t0 :initform (get-internal-real-time) :reader %peer-t0)
   (timings :initform '() :accessor peer-timings))              ; ((:what . seconds) ...)
  (:documentation "The calling end of one WebRTC data-channel session: a handle over the channels
to the session thread that owns ICE, DTLS and SCTP."))

(defmethod print-object ((p rtc-peer) s)
  (print-unreadable-object (p s :type t)
    (format s "~(~a~) ~d channel~:p" (peer-state p) (length (peer-channels p)))))

(defun rtc-channel (peer label-or-id)
  "PEER's channel by label (a string) or stream id."
  (find label-or-id (peer-channels peer)
        :key (if (stringp label-or-id) #'channel-label #'channel-id) :test #'equal))

(defun %deliver (ch payload)
  "An inbound message on CH: to its ON-MESSAGE if it has one, else queued for the stream view."
  (if (channel-on-message ch)
      (funcall (channel-on-message ch) ch payload)
      (let ((bytes (if (stringp payload) (utf8 payload) (as-u8vec payload))))
        (when (plusp (length bytes))
          (let ((cell (list bytes)))
            (if (%chan-inq-tail ch)
                (setf (cdr (%chan-inq-tail ch)) cell)
                (setf (%chan-inq ch) cell))
            (setf (%chan-inq-tail ch) cell))))))

(defun %handle-event (peer msg)
  "File one event from the session.  Returns T for the session's last word, :CLOSED."
  (case (first msg)
    (:offer (setf (peer-offer peer) (second msg) (peer-state peer) :offered) nil)
    (:mark (push (cons (second msg) (third msg)) (peer-timings peer)) nil)
    (:log (let ((out (peer-log peer)))
            (when out (format out "~&~a~%" (second msg)) (finish-output out)))
          nil)
    (:open (setf (peer-state peer) :open
                 (peer-remote-fingerprint peer) (second msg))
           (dolist (ch (peer-channels peer)) (setf (channel-state ch) :open))
           nil)
    (:chstate (let ((ch (rtc-channel peer (second msg))))
                (when ch (setf (channel-state ch) (third msg))))
              nil)
    (:data (let ((ch (rtc-channel peer (second msg))))
             (when ch (%deliver ch (third msg))))
           nil)
    (:stats (setf (%peer-stats peer) (second msg)) nil)
    (:error (unless (peer-reason peer) (setf (peer-reason peer) (second msg))) nil)
    (:closed (unless (peer-reason peer) (setf (peer-reason peer) (second msg)))
             (when (third msg) (setf (%peer-stats peer) (third msg)))
             (setf (peer-state peer) :closed)
             (dolist (ch (peer-channels peer)) (setf (channel-state ch) :closed))
             t)))

(defun rtc-pump (peer &optional (timeout 0))
  "Take what the session has sent: inbound messages to their channels (ON-MESSAGE runs here, on
this thread), state changes, and the end.  Waits up to TIMEOUT seconds for the first event.
Returns the number taken.  Call it in a loop that waits on ON-MESSAGE callbacks."
  (let ((n 0) (closed nil))
    (bt:with-recursive-lock-held ((%peer-lock peer))
      (unless (eq (peer-state peer) :closed)
        (loop
          (multiple-value-bind (msg ok)
              (cl-transport.chan:chan-receive (%peer-events peer) :timeout (if (zerop n) timeout 0))
            (unless ok (return))
            (incf n)
            (when (%handle-event peer msg) (setf closed t) (return))))))
    (when closed (%peer-ended peer))
    n))

(defun %peer-ended (peer)
  "The session has said its last word: free its channels and run ON-CLOSE (once)."
  (unless (%peer-on-close-done peer)
    (setf (%peer-on-close-done peer) t)
    (%give-chan-pair (%peer-pair peer))
    (when (peer-on-close peer)
      (ignore-errors (funcall (peer-on-close peer) peer (peer-reason peer))))))

(defun %pump-until (peer pred timeout what)
  "Pump until PRED is true; WEBRTC-ERROR naming WHAT if the session closes or TIMEOUT passes."
  (let ((deadline (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second)))))
    (loop
      (when (funcall pred) (return t))
      (when (eq (peer-state peer) :closed)
        (werr "~a: the session closed (~a)" what (peer-reason peer)))
      (when (>= (get-internal-real-time) deadline)
        (werr "~a: timed out after ~as" what timeout))
      (rtc-pump peer 0.05))))

(defun %command (peer msg)
  (unless (cl-transport.chan:chan-send (%peer-commands peer) msg :timeout 10)
    (werr "the session is not taking commands")))

(defun channel-send (ch data)
  "Send DATA on CH as one message: a string as PPID 51 (UTF-8), octets as PPID 53."
  (let ((peer (channel-peer ch)))
    (unless (eq (peer-state peer) :open)
      (werr "channel ~s: the association is not up" (channel-label ch)))
    (%command peer (list :send (channel-id ch)
                         (if (stringp data) data (coerce data '(simple-array (unsigned-byte 8) (*))))))
    t))

(defun channel-read (ch buf &key (start 0) (end (length buf)) (wait t))
  "Copy queued inbound bytes of CH into BUF[START,END): at least one unless WAIT is NIL (blocks
for the first).  Returns the index after the last byte copied; START means EOF (or nothing,
with WAIT NIL)."
  (let ((peer (channel-peer ch)))
    (loop while (and wait (null (%chan-inq ch)) (not (eq (channel-state ch) :closed)))
          do (rtc-pump peer 0.05))
    (unless wait (rtc-pump peer 0))
    (bt:with-recursive-lock-held ((%peer-lock peer))
      (let ((i start))
        (loop while (and (< i end) (%chan-inq ch))
              do (let* ((v (car (%chan-inq ch))) (pos (%chan-inpos ch))
                        (n (min (- end i) (- (length v) pos))))
                   (replace buf v :start1 i :start2 pos :end2 (+ pos n))
                   (incf i n)
                   (if (>= (+ pos n) (length v))
                       (progn (setf (%chan-inq ch) (cdr (%chan-inq ch)) (%chan-inpos ch) 0)
                              (unless (%chan-inq ch) (setf (%chan-inq-tail ch) nil)))
                       (setf (%chan-inpos ch) (+ pos n)))))
        i))))

(defun rtc-open-p (peer)
  (rtc-pump peer 0)
  (eq (peer-state peer) :open))

(defun peer-stats (peer &key (timeout 2.0))
  "The session's SCTP-STATS plist, plus :ROUTE (ICE-ROUTE-LABEL of the selected pair) and
:ROUTE-KIND (the first element of the selected peer form: a host, :RELAY or :RELAY-SEND).  Asked
of the session while it runs; the last ones it sent once it has ended."
  (unless (eq (peer-state peer) :closed)
    (setf (%peer-stats peer) nil)
    (ignore-errors (%command peer (list :stats)))
    (ignore-errors (%pump-until peer (lambda () (%peer-stats peer)) timeout "stats")))
  (%peer-stats peer))

;;; ---- the channel as a byte stream ---------------------------------------------------------

(defclass rtc-channel-stream (sb-gray:fundamental-binary-input-stream
                              sb-gray:fundamental-binary-output-stream)
  ((channel :initarg :channel :reader stream-channel)
   (one :initform (make-array 1 :element-type '(unsigned-byte 8)))
   (wbuf :initform (make-array 4096 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
   (wlock :initform (bt:make-lock "rtc-channel-stream-w")))
  (:documentation "A Gray binary stream over an RTC-CHANNEL: reads drain its inbound messages
(READ-SEQUENCE blocks until the sequence is full or the channel closes, as on a socket stream);
writes are buffered and sent as one message per FORCE-OUTPUT / FINISH-OUTPUT."))

(defun rtc-channel-stream (channel)
  "A binary byte stream over CHANNEL (an RTC-CHANNEL)."
  (make-instance 'rtc-channel-stream :channel channel))

(defmethod stream-element-type ((s rtc-channel-stream)) '(unsigned-byte 8))

(defmethod sb-gray:stream-read-byte ((s rtc-channel-stream))
  (let ((one (slot-value s 'one)))
    (if (> (channel-read (stream-channel s) one) 0) (aref one 0) :eof)))

(defmethod sb-gray:stream-read-sequence ((s rtc-channel-stream) seq &optional (start 0) end)
  (let ((end (or end (length seq))) (i start))
    (loop while (< i end)
          do (let ((j (channel-read (stream-channel s) seq :start i :end end)))
               (when (= j i) (return))                  ; closed
               (setf i j)))
    i))

(defmethod sb-gray:stream-listen ((s rtc-channel-stream))
  (let ((ch (stream-channel s)))
    (rtc-pump (channel-peer ch) 0)
    (and (%chan-inq ch) t)))

(defun %stream-flush (s)
  (with-slots (wbuf wlock channel) s
    (bt:with-lock-held (wlock)
      (when (plusp (fill-pointer wbuf))
        (let ((msg (coerce (subseq wbuf 0) '(simple-array (unsigned-byte 8) (*)))))
          (setf (fill-pointer wbuf) 0)
          (unless (eq (channel-state channel) :closed)
            (channel-send channel msg)))))))

(defmethod sb-gray:stream-write-byte ((s rtc-channel-stream) byte)
  (with-slots (wbuf wlock) s (bt:with-lock-held (wlock) (vector-push-extend byte wbuf)))
  byte)

(defmethod sb-gray:stream-write-sequence ((s rtc-channel-stream) seq &optional (start 0) end)
  (with-slots (wbuf wlock) s
    (bt:with-lock-held (wlock)
      (loop for i from start below (or end (length seq)) do (vector-push-extend (elt seq i) wbuf))))
  seq)

(defmethod sb-gray:stream-force-output ((s rtc-channel-stream)) (%stream-flush s) nil)
(defmethod sb-gray:stream-finish-output ((s rtc-channel-stream)) (%stream-flush s) nil)

(defmethod close ((s rtc-channel-stream) &key abort)
  (unless abort (ignore-errors (%stream-flush s)))
  (setf (channel-state (stream-channel s)) :closed)
  t)

;;; ---- the caller's side: dial and hang up ------------------------------------------------------

(defun %spec->channel-plists (specs)
  "Declare the channels (as the phone must, before the offer): stream ids assigned here -- the
next odd id for an in-band channel, the given one for a negotiated channel -- and checked."
  (let ((next 1) (out '()))
    (dolist (spec specs (nreverse out))
      (destructuring-bind (label &key id (negotiated (and id t)) (ordered t) (protocol "") on-message)
          spec
        (when (and negotiated (null id)) (werr "a negotiated channel needs an :id"))
        (let ((sid (or id (prog1 next (incf next 2)))))
          (when (find sid out :key (lambda (p) (getf p :id)))
            (werr "stream id ~d is already channel ~s" sid
                  (getf (find sid out :key (lambda (p) (getf p :id))) :label)))
          (push (list :label label :id sid :negotiated negotiated :ordered ordered
                      :protocol protocol :on-message on-message)
                out))))))

(defun connect-peer (signal-fn &key channels local-ip gather-srflx gather-relay (timeout 30.0)
                                    log on-close relay-only)
  "Dial: gather, offer, have SIGNAL-FN deliver the offer and return the answer, connect.
SIGNAL-FN is called with the offer SDP (a string) and returns the answer SDP, or NIL for no
answer.  CHANNELS is a list of (LABEL &key ID NEGOTIATED ORDERED PROTOCOL ON-MESSAGE) specs,
declared before the offer.  Returns the open RTC-PEER (its channels by RTC-CHANNEL, as streams
by RTC-CHANNEL-STREAM); signals WEBRTC-ERROR, naming what failed.

GATHER-SRFLX asks a STUN server for our public mapping (*STUN-SERVERS*); GATHER-RELAY allocates a
TURN relay -- T for env TURN_SERVER/USER/PASS, or a plist (:server \"host:port\" :user :pass).
LOCAL-IP is the host candidate's address (default: the primary IPv4, or env ICE_LOCAL_IP).
RELAY-ONLY is a browser's iceTransportPolicy \"relay\": only the relay candidate is offered and
every packet goes through the TURN allocation.  LOG, a stream, gets the connect sequence.
ON-CLOSE (peer reason) runs on this thread when the end is taken (see the file header).

The session runs on a thread of its own (the file header); SIGNAL-FN and every callback run on
this one."
  (let* ((plists (%spec->channel-plists channels))
         (pair (%take-chan-pair))
         (peer (make-instance 'rtc-peer :events (car pair) :commands (cdr pair) :pair pair
                                        :log log :on-close on-close :relay-only relay-only)))
    (setf (peer-channels peer)
          (mapcar (lambda (p)
                    (make-instance 'rtc-channel :peer peer :label (getf p :label) :id (getf p :id)
                                                :negotiated (getf p :negotiated)
                                                :ordered (getf p :ordered) :protocol (getf p :protocol)
                                                :on-message (getf p :on-message)))
                  plists))
    (handler-case
        (progn
          (sb-thread:make-thread
           #'%client-session-main :name "rtc-session"
           :arguments (list (car pair) (cdr pair)
                            (mapcar (lambda (p) (list (getf p :label) (getf p :id) (getf p :negotiated)
                                                      (getf p :ordered) (getf p :protocol)))
                                    plists)
                            (list :local-ip local-ip :gather-srflx (and gather-srflx t)
                                  :gather-relay (if (consp gather-relay) gather-relay (and gather-relay t))
                                  :relay-only (and relay-only t) :timeout timeout :log (and log t))))
          (%pump-until peer (lambda () (peer-offer peer)) 120 "gathering")
          (let ((answer (funcall signal-fn (peer-offer peer))))
            (push (cons :answered (/ (float (- (get-internal-real-time) (%peer-t0 peer)) 1d0)
                                     internal-time-units-per-second))
                  (peer-timings peer))
            (unless answer (werr "no answer"))
            (setf (peer-state peer) :connecting)
            (%command peer (list :answer answer))
            (%pump-until peer (lambda () (eq (peer-state peer) :open)) (+ timeout 5) "connect")
            peer))
      ;; HANDLER-CASE, not HANDLER-BIND: the stack (and any lock it held) is unwound before the
      ;; hang-up runs, and the error that reaches the caller is the one that happened.
      (error (e)
        (ignore-errors (rtc-close peer :abort t))
        (error e)))))

(defun rtc-close (peer &key abort)
  "End PEER: an SCTP ABORT tells the answerer at once (rather than after its silence timeout),
then the session stops and releases the socket -- and any TURN allocation.  ABORT skips the
goodbye (used on a failed connect).  Waits up to 5 s for the session's last word.  Safe to call
twice: the second call returns PEER."
  (unless (bt:with-recursive-lock-held ((%peer-lock peer))
            (unless (%peer-closing peer) (setf (%peer-closing peer) t)))
    (return-from rtc-close peer))
  (unless (eq (peer-state peer) :closed)
    (cl-transport.chan:chan-send (%peer-commands peer) (list :close (and abort t)) :timeout 2)
    (let ((deadline (+ (get-internal-real-time) (* 5 internal-time-units-per-second))))
      (loop until (or (eq (peer-state peer) :closed) (> (get-internal-real-time) deadline))
            do (rtc-pump peer 0.1)))
    (unless (eq (peer-state peer) :closed)          ; the session never answered: say so locally
      (setf (peer-state peer) :closed)
      (unless (peer-reason peer) (setf (peer-reason peer) "the session did not end in 5 s"))
      (dolist (ch (peer-channels peer)) (setf (channel-state ch) :closed))))
  peer)

;;; ===============================================================================================
;;; THE SESSION'S SIDE -- everything below runs on the session thread and nowhere else.
;;; ===============================================================================================

(defstruct (%sch (:constructor %make-sch (label id negotiated ordered protocol)))
  label id negotiated ordered protocol (state :connecting))

(defstruct (rtc-session (:conc-name %s-) (:constructor %make-session))
  agent conn assoc (channels '()) relay-only (tiebreaker (random-bytes 8))
  events commands log reason (stop nil) (t0 (get-internal-real-time))
  (backlog '()) (backlog-tail nil)
  (checks-at 0) (extra-checks 5) (consent-at 0) (hs-at 0) (hs-tries 0))

(defun %secs-since (t0) (/ (float (- (get-internal-real-time) t0) 1d0) internal-time-units-per-second))

(defun %emit (s msg)
  "MSG to the caller, in order, never waiting: what the events channel will not take now waits
in the session's backlog and goes on a later pass."
  (let ((ev (%s-events s)))
    (if (and (null (%s-backlog s)) (cl-transport.chan:chan-send ev msg :timeout 0))
        t
        (let ((cell (list msg)))
          (if (%s-backlog-tail s) (setf (cdr (%s-backlog-tail s)) cell) (setf (%s-backlog s) cell))
          (setf (%s-backlog-tail s) cell)
          nil))))

(defun %flush-backlog (s &optional (timeout 0))
  (loop while (and (%s-backlog s)
                   (cl-transport.chan:chan-send (%s-events s) (first (%s-backlog s)) :timeout timeout))
        do (pop (%s-backlog s))
           (unless (%s-backlog s) (setf (%s-backlog-tail s) nil))))

(defun %plog (s fmt &rest args)
  (when (%s-log s)
    (%emit s (list :log (format nil "[rtc ~,2fs] ~?" (%secs-since (%s-t0 s)) fmt args)))))

(defun %mark (s what)
  (%emit s (list :mark what (%secs-since (%s-t0 s)))))

;;; ---- gathering + the offer ---------------------------------------------------------------------

(defun %offer-candidates (agent &optional relay-only)
  (let ((ip (ice-agent-local-ip agent)) (port (ice-agent-port agent)))
    (with-output-to-string (o)
      (unless relay-only (format o "a=candidate:1 1 udp 2130706431 ~a ~d typ host~%" ip port))
      (when (and (ice-agent-srflx-ip agent) (not relay-only))
        (format o "a=candidate:2 1 udp 1694498815 ~a ~d typ srflx raddr ~a rport ~d~%"
                (ice-agent-srflx-ip agent) (ice-agent-srflx-port agent) ip port))
      (when (ice-agent-relay-ip agent)
        (format o "a=candidate:3 1 udp 41885439 ~a ~d typ relay raddr ~a rport ~d~%"
                (ice-agent-relay-ip agent) (ice-agent-relay-port agent)
                (or (ice-agent-srflx-ip agent) ip) (or (ice-agent-srflx-port agent) port)))
      (format o "a=end-of-candidates~%"))))

(defun %session-gather (s &key local-ip gather-srflx gather-relay relay-only)
  "Bind the UDP socket and gather (blocking, as the phone gathers before it offers)."
  (let* ((agent (make-ice :local-ip (or local-ip (uiop:getenv "ICE_LOCAL_IP"))))
         (conn (webrtc-dtls-setup agent)))
    (setf (%s-agent s) agent (%s-conn s) conn (%s-relay-only s) relay-only)
    (when gather-srflx (ice-gather-srflx agent))
    (when (or gather-relay relay-only)
      (apply #'ice-gather-relay agent (if (listp gather-relay) gather-relay '())))
    (when (and relay-only (null (ice-agent-relay-ip agent)))
      (werr "relay-only, and no TURN relay could be allocated"))
    ;; Our end of DTLS is the SERVER (the answer will say a=setup:active).
    (seal:dtls-server-start (dtls-conn-session conn) :timeout 0.4)
    ;; The pump dtls.lisp installed, plus: the first datagram from the peer names the route if
    ;; ICE has not yet (a reply to our check and the answerer's first flight race).
    (let ((mb (dtls-conn-mailbox conn)))
      (setf (ice-agent-on-packet agent)
            (lambda (pkt host port)
              (unless (or (ice-agent-peer agent) relay-only)
                (ignore-errors (ice-note-peer agent (list host port))))
              (mailbox-push mb pkt))))
    (%mark s :gathered)))

(defun %session-offer (s)
  "The offer SDP: one bundled m=application (webrtc-datachannel, sctp-port 5000) with every
gathered candidate, our ICE credentials, our certificate's fingerprint and a=setup:actpass.
Nothing about the channels is in it (the in-band ones are opened by DCEP, the negotiated ones are
agreed out of band), as in a browser's offer."
  (let* ((agent (%s-agent s)) (conn (%s-conn s))
         (sid (format nil "~d" (logand (rd-u32be (random-bytes 4) 0) #x7fffffff)))
         (sdp (with-output-to-string (o)
                (format o "v=0~%o=- ~a 2 IN IP4 127.0.0.1~%s=-~%t=0 0~%a=group:BUNDLE 0~%~
                           a=msid-semantic: WMS~%~
                           m=application ~d UDP/DTLS/SCTP webrtc-datachannel~%c=IN IP4 ~a~%~a~
                           a=ice-ufrag:~a~%a=ice-pwd:~a~%a=fingerprint:sha-256 ~a~%a=setup:actpass~%~
                           a=mid:0~%a=sctp-port:5000~%a=max-message-size:262144~%"
                        sid (ice-agent-port agent) (ice-agent-local-ip agent)
                        (%offer-candidates agent (%s-relay-only s))
                        (ice-agent-local-ufrag agent) (ice-agent-local-pwd agent)
                        (dtls-conn-fingerprint conn)))))
    ;; CRLF, as SDP is written on the wire (RFC 8866); our parser takes either.
    (with-output-to-string (o)
      (loop for c across sdp do (if (char= c #\Newline) (format o "~c~c" #\Return #\Newline)
                                    (write-char c o))))))

;;; ---- ICE: the controlling agent's checks ----------------------------------------------------

(defun %check-request (s)
  (let ((agent (%s-agent s)))
    (encode-stun +binding-request+ (stun-transaction-id)
                 (list (cons +attr-username+
                             (ascii (format nil "~a:~a" (ice-agent-remote-ufrag agent)
                                            (ice-agent-local-ufrag agent))))
                       (cons +attr-ice-controlling+ (%s-tiebreaker s))
                       (cons +attr-use-candidate+ (u8vec 0))
                       (cons +attr-priority+ (u32be 1845501695)))   ; a peer-reflexive host
                 :integrity-key (ice-agent-remote-pwd agent) :fingerprint t)))

(defun %ice-targets (agent)
  "The answer's candidates we can dial from an IPv4 socket: dotted IPv4 only (not mDNS names,
not IPv6), highest priority first."
  (sort (remove-if-not (lambda (c) (and (ice-candidate-ip c)
                                        (every (lambda (ch) (or (digit-char-p ch) (char= ch #\.)))
                                               (ice-candidate-ip c))
                                        (= 3 (count #\. (ice-candidate-ip c)))))
                       (copy-list (ice-agent-remote-candidates agent)))
        #'> :key (lambda (c) (or (ice-candidate-priority c) 0))))

(defun %send-to-candidate (agent bytes c &optional relay)
  "BYTES to candidate C: straight from our socket, or with RELAY through our TURN allocation (a
Send indication; the reply comes back as a Data indication and the ICE agent then answers on the
same path, so the selected route is the relay)."
  (ignore-errors
   (let ((host (sb-bsd-sockets:make-inet-address (ice-candidate-ip c))))
     (if relay
         (ice-send agent bytes :relay-send (cons host (ice-candidate-port c)))
         (ice-send agent bytes host (ice-candidate-port c))))))

(defun %session-checks (s)
  "Every 100 ms: a check to every candidate pair until one answers (the agent selects it on the
Binding success, or on the answerer's own check reaching us), then a few more to the selected
route, so a lost USE-CANDIDATE does not matter."
  (let ((agent (%s-agent s)) (now (get-internal-real-time)))
    (when (and (>= now (%s-checks-at s)) (plusp (%s-extra-checks s)))
      (setf (%s-checks-at s) (+ now (round internal-time-units-per-second 10)))
      (if (ice-agent-peer agent)
          (progn (decf (%s-extra-checks s))
                 (ignore-errors (ice-send-to-peer agent (%check-request s))))
          (dolist (c (%ice-targets agent))
            (%send-to-candidate agent (%check-request s) c (%s-relay-only s)))))))

;;; ---- the association, one pass at a time ------------------------------------------------------

(defun %dcep-open-message (ch)
  (let ((label (utf8 (%sch-label ch))) (proto (utf8 (%sch-protocol ch))))
    (cat-bytes (vector +dcep-open+ (if (%sch-ordered ch) #x00 #x80))
               (u16be 256) (u32be 0)                         ; priority; reliability parameter
               (u16be (length label)) (u16be (length proto)) label proto)))

(defun %has-record-type-p (dg type)
  (loop for pos = 0 then (+ pos 13 (rd-u16be dg (+ pos 11)))
        while (<= (+ pos 13) (length dg))
        thereis (= (aref dg pos) type)))

(defparameter *consent-interval* 4.0
  "Seconds between consent checks to the selected route (RFC 7675 says ~5 s, randomised).  They
are also what tells the answerer we are still here when the desktop is idle: a box measures its
peer's silence and closes a session that says nothing.")

(defun %session-step (s timeout)
  "One pass: inbound datagrams to SCTP (or, for a handshake record after we finished, to the DTLS
server, which resends our Finished), SCTP's timers, the INIT / COOKIE-ECHO retransmissions, and
consent.  Returns NIL to go on, or a reason the association is over."
  (let* ((conn (%s-conn s)) (session (dtls-conn-session conn)) (assoc (%s-assoc s))
         (agent (%s-agent s)))
    (let ((dg (dtls-conn-pop conn timeout)))
      (when dg
        (when (%has-record-type-p dg 22)
          (ignore-errors (seal:dtls-server-input session dg)))
        (dolist (pkt (seal:dtls-handle-datagram session dg))
          (handler-case (sctp-input assoc pkt)
            (error (e) (%plog s "sctp-input error: ~a" e))))))
    (when (> (%secs-since (%s-consent-at s)) *consent-interval*)
      (setf (%s-consent-at s) (get-internal-real-time))
      (ignore-errors (ice-send-to-peer agent (%check-request s))))
    (case (sctp-assoc-state assoc)
      ((:closed :cookie-wait :cookie-echoed)
       (when (> (%secs-since (%s-hs-at s)) (min 4.0 (* 0.5 (expt 2 (%s-hs-tries s)))))
         (when (> (incf (%s-hs-tries s)) 8)
           (return-from %session-step "SCTP: no answer to INIT"))
         (setf (%s-hs-at s) (get-internal-real-time))
         (sctp-resend-handshake assoc))
       nil)
      (:established
       (handler-case (sctp-tick assoc)
         (error (e) (%plog s "sctp-tick error: ~a" e)))
       nil)
      (:aborted "SCTP aborted"))))

;;; ---- the answer: ICE, DTLS, SCTP, DCEP -------------------------------------------------------

(defun %session-connect (s answer timeout)
  "Apply the answer SDP and connect -- ICE checks until a route answers, the DTLS handshake (we
are its server), the SCTP association (we initiate), and DCEP OPEN for every in-band channel --
all on this thread.  Signals WEBRTC-ERROR on failure or after TIMEOUT seconds."
  (let* ((sdp (parse-sdp answer)) (agent (%s-agent s)) (conn (%s-conn s))
         (session (dtls-conn-session conn))
         (deadline (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second)))))
    (flet ((remain () (max 0.01 (/ (float (- deadline (get-internal-real-time)) 1d0)
                                   internal-time-units-per-second)))
           (late-p () (>= (get-internal-real-time) deadline)))
      (unless (and (sdp-ice-ufrag sdp) (sdp-ice-pwd sdp))
        (werr "the answer has no ICE credentials"))
      (unless (member (sdp-setup sdp) '("active" nil) :test #'equal)
        ;; We offered actpass; an answer of passive would make us the DTLS client, which a box
        ;; never asks for.  Say so rather than handshake the wrong way round.
        (werr "the answer asks for a=setup:~a; this end only takes the DTLS server role"
              (sdp-setup sdp)))
      (setf (seal:dtls-expected-peer-fingerprint session) (sdp-fingerprint sdp))
      (ice-accept-remote agent :ufrag (sdp-ice-ufrag sdp) :pwd (sdp-ice-pwd sdp)
                               :candidates (sdp-candidates sdp))
      ;; Our TURN allocation (if any) must PERMIT the answerer's addresses before its checks or
      ;; its relayed packets can reach us.  Its upkeep needs no thread: in PULL mode ICE-POLL
      ;; refreshes the allocation, these permissions and any channel binding before they lapse
      ;; (cl-transport ice.lisp), and nothing else reads the socket, so ICE-CLOSE's release can
      ;; read its answer directly.
      (let ((alloc (ice-agent-turn agent)))
        (when alloc
          (dolist (ip (remove-duplicates (mapcar #'ice-candidate-ip (%ice-targets agent))
                                         :test #'equal))
            (ignore-errors (turn-create-permission alloc ip)))))
      (ice-serve agent :mode :pull)
      (loop until (ice-agent-peer agent)
            do (when (late-p) (werr "ICE: no route answered within ~as" timeout))
               (%session-checks s)
               (ice-poll agent :timeout 0.01))
      (%mark s :ice)
      (%plog s "ICE route ~a" (ice-agent-peer agent))
      ;; DTLS: the answerer is the client and speaks first.
      (let ((rtx-at nil))
        (flet ((arm () (setf rtx-at (+ (get-internal-real-time)
                                       (round (* (seal:dtls-server-timeout-seconds session)
                                                 internal-time-units-per-second))))))
          (arm)
          (loop until (seal:dtls-done session)
                do (when (late-p) (werr "DTLS: handshake not complete within ~as" timeout))
                   (%session-checks s)
                   (let ((dg (dtls-conn-pop conn (min (remain) 0.05))))
                     (cond (dg (seal:dtls-server-input session dg) (arm))
                           ((>= (get-internal-real-time) rtx-at)
                            (seal:dtls-server-retransmit session) (arm)))))))
      (let ((fp (seal:dtls-peer-fingerprint session)))
        (when (and (sdp-fingerprint sdp) (not (string-equal fp (sdp-fingerprint sdp))))
          (werr "DTLS: the answerer's certificate is not the one its SDP names")))
      (%mark s :dtls)
      (%plog s "DTLS up, cipher ~4,'0x" (seal:dtls-cipher session))
      ;; SCTP, initiated by us.
      (let ((assoc (make-sctp-assoc
                    :session session
                    :on-message (lambda (assoc sid payload)
                                  (declare (ignore assoc))
                                  (%emit s (list :data sid payload)))
                    :on-ack (lambda (assoc sid)
                              (declare (ignore assoc))
                              (let ((ch (find sid (%s-channels s) :key #'%sch-id)))
                                (when ch (setf (%sch-state ch) :open)))
                              (%emit s (list :chstate sid :open))))))
        (setf (%s-assoc s) assoc
              (sctp-assoc-state assoc) :cookie-wait
              (%s-hs-at s) (get-internal-real-time)
              (%s-consent-at s) (get-internal-real-time))
        (sctp-send-init assoc)
        (loop until (eq (sctp-assoc-state assoc) :established)
              do (when (late-p) (werr "SCTP association: timed out after ~as" timeout))
                 (%session-checks s)
                 (let ((why (%session-step s 0.02))) (when why (werr "SCTP association: ~a" why))))
        (%mark s :sctp)
        (%plog s "SCTP established")
        (dolist (ch (%s-channels s))
          (if (%sch-negotiated ch)
              (setf (%sch-state ch) :open)
              (sctp-send-data assoc (%sch-id ch) +ppid-dcep+ (%dcep-open-message ch))))
        (loop until (every (lambda (ch) (eq (%sch-state ch) :open)) (%s-channels s))
              do (when (late-p) (werr "DCEP: timed out after ~as" timeout))
                 (let ((why (%session-step s 0.02))) (when why (werr "DCEP: ~a" why))))
        (%mark s :open)
        (%plog s "~d channel~:p open" (length (%s-channels s)))))))

(defun %session-stats (s)
  (let ((agent (%s-agent s)) (assoc (%s-assoc s)))
    (append (and assoc (sctp-stats assoc))
            (and agent (list :route (ignore-errors (ice-route-label agent))
                             :route-kind (first (ice-agent-peer agent)))))))

(defun %session-command (s msg)
  "Act on one command from the caller.  Returns T if it ends the session."
  (let ((assoc (%s-assoc s)))
    (case (first msg)
      (:send (when (and assoc (eq (sctp-assoc-state assoc) :established))
               (destructuring-bind (sid data) (rest msg)
                 (if (stringp data)
                     (sctp-send-string assoc sid data)
                     (sctp-send-binary assoc sid data))))
             nil)
      (:stats (%emit s (list :stats (%session-stats s))) nil)
      (:close (unless (second msg)                ; not :ABORT -- say goodbye
                (when (and assoc (eq (sctp-assoc-state assoc) :established))
                  (ignore-errors (sctp-transmit assoc (sctp-chunk +chunk-abort+ 0 #())))))
              (unless (%s-reason s) (setf (%s-reason s) :closed-here))
              t)
      (t nil))))

(defun %session-commands (s)
  "Every command the caller has sent, in order.  T if one ended the session."
  (loop (multiple-value-bind (msg ok) (cl-transport.chan:chan-try-receive (%s-commands s))
          (unless ok (return nil))
          (when (%session-command s msg) (return t)))))

(defun %client-session-main (events commands channel-specs opts)
  "The session thread: gather, offer, take the answer, connect, then serve the association until
the caller closes it or the peer goes -- all of it on this thread.  Talks to the caller only
through EVENTS and COMMANDS (see the file header)."
  (destructuring-bind (&key local-ip gather-srflx gather-relay relay-only (timeout 30.0) log
                       &allow-other-keys)
      opts
    (let ((s (%make-session :events events :commands commands :log log
                            :channels (mapcar (lambda (c) (apply #'%make-sch c)) channel-specs))))
      (handler-case
          (block session
            (%session-gather s :local-ip local-ip :gather-srflx gather-srflx
                               :gather-relay gather-relay :relay-only relay-only)
            (%emit s (list :offer (%session-offer s)))
            ;; the caller's signalling may take minutes (a box over nostr relays)
            (let ((answer nil))
              (loop until answer
                    do (%flush-backlog s)
                       (multiple-value-bind (msg ok)
                           (cl-transport.chan:chan-receive commands :timeout 0.1)
                         (when ok
                           (case (first msg)
                             (:answer (setf answer (second msg)))
                             (:close (setf (%s-reason s) :closed-here) (return-from session))
                             (:stats (%emit s (list :stats (%session-stats s))))))))
              (%session-connect s answer timeout))
            (%emit s (list :open (seal:dtls-peer-fingerprint (dtls-conn-session (%s-conn s)))))
            (loop
              (%flush-backlog s)
              (when (%session-commands s) (return))
              (let ((why (%session-step s 0.01)))
                (when why (setf (%s-reason s) why) (return)))))
        (error (e)
          (setf (%s-reason s) (princ-to-string e))
          (%emit s (list :error (%s-reason s)))))
      (when (%s-agent s) (ignore-errors (ice-close (%s-agent s))))
      ;; The last word: it must reach the caller, so wait for room (the caller drains as it waits).
      (%emit s (list :closed (or (%s-reason s) :done) (ignore-errors (%session-stats s))))
      (%flush-backlog s 10))))
