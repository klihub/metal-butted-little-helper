# Metal Butt — pair programming with Claude from Emacs buffers

**Status:** approved design, not yet implemented
**Date:** 2026-09-17
**Elisp prefix:** `metal-butt-`

## Goal

Let a developer prompt Claude from inside an Emacs buffer, in the buffer's own
comment syntax, and receive either a reviewable code edit or a written answer —
without leaving the editor and without retyping context that has already been
established elsewhere.

The motivating experience is pair programming. Copilot-style tools can suggest
edits but cannot be *asked* anything; chat tools can be asked anything but do
not share the buffer. This closes that gap.

## Non-goals

- **No shared live session with the terminal.** Attaching to a running Claude
  Code session would require driving the undocumented IDE WebSocket protocol in
  a direction it does not support. Rejected in favour of file-based context
  handoff (see *Handoff*). Revisit only if the seam proves painful in practice.
- **No MCP server in Emacs.** Not needed once the transport is `claude -p`.
- **No automatic triggering.** Requests fire on an explicit keystroke only.
  Auto-firing on idle or newline sends half-written prompts, and every misfire
  costs real money.
- **No disk writes by Claude.** See *Why Claude must not touch the disk*.

## Verified findings

These were measured against Claude Code 2.1.274 on the target machine, not
assumed. The design rests on them.

| Finding | Status |
|---|---|
| `--session-id <uuid>` accepts an arbitrary caller-chosen UUID | Confirmed |
| `--resume <uuid>` carries conversation memory across invocations | Confirmed |
| `--output-format json` returns text in `result`, plus `session_id`, `total_cost_usd`, `usage` | Confirmed |
| `.claude/commands/*.md` custom slash commands supported | Confirmed |
| `Stop` hook exists with `decision: block` semantics | Confirmed (binary strings) |
| Concurrent `--resume` on one session id is safe | **Assumed unsafe** — not disproven, but the test did not verify both turns survived in history |

Discounted claims from investigation (recorded so they are not re-derived):
transcripts *are* persisted under `~/.claude/projects/`, and the
`UserPromptSubmit`/`PreToolUse` hooks *do* exist — an earlier probe reported
otherwise on flawed evidence.

## Architecture

The transport is the only component with residual unknowns, so it is the only
one behind an interface. Everything else manipulates strings and buffers, and is
therefore testable with zero API spend via a stub transport.

```
C-c b  (metal-butt-send-prompt)
  │
  ├─ metal-butt-prompt     locate the `claude:` comment block at point;
  │                        strip comment prefixes → prompt text + region markers
  │
  ├─ metal-butt-handoff    read unconsumed delta of to-emacs.md; advance offset
  │
  ├─ metal-butt-context    assemble request: prompt, buffer content, file path,
  │                        major mode, active region, handoff delta
  │
  ├─ metal-butt-transport  ← THE SWAPPABLE SEAM
  │                        build argv → async process → parse JSON → result
  │
  ├─ metal-butt-response   dispatch on `kind`
  │
  ├─ metal-butt-overlay    kind=edit  → accept/reject overlay
  │  metal-butt-comment    kind=reply → comment block beneath the prompt
  │
  └─ metal-butt-handoff    append a note to to-terminal.md
```

Plus `metal-butt.el` as the entry point: minor mode, keybindings, and the
`metal-butt` customization group.

### Module responsibilities

**`metal-butt-prompt`** — Finds the contiguous run of comment lines at or above
point whose first line matches the attention word. Derives comment syntax from
`comment-start` / `comment-end` via `comment-normalize-vars` rather than
hardcoding `//` and `#`, so every major mode works for free. Returns prompt text
plus markers delimiting the block.

Matching rule, so it is unambiguous: after the mode's comment starter, optional
whitespace, then `metal-butt-attention-word` (default `"claude"`), then a colon.
Case-insensitive. Continuation lines are any immediately following comment lines
at the same indentation that do *not* themselves begin a new attention word. So
both of these are one two-line prompt:

```c
// claude: extract this into a helper
// and add a test for the empty case
```

```python
#claude: same thing, no space, still matches
# and this line continues it
```

**`metal-butt-context`** — Builds the request payload. Sends the buffer's *live*
content, not the file. Buffers above `metal-butt-max-buffer-chars` (default
20000) send a window around point plus an outline rather than the whole thing.

