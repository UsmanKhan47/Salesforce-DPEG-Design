# 📋 DESIGN REQUIREMENTS — FSD Conformance Tranche 2 — **DECISION-LOCKED (rev 3)**

**Date:** 2026-08-27
**Branch:** `feature/disposition-redesign`
**Source:** FSD conformance audit against `docs/DPEG Acquisitions Module FSD Revised v2.0.docx` —
22 gaps found, **2 approved for build**.

---

## 📖 DECISION HISTORY — READ THIS BEFORE RE-OPENING ANYTHING

This document contains a **rejected alternative**, on purpose. The path was:

| Rev | OQ-4 ruling | Outcome |
|---|---|---|
| 1 | **(a)** create a `Call_For_Offers__c` at conversion; retire all four Opportunity fields | Superseded before build |
| 2 | **(c)** keep `Opportunity.Offer_Due_Date__c`; retire the other three | 🔴 **Shown to be incoherent** — see §0.1. Design proposed a "nearest coherent variant" (child-as-LOG, parent-as-ENGINE, retire one field). |
| **3 — CURRENT** | **back to (a)** — retire ALL FOUR. `Call_For_Offers__c` is the **sole system of record**; the alert marker lives on the child; `LeadConvertService` creates a child at conversion. | ✅ **BUILD THIS** |

🔴 **The rev-2 "child-as-LOG" amendment is WITHDRAWN and is NOT the design.** It is recorded at
§0.2 as a rejected alternative with its reasoning, because it is the thing a future reader will
otherwise re-propose on seeing the two-object split. **`Lead.Offer_Due_Date__c` is KEPT** — that
half of the original decision survived every revision.

**Authorities consulted:** `CLAUDE.md`, `ARCHITECTURE.md`, all five files in `.claude/rules/`.

---

## DECISIONS LOCKED

| Ref | Decision |
|---|---|
| **D1** | Item 1 claims on entry to any **CLAIM STAGE**. Under the RESIDUAL-3 closure that set is now **`{Under Review, Underwriting, About to Close, Closed Won}`**. `Opportunity_Initiate_Underwriting` and `No_Backward_Stage_Movement` CARVE-OUT 2 **not touched**. |
| **D2** | **UNCHANGED.** Item 1 is the trigger-point move ONLY — no `Opportunity.SharePoint_Folder_URL__c`, no repointing of the four `OneDrive_Folder_URL__c` surfaces. **Item 1 is developer-only; there is no admin prompt for it.** |
| **D3-REVISED** | **Retire ALL FOUR** Opportunity fields. `Call_For_Offers__c` is the sole system of record. Marker on the child. `LeadConvertService` creates a child at conversion. `Lead.Offer_Due_Date__c` KEPT. |
| **D4** | **UNCHANGED.** No related list, no tab, no app-nav or `tabVisibilities` change. **GATE FP-1 does not fire.** ⚠ **See §0.3 — this is now in tension with D3-REVISED.** |
| **D5** | Auto Number `CFO-{0000}`. |
| **D6** | **No grant on `Broker_Protection_Access`.** |
| **D7** | OQ-8 (approval lock vs MD child insert) stays a **named measurement** in the technical-architect prompt. |
| **D8** | **RESIDUAL-3 CLOSED** by widening `CLAIM_STAGES` to four stages. |
| **D9** | **OQ-11 ANSWERED: YES** — carry existing values across, folded into the one migration. |

## ORG MEASUREMENTS (usman-dpeg, 2026-08-27, read-only)

| Ref | Result |
|---|---|
| **OQ-2** | `Opportunity.StageName` has **no default on either active record type**; `New` is first in every business process ⇒ **`convertLead` lands on `New`.** ⚠ **Inference from picklist ordering, not a measurement** — must be confirmed by a real `Database.convertLead` assertion (named step in the Item 1 prompt). |
| **OQ-10** | ✅ **The folder sweep IS scheduled** — `DPEG SharePoint Deal Folder Sweep`, `0 0 2 * * ?`, `WAITING`. |
| **NEW** | 🔴 **`CallForOffersAlertSchedule` is NOT in `CronTrigger` at all** — the reminder has never fired. See §0.4 and **GATE G-CFO**. |

---

# ═══ §0 — WHAT STILL DOES NOT HOLD ═══

## §0.1 ✅ D3-REVISED FIXES THE INCOHERENCE THAT KILLED REV 2

Recorded so the fix is not accidentally undone. Rev 2 kept the deadline on the Opportunity while
retiring its alert marker — separating a **state field from the value it tracks**. The marker's job
is `shouldFire`'s `markerDate == liveDate` comparison; with the deadline on the parent and the
marker on the child, a deal with no child had no marker, and the batch could only **never alert it**
(feature dead for the majority) or **alert it every day forever** — the exact failure
`CallForOffersService` §3 exists to prevent. There was no third behaviour.

**D3-REVISED closes it at the root:** because `LeadConvertService` now creates a child at
conversion, **every deadline has a child**, so every deadline has somewhere to keep its marker.
All four `shouldFire` inputs come from one row. One ladder, one marker home, one engine. ✅

🔴 **The load-bearing consequence: `LeadConvertService` creating a child is not a convenience — it
is what makes the marker coherent.** If it is ever dropped or made conditional in a way that lets a
deadline exist without a child, the rev-2 failure returns immediately and silently. This must be
stated in `CallForOffersService`'s header, not just in `LeadConvertService`'s.

## §0.2 📕 REJECTED ALTERNATIVE (rev 2) — recorded so it is not re-proposed

