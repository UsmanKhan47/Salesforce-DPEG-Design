# Phase 0 — Manual Flow Exercise Script (API 62.0 → 67.0 Uplift)

**Prepared:** 2026-07-15
**Target org:** DPEG-Acq-5

## Why this script exists

`sf apex run test --test-level RunLocalTests` only executes Apex test methods. It proves Apex classes/triggers still compile and pass their assertions at API 67.0. **It does not invoke a single Flow.** All 23 Flows in this change jumped 62.0 → 67.0 (five major API releases) with zero automated coverage — Flows have no equivalent of Apex unit tests in this org. This script is the only verification these 23 Flows get before/around this deploy. Run it against the org **after** the real deploy is approved and executed (not the check-only validation, which makes no org changes) — this document is prepared now so it is ready to execute immediately once that gate opens.

Each step: **Setup** → **Action** → **Expected Result** → **Pass/Fail**. Record actual results inline as you go. If any step fails, stop, capture the record Id and exact error/behavior, and consult `agent-output/P0-rollback-plan.md` before continuing to the next flow.

---

## Priority 1 — `Transaction_Task_Fanout` (test FIRST, in isolation)

**Object:** `Transaction__c` | **Trigger:** Record-triggered, After Save, Create or Update | **Entry condition:** `Contract_Executed_Date__c` is not null AND `Tasks_Fanned_Out__c = false` | **Action:** invokes `TaskFanoutService.fanOut()` (Apex) which reads `Task_Group_Def__mdt` / `Transaction_Task_Def__mdt` and inserts the Day-0 task checklist (~75 Task records) as children via `Transaction_Deal__c`.

**⚠️ Known defect — do not use a bulk/mass-created batch of Transactions for this test.** `TaskFanoutService` has a documented, not-yet-fixed DML-limit bug: 251 Transactions × ~75 Tasks ≈ 18,825 rows exceeds the 10,000-row single-transaction DML limit (fix is scoped for Phase 7). Test with **one single Transaction record**, created/updated **individually** (not via a data-loader batch), so this exercise verifies the apiVersion bump in isolation and does not also trip the pre-existing limit bug and produce a false "regression."

1. **Setup:** Create one net-new `Transaction__c` record (or use an existing one where `Tasks_Fanned_Out__c = false`). Leave `Contract_Executed_Date__c` blank initially.
2. **Action:** Save the record with `Contract_Executed_Date__c` still blank.
   **Expected:** No tasks created (entry condition not met — `IsNull` filter on `Contract_Executed_Date__c` fails).
3. **Action:** Edit the same Transaction and set `Contract_Executed_Date__c` = today. Save.
   **Expected:** The flow fires once. The full Day-0 task checklist is created as `Task` records related via `Transaction_Deal__c` (not `WhatId` — checklist tasks are deliberately kept off the standard Activity timeline). Check the Transaction's related list / a SOQL count: `SELECT COUNT() FROM Task WHERE Transaction_Deal__c = '<id>'` should return the full definition count from `Transaction_Task_Def__mdt` (conditional groups, e.g. Financing, only appear if their gating field, e.g. `Loan_Required__c`, is true on this Transaction). `Tasks_Fanned_Out__c` should now read `true` on the Transaction.
4. **Action:** Save the same Transaction again (e.g. touch an unrelated field) without changing `Tasks_Fanned_Out__c`.
   **Expected:** No duplicate tasks are created — dedupe guard (`Tasks_Fanned_Out__c == true` skips re-fan-out) holds.
5. **Pass/Fail:** ______

---

## Priority 2 — `LOI_Approval_Stamp`

**Object:** `Opportunity` | **Trigger:** After Save, Create or Update | **Entry condition:** `LOI_Approved__c = true` | **Actions:** Custom notification to `Acquisitions_Team` ("LOI approved - send to broker"), custom notification to `LOI_Panel` group ("LOI approved by principals (FYI)"), invokes `ApprovalAuditService.stampApprovalAudit()` with `gate = 'LOI'`.

