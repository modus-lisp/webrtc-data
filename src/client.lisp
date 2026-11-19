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
;;;; THREADS, like the threaded answerer (WEBRTC-DTLS-RUN + WEBRTC-SERVE-DATACHANNEL): the ICE
;;;; receive thread, a check thread while ICE is choosing, the caller's thread for the DTLS
;;;; handshake, then one association thread (SCTP input, its timers, consent).  An event-loop
;;;; driver (as loop.lisp is for the answerer) is not written yet.
;;;;
;;;; A CHANNEL IS A BYTE STREAM when you want one: RTC-CHANNEL-STREAM is a Gray binary stream whose
;;;; READ-SEQUENCE fills completely (CL semantics, so a protocol reader such as an RFB client can
;;;; sit on it as on a socket), and whose FORCE-OUTPUT sends what was written as one message.

(in-package #:webrtc-data)

;;; ---- the channel --------------------------------------------------------------------------

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
   (inpos :initform 0 :accessor %chan-inpos)
   (lock :initform (bt:make-lock "rtc-channel") :reader %chan-lock)
   (cvar :initform (bt:make-condition-variable) :reader %chan-cvar))
  (:documentation "One data channel of an RTC-PEER: a label and an SCTP stream id."))

(defmethod print-object ((c rtc-channel) s)
  (print-unreadable-object (c s :type t)
    (format s "~s id ~d ~(~a~)" (channel-label c) (channel-id c) (channel-state c))))

(defun %channel-deliver (ch payload)
  "An inbound message on CH: to its ON-MESSAGE if it has one, else queued for the stream view."
  (if (channel-on-message ch)
      (funcall (channel-on-message ch) ch payload)
      (let ((bytes (if (stringp payload) (utf8 payload) (as-u8vec payload))))
        (when (plusp (length bytes))
          (bt:with-lock-held ((%chan-lock ch))
            (let ((cell (list bytes)))
              (if (%chan-inq-tail ch)
                  (setf (cdr (%chan-inq-tail ch)) cell)
                  (setf (%chan-inq ch) cell))
              (setf (%chan-inq-tail ch) cell))
            (bt:condition-notify (%chan-cvar ch)))))))

(defun %channel-eof (ch)
  (bt:with-lock-held ((%chan-lock ch))
    (setf (channel-state ch) :closed)
    (sb-thread:condition-broadcast (%chan-cvar ch))))

(defun channel-send (ch data)
  "Send DATA on CH as one message: a string as PPID 51 (UTF-8), octets as PPID 53."
  (let ((assoc (peer-assoc (channel-peer ch))))
    (unless (and assoc (eq (sctp-assoc-state assoc) :established))
      (werr "channel ~s: the association is not up" (channel-label ch)))
    (if (stringp data)
        (sctp-send-string assoc (channel-id ch) data)
        (sctp-send-binary assoc (channel-id ch) data))))

(defun channel-read (ch buf &key (start 0) (end (length buf)) (wait t))
  "Copy queued inbound bytes of CH into BUF[START,END): at least one unless WAIT is NIL (blocks
for the first).  Returns the index after the last byte copied; START means EOF (or nothing,
with WAIT NIL)."
  (bt:with-lock-held ((%chan-lock ch))
    (loop while (and wait (null (%chan-inq ch)) (not (eq (channel-state ch) :closed)))
          do (bt:condition-wait (%chan-cvar ch) (%chan-lock ch)))
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
      i)))

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
    (bt:with-lock-held ((%chan-lock ch)) (and (%chan-inq ch) t))))

