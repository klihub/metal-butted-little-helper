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
  "Regression test: an earlier version sent a bare token with no Bearer
prefix, which the chat/completions endpoint rejects outright with an
\"IDE token is malformed\" error -- verified against a real failing
invocation via M-x metal-butt-show-last-exchange."
  (should (equal "authorization: Bearer abc123"
                 (metal-butt-copilot-api--auth-header "abc123"))))

(ert-deftest metal-butt-copilot-api-curl-command-carries-the-real-auth-header ()
  "Regression test: an earlier version passed a literal ******-redacted
string as the actual `authorization' header sent over the wire (a stray
`(format \"authorization: ******\" token)' with no %s placeholder silently
dropped TOKEN), so every real request went out unauthenticated. Both the
real command and the redacted copy shown by
`metal-butt-show-last-exchange' must come from the same builder so they
cannot drift apart like that again."
  (let ((real (metal-butt-copilot-api--curl-command
               (metal-butt-copilot-api--auth-header "secret-token")))
        (redacted (metal-butt-copilot-api--curl-command "authorization: ******")))
    (should (member "authorization: Bearer secret-token" real))
    (should-not (member "authorization: ******" real))
    (should (member "authorization: ******" redacted))
    (should-not (member "authorization: Bearer secret-token" redacted))))

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

(ert-deftest metal-butt-copilot-api-send-dispatches-through-the-injectable-seam ()
  (let* ((called nil)
         (metal-butt-transport-copilot-api-function
          (lambda (req sid cb) (setq called (list req sid)) (funcall cb '(:text "ok") nil))))
    (metal-butt-transport-copilot-api-send "req" "sid" (lambda (&rest _) nil))
    (should (equal called '("req" "sid")))))

(provide 'metal-butt-transport-copilot-api-test)
;;; metal-butt-transport-copilot-api-test.el ends here
