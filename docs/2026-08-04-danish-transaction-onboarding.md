# Danish Rehman — Transaction team onboarding runbook

**Date:** 2026-08-04
**Target org:** `usman-dpeg`
**Type:** In-org manual steps. None of this is deployable metadata — do not look for it in `force-app/`.

**Related:** `agent-output/design-requirements.md` (approved design), `docs/rbac-access-model-standard.md`
(adopted access model), the 2026-07-22 RBAC build (`docs/` entries for that date if present).

---

## Metadata already deployed as part of this change (for context — deploy via `salesforce-devops`)

- New permission set `DPEG_Property_View` (read-only `Property__c`, View All, full FLS).
- New permission set `DPEG_Reports_Access` (`RunReports` only).
- Amended permission set group `DPEG_Transaction_Team` — removed `DPEG_PropertyAsset_View`,
  `DPEG_Disposition_View`, `DPEG_App_Disposition`; added `DPEG_Property_View`, `DPEG_Reports_Access`.
- New classic email template `unfiled$public/Transaction_Opened_Notification`.
- New Email Alert `Transaction__c.Transaction_Opened_Notification` (`workflows/Transaction__c.workflow-meta.xml`),
  recipient = group `Transactions_Team`.
- New record-triggered flow `Transaction_Opened_Notify` (`Transaction__c`, after-insert, no filter) that fires
  the alert above.

None of the above creates users, assigns permission sets, adds group members, or touches data. The steps
below complete the picture in the org itself.

---

## a. Create the user

Setup → Users → New User:

| Field | Value |
|---|---|
| First Name | Danish |
| Last Name | Rehman |
| Email | `usmanblogs7@gmail.com` |
| Username | `danish.rehman@usmandpeg.uat` |
| Nickname | `danish` |
| Alias | `drehm` |
| Profile | `Minimum Access - Salesforce` |
| Role | `Transactions Coordinator` |
| User License | Salesforce |
| Locale | `en_US` |
| Language | `en_US` |
| Time Zone | `America/Los_Angeles` |
| Email Encoding | `UTF-8` |

## b. Assign the permission set group

Setup → Users → Danish Rehman → Permission Set Group Assignments → Edit Assignments → assign
**`DPEG_Transaction_Team`**.

This is the one PSG for this persona. It now composes: `DPEG_Base_Access`, `DPEG_Apex_Access`,
`DPEG_Transaction_Edit`, `DPEG_Task_Edit`, `DPEG_Opportunity_View`, `DPEG_Property_View`,
`DPEG_Reports_Access`, `DPEG_App_Transaction`. Disposition and Property Management access were
deliberately removed from this PSG in this change — confirm nobody else was relying on them (see the
caveat at the bottom of this doc).

## c. Add Danish to public group `DPEG_Transactions_Team` — REQUIRED for EDIT

Setup → Public Groups → `DPEG_Transactions_Team` → Add Danish as a member.

**Why this is required and not optional:** the sharing rule `Transaction_Team_All_RW`
(`sharingRules/Transaction__c.sharingRules-meta.xml`) grants Edit access to `Transaction__c` (and the
twin `Critical_Date_Team_All_RW` rule to `Critical_Date__c`) to this exact public group, not to
`DPEG_Transaction_Edit` holders generally. `DPEG_Transaction_Edit` gives Danish `viewAllRecords=true`
(read of every Transaction), but **without group membership he cannot edit any Transaction he does not
own** — and he owns none, since Transactions are pipeline-created. Skipping this step produces a
confusing "read-only despite an Edit permission set" symptom.

## d. Add Danish to public group `Transactions_Team` — REQUIRED to receive notifications

Setup → Public Groups → `Transactions_Team` → Add Danish as a member.

**Why:** this is the recipient group for two independent things — the pre-existing `GroupNotifier`
custom notification ("PSA executed - transaction opened", fired by `ContractExecutionService`) and the
**new** `Transaction_Opened_Notification` email alert built in this change. Missing this step means
Danish sees Transactions in the app but is never proactively told one exists.

