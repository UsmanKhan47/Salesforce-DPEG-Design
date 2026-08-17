# "Property Package" → "Portfolio Deal" Rename Program — Phase A2 (Stage-Value Removal)

**Date:** 2026-08-17
**Author:** Documentation Agent
**Status:** Deployed to `usman-dpeg` (deploy `0Afiw000000LW9mCAG`). Second of a multi-phase program;
Part A continues with A3 (field deletion + permanent erase); Part B (the actual object rename) has not
started and remains gated behind A3.

---

## 📋 Overview

### Original Request

> From `agent-output/design-requirements-portfolio-deal-rename.md` §4, Phase A2: remove the
> `Portfolio Deal` standard value from `standardValueSets/OpportunityStage.standardValueSet-meta.xml`,
> now that Phase A1 has removed every live reference to it (path step, report columns, Apex
> `STAGE_ORDER` entry, permission-set grants, seed data, LWC dead key/comment). Per this repo's
> standing rule, grep the repo and query the org before removing any picklist value, and verify the
> removal via REST describe rather than `retrieve` (which unions local and remote picklist values and
> can make a removed value appear to have returned).

This document covers **Part A, Phase A2 only**. See `docs/2026-08-17-portfolio-deal-rename-phase-
a1.md` for Phase A1 (reference removal) and `agent-output/design-requirements-portfolio-deal-rename.md`
for the full nine-deploy program plan (§7).

### Business Objective

Same underlying objective as Phase A1: the legacy, dead Opportunity `Portfolio Deal` stage (0 live
records, no automation) occupies a name the business wants to reuse — the live rename of
`Property_Package__c` → `Portfolio_Deal__c` (Part B) needs that name, and needs
`Opportunity.Portfolio_Deal__c` free of both the field and the picklist value that references the same
concept. Phase A1 stripped every consumer that *pointed at* the stage; Phase A2 removes the stage
value's own declaration from `OpportunityStage`. The field metadata itself (Phase A3) is the only
remaining piece of the legacy concept still standing after this phase.

### Summary

Phase A2 removed the `Portfolio Deal` `<standardValue>` block from `OpportunityStage`, verified via a
live describe that 10 active stage values remain. Executing the removal also surfaced and reconciled
two pieces of drift unrelated to the stage value itself — a stale, already-dead `PSA` standard value
sitting in the same file, and a leftover empty Path Assistant step — and prompted a Jest fixture update
so a test's intent no longer depends on institutional memory of a retired stage. All four changes
landed in the single A2 deploy.

---

## 🏗️ Components Modified

All work in Phase A2 is a single metadata edit (the standard value set) plus incidental cleanup of
drift discovered while making that edit, and one Jest fixture update. No new components (objects,
fields, classes) were created.

### Admin Components (Declarative)

#### Standard Value Sets

