# Design Requirements — "Property Package" → "Portfolio Deal" (Parts A + B)

**Date:** 2026-08-17
**Org:** usman-dpeg
**Status:** Part A specified and ready. **Part B BLOCKED on 5 decisions (§0).**
**Authority:** `ARCHITECTURE.md` §1 (naming), §2 (Apex layering), §5 (LWC)

---

## 0. BLOCKING DECISIONS — Part B cannot be handed to an implementation agent until these are answered

These are not stylistic. Each one changes the file list, the deploy count, or whether the plan is
executable at all.

**B-Q1. Does `Opportunity.Portfolio_Deal__c` (the Part A field) need a PERMANENT ERASE, not just a
delete?**
This is the single hardest dependency between the two parts. See §3.1 — Part B needs that exact API
name back, and a deleted Salesforce custom field holds its API name until it is erased from the
Deleted Fields list. If erase is not authorized, Part B's Opportunity lookup must take a different
API name and ARCHITECTURE.md §1's relationship-naming rule is knowingly broken.

**B-Q2. Do the three lookup FIELDS rename, or only the object?**
`Lead.Property_Package__c`, `Opportunity.Property_Package__c`, `Property__c.Property_Package__c`.
ARCHITECTURE.md §1 says a relationship field's name *is* the target object's name, which implies all
three rename to `Portfolio_Deal__c`. That triples the field-migration work (3 add + 3 backfill +
3 retire). Confirm.

**B-Q3. Do the LWC BUNDLE names rename (`recentPackages`, `packageSiblings`)?**
The brief says "LWCs rename" but is ambiguous between bundle API name and display text. An LWC bundle
API-name change is a delete+create and breaks the four FlexiPages that reference it by API name.
`recentPackages.js-meta.xml` explicitly records that the bundle API name was deliberately held stable
through four label changes. Confirm whether that is being superseded too.

**B-Q4. What are the new object label, plural label, and Name-field label?**
Current: label `Property Package`, plural `Property Packages`, Name field label `Package Name`.
Proposed `Portfolio Deal` / `Portfolio Deals` / `Deal Name`? The Name-field label is not derivable.

**B-Q5. Do the relationship names on the three lookups change?**
Currently `Leads`, `Properties`, and (Opportunity) — these are child-relationship names used in
subqueries. Changing them is an Apex-breaking change; keeping them is a naming inconsistency.
Confirm which way.

---

## 1. WHAT WAS REQUESTED

Rename "Property Package" to "Portfolio Deal" across the DPEG org **including the object API name**,
sequenced behind the retirement of the colliding legacy Opportunity "Portfolio Deal" artifacts.

- **Part A** — retire the dead Opportunity-side `Portfolio Deal` concept (field, two companion
  fields, stage value, path step, Apex constant, report column, FLS).
- **Part B** — full rename of `Property_Package__c` → `Portfolio_Deal__c` (object API name, Apex,
  LWC, labels), phased as add → migrate → repoint → retire.

---

## 2. FINDINGS THAT CONTRADICT OR EXTEND THE BRIEF

Investigated before planning. Six items change the shape of the work.

### 2.1 🔴 The profile FLS sweep is NOT a deploy step — profiles are force-ignored

The brief calls for a cleanup sweep of `Portfolio_Deal__c` FLS across 40+ profile files and treats it
as a prerequisite. `.forceignore` line 28 excludes `force-app/main/default/profiles/**` entirely,
with a documented rationale (394 validation errors). **Those 40+ profile files never deploy.** Editing
them is repo hygiene, not a blocker, and it cannot break or fix anything in the org.

**The real FLS lives in permission sets, which the brief did not mention and which DO deploy:**

| Permission set | Grants |
|---|---|
| `DPEG_Opportunity_View` | `Portfolio_Deal__c`, `Is_Portfolio_Parent__c`, `Bundle_LOI__c` |
| `DPEG_Acquisition_View` | `Portfolio_Deal__c`, `Is_Portfolio_Parent__c`, `Bundle_LOI__c` |
| `DPEG_Acquisition_Edit` | (verify — carries Opportunity grants) |

⚠ Per prior incident on this project, **a PermissionSet deploy REPLACES its entire `fieldPermissions`
set** — these three files must be edited surgically and diffed against HEAD before deploying, not
regenerated. `.claude/agents` note: a second concurrent session has previously turned shared
permission-set files into a union of two features.

### 2.2 🔴 `settings/**` is also force-ignored, and Forecasting references the field by hardcoded Id

