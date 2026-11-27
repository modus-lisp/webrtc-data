;;;; src/transport.lisp — webrtc-data as a cl-transport INBOUND backend (:webrtc).
;;;;
;;;; Loading this file registers :WEBRTC with cl-transport, so any modus-lisp code can accept
;;;; WebRTC data-channel connections through the uniform EXPOSE interface, exactly like :tcp
;;;; (built in) and :frp (via cl-frpc):
;;;;
;;;;   (cl-transport:expose handler :backend :webrtc :signal-port 8766)
;;;;
;;;; A peer POSTs its SDP offer to /signal; we run the webrtc-data answerer (ICE -> DTLS ->
;;;; SCTP/DCEP) and, when the data channel opens, hand HANDLER a binary stream + peer plist —
;;;; the caller reads/writes it like a TCP socket stream and never branches on the backend.
;;;;
;;;; Two parts:
;;;;   1. WEBRTC-CHANNEL-STREAM — a Gray binary stream over the data channel: inbound messages
;;;;      are concatenated into a read buffer (blocking reads); outbound bytes are buffered and
;;;;      flushed as chunked messages.
;;;;   2. %WEBRTC-EXPOSE — the :webrtc backend fn: an HTTP POST /signal endpoint that
;;;;      drives the answerer per peer and delivers each open channel to ON-CONNECTION.
;;;;
;;;; THE THREADS SHARE NOTHING.  Each piece of a session is OWNED by one thread, and what crosses
;;;; between threads is COPIED, through CL-TRANSPORT.CHAN channels:
;;;;
;;;;   HTTP handler   (an http-server connection thread) receives the offer, starts the SESSION
;;;;                  thread on a NAMED function with the offer STRING and a slot's channels as
;;;;                  :ARGUMENTS, and waits on the slot's REPLY channel for the answer SDP.
;;;;   session        builds the ICE agent, the DTLS connection and the SCTP association in its
;;;;                  own heap, and reads the UDP socket itself (ICE PULL mode: no receive
;;;;                  thread).  It sends the answer back on REPLY, and when the data channel
;;;;                  opens starts the APPLICATION thread, again on a named function.
;;;;   application    builds its own WEBRTC-CHANNEL-STREAM over the slot's IN and OUT channels
;;;;                  and runs ON-CONNECTION.  Reads take messages from IN; writes send to OUT,
;;;;                  which the session drains into SCTP on every pass of its loop.  EOF and
;;;;                  close are messages too (:EOF on IN, :CLOSE on OUT).
;;;;
;;;; This is the shape that works on modus, where a thread may not store an object it made into
;;;; memory another thread made: a handler thread that built the agent could not hand a session
;;;; thread a closure over it, and a reader thread could not push datagrams onto a session's
;;;; queue.  SBCL runs exactly the same threads and channels (a CHAN there is a locked queue of
;;;; copies), so there is one design to test.
;;;;
;;;; ON-CONNECTION is the caller's function, called on the application thread.  On modus it must
;;;; be a global function or a closure made on the thread that called EXPOSE (normally the main
;;;; thread) -- a closure a worker thread made cannot be handed to another thread there -- and
;;;; what it keeps from a session it must keep in its own heap or send somewhere by copy.
;;;;
;;;; cl-transport stays OUT of core webrtc-data's deps — this is an optional integration
;;;; system (webrtc-data/transport), modeled on cl-frpc's :frp provider.

