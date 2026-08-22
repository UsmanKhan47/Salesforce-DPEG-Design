# Hub File Consolidation Tracker — FSD v1.1 build

Single owner: the orchestrator. **No implementation stream edits these files.** A PermissionSet
deploy REPLACES its entire `<fieldPermissions>` block, so concurrent edits silently lose each
other's fields — this must be applied in ONE pass.

⚠ **A concurrent session is editing this same working tree** (BOV score formula conversion:
`BovController.cls`, `DispositionApprovalService.cls`, `DispositionSelector.cls`, four `bov*` LWCs,
`BOV_Submission__c` field + layout, and **`DPEG_Disposition_Edit.permissionset-meta.xml`**, plus
`manifest/bov-score-formula-conversion/`). Their permission set is different from ours, so no direct
collision — but **diff every hub file against HEAD immediately before deploying**, and never run a
repo-wide deploy.

---

## Status

| Stream | Schema | Apex | Hub requests received |
|---|---|---|---|
| Utility & Meter | ✅ validated 65 components / 0 errors | ⬜ not started | ✅ |
| Onboarding | ✅ validated | 🔄 in progress | ✅ (partial — dev wave pending) |
| AR & Delinquency | 🔄 in progress | ⬜ blocked on schema | ⬜ |

---

## 🔴 Formula / roll-up fields — MUST be granted read-only FLS

Granting `editable=true` on these **fails the deploy**. Verified by reading each field's `<type>`.

| Object | Field | Why |
|---|---|---|
| `Utility_Bill__c` | `Rate_Per_Unit__c` | formula (Currency) |
| `Utility_Bill__c` | `Usage_Variance_Amount__c` | formula (Currency) |
| `Utility_Bill__c` | `Rate_Variance_Amount__c` | formula (Currency) |
| `Utility_Bill__c` | `Total_Variance_Amount__c` | formula (Currency) |
| `Utility_Bill__c` | `Total_Variance_Pct__c` | formula (Percent) |
| `Utility_Bill__c` | `Total_Charges_Amount__c` | roll-up Summary |
| `Meter__c` | `Register_Modulus__c` | formula (Number) |
| `Meter__c` | `Total_Allocated_Pct__c` | roll-up Summary |

`Utility_Bill__c.Consumption__c` is a plain **Number**, deliberately — rollover handling forces it to
be Apex-computed, so it IS writable.

---

## Requests — Utility & Meter

**Object permissions**, `DPEG_PropertyMgmt_View` (`allowRead=true`, `viewAllRecords=true`, rest false)
and `DPEG_PropertyMgmt_Edit` (`allowCreate`/`allowEdit=true`):
`Meter__c`, `Utility_Bill__c`, `Charge_Line__c`, `Meter_Allocation__c`, `Vendor_Contract__c`.
- Recommend `allowDelete=false` on `Utility_Bill__c` and `Charge_Line__c` (billing data — matches the
  caution already applied to `CAM_Reconciliation__c`).
- `Charge_Line__c` and `Meter_Allocation__c` are related-list-only children: they need object + field
  permissions but **no tab**.

**Field permissions**: every field on all five objects (metadata-deployed fields arrive with zero FLS
for everyone, admins included). Read-only in `View`; editable in `Edit` EXCEPT the 8 listed above.

**Tab visibility** in `DPEG_App_PropertyMgmt`: `Meter__c`, `Utility_Bill__c`, `Vendor_Contract__c`.

**App nav** in `applications/Property_Management.app-meta.xml`: the same three.

---

## Requests — Onboarding

| Hub file | Change | Why |
|---|---|---|
| `DPEG_PropertyMgmt_Edit` | `Onboarding__c.Tasks_Fanned_Out__c` — `readable=true`, **`editable=false`** | Idempotency marker. If a human can clear it, re-running mints 45 duplicate Tasks. |
| `DPEG_PropertyMgmt_View` | `Onboarding__c.Tasks_Fanned_Out__c` — `readable=true`, `editable=false` | Read parity |
| `DPEG_Task_Edit` | `Task.Onboarding_Completed_Date__c` — `readable=true`, **`editable=false`** | Trigger-stamped only; a hand edit defeats the "auto-set on completion" fix |

