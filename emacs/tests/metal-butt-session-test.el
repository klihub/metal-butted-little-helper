;;; metal-butt-session-test.el --- Tests for session identity  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-session)

(defmacro metal-butt-test--with-repo (var &rest body)
  "Bind VAR to a fresh temporary repo root, run BODY, then delete it."
  (declare (indent 1))
  `(let ((,var (make-temp-file "metal-butt-test" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest metal-butt-session-uuid-is-well-formed ()
  (should (string-match-p
           "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-5[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'"
           (metal-butt-session-uuid "/tmp/repo" 0))))

(ert-deftest metal-butt-session-uuid-is-deterministic ()
  (should (equal (metal-butt-session-uuid "/tmp/repo" 0)
                 (metal-butt-session-uuid "/tmp/repo" 0))))

(ert-deftest metal-butt-session-uuid-varies-by-generation ()
  (should-not (equal (metal-butt-session-uuid "/tmp/repo" 0)
                     (metal-butt-session-uuid "/tmp/repo" 1))))

(ert-deftest metal-butt-session-uuid-varies-by-repo ()
  (should-not (equal (metal-butt-session-uuid "/tmp/a" 0)
                     (metal-butt-session-uuid "/tmp/b" 0))))

(ert-deftest metal-butt-session-generation-defaults-to-zero ()
  (metal-butt-test--with-repo root
    (should (= 0 (metal-butt-session-generation root)))))

(ert-deftest metal-butt-session-bump-persists ()
  (metal-butt-test--with-repo root
    (should (= 1 (metal-butt-session-bump-generation root)))
    (should (= 1 (metal-butt-session-generation root)))
    (should (= 2 (metal-butt-session-bump-generation root)))))

(ert-deftest metal-butt-session-corrupt-state-resets-to-zero ()
  (metal-butt-test--with-repo root
    (make-directory (metal-butt-session-dir root) t)
    (with-temp-file (expand-file-name "state" (metal-butt-session-dir root))
      (insert "not a number"))
    (should (= 0 (metal-butt-session-generation root)))))

(ert-deftest metal-butt-session-current-id-tracks-generation ()
  (metal-butt-test--with-repo root
    (let ((first (metal-butt-session-current-id root)))
      (metal-butt-session-bump-generation root)
      (should-not (equal first (metal-butt-session-current-id root))))))
