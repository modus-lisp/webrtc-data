;;;; test/receive-test.lisp — SCTP receive: per-stream delivery, fragments by TSN, FORWARD-TSN.
;;;;   sbcl --script test/receive-test.lisp        (with webrtc-data findable by ASDF)
;;;; Prints a verdict, exits 0 iff all pass.  No network: DATA chunk values go straight into
;;;; SCTP-HANDLE-DATA and what reaches ON-MESSAGE is checked.

(require :asdf)
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :webrtc-data)))

(defpackage #:webrtc-data-receive-test (:use #:cl))
(in-package #:webrtc-data-receive-test)

(defvar *checks* 0)
(defvar *fails* 0)
(defun check (name ok &optional detail)
  (incf *checks*)
  (unless ok (incf *fails*))
  (format t "  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" ok name detail))

(defvar *got* nil)
(defun fresh (&optional (initial-tsn 1000))
  (setf *got* nil)
  (let ((a (webrtc-data::make-sctp-assoc
            :on-message (lambda (assoc sid payload)
                          (declare (ignore assoc))
                          (push (list sid (map 'string #'code-char payload)) *got*)))))
    (setf (webrtc-data::sctp-assoc-last-received-tsn a) (1- initial-tsn))
    a))
(defun got () (reverse *got*))

(defun data (a tsn sid ssn text &key unordered (b t) (e t))
  "Feed one DATA chunk: binary PPID 53, TEXT as its bytes."
  (let ((v (webrtc-data::cat-bytes (webrtc-data::u32be tsn) (webrtc-data::u16be sid)
                                   (webrtc-data::u16be ssn) (webrtc-data::u32be 53)
                                   (map '(vector (unsigned-byte 8)) #'char-code text))))
    (webrtc-data::sctp-handle-data
     a (logior (if unordered #x04 0) (if b #x02 0) (if e #x01 0)) v)))

(defun forward-tsn (a new &rest sid-ssn)
  (webrtc-data::sctp-handle-forward-tsn
   a (apply #'webrtc-data::cat-bytes (webrtc-data::u32be new)
            (loop for (sid ssn) on sid-ssn by #'cddr
                  collect (webrtc-data::cat-bytes (webrtc-data::u16be sid) (webrtc-data::u16be ssn))))))

(defun cum (a) (webrtc-data::sctp-assoc-last-received-tsn a))

(format t "~&[webrtc-data receive]~%")

(let ((a (fresh)))
  (data a 1000 0 0 "a") (data a 1001 0 1 "b")
  (check "in order on one stream" (equal (got) '((0 "a") (0 "b"))) (got))
  (check "the cumulative TSN follows" (= (cum a) 1001)))

(let ((a (fresh)))
  (data a 1001 106 0 "ptr" :unordered t)
  (check "an unordered message behind a hole goes up at once" (equal (got) '((106 "ptr"))) (got))
  (check "...while the hole holds the cumulative TSN" (= (cum a) 999))
  (data a 1002 0 1 "second")
  (check "an ordered message ahead of its turn waits" (equal (got) '((106 "ptr"))) (got))
  (data a 1000 0 0 "first")
  (check "the hole filled: the stream goes up in SSN order"
         (equal (got) '((106 "ptr") (0 "first") (0 "second"))) (got))
  (check "...and the cumulative TSN covers it all" (= (cum a) 1002)))

(let ((a (fresh)))
  (data a 1001 1 0 "other stream")
  (check "a hole on one ordered stream does not hold another" (equal (got) '((1 "other stream"))) (got)))

(let ((a (fresh)))
  (data a 1002 0 0 "ld" :b nil :e t)
  (data a 1000 0 0 "wor" :b t :e nil)
  (check "a fragmented message is not delivered in part" (null (got)) (got))
  (data a 1001 0 0 "l" :b nil :e nil)   ; wor + l + ld
  (check "it is delivered whole when its last fragment lands, in TSN order"
         (equal (got) '((0 "worlld"))) (got)))

(let ((a (fresh)))                      ; 1000 (stream 0) is lost; 1001-1002 are one message
  (data a 1002 2 0 "ag" :unordered t :b nil :e t)
  (data a 1001 2 0 "fr" :unordered t :b t :e nil)
  (check "an unordered fragmented message goes up whole behind another stream's hole"
         (equal (got) '((2 "frag"))) (got)))

(let ((a (fresh)))
  (data a 1001 0 0 "kept")
  (check "a received TSN above a hole is reported, not delivered past its stream"
         (and (equal (got) '((0 "kept"))) (= (cum a) 999)))
  (forward-tsn a 1000)
  (check "FORWARD-TSN over an abandoned TSN moves the cumulative TSN past what followed it"
         (= (cum a) 1001) (cum a))
  (check "...and the gap list is empty again"
         (zerop (hash-table-count (webrtc-data::sctp-assoc-rcv-buffer a)))))

(let ((a (fresh)))
  (data a 1000 3 0 "half" :b t :e nil)
  (forward-tsn a 1001)
  (check "FORWARD-TSN drops an abandoned message's fragments"
         (zerop (hash-table-count (webrtc-data::sctp-assoc-rcv-frags a))))
  (data a 1001 3 0 "late" :b nil :e t)
  (check "...and a fragment it covers is a duplicate, not a message" (null (got)) (got)))

(let ((a (fresh)))
  (data a 1001 4 1 "after-skip")
  (forward-tsn a 1000 4 0)
  (check "FORWARD-TSN's (stream, SSN) skips an abandoned ordered message and drains the stream"
         (equal (got) '((4 "after-skip"))) (got)))

(let ((a (fresh)))
  (data a 1000 0 0 "once")
  (data a 1000 0 0 "once")
  (check "a duplicate TSN is not redelivered" (equal (got) '((0 "once"))) (got))
  (check "...and is reported" (equal (webrtc-data::sctp-assoc-dup-tsns a) '(1000))))

(let ((a (fresh)))
  (setf (gethash 0 (webrtc-data::sctp-assoc-rcv-next-ssn a)) 65535)
  (data a 1000 0 65535 "last") (data a 1001 0 0 "wrapped")
  (check "the SSN wraps at 65535" (equal (got) '((0 "last") (0 "wrapped"))) (got)))

(let ((a (fresh #xFFFFFFFF)))
  (data a #xFFFFFFFF 0 0 "x") (data a 0 0 1 "y")
  (check "the TSN wraps at 2^32" (and (equal (got) '((0 "x") (0 "y"))) (= (cum a) 0))))

(format t "checks: ~d   failures: ~d   => ~:[FAIL~;PASS~]~%" *checks* *fails* (zerop *fails*))
(uiop:quit (if (zerop *fails*) 0 1))
