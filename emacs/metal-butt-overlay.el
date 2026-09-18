;;; metal-butt-overlay.el --- Review proposed edits before applying  -*- lexical-binding: t; -*-

;;; Commentary:
;; Edits arrive as string pairs rather than line numbers, because line numbers
;; go stale the moment anything above the target is typed.  An `old' that does
;; not match exactly once is refused rather than guessed at.

;;; Code:

(require 'cl-lib)

(define-error 'metal-butt-overlay-no-match
  "Proposed edit does not match the buffer")
(define-error 'metal-butt-overlay-ambiguous
  "Proposed edit matches the buffer in more than one place")

(defvar-local metal-butt-overlay--overlay nil)
(defvar-local metal-butt-overlay--queue nil)
(defvar-local metal-butt-overlay--current nil)
(defvar-local metal-butt-overlay--hunks nil
  "Remaining not-yet-decided hunks of the edit currently under review.
Each hunk is a plist (:old :new) plus an overlay in :ov marking where its
old text sits in the buffer.  Hunks are resolved strictly in order --
`metal-butt-accept'/`metal-butt-reject' always act on the first one -- so
this is a queue, not something addressed by index.")
(defvar-local metal-butt-overlay--hunk-total 0
  "How many hunks the edit under review started with, for progress messages.")
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

