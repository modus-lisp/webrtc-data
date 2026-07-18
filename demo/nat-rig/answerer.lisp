;;;; answerer.lisp — the webrtc-data answerer for the NAT-traversal A/B rig.
;;;;
;;;; Runs behind the NAT (side S).  Reads offer.sdp when it appears, sets up ICE -> DTLS ->
;;;; SCTP -> DCEP and echoes.  The A/B knob is env RIG_MODE:
;;;;
;;;;   full      (A) — gather a server-reflexive candidate (STUN) AND send our own connectivity
;;;;                   checks toward the peer (ice-start-checks).  Those outbound checks punch our
;;;;                   NAT mapping open toward the peer's address, so the peer's checks get in.
;;;;   lite      (B) — gather srflx (so the peer HAS our public mapping to aim at) but do NOT
;;;;                   send checks.  This isolates the connectivity-checks feature: the peer's
;;;;                   checks to our public mapping are dropped by the restricted NAT, because we
;;;;                   never sent out to the peer's address.  The scientifically clean negative.
;;;;   hostonly      — the task's literal ICE-lite: host candidate only, no srflx, no checks.
;;;;                   Also fails, but trivially (peer only sees an unroutable private candidate).
;;;;
;;;; Env: RIG_MODE=full|lite|hostonly, RIG_DIR=<shared dir for offer.sdp/answer.sdp>,
;;;;      ICE_LOCAL_IP=<our private host IP>, STUN_SERVER=host:port (read inside ice.lisp).

(require :asdf)
(handler-bind ((warning #'muffle-warning)) (asdf:load-system "webrtc-data"))
(in-package #:webrtc-data)

(defparameter *dir* (or (uiop:getenv "RIG_DIR") "/tmp/nat-rig/"))
(defparameter *mode* (or (uiop:getenv "RIG_MODE") "full"))
(defparameter *local-ip* (uiop:getenv "ICE_LOCAL_IP"))
;; srflx: advertise a public mapping (full + lite).  checks: send connectivity checks (full only).
(defparameter *gather-srflx* (not (string-equal *mode* "hostonly")))
(defparameter *checks* (string-equal *mode* "full"))

(defun log! (fmt &rest args)
  (apply #'format t (concatenate 'string "~&@@ " fmt "~%") args)
  (finish-output))

(let ((offer (concatenate 'string *dir* "offer.sdp"))
      (answer (concatenate 'string *dir* "answer.sdp")))
  (log! "answerer mode=~a local-ip=~a stun=~a" *mode* *local-ip* (uiop:getenv "STUN_SERVER"))
  (loop until (probe-file offer) do (sleep 0.2))
  (sleep 0.3)
  (let* ((off (parse-sdp (uiop:read-file-string offer)))
         (agent (make-ice :local-ip *local-ip*))
         (conn (webrtc-dtls-setup agent :remote-fingerprint (sdp-fingerprint off))))
    ;; full + lite gather srflx (advertise a public mapping); hostonly does not.
    (let ((sdp (ice-answer agent off :fingerprint (dtls-conn-fingerprint conn)
                                     :gather-srflx *gather-srflx*)))
      (log! "srflx=~a:~a host=~a:~a" (ice-agent-srflx-ip agent) (ice-agent-srflx-port agent)
            (ice-agent-local-ip agent) (ice-agent-port agent))
      (with-open-file (o answer :direction :output :if-exists :supersede :if-does-not-exist :create)
        (write-string sdp o)))
    (ice-serve agent)
    ;; full-agent sends connectivity checks toward the peer's candidates — this is what
    ;; punches the NAT mapping open.  lite / hostonly do NOT.
    (when *checks*
      (ice-start-checks agent)
      (log! "ice-start-checks running toward ~d peer candidate(s)"
            (length (ice-agent-remote-candidates agent))))
    (log! "answerer serving on ~a:~a" (ice-agent-local-ip agent) (ice-agent-port agent))
    (handler-case
        (progn
          (webrtc-dtls-run conn :timeout 1.0 :peer-wait 22.0)
          (log! "DTLS HANDSHAKE COMPLETE done=~a" (seal:dtls-done (dtls-conn-session conn)))
          (webrtc-serve-datachannel
           conn :duration 20.0 :log *standard-output*
           :on-message (lambda (assoc stream-id msg)
                         (log! "inbound message stream=~a: ~a" stream-id msg)
                         (if (stringp msg)
                             (sctp-send-string assoc stream-id msg)
                             (sctp-send-data assoc stream-id +ppid-binary+ msg))))
          (log! "SCTP loop done"))
      (error (e)
        (log! "ANSWERER FAILED (~a): ~a" *mode* e)))))
