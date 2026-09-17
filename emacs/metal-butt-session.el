;;; metal-butt-session.el --- Deterministic session identity  -*- lexical-binding: t; -*-

;;; Commentary:
;; Session ids derive from <repo-root>:<generation>, so there is no id to
;; track.  The generation counter is the only persisted state; losing it
;; resets to zero and starts a fresh session rather than corrupting anything.

;;; Code:

(defun metal-butt-session-dir (repo-root)
  "Return the state directory for REPO-ROOT."
  (expand-file-name ".claude/metal-butt/" repo-root))

(defun metal-butt-session--state-file (repo-root)
  (expand-file-name "state" (metal-butt-session-dir repo-root)))

(defun metal-butt-session-uuid (repo-root generation)
  "Return a deterministic UUID for REPO-ROOT at GENERATION.
Shaped as a version-5 UUID: SHA-1 of the seed with the version nibble
forced to 5 and the variant nibble forced into [89ab]."
  (let* ((hash (secure-hash 'sha1 (format "%s:%d" repo-root generation)))
         (variant (aref "89ab" (mod (string-to-number
                                     (substring hash 16 17) 16)
                                    4))))
    (format "%s-%s-5%s-%c%s-%s"
            (substring hash 0 8)
            (substring hash 8 12)
            (substring hash 13 16)
            variant
            (substring hash 17 20)
            (substring hash 20 32))))

(defun metal-butt-session-generation (repo-root)
  "Return the current generation for REPO-ROOT, or 0 if unset or unreadable."
  (let ((file (metal-butt-session--state-file repo-root)))
    (or (and (file-readable-p file)
             (with-temp-buffer
               (insert-file-contents file)
               (let ((n (string-to-number (string-trim (buffer-string)))))
                 (and (integerp n) (> n 0) n))))
        0)))

(defun metal-butt-session-bump-generation (repo-root)
  "Increment and persist the generation for REPO-ROOT.  Return the new value."
  (let ((next (1+ (metal-butt-session-generation repo-root)))
        (dir (metal-butt-session-dir repo-root)))
    (make-directory dir t)
    (with-temp-file (metal-butt-session--state-file repo-root)
      (insert (number-to-string next) "\n"))
    next))

(defun metal-butt-session-current-id (repo-root)
  "Return the session id for REPO-ROOT's current generation."
  (metal-butt-session-uuid repo-root (metal-butt-session-generation repo-root)))

(provide 'metal-butt-session)
;;; metal-butt-session.el ends here
