;;;; test/transport-split-server.lisp — the :webrtc EXPOSE half of transport-split.sh.
;;;; EXPOSE on 127.0.0.1 and an ephemeral port (written to $PORT_FILE), the reversing echo
;;;; handler, until $STOP_FILE appears; then the closer, which must report every session ended.
(require :asdf)
(asdf:initialize-source-registry)       ; modus's ASDF reads CL_SOURCE_REGISTRY only when asked
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream))) (asdf:load-system "webrtc-data/transport")))
(defvar *served* 0)
(defun echo-reversed (stream peer)
  (declare (ignore peer))
  (let ((buf (make-array 5 :element-type '(unsigned-byte 8))))
    (when (= 5 (read-sequence buf stream))
      (write-sequence (reverse buf) stream)
      (force-output stream)
      (sleep 1))))
(let* ((port nil)
       (closer (cl-transport:expose #'echo-reversed :backend :webrtc
                                    :signal-host "127.0.0.1" :signal-port 0 :signal-path "/signal"
                                    :local-ip "127.0.0.1" :duration 60.0
                                    :on-listening (lambda (p) (setf port p)))))
  (with-open-file (o (uiop:getenv "PORT_FILE") :direction :output :if-exists :supersede)
    (format o "~d~%" port))
  (format t "~&SERVER-PORT ~d~%" port) (finish-output)
  (loop repeat 900 until (probe-file (uiop:getenv "STOP_FILE")) do (sleep 0.1))
  (format t "~&closer: ~:[FAIL~;ok~]~%" (funcall closer)) (finish-output))
(sb-ext:exit :code 0 :abort t)
