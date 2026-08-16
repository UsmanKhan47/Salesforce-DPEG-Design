# Acquisition App — Observations Fix Pack (design)

**Date:** 2026-08-14
**Status:** Approved at Gate 1. Amended 2026-08-14 after design-agent review — see §0.0.
**Scope:** 7 observations raised against the Acquisition app, **now 6** (observation 4 withdrawn)
**Related:** `ARCHITECTURE.md` §1 (naming), §2 (Apex layering, stage services), §5 (LWC guard/confirm)

---

## 0.0 Amendments after design-agent review (2026-08-14)

The design agent's requirements
(`agent-output/design-requirements-acquisition-observations.md`) found eleven
collisions with existing invariants that this spec did not anticipate, and
escalated three blocking decisions. All three are now settled:

| Item | Decision | Consequence for this spec |
|---|---|---|
| **Observation 4 — Underwriting `Rejected`** | 🔴 **WITHDRAWN.** Not built. | **§4.1 is void.** `Underwriting__c.Stage__c` keeps its current four values. No approval wiring, no Path change, no rejection-side flow. |
| **O4 — score denominator** | **Deal-process fields only: 9 keys.** `property_name`, `property_address`, `guidance_price`, `guidance_cap_rate`, `offer_due_date`, `sale_process`, `listing_broker_name`, `listing_broker_email`, `listing_status`. The six physical-property keys (`building_sf`, `noi`, `unit_count`, `occupancy`, `year_built`, `asset_type`) are **excluded**. | §2.2's denominator is fixed at **9**. Phase 1 unblocked. |
| **C11 — no home page** | **Lead Funnel tab**, not a new home page. | §5.2 retargets. **`Acquisition.app-meta.xml` is NOT edited** and no user's landing surface changes. |

**Withdrawing observation 4 also retires three of the eleven collisions** — C5
(a `Rejected` record is a dead end reachable by no advance and no resubmit), C6
(the approval's `finalRejectionActions` is a workflow `FieldUpdate`, which
cannot write a child record at all) and C8 (`Underwriting_Record_Page`'s
parenthesised-OR `booleanFilter`, a construct measured to deploy, survive a
retrieve and then be ignored by the renderer). None of that work is needed.

**Eight collisions remain live and are now owned by the requirements doc**, not
by this spec: C1 (`Is_Advance_Allowed__c` formula), C2
(`Completed_LOI_Before_PSA` blocks every deal), C3 (`OpportunityReviewService`
never stamps `Negotiation_Status__c`), C4 (`Contract_Review_Stage_Sync`'s
default branch), C7 (`Disposition__c` has its own `PSA` value — 12 files that
must not be touched), C9 (`CONTRACT_REVIEW_NEXT_STAGE` must be split), C10 (the
`Acquisition` queue supports `Lead` and `Property__c`, not `Opportunity`), C12
(the Deal Type value is enumerated on **four** record-type files, not two) and
C13 (the LLM prompt string is a live reference).

O1 and O2 resolved as recommended: `Fields_Captured_Count__c` /
`Fields_Missing_Count__c` (rule 4 reserves `<Subject>_<PastParticiple>` for
Booleans), and scheduled Apex over Flow. O3: retired picklist values are left
**inactive, not deleted** — three of them remain active and required on
`Disposition_PSA`.

---

## 0. Summary of decisions taken at Gate 1

| # | Observation | Decision |
|---|---|---|
| 1 | Lead Under Review validation; Commercial→Retail; on/off market; property address; parse score | Full rename incl. API values. New `Listing_Status__c`. Score = percent + captured/missing counts. VR requires Deal Type + Listing Status + Property Address. |
| 2 | Call for offers LWC on Acquisition home page | Matched Opportunities only |
| 3 | Call for offers LWC on Opportunity record page, above Activity + due-date alerts | Single-deal call-for-offers panel; custom notification to the existing `Acquisition` queue, scheduled daily |
| 4 | Underwriting `Rejected` stage | Approval rejection stamps it; deal returns to `Underwriting` |
| 5 | LOI stage sequence | Additive — new values added, old values deactivated (plus a data migration, see §4.2) |
| 6 | Opportunity `PSA` → `Under Contract (PSA)` | Full rename + migrate |
| 7 | PSA stages Draft → Negotiation → Signed → Executed | Rework `Negotiation_Status__c`, **acquisition record type only** |

