;;; metal-butt-transport-copilot.el --- Talk to the copilot CLI  -*- lexical-binding: t; -*-

;;; Commentary:
;; Sibling of `metal-butt-transport', selected via `metal-butt-backend'.  Kept
;; as its own module, with its own injectable seam
;; (`metal-butt-transport-copilot-function'), rather than folded into the
;; Claude transport, because the two CLIs differ enough that sharing one
;; implementation would mean padding every function with branches:
;;
;; - `--session-id <uuid>' both creates and resumes a session -- verified by
;;   writing a fact in one invocation and reading it back in a second with the
;;   same id.  There is no separate create/resume flag pair, and therefore no
;;   retry-on-missing-session dance the way the Claude backend needs.
;;
;; - `--output-format json' streams JSONL, one event object per line, not one
;;   JSON document.  The reply text is the `content' of the *last*
;;   `assistant.message' event: when the model calls a tool before answering,
;;   more than one such event appears in the stream, and only the last is the
;;   actual answer (verified against a real invocation that called a tool,
;;   was refused by --deny-tool, and then explained that in a second message).
;;
;; - There is no `--append-system-prompt' equivalent that works in an
;;   arbitrary target repository without a setup step.  A `.github/agents/*.md'
;;   file plus `--agent' does the same job, verified against a real
;;   invocation, but it has to exist in whatever repository the buffer being
;;   edited belongs to -- unacceptable for a package meant to work in any
;;   project without per-project setup.  So the contract is prepended to the
;;   request body instead of carried on argv.
;;
;; - Tool permissions are denied by category, not by literal tool name.
;;   `--deny-tool write' and `--deny-tool shell' were verified against real
;;   invocations that tried to create a file and run a shell command: both
;;   were actually refused, and the model reported the refusal in its reply
;;   rather than the process hanging or silently succeeding.
;;
;; - There is no dollar cost in the output, unlike Claude's `total_cost_usd'.
;;   The nearest analogue is `premiumRequests' on the terminating `result'
;;   event.  An input-token count for the session-rolling heuristic *is*
;;   present, but nested under a `session.usage_checkpoint' event, itself
;;   under a model-id key whose name is not known in advance; extracted on a
;;   best-effort basis below.

;;; Code:

(require 'seq)
(require 'json)
(require 'metal-butt-response)

(defvar metal-butt-request-timeout)
(declare-function metal-butt-active-model "metal-butt-transport")

(define-error 'metal-butt-copilot-transport-error "Copilot CLI transport failed")

(defcustom metal-butt-copilot-executable "copilot"
  "Name or path of the GitHub Copilot CLI."
  :type 'string
  :group 'metal-butt)

(defcustom metal-butt-copilot-known-models
  '("auto" "claude-sonnet-5" "claude-opus-5" "claude-haiku-4.5"
    "gpt-5.4" "gpt-5.3-codex" "gemini-3.6-flash")
  "Model names offered for completion by `metal-butt-set-model'.
Unlike `metal-butt-known-models' for the Claude backend, this list is not
enforced by `metal-butt-copilot-check-model'.  The Copilot CLI's model
catalogue is large and changes over time, and the CLI itself already
rejects an unknown model in under a second, before anything is billed
\(verified: `copilot --model not-a-real-model' exits 1 immediately with
`Error: Model \"not-a-real-model\" from --model flag is not available.'\),
so a stale local allowlist would only ever be wrong in the annoying
direction."
  :type '(repeat string)
  :group 'metal-butt)

(defun metal-butt-copilot-check-model (model)
  "Return MODEL unchanged if it is a non-empty string.
Validation against the real catalogue is left to the CLI itself; see
`metal-butt-copilot-known-models' for why."
  (when (or (not (stringp model)) (string-empty-p (string-trim model)))
    (error "Metal Butt: empty model name"))
  model)

(defcustom metal-butt-copilot-deny-tools '("write" "shell")
  "Tool permission categories denied on every Copilot CLI invocation.
`write' covers file creation and editing tools; `shell' covers command
execution.  Both were verified against real invocations that attempted the
denied action and were actually refused, not merely warned about.  This is
this backend's equivalent of the Claude backend's
`--disallowedTools Edit,Write,NotebookEdit', and arguably stronger: it also
closes the route of writing a file via a shell command, which a tool-name
blocklist does not."
  :type '(repeat string)
  :group 'metal-butt)

(defun metal-butt-transport-copilot-argv (session-id)
  "Return the argument list for a Copilot CLI request against SESSION-ID.
No -p/--prompt here: the request text goes on stdin instead, for the same
reason the Claude backend uses stdin -- it carries whole buffers and would
otherwise risk an argv length limit.  Verified that `copilot' reads a piped
prompt with no -p flag at all when stdin is not a TTY."
  (append (list "--session-id" session-id
                "--model" (metal-butt-active-model)
                "--output-format" "json"
                "--allow-all-tools")
          (mapcan (lambda (tool) (list "--deny-tool" tool))
                  metal-butt-copilot-deny-tools)))

(defun metal-butt-transport-copilot--build-stdin (request)
  "Prepend the shared response contract to REQUEST.
Split out from the process-launching code so it is unit-testable without
spawning anything."
  (concat metal-butt-response-contract "\n\n" request))

(defun metal-butt-transport-copilot--parse-lines (text)
  "Parse TEXT as JSONL, returning the objects that parsed.
A line that is not valid JSON -- such as a plain-text error banner the CLI
sometimes mixes into stdout before a non-zero exit -- is skipped rather than
aborting the whole parse: one bad line must not hide the events that came
before it."
  (let (out)
    (dolist (line (split-string text "\n" t))
      (unless (string-blank-p line)
        (condition-case nil
            (push (json-parse-string line :object-type 'alist
                                     :null-object nil :false-object nil)
                  out)
          (error nil))))
    (nreverse out)))

(defun metal-butt-transport-copilot--events-of-type (events type)
  "Return the subsequence of EVENTS whose `type' field is TYPE."
  (seq-filter (lambda (e) (equal (alist-get 'type e) type)) events))

(defun metal-butt-transport-copilot--checkpoint-prompt-tokens (checkpoint-data)
  "Best-effort extraction of a prompt token count from CHECKPOINT-DATA.
CHECKPOINT-DATA is the `data' field of a `session.usage_checkpoint' event.
The count is nested under an alist keyed by model id
\(`promptCacheBreakState[0].models.<model-id>.prompt_tokens'\), and the model
id is not known in advance, so this takes whichever entry is present rather
than looking up a specific key.  Returns nil, never an error, when the
shape is not as expected -- this feeds a mode-line nudge, not a decision
that must be correct."
  (ignore-errors
    (let* ((states (alist-get 'promptCacheBreakState checkpoint-data))
           (first-state (and (seqp states) (> (length states) 0)
                              (elt states 0)))
           (models (and first-state (alist-get 'models first-state)))
           (first-model (and (consp models) (cdar models))))
      (and first-model (alist-get 'prompt_tokens first-model)))))

(defun metal-butt-transport-copilot--extract-result (stdout)
  "Pull the reply text and usage figures out of STDOUT.
STDOUT is the full JSONL stream from one invocation.  The reply is the
`content' of the last `assistant.message' event, because a turn that calls
tools before answering emits more than one, and only the last is the actual
answer."
  (let* ((events (metal-butt-transport-copilot--parse-lines stdout))
         (messages (metal-butt-transport-copilot--events-of-type events "assistant.message"))
         (checkpoints (metal-butt-transport-copilot--events-of-type events "session.usage_checkpoint"))
         (last-message (car (last messages)))
         (last-checkpoint (car (last checkpoints)))
         (result-event (car (metal-butt-transport-copilot--events-of-type events "result"))))
    (unless last-message
      (signal 'metal-butt-copilot-transport-error
              (list "no assistant reply in Copilot CLI output")))
    (let* ((text (alist-get 'content (alist-get 'data last-message)))
           (usage (and result-event (alist-get 'usage result-event)))
           (checkpoint-data (and last-checkpoint (alist-get 'data last-checkpoint))))
      (unless (stringp text)
        (signal 'metal-butt-copilot-transport-error
                (list "assistant.message event has no `content'")))
      (list :text text
            :cost 0
            :input-tokens (or (metal-butt-transport-copilot--checkpoint-prompt-tokens
                                checkpoint-data)
                               0)
            :premium-requests (or (and usage (alist-get 'premiumRequests usage)) 0)))))

(defun metal-butt-transport-copilot--classify-error (text)
  "Return TEXT, prefixed with a hint when it matches a known failure shape.
Unlike the Claude backend's IAM-deny classifier, there is no verified corpus
of Copilot CLI failure text to pattern-match beyond the unknown-model case
below, so this stays deliberately thin rather than guessing at patterns
that were never actually observed."
  (if (string-match-p "is not available" text)
      (concat "Model rejected by the Copilot CLI -- check that "
              "`metal-butt-model' is a name it recognises. " text)
    text))

(defvar metal-butt-transport-copilot-last-exchange nil
  "Plist recording the most recent Copilot CLI invocation, for troubleshooting.
Keys: :argv :request :stdout :stderr :exit :duration-ms.  Mirrors
`metal-butt-transport-last-exchange' for the Claude backend.")

(defun metal-butt-transport-copilot--finish (out err code callback)
  "Interpret one invocation's OUT, ERR and exit CODE, then call CALLBACK.
CALLBACK is called as (RESULT nil) on success, or (nil ERROR-STRING) on
failure.  Verified that the CLI writes a plain-text error to stderr and
exits non-zero on a failure such as an unknown model, with valid JSONL
still on stdout up to that point -- so on a non-zero exit, stderr is the
error unless it is empty, in which case stdout is used instead."
  (if (zerop code)
      (condition-case e
          (funcall callback (metal-butt-transport-copilot--extract-result out) nil)
        (metal-butt-copilot-transport-error (funcall callback nil (cadr e))))
    (let ((text (if (string-empty-p (string-trim err)) out err)))
      (funcall callback nil (metal-butt-transport-copilot--classify-error text)))))

(defun metal-butt-transport-copilot--launch (request session-id callback)
  "Run one copilot invocation for SESSION-ID and hand its outcome to CALLBACK.
CALLBACK is called as described in `metal-butt-transport-copilot--finish'.
Mirrors `metal-butt-transport--launch' for the Claude backend, minus the
create/resume distinction that backend needs and this one does not."
  (let* ((stdout (generate-new-buffer " *metal-butt-copilot-stdout*"))
         (stderr (generate-new-buffer " *metal-butt-copilot-stderr*"))
         (done nil)
         (timer nil)
         (proc nil)
         (start-time (float-time))
         (stdin (metal-butt-transport-copilot--build-stdin request)))
    (setq metal-butt-transport-copilot-last-exchange
          (list :argv (cons metal-butt-copilot-executable
                            (metal-butt-transport-copilot-argv session-id))
                :request stdin))
    (setq proc
          (make-process
           :name "metal-butt-copilot"
           :buffer stdout
           :stderr stderr
           :noquery t
           :connection-type 'pipe
           :command (cons metal-butt-copilot-executable
                          (metal-butt-transport-copilot-argv session-id))
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (let ((out (with-current-buffer stdout (buffer-string)))
                     (err (with-current-buffer stderr (buffer-string)))
                     (code (process-exit-status proc))
                     (duration-ms (round (* 1000 (- (float-time) start-time)))))
                 (setq metal-butt-transport-copilot-last-exchange
                       (plist-put (plist-put (plist-put (plist-put
                                              metal-butt-transport-copilot-last-exchange
                                              :stdout out)
                                             :stderr err)
                                  :exit code)
                                  :duration-ms duration-ms))
                 (kill-buffer stdout)
                 (kill-buffer stderr)
                 (unless done
                   (setq done t)
                   (when timer (cancel-timer timer))
                   (metal-butt-transport-copilot--finish out err code callback)))))))
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
                                  metal-butt-request-timeout)))))))
    (process-send-string proc stdin)
    (process-send-eof proc)
    proc))

(defvar metal-butt-transport-copilot-function #'metal-butt-transport-copilot--launch
  "Function used to reach the Copilot CLI.
Called as (FN REQUEST SESSION-ID CALLBACK), where REQUEST already has the
contract prepended.  Rebind in tests.")

(defun metal-butt-transport-copilot-send (request session-id callback)
  "Send REQUEST for SESSION-ID via `metal-butt-transport-copilot-function'.
The contract is prepended inside the launch function, not here, so that a
test stubbing `metal-butt-transport-copilot-function' sees the same REQUEST
its caller passed in -- mirroring how the Claude backend's `-send' hands
`metal-butt-transport-function' the raw request untouched, since its
contract travels on argv instead."
  (funcall metal-butt-transport-copilot-function request session-id callback))

(provide 'metal-butt-transport-copilot)
;;; metal-butt-transport-copilot.el ends here
