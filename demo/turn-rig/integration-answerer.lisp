;;;; integration-answerer.lisp — webrtc-data answerer for the TURN integration proof.
;;;;
;;;; Full stack (ICE -> DTLS -> SCTP -> DCEP echo).  Env RELAY_MODE:
;;;;   relay      — gather a TURN relay candidate (env TURN_SERVER/USER/PASS) and advertise it.
;;;;   srflx-only — do NOT gather a relay candidate (only host/srflx).  With the peer forced to a
;;;;                relay-only ICE policy, this must fail to connect: the control negative.

(require :asdf)
(handler-bind ((warning #'muffle-warning)) (asdf:load-system "webrtc-data"))
(in-package #:webrtc-data)

(defparameter *dir* (or (uiop:getenv "TURN_DIR") "/tmp/turn-rig/"))
(defparameter *mode* (or (uiop:getenv "RELAY_MODE") "relay"))
(defparameter *local-ip* (or (uiop:getenv "ICE_LOCAL_IP") "127.0.0.1"))

(defun log! (fmt &rest args)
  (apply #'format t (concatenate 'string "~&@@ " fmt "~%") args) (finish-output))

(let ((offer (concatenate 'string *dir* "offer.sdp"))
      (answer (concatenate 'string *dir* "answer.sdp")))
  (log! "answerer mode=~a turn=~a" *mode* (uiop:getenv "TURN_SERVER"))
  (loop until (probe-file offer) do (sleep 0.2))
  (sleep 0.3)
  (let* ((off (parse-sdp (uiop:read-file-string offer)))
         (agent (make-ice :local-ip *local-ip*))
         (conn (webrtc-dtls-setup agent :remote-fingerprint (sdp-fingerprint off))))
    ;; :use-mapped-srflx nil -> advertise ONLY the relay candidate (not TURN's mapped address as a
    ;; srflx), so the proof isolates the relay path: nothing but the relay is reachable.
    (let ((sdp (ice-answer agent off :fingerprint (dtls-conn-fingerprint conn)
                                     :gather-relay (and (string-equal *mode* "relay")
                                                        '(:use-mapped-srflx nil)))))
      (log! "relay=~a:~a  (~d remote candidate(s))"
            (ice-agent-relay-ip agent) (ice-agent-relay-port agent)
            (length (ice-agent-remote-candidates agent)))
      (with-open-file (o answer :direction :output :if-exists :supersede :if-does-not-exist :create)
        (write-string sdp o)))
    (ice-serve agent)
    (when (ice-agent-turn agent)
      (turn-start-refresh (ice-agent-turn agent) (lambda () (ice-agent-stop agent))))
    (log! "serving on ~a:~a" (ice-agent-local-ip agent) (ice-agent-port agent))
    (handler-case
        (progn
          (webrtc-dtls-run conn :timeout 1.0 :peer-wait 25.0)
          (log! "DTLS HANDSHAKE COMPLETE done=~a peer=~a"
                (seal:dtls-done (dtls-conn-session conn)) (ice-agent-peer agent))
          (webrtc-serve-datachannel
           conn :duration 20.0 :log *standard-output*
           :on-message (lambda (assoc stream-id msg)
                         (log! "inbound message stream=~a: ~a" stream-id msg)
                         (if (stringp msg)
                             (sctp-send-string assoc stream-id msg)
                             (sctp-send-data assoc stream-id +ppid-binary+ msg))))
          (log! "SCTP loop done"))
      (error (e) (log! "ANSWERER FAILED (~a): ~a" *mode* e)))))