1. **Setup:** Find (or create via the existing `LOI_Approval` approval process) an Opportunity with an associated LOI in an approvable state, so that `LOI_Approved__c` can legitimately flip to `true` (normally set by the approval process's final-approval field update — do not hand-set it via a data tool if the org's approval process is the intended path; use the approval process to get a realistic transition).
2. **Action:** Drive the Opportunity's LOI through the `LOI_Approval` approval process to final approval (this sets `LOI_Approved__c = true`).
   **Expected:** Two custom notifications fire (Acquisitions Team + LOI Panel FYI). The Opportunity's Primary LOI gets `LOI_Status = Approved`, `Approved_By__c`, `Approved_Date__c`, and `Approval_Comments__c` populated by `ApprovalAuditService` (reading `ProcessInstanceStep`).
3. **Pass/Fail:** ______

---

## Priority 3 — `Opportunity_UW_Approved_Notify`

**Object:** `Opportunity` | **Trigger:** After Save, Create or Update | **Entry condition:** `Underwriting_Status__c = 'Approved by Principals'` | **Actions:** Custom notification to `Acquisitions_Team` ("Underwriting approved - LOI pending"), invokes `ApprovalAuditService.stampApprovalAudit()` with default gate (Underwriting) — stamps `UW_Approved_By__c` / `UW_Approval_Date__c` on the Opportunity.

1. **Setup:** Find an Opportunity in Underwriting with an in-flight or startable Underwriting approval process.
2. **Action:** Approve the underwriting so `Underwriting_Status__c` transitions to `Approved by Principals`.
   **Expected:** Custom notification fires to Acquisitions Team. `Opportunity.UW_Approved_By__c` and `UW_Approval_Date__c` populate from the approval history.
3. **Pass/Fail:** ______

---

## Remaining 20 Flows — concrete steps

### `Broker_Portal_New_Lead_Notify`
Object: `Lead` | After Save, Create | Condition: `LeadSource = 'Broker Portal'`.
1. Create a Lead with `LeadSource = 'Broker Portal'` (e.g. via the public broker portal LWC, or directly).
   Expected: Acquisitions notified of the new broker-sourced Lead.
Pass/Fail: ______

### `Con_Review_Opinion_Notify`
Object: `Construction_Feasibility_Review__c` | After Save, Create/Update | Condition: `Recommendation__c` is not null.
1. Create or update a Construction Feasibility Review record, setting `Recommendation__c` to any value.
   Expected: "Opinion Received" notification fires.
Pass/Fail: ______

### `Contract_Review_Stage_Sync`
Object: `Contract_Review__c` | Before Save, Create/Update | Condition: `Negotiation_Status__c` is not null.
1. Create/update a Contract Review record with `Negotiation_Status__c` set.
   Expected: Stage Counter field is set/updated on the same record (before-save, no new DML).
Pass/Fail: ______

### `Counter_Offer_Notify`
Object: `Counter_Offer__c` | After Save, Create | No filter (fires on every create).
1. Create a Counter Offer record (e.g. via the LOI Counter Offer LWC).
   Expected: Notification fires immediately on creation.
Pass/Fail: ______

### `Dev_Review_Opinion_Notify`
Object: `Development_Feasibility_Review__c` | After Save, Create/Update | Condition: `Recommendation__c` is not null.
1. Create or update a Development Feasibility Review record, setting `Recommendation__c`.
   Expected: "Opinion Received" notification fires.
Pass/Fail: ______

### `LOI_Signed_Notify`
Object: `LOI__c` | After Save, Create/Update | Condition: `LOI_Signed__c = true`.
1. Update an LOI record, setting `LOI_Signed__c = true`.
   Expected: IR notified.
Pass/Fail: ______

### `Lead_Approved_Notify`
Object: `Lead` | After Save, Update | Condition: `IsConverted = true`.
1. Convert a Lead (via standard convert action, e.g. through `LeadConvertService`).
   Expected: Acquisitions Team notified of the converted Lead.
Pass/Fail: ______

### `Lead_Intake_Stamp`
Object: `Lead` | Before Save, Create/Update | No filter.
1. Create a new Lead.
   Expected: "DPEG First" stamp field populates on the same record at save time.
Pass/Fail: ______

