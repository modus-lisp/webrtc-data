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
;;;;   1. WEBRTC-CHANNEL-STREAM — a Gray binary stream that bridges the message-oriented data
;;;;      channel to a byte stream: inbound SCTP messages are concatenated into a read buffer
;;;;      (blocking reads); outbound bytes are buffered and flushed as chunked SCTP messages.
;;;;   2. %WEBRTC-EXPOSE — the :webrtc backend fn: a hunchentoot POST /signal endpoint that
;;;;      drives the answerer per peer and delivers each open channel to ON-CONNECTION.
;;;;
;;;; cl-transport stays OUT of core webrtc-data's deps — this is an optional integration
;;;; system (webrtc-data/transport), modeled on cl-frpc's :frp provider.

(in-package #:webrtc-data-transport)

;;; ---------------------------------------------------------------------------
;;; 1. A Gray binary stream over the data channel.
;;;
;;; The data channel is message-oriented (whole SCTP messages in/out); this stream presents it
;;; as a plain byte stream.  Inbound messages are appended to a byte buffer that blocking reads
;;; drain; outbound writes are buffered and flushed as SCTP binary messages, chunked under the
;;; no-fragmentation limit (like the glass gateway does).
;;; ---------------------------------------------------------------------------

(defconstant +chunk+ 1024
  "Max bytes per outbound SCTP message: our SCTP doesn't fragment, so flush in <=1KB chunks.")

(defclass webrtc-channel-stream (sb-gray:fundamental-binary-input-stream
                                 sb-gray:fundamental-binary-output-stream)
  ((assoc     :initarg :assoc     :reader chs-assoc)
   (stream-id :initarg :stream-id :reader chs-stream-id)
   (peer      :initarg :peer      :initform nil :reader chs-peer)
   ;; read side: a byte queue fed by :on-message, drained by reads.  RBUF holds bytes from
   ;; RPOS (next unread) to the fill pointer; we compact when fully drained.
   (rbuf   :initform (make-array 4096 :element-type '(unsigned-byte 8)
                                      :adjustable t :fill-pointer 0))
   (rpos   :initform 0)
   (lock   :initform (bt:make-lock "webrtc-chs"))
   (cvar   :initform (bt:make-condition-variable))
   (closed :initform nil)
   ;; write side: bytes buffered until force/finish-output (or a full chunk) flushes them.
   (wbuf   :initform (make-array +chunk+ :element-type '(unsigned-byte 8)
                                         :adjustable t :fill-pointer 0))
   (wlock  :initform (bt:make-lock "webrtc-chs-w"))))

(defmethod stream-element-type ((s webrtc-channel-stream))
  '(unsigned-byte 8))

;;; --- read side --------------------------------------------------------------

(defun %payload->bytes (payload)
  "An inbound data-channel message is bytes (PPID 53) or a string (PPID 51); a byte stream
carries bytes either way, so coerce a string to its octets."
  (if (stringp payload)
      (map '(vector (unsigned-byte 8)) #'char-code payload)
      (coerce payload '(vector (unsigned-byte 8)))))

(defun channel-stream-push (s payload)
  "Feed one inbound data-channel message into the read buffer and wake blocked readers.
Called from the answerer's :on-message.  Whole-message boundaries are erased here: readers
see a continuous byte stream."
  (let ((bytes (%payload->bytes payload)))
    (with-slots (rbuf lock cvar) s
      (bt:with-lock-held (lock)
        (loop for b across bytes do (vector-push-extend b rbuf))
        (bt:condition-notify cvar)))))

(defun channel-stream-eof (s)
  "Mark the channel closed: pending readers return whatever's buffered, then EOF."
  (with-slots (lock cvar closed) s
    (bt:with-lock-held (lock)
      (setf closed t)
      (bt:condition-notify cvar))))

(defun %chs-available (s)
  "Bytes currently readable.  Caller holds the lock."
  (with-slots (rbuf rpos) s (- (fill-pointer rbuf) rpos)))

(defun %chs-wait-readable (s)
  "Block until >=1 byte is readable or the channel is closed.  Returns T if bytes are
available, NIL on EOF.  Caller holds the lock."
  (with-slots (lock cvar closed) s
    (loop
      (when (plusp (%chs-available s)) (return t))
      (when closed (return nil))
      (bt:condition-wait cvar lock))))

(defun %chs-compact (s)
  "Reset the buffer once fully drained, so it can't grow without bound.  Caller holds lock."
  (with-slots (rbuf rpos) s
    (when (>= rpos (fill-pointer rbuf))
      (setf (fill-pointer rbuf) 0 rpos 0))))

(defmethod sb-gray:stream-read-byte ((s webrtc-channel-stream))
  (with-slots (rbuf rpos lock) s
    (bt:with-lock-held (lock)
      (if (%chs-wait-readable s)
          (prog1 (aref rbuf rpos)
            (incf rpos)
            (%chs-compact s))
          :eof))))

(defmethod sb-gray:stream-read-sequence
    ((s webrtc-channel-stream) seq &optional (start 0) end)
  "Socket-style partial read: block until >=1 byte or EOF, then copy as many buffered bytes as
fit (never waiting to fill).  Returns the index of the first element not written (= START on
EOF).  Callers loop like they would on a TCP socket."
  (let ((end (or end (length seq))))
    (with-slots (rbuf rpos lock) s
      (bt:with-lock-held (lock)
        (if (%chs-wait-readable s)
            (let ((n (min (- end start) (%chs-available s))))
              (dotimes (i n) (setf (elt seq (+ start i)) (aref rbuf (+ rpos i))))
              (incf rpos n)
              (%chs-compact s)
              (+ start n))
            start)))))

;;; --- write side -------------------------------------------------------------

(defun %chs-flush (s)
  "Send the write buffer as chunked SCTP binary messages (<=+CHUNK+ each) and clear it."
  (with-slots (wbuf wlock assoc stream-id closed) s
    (bt:with-lock-held (wlock)
      (let ((n (fill-pointer wbuf)))
        (when (and (plusp n) (not closed))
          (loop for off from 0 below n by +chunk+
                do (wd:sctp-send-binary assoc stream-id
                                        (subseq wbuf off (min n (+ off +chunk+))))))
        (setf (fill-pointer wbuf) 0)))))

(defmethod sb-gray:stream-write-byte ((s webrtc-channel-stream) byte)
  (with-slots (wbuf wlock) s
    (bt:with-lock-held (wlock) (vector-push-extend byte wbuf))
    (when (>= (fill-pointer wbuf) +chunk+) (%chs-flush s)))
  byte)

(defmethod sb-gray:stream-write-sequence
    ((s webrtc-channel-stream) seq &optional (start 0) end)
  (let ((end (or end (length seq))))
    (with-slots (wbuf wlock) s
      (bt:with-lock-held (wlock)
        (loop for i from start below end do (vector-push-extend (elt seq i) wbuf)))
      (when (>= (fill-pointer wbuf) +chunk+) (%chs-flush s))))
  seq)

(defmethod sb-gray:stream-force-output ((s webrtc-channel-stream)) (%chs-flush s) nil)
(defmethod sb-gray:stream-finish-output ((s webrtc-channel-stream)) (%chs-flush s) nil)

(defmethod close ((s webrtc-channel-stream) &key abort)
  (unless abort (ignore-errors (%chs-flush s)))
  (channel-stream-eof s)
  t)

;;; ---------------------------------------------------------------------------
;;; 2. The :webrtc backend fn.
;;;
;;; Signaling: a hunchentoot POST /signal (offer in, answer out), like the glass demo.  For
;;; each offer we run the full answerer on a background thread; when the data channel opens we
;;; build a WEBRTC-CHANNEL-STREAM and hand it to ON-CONNECTION (on its OWN thread, so the
;;; serve-datachannel loop keeps pumping inbound messages / SACKs while the handler blocks on
;;; the stream).
;;; ---------------------------------------------------------------------------

(defun %run-answerer (conn on-connection duration fp)
  "Drive DTLS then the data channel; on open, hand ON-CONNECTION a stream over the channel."
  (let ((stream nil))
    (unwind-protect
         (handler-case
             (progn
               (wd:webrtc-dtls-run conn)
               (wd:webrtc-serve-datachannel
                conn :duration duration
                :on-ready
                (lambda (assoc sid)
                  (setf stream (make-instance 'webrtc-channel-stream
                                              :assoc assoc :stream-id sid
                                              :peer (list :backend :webrtc :fingerprint fp)))
                  ;; ON-CONNECTION may block on the stream; run it off the serve loop so this
                  ;; loop keeps feeding :on-message and flushing SCTP.
                  (bt:make-thread
                   (lambda ()
                     (unwind-protect
                          (funcall on-connection stream (chs-peer stream))
                       (ignore-errors (close stream))))
                   :name "webrtc-on-connection"))
                :on-message
                (lambda (assoc sid payload)
                  (declare (ignore assoc sid))
                  (when stream (channel-stream-push stream payload)))))
           (error (e)
             (format *error-output* "~&[webrtc-transport] session error: ~a~%" e)))
      ;; serve loop ended (duration elapsed / peer aborted): EOF the stream so a blocked
      ;; handler unwinds.
      (when stream (ignore-errors (channel-stream-eof stream))))))

(defun %webrtc-expose (on-connection opts)
  "cl-transport :webrtc inbound backend.  Start a POST /signal endpoint; for each offer run the
webrtc-data answerer and deliver each open data channel to ON-CONNECTION.  Returns a zero-arg
closer thunk (stops the acceptor + EOFs live sessions).

OPTS (all optional): :signal-host \"0.0.0.0\" :signal-port 8766 :signal-path \"/signal\"
:duration 86400.0 :local-ip <advertised host candidate> :gather-srflx :gather-relay."
  (destructuring-bind (&key (signal-host "0.0.0.0") (signal-port 8766) (signal-path "/signal")
                            (duration 86400.0) local-ip gather-srflx gather-relay
                       &allow-other-keys)
      opts
    (let ((sessions '())
          (slock (bt:make-lock "webrtc-expose"))
          acceptor)
      (labels ((process-offer (offer-sdp)
                 "Offer SDP in -> answer SDP out; spawn the answerer session.  Reusable by any
                  signaling front-end, not just HTTP."
                 (let* ((offer (wd:parse-sdp offer-sdp))
                        (agent (wd:make-ice :local-ip (or local-ip (uiop:getenv "ICE_LOCAL_IP"))))
                        (conn  (wd:webrtc-dtls-setup
                                agent :remote-fingerprint (wd:sdp-fingerprint offer)))
                        (fp    (wd:dtls-conn-fingerprint conn))
                        (answer (wd:ice-answer agent offer :fingerprint fp
                                               :gather-srflx (and gather-srflx t)
                                               :gather-relay (and gather-relay t))))
                   (wd:ice-serve agent)
                   (when gather-srflx (wd:ice-start-checks agent))
                   (let ((thr (bt:make-thread
                               (lambda () (%run-answerer conn on-connection duration fp))
                               :name "webrtc-session")))
                     (bt:with-lock-held (slock) (push thr sessions)))
                   answer))
               (signal-handler ()
                 (setf (hunchentoot:content-type*) "application/sdp")
                 (process-offer (hunchentoot:raw-post-data :force-text t))))
        (setf acceptor (make-instance 'hunchentoot:easy-acceptor
                                      :address signal-host :port signal-port))
        (setf hunchentoot:*dispatch-table*
              (list (hunchentoot:create-regex-dispatcher
                     (format nil "^~a$" signal-path) #'signal-handler)))
        (hunchentoot:start acceptor)
        (format *error-output* "~&[webrtc-transport] :webrtc EXPOSE — POST http://~a:~a~a~%"
                signal-host signal-port signal-path)
        ;; closer thunk
        (lambda ()
          (ignore-errors (hunchentoot:stop acceptor))
          (bt:with-lock-held (slock)
            (dolist (thr sessions) (ignore-errors (bt:destroy-thread thr)))
            (setf sessions '())))))))

;;; Register :WEBRTC with cl-transport's inbound registry (nothing backend-specific lives in
;;; cl-transport itself — the backend lives here, like cl-frpc's :frp).
(ct:register-listener :webrtc #'%webrtc-expose)
