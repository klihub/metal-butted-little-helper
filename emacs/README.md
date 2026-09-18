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

Authentication is not special here — the spawned `claude` authenticates exactly as
it does in your terminal. But it inherits **Emacs's** environment, and GUI Emacs
started from a desktop launcher does not source your shell's rc files. A setup
that works in a terminal can still fail from a buffer, either because `claude` is
not on `exec-path` or because the credential variables are absent.

Check with `M-:`:

```elisp
(list (executable-find "claude")
      (getenv "CLAUDE_CODE_USE_BEDROCK")   ; if you authenticate via Bedrock
      (getenv "AWS_REGION"))
```

If anything is `nil`, either start Emacs from a shell that has the environment,
use `exec-path-from-shell`, or set `metal-butt-executable` to an absolute path.
Avoid putting a credential in a version-controlled init file.

The child process has no TTY, so the CLI cannot prompt interactively — if your
credentials have expired, refresh them in a terminal first.

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
| `C-c m` | Set the model (prefix arg: this buffer only) |

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
| `metal-butt-executable` | `"claude"` | Name or path of the Claude Code CLI |
| `metal-butt-model` | `"sonnet"` | Model for buffer prompts |
| `metal-butt-known-models` | `'("haiku" "sonnet" "opus" "fable")` | Accepted model names |
| `metal-butt-request-timeout` | `60` | Seconds before a request is abandoned |
| `metal-butt-attention-words` | `'("claude")` | Words that mark a comment as a prompt |
| `metal-butt-prompt-search-limit` | `20` | Lines above point to search for a prompt |
| `metal-butt-max-buffer-chars` | `20000` | Larger buffers send a window around point |
| `metal-butt-roll-threshold` | `60000` | Input tokens before offering a roll |
| `metal-butt-delete-prompt-after-send` | `nil` | Remove the prompt comment once answered |

## Choosing a model

Per prompt, with a leading `@` token:

```c
// claude: @opus redesign this module
// claude: @haiku what does this do?
```

Per session, without writing any elisp: `C-c m` (or `M-x metal-butt-set-model`)
reads a model with completion. A prefix argument sets it for the current buffer
only. Most specific wins: an `@` token beats the buffer setting, which beats the
global default. The mode line shows which model is active.

## Troubleshooting

If a response fails to parse, `M-x metal-butt-show-last-exchange` shows the exact
argv, the request sent on stdin, and the raw stdout and stderr of the last CLI
invocation.

Responses are parsed tolerantly: a Markdown code fence around the JSON is
stripped, and raw line breaks inside JSON strings are escaped, since models
produce both despite instructions. Neither transformation changes the meaning of
valid JSON.

## Tests

```sh
make check      # ERT suite, no API calls
make compile    # byte-compile, warnings are errors
```

The transport is injectable, so the whole pipeline is tested against a stub and
the suite costs nothing to run. 99 tests pass.
