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
(require 'metal-butt-response)
(require 'metal-butt-transport-copilot)
(require 'metal-butt-transport-copilot-api)

(define-error 'metal-butt-transport-error "Claude CLI transport failed")

(defcustom metal-butt-backend 'claude
  "Which CLI answers buffer prompts: `claude' or `copilot'.
Everything above the transport — prompt detection, the overlay, comment
insertion, handoff files — is CLI-agnostic, so switching this is the whole
migration.  It does not change `metal-butt-model': the two CLIs use
different model name spellings (\"sonnet\" versus \"claude-sonnet-5\", for
instance), so that variable needs a value appropriate to whichever backend
is active."
  :type '(choice (const :tag "Claude Code (claude)" claude)
                 (const :tag "GitHub Copilot CLI (copilot)" copilot)
                 (const :tag "GitHub Copilot chat API directly (copilot-api)" copilot-api))
  :group 'metal-butt)

(defun metal-butt-backend-copilot-family-p ()
  "Return non-nil if the active backend is either Copilot variant.
`copilot' and `copilot-api' share the same model catalogue and
mode-line/cost display, differing only in how the request actually
reaches Copilot -- see `metal-butt-transport-send' for that dispatch."
  (memq metal-butt-backend '(copilot copilot-api)))

(defcustom metal-butt-executable "claude"
  "Name or path of the Claude Code CLI."
  :type 'string
  :group 'metal-butt)

(defcustom metal-butt-claude-model "sonnet"
  "Default model for buffer prompts when `metal-butt-backend' is `claude'.
There is deliberately no automatic fallback to a cheaper model on refusal.
A silent downgrade would change edit quality without the user knowing why,
which is harder to diagnose than an outright error."
  :type 'string
  :group 'metal-butt)

(defcustom metal-butt-copilot-model "claude-sonnet-5"
  "Default model for buffer prompts when `metal-butt-backend' is `copilot'."
  :type 'string
  :group 'metal-butt)

(defcustom metal-butt-model nil
  "Model used for buffer prompts, overriding the active backend's default.
Leave nil to use `metal-butt-claude-model' or `metal-butt-copilot-model',
whichever matches `metal-butt-backend' — see `metal-butt-default-model'.
Set this only if you want the same non-default model on every prompt
regardless of backend, which is unusual since the two CLIs use different
model name spellings (\"sonnet\" versus \"claude-sonnet-5\", for instance)."
  :type '(choice (const :tag "Use the active backend's default" nil) string)
  :group 'metal-butt)

(defun metal-butt-default-model ()
  "Return the active backend's default model.
`metal-butt-copilot-model' for `copilot'/`copilot-api',
`metal-butt-claude-model' otherwise."
  (if (metal-butt-backend-copilot-family-p)
      metal-butt-copilot-model
    metal-butt-claude-model))

(defun metal-butt-active-model ()
  "Return the model to use when nothing more specific overrides it.
`metal-butt-model' wins if the user has set it; otherwise the active
backend's own default, from `metal-butt-default-model'.  This is itself
the least specific tier of `metal-butt-effective-model' in metal-butt.el —
an @model directive or a buffer-local `metal-butt-set-model' both outrank
it."
  (or metal-butt-model (metal-butt-default-model)))

(defcustom metal-butt-known-models '("haiku" "sonnet" "opus" "fable")
  "Model names accepted from an @model directive or `metal-butt-set-model'
when `metal-butt-backend' is `claude'.  Checked locally so a typo fails at
once, rather than becoming an API call that can take a minute to be
refused.  Extend this if you use a model name that is not listed.
See `metal-butt-copilot-known-models' for the Copilot backend's list, which
is not enforced the way this one is."
  :type '(repeat string)
  :group 'metal-butt)

(defun metal-butt-active-known-models ()
  "Return the model names offered for completion by the active backend."
  (if (metal-butt-backend-copilot-family-p)
      metal-butt-copilot-known-models
    metal-butt-known-models))

(defun metal-butt-check-model (model)
  "Validate MODEL against the active backend and return it unchanged.
The Claude backend enforces membership in `metal-butt-known-models',
because a typo there becomes an API call that can take a minute to be
refused.  The Copilot backend does not: see
`metal-butt-copilot-check-model' for why."
  (if (metal-butt-backend-copilot-family-p)
      (metal-butt-copilot-check-model model)
    (unless (member model metal-butt-known-models)
      (error "Metal Butt: unknown model %S; known models are %s"
             model (mapconcat #'identity metal-butt-known-models ", ")))
    model))

(defcustom metal-butt-request-timeout 60
  "Seconds to wait for a response before abandoning the request.
Set to nil or 0 to wait indefinitely.  A bound matters because the CLI
retries some failures with backoff and can take minutes to report them,
which is indistinguishable from a hang."
  :type '(choice (const :tag "Wait indefinitely" nil) integer)
  :group 'metal-butt)

(defconst metal-butt-transport-contract metal-butt-response-contract
  "Alias of `metal-butt-response-contract' for the Claude backend's argv.
Kept under its historical name because it is carried on
--append-system-prompt here, unlike the Copilot backend which prepends the
same text to the request body.")

(defvar metal-butt-transport-last-exchange nil
  "Plist recording the most recent CLI invocation, for troubleshooting.
Keys: :argv :request :stdout :stderr :exit :duration-ms.  Without this a
parse failure destroys the very evidence needed to diagnose it.")

(defun metal-butt-transport-argv (session-id &optional create)
  "Return the argument list for a request against SESSION-ID.
If CREATE is non-nil, use --session-id to create a session; else use --resume."
  (list "-p"
        (if create "--session-id" "--resume") session-id
        "--model" (metal-butt-active-model)
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
       (format "Model %S was refused by AWS. " (metal-butt-active-model))
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
as described in `metal-butt-transport--finish', exactly once: whichever of
the process sentinel and the timeout timer fires first wins."
  (let* ((stdout (generate-new-buffer " *metal-butt-stdout*"))
         (stderr (generate-new-buffer " *metal-butt-stderr*"))
         (done nil)
         (timer nil)
         (proc nil)
         (start-time (float-time)))
    (setq metal-butt-transport-last-exchange
          (list :argv (cons metal-butt-executable
                            (metal-butt-transport-argv session-id create))
                :request request))
    (setq proc
          (make-process
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
                     (code (process-exit-status proc))
                     (duration-ms (round (* 1000 (- (float-time) start-time)))))
                 (setq metal-butt-transport-last-exchange
                       (plist-put (plist-put (plist-put (plist-put
                                              metal-butt-transport-last-exchange
                                              :stdout out)
                                             :stderr err)
                                  :exit code)
                                  :duration-ms duration-ms))
                 (kill-buffer stdout)
                 (kill-buffer stderr)
                 (unless done
                   (setq done t)
                   (when timer (cancel-timer timer))
                   (metal-butt-transport--finish out err code callback)))))))
    (when (and (numberp metal-butt-request-timeout)
               (> metal-butt-request-timeout 0))
      (setq timer
            (run-at-time
             metal-butt-request-timeout nil
             (lambda ()
               (unless done
                 (setq done t)
                 (when (process-live-p proc) (kill-process proc))
                 (funcall callback nil
                          (format "no response after %d seconds; request abandoned (M-x metal-butt-show-last-exchange shows what was sent)"
                                  metal-butt-request-timeout)
                          nil))))))
    (process-send-string proc request)
    (process-send-eof proc)
    proc))

(defun metal-butt-transport--run (request session-id callback)
  "Send REQUEST to SESSION-ID, calling CALLBACK with a result plist or an error.
CALLBACK receives (RESULT-PLIST nil) on success or (nil ERROR-STRING) on
failure.  Resuming a session id that does not exist yet fails, so that one
case is retried once with --session-id, which creates it.

The model in effect is captured here and rebound around the retry, because
the retry fires from inside a callback, outside any dynamic binding the
caller established around this call."
  (let ((model metal-butt-model))
    (metal-butt-transport--launch
     request session-id nil
     (lambda (result error retryable)
       (if (and error retryable)
           (let ((metal-butt-model model))
             (metal-butt-transport--launch
              request session-id t
              (lambda (result2 error2 _retryable2)
                (funcall callback result2 error2))))
         (funcall callback result error))))))

(defvar metal-butt-transport-function #'metal-butt-transport--run
  "Function used to reach Claude.
Called as (FN REQUEST SESSION-ID CALLBACK).  Rebind in tests.")

(defun metal-butt-transport-send (request session-id callback)
  "Send REQUEST for SESSION-ID via the backend named by `metal-butt-backend'.
The Claude backend goes through `metal-butt-transport-function', the
injectable seam tests rebind.  The Copilot CLI backend has its own
analogous seam, `metal-butt-transport-copilot-function', reached via
`metal-butt-transport-copilot-send'.  The direct-API Copilot backend has
a third, `metal-butt-transport-copilot-api-function', reached via
`metal-butt-transport-copilot-api-send' — three backends' argv, wire
format and error shapes differ enough that sharing one seam would mean
every stub had to pretend to be all three at once."
  (pcase metal-butt-backend
    ('copilot (metal-butt-transport-copilot-send request session-id callback))
    ('copilot-api (metal-butt-transport-copilot-api-send request session-id callback))
    (_ (funcall metal-butt-transport-function request session-id callback))))

(provide 'metal-butt-transport)
;;; metal-butt-transport.el ends here
