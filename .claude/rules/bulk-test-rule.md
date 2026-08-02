# Rule: Bulk Test Enforcement

## Objective
Ensure every trigger, batch job, and service method is tested with enough records to expose governor limit failures and bulkification bugs. The standard 200-record threshold is insufficient — this project requires 251+.

## Why 251?

Salesforce processes trigger batches in chunks of up to 200 records. A bulk test with exactly 200 records may pass even if there is a SOQL-in-loop bug because it runs in a single batch. Inserting 251 records forces a second batch chunk, exposing bugs that only appear when trigger logic runs more than once per transaction.

## Mandatory Bulk Counts

| Context | Minimum Records | Reason |
|---------|----------------|--------|
| Trigger test (insert/update/delete) | **251** | Forces 2 trigger batch firings |
| Batch Apex test (data setup) | **251** | Verifies batch processes all records across chunks |
| Service method with DML | **251** | Verifies no SOQL/DML in loops |
| Queueable test | **251** | Verifies bulk handling in async context |

## Enforcement Gate

Before writing any test class for a trigger, batch, or service:

1. Check that bulk test methods insert **251 or more** records.
2. The assertion count in bulk tests must match the inserted count (251).
3. `Database.executeBatch(batch, 200)` — the chunk size of 200 is standard and correct; the *record count* must be 251+.

## Required Test Method Structure

Every trigger test class must contain at minimum:
- A positive bulk insert test with 251 records
- A positive bulk update test with 251 records (if trigger handles updates)
- A positive bulk delete test with 251 records (if trigger handles deletes)

Every batch test class must contain:
- A test that sets up 251+ records and verifies all are processed after `Test.stopTest()`

## Anti-Patterns

| Don't | Do Instead |
|-------|-----------|
| `for (Integer i = 0; i < 200; i++)` in bulk tests | `for (Integer i = 0; i < 251; i++)` |
| `Assert.areEqual(200, results.size(), ...)` | `Assert.areEqual(251, results.size(), ...)` |
| Single-record trigger tests only | Always include a 251-record bulk scenario |
| Bulk test with 1 record to "save time" | Use `@TestSetup` to share setup cost; always test at 251+ |

## Exemption: Per-Transaction-Singleton Async Pipelines

Added 2026-07-24 (Broker Protection code review, Suggestion 2; see `docs/2026-07-24-broker-protection.md`).
**⚠ NARROWED 2026-07-31 — read "Narrowed scope" below before applying this to any Broker
Protection class.**

A service method that is **structurally single-record-per-transaction** — no trigger, no loop over
multiple records, invoked exactly once per async job (e.g. one inbound email → one `Queueable`
execution → one claim) — is exempt from the 251-record mandate above. A 251-record test on such a
method would not exercise any additional code path (there is no loop to force a second batch), and
would itself risk tripping unrelated governor limits (e.g. 150 DML statements) while proving nothing.
This exemption does **not** relax the "no SOQL/DML in loops" rule — it only removes the 251-record
*volume* requirement for methods that are provably never called with more than one record per
transaction.

### Narrowed scope (2026-07-31, design C-18)

The exemption originally listed `EmailToLeadService`, `LLMExtractionCalloutService`,
`PropertyMatchingService` and `PropertyClaimService`. **D1 multi-property extraction invalidated
that premise for three of the four:** `ExtractAddressQueueable.execute` now loops over up to
`MAX_PROPERTIES` (10) properties per email, so `PropertyClaimService.claim` and
`EmailToLeadService.createLeadFromExtracted` are invoked **N times per transaction**, not once.

| Class | Exempt? | Why |
|---|---|---|
| `LLMExtractionCalloutService` | ✅ **Yes** | Still exactly ONE callout per queueable execution. |
| `ExtractAddressQueueable` | ❌ No | Now loops. Needs the volume tests below. |
| `PropertyClaimService` | ❌ No | `claim()` runs once per property. |
| `EmailToLeadService` | ❌ No | `createLeadFromExtracted()` runs once per property. |
| `PropertyMatchingService` | ❌ No | Read helpers run once per property. |

**A literal 251 is still both impossible and meaningless here, and that reasoning must be recorded
in the test class header so review does not demand it:** `System.enqueueJob` caps at 50 calls per
transaction, *and* 251 properties in one email would exhaust the SOQL limit at roughly 14–24
properties. Testing a volume production cannot reach is the exact anti-pattern this exemption
exists to prevent.

**Required replacements for a de-exempted class** (design §7):
1. a **MAX_PROPERTIES-volume test** — one email carrying 10 properties, all correctly routed;
2. a **truncation test** — 15 properties, exactly 10 routed, the count and ` [truncated: X of M]`
   suffix visible;
3. **governor-headroom assertions** against a named budget — the highest-value test, because it
   makes a future change that adds one query per property fail HERE instead of in production;
4. a **mixed-outcome test** (winner + competing + repeat in one email);
5. **ordering determinism** for anything whose iteration order is load-bearing (lock ordering).

⚠ Assert governor headroom on counters captured INSIDE the async context (e.g.
`ExtractAddressQueueable.lastRunQueryCount`), not on `Limits.getQueries()` after
`Test.stopTest()` — stopTest restores the pre-test counters, so the obvious assertion is
silently vacuous.
