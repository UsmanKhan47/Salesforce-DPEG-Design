# Permission Set Cleanup + `Opportunity_Stage_Actions_Access`

**Date:** 2026-08-10
**Author:** Documentation Agent
**Status:** ✅ **DEPLOYED AND VERIFIED on `usman-dpeg` 2026-08-10.** The additive half (§3 below) shipped in the two ordered stages this document prescribes:

| Stage | Deploy Id | Components | Result |
| --- | --- | --- | --- |
| 1 | `0Afiw000000HXvdCAG` | `Opportunity_Stage_Actions_Access` (new), `DPEG_Junior_Analyst_PSG`, `Acquisition_Deal_Driver` | Succeeded, 3/3, 0 errors |
| — | — | `DPEG_Junior_Analyst_PSG` polled to `Status = Updated` before stage 2 | confirmed |
| 2 | `0Afiw000000HXxFCAW` | `DPEG_Apex_Access` (28 → 26) | Succeeded, 1/1, 0 errors |

Verified against org state rather than asserted: `Opportunity_Stage_Actions_Access` carries exactly the 4 intended `classAccesses`; `DPEG_Apex_Access` is at 26 with `StageAdvanceController` and `OpportunityApprovalController` removed and `OpportunityActionPermissionController` / `RecordStageAdvanceController` retained; **37/37 tests pass** across `OpportunityActionPermissionServiceTest`, `OpportunityActionPermissionCtrlTest`, `UserSelectorTest` and `StageAdvanceControllerTest`, including the two-factor falsifier `hasDealActionAccess_membershipWithoutTheFlag_isStillDenied`.

🔴 **The pre-stage-2 reconcile was run and is the reason stage 2 was safe** — see the REPLACE-not-merge rule in `ARCHITECTURE.md` §2. The org held exactly 28 `ApexClass` grants on `DPEG_Apex_Access` against the repo's 26, and the delta was **precisely** the two classes being removed: no org-side-only grant existed to be destroyed. Re-run that reconcile before any future edit to this set; a clean result here is not a standing guarantee.

⚠ **`DPEG_Admin_Access` was NOT deployed** — it is modified in the working tree but belongs to the §6 `Acquisition_App_Access` retirement, not to this pass. The five staged retirements in §6 are **not executed** — they are a runbook for future, separately-scheduled work.

⚠ **UAT persona note (masking).** `DPEG_Acquisitions` also grants both trimmed classes, so any persona holding it keeps them regardless of this change — an **administrator smoke test would pass even if stage 1 had failed entirely**. The administrator is its only holder, so `junior.dhanani@usmandpeg.uat` (holds `DPEG_Junior_Analyst_PSG` + `Acquisition_Deal_Driver`, not the monolith) is the unmasked UAT persona. That safety net disappears at §6 retirement stage 5.

---

## 📋 Overview

### Original Request

> "Clean up the DPEG permission sets so there is no duplication and they follow best practice. Also add a missing 'Opportunity Stage Actions Access' permission set under the Acquisition module — there is one for Lead but not for Opportunity."

Two deliverables, nothing else in scope: add the missing Opportunity twin of `Lead_Stage_Actions_Access`, and remove duplication across the existing permission-set estate against a stated best-practice model. No new fields, objects, Apex, LWCs, validation rules, or personas — every change below is a rearrangement of grants that already exist, plus one new file.

### Business Objective

The org had grown four **monolithic** permission sets (`DPEG_Acquisitions`, `Acquisition_App_Access`, `Transaction_App_Access`, `Property_Management_Access`) left over from before the 2026-07-22 RBAC build, each duplicating grants that the split `DPEG_<Module>_Edit/View` sets introduced later — and a real gap: Lead had a dedicated stage-action capability set (`Lead_Stage_Actions_Access`), but Opportunity's four stage-action controllers were reachable only through the 28-class `DPEG_Apex_Access` catch-all, with no capability set of their own. Left alone, both problems compound: every new persona has to reason about which of several overlapping sets is authoritative, and a future permission-set edit risks silently duplicating or silently omitting a grant.

### Summary

This change (a) adds `Opportunity_Stage_Actions_Access`, a new layer-4 capability set carrying Apex invoke access to the four Opportunity/child-object stage-action controllers, joined to `DPEG_Junior_Analyst_PSG` only; (b) trims the two action-only classes those controllers replace out of `DPEG_Apex_Access` (28 → 26), while deliberately keeping two permission-question classes in both places; (c) documents, but does not yet execute, a five-stage retirement plan for the four monolithic sets plus one small redundant dashboard set; and (d) records the seven-layer permission-set model this repo now follows, in `ARCHITECTURE.md` §2, so future permission-set work has a standing structure to conform to instead of an implicit one to reverse-engineer.