(in-package #:webrtc-data-transport)

;;; ---------------------------------------------------------------------------
;;; 1. A Gray binary stream over the data channel, on the application's thread.
;;;
;;; The data channel is message-oriented; this stream presents it as a plain byte stream.
;;; Inbound messages (octet vectors on IN) are appended to a read buffer that blocking reads
;;; drain; :EOF on IN ends it.  Outbound writes are buffered and sent to OUT as octet vectors of
;;; at most +CHUNK+ bytes, each of which the session sends as one SCTP message; CLOSE sends
;;; :CLOSE.  Everything here belongs to the one thread that made the stream.
;;; ---------------------------------------------------------------------------

(defconstant +chunk+ 1024
  "Max bytes per outbound SCTP message: our SCTP doesn't fragment, so flush in <=1KB chunks.")

(defconstant +chan-bytes+ (* 256 1024)
  "Capacity of each of a session slot's IN and OUT channels, in bytes.")

(defclass webrtc-channel-stream (sb-gray:fundamental-binary-input-stream
                                 sb-gray:fundamental-binary-output-stream)
  ((in   :initarg :in   :reader chs-in)          ; CHAN: octet vectors from the peer, then :EOF
   (out  :initarg :out  :reader chs-out)         ; CHAN: octet vectors to the peer, then :CLOSE
   (peer :initarg :peer :initform nil :reader chs-peer)
   ;; read side: bytes from RPOS (next unread) to the fill pointer of RBUF.
   (rbuf   :initform (make-array 4096 :element-type '(unsigned-byte 8)
                                      :adjustable t :fill-pointer 0))
   (rpos   :initform 0)
   (eof    :initform nil)                        ; :EOF arrived: what is buffered is all there is
   (closed :initform nil)                        ; CLOSE was called here
   ;; write side: bytes buffered until force/finish-output (or a full chunk) flushes them.
   (wbuf   :initform (make-array +chunk+ :element-type '(unsigned-byte 8)
                                         :adjustable t :fill-pointer 0))))

(defmethod stream-element-type ((s webrtc-channel-stream))
  '(unsigned-byte 8))

;;; --- read side --------------------------------------------------------------

(defun %chs-take (s msg)
  "File one message from IN: an octet vector joins the read buffer, :EOF ends the stream."
  (with-slots (rbuf rpos eof) s
    (cond ((eq msg :eof) (setf eof t))
          ((vectorp msg)
           (when (>= rpos (fill-pointer rbuf)) (setf (fill-pointer rbuf) 0 rpos 0))
           (loop for b across msg do (vector-push-extend b rbuf))))))

(defun %chs-available (s)
  (with-slots (rbuf rpos) s (- (fill-pointer rbuf) rpos)))

(defun %chs-wait-readable (s)
  "Block until >=1 byte is readable or the channel ended: T if bytes are available, NIL on EOF."
  (with-slots (eof closed in) s
    (loop
      (when (plusp (%chs-available s)) (return t))
      (when (or eof closed) (return nil))
      (multiple-value-bind (msg ok) (bob:channel-receive in :timeout 1)
        (when ok (%chs-take s msg))))))

(defmethod sb-gray:stream-read-byte ((s webrtc-channel-stream))
  (with-slots (rbuf rpos) s
    (if (%chs-wait-readable s)
        (prog1 (aref rbuf rpos) (incf rpos))
        :eof)))

(defmethod sb-gray:stream-listen ((s webrtc-channel-stream))
  (with-slots (in eof closed) s
    (loop until (or eof closed (plusp (%chs-available s)))
          do (multiple-value-bind (msg ok) (bob:channel-try-receive in)
               (if ok (%chs-take s msg) (return))))
    (plusp (%chs-available s))))

(defmethod sb-gray:stream-read-sequence
    ((s webrtc-channel-stream) seq &optional (start 0) end)
  "Socket-style partial read: block until >=1 byte or EOF, then copy as many buffered bytes as
fit (never waiting to fill).  Returns the index of the first element not written (= START on
EOF).  Callers loop like they would on a TCP socket."
  (let ((end (or end (length seq))))
    (with-slots (rbuf rpos) s
      (if (%chs-wait-readable s)
          (let ((n (min (- end start) (%chs-available s))))
            (replace seq rbuf :start1 start :end1 (+ start n) :start2 rpos)
            (incf rpos n)
            (+ start n))
          start))))

;;; --- write side -------------------------------------------------------------

(defun %chs-send (s msg)
  "MSG onto OUT.  A full OUT waits for the session to drain it -- unless the session has ended
(:EOF on IN), when there is nobody to drain it and the message is dropped (NIL)."
  (with-slots (out in eof) s
    (loop
      (when (bob:channel-send out msg :timeout 1) (return t))
      (loop (multiple-value-bind (m ok) (bob:channel-try-receive in)
              (if ok (%chs-take s m) (return))))
      (when eof (return nil)))))

(defun %chs-flush (s)
  "Send the write buffer to OUT as messages of at most +CHUNK+ bytes and clear it."
  (with-slots (wbuf eof) s
    (let ((n (fill-pointer wbuf)))
      (when (and (plusp n) (not eof))
        (loop for off from 0 below n by +chunk+
              do (%chs-send s (subseq wbuf off (min n (+ off +chunk+))))))
      (setf (fill-pointer wbuf) 0))))

(defmethod sb-gray:stream-write-byte ((s webrtc-channel-stream) byte)
  (with-slots (wbuf) s
    (vector-push-extend byte wbuf)
    (when (>= (fill-pointer wbuf) +chunk+) (%chs-flush s)))
  byte)

(defmethod sb-gray:stream-write-sequence
    ((s webrtc-channel-stream) seq &optional (start 0) end)
  (let ((end (or end (length seq))))
    (with-slots (wbuf) s
      (loop for i from start below end do (vector-push-extend (elt seq i) wbuf))
      (when (>= (fill-pointer wbuf) +chunk+) (%chs-flush s))))
  seq)

(defmethod sb-gray:stream-force-output ((s webrtc-channel-stream)) (%chs-flush s) nil)
(defmethod sb-gray:stream-finish-output ((s webrtc-channel-stream)) (%chs-flush s) nil)

(defmethod close ((s webrtc-channel-stream) &key abort)
  "Flush (unless ABORT) and tell the session this end is done: it ends the association, and the
session's slot is free again once it has heard this."
  (with-slots (closed) s
    (unless closed
      (unless abort (ignore-errors (%chs-flush s)))
      (setf closed t)
      (ignore-errors (%chs-send s :close))))
  t)

;;; ---------------------------------------------------------------------------
;;; 2. The :webrtc backend fn.
;;;
;;; Signaling: a POST /signal (offer in, answer out) on cl-transport/http-server, like the glass
;;; gateway.  The server is this EXPOSE's own, with its own routes: hunchentoot's one global
;;; *DISPATCH-TABLE* meant a second EXPOSE (or the glass gateway) in the same image took the first
;;; one's /signal away.
;;;
;;; SLOTS.  Channels are made once and reused (on modus a channel's ring and wait queues are
;;; never reclaimed), so EXPOSE makes MAX-SESSIONS slots up front -- each a REPLY, an IN and an
;;; OUT channel -- and a FREE channel holding the numbers of the slots not in use.  A session
;;; takes a number and gives it back when it and its application thread are done.  An offer
;;; that finds no free slot is refused.  STOP is a one-byte array the closer sets and every
;;; session reads on each pass.
;;; ---------------------------------------------------------------------------

(defun %abort-association (assoc)
  "Tell the peer at once that we are done (rather than after its silence timeout)."
  (ignore-errors
   (when (eq (wd:sctp-assoc-state assoc) :established)
     (wd::sctp-transmit assoc (wd::sctp-chunk wd::+chunk-abort+ 0 #())))))

(defun %application-main (in out peer on-connection)
  "The application thread: a stream of its own over IN and OUT, handed to ON-CONNECTION."
  (let ((stream (make-instance 'webrtc-channel-stream :in in :out out :peer peer)))
    (unwind-protect
         (handler-case (funcall on-connection stream peer)
           (error (e) (format *error-output* "~&[webrtc-transport] handler error: ~a~%" e)))
      (ignore-errors (close stream)))))

(defun %session-main (offer-sdp slot reply in out free stop on-connection opts)
  "The session thread: answer OFFER-SDP (sent back on REPLY), then run ICE, DTLS and SCTP on
this thread, with the application on a thread of its own talking to us through IN and OUT.
Gives SLOT back on FREE when done."
  (destructuring-bind (&key (duration 86400.0) local-ip gather-srflx gather-relay (tick 0.01)
                       &allow-other-keys)
      opts
    (let ((agent nil) (answered nil) (app nil) (app-done nil) (sid nil) (backlog '()))
      (labels ((to-app (msg)
                 ;; Never block the association on a slow reader: what IN will not take now
                 ;; waits here, in order, and goes on a later pass.
                 (unless (and (null backlog) (bob:channel-send in msg :timeout 0))
                   (setf backlog (nconc backlog (list msg)))))
               (pass (assoc)
                 (loop while (and backlog (bob:channel-send in (first backlog) :timeout 0))
                       do (pop backlog))
                 ;; everything the application has written, into SCTP
                 (loop (multiple-value-bind (msg ok) (bob:channel-try-receive out)
                         (cond ((not ok) (return))
                               ((eq msg :close) (setf app-done t) (return))
                               ((and sid (vectorp msg)) (wd:sctp-send-binary assoc sid msg)))))))
        (unwind-protect
             (handler-case
                 (let* ((offer (wd:parse-sdp offer-sdp))
                        (a (setf agent (wd:make-ice :local-ip (or local-ip (uiop:getenv "ICE_LOCAL_IP")))))
                        (conn (wd:webrtc-dtls-setup a :remote-fingerprint (wd:sdp-fingerprint offer)))
                        (fp (wd:dtls-conn-fingerprint conn))
                        (answer (wd:ice-answer a offer :fingerprint fp
                                                       :gather-srflx (and gather-srflx t)
                                                       :gather-relay (and gather-relay t))))
                   (wd:ice-serve a :mode :pull)
                   (when gather-srflx (wd:ice-start-checks a))
                   (setf answered t)
                   (bob:channel-send reply answer :timeout 5)
                   (wd:webrtc-dtls-run conn)
                   (let ((assoc
                           (wd:webrtc-serve-datachannel
                            conn :duration duration :tick tick
                            :alive-p (lambda () (not (or app-done (plusp (aref stop 0)))))
                            :on-ready
                            (lambda (assoc id)
                              (declare (ignore assoc))
                              (if sid
                                  (format *error-output* "~&[webrtc-transport] channel ~d ignored: ~
                                                          this session serves channel ~d~%" id sid)
                                  (setf sid id
                                        app (sb-thread:make-thread
                                             #'%application-main
                                             :name "webrtc-on-connection"
                                             :arguments (list in out
                                                              (list :backend :webrtc :fingerprint fp)
                                                              on-connection)))))
                            :on-message
                            (lambda (assoc id payload)
                              (declare (ignore assoc))
                              (when (eql id sid)
                                (to-app (if (stringp payload) (wd::utf8 payload) payload))))
                            :on-pass #'pass)))
                     ;; Ended here (the handler closed, or EXPOSE's closer): tell the peer.
                     (pass assoc)
                     (%abort-association assoc)))
               (error (e)
                 (unless answered
                   (ignore-errors (bob:channel-send reply (list :error (princ-to-string e)) :timeout 1)))
                 (format *error-output* "~&[webrtc-transport] session error: ~a~%" e)))
          (when agent (ignore-errors (wd:ice-close agent)))
          ;; The application, if it started, hears :EOF and says :CLOSE before this slot may
          ;; serve another session; give it a while, draining what it writes meanwhile.
          (when (and app (not app-done))
            (bob:channel-drain in)
            (bob:channel-send in :eof :timeout 1)
            (loop with deadline = (+ (get-internal-real-time) (* 10 internal-time-units-per-second))
                  until (or app-done (> (get-internal-real-time) deadline))
                  do (multiple-value-bind (msg ok) (bob:channel-receive out :timeout 0.1)
                       (when (and ok (eq msg :close)) (setf app-done t)))))
          (if (or app-done (null app))
              (progn (bob:channel-drain in) (bob:channel-drain out) (bob:channel-send free slot :timeout 1))
              (format *error-output* "~&[webrtc-transport] session slot ~d not reused: its ~
                                      handler has not returned~%" slot)))))))

(defun %webrtc-expose (on-connection opts)
  "cl-transport :webrtc inbound backend.  Start a POST /signal endpoint; for each offer run the
webrtc-data answerer and deliver each open data channel to ON-CONNECTION.  Returns a zero-arg
closer thunk: it stops the endpoint, ends live sessions, waits up to 10 s for them, and returns
T if every one ended.

OPTS (all optional): :signal-host \"0.0.0.0\" :signal-port 8766 (0: ephemeral) :signal-path
\"/signal\" :duration 86400.0 :local-ip <advertised host candidate> :gather-srflx :gather-relay
:max-sessions 4 (sessions at once; a further offer is refused) :answer-timeout 30.0
:on-listening (called with the bound port once the endpoint accepts).

On modus call it on the main thread (see the file header): the channels, the slot table and the
route closure made here are what every handler and session thread is handed."
  (destructuring-bind (&key (signal-host "0.0.0.0") (signal-port 8766) (signal-path "/signal")
                            (max-sessions 4) (answer-timeout 30.0) on-listening
                       &allow-other-keys)
      opts
    (wd:webrtc-identity)                ; made here, once, where every session can read it
    (let* ((slots (coerce (loop repeat max-sessions
                                collect (vector (bob:make-channel :capacity 16384)
                                                (bob:make-channel :capacity +chan-bytes+)
                                                (bob:make-channel :capacity +chan-bytes+)))
                          'simple-vector))
           (free (bob:make-channel :capacity 4096))
           (stop (make-array 1 :element-type '(unsigned-byte 8) :initial-element 0))
           (server nil))
      (dotimes (i max-sessions) (bob:channel-send free i))
      (labels ((process-offer (offer-sdp)
                 "Offer SDP in -> answer SDP out; the session runs on a thread of its own.
                  Reusable by any signaling front-end, not just HTTP."
                 (multiple-value-bind (slot ok) (bob:channel-try-receive free)
                   (unless ok (error "webrtc: every session slot (~d) is in use" max-sessions))
                   (let* ((chans (svref slots slot)) (reply (svref chans 0)))
                     (bob:channel-drain reply)
                     (handler-case
                         (sb-thread:make-thread
                          #'%session-main :name "webrtc-session"
                          :arguments (list offer-sdp slot reply (svref chans 1) (svref chans 2)
                                           free stop on-connection opts))
                       (error (e) (bob:channel-send free slot :timeout 1) (error e)))
                     (multiple-value-bind (answer got) (bob:channel-receive reply :timeout answer-timeout)
                       (cond ((not got) (error "webrtc: no answer within ~as" answer-timeout))
                             ((stringp answer) answer)
                             (t (error "webrtc: ~a" (second answer))))))))
               (signal-handler (request)
                 (setf (http:reply-content-type request) "application/sdp")
                 (process-offer (http:request-body-string request))))
        (setf server (http:start-server :host signal-host :port signal-port :name "webrtc-signal"
                                        :routes (list (list "POST" signal-path #'signal-handler))))
        (format *error-output* "~&[webrtc-transport] :webrtc EXPOSE — POST http://~a:~a~a~%"
                signal-host (http:server-port server) signal-path)
        (when on-listening (funcall on-listening (http:server-port server)))
        ;; closer thunk
        (lambda ()
          (ignore-errors (http:stop-server server))
          (setf (aref stop 0) 1)
          ;; every slot back = every session ended (each notices within one pass of its loop)
          (let ((back '())
                (deadline (+ (get-internal-real-time) (* 10 internal-time-units-per-second))))
            (loop while (and (< (length back) max-sessions) (< (get-internal-real-time) deadline))
                  do (multiple-value-bind (slot ok) (bob:channel-receive free :timeout 0.1)
                       (when ok (push slot back))))
            (dolist (slot back) (bob:channel-send free slot :timeout 1))
            (= (length back) max-sessions)))))))

;;; Register :WEBRTC with cl-transport's inbound registry (nothing backend-specific lives in
;;; cl-transport itself — the backend lives here, like cl-frpc's :frp).
(ct:register-listener :webrtc #'%webrtc-expose)
