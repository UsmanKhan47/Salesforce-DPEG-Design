# 📋 DESIGN REQUIREMENTS — DPEG Acquisitions FSD Gap Closure, Tranche 1

**Branch:** `feature/acquisitions-fsd-tranche-1` (⚠ current working branch is `test/acquisition-disposition-flows` — branch before any work starts)
**Source:** `docs/DPEG Acquisitions Module Revised FSD v2_0.docx` §9 Conv 3, §15.2, §26, §28, §29.1
**Verified against:** repo @ 2026-08-16. `ARCHITECTURE.md`, `CLAUDE.md`, `.claude/rules/*` read first.
**Scope:** requirements only. No implementation files written.

---

## 🔴 PREMISE CORRECTIONS — READ BEFORE PRICING ANYTHING

Five statements in the brief were checked against the code and are wrong or stale. Each changes a design decision.

| # | Brief said | Repo says | Consequence |
|---|---|---|---|
| **P1** | "`ContractExecutionService.handleExecution` already creates the `Transaction__c` idempotently — mirror it in the SAME method" | ❌ **Transaction creation MOVED OUT on 2026-08-05.** It now lives in `ContractExecutionService.openTransactionsOnAboutToClose`, hung off `OpportunityReviewTrigger`, keyed on `Opportunity.StageName = 'About to Close'`. `handleExecution` only stamps Day 0 + notifies. The class header says *"Do not re-add Transaction creation to handleExecution."* | The idempotency pattern is real but lives in a **different method on a different trigger**. Copy the *shape*, not the location. |
| **P2** | "its header warns an executed SALE would otherwise mint a phantom acquisition artifact" | ❌ The header says the exact opposite: *"THAT RISK NO LONGER EXISTS and nothing here guards against it."* The acquisition arm has **always** dropped a Contract Review with a null `Opportunity__c`. | The acquisition-only requirement is satisfied **structurally and for free** by placing the new call inside `stampOpportunities(Set<Id> executedOppIds)` — that set only ever receives non-null `Opportunity__c` parents. No new guard, no record-type test. |
| **P3** | "`LeadConvertService` stamps `Opportunity.Broker_First_Seen__c` during conversion" | ❌ **Nothing in the repo writes `Broker_First_Seen__c` at all.** Verified by repo-wide grep: no Apex writer, no Flow writer. `CallForOffersService`'s own class header records this independently: *"nothing in this repo writes `Broker_First_Seen__c` at all (`LeadConvertService` does not copy it, and no flow touches it)"*. The field's `<description>` ("Copied from Lead at Conversion 1") is aspirational. | Trap (b) as stated **does not exist on the Opportunity field**. It exists, in a different form, on `Lead.First_Seen_Date__c`. And a VR on the Opportunity field would lock a permanently-blank field — see Item 3. |
| **P4** | Rule 5 "prevents the 75-task fan-out firing early" | ❌ **`Transaction_Task_Fanout` is `RecordAfterSave` on `Transaction__c`**, filtered `Contract_Executed_Date__c IsNull = false` AND `Tasks_Fanned_Out__c = false`. It never reads Opportunity. | An Opportunity VR does **not** prevent an early fan-out. It prevents a **mis-dated** one. The FSD's stated mechanism is wrong; the rule is still worth building, for a different reason. |
| **P5** | The re-notification guard is one field (`Offer_Alert_Last_Interval__c`) | ⚠ Incomplete. The precedent uses **two**: `Offer_Alert_Last_Interval__c` *and* `Offer_Alert_Due_Date__c` (a snapshot of the date the marker was computed against). `CallForOffersService` §3: *"🔴 THE SECOND FIELD IS NOT DEFENSIVE POLISH … without the snapshot, an extension leaves the marker armed against a date that no longer exists and the re-armed schedule NEVER FIRES — silently."* | Item 2 needs **two** new fields, not one. |

---

## 🎯 WHAT THE USER REQUESTED

Three FSD gap-closure items, requirements only:
1. Create an `Offering__c` shell when an acquisition PSA is executed.
2. NDA expiry reminders at 5 and 2 days before expiry, to the Acquisition Team.
3. Two validation rules: broker first-seen is not manually editable; contract executed date requires an Executed PSA.

Nothing beyond this is proposed. Items flagged as out-of-scope findings are listed in one place at the end and are **not** folded into the build.

---

# ITEM 1 — Offering shell at PSA executed

## Established / verified

| Fact | Status |
|---|---|
| `Offering__c` exists: `Opportunity__c` (Lookup→Opportunity, `SetNull`), `IR_Owner__c` (Lookup→User, `SetNull`), `Status__c` | ✅ verified |
| `Status__c` is a **restricted** picklist: `Draft` (`<default>true</default>`), `Active`, `Closed` | ✅ verified |
| Name field is AutoNumber `OFR-{0000}` — no Name to supply | ✅ verified |
| Nothing creates one. Only non-metadata reference is `TestDataFactory.createOfferings` / `createOffering` (already sets `Status__c = 'Draft'`) | ✅ verified |
| No `OfferingSelector` exists — this would be the **first and only `Offering__c` SOQL in the application** | ✅ verified |
| IR is already notified at execution (`Investor_Relations` + `Transactions_Team` + `Due_Diligence`, one batched `GroupNotifier.notify()`) | ✅ verified — **do not add a notification** |
| `Offering__c` is `sharingModel Private`, `enableSharing true`, and `sharingRules/Offering__c.sharingRules-meta.xml` is **EMPTY** | ✅ verified |
| `Opportunity.Primary_Offering__c` does **not** exist | ✅ verified |

## DML mode — measured, and the answer differs from `Transaction__c`

The brief flagged this correctly as a real risk. Measurement:

- `DPEG_Acquisition_Edit` grants `Offering__c`: `allowCreate=true`, `allowEdit=true`, `allowRead=true`, `viewAllRecords=true`, and `editable=true` FLS on all three fields.
- ⇒ **Unlike `Transaction__c` (Create = false, the measured `System.TypeException`), the acquisitions persona CAN create an Offering.**

**Recommendation: use `AccessLevel.SYSTEM_MODE` anyway.** Three reasons, none of them "consistency for its own sake":
1. The persona that executes a PSA is defined by the **`Acquisition_Deal_Actions` custom permission** on the layer-5 `Acquisition_Deal_Driver` set. Holding that permission does **not** imply holding `DPEG_Acquisition_Edit` — those are different layers and different assignments (ARCHITECTURE §2, Permission Set Architecture). So the measured grant does not cover the whole executing population.
2. `DPEG_Admin_Access` carries a `<tabSettings>` entry for `Offering__c` and **no `objectPermissions` entry at all**.
3. Both sibling DMLs in this class are already `AccessLevel.SYSTEM_MODE` for the same class of reason.

## `allOrNone` — a real trade, and the repo precedent cuts both ways

`stampOpportunities` currently ends in `Database.update(oppUpdates, true, SYSTEM_MODE)` — all-or-none.

| Option | Precedent | Failure mode |
|---|---|---|
| `allOrNone = false` **(recommended)** | `advanceDispositionsToClosing` in this same class: *"An all-or-none update would roll back THE PSA EXECUTION ITSELF … The legal state is the irreplaceable half."* | A failed insert leaves no Offering and **no signal** — there is no sweeper. Real residual; state it, don't hide it. |
| `allOrNone = true` | `PropertyAssetService` is deliberately all-or-none *"because its silent absence WAS the bug"* — which is exactly this feature's situation | A refused insert rolls back the PSA execution: `Contract_Signed__c`, Day 0, the three notifications, all gone. |

→ **OPEN QUESTION Q1.1** (below). Recommendation is `false`, on the grounds that the executed PSA is the irreplaceable half and an Offering is recoverable by hand.

## Idempotency

Follow the `openTransactionsOnAboutToClose` shape exactly: one bulk read of existing children keyed on the parent Id set, build a `Set<Id> alreadyHasOffering`, skip those. **Never a second Offering for one Opportunity.**

