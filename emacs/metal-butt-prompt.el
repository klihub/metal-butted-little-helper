;;; metal-butt-prompt.el --- Locate claude: prompt blocks  -*- lexical-binding: t; -*-

;;; Commentary:
;; Finds a comment block introduced by the attention word at or above point.
;; Detection matches a leading run of punctuation rather than `comment-start',
;; because `comment-start' is "/* " in c-mode while users type "//".

;;; Code:

(defgroup metal-butt nil
  "Pair programming with Claude from Emacs buffers."
  :group 'tools
  :prefix "metal-butt-")

(defcustom metal-butt-attention-word "claude"
  "Word that marks a comment as a prompt for Claude."
  :type 'string
  :group 'metal-butt)

(defconst metal-butt-prompt--comment-rx
  "^\\([[:space:]]*\\)\\([^[:alnum:][:space:]]+\\)[[:space:]]*"
  "Matches indentation (group 1) and comment punctuation (group 2).")

(defun metal-butt-prompt--attention-rx ()
  "Regexp matching a line that opens a prompt block."
  (concat metal-butt-prompt--comment-rx
          (regexp-quote metal-butt-attention-word)
          ":[[:space:]]*"))

(defun metal-butt-prompt--line-indent ()
  "Return indentation string of the current line, or nil if not a comment line."
  (save-excursion
    (beginning-of-line)
    (when (looking-at metal-butt-prompt--comment-rx)
      (match-string 1))))

(defun metal-butt-prompt--attention-line-p ()
  "Non-nil if the current line opens a prompt block."
  (save-excursion
    (beginning-of-line)
    (let ((case-fold-search t))
      (looking-at (metal-butt-prompt--attention-rx)))))

(defun metal-butt-prompt--strip-line ()
  "Return the current line's text with comment punctuation removed."
  (save-excursion
    (beginning-of-line)
    (let ((case-fold-search t)
          (attention-rx (metal-butt-prompt--attention-rx)))
      (if (looking-at attention-rx)
          (buffer-substring-no-properties (match-end 0) (line-end-position))
        (if (looking-at metal-butt-prompt--comment-rx)
            (buffer-substring-no-properties (match-end 0) (line-end-position))
          "")))))

(defun metal-butt-prompt--find-attention-line ()
  "Move point to the attention line of the block at or above point.
Return non-nil on success."
  (beginning-of-line)
  (cond
   ((metal-butt-prompt--attention-line-p) t)
   ;; Walk up through a contiguous comment run at the same indentation.
   (t (let ((indent (metal-butt-prompt--line-indent))
            (found nil))
        (while (and (not found)
                    (metal-butt-prompt--line-indent)
                    (equal (metal-butt-prompt--line-indent) indent)
                    (not (bobp)))
          (forward-line -1)
          (when (metal-butt-prompt--attention-line-p)
            (setq found t)))
        ;; Point started on a non-comment line: check the line directly above.
        (unless (or found indent)
          (forward-line -1)
          (when (metal-butt-prompt--attention-line-p)
            (setq found t)))
        found))))

(defun metal-butt-prompt-at-point ()
  "Return the prompt block at or above point, or nil.
The value is a plist (:text STRING :start MARKER :end MARKER)."
  (save-excursion
    (when (metal-butt-prompt--find-attention-line)
      (let* ((start (copy-marker (line-beginning-position)))
             (indent (metal-butt-prompt--line-indent))
             (lines (list (metal-butt-prompt--strip-line))))
        (forward-line 1)
        (while (and (not (eobp))
                    (equal (metal-butt-prompt--line-indent) indent)
                    (not (metal-butt-prompt--attention-line-p)))
          (push (metal-butt-prompt--strip-line) lines)
          (forward-line 1))
        (list :text (string-join (nreverse lines) "\n")
              :start start
              :end (copy-marker (point)))))))

(provide 'metal-butt-prompt)
;;; metal-butt-prompt.el ends here
