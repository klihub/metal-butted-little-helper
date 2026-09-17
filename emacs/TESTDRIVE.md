# Metal Butt — test drive

Pair programming with Claude from inside Emacs buffers. Type a prompt in your
buffer's own comment syntax, press `C-c b`, and get back either a reviewable
edit or a written answer.

This file is the state of things as of the overnight build. `README.md` (Task 11)
supersedes it once written.

## Before your first C-c b — read this one thing

`metal-butt-model` defaults to `"sonnet"`, and **Sonnet is currently denied on
your Bedrock account** by an explicit `Deny` in the `BedrockMinimalInferenceAccess`
IAM policy. Your first prompt will come back as a 403 unless you either:

- amend that policy — remember an explicit `Deny` cannot be overridden by adding
  an `Allow`, and `us.anthropic.*` are cross-region inference profiles, so you
  need permission on the underlying foundation-model ARNs in every destination
  region, not just the profile; **or**
- set `(setq metal-butt-model "haiku")` for the test drive.

The transport reports this failure by name — it will tell you the model and the
denying policy rather than failing vaguely — and it deliberately does **not**
silently retry on a cheaper model, because a quiet downgrade would change edit
quality without telling you why.

## Install

```elisp
(add-to-list 'load-path "/u/src/kli/santas-metal-butted-little-helpers")
(require 'metal-butt)
(add-hook 'prog-mode-hook #'metal-butt-mode)
```

Or, to try it without touching your config:

```sh
cd /u/src/kli/santas-metal-butted-little-helpers
emacs -Q -L . -l metal-butt.el
```

Requires Emacs 30.1+ (you have 30.2), the `claude` CLI on `PATH`, and a git
repository — state lives under `<repo-root>/.claude/metal-butt/`. No external
Elisp packages.

## Try it

In a file inside any git repo, with `metal-butt-mode` on:

```c
// claude: what does this function do?
```

Put point on or below that line and press `C-c b`. The answer arrives as a
comment block beneath it, and the mode line shows what the prompt cost.

Then try an edit:

```c
// claude: rename x to count
int x = 1;
```

`C-c b` proposes the change as an overlay. **The buffer is not modified until you
press `C-c C-a`.** `C-c C-r` rejects it.

| Key | Does |
|---|---|
| `C-c b` | Send the `claude:` block at or above point |
| `C-c C-a` | Accept the proposed edit |
| `C-c C-r` | Reject it |

`C-c b` rather than `C-c C-c`, which is already `comment-region` in `c-mode` and
`python-shell-send-buffer` in `python-mode`.

## What works right now

Tasks 1–9 of 11 are complete, each reviewed and committed:

- Prompt detection in any comment syntax (`//`, `#`, `;;`, `--`), case-insensitive,
  multi-line prompts, finding the **nearest** prompt at or above point.
- Structured edit/reply responses, with malformed responses reported rather than
  half-applied.
- Deterministic per-repo session ids, so buffer prompts share one conversation
  with each other. First use of a fresh repo creates the session automatically.
- Append-only handoff files for sharing context with a terminal session.
- Accept/reject overlays; an edit whose target text no longer matches is refused
  rather than guessed at, and a stale edit in a multi-edit response is skipped
  with a message rather than stranding the rest.
- Answers inserted as comments in the buffer's own syntax.
- Guards: one request in flight per buffer, and a response is discarded if you
  changed the buffer while it was in flight.

## What is not done yet

- **Task 10 — session rolling.** `M-x metal-butt-roll-session` and the
  `metal-butt-roll-threshold` warning do not exist yet, so a long-lived buffer
  session's context will grow unbounded. Watch the cost in the mode line.
- **Task 11 — terminal-side handoff.** The `/handoff` and `/sync` slash commands
  are not written, so the Emacs side can read handoff files but nothing writes
  them from the terminal yet. `README.md` also lands in this task.

## Tests

```sh
make check      # 84 tests, zero API calls, costs nothing
make compile    # byte-compile, warnings are errors
```

The transport sits behind an injectable interface, so the whole pipeline is
exercised against a stub. Running the suite never spends money.

## Things I decided while you slept

Read `.superpowers/sdd/2026-09-17-metal-butt/progress.md` — every ruling I made
on your behalf is in there with what it costs if I got it wrong. The one most
worth your attention is **Ruling 11**: I changed already-reviewed prompt-detection
code so that a prompt is found up to 20 lines above point instead of exactly one,
because the alternative was a tool that only worked when your point sat one line
below your prompt. The bound is `metal-butt-prompt-search-limit` if you want it
different.
