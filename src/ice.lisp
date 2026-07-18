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
  relay-ip relay-port                          ; TURN relayed transport address, if gathered
  turn                                         ; a TURN-ALLOC (allocation state), or NIL
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

(defun ice-answer (agent remote-sdp &key fingerprint (setup "active") gather-srflx gather-relay)
  "Record the remote credentials from REMOTE-SDP and return our answer SDP.  With GATHER-SRFLX,
first discover our server-reflexive (public) address via STUN and include it as a candidate, so a
peer behind a different NAT can reach us.  With GATHER-RELAY, additionally Allocate a TURN relayed
address (env TURN_SERVER/USER/PASS unless GATHER-RELAY is a plist of :server/:user/:pass) and
advertise it as a `typ relay` candidate — this covers the symmetric-NAT case srflx can't.  Both
must run before ICE-SERVE (they use the ICE socket)."
  (setf (ice-agent-remote-ufrag agent) (sdp-ice-ufrag remote-sdp)
        (ice-agent-remote-pwd agent) (sdp-ice-pwd remote-sdp)
        (ice-agent-remote-candidates agent) (sdp-candidates remote-sdp))
  (when gather-srflx (ice-gather-srflx agent))
  (when gather-relay
    (apply #'ice-gather-relay agent (if (listp gather-relay) gather-relay '())))
  (make-answer-sdp :ice-ufrag (ice-agent-local-ufrag agent) :ice-pwd (ice-agent-local-pwd agent)
                   :fingerprint (or fingerprint (colon-hex (u8vec 32)))   ; valid-format placeholder until DTLS
                   :ip (ice-agent-local-ip agent) :port (ice-agent-port agent)
                   :srflx-ip (ice-agent-srflx-ip agent) :srflx-port (ice-agent-srflx-port agent)
                   :relay-ip (ice-agent-relay-ip agent) :relay-port (ice-agent-relay-port agent)
                   :setup setup :mid (sdp-mid remote-sdp) :lite t))

(defun ice-send (agent bytes host port)
  "Send BYTES to HOST:PORT via the ICE socket.  If HOST is the keyword :RELAY, PORT is a bound
TURN channel number: wrap BYTES as ChannelData and send them to the TURN server instead, so the
allocation relays them to the peer (this is what carries traffic in the symmetric-NAT case)."
  (let ((alloc (ice-agent-turn agent)))
    (cond
      ;; ChannelData: PORT is a bound channel number.
      ((eq host :relay)
       (when alloc
         (sb-bsd-sockets:socket-send (ice-agent-socket agent)
                                     (turn-wrap-channeldata port bytes)
                                     (+ 4 (length bytes))
                                     :address (list (turn-alloc-server-host alloc)
                                                    (turn-alloc-server-port alloc)))))
      ;; Send indication: PORT is (peer-host-vec . peer-port), used before a channel exists.
      ((eq host :relay-send)
       (when alloc
         (let ((wrapped (turn-wrap-send-indication alloc (car port) (cdr port) bytes)))
           (sb-bsd-sockets:socket-send (ice-agent-socket agent) wrapped (length wrapped)
                                       :address (list (turn-alloc-server-host alloc)
                                                      (turn-alloc-server-port alloc))))))
      (t (sb-bsd-sockets:socket-send (ice-agent-socket agent) (as-u8vec bytes) (length bytes)
                                     :address (list host port))))))

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

(defparameter +turn-relay-priority+ 41885439
  "Priority for a relay candidate: type-preference 2 (relay) << 24 — always below host/srflx,
so a peer only picks the relay when nothing else works.")

(defun ice-gather-relay (agent &key server user pass (timeout 2.0) (use-mapped-srflx t))
  "Allocate a TURN relayed transport address from the ICE socket (the Allocate/401-auth dance in
turn.lisp), plus a permission+channel for each already-known remote candidate, and set the
allocation + RELAY-IP/PORT on AGENT.  SERVER is \"host:port\"; SERVER/USER/PASS default to env
TURN_SERVER/TURN_USER/TURN_PASS.  Best-effort — returns T on success.  MUST run before ICE-SERVE
(it reads the socket) and after the remote candidates are recorded, so it can pre-install them."
  (let* ((srv (or server (uiop:getenv "TURN_SERVER")))
         (usr (or user (uiop:getenv "TURN_USER")))
         (pw  (or pass (uiop:getenv "TURN_PASS"))))
    (when (and srv usr pw (position #\: srv))
      (let* ((host (subseq srv 0 (position #\: srv)))
             (port (parse-integer (subseq srv (1+ (position #\: srv)))))
             (ip (resolve-host host)))
        (when ip
          (handler-case
              (let ((alloc (make-turn-alloc :socket (ice-agent-socket agent)
                                            :server-host (sb-bsd-sockets:make-inet-address ip)
                                            :server-port port :user usr :pass pw)))
                (when (turn-allocate alloc :timeout timeout)
                  (setf (ice-agent-turn agent) alloc
                        (ice-agent-relay-ip agent) (turn-alloc-relay-ip alloc)
                        (ice-agent-relay-port agent) (turn-alloc-relay-port alloc))
                  ;; If STUN never ran, TURN's XOR-MAPPED-ADDRESS is a free srflx too.
                  (when (and use-mapped-srflx
                             (turn-alloc-mapped-ip alloc) (not (ice-agent-srflx-ip agent)))
                    (setf (ice-agent-srflx-ip agent) (turn-alloc-mapped-ip alloc)
                          (ice-agent-srflx-port agent) (turn-alloc-mapped-port alloc)))
                  ;; Pre-install permission+channel for each known peer candidate.
                  (dolist (c (ice-agent-remote-candidates agent))
                    (ignore-errors (turn-install-peer alloc (ice-candidate-ip c) (ice-candidate-port c))))
                  t))
            (error () nil)))))))

(defun ice-bind-relay-peer-async (agent from-host from-port)
  "Kick off CreatePermission + ChannelBind for FROM-HOST:FROM-PORT (a 4-octet host vector) on a
BACKGROUND thread, so the recv loop never blocks waiting for its own response (that would
deadlock).  Once the channel binds, inbound peer traffic upgrades from Data indications to the
low-overhead ChannelData framing automatically.  Idempotent per peer transport address."
  (let ((alloc (ice-agent-turn agent)))
    (when alloc
      (let* ((ip (format nil "~{~d~^.~}" (coerce from-host 'list)))
             (k (format nil "~a:~d" ip from-port)))
        (when (and (not (gethash k (turn-alloc-peer->chan alloc)))
                   (not (gethash k (turn-alloc-binding alloc))))
          (setf (gethash k (turn-alloc-binding alloc)) t)
          (bt:make-thread
           (lambda ()
             (unwind-protect
                  (let ((chan (let ((c (turn-alloc-next-channel alloc)))
                                (setf (turn-alloc-next-channel alloc) (1+ c)) c)))
                    (%turn-txn-loop alloc +turn-create-perm+
                                    (list (cons +attr-xor-peer-address+ (xor-mapped-address from-host 0)))
                                    :want-success +turn-create-perm-success+)
                    (when (eql (nth-value 0
                                (%turn-txn-loop alloc +turn-channel-bind+
                                                (list (cons +attr-channel-number+ (cat-bytes (u16be chan) (u16be 0)))
                                                      (cons +attr-xor-peer-address+ (xor-mapped-address from-host from-port)))
                                                :want-success +turn-channel-bind-success+))
                               +turn-channel-bind-success+)
                      (setf (gethash k (turn-alloc-peer->chan alloc)) chan
                            (gethash chan (turn-alloc-chan->peer alloc)) (cons ip from-port))))
               (remhash k (turn-alloc-binding alloc))))
           :name "turn-bind"))))))

(defun ice-handle-stun (agent pkt from-host from-port)
  "Handle a STUN packet, dispatching on how it reached us:
     FROM-HOST a 4-octet vector       -> direct; reply to FROM-HOST:FROM-PORT.
     FROM-HOST :RELAY, FROM-PORT chan -> arrived as ChannelData; reply via that channel.
     FROM-HOST :RELAY-SEND, FROM-PORT (host-vec . port) -> arrived as a Data indication; reply
                                        via a Send indication to that peer address.
   The peer slot is set to the matching send-form so the DTLS return path uses the same route,
   and XOR-MAPPED-ADDRESS reflects the peer's real transport address."
  (multiple-value-bind (type tid) (decode-stun pkt)
    (tdbg "handle-stun type=~x from-host=~a from-port=~a" type from-host from-port)
    ;; peer-form = what ice-send should target; reflect = (host . port) for XOR-MAPPED-ADDRESS.
    (multiple-value-bind (peer-form reflect)
        (cond
          ((eq from-host :relay)
           (values (list :relay from-port)
                   (gethash from-port (turn-alloc-chan->peer (ice-agent-turn agent)))))
          ((eq from-host :relay-send)
           (values (list :relay-send from-port)
                   (cons (car from-port) (cdr from-port))))
          (t (values (list from-host from-port) (cons from-host from-port))))
      (let ((rhost (cond ((null reflect) #(0 0 0 0))
                         ;; :relay path stores the peer IP as a dotted string; :relay-send stores
                         ;; a 4-octet host vector.  (A string is also a vector, so test STRINGP.)
                         ((stringp (car reflect)) (sb-bsd-sockets:make-inet-address (car reflect)))
                         (t (car reflect))))
            (rport (if reflect (cdr reflect) 0)))
        (cond
          ((eql type +binding-request+)
           (setf (ice-agent-peer agent) peer-form)
           (tdbg "binding-request -> respond via ~a" peer-form)
           (ice-send agent
                     (encode-stun +binding-success+ tid
                                  (list (cons +attr-xor-mapped-address+ (xor-mapped-address rhost rport)))
                                  :integrity-key (ice-agent-local-pwd agent) :fingerprint t)
                     (first peer-form) (second peer-form)))
          ((eql type +binding-success+)
           (unless (ice-agent-peer agent) (setf (ice-agent-peer agent) peer-form))))))))

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

(defun ice-dispatch (agent buf len host port)
  "Classify one received datagram (BUF[0:LEN] from HOST:PORT) and route it.

  From the TURN server:
    - ChannelData (first 2 bytes a bound channel) -> strip the 4-byte header; the inner bytes are
      a packet FROM the peer via the relay (a relayed STUN check -> ice-handle-stun through the
      relay, or relayed DTLS/SCTP -> on-packet).
    - a Data indication -> unwrap DATA the same way.
    - any other STUN message -> a TURN control response (Allocate/Refresh/Permission/ChannelBind);
      hand it to the TURN layer, never to the peer path.
  Otherwise: a direct datagram, exactly as before (STUN check -> ice-handle-stun, else on-packet)."
  (declare (type fixnum len))
  (let ((alloc (ice-agent-turn agent)))
    (cond
      ;; --- traffic from the TURN server -------------------------------------------------
      ((and alloc (%from-turn-server-p alloc host port))
       (cond
         ((turn-channeldata-p buf len)
          (let* ((chan (logior (ash (aref buf 0) 8) (aref buf 1)))
                 (dlen (logior (ash (aref buf 2) 8) (aref buf 3)))
                 (inner (subseq buf 4 (min len (+ 4 dlen)))))
            (ice-relayed-inner agent inner chan)))
         (t
          (multiple-value-bind (type tid attrs) (decode-stun (subseq buf 0 len))
            (cond
              ((eql type +turn-data-indication+)
               ;; Data indication: DATA came from a permitted peer we have no channel for yet.
               ;; Deliver it now (reply via Send indication) and start a channel bind in the
               ;; background so subsequent traffic rides ChannelData.
               (multiple-value-bind (pip pport)
                   (parse-xor-mapped-address (stun-attr attrs +attr-xor-peer-address+))
                 (let ((data (stun-attr attrs +attr-data+)))
                   (when (and data pip)
                     (let ((hv (sb-bsd-sockets:make-inet-address pip)))
                       (ice-bind-relay-peer-async agent hv pport)
                       (ice-relayed-inner-send agent (as-u8vec data) hv pport))))))
              (type (turn-deliver-control alloc tid type attrs)))))))
      ;; --- ordinary direct datagram -----------------------------------------------------
      (t
       (let ((pkt (subseq buf 0 len)))
         (if (and (>= len 20) (= (rd-u32be pkt 4) +stun-magic+))
             (ice-handle-stun agent pkt host port)
             (when (ice-agent-on-packet agent)
               (funcall (ice-agent-on-packet agent) pkt host port))))))))

(defparameter *turn-debug* (and (uiop:getenv "WEBRTC_TURN_DEBUG") t))
(defun tdbg (fmt &rest args)
  (when *turn-debug* (apply #'format *error-output* (concatenate 'string "~&#TURN " fmt "~%") args)
        (finish-output *error-output*)))

(defun ice-relayed-inner (agent inner chan)
  "INNER is a packet the TURN server relayed from the peer on channel CHAN.  A STUN Binding check
is answered THROUGH the relay (and marks the peer relay-selected); anything else is peer data."
  (tdbg "relayed-inner chan=~a len=~a stun=~a" chan (length inner)
        (and (>= (length inner) 20) (= (rd-u32be inner 4) +stun-magic+)))
  (if (and (>= (length inner) 20) (= (rd-u32be inner 4) +stun-magic+))
      (handler-case (ice-handle-stun agent inner :relay chan)
        (error (e) (tdbg "handle-stun ERROR: ~a" e)))
      (progn
        ;; relayed DTLS/SCTP: make sure the DTLS send-fn returns through this channel
        (setf (ice-agent-peer agent) (list :relay chan))
        (when (ice-agent-on-packet agent)
          (funcall (ice-agent-on-packet agent) inner :relay chan)))))

(defun ice-relayed-inner-send (agent inner peer-host peer-port)
  "Like ICE-RELAYED-INNER but for a peer reached via Data/Send indications (no channel yet):
PEER-HOST is a 4-octet vector.  Replies ride Send indications until a channel binds."
  (let ((tgt (cons peer-host peer-port)))
    (if (and (>= (length inner) 20) (= (rd-u32be inner 4) +stun-magic+))
        (ice-handle-stun agent inner :relay-send tgt)
        (progn
          (setf (ice-agent-peer agent) (list :relay-send tgt))
          (when (ice-agent-on-packet agent)
            (funcall (ice-agent-on-packet agent) inner :relay-send tgt))))))

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
                       (ice-dispatch agent buf len host port)))
                 (error () (unless (ice-agent-stop agent) (sleep 0.005)))))))
         :name "webrtc-data-ice"))
  agent)

(defun ice-close (agent)
  (setf (ice-agent-stop agent) t)
  (ignore-errors (sb-bsd-sockets:socket-close (ice-agent-socket agent)))
  (ignore-errors (bt:destroy-thread (ice-agent-thread agent))))