🔴 **The guard read must escape sharing.** `Offering__c` is Private OWD with zero sharing rules. ARCHITECTURE §2 records the escalated rule: *"whenever a SYSTEM_MODE automation read against a Private-OWD object is used to decide whether something already exists, sharing is not a robustness question, it is a correctness one — a filtered read does not disable the feature, it inverts it."* A filtered read returns zero rows → "no Offering exists" → a **duplicate** shell. Put the query in a `private without sharing` inner class (`OfferingSelector.ExecutionHandoffReads`), mirroring `PropertyAssetSelector.AssetCreationReads`; the outer selector stays `with sharing`.

## Field set for the new shell

| Field | Value | Why |
|---|---|---|
| `Opportunity__c` | the executed deal's Id | the only link |
| `Status__c` | **`'Draft'`, set EXPLICITLY** | never inherit the picklist `<default>` — a creator that relies on a field default breaks silently when the default moves (recorded repo trap) |
| `IR_Owner__c` | **null** | see below |
| `Name` | not supplied | AutoNumber |

**`IR_Owner__c` cannot be derived, and the consequence must be stated.** It is a `User` lookup; `Investor_Relations` is a **public group**, and a group Id is not a valid value for a User lookup. There is no "the IR owner" anywhere in the schema. Options considered and rejected: picking an arbitrary group member (non-deterministic, and wrong the moment membership changes); a Custom Setting holding a default User Id (a User Id is org-specific, so custom-setting *data* is not deployable and the value would silently be null on every org but one).

🔴 **Consequence of leaving it null — and it is bigger than the field.** `Offering__c` is Private OWD with **zero sharing rules**. The new row is owned by whoever executed the PSA (an acquisitions persona). IR sees it **only** if IR holds a permission set carrying `viewAllRecords` on `Offering__c` — today only `DPEG_Acquisition_Edit` / `DPEG_Acquisition_View`. If the IR team does not hold an acquisitions permission set, **the FSD's "Offering shell" is created and is invisible to the exact team it is for**, with no error anywhere. → **OPEN QUESTION Q1.2.**

## `Primary_Offering__c` — DO NOT ADD

The FSD does not ask for one. `Primary_LOI__c`'s stamp is load-bearing **only** because `ApprovalAuditService` resolves its LOI target through it and swallows its own failures; nothing resolves an Offering. `DispositionStageEntryService`'s LOI/PSA blocks deliberately carry no parent stamp for the same reason. The `Offerings` child relationship (`relationshipName Offerings`) already gives the related list. Adding one would also import the approval-lock / deferred-stamp analysis for no benefit.

## Governor budget

**+1 SOQL / +1 DML per trigger chunk, CONSTANT in deal count.** A chunk in which no PSA became `Executed` costs zero of both (the existing `executedOppIds.isEmpty()` early return in `stampOpportunities` already short-circuits).

## Testing

`ContractReviewTrigger` is a real trigger ⇒ `.claude/rules/bulk-test-rule.md`'s **251-record** mandate applies with no exemption. Required:
- 251 Contract Reviews transitioning to `Executed` in one chunk → 251 Offerings, 1 SOQL, 1 DML.
- Re-execution is a no-op (zero second Offerings).
- A disposition PSA (`Disposition__c` set, `Opportunity__c` null) creates **no** Offering.
- A mixed chunk (acquisition + disposition) creates Offerings only for the acquisition half.

---

# ITEM 2 — NDA expiry reminders (5 / 2 days)

## Established / verified

| Fact | Status |
|---|---|
| Nothing implements this — no flow, no batch, no schedulable | ✅ verified |
| `NDA__c.NDA_Expiry_Date__c` is a plain **Date**, no default, nothing computes it | ✅ verified |
| `NDA__c.Is_Non_Expiring__c` is a Checkbox, `defaultValue false` | ✅ verified |
| `NDA__c.Status__c` restricted picklist, six values across two record-type sets; acquisition set = `Pending, Sent, Received, Signed` | ✅ verified |
| Precedent complete and live: `CallForOffersAlertBatch` + `CallForOffersAlertSchedule` + `CallForOffersService` + `OpportunitySelector.queryCallForOffersAlerts` + `GroupNotifier.notifyWithOutcome` | ✅ verified |
| `Acquisition` **queue** exists; `Acquisitions_Team` and `DPEG_Acquisitions_Team` **groups** also exist | ✅ verified — three candidates, see Q2.3 |
| `Acquisitions_Deal_Update` notification type exists and is the only type `GroupNotifier` uses | ✅ verified — no new type needed |
| `NDA__c` has **no trigger** and **no validation rules**. Two flows fire on it: `NDA_Signed_Status_Sync` (before-save) and `NDA_Signed_Rollup` (after-save) | ✅ verified |

## 🔴 FINDING A — the record-type filter the brief asked for would ship the feature INERT

The brief mandates scoping to the `Acquisition_NDA` record type. Correct intent, wrong mechanism:

