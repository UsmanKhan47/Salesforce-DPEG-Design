# Phase 0 — Rollback Plan (API 62.0 → 67.0 Uplift)

**Prepared:** 2026-07-15
**Target org:** DPEG-Acq-5 (scratch, expires 2026-08-14)
**Scope of change:** `sfdx-project.json` (`sourceApiVersion` 62.0→67.0), 69 `.cls-meta.xml`, 4 `.trigger-meta.xml`, 23 `.flow-meta.xml`. Version-line-only diff, confirmed via `git diff --numstat` (every file `1 1`) and `git diff -U0` (zero non-`apiVersion` content lines). `ARCHITECTURE.md`/`CLAUDE.md` are doc-only, not deployable metadata, no rollback action needed for them.

This plan must exist and be read **before** any deploy of this change is executed — not improvised during an incident. It is written now, before the check-only validation in Task 3, per the code-review finding.

---

## 1. Why Apex/triggers and Flows need different rollback strategies

| Metadata type | Deploy mechanics | Rollback mechanics |
|---|---|---|
| Apex classes/triggers (`apiVersion` in meta.xml) | Redeploying the class **overwrites in place** — there is one class body, one apiVersion tag. | Mechanical: redeploy the prior file content (or `git revert` + redeploy). Fully reversible, no data/state loss. |
| Flows | Redeploying a Flow with a bumped `apiVersion` (even with **zero logic changes**) **creates a brand-new Flow version** on top of whatever is currently active. Metadata deploys never edit an existing Flow version in place. | **Lossy by default.** Redeploying the old file does not "restore" the old version — it creates *yet another new version* with the old apiVersion tag. The only true rollback is **re-activating the previously-active version** via the UI/Tooling API, which still exists (Salesforce never deletes flow versions on deactivation). |

This asymmetry is why the Flow baseline below was captured **before** touching the org.

---

## 2. Pre-deploy Flow baseline (captured 2026-07-15, before any deploy/validate ran)

Queried via Tooling API (`FlowDefinition` → `ActiveVersion.VersionNumber` / `LatestVersion.VersionNumber` / `ActiveVersion.Status`) against DPEG-Acq-5. **All 23 flows are on Active Version 1** — Latest Version also 1 (no draft/inactive versions sitting around). This is the known-good state to return to if a Flow rollback is needed.

| # | Flow API Name | Active Version (pre-deploy) | Status |
|---|---|---|---|
| 1 | Broker_Portal_New_Lead_Notify | 1 | Active |
| 2 | Con_Review_Opinion_Notify | 1 | Active |
| 3 | Contract_Review_Stage_Sync | 1 | Active |
| 4 | Counter_Offer_Notify | 1 | Active |
| 5 | Dev_Review_Opinion_Notify | 1 | Active |
| 6 | LOI_Approval_Stamp | 1 | Active |
| 7 | LOI_Signed_Notify | 1 | Active |
| 8 | Lead_Approved_Notify | 1 | Active |
| 9 | Lead_Intake_Stamp | 1 | Active |
| 10 | Lease_Inquiry_Create_Lease | 1 | Active |
| 11 | Lease_Inquiry_Open_Log | 1 | Active |
| 12 | Lease_Inquiry_Signed_Date | 1 | Active |
| 13 | Lease_Inquiry_Stage_Timer | 1 | Active |
| 14 | Lease_Renewal_Status_Sync | 1 | Active |
| 15 | Opportunity_Initiate_Underwriting | 1 | Active |
| 16 | Opportunity_LOI_Prep_Stamp | 1 | Active |
| 17 | Opportunity_UW_Approved_Notify | 1 | Active |
| 18 | PSA_Ready_Notify | 1 | Active |
| 19 | PSA_Version_Notify | 1 | Active |
| 20 | Transaction_Complete_Close | 1 | Active |
| 21 | Transaction_Task_Fanout | 1 | Active |
| 22 | Underwriting_Opp_Sync | 1 | Active |
| 23 | Work_Order_Touch_Sync | 1 | Active |

**Expected post-deploy state:** every flow above active on **Version 2** (apiVersion 67.0), Version 1 still present in Version History but inactive. If any flow shows an active version other than 2 immediately after deploy, or more than one new version was created, treat that as a signal something unexpected happened (e.g., a partial deploy retry) and investigate before doing anything else.

Raw query used (repeatable — re-run any time to re-baseline):
```
sf data query -t --json \
  -q "SELECT DeveloperName, ActiveVersion.VersionNumber, LatestVersion.VersionNumber, ActiveVersion.Status FROM FlowDefinition ORDER BY DeveloperName" \
  -o DPEG-Acq-5
```

---

## 3. Rollback procedure — Apex classes & triggers

Mechanical, low-risk, fully reversible:

