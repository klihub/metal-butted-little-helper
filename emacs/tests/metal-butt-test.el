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

(ert-deftest metal-butt-handle-ignores-a-killed-buffer ()
  "A response arriving after the buffer was killed must not signal."
  (let ((buffer (generate-new-buffer " *metal-butt-dead*")))
    (kill-buffer buffer)
    (should-not (metal-butt--handle buffer nil 0 nil "boom"))))

(ert-deftest metal-butt-send-clears-in-flight-on-launch-failure ()
  "A transport that fails synchronously must not wedge the buffer."
  (metal-butt-test--in-repo
    (insert "// claude: hi\n")
    (let ((metal-butt-transport-function (lambda (&rest _) (error "boom"))))
      (should-error (metal-butt-send-prompt)))
    (should-not metal-butt--in-flight)))

(ert-deftest metal-butt-error-does-not-report-a-stale-cost ()
  "After a failure the mode line must not show the previous prompt's cost."
  (metal-butt-test--in-repo
    (insert "// claude: hi\n")
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"hi\"}"
      (metal-butt-send-prompt))
    (should (> metal-butt--last-cost 0))
    (let ((metal-butt-transport-function
           (lambda (_r _s cb) (funcall cb nil "explicit deny"))))
      (metal-butt-send-prompt))
    (should (= metal-butt--last-cost 0))))

(ert-deftest metal-butt-repo-root-is-fully-resolved ()
  "Two spellings of one directory must not yield two session ids."
  (let* ((real (file-name-as-directory (make-temp-file "mb-real" t)))
         (link (make-temp-name "/tmp/mb-link")))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" real))
          (make-symbolic-link (directory-file-name real) link)
          (let ((via-real (let ((default-directory real))
                            (metal-butt-repo-root)))
                (via-link (let ((default-directory (file-name-as-directory link)))
                            (metal-butt-repo-root))))
            (should (equal via-real via-link))))
      (ignore-errors (delete-file link))
      (delete-directory real t))))

