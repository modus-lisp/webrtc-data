;;;; check-deploy.lisp — answer "what is actually on the phone?" for the nsite deployment.
;;;;
;;;; A publish is four independent hops, and a break in any one of them looks identical from the
;;;; phone: the old page loads and nothing anywhere reports an error.  This walks the hops in order
;;;; and prints what each one holds, so the first mismatch names the broken hop.
;;;;
;;;;   build     the local nsite-index.html                       (sha256 = the blob id)
;;;;   Blossom   the blob is fetchable by that hash
;;;;   relays    a manifest naming that hash exists, on the relays the site itself advertises
;;;;   gateway   https://<npub>.nsite.lol/<path> actually serves it
;;;;
;;;;   sbcl --script check-deploy.lisp [/path/to/nsite-index.html]
;;;;
;;;; Read-only: it publishes nothing and needs no secret.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (let ((*standard-output* (make-broadcast-stream)))
    (asdf:load-system :cl-nostr)
    (asdf:load-system :dexador)
    (asdf:load-system :ironclad)))

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
      (string-downcase (ironclad:byte-array-to-hex-string (ironclad:digest-sequence :sha256 buf))))))

(defun %short (s &optional (n 16)) (if (and s (> (length s) n)) (subseq s 0 n) s))

(defun %http-head (url)
  "(values status sha256-of-body) — NIL status on any failure."
  (handler-case
      (multiple-value-bind (body status) (dex:get url :force-binary t :read-timeout 25)
        (values status
                (string-downcase (ironclad:byte-array-to-hex-string
                                  (ironclad:digest-sequence :sha256 body)))))
    (error (e) (values nil (princ-to-string e)))))

(defun %collect (relays filter &key (secs 7))
  (let ((pool (cl-nostr.pool:make-pool relays)) (rows '()))
    (sleep 3)                           ; the pool connects asynchronously — see DEPLOY.md
    (cl-nostr.pool:pool-subscribe
     pool (list filter)
     :on-event (lambda (ev relay) (declare (ignore relay))
                 (pushnew ev rows :key #'cl-nostr.event:event-id :test #'equal)))
    (sleep secs)
    rows))

(defun %tag-value (ev name)
  (let ((tg (find name (cl-nostr.event:event-tags ev) :key #'first :test #'equal)))
    (and tg (second tg))))

(let* ((pk (string-downcase (cl-nostr.util:bytes->hex (cl-nostr.bech32:npub-decode *site-npub*))))
       (want (and *build* (probe-file *build*) (%sha256-file *build*))))
  (format t "~&site  ~a~%      ~a~%" *site-npub* pk)

  ;; ---- 1. build -------------------------------------------------------------
  (if want
      (format t "~%[build]   ~a  ~a~%" (%short want) *build*)
      (format t "~%[build]   (no local build given — pass a path to nsite-index.html to compare)~%"))

  ;; ---- 2. Blossom -----------------------------------------------------------
  (when want
    (format t "~%[blossom]~%")
    (dolist (host *blossom*)
      (multiple-value-bind (status got) (%http-head (format nil "~a/~a" host want))
        (format t "   ~a~30t~@[http ~a~]~@[ ~a~]~a~%" host status
                (and status (%short got))
                (cond ((null status) " unreachable")
                      ((equal got want) "  MATCH")
                      (t "  *** WRONG BODY ***"))))))

  ;; ---- 3. relays ------------------------------------------------------------
  ;; Both kinds are checked: 15128 is what publish.lisp writes; 34128 is the legacy per-path form
  ;; some tools emit.  Either may be what a given gateway reads.
  (format t "~%[relays]  what the site advertises, and what the manifests point at~%")
  (let ((lists (%collect *relays* (cl-nostr.filter:make-filter
                                  :kinds '(10002 10063) :authors (list pk) :limit 4))))
    (dolist (ev lists)
      (format t "   kind ~a:~{ ~a~}~%" (cl-nostr.event:event-kind ev)
              (loop for tg in (cl-nostr.event:event-tags ev)
                    when (and (>= (length tg) 2) (member (first tg) '("r" "server") :test #'equal))
                      collect (second tg)))))
  (let ((manifests (%collect *relays* (cl-nostr.filter:make-filter
                                      :kinds '(15128) :authors (list pk) :limit 4))))
    (if (null manifests)
        (format t "   kind 15128: NONE FOUND — nothing was published, or not to these relays~%")
        (dolist (ev manifests)
          (format t "   kind 15128  created_at ~a~%" (cl-nostr.event:event-created-at ev))
          (loop for tg in (cl-nostr.event:event-tags ev)
                when (and (>= (length tg) 3) (equal (first tg) "path"))
                  do (format t "      ~a -> ~a~a~%" (second tg) (%short (third tg))
                             (if (and want (equal (third tg) want)) "  MATCH" ""))))))
  (let ((legacy (%collect *relays* (cl-nostr.filter:make-filter
                                   :kinds '(34128) :authors (list pk) :limit 20))))
    (when legacy
      (format t "   kind 34128 (legacy per-path): ~a event(s)~%" (length legacy))
      (dolist (ev (sort legacy #'string< :key (lambda (e) (or (%tag-value e "d") ""))))
        (format t "      ~a -> ~a~a~%" (%tag-value ev "d") (%short (%tag-value ev "x"))
                (if (and want (equal (%tag-value ev "x") want)) "  MATCH" "")))))

  ;; ---- 4. gateway -----------------------------------------------------------
  ;; The hop that has actually broken in practice: the relays hold the new manifest and the gateway
  ;; keeps serving an older one for hours, well past its advertised max-age.  Nothing in this repo
  ;; can fix that — see "If the gateway will not pick it up" in DEPLOY.md.
  (format t "~%[gateway]~%")
  (dolist (path '("/index.html" "/"))
    (multiple-value-bind (status got) (%http-head (format nil "https://~a.nsite.lol~a" *site-npub* path))
      (format t "   ~a~30thttp ~a  ~a~a~%" path status (%short got)
              (cond ((null want) "")
                    ((equal got want) "  MATCH — the gateway is current")
                    (t "  *** STALE — serving an older build ***")))))
  (format t "~%"))
