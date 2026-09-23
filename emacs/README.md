# Metal Butt

Pair programming with Claude Code or GitHub Copilot CLI from inside Emacs
buffers.

Type a prompt in your buffer's own comment syntax and press `C-c b`:

```c
// claude: extract this into a helper
// and add a test for the empty case
```

Code edits come back as an accept/reject overlay. Discussion comes back as a
comment block under your prompt. Neither backend ever writes to disk — your
buffer is the source of truth, so unsaved changes are safe.

## Requirements

- Emacs 30.1+
- The `claude` CLI (default backend) or the `copilot` CLI, authenticated, on
  `exec-path`
- A git repository (state lives under `<repo-root>/.claude/metal-butt/`)

No external Elisp packages.

### Emacs must be able to see your CLI and its credentials

The spawned `claude` authenticates exactly as it does in your terminal, but it
inherits **Emacs's** environment — and GUI Emacs started from a desktop launcher
does not source your shell's rc files. So a setup that works in a terminal can
still fail from a buffer, either because `claude` is not on `exec-path` or
because the credential variables are absent.

Check with `M-:`:

```elisp
(list (executable-find "claude")
      (getenv "CLAUDE_CODE_USE_BEDROCK")   ; if you authenticate via Bedrock
      (getenv "AWS_REGION"))
```

If anything is `nil`: start Emacs from a shell that has the environment, use
`exec-path-from-shell`, or set `metal-butt-executable` to an absolute path. Avoid
putting a credential in a version-controlled init file.

The child process has no TTY, so the CLI cannot prompt interactively. If your
credentials have expired, refresh them in a terminal first.

## Install

```elisp
(add-to-list 'load-path "/path/to/santas-metal-butted-little-helpers/emacs")
(require 'metal-butt)
(add-hook 'prog-mode-hook #'metal-butt-mode)
```

## Keys

| Key | Command |
|---|---|
| `C-c b` | Send the `claude:` block at or above point |
| `C-c p` | Ask from the minibuffer, answer in its own window |
| `C-c e` | Explain the marked region — no minibuffer, no typing |
| `C-c C-p` | Ask a follow-up, continuing the last `C-c p`/`C-c e` conversation |
| `C-c C-a` | Accept the whole proposed edit (all remaining hunks) |
| `C-c C-r` | Reject the whole proposed edit (all remaining hunks) |
| `C-c h a` | Accept just the current hunk, then advance to the next |
| `C-c h r` | Reject just the current hunk, then advance to the next |
| `C-c C-d` | Toggle the current hunk between full-region and diff-style view |
| `C-c C-e` | Review every remaining proposed edit at once in Ediff |
| `C-c C-TAB` | Complete or write code at point (`'copilot-api` only) |
| `C-c TAB` | Toggle idle-triggered autocomplete for this buffer, off by default (prefix arg: adjust it instead) |
| `C-c m` | Set the model (prefix arg: this buffer only) |
| `C-c s` | Show backend, model, session id, and last-exchange status |
| `C-c t` | Retry the last prompt (prefix arg: choose a different model) |
| `C-c l` | Show the events log (`*metal-butt events*`) |

## Asking without editing the buffer

`C-c b` needs the question written into the buffer as a comment. When you would
rather not touch the file, `C-c p` reads it from the minibuffer instead:

- The answer opens in `*metal-butt-reply*`; `q` dismisses it. The code buffer is
  never modified.
- A proposed edit still arrives as an accept/reject overlay, as with `C-c b`.
- `M-p` recalls earlier questions.
- An `@model` token works here too: `@opus why is this nil?`
- Mark a region first and it travels with the question.

Once you've asked something with `C-c p`, `C-c C-p` (`metal-butt-ask-followup`)
lets you continue that same conversation: every earlier question and answer in
the chain is sent along as context, so "and what about the error case?" is
understood as a continuation instead of a fresh, unrelated question. Starting
a new question with `C-c p` resets the conversation, so the next `C-c C-p`
follows up on that new question instead of the old one. `metal-butt-ask-followup`
errors if there is no conversation yet — run `C-c p` first.

## Explaining a region without any minibuffer prompt

