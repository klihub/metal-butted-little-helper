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
| `C-c C-p` | Ask a follow-up, continuing the last `C-c p` conversation |
| `C-c C-a` | Accept the whole proposed edit (all remaining hunks) |
| `C-c C-r` | Reject the whole proposed edit (all remaining hunks) |
| `C-c h a` | Accept just the current hunk, then advance to the next |
| `C-c h r` | Reject just the current hunk, then advance to the next |
| `C-c C-d` | Toggle the current hunk between full-region and diff-style view |
| `C-c m` | Set the model (prefix arg: this buffer only) |

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

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `metal-butt-backend` | `'claude` | Which backend to use: `'claude`, `'copilot`, or `'copilot-api` |
| `metal-butt-executable` | `"claude"` | Name or path of the Claude Code CLI |
| `metal-butt-copilot-executable` | `"copilot"` | Name or path of the Copilot CLI |
| `metal-butt-copilot-api-github-token-file` | `"~/.config/copilot-chat/github-token"` | GitHub token file reused from `copilot-chat`, for `'copilot-api` |
| `metal-butt-copilot-api-curl-program` | `"curl"` | Curl program used to reach the Copilot API directly |
| `metal-butt-copilot-api-stream` | `t` | Request a streaming response from `'copilot-api' and show it growing live in `M-x metal-butt-ask`'s window |
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
| `metal-butt-roll-threshold` | `60000` | Input tokens before offering a roll |
| `metal-butt-delete-prompt-after-send` | `nil` | Remove the prompt comment once answered |

## Troubleshooting

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