| Component | Change |
|---|---|
| `standardValueSets/OpportunityStage.standardValueSet-meta.xml` | Removed the `Portfolio Deal` `<standardValue>` block entirely (label, `closed`, `forecastCategory`, `probability`, `won` all removed with it — there was no partial/soft-retire option; a `StandardValueSet` entry doesn't support `isActive=false` the way custom picklist values do). **Verified: deploy `0Afiw000000LW9mCAG` succeeded and the live org now returns exactly 10 active `StageName` values**: `New, Under Review, Development Review, Construction Review, Underwriting, LOI, Under Contract (PSA), About to Close, Closed Won, Dead/Pass`. `Portfolio Deal` is absent from this list. |

#### Unrelated drift reconciled in the same file (see "Key Design Decisions" below)

| Component | Change |
|---|---|
| `standardValueSets/OpportunityStage.standardValueSet-meta.xml` | Removed a **stale `PSA` `<standardValue>` block** (`isActive=false`) that the file had carried since an earlier, unrelated migration (P2-D3). A live sobject describe of `Opportunity.StageName` against `usman-dpeg` confirmed the org had *already* dropped `PSA` entirely — not even present as an inactive value — so deploying the file as it stood before this reconciliation would have **silently resurrected `PSA` in the org**, undoing a prior migration this program had nothing to do with. |
| `standardValueSets/OpportunityStage.standardValueSet-meta.xml` | Corrected the file's header comment, which had described the `PSA` block as `"P2-D3, staged, not applied here"` — that description was stale/wrong given the confirmed org state, and was rewritten to state that `PSA` is now fully retired and why the block was deleted rather than deployed as inactive. |

#### Path Assistants

| Component | Change |
|---|---|
| `pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml` | No direct edit in this phase — but a **phantom 9th step** left behind by Phase A1 (an empty `<pathAssistantSteps>` block for `picklistValueName = 'Portfolio Deal'`, stripped of its `fieldNames` in A1 but not removed outright at the time) only disappeared once the underlying picklist value itself was removed here. **Verified: the deployed path now shows exactly 8 real steps** (`New → Under Review → Underwriting → LOI → Under Contract (PSA) → About to Close → Closed Won → Dead/Pass`), with no `Portfolio Deal` entry, empty or otherwise. |

### Development Components (Code)

#### Test Fixtures (Jest)

| File | Change |
|---|---|
| `lwc/totalOpportunities/__tests__/totalOpportunities.test.js` | Replaced the `'Portfolio Deal'` literal used as the test's canonical "unknown/unmapped stage" fixture with a deliberately synthetic value, `'__NOT_A_REAL_STAGE__'`. **Verified present** in the "ignores unknown labels and defaults unreported stages to 0" test, with an inline comment explaining the swap: the previous fixture was a *real* (if unmapped) stage, so its meaning quietly inverted the moment `Portfolio Deal` was actually retired from the picklist — using a value that can never exist in `OpportunityStage` keeps the test's intent readable without depending on which stages the org happens to have configured. This was flagged as stale by Phase A1's design doc (§2.4, §8) but explicitly left alone at the time because no behavior change had been requested; removing the stage's last live declaration in A2 made the fixture's premise actually false, not just stale, so it was fixed here. |

No Apex was touched in this phase — Phase A1 already removed `Portfolio Deal` from
`OpportunityFunnelController.STAGE_ORDER` and added the negative-assertion regression guard in
`OpportunityFunnelControllerTest`; both remain unchanged and still pass with `Portfolio Deal` now
absent from the picklist as well as from `STAGE_ORDER`.

---

## 🔑 Key Design Decisions and Rationale

### Why the PSA drift was reconciled here, not deferred

The design doc's Phase A2 scope (§4 item 8) is a single line: remove the `Portfolio Deal`
`<standardValue>` block. It says nothing about `PSA`. Reconciling the `PSA` drift here was an
in-flight discovery, not planned work — the same file happened to carry both. Two things made
deferring it the wrong call:

1. **Deploying the file unmodified would have been an active regression, not a no-op.** The file's own
   header comment claimed the `PSA` block was "staged, not applied" — implying it was safely inert.
   A live describe proved that framing false: the org had already fully retired `PSA` through an
   earlier, separate migration (P2-D3), so the file was drifted *ahead* of what its own comment
   claimed. Deploying it as originally edited would have resurrected a value the org had already
   correctly removed.
2. **The user explicitly authorized folding this into the Portfolio Deal deploy** rather than opening a
   separate phase/deploy for it, since both changes touch the identical file and the alternative — a
   second deploy to the same `StandardValueSet` purely to fix a comment/drift issue found while doing
   the first — was judged not worth the extra deploy for a fix this small and this clearly justified by
   a live describe.

The header comment was rewritten rather than left in its stale form specifically because this repo's
convention (established in the same file during the earlier P2 migration, and reinforced by this
project's `docs/2026-08-15-retire-loi-psa-legacy-stage-values.md`) is that in-file comments must
reflect current reality, not a snapshot of an old plan — a comment that contradicts the file's own
content is exactly the kind of drift that caused this reconciliation to be necessary in the first
place.

### Why the phantom path step required no direct edit

Phase A1 stripped the `Portfolio Deal` path step's `fieldNames` (`Is_Portfolio_Parent__c`,
`Bundle_LOI__c`) because those were the actual field-level references blocking field deletion, but per
the A1 doc's own account, the step *entry* itself — keyed to `picklistValueName = 'Portfolio Deal'` —
was left behind as an empty placeholder rather than deleted outright at that time. A `PathAssistant`
step is keyed to a picklist value that must exist in the underlying `StageName` set; removing the step
explicitly in A1 while the picklist value was still active was unnecessary work in that phase and would
have meant editing the same file twice across two phases for no operational benefit. Removing the
picklist value in A2 made the step reference an now-nonexistent value, and Salesforce's own path
rendering silently drops steps for values that no longer exist in the underlying picklist — this is why
verification shows exactly 8 real steps with no manual edit to the `PathAssistant` file in this phase.

### Why the Jest fixture was fixed now, not left deferred to A3

Phase A1's design doc (§2.4) explicitly flagged this fixture as "semantically stale" but left it
unchanged, reasoning that no behavior change had been requested and the test still passed. That
reasoning held only while `Portfolio Deal` was still a real (if unreferenced) stage value — the
fixture's entire point was to use a real-but-unmapped stage as the "unknown" case. Once A2 removed the
stage's last live declaration, `'Portfolio Deal'` stopped being a real stage at all, which is a
stronger and different kind of staleness than what A1 deferred: the test's documented *intent* ("a real
stage the component doesn't map") became actively false, not merely reliant on institutional memory.
Fixing it in the same phase that caused the premise to flip, rather than carrying a doc-flagged-false
test description into A3, was the more conservative choice.

---

## 🔄 What This Phase Did NOT Do (deferred to A3)

Phase A2 removed the picklist value only. The following still exist in the org and repo today,
unchanged by this phase:

| Item | Current State | Deferred To |
|---|---|---|
| `Opportunity.Portfolio_Deal__c`, `Is_Portfolio_Parent__c`, `Bundle_LOI__c` field metadata | Still present — `objects/Opportunity/fields/{Portfolio_Deal__c,Is_Portfolio_Parent__c,Bundle_LOI__c}.field-meta.xml` all still exist and deploy | Phase A3 |
| **Permanent erase of `Opportunity.Portfolio_Deal__c` from Setup → Deleted Fields** | Not applicable yet — the field has not been deleted, let alone erased | Phase A3 — the single hardest dependency in the whole program (Part B's Opportunity lookup wants this exact API name back) |
| `scripts/gen-metadata.mjs` field-generator entries for the three fields | Unchanged — still generates the three field definitions | Phase A3 |
| `LeadConvertService.cls`'s warning comments about keeping the two portfolio concepts apart | Unchanged — still present and, once the field is gone, will become obsolete/misleading | Phase A3 (rewrite, not silent deletion) |
| Repo hygiene sweep of the 40+ force-ignored `profiles/*.xml` files still granting FLS on the three fields | Unchanged | Phase A3 (non-deploying cleanup only) |
| `Forecasting.settings-meta.xml`'s hardcoded field-Id reference (`00NIm000002XGtk`) | Unchanged — force-ignored, will not deploy, flagged as a dangling reference risk only | Not scheduled; flagged, not planned work |
| `objects/Opportunity/businessProcesses/Land.businessProcess-meta.xml`'s stale comment | **Unchanged — newly re-confirmed this phase.** Line 20 still reads `See agent-output/p2-d3-retire-psa/`, a directory that no longer exists in this repo (the same drift class this phase's own file — `OpportunityStage.standardValueSet-meta.xml` — used to carry, and had corrected as part of the P2-D3 reconciliation on 2026-08-17). This is a **different file**, out of Phase A2's scope; flagged here for Phase A3 cleanup rather than fixed in-flight. |
| Part B (the actual `Property_Package__c` → `Portfolio_Deal__c` rename) | Not started — blocked on 5 open decisions in the design requirements doc §0 | Part B, after A3 completes and the field is erased |

---

## 📁 File Locations

| Component | Path |
|---|---|
| Standard Value Set | `force-app/main/default/standardValueSets/OpportunityStage.standardValueSet-meta.xml` |
| Path Assistant (verification target, no direct edit) | `force-app/main/default/pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml` |
| Jest fixture | `force-app/main/default/lwc/totalOpportunities/__tests__/totalOpportunities.test.js` |
| Deferred cleanup item (flagged, not fixed) | `force-app/main/default/objects/Opportunity/businessProcesses/Land.businessProcess-meta.xml` |
| Design requirements (full program, all findings/decisions) | `agent-output/design-requirements-portfolio-deal-rename.md` |
| Phase A1 documentation | `docs/2026-08-17-portfolio-deal-rename-phase-a1.md` |

---

## 🧪 Testing

No new Apex test classes were required — Phase A1 already added the `STAGE_ORDER` regression guard in
`OpportunityFunnelControllerTest`, which continues to pass unchanged now that the picklist value is
also gone.

One existing Jest test was updated in place (`totalOpportunities.test.js` — see "Key Design Decisions"
above); no test count changed, no new test file was added.

Primary verification for this phase was a **live REST describe of `Opportunity.StageName` against
`usman-dpeg`**, confirming exactly 10 active values with `Portfolio Deal` absent — per this repo's
standing rule, `retrieve` was deliberately not used to verify this, since `retrieve` unions local and
remote picklist values and would make a removed value appear to have returned.

---

## 🔒 Security

No new fields, objects, sharing, or FLS changes in this phase. Removing a `StandardValueSet` value does
not touch field-level permissions — those were already narrowed in Phase A1's permission-set edits.

---

## 📝 Notes & Considerations

### Known Limitations

- The legacy field metadata (`Portfolio_Deal__c`, `Is_Portfolio_Parent__c`, `Bundle_LOI__c`) is still
  live in the org after this phase. Nothing in A2 prevents those fields from still being populated by
  hand on an Opportunity — only Phase A3's field deletion closes that gap.
- `objects/Opportunity/businessProcesses/Land.businessProcess-meta.xml` still points at a nonexistent
  `agent-output/p2-d3-retire-psa/` directory in a comment. It does not affect deploys (comments don't
  deploy-fail) but is stale documentation that should be corrected alongside Phase A3's other cleanup.

### Dependencies / Sequencing

- Phase A2 required Phase A1 to be deployed and verified first — an active path step or report column
  referencing the legacy fields would have blocked this phase's picklist-value removal in the same way
  it would have blocked a field deletion.
- Phase A3 (field deletion + permanent erase) is now unblocked from a *references* standpoint but is
  still the phase that must resolve the program's hardest dependency: a deleted Salesforce custom field
  retains its API name until it is **permanently erased** from Setup's Deleted Fields list, and Part B's
  Opportunity lookup needs the exact name `Opportunity.Portfolio_Deal__c` back.
- Part B (the live object rename) remains fully gated behind Phase A3's completion and verified erase,
  and is additionally blocked on five open design decisions unrelated to Phase A2 (design doc §0).

### ARCHITECTURE.md Update

No edit was made to `ARCHITECTURE.md` for this phase, for the same reason recorded in the Phase A1 doc:
the change touches no new object, no new Apex service, and no integration boundary — the three triggers
`ARCHITECTURE.md` documents as requiring an update. The full program's rationale and decision record
lives in `agent-output/design-requirements-portfolio-deal-rename.md`.

---

## 📜 Change History

| Date | Author | Change Description |
|------|--------|-------------------|
| 2026-08-17 | Documentation Agent | Initial creation, documenting Phase A2 (stage-value removal, deploy `0Afiw000000LW9mCAG`) of the Portfolio Deal rename program, deployed to `usman-dpeg`. |
