# Disposition BA Gap Closure — TRANCHE 1 Design (Schema & Access Foundation)

**Date:** 2026-08-31
**Agent:** salesforce-design (analysis only — no metadata, no Apex, no org writes)
**Branch at time of writing:** `qa/lifecycle-simulation-2026-08-27`
**Scope:** exactly the 12 numbered items in the request. Nothing added, nothing expanded.
**Sources read in the order requested:** `agent-output/disposition-ba-stories-gap-analysis.md`
(including the USER-CONFIRMED conflict resolutions, treated as decisions), `ARCHITECTURE.md`,
`CLAUDE.md`, `docs/2026-08-19-disposition-flow-redesign.md`,
`docs/2026-08-20-disposition-tranche-2.md`.

---

## 0. Mandatory gate declarations

```
intent=type | best_matched_skill=none (design step only — no metadata generated here)
skill_selection=complete
mcp=unavailable | mcp_tools=none
```

`.claude/rules/salesforce-global-rule.md` mandates a `salesforce-api-context` MCP call per metadata
type. **A real attempt is not possible from this agent** — `.mcp.json` configures only the
`salesforce` server and subagents carry no MCP tools at all (memory:
`api-context-mcp-not-configured`). Recorded as `mcp=unavailable`, `mcp_tools=none`. Every
implementing agent must re-attempt and re-record for **each** metadata type it writes, and fall
back to the per-type skill.

**Consequence carried into the plan:** where an XML shape is not already exercised in this repo, it
is raised as a **blocking gate with a one-item dry-run**, never guessed. Precedent for why:
`ARCHITECTURE.md` §3.4 (the SharePoint OAuth External Credential shape could not be confirmed at
67.0 and had to be hand-built). The two shapes in this tranche that qualify are **G-6** (list-view
record-type filter) and **G-4** (`<formulaTreatBlanksAs>` on a new Number formula).

---

## 1. Premise verification — what I measured in the repo before designing

Per standing practice, every load-bearing claim in the request was checked against the tree rather
than accepted. Eleven of twelve premises hold. **Six premises are incomplete or wrong in a way that
changes the design**, and they are listed first because they drive the recommendations below.

### 1.1 CONFIRMED premises

| Claim | Verdict | Evidence |
|---|---|---|
| `NDA__c` has no `Principal_Approved__c` / `Approved_For_Release__c` / `Buyer_Response_Date__c` | ✅ | `objects/NDA__c/fields/` — 25 field files, none of the three |
| `BOV_Submission__c` has no `Buyer_Ready__c` / `Known_Performer__c` | ✅ | `objects/BOV_Submission__c/fields/` — 20 files, neither present |
| `Broker_Listing__c` has no `Broker__c` lookup | ✅ | `objects/Broker_Listing__c/fields/` — 9 files, only `Broker_Firm__c` / `Contact_Name__c` Text |
| `Broker_Listing__c.Days_On_Market__c` is a plain stored `Number(4,0)` | ✅ | field file lines 6-11, no `<formula>` |
| `Disposition__c.Days_On_Market__c` is a formula off `Listing_Date__c` | ✅ | `IF(ISBLANK(Listing_Date__c), null, TODAY() - Listing_Date__c)`, `BlankAsZero` |
| `Disposition__c` has no `Offers_Received__c`; `Responses_Received__c` exists and is a plain `Number(3,0)` | ✅ | `objects/Disposition__c/fields/` |
| No roll-up summary is possible — every child is a Lookup | ✅ | `Disposition_Offer__c.Disposition__c`, `BOV_Submission__c.Disposition__c` are Lookups |
| `Disposition__c.Property_Asset__c` is `<required>false</required>` | ✅ | field file line 9 |
| `Disposition__c` has exactly 3 validation rules, none touching `RecordTypeId` | ✅ | `validationRules/` = `All_NDAs_Signed_Before_Progression`, `Broker_Lookup_Is_Off_Market_Only`, `Wire_Complete_Before_Sale_Closes` |
| Neither disposition permission set grants `Property__c` / `Property_Asset__c` / `Offering__c` / `Transaction__c` | ✅ | `DPEG_Disposition_View` `objectPermissions` = 12 entries, all disposition-module objects; same in `_Edit` |
| **8 of 13** disposition reports run on `Property_Asset__c` | ✅ **exactly 8** | `Portfolio_Sell_Readiness`, `Sell_Ready_Argus`, `Total_Argus_Value`, `Properties_by_Argus_Value`, `Properties_in_AUM`, `Readiness_Mix`, `Readiness_Signal_By_Value_Avk`, `Sell_Readiness_By_Type` |
| `Disposition_Dashboard_Access` grants `Property_Asset__c.Argus_Value__c` `editable=true` | ✅ | file line 34-38 |
| `Wire__c.Verified_DateTime__c` is `editable=true` in `DPEG_Disposition_Edit`; `Wire__c` has zero VRs | ✅ | permission set line 2062-2065; no `objects/Wire__c/validationRules/` |
| `Disposition__c` has zero source-controlled list views | ✅ | no `listViews/` folder, no `<listViews>` in the object file |

### 1.2 🔴 SIX PREMISES THAT ARE INCOMPLETE OR WRONG — read these before scoping

**P-1. Item 6's "additive deprecation pattern" instruction is right, but for a reason the request
does not state — and the reason removes an option the request implies exists.**
Salesforce **cannot change an existing custom field into a Formula field.** There is no in-place
type change to Formula in the UI or the Metadata API. So "convert `Broker_Listing__c.Days_On_Market__c`
to a formula" is a **delete + create**, not an edit — and a deleted API name stays reserved until
manually **ERASED** in Setup (irreversible, and blocked while Apex references the field). This turns
the naive route into 5 waves with the test suite red in between. See §3.6 for the two options.

**P-2. Item 6's consumer list is incomplete in the two places that break a deploy and a seed run.**
The request names `BrokerListingSelector`, `brokerListing`, `Disposition_Dashboard_Access` and the
`Avg_Days_on_Market` report. Three more exist and each is a hard failure:

- 🔴 `DPEG_Disposition_Edit:1409-1413` grants `Broker_Listing__c.Days_On_Market__c` with
  **`<editable>true</editable>`**. **`editable=true` on a formula field is a DEPLOY ERROR.**
- 🔴 **Three seed scripts assign the field** — `scripts/seed-disposition.apex:217`,
  `scripts/seed-disposition-bulk.apex:372,377,382,387`, `scripts/seed-disp0002.apex:183`. A formula
  field is not writable in Apex, so each becomes a **compile error in anonymous Apex**.
- `objectTranslations/Broker_Listing__c-en_US/Days_On_Market__c.fieldTranslation-meta.xml` and
  `manifest/package.xml:293` both name it.
- ⚠ `lwc/brokerListing` does **not** read the field. `BrokerListingController` computes days in Apex
  from the raw date. `BrokerListingSelector.cls:53-57` states the field is **"LEGACY: a hand-keyed
  Number that nothing writes"**, retained deliberately so removing it is a decision, not a side
  effect. So the LWC is not a blocker — the permission set and the seeds are.

**P-3. 🔴 Item 6 collides with a live design decision and with an in-flight design doc.**
`DispositionStageEntryService.cls:1008-1011` leaves `Broker_Listing__c.Days_On_Market__c` **blank on
purpose** on auto-create — *"seeding a 0 would resurrect the very field the clock was moved OFF."*
The marketing clock was deliberately moved **off** this field into
`DispositionTractionService.evaluate`, which computes days in Apex and (per the pending design at
`agent-output/listing-alerts-and-escalation.md` §7.2) is to gain a **pause at first offer**. A naive
`TODAY() - List_Date__c` formula **keeps counting after an offer arrives** and will therefore
disagree with the badge rendered beside it on the same card. This is a genuine decision, not a
detail — see **D-3**.

**P-4. 🔴 Item 7's "account for … undelete" collides with a recorded 2026-08-24 refusal on the BOV
side.** `BovSubmissionTrigger` is `(before insert, before update, after insert, after update, after
delete)` and its header states in terms: *"🔴 STILL NO `after undelete`: see
`BovAutoSelectionService.reselectForDeleted` for the three things that depend on the undelete
duplicate remaining REACHABLE rather than silently self-healed."* Adding the context is required for
the counter but must **not** route `BovAutoSelectionService`. See **D-5**.
Separately, `DispositionOfferTrigger` is `(before insert, before update, after update)` — it has
**no `after insert`, no `after delete`, no `after undelete`**, so three contexts must be added there.

**P-5. 🔴 Item 8 (`required = true`) has a blocker the request does not name, and a live blast
radius in the test suite.**
- `Disposition__c.Property_Asset__c` is `deleteConstraint SetNull`. **Salesforce forces `Restrict` on
  a required lookup.** `Restrict` would block deletion of any `Property_Asset__c` that has ever had a
  disposition, org-wide. Memory `required-flag-vs-validation-rule` records this exact collision on
  `BOV_Submission__c.Broker__c`, whose own header carries a 🔴 banner forbidding the switch.
- `BOV_Score__c`'s own header depends on the current nullability: *"⚠ A NULL `Property_Asset__c`
  LOOKUP ON THE DISPOSITION IS COVERED BY THE SAME `ISBLANK`. The lookup is not required
  (`deleteConstraint SetNull`), so the whole chain can be null."*
