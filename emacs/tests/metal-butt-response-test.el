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
