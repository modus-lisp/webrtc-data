;;;; src/util.lisp — byte helpers shared across the stack.

(in-package #:webrtc-data)

(deftype u8 () '(unsigned-byte 8))
(deftype u8vec () '(simple-array (unsigned-byte 8) (*)))
(defun u8vec (n &optional (init 0)) (make-array n :element-type 'u8 :initial-element init))
(defun as-u8vec (seq) (coerce seq 'u8vec))
(defun cat-bytes (&rest seqs) (apply #'concatenate 'u8vec seqs))
(defun ascii (s) (map 'u8vec #'char-code s))
(defun bytes->ascii (v) (map 'string #'code-char v))

;; UTF-8, for WebRTC STRING messages (PPID 51), which are UTF-8 by spec — ASCII maps
;; identically, so `ascii` was fine until the first byte > 127 (an em-dash in a chat
;; reply, char 8212) tried to become an (unsigned-byte 8) and blew up the send.
(defun utf8 (s)
  "STRING S as a UTF-8 u8vec."
  (let ((out (make-array (length s) :element-type 'u8 :adjustable t :fill-pointer 0)))
    (loop for ch across s for c = (char-code ch) do
      (cond ((< c #x80) (vector-push-extend c out))
            ((< c #x800)
             (vector-push-extend (logior #xC0 (ash c -6)) out)
             (vector-push-extend (logior #x80 (logand c #x3F)) out))
            ((< c #x10000)
             (vector-push-extend (logior #xE0 (ash c -12)) out)
             (vector-push-extend (logior #x80 (logand (ash c -6) #x3F)) out)
             (vector-push-extend (logior #x80 (logand c #x3F)) out))
            (t
             (vector-push-extend (logior #xF0 (ash c -18)) out)
             (vector-push-extend (logior #x80 (logand (ash c -12) #x3F)) out)
             (vector-push-extend (logior #x80 (logand (ash c -6) #x3F)) out)
             (vector-push-extend (logior #x80 (logand c #x3F)) out))))
    (as-u8vec out)))

(defun utf8->string (v)
  "Decode a UTF-8 u8vec V to a string (lenient: a bad byte passes through as latin-1)."
  (let ((out (make-array (length v) :element-type 'character :adjustable t :fill-pointer 0))
        (i 0) (n (length v)))
    (flet ((cont (k) (if (and (< k n) (= (logand (aref v k) #xC0) #x80))
                         (logand (aref v k) #x3F) nil)))
      (loop while (< i n) do
        (let ((b (aref v i)))
          (cond
            ((< b #x80) (vector-push-extend (code-char b) out) (incf i))
            ((= (logand b #xE0) #xC0)
             (let ((c1 (cont (1+ i))))
               (if c1 (progn (vector-push-extend (code-char (logior (ash (logand b #x1F) 6) c1)) out) (incf i 2))
                   (progn (vector-push-extend (code-char b) out) (incf i)))))
            ((= (logand b #xF0) #xE0)
             (let ((c1 (cont (1+ i))) (c2 (cont (+ i 2))))
               (if (and c1 c2) (progn (vector-push-extend (code-char (logior (ash (logand b #x0F) 12) (ash c1 6) c2)) out) (incf i 3))
                   (progn (vector-push-extend (code-char b) out) (incf i)))))
            ((= (logand b #xF8) #xF0)
             (let ((c1 (cont (1+ i))) (c2 (cont (+ i 2))) (c3 (cont (+ i 3))))
               (if (and c1 c2 c3) (progn (vector-push-extend (code-char (logior (ash (logand b #x07) 18) (ash c1 12) (ash c2 6) c3)) out) (incf i 4))
                   (progn (vector-push-extend (code-char b) out) (incf i)))))
            (t (vector-push-extend (code-char b) out) (incf i))))))
    (coerce out 'string)))

(declaim (inline u8! ))
(defun u8! (n) (logand n #xff))

;;; big-endian integer read/write
(defun u16be (n) (as-u8vec (list (u8! (ash n -8)) (u8! n))))
(defun u32be (n) (as-u8vec (list (u8! (ash n -24)) (u8! (ash n -16)) (u8! (ash n -8)) (u8! n))))
(defun rd-u16be (v off) (logior (ash (aref v off) 8) (aref v (1+ off))))
(defun rd-u32be (v off) (logior (ash (aref v off) 24) (ash (aref v (1+ off)) 16)
                                (ash (aref v (+ off 2)) 8) (aref v (+ off 3))))

(defun hexbytes (v) (string-downcase (format nil "~{~2,'0x~}" (coerce v 'list))))
(defun colon-hex (v) (format nil "~{~2,'0X~^:~}" (coerce v 'list)))   ; AA:BB:CC (for fingerprints)

(defun random-bytes (n)
  (handler-case
      (with-open-file (f "/dev/urandom" :element-type 'u8) (let ((b (u8vec n))) (read-sequence b f) b))
    (error () (ic:random-data n (ic:make-prng :fortuna)))))

(defparameter +b64-alphabet+ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
(defun b64-encode (bytes)
  (with-output-to-string (out)
    (loop for i from 0 below (length bytes) by 3
          for b0 = (aref bytes i)
          for b1 = (if (< (+ i 1) (length bytes)) (aref bytes (+ i 1)) 0)
          for b2 = (if (< (+ i 2) (length bytes)) (aref bytes (+ i 2)) 0)
          for n = (logior (ash b0 16) (ash b1 8) b2)
          do (write-char (char +b64-alphabet+ (ldb (byte 6 18) n)) out)
             (write-char (char +b64-alphabet+ (ldb (byte 6 12) n)) out)
             (write-char (if (< (+ i 1) (length bytes)) (char +b64-alphabet+ (ldb (byte 6 6) n)) #\=) out)
             (write-char (if (< (+ i 2) (length bytes)) (char +b64-alphabet+ (ldb (byte 6 0) n)) #\=) out))))