- **Nine test call sites already create a Disposition with a null asset** —
  `DispositionMaterialsStampTest:57,109,172,205,220`, `DispositionBuyerTimelineTest:154`,
  `DispositionDomainTest:103,111`, `RecordStageAdvanceServiceTest:2234`. Six of those insert.
- `scripts/seed-lakeline-asset-repair.apex` exists **specifically to repair a live disposition whose
  `Property_Asset__c` was null**, so null rows have existed in this org.
- ✅ The two Apex create paths are clean: `DispositionService.findOrCreate:323` and
  `initiateAndSubmit:445` both set `Property_Asset__c`. All 6 seed scripts that create dispositions
  set it too. **The break is the test suite, not production.** See **D-6**.

**P-6. 🔴 Item 3's framing of `Release_Materials_Response__c` is wrong in the way that matters.**
That object carries `Disposition__c`, **`Broker__c`**, `Entry_DateTime__c`, `Method__c`, `Notes__c`.
It has **no `Buyer__c` and no `NDA__c` lookup**. It is **disposition-scoped and BROKER-scoped**, so
it structurally *cannot* record a per-buyer response. `NDA__c.Buyer_Response_Date__c` is
**per-party**. They are complementary, not duplicates — the request's implied overlap does not
exist. See **D-2**.

**Additional finding, not a premise but load-bearing for item 11:** the CoStar fields live on
**`Property__c`** (`CoStar_URL__c`, `CoStar_Asking_Rent_PSF__c`, `CoStar_Data_Source__c`,
`CoStar_Exit_Cap_Rate__c`, `CoStar_Fetch_Status__c`, `CoStar_Last_Synced_DateTime__c`,
`CoStar_Location_Score__c`, `CoStar_Pct_Leased__c` — 8 fields). Argus lives on **`Property_Asset__c`**
(`Argus_Value__c`, `Argus_Signal__c` — 2 fields). The gap analysis's line *"`Property_Asset__c`
carries no `*_Last_Synced_DateTime__c` field at all"* is true, but `Property__c` **does** carry one —
so story 69's "visible timestamp" is satisfiable for CoStar and not for Argus.
**And "make read-only" is the wrong verb for the disposition sets:** they grant *none* of these ten
fields today, so items 10 and 11 are a **new grant at read-only**, not a downgrade. Only
`Disposition_Dashboard_Access` is an actual downgrade (`Argus_Value__c` `true` → `false`).

---

## 2. Decisions this design asks the user to confirm

These are the only genuinely open questions. Everything else is resolved below with a recommendation
and its evidence. **Nothing here re-opens a USER-CONFIRMED resolution** — A1-A4, C1, D1-D4, E1-E4,
B1-B3 are treated as settled.

| # | Decision | Recommendation |
|---|---|---|
| **D-1** | **Item 2 mechanism, and what "fully executed" means.** `Counter_Signed_Date__c`'s own header records design decision **Q6**: *"the all-signed release gate (`All_NDAs_Signed_Before_Progression`) keys on `Status__c = Signed` alone … requiring two would be an invention."* Defining `Approved_For_Release__c` as *Signed + counter-signed* would create a **second, disagreeing release condition** on the same object. | **FORMULA (Checkbox): `ISPICKVAL(Status__c, 'Signed')`.** Zero writers, cannot latch, self-corrects, no FLS-write risk, no flow, no trigger, no rollback path. **A Declined NDA reads FALSE automatically** — Status is no longer `Signed` — which is the exact inverse of the `NDA_Signed__c` latch defect this repo has already paid for. Confirm you do not want the counter-signature in the definition. |
| **D-2** | **Item 3 — does `dispositionBuyerTimeline` read the new field in T1?** Adding it to `NdaSelector.selectBuyerTimelineByDispositionId` is a **`WITH USER_MODE` selector widening = an FLS change**, and that controller deliberately does **not** fail soft (`DispositionBuyerTimelineController`: *"a `QueryException` is NOT swallowed into an empty list"*). A missing grant red-banners the whole card. | **T1 ships the FIELD + FLS only. Defer the timeline read.** T1 is "schema and access foundation"; the read is an LWC + selector + service change with a named failure mode and belongs with the tranche that reworks the timeline. Confirm. |
| **D-3** | **Item 6 — the third days-on-market definition (P-3).** A live formula on the listing will disagree with `DispositionTractionService`'s paused clock beside it. | **Ship the formula, and state in its `<description>` that it is RAW ELAPSED DAYS, not the escalation clock** — the clock's owner is `DispositionTractionService` and nothing may read the formula to drive an alert. Alternative: defer item 6's formula until Tranche 5 settles the pause. Confirm which. |
| **D-4** | **Item 6 — API name for the new formula field (forced by P-1).** The additive pattern needs a *new* name; `Days_On_Market__c` is occupied on the same object by the stored Number. | **`Days_On_Market_Live__c`** (Number formula, scale 0). Shorthand — **flagged, not invented.** Confirm or supply. |
| **D-5** | **Item 7 — `BovSubmissionTrigger` gains `after undelete` (P-4).** Required for the counter; explicitly refused in 2026-08-24 for auto-selection. | **Add the context; route ONLY the counter recompute in it.** `BovAutoSelectionService` must not be called on `afterUndelete`. The trigger header's "🔴 STILL NO after undelete" must be **retracted in place, not deleted**, per this repo's convention. Confirm. |
| **D-6** | **Item 8 — mechanism (P-5).** `required=true` forces `deleteConstraint Restrict`, which this repo has refused in writing elsewhere, and reds 6 inserting test methods. | **A VALIDATION RULE, not `required=true`.** In-repo precedent is exact: `BOV_Submission__c.Broker_Required_On_Submission` exists *"because a required lookup cannot carry `deleteConstraint SetNull`."* A VR keeps `SetNull`, keeps `BOV_Score__c`'s documented null-chain guard true, and is one file to scope later. ⚠ **Either way the 9 test call sites must be repaired** — the VR does not spare them. Confirm. |
| **D-7** | **Item 9 — the admin override mechanism and the exact lock boundary.** A validation rule is **not** bypassed by Modify All Data, so "admin-overridable" needs a `$Permission` gate. | **New custom permission `Disposition_Record_Type_Override`, granted only to `DPEG_Admin_Access`**, gated as `NOT($Permission.Disposition_Record_Type_Override)` — the exact shape of `Account.Record_Type_Is_Immutable`, whose header states the rule: *"If an exemption is ever needed, add a custom permission and gate on `$Permission` — never widen the rule itself."* **Boundary:** lock from `Broker Selection` onward inclusive (i.e. free only at `Disposition Readiness` and `BOV Outreach`). Confirm both. |
| **D-8** | **Items 1/2/4 — API names vs `ARCHITECTURE.md` §1 Boolean convention** (`Is_`/`Has_` **or** `<Subject>_<PastParticiple>`). `Principal_Approved__c` ✅ conforms. `Approved_For_Release__c`, `Buyer_Ready__c`, `Known_Performer__c` ❌ do not. The three sibling Booleans on `BOV_Submission__c` are all `Is_`-prefixed (`Is_Preferred_Broker__c`, `Is_System_Selected__c`, `Is_Manually_Appointed__c`). | **`Is_Approved_For_Release__c`, `Is_Buyer_Ready__c`, `Is_Known_Performer__c`**, with **labels** "Approved for Release", "Buyer Ready", "Known Performer" so every BA-facing surface reads exactly as the story asks. Confirm — or accept the story spellings as an explicit convention exception. |
| **D-9** | **Item 7 — what the two counters actually count.** | `Offers_Received__c` = **all** `Disposition_Offer__c` rows on the disposition, every status (story 37 keeps Rejected/Countered/Withdrawn visible). `Responses_Received__c` = **all** `BOV_Submission__c` rows on the disposition. Both `<defaultValue>0</defaultValue>`, matching `Broker_Listing__c.Offers_Received__c`. Confirm. |
| **D-10** | **Item 7 — the counter write and sharing.** The parent write must be `SYSTEM_MODE` (the fields will be read-only FLS). 🔴 **`SYSTEM_MODE` lifts CRUD/FLS but NEVER sharing** — a measured production incident in this repo: an approval's parent write failed silently for every approver who did not OWN the record, and `allOrNone=false` swallowed it. Both disposition sets carry `viewAllRecords=true` on `Disposition__c`, which is **read**, not write. | **Wrap the parent update in a narrow `private without sharing` inner class**, separately justified in the handler header per `ARCHITECTURE.md` §2 — a counter that silently diverges for non-owners is exactly the defect class this org has already paid for. Alternative: accept staleness. Confirm. |
| **D-11** | **Items 10/11 — field scope on `Property__c`, `Offering__c`, `Transaction__c`.** No disposition report or dashboard component touches any of these three; the grant is driven purely by story 8's "IR hand-off" AC. `Property__c` has **54** custom fields, `Transaction__c` **27**, `Offering__c` **3**. | **Do NOT grant all fields.** Grant object read + a **named minimal set**: `Property__c` → `Address__c`, `City__c`, `State__c`, `Zip__c`, `Asset_Type__c`, `Square_Footage__c`, `CoStar_URL__c` + the 7 other `CoStar_*` (item 11); `Transaction__c` → `Property__c`, `Property_Name__c`, `Stage__c`, `Status__c`, `Target_Close_Date__c`, `Contract_Value__c`, `Opportunity__c`; `Offering__c` → all 3. Confirm the lists. |
| **D-12** | **Item 12 — remove the grant, add a VR, or both.** | **BOTH, and the VR shape is not obvious.** See §3.12 for the traced formula and why the naive shapes break `WireService`. Confirm the tolerance window (recommend 1 minute). |
| **D-13** | **Item 13 — org list views are not captured.** `Disposition__c` has no `listViews/` folder, which means *either* the org has none *or* they were never retrieved. Deploying a source list view whose `fullName` matches a hand-made org one **replaces it**. | **Retrieve `Disposition__c` list views from `usman-dpeg` FIRST and diff**, before writing any file. Then ship the six proposed in §3.13. Confirm the set. |

