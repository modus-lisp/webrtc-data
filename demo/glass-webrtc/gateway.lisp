;;;; gateway.lisp — serve glass over WebRTC to a browser (noVNC on the data channel).
;;;;
;;;; hunchentoot serves the noVNC page + one POST /signal for the SDP exchange.  For each
;;;; browser we set up the cl-webrtc answerer (ICE-lite -> DTLS -> SCTP), and when the data
;;;; channel opens we open a TCP connection to glass's RFB server and pump bytes both ways:
;;;;   glass -> channel  (chunked, since our SCTP doesn't fragment)
;;;;   channel -> glass  (noVNC's RFB client messages)
;;;; The gateway is transparent to RFB: noVNC is the client, glass is the server.

(require :asdf)
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system "cl-webrtc")
  (ql:quickload '(:hunchentoot) :silent t))

(in-package #:cl-webrtc)

(defparameter *dir* (uiop:pathname-directory-pathname
                     (or *load-pathname* *default-pathname-defaults*)))
;; noVNC checkout: $NOVNC_DIR, else ../novnc/ next to this demo.
(defparameter *novnc* (truename (or (uiop:getenv "NOVNC_DIR")
                                    (merge-pathnames "../novnc/" *dir*))))
(defparameter *index* (uiop:read-file-string (merge-pathnames "index.html" *dir*)))
(defparameter *port*       (or (ignore-errors (parse-integer (uiop:getenv "GW_PORT"))) 8765))
(defparameter *glass-host* (or (uiop:getenv "GLASS_HOST") "127.0.0.1"))
(defparameter *glass-port* (or (ignore-errors (parse-integer (uiop:getenv "GLASS_PORT"))) 5900))

(defun glass-connect ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-connect s (sb-bsd-sockets:make-inet-address *glass-host*) *glass-port*)
    s))

(defun run-session (conn)
  "Drive DTLS, then run the data channel; bridge it to glass once it opens."
  (let ((glass nil))
    (unwind-protect
        (handler-case
            (progn
              (webrtc-dtls-run conn)
              (webrtc-serve-datachannel
               conn :duration 3600.0
               :on-ready
               (lambda (assoc sid)
                 (setf glass (glass-connect))
                 (format *error-output* "~&[gw] channel open (stream ~a) -> glass ~a:~a~%"
                         sid *glass-host* *glass-port*)
                 ;; glass -> browser: read RFB, chunk under the no-fragmentation limit
                 (bt:make-thread
                  (lambda ()
                    (let ((buf (make-array 16384 :element-type '(unsigned-byte 8))))
                      (handler-case
                          (loop
                            (multiple-value-bind (b n) (sb-bsd-sockets:socket-receive glass buf nil)
                              (declare (ignore b))
                              (when (or (null n) (zerop n)) (return))
                              (loop for off from 0 below n by 1024
                                    do (sctp-send-binary assoc sid
                                                         (subseq buf off (min n (+ off 1024)))))))
                        (error () nil))))
                  :name "glass->ch")
                 ;; transport-health monitor: log SCTP rates every 2s until the peer aborts
                 (bt:make-thread
                  (lambda ()
                    (let ((prev (sctp-stats assoc)) (t0 (get-internal-real-time)))
                      (loop until (eq (getf (sctp-stats assoc) :state) :aborted) do
                        (sleep 2.0)
                        (let* ((now (sctp-stats assoc))
                               (dt (max 1d-3 (/ (float (- (get-internal-real-time) t0) 1d0)
                                                internal-time-units-per-second))))
                          (flet ((d (k) (- (getf now k) (getf prev k))))
                            (format *error-output*
                                    "~&[stats] out ~,1f KB/s  in ~,1f KB/s  rtx ~a (~,1f%)  drops ~a  ~
                                     cwnd ~a  rwnd ~a  flight ~a  outq ~a  rto ~,2f~%"
                                    (/ (d :bytes-out) 1024d0 dt) (/ (d :bytes-in) 1024d0 dt)
                                    (d :rtx)
                                    (if (plusp (d :data-out)) (* 100d0 (/ (d :rtx) (d :data-out))) 0d0)
                                    (d :drops)
                                    (getf now :cwnd) (getf now :peer-rwnd) (getf now :flight)
                                    (getf now :send-q) (getf now :rto)))
                          (setf prev now t0 (get-internal-real-time))))))
                  :name "gw-stats"))
               :on-message
               (lambda (assoc sid payload)
                 (declare (ignore assoc sid))
                 (when (and glass (plusp (length payload)))
                   (sb-bsd-sockets:socket-send glass (as-u8vec payload) (length payload))))))
          (error (e) (format *error-output* "~&[gw] session error: ~a~%" e)))
      ;; cleanup: close the glass connection so glass's per-client thread exits too
      (when glass (ignore-errors (sb-bsd-sockets:socket-close glass)))
      (format *error-output* "~&[gw] session closed~%"))))

(defun handle-signal ()
  "POST /signal: body is the browser's offer SDP; return our answer SDP."
  (setf (hunchentoot:content-type*) "application/sdp")
  (let* ((offer (parse-sdp (hunchentoot:raw-post-data :force-text t)))
         (agent (make-ice))
         (conn (webrtc-dtls-setup agent :remote-fingerprint (sdp-fingerprint offer)))
         (answer (ice-answer agent offer :fingerprint (dtls-conn-fingerprint conn))))
    (ice-serve agent)
    (bt:make-thread (lambda () (run-session conn)) :name "webrtc-session")
    answer))

(defun handle-index ()
  (setf (hunchentoot:content-type*) "text/html") *index*)

(setf hunchentoot:*dispatch-table*
      (list (hunchentoot:create-folder-dispatcher-and-handler "/novnc/" *novnc*)
            (hunchentoot:create-regex-dispatcher "^/signal$" #'handle-signal)
            (hunchentoot:create-regex-dispatcher "^/$" #'handle-index)))

(defvar *acceptor*
  (hunchentoot:start (make-instance 'hunchentoot:easy-acceptor :port *port* :address "0.0.0.0")))
(format t "~&@@ gateway on http://0.0.0.0:~a  (glass ~a:~a, noVNC ~a)~%"
        *port* *glass-host* *glass-port* *novnc*)
(finish-output)
(loop (sleep 5))
