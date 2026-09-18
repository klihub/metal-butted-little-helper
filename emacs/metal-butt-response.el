;;; metal-butt-response.el --- Parse Claude's structured response  -*- lexical-binding: t; -*-

;;; Commentary:
;; The contract, stated once per session via --append-system-prompt:
;;   {"kind":"edit","edits":[{"old":"...","new":"...","why":"..."}]}
;;   {"kind":"reply","text":"..."}
;; Anything else is an error surfaced to the user, never a partial mutation.

;;; Code:

(define-error 'metal-butt-response-invalid
  "Claude returned a response that does not match the contract")

(defconst metal-butt-response-contract
  "Respond with a single JSON object and nothing else. No prose, no code fences.
Either {\"kind\":\"edit\",\"edits\":[{\"old\":\"...\",\"new\":\"...\",\"why\":\"...\"}]}
where each `old' is text copied verbatim from the buffer and occurring exactly
once in it, or {\"kind\":\"reply\",\"text\":\"...\"} when the answer is discussion
rather than a change. Never propose an edit whose `old' you have not copied
character-for-character from the buffer shown to you. Escape line breaks inside JSON strings as \\n; a raw line break inside a string is invalid JSON."
  "Response contract shared by every backend.
Owned here rather than in a transport module because this file is what
actually parses and enforces it, and both backends must state exactly the
same contract or their responses would need different parsers.  The Claude
backend carries it on argv via --append-system-prompt; the Copilot backend
has no equivalent flag that works in an arbitrary target repository without
a per-project setup step, so it prepends this text to the request instead.")

(defun metal-butt-response--fail (fmt &rest args)
  (signal 'metal-butt-response-invalid (list (apply #'format fmt args))))

(defun metal-butt-response--edit (alist)
  (let ((old (alist-get 'old alist))
        (new (alist-get 'new alist))
        (why (alist-get 'why alist)))
    (unless (stringp old) (metal-butt-response--fail "edit is missing `old'"))
    (unless (stringp new) (metal-butt-response--fail "edit is missing `new'"))
    (list :old old :new new :why (and (stringp why) why))))

(defun metal-butt-response--strip-fences (json)
  "Remove a surrounding Markdown code fence from JSON, if there is one.
Models wrap JSON in fences even when told not to, and a fenced object is
still unambiguously the response that was asked for."
  (let ((text (string-trim json)))
    (if (string-prefix-p "```" text)
        (string-trim
         (replace-regexp-in-string
          "\n?```[ \t]*\\'" ""
          (replace-regexp-in-string "\\````[a-zA-Z]*[ \t]*\n?" "" text)))
      text)))

(defun metal-butt-response--escape-raw-controls (json)
  "Escape raw control characters that appear inside JSON string literals.
Models emit a literal line break inside a string when the text they are
quoting spans lines, which is invalid JSON.  This is a no-op on valid JSON,
because a raw line break inside a string is never legal there, so it can
only widen what parses.  Line breaks BETWEEN tokens, as in pretty-printed
JSON, are outside strings and are left alone."
  (let ((in-string nil)
        (escaped nil)
        (acc nil))
    (dolist (c (append json nil))
      (cond
       (escaped (push c acc) (setq escaped nil))
       ((eq c ?\\) (push c acc) (setq escaped t))
       ((eq c ?\") (push c acc) (setq in-string (not in-string)))
       ((and in-string (eq c ?\n)) (push ?\\ acc) (push ?n acc))
       ((and in-string (eq c ?\r)) (push ?\\ acc) (push ?r acc))
       ((and in-string (eq c ?\t)) (push ?\\ acc) (push ?t acc))
       (t (push c acc))))
    (concat (nreverse acc))))

(defun metal-butt-response-parse (json)
  "Parse JSON against the response contract.
Signal `metal-butt-response-invalid' if it does not conform."
  (let ((data (condition-case err
                  (json-parse-string (metal-butt-response--escape-raw-controls
                                      (metal-butt-response--strip-fences json))
                                     :object-type 'alist
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
