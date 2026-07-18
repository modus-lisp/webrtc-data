;;;; src/sdp.lisp — the tiny slice of SDP a data-channel-only session needs.
;;;;
;;;; We parse the remote OFFER (its ICE ufrag/pwd, DTLS fingerprint, candidates, sctp-port,
;;;; setup role) and generate our ANSWER.  Non-trickle: all candidates live in the SDP, so
;;;; signaling is just one offer/answer exchange.  Media is always a single m=application
;;;; (webrtc-datachannel) — no audio/video lines.

(in-package #:webrtc-data)

(defstruct ice-candidate foundation component transport priority ip port type)

(defstruct (sdp-session (:conc-name sdp-))
  ice-ufrag ice-pwd fingerprint setup (candidates '()) (sctp-port 5000) (mid "0")
  (max-message-size 65536))

(defun %split (line &optional (sep #\Space))
  (loop with s = 0 with out = '() with len = (length line)
        for p = (position sep line :start s)
        do (push (subseq line s (or p len)) out)
           (if p (setf s (1+ p)) (return (nreverse out)))))

(defun %aval (line prefix)
  "If LINE starts with PREFIX, return the rest, else NIL."
  (when (and (>= (length line) (length prefix)) (string= line prefix :end1 (length prefix)))
    (string-trim '(#\Space #\Return) (subseq line (length prefix)))))

(defun parse-candidate (val)
  "candidate foundation component transport priority ip port typ type ..."
  (let ((f (%split val)))
    (make-ice-candidate :foundation (nth 0 f) :component (parse-integer (nth 1 f))
                        :transport (string-downcase (nth 2 f)) :priority (parse-integer (nth 3 f))
                        :ip (nth 4 f) :port (parse-integer (nth 5 f)) :type (nth 7 f))))

(defun parse-sdp (sdp)
  "Parse a data-channel offer/answer into an SDP-SESSION."
  (let ((s (make-sdp-session)))
    (dolist (raw (%split sdp #\Newline) s)
      (let ((line (string-trim '(#\Return #\Space) raw)))
        (let (v)
          (cond
            ((setf v (%aval line "a=ice-ufrag:")) (setf (sdp-ice-ufrag s) v))
            ((setf v (%aval line "a=ice-pwd:")) (setf (sdp-ice-pwd s) v))
            ((setf v (%aval line "a=fingerprint:sha-256 ")) (setf (sdp-fingerprint s) v))
            ((setf v (%aval line "a=setup:")) (setf (sdp-setup s) v))
            ((setf v (%aval line "a=mid:")) (setf (sdp-mid s) v))
            ((setf v (%aval line "a=sctp-port:")) (setf (sdp-sctp-port s) (parse-integer v)))
            ((setf v (%aval line "a=max-message-size:")) (setf (sdp-max-message-size s) (parse-integer v)))
            ((setf v (%aval line "a=candidate:"))
             (push (parse-candidate v) (sdp-candidates s)))))))))

(defun make-answer-sdp (&key ice-ufrag ice-pwd fingerprint ip port
                             (sctp-port 5000) (mid "0") (setup "active") (foundation "1")
                             (priority 2130706431) (session-id "3993324220") (lite t))
  "Build the answer SDP.  FINGERPRINT is our DTLS cert's SHA-256 as colon-hex; IP/PORT is our
   host ICE candidate; SETUP \"active\" means we are the DTLS client; LITE advertises ICE-lite
   (the peer then does all connectivity checks + nomination — we only answer)."
  (format nil "v=0~%o=- ~a ~a IN IP4 0.0.0.0~%s=-~%t=0 0~%~@[a=ice-lite~%~*~]a=group:BUNDLE ~a~%~
               a=msid-semantic:WMS *~%~
               m=application ~d UDP/DTLS/SCTP webrtc-datachannel~%~
               c=IN IP4 ~a~%a=mid:~a~%a=sctp-port:~d~%a=max-message-size:65536~%~
               a=candidate:~a 1 udp ~d ~a ~d typ host~%a=end-of-candidates~%~
               a=ice-ufrag:~a~%a=ice-pwd:~a~%a=fingerprint:sha-256 ~a~%a=setup:~a~%"
          session-id session-id lite mid port ip mid sctp-port
          foundation priority ip port ice-ufrag ice-pwd fingerprint setup))
