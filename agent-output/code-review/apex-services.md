# Code Review — Apex Service Layer + Async + Triggers + Handlers

**Review date:** 2026-07-21
**Reviewer:** salesforce-code-review subagent
**Scope:** 20 `*Service.cls`, 7 async/support classes (`TaskFanoutQueueable`, `TaskGroupDefProvider`, `TransactionTaskDefProvider`, `BrokerPortalNotifier`, `GroupNotifier`, `BrokerCheckInReminderSchedulable`, `TriggerHandler`), 4 triggers, 4 `*TriggerHandler.cls`. **35 files.**
**Binding standards:** `CLAUDE.md`, `ARCHITECTURE.md` §2, `.claude/rules/{apex-layering,bulk-test,invocable,salesforce-global}-rule.md`.
**Out of scope (not reviewed):** selectors, controllers, tests, LWC, metadata, and the 10 Site/Communities boilerplate classes.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| WARNING | 4 |
| SUGGESTION | 5 |
| PASSED (clean) | 28 files |

**No critical issues.** Layering is clean across the whole scope: **zero inline SOQL** in any service/handler/notifier (all delegated to selectors or CMDT providers), **zero `@future`** (async is Queueable + `System.Finalizer`), **zero hardcoded Salesforce Ids**, **no service constructs/throws `AuraHandledException`** (every `AuraHandledException` token is Javadoc describing the controller boundary), all 4 triggers are one-line delegations, one trigger per object, and all handlers are thin. The known `TaskFanoutService` synchronous DML ceiling is **mitigated** by the chunked Queueable.

The findings are documentation/layering-nuance items, not defects that change behaviour or open a security hole.

---

## WARNINGS (should fix)

### W1 — `without sharing` with no class-header justification (BrokerPortalNotifier.cls:1)
- **Rule:** ARCHITECTURE.md §2 Standards (non-negotiable): "`without sharing` only with written justification in the class header Javadoc."
- **Finding:** `public without sharing class BrokerPortalNotifier` has **no class-header Javadoc at all** — the file opens directly on the class declaration. The inline comment at lines 14-17 justifies the *selectors'* `SYSTEM_MODE`, not the class's own `without sharing`.
- **Why it matters:** the next developer copying this notifier has nothing telling them the `without sharing` is deliberate vs an oversight. Against a non-negotiable standard.
- **Recommended fix (do not apply):** add a class-header Javadoc block stating the purpose and an explicit sharing justification, mirroring `BrokerPortalService`'s pattern (why the notifier must resolve the notification type / queue / lead across users). Keep the keyword.

