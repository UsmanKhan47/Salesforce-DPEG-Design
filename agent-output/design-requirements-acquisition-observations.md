# Design Requirements — Acquisition App Observations Fix Pack

**Source spec:** `docs/superpowers/specs/2026-08-14-acquisition-app-observations-design.md` (approved at Gate 1)
**Date:** 2026-08-14
**Status:** Requirements structured. **Two items block Phase 1 and Phase 3 respectively** — see §0.1.

---

## 0. What this document is

The spec's Gate-1 decisions are **settled and are not re-opened here**. This document does four things
the spec explicitly delegated:

1. Splits the work into Admin/declarative vs Developer/programmatic, with routing (§2–§5).
2. Resolves the four open questions O1–O4 with recorded reasoning (§1).
3. Produces the **verified** reference inventory for the two renames (§6).
4. Enumerates deploy order, migration points, org-query verification, and the undeployable
   post-deploy gates (§7, §8).

Plus one thing the spec asked for but could not itself supply: **§9 — collisions with existing
ARCHITECTURE.md invariants that the spec did NOT anticipate.** There are eleven. Three of them
(C1, C3, C5) make a phase as-written unbuildable or self-breaking.

### 0.1 Blocking items — read before scheduling anything

| ID | Blocks | Question |
|---|---|---|
| **O4** | Phase 1 | The extraction-score denominator is a business sign-off, not a design-agent call. §1.4 gives a proposal to sign off; **it must be signed off before Phase 1 D1.** |
| **C5** | Phase 3 / obs 4 | The spec's `Rejected` stamp is not buildable by the mechanism it names, and the record it produces is a dead end. §9 C5/C6 give the two options; **one must be chosen before build.** |
| **M11 (§9 C11)** | Phase 4 / obs 2 | The Acquisition app has **no home page**. There is no `HomePage` FlexiPage anywhere in the repo and no `standard-home` tab in `Acquisition.app`. Observation 2 has no target surface until this is decided. |

---

## 1. Open questions — resolutions

### O1. `Fields_Captured__c` / `Fields_Missing__c` vs §1 rule 9's `_Count__c` suffix

**Decision: rename both to `Fields_Captured_Count__c` and `Fields_Missing_Count__c`.**

The spec framed this as "`Fields_Captured__c` arguably already reads as a count". It does not — it reads
as a **Boolean**, and not by inference but by the repo's own live rule.