1. Identify the bad class(es)/trigger(s) from the incident.
2. `git revert <deploy-commit>` (or, if not yet committed, `git checkout -- <file>` on the working tree) to restore the prior `apiVersion` value (62.0) in the affected `.cls-meta.xml` / `.trigger-meta.xml`.
3. Redeploy just the affected file(s):
   `sf project deploy start --source-dir force-app/main/default/classes/<Class>.cls-meta.xml --target-org DPEG-Acq-5`
4. No data loss, no version proliferation — the deployed class body is simply overwritten back to its prior state.
5. Confirm via `sf project deploy report` or a fresh `sf project deploy validate` that the org matches the reverted source.

There is no scenario where an Apex/trigger apiVersion bump requires anything beyond a standard redeploy-the-old-file rollback.

---

## 4. Rollback procedure — Flows (lossy, requires manual reactivation)

**Do not attempt to "fix" a bad Flow by redeploying the 62.0-tagged source file.** That creates a *third* version, not a restore of Version 1, and burns another version-history slot while the org still runs on whatever version was active at the moment of the incident.

### Step-by-step

1. **Stop the bleeding first, restore state second.** If a Flow is actively causing harm (e.g., wrong emails firing, bad DML), the fastest safe action is usually **deactivate** the current (v2) version — Setup → Flows → click the flow → "Deactivate" — before deciding whether to reactivate v1 or fix-forward. A deactivated AutoLaunched record-triggered flow simply stops firing; it does not roll back records it already touched.
2. **Reactivate the known-good version** (Version 1 per the baseline in §2, for every flow in this change):
   - Setup → Flows → open the flow → **Version History** related list.
   - Locate the row for **Version 1**.
   - Click **Activate** on that row. This makes Version 1 active again and automatically deactivates Version 2 — Salesforce only allows one active version per flow.
   - Repeat per affected flow. There is no bulk "reactivate previous version" API call exposed to `sf`; this is a UI (or manual Tooling API `Flow` sObject `Status` update) action per flow.
3. **Tooling API alternative** (for scripting a mass rollback across many flows at once, e.g., in a real incident):
   ```
   sf data update record -t -s Flow -i <Version1FlowId> -v "Status=Active" -o DPEG-Acq-5
   ```
   Use the `301...` Version 1 Ids captured in the raw JSON export at
   `agent-output/P0-flow-baseline.json` (see §5) — each flow's Version 1 `Flow` record Id is under `ActiveVersion.attributes.url` in that file (pre-deploy baseline, before v2 exists).
4. **Verify** by re-running the same baseline query from §2 — every `ActiveVersion.VersionNumber` should read back to `1`.
5. **Any records touched by the bad v2 version between deploy and rollback are NOT automatically corrected.** Flow rollback only stops *future* executions from using the bad version — it does not undo DML already committed by v2 runs. Data cleanup (if any bad records were created/updated) is a separate, manual follow-up scoped to whatever the specific incident touched.

### Special note — `Transaction_Task_Fanout`

This flow calls `TaskFanoutService.fanOut()`, which has a **known, not-yet-fixed** governor-limit issue: 251 Transactions × ~75 Tasks/transaction ≈ 18,825 Task inserts in a single transaction context exceeds the 10,000-row DML limit (fix scoped for Phase 7, not present in this change). This is a **pre-existing** risk carried by the apiVersion bump, not introduced by it — the Flow's logic is unchanged, only its apiVersion tag moved 62→67. Rollback for this flow follows the same v1-reactivation procedure above; reactivating v1 does not "fix" the DML-limit issue (it was equally present in v1) — it only removes the double-exposure of running the apiVersion bump concurrently with an unrelated known defect. See the manual exercise script (`agent-output/P0-flow-exercise-script.md`) for how this is tested pre-deploy in isolation (single/small-batch Transaction, not a 251-record batch) specifically to avoid tripping this known limit during Phase 0 verification.

---

## 5. Supporting artifact

Full pre-deploy Flow baseline (raw Tooling API JSON, including each Version 1 `Flow` record Id needed for §4 step 3) is preserved at:
`agent-output/P0-flow-baseline.json`

---

## 6. Rollback decision tree (quick reference)

```
Incident detected after deploy
        |
        v
Is it an Apex/trigger issue only?
        |                    \
       YES                    NO (Flow involved)
        |                      |
  git revert + redeploy   Deactivate the offending Flow's
  affected .cls/.trigger  active (v2) version FIRST
  file(s). Done.                |
                                 v
                        Reactivate Version 1 via
                        Version History > Activate
                        (or Tooling API Flow.Status
                        update using baseline Ids)
                                 |
                                 v
                        Re-run baseline query to confirm
                        ActiveVersion.VersionNumber = 1
                        for every affected flow
                                 |
                                 v
                        Assess whether any records were
                        touched by the bad v2 run and need
                        manual data cleanup (separate from
                        the version rollback itself)
```