---

## 3. Item-by-item design

### 🔵 Item 1 — `NDA__c.Principal_Approved__c` + `Principal_Approved_Date__c` — ADMIN

**Deliver:** two fields + FLS. **The approval process itself is Tranche 3** (D1) and is not designed
here.

| Field | Type | Notes |
|---|---|---|
| `Principal_Approved__c` | Checkbox, `defaultValue false` | Conforms to §1 (`<Subject>_<PastParticiple>`). |
| `Principal_Approved_Date__c` | **Date** (as requested) | ⚠ §1 forbids a `Date` suffix on a DateTime. This is date-only, so the name is correct. **But** every other approval fact in this module is captured as a DateTime elsewhere; if the Tranche-3 approval will stamp `NOW()`, the field must be a DateTime and named `Principal_Approved_DateTime__c`. Raised, not decided. |

🔴 **Design conflict to record now, so Tranche 3 does not rediscover it.** The `Disposition_NDA`
record type **already carries `Status__c = 'Approved'`** (sequence: `Prepare → Approved → Sent →
Signed`, `Declined` terminal, **no default**). So after item 1 the object holds **two
representations of "a principal approved this NDA"**. Intended split, to be written into both field
descriptions: `Status__c = 'Approved'` is the **lifecycle position** (drives the Path);
`Principal_Approved__c` + date is the **machine-written audit fact** (who/when — which a workflow
field update cannot capture, which is precisely why `ApprovalAuditService` exists). Tranche 3's final
approval action should set **both**.

