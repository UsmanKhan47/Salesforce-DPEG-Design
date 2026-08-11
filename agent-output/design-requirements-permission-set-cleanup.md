# DESIGN REQUIREMENTS — Permission Set Cleanup + `Opportunity_Stage_Actions_Access`

**Date:** 2026-08-10
**Branch:** `feature/stage-by-stage-alignment`
**Org of record:** `usman-dpeg` (00Diw000000Fqw1EAC)
**Design agent run:** requirements only. No metadata written, nothing deployed.

---

## 0. WHAT THE USER REQUESTED

> "Clean up the DPEG permission sets so there is no duplication and they follow best practice. Also add a missing 'Opportunity Stage Actions Access' permission set under the Acquisition module — there is one for Lead but not for Opportunity."

Two deliverables, and nothing else is in scope:

1. **ADD** one permission set — `Opportunity_Stage_Actions_Access`, the Opportunity twin of `Lead_Stage_Actions_Access`.
2. **REMOVE DUPLICATION** across the existing permission sets, against a stated best-practice model.

No new fields, no new objects, no Apex changes, no LWC changes, no validation rules, no new personas. Everything below is a rearrangement of grants that already exist, plus one new file.

---

## 0.1 EVIDENCE STATUS — read this before acting on any number

| Marker | Meaning |
| --- | --- |
| **[M]** | Measured directly (repo file read, or live-org query stated in the brief). Trust it. |
| **[D]** | Derived by arithmetic or logic from **[M]** facts. Sound, but re-verify before a destructive step. |
| **[U]** | **Unverified.** Stated as a question, never as a fact. Must be measured before it is acted on. |

---

## 0.2 TWO CORRECTIONS TO THE BRIEF

Both found during recon. Neither changes the shape of the request; both change the numbers, so they are stated up front rather than buried.

### Correction 1 — it is ELEVEN LWC bundles, not nine **[M]**

The brief lists 9 bundles calling the four controllers. A repo-wide grep of `@salesforce/apex/{StageAdvanceController,OpportunityApprovalController,OpportunityActionPermissionController,RecordStageAdvanceController}` finds **11 action bundles plus 2 shared guard utils**:

| Controller | Bundles that call it **[M]** |
| --- | --- |
| `StageAdvanceController` | `advanceDealStage`, `dealSendToDevelopmentReview`, `dealSendToConstructionReview`, `dealMoveToAboutToClose` (4) |
| `OpportunityApprovalController` | `submitForApproval` (1) |
| `RecordStageAdvanceController` | `advanceRecordStage`, `loiMarkCountered`, `loiMarkCompleted`, `ndaMarkDeclined`, **`loiMarkCounterReceived`**, **`loiMarkCounteredByDpeg`** (6) |
| `OpportunityActionPermissionController` | `dealActionGuard` (util, shared by the 5 Opportunity bundles) |
| `RecordStageAdvanceController.hasStageActionAccess` | `recordStageGuard` (util, shared by the 6 child-object bundles) |

The two the brief omits — `loiMarkCounterReceived` and `loiMarkCounteredByDpeg` — are in the blast radius of any change to `RecordStageAdvanceController` class access and must be on the UAT list.

### Correction 2 — the answer to "should `DPEG_Apex_Access` shed these four classes?" is **TWO, not four** **[M]**

Two of the four **cannot** be removed from the broad set, and the reason is written into the codebase already:

`OpportunityActionPermissionController.cls`, class header, verbatim **[M]**:

> "Granted in `DPEG_Apex_Access` (the broad Apex-invoke set every persona holds) as well as in `DPEG_Acquisitions`, rather than only in the deal-driver set. That is deliberate: a user who is NOT a deal driver must still be able to reach this method so it can honestly answer `false`. If class access were limited to the deal-driver personas, an unauthorized user's call would fail with an Apex access error rather than a clean denial."

And `RecordStageAdvanceController` is worse, because **Apex class access is per-CLASS, not per-method** **[M]** — that one class holds both the cacheable permission QUESTION (`hasStageActionAccess`, called by `recordStageGuard` for any user who clicks) and the ACTIONS (`advance` / `advanceTo`). It is structurally un-narrowable.

The consequence is confirmed by the two guard utils **[M]**: both `dealActionGuard.guardDealAction` and `recordStageGuard.guardStageAction` do

```js
} catch (error) {
    showError(cmp, messageFor(error, NO_PERMISSION_MESSAGE));   // messageFor -> error.body.message
    return false;
}
```

so a missing-class-access failure would put **raw platform text** ("You do not have access to the Apex class named…") into a user-facing toast — which ARCHITECTURE.md §5 forbids. The gate still fails closed, so this is a message-quality and diagnosability defect, not a security hole; but it is a regression, and it is avoidable.

**Result:** `DPEG_Apex_Access` sheds `StageAdvanceController` and `OpportunityApprovalController` only. See §3.6.

---

# 1. THE NEW PERMISSION SET — `Opportunity_Stage_Actions_Access`

## 1.1 Exact grants

**File:** `force-app/main/default/permissionsets/Opportunity_Stage_Actions_Access.permissionset-meta.xml`

| Element | Value |
| --- | --- |
| `<label>` | `Opportunity Stage Actions Access` |
| `<hasActivationRequired>` | `false` |
| `<classAccesses>` ×4 | `OpportunityActionPermissionController`, `StageAdvanceController`, `OpportunityApprovalController`, `RecordStageAdvanceController` — each `<enabled>true</enabled>` |
| `<fieldPermissions>` | **NONE. Deliberate. See §1.3.** |
| `<objectPermissions>` | **NONE. Deliberate. See §1.4.** |
| `<userPermissions>` | **NONE. Deliberate. See §1.5.** |
| `<recordTypeVisibilities>` | **NONE.** |
| `<tabSettings>` / `<applicationVisibilities>` | **NONE.** |

Four `classAccesses` and nothing else. That is the whole file.

## 1.2 `<description>` (≤255 chars — the platform cap)

```
Capability set for the Opportunity and child-object stage quick actions: Apex invoke access only.
It does NOT grant User.Deal_Driver__c FLS - that is Acquisition_Deal_Driver's job, and the gate is
two-factor. Assign with DPEG_Acquisition_Edit.
```

The full rationale exceeds 255 characters, so it goes in an **XML comment placed INSIDE the root element** — a comment above `<PermissionSet>` breaks `sf` at source conversion with the misleading error "unable to find matching parent xml file". Precedents in this repo: `Disposition_Deal_Driver`, `Broker_Protection_Access`, `DPEG_Admin_Access` **[M]**.

## 1.3 WHY NO `User.Deal_Driver__c` FLS — the two-factor separation (NON-NEGOTIABLE)

This is the single most important constraint on the new set.

`OpportunityActionPermissionService.hasDealActionAccess()` asks two independent questions **[M, ARCHITECTURE.md §2]**:

- **(a) CAPABILITY / membership** — can the user reach the code at all? Today: Apex class access.
- **(b) AUTHORIZATION / the flag** — FLS read on `User.Deal_Driver__c` (`WITH USER_MODE` in `UserSelector`; a denial THROWS and the service converts the throw to `false`) **AND** `Deal_Driver__c = true` on the running user's own User record.