**`metal-butt-transport`** — Single public function taking a request and a
callback. v1 implementation shells out asynchronously to `claude -p`. The
interface is what matters; the implementation is expected to be replaced.

**`metal-butt-response`** — Parses and validates JSON against the contract.
Anything malformed is an error surfaced to the user, never a partial buffer
mutation.

**`metal-butt-overlay`** — Copilot-style inline presentation of a proposed edit,
one edit at a time, with accept and reject bindings.

**`metal-butt-comment`** — Inserts a non-edit answer as a comment block beneath
the prompt, in the buffer's comment syntax.

**`metal-butt-handoff`** — Append-only reads and writes plus consumed-offset
tracking.

## Response contract

Stated once per session via `--append-system-prompt`, so it cannot drift between
prompts and is not re-billed on every request.

```json
{"kind": "edit",  "edits": [{"old": "...", "new": "...", "why": "..."}]}
{"kind": "reply", "text": "..."}
```

`old`/`new` are **string pairs, not line numbers**. Line numbers go stale the
moment the user types anything above the target; string matching survives it.

Application rules:

- `old` must match **exactly once** in the buffer. Zero matches or two or more
  matches means refuse and report — never guess which one was meant.
- Edits apply to the buffer, never to the file on disk.
- Multiple edits are presented and accepted or rejected individually.

## Why Claude must not touch the disk

The buffer frequently holds unsaved changes, which makes the file on disk a
stale copy. If Claude edited the disk while the user held modifications, one
side's work would be lost, and Emacs would either clobber the change on save or
prompt about a file changed underneath it.

Therefore the buffer is the single source of truth: elisp sends buffer content,
Claude returns edits as *data*, elisp applies them to the buffer. Enforced with
`--disallowedTools Edit,Write,NotebookEdit`.

## Handoff

Two sessions exist — the terminal one and the buffer one — and they share
understanding through files rather than through a transcript. A curated note is
smaller, cheaper, and higher signal than a replayed conversation.

```
.claude/metal-butt/to-emacs.md       append-only, written by terminal session
.claude/metal-butt/to-terminal.md    append-only, written by Emacs
.claude/metal-butt/offsets            consumed byte offsets per direction
```

**One file per direction, single writer each.** This eliminates interleaving and
therefore eliminates locking.

**No file watching.** The buffer side reads the unconsumed delta at the moment it
sends the next prompt. Context arrives exactly when needed, costs nothing while
the user is typing, and requires no daemon.

**Bidirectional from day one.** The reverse direction matters more than it
appears: after an hour of pairing in buffers, the terminal session's picture of
the code is wrong, and it will act confidently on that stale picture.

Terminal side gets `.claude/commands/handoff.md` (write a handoff note) and
`.claude/commands/sync.md` (consume pending notes from Emacs). Both are plain
markdown; no plugin required.

Handoff files are generated state and belong in `.gitignore`.

## Transport details

```
claude -p
  --resume <derived-uuid>          (falls back to --session-id on first use)
  --model <metal-butt-model>
  --output-format json
  --append-system-prompt <contract>
  --disallowedTools Edit,Write,NotebookEdit
```

The session id is derived deterministically from the repository root path and a
generation counter — SHA-1 of `<repo-root>:<generation>`, formatted into UUID
shape with the version nibble set to 5. The generation counter is the only piece
of persisted state (`.claude/metal-butt/state`), and losing it is harmless: it
resets to zero and starts a fresh session rather than corrupting anything.

`total_cost_usd` from each response is displayed in the modeline. The user is
operating under a hard budget constraint; per-prompt cost feedback is a feature,
not telemetry.

**Model.** `metal-butt-model` defaults to `sonnet` — the right quality-per-dollar
for buffer-sized edits. Sonnet is currently blocked on the target account by an
explicit `Deny` in the `BedrockMinimalInferenceAccess` IAM policy, so the
transport must surface that 403 as a specific, actionable message naming the
policy rather than as a generic failure.

Deliberately **no automatic fallback to a cheaper model**
(`metal-butt-fallback-model` defaults to nil). A silent downgrade would change
edit quality without the user knowing why the suggestions suddenly got worse,
which is a harder problem to diagnose than an outright error.

