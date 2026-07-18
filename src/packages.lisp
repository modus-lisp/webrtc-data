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
  (:export #:parse-sdp #:make-answer-sdp #:sdp-session
           #:sdp-ice-ufrag #:sdp-ice-pwd #:sdp-fingerprint #:sdp-setup
           #:sdp-candidates #:sdp-sctp-port #:sdp-mid
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
