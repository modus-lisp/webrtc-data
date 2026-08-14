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
    (asdf:load-system "webrtc-data")
    ;; The enrolment store is the DESKTOP's now, so this harness starts a real one: a glass
    ;; admission service on a loopback port, over a /tmp fixture.  That is not a stub — it is the
    ;; same code and the same socket protocol the gateway uses in production, and the panel's
    ;; query, invoker and revoke all go through it here exactly as they do there.
    (asdf:load-system "glass/nostr")))

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

(format t "~&== the gateway's own names for the desktop, lifted out of its source ==~%")
;; What warp-channel.lisp needs from the gateway is no longer a store — it is WHERE THE DESKTOP IS.
;; Lifted rather than transcribed for the same reason AUTHORIZED-P used to be: the harness must
;; break if the gateway renames or re-defaults them, instead of quietly agreeing with itself.
(dolist (f '("%unix-now")) (lift "defun" f))
(dolist (v '("*glass-host*" "*admission-port*")) (lift "defparameter" v))
;; and the control channel's id, from the file that owns it, so "these two do not collide" is a
;; claim about the shipped constants rather than about two numbers written down in a test
(lift "defconstant" "+control-stream-id+" *profiles-source*)
(lift "defun" "control-sid-p" *profiles-source*)
(ok "the gateway names its desktop's admission port, and the default is the convention"
    (and (boundp '*admission-port*) (= 5915 *admission-port*)))
(ok "...one past the microphone's 5914, which is one past the mix's 5913, which is a decade past
        the screen's 5903 — arithmetic, not four numbers typed into a startup script"
    (= *admission-port* (glass:seat-admission-port 5903)))
(ok "and the control channel's stream id, from video-profiles.lisp" (= 100 +control-stream-id+))
(ok "THE GATEWAY NO LONGER HAS A DEVICE STORE OR AN ALLOWLIST OF ITS OWN.
        That is the claim the whole move rests on: one store, one writer, in the process that
        stays up.  A second copy here would be a second writer to a file synced by mtime"
    (and (null (search "(defvar *devices*" *gateway-source*))
         (null (search "(defun authorized-p" *gateway-source*))
         (null (search "(defun sync-devices" *gateway-source*))
         (null (search "(defun enrol-device" *gateway-source*))
         (null (search "(defparameter *device-file*" *gateway-source*))))

;;; ---- a fixture, in /tmp, and never anywhere else ----------------------------------------
;;; REVOKE-TERMINAL genuinely rewrites whatever the device file names.  A suite that pointed at the
;;; live .glass-devices would revoke a real terminal to pass, which has happened here before.

(defparameter *device-file* "/tmp/warp-gw-test-devices")
(defparameter *owner-npub* "1111111111111111111111111111111111111111111111111111111111111111")
(defparameter *guest-npub* "2222222222222222222222222222222222222222222222222222222222222222")
(defparameter *rando*     "3333333333333333333333333333333333333333333333333333333333333333")

;; A REAL DESKTOP, on a port no desktop uses, over that fixture.  Its allowlist is the owner and
;; nobody else, which is what makes the invoker mapping below a test of the policy rather than of a
;; local variable named *ALLOW*.
(setf glass:*enrolment-file* *device-file*
      glass::*enrolments-mtime* nil
      glass:*box-secret* (make-string 64 :initial-element #\7))
(clrhash glass:*enrolments*)
(glass:refresh-nostr-allow *owner-npub*)
(setf *admission-port* 15917)

(defun write-fixture ()
  (let ((now (%unix-now)))
    (with-open-file (s *device-file* :direction :output :if-exists :supersede
                                     :if-does-not-exist :create)
      (format s "~a ~a~%" *guest-npub* (+ now 86400))
      (format s "~a ~a~%" *rando* (+ now 43200))))
  (setf glass::*enrolments-mtime* nil))
(write-fixture)

(defparameter *desktop* (glass:start-admission-service :port *admission-port* :install nil))
(sleep 0.2)
(ok "a desktop is answering on the port the gateway would ask"
    (not (null (glass:admission-ping :host *glass-host* :port *admission-port*))))

(ok "the fixture is in /tmp, and the live enrolment file is not named anywhere here"
    (and (eql 0 (search "/tmp/" *device-file*))
         (null (search ".glass-devices" *device-file*))))
(ok "and the test port is not the one a real desktop serves on"
    (/= 5915 *admission-port*))

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

;;; A peer's state is a LINK now, not a channel: one stream may carry several apps, so reaching a
;;; particular one goes through the mux.  NIL is the device manager — the app with no name.
(defun chan-of (state &optional app)
  (let ((cell (assoc app (funcall (find-symbol "MUX-CHANNELS" "WARP-DOM") (warp-link-mux state))
                     :test #'equal)))
    (cdr cell)))

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
         ;; the desktop's own classification, which the session now asks for rather than computes
         (cond (code-ok "code")
               ((glass:allowed-pubkey-p pub) "allowlist")
               ((glass:device-enrolled-p pub) "device")
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
(ok "the revoke handler no longer WRITES A FILE at all — it asks the desktop that owns the store.
        A panel still rewriting a local .glass-devices would be revoking terminals nobody enforces"
    (let ((src (with-output-to-string (o)
                 (let ((*print-readably* nil))
                   (princ (function-lambda-expression
                           (fdefinition (find-symbol "REVOKE-IN-FILE" "WARP-MONITOR")))
                          o)))))
      (search "ADMISSION-REVOKE" (string-upcase src))))

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
                 (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (chan-of *owner-ch*)))
        (funcall (find-symbol "CONSUMER-PROJECTION" "WARP")
                 (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (chan-of *guest-ch*)))))
(ok "with different invokers, taken from their pubkeys"
    (and (eq :allowlist (funcall (find-symbol "CONSUMER-INVOKER" "WARP")
                                 (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (chan-of *owner-ch*))))
         (eq :device (funcall (find-symbol "CONSUMER-INVOKER" "WARP")
                              (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (chan-of *guest-ch*))))))

(defun menu-of (state)
  (let* ((c (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (chan-of state)))
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
(format t "~&== a second APP on the same stream: off unless asked, and refused when off ==~%")
;;; ===========================================================================================
;;; The multiplex, from the gateway's side.  What is being claimed is narrow and is the whole of
;;; what this file can claim: an app id routes to the right projection, an app this box does not
;;; serve is DROPPED rather than mistaken for the default one, and the device manager's channel is
;;; not touched by either.  That the frames then render as columns is warp/t/two-apps.sh's, in a
;;; browser, because it is a claim about a browser.

(ok "with WARP_FILES unset the file browser is not an app this box has"
    (and (null *warp-files-enabled*) (null (warp-app "files"))))
(let ((before (length (funcall (find-symbol "MUX-CHANNELS" "WARP-DOM") (warp-link-mux *owner-ch*)))))
  (warp-on-message *owner-ch* :fake-assoc +warp-stream-id+
                   "{\"t\":\"viewport\",\"rows\":9,\"a\":\"files\"}" *owner-npub*)
  (ok "so a phone asking for it opens nothing, and is not silently given the device manager"
      (= before (length (funcall (find-symbol "MUX-CHANNELS" "WARP-DOM")
                                 (warp-link-mux *owner-ch*)))))
  (ok "and the device manager's own consumer is untouched by the refusal"
      (= 10 (funcall (find-symbol "DOM-ROWS" "WARP-DOM")
                     (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (chan-of *owner-ch*))))))
(ok "an app id nobody has ever served is the same refusal, not a crash"
    (null (warp-app "no-such-app")))

(format t "~&   -- and with WARP_FILES set, the same peer gets a second consumer --~%")
;;; The fixture root is in /tmp and the env var is what the gateway would read.  If :warp-files
;;; will not load — it drags warren, gesso, scribe and pigment — this SKIPS rather than fails: the
;;; claim is about the routing, and a box without the sibling checkout is the case the guard is for.
(require :sb-posix)
(defparameter *files-root* "/tmp/warp-channel-files-fixture/")
(ensure-directories-exist (merge-pathnames "sub/" *files-root*))
(with-open-file (s (merge-pathnames "one.txt" *files-root*) :direction :output
                                                            :if-exists :supersede)
  (write-string "hello" s))
(sb-posix:putenv (format nil "WARP_FILES_ROOT=~a" *files-root*))
(setf *warp-files-enabled* t)

;;; A FRESH PEER, and that is not a convenience: MUX-REFUSED remembers a refusal for the life of a
;;; link, so *OWNER-CH* — which asked while the app was off — will never be given it.  That is the
;;; behaviour we want on a gateway (an app that is not served must not cost a load attempt per
;;; message) and it means enabling one takes a restart, which it already did.
(defvar *both-ch* nil)
(if (not (warp-files-ensure-loaded))
    (format t "~&  skip  :warp-files is not loadable in this image — routing untested~%")
    (progn
      ;; THE WIRE IS CLEARED BEFORE THE CHANNELS EXIST, not after: each of these consumers sends
      ;; its first fill on its first tick, and clearing later throws away whichever one was quick.
      (setf *wire* '())
      (setf *both-ch* (warp-on-message nil :fake-assoc +warp-stream-id+
                                       "{\"t\":\"viewport\",\"rows\":9,\"scroll\":0}" *owner-npub*))
      (warp-on-message *both-ch* :fake-assoc +warp-stream-id+
                       "{\"t\":\"viewport\",\"rows\":9,\"scroll\":0,\"a\":\"files\"}" *owner-npub*)
      (ok "one link, two channels: the app with no name and the one that has one"
          (and (chan-of *both-ch*) (chan-of *both-ch* "files")
               (not (eq (chan-of *both-ch*) (chan-of *both-ch* "files")))))
      (when (and (chan-of *both-ch*) (chan-of *both-ch* "files"))
        (ok "on its own projection — a different query, not a different view of one"
            (not (eq (funcall (find-symbol "CONSUMER-PROJECTION" "WARP")
                              (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM")
                                       (chan-of *both-ch*)))
                     (funcall (find-symbol "CONSUMER-PROJECTION" "WARP")
                              (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM")
                                       (chan-of *both-ch* "files"))))))
        ;; asked of the QUERY rather than of the cache, so this does not depend on whether the
        ;; channel's clock has taken a pass yet
        (ok "rooted where WARP_FILES_ROOT said, which is the only thing that variable does"
            (let ((rows (funcall (funcall (find-symbol "PROJECTION-ROWS-FN" "WARP")
                                          *warp-files-projection*))))
              (equal (truename *files-root*)
                     (funcall (find-symbol "BROWSER-ROOT" "WARP-FILES")
                              (funcall (find-symbol "COLUMN-BROWSER" "WARP-FILES")
                                       (funcall (find-symbol "ROW-COLUMN" "WARP-FILES")
                                                (first rows)))))))
        (ok "and with the same invoker, because it is the same authenticated peer"
            (eq :allowlist (funcall (find-symbol "CONSUMER-INVOKER" "WARP")
                                    (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM")
                                             (chan-of *both-ch* "files")))))
        (sleep 1.2)
        (let ((labelled (remove-if-not (lambda (m) (search "\"a\":\"files\"" (cdr m))) *wire*))
              (plain (remove-if (lambda (m) (search "\"a\":" (cdr m))) *wire*)))
          (ok "the file browser's frames are labelled and the device manager's are not"
              (and labelled plain))
          (ok "and both went out on the ONE stream id — no second channel was needed"
              (every (lambda (m) (eql +warp-stream-id+ (car m))) *wire*))
          (when labelled
            (format t "     ~a~%"
                    (subseq (cdr (first labelled)) 0 (min 120 (length (cdr (first labelled)))))))
          (ok "the labelled ones carry the columns in `cs`, which is what makes them nest"
              (and labelled (every (lambda (m) (search "\"cs\":[\"col:" (cdr m))) labelled)))))
      (ok "closing the link closes every app on it, and is still safe twice"
          (and (null (warp-close *both-ch*)) (null (warp-close *both-ch*))))))
(setf *warp-files-enabled* nil)

;;; ===========================================================================================
(format t "~&== rule 6: the guest's out-of-band revoke is refused at INVOCATION ==~%")
;;; ===========================================================================================

(defun devices-now ()
  "The enrolments, asked of the desktop the way the panel's query asks."
  (sort (mapcar #'car (glass:admission-devices :host *glass-host* :port *admission-port*))
        #'string<))

(let ((before (devices-now)))
  (warp-on-message *guest-ch* :fake-assoc +warp-stream-id+
                   (format nil "{\"t\":\"cmd\",\"name\":\"revoke-terminal\",\"key\":\"~a\",\"confirmed\":true}"
                           *rando*)
                   *guest-npub*)
  (ok "the enrolment survives — the menu was courtesy, INVOKE is the enforcement point"
      (equal before (devices-now)))
  (ok "and the desktop's own view of who is enrolled is unchanged"
      (glass:device-enrolled-p *rando*))
  ;; belt and braces, and the braces are the point: even if warp's rule 6 were bypassed entirely,
  ;; the desktop refuses a revoke whose invoking pubkey is not on ITS allowlist
  (ok "...and the desktop would have refused it anyway, on its own side of the socket"
      (multiple-value-bind (r why)
          (glass:admission-revoke *guest-npub* *rando* :host *glass-host* :port *admission-port*)
        (and (null r) (eq :denied why)))))

(format t "~&== ...and the owner's is not, and the GATEWAY honours it ==~%")
(let ((before (devices-now)))
  (warp-on-message *owner-ch* :fake-assoc +warp-stream-id+
                   (format nil "{\"t\":\"cmd\",\"name\":\"revoke-terminal\",\"key\":\"~a\",\"confirmed\":true}"
                           *rando*)
                   *owner-npub*)
  (ok "the terminal is revoked" (= (1- (length before)) (length (devices-now))))
  (ok "and the DESKTOP's own admission check now says no — which is the check that matters,
        because it is the one every offer is measured against"
      (null (nth-value 0 (glass:admission-admit *rando* nil
                                                :host *glass-host* :port *admission-port*))))
  (ok "the terminal that was not named is untouched" (glass:device-enrolled-p *guest-npub*)))

;;; ===========================================================================================
(format t "~&== a peer that vanishes: the send refuses rather than blocking forever ==~%")
;;; ===========================================================================================

(defun errs (state)
  (getf (funcall (find-symbol "CHANNEL-STATS" "WARP-DOM") (chan-of state)) :send-errors))

(setf *assoc-state* :aborted)
(setf *wire* '())
;; LET THE REVOKE LAND FIRST.  What makes the rewrite below something the channels want to send is
;; that they have already been told the revoked terminal is gone — so if the :gone has not been
;; delivered yet, re-adding it diffs to nothing and the aborted link is never touched.  That was an
;; unstated timing assumption and it held until something slower ran before it.
(sleep 0.8)
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
    (and (chan-of *owner-ch*) (chan-of *guest-ch*)))
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
         (not (member (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (chan-of *owner-ch*))
                      (funcall (find-symbol "PROJECTION-CONSUMERS" "WARP") *warp-projection*)))))
(ok "the OTHER peer is undisturbed by its neighbour leaving"
    (member (funcall (find-symbol "CHANNEL-CONSUMER" "WARP-DOM") (chan-of *guest-ch*))
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

;;; ===========================================================================================
(format t "~&== and with no desktop answering: an empty list, and everybody a guest ==~%")
;;; ===========================================================================================
;;; The safe direction in both cases, and neither is silent.  A list that cannot be fetched is
;;; empty rather than stale; an authority that cannot be checked is not granted.  Note that a
;;; phone in this state is a phone whose screen, audio and microphone are all coming from the same
;;; process that is not answering — the panel is not the thing it will notice.

(glass:stop-admission-service *desktop*)
(sleep 0.3)
(setf *warp-query-complained* nil)
(ok "the query answers no rows rather than signalling into a session thread"
    (null (warp-enrolments)))
(ok "and everybody is a guest, including the owner — the one mistake with consequences here
        would be offering `revoke' to somebody whose authority could not be checked"
    (and (eq :device (warp-invoker-for *owner-npub*))
         (eq :device (warp-invoker-for *guest-npub*))))

(format t "~&~:[~a TEST(S) FAILED~;ALL TESTS PASSED~]~%" (zerop *fails*) *fails*)
(unless (zerop *fails*) (sb-ext:exit :code 1))
