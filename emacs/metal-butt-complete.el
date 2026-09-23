;;; metal-butt-complete.el --- Point completion with a persistent diff session  -*- lexical-binding: t; -*-

;;; Commentary:
;; Every other request in the package resends the whole buffer (or a window
;; around point, for a large one) on every single call -- fine for an
;; occasional ask or edit, but a non-starter for something meant to be
;; triggered often, close to every edit: resending 20000 characters on each
;; call would waste most of the request's latency on transfer, not thought.
;;
;; So this feature keeps its own persistent, buffer-local chat message
;; history instead, and only ever sends the whole buffer once, up front;
;; every later turn sends a compact unified-diff of what changed since the
;; previous turn plus the current point, and relies on the model's own memory
;; of the conversation for everything that has not changed.  The history
;; itself is bounded (`metal-butt-complete-max-turns',
;; `metal-butt-complete-max-history-chars'): once either limit is hit, the
;; next turn resyncs by resending the whole buffer and dropping everything
;; before it, the same trade the rest of the package makes with
;; `metal-butt-roll-session', just automatic and local to this buffer.
;;
;; Only implemented for the `copilot-api' backend for now, for two reasons:
;;
;; - `claude' and `copilot' both shell out to a CLI that pays a large,
;;   mostly-fixed per-invocation cost (process startup, an update check, tool
;;   schema loading, and so on -- measured at several seconds, see the
;;   Commentary in `metal-butt-transport-copilot-api.el').  That is
;;   tolerable for an occasional ask or edit, but would make a completion
;;   command meant to be used often feel unusably slow.
;;
;; - The chat/completions API this backend talks to takes an explicit,
;;   caller-assembled message array on every call (see
;;   `metal-butt-transport-copilot-api-send-messages'), which is what makes
;;   growing a persistent, diff-based history practical to build at all.
;;   The other two backends' CLIs manage their own session/context instead,
;;   with no equivalent way to hand them one growing message array directly.
;;
;; A proposed completion arrives through the exact same edit contract and
;; `metal-butt-overlay' review flow as any other proposed edit -- accept,
;; reject, hunk-by-hunk, diff/full toggle, or the whole-changeset Ediff view
;; all work on it unchanged, since as far as the overlay is concerned this is
;; just another edit response.

;;; Code:

(require 'metal-butt-log)
(require 'metal-butt-response)
(require 'metal-butt-overlay)
(require 'metal-butt-transport)
(require 'metal-butt-transport-copilot-api)

(defvar metal-butt--in-flight)
(defvar metal-butt--last-cost)
(defvar metal-butt--last-input-tokens)
(defvar metal-butt--last-premium-requests)

(defcustom metal-butt-complete-max-turns 20
  "Resync once this many turns have accumulated since the last resync.
A resync resends the whole buffer as a fresh first turn and drops every
earlier message -- the same trade `metal-butt-roll-session' makes for the
ask/edit conversation, just automatic and buffer-local.  Whichever of this
and `metal-butt-complete-max-history-chars' is hit first triggers it; see
that variable for why an unbounded history is worse here than for the
ask/edit conversation, which at least has a server-side session to fall
back on."
  :type 'integer
  :group 'metal-butt)

(defcustom metal-butt-complete-max-history-chars 40000
  "Resync once the accumulated completion message history exceeds this many
characters.  Unlike the ask/edit conversation history, which rides on top
of a session id the backend itself remembers, this backend's
chat/completions API has no server-side session at all -- every character
ever sent is resent on every subsequent turn until a resync -- so an
uncapped history here would make every completion request in a long
editing run larger (and slower) than the last, indefinitely."
  :type 'integer
  :group 'metal-butt)

(defvar-local metal-butt-complete--messages nil
  "Growing chat message history for this buffer's completion session.
A list of `(role . content)' alists, oldest first, always starting with a
system message stating the response contract and the completion task --
see `metal-butt-complete--system-message'.  Nil before the first
completion request in this buffer, or right after a resync; the next
completion turn recreates it from scratch, see
`metal-butt-complete--ensure-session'.")

(defvar-local metal-butt-complete--synced-text nil
  "Buffer text as of the last successful completion turn.
Nil before the first successful turn, or right after a resync, which is
what tells `metal-butt-complete--build-user-message' to send the whole
buffer instead of a diff against this.")

(defvar-local metal-butt-complete--turns 0
  "Turns sent since `metal-butt-complete--messages' was last reset.")

(defconst metal-butt-complete--system-message
  `((role . "system")
    (content
     . ,(concat
         "You are completing or writing code inline at the user's cursor in a "
         "live-edited Emacs buffer, across a running conversation. The first "
         "user message in this conversation (or the first after a resync) "
         "carries the whole current buffer; every later one instead carries a "
         "unified diff of what changed in the buffer since your previous turn, "
         "plus the file name, major mode, and current point (cursor) location. "
         "Propose a small, focused completion or edit at or near the point; do "
         "not rewrite unrelated parts of the file. If there is nothing sensible "
         "to complete right now, reply instead of proposing an edit.\n\n"
         metal-butt-response-contract)))
  "The one-time system message stating the completion task and the contract.
Restated only when the session is (re)created -- see
`metal-butt-complete--ensure-session' -- not on every turn, unlike every
other request in the package, which has no persistent history to state it
in just once.")

(defun metal-butt-complete--history-chars ()
  "Return the total character count of `metal-butt-complete--messages'."
  (apply #'+ (mapcar (lambda (m) (length (alist-get 'content m)))
                     metal-butt-complete--messages)))

(defun metal-butt-complete--ensure-session ()
  "Ensure a completion session exists for this buffer, resyncing if due.
Resyncing means dropping every prior message and forgetting
`metal-butt-complete--synced-text', so the next turn sends the whole
buffer as a fresh first turn -- see `metal-butt-complete-max-turns' and
`metal-butt-complete-max-history-chars' for when that triggers."
  (when (or (null metal-butt-complete--messages)
            (>= metal-butt-complete--turns metal-butt-complete-max-turns)
            (> (metal-butt-complete--history-chars)
               metal-butt-complete-max-history-chars))
    (metal-butt-log "complete: (re)starting completion session for this buffer")
    (setq metal-butt-complete--messages (list metal-butt-complete--system-message)
          metal-butt-complete--synced-text nil
          metal-butt-complete--turns 0)))

(defun metal-butt-complete--diff-text (old new)
  "Return a compact unified-diff-style delta turning OLD into NEW.
Empty when OLD and NEW are equal.  Built on `metal-butt-overlay--diff-hunks',
the same line-level LCS diff the overlay review uses to split a proposed
edit into hunks -- reused here rather than a second diff implementation,
so the two can never disagree about what counts as a line-level change."
  (let ((old-line 1) (new-line 1) (out nil))
    (dolist (hunk (metal-butt-overlay--diff-hunks old new))
      (let* ((old-text (plist-get hunk :old))
             (new-text (plist-get hunk :new))
             (old-lines (if (string-empty-p old-text) nil (split-string old-text "\n")))
             (new-lines (if (string-empty-p new-text) nil (split-string new-text "\n"))))
        (if (eq (plist-get hunk :type) 'equal)
            (setq old-line (+ old-line (length old-lines))
                  new-line (+ new-line (length new-lines)))
          (push (format "@@ -%d,%d +%d,%d @@"
                        old-line (length old-lines) new-line (length new-lines))
                out)
          (dolist (l old-lines) (push (concat "-" l) out))
          (dolist (l new-lines) (push (concat "+" l) out))
          (setq old-line (+ old-line (length old-lines))
                new-line (+ new-line (length new-lines))))))
    (mapconcat #'identity (nreverse out) "\n")))

(defun metal-butt-complete--build-user-message (synced-text)
  "Return a plist (:message MESSAGE :text TEXT) for the next completion turn.
MESSAGE is the `(role . content)' alist to send; TEXT is the buffer text
as of now, for the caller to remember as the next SYNCED-TEXT once this
turn succeeds.  SYNCED-TEXT is the buffer text as of the previous
successful turn, or nil to send the whole buffer instead of a diff (the
first turn of a session, or right after a resync)."
  (let* ((current (buffer-substring-no-properties (point-min) (point-max)))
         (header (format "File: %s\nMajor mode: %s\nPoint: line %d\n"
                         (or (buffer-file-name) "(unsaved buffer)")
                         major-mode (line-number-at-pos)))
         (body
          (if (null synced-text)
              (format "## Buffer\n\n%s\n```\n%s\n```\n" header current)
            (let ((diff (metal-butt-complete--diff-text synced-text current)))
              (if (string-empty-p diff)
                  (format "## Buffer\n\n%s\n(No changes since your last turn.)\n" header)
                (format "## Buffer changed since your last turn\n\n%s\n```diff\n%s\n```\n"
                        header diff))))))
    (list :message `((role . "user")
                      (content . ,(concat body "\nComplete or write code at the indicated point.")))
          :text current)))

(defun metal-butt-complete--handle (buffer message text tick result error interactive)
  "Handle RESULT or ERROR for one completion turn's MESSAGE/TEXT/TICK.
BUFFER is the buffer the request was made from; INTERACTIVE non-nil means
report a `reply' kind (nothing to complete right now) with `message',
matching how the manual command is used -- an automatic trigger stays
silent about it instead, so idle-triggered autocomplete does not spam the
echo area every time there happens to be nothing to propose."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq metal-butt--in-flight nil)
      (cond
       (error
        (metal-butt-log "complete: request failed: %s" error)
        (message "Metal Butt: %s" error))
       ((/= tick (buffer-chars-modified-tick))
        (metal-butt-log "complete: response discarded: buffer changed while completing")
        (message "Metal Butt: buffer changed while completing; response discarded"))
       (t
        (setq metal-butt--last-cost (plist-get result :cost)
              metal-butt--last-input-tokens (plist-get result :input-tokens)
              metal-butt--last-premium-requests (or (plist-get result :premium-requests) 0))
        (setq metal-butt-complete--messages
              (append metal-butt-complete--messages
                      (list message `((role . "assistant")
                                      (content . ,(plist-get result :text))))))
        (setq metal-butt-complete--synced-text text
              metal-butt-complete--turns (1+ metal-butt-complete--turns))
        (metal-butt-log "complete: ok turn=%d input-tokens=%d"
                         metal-butt-complete--turns metal-butt--last-input-tokens)
        (condition-case e
            (let ((response (metal-butt-response-parse (plist-get result :text))))
              (pcase (plist-get response :kind)
                ('edit (metal-butt-overlay-propose-all (plist-get response :edits)))
                ('reply
                 (when interactive
                   (message "Metal Butt: %s" (plist-get response :text))))))
          (metal-butt-response-invalid
           (message "Metal Butt: %s (M-x metal-butt-show-last-exchange to see the payload)"
                    (cadr e))))
        (force-mode-line-update))))))

;;;###autoload
(defun metal-butt-complete-at-point (&optional interactive)
  "Ask the model to complete or write code at point.
The proposal comes back for review through the exact same
`metal-butt-overlay' flow as any other proposed edit: accept/reject,
hunk-by-hunk, diff/full toggle, or the whole-changeset Ediff view.

Only implemented for the `copilot-api' backend for now -- see the
Commentary at the top of this file for why.  INTERACTIVE is non-nil for
a direct, manual call (the usual case); `metal-butt-complete--autocomplete-fire'
passes nil for an idle-triggered call, so a turn that comes back with
nothing to propose stays silent instead of messaging on every idle
trigger."
  (interactive (list t))
  (unless (eq metal-butt-backend 'copilot-api)
    (error "Metal Butt: completion is only implemented for the copilot-api backend"))
  (when metal-butt--in-flight
    (error "Metal Butt: a request is already in flight for this buffer"))
  (metal-butt-complete--ensure-session)
  (let* ((turn (metal-butt-complete--build-user-message metal-butt-complete--synced-text))
         (message (plist-get turn :message))
         (text (plist-get turn :text))
         (messages (append metal-butt-complete--messages (list message)))
         (tick (buffer-chars-modified-tick))
         (buffer (current-buffer)))
    (setq metal-butt--in-flight t)
    (metal-butt-log "complete: dispatch turn=%d bytes=%d"
                     (1+ metal-butt-complete--turns)
                     (length (alist-get 'content message)))
    (metal-butt-transport-copilot-api-send-messages
     messages
     (lambda (result error)
       (metal-butt-complete--handle buffer message text tick result error interactive)))))

(provide 'metal-butt-complete)
;;; metal-butt-complete.el ends here
