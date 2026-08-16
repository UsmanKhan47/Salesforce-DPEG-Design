# FSD Gap Closure — Acquisitions, Tranche 1

**Date:** 2026-08-16
**Author:** Documentation Agent
**Status:** Code complete on `feature/acquisitions-fsd-tranche-1`. Code review returned **APPROVED** after one fix round (findings C1, W1, W2, W4, S1, S2 — see *Testing & Code Review* below). Deploy status not evidenced in this pass — no `salesforce-devops` report exists in this conversation; verify org state on the target org independently before relying on it as deployed.

---

## 📋 Overview

### Original Request

> From `agent-output/design-requirements-fsd-tranche-1.md`, itself sourced from
> `docs/DPEG Acquisitions Module Revised FSD v2_0.docx` §9 Conv 3, §15.2, §26, §28, §29.1: close three
> gaps found by reviewing the Acquisitions FSD against the repo. (1) Open an `Offering__c` shell for
> Investor Relations when an acquisition PSA is executed. (2) Remind the Acquisition team 5 and 2 days
> before an NDA expires. (3) Add two validation rules — a broker "first seen" timestamp that cannot be
> hand-edited, and a contract-executed date that requires the deal's PSA to actually be Executed.

### Business Objective

Each item closes a gap between what the FSD promised and what the application actually did. IR was
being notified that a PSA had executed but had no record to work from (`Offering__c` existed as a
bare shell object with no creator anywhere in the app). Nothing reminded the Acquisitions team that a
signed NDA was about to lapse, so a lapse was discoverable only by someone manually checking a date
field. And two fields that should only ever be set by the system or by a correctly-sequenced deal
event — a Lead's first-seen timestamp (the anchor for the 90-day broker-protection window) and an
Opportunity's contract-executed date — had no validation stopping a hand-typed value from silently
corrupting either the protection window or the 75-task Day-0 checklist's dates.

### Summary

Three closely-scoped changes landed together on one branch: a new `OfferingService` /
`OfferingSelector` pair that opens an `Offering__c` shell as the last step of PSA execution
(idempotent, acquisition-only by construction, no new IR notification); a new `NdaExpiryService` /
`NdaExpiryAlertBatch` / `NdaExpiryAlertSchedule` trio that reminds the `Acquisition` queue on a
5-day/2-day ladder with a monotone, re-arming marker; and two validation rules,
`Lead.Broker_First_Seen_Is_System_Set` and `Opportunity.Executed_PSA_Before_Contract_Date`. Two of
the FSD's own stated mechanisms were found to be wrong during design and were deliberately
**not** built as literally written — see *Key Design Decisions* below; both deviations were
user-approved at Gate 1 (Q3.3, Q3.4) before any code was written.

---

## 🏗️ Components Created

### Admin Components (Declarative)

#### Custom Fields

| Object | Field API Name | Type | Description |
|--------|-----------------|------|--------------|
| `NDA__c` | `NDA_Alert_Last_Interval__c` | Number(2,0) | System-maintained: the smallest reminder-ladder rung (5 or 2) already notified. Not for manual entry. |
| `NDA__c` | `NDA_Alert_Expiry_Date__c` | Date | System-maintained snapshot of the expiry date the marker was computed against. Differing from the live `NDA_Expiry_Date__c` re-arms the whole ladder. |

#### Validation Rules

| Object | Rule Name | Description |
|--------|-----------|--------------|
| `Lead` | `Broker_First_Seen_Is_System_Set` | Blocks changing an already-stamped `First_Seen_Date__c`. **Deliberately built on this field, not the FSD-named `Opportunity.Broker_First_Seen__c`** — see *Key Design Decisions*, item 1. No bypass. |
| `Opportunity` | `Executed_PSA_Before_Contract_Date` | Blocks setting/changing `Contract_Executed_Date__c` unless the deal's Primary Contract Review is `Executed`. Exempts a blank `Primary_Contract__c` (structural, not persona-based). No bypass. Carries a known, accepted limitation — see *Testing & Code Review*, finding W1. |

#### Sharing Rules

| Object | Rule Name | Description |
|--------|-----------|--------------|
| `Offering__c` | `Offering_IR_Visibility` | New. Owner-based (`sharingOwnerRules`), sharing rows owned by `roleAndSubordinates: Acquisitions_Analyst` to the `Investor_Relations` group with **Edit**. Carries a large, explicit XML comment recording a known, accepted residual — see *Residuals*. Deploy **on its own** (batched sharing-rule deploys roll back in this org). |

#### Permission Sets (edited, no new sets)

