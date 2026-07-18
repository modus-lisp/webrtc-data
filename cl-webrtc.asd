;;;; cl-webrtc.asd
;;;;
;;;; A from-scratch WebRTC data-channel peer in pure Common Lisp: SDP + ICE/STUN + DTLS 1.2 +
;;;; SCTP/DCEP, so a browser (or aiortc) can open an RTCDataChannel with no plugins.  Data
;;;; channels only — no SRTP, no video codec; built to carry glass's framebuffer + input.

(defsystem "cl-webrtc"
  :description "A from-scratch WebRTC data-channel peer in pure Common Lisp (SDP/ICE/DTLS/SCTP)."
  :version "0.0.1"
  :author "ynniv"
  :license "MIT"
  :depends-on ("ironclad" "bordeaux-threads")
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "packages")
     (:file "util")        ; byte helpers, base64, random
     (:file "sdp")         ; offer parse + answer generation (data-channel m-line)
     (:file "stun")))))    ; STUN messages: MESSAGE-INTEGRITY + FINGERPRINT (ICE checks)
