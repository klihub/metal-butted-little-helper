;;; metal-butt-transport-test.el --- Tests for the transport  -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'ert)
(require 'metal-butt-transport)

(ert-deftest metal-butt-transport-argv-has-required-flags ()
  (let ((argv (metal-butt-transport-argv "11111111-1111-5111-8111-111111111111")))
    (should (member "-p" argv))
    (should (member "--output-format" argv))
    (should (member "json" argv))
    (should (member "--resume" argv))
    (should (member "11111111-1111-5111-8111-111111111111" argv))))

(ert-deftest metal-butt-transport-argv-forbids-disk-writes ()
  (let ((argv (metal-butt-transport-argv "x")))
    (should (member "--disallowedTools" argv))
    (should (member "Edit,Write,NotebookEdit" argv))))

(ert-deftest metal-butt-transport-argv-includes-the-contract ()
  (let ((argv (metal-butt-transport-argv "x")))
    (should (member "--append-system-prompt" argv))
    (should (seq-find (lambda (a) (string-match-p "\"kind\"" a)) argv))))

(ert-deftest metal-butt-transport-argv-uses-configured-model ()
  (let ((metal-butt-model "haiku"))
    (should (member "haiku" (metal-butt-transport-argv "x")))))

(ert-deftest metal-butt-active-model-falls-back-to-per-backend-default ()
  (let ((metal-butt-model nil)
        (metal-butt-backend 'claude)
        (metal-butt-claude-model "sonnet")
        (metal-butt-copilot-model "claude-sonnet-5"))
    (should (equal (metal-butt-active-model) "sonnet"))
    (setq metal-butt-backend 'copilot)
    (should (equal (metal-butt-active-model) "claude-sonnet-5"))))

(ert-deftest metal-butt-active-model-prefers-the-explicit-override ()
  (let ((metal-butt-model "gpt-5.4")
        (metal-butt-backend 'copilot)
        (metal-butt-copilot-model "claude-sonnet-5"))
    (should (equal (metal-butt-active-model) "gpt-5.4"))))

(ert-deftest metal-butt-transport-argv-uses-the-backend-default-when-unset ()
  (let ((metal-butt-model nil)
        (metal-butt-backend 'claude)
        (metal-butt-claude-model "sonnet"))
    (should (member "sonnet" (metal-butt-transport-argv "x")))))

(ert-deftest metal-butt-transport-extracts-result-and-usage ()
  (let* ((json "{\"result\":\"OK\",\"total_cost_usd\":0.0042,\"usage\":{\"input_tokens\":1234}}")
         (r (metal-butt-transport--extract-result json)))
    (should (equal (plist-get r :text) "OK"))
    (should (= (plist-get r :cost) 0.0042))
    (should (= (plist-get r :input-tokens) 1234))))

(ert-deftest metal-butt-transport-extract-rejects-missing-result ()
  (should-error (metal-butt-transport--extract-result "{\"usage\":{}}")
                :type 'metal-butt-transport-error))

(ert-deftest metal-butt-transport-extract-rejects-garbage ()
  (should-error (metal-butt-transport--extract-result "not json")
                :type 'metal-butt-transport-error))

(ert-deftest metal-butt-transport-diagnoses-iam-denial ()
  (let ((msg (metal-butt-transport--classify-error
              "API Error: 403 {\"Message\":\"User: arn:aws:iam::1:user/u is not authorized to perform: bedrock:InvokeModelWithResponseStream ... with an explicit deny in an identity-based policy: arn:aws:iam::1:policy/BedrockMinimalInferenceAccess\"}")))
    (should (string-match-p "BedrockMinimalInferenceAccess" msg))
    (should (string-match-p "explicit deny" msg))))

(ert-deftest metal-butt-transport-does-not-suggest-a-cheaper-model ()
  "A silent downgrade would change edit quality without the user knowing why."
  (let ((msg (metal-butt-transport--classify-error "API Error: 403 explicit deny")))
    (should-not (string-match-p "haiku" msg))))

(ert-deftest metal-butt-transport-passes-through-unknown-errors ()
  (should (string-match-p "boom" (metal-butt-transport--classify-error "boom"))))

(ert-deftest metal-butt-transport-argv-can-create-a-session ()
  (let ((argv (metal-butt-transport-argv "x" 'create)))
    (should (member "--session-id" argv))
    (should-not (member "--resume" argv))))

(ert-deftest metal-butt-transport-detects-missing-session ()
  (should (metal-butt-transport--missing-session-p
           "No conversation found with session ID abc"))
  (should-not (metal-butt-transport--missing-session-p "explicit deny"))
  (should-not (metal-butt-transport--missing-session-p nil)))

(ert-deftest metal-butt-transport-finish-marks-missing-session-retryable ()
  (let (captured)
    (metal-butt-transport--finish
     "" "No conversation found with session ID abc" 1
     (lambda (&rest args) (setq captured args)))
    (should-not (nth 0 captured))
    (should (nth 1 captured))
    (should (nth 2 captured))))

(ert-deftest metal-butt-transport-finish-does-not-retry-other-errors ()
  "An IAM denial must not be mistaken for a missing session."
  (let (captured)
    (metal-butt-transport--finish
     "" "API Error: 403 explicit deny" 1
     (lambda (&rest args) (setq captured args)))
    (should (nth 1 captured))
    (should-not (nth 2 captured))))

(ert-deftest metal-butt-transport-finish-passes-result-on-success ()
  (let (captured)
    (metal-butt-transport--finish
     "{\"result\":\"OK\",\"total_cost_usd\":0.001,\"usage\":{\"input_tokens\":5}}"
     "" 0
     (lambda (&rest args) (setq captured args)))
    (should (equal (plist-get (nth 0 captured) :text) "OK"))
    (should-not (nth 1 captured))
    (should-not (nth 2 captured))))

(ert-deftest metal-butt-transport-times-out-a-slow-process ()
  "A process that never answers must not leave the caller waiting forever."
  (let ((metal-butt-executable "sleep")
        (metal-butt-request-timeout 1)
        (outcome 'none))
    (cl-letf (((symbol-function 'metal-butt-transport-argv)
               (lambda (&rest _) (list "30"))))
      (metal-butt-transport--run
       "" "irrelevant-session-id"
       (lambda (result error) (setq outcome (list result error))))
      (let ((deadline (+ (float-time) 10)))
        (while (and (eq outcome 'none) (< (float-time) deadline))
          (sit-for 0.1))))
    (should (listp outcome))
    (should-not (nth 0 outcome))
    (should (string-match-p "no response after 1 seconds" (nth 1 outcome)))))

(ert-deftest metal-butt-transport-records-the-exchange ()
  "A parse failure must not destroy the evidence needed to diagnose it."
  (let ((metal-butt-executable "true")
        (metal-butt-request-timeout 5)
        (metal-butt-transport-last-exchange nil)
        (finished nil))
    (cl-letf (((symbol-function 'metal-butt-transport-argv)
               (lambda (&rest _) (list "--flag"))))
      (metal-butt-transport--run
       "the request body" "some-session"
       (lambda (&rest _) (setq finished t)))
      (let ((deadline (+ (float-time) 5)))
        (while (and (not finished) (< (float-time) deadline))
          (sit-for 0.05))))
    (should (member "--flag" (plist-get metal-butt-transport-last-exchange :argv)))
    (should (equal (plist-get metal-butt-transport-last-exchange :request)
                   "the request body"))
    (should (= 0 (plist-get metal-butt-transport-last-exchange :exit)))
    (should (natnump (plist-get metal-butt-transport-last-exchange :duration-ms)))))

(ert-deftest metal-butt-transport-contract-escapes-newline-correctly ()
  "The contract must ask for \\n, not \\\\n.
Two backslashes decode to a literal backslash-then-n, which could never
match text in the user's buffer, so the instruction would cause the very
failure it exists to prevent."
  (should (string-search "as \\n;" metal-butt-transport-contract))
  (should-not (string-search "as \\\\n;" metal-butt-transport-contract)))

(ert-deftest metal-butt-transport-rejects-an-unknown-model ()
  (should-error (metal-butt-check-model "opuss"))
  (should (equal "opus" (metal-butt-check-model "opus"))))

(ert-deftest metal-butt-transport-retry-keeps-the-model ()
  "The retry fires from a callback, outside any binding the caller made."
  (let ((seen nil)
        (metal-butt-model "haiku"))
    (cl-letf (((symbol-function 'metal-butt-transport--launch)
               (lambda (_req _sid create cb)
                 (push metal-butt-model seen)
                 (if create
                     (funcall cb (list :text "{}" :cost 0 :input-tokens 0) nil nil)
                   (funcall cb nil "No conversation found" t)))))
      (let ((metal-butt-model "opus"))
        (metal-butt-transport--run "r" "sid" (lambda (&rest _) nil))))
    (should (equal seen '("opus" "opus")))))

(ert-deftest metal-butt-transport-send-uses-claude-by-default ()
  (let* ((metal-butt-backend 'claude)
         (called nil)
         (metal-butt-transport-function
          (lambda (req sid cb) (setq called (list req sid)) (funcall cb nil nil))))
    (metal-butt-transport-send "req" "sid" (lambda (&rest _) nil))
    (should (equal called '("req" "sid")))))

(ert-deftest metal-butt-transport-send-dispatches-to-copilot-when-configured ()
  (let* ((metal-butt-backend 'copilot)
         (claude-called nil)
         (copilot-called nil)
         (metal-butt-transport-function
          (lambda (&rest _) (setq claude-called t)))
         (metal-butt-transport-copilot-function
          (lambda (req sid cb) (setq copilot-called (list req sid)) (funcall cb nil nil))))
    (metal-butt-transport-send "req" "sid" (lambda (&rest _) nil))
    (should-not claude-called)
    (should (equal copilot-called '("req" "sid")))))

(ert-deftest metal-butt-transport-send-dispatches-to-copilot-api-when-configured ()
  (let* ((metal-butt-backend 'copilot-api)
         (claude-called nil)
         (copilot-api-called nil)
         (metal-butt-transport-function
          (lambda (&rest _) (setq claude-called t)))
         (metal-butt-transport-copilot-api-function
          (lambda (req sid cb) (setq copilot-api-called (list req sid)) (funcall cb nil nil))))
    (metal-butt-transport-send "req" "sid" (lambda (&rest _) nil))
    (should-not claude-called)
    (should (equal copilot-api-called '("req" "sid")))))

(ert-deftest metal-butt-check-model-dispatches-per-backend ()
  (let ((metal-butt-backend 'claude))
    (should-error (metal-butt-check-model "not-a-claude-model")))
  (let ((metal-butt-backend 'copilot))
    (should (equal "anything-nonempty" (metal-butt-check-model "anything-nonempty"))))
  (let ((metal-butt-backend 'copilot-api))
    (should (equal "anything-nonempty" (metal-butt-check-model "anything-nonempty")))))
