;;;; warp-channel-test.lisp — warp-channel.lisp, exercised in a process that is not a gateway.
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
;;;; This harness therefore does two things carefully:
;;;;
;;;;   1. It EXTRACTS the definitions it needs from gateway-nostr.lisp by name, out of the file's
;;;;      text, and evaluates only those.  AUTHORIZED-P — the predicate the whole invoker mapping
;;;;      turns on — is the gateway's real one, character for character, rather than a copy that
;;;;      could drift into agreeing with the test.  Nothing else in that file runs: not the ASDF
;;;;      loads, not the LOAD of this directory's other files, and above all not the signalling
;;;;      loop at the bottom.
;;;;   2. It stubs SCTP-SEND-STRING and SCTP-STATS, which are the two calls that genuinely need a
;;;;      live association.  That is the whole of what stays unverified — one function that puts
;;;;      bytes on a stream, already carrying RFB and the control channel in production.
;;;;
;;;; Everything above those two calls — the stream-id gate, the invoker mapping, the lazy open, the
;;;; refusal path, the close — is real code, running.
;;;;
;;;;     sbcl --dynamic-space-size 2048 --non-interactive --load warp-channel-test.lisp

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "webrtc-data")))

(in-package #:webrtc-data)

(defvar *fails* 0)
(defun ok (n p) (format t "~&  ~:[FAIL~;ok  ~] ~a~%" p n) (unless p (incf *fails*)))

;;; ---- lift the gateway's own definitions, without running the gateway --------------------

(defparameter *here* (or *load-pathname* *default-pathname-defaults*))
(defun slurp (name)
  (with-open-file (in (merge-pathnames name *here*))
    (let ((s (make-string (file-length in)))) (subseq s 0 (read-sequence s in)))))

(defparameter *gateway-source* (slurp "gateway-nostr.lisp"))
(defparameter *profiles-source* (slurp "video-profiles.lisp"))

(defun lift (kind name &optional (source *gateway-source*))
  "Read the toplevel (KIND NAME ...) form out of a gateway file's TEXT and evaluate it.
By NAME and out of the text, so what runs here is what is in that file — and so that adding a
definition to it can never silently change what this test is testing.  Nothing else in the file is
read, evaluated, or so much as looked at."
  (let* ((needle (format nil "(~a ~a " kind name))
         (at (search needle source)))
    (unless at (error "warp-channel-test: no (~a ~a ...) in the source" kind name))
    (eval (read-from-string source t nil :start at))
    name))

(format t "~&== the gateway's own device store and allowlist predicate, lifted by name ==~%")
(dolist (v '("*device-ttl*" "*devices*" "*devices-lock*" "*devices-mtime*"))
  (lift (if (string= v "*device-ttl*") "defparameter" "defvar") v))
(dolist (f '("%unix-now" "authorized-p" "load-devices" "save-devices" "sync-devices"
             "device-enrolled-p" "enrol-device"))
  (lift "defun" f))
;; and the control channel's id, from the file that owns it, so "these two do not collide" is a
;; claim about the shipped constants rather than about two numbers written down in a test
(lift "defconstant" "+control-stream-id+" *profiles-source*)
(lift "defun" "control-sid-p" *profiles-source*)
(ok "AUTHORIZED-P is the gateway's, lifted out of its source" (fboundp 'authorized-p))
(ok "and so is the device store it reads" (and (fboundp 'sync-devices) (boundp '*devices*)))
(ok "and the control channel's stream id, from video-profiles.lisp" (= 100 +control-stream-id+))

;;; ---- a fixture, in /tmp, and never anywhere else ----------------------------------------
;;; REVOKE-TERMINAL genuinely rewrites whatever the device file names.  A suite that pointed at the
;;; live .glass-devices would revoke a real terminal to pass, which has happened here before.

(defparameter *device-file* "/tmp/warp-gw-test-devices")
(defparameter *owner-npub* "1111111111111111111111111111111111111111111111111111111111111111")
(defparameter *guest-npub* "2222222222222222222222222222222222222222222222222222222222222222")
(defparameter *rando*     "3333333333333333333333333333333333333333333333333333333333333333")
(defparameter *allow* (list *owner-npub*))

(defun write-fixture ()
  (let ((now (%unix-now)))
    (with-open-file (s *device-file* :direction :output :if-exists :supersede
                                     :if-does-not-exist :create)
      (format s "~a ~a~%" *guest-npub* (+ now 86400))
      (format s "~a ~a~%" *rando* (+ now 43200))))
  (setf *devices-mtime* nil))
(write-fixture)

(ok "the fixture is in /tmp, and the live enrolment file is not named anywhere here"
    (and (eql 0 (search "/tmp/" *device-file*))
         (null (search ".glass-devices" *device-file*))))

;;; ---- the two calls that need a live association, and nothing else ------------------------

(defvar *wire* '())
(defvar *assoc-state* :established)
(defun sctp-send-string (assoc sid string)
  (declare (ignore assoc))
  (push (cons sid string) *wire*))
(defun sctp-stats (assoc) (declare (ignore assoc)) (list :state *assoc-state*))

;;; ---- and now the file under test ---------------------------------------------------------

(load (merge-pathnames "warp-channel.lisp" *here*))
(setf *warp-channel-enabled* t)                    ; WARP_CHANNEL, without an env round trip

;;; ===========================================================================================
(format t "~&== the gate: with the feature off, nothing here is reachable ==~%")
;;; ===========================================================================================

;; THE STREAM ID CLAIMS ITS OWN TRAFFIC WHETHER OR NOT THE FEATURE IS ON.  A phone whose page has
;; the panel, talking to a box that does not have the channel, must not have its viewport report
;; fall past this clause into the RFB one — 0x7B is not an RFB client message type, and glass would
;; be handed it as desktop input.  Disabled means DROPPED, not FORWARDED.
(let ((*warp-channel-enabled* nil))
  (ok "the warp stream is still recognised as the warp stream with the feature off"
      (warp-sid-p +warp-stream-id+))
  (ok "and its messages are dropped rather than opening anything"
      (null (warp-on-message nil :fake-assoc +warp-stream-id+
                             "{\"t\":\"viewport\",\"rows\":9}" *owner-npub*)))
  (ok "...which is what keeps them off the RFB stream, where they would be input to a desktop"
      (not (control-sid-p +warp-stream-id+))))
(ok "and no other stream is claimed, enabled or not"
    (and (null (warp-sid-p 0)) (null (warp-sid-p 100)) (null (warp-sid-p 101))
         (warp-sid-p +warp-stream-id+)))
(ok "the id is 102: beside control's 100, clear of the ids DCEP hands out from the bottom"
    (and (= 102 +warp-stream-id+) (/= +warp-stream-id+ +control-stream-id+)))
(ok "and the rfb and control streams still route where they always did"
    (and (control-sid-p 100) (not (control-sid-p 0)) (not (control-sid-p +warp-stream-id+))))

;;; ===========================================================================================
(format t "~&== the invoker comes from the AUTHENTICATED PEER, and from nothing else ==~%")
;;; ===========================================================================================

(ok "an allowlisted identity is the owner" (eq :allowlist (warp-invoker-for *owner-npub*)))
(ok "an enrolled device is a guest" (eq :device (warp-invoker-for *guest-npub*)))
(ok "so is a peer the box has never heard of" (eq :device (warp-invoker-for *rando*)))
(ok "and so is no peer at all — the narrow answer is the default"
    (eq :device (warp-invoker-for nil)))

;;; THE CASE THAT MOTIVATED NOT REUSING `via`.  The session classifies code / allowlist / device and
;;; takes the FIRST match, so an owner arriving on a magic link is classified "code" — and a guest
;;; who was sent one is classified "code" too.  One string, two opposite authorities.
(format t "~&   -- and it is not the session's `via`, which conflates two opposite peers --~%")
(flet ((via (pub code-ok)
         ;; the session's own classification, transcribed from gateway-nostr.lisp
         (cond (code-ok "code")
               ((authorized-p pub) "allowlist")
               ((device-enrolled-p pub) "device")
               (t nil))))
  (ok "the owner on a magic link is classified \"code\", not \"allowlist\""
      (string= "code" (via *owner-npub* t)))
  (ok "a guest on a magic link is classified \"code\" too — the same string, the other peer"
      (string= "code" (via *guest-npub* t)))
  (ok "mapping that string would demote the owner AND promote the guest, so we do not: the
        owner is still the owner"
      (eq :allowlist (warp-invoker-for *owner-npub*)))
  (ok "        ...and the guest is still a guest"
      (eq :device (warp-invoker-for *guest-npub*))))

;;; ===========================================================================================
(format t "~&== the first message IS the open: a negotiated channel has no handshake ==~%")
;;; ===========================================================================================

(setf *wire* '())
(defvar *owner-ch* nil)
(ok "nothing exists before the peer speaks" (null *owner-ch*))
(setf *owner-ch* (warp-on-message nil :fake-assoc +warp-stream-id+
                                  "{\"t\":\"viewport\",\"rows\":10,\"scroll\":0}" *owner-npub*))
(ok "the first message opened a channel" (not (null *owner-ch*)))
(ok "warp and warp-monitor are in the image now, and were not before"
    (and *warp-loaded* (find-package "WARP") (find-package "WARP-DOM")))
(ok "and the projection is shared — one query, however many phones"
    (not (null *warp-projection*)))
(ok "the revoke handler was aimed at OUR device file, not at its compiled-in default"
    (equal *device-file* (symbol-value (find-symbol "*DEVICES-FILE*" "WARP-MONITOR"))))

(sleep 0.6)                                     ; let the channel's own clock take a pass
(ok "frames reached the fake stream, on the warp stream id and no other"
    (and *wire* (every (lambda (m) (eql +warp-stream-id+ (car m))) *wire*)))
(let* ((frame (cdr (first (last *wire*))))
       (j (funcall (find-symbol "FROM-JSON" "WARP-DOM") frame))
       (ds (funcall (find-symbol "JSON-GET" "WARP-DOM") j "deltas")))
  (format t "     ~a~%" (subseq frame 0 (min 150 (length frame))))
  (ok "carrying the enrolled terminals, keyed by pubkey"
      (and ds (every (lambda (d)
                       (member (funcall (find-symbol "JSON-GET" "WARP-DOM") d "key")
                               (list *guest-npub* *rando*) :test #'equal))
                     ds)))
  (ok "as :appeared deltas into the rows container, with the DOM's own anchors"
      (every (lambda (d)
               (and (equal "appeared" (funcall (find-symbol "JSON-GET" "WARP-DOM") d "k"))
                    (equal "rows" (funcall (find-symbol "JSON-GET" "WARP-DOM") d "in"))))
             ds)))

;;; ===========================================================================================
(format t "~&== a second peer: same query, own stream, own authority ==~%")
;;; ===========================================================================================

(defvar *guest-ch*
  (warp-on-message nil :fake-assoc +warp-stream-id+
                   "{\"t\":\"viewport\",\"rows\":10,\"scroll\":0}" *guest-npub*))
(ok "the guest opened its own channel" (not (null *guest-ch*)))
(ok "over the SAME projection — rule 8's shared half"
    (eq (funcall (find-symbol "CONSUMER-PROJECTION" "WARP")
                 (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (car *owner-ch*)))
        (funcall (find-symbol "CONSUMER-PROJECTION" "WARP")
                 (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (car *guest-ch*)))))
(ok "with different invokers, taken from their pubkeys"
    (and (eq :allowlist (funcall (find-symbol "CONSUMER-INVOKER" "WARP")
                                 (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (car *owner-ch*))))
         (eq :device (funcall (find-symbol "CONSUMER-INVOKER" "WARP")
                              (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (car *guest-ch*))))))

(defun menu-of (state)
  (let* ((c (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (car state)))
         (m (funcall (find-symbol "CONSUMER-MENU" "WARP") c)))
    (mapcar (lambda (it) (first (funcall (find-symbol "PRESENT" "WARP") it
                                         (find-symbol "MENU-ITEM" "WARP")
                                         (find-symbol "MONITOR-VIEW" "WARP-MONITOR"))))
            (getf m :items))))

(sleep 0.4)
(warp-on-message *owner-ch* :fake-assoc +warp-stream-id+
                 (format nil "{\"t\":\"gesture\",\"g\":\"hold\",\"key\":\"~a\"}" *rando*) *owner-npub*)
(warp-on-message *guest-ch* :fake-assoc +warp-stream-id+
                 (format nil "{\"t\":\"gesture\",\"g\":\"hold\",\"key\":\"~a\"}" *rando*) *guest-npub*)
(let ((o (menu-of *owner-ch*)) (g (menu-of *guest-ch*)))
  (format t "     owner: ~{~a~^, ~}~%     guest: ~{~a~^, ~}~%" o g)
  (ok "the owner's hold-menu offers revoke" (member "revoke" o :test #'string=))
  (ok "the guest's does not" (not (member "revoke" g :test #'string=))))

;;; ===========================================================================================
(format t "~&== rule 6: the guest's out-of-band revoke is refused at INVOCATION ==~%")
;;; ===========================================================================================

(defun devices-now ()
  (sort (let ((out '()))
          (sync-devices)
          (bt:with-lock-held (*devices-lock*)
            (maphash (lambda (k v) (declare (ignore v)) (push k out)) *devices*))
          out)
        #'string<))

(let ((before (devices-now)))
  (warp-on-message *guest-ch* :fake-assoc +warp-stream-id+
                   (format nil "{\"t\":\"cmd\",\"name\":\"revoke-terminal\",\"key\":\"~a\",\"confirmed\":true}"
                           *rando*)
                   *guest-npub*)
  (ok "the enrolment survives — the menu was courtesy, INVOKE is the enforcement point"
      (equal before (devices-now)))
  (ok "and the gateway's own view of who is enrolled is unchanged"
      (device-enrolled-p *rando*)))

(format t "~&== ...and the owner's is not, and the GATEWAY honours it ==~%")
(let ((before (devices-now)))
  (warp-on-message *owner-ch* :fake-assoc +warp-stream-id+
                   (format nil "{\"t\":\"cmd\",\"name\":\"revoke-terminal\",\"key\":\"~a\",\"confirmed\":true}"
                           *rando*)
                   *owner-npub*)
  (ok "the terminal is revoked" (= (1- (length before)) (length (devices-now))))
  (ok "and DEVICE-ENROLLED-P — the gateway's own admission check — now says no.
        The file is the source of truth and SYNC-DEVICES is what makes that true without a restart"
      (not (device-enrolled-p *rando*)))
  (ok "the terminal that was not named is untouched" (device-enrolled-p *guest-npub*)))

;;; ===========================================================================================
(format t "~&== a peer that vanishes: the send refuses rather than blocking forever ==~%")
;;; ===========================================================================================

(defun errs (state)
  (getf (funcall (find-symbol "CHANNEL-STATS" "WARP-DOM") (car state)) :send-errors))

(setf *assoc-state* :aborted)
(setf *wire* '())
(write-fixture)                                   ; give both channels something to want to send
(sleep 1.2)
(ok "an aborted association is not written to"
    (null *wire*))
;; The two channels tick on their own clocks and neither is the other's, so which of them notices
;; first is a race and asserting on a particular one would be asserting on the scheduler.  What is
;; being claimed is that a dead link becomes a COUNTER rather than a stack trace on a session
;; thread, and that claim is about the pair.
(format t "     send errors: owner ~a, guest ~a~%" (errs *owner-ch*) (errs *guest-ch*))
(ok "the failure is counted on a channel rather than raised into a session thread"
    (plusp (+ (errs *owner-ch*) (errs *guest-ch*))))
(ok "and both channels are still ticking rather than having unwound"
    (and (car *owner-ch*) (car *guest-ch*)))
(setf *assoc-state* :established)

;;; ===========================================================================================
(format t "~&== close runs on an unwind path, so it may not signal and may find nothing ==~%")
;;; ===========================================================================================

(ok "closing NIL — the session where the panel was never opened — is a no-op"
    (null (warp-close nil)))
(ok "closing a live channel returns NIL, which is what the session stores back"
    (null (warp-close *owner-ch*)))
(ok "and closing it again is still not an error" (null (warp-close *owner-ch*)))
(ok "the consumer was unseated; the projection outlives the session"
    (and *warp-projection*
         (not (member (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (car *owner-ch*))
                      (funcall (find-symbol "PROJECTION-CONSUMERS" "WARP") *warp-projection*)))))
(ok "the OTHER peer is undisturbed by its neighbour leaving"
    (member (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (car *guest-ch*))
            (funcall (find-symbol "PROJECTION-CONSUMERS" "WARP") *warp-projection*)))

(format t "~&== a message that is not a message ==~%")
(dolist (junk '("" "{" "]]]" "{\"t\":\"cmd\",\"name\":\"rm -rf\"}"))
  (ok (format nil "  ~s does not take the session thread down" junk)
      (not (null (warp-on-message *guest-ch* :fake-assoc +warp-stream-id+ junk *guest-npub*)))))
;; A box that does not have warp checked out at all: WARP-ENSURE-LOADED answers NIL, WARP-OPEN
;; answers NIL, and the session stores NIL back — so the phone's panel shows no answer and the
;; gateway carries on.  A missing sibling checkout is a menu item that does not work, not a session
;; that falls over.
(let ((real (fdefinition 'warp-ensure-loaded)))
  (unwind-protect
       (progn
         (setf (fdefinition 'warp-ensure-loaded) (lambda () nil))
         (ok "with warp unavailable the channel simply does not open"
             (null (warp-on-message nil :fake-assoc +warp-stream-id+
                                    "{\"t\":\"viewport\",\"rows\":8}" *rando*)))
         (ok "and a second message is still not an error"
             (null (warp-on-message nil :fake-assoc +warp-stream-id+ "{\"t\":\"nope\"}" *rando*))))
    (setf (fdefinition 'warp-ensure-loaded) real)))

(warp-close *guest-ch*)

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
(unless (zerop *fails*) (sb-ext:exit :code 1))
