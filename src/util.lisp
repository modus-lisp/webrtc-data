;;;; src/util.lisp — byte helpers shared across the stack.

(in-package #:cl-webrtc)

(deftype u8 () '(unsigned-byte 8))
(deftype u8vec () '(simple-array (unsigned-byte 8) (*)))
(defun u8vec (n &optional (init 0)) (make-array n :element-type 'u8 :initial-element init))
(defun as-u8vec (seq) (coerce seq 'u8vec))
(defun cat-bytes (&rest seqs) (apply #'concatenate 'u8vec seqs))
(defun ascii (s) (map 'u8vec #'char-code s))
(defun bytes->ascii (v) (map 'string #'code-char v))

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
