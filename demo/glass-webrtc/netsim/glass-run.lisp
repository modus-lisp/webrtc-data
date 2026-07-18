;;;; netsim/glass-run.lisp — launch a glass terminal RFB server for the conditioning rig.
(require :asdf)
(handler-bind ((warning #'muffle-warning)) (asdf:load-system "glass/term"))
(let ((port (or (ignore-errors (parse-integer (uiop:getenv "GLASS_PORT"))) 5900)))
  (format t "~&@@ glass-term on ~a~%" port) (finish-output)
  (glass-term:run :port port :cols 80 :rows 24 :ppem 16 :shell "/bin/bash"))
