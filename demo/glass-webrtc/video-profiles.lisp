;;;; video-profiles.lisp — the bandwidth ladder, and the control channel that moves between its
;;;; rungs while a session is running.
;;;;
;;;; The ladder is SEVEN RUNGS IN KILOBITS PER SECOND — 5, 16, 48, 160, 480, 1600, 4800 — because
;;;; that is the unit a link is described in.  Everything the encoder actually takes is DERIVED
;;;; from that one number (see RUNG-SETTINGS): there are no hand-tuned profiles left to drift out
;;;; of step with each other, and adding a rung is adding a number to a list.
;;;;
;;;; A FACTOR OF THREE PER STEP, so seven rungs span a thousandfold — 0.625 KB/s to 600 KB/s —
;;;; and every rung is round in BOTH units: 5/16/48/160/480/1600/4800 kbps is 0.625/2/6/20/60/
;;;; 200/600 KB/s.  The ladder used to double, from 5 to 320, and 320 kbps is 40 KB/s: a fifteenth
;;;; of the rate the profile it replaced asked for, and far below what an ordinary link carries.
;;;; A ladder whose top rung a 3 ms link finishes in its sleep is not a ladder, it is a throttle,
;;;; so the top is now the 600 KB/s that was measured working and the STEPS were widened to reach
;;;; it rather than rungs being added — seven taps across the whole range is a stepper you can use
;;;; on a phone, and fourteen is a menu.
;;;;
;;;; The bottom stays at 5 kbps.  It is not a rate anyone would choose; it is the rung that proves
;;;; the derivations hold when the link is genuinely hostile, and losing it would mean losing the
;;;; only place the low-rate behaviour can be exercised on purpose.
;;;;
;;;; Note the unit change, and that there are two of them.  A rung's rate in kbps is kbps*125
;;;; bytes/s, i.e. kbps/8 KILOBYTES/s — that is the number the ladder is named in and the one the
;;;; log line leads with.  The encoder's own TARGET-KBS is KIBIbytes/s (bytes/1024), 2.4% smaller,
;;;; which is why the top rung is "600 KB/s" and "585.94 KiB/s to the encoder" on the same line.
;;;;
;;;; The encoder reads its knobs on every pass of its loop (webrtc-media's *VIDEO-PROFILE*), so a
;;;; rung applied here takes effect on the next frame — same session, same RTP sequence, no
;;;; reconnect, no black frame.  That is what makes an A/B by feel possible: two rungs are
;;;; separated by a tap, not by "edit the env, kill the gateway, wait for the phone to come back".
;;;;
;;;; The phone reaches this over a SECOND data channel, negotiated on a fixed stream id, carrying
;;;; JSON.  Not the RFB channel: that one is a byte stream with its own framing, and squeezing
;;;; control messages into it would mean teaching both ends to tell RFB bytes from ours.  Not
;;;; Nostr either: a relay round-trip is seconds, which is the wrong instrument for a comparison
;;;; you are making by eye.
;;;;
;;;;   phone -> box   {"kbps":480}             move to the 480 kbps rung
;;;;                  {"get":1}                just report the current state
;;;;                  {"request":"keyframe"}   my decoder is stranded, start me again
;;;;   box -> phone   {"kbps":480,"rung":4,"target_kbs":58.59,...,"rungs":[5,16,...]}
;;;;
;;;; Nothing here is a credential: the channel only exists inside an already-authenticated,
;;;; already-encrypted session, and the worst a message can do is name a rate.

(in-package #:webrtc-data)

;;; Stream id 100, negotiated: both ends agree on it in advance, so no DCEP exchange is needed and
;;; it cannot collide with the RFB channel (which the browser opens first, on stream 0).
(defconstant +control-stream-id+ 100)

(defun control-sid-p (sid) (eql sid +control-stream-id+))

(defparameter *video-rungs* '(5 16 48 160 480 1600 4800)
  "The ladder, in kilobits per second — 0.625, 2, 6, 20, 60, 200 and 600 kilobytes per second.")

(defparameter *default-rung* 480
  "The rung a session starts on when nothing in the environment names one.

THE MIDDLE-UPPER RUNG, NOT THE FLOOR.  The default used to be 40 kbps, which on the old ladder was
the rung the measurements identified as barely usable — 4.4 seconds for the first full-size picture
— and every session began by being disappointing and needing a tap.  60 KB/s is the other way
round: it is what an ordinary connection carries without noticing, it never drops resolution (see
SCALE-FOR-MOTION), its first picture is a 134 KB keyframe in 2.2 s, and the two rungs above it are
one tap away for a link that has more to give.  A default is a guess about a link nobody has
measured yet, and the cost of guessing high on a slow link — one tap down — is much cheaper than
the cost of guessing low on a fast one, which is a session that feels broken and says nothing.")

;;; ---- what a rung means -----------------------------------------------------------------------
;;;
;;; Measured on a real 1280x800 desktop capture (a browser on Hacker News), encoded with this
;;; encoder and decoded with ffmpeg.  Three facts set every constant below:
;;;
;;;   1. A KEYFRAME COSTS ~22 KB AND THERE IS NO WAY AROUND IT.  At qi 127 — the coarsest
;;;      quantizer VP8 has — a 1280x800 keyframe is 22116 bytes.  qi 96 is 40 KB, qi 44 is 95 KB.
;;;      So the first picture takes 35 s at 5 kbps and 4.4 s at 40 kbps, and that is the floor.
;;;      Splitting the intra coverage across frames instead measured WORSE (32 KB for the same
;;;      picture) because an inter macroblock cannot use intra prediction and every inter frame
;;;      re-pays its skip flags.  Halving the resolution makes the keyframe 4x cheaper and the text
;;;      illegible, which is not a trade a remote desktop can take.  Hence: full resolution, coarse
;;;      keyframe, refine afterwards.
;;;
;;;   2. EVERY INTER FRAME COSTS ~500 BYTES BEFORE IT CODES ANYTHING.  1280x800 is 4000
;;;      macroblocks and each one spends a skip bit whether it changed or not.  At 5 kbps that is
;;;      most of a second of channel time per frame, so the per-frame cap must not be allowed to
;;;      shrink to where the flags dominate — MAX-FRAME-KB has a floor of 4 KB for that reason,
;;;      even though 4 KB is 6.6 s in flight down there.
;;;
;;;   3. REFINING THE WHOLE SCREEN TO qi Q COSTS ABOUT WHAT A qi-Q KEYFRAME COSTS.  Measured:
;;;      keyframe at 127 then refine to 44 totals 97 KB; the qi-44 keyframe alone is 95 KB.  So the
;;;      base qi is the sharpest whose full-screen refinement fits a sane slice of the rung.
;;; The measured cost of a 1280x800 keyframe, in bytes, against the quantizer index.  This is not a
;;; model — each entry is this encoder's output on a real desktop frame — and it is what makes
;;; KEY-QI a lookup rather than a guess.  Coarsest last; 22116 at qi 127 is the format's floor.
(defparameter *keyframe-cost*
  '((8 . 203137) (16 . 159937) (24 . 134357) (32 . 116227) (44 . 96756) (56 . 81051)
    (63 . 70127) (72 . 59669) (84 . 50012) (96 . 40340) (108 . 31783) (118 . 26147) (127 . 22116))
  "Keyframe bytes at 1280x800 by quantizer index, measured.")

;;; What an inter frame costs BEFORE it codes anything, at 1280x800: 64 bytes of frame header plus
;;; one skip bit for each of 4000 macroblocks.  Same measured-at-this-resolution status as
;;; *KEYFRAME-COST* above, and it is the number that decides how fluid a rung can possibly be —
;;; :TARGET-FPS below is derived from it, and the sender recomputes it from the real frame size and
;;; clamps the rate to what it permits.
(defparameter *inter-overhead-bytes* 564
  "Bytes an inter frame pays per frame at 1280x800 whatever it codes.")

(defparameter *max-target-fps* 12.0
  "The most frames per second we ask for at any rung.  Above this the encoder is the constraint,
not the link — a 1280x800 inter frame is ~37 ms to encode and its motion search another ~23 — and
a target the pipeline cannot meet is only a smaller frame budget for no extra pictures.

AND IT STAYS 12 NOW THAT THE LADDER REACHES 600 KB/s, which is the one number the widening might
have been expected to move.  At 4800 kbps the skip flags would allow 354 fps, so the link has
stopped being the constraint entirely — but the encoder has not: measured over a session's whole
[video] log, whole-screen frames encode in 240-290 ms, and the highest frame rate this pipeline
has ever actually produced is 4.0.  Raising the ask above what it can deliver does not add
pictures, it DIVIDES THE FRAME BUDGET — bps/fps — so each of the four frames a second we really
get would be allotted a third of the bytes and coded coarser for nothing.

So the top of the ladder is not bought in cadence.  It is bought in the FRAME BUDGET (1.7 KB at
160 kbps, 50 KB at 4800: the difference between a frame pinned at the coarsest quantizer it is
allowed and one coded at the finest VP8 has), in the KEYFRAME QUANTIZER, and in never dropping
resolution.  That is the honest account of what the extra rate does here, and it is worth having
written down before someone reads \"12 fps at 600 KB/s\" as a mistake.")

(defun target-fps-for (bps)
  "The cadence a link of BPS bytes/s can hold at 1280x800.  A frame's budget is a second of the
link divided by this, so asking for more than the skip flags leave room for does not buy motion:
at 48 kbps, ten frames a second would be 600-byte frames that are 94% flags.  The floor is one
third of a frame's budget going on overhead, which is where these numbers come from — 0.4 fps at
5 kbps, 1.2 at 16, 3.5 at 48, 11.8 at 160 — and below 160 kbps this, not the bitrate, is what caps
how fluid a scroll can look at this resolution.  At and above 160 kbps *MAX-TARGET-FPS* binds
instead, for the reason recorded there."
  (min *max-target-fps* (/ bps (* 3.0 *inter-overhead-bytes*))))

(defun keyframe-qi-for (budget-bytes)
  "The FINEST quantizer whose keyframe fits BUDGET-BYTES — the sharpest first picture this rung can
afford.  Falls back to 127 when nothing fits, because a slow first picture is still a picture."
  (or (car (find-if (lambda (e) (<= (cdr e) budget-bytes)) *keyframe-cost*)) 127))

(defun rung-settings (kbps)
  "Every encoder knob for a rung, derived from KBPS alone."
  (let* ((bps (* kbps 125))                       ; kilobits/s -> bytes/s
         (target-kbs (/ bps 1024.0))              ; the encoder's unit is kiloBYTES/s
         ;; the sharpest quantizer whose whole-screen refinement fits ~15 s of this rung's budget.
         ;; Refinement costs about what a keyframe at the same quantizer costs (measured), so this
         ;; is the same lookup against a bigger budget.
         (qi (keyframe-qi-for (* 15 bps)))
         ;; the keyframe: the sharpest that lands in ~2.5 s of budget, and never sharper than the
         ;; stream's own quality — coarse and whole beats sharp and half-drawn
         (key-qi (max qi (keyframe-qi-for (round (* 2.5 bps))))))
    (list :kbps kbps
          :target-kbs target-kbs
          :qi qi
          :key-qi key-qi
          ;; how coarse we are willing to get under load, and the coverage-beats-sharpness lever
          :max-qi (min 127 (+ qi 44))
          :backlog-qi (min 127 (+ qi 40))
          ;; A FRAME MAY NOT EXCEED ~1.5 s OF THE LINK'S BUDGET.  This used to be a fixed 32-128 KB,
          ;; which at 5 kbps is 51 s in flight — the cap has to come from the rate or it is not a
          ;; cap at all.  Floored at 4 KB so per-frame skip-flag overhead stays under a sixth.
          :max-frame-kb (max 4.0 (/ (* bps 1.5) 1024.0))
          ;; THE CADENCE, and it is what makes a rung buy MOTION rather than only sharpness.  A
          ;; live frame's budget is a second of the link divided by this; sized in link-seconds
          ;; instead, a frame is the same number of SECONDS at every rung, so the whole of a rate
          ;; increase went into making one frame per two seconds prettier.
          :target-fps (target-fps-for bps)
          ;; how long the screen must be quiet before we spend the link sharpening it.  Refinement
          ;; is expensive; down the ladder it must not start while the last change is still flying.
          :cleanup-ms (min 8000 (max 400 (round 32000 kbps)))
          ;; THE PERIODIC RESYNC, AS A FRACTION OF THE LINK RATHER THAN A FIXED PERIOD.  We parse no
          ;; RTCP — no PLI, no receiver reports — so a viewer that missed the first keyframe has no
          ;; way to tell us except over the control channel, and one that has not connected it has
          ;; no way at all.  So the blind timer STAYS, as a genuine last resort.  What changes is
          ;; its price: it used to fire every 3 s for the first 30 s of a session, which at 40 kbps
          ;; is 16 s of channel time per 3 s of wall clock — permanent saturation — and at 5 kbps
          ;; the session never produced a first image at all.  Here it is allowed 8% of the link,
          ;; so it is 30 s from 160 kbps up and ~7 minutes at the bottom.
          ;;
          ;; PRICED AT THE KEYFRAME WE WILL ACTUALLY SEND, which is the one thing the widening
          ;; changed here.  This used to divide the qi-127 floor (22116 bytes) by the rate whatever
          ;; KEY-QI said, and that was true while every affordable keyframe was the coarsest one.
          ;; Above 480 kbps KEY-QI reaches 8 and its keyframe is 203 KB — nine times the number
          ;; being divided — so the "8% of the link" the comment promises was no longer what the
          ;; arithmetic computed.  It costs nothing to state it correctly: on this ladder every
          ;; rung that is not already at the 30 s floor has KEY-QI 127 and the answer is unchanged.
          :key-secs (max 30.0 (/ (float (or (cdr (assoc key-qi *keyframe-cost*)) 22116) 1.0)
                                 (* 0.08 bps))))))

(defun rung-index (kbps) (position kbps *video-rungs*))

(defun nearest-rung (kbps)
  "The rung closest to KBPS — so a stale client, or an env holding an old KB/s number, still lands
somewhere sensible instead of being rejected."
  (let ((k (or kbps 0)))
    (first (sort (copy-list *video-rungs*) #'< :key (lambda (r) (abs (- r k)))))))

(defvar *video-kbps* nil "The rung now in force, in kbps, or NIL until the environment is read.")

(defun %env-int (name)
  (ignore-errors (parse-integer (uiop:getenv name))))

(defun detect-video-rung ()
  "The rung the gateway was STARTED on.  VIDEO_KBPS is the knob; the old VIDEO_TARGET_KBS (in
kiloBYTES) is still honoured so an un-updated env file lands on the nearest rung, not on nothing."
  (or (let ((k (%env-int "VIDEO_KBPS"))) (and k (nearest-rung k)))
      (let ((kb (%env-int "VIDEO_TARGET_KBS"))) (and kb (nearest-rung (round (* kb 8.192)))))
      *default-rung*))

(defun apply-video-rung (kbps &key (why "control channel"))
  "Move the RUNNING video sender to the KBPS rung.  Returns the settings plist, or NIL if KBPS is
not on the ladder.  Setting webrtc-media:*VIDEO-PROFILE* is most of the mechanism — the sender
re-reads it at the top of every pass — plus the backlog quantizer, which lives in the encoder."
  (when (member kbps *video-rungs*)
    (let ((p (rung-settings kbps)))
      (setf webrtc-media.vp8::*backlog-qi* (getf p :backlog-qi)
            webrtc-media:*video-profile* (list* :name (format nil "~a kbps" kbps) p)
            *video-kbps* kbps)
      ;; The rung's OWN unit first — kbps/8 kilobytes per second, which is what the ladder is named
      ;; in and what a person asked for — then the kibibyte figure the encoder is actually handed.
      ;; Printing only the second made a rung called 600 KB/s log itself as 585.94 and read as a bug.
      (format *error-output* "~&[rung] ~a kbps = ~,1f KB/s (~a) — ~,2f KiB/s to the encoder, ~,1f fps (~a B/frame), qi ~a/~a, keyframe qi ~a, frame<=~,1f KiB, settle ~a ms, resync ~a s, backlog qi ~a~%"
              kbps (/ kbps 8.0) why (getf p :target-kbs) (getf p :target-fps)
              (round (* (getf p :target-kbs) 1024) (getf p :target-fps))
              (getf p :qi) (getf p :max-qi) (getf p :key-qi)
              (getf p :max-frame-kb) (getf p :cleanup-ms) (round (getf p :key-secs))
              (getf p :backlog-qi))
      (finish-output *error-output*)
      p)))

(defun video-profile-status ()
  "The current state, as the JSON the phone paints its stepper from."
  (let* ((kbps (or *video-kbps* (setf *video-kbps* (detect-video-rung))))
         (p (rung-settings kbps)))
    ;; ~,0f would emit "55." — a trailing point with no digits, which is not JSON and takes the
    ;; phone's whole status handler down with it.  Every number here is rounded to an integer or
    ;; given explicit decimals.
    (format nil "{\"kbps\":~a,\"rung\":~a,\"profile\":\"~a kbps\",\"target_kbs\":~,2f,\"target_fps\":~,1f,\"frame_budget\":~a,\"max_frame_kb\":~,1f,\"cleanup_ms\":~a,\"qi\":~a,\"max_qi\":~a,\"key_qi\":~a,\"key_secs\":~a,\"backlog_qi\":~a,\"rungs\":[~{~a~^,~}]}"
            kbps (or (rung-index kbps) 0) kbps
            (getf p :target-kbs) (getf p :target-fps)
            (round (* (getf p :target-kbs) 1024) (getf p :target-fps))
            (getf p :max-frame-kb) (getf p :cleanup-ms)
            (getf p :qi) (getf p :max-qi) (getf p :key-qi) (round (getf p :key-secs))
            (getf p :backlog-qi) *video-rungs*)))

(defun %json-string-value (json key)
  "The string value of KEY in a flat JSON object, without a JSON parser: these messages are two
fields long and generated by a client we ship."
  (let ((at (search (format nil "\"~a\"" key) json)))
    (when at
      (let* ((colon (position #\: json :start (+ at (length key) 2)))
             (open (and colon (position #\" json :start (1+ colon))))
             (close (and open (position #\" json :start (1+ open)))))
        (when close (subseq json (1+ open) close))))))

(defun %json-number-value (json key)
  "The unquoted integer value of KEY in a flat JSON object.  Same reasoning as the string case: the
messages are ours, two fields long, and a parser would be the larger thing to trust."
  (let ((at (search (format nil "\"~a\"" key) json)))
    (when at
      (let ((colon (position #\: json :start (+ at (length key) 2))))
        (when colon
          (let* ((start (position-if #'digit-char-p json :start (1+ colon)))
                 (end (and start (or (position-if-not #'digit-char-p json :start start)
                                     (length json)))))
            (when start (parse-integer json :start start :end end :junk-allowed t))))))))

(defun handle-control-message (assoc sid payload)
  "One JSON message from the phone on the control channel.  Always answers with the current state,
so the phone's stepper shows what the box actually did rather than what was asked for."
  (let ((json (if (stringp payload) payload (map 'string #'code-char (as-u8vec payload)))))
    (let ((want (%json-number-value json "kbps")))
      (when want
        (unless (apply-video-rung want)
          (format *error-output* "~&[rung] ignoring off-ladder rate ~a kbps~%" want))))
    ;; "keyframe": the viewer knows its decoder is stranded and we do not.  We parse no RTCP, so
    ;; there is no PLI to hear — this channel is the ONLY way a viewer can ask, which is exactly why
    ;; the blind periodic resync above cannot be removed outright, only made affordable.  iOS
    ;; suspends a backgrounded tab, so the phone misses every frame while it is away and comes back
    ;; holding a reference the encoder has long since predicted past.
    (let ((req (%json-string-value json "request")))
      (when (equal req "keyframe")
        (setf webrtc-media:*force-keyframe* t)
        (format *error-output* "~&[video] keyframe requested by the viewer~%")
        (finish-output *error-output*)))
    (ignore-errors (sctp-send-string assoc sid (video-profile-status)))))

;; Adopt the environment at load time: the sender then starts on exactly the rung the keepalive
;; printed, and the phone sees the matching step already highlighted.  This happens before any
;; session exists, which is why the sender adopts *VIDEO-PROFILE* at the TOP of its loop — the first
;; keyframe is the most expensive frame of the session and it has to be coded at the rung's numbers.
(apply-video-rung (detect-video-rung) :why "startup")
