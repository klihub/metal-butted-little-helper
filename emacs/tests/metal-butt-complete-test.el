;;; metal-butt-complete-test.el --- Tests for point completion  -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'metal-butt)

(defmacro metal-butt-complete-test--with-stub (response &rest body)
  "Run BODY with `metal-butt-transport-copilot-api-send-messages' stubbed to
call back with RESPONSE as the result text, recording the MESSAGES it was
called with in `sent-messages'."
  (declare (indent 1))
  `(let (sent-messages)
     (cl-letf (((symbol-function 'metal-butt-transport-copilot-api-send-messages)
                (lambda (messages callback &optional _progress)
                  (setq sent-messages messages)
                  (funcall callback (list :text ,response :cost 0 :input-tokens 50) nil))))
       ,@body)))

(defmacro metal-butt-complete-test--in-buffer (&rest body)
  "Run BODY in a temp buffer configured for the `copilot-api' backend."
  (declare (indent 0))
  `(with-temp-buffer
     (let ((metal-butt-backend 'copilot-api))
       ,@body)))

;; -- metal-butt-complete--diff-text --------------------------------------

(ert-deftest metal-butt-complete-diff-text-empty-when-unchanged ()
  (should (string-empty-p (metal-butt-complete--diff-text "a\nb\nc\n" "a\nb\nc\n"))))

(ert-deftest metal-butt-complete-diff-text-shows-a-changed-line ()
  (let ((diff (metal-butt-complete--diff-text "one\ntwo\nthree\n" "one\nTWO\nthree\n")))
    (should (string-match-p "^-two$" diff))
    (should (string-match-p "^\\+TWO$" diff))
    (should (string-match-p "^@@ " diff))))

(ert-deftest metal-butt-complete-diff-text-handles-pure-insertion ()
  (let ((diff (metal-butt-complete--diff-text "one\ntwo\n" "one\ntwo\nthree\n")))
    (should (string-match-p "^\\+three$" diff))
    (should-not (string-match-p "^-" diff))))

;; -- metal-butt-complete--build-user-message -----------------------------

(ert-deftest metal-butt-complete-build-message-sends-whole-buffer-first-turn ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (let ((turn (metal-butt-complete--build-user-message nil)))
      (should (string-match-p "## Buffer\n" (alist-get 'content (plist-get turn :message))))
      (should (string-match-p "int x = 1;" (alist-get 'content (plist-get turn :message))))
      (should (equal "int x = 1;\n" (plist-get turn :text))))))

(ert-deftest metal-butt-complete-build-message-sends-a-diff-later ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (let ((turn (metal-butt-complete--build-user-message "int x = 0;\n")))
      (should (string-match-p "changed since your last turn"
                              (alist-get 'content (plist-get turn :message))))
      (should (string-match-p "-int x = 0;" (alist-get 'content (plist-get turn :message))))
      (should (string-match-p "\\+int x = 1;" (alist-get 'content (plist-get turn :message)))))))

(ert-deftest metal-butt-complete-build-message-notes-no-changes ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (let ((turn (metal-butt-complete--build-user-message "int x = 1;\n")))
      (should (string-match-p "No changes since your last turn"
                              (alist-get 'content (plist-get turn :message)))))))

;; -- metal-butt-complete--ensure-session ---------------------------------

(ert-deftest metal-butt-complete-ensure-session-creates-the-system-message ()
  (metal-butt-complete-test--in-buffer
    (metal-butt-complete--ensure-session)
    (should (= 1 (length metal-butt-complete--messages)))
    (should (equal "system" (alist-get 'role (car metal-butt-complete--messages))))))

(ert-deftest metal-butt-complete-ensure-session-resyncs-past-the-turn-cap ()
  (metal-butt-complete-test--in-buffer
    (let ((metal-butt-complete-max-turns 3))
      (metal-butt-complete--ensure-session)
      (setq metal-butt-complete--messages
            (append metal-butt-complete--messages '(((role . "user") (content . "x"))))
            metal-butt-complete--turns 3
            metal-butt-complete--synced-text "old")
      (metal-butt-complete--ensure-session)
      (should (= 1 (length metal-butt-complete--messages)))
      (should (null metal-butt-complete--synced-text))
      (should (= 0 metal-butt-complete--turns)))))

(ert-deftest metal-butt-complete-ensure-session-resyncs-past-the-byte-cap ()
  (metal-butt-complete-test--in-buffer
    (let ((metal-butt-complete-max-history-chars 10))
      (metal-butt-complete--ensure-session)
      (setq metal-butt-complete--messages
            (append metal-butt-complete--messages
                    (list `((role . "user") (content . ,(make-string 100 ?x)))))
            metal-butt-complete--synced-text "old")
      (metal-butt-complete--ensure-session)
      (should (= 1 (length metal-butt-complete--messages)))
      (should (null metal-butt-complete--synced-text)))))

