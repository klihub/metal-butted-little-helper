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
;;
;; Or press C-c p to ask from the minibuffer, leaving the buffer untouched;
;; the answer appears in its own window.

;;; Code:

(require 'cl-lib)
(require 'metal-butt-prompt)
(require 'metal-butt-context)
(require 'metal-butt-transport)
(require 'metal-butt-transport-copilot)
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
(defvar-local metal-butt--last-premium-requests 0)

(defvar-local metal-butt--buffer-model nil
  "Model for this buffer alone, set by `metal-butt-set-model' with a prefix arg.")

(defun metal-butt-effective-model (&optional prompt-model)
  "Return the model to use, most specific setting first.
PROMPT-MODEL comes from an @model directive, then the buffer-local setting
from `metal-butt-set-model', then `metal-butt-active-model' (the explicit
override `metal-butt-model' if set, else the active backend's own
default)."
  (or prompt-model metal-butt--buffer-model (metal-butt-active-model)))

(defun metal-butt-set-model (model &optional buffer-only)
  "Set the model to MODEL, globally, or for this buffer with a prefix arg.
Reads with completion so no elisp is needed and a typo cannot become a
wasted API call.  Candidates come from whichever backend is active
\(`metal-butt-known-models' for `claude', `metal-butt-copilot-known-models'
for `copilot'\); typing a name outside that list is still accepted, since
completion here is a convenience, not the whole validation."
  (interactive
   (list (completing-read
          (format "Model (currently %s): " (metal-butt-effective-model))
          (metal-butt-active-known-models) nil nil)
         current-prefix-arg))
  (metal-butt-check-model model)
  (if buffer-only
      (setq-local metal-butt--buffer-model model)
    (setq metal-butt-model model))
  (force-mode-line-update)
  (cond
   (buffer-only (message "Metal Butt: model set to %s for this buffer" model))
   (metal-butt--buffer-model
    (message "Metal Butt: model set to %s globally, but this buffer overrides with %s (use C-u to change it here)"
             model metal-butt--buffer-model))
   (t (message "Metal Butt: model set to %s globally" model))))

(defun metal-butt-repo-root ()
  "Return the top-level directory of the current repository, fully resolved.
Resolved with `file-truename' so that two spellings of one directory — a
symlink and its target, say — do not hash to two different session ids."
  (let ((root (locate-dominating-file (or default-directory "") ".git")))
    (unless root (error "Not inside a git repository"))
    (file-truename root)))

(defun metal-butt--show-reply (text)
  "Show TEXT in the reply window, leaving the code buffer untouched."
  (let ((buffer (get-buffer-create "*metal-butt-reply*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min)))
      (view-mode 1))
    (display-buffer buffer)))

(defun metal-butt--apply (response prompt)
  "Apply RESPONSE for PROMPT in the current buffer."
  (pcase (plist-get response :kind)
    ('reply
     (if (eq (plist-get prompt :reply) 'window)
         (metal-butt--show-reply (plist-get response :text))
       (metal-butt-comment-insert (plist-get response :text)
                                  (marker-position (plist-get prompt :end)))))
    ('edit
     (metal-butt-overlay-propose-all (plist-get response :edits))))
  (when (and metal-butt-delete-prompt-after-send
             (eq (plist-get response :kind) 'reply)
             (plist-get prompt :start))
    (delete-region (plist-get prompt :start) (plist-get prompt :end))))

(defun metal-butt--handle (buffer prompt tick result error &optional ack)
  "Handle RESULT or ERROR for PROMPT sent from BUFFER at modification TICK.
Does nothing if BUFFER was killed while the request was in flight.
ACK, when given, is called after a response has been applied, so a failed or
discarded response does not consume pending handoff context."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq metal-butt--in-flight nil)
      (cond
       (error
        (setq metal-butt--last-cost 0
              metal-butt--last-input-tokens 0
              metal-butt--last-premium-requests 0)
        (force-mode-line-update)
        (message "Metal Butt: %s" error))
       ((and (/= tick (buffer-chars-modified-tick))
             (not (eq (plist-get prompt :reply) 'window)))
        (message "Metal Butt: buffer changed while the request was in flight; response discarded"))
       (t
        (setq metal-butt--last-cost (plist-get result :cost)
              metal-butt--last-input-tokens (plist-get result :input-tokens)
              metal-butt--last-premium-requests (or (plist-get result :premium-requests) 0))
        (condition-case e
            (metal-butt--apply (metal-butt-response-parse (plist-get result :text)) prompt)
          (metal-butt-response-invalid
           (message "Metal Butt: %s (M-x metal-butt-show-last-exchange to see the payload)"
                    (cadr e)))
          (metal-butt-overlay-no-match (message "Metal Butt: %s" (cadr e)))
          (metal-butt-overlay-ambiguous (message "Metal Butt: %s" (cadr e))))
        (force-mode-line-update)
        (when (metal-butt-session-should-roll-p metal-butt--last-input-tokens)
          (message "Metal Butt: context is large (%d input tokens); M-x metal-butt-roll-session"
                   metal-butt--last-input-tokens))
        (when ack (funcall ack)))))))

(defun metal-butt--dispatch (prompt)
  "Send PROMPT and arrange for its response to be applied.
PROMPT is a plist: :text and optional :model, plus :reply, which is `comment'
to insert an answer into the buffer or `window' to show it separately.  A
prompt located in the buffer also carries :start and :end markers."
  (when metal-butt--in-flight
    (error "Metal Butt: a request is already in flight for this buffer"))
  (when (string-match-p "\\`[ \t\n]*\\'" (plist-get prompt :text))
    (error "Metal Butt: the prompt is empty"))
  (when (plist-get prompt :model)
    (metal-butt-check-model (plist-get prompt :model)))
  (let* ((root (metal-butt-repo-root))
         (handoff (metal-butt-handoff-peek root 'to-emacs))
         (request (metal-butt-context-build (plist-get prompt :text)
                                            root (car handoff)))
         (tick (buffer-chars-modified-tick))
         (buffer (current-buffer))
         (ack (lambda ()
                (unless (string-empty-p (car handoff))
                  (metal-butt-handoff-ack root 'to-emacs (cdr handoff))))))
    (let ((metal-butt-model (metal-butt-effective-model (plist-get prompt :model))))
      (setq metal-butt--in-flight t)
      (message "Metal Butt: thinking...")
      (condition-case err
          (metal-butt-transport-send
           request
           (metal-butt-session-current-id root)
           (lambda (result error)
             (metal-butt--handle buffer prompt tick result error ack)))
        (error
         (setq metal-butt--in-flight nil)
         (signal (car err) (cdr err)))))))

(defun metal-butt-send-prompt ()
  "Send the attention-word comment block at or above point."
  (interactive)
  (save-excursion
    (let ((prompt (or (metal-butt-prompt-at-point)
                      (error "Metal Butt: no `%s:' comment block at point"
                             (mapconcat #'identity metal-butt-attention-words "/")))))
      (metal-butt--dispatch (append prompt (list :reply 'comment))))))

(defvar metal-butt--ask-history nil
  "Prompts previously entered with `metal-butt-ask', for M-p recall.")

(defun metal-butt-ask (prompt)
  "Ask PROMPT about this buffer without writing the question into it.
The answer appears in a separate window; a proposed code edit still arrives
as an accept/reject overlay.  A leading @model directive works here too."
  (interactive (list (read-string "Ask Claude: " nil 'metal-butt--ask-history)))
  (let ((split (metal-butt-prompt--extract-model prompt)))
    (metal-butt--dispatch (list :text (cdr split)
                                :model (car split)
                                :reply 'window))))

(defun metal-butt-roll-session ()
  "Summarise this session into a handoff note and start a fresh generation."
  (interactive)
  (metal-butt-session-roll (metal-butt-repo-root)))

(defun metal-butt-show-last-exchange ()
  "Show the raw request and response of the most recent CLI invocation.
The place to look when a response fails to parse: the payload is otherwise
discarded along with the process buffers.  Shows whichever backend is
active's record: `metal-butt-transport-last-exchange' for `claude',
`metal-butt-transport-copilot-last-exchange' for `copilot',
`metal-butt-transport-copilot-api-last-exchange' for `copilot-api'."
  (interactive)
  (let ((exchange (pcase metal-butt-backend
                    ('copilot metal-butt-transport-copilot-last-exchange)
                    ('copilot-api metal-butt-transport-copilot-api-last-exchange)
                    (_ metal-butt-transport-last-exchange))))
    (if (null exchange)
        (message "Metal Butt: no exchange recorded yet")
      (with-current-buffer (get-buffer-create "*metal-butt-last-exchange*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "=== argv ===\n")
          (dolist (a (plist-get exchange :argv))
            (insert (format "  %s\n" a)))
          (insert (format "\n=== exit code ===\n  %S\n" (plist-get exchange :exit)))
          (insert (format "\n=== duration ===\n  %s\n"
                          (if (plist-get exchange :duration-ms)
                              (format "%.1fs" (/ (plist-get exchange :duration-ms) 1000.0))
                            "unknown")))
          (insert "\n=== request sent on stdin ===\n")
          (insert (or (plist-get exchange :request) ""))
          (insert "\n\n=== raw stdout ===\n")
          (insert (or (plist-get exchange :stdout) ""))
          (insert "\n\n=== raw stderr ===\n")
          (insert (or (plist-get exchange :stderr) ""))
          (goto-char (point-min)))
        (view-mode 1))
      (display-buffer "*metal-butt-last-exchange*"))))

(defconst metal-butt--modules
  '("metal-butt-prompt"
    "metal-butt-context"
    "metal-butt-response"
    "metal-butt-transport-copilot"
    "metal-butt-transport-copilot-api"
    "metal-butt-transport"
    "metal-butt-overlay"
    "metal-butt-comment"
    "metal-butt-session"
    "metal-butt-handoff"
    "metal-butt")
  "Every file of the package, entry point last.
`metal-butt-reload' walks this list, so a new module added to the package
must be added here too or it will be left stale by a reload.")

(defun metal-butt-reload ()
  "Reload every module of the package.
`require' is a no-op once a feature is loaded, so reloading only `metal-butt'
leaves the other modules at whatever version the session started with.  That
mixed state usually announces itself as a void function for something added
to another module since.  This force-loads all of them instead.

A request already in flight is not cancelled; its callback belongs to the
code that was loaded when it started."
  (interactive)
  (dolist (module metal-butt--modules)
    (load module nil t))
  (message "Metal Butt: reloaded %d modules" (length metal-butt--modules)))

(defvar metal-butt-mode-map (make-sparse-keymap)
  "Keymap for `metal-butt-mode'.
Bindings are installed below rather than in this initialiser.  `defvar' only
assigns when the variable is unbound, so bindings written here would never
appear in an Emacs that had already loaded the package once — reloading after
adding a key would silently do nothing.  Installing them at top level means a
reload applies them, while the `defvar' still protects keys you have added
yourself.")

(define-key metal-butt-mode-map (kbd "C-c b") #'metal-butt-send-prompt)
(define-key metal-butt-mode-map (kbd "C-c p") #'metal-butt-ask)
(define-key metal-butt-mode-map (kbd "C-c C-a") #'metal-butt-accept)
(define-key metal-butt-mode-map (kbd "C-c C-r") #'metal-butt-reject)
(define-key metal-butt-mode-map (kbd "C-c m") #'metal-butt-set-model)

;;;###autoload
(define-minor-mode metal-butt-mode
  "Prompt Claude or Copilot from this buffer's comments."
  :lighter (:eval (format " MB[%s]%s"
                          (metal-butt-effective-model)
                          (cond
                           ((eq metal-butt-backend 'copilot)
                            (if (> metal-butt--last-premium-requests 0)
                                (format " %dpr" metal-butt--last-premium-requests)
                              ""))
                           ((eq metal-butt-backend 'copilot-api) " api")
                           ((> metal-butt--last-cost 0)
                            (format " $%.4f" metal-butt--last-cost))
                           (t ""))))
  :keymap metal-butt-mode-map)

(provide 'metal-butt)
;;; metal-butt.el ends here
