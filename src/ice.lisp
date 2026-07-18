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
  srflx-ip srflx-port                          ; server-reflexive (public) address, if gathered
  (remote-candidates '())                      ; the peer's candidates (from its offer), for our checks
  (on-packet nil) (peer nil) (stop nil) (check-thread nil) thread)

(defparameter *stun-servers*
  (let ((env (uiop:getenv "STUN_SERVER")))     ; "host:port" — overrides for a local/test STUN
    (if (and env (position #\: env))
        (list (cons (subseq env 0 (position #\: env))
                    (parse-integer (subseq env (1+ (position #\: env))))))
        '(("stun.l.google.com" . 19302) ("stun.cloudflare.com" . 3478))))
  "STUN servers tried in order to discover our server-reflexive address ($STUN_SERVER overrides).")

(defun resolve-host (host)
  "Dotted-quad IP string for HOST (a dotted string passes through); NIL on failure."
  (handler-case
      (if (every (lambda (c) (or (digit-char-p c) (char= c #\.))) host)
          host
          (format nil "~{~d~^.~}"
                  (coerce (sb-bsd-sockets:host-ent-address
                           (sb-bsd-sockets:get-host-by-name host)) 'list)))
    (error () nil)))

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

(defun ice-answer (agent remote-sdp &key fingerprint (setup "active") gather-srflx)
  "Record the remote credentials from REMOTE-SDP and return our answer SDP.  With GATHER-SRFLX,
first discover our server-reflexive (public) address via STUN and include it as a candidate, so a
peer behind a different NAT can reach us — must run before ICE-SERVE (it uses the ICE socket)."
  (setf (ice-agent-remote-ufrag agent) (sdp-ice-ufrag remote-sdp)
        (ice-agent-remote-pwd agent) (sdp-ice-pwd remote-sdp)
        (ice-agent-remote-candidates agent) (sdp-candidates remote-sdp))
  (when gather-srflx (ice-gather-srflx agent))
  (make-answer-sdp :ice-ufrag (ice-agent-local-ufrag agent) :ice-pwd (ice-agent-local-pwd agent)
                   :fingerprint (or fingerprint (colon-hex (u8vec 32)))   ; valid-format placeholder until DTLS
                   :ip (ice-agent-local-ip agent) :port (ice-agent-port agent)
                   :srflx-ip (ice-agent-srflx-ip agent) :srflx-port (ice-agent-srflx-port agent)
                   :setup setup :mid (sdp-mid remote-sdp) :lite t))

(defun ice-send (agent bytes host port)
  (sb-bsd-sockets:socket-send (ice-agent-socket agent) (as-u8vec bytes) (length bytes)
                              :address (list host port)))

(defun ice-gather-srflx (agent &key (timeout 1.5))
  "Discover our server-reflexive (public) transport address: send a STUN Binding request from
the ICE socket to a public STUN server and read XOR-MAPPED-ADDRESS from the response, setting
SRFLX-IP/PORT on AGENT.  Because the request goes out from the very socket ICE will use, the
NAT mapping it creates is the one the peer will reach us through (host-candidate hole punch for
cone NATs).  Best-effort — returns T on success, NIL if no server answers.  MUST run before
ICE-SERVE so the response isn't consumed by the receive loop."
  (let ((sock (ice-agent-socket agent)))
    (dolist (server *stun-servers* nil)
      (let ((ip (resolve-host (car server))))
        (when ip
          (handler-case
              (let ((tid (stun-transaction-id)))
                ;; ICE-SEND takes the peer host as a 4-octet vector (as socket-receive returns it),
                ;; so convert the resolved dotted string.
                (ice-send agent (encode-stun +binding-request+ tid nil :fingerprint t)
                          (sb-bsd-sockets:make-inet-address ip) (cdr server))
                (when (sb-sys:wait-until-fd-usable
                       (sb-bsd-sockets:socket-file-descriptor sock) :input timeout)
                  (let ((buf (make-array 512 :element-type '(unsigned-byte 8))))
                    (multiple-value-bind (b len) (sb-bsd-sockets:socket-receive sock buf nil)
                      (declare (ignore b))
                      (when (and len (>= len 20))
                        (multiple-value-bind (type rtid attrs) (decode-stun (subseq buf 0 len))
                          (when (and (eql type +binding-success+) (equalp rtid tid))
                            (multiple-value-bind (mip mport)
                                (parse-xor-mapped-address (stun-attr attrs +attr-xor-mapped-address+))
                              (when mip
                                (setf (ice-agent-srflx-ip agent) mip
                                      (ice-agent-srflx-port agent) mport)
                                (return t))))))))))
            (error () nil)))))))

(defun ice-handle-stun (agent pkt from-host from-port)
  (multiple-value-bind (type tid) (decode-stun pkt)
    (cond
      ((eql type +binding-request+)
       ;; a connectivity check from the peer: respond, and remember where it reached us from
       (setf (ice-agent-peer agent) (list from-host from-port))
       (ice-send agent
                 (encode-stun +binding-success+ tid
                              (list (cons +attr-xor-mapped-address+ (xor-mapped-address from-host from-port)))
                              :integrity-key (ice-agent-local-pwd agent) :fingerprint t)
                 from-host from-port))
      ((eql type +binding-success+)
       ;; a response to one of OUR checks: this pair works, so the peer is reachable here
       (unless (ice-agent-peer agent)
         (setf (ice-agent-peer agent) (list from-host from-port)))))))

(defun ice-start-checks (agent &key (interval 0.2) (duration 15.0) (priority 1845494015))
  "Full-agent behaviour layered on the ICE-lite responder: periodically send STUN connectivity
checks to each of the peer's candidates.  We don't nominate (the peer, controlling, does that) —
the point is that sending these punches OUR NAT mapping open toward the peer, so a restricted-cone
NAT lets the peer's own checks reach us.  Runs on its own thread until a peer address is
established or DURATION elapses.  Call after ICE-SERVE."
  (setf (ice-agent-check-thread agent)
        (bt:make-thread
         (lambda ()
           (let ((deadline (+ (get-internal-real-time)
                              (round (* duration internal-time-units-per-second))))
                 (tiebreaker (random-bytes 8))
                 (username (ascii (format nil "~a:~a" (ice-agent-remote-ufrag agent)
                                          (ice-agent-local-ufrag agent)))))
             (loop until (or (ice-agent-peer agent) (ice-agent-stop agent)
                             (>= (get-internal-real-time) deadline))
                   do (dolist (c (ice-agent-remote-candidates agent))
                        (ignore-errors
                          (ice-send agent
                                    (encode-stun +binding-request+ (stun-transaction-id)
                                                 (list (cons +attr-username+ username)
                                                       (cons +attr-ice-controlled+ tiebreaker)
                                                       (cons +attr-priority+ (u32be priority)))
                                                 :integrity-key (ice-agent-remote-pwd agent) :fingerprint t)
                                    (sb-bsd-sockets:make-inet-address (ice-candidate-ip c))
                                    (ice-candidate-port c))))
                      (sleep interval))))
         :name "ice-checks"))
  agent)

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