### `Lease_Inquiry_Create_Lease`
Object: `Lease__c` | After Save, Create/Update | Condition: related `Lease_Inquiry__c.Stage__c = 'Lease Drafting'` (via `Lease_Inquiry__c` lookup = `$Record.Id` cross-reference — read the filter carefully, it correlates the Lease back to its parent Inquiry's stage).
1. Advance a Lease Inquiry to Stage = "Lease Drafting" such that a related Lease record is created/updated.
   Expected: Lease creation/linkage behaves as before (no Lease created twice, correct Inquiry stage gating).
Pass/Fail: ______

### `Lease_Inquiry_Open_Log`
Object: `Lease_Activity__c` | After Save, Create | No filter.
1. Log a new Lease Activity against a Lease Inquiry (via `leaseNegotiationLog` LWC or directly).
   Expected: Open Log entry behavior fires on every new activity.
Pass/Fail: ______

### `Lease_Inquiry_Signed_Date`
Object: `Lease_Inquiry__c` | Before Save, Create/Update | Condition: `Status__c = 'Closed Won'`.
1. Update a Lease Inquiry's `Status__c` to `Closed Won`.
   Expected: Signed Date field stamps on the same record.
Pass/Fail: ______

### `Lease_Inquiry_Stage_Timer`
Object: `Lease_Inquiry__c` | Before Save, Create/Update | No filter.
1. Change a Lease Inquiry's stage/ball-in-court field.
   Expected: Stage Start Date resets appropriately (feeds the 14-day non-responsiveness aging formula).
Pass/Fail: ______

### `Lease_Renewal_Status_Sync`
Object: `Lease_Renewal__c` | Before Save, Create/Update | No filter.
1. Update a Lease Renewal record into a closed/lost-eligible state per its own criteria.
   Expected: `Closed Lost` status sync applies correctly on the same record.
Pass/Fail: ______

### `Opportunity_Initiate_Underwriting`
Object: `Opportunity` | Before Save, Create/Update | Condition: `Initiate_Underwriting__c = true`.
1. On an Opportunity, check/set `Initiate_Underwriting__c = true` and save.
   Expected: Stage advances to Underwriting on the same record.
Pass/Fail: ______

### `Opportunity_LOI_Prep_Stamp`
Object: `Opportunity` | Before Save, Create/Update | No filter.
1. Save an Opportunity as it enters the "Initiate LOI" stage / LOI prep step.
   Expected: Prep Approval stamp field populates on the same record.
Pass/Fail: ______

### `PSA_Ready_Notify`
Object: `Contract_Review__c` | After Save, Create/Update | Condition: `Negotiation_Status__c = 'Ready for Execution'`.
1. Update a Contract Review's `Negotiation_Status__c` to `Ready for Execution`.
   Expected: "Notify Ready" notification fires.
Pass/Fail: ______

### `PSA_Version_Notify`
Object: `PSA_Version__c` | After Save, Create | No filter.
1. Create a new PSA Version record (via the PSA versions feature / transaction handoff).
   Expected: Acquisitions notified of the new PSA version.
Pass/Fail: ______

### `Transaction_Complete_Close`
Object: `Transaction__c` | After Save, Create/Update | Condition: `Status__c = 'Closed'` AND `Opportunity__c` is not null.
1. Update a Transaction (with a populated `Opportunity__c` lookup) to `Status__c = 'Closed'`.
   Expected: "Congratulate" action fires (closing notification/message).
Pass/Fail: ______

### `Underwriting_Opp_Sync`
Object: `Underwriting__c` | After Save, Create/Update | No filter (logic inside the flow determines "is this the primary underwriting?").
1. Create or update an Underwriting record marked as the deal's primary underwriting, changing a key number (e.g. purchase price, cap rate).
   Expected: The parent Opportunity's mirrored underwriting fields update to match. Confirm `Underwriting_Status__c` on the Opportunity is **not** touched by this flow (deliberately owned by the approval process only — per the flow's own description).
Pass/Fail: ______

### `Work_Order_Touch_Sync`
Object: `Work_Order__c` | Before Save, Create/Update | No filter.
1. Update a Work Order into a completed state per its own criteria (read-only Yardi-mirror object — use a test record, not live-looking data).
   Expected: "Stamp Completed" field sets on the same record.
Pass/Fail: ______

---

## After exercising all 23

1. Re-run the Flow baseline query (see `agent-output/P0-rollback-plan.md` §2) and confirm every flow shows **Active Version 2** (or higher, if any were touched more than once) with `Status = Active`, and no flow accidentally ended up on an inactive/draft version.
2. Log any failures with: flow name, record Id, expected vs. actual, exact error text (from debug logs / notification absence / field not stamped).
3. If any flow fails, use the rollback procedure in `agent-output/P0-rollback-plan.md` §4 to reactivate Version 1 for that flow specifically — a single flow's rollback does not require rolling back the other 22 or the Apex/trigger portion of the deploy.