`C-c p` still needs a question typed into the minibuffer. For the common case
of "what does this do", `C-c e` (`metal-butt-explain-region`) skips that
entirely: mark a region and press the key. It sends the canned question in
`metal-butt-explain-region-prompt` (default: "Explain this code.") with the
region attached as context, exactly as `C-c p` attaches a marked region —
customise the prompt if you'd rather it ask something else by default.
Errors if no region is active. Like `C-c p`, it starts a fresh conversation,
so `C-c C-p` afterwards follows up on the explanation just given.

## Reviewing a proposed edit: full-region or diff style

A proposed edit is shown one of two ways, controlled by
`metal-butt-overlay-diff-style`:

- `full` (the default): the matched old text is highlighted in place with the
  new text appended after it as `→ new`. Compact, and easy to read for a
  short, single-line edit.
- `diff`: the old text is struck through and the new text shown on its own
  line prefixed with `+`, closer to how a unified diff hunk reads. Easier to
  follow for a multi-line edit, where `full` style's inline arrow can bury
  the change in a wall of text.

`C-c C-d` (`metal-butt-overlay-toggle-style`) flips the *current hunk*
between the two views without touching the buffer or changing the default —
the next hunk or edit proposed goes back to whatever
`metal-butt-overlay-diff-style` says.

## Accepting an edit hunk by hunk

When a proposed edit touches several disjoint spans of the buffer — a rename
across a handful of nearby lines, say — Metal Butt splits it into hunks, one
per contiguous changed span, and reviews them one at a time, magit
stage-hunk style:

- `C-c h a` (`metal-butt-overlay-accept-hunk`) applies just the hunk under
  review and moves on to the next one.
- `C-c h r` (`metal-butt-overlay-reject-hunk`) discards just that hunk and
  moves on.
- `C-c C-a` / `C-c C-r` still take the whole edit at once — every remaining
  hunk of the current edit is accepted or rejected in one step, which is all
  that ever happens for the common case of an edit with a single hunk.

The minibuffer message while a hunk is under review shows `(k/n hunks)`
once an edit has more than one, so you always know where you are in a
multi-hunk edit. Hunks are resolved strictly in order; once the last hunk of
an edit is resolved, review moves on to the next queued edit, if any.

## Reviewing the whole planned changeset at once with Ediff

The one-hunk-at-a-time flow above only ever shows you one change in
context. `C-c C-e` (`metal-butt-overlay-review-ediff`) instead builds a
scratch buffer holding what this buffer would look like if every
still-pending hunk of the edit under review, and every edit still queued
behind it, were fully accepted, then opens `ediff-buffers` between this
buffer and that scratch buffer — so the whole planned changeset is laid
out as one ordinary Ediff session, with its usual `n`/`p` to move between
diff regions, `b` to pull a region's proposed text into this buffer (`a`
does the reverse, restoring this buffer's own text in that region), and
either buffer can be hand-edited directly before moving on.

This buffer's own pending-hunk state is cleared the moment Ediff takes
over — Ediff, not the overlay queue, now owns deciding what happens to
the rest of this edit set — so `metal-butt-accept`/`metal-butt-reject`
and the per-hunk commands above no longer apply once you are in an Ediff
session. Quitting Ediff (`q`) kills the scratch buffer and leaves this
buffer holding whatever combination you chose.

## Completing code at point

`C-c C-TAB` (`metal-butt-complete-at-point`) asks the model to complete or
write code right where point is, and the proposal comes back through the
exact same review flow as any other proposed edit: accept/reject,
hunk-by-hunk, the full/diff style toggle, or the whole-changeset Ediff view
all work on it unchanged.

Only implemented for `metal-butt-backend` `'copilot-api` so far. Every other
request in the package resends the whole buffer (or a window around point)
on every single call, which is fine for an occasional ask or edit but would
make a completion command meant to be triggered often too slow and too
expensive: `'claude` and `'copilot` both shell out to a CLI that pays a
large, mostly fixed per-invocation cost (see "Backends" above), and neither
gives a way to hand it a growing, explicit conversation directly the way
`'copilot-api`'s `chat/completions` endpoint does. So this feature keeps its
own persistent, buffer-local chat session instead: the whole buffer is sent
only once, up front, and every later completion sends a compact unified
diff of what changed since the previous turn plus the current point,
relying on the model's own memory of the conversation for everything that
has not changed. That history is bounded by `metal-butt-complete-max-turns`
and `metal-butt-complete-max-history-chars`; once either limit is hit, the
next completion resyncs by resending the whole buffer and dropping
everything before it, the same trade `M-x metal-butt-roll-session` makes
for the ask/edit conversation, just automatic and local to this buffer.

