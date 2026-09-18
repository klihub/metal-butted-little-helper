;;; metal-butt-context-test.el --- Tests for context assembly  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-context)

(defmacro metal-butt-test--with-repo (var &rest body)
  (declare (indent 1))
  `(let ((,var (make-temp-file "metal-butt-test" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest metal-butt-context-includes-prompt ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (insert "int x = 1;\n")
      (should (string-match-p "fix the loop"
                              (metal-butt-context-build "fix the loop" root))))))

(ert-deftest metal-butt-context-includes-buffer-contents ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (insert "int unique_marker = 1;\n")
      (should (string-match-p "unique_marker"
                              (metal-butt-context-build "p" root))))))

(ert-deftest metal-butt-context-includes-major-mode ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (emacs-lisp-mode)
      (should (string-match-p "emacs-lisp-mode"
                              (metal-butt-context-build "p" root))))))

(ert-deftest metal-butt-context-includes-handoff-delta ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (should (string-match-p "markers over line numbers"
                              (metal-butt-context-build
                               "p" root "we chose markers over line numbers"))))))

(ert-deftest metal-butt-context-omits-handoff-section-when-empty ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (should-not (string-match-p "Context handed over"
                                  (metal-butt-context-build "p" root nil))))))

(ert-deftest metal-butt-context-includes-history-when-given ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (let ((request (metal-butt-context-build
                      "p" root nil '(("first q?" . "first a.")))))
        (should (string-match-p "first q?" request))
        (should (string-match-p "first a\\." request))))))

(ert-deftest metal-butt-context-omits-history-section-when-nil ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (should-not (string-match-p "Earlier turns"
                                  (metal-butt-context-build "p" root nil nil))))))

(ert-deftest metal-butt-context-truncates-large-buffers ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (insert (make-string 1000 ?a))
      (goto-char (point-max))
      (let ((metal-butt-max-buffer-chars 100))
        (let ((ctx (metal-butt-context-build "p" root)))
          (should (string-match-p "truncated" ctx))
          (should (< (length ctx) 600)))))))

(ert-deftest metal-butt-context-includes-region-when-active ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (insert "alpha\nbeta\ngamma\n")
      (goto-char (point-min))
      (set-mark (point))
      (forward-line 1)
      (let ((transient-mark-mode t))
        (let ((ctx (metal-butt-context-build "p" root)))
          (should (string-match-p "Selected region" ctx)))))))