Two items were explicitly raised as costs and accepted: phases 1 and 2 each need
3–4 deploys with a data migration between them, and the LOI change needs a row
migration despite being additive.

---

## 1. Non-negotiable constraints carried in from the existing codebase

These are not new rules; they are existing invariants this work must not break.

1. **Picklist removal sweep rule** (`.claude/rules/`, plus two prior incidents):
   grep the repo **and** query the org before removing any picklist value.
   Order is always sweep → remap → restrict.
2. **Field/value rename pattern is additive**: add → backfill → repoint →
   retire, across separate deploys. An in-place rename blanks the column.
3. **Metadata-API-deployed custom fields arrive with NO field permissions for
   any profile**, System Administrator included. Every new field below needs an
   explicit `fieldPermissions` entry in a permission set that is in source.
4. **A `PermissionSet` deploy REPLACES its `fieldPermissions` set.** Reconcile
   org → repo before editing any existing permission set.
5. **Reports, dashboards and pathAssistants reference fields and picklist values
   by name and do not block a deletion** — they break silently.
6. **`profiles/**` is `.forceignore`d.** A grep hit inside `profiles/` is not a
   real reference and a profile-level FLS gap is invisible to any file check.
7. **The inbound email pipeline must never be made to throw.** Anything added to
   the Lead-creation path (§2.2) is fail-soft or it does not ship.

---

## 2. Phase 1 — Lead intake, Deal Type, extraction score

### 2.1 New fields

| Object | Field | Type | Notes |
|---|---|---|---|
| `Lead` | `Listing_Status__c` | Picklist, restricted: `On Market`, `Off Market` | §1 rule 7: a state field. Blank is permitted until Under Review. |
| `Lead` | `Extraction_Score_Pct__c` | Number(3,0) | §1 rule 9 `_Pct__c` — the name must not read Boolean/categorical. |
| `Lead` | `Fields_Captured__c` | Number(3,0) | §1 rule 9 `_Count__c` semantics; named `Captured` for legibility, see open question O1. |
| `Lead` | `Fields_Missing__c` | Number(3,0) | ditto |
| `Opportunity` | same four | same | Carried on conversion. |

`Property_Address__c` already exists on both objects — **no new field.**
`Parse_Confidence__c` is retained unchanged: it records the model's certainty
about `is_acquisition_related`, which is a different question from how complete
the extraction was. Do not conflate them.

### 2.2 Extraction score computation

Computed in Apex on the Lead-creation path, written in the **same insert** that
already creates the Lead — no additional DML, no additional SOQL.

- The denominator is a **named, explicit constant list** of extraction keys, not
  a describe over all fields. A describe-based denominator would silently change
  meaning every time a field is added.
- `Extraction_Score_Pct__c = round(captured / denominator * 100)`.
- **Fail-soft is mandatory.** A defect in scoring must not cost a broker email.
  The computation is wrapped so that any failure yields null scores and a note,
  never a thrown exception. Reference precedent: `InboundEmailFieldUtil` clips
  every externally sourced value for exactly this reason.

### 2.3 `Listing_Status__c` extraction

A new key is added to the enriched extraction block. It defaults to **blank, not
a guess** — a wrong On/Off Market is worse than an empty one, because the
analyst has no signal to correct it. Legacy-shape responses carrying no key
parse to blank, so a prompt rollback degrades to manual entry rather than
stranding the feature.

### 2.4 Validation rule

On `Lead`, blocking entry to `Under Review` when any of `Deal_Type__c`,
`Listing_Status__c`, `Property_Address__c` is blank.

⚠ **Interaction to verify, not assume:** branch (c) of the routing tree
deliberately holds `Property_Address__c` null for leads whose property could not
be addressed (`OUTCOME_NO_ADDRESS`). Those leads are legitimate and are
*supposed* to be chased by a human. This VR is what forces that chase, which is
the intent — but the error message must say so, or it reads as a bug.

### 2.5 Carry-forward on conversion