**Keybinding.** `C-c b` in the minor mode map. `C-c` followed by a plain letter
is the namespace Emacs convention reserves for users, so it shadows nothing.
`C-c C-c` was rejected: it is `comment-region` in `c-mode`,
`python-shell-send-buffer` in `python-mode`, and a toggle in `org-mode`.

## Session rolling

A resumed session's context grows without bound. Rather than tolerate that or
depend on built-in auto-compaction, the session rolls itself over:

1. Watch `usage.input_tokens` on each response — already parsed for the modeline,
   so this costs nothing extra.
2. Above `metal-butt-roll-threshold`, or on explicit `M-x metal-butt-roll-session`,
   send one final prompt to the current session asking it to write a self-handoff.
3. Append that to `.claude/metal-butt/self-handoff.md`.
4. Increment the generation counter, derive the next session id, and seed the
   first prompt of the new session with the latest self-handoff.

This is the handoff primitive aimed at itself, which unifies the design: **one
handoff format, three channels** — terminal→Emacs, Emacs→terminal, and
session→successor.

Two properties worth stating explicitly:

**Cumulative, not chained.** The roll prompt already has the previous
self-handoff in its context, so it produces a *replacement* rather than a
summary of a summary. Without this, quality degrades by telephone game across
generations.

**Rolling too eagerly costs more than it saves.** Prompt caching means a long
session is sublinear in cost — cached prefix reads are billed at a fraction of
fresh input tokens. A roll discards that cached prefix *and* pays once for a
full-context summarisation call. So the threshold is set high, driven by measured
`input_tokens` rather than guesswork, and tuned after observing real numbers.
The default is deliberately provisional.

Preferred over built-in auto-compaction because a file can be read, edited, and
version-controlled, whereas compaction is opaque about what it chose to keep.

A useful side effect: sessions become disposable. If one drifts into a confused
state or a wrong assumption, rolling it is also the recovery mechanism.

## Failure handling

| Failure | Behaviour |
|---|---|
| Buffer changed while request in flight | Compare `buffer-chars-modified-tick` and marker positions; refuse to apply, report staleness |
| `old` text no longer matches, or matches more than once | Refuse that edit, report which one and why |
| Second `C-c b` while a request is pending | Refuse (one request in flight per buffer) |
| Non-zero exit, unparseable JSON, schema violation, timeout | Report as a message; no partial mutation |
| Offset file missing or handoff file truncated | Re-read from offset zero; duplicated context is acceptable, skipped context is not |
| Auth/authorisation failure (e.g. IAM denies the model) | Report the model and the denying policy verbatim; do not silently retry on a cheaper model |

## Testing

ERT against a stub transport returning canned JSON. No API calls, so the suite
is free to run and safe in CI.

Coverage: prompt extraction across `//`, `#`, `;;`, and `/* */` comment styles;
handoff delta and offset tracking; response parsing including malformed input;
uniqueness enforcement on `old`; staleness refusal; single-in-flight refusal.

The deliberate consequence of putting the transport behind an interface is that
essentially all logic is reachable without spending money.

## Open questions

Resolved during implementation, none blocking:

1. What `--resume` does with an id that does not yet exist — determines whether
   the `--session-id` fallback triggers on error or on a tracked first-use flag.
2. Whether a headless `-p` call hangs or auto-denies when a tool wants
   permission. Fallback if it hangs: whitelist with
   `--allowedTools Read,Grep,Glob`.
3. The value of `metal-butt-roll-threshold`. Requires observing real
   `input_tokens` growth against real cache-read discounts; see *Session
   rolling*.
4. Whether the prompt comment should remain after answering. Default: keep it,
   as a record of intent. Controlled by
   `metal-butt-delete-prompt-after-send` (default nil).

## Future: shared live session

Deferred, not discarded. If file handoff proves too coarse, the path is an Emacs
WebSocket MCP server plus a `Stop` hook that blocks termination and feeds
buffer-originated prompts into the live terminal session. Prior art exists
(`monet`, `claude-code-ide.el`). This buys interruptibility and live pull of
Emacs state — genuinely nicer, but not worth the reverse-engineering until the
cheap design is shown to be insufficient.
