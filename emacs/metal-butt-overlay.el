;;; metal-butt-overlay.el --- Review proposed edits before applying  -*- lexical-binding: t; -*-

;;; Commentary:
;; Edits arrive as string pairs rather than line numbers, because line numbers
;; go stale the moment anything above the target is typed.  An `old' that does
;; not match exactly once is refused rather than guessed at.

;;; Code:

(define-error 'metal-butt-overlay-no-match
  "Proposed edit does not match the buffer")
(define-error 'metal-butt-overlay-ambiguous
  "Proposed edit matches the buffer in more than one place")

(defvar-local metal-butt-overlay--overlay nil)
(defvar-local metal-butt-overlay--queue nil)
(defvar-local metal-butt-overlay--current nil)

(defface metal-butt-overlay-face
  '((t :inherit diff-refine-added))
  "Face for a proposed edit awaiting review."
  :group 'metal-butt)

(defun metal-butt-overlay-locate (old)
  "Return the position of the unique occurrence of OLD in the buffer."
  (save-excursion
    (goto-char (point-min))
    (if (not (search-forward old nil t))
        (signal 'metal-butt-overlay-no-match
                (list (format "no match for: %s" (truncate-string-to-width old 60))))
      (let ((first (match-beginning 0)))
        (if (search-forward old nil t)
            (signal 'metal-butt-overlay-ambiguous
                    (list (format "%s matches more than once"
                                  (truncate-string-to-width old 60))))
          first)))))

(defun metal-butt-overlay-pending-p ()
  "Non-nil when an edit is awaiting accept or reject."
  (and metal-butt-overlay--current t))

(defun metal-butt-overlay--clear ()
  (when (overlayp metal-butt-overlay--overlay)
    (delete-overlay metal-butt-overlay--overlay))
  (setq metal-butt-overlay--overlay nil
        metal-butt-overlay--current nil))

(defun metal-butt-overlay-propose (edit)
  "Show EDIT for review."
  (let* ((old (plist-get edit :old))
         (pos (metal-butt-overlay-locate old))
         (ov (make-overlay pos (+ pos (length old)))))
    (overlay-put ov 'face 'metal-butt-overlay-face)
    (overlay-put ov 'after-string
                 (propertize (format " → %s" (plist-get edit :new))
                             'face 'metal-butt-overlay-face))
    (setq metal-butt-overlay--overlay ov
          metal-butt-overlay--current edit)
    (goto-char pos)
    (message "%s  (C-c C-a accept, C-c C-r reject)"
             (or (plist-get edit :why) "Proposed edit"))))

(defun metal-butt-overlay--next ()
  "Offer the next queued edit, skipping any whose text no longer matches.
A stale edit must not strand the edits behind it in the queue."
  (let ((offered nil))
    (while (and (not offered) metal-butt-overlay--queue)
      (let ((next (pop metal-butt-overlay--queue)))
        (condition-case e
            (progn (metal-butt-overlay-propose next)
                   (setq offered t))
          ((metal-butt-overlay-no-match metal-butt-overlay-ambiguous)
           (message "Metal Butt: skipping an edit — %s" (cadr e))))))
    (unless offered
      (message "No more proposed edits"))))

(defun metal-butt-overlay-propose-all (edits)
  "Queue EDITS for review, offering the first one that still matches."
  (setq metal-butt-overlay--queue edits)
  (metal-butt-overlay--next))

(defun metal-butt-accept ()
  "Apply the proposed edit."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to accept"))
  (let* ((edit metal-butt-overlay--current)
         (ov metal-butt-overlay--overlay)
         (beg (overlay-start ov))
         (end (overlay-end ov)))
    (metal-butt-overlay--clear)
    (save-excursion
      (goto-char beg)
      (delete-region beg end)
      (insert (plist-get edit :new)))
    (metal-butt-overlay--next)))

(defun metal-butt-reject ()
  "Discard the proposed edit."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to reject"))
  (metal-butt-overlay--clear)
  (metal-butt-overlay--next))

(provide 'metal-butt-overlay)
;;; metal-butt-overlay.el ends here
