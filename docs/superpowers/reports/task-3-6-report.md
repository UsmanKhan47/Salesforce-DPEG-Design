# Task 3-6 Report: BrokerPortalController Apex Classes

**Date:** 2026-06-22  
**Target Org:** DPEG-Acq-3 (test-3iuncy5c1je5@example.com)

---

## Files Created

| # | File Path |
|---|---|
| 1 | `F:\Acquisition-Design-Salesforce\force-app\main\default\classes\BrokerPortalController.cls` |
| 2 | `F:\Acquisition-Design-Salesforce\force-app\main\default\classes\BrokerPortalController.cls-meta.xml` |
| 3 | `F:\Acquisition-Design-Salesforce\force-app\main\default\classes\BrokerPortalControllerTest.cls` |
| 4 | `F:\Acquisition-Design-Salesforce\force-app\main\default\classes\BrokerPortalControllerTest.cls-meta.xml` |

---

## Deploy Command and Result

**Command:**
```
sf project deploy start -m "ApexClass:BrokerPortalController" -m "ApexClass:BrokerPortalControllerTest" --ignore-conflicts -o DPEG-Acq-3
```

**Result:** `Status: Succeeded`  
**Deploy ID:** `0AfIm000009s6D5KAI`  
**Components:** 2/2 (100%) - both `BrokerPortalController` and `BrokerPortalControllerTest` created.

---

## Test Run Output

**Command:**
```
sf apex run test --tests BrokerPortalControllerTest --result-format human --wait 10 -o DPEG-Acq-3
```

**Test Run ID:** `707Im00000UzdVc`

| Test Method | Outcome | Runtime (ms) |
|---|---|---|
| BrokerPortalControllerTest.getFormMetadata_returnsActiveOptions | Pass | 44 |
| BrokerPortalControllerTest.submitDeal_happyPath_insertsStampedLead | Pass | 75 |
| BrokerPortalControllerTest.submitDeal_missingLastName_rejected | Pass | 5 |
| BrokerPortalControllerTest.submitDeal_missingFirm_rejected | Pass | 5 |
| BrokerPortalControllerTest.submitDeal_invalidEmail_rejected | Pass | 5 |
| BrokerPortalControllerTest.submitDeal_nonPositivePrice_rejected | Pass | 4 |
| BrokerPortalControllerTest.submitDeal_invalidAssetType_rejected | Pass | 5 |
| BrokerPortalControllerTest.submitDeal_badCoStarUrl_rejected | Pass | 10 |
| BrokerPortalControllerTest.submitDeal_honeypotFilled_skipsInsert | Pass | 7 |
| BrokerPortalControllerTest.submitDeal_openDuplicate_setsFlag | Pass | 83 |
| BrokerPortalControllerTest.submitDeal_closedDuplicate_doesNotSetFlag | Pass | 345 |
| BrokerPortalControllerTest.submitDeal_differentAddress_doesNotSetFlag | Pass | 87 |

**Summary:**
- Outcome: Passed
- Tests Ran: 12
- Pass Rate: 100%
- Fail Rate: 0%
- Total Execution Time: 675ms

---

## Fixes Required

### Fix 1: Reserved keyword `in` as parameter name

