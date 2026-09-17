;;; metal-butt-transport-test.el --- Tests for the transport  -*- lexical-binding: t; -*-
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
