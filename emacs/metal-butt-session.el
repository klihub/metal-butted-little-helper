;;; metal-butt-session.el --- Deterministic session identity  -*- lexical-binding: t; -*-

;;; Commentary:
;; Session ids derive from <repo-root>:<generation>, so there is no id to
;; track.  The generation counter is the only persisted state; losing it
;; resets to zero and starts a fresh session rather than corrupting anything.

;;; Code:

(require 'metal-butt-log)

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

(defcustom metal-butt-roll-threshold 60000
  "Roll the session once a response reports this many input tokens.
Provisional.  Prompt caching makes a long session sublinear in cost,
while a roll discards the cached prefix and pays for a full-context
summarisation, so setting this too low costs more than it saves.  Tune it
against observed `input_tokens' rather than by guessing."
  :type 'integer
  :group 'metal-butt)

(defconst metal-butt-session-roll-prompt
  "Write a handoff note for the session that replaces you. Include: what we are
working on, decisions already made and why, files touched, corrections the user
gave you, and open threads. If a previous handoff note appears above, produce a
single replacement that supersedes it rather than a summary of it. Prose only, no
JSON."
  "Prompt used to extract a self-handoff before rolling.
Deliberately asks for a replacement rather than a summary, so quality does
not degrade by telephone game across generations.")

(declare-function metal-butt-handoff-append "metal-butt-handoff")
(declare-function metal-butt-transport-send "metal-butt-transport")

(defun metal-butt-session-should-roll-p (input-tokens)
  "Non-nil when INPUT-TOKENS has reached `metal-butt-roll-threshold'."
  (>= input-tokens metal-butt-roll-threshold))

(defun metal-butt-session-roll (repo-root)
  "Ask the current session for a self-handoff, then start the next generation."
  (metal-butt-log "roll: requesting self-handoff for session=%s"
                   (metal-butt-session-current-id repo-root))
  (metal-butt-transport-send
   metal-butt-session-roll-prompt
   (metal-butt-session-current-id repo-root)
   (lambda (result error)
     (if error
         (progn
           (metal-butt-log "roll aborted: %s" error)
           (message "Metal Butt: roll aborted, session left alone (%s)" error))
       (metal-butt-handoff-append repo-root 'self-handoff (plist-get result :text))
       (let ((generation (metal-butt-session-bump-generation repo-root)))
         (metal-butt-log "roll: session rolled to generation %d" generation)
         (message "Metal Butt: rolled to generation %d" generation))))))

(provide 'metal-butt-session)
;;; metal-butt-session.el ends here