### W2 — `without sharing` justification absent from class header (GroupNotifier.cls:11)
- **Rule:** ARCHITECTURE.md §2 Standards.
- **Finding:** the class carries a header Javadoc (lines 1-10) describing purpose and the degrade-to-warning posture, but **never states why it runs `without sharing`**. The reason (resolving public-group / queue membership and the notification type regardless of the running user's sharing) is inferable but not written.
- **Recommended fix (do not apply):** add one sentence to the header tying the `without sharing` keyword to the cross-user group/notification-type resolution it performs.

### W3 — `without sharing` justification thin / not explicit in class header (ApprovalAuditService.cls:15)
- **Rule:** ARCHITECTURE.md §2 Standards. (Task explicitly asked to verify this class.)
- **Finding:** the header explains the *purpose* (reads `ProcessInstanceStep` approval history that field-updates can't capture) and the defensive posture, but does **not** explicitly justify the `without sharing` keyword the way `BrokerPortalService` does. **Mitigation:** ARCHITECTURE.md §2 Key Apex Services table does document this service as `without sharing`, and the method comment at lines 106-112 explains the selector's `without sharing + SYSTEM_MODE`. So the intent is architecturally sanctioned — the gap is only that the class header itself doesn't restate it as a sharing justification. This is the softest of the three W1-W3.
- **Recommended fix (do not apply):** add an explicit inline sharing-justification line to the class header (e.g. "`without sharing`: stamps audit fields and reads the full `ProcessInstanceStep` trail regardless of the running approver's sharing").

### W4 — Service depends on a Controller and lets `AuraHandledException` flow through the service layer (StageAdvanceService.cls:64-68)
- **Rule:** `.claude/rules/apex-layering-rule.md` (Service layer contract; Controller is the `AuraHandledException` boundary, not a service dependency).
- **Finding:** `advance()` calls `OpportunityApprovalController.submitForApproval(recordId)` and returns/propagates its `AuraHandledException` up through `StageAdvanceService`. That is a Service → Controller dependency (reverse layering) plus a transport-layer exception type transiting the service layer.
- **Mitigation / honesty check:** the class header (lines 19-25) documents this openly as "the lesser layering compromise," notes `submitForApproval` is "functionally an approval-submission service exposed under a `*Controller` name for historical reasons," and scopes the rename out of P6. The justification is honest and checks out (unlike a header that miscites a rule) — so this is WARNING + tracked debt, **not** CHANGES REQUIRED.
- **Recommended fix (do not apply):** track an extraction item to rehome `submitForApproval` into an `ApprovalSubmissionService` and have `StageAdvanceService` call that, keeping the `AuraHandledException` construction at the controller.

---

## SUGGESTIONS (nice to have)

- **S1 — BrokerPortalNotifier.cls:10:** the `@InvocableMethod notifyNewLeads(List<Id> leadIds)` uses a raw `List<Id>` rather than a `List<InputDTO>` with `@InvocableVariable` inner class. It **is** bulk-safe (a List), so it satisfies the core intent of `invocable-rule.md`, but the repo's three other invocables (`TaskFanoutService.InputDTO`, `ApprovalAuditService.Request`, `GroupNotifier.Request`) all wrap input in a DTO per rule item 3. Consider aligning for consistency; low priority since `List<Id>` is Flow-compatible and bulk-safe.
- **S2 — ContractExecutionService.cls:62:** `Target_Close_Date__c = Date.today().addDays(60)` — magic number `60`. Consider a named constant (e.g. `DEFAULT_CLOSE_HORIZON_DAYS`).
- **S3 — OnboardingTaskRollupService.cls:** the public `recalc` method and the class have only inline comments, no ApexDoc header — inconsistent with the other P6 services which all carry full Javadoc.
- **S4 — BrokerPortalNotifier.cls:** no class-header Javadoc describing the class purpose (separate from the W1 sharing point) — every sibling class in scope carries one.
- **S5 — Notification sends inside loops** (`GroupNotifier.notify` line 88, `BrokerPortalNotifier.notifyNewLeads` line 34): each iteration builds a per-record `Messaging.CustomNotification` with distinct target/title/body, so batching into a single send is not possible and the loop is the correct design. Noted only to confirm it was reviewed and is **not** a governor-limit concern (bounded by input list size, no SOQL/DML in the loop).

---

## Verification notes (things checked and found compliant)

- **Inline SOQL:** none. Every `[SELECT` token in scope is inside a comment in `TaskGroupDefProvider` / `TransactionTaskDefProvider` describing the query they replaced with `getAll()`. CMDT-via-`getAll()` (not a selector) is the correct pattern for `__mdt` and is documented in both providers.
- **`@future`:** none. `TaskFanoutQueueable` uses `Queueable` + `System.attachFinalizer` + a chained `ChainFinalizer`, advancing the chain from the Finalizer so a failed chunk doesn't strand the rest. Compliant with the async standard.
- **`AuraHandledException` in services:** none constructed/thrown. Services throw typed domain exceptions (`SubmissionException`, `CounterOfferException`, `LeaseInquiryException`, etc.) or raw platform `DmlException`/`QueryException`, leaving the `AuraHandledException` mapping to controllers. Compliant with ARCHITECTURE.md §5.
- **Bulkification:** trigger-invoked services (`ContractExecutionService`, `OpportunityReviewService`, `LeadConvertService`, `TaskRollupService`, `OnboardingTaskRollupService`, `ApprovalAuditService`) all take collections and accumulate DML outside loops. Controller-support P6 services take single-record args by design (single-user UI actions) — acceptable, not a trigger path.
- **`TaskFanoutService` DML ceiling:** the header documents the ~116-Transaction synchronous ceiling (200 × 82 tasks > 10,000 DML rows). `fanOut()` enqueues exactly one Queueable; `TaskFanoutQueueable` processes `CHUNK_SIZE = 100` per job (~8,200 rows < 10,000) and chains the remainder. Ceiling is **mitigated**, not an open risk.
- **`System.debug`:** the 6 occurrences (ApprovalAuditService, BrokerPortalNotifier, GroupNotifier ×3, TaskFanoutQueueable) are all catch-block error diagnostics — the established repo convention — and are **not** flagged (see review memory `review-standard-system-debug.md`). The standing critique is program-level (no durable error sink), not per-PR.
- **Triggers:** `ContractReviewTrigger`, `LeadConvertTrigger`, `OpportunityReviewTrigger`, `TaskRollupTrigger` are each one line delegating to their handler; one trigger per object; no logic/SOQL/DML in the trigger body.
- **Handlers:** all four extend the `TriggerHandler` base, override only the contexts they act on, and route to services with no SOQL/DML/business logic. The `TaskRollupTriggerHandler` id-projection is a mechanical lookup projection (documented Domain-vs-handler decision), not business logic.
- **Recursion:** `OpportunityReviewService` re-fires the Opportunity after-update trigger via its primary-stamp updates, but is naturally idempotent (stage-unchanged guard + selector-based existence checks + insert-only NDA on the insert context), so no infinite recursion and no static flag needed.
- **Hardcoded Ids:** none. RecordTypes/queues/notification types are resolved by DeveloperName via selectors. `GroupNotifier`'s `'005'` is the User key-prefix constant, not a record Id.

---

## File-by-file

| File | Status | Notes |
|------|--------|-------|
| ContractReviewTrigger.trigger | PASS | one-line delegation |
| LeadConvertTrigger.trigger | PASS | one-line delegation |
| OpportunityReviewTrigger.trigger | PASS | one-line delegation |
| TaskRollupTrigger.trigger | PASS | one-line delegation |
| TriggerHandler.cls | PASS | base router, `with sharing`, bulk-safe |
| ContractReviewTriggerHandler.cls | PASS | thin, delegates |
| LeadConvertTriggerHandler.cls | PASS | thin, delegates |
| OpportunityReviewTriggerHandler.cls | PASS | thin, delegates |
| TaskRollupTriggerHandler.cls | PASS | thin, id-projection only |
| ApprovalAuditService.cls | WARNING | W3 (without-sharing header justification thin) |
| BrokerPortalService.cls | PASS | `without sharing` fully & explicitly justified |
| BrokerPortalNotifier.cls | WARNING | W1 (no header / no sharing justification) + S1, S4 |
| GroupNotifier.cls | WARNING | W2 (sharing justification absent from header) |
| GroupNotifier / notifier loop | PASS | S5 (send-in-loop is correct design) |
| BrokerCheckInReminderSchedulable.cls | PASS | Schedulable, selectors, bulk insert |
| TaskFanoutService.cls | PASS | invocable List-in/void, ceiling mitigated |
| TaskFanoutQueueable.cls | PASS | Queueable + Finalizer + chunking |
| TaskGroupDefProvider.cls | PASS | CMDT `getAll()`, not a selector (correct) |
| TransactionTaskDefProvider.cls | PASS | CMDT `getAll()`, not a selector (correct) |
| ContractExecutionService.cls | PASS | S2 (magic number 60) |
| OpportunityReviewService.cls | PASS | idempotent, bulkified |
| LeadConvertService.cls | PASS | `Database.insert(allOrNone=false)` intentional |
| TaskRollupService.cls | PASS | in-memory counts, bulk update |
| OnboardingTaskRollupService.cls | PASS | S3 (missing ApexDoc) |
| DispositionService.cls | PASS | controller-support, single-record |
| DispositionTaskService.cls | PASS | controller-support, find-or-create |
| WireService.cls | PASS | controller-support, upsert |
| CounterOfferService.cls | PASS | typed exception, 2-DML documented |
| PsaVersionService.cls | PASS | typed exception, 2-DML documented |
| StageAdvanceService.cls | WARNING | W4 (service→controller / AHE propagation, documented) |
| TransactionTaskService.cls | PASS | single-record updates |
| OnboardingService.cls | PASS | delegates rollup to rollup service |
| LeaseRenewalService.cls | PASS | savepoint discipline |
| DealMessageService.cls | PASS | describe-based parent resolution |
| LeaseInquiryService.cls | PASS | savepoint/rollback well-formed |
| BrokerAssignmentService.cls | PASS | savepoint on multi-DML |

---

## Verdict

**APPROVED WITH WARNINGS** — no critical or blocking issues in this scope. The 4 warnings are documentation completeness (`without sharing` header justifications: W1-W3) and one honestly-documented layering deferral (W4). Recommend fixing W1-W3 in this iteration (cheap, comment-only) and tracking W4 as an extraction item; the deployment need not be blocked on them.
