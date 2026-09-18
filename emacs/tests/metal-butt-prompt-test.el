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

(ert-deftest metal-butt-prompt-finds-block-several-lines-above ()
  "Point is usually below the prompt, not on it."
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: refactor this\nint a = 1;\nint b = 2;\n|\n"
    (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                   "refactor this"))))

(ert-deftest metal-butt-prompt-respects-the-search-limit ()
  "A prompt far above point must not be picked up by accident."
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: far away\nx\nx\nx\nx\nx\n|\n"
    (let ((metal-butt-prompt-search-limit 3))
      (should-not (metal-butt-prompt-at-point)))))

(ert-deftest metal-butt-prompt-picks-the-nearest-block ()
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: the far one\nint a = 1;\n// claude: the near one\nint b = 2;\n|\n"
    (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                   "the near one"))))

(ert-deftest metal-butt-prompt-matches-any-configured-word ()
  (let ((metal-butt-attention-words '("claude" "cc" "ai")))
    (dolist (word '("claude" "cc" "ai"))
      (metal-butt-test--with-buffer #'prog-mode
          (format "// %s: do the thing|\n" word)
        (should (equal (plist-get (metal-butt-prompt-at-point) :text)
                       "do the thing"))))))

(ert-deftest metal-butt-prompt-ignores-unconfigured-words ()
  (let ((metal-butt-attention-words '("claude")))
    (metal-butt-test--with-buffer #'prog-mode
        "// cc: not configured|\n"
      (should-not (metal-butt-prompt-at-point)))))

(ert-deftest metal-butt-prompt-aliases-are-case-insensitive ()
  (let ((metal-butt-attention-words '("cc")))
    (metal-butt-test--with-buffer #'prog-mode
        "// CC: shout|\n"
      (should (equal (plist-get (metal-butt-prompt-at-point) :text) "shout")))))

(ert-deftest metal-butt-prompt-empty-word-list-matches-nothing ()
  "An empty list must not turn every comment line into a prompt."
  (let ((metal-butt-attention-words nil))
    (metal-butt-test--with-buffer #'prog-mode
        "// claude: would normally match|\n"
      (should-not (metal-butt-prompt-at-point)))))

(ert-deftest metal-butt-prompt-extracts-a-model-directive ()
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: @opus redesign this|\n"
    (let ((p (metal-butt-prompt-at-point)))
      (should (equal (plist-get p :model) "opus"))
      (should (equal (plist-get p :text) "redesign this")))))

(ert-deftest metal-butt-prompt-without-a-directive-has-no-model ()
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: redesign this|\n"
    (let ((p (metal-butt-prompt-at-point)))
      (should-not (plist-get p :model))
      (should (equal (plist-get p :text) "redesign this")))))

(ert-deftest metal-butt-prompt-at-sign-mid-prompt-is-literal ()
  "Only a directive at the very start counts."
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: fix @foo in the docs|\n"
    (let ((p (metal-butt-prompt-at-point)))
      (should-not (plist-get p :model))
      (should (equal (plist-get p :text) "fix @foo in the docs")))))

(ert-deftest metal-butt-prompt-directive-alone-on-the-first-line ()
  (metal-butt-test--with-buffer #'prog-mode
      "// claude: @haiku\n// and explain briefly|\n"
    (let ((p (metal-butt-prompt-at-point)))
      (should (equal (plist-get p :model) "haiku"))
      (should (equal (plist-get p :text) "and explain briefly")))))
