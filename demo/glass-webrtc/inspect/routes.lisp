;;;; inspect/routes.lisp — which routes does this gateway actually have?
;;;;
;;;; The failure this exists for: signalling succeeds, the phone authenticates,
;;;; an answer goes back, and then nothing — because ICE had no candidate anyone
;;;; could reach.  All you see is `srflx=NIL relay=NIL`, which does not say
;;;; whether STUN was blocked, the VPN ate the route, or the firewall is holding
;;;; a prompt nobody is at the keyboard to answer.
;;;;
;;;; So: try every route the gateway needs, each on a short deadline, and print a
;;;; table.  A host firewall that prompts per binary will show up as a row of
;;;; timeouts, which is the answer — approve those destinations for THIS sbcl and
;;;; run it again.
;;;;
;;;;   sbcl --script inspect/routes.lisp

(require :asdf)
(require :sb-bsd-sockets)

(defparameter *deadline* 4 "Seconds per probe.  Short: a hang is a result here.")

(defvar *rows* '())
(defun row (kind target verdict detail)
  (push (list kind target verdict detail) *rows*))

(defmacro with-deadline ((&key (seconds '*deadline*)) &body body)
  `(handler-case (sb-ext:with-timeout ,seconds ,@body)
     (sb-ext:timeout () :timeout)
     (error (e) (cons :error (princ-to-string e)))))

;;; ---- TCP ---------------------------------------------------------------------

(defun probe-tcp (host port)
  (with-deadline ()
    (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
      (unwind-protect
           (progn (sb-bsd-sockets:socket-connect
                   s (sb-bsd-sockets:host-ent-address
                      (sb-bsd-sockets:get-host-by-name host))
                   port)
                  :ok)
        (ignore-errors (sb-bsd-sockets:socket-close s))))))

;;; ---- STUN --------------------------------------------------------------------
;;; A binding request is 20 bytes: type, length, magic cookie, transaction id.
;;; Any answer at all proves the path; we only care that something came back.

(defun stun-request ()
  (let ((b (make-array 20 :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (aref b 0) #x00 (aref b 1) #x01)          ; Binding Request
    (setf (aref b 2) #x00 (aref b 3) #x00)          ; length 0
    (setf (aref b 4) #x21 (aref b 5) #x12           ; magic cookie 0x2112A442
          (aref b 6) #xa4 (aref b 7) #x42)
    (loop for i from 8 below 20 do (setf (aref b i) (random 256)))
    b))

(defun probe-stun (host port)
  (with-deadline ()
    (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :datagram :protocol :udp)))
      (unwind-protect
           (let ((addr (sb-bsd-sockets:host-ent-address
                        (sb-bsd-sockets:get-host-by-name host)))
                 (req (stun-request))
                 (buf (make-array 512 :element-type '(unsigned-byte 8))))
             (sb-bsd-sockets:socket-send s req (length req) :address (list addr port))
             (multiple-value-bind (data len peer) (sb-bsd-sockets:socket-receive s buf nil)
               (declare (ignore data peer))
               (if (and len (>= len 20)) :ok :short)))
        (ignore-errors (sb-bsd-sockets:socket-close s))))))

;;; ---- what the gateway needs ---------------------------------------------------

(defun relays ()
  (let ((env (sb-ext:posix-getenv "NOSTR_RELAYS")))
    (if (and env (plusp (length env)))
        (loop with start = 0 for i = (position #\, env :start start)
              collect (string-trim " " (subseq env start (or i (length env))))
              while i do (setf start (1+ i)))
        '("wss://relay.damus.io" "wss://nos.lol" "wss://relay.primal.net"))))

(defun host-of (url)
  (let* ((p (search "://" url))
         (rest (if p (subseq url (+ p 3)) url))
         (slash (position #\/ rest)))
    (if slash (subseq rest 0 slash) rest)))

(format t "~&probing every route the gateway needs (~ds each)~%~%" *deadline*)
(finish-output)

(dolist (r (relays))
  (let ((h (host-of r)))
    (row "relay (tcp 443)" h (probe-tcp h 443) "signalling — offers and answers")))

(dolist (s '(("stun.l.google.com" 19302) ("stun.cloudflare.com" 3478)))
  (row "STUN (udp)" (format nil "~a:~d" (first s) (second s))
       (probe-stun (first s) (second s))
       "our own public address — without it, srflx=NIL"))

(let ((turn (sb-ext:posix-getenv "TURN_SERVER")))
  (if turn
      (row "TURN (udp 3478)" turn (probe-stun turn 3478) "relayed media for hard NAT")
      (row "TURN" "(unset)" :skipped "no TURN_SERVER — cellular peers will fail")))

;; The client page the phone loads, and the NIP-05 host if one is configured.
(row "nsite (tcp 443)" "nsite.lol" (probe-tcp "nsite.lol" 443) "the phone fetches the client here")
(let ((allow (sb-ext:posix-getenv "NOSTR_ALLOW")))
  (when (and allow (find #\@ allow))
    (let ((dom (subseq allow (1+ (position #\@ allow)))))
      (row (format nil "NIP-05 (tcp 443)") dom (probe-tcp dom 443)
           "resolved at LOAD time with no timeout — a block hangs the gateway"))))

(format t "~&~va  ~va  ~a~%" 18 "route" 30 "target" "verdict")
(format t "~a~%" (make-string 78 :initial-element #\-))
(let ((bad 0))
  (dolist (r (reverse *rows*))
    (destructuring-bind (kind target verdict detail) r
      (let ((v (cond ((eq verdict :ok) "ok")
                     ((eq verdict :timeout) (incf bad) "TIMED OUT / blocked")
                     ((eq verdict :skipped) "skipped")
                     ((and (consp verdict) (eq (car verdict) :error))
                      (incf bad) (format nil "error: ~a" (subseq (cdr verdict) 0 (min 28 (length (cdr verdict))))))
                     (t (format nil "~a" verdict)))))
        (format t "~va  ~va  ~a~%" 18 kind 30 target v)
        (when (or (eq verdict :timeout) (consp verdict))
          (format t "~va  ~va  (~a)~%" 18 "" 30 "" detail)))))
  (format t "~%~[all routes open~:;~:*~d route(s) not usable~]~%" bad))
