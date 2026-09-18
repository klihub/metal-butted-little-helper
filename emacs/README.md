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
- The `claude` CLI on `exec-path`, authenticated
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
| `C-c C-a` | Accept the proposed edit |
| `C-c C-r` | Reject the proposed edit |
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

The mode line shows what each prompt cost. When a session's context gets large,
`M-x metal-butt-roll-session` summarises it into a handoff note and starts a
fresh session. Rolling is never automatic — it costs a full-context call, so the
timing is yours to choose.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `metal-butt-executable` | `"claude"` | Name or path of the Claude Code CLI |
| `metal-butt-model` | `"sonnet"` | Model for buffer prompts |
| `metal-butt-known-models` | `'("haiku" "sonnet" "opus" "fable")` | Accepted model names |
| `metal-butt-request-timeout` | `60` | Seconds before a request is abandoned |
| `metal-butt-attention-words` | `'("claude")` | Words that mark a comment as a prompt |
| `metal-butt-prompt-search-limit` | `20` | Lines above point to search for a prompt |
| `metal-butt-max-buffer-chars` | `20000` | Larger buffers send a window around point |
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
