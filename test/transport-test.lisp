;;;; test/transport-test.lisp — the :webrtc EXPOSE backend, signalled over real HTTP.
;;;;   sbcl --script test/transport-test.lisp      (with webrtc-data/transport findable by ASDF)
;;;;
;;;; The whole inbound path, loopback only: cl-transport:EXPOSE :backend :webrtc starts the
;;;; POST /signal endpoint (cl-transport/http-server) on 127.0.0.1 and an ephemeral port; this
;;;; library's own calling side (CONNECT-PEER) dials it, and the offer goes over HTTP by CURL --
;;;; a client that is not ours -- and the answer comes back the same way.  Then bytes through
;;;; the stream ON-CONNECTION was handed, both ways.  Two EXPOSEs in one image keep their own
;;;; routes (hunchentoot had one global dispatch table, so the second replaced the first), and
;;;; each closer leaves its port closed.  Exits 0 iff all pass.

(require :asdf)
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system "webrtc-data/transport")))

(defpackage #:webrtc-transport-test (:use #:cl) (:local-nicknames (#:wd #:webrtc-data)))
(in-package #:webrtc-transport-test)

(defvar *checks* 0)
(defvar *fails* 0)
(defun check (name ok &optional detail)
  (incf *checks*)
  (unless ok (incf *fails*))
  (format t "  ~:[FAIL~;ok  ~] ~a~@[   ~a~]~%" ok name detail)
  (finish-output))

(defun curl-post (port path body)
  "BODY POSTed to 127.0.0.1:PORT PATH by curl: (values response-body status-code)."
  (let* ((out (with-output-to-string (o)
                (with-input-from-string (in body)
                  (sb-ext:run-program "curl" (list "-sS" "-o" "-" "-w" (format nil "~%%{http_code}")
                                                   "-H" "Content-Type: application/sdp"
                                                   "--data-binary" "@-"
                                                   (format nil "http://127.0.0.1:~d~a" port path))
                                      :search t :input in :output o :error nil))))
         (nl (position #\Newline out :from-end t)))
    (values (subseq out 0 nl) (parse-integer out :start (1+ nl) :junk-allowed t))))

(defun refused-p (port)
  (handler-case
      (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
        (unwind-protect (progn (sb-bsd-sockets:socket-connect s #(127 0 0 1) port) nil)
          (ignore-errors (sb-bsd-sockets:socket-close s))))
    (error () t)))

(defun echo-reversed (stream peer)
  "ON-CONNECTION: read 5 bytes, write them back reversed."
  (declare (ignore peer))
  (let ((buf (make-array 5 :element-type '(unsigned-byte 8))))
    (when (= 5 (read-sequence buf stream))
      (write-sequence (reverse buf) stream)
      (force-output stream)
      (sleep 1))))

(defun expose (path)
  "A :webrtc EXPOSE at PATH: (values closer port)."
  (let ((port nil))
    (let ((closer (cl-transport:expose #'echo-reversed :backend :webrtc
                                       :signal-host "127.0.0.1" :signal-port 0 :signal-path path
                                       :local-ip "127.0.0.1" :duration 30.0
                                       :on-listening (lambda (p) (setf port p)))))
      (values closer port))))

(format t "~&== webrtc-data/transport: EXPOSE :webrtc over HTTP ==~%")
(check "hunchentoot is not loaded" (not (find-package "HUNCHENTOOT")))
(multiple-value-bind (closer-a port-a) (expose "/signal")
  (multiple-value-bind (closer-b port-b) (expose "/other-signal")
    (check "both endpoints listen, on loopback ephemeral ports"
           (and (integerp port-a) (integerp port-b) (/= port-a port-b) (not (refused-p port-a))))
    (multiple-value-bind (body code) (curl-post port-a "/nowhere" "x")
      (declare (ignore body))
      (check "an unrouted path is a 404" (eql code 404) code))
    (check "a second EXPOSE did not take the first one's route away (per-server routes)"
           (eql 404 (nth-value 1 (curl-post port-b "/signal" "x"))))
    (dolist (case (list (list port-a "/signal") (list port-b "/other-signal")))
      (destructuring-bind (port path) case
        (let* ((status nil)
               (peer (handler-case
                         (wd:connect-peer (lambda (offer)
                                            (multiple-value-bind (answer code) (curl-post port path offer)
                                              (setf status code)
                                              answer))
                                          :local-ip "127.0.0.1" :channels '(("bytes")) :timeout 20.0)
                       (error (e) (check (format nil "~a: connect-peer" path) nil (princ-to-string e)) nil))))
          (when peer
            (unwind-protect
                 (progn
                   (check (format nil "~a: curl's POST got 200 and an answer that connected" path)
                          (and (eql status 200) (wd:rtc-open-p peer)) status)
                   (let ((s (wd:rtc-channel-stream (wd:rtc-channel peer "bytes")))
                         (buf (make-array 5 :element-type '(unsigned-byte 8))))
                     (write-sequence (map '(vector (unsigned-byte 8)) #'char-code "hello") s)
                     (force-output s)
                     (read-sequence buf s)
                     (check (format nil "~a: bytes through ON-CONNECTION's stream, both ways" path)
                            (string= (map 'string #'code-char buf) "olleh")
                            (map 'string #'code-char buf))))
              (ignore-errors (wd:rtc-close peer :abort t)))))))
    (funcall closer-a)
    (funcall closer-b)
    (check "each closer leaves its port closed" (and (refused-p port-a) (refused-p port-b)))))

(format t "~&checks: ~d   failures: ~d   => ~:[FAIL~;PASS~]~%" *checks* *fails* (zerop *fails*))
(finish-output)
(sb-ext:exit :code (if (zerop *fails*) 0 1) :abort t)
