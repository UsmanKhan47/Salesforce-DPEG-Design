---
name: design-decision-doc-style
description: DPEG documentation style preference — a dedicated, evidence-backed "Key Design Decisions and Rationale" section is the centerpiece of feature docs, not an afterthought
metadata:
  type: feedback
---

For this project, when a build task hands over a list of "design decisions and their rationale,"
treat that as the most valuable part of the documentation, not boilerplate to compress. Confirmed
2026-07-17 on the Lease Inquiry reminder→Task doc, where the requester explicitly said "document the
WHY, this is the valuable part."

**How to apply:**
- Give each decision its own numbered entry with a bold one-line statement of the decision, then the
  reasoning.
- Where possible, back the rationale with something verifiable in the actual code/tests read during
  research (e.g. "proven by mutation testing — disabling X makes test Y fail with Expected:1
  Actual:2"), not just a restatement of what the requester said. This project's engineers write
  test comments that explicitly document *why* a test exists (control tests, mutation-testing
  proofs, "do not weaken this assertion" notes) — mine those comments, they are gold for this
  section.
- Distinguish clearly between "verified in code" and "reported to me, not independently re-verified"
  — this project has a strong norm (see [[unverified-claims-norm]]) of not overstating what was
  checked. A decision rationale that cites "web docs were unreachable, so this is unverified" should
  be preserved as unverified in the doc, not upgraded to a confirmed fact.
- Known open items / drift (e.g. stale ARCHITECTURE.md) get their own separate section, explicitly
  labeled as NOT resolved and NOT to be corrected by the documentation agent — just recorded.
