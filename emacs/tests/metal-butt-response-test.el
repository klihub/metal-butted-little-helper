;;; metal-butt-response-test.el --- Tests for response parsing  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-response)

(ert-deftest metal-butt-response-parses-reply ()
  (let ((r (metal-butt-response-parse "{\"kind\":\"reply\",\"text\":\"careful, api.go passes nil\"}")))
    (should (eq (plist-get r :kind) 'reply))
    (should (equal (plist-get r :text) "careful, api.go passes nil"))))

(ert-deftest metal-butt-response-parses-edit ()
  (let* ((json "{\"kind\":\"edit\",\"edits\":[{\"old\":\"a\",\"new\":\"b\",\"why\":\"clearer\"}]}")
         (r (metal-butt-response-parse json))
         (e (car (plist-get r :edits))))
    (should (eq (plist-get r :kind) 'edit))
    (should (equal (plist-get e :old) "a"))
    (should (equal (plist-get e :new) "b"))
    (should (equal (plist-get e :why) "clearer"))))

(ert-deftest metal-butt-response-allows-missing-why ()
  (let* ((r (metal-butt-response-parse "{\"kind\":\"edit\",\"edits\":[{\"old\":\"a\",\"new\":\"b\"}]}"))
         (e (car (plist-get r :edits))))
    (should-not (plist-get e :why))))

(ert-deftest metal-butt-response-rejects-malformed-json ()
  (should-error (metal-butt-response-parse "{not json")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-unknown-kind ()
  (should-error (metal-butt-response-parse "{\"kind\":\"explode\"}")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-reply-without-text ()
  (should-error (metal-butt-response-parse "{\"kind\":\"reply\"}")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-edit-without-edits ()
  (should-error (metal-butt-response-parse "{\"kind\":\"edit\"}")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-edit-missing-old ()
  (should-error (metal-butt-response-parse "{\"kind\":\"edit\",\"edits\":[{\"new\":\"b\"}]}")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-empty-edits ()
  (should-error (metal-butt-response-parse "{\"kind\":\"edit\",\"edits\":[]}")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-tolerates-json-code-fences ()
  (let ((r (metal-butt-response-parse
            "```json\n{\"kind\":\"reply\",\"text\":\"hi\"}\n```")))
    (should (equal (plist-get r :text) "hi"))))

(ert-deftest metal-butt-response-tolerates-bare-code-fences ()
  (let ((r (metal-butt-response-parse
            "```\n{\"kind\":\"reply\",\"text\":\"hi\"}\n```")))
    (should (equal (plist-get r :text) "hi"))))

(ert-deftest metal-butt-response-still-rejects-prose ()
  "Tolerating fences must not turn into tolerating anything."
  (should-error (metal-butt-response-parse "Here you go: not json")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-repairs-raw-newline-in-a-string ()
  "The model writes a literal line break inside a multi-line `old'."
  (let* ((r (metal-butt-response-parse
             "{\"kind\":\"edit\",\"edits\":[{\"old\":\"int a = 1;\nreturn a;\",\"new\":\"x\"}]}"))
         (e (car (plist-get r :edits))))
    (should (equal (plist-get e :old) "int a = 1;\nreturn a;"))))

(ert-deftest metal-butt-response-repairs-raw-newline-inside-fences ()
  (let* ((r (metal-butt-response-parse
             "```json\n{\"kind\":\"reply\",\"text\":\"line one\nline two\"}\n```")))
    (should (equal (plist-get r :text) "line one\nline two"))))

(ert-deftest metal-butt-response-leaves-pretty-printed-json-alone ()
  "Line breaks BETWEEN tokens are outside strings and must not be touched."
  (let ((r (metal-butt-response-parse
            "{\n  \"kind\": \"reply\",\n  \"text\": \"fine\"\n}")))
    (should (equal (plist-get r :text) "fine"))))

(ert-deftest metal-butt-response-repair-is-a-noop-on-valid-json ()
  (let ((valid "{\"kind\":\"reply\",\"text\":\"a\\nb\"}"))
    (should (equal (metal-butt-response--escape-raw-controls valid) valid))))

(ert-deftest metal-butt-response-repair-handles-escaped-quotes ()
  "An escaped quote must not be mistaken for the end of a string."
  (let ((r (metal-butt-response-parse
            "{\"kind\":\"reply\",\"text\":\"he said \\\"hi\\\" then\nleft\"}")))
    (should (equal (plist-get r :text) "he said \"hi\" then\nleft"))))

(ert-deftest metal-butt-response-preview-text-extracts-partial-reply ()
  (should (equal "Hello wor"
                 (metal-butt-response-preview-text
                  "{\"kind\":\"reply\",\"text\":\"Hello wor"))))

(ert-deftest metal-butt-response-preview-text-nil-before-text-field-appears ()
  (should-not (metal-butt-response-preview-text "{\"kind\":\"reply\",\"te")))

(ert-deftest metal-butt-response-preview-text-nil-for-edit-kind ()
  (should-not (metal-butt-response-preview-text "{\"kind\":\"edit\",\"edits\":[")))

(ert-deftest metal-butt-response-preview-text-nil-for-nil-input ()
  (should-not (metal-butt-response-preview-text nil)))

(ert-deftest metal-butt-response-preview-text-handles-escaped-newline ()
  (should (equal "line one\nline two"
                 (metal-butt-response-preview-text
                  "{\"kind\":\"reply\",\"text\":\"line one\\nline two"))))

