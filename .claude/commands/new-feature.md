---
description: Run the full 7-agent workflow for a new Salesforce feature (design → admin → developer → unit-testing → code-review → devops + docs)
---

# New Feature

Kick off the full 7-agent orchestration for a new Salesforce feature.

**User request:** $ARGUMENTS

## Required flow (from CLAUDE.md — do not skip steps)

1. **salesforce-design** (always first). Pass the user's request verbatim. Wait for the Design Agent's requirements doc. Display the plan and ask the user: `Proceed? (yes/no/changes)`.

2. On `yes`: invoke the agents indicated by Design's plan in this exact order:
   - **salesforce-admin** — if Design identified declarative work
   - **salesforce-developer** — if Design identified code work
   - **salesforce-unit-testing** — if Apex was created
   - **salesforce-code-review** — always, before deployment

3. **Code review gate.** If verdict is `CHANGES REQUIRED`, ask the user: `[F]ix / [S]kip / [C]ancel`. On `F`, loop back to `salesforce-developer` with the issue list, then re-run `salesforce-code-review`.

4. On `APPROVED` or `APPROVED WITH WARNINGS`: run **salesforce-devops** and **salesforce-documentation** in parallel (single message, two tool calls).

5. Summarize: components created/modified, deploy result, docs path.

## Guardrails

- Consult `ARCHITECTURE.md` at every delegation boundary — include relevant conventions in the sub-prompt.
- Never write `.cls`, `.trigger`, `.xml`, or metadata files yourself. Delegate.
- Never run `sf project deploy` yourself — that's the devops agent's job.
