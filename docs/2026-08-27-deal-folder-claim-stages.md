# Deal Folder Claim-Stage Widening (FSD Conformance Tranche 2, Item 1)

**Date:** 2026-08-27
**Author:** Documentation Agent
**Status:** Deployed to `usman-dpeg` (deploy id `0Afiw000000S6DlCAK`, 2026-08-27 08:15:34Z). Verified landed by `LastModifiedDate` readback — all 11 shipped classes moved off a 2026-08-21 baseline.

---

## 📋 Overview

### Original Request

> From `agent-output/design-requirements-fsd-tranche-2.md` — an FSD conformance audit against
> `docs/DPEG Acquisitions Module FSD Revised v2.0.docx` found **22 gaps**. Two were approved for
> build in this tranche: **Item 1**, widen the SharePoint deal-folder claim trigger from
> `Closed Won` alone to a set of four claim stages, closing FSD §3/§6.1/§15.3's requirement that a
> deal folder exist while the team is working the deal, not only after it closes; and **Item 2**, a
> `Call_For_Offers__c` object to replace four ad-hoc Opportunity fields as the system of record for
> offer deadlines. **Item 2 was cancelled by the user before build** (see *Deferred Work*, below) —
> only Item 1 shipped.

### Business Objective

Under the old design, `DealFolderService` created the SharePoint deal-folder tree (a parent folder
plus six lifecycle subfolders — NDA, LOI, Underwriting, PSA, Due Diligence, Closing) only when a
deal reached `Closed Won`. That defeated the FSD's own stated purpose: Junior works *out of* those
folders from NDA through Underwriting, LOI and PSA — i.e. for the entire life of the deal *before*
it closes — and under the old trigger they did not exist yet during any of that work. Widening the
trigger to fire on entry to any of four **claim stages** means a document home now exists from the
deal's first forward step (**Begin Review**, `New → Under Review`) rather than its last.

### Summary

`DealFolderService.CLOSED_WON` (a single String) became a four-member
`@TestVisible private static final Set<String> CLAIM_STAGES = {'Under Review', 'Underwriting',
'About to Close', 'Closed Won'}`, and the entry-point method `ensureOnClosedWon` was renamed
`ensureOnClaimStageEntry`. The `SharePoint_Folder_ID__c` idempotency guard on `Property__c` makes
every claim-stage entry after the first a zero-callout, zero-DML, zero-enqueue no-op, so an
ordinary deal still claims its folder exactly once — just three or four stages earlier than before.
Three of the four stages exist specifically to catch stage-advance routes that skip the ordinary
one. The change touched 11 Apex classes and no other metadata type: no new object, field,
permission set, or UI surface.

---

## 🏗️ Components Modified

No admin/declarative work — per design decision D2, Item 1 is **developer-only**; there is no admin
prompt, no new field, and no UI surface change.

### Apex Classes (Production)

| Class Name | Change |
|------------|--------|
| `DealFolderService` | Core change. `CLOSED_WON` (String) → `CLAIM_STAGES` (`Set<String>`, `@TestVisible`); `ensureOnClosedWon` → `ensureOnClaimStageEntry`; the prior-stage no-op test now uses set membership on both sides (`CLAIM_STAGES.contains(o.StageName) && (prior == null \|\| !CLAIM_STAGES.contains(prior.StageName))`); class header rewritten — the old "hangs off the Opportunity trigger because `NEXT_STAGE` maps two predecessors to `Closed Won`" argument is deleted (moot under the new key) and replaced with the four-stage rationale; residual R1's recovery query and residual R5 (no backfill) rewritten for the new population; the credential hint (`HINT_CREDENTIAL`) rewritten because the dominant claimer changed from the Transactions persona to a deal driver. |
| `OpportunityReviewTriggerHandler` | Call-site rename (`ensureOnClosedWon` → `ensureOnClaimStageEntry`) plus header rewrite: the paragraph arguing `PropertyAssetService` and `DealFolderService` "share a trigger point" no longer holds (one keys on one stage, the other on four) — replaced with an "overlap, not identity" framing that keeps the opposite-failure-contract warning alive specifically for the `Closed Won` case they still share. |
| `PropertySelector` | Class-header comment updated: `selectFolderStateByIds` is now described as re-keyed from `'Closed Won'` entry to claim-stage entry — "the QUERY is unchanged; only how often and how early it runs moved." No method signature change. |
| `StageAdvanceService` | Comment-only: the `NEXT_STAGE`-both-routes-reach-Closed-Won argument, previously cited to justify where `DealFolderService` hung off the trigger, is removed with an explicit note that `DealFolderService` no longer belongs in that argument and must not be re-added there. |
| `DealFolderQueueable` | Header rewrite: the "running principal" section no longer describes a whole-persona credential outage (the ordinary claimer now holds the SharePoint grant); narrowed to the two surviving routes — the LOI-rejection approval path and the `Closed Won` backstop. |
| `DealFolderFinalizer` | Comment updated to reference "claim-stage entry" instead of "close" as the point at which rows are stamped `Pending`. No logic change (Finalizer records; it does not key on stage). |
| `DealFolderSweepBatch` | Header rewrite: the sweep's *raison d'être* changes from "absorbs one whole-persona credential outage" to "absorbs four narrower causes" (deferred chains, dead job links, transient Graph failures, two narrow credential-refusal routes). Confirms the sweep is live-scheduled in `usman-dpeg` (`DPEG SharePoint Deal Folder Sweep`, `0 0 2 * * ?`, `WAITING`) as a measured fact, not an assumption. |
| `DealFolderSweepSchedule` | Comment-only: notes the sweep is now the recovery path for the LOI-rejection and `Closed Won`-backstop routes specifically, rather than an entire closing route. |