> **"Child as LOG, Opportunity as ENGINE"** — keep `Opportunity.Offer_Due_Date__c` and both marker
> fields as the alerting engine; let `Call_For_Offers__c` record only what a campaign email said;
> retire only `Call_For_Offers_Received_Date__c` (whose population is identical to the child's).
> **Rejected** because it leaves the deadline in two places permanently, requires
> `CallForOffersStampService` to write both objects in one transaction to keep them agreed, and
> leaves a hand-edit of one silently not moving the other. It was proposed only as the minimum
> change that made rev-2's ruling buildable; once the user accepted creating a child at conversion,
> it has no advantage over D3-REVISED and one clear disadvantage.

## §0.3 🔴 **THE THING THAT DOES NOT HOLD: D4 AND D3-REVISED ARE IN TENSION. THERE IS NO UI PATH TO CREATE OR EDIT A `Call_For_Offers__c`.**

This is stated with the same directness used on D3, because it is the same class of problem: a
decision that was correct under one reading of the object's role is not correct under another.

**D4 (no related list, no tab, no app-nav) was decided when the child was a LOG** — a
nice-to-have visibility record whose absence from navigation cost nothing. **Under D3-REVISED the
child is the SOLE SYSTEM OF RECORD for a deadline the acquisitions team is expected to act on.**
With no related list on the Opportunity, no tab, and no app-nav entry, the only ways a
`Call_For_Offers__c` row is ever created or changed are `LeadConvertService` and
`CallForOffersStampService`. Both are automated. Four concrete consequences:

1. 🔴 **FSD §25.1 says Due Date is "extracted from the email, **editable**". It will not be
   editable.** There is no navigable surface on which to edit it. `callForOffersPanel` is a
   `cacheable=true` read (its own header notes there is *"no in-page action that can change a due
   date"*), and `callForOffersList` is a read-only table.
2. 🔴 **RESIDUAL-11's premise collapses.** "At most one OPEN call for offers per deal" depends on a
   human setting `Status__c` to `Submitted`/`Closed` so a genuinely new campaign can open a new
   record. With no UI path, **`Status__c` can never leave `Open`**, and every subsequent campaign
   overwrites the first record forever. The `Status__c` picklist becomes decorative.
3. **A manually created deal can never have a call for offers.** `DealFolderService`'s residual R1
   already establishes that deals built by hand exist (only `LeadConvertService` creates a
   `Property__c`). Such a deal has no child and no way to get one.
4. **Nothing can be corrected.** An LLM-extracted due date that is wrong is uncorrectable, on a
   record that now drives reminders to the whole `Acquisition` queue.

**RECOMMENDED RESOLUTION — reopen D4 for the RELATED LIST ONLY, not the tab.**
A `Call_For_Offers__c` related list on `Opportunity_Record_Page` gives create, edit and Status
changes in place, is the natural home for a child record, and costs exactly one FlexiPage edit.
No tab, no `tabVisibilities`, no app file, no other hub file — so the parallel-build hub-file
protocol is respected and only **GATE FP-1** comes back into play.
⚠ **GATE FP-1 is not optional if this is accepted:** a FlexiPage deploy replaces the org copy and
there is **no version history**; hand-edits to this page have been lost before. Retrieve and diff
against `HEAD` seconds before deploying, and check `SetupAuditTrail` for saves newer than the
retrieve.

**If D4 stands as written**, then FSD §25.1's "editable" is not satisfied, `Status__c` should be
dropped to a single value or removed (a picklist nobody can change is worse than no picklist), and
RESIDUAL-11 must be rewritten to say that the first campaign's record is permanent. **Say which.**
→ **OQ-12**, the only blocking question left.

## §0.4 🔴 The reminder has never fired in this org

`CallForOffersAlertSchedule` does not appear in `CronTrigger`. **The Call for Offers reminder is
currently INERT** — a quiet `Acquisition` queue is not evidence the ladder works, because nothing
has ever run. Post-deploy **GATE G-CFO** must schedule it.
⚠ The marker fields are therefore almost certainly **null org-wide**, which has two consequences:
the migration (§2.5) will find nothing to carry in those two columns, and the **first run after
scheduling will alert every open deal inside the 7-day ladder in one burst.** Correct behaviour;
plan for it rather than treating it as an incident.

---

# ═══ FINDINGS THAT CORRECTED THE ORIGINAL BRIEF ═══

**F1 — `Under Review` was skippable** via the before-save `Opportunity_Initiate_Underwriting` flow,
protected by CARVE-OUT 2. ✅ **CLOSED BY D1.**

**F2 — `OneDrive_Folder_URL__c` is displayed on four surfaces and is permanently blank**
(`flexipages/Opportunity_Record_Page:352`, `layouts/Opportunity-Opportunity Layout:121`,
`pathAssistants/Acquisitions_Deal_Path:24`, `reports/Acquisitions/Deal_Status_Breakdown:364`, plus 3
permission sets). ⚠ **D2 declines the fix** → **RESIDUAL-5**, deliberately unclosed.

**F3 — the Lead surfaces need no change.** Both reference `Lead.Offer_Due_Date__c`, KEPT. ✅ Still
true, and now the *only* thing on Lead that stays. `EmailToLeadService` and
`ExtractAddressQueueable` also touch only the **Lead** field (that service *"owns Lead DML and ONLY
Lead DML"*) ⇒ **out of scope.**

**F4 — `Broker_Protection_Access` carries only the Lead field** ⇒ no removal (D6 confirms no
addition either). ⚠ `DPEG_Admin_Access` appears to be **missing `Opportunity.Offer_Due_Date__c`** in
the repo copy — under D3-REVISED that field IS now retiring, so this must be **resolved under GATE
PS-1**, not merely reported: if the org has the grant and the repo does not, a naive deploy would
have removed something else.

**F5 — `LeadConvertService:354`.** ✅ **IN SCOPE under D3-REVISED** — see §2.5.

**F6 (new, verified this round) — `objects/Opportunity/fields/Listing_Status__c.field-meta.xml`
names `Offer_Due_Date__c`, but only inside an XML COMMENT** (*"it therefore sits beside
Sale_Process__c, Offer_Due_Date__c and the listing-broker fields"*). **Not a formula, not a
dependency** — the retirement does not break it. The comment should be amended for accuracy but is
not a blocker.

---

# ═══ ITEM 1 — Deal folder tree at CLAIM-STAGE entry ═══
*(Unchanged by D3-REVISED. Item 1 and Item 2 share no metadata and no class.)*

## §1.1 — `CLAIM_STAGES` = `{Under Review, Underwriting, About to Close, Closed Won}`

**D8 closes RESIDUAL-3** by making the set exhaustive rather than by tightening `advanceTo`. The
`SharePoint_Folder_ID__c` guard makes every claim after the first a **zero-callout, zero-DML,
zero-enqueue no-op**, so a normal deal still claims exactly once, at `Under Review`; the extra three
entries cost one SOQL each and exist only to catch the skip routes.

**Exhaustiveness proof — every route into the pipeline passes through at least one claim stage:**

| Route | Caught at |
|---|---|
| `advance()` `New → Under Review` (**Begin Review**) | `Under Review` ✅ |
| `advance()` `Under Review → Underwriting` | already claimed (no-op) |
| `advanceTo('Development Review'\|'Construction Review')` from `New` — `advanceTo` does **not** validate the predecessor | one stage later, at `Underwriting` (`NEXT_STAGE` maps both branch reviews there) ✅ |
| `Initiate_Underwriting__c` before-save jump from **any** stage | `Underwriting` ✅ |
| 🔴 `advanceTo('About to Close')` from any stage — the old RESIDUAL-3 hole | **`About to Close`** ✅ **now closed** |
| `LOI_Approval` final-rejection `LOI → Underwriting` | already claimed (no-op). ⚠ New principal — RESIDUAL-4 |
| `Transaction_Complete_Close` flow → `Closed Won` | `Closed Won` ✅ |
| `advance()` `Under Contract (PSA) → Closed Won` | `Closed Won` ✅ |
| `Database.convertLead` | lands on `New` (OQ-2) — claims on the first Begin Review |
| Dead/Pass two-save recovery back up | no-op |

⚠ **`LOI` and `Under Contract (PSA)` are deliberately NOT in the set**, and that is correct: neither
is reachable except from a stage that already claimed. **The one uncovered case is a record
*created directly* at `LOI` or `Under Contract (PSA)`** (a data load) — `prior == null` and the
stage is not in the set, so nothing claims. Such a deal claims on its next forward move, which
reaches `Closed Won` either way, so **the folder is deferred, never lost.** One-line note, not a
residual.

## §1.2 — Volume

**`MAX_PROPERTIES_PER_TRANSACTION = 10` and `DealFolderSweepBatch.SCOPE` hold unchanged** — they are
**per-transaction** callout budgets (10 × 7 = 70 callouts ≈ 105 s at 1.5 s/call against the 90 s
`CALLOUT_TIME_BUDGET_MS` deferral point, which reserves exactly one property's worst case of
7 × `TIMEOUT_MS` inside the 120 s ceiling). The trigger point cannot move them. The synchronous side
stays **1 SOQL, ≤1 DML, ≤1 enqueue per chunk, constant in deal count**, zero callouts.

🔴 **The convertLead risk does not materialise** (OQ-2): conversion lands on `New`, so no claim
happens inside the `Database.convertLead` transaction. The claimer is the human clicking **Begin
Review** — a single-record UI save, so chunks are size 1.

🔴 **The credential picture improves, and it is the most important consequence of Item 1.**
`DealFolderSweepBatch`'s header records that its reason for existing is that
`Transaction_Complete_Close` writes `Closed Won` with no `<runInMode>` — as the **Transactions**
persona — while `SharePoint_Integration_Access` is granted to `DPEG_Junior_Analyst_PSG` **only**, so
an entire ordinary closing route has every callout refused. At `Under Review` the claimer is a deal
driver **who holds the grant**. ⇒ **`HINT_CREDENTIAL` and `DealFolderSweepBatch`'s header become
affirmatively wrong**, not merely stale.
⚠ Partially re-opened by D1 in two narrow ways: the LOI-rejection path (RESIDUAL-4) and — because
`Closed Won` is now itself a claim stage — the `Transaction_Complete_Close` route survives as a
*backstop* claim for any deal that reached close without a folder. Both must be named in the
rewritten hint.

Graph rate becomes `7 × (deals entering a claim stage per day)`, bounded at 70/transaction, degrading
into deferral rather than failure, with a 429 stamped `Failed` and retried by the sweep — **which
OQ-10 confirms is live.** DPEG's throttle allocation remains unknowable from source (**RESIDUAL-6**).

## §1.3 — D2: no admin work

**Item 1 is developer-only.** F2 retained as RESIDUAL-5.

## §1.4 — The rename

🔴 **Both `ensureOnUnderReview` and `ensureOnReviewEntry` now lie** — the set runs to `Closed Won`,
which is not a review stage. The repo's stage-in-the-method-name convention cannot express four
stages.

**PROPOSED:**
```apex
DealFolderService.ensureOnClosedWon → ensureOnClaimStageEntry
DealFolderService.CLOSED_WON (String) →
    @TestVisible private static final Set<String> CLAIM_STAGES = new Set<String>{
        'Under Review', 'Underwriting', 'About to Close', 'Closed Won' };
```
`ensureOnClaimStageEntry` uses vocabulary the class already owns (`claimFolders`, *"claim a
SharePoint deal folder"*) and points the reader at the constant, which becomes **the authoritative
statement of which stages claim**. Its Javadoc must record *why each entry is there* — `Under
Review` is the ordinary route; `Underwriting` catches the `Initiate_Underwriting__c` jump; `About to
Close` catches the unvalidated `advanceTo` target; `Closed Won` is the final backstop — or a future
reader will "tidy" the set back down and silently reopen F1 and RESIDUAL-3.

🔴 **The prior-stage test must use the SET too:**
```apex
CLAIM_STAGES.contains(o.StageName)
  && (prior == null || !CLAIM_STAGES.contains(prior.StageName))
```
If the prior check tests a single stage, an ordinary `Under Review → Underwriting` move registers as
a **fresh entry** and costs a needless SOQL on every deal. Assert it explicitly.

**Move list — 13 sites; five are FALSE PREMISES, not stale strings.** Full detail in the Item 1
prompt: `OpportunityReviewTriggerHandler:82`, `:11`, `:19-25` (the *"share a trigger point"* block
— they no longer do), `:71-82`; `DealFolderService:18-28` (the `NEXT_STAGE`-both-routes argument,
now moot), `:180` (the *"must not drift between two services"* invariant, now **false**),
`:300-317` (`HINT_CREDENTIAL`), `:122-149` (residual R5 → the no-backfill residual), plus lines 2,
30-33, 110, 290-297, 353, 393-414; `DealFolderSweepBatch:5-27`; `StageAdvanceService:106-112`;
`DealFolderQueueable` / `DealFolderFinalizer` headers; `PropertySelector:15` +
`FolderCreationReads` (🔴 **not** `AssetCreationReads`); the four test classes; `ARCHITECTURE.md`
and two docs.

## §1.5 — The never-throw contract survives

**STRUCTURAL, therefore stage-independent** — all six mechanisms (the `catch (Exception)` wrapper;
the enqueue's own `Limits.getQueueableJobs()` guard for the one uncatchable path;
`SharePointCalloutService` returning failures as values; `SharePointConfig` degrading to DISABLED;
`allOrNone = false`; zero synchronous callouts) transfer unchanged.

**Four changes in the STAKES**, all to be recorded in the header: (i) a rollback now blocks a deal
at its **first** forward step; (ii) a throw surfaces through `StageAdvanceService.setStage`'s
`catch (DmlException)`, which rethrows `getDmlMessage(0)` **verbatim into a user's toast**;
(iii) under D8 the contract is exercised on essentially every deal at **up to four** entry points,
so a latent throwing path is a pipeline-wide outage; (iv) 🔴 the LOI-rejection path reaches this
code **inside an approval transaction as a read-only approver** — `OpportunityReviewService`'s
header documents that a throw there rolls back the **approval** and shows the approver a platform
error on an Approve click (the D10 `ApprovalAuditService` incident shape).

---

# ═══ ITEM 2 — `Call_For_Offers__c` as the sole system of record ═══

## §2.1 — Master-Detail, and the roll-up is now REQUIRED

**✅ MASTER-DETAIL to Opportunity**, on the original four reasons — all of which now hold:

| Reason | Status |
|---|---|
| Child inherits Opportunity's **`ReadWrite`** OWD (measured 2026-08-10) ⇒ **zero new sharing artefacts**; a lookup means Private OWD + a criteria sharing rule + a public group **whose membership is not deployable** (inert until added by hand) | ✅ |
| Required parent enforces FSD §25.2.1's scope gate **structurally** | ✅ |
| Cascade delete — a call-for-offers with no deal is meaningless | ✅ |
| **Roll-up summary onto Opportunity** | ✅ **RESTORED — and now mandatory, see below** |

🔴 **THE ROLL-UP PROHIBITION FROM REV 2 IS LIFTED, AND THE REASON MUST BE RECORDED.** Rev 2
forbade it because `Opportunity.Offer_Due_Date__c` survived, so a roll-up would have been **null for
the majority population while the real deadline sat in the field beside it** — two deal-level date
fields with overlapping meaning and different populations. **Under D3-REVISED that parent field
retires, so there is nothing left to collide with.** The prohibition's premise is gone.

### §2.1.1 🔴 CONCRETE RESOLUTION for `Opportunity.Offers_Due_Soon` — **option (a), the roll-up**

**Build `Opportunity.Next_Offer_Due_Date__c` = ROLL-UP SUMMARY `MIN(Call_For_Offers__c.Offer_Due_Date__c)`
filtered `Status__c = 'Open'`.**

**Why (a) and not (b) "move the view to the child and delete the Opportunity one":**
🔴 **the compact layout decides it.** `objects/Opportunity/compactLayouts/Deal_Highlights` shows
`Offer_Due_Date__c`, and **a compact layout cannot reference a child field under any circumstance.**
Option (b) would silently delete the offer deadline from the Deal Highlights panel — the
highlights strip on every Opportunity record — with no replacement possible. The roll-up is the
only mechanism that keeps that slot alive. It simultaneously keeps the **page layout** and the
**list view** working, so one field resolves all three surfaces.

**What the user loses under (a), stated plainly:**
1. **The list view's semantics shift from "this deal's deadline" to "this deal's soonest OPEN
   deadline".** A deal whose only campaign is `Submitted`/`Closed` drops out of the view. That is
   arguably an improvement (a closed campaign is not something to chase) but it **is** a behaviour
   change and should be expected rather than discovered.
2. **A deal with two open campaigns shows only the sooner one.** Near-theoretical given the
   one-open-per-deal idempotency key (§2.3), but real if that key is ever relaxed.
3. **Roll-ups are read-only** — no Apex, no migration and no user can write the field. Nothing needs
   to, but a future requirement to override a deal-level deadline would have to go to the child.
4. **Recalculation cost during the backfill** — a MIN roll-up recomputing across the whole migrated
   parent set is a real, non-zero cost. Size it before the live run (§2.5).

⚠ **Verify before building:** Opportunity's roll-up-summary count against the 25-per-object limit.
Not checkable from source.

**We also build (b) *as well*** — a `Call_For_Offers__c.Offers_Due_Soon` list view — because it is
the honest per-campaign surface and expresses `Status__c`, which the roll-up cannot. Under D4 it is
reachable only by direct URL (**RESIDUAL-14**; see §0.3/OQ-12).

**MD field settings:** required; **`writeRequiresMasterRead = true`** (so a persona who can only
READ a deal can still log a call for offers — the default `false` demands EDIT on the parent, the
gotcha hit on `Lease_Activity__c` / `Renewal_Activity__c`); `reparentableMasterDetail = false`.

## §2.2 — The single-derivation invariant

`CallForOffersService.evaluate(Date, Date)` and `shouldFire(Integer, Integer, Date, Date)` take
**primitives only** and are already object-agnostic. Under D3-REVISED the ladder's inputs all come
from **one `Call_For_Offers__c` row** — no coalesce, no second candidate, no second marker home.

**DO NOT:** change `ALERT_INTERVALS = {7,3,1,0}` (hardcoded, **no Custom Metadata** — the user
amends the FSD rather than adopting §25.2.2's configurable 2-day reminder); merge `CRITICAL_DAYS`
/ `APPROACHING_DAYS` into it (they stay separately declared, and
`CallForOffersServiceTest.everyRungOfTheLadderMapsToExactlyOneBand` must stay green **with zero
edits** — it is the coupling and the falsifier); "fix" the documented top-rung divergence (batch
alerts at 7; UI paints red from 3); or retire `dealArrivedDate`.

⚠ **`evaluateAll` now iterates `Call_For_Offers__c` rows and must traverse to the parent for three
DTO members** — `propertyName` (`Opportunity__r.Name`, deliberately not `Property__r.Name`) and
`dealArrivedDate` (`Opportunity__r.Broker_First_Seen__c` ?? `Opportunity__r.CreatedDate`). 🔴 Under
`USER_MODE` that traversal adds an **object-level gate on Opportunity plus an FLS gate on
`Broker_First_Seen__c`**, and `USER_MODE` **throws rather than degrades** — the exact trap
`CallForOffersService` §4 documents for `Property__r.Name`. Verify the grant per persona and pin it
with a test; do not assume.

## §2.3 — Idempotency key: `Opportunity__c` + `Status__c = 'Open'`

**At most ONE open Call for Offers per deal.** Update the open one; create only when none exists.

Rejected, with reasons carried into the prompt so they are not re-derived: keying on the **due
date** makes an extension create a *second* record — exactly the FSD behaviour that must not happen;
keying on the **inbound Message-Id** does the same **and** is redundant, because the RFC Message-Id
duplicate guard already runs upstream in `ExtractAddressQueueable` and returns **before the
callout**, so a platform redelivery never reaches `CallForOffersStampService` at all.

🔴 **Under D3-REVISED this key acquires a second job:** `LeadConvertService` creates the first
child, so the stamp service's *first* action on a converted deal is almost always an **UPDATE**, not
an insert. That is the path that must be tested, and it is what makes *"if the broker moves the
date, the reminder recalculates automatically from the new date"* true — the update moves
`Offer_Due_Date__c`, and the existing snapshot comparison in `shouldFire` re-arms the ladder by
itself. **Do not add a marker reset anywhere**; `CallForOffersService` §3 explains at length why the
re-arm must fall out of the comparison.

**Preserve verbatim:** the FSD §25.2.1 scope gate (structural — the MD parent is required; **do not
add a Lead branch**); `mergeByRecord`'s de-duplication (a duplicate Id in one `update` throws
`DUPLICATE_VALUE` for the *whole statement*, which `allOrNone = false` does not rescue); all four
`StampResult` populations **including `missing`**, the only channel that can see a sharing-filtered
read; `allOrNone = false`; per-field last-wins / ignore-null / no-change-skip; all three test seams;
the describe-guard pattern, moved from `Sale_Process__c` onto the new **restricted** `Status__c`.

🔴 **Re-pin the governor shape deliberately.** Currently *"exactly 1 SOQL and at most 1 DML per
call, constant in the number of matched deals"*. It becomes **≤2 SOQL / ≤2 DML** (parent-match read
+ existing-open-child read; child update + child insert) — **still CONSTANT in matched deals**,
which is the property that matters. Update
`ExtractAddressQueueableTest.callForOffers_matched_governorBudget...` to the new numbers on purpose;
do not loosen the assertion.

## §2.4 — `SYSTEM_MODE` and sharing — **all three decisions are back, argued separately**

Per `ARCHITECTURE.md` §2, mode and sharing are two separate questions, argued **at each method's own
declaration**, and the selector class headers — not this document — are the authoritative inventory.
**No Opportunity-era justification is carried across.**

**(i) `CallForOffersAlertBatch.stampMarkers` — the marker write, now on `Call_For_Offers__c`**
- **MODE = `SYSTEM_MODE`.** The argument is *stronger* than the one it replaces, not inherited: the
  Opportunity-era reasoning was "the two marker fields are new and have no FLS". On the new object
  **every field is new**, so the entire record is inaccessible under `USER_MODE` on day one,
  including for the deploying administrator. And no principal asks for this write — the scheduler
  makes it on the team's behalf.
- **SHARING = `with sharing` (class keyword), SUFFICIENT — and sufficient *because of* the MD
  decision**, not by default: the child inherits Opportunity's `ReadWrite` OWD, so the scheduling
  principal reaches every row. **No `without sharing` inner class is needed or justified.**
- 🔴 **Contingency, into the header:** if Opportunity is ever narrowed to Private this write
  silently refuses rows and `allOrNone = false` swallows it — the 2026-08-25 incident shape (*a
  `SYSTEM_MODE` write that still enforced sharing, which worked only when the principal owned the
  record, which is what every test does*). Required: **keep `allOrNone = false`** (one refused row
  must not cost the other 199 their markers, because an unstamped-but-notified deal alerts again
  tomorrow); **keep the per-row `SaveResult` logging**; **add a read/write diff counter** asserting
  `attempted == succeeded + logged` so a wholesale refusal is countable rather than a silent zero;
  and **test with `System.runAs` a non-owner**.

**(ii) `CallForOffersSelector.queryAlerts` — the batch locator, moving off `OpportunitySelector`**
- **MODE = `SYSTEM_MODE`**, same argument, at its own declaration.
- **SHARING = `with sharing`, sufficient**, same MD reasoning, same contingency.
- ⚠ **The `IsClosed` filter must traverse.** Today the locator filters `IsClosed = FALSE` on the
  Opportunity; on the child it becomes `Opportunity__r.IsClosed = FALSE`. Relationship traversal in
  a `QueryLocator` `WHERE` is supported, and `SYSTEM_MODE` lifts CRUD/FLS on both objects, so this
  holds — but it is a new cross-object dependency and should be stated. Add `Status__c = 'Open'`.
- ⚠ `OpportunitySelectorTest.queryCallForOffersAlerts_doesNotSelectTheReceivedDate` pins a
  deliberate omission that now lives on another object. **Move and reword it; do not delete it.**

**(iii) `CallForOffersSelector.selectOpenByOpportunityIds` — the stamp service's idempotency read**
- **MODE = `SYSTEM_MODE`**, same argument.
- **SHARING = `with sharing`, sufficient**, same MD reasoning.
- 🔴 **This is an IDEMPOTENCY-GUARD read, which `ARCHITECTURE.md` §2 singles out in red:** a
  sharing-filtered guard read *"does not disable the feature, it inverts it into a
  duplicate-maker"*. Under-reading here mints a **second open `Call_For_Offers__c`** for a deal that
  already has one. The `missing` population is the only channel that detects it.

**The two UI reads** (`selectOpen` / `selectById`) stay **`WITH USER_MODE`** — a human asked for
them. 🔴 Do **not** simplify them to `SYSTEM_MODE`: `CallForOffersController`'s header records that
it would make both `catch` blocks untestable, since `System.runAs` a bare user is exactly how they
are covered today. 🔴 **HARD DEPLOY ORDER: the permission sets must land WITH the object, never
after** — every field is new, and `USER_MODE` throws on the whole row for one inaccessible field.

## §2.5 — `LeadConvertService`: the budget re-derived

**Current contract, verbatim from the class header:** `2 SOQL / ≤5 DML, CONSTANT` —
`SOQL 1` RecordTypeSelector, `SOQL 2` OpportunityContactRoleSelector; `DML 1` Property insert,
`DML 2` Opportunity update (**all-or-none, deliberately**), `DML 3/4` the partitioned contact-role
write (**only one of the two is reachable through this path**), `DML 5` Contact record-type stamp,
`DML 6` Account record-type stamp. Honest worst case = **five** statements.

**The change:** delete `o.Offer_Due_Date__c = l.Offer_Due_Date__c` (line 354); add a
`Call_For_Offers__c` insert for every converted Lead carrying a non-null `Lead.Offer_Due_Date__c`.

**New contract: `2 SOQL / ≤6 DML, CONSTANT.` ✅ THE PIN STILL HOLDS.**
- **SOQL: unchanged at 2.** No new query is needed — the Lead rows are already in hand from
  `justConvertedByOpportunity`, and the Opportunity Ids are its keys.
- **DML: +1**, `isEmpty()`-guarded, **one statement for the whole chunk, never one per record.**
- **251 conversions run as TWO `convertLead` chunks, so the service fires TWICE** ⇒ worst case
  **12 DML and 4 SOQL** in one transaction, against limits of 150 and 100. Comfortable.
- 🔴 `LeadConvertServiceTest.bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities` asserts
  the **per-invocation** bound and must be raised to `≤6` **deliberately**, with the header's
  enumeration extended to `DML 7`.

🔴 **THREE CONSTRAINTS ON THE NEW INSERT, EACH FROM A MEASURED INCIDENT IN THIS REPO:**
1. **`allOrNone = false`, never all-or-none.** `DML 2` is all-or-none *on purpose* because the
   structural fields must land. The child insert must follow the **Property insert**'s precedent
   instead — *"one bad Property must never roll back the conversion"* — because a failed call-for-
   offers row must never cost a lead its conversion.
2. 🔴 **Explicit `AccessLevel.SYSTEM_MODE`, not a bare `insert`.** The header claims *"this service's
   DML runs in SYSTEM MODE"*, which is true of an ordinary trigger context — **but this repo has
   measured that `EmailsimpleRespectProfiles` is ACTIVE, so Apex on an inbound-email-service path is
   NOT in system mode**, and one read-only field killed that pipeline for six days while the service
   logged *Success*. Every field on `Call_For_Offers__c` is new and has **no FLS for anyone** on
   deploy day, so this is the first insert in that class that would actually expose the difference.
   Stating the access level explicitly costs nothing and removes the question.
3. **Describe-guard `Status__c`** before writing it, for the same reason every other restricted
   picklist write in that class is guarded — an off-list value is a runtime
   `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`. (Writing the literal `'Open'` is safe today; the guard
   protects against the value being deactivated in Setup without a deploy.)

⚠ **Field mapping at conversion:** `Offer_Due_Date__c` ← `Lead.Offer_Due_Date__c`;
`Source_Broker_Name__c` / `Source_Broker_Email__c` ← the Lead's listing-broker fields (which
`LeadConvertService` already copies to the Opportunity and continues to);
`Status__c` = `'Open'`; `Received_Date__c` = **null** (no email arrival is known at conversion —
leave it null rather than inventing one; `dealArrivedDate` already covers "when the deal arrived").

## §2.6 — Migration: **restored, all four fields, D9 = carry everything across**

**`CallForOffersBackfillBatch`** — a one-off `Database.Batchable`, deployed → run once → verified →
**deleted**. Rejected: anonymous Apex (no chunking; documented governor-cascade history here) and
Data Loader (no idempotency guard, manual transform).

**Source:** `SELECT ... FROM Opportunity WHERE Offer_Due_Date__c != NULL`

| Opportunity source | `Call_For_Offers__c` target |
|---|---|
| `Id` | `Opportunity__c` (MD parent) |
| `Offer_Due_Date__c` | `Offer_Due_Date__c` |
| `Call_For_Offers_Received_Date__c` | `Received_Date__c` |
| `Listing_Broker_Name__c` *(NOT retiring — copy)* | `Source_Broker_Name__c` |
| `Listing_Broker_Email__c` *(NOT retiring — copy)* | `Source_Broker_Email__c` |
| `Offer_Alert_Due_Date__c` | `Offer_Alert_Due_Date__c` |
| `Offer_Alert_Last_Interval__c` | `Offer_Alert_Last_Interval__c` |
| derived from `IsClosed` | `Status__c` = `Closed` if closed, else `Open` |

🔴 **CARRYING THE TWO MARKER FIELDS IS NOT OPTIONAL AND IS THE THING MOST LIKELY TO BE DROPPED.**
`shouldFire` treats a marker whose snapshot differs from the live due date as **blank** and re-arms
the whole ladder. Dropping them makes the batch **re-alert the entire back catalogue** on its next
run, firing a burst of notifications at the live `Acquisition` queue.
⚠ **Per §0.4 they are probably null org-wide anyway** (the job has never been scheduled) — carry
them regardless, so the code is correct rather than accidentally correct.

**Idempotency:** skip any Opportunity that already has a `Call_For_Offers__c` child ⇒ freely
re-runnable (it will be run at least twice: dry run, then live). **`SYSTEM_MODE`** — the new fields
have no FLS for anyone.

**Verification queries — run all four; a count match alone is not proof:**
```sql
-- V1 totals agree
SELECT COUNT() FROM Opportunity WHERE Offer_Due_Date__c != NULL
SELECT COUNT() FROM Call_For_Offers__c

-- V2 no source row was skipped (expect ZERO rows with an empty child set)
SELECT Id, Offer_Due_Date__c, (SELECT Id FROM Call_For_Offers__r)
FROM Opportunity WHERE Offer_Due_Date__c != NULL

-- V3 no duplicates were minted (expect every count = 1)
SELECT Opportunity__c, COUNT(Id) FROM Call_For_Offers__c
GROUP BY Opportunity__c HAVING COUNT(Id) > 1

-- V4 🔴 THE MARKERS SURVIVED — the two counts MUST be equal
SELECT COUNT() FROM Opportunity WHERE Offer_Alert_Last_Interval__c != NULL
SELECT COUNT() FROM Call_For_Offers__c WHERE Offer_Alert_Last_Interval__c != NULL
```

**Operational gates:** run with `CallForOffersAlertSchedule` **unscheduled** (per §0.4 it already
is — confirm rather than assume, since GATE G-CFO may have been run early). Size the **roll-up
recalculation** cost across the migrated parent set before the live run.

## §2.7 — Surfaces

| Surface | Under D3-REVISED |
|---|---|
| `objects/Opportunity/listViews/Offers_Due_Soon` | **REPOINT** both date filters **and the `Offer_Due_Date__c` column** onto `Next_Offer_Due_Date__c`. `Listing_Broker_Name__c` / `Listing_Broker_Email__c` columns and the `STAGE_NAME` filter are unaffected (those fields are not retiring). 🔴 **PRESERVE AND AMEND the file's large explanatory XML comment** — the window rationale (rear-view week; 30 days forward because 14 is inside an approval round) is still valid, and a note about the new "soonest OPEN" semantics belongs in it. ⚠ The comment must stay **inside** the root element. |
| `objects/Opportunity/compactLayouts/Deal_Highlights` | **REPOINT** `Offer_Due_Date__c` → `Next_Offer_Due_Date__c`. 🔴 This is the surface that **forces** the roll-up (§2.1.1). |
| `layouts/Opportunity-Opportunity Layout:133` | **REPOINT** `Offer_Due_Date__c` → `Next_Offer_Due_Date__c`, **read-only** (roll-ups cannot be edited; the current entry is `<behavior>Edit</behavior>`). |
| `objects/Lead/*` (list view + compact layout) | 🔴 **NO CHANGE** (F3). |
| `flexipages/Opportunity_Record_Page` | **Not touched under D4** — ⚠ unless OQ-12 reopens it for the related list, in which case **GATE FP-1 fires.** |
| Custom tab / app nav / `tabVisibilities` | 🔴 **NONE — D4.** |
| **NEW** `objects/Call_For_Offers__c/listViews/Offers_Due_Soon` | `Offer_Due_Date__c` between `LAST_N_DAYS:7` and `NEXT_N_DAYS:30`, `Status__c = 'Open'`; columns `Opportunity__c`, `Offer_Due_Date__c`, `Source_Broker_Name__c`, `Status__c`. URL-reachable only under D4. |
| `objects/Call_For_Offers__c` page layout | Required (new object). |
| `lwc/callForOffersList`, `lwc/callForOffersPanel` | **Additive.** Both are imperative-Apex-backed (`CallForOffersController.getUpcoming` / `.getForOpportunity`), not LDS — if the DTO member names hold, the change is a `status` column, a `sourceBroker` value and `callForOffersId`. Also update the three **comment** lines naming the retired field (`callForOffersList.js:16`, `callForOffersPanel.js:233`, `callForOffersPanel.html:62`). Update Jest; keep `@sa11y/jest`. Jest is local-only and never deploys. |
| `objects/Opportunity/fields/Listing_Status__c` | Amend the XML **comment** naming `Offer_Due_Date__c` (F6). Not a dependency. |

## §2.8 — `.claude/rules/salesforce-global-rule.md`

```
1. CustomObject    Call_For_Offers__c  (incl. the restricted Status__c value set)
2. CustomField     Opportunity__c (MD) → Offer_Due_Date__c → Source_Broker_Name__c
                   → Source_Broker_Email__c → Status__c → Received_Date__c
                   → Offer_Alert_Due_Date__c → Offer_Alert_Last_Interval__c
                   → Opportunity.Next_Offer_Due_Date__c (ROLL-UP — AFTER the MD field exists)
3. CompactLayout   Opportunity.Deal_Highlights (amend)
4. ListView        Call_For_Offers__c.Offers_Due_Soon (new); Opportunity.Offers_Due_Soon (amend)
5. Layout          Call_For_Offers__c (new); Opportunity-Opportunity Layout (amend)
6. FlexiPage       ONLY if OQ-12 reopens D4                              [GATE FP-1]
7. PermissionSet   the five sets                                         [GATE PS-1]
```
🔴 Record `mcp=unavailable` / `mcp_tools=none` **after a real attempt** for every type — `.mcp.json`
configures only the `salesforce` server and subagents have no MCP tools at all — then fall back to
the per-type skill, which the rule explicitly permits. Print the gate status lines.
🔴 The **restricted** `Status__c` picklist must exist in the org **before** any Apex that writes it.

## §2.9 — 🔴 GATE PS-1 (blocking)

**A `PermissionSet` deploy REPLACES its entire `<fieldPermissions>` set** — already a live outage
here, and concurrent sessions have been measured turning a shared set into the union of two
features. **Per set, immediately before deploying:** retrieve → `git diff` the retrieval against
`HEAD` → **report drift and STOP** → apply edits to the **retrieved** copy → after deploy, read back
and confirm the delta (*"Succeeded" is not proof* — "689/689 deployed, 0 errors" has been measured
on a deploy that rolled everything back).

| Set | Remove (Opportunity) | Add (`Call_For_Offers__c`) |
|---|---|---|
| `Broker_Protection_Access` | **none** (carries only `Lead.Offer_Due_Date__c`, KEPT) | 🔴 **NONE — D6.** Stamp service reads/writes in `SYSTEM_MODE`; the human triage path is walked by an Acquisitions persona on `DPEG_Acquisition_View`. |
| `DPEG_Acquisition_Edit` | all 4 | object CRUD + all 8 fields **editable** |
| `DPEG_Acquisition_View` | all 4 | object read + all 8 read-only |
| `DPEG_Opportunity_View` | all 4 | object read + all 8 read-only |
| `DPEG_Admin_Access` | 3 present; ⚠ **`Offer_Due_Date__c` absent in the repo copy — RESOLVE under PS-1**, do not assume the file is complete | object CRUD + all 8 **editable** |

Plus `Next_Offer_Due_Date__c` (read-only everywhere — it is a roll-up) on the four non-Broker sets.

🔴 **`DPEG_Admin_Access` is load-bearing FOR THE DEPLOY.** Its own inline comment records that
`RunLocalTests` runs as the deploying administrator, who holds this set and nothing else — so
**every** new `Call_For_Offers__c` field a test fixture sets must be granted here, or the whole test
run fails with *"fields being inaccessible on Sobject Call_For_Offers__c"*, pointing at the new test
rather than at this file.
⚠ `DPEG_Apex_Access` — `CallForOffersController` keeps its name ⇒ no edit. **Confirm, do not assume.**

---

# 🔵 ADMIN WORK

### ITEM 1 — 🔴 **NONE.** D2. Item 1 is developer-only.

### ITEM 2 — Admin
- **New object** `Call_For_Offers__c`, Name = Auto Number `CFO-{0000}` (D5).
- **8 custom fields:** `Opportunity__c` (Master-Detail, required, `writeRequiresMasterRead=true`,
  `reparentableMasterDetail=false`); `Offer_Due_Date__c` (Date); `Source_Broker_Name__c` (Text 120);
  `Source_Broker_Email__c` (Email 80); `Status__c` (Picklist, **restricted**,
  `Open`/`Submitted`/`Closed`, default `Open`); `Received_Date__c` (Date);
  `Offer_Alert_Due_Date__c` (Date); `Offer_Alert_Last_Interval__c` (Number 2,0).
- **1 roll-up on Opportunity:** `Next_Offer_Due_Date__c` = `MIN(Call_For_Offers__c.Offer_Due_Date__c)`
  filtered `Status__c = 'Open'` (after the MD field exists). ⚠ Verify Opportunity's roll-up count
  against the 25-per-object limit first.
- **Page layout** for `Call_For_Offers__c`; **list view** `Call_For_Offers__c.Offers_Due_Soon`.
- **Repoint three Opportunity surfaces** onto the roll-up (§2.7).
- **5 permission sets** per §2.9. **[GATE PS-1]**
- **Retire** the four Opportunity fields — **last**, after the Apex repoint and the backfill.
  🔴 Grep `reports/**` and query the org for report / dashboard / list view / flow / formula
  references first — **reports do not block deletion and fail silently.**
- 🔴 **DO NOT TOUCH:** `Lead.Offer_Due_Date__c`, both Lead surfaces,
  `Opportunity.Listing_Broker_Name__c` / `Listing_Broker_Email__c` / `Sale_Process__c`,
  `Opportunity_Record_Page` (unless OQ-12), the app file, `tabVisibilities`.
- 🔴 **DO NOT ADD** `Is_Best_And_Final__c` — Gate-1 Q3, *"leave it"*, a decided gap.

---

# 🟢 DEVELOPMENT WORK

### ITEM 1 — ⚫ technical-architect *(the whole of Item 1)*
Rename to `ensureOnClaimStageEntry` + the 4-stage `CLAIM_STAGES`; the 13-site move with five header
**rewrites**; the set-membership change on **both** the current and prior tests; the 251-record bulk
fixture moved to a claim-stage entry; confirm OQ-2 by test. Preserve every listed invariant.

### ITEM 2 — ⚫ technical-architect
New `CallForOffersSelector` (three `SYSTEM_MODE` decisions argued separately + two USER_MODE UI
reads); `CallForOffersService.evaluateAll` repointed with parent traversals;
`CallForOffersStampService` create-or-update with the new key and re-pinned budget;
`CallForOffersAlertBatch` + locator moved to the child; `CallForOffersController` DTO;
`ExtractAddressQueueable.routeCallForOffers`; **`LeadConvertService` child creation with the
re-derived `2 SOQL / ≤6 DML` pin**; `CallForOffersBackfillBatch` (one-off); LWC + Jest additive.
🔴 **DO NOT TOUCH:** `CallForOffersService.evaluate` / `shouldFire` / the three constants;
`NdaExpiryService`.

---

# 🔗 BUILD ORDER

```
ITEM 1  — developer-only, ONE deploy. (No admin wave — D2.)
  1-A  Rename to ensureOnClaimStageEntry + the 4-stage CLAIM_STAGES; the 13-site move;
       5 header REWRITES (false premises, not stale strings)
  1-B  Confirm OQ-2 with a real Database.convertLead assertion
  1-C  Tests: 251-record bulk fixture MOVED to a claim-stage entry; multi-stage no-op assertions
  1-D  Unit testing → Code review → Deploy + Docs
  1-E  Post-deploy: watch week-1 Graph volume. Sweep already scheduled (OQ-10).

ITEM 2  — FOUR waves. The additive pattern IS the order.
  W0   Resolve OQ-12 (the D4 / no-UI-path tension)                         ⟵ BLOCKING
  W1   ADD      object + 8 fields + roll-up + layouts + list view + permission sets  [PS-1]
                Strictly additive; nothing reads them; org behaviour unchanged
  W2   BACKFILL CallForOffersBackfillBatch, alert schedule unscheduled (confirm).
                Run V1–V4. Size the roll-up recalculation first.
  W3   REPOINT  selector + service + stamp service + alert batch + controller + queueable
                + LeadConvertService + list view + compact layout + page layout + LWC + Jest
                🔴 THE ORG NOW HOLDS TWO SOURCES OF TRUTH FOR EVERY DEADLINE. Only
                   CallForOffersStampService and LeadConvertService write them, so there is no
                   dual-writer race — but ONLY IF W3 LANDS AS ONE DEPLOY. DO NOT SPLIT IT.
  W4   RETIRE   the four Opportunity fields, after a repo grep AND an org query for report /
                dashboard / list view / flow / formula references

POST-DEPLOY GATE G-CFO 🔴  SCHEDULE CallForOffersAlertSchedule. It has NEVER been scheduled
  (§0.4), so the reminder feature is currently INERT. Expect the first run to alert every open
  deal inside the 7-day ladder in one burst.
```

---

# ❓ REMAINING OPEN QUESTION

| # | Question |
|---|---|
| **OQ-12** 🔴 **BLOCKING** | **§0.3 — under D3-REVISED there is no UI path to create or edit a `Call_For_Offers__c`.** FSD §25.1 requires the Due Date to be editable; RESIDUAL-11 requires a human to close a campaign; a manually created deal can never get one; a wrong LLM-extracted date is uncorrectable. **Recommendation: reopen D4 for the RELATED LIST ONLY** (one FlexiPage edit, GATE FP-1, no tab and no other hub file). If D4 stands, say so explicitly and accept that FSD §25.1's "editable" is unmet, that `Status__c` is decorative, and that RESIDUAL-11 becomes "the first campaign's record is permanent". |

*(OQ-1, 2, 4, 5, 6, 7, 8, 9, 10, 11 all closed. OQ-3 → RESIDUAL-6. OQ-8 survives as an assigned
measurement inside the Item 2 prompt.)*

---

# ⚠ ACCEPTED RESIDUALS

### Item 1

**RESIDUAL-1 — Dead deals get permanent folder trees.** *Bounded* by the `Property__c`-keyed guard:
one tree per distinct property that ever reached a claim stage; a re-marketed property reuses it.

**RESIDUAL-2 🔴 — NO BACKFILL. Every deal already past all four claim stages will NEVER get a folder
tree, and nothing anywhere says so.** Under D8 the population shrinks to deals already at `Closed
Won` on deploy day. Two independent mechanisms exclude them, each sufficient alone: the trigger keys
on stage **ENTRY**, so no later save claims; and the sweeper's locator is
`SharePoint_Folder_Status__c IN ('Pending','Failed')`, which only `DealFolderService` writes, so an
unclaimed Property has a **NULL** status and is not in the queue. No error, no counter, no `Skipped`
stamp. *Remedy if ever wanted:* a one-off anonymous-Apex `Pending` stamp in bounded batches; the
(live) sweep drains it at 10 properties × 7 callouts per transaction. Run only after
`SharePoint_Config__c` is populated.

**RESIDUAL-3 — ✅ CLOSED by D8.** `advanceTo`'s unvalidated `About to Close` target is now itself a
claim stage. ⚠ Residual sliver: a record **created directly** at `LOI` or `Under Contract (PSA)`
(a data load) claims nothing at insert, but claims on its next forward move and reaches `Closed Won`
either way — **deferred, never lost.**

**RESIDUAL-4 — the LOI-rejection path runs as a read-only approver.** `LOI → Underwriting` is a
claim-stage entry inside the approval transaction; the Queueable therefore runs as a principal
unlikely to hold `SharePoint_Integration_Access`. Callouts refused → `Failed` → recovered by the
(live) sweep. **Safe, and now one of the two likeliest remaining credential refusals** — which is
why `HINT_CREDENTIAL` must name it.

**RESIDUAL-5 🔴 — `OneDrive_Folder_URL__c` stays permanently blank on four live surfaces.** D2
declined the fix. Recorded rather than dropped because it is exactly the kind of thing rediscovered
as a bug later. Reopening it is a one-field, four-repoint change.

**RESIDUAL-6 — DPEG's Microsoft Graph throttle allocation is unknown.** Bursts bounded at
70/transaction; degrades into deferral; 429s land in `SharePoint_Folder_Error__c` and are retried.
A monitoring item.

**RESIDUAL-7 — a deal with a null `Property__c` still gets no folder** (inherited R1). ⚠ The
recovery query in the header must be updated — `WHERE StageName = 'Closed Won'` no longer describes
the population.

**RESIDUAL-8 — folder existence is no longer a signal.** "A folder exists ⇒ the deal closed" is now
false and may be embedded in someone's habits.

### Item 2

**RESIDUAL-9 — `Call_For_Offers__c` sharing is permanently a function of Opportunity's.** MD is
correct *because* Opportunity OWD is `ReadWrite`. If it is ever narrowed to Private, the
idempotency-guard read returns zero rows and the stamp service becomes a **duplicate-maker**
(`ARCHITECTURE.md` §2's red note), and the marker write silently refuses. Mitigated by the `missing`
population, the diff counter and a non-owner `runAs` test; **mitigated, not removed.**

**RESIDUAL-10 🔴 — the simple relationship does NOT satisfy FSD §25.1 row 1.** *"Related Deal(s) —
one or more linked Opportunities — supports the portfolio case"* requires a junction. A broker's
single call for offers across a 3-property portfolio produces **three records** with duplicated due
date, broker and status and no signal they came from one campaign. **Amend the FSD.**

**RESIDUAL-11 — "one OPEN CFO per deal" means a new campaign overwrites the old unless a human
closes it first.** ⚠ **Under D4 as written, no human can** — see §0.3 / OQ-12. If D4 stands, this
residual hardens into "the first campaign's record is permanent."

**RESIDUAL-12 — the idempotency check is not atomic across transactions.** Two concurrent emails
could both read "no open CFO" and both insert. The existing service has the identical exposure on
the Opportunity field. A composite key cannot be an External Id, so `upsert` is unavailable.

**RESIDUAL-13 — the roll-up changes the list view's meaning** from "this deal's deadline" to "this
deal's soonest **OPEN** deadline". A deal whose only campaign is `Submitted`/`Closed` drops out of
`Offers_Due_Soon`. Arguably an improvement; **it is still a behaviour change.**

**RESIDUAL-14 — a `Call_For_Offers__c` row is reachable only through the two LWCs and by direct
URL (D4).** The new list view has no navigation entry point. ⚠ Escalated to **OQ-12** because under
D3-REVISED this is no longer only a visibility question.

**RESIDUAL-15 — the reminder ladder diverges from FSD §25.2.2.** `{7,3,1,0}` stays hardcoded rather
than a configurable 2-day reminder. **Amend the FSD.** Also preserved deliberately: the batch alerts
at 7 days while the UI paints red only from 3.

**RESIDUAL-16 — `dealArrivedDate` survives the move.** A migration affordance with its own separate
retirement condition; out of scope and not to be folded in.

**RESIDUAL-17 (new) — a call-for-offers record created at conversion has a null `Received_Date__c`.**
No email arrival is known at conversion. `dealArrivedDate` already answers "when did the deal
arrive", and `CallForOffersService` §4 forbids coalescing the two. So the "Received" column is blank
for every conversion-created record until a call-for-offers email matches — which is the same
population shape the field has today.

---

# 🔀 COMPLEXITY TIERS

| Item | Admin | Dev |
|---|---|---|
| **Item 1** | 🔴 **NONE — D2.** | ⚫ **`salesforce-technical-architect`** |
| **Item 2** | 🟤 **`salesforce-solution-architect`** | ⚫ **`salesforce-technical-architect`** *(restored — the migration and the architect-tier decisions are back)* |

**Item 1 → technical-architect:** it changes the volume profile of a **direct Microsoft Graph
integration** (a standing §3.4 exception to `ARCHITECTURE.md` §3.1); the never-throw contract rests
on measured uncatchable-`LimitException` behaviour and a deliberate guard asymmetry the header
forbids harmonising; **five class-header blocks contain arguments that become FALSE**; and under D8
the contract is exercised at up to four entry points on essentially every deal, including once
inside an approval transaction as a read-only approver.

**Item 2 admin → solution-architect:** the MD-vs-lookup **sharing** decision propagates into the
Apex sharing keyword on three automation paths; a **roll-up summary is load-bearing** for three
surfaces (and its rev-2 prohibition has just been lifted, which is exactly the kind of reversal that
needs an architect's note rather than an admin's edit); and a **5-permission-set reconciliation**
under replace semantics.

**Item 2 dev → technical-architect (RESTORED from `salesforce-developer`):** the **one-off data
migration** is back; **three separate `SYSTEM_MODE`/sharing decisions** must be argued at a new
object; `LeadConvertService`'s **pinned governor contract must be re-derived and re-pinned**; and
the `CallForOffersStampService` budget must be re-pinned. That is `CLAUDE.md`'s *"complex
service-layer design"*.

---

# 📝 PROMPTS FOR SPECIALIST AGENTS

> No `salesforce-admin` prompt exists for Item 1 (D2). **Do not dispatch Item 2 until OQ-12 is
> answered.**

---

### ⚫ PROMPT FOR `salesforce-technical-architect` — Item 1

```
Read ARCHITECTURE.md and all of .claude/rules/ first. Then read these headers IN FULL before
writing anything — each carries an argument you must preserve or REWRITE, not restate:
DealFolderService, DealFolderSweepBatch, OpportunityReviewTriggerHandler, StageAdvanceService,
PropertySelector.

TASK: move the SharePoint deal-folder claim from entry to 'Closed Won' to entry to any CLAIM
STAGE. Code + tests only — do not deploy.

DECIDED, DO NOT REOPEN:
  - CLAIM_STAGES = { 'Under Review', 'Underwriting', 'About to Close', 'Closed Won' }.
    Four stages, not one. The SharePoint_Folder_ID__c guard makes every claim after the first
    a ZERO-callout, ZERO-DML, ZERO-enqueue no-op, so a normal deal still claims exactly once,
    at Under Review; the other three exist only to catch skip routes.
  - 🔴 DO NOT TOUCH flows/Opportunity_Initiate_Underwriting, No_Backward_Stage_Movement
    CARVE-OUT 2, or StageAdvanceService.advanceTo's contract. The four-stage set exists
    precisely so all three can stay untouched.
  - 🔴 NO BACKFILL. Deals already at Closed Won on deploy day never get a folder. User
    decision — document it, do not solve it.
  - 🔴 NO new Opportunity field and NO repointing of OneDrive_Folder_URL__c (user decision D2).
    Item 1 has ZERO admin work.

1. RENAME
     DealFolderService.ensureOnClosedWon → ensureOnClaimStageEntry
     DealFolderService.CLOSED_WON (String) → @TestVisible private static final Set<String>
       CLAIM_STAGES = new Set<String>{
         'Under Review', 'Underwriting', 'About to Close', 'Closed Won' };
   NOT 'ensureOnUnderReview' and NOT 'ensureOnReviewEntry' — the set runs to Closed Won, which
   is not a review stage, and the repo's stage-in-the-method-name convention cannot express
   four. 'ensureOnClaimStageEntry' uses vocabulary this class already owns (claimFolders,
   "claim a SharePoint deal folder") and points the reader at the constant.
   🔴 The constant's Javadoc must record WHY EACH ENTRY IS THERE:
     'Under Review'   the ordinary route (advance() from 'New', the Begin Review action)
     'Underwriting'   catches the Opportunity_Initiate_Underwriting before-save jump, which
                      can fire from ANY stage and is deliberately not being touched
     'About to Close' catches StageAdvanceService.advanceTo, which validates only that the
                      TARGET is in ALLOWED_EXPLICIT_TARGETS and NEVER checks the current stage
     'Closed Won'     the final backstop, and the Transaction_Complete_Close flow's route
   Without those four sentences a future reader will "tidy" the set back down and silently
   reopen two holes.
   ⚠ ALSO RECORD: 'LOI' and 'Under Contract (PSA)' are deliberately ABSENT because neither is
   reachable except from a stage that already claimed. The one uncovered case is a record
   CREATED DIRECTLY at one of them (a data load); it claims on its next forward move and
   reaches Closed Won either way, so the folder is DEFERRED, never lost.

2. enteringPropertyIds — the entry test becomes
     CLAIM_STAGES.contains(o.StageName)
       && (prior == null || !CLAIM_STAGES.contains(prior.StageName))
   🔴 BOTH halves must use the SET. If the prior test checks a single stage, an ordinary
   'Under Review' → 'Underwriting' move registers as a FRESH entry and costs a needless SOQL on
   every deal in the org. Assert this explicitly in a test.

3. 🔴 REWRITE THE FIVE HEADER BLOCKS WHOSE ARGUMENTS BECOME FALSE. Each block's stated PREMISE
   evaporates; a rename alone leaves the codebase lying to its next reader:
   a. DealFolderService 18-28 "WHY IT HANGS OFF THE OPPORTUNITY TRIGGER" — the argument is that
      NEXT_STAGE maps BOTH 'Under Contract (PSA)' and 'About to Close' to 'Closed Won'. MOOT.
      Surviving reasons: the Flow callout arithmetic (251 x 7 = 1,757 HTTP actions against a
      limit of 100) and Flow's absent HttpCalloutMock seam. Add that a FOUR-stage key is itself
      an argument for Apex over Flow.
   b. DealFolderService:180 — "stage-ENTRY semantics must not drift between two services on one
      trigger". NOW FALSE: this service keys on four stages, PropertyAssetService on one.
      DELETE the claim.
   c. DealFolderService 300-317 (HINT_CREDENTIAL) — it names Transaction_Complete_Close and the
      Transactions persona as the likely cause. 🔴 MEASURED CONSEQUENCE: at 'Under Review' the
      claimer is the human clicking Begin Review — a deal driver on DPEG_Junior_Analyst_PSG,
      which HOLDS SharePoint_Integration_Access — so the dominant failure route DISAPPEARS.
      Rewrite the hint to name the TWO that remain: (i) the LOI_Approval final-rejection field
      update ('LOI' → 'Underwriting'), which runs as a READ-ONLY APPROVER inside the approval
      transaction; and (ii) Transaction_Complete_Close, which survives only as a BACKSTOP claim
      at 'Closed Won' for a deal that somehow reached close with no folder.
   d. DealFolderSweepBatch 5-27 — same dead premise. The sweep is STILL load-bearing (deferred
      chains, dead jobs, transient Graph failures, the two paths above) but for DIFFERENT
      reasons. Re-argue it. ✅ ALSO RECORD: it IS scheduled — CronTrigger shows 'DPEG SharePoint
      Deal Folder Sweep', 0 0 2 * * ?, State WAITING (measured 2026-08-27), so the header's
      warning about an unscheduled deploy is satisfied in this org.
   e. DealFolderService 122-149 (residual R5) — REPLACE with the NO-BACKFILL residual, at the
      same length. 🔴 Re-derive it for FOUR stages: the excluded population shrinks to deals
      ALREADY AT 'Closed Won' on deploy day. Everything earlier in the pipeline still has a
      claim stage ahead of it and WILL claim. State that there is no error, no counter and no
      Skipped stamp to find the population by, and that the remedy if ever wanted is a one-off
      anonymous-Apex Pending stamp — never a code change.

4. STALE-STRING SWEEP: DealFolderService lines 2, 30-33, 110 (the R1 recovery query — "WHERE
   StageName = 'Closed Won'" no longer describes the population), 290-297 (REASON_UNNAMABLE's
   "Re-saving the closed deal will NOT retry it"), 353, 393-414; DealFolderQueueable and
   DealFolderFinalizer headers; PropertySelector:15 + FolderCreationReads.
   🔴 DO NOT TOUCH PropertySelector.AssetCreationReads — it belongs to PropertyAssetService.

5. CROSS-CLASS: OpportunityReviewTriggerHandler:11, :71-82, and 🔴 :19-25 — whose premise is
   that the last two services SHARE a trigger point. They no longer do. The
   opposite-failure-contract fact (PropertyAssetService is allOrNone = true and THROWS on
   purpose; DealFolderService MUST NEVER THROW) is STILL TRUE and STILL MATTERS — keep it,
   re-found it. ⚠ Note they now OVERLAP at 'Closed Won' without being identical, which is a
   subtler relationship than either "same trigger point" or "different trigger points" — say so.
   StageAdvanceService:106-112 — remove DealFolderService from the load-bearing Closed-Won
   pair. LEAVE PropertyAssetService in it; the argument still holds for it.

6. 🔴 NAMED MEASUREMENT — CONFIRM OQ-2 WITH A TEST, DO NOT INHERIT IT. Design established by
   INFERENCE (not measurement) that Database.convertLead lands the Opportunity on 'New':
   Opportunity.StageName has no default on either active record type (ui-api picklist-values
   for Land and Retail both return an empty defaultValue) and 'New' is first in every business
   process. Assert that a real Database.convertLead produces StageName = 'New'.
   🔴 IF IT LANDS ON 'Under Review', STOP AND REPORT: every converted deal would then claim its
   folder INSIDE the Database.convertLead transaction — i.e. inside the already-governor-tight
   Broker Protection pipeline, as the pipeline principal — a different risk and credential
   picture that this design does not cover.

7. TESTS — 🔴 MOVE the 251-record bulk fixture from a Closed Won stage move to a CLAIM-STAGE
   entry. Per .claude/rules/bulk-test-rule.md the 251 mandate applies to the synchronous claim
   path (it is a trigger) and must be MET AT THE NEW STAGE; a fixture renamed but not moved
   passes vacuously. Also add: a deal walked through ALL FOUR claim stages claims EXACTLY ONCE
   and costs ZERO extra callouts and ZERO extra enqueues on entries 2-4 (the duplicate-folder
   falsifier, now the most important test in the class); and the prior-stage set-membership
   assertion from step 2.
   The async path keeps its existing volume shape — 251 properties would demand 1,757 callouts
   and would measure a state the job can never be in.

8. PRESERVE EXACTLY, and say so in the header: the never-throw contract (STRUCTURAL — the
   absence of throwing paths, NOT statement ordering); allOrNone = false; the enqueue's
   Limits.getQueueableJobs() guard AND the deliberate asymmetry that the SOQL and DML carry no
   matching guard; the SharePoint_Folder_ID__c idempotency guard; the applyStatus describe
   guard; MAX_PROPERTIES_PER_TRANSACTION = 10; CALLOUT_TIME_BUDGET_MS = 90000;
   DealFolderSweepBatch.SCOPE. None of these move — they are PER-TRANSACTION budgets and the
   trigger point cannot affect them.

9. RECORD IN THE HEADER as four facts about the STAKES rather than the mechanism:
   (i)   a rollback now blocks a deal at its FIRST forward step, not its last;
   (ii)  a throw would surface through StageAdvanceService.setStage's catch(DmlException),
         which rethrows getDmlMessage(0) VERBATIM into a user's toast on a Begin Review click;
   (iii) the contract is now exercised on essentially every deal at UP TO FOUR entry points, so
         any latent throwing path is a pipeline-wide outage;
   (iv)  🔴 the LOI-rejection path reaches this code INSIDE AN APPROVAL TRANSACTION as a
         read-only approver. OpportunityReviewService's header documents what a throw there
         costs: it rolls back the APPROVAL and shows the approver a platform error on an
         Approve click (the D10 ApprovalAuditService incident shape). Safe today because this
         service never throws — but it raises the cost of ever introducing a throwing path.

Update ARCHITECTURE.md in the same change if any convention it states moves.
```

---

### 🟤 PROMPT FOR `salesforce-solution-architect` — Item 2 (declarative)

```
Read ARCHITECTURE.md and all of .claude/rules/ first.

TASK: create Call_For_Offers__c as the SOLE SYSTEM OF RECORD for call-for-offers deadlines, and
retire FOUR Opportunity fields. Metadata only — do not deploy.

DECIDED, DO NOT REOPEN:
  - RELATIONSHIP: MASTER-DETAIL to Opportunity. The deciding fact is that Opportunity OWD is
    ReadWrite (measured 2026-08-10 via Tooling EntityDefinition; recorded in
    CallForOffersStampService's header). MD makes the child inherit that, so NO new sharing
    artefacts are needed. A lookup would mean a Private OWD, a criteria sharing rule, and a
    public group WHOSE MEMBERSHIP IS NOT DEPLOYABLE — inert until added by hand. MD also makes
    the parent required, which enforces FSD §25.2.1's scope gate structurally, and gives
    cascade delete.
    Settings: required; writeRequiresMasterRead = true (so a persona who can only READ a deal
    can still log a call for offers — the default false demands EDIT on the parent);
    reparentableMasterDetail = false.
  - 🔴 BUILD THE ROLL-UP SUMMARY. An earlier revision of this design PROHIBITED it; that
    prohibition is LIFTED and you should record why in the object description so nobody
    reinstates it. The prohibition existed because Opportunity.Offer_Due_Date__c was going to
    SURVIVE, so a roll-up would have been null for the majority population while the real
    deadline sat in the field beside it. That field now RETIRES, so there is nothing left to
    collide with.
      Opportunity.Next_Offer_Due_Date__c = ROLL-UP SUMMARY
        MIN(Call_For_Offers__c.Offer_Due_Date__c) filtered Status__c = 'Open'
    🔴 IT IS MANDATORY, NOT OPTIONAL, AND THE COMPACT LAYOUT IS WHY. A compact layout cannot
    reference a child field under any circumstance, so without the roll-up the offer deadline
    would silently vanish from Opportunity's Deal_Highlights strip with no replacement
    possible. It also keeps the page layout and the Offers_Due_Soon list view working, so one
    field resolves all three surfaces.
    ⚠ VERIFY FIRST: Opportunity's existing roll-up-summary count against the 25-per-object
    limit. Not checkable from source — report it.
  - 🔴 ALL FOUR Opportunity fields retire: Offer_Due_Date__c,
    Call_For_Offers_Received_Date__c, Offer_Alert_Due_Date__c, Offer_Alert_Last_Interval__c.
    Lead.Offer_Due_Date__c is KEPT and must not be touched.
  - 🔴 NO related list, NO custom tab, NO app-nav or tabVisibilities change (user decision D4)
    — UNLESS the coordinator tells you OQ-12 reopened it for a RELATED LIST ONLY, in which case
    ONE FlexiPage edit is in scope and GATE FP-1 applies.

BUILD — CustomObject Call_For_Offers__c, Name = Auto Number CFO-{0000}
  EIGHT fields:
    Opportunity__c               Master-Detail(Opportunity), per the settings above
    Offer_Due_Date__c            Date
    Source_Broker_Name__c        Text(120)  — mirrors Opportunity.Listing_Broker_Name__c
    Source_Broker_Email__c       Email(80)  — mirrors Opportunity.Listing_Broker_Email__c
    Status__c                    Picklist, RESTRICTED, Open / Submitted / Closed, default Open
    Received_Date__c             Date
    Offer_Alert_Due_Date__c      Date       — the marker SNAPSHOT; keep this exact name
    Offer_Alert_Last_Interval__c Number(2,0) — the marker RUNG; keep this exact name
  🔴 THE TWO MARKER FIELDS ARE THE TWO-FIELD RE-ARMING PATTERN. Read NdaExpiryService's header
     §3 before writing their descriptions. The SNAPSHOT field is what re-arms the whole ladder
     when a broker moves a date; WITHOUT IT a moved deadline is NEVER REMINDED ABOUT AGAIN, on
     exactly the deals someone cared enough about to change. Say that in the descriptions.
     ⚠ They live HERE, on the child, and not on Opportunity, BECAUSE the deadline lives here.
     A marker must live with the value it tracks — separating them was found to be incoherent
     in an earlier revision of this design. Record that sentence.
  🔴 Status__c is RESTRICTED. This repo has MEASURED FOUR TIMES that restricted picklists ARE
     enforced by DML, contradicting ~20 places in its own docs. An off-list value is
     INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST at runtime. The picklist must exist in the org
     BEFORE the Apex that writes it.
  Page layout for Call_For_Offers__c.
  List view Call_For_Offers__c.Offers_Due_Soon — Offer_Due_Date__c between LAST_N_DAYS:7 and
  NEXT_N_DAYS:30, Status__c = 'Open'; columns Opportunity__c, Offer_Due_Date__c,
  Source_Broker_Name__c, Status__c.

REPOINT three Opportunity surfaces onto Next_Offer_Due_Date__c:
  objects/Opportunity/listViews/Offers_Due_Soon — BOTH date filters AND the Offer_Due_Date__c
    COLUMN. The Listing_Broker_Name__c / Listing_Broker_Email__c columns and the STAGE_NAME
    filter are unaffected (those fields are not retiring).
    🔴 PRESERVE AND AMEND the file's large explanatory XML comment — do not delete it. The
    window rationale (a rear-view week; 30 days forward because 14 is inside an approval round)
    is still valid, and a note about the new "soonest OPEN deadline" semantics belongs in it.
    ⚠ The comment must stay INSIDE the root element: a comment above the root breaks `sf` at
    conversion with a misleading "unable to find matching parent xml file".
  objects/Opportunity/compactLayouts/Deal_Highlights — Offer_Due_Date__c →
    Next_Offer_Due_Date__c.
  layouts/Opportunity-Opportunity Layout (line ~133) — same swap, and change <behavior> from
    Edit to Readonly: a roll-up summary cannot be edited.
  objects/Opportunity/fields/Listing_Status__c — amend the XML COMMENT that names
    Offer_Due_Date__c. It is a comment, not a formula, so it is not a dependency — but leaving
    it names a field that no longer exists.

🔴 DO NOT TOUCH: Lead.Offer_Due_Date__c, objects/Lead/listViews/Offers_Due_Soon,
   objects/Lead/compactLayouts/Lead_Highlights, Opportunity.Listing_Broker_Name__c,
   Listing_Broker_Email__c, Sale_Process__c, the Acquisitions app file, tabVisibilities.
🔴 DO NOT ADD Is_Best_And_Final__c — Gate-1 Q3, "leave it", a decided gap.

🔴 GATE PS-1 — MANDATORY, BLOCKING, PER SET. A PermissionSet deploy REPLACES its entire
  <fieldPermissions> set; this has already caused a live outage here, and concurrent sessions
  have been measured turning a shared set into the union of two features. For EACH set:
  retrieve from the org → diff the retrieval against HEAD → REPORT ANY DRIFT AND STOP rather
  than overwriting → apply edits to the RETRIEVED copy → after deploy read back and confirm the
  field count moved by exactly the expected delta ("Succeeded" is not proof; "689/689 deployed,
  0 errors" has been measured on a deploy that rolled everything back).
    Broker_Protection_Access  🔴 NO CHANGE AT ALL. It carries only Lead.Offer_Due_Date__c,
                              which is KEPT, and needs no grant on the new object: the stamp
                              service reads and writes in SYSTEM_MODE, and the human triage path
                              is walked by an Acquisitions persona on DPEG_Acquisition_View.
    DPEG_Acquisition_Edit     remove all 4 Opportunity fields; add object CRUD + all 8 new
                              fields EDITABLE + Next_Offer_Due_Date__c read-only
    DPEG_Acquisition_View     same removal; object read + all 8 read-only + the roll-up
    DPEG_Opportunity_View     same removal; object read + all 8 read-only + the roll-up
    DPEG_Admin_Access         same removal; object CRUD + all 8 EDITABLE + the roll-up
                              🔴 LOAD-BEARING FOR THE DEPLOY: its own inline comment records
                              that RunLocalTests runs as the deploying admin, who holds this set
                              and nothing else — so EVERY new Call_For_Offers__c field a test
                              fixture sets must be granted here, or the whole test run fails
                              with "fields being inaccessible on Sobject Call_For_Offers__c",
                              pointing at the new test rather than here.
                              ⚠ RESOLVE, do not merely report: Opportunity.Offer_Due_Date__c
                              appears ABSENT from the repo copy of this set while the other
                              three are present. If the ORG has the grant and the repo does not,
                              a naive deploy would remove something else. Diff before editing.

RETIREMENT ORDER: add → backfill (developer's wave) → repoint → retire. The four field
deletions are LAST, and only after a repo grep AND an org query for any report, dashboard, list
view, flow or formula still referencing them. Reports do NOT block field deletion and fail
silently.

Per .claude/rules/salesforce-global-rule.md: one metadata type at a time, in the order
CustomObject → CustomField (the roll-up LAST, after the MD field exists) → CompactLayout →
ListView → Layout → PermissionSet. Load the matching skill for each. Attempt
salesforce-api-context MCP for EVERY type; .mcp.json configures only the `salesforce` server, so
record mcp=unavailable / mcp_tools=none after a REAL attempt and fall back to the per-type
skill. Print the required gate status lines.

Update ARCHITECTURE.md in the same change with the new object and its sharing posture.
```

---

### ⚫ PROMPT FOR `salesforce-technical-architect` — Item 2 (Apex + LWC)

```
Read ARCHITECTURE.md and all of .claude/rules/ first, then read these headers IN FULL:
CallForOffersService, CallForOffersStampService, CallForOffersAlertBatch,
CallForOffersController, OpportunitySelector (the MODE section), ExtractAddressQueueable
(routeCallForOffers), LeadConvertService (the "BULK SHAPE IS A CONTRACT" block), NdaExpiryService
(§3, the two-field marker).

TASK: make Call_For_Offers__c the SOLE SYSTEM OF RECORD for call-for-offers deadlines, and
retire four Opportunity fields. Code + tests only — do not deploy.

🔴 THE ARCHITECTURE, SETTLED — DO NOT RE-DERIVE IT:
  Call_For_Offers__c holds the deadline, the campaign facts AND the alert marker. Opportunity
  holds none of them. LeadConvertService creates a child at conversion, so EVERY deadline has a
  child — and that is not a convenience, it is WHAT MAKES THE MARKER COHERENT. An earlier
  revision kept the deadline on the parent and put the marker on the child; that was shown to be
  incoherent (a deal with no child had no marker, so the batch could only never alert it or
  alert it every day forever). If child creation at conversion is ever dropped or made
  conditional, that failure returns silently. STATE THIS IN CallForOffersService's HEADER, not
  only in LeadConvertService's.

🔴 DO NOT TOUCH — any diff here is a design error:
  CallForOffersService.evaluate / shouldFire / ALERT_INTERVALS / CRITICAL_DAYS /
  APPROACHING_DAYS; NdaExpiryService.
  CallForOffersServiceTest.everyRungOfTheLadderMapsToExactlyOneBand must stay green with ZERO
  edits — it is the coupling between the badge and the bell.
  DO NOT "fix" the top-rung divergence (batch alerts at 7 days; UI paints red from 3).
  DO NOT retire dealArrivedDate. NO Custom Metadata for the ladder.

1. NEW CallForOffersSelector — ALL SOQL for the new object (.claude/rules/apex-layering-rule.md:
   all SOQL lives in a selector, no exceptions). 🔴 ARGUE MODE AND SHARING AS TWO SEPARATE
   QUESTIONS, AT EACH METHOD'S OWN DECLARATION. DO NOT reuse the Opportunity-era justification —
   all three of these are NEW decisions at a NEW object.
   a. queryAlerts()  (the batch locator)                        SYSTEM_MODE
   b. selectOpenByOpportunityIds()  (the idempotency read)      SYSTEM_MODE
   c. selectOpen() / selectById()   (the two UI reads)          USER_MODE
   MODE for (a) and (b): every field on Call_For_Offers__c is new Metadata-API-deployed
   metadata arriving with NO FLS for ANY profile including the deploying administrator, so
   USER_MODE would throw on day one for the very admin who deployed it — and no principal asks
   for either read.
   SHARING for (a) and (b): `with sharing` (the class keyword) is SUFFICIENT, and it is
   sufficient BECAUSE of the Master-Detail decision — the child inherits Opportunity's sharing
   and Opportunity OWD is ReadWrite (measured 2026-08-10). NO `without sharing` inner class is
   needed or justified.
   🔴 (b) IS AN IDEMPOTENCY-GUARD READ, which ARCHITECTURE.md §2 singles out in red: a
   sharing-filtered guard read "does not disable the feature, it INVERTS it into a
   duplicate-maker". Under-reading mints a SECOND open Call_For_Offers__c for a deal that
   already has one. Write that contingency into the header.
   ⚠ (a) MUST TRAVERSE FOR IsClosed. Today the locator filters IsClosed = FALSE on Opportunity;
   on the child it becomes Opportunity__r.IsClosed = FALSE. Traversal in a QueryLocator WHERE is
   supported and SYSTEM_MODE lifts CRUD/FLS on both objects — but it is a NEW cross-object
   dependency, so say so. Add Status__c = 'Open'.
   ⚠ MOVE AND REWORD OpportunitySelectorTest
   .queryCallForOffersAlerts_doesNotSelectTheReceivedDate — it pins a deliberate omission that
   now lives on another object. Do NOT delete it.
   (c) stays USER_MODE — a human asked for it, and CallForOffersController's header records that
   "simplifying" it to SYSTEM_MODE would make both catch blocks UNTESTABLE, since System.runAs a
   bare user is exactly how they are covered today.

2. CallForOffersService.evaluateAll — now iterates Call_For_Offers__c rows. 🔴 IT MUST TRAVERSE
   TO THE PARENT FOR THREE DTO MEMBERS: propertyName (Opportunity__r.Name — deliberately NOT
   Property__r.Name; §4 of that header explains why) and dealArrivedDate
   (Opportunity__r.Broker_First_Seen__c falling back to Opportunity__r.CreatedDate).
   🔴 UNDER USER_MODE THAT TRAVERSAL ADDS AN OBJECT-LEVEL GATE ON Opportunity PLUS AN FLS GATE
   ON Broker_First_Seen__c, AND USER_MODE THROWS RATHER THAN DEGRADES — a missing grant takes
   down the WHOLE TABLE for that persona, not one column. This is the sibling of the
   Property__r.Name trap §4 already documents. Verify the grant per persona and PIN IT WITH A
   TEST. The permission sets must land WITH the object, never after.
   DTO gains callForOffersId and status.

3. CallForOffersStampService — create-or-update a Call_For_Offers__c instead of stamping the
   Opportunity.
   🔴 IDEMPOTENCY KEY = Opportunity__c + Status__c = 'Open' (at most ONE open call for offers
   per deal). Update the open one; create only when none exists.
   Rejected alternatives, recorded so you do not re-derive them: keying on the DUE DATE makes a
   broker's extension create a SECOND record — exactly the FSD behaviour that must not happen;
   keying on the inbound Message-Id does the same AND is redundant, because the RFC Message-Id
   duplicate guard already runs upstream in ExtractAddressQueueable and returns BEFORE the
   callout, so a platform redelivery never reaches this class at all.
   🔴 BECAUSE LeadConvertService CREATES THE FIRST CHILD, THIS SERVICE'S FIRST ACTION ON A
   CONVERTED DEAL IS ALMOST ALWAYS AN UPDATE, NOT AN INSERT. That is the path to test, and it is
   what makes "if the broker moves the date, the reminder recalculates automatically from the
   new date" TRUE: the update moves Offer_Due_Date__c and the snapshot comparison in shouldFire
   re-arms the ladder BY ITSELF. DO NOT add a marker reset anywhere — CallForOffersService §3
   explains at length why the re-arm must fall out of the comparison.
   PRESERVE VERBATIM: the FSD §25.2.1 scope gate (structural — the MD parent is required; DO NOT
   add a Lead branch); mergeByRecord's de-duplication (a duplicate Id in one update throws
   DUPLICATE_VALUE for the WHOLE statement and allOrNone = false does NOT rescue it); all FOUR
   StampResult populations INCLUDING `missing`, the only channel that can see a sharing-filtered
   read; allOrNone = false; per-field last-wins / ignore-null / no-change-skip; all three test
   seams; the describe-guard pattern, moved from Sale_Process__c onto the RESTRICTED Status__c.
   🔴 RE-PIN THE GOVERNOR SHAPE DELIBERATELY: from "1 SOQL / ≤1 DML" to ≤2 SOQL / ≤2 DML —
   STILL CONSTANT IN THE NUMBER OF MATCHED DEALS, which is the property that matters. Update
   ExtractAddressQueueableTest.callForOffers_matched_governorBudget... to the new numbers on
   purpose; do not loosen the assertion.

4. CallForOffersAlertBatch — locator and marker stamp move to Call_For_Offers__c. SCOPE = 200 is
   UNCHANGED (its derivation is a measured CPU cost of 6.0 ms + 0.22 ms x |recipients| per send,
   unrelated to which object is read). Keep send-then-stamp ordering and its argument; keep ONE
   asOf per chunk; keep SYSTEM_MODE + allOrNone = false and the per-row SaveResult logging.
   🔴 ADD a read/write diff counter — assert attempted == succeeded + logged so a wholesale
   sharing refusal is a COUNTABLE outcome rather than a silent zero. This is the concrete lesson
   of the 2026-08-25 incident (a SYSTEM_MODE write that still enforced sharing, swallowed by
   allOrNone = false, which worked only when the principal owned the record — which is what
   every test does).
   ⚠ The notification body reads deal.Name; it now reads Opportunity__r.Name. Keep every string
   coming from CallForOffersService so the bell, the badge and the table cannot describe one
   deadline three ways.

5. 🔴 LeadConvertService — DELETE line 354 (o.Offer_Due_Date__c = l.Offer_Due_Date__c) and ADD a
   Call_For_Offers__c insert for every converted Lead carrying a non-null Lead.Offer_Due_Date__c.
   THE BUDGET, RE-DERIVED — the pin HOLDS, but you must move it deliberately:
     current contract  2 SOQL / ≤5 DML, CONSTANT
     new contract      2 SOQL / ≤6 DML, CONSTANT   (extend the header enumeration to DML 7)
     SOQL is UNCHANGED at 2 — no new query is needed; the Lead rows are already in hand from
     justConvertedByOpportunity and the Opportunity Ids are its keys.
     DML +1, isEmpty()-guarded, ONE statement for the whole chunk, NEVER one per record.
     251 conversions run as TWO convertLead chunks so this service fires TWICE ⇒ worst case
     12 DML and 4 SOQL in one transaction, against limits of 150 and 100. Comfortable.
     🔴 RAISE LeadConvertServiceTest
     .bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities's per-invocation bound to
     ≤6 ON PURPOSE.
   🔴 THREE CONSTRAINTS ON THE INSERT, EACH FROM A MEASURED INCIDENT IN THIS REPO:
     (i)   allOrNone = false, NEVER all-or-none. DML 2 is all-or-none on purpose because the
           structural fields must land. Follow the PROPERTY INSERT's precedent instead — "one
           bad Property must never roll back the conversion" — because a failed call-for-offers
           row must never cost a lead its conversion.
     (ii)  🔴 EXPLICIT AccessLevel.SYSTEM_MODE, not a bare insert. The class header claims "this
           service's DML runs in SYSTEM MODE", which is true of an ordinary trigger context —
           BUT this repo has measured that EmailsimpleRespectProfiles is ACTIVE, so Apex on an
           inbound-email-service path is NOT in system mode, and one read-only field killed that
           pipeline for six days while the service logged Success. Every field on
           Call_For_Offers__c is new and has NO FLS FOR ANYONE on deploy day, so this is the
           first insert in that class that would actually expose the difference. Stating the
           access level explicitly costs nothing and removes the question.
     (iii) Describe-guard Status__c before writing it, for the same reason every other
           restricted picklist write in that class is guarded.
   FIELD MAPPING AT CONVERSION: Offer_Due_Date__c ← Lead.Offer_Due_Date__c;
   Source_Broker_Name__c / Source_Broker_Email__c ← the Lead's listing-broker fields;
   Status__c = 'Open'; Received_Date__c = NULL (no email arrival is known at conversion — leave
   it null rather than inventing one; dealArrivedDate already answers "when did the deal
   arrive", and CallForOffersService §4 forbids coalescing the two).

6. CallForOffersController — DTO shape only. Keep the class NAME unchanged so DPEG_Apex_Access
   needs no edit (confirm rather than assume). Keep both methods cacheable = true and both catch
   blocks reachable.

7. ExtractAddressQueueable.routeCallForOffers — adjust to the new request/result shape.
   PRESERVE: no envelope-sender fallback (it let a blast platform's mailbox overwrite a live
   deal's real listing broker); the per-email vs per-property asymmetry; the shared
   parseSentDatetime derivation; and 🔴 ALL THREE load-bearing Outcome__c string couplings — the
   Gated_Call_For_Offers list view filters on startsWith 'Not Routed' AND contains 'call for
   offers', and changing either silently empties a deployed view with no compile error and no
   failing test outside this module.

8. NEW CallForOffersBackfillBatch — a ONE-OFF migration, deployed → run once → verified →
   DELETED. Source: every Opportunity with Offer_Due_Date__c != null. SYSTEM_MODE. Idempotent:
   skip any Opportunity that already has a child, so it is freely re-runnable (it WILL be run at
   least twice — dry run, then live). Map all seven values plus a derived Status (Closed if
   IsClosed, else Open).
   🔴 CARRYING Offer_Alert_Due_Date__c AND Offer_Alert_Last_Interval__c IS NOT OPTIONAL AND IS
   THE THING MOST LIKELY TO BE DROPPED. shouldFire treats a marker whose snapshot differs from
   the live due date as BLANK and re-arms the whole ladder — so losing them makes the batch
   RE-ALERT THE ENTIRE BACK CATALOGUE on its next run, firing a burst of notifications at the
   live Acquisition queue. ⚠ They are probably NULL org-wide today because
   CallForOffersAlertSchedule has never been scheduled — carry them anyway, so the code is
   correct rather than accidentally correct. Say that in the class header.
   Include the four verification queries from the design doc §2.6. Document that the run needs
   the alert schedule unscheduled, and that the roll-up recalculation across the migrated parent
   set should be sized before the live run.

9. 🔴 NAMED MEASUREMENT — OQ-8, RUN IT AND REPORT: does an Underwriting_Approval / LOI_Approval
   lock on the parent Opportunity (recordEditability = AdminOnly) block an INSERT of a
   Master-Detail child? This repo has measured that SYSTEM_MODE does not lift an approval lock
   on the parent's own UPDATE, but has NEVER measured it for a child insert. It matters twice
   over here: CallForOffersStampService inserts children onto deals that are precisely the kind
   a broker blasts a call for offers about, and the backfill inserts one onto every deadline-
   bearing deal in the org. If it BLOCKS, allOrNone = false plus the refusals channel handle the
   stamp path — but the BACKFILL would silently skip every locked deal, and that must become a
   V-query rather than a surprise.

10. LWC callForOffersList + callForOffersPanel — ADDITIVE ONLY. Both are imperative-Apex-backed
    (CallForOffersController.getUpcoming / .getForOpportunity), not LDS, so if the DTO member
    names hold the change is a status column, a sourceBroker value and callForOffersId. Also
    update the three COMMENT lines naming the retired field (callForOffersList.js:16,
    callForOffersPanel.js:233, callForOffersPanel.html:62). Update Jest; keep the @sa11y/jest
    matchers. Jest is local-only and never deploys.

11. TESTS — .claude/rules/bulk-test-rule.md's 251-record mandate applies to the batch, the
    backfill and the stamp service. .claude/rules/content-publication-rule.md does NOT apply —
    no ContentVersion / ContentNote / ContentDocument anywhere in this work.
    TestDataFactory gains createCallForOffers.
    🔴 ADD a sharing test that runs System.runAs a principal who does NOT own the parent deal.
    🔴 ADD a duplicate-prevention test: two stamps for one deal produce ONE open child, not two.
    🔴 ADD the conversion test: a converted Lead with a due date produces exactly one
    Call_For_Offers__c, and the second call-for-offers email UPDATES it rather than inserting.

Update ARCHITECTURE.md in the same change if any convention it states moves.
```

---

# 🚦 POST-DEPLOY GATES

| Gate | Action |
|---|---|
| **G-CFO** 🔴 | **SCHEDULE `CallForOffersAlertSchedule`.** It has NEVER been scheduled in `usman-dpeg` — it does not appear in `CronTrigger` at all — so the Call for Offers reminder **has never fired**. A quiet `Acquisition` queue is not evidence the ladder works. ⚠ Expect the first run to alert every open deal inside the 7-day ladder in one burst (the marker fields are almost certainly null org-wide). Correct behaviour; plan for it. |
| **G-SWEEP** ✅ | Already satisfied — `DPEG SharePoint Deal Folder Sweep` is scheduled (`0 0 2 * * ?`, `WAITING`). No action. |
| **G-QUEUE** | Confirm the `Acquisition` queue's MEMBERSHIP is the intended alerting population. Queue membership is not deployable metadata and no test can see it. (Pre-existing gate G2; still open.) |
| **FP-1** | Fires **only** if OQ-12 reopens D4 for the related list. Retrieve + diff `Opportunity_Record_Page` against `HEAD` seconds before deploying; check `SetupAuditTrail` for saves newer than the retrieve. A FlexiPage deploy replaces the org copy and there is **no version history**. |

---

# 📊 TRACEABILITY

| FSD reference | Status |
|---|---|
| §25 "a lightweight child record on the Opportunity" | ✅ satisfied |
| §25.1 Related Deal / Due Date / Source Broker / Status | ✅ satisfied (Source Broker as Name + Email, matching the existing extracted shape) |
| §25.1 row 1 "one or more linked Opportunities — supports the portfolio case" | ❌ **NOT satisfied — RESIDUAL-10.** Simple relationship chosen. **Amend the FSD.** |
| §25.1 Due Date **"editable"** | ⚠ **BLOCKED ON OQ-12.** Satisfied only if D4 is reopened for the related list; otherwise **not satisfied** — no navigable surface exists on which to edit it. |
| §25.2.1 scope gate (record only when a matching Opportunity exists) | ✅ satisfied **structurally** by the required MD parent |
| §25.2.1 "if the broker moves the date, the reminder recalculates from the new date" | ✅ satisfied — the stamp service updates the open child, and the two-field marker re-arms the ladder by comparison |
| §25.2.2 single configurable 2-day reminder | ❌ **NOT satisfied — RESIDUAL-15.** Ladder stays `{7,3,1,0}`, hardcoded. **Amend the FSD.** |
| "Salesforce holds the link" (deal folder) | ❌ **NOT satisfied on the deal record — RESIDUAL-5.** D2 declined; the link lives on `Property__c` only, and four Opportunity surfaces show a permanently blank field. |
| Deal folder created at the start of diligence rather than at close | ✅ satisfied for new deals — ⚠ **RESIDUAL-2**: never for deals already at `Closed Won`. |
