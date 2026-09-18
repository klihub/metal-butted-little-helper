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

## Authentication — Emacs may not have your shell's environment

Nothing about authentication is special to this package: it spawns `claude` and
the CLI authenticates exactly as it does in your terminal. The catch is *whose*
environment it inherits. `make-process` gives the child Emacs's environment, and
GUI Emacs started from a desktop launcher or a systemd user session does not
source `~/.bashrc` or `~/.profile`. So a setup that works perfectly in your
terminal can fail from a buffer.

On this machine the CLI is authenticated purely through environment variables,
with nothing on disk to fall back on — there is no `~/.aws/` directory:

| Variable | Why it matters |
|---|---|
| `AWS_BEARER_TOKEN_BEDROCK` | the actual credential |
| `CLAUDE_CODE_USE_BEDROCK` | without it the CLI targets the Anthropic API instead of Bedrock |
| `AWS_REGION` | which region to reach |

**Check from inside Emacs before blaming the package.** `M-:` and evaluate:

```elisp
(list (executable-find "claude")
      (and (getenv "AWS_BEARER_TOKEN_BEDROCK") t)
      (getenv "CLAUDE_CODE_USE_BEDROCK")
      (getenv "AWS_REGION"))
```

A `nil` anywhere is your problem. `claude` lives in `~/.local/bin`, which GUI
Emacs often omits from `exec-path`.

Fixes, cheapest first:

1. **Launch Emacs from a shell that already has the variables** — `emacs &` from
   your terminal. Nothing to install, and it is the fastest way to confirm the
   package itself works.
2. **Install `exec-path-from-shell`** and call `(exec-path-from-shell-initialize)`
   in your init. This is the durable fix for GUI Emacs. Note it is a dependency of
   *your config*, not of this package — Metal Butt itself still needs no external
   packages.
3. **Set `metal-butt-executable` to the absolute path** (`"/home/kli/.local/bin/claude"`).
   This solves only the PATH half, not the credential half.

**Do not paste the bearer token into your init file** if that file is version
controlled or shared. Prefer options 1 or 2, or read it from a mode-600 file.

Two further consequences worth knowing:

- **There is no TTY.** The child runs on a pipe, so the CLI cannot prompt you for
  anything interactively. If the token has expired, re-authenticate in a terminal
  first; from a buffer you will just get an auth error.
- **Bearer tokens expire.** When yours does, this will surface as an
  authentication failure mid-session rather than at startup, and the message will
  name the model and the failure rather than being vague about it.

A denied request is not fast. The CLI retries some failures with backoff, so an
authorization denial can take minutes to surface. `metal-butt-request-timeout`
(60 seconds by default) bounds that, so a slow failure is reported rather than
looking like a hang.

## Install

```elisp
(add-to-list 'load-path "/u/src/kli/santas-metal-butted-little-helpers/emacs")
(require 'metal-butt)
(add-hook 'prog-mode-hook #'metal-butt-mode)
```

Or, to try it without touching your config:

```sh
cd /u/src/kli/santas-metal-butted-little-helpers/emacs
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

**All 11 tasks are complete**, each reviewed and committed:

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

- Session rolling: `M-x metal-butt-roll-session` writes a self-handoff note and
  starts a fresh generation seeded from it, and you get a mode-line nudge once a
  response reports a large input-token count. Rolling is never automatic — it
  costs a full-context call, so it waits for you to ask.
- Terminal-side handoff: `/handoff` and `/sync` slash commands under
  `.claude/commands/`.

## What real use found

Confirmed working in a real editor on 2026-09-18: replies as comment blocks,
edits as overlays, accept, reject, and multi-line edits.

Two bugs surfaced on first use, both now fixed with tests pinning them:

- **Raw line breaks inside JSON strings.** The model writes a literal newline
  inside `old`/`new` when the quoted text spans lines, which is invalid JSON. Not
  an edge case — it is what happens for *any* edit longer than one line.
  Responses are now repaired before parsing; the transformation is a no-op on
  valid JSON, so it can only widen what parses.
- **No timeout.** The spec listed one and nothing implemented it. An
  authorization denial that the CLI retried with backoff took 190 seconds to
  surface, which was indistinguishable from a hang. Now bounded by
  `metal-butt-request-timeout`.

Markdown code fences around the JSON were already tolerated and were not the
problem. If a response ever comes back as genuine prose you will get a clear
refusal rather than a mangled buffer, and
`M-x metal-butt-show-last-exchange` shows the exact payload.

The likeliest thing still needing adjustment is contract wording — specifically
whether the model copies `old` character-for-character, including indentation.
A near-miss shows up as "no match for: …", which is the guard working.

## Open questions, parked

- **Per-word behaviour.** `metal-butt-attention-words` now takes a list of
  interchangeable aliases, but words still carry no meaning of their own —
  there is no way to say "answer, never edit". Deliberately deferred until real
  use shows which distinctions are actually wanted.

## Tests

```sh
make check      # 106 tests, zero API calls, costs nothing
make compile    # byte-compile, warnings are errors
```

The transport sits behind an injectable interface, so the whole pipeline is
exercised against a stub. Running the suite never spends money.

## Things I decided while you slept

**`docs/superpowers/2026-09-17-metal-butt-rulings.md`** — fifteen decisions taken
on your behalf, each with what it costs if I got it wrong. Three are worth your
attention, and all three are things you might reasonably reverse:

- I widened already-reviewed prompt detection so a prompt is found up to 20 lines
  above point rather than exactly one (`metal-butt-prompt-search-limit`).
- I deleted `metal-butt-fallback-model`, which the spec names, because nothing
  read it — setting it bought a silent no-op.
- I made a stale edit in a multi-edit response get skipped with a message rather
  than aborting the rest.
