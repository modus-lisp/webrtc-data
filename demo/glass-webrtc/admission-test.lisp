;;;; admission-test.lisp — the gateway's half of the move, in a process that is not a gateway.
;;;;
;;;;   sbcl --dynamic-space-size 2048 --non-interactive --load admission-test.lisp
;;;;
;;;; ==============================================================================================
;;;; THE RULE THIS FILE EXISTS UNDER
;;;; ==============================================================================================
;;;;
;;;; gateway-nostr.lisp MAY NOT BE LOADED.  Loading it subscribes to three Nostr relays as the box's
;;;; own identity, answers offers, and races the session a person is using.  So the gateway file is
;;;; verified by READING — literally, out of its own text — and everything it now delegates to is
;;;; verified by running, here, against a real service on a loopback port.
;;;;
;;;; ==============================================================================================
;;;; WHAT IT IS CHECKING
;;;; ==============================================================================================
;;;;
;;;;   1. THE TOKEN FORMAT SURVIVED THE MOVE.  login-token.lisp (the implementation the deployed
;;;;      gateway runs) and glass's MINT-LOGIN-TOKEN / VERIFY-LOGIN-TOKEN are cross-checked BOTH
;;;;      WAYS against the same secret.  Every magic link anybody holds is a string minted by the
;;;;      first and about to be verified by the second; if this fails, the day this deploys is the
;;;;      day every issued link stops working.
;;;;
;;;;   2. THE COMMAND SURFACE LEFT, AND IT LEFT AS A SWAP.  Both processes subscribe to the same
;;;;      box pubkey for the same kind, so a gateway that went on answering `link' while the
;;;;      desktop also answered it would send two magic links per request.  The gateway's source is
;;;;      searched for the names that used to do that, and for the ones that must still be there.
;;;;
;;;;   3. ADMISSION GOES THROUGH THE SERVICE, AND THE GATEWAY KEEPS NO STORE.  A local fallback
;;;;      would be a second writer to a file synchronised by mtime, which is the arrangement the
;;;;      move exists to end.  Both halves are asserted from the source: the store's names are gone,
;;;;      and the one decision left is a call.
;;;;
;;;;   4. THE SERVICE IS THE PROTOCOL.  The calls the gateway makes are made here over TCP, against
;;;;      a real glass admission service — including the case its failure policy turns on: with the
;;;;      desktop down the answer must be :UNREACHABLE and never a plain denial.
;;;;
;;;; NOTHING HERE READS OR WRITES THE LIVE .glass-devices.  A suite that pointed at it would revoke
;;;; a real terminal to pass, which has happened here before.  The fixture is in /tmp, and its
;;;; mtime is checked at the end.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "glass/nostr")))

(defpackage #:glass-admission-test (:use #:cl)) (in-package #:glass-admission-test)

(defvar *pass* 0) (defvar *fail* 0)
(defun ok (name p &optional detail)
  (if p (progn (incf *pass*) (format t "  ok   ~a~@[ — ~a~]~%" name detail))
      (progn (incf *fail*) (format t "  FAIL ~a~@[ — ~a~]~%" name detail)))
  (finish-output))
(defun banner (s) (format t "~&~%== ~a ==~%" s))

(defparameter *here* (or *load-pathname* *default-pathname-defaults*))
(defun slurp (name)
  (with-open-file (in (merge-pathnames name *here*))
    (let ((s (make-string (file-length in)))) (subseq s 0 (read-sequence s in)))))

(defparameter *gateway* (slurp "gateway-nostr.lisp"))
(defparameter *warp* (slurp "warp-channel.lisp"))

;; make-pathname with an explicit :type nil, for the reason gateway-nostr.lisp gives at its own
;; *DEVICE-FILE*: merge-pathnames would read ".glass-devices" as a TYPE and inherit the name from
;; this file, so the probe below would silently be of something that does not exist — and a
;; vacuous "the live store was not touched" is worse than no check at all.
(defparameter *live* (namestring (make-pathname :name ".glass-devices" :type nil :defaults *here*)))
(defparameter *live-mtime* (and (probe-file *live*) (file-write-date *live*)))

;;; ==============================================================================
(banner "the login-token format survived the move — checked both ways")
;;; ==============================================================================

;; The implementation the deployed gateway runs, loaded as itself.  It defines its own package and
;; touches nothing else, so this is the real thing and not a transcription of it.
(load (merge-pathnames "login-token.lisp" *here*))

(defparameter *secret* "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
(setf glass:*box-secret* *secret*)

(let ((old (glass-login:mint-token *secret* :ttl 900)))
  (format t "     old -> ~a~%" old)
  (ok "A TOKEN MINTED BY THE OLD CODE VERIFIES UNDER THE NEW ONE.
        This is the whole compatibility question: every link already in somebody's message
        history is one of these, and the desktop is about to be the thing that checks it"
      (glass:verify-login-token old))
  (multiple-value-bind (ok-p nonce exp) (glass:verify-login-token old)
    (declare (ignore ok-p))
    (multiple-value-bind (ok2 nonce2 exp2) (glass-login:verify-token *secret* old)
      (declare (ignore ok2))
      (ok "  …and reads the same nonce and expiry out of it" (and (equal nonce nonce2)
                                                                  (eql exp exp2))))))

(let ((new (glass:mint-login-token :ttl 900)))
  (format t "     new -> ~a~%" new)
  (ok "and a token minted by the NEW code verifies under the OLD one.
        Both directions, because during the deploy window both are running: the desktop mints
        the renewal that rides back with an answer, and login-link.lisp still mints from a shell"
      (glass-login:verify-token *secret* new)))

(ok "a token from a different secret verifies under neither"
    (let ((other (glass-login:mint-token (make-string 64 :initial-element #\a) :ttl 900)))
      (and (not (glass:verify-login-token other))
           (not (glass-login:verify-token *secret* other)))))

;;; ==============================================================================
(banner "the command surface left the gateway — as a SWAP, not an addition")
;;; ==============================================================================

;; Searched in the gateway's own TEXT rather than by loading it, because loading it is exactly what
;; must not happen.  A DEFUN that is gone cannot answer a DM.
(dolist (gone '("(defun parse-command" "(defun describe-devices" "(defun revoke-devices"
                "(defun link-request-p" "(defparameter *link-base*"))
  (ok (format nil "gone from gateway-nostr.lisp: ~a…)" gone) (null (search gone *gateway*))))
(ok "…and so is the reply that used to go out with them"
    (null (search "Fresh glass login link" *gateway*)))
(ok "THE DESKTOP HAS THEM INSTEAD — one command surface, in one process"
    (and (fboundp 'glass:parse-nostr-command) (fboundp 'glass:nostr-command-reply)))

;; …and the paths that were NOT touched are still there, named, in the same file.  This is the
;; other half of "a swap": the gateway that stopped answering commands must still answer offers.
(dolist (kept '("(defun parse-offer" "(defun process-offer" "(defun run-session"
                "(defun wrap-seen-p" "m=application" "(defun glass-connect"
                "webrtc-serve-datachannel" "glass:make-audio-tap" "glass:make-mic-sender"
                "(warp-sid-p sid)" "(payload-sid-p sid)" "(control-sid-p sid)"))
  (ok (format nil "still in gateway-nostr.lisp: ~a" kept) (search kept *gateway*)))

;;; ==============================================================================
(banner "the enrolment store left too — and nothing took its place here")
;;; ==============================================================================

(dolist (gone '("(defvar *devices*" "(defvar *devices-lock*" "(defun load-devices"
                "(defun save-devices" "(defun sync-devices" "(defun enrol-device"
                "(defun device-enrolled-p" "(defun authorized-p" "(defun %normalize-pubkey"
                "(defun code-status" "(defparameter *device-file*" "(defparameter *allow*"
                "glass-login:"))
  (ok (format nil "gone from gateway-nostr.lisp: ~a…" gone) (null (search gone *gateway*))))
(ok "…and login-token.lisp is no longer loaded by it — the mint went with the store"
    (null (search "(load (merge-pathnames \"login-token.lisp\"" *gateway*)))
(ok "  (the file itself stays: login-link.lisp mints from a shell and is unchanged)"
    (probe-file (merge-pathnames "login-token.lisp" *here*)))

(ok "the one decision left is a CALL: ASK-ADMISSION, over glass:ADMISSION-ADMIT"
    (and (search "(defun ask-admission" *gateway*)
         (search "(glass:admission-admit pubkey code" *gateway*)))
(ok "and it is the ONLY admission decision in the file — no second path, no fallback store"
    (= 1 (let ((n 0) (at 0))
           (loop for i = (search "(ask-admission " *gateway* :start2 at)
                 while i do (incf n) (setf at (1+ i)))
           n)))
(ok "IT FAILS CLOSED, and says so in a line that names the port, because a silent refusal
        here gets diagnosed for an hour in the wrong process"
    (and (search "FAIL CLOSED" *gateway*)
         (search "ADMISSION UNREACHABLE" *gateway*)))
(ok "the reasoning is written down beside it, not left to a commit message"
    (search "THE DESKTOP IS ALREADY A HARD DEPENDENCY OF THIS PROCESS" *gateway*))
(ok "…and the gateway reports the desktop's posture once at startup, so `nobody can connect'
        has somewhere to be diagnosed from"
    (search "(glass:admission-ping" *gateway*))
