;;;; test/client-test.lisp — the calling side against the answering side, in one process.
;;;;   sbcl --script test/client-test.lisp        (with webrtc-data findable by ASDF)
;;;; Prints a verdict, exits 0 iff all pass.  Loopback only: the answerer is this library's own
;;;; threaded box path (ICE-ANSWER, WEBRTC-DTLS-RUN, WEBRTC-SERVE-DATACHANNEL), the caller is
;;;; CONNECT-PEER -- so every layer is exercised in both roles: ICE controlling vs ICE-lite,
;;;; DTLS server vs client, SCTP initiator vs responder, DCEP OPEN vs ACK.  Then bytes both ways
;;;; (a message big enough to fragment, both directions), a negotiated channel, the stream view,
;;;; and a close the answerer hears.

(require :asdf)
(unless (find-package '#:webrtc-data)
  (handler-bind ((warning #'muffle-warning))
    (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :webrtc-data))))

(defpackage #:webrtc-data-client-test (:use #:cl) (:local-nicknames (#:wd #:webrtc-data)))
(in-package #:webrtc-data-client-test)

(defvar *checks* 0)
(defvar *fails* 0)
(defun check (name ok &optional detail)
  (incf *checks*)
  (unless ok (incf *fails*))
  (format t "  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" ok name detail)
  (finish-output))

(defun bytes (n &optional (seed 7))
  (let ((v (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n v) (setf (aref v i) (mod (+ (* i seed) (ash i -8)) 256)))))

;;; ---- the answering side: the box's threaded path ------------------------------------------

(defvar *box-ready* '())                ; stream ids the box saw DCEP OPEN on
(defvar *box-got* '())                  ; (sid . payload) the box received
(defvar *box-assoc* nil)
(defvar *box-end* nil)                  ; the association's final state, once its loop returns
(defvar *box-lock* (sb-thread:make-mutex))

(defun box-answer (offer-sdp)
  "Answer OFFER-SDP the way the box does, run its session on a thread, return the answer."
  (let* ((offer (wd:parse-sdp offer-sdp))
         (agent (wd:make-ice :local-ip "127.0.0.1"))
         (conn (wd:webrtc-dtls-setup agent :remote-fingerprint (wd:sdp-fingerprint offer)))
         (answer (wd:ice-answer agent offer :fingerprint (wd::dtls-conn-fingerprint conn))))
    (wd:ice-serve agent)
    (wd:ice-start-checks agent)
    (sb-thread:make-thread
     (lambda ()
       (handler-case
           (progn
             (wd:webrtc-dtls-run conn :peer-wait 20.0)
             (let ((assoc (wd:webrtc-serve-datachannel
                           conn :duration 30.0
                           :on-ready (lambda (assoc sid)
                                       (setf *box-assoc* assoc)
                                       (sb-thread:with-mutex (*box-lock*) (push sid *box-ready*))
                                       ;; like an RFB server: the box speaks first
                                       (wd:sctp-send-string assoc sid "hello from the box"))
                           :on-message (lambda (assoc sid payload)
                                         (setf *box-assoc* assoc)
                                         (sb-thread:with-mutex (*box-lock*) (push (cons sid payload) *box-got*))
                                         ;; echo: strings prefixed, bytes reversed
                                         (if (stringp payload)
                                             (wd:sctp-send-string assoc sid (format nil "echo:~a" payload))
                                             (wd:sctp-send-binary assoc sid (reverse payload)))))))
               (setf *box-end* (wd:sctp-assoc-state assoc))))
         (error (e) (setf *box-end* (format nil "error: ~a" e))))
       (ignore-errors (wd:ice-close agent)))
     :name "test-box")
    answer))

;;; ---- the test ----------------------------------------------------------------------------

(defun wait-for (pred &optional (secs 10))
  (loop repeat (* secs 100) until (funcall pred) do (sleep 0.01))
  (funcall pred))

(defun run ()
  (format t "~&== webrtc-data: the calling side, loopback ==~%")
  (let* ((t0 (get-internal-real-time))
         (offer nil)
         (peer (handler-case
                   (wd:connect-peer (lambda (o) (setf offer o) (box-answer o))
                                    :local-ip "127.0.0.1"
                                    :channels '(("rfb")
                                                ("control" :id 100)
                                                ("warp" :id 102))
                                    :timeout 20.0)
                 (error (e) (check "connect-peer" nil (princ-to-string e)) (return-from run))))
         (ms (round (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second)))
    (check "the offer is a data-channel offer, actpass, with a host candidate"
           (and (search "m=application" offer) (search "a=setup:actpass" offer)
                (search "typ host" offer) (search "a=fingerprint:sha-256 " offer)))
    (check "connected: ICE, DTLS (we are the server), SCTP (we initiate), DCEP" (wd:rtc-open-p peer)
           (format nil "~d ms  ~{~(~a~) ~,3fs~^, ~}" ms
                   (loop for (k . v) in (reverse (wd:peer-timings peer)) collect k collect v)))
    (let* ((rfb (wd:rtc-channel peer "rfb")) (ctl (wd:rtc-channel peer 100)))
      (check "the in-band channel took an odd stream id (DTLS server, RFC 8832)" (oddp (wd:channel-id rfb))
             (wd:channel-id rfb))
      (check "the box saw DCEP OPEN on it" (wait-for (lambda () (member (wd:channel-id rfb) *box-ready*))))
      (check "the negotiated channels are open without a handshake"
             (and (eq (wd:channel-state ctl) :open) (eq (wd:channel-state (wd:rtc-channel peer "warp")) :open)))
      ;; the box spoke first, on the rfb channel: read it through the stream view
      (let* ((s (wd:rtc-channel-stream rfb))
             (buf (make-array 18 :element-type '(unsigned-byte 8))))
        (read-sequence buf s)
        (check "box -> caller: the box's first words arrive on the stream"
               (string= (map 'string #'code-char buf) "hello from the box"))
        ;; caller -> box: a message bigger than one SCTP chunk (fragmentation both ways)
        (let ((big (bytes 100000)))
          (write-sequence big s) (force-output s)
          (check "caller -> box: 100000 bytes arrive whole"
                 (wait-for (lambda () (find-if (lambda (x) (and (= (car x) (wd:channel-id rfb))
                                                                (vectorp (cdr x)) (not (stringp (cdr x)))
                                                                (= (length (cdr x)) 100000)
                                                                (equalp (cdr x) big)))
                                               *box-got*))))
          (let ((back (make-array 100000 :element-type '(unsigned-byte 8))))
            (let ((n (read-sequence back s)))
              (check "box -> caller: 100000 bytes back (the box reversed them)"
                     (and (= n 100000) (equalp back (reverse big))))))))
      ;; a string on the negotiated channel
      (let ((got nil))
        (setf (wd:channel-on-message ctl) (lambda (ch payload) (declare (ignore ch)) (setf got payload)))
        (wd:channel-send ctl "{\"t\":\"ping\"}")
        (check "negotiated channel 100: a string there and back"
               (wait-for (lambda () (equal got "echo:{\"t\":\"ping\"}"))) got)))
    (let ((st (wd:sctp-stats (wd:peer-assoc peer))))
      (check "no retransmissions on loopback" (zerop (getf st :rtx)) st))
    (wd:rtc-close peer)
    (check "closed here" (eq (wd:peer-state peer) :closed))
    (check "...and the box heard it (SCTP ABORT ends its session)"
           (wait-for (lambda () *box-end*) 5) *box-end*)))

(run)
(format t "~&client-test: ~d/~d passed~%" (- *checks* *fails*) *checks*)
(finish-output)
(sb-ext:exit :code (if (zerop *fails*) 0 1) :abort t)