The plan used `in` as the parameter name for the `validate()` helper method (copied from the plan's `private static void validate(DealSubmission in) { ... }`). The word `in` is a reserved keyword in Apex and caused two compile errors:

```
Unexpected token 'in'. (129:49)
Unexpected token 'in'. (130:13)
```

**Fix applied:** Renamed the parameter from `in` to `sub` throughout the `validate()` method body. No behavior change - pure rename. First deploy failed; second deploy after fix succeeded.

---

## Class Summary

**BrokerPortalController.cls** (`without sharing`, API 62.0):
- DTOs: `DealSubmission`, `SubmitResult`, `PicklistOption`, `FormMetadata`
- `getFormMetadata()` - cacheable, describe-driven picklist options for `Asset_Type__c` and `Deal_Type__c`
- `submitDeal(DealSubmission input)` - honeypot check -> validate -> build Lead -> stamp protected fields -> dedup check -> assign to queue -> insert
- Helpers: `brokerQueueId()`, `trimToNull()`, `validate()`, `isValidEmail()`, `isValidUrl()`, `isValidPicklist()`, `isDuplicate()`

**BrokerPortalControllerTest.cls** (API 62.0, 12 test methods):
- Task 3: `getFormMetadata_returnsActiveOptions`
- Task 4: `submitDeal_happyPath_insertsStampedLead` (asserts field mapping, stamps, queue ownership)
- Task 5: `submitDeal_missingLastName_rejected`, `submitDeal_missingFirm_rejected`, `submitDeal_invalidEmail_rejected`, `submitDeal_nonPositivePrice_rejected`, `submitDeal_invalidAssetType_rejected`, `submitDeal_badCoStarUrl_rejected`, `submitDeal_honeypotFilled_skipsInsert`
- Task 6: `submitDeal_openDuplicate_setsFlag`, `submitDeal_closedDuplicate_doesNotSetFlag`, `submitDeal_differentAddress_doesNotSetFlag`

---

## Concerns

None. All 12 tests passed on the second deploy attempt. The only issue was the reserved-keyword bug in the plan itself, which was a straightforward rename with no impact on behavior.

---

## Final-review fixes

**Date:** 2026-06-22

### Changes Applied

**Fix 1 — Queue must fail closed (`BrokerPortalController.cls`, `submitDeal`):**
Replaced the `if (queueId != null) { l.OwnerId = queueId; }` block with a fail-closed guard that throws `AuraHandledException` when the queue is not found, then unconditionally assigns `l.OwnerId = queueId`.

**Fix 2 — Server-side length caps (`BrokerPortalController.cls`, `validate`):**
Added 8 length-check lines immediately before the `if (!errors.isEmpty())` throw in `validate()`: firstName (40), lastName (80), brokerageFirm (255), email (80), phone (40), propertyAddress (255), coStarLink (255), dealNotes (32768).

**Fix 3 — New validation tests (`BrokerPortalControllerTest.cls`):**
Added 5 new `@IsTest` methods: `submitDeal_missingPropertyAddress_rejected`, `submitDeal_missingEmail_rejected`, `submitDeal_capRateOutOfRange_rejected`, `submitDeal_invalidDealType_rejected`, `submitDeal_overLengthPropertyAddress_rejected`.

**Fix 4 — LWC max-length UX attributes (`brokerDealIntakeForm.html`):**
Added `max-length` to 5 `lightning-input` elements: firstName (`40`), lastName (`80`), brokerageFirm (`255`), email (`80`), phone (`40`).

### Deploy Result

**Command:** `sf project deploy start -m "ApexClass:BrokerPortalController" -m "ApexClass:BrokerPortalControllerTest" -m "LightningComponentBundle:brokerDealIntakeForm" --ignore-conflicts -o DPEG-Acq-3`

**Status:** Succeeded  
**Deploy ID:** `0AfIm000009s6FZKAY`  
**Components:** 3/3 (100%) — BrokerPortalController, BrokerPortalControllerTest, brokerDealIntakeForm  
**Members:** 7/7 (100%)

### Test Run Output

**Command:** `sf apex run test --tests BrokerPortalControllerTest --result-format human --wait 10 -o DPEG-Acq-3`  
**Test Run ID:** `707Im00000Uzdlt`

| Test Method | Outcome | Runtime (ms) |
|---|---|---|
| BrokerPortalControllerTest.getFormMetadata_returnsActiveOptions | Pass | 26 |
| BrokerPortalControllerTest.submitDeal_badCoStarUrl_rejected | Pass | 7 |
| BrokerPortalControllerTest.submitDeal_capRateOutOfRange_rejected | Pass | 5 |
| BrokerPortalControllerTest.submitDeal_closedDuplicate_doesNotSetFlag | Pass | 730 |
| BrokerPortalControllerTest.submitDeal_differentAddress_doesNotSetFlag | Pass | 323 |
| BrokerPortalControllerTest.submitDeal_happyPath_insertsStampedLead | Pass | 150 |
| BrokerPortalControllerTest.submitDeal_honeypotFilled_skipsInsert | Pass | 7 |
| BrokerPortalControllerTest.submitDeal_invalidAssetType_rejected | Pass | 7 |
| BrokerPortalControllerTest.submitDeal_invalidDealType_rejected | Pass | 6 |
| BrokerPortalControllerTest.submitDeal_invalidEmail_rejected | Pass | 6 |
| BrokerPortalControllerTest.submitDeal_missingEmail_rejected | Pass | 6 |
| BrokerPortalControllerTest.submitDeal_missingFirm_rejected | Pass | 7 |
| BrokerPortalControllerTest.submitDeal_missingLastName_rejected | Pass | 6 |
| BrokerPortalControllerTest.submitDeal_missingPropertyAddress_rejected | Pass | 6 |
| BrokerPortalControllerTest.submitDeal_nonPositivePrice_rejected | Pass | 7 |
| BrokerPortalControllerTest.submitDeal_openDuplicate_setsFlag | Pass | 142 |
| BrokerPortalControllerTest.submitDeal_overLengthPropertyAddress_rejected | Pass | 8 |

**Summary:**
- Outcome: Passed
- Tests Ran: 17
- Pass Rate: 100%
- Fail Rate: 0%
- Total Execution Time: 1449ms
