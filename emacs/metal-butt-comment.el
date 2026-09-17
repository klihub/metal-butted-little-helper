;;; metal-butt-comment.el --- Insert an answer as a comment block  -*- lexical-binding: t; -*-

;;; Commentary:
;; Answers that are discussion rather than a change get written into the
;; buffer as comments, so the conversation lives next to the code it is about.

;;; Code:

(defun metal-butt-comment-insert (text position)
  "Insert TEXT at POSITION as comment lines.  Return the end position."
  (save-excursion
    (goto-char position)
    (unless (bolp) (insert "\n"))
    (let ((beg (point)))
      (insert (string-trim-right text) "\n")
      (comment-region beg (point))
      (point))))

(provide 'metal-butt-comment)
;;; metal-butt-comment.el ends here
