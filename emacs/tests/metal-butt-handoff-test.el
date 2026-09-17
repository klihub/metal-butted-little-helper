;;; metal-butt-handoff-test.el --- Tests for handoff files  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-handoff)

(defmacro metal-butt-test--with-repo (var &rest body)
  (declare (indent 1))
  `(let ((,var (make-temp-file "metal-butt-test" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest metal-butt-handoff-consume-empty-is-empty-string ()
  (metal-butt-test--with-repo root
    (should (equal "" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-append-then-consume ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "we agreed to use markers\n")
    (should (equal "we agreed to use markers\n"
                   (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-consume-is-idempotent ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "first\n")
    (metal-butt-handoff-consume root 'to-emacs)
    (should (equal "" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-consume-returns-only-the-delta ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "first\n")
    (metal-butt-handoff-consume root 'to-emacs)
    (metal-butt-handoff-append root 'to-emacs "second\n")
    (should (equal "second\n" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-channels-are-independent ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "for emacs\n")
    (metal-butt-handoff-append root 'to-terminal "for terminal\n")
    (should (equal "for emacs\n" (metal-butt-handoff-consume root 'to-emacs)))
    (should (equal "for terminal\n" (metal-butt-handoff-consume root 'to-terminal)))))

(ert-deftest metal-butt-handoff-truncation-rereads-from-zero ()
  "Skipped context is worse than duplicated context."
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "a long first note\n")
    (metal-butt-handoff-consume root 'to-emacs)
    (with-temp-file (metal-butt-handoff-file root 'to-emacs) (insert "tiny\n"))
    (should (equal "tiny\n" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-missing-offsets-rereads-from-zero ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "note\n")
    (metal-butt-handoff-consume root 'to-emacs)
    (delete-file (expand-file-name "offsets" (metal-butt-session-dir root)))
    (should (equal "note\n" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-rejects-unknown-channel ()
  (metal-butt-test--with-repo root
    (should-error (metal-butt-handoff-append root 'nonsense "x"))))