(ok "the loopback port is the convention, one past the microphone's"
    (and (search "GLASS_ADMISSION_PORT" *gateway*) (search "5915" *gateway*)))

(banner "warp's device panel followed the store")
(ok "its QUERY asks the desktop" (search "(glass:admission-devices" *warp*))
(ok "its INVOKER asks the desktop's allowlist" (search "(glass:admission-allowed-p" *warp*))
(ok "and its REVOKE is a service call, not a file write — a panel still rewriting a local
        .glass-devices would be revoking terminals nobody enforces"
    (and (search "(glass:admission-revoke" *warp*)
         (null (search "*DEVICES-FILE*" *warp*))))
(ok "none of the gateway's old store names survive in it either"
    (and (null (search "(sync-devices)" *warp*))
         (null (search "(authorized-p " *warp*))
         (null (search "*devices-lock*" *warp*))))

;;; ==============================================================================
(banner "the service, over a real socket, called the way the gateway calls it")
;;; ==============================================================================

(defparameter *port* 15916)          ; not 5915: a test must never race the desktop's own service
(defparameter *fixture* "/tmp/glass-admission-test-devices")
(defparameter *owner* "1111111111111111111111111111111111111111111111111111111111111111")
(defparameter *phone* "2222222222222222222222222222222222222222222222222222222222222222")
(defparameter *rando* "3333333333333333333333333333333333333333333333333333333333333333")