(ert-deftest metal-butt-handoff-survives-a-failed-request ()
  "A failed request must not swallow the terminal session's note."
  (metal-butt-test--in-repo
    (metal-butt-handoff-append root 'to-emacs "important context")
    (insert "// claude: hi\n")
    (let ((metal-butt-transport-function
           (lambda (_r _s cb) (funcall cb nil "boom"))))
      (metal-butt-send-prompt))
    (should (string-match-p "important context"
                            (car (metal-butt-handoff-peek root 'to-emacs))))))

(ert-deftest metal-butt-handoff-is-consumed-after-a-successful-request ()
  (metal-butt-test--in-repo
    (metal-butt-handoff-append root 'to-emacs "important context")
    (insert "// claude: hi\n")
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"ok\"}"
      (metal-butt-send-prompt))
    (should (equal "" (car (metal-butt-handoff-peek root 'to-emacs))))))

(ert-deftest metal-butt-effective-model-precedence ()
  (with-temp-buffer
    (let ((metal-butt-model "sonnet"))
      (should (equal (metal-butt-effective-model) "sonnet"))
      (setq-local metal-butt--buffer-model "haiku")
      (should (equal (metal-butt-effective-model) "haiku"))
      (should (equal (metal-butt-effective-model "opus") "opus")))))

(ert-deftest metal-butt-effective-model-falls-back-to-the-backend-default ()
  "With no explicit override, each backend supplies its own default model."
  (with-temp-buffer
    (let ((metal-butt-model nil)
          (metal-butt-backend 'claude)
          (metal-butt-claude-model "sonnet")
          (metal-butt-copilot-model "claude-sonnet-5"))
      (should (equal (metal-butt-effective-model) "sonnet"))
      (setq metal-butt-backend 'copilot)
      (should (equal (metal-butt-effective-model) "claude-sonnet-5")))))

(ert-deftest metal-butt-set-model-buffer-only-leaves-the-global-alone ()
  (with-temp-buffer
    (let ((metal-butt-model "sonnet"))
      (metal-butt-set-model "haiku" t)
      (should (equal metal-butt--buffer-model "haiku"))
      (should (equal metal-butt-model "sonnet")))))

(ert-deftest metal-butt-send-rejects-an-unknown-model-without-calling-out ()
  "A typo must fail before any request is made, and must not wedge the buffer."
  (metal-butt-test--in-repo
    (insert "// claude: @opuss do it\n")
    (let ((called nil))
      (let ((metal-butt-transport-function
             (lambda (&rest _) (setq called t))))
        (should-error (metal-butt-send-prompt)))
      (should-not called)
      (should-not metal-butt--in-flight))))

(ert-deftest metal-butt-backend-label-names-the-active-backend ()
  (let ((metal-butt-backend 'claude))
    (should (equal "Claude" (metal-butt-backend-label))))
  (let ((metal-butt-backend 'copilot))
    (should (equal "Copilot" (metal-butt-backend-label))))
  (let ((metal-butt-backend 'copilot-api))
    (should (equal "Copilot (API)" (metal-butt-backend-label)))))

(ert-deftest metal-butt-ask-shows-a-reply-in-a-window ()
  "The code buffer must not be touched by a question."
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (let ((before (buffer-string)))
      (metal-butt-test--with-stub
          "{\"kind\":\"reply\",\"text\":\"because api.go passes nil\"}"
        (metal-butt-ask "why is this nil?"))
      (should (equal before (buffer-string)))
      (should (with-current-buffer "*metal-butt-reply*"
                (string-match-p "api.go passes nil" (buffer-string)))))))

(ert-deftest metal-butt-ask-still-proposes-edits-as-overlays ()
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (metal-butt-test--with-stub
        "{\"kind\":\"edit\",\"edits\":[{\"old\":\"int x\",\"new\":\"int count\"}]}"
      (metal-butt-ask "rename x"))
    (should (metal-butt-overlay-pending-p))
    (should (string-match-p "int x = 1;" (buffer-string)))))

(ert-deftest metal-butt-ask-parses-a-model-directive ()
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (let (seen)
      (let ((metal-butt-transport-function
             (lambda (_r _s cb)
               (setq seen metal-butt-model)
               (funcall cb (list :text "{\"kind\":\"reply\",\"text\":\"ok\"}"
                                 :cost 0 :input-tokens 0)
                        nil))))
        (metal-butt-ask "@opus explain this"))
      (should (equal seen "opus")))))

(ert-deftest metal-butt-ask-rejects-an-empty-prompt ()
  (metal-butt-test--in-repo
    (let ((called nil))
      (let ((metal-butt-transport-function (lambda (&rest _) (setq called t))))
        (should-error (metal-butt-ask "   ")))
      (should-not called))))

(ert-deftest metal-butt-ask-reply-survives-a-mid-flight-edit ()
  "A window reply modifies nothing, so typing must not throw it away."
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (let ((saved nil))
      (let ((metal-butt-transport-function (lambda (_r _s cb) (setq saved cb))))
        (metal-butt-ask "why?"))
      (insert "int y = 2;\n")
      (funcall saved (list :text "{\"kind\":\"reply\",\"text\":\"late but shown\"}"
                           :cost 0 :input-tokens 0)
               nil)
      (should (with-current-buffer "*metal-butt-reply*"
                (string-match-p "late but shown" (buffer-string)))))))

(ert-deftest metal-butt-ask-followup-errors-without-a-prior-ask ()
  (metal-butt-test--in-repo
    (should-error (metal-butt-ask-followup "and then?"))))

(ert-deftest metal-butt-ask-followup-sends-prior-turn-as-history ()
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"first answer\"}"
      (metal-butt-ask "first question?"))
    (let ((seen-request nil))
      (let ((metal-butt-transport-function
             (lambda (request _session-id callback)
               (setq seen-request request)
               (funcall callback (list :text "{\"kind\":\"reply\",\"text\":\"second answer\"}"
                                       :cost 0 :input-tokens 0)
                        nil))))
        (metal-butt-ask-followup "second question?"))
      (should (string-match-p "first question?" seen-request))
      (should (string-match-p "first answer" seen-request))
      (should (with-current-buffer "*metal-butt-reply*"
                (string-match-p "second answer" (buffer-string)))))))

(ert-deftest metal-butt-ask-followup-chains-across-multiple-turns ()
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"answer one\"}"
      (metal-butt-ask "question one?"))
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"answer two\"}"
      (metal-butt-ask-followup "question two?"))
    (let ((seen-request nil))
      (let ((metal-butt-transport-function
             (lambda (request _session-id callback)
               (setq seen-request request)
               (funcall callback (list :text "{\"kind\":\"reply\",\"text\":\"answer three\"}"
                                       :cost 0 :input-tokens 0)
                        nil))))
        (metal-butt-ask-followup "question three?"))
      (should (string-match-p "question one?" seen-request))
      (should (string-match-p "question two?" seen-request)))))

(ert-deftest metal-butt-ask-resets-the-conversation ()
  "A fresh `metal-butt-ask' must not carry over an old conversation."
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"answer one\"}"
      (metal-butt-ask "question one?"))
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"answer two\"}"
      (metal-butt-ask "question two?"))
    (let ((seen-request nil))
      (let ((metal-butt-transport-function
             (lambda (request _session-id callback)
               (setq seen-request request)
               (funcall callback (list :text "{\"kind\":\"reply\",\"text\":\"answer three\"}"
                                       :cost 0 :input-tokens 0)
                        nil))))
        (metal-butt-ask-followup "question three?"))
      (should-not (string-match-p "question one?" seen-request))
      (should (string-match-p "question two?" seen-request)))))

(ert-deftest metal-butt-explain-region-errors-without-a-region ()
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (should-error (metal-butt-explain-region))))

(ert-deftest metal-butt-explain-region-sends-the-canned-question ()
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (goto-char (point-min))
    (push-mark (point) t t)
    (activate-mark)
    (goto-char (point-max))
    (let ((seen-request nil))
      (let ((metal-butt-transport-function
             (lambda (request _session-id callback)
               (setq seen-request request)
               (funcall callback (list :text "{\"kind\":\"reply\",\"text\":\"it declares x\"}"
                                       :cost 0 :input-tokens 0)
                        nil))))
        (metal-butt-explain-region))
      (should (string-match-p (regexp-quote metal-butt-explain-region-prompt) seen-request))
      (should (string-match-p "## Selected region" seen-request)))))

(ert-deftest metal-butt-explain-region-does-not-touch-the-buffer ()
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (goto-char (point-min))
    (push-mark (point) t t)
    (activate-mark)
    (goto-char (point-max))
    (let ((before (buffer-string)))
      (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"it declares x\"}"
        (metal-butt-explain-region))
      (should (equal before (buffer-string)))
      (should (with-current-buffer "*metal-butt-reply*"
                (string-match-p "it declares x" (buffer-string)))))))

(ert-deftest metal-butt-explain-region-resets-the-conversation ()
  "Like `metal-butt-ask', a fresh call must not carry over an old conversation."
  (metal-butt-test--in-repo
    (insert "int x = 1;\n")
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"answer one\"}"
      (metal-butt-ask "question one?"))
    (goto-char (point-min))
    (push-mark (point) t t)
    (activate-mark)
    (goto-char (point-max))
    (metal-butt-test--with-stub "{\"kind\":\"reply\",\"text\":\"answer two\"}"
      (metal-butt-explain-region))
    (let ((seen-request nil))
      (let ((metal-butt-transport-function
             (lambda (request _session-id callback)
               (setq seen-request request)
               (funcall callback (list :text "{\"kind\":\"reply\",\"text\":\"answer three\"}"
                                       :cost 0 :input-tokens 0)
                        nil))))
        (metal-butt-ask-followup "question three?"))
      (should-not (string-match-p "question one?" seen-request)))))

(ert-deftest metal-butt-show-reply-wraps-long-lines ()
  "Replies are prose, not code; without visual-line-mode a long answer runs
off the window edge instead of wrapping, which is what prompted this test."
  (metal-butt--show-reply "some reply text")
  (should (with-current-buffer "*metal-butt-reply*"
            visual-line-mode)))

(ert-deftest metal-butt-mode-binds-every-command ()
  "Bindings live at top level so a reload installs them; guard all five."
  (dolist (pair '(("C-c b" . metal-butt-send-prompt)
                  ("C-c p" . metal-butt-ask)
                  ("C-c e" . metal-butt-explain-region)
                  ("C-c C-a" . metal-butt-accept)
                  ("C-c C-r" . metal-butt-reject)
                  ("C-c m" . metal-butt-set-model)))
    (should (eq (lookup-key metal-butt-mode-map (kbd (car pair))) (cdr pair)))))

(ert-deftest metal-butt-mode-map-survives-a-reload ()
  "Reloading must not wipe a key the user added, and must install ours."
  (define-key metal-butt-mode-map (kbd "C-c z") #'ignore)
  (load "metal-butt")
  (should (eq (lookup-key metal-butt-mode-map (kbd "C-c z")) #'ignore))
  (should (eq (lookup-key metal-butt-mode-map (kbd "C-c p")) #'metal-butt-ask))
  (define-key metal-butt-mode-map (kbd "C-c z") nil))

(ert-deftest metal-butt-reload-refreshes-every-module ()
  "Reloading only the entry point leaves the other modules stale."
  (should (equal (car (last metal-butt--modules)) "metal-butt"))
  (dolist (m metal-butt--modules)
    (should (locate-library m)))
  (metal-butt-reload)
  (should (fboundp 'metal-butt-prompt--extract-model))
  (should (fboundp 'metal-butt-handoff-peek))
  (should (fboundp 'metal-butt-response--escape-raw-controls)))

(ert-deftest metal-butt-reload-list-covers-every-file ()
  "A module added without listing it would be left stale by every reload."
  (let* ((dir (file-name-directory (locate-library "metal-butt")))
         (on-disk (sort (mapcar #'file-name-base
                                (directory-files dir nil "\\`metal-butt.*\\.el\\'"))
                        #'string<)))
    (should (equal on-disk (sort (copy-sequence metal-butt--modules) #'string<)))))
