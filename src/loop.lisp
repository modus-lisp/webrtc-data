;;;; src/loop.lisp -- a WebRTC data-channel session on an event loop: no threads.
;;;;
;;;; The threaded driver is three things in a row on a session thread: WEBRTC-DTLS-RUN polls
;;;; for an ICE peer and then blocks in the DTLS handshake, reading a mailbox the ICE receive
;;;; thread fills; WEBRTC-SERVE-DATACHANNEL then loops on that mailbox and SCTP-TICK.  Here the
;;;; same steps are a LINK whose PHASE moves along as packets arrive through the ICE agent's
;;;; socket watch (cl-transport ice-loop.lisp), with timers for everything that waited:
;;;;
;;;;   :await-peer  a 50 ms poll until ICE selects a peer, failing after PEER-WAIT
;;;;   :handshake   seal's driven client handshake: DTLS-CLIENT-INPUT per datagram, a
;;;;                retransmit timer re-armed after every event
;;;;   :sctp        DTLS-HANDLE-DATAGRAM -> SCTP-INPUT per datagram, SCTP-TICK every 50 ms, which
;;;;                also checks DURATION, an ABORT and the caller's ALIVE-P
;;;;   :closed      every timer cancelled, ON-CLOSE called once with the reason
;;;;
;;;; SCTP sends never wait here: the association is made NONBLOCKING, so SCTP-SEND-DATA always
;;;; enqueues and returns, and a producer that can outrun the peer (the RFB bridge) asks
;;;; SCTP-BACKLOGGED-P and stops reading its source until the queue drains.

