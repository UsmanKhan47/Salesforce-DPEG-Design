# Permission Set Retirement Runbook

**Written:** 2026-08-10 · **Org of record:** `usman-dpeg` (00Diw000000Fqw1EAC) · **Branch:** `feature/stage-by-stage-alignment`

**This document is self-contained.** You do not need to read the design document to run it. Everything measured is reproduced here, including the commands used to measure it, so you can re-measure rather than trust a number that may have aged.

---

## 0. WHAT THIS IS, AND WHAT IT IS NOT

Five permission sets are to be **deleted outright**. There is no deprecate-and-relabel phase — that was decided and declined. **Deletion is irreversible in the org**, and rollback after deletion means a git revert plus a re-deploy plus a re-assign.

Because there is no soak-by-deprecation, **the residual pass in §4 is the only thing standing between a missed grant and an irreversible deletion.** Do not skip it, and do not accept "the counts overlap" as proof. That reasoning has already been falsified once on this very work — see the `standard-Task` finding in §3.

**The additive half of this change is NOT in this runbook.** It is a separate, live deploy handled by `salesforce-devops`. See §2 for the exact file split.

### The five sets

| Stage | Set | Size | Holder (as measured) | Destructive manifest |
| --- | --- | --- | --- | --- |
| 1 | `Acquisitions_Dashboard_Access` | 3 grants | admin only | `manifest/permset-retirement/1-acquisitions-dashboard-access/` |
| 2 | `Acquisition_App_Access` | 4 grants | admin only | `manifest/permset-retirement/2-acquisition-app-access/` |
| 3 | `Transaction_App_Access` | 56 grants | admin only | `manifest/permset-retirement/3-transaction-app-access/` |
| 4 | `Property_Management_Access` | 225 grants | **UNKNOWN — must be measured** | `manifest/permset-retirement/4-property-management-access/` |
| 5 | `DPEG_Acquisitions` | 459 grants | admin only | `manifest/permset-retirement/5-dpeg-acquisitions/` |

Stages are ordered smallest-blast-radius first. **They are independent of each other** — you may run stage 1 today and stage 5 next quarter, or stop after any stage. You may not reorder the steps *within* a stage.

### The universal order, in every stage, without exception

```
  STEP A   RECONCILE org -> repo for every existing set this stage edits   (blocking)
  STEP B   CLOSE THE RESIDUAL  - add the uncovered grants to a surviving set
  STEP C   GRANT               - deploy the amended sets, then ASSIGN them in-org
  STEP D   VERIFY IN-ORG       - log in as each affected persona and exercise the feature
  STEP E   REMOVE ASSIGNMENT   - unassign the doomed set; remove it from every group
  STEP F   DELETE              - run the destructive manifest
```

**Never delete first. Steps C and E are in-org actions that no deploy performs and no deploy verifies** — `PermissionSetAssignment` and group membership are not deployable metadata.

---

## 1. THE FOUR THINGS THAT WILL BITE YOU

Read these before touching anything. Each is measured, not anticipated.

### 1.1 🔴 A `PermissionSet` deploy REPLACES its grant list. It does not merge.

Deploying a permission set overwrites the org's entire grant list for that set with exactly what the file declares. Any grant that exists in the org but not in the file is **silently destroyed** — no error, no warning, no failing test. This has caused two production incidents on this project (2026-08-05 and 2026-08-06, Broker Protection).

**It very nearly caused a third one during this work.** `DPEG_Admin_Access` held **six `recordTypeVisibilities` in the org that were absent from the repo file**:

```
Account.Broker_Firm       Contact.Broker      Lead.Acquisition_Broker
Account.Investor_Entity   Contact.Investor    Lead.IR_Investor
```

They have been reconciled into the repo file. **The lesson is the general one: run step A every time.** The file's own comment records a field-by-field reconciliation done on 2026-08-09 that found zero org-only grants — and one day later there were six. A past clean reconciliation is not a standing guarantee.

**How to run step A (the reconcile):**

```bash
# 1. Retrieve into a SCRATCH directory. NEVER retrieve over the repo file - that overwrites
#    the very thing you are trying to diff.
mkdir -p /tmp/psdiff
sf project retrieve start \
    --metadata "PermissionSet" --metadata "PermissionSetGroup" \
    --target-org usman-dpeg \
    --target-metadata-dir /tmp/psdiff --unzip --wait 20

# 2. Diff. A raw `diff` is USELESS here - MDAPI and source format order and serialize
#    differently. Normalize to one sorted line per grant first. The analyzer used for the
#    measurements in this document is reproduced in Appendix B.
```

Two normalization traps, both of which produce a **wrong answer**:

- **False positive** — a line-based normalizer breaks on inter-tag whitespace. A file with `</fieldPermissions>    <fieldPermissions>` on one line makes an awk/grep normalizer swallow the preceding grant, which then reads as "org-only", i.e. as a live grant about to be destroyed. Collapse whitespace first, or use a real XML parser.
- **False negative noise** — MDAPI emits `<viewAllFields>false</viewAllFields>` explicitly where source format omits it. Semantically identical. Filter it out or every object permission on both sides reads as differing, burying the real finding.

**An empty or failed retrieve is NOT evidence that a set is absent from the org.** Re-run it. A previous round on this project promoted "the retrieve returned nothing" into a permanent written claim, and re-running one day later returned both sets.

### 1.2 🔴 `standard-Task` exists in exactly two files repo-wide, and both are being deleted

```bash
grep -rl 'standard-Task' force-app/main/default/permissionsets/
#   Property_Management_Access.permissionset-meta.xml
#   Transaction_App_Access.permissionset-meta.xml
```

Confirmed identically in the org retrieve. **No `DPEG_App_*` set, no module set, and not `DPEG_Admin_Access` carries it.** Running stages 3 and 4 without closing this removes the Salesforce Tasks tab from the repo entirely — with no error, no failing test and no deploy warning.

This is the concrete proof that overlap counts do not prove coverage. It is a **blocking prerequisite** of both stage 3 and stage 4 (see §5.3 step B and §5.4 step B).

⚠ It also appears in `force-app/main/default/profiles/**`, including `Admin.profile-meta.xml`. **Do not treat that as cover.** `profiles/**` is `.forceignore`d, never deploys and never reconciles, so the repo copy is unverified against the org. Measure the tab in-org as the affected persona; do not infer it from a profile file.

