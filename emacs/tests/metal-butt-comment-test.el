;;; metal-butt-comment-test.el --- Tests for reply insertion  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-comment)

(ert-deftest metal-butt-comment-inserts-in-elisp-syntax ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun f ())\n")
    (metal-butt-comment-insert "callers pass nil" (point-max))
    (should (string-match-p "^;+ *callers pass nil" (buffer-string)))))

(ert-deftest metal-butt-comment-inserts-in-shell-syntax ()
  (with-temp-buffer
    (sh-mode)
    (insert "echo hi\n")
    (metal-butt-comment-insert "quote that" (point-max))
    (should (string-match-p "^# *quote that" (buffer-string)))))

(ert-deftest metal-butt-comment-comments-every-line ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (metal-butt-comment-insert "first\nsecond" (point-max))
    (let ((lines (seq-filter (lambda (l) (not (string-empty-p l)))
                             (split-string (buffer-string) "\n"))))
      (should (= 2 (length lines)))
      (should (seq-every-p (lambda (l) (string-prefix-p ";" (string-trim-left l)))
                          lines)))))

(ert-deftest metal-butt-comment-does-not-disturb-existing-text ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun f ())\n")
    (metal-butt-comment-insert "note" (point-max))
    (should (string-prefix-p "(defun f ())\n" (buffer-string)))))

(ert-deftest metal-butt-comment-returns-end-position ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (should (> (metal-butt-comment-insert "note" (point-max)) 1))))