```elisp
(setq metal-butt-backend 'copilot-api)
;; ... then, with point wherever you want code completed or written:
;; M-x metal-butt-complete-at-point, or C-c C-TAB
```

`C-c TAB` (`metal-butt-toggle-autocomplete`) turns on an idle-triggered
version of the same command for the current buffer — off by default
everywhere. Once on, an edit re-arms a `metal-butt-autocomplete-idle-delay`
(default 1 second) idle timer, and letting it expire fires
`metal-butt-complete-at-point` silently, proposing its result through the
exact same review flow as a manual completion. It never fires while a
request is already in flight, or while an earlier proposal (auto-triggered
or not) is still awaiting review, so it can never pile a second, unrequested
proposal on top of one you have not looked at yet.

With a prefix argument, `C-c TAB` prompts for one of two adjustments to a
*running* autocomplete instead of toggling it: "suppress until I type more"
pauses auto-triggering until the buffer actually changes again (not merely
until some time passes — handy for "not right now" without turning the
whole thing off), and "increase the idle delay" raises the delay for this
buffer only.

## Choosing a model

Per prompt, with a leading `@` token:

```c
// claude: @opus redesign this module
// claude: @haiku what does this do?
```

Per session, `C-c m` (or `M-x metal-butt-set-model`) reads a model with
completion; a prefix argument sets it for the current buffer only. Most specific
wins: an `@` token beats the buffer setting, which beats the global default. The
mode line shows which model is active.

## Backends

`metal-butt-backend` selects which CLI (or API) does the work: `'claude` (the
default), `'copilot`, or `'copilot-api`. All three speak the same JSON contract
described above, so overlays, comment replies, sessions and handoff files
behave identically either way — only the transport underneath differs.

```elisp
(setq metal-butt-backend 'copilot)
```

### `copilot-api`: talking to Copilot directly, without the CLI

The `copilot` CLI backend pays a large, mostly fixed per-invocation cost on
every non-interactive call — process startup, an update check, MCP server
discovery, tool schema loading — none of which buys anything here, since
metal-butt never lets the CLI use tools (`write` and `shell` are always
denied) and never relies on its session/context management (the whole buffer
is resent every call regardless of backend). Measured: ~7-8s wall time per
call, most of it before the model is even reached.

