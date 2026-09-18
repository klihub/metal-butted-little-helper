# Santa's metal-butted little helpers

Tools for working with Claude, one subdirectory per helper.

| Directory | What it is |
|---|---|
| [`emacs/`](emacs/) | **Metal Butt** — pair programming with Claude from inside Emacs buffers. Type a prompt in a comment, press a key, get a reviewable edit or a written answer. |

Each subproject is self-contained and carries its own README, Makefile and
tests. `make check` at the repo root runs every subproject's suite.

## Repository layout

```
emacs/              the Emacs integration
docs/superpowers/   design spec, implementation plan, and the decisions
                    taken while building it
.claude/commands/   terminal-side slash commands (must live at the repo root;
                    Claude Code only looks for them here)
.claude/metal-butt/ handoff state shared between sessions (gitignored)
```

`.claude/` stays at the root deliberately rather than moving under `emacs/`:
Claude Code discovers project commands only at the repo root, and the handoff
files are addressed relative to it.
