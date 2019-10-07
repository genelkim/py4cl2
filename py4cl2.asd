;;;; Py4cl.asd

(asdf:defsystem "py4cl2"
  :serial t
  :description "Call Python libraries from Common Lisp"
  :author "Ben Dudson <benjamin.dudson@york.ac.uk>"
  :license "MIT"
  :depends-on ("trivial-garbage"
               "iterate"
               "cl-json"
               "bordeaux-threads"
               "parse-number"
               "uiop"
               "numpy-file-format")
  :pathname #P"src/"
  :serial t
  :components ((:file "package")
	       (:file "config")
               (:file "reader")
               (:file "writer")
               (:file "python-process")
               (:file "lisp-classes")
               (:file "callpython")
               (:file "import-export")
	       (:file "do-after-load"))
  :in-order-to ((test-op (test-op "py4cl2-tests"))))

;; This is to store the path to the source code
;; suggested here https://xach.livejournal.com/294639.html
(defpackage #:py4cl2/config (:export #:*base-directory*))
(defparameter py4cl2/config:*base-directory* 
  (make-pathname :name nil :type nil :defaults *load-truename*))

