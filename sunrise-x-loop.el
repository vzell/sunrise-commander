;;  sunrise-x-loop.el  ---  Asynchronous  execution of filesystem operations for
;;  the Sunrise Commander File Manager.

;; Copyright (C) 2008 José Alfredo Romero L.

;; Author: José Alfredo Romero L. <joseito@poczta.onet.pl>
;; Keywords: Sunrise Commander Emacs File Manager Background Copy Rename Move

;; This program is free software: you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free Software
;; Foundation,  either  version  3 of the License, or (at your option) any later
;; version.
;;
;; This  program  is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR  A  PARTICULAR  PURPOSE.  See the GNU General Public License for more de-
;; tails.

;; You  should have received a copy of the GNU General Public License along with
;; this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This  extension  adds  to  the Sunrise Commander the capability of performing
;; copy and rename operations in the background. It provides prefixable  drop-in
;; replacements  for  the  sr-do-copy and sr-do-rename commands and uses them to
;; redefine their bindings in the sr-mode-map keymap. When invoked the usual way
;; (by  pressing C or R), these new functions work exactly as the old ones, i.e.
;; they simply pass the control flow to the logic already provided  by  Sunrise,
;; but  when  prefixed (by pressing C-u C or C-u R) they launch a separate elisp
;; intepreter in the background, delegate to it the  execution  of  all  further
;; operations  and  return immediately, so the emacs UI remains fully responsive
;; while any potentially long-running copy or move tasks can  be  let  alone  to
;; eventually reach their completion in the background.

;; After  all  requested actions have been performed, the background interpreter
;; remains active for a short period of time (30 seconds by default, but it  can
;; be customized), after which it shuts down automatically.

;; At any moment you can abort all tasks scheduled and under execution and force
;; the background interpreter to shut down by invoking the sr-loop-stop  command
;; (M-x sr-loop-stop).

;; If  you  need to debug something or are just curious about how this extension
;; works, you can set the variable sr-loop-debug to t to  have  the  interpreter
;; launched  in  debug  mode.  In  this  mode all input and output of background
;; operations are sent to a buffer named *SUNRISE-LOOP*.  To  return  to  normal
;; mode set back sr-loop-debug to nil and use sr-loop-stop to kill the currently
;; running interpreter.

;; The extension disables itself and tries to do its best to keep out of the way
;; when working with remote directories through FTP (e.g. when using  ange-ftp),
;; since in these cases the execution of file transfers in the background should
;; be managed directly by the FTP client.

;; This is version 1 $Rev$ of the Sunrise Commander Loop Extension.

;; It  was  written  on GNU Emacs 23 on Linux, and tested on GNU Emacs 22 and 23
;; for Linux and on EmacsW32 (version 22) for  Windows.

;;; Installation and Usage:

;; 1) Put this file somewhere in your emacs load-path.

;; 2)  Add  a (require 'sunrise-x-loop) expression to your .emacs file somewhere
;; after the (require 'sunrise-commander) one.

;; 3) Evaluate the new expression, or reload your .emacs file, or restart emacs.

;; 4)  The  next  time  you  need to copy of move any big files, just prefix the
;; appropriate command with C-u.

;; 5) Enjoy ;-)

;;; Code:

