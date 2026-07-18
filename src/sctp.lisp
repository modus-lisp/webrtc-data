;;;; src/sctp.lisp — a minimal SCTP association + DCEP over the DTLS flow.
;;;;
;;;; This is the top of the WebRTC data-channel stack: aiortc (or a browser) runs SCTP
;;;; (RFC 4960) inside the DTLS application-data stream we already established, and the
;;;; DATA_CHANNEL protocol (DCEP, RFC 8832) on top of that.  We implement the minimal
;;;; subset needed for a working data channel:
;;;;
;;;;   * common header framing with the CRC32c checksum (RFC 3309),
;;;;   * the 4-way association handshake as the RESPONDER (server): aiortc is the ICE
;;;;     controlling agent, so it is the SCTP *client* and sends INIT; we reply INIT-ACK
;;;;     (with a State Cookie), receive COOKIE-ECHO, reply COOKIE-ACK -> ESTABLISHED,
;;;;   * DATA chunks (unfragmented, ordered) with per-packet SACKs,
;;;;   * HEARTBEAT ack, and DCEP DATA_CHANNEL_OPEN -> DATA_CHANNEL_ACK.
;;;;
;;;; Deliberately NOT implemented (fine for the MVP / a single reliable data channel):
;;;; fragmentation/reassembly, congestion control, retransmission of our own DATA,
;;;; FORWARD-TSN / partial reliability, and RE-CONFIG.  We also do NOT advertise the
;;;; PRSCTP or supported-chunk-extensions parameters, so aiortc falls back to plain
;;;; DATA=0 chunks (no I-DATA).
;;;;
;;;; Transport glue (from dtls.lisp / seal): send an SCTP packet with
;;;; (seal:dtls-send-app session packet-bytes); receive by popping a datagram from the
;;;; mailbox and running (seal:dtls-handle-datagram session datagram) -> list of SCTP
;;;; packets.

