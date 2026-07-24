# Code Review — Apex Selector Layer

**Review date:** 2026-07-21
**Reviewer:** salesforce-code-review subagent (READ-ONLY)
**Scope:** `force-app/main/default/classes/*Selector.cls` — 37 files
**Binding standards:** `ARCHITECTURE.md` §2, `.claude/rules/apex-layering-rule.md`, `.claude/rules/salesforce-global-rule.md`, `.claude/rules/invocable-rule.md`, `.claude/rules/bulk-test-rule.md`

---

## Summary

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | 0 |
| 🟡 WARNING | 0 |
| 🟢 SUGGESTION | 3 |
| ✅ PASSED (files clean) | 37 / 37 |

**Verdict for this scope: APPROVED.**

The selector layer is in full conformance with the layering contract. Every query enforces an access mode; every `SYSTEM_MODE` read carries a written justification in the method or class header; every dynamic query is injection-safe (bind variables, describe allow-lists, or selector-owned constants only); no selector contains DML, business logic, callouts, or cross-object orchestration; each selector owns SOQL for exactly one primary object (child sub-queries and parent traversals aside). The three items below are cosmetic consistency nits, not rule violations.

---

## Access-mode census (USER_MODE vs SYSTEM_MODE)

Every query in scope uses `WITH USER_MODE` / `AccessLevel.USER_MODE`, **except** the eight `SYSTEM_MODE` reads below. All eight are justified in the class/method Javadoc, and each justification checks out against the cited rationale (guest/automation path on a non-deployable Guest Profile, or a setup/metadata object with no FLS/sharing to enforce, or an audit read that must see the full approval trail).

| # | Class.method | Mode | `without sharing`? | Justified? | Rationale (verified in header) |
|---|--------------|------|--------------------|------------|--------------------------------|
| 1 | `LeadSelector.selectByIdsSystem` | SYSTEM_MODE | no (outer `with sharing`) | ✅ | Guest/automation Broker-Portal notifier; guest FLS on non-deployable Guest Profile (P3 spike incomplete). |
| 2 | `LeadSelector.GuestReads.selectOpenDuplicatesByAddressSystem` | SYSTEM_MODE | yes (inner `without sharing`) | ✅ | Guest anti-abuse dedup must see all open leads at an address regardless of guest sharing; preserves original `without sharing` controller query. |
| 3 | `ContactSelector.GuestReads.selectBrokerPriorityByEmailSystem` | SYSTEM_MODE | yes (inner `without sharing`) | ✅ | Guest broker-priority lookup; same guest-context rationale. |
| 4 | `ProcessInstanceStepSelector.AuditReads.selectApprovedStepsByTargetIds` | SYSTEM_MODE | yes (inner `without sharing`) | ✅ | Audit stamp must see the full approval trail — final approver is usually not the running user; preserves original no-WITH audit read. |
| 5 | `NotificationTypeSelector.selectByDeveloperName` | SYSTEM_MODE | no | ✅ | Guest notifier; `CustomNotificationType` is a setup/metadata object with no guest FLS. DeveloperName→Id lookup, not user data. |
| 6 | `GroupMemberSelector.selectByGroupIds` | SYSTEM_MODE | no | ✅ | Setup object (no FLS/sharing); automation/guest notifier (`GroupNotifier` is `without sharing`). Group-membership resolution. |
| 7 | `QueueGroupSelector.selectQueueByDeveloperName` | SYSTEM_MODE | no | ✅ | Setup object; guest path. DeveloperName→Id queue lookup. |
| 8 | `QueueGroupSelector.selectRegularAndQueueByDeveloperNames` | SYSTEM_MODE | no | ✅ | Setup object; guest/automation path. `Type IN ('Regular','Queue')` literals only, names bound. |