### 1.3 🔴 The admin is in no permission set group, and profiles do not deploy

`usman.khan.dpeg` is the sole holder of four of the five doomed sets and is **in no PSG**, holding **none** of `DPEG_App_Acquisition` / `_Disposition` / `_Transaction` / `_PropertyMgmt`. Because `force-app/main/default/profiles/**` is `.forceignore`d and never deploys, **nothing in source restores the admin's access if you delete a set they depend on.**

This is why every stage is GRANT → VERIFY → REMOVE → DELETE, and why `DPEG_Admin_Access` is the designated destination for anything profile-derived: it makes the restoration deployable.

⚠ **An admin smoke test proves the admin case and nothing else. The reverse also holds.** Both directions must be run where a stage touches both.

### 1.4 ⚠ `DPEG_Admin_Access` now depends on org metadata that is not in this repo

The six record types reconciled in at §1.1 **exist in `usman-dpeg` but have no `recordType-meta.xml` in this repo**. More broadly, the org contains permission sets, groups and record types that were built directly in `usman-dpeg` and never brought into source.

- Deploying `DPEG_Admin_Access` **to `usman-dpeg` succeeds**, because the record types are present there.
- Deploying it **to a fresh scratch org built from this repo alone will FAIL** on all six.

The alternative — leaving them out of the file — guarantees a silent wipe on the org that actually matters, which is strictly worse. Bringing the unsourced metadata into source is the real fix and is **out of this change's scope**. Raise it as its own piece of work.

**Related and more dangerous, not fixed here:** the deployed `DPEG_Principal_PSG` carries a member the repo copy of that group does **not** list. Because a group deploy replaces its member list wholesale, deploying the repo copy would silently revoke that access for every principal. **No step in this runbook deploys `DPEG_Principal_PSG`** — but anyone who does, for any reason, must reconcile it first.

---

## 2. FILE SPLIT — ADDITIVE DEPLOY vs THIS RUNBOOK

`salesforce-devops` deploys **only the additive list.** Nothing in the runbook list goes out with it.

### 2.1 ADDITIVE DEPLOY — deploy now, in this order

| # | File | Change | Risk |
| --- | --- | --- | --- |
| 1 | `force-app/main/default/permissionsets/Opportunity_Stage_Actions_Access.permissionset-meta.xml` | **NEW.** 4 `classAccesses`, nothing else. | None — purely additive, new file. |
| 2 | `force-app/main/default/permissionsetgroups/DPEG_Junior_Analyst_PSG.permissionsetgroup-meta.xml` | Adds the new set as a member. | None — reconciled, zero drift. Grants no NEW effective access while (3) is pending. |
| 3 | `force-app/main/default/permissionsets/DPEG_Apex_Access.permissionset-meta.xml` | Removes `StageAdvanceController` + `OpportunityApprovalController` (28 → 26 class grants). | **Destructive. Must go LAST**, after 1+2 are deployed, the group has recalculated, and VERIFY has passed. |
| 4 | `force-app/main/default/permissionsets/Acquisition_Deal_Driver.permissionset-meta.xml` | **XML comment only. Zero grant change.** | None — reconciled, zero drift. May ride with (1) or (2). |

**Reconcile status for the additive deploy, measured 2026-08-10:**

| Set | Org grants | Repo grants | Org-only (would be wiped) | Verdict |
| --- | --- | --- | --- | --- |
| `DPEG_Apex_Access` | 28 | 28 → 26 | **0** | Safe to deploy |
| `Acquisition_Deal_Driver` | 1 | 1 | **0** | Safe to deploy |
| `DPEG_Junior_Analyst_PSG` | 11 members | 11 → 12 | **0** | Safe to deploy |

⚠ Re-run the reconcile at deploy time regardless. It is cheap and §1.1 is why.

**Sequencing for the additive deploy — the one place where order failure breaks live buttons:**

```
1. Deploy Opportunity_Stage_Actions_Access                    (additive, no risk)
2. Deploy DPEG_Junior_Analyst_PSG with the new member         (still zero effective change)
3. WAIT for permission set GROUP RECALCULATION to finish      (status must read "Updated")
4. VERIFY as junior.dhanani@usmandpeg.uat - click all 11 bundles in §6
5. ONLY THEN deploy the trimmed DPEG_Apex_Access              (the destructive step)
6. RE-VERIFY as junior.dhanani AND as a NON-driver
```

Step 6's non-driver check is the one that catches an error in the reasoning behind the trim. **It must be run.** Expected result for a non-driver: a clean denial toast — *not* "You do not have access to the Apex class named …".

Why the order: while the four classes remain in `DPEG_Apex_Access` (which is in all four PSGs), adding the new set grants **zero** additional effective access, because permission sets union. The new set only becomes load-bearing at the moment the catch-all sheds the two action controllers. Reversing steps 2 and 5 leaves every deal-driver stage button dead in the window between the two deploys.

**Post-deploy test:** `OpportunityActionPermissionServiceTest.hasDealActionAccess_membershipWithoutTheFlag_isStillDenied` must be run and must stay green. **Do not modify it** — it is the falsifier for the two-factor gate.

### 2.2 RUNBOOK ONLY — do NOT include in the additive deploy

| File | Used by | Why it is not in the additive deploy |
| --- | --- | --- |
| `force-app/main/default/permissionsets/DPEG_Admin_Access.permissionset-meta.xml` | Stage 2 (and referenced by 3/4/5) | Gains the four `applicationVisibilities` + six reconciled record types. Only matters once `Acquisition_App_Access` is going. Carries the §1.4 org-dependency. |
| `manifest/permset-retirement/1-acquisitions-dashboard-access/` | Stage 1 | Deletion. |
| `manifest/permset-retirement/2-acquisition-app-access/` | Stage 2 | Deletion. |
| `manifest/permset-retirement/3-transaction-app-access/` | Stage 3 | Deletion. |
| `manifest/permset-retirement/4-property-management-access/` | Stage 4 | Deletion. |
| `manifest/permset-retirement/5-dpeg-acquisitions/` | Stage 5 | Deletion. |
| *(not yet authored)* residual-closing edits to `DPEG_Transaction_Edit`, `DPEG_PropertyMgmt_*`, `DPEG_Task_Edit`, `DPEG_App_*` | Stages 3/4/5 step B | Each stage's step B decides these — see §4, several are **policy decisions**, not mechanical copies. |

