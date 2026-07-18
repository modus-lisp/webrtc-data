;;;; src/dtls.lisp — the DTLS 1.2 client, wired to our ICE agent.
;;;;
;;;; The DTLS protocol itself lives in `seal` (seal/src/dtls.lisp): it reuses
;;;; seal's TLS 1.2 PRF, key schedule and AES-128-GCM record protection, and adds
;;;; the datagram framing, cookie exchange and flight retransmission.  seal is a
;;;; pure verifier — it has no private-key operations — so this file supplies the
;;;; one thing a WebRTC peer needs that a normal TLS client does not: a
;;;; self-signed certificate plus a signing closure for the client
;;;; CertificateVerify (WebRTC does mutual auth, trust rooted in the SDP
;;;; fingerprint).  We generate an RSA-2048 key with ironclad, hand-roll the
;;;; X.509 DER, and offer TLS_ECDHE_{ECDSA,RSA}_WITH_AES_128_GCM_SHA256 (aiortc
;;;; picks ECDSA to match its own certificate; the ECDHE runs over X25519).
;;;;
;;;; The glue turns the ICE agent into a datagram transport: non-STUN packets
;;;; arriving on the ICE socket are pumped into a mailbox, and seal's handshake
;;;; reads that mailbox and writes back through ICE-SEND.