ARCHITECTURE records that until post-deploy gate **T-A1 / T-B** every live NDA row sits on **Master**, not on a named record type (`RecordStageAdvanceService`'s null/Master fallback exists precisely for this window). A locator filtered `RecordType.DeveloperName = 'Acquisition_NDA'` therefore returns **zero rows** for every un-migrated acquisition NDA — the job runs daily, logs an all-zeros summary, and looks completely healthy.

**Use the PARENT LOOKUP as the discriminator: `Opportunity__c != NULL`.** This is not an invention — it is what `Contract_Review__c.Disposition__c`'s own field metadata mandates (*"this lookup, NOT the record type, is the discriminator anything outside the record page should test"*) and what `ContractExecutionService.handleExecution` uses, for reason 2 in its own header: *"It WORKS DURING THE MIGRATION WINDOW."* A disposition NDA carries `Disposition__c` and a null `Opportunity__c`, so the split is exact and survives the migration in both directions.

## 🔴 FINDING B — the SHARING half, and it is the difference between this job working and silently doing nothing

This is the one place the CFO precedent **must not** be copied verbatim.

- `OpportunitySelector.queryCallForOffersAlerts` is `WITH SYSTEM_MODE` on a `with sharing` class, and its header argues that `with sharing` is *sufficient* **because `Opportunity` internal OWD is `ReadWrite` (measured)**.
- `NDA__c` is **`sharingModel Private`**. Its only two sharing rules (`NDA_Disposition_Team_RW`, `NDA_Disposition_Principals_R`) are **criteria-scoped to `RecordTypeId = 'Disposition NDA'`**. There is **no sharing rule covering acquisition NDAs at all** — they are reachable only via `viewAllRecords = true` on an acquisitions permission set.
- ⇒ Under `with sharing`, a scheduling principal without an acquisitions permission set sees **only the NDAs they personally own**. The locator returns zero rows, `finish()` logs all-zeros, and that is **indistinguishable from "no NDA is expiring"**. This is the 2026-08-08 `InboundEmailStagingSelector.RoutingReads` incident, one module later.

**Required, both halves:**
1. The **read** goes in a `private without sharing` inner class — `NdaSelector.ExpiryAlertReads` — holding only that query. Never `without sharing` on `NdaSelector`, which backs five user-facing reads.
2. The **stamp write** has the same problem and it is not covered by the read fix. `SYSTEM_MODE` lifts CRUD/FLS and **never** sharing, and a Private-OWD `update` by a non-owner is **refused**. A silently refused stamp means the job re-alerts the same NDA every single day forever. Mirror `InboundEmailStagingService.RoutingWrites`: a `without sharing` writer holding only that update.

## Design

### ADMIN — two new fields on `NDA__c` (both required; see P5)

| Field | Type | Purpose |
|---|---|---|
| `NDA_Alert_Last_Interval__c` | Number(2,0) | the smallest ladder rung already notified. Monotone ⇒ a missed day catches up, a double run is a no-op. ⚠ arrives in Apex as a **Decimal** — cast with `.intValue()` (the CFO batch carries a comment about exactly this). |
| `NDA_Alert_Expiry_Date__c` | Date | 🔴 the SNAPSHOT of the expiry date the marker was computed against. When it differs from the live expiry the marker is treated as blank and the whole ladder **re-arms**. Without it, extending an NDA's expiry silently guarantees it is never alerted again. |

- Naming conforms to §1 rule 9 (`_Date__c` for a Date field; a Number named for a count/interval).
- **FLS:** grant in the permission set files where the *sibling* `NDA__c` fields already live — `DPEG_Acquisition_Edit` (editable), `DPEG_Acquisition_View` (readable), and `DPEG_Admin_Access` if it carries the other NDA fields. ⚠ `PermissionSet` deploys **REPLACE** their `<fieldPermissions>` set; a grant that is not declared in-file is wiped by the next deploy of that file (paid twice on this project). ⚠ Metadata-API-deployed fields arrive with **no** FLS for any profile including System Administrator — which is the FLS half of why both reads and writes are SYSTEM_MODE.

### DEVELOPER — four Apex classes + one selector method

1. **`NdaExpiryService`** — the pure ladder and the idempotency rule, mirroring `CallForOffersService`:
   - `evaluate(Date expiry, Date asOf)` → pure, no SOQL/DML, clock is an argument.
   - `shouldFire(Integer dueInterval, Integer lastInterval, Date liveExpiry, Date markerExpiry)` → pure.
   - `ALERT_INTERVALS = {5, 2}` lives here and **nowhere else**.
   - Why a service for one consumer today: the intervals are the thing the FSD calls configurable, so they need exactly one home; and `OpportunityDocStatusController` / the `NDAs_Expiring_This_Month` report are plausible second consumers. Same argument the CFO service's header makes.
2. **`NdaSelector.queryExpiryAlerts()`** → `Database.QueryLocator`, `WITH SYSTEM_MODE`, inside `private without sharing class ExpiryAlertReads`.
   ```
   WHERE NDA_Expiry_Date__c != NULL
     AND NDA_Expiry_Date__c <= :ceiling          // TODAY + 5, the widest rung
     AND Is_Non_Expiring__c = FALSE
     AND Opportunity__c != NULL                  // ← the discriminator; NOT RecordType (Finding A)
     [AND Status__c = 'Signed']                  // ← pending Q2.1
   ORDER BY NDA_Expiry_Date__c ASC, Id ASC
   ```
   - **Ceiling only, no floor** — copy the CFO reasoning verbatim: an NDA whose expiry already passed with no marker genuinely is owed its one alert; a floor would silence it. Once interval `2` is stamped the strictly-smaller test can never pass again, so overdue rows cost one row per pass and never spam.
   - ⚠ The `+ 5` is duplicated knowledge (a `QueryLocator` cannot bind an Apex collection). It is a **ceiling**, not a threshold — widening it is free, narrowing it below the widest rung is the only way to break the feature. Whoever adds a rung above 5 must widen it.
   - ⚠ `NdaSelector`'s class header currently states its mode policy per method; it must be amended in place (it already carries one `SYSTEM_MODE` method, `selectByDispositionIds`).
3. **`NdaExpiryAlertBatch`** (`Database.Batchable`, `Database.Stateful`):
   - `SCOPE = 200`, **inherited from `CallForOffersAlertBatch` rather than re-measured.** That is legitimate and should be stated as such: the measured cost model is `6.0 ms + 0.22 ms × |recipients|` **per notification**, which is a property of `Messaging.CustomNotification.send()` and not of the object being alerted on. Do not re-run the probes; do cite them.
   - 🔴 **SEND FIRST, STAMP SECOND**, via `GroupNotifier.notifyWithOutcome(...)`, stamping only the rows whose send succeeded. A notification is not transactional; stamp-then-send loses an alert **silently and forever**, send-then-stamp merely repeats it tomorrow.
   - Stamp: `Database.update(toStamp, false, AccessLevel.SYSTEM_MODE)` **from a `without sharing` writer** (Finding B).
   - One `asOf`, captured once per `execute()` — never `Date.today()` per record.
   - Fail-soft per chunk (a batch has no Finalizer).
4. **`NdaExpiryAlertSchedule`** (Schedulable, daily) — no logic, starts the batch at `NdaExpiryAlertBatch.SCOPE`.

- **Recipient:** `Acquisition` queue (matching `CallForOffersAlertBatch.RECIPIENT_GROUP`), pending Q2.3. Keep it a **non-`final` `@TestVisible` static** — that is the only way to reproduce a swallowed send failure, which is the branch proving a failed alert is not stamped.
- **`targetRecordId`:** the `NDA__c` Id. ⚠ Recipients must be able to open it — same Private-OWD story; acquisitions personas hold `viewAllRecords`, so this is fine today, but it is worth one line in the class header.
- ⚠ The marker update will **re-fire `NDA_Signed_Status_Sync` and `NDA_Signed_Rollup`**. `NDA__c` has no trigger and no validation rules, so there is no recursion apparatus to add — but the implementer must confirm `NDA_Signed_Rollup` is criteria-scoped and does not run a cross-module rollup for an acquisition NDA whose `Disposition__c` is null.

### Testing
251-row bulk test on the locator (`.claude/rules/bulk-test-rule.md`; a test method runs one chunk, so at SCOPE 200 a 251-row fixture proves the locator selects/filters/orders 251 rows and a full 200-row chunk behaves). Plus: a disposition NDA is never selected; an `Is_Non_Expiring__c = true` NDA is never selected; a missed day catches up; a double run is a no-op; **an extended expiry re-arms the whole ladder** (the falsifier for dropping the snapshot field); a failed send is not stamped. Governor assertions must read counters captured **inside** the async context, never `Limits.*` after `Test.stopTest()`.

---

# ITEM 3 — Two validation rules

## FSD Rule 2 — "Broker First-Seen Timestamp is system-set and cannot be edited"

### 🔴 The FSD names a field that does not do the job. Recommend re-targeting.

There are two candidate fields and they are not interchangeable:

| Field | Type | Written by | Read by | Verdict |
|---|---|---|---|---|
| **`Lead.First_Seen_Date__c`** | DateTime | `Lead_Intake_Stamp` (before-save, CreateAndUpdate, **only when blank**); `BrokerPortalService` (guest insert) | `Lead.BP_Expiry__c` = `First_Seen_Date__c + 90` — **the 90-day broker protection**; `Days_in_System__c`; `LeadSelector` ordering; `LeadFunnelController`; Lead Funnel Path; Lead record page | ✅ **This is the field FSD §12 broker protection actually runs on. Build the rule here.** |
| `Opportunity.Broker_First_Seen__c` | Date | **NOTHING** (P3) | `CallForOffersService` as `dealArrivedDate`; `OpportunitySelector` | ❌ permanently blank. A VR here would lock a blank field and **remove the only way it can ever be populated** — a human typing it. Strictly worse than doing nothing. |

### Recommended rule — on `Lead`

```
AND(
  ISCHANGED(First_Seen_Date__c),
  NOT(ISBLANK(PRIORVALUE(First_Seen_Date__c)))
)
```

**Why this satisfies trap (b) without a special case:**

| Writer | Fires the rule? | Outcome |
|---|---|---|
| Any INSERT (`BrokerPortalService`, the inbound-email pipeline, manual, Data Loader) | `ISCHANGED` is false on insert | ✅ unaffected |
| `Lead_Intake_Stamp` (before-save, assigns **only when `IsNull`**) | ✅ fires, and prior value is blank | ✅ exempt by the second clause — the exemption falls out of the formula rather than needing a carve-out |
| `Database.convertLead` | only when `shouldLeadConvertRequireValidation` is true | inert either way: conversion does not change this field. ⚠ that setting lives in `settings/LeadConfig.settings-meta.xml`, which is `.forceignore`d and is an **unverified snapshot** — verify in Setup, do not design on the file |
| Manual edit / inline edit / API / Data Loader on an already-stamped Lead | ✅ fires | ✅ **this is the population the rule exists for** |

- `errorDisplayField`: `First_Seen_Date__c`.
- Full rationale goes in an **XML comment inside the root element**, not `<description>` (capped at 255; and a comment above the root breaks `sf` deploy with a misleading "unable to find matching parent xml file"). House precedent: `Contract_Signed_Before_Closed_Won`.
- **Bypass: recommend NONE.** The rule's entire purpose is anti-tampering; an admin bypass re-opens it for the population most able to tamper, and a genuine data correction has an auditable path (deactivate the rule). → **Q3.1.** If the user wants one, it **must** be a Custom Permission (`Broker_First_Seen_Override`) — **never** a field reference (ARCHITECTURE §5: a rule bound to a field evaluates false for anyone lacking FLS on it, silently; that is why the `*_Driver__c` model was retired org-wide on 2026-08-12).
- ⚠ FLS and the VR are **complementary, not alternatives**: FLS on a writable field does not stop the Data Loader path for a user who has the grant; the VR does.

---

## FSD Rule 5 — "Contract Executed Date cannot be populated unless the related PSA is Executed"

### (a) Which field arms the fan-out — RESOLVED, and the FSD is wrong

`flows/Transaction_Task_Fanout.flow-meta.xml`:
```
<object>Transaction__c</object>
<triggerType>RecordAfterSave</triggerType>
<filters> Contract_Executed_Date__c IsNull = false
          Tasks_Fanned_Out__c EqualTo false </filters>
```
**The fan-out is armed by `Transaction__c.Contract_Executed_Date__c`, not the Opportunity's.** An Opportunity VR does not prevent it firing early.

**What the Opportunity rule does buy, stated honestly:** `openTransactionsOnAboutToClose` reads `Opportunity.Contract_Executed_Date__c` and copies it into `Transaction__c.Contract_Executed_Date__c` as **Day 0**, and every one of the ~75 checklist tasks is dated by offset from it. So a hand-typed Opportunity date produces a **wrongly-dated** checklist — every deadline silently shifted — not an early one. That is a real defect worth preventing.

**Recommendation:** build on **Opportunity**, as the FSD literally asks, and **correct the rationale in the rule's own XML comment** rather than propagating a wrong mechanism into the metadata. Do **not** also build a `Transaction__c` rule in this tranche: its field is set at INSERT by `openTransactionsOnAboutToClose` with `allOrNone = true` inside an Opportunity after-update trigger, so a block there rolls back the deal's own stage change, and the rule would need a two-hop `Opportunity__r.Primary_Contract__r.Negotiation_Status__c`. Flag it as a candidate follow-up, priced separately.

### (c) Cross-object reference and ordering

- ✅ The status field is `Contract_Review__c.Negotiation_Status__c`. **Not `Stage__c`**, which `Contract_Review_Stage_Sync` (before-save) recomputes on every save — a direct write commits and is silently discarded (measured on CTR-0000, recorded repo trap).
- Path from Opportunity: `Primary_Contract__r.Negotiation_Status__c`.
- **Ordering — probably safe, must be PROVEN not assumed.** `stampOpportunities` runs from `ContractReviewTrigger` **after update**, i.e. after the Contract Review row is written to the database within the transaction, so a cross-object formula should evaluate against `'Executed'`. 🔴 If it does not, `Database.update(oppUpdates, true, SYSTEM_MODE)` (all-or-none) throws inside an after-update trigger and **rolls back the entire PSA execution**. The falsifier is cheap and already exists: `ContractExecutionServiceTest` executes a PSA end-to-end and asserts the stamp. **A green `ContractExecutionServiceTest` after the rule is deployed is the proof.** Do not ship without running it.

### 🔴 (c-2) THE LARGER ORDERING HAZARD THE BRIEF DID NOT NAME — `Primary_Contract__c` may be blank

`OpportunityReviewService` stamps `Primary_Contract__c` only for the Contract Review **it** creates on entry to `Under Contract (PSA)`. A Contract Review created any other way — by hand, by a data load, on a deal that reached PSA by an unusual route — executes without ever being the primary. Then `Primary_Contract__r.Negotiation_Status__c` is blank, the VR fires, the all-or-none update throws, **and the PSA execution rolls back**.

**The rule must exempt a blank primary contract:**
```
AND(
  ISCHANGED(Contract_Executed_Date__c),
  NOT(ISBLANK(Contract_Executed_Date__c)),
  NOT(ISBLANK(Primary_Contract__c)),
  TEXT(Primary_Contract__r.Negotiation_Status__c) <> "Executed"
)
```
⚠ **State the cost, do not hide it:** the rule is then unenforceable on exactly the deals with no primary contract — it protects the ordinary path and fails **open** on the irregular one. That is the correct trade (a rolled-back PSA execution is worse than an unguarded manual date on an irregular deal), but it is a decision, not an oversight.

⚠ **And there is a second reason the exemption is mandatory rather than optional.** `stampOpportunities` has **no catch at all**, so a `DmlException` propagates out of the trigger. A user executing the PSA through the Advance Stage action hits `RecordStageAdvanceController`, which converts **every** exception into one fixed generic string — so the user would see "This change could not be saved" with no clue why, and the rule's text would never reach them. (Recorded pattern: designed refusals need their own catch; a VR on a record whose write path is Apex is invisible.)

### Writers this rule meets

| Writer | Fires? | Notes |
|---|---|---|
| `ContractExecutionService.stampOpportunities` (Apex update, all-or-none, SYSTEM_MODE) | ✅ **and a block is FATAL** | `AccessLevel.SYSTEM_MODE` bypasses CRUD/FLS, **not** validation rules. The primary hazard. |
| Manual / inline edit / Data Loader | ✅ | the population the rule exists for |
| `Transaction_Complete_Close` | ❌ | verified: `Transaction_Task_Fanout` is the **only** flow in the repo referencing `Contract_Executed_Date__c` |
| Approval-process field updates | ❌ | measured — approval field updates do not run VRs in this org |
| INSERT | ❌ | `ISCHANGED` is false on insert — a deliberate hole, same as the deployed NDA rule. State it. |

- `errorDisplayField`: `Contract_Executed_Date__c`.
- **Bypass: recommend NONE.** The needed exemptions are structural (blank primary contract), not persona-based. → **Q3.2.**

---

# 🔵 ADMIN WORK (`salesforce-admin`)

| # | Item | Detail |
|---|---|---|
| A1 | **`NDA__c.NDA_Alert_Last_Interval__c`** | Number(2,0), not required, no default. Description must say it is a system-maintained alert marker and is not for manual entry. |
| A2 | **`NDA__c.NDA_Alert_Expiry_Date__c`** | Date, not required, no default. Description must say it is the snapshot the marker was computed against and that clearing it re-arms the ladder. |
| A3 | **FLS for A1 + A2** | Declared **in-file** in the permission sets that already carry the sibling `NDA__c` field grants (`DPEG_Acquisition_Edit` editable, `DPEG_Acquisition_View` readable, `DPEG_Admin_Access` if it carries the others). ⚠ `PermissionSet` deploys REPLACE their `<fieldPermissions>` set — reconcile org → repo before editing any of these files. |
| A4 | **VR `Lead.Broker_First_Seen_Is_System_Set`** | Formula, error field and long XML-comment rationale exactly as in Item 3 Rule 2. ⚠ comment must sit **inside** the root element. |
| A5 | **VR `Opportunity.Executed_PSA_Before_Contract_Date`** | Formula, error field and long XML-comment rationale exactly as in Item 3 Rule 5 — **including the correction that the fan-out is armed by `Transaction__c`, not this field**. |
| A6 | *(conditional on Q1.2)* IR visibility on `Offering__c` | Either a criteria/owner sharing rule sharing `Offering__c` to `Investor_Relations`, or an IR permission set carrying `viewAllRecords`. ⚠ Deploy sharing rules **ONE AT A TIME** — a batch deploy rolls all of them back in this org. Not in scope unless the user says yes. |

**Complexity routing: `salesforce-admin`.** Two fields, three FLS edits and two validation rules are routine declarative work. No multi-object schema design, no OWD/sharing-model design, no subflow orchestration. (A6, if taken, is one sharing rule — still `salesforce-admin`.)

---

# 🟢 DEVELOPMENT WORK (`salesforce-developer`)

| # | Item | Detail |
|---|---|---|
| D1 | **`OfferingSelector`** (new) | First and only `Offering__c` SOQL in the application — name and document it as such, following `AccountSelector` / `OpportunityContactRoleSelector`. One method: `selectByOpportunityIds(Set<Id>)`, `WITH SYSTEM_MODE`, inside `private without sharing class ExecutionHandoffReads`. Outer class `with sharing`. |
| D2 | **`OfferingService`** (new) | `ensureOnPsaExecuted(Set<Id> executedOppIds)`. Idempotent on `Opportunity__c` alone. `Database.insert(..., allOrNone, AccessLevel.SYSTEM_MODE)` — `allOrNone` per Q1.1. Sets `Opportunity__c` + `Status__c = 'Draft'` explicitly; leaves `IR_Owner__c` null. |
| D3 | **`ContractExecutionService`** (edit) | One call to `OfferingService.ensureOnPsaExecuted(executedOppIds)` **inside `stampOpportunities`**, after the Opportunity update. Placing it there is what makes ACQUISITION-ONLY structural (P2). Do **not** add a notification — IR is already notified. |
| D4 | **`NdaExpiryService`** (new) | Pure ladder + idempotency. `ALERT_INTERVALS = {5, 2}` lives here and nowhere else. |
| D5 | **`NdaSelector.queryExpiryAlerts()`** (edit) | `Database.QueryLocator`, `WITH SYSTEM_MODE`, in `private without sharing class ExpiryAlertReads`. Discriminator is `Opportunity__c != NULL`, **not** the record type (Finding A). Amend the class header's mode policy in place. |
| D6 | **`NdaExpiryAlertBatch`** (new) | `Database.Batchable, Database.Stateful`. `SCOPE = 200` **inherited** from `CallForOffersAlertBatch` with the citation, not re-measured. Send-then-stamp via `notifyWithOutcome`. Stamp write must escape sharing (Finding B). |
| D7 | **`NdaExpiryAlertSchedule`** (new) | Schedulable, daily. No SOQL, no DML, no logic. |
| D8 | **Regression tests pinning the two VRs** | `ContractExecutionServiceTest` must stay green with A5 deployed (that IS the ordering proof). Add: a Lead whose blank `First_Seen_Date__c` is stamped by `Lead_Intake_Stamp` on update still saves; an already-stamped Lead's manual change is refused; a PSA execution on a deal with a **blank** `Primary_Contract__c` still executes. |
| D9 | **ARCHITECTURE.md** (edit, same PR — §6) | §1 `Offering__c` row gains a Purpose + creator; §2 Key Apex Services gains `OfferingService`, `NdaExpiryService`, `NdaExpiryAlertBatch`, `NdaExpiryAlertSchedule`; the `WITH SYSTEM_MODE` table gains three rows (the Offering guard read, the NDA locator, the NDA marker write) with their own justifications; the selector/class counts are updated. |

**Complexity routing: `salesforce-developer`.** Standard Apex service + selector + batch + schedulable, all following an in-repo precedent that is already built and documented. No integration, no Named Credentials, no LDV, no Platform Events, no callouts. **Not** `salesforce-technical-architect`.

**Unit testing:** `salesforce-unit-testing` after D1–D8 (251-record bulk mandate applies to Item 1's trigger path and Item 2's locator; no exemption applies to either).

---

# 🔗 EXECUTION ORDER

1. **A1 + A2 + A3** (NDA marker fields + FLS) — D5/D6 select and write these fields; Apex will not compile without them.
2. **D1 → D2 → D3** (Item 1) — selector before service before the trigger-path edit. Independent of Item 2.
3. **D4 → D5 → D6 → D7** (Item 2) — service (the ladder) before the selector method before the batch before the schedule.
4. **A4 + A5** (the two VRs) — deploy **after** D3, because A5 is exercised by the existing `ContractExecutionServiceTest` and by D3's new Offering insert path in the same transaction.
5. **D8** (regression pinning) — immediately after A4/A5; a green run here is the ordering proof for Rule 5.
6. **D9** (ARCHITECTURE.md) — same PR, per §6.
7. **A6** — only if the user answers yes to Q1.2.

---

# ❓ OPEN QUESTIONS — USER DECISION REQUIRED (Gate 1)

| # | Question | Options | Recommendation |
|---|---|---|---|
| **Q1.1** | Should a failed Offering insert roll back the PSA execution? | (a) `allOrNone = false` — the Offering is skipped, execution stands, **no signal anywhere**; (b) `allOrNone = true` — a refused insert rolls back `Contract_Signed__c`, Day 0 and the three notifications | **(a)**. The repo precedent cuts both ways (`advanceDispositionsToClosing` chose soft, `PropertyAssetService` chose hard); the deciding fact is that the executed PSA is the irreplaceable half and an Offering shell is recoverable by hand. |
| **Q1.2** | 🔴 Does the IR team hold an acquisitions permission set? | `Offering__c` is **Private OWD with zero sharing rules**. If IR holds none, the Offering shell is created and is **invisible to IR** — no error, nothing to notice. Options: (a) confirm IR already holds `DPEG_Acquisition_View` → no work; (b) add a sharing rule to the `Investor_Relations` group (A6); (c) accept the invisibility and record it as a residual | **Answer (a) first by checking the org.** This is the single question that decides whether Item 1 delivers the FSD's intent or a hidden record. |
| **Q2.1** | Should a **SIGNED** NDA still get expiry reminders? | (a) Signed only; (b) unsigned only (chase-the-counterparty reading); (c) any NDA with an expiry date | **(a) Signed only.** This is not a guess — the deployed `Acquisitions/NDAs_Expiring_This_Month` report, the only existing expiry-tracking surface in the repo, filters `Status__c equals Signed` AND `Is_Non_Expiring__c = 0`. Matching it means the report and the alert cannot disagree about which NDAs are expiring. Confirm, or the two surfaces diverge on day one. |
| **Q2.2** | "Configurable" intervals — Custom Setting or Apex constant? | (a) hardcoded in `NdaExpiryService`; (b) a hierarchy Custom Setting | **(a) hardcoded.** Three reasons: custom-setting **data is not deployable**, so a config-driven design adds a post-deploy gate whose omission leaves the ladder empty or silently defaulted; both existing Custom Settings in this repo exist because `getOrgDefaults()` costs 0 SOQL on a **hot** path (an after-update trigger, a per-file job) — a once-daily batch has no such pressure, so the precedent's own justification does not transfer; and an admin editing an alert ladder with no deploy and no review is the same hole `RecordStageAdvanceService` cites for keeping its stage map in Apex. **Cost, stated:** changing 5/2 then requires a one-constant code change + deploy. The FSD says "adjusted later as needed", not "adjusted by an admin". |
| **Q2.3** | Who is "the Acquisition Team"? | Three live candidates: the **`Acquisition` queue**, the `Acquisitions_Team` group, the `DPEG_Acquisitions_Team` group | **The `Acquisition` queue**, matching `CallForOffersAlertBatch.RECIPIENT_GROUP = 'Acquisition'` — the only other alert job in the app. ⚠ Queue membership is **not deployable metadata** and the `Acquisition` queue was measured at **one member**; confirming the membership is the intended alerting population is a post-deploy gate. |
| **Q3.1** | Admin bypass on the broker first-seen rule? | (a) none; (b) a `Broker_First_Seen_Override` **Custom Permission** | **(a) none.** The rule is anti-tampering; a bypass re-opens it for the population most able to tamper, and a genuine correction has an auditable path (deactivate the rule). If (b): it **must** be a Custom Permission, never a field reference. |
| **Q3.2** | Admin bypass on the contract-executed-date rule? | (a) none; (b) a Custom Permission | **(a) none.** The needed exemption is structural (blank `Primary_Contract__c`), not persona-based. |
| **Q3.3** | 🔴 Accept the re-target of FSD Rule 2 from `Opportunity.Broker_First_Seen__c` to `Lead.First_Seen_Date__c`? | (a) accept — build on Lead; (b) build on Opportunity as literally written | **(a).** Nothing writes the Opportunity field (P3), so a VR there locks a permanently-blank field and removes the only way it can ever be populated. Building it as written produces a rule that is provably worse than no rule. |
| **Q3.4** | Accept that FSD Rule 5's stated rationale is wrong, and build the Opportunity rule for the **mis-dated-checklist** benefit instead of the **early-fan-out** one? | (a) accept, correct the rationale in the rule's XML comment; (b) also build the `Transaction__c` rule that would actually gate the fan-out | **(a) for tranche 1.** (b) is a real follow-up but its field is set at INSERT with `allOrNone = true` inside an Opportunity after-update trigger, so a block there rolls back the deal's stage change — it needs its own design pass. |

---

# 🚦 POST-DEPLOY GATES (job instances and memberships are not deployable metadata)

| # | Gate | Failure mode if skipped |
|---|---|---|
| **G1** | 🔴 **Schedule `NdaExpiryAlertSchedule`** (daily, early). Record the cron expression **and the owning user**. `System.schedule('DPEG NDA Expiry Alert', '0 0 7 * * ?', new NdaExpiryAlertSchedule());` | The class deploys, compiles, tests and covers, and is **completely inert**. Zero alerts, zero errors, zero failed `AsyncApexJob` rows. Worse than the sweepers this resembles: they leave rows on a `Failed` status a human can list; an unscheduled alert job leaves **no trace at all**, and "no alert arrived" is indistinguishable from "no NDA was expiring". Verify in Setup. |
| **G2** | 🔴 **Confirm the schedule owner's `NDA__c` visibility.** Even with the `without sharing` inner classes, verify the owner and re-verify when that user is deactivated. | If Finding B's `without sharing` remedy is watered down in review, an ungranted owner produces an all-zeros `finish()` summary indistinguishable from a healthy pipeline. |
| **G3** | **Confirm `Acquisition` queue membership** is the intended alerting population (measured at **one** member). Queue membership is not deployable and no test can see it. | Alerts fire to one person, or to nobody. |
| **G4** | 🔴 **Confirm IR's `Offering__c` visibility** (Q1.2). Verify by **opening an Offering as an IR user**, not as an administrator. | Offering shells are created and are invisible to IR. No error. |
| **G5** | **Run `ContractExecutionServiceTest` after A5 deploys.** | If a cross-object VR does not see the in-transaction `'Executed'` status, every PSA execution rolls back — and the only surface a user sees is `RecordStageAdvanceController`'s fixed generic "could not be saved". |
| **G6** | **Verify `settings/LeadConfig.settings-meta.xml` → `shouldLeadConvertRequireValidation` in Setup**, not in the repo (`settings/**` is `.forceignore`d and is an unverified snapshot). | Rule 2 is inert at conversion either way (conversion does not change the field), but the assumption must be checked rather than inherited. |
| **G7** | **Reconcile each touched permission set against the org before deploying it** (A3). | A `PermissionSet` deploy REPLACES its `<fieldPermissions>` set — an org-side-only grant absent from the file is silently wiped. Paid twice on this project. |

---

# 🚩 FLAGGED — RE-SCOPE / DROP RECOMMENDATIONS

| Item | Flag |
|---|---|
| **Item 3, FSD Rule 2 as literally written** | 🔴 **DROP the Opportunity version, build the Lead version.** A VR on `Opportunity.Broker_First_Seen__c` locks a field nothing writes and blocks the only route to populating it. See Q3.3. |
| **Item 3, FSD Rule 5's rationale** | ⚠ **Correct, do not propagate.** The rule is worth building; its stated purpose is factually wrong (P4). The corrected rationale belongs in the rule's own XML comment. |
| **Item 2's record-type scoping** | ⚠ **Re-specify** from `RecordType.DeveloperName = 'Acquisition_NDA'` to `Opportunity__c != NULL`. The record-type version ships the feature inert until post-deploy gate T-A1/T-B (Finding A). |
| **Item 2's guard field** | ⚠ **Widen from one field to two.** Without `NDA_Alert_Expiry_Date__c`, extending an NDA's expiry silently guarantees it is never alerted again (P5). |
| **Item 1's DML mode** | ⚠ The brief's premise (measure the persona) was right; the **answer differs from `Transaction__c`** — the acquisitions persona *does* hold Create on `Offering__c`. `SYSTEM_MODE` is still recommended, for a different and narrower reason. |

## Findings OUT OF SCOPE — reported, not folded in

1. **`Opportunity.Broker_First_Seen__c` is a dead field whose `<description>` asserts behaviour that does not exist** ("Copied from Lead at Conversion 1 - drives 90-day protection"). The FSD's own "Conv 1" carry-forward appears to be a **separate unimplemented gap**. The complete fix for Rule 2's intent is to *implement the copy* and then lock it — that is a tranche-2 candidate, not a silent scope expansion here.
2. **A `Transaction__c.Contract_Executed_Date__c` rule** is what would actually gate the fan-out. Needs its own design pass (Q3.4b).
3. **`Offering__c` has no record page, no path, no tab assignment outside `DPEG_Admin_Access`, and no lifecycle automation.** Creating the shell is the FSD's ask; nothing advances `Status__c` from `Draft` afterwards. Worth naming so "the Offering never leaves Draft" is not later read as a defect in this tranche.
4. **`NDA_Expiry_Date__c` is a plain manual Date that nothing computes.** The reminders are only as good as the human who typed it. No derivation is requested and none is proposed.
5. **The `Offering_IR_Visibility` sharing rule (Q1.2 follow-up) is owner-based and only reaches Offerings owned by `roleAndSubordinates: Acquisitions_Analyst`.** The role hierarchy is `DPEG_Principal` at the top with three children — `Acquisitions_Analyst`, `Investor_Relations_Manager`, `Transactions_Coordinator`. An `Offering__c` is owned by whichever user executed the PSA (`ContractExecutionService` inserts it in that user's context with no explicit `OwnerId`), so an Offering created by a user **outside** the `Acquisitions_Analyst` branch — a principal at `DPEG_Principal` itself, a System Administrator, or anyone in the other two branches — is **not shared to `Investor_Relations` by this rule**, and IR simply cannot see it. **This fails silently**: no error, no failed job, nothing in the UI. It is a real path, not a hypothetical one — both `DPEG_Acquisition_Edit` and `DPEG_Admin_Access` grant `Contract_Review__c` edit, so an administrator doing UAT or a data fix, or a principal executing a PSA directly, both reach this gap. **This was a Gate-1 choice, decided 2026-08-16**: offered against a criteria-based rule matching every `Offering__c` record regardless of owner, and the user chose to keep the narrower owner-based rule and accept the residual. The full rationale and the remedy (switch to a criteria-based, all-records rule granting Edit to the same group) are recorded as an XML comment inside `force-app/main/default/sharingRules/Offering__c.sharingRules-meta.xml`.

---

# 📝 PROMPTS FOR SPECIALIST AGENTS

## 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md and .claude/rules/* first. Work on branch
feature/acquisitions-fsd-tranche-1. Create metadata files only — DO NOT DEPLOY.
API version 67.0. Package directory force-app/main/default.

1. Two new custom fields on NDA__c:
   - NDA_Alert_Last_Interval__c : Number, precision 2, scale 0, not required, no
     default value. Description: system-maintained expiry-alert marker holding the
     smallest ladder rung already notified; not for manual entry.
   - NDA_Alert_Expiry_Date__c : Date, not required, no default value. Description:
     the expiry date the alert marker was computed against; when it differs from the
     live NDA_Expiry_Date__c the marker is treated as blank and the whole reminder
     ladder re-arms. Clearing this field re-arms the ladder.

2. FLS for both fields, declared IN FILE, in the permission sets that already carry
   the sibling NDA__c field grants: DPEG_Acquisition_Edit (editable=true,
   readable=true), DPEG_Acquisition_View (editable=false, readable=true), and
   DPEG_Admin_Access if it carries the other NDA__c fields.
   ⚠ A PermissionSet deploy REPLACES its entire <fieldPermissions> set. Reconcile
   each file against the org before editing it and do not drop any existing entry.

3. Validation rule on Lead, fullName Broker_First_Seen_Is_System_Set, active:
     AND(
       ISCHANGED(First_Seen_Date__c),
       NOT(ISBLANK(PRIORVALUE(First_Seen_Date__c)))
     )
   errorDisplayField: First_Seen_Date__c
   errorMessage: user-safe, states the field is set automatically when the lead is
   first seen and cannot be changed afterwards.
   Put the full rationale in an XML COMMENT INSIDE the root <ValidationRule> element
   (never above it — that breaks sf deploy at source conversion; and <description> is
   capped at 255 chars). Follow the house precedent in
   objects/Opportunity/validationRules/Contract_Signed_Before_Closed_Won. The comment
   must record: (i) which writers this rule meets — Lead_Intake_Stamp is a before-save
   flow that assigns only when the field IsNull, so the blank-prior clause exempts it;
   BrokerPortalService writes it at insert, and ISCHANGED is false on insert;
   (ii) that Database.convertLead only enforces Lead VRs when
   shouldLeadConvertRequireValidation is true, that this setting lives in a
   force-ignored file and must be verified in Setup, and that the rule is inert at
   conversion either way; (iii) that there is deliberately no bypass.

4. Validation rule on Opportunity, fullName Executed_PSA_Before_Contract_Date, active:
     AND(
       ISCHANGED(Contract_Executed_Date__c),
       NOT(ISBLANK(Contract_Executed_Date__c)),
       NOT(ISBLANK(Primary_Contract__c)),
       TEXT(Primary_Contract__r.Negotiation_Status__c) <> "Executed"
     )
   errorDisplayField: Contract_Executed_Date__c
   errorMessage: user-safe, states the contract executed date is set when the PSA is
   executed and directs the user to execute the PSA on the Contract Review first.
   Put the full rationale in an XML COMMENT INSIDE the root element, recording:
   (i) 🔴 THE FSD'S STATED RATIONALE IS WRONG — the Day-0 fan-out is armed by
   Transaction__c.Contract_Executed_Date__c (Transaction_Task_Fanout is RecordAfterSave
   on Transaction__c, filtered Contract_Executed_Date__c IsNull=false AND
   Tasks_Fanned_Out__c=false), NOT by this field. What this rule actually prevents is a
   MIS-DATED 75-task checklist: openTransactionsOnAboutToClose copies this field into
   Transaction__c as Day 0 and every task is offset from it;
   (ii) the field is Negotiation_Status__c, NOT Stage__c — Stage__c is recomputed by the
   before-save Contract_Review_Stage_Sync flow and direct writes commit and are silently
   discarded;
   (iii) 🔴 the NOT(ISBLANK(Primary_Contract__c)) clause is MANDATORY, not defensive:
   ContractExecutionService.stampOpportunities writes this field with
   Database.update(..., true, SYSTEM_MODE) inside a Contract_Review__c after-update
   trigger, and AccessLevel.SYSTEM_MODE does NOT bypass validation rules — so a deal
   whose Primary_Contract__c was never stamped would have its entire PSA execution
   rolled back. State the cost: the rule is unenforceable on deals with no primary
   contract, i.e. it fails OPEN there;
   (iv) ISCHANGED leaves a create-at-any-value hole on insert, deliberately, matching
   the deployed NDA rule;
   (v) approval-process field updates do not fire VRs in this org, and
   Transaction_Complete_Close does not write this field (verified: Transaction_Task_Fanout
   is the only flow referencing it);
   (vi) there is deliberately no bypass.

Do NOT add any other field, rule, permission set, page layout, flow, report or
sharing rule. Do not add a Primary_Offering__c field. Do not deploy.
```

## 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md and .claude/rules/* first. Work on branch
feature/acquisitions-fsd-tranche-1. API version 67.0. Do not deploy.
Use TestDataFactory (it already has createOfferings/createOffering). Every selector
method must be WITH USER_MODE unless justified at its own declaration.

=== ITEM 1 — Offering shell at PSA executed ===

1. NEW: OfferingSelector (with sharing). This is the FIRST AND ONLY Offering__c SOQL
   in the application — document it as such in the class header, following the
   AccountSelector / OpportunityContactRoleSelector precedent. One method:
     selectByOpportunityIds(Set<Id> opportunityIds) -> List<Offering__c>
   selecting Id and Opportunity__c only.
   🔴 It must live in a `private without sharing` inner class named
   ExecutionHandoffReads, and be WITH SYSTEM_MODE. Justify BOTH at the method, as two
   SEPARATE decisions:
     MODE — automation path; the read is made on the executing user's behalf, and a
     USER_MODE throw inside a Contract_Review__c after-update trigger escapes as
     CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and rolls back the PSA execution.
     SHARING — Offering__c is sharingModel Private and sharingRules/Offering__c is
     EMPTY. This read backs an IDEMPOTENCY GUARD, so a sharing-filtered read does not
     disable the feature, it INVERTS it: zero rows means "no Offering exists" and the
     service creates a DUPLICATE. Mirror PropertyAssetSelector.AssetCreationReads.

2. NEW: OfferingService (with sharing). One public method:
     ensureOnPsaExecuted(Set<Id> executedOppIds)
   - Empty-safe early return.
   - Idempotent on Opportunity__c ALONE, via OfferingSelector.selectByOpportunityIds.
     Never a second Offering for one Opportunity.
   - Builds Offering__c(Opportunity__c = <id>, Status__c = 'Draft'). Status__c is set
     EXPLICITLY and must never rely on the picklist's own <default>.
   - IR_Owner__c is left NULL — it is a User lookup and Investor_Relations is a public
     GROUP, so no IR owner is derivable. Record in the class header that Offering__c is
     Private OWD with zero sharing rules, so IR sees the row only if IR holds a
     permission set with viewAllRecords on Offering__c (today DPEG_Acquisition_Edit /
     _View) — a stated residual, confirmed as post-deploy gate G4.
   - DML: Database.insert(offerings, <ALL_OR_NONE>, AccessLevel.SYSTEM_MODE).
     <ALL_OR_NONE> is a user decision (Q1.1) — the recommendation is FALSE. Whichever
     is chosen, argue it in the header against BOTH in-repo precedents:
     advanceDispositionsToClosing chose allOrNone=false so a stage advance could not
     roll back a legal state; PropertyAssetService chose true because silent absence
     WAS the bug. If false, state the residual plainly: a failed insert leaves no
     Offering and NO SIGNAL — there is no sweeper.
   - Budget: 1 SOQL / 1 DML per call, CONSTANT in deal count. No SOQL or DML in loops.

3. EDIT: ContractExecutionService.stampOpportunities — add ONE call to
   OfferingService.ensureOnPsaExecuted(executedOppIds), after the Opportunity update.
   🔴 It goes INSIDE stampOpportunities and nowhere else: that set only ever receives
   Contract Reviews with a non-null Opportunity__c, so ACQUISITION-ONLY is structural
   and needs no new guard and no record-type test. Record in the header that the
   discriminator is the PARENT LOOKUP, never the record type (the same reason
   handleExecution gives: it works during the record-type migration window).
   DO NOT add a notification — IR is already notified at this exact moment via the
   existing batched GroupNotifier.notify() call. DO NOT add Primary_Offering__c.
   DO NOT re-add Transaction creation to this method.

=== ITEM 2 — NDA expiry reminders ===

Mirror the CallForOffers* feature exactly, EXCEPT where noted. Read
CallForOffersService, CallForOffersAlertBatch, CallForOffersAlertSchedule and
OpportunitySelector.queryCallForOffersAlerts before writing anything.

4. NEW: NdaExpiryService (with sharing) — the PURE ladder and the PURE idempotency
   rule. ALERT_INTERVALS = {5, 2} lives here and NOWHERE else.
     evaluate(Date expiryDate, Date asOf) -> a state DTO carrying daysRemaining,
       dueInterval (the smallest interval the countdown is still inside, null above
       the widest rung), a label and a one-sentence detail. No SOQL, no DML; the clock
       is an argument.
     shouldFire(Integer dueInterval, Integer lastInterval, Date liveExpiry,
                Date markerExpiry) -> Boolean. Pure.
       Fire only when dueInterval is STRICTLY SMALLER than the effective last interval,
       where effective = (markerExpiry == liveExpiry) ? lastInterval : null.
       🔴 The second field is NOT polish: without it, extending an NDA's expiry leaves
       the marker armed against a date that no longer exists and the ladder NEVER FIRES
       again, silently, on exactly the NDAs someone cared enough to extend.
   Fixed date formatting (never DateTime.format, which is locale/timezone dependent).

5. EDIT: NdaSelector — add queryExpiryAlerts() returning a Database.QueryLocator:
     SELECT Id, Name, Opportunity__c, NDA_Expiry_Date__c, Status__c,
            NDA_Alert_Last_Interval__c, NDA_Alert_Expiry_Date__c
     FROM NDA__c
     WHERE NDA_Expiry_Date__c != NULL
       AND NDA_Expiry_Date__c <= :ceiling        // Date.today().addDays(5)
       AND Is_Non_Expiring__c = FALSE
       AND Opportunity__c != NULL
       [AND Status__c = 'Signed']                 // include per user answer to Q2.1
     WITH SYSTEM_MODE
     ORDER BY NDA_Expiry_Date__c ASC, Id ASC
   🔴 It must live in a `private without sharing` inner class named ExpiryAlertReads.
   Amend NdaSelector's class header IN PLACE (it currently documents one SYSTEM_MODE
   method) and justify BOTH decisions at the method:
     DISCRIMINATOR — Opportunity__c != NULL, deliberately NOT
     RecordType.DeveloperName = 'Acquisition_NDA'. Until post-deploy gate T-A1/T-B
     every live NDA sits on MASTER, so a record-type filter returns ZERO rows and the
     job ships inert while looking healthy. The parent lookup is the discriminator
     Contract_Review__c.Disposition__c's own field metadata mandates and that
     ContractExecutionService uses, for exactly this migration-window reason.
     MODE — both marker fields are Metadata-API-deployed customs, which arrive with NO
     FLS for ANY profile including the deploying administrator, so USER_MODE breaks the
     job on day one for that administrator, silently.
     SHARING — 🔴 THIS IS THE DIVERGENCE FROM THE CFO PRECEDENT AND IT IS NOT OPTIONAL.
     queryCallForOffersAlerts argues `with sharing` is SUFFICIENT because Opportunity
     OWD is ReadWrite. NDA__c is sharingModel Private, and its only two sharing rules
     are criteria-scoped to RecordTypeId = 'Disposition NDA' — there is NO sharing rule
     covering acquisition NDAs. A scheduling principal without an acquisitions
     permission set sees only the NDAs they own, the locator returns zero rows, and
     finish() logs an all-zeros summary INDISTINGUISHABLE FROM A HEALTHY PIPELINE.
     That is the 2026-08-08 InboundEmailStagingSelector.RoutingReads incident.
   Note in the header that the `+ 5` is duplicated knowledge (a QueryLocator cannot bind
   an Apex collection), that it is a CEILING not a threshold, and that there is
   deliberately NO FLOOR (an NDA whose expiry already passed with no marker genuinely is
   owed its one alert; the monotone marker stops it spamming).

6. NEW: NdaExpiryAlertBatch (with sharing, Database.Batchable<SObject>,
   Database.Stateful). NOT Database.AllowsCallouts.
   - SCOPE = 200, INHERITED from CallForOffersAlertBatch.SCOPE with a citation, NOT
     re-measured. Say why the inheritance is legitimate: the measured cost model
     (6.0 ms + 0.22 ms x |recipients| per Messaging.CustomNotification.send()) is a
     property of the notification API, not of the object being alerted on.
   - RECIPIENT_GROUP = 'Acquisition' (the queue), a @TestVisible NON-final static so a
     send failure can be reproduced.
   - One Date asOf captured ONCE per execute(); never Date.today() per record.
   - Read the marker as a Decimal and cast with .intValue() — the field is Number(2,0).
   - 🔴 SEND FIRST, STAMP SECOND, via GroupNotifier.notifyWithOutcome(...), stamping
     ONLY the rows whose send succeeded. A notification is not transactional:
     stamp-then-send loses an alert silently and forever; send-then-stamp merely
     repeats it tomorrow.
   - Stamp: Database.update(toStamp, false, AccessLevel.SYSTEM_MODE).
     🔴 The write must ALSO escape sharing — SYSTEM_MODE lifts CRUD/FLS and NEVER
     sharing, and a Private-OWD update by a non-owner is REFUSED, which would make the
     job re-alert the same NDA every single day forever. Mirror
     InboundEmailStagingService.RoutingWrites.
   - Per-chunk statics for test assertions (evaluated/owed/notified/sendFailures/
     stamped) plus instance totals for finish(); the ExtractAddressQueueable
     .lastRunQueryCount precedent. Fail-soft per chunk with a catch, since a batch has
     no Finalizer.
   - Budget: 0 SOQL of its own, at most 1 DML, at most SCOPE notifications — all
     CONSTANT in chunk size. A chunk owing nothing costs zero DML and zero
     notifications.

7. NEW: NdaExpiryAlertSchedule (with sharing, Schedulable). No SOQL, no DML, no logic;
   Database.executeBatch(new NdaExpiryAlertBatch(), NdaExpiryAlertBatch.SCOPE).
   🔴 Its class header must carry the post-deploy scheduling gate in the same terms
   CallForOffersAlertSchedule uses: an unscheduled alert job leaves NO TRACE AT ALL —
   no queue to inspect, no status to filter — and "no alert arrived" is
   indistinguishable from "no NDA was expiring". Record the cron expression and the
   owning user.

=== ITEM 3 — regression pinning only (the rules themselves are admin work) ===

8. Tests that must exist and stay green once the two validation rules deploy:
   - ContractExecutionServiceTest must remain green end-to-end. That IS the proof that
     a cross-object VR sees the in-transaction 'Executed' status; if it does not, every
     PSA execution rolls back.
   - A PSA execution on a deal whose Primary_Contract__c is BLANK still executes and
     still stamps Contract_Executed_Date__c (the falsifier for removing the
     ISBLANK(Primary_Contract__c) clause).
   - A Lead with a blank First_Seen_Date__c, updated so Lead_Intake_Stamp stamps it,
     still saves.
   - A Lead whose First_Seen_Date__c is already populated cannot have it changed.

=== ARCHITECTURE.md (§6 — same PR) ===

9. Update:
   - §1 Current objects: the Offering__c row gains a Purpose and names OfferingService
     as its creator (and loses nothing).
   - §2 Key Apex Services: add OfferingService, NdaExpiryService, NdaExpiryAlertBatch,
     NdaExpiryAlertSchedule.
   - §2 WITH SYSTEM_MODE table: three new rows — OfferingSelector's guard read,
     NdaSelector.queryExpiryAlerts, and the NDA marker write — each argued at its own
     row, with SHARING stated as a SEPARATE decision from MODE.
   - Update the running "N SYSTEM_MODE queries across M selector classes" count.

Bulk testing: .claude/rules/bulk-test-rule.md's 251-record mandate applies with NO
exemption to both the ContractReviewTrigger path (Item 1) and the NDA locator (Item 2).
Assert governor headroom on counters captured INSIDE the async context, never on
Limits.* after Test.stopTest() — stopTest restores the pre-test counters and makes the
obvious assertion silently vacuous.

Do not deploy. Do not add anything not listed above.
```

---

**Complexity routing summary**

| Item | Declarative | Programmatic |
|---|---|---|
| 1 — Offering shell | none (unless Q1.2 → A6, then `salesforce-admin`) | **`salesforce-developer`** |
| 2 — NDA expiry reminders | **`salesforce-admin`** (2 fields + FLS) | **`salesforce-developer`** |
| 3 — Two validation rules | **`salesforce-admin`** | **`salesforce-developer`** (regression pinning only) |

No item routes to `salesforce-solution-architect` (no multi-object schema, no org-wide security-model design, no subflow orchestration) or to `salesforce-technical-architect` (no integration, no Named Credentials, no LDV, no callouts, no Platform Events).