---

## 3. THE MEASUREMENT METHOD

Every number below was produced on **2026-08-10** by retrieving all 40 permission sets and 15 permission set groups from `usman-dpeg` into a scratch directory and normalizing both sides into one canonical line per grant with a real XML parser. Appendix B reproduces the analyzer.

**Residuals were computed from DEPLOYED ORG STATE, not from repo files** — several repo files are ahead of the org (`DPEG_Disposition_Edit` is 90 KB in repo vs 24 KB in org) and computing from repo would claim coverage from grants that are not deployed.

**A control was run:** the same residuals computed from repo state came out **identical** (`DPEG_Acquisitions` 77, `Disposition_Dashboard_Access` 6 against the same survivor lists). So none of the residuals below is an artefact of org lag — the undeployed tranches close none of them.

**Coverage rule used:** a grant is covered when a surviving set grants **at least the same strength** on the same key — `readable`/`editable` for FLS, all six CRUD flags for objects, `enabled` for classes, and `Visible > Available > None` for tabs. This is why several "same object, same field" pairs still appear as residual: the doomed set grants `editable` where the survivor grants read-only.

---

## 4. RESIDUAL ANALYSIS — every grant, and the set that covers it

### 4.1 Summary

| Set | Total grants | Covered | **Residual** | Blocking issues |
| --- | --- | --- | --- | --- |
| `Acquisitions_Dashboard_Access` | 3 | 3 | **0 — proven** | none |
| `Acquisition_App_Access` | 4 | 4 | **0 — proven** | admin holds no `DPEG_App_*` set |
| `Transaction_App_Access` | 56 | 41 | **15** | `standard-Task`; 2 service classes; `allowDelete` |
| `Property_Management_Access` | 225 | 186 | **39** | `standard-Task`; Work Order edit-vs-read-only is a POLICY question |
| `DPEG_Acquisitions` | 459 | 400 | **59** | admin's `DPEG_Apex_Access` holding is UNMEASURED |

### 4.2 `Acquisitions_Dashboard_Access` — residual 0, proven

| Grant | Covered by |
| --- | --- |
| `NDA__c.Days_Out__c` (r) | `DPEG_Acquisition_Edit` **and** `DPEG_Acquisition_View` |
| `Opportunity.Deal_Bucket__c` (r) | `DPEG_Acquisition_Edit` **and** `DPEG_Acquisition_View` |
| `Underwriting__c.Verdict__c` (r) | `DPEG_Acquisition_Edit` **and** `DPEG_Acquisition_View` |

All three are covered by **both** sets independently, so any persona reaching an Acquisitions dashboard is covered whichever one they hold. **This is the only fully-proven-zero case among the five. Run it first, as the rehearsal for the ordering discipline.**

### 4.3 `Acquisition_App_Access` — residual 0, but the risk is the ASSIGNMENT

| Grant | Covered by |
| --- | --- |
| `applicationVisibilities` `Acquisition` | `DPEG_App_Acquisition` |
| `applicationVisibilities` `Disposition` | `DPEG_App_Disposition` |
| `applicationVisibilities` `Transaction` | `DPEG_App_Transaction` |
| `applicationVisibilities` `Property_Management` | `DPEG_App_PropertyMgmt` |

🔴 **Coverage by a set the holder does not hold is not coverage.** The admin holds **none** of those four sets and is in no group. That is precisely why the four grants were moved into `DPEG_Admin_Access` (already done in the repo file) rather than left to the `DPEG_App_*` sets.

### 4.4 `Transaction_App_Access` — residual 15

**Covered (41):** 23 by `DPEG_Transaction_Edit` alone · 6 by `DPEG_Transaction_Edit` + `DPEG_Transaction_View` · 8 by `DPEG_Task_Edit` · 2 by `DPEG_Apex_Access` (`TransactionController`, `TransactionTaskController`) · 2 by `DPEG_App_Transaction` + `DPEG_Admin_Access` (`Active_Transactions`, `Transaction__c` tabs).

**Residual (15) — each needs a decision at step B:**

| # | Grant | Nature | Recommended destination |
| --- | --- | --- | --- |
| 1 | `tabSettings` **`standard-Task`** (Visible) | §1.2 blocking | `DPEG_Admin_Access`. Whether the Transaction/PM **personas** also need it is a **CHANGE, not a cleanup** — see §4.4.1. |
| 2 | `classAccesses` `TaskFanoutService` | service class, not a controller | **Verify before adding.** Invoked from a Flow / trigger, so class access may be irrelevant to its execution path. Do not add it "to be safe" — measure. |
| 3 | `classAccesses` `TaskRollupService` | same | same |
| 4–8 | `Event.Conditional__c` (r+e), `Event.Task_Group__c` (e), `Event.Task_Owner_Label__c` (e), `Event.Task_Sequence__c` (e), `Event.Transaction_Deal__c` (e) | Event half of the Day-0 checklist field block | `DPEG_Task_Edit` if the Transaction persona edits Events; otherwise `DPEG_Admin_Access` |
| 9–13 | `Task.Conditional__c` (r+e), `Task.Task_Group__c` (e), `Task.Task_Owner_Label__c` (e), `Task.Task_Sequence__c` (e), `Task.Transaction_Deal__c` (e) | Task half — note `DPEG_Task_Edit`/`DPEG_TaskChecklist_View` cover these **read-only**; the `editable` bit is what is missing | `DPEG_Task_Edit` |
| 14 | `objectPermissions` `Critical_Date__c` → `allowDelete` | delete right only | See §4.4.2 |
| 15 | `objectPermissions` `Transaction__c` → `allowDelete` | delete right only | See §4.4.2 |

#### 4.4.1 The `standard-Task` persona question is a CHANGE, not a cleanup

Whether the Transaction and Property Management personas can see the Tasks tab **today** has not been measured. If they cannot, granting it now would be **adding access nobody has**, which is out of scope for a cleanup and must go back for a decision — not be quietly fixed. **Measure first:**