`Forecasting.settings-meta.xml` carries `<label>Portfolio Deal</label>` in four places, keyed to
field Id `00NIm000002XGtk` — **an Id, not an API name**. It is force-ignored (`.forceignore` line 32),
so it will not deploy and will not block the field deletion. But it will hold a dangling Id reference,
and per this project's history, force-ignored settings files are unreconciled fiction. Flag, do not
treat as work.

### 2.3 🔴 The seed-data pipeline will RESURRECT the retired stage

The brief states Part A needs no data step because there are 0 live records. True for existing data,
but two seed sources create an Opportunity at that stage on the next org rebuild:

- `data/opportunities.json` line 181 — `"StageName": "Portfolio Deal"` (record `opp_9`, "Pearland Pad #14")
- `scripts/gen-data.mjs` line 34 — the generator row that produces it
- `scripts/gen-metadata.mjs` lines 230-232 — regenerates all three Opportunity fields

**If these are not fixed, Part A is silently undone on the next scratch/seed rebuild**, and the
Part B collision returns. This is Part A work, not optional cleanup.

### 2.4 The stage value has more consumers than the brief lists

Beyond `OpportunityFunnelController.STAGE_ORDER`:

| File | Reference | Effect of leaving it |
|---|---|---|
| `lwc/recentOpportunities/recentOpportunities.js` L19 | `'Portfolio Deal'` in the stage colour map | Dead map key — harmless, falls through to fallback |
| `lwc/pipelineStageBoard/pipelineStageBoard.js` L18 | Comment: "Portfolio Deal intentionally excluded" | Stale comment referencing a stage that no longer exists |
| `lwc/totalOpportunities/__tests__/totalOpportunities.test.js` L93 | Uses `'Portfolio Deal'` as its canonical *unknown* stage fixture | ⚠ Test still passes but its premise inverts — it was chosen as a REAL stage not in STAGE_META |

On `STAGE_ORDER` specifically: the class comment warns a *stale* key renders a permanent zero rather
than erroring. Removing the entry is the correct fix and is safe — `getStageCounts` seeds the map
from `STAGE_ORDER` and only fills keys it already contains, so dropping the entry drops the card. The
LWC boards join on the emitted value, so the card disappears cleanly rather than rendering zero.

### 2.5 The report references the FIELDS, not the stage

`reports/Acquisitions/Deal_Status_Breakdown.report-meta.xml` carries **three** `<columns>` entries:
`Opportunity.Is_Portfolio_Parent__c`, `Opportunity.Portfolio_Deal__c`, and `Opportunity.Bundle_LOI__c`
(corrected 2026-08-17 by code review — the original pass here missed the third column). No stage
filter. All three must be removed before the fields are retired — per this repo's known gotcha, reports
do not block field deletion, they silently break.

**Correction to §4 Phase A1 item 5 (seed pipeline):** the same code review found the stage
reassignment in `data/opportunities.json`/`scripts/gen-data.mjs` left `Is_Portfolio_Parent__c: true`
in place on the reassigned record (`opp_9`). That field-level flag must be removed in the same wave
as the stage reassignment, not deferred to A3 — otherwise the seed pipeline hard-fails on
`INVALID_FIELD` the moment A3 deletes the field.

### 2.6 Part B is 43 files / 607 occurrences, and THREE lookups — not ~39 files and one lookup

The brief names `Property__c.Property_Package__c`. There are three inbound lookups, all
`deleteConstraint=SetNull`:

- `Lead.Property_Package__c` (relationshipName `Leads`)
- `Opportunity.Property_Package__c`
- `Property__c.Property_Package__c` (relationshipName `Properties`)

Consumers not named in the brief: `LeadSelector` (20 refs), `OpportunitySelector` (12),
`LeadFunnelController`, `EmailToLeadService`, `ExtractAddressQueueable`, `lwc/recentLeads`,
`applications/Acquisition.app`, `flexipages/Property_Package_Record_Page`, `Lead_Funnel`,
`Opportunity_Record_Page`, `Lead_Record_Page`, `layouts/Property_Package__c-Property Package Layout`,
five permission sets (`DPEG_Admin_Access`, `DPEG_Acquisition_View`, `DPEG_Acquisition_Edit`,
`Broker_Protection_Access`, `DPEG_Apex_Access`), `manifest/package.xml`,
`scripts/seed-fsd-07-property-package.apex`, and `ARCHITECTURE.md` §2.

