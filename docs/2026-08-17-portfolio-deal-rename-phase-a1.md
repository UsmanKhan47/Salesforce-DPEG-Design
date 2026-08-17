# "Property Package" → "Portfolio Deal" Rename Program — Phase A1 (Reference Removal)

**Date:** 2026-08-17
**Author:** Documentation Agent
**Status:** Deployed to `usman-dpeg` (declarative + one Apex constant + seed-pipeline data). First of a
multi-phase program; Part A continues with A2 (stage-value removal) and A3 (field deletion + erase);
Part B (the actual object rename) has not started and is gated behind A3.

---

## 📋 Overview

### Original Request

> From `agent-output/design-requirements-portfolio-deal-rename.md`: rename "Property Package"
> (`Property_Package__c`, the live Broker Protection multi-property email grouping object) to
> "Portfolio Deal" across the DPEG org, including the object API name — sequenced behind retiring a
> dead, unrelated legacy Opportunity concept that already occupies the "Portfolio Deal" name.

The full program is split into two parts:

- **Part A** — retire the dead Opportunity-side `Portfolio Deal` concept (field, two companion
  fields, stage value, path step, Apex constant, report column, FLS). Phased across A1/A2/A3.
- **Part B** — full rename of `Property_Package__c` → `Portfolio_Deal__c` (object API name, Apex,
  LWC, labels). **Blocked on five open decisions** recorded in the design requirements doc §0; not
  started.

**This document covers Part A, Phase A1 only.**

### Business Objective

`Opportunity.Portfolio_Deal__c` (a self-lookup) plus its two companion fields
(`Is_Portfolio_Parent__c`, `Bundle_LOI__c`) and a `Portfolio Deal` `StageName` value made up a
manual-only bundling feature on Opportunity that is confirmed dead: **0 live records, no automation
reads or writes any of it** (design doc §1, §2.3). It happens to share its name with a completely
unrelated, live, actively-used object — `Property_Package__c`, the Broker Protection pipeline's
multi-property email grouping object (see `docs/2026-08-17-property-package-multi-property-email-
grouping.md`) — which the business wants renamed to `Portfolio_Deal__c`.

Because a deleted Salesforce custom field retains its API name until it is **permanently erased**
from Setup's Deleted Fields list, the live rename (Part B) cannot create `Opportunity.Portfolio_Deal__c`
as a new lookup until the legacy field of the same name is not just deleted but erased. Phase A1 is
the first step of clearing that name collision: it removes every *reference* to the legacy concept so
the field/stage metadata itself can be safely deleted in later phases without breaking anything that
still points at it.

### Summary

Phase A1 removed every live reference to the legacy `Portfolio Deal` Opportunity concept — a path
step, three report columns, an Apex stage-order entry (with a regression-guard test), three
permission sets' field grants, a dead LWC colour-map key, a stale LWC comment, and the seed-data
pipeline's ability to resurrect the stage or the `Is_Portfolio_Parent__c` flag on scratch-org rebuild.
**The underlying field metadata and picklist value were deliberately left in place** — that is A2/A3
work — so this phase only removes what *points at* the legacy concept, not the concept's own
declaration.

---

## 🏗️ Components Modified

All work in Phase A1 is metadata/report/permission-set edits plus one Apex constant and its test, and
two data-seed files. No new components (objects, fields, classes) were created.

### Admin Components (Declarative)

#### Path Assistants

| Path | Change |
|---|---|
| `Acquisitions_Deal_Path` | Removed the `<pathAssistantSteps>` block for `picklistValueName = 'Portfolio Deal'` (the step that carried `Is_Portfolio_Parent__c` and `Bundle_LOI__c` as its `fieldNames`). Verified absent — the remaining 8 steps run `New → Under Review → Underwriting → LOI → Under Contract (PSA) → About to Close → Closed Won → Dead/Pass`, with no `Portfolio Deal` step. This removal had to precede any future field deletion — an active path step referencing a field blocks deleting that field. |