```bash
sf org login web --instance-url https://usmandpegorg.my.salesforce.com   # as the persona
# then: App Launcher -> search "Tasks". Or check Setup > Permission Sets for any set
# granting the tab to a set that persona actually holds.
```

Restoring the tab for the **admin** via `DPEG_Admin_Access` is a restoration, not a change, and is in scope.

#### 4.4.2 `allowDelete` — a removal, and removals need a decision too

The doomed set grants `allowDelete` on `Critical_Date__c` and `Transaction__c`; `DPEG_Transaction_Edit` does not. Retiring the set therefore **removes a delete right the admin holds today**. The admin's profile may confer Modify All Data independently — but `profiles/**` never deploys, so that is unverifiable from source and must be checked in-org. Decide explicitly: restore it in `DPEG_Admin_Access`, or accept the tightening and record that you did.

### 4.5 `Property_Management_Access` — residual 39

**Covered (186):** 78 by `DPEG_PropertyMgmt_Edit` + `DPEG_PropertyMgmt_View` · 73 by `DPEG_PropertyMgmt_Edit` alone · 10 by `DPEG_PropertyMgmt_View` alone · 8 by `DPEG_App_PropertyMgmt` + `DPEG_Admin_Access` (tabs) · 7 by `DPEG_PropertyMgmt_Edit` + `DPEG_LeaseNotes_Create` · 6 by `DPEG_Apex_Access` · 4 by `DPEG_Admin_Access`.

**Residual (39), grouped:**

| Group | Grants | Nature |
| --- | --- | --- |
| **Tab** | `standard-Task` | §1.2 blocking — the second of the only two files carrying it |
| **Apex** | `BrokerCheckInReminderSchedulable`, `OnboardingTaskRollupService` | Schedulable + service. Same "verify, do not assume" rule as §4.4 #2–3. |
| **Task / Event onboarding block** (12) | `Blocked_Reason__c`, `Onboarding__c`, `Onboarding_Category__c`, `Onboarding_Status__c`, `Source_System__c`, `Task_Owner_Label__c` — on **both** `Task` and `Event`, all r+e | Not covered anywhere. Destination: `DPEG_Task_Edit` if the PM persona drives the Onboarding checklist, else `DPEG_Admin_Access`. |
| 🔴 **Work Order EDIT rights** (17) | `Work_Order__c`: `Category__c`, `Completed_DateTime__c`, `Delay_Reason__c`, `Description__c`, `First_Touched_DateTime__c`, `Owner_Role__c`, `Owner_User__c`, `Priority__c`, `Property_Asset__c`, `Status__c`, `Tenant_Name__c`, `Unit_Label__c`, `Vendor__c` (all `editable`); `Work_Order_Activity__c`: `Actor__c`, `Detail__c`, `Entry_DateTime__c`, `Kind__c` (all `editable`); plus `objectPermissions` `Work_Order__c` and `Work_Order_Activity__c` → `allowCreate` / `allowEdit` / `allowDelete` | **See §4.5.1 — this is a policy question, not a gap to close.** |
| **Other object rights** (5) | `Lease_Renewal__c` `allowDelete`; `Onboarding__c` `allowDelete`; `Renewal_Activity__c` `allowDelete` + `viewAllRecords`; `Rent_Step__c` `viewAllRecords`; `Unit__c` `viewAllRecords` | Same class as §4.4.2 — deliberate decision, restore or accept the tightening. |

#### 4.5.1 🔴 The Work Order residual is a HARDENING, and it may be the correct outcome

`Work_Order__c` and `Work_Order_Activity__c` are a **read-only Yardi mirror** (`ARCHITECTURE.md` §1: *"mirrored read-only from Yardi. No write-back except the Delay Reason flag."*). `DPEG_PropertyMgmt_View` carries exactly that read-only carve-out, which is why `DPEG_Property_Management_Team` composes **both** the Edit and View sets — and why merging that pair is on the do-not-touch list.

`Property_Management_Access` grants **create, edit and delete** on both objects. Retiring it therefore **enforces the documented read-only contract** rather than breaking something.

**Do not blindly copy these 21 grants into a surviving set to "close the residual".** That would re-open write access to the Yardi mirror in the name of a cleanup. Decide deliberately:

- **(a) Accept the tightening** *(recommended)* — it matches the documented architecture. Record it as an intentional behaviour change and UAT that the Work Order screens still render read-only and nothing errors.
- **(b) Restore write access** to `DPEG_Admin_Access` only, if the admin genuinely needs to hand-correct mirrored rows. Narrower, and does not touch the PM persona.
- **(c) Restore to `DPEG_PropertyMgmt_Edit`** — this re-opens write for the whole PM team and contradicts §1 of `ARCHITECTURE.md`. Requires an explicit decision from the architecture owner.

#### 4.5.2 🔴 BLOCKING PREREQUISITE — confirm the holder before doing anything else

The holder of `Property_Management_Access` is **unknown**. A prior query returned no assignment, but **"no assignment returned in one query window" is not the same as "no assignment"**. Query explicitly, with no date scoping:

```bash
sf data query --target-org usman-dpeg --json --query \
 "SELECT Assignee.Username, Assignee.IsActive, PermissionSet.Name \
  FROM PermissionSetAssignment WHERE PermissionSet.Name = 'Property_Management_Access'"
```

- **If the result is genuinely empty** — and no permission set group contains it — this collapses to a pure deletion: steps C, D and E have nothing to do, and you go straight from step B to step F.
- **If it has holders**, run the full sequence with those personas in step D.

⚠ `sf data query` may fail under Git Bash on this Windows box; run it from PowerShell if so.

### 4.6 `DPEG_Acquisitions` — residual 59

**Covered (400):** 212 by `DPEG_Acquisition_Edit` alone · 55 by `DPEG_Disposition_Edit` alone · 36 by `DPEG_Acquisition_Edit` + `DPEG_Disposition_Edit` · 24 by `DPEG_Acquisition_Edit` + `DPEG_Acquisition_View` · 20 by `DPEG_Apex_Access` · 13 by `DPEG_Contact_Edit` · 10 by `DPEG_Admin_Access` alone · 5 by `DPEG_Transaction_Edit` · 5 by `DPEG_Disposition_Edit` + `DPEG_Admin_Access` · 4 by `DPEG_Acquisition_Edit` + `_View` + `DPEG_Disposition_Edit` + `_View` · 4 by `DPEG_Acquisition_Edit` + `DPEG_Disposition_Edit` + `DPEG_Admin_Access` · 4 by `DPEG_Disposition_Edit` + `_View` + `DPEG_Admin_Access` · 3 by `DPEG_Acquisition_Edit` + `DPEG_Admin_Access` · 4 tabs/apps by `DPEG_Admin_Access` + the `DPEG_App_*` sets · 1 by `DPEG_Disposition_Edit` + `DPEG_Disposition_View`.

