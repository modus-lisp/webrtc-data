;;;; test2-client.lisp — standalone TURN relay round-trip proof.
;;;;
;;;; Allocates a relayed address from the TURN server, pre-binds a channel for the third party's
;;;; fixed source port (so both directions ride ChannelData), then echoes every relayed datagram
;;;; back with an "ECHO:" prefix.  Writes the relayed address to relay.addr for the peer.

(require :asdf)
(handler-bind ((warning #'muffle-warning)) (asdf:load-system "webrtc-data"))
(in-package #:webrtc-data)

(defparameter *dir* (or (uiop:getenv "TURN_DIR") "/tmp/turn-rig/"))
(defparameter *peer-ip* (or (uiop:getenv "PEER_IP") "127.0.0.1"))
(defparameter *peer-port* (parse-integer (or (uiop:getenv "PEER_PORT") "45999")))

(defun log! (fmt &rest args)
  (apply #'format t (concatenate 'string "~&@@ " fmt "~%") args) (finish-output))

(let* ((agent (make-ice :local-ip "127.0.0.1")))
  (log! "gathering relay (TURN_SERVER=~a)" (uiop:getenv "TURN_SERVER"))
  (let ((ok (ice-gather-relay agent)))
    (log! "ice-gather-relay -> ~a" ok)
    (unless ok (log! "FAILED to allocate") (sb-ext:exit :code 3))
    (log! "RELAY ADDRESS = ~a:~a" (ice-agent-relay-ip agent) (ice-agent-relay-port agent))
    (with-open-file (o (concatenate 'string *dir* "relay.addr")
                       :direction :output :if-exists :supersede :if-does-not-exist :create)
      (format o "~a:~a~%" (ice-agent-relay-ip agent) (ice-agent-relay-port agent)))
    ;; Pre-bind a channel for the third party's known transport address (blocking, pre-serve):
    ;; proves ChannelData both directions.
    (let ((chan (turn-install-peer (ice-agent-turn agent) *peer-ip* *peer-port*)))
      (log! "turn-install-peer ~a:~a -> channel ~a" *peer-ip* *peer-port* chan))
    ;; Echo relayed datagrams back through the relay.
    (setf (ice-agent-on-packet agent)
          (lambda (pkt host port)
            (let ((s (bytes->ascii pkt)))
              (log! "RELAYED INBOUND (via ~a): ~a" host s)
              (ice-send agent (ascii (format nil "ECHO:~a" s)) host port))))
    (ice-serve agent)
    (log! "serving; echoing relayed traffic for 20s")
    (sleep 20)
    (log! "done")))
