(require :asdf)(load "~/quicklisp/setup.lisp")
(handler-bind ((warning #'muffle-warning))(let ((*standard-output*(make-broadcast-stream)))(ql:quickload :cl-nostr)))
(defpackage :pub (:use :cl)) (in-package :pub)

;;;; publish.lisp — build a blob onto Blossom, then point the nsite manifest at it.
;;;;
;;;;   SITE_VERSION=k30 sbcl --script publish.lisp [/path/to/nsite-index.html]
;;;;
;;;; THE SITE KEY IS NOT IN THIS FILE.  It is the site's whole identity — whoever holds it can
;;;; replace every page served at that npub — so it is resolved at runtime, in this order:
;;;;
;;;;   1. $SITE_SEC                (64 hex)
;;;;   2. ~/.glass/site-key        (64 hex, mode 600)
;;;;
;;;; and the script refuses to run if neither is present, rather than falling back to anything.
;;;; That is what lets this file live in the repo at all.
;;;;
;;;; Everything that used to be hand-rolled here — bounding each upload, fanning out across the
;;;; Blossom servers, waiting for the relays instead of guessing, publishing the kind-10002 and
;;;; kind-10063 discovery lists — now lives in CL-NOSTR.NSITE:NSITE-PUBLISH, which reports what
;;;; every server and every relay did.  This file is the site's policy: which key, which servers,
;;;; which paths, and what to tell the operator.

(defun %trim (s) (string-trim '(#\Space #\Tab #\Newline #\Return) (or s "")))

(defun %read-key-file (path)
  (handler-case
      (with-open-file (s path :if-does-not-exist nil)
        (and s (%trim (read-line s nil ""))))
    (error () nil)))

(defparameter *site*
  (let* ((env (%trim (sb-posix:getenv "SITE_SEC")))
         (file (%read-key-file (merge-pathnames ".glass/site-key" (user-homedir-pathname))))
         (key (if (plusp (length env)) env file)))
    (unless (and key (= 64 (length key)) (every (lambda (c) (digit-char-p c 16)) key))
      (format *error-output*
              "~&publish: no site key.  Put the 64-hex secret in ~~/.glass/site-key (chmod 600)~%~
                 or pass it as SITE_SEC.  Refusing to publish without it.~%")
      (finish-output *error-output*)
      (sb-ext:exit :code 2))
    key))

(defparameter *blossom* '("https://cdn.hzrd149.com" "https://blossom.primal.net" "https://nostr.download"))
(defparameter *relays* '("wss://relay.damus.io" "wss://nos.lol" "wss://relay.primal.net"))
(defparameter *lookup* '("wss://purplepag.es" "wss://user.kindpag.es"))
;; The built artefact: argv, then $NSITE_BUILD, then a build dir beside this script.  Nothing here
;; is machine-specific, so the file is portable between checkouts.
(defparameter *path*
  (or (second sb-ext:*posix-argv*)
      (let ((e (%trim (sb-posix:getenv "NSITE_BUILD")))) (and (plusp (length e)) e))
      (namestring (merge-pathnames "nsite-build/nsite-index.html"
                                   (or *load-truename* *default-pathname-defaults*)))))
;; A VERSIONED PATH, not a ?v= query.  An nsite gateway resolves a request by PATH against the
;; kind-15128 manifest, so a query string selects the same blob and the browser is free to serve its
;; cached copy — which is why ?v= never busted anything.  Publishing each build at its own path makes
;; every version a distinct URL that cannot be mistaken for the previous one.
(defparameter *version* (or (sb-posix:getenv "SITE_VERSION") "latest"))
(defun read-bytes (p)
  (with-open-file (s p :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8)))) (read-sequence v s) v)))

(defun %short (s &optional (n 16)) (if (and s (> (length s) n)) (subseq s 0 n) s))

(let* ((kp (cl-nostr.keys:keypair-from-secret *site*))
       (bytes (read-bytes *path*)))
  (format t "~&bundle: ~a bytes~%" (length bytes))
  (multiple-value-bind (npub report)
      (cl-nostr.nsite:nsite-publish
       ;; publish to the lookup relays too, but advertise only the read relays in kind 10002
       (append *relays* *lookup*) *blossom* kp
       (list (cons (format nil "/~a.html" *version*) bytes)
             (cons "/index.html" bytes)
             (cons "/" bytes))
       :relays *relays* :title "glass over WebRTC" :content-type "text/html"
       ;; ONE upload per DISTINCT blob (all three paths are the same bytes), to every server at
       ;; once, EACH INDIVIDUALLY BOUNDED.  One of these servers reliably hangs rather than
       ;; refusing, and an unbounded upload once sat on a single POST for twenty minutes — the
       ;; blob went live and nothing ever pointed at it.  One success is enough.
       :on-upload
       (lambda (up)
         (if (cl-nostr.blossom:upload-ok-p up)
             (format t "~&[blossom] ~a -> ~a~%" (cl-nostr.blossom:upload-server up)
                     (%short (cl-nostr.blossom:upload-hash up)))
             (format t "~&[blossom] ~a SKIPPED: ~a~%" (cl-nostr.blossom:upload-server up)
                     (cl-nostr.blossom:upload-error up))))
       ;; NSITE-PUBLISH waits for each relay's OK rather than publishing and hoping: a websocket
       ;; swallows a send on a dead socket without a word, so the reply is the only evidence the
       ;; event landed.  Two publishes were lost before that was true — see DEPLOY.md.  A relay
       ;; that blocks by policy is fine; ZERO accepted=T lines means nothing was published.
       :on-publish
       (lambda (pub)
         (when (= (cl-nostr.nsite:publication-kind pub) cl-nostr.nsite:+kind-nsite-root+)
           (dolist (ack (cl-nostr.nsite:publication-acks pub))
             (format t "~&[manifest] ~a accepted=~a ~a~%"
                     (cl-nostr.pool:ack-url ack)
                     (if (cl-nostr.pool:ack-accepted-p ack) "T" "NIL")
                     (or (cl-nostr.pool:ack-message ack) ""))))))
    ;; No server took the blob: NSITE-PUBLISH has already declined to move the manifest, because a
    ;; manifest naming a blob nobody holds is how a live site goes dark.
    (unless (cl-nostr.nsite:report-stored-p report)
      (format t "~&NO BLOSSOM ACCEPTED~%")
      (sb-ext:exit :code 1))
    (let ((hash (cdr (first (cl-nostr.nsite:report-paths report)))))
      (format t "~&[done] site hash ~a~%[done] versioned path: /~a.html~%" hash *version*)
      (dolist (problem (cl-nostr.nsite:report-problems report))
        (format t "[done] WARNING: ~a~%" problem)))
    ;; Hand the freshly published path to the gateway, rather than expecting someone to remember.
    ;; Publishing REPLACES the manifest, so the previous /<tag>.html stops resolving the moment this
    ;; one lands — a login link minted against it 404s, which is indistinguishable from the box being
    ;; down.  The keepalive re-sources this file on every gateway start, the same way it picks up
    ;; video-profile.env, so a publish plus the next restart is enough.
    (let ((envf (namestring (merge-pathnames "site-url.env"
                                             (or *load-truename* *default-pathname-defaults*)))))
      (with-open-file (o envf :direction :output :if-exists :supersede :if-does-not-exist :create)
        (format o "# written by publish.lisp — the path published most recently.  Do not hand-edit.~%")
        (format o "export LOGIN_URL_BASE='~a'~%"
                (cl-nostr.nsite:nsite-gateway-url npub (format nil "/~a.html" *version*))))
      (format t "[done] wrote ~a~%" envf))))
(sb-ext:exit)
