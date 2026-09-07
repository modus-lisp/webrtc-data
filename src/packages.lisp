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
  ;; ---- the connectivity stack lives in cl-transport ------------------------------
  ;; STUN, TURN and ICE are the IETF stack for getting a datagram between two peers behind
  ;; NATs.  They predate WebRTC, SIP uses them, and this library is one CONSUMER -- so they
  ;; are in cl-transport/ice now and imported back here.
  ;;
  ;; WHAT STAYED is what is actually WebRTC: SDP, DTLS and SCTP.  ICE-ANSWER stayed too, in
  ;; sdp.lisp, because it is the SDP-shaped wrapper over ICE-ACCEPT-REMOTE and this is the
  ;; only file that ever knew both halves.  ICE itself no longer knows what SDP is.
  ;;
  ;; IMPORTED, not USEd: what came from where stays greppable, and a name added upstream
  ;; cannot silently shadow one of ours.  The byte helpers are still ours -- util.lisp
  ;; defines them for dtls and sctp -- except COLON-HEX and HEXBYTES, which came back with
  ;; ICE and would otherwise be defined twice in one image.
  (:import-from #:cl-transport.ice
                #:*stun-servers* #:*turn-debug* #:+attr-channel-number+ #:+attr-data+
                #:+attr-error-code+ #:+attr-fingerprint+ #:+attr-ice-controlled+ #:+attr-ice-controlling+
                #:+attr-lifetime+ #:+attr-message-integrity+ #:+attr-nonce+ #:+attr-priority+
                #:+attr-realm+ #:+attr-requested-transport+ #:+attr-software+ #:+attr-use-candidate+
                #:+attr-username+ #:+attr-xor-mapped-address+ #:+attr-xor-peer-address+ #:+attr-xor-relayed-address+
                #:+binding-request+ #:+binding-success+ #:+ice-chars+ #:+stun-magic+
                #:+turn-allocate+ #:+turn-allocate-error+ #:+turn-allocate-success+ #:+turn-channel-bind+
                #:+turn-channel-bind-success+ #:+turn-channel-max+ #:+turn-channel-min+ #:+turn-create-perm+
                #:+turn-create-perm-success+ #:+turn-data-indication+ #:+turn-refresh+ #:+turn-refresh-success+
                #:+turn-relay-priority+ #:+turn-send-indication+ #:colon-hex #:crc32
                #:decode-stun #:encode-stun #:hexbytes #:hmac-sha1
                #:ice-accept-remote #:ice-agent #:ice-agent-check-thread #:ice-agent-created-at
                #:ice-agent-last-rx #:ice-agent-local-ip #:ice-agent-local-pwd #:ice-agent-local-ufrag
                #:ice-agent-on-media #:ice-agent-on-packet #:ice-agent-p #:ice-agent-peer
                #:ice-agent-port #:ice-agent-relay-ip #:ice-agent-relay-port #:ice-agent-remote-candidates
                #:ice-agent-remote-pwd #:ice-agent-remote-ufrag #:ice-agent-route-changes #:ice-agent-selected-at
                #:ice-agent-selected-first #:ice-agent-socket #:ice-agent-srflx-ip #:ice-agent-srflx-port
                #:ice-agent-stop #:ice-agent-thread #:ice-agent-turn #:ice-bind-relay-peer-async
                #:ice-candidate #:ice-candidate-component #:ice-candidate-foundation #:ice-candidate-ip
                #:ice-candidate-p #:ice-candidate-port #:ice-candidate-priority #:ice-candidate-transport
                #:ice-candidate-type #:ice-close #:ice-dispatch #:ice-gather-relay
                #:ice-gather-srflx #:ice-handle-stun #:ice-local-end-type #:ice-note-peer
                #:ice-offered-counts #:ice-relayed-inner #:ice-relayed-inner-send #:ice-remote-end-type
                #:ice-route-label #:ice-selection-secs #:ice-send #:ice-send-to-peer
                #:ice-serve #:ice-silent-secs #:ice-start-checks #:ice-string
                #:local-ipv4 #:make-ice #:make-ice-agent #:make-ice-candidate
                #:make-turn-alloc #:parse-xor-mapped-address #:resolve-host #:stun-attr
                #:stun-transaction-id #:stun-username-key #:tdbg #:turn-alloc
                #:turn-alloc-binding #:turn-alloc-chan->peer #:turn-alloc-key #:turn-alloc-lifetime
                #:turn-alloc-mapped-ip #:turn-alloc-mapped-port #:turn-alloc-next-channel #:turn-alloc-nonce
                #:turn-alloc-p #:turn-alloc-pass #:turn-alloc-peer->chan #:turn-alloc-perms
                #:turn-alloc-realm #:turn-alloc-refresh-thread #:turn-alloc-relay-ip #:turn-alloc-relay-port
                #:turn-alloc-resp #:turn-alloc-resp-cv #:turn-alloc-resp-lock #:turn-alloc-server-host
                #:turn-alloc-server-port #:turn-alloc-socket #:turn-alloc-user #:turn-allocate
                #:turn-channel-bind #:turn-channeldata-p #:turn-create-permission #:turn-deliver-control
                #:turn-install-peer #:turn-long-term-key #:turn-refresh #:turn-refresh-via-loop
                #:turn-start-refresh #:turn-wrap-channeldata #:turn-wrap-send-indication #:xor-mapped-address)
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