#### Reports

| Report | Change |
|---|---|
| `Acquisitions/Deal_Status_Breakdown` | Removed all **three** `<columns>` entries that referenced the legacy fields: `Opportunity.Is_Portfolio_Parent__c`, `Opportunity.Portfolio_Deal__c`, `Opportunity.Bundle_LOI__c`. Verified absent from the deployed report XML. (Design doc §2.5 notes the original A1 pass had missed the third column — `Bundle_LOI__c` — and it was corrected before this deploy; per this repo's known gotcha, reports do not block field deletion, they silently break instead, so this had to be caught before A3.) |

#### Permission Sets — field-permission grants removed

| Permission Set | Change |
|---|---|
| `DPEG_Opportunity_View` | `<fieldPermissions>` blocks for `Portfolio_Deal__c`, `Is_Portfolio_Parent__c`, `Bundle_LOI__c` removed. Verified absent. |
| `DPEG_Acquisition_View` | Same three fields' grants removed. Verified absent. |
| `DPEG_Acquisition_Edit` | Same three fields' grants removed. Verified absent. |

Per this project's documented permission-set gotcha (a `PermissionSet` deploy replaces its *entire*
`fieldPermissions` set on deploy, not just the diff), these three files needed to be edited
surgically and diffed against HEAD before deploying, not regenerated wholesale.

**Deliberately not touched:** the 40+ `profiles/*.xml` files that also grant these three fields.
`.forceignore` excludes `force-app/main/default/profiles/**` entirely, so those files never deploy —
editing them would be repo hygiene only, not a functional change, and is explicitly deferred to A3
(design doc §2.1, §4 item 11).

### Development Components (Code)

#### Apex Classes

