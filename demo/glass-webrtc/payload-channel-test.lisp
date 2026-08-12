;;;; payload-channel-test.lisp — payload-channel.lisp, exercised in a process that is not a gateway.
;;;;
;;;; ==============================================================================================
;;;; THE RULE THIS FILE EXISTS UNDER
;;;; ==============================================================================================
;;;;
;;;; gateway-nostr.lisp MAY NOT BE LOADED.  Loading it subscribes to three Nostr relays as the box's
;;;; own identity, answers offers, and races the session a person is using — it has broken that
;;;; session before.  So the gateway file is verified by READING, and everything it delegates to is
;;;; verified here instead, which is the only reason delegating was worth doing.
;;;;
;;;; The shape is warp-channel-test.lisp's, deliberately, because the two channels make the same
;;;; claims and those claims should be checked the same way:
;;;;
;;;;   1. The gateway's five added lines are checked against its TEXT — that the load is guarded,
;;;;      that the fallbacks exist, that stream 104 is claimed in the dispatch, and that the close
;;;;      is on the unwind path.  Nothing in that file is evaluated.
;;;;   2. SCTP-SEND-STRING, SCTP-SEND-BINARY and SCTP-STATS are stubbed — the three calls that
;;;;      genuinely need a live association.  That is the whole of what stays unverified here, and
;;;;      all three already carry RFB, the control channel and warp in production.
;;;;
;;;; Everything else — the stream-id gate, the file read, the hash, the cache answer, the chunking,
;;;; the duplicate-hello guard, the close — is real code, running.
;;;;
;;;;     sbcl --dynamic-space-size 2048 --non-interactive --load payload-channel-test.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "webrtc-data")))

(in-package #:webrtc-data)

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))

(defparameter *here* (or *load-pathname* *default-pathname-defaults*))
(defun slurp (name)
  (with-open-file (in (merge-pathnames name *here*))
    (let ((s (make-string (file-length in)))) (subseq s 0 (read-sequence s in)))))

;;; ---- the three calls that need a live association, and nothing else ----------------------

