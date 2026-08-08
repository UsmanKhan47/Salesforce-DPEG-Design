# Rule: ContentPublication Quota Protection

## Objective
Make it structurally impossible for this repo's test suite to exhaust the org's `ContentPublication` quota. Every `ContentVersion` or `ContentNote` insert — in production code OR in a test — consumes one **ContentPublication**, and this org enforces a hard, org-wide cap of **2,500 per rolling 24 hours**. A test suite that burns this quota can turn a green codebase into a failed deployment, or worse — starve production of headroom it needs to survive a real inbound transaction. **Read this together with `.claude/rules/bulk-test-rule.md`** — this rule narrows that rule's 251-record mandate specifically where the object under test is content.

## Why This Is Not An Ordinary Governor Limit

This happened in production on this project (2026-08-06) and is the reason this rule exists — read `EmailToLeadHandler.cls`'s class header for the full incident writeup. Four facts make `ContentPublication` categorically more dangerous than every other limit this codebase tests against:

1. **The cap is org-wide and rolling, not per-transaction.** Every other governor limit (SOQL, DML, CPU, heap) resets per transaction and is irrelevant to any OTHER transaction. `ContentPublication` is shared across every test run, every deploy's `RunLocalTests`, and every real inbound email the org processes, all counted against the SAME 2,500-per-24-hours ceiling.
2. **🔴 TEST ROLLBACK DOES NOT REFUND THE QUOTA.** A test's `ContentVersion`/`ContentNote` rows vanish at rollback exactly like any other test data — but the ContentPublication counter they consumed does NOT roll back with them. The cost is permanent per test run and invisible in the test's own debug log.
3. **Apex `Limits` cannot see it.** `ContentPublicationLimit` is not exposed anywhere in the `System.Limits` class. There is no `Limits.getContentPublications()` / `Limits.getLimitContentPublications()` to check before inserting, and do not add a REST callout to the `/limits` API to work around this — that is a synchronous callout from code that has no business making one, and it does not fix the underlying problem.
4. **The failure is effectively uncatchable and aborts the whole transaction.** Exceeding the cap throws `System.UnexpectedException: ContentPublication Limit exceeded`, which has been measured on this project to escape `catch (Exception e)` blocks AND to be ignored by `Database.insert(records, false)` (the `allOrNone = false` partial-success pattern does not apply to it). The entire transaction rolls back, including unrelated DML that had already committed earlier in the same transaction.

## Hard Ceiling Per Test Method

| Test is testing... | Max content rows per test method | Why |
|---|---|---|
| A selector READ (`WHERE Id IN :ids`, `WHERE LinkedEntityId = :id`, etc.) | **20** | A read has no batch chunking — behaviour at 251 rows is identical to behaviour at 20. `.claude/rules/bulk-test-rule.md`'s 251 mandate exists to force a SECOND trigger-batch firing, which does not apply to a query. |
| A service method that performs the DML itself (`persist()`, `linkTo()`, `addNote()`, etc.) | **As few rows as the scenario requires — typically 1-3** | Each row exists to prove one specific DML-path fact (happy path, cross-product, rollback-on-failure, refusal handling). Do not add rows "for volume" on a DML test; add a SEPARATE narrowly-scoped test instead if a new fact needs proving. |
| Any single test class, summed across all its methods | **≤ 30 as a target, flag anything over 50** | Keeps one class from silently becoming the suite's largest consumer the way `ContentDocumentLinkSelectorTest`/`ContentNoteSelectorTest` did at 251 rows each. |

**No test method may insert 251 (or any other bulk-test-rule number) rows of `ContentVersion`, `ContentNote`, or `ContentDocument` under any circumstance.** If a genuine trigger or batch job existed that operated ON these objects and needed 251-row bulk proof, that would be the one exception requiring explicit sign-off in the class header — none exists in this codebase today, and none should be added without first re-reading this rule.

## Enforcement Gate

Before writing or approving any test method that inserts `ContentVersion`, `ContentNote`, or `ContentDocument`:

1. **Classify the method under test** — is it a selector read, or a service method that performs the DML? Apply the matching row from the table above.
2. **If it is a selector read and an existing/planned test uses 251 rows** — cut it to 20 and add the same "BULK VOLUME IS 20, NOT 251 — DELIBERATE" header block used in `ContentVersionSelectorTest.cls`, `ContentNoteSelectorTest.cls`, and `ContentDocumentLinkSelectorTest.cls`. Cross-reference this file.
3. **If it is a DML-performing method** — use the minimum row count that still falsifies the specific behavior (e.g. 2 files to prove a cross-product multiplies, not adds; 1 file to prove a rollback). Never round up "to be safe."
4. **Before finalizing, sum every content-creating test method in the class** (and re-check the suite total in the class header comment where one exists) and confirm it is nowhere near the 2,500/24h ceiling on its own.
5. **Do not attempt to pre-check the live counter** — there is no such check available (see point 3 above). The only real control is keeping the row counts themselves small.

## Anti-Patterns

| Don't | Why | Do Instead |
|-------|-----|-----------|
| `for (Integer i = 0; i < 251; i++) { notes.add(new ContentNote(...)); }` on a selector-read bulk test | Proves nothing a 20-row loop doesn't, and burns ~10% of the org's daily quota in one test method | Loop to `BULK_ROWS = 20` and document why in the class header |
| Assuming `Database.insert(versions, false)` makes a `ContentVersion` insert failure "safe" | `ContentPublication Limit exceeded` ignores `allOrNone = false` entirely — measured in production | Treat any code path that inserts `ContentVersion`/`ContentNote` as capable of aborting the WHOLE transaction, test the object under test's OWN failure handling only, and keep row counts minimal |
| Trying to check remaining ContentPublication quota with `Limits.getX()` before inserting | Does not exist — `ContentPublicationLimit` is not exposed by the `Limits` class | Do not attempt a pre-check; keep test volume low instead |
| Adding "just a few more rows for confidence" to an already-passing content test | Confidence gained is roughly zero (a selector read behaves identically at any N > the actual query page size) against a real, cumulative, non-refundable cost | If a genuinely new fact needs proving, write a new narrowly-scoped test with its own minimal fixture, don't inflate an existing one |
| Assuming test rollback means a content-heavy test is "free to re-run" | Rollback removes the ROWS, not the ContentPublication COUNT — confirmed root cause of the 2026-08-06 incident | Budget every content-creating test as a PERMANENT quota cost, run once, not something to iterate on freely against a live org |

## Cross-Reference

Read together with `.claude/rules/bulk-test-rule.md`. That rule's 251-record mandate is the DEFAULT for triggers, batch jobs, DML-performing services, and queueables — and it is still correct for every non-content object in this codebase. This rule is a narrower, content-specific EXCEPTION carved out of that default: a selector read against `ContentVersion`/`ContentNote`/`ContentDocument` never needs 251 rows to prove its point, and unlike almost everything else this codebase tests against, the cost of over-testing here is a real, shared, non-refundable, org-wide production resource.
