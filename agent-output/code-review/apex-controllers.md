# Code Review — Apex @AuraEnabled Controller Layer

**Reviewer:** salesforce-code-review subagent
**Date:** 2026-07-21
**Scope:** 25 `@AuraEnabled` controllers under `force-app/main/default/classes/` (the 10 Site/Communities boilerplate classes excluded per ARCHITECTURE.md §2 Scope).
**Standards applied:** ARCHITECTURE.md §2 (Apex layering) + §5 (LWC boundary), `.claude/rules/apex-layering-rule.md`, `.claude/rules/salesforce-global-rule.md`.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| WARNING | 3 |
| SUGGESTION | 1 (cross-cutting) |
| Clean files | 23 / 25 |

**Verdict for this scope: APPROVED WITH WARNINGS.**

The controller layer is in strong shape. Every in-scope controller is `with sharing` (the sole `without sharing`, `BrokerPortalController`, carries a thorough, security-critical justification header — compliant with the Standards escape hatch). No inline SOQL anywhere — all reads go through selectors or the `TaskGroupDefProvider` CMDT provider. No hardcoded Ids, no TODO/FIXME, no dead code. Write controllers correctly delegate DML/business logic to their P6 services and re-throw `AuraHandledException` via the repo-standard `ahe()` helper. Two controllers have gaps in the §5 exception boundary, and one recurring comment overstates the reliability of the debug log.

---

## WARNINGS (should fix)

### W1 — LeaseInquiryController: 6 read methods have no try/catch → can leak raw exceptions past the §5 boundary
**File:** `LeaseInquiryController.cls`
**Lines:** 48 (`getLog`), 130 (`getHomeKpis`), 176 (`getRecentInquiries`), 190 (`getPipelineByStage`), 215 (`getAttention`), 250 (`getLeaseSummary`)
**Rule:** ARCHITECTURE.md §5 — "Apex methods throw `AuraHandledException` (never raw exceptions)."
**Problem:** Only the write method `addUpdate()` (line 93) is wrapped in try/catch. All six read methods invoke selectors directly with no boundary. If a selector throws (e.g. `LeaseInquirySelector.selectRequiredById` on a deleted/invalid Id at line 55, or `RenewalActivity`-style query failure), the raw `QueryException`/`NullPointerException` propagates to the LWC — leaking field/object API-name internals and violating the §5 boundary. This is the one in-scope controller that deviates from the otherwise-uniform pattern; its direct sibling `LeaseRenewalController` wraps *every* method (read and write) exactly as required.
**Fix:** Wrap each read method body in try/catch and re-throw `ahe(READ_FAILURE_MESSAGE)` after a catch-block `System.debug(LoggingLevel.ERROR, ...)`, mirroring `LeaseRenewalController.getTimeline`/`getHomeKpis`. Add a `READ_FAILURE_MESSAGE` constant (the class currently defines only `DML_FAILURE_MESSAGE`). Note: the header no longer miscites the layering rule — P6 correctly moved the DML into `LeaseInquiryService`, so no header change is needed here.

### W2 — OpportunityApprovalController: raw platform exception message surfaced to the user
**File:** `OpportunityApprovalController.cls`
**Line:** 39 — `throw ahe(e.getMessage());`
**Rule:** ARCHITECTURE.md §5 — user-safe, fixed message required; do not surface raw platform/exception text.
**Problem:** In the `catch (Exception e)` around `Approval.process()` (lines 30–40), the fallback path (when the deal *is* at Underwriting/LOI but the submission still fails) re-throws `e.getMessage()` verbatim. `e` here is an untyped platform `Exception`, not a curated/typed user-actionable exception, so its raw text (approval-engine internals, lock errors, validation-rule text) reaches the user. The curated stage-mismatch branch above it (lines 35–38) is good; only the line-39 fallback leaks.
**Secondary (same class):** the pre-`try` validation reads sit outside any boundary — `resolveDealId(recordId)` (line 17, which calls `LoiSelector`/`UnderwritingSelector`/`ContractReviewSelector` "required" selectors) and `ProcessInstanceSelector.selectPendingByTargetId` (line 22), plus `OpportunitySelector.selectStageRequiredById` inside the catch (line 34). A `QueryException` from any of these leaks raw to the LWC. `resolveDealId`'s own `ahe(...)` throws are fine.
**Fix:** Replace line 39 with a fixed generic constant (e.g. `throw ahe(SUBMIT_FAILURE_MESSAGE)`) after logging `e` at ERROR; keep the curated stage-mismatch message. Bring the pre-try/in-catch selector reads under the boundary so a query failure maps to a user-safe message.

