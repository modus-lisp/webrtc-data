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

(in-package #:webrtc-data)

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
(defparameter +oid-ec-public-key+                       ; id-ecPublicKey 1.2.840.10045.2.1
  (as-u8vec '(#x06 #x07 #x2a #x86 #x48 #xce #x3d #x02 #x01)))
(defparameter +oid-prime256v1+                          ; secp256r1 (prime256v1) 1.2.840.10045.3.1.7
  (as-u8vec '(#x06 #x08 #x2a #x86 #x48 #xce #x3d #x03 #x01 #x07)))
(defparameter +oid-ecdsa-sha256+                        ; ecdsa-with-SHA256 1.2.840.10045.4.3.2
  (as-u8vec '(#x06 #x08 #x2a #x86 #x48 #xce #x3d #x04 #x03 #x02)))

(defun ecdsa-sha256-sign (d message)
  "Sign MESSAGE (bytes) with private scalar D as ecdsa_secp256r1_sha256, returning the
DER Ecdsa-Sig-Value  SEQUENCE { r INTEGER, s INTEGER }  (the wire form for both the
certificate self-signature and DTLS CertificateVerify)."
  (multiple-value-bind (r s) (seal:ecdsa-sign seal:*p256* d (seal:sha256 (as-u8vec message)))
    (der-seq (der-uint r) (der-uint s))))

(defun build-self-signed-ec-cert (d pub)
  "Hand-build a self-signed ECDSA P-256 X.509 v3 certificate (DER).  PUB is the affine
public point (d*G); D the private scalar.  ~330 bytes vs ~800 for RSA-2048."
  (let* ((name (der-seq (der-set (der-seq +oid-cn+ (der-utf8 "webrtc-data")))))
         (spki (der-seq (der-seq +oid-ec-public-key+ +oid-prime256v1+)   ; namedCurve as param
                        (der-bitstring (seal:ec-encode-point seal:*p256* pub))))
         (validity (der-seq (der-utctime "250101000000Z") (der-utctime "350101000000Z")))
         (sigalg (der-seq +oid-ecdsa-sha256+))          ; ecdsa-with-SHA256 has no parameters
         (serial (der-uint (logior 1 (os2ip (random-bytes 8)))))
         (tbs (der-seq (der-explicit0 (der-uint 2))     ; version v3
                       serial sigalg name validity name spki)))
    (der-seq tbs sigalg (der-bitstring (ecdsa-sha256-sign d tbs)))))

(defun generate-webrtc-cert ()
  "Return (values cert-der sign-fn fingerprint) for a fresh ECDSA P-256 DTLS identity.
The EC cert keeps our DTLS auth flight to ~one datagram so the handshake survives a lossy
link; SIGN-FN produces ecdsa_secp256r1_sha256 signatures for CertificateVerify."
  (multiple-value-bind (d pub) (seal:ec-generate-key seal:*p256*)
    (let ((der (build-self-signed-ec-cert d pub)))
      (values der
              (lambda (message) (ecdsa-sha256-sign d message))
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
                     :sig-scheme-code seal:+sig-ecdsa-secp256r1-sha256+
                     :expected-peer-fingerprint remote-fingerprint)))
      (setf (ice-agent-on-packet agent)
            (lambda (pkt host port)
              (declare (ignore host port))
              (mailbox-push mb pkt)))
      (make-dtls-conn :agent agent :session session :mailbox mb
                      :cert-der der :sign-fn sign-fn :fingerprint fp))))

(defun webrtc-dtls-run (conn &key (timeout 0.4) (peer-wait 20.0))
  "Wait for ICE to settle on a peer, then drive the DTLS client handshake.  TIMEOUT is the
INITIAL handshake retransmit timer — seal backs it off exponentially, so a low value makes a
lossy link recover fast without storming a high-RTT one.  Returns the seal DTLS-SESSION on
success (SEAL:DTLS-DONE true)."
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
