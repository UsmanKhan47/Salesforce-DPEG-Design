---
name: docs-folder-convention
description: Where to save documentation-agent output in this repo, and how it differs from the pre-existing docs/ layout
metadata:
  type: project
---

The repo's `docs/` folder already contains a large body of files, but they live under
`docs/superpowers/{plans,specs,reports}/[YYYY-MM-DD]-[task-name].md` — this is output from a
different, prior tool/workflow ("superpowers"), not from the salesforce-documentation subagent.
There is no precedent (as of 2026-07-17) of this agent's own output living anywhere in the repo yet.

**Decision made 2026-07-17:** followed this agent's own system-prompt template literally — saved
flat at `docs/[YYYY-MM-DD]-[task-name].md` (not nested under `docs/superpowers/`). The filename
style (date-prefixed, kebab-case) matches the existing superpowers docs anyway, so this reads as
consistent with the folder even though it isn't nested.

**Why this matters:** if a future task says "follow existing docs/ conventions," don't assume that
means nesting under `docs/superpowers/` — that subfolder belongs to a different workflow. The
correct read is: match the *filename* convention (date + kebab-case), keep the *location* flat per
this agent's own instructions, unless the user explicitly asks to nest it elsewhere.
