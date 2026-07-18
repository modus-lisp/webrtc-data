;;;; src/transport-package.lisp — package for the optional cl-transport :webrtc provider.
;;;;
;;;; Kept separate from webrtc-data's core package so cl-transport / hunchentoot are only
;;;; pulled in by the webrtc-data/transport system, never by core webrtc-data.

(defpackage #:webrtc-data-transport
  (:use #:cl)
  (:local-nicknames (#:wd #:webrtc-data)
                    (#:ct #:cl-transport)
                    (#:bt #:bordeaux-threads))
  (:export #:webrtc-channel-stream #:%webrtc-expose))
