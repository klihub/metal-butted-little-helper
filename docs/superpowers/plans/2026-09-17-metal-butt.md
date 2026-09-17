# Metal Butt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a developer prompt Claude from inside an Emacs buffer using the buffer's own comment syntax, and receive either a reviewable code edit or a written answer.

**Architecture:** Pure-elisp pipeline: a keystroke locates a `claude:` comment block, assembles a request from live buffer content plus any pending handoff context, shells out asynchronously to `claude -p --resume`, and applies the structured JSON response as either an accept/reject overlay or an inserted comment. The transport is the only component behind an injectable interface, so a stub covers the entire pipeline in tests without spending API budget.

**Tech Stack:** Emacs Lisp (Emacs 30.2), ERT, native `json-parse-string`, `make-process`. No external Elisp dependencies.

**Spec:** `docs/superpowers/specs/2026-09-17-metal-butt-design.md`

## Global Constraints

- Emacs 30.1+ required (native `json-parse-string`, `string-trim`). Target machine runs 30.2.
- **No external Elisp package dependencies.** No `websocket.el`, no `transient`, no `vterm`.
- Symbol prefix is `metal-butt-` for public names, `metal-butt--` for internal ones. Per-module prefixes are `metal-butt-<module>--` for internals.
- Send keybinding is `C-c b` in `metal-butt-mode-map`. Never bind `C-c C-c`.
- `metal-butt-model` defaults to `"sonnet"`. `metal-butt-fallback-model` defaults to `nil` — never silently downgrade the model.
- Claude must never write to disk: every invocation passes `--disallowedTools Edit,Write,NotebookEdit`.
- Response contract is exactly `{"kind":"edit","edits":[{"old","new","why"}]}` or `{"kind":"reply","text"}`.
- Edits are string pairs. An `old` string that matches zero times or more than once is refused, never guessed.
- One request in flight per buffer.
- All state lives under `<repo-root>/.claude/metal-butt/` and is gitignored.
- Tests never invoke the real `claude` binary. Any test that would spend money is a plan failure.

---

### Task 1: Test harness and prompt block detection

The attention-word matcher is the foundation everything else builds on, so it ships with the test harness it needs.

**Deviation from spec, deliberate:** the spec said derive comment syntax from `comment-start`. For *detection* we instead match a leading run of punctuation, because `comment-start` is `"/* "` in `c-mode` but `"// "` in `c++-mode`, and users type `//` in both. `comment-start` is still used for *insertion* in Task 8.

**Files:**
- Create: `Makefile`
- Create: `.gitignore`
- Create: `metal-butt-prompt.el`
- Test: `tests/metal-butt-prompt-test.el`

**Interfaces:**
- Consumes: nothing.
- Produces: `(metal-butt-prompt-at-point)` → plist `(:text STRING :start MARKER :end MARKER)` or `nil`. `:text` is the prompt with comment punctuation and the attention word stripped, lines joined by `"\n"`. `:start`/`:end` are markers delimiting the comment block.
- Produces: `metal-butt-attention-word` (defcustom, default `"claude"`).

- [ ] **Step 1: Create the test harness and gitignore**

`Makefile` (the recipe lines must be indented with real TAB characters):

```make
EMACS ?= emacs
TESTS := $(wildcard tests/*-test.el)

.PHONY: check compile clean

check:
	$(EMACS) -Q --batch -L . -L tests \
	  $(patsubst %,-l %,$(TESTS)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile metal-butt*.el

clean:
	rm -f *.elc tests/*.elc
```

`.gitignore`:

```gitignore
*.elc
.claude/metal-butt/
```

- [ ] **Step 2: Write the failing test**

`tests/metal-butt-prompt-test.el`:

```elisp
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
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `Cannot open load file: metal-butt-prompt`

- [ ] **Step 4: Write the implementation**

`metal-butt-prompt.el`:

```elisp
;;; metal-butt-prompt.el --- Locate claude: prompt blocks  -*- lexical-binding: t; -*-

;;; Commentary:
;; Finds a comment block introduced by the attention word at or above point.
;; Detection matches a leading run of punctuation rather than `comment-start',
;; because `comment-start' is "/* " in c-mode while users type "//".

;;; Code:

(defgroup metal-butt nil
  "Pair programming with Claude from Emacs buffers."
  :group 'tools
  :prefix "metal-butt-")

