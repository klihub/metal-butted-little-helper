;;; metal-butt-transport-copilot-api-test.el --- Tests for the direct Copilot API transport  -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'ert)
(require 'metal-butt-transport-copilot-api)
;; `metal-butt-active-model' and `metal-butt-request-timeout' are shared
;; knobs defined in `metal-butt-transport', not duplicated here; require it
;; explicitly so this file's tests do not depend on load order.
(require 'metal-butt-transport)

(ert-deftest metal-butt-copilot-api-build-body-carries-model-and-request ()
  (let* ((body (metal-butt-copilot-api--build-body "the request body" "claude-sonnet-5"))
         (data (json-parse-string body :object-type 'alist)))
    (should (equal "claude-sonnet-5" (alist-get 'model data)))
    (should (eq :false (alist-get 'stream data)))
    (let* ((messages (alist-get 'messages data))
           (first-message (elt messages 0)))
      (should (equal "user" (alist-get 'role first-message)))
      (should (string-suffix-p "the request body" (alist-get 'content first-message))))))

(ert-deftest metal-butt-copilot-api-build-body-prepends-the-contract ()
  "Without this, the model answers in prose instead of the JSON contract --
verified against a real invocation that omitted it and got an unparseable
markdown reply back."
  (let* ((body (metal-butt-copilot-api--build-body "the request body" "claude-sonnet-5"))
         (data (json-parse-string body :object-type 'alist))
         (content (alist-get 'content (elt (alist-get 'messages data) 0))))
    (should (string-prefix-p metal-butt-response-contract content))))

(ert-deftest metal-butt-copilot-api-auth-header-carries-the-bearer-prefix ()
  "Regression test: an earlier version sent a bare token with no auth-scheme
prefix, which the chat/completions endpoint rejects outright with an
\"IDE token is malformed\" error -- verified against a real failing
invocation via M-x metal-butt-show-last-exchange."
  (should (equal (concat "authorization: " "Bearer" " abc123")
                 (metal-butt-copilot-api--auth-header "abc123"))))

(ert-deftest metal-butt-copilot-api-curl-command-carries-the-real-auth-header ()
  "Regression test: an earlier version passed a literal redacted
placeholder as the actual `authorization' header sent over the wire (a
stray format string with no %s placeholder silently dropped TOKEN), so
every real request went out unauthenticated. Both the real command and
the redacted copy shown by `metal-butt-show-last-exchange' must come
from the same builder so they cannot drift apart like that again."
  (let* ((placeholder "authorization: ******")
         (real-header (metal-butt-copilot-api--auth-header "secret-token"))
         (real (metal-butt-copilot-api--curl-command real-header))
         (redacted (metal-butt-copilot-api--curl-command placeholder)))
    (should (member real-header real))
    (should-not (member placeholder real))
    (should (member placeholder redacted))
    (should-not (member real-header redacted))))

(ert-deftest metal-butt-copilot-api-extract-result-reads-reply-and-usage ()
  (let* ((json (json-serialize
                '((choices . [((message . ((content . "the reply") (role . "assistant"))))])
                  (usage . ((prompt_tokens . 42) (completion_tokens . 4))))))
         (result (metal-butt-copilot-api--extract-result json)))
    (should (equal "the reply" (plist-get result :text)))
    (should (= 42 (plist-get result :input-tokens)))
    (should (= 0 (plist-get result :cost)))))

(ert-deftest metal-butt-copilot-api-extract-result-signals-on-api-error ()
  (let ((json (json-serialize '((error . ((message . "model_not_supported")))))))
    (should-error (metal-butt-copilot-api--extract-result json)
                  :type 'metal-butt-copilot-api-transport-error)))

(ert-deftest metal-butt-copilot-api-extract-result-signals-when-unparseable ()
  (should-error (metal-butt-copilot-api--extract-result "not json")
                :type 'metal-butt-copilot-api-transport-error))

(ert-deftest metal-butt-copilot-api-build-body-requests-streaming-when-asked ()
  (let* ((body (metal-butt-copilot-api--build-body "the request body" "claude-sonnet-5" t))
         (data (json-parse-string body :object-type 'alist)))
    (should (eq t (alist-get 'stream data)))))

(ert-deftest metal-butt-copilot-api-build-body-requests-usage-when-streaming ()
  "Without this, a streamed response has no `usage' object at all, so
