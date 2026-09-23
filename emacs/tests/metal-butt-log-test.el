;;; metal-butt-log-test.el --- Tests for the events log buffer  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-log)

(defmacro metal-butt-log-test--with-clean-buffer (&rest body)
  "Run BODY with a fresh log buffer, then kill it afterward."
  (declare (indent 0))
  `(progn
     (when (get-buffer metal-butt-log-buffer-name)
       (kill-buffer metal-butt-log-buffer-name))
     (unwind-protect (progn ,@body)
       (when (get-buffer metal-butt-log-buffer-name)
         (kill-buffer metal-butt-log-buffer-name)))))

(ert-deftest metal-butt-log-appends-a-timestamped-line ()
  (metal-butt-log-test--with-clean-buffer
    (metal-butt-log "hello %s" "world")
    (with-current-buffer (get-buffer metal-butt-log-buffer-name)
      (should (string-match-p "\\`\\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\.[0-9]\\{3\\}\\] hello world\n\\'"
                              (buffer-string))))))

(ert-deftest metal-butt-log-appends-multiple-lines-in-order ()
  (metal-butt-log-test--with-clean-buffer
    (metal-butt-log "first")
    (metal-butt-log "second")
    (with-current-buffer (get-buffer metal-butt-log-buffer-name)
      (should (string-match-p "first\n.*second" (buffer-string))))))

(ert-deftest metal-butt-log-disabled-does-nothing ()
  (metal-butt-log-test--with-clean-buffer
    (let ((metal-butt-log-enabled nil))
      (metal-butt-log "should not appear"))
    (should-not (and (get-buffer metal-butt-log-buffer-name)
                      (with-current-buffer metal-butt-log-buffer-name
                        (> (buffer-size) 0))))))

(ert-deftest metal-butt-log-buffer-is-read-only ()
  (metal-butt-log-test--with-clean-buffer
    (metal-butt-log "line")
    (with-current-buffer (get-buffer metal-butt-log-buffer-name)
      (should buffer-read-only))))

(ert-deftest metal-butt-log-a-format-error-does-not-signal ()
  (metal-butt-log-test--with-clean-buffer
    (should-not (condition-case nil
                    (progn (metal-butt-log "%d" "not-a-number") nil)
                  (error t)))
    (with-current-buffer (get-buffer metal-butt-log-buffer-name)
      (should (string-match-p "unformattable log message" (buffer-string))))))

(ert-deftest metal-butt-log-trims-oldest-lines-past-the-cap ()
  (metal-butt-log-test--with-clean-buffer
    (let ((metal-butt-log-max-chars 200))
      (dotimes (i 50)
        (metal-butt-log "line %d %s" i (make-string 20 ?x)))
      (with-current-buffer (get-buffer metal-butt-log-buffer-name)
        (should (<= (- (point-max) (point-min)) (+ metal-butt-log-max-chars 100)))
        (should-not (string-match-p "line 0 " (buffer-string)))
        (should (string-match-p "line 49 " (buffer-string)))))))

(ert-deftest metal-butt-show-log-displays-and-moves-point-to-end ()
  (metal-butt-log-test--with-clean-buffer
    (metal-butt-log "one")
    (metal-butt-log "two")
    (save-window-excursion
      (metal-butt-show-log)
      (with-current-buffer (get-buffer metal-butt-log-buffer-name)
        (should (= (point) (point-max)))))))

(provide 'metal-butt-log-test)
;;; metal-butt-log-test.el ends here
