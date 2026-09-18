;;; metal-butt-transport-copilot-test.el --- Tests for the Copilot transport  -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'ert)
(require 'metal-butt-transport-copilot)
;; `metal-butt-model' and `metal-butt-request-timeout' are shared knobs
;; defined in `metal-butt-transport', not duplicated here; require it
;; explicitly so this file's tests do not depend on load order.
(require 'metal-butt-transport)

(ert-deftest metal-butt-copilot-argv-has-required-flags ()
  (let ((argv (metal-butt-transport-copilot-argv "11111111-1111-5111-8111-111111111111")))
    (should (member "--session-id" argv))
    (should (member "11111111-1111-5111-8111-111111111111" argv))
    (should (member "--output-format" argv))
    (should (member "json" argv))
    (should (member "--allow-all-tools" argv))))

(ert-deftest metal-butt-copilot-argv-has-no-create-resume-distinction ()
  "Verified: --session-id both creates and resumes; there is nothing to switch."
  (let ((argv (metal-butt-transport-copilot-argv "x")))
    (should-not (member "--resume" argv))
    (should-not (member "--create" argv))))

(ert-deftest metal-butt-copilot-argv-forbids-disk-writes ()
  (let ((argv (metal-butt-transport-copilot-argv "x")))
    (should (member "--deny-tool" argv))
    (should (member "write" argv))
    (should (member "shell" argv))))

(ert-deftest metal-butt-copilot-argv-uses-configured-model ()
  (let ((metal-butt-model "claude-sonnet-5"))
    (should (member "claude-sonnet-5" (metal-butt-transport-copilot-argv "x")))))

(ert-deftest metal-butt-copilot-build-stdin-prepends-the-contract ()
  (let ((stdin (metal-butt-transport-copilot--build-stdin "the request body")))
    (should (string-prefix-p metal-butt-response-contract stdin))
    (should (string-suffix-p "the request body" stdin))))

(defun metal-butt-copilot-test--jsonl (&rest lines)
  "Join LINES, each a string, with newlines, as a fake CLI stdout."
  (string-join lines "\n"))

(ert-deftest metal-butt-copilot-extract-result-uses-the-last-assistant-message ()
  "A turn that calls a tool before answering emits more than one
`assistant.message' event; only the last is the actual answer."
  (let* ((stdout (metal-butt-copilot-test--jsonl
                  "{\"type\":\"assistant.message\",\"data\":{\"content\":\"\",\"toolRequests\":[{\"name\":\"bash\"}]}}"
                  "{\"type\":\"assistant.message\",\"data\":{\"content\":\"final answer\",\"toolRequests\":[]}}"
                  "{\"type\":\"result\",\"sessionId\":\"s1\",\"exitCode\":0,\"usage\":{\"premiumRequests\":2}}"))
         (r (metal-butt-transport-copilot--extract-result stdout)))
    (should (equal (plist-get r :text) "final answer"))
    (should (= (plist-get r :premium-requests) 2))
    (should (= (plist-get r :cost) 0))))

(ert-deftest metal-butt-copilot-extract-result-skips-unparseable-lines ()
  "A plain-text banner mixed into stdout must not hide the events around it."
  (let* ((stdout (metal-butt-copilot-test--jsonl
                  "not json at all"
                  "{\"type\":\"assistant.message\",\"data\":{\"content\":\"ok\"}}"
                  ""))
         (r (metal-butt-transport-copilot--extract-result stdout)))
    (should (equal (plist-get r :text) "ok"))))

