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
| `metal-butt-executable` | `"claude"` | Name or path of the Claude Code CLI |
| `metal-butt-model` | `"sonnet"` | Model for buffer prompts |
| `metal-butt-attention-word` | `"claude"` | Word before the colon |
| `metal-butt-prompt-search-limit` | `20` | Lines above point to search for a prompt |
| `metal-butt-max-buffer-chars` | `20000` | Larger buffers send a window around point |
| `metal-butt-roll-threshold` | `60000` | Input tokens before offering a roll |
| `metal-butt-delete-prompt-after-send` | `nil` | Remove the prompt comment once answered |

## Tests

```sh
make check      # ERT suite, no API calls
make compile    # byte-compile, warnings are errors
```

The transport is injectable, so the whole pipeline is tested against a stub and
the suite costs nothing to run. 91 tests pass.