### Test Classes

| Test Class | Change |
|------------|--------|
| `DealFolderServiceTest` | Both 251-record bulk tests **moved, not renamed** — from a bulk `Closed Won` update to a bulk `New → Under Review` update (`.claude/rules/bulk-test-rule.md`'s 251 mandate binds on the synchronous trigger path, so it must be met at whatever stage that path now keys on). Added a dedicated **OQ-2 measurement test**: a real `Database.convertLead` call asserting the converted deal lands on `New` (previously inferred from picklist ordering, not measured). Added multi-stage no-op assertions proving an `Under Review → Underwriting` move is **not** a fresh entry. Measured and asserted that entering `Underwriting` fires the trigger-handler route **twice** per save (`OpportunityReviewService`'s own `update uwStamps` re-fires it) and that a five-stage walk (`New → Under Review → Underwriting → About to Close → Closed Won` plus the re-entrant routing) costs **five**, not four, route invocations. |
| `DealFolderSweepBatchTest` | Comment amended: the "canonical failure scenario" is no longer "a Transactions-persona close" — it's now the LOI-rejection final-field-update running as a read-only approver. |
| `TopDealsControllerTest` | Comment-only: confirms its bulk `Closed Won` insert fixture is still a no-op for the folder service post-move, and explains *why* (null `Property__c` on the fixture, not the stage, is what makes it a no-op). |

---

## 🔑 Why Four Stages, Not One

This is the core design decision and is recorded verbatim (mined from `DealFolderService`'s own
class header, which this repo treats as the authoritative record) rather than paraphrased.

`CLAIM_STAGES` is exhaustive by construction — every route into the pipeline passes through at
least one member:

