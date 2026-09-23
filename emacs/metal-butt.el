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
(require 'seq)
(require 'metal-butt-log)
(require 'metal-butt-prompt)
(require 'metal-butt-context)
(require 'metal-butt-transport)
(require 'metal-butt-transport-copilot)
(require 'metal-butt-response)
(require 'metal-butt-overlay)
(require 'metal-butt-comment)
(require 'metal-butt-session)
(require 'metal-butt-handoff)
(require 'metal-butt-complete)

(defcustom metal-butt-delete-prompt-after-send nil
  "When non-nil, remove the prompt comment once it has been answered."
  :type 'boolean
  :group 'metal-butt)

(defvar-local metal-butt--in-flight nil)
(defvar-local metal-butt--last-cost 0)
(defvar-local metal-butt--last-input-tokens 0)
(defvar-local metal-butt--last-premium-requests 0)
(defvar-local metal-butt--last-prompt nil
  "The most recent prompt plist passed to `metal-butt--dispatch', for
`metal-butt-retry' to resend.  Set unconditionally, including on prompts
that go on to fail, so a retry after an error resends the same prompt
rather than erroring a second time with nothing to retry.")

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
  "Show TEXT in the reply window, leaving the code buffer untouched.
Uses `visual-line-mode' so long lines wrap at the window edge instead of
running off it -- the model's replies are plain prose/markdown, not code,
so soft-wrapping is what a reader actually wants here."
  (let ((buffer (get-buffer-create "*metal-butt-reply*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min)))
      (visual-line-mode 1)
      (view-mode 1))
    (display-buffer buffer)))

(defun metal-butt--show-reply-progress (text)
  "Show a live, in-progress TEXT preview in the reply window.
Same buffer as `metal-butt--show-reply', so the final call to that
function (once the response is complete) simply replaces this preview;
used only for prompts with :reply `window', since a `comment' reply is
inserted at point just once, and there is nowhere sensible to preview a
comment-in-progress without disturbing the buffer being edited."
  (let ((buffer (get-buffer-create "*metal-butt-reply*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min)))
      (visual-line-mode 1)
      (view-mode 1))
    (display-buffer buffer)))

(defvar-local metal-butt--ask-conversation nil
  "Prior (PROMPT . ANSWER) turns for the running `metal-butt-ask' conversation.
Oldest first.  Reset whenever `metal-butt-ask' starts a fresh question;
extended by both `metal-butt-ask' and `metal-butt-ask-followup' whenever
a reply comes back, so a subsequent `metal-butt-ask-followup' always
continues from the latest successful answer.  Buffer-local because the
conversation is tied to whichever code buffer it is about, not to the
transient `*metal-butt-reply*' window.  Capped to the most recent
`metal-butt-ask-conversation-max-turns' turns -- see that variable's
docstring for why an uncapped conversation would otherwise grow every
request's payload without bound.")

(defcustom metal-butt-ask-conversation-max-turns 12
  "Maximum turns kept in `metal-butt--ask-conversation'.
Every turn ever asked with `metal-butt-ask-followup' is resent in full
on every subsequent follow-up, so an uncapped conversation makes every
request in a long back-and-forth larger than the last, indefinitely --
this bounds that growth by dropping the oldest turns once the cap is
reached, keeping the request size roughly constant instead. Rolling the
whole session (`M-x metal-butt-roll-session') is still the right tool
for reclaiming a session that has grown large in some other way (a
large buffer, a big handoff note); this only bounds the ask/follow-up
history specifically."
  :type 'integer
  :group 'metal-butt)

(defun metal-butt--ask-conversation-append (conversation prompt answer)
  "Return CONVERSATION with a new (PROMPT . ANSWER) turn appended.
Truncated to the most recent `metal-butt-ask-conversation-max-turns'
turns, oldest dropped first -- see that variable's docstring."
  (let ((extended (append conversation (list (cons prompt answer)))))
    (if (> (length extended) metal-butt-ask-conversation-max-turns)
        (seq-drop extended (- (length extended) metal-butt-ask-conversation-max-turns))
      extended)))

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
        (metal-butt-log "request failed: %s" error)
        (message "Metal Butt: %s" error))
       ((and (/= tick (buffer-chars-modified-tick))
             (not (eq (plist-get prompt :reply) 'window)))
        (metal-butt-log "response discarded: buffer changed while the request was in flight")
        (message "Metal Butt: buffer changed while the request was in flight; response discarded"))
       (t
        (setq metal-butt--last-cost (plist-get result :cost)
              metal-butt--last-input-tokens (plist-get result :input-tokens)
              metal-butt--last-premium-requests (or (plist-get result :premium-requests) 0))
        (metal-butt-log "request ok: backend=%s model=%s input-tokens=%d cost=$%.4f premium-requests=%d"
                         metal-butt-backend (metal-butt-effective-model)
                         metal-butt--last-input-tokens metal-butt--last-cost
                         metal-butt--last-premium-requests)
        (condition-case e
            (let ((response (metal-butt-response-parse (plist-get result :text))))
              (metal-butt--apply response prompt)
              (when (and (plist-get prompt :track-history)
                         (eq (plist-get response :kind) 'reply))
                (setq metal-butt--ask-conversation
                      (metal-butt--ask-conversation-append
                       metal-butt--ask-conversation
                       (plist-get prompt :text)
                       (plist-get response :text)))))
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
  (setq metal-butt--last-prompt prompt)
  (let* ((root (metal-butt-repo-root))
         (handoff (metal-butt-handoff-peek root 'to-emacs))
         (request (metal-butt-context-build (plist-get prompt :text)
                                            root (car handoff)
                                            (plist-get prompt :history)))
         (tick (buffer-chars-modified-tick))
         (buffer (current-buffer))
         (ack (lambda ()
                (unless (string-empty-p (car handoff))
                  (metal-butt-handoff-ack root 'to-emacs (cdr handoff))))))
    (let ((metal-butt-model (metal-butt-effective-model (plist-get prompt :model))))
      (setq metal-butt--in-flight t)
      (message "Metal Butt: thinking...")
      (metal-butt-log "dispatch: backend=%s model=%s session=%s bytes=%d"
                       metal-butt-backend metal-butt-model
                       (metal-butt-session-current-id root) (length request))
      (condition-case err
          (metal-butt-transport-send
           request
           (metal-butt-session-current-id root)
           (lambda (result error)
             (metal-butt--handle buffer prompt tick result error ack))
           (when (eq (plist-get prompt :reply) 'window)
             (lambda (partial-text)
               (when (buffer-live-p buffer)
                 (let ((preview (metal-butt-response-preview-text partial-text)))
                   (when preview (metal-butt--show-reply-progress preview)))))))
        (error
         (setq metal-butt--in-flight nil)
         (metal-butt-log "dispatch failed before send: %s" (error-message-string err))
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
  "Prompts previously entered with `metal-butt-ask', for M-p recall.
Persisted to disk by `metal-butt-history-save' so it survives Emacs
restarts; loaded lazily by `metal-butt-history-load' the first time this
Emacs session asks a question, so a later buffer's `M-p' can recall
prompts from a prior Emacs process too.")

(defcustom metal-butt-history-max-entries 200
  "Maximum number of prompts kept in the persisted `M-p' history file.
Oldest entries are dropped first once this is exceeded, so the file
does not grow without bound across a long-lived repo."
  :type 'integer
  :group 'metal-butt)

(defun metal-butt--history-file (repo-root)
  "Return the path of the persisted prompt-history file for REPO-ROOT."
  (expand-file-name "history" (metal-butt-session-dir repo-root)))

(defun metal-butt-history-load (repo-root)
  "Load persisted prompt history for REPO-ROOT, once per Emacs session.
Does nothing if `metal-butt--ask-history' is already populated -- either
from an earlier `metal-butt-ask' this session, or from an earlier call to
this function -- so a prompt entered after loading is never clobbered by
a stale on-disk copy."
  (let ((file (metal-butt--history-file repo-root)))
    (when (and (null metal-butt--ask-history) (file-readable-p file))
      (setq metal-butt--ask-history
            (ignore-errors
              (with-temp-buffer
                (insert-file-contents file)
                (read (current-buffer))))))))

(defun metal-butt-history-save (repo-root)
  "Persist `metal-butt--ask-history' for REPO-ROOT to disk.
Truncated to `metal-butt-history-max-entries', keeping the most recent
entries -- `read-string' prepends new entries, so the newest are always
at the front of the list already."
  (let ((dir (metal-butt-session-dir repo-root)))
    (make-directory dir t)
    (with-temp-file (metal-butt--history-file repo-root)
      (prin1 (seq-take metal-butt--ask-history metal-butt-history-max-entries)
             (current-buffer)))))

(defun metal-butt-backend-label ()
  "Return a short human-readable name for the active backend.
Used for prompts like `metal-butt-ask''s minibuffer label, so it names
whichever backend will actually answer instead of always saying Claude."
  (pcase metal-butt-backend
    ('copilot "Copilot")
    ('copilot-api "Copilot (API)")
    (_ "Claude")))

(defun metal-butt-ask (prompt)
  "Ask PROMPT about this buffer without writing the question into it.
The answer appears in a separate window; a proposed code edit still arrives
as an accept/reject overlay.  A leading @model directive works here too.
Starts a fresh conversation: any earlier turns tracked for
`metal-butt-ask-followup' are discarded, since a new top-level question
is not a continuation of the last one."
  (interactive (progn
                 (metal-butt-history-load (metal-butt-repo-root))
                 (list (read-string (format "Ask %s: " (metal-butt-backend-label))
                                    nil 'metal-butt--ask-history))))
  (setq metal-butt--ask-conversation nil)
  (metal-butt-history-save (metal-butt-repo-root))
  (let ((split (metal-butt-prompt--extract-model prompt)))
    (metal-butt--dispatch (list :text (cdr split)
                                :model (car split)
                                :reply 'window
                                :track-history t))))

(defun metal-butt-ask-followup (prompt)
  "Ask PROMPT as a continuation of the last `metal-butt-ask' conversation.
Includes every earlier (question . answer) pair from this buffer's running
conversation so the model can use them as context, the same way a human
follow-up question relies on what was already said rather than repeating
it.  Errors if there is no conversation yet to follow up on -- run
`metal-butt-ask' first."
  (interactive (progn
                 (metal-butt-history-load (metal-butt-repo-root))
                 (list (read-string (format "Follow up %s: " (metal-butt-backend-label))
                                    nil 'metal-butt--ask-history))))
  (unless metal-butt--ask-conversation
    (error "Metal Butt: no conversation yet to follow up on; use M-x metal-butt-ask first"))
  (metal-butt-history-save (metal-butt-repo-root))
  (let ((split (metal-butt-prompt--extract-model prompt)))
    (metal-butt--dispatch (list :text (cdr split)
                                :model (car split)
                                :reply 'window
                                :track-history t
                                :history metal-butt--ask-conversation))))

(defun metal-butt-roll-session ()
  "Summarise this session into a handoff note and start a fresh generation."
  (interactive)
  (metal-butt-session-roll (metal-butt-repo-root)))

(defun metal-butt-retry (&optional model)
  "Resend the most recent prompt, optionally with a different MODEL.
Reuses `metal-butt--last-prompt' verbatim -- same text, same :reply
target, same conversation history if it was a follow-up -- so this is
useful both to retry a request that errored out (a network blip, a
transient backend hiccup) and to compare how a different model answers
the same question, without retyping it.  With a prefix arg, prompts for
MODEL with completion; otherwise resends with the model the prompt was
originally sent with.  Errors if nothing has been asked yet this buffer."
  (interactive
   (list (when current-prefix-arg
           (completing-read "Retry with model: " (metal-butt-active-known-models)
                            nil nil))))
  (unless metal-butt--last-prompt
    (error "Metal Butt: nothing to retry yet in this buffer"))
  (let ((prompt metal-butt--last-prompt))
    (metal-butt--dispatch
     (if (and model (not (string-empty-p model)))
         (plist-put (copy-sequence prompt) :model model)
       prompt))))

(defcustom metal-butt-explain-region-prompt "Explain this code."
  "Canned question sent by `metal-butt-explain-region' with no minibuffer prompt.
Kept short and generic since the marked region is already attached as
context (see `metal-butt-context-build''s \"## Selected region\" section) --
this is just what to do with it."
  :type 'string
  :group 'metal-butt)

(defun metal-butt-explain-region ()
  "Ask a canned question about the marked region with no minibuffer prompt.
Lighter-weight than `metal-butt-ask' for the common case of \"what does
this do\": mark a region and press the key, no typing required.  The
question asked is `metal-butt-explain-region-prompt'; the region is
attached as context the same way `metal-butt-ask' attaches one, via
`metal-butt-context-build''s \"## Selected region\" section, so the model
still sees exactly the marked text alongside the rest of the buffer.
Starts a fresh conversation, like `metal-butt-ask', so a later
`metal-butt-ask-followup' continues from this question. Errors if no
region is active -- mark one first."
  (interactive)
  (unless (use-region-p)
    (error "Metal Butt: no region marked; select the code to ask about first"))
  (setq metal-butt--ask-conversation nil)
  (metal-butt--dispatch (list :text metal-butt-explain-region-prompt
                              :reply 'window
                              :track-history t)))

(defun metal-butt--current-exchange ()
  "Return the last-exchange plist for whichever backend is active.
Shared by `metal-butt-show-last-exchange' and `metal-butt-status'."
  (pcase metal-butt-backend
    ('copilot metal-butt-transport-copilot-last-exchange)
    ('copilot-api metal-butt-transport-copilot-api-last-exchange)
    (_ metal-butt-transport-last-exchange)))

(defun metal-butt-show-last-exchange ()
  "Show the raw request and response of the most recent CLI invocation.
The place to look when a response fails to parse: the payload is otherwise
discarded along with the process buffers.  Shows whichever backend is
active's record: `metal-butt-transport-last-exchange' for `claude',
`metal-butt-transport-copilot-last-exchange' for `copilot',
`metal-butt-transport-copilot-api-last-exchange' for `copilot-api'."
  (interactive)
  (let ((exchange (metal-butt--current-exchange)))
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

(defun metal-butt-status ()
  "Show a summary of Metal Butt's state for this buffer in one message.
Reports the active backend, the effective model, the current session id,
whether a request is in flight, the size of the running `metal-butt-ask'
conversation, and the cost/tokens/duration of the last exchange --
everything you'd otherwise have to check via half a dozen different
variables and `metal-butt-show-last-exchange', in one place."
  (interactive)
  (let* ((root (metal-butt-repo-root))
         (exchange (metal-butt--current-exchange))
         (duration (and exchange (plist-get exchange :duration-ms))))
    (message "Metal Butt: backend=%s model=%s session=%s %s%s%s%s%s"
             (metal-butt-backend-label)
             (metal-butt-effective-model)
             (metal-butt-session-current-id root)
             (if metal-butt--in-flight "in-flight" "idle")
             (if metal-butt--ask-conversation
                 (format " conversation=%d/%d turns" (length metal-butt--ask-conversation)
                         metal-butt-ask-conversation-max-turns)
               "")
             (if (> metal-butt--last-cost 0)
                 (format " cost=$%.4f" metal-butt--last-cost)
               "")
             (if (> metal-butt--last-premium-requests 0)
                 (format " premium-requests=%d" metal-butt--last-premium-requests)
               "")
             (cond
              ((> metal-butt--last-input-tokens 0)
               (format " input-tokens=%d%s" metal-butt--last-input-tokens
                       (if duration (format " duration=%.1fs" (/ duration 1000.0)) "")))
              (duration (format " duration=%.1fs" (/ duration 1000.0)))
              (t "")))))

(defconst metal-butt--modules
  '("metal-butt-log"
    "metal-butt-prompt"
    "metal-butt-context"
    "metal-butt-response"
    "metal-butt-transport-copilot"
    "metal-butt-transport-copilot-api"
    "metal-butt-transport"
    "metal-butt-overlay"
    "metal-butt-comment"
    "metal-butt-session"
    "metal-butt-handoff"
    "metal-butt-complete"
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
(define-key metal-butt-mode-map (kbd "C-c C-p") #'metal-butt-ask-followup)
(define-key metal-butt-mode-map (kbd "C-c e") #'metal-butt-explain-region)
(define-key metal-butt-mode-map (kbd "C-c C-a") #'metal-butt-accept)
(define-key metal-butt-mode-map (kbd "C-c C-r") #'metal-butt-reject)
(define-key metal-butt-mode-map (kbd "C-c C-d") #'metal-butt-overlay-toggle-style)
(define-key metal-butt-mode-map (kbd "C-c C-e") #'metal-butt-overlay-review-ediff)
(define-key metal-butt-mode-map (kbd "C-c h a") #'metal-butt-overlay-accept-hunk)
(define-key metal-butt-mode-map (kbd "C-c h r") #'metal-butt-overlay-reject-hunk)
(define-key metal-butt-mode-map (kbd "C-c m") #'metal-butt-set-model)
(define-key metal-butt-mode-map (kbd "C-c s") #'metal-butt-status)
(define-key metal-butt-mode-map (kbd "C-c t") #'metal-butt-retry)
(define-key metal-butt-mode-map (kbd "C-c l") #'metal-butt-show-log)
(define-key metal-butt-mode-map (kbd "C-c C-TAB") #'metal-butt-complete-at-point)
(define-key metal-butt-mode-map (kbd "C-c TAB") #'metal-butt-toggle-autocomplete)

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