(ert-deftest metal-butt-copilot-extract-result-rejects-no-assistant-message ()
  (should-error
   (metal-butt-transport-copilot--extract-result
    "{\"type\":\"session.mcp_servers_loaded\",\"data\":{}}")
   :type 'metal-butt-copilot-transport-error))

(ert-deftest metal-butt-copilot-extract-result-reads-checkpoint-prompt-tokens ()
  (let* ((stdout (metal-butt-copilot-test--jsonl
                  "{\"type\":\"assistant.message\",\"data\":{\"content\":\"hi\"}}"
                  (concat "{\"type\":\"session.usage_checkpoint\",\"data\":{"
                          "\"promptCacheBreakState\":[{\"models\":{"
                          "\"claude-sonnet-5\":{\"prompt_tokens\":20119}}}]}}")))
         (r (metal-butt-transport-copilot--extract-result stdout)))
    (should (= (plist-get r :input-tokens) 20119))))

(ert-deftest metal-butt-copilot-checkpoint-prompt-tokens-tolerates-absence ()
  (should-not (metal-butt-transport-copilot--checkpoint-prompt-tokens nil))
  (should-not (metal-butt-transport-copilot--checkpoint-prompt-tokens '((foo . "bar")))))

(ert-deftest metal-butt-copilot-classify-error-hints-at-unknown-model ()
  (let ((msg (metal-butt-transport-copilot--classify-error
              "Error: Model \"not-a-real-model\" from --model flag is not available.")))
    (should (string-match-p "metal-butt-model" msg))
    (should (string-match-p "not-a-real-model" msg))))

(ert-deftest metal-butt-copilot-classify-error-passes-through-unknown-errors ()
  (should (string-match-p "boom" (metal-butt-transport-copilot--classify-error "boom"))))

(ert-deftest metal-butt-copilot-finish-passes-result-on-success ()
  (let (captured)
    (metal-butt-transport-copilot--finish
     "{\"type\":\"assistant.message\",\"data\":{\"content\":\"OK\"}}"
     "" 0
     (lambda (&rest args) (setq captured args)))
    (should (equal (plist-get (nth 0 captured) :text) "OK"))
    (should-not (nth 1 captured))))

(ert-deftest metal-butt-copilot-finish-uses-stderr-on-failure ()
  "Verified: an invalid model exits 1 with the error on stderr, not stdout."
  (let (captured)
    (metal-butt-transport-copilot--finish
     "{\"type\":\"session.mcp_server_status_changed\",\"data\":{}}"
     "Error: Model \"bogus\" from --model flag is not available.\n" 1
     (lambda (&rest args) (setq captured args)))
    (should-not (nth 0 captured))
    (should (string-match-p "not available" (nth 1 captured)))))

(ert-deftest metal-butt-copilot-finish-falls-back-to-stdout-when-stderr-empty ()
  (let (captured)
    (metal-butt-transport-copilot--finish "stdout error text" "" 1
     (lambda (&rest args) (setq captured args)))
    (should-not (nth 0 captured))
    (should (string-match-p "stdout error text" (nth 1 captured)))))

(ert-deftest metal-butt-copilot-check-model-accepts-any-non-empty-name ()
  "The catalogue is large and changes over time; the CLI validates it, not us."
  (should (equal "totally-unheard-of-model"
                 (metal-butt-copilot-check-model "totally-unheard-of-model"))))

(ert-deftest metal-butt-copilot-check-model-rejects-empty ()
  (should-error (metal-butt-copilot-check-model ""))
  (should-error (metal-butt-copilot-check-model nil)))

(ert-deftest metal-butt-copilot-times-out-a-slow-process ()
  (let ((metal-butt-copilot-executable "sleep")
        (metal-butt-request-timeout 1)
        (outcome 'none))
    (cl-letf (((symbol-function 'metal-butt-transport-copilot-argv)
               (lambda (&rest _) (list "30"))))
      (metal-butt-transport-copilot--launch
       "irrelevant" "irrelevant-session-id"
       (lambda (result error) (setq outcome (list result error))))
      (let ((deadline (+ (float-time) 10)))
        (while (and (eq outcome 'none) (< (float-time) deadline))
          (sit-for 0.1))))
    (should (listp outcome))
    (should-not (nth 0 outcome))
    (should (string-match-p "no response after 1 seconds" (nth 1 outcome)))))

(ert-deftest metal-butt-copilot-records-the-exchange ()
  (let ((metal-butt-copilot-executable "true")
        (metal-butt-request-timeout 5)
        (metal-butt-transport-copilot-last-exchange nil)
        (finished nil))
    (cl-letf (((symbol-function 'metal-butt-transport-copilot-argv)
               (lambda (&rest _) (list "--flag"))))
      (metal-butt-transport-copilot--launch
       "the request body" "some-session"
       (lambda (&rest _) (setq finished t)))
      (let ((deadline (+ (float-time) 5)))
        (while (and (not finished) (< (float-time) deadline))
          (sit-for 0.05))))
    (should (member "--flag" (plist-get metal-butt-transport-copilot-last-exchange :argv)))
    (should (string-suffix-p "the request body"
                             (plist-get metal-butt-transport-copilot-last-exchange :request)))
    (should (= 0 (plist-get metal-butt-transport-copilot-last-exchange :exit)))
    (should (natnump (plist-get metal-butt-transport-copilot-last-exchange :duration-ms)))))

(provide 'metal-butt-transport-copilot-test)
;;; metal-butt-transport-copilot-test.el ends here