| Route | Caught at | Why it's needed |
|---|---|---|
| `StageAdvanceService.advance()` `New → Under Review` (**Begin Review**) | `Under Review` | The ordinary route. On a normal deal this is the only entry that ever does work. |
| `Opportunity_Initiate_Underwriting` before-save flow jump, from **any** stage | `Underwriting` | Catches a flow that assigns `StageName = 'Underwriting'` directly, skipping `Under Review` entirely. Protected by `No_Backward_Stage_Movement` CARVE-OUT 2, a 2026-08-04 user decision — left untouched. |
| `StageAdvanceService.advanceTo('About to Close')`, from any stage | `About to Close` | `advanceTo` validates only that the *target* is in `ALLOWED_EXPLICIT_TARGETS` and never checks the current stage, so this was reachable from `New`. This was RESIDUAL-3's original hole; D8 closes it by making the target itself a claim stage rather than tightening `advanceTo` (whose looser contract is relied on elsewhere). |
| `Transaction_Complete_Close` flow → `Closed Won`; `advance()` `Under Contract (PSA) → Closed Won` | `Closed Won` | The final backstop — no longer the ordinary claim point, but still catches any deal that somehow reached close with no folder. |
| `Database.convertLead` | Lands on `New` (measured, not inferred — see `DealFolderServiceTest`'s OQ-2 test) | Claims on the human's first `Begin Review` click, not during conversion. |
| A record created **directly** at `LOI` or `Under Contract (PSA)` (a data load) | Not caught at insert — deferred to the next forward move | `LOI` and `Under Contract (PSA)` are deliberately **absent** from the set: both are reachable only from a stage that already claimed, so adding them would buy nothing but a no-op SOQL read on the ordinary path. The one gap this leaves is a directly-inserted record, which claims on its next forward move and reaches `Closed Won` either way — the folder is **deferred, never lost**. |

`Property_Asset__c`'s creator, `PropertyAssetService`, deliberately keeps its own single-stage key
(`Closed Won` only) — the two services now **overlap** at `Closed Won` without being identical, and
that overlap (not an identity) is what keeps `OpportunityReviewTriggerHandler`'s opposite-failure-
contract warning (`PropertyAssetService` throws by design; `DealFolderService` must never throw)
alive specifically for the `Closed Won` case.

---

## 🔄 Data Flow

```
User clicks "Begin Review" (or another claim-stage-reaching action)
        │
        ▼
Opportunity save  (StageName -> a member of CLAIM_STAGES, prior stage was not)
        │
        ▼
OpportunityReviewTriggerHandler.route()
        │  (5th of 5 calls, after OpportunityReviewService x2, ContractExecutionService,
        │   PropertyAssetService — ordering is for readability only; a throw anywhere
        │   rolls back the whole transaction regardless of statement order)
        ▼
DealFolderService.ensureOnClaimStageEntry(opps, priorById)
        │
        ├─ PropertySelector.selectFolderStateByIds   (SYSTEM_MODE, without-sharing inner class)
        │       — SOQL unchanged; only how often/how early it now runs
        │
        ├─ stamp Property__c.SharePoint_Folder_Status__c = 'Pending'  (allOrNone = false)
        │
        └─ System.enqueueJob(DealFolderQueueable)   — ONE per trigger chunk, never one per deal
                    │
                    ▼
        DealFolderQueueable.execute()  (async — callouts cannot run with uncommitted DML pending)
                    │
                    ├─ up to MAX_PROPERTIES_PER_TRANSACTION (10) properties x 7 callouts each
                    │      (1 parent folder + 6 lifecycle subfolders via SharePointCalloutService)
                    │
                    ├─ stamp Created / Failed / Skipped, self-chain the remainder
                    │
                    └─ on an uncatchable death: DealFolderFinalizer stamps Failed + reason
                                    │
                                    ▼
                    DealFolderSweepBatch (scheduled nightly, 0 0 2 * * ?)
                       re-selects every Pending/Failed Property__c and retries the identical path
```

Every claim-stage entry **after** the first for a given property is a no-op: the
`SharePoint_Folder_ID__c` guard on `Property__c` is keyed on the property, never the stage, so an
`Under Review → Underwriting` move (both claim stages) costs exactly one SOQL and nothing else.

---

## 📁 File Locations

| Component | Path |
|---|---|
| Core service (renamed method + CLAIM_STAGES) | `force-app/main/default/classes/DealFolderService.cls` |
| Trigger handler (call-site + header) | `force-app/main/default/classes/OpportunityReviewTriggerHandler.cls` |
| Selector (comment only) | `force-app/main/default/classes/PropertySelector.cls` |
| Stage-advance service (comment only) | `force-app/main/default/classes/StageAdvanceService.cls` |
| Async venue (header) | `force-app/main/default/classes/DealFolderQueueable.cls` |
| Failure reporter (comment) | `force-app/main/default/classes/DealFolderFinalizer.cls` |
| Recovery batch (header) | `force-app/main/default/classes/DealFolderSweepBatch.cls` |
| Recovery batch's scheduler (comment) | `force-app/main/default/classes/DealFolderSweepSchedule.cls` |
| Test classes | `force-app/main/default/classes/DealFolderServiceTest.cls`, `DealFolderSweepBatchTest.cls`, `TopDealsControllerTest.cls` |
| Design source | `agent-output/design-requirements-fsd-tranche-2.md` (§1, "Item 1") |
| FSD reference | `docs/DPEG Acquisitions Module FSD Revised v2.0.docx` §3, §6.1, §15.3 |

---

## ⚙️ Configuration Details

### `DealFolderService.CLAIM_STAGES`

```apex
@TestVisible private static final Set<String> CLAIM_STAGES = new Set<String>{
    'Under Review',
    'Underwriting',
    'About to Close',
    'Closed Won'
};
```

`LOI` and `Under Contract (PSA)` are deliberately absent — see *Why Four Stages*, above. Do not
widen this set to "close" the no-backfill residual (RESIDUAL-2/R5, below) — the class header is
explicit that doing so would re-key the service on *state* rather than *transition* and cause every
subsequent save of an already-claimed deal to re-claim, forever.

### Governor budget (unchanged shape, changed frequency)

- **Synchronous, per trigger chunk:** 0 callouts, 1 SOQL, ≤1 DML, ≤1 enqueue — constant in deal
  count. A chunk claiming nothing (no stage entry) still costs zero of all four.
- **What changed is not the shape but how often it's non-zero.** A `New → Under Review` save
  previously cost 0/0/0 here (it wasn't `Closed Won`); it now costs 1/1/1, on essentially every deal
  in the org, at its first forward step — including inside the LOI-rejection approval transaction.
- **Async, per job link:** ≤70 callouts (`MAX_PROPERTIES_PER_TRANSACTION = 10` × 7 callouts/property),
  1 SOQL, ≤1 DML. Unchanged by this move — it is a per-transaction callout budget, not a
  throughput knob.

---

## 🧪 Testing & Code Review

### Coverage (post-deploy, `usman-dpeg`)

| Class | Coverage |
|---|---|
| `DealFolderService` | 95% |
| `PropertySelector` | 91% |
| `DealFolderQueueable` | 90% |
| `DealFolderSweepBatch` | 85% |
| `OpportunityReviewTriggerHandler` | 100% |
| `TopDealsController` | 100% |
| `StageAdvanceService` | 100% |
| `DealFolderFinalizer` | 93% |

Three unrelated classes were watched because they insert bulk (251-record) Opportunity fixtures at
`Closed Won` for their own purposes, and the 251-record fixture in `DealFolderServiceTest` moved
*off* `Closed Won` as part of this change: `PropertyAssetService` 99%, `OnboardingAutoCreateService`
93%, `ContractExecutionService` 99% — against their **own** suites. ⚠ **Recorded because it is a
real trap, not a footnote:** run as part of the *feature* test subset (rather than the full local
suite) their figures read 85% / 75% / **27%** respectively, because that narrower run no longer
exercises the code paths the moved 251-record fixture used to incidentally cover. **A subset test
run's coverage number is not the same fact as the class's actual coverage** — always read coverage
off a `RunLocalTests` pass, not a targeted subset.

### Bulk test rule compliance

`.claude/rules/bulk-test-rule.md`'s 251-record mandate applies to the synchronous trigger path.
Both existing 251-record bulk tests in `DealFolderServiceTest` were **moved, not merely renamed** —
from a bulk `Closed Won` update to a bulk `New → Under Review` update — because the rule binds at
whatever stage the synchronous path now keys on. Record counts (251, forcing two Opportunity
trigger chunks of 200 + 51) and every assertion are otherwise unchanged.

### Code Review

**Verdict: APPROVED WITH WARNINGS.** 0 critical findings, 0 runtime defects. All 8 warnings were
documentation-accuracy findings — class headers that, after the CLAIM_STAGES move, were left
asserting a premise the same change had deleted as dead (e.g. `OpportunityReviewTriggerHandler`'s
"they share a trigger point" argument, `StageAdvanceService`'s `NEXT_STAGE`-justifies-the-Apex-
trigger argument, `DealFolderQueueable`'s whole-persona credential-outage framing). All 8 were fixed
before deploy. This codebase treats class-header Javadoc as the authoritative record of *why* code
is shaped the way it is — a confidently-false header is treated as a defect on the same footing as a
runtime one, not a nitpick, which is why none of the 8 were waved through.

---

## 🔒 Security

No sharing, mode, or permission-set change. `DealFolderService` and its collaborators keep their
existing `with sharing` / `SYSTEM_MODE`-inner-class shape unchanged by this move — the class header
is explicit that mode and sharing are unaffected by *which stage* triggers the claim, only by *how
often* the code path runs. The one security-relevant consequence is a change in **exposure**, not in
any grant: `DealFolderService`'s SOQL, DML and enqueue are now reached inside transactions they
previously never touched, including the LOI-rejection approval transaction (run as a read-only
approver) — see *Named Residuals*, item 4 below, and *Also Worth Noting*.

---

## 📝 Named Residuals

1. **NO BACKFILL (explicit user decision, re-confirmed at this move).** A deal already sitting at
   `Closed Won` on deploy day gets no folder — permanently, with no error, no counter, and no
   `Skipped` stamp anywhere to find that population by. Two independent mechanisms exclude it: the
   trigger keys on stage *entry* (a deal already at `Closed Won` never "enters" it again), and the
   sweeper's locator only selects rows this service itself has stamped `Pending`/`Failed` — an
   unclaimed property has a `NULL` status and is invisible to the sweep. ✅ **The move itself shrank
   this excluded population to its floor**: under the old `Closed Won`-only key, *every* historical
   deal in the org was excluded; under the four-stage set, only deals already sitting at `Closed Won`
   on deploy day are. The remedy, if ever wanted, is a one-off anonymous-Apex `Pending` stamp on that
   narrow population — never a code change, and never by widening `CLAIM_STAGES`.
2. **`Opportunity.OneDrive_Folder_URL__c` remains written by nothing** and displays blank on four
   live surfaces (the Opportunity record page, its page layout, the LOI path step, and the
   `Deal_Status_Breakdown` report). Fixing it was explicitly declined for this tranche (design
   decision D2). Reports do not block field deletion and fail silently if that field is ever
   retired — a fact worth carrying forward to whoever eventually closes this gap.
3. **A single user save routes the trigger handler twice when entering `Underwriting`.**
   `OpportunityReviewService.cls:496` performs `update uwStamps` to stamp
   `Primary_Underwriting__c` on the just-inserted Underwriting record, which re-fires the
   Opportunity after-update trigger. The re-entry is correctly a no-op for `DealFolderService`
   (member-to-member, no fresh claim), but the per-save invocation count for the whole handler is
   N+1, not N — pinned by `DealFolderServiceTest`'s five-stage-walk test (which asserts **five**
   invocations across four stage saves, not four).
4. **A record created directly at `LOI` or `Under Contract (PSA)`** (e.g. a data load) claims
   nothing at insert (`prior == null` and neither stage is a claim stage), but claims on its next
   forward move and reaches `Closed Won` either way — the folder is **deferred, never lost**.
5. **Budget change on essentially every deal.** A `New → Under Review` save moved from 0 SOQL / 0
   DML / 0 enqueues to 1 SOQL / 1 DML / 1 enqueue in `DealFolderService` — including inside the
   LOI-rejection approval transaction, which runs as a read-only approver. The never-throw contract
   (this service must never raise a catchable exception) is what keeps that safe today; the class
   header is explicit that this raises, rather than removes, the cost of ever introducing a path
   that does throw.

---

## 📊 Measurements Recorded (not inferred)

- **`Database.convertLead` lands a converted deal on `New`** — measured by a real conversion inside
  `DealFolderServiceTest`, not inferred from picklist ordering (`Opportunity.StageName` has no
  default on either active record type, which is what the original inference rested on).
- **`DPEG SharePoint Deal Folder Sweep` remains scheduled**: `WAITING`, `0 0 2 * * ?`, unchanged
  across this deploy. A scheduled-job *instance* is not deployable metadata, so this must be
  re-confirmed after any org rebuild (scratch org, sandbox refresh) rather than assumed.
- **Coverage subset trap** — see *Testing & Code Review* above: `PropertyAssetService`,
  `OnboardingAutoCreateService`, and `ContractExecutionService` read 99% / 93% / 99% against their
  own full suites but 85% / 75% / 27% when run as a narrower feature subset, because the 251-record
  fixture that used to incidentally cover their code moved off `Closed Won`.

---

## 🗂 Deferred Work — Item 2 (`Call_For_Offers__c`)

The design doc also specified Item 2: retiring four ad-hoc Opportunity offer-deadline fields in
favor of a new `Call_For_Offers__c` child object as the sole system of record, with a companion
roll-up back onto Opportunity. **This item was cancelled by the user before build and was not
constructed.** It remains fully designed — including its own blocking open question (whether
`Call_For_Offers__c` needs a related list, since as designed there is no UI path to create or edit
one) — in `agent-output/design-requirements-fsd-tranche-2.md` §2, should it be picked back up later.

---

## Also Worth Noting

The FSD conformance audit that produced this tranche found **22 gaps** against
`docs/DPEG Acquisitions Module FSD Revised v2.0.docx`. This change closes exactly **one** of them.
The largest of the remaining 21 are worth naming rather than re-listing in full: no Placer.ai/CoStar
integration exists at all (§18); Call for Offers is still four ad-hoc Opportunity fields rather than
an object (§25 — designed this tranche, then deferred, see above); no notification fires on entry to
Underwriting (§23 #2); and deal approvals route to two hardcoded usernames, one of which belongs to
an Avanza consultant rather than a DPEG employee (§22). This tranche should not be read as closing
the audit — it closes one item from it.

---

## 📜 Change History

| Date | Author | Change Description |
|------|--------|---------------------|
| 2026-08-27 | Documentation Agent | Initial creation — FSD Conformance Tranche 2, Item 1 (deal-folder claim-stage widening from `Closed Won` alone to four claim stages). Item 2 (`Call_For_Offers__c`) recorded as designed and deferred, not shipped. |
