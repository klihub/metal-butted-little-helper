;;; metal-butt-context.el --- Assemble the request payload  -*- lexical-binding: t; -*-

;;; Commentary:
;; Sends the buffer's live content, never the file on disk: the buffer
;; frequently holds unsaved changes, which makes the file a stale copy.

;;; Code:

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

(defun metal-butt-context-build (prompt repo-root &optional handoff history)
  "Build the text piped to `claude -p' for PROMPT in REPO-ROOT.
HANDOFF is pending handoff text to include; the caller owns reading and
acknowledging it.  HISTORY, when given, is a list of (PROMPT . ANSWER)
conses from earlier turns of the same `metal-butt-ask' conversation,
oldest first; included so a follow-up question is answered with the
prior exchange in mind instead of the model seeing only the buffer and
the new question, as if this were the first thing ever asked.  Call with
the target buffer current."
  (ignore repo-root)
  (let* ((text-and-flag (metal-butt-context--buffer-text))
         (body (car text-and-flag))
         (truncated (cdr text-and-flag))
         (handoff (or handoff ""))
         (parts nil))
    (push (format "## Request\n\n%s\n" prompt) parts)
    (when history
      (push (concat "## Earlier turns in this conversation\n\n"
                     (mapconcat (lambda (turn)
                                  (format "Q: %s\nA: %s\n" (car turn) (cdr turn)))
                                history "\n")
                     "\n")
            parts))
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