`LeadConvertService` extends its existing split. `Listing_Status__c` is a
**deal-process fact** → Opportunity (not `Property__c`). The three score fields
likewise. Its pinned **2 SOQL / 3 DML** contract is unchanged — same records,
more fields on the same update. Every restricted-picklist write stays
**describe-guarded**, per the existing rule in that class.

### 2.6 Deal Type: `Commercial` → `Retail`

Four deploys. **Do not collapse them.**

| Step | Action | Verified by |
|---|---|---|
| D1 | Add `Retail` to `Deal_Type__c` on `Lead`, `Opportunity`, `Contract_Review__c`. Add `Retail` record type + `Retail` business process on `Opportunity`. | Deploy green + org describe shows both values |
| D2 | Backfill: every `Commercial` row → `Retail`; every Opportunity on the `Commercial` record type → `Retail` | Org **query**, not a green deploy |
| D3 | Repoint: `LeadConvertService` record-type resolution, `RecordTypeSelector`, flexipages, page-layout assignments, list views, reports, dashboards, `TestDataFactory` | Repo grep returns zero live references (excluding `profiles/`) |
| D4 | Deactivate then delete `Commercial`; retire the `Commercial` record type + business process | Org query returns zero rows on the old value |

⚠ The `Commercial` grep returns 60+ files, but a large share are `profiles/`
(force-ignored) and test classes. The design agent must produce the **true**
reference list before D3, separating live references from noise.

⚠ **Record type DeveloperName vs Label.** Apex resolves record types by
DeveloperName. If the DeveloperName is changed, every resolution site changes
with it; if only the Label is changed, the code keeps saying `Commercial`
forever. This spec takes the **DeveloperName change** — that is what "full
rename" was approved as — and D3 is where it is paid for.

---

## 3. Phase 2 — Opportunity stage `PSA` → `Under Contract (PSA)`

`Opportunity.StageName` is a standard picklist whose label and value are the
same thing, so this is a real value change on live records. Same four-step
shape.

Known reference sites to repoint at D3 (the design agent verifies and completes
this list — it is a starting point, not an inventory):

- `StageAdvanceService.NEXT_STAGE` — maps `LOI ⇒ PSA` and `PSA ⇒ Closed Won`
- `StageAdvanceService.ALLOWED_EXPLICIT_TARGETS` — `PSA` is deliberately absent;
  it must stay absent under the new name
- `OpportunityReviewService` — the PSA stage-entry block that creates
  `Contract_Review__c`
- `OpportunityReviewTriggerHandler`, `DealFolderService`,
  `PropertyAssetService` — all three reason about `PSA ⇒ Closed Won`
- Validation rules `Approved_LOI_Before_PSA`, `Completed_LOI_Before_PSA`,
  `No_Backward_Stage_Movement`, `NDA_Signed_Before_Deal_Progression`
- Both business processes (`Land`, `Commercial`→`Retail`)
- List view `Deal_Tracker_PSA`; `Deal_Bucket__c`; `Opportunity_Record_Page`
  stage-keyed visibility rules; the Opportunity pathAssistants
- Reports and dashboards (org-side; not fully represented in the repo)

⚠ `Dead/Pass` is encoded `Dead%2FPass` in BusinessProcess/picklist metadata but
is the plain string at runtime. `Under Contract (PSA)` contains parentheses and
spaces but no `/`, so no encoding applies — do not "helpfully" encode it.

---

## 4. Phase 3 — Stage sets

### 4.1 Underwriting `Rejected` (observation 4)

- Add `Rejected` to `Underwriting__c.Stage__c` (currently Requested, In
  Progress, Approved, Completed) and to the Underwriting Path.
- `Opportunity.Underwriting_Approval`'s **final rejection** action stamps the
  child `Underwriting__c.Stage__c = 'Rejected'`, routed through the existing
  `ApprovalAuditService` path — which already resolves the child through
  `Primary_Underwriting__c`.
- The Opportunity keeps its current behaviour of returning to the `Underwriting`
  stage, so the analyst can rework and resubmit.

🔴 **The approval-flow trap applies here and is already documented:** a flow
invoked by an approval runs as **the approver**, who is deliberately read-only
on Opportunity. Any flow added or edited for this must declare
`<runInMode>SystemModeWithoutSharing</runInMode>`, and the catch must be
`Exception`, not `DmlException` — a `TypeException` is not a `DmlException` and
will escape and roll back the whole approval. This exact defect was paid for on
2026-08-05; see `ApprovalAuditService`.

