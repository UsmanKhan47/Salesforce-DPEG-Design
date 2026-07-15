---
description: Backfill or improve Apex test coverage for a target class to 90%+.
---

# Retrofit Tests

**Target Apex class(es):** $ARGUMENTS

## Flow

1. Read the target class(es). Identify uncovered paths (branches, exception handlers, bulk scenarios).
2. **salesforce-unit-testing** — create or extend the test class using `TestDataFactory`. Target 90%+ coverage per `ARCHITECTURE.md` §2. Include:
   - Positive + negative paths
   - Bulk scenario (251+ records)
   - Sharing/permission tests where applicable (`System.runAs`)
   - Mock HTTP callouts via `HttpCalloutMock` if the class has callouts
3. Run the tests locally via `sf apex run test --class-names <TestClass> --code-coverage`.
4. **salesforce-code-review** — verify coverage hits the target and assertions are meaningful (not just `System.assert(true)`).
5. **salesforce-devops** — deploy tests only.

Do not modify the class under test unless the user explicitly asks — tests reveal bugs, they don't fix them.
