;;; metal-butt-context.el --- Assemble the request payload  -*- lexical-binding: t; -*-

;;; Commentary:
;; Sends the buffer's live content, never the file on disk: the buffer
;; frequently holds unsaved changes, which makes the file a stale copy.

;;; Code:

(require 'metal-butt-handoff)

(defcustom metal-butt-max-buffer-chars 20000
  "Send at most this much buffer text; larger buffers send a window around point."
  :type 'integer
  :group 'metal-butt)

(defun metal-butt-context--buffer-text ()
  "Return buffer text, or a window around point for large buffers.
The second value of the returned cons is non-nil when truncated."
  (if (<= (buffer-size) metal-butt-max-buffer-chars)
      (cons (buffer-substring-no-properties (point-min) (point-max)) nil)
    (let* ((half (/ metal-butt-max-buffer-chars 2))
           (beg (max (point-min) (- (point) half)))
           (end (min (point-max) (+ (point) half))))
      (cons (buffer-substring-no-properties beg end) t))))

(defun metal-butt-context-build (prompt repo-root)
  "Build the text piped to `claude -p' for PROMPT in REPO-ROOT.
Call with the target buffer current."
  (let* ((text-and-flag (metal-butt-context--buffer-text))
         (body (car text-and-flag))
         (truncated (cdr text-and-flag))
         (handoff (metal-butt-handoff-consume repo-root 'to-emacs))
         (parts nil))
    (push (format "## Request\n\n%s\n" prompt) parts)
    (unless (string-empty-p handoff)
      (push (format "## Context handed over from the terminal session\n\n%s\n" handoff)
            parts))
    (push (format "## Buffer\n\nFile: %s\nMajor mode: %s\nPoint: line %d\n%s"
                  (or (buffer-file-name) "(unsaved buffer)")
                  major-mode
                  (line-number-at-pos)
                  (if truncated
                      "Note: buffer was truncated to a window around point.\n"
                    ""))
          parts)
    (when (use-region-p)
      (push (format "\n## Selected region\n\n```\n%s\n```\n"
                    (buffer-substring-no-properties (region-beginning) (region-end)))
            parts))
    (push (format "\n```\n%s\n```\n" body) parts)
    (string-join (nreverse parts) "\n")))

(provide 'metal-butt-context)
;;; metal-butt-context.el ends here
