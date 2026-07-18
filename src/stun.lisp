;;;; src/stun.lisp — STUN (RFC 5389) messages, as used by ICE connectivity checks.
;;;;
;;;; A STUN message is a 20-byte header (type, length, magic cookie 0x2112A442, 96-bit
;;;; transaction id) followed by 4-byte-aligned TLV attributes.  ICE uses short-term
;;;; credentials: each Binding Request/Response carries a MESSAGE-INTEGRITY (HMAC-SHA1 keyed
;;;; by the peer's ICE password, over the message with its length pre-adjusted to include the
;;;; attribute) and a FINGERPRINT (CRC-32 xor 0x5354554e).

(in-package #:webrtc-data)

(defconstant +stun-magic+ #x2112A442)
(defparameter +binding-request+ #x0001)
(defparameter +binding-success+ #x0101)
;; attributes
(defparameter +attr-username+ #x0006)
(defparameter +attr-message-integrity+ #x0008)
(defparameter +attr-xor-mapped-address+ #x0020)
(defparameter +attr-priority+ #x0024)
(defparameter +attr-use-candidate+ #x0025)
(defparameter +attr-fingerprint+ #x8028)
(defparameter +attr-ice-controlled+ #x8029)
(defparameter +attr-ice-controlling+ #x802A)

(defun stun-transaction-id () (random-bytes 12))

(defun %pad4 (n) (logand (- 4 (logand n 3)) 3))

(defun %encode-attrs (attrs)
  "ATTRS: list of (type . value-u8vec).  -> concatenated, each TLV 4-byte padded."
  (let ((out (make-array 0 :element-type 'u8 :adjustable t :fill-pointer 0)))
    (dolist (a attrs (as-u8vec out))
      (let* ((type (car a)) (val (as-u8vec (cdr a))) (len (length val)))
        (loop for b across (u16be type) do (vector-push-extend b out))
        (loop for b across (u16be len) do (vector-push-extend b out))
        (loop for b across val do (vector-push-extend b out))
        (dotimes (i (%pad4 len)) (vector-push-extend 0 out))))))

(defun %hdr (type len tid) (cat-bytes (u16be type) (u16be len) (u32be +stun-magic+) tid))

(defun crc32 (bytes) (rd-u32be (ic:digest-sequence :crc32 (as-u8vec bytes)) 0))
(defun hmac-sha1 (key bytes)
  ;; ICE short-term credentials key the HMAC by the peer's ICE password (as bytes).
  (let ((m (ic:make-mac :hmac (if (stringp key) (ascii key) (as-u8vec key)) :sha1)))
    (ic:update-mac m (as-u8vec bytes)) (ic:produce-mac m)))

(defun encode-stun (type tid attrs &key integrity-key fingerprint)
  "Build a STUN message.  Appends MESSAGE-INTEGRITY (keyed by INTEGRITY-KEY) then FINGERPRINT,
   each with the header length pre-adjusted per RFC 5389 so the peer's checks match."
  (let* ((body (%encode-attrs attrs)) (blen (length body)))
    ;; MESSAGE-INTEGRITY: length must count this attribute (4+20=24)
    (when integrity-key
      (let* ((pre (cat-bytes (%hdr type (+ blen 24) tid) body))
             (mi (hmac-sha1 integrity-key pre)))
        (setf body (cat-bytes body (%encode-attrs (list (cons +attr-message-integrity+ mi))))
              blen (length body))))
    ;; FINGERPRINT: length must count this attribute (4+4=8)
    (when fingerprint
      (let* ((pre (cat-bytes (%hdr type (+ blen 8) tid) body))
             (fp (logxor (crc32 pre) #x5354554e)))
        (setf body (cat-bytes body (%encode-attrs (list (cons +attr-fingerprint+ (u32be fp)))))
              blen (length body))))
    (cat-bytes (%hdr type blen tid) body)))

(defun decode-stun (bytes)
  "-> (values type transaction-id attrs-alist) or NIL if not a STUN message."
  (when (and (>= (length bytes) 20) (= (rd-u32be bytes 4) +stun-magic+))
    (let ((type (rd-u16be bytes 0)) (len (rd-u16be bytes 2))
          (tid (subseq bytes 8 20)) (attrs '()) (pos 20) (end (+ 20 (rd-u16be bytes 2))))
      (declare (ignore len))
      (loop while (<= (+ pos 4) end) do
        (let* ((atype (rd-u16be bytes pos)) (alen (rd-u16be bytes (+ pos 2)))
               (val (subseq bytes (+ pos 4) (+ pos 4 alen))))
          (push (cons atype val) attrs)
          (setf pos (+ pos 4 alen (%pad4 alen)))))
      (values type tid (nreverse attrs)))))

(defun xor-mapped-address (ip-octets port)
  "Encode an XOR-MAPPED-ADDRESS value for an IPv4 IP-OCTETS:PORT."
  (let ((xport (logxor port (ash +stun-magic+ -16)))
        (xaddr (logxor (rd-u32be (as-u8vec ip-octets) 0) +stun-magic+)))
    (cat-bytes (as-u8vec (list 0 1)) (u16be xport) (u32be xaddr))))   ; reserved, family=IPv4

(defun stun-attr (attrs type) (cdr (assoc type attrs)))

(defun stun-username-key (val) (bytes->ascii val))   ; ICE USERNAME = "rfrag:lfrag"