**FLS:** read in `DPEG_Disposition_View`, **read-only in `DPEG_Disposition_Edit` too** — these are
approval-written facts, and `BOV_Broker_Change__c`'s 2026-08-20 code-review reconciliation is the
precedent (*"granting `allowEdit` … would let the very analyst who replaced a broker go back and
rewrite who did it and when"*).

**Risk:** LOW. Two new fields, no reader, no writer in T1. The only hazard is the standard one — a
Metadata-API field arrives with **no FLS for anyone, System Administrator included** — closed by the
consolidated permission pass (§3.10).

---

### 🔵 Item 2 — `NDA__c.Approved_For_Release__c` — ADMIN

**Mechanism: FORMULA (Checkbox). Recommended, see D-1.**

```
ISPICKVAL(Status__c, 'Signed')
```

**Why a formula and not a flow-written or trigger-written checkbox — the three mechanisms priced:**

| Mechanism | Verdict |
|---|---|
| **Formula** ✅ | Cannot latch. Cannot be hand-edited. No FLS-write exposure. No flow, no trigger, no rollback path, no `SYSTEM_MODE` question, no bulk-test obligation. **It is structurally incapable of the `NDA_Signed__c` failure.** |
| Flow-written checkbox ❌ | Would be a *fourth* automation on `NDA__c` alongside `NDA_Signed_Status_Sync` and `NDA_Signed_Rollup`. `NDA_Signed_Rollup` runs `SystemModeWithoutSharing` with a fault connector that **converts a failed parent update into a stale count rather than a visible error** — this repo already has one silently-degrading NDA flow and does not need a second. |
| Trigger-written ❌ | `NdaTrigger` exists (`before insert, before update`) and is safe **by construction** because its one service is change-keyed on `Buyer__c` and returns after one in-memory pass with zero queries. Adding an unconditional status-derived write would widen that blast radius across **every acquisition NDA in the org** for a value a formula computes for free. |

**🔴 How a Declined NDA must behave — stated explicitly, as requested.**
Under the formula it reads **FALSE the moment `Status__c` moves to `Declined`**, with no writer and
no latch. This is the deliberate inverse of `NDA_Signed__c`, whose own field header warns: *"DO NOT
USE THIS FIELD TO ANSWER 'DID THIS PARTY SIGN'. Use `Status__c`. The checkbox latches true across
Sent, Received, Pending and Not Sent."* A party who signs and later declines **loses** release
approval — correct, and unreachable by a checkbox anyone can write.

**Relationship to the existing machinery — nothing is changed, and here is why:**
- `NDA_Signed__c` **latches** and is granted **only** to the acquisition sets. Deliberately not read.
- `NDA_Signed_Status_Sync` (before-save) sets `NDA_Signed__c` true on `Signed`, false on `Declined`,
  and touches nothing else. Unchanged.
- `NDA_Signed_Rollup` (after-save) maintains `NDA_Count__c` / `Signed_NDA_Count__c` and
  **deliberately counts Declined rows** (D20/C2). Unchanged — that is a **parent-level** count and
  this is a **per-party** flag. They answer different questions and must not be reconciled.
- ⚠ `Approved_For_Release__c` and `All_NDAs_Signed_Before_Progression` will now key on the **same**
  condition (`Status__c = 'Signed'`), by design. That is the point: one release condition, two
  surfaces, per Q6.

**FLS:** read-only in **both** sets (a formula field cannot be `editable=true` — that is a deploy
error).

**Risk:** LOW-MEDIUM. The only real exposure is **D-1**: if the BA intends "fully executed" to mean
counter-signed as well, the formula must change and it silently disagrees with the stage gate until
it does.

---

### 🔵 Item 3 — `NDA__c.Buyer_Response_Date__c` — ADMIN

**Deliver:** `Buyer_Response_Date__c`, **Date**, hand-entered, not required, no default. Naming
conforms to §1 (date-only ⇒ `Date` suffix).

**🔴 How it relates to `Release_Materials_Response__c` — the request's framing is wrong (P-6).**

| | `NDA__c.Buyer_Response_Date__c` (new) | `Release_Materials_Response__c` (existing) |
|---|---|---|
| Scope | **Per NDA = per party** | **Per disposition, per BROKER** (`Disposition__c` + `Broker__c`) |
| Can it name a buyer? | Yes — the NDA carries `Buyer__c` and `Party_Role__c = 'Buyer'` | **No.** The object has no `Buyer__c` and no `NDA__c` lookup |
| Granularity | Date | DateTime (`Entry_DateTime__c`) + `Method__c` + `Notes__c` |

They are **complementary, not duplicates.** The child object cannot express a per-buyer response at
any price without a schema change, which is out of scope. This is the classic per-party join trap:
a parent-scoped log cannot answer a child-scoped question.

**Should `dispositionBuyerTimeline` read both? — Recommendation: not in T1 (D-2).**
Today `DispositionBuyerTimelineService` computes `daysToRespond = span(materialsReleased,
firstOfferDate)`, where `firstOfferDate` comes from
`DispositionOfferSelector.selectEarliestByBuyerIds`. The new field is an **earlier, weaker signal** —
"the buyer replied", not "the buyer bid". Reading it is a real improvement and a real risk:

- 🔴 Adding it to `NdaSelector.selectBuyerTimelineByDispositionId` is a **`USER_MODE` selector
  widening = an FLS change**. `USER_MODE` *throws, it does not degrade*, and this controller
  **deliberately does not fail soft**, so one missing grant replaces the card with a red banner.
- ⚠ Recall the module-asymmetric baseline: the two disposition sets grant **four** `NDA__c` fields
  today, while `Date_Signed__c` / `Disposition__c` / `Counterparty_Name__c` / `NDA_Signed__c` /
  `Date_Sent__c` are granted **only** in the acquisition sets. Any NDA-field read from a disposition
  persona must be grant-checked field by field, not assumed.
- ⚠ If it is later read, it must sit **behind `buildRow`'s early return for Declined rows**, exactly
  as `Date_Signed__c` does — otherwise a declined party's retained response date leaks onto a row the
  service is documented to keep date-free.

**Risk:** LOW as scoped (field + FLS). MEDIUM if the timeline read is pulled into T1.

---

### 🔵 Item 4 — `BOV_Submission__c` Buyer-Ready / Known-Performer flags — ADMIN

**Deliver:** two Checkboxes + FLS. Recommended names per **D-8**: `Is_Buyer_Ready__c`,
`Is_Known_Performer__c`, labels "Buyer Ready" / "Known Performer". `defaultValue false`.
**FLS:** read in View, **editable in `DPEG_Disposition_Edit`** — unlike items 1-2 these are analyst
judgements, hand-entered, and story 20 requires them to be settable.

**🔴 Tranche-4 formula-change implication, flagged as requested — and it is larger than a
re-weighting.** `BOV_Score__c` today is `50 (value) + 25 (commission) + 25 (speed)`, with a hard
`null` guard. Folding two Booleans in means:

1. The **3,900-character cap is on the COMPILED formula**, and `BOV_Score__c` already spans
   **two relationship hops** (`Disposition__r.Property_Asset__r.Target_Sale_Price__c`), which expand
   heavily at compile. Count before adding branches.
2. 🔴 The `null` guard is **load-bearing and must survive**. Its own header: *"That null means NOT
   SCOREABLE, never worst … Changing the guard to a 0 would silently make every unpriced sale
   auto-appoint whichever broker quoted first."* `BovAutoSelectionService` skips null-scored rows and
   `BovSubmissionSelector`'s `ORDER BY BOV_Score__c DESC NULLS LAST` depends on it.
3. `formulaTreatBlanksAs` is `BlankAsBlank` here **deliberately** — a Boolean folded in with
   `BlankAsZero` would make an unset flag score as an explicit "no", which is different from "not
   yet assessed".
4. Any re-weighting changes **which broker is auto-appointed** on live in-flight sales. That is a
   data-affecting change, not a formula edit.

**Risk:** LOW in T1 (two inert Booleans). The risk is entirely deferred into Tranche 4.

---

### 🔵 Item 5 — `Broker_Listing__c.Broker__c` (Lookup → Contact) — ADMIN

**Deliver:** the sixth member of the broker-lookup family, byte-consistent with the five reconciled
on 2026-08-20.

```
type            Lookup
referenceTo     Contact
deleteConstraint SetNull          ← matches all five siblings. NEVER Restrict.
lookupFilter    active=true, isOptional=false, booleanFilter=1
                Contact.RecordType.DeveloperName equals Broker
errorMessage    "Only Broker Contacts can be selected here."
relationshipName  Broker_Listings   ← PROVISIONAL, see below
```

**Why `Is_Broker__c` must not be used** — measured live on `usman-dpeg`, 2026-08-20, and written up
in full in `objects/Disposition__c/fields/Broker__c.field-meta.xml`:

```
SELECT COUNT(Id) FROM Contact WHERE Is_Broker__c = true                 -> 0
SELECT COUNT(Id) FROM Contact WHERE RecordType.DeveloperName = 'Broker' -> 19
```

Three fields enforced the checkbox predicate for months and silently refused **every real broker in
the org**. `Is_Broker__c` is retained but no longer defines anything.

**🔴 `relationshipName` must be collision-checked against `Contact`, not assumed.** Known occupants:
`Broker_Assignments`, `Lease_Inquiries`, `Brokered_Opportunities`, `Brokered_Dispositions`, plus the
two on `BOV_Broker_Change__c`. `Broker_Listings` is the bare plural, justified by the same rule the
Disposition field's header states (*bare plural when the object exists only to be about a broker*).
⚠ **A `relationshipName` is disruptive to change after deploy — settle it before the first deploy.**

**🔴 THE SEED GUARD IS NOW INCOMPLETE — this is a genuine new finding, and it is a DEV task.**
`scripts/seed-broker-contacts.apex` mass-deletes broker Contacts. With `SetNull` on all six lookups,
re-running it **nulls this field with no error and no warning**. The script's six-step guard
(STEP 2 scan / STEP 3 abort gate) was written naming **four** dependent lookups. A fifth and sixth
now exist. The guard's scan must be widened to include `Broker_Listing__c.Broker__c`, and its header
comment must name it. **Do not "fix" this by switching to `Restrict`** — the field header forbids it
in terms.

**🔴 What this field does NOT do in T1, stated so nobody assumes otherwise.** `Broker_Listing__c`
already carries `Broker_Firm__c` and `Contact_Name__c` as Text, and
`DispositionStageEntryService` **copies `Disposition__c.Selected_Broker__c` straight into
`Broker_Firm__c`** on auto-create. T1 adds **no stamp service**, so:
- the lookup is **blank on every auto-created listing**, and
- the same lookup/text duality (and the same documented Contact-rename staleness) now exists on a
  second object.
That is acceptable for a "schema foundation" tranche **only if it is written into the field
description**. The stamp is a separate, un-scoped item.

**⚠ Do NOT widen `BrokerListingSelector.selectMostRecentByDispositionId` in T1.** Its field list is
marked *"🔴 THE FIELD LIST IS A CONTRACT"*, it is `WITH USER_MODE`, and it backs the Active Listing
card. Adding a field there is an FLS change with a red-banner failure mode. Field + FLS only.

**⚠ Test fixtures:** any `Broker_Listing__c` fixture that sets this field must use
`TestDataFactory.createBrokerContact(s)`. The lookup filter is **active and non-optional**, so a
plain `createContacts()` Contact is refused at DML.

**Risk:** MEDIUM — entirely because of the seed guard and the relationship-name collision check.

---

### 🔵 Item 6 — `Broker_Listing__c.Days_On_Market__c` → live formula; retire the Disposition copy — ADMIN + DEV

**🔴 This is the highest-risk item in the tranche and the one whose stated shape is not achievable
as written.** See P-1, P-2, P-3.

#### The two routes

| | **Option A — additive (RECOMMENDED)** | Option B — erase and reuse |
|---|---|---|
| Waves | **2** | **5** |
| Suite | **green throughout** | **red between waves 2 and 5** |
| Shape | Create **`Days_On_Market_Live__c`** (Number formula) alongside; repoint readers; leave the stored `Days_On_Market__c` in place under an additive-retirement header | Strip every Apex/seed ref → delete → **manually ERASE in Setup (irreversible)** → recreate as a formula → restore refs |
| `editable=true` grant | Untouched — stays legal on the stored field | Must be flipped to `editable=false` in the **same** deploy or the deploy fails |
| 3 seed scripts | Keep working unchanged | **Compile-error** until repointed |
| Precedent | ✅ This repo's standing rule. `Asking_Price__c` and `BOV_Score__c`'s header: *"The field itself is NOT deleted (additive retirement, per this repo's standing rule)"* | none |

**Recommend Option A.** The request already directs "additive deprecation … never an in-place
rename"; P-1 is why that instruction is not merely stylistic — an in-place rename to a formula is not
a thing Salesforce can do.

#### The formula

```
IF(ISBLANK(List_Date__c), null, TODAY() - List_Date__c)
```

Copied in shape from `Disposition__c.Days_On_Market__c`, which is the in-repo precedent for a Number
formula that returns **`null`** rather than 0 for an un-datable row. **Return `null`, not 0** —
`BOV_Score__c`'s header records the general form of that trap.
⚠ **GATE G-4:** the Disposition precedent sets `<formulaTreatBlanksAs>BlankAsZero</...>` *with* an
explicit `ISBLANK` guard. The enum spelling and its interaction on a fresh field is not confirmable
without MCP → mirror the precedent exactly and confirm by dry-run; a bad enum fails loudly, which is
the safe direction.

#### Consumers — the complete list (P-2), with the action for each

| Consumer | Action |
|---|---|
| `BrokerListingSelector.selectMostRecentByDispositionId:71` | **DEV.** Repoint `Days_On_Market__c` → `Days_On_Market_Live__c`. ⚠ Widening this `USER_MODE` list is an FLS change — the grant must land in the same deploy. |
| `lwc/brokerListing` / `BrokerListingController:132-139` | **No change.** Computes from the raw date; does not read either field. |
| `DispositionStageEntryService:1008-1011` | **No change** — but its comment ("seeding a 0 would resurrect the very field the clock was moved OFF") must be **amended in place**, since a formula cannot be seeded at all. |
| `DPEG_Disposition_Edit:1409-1413` (`editable=true`) | **No change under Option A.** 🔴 Under Option B this is a **deploy error**. |
| 3 seed scripts, 6 assignment sites | **No change under Option A.** 🔴 Under Option B, compile errors. |
| `objectTranslations/Broker_Listing__c-en_US/Days_On_Market__c` | Add a sibling translation for the new field. |
| `manifest/package.xml:293` | Add the new member. |
| `BrokerListingSelectorTest:47` | Asserts `Offers_Received__c`, not DOM. **No change.** |

#### 🔴 Retiring `Disposition__c.Days_On_Market__c` has a blocker

`reports/Dispositions/Avg_Days_on_Market.report-meta.xml` is `reportType
CustomEntity$Disposition__c` and its only measure is `Disposition__c.Days_On_Market__c`.
**A report on the Disposition report type cannot show a `Broker_Listing__c` field.** No
Disposition-with-Broker-Listing or Broker-Listing report type exists in this repo. So repointing that
report is **not a field swap — it needs a new report type**, which is out of T1 scope.

⚠ And reports **do not block field deletion; they break silently** (memory: `field-rename-traps`).
Deleting the Disposition formula would leave a dashboard component rendering nothing, with no error
anywhere.

**Recommended T1 boundary:** T1 **creates** the listing formula and repoints the selector. The
Disposition copy is marked **additively retired in its `<description>` and dropped from
`Disposition_Dashboard_Access`** only if the report is repointed first; otherwise **leave both the
report and the grant alone** and carry the retirement as a named follow-up. Deleting the field is
**not** in T1 under any option.

**Risk:** HIGH. Contains the tranche's only deploy-breaking and seed-breaking mechanics.

---

### 🔵🟢 Item 7 — `Offers_Received__c` (new) + a writer for `Responses_Received__c` — ADMIN + DEV

#### Admin half

`Disposition__c.Offers_Received__c` — Number(4,0), `<defaultValue>0</defaultValue>`, matching
`Broker_Listing__c.Offers_Received__c`.

🔴 **`Offers_Received__c` will now exist on THREE objects** — `Contact`, `Broker_Listing__c`, and
`Disposition__c`. `Days_On_Market__c` already exists on two, plus `Contact.Avg_Days_On_Market__c`.
**`sf sobject describe` is a stale cache and a same-named sibling makes a sloppy verification confirm
the wrong field.** Post-deploy verification **must** use the Tooling API `CustomField` with an
explicit `TableEnumOrId`, never a describe and never a bare name match.

⚠ Naming tension, noted not decided: §1's type-suffix discipline would prefer `_Count__c` for a
Number whose name reads categorical. **Recommend keeping `Offers_Received__c`** for consistency with
the two existing siblings and FSD Table 24's own label. `Brokers_Contacted__c` **stays manual** as
directed — it records how many brokers were *asked*, which is not derivable.

**FLS:** **read-only in BOTH sets.** These are machine-maintained. Granting edit would let a user
overwrite a counter that the next child save silently recomputes — a confident wrong answer.

#### Developer half

**Layer plan** (per `ARCHITECTURE.md` §2 and `.claude/rules/apex-layering-rule.md`):

| Layer | Component | Note |
|---|---|---|
| Selector | `DispositionOfferSelector` | **`countByDispositionIds` ALREADY EXISTS** — reuse, do not add a second. |
| Selector | `BovSubmissionSelector` | Add a matching aggregate count method. `WITH SYSTEM_MODE`, justified **at its own declaration** — this is an automation-path read nobody asked for, and `USER_MODE` inside a trigger throws `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the user's own save. |
| Service | **new** `DispositionCounterRollupService` | One home for both counters. Zero inline SOQL. Takes `Set<Id>` parent ids, **recomputes** (never increments), writes once. |
| Handler | `DispositionOfferTriggerHandler` | New routing for `afterInsert`, `afterDelete`, `afterUndelete` + the existing `afterUpdate`. |
| Handler | `BovSubmissionTriggerHandler` | New routing for `afterInsert` / `afterDelete` (contexts already exist) + `afterUndelete` (new). |
| Trigger | `DispositionOfferTrigger` | 🔴 `(before insert, before update, after update)` → **add `after insert, after delete, after undelete`**. |
| Trigger | `BovSubmissionTrigger` | 🔴 **add `after undelete` ONLY** — see D-5. |

**Recompute, never increment.** An incrementing counter cannot survive a reparent, a partial
rollback, or a data load, and cannot self-heal. Recomputing is idempotent and makes the seeded
values in §"seed impact" converge rather than diverge.

**All four events, and why each is needed:**
- **insert** — a new offer/submission arrives.
- **update** — 🔴 **the parent lookup CHANGING (a reparent)**, which must recompute **both** the old
  and the new parent. A handler that only recomputes `Trigger.new`'s parent leaves the old one
  permanently one too high. Key on `Disposition__c` changing; skip the chunk entirely when it did
  not, giving a **zero-query fast path** — the same shape `BovSubmissionBrokerStampService` and
  `DispositionOfferBuyerStampService` already use, and the reason every existing fixture stays green.
- **delete** — read parent ids from `Trigger.old`.
- **undelete** — a restored row must be counted again.

**🔴 Governor budget — state it and test it.** Routing a new parent write into these triggers costs
`ceil(rows/200)` SOQL **and** DML at scale. The budget per chunk must be **exactly one aggregate
query per counted object and one `Database.update`**, asserted in the bulk test — not merely "251
rows produced 251 counters". `.claude/rules/bulk-test-rule.md` applies **in full** to both handlers
(trigger-driven, loops over collections); no exemption is available and none should be claimed.

**🔴 Write mode and sharing (D-10).** `Database.update(parents, false, AccessLevel.SYSTEM_MODE)` —
`SYSTEM_MODE` because the fields are read-only FLS; `allOrNone = false` so a counter failure never
rolls back the user's own offer save. **But `SYSTEM_MODE` does not bypass sharing**, and this repo
has a measured incident where exactly this shape failed silently for every non-owner. Recommend the
narrow `private without sharing` inner class, separately justified.

**🔴 Seed and test impact — six sites that will be silently overwritten:**
- `scripts/seed-disposition.apex:112-113`, `seed-disposition-bulk.apex:158,163`,
  `seed-disp0002.apex:83-84`, `create-on-market-disposition.apex:26-27` all hand-set
  `Responses_Received__c`. Once a trigger owns it, **the next child save overwrites the seeded
  value** with no error. Repoint or comment each.
- `BovControllerTest.cls:74,297` hand-set `Responses_Received__c`; `BovController.cls:151-152`
  reads both counters. Assertions written against a hand-set value may now be vacuous.

**Risk:** HIGH — the trigger-context expansion (two triggers, four new contexts), the documented
undelete refusal (D-5), the sharing question (D-10), and the six seed/test sites.

---

### 🔵 Item 8 — `Disposition__c.Property_Asset__c` required — ADMIN

**Recommended mechanism: a VALIDATION RULE, not `required=true` (D-6).**

```
AND(
    OR(ISNEW(), ISCHANGED(Property_Asset__c)),
    ISBLANK(Property_Asset__c)
)
```

`OR(ISNEW(), ISCHANGED(...))` mirrors `Wire_Complete_Before_Sale_Closes`'s in-repo shape and means
the rule **cannot trap an existing null row**: a legacy disposition can still be saved for any other
reason, and the remedy (supply the asset) is itself a permitted save.
⚠ If `required=true` is chosen instead, the rule becomes an all-or-nothing schema change on live
data, forces `deleteConstraint Restrict`, and **freezes every existing null row** on the next save.

**Which creation paths break — checked, as requested:**

| Path | Breaks? |
|---|---|
| `DispositionService.findOrCreate:323` | ✅ **No** — sets `Property_Asset__c = assetId` |
| `DispositionService.initiateAndSubmit:445` | ✅ **No** — same |
| `scripts/seed-dispositions.apex`, `seed-disposition.apex`, `seed-disposition-bulk.apex`, `seed-disp0002.apex`, `create-on-market-disposition.apex`, `seed-lakeline-asset-repair.apex` | ✅ **No** — all set the asset |
| 🔴 **`TestDataFactory.createDisposition(null, …)` — 9 call sites, 6 of them inserting** | ❌ **YES.** `DispositionMaterialsStampTest:57,109,172,205,220`; `DispositionBuyerTimelineTest:154`; `DispositionDomainTest:103,111`; `RecordStageAdvanceServiceTest:2234` |

**The break is entirely in the test suite**, and it breaks under **either** mechanism. Repair
(DEV): route those fixtures through a **lazily-built shared** `TestDataFactory.defaultPropertyAsset()`
— the factory already caches one (`defaultDisposition()` uses it) — never one asset per fixture.

⚠ **Re-measure before deploying.** `scripts/seed-lakeline-asset-repair.apex` exists because a live
disposition had a null asset. Run `SELECT COUNT(Id) FROM Disposition__c WHERE Property_Asset__c =
null` against `usman-dpeg` at deploy time. A non-zero result under `required=true` is an escalation,
not a deploy.

**Risk:** MEDIUM — low in production, certain in the test suite.

---

### 🔵 Item 9 — Validation rule locking `RecordTypeId` — ADMIN

**Story 2's AC.** Shape follows `Account.Record_Type_Is_Immutable` exactly, including the
`$Permission` exemption pattern that file's own header prescribes.

```
AND(
    NOT(ISNEW()),
    ISCHANGED(RecordTypeId),
    NOT(ISPICKVAL(Disposition_Stage__c, 'Disposition Readiness')),
    NOT(ISPICKVAL(Disposition_Stage__c, 'BOV Outreach')),
    NOT($Permission.Disposition_Record_Type_Override)
)
```

- `NOT(ISNEW())` + `ISCHANGED` — `DispositionService` stamps the record type **at insert** on both
  create paths, so the rule must not fire there.
- **The stage test is an exclusion list, not a rank comparison, and that is deliberate.** The two
  record types have **different sequences** (On_Market 11 stages, Off_Market 9), so no single stage
  index exists. Naming the two "not yet committed" stages is the only expressible form. Locking
  therefore begins at `Broker Selection` — matching the AC's "once Broker/NDA begins" (D-7).
- 🔴 **`$Permission` must be the three-segment form.** `{!$Permission.<Name>}` and
  `{!$CustomPermission.<Name>}` are both rejected by the Metadata API (measured 2026-08-12) — the
  Account rule's working spelling is the template.
- `errorDisplayField` → `Disposition_Stage__c`, matching the two sibling rules on this object that
  anchor there.

**New artefact required:** custom permission `Disposition_Record_Type_Override`, granted **only** to
`DPEG_Admin_Access`. This is the *mechanism* for "admin-overridable", not added scope — a validation
rule is **not** bypassed by Modify All Data, so without it the AC is unimplementable.

**⚠ Two things to grep before writing (DEV/build task, not assumed here):**
1. Does anything write `Disposition__c.RecordTypeId` **after** insert? Nothing found in the paths
   read, but the sweep must be explicit.
2. `TestDataFactory.dispositionRecordTypeId` **deliberately degrades to no record type** when the
   type is absent or unavailable (*"an undeployed record type must not turn every disposition test in
   the repo red"*). A test that later stamps a record type onto an already-inserted fixture would
   now be refused.

**Risk:** MEDIUM — the custom permission is a new dependency and the stage boundary is a judgement.

---

## 🔵 Items 10-12 — the consolidated ACCESS pass (ONE deploy, three files)

🔴 **These three items MUST be designed and deployed as a single pass, and so must every FLS grant
for items 1-7.** A `PermissionSet` deploy **REPLACES that set's entire `fieldPermissions`
collection** — a measured production incident on this project. Two partial passes means the second
silently revokes the first.

🔴 **A concurrent session shares this working tree.** `git status` already shows
`DPEG_Transaction_Edit` and `DPEG_Transaction_View` modified by work that is not this tranche. Per
the parallel-build hub-file protocol: **no other stream may edit these three files during the pass**,
and every file must be **diffed against `HEAD` immediately before deploying**, not at design time.

🔴 **RE-CONFIRM THE BASELINE AGAINST THE ORG FIRST — this is the single highest-value gate in the
tranche.** The gap analysis's own caveat 1 says it is a **repo** analysis, and on 2026-08-31 an
eight-workstream build documented as deployed was measured **entirely absent** from `usman-dpeg`. If
the org's copies of these three sets differ from the repo, a replace-semantics deploy **silently
revokes live grants**. Retrieve all three, diff against `HEAD`, reconcile, *then* edit.

### Item 10 — read-only access to `Property__c`, `Property_Asset__c`, `Offering__c`, `Transaction__c`

Both `DPEG_Disposition_View` and `DPEG_Disposition_Edit` gain, for all four objects:

```
objectPermissions: allowRead=true, allowCreate=false, allowEdit=false,
                   allowDelete=false, viewAllRecords=false, modifyAllRecords=false
```

⚠ `viewAllRecords=false` deliberately. The four older disposition objects carry `true`; NDA/LOI/PSA
were dropped to `false` by decision D17 and D24 precisely because view-all is an informed widening,
not a default. These four are **other modules' data** — sharing-scoped read is the conservative
choice. If a Disposition-only user then cannot see enough Property Assets to render the donuts, that
is a **sharing-rule** conversation, not a permission-set one, and it should surface as a finding
rather than be pre-empted by a blanket `true`.

**`Property_Asset__c` field grants — the exact 8 the reports need**, all `readable=true,
editable=false`:
`Sell_Readiness_Score__c`, `Sell_Readiness_Band__c`, `Readiness_Score__c`, `Property_Type__c`,
`Property_Name__c`, `Status__c`, `Argus_Value__c`, `Argus_Signal__c`.
(The last two also satisfy item 11 for Argus.)

**`Property__c` / `Transaction__c` / `Offering__c`** — see **D-11**. Grant object read plus a named
minimal list, never all fields.

### Item 11 — Argus / CoStar read-only, and the `Disposition_Dashboard_Access` fix

| File | Change |
|---|---|
| `Disposition_Dashboard_Access` | 🔴 `Property_Asset__c.Argus_Value__c` **`editable` `true` → `false`**. This is the one true *downgrade* in the tranche and the exact inverse of story 8's AC today. |
| `DPEG_Disposition_View` / `_Edit` | **New** grants at `editable=false`: `Property_Asset__c.Argus_Value__c`, `Argus_Signal__c`; `Property__c.CoStar_URL__c`, `CoStar_Asking_Rent_PSF__c`, `CoStar_Data_Source__c`, `CoStar_Exit_Cap_Rate__c`, `CoStar_Fetch_Status__c`, `CoStar_Last_Synced_DateTime__c`, `CoStar_Location_Score__c`, `CoStar_Pct_Leased__c`. |

⚠ **Two findings worth reporting rather than silently fixing:**
1. `Disposition_Dashboard_Access` carries **no `objectPermissions` at all** — its 12 field grants are
   inert unless the user gets `Property_Asset__c` object read from another set. After item 10 the
   disposition personas will have it; anyone else holding only this set will not. Say so; do not
   widen it without a decision.
2. The same set also grants `Property_Asset__c.Property_Type__c` and `Sell_Readiness_Score__c` as
   `editable=true`. Neither is Argus/CoStar, so **neither is in item 11's scope** and neither is
   being changed here. Flagged for a future pass, not fixed.

### Item 12 — `Wire__c.Verified_DateTime__c` non-backdatable

**Recommendation: BOTH (D-12), and the VR shape is not the obvious one.**

**(a) Permission set.** `DPEG_Disposition_Edit`: `editable` `true` → **`false`**; `readable` stays
`true`.
✅ **Verified this does not break the service.** `WireService.saveWire:62` performs a **bare
`upsert w;`** — ordinary Apex DML runs in system context and does not enforce FLS, so the stamp still
writes. `WireSelector.selectRequiredById` is `WITH USER_MODE` and **selects the field
deliberately** ("narrowing that selector field set would reintroduce a `System.SObjectException`") —
`readable=true` is retained, so that read is unaffected.
✅ **Verified the UI path is safe.** `lwc/wireVerification` calls `saveWire` **imperatively**; it does
not use `lightning-record-edit-form`. Had it done so, an `editable=false` field in the payload would
be **FLS-checked and dropped silently with a success toast** — a live failure mode in this repo. It
does not apply here, but it is why the check was made.

**(b) Validation rule — `Wire__c`'s first.**

```
AND(
    OR(ISNEW(), ISCHANGED(Verified_DateTime__c)),
    NOT(ISBLANK(Verified_DateTime__c)),
    OR(
        Verified_DateTime__c < NOW() - 0.0007,
        Verified_DateTime__c > NOW() + 0.0007
    )
)
```

**Why each clause, traced against `WireService` line by line:**

| Clause | Reason |
|---|---|
| `OR(ISNEW(), ISCHANGED(...))` | 🔴 `ISCHANGED` is **false on insert**, and `WireService` creates a new `Wire__c` and stamps in the same save — an insert-only backdate would slip straight through a `ISCHANGED`-only rule. `Wire_Complete_Before_Sale_Closes` is the in-repo precedent for this exact pair. It also means the rule **cannot trap an existing wire**: a wire verified last week can still be edited for any other reason. |
| `NOT(ISBLANK(...))` | `WireService:59-60` **clears the field to null** when the verbal flag is turned off. Without this the service's own clear is refused. |
| `< NOW() - tolerance` | The backdate this item exists to stop. |
| `> NOW() + tolerance` | Forward-dating is the same tamper in the other direction. |
| **the tolerance itself** | 🔴 **Load-bearing.** `WireService` writes `Datetime.now()`, and the rule evaluates *after* — so a strict `< NOW()` would refuse **the service's own stamp on every save**. `0.0007` day ≈ 1 minute. **Confirm the window.** |

**Shapes that were considered and rejected, so they are not re-proposed:**
- *"Refuse any re-stamp: `ISCHANGED` + `NOT(ISBLANK(PRIORVALUE(...)))`"* — ❌ refuses the service's
  own clear-to-null, which is a legitimate documented behaviour.
- *"Just remove the FLS grant, no VR"* — ❌ FLS does not stop a data loader, an admin, or a future
  `AccessLevel.USER_MODE` refactor. And a VR **still evaluates under `SYSTEM_MODE`** — that is
  precisely the D-1 argument the disposition redesign already relies on.

✅ **No existing row is frozen** by this rule: the `ISCHANGED` guard means a wire whose
`Verified_DateTime__c` is already in the past saves normally.
⚠ `Wire_Verification_Rollup` reads the field and writes the **parent** — unaffected.

**Risk (10-12 combined):** HIGH — not because any single grant is hard, but because the
replace-semantics hazard, the shared working tree, and the unverified org baseline all converge on
the same three files.

---

### 🔵 Item 13 — source-controlled list views for `Disposition__c` — ADMIN

**🔴 GATE FIRST (D-13): retrieve `Disposition__c` list views from `usman-dpeg` and diff before
writing anything.** No `listViews/` folder in the repo means either the org has none *or* they were
never retrieved — and a source list view whose `fullName` matches a hand-made org one **replaces it
silently**.

**Proposed set (six), modelled on `Lease_Inquiry__c/listViews/` — the closest in-repo precedent:**

| `fullName` | Label | `filterScope` | Filter |
|---|---|---|---|
| `All_Dispositions` | All Dispositions | `Everything` | — |
| `My_Dispositions` | My Dispositions | `Mine` | — |
| `Active_Sales` | Active Sales | `Everything` | `Disposition_Stage__c` **not equal** `Sale Closes` |
| `Awaiting_Approval` | Awaiting Approval | `Everything` | `Approval_Pending__c` equals `true` |
| `On_Market_Sales` | On Market Sales | `Everything` | 🔴 record type — **GATE G-6** |
| `Off_Market_Sales` | Off Market Sales | `Everything` | 🔴 record type — **GATE G-6** |

**Columns** (all six): `NAME`, `Property_Asset__c`, `Disposition_Stage__c`, `Selected_Broker__c`,
`Listing_Date__c`, `Closing_Date__c`, `LAST_UPDATE`.

**Design notes:**
- `filterScope Everything` is safe — both sets carry `viewAllRecords=true` on `Disposition__c`.
- **Omit `<sharedTo>`**, matching the `Lease_Inquiry__c` precedents. A list view with no `sharedTo`
  is visible to everyone who can see the object.
- 🔴 **GATE G-6.** The XML shape for a record-type filter in a `ListView` (`RECORD_TYPE` pseudo-field,
  and whether the `<value>` takes the developer name or the label) is **not exercised anywhere in
  this repo** and cannot be confirmed without MCP. Per the standing rule: **deploy ONE list view as a
  dry-run and read it back before writing the other five.** Never guess a shape — §3.4 of
  `ARCHITECTURE.md` records what that costs.
- ⚠ A `Disposition__c` list view with an `Is_On_Market__c` filter is the **fallback** if G-6 fails —
  that formula checkbox already exists precisely so record type can be tested where a direct test is
  unproven.
- ⚠ Separately, the gap analysis notes `Disposition_Dashboard.tab-meta.xml` hard-codes an 18-char
  Dashboard Id that dies on every org rebuild. **Out of scope here**, named so it is not conflated
  with this item.

**Risk:** LOW-MEDIUM — entirely G-6 and the un-retrieved org state.

---

## 4. Admin vs Developer split

### 🔵 ADMIN / SOLUTION-ARCHITECT work

| Item | Deliverable | Route |
|---|---|---|
| 1 | 2 `NDA__c` fields | `salesforce-admin` |
| 2 | 1 `NDA__c` formula field | `salesforce-admin` |
| 3 | 1 `NDA__c` Date field | `salesforce-admin` |
| 4 | 2 `BOV_Submission__c` Checkboxes | `salesforce-admin` |
| 5 | 1 `Broker_Listing__c` Lookup + filter | `salesforce-admin` |
| 6 | 1 `Broker_Listing__c` formula field (+ additive-retirement descriptions) | `salesforce-admin` |
| 7 | 1 `Disposition__c` Number field | `salesforce-admin` |
| 8 | 1 `Disposition__c` validation rule (or the `required` flip) | `salesforce-admin` |
| 9 | 1 validation rule + 1 custom permission | `salesforce-admin` |
| **10-12** | **3 permission sets, ONE consolidated pass, 4 new objects + ~30 field grants across 2 personas + 1 downgrade** | 🟤 **`salesforce-solution-architect`** — this is an FLS strategy across multiple objects and personas with replace-semantics risk on shared hub files, which is that agent's routing trigger in `CLAUDE.md` |
| 12b | 1 `Wire__c` validation rule | `salesforce-admin` |
| 13 | 6 list views (after G-6) | `salesforce-admin` |

### 🟢 DEVELOPER work

| Item | Deliverable | Route |
|---|---|---|
| 7 | `BovSubmissionSelector` new aggregate method (`SYSTEM_MODE`, justified at the declaration); new `DispositionCounterRollupService`; `DispositionOfferTriggerHandler` + `BovSubmissionTriggerHandler` routing; **`DispositionOfferTrigger` +3 contexts**, **`BovSubmissionTrigger` +1 context**; bulk tests at 251 with a per-chunk **query-and-DML budget assertion** | 🟢 `salesforce-developer` |
| 6 | Repoint `BrokerListingSelector.selectMostRecentByDispositionId`; amend `DispositionStageEntryService`'s comment in place | 🟢 `salesforce-developer` |
| 5 | **Widen `scripts/seed-broker-contacts.apex`'s guard** to cover `Broker_Listing__c.Broker__c`; update its header to name six lookups, not four | 🟢 `salesforce-developer` |
| 7 | Repoint/comment the 4 seed scripts that hand-set `Responses_Received__c`; re-examine `BovControllerTest:74,297` | 🟢 `salesforce-developer` |
| 8 | Repair the **9** `TestDataFactory.createDisposition(null, …)` call sites via a shared lazily-built asset | 🟢 `salesforce-developer` |
| 9 | Grep sweep: does anything write `Disposition__c.RecordTypeId` post-insert? | 🟢 `salesforce-developer` |

**No integration, no Named Credential, no ASB/Plaid/Yardi touchpoint in this tranche** — so
`salesforce-technical-architect` is **not** required.

---

## 5. Deploy order

Metadata dependency order is not negotiable; several steps also carry a gate that must pass first.

| Wave | Contents | Why here |
|---|---|---|
| **0** | **GATES, no writes.** (a) Retrieve + diff the 3 permission sets vs `HEAD` **and vs the org**. (b) Retrieve `Disposition__c` list views. (c) `SELECT COUNT(Id) FROM Disposition__c WHERE Property_Asset__c = null`. (d) Re-measure `Contact` by record type. (e) Confirm `Broker_Listings` relationship name is free on `Contact`. (f) G-4 and G-6 one-item dry-runs. | Every one of these has produced a silent failure on this project before. |
| **1** | **Schema, additive only** — items 1, 2, 3, 4, 5, 6 (new formula), 7 (new Number). No record type or picklist surgery is in this tranche, so the record-type-before-Apex ordering rule does not bite; it still applies to any future value change. | Apex referencing a new field will not compile and a layout referencing a missing field will not deploy until schema lands. |
| **2** | **The consolidated permission-set pass** — items 10, 11, 12(a) **plus every FLS grant for items 1-7**, in ONE deploy across the 3 files. | 🔴 A field with no FLS **aborts the whole DML statement**, it does not degrade. A `PermissionSet` deploy **replaces** the whole collection, so this cannot be split. |
| **3** | **Validation rules** — 9 (+ its custom permission, which must land in the **same or an earlier** deploy or `$Permission` resolves false and nobody can override), 12(b), 8 (if the VR route is chosen). | A VR referencing a field needs the field. |
| **4** | **Apex** — selector → service → handler → trigger, for item 7. Trigger context expansion last within the wave. | The layering order, and the parent-write mode question is settled by then. |
| **5** | **Test-fixture + seed repair** — item 8's 9 call sites, item 5's seed guard, item 7's 4 seed scripts. | Must precede any `required=true`; must follow the schema. |
| **6** | **Item 8's `required=true`** — only if D-6 chooses that route, and only after wave 5 is green. | Otherwise 6 inserting test methods red the suite and every `RunLocalTests` deploy with it. |
| **7** | **List views** — item 13, after G-6 passes. | Independent; safest last. |
| **8** | **Deferred / gated: retirement of `Disposition__c.Days_On_Market__c`.** Not in T1 unless the `Avg_Days_on_Market` report is repointed onto a report type that does not yet exist. | Reports do not block deletion; they break silently. |

**Standing deploy hygiene for every wave:**
- 🔴 **Check per-component `state` in the dry-run output, not just the top-level status.** A
  byte-identical component reports `Unchanged` and **skips validation entirely** — a comment-only
  edit does not count as a change. This exact trap hid a FlexiPage binding defect in Tranche 2.
- 🔴 **`sf sobject describe` is a stale cache** and reports fields absent after a successful deploy.
  Verify via Tooling API `CustomField` with an explicit `TableEnumOrId` — and beware
  `Offers_Received__c` and `Days_On_Market__c` existing on other objects.
- 🔴 **A green deploy is not proof for anything with a rendering or ordering component.** Read the
  list views back in the UI; read the permission sets back per-field.

---

## 6. Per-item risk register

| # | Item | Risk | Dominant hazard |
|---|---|---|---|
| 1 | NDA Principal Approved (+ date) | **LOW** | Duplicate representation vs the existing `Status__c = 'Approved'` value — must be documented now |
| 2 | NDA Approved for Release | **LOW-MED** | The "fully executed" definition (D-1). A wrong definition silently creates a second release condition beside Q6's |
| 3 | NDA Buyer Response Date | **LOW** (field only) | Escalates to MED if the timeline read is pulled in — `USER_MODE` widening on a card that does **not** fail soft |
| 4 | BOV Buyer Ready / Known Performer | **LOW** | All risk is deferred to Tranche 4's formula change (3,900-char compiled cap; the `null` guard is load-bearing) |
| 5 | Broker Listing broker lookup | **MED** | 🔴 `seed-broker-contacts.apex`'s guard now covers 4 of 6 lookups; `relationshipName` collision; lookup stays blank on auto-created listings |
| 6 | Days on Market formula + retire | **HIGH** | 🔴 Formula conversion is delete+create, not an edit; `editable=true` grant is a deploy error; 3 seed scripts break; the report cannot be repointed without a new report type; a third disagreeing DOM definition |
| 7 | Offers/Responses counters | **HIGH** | 🔴 4 new trigger contexts across 2 triggers; a documented refusal of `after undelete`; `SYSTEM_MODE` does not bypass sharing; reparent must recompute BOTH parents; 6 seed/test sites overwritten |
| 8 | Property Asset required | **MED** | 🔴 `required=true` forces `deleteConstraint Restrict`; 9 test call sites pass null |
| 9 | Record type lock VR | **MED** | Needs a new custom permission (a VR is not bypassed by Modify All Data); the stage boundary is a judgement; `TestDataFactory`'s deliberate record-type degradation |
| 10 | 4-object read grants | **HIGH** | 🔴 Replace semantics + a shared working tree + an **unverified org baseline** |
| 11 | Argus/CoStar read-only | **MED** | Framing correction — 10 of 11 changes are a *new grant*, only one is a downgrade; `Disposition_Dashboard_Access` has no object permissions at all |
| 12 | Wire timestamp non-backdatable | **MED** | 🔴 The naive VR shapes each break `WireService`; the tolerance window is load-bearing; this is `Wire__c`'s first VR |
| 13 | Disposition list views | **LOW-MED** | 🔴 Unretrieved org list views would be silently replaced; the record-type filter shape is unproven (G-6) |

---

## 7. Confirmed OUT of Tranche 1

Restated so no implementing agent widens the scope. None of these is designed above.

- Conversion 5 freeze (13/66) — **A1: NO FREEZE.** Live values stand; `Asking_Price__c` stays retired.
- NDA template population (23) — **E2: DEFERRED.** Only the *Approve* half (item 1) is in scope.
- Approval processes, the 2-of-4 approver roster, the approval tracker — **Tranche 3.**
- BOV score re-weighting, the 3-response matrix threshold, broker-history surfaces — **Tranche 4.**
- The Week 2 rung change (A2), detection/reminder jobs, timers — **Tranche 5.**
- Offer comparison columns, closing statement upload, PSA status enforcement, Conversion 6, deep
  links — **Tranche 6.**
- Anything integration- or notification-shaped.
- ⚠ Also explicitly untouched here, though adjacent: **A3's repointing of
  `Property_Asset__c.Sell_Readiness_Band__c` off `Argus_Signal__c`.** It is a confirmed decision but
  it is **not** among the 12 items, and items 10/11 grant that field read-only exactly as it stands
  today. Whoever executes A3 must re-check these grants afterwards.

---

## 8. Prompts for the specialist agents

Only what was requested. No extras.

### 🟤 PROMPT FOR `salesforce-solution-architect` (items 10, 11, 12a — ONE consolidated pass)

```
Execute the ACCESS pass in agent-output/disposition-gap-closure-t1-design.md §"Items 10-12", as a
SINGLE consolidated edit to exactly three files:
  force-app/main/default/permissionsets/DPEG_Disposition_View.permissionset-meta.xml
  force-app/main/default/permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml
  force-app/main/default/permissionsets/Disposition_Dashboard_Access.permissionset-meta.xml

BEFORE editing:
  - Retrieve all three from usman-dpeg and diff against HEAD. A PermissionSet deploy REPLACES the
    file's entire fieldPermissions collection; an org/repo divergence silently revokes live grants.
    Report any divergence and STOP rather than reconciling silently.
  - Confirm no concurrent stream is editing these files (git status already shows
    DPEG_Transaction_* modified by other work).

THEN, additively:
  10. Add objectPermissions (allowRead=true, all else false, viewAllRecords=false) for Property__c,
      Property_Asset__c, Offering__c, Transaction__c to BOTH DPEG_Disposition_View and _Edit.
      Add the 8 Property_Asset__c field grants named in §"Item 10", all editable=false.
      For Property__c / Transaction__c / Offering__c use the field lists confirmed under D-11 —
      do NOT grant all fields.
  11. In Disposition_Dashboard_Access, flip Property_Asset__c.Argus_Value__c editable true -> false.
      Add the 2 Argus + 8 CoStar field grants named in §"Item 11" to both disposition sets, all
      editable=false. Do NOT change Property_Type__c or Sell_Readiness_Score__c — out of scope.
  12a. In DPEG_Disposition_Edit, flip Wire__c.Verified_DateTime__c editable true -> false.
       Keep readable=true (WireSelector.selectRequiredById is WITH USER_MODE and selects it).
  PLUS: add the FLS grants for every new field created in items 1-7 of the same design doc, per each
  item's stated read/edit posture. This must be in the SAME pass — a Metadata-API field arrives with
  no FLS for anyone including System Administrator, and an ungranted field ABORTS the whole DML
  statement rather than degrading.

Record mcp=unavailable / mcp_tools=none after a real attempt, per memory api-context-mcp-not-configured,
and fall back to the PermissionSet skill.

Do NOT deploy. Create/modify the metadata files only.
```

### 🔵 PROMPT FOR `salesforce-admin` (items 1-9, 12b, 13)

```
Create the metadata described in agent-output/disposition-gap-closure-t1-design.md §3, items 1-9,
12b and 13. Do NOT create permission-set edits — items 10-12a are a separate consolidated pass owned
by salesforce-solution-architect.

Follow each item's section exactly, including:
  - Item 2: Approved_For_Release__c is a FORMULA checkbox = ISPICKVAL(Status__c,'Signed'). Not a
    flow-written or trigger-written field. Write the "how a Declined NDA behaves" reasoning into the
    field's XML comment.
  - Item 5: copy the lookupFilter shape BYTE-FOR-BYTE from
    objects/Disposition__c/fields/Broker__c.field-meta.xml — Contact.RecordType.DeveloperName equals
    Broker, active=true, isOptional=false, errorMessage "Only Broker Contacts can be selected here."
    deleteConstraint SetNull. NEVER Is_Broker__c. NEVER Restrict.
  - Item 6: create a NEW formula field (name per D-4) alongside the stored Days_On_Market__c. Do NOT
    attempt to convert the existing field — Salesforce cannot change a field into a Formula.
    Do NOT delete Disposition__c.Days_On_Market__c.
  - Item 9: use the $Permission three-segment form, copying
    objects/Account/validationRules/Record_Type_Is_Immutable.validationRule-meta.xml. Create the
    custom permission Disposition_Record_Type_Override.
  - Item 12b: use the exact traced formula in §"Item 12", including the ISNEW-or-ISCHANGED guard and
    the tolerance window — the naive shapes break WireService.saveWire.
  - Item 13: deploy ONE list view as a dry-run first and read it back (GATE G-6). The record-type
    filter shape is unproven in this repo.

Every long rationale goes in an XML comment INSIDE the root element, never in <description>
(<description> is capped: 255 on ValidationRule/RecordType, 1000 on CustomField) and never above the
root element (that breaks sf at source conversion).

Record mcp=unavailable / mcp_tools=none per metadata type after a real attempt, and fall back to the
per-type skill.

Do NOT deploy. Create the metadata files only.
```

### 🟢 PROMPT FOR `salesforce-developer` (item 7 Apex + the repair tasks)

```
Implement the DEVELOPER half of agent-output/disposition-gap-closure-t1-design.md §"Item 7", plus the
repair tasks listed in §4.

Item 7 — the two Disposition counters:
  - Reuse the EXISTING DispositionOfferSelector.countByDispositionIds. Add one matching aggregate
    method to BovSubmissionSelector, WITH SYSTEM_MODE, justified at its own declaration (automation
    path — USER_MODE inside a trigger throws CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and rolls back the
    user's own save).
  - New DispositionCounterRollupService: zero inline SOQL, accepts Set<Id>, RECOMPUTES (never
    increments), one aggregate query per counted object and ONE Database.update per chunk.
  - Trigger contexts:
      DispositionOfferTrigger: (before insert, before update, after update)
        -> ADD after insert, after delete, after undelete
      BovSubmissionTrigger:    ADD after undelete ONLY
    🔴 On BovSubmissionTrigger's afterUndelete, route ONLY the counter recompute.
    BovAutoSelectionService must NOT be called there — its 2026-08-24 header deliberately refuses
    the undelete context. Retract that header claim IN PLACE (quote, do not delete), per this repo's
    convention.
  - Handle the parent-lookup CHANGING on update: recompute BOTH the old and the new parent.
  - Zero-query fast path when no row in the chunk changed its parent — the same shape
    BovSubmissionBrokerStampService and DispositionOfferBuyerStampService already use.
  - Parent write: Database.update(parents, false, AccessLevel.SYSTEM_MODE), wrapped per D-10's
    resolution. SYSTEM_MODE lifts CRUD/FLS but NEVER sharing.
  - .claude/rules/bulk-test-rule.md applies IN FULL (251+). Assert the PER-CHUNK query and DML budget,
    not just that 251 rows produced 251 counters.

Repair tasks:
  - Item 5: widen scripts/seed-broker-contacts.apex's STEP 2/3 guard to cover
    Broker_Listing__c.Broker__c; update its header to name six dependent lookups, not four.
  - Item 6: repoint BrokerListingSelector.selectMostRecentByDispositionId's field list to the new
    formula field; amend DispositionStageEntryService:1008-1011's comment in place.
  - Item 7: repoint or comment the four seed scripts that hand-set Responses_Received__c
    (seed-disposition.apex:112, seed-disposition-bulk.apex:158,163, seed-disp0002.apex:83,
    create-on-market-disposition.apex:27); re-examine BovControllerTest:74,297.
  - Item 8: repair the nine TestDataFactory.createDisposition(null, ...) call sites
    (DispositionMaterialsStampTest:57,109,172,205,220; DispositionBuyerTimelineTest:154;
    DispositionDomainTest:103,111; RecordStageAdvanceServiceTest:2234) via a shared lazily-built
    Property_Asset__c — one asset for the whole run, never one per fixture.
  - Item 9: grep and report whether anything writes Disposition__c.RecordTypeId AFTER insert.

Every class with SOQL must be a Selector. with sharing everywhere unless separately justified in the
class header. Do NOT deploy.
```

---

## 9. Summary

- **12 of 12 items designed.** Nothing added, nothing expanded.
- **6 premises in the request are incomplete or wrong** in ways that change the design (P-1 … P-6).
  The two that would have produced a broken deploy are **P-1** (a field cannot be converted to a
  formula — it is delete + create) and **P-2** (`DPEG_Disposition_Edit` grants the field
  `editable=true`, which is a deploy error on a formula, and three seed scripts assign it).
- **13 decisions (D-1 … D-13)** need confirmation before build. Each carries a recommendation and its
  evidence.
- **Highest-risk items:** 6 (formula conversion mechanics), 7 (four new trigger contexts against a
  documented refusal, plus the sharing question), 10 (permission-set replace semantics against an
  unverified org baseline).
- **The single most valuable gate before any of this ships:** re-confirm the three permission sets
  against `usman-dpeg`. The gap analysis is a repo analysis by its own admission, and on 2026-08-31 a
  whole documented-as-deployed build was measured absent from that org.