(eval-when-compile (require 'sunrise-commander))

(defcustom sr-loop-debug nil
  "Activates  debug mode in the Sunrise Loop extension. When set, the background
  elisp interpreter is launched in such a way  that  all  background  input  and
  output  are  sent  to  a  buffer  named *SUNRISE LOOP* and automatic lifecycle
  management is disabled (i.e. you have to kill the interpreter  manually  using
  sr-loop-stop to get rid of it)."
  :group 'sunrise
  :type 'boolean)

(defcustom sr-loop-timeout 30
  "Time  to  wait (in seconds) while idle before automatically shutting down the
  Sunrise Loop elisp interpreter after executing one or more operations  in  the
  background."
  :group 'sunrise)

(defvar sr-loop-idle-msg "***IDLE***")
(defvar sr-loop-process nil)
(defvar sr-loop-timer nil)
(defvar sr-loop-scope nil)
(defvar sr-loop-queue-length 0)

(if (boundp 'sr-mode-map)
    (progn
      (define-key sr-mode-map "C" 'sr-loop-do-copy)
      (define-key sr-mode-map "R" 'sr-loop-do-rename)))

(defun sr-loop-start ()
  "Launches   and   initiates  a  new  background  elisp  interpreter.  The  new
  interpreter runs in batch mode and inherits all  functions  from  the  Sunrise
  Commander (sunrise-commander.el) and from this file."
  (sr-loop-stop)
  (let ((process-connection-type nil)
        (sr-loop (symbol-file 'sr-loop-cmd-loop))
        (emacs (concat invocation-directory invocation-name)))
    (setq sr-loop-process (start-process
                         "Sunrise-Loop"
                         (if sr-loop-debug "*SUNRISE-LOOP*" nil)
                         emacs
                         "-batch" "-q" "-no-site-file"
                         "-l" sr-loop "-eval" "(sr-loop-cmd-loop)"))
    (sr-loop-enqueue `(setq load-path (quote ,load-path)))
    (sr-loop-enqueue '(require 'sunrise-commander))
    (if sr-loop-debug
        (sr-loop-enqueue '(setq sr-loop-debug t))
      (set-process-filter sr-loop-process 'sr-loop-filter))
    (setq sr-loop-queue-length 0)))

(defun sr-loop-disable-timer ()
  "Disables  the automatic shutdown timer. This is done every time we send a new
  task to the background interpreter, lest it gets nuked before  completing  its
  queue."
  (if sr-loop-timer
      (progn
        (cancel-timer sr-loop-timer)
        (setq sr-loop-timer nil))))

(defun sr-loop-enable-timer ()
  "Enables  the  automatic  shutdown  timer.  This is done every time we receive
  confirmation from the background interpreter that all the tasks  delegated  to
  it  have  been  completed. Once this function is executed, if no new tasks are
  enqueued before sr-loop-timeout seconds, the interpreter is killed."
  (sr-loop-disable-timer)
  (setq sr-loop-timer (run-with-timer sr-loop-timeout nil 'sr-loop-stop)))

(defun sr-loop-stop ()
  "Shuts down the background elisp interpreter and cleans up after it."
  (interactive)
  (sr-loop-disable-timer)
  (setq sr-loop-queue-length 0)
  (if sr-loop-process
      (progn
        (message "[[Shutting down background interpreter]]")
        (delete-process sr-loop-process)
        (setq sr-loop-process nil))))

(defun sr-loop-filter (process output)
  "Process filter used to intercept and manage all the notifications produced by
  the background interpreter."
  (mapc (lambda (line)
          (cond ((and (string-match "^\\[\\[" line) (< 0 (length line)))
                 (message "%s" line))
                ((string= line sr-loop-idle-msg)
                 (progn
                   (setq sr-loop-queue-length (1- sr-loop-queue-length))
                   (if (>= 0 sr-loop-queue-length)
                       (sr-loop-enable-timer))))
                (t nil)))
        (split-string output "\n")))

(defun sr-loop-enqueue (form)
  "Delegates  the  execution of the given form to the background interpreter. If
  no such interpreter is currently running, then launches first a new one."
  (if (or (null sr-loop-process)
          (equalp 'exit (process-status sr-loop-process)))
      (sr-loop-start))
  (sr-loop-disable-timer)
  (setq sr-loop-queue-length (1+ sr-loop-queue-length))
  (let ((contents (prin1-to-string form)))
    (process-send-string sr-loop-process contents)
    (process-send-string sr-loop-process "\n")))

(defun sr-loop-cmd-loop ()
  "Main execution loop for the background elisp interpreter."
  (sr-loop-disengage)
  (defun read-char nil ?y) ;; Always answer "yes" to any prompt
  (let (command)
    (while t
      (setq command (read))
      (condition-case description
          (progn
            (if sr-loop-debug
                (message "%s" (concat "[[Executing: "
                                      (prin1-to-string command) "]]")))
            (eval command)
            (message "[[Command successfully sent to background]]"))
        (error (message "%s" (concat "[[ERROR EXECUTING IN BACKGROUND: "
                                (prin1-to-string description) "]]"))))
      (setq command nil)
      (message "%s" sr-loop-idle-msg))))

(defun sr-loop-applicable-p ()
  "Determines  whether  a  given  operation  may  be  safely  delegated  to  the
  background elisp interpreter."
  (and (null (string-match "^/ftp:" dired-directory))
       (null (string-match "^/ftp:" sr-other-directory))))

(defun sr-loop-do-copy (&optional arg)
  "Drop-in  prefixable replacement for the sr-do-copy command. When invoked with
  any prefix, sets a flag that is used later by  advice  to  decide  whether  to
  delegate further copy operations to the background interpreter."
  (interactive "P")
  (if (and arg (sr-loop-applicable-p))
      (let ((sr-loop-scope t))
        (sr-do-copy))
    (sr-do-copy)))

(defun sr-loop-do-rename (&optional arg)
  "Drop-in  prefixable  replacement  for  the sr-do-rename command. When invoked
  with any prefix, sets a flag that is used later by advice to decide whether to
  delegate further rename operations to the background interpreter."
  (interactive "P")
  (if (and arg (sr-loop-applicable-p))
      (let ((sr-loop-scope t))
        (sr-do-rename))
    (sr-do-rename)))

;; This modifies all confirmation request messages inside a loop scope:
(defadvice y-or-n-p
  (before sr-loop-advice-y-or-n-p (prompt))
  (if sr-loop-scope
      (setq prompt (replace-regexp-in-string
                    "\?" " in the background? (overwrites ALWAYS!)" prompt))))

;; This modifies all queries from dired inside a loop scope:
(defadvice dired-mark-read-file-name
  (before sr-loop-advice-dired-mark-read-file-name
          (prompt dir op-symbol arg files &optional default))
  (if sr-loop-scope
      (setq prompt (replace-regexp-in-string
                    "^\\([^ ]+\\) ?\\(.*\\)"
                    "\\1 (in background - overwrites ALWAYS!) \\2" prompt))))

;; This delegates to the background interpreter all copy and rename operations
;; triggered by dired-do-copy inside a loop scope:
(defadvice dired-create-files
  (around sr-loop-advice-dired-create-files
          (file-creator operation fn-list name-constructor
                        &optional marker-char))
  (if sr-loop-scope
      (with-no-warnings
        (sr-loop-enqueue
         `(let ((target ,target))
            (dired-create-files (function ,file-creator)
                                ,operation
                                (quote ,fn-list)
                                ,name-constructor nil))))
    ad-do-it))

;; This delegates to the background interpreter all copy operations triggered by
;; sr-do-copy inside a loop scope:
(defadvice sr-copy-files
  (around sr-loop-advice-sr-copy-files
          (file-path-list target-dir &optional do-overwrite))
  (if sr-loop-scope
      (sr-loop-enqueue
       `(sr-copy-files (quote ,file-path-list) ,target-dir 'ALWAYS))
    ad-do-it))

;; This  delegates to the background interpreter all rename operations triggered
;; by sr-do-rename inside a loop scope:
(defadvice sr-move-files
  (around sr-loop-advice-sr-move-files
          (file-path-list target-dir &optional do-overwrite))
  (if sr-loop-scope
      (sr-loop-enqueue
       `(sr-move-files (quote ,file-path-list) ,target-dir 'ALWAYS))
    ad-do-it))

(defun sr-loop-engage ()
  "Activates all advice used by the Sunrise Loop extension."
  (mapc 'ad-activate '(y-or-n-p
                       dired-mark-read-file-name
                       dired-create-files
                       sr-copy-files
                       sr-move-files)))

(defun sr-loop-disengage ()
  "Deactivates all advice used by the Sunrise Loop extension."
  (mapc 'ad-deactivate '(y-or-n-p
                         dired-mark-read-file-name
                         dired-create-files
                         sr-copy-files
                         sr-move-files)))

(sr-loop-engage)
(provide 'sunrise-x-loop)
