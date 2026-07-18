;;;; src/turn.lisp — a TURN client (RFC 5766 / 8656): gather a *relay* ICE candidate.
;;;;
;;;; STUN's server-reflexive candidate only works when the NAT keeps a stable public mapping
;;;; (cone NATs).  A symmetric NAT picks a fresh port per destination, so the mapping the peer
;;;; was told about is dead by the time the peer aims at it.  TURN sidesteps that: the client
;;;; asks a relay server to Allocate a public transport address and forwards all peer traffic
;;;; through it, so the peer only ever talks to the relay (a stable, server-side address).
;;;;
;;;; We reuse stun.lisp for message framing.  On top of it TURN adds long-term credentials
;;;; (USERNAME/REALM/NONCE + MESSAGE-INTEGRITY keyed by MD5(user:realm:pass)), the Allocate /
;;;; CreatePermission / ChannelBind / Refresh methods, and — for the actual bytes — ChannelData,
;;;; a bare 4-byte-framed datagram (NOT a STUN message) that rides straight to the server.
;;;;
;;;; Integration with ice.lisp: a relay-selected peer is `ice-agent-peer = (list :relay chan)`;
;;;; ice-send wraps such sends as ChannelData to the server, and the ice-serve recv loop unwraps
;;;; inbound ChannelData (and Data indications) from the server back into peer packets.