(defcustom metal-butt-attention-word "claude"
  "Word that marks a comment as a prompt for Claude."
  :type 'string
  :group 'metal-butt)

(defconst metal-butt-prompt--comment-rx
  "^\\([[:space:]]*\\)\\([^[:alnum:][:space:]]+\\)[[:space:]]*"
  "Matches indentation (group 1) and comment punctuation (group 2).")

(defun metal-butt-prompt--attention-rx ()
  "Regexp matching a line that opens a prompt block."
  (concat metal-butt-prompt--comment-rx
          (regexp-quote metal-butt-attention-word)
          ":[[:space:]]*"))

(defun metal-butt-prompt--line-indent ()
  "Return indentation string of the current line, or nil if not a comment line."
  (save-excursion
    (beginning-of-line)
    (when (looking-at metal-butt-prompt--comment-rx)
      (match-string 1))))

(defun metal-butt-prompt--attention-line-p ()
  "Non-nil if the current line opens a prompt block."
  (save-excursion
    (beginning-of-line)
    (let ((case-fold-search t))
      (looking-at (metal-butt-prompt--attention-rx)))))

(defun metal-butt-prompt--strip-line ()
  "Return the current line's text with comment punctuation removed."
  (save-excursion
    (beginning-of-line)
    (let ((case-fold-search t))
      (if (looking-at (metal-butt-prompt--attention-rx))
          (buffer-substring-no-properties (match-end 0) (line-end-position))
        (looking-at metal-butt-prompt--comment-rx)
        (buffer-substring-no-properties (match-end 0) (line-end-position))))))

(defun metal-butt-prompt--find-attention-line ()
  "Move point to the attention line of the block at or above point.
Return non-nil on success."
  (beginning-of-line)
  (cond
   ((metal-butt-prompt--attention-line-p) t)
   ;; Walk up through a contiguous comment run at the same indentation.
   (t (let ((indent (metal-butt-prompt--line-indent))
            (found nil))
        (while (and (not found)
                    (metal-butt-prompt--line-indent)
                    (equal (metal-butt-prompt--line-indent) indent)
                    (not (bobp)))
          (forward-line -1)
          (when (metal-butt-prompt--attention-line-p)
            (setq found t)))
        ;; Point started on a non-comment line: check the line directly above.
        (unless (or found indent)
          (forward-line -1)
          (when (metal-butt-prompt--attention-line-p)
            (setq found t)))
        found))))

(defun metal-butt-prompt-at-point ()
  "Return the prompt block at or above point, or nil.
The value is a plist (:text STRING :start MARKER :end MARKER)."
  (save-excursion
    (when (metal-butt-prompt--find-attention-line)
      (let* ((start (copy-marker (line-beginning-position)))
             (indent (metal-butt-prompt--line-indent))
             (lines (list (metal-butt-prompt--strip-line))))
        (forward-line 1)
        (while (and (not (eobp))
                    (equal (metal-butt-prompt--line-indent) indent)
                    (not (metal-butt-prompt--attention-line-p)))
          (push (metal-butt-prompt--strip-line) lines)
          (forward-line 1))
        (list :text (string-join (nreverse lines) "\n")
              :start start
              :end (copy-marker (point)))))))

(provide 'metal-butt-prompt)
;;; metal-butt-prompt.el ends here
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 9 tests. If `metal-butt-prompt-finds-block-above-point` fails, the non-comment-line branch of `metal-butt-prompt--find-attention-line` is wrong — fix it there, not in the test.

- [ ] **Step 6: Verify clean byte-compilation**

Run: `make compile`
Expected: no output, exit 0. Warnings are errors.

- [ ] **Step 7: Commit**

```bash
git add Makefile .gitignore metal-butt-prompt.el tests/metal-butt-prompt-test.el
git commit -m "Detect claude: prompt blocks in any comment syntax

Match a leading run of punctuation rather than comment-start, since
comment-start is \"/* \" in c-mode while users type \"//\"."
```

---

### Task 2: Response contract parsing

**Files:**
- Create: `metal-butt-response.el`
- Test: `tests/metal-butt-response-test.el`

**Interfaces:**
- Consumes: nothing.
- Produces: `(metal-butt-response-parse JSON-STRING)` → plist `(:kind 'edit :edits LIST)` where each element is `(:old STRING :new STRING :why STRING-OR-NIL)`, or `(:kind 'reply :text STRING)`. Signals `metal-butt-response-invalid` with a message on anything malformed.
- Produces: error symbol `metal-butt-response-invalid`.

- [ ] **Step 1: Write the failing test**

`tests/metal-butt-response-test.el`:

```elisp
;;; metal-butt-response-test.el --- Tests for response parsing  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-response)

(ert-deftest metal-butt-response-parses-reply ()
  (let ((r (metal-butt-response-parse "{\"kind\":\"reply\",\"text\":\"careful, api.go passes nil\"}")))
    (should (eq (plist-get r :kind) 'reply))
    (should (equal (plist-get r :text) "careful, api.go passes nil"))))

(ert-deftest metal-butt-response-parses-edit ()
  (let* ((json "{\"kind\":\"edit\",\"edits\":[{\"old\":\"a\",\"new\":\"b\",\"why\":\"clearer\"}]}")
         (r (metal-butt-response-parse json))
         (e (car (plist-get r :edits))))
    (should (eq (plist-get r :kind) 'edit))
    (should (equal (plist-get e :old) "a"))
    (should (equal (plist-get e :new) "b"))
    (should (equal (plist-get e :why) "clearer"))))

(ert-deftest metal-butt-response-allows-missing-why ()
  (let* ((r (metal-butt-response-parse "{\"kind\":\"edit\",\"edits\":[{\"old\":\"a\",\"new\":\"b\"}]}"))
         (e (car (plist-get r :edits))))
    (should-not (plist-get e :why))))

(ert-deftest metal-butt-response-rejects-malformed-json ()
  (should-error (metal-butt-response-parse "{not json")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-unknown-kind ()
  (should-error (metal-butt-response-parse "{\"kind\":\"explode\"}")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-reply-without-text ()
  (should-error (metal-butt-response-parse "{\"kind\":\"reply\"}")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-edit-without-edits ()
  (should-error (metal-butt-response-parse "{\"kind\":\"edit\"}")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-edit-missing-old ()
  (should-error (metal-butt-response-parse "{\"kind\":\"edit\",\"edits\":[{\"new\":\"b\"}]}")
                :type 'metal-butt-response-invalid))

(ert-deftest metal-butt-response-rejects-empty-edits ()
  (should-error (metal-butt-response-parse "{\"kind\":\"edit\",\"edits\":[]}")
                :type 'metal-butt-response-invalid))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `Cannot open load file: metal-butt-response`

- [ ] **Step 3: Write the implementation**

`metal-butt-response.el`:

```elisp
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 18 tests total.

- [ ] **Step 5: Commit**

```bash
git add metal-butt-response.el tests/metal-butt-response-test.el
git commit -m "Parse and validate the edit/reply response contract

Malformed responses signal an error rather than producing a partial
buffer mutation."
```

---

### Task 3: Session identity and generation counter

**Files:**
- Create: `metal-butt-session.el`
- Test: `tests/metal-butt-session-test.el`

**Interfaces:**
- Consumes: nothing.
- Produces: `(metal-butt-session-uuid REPO-ROOT GENERATION)` → UUID string.
- Produces: `(metal-butt-session-dir REPO-ROOT)` → `<repo-root>/.claude/metal-butt/`.
- Produces: `(metal-butt-session-generation REPO-ROOT)` → integer, 0 if unset.
- Produces: `(metal-butt-session-bump-generation REPO-ROOT)` → new integer, persisted.
- Produces: `(metal-butt-session-current-id REPO-ROOT)` → UUID for the current generation.

- [ ] **Step 1: Write the failing test**

`tests/metal-butt-session-test.el`:

```elisp
;;; metal-butt-session-test.el --- Tests for session identity  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-session)

(defmacro metal-butt-test--with-repo (var &rest body)
  "Bind VAR to a fresh temporary repo root, run BODY, then delete it."
  (declare (indent 1))
  `(let ((,var (make-temp-file "metal-butt-test" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest metal-butt-session-uuid-is-well-formed ()
  (should (string-match-p
           "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-5[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'"
           (metal-butt-session-uuid "/tmp/repo" 0))))

(ert-deftest metal-butt-session-uuid-is-deterministic ()
  (should (equal (metal-butt-session-uuid "/tmp/repo" 0)
                 (metal-butt-session-uuid "/tmp/repo" 0))))

(ert-deftest metal-butt-session-uuid-varies-by-generation ()
  (should-not (equal (metal-butt-session-uuid "/tmp/repo" 0)
                     (metal-butt-session-uuid "/tmp/repo" 1))))

(ert-deftest metal-butt-session-uuid-varies-by-repo ()
  (should-not (equal (metal-butt-session-uuid "/tmp/a" 0)
                     (metal-butt-session-uuid "/tmp/b" 0))))

(ert-deftest metal-butt-session-generation-defaults-to-zero ()
  (metal-butt-test--with-repo root
    (should (= 0 (metal-butt-session-generation root)))))

(ert-deftest metal-butt-session-bump-persists ()
  (metal-butt-test--with-repo root
    (should (= 1 (metal-butt-session-bump-generation root)))
    (should (= 1 (metal-butt-session-generation root)))
    (should (= 2 (metal-butt-session-bump-generation root)))))

(ert-deftest metal-butt-session-corrupt-state-resets-to-zero ()
  (metal-butt-test--with-repo root
    (make-directory (metal-butt-session-dir root) t)
    (with-temp-file (expand-file-name "state" (metal-butt-session-dir root))
      (insert "not a number"))
    (should (= 0 (metal-butt-session-generation root)))))

(ert-deftest metal-butt-session-current-id-tracks-generation ()
  (metal-butt-test--with-repo root
    (let ((first (metal-butt-session-current-id root)))
      (metal-butt-session-bump-generation root)
      (should-not (equal first (metal-butt-session-current-id root))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `Cannot open load file: metal-butt-session`

- [ ] **Step 3: Write the implementation**

`metal-butt-session.el`:

```elisp
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
                 (and (integerp n) (>= n 0) (> n 0) n))))
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
```

Note on `metal-butt-session-generation`: `string-to-number` returns 0 for junk, and generation 0 is also the legitimate default, so returning 0 on unparseable input is correct behaviour rather than a swallowed error. The `(> n 0)` guard exists so a corrupt file and a missing file take the same path.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 26 tests total.

- [ ] **Step 5: Commit**

```bash
git add metal-butt-session.el tests/metal-butt-session-test.el
git commit -m "Derive session ids from repo root and generation counter

No session id bookkeeping: the same repo at the same generation always
yields the same id. Losing the counter resets to zero rather than
corrupting state."
```

---

### Task 4: Handoff files with consumed-offset tracking

**Files:**
- Create: `metal-butt-handoff.el`
- Test: `tests/metal-butt-handoff-test.el`

**Interfaces:**
- Consumes: `metal-butt-session-dir` from Task 3.
- Produces: `(metal-butt-handoff-append REPO-ROOT CHANNEL TEXT)` where CHANNEL is one of `to-emacs`, `to-terminal`, `self-handoff`.
- Produces: `(metal-butt-handoff-consume REPO-ROOT CHANNEL)` → unconsumed string (`""` if none), advancing the offset.
- Produces: `(metal-butt-handoff-file REPO-ROOT CHANNEL)` → absolute path.

- [ ] **Step 1: Write the failing test**

`tests/metal-butt-handoff-test.el`:

```elisp
;;; metal-butt-handoff-test.el --- Tests for handoff files  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-handoff)

(defmacro metal-butt-test--with-repo (var &rest body)
  (declare (indent 1))
  `(let ((,var (make-temp-file "metal-butt-test" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest metal-butt-handoff-consume-empty-is-empty-string ()
  (metal-butt-test--with-repo root
    (should (equal "" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-append-then-consume ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "we agreed to use markers\n")
    (should (equal "we agreed to use markers\n"
                   (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-consume-is-idempotent ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "first\n")
    (metal-butt-handoff-consume root 'to-emacs)
    (should (equal "" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-consume-returns-only-the-delta ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "first\n")
    (metal-butt-handoff-consume root 'to-emacs)
    (metal-butt-handoff-append root 'to-emacs "second\n")
    (should (equal "second\n" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-channels-are-independent ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "for emacs\n")
    (metal-butt-handoff-append root 'to-terminal "for terminal\n")
    (should (equal "for emacs\n" (metal-butt-handoff-consume root 'to-emacs)))
    (should (equal "for terminal\n" (metal-butt-handoff-consume root 'to-terminal)))))

(ert-deftest metal-butt-handoff-truncation-rereads-from-zero ()
  "Skipped context is worse than duplicated context."
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "a long first note\n")
    (metal-butt-handoff-consume root 'to-emacs)
    (with-temp-file (metal-butt-handoff-file root 'to-emacs) (insert "tiny\n"))
    (should (equal "tiny\n" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-missing-offsets-rereads-from-zero ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "note\n")
    (metal-butt-handoff-consume root 'to-emacs)
    (delete-file (expand-file-name "offsets" (metal-butt-session-dir root)))
    (should (equal "note\n" (metal-butt-handoff-consume root 'to-emacs)))))

(ert-deftest metal-butt-handoff-rejects-unknown-channel ()
  (metal-butt-test--with-repo root
    (should-error (metal-butt-handoff-append root 'nonsense "x"))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `Cannot open load file: metal-butt-handoff`

- [ ] **Step 3: Write the implementation**

`metal-butt-handoff.el`:

```elisp
;;; metal-butt-handoff.el --- Append-only context handoff  -*- lexical-binding: t; -*-

;;; Commentary:
;; One handoff format, three channels: terminal to Emacs, Emacs to terminal,
;; and session to successor.  One file per direction with a single writer, so
;; there is no interleaving and therefore no locking.

;;; Code:

(require 'metal-butt-session)

(defconst metal-butt-handoff-channels '(to-emacs to-terminal self-handoff))

(defun metal-butt-handoff--check-channel (channel)
  (unless (memq channel metal-butt-handoff-channels)
    (error "Unknown handoff channel: %S" channel)))

(defun metal-butt-handoff-file (repo-root channel)
  "Return the file backing CHANNEL in REPO-ROOT."
  (metal-butt-handoff--check-channel channel)
  (expand-file-name (format "%s.md" channel)
                    (metal-butt-session-dir repo-root)))

(defun metal-butt-handoff--offsets-file (repo-root)
  (expand-file-name "offsets" (metal-butt-session-dir repo-root)))

(defun metal-butt-handoff--offsets (repo-root)
  (let ((file (metal-butt-handoff--offsets-file repo-root)))
    (or (and (file-readable-p file)
             (ignore-errors
               (with-temp-buffer
                 (insert-file-contents file)
                 (read (current-buffer)))))
        nil)))

(defun metal-butt-handoff--set-offset (repo-root channel offset)
  (let* ((offsets (assq-delete-all channel (metal-butt-handoff--offsets repo-root)))
         (updated (cons (cons channel offset) offsets)))
    (make-directory (metal-butt-session-dir repo-root) t)
    (with-temp-file (metal-butt-handoff--offsets-file repo-root)
      (prin1 updated (current-buffer))
      (insert "\n"))))

(defun metal-butt-handoff-append (repo-root channel text)
  "Append TEXT to CHANNEL in REPO-ROOT."
  (let ((file (metal-butt-handoff-file repo-root channel)))
    (make-directory (metal-butt-session-dir repo-root) t)
    (with-temp-buffer
      (insert text)
      (unless (string-suffix-p "\n" text) (insert "\n"))
      (write-region (point-min) (point-max) file t 'quiet))))

(defun metal-butt-handoff-consume (repo-root channel)
  "Return the unconsumed tail of CHANNEL in REPO-ROOT, advancing the offset.
Returns the empty string when there is nothing new.  If the file has
shrunk since the offset was recorded, re-read from zero: duplicated
context is acceptable, skipped context is not."
  (let ((file (metal-butt-handoff-file repo-root channel)))
    (if (not (file-readable-p file))
        ""
      (let* ((size (file-attribute-size (file-attributes file)))
             (recorded (or (alist-get channel (metal-butt-handoff--offsets repo-root)) 0))
             (offset (if (> recorded size) 0 recorded)))
        (if (>= offset size)
            ""
          (with-temp-buffer
            (insert-file-contents file nil offset size)
            (metal-butt-handoff--set-offset repo-root channel size)
            (buffer-string)))))))

(provide 'metal-butt-handoff)
;;; metal-butt-handoff.el ends here
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 34 tests total.

- [ ] **Step 5: Commit**

```bash
git add metal-butt-handoff.el tests/metal-butt-handoff-test.el
git commit -m "Add append-only handoff channels with offset tracking

One file per direction with a single writer, so no locking is needed. A
shrunken file re-reads from zero, because duplicated context is
acceptable and skipped context is not."
```

---

### Task 5: Request context assembly

**Files:**
- Create: `metal-butt-context.el`
- Test: `tests/metal-butt-context-test.el`

**Interfaces:**
- Consumes: `metal-butt-handoff-consume` (Task 4).
- Produces: `(metal-butt-context-build PROMPT REPO-ROOT)` → string, the full text piped to `claude -p`. Called with the target buffer current.
- Produces: `metal-butt-max-buffer-chars` (defcustom, default 20000).

- [ ] **Step 1: Write the failing test**

`tests/metal-butt-context-test.el`:

```elisp
;;; metal-butt-context-test.el --- Tests for context assembly  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-context)

(defmacro metal-butt-test--with-repo (var &rest body)
  (declare (indent 1))
  `(let ((,var (make-temp-file "metal-butt-test" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest metal-butt-context-includes-prompt ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (insert "int x = 1;\n")
      (should (string-match-p "fix the loop"
                              (metal-butt-context-build "fix the loop" root))))))

(ert-deftest metal-butt-context-includes-buffer-contents ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (insert "int unique_marker = 1;\n")
      (should (string-match-p "unique_marker"
                              (metal-butt-context-build "p" root))))))

(ert-deftest metal-butt-context-includes-major-mode ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (emacs-lisp-mode)
      (should (string-match-p "emacs-lisp-mode"
                              (metal-butt-context-build "p" root))))))

(ert-deftest metal-butt-context-includes-handoff-delta ()
  (metal-butt-test--with-repo root
    (metal-butt-handoff-append root 'to-emacs "we chose markers over line numbers")
    (with-temp-buffer
      (should (string-match-p "markers over line numbers"
                              (metal-butt-context-build "p" root))))))

(ert-deftest metal-butt-context-omits-handoff-section-when-empty ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (should-not (string-match-p "Context handed over"
                                  (metal-butt-context-build "p" root))))))

(ert-deftest metal-butt-context-truncates-large-buffers ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (insert (make-string 1000 ?a))
      (goto-char (point-max))
      (let ((metal-butt-max-buffer-chars 100))
        (let ((ctx (metal-butt-context-build "p" root)))
          (should (string-match-p "truncated" ctx))
          (should (< (length ctx) 600)))))))

(ert-deftest metal-butt-context-includes-region-when-active ()
  (metal-butt-test--with-repo root
    (with-temp-buffer
      (insert "alpha\nbeta\ngamma\n")
      (goto-char (point-min))
      (set-mark (point))
      (forward-line 1)
      (let ((ctx (metal-butt-context-build "p" root)))
        (should (string-match-p "Selected region" ctx))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `Cannot open load file: metal-butt-context`

- [ ] **Step 3: Write the implementation**

`metal-butt-context.el`:

```elisp
;;; metal-butt-context.el --- Assemble the request payload  -*- lexical-binding: t; -*-

;;; Commentary:
;; Sends the buffer's live content, never the file on disk: the buffer
;; frequently holds unsaved changes, which makes the file a stale copy.

;;; Code:

(require 'metal-butt-handoff)

(defcustom metal-butt-max-buffer-chars 20000
  "Send at most this much buffer text; larger buffers send a window around point."
  :type 'integer
  :group 'metal-butt)

(defun metal-butt-context--buffer-text ()
  "Return buffer text, or a window around point for large buffers.
The second value of the returned cons is non-nil when truncated."
  (if (<= (buffer-size) metal-butt-max-buffer-chars)
      (cons (buffer-substring-no-properties (point-min) (point-max)) nil)
    (let* ((half (/ metal-butt-max-buffer-chars 2))
           (beg (max (point-min) (- (point) half)))
           (end (min (point-max) (+ (point) half))))
      (cons (buffer-substring-no-properties beg end) t))))

(defun metal-butt-context-build (prompt repo-root)
  "Build the text piped to `claude -p' for PROMPT in REPO-ROOT.
Call with the target buffer current."
  (let* ((text-and-flag (metal-butt-context--buffer-text))
         (body (car text-and-flag))
         (truncated (cdr text-and-flag))
         (handoff (metal-butt-handoff-consume repo-root 'to-emacs))
         (parts nil))
    (push (format "## Request\n\n%s\n" prompt) parts)
    (unless (string-empty-p handoff)
      (push (format "## Context handed over from the terminal session\n\n%s\n" handoff)
            parts))
    (push (format "## Buffer\n\nFile: %s\nMajor mode: %s\nPoint: line %d\n%s"
                  (or (buffer-file-name) "(unsaved buffer)")
                  major-mode
                  (line-number-at-pos)
                  (if truncated
                      "Note: buffer was truncated to a window around point.\n"
                    ""))
          parts)
    (when (use-region-p)
      (push (format "\n## Selected region\n\n```\n%s\n```\n"
                    (buffer-substring-no-properties (region-beginning) (region-end)))
            parts))
    (push (format "\n```\n%s\n```\n" body) parts)
    (string-join (nreverse parts) "\n")))

(provide 'metal-butt-context)
;;; metal-butt-context.el ends here
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 41 tests total.

- [ ] **Step 5: Commit**

```bash
git add metal-butt-context.el tests/metal-butt-context-test.el
git commit -m "Assemble request context from live buffer state

Sends buffer contents rather than the file, since the buffer routinely
holds unsaved changes that would make the file a stale copy."
```

---

### Task 6: Transport

The async process is thin; everything decidable is factored into pure functions so it can be tested without running `claude`.

**Files:**
- Create: `metal-butt-transport.el`
- Test: `tests/metal-butt-transport-test.el`

**Interfaces:**
- Consumes: nothing.
- Produces: `(metal-butt-transport-argv SESSION-ID)` → list of strings.
- Produces: `(metal-butt-transport--extract-result JSON-STRING)` → plist `(:text STRING :cost NUMBER :input-tokens INTEGER)`; signals `metal-butt-transport-error` on failure.
- Produces: `(metal-butt-transport--classify-error STDERR)` → string, a human-readable diagnosis.
- Produces: `metal-butt-transport-function` (variable) — funcall'd as `(FN REQUEST-TEXT SESSION-ID CALLBACK)`. Tests rebind it. Default is `metal-butt-transport--run`.
- Produces: `metal-butt-model`, `metal-butt-fallback-model`, `metal-butt-executable` (defcustoms).
- Produces: error symbol `metal-butt-transport-error`.

- [ ] **Step 1: Write the failing test**

`tests/metal-butt-transport-test.el`:

```elisp
;;; metal-butt-transport-test.el --- Tests for the transport  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-transport)

(ert-deftest metal-butt-transport-argv-has-required-flags ()
  (let ((argv (metal-butt-transport-argv "11111111-1111-5111-8111-111111111111")))
    (should (member "-p" argv))
    (should (member "--output-format" argv))
    (should (member "json" argv))
    (should (member "--resume" argv))
    (should (member "11111111-1111-5111-8111-111111111111" argv))))

(ert-deftest metal-butt-transport-argv-forbids-disk-writes ()
  (let ((argv (metal-butt-transport-argv "x")))
    (should (member "--disallowedTools" argv))
    (should (member "Edit,Write,NotebookEdit" argv))))

(ert-deftest metal-butt-transport-argv-includes-the-contract ()
  (let ((argv (metal-butt-transport-argv "x")))
    (should (member "--append-system-prompt" argv))
    (should (seq-find (lambda (a) (string-match-p "\"kind\"" a)) argv))))

(ert-deftest metal-butt-transport-argv-uses-configured-model ()
  (let ((metal-butt-model "haiku"))
    (should (member "haiku" (metal-butt-transport-argv "x")))))

(ert-deftest metal-butt-transport-extracts-result-and-usage ()
  (let* ((json "{\"result\":\"OK\",\"total_cost_usd\":0.0042,\"usage\":{\"input_tokens\":1234}}")
         (r (metal-butt-transport--extract-result json)))
    (should (equal (plist-get r :text) "OK"))
    (should (= (plist-get r :cost) 0.0042))
    (should (= (plist-get r :input-tokens) 1234))))

(ert-deftest metal-butt-transport-extract-rejects-missing-result ()
  (should-error (metal-butt-transport--extract-result "{\"usage\":{}}")
                :type 'metal-butt-transport-error))

(ert-deftest metal-butt-transport-extract-rejects-garbage ()
  (should-error (metal-butt-transport--extract-result "not json")
                :type 'metal-butt-transport-error))

(ert-deftest metal-butt-transport-diagnoses-iam-denial ()
  (let ((msg (metal-butt-transport--classify-error
              "API Error: 403 {\"Message\":\"User: arn:aws:iam::1:user/u is not authorized to perform: bedrock:InvokeModelWithResponseStream ... with an explicit deny in an identity-based policy: arn:aws:iam::1:policy/BedrockMinimalInferenceAccess\"}")))
    (should (string-match-p "BedrockMinimalInferenceAccess" msg))
    (should (string-match-p "explicit deny" msg))))

(ert-deftest metal-butt-transport-does-not-suggest-a-cheaper-model ()
  "A silent downgrade would change edit quality without the user knowing why."
  (let ((msg (metal-butt-transport--classify-error "API Error: 403 explicit deny")))
    (should-not (string-match-p "haiku" msg))))

(ert-deftest metal-butt-transport-passes-through-unknown-errors ()
  (should (string-match-p "boom" (metal-butt-transport--classify-error "boom"))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `Cannot open load file: metal-butt-transport`

- [ ] **Step 3: Write the implementation**

`metal-butt-transport.el`:

```elisp
;;; metal-butt-transport.el --- Talk to the claude CLI  -*- lexical-binding: t; -*-

;;; Commentary:
;; The only component with residual unknowns, so the only one behind an
;; injectable interface: rebind `metal-butt-transport-function' to a stub and
;; the whole pipeline is testable without spending API budget.
;;
;; The request is written to stdin rather than passed as an argument, because
;; it carries whole buffers and would otherwise hit argv length limits.

;;; Code:

(require 'seq)

(define-error 'metal-butt-transport-error "Claude CLI transport failed")

(defcustom metal-butt-executable "claude"
  "Name or path of the Claude Code CLI."
  :type 'string
  :group 'metal-butt)

(defcustom metal-butt-model "sonnet"
  "Model used for buffer prompts."
  :type 'string
  :group 'metal-butt)

(defcustom metal-butt-fallback-model nil
  "Never set this to a cheaper model expecting a silent retry.
A silent downgrade would change edit quality without the user knowing
why suggestions got worse, which is harder to diagnose than an error."
  :type '(choice (const :tag "No fallback" nil) string)
  :group 'metal-butt)

(defconst metal-butt-transport-contract
  "Respond with a single JSON object and nothing else. No prose, no code fences.
Either {\"kind\":\"edit\",\"edits\":[{\"old\":\"...\",\"new\":\"...\",\"why\":\"...\"}]}
where each `old' is text copied verbatim from the buffer and occurring exactly
once in it, or {\"kind\":\"reply\",\"text\":\"...\"} when the answer is discussion
rather than a change. Never propose an edit whose `old' you have not copied
character-for-character from the buffer shown to you."
  "Response contract, stated once per session via --append-system-prompt.")

(defun metal-butt-transport-argv (session-id)
  "Return the argument list for a request against SESSION-ID."
  (list "-p"
        "--resume" session-id
        "--model" metal-butt-model
        "--output-format" "json"
        "--append-system-prompt" metal-butt-transport-contract
        "--disallowedTools" "Edit,Write,NotebookEdit"))

(defun metal-butt-transport--extract-result (json)
  "Pull the assistant text and usage figures out of JSON."
  (let ((data (condition-case err
                  (json-parse-string json :object-type 'alist
                                     :null-object nil :false-object nil)
                (error (signal 'metal-butt-transport-error
                               (list (format "unparseable CLI output: %s"
                                             (error-message-string err))))))))
    (let ((result (alist-get 'result data))
          (usage (alist-get 'usage data)))
      (unless (stringp result)
        (signal 'metal-butt-transport-error (list "CLI output has no `result'")))
      (list :text result
            :cost (or (alist-get 'total_cost_usd data) 0)
            :input-tokens (or (alist-get 'input_tokens usage) 0)))))

(defun metal-butt-transport--classify-error (stderr)
  "Turn STDERR into an actionable diagnosis."
  (if (string-match-p "explicit deny\\|not authorized\\|AccessDenied" stderr)
      (concat
       (format "Model %S was refused by AWS. " metal-butt-model)
       (if (string-match "policy/\\([A-Za-z0-9_-]+\\)" stderr)
           (format "An explicit deny in IAM policy %S is blocking it; an explicit deny cannot be overridden by adding an Allow, so that policy must be amended. "
                   (match-string 1 stderr))
         "An explicit deny in an IAM policy is blocking it. ")
       "Cross-region inference profiles also need permission on the underlying "
       "foundation-model ARNs in every destination region.\n\n"
       stderr)
    stderr))

(defun metal-butt-transport--run (request session-id callback)
  "Send REQUEST to SESSION-ID, calling CALLBACK with a result plist or an error.
CALLBACK receives (RESULT-PLIST nil) on success or (nil ERROR-STRING) on failure."
  (let* ((stdout (generate-new-buffer " *metal-butt-stdout*"))
         (stderr (generate-new-buffer " *metal-butt-stderr*"))
         (proc (make-process
                :name "metal-butt"
                :buffer stdout
                :stderr stderr
                :noquery t
                :connection-type 'pipe
                :command (cons metal-butt-executable
                               (metal-butt-transport-argv session-id))
                :sentinel
                (lambda (proc _event)
                  (when (memq (process-status proc) '(exit signal))
                    (let ((out (with-current-buffer stdout (buffer-string)))
                          (err (with-current-buffer stderr (buffer-string)))
                          (code (process-exit-status proc)))
                      (kill-buffer stdout)
                      (kill-buffer stderr)
                      (if (zerop code)
                          (condition-case e
                              (funcall callback (metal-butt-transport--extract-result out) nil)
                            (metal-butt-transport-error
                             (funcall callback nil (cadr e))))
                        (funcall callback nil
                                 (metal-butt-transport--classify-error
                                  (if (string-empty-p err) out err))))))))))
    (process-send-string proc request)
    (process-send-eof proc)
    proc))

(defvar metal-butt-transport-function #'metal-butt-transport--run
  "Function used to reach Claude.
Called as (FN REQUEST SESSION-ID CALLBACK).  Rebind in tests.")

(defun metal-butt-transport-send (request session-id callback)
  "Send REQUEST for SESSION-ID via `metal-butt-transport-function'."
  (funcall metal-butt-transport-function request session-id callback))

(provide 'metal-butt-transport)
;;; metal-butt-transport.el ends here
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 51 tests total.

- [ ] **Step 5: Verify the `--resume` fallback question empirically**

This resolves open question 1 from the spec. Run **once**, by hand, with a cheap model:

```bash
cd /tmp && mkdir -p mb-probe && cd mb-probe && git init -q 2>/dev/null
claude -p --model haiku --resume 99999999-9999-5999-8999-999999999999 \
  --output-format json 'say OK' ; echo "exit=$?"
```

If it fails, add a `--session-id` retry to `metal-butt-transport--run`: on a
first-use failure whose stderr mentions the session not being found, re-run with
`--session-id` substituted for `--resume`. Add this test alongside it:

```elisp
(ert-deftest metal-butt-transport-argv-can-create-a-session ()
  (let ((argv (metal-butt-transport-argv "x" 'create)))
    (should (member "--session-id" argv))
    (should-not (member "--resume" argv))))
```

If it succeeds, note in the commit message that `--resume` creates missing
sessions and no fallback is needed.

- [ ] **Step 6: Commit**

```bash
git add metal-butt-transport.el tests/metal-butt-transport-test.el
git commit -m "Add claude CLI transport behind an injectable interface

Everything decidable is a pure function, so argv construction, result
extraction and error diagnosis are all tested without invoking the CLI.
Requests go over stdin because they carry whole buffers.

IAM denials are reported with the offending policy named, and never
retried on a cheaper model: a silent downgrade changes edit quality
without the user knowing why."
```

---

### Task 7: Edit application with accept/reject overlay

**Files:**
- Create: `metal-butt-overlay.el`
- Test: `tests/metal-butt-overlay-test.el`

**Interfaces:**
- Consumes: nothing.
- Produces: `(metal-butt-overlay-locate OLD)` → buffer position of the unique match; signals `metal-butt-overlay-no-match` or `metal-butt-overlay-ambiguous`.
- Produces: `(metal-butt-overlay-propose EDIT)` → shows the proposal; `EDIT` is the plist from Task 2.
- Produces: commands `metal-butt-accept`, `metal-butt-reject`.
- Produces: `(metal-butt-overlay-pending-p)` → boolean.

- [ ] **Step 1: Write the failing test**

`tests/metal-butt-overlay-test.el`:

```elisp
;;; metal-butt-overlay-test.el --- Tests for edit overlays  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-overlay)

(ert-deftest metal-butt-overlay-locates-unique-match ()
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (should (= (metal-butt-overlay-locate "beta") 7))))

(ert-deftest metal-butt-overlay-rejects-missing-match ()
  (with-temp-buffer
    (insert "alpha\n")
    (should-error (metal-butt-overlay-locate "zeta")
                  :type 'metal-butt-overlay-no-match)))

(ert-deftest metal-butt-overlay-rejects-ambiguous-match ()
  "Never guess which occurrence was meant."
  (with-temp-buffer
    (insert "dup\ndup\n")
    (should-error (metal-butt-overlay-locate "dup")
                  :type 'metal-butt-overlay-ambiguous)))

(ert-deftest metal-butt-overlay-accept-replaces-text ()
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (metal-butt-overlay-propose '(:old "beta" :new "BETA" :why "louder"))
    (metal-butt-accept)
    (should (equal (buffer-string) "alpha\nBETA\ngamma\n"))))

(ert-deftest metal-butt-overlay-reject-leaves-buffer-untouched ()
  (with-temp-buffer
    (insert "alpha\nbeta\n")
    (metal-butt-overlay-propose '(:old "beta" :new "BETA"))
    (metal-butt-reject)
    (should (equal (buffer-string) "alpha\nbeta\n"))))

(ert-deftest metal-butt-overlay-reject-clears-pending-state ()
  (with-temp-buffer
    (insert "alpha\n")
    (metal-butt-overlay-propose '(:old "alpha" :new "ALPHA"))
    (should (metal-butt-overlay-pending-p))
    (metal-butt-reject)
    (should-not (metal-butt-overlay-pending-p))))

(ert-deftest metal-butt-overlay-accept-applies-edits-in-sequence ()
  (with-temp-buffer
    (insert "one\ntwo\n")
    (metal-butt-overlay-propose-all
     '((:old "one" :new "1") (:old "two" :new "2")))
    (metal-butt-accept)
    (metal-butt-accept)
    (should (equal (buffer-string) "1\n2\n"))))

(ert-deftest metal-butt-overlay-accept-without-proposal-is-an-error ()
  (with-temp-buffer
    (should-error (metal-butt-accept))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `Cannot open load file: metal-butt-overlay`

- [ ] **Step 3: Write the implementation**

`metal-butt-overlay.el`:

```elisp
;;; metal-butt-overlay.el --- Review proposed edits before applying  -*- lexical-binding: t; -*-

;;; Commentary:
;; Edits arrive as string pairs rather than line numbers, because line numbers
;; go stale the moment anything above the target is typed.  An `old' that does
;; not match exactly once is refused rather than guessed at.

;;; Code:

(define-error 'metal-butt-overlay-no-match
  "Proposed edit does not match the buffer")
(define-error 'metal-butt-overlay-ambiguous
  "Proposed edit matches the buffer in more than one place")

(defvar-local metal-butt-overlay--overlay nil)
(defvar-local metal-butt-overlay--queue nil)
(defvar-local metal-butt-overlay--current nil)

(defface metal-butt-overlay-face
  '((t :inherit diff-refine-added))
  "Face for a proposed edit awaiting review."
  :group 'metal-butt)

(defun metal-butt-overlay-locate (old)
  "Return the position of the unique occurrence of OLD in the buffer."
  (save-excursion
    (goto-char (point-min))
    (if (not (search-forward old nil t))
        (signal 'metal-butt-overlay-no-match
                (list (format "no match for: %s" (truncate-string-to-width old 60))))
      (let ((first (match-beginning 0)))
        (if (search-forward old nil t)
            (signal 'metal-butt-overlay-ambiguous
                    (list (format "%s matches more than once"
                                  (truncate-string-to-width old 60))))
          first)))))

(defun metal-butt-overlay-pending-p ()
  "Non-nil when an edit is awaiting accept or reject."
  (and metal-butt-overlay--current t))

(defun metal-butt-overlay--clear ()
  (when (overlayp metal-butt-overlay--overlay)
    (delete-overlay metal-butt-overlay--overlay))
  (setq metal-butt-overlay--overlay nil
        metal-butt-overlay--current nil))

(defun metal-butt-overlay-propose (edit)
  "Show EDIT for review."
  (let* ((old (plist-get edit :old))
         (pos (metal-butt-overlay-locate old))
         (ov (make-overlay pos (+ pos (length old)))))
    (overlay-put ov 'face 'metal-butt-overlay-face)
    (overlay-put ov 'after-string
                 (propertize (format " → %s" (plist-get edit :new))
                             'face 'metal-butt-overlay-face))
    (setq metal-butt-overlay--overlay ov
          metal-butt-overlay--current edit)
    (goto-char pos)
    (message "%s  (C-c C-a accept, C-c C-r reject)"
             (or (plist-get edit :why) "Proposed edit"))))

(defun metal-butt-overlay-propose-all (edits)
  "Queue EDITS for review, showing the first."
  (setq metal-butt-overlay--queue (cdr edits))
  (metal-butt-overlay-propose (car edits)))

(defun metal-butt-overlay--next ()
  (if metal-butt-overlay--queue
      (let ((next (pop metal-butt-overlay--queue)))
        (metal-butt-overlay-propose next))
    (message "No more proposed edits")))

(defun metal-butt-accept ()
  "Apply the proposed edit."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to accept"))
  (let* ((edit metal-butt-overlay--current)
         (ov metal-butt-overlay--overlay)
         (beg (overlay-start ov))
         (end (overlay-end ov)))
    (metal-butt-overlay--clear)
    (save-excursion
      (goto-char beg)
      (delete-region beg end)
      (insert (plist-get edit :new)))
    (metal-butt-overlay--next)))

(defun metal-butt-reject ()
  "Discard the proposed edit."
  (interactive)
  (unless (metal-butt-overlay-pending-p)
    (error "No proposed edit to reject"))
  (metal-butt-overlay--clear)
  (metal-butt-overlay--next))

(provide 'metal-butt-overlay)
;;; metal-butt-overlay.el ends here
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 59 tests total. Note the position `7` in the first test assumes `"alpha\n"` is 6 characters and buffer positions are 1-based.

- [ ] **Step 5: Commit**

```bash
git add metal-butt-overlay.el tests/metal-butt-overlay-test.el
git commit -m "Review proposed edits with an accept/reject overlay

Locate edits by unique string match. Zero matches or several matches are
both refused, because guessing which occurrence was meant is how a tool
like this corrupts a buffer."
```

---

### Task 8: Reply insertion as a comment block

**Files:**
- Create: `metal-butt-comment.el`
- Test: `tests/metal-butt-comment-test.el`

**Interfaces:**
- Consumes: nothing.
- Produces: `(metal-butt-comment-insert TEXT POSITION)` → inserts TEXT at POSITION as comment lines in the current buffer's syntax.

Insertion uses `comment-start` (unlike detection in Task 1), because here we want the mode's own idea of how to write a comment.

- [ ] **Step 1: Write the failing test**

`tests/metal-butt-comment-test.el`:

```elisp
;;; metal-butt-comment-test.el --- Tests for reply insertion  -*- lexical-binding: t; -*-
(require 'ert)
(require 'metal-butt-comment)

(ert-deftest metal-butt-comment-inserts-in-elisp-syntax ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun f ())\n")
    (metal-butt-comment-insert "callers pass nil" (point-max))
    (should (string-match-p "^;+ *callers pass nil" (buffer-string)))))

(ert-deftest metal-butt-comment-inserts-in-shell-syntax ()
  (with-temp-buffer
    (sh-mode)
    (insert "echo hi\n")
    (metal-butt-comment-insert "quote that" (point-max))
    (should (string-match-p "^# *quote that" (buffer-string)))))

(ert-deftest metal-butt-comment-comments-every-line ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (metal-butt-comment-insert "first\nsecond" (point-max))
    (let ((lines (seq-filter (lambda (l) (not (string-empty-p l)))
                             (split-string (buffer-string) "\n"))))
      (should (= 2 (length lines)))
      (should (seq-every-p (lambda (l) (string-prefix-p ";" (string-trim-left l)))
                          lines)))))

(ert-deftest metal-butt-comment-does-not-disturb-existing-text ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun f ())\n")
    (metal-butt-comment-insert "note" (point-max))
    (should (string-prefix-p "(defun f ())\n" (buffer-string)))))

(ert-deftest metal-butt-comment-returns-end-position ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (should (> (metal-butt-comment-insert "note" (point-max)) 1))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `Cannot open load file: metal-butt-comment`

- [ ] **Step 3: Write the implementation**

`metal-butt-comment.el`:

```elisp
;;; metal-butt-comment.el --- Insert an answer as a comment block  -*- lexical-binding: t; -*-

;;; Commentary:
;; Answers that are discussion rather than a change get written into the
;; buffer as comments, so the conversation lives next to the code it is about.

;;; Code:

(defun metal-butt-comment-insert (text position)
  "Insert TEXT at POSITION as comment lines.  Return the end position."
  (save-excursion
    (goto-char position)
    (unless (bolp) (insert "\n"))
    (let ((beg (point)))
      (insert (string-trim-right text) "\n")
      (comment-region beg (point))
      (point))))

(provide 'metal-butt-comment)
;;; metal-butt-comment.el ends here
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 64 tests total. If `sh-mode` emits a deprecation warning under Emacs 30, switch that test to `bash-ts-mode` only if `sh-mode` genuinely fails; a warning is acceptable.

- [ ] **Step 5: Commit**

```bash
git add metal-butt-comment.el tests/metal-butt-comment-test.el
git commit -m "Insert non-edit answers as comment blocks

Uses comment-region so each major mode writes comments its own way."
```

---

### Task 9: Orchestration, minor mode, staleness and in-flight guards

**Files:**
- Create: `metal-butt.el`
- Test: `tests/metal-butt-test.el`

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces: `metal-butt-mode` (minor mode), `metal-butt-mode-map` with `C-c b`, `C-c C-a`, `C-c C-r`.
- Produces: command `metal-butt-send-prompt`.
- Produces: `(metal-butt-repo-root)` → repo root or signals.
- Produces: `metal-butt--last-cost` (buffer-local) for the modeline.

- [ ] **Step 1: Write the failing test**

`tests/metal-butt-test.el`:

```elisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `Cannot open load file: metal-butt`

- [ ] **Step 3: Write the implementation**

`metal-butt.el`:

```elisp
;;; metal-butt.el --- Pair programming with Claude from Emacs buffers  -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:
;; Type a prompt in your buffer's own comment syntax and press C-c b:
;;
;;   // claude: extract this into a helper
;;   // and add a test for the empty case
;;
;; Code edits come back as an accept/reject overlay; discussion comes back
;; as a comment block.  Claude never writes to disk.

;;; Code:

(require 'cl-lib)
(require 'metal-butt-prompt)
(require 'metal-butt-context)
(require 'metal-butt-transport)
(require 'metal-butt-response)
(require 'metal-butt-overlay)
(require 'metal-butt-comment)
(require 'metal-butt-session)
(require 'metal-butt-handoff)

(defcustom metal-butt-delete-prompt-after-send nil
  "When non-nil, remove the prompt comment once it has been answered."
  :type 'boolean
  :group 'metal-butt)

(defvar-local metal-butt--in-flight nil)
(defvar-local metal-butt--last-cost 0)
(defvar-local metal-butt--last-input-tokens 0)

(defun metal-butt-repo-root ()
  "Return the top-level directory of the current repository."
  (or (locate-dominating-file (or default-directory "") ".git")
      (error "Not inside a git repository")))

(defun metal-butt--apply (response prompt)
  "Apply RESPONSE for PROMPT in the current buffer."
  (pcase (plist-get response :kind)
    ('reply
     (metal-butt-comment-insert (plist-get response :text)
                                (marker-position (plist-get prompt :end))))
    ('edit
     (metal-butt-overlay-propose-all (plist-get response :edits))))
  (when (and metal-butt-delete-prompt-after-send
             (eq (plist-get response :kind) 'reply))
    (delete-region (plist-get prompt :start) (plist-get prompt :end))))

(defun metal-butt--handle (buffer prompt tick result error)
  "Handle RESULT or ERROR for PROMPT sent from BUFFER at modification TICK."
  (with-current-buffer buffer
    (setq metal-butt--in-flight nil)
    (cond
     (error (message "Metal Butt: %s" error))
     ((/= tick (buffer-chars-modified-tick))
      (message "Metal Butt: buffer changed while the request was in flight; response discarded"))
     (t
      (setq metal-butt--last-cost (plist-get result :cost)
            metal-butt--last-input-tokens (plist-get result :input-tokens))
      (condition-case e
          (metal-butt--apply (metal-butt-response-parse (plist-get result :text)) prompt)
        (metal-butt-response-invalid (message "Metal Butt: %s" (cadr e)))
        (metal-butt-overlay-no-match (message "Metal Butt: %s" (cadr e)))
        (metal-butt-overlay-ambiguous (message "Metal Butt: %s" (cadr e))))
      (force-mode-line-update)))))

(defun metal-butt-send-prompt ()
  "Send the `claude:' comment block at or above point."
  (interactive)
  (when metal-butt--in-flight
    (error "Metal Butt: a request is already in flight for this buffer"))
  (let ((prompt (or (metal-butt-prompt-at-point)
                    (error "Metal Butt: no `%s:' comment block at point"
                           metal-butt-attention-word)))
        (root (metal-butt-repo-root)))
    (let ((request (metal-butt-context-build (plist-get prompt :text) root))
          (tick (buffer-chars-modified-tick))
          (buffer (current-buffer)))
      (setq metal-butt--in-flight t)
      (message "Metal Butt: thinking...")
      (metal-butt-transport-send
       request
       (metal-butt-session-current-id root)
       (lambda (result error)
         (metal-butt--handle buffer prompt tick result error))))))

(defvar metal-butt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c b") #'metal-butt-send-prompt)
    (define-key map (kbd "C-c C-a") #'metal-butt-accept)
    (define-key map (kbd "C-c C-r") #'metal-butt-reject)
    map)
  "Keymap for `metal-butt-mode'.")

;;;###autoload
(define-minor-mode metal-butt-mode
  "Prompt Claude from this buffer's comments."
  :lighter (:eval (if (> metal-butt--last-cost 0)
                      (format " MB $%.4f" metal-butt--last-cost)
                    " MB"))
  :keymap metal-butt-mode-map)

(provide 'metal-butt)
;;; metal-butt.el ends here
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 73 tests total.

- [ ] **Step 5: Verify clean byte-compilation of the whole package**

Run: `make clean && make compile`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add metal-butt.el tests/metal-butt-test.el
git commit -m "Wire the pipeline together behind C-c b

Guards that make this usable rather than merely working: one request in
flight per buffer, and a response whose buffer changed underneath it is
discarded rather than applied to text it was not computed against.

Per-prompt cost shows in the lighter, since the budget is the binding
constraint on using this at all."
```

---

### Task 10: Session rolling

**Files:**
- Modify: `metal-butt-session.el` (append)
- Modify: `metal-butt.el` (record tokens, offer the roll)
- Test: `tests/metal-butt-roll-test.el`

**Interfaces:**
- Consumes: `metal-butt-session-bump-generation`, `metal-butt-handoff-append`, `metal-butt-handoff-consume`, `metal-butt-transport-send`.
- Produces: `metal-butt-roll-threshold` (defcustom, default 60000 — provisional).
- Produces: `(metal-butt-session-should-roll-p INPUT-TOKENS)` → boolean.
- Produces: command `metal-butt-roll-session`.
- Produces: `metal-butt-session-roll-prompt` (constant).

- [ ] **Step 1: Write the failing test**

`tests/metal-butt-roll-test.el`:

```elisp
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make check`
Expected: FAIL — `void-function metal-butt-session-should-roll-p`

- [ ] **Step 3: Append the implementation to `metal-butt-session.el`**

Insert before the closing `(provide 'metal-butt-session)`:

```elisp
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
  (metal-butt-transport-send
   metal-butt-session-roll-prompt
   (metal-butt-session-current-id repo-root)
   (lambda (result error)
     (if error
         (message "Metal Butt: roll aborted, session left alone (%s)" error)
       (metal-butt-handoff-append repo-root 'self-handoff (plist-get result :text))
       (let ((generation (metal-butt-session-bump-generation repo-root)))
         (message "Metal Butt: rolled to generation %d" generation))))))
```

Note the ordering in the success branch: the handoff is written *before* the
generation is bumped, so a failure between the two leaves a recoverable note
rather than a new session with nothing to seed it.

- [ ] **Step 4: Wire the roll offer into `metal-butt.el`**

In `metal-butt--handle`, replace the `force-mode-line-update` line with:

```elisp
      (force-mode-line-update)
      (when (metal-butt-session-should-roll-p metal-butt--last-input-tokens)
        (message "Metal Butt: context is large (%d input tokens); M-x metal-butt-roll-session"
                 metal-butt--last-input-tokens))
```

Then add the interactive command before `metal-butt-mode-map`:

```elisp
(defun metal-butt-roll-session ()
  "Summarise this session into a handoff note and start a fresh generation."
  (interactive)
  (metal-butt-session-roll (metal-butt-repo-root)))
```

The roll is *offered*, never automatic: it costs a full-context call, so the
decision belongs to the user.

- [ ] **Step 5: Run tests to verify they pass**

Run: `make check`
Expected: PASS, 80 tests total.

- [ ] **Step 6: Commit**

```bash
git add metal-butt-session.el metal-butt.el tests/metal-butt-roll-test.el
git commit -m "Roll sessions instead of letting context grow unbounded

Ask the session for a self-handoff, write it, then bump the generation so
the next session id is fresh. Handoff is written before the bump, so a
failure between the two leaves a recoverable note rather than an unseeded
session.

The roll is offered rather than automatic: it discards a cached prefix
and pays for a full-context summarisation, so it is not always a win."
```

---

### Task 11: Terminal-side slash commands, README, and manual smoke test

**Files:**
- Create: `.claude/commands/handoff.md`
- Create: `.claude/commands/sync.md`
- Create: `README.md`

**Interfaces:**
- Consumes: the handoff file layout from Task 4.
- Produces: nothing the elisp calls; these are the terminal half of the handoff.

- [ ] **Step 1: Write the handoff slash command**

`.claude/commands/handoff.md`:

```markdown
---
description: Hand the current context over to the Emacs buffer session
---

Append a handoff note to `.claude/metal-butt/to-emacs.md`, creating the
directory if needed. Do not overwrite the file — append to it.

The note is read by a separate Claude session that is answering prompts from
Emacs buffers and knows nothing about this conversation. Write for that reader.

Include, under a `## <today's date and time>` heading:

- What we are working on right now.
- Decisions we have made and the reasoning behind them, especially any the code
  does not make obvious.
- Files we have touched and what changed in each.
- Corrections the user gave me that I should not repeat.
- Open threads and what the next step is.

Be specific and concrete. Skip anything the reader can see for themselves by
reading the code. Prose, not JSON.
```

- [ ] **Step 2: Write the sync slash command**

`.claude/commands/sync.md`:

```markdown
---
description: Catch up on work done in Emacs buffers since we last synced
---

Read `.claude/metal-butt/to-terminal.md` if it exists. It is an append-only log
written by the Claude session that answers prompts from Emacs buffers.

Read the whole file, then tell me in a few sentences what changed while I was
working in the editor — specifically anything that invalidates an assumption
from earlier in our conversation. My picture of the code may be stale, so say so
plainly if it is.

If the file does not exist or is empty, say so and do nothing else.
```

- [ ] **Step 3: Write the README**

`README.md`:

```markdown
# Metal Butt

Pair programming with Claude from inside Emacs buffers.

Type a prompt in your buffer's own comment syntax and press `C-c b`:

```c
// claude: extract this into a helper
// and add a test for the empty case
```

Code edits come back as an accept/reject overlay. Discussion comes back as a
comment block under your prompt. Claude never writes to disk — your buffer is
the source of truth, so unsaved changes are safe.

## Requirements

- Emacs 30.1+
- The `claude` CLI on `PATH`
- A git repository (state lives under `<repo-root>/.claude/metal-butt/`)

No external Elisp packages.

## Install

```elisp
(add-to-list 'load-path "/path/to/santas-metal-butted-little-helpers")
(require 'metal-butt)
(add-hook 'prog-mode-hook #'metal-butt-mode)
```

## Keys

| Key | Command |
|---|---|
| `C-c b` | Send the `claude:` block at or above point |
| `C-c C-a` | Accept the proposed edit |
| `C-c C-r` | Reject the proposed edit |

`C-c b` rather than `C-c C-c`, which is already `comment-region` in `c-mode`
and `python-shell-send-buffer` in `python-mode`.

## Sharing context with a terminal session

The buffer session and your terminal session are separate conversations. They
share understanding through append-only files rather than a shared transcript,
because a curated note is cheaper and higher signal than a replayed
conversation:

- In the terminal, `/handoff` writes what the buffer session needs to know.
- In the terminal, `/sync` catches you up on what happened in the editor.
- The buffer session picks up pending notes on your next `C-c b`.

## Cost

The mode line shows what each prompt cost. When the session's context gets
large, `M-x metal-butt-roll-session` summarises it into a handoff note and
starts a fresh session. Rolling is never automatic: it throws away a cached
prefix and pays for a summarisation call, so it is not always cheaper.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `metal-butt-model` | `"sonnet"` | Model for buffer prompts |
| `metal-butt-fallback-model` | `nil` | Leave nil; a silent downgrade hides why quality dropped |
| `metal-butt-attention-word` | `"claude"` | Word before the colon |
| `metal-butt-max-buffer-chars` | `20000` | Larger buffers send a window around point |
| `metal-butt-roll-threshold` | `60000` | Input tokens before offering a roll |
| `metal-butt-delete-prompt-after-send` | `nil` | Remove the prompt comment once answered |

## Tests

```sh
make check      # ERT suite, no API calls
make compile    # byte-compile, warnings are errors
```

The transport is injectable, so the whole pipeline is tested against a stub and
the suite costs nothing to run.
```

- [ ] **Step 4: Run the full suite and byte-compile**

Run: `make clean && make check && make compile`
Expected: 80 tests passing, byte-compilation silent.

- [ ] **Step 5: Manual smoke test**

This is the first step that spends money. It needs `metal-butt-model` to be
reachable — if Sonnet is still denied by IAM, either fix the policy or set
`metal-butt-model` to `"haiku"` for this test only.

```
emacs -Q -L . -l metal-butt.el
```

In the scratch buffer: `M-x cd` to a git repo, `M-x prog-mode`,
`M-x metal-butt-mode`, then type `// claude: what file am I in?` and press
`C-c b`. Expect a comment block answer and a cost in the mode line.

Then verify the edit path: type `// claude: rename the variable x to count`
above a line containing `int x = 1;` and press `C-c b`. Expect an overlay, and
expect the buffer to be unchanged until you press `C-c C-a`.

- [ ] **Step 6: Commit**

```bash
git add .claude/commands/handoff.md .claude/commands/sync.md README.md
git commit -m "Add terminal-side handoff commands and README

/handoff writes what the buffer session needs; /sync catches the terminal
session up on editor work and warns that its picture may be stale."
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: prompt detection → 1;
response contract → 2; session identity and the generation counter → 3; handoff
channels and offsets → 4; context assembly and buffer truncation → 5; transport,
argv, model policy and auth diagnosis → 6; unique-match edits and the overlay →
7; comment replies → 8; keybinding, staleness, single-in-flight and the cost
lighter → 9; session rolling → 10; slash commands and docs → 11. The four spec
failure-handling rows are tested in Tasks 4, 6, 7 and 9. Spec open question 1
(`--resume` on a missing id) is resolved in Task 6 Step 5; question 2 (permission
hangs) surfaces in the Task 11 smoke test and has a documented
`--allowedTools` fallback; question 3 (roll threshold) ships provisional by
design; question 4 (prompt survival) is `metal-butt-delete-prompt-after-send`.

**Naming consistency.** `metal-butt-prompt-at-point` returns `(:text :start
:end)`, consumed unchanged in Task 9. Edit plists are `(:old :new :why)` from
Task 2 through Tasks 7 and 9. Transport results are `(:text :cost
:input-tokens)` from Task 6 through Tasks 9 and 10. Handoff channels are the
symbols `to-emacs`, `to-terminal`, `self-handoff` throughout. `metal-butt-repo-root`
is defined in Task 9 and stubbed by name in its own tests.

**Known ordering constraint.** `metal-butt-session.el` gains functions in Task 10
that call into `metal-butt-handoff` and `metal-butt-transport`, which would be a
circular require — hence `declare-function` rather than `require` there, with
`metal-butt.el` loading all three.