`metal-butt-backend` set to `'copilot-api` skips the CLI entirely and calls
GitHub's `chat/completions` endpoint directly over HTTPS, the same endpoint
the [`copilot-chat`](https://github.com/chep/copilot-chat.el) Emacs package
uses. Measured end-to-end latency: ~1-2s, a several-fold improvement, since
only the model call itself remains.

This backend has one prerequisite: it reuses the GitHub OAuth token already
cached by `copilot-chat` at `metal-butt-copilot-api-github-token-file`
(default `~/.config/copilot-chat/github-token`) rather than performing its
own login. Install `copilot-chat` and log in once (`M-x copilot-chat-login`
or equivalent), and this backend will pick up that token — there is no
separate login flow here. If that file does not exist, requests fail with an
error explaining exactly this.

```elisp
(setq metal-butt-backend 'copilot-api)
```

The trade-off: this backend has no CLI-side session, so `--session-id`/resume
does not apply to it (a non-issue in practice, since the whole buffer is
already resent every call), and it is a second, independent path to
Copilot's API that could break if GitHub changes the endpoint's shape —
whereas the `copilot` CLI backend is a supported, stable interface. Use
`copilot` if you want the officially supported path; use `copilot-api` if you
want the same model with much lower latency and are fine depending on an
undocumented endpoint copilot-chat already relies on.

By default (`metal-butt-copilot-api-stream` is `t`), this backend requests a
streaming response and, for `M-x metal-butt-ask` (which shows its answer in a
separate window rather than inserting it at point), shows the reply growing
live as chunks arrive instead of only appearing once the whole answer is
back. This is a perceived-latency improvement only: the underlying JSON
response contract still requires one complete, valid JSON document, so the
live preview shows a best-effort snippet of the `text` field as it streams in
and the final applied answer is always parsed from the fully-assembled
response, not the partial preview. Set `metal-butt-copilot-api-stream` to
`nil` to go back to waiting for the whole response before showing anything.

The Copilot API bearer token this backend exchanges the cached GitHub token
for is short-lived (~25 minutes) and, without any prefetching, is only
renewed lazily on the first request after it goes stale — so that first
request after an idle period pays the exchange's own latency on top of the
model call. To avoid that, a background timer refreshes the token shortly
before it expires (`metal-butt-copilot-api-token-prefetch-margin`, default
60 seconds), so requests almost always find an already-warm token. If the
background refresh fails for some reason (network blip, expired GitHub
token), it just logs a message — the next request's lazy renewal still
covers for it. Set `metal-butt-copilot-api-token-prefetch-margin` to `0` to
disable proactive refresh and go back to the old lazy-only behaviour.

When `copilot-api` itself is unavailable — no cached GitHub token file, the
token exchange failing to connect, or curl failing to reach the
chat/completions endpoint at all — a request automatically falls back to
the `copilot` CLI backend instead of erroring out, since the CLI needs no
separate GitHub token and is far less likely to be down for the same
reason at the same time. A one-time message notes the fallback happened;
it is not repeated on every subsequent request while the underlying
problem persists. This only covers backend-unavailability failures — a
genuine answer-level error (an unsupported model, a malformed response
body) still surfaces normally, since switching backends would not fix it.

Because this backend has no server-side session at all, the request body
is what carries all context, and the streamed response includes a `usage`
object (via `stream_options.include_usage`) just like the non-streaming
one, so `M-x metal-butt-status`'s input-token count and
`metal-butt-session-should-roll-p`'s "roll the session" nudge both work
the same way here as with the other backends, whether streaming is on or
off.

A few differences follow from the CLIs themselves, not from any choice made
here:

- **Each backend has its own default model, and its own catalog.**
  `metal-butt-claude-model` (default `"sonnet"`) and `metal-butt-copilot-model`
  (default `"claude-sonnet-5"`) are used automatically depending on
  `metal-butt-backend`, so switching backends does not leave you sending a
  Claude model name to the Copilot CLI or vice versa. `metal-butt-model`
  itself defaults to `nil` and is only an *override*: set it if you want a
  specific model regardless of backend. Completion candidates for `C-c m`
  come from whichever backend is active: `metal-butt-known-models` for
  `claude` (`"sonnet"`, `"opus"`, ...) or `metal-butt-copilot-known-models`
  for `copilot` (`"claude-sonnet-5"`, `"gpt-5.4"`, `"auto"`, ...). Setting a
  model unknown to Claude fails immediately, since a typo there becomes a
  wasted API call; the Copilot backend does not enforce its list locally,
  because the CLI's own catalog changes too often to hard-code — an invalid
  model still fails fast there, just inside the CLI instead of in Emacs.
- **No system-prompt flag.** Claude Code accepts `--append-system-prompt`, but
  the closest Copilot CLI equivalent (`.github/agents/<name>.md` +
  `--agent`) needs a file to exist in whatever repository the buffer belongs
  to, which would mean per-project setup. Instead, the Copilot backend
  prepends the same response contract to the request body sent on stdin. This
  costs a few extra tokens per call (mitigated by prompt caching) in exchange
  for working in any repository without setup, matching the Claude backend.
- **Tool permissions differ in shape.** Both backends deny file writes and
  shell execution unconditionally (`metal-butt-copilot-deny-tools`, default
  `("write" "shell")`, mirrors Claude's disallowed-tools list) — buffers stay
  the sole source of truth either way.
- **Cost is reported differently.** See [Cost](#cost) below.
- **`/handoff` and `/sync` need no changes.** Both slash commands live under
  `.claude/commands/` and are auto-discovered by the Copilot CLI as `md:`
  project skills, so a Copilot terminal session started in this repo already
  has `/handoff` and `/sync` available with no extra setup.

## Sharing context with a terminal session

The buffer session and your terminal session are separate conversations that
share understanding through append-only files:

- In the terminal, `/handoff` writes what the buffer session needs to know.
- In the terminal, `/sync` catches you up on what happened in the editor.
- The buffer session picks up pending notes on your next prompt.

A pending note is consumed only once a response has been applied, so a failed
request leaves it in place for next time.

### Installing the slash commands

The commands ship in this repo under `.claude/commands/`, so a terminal session
started here needs no setup. To use them in other projects, install them at user
level under a namespace:

```sh
mkdir -p ~/.claude/commands/mb
cp .claude/commands/handoff.md ~/.claude/commands/mb/handoff.md
cp .claude/commands/sync.md    ~/.claude/commands/mb/sync.md
```

A subdirectory becomes a namespace, giving `/mb:handoff` and `/mb:sync` in every
session on the machine. Each project still keeps its own handoff files, since the
commands address them relative to the session's working directory.

Alternatively, copy the two files into another project's own
`.claude/commands/` so the tooling travels with that repo.

Creating `~/.claude/commands` for the first time needs a session restart before
the commands appear; edits to files in a directory that already exists are picked
up mid-session.

## Cost

With the `claude` backend, the mode line shows what each prompt cost in
dollars. With the `copilot` backend, there is no dollar figure in the CLI's
output, so the mode line instead shows the accumulated premium-request count
for the last call (for example `2pr`). With `copilot-api`, the
`chat/completions` response has neither figure, so the mode line shows ` api`
instead as a reminder of which backend answered. Either way, when a session's
context gets large, `M-x metal-butt-roll-session` summarises it into a
handoff note and starts a fresh session. Rolling is never automatic — it
costs a full-context call, so the timing is yours to choose.

## Status, retry, and prompt history

`C-c s` (`metal-butt-status`) prints a one-line summary to the echo area:
active backend, effective model, current session id, whether a request is
in flight, the size of the running ask/follow-up conversation (once one has
started), and the cost/tokens/duration of the last exchange — the same
figures otherwise scattered across the mode line and
`M-x metal-butt-show-last-exchange`, gathered in one place.

`C-c t` (`metal-butt-retry`) resends the most recently sent prompt verbatim
— same text, same reply target, same conversation history if it was a
follow-up. Useful both to retry after a transient failure and, with a
prefix arg, to resend the same question to a different model for
comparison (`C-u C-c t` prompts for the model with completion). Errors if
nothing has been asked yet in this buffer.

`M-p` history for `C-c p` and `C-c C-p` is persisted to
`.claude/metal-butt/history` (see `metal-butt-history-max-entries`), so it
survives an Emacs restart instead of resetting to empty every session.

A chain of `C-c C-p` follow-ups resends every prior turn of that
conversation in full on each request, so an unbounded chain would make
every request larger than the last, indefinitely, regardless of backend.
`metal-butt-ask-conversation-max-turns` (default 12) bounds this by
dropping the oldest turn once the cap is reached, keeping the size of a
long back-and-forth roughly constant; `C-c s` shows the current count so
you can see it approaching the cap. This is independent of
`M-x metal-butt-roll-session`, which addresses growth from other sources
(a large buffer, a big handoff note) by starting an entirely fresh
session.

## Diagnosing problems: the events log

`C-c l` (`metal-butt-show-log`) opens `*metal-butt events*`, a persistent,
timestamped, append-only log of what Metal Butt actually did, kept
separately from the echo area (which only keeps the last message) and
`*Messages*` (which mixes in everything else Emacs and every other package
logs). One line is recorded for every request dispatched and every
result/error, regardless of backend, plus a few events that never
otherwise surface as a user-visible message: a `copilot-api` backend
falling back to the `copilot` CLI, and the outcome of `copilot-api`'s
background bearer-token refresh. The buffer is capped at
`metal-butt-log-max-chars`, dropping the oldest lines once exceeded, so it
stays bounded over a long Emacs session; set `metal-butt-log-enabled` to
nil to turn logging off entirely.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `metal-butt-backend` | `'claude` | Which backend to use: `'claude`, `'copilot`, or `'copilot-api` |
| `metal-butt-executable` | `"claude"` | Name or path of the Claude Code CLI |
| `metal-butt-copilot-executable` | `"copilot"` | Name or path of the Copilot CLI |
| `metal-butt-copilot-api-github-token-file` | `"~/.config/copilot-chat/github-token"` | GitHub token file reused from `copilot-chat`, for `'copilot-api` |
| `metal-butt-copilot-api-curl-program` | `"curl"` | Curl program used to reach the Copilot API directly |
| `metal-butt-copilot-api-stream` | `t` | Request a streaming response from `'copilot-api' and show it growing live in `M-x metal-butt-ask`'s window |
| `metal-butt-copilot-api-token-prefetch-margin` | `60` | Seconds before expiry that `'copilot-api` proactively refreshes its bearer token in the background; `0` disables it |
| `metal-butt-ask-conversation-max-turns` | `12` | Max turns kept in a `C-c p`/`C-c C-p` conversation before the oldest are dropped |
| `metal-butt-model` | `nil` | Explicit model override, regardless of backend; leave `nil` to use the active backend's default |
| `metal-butt-claude-model` | `"sonnet"` | Default model when `metal-butt-backend` is `'claude` |
| `metal-butt-copilot-model` | `"claude-sonnet-5"` | Default model when `metal-butt-backend` is `'copilot` or `'copilot-api` |
| `metal-butt-known-models` | `'("haiku" "sonnet" "opus" "fable")` | Accepted model names for `claude` |
| `metal-butt-copilot-known-models` | see source | Model names offered for completion for `copilot`/`copilot-api` (not enforced) |
| `metal-butt-copilot-deny-tools` | `'("write" "shell")` | Tool categories denied to the Copilot CLI backend |
| `metal-butt-request-timeout` | `60` | Seconds before a request is abandoned |
| `metal-butt-attention-words` | `'("claude" "mb" "metal-butt" "butty")` | Words that mark a comment as a prompt |
| `metal-butt-prompt-search-limit` | `20` | Lines above point to search for a prompt |
| `metal-butt-max-buffer-chars` | `20000` | Larger buffers send a window around point |
| `metal-butt-overlay-diff-style` | `'full` | How to render a proposed edit: `'full` (inline highlight + arrow) or `'diff` (struck-through old, `+`-prefixed new) |
| `metal-butt-explain-region-prompt` | `"Explain this code."` | Canned question sent by `C-c e` (`metal-butt-explain-region`) |
| `metal-butt-history-max-entries` | `200` | Prompts kept in the persisted `M-p` history file before oldest entries are dropped |
| `metal-butt-roll-threshold` | `60000` | Input tokens before offering a roll |
| `metal-butt-delete-prompt-after-send` | `nil` | Remove the prompt comment once answered |
| `metal-butt-log-enabled` | `t` | Log requests/results/fallbacks to `*metal-butt events*` (`C-c l`) |
| `metal-butt-log-max-chars` | `200000` | Approximate cap on the events log buffer's size before oldest lines are dropped |
| `metal-butt-complete-max-turns` | `20` | Turns before `C-c C-TAB` resyncs by resending the whole buffer (`'copilot-api` only) |
| `metal-butt-complete-max-history-chars` | `40000` | Accumulated completion-history size before a resync (`'copilot-api` only) |
| `metal-butt-autocomplete-idle-delay` | `1` | Idle seconds after an edit before auto-triggering a completion, once `C-c TAB` has turned it on for a buffer |

## Troubleshooting

**Something went wrong and it's not clear what or when.** `C-c l`
(`M-x metal-butt-show-log`) opens `*metal-butt events*`, a timestamped
history of every request, its outcome, and backend-level events (fallbacks,
token refreshes) — see "Diagnosing problems: the events log" above.

**A response failed to parse.** `M-x metal-butt-show-last-exchange` shows the
argv, the request sent on stdin, and the raw stdout and stderr of the last CLI
invocation. Responses are parsed tolerantly — a Markdown code fence around the
JSON is stripped, and raw line breaks inside JSON strings are escaped — so a
parse failure means something further from the contract than that.

**A command or function is missing after editing the source.** `M-x
metal-butt-reload` reloads every module. Plain `load-library` only reloads the
file you name, leaving the rest at the version the session started with, which
usually shows up as a void function.

**A prompt seems to hang.** Requests are abandoned after
`metal-butt-request-timeout` seconds. The CLI retries some failures with backoff,
so a denied model can take minutes to report; the timeout bounds that.

## Tests

```sh
make check      # ERT suite, no API calls
make compile    # byte-compile, warnings are errors
```

The transport is injectable, so the whole pipeline is tested against a stub and
the suite costs nothing to run.