`without sharing` on the four inner classes (`LeadSelector.GuestReads`, `ContactSelector.GuestReads`, `ProcessInstanceStepSelector.AuditReads`) is declared explicitly (inner classes do not inherit outer sharing) and justified in the class header per the ARCHITECTURE §2 Standards escape hatch — honest justifications, each pointing at the behaviour it preserves and the pre-promotion guest-sharing caveat.

---

## Dynamic-SOQL injection safety

All dynamic queries are safe:

- `TransactionSelector.selectByIdsWithConditionFields` — condition field names are validated against the live `Transaction__c` describe allow-list before concatenation; record filter is a bound `:ids` via `Database.queryWithBinds`. Safe (defense-in-depth).
- `DealMessageSelector.selectByParent` — `parentField` checked against the `PARENT_FIELDS` allow-list (throws `QueryException` on anything else); `recordId` bound via `Database.queryWithBinds`. Safe.
- `LeaseRenewalSelector.selectRecent` / `selectAttention` — built from the selector-owned `ROW_FIELDS` constant + literal WHERE/ORDER tails; no caller string concatenated. Safe.
- `WorkOrderSelector.selectRecentOpen` / `selectEscalations` / `selectUntouched` — same pattern (selector-owned `ROW_FIELDS` + literal tails). Safe.
- `OpportunitySelector.countByStageInLastNDays`, `LeadSelector.countConvertedInLastNDays` / `countDisqualifiedInLastNDays` — dynamic only for the `LAST_N_DAYS:n` literal (n cannot be bound); `days` coerced via `Integer.valueOf(...)`, status passed as a real bind. Safe.
- `RecordTypeSelector`, all other selectors — static SOQL with bind variables. Safe.

---

## Purity / layering

No selector contains DML, callouts, or cross-object business orchestration. The only in-method logic present is query construction (field-list assembly for the two describe/allow-list dynamic selectors) and null/empty guards that short-circuit to empty collections — both legitimate selector responsibilities. Every selector is `public with sharing`. Each queries exactly one primary object; child sub-queries (`Wires__r`, `Rent_Steps__r`) and parent traversals (`Account.Name`, `Property__r.Asset_Type__c`, `Logged_By__r.Name`, `CreatedBy.Name`) are in-scope for their owning selector.

`TaskSelector.selectOpenByWhatIdsAndSubjectPrefix` has no in-module consumer yet — this is documented as the pre-agreed Property-Management contract (covered by its own `runAs` USER_MODE test), not dead code. Accepted.

---

## 🟢 SUGGESTIONS (cosmetic — not blocking)

### S1 — `UnitSelector.cls:15` — stale "API 66" in the MODE comment
The class header reads `MODE — WITH USER_MODE (API 66).` Every other selector says API 67, and `ARCHITECTURE.md` states the repo is uniformly 67.0 (LWC exception aside). No functional impact (the clause is `WITH USER_MODE` regardless), but the comment is inconsistent with the rest of the layer.
**Fix:** update the comment to `(API 67)`.

### S2 — `WireSelector.cls:85-92` — `selectRequiredById` omits `LIMIT 1`
Every other `selectRequiredById` in the layer (`TaskSelector`, `BrokerAssignmentSelector`, `LeaseInquirySelector`, `LeaseRenewalSelector`, `WorkOrderSelector`, plus the Opportunity/Underwriting/LOI/ContractReview `...RequiredById` methods) closes with `LIMIT 1`. The Wire version does not. Functionally safe — it filters on a unique `Id`, so the single-row assignment resolves to exactly 0 or 1 rows and preserves the documented "throws `System.QueryException` on a miss" contract — but it is the one outlier from the otherwise-uniform pattern.
**Fix:** add `LIMIT 1` for consistency with the pilot pattern the class header cites.