### W3 — OpportunityApprovalController: business logic / approval orchestration lives in the controller (layering)
**File:** `OpportunityApprovalController.cls` (whole class)
**Rule:** `.claude/rules/apex-layering-rule.md` — Controller row: "Thin: call service, catch `AuraHandledException`"; prohibits business logic. ARCHITECTURE.md §2.
**Problem:** Unlike the P6-thinned write controllers (which delegate to a `*Service`) and the P6 read-only controllers (which only wrap selector reads), this controller holds real orchestration in-line: parent-deal resolution (`resolveDealId`), the duplicate-pending gate, the `Approval.ProcessSubmitRequest` submission, and the stage-based error-message derivation. This is exactly the logic the rules reserve for a service (an `OpportunityApprovalService` analogous to `StageAdvanceService`). It was not part of the P6 controller-thinning sweep (not listed among the 13 new services nor the read-only "kept no service" set).
**Severity rationale:** Treated as **WARNING, not CHANGES REQUIRED** — consistent with the standing review stance that pre-existing controller logic deferred by prior accepted phases is a tracked-extraction item, not a blocker, provided the change under review does not *introduce* it (it does not; this is existing code). Recommend logging an extraction item to move this into an `OpportunityApprovalService`.

---

## SUGGESTIONS (nice to have)

### S1 — "detail goes to the debug log (admin-only)" comment overstates the debug log as a reliable sink (cross-cutting)
**Files:** recurring in `BovController` (l.28–30), `BrokerAssignmentController` (l.24–27), `BrokerController` (l.10–13), `BrokerFirmController` (l.8–10), `BrokerListingController` (l.17–19), `CounterOfferController`, `DealMessageController`, `DispositionController`, `DispositionTaskController`, `LeaseInquiryController`, `LeaseRenewalController`, `OnboardingController`, `OpportunityDocStatusController`, `OpportunityFunnelController`, `PsaVersionController`, `RentRollController`, `SellMeterController`, `StageAdvanceController`, `TransactionController`, `TransactionTaskController`, `WireController`, `WorkOrderController`.
**Problem:** The masking pattern itself is correct and is the repo standard — the concern is only the comment. A `System.debug` line only lands anywhere if a trace flag is active on that user at that moment; the codebase has no durable error sink (no Platform Event logger, no log object). Comments that describe the debug log as an admin-visible channel imply a reliability it does not have.
**Fix:** Soften the comment wording (e.g. "detail is logged at ERROR for diagnostics when trace logging is enabled"). The catch-block `System.debug(LoggingLevel.ERROR, ...)` calls are the established repo convention and are **not** flagged. The real remediation — a durable error sink — is a program-level item, not a per-PR one.

---

## File-by-file

| File | Status | Notes |
|------|--------|-------|
| BovController.cls | Clean | Selector reads, `ahe()` boundary on both methods. |
| BrokerAssignmentController.cls | Clean | Reads buffer one selector query; 4 writes delegate to `BrokerAssignmentService`; typed validation surfaced verbatim, platform failures masked. |
| BrokerController.cls | Clean | Read-only, selectors, boundary. |
| BrokerFirmController.cls | Clean | Read-only, selectors, boundary. |
| BrokerListingController.cls | Clean | Read-only, selector, boundary. |
| BrokerPortalController.cls | Clean | `without sharing` justified (guest anti-abuse dedup); delegates to `BrokerPortalService`; typed `SubmissionException` verbatim, platform masked. |
| CounterOfferController.cls | Clean | Delegates to `CounterOfferService`; typed exception verbatim. |
| DealMessageController.cls | Clean | Delegates to `DealMessageService`; two typed exceptions verbatim. |
| DispositionController.cls | Clean | Delegates find-or-create to `DispositionService`. |
| DispositionTaskController.cls | Clean | Delegates to `DispositionTaskService`; `getClosingTasks` correctly non-cacheable (self-seeds). |
| LeadFunnelController.cls | Clean | Read-only, selectors, boundary. |
| **LeaseInquiryController.cls** | **WARNING** | **W1** — 6 read methods lack try/catch (§5 boundary gap). Writes/layering fine. |
| LeaseRenewalController.cls | Clean | Every method wrapped; delegates to `LeaseRenewalService`. Reference pattern for W1 fix. |
| OnboardingController.cls | Clean | Delegates to `OnboardingService`; all reads wrapped. |
| **OpportunityApprovalController.cls** | **WARNING** | **W2** raw message leak (l.39); **W3** business logic in controller. |
| OpportunityDocStatusController.cls | Clean | Read-only, selectors, boundary. |
| OpportunityFunnelController.cls | Clean | Read-only, selectors, boundary. |
| PsaVersionController.cls | Clean | Delegates to `PsaVersionService`; typed exception verbatim. |
| RentRollController.cls | Clean | Read-only, selector, boundary. |
| SellMeterController.cls | Clean | Read-only, selectors, boundary. |
| StageAdvanceController.cls | Clean | Delegates to `StageAdvanceService`; approval `AuraHandledException` propagated unchanged, typed exception verbatim. |
| TransactionController.cls | Clean | Read-only, selectors, boundary. |
| TransactionTaskController.cls | Clean | Delegates to `TransactionTaskService`; typed `WireVerificationException` verbatim. |
| WireController.cls | Clean | Delegates to `WireService`; re-reads and shapes; `saveWire` correctly non-cacheable. |
| WorkOrderController.cls | Clean | Read-only Yardi mirror, selectors, boundary. |
