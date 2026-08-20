# Disposition Flow Redesign — On-Market / Off-Market Stage Overhaul

**Date:** 2026-08-19
**Author:** Documentation Agent
**Status:** Metadata and Apex for the full redesign (additive schema, approvals, quick actions,
flexipage, rebuilt paths, and the Phase 6 validation-rule rewrite) are present and internally
consistent in the repo as a single build. Two org-destructive operations are deliberately **prepared
but not authorised**: see [What Is Still Outstanding](#-what-is-still-outstanding). This document
describes the branch `feature/disposition-redesign` as it exists in the working tree, not a
deployment record — no deploy confirmation or live-org readback is claimed here (see
[Test/Verification Evidence](#-testverification-evidence)).

---

## 📋 Overview

### Original Request

> The client has drastically redefined the disposition flow. Today the module runs a 10-value stage
> picklist across On_Market/Off_Market record types, an Initiate button that creates a Disposition
> directly (no popup, no approval), three principal approvals with **no final actions** (stage moves
> are manual via Path), and stage-routed LWCs. The new flow adds stages, moves NDA into On-Market,
> introduces four approval-gated transitions with **auto-advance on approval**, an initiate modal with
> record-type choice + auto-submit, per-stage quick actions (Opportunity pattern), and several LWC
> changes.

Full item-by-item scope lives in `agent-output/design-requirements.md`, transcribed from the
user-approved plan at `C:\Users\usman.khan\.claude\plans\now-we-have-a-linear-phoenix.md`. This
document does not repeat that transcription; it records what the repo actually contains today and
calls out every place reality diverged from the plan.

### Business Objective

DPEG's disposition (sell-side) process changed shape at the client's direction: NDA collection, which
used to be an off-market-only concern, now applies to both broker-listed (on-market) and direct
(off-market) sales; four new stages were added to reflect real steps the business already performs
(competitive broker selection, materials release, a distinct offer-selection step, a real "sale
closed" terminal stage); and every stage transition that used to depend on a human remembering to
click through the Path now either happens automatically when the right approval clears, or is gated
behind an explicit, permissioned quick action — closing the gap where a disposition could sit
"approved" on paper while nobody had actually advanced the record.

### Summary

`Disposition__c.Disposition_Stage__c` grew from a flat 10-value picklist to an 11-stage on-market
sequence and a 9-stage off-market sequence sharing nine of eleven values, with the picklist's master
order **interleaved** (not appended) so both Paths still render correctly. Five approval processes
across three objects (Disposition, BOV_Submission, Disposition_Offer) now own seven of the eleven
stage transitions and auto-advance the stage on approval through a semaphore-plus-Queueable
mechanism (design D-1) rather than a direct field update or an approval-triggered flow, both of which
this org has independently proven unsafe. Nine new quick actions plus a Dynamic Actions block replace
the record page's action bar entirely, gated by the pre-existing `Disposition_Deal_Actions` custom
permission. Six LWC bundles were added and five modified. A code-review pass (findings referred to
below as C-1/C-2/C-3) found and fixed a live production defect (two disagreeing private copies of a
record-type helper) and added an Approval History related list the page had never carried, then
approved the result with warnings.

---

## 🏗️ Key Design Decisions and Rationale

### D-1 — Approval auto-advance is a semaphore, never a direct write

Three mechanisms were considered for "approving X moves the stage to Y," and two are structurally
forbidden in this org, not merely disfavored:

- **A direct `finalApprovalActions` field update on `Disposition_Stage__c`** — rejected. A workflow
  field update does **not** evaluate validation rules the way a user edit does, so it would silently
  bypass `All_NDAs_Signed_Before_Progression` and the wire-completion backstop for exactly the actor
  (an approving principal) most able to do damage with the bypass.
- **An approval-triggered Flow** — rejected as a measured org incident, not a theory (memory:
  `flow-runinmode-runs-as-approver`). A record-triggered Flow with no `<runInMode>` executes as the
  approver, a read-only persona on `Disposition__c`; its DML throws a `TypeException` that escapes a
  `DmlException`-only fault path and **rolls back the approval itself** — the approver clicks Approve
  and is told the approval failed.
- **A semaphore + trigger + Queueable** (chosen). The approval's `finalApprovalActions` writes only
  `Disposition__c.Approval_Advance_Pending__c` (a boolean with **no FLS for anyone**). That write
  re-fires `DispositionTrigger`; `DispositionTriggerHandler.afterUpdate` detects the transition
  false→true (not merely "is true," so a row that already had the flag set on a later, unrelated save
  does not re-enqueue) and calls `DispositionApprovalAdvanceService.enqueuePendingAdvances`, guarded
  against the queueable-job limit. The enqueued `DispositionApprovalAdvanceQueueable` calls
  `DispositionApprovalAdvanceService.advance`, which re-reads the row (never trusts the trigger
  snapshot — the stage may have moved between submission and the job running) and writes the target
  stage with ordinary `Database.update(updates, false, AccessLevel.SYSTEM_MODE)` in the **same
  statement** that clears the flag. `SYSTEM_MODE` lifts CRUD/FLS but never a validation rule, so the
  gates still apply; the approver's own CRUD is irrelevant because the write runs as the automation;
  and the async hop matters specifically because the triggering transaction **is** the one that
  releases the `recordEditability = AdminOnly` lock, so the job always finds an unlocked record.

Child-object approvals (`BOV_Submission__c.Broker_Finalize_Approval`,
`Disposition_Offer__c.Offer_Selection_Approval`) do **not** use the semaphore. Their `AdminOnly` lock
falls on the child, not the parent, so `BovSubmissionTriggerHandler` / `DispositionOfferTriggerHandler`
update the parent Disposition **synchronously**, `allOrNone = false`, `SYSTEM_MODE` — the same shape
`ContractExecutionService` already uses for PSA→Closing.

**A refusal leaves the semaphore `true` by design, not by omission.** The stage write and the flag
clear are one `Database.update` call, so any refusal (a validation rule, an invisible row, an
unmapped stage pair, an exhausted queueable budget) leaves both the stage and the flag exactly where
they were — visible to an admin via SOQL, recoverable, and honest, versus a silently-cleared flag that
would make an approved-but-unadvanced disposition look completely normal.

### C-2 — one canonical `recordTypeNameOf`, not two that quietly disagreed

Code review found that `DispositionApprovalService` and `DispositionApprovalAdvanceService` each held
a **private** copy of "what record type is this Disposition," and the two copies disagreed on the
Master/unset case: one returned `null`, the other returned `On_Market`. The disagreement was live and
reachable — a Master-type row's `null` answer made `submitForApproval`'s on-market guard read false,
so the click fell into the off-market branch and submitted `Broker_Selection_Approval`; that approval
then advanced via a key (`On_Market|Broker Selection`) the advance map deliberately does not carry, so
the semaphore stuck `true` with nothing on the page explaining why. The fix, `DispositionDomain.cls`
(new), is a single Domain-layer class holding `RT_ON_MARKET`/`RT_OFF_MARKET` and one
`recordTypeNameOf(Disposition__c)` — a describe, not a query, so it costs zero SOQL even inside a
trigger chunk — that every other class now aliases rather than re-declaring. The chosen default for a
Master/unset row is `On_Market`, matching `RecordStageAdvanceService`'s own `defaultTypeKey`.

### Why `initiateAndSubmit` / `findOrCreate` do **not** call the disposition action gate

Code review raised this as a critical finding and it was investigated and **kept**, not fixed, per
`DispositionService.cls`'s class header: the create path is reachable from the Sell Meter dashboard by
any acquisitions/transaction/PM analyst who can see a Property Asset, not only disposition drivers,
and gating creation itself would silently remove that entry point rather than close a real hole. The
actual authorization control on this path is **the approval**: a disposition is created at
`Disposition Readiness` — before anything is released or committed — and immediately submitted into
`Sale_Decision_Approval`; only the two named principals can let it move past that point. Every stage
after Readiness is gated by `Disposition_Deal_Actions`, enforced by
`DispositionActionPermissionService.assertDispositionActionAccess()` at the top of every other new
write (`DispositionApprovalService.submitForApproval` / `.selectOffer`,
`BovSubmissionService.replaceSelectedBroker`).

### Picklist master order was interleaved, not appended

`Disposition_Stage__c`'s master value list controls the order **both** record types' Paths render in
(a record type can only include/exclude a value, never reorder it). Appending the four new values to
the end would have rendered the on-market Path as `... Closing, Completed, Broker Selection, Release
Materials, Offer Selection, Sale Closes` — the finish line stranded mid-path, four steps trailing
behind it — and this would have deployed green with no Apex or Jest test able to see it. The chosen
order instead interleaves the new values into their correct final position (NDA had to move ahead of
Active Listing; Release Materials had to land between them), verified against both record types'
filtered walks in the field file's own comment. The three doomed values are parked at positions 12–14,
past the real terminal stage, rather than left in their old slots.

### Wire-flag entry criterion supersedes the documented Q4 decision

`Wire_Complete_Before_Completed`'s (now `Wire_Complete_Before_Sale_Closes`) own comment recorded design
decision Q4: do **not** put the wire flag in `Closing_Approval`'s entry criteria, because an unmet
entry criterion surfaces as the platform's opaque "no applicable approval process was found." This
redesign does exactly that anyway, and `Closing_Approval`'s XML comment carries the superseding
argument in full: without the criterion, approving Closing with the wire unverified fires the D-1
semaphore, the Queueable tries to write `Sale Closes`, and the validation rule (which still applies
under `SYSTEM_MODE`) refuses it — leaving the deal **approved, unadvanced, and the semaphore stuck
true**, a deadlock that did not exist under Q4 because a human previously just waited before advancing
manually. The mitigation that makes the trade pay is
`DispositionApprovalService.submitForApproval`'s pre-check: the Closing branch tests
`Wire_Verification_Completed__c` itself and raises an authored message before `Approval.process` is
ever called, so the user never reaches the platform's unhelpful error. Both gates are kept
deliberately — the validation rule still blocks a hand-edit or the Queueable's own write; the approval
entry criterion only decides who may *enter* the approval.

### Naming items the plan left open, and how they were resolved

The design-requirements doc flagged three names as shorthand, not invented. The built code resolved
them as follows (a deviation worth recording because the plan's spelling does not match the shipped
metadata):

| Plan's shorthand | What actually shipped |
|---|---|
| `Set_BOV_Approval_Approved` / `Set_BOV_Approval_Rejected` | `Set_Broker_Approval_Approved` / `Set_Broker_Approval_Rejected` (matches the approval process's own name, `Broker_Finalize_Approval`) |
| `Set_Offer_Approval_Approved` / `Set_Offer_Approval_Rejected` | Shipped exactly as transcribed |
| Suggested `BovSubmissionService` for the class behind `BovController.replaceSelectedBroker` | Shipped exactly as suggested — `BovSubmissionService.cls` |

---

## 🧱 Components

### Custom Fields (7 new)

| Object | Field API Name | Type | Notes |
|---|---|---|---|
| `Disposition__c` | `Approval_Advance_Pending__c` | Checkbox | The D-1 semaphore. **No FLS for anyone in either permission set**, deliberately — a machine interlock granting user visibility would invite a hand edit that fires a spurious advance. |
| `Disposition__c` | `Is_On_Market__c` | Formula (Checkbox), `RecordType.DeveloperName = 'On_Market'` | Exists solely so FlexiPage visibility rules can test record type (never `{!$User...}`; spanning `{!Record.RecordType...}` is unverified on this org). Read FLS granted in both permission sets; gates 4 of the 12 Dynamic Actions on the record page. |
| `BOV_Submission__c` | `Approval_Status__c` | Picklist (Approved/Rejected, blank = unsubmitted) | A **second, distinct** field from the pre-existing `Submission_Status__c` — do not conflate them. Written only by the `Broker_Finalize_Approval` workflow field updates. |
| `Disposition_Offer__c` | `Is_Selected__c` | Checkbox | Entry criterion for `Offer_Selection_Approval`. Written exclusively (at most one true per disposition) by `DispositionApprovalService.selectOffer`, in `SYSTEM_MODE` because the field ships with no FLS and both permission sets grant read-only. |
| `Disposition_Offer__c` | `Approval_Status__c` | Picklist (Approved/Rejected, blank = unsubmitted) | A **second, distinct** field from the pre-existing `Offer_Status__c`. Written only by the `Offer_Selection_Approval` workflow field updates. |

### Custom Object Picklist Surgery

`Disposition__c.Disposition_Stage__c` (`force-app/main/default/objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml`):

| Change | Values |
|---|---|
| Added | `Broker Selection`, `Release Materials`, `Offer Selection`, `Sale Closes` |
| Retired, **still present in the field and both record types** (a deploy cannot delete a picklist value) | `Call for Offers`, `Disposition Offer`, `Completed` |

**Final sequences** (both record types already carry these value sets, plus the three retired values
appended after `Sale Closes` for the transition window):

- **On_Market (11):** Disposition Readiness → BOV Outreach → Broker Selection → NDA → Release
  Materials → Active Listing → Offer Selection → LOI → PSA → Closing → Sale Closes.
- **Off_Market (9):** Disposition Readiness → Broker Selection → NDA → Release Materials → Offer
  Selection → LOI → PSA → Closing → Sale Closes.

Nine of eleven values are now shared between the two record types — only `BOV Outreach` and `Active
Listing` remain on-market-only. **The doctrine that "NDA and Disposition Offer are off-market stage
values only" and "the two record types' stage value sets are disjoint," previously recorded in both
record-type files, `All_NDAs_Signed_Before_Progression`, and `lwc/dispositionSidebar.js`, is dead and
was rewritten (quote-and-retract, not deleted) everywhere it was asserted.**

### Workflow Field Updates (3 new files)

| File | Field Updates |
|---|---|
| `workflows/Disposition__c.workflow-meta.xml` | `Set_Approval_Advance_Pending` → `Approval_Advance_Pending__c = true` |
| `workflows/BOV_Submission__c.workflow-meta.xml` | `Set_Broker_Approval_Approved` / `Set_Broker_Approval_Rejected` → `Approval_Status__c` |
| `workflows/Disposition_Offer__c.workflow-meta.xml` | `Set_Offer_Approval_Approved` / `Set_Offer_Approval_Rejected` → `Approval_Status__c` |

### Approval Processes (5)

| Process | Object | Change | Entry Criteria |
|---|---|---|---|
| `Sale_Decision_Approval` | `Disposition__c` | Modified | `Disposition_Stage__c = 'Disposition Readiness'` (unchanged); gained `finalApprovalActions → Set_Approval_Advance_Pending` |
| `Broker_Finalize_Approval` | `BOV_Submission__c` | **New** | `Submission_Status__c = 'Selected'`. Approves the **submission**, not the Disposition — the approval page shows the winning broker's own economics, and the `AdminOnly` lock lands on the submission, leaving the parent writable for a synchronous trigger update. |
| `Broker_Selection_Approval` | `Disposition__c` | Adapted | `Disposition_Stage__c = 'Broker Selection'` **AND** record type Off Market (previously scoped differently); gained the semaphore final action; `approvalPageFields` swapped to surface `Selected_Broker__c` |
| `Offer_Selection_Approval` | `Disposition_Offer__c` | **New** | `Is_Selected__c = true`. Approves the **offer**, not the Disposition, for the same reason as `Broker_Finalize_Approval`. |
| `Closing_Approval` | `Disposition__c` | Modified | Gained `Wire_Verification_Completed__c = true` as an **added** entry criterion (see Key Design Decisions) plus the semaphore final action |

All five: `recordEditability = AdminOnly`, `allowRecall = true`, two named principals
(`nikhil.dhanani@usmandpeg.uat`, `aftab.ali.dpeg.usman@avanzasolutions.com`),
`whenMultipleApprovers = FirstResponse`.

### Quick Actions (9 new, `Disposition__c.*`)

| Action | LWC | Visible when (Dynamic Actions rule) |
|---|---|---|
| `Submit_Sale_Decision` | `dispositionSubmitForApproval` | `Disposition_Stage__c = 'Disposition Readiness'` |
| `Submit_Selected_Broker` | `dispositionSubmitForApproval` | `Disposition_Stage__c = 'BOV Outreach'` |
| `Submit_Broker_Selection` | `dispositionSubmitForApproval` | `Disposition_Stage__c = 'Broker Selection' AND Is_On_Market__c = false` |
| `Submit_Closing_Approval` | `dispositionSubmitForApproval` | `Disposition_Stage__c = 'Closing' AND Wire_Verification_Completed__c = true` |
| `Advance_to_NDA` | `advanceRecordStage` (existing) | `Disposition_Stage__c = 'Broker Selection' AND Is_On_Market__c = true` |
| `Advance_to_Release_Materials` | `advanceRecordStage` | `Disposition_Stage__c = 'NDA'` |
| `Advance_to_Active_Listing` | `advanceRecordStage` | `Disposition_Stage__c = 'Release Materials' AND Is_On_Market__c = true` |
| `Advance_to_PSA` | `advanceRecordStage` | `Disposition_Stage__c = 'LOI'` |
| `Select_Offer` | `dispositionOfferSelect` (ScreenAction) | `(Active Listing OR Release Materials) AND (Active Listing OR NOT on-market) AND permission` — a De Morgan expansion of "Active Listing on-market OR Release Materials off-market," chosen because a nested disjunction is unproven on this renderer (precedent: `LOI__c.Is_Advance_Allowed__c`) |

Every rule is AND-ed with `{!$Permission.CustomPermission.Disposition_Deal_Actions} EQUAL true` in the
mandatory three-segment form — `{!$Permission.<Name>}` and `{!$CustomPermission.<Name>}` are both
rejected by the Metadata API (measured 2026-08-12).

### FlexiPage — `Disposition_Record_Page.flexipage-meta.xml`

`enableActionsConfiguration` flipped false→true with an `actionNames` valueList. **This is the whole
action bar, not an addition to it** — turning on Dynamic Actions discards the page's inherited
`platformActionList` entirely (memory: `dynamic-actions-discards-inherited-actions`), which is why
`Edit`, `Clone`, and `Delete` are carried forward explicitly in bare form alongside the nine new
actions, for **twelve total entries**. The platform's generic `Submit` button was deliberately
dropped — restoring it would route around `DispositionApprovalService`'s authored pre-checks (notably
the wire pre-check). `LogACall`/`NewEvent`/`NewTask`/`SendEmail` remain reachable from the sidebar
Activity panel, fed by a different action-list context. The two pre-existing visibility rules
(`c_dispositionMain`, `flexipage_fieldSection`) were **repointed, not added**: `Completed` → `Sale
Closes`, no other criterion changed.

**Approval History was added in the same change** (code review finding C-3) —
`force:relatedListContainer` (identifier `relatedLists`), **not** `force:relatedListSingleContainer`.
The comment records a measured API distinction: `GET /ui-api/related-list-info/Disposition__c/NDAs__r`
returns 200, but the same call for `ProcessSteps`/`RelatedProcessHistoryList` returns
`INVALID_TYPE, "The related lists UI API does not currently support this entity"` — so the Single
container would have deployed green and rendered nothing for approval history. The component renders
whatever related lists the page layout carries, so it required a **second file edit**:
`layouts/Disposition__c-Disposition Layout.layout-meta.xml` gained a `RelatedProcessHistoryList`
entry. Without both halves the fix is incomplete but not visibly broken. The gap being closed: with
five approval processes now owning seven of eleven stage transitions, and all five locking the record
(`AdminOnly`) with `allowRecall = true`, a submitted record had no UI route to Recall — a driver whose
approver went on leave saw a Path, fields they could no longer edit, and no way to see or cancel the
pending approval.

### Apex — Development Components

| Class | Layer | Responsibility |
|---|---|---|
| `DispositionDomain` (new) | Domain | Single canonical `recordTypeNameOf` + `RT_ON_MARKET`/`RT_OFF_MARKET` constants (see C-2 above). Zero SOQL — a describe. |
| `DispositionService` (modified) | Service | Added `initiateAndSubmit(assetId, recordTypeDeveloperName)` — allow-lists the record type, creates at Disposition Readiness, submits `Sale_Decision_Approval`, returns a 3-field `InitiateOutcome` (`dispositionId`, `submitted`, `message`) so a submit failure after a successful insert is neither swallowed nor thrown away. `findOrCreate` is untouched. |
| `DispositionController` (modified) | Controller | Thin `@AuraEnabled` wrapper for `initiateAndSubmit`. |
| `DispositionApprovalService` (new) | Service | `submitForApproval(dispositionId)` — derives the target approval from stage + record type (never accepts one as a parameter, so a hand-crafted call cannot submit the wrong approval); pre-checks the two user-actionable entry criteria (`Selected_Broker__c` non-blank, wire complete) with authored messages. `selectOffer(dispositionId, offerId)` — the D-3 two-step: exclusive `Is_Selected__c` flip, stage advance to `Offer Selection`, offer submission, all under one savepoint. |
| `DispositionApprovalController` (new) | Controller | Thin wrapper for the above. |
| `DispositionApprovalAdvanceService` (new) | Service | The D-1 stage-advance map (`ADVANCE_TARGET`, keyed `<recordType>|<currentStage>`) and `advance()`, called only from the Queueable. |
| `DispositionApprovalAdvanceQueueable` (new) | Queueable | Five-line async shell calling `advance()`. |
| `DispositionTriggerHandler` (modified) | Trigger Handler | `afterUpdate` gained the false→true semaphore-detection hook, queueable-limit guarded. |
| `BovSubmissionTrigger` / `BovSubmissionTriggerHandler` (new) | Trigger / Handler | On `Approval_Status__c → Approved` where `Submission_Status__c = 'Selected'`: advances the parent to `Broker Selection` **only if currently at `BOV Outreach`** (idempotency guard), stamps `Selected_Broker__c`. Synchronous, `allOrNone=false`, `SYSTEM_MODE`. |
| `DispositionOfferTrigger` / `DispositionOfferTriggerHandler` (new) | Trigger / Handler | On `Approval_Status__c → Approved` where `Is_Selected__c = true`: sets own `Offer_Status__c = 'Accepted'`, advances parent to `LOI` **only if currently at `Offer Selection`**, stamps `Accepted_Offer_Price__c`. Same synchronous shape. |
| `BovController` (modified) + `BovSubmissionService` (new) | Controller / Service | `replaceSelectedBroker` — demotes the old Selected submission to Backup and clears its `Approval_Status__c`; promotes the new one; updates `Selected_Broker__c`. A replace after the stage already advanced does not re-advance (the trigger's current-stage guard covers it). |
| `RecordStageAdvanceService` (modified) | Service | Registered `Disposition__c` in `CONFIG_BY_TYPE`, `defaultTypeKey = 'On_Market'`, gate `DISPOSITION_DRIVER`. Manual hops only: On_Market `{Broker Selection→NDA, NDA→Release Materials, Release Materials→Active Listing, LOI→PSA}`; Off_Market `{NDA→Release Materials, LOI→PSA}` — no approval- or machine-owned hop is reachable through the Advance button. `NO_NEXT_STEP_HINTS` name the real owner of every blocked hop. |
| `DispositionSelector` (modified) | Selector | `selectStageRequiredById` (new, `WITH SYSTEM_MODE`, justified in the class header per the automation-path exception) for `RecordStageAdvanceService`. |
| `BovSubmissionSelector` (modified) | Selector | New method returning the Selected submission for a disposition. |
| `DispositionStageEntryService` | Service | **Comment rewrite only** — no behavior change. |

### LWC (6 new, 5 modified)

| Component | Change | Notes |
|---|---|---|
| `sellMeterInitiateModal` | New | `LightningModal`: read-only property summary (pre-formatted strings supplied by the caller — no formatting or wire in this component) + mandatory On Market/Off Market radio, no default. Calls `DispositionController.initiateAndSubmit`. |
| `sellMeterList` | Modified | Row action opens the modal instead of creating directly. RED band stays refused (button already disabled); YELLOW keeps its existing `LightningConfirm` before opening the modal. |
| `dispositionSubmitForApproval` | New | Headless `RecordAction` backing all four `Submit_*` quick actions; permission pre-flight against `DispositionActionPermissionService`, not the acquisitions `dealActionGuard`. |
| `dispositionOfferSelect` | New | ScreenAction, radio list of the disposition's offers → `DispositionApprovalService.selectOffer`. |
| `bovComparisonMatrix` | Modified | Added "Add Broker Response" and "Replace Broker" (visible only when exactly one submission is Selected) buttons. |
| `bovReplaceBrokerModal` | New | Calls `BovController.replaceSelectedBroker`, refreshes, warns a fresh approval is required. |
| `dispositionCallForOffers` | New (design D-5) | Card in `dispositionMain`'s Active Listing block. Deliberately separate from the Opportunity-scoped `callForOffersList`/`callForOffersPanel`, which were not touched. |
| `dispositionMain` | Modified | `isClosing` now covers `'Sale Closes'` and drops `'Completed'`; mounts `dispositionCallForOffers`. |
| `dispositionSidebar` | Modified | Offer-panel stage set is now `Active Listing \| Release Materials \| Offer Selection \| LOI`; the "disjoint value sets" comment was rewritten (see Key Design Decisions). |

---

## 🔄 Data Flow — the Auto-Advance Path

```
Approve Sale_Decision_Approval (principal)
        │  finalApprovalActions
        ▼
Set_Approval_Advance_Pending  (workflow field update)
        │  Disposition__c.Approval_Advance_Pending__c: false -> true
        ▼
DispositionTrigger  ──▶  DispositionTriggerHandler.afterUpdate
        │  detects the FALSE->TRUE transition (not merely "is true")
        ▼
DispositionApprovalAdvanceService.enqueuePendingAdvances
        │  guarded: Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()
        ▼
System.enqueueJob(DispositionApprovalAdvanceQueueable)
        │  (async — runs after the approving transaction commits,
        │   which is also when the AdminOnly lock releases)
        ▼
DispositionApprovalAdvanceQueueable.execute
        │  calls DispositionApprovalAdvanceService.advance(ids)
        ▼
Re-read current stage + record type via DispositionSelector.selectStageAndTypeByIds
        │  look up ADVANCE_TARGET["<RT>|<current stage>"]
        │
        ├─ mapped   ──▶ Database.update({ Disposition_Stage__c = target,
        │                                  Approval_Advance_Pending__c = false },
        │                                allOrNone=false, AccessLevel.SYSTEM_MODE)
        │                    │
        │                    ├─ VALIDATION RULES STILL EVALUATE (SYSTEM_MODE lifts CRUD/FLS only)
        │                    ├─ success → stage advanced, semaphore cleared, in ONE statement
        │                    └─ refused (e.g. All_NDAs_Signed_Before_Progression) →
        │                              stage unchanged, semaphore LEFT TRUE (visible, recoverable)
        │
        └─ unmapped ──▶ row left untouched, semaphore left true (e.g. an approval
                          firing at a stage the map does not cover)
```

Child-object approvals (`Broker_Finalize_Approval` on `BOV_Submission__c`,
`Offer_Selection_Approval` on `Disposition_Offer__c`) skip this whole path — their trigger handlers
write the parent Disposition **synchronously**, in the same transaction as the approval, because their
`AdminOnly` lock falls on the child record, not the parent.

---

## 📁 File Locations

| Component Type | Path |
|---|---|
| Disposition_Stage__c picklist | `force-app/main/default/objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml` |
| Record types | `force-app/main/default/objects/Disposition__c/recordTypes/{On_Market,Off_Market}.recordType-meta.xml` |
| New Disposition fields | `force-app/main/default/objects/Disposition__c/fields/{Approval_Advance_Pending__c,Is_On_Market__c}.field-meta.xml` |
| New BOV/Offer fields | `force-app/main/default/objects/BOV_Submission__c/fields/Approval_Status__c.field-meta.xml`; `force-app/main/default/objects/Disposition_Offer__c/fields/{Is_Selected__c,Approval_Status__c}.field-meta.xml` |
| Validation rules | `force-app/main/default/objects/Disposition__c/validationRules/{All_NDAs_Signed_Before_Progression,Wire_Complete_Before_Sale_Closes}.validationRule-meta.xml` |
| Workflows | `force-app/main/default/workflows/{Disposition__c,BOV_Submission__c,Disposition_Offer__c}.workflow-meta.xml` |
| Approval processes | `force-app/main/default/approvalProcesses/{Disposition__c.Sale_Decision_Approval,Disposition__c.Broker_Selection_Approval,Disposition__c.Closing_Approval,BOV_Submission__c.Broker_Finalize_Approval,Disposition_Offer__c.Offer_Selection_Approval}.approvalProcess-meta.xml` |
| Quick actions | `force-app/main/default/quickActions/Disposition__c.{Submit_Sale_Decision,Submit_Selected_Broker,Submit_Broker_Selection,Submit_Closing_Approval,Advance_to_NDA,Advance_to_Release_Materials,Advance_to_Active_Listing,Advance_to_PSA,Select_Offer}.quickAction-meta.xml` |
| FlexiPage | `force-app/main/default/flexipages/Disposition_Record_Page.flexipage-meta.xml` |
| Layout (Approval History) | `force-app/main/default/layouts/Disposition__c-Disposition Layout.layout-meta.xml` |
| Path assistants | `force-app/main/default/pathAssistants/Disposition_Path_{On_Market,Off_Market}.pathAssistant-meta.xml` |
| Permission sets | `force-app/main/default/permissionsets/DPEG_Disposition_{View,Edit}.permissionset-meta.xml` |
| Apex — approvals/advance | `force-app/main/default/classes/{DispositionDomain,DispositionApprovalService,DispositionApprovalController,DispositionApprovalAdvanceService,DispositionApprovalAdvanceQueueable}.cls` |
| Apex — triggers/handlers | `force-app/main/default/triggers/{BovSubmissionTrigger,DispositionOfferTrigger}.trigger`; `force-app/main/default/classes/{BovSubmissionTriggerHandler,DispositionOfferTriggerHandler}.cls` |
| Apex — broker replace | `force-app/main/default/classes/{BovController,BovSubmissionService}.cls` |
| Apex — stage advance / selectors | `force-app/main/default/classes/{RecordStageAdvanceService,DispositionSelector,BovSubmissionSelector}.cls` |
| Apex — Sell Meter initiate | `force-app/main/default/classes/{DispositionService,DispositionController}.cls` |
| LWC | `force-app/main/default/lwc/{sellMeterInitiateModal,dispositionSubmitForApproval,dispositionOfferSelect,bovReplaceBrokerModal,dispositionCallForOffers,sellMeterList,bovComparisonMatrix,dispositionMain,dispositionSidebar}/` |
| Prepared but unauthorized destructive package | `manifest/disposition-redesign-destructive/destructiveChangesPost.xml` |
| NDA baseline repair script (not yet executed) | `scripts/repair-onmarket-nda-baseline.apex` |

---

## 🚨 Operations — Read Before Deploying or Running Anything

### 1. `Disposition_Deal_Driver` is retired — the token now rides `DPEG_Disposition_Edit`

**Superseded 2026-08-19 by a separate, later, explicit user decision — not part of this redesign's own
scope, but corrected here because a stale statement about a live security gate is a defect.** The
paragraph this replaces reported that all nine new quick actions were gated on the
`Disposition_Deal_Actions` custom permission, granted only by a dedicated `Disposition_Deal_Driver`
permission set, and that the set had zero live assignees — "the single most important go-live step."
That finding is exactly what the later decision resolved, not something still open:

- The dedicated `Disposition_Deal_Driver` permission set (`Disposition_Deal_Driver.permissionset-meta.xml`,
  Tranche 3A) has been **deleted from the source tree** and is queued for org deletion via
  `manifest/retire-disposition-deal-driver/destructiveChangesPost.xml`.
- **The `Disposition_Deal_Actions` custom permission itself is NOT retired.** It still gates fifteen
  FlexiPage visibility rules (nine on `Disposition_Record_Page`, three on `LOI_Record_Page`, two on
  `NDA_Record_Page`, one on `Contract_Review_Record_Page`) and remains the sole server-side check in
  `DispositionActionPermissionService.assertDispositionActionAccess()`, asserted by
  `DispositionApprovalService`, `BovSubmissionService`, and `RecordStageAdvanceService`. Only the
  **grantor** changed.
- The token now rides `permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml` — its 2026-08-19
  header records the grant as additions-only (the `customPermissions` block), diffed against `HEAD`
  with zero deletions to any existing grant element.
- **Consequence, stated plainly:** every holder of `DPEG_Disposition_Edit` now has the nine disposition
  deal actions, where previously it required a separate, hand-assigned set. `DPEG_Disposition_Edit` is a
  member of `DPEG_Junior_Analyst_PSG` (`permissionsetgroups/DPEG_Junior_Analyst_PSG.permissionsetgroup-meta.xml`),
  so that group's entire population is now a disposition deal driver — the group's own 2026-08-19 header
  records this as a deliberate, accepted widening, not drift. `DPEG_Disposition_View` deliberately does
  **not** carry the token, so Principals still approve without driving.
- **Sequencing matters, and it is why the deletion is a post-destructive change rather than a plain
  delete:** `DPEG_Disposition_Edit`'s additive grant must land in the org **before**
  `Disposition_Deal_Driver` is removed. Reversing the order opens a window where no user in the org
  holds `Disposition_Deal_Actions`, and every disposition deal action vanishes silently — a FlexiPage
  visibility rule that evaluates false hides its button with no error logged anywhere.
- **What an admin provisioning a new disposition user must now check:** assigning `DPEG_Disposition_Edit`
  (directly, or via `DPEG_Junior_Analyst_PSG` membership) is now both necessary AND sufficient to grant
  the nine disposition quick actions — there is no second permission set to separately assign or verify.
  Conversely, a user who should approve without driving needs `DPEG_Disposition_View`, not
  `DPEG_Disposition_Edit`; assigning the Edit set to a Principal now hands them the drive capability as a
  side effect, not just edit access to the module's fields.
- **The acquisition side is unaffected and intentionally asymmetric.** `Acquisition_Deal_Driver` remains
  a separate, directly-assigned layer-5 authorization set carrying `Acquisition_Deal_Actions` — the two
  modules no longer follow the same pattern, and `DPEG_Junior_Analyst_PSG`'s own header explicitly warns
  against "fixing" that asymmetry in either direction without a further decision.

This documentation agent did not independently re-query live `PermissionSetAssignment` records for this
correction — as before, that org state is not retrievable metadata (memory: `rbac-build-2026-07-22`).
What is verified directly against the current file state: the `Disposition_Deal_Driver.permissionset-meta.xml`
file no longer exists in `force-app/main/default/permissionsets/`; the `customPermissions` grant is
present in `DPEG_Disposition_Edit.permissionset-meta.xml` and absent from `DPEG_Disposition_View.permissionset-meta.xml`;
and `DPEG_Disposition_Edit` is listed as a member of `DPEG_Junior_Analyst_PSG`. Acceptance-test as a real
disposition-driver persona, not as an admin — `DispositionActionPermissionService`'s own header notes an
admin smoke test proves nothing about this gate, since "Modify All Data" bypasses it for an unrelated
reason.

### 2. Five live records need the NDA-baseline repair before they can advance further

`All_NDAs_Signed_Before_Progression` dropped its `RecordType.DeveloperName = 'Off_Market'` term so the
gate now also applies on-market. An org sweep on 2026-08-19 found **five on-market rows created before
NDA existed as an on-market concept**, each with `NDA_Count__c = 0`: `DISP-0003`, `DISP-0007`,
`DISP-0008` (at `Active Listing`) and `DISP-0009`, `DISP-0010` (at `Closing`).

- The three at **Active Listing** fail loudly — a human presses Advance and gets the validation rule's
  message.
- **The two at Closing fail silently**, which is why this repair is urgent, not cosmetic: their next
  hop is not a button, it is the D-1 approval auto-advance. `Closing_Approval` reads Approved, the
  Queueable's `SYSTEM_MODE` write is refused by the validation rule (SYSTEM_MODE lifts CRUD/FLS, never
  a rule), `allOrNone=false` results are deliberately uninspected, and `Approval_Advance_Pending__c`
  — a field with no FLS for anyone and not on any layout — sticks `true` with nothing on the page to
  explain it.

Repair script: `scripts/repair-onmarket-nda-baseline.apex`. It is bound to the exact five named rows
(not a general stage sweep, because new rows reaching a gated stage after this deploy are live deals
genuinely missing an NDA, not pre-redesign casualties), backdates `Date_Signed__c` to `Listing_Date__c`
or `CreatedDate`, defaults `PREVIEW_ONLY = true` (no DML until explicitly flipped), and is idempotent
(skip test is the existence of a child NDA row, not the — deliberately stale-tolerant — counter field).
It depends on `DispositionDomain` being deployed first. **As of this writing it has not been run.**

### 3. Standing operational check for stuck semaphores

```sql
SELECT Id, Name, Disposition_Stage__c FROM Disposition__c WHERE Approval_Advance_Pending__c = true
```

Any non-empty result is a disposition that was approved but did not advance — check the validation
rules first (most likely `All_NDAs_Signed_Before_Progression` or `Wire_Complete_Before_Sale_Closes`),
resolve the blocker, and the flag will clear on the next save that re-triggers the semaphore path (or
can be cleared administratively once the underlying condition is fixed).

### 4. Mandatory post-deploy readbacks, and why

- **Read `Disposition_Stage__c`'s value order back in Setup.** A picklist reorder (as opposed to an
  add) is the one part of this change that can silently not take — if the org keeps the old ordering,
  both Paths render wrong while every Apex and Jest test still passes, because nothing in the test
  suite can observe Path rendering order.
- **Read the FlexiPage back and count exactly twelve action entries.** A FlexiPage deploy can roll
  back and still report success (memory: `flexipage-template-pattern`); the page's own in-root comment
  states this is "verification step 1 and it is not optional."

### 5. What is still outstanding

| Item | Status | Where |
|---|---|---|
| Destructive delete of `Wire_Complete_Before_Completed` (superseded by `Wire_Complete_Before_Sale_Closes`) | **Prepared, not authorized** | `manifest/disposition-redesign-destructive/destructiveChangesPost.xml` |
| Destructive delete of the legacy inactive `Disposition_Path` master path assistant | **Prepared, not authorized** | Same manifest folder |
| Manual Setup deletion of the three retired picklist values (`Call for Offers`, `Disposition Offer`, `Completed`) | **Not started** — a deploy cannot delete a picklist value; this is a hand step in Object Manager, and it cannot run until the destructive package above has run (a validation rule / path step referencing a value blocks that value's deletion) | Object Manager → Disposition Stage |
| Data migration script for the three retired values | **Not created** — Phase 0's org sweep on 2026-08-19 found **zero** live rows on any of the three retired values and zero pending approval instances, so the plan's own Phase 7 migration collapsed to a no-op guard and was not built. This is a deliberate scope reduction, not a gap. | — |
| NDA baseline repair | **Authored, not executed** | `scripts/repair-onmarket-nda-baseline.apex` |
| Re-retrieve confirmation after the manual picklist deletion | **N/A until the deletion runs** — `sf project retrieve` UNIONS local and remote picklist values, so a retrieve run before or during this cleanup will restore the deleted values locally and mimic a failed deploy (memory: `retrieve-merges-picklist-values`); verify via REST describe, not the retrieved file | — |

**Reality vs. the plan's deploy split.** The design-requirements doc described two separate metadata
deploys (Deploy 1 additive, an org migration, then Deploy 2 removal) gated on a data-migration step.
The repo today shows those collapsed into one internally-consistent build: the Phase 6 validation-rule
rewrite (rename-by-recreate of the wire rule) and the Phase 8 path-assistant rebuilds are already
present in `force-app`, not held back behind a second deploy — because Phase 0's sweep proved there
was no live data to protect, the plan's own stated reason for splitting the deploys did not apply.
Only the two genuinely destructive, irreversible-without-git-history operations (deleting the old VR
and the legacy path) remain gated behind explicit authorization, exactly as the prepared destructive
package's header states.

### 6. Known pre-existing issue, not caused by this work

`lwc/callForOffersList/__tests__/callForOffersList.test.js` asserts a `'Property'` column label
(`expect(labels).toEqual(['Property', 'Due Date', 'Urgency'])`), but
`lwc/callForOffersList/callForOffersList.js` renders `label: 'Deal'` — a leftover from an earlier
rename that predates this branch. `callForOffersList` is explicitly out of scope for this redesign
(design D-5 states the Opportunity-scoped `callForOffersList`/`callForOffersPanel` bundles were not to
be touched), so this failing test was not introduced or fixed here; it is flagged for whoever owns
that earlier rename.

---

## 🧪 Test/Verification Evidence

This documentation agent has no test-execution tooling (file-read/write/search only). The following
figures were reported by the build/code-review pass that produced this branch and are **not**
independently re-run here: **Apex tests 328/328 passing**, all touched classes ≥90% coverage
(`DispositionDomain` reported at 100%); **Jest 103 tests** across 9 Phase-5 suites; **SLDS linter 0
errors**; **two code-review rounds** (first pass: CHANGES REQUIRED with 3 criticals; second pass,
after fixes including C-2's `DispositionDomain` consolidation and C-3's Approval History addition:
APPROVED WITH WARNINGS). No standalone code-review report file exists under `agent-output/` for this
branch (unlike, for example, `docs/2026-07-24-broker-protection.md`'s companion review doc) — the
findings referenced throughout this document (C-1, C-2, C-3) are instead recorded directly in the
affected classes' and metadata files' own header comments, which this document quotes from directly
where cited.

What **is** independently verified by reading the files directly (not merely reported): every test
class named in the design doc's DEV-19 exists on disk (`DispositionServiceTest`,
`DispositionApprovalServiceTest`, `DispositionApprovalAdvanceServiceTest`,
`BovSubmissionTriggerHandlerTest`, `DispositionOfferTriggerHandlerTest`,
`DispositionApprovalControllerTest`, `DispositionDomainTest`, plus an end-to-end
`DispositionApprovalProcessesTest` not explicitly named in the plan); all five permission-set field
grants named in the field table above are present in both `DPEG_Disposition_View` and
`DPEG_Disposition_Edit`; `Approval_Advance_Pending__c` carries no `fieldPermissions` entry in either
set; the picklist master order, both record types, both rebuilt path assistants, all five approval
processes, all nine quick actions, and the FlexiPage's twelve-entry action list all match the design
exactly as described above.

### Bulk-Test-Rule Applicability

`DispositionApprovalAdvanceService.advance` is **trigger-driven** (fired from
`DispositionTriggerHandler.afterUpdate`), so the 251-record mandate in
`.claude/rules/bulk-test-rule.md` applies in full and carries no exemption — its class header states
this explicitly and calls for a bulk test asserting the per-chunk cost stays constant (one selector
query, one `Database.update`, at most one enqueue), not merely that 251 rows produced 251 advances.
`DispositionApprovalService.submitForApproval` / `.selectOffer` and
`DispositionActionPermissionService.hasDispositionActionAccess` are, by contrast, per-transaction
singleton `@AuraEnabled`/service methods invoked once per click with no record collection — these
carry the same documented exemption `RecordStageAdvanceService` and `OpportunityApprovalService`
already use, per each class's own header.

---

## 🔒 Security

- Every new Service/Selector/Controller class is `with sharing`.
- `DispositionSelector.selectStageRequiredById` uses `WITH SYSTEM_MODE`, justified in the class
  header per ARCHITECTURE.md §2's automation-path exception (an automation-driven read on behalf of a
  principal, not a read the running user asked for).
- All Queueable/trigger-driven writes that must survive the approver's own read-only CRUD use
  `AccessLevel.SYSTEM_MODE` explicitly (the async advance, the two child-approval synchronous parent
  updates) — SYSTEM_MODE lifts CRUD/FLS only, never a validation rule, which is the entire point of
  choosing it over a workflow field update (see D-1).
- The Dynamic Actions gate and the server-side `DispositionActionPermissionService.
  assertDispositionActionAccess()` are deliberately duplicated, not merged: the FlexiPage rule is a UX
  affordance only (any direct `@AuraEnabled` call bypasses it), so every server method that a quick
  action reaches re-asserts the same gate as its first statement.
- `Disposition_Deal_Actions` is a custom permission (no FLS involved). **Retracted 2026-08-19:** this
  section previously said it was "granted only by `Disposition_Deal_Driver`." That dedicated set was
  retired at explicit user request the same day; the grant now rides `DPEG_Disposition_Edit` instead —
  see Operations item 1 for the full change and its consequences. It remains deliberately a separate
  custom permission from `Acquisition_Deal_Actions`, so a sale still cannot be driven by an acquisitions
  deal driver and vice versa — only the mechanism granting it on the disposition side changed, not the
  cross-module separation itself.
- `Approval_Advance_Pending__c` deliberately carries **no FLS grant in either permission set** —
  see Operations item 1/2 for the consequence (a stuck semaphore is invisible on the record itself).

---

## 🏛️ ARCHITECTURE.md Update

Not touched by this change. The redesign adds no new object, no new external integration boundary,
and no new Apex layering pattern — every new class follows the existing Service/Selector/Domain/
Trigger-Handler split already documented in ARCHITECTURE.md §2, and `DispositionDomain` is a new
*instance* of the existing Domain layer pattern, not a new layer. `RecordStageAdvanceService`'s
manual-hop-map pattern, the semaphore-plus-Queueable approach, and the `WITH SYSTEM_MODE`
automation-path exception it invokes were all already established conventions this change reuses
rather than introduces.

---

## 📝 Notes & Considerations

### Known limitations / accepted residuals

- **Cross-cluster / queueable-budget residual (risk 8, accepted in the plan's own risk register).**
  If `DispositionApprovalAdvanceService.enqueuePendingAdvances` fires inside a transaction that has
  already exhausted its chained-async-job budget, the advance is skipped and the semaphore is left
  `true` — the same visible, recoverable state every other refusal on this path produces, and a
  deliberate trade (the approval is the irreplaceable half of the record; the stage write is
  derivable and can be retried).
- **A wire flag that flips false between submission and the Queueable running** (an admin correcting
  a verbal verification) leaves the semaphore stuck true — `Closing_Approval`'s XML comment records
  this as an accepted, fail-closed residual.
- **`Select_Offer`'s visibility-rule Boolean expression duplicates one criterion index** (stage =
  Active Listing appears as both criterion 1 and criterion 3) to keep the expression a conjunction of
  parenthesized ORs rather than a nested disjunction — the FlexiPage comment records that a nested
  disjunction's renderer behavior has never been confirmed safe on this org.

### Dependencies

- `DispositionActionPermissionService` and the `Disposition_Deal_Actions` custom permission both
  pre-date this redesign (Tranche 3A, 2026-08-09) and are reused, not created. **Retracted 2026-08-19:**
  this line previously also named `Disposition_Deal_Driver` as a pre-dating dependency; that dedicated
  permission set was retired the same day as a separate, later change (see Operations item 1) — the
  custom permission it used to grant did not go with it, it moved onto `DPEG_Disposition_Edit`.
- `ContractExecutionService` (PSA→Closing) is unchanged and continues to own that one transition.
- `DispositionStageEntryService`'s auto-create-on-entry behavior for the sell-side LOI and PSA
  (`Contract_Review__c`) is unchanged; only its header comments were rewritten to match the new flow.
- The NDA baseline repair script depends on `DispositionDomain` being deployed first (anonymous Apex
  compiles against the org's classes, not the repo).

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-08-19 | Documentation Agent | Initial creation — documents the Disposition flow redesign end to end as built on `feature/disposition-redesign`, including the deviations from the original plan (naming resolutions, deploy-split collapse, the C-1/C-2/C-3 code-review findings) and the operational steps still required before go-live. |