`ARCHITECTURE.md` §1 rule 4 states the permitted Boolean forms: *"Prefix `Is_` or `Has_`, **or**
`<Subject>_<PastParticiple>`. No other form is permitted."* Its own examples are `LOI_Signed__c`,
`PSA_Executed__c`, `SLA_Breached__c`. `Fields_Captured__c` is exactly `<Subject>_<PastParticiple>` —
it is not near the Boolean form, it **is** the Boolean form. Rule 9 prohibition 2 ("a field name must
not assert a type the field does not have") is therefore violated positively, not marginally.

`Fields_Missing__c` is weaker but fails the same way: `Missing` reads as a state, and the field would
sit beside a genuine `<Subject>_<PastParticiple>` sibling, so a reader who resolves one as Boolean
resolves the other the same way.

Three supporting facts:

- **The repo has already paid for this exact defect twice.** The §1 repair of 2026-07-17/18 converted
  `Is_Ready__c` (a Number wearing rule 4's Boolean marker) → `Readiness_Score__c`, and
  `Occupied_Flag__c` → `Occupied_Pct__c`. Both cost a **delete-and-recreate**, because in-place
  case/name changes on a live field are a Metadata-API no-op and Apex/FlexiPage references block
  deletion by field-ID.
- **Here it costs nothing.** These fields do not exist yet. Four characters now versus a
  delete-and-recreate later is not a trade-off.
- **`Tasks_Open__c`, `Completion_Pct__c`, `Readiness_Score__c`, `Occupied_Pct__c`** are the in-repo
  precedent set for rule 9's suffixes. `_Count__c` is the member of that set these two fields need.

**Not changed:** `Extraction_Score_Pct__c` stays as the spec named it. It already carries a rule-9
suffix (`_Pct__c`), which is what the rule requires; "Score" inside a descriptive name is not a
competing suffix. Renaming it would be churn against a conformant name.

**Also record (see §9 C10):** `Listing_Status__c` is a *new* name on `Lead`/`Opportunity` but a
**pre-existing, unrelated picklist** on `Broker_Listing__c` with a different value set (`On Track`,
…). Rule 7 permits both. Nothing must ever map between them, and the new field's `<description>`
should say so.

---

### O2. Alert job — scheduled Apex vs scheduled-triggered Flow

**Decision: scheduled Apex — a `Database.Batchable` (`CallForOffersAlertBatch`) plus a `Schedulable`
(`CallForOffersAlertSchedule`), following `DealFolderSweepBatch` / `DealFolderSweepSchedule` exactly.**

The spec asked this be decided *"on the idempotency-marker requirement and the 251-record volume, not
on preference"*. Both criteria point the same way, and a third is decisive.

**(a) The idempotency marker requires persistent state, and the state is not trivial.**
A stateless derivation ("fire when `daysRemaining ∈ {7,3,1,0}`") is idempotent *only* if the job runs
exactly once per day, never misses a day and never re-runs one. A missed day silently skips an
interval **forever** — the alert that never arrives is indistinguishable from the deal not being
urgent. A double-run double-fires, which the spec says is the failure worth avoiding ("the team gets
the same alert every day and stops reading them").

The required marker is therefore **two fields on `Opportunity`**, and both are load-bearing:

| Field | Type | Purpose |
|---|---|---|
| `Offer_Alert_Last_Interval__c` | Number(2,0) | The smallest interval already notified. Fire when `daysRemaining <= interval` **and** `interval < lastFired` (or `lastFired` is null). Monotone ⇒ a missed day catches up on the next run; a double-run is a no-op. |
| `Offer_Alert_Due_Date__c` | Date | Snapshot of the due date the marker was computed against. When it differs from the live `Offer_Due_Date__c`, **reset the interval**. |

The second field is not defensive polish. `CallForOffersStampService` is **last-email-wins on
`Offer_Due_Date__c` on purpose** — ARCHITECTURE records the reason verbatim: *"a call-for-offers
deadline is a fact that changes ('extended to Friday'), so fill-if-blank would freeze the first date
and make an extension invisible."* Without the snapshot, an extension leaves a marker armed against a
date that no longer exists and the re-armed schedule never fires. The alert feature and the stamp
service must agree that the deadline moves.

**(b) The 251-record volume rule cannot be satisfied by a Flow.**
`.claude/rules/bulk-test-rule.md` mandates 251 records for a batch job, and the spec's own §6 adds:
*"Assert on counters captured **inside** the async context, never `Limits.*` after
`Test.stopTest()`."* A scheduled-triggered Flow runs one interview per record and **exposes no
counter an Apex test can read**. The spec's stated testing requirement is literally unsatisfiable by a
Flow — not merely harder.

**(c) The decisive reason: a Flow would be a third derivation of the urgency band.**
Spec §5.1 mandates one shared Apex service so *"the table and the panel cannot disagree about whether
a deal is urgent"* — the `DispositionTractionService` shape, which ARCHITECTURE describes as *"two
consumers, one derivation, on purpose … so they cannot contradict each other."* A Flow that computes
"7/3/1/0 days" in decision elements is a **third** ladder that will drift from the two the spec just
unified. Reaching the Apex `evaluate(Date, Integer)` from a Flow requires an `@InvocableMethod`
wrapper — at which point the Apex exists anyway and the Flow adds a second scheduling surface with no
governor visibility.

Supporting: `.claude/rules/apex-layering-rule.md` requires SOQL in a selector; every recurring job in
this repo is Apex + `Schedulable` (`AttachmentCarrierSweepSchedule`, `RoutingRetrySweepSchedule`,
`DealFolderSweepSchedule`). There is no scheduled-triggered Flow precedent in the acquisitions module.

**Batchable, not Queueable:** the population is "every open Opportunity with a future
`Offer_Due_Date__c`", which is unbounded and must chunk.

**⚠ Instruction for the developer, not a value to copy:** `SCOPE` must be derived from the org's
**per-transaction `Messaging.CustomNotification.send()` ceiling**, MEASURED in `usman-dpeg` before it
is fixed, and the measurement recorded in the class header. Do not carry `DealFolderSweepBatch`'s
`SCOPE = 10` across — that constant is a *callout* budget and has nothing to do with notifications.
This mirrors `SharePointCalloutService.TIMEOUT_MS`, which is derived arithmetic with its derivation
written down, not a round number.

---

### O3. Delete or leave inactive the deactivated LOI and PSA values

**Decision: LEAVE INACTIVE in this pack. Deletion is a separately-scoped, separately-gated follow-up
change and must not ride along.**

Three legs, in order of weight.

**1. Deletion buys nothing the deactivation has not already delivered.** An inactive value is already
unselectable in every UI. The 2026-08-04 picklist sweep established this in the strongest possible
form: all 14 "orphan values" queued for deletion were *already* `isActive=false`, so the deletion was
a **tidy-up, not a control**. The observation asks for a new sequence; deactivation + the row
migration delivers it completely.

**2. The costs are asymmetric and one side is unverifiable.** An inactive value keeps every historical
row, report filter, dashboard grouping and Path reference resolvable. A deleted value **breaks reports
and dashboards silently** — they reference by name and do not block the deletion — and reports and
dashboards are org-side and *not fully represented in this repo*, so no repo-side check can prove the
sweep complete. The spec's own §1 constraint 5 says exactly this.

**3. Every single value on both deactivation lists is a substring-collision or encoding hazard.**
This is the specific reason to refuse, not a general caution:

| Value to deactivate | Hazard if a sweep is string-scoped rather than field-scoped |
|---|---|
| `Prepare/Review` | Literal slash. Encoded `Prepare%2FReview` in some metadata contexts, plain at runtime — the `Dead%2FPass` trap, one field over. `RecordStageAdvanceService`'s own header already warns that comparisons on this field must use `TEXT(...)`, never `ISPICKVAL`. |
| `Completed` | **ACTIVE** on `Underwriting__c.Stage__c`, `Construction_Feasibility_Review__c.Stage__c` and `Development_Feasibility_Review__c.Stage__c` (all three map `Share Opinion ⇒ Completed`). Also one character from `Complete`, which is **ACTIVE** on `Underwriting__c.Status__c`. |
| `Sent` | **ACTIVE** on `NDA__c.Status__c` for **both** record types, where it is a live hop. |
| `Counter` | A strict prefix of `Countered by DPEG` and `Counter Received from Buyer` — **on the same field**, on the disposition record type. |
| `Initial Draft` / `Revised` / `Ready for Execution` | All three remain **ACTIVE and required** on `Disposition_PSA`. Deleting them from the field deletes them from the disposition sequence. This one is not a hazard, it is a hard stop. |

That last row alone settles it for Phase 3's PSA half: the three values being retired from the
*acquisition* record type are the three the *disposition* record type still runs on. They can be
removed from `Acquisition_PSA`'s enumerated set; they can **never** be deleted from the field.

**Recorded as a follow-up with its own preconditions** (do not start it inside this pack):
delete only after (i) an org query proves zero rows hold each value on each *field*, (ii) a
report/dashboard inventory is taken from the **org**, not the repo, and (iii) the sweep is
FIELD-scoped, never string-scoped.

---

### O4. The extraction-score denominator field list

**Decision: ESCALATE. This is not a design-agent call and the spec is right that it must be signed
off.** What follows is the material needed to sign it off, plus five properties the list must have
whichever fields are chosen. **Phase 1 D1 is blocked on this.**

**The strongest argument for the spec's own three-field design surfaces here.** Because
`Fields_Captured_Count__c` and `Fields_Missing_Count__c` are both stored, the **denominator is
recoverable per record** (`captured + missing`). That makes a future change to the list *auditable*
rather than silently re-basing every historical score. This is the reason to keep both counts rather
than the percent alone, and it should be said out loud in the field descriptions — otherwise someone
"simplifies" the schema to the percent and destroys the property.

**Five properties the list must have, regardless of contents:**

1. **A named constant list in Apex, never a describe.** Spec §2.2. A describe denominator changes
   every score's meaning the day someone adds a field.
2. **It must exclude fields the pipeline is FORBIDDEN to write.** Specifically
   `Property__c.Lot_Size__c` — ARCHITECTURE: *"(square feet, OM-entered) is **never written** —
   deriving SF from acres is forbidden."* Counting a field the pipeline may never fill guarantees a
   permanent ceiling below 100% and makes every score wrong by a constant.
3. **It must exclude the classification keys.** `is_acquisition_related`, `confidence`,
   `email_category`, `category_confidence` measure *what kind of email this is*, not *how much was
   extracted*. Folding them in repeats the mistake §2.1 already forbids ("`Parse_Confidence__c` …
   records the model's certainty about `is_acquisition_related`, which is a different question").
4. **It must be scored against the SAME property block that was stamped.** The extraction returns N
   properties; branch (c) stamps `properties[0]` and branch (e) stamps the routed property. Scoring
   the email while the fields describe one property produces a number that explains nothing.
5. **It must survive the degraded paths.** LLM-down, `OUTCOME_NO_ADDRESS` and the call-for-offers gate
   all produce Leads. A null score there is correct; a `0` is a claim.

**Proposal for sign-off** (derived from the deal-screening set `LeadConvertService` already carries;
**the user must confirm, add or strike**):

| Group | Candidate keys |
|---|---|
| Identity | `property_name`, `property_address` |
| Deal process | `guidance_price`, `guidance_cap_rate`, `offer_due_date`, `sale_process`, `listing_broker_name`, `listing_broker_email` |
| Physical | `building_sf`, `noi`, `unit_count`, `occupancy`, `year_built`, `asset_type` |
| New in this pack | `listing_status` |

Denominator = 15 as drawn. **Do not build against this list until it is confirmed.**

---

## 2. Work split and routing — summary

| Phase | Declarative half | Programmatic half |
|---|---|---|
| **1** — Lead intake, Deal Type, extraction score | 🟤 **`salesforce-solution-architect`** | 🟢 `salesforce-developer` |
| **2** — `PSA` → `Under Contract (PSA)` | 🟤 **`salesforce-solution-architect`** | 🟢 `salesforce-developer` |
| **3** — Underwriting / LOI / PSA stage sets | 🟤 **`salesforce-solution-architect`** | 🟢 `salesforce-developer` |
| **4** — Call-for-offers UI + alerts | 🟤 **`salesforce-solution-architect`** (Opportunity_Record_Page only) + 🔵 `salesforce-admin` (notification type, queue verification) | 🟢 `salesforce-developer` |

**Phases 1 and 2 are solution-architect work, plainly.** Neither is "add a field". Phase 1 is a
four-deploy value migration spanning two objects' picklists, four record-type files, a record type,
a business process, two permission sets and a live LLM prompt, with a mass data update between D1 and
D3. Phase 2 is a **standard** picklist value migration across ~20 metadata types and 8 Apex classes
where the value collides by substring with a live, unrelated picklist on another object (§9 C7). Both
match the routing guide's *"multi-object metadata schema"* and *"security model / record type"*
criteria, and neither matches *"add a custom field or object"*.

**No phase routes to `salesforce-technical-architect`.** Nothing here touches ASB, Plaid, Yardi,
Named Credentials, Platform Events, LDV or callout architecture. Phase 1 edits an existing LLM prompt
string inside an existing callout service — additive, no new boundary — which is standard
service-layer work. Phase 4's batch is an ordinary `Batchable` + `Schedulable` on the existing
`DealFolderSweepBatch` pattern.

**`salesforce-unit-testing` and `salesforce-code-review` run for every phase** (all four create or
modify Apex). Documentation and DevOps run per phase, not once at the end — each phase has its own
multi-deploy sequence with migrations in between.

---

## 3. 🔵 / 🟤 ADMIN & DECLARATIVE WORK

Grouped by phase. Everything here is exactly what the spec approved; nothing has been added.

### Phase 1 — declarative

- **`Lead.Listing_Status__c`** — Picklist, **restricted**, values `On Market`, `Off Market`. Blank
  permitted. No default.
- **`Lead.Extraction_Score_Pct__c`** — Number(3,0).
- **`Lead.Fields_Captured_Count__c`** — Number(3,0). *(renamed per O1)*
- **`Lead.Fields_Missing_Count__c`** — Number(3,0). *(renamed per O1)*
- **The same four on `Opportunity`**, identical types.
- **`fieldPermissions` for all eight**, declared IN source. See §5 for which sets and why.
- **Validation rule on `Lead`** blocking entry to `Under Review` when any of `Deal_Type__c`,
  `Listing_Status__c`, `Property_Address__c` is blank. Error message must name the
  `OUTCOME_NO_ADDRESS` case explicitly (spec §2.4) so it reads as the intended chase, not a bug.
- **Deal Type `Commercial` → `Retail`**, four deploys — value on **both** `Deal_Type__c` fields, the
  enumerated value on **four** record-type files (§9 C12), the `Retail` record type, the `Retail`
  business process, two permission-set `recordTypeVisibilities`, two FlexiPage criteria.

### Phase 2 — declarative

- `OpportunityStage` standard value set: add `Under Contract (PSA)` (`forecastCategory` `Forecast`,
  `probability` 85, matching the outgoing `PSA` entry exactly), deactivate `PSA`.
- Both business processes (`Land`, and `Commercial`→`Retail`).
- Four validation rules — `Approved_LOI_Before_PSA`, `Completed_LOI_Before_PSA`,
  `No_Backward_Stage_Movement` (**five occurrences in one file**, four of them inside separate
  `CASE()` blocks — count them), `NDA_Signed_Before_Deal_Progression`.
- `Opportunity_Record_Page` — 2 stage-keyed criteria. `Acquisitions_Deal_Path` pathAssistant.
  `Deal_Tracker_PSA` list view. `Opportunity.Deal_Bucket__c` formula.
- ⚠ **`Opportunity.Advance_to_PSA` quick action** — the API name need not change; its **label**
  should. Renaming the quick action is a separate, larger blast radius (FlexiPage `valueListItems`,
  layouts) and is not required by the observation.

### Phase 3 — declarative

- `Underwriting__c.Stage__c`: add `Rejected`. Underwriting Path: add the step.
  `Underwriting_Record_Page`: a visibility entry for the rework route (**see §9 C5 — the route must
  be designed first**, and §9 C8 for the `booleanFilter` hazard).
- `LOI__c.Stage__c`: add `Submitted`, `Negotiation`, `Signed`; deactivate `Prepare/Review`, `Sent`,
  `Counter`, `Completed`. `Under Review` already exists.
- **Both** LOI record-type files: `Acquisition_LOI` gains the three new values; `Disposition_LOI` must
  **explicitly continue to exclude** them (a record type file that omits a picklist drops all of its
  values from that type).
- Rewrite `LOI__c.Stage__c`'s `<description>` — it currently asserts the two sets are **fully
  disjoint** and that this is what makes stage-keyed rules self-limiting. That becomes false.
- `LOI_Path_Acquisition` pathAssistant. `LOI_Record_Page`: **four acquisition visibility rules gain a
  record-type criterion**, and the file's XML comment (which explains the disjointness) becomes wrong
  and must be rewritten.
- **`LOI__c.Is_Advance_Allowed__c` formula — see §9 C1. Not in the spec. Breaks three ways.**
- `Contract_Review__c.Negotiation_Status__c`: add `Draft`, `Negotiation`, `Signed`. `Acquisition_PSA`
  exposes exactly the four target values; `Disposition_PSA` untouched.
- `Contract_Review_Path_Acquisition` pathAssistant.
- **`Contract_Review_Stage_Sync` flow — see §9 C4. Not in the spec. Must learn `Draft` while KEEPING
  `Initial Draft`.**
- **Rejection-side flow for observation 4** — `<runInMode>SystemModeWithoutSharing</runInMode>` is
  mandatory (spec §4.1, correctly anticipated). **See §9 C6 for the discriminator problem.**

### Phase 4 — declarative

- **`Opportunity_Record_Page`**: place the new LWC **above** the Activity component. Retrieve live,
  edit, deploy, **read the deployed result back**. This page carries 8 custom-permission visibility
  rules and a heavily-ordered region.
- **Notification type: REUSE `Acquisitions_Deal_Update`.** ✅ Verified to exist
  (`notificationtypes/Acquisitions_Deal_Update.notiftype-meta.xml`, desktop + mobile, label
  "Acquisitions - Deal Update"). Its semantics fit. **Do not create a new type.**
- **Home page for observation 2 — BLOCKED, see §9 C11.** There is no home page.

---

## 4. 🟢 DEVELOPMENT WORK

### Phase 1 — Apex

- **Extraction scoring** on the Lead-creation path. Same insert, **no additional DML, no additional
  SOQL**. Denominator is the signed-off constant list from O4. **Fail-soft is mandatory** — any
  failure yields null scores and a note, never a throw (spec §1 constraint 7 / §2.2).
- **`LLMExtractionCalloutService`**: new `listing_status` key in the enriched block, defaulting to
  **blank, never a guess**. Legacy-shape responses parse to blank. Plus the `Retail` repoint at
  Phase 1 D3 (§9 C13).
- **`PropertyExtraction`** / parser: carry the new key.
- **`LeadConvertService`**: carry `Listing_Status__c` + the three score fields to **Opportunity**
  (deal-process facts, not `Property__c`). **Pinned 2 SOQL / 3 DML contract is unchanged** — same
  records, more fields on the same update. Every restricted-picklist write stays **describe-guarded**.
- **`RecordTypeSelector` / `LeadConvertService`** record-type resolution → `Retail`.
- **`OpportunityFunnelController`**, **`recentOpportunities.js`**, **`TestDataFactory`**,
  **`opportunityPipeline.js`** label — see the §6 live list.

### Phase 2 — Apex

`StageAdvanceService` (`NEXT_STAGE` ×2 entries; `ALLOWED_EXPLICIT_TARGETS` — `PSA` is deliberately
**absent** and must stay absent under the new name), `OpportunityReviewService` (`CONTRACT_STAGE`
constant + header prose), `OpportunityReviewTriggerHandler`, `ContractExecutionService`,
`DealFolderService`, `PropertyAssetService`, `TestDataFactory`, plus the `pipelineStageBoard` /
`totalOpportunities` / `recentOpportunities` LWCs.

🔴 **`DealFolderService` and `PropertyAssetService` reason about `PSA ⇒ Closed Won` via
`StageAdvanceService.NEXT_STAGE`.** ARCHITECTURE records that both were placed on the Opportunity
trigger *specifically because* `NEXT_STAGE` maps **both** `PSA ⇒ Closed Won` **and**
`About to Close ⇒ Closed Won`. Missing either half here re-opens the "key on the state, not the route"
defect — invisibly.

### Phase 3 — Apex

- **`RecordStageAdvanceService`** — `LOI_ACQUISITION_NEXT_STAGE` (whole map),
  `LOI_ACQUISITION_EXPLICIT_TARGETS` (`Counter`→`Negotiation`, `Completed`→`Signed`),
  **`CONTRACT_REVIEW_NEXT_STAGE` must be SPLIT into two maps** (§9 C9 — it is currently ONE map shared
  by reference, deliberately, and the header says so), and `UNDERWRITING_NEXT_STAGE` (§9 C5).
- **`c/loiMarkCountered` / `c/loiMarkCompleted`** — hardcoded target constants become `Negotiation`
  and `Signed`. **Changed in the bundle, never computed** — the server validates them against a
  record-type-scoped allow-list and that is the security-relevant half.
- **`OpportunityReviewService`** — the Contract Review insert must **explicitly stamp**
  `Negotiation_Status__c = 'Draft'` (§9 C3). Today it stamps nothing and relies on the field default.
- **`ApprovalAuditService`** — the `Rejected` stamp (§9 C5/C6/C7). Catch must be `Exception`, not
  `DmlException`; the test must **re-read the stamp**, because this class swallows.
- **Regression**: `CounterOfferServiceTest`, `PsaVersionServiceTest` (the `Ball_In_Court__c`
  derivation reads the parent's record type and the PSA value set moves under it).

### Phase 4 — Apex

- **`CallForOffersService`** — the single derivation: due date, days remaining, urgency band, listing
  broker, sale process, deal room. `evaluate(Date, Integer)` **pure** (no SOQL, no DML, no
  `Date.today()` beyond its argument). Both UI surfaces and the alert batch render from it.
- **`OpportunitySelector`** — the CFO read. **N SOQL independent of record count**, pinned at 251.
- **`CallForOffersAlertBatch` + `CallForOffersAlertSchedule`** (per O2), with the two marker fields.
- **Controllers** — thin, `AuraHandledException` at the boundary.
- **Two LWC bundles** — home-page table and record-page panel. `.lv-*` list-view chrome standard,
  SLDS 2 tokens, SLDS linter, Jest + `@sa11y/jest`. **Errors surfaced via toast; no silent `@wire`
  error swallowing** — that was a real defect class found and fixed in the 2026-07-19 audit.

✅ **No new CFO fields are needed for the panel.** Verified present on `Opportunity`:
`Offer_Due_Date__c`, `Sale_Process__c`, `Listing_Broker_Name__c`, `Listing_Broker_Email__c`,
`Deal_Room_Link__c`. The only new fields in Phase 4 are the two alert markers from O2.

---

## 5. Permission sets — the reconciliation rule and where each grant goes

**Every new field in this pack needs an explicit `fieldPermissions` entry declared IN a permission set
that is in source.** A Metadata-API-deployed custom field arrives with **no** field permissions for
**any** profile, System Administrator included, and `profiles/**` is `.forceignore`d so there is no
profile-level fallback and no file-based check can see the gap.

**Grant the new fields where their SIBLING fields already live, not where the feature lives.**
Verified: `Parse_Confidence__c`, `Property_Address__c`, `Deal_Type__c`, `Sale_Process__c` and
`Offer_Due_Date__c` grants are carried by —

| Set | Carries |
|---|---|
| `DPEG_Acquisition_Edit` | the acquisitions persona's editable grants |
| `DPEG_Acquisition_View` | the read-only twin |
| `DPEG_Opportunity_View` | the Transactions-team Opportunity subset |
| `Broker_Protection_Access` | the inbound-pipeline principal's grants |
| `DPEG_Disposition_Edit` / `_View` | disposition-side (Sale_Process/Offer_Due_Date only) |

⚠ **`Broker_Protection_Access` is not optional for the Lead score fields.** The pipeline writes them.
The 2026-08-05/06 incidents are on record: a permission-set deploy **REPLACES** its
`<fieldPermissions>` set, an org-side-only grant was wiped by an unrelated redeploy, and every inbound
email routing to a Lead or Contact then threw `Operation failed due to fields being inaccessible`.
Note this write is on the Lead-**insert** path in **system mode**, so a missing grant does not block
the write — it makes the value **invisible to the persona**, which is the harder failure to spot.

🔴 **RECONCILE ORG → REPO BEFORE EDITING ANY OF THESE FILES.** Not "check once" — the 2026-08-10
cleanup found `DPEG_Admin_Access` carrying six `recordTypeVisibilities` live in `usman-dpeg` and
absent from the repo file **one day after** a clean 2026-08-09 reconciliation had recorded zero
org-only grants in it. A past clean reconciliation is a snapshot, not a guarantee. The same
REPLACE-not-merge hazard applies one layer up to **`PermissionSetGroup` membership**.

Both permission sets carrying `<recordType>Opportunity.Commercial</recordType>` —
`DPEG_Acquisition_Edit` and `DPEG_Admin_Access` — are edited in Phase 1. **Reconcile both first.**

---

## 6. VERIFIED reference inventory for the two renames

The spec warned that the raw `Commercial` grep returns 60+ files and asked for the true list. It
returns **88 files / 196 occurrences**. Below is the classification. Downstream agents get the
classified list, not the grep.

### 6.1 `Commercial` → `Retail`

**88 files. 41 are under `profiles/` and are NOT references** (`.forceignore`d; they never deploy).
That leaves **47 real files**, which split three ways.

#### 🔴 LIVE — behaviour changes if not repointed (edit at D1/D3/D4 per §7)

| # | File | What |
|---|---|---|
| 1 | `objects/Lead/fields/Deal_Type__c.field-meta.xml` | the value definition |
| 2 | `objects/Opportunity/fields/Deal_Type__c.field-meta.xml` | the value definition |
| 3 | `objects/Lead/recordTypes/Acquisition_Broker.recordType-meta.xml` | enumerated `Deal_Type__c` value |
| 4 | `objects/Lead/recordTypes/IR_Investor.recordType-meta.xml` | enumerated `Deal_Type__c` value |
| 5 | `objects/Opportunity/recordTypes/Land.recordType-meta.xml` | enumerated `Deal_Type__c` value |
| 6 | `objects/Opportunity/recordTypes/Commercial.recordType-meta.xml` | **the record type itself** — `fullName`, `businessProcess`, `label`, plus its own enumerated value. **File is renamed.** |
| 7 | `objects/Opportunity/businessProcesses/Commercial.businessProcess-meta.xml` | **the business process. File is renamed.** |
| 8 | `flexipages/Opportunity_Record_Page.flexipage-meta.xml` | **2** live `<rightValue>Commercial</rightValue>` on `{!Record.Deal_Type__c}` (lines 58, 1381) |
| 9 | `permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml` | `<recordType>Opportunity.Commercial</recordType>` |
| 10 | `permissionsets/DPEG_Admin_Access.permissionset-meta.xml` | same |
| 11 | `classes/LeadConvertService.cls` | **line 239** `new Set<String>{'Land','Commercial'}`, **line 266** the resolution comment |
| 12 | `classes/LLMExtractionCalloutService.cls` | **line 719** — the PROMPT: `'deal_type must be one of: Land, Commercial.'` **This instructs the model which value to emit.** |
| 13 | `classes/OpportunityFunnelController.cls` | **line 98** `countByDealType('Commercial')` |
| 14 | `lwc/recentOpportunities/recentOpportunities.js` | **line 20** `Commercial: ['#e8f1fc','#1565c0']` — a live badge-colour map key |
| 15 | `lwc/opportunityPipeline/opportunityPipeline.js` | **line 31** `label: 'Commercial Deals'` — user-facing label |
| 16 | `classes/TestDataFactory.cls` | **lines 604, 649** `Deal_Type__c = 'Commercial'`, **line 691** the record-type error message. **Not a test class — the org-wide factory. Every test asserting `Commercial` depends on it.** |
| 17 | `flexipages/Construction_Feasibility_Review_Record_Page.flexipage-meta.xml` + `pathAssistants/Construction_Feasibility_Path.pathAssistant-meta.xml` | user-facing prose *"Commercial deal forwarded for a construction condition assessment"*. Not a picklist reference, but it becomes wrong on screen. |

#### 🟡 TEST — real references; they fail LOUDLY, not silently

15 files. Repoint at D3 with the live sites, in the same commit:
`LeadConvertServiceTest` (14 deal-type occurrences), `LeadConvertActionServiceTest` (9),
`LeadConvertTriggerHandlerTest` (5), `LeadConvertActionControllerTest` (3),
`OpportunityFunnelControllerTest` (4), `RecordTypeSelectorTest` (5), `OpportunitySelectorTest` (4),
`StageAdvanceServiceTest` (3), `PropertyExtractionTest` (2), `LLMExtractionParserTest` (2),
`BrokerPortalControllerTest` (2), `BrokerPortalServiceTest` (1), `EmailToLeadServiceTest` (1),
`lwc/recentOpportunities/__tests__` (3), `lwc/opportunityPipeline/__tests__` (1),
`lwc/dealSendToConstructionReview/__tests__` (2).

#### ⚪ COMMENT / JAVADOC — nothing breaks, but the prose becomes wrong

Per the standing rule that comments in this repo are load-bearing documentation, these are **still
edits** — the work moves category, it does not disappear:
`RecordTypeSelector.cls` (3, all Javadoc), `LeadConvertService.cls` (lines 8, 49),
`LeadConvertActionService.cls` (12), `OpportunityReviewService.cls` (5),
`RecordStageAdvanceService.cls` (187), `StageAdvanceService.cls` (68), `OpportunitySelector.cls` (125),
`PropertyExtraction.cls` (61), `TestDataFactory.cls` (59, 627, 672, 675),
`lwc/dealSendToDevelopmentReview.js` (19), `lwc/dealSendToConstructionReview.js` (18, 22),
`lwc/dealMoveToAboutToClose.js` (18), `objects/Opportunity/validationRules/No_Backward_Stage_Movement`
(the rank-map comment), and **`objects/LOI__c/recordTypes/{Acquisition,Disposition}_LOI`**, whose
comments cite `objects/Opportunity/recordTypes/Commercial.recordType-meta.xml` **by file path** — a
path that ceases to exist at D4.

#### 🚫 FALSE POSITIVES — verified by opening the line. DO NOT CHANGE.

| File / line | Why it is not a reference |
|---|---|
| `LeadConvertServiceTest.cls` **140, 354** | `'C-2 Commercial'` — a **`Zoning__c`** value. Nothing to do with Deal Type. Changing it breaks the zoning carry-forward assertion. |
| `LeadConvertTriggerHandlerTest.cls` **18** | `l.Company = 'Commercial Partners Inc'` — a company name |
| `LeadConvertServiceTest.cls` **202** | `'Commercial Partners Inc'` — company name (same line as a real deal-type arg; change one, not both) |
| `LeadConvertActionServiceTest.cls` **136** | `'Commercial Small List LLC'` — company name |
| `OpportunityFunnelControllerTest.cls` **108, 119** | `openCommercial` — a local variable |

### 6.2 `PSA` → `Under Contract (PSA)`

A bare `PSA` grep returns 76 files and is unusable — the token is a substring of `PSA_Version__c`,
`PSA_Date__c`, `PSA_Executed__c`, `psaVersionLog`, `PSA_Version_Notify`, `PSA_Ready_Notify` and
`Advance_to_PSA`, none of which are the stage value.

**Use the syntactic form.** Constrained to value positions, the result is **47 files / 99
occurrences**, and it splits into two populations that must not be confused:

#### 🔴 THE DANGEROUS HALF — `Disposition__c.Disposition_Stage__c` has its OWN `PSA` value

**See §9 C7. This is the most important line in this section.** A find/replace on the syntactic form
would silently rename the DISPOSITION stage as well. **12 files / ~25 occurrences must NOT be
touched:**

`objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml`,
`objects/Disposition__c/recordTypes/On_Market` + `Off_Market`,
`objects/Disposition__c/validationRules/All_NDAs_Signed_Before_Progression`,
`objectTranslations/Disposition__c-en_US/Disposition_Stage__c.fieldTranslation-meta.xml`,
`pathAssistants/Disposition_Path_On_Market` + `Disposition_Path_Off_Market`,
`flexipages/Disposition_Record_Page`, `lwc/dispositionSidebar` (+ its `__tests__`),
`classes/DispositionStageEntryService`, `classes/DispositionStageEntryServiceTest` (12 occurrences —
the single largest count in the whole grep, and every one of them is disposition).

#### 🔴 LIVE ACQUISITION SITES — repoint

`standardValueSets/OpportunityStage` (the value: `fullName` + `label`, `forecastCategory` `Forecast`,
`probability` 85); `objects/Opportunity/businessProcesses/{Land,Commercial→Retail}`;
`objects/Opportunity/validationRules/{No_Backward_Stage_Movement` (**5 occurrences — 4 in separate
`CASE()` blocks + 1 comment**), `Approved_LOI_Before_PSA`, `Completed_LOI_Before_PSA`,
`NDA_Signed_Before_Deal_Progression}`; `objects/Opportunity/fields/Deal_Bucket__c`;
`objects/Opportunity/listViews/Deal_Tracker_PSA`; `flexipages/Opportunity_Record_Page` (2 criteria);
`pathAssistants/Acquisitions_Deal_Path`; `classes/{StageAdvanceService, OpportunityReviewService,
OpportunityReviewTriggerHandler, ContractExecutionService, OpportunityFunnelController,
TestDataFactory}`; `lwc/{pipelineStageBoard, totalOpportunities, recentOpportunities}`.
Plus **`DealFolderService`** and **`PropertyAssetService`** (they consume `NEXT_STAGE`, so their
prose and any stage constants must move with it).

#### 🟡 TEST

`StageBackwardMovementGateTest` (6), `StageApprovalGatesTest` (5), `ContractExecutionServiceTest` (4),
`OpportunityReviewServiceTest` (3), `StageAdvanceServiceTest` (3), `OpportunityFunnelControllerTest`
(3), `StageAdvanceControllerTest` (2), `CloseDateGateTest` (2), `ContractReviewTriggerHandlerTest` (2),
`NdaDealProgressionGateTest` (2), `OpportunityDocStatusControllerTest` (1),
`OpportunityApprovalServiceTest` (1), `OpportunityApprovalControllerTest` (1),
`lwc/{totalOpportunities, recentOpportunities}/__tests__`.

#### ⚠ VERIFY BEFORE TOUCHING

`layouts/Contract_Review__c-Contract Review Layout.layout-meta.xml` — the hit is more likely
`PSA_Date__c` or a section label than the Opportunity stage. Open the line.

#### ⚠ Encoding

`Under Contract (PSA)` contains spaces and parentheses but **no `/`**, so **no `%2F` encoding
applies**. Do not "helpfully" encode it. (`Dead/Pass` is `Dead%2FPass` in BusinessProcess/picklist
metadata; that is a different value.)

---

## 7. Deploy order

Legend: **[MIG]** = an org data migration runs between this step and the next.
**[ORG-Q]** = verified by an **org query**, not by a green deploy.

### Phase 1 — Lead intake, Deal Type, extraction score

| Step | Contents | Verified by |
|---|---|---|
| **P1-A** | 8 new fields (4 × Lead, 4 × Opportunity) + `fieldPermissions` in the reconciled permission sets | Deploy green **+ [ORG-Q]** `SELECT Id FROM FieldPermissions WHERE Field IN (...)` — a green field deploy does **not** imply FLS |
| **P1-D1** | Add `Retail` to both `Deal_Type__c` fields, to all **four** record-type files, add the `Retail` record type + `Retail` business process. `Commercial` still present and active. | Deploy green **+ [ORG-Q]** describe shows BOTH values and BOTH record types |
| — | **[MIG] Backfill.** Every `Deal_Type__c = 'Commercial'` row on `Lead` and `Opportunity` → `Retail`. Every Opportunity on the `Commercial` record type → `Retail`. | **[ORG-Q]** `SELECT COUNT() FROM Lead WHERE Deal_Type__c='Commercial'` = 0; same for Opportunity; `SELECT COUNT() FROM Opportunity WHERE RecordType.DeveloperName='Commercial'` = 0 |
| **P1-D2** | Extraction scoring Apex + the `listing_status` extraction key + `LeadConvertService` carry-forward + the Lead validation rule | Deploy green + `RunLocalTests` |
| **P1-D3** | Repoint every 🔴 LIVE and 🟡 TEST site in §6.1 — including the LLM prompt (line 719) and `recentOpportunities.js` line 20 | Repo grep for `Commercial` returns **only** the 🚫 false positives and `profiles/` |
| **P1-D4** | Deactivate `Commercial` on both `Deal_Type__c` fields; remove it from all four record-type files; retire the `Commercial` record type + business process | **[ORG-Q]** zero rows on the old value and the old record type |

### Phase 2 — `PSA` → `Under Contract (PSA)` — **serialised after Phase 1**

| Step | Contents | Verified by |
|---|---|---|
| **P2-D1** | Add `Under Contract (PSA)` to `OpportunityStage` (matching `forecastCategory`/`probability`) and to **both** business processes. `PSA` still active. | Deploy green **+ [ORG-Q]** describe shows both |
| — | **[MIG]** Every `Opportunity.StageName = 'PSA'` → `Under Contract (PSA)`. ⚠ `No_Backward_Stage_Movement` and `NDA_Signed_Before_Deal_Progression` are `ISCHANGED(StageName)`-scoped and **WILL fire on this update** — the migration must run in a context that satisfies them or with the rules temporarily deactivated and re-activated. Decide which, in writing, before running it. | **[ORG-Q]** `SELECT COUNT() FROM Opportunity WHERE StageName='PSA'` = 0 |
| **P2-D2** | Repoint all 🔴 LIVE ACQUISITION sites + 🟡 TEST from §6.2. **Do not touch the 12 disposition files.** | Deploy green + `RunLocalTests` + a diff review that confirms zero disposition files changed |
| **P2-D3** | Deactivate `PSA` on `OpportunityStage`; remove from both business processes | **[ORG-Q]** zero rows |

### Phase 3 — stage sets — **after Phase 2**

🔴 **Sequencing constraint the spec did not state:** `Completed_LOI_Before_PSA` is edited in **both**
Phase 2 (the stage name) and Phase 3 (the LOI value it reads — §9 C2). Phase 3 must land its edit to
that file **after** Phase 2's, or one overwrites the other.

| Step | Contents | Verified by |
|---|---|---|
| **P3-D1** | Add the new values: `Underwriting__c.Stage__c` += `Rejected`; `LOI__c.Stage__c` += `Submitted`, `Negotiation`, `Signed`; `Contract_Review__c.Negotiation_Status__c` += `Draft`, `Negotiation`, `Signed`. Old values still active. Record-type files updated (`Acquisition_LOI`, `Acquisition_PSA` gain; `Disposition_*` explicitly unchanged). | Deploy green **+ [ORG-Q]** describe per field |
| — | **[MIG] Three migrations.** Open **acquisition** LOIs: `Prepare/Review→Under Review`, `Sent→Submitted`, `Counter→Negotiation`, `Completed→Signed`. Open **acquisition** Contract Reviews: `Initial Draft→Draft`, `Revised→Negotiation`, `Ready for Execution→Signed`. ⚠ **Both must be scoped by RecordTypeId**, not by value — the disposition rows must not move. ⚠ The Contract Review update fires `Contract_Review_Stage_Sync` (before-save), so C4's fix must already be deployed. | **[ORG-Q]** zero acquisition-record-type rows on any retired value, per field |
| **P3-D2** | Apex + declarative repoints: `RecordStageAdvanceService` (LOI map, LOI explicit targets, **Contract Review map SPLIT**, Underwriting map), `c/loiMarkCountered`/`c/loiMarkCompleted` constants, `OpportunityReviewService` explicit `Negotiation_Status__c` stamp, `Is_Advance_Allowed__c` formula, `Contract_Review_Stage_Sync`, `Completed_LOI_Before_PSA`, LOI FlexiPage record-type criteria, three pathAssistants, the rejection-side flow + `ApprovalAuditService` | Deploy green + `RunLocalTests` + **render probe** (§8 G6) |
| **P3-D3** | Deactivate `Prepare/Review`, `Sent`, `Counter`, `Completed` on `LOI__c.Stage__c`. **Nothing is deactivated on `Negotiation_Status__c`** (the three "retired" values remain active for `Disposition_PSA` — O3). | **[ORG-Q]** zero rows |

### Phase 4 — parallel with 1–3, once the CFO field set is settled

| Step | Contents | Verified by |
|---|---|---|
| **P4-A** | 2 alert marker fields + `fieldPermissions` | Deploy green **+ [ORG-Q]** FLS |
| **P4-B** | `CallForOffersService`, `OpportunitySelector` method, controllers, batch + schedulable | Deploy green + `RunLocalTests` |
| **P4-C** | 2 LWC bundles + Jest | Local Jest green (Jest never deploys) + SLDS linter |
| **P4-D** | `Opportunity_Record_Page` edit | Deploy green **+ retrieve the page back and diff** — a FlexiPage deploy can roll back with a design-time error that reports as success |
| **P4-E** | Home page surface — **decision required first (§9 C11)** | — |

---

## 8. Post-deploy gates — NOT deployable metadata, each fails SILENTLY

Every item here is org state. No deploy performs it, no test detects its absence, and every one of
them looks exactly like a working feature when missed.

| # | Gate | If missed |
|---|---|---|
| **G1** | **Schedule `CallForOffersAlertSchedule`.** Record the cron expression **and the owning user**. | Zero alerts, no error, a feature that looks shipped. |
| **G2** | **Verify the `Acquisition` queue's MEMBERSHIP** is the right alerting population. Queue membership is not deployable. | Alerts fire into an empty or wrong population. ⚠ **Second, separate fact (§9 C10):** the queue's `queueSobject` list is **`Lead` and `Property__c` — not `Opportunity`.** It can still receive a notification, but it cannot own the deals it is being alerted about. Confirm this is intended. |
| **G3** | **Assign the permission sets** carrying the new `fieldPermissions`. `PermissionSetAssignment` is not deployable. | System-mode writes land; the persona sees blanks. No test can fail — a `System.runAs` FLS test on a system-mode write cannot fail. |
| **G4** | **Reconcile `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `DPEG_Opportunity_View`, `Broker_Protection_Access`, `DPEG_Admin_Access` ORG → REPO before editing.** Also reconcile any `PermissionSetGroup` whose membership changes. | A deploy silently revokes an org-side-only grant (2026-08-05 and 2026-08-06 incidents) or a group member. |
| **G5** | **Record-type visibility + the profile DEFAULT for `Retail`.** `PermissionSet.recordTypeVisibilities` has no `default` element — only a Profile can name a default, and `profiles/**` is force-ignored. | New Opportunities keep defaulting to the retired type, or users get a record-type chooser they did not have. |
| **G6** | **Render probe, both directions, as a real non-admin persona** for every changed FlexiPage visibility rule — holder sees it, **non-holder does NOT**. The non-holder half is the one that falsifies. | A rule can deploy, survive a retrieve, and be **ignored by the renderer** — measured on `NDA__c.Is_Decline_Allowed__c`. §9 C8 makes this acute for `Underwriting_Record_Page`. |
| **G7** | **Verify `settings/LeadConfig` → `shouldLeadConvertRequireValidation` in Setup**, not in the repo file. `settings/**` is force-ignored, so the repo copy never deploys and has twice been measured to contradict the org. | The new Lead validation rule's behaviour at conversion is the opposite of what was designed. It fails **open**. |
| **G8** | **Re-point any report or dashboard filtering `Deal_Type__c = 'Commercial'` or `StageName = 'PSA'`.** Org-side; not fully represented in the repo. | Reports and dashboards break **silently** — they reference by name and do not block the change. |

---

## 9. Collisions with existing ARCHITECTURE.md invariants the spec did NOT anticipate

The spec correctly anticipated two: the **LOI disjointness break** (§4.2) and the
**approval-runs-as-approver / `runInMode`** trap (§4.1). Eleven more were found. **C1, C3 and C5 make
a phase as-written unbuildable or self-breaking.**

### 🔴 C1 — `LOI__c.Is_Advance_Allowed__c` is a formula naming four LOI stage values by string, and it deliberately carries NO record-type test

The spec repairs the disjointness break in **FlexiPage visibility rules only**. The invariant is also
consumed by a **formula field**, whose own header records that it omits a record-type test *precisely
because the two value sets are disjoint*. Its formula reads:

```
TEXT(Stage__c) <> "Completed",   TEXT(Stage__c) <> "Executed",
TEXT(Stage__c) <> "Sent",        TEXT(Stage__c) <> "Prepare/Review"  (unless approved)
```

Observation 5 breaks it **three ways**:

1. **Terminal moves `Completed` → `Signed`.** The formula returns TRUE at `Signed`, so **Advance Stage
   renders on a finished acquisition LOI and then refuses the click.** This is the third occurrence of
   one defect: D20/C1 (`NE 'Signed'` not excluding `Declined`) and D22 (`<> "Completed"` not excluding
   `Executed`) are both recorded in this same field's XML comment.
2. **`Under Review` becomes SHARED.** With no record-type test, `TEXT(Stage__c) <> "Under Review"`
   would now also fire on a **disposition** LOI at `Under Review`, hiding its Advance button unless
   `LOI_Status__c = 'Approved'` — a condition the sell-side path has no way to satisfy.
3. **`Sent` → `Submitted`** changes what the branch-point exclusion means; under a linear
   `Submitted → Negotiation → Signed` there may no longer be a branch to exclude at all.

**Required:** rewrite the formula **and** its header, and decide explicitly whether it now needs a
`RecordTypeId` test. Add it to the Phase 3 declarative list.

### 🔴 C2 — `Completed_LOI_Before_PSA` reads the LOI child's stage value; observation 5 makes it block every deal

Verified: `TEXT(Primary_LOI__r.Stage__c) <> 'Completed'`. After the migration the acquisition terminal
is `Signed`, so **no LOI is ever "Completed"** and the rule blocks every deal from entering
`Under Contract (PSA)`. The spec lists this file under Phase **2** (the stage name) and not under
Phase 3's LOI value list. **Two phases edit one file** — see the sequencing constraint in §7.

### 🔴 C3 — `OpportunityReviewService` does not stamp `Negotiation_Status__c`; observation 7 makes every auto-created acquisition PSA invalid at birth

Verified at `OpportunityReviewService` lines 258–273: the Contract Review insert sets **only**
`Opportunity__c` and `Stage__c = 'PSA Drafting'`. `Negotiation_Status__c` comes from the **field-level
default**, which is `Initial Draft`. Observation 7 removes `Initial Draft` from `Acquisition_PSA`.

**Apex DML does not enforce record-type picklist restriction** (ARCHITECTURE states this repeatedly),
so the insert **commits silently** on a value that is not on its own record type. The Path renders
blank, and `RecordStageAdvanceService`'s acquisition map has no entry for it — the record is unusable
from creation, with nothing erroring.

**Contrast the LOI block in the same class (line 351), which DOES stamp `Stage__c = 'Draft'`
explicitly** — and whose comment says *"the right seed stage is this method's responsibility, not the
platform's"*. That is the fix: stamp `Negotiation_Status__c = 'Draft'` explicitly, describe-guarded.
Do not solve it by moving the field-level default — `Disposition_PSA` needs `Initial Draft`.

### 🔴 C4 — `Contract_Review_Stage_Sync` is a before-save flow with a DEFAULT branch, is not record-type-scoped, and does not know `Draft`

Verified. Its decision `Map_Status` has rules for `Initial Draft` → `PSA Drafting` and `Executed` →
`Contract Execution`, and a **default connector** sending everything else to `Stage__c = 'Review'`.

Observation 7's `Draft` therefore falls to the default: **a brand-new acquisition PSA immediately
shows coarse `Stage__c = 'Review'` instead of `PSA Drafting`.** It deploys green and nothing errors.
`Stage__c` is a derived field — writing it directly commits and is silently discarded — so the only
fix is in the flow.

The flow serves **both** record types with no criterion, so it must learn `Draft` while **keeping**
`Initial Draft`. This is the "un-criteria'd flow on a shared child leaks cross-module" pattern.

### 🔴 C5 — a `Rejected` Underwriting record is a DEAD END; the spec's "rework and resubmit" is unbuildable as written

Verified across three artefacts:

- `RecordStageAdvanceService.UNDERWRITING_NEXT_STAGE` = `{Requested→In Progress, Approved→Completed}`.
  No entry from `Rejected` ⇒ Advance Stage yields "no next step available".
- `Underwriting__c` has **no explicit-target allow-list at all** ⇒ `advanceTo` cannot reach anything.
- `Underwriting_Record_Page`: **Advance Stage** shows only at `Requested` **or** `Approved`;
  **Submit for Approval** shows only at `In Progress`.

So a record stamped `Rejected` can be advanced by no route and resubmitted by no route. The spec's
*"the Opportunity keeps its current behaviour of returning to the `Underwriting` stage, so the analyst
can rework and resubmit"* is satisfied on the Opportunity but **not on the child**, which is where the
new value lives.

**Two options — one must be chosen before build:**
- **(a)** Add `Rejected → In Progress` to `UNDERWRITING_NEXT_STAGE` and a `Rejected` criterion to the
  Advance Stage visibility rule. Cheapest. ⚠ Makes `Rejected` a forward hop, which the spec's own
  §4.1 explicitly forbids: *"`Rejected` must not become reachable from `RecordStageAdvanceService`'s
  forward sequence."* It is the *exit* that is wanted, not the entry — but `NEXT_STAGE` expresses both
  with one map, so this needs the user's ruling.
- **(b)** Give `Underwriting__c` its first explicit-target allow-list (`{In Progress}`, gated
  `DEAL_DRIVER`) and a `c/underwritingMarkRework` bundle with a hardcoded constant, mirroring
  `c/ndaMarkDeclined`. Honours §4.1 exactly. Costs one bundle + one quick action + one allow-list.

**Recommend (b)** — it is the shape the repo already uses for an off-ramp's return, and the hardcoded
constant is the security-relevant half.

### 🔴 C6 — the approval's final-rejection action CANNOT stamp the child, and the obvious discriminator is ambiguous

The spec says *"`Opportunity.Underwriting_Approval`'s final rejection action stamps the child
`Underwriting__c.Stage__c = 'Rejected'`"*. Verified:

```
<finalRejectionActions><action><name>UW_Reopen_For_Revision</name><type>FieldUpdate</type></action></finalRejectionActions>
```

It is a **single workflow FieldUpdate**, and it writes `Opportunity.Underwriting_Complete__c = false`.
A workflow field update **cannot write a child record**, so this mechanism cannot do what the spec
describes. It must be built the way the **approval** side already is: an after-save Flow calling
`ApprovalAuditService`, which already resolves the child through `Primary_Underwriting__c` and already
reads `ProcessInstanceStep`.

**And the discriminator is the hard part.** A flow keyed on "the Opportunity is at `Underwriting`"
also fires for `Opportunity_Initiate_Underwriting` — a **before-save** flow that sets
`StageName = 'Underwriting'` **from any stage**. That flow would stamp `Rejected` on an Underwriting
record that was merely (re)initiated and never rejected. The reliable discriminator is
`ProcessInstanceStep.StepStatus = 'Rejected'`, which is exactly what `ApprovalAuditService` already
queries — which is a second reason to put the logic there rather than in Flow decision elements.

**Also worth stating so nobody builds it:** the spec's *"the Opportunity returns to the `Underwriting`
stage"* is **already true and needs no work.** The approval's `entryCriteria` is
`StageName equals Underwriting` and `UW_Reopen_For_Revision` does not touch `StageName` — the deal
never leaves. Building a stage rewind would be new behaviour and would meet
`No_Backward_Stage_Movement`.

### 🔴 C7 — `Disposition__c.Disposition_Stage__c` has its own `PSA` value; a Phase 2 find/replace corrupts the disposition module silently

The single largest `PSA` count in the whole repo — 12 occurrences in
`DispositionStageEntryServiceTest` — is **disposition**, not Opportunity. `Disposition_Stage__c`'s
`PSA` stage is what `DispositionStageEntryService`'s third block keys on to create the sell-side
`Contract_Review__c`.

A blind rename would break the two disposition Paths, `dispositionSidebar`,
`All_NDAs_Signed_Before_Progression`, the field translation, both disposition record types, and the
sell-side PSA auto-create — **with a green deploy and green Apex tests, because the rename would be
consistent across code and metadata while being semantically wrong.** §6.2 lists the 12 files to
exclude. This is the same interleaved-corruption shape recorded for the 2026-08-12 flag migration,
where 18 acquisition and 6 disposition rules were interleaved **within three of seven files**.

### ⚠ C8 — `Underwriting_Record_Page` uses a parenthesised-OR `booleanFilter`, a construct MEASURED not to be honoured by the renderer

Verified: `<booleanFilter>1 AND (2 OR 3)</booleanFilter>`. The natural way to add C5's rework route is
`1 AND (2 OR 3 OR 4)`. `NDA__c.Is_Decline_Allowed__c`'s comment records a measurement that a
parenthesised OR **deployed, survived a retrieve, and was ignored by the renderer — the button stayed
visible.** No Apex test, no Jest test and no file check can see this.

**Required:** a render probe in both directions (G6). If the construct is not honoured, the remedy is
the in-repo one — a **formula field** as an explicit discriminator, exactly as
`Is_Decline_Allowed__c` and `Is_Advance_Allowed__c` are.

### ⚠ C9 — observation 7 forces `CONTRACT_REVIEW_NEXT_STAGE` to be SPLIT, and kills a documented fallback argument

`RecordStageAdvanceService`'s header states that `Acquisition_PSA` and `Disposition_PSA` point at
**ONE map object, shared by reference**, deliberately, *"the opposite of the `NDA__c` / `LOI__c`
treatment"*, and that *"copying it would invite the two to drift apart"*. Observation 7 makes them
genuinely differ, so the map must be split — and **that header prose becomes wrong** and must be
rewritten, not just the code.

**The consequence that is easy to miss:** `OpportunityReviewService`'s class header currently argues
that a Master-record-type Contract Review is *"NOT functionally dead"* because *"both PSA record types
share ONE `Negotiation_Status__c` sequence, so `RecordStageAdvanceService`'s `defaultTypeKey` routes it
to a map that genuinely fits."* **That argument dies with the split.** After Phase 3 a Master-type
Contract Review routes to whichever map `defaultTypeKey` names and will be wrong for half of them.
`defaultTypeKey` must be re-chosen deliberately and the header re-argued.

### ⚠ C10 — the `Acquisition` queue does not support `Opportunity`

`queues/Acquisition.queue-meta.xml` declares `queueSobject` for **`Lead`** and **`Property__c`** only.
A queue can still be a custom-notification recipient, so observation 3 works — but the queue cannot
own the Opportunities it is being alerted about, and it was built for lead routing. The spec asked
that membership be confirmed; this is a **second, separate** fact about the same queue. Confirm the
alerting population is intended to be the lead-routing population. Gate G2.

### ⚠ C11 — the Acquisition app has NO home page, so observation 2 has no target

Verified two ways: there is **no FlexiPage of type `HomePage` anywhere in `force-app`**, and
`Acquisition.app-meta.xml`'s tab list is `Lead_Funnel`, `Broker_Hub`, `standard-Lead`,
`standard-Opportunity`, `standard-report`, `Acquisition_Dashboard` — **no `standard-home`**.

Observation 2 says "Acquisition app home page". Three options, none free:
- **(a)** Create a `HomePage` FlexiPage + add `standard-home` to `Acquisition.app`. Cleanest match to
  the wording; edits the app file, which changes every user's default landing surface.
- **(b)** Place the table on the existing **`Lead_Funnel`** tab. No app-file edit. But that surface is
  lead-oriented and the component is Opportunity-oriented.
- **(c)** Place it on **`Broker_Hub`**.

**This is a user decision, not a design-agent one** — it changes what every acquisitions user sees on
login. Recommend (a) if "home page" was meant literally, (b) otherwise.

### ⚠ C12 — the `Deal_Type__c` value is enumerated on FOUR record-type files, not two

`Lead/recordTypes/Acquisition_Broker`, `Lead/recordTypes/IR_Investor`,
`Opportunity/recordTypes/Land`, `Opportunity/recordTypes/Commercial`. A record type file that omits a
picklist **silently drops all of that picklist's values from that type**, so `Retail` must be added to
all four at D1 and `Commercial` removed from all four at D4. The spec named only the Opportunity side.

### ⚠ C13 — the LLM prompt is a live reference, not documentation

`LLMExtractionCalloutService.cls:719` — `'deal_type must be one of: Land, Commercial.'` — instructs
the model which value to emit. It is behaviour, not prose. It belongs in the D3 repoint wave.

The pipeline is protected in the interim: `PropertyExtraction.dealType` is describe-validated against
the live picklist (the `LeadConvertService.assetTypePicklistValues()` precedent), so between D1 and D4
both values validate. **After D4, an un-repointed prompt instructs the model to emit a deleted value**
and the guard drops it **silently** — no exception, no log. That is the same silent-drop shape as the
`Asset_Type__c` divergence already recorded.

---

## 10. PROMPTS FOR SPECIALIST AGENTS

> ⚠ **Do not dispatch Phase 1 until O4 is signed off. Do not dispatch Phase 3 until C5 is decided. Do
> not dispatch Phase 4's home-page item until C11 is decided.**

### 🟤 PROMPT — `salesforce-solution-architect` (Phase 1, declarative)

```
Read ARCHITECTURE.md, .claude/rules/salesforce-global-rule.md, and
agent-output/design-requirements-acquisition-observations.md §3 (Phase 1), §5, §6.1, §7, §8, §9.

Build the Phase 1 declarative half of the Acquisition Observations pack:

1. Four new fields on Lead AND four on Opportunity (identical types):
   - Listing_Status__c   Picklist, RESTRICTED, values: On Market, Off Market. No default. Blank allowed.
   - Extraction_Score_Pct__c   Number(3,0)
   - Fields_Captured_Count__c  Number(3,0)
   - Fields_Missing_Count__c   Number(3,0)
   The _Count__c suffix is REQUIRED, not stylistic: §1 rule 4 reserves the
   <Subject>_<PastParticiple> shape for Booleans, so Fields_Captured__c asserts a type the
   field does not have. Reasoning is recorded in §1 (O1) of the requirements doc.
   Property_Address__c already exists on both objects — do NOT create it.
   Parse_Confidence__c is retained unchanged and must NOT be conflated with the new score.

2. fieldPermissions for all eight, declared IN source, in the permission sets named in §5:
   DPEG_Acquisition_Edit, DPEG_Acquisition_View, DPEG_Opportunity_View, Broker_Protection_Access.
   RECONCILE EACH FILE ORG -> REPO BEFORE EDITING IT. A PermissionSet deploy REPLACES its
   fieldPermissions set. See §5 for the two 2026-08 incidents this prevents.

3. Validation rule on Lead blocking entry to Under Review when any of Deal_Type__c,
   Listing_Status__c or Property_Address__c is blank. The error message MUST name the
   addressless-lead case (routing-tree branch (c) / OUTCOME_NO_ADDRESS) so it reads as the
   intended chase rather than a bug. The rule must NOT be able to fire on the inbound
   pipeline's own Lead insert — assert that, do not assume it.

4. Deal Type Commercial -> Retail, as FOUR deploys. Do not collapse them.
   Use the CLASSIFIED inventory in §6.1 — it separates 41 force-ignored profile files and 5
   verified false positives ('C-2 Commercial' is a Zoning value; three are company names; one
   is a local variable) from the real sites. Do not re-run the raw grep.
   NOTE §9 C12: the value is enumerated on FOUR record-type files, not two.
   Add the Retail record type + Retail business process; retire Commercial's at D4.
   Both permission sets carrying <recordType>Opportunity.Commercial</recordType> are edited.

Deploy sequence, migration points and org-query verification: §7. Post-deploy gates: §8.
Do NOT deploy — produce metadata files only.
Do NOT add validation rules, permission sets, page layouts or fields beyond the list above.
```

### 🟢 PROMPT — `salesforce-developer` (Phase 1, Apex)

```
Read ARCHITECTURE.md, .claude/rules/apex-layering-rule.md, .claude/rules/bulk-test-rule.md, and
agent-output/design-requirements-acquisition-observations.md §4 (Phase 1), §1 (O4), §6.1, §9 C13.

1. Extraction-completeness scoring on the Lead-creation path.
   - Written in the SAME insert that already creates the Lead. NO additional DML, NO additional SOQL.
   - Denominator is the SIGNED-OFF named constant list (see §1 O4 — confirm it is signed off
     before writing; do not infer it). Never a describe.
   - FAIL-SOFT IS MANDATORY. Any failure yields null scores plus a note, never a thrown
     exception. The inbound email pipeline must never be made to throw. Precedent:
     InboundEmailFieldUtil.
   - Score the SAME property block that was stamped (properties[0] on branch (c), the routed
     property on branch (e)), not the email.
   - captured + missing must equal the denominator, so the denominator is recoverable per record.

2. LLMExtractionCalloutService: add a `listing_status` key to the enriched extraction block.
   Defaults to BLANK, never a guess. A legacy-shape response carrying no key parses to blank,
   so a prompt rollback degrades to manual entry rather than stranding the feature.
   Carry the key through PropertyExtraction and the parser.

3. LeadConvertService: carry Listing_Status__c and the three score fields to the OPPORTUNITY
   (deal-process facts, not Property__c). The pinned 2 SOQL / 3 DML contract is UNCHANGED —
   same records, more fields on the same update. Every restricted-picklist write stays
   describe-guarded.

4. Commercial -> Retail repoints at D3. Use the LIVE list in §6.1. Specifically:
   - LeadConvertService line 239 (record-type Set) and its comments
   - RecordTypeSelector (Javadoc only — verify before editing)
   - LLMExtractionCalloutService LINE 719: the PROMPT string
     'deal_type must be one of: Land, Commercial.' — this is LIVE behaviour, see §9 C13
   - OpportunityFunnelController line 98
   - lwc/recentOpportunities/recentOpportunities.js line 20 (a live badge-colour map key —
     the ONLY LWC code hit; the other five LWC hits are Javadoc)
   - lwc/opportunityPipeline/opportunityPipeline.js line 31 (user-facing label)
   - TestDataFactory lines 604, 649, 691 — this is the ORG-WIDE FACTORY, not a test class
   DO NOT change the five verified false positives listed in §6.1.

Tests: 90%+ on every touched class. Assert governor counters captured INSIDE the async context,
never Limits.* after Test.stopTest() — stopTest restores pre-test counters and makes the
obvious assertion silently vacuous.
Do NOT deploy. Do NOT add error handling, test scenarios or fields beyond the above.
```

### 🟤 PROMPT — `salesforce-solution-architect` (Phase 2, declarative)

```
Read ARCHITECTURE.md and agent-output/design-requirements-acquisition-observations.md
§3 (Phase 2), §6.2, §7 (Phase 2), §9 C7.

Migrate Opportunity.StageName 'PSA' -> 'Under Contract (PSA)' in four deploys.

🔴 READ §9 C7 FIRST. Disposition__c.Disposition_Stage__c HAS ITS OWN 'PSA' VALUE. Twelve files
listed in §6.2 must NOT be touched — a find/replace would rename the disposition stage too,
breaking two Paths, dispositionSidebar, All_NDAs_Signed_Before_Progression and the sell-side
Contract Review auto-create, WITH A GREEN DEPLOY AND GREEN TESTS.

Declarative sites (classified list in §6.2):
 - standardValueSets/OpportunityStage — add the new value with forecastCategory Forecast and
   probability 85, matching the outgoing PSA entry exactly; deactivate PSA at the last step
 - both business processes (Land, and Commercial->Retail if Phase 1 has landed)
 - four validation rules. No_Backward_Stage_Movement has FIVE occurrences in one file — four
   inside separate CASE() blocks plus one comment. Count them.
 - Opportunity_Record_Page (2 stage-keyed criteria), Acquisitions_Deal_Path pathAssistant,
   Deal_Tracker_PSA list view, Opportunity.Deal_Bucket__c formula
 - Opportunity.Advance_to_PSA quick action: change the LABEL only, not the API name

'Under Contract (PSA)' has no '/', so NO %2F encoding applies. Do not encode it.

The migration between D1 and D2 fires two ISCHANGED(StageName) validation rules. Decide IN
WRITING whether it runs in a satisfying context or with those rules temporarily deactivated,
before running it. Verification is by ORG QUERY, not by a green deploy — see §7.
Do NOT deploy. Do NOT expand scope.
```

### 🟢 PROMPT — `salesforce-developer` (Phase 2, Apex)

```
Read agent-output/design-requirements-acquisition-observations.md §4 (Phase 2), §6.2, §9 C7.

Repoint 'PSA' -> 'Under Contract (PSA)' in Apex and LWC. Use the classified list in §6.2.

🔴 DO NOT TOUCH the twelve DISPOSITION files listed in §6.2 — Disposition__c.Disposition_Stage__c
has its own 'PSA' value. DispositionStageEntryServiceTest's 12 occurrences are ALL disposition
and are the largest single count in the grep. A consistent-but-wrong rename deploys green.

Sites: StageAdvanceService (NEXT_STAGE x2 entries; ALLOWED_EXPLICIT_TARGETS — PSA is
deliberately ABSENT and must STAY absent under the new name), OpportunityReviewService
(CONTRACT_STAGE constant + header prose), OpportunityReviewTriggerHandler,
ContractExecutionService, DealFolderService, PropertyAssetService, OpportunityFunnelController,
TestDataFactory, lwc/{pipelineStageBoard, totalOpportunities, recentOpportunities}, plus the
14 test classes and 2 Jest suites listed in §6.2.

⚠ DealFolderService and PropertyAssetService reason about 'PSA => Closed Won' via NEXT_STAGE.
ARCHITECTURE records that both live on the Opportunity trigger PRECISELY because NEXT_STAGE maps
BOTH 'PSA => Closed Won' AND 'About to Close => Closed Won'. Missing either half re-opens a
route-vs-state defect that is invisible at runtime.

Include a diff review confirming zero disposition files changed.
Do NOT deploy. Do NOT expand scope.
```

### 🟤 PROMPT — `salesforce-solution-architect` (Phase 3, declarative)

```
Read ARCHITECTURE.md and agent-output/design-requirements-acquisition-observations.md
§3 (Phase 3), §7 (Phase 3), §8 G6, §9 C1/C2/C4/C5/C6/C8/C9.

⚠ Phase 3 must land AFTER Phase 2, and its edit to Completed_LOI_Before_PSA must land AFTER
Phase 2's edit to the same file (§7).
⚠ Do not start until the user has chosen option (a) or (b) in §9 C5.

1. Underwriting__c.Stage__c += 'Rejected'; add the Path step; add the visibility entry for the
   chosen rework route. READ §9 C5 — a Rejected record is currently a DEAD END reachable by no
   advance and no resubmit. READ §9 C8 — this page uses a parenthesised-OR booleanFilter, a
   construct MEASURED to deploy, retrieve and be IGNORED by the renderer. A render probe in
   BOTH directions (G6) is required; if it is not honoured, use a formula-field discriminator,
   the in-repo remedy.

2. LOI__c.Stage__c += Submitted, Negotiation, Signed; deactivate Prepare/Review, Sent, Counter,
   Completed. Under Review already exists.
   - BOTH record-type files: Acquisition_LOI gains the three; Disposition_LOI must EXPLICITLY
     continue to exclude them (an omitted picklist drops all its values from that type).
   - Rewrite the field <description> — it currently asserts the two sets are FULLY DISJOINT and
     that this is what makes stage-keyed rules self-limiting. That becomes false.
   - LOI_Record_Page: four acquisition visibility rules gain a record-type criterion; the file's
     XML comment explaining the disjointness becomes wrong and must be rewritten too.
   - LOI_Path_Acquisition pathAssistant.
   - 🔴 §9 C1 — NOT IN THE SPEC: LOI__c.Is_Advance_Allowed__c is a FORMULA naming Completed,
     Executed, Sent and Prepare/Review by string, and it deliberately carries NO record-type
     test BECAUSE the sets are disjoint. It breaks three ways. Rewrite the formula AND its
     header, and decide explicitly whether it now needs a RecordTypeId test.
   - 🔴 §9 C2 — NOT IN THE SPEC as an LOI site: Completed_LOI_Before_PSA reads
     TEXT(Primary_LOI__r.Stage__c) <> 'Completed'. Unrepointed, it blocks EVERY deal from
     entering Under Contract (PSA).

3. Contract_Review__c.Negotiation_Status__c += Draft, Negotiation, Signed. Acquisition_PSA
   exposes exactly the four target values; Disposition_PSA UNTOUCHED. Deactivate NOTHING on this
   field — Initial Draft / Revised / Ready for Execution remain ACTIVE for Disposition_PSA (O3).
   Contract_Review_Path_Acquisition pathAssistant.
   - 🔴 §9 C4 — NOT IN THE SPEC: Contract_Review_Stage_Sync is a before-save flow with a DEFAULT
     branch and NO record-type criterion. 'Draft' falls to the default, so a new acquisition PSA
     shows coarse Stage__c = 'Review' instead of 'PSA Drafting'. It must learn 'Draft' while
     KEEPING 'Initial Draft' for disposition.

4. Rejection-side flow for the Underwriting Rejected stamp. It MUST declare
   <runInMode>SystemModeWithoutSharing</runInMode> — an approval-invoked flow runs as the
   APPROVER, who is deliberately read-only on Opportunity, and a TypeException is not a
   DmlException. READ §9 C6: the approval's finalRejectionActions is a single workflow
   FieldUpdate writing Underwriting_Complete__c, and a field update CANNOT write a child record.
   The discriminator must be one that Opportunity_Initiate_Underwriting (a before-save flow
   setting StageName='Underwriting' from ANY stage) does not also satisfy.

Migrations between D1 and D2 must be scoped BY RecordTypeId, not by value. Verification is by
ORG QUERY. See §7.
Do NOT deploy. Do NOT expand scope.
```

### 🟢 PROMPT — `salesforce-developer` (Phase 3, Apex)

```
Read agent-output/design-requirements-acquisition-observations.md §4 (Phase 3), §9 C3/C5/C6/C9.

1. RecordStageAdvanceService:
   - LOI_ACQUISITION_NEXT_STAGE: Draft -> Under Review -> Submitted -> Negotiation -> Signed
   - LOI_ACQUISITION_EXPLICIT_TARGETS: Counter->Negotiation, Completed->Signed
   - 🔴 §9 C9: CONTRACT_REVIEW_NEXT_STAGE is currently ONE MAP SHARED BY REFERENCE by both PSA
     record types, deliberately, and the class header says so. It must be SPLIT. Rewrite that
     header prose — do not leave it asserting a shared map.
   - Also re-choose defaultTypeKey for Contract_Review__c deliberately: OpportunityReviewService's
     header argues a Master-type row is safe BECAUSE the two types share one sequence. That
     argument dies with the split; re-argue it in the header.
   - UNDERWRITING_NEXT_STAGE / a new UNDERWRITING_EXPLICIT_TARGETS per the §9 C5 option chosen.

2. c/loiMarkCountered and c/loiMarkCompleted: hardcoded target constants become 'Negotiation'
   and 'Signed'. CHANGED IN THE BUNDLE, NEVER COMPUTED — the server validates them against a
   record-type-scoped allow-list and that is the security-relevant half.

3. 🔴 §9 C3 — NOT IN THE SPEC: OpportunityReviewService's Contract Review insert (lines ~258-273)
   sets only Opportunity__c and Stage__c, and takes Negotiation_Status__c from the FIELD DEFAULT
   ('Initial Draft'). Once Acquisition_PSA drops that value, every auto-created acquisition
   Contract Review is born on a value not on its own record type — Apex DML does NOT enforce
   record-type picklist restriction, so it commits SILENTLY, the Path is blank and the stage map
   has no entry. Stamp Negotiation_Status__c = 'Draft' EXPLICITLY, describe-guarded, exactly as
   the LOI block in the same class stamps Stage__c = 'Draft'. Do NOT solve it by moving the
   field-level default — Disposition_PSA needs 'Initial Draft'.

4. ApprovalAuditService: the Underwriting 'Rejected' stamp (§9 C6). Catch Exception, NOT
   DmlException. This class SWALLOWS its failures, so the test MUST RE-READ the stamp — a green
   ApprovalAuditServiceTest is not evidence the write landed.

5. Regression: re-run CounterOfferServiceTest and PsaVersionServiceTest. They are ONE DESIGN
   APPLIED TO TWO OBJECTS and both derive Ball_In_Court__c from the parent's record type; the
   PSA value set moves under them.
   Also re-run StageAdvanceServiceTest, RecordStageAdvanceServiceTest,
   OpportunityReviewServiceTest, ContractExecutionServiceTest, and the LOI/PSA stage-gate tests.

Do NOT deploy. Do NOT expand scope.
```

### 🟢 PROMPT — `salesforce-developer` (Phase 4, Apex + LWC)

```
Read ARCHITECTURE.md §5, .claude/rules/bulk-test-rule.md, .claude/rules/apex-layering-rule.md, and
agent-output/design-requirements-acquisition-observations.md §4 (Phase 4), §1 (O2), §8 G1/G2.

1. Two new Opportunity fields (the alert idempotency marker, per O2):
   Offer_Alert_Last_Interval__c  Number(2,0)
   Offer_Alert_Due_Date__c       Date  (the due date the marker was computed against)
   Both need fieldPermissions declared IN a permission set in source (§5).
   The second field is load-bearing, not polish: CallForOffersStampService is last-email-wins on
   Offer_Due_Date__c ON PURPOSE, so an extension must RE-ARM the alerts. Without the snapshot a
   marker stays armed against a date that no longer exists and the alert never fires.

   NO other new fields are needed. Offer_Due_Date__c, Sale_Process__c, Listing_Broker_Name__c,
   Listing_Broker_Email__c and Deal_Room_Link__c ALREADY EXIST on Opportunity — verified.

2. CallForOffersService — the SINGLE derivation of call-for-offers state. Both UI surfaces AND
   the alert batch render from it, so they cannot disagree about whether a deal is urgent. This
   is the DispositionTractionService / EmailThreadAnchorService shape.
   evaluate(Date dueDate, Integer today-offset) must be PURE: no SOQL, no DML, no Date.today()
   beyond its argument.

3. OpportunitySelector: the CFO read. N SOQL INDEPENDENT OF RECORD COUNT, pinned by a
   251-record test.

4. CallForOffersAlertBatch (Database.Batchable) + CallForOffersAlertSchedule (Schedulable),
   following DealFolderSweepBatch / DealFolderSweepSchedule. Scheduled Apex, NOT a
   scheduled-triggered Flow — reasoning in §1 O2; the deciding factor is that a Flow would be a
   THIRD urgency ladder and exposes no governor counter an Apex test can read.
   Notifications at 7 / 3 / 1 days before the due date and ON the day, to the existing
   `Acquisition` queue, using the EXISTING Acquisitions_Deal_Update notification type.
   ⚠ SCOPE must be DERIVED from the org's per-transaction Messaging.CustomNotification.send()
   ceiling, MEASURED in usman-dpeg before it is fixed, and the measurement recorded in the class
   header. Do NOT copy DealFolderSweepBatch's SCOPE = 10 — that is a CALLOUT budget.

5. Two LWC bundles: the home-page table (received date, property name, due date, days remaining;
   property name links to the Opportunity) and the record-page panel (due date, days remaining
   with a colour-coded urgency badge, sale process, listing broker, deal room link).
   - Shared .lv-* list-view chrome standard (icon + title + count, sortable-style headers, blue
     record links, View All).
   - SLDS 2 design tokens; run the SLDS linter.
   - Errors surfaced via toast. NO silent @wire error swallowing — that was a real defect class
     found and fixed in the 2026-07-19 audit.
   - Jest suites for both, plus @sa11y/jest accessibility matchers. apiVersion 67.0.

Tests: 90%+ on every touched class. 251-record bulk tests for the alert batch and the CFO
derivation. Assert governor counters captured INSIDE the async context, never Limits.* after
Test.stopTest().
Do NOT deploy. Do NOT expand scope.
```

### 🔵 PROMPT — `salesforce-admin` (Phase 4, declarative — small)

```
Read agent-output/design-requirements-acquisition-observations.md §3 (Phase 4), §8 G1/G2, §9 C10.

1. Notification type: REUSE the existing Acquisitions_Deal_Update
   (notificationtypes/Acquisitions_Deal_Update.notiftype-meta.xml — desktop + mobile, label
   "Acquisitions - Deal Update"). Its semantics fit. DO NOT create a new type.

2. Verify — do not change without instruction — the `Acquisition` queue:
   - its MEMBERSHIP is the intended alerting population (queue membership is NOT deployable
     metadata; this is an in-org check)
   - §9 C10: its queueSobject list is Lead and Property__c, NOT Opportunity. It can still receive
     a custom notification, but it cannot own the deals it is alerted about. Confirm that is
     intended and record the answer.

Report findings. Create no metadata unless the verification says a change is needed.
```

### 🟤 PROMPT — `salesforce-solution-architect` (Phase 4, `Opportunity_Record_Page`)

```
Read agent-output/design-requirements-acquisition-observations.md §3 (Phase 4), §7 (P4-D), §8 G6.

Place the new single-deal call-for-offers LWC on Opportunity_Record_Page, positioned ABOVE the
Activity component.

⚠ THIS IS THE HIGHEST-RISK DECLARATIVE EDIT IN THE PACK. That page carries 8 custom-permission
visibility rules and a heavily-ordered region. Retrieve the LIVE page first, edit, deploy, and
READ THE DEPLOYED RESULT BACK — a FlexiPage deploy can roll back with a design-time error that
REPORTS AS SUCCESS. A green deploy is not evidence.

Do NOT enable Dynamic Actions on this page — doing so silently discards the inherited layout
action list.
Add no components other than the one named. Do NOT deploy without the readback.
```

---

## 11. Testing (carried from spec §6, plus what §9 adds)

| Area | Requirement |
|---|---|
| Apex | 90%+ on every team-owned class touched. 251-record bulk tests for the scoring path, the alert batch and the CFO derivation service. |
| Governor budgets | Assert on counters captured **inside** the async context, never `Limits.*` after `Test.stopTest()`. |
| LWC | Jest for both new bundles + `@sa11y/jest`, matching the existing 82-bundle net. |
| Migrations | Verified by **org query**, not a green deploy. |
| Regression | `StageAdvanceServiceTest`, `RecordStageAdvanceServiceTest`, `OpportunityReviewServiceTest`, `ContractExecutionServiceTest`, `LeadConvertServiceTest`, `CounterOfferServiceTest`, `PsaVersionServiceTest`, LOI/PSA stage-gate tests. |
| **Added by §9** | `ApprovalAuditService`'s `Rejected` test must **re-read the stamp** (C6 — the class swallows). A test must pin that `OpportunityReviewService` stamps `Negotiation_Status__c` explicitly (C3 — the falsifier for anyone who "simplifies" it back to the default). A test must pin that `DispositionStageEntryService` still seeds `Initial Draft` after the C9 map split. |
| **Not testable by any automated means** | G6 render probes (both directions, real non-admin persona); G1/G2/G3 org state; G8 report/dashboard repoints. These are UAT items and must be listed as such. |
