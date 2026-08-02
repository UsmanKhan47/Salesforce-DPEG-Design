---
name: review-standard-system-debug
description: System.debug in a catch block as an error diagnostic is the established, unanimous convention in this repo — do not flag it as a "debug statement in production code"
metadata:
  type: feedback
---

Do **not** flag `System.debug(LoggingLevel.WARN|ERROR, ...)` inside a `catch` block as a
"debug statement in production code" warning. It is the established repo convention.

**Why:** measured against the codebase 2026-07-17. Every team-owned `System.debug` in the
repo is an error diagnostic inside a catch, never a debug print:

- `ApprovalAuditService.cls` (1), `BrokerPortalNotifier.cls` (1), `GroupNotifier.cls` (3),
  `TaskFanoutQueueable.cls` (1) — 6 occurrences, 4 classes, all catch-block diagnostics.
- `CommunitiesSelfRegController` / `MicrobatchSelfRegController` also contain one each, but
  are ARCHITECTURE.md §2 exempt Salesforce boilerplate — exclude them from precedent counts.

The generic "no System.debug in production" rule exists to stop **debug prints** left behind
during development. It was never aimed at catch-block diagnostics, and this repo has no
durable error sink (no Platform Event logger, no log object) — so removing them would make
failures undiagnosable with nothing offered in exchange.

**How to apply:** flag a `System.debug` only if it is (a) outside a catch, or (b) logging
routine flow rather than a failure. When reviewing a catch-block debug, the useful critique
is *not* "remove it" — it is that `System.debug` only lands anywhere if a **trace flag is
active on that user at that moment**, so any comment claiming the detail "goes to the debug
log (admin-only)" as if it were a reliable channel is overstating it. Push on the comment,
not the line. The real fix is a durable error sink, which is a program-level item, not a
per-PR one.

Related: [[review-standard-controller-dml]]
