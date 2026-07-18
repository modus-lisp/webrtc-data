;;;; src/sctp.lisp — a reliable, flow-controlled SCTP association + DCEP over DTLS.
;;;;
;;;; This is the top of the WebRTC data-channel stack: aiortc (or a browser) runs SCTP
;;;; (RFC 4960) inside the DTLS application-data stream we already established, and the
;;;; DATA_CHANNEL protocol (DCEP, RFC 8832) on top of that.
;;;;
;;;;   * common header framing with the CRC32c checksum (RFC 3309),
;;;;   * the 4-way association handshake as the RESPONDER (server): aiortc is the ICE
;;;;     controlling agent, so it is the SCTP *client* and sends INIT; we reply INIT-ACK
;;;;     (with a State Cookie), receive COOKIE-ECHO, reply COOKIE-ACK -> ESTABLISHED,
;;;;   * DATA chunks (unfragmented, ordered) on one reliable stream, with a genuine
;;;;     RFC 4960 transmit path: a send queue, retransmission (RTO + fast retransmit),
;;;;     slow-start/congestion-avoidance congestion control, and flow control that
;;;;     honours the peer's advertised receive window (a_rwnd) learned from SACKs,
;;;;   * an in-order receive path that buffers out-of-order TSNs and reports gaps +
;;;;     duplicates back in our SACKs (TSN serial arithmetic, 32-bit wrap safe),
;;;;   * HEARTBEAT ack, and DCEP DATA_CHANNEL_OPEN -> DATA_CHANNEL_ACK.
;;;;
;;;; Deliberately NOT implemented (fine for a single reliable data channel carrying
;;;; RFB messages that the gateway already chunks to <=1024B): fragmentation/reassembly
;;;; (I-DATA / DATA fragments), FORWARD-TSN / partial reliability (PR-SCTP), RE-CONFIG,
;;;; and multihoming.  We advertise no chunk extensions, so aiortc uses plain DATA=0.
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

;;; ---- reliability / congestion-control tunables -----------------------------

(defconstant +sctp-mtu+ 1200)                ; nominal path MTU (bytes) for cc math
(defconstant +sctp-cwnd-init+ 4380)          ; min(4*MTU, max(2*MTU, 4380))
(defconstant +sctp-send-q-max+ 512)          ; backpressure bound on the ready queue
(defconstant +sctp-rto-init+ 1.0d0)          ; initial retransmit timeout (s)
(defconstant +sctp-rto-min+  0.4d0)          ; snappy LAN recovery (RFC min is 1s)
(defconstant +sctp-rto-max+  60.0d0)
(defconstant +sctp-fast-rtx-threshold+ 3)    ; missing reports before fast retransmit
(defconstant +sctp-dup-report-max+ 32)       ; cap duplicate TSNs reported per SACK
(defconstant +sctp-max-rto-strikes+ 8)       ; consecutive RTO fires w/o progress -> peer gone