🔴 **Note which sets appear in that list: `DPEG_Contact_Edit`, `DPEG_Transaction_Edit`, `DPEG_Disposition_Edit`, `DPEG_Acquisition_Edit`. The admin holds NONE of them unless assigned.** Coverage on paper is not coverage in practice — see step C.

**Residual (59):**

| Group | Grants | Notes |
| --- | --- | --- |
| **Apex service classes** (5) | `ApprovalAuditService`, `ContractExecutionService`, `GroupNotifier`, `LeadConvertService`, `OpportunityReviewService` | All **services**, not controllers — `DPEG_Apex_Access` deliberately holds controllers only. Same "verify, do not assume" rule: a trigger/flow-invoked service usually needs no class access. Measure before adding. |
| **`Property_Asset__c` FLS** (10) | `Argus_Signal__c`, `Closing_Date__c`, `Final_Purchase_Price__c`, `Market_Cap_Rate__c`, `NOI__c`, `Peak_Sell_Date__c`, `Projected_Value_At_Peak__c`, `Property__c`, `Status__c`, `Target_Sale_Price__c` (all r+e) | `DPEG_PropertyAsset_View` covers some read-only, not editable. Destination: `DPEG_Admin_Access`, or `DPEG_Disposition_Edit` if a disposition persona needs them. |
| **`Rent_Step__c` FLS** (8) | `Monthly_Rent__c`, `Note__c`, `Period_End__c`, `Period_Label__c`, `Period_Start__c`, `Rent_PSF__c`, `Sort_Order__c`, `Type__c` (read) | Rent Roll surface. PM-module fields sitting in the acquisitions monolith. |
| **`Unit__c` FLS** (16) | `Asking_Rent_PSF__c`, `Current_Monthly_Rent__c`, `Current_Rent_PSF__c`, `Estimated_NNN_PSF__c`, `Lease_End__c`, `Lease_Start__c`, `NNN_CAM__c`, `NNN_Insurance__c`, `NNN_Monthly_Total__c`, `NNN_Property_Tax__c`, `NNN_PSF__c`, `Square_Feet__c`, `Status__c`, `Suite_Number__c`, `Tenant_Name__c`, `Yardi_Unit_Id__c` (read) | Same — Rent Roll. |
| **Object `allowDelete` + `modifyAllRecords`** (16) | `BOV_Submission__c`, `Broker_Listing__c`, `Construction_Feasibility_Review__c`, `Contract_Review__c`, `Counter_Offer__c`, `Deal_Message__c`, `Development_Feasibility_Review__c`, `Disposition__c`, `Disposition_Offer__c`, `LOI__c`, `NDA__c`, `Offering__c`, `Property__c`, `PSA_Version__c`, `Underwriting__c`, `Wire__c` | The module Edit sets grant C/R/E but **not** delete or Modify All. Same decision class as §4.4.2, at scale: restore in `DPEG_Admin_Access`, or accept the tightening. ⚠ `Deal_Message__c`, `PSA_Version__c` and `Renewal_Activity__c` are **append-only by design** — losing delete on those is arguably a *fix*. |
| **Objects not covered at all** (4) | `Property_Asset__c` (all six flags), `Transaction__c` (all six), `Rent_Step__c` (`allowRead` + `viewAllRecords`), `Unit__c` (`allowRead` + `viewAllRecords`) | These are PM/Transaction objects living in the acquisitions monolith. `DPEG_PropertyAsset_View` / `DPEG_Transaction_Edit` / `DPEG_PropertyMgmt_*` cover them **for personas who hold those sets** — the admin does not. |

#### 4.6.1 🔴 BLOCKING PREREQUISITE — does the admin hold `DPEG_Apex_Access`?

The admin's invoke access to **20 LWC controllers** currently comes from `DPEG_Acquisitions` and/or their profile. The assignment data does **not** show the admin holding `DPEG_Apex_Access`. If they do not, retiring this monolith **silently removes their ability to invoke 20 controllers**, and the symptom is a raw-platform-text error toast on every affected component — not a deploy error.

**This must be measured before stage 5 proceeds. It is blocking.**

```bash
sf data query --target-org usman-dpeg --json --query \
 "SELECT PermissionSet.Name FROM PermissionSetAssignment \
  WHERE Assignee.Username = 'usman.khan.dpeg@avanzasolutions.com' \
    AND PermissionSet.IsOwnedByProfile = false ORDER BY PermissionSet.Name"
```

Check the result for `DPEG_Apex_Access`, `DPEG_Acquisition_Edit`, `DPEG_Disposition_Edit`, `DPEG_Contact_Edit`, `DPEG_Transaction_Edit`, `DPEG_Admin_Access`. **Every one of those that is missing must be assigned in step C**, because §4.6's coverage table depends on all of them.

---

## 5. THE STAGES

### 5.1 Stage 1 — `Acquisitions_Dashboard_Access` (the rehearsal)

| Step | Action | Type |
| --- | --- | --- |
| A | Nothing to reconcile — this stage edits no existing set. | — |
| B | Nothing to close — residual is 0, proven (§4.2). | — |
| C | Confirm the admin holds `DPEG_Acquisition_Edit`: run the §4.6.1 query and look for it. If absent, **assign it in-org** (Setup → Permission Sets → `DPEG_Acquisition_Edit` → Manage Assignments → Add). | **IN-ORG** |
| D | **VERIFY as `usman.khan.dpeg`:** open the Acquisition Dashboard. Confirm all three derived columns render with values: **Underwriting Verdict**, **Deal Bucket**, **NDA Days Out**. A blank column here is the failure signal. | **IN-ORG, human** |
| E | Setup → Permission Sets → `Acquisitions_Dashboard_Access` → Manage Assignments → **remove every assignee**. Confirm it is in **no** permission set group. | **IN-ORG** |
| F | `sf project deploy start --manifest manifest/permset-retirement/1-acquisitions-dashboard-access/package.xml --post-destructive-changes manifest/permset-retirement/1-acquisitions-dashboard-access/destructiveChanges.xml --target-org usman-dpeg` | deploy |

