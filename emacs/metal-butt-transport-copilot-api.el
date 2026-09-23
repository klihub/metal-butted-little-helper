;;; metal-butt-transport-copilot-api.el --- Talk to Copilot's chat API directly  -*- lexical-binding: t; -*-

;;; Commentary:
;; Third backend, selected via `metal-butt-backend' set to `copilot-api'.
;; Unlike `metal-butt-transport-copilot' (which shells out to the `copilot'
;; CLI once per request), this module skips the CLI entirely and calls
;; GitHub's chat-completions endpoint directly over HTTPS via curl.
;;
;; Why this exists: the `copilot' CLI's non-interactive `-p' mode pays a
;; large, mostly fixed per-invocation cost -- process startup, an
;; update-check network round trip, MCP server discovery/handshake, tool
;; schema loading, and a telemetry flush at shutdown -- on top of the
;; actual model call.  Measured on a real invocation: ~7-8s wall time of
;; which only ~1-4s was `totalApiDurationMs'.  None of that overhead buys
;; anything for metal-butt, which never lets the CLI use tools (every
;; request denies `write' and `shell') and never relies on the CLI's own
;; session/context management (the whole buffer is resent on every call
;; regardless of backend).  So the agent harness is pure overhead here.
;;
;; This backend reuses the GitHub OAuth token already cached on disk by
;; the `copilot-chat' Emacs package
;; (`metal-butt-copilot-api-github-token-file'), rather than performing
;; its own device-flow login, on the reasoning that duplicating a login
;; dance a user has already done once is pure friction.  If that file is
;; absent, this backend simply cannot be used -- there is no fallback
;; login flow here, deliberately: see the file's docstring below.
;;
;; The GitHub token is exchanged for a short-lived Copilot API token via
;; `GET https://api.github.com/copilot_internal/v2/token' (verified: this
;; is the same exchange `copilot-chat-curl.el' performs).  That token is
;; cached in memory and renewed only after it has actually expired
;; (`expires_at' in the exchange response), not on every request, since
;; the exchange itself is a network round trip (~0.6s measured).
;;
;; The actual request is a single-turn, non-streaming
;; `POST https://api.githubcopilot.com/chat/completions' with the whole
;; buffer + contract as one user message, matching what the CLI backends
;; already do (no multi-turn history is replicated -- see Commentary in
;; `metal-butt-transport-copilot.el' for why the full buffer is resent
;; every time regardless of backend).  Measured end-to-end latency for
;; this path: ~1-1.5s, versus ~7-8s for the CLI backend, for the same
;; model and an equivalent prompt.

;;; Code:

(require 'seq)
(require 'json)
(require 'url)
(require 'metal-butt-response)
(require 'metal-butt-log)

(defvar metal-butt-request-timeout)
(declare-function metal-butt-active-model "metal-butt-transport")

(define-error 'metal-butt-copilot-api-transport-error
  "Copilot chat-completions API request failed")

(defcustom metal-butt-copilot-api-github-token-file
  "~/.config/copilot-chat/github-token"
  "File holding a cached GitHub OAuth token, reused from `copilot-chat'.
This backend performs no login flow of its own.  If this file does not
exist, install and log in with the `copilot-chat' Emacs package once
\(or place a valid token here yourself\) before using
`metal-butt-backend' `copilot-api'."
  :type 'string
  :group 'metal-butt)

(defcustom metal-butt-copilot-api-curl-program "curl"
  "Curl program used to reach the Copilot API."
  :type 'string
  :group 'metal-butt)

(defvar metal-butt-copilot-api--token nil
  "Cached Copilot API bearer token, an alist with `token' and `expires-at'.
Renewed lazily by `metal-butt-copilot-api--ensure-token' once it is missing
or actually expired, not on every request, and also refreshed proactively
in the background by `metal-butt-copilot-api--schedule-refresh' shortly
before it expires, so a request after a long idle period usually finds a
token already warm instead of paying the exchange latency itself.")

(defcustom metal-butt-copilot-api-token-prefetch-margin 60
  "Seconds before token expiry that the background refresh fires.
Set to 0 to disable proactive refresh and fall back to the old
lazy-only behaviour (a token is still renewed on demand if it has
actually expired by the time a request needs it)."
  :type 'integer
  :group 'metal-butt)

(defvar metal-butt-copilot-api--refresh-timer nil
  "Timer for the background token refresh, or nil if none is scheduled.")

(defun metal-butt-copilot-api--read-github-token ()
  "Read the cached GitHub OAuth token from
`metal-butt-copilot-api-github-token-file'."
  (let ((file (expand-file-name metal-butt-copilot-api-github-token-file)))
    (unless (file-readable-p file)
      (signal 'metal-butt-copilot-api-transport-error
              (list (format "no GitHub token at %s -- log in with copilot-chat once, or place a token there yourself"
                             file))))
    (string-trim (with-temp-buffer
                   (insert-file-contents file)
                   (buffer-string)))))

(defun metal-butt-copilot-api--token-valid-p ()
  "Return non-nil if `metal-butt-copilot-api--token' is present and unexpired."
  (and metal-butt-copilot-api--token
       (let ((expires-at (alist-get 'expires-at metal-butt-copilot-api--token)))
         (and (numberp expires-at) (< (float-time) expires-at)))))

(defun metal-butt-copilot-api--exchange-token ()
  "Exchange the cached GitHub token for a short-lived Copilot API token.
Synchronous: this is a small, occasional call \(roughly every 25 minutes,
per the exchange response's own `refresh_in'\), not one made per request,
so blocking Emacs briefly here is an acceptable trade for not threading
another async callback layer through every request."
  (let* ((github-token (metal-butt-copilot-api--read-github-token))
         (url-request-method "GET")
         (url-request-extra-headers
          `(("authorization" . ,(format "token %s" github-token))))
         (buffer (url-retrieve-synchronously
                  "https://api.github.com/copilot_internal/v2/token"
                  t t 15)))
    (unless buffer
      (signal 'metal-butt-copilot-api-transport-error
              (list "token exchange timed out or failed to connect")))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (unless (search-forward "\n\n" nil t)
            (signal 'metal-butt-copilot-api-transport-error
                    (list "token exchange response has no body")))
          (let* ((data (condition-case e
                           (json-parse-buffer :object-type 'alist
                                               :null-object nil :false-object nil)
                         (error (signal 'metal-butt-copilot-api-transport-error
                                        (list (format "unparseable token exchange response: %s"
                                                       (error-message-string e)))))))
                 (token (alist-get 'token data))
                 (expires-at (alist-get 'expires_at data)))
            (unless (stringp token)
              (signal 'metal-butt-copilot-api-transport-error
                      (list (format "token exchange did not return a token: %S" data))))
            (setq metal-butt-copilot-api--token
                  (list (cons 'token token)
                        (cons 'expires-at (if (numberp expires-at)
                                               (float expires-at)
                                             (+ (float-time) 1500)))))
            (metal-butt-copilot-api--schedule-refresh)))
      (kill-buffer buffer))))

(defun metal-butt-copilot-api--schedule-refresh ()
  "Arrange a background token exchange shortly before the current one expires.
Cancels any timer already pending first, so repeated calls (a proactive
refresh followed by a lazy one, say) never stack up more than one
pending timer.  Does nothing if `metal-butt-copilot-api-token-prefetch-margin'
is zero or the current token has no known expiry.  Errors from the
background exchange are reported with `message' rather than signalled,
since there is no synchronous caller here to catch them -- the next
request's lazy `metal-butt-copilot-api--ensure-token' still renews the
token itself if this background attempt fails."
  (when metal-butt-copilot-api--refresh-timer
    (cancel-timer metal-butt-copilot-api--refresh-timer)
    (setq metal-butt-copilot-api--refresh-timer nil))
  (let ((expires-at (alist-get 'expires-at metal-butt-copilot-api--token)))
    (when (and (numberp expires-at)
               (> metal-butt-copilot-api-token-prefetch-margin 0))
      (let ((delay (- expires-at (float-time) metal-butt-copilot-api-token-prefetch-margin)))
        (setq metal-butt-copilot-api--refresh-timer
              (run-at-time
               (max delay 1) nil
               (lambda ()
                 (setq metal-butt-copilot-api--refresh-timer nil)
                 (condition-case e
                     (progn
                       (metal-butt-copilot-api--exchange-token)
                       (metal-butt-log "copilot-api: background token refresh succeeded"))
                   (error
                    (metal-butt-log "copilot-api: background token refresh failed: %s"
                                     (error-message-string e))
                    (message "Metal Butt: background token refresh failed (%s); will retry on next request"
                             (error-message-string e)))))))))))

(defun metal-butt-copilot-api--ensure-token ()
  "Return a valid Copilot API bearer token, renewing it if necessary."
  (unless (metal-butt-copilot-api--token-valid-p)
    (metal-butt-copilot-api--exchange-token))
  (alist-get 'token metal-butt-copilot-api--token))

(defcustom metal-butt-copilot-api-stream t
  "Whether to request a streaming response from the chat/completions API.
When non-nil, `metal-butt-transport-copilot-api--launch' requests
Server-Sent Events (`stream: true') and reports partial text as it
arrives via its PROGRESS callback, in addition to the final result via
its usual CALLBACK.  Disable if the streaming path ever misbehaves — a
non-streaming request to the same endpoint always works as a fallback."
  :type 'boolean
  :group 'metal-butt)

(defun metal-butt-copilot-api--build-body (request model &optional stream)
  "Build the JSON request body for REQUEST under MODEL.
Prepends `metal-butt-response-contract' to REQUEST, the same way
`metal-butt-transport-copilot--build-stdin' does for the CLI backend --
this endpoint has no system-prompt parameter that survives across an
arbitrary target repository without setup, so the contract travels as
part of the one user message instead.  STREAM controls the `stream'
field sent to the API; nil (the default) matches the previous
non-streaming behavior.  When STREAM is non-nil, also requests
`stream_options.include_usage' -- without it, a streamed response has no
`usage' object at all (verified against a real streamed response), so
`:input-tokens' silently reports 0 and `metal-butt-session-should-roll-p'
never fires for this backend while streaming; asking for it here makes
the roll nudge work the same regardless of `metal-butt-copilot-api-stream'."
  (json-serialize
   `((model . ,model)
     (stream . ,(if stream t :false))
     ,@(when stream '((stream_options . ((include_usage . t)))))
     (messages . [((role . "user")
                   (content . ,(concat metal-butt-response-contract "\n\n" request)))]))))

(defun metal-butt-copilot-api--auth-header (token)
  "Build the `authorization' header value carrying TOKEN.
The chat/completions endpoint expects a Bearer-prefixed value; a bare
token (correct for the *token-exchange* call this token came from, see
`metal-butt-copilot-api--exchange-token') is rejected here with an
\"IDE token is malformed\" error -- verified against a real failing
invocation."
  (format "authorization: %s %s" "Bearer" token))

(defun metal-butt-copilot-api--curl-command (auth-header)
  "Build the curl argv for a chat/completions call using AUTH-HEADER.
Shared by the real invocation and the redacted copy recorded for
`metal-butt-show-last-exchange', so the two can never drift apart the
way a hand-duplicated pair of argv lists could."
  (list metal-butt-copilot-api-curl-program
        "-s" "-S"
        "https://api.githubcopilot.com/chat/completions"
        "-X" "POST"
        "-H" auth-header
        "-H" "content-type: application/json"
        "-H" "copilot-integration-id: vscode-chat"
        "--data-binary" "@-"))

(defvar metal-butt-transport-copilot-api-last-exchange nil
  "Plist recording the most recent direct-API Copilot invocation.
Keys: :argv :request :stdout :stderr :exit :duration-ms.  Mirrors the two
CLI backends' last-exchange variables so `metal-butt-show-last-exchange'
works unmodified across all three backends.  `:argv' here is the curl
command line actually run, with the bearer token redacted.")

(defun metal-butt-copilot-api--extract-result (json-text)
  "Pull the reply text and usage figures out of JSON-TEXT.
JSON-TEXT is one `chat/completions' response body, not JSONL -- unlike the
CLI backend, this endpoint answers with a single JSON document."
  (let* ((data (condition-case e
                   (json-parse-string json-text :object-type 'alist
                                       :null-object nil :false-object nil)
                 (error (signal 'metal-butt-copilot-api-transport-error
                                (list (format "unparseable response: %s"
                                              (error-message-string e)))))))
         (error-obj (alist-get 'error data)))
    (when error-obj
      (signal 'metal-butt-copilot-api-transport-error
              (list (or (alist-get 'message error-obj) (format "%S" error-obj)))))
    (let* ((choices (alist-get 'choices data))
           (first-choice (and (vectorp choices) (> (length choices) 0) (elt choices 0)))
           (message (and first-choice (alist-get 'message first-choice)))
           (text (and message (alist-get 'content message)))
           (usage (alist-get 'usage data)))
      (unless (stringp text)
        (signal 'metal-butt-copilot-api-transport-error
                (list (format "no reply text in response: %S" data))))
      (list :text text
            :cost 0
            :input-tokens (or (alist-get 'prompt_tokens usage) 0)
            :premium-requests 0))))

(defun metal-butt-copilot-api--sse-events (text)
  "Split TEXT (raw Server-Sent-Events bytes) into a list of `data:' payloads.
Each event is a line starting with `data: ' followed by either a JSON
object or the literal `[DONE]' sentinel; blank lines separate events but
carry no payload of their own and are dropped.  This only looks at
complete lines, so a chunk ending mid-line is handled by the caller
re-parsing the whole accumulated buffer on every new chunk rather than
this function trying to track partial state itself."
  (let (out)
    (dolist (line (split-string text "\n"))
      (when (string-prefix-p "data: " line)
        (push (substring line (length "data: ")) out)))
    (nreverse out)))

(defun metal-butt-copilot-api--sse-delta (payload)
  "Pull the incremental text out of one streamed PAYLOAD, or nil.
PAYLOAD is one `data: ' event body from `metal-butt-copilot-api--sse-events'.
Returns nil for the `[DONE]' sentinel, a malformed/unparseable payload, or
a chunk with no text delta (such as the first chunk, which only carries
role/metadata) -- callers should treat nil as \"nothing to display yet\",
not as an error, since these are all routine parts of a normal stream."
  (unless (equal payload "[DONE]")
    (ignore-errors
      (let* ((data (json-parse-string payload :object-type 'alist
                                       :null-object nil :false-object nil))
             (choices (alist-get 'choices data))
             (first-choice (and (vectorp choices) (> (length choices) 0) (elt choices 0)))
             (delta (and first-choice (alist-get 'delta first-choice)))
             (content (and delta (alist-get 'content delta))))
        (and (stringp content) (> (length content) 0) content)))))

(defun metal-butt-copilot-api--stream-text (raw)
  "Reassemble the full reply text streamed so far from RAW SSE bytes.
Reparses everything accumulated so far rather than tracking incremental
state, which is simpler and cheap at the sizes involved here (a whole
reply is at most a few KB of JSON deltas)."
  (mapconcat (lambda (payload) (or (metal-butt-copilot-api--sse-delta payload) ""))
             (metal-butt-copilot-api--sse-events raw)
             ""))

(defun metal-butt-copilot-api--stream-usage (raw)
  "Return the `prompt_tokens' figure from RAW streamed SSE bytes, or 0.
With `stream_options.include_usage' requested (see
`metal-butt-copilot-api--build-body'), the API sends one extra final
chunk carrying a top-level `usage' object and an empty `choices' array;
every other chunk has no `usage' at all, so this looks at every event
and returns the first one found rather than assuming which position it
arrives in."
  (or (seq-some
       (lambda (payload)
         (unless (equal payload "[DONE]")
           (ignore-errors
             (let* ((data (json-parse-string payload :object-type 'alist
                                              :null-object nil :false-object nil))
                    (usage (alist-get 'usage data)))
               (and usage (alist-get 'prompt_tokens usage))))))
       (metal-butt-copilot-api--sse-events raw))
      0))

(defun metal-butt-copilot-api--finish (out err code callback &optional streamed)
  "Interpret one invocation's OUT, ERR and exit CODE, then call CALLBACK.
Same contract as `metal-butt-transport-copilot--finish'.  STREAMED non-nil
means OUT is raw Server-Sent-Events bytes rather than one JSON document,
so the reply text is reassembled via `metal-butt-copilot-api--stream-text'
instead of parsed with `metal-butt-copilot-api--extract-result'.  Token
usage for a streamed response comes from `metal-butt-copilot-api--stream-usage',
which relies on the `stream_options.include_usage' opt-in sent by
`metal-butt-copilot-api--build-body' -- without it there would be no
`usage' object at all and `metal-butt-session-should-roll-p' would never
fire for this backend while streaming.  Cost is always reported as 0
either way: the mode line already shows \" api\" rather than a dollar
figure for this backend, since the API's response never carries a cost."
  (if (zerop code)
      (condition-case e
          (funcall callback
                   (if streamed
                       (let ((text (metal-butt-copilot-api--stream-text out)))
                         (when (string-empty-p text)
                           (signal 'metal-butt-copilot-api-transport-error
                                   (list (format "no reply text in streamed response: %s" out))))
                         (list :text text :cost 0
                               :input-tokens (metal-butt-copilot-api--stream-usage out)
                               :premium-requests 0))
                     (metal-butt-copilot-api--extract-result out))
                   nil)
        (metal-butt-copilot-api-transport-error (funcall callback nil (cadr e))))
    (let ((text (if (string-empty-p (string-trim err)) out err)))
      (funcall callback nil (format "curl failed (exit %d): %s" code text)))))

(defun metal-butt-transport-copilot-api--launch (request session-id callback &optional progress)
  "Send REQUEST for SESSION-ID to the Copilot chat-completions API.
SESSION-ID is accepted for interface parity with the other two backends'
launch functions but unused: this backend has no server-side session
concept, since it makes a single-turn call carrying the whole buffer, the
same as the other two backends effectively do already.

When `metal-butt-copilot-api-stream' is non-nil, the request asks for a
streaming response and, if PROGRESS is given, calls it as (PROGRESS TEXT)
with the reply text reassembled so far every time a new chunk arrives —
letting a caller show the answer growing live instead of only once the
whole thing has arrived.  PROGRESS is never called with a final/complete
guarantee; only CALLBACK's eventual result is authoritative."
  (ignore session-id)
  (condition-case e
      (let* ((start-time (float-time))
             (token (metal-butt-copilot-api--ensure-token))
             (model (metal-butt-active-model))
             (streaming metal-butt-copilot-api-stream)
             (body (metal-butt-copilot-api--build-body request model streaming))
             (stdout (generate-new-buffer " *metal-butt-copilot-api-stdout*"))
             (stderr (generate-new-buffer " *metal-butt-copilot-api-stderr*"))
             (done nil)
             (timer nil)
             (proc nil)
             (redacted-argv (metal-butt-copilot-api--curl-command "authorization: ******")))
        (setq metal-butt-transport-copilot-api-last-exchange
              (list :argv redacted-argv :request request))
        (setq proc
              (make-process
               :name "metal-butt-copilot-api"
               :buffer stdout
               :stderr stderr
               :noquery t
               :connection-type 'pipe
               :command (metal-butt-copilot-api--curl-command
                         (metal-butt-copilot-api--auth-header token))
               :filter
               (lambda (proc chunk)
                 (when (buffer-live-p (process-buffer proc))
                   (with-current-buffer (process-buffer proc)
                     (goto-char (point-max))
                     (insert chunk)))
                 (when (and streaming progress)
                   (ignore-errors
                     (funcall progress
                              (metal-butt-copilot-api--stream-text
                               (with-current-buffer stdout (buffer-string)))))))
               :sentinel
               (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (let ((out (with-current-buffer stdout (buffer-string)))
                         (err (with-current-buffer stderr (buffer-string)))
                         (code (process-exit-status proc))
                         (duration-ms (round (* 1000 (- (float-time) start-time)))))
                     (setq metal-butt-transport-copilot-api-last-exchange
                           (plist-put (plist-put (plist-put (plist-put
                                                   metal-butt-transport-copilot-api-last-exchange
                                                   :stdout out)
                                                  :stderr err)
                                       :exit code)
                                       :duration-ms duration-ms))
                     (kill-buffer stdout)
                     (kill-buffer stderr)
                     (unless done
                       (setq done t)
                       (when timer (cancel-timer timer))
                       (metal-butt-copilot-api--finish out err code callback streaming)))))))
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
        (process-send-string proc body)
        (process-send-eof proc))
    (metal-butt-copilot-api-transport-error
     (funcall callback nil (cadr e)))))

(defvar metal-butt-transport-copilot-api-function
  #'metal-butt-transport-copilot-api--launch
  "Function used to reach the Copilot chat-completions API.
Called as (FN REQUEST SESSION-ID CALLBACK PROGRESS).  Rebind in tests.")

(defun metal-butt-transport-copilot-api-send (request session-id callback &optional progress)
  "Send REQUEST for SESSION-ID via `metal-butt-transport-copilot-api-function'.
PROGRESS, if given, is forwarded as the streaming-progress callback; see
`metal-butt-transport-copilot-api--launch'."
  (funcall metal-butt-transport-copilot-api-function request session-id callback progress))

(defun metal-butt-copilot-api--unavailable-error-p (error-string)
  "Non-nil if ERROR-STRING indicates the `copilot-api' backend is simply
unavailable right now, as opposed to an error that switching backends
would not fix (a rejected model name, a malformed response body, an API
error message from Copilot itself, and so on).  Matches: a missing
GitHub token file, the token-exchange call failing to connect, or curl
itself failing to reach the chat/completions endpoint -- curl reports a
non-zero exit only for a connection-level failure, since an HTTP-level
error from the API comes back as a 200-exit-code response body instead."
  (and (stringp error-string)
       (string-match-p
        "no GitHub token at\\|token exchange timed out or failed to connect\\|curl failed (exit"
        error-string)))

(provide 'metal-butt-transport-copilot-api)
;;; metal-butt-transport-copilot-api.el ends here
