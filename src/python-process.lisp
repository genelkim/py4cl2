;;; Functions to start and stop python process

(in-package :py4cl2)

(defvar *python* nil
  "Most recently started python subprocess")

(defvar *current-python-process-id* 0
  "A number which changes when python is started. This
is used to prevent garbage collection from deleting objects in the wrong
python session")

(defvar *python-process-busy-p* nil
  "Used by pyinterrupt to determine if python process is waiting for input, or
is busy processing.

A possible workaround is to use strace.
See https://askubuntu.com/questions/1118109/how-do-i-tell-if-a-command-is-running-or-waiting-for-user-input")

(defvar *py4cl-tests* nil)

(defvar *python-code*
  (alexandria:read-file-into-string
   (asdf:component-pathname
    (asdf:find-component :py4cl2 "python-code"))))

(defvar *python-startup-error*) ; couldn't put this inside the :REPORT!

(define-condition python-process-startup-error (error)
  ((command :initarg :command :reader command))
  (:report (lambda (condition stream)
             (format stream "Unable to start python process \"~a\"~%~% Error: ~%~%~a"
                     (command condition)
                     *python-startup-error*))))

(defun pystart (&optional (command (config-var 'pycmd)))
  "Start a new python subprocess
This sets the global variable *python* to the process handle,
in addition to returning it.
COMMAND is a string with the python executable to launch e.g. \"python\"
By default this is is set to *PYTHON-COMMAND*
"
  (flet ((bash-escape-string (string) ; TODO: Better way to do things!
           ;; We want strings such as
           ;; "/user/ram-disk/test (hello''/miniconda(3')/bin/"
           ;; to be escaped correctly.
           ;; This function only exists in the context of PYSTART
           (with-output-to-string (*standard-output*)
             (iter (for ch in-string string)
               (case ch
                 (#\' (write-string "\\'"))
                 (#\( (write-string "\\("))
                 (#\) (write-string "\\)"))
                 (#\space (write-string "\\ "))
                 (t (write-char ch)))))))
    (loop :until (python-alive-p)
          :do (setq *python*
                    #+(or os-windows windows)
                    (uiop:launch-program
                     (concatenate 'string
                                  command
                                  " -u "
                                  (namestring
                                   (asdf:component-pathname
                                    (asdf:find-component
                                     :py4cl2 "python-code")))
                                  " "
                                  (directory-namestring
                                   (asdf:component-pathname
                                    (asdf:find-component
                                     :py4cl2 "python-code"))))
                     ;; Not much idea why, but
                     ;; numpy.random loads in windows with latin-1, but errors on linux
                     :external-format :latin-1
                     :input :stream
                     :output :stream
                     :error-output :stream)
                     #+unix
                     (uiop:launch-program
                      (concatenate 'string
                                   "bash -c \""
                                   (bash-escape-string command)
                                   "\"' <(cat <<\"EOF\""
                                   (string #\newline)
                                   *python-code*
                                   (string #\newline)
                                   "EOF"
                                   (string #\newline)
                                   ")'\" "
                                   (bash-escape-string
                                    (directory-namestring
                                     (asdf:component-pathname
                                      (asdf:find-component
                                       :py4cl2 "python-code"))))
                                   "\"")
                      :input :stream
                      :output :stream
                      :error-output :stream))
              (sleep 0.1)
              (unless (python-alive-p)
                (let ((*python-startup-error* (or (ignore-errors
                                                   (read-stream-content-into-string
                                                    (uiop:process-info-error-output *python*)))
                                                  "Unable to fetch more error details on ECL")))
                  (cerror "Provide another path (setf (config-var 'pycmd) ...)"
                          'python-process-startup-error :command command))
                (format t "~&Provide the path to python binary to use (eg python): ")
                (let ((cmd (read-line)))
                  (setf (config-var 'pycmd) cmd)
                  (setf command cmd)))))
  (unless *py4cl-tests*
    (setq *python-output-thread*
          (bt:make-thread
           (lambda ()
             (when *python*
               (let ((py-out (uiop:process-info-error-output *python*)))
                 (iter outer
                   (while (and *python* (python-alive-p *python*)))
                   (for char =
                        (progn
                          ;; PEEK-CHAR waits for input
                          (peek-char nil py-out nil)
                          (when *in-with-python-output*
                            (iter (while *in-with-python-output*)
                              (bt:wait-on-semaphore *python-output-semaphore*))
                            (in outer (next-iteration)))
                          (read-char py-out nil)))
                   (when char (write-char char)))))))))
  (incf *current-python-process-id*))

(defvar *python-output-semaphore* (bt:make-semaphore))
(defvar *python-output-thread*)
(defvar *in-with-python-output* nil) ; This is more of a global variable than a dynamic variable.

(defmacro with-python-output (&body forms-decl)
  `(with-output-to-string (output-stream)
     (unwind-protect (progn
                       (setq *in-with-python-output* t)
                       ,@forms-decl
                       (sleep 0.00002)
                       (let ((py-out (uiop:process-info-error-output *python*)))
                         (iter (while (listen py-out))
                           (for char = (read-char py-out nil))
                           (when char (write-char char output-stream)))))
       (setq *in-with-python-output* nil)
       (bt:signal-semaphore *python-output-semaphore*))))

(defun python-alive-p (&optional (process-info *python*))
  "Returns non-NIL if the python process is alive
(e.g. SBCL -> T, CCL -> RUNNING).
Optionally pass the process object returned by PYTHON-START"
  (and process-info
       (uiop:process-alive-p process-info)))

(defun python-start-if-not-alive ()
  "If no python process is running, tries to start it.
If still not alive, raises a condition."
  (unless (python-alive-p)
    (pystart)))

;; Function defined in writer.lisp, which clears an object store
(declaim (ftype (function () t) clear-lisp-objects))

(defun pystop (&optional (process-info *python*))
  "Stop (Quit) the python process PROCESS"
  (unless (python-alive-p process-info)
    (return-from pystop))
  (let ((stream (uiop:process-info-input process-info)))
    ;; ask the python process to quit; might require a few sec?
    (write-char #\q stream))
  (uiop:terminate-process process-info)
  (if (bt:thread-alive-p *python-output-thread*) (bt:destroy-thread *python-output-thread*))
  (setf *python* nil) ;; what about multiple processes?
  (clear-lisp-objects))

(defun pyinterrupt (&optional (process-info *python*))
  (when (and (python-alive-p process-info)
             *python-process-busy-p*)
    (uiop:run-program
     (concatenate 'string "/bin/kill -SIGINT -"
                  (write-to-string (uiop:process-info-pid process-info)))
     :force-shell t)
    (setq *python-process-busy-p* nil)
    ;; something to do with running in separate threads! "deftest interrupt"
    (unless *py4cl-tests* (dispatch-messages process-info))))
