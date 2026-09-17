;;; metal-butt.el --- Pair programming with Claude from Emacs buffers  -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; Type a prompt in your buffer's own comment syntax and press C-c b:
;;
;;   // claude: extract this into a helper
;;   // and add a test for the empty case
;;
;; Code edits come back as an accept/reject overlay; discussion comes back
;; as a comment block.  Claude never writes to disk.

;;; Code:

(require 'cl-lib)
(require 'metal-butt-prompt)
(require 'metal-butt-context)
(require 'metal-butt-transport)
(require 'metal-butt-response)
(require 'metal-butt-overlay)
(require 'metal-butt-comment)
(require 'metal-butt-session)
(require 'metal-butt-handoff)

(defcustom metal-butt-delete-prompt-after-send nil
  "When non-nil, remove the prompt comment once it has been answered."
  :type 'boolean
  :group 'metal-butt)

(defvar-local metal-butt--in-flight nil)
(defvar-local metal-butt--last-cost 0)
(defvar-local metal-butt--last-input-tokens 0)

(defun metal-butt-repo-root ()
  "Return the top-level directory of the current repository."
  (or (locate-dominating-file (or default-directory "") ".git")
      (error "Not inside a git repository")))

(defun metal-butt--apply (response prompt)
  "Apply RESPONSE for PROMPT in the current buffer."
  (pcase (plist-get response :kind)
    ('reply
     (metal-butt-comment-insert (plist-get response :text)
                                (marker-position (plist-get prompt :end))))
    ('edit
     (metal-butt-overlay-propose-all (plist-get response :edits))))
  (when (and metal-butt-delete-prompt-after-send
             (eq (plist-get response :kind) 'reply))
    (delete-region (plist-get prompt :start) (plist-get prompt :end))))

(defun metal-butt--handle (buffer prompt tick result error)
  "Handle RESULT or ERROR for PROMPT sent from BUFFER at modification TICK.
Does nothing if BUFFER was killed while the request was in flight."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq metal-butt--in-flight nil)
      (cond
       (error
        (setq metal-butt--last-cost 0
              metal-butt--last-input-tokens 0)
        (force-mode-line-update)
        (message "Metal Butt: %s" error))
       ((/= tick (buffer-chars-modified-tick))
        (message "Metal Butt: buffer changed while the request was in flight; response discarded"))
       (t
        (setq metal-butt--last-cost (plist-get result :cost)
              metal-butt--last-input-tokens (plist-get result :input-tokens))
        (condition-case e
            (metal-butt--apply (metal-butt-response-parse (plist-get result :text)) prompt)
          (metal-butt-response-invalid (message "Metal Butt: %s" (cadr e)))
          (metal-butt-overlay-no-match (message "Metal Butt: %s" (cadr e)))
          (metal-butt-overlay-ambiguous (message "Metal Butt: %s" (cadr e))))
        (force-mode-line-update)
        (when (metal-butt-session-should-roll-p metal-butt--last-input-tokens)
          (message "Metal Butt: context is large (%d input tokens); M-x metal-butt-roll-session"
                   metal-butt--last-input-tokens)))))))

(defun metal-butt-send-prompt ()
  "Send the `claude:' comment block at or above point."
  (interactive)
  (when metal-butt--in-flight
    (error "Metal Butt: a request is already in flight for this buffer"))
  (save-excursion
    (let ((prompt (or (metal-butt-prompt-at-point)
                      (error "Metal Butt: no `%s:' comment block at point"
                             metal-butt-attention-word)))
          (root (metal-butt-repo-root)))
      (let ((request (metal-butt-context-build (plist-get prompt :text) root))
            (tick (buffer-chars-modified-tick))
            (buffer (current-buffer)))
        (setq metal-butt--in-flight t)
        (message "Metal Butt: thinking...")
        (condition-case err
            (metal-butt-transport-send
             request
             (metal-butt-session-current-id root)
             (lambda (result error)
               (metal-butt--handle buffer prompt tick result error)))
          (error
           (setq metal-butt--in-flight nil)
           (signal (car err) (cdr err))))))))

(defun metal-butt-roll-session ()
  "Summarise this session into a handoff note and start a fresh generation."
  (interactive)
  (metal-butt-session-roll (metal-butt-repo-root)))

(defvar metal-butt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c b") #'metal-butt-send-prompt)
    (define-key map (kbd "C-c C-a") #'metal-butt-accept)
    (define-key map (kbd "C-c C-r") #'metal-butt-reject)
    map)
  "Keymap for `metal-butt-mode'.")

;;;###autoload
(define-minor-mode metal-butt-mode
  "Prompt Claude from this buffer's comments."
  :lighter (:eval (if (> metal-butt--last-cost 0)
                      (format " MB $%.4f" metal-butt--last-cost)
                    " MB"))
  :keymap metal-butt-mode-map)

(provide 'metal-butt)
;;; metal-butt.el ends here
