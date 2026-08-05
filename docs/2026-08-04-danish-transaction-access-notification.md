# Danish — Transaction Team Access & "Transaction Opened" Email Notification

**Date:** 2026-08-04
**Author:** Documentation Agent
**Status:** Completed (metadata authored; deployment + in-org steps tracked separately — see below)
**Target org:** `usman-dpeg` (live EE demo)

**Related documents:**
- `agent-output/design-requirements.md` — full design, evidence trail, and the open-questions log this
  build resolved (referenced throughout as Q1–Q9)
- `docs/2026-08-04-danish-transaction-onboarding.md` — the in-org manual runbook (user creation, PSG
  assignment, group memberships, acceptance test). **This document does not duplicate that runbook** —
  it explains what was built and why; the runbook is the operational checklist to execute it.
- `docs/rbac-access-model-standard.md` — the adopted org-wide RBAC/naming standard, amended in this
  same change (see §7 below)

---

## Overview

### Original request

> Create a new Salesforce user, Danish (`usmanblogs7@gmail.com`), who owns Transaction work: sees the
> Transaction application and Transaction-related objects, has write access on Transaction and related
> data, with permission sets created for him. No dummy Transaction records — they should arise from the
> existing pipeline. Also send Danish an email notification when work arrives (stated as: when an
> Opportunity's stage is set to "About to Close").

### Business objective

DPEG needed a named individual (Danish) to own day-to-day work on Transactions — the ~75-task Day-0
checklist, critical dates, and wire tracking that begins the moment a deal's PSA is executed — without
giving him visibility into the rest of the pipeline (Disposition, Property Management, Lead/Broker
Protection). He also needed to be told proactively, by email, the moment a Transaction becomes his to
work, rather than having to notice one by checking the app.

### Summary

Most of what this request asked for already existed: the 2026-07-22 RBAC build had already designed
and deployed a complete Transaction-team access model (permission sets, a role, a criteria sharing
rule) — see §1 below for why this matters and what it changed about the work actually done. This
change closes the two real gaps that model didn't cover (`Property__c` read access and `RunReports`),
narrows the existing Transaction permission-set group to match the "nothing outside
Transaction/Opportunity/Property" scope decision, and adds the repo's first declarative email
notification (Email Alert + record-triggered Flow) — deliberately hooked to `Transaction__c` creation
rather than to the Opportunity stage the request literally named, because that stage does not reliably
fire for every deal. The user record itself, permission-set assignment, and two required public-group
memberships are in-org manual steps, tracked in the companion runbook.

---

## 1. This was mostly an assignment task, not an authoring task

Before writing anything, the design pass reconciled the request against what was already deployed in
`force-app/main/default/`. The result: **eight of the nine requested capabilities already existed**,
built as part of the 2026-07-22 RBAC program (`docs/rbac-access-model-standard.md`,
`agent-output/rbac-architecture-spec.md`).

| Requested capability | Status | What already covers it |
|---|---|---|
| Permission sets for a Transaction owner | Already existed | `DPEG_Transaction_Edit`, `DPEG_App_Transaction` |
| A composed "everything Danish needs" persona | Already existed | PSG `DPEG_Transaction_Team` |
| Transaction app visibility | Already existed | `DPEG_App_Transaction` → app `Transaction` + 4 tabs |
| Write access on Transaction + related data | Already existed | `DPEG_Transaction_Edit` (create/read/update, no delete, View All) |
| Read-only Opportunity | Already existed | `DPEG_Opportunity_View` (61 fields, View All) |
| Role in the hierarchy | Already existed | `roles/Transactions_Coordinator.role-meta.xml` |
| Row access under `Transaction__c` OWD Private | Already solved | View All (read) + criteria sharing rule `Transaction_Team_All_RW` (edit) |
| Apex access for the Transaction UI | Already existed | `DPEG_Apex_Access` already grants `TransactionController` and `TransactionTaskController` — the only two classes the Transaction UI calls |
| Read-only `Property__c` | **Genuinely absent** | closed by this change — `DPEG_Property_View` |
| Reports/dashboards usability | **Genuinely absent** | closed by this change — `DPEG_Reports_Access` |
| The user record | **Genuinely absent** | in-org, see the runbook |
| The email notification | **Genuinely absent**, and its stated trigger doesn't match the code | closed by this change, on a corrected trigger — see §2 |

**Why this matters for future readers:** anyone approaching a similar request ("create a permission
set so X can own Y") should check whether a persona for that module already exists before authoring a
new monolithic permission set. Building a fresh `Transaction_Access` set here would have duplicated a
working, already-tested access model and fragmented the org's permission-set taxonomy (the exact drift
`docs/rbac-access-model-standard.md` §2 exists to prevent).

---

## 2. The stated notification trigger did not match the code — and the design changed as a result

The request said the email should fire "once Opportunity stage sets to about to close." Tracing the
actual code showed three things that don't match that premise:

1. **Transactions are not created by an Opportunity stage change at all.**
   `ContractExecutionService.handleExecution` runs from `ContractReviewTrigger` (after update) and
   creates the `Transaction__c` when **`Contract_Review__c.Negotiation_Status__c` becomes
   `'Executed'`** — i.e. at PSA execution, a Contract Review event, not an Opportunity stage event.

2. **At that moment the Opportunity does not move to "About to Close."** The service's own header
   documents this deliberately: the deal stays at the coarse `PSA` stage; `Contract_Signed__c` and
   `Deal_Status__c = 'Contract Signed'` are stamped instead. `StageName` is untouched.

3. **"About to Close" is an optional off-ramp many deals never enter.**
   `StageAdvanceService.NEXT_STAGE` maps `'PSA' => 'Closed Won'` — the primary Advance button skips
   "About to Close" entirely. It is reachable only through the separate `Move to About to Close` quick
   action. Building literally to the request would mean the email fires late (days after the
   Transaction and its ~75-task checklist already exist) for the deals that pass through that stage,
   and **never fires at all** for every deal that goes `PSA → Closed Won` directly.

A notification already exists at the true creation moment — `ContractExecutionService` already calls
`GroupNotifier` ("PSA executed - transaction opened") to the `Transactions_Team` group — but that is a
**Custom Notification** (desktop/mobile push), which cannot send email. So the request for an email
was still legitimate; only the *timing* needed correcting.

**Decision made (with the user):** hook the email to **`Transaction__c` after-insert** instead of the
Opportunity stage change. This fires exactly once, for every Transaction, at the moment Danish
actually has work — and needs no `ISCHANGED`-equivalent logic, cannot double-fire, and is immune to
future changes in the stage model. The Opportunity-stage variant remains documented in the design as
an alternative (option a) in case a literal "About to Close" marker email is wanted later, but it was
not built.

---

## 3. Ownership is not what grants Danish access — and the intuitive reasoning is wrong

`Transaction__c` and `Critical_Date__c` are both `<sharingModel>Private</sharingModel>`. Twenty-eight
objects across this org are OWD Private, so the natural conclusion is "Danish needs a role, a sharing
rule, or record ownership, or he'll see nothing." **That conclusion is wrong for this persona**, and
acting on it would have produced an unnecessary new sharing rule:

- **Read** comes from `<viewAllRecords>true</viewAllRecords>` on `DPEG_Transaction_Edit` (on both
  `Transaction__c` and `Critical_Date__c`). View All overrides OWD Private for read, unconditionally.
- **Edit** comes from the already-deployed criteria sharing rule `Transaction_Team_All_RW`
  (`sharingRules/Transaction__c.sharingRules-meta.xml`, `accessLevel = Edit`, criteria
  `Stage__c notEqual <blank>`, shared to public group `DPEG_Transactions_Team`), and its twin
  `Critical_Date_Team_All_RW` on `Critical_Date__c` via `Type__c`.

Because `ContractExecutionService` always inserts a Transaction with `Stage__c = 'Open Contract'`,
every pipeline-created Transaction matches the sharing-rule criteria immediately.

**Net effect: Danish sees and edits every Transaction the moment his permission-set group and group
memberships are in place, while owning none of them.** No new role, no new sharing rule, and no
ownership transfer was created or is required for access. (`Transactions_Coordinator` role is still
assigned — not for visibility, but so the role hierarchy keeps `DPEG_Principal` able to see anything
Danish personally owns, and for consistency with every other DPEG persona having a role.)

---

## 4. Two similarly-named groups are both required, for two unrelated reasons

Group membership is data, not metadata (`.group-meta.xml` carries only `name`/`doesIncludeBosses`, no
members) — so this is an in-org step, but it is the single highest-probability way to get this rollout
wrong, and is worth documenting precisely:

| Group | Consumed by | Consequence of omitting Danish |
|---|---|---|
| `DPEG_Transactions_Team` | sharing rules `Transaction_Team_All_RW` / `Critical_Date_Team_All_RW` | He can **read** every Transaction (View All) but **cannot edit** any — a confusing "read-only despite holding an Edit permission set" symptom |
| `Transactions_Team` (`doesIncludeBosses=true`) | the pre-existing `GroupNotifier` custom notification, and the **new** `Transaction_Opened_Notification` email alert built in this change | He gets no "PSA executed" push notification and no Transaction-opened email — the app works, he's just never told anything landed |

Neither group is deployable metadata, so neither omission produces a deploy error — both fail silently
in the org. This is called out explicitly in the runbook (step c/d) and repeated here because it is the
single most important operational risk in this change.

---

## 5. `DPEG_PropertyAsset_View` vs the new `DPEG_Property_View` — same shape of name, different object

`DPEG_Transaction_Team` (as deployed 2026-07-22) originally included `DPEG_PropertyAsset_View`, which
grants **`Property_Asset__c`** — the **Property Management** module's object. It does **not** grant
`Property__c`, the **Acquisitions** object that the Transaction record page actually references via
`Record.Property__r.*`.

The Transaction record page (`flexipages/Transaction_Record_Page.flexipage-meta.xml`) has a "Property"
tab spanning six cross-object fields — `Property__r.Name`, `Property__r.Address__c`,
`Property__r.Asking_Price__c`, `Property__r.Square_Footage__c`, `Property__r.State__c`,
`Property__r.Cap_Rate_Asking__c` — and nothing in the pre-existing `DPEG_Transaction_Team` composition
granted `Property__c` object read. Without a fix, **that entire tab renders blank for Danish while
working perfectly for the admin who tests it** — because an admin's own profile grants pass FLS checks
that Danish's `Minimum Access – Salesforce` profile does not (see §6).

The only existing sets that grant `Property__c` read (`DPEG_Acquisition_View`, `DPEG_Acquisition_Edit`,
`DPEG_Acquisitions`) each also grant `Lead` and ten other Acquisition objects (`LOI__c`,
`Underwriting__c`, `Contract_Review__c`, `NDA__c`, …) — reusing any of them would have violated the
pre-confirmed decision that Danish sees nothing outside Transaction/Opportunity/Property. That is why a
new, narrowly-scoped `DPEG_Property_View` was built instead of reusing an existing block.

---

## 6. Admin acceptance testing proves nothing for this persona

FLS truth lives in the org itself, not in this repo — profiles are `.forceignore`d, so an admin's own
profile carries field grants an admin will pass without noticing, while `Minimum Access – Salesforce`
(Danish's profile) grants nothing at all; every grant Danish gets comes from the permission-set group.
An administrator testing the Transaction record page will see a fully populated Property tab and a
working Reports tab regardless of whether `DPEG_Property_View` or `DPEG_Reports_Access` were ever
actually assigned to Danish. **The only valid acceptance test is logging in as Danish** (or using
"Login As" from his user detail page) — this is codified as a required step in the companion runbook,
not a suggestion.

---

## 7. Components created and modified

### New — Permission Sets

| API Name | Label | Grants | Why it's new |
|---|---|---|---|
| `DPEG_Property_View` | Property – View Only | `Property__c`: read + View All, no create/edit/delete/modify-all; FLS `readable=true, editable=false` on all 35 `Property__c` fields (the object has no required or master-detail fields, so none were excluded) | Closes the blank-Property-tab gap in §5. Named by object (`Property`), not by team, per `docs/rbac-access-model-standard.md` §2 — reusable by any future team that needs to reference the acquisition property without owning it. Was already pre-authorized as an optional building block in that standard's §3; this change is what makes it real. |
| `DPEG_Reports_Access` | DPEG Reports Access | `userPermissions`: `RunReports` only | No permission set in the repo granted `RunReports` before this — `DPEG_App_Transaction` makes the `standard-report` and `Transaction_Dashboard` tabs *visible*, but visibility without `RunReports` means the tabs render and do nothing. Kept as its own block (rather than folded into `DPEG_Base_Access`) so the grant stays opt-in per team instead of becoming an org-wide privilege change. |

### Modified — Permission Set Group

| Component | Change |
|---|---|
| `DPEG_Transaction_Team` (PSG) | **Removed:** `DPEG_PropertyAsset_View` (Property Management object — out of scope), `DPEG_Disposition_View`, `DPEG_App_Disposition` (Disposition module — out of scope). **Added:** `DPEG_Property_View`, `DPEG_Reports_Access`. Description updated to match the new composition. |

The PSG now composes exactly: `DPEG_Base_Access`, `DPEG_Apex_Access`, `DPEG_Transaction_Edit`,
`DPEG_Task_Edit`, `DPEG_Opportunity_View`, `DPEG_Property_View`, `DPEG_Reports_Access`,
`DPEG_App_Transaction` — one canonical Transaction-team persona, matching Transaction + Opportunity +
Property and nothing else, per the pre-confirmed decision. This was a deliberate amendment (not a new,
second PSG) specifically to avoid fragmenting the model into two near-identical Transaction personas;
it was confirmed safe because nobody else was assigned `DPEG_Transaction_Team` in `usman-dpeg` at the
time of the change (re-verify this before any future reuse of this pattern, per the runbook's closing
caveat).

### New — Email notification components (the repo's first of their kind)

| Component | File | Detail |
|---|---|---|
| Classic email template | `email/unfiled$public/Transaction_Opened_Notification.email` (+ `.email-meta.xml`) | Plain-text template. Subject: `New Transaction opened – {!Transaction__c.Name}`. Body merges `Transaction__c.Name`, `Transaction__c.Opportunity__r.Name`, `Stage__c`, `Target_Close_Date__c`, and a direct record link built from `$Api.Partner_Server_URL_80`. |
| Email Alert | `workflows/Transaction__c.workflow-meta.xml` → `<alerts><fullName>Transaction_Opened_Notification</fullName>` | Recipient: `<type>group</type>` → **`Transactions_Team`**, `senderType = CurrentUser`. **This is the first `<alerts>` entry that exists anywhere in this repo** — `Opportunity.workflow-meta.xml` previously held only `<fieldUpdates>`, and no other object's workflow file had an alert at all. Group recipient (rather than an individual user lookup) is deliberate — staffing changes become a group-membership edit in Setup, with no metadata change and no redeploy. |
| Record-triggered Flow | `flows/Transaction_Opened_Notify.flow-meta.xml` | `AutoLaunchedFlow`, `apiVersion 67.0`, `<status>Active</status>`. Trigger: object `Transaction__c`, `recordTriggerType = Create`, `triggerType = RecordAfterSave`, **no entry filter** — every new Transaction fires it. Single action: `actionType = emailAlert` calling `Transaction__c.Transaction_Opened_Notification` with `SObjectRowId = $Record.Id`. Modeled on the shape of `flows/PSA_Ready_Notify.flow-meta.xml`. |

**Note on sender identity:** `senderType = CurrentUser` means the email will appear to be sent from
whichever user's action ultimately triggered `ContractExecutionService` (i.e. whoever updated
`Contract_Review__c.Negotiation_Status__c` to `'Executed'`), not from a dedicated system address. This
is standard Email Alert behavior and was not flagged as a defect, but is worth knowing if the "From"
address is ever questioned during UAT.

### Not created (explicitly, by design)

- No Apex class, trigger, test class, or LWC. The Transaction UI's only two Apex entry points
  (`TransactionController`, `TransactionTaskController`) already exist and are already granted by
  `DPEG_Apex_Access`; `ContractExecutionService`, `TaskFanoutService`, and `TaskRollupService` are
  trigger/flow-invoked and run in system context, needing no `classAccesses` grant.
- No new role, sharing rule, public group, or validation rule — all pre-existed or were not requested.
- No seed data. `scripts/seed-transactions.apex` was not invoked and is not part of this change;
  Transactions arise only from the live `ContractExecutionService → Transaction_Task_Fanout →
  TaskFanoutService` Day-0 path.
- No `Transaction__c.OwnerId` assignment element in the Flow — ownership is not required for
  visibility (see §3), and adding one would have solved a problem that does not exist.

---

## 8. Data flow

### Access model

```
Danish (User)
  Profile: Minimum Access - Salesforce   (grants nothing directly)
  Role:    Transactions Coordinator      (→ parent role DPEG_Principal; not used for visibility here)
      │
      ▼
  Permission Set Group: DPEG_Transaction_Team
      ├── DPEG_Base_Access        → LightningExperienceUser
      ├── DPEG_Apex_Access        → TransactionController, TransactionTaskController, ...
      ├── DPEG_Transaction_Edit   → Transaction__c + Critical_Date__c: C/R/U, no delete, View All
      ├── DPEG_Task_Edit          → Task: C/R/U (no Event — see Known Limitations)
      ├── DPEG_Opportunity_View   → Opportunity: read, View All
      ├── DPEG_Property_View      → Property__c: read, View All              [NEW]
      ├── DPEG_Reports_Access     → RunReports                                [NEW]
      └── DPEG_App_Transaction    → app Transaction + 4 tabs

Separately — public group membership (data, not metadata; not covered by the PSG):
  DPEG_Transactions_Team  → consumed by sharing rules Transaction_Team_All_RW /
                             Critical_Date_Team_All_RW → grants EDIT on every Transaction/Critical Date
                             whose Stage__c / Type__c is non-blank
  Transactions_Team       → consumed by GroupNotifier (existing custom notification) AND the new
                             Transaction_Opened_Notification email alert
```

### Notification flow

```
Contract_Review__c.Negotiation_Status__c → 'Executed'   (PSA execution)
            │
            ▼
ContractExecutionService.handleExecution   (ContractReviewTrigger, after update)
            │
            ├── stamps Opportunity: Contract_Signed__c = true, Deal_Status__c = 'Contract Signed'
            │   (StageName stays at 'PSA' — NOT 'About to Close')
            │
            ├── creates Transaction__c   (Stage__c = 'Open Contract', idempotent)
            │         │
            │         ├──▶ Transaction_Task_Fanout Flow → TaskFanoutService
            │         │       (creates the ~75-task Day-0 checklist)
            │         │
            │         └──▶ [NEW] Transaction_Opened_Notify Flow (RecordAfterSave, Create, no filter)
            │                       │
            │                       ▼
            │               Email Alert: Transaction__c.Transaction_Opened_Notification
            │                 recipient = group Transactions_Team
            │                       │
            │                       ▼
            │               Template: unfiled$public/Transaction_Opened_Notification
            │                       │
            │                       ▼
            │               Inbox: usmanblogs7@gmail.com (Danish — via Transactions_Team membership)
            │
            └── GroupNotifier → Custom Notification "PSA executed - transaction opened"
                    to group Transactions_Team (desktop/mobile push — pre-existing, unchanged)
```

---

## 9. File locations

| Component | Path |
|---|---|
| New permission set | `force-app/main/default/permissionsets/DPEG_Property_View.permissionset-meta.xml` |
| New permission set | `force-app/main/default/permissionsets/DPEG_Reports_Access.permissionset-meta.xml` |
| Amended permission set group | `force-app/main/default/permissionsetgroups/DPEG_Transaction_Team.permissionsetgroup-meta.xml` |
| New email template | `force-app/main/default/email/unfiled$public/Transaction_Opened_Notification.email` and `.email-meta.xml` |
| New email alert | `force-app/main/default/workflows/Transaction__c.workflow-meta.xml` |
| New flow | `force-app/main/default/flows/Transaction_Opened_Notify.flow-meta.xml` |
| In-org runbook (user, PSG assignment, group memberships, acceptance test) | `docs/2026-08-04-danish-transaction-onboarding.md` |
| Adopted RBAC standard (amended alongside this change — see §12) | `docs/rbac-access-model-standard.md` |
| Full design record and resolved open-questions log | `agent-output/design-requirements.md` |
| Existing sharing rule this change relies on (unmodified) | `force-app/main/default/sharingRules/Transaction__c.sharingRules-meta.xml` |
| Existing reference flow this new flow was modeled on | `force-app/main/default/flows/PSA_Ready_Notify.flow-meta.xml` |

---

## 10. Security

- **Sharing model:** `Transaction__c` and `Critical_Date__c` are OWD Private (unchanged by this
  change). Read is granted org-wide-within-team via `viewAllRecords=true` on `DPEG_Transaction_Edit`;
  edit is granted via the pre-existing criteria sharing rule `Transaction_Team_All_RW` /
  `Critical_Date_Team_All_RW` to public group `DPEG_Transactions_Team`. `Property__c` is likewise OWD
  Private, and `DPEG_Property_View` grants read via `viewAllRecords=true` rather than a sharing rule
  (matching the pattern every other `_View` block in this org uses).
- **Profile:** `Minimum Access – Salesforce` — grants nothing on its own; every capability Danish has
  comes from the permission-set group, per the adopted standard in `docs/rbac-access-model-standard.md`
  §1.
- **Delete:** deliberately **not** granted on `Transaction__c`. This matches the org-wide convention
  (`docs/rbac-access-model-standard.md` §2: `Edit` = create/read/update, no delete; `Manage` = full
  including delete). If delete access is genuinely needed later, that is a new `DPEG_Transaction_Manage`
  block, not an edit to `DPEG_Transaction_Edit`.
- **Record types:** no `recordTypeVisibilities` entries were added anywhere in this change. Record type
  visibility governs what a user may *select* when creating/editing a record; it does not gate read,
  and Danish's Opportunity access is read-only.
- **No Apex, no SOQL, no DML introduced.** This entire change is declarative metadata (permission sets,
  a permission set group, an email template, a workflow alert, and a record-triggered flow). The
  Apex layering rules and the 251-record bulk-test rule do not apply — there is no code to test.

---

## 11. Known limitations, deferred items, and caveats (carried forward, not introduced by this change)

These are documented decisions, not oversights — each is called out here so it is not later mistaken
for a bug in this change.

- **The Edit sharing rule keys on `Stage__c != blank`.** If a Transaction's `Stage__c` is ever cleared,
  the entire Transactions team — Danish included — silently drops to read-only on that record, with no
  error surfaced anywhere. Pre-existing behavior from the 2026-07-22 build; not altered here.
- **`DPEG_Task_Edit` grants `Task` only, not `Event`.** `Transaction__c` has `enableActivities=true`
  and its record page carries the standard Activity panel, but the Event half (New Event / calendar)
  will be unavailable to Danish. Not requested; flagged as a probable, expected UAT observation, not a
  defect to fix in this change.
- **`Transaction__c.Owner_Name__c` is a plain Text field, not a formula on `OwnerId`.** Only
  `scripts/seed-transactions.apex` populates it (hardcoded to `'Danish'` in that script).
  `ContractExecutionService` never sets it. The "Owner" column in the `activeTransactionsList` LWC will
  therefore be **blank on every real, pipeline-created Transaction**. This is a pre-existing display
  defect, reported for awareness and deliberately **not** folded into this change's scope.
- **Delete on `Transaction__c` was deliberately not granted** — see §10.
- **`DPEG_Reports_Access` grants only the `RunReports` user permission.** Whether Danish can actually
  *see* the Transaction Dashboard and its underlying reports is governed by **report/dashboard folder
  sharing**, which is an in-org configuration step (Setup → Reports/Dashboards → folder → Share), not a
  metadata permission. If the relevant folder isn't already broadly shared, that folder-sharing step
  must happen before the acceptance test's Reports/Dashboard checks can pass — this is called out as
  its own step in the companion runbook.
- **Group-membership omission is the highest-probability post-deploy defect in this change** — see §4.
  Both required-but-different groups (`DPEG_Transactions_Team` for edit, `Transactions_Team` for
  notifications) must be populated in Setup; neither is deployable metadata and neither omission
  produces a deploy-time error.
- **If anyone else is ever assigned `DPEG_Transaction_Team`**, they will inherit exactly the same
  amended composition Danish gets (losing Property Management + Disposition access, gaining Property
  and Reports access). This was confirmed safe at the time of this change (nobody else was assigned the
  PSG in `usman-dpeg`) but should be re-verified before this PSG is reused for a future hire, per the
  runbook's closing note.

---

## 12. ARCHITECTURE.md assessment (per §6)

**Conclusion: no `ARCHITECTURE.md` edit is warranted for this change.** Reasoning, checked against each
of §6's stated triggers:

- **No custom object was added or modified.** `Property__c`, `Transaction__c`, and `Critical_Date__c`
  are all pre-existing objects; §1's "Current objects" tables are unaffected.
- **No new Apex service was introduced**, and no existing service's responsibility changed. This
  change reuses `ContractExecutionService`, `TaskFanoutService`, and `TaskRollupService` exactly as
  they already exist; §2's "Key Apex Services" table needs no new row.
- **No external integration was wired.** Nothing in this change touches ASB, Plaid, Yardi, or any
  Named Credential; §3 is unaffected.
- The two genuinely new artifacts — the repo's first `<alerts>` entry and the `DPEG_Property_View` /
  `DPEG_Reports_Access` permission sets — are **RBAC and declarative-notification configuration**, not
  application architecture in the sense §1–§5 document (domain model, Apex layering, integration
  boundaries, LWC/UI patterns). The document that exists specifically to track this kind of change is
  `docs/rbac-access-model-standard.md` §3 ("Building blocks — deployed vs. to-add"), which **was**
  updated as part of this change: `DPEG_Property_View` is moved from "optional, to-add" to "deployed,"
  `DPEG_Transaction_Edit`/`DPEG_Opportunity_View` (found already live but still listed as "to add" —
  a stale entry from the 2026-07-22 baseline, fixed in the same pass) are moved to "deployed," and
  `DPEG_Reports_Access` is added as a new building block.
- If a future change introduces a **second** Email Alert / record-triggered-notification pattern
  elsewhere in the app, that would be the point at which "declarative notification pattern" becomes
  worth its own subsection in `ARCHITECTURE.md` §5 (LWC/UI) or a new §2-adjacent section — one instance
  does not yet constitute a documented convention.

---

## 13. Change history

| Date | Author | Change description |
|---|---|---|
| 2026-08-04 | Documentation Agent | Initial creation. Documents the Danish/Transaction-team access closure (`DPEG_Property_View`, `DPEG_Reports_Access`, amended `DPEG_Transaction_Team`) and the new `Transaction_Opened_Notification` email alert + flow. Also updated `docs/rbac-access-model-standard.md` §3 to reflect deployed status of the new and previously-stale building blocks. |