(defvar *wire* '())                       ; (sid . string-or-bytes), newest first
(defvar *assoc-state* :established)
(defvar *wire-lock* (bt:make-lock "wire"))
(defun sctp-send-string (assoc sid string)
  (declare (ignore assoc))
  (bt:with-lock-held (*wire-lock*) (push (cons sid string) *wire*)))
(defun sctp-send-binary (assoc sid bytes)
  (declare (ignore assoc))
  (bt:with-lock-held (*wire-lock*) (push (cons sid (as-u8vec bytes)) *wire*)))
(defun sctp-stats (assoc) (declare (ignore assoc)) (list :state *assoc-state*))
(defun wire () (bt:with-lock-held (*wire-lock*) (reverse *wire*)))
(defun wire-clear () (bt:with-lock-held (*wire-lock*) (setf *wire* '())))
(defun strings-on-wire () (remove-if-not #'stringp (wire) :key #'cdr))
(defun chunks-on-wire () (remove-if #'stringp (wire) :key #'cdr))
;; The sender runs on its own thread (that is the point of it), so settle rather than assume.
(defun settle (&optional (secs 5))
  (let ((deadline (+ (get-universal-time) secs)) (n -1))
    (loop until (or (= n (length (wire))) (> (get-universal-time) deadline))
          do (setf n (length (wire))) (sleep 0.15))
    (wire)))

;;; ---- a fixture, in /tmp, and never anywhere else -----------------------------------------

(defparameter *fixture* "/tmp/payload-gw-test.js")
(defparameter *fixture-gz* "/tmp/payload-gw-test.js.gz")
(defun write-fixture (path text)
  (with-open-file (s path :direction :output :if-exists :supersede :if-does-not-exist :create
                          :element-type '(unsigned-byte 8))
    (write-sequence (map '(vector (unsigned-byte 8)) #'char-code text) s)))
;; ~40 KB, so the chunker has something to chunk: at 16 KB a message that is three messages.
(defparameter *fixture-text*
  (with-output-to-string (s)
    (format s "export const needs = 1;~%export function init(api){}~%")
    (dotimes (i 900) (format s "// filler line ~4,'0d ~a~%" i "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"))))
(write-fixture *fixture* *fixture-text*)

(ok "the fixture is in /tmp, and no live payload file is named here"
    (and (eql 0 (search "/tmp/" *fixture*))
         (null (search "nsite-build" *fixture*))))

;;; ---- and now the file under test ----------------------------------------------------------

(load (merge-pathnames "payload-channel.lisp" *here*))
(setf *payload-file* *fixture*)
(setf *payload-channel-enabled* t)            ; PAYLOAD_CHANNEL, without an env round trip

(defparameter *hello* "{\"t\":\"hello\",\"api\":1,\"have\":\"\",\"enc\":[\"raw\"]}")
(defun hello-with (have &optional (enc "[\"raw\"]"))
  (format nil "{\"t\":\"hello\",\"api\":1,\"have\":\"~a\",\"enc\":~a}" have enc))

;;; ===========================================================================================
(format t "~&== the gate: the stream id claims its own traffic, on or off ==~%")
;;; ===========================================================================================

;; THE POINT OF THE WHOLE GATE.  A phone whose shell asks for a payload from a box that does not
;; serve one must not have its hello fall past the 104 clause into the RFB one: 0x7B is not an RFB
;; client message type, and glass would be handed it as desktop input.  Disabled means ANSWERED
;; `none` — not forwarded, and not silently dropped either, because a spinner is a bad failure.
(ok "104 is the payload stream" (payload-sid-p +payload-stream-id+))
(ok "and it is 104" (= 104 +payload-stream-id+))
(ok "no other stream is claimed"
    (and (null (payload-sid-p 0)) (null (payload-sid-p 100))
         (null (payload-sid-p 102)) (null (payload-sid-p 103))))
(ok "104 does not collide with control (100) or warp (102)"
    (and (/= +payload-stream-id+ 100) (/= +payload-stream-id+ 102)))

(wire-clear)
(let ((*payload-channel-enabled* nil))
  (ok "with the feature off the stream is still claimed"
      (payload-sid-p +payload-stream-id+))
  (let ((st (payload-on-message nil :fake +payload-stream-id+ *hello* "pub")))
    (settle 1)
    (ok "...and a hello is ANSWERED rather than dropped, so the phone can say so and retry"
        (and st (= 1 (length (strings-on-wire)))
             (search "\"none\"" (cdr (first (strings-on-wire))))))
    (ok "...with nothing binary on the wire" (null (chunks-on-wire)))))

;;; ===========================================================================================
(format t "~&== a transfer ==~%")
;;; ===========================================================================================

(wire-clear)
(defparameter *state1* (payload-on-message nil :fake +payload-stream-id+ *hello* "pub"))
(settle)
(defparameter *begin* (cdr (first (strings-on-wire))))
(defparameter *sent-sha*
  (let* ((at (search "\"sha\":\"" *begin*))
         (start (+ at 7)))
    (subseq *begin* start (position #\" *begin* :start start))))
(defparameter *rebuilt*
  (let ((v (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (dolist (c (chunks-on-wire) v)
      (loop for b across (cdr c) do (vector-push-extend b v)))))

(ok "the transfer opens with one begin frame" (search "\"t\":\"begin\"" *begin*))
(ok "...naming the encoding" (search "\"enc\":\"raw\"" *begin*))
(ok "...and the length" (search (format nil "\"len\":~d" (length *fixture-text*)) *begin*))
(ok "...and the shell API it was built against" (search "\"api\":1" *begin*))
(ok "the chunks reassemble to the file, byte for byte"
    (equalp (coerce *rebuilt* 'list)
            (coerce (map '(vector (unsigned-byte 8)) #'char-code *fixture-text*) 'list)))
(ok "the sha in the begin frame is the sha of the bytes that were sent"
    (equal *sent-sha* (%sha256-hex (as-u8vec *rebuilt*))))
(ok "chunks are bounded by *payload-chunk*"
    (every (lambda (c) (<= (length (cdr c)) *payload-chunk*)) (chunks-on-wire)))
(ok "...and there is more than one of them, so the chunker is actually chunking"
    (> (length (chunks-on-wire)) 1))
(ok "everything went out on stream 104"
    (every (lambda (m) (eql (car m) +payload-stream-id+)) (wire)))

;; A DUPLICATE HELLO MUST NOT START A SECOND TRANSFER.  Both would interleave on one ordered stream
;; and the phone would reassemble a blend of the two — which would then fail its hash check, so the
;; symptom would be "the client never loads" with a perfectly healthy log at this end.
(let ((before (length (wire))))
  (payload-on-message *state1* :fake +payload-stream-id+ *hello* "pub")
  (settle 1)
  (ok "a duplicate hello is ignored once this peer has been answered"
      (= before (length (wire)))))

;;; ===========================================================================================
(format t "~&== the cache: a phone that already has this build is sent nothing ==~%")
;;; ===========================================================================================

(wire-clear)
(defparameter *state2* (payload-on-message nil :fake +payload-stream-id+
                                           (hello-with *sent-sha*) "pub"))
(settle 1)
(ok "a matching `have` is answered `same`"
    (and (= 1 (length (strings-on-wire)))
         (search "\"t\":\"same\"" (cdr (first (strings-on-wire))))))
(ok "...naming the sha, so the phone can check its own cache against it"
    (search *sent-sha* (cdr (first (strings-on-wire)))))
(ok "...and NOTHING binary goes on the wire, which is the whole of the cache"
    (null (chunks-on-wire)))

(wire-clear)
(payload-on-message nil :fake +payload-stream-id+ (hello-with "deadbeef") "pub")
(settle)
(ok "a stale `have` gets the full transfer" (plusp (length (chunks-on-wire))))

;;; ===========================================================================================
(format t "~&== gzip: preferred when the browser says it can inflate, and only then ==~%")
;;; ===========================================================================================

;; The .gz is written by mksplit.py, not here — this file has no deflate either.  A stand-in with
;; different bytes is enough to check WHICH FILE is chosen, which is the only decision in the code.
(write-fixture *fixture-gz* "(this stands in for gzip bytes)")
(setf *payload-cache* nil)
(wire-clear)
(payload-on-message nil :fake +payload-stream-id+ (hello-with "" "[\"gzip\",\"raw\"]") "pub")
(settle)
(ok "with gzip offered, the .gz file is served"
    (search "\"enc\":\"gzip\"" (cdr (first (strings-on-wire)))))
(setf *payload-cache* nil)
(wire-clear)
(payload-on-message nil :fake +payload-stream-id+ (hello-with "" "[\"raw\"]") "pub")
(settle)
(ok "a browser that cannot inflate gets the raw file"
    (search "\"enc\":\"raw\"" (cdr (first (strings-on-wire)))))
(ignore-errors (delete-file *fixture-gz*))

;;; ===========================================================================================
(format t "~&== a payload change is picked up without a restart ==~%")
;;; ===========================================================================================

;; This is the property the whole exercise is for: shipping a client change is `cp payload.js`.
(setf *payload-cache* nil)
(wire-clear)
(payload-on-message nil :fake +payload-stream-id+ *hello* "pub")
(settle)
(defparameter *sha-before* (%sha256-hex (as-u8vec (%read-file-bytes *fixture*))))
(sleep 1.1)                                     ; file-write-date has one-second resolution
(write-fixture *fixture* (concatenate 'string *fixture-text* "// a change~%"))
(wire-clear)
(payload-on-message nil :fake +payload-stream-id+ (hello-with *sha-before*) "pub")
(settle)
(ok "an edited payload file is re-read, re-hashed and sent — no restart"
    (and (plusp (length (chunks-on-wire)))
         (not (search "\"t\":\"same\"" (cdr (first (strings-on-wire)))))))

;;; ===========================================================================================
(format t "~&== failures are answered, never signalled ==~%")
;;; ===========================================================================================

(setf *payload-cache* nil)
(let ((*payload-file* "/tmp/there-is-no-payload-here.js"))
  (wire-clear)
  (let ((st (payload-on-message nil :fake +payload-stream-id+ *hello* "pub")))
    (settle 1)
    (ok "a missing payload file is answered `none` rather than signalling"
        (and st (search "\"none\"" (cdr (first (strings-on-wire))))))))

(setf *payload-cache* nil)
(wire-clear)
(ok "garbage on the channel returns the state unchanged and does not signal"
    (null (payload-on-message nil :fake +payload-stream-id+ "not json at all" "pub")))
(ok "...and puts nothing on the wire" (null (wire)))
(ok "a hello with no fields at all does not signal"
    (progn (payload-on-message nil :fake +payload-stream-id+ "{\"t\":\"hello\"}" "pub")
           (settle 1) t))

(ok "PAYLOAD-CLOSE tolerates being called with nothing to close" (null (payload-close nil)))
(ok "...and with a peer that was answered but never transferred" (null (payload-close t)))
(let ((stopped nil))
  (ok "...and runs the stopper when there was a transfer"
      (progn (payload-close (lambda () (setf stopped t))) stopped)))

;; An aborted association must end the transfer rather than pushing into it forever.
(setf *payload-cache* nil)
(wire-clear)
(let ((*assoc-state* :aborted))
  (%payload-send-loop :fake +payload-stream-id+
                      (as-u8vec (map 'list #'char-code *fixture-text*))
                      "sha" "raw" (lambda () t))
  (ok "an aborted association stops the transfer after the begin frame"
      (null (chunks-on-wire))))

;;; ===========================================================================================
(format t "~&== the gateway's five added lines, checked against its TEXT ==~%")
;;; ===========================================================================================

(defparameter *gw* (slurp "gateway-nostr.lisp"))
;; The LOAD FORM, not the first mention of the filename — the header comment names it too, and an
;; assertion that matched the comment would pass with the guard deleted.
(ok "the load of payload-channel.lisp is inside a HANDLER-CASE"
    (let ((at (search "(load (merge-pathnames \"payload-channel.lisp\"" *gw*)))
      (and at
           ;; the nearest preceding HANDLER-CASE is nearer than the nearest preceding toplevel form
           (let ((hc (search "(handler-case" *gw* :from-end t :end2 at))
                 (df (search (format nil "~%(defun " *gw*) *gw* :from-end t :end2 at)))
             (and hc (> hc (or df 0)))))))
(dolist (name '("*payload-channel-enabled*" "payload-sid-p" "payload-on-message" "payload-close"))
  (ok (format nil "the guard's fallback defines ~a" name)
      (let ((at (search "payload: channel unavailable" *gw*)))
        (and at (search name *gw* :start2 at)))))
(ok "the fallback claims stream 104 with a LITERAL, since the constant is what we may not have"
    (let ((at (search "payload: channel unavailable" *gw*)))
      (search "(eql sid 104)" *gw* :start2 at)))
(ok "the session dispatch has a payload clause"
    (search "((payload-sid-p sid)" *gw*))
(ok "...placed after the warp clause and before the RFB one, so 0/100/102 are unchanged"
    (let ((w (search "((warp-sid-p sid)" *gw*))
          (p (search "((payload-sid-p sid)" *gw*))
          (r (search "((and glass (plusp (length payload)))" *gw*)))
      (and w p r (< w p r))))
(ok "the session binds a per-peer payload state"
    (search "(payload-ch nil)" *gw*))
(ok "...and closes it on the unwind path, beside warp's close"
    (let ((c (search "(payload-close payload-ch)" *gw*))
          (u (search "(when warp (setf warp (warp-close warp)))" *gw*)))
      (and c u (< u c))))
;; The BANNER, not the guard's "channel unavailable" message, which also begins "@@ payload:" and
;; comes first in the file.
(ok "the banner line is printed ONLY when the channel is enabled"
    (let ((at (search "@@ payload:    stream" *gw*)))
      (and at (search "(when *payload-channel-enabled*" *gw* :from-end t :end2 at))))
(ok "...and the guard's own message is NOT gated, so a broken load always says so"
    (let ((at (search "@@ payload: channel unavailable" *gw*)))
      (and at (null (search "(when *payload-channel-enabled*" *gw*
                            :start2 (- at 200) :end2 at)))))
(ok "gateway-nostr.lisp is not loaded by this file"
    (null (search "(load (merge-pathnames \"gateway-nostr.lisp\""
                  (slurp "payload-channel-test.lisp"))))

(format t "~&~%~:[~a FAILURE(S)~;all payload-channel tests passed~]~%" (zerop *fails*) *fails*)
(finish-output)
(sb-ext:exit :code (if (zerop *fails*) 0 1))