---

## 🏗️ Components Created / Modified

This is a **metadata-only** change — no Apex, no LWC, no Flow, no validation rule. Per `CLAUDE.md`'s Complexity Routing Guide, it was routed to `salesforce-solution-architect` (permission-set-group strategy / org-wide security model), not `salesforce-admin`, and `salesforce-unit-testing` / `salesforce-code-review` / `salesforce-developer` / `salesforce-technical-architect` were all explicitly skipped in the design document — there is no code to test or review.

### New Permission Set

| API Name | Label | Layer | Grants |
| --- | --- | --- | --- |
| `Opportunity_Stage_Actions_Access` | Opportunity Stage Actions Access | 4 — Capability | 4 `classAccesses`, nothing else: `OpportunityActionPermissionController`, `StageAdvanceController`, `OpportunityApprovalController`, `RecordStageAdvanceController` |

No `fieldPermissions`, `objectPermissions`, `userPermissions`, `recordTypeVisibilities`, `tabSettings` or `applicationVisibilities` — every omission is deliberate and is argued in the file's own XML comment (see §5 below).

### Amended Permission Sets / Groups

| File | Change | Nature |
| --- | --- | --- |
| `DPEG_Apex_Access.permissionset-meta.xml` | Removed 2 `classAccesses`: `StageAdvanceController`, `OpportunityApprovalController`. 28 → 26 class grants. | Destructive (class-access only; must deploy **after** the additive half below) |
| `DPEG_Junior_Analyst_PSG.permissionsetgroup-meta.xml` | Added `Opportunity_Stage_Actions_Access` as a member. Now 12 member sets (was 11). | Additive |
| `Acquisition_Deal_Driver.permissionset-meta.xml` | XML-comment only. Zero grant change. Gained the same two-factor rationale its disposition twin (`Disposition_Deal_Driver`) already carried, so the acquisitions half no longer reads as the "trivial one-field set safe to fold away." | Additive (comment only) |

### Deferred (documented, not authored/deployed this pass)

Five sets are planned for retirement but **no destructive metadata has been written or deployed for any of them in this change**: `Acquisitions_Dashboard_Access`, `Acquisition_App_Access`, `Transaction_App_Access`, `Property_Management_Access`, `DPEG_Acquisitions`. See §6.

---

## 🔄 Data Flow — the two-factor gate

`OpportunityActionPermissionService.hasDealActionAccess()` (and its disposition twin,
`DispositionActionPermissionService`) requires two independent, separately-granted conditions to both
be true. This is the model `Opportunity_Stage_Actions_Access` and `Acquisition_Deal_Driver` implement,
and it is the single most important constraint on the new file — see `ARCHITECTURE.md` §2's
"Opportunity deal-action gate is TWO-FACTOR" subsection and the new "Permission Set Architecture"
subsection this change added directly below it.

```
        Layer 4 — CAPABILITY                       Layer 5 — AUTHORIZATION
   Opportunity_Stage_Actions_Access              Acquisition_Deal_Driver
   4x classAccesses (Apex invoke only)           1x fieldPermissions
                                                  (User.Deal_Driver__c, read-only)
              │                                            │
   (a) CAN the code be reached at all?          (b) IS this specific user
       -> Apex class access                         allowed?
                                                     -> WITH USER_MODE read of
                                                        Deal_Driver__c = true
              │                                            │
              └──────────────────┬─────────────────────────┘
                                  ▼
           OpportunityActionPermissionService.hasDealActionAccess()
                    returns true ONLY when BOTH (a) AND (b) hold
                                  │
                                  ▼
              lwc/dealActionGuard, lwc/recordStageGuard
              (permission check -> confirm -> act, per ARCHITECTURE.md §5)
```

**Why they cannot be merged:** if `Opportunity_Stage_Actions_Access` also carried the
`User.Deal_Driver__c` FLS, the gate would collapse from two factors to one for the whole population of
that set — membership would silently become authorization. `Acquisition_Deal_Driver` is deliberately
assigned **directly** rather than through a group, because its population (real deal drivers) is
narrower than any persona group. `OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied`
is the falsifier that pins this and was **not modified** by this change — it must stay green.

### Sequencing — the additive deploy is order-dependent

