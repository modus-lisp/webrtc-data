;;;; src/sdp.lisp — the slice of SDP a bundled data-channel + audio session needs.
;;;;
;;;; We parse the remote OFFER (ICE ufrag/pwd, DTLS fingerprint, setup role, candidates, and the
;;;; list of media m-lines) and generate our ANSWER.  Non-trickle: all candidates live in the SDP,
;;;; so signaling is one offer/answer exchange.  Media sections share one bundled ICE/DTLS transport
;;;; (a=group:BUNDLE).  We answer every offered m-line so the m-lines line up (the browser rejects a
;;;; mismatched answer): m=application -> webrtc-datachannel; m=audio -> G.711 PCMU (payload type 0)
;;;; if the offer lists it, else rejected (port 0).

(in-package #:webrtc-data)

(defstruct ice-candidate foundation component transport priority ip port type)

(defstruct (sdp-media (:conc-name sdp-media-))
  type mid (pts '()) (sctp-port 5000) (direction "sendrecv"))

(defstruct (sdp-session (:conc-name sdp-))
  ice-ufrag ice-pwd fingerprint setup (candidates '()) (media '()))

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
  "Parse an offer/answer into an SDP-SESSION.  Session-level ICE/fingerprint/setup are shared
across all bundled m-lines; per-media a=mid / a=sctp-port / direction attach to the current section."
  (let ((s (make-sdp-session)) (cur nil))
    (dolist (raw (%split sdp #\Newline))
      (let ((line (string-trim '(#\Return #\Space) raw)) v)
        (cond
          ((%aval line "m=")                                  ; new media section
           (let* ((f (%split line)) (type (subseq (first f) 2)))
             (setf cur (make-sdp-media
                        :type type
                        :pts (loop for x in (nthcdr 3 f)       ; payload types (RTP media only)
                                   for n = (ignore-errors (parse-integer x)) when n collect n)))
             (push cur (sdp-media s))))
          ((setf v (%aval line "a=ice-ufrag:")) (setf (sdp-ice-ufrag s) v))
          ((setf v (%aval line "a=ice-pwd:")) (setf (sdp-ice-pwd s) v))
          ((setf v (%aval line "a=fingerprint:sha-256 ")) (setf (sdp-fingerprint s) v))
          ((setf v (%aval line "a=setup:")) (setf (sdp-setup s) v))
          ((setf v (%aval line "a=mid:")) (when cur (setf (sdp-media-mid cur) v)))
          ((setf v (%aval line "a=sctp-port:")) (when cur (setf (sdp-media-sctp-port cur) (parse-integer v))))
          ((member line '("a=sendrecv" "a=sendonly" "a=recvonly" "a=inactive") :test #'string=)
           (when cur (setf (sdp-media-direction cur) (subseq line 2))))
          ((setf v (%aval line "a=candidate:")) (push (parse-candidate v) (sdp-candidates s))))))
    (setf (sdp-media s) (nreverse (sdp-media s))
          (sdp-candidates s) (nreverse (sdp-candidates s)))
    s))

;;; Convenience for callers that only care about the data channel.
(defun sdp-mid (s) (let ((m (find "application" (sdp-media s) :key #'sdp-media-type :test #'string=)))
                     (if m (sdp-media-mid m) (and (sdp-media s) (sdp-media-mid (first (sdp-media s)))))))

(defun %candidates-block (ip port srflx-ip srflx-port relay-ip relay-port foundation priority)
  (concatenate 'string
    (format nil "a=candidate:~a 1 udp ~d ~a ~d typ host~%" foundation priority ip port)
    (if srflx-ip (format nil "a=candidate:2 1 udp ~d ~a ~d typ srflx raddr ~a rport ~d~%"
                         1694498815 srflx-ip srflx-port ip port) "")
    (if relay-ip (format nil "a=candidate:3 1 udp ~d ~a ~d typ relay raddr ~a rport ~d~%"
                         41885439 relay-ip relay-port (or srflx-ip ip) (or srflx-port port)) "")
    (format nil "a=end-of-candidates~%")))

(defun make-answer-sdp (&key ice-ufrag ice-pwd fingerprint ip port srflx-ip srflx-port
                             relay-ip relay-port media
                             (setup "active") (foundation "1")
                             (priority 2130706431) (session-id "3993324220") (lite t))
  "Build the answer SDP.  MEDIA is the offer's list of SDP-MEDIA (so our m-lines line up); if NIL,
answer a single data channel.  FINGERPRINT is our DTLS cert SHA-256 (colon-hex); IP/PORT the host
candidate; SRFLX-* / RELAY-* add server-reflexive / TURN-relay candidates; SETUP \"active\" = we are
the DTLS client; LITE advertises ICE-lite.  Audio is answered as G.711 PCMU (pt 0)."
  (let* ((media (or media (list (make-sdp-media :type "application" :mid "0" :sctp-port 5000))))
         (cands (%candidates-block ip port srflx-ip srflx-port relay-ip relay-port foundation priority))
         (shared (format nil "a=ice-ufrag:~a~%a=ice-pwd:~a~%a=fingerprint:sha-256 ~a~%a=setup:~a~%"
                         ice-ufrag ice-pwd fingerprint setup)))
    (with-output-to-string (out)
      (format out "v=0~%o=- ~a ~a IN IP4 0.0.0.0~%s=-~%t=0 0~%~@[a=ice-lite~%~*~]a=group:BUNDLE ~{~a~^ ~}~%~
                   a=msid-semantic:WMS *~%"
              session-id session-id lite (mapcar #'sdp-media-mid media))
      (loop for m in media for first = t then nil
            for own = (if first cands "") do
        (cond
          ((string= (sdp-media-type m) "audio")
           (let ((ok (member 0 (sdp-media-pts m))))            ; we only offer PCMU
             (format out "m=audio ~d UDP/TLS/RTP/SAVPF 0~%c=IN IP4 ~a~%a=rtcp-mux~%a=mid:~a~%~
                          a=~:[inactive~;sendrecv~]~%a=rtpmap:0 PCMU/8000~%~a~a"
                     (if ok port 0) ip (sdp-media-mid m) ok shared own)))
          (t                                                   ; application / data channel
           (format out "m=application ~d UDP/DTLS/SCTP webrtc-datachannel~%c=IN IP4 ~a~%~
                        a=mid:~a~%a=sctp-port:~d~%a=max-message-size:65536~%~a~a"
                   port ip (sdp-media-mid m) (or (sdp-media-sctp-port m) 5000) shared own)))))))