**Rollback:** `git checkout <commit> -- force-app/main/default/permissionsets/Acquisitions_Dashboard_Access.permissionset-meta.xml`, deploy it, re-assign in-org. Three FLS grants — trivial.

---

### 5.2 Stage 2 — `Acquisition_App_Access`

| Step | Action | Type |
| --- | --- | --- |
| A | **Reconcile `DPEG_Admin_Access` org → repo** (§1.1). It is edited by this stage. Expect **zero** org-only grants now that the six record types are reconciled in — if the diff shows any others, stop and add them to the file first. | measure |
| B | Already closed in the repo: `DPEG_Admin_Access` has gained the four `applicationVisibilities`. Nothing further. | — |
| C | Deploy `DPEG_Admin_Access`. ⚠ Read §1.4 first — it now references six record types that exist only in the org. Then **confirm the admin is assigned `DPEG_Admin_Access`** (§4.6.1 query); assign it in-org if not. | deploy + **IN-ORG** |
| D | **VERIFY as `usman.khan.dpeg`:** open the App Launcher and confirm **all four** apps are listed — Acquisition, Disposition, Transaction, Property Management. Open one record page in each to confirm the tabs render. | **IN-ORG, human** |
| E | Remove all assignments of `Acquisition_App_Access`; confirm it is in no group. | **IN-ORG** |
| F | Deploy `manifest/permset-retirement/2-acquisition-app-access/` (same command shape as stage 1). | deploy |

**Rollback:** restore `Acquisition_App_Access` from git, deploy, re-assign. If the *cause* was the §1.4 record-type dependency, the faster fix is to deploy `DPEG_Admin_Access` **without** the six record types to a non-`usman-dpeg` org — but never to `usman-dpeg`, where that would wipe them.

---

### 5.3 Stage 3 — `Transaction_App_Access`

| Step | Action | Type |
| --- | --- | --- |
| A | Reconcile **every** set this stage will edit — at minimum `DPEG_Admin_Access` and `DPEG_Task_Edit`, plus `DPEG_Transaction_Edit` and `DPEG_App_Transaction` if step B targets them. | measure |
| B | **Close the 15-grant residual (§4.4). BLOCKING: `standard-Task` (§1.2) must be re-homed before step F.** Decide each of the four groups: the tab, the two service classes (measure, do not assume), the 10 Task/Event `editable` bits, and the two `allowDelete` rights (§4.4.2). ⚠ §4.4.1 — if the answer for a persona is "they never had it", that is a CHANGE and goes back for a decision. | decide + author + deploy |
| C | Deploy the amended sets. Assign in-org anything the admin does not already hold. | deploy + **IN-ORG** |
| D | **VERIFY as `usman.khan.dpeg` AND as the Transaction Team persona:** Active Transactions KPIs render · the Day-0 checklist tile shows "N / 75" · the Critical Dates list populates · **the Tasks tab is present** · open a `Transaction__c` and a `Critical_Date__c` record and confirm every field region renders. | **IN-ORG, human** |
| E | Remove all assignments; confirm no group membership. | **IN-ORG** |
| F | Deploy `manifest/permset-retirement/3-transaction-app-access/`. | deploy |

**Rollback:** restore from git + re-assign. ⚠ The `DPEG_Transaction_Edit` / `DPEG_Task_Edit` edits are subject to §1.1 — reconcile before re-deploying them too.

---

### 5.4 Stage 4 — `Property_Management_Access`

| Step | Action | Type |
| --- | --- | --- |
| **0** | 🔴 **BLOCKING — confirm the holder (§4.5.2).** If genuinely unassigned and in no group, steps C/D/E have nothing to do and you may go from B straight to F. | measure |
| A | Reconcile every set this stage edits (`DPEG_PropertyMgmt_Edit` / `_View`, `DPEG_App_PropertyMgmt`, `DPEG_Task_Edit`, `DPEG_Admin_Access` — whichever step B targets). | measure |
| B | **Close the 39-grant residual (§4.5). Two blocking items:** (i) `standard-Task` (§1.2) — this is the second of the only two files carrying it, so after this stage it is gone unless re-homed; (ii) 🔴 **the 21 Work Order write grants are a POLICY decision (§4.5.1), not a gap** — pick (a), (b) or (c) and record which. Also decide the 12 Task/Event onboarding fields and the 5 other object rights. | decide + author + deploy |
| C | Deploy the amended sets; assign in-org as needed. | deploy + **IN-ORG** |
| D | **VERIFY as the PM Team persona** (and as the admin): Onboarding checklist · Broker Assignments · Lease Activity Tracker · Lease Renewals · **Work Orders (confirm they render, and confirm the read/write behaviour matches the §4.5.1 decision you made)** · Rent Roll · **Tasks tab**. | **IN-ORG, human** |
| E | Remove all assignments; confirm no group membership. | **IN-ORG** |
| F | Deploy `manifest/permset-retirement/4-property-management-access/`. | deploy |

**Rollback:** restore from git + re-assign. If the §4.5.1 decision proves wrong in UAT, restoring **just** this set is the fastest route back to the previous behaviour.

---

### 5.5 Stage 5 — `DPEG_Acquisitions` (largest; run last)

