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
  (t-wait 0d0) (t-conv 0d0) (n-upd 0) (px 0)   ; capture-side timing
  mb-cols mb-rows dirty-mbs                    ; per-macroblock dirty flags, straight from RFB
  (dirty t) (lock (bt:make-lock)) (stop nil) thread)

(defun %rd (stream n)
  (let ((buf (make-array n :element-type '(unsigned-byte 8))) (got 0))
    (loop while (< got n)
          do (let ((r (read-sequence buf stream :start got)))
               (when (<= r got) (error "rfb: short read"))
               (setf got r)))
    buf))

(defun %be16 (b i) (logior (ash (aref b i) 8) (aref b (1+ i))))
(defun %be32 (b i) (let ((v 0)) (dotimes (k 4 v) (setf v (logior (ash v 8) (aref b (+ i k)))))))

(defun capture-connect (host port)
  "RFB handshake with glass; returns a CAPTURE with allocated planes (native 32bpp, Raw)."
  (let* ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-connect sock (sb-bsd-sockets:make-inet-address host) port)
    (let ((s (sb-bsd-sockets:socket-make-stream sock :input t :output t
                                                :element-type '(unsigned-byte 8))))
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
        (write-sequence (concatenate '(vector (unsigned-byte 8)) (vector 2 0 0 1 0 0 0 0)) s)
        (finish-output s)
        (let* ((cw (ceiling w 2)) (ch (ceiling h 2))
               (mc (ceiling w 16)) (mr (ceiling h 16))
               (c (make-capture :socket s :width w :height h :cw cw :ch ch
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

(defun %apply-rect (c rx ry rw rh data)
  "Convert one BGRX rectangle into the Y/U/V planes (BT.601, 4:2:0)."
  (let ((y (cap-y c)) (u (cap-u c)) (v (cap-v c))
        (w (cap-width c)) (cw (cap-cw c)))
    ;; luma, every pixel
    (dotimes (row rh)
      (let ((base (* row rw 4)) (out (* (+ ry row) w)))
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
             (let ((n (%be16 (%rd s 2) 0)) (tc (get-internal-real-time)))
               (bt:with-lock-held ((cap-lock c))
                 (dotimes (i n)
                   (let* ((h (%rd s 12)) (rx (%be16 h 0)) (ry (%be16 h 2))
                          (rw (%be16 h 4)) (rh (%be16 h 6)) (enc (%be32 h 8)))
                     (cond
                       ((= enc 0) (incf (cap-px c) (* rw rh))
                                  (%apply-rect c rx ry rw rh (%rd s (* rw rh 4)))
                                  (%mark-dirty c rx ry rw rh))
                       (t (error "capture: unexpected encoding ~a" enc)))))
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
               :px (cap-px c))
    (setf (cap-n-upd c) 0 (cap-t-wait c) 0d0 (cap-t-conv c) 0d0 (cap-px c) 0)))

(defun capture-start (host port)
  "Connect + run the capture loop on its own thread.  Returns the CAPTURE."
  (let ((c (capture-connect host port)))
    (setf (cap-thread c)
          (bt:make-thread (lambda ()
                            (handler-case (capture-run c)
                              (error (e) (format *error-output* "~&[capture] ~a~%" e))))
                          :name "glass-capture"))
    c))

(defun capture-stop (c)
  (setf (cap-stop c) t)
  (ignore-errors (close (cap-socket c))))

(defun capture-take (c)
  "If the desktop changed since the last call, return (values Y U V w h dirty-mbs); else NIL.
DIRTY-MBS flags exactly the macroblocks glass reported as updated, so the encoder can go straight
to them instead of scanning the screen."
  (bt:with-lock-held ((cap-lock c))
    (when (cap-dirty c)
      (setf (cap-dirty c) nil)
      (let ((d (cap-dirty-mbs c)))
        (setf (cap-dirty-mbs c) (make-array (length d) :element-type 'bit :initial-element 0))
        (values (copy-seq (cap-y c)) (copy-seq (cap-u c)) (copy-seq (cap-v c))
                (cap-width c) (cap-height c) d)))))