`Acquisition_Deal_Driver` exists solely to carry (b). It contains exactly one grant **[M]**:

```xml
<fieldPermissions>
    <editable>false</editable>
    <field>User.Deal_Driver__c</field>
    <readable>true</readable>
</fieldPermissions>
```

**If the new set also granted that FLS, the gate would collapse from two factors to one for every holder of the new set.** A user holding the new set with `Deal_Driver__c = false` is denied today; with the FLS moved or copied in, the denial still holds (the flag is still false) — but the *separation* is gone, and the next reviewer who sees the FLS in the capability set will reasonably fold `Acquisition_Deal_Driver` into it, at which point membership silently becomes authorization. That is precisely the widening `Disposition_Deal_Driver`'s own XML comment was written to prevent **[M]**, and `OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied` is the falsifier that goes red **[M, per brief]**.

**The rule, to be stated verbatim in the new file's XML comment:**

> This set carries the CAPABILITY (invoke the controllers). `Acquisition_Deal_Driver` carries the AUTHORIZATION (`User.Deal_Driver__c` FLS). They are two factors of one gate and must never be merged, in either direction. Do not add a `fieldPermissions` entry for any `User.*` field to this file.

Same rule applies to `User.Disposition_Driver__c` / `Disposition_Deal_Driver`, which `RecordStageAdvanceController` reaches through the `Disposition_NDA` record type's gate **[M]**.

## 1.4 WHY NO `objectPermissions` — and why this DIFFERS from the Lead twin

`Lead_Stage_Actions_Access` carries three object grants — `Account` (C/R/E), `Contact` (C/R/E), `Lead` (R/E) **[M]**. Those are there because `Database.convertLead` writes to Account and Contact, targets the Lead module sets do not otherwise cover.

The Opportunity actions have no analogue. `DPEG_Acquisition_Edit` already grants object permissions on **Opportunity and all six stage-controlled child objects** **[M]** — measured object list: `Opportunity`, `Lead`, `Property__c`, `LOI__c`, `Counter_Offer__c`, `Underwriting__c`, `Development_Feasibility_Review__c`, `Construction_Feasibility_Review__c`, `Contract_Review__c`, `PSA_Version__c`, `Deal_Message__c`, `Offering__c`, `NDA__c`. A deal driver is on `DPEG_Junior_Analyst_PSG` → `DPEG_Acquisition_Edit`, so they already hold every object the actions touch.

Adding them here would create **exactly the duplication this whole exercise exists to remove.** Omitting them is not an oversight; it is the point.

## 1.5 WHY NO `userPermissions` and NO `fieldPermissions` for module fields