(ignore-errors (delete-file *fixture*))
(setf glass:*enrolment-file* *fixture* glass::*enrolments-mtime* nil)
(clrhash glass:*enrolments*)
(glass:refresh-nostr-allow *owner*)
(ok "the fixture is in /tmp, and the live enrolment file is not named as one"
    (and (eql 0 (search "/tmp/" glass:*enrolment-file*))
         (null (search ".glass-devices" glass:*enrolment-file*))))

(defparameter *srv* (glass:start-admission-service :port *port* :install nil))
(sleep 0.2)
(ok "a desktop is answering" (not (null (glass:admission-ping :host "127.0.0.1" :port *port*))))

(defmacro at (&rest form) `(,@form :host "127.0.0.1" :port *port*))

;;; ---- the gateway's admission call, in each of the three ways in ---------------

(let ((code (glass:mint-login-token :ttl 900)))
  (multiple-value-bind (via token) (at glass:admission-admit *phone* code)
    (ok "a phone on a magic link is admitted `code'" (eq :code via))
    (ok "  …and the renewal that rides back with the ANSWER is minted by the desktop now"
        (glass:verify-login-token token))))
(multiple-value-bind (via token) (at glass:admission-admit *phone* nil)
  (ok "the same phone, reconnecting with no code, is admitted `device'" (eq :device via))
  (ok "  …and renewed again, so an active terminal never needs a new link" (not (null token))))
