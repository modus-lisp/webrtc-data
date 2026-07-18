;;;; gateway.lisp — serve glass over WebRTC to a browser (noVNC on the data channel).
;;;;
;;;; hunchentoot serves the noVNC page + one POST /signal for the SDP exchange.  For each
;;;; browser we set up the webrtc-data answerer (ICE-lite -> DTLS -> SCTP), and when the data
;;;; channel opens we open a TCP connection to glass's RFB server and pump bytes both ways:
;;;;   glass -> channel  (chunked, since our SCTP doesn't fragment)
;;;;   channel -> glass  (noVNC's RFB client messages)
;;;; The gateway is transparent to RFB: noVNC is the client, glass is the server.

(require :asdf)
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system "webrtc-data")
  (ql:quickload '(:hunchentoot) :silent t))

(in-package #:webrtc-data)

(defparameter *dir* (uiop:pathname-directory-pathname
                     (or *load-pathname* *default-pathname-defaults*)))
;; noVNC: $NOVNC_DIR, else the vendored copy next to this demo (novnc/, includes our TRLE decoder).
(defparameter *novnc* (truename (or (uiop:getenv "NOVNC_DIR")
                                    (merge-pathnames "novnc/" *dir*))))
(defparameter *index* (uiop:read-file-string (merge-pathnames "index.html" *dir*)))
(defparameter *port*       (or (ignore-errors (parse-integer (uiop:getenv "GW_PORT"))) 8765))
(defparameter *epoch* (get-internal-real-time))   ; series time origin (ms since load)
(defparameter *glass-host* (or (uiop:getenv "GLASS_HOST") "127.0.0.1"))
(defparameter *glass-port* (or (ignore-errors (parse-integer (uiop:getenv "GLASS_PORT"))) 5900))

(defun glass-connect ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-connect s (sb-bsd-sockets:make-inet-address *glass-host*) *glass-port*)
    s))

(defvar *last-assoc* nil)   ; most recent SCTP association, for the /stats endpoint

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
                 (setf glass (glass-connect) *last-assoc* assoc)
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
                        (sleep 1.0)
                        (let* ((now (sctp-stats assoc))
                               (dt (max 1d-3 (/ (float (- (get-internal-real-time) t0) 1d0)
                                                internal-time-units-per-second))))
                          (flet ((d (k) (- (getf now k) (getf prev k))))
                            (format *error-output*
                                    "~&[stats] out ~,1f KB/s  in ~,1f KB/s  rtx ~a (~,1f%)  drops ~a  ~
                                     cwnd ~a  rwnd ~a  flight ~a  outq ~a  srtt ~a  rto ~,2f~%"
                                    (/ (d :bytes-out) 1024d0 dt) (/ (d :bytes-in) 1024d0 dt)
                                    (d :rtx)
                                    (if (plusp (d :data-out)) (* 100d0 (/ (d :rtx) (d :data-out))) 0d0)
                                    (d :drops)
                                    (getf now :cwnd) (getf now :peer-rwnd) (getf now :flight)
                                    (getf now :send-q)
                                    (let ((s (getf now :srtt-ms))) (if s (format nil "~,1fms" s) "-"))
                                    (getf now :rto))
                            ;; machine-readable series line (parsed by the perf harness)
                            (format *error-output*
                                    "~&PERFSVR ~,1f ~,2f ~,2f ~a ~a ~a ~,1f ~a ~a ~,2f~%"
                                    (/ (float (- (get-internal-real-time) *epoch*) 1d0)
                                       internal-time-units-per-second)
                                    (/ (d :bytes-out) 1024d0 dt) (/ (d :bytes-in) 1024d0 dt)
                                    (d :rtx) (d :drops) (getf now :cwnd)
                                    (or (getf now :srtt-ms) -1) (getf now :flight) (getf now :send-q)
                                    (getf now :rto))
                            (finish-output *error-output*))   ; flush: survive an ungraceful kill
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
         ;; ICE_LOCAL_IP pins the advertised host candidate (multi-homed / netns / container
         ;; deploys, where auto-detect can't reach 8.8.8.8); nil = auto-detect.
         (agent (make-ice :local-ip (uiop:getenv "ICE_LOCAL_IP")))
         (conn (webrtc-dtls-setup agent :remote-fingerprint (sdp-fingerprint offer)))
         (answer (ice-answer agent offer :fingerprint (dtls-conn-fingerprint conn))))
    (ice-serve agent)
    (bt:make-thread (lambda () (run-session conn)) :name "webrtc-session")
    answer))

(defun handle-index ()
  (setf (hunchentoot:content-type*) "text/html") *index*)

(defun handle-drop ()
  "GET /drop?rate=R — set *SCTP-DROP-RATE* (a dev knob for simulating outbound loss)."
  (setf (hunchentoot:content-type*) "text/plain")
  (let ((r (ignore-errors (read-from-string (hunchentoot:get-parameter "rate")))))
    (when (realp r)
      (setf (symbol-value (find-symbol "*SCTP-DROP-RATE*" :webrtc-data)) (float r 1d0))))
  (format nil "drop-rate=~a~%" (symbol-value (find-symbol "*SCTP-DROP-RATE*" :webrtc-data))))

(defun handle-stats ()
  "GET /stats — the current session's SCTP transport stats as JSON."
  (setf (hunchentoot:content-type*) "application/json")
  (if *last-assoc*
      (format nil "{~{~a~^,~}}"
              (loop for (k v) on (sctp-stats *last-assoc*) by #'cddr
                    collect (format nil "\"~(~a~)\":~a"
                                    k (cond ((null v) -1) ((symbolp v) (format nil "\"~(~a~)\"" v))
                                            ((floatp v) (format nil "~,2f" v)) (t v)))))
      "{}"))

(setf hunchentoot:*dispatch-table*
      (list (hunchentoot:create-folder-dispatcher-and-handler "/novnc/" *novnc*)
            (hunchentoot:create-regex-dispatcher "^/signal$" #'handle-signal)
            (hunchentoot:create-regex-dispatcher "^/drop$" #'handle-drop)
            (hunchentoot:create-regex-dispatcher "^/stats$" #'handle-stats)
            (hunchentoot:create-regex-dispatcher "^/$" #'handle-index)))

(defvar *acceptor*
  (hunchentoot:start (make-instance 'hunchentoot:easy-acceptor :port *port* :address "0.0.0.0")))
(format t "~&@@ gateway on http://0.0.0.0:~a  (glass ~a:~a, noVNC ~a)~%"
        *port* *glass-host* *glass-port* *novnc*)
(finish-output)
(loop (sleep 5))
