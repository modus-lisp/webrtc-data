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
(let* ((kp (cl-nostr.keys:keypair-from-secret *site*))
       (bytes (read-bytes *path*)) (hash nil))
  (format t "~&bundle: ~a bytes~%" (length bytes))
  (dolist (srv *blossom*)
    (handler-case
        ;; BOUND EACH UPLOAD.  blossom-upload takes no timeout and one of these servers reliably
        ;; hangs rather than refusing — a publish sat on a single POST for twenty minutes and never
        ;; reached the manifest, so the blob was live and nothing pointed at it.  One success is
        ;; enough; a server that will not answer promptly is simply skipped.
        (multiple-value-bind (h) (sb-ext:with-timeout 45
                                   (cl-nostr.blossom:blossom-upload srv bytes kp :content-type "text/html"))
          (setf hash h) (format t "~&[blossom] ~a -> ~a~%" srv (subseq h 0 16)))
      ;; SERIOUS-CONDITION, not ERROR: SB-EXT:TIMEOUT is not an ERROR subtype, so an (ERROR (e))
      ;; clause lets it straight through and the whole publish dies after the good uploads.
      (serious-condition (e) (format t "~&[blossom] ~a SKIPPED: ~a~%" srv (type-of e)))))
  (unless hash (format t "~&NO BLOSSOM ACCEPTED~%") (sb-ext:exit :code 1))
  (let ((pool (cl-nostr.pool:make-pool (append *relays* *lookup*))))
    ;; make-pool connects asynchronously: publishing immediately drops the event on relays whose
    ;; socket is not up yet, and pool-publish reports nothing, so the script still prints [done].
    ;; Wait for the sockets, and log each relay's OK so a silent loss is visible.
    (sleep 3)
    (cl-nostr.pool:pool-publish pool
      (cl-nostr.nsite:nsite-manifest kp (list (cons (format nil "/~a.html" *version*) hash)
                                              (cons "/index.html" hash) (cons "/" hash))
                                     :servers *blossom* :title "glass over WebRTC")
      :on-ok (lambda (relay ok msg)
               (format t "~&[manifest] ~a accepted=~a ~a~%"
                       (cl-nostr.relay:relay-url relay) ok (or msg ""))))
    (cl-nostr.pool:pool-publish pool
      (cl-nostr.event:build-event kp 10002 "" :tags (mapcar (lambda (r) (list "r" r)) *relays*)))
    (cl-nostr.pool:pool-publish pool
      (cl-nostr.event:build-event kp 10063 "" :tags (mapcar (lambda (s) (list "server" s)) *blossom*)))
    (sleep 4)
    (format t "~&[done] site hash ~a~%[done] versioned path: /~a.html~%" hash *version*)
    ;; Hand the freshly published path to the gateway, rather than expecting someone to remember.
    ;; Publishing REPLACES the manifest, so the previous /<tag>.html stops resolving the moment this
    ;; one lands — a login link minted against it 404s, which is indistinguishable from the box being
    ;; down.  The keepalive re-sources this file on every gateway start, the same way it picks up
    ;; video-profile.env, so a publish plus the next restart is enough.
    (let ((envf (namestring (merge-pathnames "site-url.env"
                                             (or *load-truename* *default-pathname-defaults*)))))
      (with-open-file (o envf :direction :output :if-exists :supersede :if-does-not-exist :create)
        (format o "# written by publish.lisp — the path published most recently.  Do not hand-edit.~%")
        (format o "export LOGIN_URL_BASE='https://~a.nsite.lol/~a.html'~%"
                (cl-nostr.bech32:npub-encode (cl-nostr.keys:public-key-of-secret *site*))
                *version*))
      (format t "[done] wrote ~a~%" envf))))
(sb-ext:exit)