No Tab and no sharingRules exist for the object (verified) — two migration steps the plan does *not* need.

---

## 3. ANSWERS TO THE THREE QUESTIONS ASKED

### 3.1 (1) Does an OBJECT rename carry the same case-only and required-field traps as a field?

**Case-only-is-a-no-op: YES, and worse.** The Metadata API treats a case-only `fullName` change on a
CustomObject as a no-op exactly as it does for fields — the deploy reports success and changes
nothing. Not directly relevant here (`Property_Package__c` → `Portfolio_Deal__c` is not case-only),
but it applies to the *label* fields, where a case-only edit to `<label>` is also silently dropped.

**Required-field trap: NOT APPLICABLE in the same form.** The field-level trap is that a required
field cannot be added and backfilled in one deploy. At object level the analogous trap is different
and worse: **a Master-Detail child cannot be reparented across objects at all.** Verified — all three
inbound relationships are Lookup with `SetNull`, and `Property_Package__c` is itself a child of
nothing. So this trap does not bite. It would have made the migration impossible if any relationship
were Master-Detail.

**🔴 The trap that DOES bite, and it is the Part A/Part B hinge:** a deleted Salesforce custom field
**retains its API name until it is permanently erased** from Setup's Deleted Fields list. Part B's
Opportunity lookup to the new object wants the API name `Opportunity.Portfolio_Deal__c` under
ARCHITECTURE.md §1's relationship-naming rule — the *exact* name Part A's legacy field occupies.
Deleting it in Part A is **not sufficient**; it must be erased, or Part B's creation of that field
fails with a duplicate-name error. This is the direct analogue of this project's documented
"deleting a once-active approval process needs a Recycle-Bin purge" precedent. **See B-Q1.**

### 3.2 (2) What happens to Ids and relationships during the migration?

**Every record Id changes.** A new custom object gets a new 3-character key prefix; migrated records
are new records with new 18-character Ids. Consequences:

- **The three lookups cannot be "repointed."** A Lookup's `referenceTo` is immutable after creation.
  Each of the three must be created as a NEW field pointing at `Portfolio_Deal__c`, backfilled via an
  old-Id → new-Id map, and only then retired. This is the field-level additive pattern, executed
  three times, on top of the object migration.
- **A backfill key is required.** `Property_Package__c.Source_Staging_Id__c` exists and is the natural
  external key for the old→new mapping — confirm it is populated on 100% of live rows before relying
  on it. If it is not, the migration needs a temporary `Legacy_Id__c` text field on the new object.
- **`SetNull` is a live hazard during the cutover window.** If the old object is deleted while any of
  the three legacy lookups still hold values, those values are nulled — destroying the very mapping
  the backfill depends on. **Retire the old object LAST, after all three new lookups are populated
  and verified.**