```
1. Deploy Opportunity_Stage_Actions_Access              (new file, purely additive)
2. Deploy DPEG_Junior_Analyst_PSG with the new member   (still ZERO effective access change —
                                                          DPEG_Apex_Access still grants the same
                                                          4 classes, and permission sets union)
3. WAIT for permission set group recalculation           (status must read "Updated")
4. VERIFY as a real deal driver (junior.dhanani)          — all 11 stage-action LWC bundles work
5. ONLY THEN deploy the trimmed DPEG_Apex_Access          (the destructive step — 28 -> 26 classes)
6. RE-VERIFY as the driver AND as a non-driver            — non-driver must see a clean denial
                                                             toast, never raw Apex-access text
```

Reversing steps 2 and 5 leaves every deal-driver stage button dead in the window between the two
deploys, because the new set is inert until the catch-all sheds the two action-only classes. This is
the one place in the whole change where order failure produces an immediate, live break.

---

## 📁 File Locations

| Component | Path |
| --- | --- |
| New capability set | `force-app/main/default/permissionsets/Opportunity_Stage_Actions_Access.permissionset-meta.xml` |
| Trimmed catch-all | `force-app/main/default/permissionsets/DPEG_Apex_Access.permissionset-meta.xml` |
| Amended group | `force-app/main/default/permissionsetgroups/DPEG_Junior_Analyst_PSG.permissionsetgroup-meta.xml` |
| Comment-only amendment | `force-app/main/default/permissionsets/Acquisition_Deal_Driver.permissionset-meta.xml` |
| Admin restoration set (referenced by §6, not yet deployed as part of this pass) | `force-app/main/default/permissionsets/DPEG_Admin_Access.permissionset-meta.xml` |
| Retirement staging manifests (authored, not run) | `manifest/permset-retirement/{1-acquisitions-dashboard-access,2-acquisition-app-access,3-transaction-app-access,4-property-management-access,5-dpeg-acquisitions}/` |
| Design source | `agent-output/design-requirements-permission-set-cleanup.md` |
| Runbook (self-contained, reproduces every measurement) | `docs/permission-set-retirement-runbook.md` |
| Architecture record (new convention, same PR) | `ARCHITECTURE.md` §2 — "Permission Set Architecture — the seven-layer model" |

---

## ⚙️ Configuration Details — the seven-layer model

`ARCHITECTURE.md` §2 now carries the full model this cleanup made explicit; this section is the
practical summary for anyone reading only this doc.

| # | Layer | Contains ONLY | This change touches |
| --- | --- | --- | --- |
| 1 | Base | license-level `userPermissions` | — |
| 2 | App visibility | `applicationVisibilities` + `tabSettings` | — (planned §6 stage 2) |
| 3 | Module data | object/field/record-type grants, one module, one access level | — |
| 3b | Module data, fine-grained | a deliberate subset of a layer-3 set | — (`DPEG_Opportunity_View` etc. are KEEP items, untouched) |
| 4 | Capability | `classAccesses` + platform `userPermissions` | ✅ new set added; ✅ `DPEG_Apex_Access` trimmed |
| 5 | Authorization flag | one `fieldPermissions` entry on `User.*` | ✅ `Acquisition_Deal_Driver` — comment only, zero grant change |
| 6 | Persona group | a `PermissionSetGroup` composing 1–5 | ✅ `DPEG_Junior_Analyst_PSG` — new member added |
| 7 | Profile restoration | tabs/FLS/apps/record types the profile grants but that don't deploy | referenced by §6 (planned), not deployed here |

**R-4, applied here:** `DPEG_Apex_Access` is a layer-4 violation by definition (it names no single
capability) but can never shrink to zero — two classes are structurally un-narrowable because Apex
class access is per-class, not per-method, and each holds a permission-**question** method a
non-authorized user must still be able to reach:

| Class | Removed from `DPEG_Apex_Access`? | Why |
| --- | --- | --- |
| `StageAdvanceController` | **Yes** | Action-only. All 4 calling bundles call `dealActionGuard.guardDealAction` first — a non-driver never reaches it. |
| `OpportunityApprovalController` | **Yes** | Action-only, identical reasoning (`submitForApproval` calls the same guard first). |
| `OpportunityActionPermissionController` | **No — kept in both files** | Holds the permission-question method `hasDealActionAccess()`. Its own class header states a non-driver must still be able to invoke it to receive a clean `false`. |
| `RecordStageAdvanceController` | **No — kept in both files** | Holds `hasStageActionAccess()` (the question) **and** `advance`/`advanceTo` (the actions) in one class. Class access is per-class, so it cannot be narrowed without losing the honest-`false` path for the actions too. |