| Step | Action | Type |
| --- | --- | --- |
| **0** | 🔴 **BLOCKING — §4.6.1. Measure which permission sets the admin actually holds.** Everything in §4.6's coverage table is conditional on this. | measure |
| A | Reconcile every set this stage edits. `DPEG_Admin_Access` is certain; `DPEG_Disposition_Edit` is likely (repo is far ahead of org — 90 KB vs 24 KB — so expect large repo-only additions, which are safe; what matters is that there are **no org-only** grants). | measure |
| B | **Close the 59-grant residual (§4.6).** Five service classes (measure first) · 10 `Property_Asset__c` r+e · 8 `Rent_Step__c` read · 16 `Unit__c` read · 16 object `allowDelete`/`modifyAllRecords` · 4 objects not covered at all. Default destination for admin-only restoration is `DPEG_Admin_Access`; anything a **persona** needs goes to that module's Edit/View set instead. | decide + author + deploy |
| C | Deploy the amended sets. **Assign the admin, in-org, every set §4.6's coverage depends on** — at minimum `DPEG_Apex_Access`, `DPEG_Acquisition_Edit`, `DPEG_Disposition_Edit`, `DPEG_Contact_Edit`, `DPEG_Transaction_Edit`, `DPEG_Admin_Access`. | deploy + **IN-ORG** |
| D | **VERIFY as `usman.khan.dpeg`, thoroughly.** Open one record of **each** of: Opportunity, LOI, NDA, Underwriting, Contract Review, Development FR, Construction FR, Disposition, Transaction, Property Asset. On each confirm: every field region renders (no blanks) · every record type is selectable in **New** · every LWC on the page loads **without an error toast**. Then run the §6 bundle list. | **IN-ORG, human** |
| E | Remove all assignments; confirm no group membership. | **IN-ORG** |
| F | Deploy `manifest/permset-retirement/5-dpeg-acquisitions/`. | deploy |

**Rollback:** restore `DPEG_Acquisitions` from git, deploy, re-assign. The file's recorded 2026-08-09 reconciliation found zero org-only grants in it, which makes the repo copy a trustworthy rollback source **as of that date** — re-confirm with a fresh retrieve before relying on it (§1.1: that same reconciliation went stale within a day for `DPEG_Admin_Access`).

---

## 6. UAT — the 11 LWC bundles in the blast radius

Any change to class access on the four stage-action controllers touches **11 bundles plus 2 shared guard utils**. All 11 belong on the UAT list for the additive deploy (§2.1 steps 4 and 6), and the `RecordStageAdvanceController` six also belong on stage 5's step D.

| Controller | Bundles |
| --- | --- |
| `StageAdvanceController` | `advanceDealStage`, `dealSendToDevelopmentReview`, `dealSendToConstructionReview`, `dealMoveToAboutToClose` |
| `OpportunityApprovalController` | `submitForApproval` |
| `RecordStageAdvanceController` | `advanceRecordStage`, `loiMarkCountered`, `loiMarkCompleted`, `ndaMarkDeclined`, **`loiMarkCounterReceived`**, **`loiMarkCounteredByDpeg`** |
| shared guard utils | `dealActionGuard` (5 Opportunity bundles), `recordStageGuard` (6 child-object bundles) |

⚠ `loiMarkCounterReceived` and `loiMarkCounteredByDpeg` are easy to miss — earlier counts of this blast radius said 9 bundles and omitted them.

**Run every bundle as TWO personas:**

1. **A real deal driver** (`junior.dhanani@usmandpeg.uat`) — every action completes, the Path/highlights re-render.
2. **A non-driver** — the action is refused with a **clean denial toast**. 🔴 If the toast reads *"You do not have access to the Apex class named …"*, the trim in §2.1 step 5 has gone too far: re-add that class to `DPEG_Apex_Access` and redeploy.

⚠ **An admin smoke test proves nothing about this gate.** A bare System Administrator has no FLS on `User.Deal_Driver__c` — Metadata-API-deployed custom fields arrive with no field permissions for any profile, System Administrator included — which is why the service checks Modify All Data *before* it reads the flag. Acceptance-test as a real deal-driver persona.

---

## 7. DO NOT "FIX" THESE

Each looks like duplication and is not. Do not fold, merge or delete any of them during this work.

| Item | Why it stays |
| --- | --- |
| `DPEG_Opportunity_View`, `DPEG_Property_View` | Subsets of `DPEG_Acquisition_View`, composed **directly** by `DPEG_Transaction_Team`. Folding them in would give the Transaction team LOI, NDA, Underwriting, Counter Offer, PSA Version and Deal Message. |
| `DPEG_PropertyAsset_View` | Lets a non-PM persona read the Property Asset (Sell Meter / Disposition) without the 15-object PM module. |
| `Acquisition_Deal_Driver`, `Disposition_Deal_Driver` | Factor (a) of a two-factor gate. Folding either into a broad Edit set hands factor (a) to that set's whole population and leaves a one-factor gate. Deleting either denies every driver **silently** — the read throws, the service returns false, the buttons just stop working. |
| `LeadActionPermissionController` in both `Lead_Stage_Actions_Access` **and** `DPEG_Apex_Access` | Deliberate. A non-authorized user must reach the permission-question method to get a clean `false`. |
| `OpportunityActionPermissionController` + `RecordStageAdvanceController` in both `Opportunity_Stage_Actions_Access` **and** `DPEG_Apex_Access` | Same reason. `RecordStageAdvanceController` is additionally **structurally un-narrowable** — Apex class access is per-class, and that class holds both the question and the actions. |
| `DPEG_Admin_Access` as a whole | Layer 7. Exists only because `profiles/**` is `.forceignore`d. Its overlap with the persona sets is the mechanism, not a defect. |
| `DPEG_PropertyMgmt_Edit` / `_View` overlapping on 13 of 15 objects | The View set carries the read-only Yardi carve-out (`Work_Order__c`, `Work_Order_Activity__c`), which is why the PM team composes **both**. Merging them makes the read-only mirror editable. |
| `sfdcInternalInt__*`, `force__*` sets and groups | Platform-managed. Never edit, never delete. |

---

## 8. APPENDIX A — the `Disposition_Dashboard_Access` measurement (decision pending)

**This set is NOT on the retirement list and NOT in any execution step above.** It was measured only because it is the structural sibling of `Acquisitions_Dashboard_Access`, the one set proven fully redundant. Result and decision below; the decision is the user's.

**Result: it is NOT a subset of either disposition module set, unlike its acquisitions sibling.** 12 `fieldPermissions` measured against org state:

| Survivor union tested | Residual |
| --- | --- |
| `DPEG_Disposition_Edit` alone | **6 uncovered** |
| `DPEG_Disposition_View` alone | **8 uncovered** |
| `DPEG_Disposition_Edit` + `DPEG_PropertyAsset_View` | **3 uncovered** |
| `DPEG_Disposition_Edit` + `DPEG_PropertyMgmt_Edit` | **0 — fully covered** |