| Class | Change |
|---|---|
| `OpportunityFunnelController` | Removed `'Portfolio Deal'` from the `STAGE_ORDER` constant (the list that drives `getStageCounts()`'s funnel-order output). `STAGE_ORDER` now has 10 entries: `New, Under Review, Development Review, Construction Review, Underwriting, LOI, Under Contract (PSA), About to Close, Closed Won, Dead/Pass`. Class header comment already warned that a *stale* key in this list renders a permanent zero rather than erroring — dropping the entry is the correct fix, and is safe because `getStageCounts` only seeds its map from `STAGE_ORDER` itself and the LWC boards join on the emitted value, so the card disappears cleanly rather than showing zero. |

#### Test Classes

| Test Class | Change |
|---|---|
| `OpportunityFunnelControllerTest` | `getStageCounts_returnsAllStagesInFunnelOrder` still asserts the funnel returns exactly 10 stages, `New` first and `Dead/Pass` last, but now includes an explicit regression guard: `Assert.isFalse(countByLabel.containsKey('Portfolio Deal'), ...)`. This is a genuine negative assertion, not just a size check — it will fail if the stage is ever reintroduced to `STAGE_ORDER`. |

#### Lightning Web Components

| Component | Change |
|---|---|
| `recentOpportunities` | Removed the dead `'Portfolio Deal'` entry from the stage colour map (it was a harmless orphaned key that fell through to the fallback colour — removed for cleanliness, not because it was broken). |
| `pipelineStageBoard` | Corrected a stale comment that referenced "Portfolio Deal intentionally excluded" — since the stage no longer exists in `STAGE_ORDER`, the comment now reflects that this list mirrors `STAGE_ORDER` one-for-one with nothing manually excluded. |

### Data / Seed Pipeline

| File | Change |
|---|---|
| `data/opportunities.json` | Record `opp_9` ("Pearland Pad #14") was reassigned from `StageName: "Portfolio Deal"` to `StageName: "New"` — matching the existing seed pattern used by the other `Evaluating`/`Live` deal in the set (`Hwy 290 Retail Center`). The record's `Is_Portfolio_Parent__c: true` flag (found by code review in the same wave, design doc §2.5) was also removed — left in place, it would have caused an `INVALID_FIELD` failure the moment A3 deletes the field. |
| `scripts/gen-data.mjs` | The generator source row for `opp_9` was updated to match — `StageName` is now `'New'`, with an inline comment recording why (`Do NOT restore 'Portfolio Deal' here`) to stop a future edit from reintroducing it. |

Without this fix, the retired stage and the `Is_Portfolio_Parent__c` flag would have been silently
**resurrected on every scratch-org rebuild**, undoing Phase A1 and reopening the Part B name collision
— this was identified as Phase A1 work, not optional cleanup (design doc §2.3).

---

## 🔄 What This Phase Did NOT Do (deferred to A2 / A3)

Phase A1 is a **references-only** removal. The following still exist in the org and repo today,
unchanged by this phase:

| Item | Current State | Deferred To |
|---|---|---|
| `Opportunity.Portfolio_Deal__c`, `Is_Portfolio_Parent__c`, `Bundle_LOI__c` field metadata | Still present — `objects/Opportunity/fields/{Portfolio_Deal__c,Is_Portfolio_Parent__c,Bundle_LOI__c}.field-meta.xml` all still exist and deploy | Phase A3 |
| `OpportunityStage` standard value set's `Portfolio Deal` picklist value | Still present and active in `standardValueSets/OpportunityStage.standardValueSet-meta.xml` | Phase A2 |
| `scripts/gen-metadata.mjs` field-generator entries for the three fields | Unchanged — still generates the three field definitions (this is correct; the fields themselves are not yet retired) | Phase A3 |
| **Permanent erase of `Opportunity.Portfolio_Deal__c` from Setup → Deleted Fields** | Not applicable yet — the field has not even been deleted | Phase A3, and is the single hardest dependency in the whole program: Part B's Opportunity lookup wants the exact API name `Opportunity.Portfolio_Deal__c`, which a Salesforce custom field retains until permanently erased, not merely deleted |
| `LeadConvertService.cls`'s warning comments (L45-48, L386-397, L475) about keeping the two portfolio concepts apart | Unchanged — still present and, once the legacy concept is fully gone, will become obsolete/misleading | Phase A3 (rewrite, not silent deletion) |
| Repo hygiene sweep of the 40+ force-ignored `profiles/*.xml` files | Unchanged | Phase A3 (non-deploying cleanup only) |
| `Forecasting.settings-meta.xml`'s hardcoded field-Id reference (`00NIm000002XGtk`) | Unchanged — force-ignored, will not deploy, flagged as a dangling reference risk only | Not scheduled; flagged, not planned work |
| `totalOpportunities` test fixture using `'Portfolio Deal'` as its canonical *unknown*-stage value | Unchanged — flagged as semantically stale (the stage it was chosen to represent no longer exists) but no behavior change was requested, so left alone | Out of scope per design doc §8 |
| Part B (the actual `Property_Package__c` → `Portfolio_Deal__c` rename) | Not started — blocked on 5 open decisions in the design requirements doc §0 | Part B, after A3 completes and the field is erased |

**Why leave the field/stage value in place rather than removing everything in one deploy:** an active
path step or report column referencing a field blocks deleting that field, and removing a picklist
value out from under a stage that Opportunities could still theoretically reference (before the
reference sweep completes) risks the same class of "reports don't block deletion — they silently
break" failure this repo has hit before. Phasing removal → stage retirement → field deletion in that
order, each with its own deploy and verification gate, is the safer sequence (design doc §4, §7).

---

## 📁 File Locations

| Component | Path |
|---|---|
| Path Assistant | `force-app/main/default/pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml` |
| Report | `force-app/main/default/reports/Acquisitions/Deal_Status_Breakdown.report-meta.xml` |
| Permission sets | `force-app/main/default/permissionsets/DPEG_Opportunity_View.permissionset-meta.xml`, `DPEG_Acquisition_View.permissionset-meta.xml`, `DPEG_Acquisition_Edit.permissionset-meta.xml` |
| Apex controller | `force-app/main/default/classes/OpportunityFunnelController.cls` |
| Apex test | `force-app/main/default/classes/OpportunityFunnelControllerTest.cls` |
| LWCs | `force-app/main/default/lwc/recentOpportunities/recentOpportunities.js`, `force-app/main/default/lwc/pipelineStageBoard/pipelineStageBoard.js` |
| Seed data | `data/opportunities.json`, `scripts/gen-data.mjs` |
| Design requirements (full program, all findings/decisions) | `agent-output/design-requirements-portfolio-deal-rename.md` |

---

## 🧪 Testing

No new test classes were required. The existing `OpportunityFunnelControllerTest
.getStageCounts_returnsAllStagesInFunnelOrder` test was updated in place to add a negative assertion
(`Assert.isFalse(countByLabel.containsKey('Portfolio Deal'), ...)`) confirming the retired stage no
longer appears in the funnel output — a genuine regression guard against the stage being
reintroduced to `STAGE_ORDER`, not merely an unchanged size check.

No Jest tests reference the touched LWC files' changed lines (colour-map key removal, comment
correction) — both changes are non-behavioral.