(in-package #:webrtc-data)

;;; ---- methods (STUN message types: class bits interleaved into the method) ---------------
;;; request class = 00, success = 10, error = 11.  encode-stun takes the full 14-bit type.
(defparameter +turn-allocate+           #x0003)
(defparameter +turn-allocate-success+   #x0103)
(defparameter +turn-allocate-error+     #x0113)
(defparameter +turn-refresh+            #x0004)
(defparameter +turn-refresh-success+    #x0104)
(defparameter +turn-create-perm+        #x0008)
(defparameter +turn-create-perm-success+ #x0108)
(defparameter +turn-channel-bind+       #x0009)
(defparameter +turn-channel-bind-success+ #x0109)
(defparameter +turn-send-indication+    #x0016)
(defparameter +turn-data-indication+    #x0017)

;;; ---- attributes ------------------------------------------------------------------------
(defparameter +attr-channel-number+     #x000C)
(defparameter +attr-lifetime+           #x000D)
(defparameter +attr-xor-peer-address+   #x0012)
(defparameter +attr-data+               #x0013)
(defparameter +attr-realm+              #x0014)
(defparameter +attr-nonce+              #x0015)
(defparameter +attr-xor-relayed-address+ #x0016)
(defparameter +attr-requested-transport+ #x0019)
(defparameter +attr-error-code+         #x0009)
(defparameter +attr-software+           #x8022)

(defparameter +turn-channel-min+ #x4000)
(defparameter +turn-channel-max+ #x7FFF)

(defstruct turn-alloc
  socket                                   ; the ICE UDP socket (shared with the ICE agent)
  server-host                              ; TURN server IP as a 4-octet vector (sb-bsd address form)
  server-port
  user pass realm nonce
  key                                      ; long-term key = MD5(user ":" realm ":" pass) bytes
  relay-ip relay-port                      ; the Allocate'd relayed transport address (dotted / int)
  mapped-ip mapped-port                    ; our reflexive addr as the TURN server saw it (bonus srflx)
  (lifetime 600)
  (next-channel +turn-channel-min+)
  (peer->chan (make-hash-table :test 'equal))   ; "ip:port" -> channel-number
  (chan->peer (make-hash-table))                ; channel-number -> (ip-string . port)
  (perms (make-hash-table :test 'equal))        ; "ip" -> t  (installed permissions)
  (resp-lock (bt:make-lock))                     ; recv-loop delivers control responses here
  (resp-cv (bt:make-condition-variable))
  (resp nil)                                     ; (list tid type attrs) — last control response
  (binding (make-hash-table :test 'equal))       ; "ip:port" -> t while a background bind is in flight
  (refresh-thread nil))

;;; ---- long-term credential key ----------------------------------------------------------

(defun turn-long-term-key (user realm pass)
  "RFC 5766 §4: the MESSAGE-INTEGRITY HMAC-SHA1 key for long-term credentials is the 16-byte
MD5 digest of \"username:realm:password\"."
  (ic:digest-sequence :md5 (ascii (format nil "~a:~a:~a" user realm pass))))

;;; ---- server-address helpers ------------------------------------------------------------

(defun %inet (dotted) (sb-bsd-sockets:make-inet-address dotted))

(defun %from-turn-server-p (alloc host port)
  "Is a received datagram's source (HOST 4-octet vector, PORT) the TURN server?"
  (and alloc (equalp host (turn-alloc-server-host alloc))
       (eql port (turn-alloc-server-port alloc))))

;;; ---- authenticated request builder -----------------------------------------------------

(defun %turn-auth-attrs (alloc extra)
  "Prepend USERNAME/REALM/NONCE to EXTRA (the caller adds MESSAGE-INTEGRITY via :integrity-key)."
  (append extra
          (list (cons +attr-username+ (ascii (turn-alloc-user alloc)))
                (cons +attr-realm+   (ascii (turn-alloc-realm alloc)))
                (cons +attr-nonce+   (as-u8vec (turn-alloc-nonce alloc))))))

(defun %send-to-server (alloc bytes)
  (sb-bsd-sockets:socket-send (turn-alloc-socket alloc) (as-u8vec bytes) (length bytes)
                              :address (list (turn-alloc-server-host alloc)
                                             (turn-alloc-server-port alloc))))

;;; ---- blocking transaction (used before ICE-SERVE owns the socket) ----------------------

(defun %recv-stun-blocking (sock tid want-types timeout)
  "Read datagrams from SOCK until one is a STUN reply with transaction id TID whose type is in
WANT-TYPES, or TIMEOUT elapses.  Returns (values type attrs) or NIL.  Non-matching datagrams
(e.g. a straggler STUN Binding, or ChannelData) are skipped."
  (let ((deadline (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second))))
        (buf (make-array 2048 :element-type '(unsigned-byte 8))))
    (loop
      (let ((remain (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
        (when (<= remain 0) (return nil))
        (when (sb-sys:wait-until-fd-usable (sb-bsd-sockets:socket-file-descriptor sock)
                                           :input (min 1.0 remain))
          (multiple-value-bind (b len) (sb-bsd-sockets:socket-receive sock buf nil)
            (declare (ignore b))
            (when (and len (>= len 20))
              (let ((pkt (subseq buf 0 len)))
                (when (= (rd-u32be pkt 4) +stun-magic+)
                  (multiple-value-bind (type rtid attrs) (decode-stun pkt)
                    (when (and (equalp rtid tid) (member type want-types))
                      (return (values type attrs)))))))))))))

(defun %turn-request (alloc type extra &key (want-success nil) (timeout 2.0) authed)
  "Send one TURN request of TYPE with EXTRA attrs (auth attrs + MI added when AUTHED) and wait,
via the shared socket, for its reply.  Returns (values success-type-or-error-type attrs tid).
Use only BEFORE ice-serve starts (it reads the socket directly)."
  (let* ((tid (stun-transaction-id))
         (attrs (if authed (%turn-auth-attrs alloc extra) extra))
         (msg (encode-stun type tid attrs
                           :integrity-key (and authed (turn-alloc-key alloc)))))
    (%send-to-server alloc msg)
    (multiple-value-bind (rtype rattrs)
        (%recv-stun-blocking (turn-alloc-socket alloc) tid
                             (list want-success (logior type #x0110)) ; success | error type
                             timeout)
      (values rtype rattrs tid))))

;;; ---- Allocate (RFC 5766 §6) ------------------------------------------------------------

(defun %parse-error-code (attrs)
  "ERROR-CODE value -> integer code (class*100 + number), or NIL."
  (let ((v (stun-attr attrs +attr-error-code+)))
    (when (and v (>= (length v) 4))
      (+ (* 100 (logand (aref v 2) #x07)) (aref v 3)))))

(defun turn-allocate (alloc &key (timeout 2.0))
  "Do the Allocate dance: an unauthenticated Allocate draws a 401 carrying REALM+NONCE; retry
with long-term credentials.  On success record the XOR-RELAYED-ADDRESS + LIFETIME.  Returns T."
  (let ((req-transport (as-u8vec '(17 0 0 0))))     ; REQUESTED-TRANSPORT: UDP (17), RFFU=0
    ;; 1st attempt: unauthenticated -> expect 401 with realm+nonce.
    (multiple-value-bind (rtype rattrs)
        (%turn-request alloc +turn-allocate+
                       (list (cons +attr-requested-transport+ req-transport)
                             (cons +attr-software+ (ascii "webrtc-data")))
                       :want-success +turn-allocate-success+ :timeout timeout :authed nil)
      (unless rtype (return-from turn-allocate nil))
      (when (eql rtype +turn-allocate-success+)      ; open relay (no auth) — unusual but ok
        (return-from turn-allocate (%ingest-allocate-success alloc rattrs)))
      ;; 401: read realm+nonce, derive key, retry authenticated.
      (let ((realm (stun-attr rattrs +attr-realm+))
            (nonce (stun-attr rattrs +attr-nonce+)))
        (unless (and realm nonce) (return-from turn-allocate nil))
        (setf (turn-alloc-realm alloc) (bytes->ascii realm)
              (turn-alloc-nonce alloc) nonce
              (turn-alloc-key alloc)   (turn-long-term-key (turn-alloc-user alloc)
                                                           (turn-alloc-realm alloc)
                                                           (turn-alloc-pass alloc))))
      (multiple-value-bind (rtype2 rattrs2)
          (%turn-request alloc +turn-allocate+
                         (list (cons +attr-requested-transport+ req-transport))
                         :want-success +turn-allocate-success+ :timeout timeout :authed t)
        (cond
          ((eql rtype2 +turn-allocate-success+) (%ingest-allocate-success alloc rattrs2))
          ;; stale nonce on the retry: adopt the fresh nonce and try once more.
          ((and rtype2 (eql (%parse-error-code rattrs2) 438))
           (let ((n (stun-attr rattrs2 +attr-nonce+)))
             (when n (setf (turn-alloc-nonce alloc) n)))
           (multiple-value-bind (rt3 ra3)
               (%turn-request alloc +turn-allocate+
                              (list (cons +attr-requested-transport+ req-transport))
                              :want-success +turn-allocate-success+ :timeout timeout :authed t)
             (when (eql rt3 +turn-allocate-success+) (%ingest-allocate-success alloc ra3))))
          (t nil))))))

(defun %ingest-allocate-success (alloc attrs)
  (multiple-value-bind (rip rport)
      (parse-xor-mapped-address (stun-attr attrs +attr-xor-relayed-address+))
    (unless rip (return-from %ingest-allocate-success nil))
    (setf (turn-alloc-relay-ip alloc) rip
          (turn-alloc-relay-port alloc) rport)
    (multiple-value-bind (mip mport)
        (parse-xor-mapped-address (stun-attr attrs +attr-xor-mapped-address+))
      (when mip (setf (turn-alloc-mapped-ip alloc) mip (turn-alloc-mapped-port alloc) mport)))
    (let ((lt (stun-attr attrs +attr-lifetime+)))
      (when (and lt (>= (length lt) 4)) (setf (turn-alloc-lifetime alloc) (rd-u32be lt 0))))
    t))

;;; ---- CreatePermission (§9) + ChannelBind (§11) -----------------------------------------

(defun turn-create-permission (alloc peer-ip &key (timeout 2.0))
  "Install a permission so the server relays peer->us traffic from PEER-IP (a dotted string).
Idempotent per IP within an allocation's permission lifetime."
  (multiple-value-bind (rtype)
      (%turn-request alloc +turn-create-perm+
                     (list (cons +attr-xor-peer-address+ (xor-mapped-address (%inet peer-ip) 0)))
                     :want-success +turn-create-perm-success+ :timeout timeout :authed t)
    (cond
      ((eql rtype +turn-create-perm-success+) (setf (gethash peer-ip (turn-alloc-perms alloc)) t) t)
      (t nil))))

(defun turn-channel-bind (alloc peer-ip peer-port &key (timeout 2.0))
  "Bind (allocate if needed) a channel number to the peer transport address PEER-IP:PEER-PORT so
data can ride the low-overhead ChannelData framing.  Returns the channel number or NIL."
  (let* ((k (format nil "~a:~d" peer-ip peer-port))
         (chan (or (gethash k (turn-alloc-peer->chan alloc))
                   (let ((c (turn-alloc-next-channel alloc)))
                     (setf (turn-alloc-next-channel alloc) (1+ c)) c))))
    (multiple-value-bind (rtype)
        (%turn-request alloc +turn-channel-bind+
                       (list (cons +attr-channel-number+ (cat-bytes (u16be chan) (u16be 0)))
                             (cons +attr-xor-peer-address+ (xor-mapped-address (%inet peer-ip) peer-port)))
                       :want-success +turn-channel-bind-success+ :timeout timeout :authed t)
      (when (eql rtype +turn-channel-bind-success+)
        (setf (gethash k (turn-alloc-peer->chan alloc)) chan
              (gethash chan (turn-alloc-chan->peer alloc)) (cons peer-ip peer-port)
              (gethash peer-ip (turn-alloc-perms alloc)) t)   ; ChannelBind implies a permission
        chan))))

(defun turn-install-peer (alloc peer-ip peer-port)
  "Ensure the server will relay to/from PEER-IP:PEER-PORT: CreatePermission then ChannelBind.
Returns the channel number, or NIL.  Blocking — call BEFORE ice-serve."
  (turn-create-permission alloc peer-ip)
  (turn-channel-bind alloc peer-ip peer-port))

;;; ---- ChannelData framing (hot path, per packet) ----------------------------------------

(declaim (ftype (function (fixnum t) u8vec) turn-wrap-channeldata))
(defun turn-wrap-channeldata (chan data)
  "Frame DATA under CHAN as a ChannelData message: [channel(2)][length(2)][data], 4-byte header.
Sent straight to the TURN server — NOT a STUN message."
  (declare (type fixnum chan) (optimize (speed 3) (safety 0)))
  (let* ((d (as-u8vec data)) (n (length d)) (out (u8vec (+ 4 n))))
    (declare (type u8vec d out) (type fixnum n))
    (setf (aref out 0) (u8! (ash chan -8))
          (aref out 1) (u8! chan)
          (aref out 2) (u8! (ash n -8))
          (aref out 3) (u8! n))
    (replace out d :start1 4)
    out))

(declaim (inline turn-channeldata-p))
(defun turn-channeldata-p (pkt len)
  "Fast test: does a datagram (from the TURN server) start with a ChannelData channel number?"
  (declare (type u8vec pkt) (type fixnum len) (optimize (speed 3) (safety 0)))
  (and (>= len 4)
       (let ((c (logior (ash (aref pkt 0) 8) (aref pkt 1))))
         (declare (type fixnum c))
         (and (>= c +turn-channel-min+) (<= c +turn-channel-max+)))))

(defun turn-wrap-send-indication (alloc peer-host peer-port data)
  "Build a Send indication (§10) carrying DATA to PEER-HOST:PEER-PORT.  Indications are NOT
authenticated — used to reach a peer before/without a bound channel."
  (encode-stun +turn-send-indication+ (stun-transaction-id)
               (list (cons +attr-xor-peer-address+ (xor-mapped-address peer-host peer-port))
                     (cons +attr-data+ (as-u8vec data)))))

;;; ---- Refresh (§7) ----------------------------------------------------------------------

(defun turn-refresh (alloc &key (lifetime nil) (timeout 2.0))
  "Refresh the allocation (or release it with LIFETIME 0).  Handles a 438 stale-nonce by
re-reading NONCE and retrying once.  NOTE: only safe to call while the socket is not being read
by ice-serve; the timer path uses the recv-loop-delivered response instead (see turn-start-refresh)."
  (let ((lt (or lifetime (turn-alloc-lifetime alloc))))
    (flet ((one ()
             (%turn-request alloc +turn-refresh+
                            (list (cons +attr-lifetime+ (u32be lt)))
                            :want-success +turn-refresh-success+ :timeout timeout :authed t)))
      (multiple-value-bind (rtype rattrs) (one)
        (cond
          ((eql rtype +turn-refresh-success+) t)
          ((and rtype (eql (%parse-error-code rattrs) 438))
           (let ((n (stun-attr rattrs +attr-nonce+))) (when n (setf (turn-alloc-nonce alloc) n)))
           (eql (nth-value 0 (one)) +turn-refresh-success+))
          (t nil))))))

;;; ---- recv-loop-delivered control responses (while ICE-SERVE owns the socket) -----------

(defun turn-deliver-control (alloc tid type attrs)
  "Called by the ice-serve recv loop for a STUN *control* response from the TURN server: hand it
to whoever is blocked in %turn-txn-loop for this transaction."
  (bt:with-lock-held ((turn-alloc-resp-lock alloc))
    (setf (turn-alloc-resp alloc) (list tid type attrs))
    (bt:condition-notify (turn-alloc-resp-cv alloc))))

(defun %turn-txn-loop (alloc type extra &key want-success (timeout 2.0))
  "Like %turn-request but waits for the response the recv loop delivers (no direct socket read).
Use once ice-serve is running.  Returns (values type attrs)."
  (let* ((tid (stun-transaction-id))
         (msg (encode-stun type tid (%turn-auth-attrs alloc extra)
                           :integrity-key (turn-alloc-key alloc)))
         (deadline (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second)))))
    (bt:with-lock-held ((turn-alloc-resp-lock alloc))
      (setf (turn-alloc-resp alloc) nil)
      (%send-to-server alloc msg)
      (loop
        (let ((r (turn-alloc-resp alloc)))
          (when (and r (equalp (first r) tid)
                     (member (second r) (list want-success (logior type #x0110))))
            (setf (turn-alloc-resp alloc) nil)
            (return (values (second r) (third r)))))
        (let ((remain (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)))
          (when (<= remain 0) (return nil))
          (bt:condition-wait (turn-alloc-resp-cv alloc) (turn-alloc-resp-lock alloc)
                             :timeout (min 0.5 remain)))))))

(defun turn-refresh-via-loop (alloc &key (lifetime nil) (timeout 2.0))
  "Refresh using the recv-loop-delivered response (safe while ice-serve runs)."
  (let ((lt (or lifetime (turn-alloc-lifetime alloc))))
    (flet ((one () (%turn-txn-loop alloc +turn-refresh+ (list (cons +attr-lifetime+ (u32be lt)))
                                   :want-success +turn-refresh-success+ :timeout timeout)))
      (multiple-value-bind (rtype rattrs) (one)
        (cond
          ((eql rtype +turn-refresh-success+) t)
          ((and rtype (eql (%parse-error-code rattrs) 438))
           (let ((n (stun-attr rattrs +attr-nonce+))) (when n (setf (turn-alloc-nonce alloc) n)))
           (eql (nth-value 0 (one)) +turn-refresh-success+))
          (t nil))))))

(defun turn-start-refresh (alloc stop-fn)
  "Spawn a timer thread that Refreshes the allocation before it expires (~LIFETIME/2), until
STOP-FN returns true.  Keeps the relay alive across a long session."
  (bt:make-thread
   (lambda ()
     (loop until (funcall stop-fn) do
       (let ((half (max 30 (floor (turn-alloc-lifetime alloc) 2))))
         (loop repeat half until (funcall stop-fn) do (sleep 1))
         (unless (funcall stop-fn) (ignore-errors (turn-refresh-via-loop alloc))))))
   :name "turn-refresh"))