Uncovered against `DPEG_Disposition_Edit` alone:

```
Property_Asset__c.Argus_Value__c            (readable + editable)
Property_Asset__c.Property_Name__c          (readable)
Property_Asset__c.Property_Type__c          (readable + editable)
Property_Asset__c.Readiness_Score__c        (readable)
Property_Asset__c.Sell_Readiness_Band__c    (readable)
Property_Asset__c.Sell_Readiness_Score__c   (readable + editable)
```

Against `DPEG_Disposition_View` the same six plus `Disposition__c.Listing_Date__c` and `Disposition__c.Next_Broker_Checkin__c`, both on the `editable` bit only (the View set grants them read-only, correctly).

**Interpretation.** The gap is entirely `Property_Asset__c`, a **Property Management** object that the disposition module sets do not fully cover — the Sell Meter reads across the module boundary. So this set is doing real work that no single disposition set replicates, which is exactly why the acquisitions sibling's "full subset" result does **not** transfer.

**Recommendation: do not retire it in this pass.** A retirement would need `DPEG_PropertyMgmt_Edit` in the union, which means either assigning a PM-module set to a disposition persona (a widening, and a change) or moving six `Property_Asset__c` grants into `DPEG_Disposition_Edit` (defensible, but a schema-boundary decision, not a cleanup). Both are decisions, not mechanical de-duplication.

Re-measure before acting — this is a snapshot of 2026-08-10 and `DPEG_Disposition_Edit` is heavily repo-ahead-of-org.

---

## 9. APPENDIX B — reproducing the measurements

All numbers in this document came from normalizing both sides into one canonical line per grant with a real XML parser, then comparing.

⚠ **On this Windows box `python` / `python3` / `py` are all absent.** Use PowerShell's `System.Xml.XmlDocument` (a real parser, and it entity-decodes text so it also measures `<description>` against the 255-character cap correctly) or Node.

⚠ **PowerShell variables are case-INSENSITIVE.** A loop-local `$repo` silently clobbers a `$REPO` path constant and the next iteration fails with a nonsense path. Name them distinctly (`$RepoDir` / `$OrgDir`).

**Grant key = `<elementName>||<identity>`, with a numeric strength per value field:**

| Element | Identity tag | Strength fields |
| --- | --- | --- |
| `fieldPermissions` | `field` | `readable`, `editable` |
| `objectPermissions` | `object` | `allowCreate`, `allowRead`, `allowEdit`, `allowDelete`, `viewAllRecords`, `modifyAllRecords` |
| `classAccesses` | `apexClass` | `enabled` |
| `tabSettings` | `tab` | `visibility` → `Visible`=2, `Available`=1, `None`=0 |
| `applicationVisibilities` | `application` | `visible` |
| `recordTypeVisibilities` | `recordType` | `visible` |
| `userPermissions` | `name` | `enabled` |

- **Covered** = a surviving set has the same key with strength ≥ the doomed set's, on every value field the doomed set grants.
- **Residual** = not covered by the union of survivors.
- **Drift (destructive)** = a key present in the ORG copy and absent or weaker in the REPO copy. That is the direction that destroys live access on deploy.

Exclude `<viewAllFields>` from object comparisons (MDAPI emits it explicitly, source format omits it) or every object permission reads as differing.

---

## 10. CHECKLIST — tear this off

```
ADDITIVE DEPLOY (salesforce-devops, separate from this runbook)
  [ ] Reconcile DPEG_Apex_Access, Acquisition_Deal_Driver, DPEG_Junior_Analyst_PSG org->repo
  [ ] Deploy Opportunity_Stage_Actions_Access
  [ ] Deploy DPEG_Junior_Analyst_PSG (+ Acquisition_Deal_Driver, comment-only)
  [ ] Wait for group recalculation - status reads "Updated"
  [ ] VERIFY as junior.dhanani - all 11 bundles (section 6)
  [ ] Deploy trimmed DPEG_Apex_Access
  [ ] RE-VERIFY as junior.dhanani AND as a non-driver (clean denial, not raw Apex text)
  [ ] Run OpportunityActionPermissionServiceTest - must be green, must not be modified

STAGE 1  Acquisitions_Dashboard_Access
  [ ] C: admin holds DPEG_Acquisition_Edit   [ ] D: 3 dashboard columns render
  [ ] E: unassigned, no group                [ ] F: destructive deploy

STAGE 2  Acquisition_App_Access
  [ ] A: reconcile DPEG_Admin_Access         [ ] C: deploy it + admin assigned
  [ ] D: all 4 apps in App Launcher          [ ] E: unassigned  [ ] F: delete

STAGE 3  Transaction_App_Access
  [ ] A: reconcile   [ ] B: 15-grant residual closed, INCLUDING standard-Task
  [ ] B: allowDelete decision recorded       [ ] B: service-class need MEASURED
  [ ] C: deploy + assign  [ ] D: verify admin AND Transaction persona, Tasks tab present
  [ ] E: unassigned  [ ] F: delete

STAGE 4  Property_Management_Access
  [ ] 0: HOLDER CONFIRMED by explicit query  [ ] A: reconcile
  [ ] B: 39-grant residual closed, INCLUDING standard-Task
  [ ] B: WORK ORDER read-only POLICY decision recorded (a / b / c)
  [ ] C: deploy + assign  [ ] D: verify PM persona incl. Work Order behaviour
  [ ] E: unassigned  [ ] F: delete

STAGE 5  DPEG_Acquisitions
  [ ] 0: ADMIN'S PERMISSION SET HOLDINGS MEASURED (DPEG_Apex_Access especially)
  [ ] A: reconcile  [ ] B: 59-grant residual closed
  [ ] C: deploy + admin assigned every covering set
  [ ] D: 10 record types opened, every field region renders, no error toasts
  [ ] E: unassigned  [ ] F: delete

OUT OF SCOPE, RAISE SEPARATELY
  [ ] Org holds permission sets / groups / record types that are not in source
  [ ] DPEG_Principal_PSG repo copy is missing a member the org has - reconcile before
      ever deploying that group (a group deploy REPLACES its member list)
  [ ] Disposition_Dashboard_Access - measured (Appendix A), decision pending
```
