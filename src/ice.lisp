;;;; src/ice.lisp — an ICE-lite agent (RFC 8445): bind UDP, answer STUN connectivity checks.
;;;;
;;;; As ICE-lite we never initiate checks or run the nomination state machine — the full peer
;;;; (aiortc / a browser) does that.  We only: (1) advertise a host candidate + our ufrag/pwd
;;;; in the answer SDP, and (2) reply to each incoming Binding Request with a Success carrying
;;;; XOR-MAPPED-ADDRESS (the peer's source) + MESSAGE-INTEGRITY (keyed by OUR pwd) + FINGERPRINT.
;;;; That's enough for the peer's checks to succeed and ICE to reach `connected`.  Non-STUN
;;;; packets on the same socket (DTLS, later) are handed to ON-PACKET.

(in-package #:webrtc-data)

(defparameter +ice-chars+ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
(defun ice-string (n)
  (map 'string (lambda (b) (char +ice-chars+ (mod b 62))) (random-bytes n)))

(defstruct ice-agent socket port local-ip local-ufrag local-pwd remote-ufrag remote-pwd
  (on-packet nil) (peer nil) (stop nil) thread)

(defun local-ipv4 ()
  "Primary non-loopback IPv4 as a dotted string (connect a UDP socket outward, read its addr)."
  (handler-case
      (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :datagram :protocol :udp)))
        (unwind-protect
             (progn (sb-bsd-sockets:socket-connect s (sb-bsd-sockets:make-inet-address "8.8.8.8") 53)
                    (multiple-value-bind (addr port) (sb-bsd-sockets:socket-name s)
                      (declare (ignore port)) (format nil "~{~d~^.~}" (coerce addr 'list))))
          (ignore-errors (sb-bsd-sockets:socket-close s))))
    (error () "127.0.0.1")))

(defun make-ice (&key local-ip)
  "Bind a UDP socket (OS-assigned port) and mint local ICE credentials."
  (let ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :datagram :protocol :udp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address sock) t)
    (sb-bsd-sockets:socket-bind sock (sb-bsd-sockets:make-inet-address "0.0.0.0") 0)
    (multiple-value-bind (addr port) (sb-bsd-sockets:socket-name sock)
      (declare (ignore addr))
      (make-ice-agent :socket sock :port port :local-ip (or local-ip (local-ipv4))
                      :local-ufrag (ice-string 4) :local-pwd (ice-string 22)))))

(defun ice-answer (agent remote-sdp &key fingerprint (setup "active"))
  "Record the remote credentials from REMOTE-SDP and return our answer SDP."
  (setf (ice-agent-remote-ufrag agent) (sdp-ice-ufrag remote-sdp)
        (ice-agent-remote-pwd agent) (sdp-ice-pwd remote-sdp))
  (make-answer-sdp :ice-ufrag (ice-agent-local-ufrag agent) :ice-pwd (ice-agent-local-pwd agent)
                   :fingerprint (or fingerprint (colon-hex (u8vec 32)))   ; valid-format placeholder until DTLS

                   :ip (ice-agent-local-ip agent) :port (ice-agent-port agent)
                   :setup setup :mid (sdp-mid remote-sdp) :lite t))

(defun ice-send (agent bytes host port)
  (sb-bsd-sockets:socket-send (ice-agent-socket agent) (as-u8vec bytes) (length bytes)
                              :address (list host port)))

(defun ice-handle-stun (agent pkt from-host from-port)
  (multiple-value-bind (type tid) (decode-stun pkt)
    (when (eql type +binding-request+)
      ;; remember where the peer reaches us from (for DTLS later)
      (setf (ice-agent-peer agent) (list from-host from-port))
      (ice-send agent
                (encode-stun +binding-success+ tid
                             (list (cons +attr-xor-mapped-address+ (xor-mapped-address from-host from-port)))
                             :integrity-key (ice-agent-local-pwd agent) :fingerprint t)
                from-host from-port))))

(defun ice-serve (agent)
  "Start the receive loop on its own thread.  Returns AGENT."
  (setf (ice-agent-thread agent)
        (bt:make-thread
         (lambda ()
           (let ((buf (make-array 4096 :element-type '(unsigned-byte 8))))
             (loop until (ice-agent-stop agent) do
               (handler-case
                   (multiple-value-bind (b len host port)
                       (sb-bsd-sockets:socket-receive (ice-agent-socket agent) buf nil)
                     (declare (ignore b))
                     (when (and len (plusp len))
                       (let ((pkt (subseq buf 0 len)))
                         (if (and (>= len 20) (= (rd-u32be pkt 4) +stun-magic+))
                             (ice-handle-stun agent pkt host port)
                             (when (ice-agent-on-packet agent)
                               (funcall (ice-agent-on-packet agent) pkt host port))))))
                 (error () (unless (ice-agent-stop agent) (sleep 0.005)))))))
         :name "webrtc-data-ice"))
  agent)

(defun ice-close (agent)
  (setf (ice-agent-stop agent) t)
  (ignore-errors (sb-bsd-sockets:socket-close (ice-agent-socket agent)))
  (ignore-errors (bt:destroy-thread (ice-agent-thread agent))))
