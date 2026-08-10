# TRANCHE 5 — Design Requirements

**Item A** — Auto-create `Property_Asset__c` on Closed Won (acquisition) · **decision D27.3**
**Item B** — Active Listing traction monitor + broker change (disposition) · **decision D27.1**

**Date:** 2026-08-10 · **Status:** Gate 1 — NOT approved, NOT built
**Binding:** D1–D27 of `agent-output/stage-by-stage-decisions.md`. D9, D27.1 and D27.3 govern.

**Read for this design:** `agent-output/stage-by-stage-decisions.md` (D9, D26, D27) ·
`stage-by-stage-audit-acquisition.md` §3 item 7 · `stage-by-stage-audit-disposition.md` §2.4 ·
`ARCHITECTURE.md` §1 + §2 · `spec-acquisition.md:182` · `spec-disposition.md:22` (document line 213) ·
plus 40+ metadata and Apex files listed inline below. Every claim below was read off disk, not inferred.

---

## §0 — QUESTIONS FOR GATE 1

Answering these changes the design. **Questions marked 🔴 are blocking — I will not assume an answer.**

### Item A

| # | Question | Why it changes the design |
|---|---|---|
| 🔴 **A-Q1** | **Which fields carry over onto the new asset?** The minimum that makes it *exist* is `Name` + `Property__c` + `Status__c`. The nine seed scripts populate only `Name`, `Property__c`, `Property_Type__c`, `Status__c='Active'`, and sometimes `Vacant_Area__c` / `Argus_Signal__c`. Nothing in the acquisition tree supplies `Peak_Sell_Date__c`, `Target_Sale_Price__c`, `Argus_Signal__c` or `Projected_Value_At_Peak__c`. | This is the whole "usable shell vs empty shell" question. See §2.4 for a field-by-field table with a recommendation per field. |
| 🔴 **A-Q2** | **`Property_Type__c` — copy, map, or leave blank?** The three picklists do **not** align: `Opportunity.Asset_Type__c` has 10 values, `Property__c.Asset_Type__c` has 6, `Property_Asset__c.Property_Type__c` has 5. `Retail Strip`, `C-Store`, `Land`, `Storage`, `Hospitality`, `Medical Office` exist on a source and **not** on the target. And `Property_Type__c` is **NOT `<restricted>`**, so an off-list value is stored **silently** — no error, no test failure, a value nobody can pick in the UI and every report groups separately. | Copying is a defect generator. Mapping means writing and owning a translation table. Leaving blank means a manual step. Pick one. |
| 🔴 **A-Q3** | **`Opportunity.Property__c` is null on a manually created deal.** `LeadConvertService:241` sets it only on lead conversion. Skip silently, skip and log, or create a `Property__c`-less asset? | An orphan asset is invisible to the Sell Meter for a different reason than a blank peak date (see §2.5), so this is not cosmetic. |
| **A-Q4** | **Idempotency key: one asset per `Property__c`, forever?** Or one per Property that is currently `Status__c='Active'`? A property bought, sold (`Disposed`), and bought back would get no second asset under the first reading. | Determines the guard query and whether a re-acquisition is expressible. |
| **A-Q5** | **Asset `Name`: `Property__r.Name` verbatim, or `Property__r.Name + ' Asset'`?** The seeds use both conventions inconsistently (`seed-broker-assignments` appends ` Asset`; `seed-lease-renewals`/`seed-work-orders` do not). | `Property_Asset__c.Name` is a **Text** name field, so a value is mandatory. It is also the label shown by `SellMeterController.getPortfolio`, `BovController.getOutreachSummary` and `BrokerListingController.getListing`. |

### Item B

| # | Question | Why it changes the design |
|---|---|---|
| 🔴 **B-Q1** | **Define "no traction."** The document says *"no offers and no real interest."* Offers are countable (`Disposition_Offer__c` children with a `Disposition__c` lookup, and/or `Broker_Listing__c.Offers_Received__c`). **"Real interest" is not stored anywhere in this org in any form.** Options: (a) offers only — computable today, zero new fields; (b) offers **plus** a hand-set "showings / interest" input the broker check-in captures — one new field, one more thing to maintain; (c) offers plus a manual "traction confirmed" override the team sets after the internal discussion. | This is the single largest shaping question in Item B. My recommendation is (a) **plus** (c) as an override — see §3.2 — but it is a business decision. |
| 🔴 **B-Q2** | **Which record holds the clock — `Disposition__c` or `Broker_Listing__c`?** ⚠ **Nothing in the application ever creates a `Broker_Listing__c`.** Repo-wide, the only creators are `TestDataFactory` and three seed scripts (`seed-disposition.apex`, `seed-disposition-bulk.apex`, `seed-disp0002.apex`). `Disposition__c.Listing_Date__c` is likewise written by nothing. So **both candidate clocks start from a date no automation sets.** | A monitor keyed on `Broker_Listing__c` is inert for every disposition the application itself produces. If the broker-change mechanism creates listing rows (§3.3) that changes — but only from the *second* broker onward unless entry to Active Listing also opens the first one. |
| 🔴 **B-Q3** | **Is fixing `Selected_Broker__c` (Text 255) in scope?** Changing it to a lookup is an additive rename (`add → backfill → repoint → retire`), and it is **inconsistent with the rest of the module**: `Broker_Listing__c.Broker_Firm__c`/`Contact_Name__c` and `BOV_Submission__c.Broker_Firm__c`/`Contact_Name__c` are *all* Text. There is no `Contact` lookup anywhere in the disposition broker chain. | If it stays Text, broker-change *history* has to live somewhere else. My recommendation (§3.3) gives history without touching the field. |
| **B-Q4** | **Formula, scheduled job, or both?** A formula is live, zero-maintenance, unschedulable-and-therefore-unforgettable, and **cannot** be a work queue. A scheduled job can write `Listing_Status__c` / `Next_Broker_Checkin__c` and create a review Task, but 🔴 **a deploy that does not schedule it silently disables the whole feature** (the standing lesson from `AttachmentCarrierSweepSchedule` / `RoutingRetrySweepSchedule`). | Determines whether Item B is declarative-only or carries an Apex `Schedulable`. |
| **B-Q5** | **Should the mechanism write `Next_Broker_Checkin__c`?** It exists, is on no automation's path, and **backs a live report** — `reports/Dispositions/Broker_Alert_Due.report-meta.xml` filters `Next_Broker_Checkin__c = NEXT_N_DAYS:7`. That report therefore returns nothing today, always. | Writing it makes an existing report work. Not writing it leaves a permanently empty report in the org. |
| **B-Q6** | **What replaces the four hardcoded alert rows in `lwc/listingAlerts`?** See the correction in §1.3 — the component is not empty, it *asserts* a schedule that does not exist and advertises two notifications D9 defers. | Three options: render the real computed state; render the real state plus a "not yet automated" caption; or remove the rows. Doing nothing ships a UI that lies. |