(in-package #:cl-webrtc)

;;; ---- integer <-> octet-string + modular arithmetic -------------------------

(defun os2ip (v) (let ((n 0)) (loop for b across v do (setf n (logior (ash n 8) b))) n))
(defun i2osp (n len)
  (let ((v (u8vec len)))
    (loop for i from (1- len) downto 0 do (setf (aref v i) (logand n #xff) n (ash n -8)))
    v))
(defun mod-expt (b e m)
  (let ((r 1) (b (mod b m)))
    (loop while (plusp e) do
      (when (oddp e) (setf r (mod (* r b) m)))
      (setf e (ash e -1) b (mod (* b b) m)))
    r))
(defun %egcd (a b)
  (if (zerop b) (values a 1 0)
      (multiple-value-bind (g x y) (%egcd b (mod a b))
        (values g y (- x (* (floor a b) y))))))
(defun mod-inverse (a m)
  (multiple-value-bind (g x) (%egcd (mod a m) m)
    (declare (ignore g)) (mod x m)))

;;; ---- RSA-2048 key generation (e = 65537) -----------------------------------

(defun generate-rsa-key (&optional (bits 2048))
  "Return (values n e d) for a fresh RSA key with public exponent 65537."
  (let ((e 65537))
    (loop
      (let* ((p (ic:generate-prime (floor bits 2)))
             (q (ic:generate-prime (- bits (floor bits 2))))
             (phi (* (1- p) (1- q))))
        (when (and (/= p q) (= 1 (gcd e phi)))
          (return (values (* p q) e (mod-inverse e phi))))))))

;;; ---- RSASSA-PKCS1-v1_5 signing (rsa_pkcs1_sha256) --------------------------

(defparameter +sha256-digestinfo+
  (as-u8vec '(#x30 #x31 #x30 #x0d #x06 #x09 #x60 #x86 #x48 #x01 #x65 #x03
              #x04 #x02 #x01 #x05 #x00 #x04 #x20)))

(defun pkcs1-sha256-sign (n d message)
  "Sign MESSAGE (bytes) as EMSA-PKCS1-v1_5 over SHA-256 with private key (n, d)."
  (let* ((dig (seal:sha256 (as-u8vec message)))
         (tt (cat-bytes +sha256-digestinfo+ dig))
         (k (ceiling (integer-length n) 8))
         (ps (- k (length tt) 3))
         (em (u8vec k #xff)))
    (setf (aref em 0) 0 (aref em 1) 1 (aref em (+ 2 ps)) 0)
    (replace em tt :start1 (+ 3 ps))
    (i2osp (mod-expt (os2ip em) d n) k)))

;;; ---- minimal DER encoder ---------------------------------------------------

(defun der-len (n)
  (if (< n 128) (as-u8vec (list n))
      (let ((bytes '()))
        (loop while (plusp n) do (push (logand n #xff) bytes) (setf n (ash n -8)))
        (as-u8vec (cons (logior #x80 (length bytes)) bytes)))))
(defun der-tlv (tag content) (cat-bytes (as-u8vec (list tag)) (der-len (length content)) content))
(defun der-seq (&rest parts) (der-tlv #x30 (apply #'cat-bytes parts)))
(defun der-set (&rest parts) (der-tlv #x31 (apply #'cat-bytes parts)))
(defun der-null () (as-u8vec '(#x05 #x00)))
(defun der-bitstring (content) (der-tlv #x03 (cat-bytes #(0) content)))
(defun der-uint (n)
  (let ((bytes '()))
    (if (zerop n) (setf bytes (list 0))
        (loop while (plusp n) do (push (logand n #xff) bytes) (setf n (ash n -8))))
    (when (>= (first bytes) 128) (push 0 bytes))       ; keep it positive
    (der-tlv #x02 (as-u8vec bytes))))
(defun der-utf8 (s) (der-tlv #x0c (ascii s)))
(defun der-utctime (s) (der-tlv #x17 (ascii s)))
(defun der-explicit0 (content) (der-tlv #xa0 content))

(defparameter +oid-cn+ (as-u8vec '(#x06 #x03 #x55 #x04 #x03)))
(defparameter +oid-rsa-encryption+
  (as-u8vec '(#x06 #x09 #x2a #x86 #x48 #x86 #xf7 #x0d #x01 #x01 #x01)))
(defparameter +oid-sha256-rsa+
  (as-u8vec '(#x06 #x09 #x2a #x86 #x48 #x86 #xf7 #x0d #x01 #x01 #x0b)))

(defun build-self-signed-cert (n e d)
  "Hand-build a self-signed RSA X.509 v3 certificate (DER)."
  (let* ((name (der-seq (der-set (der-seq +oid-cn+ (der-utf8 "cl-webrtc")))))
         (spki (der-seq (der-seq +oid-rsa-encryption+ (der-null))
                        (der-bitstring (der-seq (der-uint n) (der-uint e)))))
         (validity (der-seq (der-utctime "250101000000Z") (der-utctime "350101000000Z")))
         (sigalg (der-seq +oid-sha256-rsa+ (der-null)))
         (serial (der-uint (logior 1 (os2ip (random-bytes 8)))))
         (tbs (der-seq (der-explicit0 (der-uint 2))     ; version v3
                       serial sigalg name validity name spki))
         (sig (pkcs1-sha256-sign n d tbs)))
    (der-seq tbs sigalg (der-bitstring sig))))

(defun generate-webrtc-cert ()
  "Return (values cert-der sign-fn fingerprint) for a fresh DTLS identity."
  (multiple-value-bind (n e d) (generate-rsa-key 2048)
    (let ((der (build-self-signed-cert n e d)))
      (values der
              (lambda (message) (pkcs1-sha256-sign n d message))
              (seal:dtls-fingerprint der)))))

;;; ---- datagram mailbox (ICE recv thread -> DTLS handshake thread) -----------

(defstruct mailbox (lock (bt:make-lock)) (items '()))

(defun mailbox-push (mb item)
  (bt:with-lock-held ((mailbox-lock mb))
    (setf (mailbox-items mb) (nconc (mailbox-items mb) (list item)))))

(defun mailbox-pop (mb timeout)
  "Pop the next datagram, waiting up to TIMEOUT seconds; NIL on timeout."
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout internal-time-units-per-second)))))
    (loop
      (bt:with-lock-held ((mailbox-lock mb))
        (when (mailbox-items mb) (return-from mailbox-pop (pop (mailbox-items mb)))))
      (when (>= (get-internal-real-time) deadline) (return nil))
      (sleep 0.002))))

;;; ---- glue: DTLS over an ICE agent ------------------------------------------

(defstruct dtls-conn agent session mailbox cert-der sign-fn fingerprint)

(defun webrtc-dtls-setup (agent &key remote-fingerprint)
  "Generate a DTLS identity, install the packet pump on AGENT's ON-PACKET, and
return a DTLS-CONN.  Put its FINGERPRINT in the answer SDP.  Call before
ICE-SERVE so no early DTLS records are dropped."
  (multiple-value-bind (der sign-fn fp) (generate-webrtc-cert)
    (let* ((mb (make-mailbox))
           (session (seal:make-dtls-session
                     :send-fn (lambda (dg)
                                (let ((p (ice-agent-peer agent)))
                                  (when p (ice-send agent dg (first p) (second p)))))
                     :cert-der der :sign-fn sign-fn
                     :expected-peer-fingerprint remote-fingerprint)))
      (setf (ice-agent-on-packet agent)
            (lambda (pkt host port)
              (declare (ignore host port))
              (mailbox-push mb pkt)))
      (make-dtls-conn :agent agent :session session :mailbox mb
                      :cert-der der :sign-fn sign-fn :fingerprint fp))))

(defun webrtc-dtls-run (conn &key (timeout 1.0) (peer-wait 15.0))
  "Wait for ICE to settle on a peer, then drive the DTLS client handshake.
Returns the seal DTLS-SESSION on success (SEAL:DTLS-DONE true)."
  (let ((agent (dtls-conn-agent conn)))
    (loop with deadline = (+ (get-internal-real-time)
                             (round (* peer-wait internal-time-units-per-second)))
          until (ice-agent-peer agent)
          do (when (>= (get-internal-real-time) deadline)
               (werr "DTLS: no ICE peer within ~as" peer-wait))
             (sleep 0.05))
    (seal:dtls-client-handshake
     (dtls-conn-session conn)
     (lambda (to) (mailbox-pop (dtls-conn-mailbox conn) to))
     :timeout timeout)
    (dtls-conn-session conn)))