`metal-butt-session-should-roll-p' never fires for this backend while
streaming -- see `metal-butt-copilot-api--stream-usage'."
  (let* ((body (metal-butt-copilot-api--build-body "the request body" "claude-sonnet-5" t))
         (data (json-parse-string body :object-type 'alist))
         (options (alist-get 'stream_options data)))
    (should (eq t (alist-get 'include_usage options)))))

(ert-deftest metal-butt-copilot-api-build-body-omits-stream-options-when-not-streaming ()
  (let* ((body (metal-butt-copilot-api--build-body "the request body" "claude-sonnet-5" nil))
         (data (json-parse-string body :object-type 'alist)))
    (should-not (alist-get 'stream_options data))))

(ert-deftest metal-butt-copilot-api-sse-events-extracts-data-lines ()
  (let ((raw "data: {\"a\":1}\n\ndata: {\"a\":2}\n\ndata: [DONE]\n\n"))
    (should (equal '("{\"a\":1}" "{\"a\":2}" "[DONE]")
                   (metal-butt-copilot-api--sse-events raw)))))

(ert-deftest metal-butt-copilot-api-sse-delta-extracts-content ()
  (should (equal "Hi"
                  (metal-butt-copilot-api--sse-delta
                   "{\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"))))

(ert-deftest metal-butt-copilot-api-sse-delta-nil-for-done-sentinel ()
  (should-not (metal-butt-copilot-api--sse-delta "[DONE]")))

(ert-deftest metal-butt-copilot-api-sse-delta-nil-when-no-content ()
  (should-not (metal-butt-copilot-api--sse-delta
               "{\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}")))

(ert-deftest metal-butt-copilot-api-stream-text-accumulates-chunks ()
  (let ((raw (concat "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n"
                      "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n"
                      "data: [DONE]\n\n")))
    (should (equal "Hello" (metal-butt-copilot-api--stream-text raw)))))

(ert-deftest metal-butt-copilot-api-finish-streamed-assembles-text ()
  (let* ((raw (concat "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
                       "data: [DONE]\n\n"))
         (result nil))
    (metal-butt-copilot-api--finish raw "" 0 (lambda (r _e) (setq result r)) t)
    (should (equal "hi" (plist-get result :text)))
    (should (equal 0 (plist-get result :cost)))))

(ert-deftest metal-butt-copilot-api-stream-usage-reads-the-usage-chunk ()
  (let ((raw (concat "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
                      "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":123,\"completion_tokens\":4}}\n\n"
                      "data: [DONE]\n\n")))
    (should (= 123 (metal-butt-copilot-api--stream-usage raw)))))

(ert-deftest metal-butt-copilot-api-stream-usage-zero-when-absent ()
  (let ((raw (concat "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
                      "data: [DONE]\n\n")))
    (should (= 0 (metal-butt-copilot-api--stream-usage raw)))))

(ert-deftest metal-butt-copilot-api-finish-streamed-reports-input-tokens ()
  (let* ((raw (concat "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
                       "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":77}}\n\n"
                       "data: [DONE]\n\n"))
         (result nil))
    (metal-butt-copilot-api--finish raw "" 0 (lambda (r _e) (setq result r)) t)
    (should (= 77 (plist-get result :input-tokens)))))

(ert-deftest metal-butt-copilot-api-token-valid-p-false-when-nil ()
  (let ((metal-butt-copilot-api--token nil))
    (should-not (metal-butt-copilot-api--token-valid-p))))

(ert-deftest metal-butt-copilot-api-token-valid-p-false-when-expired ()
  (let ((metal-butt-copilot-api--token
         (list (cons 'token "expired-token")
               (cons 'expires-at (- (float-time) 10)))))
    (should-not (metal-butt-copilot-api--token-valid-p))))

(ert-deftest metal-butt-copilot-api-token-valid-p-true-when-fresh ()
  (let ((metal-butt-copilot-api--token
         (list (cons 'token "fresh-token")
               (cons 'expires-at (+ (float-time) 600)))))
    (should (metal-butt-copilot-api--token-valid-p))))

(ert-deftest metal-butt-copilot-api-ensure-token-skips-exchange-when-fresh ()
  (let* ((metal-butt-copilot-api--token
          (list (cons 'token "fresh-token") (cons 'expires-at (+ (float-time) 600))))
         (exchange-called nil))
    (cl-letf (((symbol-function 'metal-butt-copilot-api--exchange-token)
               (lambda () (setq exchange-called t))))
      (should (equal "fresh-token" (metal-butt-copilot-api--ensure-token))))
    (should-not exchange-called)))

(ert-deftest metal-butt-copilot-api-schedule-refresh-arms-a-timer ()
  (let ((metal-butt-copilot-api--refresh-timer nil)
        (metal-butt-copilot-api--token
         (list (cons 'token "t") (cons 'expires-at (+ (float-time) 600)))))
    (unwind-protect
        (progn
          (metal-butt-copilot-api--schedule-refresh)
          (should (timerp metal-butt-copilot-api--refresh-timer)))
      (when metal-butt-copilot-api--refresh-timer
        (cancel-timer metal-butt-copilot-api--refresh-timer)))))

(ert-deftest metal-butt-copilot-api-schedule-refresh-does-nothing-without-expiry ()
  (let ((metal-butt-copilot-api--refresh-timer nil)
        (metal-butt-copilot-api--token (list (cons 'token "t"))))
    (metal-butt-copilot-api--schedule-refresh)
    (should-not metal-butt-copilot-api--refresh-timer)))

(ert-deftest metal-butt-copilot-api-schedule-refresh-does-nothing-when-margin-is-zero ()
  (let ((metal-butt-copilot-api--refresh-timer nil)
        (metal-butt-copilot-api-token-prefetch-margin 0)
        (metal-butt-copilot-api--token
         (list (cons 'token "t") (cons 'expires-at (+ (float-time) 600)))))
    (metal-butt-copilot-api--schedule-refresh)
    (should-not metal-butt-copilot-api--refresh-timer)))

(ert-deftest metal-butt-copilot-api-schedule-refresh-cancels-a-prior-pending-timer ()
  (let* ((metal-butt-copilot-api--token
          (list (cons 'token "t") (cons 'expires-at (+ (float-time) 600))))
         (metal-butt-copilot-api--refresh-timer (run-at-time 600 nil #'ignore))
         (stale metal-butt-copilot-api--refresh-timer))
    (unwind-protect
        (progn
          (metal-butt-copilot-api--schedule-refresh)
          (should-not (memq stale timer-list))
          (should (timerp metal-butt-copilot-api--refresh-timer))
          (should (not (eq stale metal-butt-copilot-api--refresh-timer))))
      (when metal-butt-copilot-api--refresh-timer
        (cancel-timer metal-butt-copilot-api--refresh-timer)))))

(ert-deftest metal-butt-copilot-api-send-dispatches-through-the-injectable-seam ()
  (let* ((called nil)
         (metal-butt-transport-copilot-api-function
          (lambda (req sid cb &optional _progress) (setq called (list req sid)) (funcall cb '(:text "ok") nil))))
    (metal-butt-transport-copilot-api-send "req" "sid" (lambda (&rest _) nil))
    (should (equal called '("req" "sid")))))

(provide 'metal-butt-transport-copilot-api-test)
;;; metal-butt-transport-copilot-api-test.el ends here
