;;;; video-profiles.lisp — the measured video profiles, and the control channel that switches
;;;; between them while a session is running.
;;;;
;;;; The numbers come from video-profile.env, which documents how they were measured.  What this
;;;; file adds is the ability to change them WITHOUT restarting anything: the encoder reads its
;;;; knobs on every pass of its loop (webrtc-media's *VIDEO-PROFILE*), so a profile applied here
;;;; takes effect on the next frame — same session, same RTP sequence, no reconnect, no black
;;;; frame.  That is what makes an A/B by feel possible: the two profiles are separated by a tap,
;;;; not by "edit the env, kill the gateway, wait for the phone to come back".
;;;;
;;;; The phone reaches this over a SECOND data channel, negotiated on a fixed stream id, carrying
;;;; JSON.  Not the RFB channel: that one is a byte stream with its own framing, and squeezing
;;;; control messages into it would mean teaching both ends to tell RFB bytes from ours.  Not
;;;; Nostr either: a relay round-trip is seconds, which is the wrong instrument for a comparison
;;;; you are making by eye.
;;;;
;;;;   phone -> box   {"profile":"balanced"}   switch
;;;;                  {"get":1}                just report the current state
;;;;   box -> phone   {"profile":"balanced","target_kbs":300,...,"profiles":[...]}
;;;;
;;;; Nothing here is a credential: the channel only exists inside an already-authenticated,
;;;; already-encrypted session, and the worst a message can do is name a profile.

(in-package #:webrtc-data)

;;; Stream id 100, negotiated: both ends agree on it in advance, so no DCEP exchange is needed and
;;; it cannot collide with the RFB channel (which the browser opens first, on stream 0).
(defconstant +control-stream-id+ 100)

(defun control-sid-p (sid) (eql sid +control-stream-id+))

;;; The profiles, as measured on a 1280x800 scroll (mean PSNR against the source while scrolling):
;;;
;;;   responsive  600 KB/s cap, frame <= 128 KB, cleanup 400 ms   55.7 dB    the live default
;;;   balanced    300 KB/s cap, frame <=  64 KB, cleanup 600 ms   50.9 dB
;;;   sharp       150 KB/s cap, frame <=  32 KB, cleanup 700 ms   16.6 dB    the old default
;;;
;;; All three are identical at rest; they differ only in what happens while the screen moves.
;;; TARGET-KBS is the one that matters, and not only as a rate: the sender paces a big frame's
;;; packets at it, sleeping in the encode loop, so it also decides how often the desktop is looked
;;; at.  VIDEO_FPS is deliberately absent — start-video accepts it and never reads it.
(defparameter *video-profiles*
  '(("responsive" :qi 8 :max-qi 44 :target-kbs 600 :max-frame-kb 128 :cleanup-ms 400)
    ("balanced"   :qi 8 :max-qi 44 :target-kbs 300 :max-frame-kb  64 :cleanup-ms 600)
    ("sharp"      :qi 8 :max-qi 44 :target-kbs 150 :max-frame-kb  32 :cleanup-ms 700)))

(defun video-profile (name)
  (cdr (assoc name *video-profiles* :test #'string-equal)))

(defvar *video-profile-name* nil
  "Name of the profile now in force, or NIL until the environment has been matched against the
table.  \"custom\" when the environment is not one of the three.")

(defun %env-int (name)
  (ignore-errors (parse-integer (uiop:getenv name))))

(defun detect-video-profile ()
  "Name the profile the gateway was STARTED with, by matching the environment against the table.
The env is the source of truth at startup (gw-keepalive.sh re-sources video-profile.env on every
respawn), so this is what the phone should see highlighted when it first connects."
  (let ((kbs (%env-int "VIDEO_TARGET_KBS")) (kb (%env-int "VIDEO_MAX_FRAME_KB")))
    (or (car (find-if (lambda (p)
                        (and kbs (eql kbs (getf (cdr p) :target-kbs))
                             (or (null kb) (eql kb (getf (cdr p) :max-frame-kb)))))
                      *video-profiles*))
        "custom")))

(defun apply-video-profile (name &key (why "control channel"))
  "Switch the RUNNING video sender to NAME.  Returns the profile plist, or NIL if NAME is unknown.
Setting webrtc-media:*VIDEO-PROFILE* is the whole mechanism — the sender re-reads it every pass."
  (let ((p (video-profile name)))
    (when p
      (setf webrtc-media:*video-profile* (list* :name (string-downcase name) p)
            *video-profile-name* (string-downcase name))
      (format *error-output* "~&[profile] ~a (~a) — target ~a KB/s, frame<=~a KB, cleanup ~a ms, qi ~a/~a~%"
              *video-profile-name* why (getf p :target-kbs) (getf p :max-frame-kb)
              (getf p :cleanup-ms) (getf p :qi) (getf p :max-qi))
      (finish-output *error-output*)
      p)))

(defun video-profile-status ()
  "The current state, as the JSON the phone highlights its buttons from."
  (let* ((name (or *video-profile-name* (setf *video-profile-name* (detect-video-profile))))
         (p (or (video-profile name) (list :target-kbs (%env-int "VIDEO_TARGET_KBS")
                                           :max-frame-kb (%env-int "VIDEO_MAX_FRAME_KB")
                                           :cleanup-ms (%env-int "VIDEO_CLEANUP_MS")
                                           :qi (%env-int "VIDEO_QI")
                                           :max-qi (%env-int "VIDEO_MAX_QI")))))
    (format nil "{\"profile\":\"~a\",\"target_kbs\":~a,\"max_frame_kb\":~a,\"cleanup_ms\":~a,\"qi\":~a,\"max_qi\":~a,\"profiles\":[~{\"~a\"~^,~}]}"
            name (or (getf p :target-kbs) 0) (or (getf p :max-frame-kb) 0)
            (or (getf p :cleanup-ms) 0) (or (getf p :qi) 0) (or (getf p :max-qi) 0)
            (mapcar #'car *video-profiles*))))

(defun %json-string-value (json key)
  "The string value of KEY in a flat JSON object, without a JSON parser: these messages are two
fields long and generated by a client we ship."
  (let ((at (search (format nil "\"~a\"" key) json)))
    (when at
      (let* ((colon (position #\: json :start (+ at (length key) 2)))
             (open (and colon (position #\" json :start (1+ colon))))
             (close (and open (position #\" json :start (1+ open)))))
        (when close (subseq json (1+ open) close))))))

(defun handle-control-message (assoc sid payload)
  "One JSON message from the phone on the control channel.  Always answers with the current state,
so the phone's buttons show what the box actually did rather than what was asked for."
  (let ((json (if (stringp payload) payload (map 'string #'code-char (as-u8vec payload)))))
    (let ((want (%json-string-value json "profile")))
      (when want
        (unless (apply-video-profile want)
          (format *error-output* "~&[profile] ignoring unknown profile ~s~%" want))))
    (ignore-errors (sctp-send-string assoc sid (video-profile-status)))))

;; Adopt the environment at load time: the sender then starts on exactly the values the keepalive
;; printed, and the phone sees the matching button already highlighted.  An environment that is not
;; one of the three is left alone — *VIDEO-PROFILE* stays NIL and START-VIDEO's own arguments stand.
(let ((name (detect-video-profile)))
  (if (video-profile name)
      (apply-video-profile name :why "startup")
      (setf *video-profile-name* name)))

