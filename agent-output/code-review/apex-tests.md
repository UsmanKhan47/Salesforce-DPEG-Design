# Code Review — Apex Test Classes

**Reviewer:** salesforce-code-review subagent
**Date:** 2026-07-21
**Scope:** All `*Test.cls` under `force-app/main/default/classes/` (102 files), EXCLUDING the 10 exempt Site/Communities boilerplate test counterparts. Net in-scope: **92 test classes.**
**Method:** Static review only (no org access — coverage percentages NOT assessed). Checked against `.claude/rules/bulk-test-rule.md`, `ARCHITECTURE.md §2`, and the review standards in the task brief.

---

## Verdict: ✅ APPROVED

No CRITICAL or WARNING issues. Every trigger, async (Schedulable/Queueable), and bulkifiable DML-service test carries a genuine 251-record bulk scenario with a matching assertion. Every single-record service test that omits a 251 scenario carries explicit written justification in its class header (satisfying the "unless justified" clause). Only three low-severity SUGGESTIONs remain, none requiring a change before deployment.

---

## Summary

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | 0 |
| 🟡 WARNING | 0 |
| 🟢 SUGGESTION | 3 |
| ✅ PASSED (checks with no findings) | see below |

**Checks that passed clean across all 92 in-scope files:**
- ✅ **`@isTest(SeeAllData=true)`** — none in scope. The only occurrences are in the 10 exempt boilerplate classes. `NotificationTypeSelectorTest` and `PropertyAssetSelectorTest` merely reference "SeeAllData=false" in explanatory comments.
- ✅ **251-record bulk rule** — every trigger-handler test, the Schedulable test, the Queueable path, and every bulkifiable DML-service test has a real 251+ insert with a `251` assertion. (Details below.)
- ✅ **`TestDataFactory` discipline** — all bulk/setup data goes through the org-wide `TestDataFactory` (`createLeads(251,...)`, `createOpportunities(251,...)`, `createTransactions(...)`, `createBrokerAssignments(251,...)`, `createOnboardingTasks(251,...)`, `applyOverrides(...)`). No competing per-feature factory found.
- ✅ **TODO / FIXME / commented-out or emptied test bodies / disabled tests** — none.
- ✅ **`System.debug` in test code** — none.
- ✅ **MIXED_DML** — controller tests that `insert u` (a `User`, a setup sObject) do so only inside/around `System.runAs`, with record data sourced from `@TestSetup` (a separate transaction). No non-setup DML shares a transaction with a User insert. (`UnitSelectorTest:69 insert u` is a `Unit__c`, not a User — false positive.)
- ✅ **Async correctness** — `Test.startTest()/stopTest()` wraps the async work in `TaskFanoutServiceTest.testFanOut_bulk251_...` (asserts `AsyncApexJob`), `BrokerCheckInReminderSchedulableTest.schedulableExecuteRuns`, and the governor-sensitive bulk assertions throughout.
- ✅ **Async inventory** — only two async production classes exist: `BrokerCheckInReminderSchedulable` (covered w/ 251) and `TaskFanoutQueueable` (covered via `TaskFanoutServiceTest`'s 251 async-chunk test). No `Database.Batchable` classes exist, so no batch tests are owed.

---

## 251-Record Bulk Rule — Detailed Disposition

### Trigger-handler tests — ALL COMPLIANT
| Test class | Bulk method | Records | Matching assert |
|---|---|---|---|
| `LeadConvertTriggerHandlerTest` | `bulk251ConversionsStampEveryOpportunity` | 251 (200+51 split — fires handler twice) | `areEqual(251, ...)` ✓ |
| `OpportunityReviewTriggerHandlerTest` | `bulk251InsertsOpenOneNdaEach` + `bulk251UpdatesOpenOneReviewEach` | 251 insert & 251 update | `COUNT()=251` ✓ |
| `ContractReviewTriggerHandlerTest` | `bulk251ExecutedContractsHandOff` | 251 | `areEqual(251,...)` + `COUNT()=251` ✓ |
| `TaskRollupTriggerHandlerTest` | `bulk251TasksAcrossTransactionsRollUpPerDeal` | 251 (100/100/51) | per-parent + `COUNT()=251` ✓ |
| `TriggerHandlerTest` | (base dispatcher — no object DML) | N/A | dispatch-branch asserts ✓ |

### Async tests — ALL COMPLIANT
| Test class | Bulk method | Records | Notes |
|---|---|---|---|
| `BrokerCheckInReminderSchedulableTest` | `createsReminderForEachOverdueBulk` | 251 | clears `@TestSetup` first so assert count == inserted count ✓ |
| `TaskFanoutServiceTest` (drives `TaskFanoutQueueable`) | `testFanOut_bulk251_chunksAsyncAtProductionDefCount` | 251 (× real 82 CMDT defs) | asserts chunk math, `AsyncApexJob`, `<= 10000` DML rows ✓ |

### Key Apex Service tests (bulkifiable DML) — ALL COMPLIANT
`ContractExecutionServiceTest` (`bulkExecution251...`), `LeadConvertServiceTest` (`bulkConversion251...`), `OpportunityReviewServiceTest` (`bulkCreate`, 251), `TaskRollupServiceTest` (`testRecalc_bulk251...`), `OnboardingTaskRollupServiceTest` (`recalcHandlesBulk251Tasks`) — each inserts 251 and asserts on 251/derived counts.

### P6 controller-support service tests — single-record, JUSTIFIED (no 251 owed)
Each of the following processes exactly one record per `@AuraEnabled` invocation with no input-scaling collection DML. Each carries a written justification in its class header explaining why a 251 scenario does not apply (a per-record loop of 251 would breach the 150-DML limit and would exercise no bulkified path because none exists). This satisfies the review standard's "unless the developer provided written justification" clause.

`BrokerAssignmentServiceTest`, `CounterOfferServiceTest`, `DispositionServiceTest`, `DispositionTaskServiceTest` (bounded 3-row checklist, fixed — never scales), `DealMessageServiceTest`, `LeaseRenewalServiceTest`, `PsaVersionServiceTest`, `StageAdvanceServiceTest`, `WireServiceTest`, `OnboardingServiceTest`, `TransactionTaskServiceTest`, `BrokerPortalServiceTest` (guest single-submission).

---

## SUGGESTIONS (low severity — no change required before deployment)

### 🟢 S-1: AHE `getMessage()` equality/contains asserts (reviewed per standard — verified SAFE)
- **Files/lines:**
  - `LeaseInquiryControllerTest.cls:172-176` — `assertEquals('This update could not be saved...', e.getMessage(), ...)`
  - `LeaseInquiryControllerTest.cls:232-236` — same generic message equality
  - `LeaseInquiryControllerTest.cls:275-279` — `assertEquals('The reminder name is too long...', e.getMessage(), ...)`
  - `BovControllerTest.cls:155-158` — `e.getMessage()...contains('could not be loaded')` / `!contains('no rows')`
- **Standard concern:** asserting on `AuraHandledException.getMessage()` is normally flaky because a bare `throw new AuraHandledException('msg')` yields `getMessage()=='Script-thrown exception'` in test context.
- **Why it is SAFE here (verified):** every P6 controller builds its AHE through a private `ahe(String msg)` helper that calls `ex.setMessage(msg)` (confirmed in `BovController.cls:34-36`, `LeaseInquiryController.cls:115-117`, and 11 other controllers). With `setMessage()`, `getMessage()` returns the real text reliably. These asserts are **deliberate regression guards for the `ahe()` setMessage contract** — `LeaseInquiryControllerTest:170-171` documents that this content assert is exactly what caught a "missing setMessage()" defect and says "Do not weaken it to `threw`."
- **Recommendation:** **Do NOT weaken.** Keep as-is. Optionally add a one-line comment cross-referencing the `ahe()` helper so future maintainers know the assert depends on it. Flagged only to record that the standard check was applied.
- **Note:** service-layer message asserts that look similar are on *typed custom* exceptions, not AHE, and are reliable: e.g. `BrokerAssignmentServiceTest:118` (`BrokerAssignmentService.BrokerAssignmentException`), `TransactionTaskServiceTest:136,143` (`WireVerificationException`). Selector "no rows"/QueryException `getMessage()` asserts (`DispositionSelectorTest`, `WireSelectorTest`, `TaskSelectorTest`, etc.) are also not AHE.

### 🟢 S-2: Two trivially-true "no-throw" assertions
- **`TaskRollupServiceTest.cls:77`** — `System.assert(true, 'recalc tolerates null, empty, and null-only Id sets without throwing')`
- **`TriggerHandlerTest.cls:112`** — `Assert.isTrue(true, 'Default virtual context methods are safe no-ops in every context')`
- **Issue:** the method exercises code but its only assertion is a literal `true` — it passes as long as nothing throws.
- **Recommendation:** acceptable as a no-throw guard, but could be strengthened to assert an observable invariant (e.g., `Assert.areEqual(0, [SELECT COUNT() FROM Task ...])` after the null/empty `recalc` calls, or a recorded no-op flag). Low priority.

### 🟢 S-3: Legacy assertion API used widely
- **Where:** most Key-Service and older tests use `System.assertEquals` / `System.assert` (e.g. `ContractExecutionServiceTest`, `TaskFanoutServiceTest`, `TaskRollupServiceTest`, `LeadConvertServiceTest`, `OpportunityReviewServiceTest`, `BrokerCheckInReminderSchedulableTest`, `OnboardingTaskRollupServiceTest`). Newer P6 tests use the modern `Assert.*` class.
- **Issue:** `Assert.*` (the `Assert` class) gives clearer failure output and is the project's newer convention; the mix is cosmetic only.
- **Recommendation:** prefer `Assert.areEqual/isTrue/isNull` in new/edited tests. No functional impact — suggestion-level only.

---

## Good Practices Observed
- Every trigger/async/bulkifiable-service test forces a **second batch chunk at 251** exactly as `bulk-test-rule.md` requires, with assertions keyed to the inserted count.
- Bulk tests use **distinct per-parent data mixes** (e.g. `TaskRollupServiceTest` 60 complete / 30 overdue / 10 wire-open) so map-keyed aggregation is verified, not just totals.
- `TaskFanoutServiceTest` and the CMDT provider tests use **canary asserts** (`COUNT() FROM ..._mdt == 82/11`) so a drifted org data load fails loudly instead of silently under-testing.
- Restricted-user negative paths use `System.runAs(bareUser)` to exercise FLS/USER_MODE read-failure catches at the LWC boundary.
- Idempotency and rollback/savepoint behaviour is explicitly asserted (re-execution never duplicates; committed-then-reverted work is proven).
- Class headers document *why* single-record services are exempt from the bulk rule — reviewable intent, not silent omission.