| Permission Set | Change |
|-----------------|--------|
| `DPEG_Acquisition_Edit` | + editable FLS on `NDA__c.NDA_Alert_Last_Interval__c` / `NDA_Alert_Expiry_Date__c`. |
| `DPEG_Acquisition_View` | + readable FLS on the same two fields. |
| `DPEG_Admin_Access` | + FLS on the same two `NDA__c` fields; + FLS on all three `Offering__c` fields; + `<tabSettings>` already carried `Offering__c` from an earlier build. |
| `DPEG_IR_Edit` | **New grant** — `Offering__c` object permissions (`allowRead`/`allowEdit` = true; `allowCreate`/`allowDelete` = **false**, deliberately, so IR cannot bypass `OfferingService`'s one-shell-per-Opportunity idempotency) + editable FLS on all three fields. Per an explicit user directive at Gate 1 ("They will be visible to IR team, right now give them read/write permission"), not a design-agent recommendation. |
| `DPEG_IR_View` | **New grant** — the read-only twin of the above. |
| `DPEG_App_Investor_Relations` | **New** `<tabSettings>` entry making the `Offering__c` tab Visible — the layer-2 app-visibility fix for code review finding C1 (see below). |

#### Applications

| App | Change |
|-----|--------|
| `Investor_Relations` | + `<tabs>Offering__c</tabs>` — without this, IR had full object/field/record access to `Offering__c` and **no tab to click into it from**. Code review finding C1 (see *Testing & Code Review*). |

---

### Development Components (Code)

#### Apex Classes

| Class Name | Type | Description |
|------------|------|--------------|
| `OfferingSelector` | Selector | **First and only `Offering__c` SOQL in the application.** One method, `selectByOpportunityIds`, `WITH SYSTEM_MODE` inside a `private without sharing` inner class `ExecutionHandoffReads`. |
| `OfferingService` | Service | `ensureOnPsaExecuted(Set<Id>)` — opens the IR Offering shell, idempotent on `Opportunity__c` alone, `Status__c = 'Draft'` set explicitly, `IR_Owner__c` left null. `allOrNone = false`, `AccessLevel.SYSTEM_MODE`. |
| `NdaExpiryService` | Service (pure) | The single derivation of NDA expiry state — `evaluate()` (urgency/band/days-remaining) and `shouldFire()` (the two-field monotone re-arming marker rule). Zero SOQL/DML. `ALERT_INTERVALS = {5, 2}` lives here and nowhere else. |
| `NdaExpiryAlertBatch` | Batchable, Stateful | The daily reminder job. Send-first-stamp-second via `GroupNotifier.notifyWithOutcome`. `SCOPE = 200`, inherited (not re-measured) from `CallForOffersAlertBatch`. `public without sharing` since code review finding W2. |
| `NdaExpiryAlertSchedule` | Schedulable | Starts the batch. No logic. **Must be scheduled post-deploy — gate G1.** |
| `NdaSelector` (edited) | Selector | + `queryExpiryAlerts()`, a `Database.QueryLocator` `WITH SYSTEM_MODE` inside a new `private without sharing` inner class `ExpiryAlertReads`. Class header amended in place (and its stale `USER_MODE` count corrected — code review finding W4). |
| `ContractExecutionService` (edited) | Service | `stampOpportunities` gained one call, `OfferingService.ensureOnPsaExecuted(executedOppIds)`, as its **last statement** — the placement is what makes the Offering shell acquisition-only *structurally*, with no new guard. |

#### Test Classes

| Test Class | Tests For | Method Count |
|------------|-----------|----------------|
| `OfferingSelectorTest` | `OfferingSelector` | 4 |
| `OfferingServiceTest` | `OfferingService` | 11 |
| `NdaExpiryServiceTest` | `NdaExpiryService` | 17 |
| `NdaExpiryAlertBatchTest` | `NdaExpiryAlertBatch` | 15 (251-row locator bulk test included) |
| `NdaExpiryAlertScheduleTest` | `NdaExpiryAlertSchedule` | 3 |
| `LeadFirstSeenValidationTest` | `Broker_First_Seen_Is_System_Set` | 8 (new dedicated class) |
| `ContractExecutionServiceTest` (edited) | `OfferingService.ensureOnPsaExecuted` call site + `Executed_PSA_Before_Contract_Date` | +7 new methods, incl. a 251-record bulk Offering test and the W1 known-limitation pin |

Method counts are `static void` occurrences grepped from each file directly, not carried over from
the design doc's estimates. Total: **58 new/added test methods** across 7 classes.

#### Not created

No LWC, no Flow, no new custom object, no Custom Setting. Item 3's validation rules needed only
regression *pinning* in Apex (`ContractExecutionServiceTest`, `LeadFirstSeenValidationTest`) — the
rules themselves are pure declarative metadata.

---

## 🔑 Key Design Decisions and Rationale

Pulled from the class/metadata header Javadoc and XML comments, which this codebase's convention
treats as the authoritative record — not re-derived here.

### 1. The FSD named the wrong field for the broker first-seen rule, and the wrong flow for the fan-out rule

Two of the FSD's five stated mechanisms were checked against the actual code during design and found
wrong. Both deviations were explicit Gate-1 decisions (Q3.3, Q3.4), not silent substitutions:

- **FSD §26 named `Opportunity.Broker_First_Seen__c`.** A repo-wide grep found **nothing writes that
  field** — no Apex, no Flow. A rule there would permanently lock an already-blank field and remove
  the only way it could ever be populated (a human typing it) — strictly worse than no rule. The
  rule was built instead on **`Lead.First_Seen_Date__c`**, the field that actually drives the 90-day
  broker-protection window (`Lead.BP_Expiry__c = First_Seen_Date__c + 90`).
- **FSD §29.1 claimed the Opportunity rule prevents the 75-task Day-0 fan-out firing early.** It does
  not: `Transaction_Task_Fanout` is `RecordAfterSave` on **`Transaction__c`**, filtered on
  `Transaction__c.Contract_Executed_Date__c` and `Tasks_Fanned_Out__c` — it never reads Opportunity
  at all. What the Opportunity rule actually prevents is a **mis-dated** checklist: every one of the
  ~75 tasks is offset from `Transaction__c.Contract_Executed_Date__c`, which
  `openTransactionsOnAboutToClose` copies straight from the Opportunity field. The rule was built as
  the FSD asked (on Opportunity), but its XML comment states the corrected rationale rather than
  propagating the wrong one into metadata. A companion `Transaction__c`-level rule that would
  actually gate the fan-out is flagged as an explicit tranche-2 candidate, not built here — it needs
  its own design pass because its field is written `allOrNone = true` inside an Opportunity
  after-update trigger, so a block there would roll back the deal's own stage change.

### 2. Three sharing escapes, three different failure modes — none the same as the others

All three new/edited reads and writes against Private-OWD objects with insufficient sharing rules
needed `without sharing`, but each fails a different way if it is ever "cleaned up":

- **`OfferingSelector.ExecutionHandoffReads`** (the Offering idempotency guard read). A
  sharing-filtered read here does not disable the feature — it **inverts** it: zero rows means "no
  Offering exists" and the service silently creates a **duplicate** shell.
- **`NdaSelector.ExpiryAlertReads`** (the reminder locator). `NDA__c` is Private with both its
  sharing rules criteria-scoped to `Disposition NDA` — nothing covers an acquisition NDA at all. A
  scheduling principal without an acquisitions permission set sees zero rows, and `finish()` logs an
  all-zeros summary **indistinguishable from a healthy pipeline**.
- **`NdaExpiryAlertBatch.MarkerWrites`** (the marker stamp). `SYSTEM_MODE` lifts CRUD/FLS and *never*
  sharing; a Private-OWD `update` by a non-owner is refused, and because the write uses
  `allOrNone = false`, that refusal arrives as a silent `SaveResult`, not an exception — the job
  would re-remind the same NDA **every single day, forever**.

`SYSTEM_MODE` and `without sharing` are argued as two separate decisions at every one of these
declarations, per ARCHITECTURE.md §2's standing rule — conflating them is a mistake this repo has
already paid for once (the "D25" precedent both class headers cite).

### 3. `Offering__c` DML mode — measured, and the answer differs from the closest precedent

`Transaction__c`'s creator (`PropertyAssetService`) uses `SYSTEM_MODE` because the deal driver
persona measurably has **no** Create on that object. Measured for `Offering__c`: the acquisitions
persona *can* create one — `DPEG_Acquisition_Edit` grants full CRUD. `OfferingService` still uses
`SYSTEM_MODE`, for two narrower reasons: the persona that *executes* a PSA is gated by the
`Acquisition_Deal_Actions` custom permission, which does not imply holding `DPEG_Acquisition_Edit`
(different layers, ARCHITECTURE.md §2 Permission Set Architecture); and `DPEG_Admin_Access` carries a
`<tabSettings>` entry for `Offering__c` and **no `objectPermissions` entry at all**, so a bare
administrator has no CRUD on it from that set. A user-mode insert would throw `System.TypeException`
for part of the executing population — and a `TypeException` is not a `DmlException`, so
`allOrNone = false` would not catch it and the PSA execution would roll back anyway.

### 4. `allOrNone = false` for the Offering insert — a decided trade, argued against both in-repo precedents

`advanceDispositionsToClosing` (same class) chose `false` because "the legal state is the
irreplaceable half." `PropertyAssetService.ensureOnClosedWon` chose `true` because "its silent
absence WAS the bug." Both are cited, and `false` was chosen here: an executed PSA is a legal event
with a counterparty; an Offering shell is three fields a human can key in thirty seconds. The residual
is stated plainly, not hidden: **a failed insert leaves no Offering and no signal** — there is no
sweeper for this object.

### 5. `IR_Owner__c` is left null by design, and IR visibility was closed as three separate artifacts

`IR_Owner__c` is a **User** lookup; `Investor_Relations` is a public **group**, and a group Id cannot
populate a User lookup. Nothing in the schema names "the IR owner." Two alternatives were rejected
(picking an arbitrary group member — non-deterministic; a Custom Setting default — data is not
deployable and the value would be null on every org but one). The consequence is bigger than the
field: `Offering__c` is Private OWD, so the new row's *record* owner is simply whoever executed the
PSA. IR visibility is therefore not a property of `OfferingService` at all — it required, and got,
**three separate artifacts in the same PR**: `DPEG_IR_Edit`/`DPEG_IR_View` object+field grants, the
new `Offering_IR_Visibility` sharing rule, and (after code review) the `Offering__c` tab on the IR
app. See *Testing & Code Review*, finding C1, for what happens when only the first two land.

### 6. What `OfferingService` deliberately does NOT do

No second notification (IR is already told at PSA execution by the existing batched
`GroupNotifier.notify()` call, three lines above the new insert). No `Primary_Offering__c` stamp —
unlike `Primary_LOI__c`, nothing needs to *resolve* an Offering, so a parent stamp would import the
whole approval-lock/deferred-stamp machinery (`LoiPrimaryStampQueueable`'s shape) for no benefit.
Nothing advances `Offering__c.Status__c` past `Draft` — the shell has no record page, no Path, and no
lifecycle automation; "the Offering never leaves Draft" is a named state of this tranche, not a
defect in it.

### 7. The NDA reminder discriminator is the parent lookup, never the record type

The FSD asked for the reminder locator to be scoped to the `Acquisition_NDA` record type. ARCHITECTURE.md
records that until post-deploy gate T-A1/T-B, **every live NDA sits on the `Master` record type** — a
`RecordType.DeveloperName = 'Acquisition_NDA'` filter would therefore return **zero rows for every
un-migrated NDA**, and the job would run daily, log an all-zeros summary, and look completely
healthy while doing nothing. `NdaSelector.queryExpiryAlerts` uses `Opportunity__c != NULL` instead —
the same discriminator `Contract_Review__c.Disposition__c`'s own field metadata mandates and that
`ContractExecutionService` already uses for the identical migration-window reason.

### 8. The NDA marker needed two fields, not one, or expiry extensions would go permanently silent

`NDA_Alert_Last_Interval__c` alone (monotone, "smallest rung already notified") makes a missed day
catch up and a double run a no-op. But without `NDA_Alert_Expiry_Date__c` — the snapshot of the
expiry date the marker was computed against — extending an NDA's expiry (an ordinary edit; nothing
computes the date) leaves the marker armed against a date that no longer exists: the rung can never
go back down, the strictly-smaller test can never pass again, and the NDA is **never reminded about
again**, on exactly the NDAs someone cared enough about to extend. When the snapshot differs from the
live expiry, the marker is treated as blank and the whole ladder re-arms.

---

## 🔄 Data Flow

### Item 1 — Offering shell at PSA execution

```
User executes a PSA (Advance Stage action on Contract_Review__c)
        │
        ▼
ContractReviewTrigger (after update)
        │
        ▼
ContractExecutionService.handleExecution
        │
        ├──▶ stampOpportunities(executedOppIds)      [only non-null Opportunity__c parents —
        │         │                                    a sell-side PSA never reaches here]
        │         ├─ stamp Contract_Signed__c, Contract_Executed_Date__c (Day 0), Deal_Status__c
        │         ├─ GroupNotifier.notify()  → Transactions_Team, Investor_Relations, Due_Diligence
        │         └─ OfferingService.ensureOnPsaExecuted(executedOppIds)   ← NEW, runs LAST
        │                   │
        │                   ├─ OfferingSelector.selectByOpportunityIds (SYSTEM_MODE, without sharing)
        │                   │        → skip deals that already have a shell
        │                   └─ Database.insert(Offering__c{Opportunity__c, Status__c='Draft'},
        │                                       allOrNone=false, SYSTEM_MODE)
        │
        └──▶ advanceDispositionsToClosing(executedDispositionIds)   [unchanged]

Offering__c (new row, Status = Draft, owned by whoever executed the PSA)
        │
        ▼
Visible to IR via: DPEG_IR_Edit/_View (object+field grants)
                  + Offering_IR_Visibility sharing rule (owner-based, Acquisitions_Analyst branch)
                  + the Offering__c tab on the Investor Relations app
```

### Item 2 — NDA expiry reminders

```
NdaExpiryAlertSchedule (daily, cron — MUST be scheduled post-deploy, gate G1)
        │
        ▼
NdaExpiryAlertBatch.start()
        │
        ▼
NdaSelector.queryExpiryAlerts()   (QueryLocator, SYSTEM_MODE, without sharing — ExpiryAlertReads)
   WHERE NDA_Expiry_Date__c <= TODAY+5 AND Is_Non_Expiring__c = FALSE
     AND Opportunity__c != NULL AND Status__c = 'Signed'
        │
        ▼
execute(scope)  — one asOf clock for the whole chunk
        │
        ├─ for each NDA: NdaExpiryService.evaluate() → urgency/band/dueInterval
        │                NdaExpiryService.shouldFire(dueInterval, lastInterval,
        │                                             liveExpiry, markerExpiry)
        │
        ├─ requests owed a reminder  ──▶  GroupNotifier.notifyWithOutcome()  ──▶  Acquisition QUEUE
        │                                        │
        │                                        ▼ (only rows whose send SUCCEEDED)
        └─ NdaExpiryAlertBatch.MarkerWrites.stampMarkers()   (SYSTEM_MODE, without sharing)
               → NDA_Alert_Last_Interval__c = dueInterval
               → NDA_Alert_Expiry_Date__c   = live NDA_Expiry_Date__c   (the re-arm snapshot)
```

---

## 📁 File Locations

| Component Type | Path |
|------------------|------|
| New Apex classes | `force-app/main/default/classes/{OfferingSelector,OfferingService,NdaExpiryService,NdaExpiryAlertBatch,NdaExpiryAlertSchedule}.cls` |
| Edited Apex classes | `force-app/main/default/classes/{NdaSelector,ContractExecutionService}.cls` |
| New test classes | `force-app/main/default/classes/{OfferingSelectorTest,OfferingServiceTest,NdaExpiryServiceTest,NdaExpiryAlertBatchTest,NdaExpiryAlertScheduleTest,LeadFirstSeenValidationTest}.cls` |
| New fields | `force-app/main/default/objects/NDA__c/fields/{NDA_Alert_Last_Interval__c,NDA_Alert_Expiry_Date__c}.field-meta.xml` |
| New validation rules | `force-app/main/default/objects/Lead/validationRules/Broker_First_Seen_Is_System_Set.validationRule-meta.xml`, `force-app/main/default/objects/Opportunity/validationRules/Executed_PSA_Before_Contract_Date.validationRule-meta.xml` |
| New sharing rule | `force-app/main/default/sharingRules/Offering__c.sharingRules-meta.xml` |
| Edited permission sets | `force-app/main/default/permissionsets/{DPEG_Acquisition_Edit,DPEG_Acquisition_View,DPEG_Admin_Access,DPEG_IR_Edit,DPEG_IR_View,DPEG_App_Investor_Relations}.permissionset-meta.xml` |
| Edited application | `force-app/main/default/applications/Investor_Relations.app-meta.xml` |
| Architecture doc | `ARCHITECTURE.md` §1, §2 (Key Apex Services table, `WITH SYSTEM_MODE` table + running count, and a new note on `LoiSelector`'s self-contradictory header — see below) |

---

## ⚙️ Configuration Details

### `NDA__c.NDA_Alert_Last_Interval__c`

Number(2,0), not required, no default. System-maintained by `NdaExpiryAlertBatch`; arrives in Apex as
a `Decimal` and must be cast with `.intValue()` before reaching `NdaExpiryService.shouldFire`.

### `NDA__c.NDA_Alert_Expiry_Date__c`

Date, not required, no default. The re-arm snapshot — see *Key Design Decisions*, item 8.

### `Broker_First_Seen_Is_System_Set` (Lead)

```
AND(
  ISCHANGED(First_Seen_Date__c),
  NOT(ISBLANK(PRIORVALUE(First_Seen_Date__c)))
)
```

Fires only on a manual edit to an **already-stamped** Lead. Insert is unaffected (`ISCHANGED` is
false); `Lead_Intake_Stamp`'s own before-save assignment (only when the field `IsNull`) is exempt
because the prior value is blank. `Database.convertLead` only enforces Lead VRs when
`shouldLeadConvertRequireValidation` is true in Setup (`settings/LeadConfig.settings-meta.xml`,
force-ignored — verify in Setup, not the repo file, per post-deploy gate G6); either way the rule is
inert at conversion because conversion never writes this field. Deliberately no bypass.

### `Executed_PSA_Before_Contract_Date` (Opportunity)

```
AND(
  ISCHANGED(Contract_Executed_Date__c),
  NOT(ISBLANK(Contract_Executed_Date__c)),
  NOT(ISBLANK(Primary_Contract__c)),
  TEXT(Primary_Contract__r.Negotiation_Status__c) <> "Executed"
)
```

Tests `Negotiation_Status__c`, never `Stage__c` (which a before-save flow recomputes and silently
discards direct writes to). The `NOT(ISBLANK(Primary_Contract__c))` clause is **mandatory, not
defensive** — `ContractExecutionService.stampOpportunities` writes this field
`allOrNone = true`, `SYSTEM_MODE` (which bypasses CRUD/FLS but *not* validation rules) from inside a
`Contract_Review__c` after-update trigger with no catch of its own; without the exemption, any deal
whose `Primary_Contract__c` was never stamped would have its **entire PSA execution rolled back** —
`Contract_Signed__c`, the Day-0 stamp, and all three notifications — and the user would see only
`RecordStageAdvanceController`'s fixed generic "This change could not be saved." Deliberately no
bypass. Carries a known, accepted second hole not covered by the blank-primary exemption — see
*Testing & Code Review*, finding W1.

---

## 🧪 Testing & Code Review

### Coverage Summary

| Class | New/Modified Test Methods |
|-------|-----------------------------|
| `OfferingSelector` | 4 (`OfferingSelectorTest`) |
| `OfferingService` | 11 (`OfferingServiceTest`) |
| `NdaExpiryService` | 17 (`NdaExpiryServiceTest`) |
| `NdaExpiryAlertBatch` | 15 (`NdaExpiryAlertBatchTest`, incl. a 251-row locator bulk test) |
| `NdaExpiryAlertSchedule` | 3 (`NdaExpiryAlertScheduleTest`) |
| `Broker_First_Seen_Is_System_Set` | 8 (`LeadFirstSeenValidationTest`, new dedicated class) |
| `ContractExecutionService` / `Executed_PSA_Before_Contract_Date` | +7 new methods in the existing `ContractExecutionServiceTest` |

`.claude/rules/bulk-test-rule.md`'s 251-record mandate was applied with **no exemption** to both the
`ContractReviewTrigger` path (Item 1: `bulkExecution251AcquisitionPsasOpen251Offerings`) and the NDA
locator (Item 2: `alertBatchAt251NdasIsBulkSafe`, corrected mid-review — see finding S1 below).
Governor-headroom assertions read counters captured **inside** the async context
(`NdaExpiryAlertBatch`'s `chunk*` statics), never `Limits.*` after `Test.stopTest()`.

### Code Review Findings (2026-08-16 pass, one fix round, verdict **APPROVED**)

Labels and resolutions are recorded verbatim (mined from the shipped code's own comments, per this
repo's convention of embedding review-item labels directly in class/test headers):

| Finding | What it was | Resolution |
|---------|--------------|--------------|
| **C1** | `Offering__c` shipped with object permissions, field permissions and a sharing rule all correctly granted for IR — and **no route to the record at all**. `Investor_Relations.app-meta.xml` declared no `Offering__c` tab, and the only `<tab>Offering__c</tab>` grant anywhere in `permissionsets/` was on `DPEG_Admin_Access`. An IR user with full access still had nowhere to click. | **Fixed.** Added `<tabs>Offering__c</tabs>` to `Investor_Relations.app-meta.xml` and a matching `<tabSettings>` entry to `DPEG_App_Investor_Relations` (the layer-2 app-visibility set). |
| **W1** | `Executed_PSA_Before_Contract_Date`'s blank-`Primary_Contract__c` exemption does not cover a second, same-shape hole: a deal with **two** Contract Reviews, where the one that executes is *not* the stamped primary, still has the rule fire against the primary's (unexecuted) status and roll back the whole PSA execution. | **Accepted as a known limitation, not fixed in this tranche.** A validation rule cannot count/aggregate child records, so closing it properly needs a new rollup field on Opportunity and its own design pass. Pinned by `ContractExecutionServiceTest.aPsaExecutionIsBlockedWhenPrimaryContractPointsAtADifferentUnexecutedReview` — a test that asserts the current (undesired) behaviour and is *expected to go red* if the hole is ever closed. |
| **W2** | `NdaExpiryAlertBatch.MarkerWrites`' `without sharing` inner class alone leaves an **unestablished** question: does the platform re-apply the batch class's own sharing context when it chunks a `Database.QueryLocator` built inside a different `without sharing` inner class? No file in the repo answers it. | **Fixed, as a defense-in-depth argument, not a re-measurement.** `NdaExpiryAlertBatch` itself was made `public without sharing`. The class holds zero SOQL/DML of its own and every callee declares its own sharing keyword, so nothing is *newly* widened — but it closes the one path by which the `MarkerWrites` escape could be silently undone by a future refactor. Post-deploy gate G2 (confirm as the scheduling principal) is explicitly **retained, not closed**, by this fix. |
| **W4** | `NdaSelector`'s class header stated its `USER_MODE` method count as "four" in two places — both wrong; it was five even before this tranche's `queryExpiryAlerts` addition. | **Fixed.** Corrected in place in the class header and in `ARCHITECTURE.md`'s running `WITH SYSTEM_MODE` count. |
| **S1** | A test comment in `NdaExpiryAlertBatchTest` claimed a 251-row fixture "proves the locator's ceiling and the in-memory ladder agree" — a test method executes exactly one chunk, so it cannot observe anything about rows sorted past row 200. | **Fixed.** Comment corrected in place to state precisely what the 251-row fixture does and does not prove. |
| **S2** | `CallForOffersService`, `CallForOffersAlertBatch` and `CallForOffersAlertSchedule` — the precedent this tranche's Item 2 deliberately mirrors — are absent from `ARCHITECTURE.md`'s Key Apex Services table, even though the new NDA rows cite them by name. | **Recorded, deliberately not fixed in this tranche** (back-filling three unrelated rows inside a review pass would have buried the finding). `ARCHITECTURE.md` §2 now carries a permanent note assigning this to whoever next touches the call-for-offers feature. |

### An additional finding recorded, not fixed, in this pass (reviewer condition)

`LoiSelector`'s class header was found to be **wrong about its own `SYSTEM_MODE` count, in two
places, and self-contradictory** — the class-level summary says "four of the six methods" (should be
five of seven); `selectNegotiationContextById`'s own doc comment claims it is "the only query in this
class" that is `SYSTEM_MODE` and "the other four... stay `WITH USER_MODE`" (should be two/five), which
directly contradicts a separate, correct sentence three lines above it in the same header. This is a
pure-comment fix with zero deploy risk, found while reviewing this tranche's unrelated NDA work. Per
the reviewer's explicit instruction, **no Apex or metadata was touched** — a permanent note was added
to `ARCHITECTURE.md` §2, alongside the existing `CallForOffers*` (S2) debt note, so it is not lost the
way that one nearly was.

---

## 🔒 Security

- `OfferingService`, `OfferingSelector` (outer class), `NdaExpiryService`, `NdaSelector` (outer
  class), `NdaExpiryAlertSchedule` are `with sharing`. `NdaExpiryAlertBatch` is `without sharing`
  (finding W2 — see *Testing & Code Review*), a defense-in-depth measure that widens nothing because
  it holds no SOQL/DML of its own.
- Three narrowly-scoped `private without sharing` inner classes carry the actual escapes:
  `OfferingSelector.ExecutionHandoffReads`, `NdaSelector.ExpiryAlertReads`,
  `NdaExpiryAlertBatch.MarkerWrites`. Each is argued separately in *Key Design Decisions*, item 2.
- All new/edited SOQL uses `WITH SYSTEM_MODE` on automation-path grounds (a read/write the platform
  performs on the user's behalf, not one a human explicitly asked for) — never as a substitute for
  the sharing decision, which is argued independently at each declaration.
- `Offering__c` remains Private OWD. `DPEG_IR_Edit`/`DPEG_IR_View` carry no `viewAllRecords` — IR's
  only route to a row it does not own is the new `Offering_IR_Visibility` sharing rule.
- Object CRUD is the ceiling everywhere: `DPEG_IR_Edit` deliberately withholds `allowCreate`/
  `allowDelete` on `Offering__c` so IR cannot mint or remove a shell and bypass the
  one-per-Opportunity idempotency `OfferingService` enforces.

---

## 📝 Notes & Considerations

### Known Limitations

- **W1** (see *Testing & Code Review*): `Executed_PSA_Before_Contract_Date` does not exempt a
  wrong-Contract-Review (as opposed to a blank one), and a deal with two Contract Reviews where a
  non-primary one executes will have its entire PSA execution rolled back. Closing it needs a new
  Opportunity rollup field and a re-targeted rule — its own design pass, out of scope here.
- **Offering shell has no failure sweeper.** A failed `OfferingService` insert (`allOrNone = false`)
  leaves no Offering and no signal beyond a debug log line — no status field, no retry.
- **`Offering__c` never leaves `Draft`.** No record page, no Path, no lifecycle automation exists for
  it in this tranche; creating the shell was the FSD's whole ask.
- **`NDA_Expiry_Date__c` is a plain, hand-keyed Date that nothing computes.** The reminders are only
  as good as the human who typed the date.
- **The `Offering_IR_Visibility` sharing rule is owner-based, not criteria-based, and only reaches
  the `Acquisitions_Analyst` role branch.** An Offering created by a principal, an administrator
  running UAT or a data fix, or anyone in the `Investor_Relations_Manager`/`Transactions_Coordinator`
  branches is **not** shared to IR by this rule — silently, with no error. This was a Gate-1 choice
  (offered against a criteria-based all-records alternative; the user chose the narrower rule and
  accepted the residual), recorded in full in the sharing rule file's own XML comment. The named
  remedy, if this residual ever needs closing, is a `sharingCriteriaRules` entry with an always-true
  condition (the object carries no record type or other discriminating field to key a narrower
  criteria rule on).
- A companion `Transaction__c.Contract_Executed_Date__c` validation rule — the one that would
  actually gate the 75-task fan-out — is a named tranche-2 candidate, not built here.

### Out-of-scope findings (reported at design time, not folded into this build)

- `Opportunity.Broker_First_Seen__c`'s `<description>` asserts a "Conv 1" carry-forward from Lead
  that nothing implements — a separate, unimplemented FSD gap. Implementing that copy and then
  locking it is the complete fix for the FSD's original intent; re-targeting to `Lead` (this tranche)
  is the safe partial fix available today.

### Dependencies

- Item 1 depends on `ContractExecutionService.stampOpportunities` (existing) and `GroupNotifier`
  (existing, unchanged).
- Item 2 mirrors `CallForOffersService` / `CallForOffersAlertBatch` / `CallForOffersAlertSchedule`
  precedent-for-precedent (SCOPE inheritance, send-then-stamp order, `GroupNotifier.notifyWithOutcome`).
- Item 3's Opportunity rule depends on `Primary_Contract__c` being populated by
  `OpportunityReviewService` on the ordinary path, and is exercised end-to-end by
  `ContractExecutionServiceTest` — that suite staying green is the load-bearing proof that the
  cross-object formula reference sees the in-transaction `'Executed'` status (gate G5).

---

## 🚦 Required Post-Deploy Manual Steps

These do not travel with the metadata bundle. Each is a **verified deploy gate** — the failure mode
if skipped is a feature that deploys, compiles, passes tests, and does nothing, with no error
anywhere.

| Gate | Action | Failure Mode If Skipped |
|------|--------|---------------------------|
| **G1** | **Schedule `NdaExpiryAlertSchedule`** (daily, e.g. `System.schedule('DPEG NDA Expiry Alert', '0 0 7 * * ?', new NdaExpiryAlertSchedule());`). Record the cron expression **and the owning user**. | Class deploys, compiles, tests and covers, and is completely inert — zero reminders, zero errors, zero failed `AsyncApexJob` rows. No trace at all; "no reminder arrived" is indistinguishable from "no NDA was expiring." |
| **G2** | Confirm, **as the scheduling principal**, that a real pass selects and stamps an acquisition NDA that principal does not own. Re-verify when that user is deactivated. | If the `without sharing` remedies are ever watered down, an ungranted schedule owner produces an all-zeros `finish()` summary indistinguishable from a healthy pipeline. |
| **G3** | Confirm the `Acquisition` **queue's** membership is the intended alerting population (measured at **one** member; not deployable metadata). | Alerts fire to one person, or to nobody. |
| **G4** | Confirm IR's `Offering__c` visibility by **opening an Offering as an IR user**, not as an administrator (an administrator passes for an unrelated reason — the "Modify All Data"/`viewAllRecords` shape does not apply here, but an admin session can mask a genuine IR-side gap). | Offering shells are created and are invisible to IR, with no error. (Code review already found and fixed the tab-visibility half of this — G4 remains the confirmation step.) |
| **G5** | Run `ContractExecutionServiceTest` immediately after `Executed_PSA_Before_Contract_Date` deploys. | If the cross-object VR does not see the in-transaction `'Executed'` status, every PSA execution rolls back, surfacing only as `RecordStageAdvanceController`'s fixed generic "could not be saved." |
| **G6** | Verify `shouldLeadConvertRequireValidation` **in Setup**, not in the repo (`settings/LeadConfig.settings-meta.xml` is `.forceignore`d and is an unverified snapshot). | The Lead rule is inert at conversion either way, but the assumption must be checked rather than inherited. |
| **G7** | Reconcile every touched permission set (`DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `DPEG_Admin_Access`, `DPEG_IR_Edit`, `DPEG_IR_View`, `DPEG_App_Investor_Relations`) against the org **before** deploying it. | A `PermissionSet` deploy **replaces** its entire `<fieldPermissions>` set — an org-side-only grant absent from the file is silently wiped, as happened twice before on this project (`Broker_Protection_Access`/`Task.WhoId`). |
| — | Deploy `sharingRules/Offering__c.sharingRules-meta.xml` **on its own**, not batched with any other sharing-rule change. Expect sharing recalculation to lag after deploy — a check immediately afterward may not yet reflect the rule. | A batch deploy of sharing rules rolls **all** of them back in this org (established 2026-07-22, repeated here). |

---

## 📜 Change History

| Date | Author | Change Description |
|------|--------|----------------------|
| 2026-08-16 | Documentation Agent | Initial creation — FSD Gap Closure Tranche 1 (Offering shell, NDA expiry reminders, two validation rules). Includes the `ARCHITECTURE.md` §2 note on `LoiSelector`'s self-contradictory header, added as a reviewer-mandated condition of this documentation pass. |