Developer wave may add more — hold this section open.

---

## Requests — AR & Delinquency

Schema validated: **136 components, 0 errors**. Field inventory derived directly from the files.

**Object permissions:**
- **`Case`** — currently granted by **NO permission set at all**. Needs object perms in both PM sets,
  plus **record-type visibility for `Delinquency`**, plus a tab. Without the record type grant the
  path and business process are invisible even to users who can see Cases.
- **`Receivables_Summary__c`** — 🔴 genuinely **READ-ONLY**. Grant Read + `viewAllRecords` in
  `DPEG_PropertyMgmt_View` and **do NOT add it to `DPEG_PropertyMgmt_Edit`**. Copy the
  `Work_Order__c` exclusion pattern. The existing `Delinquency__c` grants Edit, which inverts the
  mirror rule — do not copy that.
- **`Payment_Commitment__c`** — master-detail child of Case; CRU in Edit, Read in View. No tab.
- **`Sync_Run__c`** — operational audit. Read for PM; recommend **no Edit for anyone** (an editable
  audit log is not an audit log). Admin-only tab, or no tab.

**Case fields** (22 custom) — all writable EXCEPT these two, which are **formula → read-only FLS**:
`Dashboard_Flag__c`, `Days_Since_Last_Follow_Up__c`.

**`Receivables_Summary__c` fields** (23) — read-only FLS throughout (read-only object). Two are
formulas regardless: `Aging_Bucket__c`, `Months_Outstanding__c`.
Note the five aging buckets are `Current_Amount__c`, `Aging_1_30_Amount__c`, `Aging_31_60_Amount__c`,
`Aging_61_90_Amount__c`, `Aging_90_Plus_Amount__c` — matching D-AR-2.

**`Payment_Commitment__c`** (9) and **`Sync_Run__c`** (15) — all writable types, no formulas.

---

## 🔴 Master list — all 12 formula/roll-up fields needing READ-ONLY FLS

Granting `editable=true` on any of these fails the permission-set deploy.

| Object | Fields |
|---|---|
| `Utility_Bill__c` | `Rate_Per_Unit__c`, `Usage_Variance_Amount__c`, `Rate_Variance_Amount__c`, `Total_Variance_Amount__c`, `Total_Variance_Pct__c` (formulas); `Total_Charges_Amount__c` (roll-up) |
| `Meter__c` | `Register_Modulus__c` (formula); `Total_Allocated_Pct__c` (roll-up) |
| `Case` | `Dashboard_Flag__c`, `Days_Since_Last_Follow_Up__c` (formulas) |
| `Receivables_Summary__c` | `Aging_Bucket__c`, `Months_Outstanding__c` (formulas) |

---

## Deploy ORDER matters

`sharingRules/Receivables_Summary__c` cannot validate until its parent object exists in the org —
confirmed, and it is deploy-order, not a defect. Sequence: **objects → sharing rules → permission
sets**. Sharing rules on this project deploy **one at a time**.

---

## Also owned by the orchestrator

- `.forceignore` — Phase 0 complete and proven. Do not let a stream touch it.
- `objects/Case/Case.object-meta.xml` — OWD corrected to `Private` to match the org. Do not "restore"
  `ReadWriteTransfer`.
- Retirement of `Delinquency__c` — plan only, not executed. It still backs 2 live dashboard
  components and a report, and `scripts/seed-pm-dashboard.apex:37-44,66` resurrects it on every org
  rebuild.

## Still owed by the user

The **two missing Performance Tracking onboarding task names** (FSD says 3, repo has 1). Shipping 45
rows with two documented gaps; adding them later is two records through
`scripts/load-onboarding-task-defs.apex`, no code change.
