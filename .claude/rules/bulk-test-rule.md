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
