---
name: unverified-claims-norm
description: Always independently spot-check counts/claims handed over in the task brief by grepping the actual repo before writing them into documentation
metadata:
  type: feedback
---

This project's task briefs to the documentation agent often include specific counts and claims
("17 throw sites across 10 classes", "TestDataFactory does not exist yet per ARCHITECTURE.md", a
field name in a violation list). Don't transcribe these directly — do a quick, cheap grep/glob to
confirm before writing them into the doc.

**Why:** on 2026-07-17 (Lease Inquiry reminder→Task doc), a brief said "three classes use an ahe()
helper" — a grep found 4, because the very build being documented had just added the helper to a
4th class (`LeaseInquiryController`). The brief was written before that build landed, so it was
stale by the time documentation ran. A grep caught this in under a minute and let the doc state the
count precisely (3 pre-existing + 1 added by this build = 4) instead of silently propagating a
now-wrong number.

**How to apply:** for any specific number, filename, or field name in a task brief that documentation
will assert as fact, spend one grep/glob/read confirming it against the current repo state before
including it. If the brief says something is "unverified" or "not fully verified" by the building
agent, don't try to resolve that yourself beyond a cheap sanity check — preserve it as unverified in
the doc (see [[design-decision-doc-style]]) rather than either asserting it as fact or leaving it
unchecked entirely.