(in-package #:cl-webrtc)

;;; ---- constants -------------------------------------------------------------

(defconstant +sctp-port+ 5000)               ; a=sctp-port, both sides in WebRTC

;; chunk types
(defconstant +chunk-data+        0)
(defconstant +chunk-init+        1)
(defconstant +chunk-init-ack+    2)
(defconstant +chunk-sack+        3)
(defconstant +chunk-heartbeat+   4)
(defconstant +chunk-heartbeat-ack+ 5)
(defconstant +chunk-abort+       6)
(defconstant +chunk-shutdown+    7)
(defconstant +chunk-cookie-echo+ 10)
(defconstant +chunk-cookie-ack+  11)

;; DATA chunk flags
(defconstant +data-flag-last+  #x01)         ; E
(defconstant +data-flag-first+ #x02)         ; B
(defconstant +data-flag-unordered+ #x04)     ; U
(defconstant +data-flag-be+ (logior +data-flag-first+ +data-flag-last+))  ; unfragmented

;; SCTP parameter types
(defconstant +param-state-cookie+ #x0007)

;; PPIDs (RFC 8831 §8)
(defconstant +ppid-dcep+          50)
(defconstant +ppid-string+        51)
(defconstant +ppid-binary+        53)
(defconstant +ppid-string-empty+  56)
(defconstant +ppid-binary-empty+  57)

;; DCEP (RFC 8832)
(defconstant +dcep-open+ #x03)
(defconstant +dcep-ack+  #x02)

;;; ---- CRC32c checksum (RFC 3309) --------------------------------------------
;;;
;;; ironclad's :crc32c digest returns the CRC value as 4 big-endian bytes (verified
;;; against the standard "123456789" -> 0xE3069283 vector).  SCTP stores the checksum
;;; in the common header *little-endian*, so the field bytes are the digest reversed.

(defun sctp-crc32c-value (bytes)
  (rd-u32be (ic:digest-sequence :crc32c bytes) 0))

;;; ---- packet + chunk framing ------------------------------------------------

(defun sctp-chunk (type flags value)
  "Encode one chunk (type, flags, value bytes), padded to a 4-byte boundary."
  (let* ((len (+ 4 (length value)))
         (pad (mod (- (mod len 4)) 4)))
    (cat-bytes (as-u8vec (list (u8! type) (u8! flags))) (u16be len)
               value (u8vec pad))))

(defun sctp-packet (verification-tag &rest chunk-byte-vectors)
  "Build a full SCTP packet: common header (ports 5000, VERIFICATION-TAG, CRC32c) +
the given already-encoded chunks."
  (let* ((body (apply #'cat-bytes chunk-byte-vectors))
         (pkt (cat-bytes (u16be +sctp-port+) (u16be +sctp-port+)
                         (u32be verification-tag) (u32be 0) body))
         (crc (sctp-crc32c-value pkt)))       ; computed with checksum field = 0
    ;; store the CRC little-endian into the checksum field (offset 8..11)
    (setf (aref pkt 8)  (u8! crc)
          (aref pkt 9)  (u8! (ash crc -8))
          (aref pkt 10) (u8! (ash crc -16))
          (aref pkt 11) (u8! (ash crc -24)))
    pkt))

;;; ---- association state -----------------------------------------------------

(defstruct sctp-assoc
  session                                    ; seal DTLS session (transport)
  (state :closed)                            ; :closed :established
  (local-tag (logior 1 (rd-u32be (random-bytes 4) 0)))   ; our initiate tag
  peer-tag                                   ; aiortc's initiate tag (verification tag we send)
  (local-tsn (rd-u32be (random-bytes 4) 0))  ; our next outbound TSN
  (a-rwnd #x100000)                          ; advertised receive window
  last-received-tsn                          ; cumulative TSN we can ack
  (stream-seq (make-hash-table))             ; per-stream outbound ordered sequence number
  on-message                                 ; (funcall on-message assoc stream-id string)
  on-ready                                   ; (funcall on-ready assoc stream-id) at DCEP OPEN
  (send-lock (bt:make-recursive-lock))       ; serialize sends (receive loop + app threads)
  (log nil))                                 ; optional stream for debug logging

(defun sctp-log (assoc fmt &rest args)
  (when (sctp-assoc-log assoc)
    (apply #'format (sctp-assoc-log assoc) fmt args)
    (finish-output (sctp-assoc-log assoc))))

(defun sctp-transmit (assoc &rest chunk-byte-vectors)
  "Wrap CHUNK-BYTE-VECTORS in a packet carrying the peer's verification tag and send it
over DTLS.  Locked: the DTLS record layer (sequence numbers) is not thread-safe, and the
glass framebuffer pump sends concurrently with the SCTP receive loop."
  (bt:with-recursive-lock-held ((sctp-assoc-send-lock assoc))
    (seal:dtls-send-app (sctp-assoc-session assoc)
                        (apply #'sctp-packet (or (sctp-assoc-peer-tag assoc) 0)
                               chunk-byte-vectors))))

;;; ---- outbound chunks -------------------------------------------------------

(defun sctp-next-stream-seq (assoc stream-id)
  (let ((v (gethash stream-id (sctp-assoc-stream-seq assoc) 0)))
    (setf (gethash stream-id (sctp-assoc-stream-seq assoc)) (logand (1+ v) #xffff))
    v))

(defun sctp-send-data (assoc stream-id ppid data)
  "Send one unfragmented, ordered DATA chunk on STREAM-ID with the given PPID."
  (bt:with-recursive-lock-held ((sctp-assoc-send-lock assoc))
    (let* ((data (as-u8vec data))
           (tsn (sctp-assoc-local-tsn assoc))
           (seq (sctp-next-stream-seq assoc stream-id))
           (value (cat-bytes (u32be tsn) (u16be stream-id) (u16be seq)
                             (u32be ppid) data)))
      (setf (sctp-assoc-local-tsn assoc) (logand (1+ tsn) #xffffffff))
      (sctp-transmit assoc (sctp-chunk +chunk-data+ +data-flag-be+ value))
      (sctp-log assoc "~&  >> DATA tsn=~a stream=~a ppid=~a len=~a~%"
                tsn stream-id ppid (length data)))))

(defun sctp-send-string (assoc stream-id string)
  "Send STRING as a WebRTC string message (PPID 51) on STREAM-ID."
  (let ((bytes (ascii string)))
    (if (zerop (length bytes))
        (sctp-send-data assoc stream-id +ppid-string-empty+ #(0))  ; empty needs 1 byte
        (sctp-send-data assoc stream-id +ppid-string+ bytes))))

(defun sctp-send-binary (assoc stream-id bytes)
  "Send BYTES as a WebRTC binary message (PPID 53) on STREAM-ID."
  (let ((b (as-u8vec bytes)))
    (if (zerop (length b))
        (sctp-send-data assoc stream-id +ppid-binary-empty+ #(0))
        (sctp-send-data assoc stream-id +ppid-binary+ b))))

(defun sctp-send-sack (assoc)
  (let ((value (cat-bytes (u32be (sctp-assoc-last-received-tsn assoc))
                          (u32be (sctp-assoc-a-rwnd assoc))
                          (u16be 0) (u16be 0))))     ; 0 gap blocks, 0 duplicates
    (sctp-transmit assoc (sctp-chunk +chunk-sack+ 0 value))
    (sctp-log assoc "~&  >> SACK cum=~a~%" (sctp-assoc-last-received-tsn assoc))))

(defun sctp-send-init-ack (assoc)
  "Respond to an INIT: advertise our tag/window/streams/TSN plus a State Cookie.  We are
stateful (one association) so the cookie is an opaque blob the peer just echoes back."
  (let* ((cookie (random-bytes 16))
         (cookie-param (cat-bytes (u16be +param-state-cookie+)
                                  (u16be (+ 4 (length cookie))) cookie))
         (value (cat-bytes (u32be (sctp-assoc-local-tag assoc))
                           (u32be (sctp-assoc-a-rwnd assoc))
                           (u16be 65535)                 ; outbound streams
                           (u16be 65535)                 ; inbound streams
                           (u32be (sctp-assoc-local-tsn assoc))
                           cookie-param)))
    (sctp-transmit assoc (sctp-chunk +chunk-init-ack+ 0 value))
    (sctp-log assoc "~&  >> INIT-ACK our-tag=~a peer-tag=~a~%"
              (sctp-assoc-local-tag assoc) (sctp-assoc-peer-tag assoc))))

;;; ---- inbound processing ----------------------------------------------------

(defun sctp-handle-init (assoc value)
  "VALUE is the INIT chunk value: initiate_tag(4) a_rwnd(4) out(2) in(2) initial_tsn(4)."
  (setf (sctp-assoc-peer-tag assoc) (rd-u32be value 0))
  (let ((peer-initial-tsn (rd-u32be value 12)))
    (setf (sctp-assoc-last-received-tsn assoc)
          (logand (1- peer-initial-tsn) #xffffffff)))
  (sctp-log assoc "~&  << INIT peer-tag=~a initial-tsn=~a~%"
            (sctp-assoc-peer-tag assoc) (rd-u32be value 12))
  (sctp-send-init-ack assoc))

(defun sctp-handle-dcep (assoc stream-id data)
  "DCEP control message on STREAM-ID (PPID 50)."
  (when (plusp (length data))
    (let ((msg-type (aref data 0)))
      (cond
        ((= msg-type +dcep-open+)
         (sctp-log assoc "~&  << DCEP OPEN stream=~a -> ACK~%" stream-id)
         ;; reply with a single-byte DATA_CHANNEL_ACK on the same stream
         (sctp-send-data assoc stream-id +ppid-dcep+ (as-u8vec (list +dcep-ack+)))
         ;; channel is open — let the app (e.g. the glass bridge) start pushing bytes
         (when (sctp-assoc-on-ready assoc)
           (funcall (sctp-assoc-on-ready assoc) assoc stream-id)))
        ((= msg-type +dcep-ack+)
         (sctp-log assoc "~&  << DCEP ACK stream=~a~%" stream-id))))))

(defun sctp-handle-data (assoc value)
  "VALUE is the DATA chunk value: TSN(4) stream_id(2) stream_seq(2) PPID(4) user_data."
  (let* ((tsn (rd-u32be value 0))
         (stream-id (rd-u16be value 4))
         (ppid (rd-u32be value 8))
         (user (subseq value 12)))
    ;; advance cumulative TSN (in-order assumed; no gap tracking)
    (setf (sctp-assoc-last-received-tsn assoc) tsn)
    (sctp-log assoc "~&  << DATA tsn=~a stream=~a ppid=~a len=~a~%"
              tsn stream-id ppid (length user))
    (cond
      ((= ppid +ppid-dcep+) (sctp-handle-dcep assoc stream-id user))
      ((or (= ppid +ppid-string+) (= ppid +ppid-string-empty+))
       (when (sctp-assoc-on-message assoc)
         (funcall (sctp-assoc-on-message assoc) assoc stream-id
                  (bytes->ascii user))))
      ((or (= ppid +ppid-binary+) (= ppid +ppid-binary-empty+))
       (when (sctp-assoc-on-message assoc)
         (funcall (sctp-assoc-on-message assoc) assoc stream-id user))))))

(defun sctp-input (assoc packet)
  "Process one inbound SCTP packet (already decrypted out of DTLS).  Iterates its chunks,
handling INIT / COOKIE-ECHO / DATA / HEARTBEAT, and sends a SACK if any DATA arrived."
  (when (< (length packet) 12) (return-from sctp-input))
  (let ((pos 12) (len (length packet)) (data-seen nil))
    (loop while (<= (+ pos 4) len) do
      (let* ((ctype (aref packet pos))
             (cflags (aref packet (+ pos 1)))
             (clen (rd-u16be packet (+ pos 2))))
        (when (< clen 4) (return))
        (when (> (+ pos clen) len) (return))
        (let ((value (subseq packet (+ pos 4) (+ pos clen))))
          (cond
            ((= ctype +chunk-init+)        (sctp-handle-init assoc value))
            ((= ctype +chunk-cookie-echo+)
             (sctp-log assoc "~&  << COOKIE-ECHO -> COOKIE-ACK (ESTABLISHED)~%")
             (setf (sctp-assoc-state assoc) :established)
             (sctp-transmit assoc (sctp-chunk +chunk-cookie-ack+ 0 #())))
            ((= ctype +chunk-data+)        (setf data-seen t)
                                           (sctp-handle-data assoc value))
            ((= ctype +chunk-heartbeat+)
             ;; echo the params back as a HEARTBEAT-ACK
             (sctp-transmit assoc (sctp-chunk +chunk-heartbeat-ack+ 0 value)))
            ((= ctype +chunk-sack+))       ; we don't retransmit; nothing to do
            ((= ctype +chunk-cookie-ack+))
            ((= ctype +chunk-abort+)
             (sctp-log assoc "~&  << ABORT~%") (setf (sctp-assoc-state assoc) :aborted))
            ((= ctype +chunk-shutdown+)
             (sctp-log assoc "~&  << SHUTDOWN~%"))
            (t (sctp-log assoc "~&  << unhandled chunk type ~a~%" ctype))))
        ;; advance past chunk + padding
        (incf pos (+ clen (mod (- (mod clen 4)) 4)))))
    (when data-seen (sctp-send-sack assoc))))

;;; ---- driver: run the association over a DTLS-CONN --------------------------

(defun webrtc-serve-datachannel (conn &key on-message on-ready (duration 30.0) log)
  "Run the SCTP association + DCEP over the (already handshaked) DTLS-CONN for up to DURATION
seconds (or until the peer ABORTs), pumping inbound datagrams from the mailbox.  ON-MESSAGE,
if given, is called as (funcall on-message ASSOC STREAM-ID PAYLOAD) for each inbound message
— a string for PPID 51, raw bytes for PPID 53.  ON-READY, if given, is called as
(funcall on-ready ASSOC STREAM-ID) once the channel opens (DCEP OPEN) — the moment a bridge
should start pushing bytes (e.g. glass, whose RFB server speaks first).  Returns the
SCTP-ASSOC.  Higher layers push with SCTP-SEND-DATA / SCTP-SEND-STRING and pull via ON-MESSAGE."
  (let* ((session (dtls-conn-session conn))
         (mb (dtls-conn-mailbox conn))
         (assoc (make-sctp-assoc :session session :on-message on-message :on-ready on-ready :log log))
         (deadline (+ (get-internal-real-time)
                      (round (* duration internal-time-units-per-second)))))
    (loop while (and (< (get-internal-real-time) deadline)
                     (not (eq (sctp-assoc-state assoc) :aborted)))
          do (let ((dg (mailbox-pop mb 1.0)))
               (when dg
                 (dolist (sctp (seal:dtls-handle-datagram session dg))
                   (handler-case (sctp-input assoc sctp)
                     (error (e) (sctp-log assoc "~&  !! sctp-input error: ~a~%" e)))))))
    assoc))
