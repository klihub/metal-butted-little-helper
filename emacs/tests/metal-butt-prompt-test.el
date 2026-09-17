;;; metal-butt-prompt-test.el --- Tests for prompt detection  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-prompt)

(defmacro metal-butt-test--with-buffer (mode contents &rest body)
  "Insert CONTENTS in a temp buffer in MODE, move point to |, run BODY."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,contents)
     (funcall ,mode)
     (goto-char (point-min))
     (when (search-forward "|" nil t)
       (delete-char -1))
     ,@body))

(ert-deftest metal-butt-prompt-detects-double-slash ()
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: extract this into a helper|\n"
    (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                   "extract this into a helper"))))

(ert-deftest metal-butt-prompt-detects-hash-without-space ()
  (metal-butt-test--with-buffer #'prog-mode
      "#claude: same thing, no space|\n"
    (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                   "same thing, no space"))))

(ert-deftest metal-butt-prompt-is-case-insensitive ()
  (metal-butt-test--with-buffer #'prog-mode
      ";; CLAUDE: shout at me|\n"
    (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                   "shout at me"))))

(ert-deftest metal-butt-prompt-joins-continuation-lines ()
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: extract this into a helper\n// and add a test for the empty case|\n"
    (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                   "extract this into a helper\nand add a test for the empty case"))))

(ert-deftest metal-butt-prompt-stops-at-new-attention-word ()
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: first prompt|\n// claude: second prompt\n"
    (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                   "first prompt"))))

(ert-deftest metal-butt-prompt-requires-same-indentation ()
  (metal-butt-test--with-buffer #'prog-mode
      "  // claude: indented prompt|\n// not part of it\n"
    (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                   "indented prompt"))))

(ert-deftest metal-butt-prompt-finds-block-above-point ()
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: fix the loop\nint x = 1;|\n"
    (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                   "fix the loop"))))

(ert-deftest metal-butt-prompt-returns-nil-without-attention-word ()
  (metal-butt-test--with-buffer #'prog-mode
      "// just an ordinary comment|\n"
    (should-not (metal-butt-prompt-at-point))))

(ert-deftest metal-butt-prompt-returns-markers-spanning-block ()
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: one\n// two|\n"
    (let ((p (metal-butt-prompt-at-point)))
      (should (= (marker-position (plist-get p :start)) 1))
      (should (= (marker-position (plist-get p :end)) (point-max))))))

(ert-deftest metal-butt-prompt-strip-line-on-non-comment-is-empty ()
  (with-temp-buffer
    (insert "int x = 1;\n")
    (goto-char (point-min))
    (should (equal "" (metal-butt-prompt--strip-line)))))