- **Bookmarks, saved list-view filters, and any hardcoded Id in a URL tab break.** This project has a
  documented recurrence of exactly this ("stale hardcoded Dashboard Ids in URL tabs, recurs on every
  org rebuild").

### 3.3 (3) Additional traps specific to renaming a CUSTOM OBJECT rather than a field

1. **`enableReports=true` + `enableSearch=false`, `sharingModel=ReadWrite`, `visibility=Public`** —
   the new object must be created with these settings matched exactly, or behaviour silently diverges.
   `enableActivities=false` and `enableHistory=false` likewise.
2. **Report Types.** Any custom report type built on `Property_Package__c` does not migrate and
   cannot be repointed. Reports built on it break silently (repo precedent). A sweep of
   `reportTypes/` and `reports/` for the object is required — the brief did not include one.
3. **Experience Cloud.** `digitalExperiences/**`, `networks/**`, and `sites/**` are ALL force-ignored
   in this repo, so any Broker Portal reference to this object is invisible to the repo sweep and
   must be checked **in the org**, not in source. Since Broker Protection is the sole writer of this
   object, treat this as a real risk, not a formality.
4. **Record types:** none exist on this object (verified) — no dependency.
5. **FlexiPage:** `Property_Package_Record_Page` is bound to the object; a FlexiPage cannot be
   repointed to a different sObject. A new FlexiPage must be created and assigned.
   ⚠ Repo precedent: **a FlexiPage deploy can roll back on a design-time error and still report
   success** — read the page back after deploying.
6. **Layout:** `Property_Package__c-Property Package Layout` must be recreated on the new object.
7. **Metadata-API-deployed fields arrive with NO FLS for anyone, System Administrator included**
   (ARCHITECTURE.md §2). Every field on the new object needs explicit permission-set grants in the
   same wave, or the object is invisible and Apex throws `No such column`.

---

## 4. 🔵 PART A — ADMIN / DECLARATIVE RETIREMENT

**Agent: `salesforce-admin`** (routine declarative retirement; no architecture design needed)
plus a small `salesforce-developer` slice for the Apex constant and seed scripts.

### Phase A1 — Remove every reference (one deploy)

1. `pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml` — delete the entire
   `<pathAssistantSteps>` block for `picklistValueName` = `Portfolio Deal` (lines 40-45, carrying
   `Is_Portfolio_Parent__c` and `Bundle_LOI__c`). **Must precede field deletion — an active path
   step referencing a field blocks its deletion.**
2. `reports/Acquisitions/Deal_Status_Breakdown.report-meta.xml` — remove the two `<columns>` entries
   (`Opportunity.Is_Portfolio_Parent__c` L355, `Opportunity.Portfolio_Deal__c` L376).
3. `classes/OpportunityFunnelController.cls` — remove `'Portfolio Deal'` from `STAGE_ORDER` (L23) and
   the trailing comma on L22. Update `OpportunityFunnelControllerTest` if it asserts list size.
4. Permission sets — surgically remove the `<fieldPermissions>` blocks for all three fields from
   `DPEG_Opportunity_View`, `DPEG_Acquisition_View`, and `DPEG_Acquisition_Edit`.
   **Diff each against HEAD before deploying** (§2.1).
5. Seed pipeline (§2.3) — `data/opportunities.json` L181, `scripts/gen-data.mjs` L34,
   `scripts/gen-metadata.mjs` L230-232. Reassign `opp_9` to a surviving stage.
6. `lwc/recentOpportunities/recentOpportunities.js` L19 — remove the dead colour-map key.
7. `lwc/pipelineStageBoard/pipelineStageBoard.js` L18 — update the stale comment.

**Deploy, then verify:** the path renders without the step; the funnel widget shows one fewer card
and no permanent zero; the report opens.

### Phase A2 — Remove the stage value (one deploy)

8. `standardValueSets/OpportunityStage.standardValueSet-meta.xml` — remove the `Portfolio Deal`
   `<standardValue>` block (L130-138).

⚠ Repo precedent — **STANDING RULE: grep the repo AND query the org before removing any picklist
value.** Also: a `retrieve` UNIONS local and remote picklist values, so a retrieve after this deploy
will appear to restore the value locally. Verify removal via REST describe, not via retrieve.

### Phase A3 — Retire the fields (one deploy) + erase

9. Delete `objects/Opportunity/fields/Portfolio_Deal__c.field-meta.xml`,
   `Is_Portfolio_Parent__c.field-meta.xml`, `Bundle_LOI__c.field-meta.xml`.
10. **Permanently erase `Opportunity.Portfolio_Deal__c` from Setup → Deleted Fields** — pending B-Q1.
    Without this, Part B cannot create its Opportunity lookup (§3.1).
11. Repo hygiene only (does not deploy): strip the three fields from the 40+ `profiles/*.xml`.
12. `LeadConvertService.cls` — the long warning comments at L45-48, L386-397 and L475 exist solely to
    keep the two portfolio concepts apart. Once the legacy concept is gone the warning is obsolete
    and, if left, actively misleading. Rewrite, do not delete silently.

---

## 5. 🟢 PART B — OBJECT + APEX + LWC RENAME

**Gate: do not start until Part A is deployed, verified, and the field is ERASED.**

**Agents:**
- `salesforce-solution-architect` — new object + 3 lookup fields + FlexiPage/layout + permission-set
  architecture + the data-migration design.
- `salesforce-developer` — Apex (3 classes + 3 test classes + 5 consumer classes) and LWC repointing.
- `salesforce-technical-architect` — **only** if the record migration needs a Batch/Queueable, which
  it will if row count is non-trivial.

### Phase B1 — Create the new object alongside the old
Create `Portfolio_Deal__c` with all six custom fields (`Property_Count__c`, `Broker_Email__c`,
`Broker_Name__c`, `Source_Staging_Id__c`, `Received_DateTime__c`, `Routed_Outcomes__c`) and object
settings matched exactly to §3.3.1. Grant FLS in the same wave (§3.3.7). Old object untouched.

### Phase B2 — Add the three new lookups (additive)
Add `Portfolio_Deal__c` lookups on `Lead`, `Opportunity`, `Property__c` — **pending B-Q2 and B-Q5**.
`required=false`, `SetNull`. Both old and new lookups coexist. Grant FLS.

### Phase B3 — Migrate data
Copy every `Property_Package__c` row to `Portfolio_Deal__c`, keyed by `Source_Staging_Id__c`, then
backfill the three new lookups from the old→new Id map. Old lookups still populated — do not clear.
**Verify counts match on all four objects before proceeding.**

### Phase B4 — Repoint every reader
- **Apex (rename + repoint):** `PropertyPackageController` → `PortfolioDealController`,
  `PropertyPackageSelector` → `PortfolioDealSelector`, `PropertyPackageService` → `PortfolioDealService`,
  plus the three test classes. ⚠ Class names are capped at 40 chars (repo precedent) — all six fit.
  ⚠ Apex class rename is delete+create; the old classes must be removed in the same deploy or they
  fail to compile against the retired object.
- **Apex (consumers, repoint only):** `LeadSelector`, `OpportunitySelector`, `LeadFunnelController`,
  `EmailToLeadService`, `ExtractAddressQueueable`, `LeadConvertService`, and their tests.
- **LWC:** `recentPackages`, `packageSiblings`, `recentLeads` — **pending B-Q3**. If bundles rename,
  the four FlexiPages referencing them by API name must change in the same deploy.
- **Metadata:** `Acquisition.app`, four FlexiPages, the layout, five permission sets,
  `manifest/package.xml`, `scripts/seed-fsd-07-property-package.apex`.
- **Docs:** `ARCHITECTURE.md` §2 and the `recentPackages.js` header (§6 below).

### Phase B5 — Retire the old object
Delete the three old lookups FIRST, then the old object, then the old layout and FlexiPage.
**Order is load-bearing** — deleting the object first nulls the old lookups via `SetNull` (§3.2).

### Phase B6 — Verify
Full `RunLocalTests`; Jest suite; read back all four FlexiPages (a FlexiPage deploy can report
success after rolling back); confirm the Broker Protection pipeline end-to-end with a live inbound
email, since it is the object's only writer.

---

## 6. ⚠ EXPLICIT SUPERSESSION REQUIRED (as the brief asked me to confirm)

`lwc/recentPackages/recentPackages.js` (header L43-77) and `recentPackages.js-meta.xml` (L5-15)
record a deliberate, same-day decision that:

- `Portfolio Deals` was **RETRACTED, marked "🔴 DO NOT RESTORE IT"**, because it collided with the
  `Portfolio Deal` Opportunity stage value; and
- the label work "cost no schema edits" and must not be read "as the start of a rename into the schema."

**This design intentionally supersedes both statements.** The supersession is only coherent *because*
Part A removes the stage value that caused the retraction — which is exactly why Part A must be
complete and verified first. If Part A is skipped or partially deployed, the original retraction
still stands and Part B must not proceed.

Part B must **rewrite** these two headers plus `packageSiblings`' header in the same deploy. Leaving a
"DO NOT RESTORE" banner in place after doing the thing it forbids is how the next reader reverts it.

---

## 7. RECOMMENDED EXECUTION ORDER

| # | Phase | Agent | Gate |
|---|---|---|---|
| 1 | A1 references | admin + developer | Funnel/path/report verified |
| 2 | A2 stage value | admin | REST describe confirms removal |
| 3 | A3 fields + **erase** | admin | **Erase confirmed in Setup** |
| 4 | B1 new object | solution-architect | FLS granted, object visible |
| 5 | B2 new lookups | solution-architect | Both old+new coexist |
| 6 | B3 migrate | technical-architect | Row counts match |
| 7 | B4 repoint | developer | RunLocalTests + Jest green |
| 8 | B5 retire old | admin | Lookups deleted before object |
| 9 | B6 verify | devops | Live inbound-email test |

**Nine deploys.** Consistent with the `Unit__c` → `Unit_Label__c` precedent (5 deploys for a *field*);
an object rename with three inbound lookups and a data migration is legitimately larger.

---

## 8. OUT OF SCOPE

- Any change to Broker Protection *semantics* — this is a rename only. `Property_Package__c`'s
  one-email-to-many-records meaning is preserved exactly under the new name.
- Any merge of the two portfolio concepts. Part A deletes the legacy one; it is not folded into the
  surviving one.
- The `totalOpportunities` test fixture (§2.4) — flagged as semantically stale, not changed, because
  no behaviour change was requested.