(defun metal-butt-overlay--lcs-ops (old-lines new-lines)
  "Return a list of (TYPE . LINE) ops turning OLD-LINES into NEW-LINES.
TYPE is `equal', `del', or `add'.  Uses a plain O(n*m) LCS table, which is
fine for the modest, hand-review-sized edits this package deals with."
  (let* ((n (length old-lines))
         (m (length new-lines))
         (old-vec (vconcat old-lines))
         (new-vec (vconcat new-lines))
         (dp (make-vector (1+ n) nil)))
    (dotimes (i (1+ n)) (aset dp i (make-vector (1+ m) 0)))
    (cl-loop for i from 1 to n do
             (cl-loop for j from 1 to m do
                      (aset (aref dp i) j
                            (if (equal (aref old-vec (1- i)) (aref new-vec (1- j)))
                                (1+ (aref (aref dp (1- i)) (1- j)))
                              (max (aref (aref dp (1- i)) j)
                                   (aref (aref dp i) (1- j)))))))
    (let ((i n) (j m) (ops nil))
      (while (and (> i 0) (> j 0))
        (cond
         ((equal (aref old-vec (1- i)) (aref new-vec (1- j)))
          (push (cons 'equal (aref old-vec (1- i))) ops)
          (setq i (1- i) j (1- j)))
         ((>= (aref (aref dp (1- i)) j) (aref (aref dp i) (1- j)))
          (push (cons 'del (aref old-vec (1- i))) ops)
          (setq i (1- i)))
         (t
          (push (cons 'add (aref new-vec (1- j))) ops)
          (setq j (1- j)))))
      (while (> i 0) (push (cons 'del (aref old-vec (1- i))) ops) (setq i (1- i)))
      (while (> j 0) (push (cons 'add (aref new-vec (1- j))) ops) (setq j (1- j)))
      ops)))

(defun metal-butt-overlay--group-ops (ops)
  "Group line OPS into hunks, each a plist (:type `equal' or `change' :old :new).
Consecutive `del'/`add' ops merge into one `change' hunk pairing the
deleted lines as :old with the added lines as :new; consecutive `equal'
ops merge into one `equal' hunk with the same text on both sides."
  (let (hunks old-buf new-buf eq-buf)
    (cl-flet ((flush-change ()
                (when (or old-buf new-buf)
                  (push (list :type 'change
                               :old (mapconcat #'identity (nreverse old-buf) "\n")
                               :new (mapconcat #'identity (nreverse new-buf) "\n"))
                        hunks))
                (setq old-buf nil new-buf nil))
              (flush-equal ()
                (when eq-buf
                  (let ((text (mapconcat #'identity (nreverse eq-buf) "\n")))
                    (push (list :type 'equal :old text :new text) hunks)))
                (setq eq-buf nil)))
      (dolist (op ops)
        (pcase (car op)
          ('equal (flush-change) (push (cdr op) eq-buf))
          ('del (flush-equal) (push (cdr op) old-buf))
          ('add (flush-equal) (push (cdr op) new-buf))))
      (flush-change)
      (flush-equal))
    (nreverse hunks)))

(defun metal-butt-overlay--diff-hunks (old new)
  "Diff OLD against NEW at the line level, returning an ordered hunk list.
Each hunk is a plist (:type `equal' or `change' :old STRING :new STRING).
Concatenating every hunk's :old with \"\\n\" between hunks reconstructs
OLD exactly, which is what lets a later step map hunks back onto the
buffer positions OLD was found at."
  (if (equal old new)
      (list (list :type 'equal :old old :new new))
    (metal-butt-overlay--group-ops
     (metal-butt-overlay--lcs-ops (split-string old "\n") (split-string new "\n")))))

(defun metal-butt-overlay--position-hunks (hunks pos)
  "Annotate HUNKS with absolute :beg/:end buffer positions, OLD starting at POS.
Hunks were produced by splitting OLD on newlines and regrouping, so
rejoining every hunk's :old with a single newline between hunks
reconstructs OLD exactly; that is what lets each hunk's buffer span be
computed by simply walking forward from POS."
  (let ((offset pos)
        (n (length hunks)))
    (cl-loop for h in hunks
             for idx from 0 do
             (plist-put h :beg offset)
             (setq offset (+ offset (length (plist-get h :old))))
             (plist-put h :end offset)
             (when (< idx (1- n))
               (setq offset (1+ offset)))))
  hunks)

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
        metal-butt-overlay--hunks nil
        metal-butt-overlay--hunk-total 0
        metal-butt-overlay--style-override nil))

(defun metal-butt-overlay--render (ov edit style)
  "Set OV's display properties to show EDIT in STYLE (`full' or `diff').
EDIT need only have :old/:new -- a whole proposed edit and a single hunk
of one both satisfy that, so this doubles as the hunk renderer."
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

(defun metal-butt-overlay--hunk-progress ()
  "Return \"(k/n hunks) \" for the message line, or \"\" when there is one hunk."
  (if (<= metal-butt-overlay--hunk-total 1)
      ""
    (format "(%d/%d hunks) "
            (1+ (- metal-butt-overlay--hunk-total (length metal-butt-overlay--hunks)))
            metal-butt-overlay--hunk-total)))

(defun metal-butt-overlay--show-head ()
  "Build/redraw the overlay for the head of `metal-butt-overlay--hunks'."
  (let* ((head (car metal-butt-overlay--hunks))
         (ov (make-overlay (plist-get head :beg)
                            (+ (plist-get head :beg) (length (plist-get head :old))))))
    (setq metal-butt-overlay--overlay ov)
    (metal-butt-overlay--render ov head (metal-butt-overlay--style))
    (goto-char (plist-get head :beg))))

(defun metal-butt-overlay-propose (edit)
  "Show EDIT for review, one hunk (a contiguous changed span) at a time.
An EDIT whose :old and :new differ across several disjoint spans -- e.g.
a rename touching a handful of nearby lines -- is split into hunks so each
can be accepted or rejected on its own with `metal-butt-overlay-accept-hunk'
/ `metal-butt-overlay-reject-hunk', magit-stage-hunk style, while
`metal-butt-accept'/`metal-butt-reject' still take the whole edit at once
for the common single-hunk case."
  (let* ((old (plist-get edit :old))
         (new (plist-get edit :new))
         (pos (metal-butt-overlay-locate old))
         (all (metal-butt-overlay--position-hunks
               (metal-butt-overlay--diff-hunks old new) pos))
         (changes (seq-filter (lambda (h) (eq (plist-get h :type) 'change)) all)))
    ;; Annotate each change-hunk with the gap of unchanged text before the
    ;; next one, so resolving a hunk can locate the next one without a
    ;; fresh (and possibly now-ambiguous) buffer-wide search.
    (let ((rest changes))
      (while (cdr rest)
        (plist-put (car rest) :gap-after
                    (- (plist-get (cadr rest) :beg) (plist-get (car rest) :end)))
        (setq rest (cdr rest))))
    (if (null changes)
        (progn (message "Metal Butt: edit already applied, skipping")
               nil)
      (setq metal-butt-overlay--current edit
            metal-butt-overlay--hunks changes
            metal-butt-overlay--hunk-total (length changes)
            metal-butt-overlay--style-override nil)
      (metal-butt-overlay--show-head)
      (message "%s%s  (C-c C-a/C-c C-r accept/reject whole edit, C-c h a/C-c h r one hunk, C-c C-d toggle view)"
               (metal-butt-overlay--hunk-progress)
               (or (plist-get edit :why) "Proposed edit"))
      t)))

(defun metal-butt-overlay--next ()
  "Offer the next queued edit, skipping any whose text no longer matches
or that turn out to be no-ops once diffed against the buffer."
  (let ((offered nil))
    (while (and (not offered) metal-butt-overlay--queue)
      (let ((next (pop metal-butt-overlay--queue)))
        (condition-case e
            (setq offered (metal-butt-overlay-propose next))
          ((metal-butt-overlay-no-match metal-butt-overlay-ambiguous)
           (message "Metal Butt: skipping an edit — %s" (cadr e))))))
    (unless offered
      (message "No more proposed edits"))))

(defun metal-butt-overlay-propose-all (edits)
  "Queue EDITS for review, offering the first one that still matches."
  (setq metal-butt-overlay--queue edits)
  (metal-butt-overlay--next))

(defun metal-butt-overlay--resolve-hunk (accept)
  "Resolve the head of `metal-butt-overlay--hunks', applying it when ACCEPT.
Advances to the next hunk of the same edit, or to the next queued edit
once the last hunk of this one is resolved."
  (let* ((head (pop metal-butt-overlay--hunks))
         (ov metal-butt-overlay--overlay)
         (beg (overlay-start ov))
         (end (overlay-end ov))
         (gap (plist-get head :gap-after)))
    (delete-overlay ov)
    (setq metal-butt-overlay--overlay nil)
    (let ((tail-start
           (if accept
               (progn (save-excursion
                        (goto-char beg)
                        (delete-region beg end)
                        (insert (plist-get head :new)))
                      (+ beg (length (plist-get head :new))))
             end)))
      (if metal-butt-overlay--hunks
          (progn
            (plist-put (car metal-butt-overlay--hunks) :beg (+ tail-start gap))
            (plist-put (car metal-butt-overlay--hunks) :end
                        (+ tail-start gap
                           (length (plist-get (car metal-butt-overlay--hunks) :old))))
            (metal-butt-overlay--show-head)
            (message "%s%s"
                     (metal-butt-overlay--hunk-progress)
                     (or (plist-get metal-butt-overlay--current :why) "Proposed edit")))
        (setq metal-butt-overlay--current nil
              metal-butt-overlay--hunk-total 0
              metal-butt-overlay--style-override nil)
        (metal-butt-overlay--next)))))

(defun metal-butt-overlay-accept-hunk ()
  "Apply just the hunk currently under review, then move to the next one."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to accept"))
  (metal-butt-overlay--resolve-hunk t))

(defun metal-butt-overlay-reject-hunk ()
  "Discard just the hunk currently under review, then move to the next one."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to reject"))
  (metal-butt-overlay--resolve-hunk nil))

(defun metal-butt-accept ()
  "Apply every remaining hunk of the proposed edit (not later queued edits)."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to accept"))
  (let ((edit metal-butt-overlay--current))
    (while (eq metal-butt-overlay--current edit)
      (metal-butt-overlay--resolve-hunk t))))

(defun metal-butt-reject ()
  "Discard every remaining hunk of the proposed edit (not later queued edits)."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to reject"))
  (let ((edit metal-butt-overlay--current))
    (while (eq metal-butt-overlay--current edit)
      (metal-butt-overlay--resolve-hunk nil))))

(defun metal-butt-overlay-toggle-style ()
  "Switch the current hunk between `full' and `diff' rendering.
Only affects the hunk currently awaiting review; the next hunk or edit
falls back to `metal-butt-overlay-diff-style' again, so a one-off look at
a big change as a diff does not silently change how every future edit is
shown."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to toggle"))
  (setq metal-butt-overlay--style-override
        (pcase (metal-butt-overlay--style)
          ('diff 'full)
          (_ 'diff)))
  (metal-butt-overlay--render metal-butt-overlay--overlay
                              (car metal-butt-overlay--hunks)
                              (metal-butt-overlay--style))
  (message "Metal Butt: showing proposed edit as %s"
           (metal-butt-overlay--style)))

(provide 'metal-butt-overlay)
;;; metal-butt-overlay.el ends here