Do not confuse this group with `DPEG_Transactions_Team` in step (c) — they are two different groups
serving two different mechanisms (sharing vs. notification), and Danish needs to be in **both**.

## e. Deliverability and email verification checks

- Danish must **verify his email address** (`usmanblogs7@gmail.com`) before Salesforce will deliver
  any mail to it — the platform sends a verification email on user creation / first login; this must
  be completed, not just triggered.
- Confirm org **Email Deliverability** (Setup → Email → Deliverability) is set to **"All email"**. Demo
  / sandbox-style orgs are sometimes left on "No Access" or "System email only," in which case the new
  Email Alert will silently not send even though the Flow and Workflow deploy cleanly and fire.

## f. Acceptance test — log in AS DANISH, not as an admin

FLS truth lives in the org, not this repo (profiles are `.forceignore`d), and an admin's own profile
grants pass FLS checks Danish's `Minimum Access - Salesforce` profile does not. An admin smoke test
proves nothing about this persona. Log in as Danish (or use "Login As" from the user detail page) and
verify:

1. The **Transaction** app appears in the App Launcher and loads.
2. All 4 tabs appear: Active Transactions, Transaction, Reports (standard-report), Transaction Dashboard.
3. A Transaction record page opens showing: the highlights panel, the Path (Stage), the 4 phase tabs,
   **and a populated Property tab** (this is the tab `DPEG_Property_View` exists to fix — if it is
   blank, the permission set was not actually assigned or PSG propagation has not completed yet).
4. A checklist task on the record can be marked complete.
5. The Details tab shows no blank fields for a record Danish should be able to read in full.
6. The **Reports** tab lets Danish open and run a report (not just see the tab) — this is the
   functional test for `DPEG_Reports_Access`.
7. The **Transaction Dashboard** tab renders live data, not a permissions error.
8. Trigger (or wait for) a new Transaction to be created via the normal PSA-execution pipeline and
   confirm the `Transaction_Opened_Notification` email arrives at `usmanblogs7@gmail.com`.

## g. Known caveats carried forward from the design (not defects introduced by this change)

- **The Edit sharing rule keys on `Stage__c != blank`.** If a Transaction's `Stage__c` is ever cleared,
  the whole Transactions team — Danish included — silently drops to read-only on that record. This is
  existing, deployed behavior, not something this change altered.
- **`DPEG_Task_Edit` grants Task only, not Event.** The Activity panel's Event half (New Event /
  calendar) will be unavailable to Danish. Not in scope for this change.
- **`Transaction__c.Owner_Name__c` is a plain Text field**, populated only by
  `scripts/seed-transactions.apex` (hardcoded to `'Danish'` in that script) — it is never set by the
  real `ContractExecutionService` pipeline. Expect the "Owner" column in `activeTransactionsList` to be
  **blank** on every real, pipeline-created Transaction. This is a pre-existing display defect, not
  something introduced or fixed here.
- **Dashboard/report folder sharing is a separate, in-org step not covered by `DPEG_Reports_Access`.**
  `RunReports` lets Danish execute a report or dashboard he can already see; it does not by itself put
  any specific report or the Transaction Dashboard in front of him. If the Transaction Dashboard and its
  underlying reports live in a folder that is not already shared broadly (e.g. a "Public" folder or a
  folder explicitly shared to `Transactions_Team` / `DPEG_Transactions_Team`), share that folder
  (Setup → Reports/Dashboards → folder → Share) so step (f)(6)/(7) actually has something to show.
- **If anyone else was already assigned `DPEG_Transaction_Team` before this change**, they have just
  lost `DPEG_PropertyAsset_View`, `DPEG_Disposition_View`, and `DPEG_App_Disposition` (Property
  Management + Disposition access), and gained `DPEG_Property_View` + `DPEG_Reports_Access`. Per the
  approved design this PSG was confirmed unassigned to anyone before this change, but re-check current
  assignees in the org before rollout if time has passed since that confirmation.
