;;; refmt.el --- utility functions to format reason code

;; Copyright (c) 2014 The go-mode Authors. All rights reserved.
;; Portions Copyright (c) 2015-present, Facebook, Inc. All rights reserved.

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions are
;; met:

;; * Redistributions of source code must retain the above copyright
;; notice, this list of conditions and the following disclaimer.
;; * Redistributions in binary form must reproduce the above
;; copyright notice, this list of conditions and the following disclaimer
;; in the documentation and/or other materials provided with the
;; distribution.
;; * Neither the name of the copyright holder nor the names of its
;; contributors may be used to endorse or promote products derived from
;; this software without specific prior written permission.

;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;; A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;; OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;; SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
;; LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;; DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
;; OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.)

;;; Commentary:
;;

;;; Code:

(require 'cl-lib)

(defvar-local refmt-opam-bin-dir nil)

(defcustom refmt-command "refmt"
  "The 'refmt' command."
  :type '(choice (file :tag "Filename (default binary is \"refmt\")")
                 (const :tag "Use current opam switch" opam)
                 (const :tag "Use current npm version (via npx)" npm)
                 (const :tag "Use current esy version (via esy exec-command)" esy))
  :group 're-fmt)

(defcustom refmt-show-errors 'buffer
    "Where to display refmt error output.
It can either be displayed in its own buffer, in the echo area, or not at all.
Please note that Emacs outputs to the echo area when writing
files and will overwrite refmt's echo output if used from inside
a `before-save-hook'."
    :type '(choice
            (const :tag "Own buffer" buffer)
            (const :tag "Echo area" echo)
            (const :tag "None" nil))
      :group 're-fmt)

(defcustom refmt-width-mode nil
  "Specify width when formatting buffer contents."
  :type '(choice
          (const :tag "Window width" window)
          (const :tag "Fill column" fill)
          (const :tag "None" nil))
  :group 're-fmt)

;;;###autoload
(defun refmt-before-save ()
  "Add this to .emacs to run refmt on the current buffer when saving:
 (add-hook 'before-save-hook 'refmt-before-save)."
    (interactive)
      (when (eq major-mode 'reason-mode) (refmt)))

(defun reason--goto-line (line)
  (goto-char (point-min))
    (forward-line (1- line)))

(defun reason--delete-whole-line (&optional arg)
    "Delete the current line without putting it in the `kill-ring'.
Derived from function `kill-whole-line'.  ARG is defined as for that
function."
    (setq arg (or arg 1))
    (if (and (> arg 0)
             (eobp)
             (save-excursion (forward-visible-line 0) (eobp)))
        (signal 'end-of-buffer nil))
    (if (and (< arg 0)
             (bobp)
             (save-excursion (end-of-visible-line) (bobp)))
        (signal 'beginning-of-buffer nil))
    (cond ((zerop arg)
           (delete-region (progn (forward-visible-line 0) (point))
                          (progn (end-of-visible-line) (point))))
          ((< arg 0)
           (delete-region (progn (end-of-visible-line) (point))
                          (progn (forward-visible-line (1+ arg))
                                 (unless (bobp)
                                   (backward-char))
                                 (point))))
          (t
           (delete-region (progn (forward-visible-line 0) (point))
                                                  (progn (forward-visible-line arg) (point))))))

(defun reason--apply-rcs-patch (patch-buffer &optional start-pos)
  "Apply an RCS-formatted diff from PATCH-BUFFER to the current buffer."
  (setq start-pos (or start-pos (point-min)))
  (let ((first-line (line-number-at-pos start-pos))
        (target-buffer (current-buffer))
        ;; Relative offset between buffer line numbers and line numbers
        ;; in patch.
        ;;
        ;; Line numbers in the patch are based on the source file, so
        ;; we have to keep an offset when making changes to the
        ;; buffer.
        ;;
        ;; Appending lines decrements the offset (possibly making it
        ;; negative), deleting lines increments it. This order
        ;; simplifies the forward-line invocations.
        (line-offset 0))
    (save-excursion
      (with-current-buffer patch-buffer
        (goto-char (point-min))
        (while (not (eobp))
          (unless (looking-at "^\\([ad]\\)\\([0-9]+\\) \\([0-9]+\\)")
            (error "invalid rcs patch or internal error in reason--apply-rcs-patch"))
          (forward-line)
          (let ((action (match-string 1))
                (from (string-to-number (match-string 2)))
                (len  (string-to-number (match-string 3))))
            (cond
             ((equal action "a")
              (let ((start (point)))
                (forward-line len)
                (let ((text (buffer-substring start (point))))
                  (with-current-buffer target-buffer
                    (cl-decf line-offset len)
                    (goto-char start-pos)
                    (forward-line (- from len line-offset))
                    (insert text)))))
             ((equal action "d")
              (with-current-buffer target-buffer
                (reason--goto-line (- (1- (+ first-line from)) line-offset))
                (cl-incf line-offset len)
                (reason--delete-whole-line len)))
             (t
              (error "invalid rcs patch or internal error in reason--apply-rcs-patch")))))))))

(defun refmt--process-errors (filename tmpfile errorfile errbuf)
  (with-current-buffer errbuf
    (if (eq refmt-show-errors 'echo)
        (progn
          (message "%s" (buffer-string))
          (refmt--kill-error-buffer errbuf))
      (insert-file-contents errorfile nil nil nil)
      ;; Convert the refmt stderr to something understood by the compilation mode.
      (goto-char (point-min))
      (insert "refmt errors:\n")
      (while (search-forward-regexp (regexp-quote tmpfile) nil t)
        (replace-match (file-name-nondirectory filename)))
      (compilation-mode)
      (display-buffer errbuf))))

(defun refmt--kill-error-buffer (errbuf)
  (let ((win (get-buffer-window errbuf)))
    (if win
        (quit-window t win)
      (with-current-buffer errbuf
        (erase-buffer))
      (kill-buffer errbuf))))

(defun apply-refmt (&optional start end from to)
  (setq start (or start (point-min))
        end (or end (point-max))
        from (or from "re")
        to (or to "re"))
   (let* ((ext (file-name-extension buffer-file-name t))
          (bufferfile (make-temp-file "refmt" nil ext))
          (outputfile (make-temp-file "refmt" nil ext))
          (errorfile (make-temp-file "refmt" nil ext))
          (errbuf (if refmt-show-errors (get-buffer-create "*Refmt Errors*")))
          (patchbuf (get-buffer-create "*Refmt patch*"))
          (coding-system-for-read 'utf-8)
          (coding-system-for-write 'utf-8)
          (width-args
           (cond
            ((equal refmt-width-mode 'window)
             (list "--print-width" (number-to-string (window-body-width))))
            ((equal refmt-width-mode 'fill)
             (list "--print-width" (number-to-string fill-column)))
            (t
             '()))))
     (unwind-protect
         (save-restriction
           (widen)
           (write-region start end bufferfile)
           (if errbuf
               (with-current-buffer errbuf
                 (setq buffer-read-only nil)
                 (erase-buffer)))
           (with-current-buffer patchbuf
             (erase-buffer))
           (if (zerop (let* ((files (list (list :file outputfile) errorfile))
                             (args (append width-args (list "--parse" from "--print" to bufferfile))))
                        (cond ((equal refmt-command 'opam)
                               ;; this was originally done via `opam exec' but that does not
                               ;; work for opam 1, and added a performance hit
                               (progn
                                 (when (not refmt-opam-bin-dir)
                                   (setq-local
                                    refmt-opam-bin-dir
                                    (with-temp-buffer
                                      (when (eq (call-process-shell-command
                                                 "opam config var bin" nil (current-buffer) nil) 0)
                                        (replace-regexp-in-string "\n$" "" (buffer-string))))))

                                 (apply 'call-process (concat refmt-opam-bin-dir "/refmt") nil files nil args)))

                              ((equal refmt-command 'npm)
                               (apply 'call-process
                                      "npx" nil files nil (append '("refmt") args)))

                              ((equal refmt-command 'esy)
                               (apply 'call-process
                                      "esy" nil files nil (append '("exec-command" "refmt") args)))

                              (t
                               (apply 'call-process
                                      refmt-command nil files nil args)))))
               (progn
                 (call-process-region start end "diff" nil patchbuf nil "-n" "-"
                                      outputfile)
                 (reason--apply-rcs-patch patchbuf start)
                 (message "Applied refmt")
                 (if errbuf (refmt--kill-error-buffer errbuf)))
             (message "Could not apply refmt")
             (if errbuf
                 (refmt--process-errors (buffer-file-name) bufferfile errorfile errbuf)))))
     (kill-buffer patchbuf)
     (delete-file errorfile)
     (delete-file bufferfile)
     (delete-file outputfile)))

(defun refmt ()
  "Format the current buffer according to the refmt tool."
  (interactive)
  (apply-refmt))

(defun refmt-region-ocaml-to-reason (start end)
  (interactive "r")
  (apply-refmt start end "ml"))

(defun refmt-region-reason-to-ocaml (start end)
  (interactive "r")
  (apply-refmt start end "re" "ml"))

(provide 'refmt)

;;; refmt.el ends here
