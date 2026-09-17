;;; metal-butt-response.el --- Parse Claude's structured response  -*- lexical-binding: t; -*-

;;; Commentary:
;; The contract, stated once per session via --append-system-prompt:
;;   {"kind":"edit","edits":[{"old":"...","new":"...","why":"..."}]}
;;   {"kind":"reply","text":"..."}
;; Anything else is an error surfaced to the user, never a partial mutation.

;;; Code:

(define-error 'metal-butt-response-invalid
  "Claude returned a response that does not match the contract")

(defun metal-butt-response--fail (fmt &rest args)
  (signal 'metal-butt-response-invalid (list (apply #'format fmt args))))

(defun metal-butt-response--edit (alist)
  (let ((old (alist-get 'old alist))
        (new (alist-get 'new alist))
        (why (alist-get 'why alist)))
    (unless (stringp old) (metal-butt-response--fail "edit is missing `old'"))
    (unless (stringp new) (metal-butt-response--fail "edit is missing `new'"))
    (list :old old :new new :why (and (stringp why) why))))

(defun metal-butt-response-parse (json)
  "Parse JSON against the response contract.
Signal `metal-butt-response-invalid' if it does not conform."
  (let ((data (condition-case err
                  (json-parse-string json :object-type 'alist
                                     :null-object nil :false-object nil)
                (error (metal-butt-response--fail "unparseable JSON: %s"
                                                  (error-message-string err))))))
    (unless (consp data) (metal-butt-response--fail "response is not an object"))
    (pcase (alist-get 'kind data)
      ("reply"
       (let ((text (alist-get 'text data)))
         (unless (stringp text) (metal-butt-response--fail "reply is missing `text'"))
         (list :kind 'reply :text text)))
      ("edit"
       (let ((edits (alist-get 'edits data)))
         (unless (and (vectorp edits) (> (length edits) 0))
           (metal-butt-response--fail "edit is missing a non-empty `edits' array"))
         (list :kind 'edit
               :edits (mapcar #'metal-butt-response--edit (append edits nil)))))
      (kind (metal-butt-response--fail "unknown kind: %S" kind)))))

(provide 'metal-butt-response)
;;; metal-butt-response.el ends here
