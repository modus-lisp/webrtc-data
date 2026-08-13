;;;; glass-capture.lisp — an RFB client that keeps a live YUV mirror of the glass desktop.
;;;;
;;;; This is the source for the VP8 video path.  It opens its OWN connection to glass (separate
;;;; from the one bridged to the browser), asks for Raw incremental updates, and maintains Y/U/V
;;;; 4:2:0 planes.  Only the rectangles glass reports as changed are converted, so a static
;;;; desktop costs almost nothing, and a DIRTY flag tells the encoder when a new frame is worth
;;;; sending at all.

(in-package #:webrtc-data)

(defstruct (capture (:conc-name cap-))
  socket width height cw ch y u v
  host port (n-reconnect 0)                    ; for the supervisor
  (t-wait 0d0) (t-conv 0d0) (n-upd 0) (px 0) (n-copy 0)   ; capture-side timing
  mb-cols mb-rows dirty-mbs                    ; per-macroblock dirty flags, straight from RFB
  ;; ---- the scaled mirror (see CAPTURE-TAKE) ----
  ;; The planes above are always the desktop at ITS OWN size; these are a box-filtered copy of them
  ;; at 1/SCALE, rebuilt only where the full-res planes were reported dirty.  NIL until a caller
  ;; first asks for a scale other than 1.
  (scale 1) s-y s-u s-v (n-scaled 0)
  (dirty nil) (lock (bt:make-lock)) (stop nil) thread)   ; dirty only after a real update

(defun %rd (stream n)
  (let ((buf (make-array n :element-type '(unsigned-byte 8))) (got 0))
    (loop while (< got n)
          do (let ((r (read-sequence buf stream :start got)))
               (when (<= r got) (error "rfb: short read"))
               (setf got r)))
    buf))

(defun %be16 (b i) (logior (ash (aref b i) 8) (aref b (1+ i))))
(defun %be32 (b i) (let ((v 0)) (dotimes (k 4 v) (setf v (logior (ash v 8) (aref b (+ i k)))))))
(defun %s32 (v) (if (>= v #x80000000) (- v #x100000000) v))   ; encodings are SIGNED
(defconstant +rfb-last-rect+ -224)                            ; "no more rects in this update"

(defun capture-connect (host port)
  "RFB handshake with glass; returns a CAPTURE with allocated planes (native 32bpp, Raw).

HOST is the endpoint in either form — a hostname beside PORT, or `unix:/…/seat-0.rfb' for a
socket file.  This is the SECOND RFB client this gateway opens onto the desktop (the browser's
bridged connection is the other), and it is the one that has to keep working when the desktop
stops being reachable over a port: the capture feeds the only picture the viewer has."
  (multiple-value-bind (sock s) (glass:open-connection :host host :port port)
    ;; The CAPTURE keeps the stream; the socket object is the stream's, and closing the stream
    ;; is what %CAPTURE-RECONNECT has always done.
    (declare (ignorable sock))
    (progn
      (%rd s 12)                                            ; ProtocolVersion
      (write-sequence (map '(vector (unsigned-byte 8)) #'char-code "RFB 003.008
") s)
      (finish-output s)
      (let ((n (aref (%rd s 1) 0)))                         ; security types
        (%rd s n)
        (write-sequence (vector 1) s) (finish-output s)     ; None
        (%rd s 4))                                          ; SecurityResult
      (write-sequence (vector 1) s) (finish-output s)       ; ClientInit shared
      (let* ((hdr (%rd s 4)) (w (%be16 hdr 0)) (h (%be16 hdr 2)))
        (%rd s 16)                                          ; server pixel format
        (%rd s (%be32 (%rd s 4) 0))                         ; desktop name
        ;; native 32bpp BGRX, Raw only
        (write-sequence (concatenate '(vector (unsigned-byte 8))
                                     (vector 0 0 0 0 32 24 0 1 0 255 0 255 0 255 16 8 0 0 0 0)) s)
        ;; SetEncodings: CopyRect (1) then Raw (0).  glass emits CopyRect when a window MOVES,
        ;; which costs 4 bytes on the wire instead of repainting the region.
        (write-sequence (concatenate '(vector (unsigned-byte 8))
                                     (vector 2 0 0 2  0 0 0 1  0 0 0 0)) s)
        (finish-output s)
        (let* ((cw (ceiling w 2)) (ch (ceiling h 2))
               (mc (ceiling w 16)) (mr (ceiling h 16))
               (c (make-capture :socket s :width w :height h :cw cw :ch ch :host host :port port
                                :mb-cols mc :mb-rows mr
                                :dirty-mbs (make-array (* mc mr) :element-type 'bit :initial-element 1)
                                :y (make-array (* w h) :element-type '(unsigned-byte 8) :initial-element 16)
                                :u (make-array (* cw ch) :element-type '(unsigned-byte 8) :initial-element 128)
                                :v (make-array (* cw ch) :element-type '(unsigned-byte 8) :initial-element 128))))
          c)))))

(defun %request-update (c incremental)
  (let ((s (cap-socket c)))
    (write-sequence (vector 3 (if incremental 1 0)
                            0 0 0 0
                            (ldb (byte 8 8) (cap-width c)) (ldb (byte 8 0) (cap-width c))
                            (ldb (byte 8 8) (cap-height c)) (ldb (byte 8 0) (cap-height c))) s)
    (finish-output s)))

(defun %mark-dirty (c rx ry rw rh)
  "Flag the macroblocks this update rectangle touches.  glass already knows what changed, so the
encoder never has to rediscover it by comparing the whole screen."
  (let ((d (cap-dirty-mbs c)) (mc (cap-mb-cols c)) (mr (cap-mb-rows c)))
    (loop for my from (floor ry 16) to (min (1- mr) (floor (+ ry rh -1) 16)) do
      (loop for mx from (floor rx 16) to (min (1- mc) (floor (+ rx rw -1) 16)) do
        (when (and (>= my 0) (>= mx 0)) (setf (aref d (+ (* my mc) mx)) 1))))))

(defun %copy-region (plane stride dx dy sx sy w h)
  "Move a W x H region from (SX,SY) to (DX,DY) within PLANE.  Row order is chosen so overlapping
moves (the common case when a window slides) don't clobber their own source."
  (declare (type (simple-array (unsigned-byte 8) (*)) plane)
           (type fixnum stride dx dy sx sy w h) (optimize (speed 3) (safety 0)))
  (if (< dy sy)
      (dotimes (r h)                                     ; moving up: copy top-down
        (replace plane plane :start1 (+ (* (+ dy r) stride) dx)
                             :end1 (+ (* (+ dy r) stride) dx w)
                             :start2 (+ (* (+ sy r) stride) sx)))
      (loop for r from (1- h) downto 0 do                ; moving down: copy bottom-up
        (replace plane plane :start1 (+ (* (+ dy r) stride) dx)
                             :end1 (+ (* (+ dy r) stride) dx w)
                             :start2 (+ (* (+ sy r) stride) sx)))))

(defun %apply-copyrect (c dx dy w h sx sy)
  "Apply an RFB CopyRect to the Y/U/V planes.  Chroma is 4:2:0, so its coordinates halve — only
exact even offsets stay aligned, which is what a window move gives us."
  (%copy-region (cap-y c) (cap-width c) dx dy sx sy w h)
  (let ((cw (cap-cw c)))
    (%copy-region (cap-u c) cw (floor dx 2) (floor dy 2) (floor sx 2) (floor sy 2)
                  (floor w 2) (floor h 2))
    (%copy-region (cap-v c) cw (floor dx 2) (floor dy 2) (floor sx 2) (floor sy 2)
                  (floor w 2) (floor h 2))))

(defun %apply-rect (c rx ry rw rh data)
  "Convert one BGRX rectangle into the Y/U/V planes (BT.601, 4:2:0).
Typed throughout: this runs per PIXEL over every changed rectangle (millions per second on an
active desktop), and on generic arithmetic it was costing ~14% of wall-clock."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum rx ry rw rh)
           (optimize (speed 3) (safety 0)))
  (let ((y (the (simple-array (unsigned-byte 8) (*)) (cap-y c)))
        (u (the (simple-array (unsigned-byte 8) (*)) (cap-u c)))
        (v (the (simple-array (unsigned-byte 8) (*)) (cap-v c)))
        (w (the fixnum (cap-width c))) (cw (the fixnum (cap-cw c))))
    ;; luma, every pixel
    (dotimes (row rh)
      (let ((base (the fixnum (* row rw 4))) (out (the fixnum (* (+ ry row) w))))
        (dotimes (col rw)
          (let* ((o (+ base (* col 4)))
                 (b (aref data o)) (g (aref data (+ o 1))) (r (aref data (+ o 2))))
            (setf (aref y (+ out rx col))
                  (min 255 (ash (+ (* 77 r) (* 150 g) (* 29 b)) -8)))))))
    ;; chroma, one sample per 2x2 (align to the even grid so blocks line up)
    (let ((x0 (logandc2 rx 1)) (y0 (logandc2 ry 1)))
      (loop for py from y0 below (min (cap-height c) (+ ry rh)) by 2 do
        (loop for px from x0 below (min w (+ rx rw)) by 2 do
          (let ((rs 0) (gs 0) (bs 0) (n 0))
            (dotimes (dy 2)
              (dotimes (dx 2)
                (let ((sx (- (+ px dx) rx)) (sy (- (+ py dy) ry)))
                  (when (and (>= sx 0) (< sx rw) (>= sy 0) (< sy rh))
                    (let ((o (+ (* sy rw 4) (* sx 4))))
                      (incf bs (aref data o)) (incf gs (aref data (+ o 1)))
                      (incf rs (aref data (+ o 2))) (incf n))))))
            (when (plusp n)
              (let* ((r (floor rs n)) (g (floor gs n)) (b (floor bs n))
                     (ci (+ (* (floor py 2) cw) (floor px 2))))
                (setf (aref u ci) (max 0 (min 255 (+ 128 (floor (+ (* -43 r) (* -85 g) (* 128 b)) 256))))
                      (aref v ci) (max 0 (min 255 (+ 128 (floor (+ (* 128 r) (* -107 g) (* -21 b)) 256)))))))))))))

(defun capture-run (c)
  "Read framebuffer updates forever, applying them to the planes and marking DIRTY."
  (let ((s (cap-socket c)))
    (%request-update c nil)                                  ; full frame first
    (loop until (cap-stop c) do
      (let* ((tw (get-internal-real-time))
             (msg (aref (%rd s 1) 0)))
        (incf (cap-t-wait c) (/ (* 1000d0 (- (get-internal-real-time) tw))
                                internal-time-units-per-second))
        (case msg
          (0 (%rd s 1)
             ;; Read the whole update off the socket BEFORE taking the lock.  Holding it across
             ;; blocking reads meant capture-take (and therefore the encoder) stalled behind
             ;; glass's network I/O, which showed up as a delivered frame rate far below the
             ;; update rate.  The lock now covers only the (fast, typed) plane writes.
             (let ((n (%be16 (%rd s 2) 0)) (rects '()) (tc 0))
               (dotimes (i n)
                 (let* ((h (%rd s 12)) (rx (%be16 h 0)) (ry (%be16 h 2))
                        (rw (%be16 h 4)) (rh (%be16 h 6)) (enc (%be32 h 8)))
                   (let ((e (%s32 enc)))
                     ;; sanity-check geometry first: %apply-rect runs with (safety 0), so an
                     ;; out-of-range rect would scribble past the planes instead of erroring.
                     ;; Out of range means desync or a resize — either way, resynchronise.
                     (when (and (member e '(0 1))
                                (or (> (+ rx rw) (cap-width c)) (> (+ ry rh) (cap-height c))))
                       (error "capture: rect ~ax~a+~a+~a outside ~ax~a — desync or resize"
                              rw rh rx ry (cap-width c) (cap-height c)))
                     (cond
                       ((= e 0) (push (list :raw rx ry rw rh (%rd s (* rw rh 4))) rects))
                       ((= e 1) (let ((cp (%rd s 4)))
                                  (push (list :copy rx ry rw rh (%be16 cp 0) (%be16 cp 2)) rects)))
                       ((= e +rfb-last-rect+) (return))       ; carries no data; update ends here
                       ;; An encoding we did not ask for means we can no longer know how many
                       ;; bytes it occupies, so the stream is unparseable from here.  Signal, and
                       ;; let the supervisor reconnect — one strange rect must not end the video.
                       (t (error "capture: unexpected encoding ~a (~a)" e enc))))))
               (setf tc (get-internal-real-time))
               (bt:with-lock-held ((cap-lock c))
                 (dolist (r (nreverse rects))
                   (destructuring-bind (kind rx ry rw rh a &optional b) r
                     (ecase kind
                       (:raw (incf (cap-px c) (* rw rh)) (%apply-rect c rx ry rw rh a))
                       (:copy (incf (cap-n-copy c)) (%apply-copyrect c rx ry rw rh a b)))
                     (%mark-dirty c rx ry rw rh)))
                 (setf (cap-dirty c) t)
                 (incf (cap-n-upd c))
                 (incf (cap-t-conv c) (/ (* 1000d0 (- (get-internal-real-time) tc))
                                         internal-time-units-per-second))))
             (%request-update c t))                          ; ask for the next incremental
          (1 (%rd s 5))                                      ; SetColourMapEntries (ignored)
          (2 nil)                                            ; Bell
          (3 (let* ((h (%rd s 7)) (len (%be32 h 3))) (%rd s len)))   ; ServerCutText
          (t (error "capture: unknown server message ~a" msg)))))))

(defun capture-stats (c)
  "Capture-side timing since the last call: how long glass kept us waiting for an update, and how
long converting its rectangles to YUV took.  Resets the counters."
  (prog1 (list :updates (cap-n-upd c) :wait-ms (cap-t-wait c) :convert-ms (cap-t-conv c)
               :px (cap-px c) :copies (cap-n-copy c) :reconnects (cap-n-reconnect c)
               ;; which resolution the encoder is being handed, and how many times we downscaled
               :scale (cap-scale c) :scaled (cap-n-scaled c))
    (setf (cap-n-upd c) 0 (cap-t-wait c) 0d0 (cap-t-conv c) 0d0 (cap-px c) 0 (cap-n-copy c) 0
          (cap-n-scaled c) 0)))

(defun %capture-reconnect (c)
  "Re-handshake with glass on a fresh socket and force a full refresh.  The framebuffer planes are
kept, but every macroblock is marked dirty so the viewer converges again from whatever it had."
  (ignore-errors (close (cap-socket c)))
  (let ((fresh (capture-connect (cap-host c) (cap-port c))))
    (bt:with-lock-held ((cap-lock c))
      (setf (cap-socket c) (cap-socket fresh))
      ;; the desktop may have resized while we were away — adopt the new geometry and planes
      (unless (and (= (cap-width fresh) (cap-width c)) (= (cap-height fresh) (cap-height c)))
        (format *error-output* "~&[capture] desktop resized ~ax~a -> ~ax~a~%"
                (cap-width c) (cap-height c) (cap-width fresh) (cap-height fresh))
        (setf (cap-width c) (cap-width fresh) (cap-height c) (cap-height fresh)
              (cap-cw c) (cap-cw fresh) (cap-ch c) (cap-ch fresh)
              (cap-mb-cols c) (cap-mb-cols fresh) (cap-mb-rows c) (cap-mb-rows fresh)
              (cap-y c) (cap-y fresh) (cap-u c) (cap-u fresh) (cap-v c) (cap-v fresh)
              (cap-dirty-mbs c) (cap-dirty-mbs fresh)))
      (fill (cap-dirty-mbs c) 1)
      (setf (cap-dirty c) t))
    (incf (cap-n-reconnect c))))

(defun capture-start (host port)
  "Connect + run the capture loop under a supervisor.  A parse desync or a dropped socket
RECONNECTS rather than ending the video: the capture feeds the only picture the viewer has, so
losing this thread freezes the screen with no way back.  Returns the CAPTURE."
  (let ((c (capture-connect host port)))
    (setf (cap-thread c)
          (bt:make-thread
           (lambda ()
             (loop until (cap-stop c) do
               (handler-case (capture-run c)
                 (error (e)
                   (when (cap-stop c) (return))
                   (format *error-output* "~&[capture] ~a — reconnecting~%" e)
                   (finish-output *error-output*)
                   (sleep 0.25)
                   (handler-case (%capture-reconnect c)
                     (error (e2) (format *error-output* "~&[capture] reconnect failed: ~a~%" e2)
                       (sleep 1.0)))))))
           :name "glass-capture"))
    c))

(defun capture-stop (c)
  (setf (cap-stop c) t)
  (ignore-errors (close (cap-socket c))))

;;; ---- the scaled mirror -------------------------------------------------------------------------
;;;
;;; VP8's frame size is a property of the FRAME, so a picture is entirely one resolution — there is
;;; no way to code a quarter-size region inside a full-size frame.  What the sender can do is decide
;;; per frame, and it decides on DAMAGE: local damage stays full size and codes a handful of
;;; macroblocks (dropping resolution there would throw away detail the viewer already holds, and
;;; charge a keyframe for the privilege), while damage that is genuinely global has no detail left
;;; to protect and is four to sixteen times cheaper one or two rungs down.
;;;
;;; So this file offers the desktop at 1/1, 1/2 or 1/4, and the choice is the caller's.
;;;
;;; TWO THINGS MAKE IT WORTH DOING AND BOTH ARE MACROBLOCK COUNTS, NOT BITRATES.  A keyframe is
;;; ~5.5 bytes per macroblock at the coarsest quantizer VP8 has, so a 1280x800 one is 22 KB however
;;; slow the link is; quartering the macroblocks quarters that.  And every inter frame spends a skip
;;; bit per macroblock whether it codes anything or not.  A third thing falls out for free: VP8's
;;; motion vectors reach +-255 pixels, so a scroll that displaces 400 px between two delivered
;;; frames has NO vector at full size and a 100 px one at quarter size — inside the search range,
;;; where it costs a mode bit instead of a whole new picture.
;;;
;;; BOX-AVERAGE, NOT POINT-SAMPLE.  Dropping every other pixel of a text rendering aliases the
;;; stems into and out of existence; averaging the block leaves grey where the glyph was, which
;;; both reads better and — because it is smooth — costs the encoder less.
;;;
;;; DAMAGE MAPS EXACTLY, WHICH IS WHY THE BLOCK SIZE IS A MACROBLOCK.  A full-res macroblock is
;;; 16 px, so at scale S it becomes a 16/S px square at (16/S)*(mbx,mby) — integer aligned for
;;; S in {1,2,4} — and its scaled MACROBLOCK is (floor mbx S), (floor mby S).  Rescaling exactly the
;;; macroblocks RFB reported dirty therefore leaves the rest of the mirror alone, and the dirty set
;;; the caller gets back is the same damage stated in the smaller grid.

(defparameter *capture-scales* '(1 2 4)
  "The resolution divisors CAPTURE-TAKE will produce.  Integers only, and only powers of two: a
macroblock (16 px luma, 8 px chroma) has to divide into whole scaled pixels or damage stops
mapping onto macroblock boundaries and the encoder is told the wrong thing changed.")

(defun scaled-dims (w h scale)
  "The (values sw sh cw ch) a SCALE-divided mirror of a W x H desktop has.  Rounded DOWN to an even
number of pixels so 4:2:0 chroma stays a whole sample."
  (if (= scale 1)
      (values w h (ceiling w 2) (ceiling h 2))
      (let ((sw (logandc2 (floor w scale) 1)) (sh (logandc2 (floor h scale) 1)))
        (values sw sh (ceiling sw 2) (ceiling sh 2)))))

(defun %box-2 (src sw dst dw sx sy n)
  "Box-average by 2, with no clamping: the caller has established the block lies wholly inside both
planes.  This is the hot path — a scroll rescales the whole screen on every capture — and the
bounds test hoisted out of the inner loop is most of its cost."
  (declare (type (simple-array (unsigned-byte 8) (*)) src dst)
           (type fixnum sw dw sx sy n) (optimize (speed 3) (safety 0)))
  (let ((dx0 (ash sx -1)) (dy0 (ash sy -1)))
    (declare (type fixnum dx0 dy0))
    (dotimes (r n)
      (let ((r0 (* sw (+ sy (ash r 1)))) (r1 (* sw (+ sy (ash r 1) 1)))
            (d (+ (* dw (+ dy0 r)) dx0)))
        (declare (type fixnum r0 r1 d))
        (dotimes (col n)
          (let ((a (+ sx (ash col 1))))
            (declare (type fixnum a))
            (setf (aref dst (+ d col))
                  (ash (+ (aref src (+ r0 a)) (aref src (+ r0 a 1))
                          (aref src (+ r1 a)) (aref src (+ r1 a 1)))
                       -2))))))))

(defun %box-4 (src sw dst dw sx sy n)
  "Box-average by 4, unclamped.  See %BOX-2."
  (declare (type (simple-array (unsigned-byte 8) (*)) src dst)
           (type fixnum sw dw sx sy n) (optimize (speed 3) (safety 0)))
  (let ((dx0 (ash sx -2)) (dy0 (ash sy -2)))
    (declare (type fixnum dx0 dy0))
    (dotimes (r n)
      (let ((d (+ (* dw (+ dy0 r)) dx0)) (y0 (+ sy (ash r 2))))
        (declare (type fixnum d y0))
        (dotimes (col n)
          (let ((a (+ sx (ash col 2))) (sum 0))
            (declare (type fixnum a sum))
            (dotimes (ky 4)
              (let ((ro (+ (* sw (+ y0 ky)) a)))
                (declare (type fixnum ro))
                (incf sum (+ (aref src ro) (aref src (+ ro 1))
                             (aref src (+ ro 2)) (aref src (+ ro 3))))))
            (setf (aref dst (+ d col)) (ash sum -4))))))))

(defun %box-down (src sw sh dst dw dh sx sy n scale)
  "Box-average the (N*SCALE) square of SRC at (SX,SY) into the N square of DST at (SX/SCALE,SY/SCALE).
Source reads are clamped to the plane, destination writes outside it are dropped, so a desktop whose
size is not a multiple of the scale loses its last column rather than corrupting memory."
  (declare (type (simple-array (unsigned-byte 8) (*)) src dst)
           (type fixnum sw sh dw dh sx sy n scale)
           (optimize (speed 3) (safety 0)))
  ;; wholly inside both planes — the overwhelmingly common case, and the only one worth typing
  (when (and (<= (+ sx (* n scale)) sw) (<= (+ sy (* n scale)) sh)
             (<= (+ (floor sx scale) n) dw) (<= (+ (floor sy scale) n) dh))
    (case scale
      (2 (return-from %box-down (%box-2 src sw dst dw sx sy n)))
      (4 (return-from %box-down (%box-4 src sw dst dw sx sy n)))))
  (let ((dx0 (floor sx scale)) (dy0 (floor sy scale)) (area (* scale scale)))
    (declare (type fixnum dx0 dy0 area))
    (dotimes (r n)
      (let ((dy (+ dy0 r)))
        (when (< dy dh)
          (let ((drow (* dy dw)))
            (dotimes (col n)
              (let ((dx (+ dx0 col)))
                (when (< dx dw)
                  (let ((sum 0))
                    (declare (type fixnum sum))
                    (dotimes (ky scale)
                      (let ((py (min (1- sh) (+ sy (* r scale) ky))))
                        (declare (type fixnum py))
                        (let ((srow (* py sw)))
                          (dotimes (kx scale)
                            (incf sum (aref src (+ srow (min (1- sw)
                                                             (the fixnum
                                                                  (+ sx (* col scale) kx))))))))))
                    (setf (aref dst (+ drow dx)) (the (unsigned-byte 8) (floor sum area)))))))))))))

(defun %ensure-scaled (c scale)
  "Allocate (or reallocate) the scaled mirror for SCALE.  Returns T if it had to be built from
scratch, in which case every macroblock has to be rescaled rather than only the dirty ones."
  (multiple-value-bind (sw sh cw ch) (scaled-dims (cap-width c) (cap-height c) scale)
    (let ((ny (* sw sh)) (nc (* cw ch)))
      (if (and (cap-s-y c) (= scale (cap-scale c))
               (= ny (length (the (simple-array (unsigned-byte 8) (*)) (cap-s-y c))))
               (= nc (length (the (simple-array (unsigned-byte 8) (*)) (cap-s-u c)))))
          nil
          (progn
            (setf (cap-scale c) scale
                  (cap-s-y c) (make-array ny :element-type '(unsigned-byte 8) :initial-element 16)
                  (cap-s-u c) (make-array nc :element-type '(unsigned-byte 8) :initial-element 128)
                  (cap-s-v c) (make-array nc :element-type '(unsigned-byte 8) :initial-element 128))
            t)))))

(defun %rescale-mbs (c scale bits)
  "Rebuild the scaled mirror over every macroblock flagged in BITS (a full-res dirty set)."
  (%ensure-scaled c scale)                    ; %BOX-DOWN runs at (safety 0); never hand it a NIL
  (multiple-value-bind (sw sh cw ch) (scaled-dims (cap-width c) (cap-height c) scale)
    (let ((mc (cap-mb-cols c)) (mr (cap-mb-rows c))
          (fw (cap-width c)) (fh (cap-height c))
          (fcw (cap-cw c)) (fch (cap-ch c))
          (ln (floor 16 scale)) (cn (floor 8 scale)))
      (dotimes (my mr)
        (dotimes (mx mc)
          (when (= 1 (aref bits (+ (* my mc) mx)))
            (%box-down (cap-y c) fw fh (cap-s-y c) sw sh (* 16 mx) (* 16 my) ln scale)
            (%box-down (cap-u c) fcw fch (cap-s-u c) cw ch (* 8 mx) (* 8 my) cn scale)
            (%box-down (cap-v c) fcw fch (cap-s-v c) cw ch (* 8 mx) (* 8 my) cn scale))))
      (incf (cap-n-scaled c))
      (values sw sh))))

(defun %scale-dirty (c scale bits)
  "BITS, a full-res macroblock damage set, restated on the scaled macroblock grid: a scaled
macroblock is dirty when ANY of the SCALE x SCALE full-res macroblocks inside it is."
  (multiple-value-bind (sw sh) (scaled-dims (cap-width c) (cap-height c) scale)
    (let* ((mc (cap-mb-cols c)) (mr (cap-mb-rows c))
           (smc (ceiling sw 16)) (smr (ceiling sh 16))
           (out (make-array (* smc smr) :element-type 'bit :initial-element 0)))
      (dotimes (my mr out)
        (dotimes (mx mc)
          (when (= 1 (aref bits (+ (* my mc) mx)))
            ;; (16/SCALE)*mx is where this macroblock's pixels land, so its scaled macroblock is
            ;; that divided by 16 — i.e. (floor mx SCALE).  Clamped because the scaled plane is
            ;; rounded down and the last full-res macroblock may fall off the edge.
            (let ((sx (min (1- smc) (floor mx scale))) (sy (min (1- smr) (floor my scale))))
              (setf (aref out (+ (* sy smc) sx)) 1))))))))

(defun capture-take (c &key (scale 1))
  "If the desktop changed since the last call, return (values Y U V w h dirty-mbs); else NIL.
DIRTY-MBS flags exactly the macroblocks glass reported as updated, so the encoder can go straight
to them instead of scanning the screen.

SCALE, one of *CAPTURE-SCALES*, asks for the desktop box-filtered down by that factor — see the
commentary above.  A CHANGE of scale always produces a frame, dirty or not, and that frame reports
the whole screen as damaged: the caller has asked for a picture it does not have at all, and VP8
will have to send a keyframe for it regardless."
  (bt:with-lock-held ((cap-lock c))
    (let ((scale (if (member scale *capture-scales*) scale 1)))
      (if (= scale 1)
          ;; the unscaled path is exactly what it always was, allocation and all
          (when (or (cap-dirty c) (/= 1 (cap-scale c)))
            (let ((fresh (/= 1 (cap-scale c))))
              (setf (cap-dirty c) nil (cap-scale c) 1
                    (cap-s-y c) nil (cap-s-u c) nil (cap-s-v c) nil)
              (let ((d (cap-dirty-mbs c)))
                (setf (cap-dirty-mbs c)
                      (make-array (length d) :element-type 'bit :initial-element 0))
                (when fresh (fill d 1))
                (values (copy-seq (cap-y c)) (copy-seq (cap-u c)) (copy-seq (cap-v c))
                        (cap-width c) (cap-height c) d))))
          (let ((fresh (%ensure-scaled c scale)))
            (when (or (cap-dirty c) fresh)
              (setf (cap-dirty c) nil)
              (let ((d (cap-dirty-mbs c)))
                (setf (cap-dirty-mbs c)
                      (make-array (length d) :element-type 'bit :initial-element 0))
                ;; a mirror that has just been allocated holds nothing, so everything is dirty
                (when fresh (fill d 1))
                (multiple-value-bind (sw sh) (%rescale-mbs c scale d)
                  (values (copy-seq (cap-s-y c)) (copy-seq (cap-s-u c)) (copy-seq (cap-s-v c))
                          sw sh (%scale-dirty c scale d))))))))))