The precedent for two classes deliberately living in both a capability set and the catch-all is not
new: `LeadActionPermissionController` has done exactly this in `Lead_Stage_Actions_Access` +
`DPEG_Apex_Access` since the original 2026-07-22 RBAC build.

### Correction found during design recon (measured, not estimated)

The initial brief undercounted the blast radius twice, both corrected before implementation:

1. **11 LWC bundles + 2 shared guard utils call the four controllers, not 9.** A repo-wide grep of
   `@salesforce/apex/{StageAdvanceController,OpportunityApprovalController,OpportunityActionPermissionController,RecordStageAdvanceController}`
   found `loiMarkCounterReceived` and `loiMarkCounteredByDpeg` were missing from the original list —
   both are in the blast radius of any `RecordStageAdvanceController` class-access change and are now
   on the UAT list (`docs/permission-set-retirement-runbook.md` §6).
2. **`DPEG_Apex_Access` sheds two classes, not four** — see the table above. The other two are
   structurally un-narrowable, per the class-access-is-per-class rule this change is the origin of in
   `ARCHITECTURE.md`.

---

## 🧪 Testing

No Apex or LWC was created or modified, so `salesforce-unit-testing` was explicitly skipped in the
design document, and there is nothing new for `salesforce-code-review` to review. One **existing** test
is the falsifier for the two-factor gate and must be run (not modified) after the additive deploy:

| Test | Purpose | Status |
| --- | --- | --- |
| `OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied` | Proves that holding `Opportunity_Stage_Actions_Access` without `Deal_Driver__c = true` still denies access — the falsifier for a collapsed two-factor gate | Must stay green; **not modified by this change**; not independently re-run by this documentation pass |

The acceptance test that actually matters for this change is **manual, in-org, and persona-based** —
see the sequencing diagram above and the UAT table in `docs/permission-set-retirement-runbook.md` §6.
An admin smoke test proves nothing about the deal-driver gate: a bare System Administrator has no FLS
on `User.Deal_Driver__c` either (Metadata-API-deployed custom fields arrive with no field permissions
for any profile), which is why the service checks Modify All Data before it reads the flag.

---

## 🔒 Security

- **Two-factor gate preserved, not created.** This change adds the capability half for Opportunity
  (mirroring Lead) and documents the model; it introduces no new authorization logic.
- **REPLACE-not-merge hazard applies to every existing file this change touches or that the retirement
  plan will touch.** `DPEG_Apex_Access`, `Acquisition_Deal_Driver`, `DPEG_Junior_Analyst_PSG` were all
  reconciled against `usman-dpeg` on 2026-08-10 before editing and came back with **zero org-only
  grants** for all three — safe to deploy as authored. The five sets targeted for retirement in §6 have
  **not** all been reconciled this way; the runbook makes reconciliation step A of every stage,
  non-optional.
- **Admin lockout is the single highest-consequence risk in the whole program, not this pass.** The
  admin user (`usman.khan.dpeg`) is the sole holder of all four monolithic sets and is in **no**
  permission set group; `profiles/**` is `.forceignore`d, so nothing in source restores admin access
  automatically if a set they depend on is deleted without first migrating them. This change does not
  delete anything, so it does not trigger this risk directly — but §6 exists specifically to sequence
  around it (GRANT → VERIFY → REMOVE → DELETE, never delete first).
- **No grant was added to any persona who does not have it today.** Per design constraint R-9, adding
  access is a change, not a cleanup, and returns to Gate 1 rather than being silently folded in here.

---

## 📝 Notes & Considerations

### Known Limitations / Deferred

- **The five staged retirements are documented but not executed.** See §6. Each has its own residual
  analysis, and three of the five (`Transaction_App_Access`, `Property_Management_Access`,
  `DPEG_Acquisitions`) carry unresolved residuals that require a decision before they can safely run —
  they are not a mechanical follow-up.
- **The `standard-Task` tab exists in exactly two permission-set files, both slated for retirement**
  (`Property_Management_Access`, `Transaction_App_Access`), and no `DPEG_App_*`, module, or
  `DPEG_Admin_Access` set currently carries it. This is the concrete proof, cited in `ARCHITECTURE.md`,
  that pairwise overlap counts do not prove coverage — retiring both sets without first re-homing this
  tab would remove the Tasks tab from the app with no deploy error and no failing test.
