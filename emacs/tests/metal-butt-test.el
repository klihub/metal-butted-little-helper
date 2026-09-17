;;; metal-butt-test.el --- End-to-end tests with a stub transport  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt)

(defmacro metal-butt-test--with-stub (response &rest body)
  "Run BODY with the transport stubbed to return RESPONSE as the result text."
  (declare (indent 1))
  `(let ((metal-butt-transport-function
          (lambda (_request _session-id callback)
            (funcall callback (list :text ,response :cost 0.004 :input-tokens 100) nil))))
     ,@body))

(defmacro metal-butt-test--in-repo (&rest body)
  "Run BODY in a temp buffer whose repo root is a temp directory."
  (declare (indent 0))
  `(let ((root (make-temp-file "metal-butt-test" t)))
     (unwind-protect
         (cl-letf (((symbol-function 'metal-butt-repo-root) (lambda () root)))
           (with-temp-buffer
             (prog-mode)
             ;; `prog-mode' leaves `comment-start' nil, which would make
             ;; `comment-region' fail on the reply path.  Give it a syntax.
             (setq-local comment-start "//")
             ,@body))
       (delete-directory root t))))

(ert-deftest metal-butt-send-applies-reply-as-comment ()
  (metal-butt-test--in-repo
    (insert "// claude: is this safe?\n")
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"callers pass nil\"}"
      (metal-butt-send-prompt))
    (should (string-match-p "callers pass nil" (buffer-string)))))

(ert-deftest metal-butt-send-proposes-edit-without-applying-it ()
  (metal-butt-test--in-repo
    (insert "// claude: rename it\nint x = 1;\n")
    (metal-butt-test--with-stub
        "{\"kind\":\"edit\",\"edits\":[{\"old\":\"int x\",\"new\":\"int count\"}]}"
      (metal-butt-send-prompt))
    (should (metal-butt-overlay-pending-p))
    (should (string-match-p "int x = 1;" (buffer-string)))))

(ert-deftest metal-butt-send-records-cost ()
  (metal-butt-test--in-repo
    (insert "// claude: hi\n")
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"hi\"}"
      (metal-butt-send-prompt))
    (should (= metal-butt--last-cost 0.004))))

(ert-deftest metal-butt-send-without-prompt-block-errors ()
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (should-error (metal-butt-send-prompt))))

(ert-deftest metal-butt-send-refuses-while-a-request-is-in-flight ()
  (metal-butt-test--in-repo
    (insert "// claude: one\n")
    (let ((metal-butt-transport-function (lambda (&rest _) nil)))  ; never calls back
      (metal-butt-send-prompt)
      (should-error (metal-butt-send-prompt)))))

(ert-deftest metal-butt-send-refuses-a-stale-response ()
  "A response computed against text the user has since changed must not apply."
  (metal-butt-test--in-repo
    (insert "// claude: rename it\nint x = 1;\n")
    (let* ((saved nil)
           (metal-butt-transport-function
            (lambda (_r _s callback) (setq saved callback))))
      (metal-butt-send-prompt)
      (goto-char (point-max))
      (insert "int y = 2;\n")          ; user keeps typing
      (funcall saved (list :text "{\"kind\":\"reply\",\"text\":\"late\"}"
                           :cost 0 :input-tokens 1)
               nil)
      (should-not (string-match-p "late" (buffer-string))))))

(ert-deftest metal-butt-send-reports-transport-errors ()
  (metal-butt-test--in-repo
    (insert "// claude: hi\n")
    (let ((metal-butt-transport-function
           (lambda (_r _s callback) (funcall callback nil "explicit deny"))))
      (metal-butt-send-prompt)
      (should-not (metal-butt-overlay-pending-p)))))

(ert-deftest metal-butt-mode-binds-c-c-b ()
  (should (eq (lookup-key metal-butt-mode-map (kbd "C-c b"))
              'metal-butt-send-prompt)))

(ert-deftest metal-butt-mode-does-not-bind-c-c-c-c ()
  "C-c C-c is comment-region in c-mode and send-buffer in python-mode."
  (should-not (lookup-key metal-butt-mode-map (kbd "C-c C-c"))))
