;;;; webrtc-data.asd
;;;;
;;;; A from-scratch WebRTC data-channel peer in pure Common Lisp: SDP + ICE/STUN + DTLS 1.2 +
;;;; SCTP/DCEP, so a browser (or aiortc) can open an RTCDataChannel with no plugins.  Data
;;;; channels only — no SRTP, no video codec; built to carry glass's framebuffer + input.

(defsystem "webrtc-data"
  :description "A from-scratch WebRTC data-channel peer in pure Common Lisp (SDP/ICE/DTLS/SCTP)."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  :depends-on ("ironclad" "bordeaux-threads" "sb-bsd-sockets" "seal")
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "packages")
     (:file "util")        ; byte helpers, base64, random
     (:file "sdp")         ; offer parse + answer generation (data-channel m-line)
     (:file "stun")        ; STUN messages: MESSAGE-INTEGRITY + FINGERPRINT (ICE checks)
     (:file "turn")        ; TURN client (RFC 5766/8656): relay candidate + ChannelData
     (:file "ice")         ; ICE-lite agent: UDP socket + answer connectivity checks
     (:file "dtls")        ; DTLS 1.2 client (via seal) + RSA cert generation
     (:file "sctp")))))    ; SCTP association + DCEP (data channels over DTLS)

;;; Optional integration: register :webrtc as a cl-transport INBOUND backend, so any modus-lisp
;;; code can accept WebRTC data-channel connections through cl-transport's uniform EXPOSE — just
;;; like :tcp (built in) and :frp (via cl-frpc).  cl-transport + hunchentoot stay OUT of core
;;; webrtc-data's deps; they're only pulled in when you load this system.
(defsystem "webrtc-data/transport"
  :description "cl-transport :webrtc inbound backend: accept WebRTC data channels via EXPOSE."
  :version "0.1.0"
  :author "ynniv"
  :license "MIT"
  :depends-on ("webrtc-data" "cl-transport" "hunchentoot" "bordeaux-threads")
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "transport-package")
     (:file "transport")))))   ; Gray channel stream + %webrtc-expose + register :webrtc
