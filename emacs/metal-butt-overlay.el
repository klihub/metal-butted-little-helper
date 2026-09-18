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
(defvar-local metal-butt-overlay--style-override nil
  "Buffer-local override of the rendering style for the pending edit only.
Nil means \"use `metal-butt-overlay-diff-style'\"; `full' or `diff' pins the
pending edit to that style regardless of the defcustom, until the next
edit is proposed or accepted/rejected, at which point it resets to nil so
a stale per-edit toggle cannot leak onto an unrelated later edit.")

(defcustom metal-butt-overlay-diff-style 'full
  "How to render a proposed edit awaiting review.
`full' highlights the matched old text in place and appends the new text
after it as \" → new\" -- compact, and fine for short, single-line edits.
`diff' instead strikes through the old text and shows the new text on its
own line prefixed with `+', closer to how a unified diff hunk reads --
easier to follow for a multi-line edit where the `full' style's inline
arrow can bury the change in a wall of text.  Either edit in flight can be
viewed as the other style with `metal-butt-overlay-toggle-style' (bound to
`C-c C-d') without this default changing, so this only picks the starting
point."
  :type '(choice (const :tag "Full region, old → new inline" full)
                  (const :tag "Diff-like, struck-through old / + new" diff))
  :group 'metal-butt)

(defface metal-butt-overlay-face
  '((t :inherit diff-refine-added))
  "Face for the new text of a proposed edit in `full' style."
  :group 'metal-butt)

(defface metal-butt-overlay-removed-face
  '((t :inherit diff-refine-removed))
  "Face for the old text of a proposed edit in `diff' style."
  :group 'metal-butt)

(defface metal-butt-overlay-added-face
  '((t :inherit diff-refine-added))
  "Face for the new text of a proposed edit in `diff' style."
  :group 'metal-butt)

(defun metal-butt-overlay--style ()
  "Return the style to render the pending edit with: `full' or `diff'."
  (or metal-butt-overlay--style-override metal-butt-overlay-diff-style))

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
        metal-butt-overlay--current nil
        metal-butt-overlay--style-override nil))

(defun metal-butt-overlay--render (ov edit style)
  "Set OV's display properties to show EDIT in STYLE (`full' or `diff')."
  (let ((old (plist-get edit :old))
        (new (plist-get edit :new)))
    (pcase style
      ('diff
       (overlay-put ov 'face 'metal-butt-overlay-removed-face)
       (overlay-put ov 'display
                     (propertize old 'face
                                 '(:strike-through t :inherit metal-butt-overlay-removed-face)))
       (overlay-put ov 'after-string
                     (propertize (concat "\n+" new)
                                 'face 'metal-butt-overlay-added-face)))
      (_
       (overlay-put ov 'face 'metal-butt-overlay-face)
       (overlay-put ov 'display nil)
       (overlay-put ov 'after-string
                     (propertize (format " → %s" new)
                                 'face 'metal-butt-overlay-face))))))

(defun metal-butt-overlay-propose (edit)
  "Show EDIT for review."
  (let* ((old (plist-get edit :old))
         (pos (metal-butt-overlay-locate old))
         (ov (make-overlay pos (+ pos (length old)))))
    (setq metal-butt-overlay--overlay ov
          metal-butt-overlay--current edit
          metal-butt-overlay--style-override nil)
    (metal-butt-overlay--render ov edit (metal-butt-overlay--style))
    (goto-char pos)
    (message "%s  (C-c C-a accept, C-c C-r reject, C-c C-d toggle diff/full view)"
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

(defun metal-butt-overlay-toggle-style ()
  "Switch the pending edit between `full' and `diff' rendering.
Only affects the edit currently awaiting review; the next edit proposed
falls back to `metal-butt-overlay-diff-style' again, so a one-off look at
a big edit as a diff does not silently change how every future edit is
shown."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to toggle"))
  (setq metal-butt-overlay--style-override
        (pcase (metal-butt-overlay--style)
          ('diff 'full)
          (_ 'diff)))
  (metal-butt-overlay--render metal-butt-overlay--overlay
                              metal-butt-overlay--current
                              (metal-butt-overlay--style))
  (message "Metal Butt: showing proposed edit as %s"
           (metal-butt-overlay--style)))

(provide 'metal-butt-overlay)
;;; metal-butt-overlay.el ends here