---

## §0.5 — SHOULD THE TWO ITEMS BE BUILT AND DEPLOYED TOGETHER?

**Recommendation: BUILD IN ONE PASS, DEPLOY SEPARATELY — Item A first, Item B second.**

They share nothing. Different modules, different objects, different personas, no common metadata, no
ordering dependency in either direction. The reason to split the *deploy* is that their risk profiles
are opposites:

| | Item A | Item B |
|---|---|---|
| Blast radius | 🔴 **Every Closed Won in the org, forever.** Runs inside `OpportunityReviewTrigger`, which also fires inside the `Transaction_Complete_Close` flow — so a throw here rolls back the deal close **and** the Transaction save that triggered it. | Contained to the disposition module's Active Listing stage. Nothing outside it reads the new state. |
| Failure mode | **Loud.** A bad insert throws `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and a user cannot close a deal. Impossible to miss. | **Silent.** A clock keyed on a date nobody sets (B-Q2) computes "day 0" forever and looks healthy. An unscheduled job (B-Q4) reports nothing and looks identical to "no listings are at risk". |
| Verification | One deal, one read-back query. Minutes. | Requires either a seeded aged listing or waiting 30 days. |
| Rollback | Deactivate one service call. | Path text, an LWC, a possible schedule — several moving parts. |

Deploying them together lets a silently-dead Item B hide behind a visibly-healthy Item A — the exact
argument D26 used to split Tranche 4 into 4A/4B, and the reason that split was right.

**Item A is also materially smaller and materially more urgent**: without it the entire Property
Management module has no root object on a real deployment. Item B improves a stage that at least
functions today.

---

## §1 — PREMISE CORRECTIONS FOUND DURING RECON

Recorded so they are not re-introduced. Each was measured, not inferred.

### 1.1 ✅ D27.3's core claim is CONFIRMED, exactly as stated

Re-measured independently 2026-08-10:

| Source | Creates `Property_Asset__c`? |
|---|---|
| `force-app/main/default/flows/**` | **Zero.** No flow references the object at all. |
| `force-app/main/default/triggers/**` | **Zero.** The six triggers are `ContractReviewTrigger`, `EmailMessageTrigger`, `LeadConvertTrigger`, `OpportunityReviewTrigger`, `TaskRollupTrigger`, `DispositionTrigger`. None is on `Property_Asset__c` and none creates one. |
| `force-app/main/default/classes/**` | **Only `TestDataFactory`.** |
| `scripts/*.apex` | **Nine seed scripts** (`seed-broker-assignments`, `-dispositions`, `-lease-inquiries`, `-lease-renewals`, `-leasing-dashboard`, `-onboarding`, `-pm-dashboard`, `-rent-roll`, `-work-orders`). |

### 1.2 ✅ Nothing fires on `Property_Asset__c` creation — the brief's ⚠ is answered "no"

Established four ways: no `PropertyAssetTrigger` exists; no flow has `Property_Asset__c` as its start
object; the object has **no** `listViews/` directory; and its only Apex readers are
`PropertyAssetSelector` (3 methods), `DispositionService.findOrCreate`, `SellMeterController`,
plus child-object selectors that read *up* to it.

**So auto-creating assets starts no automation. But it does change what four things display**, and
one of those is a genuine surprise — see §2.5.

### 1.3 🔴 `lwc/listingAlerts` IS NOT AN EMPTY STUB. The brief is half right and the other half matters more.

`listingAlerts.js` **is** the two-line stub the brief describes. `listingAlerts.html` **is not empty** —
it is a **hardcoded 22-line mock** that renders four alert rows as fact:

```
Day 21   →  No offers → email to Junior
Week 4   →  YELLOW flag on Junior dashboard
Week 6   →  Hard prompt + alert to Junior + Ali
Offer in →  Clock PAUSES · Disposition Offer created
```

Three consequences:

1. **It advertises the 6-week clock D27.1 just overturned**, in the UI, on the Active Listing stage.
2. **It advertises two notifications that D9 defers** ("email to Junior", "alert to Junior + Ali") and
   one rule that appears in no document, no decision and no code (**"Clock PAUSES"** on offer receipt).
3. `__tests__/listingAlerts.test.js:41` **asserts the exact trigger list** `['Day 21','Week 4','Week 6','Offer in']`.
   Changing the component reds that test — which is correct and desirable, but it means the Jest suite
   currently *pins the wrong clock*.

**A component rendering a fixed lie is worse than an empty one**, because nothing looks broken.

### 1.4 🔴 THE 6-WEEK CLOCK IS ALREADY IMPLEMENTED IN APEX — and it lives in SIX places, not one

The brief and D27.1 both treat the Path guidance as the single wrong text. It is not. `Days_On_Market__c`
thresholds are hardcoded in `BrokerListingController.getListing:46-59`:

```apex
if (dom >= 42)      { r.weekLabel = 'Week 6 — Hard Stop';  r.isAtRisk = true;  }
else if (dom >= 28) { r.weekLabel = 'Week 4 — At Risk';    r.isAtRisk = true;  }
else if (dom >= 21) { r.weekLabel = 'Week 3 — On Track';   r.isAtRisk = false; }
else                { r.weekLabel = null;                  r.isAtRisk = false; }
```

`brokerListing.js:34` colours the Days-On-Market stat amber off `isAtRisk`; `brokerListing.html`
renders `weekLabel`. **Full inventory of the 6-week clock in shippable metadata:**

| # | File | Form | Active? |
|---|---|---|---|
| 1 | `pathAssistants/Disposition_Path_On_Market` — Active Listing `<info>` | text | ✅ active |
| 2 | `pathAssistants/Disposition_Path` — Active Listing `<info>` | text | ❌ `<active>false</active>` (Tranche 2 deactivated it) |
| 3 | `pathAssistants/Disposition_Path_Off_Market` | XML comment only — **no Active Listing step exists on the off-market path** | n/a |
| 4 | `classes/BrokerListingController.cls:46-59` | **executable, 21/28/42-day thresholds** | ✅ live |
| 5 | `lwc/listingAlerts/listingAlerts.html` | hardcoded rows | ✅ rendered |
| 6 | `lwc/dispositionOffer/dispositionOffer.html:22` | empty-state string *"No offers yet. 6-week clock active."* | ✅ rendered |

Pinned by three test files: `listingAlerts.test.js:41`, `brokerListing.test.js`, `BrokerListingControllerTest.cls`.

⚠ **D27.1 says "on BOTH paths." Only ONE active path has the step.** The correct reading is
"everywhere the clock is expressed", which is the six rows above — a materially bigger edit than
"correct the Path guidance", and one that touches **Apex and tests**, not just declarative text.

### 1.5 `Broker_Listing__c.Days_On_Market__c` is a hand-keyed Number, **not** a formula

`objects/Broker_Listing__c/fields/Days_On_Market__c.field-meta.xml` — `<type>Number</type>`,
precision 4, **no `<formula>`**. Nothing writes it. So the one piece of clock logic that *does* exist
(§1.4 #4) reads a static number a human typed.

Contrast `Disposition__c.Days_On_Market__c`, which **is** a formula:
`IF(ISBLANK(Listing_Date__c), null, TODAY() - Listing_Date__c)`.

**The two fields share a name and are not the same kind of thing.** Any design that says "days on
market" must say which one.

### 1.6 The `advanceTo`/`Replace_Broker` precedents differ from what the brief implies

`quickActions/Broker_Assignment__c.Replace_Broker` is a **ScreenAction** quick action backed by
`lwc/brokerReplaceQuickAction`, which collects *incoming broker · effective date · reason · notes* and
calls `BrokerAssignmentController.replaceBroker`, snapshotting the outgoing broker into history. It is
a **very close functional template** for the disposition broker change — the only reason it cannot be
reused is its object binding and its broker picker (`getBrokerOptions` returns Contacts; the
disposition equivalent should pick from BOV submissions — see §3.3).

### 1.7 Access is already in place for both items — no new object grants needed

- `Property_Asset__c`: object CRUD + `viewAllRecords=true` on `DPEG_Acquisitions`, `DPEG_PropertyAsset_View`,
  `DPEG_PropertyMgmt_View`, `DPEG_PropertyMgmt_Edit`. ⚠ **One exception:** `Property_Management_Access`
  has `viewAllRecords=false` and `Property_Asset__c` is `sharingModel Private` with **no** sharing rules
  file — so any persona relying on that legacy set alone will not see an auto-created asset it does not
  own. (A-Q5 territory; flagged, not assumed.)
- `Broker_Listing__c`: full read/edit/create + `viewAllRecords=true` on `DPEG_Disposition_Edit`,
  read + `viewAllRecords=true` on `DPEG_Disposition_View`, and every existing field is FLS-granted on
  both. **Any NEW field must be added to both** — and to `DPEG_Acquisitions` and
  `Disposition_Dashboard_Access` where the sibling fields already live. 🔴 A `PermissionSet` deploy
  **REPLACES** its whole `<fieldPermissions>` set; reconcile against the org first (this bit Broker
  Protection twice).

---

## §2 — ITEM A: AUTO-CREATE `Property_Asset__c` ON CLOSED WON

### 2.1 What the document asks for

> *"The purchase completes and the property becomes asset."* (Part 1, line 182)

Plus D27.3: build it on Closed Won, idempotent, verified by read-back.

### 2.2 🔵/🟢 WHERE IT BELONGS — recommendation and reasoning

**RECOMMENDED: Apex, in `OpportunityReviewTriggerHandler`, keyed on Opportunity stage entry to
`Closed Won`, in a NEW service class `PropertyAssetService`.**

Three candidates were considered against the evidence:

| Option | Verdict |
|---|---|
| **Extend `Transaction_Complete_Close`** (the flow the brief names) | 🔴 **REJECTED — it misses half the closes.** That flow starts on `Transaction__c` where `Status__c = 'Closed'` **and** `Opportunity__c != null`. But `StageAdvanceService.NEXT_STAGE:104-105` maps `'PSA' ⇒ 'Closed Won'` **and** `'About to Close' ⇒ 'Closed Won'` — a deal driver clicking Advance Stage reaches Closed Won **with no Transaction involved at all**. Building here would create assets for transaction-closed deals only, and the gap would be invisible. |
| **A new record-triggered flow on Opportunity** | Workable, but rejected on three counts: (a) **idempotency needs a query of existing assets keyed on `Property__c`**, and a Flow `Get Records` in this position is exactly the shape that produced Tranche 2's C1 finding; (b) it duplicates a concern the trigger handler already owns; (c) 🔴 **it would be the FIRST flow in the repo to touch `Property_Asset__c`**, so the object gains its first automation in the least reviewable place. |
| **Apex in `OpportunityReviewTriggerHandler`** ✅ | The handler **already routes a non-review, stage-keyed concern** — `ContractExecutionService.openTransactionsOnAboutToClose(opps, priorById)` at `:40`, added 2026-08-05 for exactly this reason ("the trigger point is now the deal's stage"). One route to Closed Won regardless of how the deal got there. The `ensure*` idempotency pattern, the bulk contract and the selector layering all already exist and are proven. |

**Concrete shape:**

```
OpportunityReviewTriggerHandler.route(...)
  ├─ OpportunityReviewService.createReviewRecords(opps, priorById)
  ├─ OpportunityReviewService.ensureNda(opps, priorById)
  ├─ ContractExecutionService.openTransactionsOnAboutToClose(opps, priorById)
  └─ PropertyAssetService.ensureOnClosedWon(opps, priorById)      ← NEW
```

**A new service, not a fifth method on `OpportunityReviewService`.** That class is already 6 blocks ×
3 separately-argued record-type decisions and its header runs 145 lines. `Property_Asset__c` is not a
*review* child and not part of the deal tree — it is the handoff to a different module, which is the
same argument `ContractExecutionService` won at `:36-39`. Add it to `ARCHITECTURE.md` §2's Key Apex
Services table in the same PR (§6 requirement).

### 2.3 Idempotency — mandatory, and simpler here than the `ensure*` precedent

The guard is a **query of existing assets by `Property__c`**, not a `Primary_*` field check:

```
1. collect opps where stageChanged && StageName == 'Closed Won'   (Trigger.new / oldMap)
2. drop opps with a null Property__c                              (A-Q3)
3. PropertyAssetSelector.selectByPropertyIds(propertyIds)         ← NEW method
   → remove every Property already carrying an asset
4. build + insert
```

**Budget: 2 SOQL / 1 DML per trigger chunk, CONSTANT in the number of deals.** A chunk closing no
deal costs **zero** queries and zero DML — the guard must return before any read, matching
`DispositionStageEntryService`'s stated contract.

🟢 **Two things this does NOT need, and the reason matters:**

- **No parent back-stamp, therefore no `Queueable`.** There is no `Opportunity.Property_Asset__c` field
  and none is proposed — the join `Opportunity → Property__c → Property_Asset__c` already exists via
  `Property_Asset__c.Property__c`. This sidesteps the entire `ENTITY_IS_LOCKED` class of defect that
  forced `LoiPrimaryStampQueueable` and `DispositionNdaStampQueueable` into existence. **Do not add a
  `Primary_Asset__c` lookup "for convenience"** — it would re-open that problem for zero requested benefit.
- **No approval-lock concern.** `Underwriting_Approval` and `LOI_Approval` are `recordEditability = AdminOnly`,
  but they are resolved long before Closed Won and both set `finalApprovalRecordLock = false`. This code
  writes nothing back to `Opportunity`, so even a pending approval could not bite it.

### 2.4 🔴 Field carry-over — the table, and what "usable rather than an empty shell" actually means

`Property_Asset__c` has **16 custom fields, all `<required>false</required>`**, plus a **Text `Name`**
(mandatory by platform). Working reference = what the nine seed scripts populate, which is
**`Name` + `Property__c` + `Property_Type__c` + `Status__c='Active'`** (± `Vacant_Area__c`,
`Argus_Signal__c`).

| Field | Type | Proposed source | Recommendation |
|---|---|---|---|
| `Name` | Text (**mandatory**) | `Property__r.Name` | ✅ **Set.** A-Q5 decides the ` Asset` suffix. |
| `Property__c` | Lookup → `Property__c` | `Opportunity.Property__c` | ✅ **Set.** The whole point; always non-null after conversion (`LeadConvertService:241`). |
| `Status__c` | Picklist `Active`/`Disposed` | literal `'Active'` | ✅ **Set.** Every seed does; a blank status makes the asset invisible in `Managed_Properties` and `Properties_in_AUM`. |
| `Property_Type__c` | Picklist, **NOT restricted** | `Property__r.Asset_Type__c` | 🔴 **A-Q2. Do not blind-copy.** Mapping needed: `Retail Strip→Retail`, `Office→Office`, `Industrial→Industrial`, `Multifamily→Multifamily`, `Mixed-Use→Mixed-Use`, **`Land→(no target value)`**. An unmapped value is stored *silently* because the field is unrestricted. |
| `Closing_Date__c` | Date | `Opportunity.CloseDate` | ⚠ Recommended, pending A-Q1. Standard, always populated, semantically exact. |
| `Final_Purchase_Price__c` | Currency | **ambiguous — 3 candidates:** `Opportunity.Amount`, `Opportunity.My_Price__c`, `Transaction__c.Contract_Value__c` | 🔴 **A-Q1.** `Contract_Value__c` is the contract number and is what `ContractExecutionService` already copies onto the Transaction from `Primary_Contract__r.Contract_Value__c` — arguably the truest "final purchase price", but it is on a record that may not exist (§2.2). **Ask.** |
| `NOI__c` | Currency | `Opportunity.Underwritten_NOI__c` **or** `Property__r.Annual_NOI__c` | 🔴 **A-Q1.** These are different numbers — one is DPEG's underwriting, one is the seller's marketing figure. |
| `Market_Cap_Rate__c` | Percent | `Opportunity.Market_Cap_Rate__c` **or** `Property__r.Market_Cap_Rate__c` | 🔴 **A-Q1.** Same shape of ambiguity. |
| `Target_Sale_Price__c` | Currency | — | ❌ **Leave blank.** No acquisition-side source. It is a *disposition* target set later. |
| `Peak_Sell_Date__c` | Date | — | ❌ **Leave blank.** Argus-derived. ⚠ **But read §2.5 — a blank here has a specific, non-obvious consequence.** |
| `Argus_Signal__c` | Picklist | — | ❌ **Leave blank.** Argus-derived. |
| `Projected_Value_At_Peak__c` | Currency | — | ❌ **Leave blank.** |
| `Vacant_Area__c` | Number | — | ❌ **Leave blank.** Yardi-derived once units exist. |
| `Sell_Readiness_Score__c` | Percent | — | ❌ **Leave blank.** |
| `Sell_Readiness_Band__c` | **Formula** | — | n/a — derives from `Argus_Signal__c`; renders `—` while blank. |
| `Readiness_Score__c` | **Formula** | — | n/a — `IF(ISPICKVAL(Argus_Signal__c,"Sell Now"),1,0)`; reads 0 while blank. |
| `Property_Name__c` | **Formula** (`Name`) | — | n/a. |

**The honest summary:** the acquisition tree can populate **at most 8 of 17** fields, and 4 of those 8
are ambiguous. The blanks are not a gap in this design — they belong to Argus and Yardi, which are the
`ARCHITECTURE.md` §0 read-only spokes. **"Usable" here means "the PM tree has a parent to hang from",
not "fully populated."** Every PM child object (`Unit__c`, `Rent_Step__c`, `Onboarding__c`,
`CAM_Reconciliation__c`, `Delinquency__c`, `Insurance_Policy__c`, `Broker_Assignment__c`,
`Lease_Inquiry__c`, `Lease_Renewal__c`, `Work_Order__c`) needs only the parent Id.

### 2.5 🔴 The non-obvious downstream effect: the new asset is INVISIBLE to the Sell Meter

Nothing *fires* (§1.2), but `PropertyAssetSelector` filters **both** Sell Meter queries on:

```apex
WHERE Property__c != null AND Peak_Sell_Date__c != null      // :62 and :86
```

An auto-created asset has `Property__c` set and `Peak_Sell_Date__c` **null**, so it appears in
**neither** `selectAllForMeterSummary` (the band counts) **nor** `selectAllForPortfolio` (the table).
The selector's own header documents this as deliberate: *"an asset with no peak date is not yet on the
meter."*

**This is the correct behaviour and should not be changed** — but it must be stated at Gate 1, because
the natural expectation after "closing a deal now creates an asset" is "the new asset shows up on the
Sell Meter", and it will not. It appears there only once someone sets `Peak_Sell_Date__c`.

Where the new asset **does** become visible immediately: the PM/Disposition reports
(`Managed_Properties`, `Properties_in_AUM`, `Occupancy_by_Property`, `Portfolio_Sell_Readiness`,
`Readiness_Mix`, `Sell_Readiness_By_Type` and 8 others), object search, and the parent picker on every
PM child's New dialog. **Reports with `Status__c`/`Argus_Signal__c` groupings will grow a blank-valued
bucket** — cosmetic, but it will be noticed.

### 2.6 ⚠ Record-type stamping — re-argued, not inherited

**`Property_Asset__c` has NO record types today.** Verified: no `objects/Property_Asset__c/recordTypes/`
directory exists; the repo-wide record-type inventory is `Opportunity` (Land/Commercial), `Disposition__c`
(On_Market/Off_Market), `NDA__c`, `LOI__c`, `Contract_Review__c` (each Acquisition/Disposition).

**So there is nothing to stamp and no `RecordTypeId` line belongs in this build.** The guarded-vs-
unconditional question is **not answerable** in the abstract and must not be pre-decided.

**Written down for whoever adds record types to this object later**, since D27.3 asks for it and three
prior instances produced three different answers:

- **D16.3 / `ensureNda`** chose **guarded** because it runs on *every* Opportunity insert including
  `Database.convertLead` — an unavailable type would break lead conversion org-wide (blast radius).
- **3B / the LOI block** chose **guarded** because it runs as the **approver**, and a throw there means
  the approver cannot approve at all (principal identity).
- **3C / the PSA block** chose **guarded** because `PSA` is a sequenced gate with one route in, and the
  insert shares an all-or-none transaction with four sibling children (transaction coupling).

**None of those three arguments transfers here**, and that is the point. This block would run on a
*terminal* stage, in its own service, sharing a transaction with three siblings that have already
committed by the time it runs, driven by a deal driver with Edit — a fourth situation. It gets a
fourth argument, made at the time, in the block.

### 2.7 Work split

**🔵 ADMIN / SOLUTION-ARCHITECT — nothing, if A-Q1/A-Q2 land on "no new fields".**
No new object, no new field, no flow, no permission set, no layout, no record type.
⚠ Two conditional items:
- If A-Q2 chooses a **mapping table**, confirm whether a `Land` acquisition should produce an asset at
  all (there is no `Land` value on `Property_Type__c`).
- If A-Q1 adds any new field, add FLS to **every set where the sibling `Property_Asset__c` fields already
  live** — `DPEG_Acquisitions`, `DPEG_PropertyAsset_View`, `DPEG_PropertyMgmt_View`,
  `DPEG_PropertyMgmt_Edit`, `Property_Management_Access` — reconciled against the org first.

**🟢 DEVELOPER (`salesforce-developer` — standard Apex, no integration):**

1. **`classes/PropertyAssetService.cls`** — new. `with sharing`. One public method
   `ensureOnClosedWon(List<Opportunity> newOpps, Map<Id,Opportunity> oldMap)`. Stage-entry detection
   (`stageChanged && StageName == 'Closed Won'`); null-`Property__c` handling per A-Q3; idempotency
   drop; build; bare `insert` (system-mode DML, matching the five `OpportunityReviewService` siblings
   that are entered by a user with Edit — **not** `AccessLevel.SYSTEM_MODE`, which that class reserves
   for the approver-driven LOI block). Class header must state the budget and the A-Q1/A-Q2 decisions.
2. **`classes/PropertyAssetSelector.cls`** — add `selectByPropertyIds(Set<Id>)`.
   🔴 **`WITH SYSTEM_MODE`, and the justification is not boilerplate:** this read runs inside an
   after-update trigger the user never asked for, and one of its two callers is the
   `Transaction_Complete_Close` flow — i.e. it can execute as a **Transactions persona** who has no
   reason to hold FLS on `Property_Asset__c`. `USER_MODE` **throws** rather than degrading, and the
   throw escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`, **rolling back the deal close and the
   Transaction save with it.** That is verbatim the `TaskSelector.selectByTransactionDealIds`
   production incident recorded in `ARCHITECTURE.md` §2 (82 Tasks rolled back). Add the row to the
   automation-path table in the same PR. ⚠ The class's three existing methods stay `USER_MODE` — its
   header already argues why, and this makes it a fourth mixed-mode selector.
3. **`classes/OpportunitySelector.cls`** — add a read supplying `Property__r.Name` (+ whatever A-Q1/A-Q2
   settle on). `Trigger.new` does **not** carry parent-path fields, so this query is unavoidable.
   Same `SYSTEM_MODE` argument as (2). ⚠ Note in passing: the neighbouring
   `selectExecutionHandoffByIds` is `WITH USER_MODE` on the same trigger path and carries the identical
   latent exposure — **out of scope, reported not fixed.**
4. **`classes/OpportunityReviewTriggerHandler.cls`** — one line in `route(...)`, with a comment saying
   why it is here and not in `OpportunityReviewService`.
5. **`classes/PropertyAssetServiceTest.cls`** — trigger-driven, so `.claude/rules/bulk-test-rule.md`
   applies **in full, with no exemption**: a literal **251-Opportunity** bulk close asserting 251 assets,
   **and a constant 2-SOQL/1-DML budget** (the budget assertion is the higher-value one — it makes a
   future per-record query fail here instead of in production). Plus: idempotency (close, re-save, still
   one asset); null-`Property__c`; **both routes to Closed Won** (manual `advance()` *and* a
   `Transaction__c` flipped to `Closed`, which exercises the flow); and 🔴 **a read-back assertion that
   re-queries the inserted row** rather than asserting on the in-memory list (gate A2 / `TestDataFactoryTest`
   lesson: a creation that succeeded is not evidence the values landed).

---

## §3 — ITEM B: ACTIVE LISTING TRACTION MONITOR + BROKER CHANGE

### 3.1 What the document asks for, and what D9 removes

> *"The property is given about two months on the market. If there is no traction within the first
> month — no offers and no real interest — the team discusses it internally and decides whether to
> change the broker."* (Part 2, line 213)

D27.1: **60-day clock, 30-day checkpoint.** The document wins over the deployed 6-week guidance.

🔴 **D9 removes the ALERT and keeps the MECHANISM.** Concretely, in scope: computing and storing the
traction state, surfacing it in the UI, and the broker-change action. Out of scope: any
`CustomNotificationType`, any `GroupNotifier` call, any email alert, any Chatter post.

**What the deferred half would need later, stated explicitly (D9 asks for this):**
1. A recipient population — 🔴 still unresolved org-wide: *"Disposition team"* is neither a queue nor a
   public group in this repo, and D9 flags the `Acquisition` **queue** vs `Acquisitions_Team` **public
   group** distinction as needing re-establishment before any deferred notification is built.
2. A `notificationtypes/*.notiftype-meta.xml` (the module has **zero** today — no flow or notification
   type in the repo references `Disposition__c` at all).
3. A trigger point. **If B-Q4 lands on a scheduled job, the notification is one action call inside a
   loop that already exists — a genuinely additive change.** If B-Q4 lands on formula-only, the deferred
   alert needs a *new* scheduled job built from nothing, i.e. a rewrite. **This is the strongest single
   argument for B-Q4 = job (or formula + job), and it is the D9 "later addition rather than a rewrite"
   requirement made concrete.**

### 3.2 🔴 Defining "no traction" — recommendation

**RECOMMENDED (pending B-Q1): a two-part definition, offers-driven with a manual override.**

| Part | Source | Why |
|---|---|---|
| **No offers** | `COUNT(Disposition_Offer__c WHERE Disposition__c = :id)` | Countable, unambiguous, already modelled. ⚠ `Disposition_Offer__c.Disposition__c` is a **Lookup**, not Master-Detail, so a **roll-up summary field is unavailable** — this count needs Apex or a Flow, not a formula. ⚠ `Broker_Listing__c.Offers_Received__c` is a hand-keyed Number nobody writes and is **not** a substitute. |
| **"Real interest"** | ❌ **not stored anywhere in this org, in any form** | No showings field, no enquiry counter, no activity rollup on `Disposition__c` or `Broker_Listing__c`. |

**Recommendation: do NOT invent a "real interest" metric.** Compute the objective half (days elapsed +
offer count) and let the *subjective* half be exactly what the document says it is — an internal
discussion — captured as a **manual acknowledgement**. Concretely: the state machine flags the
disposition at day 30 with zero offers, and a human either changes the broker or records that the
review happened. That matches the document's own wording (*"the team discusses it internally and
decides"*) and refuses to fabricate a measurement.

**Rejected alternative:** deriving interest from `Task`/`Event` activity on the Disposition. Nothing
creates those today, so it would read "no interest" always — a metric that is a constant is worse than
no metric, because it looks like data.

### 3.3 Where the clock lives, and what the broker change is — recommendations

🔴 **The blocking problem underneath both (B-Q2): nothing sets a listing start date.**
`Disposition__c.Listing_Date__c` is written by nothing. `Broker_Listing__c` rows are created by
nothing. So a monitor built today measures from `null` on every real disposition, and
`Days_On_Market__c` returns `null` → the formula's `BlankAsZero` treatment makes it read **0 forever**.

**Fixing that is a prerequisite, not a nice-to-have, and it has a natural home:**
`DispositionStageEntryService` (built in Tranche 3) already runs off `DispositionTrigger` and already
owns "on entry to stage X, do Y", with three worked blocks, a documented approval-lock analysis and
251-record bulk tests. **Stamping `Listing_Date__c` on entry to `Active Listing` is a fourth block of
exactly that shape** — with one difference that must be argued at the block, not inherited:

🔴 **It is a write to `Disposition__c` ITSELF, not to a child.** Every existing block in that service
inserts a *child*, which is safe under an approval lock; this one writes the parent. `Broker_Selection_Approval`
(entry criteria: BOV Outreach) is the approval immediately *before* Active Listing, and all three
disposition approvals are `recordEditability = AdminOnly`. **`SYSTEM_MODE` lifts CRUD/FLS but NOT an
approval lock** — the measured lesson from `LoiPrimaryStampQueueable` and Tranche 2's C1. A same-record
write is normally the *safe* case (you cannot enter a stage on a locked record), but this needs the
explicit argument written down, not assumed.

**Recommendation on B-Q2: the clock lives on `Disposition__c`.** Reasons: `Listing_Date__c` and the
`Days_On_Market__c` formula already exist there; `Disposition__c` always exists at Active Listing
whereas `Broker_Listing__c` may not; the Path, the record page, the LWCs and `Broker_Alert_Due` are all
already keyed to it; and D27.1's "60-day clock" is a property of *the marketing period*, which survives
a broker change, whereas a `Broker_Listing__c` row is per-broker.

**Recommendation on B-Q4: BOTH, with the formula as the display and the job as the queue.**

| Layer | Artifact | Job |
|---|---|---|
| Live display | a **formula** on `Disposition__c` deriving the traction band from `Days_On_Market__c` at **30 / 60** | Always correct, needs no schedule, cannot be forgotten, and is what `listingAlerts` renders. |
| Work queue | a `Schedulable` writing `Listing_Status__c` and `Next_Broker_Checkin__c` | Makes the state **reportable and filterable** (a formula cannot drive `Broker_Alert_Due`), and 🔴 gives the deferred D9 alert a place to be added later as one call. |

🔴 **If B-Q4 = job, the schedule is a post-deploy gate and a deploy that skips it silently disables the
feature.** Job instances are not deployable metadata. `BrokerCheckInReminderSchedulable` is the pattern
to copy — including its **idempotency probe** (`TaskSelector.selectOpenByWhatIdsAndSubjectPrefix`), which
is what stops a daily job creating a duplicate review Task every day.

**Recommendation on B-Q3 / the broker-change mechanism: a ScreenAction quick action on
`Disposition__c` that picks the incoming broker FROM THE BOV SUBMISSIONS — and leave `Selected_Broker__c`
as Text.**

Why this shape and not a lookup conversion:

- **The candidate brokers already exist as records.** `BOV_Submission__c` rows are the brokers who
  responded; `Submission_Status__c` is a restricted picklist `Backup` (default) / `Selected`; and
  `lwc/backupBrokers` **already renders exactly this list** on the Active Listing stage by filtering
  `BovController.getSubmissions` on `!isSelected`. The broker change is therefore: flip the outgoing
  submission to `Backup`, flip the incoming one to `Selected`, and re-stamp `Disposition__c.Selected_Broker__c`
  from the chosen submission's `Broker_Firm__c`.
- **History comes for free from a new `Broker_Listing__c` row.** `BrokerListingSelector.selectMostRecentByDispositionId`
  is already `ORDER BY CreatedDate DESC LIMIT 1` — it is *already written* as "the current listing among
  several". Appending a row per broker gives an audit trail with **no schema change**, and
  `lwc/brokerListing` picks up the new broker automatically. ⚠ **One gap:** `Listing_Status__c` is a
  restricted picklist with no terminal value, so the superseded row cannot be closed off without adding
  one (`Replaced`, or similar). Flag at Gate 1.
- **Converting `Selected_Broker__c` to a lookup is inconsistent and expensive.** Every broker identity in
  this module is Text (`Broker_Listing__c.Broker_Firm__c`/`Contact_Name__c`,
  `BOV_Submission__c.Broker_Firm__c`/`Contact_Name__c`). Converting one field means an additive rename
  (add → backfill → repoint → retire; the name `Selected_Broker__c` is taken, so the new field needs a
  different name and the old one must be retired separately) **and** leaves the module half-typed.
  If DPEG wants broker records, that is a module-wide change and its own tranche.

⚠ **Note the naming collision hazard:** `BOV_Submission__c` already has a **formula** field called
`Selected_Broker__c` (per the disposition audit §2.3's "extras" list). Anything new must not add a third.

### 3.4 The `listingAlerts` surface

**RECOMMENDED: rewrite `lwc/listingAlerts` as a real, `recordId`-driven component.**

- ⚠ **It is currently rendered WITHOUT a `record-id`** — `dispositionMain.html:14` is
  `<c-listing-alerts></c-listing-alerts>`, while its two siblings on the same row both receive
  `record-id={recordId}`. That one attribute must be added or the component has nothing to read.
- `isExposed` is `false` and it is only ever used inside `dispositionMain`, so no flexipage change is
  needed — **which is a real benefit**, given that Dynamic Actions / flexipage edits have silently
  emptied three action bars in this repo.
- It must render the **computed** state (days elapsed, day-30 checkpoint met/not, offer count, current
  band) and **must not** advertise notifications D9 defers. If the rows are kept as a *schedule* display,
  the two notification rows have to go or be captioned as not-yet-automated.
- `__tests__/listingAlerts.test.js:41` currently pins `['Day 21','Week 4','Week 6','Offer in']` and
  **must be rewritten in the same change** — it is the falsifier for the wrong clock.

### 3.5 Work split

**🔵 ADMIN / SOLUTION-ARCHITECT (route to `salesforce-solution-architect` — this is multi-artifact
declarative work with a state model, not a single field):**

1. **Correct the marketing-clock text everywhere it is expressed — all six sites in §1.4**, not just the
   Path. Declarative half: `Disposition_Path_On_Market` Active Listing `<info>`; the inactive
   `Disposition_Path` (correct it or leave it — it is deactivated, so state the choice rather than
   leaving it ambiguous); the `Disposition_Path_Off_Market` XML comment that instructs future readers
   **not** to fix the other path (that instruction is now stale and will mislead).
2. **New field(s) on `Disposition__c`** per B-Q1/B-Q4. Naming must satisfy `ARCHITECTURE.md` §1:
   a state picklist → `..._Status__c` (rule 7); a checkpoint date → `..._Date__c` (rule 6/9); a boolean →
   `Is_`/`Has_` prefix (rule 4). 🔴 **`Traction_Reviewed__c` would be a rule-4 past-participle name and
   is therefore reserved for a Checkbox** — if the field is a Date, it must not carry that shape (the
   `Package_Sent__c` defect, still open on this very object).
3. **FLS for every new field** on `DPEG_Disposition_Edit`, `DPEG_Disposition_View`, `DPEG_Acquisitions`
   and `Disposition_Dashboard_Access` — the sets where the sibling `Disposition__c`/`Broker_Listing__c`
   fields already live. 🔴 Reconcile against the org first: a `PermissionSet` deploy **replaces** its
   whole grant list.
4. **A `Listing_Status__c` terminal value** on `Broker_Listing__c` if §3.3's history model is adopted.
   🔴 Standing rule: **grep the repo AND query the org before touching any picklist value**; the field
   is `<restricted>true</restricted>`.
5. **A quick action** `Disposition__c.Replace_Listing_Broker` (`ScreenAction` + LWC), modelled on
   `Broker_Assignment__c.Replace_Broker`. ⚠ `Disposition__c` has **no quick actions at all** today —
   check where it will surface, and 🔴 **do not enable Dynamic Actions** on `Disposition_Record_Page`
   to do it (that has silently emptied three pages' action bars in this repo). Tranche 2 already
   established that the layout is the right lever here.
6. **`Disposition_Record_Page` — no change expected.** `listingAlerts` renders inside `dispositionMain`,
   so no flexipage edit is required. Confirm before touching it.

**🟢 DEVELOPER (`salesforce-developer`):**

1. **`classes/BrokerListingController.cls`** — replace the 21/28/42 thresholds with the D27.1 30/60
   clock, or **delete `weekLabel`/`isAtRisk` entirely** if the band moves to `Disposition__c` (§3.3).
   🔴 Whichever is chosen, **it cannot stay as it is** — it is live, executable, and wrong.
   `BrokerListingControllerTest` and `brokerListing.test.js` change with it.
2. **`lwc/listingAlerts`** — full rewrite (`.js`, `.html`, `.css`, `__tests__`). Jest + `@sa11y/jest`
   per §5. `dispositionMain.html:14` gains `record-id={recordId}`.
3. **`lwc/dispositionOffer/dispositionOffer.html:22`** — the empty-state string *"No offers yet. 6-week
   clock active."* One line; it will otherwise contradict the corrected clock on the same screen.
4. **`classes/DispositionStageEntryService.cls`** — a fourth block stamping `Listing_Date__c` on entry
   to `Active Listing` (§3.3), with its **own** approval-lock argument written at the block, not
   inherited. Its stated budget contract (`1 SOQL / 1 DML per stage entered, constant in record count`)
   must survive.
5. **`classes/DispositionOfferSelector.cls`** — new; **there is no `Disposition_Offer__c` selector in the
   repo today**, and the offer count needs one. `WITH SYSTEM_MODE` if it is read from the scheduled job
   or the trigger (automation path); `USER_MODE` if it only ever backs a user-requested read. Argue per
   method, not per class.
6. **A `Schedulable` + its batch/logic** if B-Q4 = job. Copy `BrokerCheckInReminderSchedulable`'s
   **idempotency probe** shape. 🔴 It creates no notification (D9) — it writes state and, if B-Q5 = yes,
   `Next_Broker_Checkin__c`.
7. **`classes/DispositionBrokerService.cls` + controller** for the broker change — flip the two
   `BOV_Submission__c` statuses, re-stamp `Selected_Broker__c`, open the new `Broker_Listing__c`.
   `with sharing`; `@AuraEnabled` boundary throws `AuraHandledException` with the repo-standard `ahe()`
   helper. ⚠ The disposition persona holds `Broker_Listing__c` create + edit already (§1.7), so this can
   be plain DML — **but** `Disposition__c` may be locked by `Closing_Approval`; Active Listing is far
   from Closing, so this should be unreachable. State it, do not assume it.
8. **Tests.** `DispositionStageEntryService` is trigger-driven → the 251-record bulk mandate applies in
   full (its existing tests are the template). The scheduled job needs a 251-row locator test. The broker
   change is a user-invoked singleton but still needs the constant-budget assertion.

---

## §4 — DEPLOYMENT ORDER

### Item A (deploy first — one window)

```
1. Apex: PropertyAssetSelector (+ new method) · OpportunitySelector (+ new method)
         PropertyAssetService · OpportunityReviewTriggerHandler · PropertyAssetServiceTest
   → one deploy; the handler line and the service must land together or the handler will not compile.
2. (conditional) any new field + its FLS — BEFORE the Apex that writes it.
```

### Item B (deploy second — two phases, and the boundary is where failure changes character)

```
PHASE B1 — DECLARATIVE (fails LOUDLY at deploy)
  new field(s) on Disposition__c  →  FLS on 4 permission sets  →  Path guidance corrections
  →  Broker_Listing__c picklist value (if adopted)  →  quick action + its LWC bundle
  🔴 A quick action referencing an LWC bundle that is not in the same deploy FAILS. Deploy together.

PHASE B2 — APEX + LWC (fails SILENTLY)
  BrokerListingController threshold change  ·  DispositionStageEntryService block
  ·  DispositionOfferSelector  ·  broker-change service  ·  listingAlerts rewrite
  ·  dispositionOffer.html string  ·  Schedulable (if B-Q4 = job)
  ·  all Apex tests + all Jest tests

POST-DEPLOY (not metadata, and the feature is dead without it)
  Schedule the Schedulable.
```

The B1/B2 split is the D26 4A/4B argument reapplied: a green declarative deploy plus a dead Apex layer
is indistinguishable from a healthy feature, because the shipped behaviour of "no traction detected" is
*exactly* what a broken monitor produces.

---

## §5 — POST-DEPLOY GATES

Every gate is a **read-back**, never a "the deploy/seed/job completed without error" — the standing
lesson from gate A2, `TestDataFactoryTest` and D13's `isAvailable()` residual.

### Item A

| # | Gate | How |
|---|---|---|
| **A-G1** | 🔴 **Close one real deal and re-query the asset.** `SELECT Id, Name, Property__c, Status__c, Property_Type__c, <A-Q1 fields> FROM Property_Asset__c WHERE Property__c = :<the deal's property>`. Assert every intended value LANDED. **The insert succeeding is not the gate.** | anonymous Apex / query |
| **A-G2** | 🔴 **Both routes.** Repeat A-G1 for a deal closed by `advance()` from `PSA`/`About to Close`, **and** for one closed by flipping a `Transaction__c` to `Closed`. The second is the one that will be skipped and is the one that runs as a different persona. | manual |
| **A-G3** | **Idempotency.** Re-save the closed Opportunity; assert the asset count for that Property is still 1. | query |
| **A-G4** | 🔴 **As a non-admin.** Run A-G2's Transaction route **as a Transactions persona, not as an administrator.** This is the only thing that proves the `SYSTEM_MODE` selector decision. An admin smoke test proves nothing about FLS — the measured lesson from `OpportunityActionPermissionService`. | manual, as persona |
| **A-G5** | **`Property_Type__c` sanity** (if A-Q2 = map). Query `SELECT Property_Type__c, COUNT(Id) FROM Property_Asset__c GROUP BY Property_Type__c` and confirm no off-list value appeared — the field is unrestricted, so this is the only detection. | query |
| **A-G6** | **PM child creation.** From the new asset, create one `Unit__c` and one `Onboarding__c`. Confirms the tree actually hangs. | manual |

### Item B

| # | Gate | How |
|---|---|---|
| **B-G1** | 🔴 **SCHEDULE THE JOB** (if B-Q4 = job), then `SELECT Id, CronExpression, State, NextFireTime FROM CronTrigger` and read it back. **A deploy that skips this silently disables every automated transition in the design** — and leaves a worse state than before, because the UI will now show a band that nothing maintains. | Setup + query |
| **B-G2** | 🔴 **Verify the corrected clock in ALL SIX places from §1.4** — the two paths, the Apex, and the two LWC strings. Reading the Path in the UI is not enough; `BrokerListingController` and `dispositionOffer.html` are separate surfaces on the same screen. | manual + grep |
| **B-G3** | **Seed an aged listing** (`Listing_Date__c = TODAY() - 35`, zero offers) and confirm the day-30 state appears in the LWC **and** in `Broker_Alert_Due` (if B-Q5 = yes). Then a second at −65 days for the 60-day boundary. | seed + manual |
| **B-G4** | 🔴 **Read the state back as a disposition persona, not an admin.** New fields deployed by the Metadata API arrive with **no FLS for any profile, System Administrator included**. | manual, as persona |
| **B-G5** | **Broker change end-to-end**, then re-query: the two `BOV_Submission__c` statuses swapped, `Selected_Broker__c` re-stamped, a second `Broker_Listing__c` exists, and `lwc/brokerListing` shows the *new* broker (it reads `CreatedDate DESC LIMIT 1`). | manual + query |
| **B-G6** | **`listingAlerts` shows no deferred-notification promise.** Visual check that the D9-deferred alerts are not advertised as live. | manual |
| **B-G7** | **Jest suite green** — `listingAlerts.test.js` and `brokerListing.test.js` both rewritten and passing, `@sa11y/jest` included. Jest is local-only and never deploys, so it is not covered by any org gate. | `npm test` |

---

## §6 — EXPLICITLY OUT OF SCOPE

- **Every notification, both items** — D9. Including the month-1 traction alert, the "email to Junior"
  and "alert to Junior + Ali" rows currently hardcoded in `listingAlerts.html`, and any
  `Property_Asset__c`-created announcement.
- **Anything in Tranches 2 / 3 / 4** (`3e798d2` / `fce1996` / `0be277d`).
- **Best-and-final** — D26 / Q3, decided not built.
- **Dead/Pass** — D27.2, no change.
- **Converting the disposition broker chain to `Contact` lookups** — module-wide, its own tranche (B-Q3).
- **A `Primary_Asset__c` / `Property_Asset__c` lookup on `Opportunity`** — deliberately not proposed
  (§2.3); it would re-open the approval-lock/deferred-stamp problem for no requested benefit.
- **Changing the Sell Meter's `Peak_Sell_Date__c != null` filter** — §2.5; correct as it stands.
- **`OpportunitySelector.selectExecutionHandoffByIds`'s `USER_MODE`** on the same trigger path —
  reported (§2.7), not fixed.
- **`Property_Management_Access`'s `viewAllRecords=false`** on `Property_Asset__c` — flagged (§1.7),
  not changed.
- **`Package_Sent__c`** (a Date carrying a rule-4 past-participle Boolean name on `Disposition__c`) —
  a known open §1 item, out of this scope.

---

## §7 — `ARCHITECTURE.md` UPDATES REQUIRED IN THE SAME PR (§6 of that document)

- **§2 Key Apex Services** — add `PropertyAssetService` (Item A) and any new disposition service (Item B).
- **§2 `WITH SYSTEM_MODE` automation-path table** — add the new `PropertyAssetSelector` /
  `OpportunitySelector` rows with their own justifications. The repo count moves from 22 across 13.
- **§1 Current objects** — no new objects, so no new rows. But `Property_Asset__c`'s _Purpose_ is
  currently `—` (one of the 22 unset descriptions) and it is about to acquire an automated creator;
  worth writing the `<description>` while the reason is fresh.
