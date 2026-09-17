;;; metal-butt-transport.el --- Talk to the claude CLI  -*- lexical-binding: t; -*-

;;; Commentary:
;; The only component with residual unknowns, so the only one behind an
;; injectable interface: rebind `metal-butt-transport-function' to a stub and
;; the whole pipeline is testable without spending API budget.
;;
;; The request is written to stdin rather than passed as an argument, because
;; it carries whole buffers and would otherwise hit argv length limits.

;;; Code:

(require 'seq)

(define-error 'metal-butt-transport-error "Claude CLI transport failed")

(defcustom metal-butt-executable "claude"
  "Name or path of the Claude Code CLI."
  :type 'string
  :group 'metal-butt)

(defcustom metal-butt-model "sonnet"
  "Model used for buffer prompts.
There is deliberately no automatic fallback to a cheaper model.  A silent
downgrade would change edit quality without the user knowing why, which is
harder to diagnose than an outright error."
  :type 'string
  :group 'metal-butt)

(defconst metal-butt-transport-contract
  "Respond with a single JSON object and nothing else. No prose, no code fences.
Either {\"kind\":\"edit\",\"edits\":[{\"old\":\"...\",\"new\":\"...\",\"why\":\"...\"}]}
where each `old' is text copied verbatim from the buffer and occurring exactly
once in it, or {\"kind\":\"reply\",\"text\":\"...\"} when the answer is discussion
rather than a change. Never propose an edit whose `old' you have not copied
character-for-character from the buffer shown to you."
  "Response contract, stated once per session via --append-system-prompt.")

(defun metal-butt-transport-argv (session-id &optional create)
  "Return the argument list for a request against SESSION-ID.
If CREATE is non-nil, use --session-id to create a session; else use --resume."
  (list "-p"
        (if create "--session-id" "--resume") session-id
        "--model" metal-butt-model
        "--output-format" "json"
        "--append-system-prompt" metal-butt-transport-contract
        "--disallowedTools" "Edit,Write,NotebookEdit"))

(defun metal-butt-transport--extract-result (json)
  "Pull the assistant text and usage figures out of JSON."
  (let ((data (condition-case err
                  (json-parse-string json :object-type 'alist
                                     :null-object nil :false-object nil)
                (error (signal 'metal-butt-transport-error
                               (list (format "unparseable CLI output: %s"
                                             (error-message-string err))))))))
    (let ((result (alist-get 'result data))
          (usage (alist-get 'usage data)))
      (unless (stringp result)
        (signal 'metal-butt-transport-error (list "CLI output has no `result'")))
      (list :text result
            :cost (or (alist-get 'total_cost_usd data) 0)
            :input-tokens (or (alist-get 'input_tokens usage) 0)))))

(defun metal-butt-transport--classify-error (stderr)
  "Turn STDERR into an actionable diagnosis."
  (if (string-match-p "explicit deny\\|not authorized\\|AccessDenied" stderr)
      (concat
       (format "Model %S was refused by AWS. " metal-butt-model)
       (if (string-match "policy/\\([A-Za-z0-9_-]+\\)" stderr)
           (format "An explicit deny in IAM policy %S is blocking it; an explicit deny cannot be overridden by adding an Allow, so that policy must be amended. "
                   (match-string 1 stderr))
         "An explicit deny in an IAM policy is blocking it. ")
       "Cross-region inference profiles also need permission on the underlying "
       "foundation-model ARNs in every destination region.\n\n"
       stderr)
    stderr))

(defun metal-butt-transport--missing-session-p (text)
  "Non-nil when TEXT indicates the session id does not exist yet."
  (and (stringp text)
       (string-match-p "No conversation found" text)))

(defun metal-butt-transport--finish (out err code callback)
  "Interpret one invocation's OUT, ERR and exit CODE, then call CALLBACK.
CALLBACK is called as (RESULT nil nil) on success, or
\(nil ERROR-STRING RETRYABLE) on failure, where RETRYABLE is non-nil only
when the failure was a session that does not exist yet."
  (if (zerop code)
      (condition-case e
          (funcall callback (metal-butt-transport--extract-result out) nil nil)
        (metal-butt-transport-error
         (funcall callback nil (cadr e) nil)))
    (let ((text (if (string-empty-p err) out err)))
      (funcall callback nil
               (metal-butt-transport--classify-error text)
               (metal-butt-transport--missing-session-p text)))))

(defun metal-butt-transport--launch (request session-id create callback)
  "Run one claude invocation for SESSION-ID and hand its outcome to CALLBACK.
CREATE non-nil uses --session-id instead of --resume.  CALLBACK is called
as described in `metal-butt-transport--finish'."
  (let* ((stdout (generate-new-buffer " *metal-butt-stdout*"))
         (stderr (generate-new-buffer " *metal-butt-stderr*"))
         (proc (make-process
                :name "metal-butt"
                :buffer stdout
                :stderr stderr
                :noquery t
                :connection-type 'pipe
                :command (cons metal-butt-executable
                               (metal-butt-transport-argv session-id create))
                :sentinel
                (lambda (proc _event)
                  (when (memq (process-status proc) '(exit signal))
                    (let ((out (with-current-buffer stdout (buffer-string)))
                          (err (with-current-buffer stderr (buffer-string)))
                          (code (process-exit-status proc)))
                      (kill-buffer stdout)
                      (kill-buffer stderr)
                      (metal-butt-transport--finish out err code callback)))))))
    (process-send-string proc request)
    (process-send-eof proc)
    proc))

(defun metal-butt-transport--run (request session-id callback)
  "Send REQUEST to SESSION-ID, calling CALLBACK with a result plist or an error.
CALLBACK receives (RESULT-PLIST nil) on success or (nil ERROR-STRING) on
failure.  Resuming a session id that does not exist yet fails, so that one
case is retried once with --session-id, which creates it."
  (metal-butt-transport--launch
   request session-id nil
   (lambda (result error retryable)
     (if (and error retryable)
         (metal-butt-transport--launch
          request session-id t
          (lambda (result2 error2 _retryable2)
            (funcall callback result2 error2)))
       (funcall callback result error)))))

(defvar metal-butt-transport-function #'metal-butt-transport--run
  "Function used to reach Claude.
Called as (FN REQUEST SESSION-ID CALLBACK).  Rebind in tests.")

(defun metal-butt-transport-send (request session-id callback)
  "Send REQUEST for SESSION-ID via `metal-butt-transport-function'."
  (funcall metal-butt-transport-function request session-id callback))

(provide 'metal-butt-transport)
;;; metal-butt-transport.el ends here
