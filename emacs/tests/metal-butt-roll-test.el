;;; metal-butt-roll-test.el --- Tests for session rolling  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt)

(defmacro metal-butt-test--with-repo (var &rest body)
  (declare (indent 1))
  `(let ((,var (make-temp-file "metal-butt-test" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest metal-butt-roll-threshold-not-reached ()
  (let ((metal-butt-roll-threshold 1000))
    (should-not (metal-butt-session-should-roll-p 999))))

(ert-deftest metal-butt-roll-threshold-reached ()
  (let ((metal-butt-roll-threshold 1000))
    (should (metal-butt-session-should-roll-p 1000))))

(ert-deftest metal-butt-roll-writes-self-handoff ()
  (metal-butt-test--with-repo root
    (let ((metal-butt-transport-function
           (lambda (_r _s callback)
             (funcall callback (list :text "carry this forward" :cost 0 :input-tokens 1) nil))))
      (metal-butt-session-roll root)
      (should (string-match-p "carry this forward"
                              (with-temp-buffer
                                (insert-file-contents
                                 (metal-butt-handoff-file root 'self-handoff))
                                (buffer-string)))))))

(ert-deftest metal-butt-roll-bumps-the-generation ()
  (metal-butt-test--with-repo root
    (let ((metal-butt-transport-function
           (lambda (_r _s callback)
             (funcall callback (list :text "summary" :cost 0 :input-tokens 1) nil))))
      (metal-butt-session-roll root)
      (should (= 1 (metal-butt-session-generation root))))))

(ert-deftest metal-butt-roll-changes-the-session-id ()
  (metal-butt-test--with-repo root
    (let ((before (metal-butt-session-current-id root))
          (metal-butt-transport-function
           (lambda (_r _s callback)
             (funcall callback (list :text "summary" :cost 0 :input-tokens 1) nil))))
      (metal-butt-session-roll root)
      (should-not (equal before (metal-butt-session-current-id root))))))

(ert-deftest metal-butt-roll-seeds-the-next-session ()
  "The successor must be able to consume what the predecessor wrote."
  (metal-butt-test--with-repo root
    (let ((metal-butt-transport-function
           (lambda (_r _s callback)
             (funcall callback (list :text "we chose markers" :cost 0 :input-tokens 1) nil))))
      (metal-butt-session-roll root)
      (should (string-match-p "we chose markers"
                              (metal-butt-handoff-consume root 'self-handoff))))))

(ert-deftest metal-butt-roll-does-not-bump-on-transport-failure ()
  (metal-butt-test--with-repo root
    (let ((metal-butt-transport-function
           (lambda (_r _s callback) (funcall callback nil "boom"))))
      (metal-butt-session-roll root)
      (should (= 0 (metal-butt-session-generation root))))))
