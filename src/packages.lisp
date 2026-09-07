;;;; webrtc-data — a from-scratch WebRTC data-channel peer in pure Common Lisp.
;;;;
;;;; The goal: a browser (or aiortc) opens an RTCDataChannel to us with no plugins — so we
;;;; implement the answerer side of the stack it expects: SDP, ICE (STUN connectivity), DTLS
;;;; 1.2, and SCTP + DCEP.  Data channels only (no SRTP / no video codec) — the framebuffer
;;;; and input for `glass` ride the data channel.  Crypto via ironclad + seal; UDP via
;;;; sb-bsd-sockets.  Tested against aiortc (a spec-compliant peer), then a real browser.

(defpackage #:webrtc-data
  (:use #:cl)
  (:local-nicknames (#:ic #:ironclad) (#:bt #:bordeaux-threads))
  ;; ---- STUN and TURN now live in cl-transport ------------------------------------
  ;; They are the IETF connectivity stack and not WebRTC's: they predate it, SIP uses
  ;; them, and this library is one CONSUMER.  ice.lisp is the only file here that ever
  ;; named them -- measured, not assumed -- so the whole cost of the move is this list.
  ;; IMPORTED rather than package-USEd, so what came from where stays greppable and a
  ;; name added upstream cannot silently start shadowing one of ours.  The byte helpers
  ;; are deliberately NOT imported: util.lisp still defines them here for dtls and sctp,
  ;; and importing would be a name conflict rather than a saving.
  (:import-from #:cl-transport.ice
                #:+attr-channel-number+ #:+attr-data+ #:+attr-error-code+ #:+attr-fingerprint+
                #:+attr-ice-controlled+ #:+attr-ice-controlling+ #:+attr-lifetime+ #:+attr-message-integrity+
                #:+attr-nonce+ #:+attr-priority+ #:+attr-realm+ #:+attr-requested-transport+
                #:+attr-software+ #:+attr-use-candidate+ #:+attr-username+ #:+attr-xor-mapped-address+
                #:+attr-xor-peer-address+ #:+attr-xor-relayed-address+ #:+binding-request+ #:+binding-success+
                #:+stun-magic+ #:+turn-allocate+ #:+turn-allocate-error+ #:+turn-allocate-success+
                #:+turn-channel-bind+ #:+turn-channel-bind-success+ #:+turn-channel-max+ #:+turn-channel-min+
                #:+turn-create-perm+ #:+turn-create-perm-success+ #:+turn-data-indication+ #:+turn-refresh+
                #:+turn-refresh-success+ #:+turn-send-indication+ #:crc32 #:decode-stun
                #:encode-stun #:hmac-sha1 #:make-turn-alloc #:parse-xor-mapped-address
                #:stun-attr #:stun-transaction-id #:stun-username-key #:turn-alloc
                #:turn-alloc-binding #:turn-alloc-chan->peer #:turn-alloc-key #:turn-alloc-lifetime
                #:turn-alloc-mapped-ip #:turn-alloc-mapped-port #:turn-alloc-next-channel #:turn-alloc-nonce
                #:turn-alloc-p #:turn-alloc-pass #:turn-alloc-peer->chan #:turn-alloc-perms
                #:turn-alloc-realm #:turn-alloc-refresh-thread #:turn-alloc-relay-ip #:turn-alloc-relay-port
                #:turn-alloc-resp #:turn-alloc-resp-cv #:turn-alloc-resp-lock #:turn-alloc-server-host
                #:turn-alloc-server-port #:turn-alloc-socket #:turn-alloc-user #:turn-allocate
                #:turn-channel-bind #:turn-channeldata-p #:turn-create-permission #:turn-deliver-control
                #:turn-install-peer #:turn-long-term-key #:turn-refresh #:turn-refresh-via-loop
                #:turn-start-refresh #:turn-wrap-channeldata #:turn-wrap-send-indication #:xor-mapped-address
                #:%turn-txn-loop #:%from-turn-server-p)
  (:export #:parse-sdp #:make-answer-sdp #:sdp-session
           #:sdp-ice-ufrag #:sdp-ice-pwd #:sdp-fingerprint #:sdp-setup
           #:sdp-candidates #:sdp-sctp-port #:sdp-mid
           #:sdp-media #:sdp-media-type #:sdp-media-mid #:sdp-media-codec-pt
           #:make-ice #:ice-answer #:ice-serve #:ice-start-checks #:ice-close #:ice-silent-secs
           ;; route attribution: which pair got selected, when, and out of what
           #:ice-route-label #:ice-selection-secs #:ice-offered-counts
           #:ice-local-end-type #:ice-remote-end-type #:ice-agent-route-changes
           #:ice-gather-srflx #:ice-gather-relay #:ice-agent-relay-ip #:ice-agent-relay-port
           #:ice-agent-srflx-ip #:ice-agent-srflx-port #:ice-agent-turn #:ice-agent-peer
           #:ice-agent-on-media #:ice-send-to-peer            ; SRTP media demux + send (webrtc-media)
           #:ice-agent-local-ip #:ice-agent-port #:turn-start-refresh
           #:turn-allocate #:turn-alloc-relay-ip #:turn-alloc-relay-port #:make-turn-alloc
           #:turn-install-peer #:turn-create-permission #:turn-channel-bind #:turn-refresh
           #:generate-webrtc-cert #:webrtc-dtls-setup #:webrtc-dtls-run
           #:dtls-conn-session #:dtls-conn-fingerprint
           #:webrtc-serve-datachannel #:sctp-assoc #:sctp-assoc-state
           #:sctp-send-data #:sctp-send-string #:sctp-send-binary #:sctp-stats
           #:webrtc-error))

(in-package #:webrtc-data)

(define-condition webrtc-error (error)
  ((msg :initarg :msg :reader webrtc-error-msg))
  (:report (lambda (c s) (format s "webrtc-data: ~a" (webrtc-error-msg c)))))
(defun werr (fmt &rest args) (error 'webrtc-error :msg (apply #'format nil fmt args)))