(defun %stream-flush (s)
  (with-slots (wbuf wlock channel) s
    (bt:with-lock-held (wlock)
      (when (plusp (fill-pointer wbuf))
        (let ((msg (subseq wbuf 0)))
          (setf (fill-pointer wbuf) 0)
          (unless (eq (channel-state channel) :closed)
            (channel-send channel (coerce msg '(simple-array (unsigned-byte 8) (*))))))))))

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
  (%channel-eof (stream-channel s))
  t)

;;; ---- the peer -----------------------------------------------------------------------------

(defclass rtc-peer ()
  ((agent :initarg :agent :reader peer-agent)
   (conn :initarg :conn :reader peer-conn)                     ; a DTLS-CONN (dtls.lisp)
   (assoc :initform nil :accessor peer-assoc)
   (channels :initform '() :accessor peer-channels)
   (next-sid :initform 1 :accessor %peer-next-sid)             ; DTLS server: odd ids (RFC 8832)
   (state :initform :new :accessor peer-state)    ; :new :offered :connecting :open :closed
   (reason :initform nil :accessor peer-reason)                ; why it closed
   (stop :initform nil :accessor %peer-stop)
   (closing :initform nil :accessor %peer-closing)              ; RTC-CLOSE has begun
   (relay-only :initarg :relay-only :initform nil :reader peer-relay-only)
   (thread :initform nil :accessor %peer-thread)
   (checks :initform nil :accessor %peer-checks)
   (tiebreaker :initform (random-bytes 8) :reader %peer-tiebreaker)
   (offer :initform nil :accessor peer-offer)
   (remote-fingerprint :initform nil :accessor peer-remote-fingerprint)
   (on-close :initarg :on-close :initform nil :accessor peer-on-close)
   (log :initarg :log :initform nil :reader peer-log)
   (lock :initform (bt:make-lock "rtc-peer") :reader %peer-lock)
   (cvar :initform (bt:make-condition-variable) :reader %peer-cvar)
   (timings :initform '() :accessor peer-timings)              ; ((:what . seconds) ...)
   (t0 :initform (get-internal-real-time) :reader %peer-t0))
  (:documentation "The calling end of one WebRTC data-channel session."))

(defmethod print-object ((p rtc-peer) s)
  (print-unreadable-object (p s :type t)
    (format s "~(~a~) ~d channel~:p" (peer-state p) (length (peer-channels p)))))

(defun %plog (peer fmt &rest args)
  (let ((out (peer-log peer)))
    (when out (format out "~&[rtc ~,2fs] ~?~%" (%secs-since (%peer-t0 peer)) fmt args)
          (finish-output out))))

(defun %secs-since (t0) (/ (float (- (get-internal-real-time) t0) 1d0) internal-time-units-per-second))

(defun %mark (peer what)
  (push (cons what (%secs-since (%peer-t0 peer))) (peer-timings peer)))

(defun make-rtc-peer (&key local-ip gather-srflx gather-relay log on-close relay-only)
  "Bind a UDP socket and gather candidates for a new calling session (blocking, as the phone
gathers before it offers).  GATHER-SRFLX asks a STUN server for our public mapping
(*STUN-SERVERS*); GATHER-RELAY allocates a TURN relay -- T for env TURN_SERVER/USER/PASS, or a
plist (:server \"host:port\" :user :pass).  LOCAL-IP is the host candidate's address (default:
the primary IPv4, or env ICE_LOCAL_IP).  RELAY-ONLY is a browser's iceTransportPolicy \"relay\":
only the relay candidate is offered and every check (so every packet) goes through the TURN
allocation -- what a phone on a hard NAT ends up using.  Declare channels with
RTC-CREATE-CHANNEL, then RTC-OFFER."
  (let* ((agent (make-ice :local-ip (or local-ip (uiop:getenv "ICE_LOCAL_IP"))))
         (conn (webrtc-dtls-setup agent))
         (peer (make-instance 'rtc-peer :agent agent :conn conn :log log :on-close on-close
                                        :relay-only relay-only)))
    (when gather-srflx (ice-gather-srflx agent))
    (when (or gather-relay relay-only)
      (apply #'ice-gather-relay agent (if (listp gather-relay) gather-relay '())))
    (when (and relay-only (null (ice-agent-relay-ip agent)))
      (ice-close agent)
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
    (%mark peer :gathered)
    peer))

(defun rtc-create-channel (peer label &key id (negotiated (and id t)) (ordered t) (protocol "")
                                           on-message)
  "Declare a data channel on PEER before the offer -- as the phone must, the signalling being
one-shot.  NEGOTIATED (with ID) is a channel both ends already agree on: nothing is sent to open
it.  Otherwise it is opened in-band by DCEP once the association is up, on the next odd stream id
unless ID says which.  ON-MESSAGE (channel payload), if given, receives every inbound message;
without it they queue for RTC-CHANNEL-STREAM / CHANNEL-READ.  Returns the RTC-CHANNEL."
  (when (and negotiated (null id)) (werr "a negotiated channel needs an :id"))
  (let* ((sid (or id (prog1 (%peer-next-sid peer) (incf (%peer-next-sid peer) 2))))
         (ch (make-instance 'rtc-channel :peer peer :label label :id sid :negotiated negotiated
                                         :ordered ordered :protocol protocol :on-message on-message)))
    (when (find sid (peer-channels peer) :key #'channel-id)
      (werr "stream id ~d is already channel ~s" sid
            (channel-label (find sid (peer-channels peer) :key #'channel-id))))
    (setf (peer-channels peer) (append (peer-channels peer) (list ch)))
    ch))

(defun rtc-channel (peer label-or-id)
  "PEER's channel by label (a string) or stream id."
  (find label-or-id (peer-channels peer)
        :key (if (stringp label-or-id) #'channel-label #'channel-id) :test #'equal))

;;; ---- the offer ----------------------------------------------------------------------------

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

(defun rtc-offer (peer)
  "PEER's offer SDP: one bundled m=application (webrtc-datachannel, sctp-port 5000) with every
gathered candidate, our ICE credentials, our certificate's fingerprint and a=setup:actpass.  The
channels must already be declared; nothing about them is in the SDP (the in-band ones are
opened by DCEP, the negotiated ones are agreed out of band), as in a browser's offer."
  (let* ((agent (peer-agent peer)) (conn (peer-conn peer))
         (sid (format nil "~d" (logand (rd-u32be (random-bytes 4) 0) #x7fffffff)))
         (sdp (with-output-to-string (o)
                (format o "v=0~%o=- ~a 2 IN IP4 127.0.0.1~%s=-~%t=0 0~%a=group:BUNDLE 0~%~
                           a=msid-semantic: WMS~%~
                           m=application ~d UDP/DTLS/SCTP webrtc-datachannel~%c=IN IP4 ~a~%~a~
                           a=ice-ufrag:~a~%a=ice-pwd:~a~%a=fingerprint:sha-256 ~a~%a=setup:actpass~%~
                           a=mid:0~%a=sctp-port:5000~%a=max-message-size:262144~%"
                        sid (ice-agent-port agent) (ice-agent-local-ip agent)
                        (%offer-candidates agent (peer-relay-only peer))
                        (ice-agent-local-ufrag agent) (ice-agent-local-pwd agent)
                        (dtls-conn-fingerprint conn)))))
    ;; CRLF, as SDP is written on the wire (RFC 8866); our parser takes either.
    (setf sdp (with-output-to-string (o)
                (loop for c across sdp do (if (char= c #\Newline) (format o "~c~c" #\Return #\Newline)
                                              (write-char c o))))
          (peer-offer peer) sdp
          (peer-state peer) :offered)
    sdp))

;;; ---- ICE: the controlling agent's checks ----------------------------------------------------

(defun %check-request (peer)
  (let ((agent (peer-agent peer)))
    (encode-stun +binding-request+ (stun-transaction-id)
                 (list (cons +attr-username+
                             (ascii (format nil "~a:~a" (ice-agent-remote-ufrag agent)
                                            (ice-agent-local-ufrag agent))))
                       (cons +attr-ice-controlling+ (%peer-tiebreaker peer))
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

(defun %start-checks (peer &key (interval 0.1) (duration 30.0))
  "Check every candidate pair until one answers (the ICE agent selects it on the Binding
success, or on the answerer's own check reaching us), then keep nominating that route for a
moment so a lost USE-CANDIDATE does not matter."
  (let ((agent (peer-agent peer)))
    (setf (%peer-checks peer)
          (bt:make-thread
           (lambda ()
             (let ((deadline (+ (get-internal-real-time)
                                (round (* duration internal-time-units-per-second))))
                   (extra 5))
               (loop until (or (%peer-stop peer) (>= (get-internal-real-time) deadline)
                               (minusp extra))
                     do (if (ice-agent-peer agent)
                            (progn (decf extra)
                                   (ignore-errors (ice-send-to-peer agent (%check-request peer))))
                            (dolist (c (%ice-targets agent))
                              (%send-to-candidate agent (%check-request peer) c
                                                  (peer-relay-only peer))))
                        (sleep interval))))
           :name "rtc-ice-checks"))))

;;; ---- the answer: ICE, DTLS, SCTP, DCEP -------------------------------------------------------

(defun %dcep-open-message (ch)
  (let ((label (utf8 (channel-label ch))) (proto (utf8 (channel-protocol ch))))
    (cat-bytes (vector +dcep-open+ (if (channel-ordered-p ch) #x00 #x80))
               (u16be 256) (u32be 0)                         ; priority; reliability parameter
               (u16be (length label)) (u16be (length proto)) label proto)))

(defun %peer-wait (peer pred timeout what)
  "Wait on PEER's condition variable until PRED is true; WEBRTC-ERROR naming WHAT on timeout."
  (let ((deadline (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second)))))
    (bt:with-lock-held ((%peer-lock peer))
      (loop until (funcall pred)
            do (when (member (peer-state peer) '(:closed))
                 (werr "~a: the session closed (~a)" what (peer-reason peer)))
               (let ((remain (/ (float (- deadline (get-internal-real-time)) 1d0)
                                internal-time-units-per-second)))
                 (when (<= remain 0) (werr "~a: timed out after ~as" what timeout))
                 (bt:condition-wait (%peer-cvar peer) (%peer-lock peer) :timeout (min 0.25 remain)))))))

(defun %peer-notify (peer)
  (bt:with-lock-held ((%peer-lock peer)) (sb-thread:condition-broadcast (%peer-cvar peer))))

(defun %has-record-type-p (dg type)
  (loop for pos = 0 then (+ pos 13 (rd-u16be dg (+ pos 11)))
        while (<= (+ pos 13) (length dg))
        thereis (= (aref dg pos) type)))

(defparameter *consent-interval* 4.0
  "Seconds between consent checks to the selected route (RFC 7675 says ~5 s, randomised).  They
are also what tells the answerer we are still here when the desktop is idle: a box measures its
peer's silence and closes a session that says nothing.")

(defun %association-loop (peer)
  "The association thread: inbound datagrams to SCTP (or, for a handshake record after we
finished, to the DTLS server, which resends our Finished), SCTP's timers, the INIT /
COOKIE-ECHO retransmissions, and consent checks.  Ends on RTC-CLOSE, an ABORT, or a dead peer."
  (let* ((conn (peer-conn peer)) (session (dtls-conn-session conn)) (mb (dtls-conn-mailbox conn))
         (agent (peer-agent peer)) (assoc (peer-assoc peer))
         (hs-at (get-internal-real-time)) (hs-tries 0)
         (consent-at (get-internal-real-time)))
    (handler-case
        (loop until (%peer-stop peer)
              do (let ((dg (mailbox-pop mb 0.05)))
                   (when dg
                     (when (%has-record-type-p dg 22)
                       (ignore-errors (seal:dtls-server-input session dg)))
                     (dolist (pkt (seal:dtls-handle-datagram session dg))
                       (let ((was (sctp-assoc-state assoc)))
                         (handler-case (sctp-input assoc pkt)
                           (error (e) (%plog peer "sctp-input error: ~a" e)))
                         (unless (eq was (sctp-assoc-state assoc)) (%peer-notify peer))))))
                 (case (sctp-assoc-state assoc)
                   ((:closed :cookie-wait :cookie-echoed)
                    (when (> (%secs-since hs-at) (min 4.0 (* 0.5 (expt 2 hs-tries))))
                      (when (> (incf hs-tries) 8)
                        (setf (peer-reason peer) "SCTP: no answer to INIT")
                        (return))
                      (setf hs-at (get-internal-real-time))
                      (sctp-resend-handshake assoc)))
                   (:established
                    (handler-case (sctp-tick assoc)
                      (error (e) (%plog peer "sctp-tick error: ~a" e))))
                   (:aborted (setf (peer-reason peer) "SCTP aborted") (return)))
                 (when (> (%secs-since consent-at) *consent-interval*)
                   (setf consent-at (get-internal-real-time))
                   (ignore-errors (ice-send-to-peer agent (%check-request peer)))))
      (error (e) (setf (peer-reason peer) (princ-to-string e))))
    (%peer-closed peer)))

(defun %peer-closed (peer)
  "Mark PEER closed (once), EOF its channels, wake every waiter, and run ON-CLOSE."
  (let ((first nil))
    (bt:with-lock-held ((%peer-lock peer))
      (unless (eq (peer-state peer) :closed)
        (setf (peer-state peer) :closed first t)
        (unless (peer-reason peer) (setf (peer-reason peer) :done)))
      (sb-thread:condition-broadcast (%peer-cvar peer)))
    (when first
      (dolist (ch (peer-channels peer)) (%channel-eof ch))
      (%plog peer "closed: ~a" (peer-reason peer))
      (when (peer-on-close peer) (ignore-errors (funcall (peer-on-close peer) peer (peer-reason peer)))))))

(defun rtc-accept-answer (peer answer &key (timeout 30.0))
  "Apply the answer SDP (a string) to PEER and connect: ICE checks until a route answers, the
DTLS handshake (we are its server), the SCTP association (we initiate), and DCEP OPEN for every
in-band channel -- returning once each of those is ACKed, every channel open.  Signals
WEBRTC-ERROR on failure or after TIMEOUT seconds; PEER is then closed."
  (let* ((sdp (parse-sdp answer)) (agent (peer-agent peer)) (conn (peer-conn peer))
         (session (dtls-conn-session conn))
         (deadline (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second)))))
    (flet ((remain () (max 0.1 (/ (float (- deadline (get-internal-real-time)) 1d0)
                                  internal-time-units-per-second))))
      (handler-bind ((error (lambda (e)
                              (setf (peer-reason peer) (princ-to-string e))
                              (rtc-close peer :abort t))))
        (unless (and (sdp-ice-ufrag sdp) (sdp-ice-pwd sdp))
          (werr "the answer has no ICE credentials"))
        (unless (member (sdp-setup sdp) '("active" nil) :test #'equal)
          ;; We offered actpass; an answer of passive would make us the DTLS client, which a box
          ;; never asks for.  Say so rather than handshake the wrong way round.
          (werr "the answer asks for a=setup:~a; this end only takes the DTLS server role"
                (sdp-setup sdp)))
        (setf (peer-state peer) :connecting
              (peer-remote-fingerprint peer) (sdp-fingerprint sdp)
              (seal:dtls-expected-peer-fingerprint session) (sdp-fingerprint sdp))
        (ice-accept-remote agent :ufrag (sdp-ice-ufrag sdp) :pwd (sdp-ice-pwd sdp)
                                 :candidates (sdp-candidates sdp))
        ;; Our TURN allocation (if any) must PERMIT the answerer's addresses before its checks or
        ;; its relayed packets can reach us -- before ICE-SERVE, because these read the socket.
        (let ((alloc (ice-agent-turn agent)))
          (when alloc
            (dolist (ip (remove-duplicates (mapcar #'ice-candidate-ip (%ice-targets agent))
                                           :test #'equal))
              (ignore-errors (turn-create-permission alloc ip)))
            (ignore-errors (turn-start-refresh alloc (lambda () (%peer-stop peer))))))
        (ice-serve agent)
        (%start-checks peer)
        (loop until (ice-agent-peer agent)
              do (when (<= (remain) 0.1) (werr "ICE: no route answered within ~as" timeout))
                 (sleep 0.01))
        (%mark peer :ice)
        (%plog peer "ICE route ~a" (ice-agent-peer agent))
        ;; DTLS: the answerer is the client and speaks first.
        (let ((mb (dtls-conn-mailbox conn)))
          (loop until (seal:dtls-done session)
                do (when (<= (remain) 0.1) (werr "DTLS: handshake not complete within ~as" timeout))
                   (let ((dg (mailbox-pop mb (min (remain) (seal:dtls-server-timeout-seconds session)))))
                     (if dg
                         (seal:dtls-server-input session dg)
                         (seal:dtls-server-retransmit session)))))
        (let ((fp (seal:dtls-peer-fingerprint session)))
          (when (and (sdp-fingerprint sdp) (not (string-equal fp (sdp-fingerprint sdp))))
            (werr "DTLS: the answerer's certificate is not the one its SDP names")))
        (%mark peer :dtls)
        (%plog peer "DTLS up, cipher ~4,'0x" (seal:dtls-cipher session))
        ;; SCTP, initiated by us, on the association thread.
        (let ((assoc (make-sctp-assoc
                      :session session :log (peer-log peer)
                      :on-message (lambda (assoc sid payload)
                                    (declare (ignore assoc))
                                    (let ((ch (rtc-channel peer sid)))
                                      (when ch (%channel-deliver ch payload))))
                      :on-ack (lambda (assoc sid)
                                (declare (ignore assoc))
                                (let ((ch (rtc-channel peer sid)))
                                  (when ch (setf (channel-state ch) :open)))
                                (%peer-notify peer)))))
          (setf (peer-assoc peer) assoc
                (sctp-assoc-state assoc) :cookie-wait)
          (sctp-send-init assoc)
          (setf (%peer-thread peer)
                (bt:make-thread (lambda () (%association-loop peer)) :name "rtc-association"))
          (%peer-wait peer (lambda () (eq (sctp-assoc-state assoc) :established)) (remain)
                      "SCTP association")
          (%mark peer :sctp)
          (%plog peer "SCTP established")
          (dolist (ch (peer-channels peer))
            (if (channel-negotiated-p ch)
                (setf (channel-state ch) :open)
                (sctp-send-data assoc (channel-id ch) +ppid-dcep+ (%dcep-open-message ch))))
          (%peer-wait peer (lambda () (every (lambda (ch) (eq (channel-state ch) :open))
                                             (peer-channels peer)))
                      (remain) "DCEP")
          (%mark peer :open)
          (setf (peer-state peer) :open)
          (%plog peer "~d channel~:p open" (length (peer-channels peer)))
          peer)))))

(defun rtc-close (peer &key abort)
  "End PEER: an SCTP ABORT tells the answerer at once (rather than after its silence timeout),
then the threads stop and the socket -- and any TURN allocation -- is released.  ABORT skips the
goodbye (used on a failed connect).  Safe from several threads at once: the first does the
work, the others return (a viewer's reader and its closer both hang up)."
  (unless (bt:with-lock-held ((%peer-lock peer))
            (unless (%peer-closing peer) (setf (%peer-closing peer) t)))
    (return-from rtc-close peer))
  (unless (eq (peer-state peer) :closed)
    (let ((assoc (peer-assoc peer)))
      (when (and assoc (not abort) (eq (sctp-assoc-state assoc) :established))
        (ignore-errors (sctp-transmit assoc (sctp-chunk +chunk-abort+ 0 #())))))
    (unless (peer-reason peer) (setf (peer-reason peer) :closed-here)))
  (setf (%peer-stop peer) t)
  (let ((thr (%peer-thread peer)))
    (when (and thr (not (eq thr (bt:current-thread))))
      (ignore-errors (bt:join-thread thr))))
  (%peer-closed peer)
  ;; Release the TURN allocation (Refresh, lifetime 0) THROUGH the receive thread, then forget it
  ;; so ICE-CLOSE does not do it again its own way: that reads the socket directly, racing the
  ;; receive thread for the reply -- and a SOCKET-RECEIVE that loses the race blocks for ever (it
  ;; hung this close about one time in six).
  (let* ((agent (peer-agent peer)) (alloc (ice-agent-turn agent)))
    (when alloc
      (ignore-errors (cl-transport.ice::turn-refresh-via-loop alloc :lifetime 0 :timeout 1.0))
      (setf (ice-agent-turn agent) nil))
    (ignore-errors (ice-close agent)))
  peer)

(defun rtc-open-p (peer) (eq (peer-state peer) :open))

;;; ---- one call -------------------------------------------------------------------------------

(defun connect-peer (signal-fn &key channels local-ip gather-srflx gather-relay (timeout 30.0)
                                    log on-close relay-only)
  "Dial: gather, offer, have SIGNAL-FN deliver the offer and return the answer, connect.
SIGNAL-FN is called with the offer SDP (a string) and returns the answer SDP, or NIL for no
answer.  CHANNELS is a list of (LABEL &key ID NEGOTIATED ORDERED PROTOCOL ON-MESSAGE) specs,
declared before the offer.  Returns the open RTC-PEER (its channels by RTC-CHANNEL, as streams
by RTC-CHANNEL-STREAM); signals WEBRTC-ERROR.  RELAY-ONLY: see MAKE-RTC-PEER."
  (let ((peer (make-rtc-peer :local-ip local-ip :gather-srflx gather-srflx
                             :gather-relay gather-relay :log log :on-close on-close
                             :relay-only relay-only)))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (rtc-close peer :abort t))))
      (dolist (spec channels) (apply #'rtc-create-channel peer spec))
      (let ((answer (funcall signal-fn (rtc-offer peer))))
        (%mark peer :answered)
        (unless answer (werr "no answer"))
        (rtc-accept-answer peer answer :timeout timeout)))))