(in-package #:webrtc-data)

(defun ice-answer-on-loop (agent remote-sdp loop on-answer
                           &key fingerprint (setup "active") gather-srflx gather-relay)
  "ICE-ANSWER without the wait: record the peer's credentials, put AGENT on LOOP, gather, and
call ON-ANSWER with the answer SDP when gathering is done.  Returns AGENT."
  (ice-accept-remote agent :ufrag (sdp-ice-ufrag remote-sdp) :pwd (sdp-ice-pwd remote-sdp)
                           :candidates (sdp-candidates remote-sdp))
  (cl-transport.ice:ice-start-on-loop
   agent loop :gather-srflx gather-srflx :gather-relay gather-relay
   :on-gathered
   (lambda (agent)
     (funcall on-answer
              (make-answer-sdp :ice-ufrag (ice-agent-local-ufrag agent) :ice-pwd (ice-agent-local-pwd agent)
                               :fingerprint (or fingerprint (colon-hex (u8vec 32)))
                               :ip (ice-agent-local-ip agent) :port (ice-agent-port agent)
                               :srflx-ip (ice-agent-srflx-ip agent) :srflx-port (ice-agent-srflx-port agent)
                               :relay-ip (ice-agent-relay-ip agent) :relay-port (ice-agent-relay-port agent)
                               :setup setup :media (sdp-media remote-sdp) :lite t)))))

(defclass rtc-link ()
  ((conn :initarg :conn :reader link-conn)
   (loop :initarg :loop :reader link-loop)
   (phase :initform :await-peer :accessor link-phase)
   (assoc :initform nil :accessor link-assoc)
   (timer :initform nil :accessor link-timer)        ; the phase's timer (poll / retransmit / tick)
   (reason :initform nil :accessor link-reason)      ; why it closed
   (on-close :initarg :on-close :reader link-on-close)
   (started :initform (get-internal-real-time) :reader link-started)))

(defun link-agent (link) (dtls-conn-agent (link-conn link)))
(defun link-open-p (link) (not (eq (link-phase link) :closed)))

(defun %link-arm (link seconds fn what)
  (cl-transport.loop:cancel (link-loop link) (link-timer link))
  (setf (link-timer link) (cl-transport.loop:after (link-loop link) seconds fn :what what)))

(defun webrtc-close-on-loop (link reason)
  "End LINK: cancel its timer and stop taking packets.  ON-CLOSE is called once with REASON.
The ICE agent is the caller's to close (it may outlive the link, e.g. for media)."
  (when (link-open-p link)
    (setf (link-phase link) :closed
          (link-reason link) reason)
    (cl-transport.loop:cancel (link-loop link) (link-timer link))
    (setf (link-timer link) nil
          (ice-agent-on-packet (link-agent link)) nil)
    (when (link-on-close link)
      (funcall (link-on-close link) link reason)))
  nil)

(defun webrtc-start-on-loop (conn loop &key on-message on-ready on-established on-close alive-p
                                          (duration 3600.0) (peer-wait 120.0) (timeout 0.4) log)
  "Drive CONN (from WEBRTC-DTLS-SETUP, whose agent is already on LOOP) through ICE peer selection,
the DTLS handshake and the SCTP association, on LOOP.  ON-MESSAGE and ON-READY are the SCTP
callbacks WEBRTC-SERVE-DATACHANNEL takes; ON-ESTABLISHED is called with (link assoc) when the
handshake completes; ON-CLOSE with (link reason) when it ends -- REASON a string, or :done.
ALIVE-P, when given, is asked every tick.  Returns the LINK."
  (let* ((agent (dtls-conn-agent conn))
         (session (dtls-conn-session conn))
         (link (make-instance 'rtc-link :conn conn :loop loop :on-close on-close))
         (peer-deadline (+ (cl-transport.loop:now-seconds) peer-wait))
         (end (+ (cl-transport.loop:now-seconds) duration)))
    (labels ((fail (why) (webrtc-close-on-loop link why))
             (rearm-handshake ()
               (%link-arm link (seal:dtls-client-timeout-seconds session)
                          (lambda ()
                            (handler-case (progn (seal:dtls-client-retransmit session) (rearm-handshake))
                              (error (e) (fail (format nil "DTLS: ~a" e)))))
                          "dtls retransmit"))
             (tick ()
               (let ((assoc (link-assoc link)))
                 (handler-case (sctp-tick assoc)
                   (error (e) (sctp-log assoc "~&  !! sctp-tick error: ~a~%" e)))
                 (cond ((eq (sctp-assoc-state assoc) :aborted) (fail "SCTP aborted"))
                       ((>= (cl-transport.loop:now-seconds) end) (fail :done))
                       ((and alive-p (not (funcall alive-p))) (fail "peer gone"))
                       (t (%link-arm link 0.05 #'tick "sctp tick")))))
             (established ()
               (let ((assoc (make-sctp-assoc :session session :on-message on-message
                                             :on-ready on-ready :log log :nonblocking t)))
                 (setf (link-assoc link) assoc
                       (link-phase link) :sctp)
                 (when on-established (funcall on-established link assoc))
                 (%link-arm link 0.05 #'tick "sctp tick")))
             (on-packet (pkt host port)
               (declare (ignore host port))
               (case (link-phase link)
                 (:handshake
                  (handler-case
                      (if (seal:dtls-client-input session pkt)
                          (established)
                          (rearm-handshake))
                    (error (e) (fail (format nil "DTLS: ~a" e)))))
                 (:sctp
                  (let ((assoc (link-assoc link)))
                    (dolist (sctp (seal:dtls-handle-datagram session pkt))
                      (handler-case (sctp-input assoc sctp)
                        (error (e) (sctp-log assoc "~&  !! sctp-input error: ~a~%" e))))))))
             (await-peer ()
               (cond ((ice-agent-peer agent)
                      (setf (link-phase link) :handshake)
                      (handler-case (progn (seal:dtls-client-start session :timeout timeout)
                                           (rearm-handshake))
                        (error (e) (fail (format nil "DTLS: ~a" e)))))
                     ((>= (cl-transport.loop:now-seconds) peer-deadline)
                      (fail (format nil "DTLS: no ICE peer within ~as" peer-wait)))
                     (t (%link-arm link 0.05 #'await-peer "await ice peer")))))
      (setf (ice-agent-on-packet agent) #'on-packet)
      (await-peer))
    link))