### S3 — Inlined picklist string literals where siblings use a named constant
Several selectors inline picklist/type literals in the WHERE clause instead of extracting a named constant the way their siblings do (`TransactionSelector.STATUS_ACTIVE`, `ProcessInstanceSelector.STATUS_PENDING`, `OnboardingSelector.DONE_STAGE`, `ProcessInstanceStepSelector.STEP_STATUS_APPROVED`):
- `BrokerAssignmentSelector.cls:80` — `Status__c = 'Active'`
- `LeaseInquirySelector.cls:117,135` — `Status__c = 'Active'`
- `LeaseRenewalSelector.cls:72` — `Status__c = 'Active'` (inside dynamic string)
- `QueueGroupSelector.cls:46,76` — `Type = 'Queue'` / `Type IN ('Regular','Queue')`

Per the review checklist, repeated string literals are a 🟢 SUGGESTION (missing constants), not a defect. Extracting them would improve consistency and make a future picklist-value rename a single-line change.

---

## File-by-file result

All 37 files: ✅ 0 critical, 0 warning. Suggestion-tagged files noted below; all others fully clean.

| File | Critical | Warning | Suggestion |
|------|----------|---------|------------|
| BovSubmissionSelector.cls | 0 | 0 | 0 |
| BrokerAssignmentSelector.cls | 0 | 0 | 1 (S3) |
| BrokerListingSelector.cls | 0 | 0 | 0 |
| ConstructionFeasibilityReviewSelector.cls | 0 | 0 | 0 |
| ContactSelector.cls | 0 | 0 | 0 |
| ContentDocumentLinkSelector.cls | 0 | 0 | 0 |
| ContentNoteSelector.cls | 0 | 0 | 0 |
| ContractReviewSelector.cls | 0 | 0 | 0 |
| CounterOfferSelector.cls | 0 | 0 | 0 |
| DealMessageSelector.cls | 0 | 0 | 0 |
| DevelopmentFeasibilityReviewSelector.cls | 0 | 0 | 0 |
| DispositionSelector.cls | 0 | 0 | 0 |
| GroupMemberSelector.cls | 0 | 0 | 0 |
| LeadSelector.cls | 0 | 0 | 0 |
| LeaseActivitySelector.cls | 0 | 0 | 0 |
| LeaseInquirySelector.cls | 0 | 0 | 1 (S3) |
| LeaseRenewalSelector.cls | 0 | 0 | 1 (S3) |
| LeaseSelector.cls | 0 | 0 | 0 |
| LoiSelector.cls | 0 | 0 | 0 |
| NdaSelector.cls | 0 | 0 | 0 |
| NotificationTypeSelector.cls | 0 | 0 | 0 |
| OnboardingSelector.cls | 0 | 0 | 0 |
| OpportunitySelector.cls | 0 | 0 | 0 |
| ProcessInstanceSelector.cls | 0 | 0 | 0 |
| ProcessInstanceStepSelector.cls | 0 | 0 | 0 |
| PropertyAssetSelector.cls | 0 | 0 | 0 |
| PsaVersionSelector.cls | 0 | 0 | 0 |
| QueueGroupSelector.cls | 0 | 0 | 1 (S3) |
| RecordTypeSelector.cls | 0 | 0 | 0 |
| RenewalActivitySelector.cls | 0 | 0 | 0 |
| TaskSelector.cls | 0 | 0 | 0 |
| TransactionSelector.cls | 0 | 0 | 0 |
| UnderwritingSelector.cls | 0 | 0 | 0 |
| UnitSelector.cls | 0 | 0 | 1 (S1) |
| WireSelector.cls | 0 | 0 | 1 (S2) |
| WorkOrderActivitySelector.cls | 0 | 0 | 0 |
| WorkOrderSelector.cls | 0 | 0 | 0 |

---

## Verdict

**✅ APPROVED (selector scope).** No critical or warning-level findings. Three cosmetic suggestions (S1 stale API-version comment, S2 missing `LIMIT 1` on one `selectRequiredById`, S3 inlined picklist literals) may be picked up in a future tidy-up but do not block deployment.
