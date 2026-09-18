;;; metal-butt-overlay-test.el --- Tests for edit overlays  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-overlay)

(ert-deftest metal-butt-overlay-locates-unique-match ()
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (should (= (metal-butt-overlay-locate "beta") 7))))

(ert-deftest metal-butt-overlay-rejects-missing-match ()
  (with-temp-buffer
    (insert "alpha\n")
    (should-error (metal-butt-overlay-locate "zeta")
                  :type 'metal-butt-overlay-no-match)))

(ert-deftest metal-butt-overlay-rejects-ambiguous-match ()
  "Never guess which occurrence was meant."
  (with-temp-buffer
    (insert "dup\ndup\n")
    (should-error (metal-butt-overlay-locate "dup")
                  :type 'metal-butt-overlay-ambiguous)))

(ert-deftest metal-butt-overlay-accept-replaces-text ()
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (metal-butt-overlay-propose '(:old "beta" :new "BETA" :why "louder"))
    (metal-butt-accept)
    (should (equal (buffer-string) "alpha\nBETA\ngamma\n"))))

(ert-deftest metal-butt-overlay-reject-leaves-buffer-untouched ()
  (with-temp-buffer
    (insert "alpha\nbeta\n")
    (metal-butt-overlay-propose '(:old "beta" :new "BETA"))
    (metal-butt-reject)
    (should (equal (buffer-string) "alpha\nbeta\n"))))

(ert-deftest metal-butt-overlay-reject-clears-pending-state ()
  (with-temp-buffer
    (insert "alpha\n")
    (metal-butt-overlay-propose '(:old "alpha" :new "ALPHA"))
    (should (metal-butt-overlay-pending-p))
    (metal-butt-reject)
    (should-not (metal-butt-overlay-pending-p))))

(ert-deftest metal-butt-overlay-accept-applies-edits-in-sequence ()
  (with-temp-buffer
    (insert "one\ntwo\n")
    (metal-butt-overlay-propose-all
     '((:old "one" :new "1") (:old "two" :new "2")))
    (metal-butt-accept)
    (metal-butt-accept)
    (should (equal (buffer-string) "1\n2\n"))))

(ert-deftest metal-butt-overlay-accept-without-proposal-is-an-error ()
  (with-temp-buffer
    (should-error (metal-butt-accept))))

(ert-deftest metal-butt-overlay-skips-a-stale-first-edit ()
  "An edit that no longer matches must not block the edits behind it."
  (with-temp-buffer
    (insert "alpha\nbeta\n")
    (metal-butt-overlay-propose-all
     '((:old "nonexistent" :new "x") (:old "beta" :new "BETA")))
    (should (metal-butt-overlay-pending-p))
    (metal-butt-accept)
    (should (equal (buffer-string) "alpha\nBETA\n"))))

(ert-deftest metal-butt-overlay-queue-survives-a-stale-later-edit ()
  "Applying edit 1 must not strand edit 3 when edit 2 has gone stale."
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (metal-butt-overlay-propose-all
     '((:old "one" :new "1") (:old "vanished" :new "x") (:old "three" :new "3")))
    (metal-butt-accept)
    (should (metal-butt-overlay-pending-p))
    (metal-butt-accept)
    (should (equal (buffer-string) "1\ntwo\n3\n"))
    (should-not (metal-butt-overlay-pending-p))))

(ert-deftest metal-butt-overlay-defaults-to-full-style ()
  (let ((metal-butt-overlay-diff-style 'full))
    (with-temp-buffer
      (insert "alpha\n")
      (metal-butt-overlay-propose '(:old "alpha" :new "ALPHA"))
      (should (eq (metal-butt-overlay--style) 'full))
      (should-not (overlay-get metal-butt-overlay--overlay 'display))
      (should (string-match-p "→ ALPHA"
                              (overlay-get metal-butt-overlay--overlay 'after-string))))))

(ert-deftest metal-butt-overlay-honours-diff-style-default ()
  (let ((metal-butt-overlay-diff-style 'diff))
    (with-temp-buffer
      (insert "alpha\n")
      (metal-butt-overlay-propose '(:old "alpha" :new "ALPHA"))
      (should (eq (metal-butt-overlay--style) 'diff))
      (should (overlay-get metal-butt-overlay--overlay 'display))
      (should (string-match-p "\\+ALPHA"
                              (overlay-get metal-butt-overlay--overlay 'after-string))))))

(ert-deftest metal-butt-overlay-toggle-style-switches-live ()
  (let ((metal-butt-overlay-diff-style 'full))
    (with-temp-buffer
      (insert "alpha\n")
      (metal-butt-overlay-propose '(:old "alpha" :new "ALPHA"))
      (metal-butt-overlay-toggle-style)
      (should (eq (metal-butt-overlay--style) 'diff))
      (should (overlay-get metal-butt-overlay--overlay 'display))
      (metal-butt-overlay-toggle-style)
      (should (eq (metal-butt-overlay--style) 'full))
      (should-not (overlay-get metal-butt-overlay--overlay 'display)))))

(ert-deftest metal-butt-overlay-toggle-style-does-not-touch-the-buffer ()
  (with-temp-buffer
    (insert "alpha\n")
    (metal-butt-overlay-propose '(:old "alpha" :new "ALPHA"))
    (metal-butt-overlay-toggle-style)
    (should (equal (buffer-string) "alpha\n"))))

(ert-deftest metal-butt-overlay-toggle-style-errors-without-a-proposal ()
  (with-temp-buffer
    (should-error (metal-butt-overlay-toggle-style))))

(ert-deftest metal-butt-overlay-toggle-style-resets-for-the-next-edit ()
  "A one-off toggle on edit 1 must not leak onto edit 2."
  (let ((metal-butt-overlay-diff-style 'full))
    (with-temp-buffer
      (insert "one\ntwo\n")
      (metal-butt-overlay-propose-all '((:old "one" :new "1") (:old "two" :new "2")))
      (metal-butt-overlay-toggle-style)
      (should (eq (metal-butt-overlay--style) 'diff))
      (metal-butt-accept)
      (should (eq (metal-butt-overlay--style) 'full)))))