(multiple-value-bind (via token) (at glass:admission-admit *owner* nil)
  (ok "the owner is admitted `allowlist'" (eq :allowlist via))
  (ok "  …with no token, exactly as the deployed gateway does it today" (null token)))
(multiple-value-bind (via why) (at glass:admission-admit *rando* nil)
  (ok "a stranger is refused" (null via))
  (ok "  …with a reason the gateway can log, so a locked-out person is diagnosable"
      (eq :absent why)))
(multiple-value-bind (via why) (at glass:admission-admit *rando* "aa.bb.cc")
  (ok "a stranger with a rotten code is refused for THAT reason" (and (null via) (eq :bad why))))

;;; ---- warp's two questions, which used to be direct reads of this process's memory ----

(ok "warp's INVOKER question: the owner is :allowlist" (at glass:admission-allowed-p *owner*))
(ok "  …and an enrolled phone is not, which is the distinction warp exists to preserve"
    (and (not (at glass:admission-allowed-p *phone*))
         (not (null (at glass:admission-devices)))))
(ok "warp's QUERY: the enrolments, as rows"
    (let ((rows (at glass:admission-devices)))
      (and (= 2 (length rows)) (every (lambda (r) (and (stringp (car r)) (integerp (cdr r)))) rows))))
(ok "warp's REVOKE, on a guest's authority: refused by the desktop, not by the panel"
    (multiple-value-bind (r why) (at glass:admission-revoke *phone* (subseq *owner* 0 8))
      (and (null r) (eq :denied why))))
(ok "  …and on the owner's: obeyed"
    (equal (list *phone*) (at glass:admission-revoke *owner* (subseq *phone* 0 8))))
(ok "  …after which the desktop's own admission check says no, with no restart anywhere"
    (null (nth-value 0 (at glass:admission-admit *phone* nil))))

;;; ---- THE CASE THE FAILURE POLICY TURNS ON ------------------------------------
;;; The gateway fails CLOSED: no answer means no admission.  That is only safe because "no answer"
;;; is distinguishable from "no", and only defensible because the desktop is ALREADY a hard
;;; dependency — GLASS-CONNECT to :5903 is not wrapped in IGNORE-ERRORS, so a session admitted
;;; against a desktop that is down is a session that fails the moment its channel opens.

(banner "with the desktop down: :UNREACHABLE, and never a plain denial")
(glass:stop-admission-service *srv*)
(sleep 0.3)
(multiple-value-bind (via why) (at glass:admission-admit *owner* nil)
  (ok "ADMIT answers (NIL :unreachable) — which no denial ever does" (and (null via)
                                                                          (eq :unreachable why))))
(multiple-value-bind (a why) (at glass:admission-allowed-p *owner*)
  (ok "ALLOWED-P answers NIL and says why, so warp shows a guest menu rather than a wrong one"
      (and (null a) (eq :unreachable why))))
(multiple-value-bind (rows why) (at glass:admission-devices)
  (ok "DEVICES answers NIL :unreachable and NOT an empty list — `none enrolled' is a different fact"
      (and (null rows) (eq :unreachable why))))
(ok "the gateway's own RFB bridge is unguarded, which is why fail-closed costs nothing:
        a peer admitted against a dead desktop gets a session that dies on GLASS-CONNECT"
    (let ((at (search "(setf glass (glass-connect)" *gateway*)))
      (and at (null (search "(ignore-errors (glass-connect)" *gateway*)))))

;;; ==============================================================================
(banner "the live enrolment file was never opened")
;;; ==============================================================================

(ok "the check is of a file that is really there — a vacuous one would prove nothing"
    (integerp *live-mtime*) *live*)
(ok "the live .glass-devices has exactly the mtime it had before this ran"
    (equal *live-mtime* (and (probe-file *live*) (file-write-date *live*)))
    (format nil "~a" *live-mtime*))
(ignore-errors (delete-file *fixture*))

(format t "~&~%~a passed, ~a failed~%" *pass* *fail*)
(finish-output)
(sb-ext:exit :code (if (zerop *fail*) 0 1))