🔴 **`Rejected` must not become reachable from `RecordStageAdvanceService`'s
forward sequence.** It is an off-ramp written by the approval, not a hop. If it
is exposed at all it belongs in a record-type-scoped explicit-target allow-list,
never in `NEXT_STAGE`.

### 4.2 LOI stages (observation 5)

Target acquisition sequence: `Draft → Under Review → Submitted → Negotiation → Signed`.

- **Add** `Under Review`(already present, see below), `Submitted`,
  `Negotiation`, `Signed`. **Deactivate** `Prepare/Review`, `Sent`, `Counter`,
  `Completed`.
- **Migrate open acquisition LOIs**: `Prepare/Review → Under Review`,
  `Sent → Submitted`, `Counter → Negotiation`, `Completed → Signed`. Without
  this, an LOI holding a deactivated value renders **blank on the Path** — which
  is why "additive" does not mean "no migration".

🔴 **The disjointness invariant breaks and must be repaired in the same change.**
`LOI__c.Stage__c`'s own description states that the acquisition and disposition
value sets are *fully disjoint*, and that this is what lets every stage-keyed
FlexiPage rule work **without** a record-type criterion. `Under Review` already
exists on the disposition set. After this change the sets overlap, so:

- every stage-keyed LOI FlexiPage visibility rule gains a **record-type
  criterion**;
- the field description is rewritten to say the sets now overlap and that the
  field alone no longer identifies the record type.

Also repoint: `RecordStageAdvanceService`'s acquisition LOI sequence and
`LOI_EXPLICIT_TARGETS`; the `LOI_Path_Acquisition` pathAssistant; the
`c/loiMarkCountered` and `c/loiMarkCompleted` bundles, whose hardcoded target
constants become `Negotiation` and `Signed`. Those constants are the
security-relevant part — the server validates them against a record-type-scoped
allow-list — so they are changed in the bundle, never computed.

### 4.3 PSA stages (observation 7)

Target: `Draft → Negotiation → Signed → Executed`, on `Negotiation_Status__c`,
**acquisition record type only**.

- Add `Draft`, `Negotiation`, `Signed` to `Negotiation_Status__c`. `Executed`
  already exists and is shared.
- `Acquisition_PSA` exposes exactly the four target values; `Disposition_PSA` is
  untouched and keeps its current set.
- Migrate open acquisition Contract Reviews: `Initial Draft → Draft`,
  `Revised → Negotiation`, `Ready for Execution → Signed`, `Executed` unchanged.
- Update `RecordStageAdvanceService`'s **per-record-type** map for
  `Contract_Review__c`.
- **Verify, do not assume:** the `Contract_Review_Stage_Sync` before-save flow
  recomputes the coarse `Stage__c` from `Negotiation_Status__c`, and
  `Executed` drives `ContractExecutionService`'s transaction handoff. Both must
  still fire on the new values. `Stage__c` is a derived field — writing it
  directly commits and is silently discarded.

⚠ `CounterOfferService` and `PsaVersionService` derive `Ball_In_Court__c` from
the parent's record type. They are one design applied to two objects; this
change touches the PSA side's value set, so re-run both test classes.

---

## 5. Phase 4 — Call for offers UI and alerts

### 5.1 Shared derivation

One Apex service is the single place that derives call-for-offers state for a
set of Opportunities: offer due date, days remaining, urgency band, listing
broker, sale process. **Both** UI surfaces render from it, so the table and the
panel cannot disagree about whether a deal is urgent. This is the
`DispositionTractionService` / `EmailThreadAnchorService` shape.

The service is **pure with respect to the clock** where it can be — the band is
a function of `(dueDate, today)` passed in, so it is testable without a frozen
clock hack.

SOQL lives in `OpportunitySelector`. The evaluation is **N SOQL independent of
record count** and pinned by a 251-record test.

### 5.2 Home-page LWC (observation 2)

Acquisition app home page. Table of matched Opportunities with an offer due
date: **received date, property name, due date, days remaining**. Property name
links to the Opportunity.

- Follows the existing shared `.lv-*` list-view chrome standard used by every
  other list LWC in this repo (icon + title + count, sortable-style headers,
  blue record links, View All).