- **The Work Order write-access residual in `Property_Management_Access` is a policy question, not a
  gap to mechanically close.** `Work_Order__c` / `Work_Order_Activity__c` are a documented read-only
  Yardi mirror (`ARCHITECTURE.md` §1); the doomed set currently grants create/edit/delete on both.
  Retiring it as-is would *enforce* the documented contract rather than break something, but that is a
  decision for whoever runs stage 4, not an automatic consequence of this pass.
- **The name `Opportunity_Stage_Actions_Access` also carries a Disposition capability** — it grants
  `RecordStageAdvanceController`, which additionally serves the `Disposition_NDA` record type under a
  *different* gate (`DISPOSITION_DRIVER` / `User.Disposition_Driver__c`, not the Opportunity gate).
  This is harmless today because `DPEG_Junior_Analyst_PSG` is the one persona holding both
  `DPEG_Acquisition_Edit` and `DPEG_Disposition_Edit`, but it becomes a naming defect the moment a
  disposition-only persona is created. Accepted as requested at Gate 1; the file's own XML comment
  records the consequence so the next reader finds it before they find the surprise.

### Decision recorded — `Disposition_Dashboard_Access` is KEPT, not retired

`Disposition_Dashboard_Access` (12 `fieldPermissions`, read-mostly, on `BOV_Submission__c`,
`Disposition__c`, `Property_Asset__c`) is the structural sibling of `Acquisitions_Dashboard_Access` —
the one set **proven** fully redundant in this same pass — and was measured for exactly that reason.
**The result diverges from its sibling: it is NOT a full subset of either disposition module set.**

| Survivor union tested | Residual |
| --- | --- |
| `DPEG_Disposition_Edit` alone | 6 uncovered |
| `DPEG_Disposition_View` alone | 8 uncovered |
| `DPEG_Disposition_Edit` + `DPEG_PropertyAsset_View` | 3 uncovered |
| `DPEG_Disposition_Edit` + `DPEG_PropertyMgmt_Edit` | 0 — fully covered |

The gap is entirely six `Property_Asset__c` fields (`Argus_Value__c`, `Property_Name__c`,
`Property_Type__c`, `Readiness_Score__c`, `Sell_Readiness_Band__c`, `Sell_Readiness_Score__c`) — a
**Property Management** object that neither disposition module set fully covers, because the Sell
Meter reads across the module boundary. Closing that gap would mean either assigning a PM-module set
to a disposition persona (a widening) or moving six fields into `DPEG_Disposition_Edit` (a
schema-boundary decision) — both are decisions, not mechanical de-duplication, so **this pass keeps the
set and does not retire it.** Re-measure before acting on this later; `DPEG_Disposition_Edit` is heavily
repo-ahead-of-org, though a same-day control run computing the same residual from repo state returned
an identical answer, so the gap is not an artefact of org lag.

### Open item — the org holds metadata that is not in source

Reconciling `DPEG_Admin_Access` surfaced permission sets, a group and six record types that exist in
`usman-dpeg` but nowhere in this repository. They were built directly in the org and never brought
into source control. Two concrete consequences, both recorded:

1. `DPEG_Admin_Access` now references the six record types (to stop them being silently wiped by a
   future deploy of that file — see the reconciliation finding below). It deploys successfully to
   `usman-dpeg`, where the record types exist, and **will fail on all six if ever deployed to a fresh
   scratch org built from this repo alone.**
2. The deployed `DPEG_Principal_PSG` group carries a member the repo copy of that group does not list.
   Because a group deploy **replaces** its member list wholesale, deploying the repo copy would
   silently revoke that access for every principal. **No step in this change deploys
   `DPEG_Principal_PSG`** — but the risk is real for the next person who edits it for an unrelated
   reason without reconciling first.

Bringing the unsourced metadata into source is the correct long-term fix and is explicitly **out of
scope** for this cleanup. It is tracked here and in `docs/permission-set-retirement-runbook.md` §1.4 as
a standalone piece of future work.

### Reconciliation findings that nearly caused a third incident

`ARCHITECTURE.md` already documents two production incidents (2026-08-05, 2026-08-06) caused by a
`PermissionSet` deploy silently wiping an org-side-only grant. This cleanup's own reconciliation pass
caught a near-third **before** any deploy: `DPEG_Admin_Access` carried six `recordTypeVisibilities`
live in `usman-dpeg` and absent from the repo file — one day after a 2026-08-09 reconciliation of the
same file had recorded **zero** org-only grants. The lesson recorded in `ARCHITECTURE.md`: a past clean
reconciliation is a snapshot, not a standing guarantee — re-run it before every deploy of a permission
set, not just the first time. The six record types have been added to the repo file (see the Investor
Relations note above for the consequence of doing so).

