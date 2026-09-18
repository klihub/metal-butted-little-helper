;;; metal-butt-handoff.el --- Append-only context handoff  -*- lexical-binding: t; -*-

;;; Commentary:
;; One handoff format, three channels: terminal to Emacs, Emacs to terminal,
;; and session to successor.  One file per direction with a single writer, so
;; there is no interleaving and therefore no locking.

;;; Code:

(require 'metal-butt-session)

(defconst metal-butt-handoff-channels '(to-emacs to-terminal self-handoff))

(defun metal-butt-handoff--check-channel (channel)
  (unless (memq channel metal-butt-handoff-channels)
    (error "Unknown handoff channel: %S" channel)))

(defun metal-butt-handoff-file (repo-root channel)
  "Return the file backing CHANNEL in REPO-ROOT."
  (metal-butt-handoff--check-channel channel)
  (expand-file-name (format "%s.md" channel)
                    (metal-butt-session-dir repo-root)))

(defun metal-butt-handoff--offsets-file (repo-root)
  (expand-file-name "offsets" (metal-butt-session-dir repo-root)))

(defun metal-butt-handoff--offsets (repo-root)
  (let ((file (metal-butt-handoff--offsets-file repo-root)))
    (or (and (file-readable-p file)
             (ignore-errors
               (with-temp-buffer
                 (insert-file-contents file)
                 (read (current-buffer)))))
        nil)))

(defun metal-butt-handoff--set-offset (repo-root channel offset)
  (let* ((offsets (assq-delete-all channel (metal-butt-handoff--offsets repo-root)))
         (updated (cons (cons channel offset) offsets)))
    (make-directory (metal-butt-session-dir repo-root) t)
    (with-temp-file (metal-butt-handoff--offsets-file repo-root)
      (prin1 updated (current-buffer))
      (insert "\n"))))

(defun metal-butt-handoff-append (repo-root channel text)
  "Append TEXT to CHANNEL in REPO-ROOT."
  (let ((file (metal-butt-handoff-file repo-root channel)))
    (make-directory (metal-butt-session-dir repo-root) t)
    (with-temp-buffer
      (insert text)
      (unless (string-suffix-p "\n" text) (insert "\n"))
      (write-region (point-min) (point-max) file t 'quiet))))

(defun metal-butt-handoff-peek (repo-root channel)
  "Return (TEXT . OFFSET) for the unconsumed tail of CHANNEL in REPO-ROOT.
Does not advance the recorded offset.  Pass OFFSET to
`metal-butt-handoff-ack' once TEXT has actually been used, so that a failed
request does not silently discard a note."
  (let ((file (metal-butt-handoff-file repo-root channel)))
    (if (not (file-readable-p file))
        (cons "" 0)
      (let* ((size (file-attribute-size (file-attributes file)))
             (recorded (or (alist-get channel
                                      (metal-butt-handoff--offsets repo-root))
                           0))
             (offset (if (> recorded size) 0 recorded)))
        (if (>= offset size)
            (cons "" size)
          (with-temp-buffer
            (insert-file-contents file nil offset size)
            (cons (buffer-string) size)))))))

(defun metal-butt-handoff-ack (repo-root channel offset)
  "Record OFFSET as consumed for CHANNEL in REPO-ROOT."
  (metal-butt-handoff--set-offset repo-root channel offset))

(defun metal-butt-handoff-consume (repo-root channel)
  "Return the unconsumed tail of CHANNEL in REPO-ROOT, advancing the offset.
Returns the empty string when there is nothing new.  If the file has
shrunk since the offset was recorded, re-read from zero: duplicated
context is acceptable, skipped context is not."
  (let ((peeked (metal-butt-handoff-peek repo-root channel)))
    (unless (string-empty-p (car peeked))
      (metal-butt-handoff-ack repo-root channel (cdr peeked)))
    (car peeked)))

(provide 'metal-butt-handoff)
;;; metal-butt-handoff.el ends here
