;;;; unix-socket-test.lisp — the gateway reaching a desktop that has no ports.
;;;;
;;;;   sbcl --dynamic-space-size 4096 --non-interactive --load unix-socket-test.lisp
;;;;
;;;; The gateway opens FOUR sockets onto the desktop — the RFB bridge for the browser, a second
;;;; RFB client for the VP8 capture, the mix out, the microphone in — and asks a fifth question
;;;; over a fifth (admission: may this person connect at all).  All five were TCP on 127.0.0.1,
;;;; which is not a boundary: every process of every uid on the box can open a loopback port.
;;;; glass grew UNIX-domain transports for them; this checks that the gateway can USE them, and
;;;; that nothing about the TCP configuration moved.
;;;;
;;;; IT DOES NOT START A GATEWAY.  gateway-nostr.lisp is a running service on this box — loading
;;;; it would put a second one on the same npub, racing the live session for every offer.  So the
;;;; endpoint derivation is READ OUT OF THAT FILE and evaluated on its own (the real source text,
;;;; not a copy of it), the client halves are exercised against a fake desktop under /tmp, and
;;;; the three files are COMPILED to catch anything the reading did not.

(require :asdf)
(load "~/quicklisp/setup.lisp")
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system "webrtc-data")
    (asdf:load-system "webrtc-media/rtc")
    (asdf:load-system "glass/mic-stream")     ; brings :glass and :glass/audio-stream
    (asdf:load-system "glass/nostr")
    (asdf:load-system "cl-nostr")
    (ql:quickload '(:hunchentoot) :silent t)))

(defpackage #:gw-unix-test (:use #:cl)) (in-package #:gw-unix-test)

(defparameter *here* (uiop:pathname-directory-pathname
                      (or *load-pathname* *default-pathname-defaults*)))
;; glass-capture.lisp is a file of definitions and nothing else, so loading it is safe and is
;; what lets CAPTURE-CONNECT — the gateway's own VP8 client — be run for real below.
(handler-bind ((warning #'muffle-warning))
  (load (merge-pathnames "glass-capture.lisp" *here*)))

(defvar *pass* 0) (defvar *fail* 0)
(defun ok (name got &optional detail)
  (if got (progn (incf *pass*) (format t "  [pass] ~a~@[ — ~a~]~%" name detail))
      (progn (incf *fail*) (format t "  [FAIL] ~a~@[ — ~a~]~%" name detail)))
  (finish-output) got)
(defun head (s) (format t "~%== ~a ==~%" s) (finish-output))
(defun wait-for (test &key (seconds 10) (step 0.05))
  (let ((deadline (+ (get-internal-real-time) (round (* seconds internal-time-units-per-second)))))
    (loop for v = (funcall test)
          do (when v (return v))
             (when (> (get-internal-real-time) deadline) (return nil))
             (sleep step))))

;;; ---- a fake desktop, entirely under /tmp ------------------------------------

(defparameter *dir* (format nil "/tmp/gw-unix-test-~d/" (sb-posix:getpid)))
(setf glass:*runtime-dir* *dir*)
(defparameter *rfb-path* (glass:socket-path "seat-0.rfb"))
(defparameter *tcp-port* 5951 "A free port for the TCP half — never a live desktop's.")

(defparameter *fb* (glass:make-framebuffer 320 240 (glass:rgb 40 90 140)))
(defparameter *listener* (glass:open-listener :unix :path *rfb-path*))
(defparameter *tcp-listener* (glass:open-listener :tcp :port *tcp-port* :address "127.0.0.1"))
(sb-thread:make-thread (lambda () (ignore-errors (glass:serve *fb* 0 :listen *listener*
                                                                    :install-injector nil)))
                       :name "fake-desktop-unix")
(sb-thread:make-thread (lambda () (ignore-errors (glass:serve *fb* *tcp-port* :listen *tcp-listener*
                                                                             :install-injector nil)))
                       :name "fake-desktop-tcp")
(glass:mixer-start (glass:session-mixer))
(defparameter *audio* (glass:start-audio-stream :path (glass:socket-sibling *rfb-path* "audio")))
(defparameter *mic* (glass:start-mic-stream :path (glass:socket-sibling *rfb-path* "mic")))
(setf glass:*box-secret* "2222222222222222222222222222222222222222222222222222222222222222"
      glass:*enrolment-file* (format nil "~agw-devices" *dir*))
(defparameter *admit* (glass:start-admission-service
                       :path (glass:socket-sibling *rfb-path* "admit") :install nil))
(sleep 0.3)

;;; ---- the endpoint derivation, read out of the live gateway source -----------

(defun gateway-forms (file names)
  "The DEFPARAMETER/DEFUN forms in FILE that define NAMES, in file order.

   Read, not loaded: gateway-nostr.lisp is a service, and evaluating the whole of it would put a
   second gateway on the same npub as the running one.  Reading every form also happens to be a
   syntax check of the entire file, which is worth having for free."
  (let ((out '()) (*package* (find-package :webrtc-data)) (*read-eval* nil))
    (with-open-file (in file)
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            do (when (and (consp form) (member (first form) '(defparameter defvar defun))
                          (member (symbol-name (second form)) names :test #'string=))
                 (push form out))))
    (nreverse out)))

(defparameter *gw-file* (namestring (merge-pathnames "gateway-nostr.lisp" *here*)))
(defparameter *endpoint-forms*
  (gateway-forms *gw-file* '("*GLASS-HOST*" "*GLASS-PORT*" "*GLASS-PATH*" "GLASS-ENDPOINT")))

(head "gateway-nostr.lisp reads, and its endpoint derivation is these four forms")
(ok "the whole file parses" (plusp (length *endpoint-forms*))
    (format nil "~d endpoint forms found" (length *endpoint-forms*)))

(defun endpoints-for (glass-host &optional (glass-port "5903"))
  "Evaluate the gateway's own derivation with GLASS_HOST set, and return the four endpoints."
  (sb-posix:putenv (format nil "GLASS_HOST=~a" glass-host))
  (sb-posix:putenv (format nil "GLASS_PORT=~a" glass-port))
  (dolist (e '("GLASS_AUDIO_HOST" "GLASS_MIC_HOST" "GLASS_ADMISSION_HOST"))
    (ignore-errors (sb-posix:unsetenv e)))
  (let ((*package* (find-package :webrtc-data)))
    (dolist (f *endpoint-forms*) (eval f))
    (let ((ep (find-symbol "GLASS-ENDPOINT" :webrtc-data)))
      (list :rfb (symbol-value (find-symbol "*GLASS-HOST*" :webrtc-data))
            :audio (funcall ep "GLASS_AUDIO_HOST" "audio" 5913)
            :mic   (funcall ep "GLASS_MIC_HOST" "mic" 5914)
            :admit (funcall ep "GLASS_ADMISSION_HOST" "admit" 5915)))))

(head "a TCP GLASS_HOST derives exactly what it always did")
(let ((e (endpoints-for "127.0.0.1")))
  (ok "the screen is the host it was given" (equal (getf e :rfb) "127.0.0.1") (getf e :rfb))
  (ok "…and the mix follows it, on its port beside it" (equal (getf e :audio) "127.0.0.1"))
  (ok "…and the microphone" (equal (getf e :mic) "127.0.0.1"))
  (ok "…and admission" (equal (getf e :admit) "127.0.0.1")
      "5903 -> 5913 / 5914 / 5915, unchanged"))

(head "a socket-file GLASS_HOST derives the names beside it")
(let ((e (endpoints-for (format nil "unix:~a" *rfb-path*))))
  (ok "the screen is the socket file" (equal (getf e :rfb) (format nil "unix:~a" *rfb-path*))
      (getf e :rfb))
  (ok "…the mix is the name beside it"
      (equal (getf e :audio) (format nil "unix:~a" (glass:socket-sibling *rfb-path* "audio")))
      (getf e :audio))
  (ok "…the microphone likewise"
      (equal (getf e :mic) (format nil "unix:~a" (glass:socket-sibling *rfb-path* "mic")))
      (getf e :mic))
  (ok "…and admission"
      (equal (getf e :admit) (format nil "unix:~a" (glass:socket-sibling *rfb-path* "admit")))
      (getf e :admit))
  (ok "…so ONE line of gw-keepalive.sh moves all four"
      (every (lambda (k) (eql 0 (search "unix:" (getf e k)))) '(:rfb :audio :mic :admit))))

(head "…and an explicit GLASS_AUDIO_HOST still wins over the derivation")
(let ((e (progn (endpoints-for (format nil "unix:~a" *rfb-path*))
                (sb-posix:putenv "GLASS_AUDIO_HOST=unix:/tmp/somewhere-else.sock")
                (let ((ep (find-symbol "GLASS-ENDPOINT" :webrtc-data)))
                  (funcall ep "GLASS_AUDIO_HOST" "audio" 5913)))))
  (ok "an operator who put a socket somewhere unusual can say so"
      (equal e "unix:/tmp/somewhere-else.sock") e))
(ignore-errors (sb-posix:unsetenv "GLASS_AUDIO_HOST"))

;;; ---- the four clients, against the fake desktop -----------------------------

(head "the gateway's own clients, over socket files")

;; 1. the browser's RFB bridge — GLASS-CONNECT, whose whole body is now OPEN-CONNECTION
(let ((sock (glass:open-connection :host (format nil "unix:~a" *rfb-path*) :port 0)))
  (multiple-value-bind (s stream) (values sock nil)
    (declare (ignore s stream)))
  (let ((buf (make-array 12 :element-type '(unsigned-byte 8))))
    (multiple-value-bind (b n) (sb-bsd-sockets:socket-receive sock buf nil)
      (declare (ignore b))
      (ok "the RFB bridge reads RFB 003.008 off a socket file with SOCKET-RECEIVE"
          (and (eql n 12) (string= "RFB 003.008" (map 'string #'code-char (subseq buf 0 11))))
          (map 'string #'code-char (subseq buf 0 11)))))
  (ignore-errors (sb-bsd-sockets:socket-close sock)))

;; 2. the VP8 capture — the gateway's SECOND RFB client, its real handshake
(let ((cap (webrtc-data::capture-connect (format nil "unix:~a" *rfb-path*) 0)))
  (ok "CAPTURE-CONNECT handshakes over a socket file and learns the desktop's size"
      (and cap (eql 320 (webrtc-data::cap-width cap)) (eql 240 (webrtc-data::cap-height cap)))
      (format nil "~ax~a" (webrtc-data::cap-width cap) (webrtc-data::cap-height cap)))
  (ignore-errors (close (webrtc-data::cap-socket cap))))
(let ((cap (webrtc-data::capture-connect "127.0.0.1" *tcp-port*)))
  (ok "…and over a port, unchanged"
      (and cap (eql 320 (webrtc-data::cap-width cap)))
      (format nil "~ax~a" (webrtc-data::cap-width cap) (webrtc-data::cap-height cap)))
  (ignore-errors (close (webrtc-data::cap-socket cap))))

;; 3. the mix out
(let ((tap (glass:make-audio-tap :host (format nil "unix:~a" (glass:socket-sibling *rfb-path* "audio"))
                                 :port 5913 :rate 8000 :frame-samples 160 :name "gw-test")))
  (ok "the audio tap — what feeds the phone's ear — connects over a socket file"
      (wait-for (lambda () (glass:audio-tap-connected tap))))
  (ok "…and frames arrive" (wait-for (lambda () (glass:tap-next-frame tap))) (glass:tap-report tap))
  (glass:tap-stop tap))

;; 4. the microphone in
(let ((sender (glass:make-mic-sender :host (format nil "unix:~a" (glass:socket-sibling *rfb-path* "mic"))
                                     :port 5914 :rate 8000 :frame-samples 160 :name "gw-test")))
  (ok "the mic sender — what carries the phone's voice — connects over a socket file"
      (wait-for (lambda () (glass:mic-sender-connected sender))))
  (let ((pcm (reed:make-pcm16 800)))
    (dotimes (i 800) (setf (aref pcm i) (round (* 6000 (sin (/ i 5.0))))))
    (dotimes (i 5) (glass:mic-send sender pcm) (sleep 0.02)))
  (ok "…and the desktop end receives what it sent"
      (wait-for (lambda () (let ((m (glass:mic-stream-current *mic*)))
                             (and m (plusp (glass:mic-received m))))))
      (glass:mic-stream-report *mic*))
  (glass:mic-sender-stop sender))

;; 5. admission — the question the gateway FAILS CLOSED on
(let ((posture (glass:admission-ping :host (format nil "unix:~a" (glass:socket-sibling *rfb-path* "admit"))
                                     :port 5915)))
  (ok "the desktop answers `who may connect' over a socket file" posture (format nil "~a" posture))
  (ok "…and the answer is the desktop's own identity, which is what fails closed without it"
      (equal (getf posture :box) (glass:box-pubkey))))

(head "and the desktop it is talking to has no ports at all")
(defun sh (fmt &rest args)
  (string-trim '(#\Newline #\Space)
               (with-output-to-string (s)
                 (sb-ext:run-program "/bin/sh" (list "-c" (apply #'format nil fmt args))
                                     :output s :error nil :search nil))))
(ok "`ss -x' shows the four socket files listening"
    (eql 4 (ignore-errors (parse-integer (sh "ss -lxH 2>/dev/null | grep -c ~aseat-0" *dir*))))
    (sh "ss -lxH 2>/dev/null | grep ~aseat-0 | awk '{print $5}' | tr '\\n' ' '" *dir*))
(ok "…and `ss -ltn' shows the desktop on no port but the one this test opened for comparison"
    (eql 1 (ignore-errors (parse-integer (sh "ss -ltnH 2>/dev/null | grep -c ':~d '" *tcp-port*))))
    (sh "ss -ltnH 2>/dev/null | grep ':~d ' | awk '{print $4}'" *tcp-port*))
(ok "…each at mode 0600, owner-only, checked by the kernel on connect()"
    (every (lambda (n) (eql #o600 (logand (sb-posix:stat-mode
                                           (sb-posix:stat (glass:socket-sibling *rfb-path* n)))
                                          #o777)))
           '("audio" "mic" "admit"))
    (sh "stat -c '%a %n' ~a*" *dir*))

;;; ---- compile the three files that changed -----------------------------------

(head "the three files compile")

(defparameter *known-undefined*
  '("*LAST-ERROR*"                          ; defvar'd further down gateway-nostr.lisp than its use
    "*WARP-CHANNEL-ENABLED*" "*WARP-BUDGET*" "*WARP-HZ*" "+WARP-STREAM-ID+"
    "*PAYLOAD-CHANNEL-ENABLED*" "*PAYLOAD-FILE*" "*PAYLOAD-CHUNK*" "+PAYLOAD-STREAM-ID+")
  "Undefined variables gateway-nostr.lisp has warned about since before this change: one forward
   reference, and eight from warp-channel.lisp / payload-channel.lisp, which the gateway LOADS AT
   RUNTIME behind an env-var guard and so cannot have compiled here.  Listed rather than tolerated
   by count, so a NEW one fails this check instead of hiding in a number.")

(dolist (f '("gateway-nostr.lisp" "gateway.lisp" "glass-capture.lisp"))
  (let ((path (merge-pathnames f *here*))
        (out (format nil "~a~a.fasl" *dir* (pathname-name f)))
        (errors 0))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (incf errors)))
                   (warning (lambda (c)
                              (unless (or (typep c 'style-warning)
                                          (let ((text (princ-to-string c)))
                                            (some (lambda (k) (search k text)) *known-undefined*)))
                                (incf errors))
                              (muffle-warning c))))
      (let ((*standard-output* (make-broadcast-stream))
            (*error-output* (make-broadcast-stream))
            (*package* (find-package :webrtc-data)))
        ;; COMPILE, not LOAD: compiling evaluates none of the top level, so no gateway starts,
        ;; no relay is subscribed to and no socket is opened.  What it does catch is every
        ;; undefined variable, wrong arity and unbalanced form in the file.
        (ignore-errors (compile-file path :output-file out :verbose nil :print nil))))
    (ok (format nil "~a compiles with no errors and no NEW warnings" f) (zerop errors)
        (format nil "~d unexpected" errors))))

;;; ---- teardown ---------------------------------------------------------------

(glass:stop-audio-stream *audio*)
(glass:stop-mic-stream *mic*)
(glass:stop-admission-service *admit*)
(glass:close-listener *listener*)
(glass:close-listener *tcp-listener*)

(head "nothing outside /tmp was written")
(ok "everything this test made is under /tmp" (eql 0 (search "/tmp/" *dir*)) *dir*)
(ok "…and the gateway's own enrolment store was never opened"
    (not (equal glass:*enrolment-file*
                (namestring (merge-pathnames ".glass-devices" *here*))))
    glass:*enrolment-file*)

(format t "~%~d passed, ~d failed~%~%=> ~:[FAIL~;PASS~]~%" *pass* *fail* (zerop *fail*))
(finish-output)
(sb-ext:run-program "/bin/sh" (list "-c" (format nil "rm -rf ~a" *dir*)) :search nil)
(sb-ext:exit :code (if (plusp *fail*) 1 0))