;; -- metal-butt-complete-at-point -----------------------------------------

(ert-deftest metal-butt-complete-at-point-refuses-non-copilot-api-backend ()
  (with-temp-buffer
    (let ((metal-butt-backend 'claude))
      (should-error (metal-butt-complete-at-point)))))

(ert-deftest metal-butt-complete-at-point-refuses-while-in-flight ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (cl-letf (((symbol-function 'metal-butt-transport-copilot-api-send-messages)
               (lambda (&rest _) nil)))  ; never calls back
      (metal-butt-complete-at-point)
      (should-error (metal-butt-complete-at-point)))))

(ert-deftest metal-butt-complete-at-point-sends-the-system-message-and-a-user-turn ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (metal-butt-complete-test--with-stub "{\"kind\":\"reply\",\"text\":\"nothing to add\"}"
      (metal-butt-complete-at-point)
      (should (= 2 (length sent-messages)))
      (should (equal "system" (alist-get 'role (elt sent-messages 0))))
      (should (equal "user" (alist-get 'role (elt sent-messages 1)))))))

(ert-deftest metal-butt-complete-at-point-proposes-an-edit-for-review ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (metal-butt-complete-test--with-stub
        "{\"kind\":\"edit\",\"edits\":[{\"old\":\"int x = 1;\",\"new\":\"int x = 1;\\nint y = 2;\"}]}"
      (metal-butt-complete-at-point))
    (should (metal-butt-overlay-pending-p))))

(ert-deftest metal-butt-complete-at-point-records-history-after-success ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (metal-butt-complete-test--with-stub "{\"kind\":\"reply\",\"text\":\"nothing to add\"}"
      (metal-butt-complete-at-point))
    ;; system + user + assistant
    (should (= 3 (length metal-butt-complete--messages)))
    (should (equal "assistant" (alist-get 'role (car (last metal-butt-complete--messages)))))
    (should (equal "int x = 1;\n" metal-butt-complete--synced-text))
    (should (= 1 metal-butt-complete--turns))))

(ert-deftest metal-butt-complete-at-point-clears-in-flight-after-success ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (metal-butt-complete-test--with-stub "{\"kind\":\"reply\",\"text\":\"nothing to add\"}"
      (metal-butt-complete-at-point))
    (should-not metal-butt--in-flight)))

(ert-deftest metal-butt-complete-at-point-discards-a-stale-response ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (cl-letf (((symbol-function 'metal-butt-transport-copilot-api-send-messages)
               (lambda (_messages callback &optional _progress)
                 ;; The buffer changes before the callback fires.
                 (insert "more\n")
                 (funcall callback (list :text "{\"kind\":\"reply\",\"text\":\"hi\"}"
                                         :cost 0 :input-tokens 5)
                          nil))))
      (metal-butt-complete-at-point))
    (should-not metal-butt--in-flight)
    (should (null metal-butt-complete--synced-text))
    (should (= 0 metal-butt-complete--turns))))

(ert-deftest metal-butt-complete-at-point-reports-an-error ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (cl-letf (((symbol-function 'metal-butt-transport-copilot-api-send-messages)
               (lambda (_messages callback &optional _progress)
                 (funcall callback nil "boom"))))
      (metal-butt-complete-at-point))
    (should-not metal-butt--in-flight)
    (should (null metal-butt-complete--synced-text))))

;; -- metal-butt-toggle-autocomplete ---------------------------------------

(defmacro metal-butt-complete-test--cancel-timer (&rest body)
  "Run BODY, then cancel any autocomplete timer it left armed.
Keeps a failed assertion from leaking a real, running idle timer into
later tests."
  (declare (indent 0))
  `(unwind-protect (progn ,@body)
     (when metal-butt-complete--autocomplete-timer
       (cancel-timer metal-butt-complete--autocomplete-timer))))

(ert-deftest metal-butt-toggle-autocomplete-refuses-non-copilot-api-backend ()
  (with-temp-buffer
    (let ((metal-butt-backend 'claude))
      (should-error (metal-butt-toggle-autocomplete))
      (should-not metal-butt-complete--autocomplete-enabled))))

(ert-deftest metal-butt-toggle-autocomplete-toggles-on-and-off ()
  (metal-butt-complete-test--in-buffer
    (metal-butt-complete-test--cancel-timer
      (metal-butt-toggle-autocomplete)
      (should metal-butt-complete--autocomplete-enabled)
      (should (memq #'metal-butt-complete--post-command post-command-hook))
      (metal-butt-toggle-autocomplete)
      (should-not metal-butt-complete--autocomplete-enabled)
      (should-not (memq #'metal-butt-complete--post-command post-command-hook)))))

(ert-deftest metal-butt-toggle-autocomplete-off-works-regardless-of-backend ()
  (metal-butt-complete-test--in-buffer
    (metal-butt-toggle-autocomplete)
    (setq metal-butt-backend 'claude)
    (metal-butt-toggle-autocomplete)
    (should-not metal-butt-complete--autocomplete-enabled)))

(ert-deftest metal-butt-toggle-autocomplete-off-cancels-a-pending-timer ()
  (metal-butt-complete-test--in-buffer
    (metal-butt-toggle-autocomplete)
    (insert "x")
    (metal-butt-complete--post-command)
    (should (timerp metal-butt-complete--autocomplete-timer))
    (metal-butt-toggle-autocomplete)
    (should (null metal-butt-complete--autocomplete-timer))))

(ert-deftest metal-butt-complete-post-command-arms-a-timer-on-a-real-edit ()
  (metal-butt-complete-test--in-buffer
    (metal-butt-complete-test--cancel-timer
      (metal-butt-toggle-autocomplete)
      (insert "x")
      (metal-butt-complete--post-command)
      (should (timerp metal-butt-complete--autocomplete-timer)))))

(ert-deftest metal-butt-complete-post-command-does-not-rearm-without-a-change ()
  (metal-butt-complete-test--in-buffer
    (metal-butt-complete-test--cancel-timer
      (metal-butt-toggle-autocomplete)
      (insert "x")
      (metal-butt-complete--post-command)
      (let ((first metal-butt-complete--autocomplete-timer))
        (metal-butt-complete--post-command)
        (should (eq first metal-butt-complete--autocomplete-timer))))))

(ert-deftest metal-butt-complete-post-command-clears-suppression-once-changed ()
  (metal-butt-complete-test--in-buffer
    (metal-butt-complete-test--cancel-timer
      (metal-butt-toggle-autocomplete)
      (setq metal-butt-complete--autocomplete-suppressed-tick (buffer-chars-modified-tick))
      (metal-butt-complete--post-command)
      (should metal-butt-complete--autocomplete-suppressed-tick)
      (should (null metal-butt-complete--autocomplete-timer))
      (insert "x")
      (metal-butt-complete--post-command)
      (should (null metal-butt-complete--autocomplete-suppressed-tick))
      (should (timerp metal-butt-complete--autocomplete-timer)))))

(ert-deftest metal-butt-complete-autocomplete-fire-triggers-a-completion ()
  (metal-butt-complete-test--in-buffer
    (setq metal-butt-complete--autocomplete-enabled t)
    (let (called)
      (cl-letf (((symbol-function 'metal-butt-complete-at-point)
                 (lambda (&optional _interactive) (setq called t))))
        (metal-butt-complete--autocomplete-fire (current-buffer)))
      (should called))))

(ert-deftest metal-butt-complete-autocomplete-fire-skips-when-disabled ()
  (metal-butt-complete-test--in-buffer
    (let (called)
      (cl-letf (((symbol-function 'metal-butt-complete-at-point)
                 (lambda (&optional _interactive) (setq called t))))
        (metal-butt-complete--autocomplete-fire (current-buffer)))
      (should-not called))))

(ert-deftest metal-butt-complete-autocomplete-fire-skips-while-in-flight ()
  (metal-butt-complete-test--in-buffer
    (setq metal-butt-complete--autocomplete-enabled t
          metal-butt--in-flight t)
    (let (called)
      (cl-letf (((symbol-function 'metal-butt-complete-at-point)
                 (lambda (&optional _interactive) (setq called t))))
        (metal-butt-complete--autocomplete-fire (current-buffer)))
      (should-not called))))

(ert-deftest metal-butt-complete-autocomplete-fire-skips-when-suppressed ()
  (metal-butt-complete-test--in-buffer
    (setq metal-butt-complete--autocomplete-enabled t
          metal-butt-complete--autocomplete-suppressed-tick (buffer-chars-modified-tick))
    (let (called)
      (cl-letf (((symbol-function 'metal-butt-complete-at-point)
                 (lambda (&optional _interactive) (setq called t))))
        (metal-butt-complete--autocomplete-fire (current-buffer)))
      (should-not called))))

(ert-deftest metal-butt-complete-autocomplete-fire-skips-with-a-pending-edit ()
  (metal-butt-complete-test--in-buffer
    (insert "int x = 1;\n")
    (setq metal-butt-complete--autocomplete-enabled t)
    (metal-butt-overlay-propose-all '((:old "int x = 1;" :new "int x = 2;")))
    (let (called)
      (cl-letf (((symbol-function 'metal-butt-complete-at-point)
                 (lambda (&optional _interactive) (setq called t))))
        (metal-butt-complete--autocomplete-fire (current-buffer)))
      (should-not called))))

(ert-deftest metal-butt-complete-autocomplete-fire-skips-wrong-backend ()
  (metal-butt-complete-test--in-buffer
    (setq metal-butt-complete--autocomplete-enabled t
          metal-butt-backend 'claude)
    (let (called)
      (cl-letf (((symbol-function 'metal-butt-complete-at-point)
                 (lambda (&optional _interactive) (setq called t))))
        (metal-butt-complete--autocomplete-fire (current-buffer)))
      (should-not called))))

;; -- metal-butt-toggle-autocomplete adjust prompt -------------------------

(ert-deftest metal-butt-toggle-autocomplete-adjust-refuses-when-disabled ()
  (metal-butt-complete-test--in-buffer
    (should-error (metal-butt-toggle-autocomplete t))))

(ert-deftest metal-butt-toggle-autocomplete-adjust-suppresses-until-next-edit ()
  (metal-butt-complete-test--in-buffer
    (metal-butt-complete-test--cancel-timer
      (metal-butt-toggle-autocomplete)
      (insert "x")
      (metal-butt-complete--post-command)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "suppress until I type more")))
        (metal-butt-toggle-autocomplete t))
      (should metal-butt-complete--autocomplete-suppressed-tick)
      (should (null metal-butt-complete--autocomplete-timer)))))

(ert-deftest metal-butt-toggle-autocomplete-adjust-increases-the-idle-delay ()
  (metal-butt-complete-test--in-buffer
    (metal-butt-toggle-autocomplete)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "increase the idle delay"))
              ((symbol-function 'read-number) (lambda (&rest _) 42)))
      (metal-butt-toggle-autocomplete t))
    (should (= 42 metal-butt-complete--autocomplete-idle-delay))
    (should (= 42 (metal-butt-complete--effective-idle-delay)))))

(provide 'metal-butt-complete-test)
;;; metal-butt-complete-test.el ends here