### Dependencies

- Depends on the 2026-07-22 RBAC build (`docs/rbac-access-model-standard.md`) for the module Edit/View
  sets, app-visibility sets, and persona groups this cleanup rearranges grants among.
- Depends on `OpportunityActionPermissionService` / `RecordStageAdvanceController` /
  `DispositionActionPermissionService` (all documented in `ARCHITECTURE.md` §2) for the two-factor gate
  shape this change's capability/authorization split implements.
- The five staged retirements in §6 each depend on their own residual closure landing first — see the
  runbook for the per-stage dependency order.

---

## 🚧 Required Post-Deploy Manual Steps

**Assignment and permission-set-group membership are not deployable metadata.** Every step below has an
in-org half that a green `sf project deploy` does not perform and does not verify.

1. **Wait for `DPEG_Junior_Analyst_PSG` recalculation to reach `Updated`** after step 2 of the
   sequencing diagram, before running any verification.
2. **Verify as `junior.dhanani@usmandpeg.uat`** (a real deal driver) that all 11 stage-action LWC
   bundles work, both before and after `DPEG_Apex_Access` is trimmed.
3. **Verify as a non-driver** immediately after the trim: expect a clean denial toast. If the toast
   instead reads "You do not have access to the Apex class named …", the trim has gone too far and the
   removed class must be re-added to `DPEG_Apex_Access`.
4. **Run `OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied`**
   post-deploy and confirm it is still green.
5. **The five staged retirements in §6 are separate, future work** — each has its own GRANT → VERIFY →
   REMOVE → SOAK → DELETE sequence with mandatory in-org steps, fully enumerated in
   `docs/permission-set-retirement-runbook.md` §5 and its tear-off checklist in §10. None of them should
   be run as a consequence of this deploy landing.

---

## §6 Staged Retirement Plan (documented, not executed)

Five sets are slated for retirement, ordered smallest-blast-radius first. They are independent of one
another and may be run on separate schedules. Full detail, including the exact residual grant lists and
the reproducible measurement method, is in `docs/permission-set-retirement-runbook.md`.

| Stage | Set | Grants | Residual | Blocking prerequisite |
| --- | --- | --- | --- | --- |
| 1 | `Acquisitions_Dashboard_Access` | 3 | **0 — proven** | none; recommended as the rehearsal for the ordering discipline |
| 2 | `Acquisition_App_Access` | 4 | **0 — proven** | admin holds none of the four `DPEG_App_*` sets; the 4 `applicationVisibilities` must land in `DPEG_Admin_Access` (done, undeployed as part of this pass) and be verified before this set is unassigned |
| 3 | `Transaction_App_Access` | 56 | **15** | `standard-Task` tab re-homing; two service classes need verification, not assumption; two `allowDelete` rights need a decision |
| 4 | `Property_Management_Access` | 225 | **39** | holder is unmeasured as of this writing (a prior query window returned no assignment, which is not proof of none); `standard-Task` tab; the Work Order write-access policy decision |
| 5 | `DPEG_Acquisitions` | 459 | **59** | whether the admin holds `DPEG_Apex_Access` / `DPEG_Disposition_Edit` is unmeasured; largest blast radius, longest soak window, run last |

Every stage follows the same universal order: **RECONCILE → CLOSE RESIDUAL → GRANT → VERIFY IN-ORG →
REMOVE ASSIGNMENT → DELETE.** Deletion is irreversible in the org; there is no deprecate-and-relabel
phase (decided and declined at Gate 1) — the residual pass is the only thing standing between a missed
grant and an irreversible deletion.

---

## 📜 Change History

| Date | Author | Change Description |
| --- | --- | --- |
| 2026-08-10 | salesforce-solution-architect | Added `Opportunity_Stage_Actions_Access`; trimmed `DPEG_Apex_Access` 28 → 26; added the new set to `DPEG_Junior_Analyst_PSG`; added the two-factor rationale comment to `Acquisition_Deal_Driver`; authored (not executed) the five-stage retirement runbook and manifests |
| 2026-08-10 | Documentation Agent | Recorded the seven-layer permission-set model in `ARCHITECTURE.md` §2; wrote this feature doc |