- **User permissions:** `Lead_Stage_Actions_Access` carries `ConvertLeads` (and `EditTask`) **[M]** because Lead conversion is gated by a platform user permission. Opportunity stage advance and Submit-for-Approval have no equivalent platform user permission. Nothing to grant.
- **Module FLS:** the fields the services read (`Opportunity.StageName`; each child's stage field — `Status__c` / `Stage__c` / `Negotiation_Status__c`; and `RecordTypeId`, which has no FLS at all) are all already in `DPEG_Acquisition_Edit`'s 286 field grants **[M]**. `RecordStageAdvanceService.load()` dispatches to each object's `selectStageRequiredById`, all `WITH USER_MODE` **[M, ARCHITECTURE.md §2]**, so those grants are load-bearing — but they live in the module data set, which is where they belong.
  **[U] Verification item V1:** confirm each of the six `selectStageRequiredById` methods selects no field absent from `DPEG_Acquisition_Edit` / `DPEG_Disposition_Edit`. A `USER_MODE` selector THROWS rather than degrades, so an ungranted field is a hard failure, not a blank. This is a read-only check the implementing agent must perform before the file is written.

## 1.6 Does it join `DPEG_Junior_Analyst_PSG`? — **YES**

**Decision: add `Opportunity_Stage_Actions_Access` to `DPEG_Junior_Analyst_PSG`, and to no other group.**

| Group | Join? | Reason |
| --- | --- | --- |
| `DPEG_Junior_Analyst_PSG` | ✅ **YES** | The only deal-driver persona. Already holds `Acquisition_Deal_Driver` (factor b) and `DPEG_Acquisition_Edit` (the data). The one measured non-admin holder of `Acquisition_Deal_Driver` is `junior.dhanani@usmandpeg.uat` **[M]**. |
| `DPEG_Principal_PSG` | ❌ NO | Principals APPROVE, they do not drive. They are read-only on Opportunity by design (ARCHITECTURE.md §2 — `DPEG Principal PSG` grants Read, not Edit, and that fact already caused the `ApprovalAuditService` `runInMode` incident) **[M]**. Granting them stage-action capability contradicts the persona. |
| `DPEG_Transaction_Team` | ❌ NO | Holds `DPEG_Opportunity_View` (read-only Opportunity), no acquisitions stage responsibility **[M]**. |
| `DPEG_Property_Management_Team` | ❌ NO | Out of module entirely **[M]**. |

**Sequencing point — the join and the catch-all trim are ONE change, not two.** While the four classes remain in `DPEG_Apex_Access` (which is in all four PSGs **[M]**), adding the new set to the Junior PSG grants **zero** additional effective access — permission sets union, so the classes are already reachable. The new set only becomes load-bearing the moment §3.6 removes the two action controllers from the catch-all. Therefore: **join first, verify, trim second.** Never the reverse.

## 1.7 Consequence to record, not to solve now: the name says "Opportunity", the set also covers Disposition

`RecordStageAdvanceController` serves the `Disposition_NDA` record type, which answers to `DISPOSITION_DRIVER` / `User.Disposition_Driver__c`, not to the Opportunity gate **[M, ARCHITECTURE.md §2 + the controller's own header]**. So a set named "Opportunity Stage Actions Access" also carries the capability for a disposition action.

That is harmless today because `DPEG_Junior_Analyst_PSG` is the single persona holding both `DPEG_Acquisition_Edit` and `DPEG_Disposition_Edit` **[M]**. It becomes a naming defect the day a disposition-only persona exists, who would then be assigned an "Opportunity" set to drive a sale.

**Recommendation: accept the name as requested, and record the consequence in the file's XML comment** so the next reader finds it. Splitting into two sets now would add a set to solve a problem nobody has, which is the opposite of this request. This is listed as **Open Question Q1** for Gate 1.

---

# 2. THE BEST-PRACTICE MODEL FOR THIS REPO

The result of this work must conform to the following. This model is **descriptive of what the split sets already do** — it is not a new invention. It is written down so the cleanup has a target and so a future reviewer can tell a deliberate structure from an accident.

## 2.1 Seven layers, one job each

| # | Layer | Contains ONLY | Examples **[M]** |
| --- | --- | --- | --- |
| 1 | **Base** | license-level `userPermissions` | `DPEG_Base_Access` (LightningExperienceUser) |
| 2 | **App visibility** | `applicationVisibilities` + `tabSettings` | `DPEG_App_Acquisition`, `_Disposition`, `_Transaction`, `_PropertyMgmt` |
| 3 | **Module data** | `objectPermissions` + `fieldPermissions` + `recordTypeVisibilities`, for ONE module at ONE access level | `DPEG_Acquisition_Edit` / `_View`, `DPEG_Disposition_Edit` / `_View`, `DPEG_PropertyMgmt_Edit` / `_View`, `DPEG_Transaction_Edit` / `_View`, `DPEG_Contact_Edit` / `_View` |
| 3b | **Module data, fine-grained building block** | as (3) but a deliberate SUBSET, existing so a persona can take one object without its whole module | `DPEG_Opportunity_View`, `DPEG_Property_View`, `DPEG_PropertyAsset_View`, `DPEG_Task_Edit`, `DPEG_TaskChecklist_View`, `DPEG_LeaseNotes_Create`, `DPEG_Reports_Access` |
| 4 | **Capability** | `classAccesses` + the platform `userPermissions` a named feature needs | `Lead_Stage_Actions_Access`, **`Opportunity_Stage_Actions_Access` (new)**, `Broker_Protection_Access` |
| 5 | **Authorization flag** | exactly ONE `fieldPermissions` entry on a `User.*` field, read by a two-factor gate | `Acquisition_Deal_Driver`, `Disposition_Deal_Driver` |
| 6 | **Persona group** | `PermissionSetGroup` composing layers 1–5 | `DPEG_Junior_Analyst_PSG`, `DPEG_Principal_PSG`, `DPEG_Transaction_Team`, `DPEG_Property_Management_Team` |
| 7 | **Profile restoration** | tabs / FLS / record types the profile grants but that never deploy | `DPEG_Admin_Access` — exists ONLY because `profiles/**` is `.forceignore`d |

## 2.2 The five rules that follow

**R-1 — One grant, one home.** Any given grant key (object+perms, object.field+perms, class, tab, app) belongs to exactly one layer. If it appears in two sets, one of them is the duplicate — **unless** it is on the KEEP list in §4.

**R-2 — Users are assigned GROUPS, not sets.** Exceptions, both deliberate: layer-5 flag sets and layer-4 capability sets may be assigned individually when their population is narrower than any group. Everything else that is assigned directly to a user is a symptom.

**R-3 — No monoliths.** A set that spans layers (objects + FLS + tabs + apps + Apex in one file) cannot be composed, cannot be reasoned about, and makes the REPLACE-on-deploy hazard (§5, R3) maximally dangerous. The four sets in §3 are the last of these.

**R-4 — `DPEG_Apex_Access` shrinks, but never to zero.** A 28-class catch-all is a layer-4 violation: it names no capability. The direction of travel is to shed classes into named capability sets. But two classes of Apex must stay broadly granted forever: **permission-QUESTION classes**, whose entire job is to answer `false` honestly for a user who is *not* authorized (§0.2 Correction 2). Any class containing a question method is un-narrowable, because class access is per-class.

**R-5 — Every set is reachable.** A set that is in no PSG and assigned to no user is dead weight and should be deleted, not left "in case". `Property_Management_Access` is the current suspect **[M: no assignment returned in the queried window]** — see §3.5.

## 2.3 How the current estate scores

| Verdict | Sets |
| --- | --- |
| ✅ Conformant | The 4 `DPEG_App_*`, the 8 module Edit/View, the 7 building blocks, the 2 flag sets, `DPEG_Base_Access`, `Lead_Stage_Actions_Access`, `Broker_Protection_Access`, `DPEG_Admin_Access` |
| ⚠ Conformant-with-exception | `DPEG_Apex_Access` — a catch-all, but partly irreducible per R-4 |
| ❌ Monolith, retire | `DPEG_Acquisitions`, `Acquisition_App_Access`, `Transaction_App_Access`, `Property_Management_Access` |
| ❌ Redundant, retire | `Acquisitions_Dashboard_Access` |
| ⬜ Out of scope, not measured | `Disposition_Dashboard_Access` **[U]** — see Q2 |
| ⬜ Managed / platform | `sfdcInternalInt__sfdc_scrt2`, `sfdcInternalInt__sfdc_nc_constraints_engine_deploy` — never touch |

---

# 3. DUPLICATION-ELIMINATION PLAN — the five sets

## 3.0 THE UNIVERSAL ORDER — apply to all five, no exceptions

```
STEP 1  COMPUTE THE RESIDUAL   grants in the doomed set that are NOT in the union of its replacements
STEP 2  CLOSE THE RESIDUAL     add those grants to the correct layer per §2.1 (usually DPEG_Admin_Access)
STEP 3  GRANT                  deploy replacements; assign them in-org to every current holder
STEP 4  VERIFY IN-ORG          log in AS each affected persona and exercise the feature
STEP 5  REMOVE ASSIGNMENT      only now unassign the doomed set (and remove it from any PSG)
STEP 6  SOAK                   leave the set deployed-but-unassigned for one agreed window
STEP 7  DELETE                 destructiveChanges the set
```

**Never delete first. Never skip step 1.** Steps 3 and 5 are in-org actions — `PermissionSetAssignment` is **not deployable metadata** **[M, ARCHITECTURE.md + repo history]** — so every one of these has a manual half that a green deploy will not perform and cannot verify.

### 3.0.1 STEP 1 IS THE STEP MOST LIKELY TO BE SKIPPED, AND IT HAS ALREADY CAUGHT A REAL GAP

**Pairwise overlap does NOT prove coverage.** The brief supplies pairwise overlaps for the four monoliths; those establish that a lot is duplicated, not that *everything* is. Only `Acquisitions_Dashboard_Access` was measured as a **full subset** **[M]**.

Worked example — this is real, found during recon **[M]**:

> A repo-wide grep for the `standard-Task` tab returns exactly two files: `Property_Management_Access` and `Transaction_App_Access`. **Both are on the retirement list.** No `DPEG_App_*` set, no module set, and not `DPEG_Admin_Access` carries it. Retiring both, as planned, would remove the Salesforce Tasks tab from the repo entirely — with no error, no failing test, and no deploy warning.

Residual arithmetic to be confirmed at implementation time **[D]**:

| Doomed set | FLS in file **[M]** | Overlaps claimed **[M]** | Approx. residual **[D]** |
| --- | --- | --- | --- |
| `DPEG_Acquisitions` | 392 | 266 (Acq_Edit) + 102 (Disp_Edit) + 8 (Admin) = 376 | **≈ 16 FLS**, plus any of its 20 objects / 14 tabs / 8 record types / 20 Apex not covered |
| `Transaction_App_Access` | 47 | 28 (Transaction_Edit) | **≈ 19 FLS** (the `Event.*` / `Task.*` block; partly covered by `DPEG_Task_Edit` = 11 and `DPEG_TaskChecklist_View` = 8) + `standard-Task` tab |
| `Property_Management_Access` | 189 | 109 (PM_Edit) + 84 (PM_View) = 193 — **exceeds 189, so the two overlap each other**; union is unknown | **must be computed, cannot be inferred** + `standard-Task` tab |
| `Acquisition_App_Access` | 0 | 4 apps, 100 % covered **[M]** | **0** — but see §3.1, the risk here is the ASSIGNMENT, not the residual |
| `Acquisitions_Dashboard_Access` | 3 | full subset of BOTH `DPEG_Acquisition_Edit` and `_View` **[M]** | **0 — proven** |

**Mandated method for step 1:** a set-difference computed from the deployed org state of both sides (not from the repo files, which may be ahead of the org — `DPEG_Admin_Access`'s own comment records that its Tranche 2/3A/3B content is repo-ahead-of-org **[M]**). Output a per-set residual list and get it approved before step 2.

---

## 3.1 `Acquisition_App_Access` — RETIRE (lowest risk, do it first)

| | |
| --- | --- |
| **What it is [M]** | 4 `applicationVisibilities` (Acquisition, Disposition, Transaction, Property_Management). Nothing else — no objects, no FLS, no tabs, no Apex. |
| **Why redundant [M]** | 100 % covered by `DPEG_App_Acquisition` + `_Disposition` + `_Transaction` + `_PropertyMgmt`. Its own `<description>` already documents its real purpose: *"Assign to full-license users (incl. admin, whose visibility is otherwise profile-only and profiles are not deployed)"*. |
| **Holder [M]** | `usman.khan.dpeg` (admin) ONLY. |
| **🔴 THE HAZARD** | The admin is **in no PSG** and holds **none** of the four `DPEG_App_*` sets **[M]**. Deleting this set removes the admin's visibility of all four Lightning apps. Since profiles do not deploy, nothing in the repo would restore it. |

**Migration**

1. **Residual:** zero **[M]**.
2. **Decide the admin's destination — this is Open Question Q3.** Two viable options:
   - **(a) RECOMMENDED — move the 4 `applicationVisibilities` into `DPEG_Admin_Access`.** That set exists for exactly this purpose ("Restores tab visibility and FLS the Admin profile granted (Profiles excluded from deployment, see .forceignore)" **[M]**) and already carries the admin's 33 tabs. App visibility is the one thing it is missing.
   - **(b) Assign the admin the four `DPEG_App_*` sets directly.** Correct by layer, but four in-org assignments that no deploy can perform or verify, repeated on every org rebuild.
   Option (a) makes the restoration deployable. Prefer it.
3. GRANT: deploy the amended `DPEG_Admin_Access`; assign it to the admin **[U] — verify the admin currently holds it; the brief's assignment list does not show it**.
4. VERIFY: as `usman.khan.dpeg`, open the App Launcher and confirm all four apps are visible.
5. REMOVE assignment → SOAK → DELETE.

**Rollback:** re-deploy `Acquisition_App_Access` from git and re-assign. Rollback is cheap up to step 7; after step 7 it is a git revert plus a re-deploy plus a re-assign.

---

## 3.2 `Acquisitions_Dashboard_Access` — RETIRE (only proven-zero-residual case)

| | |
| --- | --- |
| **What it is [M]** | 3 `fieldPermissions`, read-only: `NDA__c.Days_Out__c`, `Opportunity.Deal_Bucket__c`, `Underwriting__c.Verdict__c`. |
| **Why redundant [M]** | Measured as a **FULL SUBSET of BOTH** `DPEG_Acquisition_Edit` and `DPEG_Acquisition_View`. Every persona reaching an Acquisitions dashboard holds one of those two. |
| **Holder [M]** | `usman.khan.dpeg` (admin) ONLY. |

**Migration**

1. Residual: **zero, proven** — no step 2 needed.
2. GRANT: confirm the admin holds `DPEG_Acquisition_Edit` **[M — yes, the brief's assignment list shows it]**. Nothing to deploy.
3. VERIFY: as the admin, open the Acquisition Dashboard and confirm the three derived columns render (Underwriting Verdict, Deal Bucket, NDA Days Out).
4. REMOVE assignment → SOAK → DELETE.

**Rollback:** trivial — three FLS grants, re-deployable from git.

**This is the safest of the five. Run it second, as the rehearsal for the ordering discipline.**

---

## 3.3 `Transaction_App_Access` — RETIRE

| | |
| --- | --- |
| **What it is [M]** | 4 Apex classes (`TaskFanoutService`, `TaskRollupService`, `TransactionController`, `TransactionTaskController`), 47 FLS (Critical_Date + Event.* + Task.* + Transaction__c), 2 objects (`Critical_Date__c`, `Transaction__c`), 3 tabs (`Active_Transactions`, `Transaction__c`, **`standard-Task`**). A layer-spanning monolith. |
| **Replacements** | Objects/FLS → `DPEG_Transaction_Edit` (+ `DPEG_Task_Edit` / `DPEG_TaskChecklist_View` for the Task/Event block). Apex → `DPEG_Apex_Access` (holds `TransactionController` + `TransactionTaskController` **[M]**). Tabs/app → `DPEG_App_Transaction` (`Active_Transactions`, `Transaction__c` **[M]**). |
| **Holder [M]** | `usman.khan.dpeg` (admin) ONLY. |
| **🔴 KNOWN RESIDUALS [M]** | (i) **`standard-Task` tab** — after retiring this set AND `Property_Management_Access`, no set in the repo grants it. (ii) **`TaskFanoutService` and `TaskRollupService`** are NOT in `DPEG_Apex_Access` **[M]** — these are service classes invoked from a Flow / trigger, so class access may be irrelevant to their execution path, but that must be **verified, not assumed** **[U]**. (iii) ≈19 FLS unaccounted **[D]**. |

**Migration**

1. **Residual:** compute in full. Explicitly resolve (i), (ii), (iii) above.
2. **Close it:** `standard-Task` tab → `DPEG_Admin_Access` (admin restoration) **and** consider `DPEG_App_Transaction` + `DPEG_App_PropertyMgmt` for the personas — **[U] check whether the Transaction and PM personas can currently see the Tasks tab at all; if they cannot, this is a pre-existing gap and closing it is a CHANGE, which is out of scope and must be raised, not silently fixed.** Remaining FLS → `DPEG_Transaction_Edit` or `DPEG_Admin_Access` per layer.
3. GRANT + assign; 4. VERIFY as the admin AND as the Transaction Team persona — Active Transactions KPIs render, the Day-0 checklist tile shows "N / 75", Critical Dates list populates.
5. REMOVE → 6. SOAK → 7. DELETE.

**Rollback:** re-deploy + re-assign. Note the `DPEG_Transaction_Edit` edit is subject to the REPLACE hazard (§5 R3) — reconcile org→repo before deploying it.

---

## 3.4 `DPEG_Acquisitions` — RETIRE (largest, do it last)

| | |
| --- | --- |
| **What it is [M]** | 392 FLS, 20 objects, 20 Apex classes, 14 tabs, 8 record type visibilities. No `applicationVisibilities`. The original pre-split monolith. |
| **Replacements [M]** | FLS → `DPEG_Acquisition_Edit` (266 shared) + `DPEG_Disposition_Edit` (102 shared) + `DPEG_Admin_Access` (8 shared). Apex → `DPEG_Apex_Access` (20 shared). Tabs → `DPEG_Admin_Access` (14 shared — all 14 verified present). Record types → `DPEG_Admin_Access` (all 8 verified present, and it carries `Opportunity.Land` / `.Commercial` in addition). |
| **Holder [M]** | `usman.khan.dpeg` (admin) ONLY. |
| **🔴 HAZARD 1 — Apex class access.** | The admin's class access to these 20 controllers comes from `DPEG_Acquisitions` and/or their profile. **[U] The brief's assignment list does not show the admin holding `DPEG_Apex_Access`.** If they do not, retiring this set silently removes the admin's ability to invoke 20 LWC controllers, and the symptom is a raw-platform-text toast on every affected component. **Assign the admin `DPEG_Apex_Access` in step 3.** |
| **🔴 HAZARD 2 — Metadata-API FLS.** | The System Administrator profile grants object CRUD and Modify All Data, but **Metadata-API-deployed custom fields arrive with no field permissions for ANY profile, System Administrator included** **[M, ARCHITECTURE.md §2, paid for repeatedly on this project]**. So the 392 FLS grants are genuinely load-bearing for the admin — the profile does not silently cover them. |
| **HAZARD 3 — the residual.** | ≈16 FLS unaccounted by arithmetic **[D]**. Small, but they are by definition the fields NOT in any split set, i.e. the ones most likely to be invisible after retirement. |

**Migration**

1. **Residual:** compute exactly. Expect ~16 FLS plus any of the 20 objects not covered by `DPEG_Acquisition_Edit` ∪ `DPEG_Disposition_Edit` — note this set holds `Property_Asset__c`, `Unit__c`, `Rent_Step__c`, `Transaction__c`, `Wire__c`, `BOV_Submission__c`, `Broker_Listing__c`, `Disposition_Offer__c` **[M]**, several of which are Disposition/PM/Transaction objects and may fall outside both acquisitions sets.
2. **Close it:** residual FLS/objects → `DPEG_Admin_Access` (admin restoration layer) unless the residual belongs to a persona, in which case → that module's Edit/View set.
3. GRANT: assign the admin `DPEG_Apex_Access` **[U]** and `DPEG_Disposition_Edit` **[U]** if not already held; deploy the amended `DPEG_Admin_Access`.
4. **VERIFY — as the admin, and thoroughly.** Open one record of each of: Opportunity, LOI, NDA, Underwriting, Contract Review, Development FR, Construction FR, Disposition, Transaction, Property Asset. Confirm every field region renders, every record type is selectable in New, and every LWC on the page loads without an error toast.
5. REMOVE → 6. SOAK (longest window of the five — this is 454 grants) → 7. DELETE.

**Rollback:** re-deploy from git + re-assign. **[M]** `DPEG_Admin_Access`'s own comment records that `DPEG_Acquisitions`, `DPEG_Acquisition_Edit` and `DPEG_Acquisition_View` were reconciled field-by-field against the org on 2026-08-09 and **zero org-only grants were found** — so the repo copy of `DPEG_Acquisitions` is a trustworthy rollback source as of that date. Re-confirm before relying on it.

---

## 3.5 `Property_Management_Access` — RETIRE, but MEASURE FIRST

| | |
| --- | --- |
| **What it is [M]** | 7 Apex classes, 189 FLS, 15 objects, 12 tabs. Same monolith shape. |
| **Replacements [M]** | Objects: `DPEG_PropertyMgmt_Edit` (13) ∪ `DPEG_PropertyMgmt_View` (15) — **verified to cover all 15**, including the read-only `Work_Order__c` / `Work_Order_Activity__c` carve-out that only the View set has. Tabs: `DPEG_App_PropertyMgmt` (9 of 12) + `DPEG_Admin_Access` (`Broker_Scorecard`, `Lease__c`, `Work_Order__c`, `Work_Orders`, `Property_Asset__c`). |
| **Holder** | **[U] No assignment returned in the queried window.** |
| **🔴 KNOWN RESIDUALS [M]** | (i) **`standard-Task` tab** — the second of the only two files carrying it. (ii) Neither `DPEG_PropertyMgmt_Edit` nor `_View` carries ANY tab **[M]**, so all 12 tabs must be re-homed to layer 2 or 7. (iii) FLS union unknown — the 109 + 84 overlap figures sum to more than the file's 189, proving the two replacements overlap each other, so the union cannot be inferred. |

**Migration**

1. **CONFIRM THE HOLDER FIRST.** If the set is genuinely assigned to nobody, this becomes a pure deletion under R-5 and steps 3–5 collapse. **Do not assume — a permission set with no assignment in one query window is not the same as a permission set with no assignment.** Query `PermissionSetAssignment` for it explicitly, with no date scoping.
2. Residual: compute in full, especially the FLS union and the 12 tabs.
3. Close the residual → `DPEG_App_PropertyMgmt` (tabs belonging to the PM persona) or `DPEG_Admin_Access` (admin-only tabs).
4. GRANT + VERIFY as the PM Team persona: Onboarding checklist, Broker Assignments, Lease Activity Tracker, Lease Renewals, Work Orders (read-only), Rent Roll.
5. REMOVE → SOAK → DELETE.

**Rollback:** re-deploy + re-assign.

---

## 3.6 `DPEG_Apex_Access` — TRIM TWO CLASSES (not four)

Per §0.2 Correction 2.

| Class | Action | Reason |
| --- | --- | --- |
| `StageAdvanceController` | **REMOVE** from `DPEG_Apex_Access` | Action-only. Reachable only after `hasDealActionAccess()` has already returned true, so a non-driver never calls it **[M — all 4 bundles call `guardDealAction` first]**. |
| `OpportunityApprovalController` | **REMOVE** | Action-only, same reasoning **[M — `submitForApproval` calls `guardDealAction` first]**. |
| `OpportunityActionPermissionController` | **🔴 KEEP** | Permission-QUESTION class. Its own header states the requirement in writing. Removing it puts raw platform text in a toast for every non-driver who clicks. |
| `RecordStageAdvanceController` | **🔴 KEEP** | Contains the question (`hasStageActionAccess`) AND the actions (`advance`/`advanceTo`) in one class, and **Apex class access is per-class**. Structurally un-narrowable. |

All four are granted by the new capability set regardless. **A class appearing in both a capability set and the broad set is a DELIBERATE duplicate, not a defect** — `Lead_Stage_Actions_Access` already does exactly this with `LeadActionPermissionController` **[M]**, for exactly this reason. This is on the KEEP list (§4).

**Sequence (this is the one place where order failure produces an immediate live break):**

```
1. deploy Opportunity_Stage_Actions_Access                       (new file, additive, no risk)
2. deploy DPEG_Junior_Analyst_PSG with the new member            (still no effective change)
3. WAIT for permission set group recalculation to complete       (see §5 R5)
4. VERIFY as junior.dhanani@usmandpeg.uat — click every one of the 11 bundles
5. ONLY THEN remove the 2 classes from DPEG_Apex_Access          (destructive step)
6. RE-VERIFY as junior.dhanani, and as a NON-driver (expect the clean denial toast,
   NOT "You do not have access to the Apex class named ...")
```

Step 6's non-driver check is the one that catches a mistake in Correction 2. It must be run.

**Rollback:** re-add the two `classAccesses` to `DPEG_Apex_Access` and redeploy. Fast, but subject to §5 R3 — reconcile that file against the org first, because it carries an explicit REPLACE warning in its own XML comment **[M]**.

---

# 4. EXPLICIT KEEP LIST — do not "fix" these

Every entry below LOOKS like duplication and IS NOT. Each must be annotated in the file itself (XML comment) as part of this work, so the next reviewer finds the reason before they find the redundancy.

| # | Item | Looks like | Why it must stay |
| --- | --- | --- | --- |
| K1 | **`DPEG_Opportunity_View`** (64 grants) — subset of `DPEG_Acquisition_View` **[M]** | a redundant sub-set | The **Transaction team** needs Opportunity read WITHOUT the rest of Acquisitions **[M — `DPEG_Transaction_Team` composes it directly]**. Folding it in would grant that team LOI, NDA, Underwriting, Counter Offer, PSA Version and Deal Message. This is a layer-3b building block. |
| K2 | **`DPEG_Property_View`** (36) — subset of `DPEG_Acquisition_View` **[M]** | ditto | Same persona, same reason **[M — in `DPEG_Transaction_Team`]**. A transaction needs the property; it does not need the deal tree. |
| K3 | **`DPEG_PropertyAsset_View`** (18) — subset of `DPEG_PropertyMgmt_View` **[M]** | ditto | Lets a non-PM persona read the Property Asset (Sell Meter / Disposition surfaces) without the 15-object PM module. |
| K4 | **`Acquisition_Deal_Driver`** and **`Disposition_Deal_Driver`** — one `fieldPermissions` entry each **[M]** | trivial sets that "should be folded into the module Edit set" | They are **factor (b) of a two-factor gate** (§1.3). Folding either into a broad Edit set hands factor (a) to that set's whole population and leaves a one-factor gate. `Disposition_Deal_Driver`'s own 30-line XML comment already argues this **[M]**; `Acquisition_Deal_Driver` has only a one-line description and **should be given the equivalent comment as part of this work.** |
| K5 | **`LeadActionPermissionController` in BOTH `Lead_Stage_Actions_Access` and `DPEG_Apex_Access`** **[M]** | a duplicate class grant | Deliberate. A non-authorized user must be able to reach the permission-question method to receive a clean `false`. This is the established precedent that §3.6 follows. |
| K6 | **`OpportunityActionPermissionController` + `RecordStageAdvanceController` in BOTH the new set and `DPEG_Apex_Access`** | the same duplicate | Same reason as K5, stated in the new file's XML comment. **This is the specific thing a future "no duplication" pass will try to remove. It must be commented in both files.** |
| K7 | **`DPEG_Admin_Access`** as a whole | an admin-only oddity that duplicates other sets' tabs and FLS | It is layer 7 and exists only because `profiles/**` is `.forceignore`d. Its duplication with the persona sets is the mechanism, not a defect. |
| K8 | **`DPEG_PropertyMgmt_Edit` / `_View` overlapping on 13 of 15 objects** **[M]** | two sets covering the same objects | The View set carries the read-only carve-out (`Work_Order__c`, `Work_Order_Activity__c` — the Yardi mirror), which is why `DPEG_Property_Management_Team` composes **both** **[M]**. Merging them would make the read-only mirror editable. |
| K9 | `sfdcInternalInt__sfdc_scrt2`, `sfdcInternalInt__sfdc_nc_constraints_engine_deploy` | orphan sets | Platform-managed. Never edit, never delete. |

---

# 5. RISKS

## R1 — 🔴 ADMIN LOCKOUT (the highest-consequence risk here) **[M]**

`force-app/main/default/profiles/**` is `.forceignore`d and never deploys **[M]**. The admin `usman.khan.dpeg` is **in no permission set group** and holds **none** of `DPEG_App_Acquisition` / `_Disposition` / `_Transaction` / `_PropertyMgmt` **[M]**. All four doomed monoliths are assigned to the admin and **only** to the admin **[M]**.

Consequently, deleting any of them without migrating the admin first removes the admin's own access — apps (§3.1), object/FLS (§3.4, §3.5), tabs (§3.3, §3.4, §3.5), or Apex class access (§3.4).

**Mitigations, all mandatory:**
- The §3.0 seven-step order, with GRANT and VERIFY strictly before REMOVE and DELETE.
- `DPEG_Admin_Access` is the designated destination for anything profile-derived — that is literally its stated purpose **[M]**.
- A **soak window** between unassign and delete, so a missed grant surfaces as a complaint rather than as an unrecoverable deletion.
- **An admin smoke test proves the admin case and nothing else.** The reverse also holds. Both must be run.

## R2 — 🔴 THE `Acquisition_Deal_Driver` TWO-FACTOR GATE **[M]**

Detailed in §1.3. Three concrete failure shapes:
1. Putting `User.Deal_Driver__c` FLS in the new capability set → collapses two factors to one for its whole population, and `OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied` goes red.
2. "Tidying" `Acquisition_Deal_Driver` into `DPEG_Acquisition_Edit` because it is only one field → same collapse, larger population.
3. Deleting `Acquisition_Deal_Driver` as a "trivial set" → **every** deal driver is denied silently, because the `USER_MODE` read throws and the service converts the throw to `false`. **No error surfaces. The buttons just stop working.**

Also: **the "Modify All Data" bypass must run BEFORE the flag read** **[M, ARCHITECTURE.md §2]** — a bare System Administrator has no FLS on `User.Deal_Driver__c`, so an admin smoke test of this gate proves nothing. Acceptance-test as a real deal-driver persona.

## R3 — 🔴 A `PermissionSet` DEPLOY **REPLACES**, DOES NOT MERGE **[M — bit this project twice]**

A `PermissionSet` deploy overwrites the org's entire field-permission list for that set with exactly what the file declares. An org-side-only grant absent from the file is **silently wiped by the next deploy of that same file, even one made for an unrelated reason** — this happened to `Broker_Protection_Access` on 2026-08-05 and again on 2026-08-06, taking down inbound email routing with `Operation failed due to fields being inaccessible on Sobject Task` **[M, ARCHITECTURE.md §2 Standards]**.

**This plan edits `DPEG_Admin_Access`, `DPEG_Apex_Access`, `DPEG_Acquisition_Edit`, `DPEG_Transaction_Edit`, `DPEG_App_PropertyMgmt` and `DPEG_App_Transaction` — six existing, live sets.** Every one is exposed.

**Mandatory gate:** before deploying ANY existing permission set in this plan, **retrieve it from `usman-dpeg` and diff it against the repo copy.** Any org-only grant must be added to the file first. `DPEG_Apex_Access` already carries this warning in its own XML comment **[M]**; `DPEG_Admin_Access` records a field-by-field reconciliation performed 2026-08-09 that found zero org-only grants in four sets **[M]** — that is a good precedent to repeat, not a result to reuse without re-checking.

## R4 — RESIDUAL GAPS: pairwise overlap ≠ coverage **[M]**

See §3.0.1. One residual is already proven: **`standard-Task` disappears from the repo entirely** if `Transaction_App_Access` and `Property_Management_Access` are both retired without a step-1 residual pass. There will be others; ≈16 FLS on `DPEG_Acquisitions` and ≈19 on `Transaction_App_Access` are the arithmetic estimates **[D]**.

**A green deploy is not evidence of coverage.** A missing FLS grant produces a blank field region or a `USER_MODE` `QueryException` reported as "No such column" — never a deploy error.

## R5 — Permission set GROUP recalculation is asynchronous

Editing a set that belongs to a `PermissionSetGroup` puts the group into recalculation. Access is briefly inconsistent, and a verification step run during that window can produce a false negative (or, worse, a false positive). **After every group-affecting deploy, confirm the group's status is `Updated` before running the VERIFY step.** This applies to §3.6 step 3 specifically.

## R6 — Assignment is not deployable metadata **[M]**

`PermissionSetAssignment` and group membership are in-org actions. Every migration step in §3 has a manual half that a successful deploy neither performs nor verifies. **The DevOps hand-off must list the in-org actions explicitly as a checklist, not as a footnote.** This has been recorded as a repeat trap on this project.

## R7 — Deletion has prerequisites

A permission set cannot be deleted while it is assigned to any user or is a member of any permission set group. `destructiveChanges.xml` will fail, and it will fail *after* the constructive half of the same deploy has already applied. Order: unassign everywhere → remove from every PSG → soak → then delete.

## R8 — `Disposition_Dashboard_Access` is UNMEASURED **[U]**

It is the structural sibling of `Acquisitions_Dashboard_Access` (12 read-mostly FLS grants on BOV_Submission, Disposition, Property_Asset **[M]**) — the one set proven fully redundant. It was **not** in the measured overlap or subset analysis and is therefore **NOT in scope**. Flagged so it is neither silently retired nor silently forgotten. See Q2.

## R9 — Scope discipline

The temptation during this work will be to "also fix" adjacent things: grant a persona a tab they seem to be missing, tidy `Acquisition_Deal_Driver` away, merge the PM Edit/View pair. §4 exists to stop that. **Any grant that would be ADDED to a persona who does not have it today is a CHANGE, not a cleanup, and must come back to Gate 1.** §3.3 step 2 flags one live instance of this (the `standard-Task` tab for the Transaction/PM personas).

---

# 6. AGENT ROUTING

**Recommendation: `salesforce-solution-architect` for all of it. Not `salesforce-admin`.**

Per CLAUDE.md's Complexity Routing Guide, `salesforce-solution-architect` owns *"Define permission set group strategy across all profiles and roles"* and *"Design org-wide security model (OWD + sharing rules + FLS strategy across multiple objects)"* **[M]**. This work is:

- a multi-set security-model refactor spanning 11+ permission sets and 4 permission set groups;
- a staged migration with irreversible steps and a measured lockout hazard;
- a two-factor authorization boundary that must survive intact.

It is not "add a field". `salesforce-admin` is the wrong routing even for the single new file, because the new file's correctness is entirely about its relationship to `Acquisition_Deal_Driver` and `DPEG_Apex_Access` — i.e. it is a model decision wearing a one-file disguise.

**Workflow:**

```
Gate 1 (user confirms this document)
   └─> 🟤 salesforce-solution-architect   — all metadata authoring (new set, 6 amended sets,
                                            1 amended PSG, destructiveChanges) + the per-set
                                            residual computation
   └─> Gate 3 (deployment confirmation)
   └─> 🔴 salesforce-devops               — STAGED deploy, one stage per §3 sub-section, with
                                            the in-org assignment checklist (R6) and a human
                                            VERIFY gate between every GRANT and every REMOVE
   └─> 🔷 salesforce-documentation        — in parallel; ARCHITECTURE.md §2 needs the
                                            best-practice model from §2 added, per §6 of that doc
```

**Skipped, with reasons:**
- `salesforce-unit-testing` — **no Apex or LWC is created or modified.** Nothing to test.
- `salesforce-code-review` — no code changes. (The metadata is reviewed by the solution architect and at Gate 3.)
- `salesforce-developer` / `salesforce-technical-architect` — no programmatic work.

**One test consideration for the architect, though no test is being written:** `OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied` is the falsifier for R2 **[M, per brief]**. It must be *run* (it already exists) after the permission set changes land, and it must stay green. Do not modify it.

---

# 7. EXECUTION ORDER (dependencies only)

```
0.  RECONCILE org -> repo for all 6 existing sets to be edited            [R3 gate, blocking]
1.  RESOLVE Open Questions Q1-Q4 at Gate 1                                [blocking]
2.  CREATE Opportunity_Stage_Actions_Access                               [additive, no risk]
3.  ADD it to DPEG_Junior_Analyst_PSG -> wait for recalc -> VERIFY        [R5]
4.  TRIM 2 classes from DPEG_Apex_Access -> VERIFY driver AND non-driver  [depends on 3]
--- the additive half is complete; everything below is retirement ---
5.  RETIRE Acquisitions_Dashboard_Access   (zero residual — the rehearsal)
6.  RETIRE Acquisition_App_Access          (after DPEG_Admin_Access carries the 4 apps)
7.  RETIRE Transaction_App_Access          (after the standard-Task residual is closed)
8.  RETIRE Property_Management_Access      (after the holder question is answered)
9.  RETIRE DPEG_Acquisitions               (largest; longest soak; last)
10. UPDATE ARCHITECTURE.md with the §2 model                              [same PR, per §6]
```

Steps 5–9 are independent of one another and may be spaced out; each carries its own residual pass, its own verify, and its own soak. **Step 4 must not precede step 3. No retirement may precede its own step 1.**

---

# 8. OPEN QUESTIONS FOR GATE 1

These are decisions for the user, not blockers to the design. Each has a recommendation.

| # | Question | Recommendation |
| --- | --- | --- |
| **Q1** | The new set is named for Opportunity but also carries `RecordStageAdvanceController`, which serves the **Disposition** NDA path under a different persona gate (§1.7). Accept the name, rename to something module-neutral, or split into two capability sets? | **Accept `Opportunity_Stage_Actions_Access` as requested**, and record the consequence in the file's XML comment. One persona holds both modules today; splitting solves a problem nobody has. Revisit when a disposition-only persona exists. |
| **Q2** | `Disposition_Dashboard_Access` (12 FLS) is the structural sibling of the one set proven fully redundant, but was **not measured** (§R8). In scope or not? | **Out of scope for this pass.** Measure it as a follow-up. Do not retire an unmeasured set alongside measured ones. |
| **Q3** | For the admin's app visibility (§3.1): move the 4 `applicationVisibilities` into `DPEG_Admin_Access` (deployable, matches that set's stated purpose), or assign the admin the four `DPEG_App_*` sets directly (layer-pure, but four manual assignments per org rebuild)? | **Move them into `DPEG_Admin_Access`.** Restoration should be deployable. |
| **Q4** | DELETE the five sets, or DEPRECATE (unassign + relabel `[DEPRECATED]`) and delete later? And what is the soak window — days, or one release? | **Deprecate first, delete after one agreed soak window.** Deletion is irreversible in the org and the residual analysis, however careful, is an inference. |
| **Q5** | Does this execute against the live `usman-dpeg` org, or is it repo-only until a later release? | Needs a user answer — it determines whether §3's in-org steps run now or are handed off as a runbook. |

---

# 9. PROMPT FOR THE IMPLEMENTING AGENT

## 🟤 PROMPT FOR `salesforce-solution-architect`

```
Implement the permission set cleanup specified in
agent-output/design-requirements-permission-set-cleanup.md. Read that document in
full, plus ARCHITECTURE.md §2 (Standards — the WITH SYSTEM_MODE table, the
"Opportunity deal-action gate is TWO-FACTOR" block, and the permission-set REPLACE
warning) before writing any file.

SCOPE — exactly these, nothing else:

A. CREATE force-app/main/default/permissionsets/Opportunity_Stage_Actions_Access.permissionset-meta.xml
   - <label>Opportunity Stage Actions Access</label>
   - <hasActivationRequired>false</hasActivationRequired>
   - FOUR <classAccesses>, each enabled: OpportunityActionPermissionController,
     StageAdvanceController, OpportunityApprovalController, RecordStageAdvanceController
   - NO fieldPermissions, NO objectPermissions, NO userPermissions, NO tabs, NO apps,
     NO recordTypeVisibilities. Each omission is deliberate; see §1.3-§1.5.
   - <description> per §1.2 (must be <= 255 chars).
   - A long XML comment INSIDE the root element (a comment above <PermissionSet>
     breaks `sf` at source conversion) carrying: the two-factor capability/authorization
     separation (§1.3) and the explicit instruction never to add a User.* fieldPermission
     here; why there are no object permissions (§1.4); the KEEP note K6 (this set
     deliberately duplicates two class grants with DPEG_Apex_Access, so the honest-false
     path survives); and the Q1 naming consequence (§1.7). Precedent for the pattern:
     Disposition_Deal_Driver.permissionset-meta.xml.

B. ADD <permissionSets>Opportunity_Stage_Actions_Access</permissionSets> to
   DPEG_Junior_Analyst_PSG.permissionsetgroup-meta.xml. That group ONLY.

C. REMOVE exactly TWO <classAccesses> from DPEG_Apex_Access: StageAdvanceController and
   OpportunityApprovalController. DO NOT remove OpportunityActionPermissionController or
   RecordStageAdvanceController — both hold permission-QUESTION methods that a
   non-authorized user must be able to reach, and Apex class access is per-CLASS, not
   per-method. Add an XML comment at each removal site recording why the other two stayed.

D. ADD the equivalent two-factor XML comment to Acquisition_Deal_Driver (KEEP item K4) —
   it currently has only a one-line description while its disposition twin carries the
   full rationale. Do not change any grant in that file.

E. For EACH of the five sets in §3 (Acquisition_App_Access, Acquisitions_Dashboard_Access,
   Transaction_App_Access, Property_Management_Access, DPEG_Acquisitions), produce a
   RESIDUAL REPORT before proposing any deletion: the exact set of grants present in that
   set and absent from the union of its named replacements. Pairwise overlap counts do NOT
   prove coverage — one residual is already known and measured (the `standard-Task` tab
   exists ONLY in Property_Management_Access and Transaction_App_Access, both of which are
   on the retirement list). Compute from DEPLOYED ORG STATE, not from repo files, because
   several repo files are ahead of the org.
   Then close each residual by adding those grants to the correct layer per §2.1 —
   normally DPEG_Admin_Access for anything profile-derived.

F. Produce the STAGED DEPLOY + IN-ORG RUNBOOK for salesforce-devops, one stage per §3
   sub-section, each stage in the mandatory order:
     COMPUTE RESIDUAL -> CLOSE RESIDUAL -> GRANT -> VERIFY IN-ORG -> REMOVE ASSIGNMENT
     -> SOAK -> DELETE
   Assignment and PSG membership are NOT deployable metadata, so list every in-org action
   explicitly as its own checklist line.

HARD CONSTRAINTS:

1. NEVER grant User.Deal_Driver__c or User.Disposition_Driver__c FLS anywhere except
   Acquisition_Deal_Driver / Disposition_Deal_Driver respectively. Collapsing the
   two-factor gate turns membership into authorization.
   OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied
   must stay green; do not modify it.
2. A PermissionSet deploy REPLACES its entire fieldPermissions/classAccesses list. Before
   deploying ANY existing set, retrieve it from usman-dpeg and diff it against the repo
   copy; add any org-only grant to the file first. This has caused two production
   incidents on this project.
3. GRANT -> VERIFY -> REMOVE -> DELETE. Never delete first. The admin usman.khan.dpeg is
   in NO permission set group and is the ONLY holder of all four monoliths; profiles are
   .forceignore'd, so nothing restores their access automatically.
4. Do NOT touch the §4 KEEP list: DPEG_Opportunity_View, DPEG_Property_View,
   DPEG_PropertyAsset_View, Acquisition_Deal_Driver, Disposition_Deal_Driver, the
   deliberate duplicate class grants (K5/K6), DPEG_Admin_Access, the PropertyMgmt
   Edit/View pair, or the sfdcInternalInt__* sets.
5. Do NOT add a grant to any persona who does not have it today. That is a CHANGE, not a
   cleanup, and it returns to Gate 1. §3.3 step 2 flags one live instance.
6. Do NOT touch Disposition_Dashboard_Access — it was not measured and is out of scope.
7. Do NOT deploy. Produce metadata files, the residual reports, and the runbook only.
   Deployment is salesforce-devops's, behind Gate 3.

VERIFICATION ITEM to perform before writing file A (§1.5, V1): confirm that each of the
six `selectStageRequiredById` selector methods selects no field that is absent from
DPEG_Acquisition_Edit / DPEG_Disposition_Edit. Those queries are WITH USER_MODE, which
THROWS rather than degrades, so an ungranted field is a hard failure. If a gap exists,
report it — do not silently add FLS to the new capability set.
```

---

## APPENDIX — measured inventory used to build this document

| Source | What was read |
| --- | --- |
| Repo **[M]** | All 36 files in `force-app/main/default/permissionsets/`; all 4 files in `force-app/main/default/permissionsetgroups/` |
| Repo **[M]** | `StageAdvanceController.cls`, `OpportunityActionPermissionController.cls`, `RecordStageAdvanceController.cls`, `OpportunityApprovalController.cls` (headers + method bodies) |
| Repo **[M]** | `lwc/dealActionGuard/dealActionGuard.js`, `lwc/recordStageGuard/recordStageGuard.js` |
| Repo **[M]** | Grep of `@salesforce/apex/{the four controllers}` across `lwc/` → 11 bundles + 2 guards |
| Repo **[M]** | Grep of `<field>` across all permission sets → per-set FLS counts |
| Repo **[M]** | Grep of `standard-Task`, `Broker_Scorecard`, `Work_Orders`, `Lease__c`, `Property_Asset__c` tabs across all permission sets |
| Doc **[M]** | `CLAUDE.md` (routing, gates); `ARCHITECTURE.md` §2 (two-factor gate, REPLACE hazard, USER_MODE semantics), §5 (guard utils, error handling) |
| Brief **[M]** | Live-org `PermissionSetAssignment` query results; pairwise overlap analysis; whole-set subset analysis |
