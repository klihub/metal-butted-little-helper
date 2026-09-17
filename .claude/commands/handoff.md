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