(defparameter *sctp-drop-rate* 0.0
  "TEST AID: probability in [0.0,1.0] that SCTP-TRANSMIT silently drops an outbound
packet instead of handing it to DTLS, simulating artificial outbound packet loss.
Default 0.0 (no loss).  Set e.g. 0.15 to exercise the retransmission path.")

;;; ---- TSN serial arithmetic (RFC 1982, 32-bit) ------------------------------

(declaim (inline u32 tsn< tsn<=))
(defun u32 (x) (logand x #xffffffff))
(defun tsn< (a b) "True if TSN A is strictly before TSN B, wrap-safe."
  (< 0 (u32 (- b a)) #x80000000))
(defun tsn<= (a b) (or (= (u32 a) (u32 b)) (tsn< a b)))

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

(defstruct txc
  "A DATA chunk that has been assigned a TSN: on the send queue, or in flight."
  tsn                                        ; its transmission sequence number
  bytes                                      ; the fully-encoded DATA chunk (ready to wrap)
  size                                       ; user-data payload length (flight/window unit)
  (sent 0)                                   ; internal-real-time it was last transmitted
  (missing 0)                                ; SACK missing-indications (for fast retransmit)
  (retx nil))                                ; ever retransmitted? (Karn: don't sample its RTT)

(defstruct sctp-assoc
  session                                    ; seal DTLS session (transport)
  (state :closed)                            ; :closed :established :aborted
  (local-tag (logior 1 (rd-u32be (random-bytes 4) 0)))   ; our initiate tag
  peer-tag                                   ; aiortc's initiate tag (verification tag we send)
  (local-tsn (rd-u32be (random-bytes 4) 0))  ; our next outbound TSN
  (a-rwnd #x100000)                          ; the receive window WE advertise
  last-received-tsn                          ; cumulative TSN we can ack (a.k.a. cum-tsn)
  (stream-seq (make-hash-table))             ; per-stream outbound ordered sequence number
  ;; --- send side (us -> peer) ---
  (send-q nil) (send-q-tail nil) (send-q-len 0)   ; FIFO of ready (assigned) txc's
  (outstanding (make-hash-table))            ; tsn -> txc, transmitted & unacked
  (flight 0)                                 ; sum of outstanding txc sizes (bytes)
  (cwnd +sctp-cwnd-init+)                     ; congestion window (bytes)
  (ssthresh #x7fffffff)                      ; slow-start threshold (bytes)
  (peer-rwnd 0)                              ; peer's advertised receive window (from INIT/SACK)
  peer-cum-ack                               ; highest TSN the peer has cumulatively acked
  (rto +sctp-rto-init+)                      ; current retransmission timeout (s)
  (rto-strikes 0)                            ; consecutive RTO fires with no forward progress
  (srtt nil) (rttvar nil)                    ; smoothed RTT + variance (s), Jacobson/RFC 6298
  ;; --- receive side (peer -> us) ---
  (rcv-buffer (make-hash-table))             ; tsn -> (list stream-id ppid user), out-of-order
  (dup-tsns nil)                             ; duplicate TSNs to report in the next SACK
  ;; --- stats (cumulative counters, for performance monitoring) ---
  (n-bytes-out 0) (n-bytes-in 0)             ; DATA payload bytes sent / received
  (n-data-out 0) (n-data-in 0)               ; DATA chunks sent (incl. retransmits) / received
  (n-rtx 0) (n-fast-rtx 0) (n-rto 0)         ; chunks retransmitted, fast-retransmits, RTO events
  (n-sack-in 0) (n-drop 0)                   ; SACKs processed, packets dropped by *sctp-drop-rate*
  ;; --- glue ---
  on-message                                 ; (funcall on-message assoc stream-id payload)
  on-ready                                   ; (funcall on-ready assoc stream-id) at DCEP OPEN
  (send-lock (bt:make-recursive-lock))       ; serialize send-side state + DTLS record layer
  (log nil))                                 ; optional stream for debug logging

(defun sctp-log (assoc fmt &rest args)
  (when (sctp-assoc-log assoc)
    (apply #'format (sctp-assoc-log assoc) fmt args)
    (finish-output (sctp-assoc-log assoc))))

(defun sctp-now () (get-internal-real-time))
(defun sctp-secs-since (t0)
  (/ (float (- (sctp-now) t0) 1d0) internal-time-units-per-second))

(defun sctp-transmit (assoc &rest chunk-byte-vectors)
  "Wrap CHUNK-BYTE-VECTORS in a packet carrying the peer's verification tag and send it
over DTLS.  Locked: the DTLS record layer (sequence numbers) is not thread-safe, and the
glass framebuffer pump sends concurrently with the SCTP receive loop.  Honours
*SCTP-DROP-RATE* by silently dropping the packet (test aid — simulates outbound loss)."
  (bt:with-recursive-lock-held ((sctp-assoc-send-lock assoc))
    (let ((pkt (apply #'sctp-packet (or (sctp-assoc-peer-tag assoc) 0)
                      chunk-byte-vectors)))
      (if (and (plusp *sctp-drop-rate*) (< (random 1.0) *sctp-drop-rate*))
          (incf (sctp-assoc-n-drop assoc))
          (seal:dtls-send-app (sctp-assoc-session assoc) pkt)))))

;;; ---- outbound: send queue, flow control, retransmission --------------------

(defun sctp-next-stream-seq (assoc stream-id)
  (let ((v (gethash stream-id (sctp-assoc-stream-seq assoc) 0)))
    (setf (gethash stream-id (sctp-assoc-stream-seq assoc)) (logand (1+ v) #xffff))
    v))

(defun sctp-enqueue (assoc txc)
  "Append TXC to the ready send queue (FIFO).  Caller holds the send-lock."
  (let ((cell (cons txc nil)))
    (if (sctp-assoc-send-q-tail assoc)
        (setf (cdr (sctp-assoc-send-q-tail assoc)) cell)
        (setf (sctp-assoc-send-q assoc) cell))
    (setf (sctp-assoc-send-q-tail assoc) cell)
    (incf (sctp-assoc-send-q-len assoc))))

(defun sctp-dequeue (assoc)
  "Pop the head txc off the ready send queue.  Caller holds the send-lock."
  (let ((txc (pop (sctp-assoc-send-q assoc))))
    (when txc
      (decf (sctp-assoc-send-q-len assoc))
      (unless (sctp-assoc-send-q assoc) (setf (sctp-assoc-send-q-tail assoc) nil)))
    txc))

(defun sctp-build-data-txc (assoc stream-id ppid data)
  "Assign the next TSN and build a DATA chunk for DATA on STREAM-ID.  Caller holds the
send-lock so TSNs and stream sequence numbers stay monotonic."
  (let* ((data (as-u8vec data))
         (tsn (sctp-assoc-local-tsn assoc))
         (seq (sctp-next-stream-seq assoc stream-id))
         (value (cat-bytes (u32be tsn) (u16be stream-id) (u16be seq)
                           (u32be ppid) data)))
    (setf (sctp-assoc-local-tsn assoc) (u32 (1+ tsn)))
    (make-txc :tsn tsn :size (length data)
              :bytes (sctp-chunk +chunk-data+ +data-flag-be+ value))))

(defun sctp-window (assoc)
  "Bytes we may have outstanding right now: min(cwnd, peer-rwnd)."
  (min (sctp-assoc-cwnd assoc) (sctp-assoc-peer-rwnd assoc)))

(defun sctp-flush (assoc)
  "Transmit as many queued DATA chunks as the congestion/flow window allows, moving them
to OUTSTANDING.  Caller holds the send-lock.  Always lets at least one chunk out when
nothing is in flight (zero-window / cold-start probe) so the stream can't wedge."
  (loop for txc = (car (sctp-assoc-send-q assoc))
        while txc
        do (let ((size (txc-size txc)))
             (unless (or (<= (+ (sctp-assoc-flight assoc) size) (sctp-window assoc))
                         (zerop (sctp-assoc-flight assoc)))
               (return))
             (sctp-dequeue assoc)
             (setf (txc-sent txc) (sctp-now))
             (setf (gethash (txc-tsn txc) (sctp-assoc-outstanding assoc)) txc)
             (incf (sctp-assoc-flight assoc) size)
             (incf (sctp-assoc-n-data-out assoc))
             (incf (sctp-assoc-n-bytes-out assoc) size)
             (sctp-transmit assoc (txc-bytes txc)))))

(defun sctp-send-data (assoc stream-id ppid data)
  "Enqueue one unfragmented, ordered DATA chunk on STREAM-ID and try to flush.  If the
ready queue is full this blocks (OUTSIDE the send-lock, so the receive loop can still
process the SACKs that drain it) — this is the backpressure that throttles a fast
producer (e.g. the glass pump) down to what the peer can absorb."
  (loop
    (let ((room nil))
      (bt:with-recursive-lock-held ((sctp-assoc-send-lock assoc))
        (when (< (sctp-assoc-send-q-len assoc) +sctp-send-q-max+)
          (setf room t)
          (sctp-enqueue assoc (sctp-build-data-txc assoc stream-id ppid data))
          (sctp-flush assoc)))
      (when room (return))
      (sleep 0.002))))                        ; queue full: wait for a SACK to drain it

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

(defun sctp-oldest-outstanding (assoc)
  "The in-flight txc with the lowest (earliest) TSN, or NIL.  Caller holds the lock."
  (let ((best nil))
    (maphash (lambda (tsn txc)
               (when (or (null best) (tsn< tsn (txc-tsn best)))
                 (setf best txc)))
             (sctp-assoc-outstanding assoc))
    best))

(defun sctp-tick (assoc)
  "Called frequently from the driver loop: fire the retransmission timer.  On an RTO
expiry, collapse the congestion window (RFC 4960 §7.2.3), back the RTO off, and
retransmit every outstanding chunk (oldest first)."
  (bt:with-recursive-lock-held ((sctp-assoc-send-lock assoc))
    (let ((oldest (sctp-oldest-outstanding assoc)))
      (when (and oldest (> (sctp-secs-since (txc-sent oldest)) (sctp-assoc-rto assoc)))
        (setf (sctp-assoc-ssthresh assoc)
              (max (floor (sctp-assoc-flight assoc) 2) (* 4 +sctp-mtu+)))
        (setf (sctp-assoc-cwnd assoc) +sctp-mtu+)
        (setf (sctp-assoc-rto assoc) (min +sctp-rto-max+ (* 2 (sctp-assoc-rto assoc))))
        (when (>= (incf (sctp-assoc-rto-strikes assoc)) +sctp-max-rto-strikes+)
          (sctp-log assoc "~&  !! peer unreachable (~a RTO strikes) -> abort~%"
                    (sctp-assoc-rto-strikes assoc))
          (setf (sctp-assoc-state assoc) :aborted)
          (return-from sctp-tick))
        (let ((chunks (sort (loop for txc being the hash-values of (sctp-assoc-outstanding assoc)
                                  collect txc)
                            (lambda (a b) (tsn< (txc-tsn a) (txc-tsn b))))))
          (sctp-log assoc "~&  !! RTO fire: retransmit ~a chunk(s) rto=~,2f cwnd=~a~%"
                    (length chunks) (sctp-assoc-rto assoc) (sctp-assoc-cwnd assoc))
          (incf (sctp-assoc-n-rto assoc))
          (incf (sctp-assoc-n-rtx assoc) (length chunks))
          (dolist (txc chunks)
            (setf (txc-sent txc) (sctp-now) (txc-missing txc) 0 (txc-retx txc) t)
            (sctp-transmit assoc (txc-bytes txc))))))))

(defun sctp-update-rtt (assoc r)
  "Feed one RTT sample R (seconds) into the SRTT/RTTVAR estimator and recompute the RTO
(RFC 6298 / RFC 4960 §6.3.1): the first sample seeds SRTT=R, RTTVAR=R/2; later samples are
exponentially smoothed (α=1/8, β=1/4) and RTO = SRTT + 4·RTTVAR, clamped to [rto-min, rto-max]."
  (if (null (sctp-assoc-srtt assoc))
      (setf (sctp-assoc-srtt assoc) r
            (sctp-assoc-rttvar assoc) (/ r 2))
      (let ((srtt (sctp-assoc-srtt assoc)) (rttvar (sctp-assoc-rttvar assoc)))
        (setf (sctp-assoc-rttvar assoc) (+ (* 0.75d0 rttvar) (* 0.25d0 (abs (- srtt r))))
              (sctp-assoc-srtt assoc)   (+ (* 0.875d0 srtt) (* 0.125d0 r)))))
  (setf (sctp-assoc-rto assoc)
        (min +sctp-rto-max+ (max +sctp-rto-min+
                                 (+ (sctp-assoc-srtt assoc) (* 4 (sctp-assoc-rttvar assoc)))))))

(defun sctp-handle-sack (assoc value)
  "Process an inbound SACK: drop cumulatively- and gap-acked chunks from OUTSTANDING,
update the peer's advertised window, grow the congestion window, fast-retransmit any
chunk reported missing >=3 times, then flush whatever the window now allows."
  (when (< (length value) 12) (return-from sctp-handle-sack))
  (bt:with-recursive-lock-held ((sctp-assoc-send-lock assoc))
    (incf (sctp-assoc-n-sack-in assoc))
    (let* ((cum      (rd-u32be value 0))
           (new-rwnd (rd-u32be value 4))
           (ngap     (rd-u16be value 8))
           (out      (sctp-assoc-outstanding assoc))
           (acked    0)
           (highest-gap nil))
      ;; 1. cumulative ack: drop everything at or below CUM; sample RTT off one chunk that
      ;;    was never retransmitted (Karn's algorithm) to drive the RTO estimator.
      (let ((drop '()) (rtt nil))
        (maphash (lambda (tsn txc)
                   (when (tsn<= tsn cum)
                     (push tsn drop) (incf acked (txc-size txc))
                     (when (and (null rtt) (not (txc-retx txc)))
                       (setf rtt (sctp-secs-since (txc-sent txc))))))
                 out)
        (dolist (tsn drop)
          (decf (sctp-assoc-flight assoc) (txc-size (gethash tsn out)))
          (remhash tsn out))
        (when rtt (sctp-update-rtt assoc rtt)))
      ;; 2. gap-ack blocks: [cum+start, cum+end] were received out of order.
      (let ((gap-acked (make-hash-table)))
        (dotimes (i ngap)
          (let* ((o (+ 12 (* 4 i))))
            (when (<= (+ o 4) (length value))
              (let ((start (rd-u16be value o))
                    (end   (rd-u16be value (+ o 2))))
                (loop for rel from start to end
                      for tsn = (u32 (+ cum rel))
                      do (setf (gethash tsn gap-acked) t)
                         (when (or (null highest-gap) (tsn< highest-gap tsn))
                           (setf highest-gap tsn))
                         (let ((txc (gethash tsn out)))
                           (when txc
                             (incf acked (txc-size txc))
                             (decf (sctp-assoc-flight assoc) (txc-size txc))
                             (remhash tsn out))))))))
        ;; 3. fast retransmit: chunks below the highest gap-acked TSN that are still
        ;;    missing get a missing-indication; after the threshold, retransmit them.
        (when highest-gap
          (let ((fast '()))
            (maphash (lambda (tsn txc)
                       (when (and (tsn< tsn highest-gap) (not (gethash tsn gap-acked)))
                         (incf (txc-missing txc))
                         (when (= (txc-missing txc) +sctp-fast-rtx-threshold+)
                           (push txc fast))))
                     out)
            (when fast
              (setf (sctp-assoc-ssthresh assoc)
                    (max (floor (sctp-assoc-flight assoc) 2) (* 4 +sctp-mtu+)))
              (setf (sctp-assoc-cwnd assoc) (sctp-assoc-ssthresh assoc))
              (sctp-log assoc "~&  !! fast-retransmit ~a chunk(s)~%" (length fast))
              (incf (sctp-assoc-n-fast-rtx assoc) (length fast))
              (incf (sctp-assoc-n-rtx assoc) (length fast))
              (dolist (txc (sort fast (lambda (a b) (tsn< (txc-tsn a) (txc-tsn b)))))
                (setf (txc-sent txc) (sctp-now) (txc-missing txc) 0 (txc-retx txc) t)
                (sctp-transmit assoc (txc-bytes txc)))))))
      ;; 4. window + congestion-control bookkeeping.
      (setf (sctp-assoc-peer-rwnd assoc) new-rwnd)
      (when (and (sctp-assoc-peer-cum-ack assoc)
                 (tsn< (sctp-assoc-peer-cum-ack assoc) cum))
        (setf (sctp-assoc-rto-strikes assoc) 0))   ; forward progress: clear unreachable counter
                                                    ; (RTO itself is now driven by SCTP-UPDATE-RTT)
      (setf (sctp-assoc-peer-cum-ack assoc) cum)
      (when (plusp acked)
        (if (<= (sctp-assoc-cwnd assoc) (sctp-assoc-ssthresh assoc))
            (incf (sctp-assoc-cwnd assoc) (min acked +sctp-mtu+))          ; slow start
            (incf (sctp-assoc-cwnd assoc)                                   ; cong. avoidance
                  (max 1 (floor (* +sctp-mtu+ +sctp-mtu+) (sctp-assoc-cwnd assoc))))))
      ;; 5. the window may have opened — send more.
      (sctp-flush assoc))))

(defun sctp-send-sack (assoc)
  "Send a SACK: cumulative ack, our advertised window, gap-ack blocks derived from the
out-of-order receive buffer, and any duplicate TSNs seen since the last SACK."
  (let* ((cum (sctp-assoc-last-received-tsn assoc))
         ;; offsets (relative to cum) of every buffered out-of-order TSN, ascending
         (offs (sort (loop for tsn being the hash-keys of (sctp-assoc-rcv-buffer assoc)
                           collect (u32 (- tsn cum)))
                     #'<))
         (blocks '()))
    (when offs                                ; coalesce contiguous offsets into runs
      (let ((start (first offs)) (prev (first offs)))
        (dolist (o (rest offs))
          (if (= o (1+ prev))
              (setf prev o)
              (progn (push (cons start prev) blocks) (setf start o prev o))))
        (push (cons start prev) blocks))
      (setf blocks (nreverse blocks)))
    (let* ((dups (sctp-assoc-dup-tsns assoc))
           (value (apply #'cat-bytes
                         (u32be cum) (u32be (sctp-assoc-a-rwnd assoc))
                         (u16be (length blocks)) (u16be (length dups))
                         (nconc (loop for (s . e) in blocks
                                      collect (cat-bytes (u16be s) (u16be e)))
                                (loop for d in dups collect (u32be d))))))
      (setf (sctp-assoc-dup-tsns assoc) nil)
      (sctp-transmit assoc (sctp-chunk +chunk-sack+ 0 value))
      (sctp-log assoc "~&  >> SACK cum=~a gaps=~a dups=~a~%"
                cum (length blocks) (length dups)))))

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
  (setf (sctp-assoc-peer-tag assoc)  (rd-u32be value 0)
        (sctp-assoc-peer-rwnd assoc) (rd-u32be value 4))   ; initial flow-control window
  (let ((peer-initial-tsn (rd-u32be value 12)))
    (setf (sctp-assoc-last-received-tsn assoc) (u32 (1- peer-initial-tsn))))
  (setf (sctp-assoc-peer-cum-ack assoc) (u32 (1- (sctp-assoc-local-tsn assoc))))
  (sctp-log assoc "~&  << INIT peer-tag=~a a_rwnd=~a initial-tsn=~a~%"
            (sctp-assoc-peer-tag assoc) (sctp-assoc-peer-rwnd assoc) (rd-u32be value 12))
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

(defun sctp-deliver (assoc stream-id ppid user)
  "Hand one fully-ordered message up to the application (or the DCEP handler)."
  (cond
    ((= ppid +ppid-dcep+) (sctp-handle-dcep assoc stream-id user))
    ((or (= ppid +ppid-string+) (= ppid +ppid-string-empty+))
     (when (sctp-assoc-on-message assoc)
       (funcall (sctp-assoc-on-message assoc) assoc stream-id (bytes->ascii user))))
    ((or (= ppid +ppid-binary+) (= ppid +ppid-binary-empty+))
     (when (sctp-assoc-on-message assoc)
       (funcall (sctp-assoc-on-message assoc) assoc stream-id user)))))

(defun sctp-handle-data (assoc value)
  "VALUE is the DATA chunk value: TSN(4) stream_id(2) stream_seq(2) PPID(4) user_data.
Delivers in order: a TSN one past the cumulative is delivered immediately (then any
now-contiguous buffered TSNs drain); a future TSN is buffered; a past TSN is a duplicate."
  (let* ((tsn (rd-u32be value 0))
         (stream-id (rd-u16be value 4))
         (ppid (rd-u32be value 8))
         (user (subseq value 12))
         (cum (sctp-assoc-last-received-tsn assoc)))
    (incf (sctp-assoc-n-data-in assoc))
    (incf (sctp-assoc-n-bytes-in assoc) (length user))
    (cond
      ;; duplicate / already delivered — ack again, report as a duplicate, don't redeliver
      ((tsn<= tsn cum)
       (when (< (length (sctp-assoc-dup-tsns assoc)) +sctp-dup-report-max+)
         (push tsn (sctp-assoc-dup-tsns assoc)))
       (sctp-log assoc "~&  << DATA dup tsn=~a (cum=~a)~%" tsn cum))
      ;; the next expected TSN: deliver, advance, then drain contiguous buffered TSNs
      ((= tsn (u32 (1+ cum)))
       (sctp-deliver assoc stream-id ppid user)
       (setf cum tsn)
       (loop for next = (u32 (1+ cum))
             for buffered = (gethash next (sctp-assoc-rcv-buffer assoc))
             while buffered
             do (destructuring-bind (bsid bppid buser) buffered
                  (sctp-deliver assoc bsid bppid buser))
                (remhash next (sctp-assoc-rcv-buffer assoc))
                (setf cum next))
       (setf (sctp-assoc-last-received-tsn assoc) cum))
      ;; a future TSN (gap): buffer it for later in-order delivery
      (t
       (unless (gethash tsn (sctp-assoc-rcv-buffer assoc))
         (setf (gethash tsn (sctp-assoc-rcv-buffer assoc)) (list stream-id ppid user)))
       (sctp-log assoc "~&  << DATA gap tsn=~a (cum=~a) buffered~%" tsn cum)))))

(defun sctp-input (assoc packet)
  "Process one inbound SCTP packet (already decrypted out of DTLS).  Iterates its chunks,
handling INIT / COOKIE-ECHO / DATA / SACK / HEARTBEAT, and sends a SACK if DATA arrived."
  (when (< (length packet) 12) (return-from sctp-input))
  (let ((pos 12) (len (length packet)) (data-seen nil))
    (loop while (<= (+ pos 4) len) do
      (let* ((ctype (aref packet pos))
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
            ((= ctype +chunk-sack+)        (sctp-handle-sack assoc value))
            ((= ctype +chunk-heartbeat+)
             ;; echo the params back as a HEARTBEAT-ACK
             (sctp-transmit assoc (sctp-chunk +chunk-heartbeat-ack+ 0 value)))
            ((= ctype +chunk-cookie-ack+))
            ((= ctype +chunk-abort+)
             (sctp-log assoc "~&  << ABORT~%") (setf (sctp-assoc-state assoc) :aborted))
            ((= ctype +chunk-shutdown+)
             (sctp-log assoc "~&  << SHUTDOWN~%"))
            (t (sctp-log assoc "~&  << unhandled chunk type ~a~%" ctype))))
        ;; advance past chunk + padding
        (incf pos (+ clen (mod (- (mod clen 4)) 4)))))
    (when data-seen (sctp-send-sack assoc))))

;;; ---- performance monitoring ------------------------------------------------

(defun sctp-stats (assoc)
  "A snapshot plist of transport counters + live window state.  Cumulative counters (:bytes-*,
:data-*, :rtx, :drops, ...) let a caller compute rates by differencing over time; the window
fields (:cwnd, :peer-rwnd, :flight, :outstanding, :send-q, :rto) are instantaneous health."
  (list :state       (sctp-assoc-state assoc)
        :bytes-out   (sctp-assoc-n-bytes-out assoc) :bytes-in (sctp-assoc-n-bytes-in assoc)
        :data-out    (sctp-assoc-n-data-out assoc)  :data-in  (sctp-assoc-n-data-in assoc)
        :rtx         (sctp-assoc-n-rtx assoc)       :fast-rtx (sctp-assoc-n-fast-rtx assoc)
        :rto-events  (sctp-assoc-n-rto assoc)       :sacks-in (sctp-assoc-n-sack-in assoc)
        :drops       (sctp-assoc-n-drop assoc)
        :cwnd        (sctp-assoc-cwnd assoc)        :peer-rwnd (sctp-assoc-peer-rwnd assoc)
        :flight      (sctp-assoc-flight assoc)      :rto      (sctp-assoc-rto assoc)
        :srtt-ms     (let ((s (sctp-assoc-srtt assoc))) (and s (* 1000d0 s)))  ; smoothed RTT
        :outstanding (hash-table-count (sctp-assoc-outstanding assoc))
        :send-q      (sctp-assoc-send-q-len assoc)))

;;; ---- driver: run the association over a DTLS-CONN --------------------------

(defun webrtc-serve-datachannel (conn &key on-message on-ready (duration 30.0) log)
  "Run the SCTP association + DCEP over the (already handshaked) DTLS-CONN for up to DURATION
seconds (or until the peer ABORTs), pumping inbound datagrams from the mailbox.  ON-MESSAGE,
if given, is called as (funcall on-message ASSOC STREAM-ID PAYLOAD) for each inbound message
— a string for PPID 51, raw bytes for PPID 53.  ON-READY, if given, is called as
(funcall on-ready ASSOC STREAM-ID) once the channel opens (DCEP OPEN) — the moment a bridge
should start pushing bytes (e.g. glass, whose RFB server speaks first).  Returns the
SCTP-ASSOC.  Higher layers push with SCTP-SEND-DATA / SCTP-SEND-STRING and pull via ON-MESSAGE.

The loop wakes ~20x/s: a short mailbox timeout lets SCTP-TICK run the retransmission timer
even when no datagrams are arriving."
  (let* ((session (dtls-conn-session conn))
         (mb (dtls-conn-mailbox conn))
         (assoc (make-sctp-assoc :session session :on-message on-message :on-ready on-ready :log log))
         (deadline (+ (get-internal-real-time)
                      (round (* duration internal-time-units-per-second)))))
    (loop while (and (< (get-internal-real-time) deadline)
                     (not (eq (sctp-assoc-state assoc) :aborted)))
          do (let ((dg (mailbox-pop mb 0.05)))
               (when dg
                 (dolist (sctp (seal:dtls-handle-datagram session dg))
                   (handler-case (sctp-input assoc sctp)
                     (error (e) (sctp-log assoc "~&  !! sctp-input error: ~a~%" e)))))
               (handler-case (sctp-tick assoc)
                 (error (e) (sctp-log assoc "~&  !! sctp-tick error: ~a~%" e)))))
    assoc))