- SLDS 2 design tokens; SLDS linter run before deploy.
- Errors surfaced via toast — no silent `@wire` error swallowing. That was a
  real defect class found and fixed in the 2026-07-19 audit; do not reintroduce it.

### 5.3 Record-page LWC (observation 3)

`Opportunity_Record_Page`, positioned **above** the Activity component. Shows
the single-deal view: offer due date, days remaining with a colour-coded urgency
badge, sale process, listing broker, deal room link.

⚠ **Adding a component to `Opportunity_Record_Page` is the highest-risk
declarative edit in this pack.** That page carries 8 custom-permission
visibility rules and a heavily-ordered region. Retrieve the live page, edit,
and read the deployed result back — a FlexiPage deploy can roll back with a
design-time error that reports as success.

### 5.4 Alerts (observation 3)

- A scheduled Apex job (or scheduled-triggered Flow — the design agent decides
  and justifies) raises a **custom notification** at **7 / 3 / 1 days before**
  the offer due date and **on the day**.
- Recipient: the existing **`Acquisition` queue**.
- **Reuse the existing `Acquisitions_Deal_Update` notification type** if its
  semantics fit; create a new `notificationtypes/` entry only if they do not.
  Do not create a duplicate type by default.
- **Idempotency is required**: the job must not re-notify for an interval it has
  already fired. Without a fired-marker the team gets the same alert every day
  and stops reading them, which is worse than no alert.

🔴 **Two post-deploy gates, both of which fail silently if missed:**
1. **The job must be scheduled.** Job instances are not deployable metadata. An
   unscheduled job means zero alerts, no error, and a feature that looks shipped.
   Record the cron expression and the owning user.
2. **The `Acquisition` queue's membership must be confirmed as the right
   alerting population.** That queue was built for record ownership and lead
   routing; the two populations can drift. Queue membership is not deployable
   metadata either.

---

## 6. Testing

| Area | Requirement |
|---|---|
| Apex | 90%+ on every team-owned class touched. 251-record bulk tests for the scoring path, the alert job and the CFO derivation service. |
| Governor budgets | Assert on counters captured **inside** the async context, never `Limits.*` after `Test.stopTest()` — stopTest restores pre-test counters and makes the obvious assertion silently vacuous. |
| LWC | Jest suites for both new bundles, plus `@sa11y/jest` accessibility matchers, matching the existing 82-bundle net. |
| Migrations | Verified by **org query**, not by a green deploy. A green deploy is the false signal here. |
| Regression | Re-run `StageAdvanceServiceTest`, `RecordStageAdvanceServiceTest`, `OpportunityReviewServiceTest`, `ContractExecutionServiceTest`, `LeadConvertServiceTest`, `CounterOfferServiceTest`, `PsaVersionServiceTest`, and the LOI/PSA stage-gate tests. |

---

## 7. Sequencing

Phases 1 and 2 both touch `Opportunity` picklists and both need migrations, so
they are **serialised, not parallel**. Phase 3 depends on Phase 2 only where PSA
naming overlaps. Phase 4 is independent of all three and can proceed in parallel
once the CFO field set is settled.

```
Phase 1 (D1→D4)  ──►  Phase 2 (D1→D4)  ──►  Phase 3
Phase 4 ──────────────────────────────────────────►  (parallel)
```

---

## 8. Open questions for the design agent to resolve

- **O1.** `Fields_Captured__c` / `Fields_Missing__c` vs §1 rule 9's `_Count__c`
  suffix. The rule exists to stop a Number reading as a Boolean or category;
  `Fields_Captured__c` arguably already reads as a count. Decide and record the
  reasoning — do not silently pick one.
- **O2.** Alert job: scheduled Apex vs scheduled-triggered Flow. Decide on the
  idempotency-marker requirement and the 251-record volume, not on preference.
- **O3.** Whether the deactivated LOI and PSA values are ultimately **deleted**
  or left inactive forever. Inactive-forever is safe but clutters; deletion
  requires the full sweep rule.
- **O4.** Exact denominator field list for the extraction score. This is a
  business decision about which fields "should" have been captured, and it
  changes the meaning of every score in the org — it must be signed off, not
  inferred.
