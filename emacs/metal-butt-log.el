;;; metal-butt-log.el --- Event/debug log buffer  -*- lexical-binding: t; -*-

;;; Commentary:
;; A persistent, timestamped record of what Metal Butt actually did --
;; requests dispatched, their outcome, timing, backend fallbacks, and
;; background token refreshes -- kept in its own buffer rather than
;; relying on the echo area (which only keeps the last message) or
;; `*Messages*' (which mixes in everything else Emacs and every other
;; package logs). Modelled on the analogous "*copilot events*"/"*lsp-log*"
;; convention: append-only, capped so it cannot grow without bound, never
;; auto-displayed.
;;
;; `metal-butt--dispatch'/`metal-butt--handle' in metal-butt.el log one
;; line per request regardless of backend; a few backend-specific spots
;; (the copilot-api-unavailable fallback, its background token refresh)
;; log events that never otherwise surface as a user-visible message, so
;; a problem that only shows up intermittently still leaves a trail.

;;; Code:

(defcustom metal-butt-log-enabled t
  "When non-nil, `metal-butt-log' appends events to `metal-butt-log-buffer-name'.
Disable to stop logging entirely; existing log content is left alone."
  :type 'boolean
  :group 'metal-butt)

(defconst metal-butt-log-buffer-name "*metal-butt events*"
  "Name of the buffer `metal-butt-log' appends to.")

(defcustom metal-butt-log-max-chars 200000
  "Approximate cap on `metal-butt-log-buffer-name's size, in characters.
Once exceeded, the oldest lines are dropped so the buffer stays bounded
during a long Emacs session instead of growing forever."
  :type 'integer
  :group 'metal-butt)

(define-derived-mode metal-butt-log-mode special-mode "MB-Log"
  "Major mode for `metal-butt-log-buffer-name'.
A plain `special-mode' buffer: read-only, `q' to quit its window, no
undo history to accumulate -- it is a log, not something to edit.")

(defun metal-butt-log--buffer ()
  "Return the log buffer, creating it in `metal-butt-log-mode' if needed."
  (or (get-buffer metal-butt-log-buffer-name)
      (with-current-buffer (get-buffer-create metal-butt-log-buffer-name)
        (metal-butt-log-mode)
        (current-buffer))))

(defun metal-butt-log--trim (buffer)
  "Drop the oldest lines from BUFFER until it is under `metal-butt-log-max-chars'."
  (with-current-buffer buffer
    (when (> (- (point-max) (point-min)) metal-butt-log-max-chars)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (max (point-min) (- (point-max) metal-butt-log-max-chars)))
          (forward-line 1)
          (delete-region (point-min) (point)))))))

(defun metal-butt-log (format-string &rest args)
  "Append a timestamped line built from FORMAT-STRING and ARGS to the log.
Does nothing when `metal-butt-log-enabled' is nil. Never signals: a
formatting mistake here must not break the request it is trying to
describe, so a failure to format is logged as a plain string instead of
raised."
  (when metal-butt-log-enabled
    (let* ((buffer (metal-butt-log--buffer))
           (line (condition-case e
                     (apply #'format format-string args)
                   (error (format "[unformattable log message: %s]"
                                  (error-message-string e))))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert (format-time-string "[%H:%M:%S.%3N] ") line "\n"))))
      (metal-butt-log--trim buffer))))

(defun metal-butt-show-log ()
  "Display `metal-butt-log-buffer-name', moving point to its end."
  (interactive)
  (let ((buffer (metal-butt-log--buffer)))
    (with-current-buffer buffer
      (goto-char (point-max)))
    (display-buffer buffer)
    (let ((window (get-buffer-window buffer)))
      (when window (set-window-point window (point-max))))))

(provide 'metal-butt-log)
;;; metal-butt-log.el ends here