This phase is declarative-plus-thin-Apex; per this project's workflow, `salesforce-code-review` scope
for a change this size is the one Apex class and its test, both reviewed as part of the same wave that
also caught the missing third report column and the `Is_Portfolio_Parent__c` seed flag (design doc
§2.5).

---

## 🔒 Security

No new fields, objects, or sharing changes. Three permission sets had field-permission grants
**removed** (not added) for the three legacy fields — this narrows access, it does not grant any new
access. No profile changes deploy (profiles are force-ignored in this repo).

---

## 📝 Notes & Considerations

### Known Limitations

- The legacy field metadata and picklist value are still live in the org. Nothing in Phase A1 prevents
  a new Opportunity from still being manually set to `StageName = 'Portfolio Deal'` or having
  `Is_Portfolio_Parent__c`/`Bundle_LOI__c` populated by hand — those guards only land in A2/A3.
- `Forecasting.settings-meta.xml` still carries a stale field-Id reference to the legacy field; it is
  force-ignored so it cannot break a deploy, but it will not be cleaned up by this program unless
  explicitly scheduled (design doc §2.2).

### Dependencies / Sequencing

- Phase A1 must be deployed and verified (path renders without the step, funnel widget shows one
  fewer card with no permanent-zero artifact, report opens cleanly) before Phase A2 removes the
  picklist value.
- Phase A2 must complete and be verified via REST describe (not via `retrieve`, which unions local and
  remote picklist values and can make a removed value appear to have returned) before Phase A3 deletes
  the field metadata.
- Phase A3's field deletion is **not sufficient** on its own to unblock Part B — the field must also be
  **permanently erased** from Setup's Deleted Fields list, or Part B's attempt to create
  `Opportunity.Portfolio_Deal__c` as a new lookup will fail with a duplicate-name error.
- Part B (the live object rename) is fully gated behind Phase A3's completion and verified erase, and
  is additionally blocked on five open design decisions not related to Phase A1 (design doc §0).

### ARCHITECTURE.md Update

No edit was made to `ARCHITECTURE.md` for this phase. The change touches no new object, no new Apex
service, and no integration boundary — the three triggers `ARCHITECTURE.md` documents as requiring an
update. The full program's rationale and decision record lives in
`agent-output/design-requirements-portfolio-deal-rename.md`, consistent with this project's pattern
for declarative-only stage/field retirement work (see `docs/2026-08-15-retire-loi-psa-legacy-stage-
values.md` for the same precedent on a different object pair).

---

## 📜 Change History

| Date | Author | Change Description |
|------|--------|-------------------|
| 2026-08-17 | Documentation Agent | Initial creation, documenting Phase A1 (reference removal) of the Portfolio Deal rename program, deployed to `usman-dpeg`. |
