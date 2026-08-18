;;;; check-deploy.lisp — answer "what is actually on the phone?" for the nsite deployment.
;;;;
;;;; A publish is four independent hops, and a break in any one of them looks identical from the
;;;; phone: the old page loads and nothing anywhere reports an error.  This walks the hops in order
;;;; and prints what each one holds, so the first mismatch names the broken hop.
;;;;
;;;;   build     the local nsite-index.html                       (sha256 = the blob id)
;;;;   Blossom   the blob is fetchable by that hash
;;;;   relays    a manifest naming that hash exists, on the relays the site itself advertises
;;;;   gateway   https://<npub>.nsite.{run,lol}/<path> actually serves it -- BOTH, they disagree
;;;;
;;;;   sbcl --script check-deploy.lisp [/path/to/nsite-index.html]
;;;;
;;;; Read-only: it publishes nothing and needs no secret.  Every hop below is one call into
;;;; CL-NOSTR.NSITE's resolve half — the same functions any client reading this site would use,
;;;; which is the point: if they answer here, a reader gets the same answer.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :cl-nostr)))

(defpackage :chk (:use :cl)
  (:local-nicknames (:u :cl-nostr.util) (:pool :cl-nostr.pool)
                    (:blossom :cl-nostr.blossom) (:nsite :cl-nostr.nsite)))
(in-package :chk)

(defparameter *site-npub*
  (or (uiop:getenv "NSITE_NPUB")
      "npub1ajvjnhgcmdxkng22lzsh22qvl63es78gk6p9mwksepju974teguq4l4evc"))
(defparameter *build*
  (or (second sb-ext:*posix-argv*)
      (uiop:getenv "NSITE_BUILD")))
;; Where to look.  The site's own kind-10002 list is authoritative for where a gateway SHOULD look;
;; these are just the ones we can ask directly.
(defparameter *relays* '("wss://relay.damus.io" "wss://nos.lol" "wss://relay.primal.net"))
(defparameter *blossom* '("https://cdn.hzrd149.com" "https://blossom.primal.net"))

(defun %sha256-file (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence buf s)
      (u:bytes->hex (u:sha256 buf)))))

(defun %short (s &optional (n 16)) (if (and s (> (length s) n)) (subseq s 0 n) s))

(let* ((pk (cl-nostr.bech32:pubkey-hex *site-npub*))
       (want (and *build* (probe-file *build*) (%sha256-file *build*)))
       ;; One pool for every relay question below, rather than four.
       (pool (pool:make-pool *relays*)))
  (format t "~&site  ~a~%      ~a~%" *site-npub* pk)

  ;; ---- 1. build -------------------------------------------------------------
  (if want
      (format t "~%[build]   ~a  ~a~%" (%short want) *build*)
      (format t "~%[build]   (no local build given — pass a path to nsite-index.html to compare)~%"))

  ;; ---- 2. Blossom -----------------------------------------------------------
  ;; BLOSSOM-DOWNLOAD hashes the body and compares: a mirror serving the wrong bytes under the
  ;; right hash is a distinct failure from a mirror that does not have it, and says so.
  (when want
    (format t "~%[blossom]~%")
    (dolist (host *blossom*)
      (let ((fetch (blossom:blossom-download host want :timeout 25)))
        (format t "   ~a~30t~@[http ~a~]~@[ ~a~]~a~%" host
                (blossom:fetch-status fetch)
                (%short (blossom:fetch-sha256 fetch))
                (cond ((blossom:fetch-ok-p fetch) "  MATCH")
                      ((null (blossom:fetch-sha256 fetch)) " unreachable")
                      (t "  *** WRONG BODY ***"))))))

  ;; ---- 3. relays ------------------------------------------------------------
  ;; Both kinds are checked: 15128 is what publish.lisp writes; 34128 is the legacy per-path form
  ;; some tools emit.  Either may be what a given gateway reads.
  (format t "~%[relays]  what the site advertises, and what the manifests point at~%")
  (format t "   kind 10002:~{ ~a~}~%" (nsite:nsite-relays pool pk))
  ;; MANIFESTS, plural: 15128 is replaceable so the relays should agree, and when one is still
  ;; serving last week's manifest that disagreement is the whole diagnosis.
  (let ((manifests (nsite:nsite-fetch-manifests pool pk :timeout 7)))
    (format t "   kind 10063:~{ ~a~}~%"
            (nsite:nsite-servers pool pk :manifest (first manifests)))
    (if (null manifests)
        (format t "   kind 15128: NONE FOUND — nothing was published, or not to these relays~%")
        (dolist (manifest manifests)
          (format t "   kind 15128  created_at ~a~%" (cl-nostr.event:event-created-at manifest))
          (loop for (path . hash) in (nsite:manifest-paths manifest)
                do (format t "      ~a -> ~a~a~%" path (%short hash)
                           (if (and want (equal hash want)) "  MATCH" ""))))))
  (let ((legacy (nsite:nsite-fetch-legacy pool pk :timeout 7 :limit 20)))
    (when legacy
      (format t "   kind 34128 (legacy per-path): ~a pointer(s)~%" (length legacy))
      (dolist (pointer (sort (copy-list legacy) #'string< :key #'car))
        (format t "      ~a -> ~a~a~%" (car pointer) (%short (cdr pointer))
                (if (and want (equal (cdr pointer) want)) "  MATCH" "")))))
  (pool:close-pool pool)

  ;; ---- 4. gateway -----------------------------------------------------------
  ;; The hop that has actually broken in practice: the relays hold the new manifest and the gateway
  ;; keeps serving an older one for hours, well past its advertised max-age.  Nothing in this repo
  ;; can fix that — see "If the gateway will not pick it up" in DEPLOY.md.
  ;; BOTH gateways, because checking only one has twice produced the wrong verdict: nsite.lol has
  ;; been stale for several builds running while nsite.run resolves the current manifest, so a
  ;; single-host check reported a broken deploy that was in fact fine everywhere it was being read
  ;; from.  Whichever host the link points at is the one whose line matters.
  (format t "~%[gateway]~%")
  (dolist (host '("nsite.run" "nsite.lol"))
    (dolist (path (list (format nil "/~a.html" (or (uiop:getenv "SITE_VERSION") "index")) "/index.html" "/"))
      (let ((fetch (nsite:nsite-gateway-fetch *site-npub* path
                                              :gateway host :expect want :timeout 25)))
        (format t "   ~a~12t~a~34thttp ~a  ~a~a~%" host path
                (blossom:fetch-status fetch)
                (%short (or (blossom:fetch-sha256 fetch) (blossom:fetch-error fetch)))
                (cond ((null want) "")
                      ((blossom:fetch-ok-p fetch) "  MATCH — this gateway is current")
                      ;; nothing came back at all: this gateway is unreadable, which is a
                      ;; different fault from serving the wrong build, and naming the wrong
                      ;; one is exactly the mistake this script exists to prevent.
                      ((null (blossom:fetch-sha256 fetch))
                       "  *** NO ANSWER — could not read this gateway ***")
                      (t "  *** STALE — serving an older build ***"))))))
  (format t "~%"))
