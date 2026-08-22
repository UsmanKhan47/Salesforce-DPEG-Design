# USER DECISIONS - 2026-08-22 - BINDING, DO NOT RE-OPEN

Decided by the user AFTER this design was written. Where they conflict with anything below, these win.

| # | Decision |
|---|---|
| D-ON-1 | Auto-create uses allOrNone = false plus error logging and an admin alert. An Onboarding failure must NEVER roll back the Opportunity close. |
| D-ON-2 | Auto-create keys on Property_Asset__c.Closing_Date__c transitioning to non-null. Verified: PropertyAssetService.cls:361 is its ONLY writer, and TestDataFactory + all 9 seed scripts leave it blank, so the existing suite and seeds are immune by construction. |
| D-ON-3 | Task definitions stay in Custom Metadata (Onboarding_Task_Def__mdt), mirroring Transaction_Task_Def__mdt. That is a definition table, the correct CMDT use. Runtime CONFIG elsewhere uses Hierarchy Custom Settings - do not confuse the two. |
| D-ON-4 | Accepted: S3 formula conversion is a delete-and-recreate, narrowed to the two genuinely time-dependent fields via NEW api names, in a separate gated wave. Five candidate fields carry editable=true in DPEG_PropertyMgmt_Edit and would fail the deploy as formulas. |
| D-ON-5 | STILL OWED BY THE USER: the 2 missing Performance Tracking task names (seed has 45, FSD says 47). Ship 45 real rows plus 2 explicit gaps. DO NOT INVENT THEM. |
| D-ON-6 | Onboarding__c is Private OWD. SYSTEM_MODE lifts CRUD/FLS but never sharing - the fan-out idempotency read and flag write need a narrow "private without sharing" inner class, or the guard inverts into a duplicate-maker. Auto-created records must set Status__c explicitly; a blank status hides the record from the whole PM team under the existing sharing rule. |
| D-ON-7 | GroupNotifier hardcodes Acquisitions_Deal_Update (GroupNotifier.cls:22) so a PM alert arrives branded "Acquisitions - Deal Update". Parameterise the notification type and add a PM CustomNotificationType. An empty groups/*.group-meta.xml is NOT proof of no members - membership is not deployable. |

---

# DESIGN REQUIREMENTS — PM Onboarding: Checklist Fan-Out, 2 Defects, Auto-Create

**Scope tag:** `onboarding-checklist` · **Branch:** `feature/disposition-redesign` · **Date:** 2026-08-22
**Do NOT merge with** `agent-output/design-requirements.md` — two other design agents are running concurrently.

---

## 0. RULE GATES (`.claude/rules/salesforce-global-rule.md`)

```
intent=app | best_matched_skill=none (design phase — no metadata written by this agent) | skill_selection=complete
mcp=unavailable | mcp_tools=none
```

`salesforce-api-context` is **not configured in this repo** — `.mcp.json` declares only the `salesforce`
server, and subagents carry no MCP tools at all. Every implementing agent must record
`mcp=unavailable` after a real attempt and fall back to the per-type skill. Where the XML shape of a
metadata type cannot be confirmed from an in-repo precedent, **stop and escalate — do not guess.**

**Metadata types in scope, dependency order** (each needs its own skill-load + MCP attempt):
`CustomObject (__mdt)` → `CustomField` → `CustomMetadata records (via Apex loader, NOT files)` →
`ApexClass` → `ApexTrigger` → `Flow`.

---

## 1. WHAT THE USER REQUESTED

Four items, exactly as briefed. Nothing below adds a feature, a validation rule, a permission set, a
report, a dashboard, an LWC or a test scenario that was not asked for.

| # | Item |
|---|---|
| **S1** | Checklist fan-out — CMDT-driven, fires on `Onboarding__c` creation, idempotent, bulk-safe at 251 |
| **S2** | Defect: completing a task overwrites `ActivityDate` (the due date). Add a separate auto-set Completed Date |
| **S3** | Defect: rollups fire from one LWC only. Route `Onboarding__c` through `TaskRollupTrigger`; convert derivable fields to formulas where possible |
| **S4** | Auto-create `Onboarding__c` on full acquisition + notify the PM team via `GroupNotifier` |

---

## 2. BRIEF PREMISES — VERIFIED, WITH THREE CORRECTIONS

Everything the brief asserted about current state was re-checked. **Confirmed:** the 45-row seed, the
missing fan-out, the standard-`Task` model, the 7 restricted `Onboarding_Category__c` values, the
`OnboardingService.cls:43` `ActivityDate` overwrite, `TaskRollupTriggerHandler` routing only
`Transaction_Deal__c`, `Is_Past_Target__c` being a manual Checkbox nothing writes,
`Days_To_Onboard__c`/`Age_Days__c`/`Oldest_Open_Days__c` being plain Numbers nothing writes,
`GroupNotifier` having zero PM callers, and `DPEG_Property_Mgmt_Team` existing as a public group.

Three things the brief did not know, each of which changes the design:

### 🔴 C1 — "Convert the derivable fields to formulas" is a DELETE + CREATE, not an edit

**Salesforce cannot convert an existing custom field into a Formula field.** There is no in-place
type change to Formula in the UI or the Metadata API. Every "conversion" in S3 is really: sever all
references → delete → **ERASE in Setup (manual, irreversible)** → create → restore. And the blast
radius, measured (not inferred from production classes alone — see
`.claude/agent-memory-local/salesforce-design/stored-to-formula-is-a-suite-wide-compile-break.md`):

| Consumer | Fields it **assigns** | Consequence |
|---|---|---|
| `classes/OnboardingControllerTest.cls:10,11,18,19` | `Days_To_Onboard__c`, `Age_Days__c`, `Oldest_Open_Days__c`, `Is_Past_Target__c` | **Compile error → whole suite down → every `RunLocalTests` deploy fails** |
| `classes/OnboardingSelectorTest.cls:35-38` | same four | same |
| `classes/OnboardingTaskRollupService.cls:15,39` | `Completion_Pct__c` | same |
| `scripts/seed-onboarding.apex:29-63` | all five | runtime failure of the seed script |
| `permissionsets/DPEG_PropertyMgmt_Edit.permissionset-meta.xml:455-481` | `<editable>true</editable>` on **all five** | **`editable=true` on a formula field is a DEPLOY ERROR** — and this is a **hub file** (§3) |

Not a blocker: `profiles/**` is force-ignored (`.forceignore:28`), so the three profile references
(`Cross Org Data Proxy User`, `Work%2Ecom Only User`, `CPQ Integration User`) never deploy.
`manifest/package.xml` is a retrieve manifest, not a deploy gate.

**Consequence for scope:** §6 recommends the 2-wave *new-API-name* path (create new formula fields
alongside, repoint readers, retire the old) over the 5-wave erase-and-reuse path, and narrows the
conversion to the two fields that are genuinely broken by being stored. See §6.3.

### 🔴 C2 — `Property_Asset__c` has NO "fully acquired" field. The real signal is upstream, and there is a clean discriminator

`Property_Asset__c.Status__c` is a 2-value restricted picklist (`Active` / `Disposed`) — `Active` from
birth. There is no acquisition flag, no acquisition stage, and **no `Property_Asset__c` trigger** (the
`triggers/` directory confirms this, and `PropertyAssetService.cls:121-125` states it as a
deliberately-verified fact: *"Starts no downstream automation… no `Property_Asset__c` trigger, no flow
with it as the start object"*).

The actual handoff is `PropertyAssetService.ensureOnClosedWon`, called from
`OpportunityReviewTriggerHandler` when an `Opportunity` **enters** `StageName = 'Closed Won'`. That
service is the ONLY thing in the codebase that creates a `Property_Asset__c` outside tests and seeds.

**The discriminator (measured, and it is the load-bearing fact of S4):**
`PropertyAssetService.cls:361` is the **only** writer of `Property_Asset__c.Closing_Date__c`.
- `TestDataFactory.cls:1350-1361` (`createPropertyAssets`, the ancestor of every asset in the ~66
  test classes that touch the object) does **not** set it.
- The nine seed scripts do not set it — every `Closing_Date__c` hit in `scripts/` is
  `Disposition__c.Closing_Date__c`, a different object.

So **"fully acquired" = a `Property_Asset__c` whose `Closing_Date__c` is not null**, and keying S4 on
that makes the entire existing test suite and every seed script immune **by construction** — they
create assets with a blank Closing Date and mint no Onboarding. Without this key, S4 would fire 45
Tasks per asset across ~66 test classes and 9 seed scripts. This is the single most important
constraint in the build; state it in the implementing class header.

⚠ Residual: an asset created manually (or by a future path) and given a Closing Date *later* gets no
Onboarding, because the recommended trigger context is `after insert` only. Named in §7 (OQ-8).

### 🟡 C3 — `TaskRollupTrigger` has NO before context, and `Onboarding_Lead__c` is Text, not a User lookup

- `triggers/TaskRollupTrigger.trigger:6` is `(after insert, after update, after delete, after
  undelete)`. S2's Completed-Date stamp needs a **before** context. Expanding that context list is its
  own dev item with its own org-wide blast radius (§5, D5) — and the trigger's own header comment
  ("Updates only `Transaction__c`, so no Task re-entry") becomes incomplete and must be corrected in
  place.
- `Onboarding__c.Onboarding_Lead__c` is **`Text(120)`**, not `Lookup(User)` as FSD 5.1.4 implies —
  `scripts/seed-onboarding.apex` assigns the string `'Isha Patel'` to it. So S4 has no User to assign
  as lead, and S1 has no lead to own the fanned-out Tasks. Fan-out must use `Onboarding__c.OwnerId`
  (mirroring `TaskFanoutService.cls:117`, `tk.OwnerId = t.OwnerId`). OQ-7.

---

## 3. 🚫 HUB FILE REQUESTS (for the main agent to consolidate — NOT edited by this build)

No `applications/`, `tabs/` or `permissionsets/` file is touched by this design. **No new tab and no
app-nav entry is needed** — the only new object is a `__mdt`, which has no tab, and `Onboarding__c` is
already on the Property Management app. The complete hub ask is field-level security:

| Hub file | Requested change | Why |
|---|---|---|
| `permissionsets/DPEG_PropertyMgmt_Edit.permissionset-meta.xml` | Add `Onboarding__c.Tasks_Fanned_Out__c` — `readable=true`, **`editable=false`** | New idempotency marker. Editable=false deliberately: it is written by automation in `SYSTEM_MODE`; a human must not be able to clear it and re-mint 45 duplicate tasks |
| `permissionsets/DPEG_PropertyMgmt_View.permissionset-meta.xml` | Add `Onboarding__c.Tasks_Fanned_Out__c` — `readable=true`, `editable=false` | Read parity with the other 20 `Onboarding__c` fields already listed there |
| `permissionsets/DPEG_Task_Edit.permissionset-meta.xml` | Add `Task.Onboarding_Completed_Date__c` — `readable=true`, **`editable=false`** | S2 field. Trigger-stamped only; a hand edit would defeat the "auto-set on completion" requirement |
| `permissionsets/DPEG_PropertyMgmt_View.permissionset-meta.xml` **and** `_Edit` | Add the new S3 formula fields (names per OQ-3) — `readable=true`, **`editable=false` in BOTH** | 🔴 `editable=true` on a formula field is a **deploy error**. In-repo precedent for the correct shape: `Broker_Display__c` / `Selected_Broker__c` are `editable=false` |
| `permissionsets/DPEG_PropertyMgmt_Edit.permissionset-meta.xml` | **Only if OQ-3 chooses erase-and-reuse:** flip `Onboarding__c.Is_Past_Target__c` / `Age_Days__c` (lines 455-481) from `editable=true` to `editable=false` | Same deploy-error rule |

🔴 **Two standing hub hazards to carry into the consolidation pass:**
1. A `PermissionSet` deploy **REPLACES** the entire `<fieldPermissions>` set. Diff against `HEAD`
   before deploying, or the other two concurrent builds' grants disappear silently.
2. `groups/DPEG_Property_Mgmt_Team.group-meta.xml` carries **no membership** — `Group` metadata never
   does. If the group is empty in the target org, `GroupNotifier` falls back to the group's own Id,
   which is documented as *"proven to work for queues"* — this is a **Regular** group, so the fallback
   may raise `Invalid parameter value for: recipientIds`, which `GroupNotifier` catches and degrades
   to a `System.debug`. **S4's notification then fails silently and forever.** Post-deploy gate, §8.

---

## 4. 🔵 ADMIN / DECLARATIVE WORK

### A1 — CMDT: `Onboarding_Task_Def__mdt` (S1)

`<visibility>Public</visibility>`, mirroring `Transaction_Task_Def__mdt.object-meta.xml`.
All fields `<fieldManageability>DeveloperControlled</fieldManageability>` (copy
`Transaction_Task_Def__mdt/fields/Due_Day_Offset__c.field-meta.xml` for the exact XML shape).

| Field | Type | Notes |
|---|---|---|
| `Category__c` | Text(60) | 🔴 **Must be one of the 7 `Onboarding_Category__c` values verbatim.** That picklist is `<restricted>true</restricted>`, and restricted picklists **are enforced by DML in this org** — an off-list value fails the insert, it is not silently stored |
| `Subject__c` | Text(255) | The checklist item text |
| `Sequence__c` | Number(4,0) | Global 1…45. Stamped onto `Task.Task_Sequence__c` |
| `Owner_Label__c` | Text(80) | Stamped onto `Task.Task_Owner_Label__c` |
| `Source_System__c` | Text(40) | 🔴 Must be one of `Yardi` / `Excel` / `Salesforce` / `Email` — `Task.Source_System__c` is also `<restricted>true</restricted>` |
| `Due_Day_Offset__c` | Number(4,0) | Days from `Onboarding__c.Start_Date__c`. See OQ-2 |
| `Default_Status__c` | Text(40) | Maps to `Task.Onboarding_Status__c`; blank ⇒ `'Not Started'` |
| `Conditional__c` | Checkbox | Parity with the Transaction pattern; all rows `false` today (OQ-6) |

**⚠ Deliberate deviation from the Transaction pattern — needs sign-off (OQ-1).** The Transaction
build uses **two** CMDTs (`Task_Group_Def__mdt` + `Transaction_Task_Def__mdt`) joined on `Letter__c`,
because its groups carry a letter, a display name, a conditional gate and a gating field name, and the
`Task_Group__c` picklist string is composed as `Letter + '. ' + Group_Name`. **None of that exists
here:** the Onboarding categories carry no letters (the repo deliberately dropped the FSD's A–G
prefixes), the category list is already an enumerated restricted picklist on both `Task` and
`Onboarding__c.Stage__c`, and no category is conditional. A second CMDT would hold seven rows of
`{name, sequence}` duplicating a picklist. **Recommend one CMDT.** The alternative (two CMDTs, exact
mirror) is available if the user prefers structural symmetry over minimalism.

### A2 — CMDT records: 45 rows, loaded by an Apex script, NOT by file (S1)

🔴 `.forceignore:16` — `**/customMetadata/**` — with the reason recorded in the file itself:
*"file-based deploy throws UNKNOWN_EXCEPTION in this org. Records are loaded via
`scripts/load-*-defs.apex` (Apex Metadata API)."* There is no `customMetadata/` directory in the repo
at all. **Do not create `.md-meta.xml` files.**

Deliverable: **`scripts/load-onboarding-task-defs.apex`**, mirroring
`scripts/load-transaction-task-defs.apex` + `scripts/load-task-group-defs.apex`
(`Metadata.DeployContainer` → `Metadata.Operations.enqueueDeployment`). Row shape
`{category, sequence, ownerLabel, sourceSystem, dueDayOffset, subject}`, upsert-keyed on `fullName =
'Onboarding_Task_Def.<DeveloperName>'` (DeveloperName ≤ 40 chars).

**Source of the 45 rows: `scripts/seed-onboarding-tasks.apex:8-58`, verbatim.** Counts verified by
reading the file: Property Set up 7 · Unit & Tenant Setup 14 · Vendor & Expense Management 8 · NNN
Reconciliation & Billing Setup 6 · Tenant Communication & Transition 6 · **Performance Tracking 1** ·
Leasing 3 = **45**. FSD 5.1.5 specifies 47 (Performance Tracking = 3). **The 2 missing task names are
NOT invented here** — OQ-1a.

⚠ Two operational facts: `Metadata.Operations.enqueueDeployment` is **asynchronous**, so the records
are not queryable the instant the script returns; and `sf apex run` is classifier-blocked for the main
agent — the loader must be executed by the devops subagent or by hand.

### A3 — `Onboarding__c.Tasks_Fanned_Out__c` (S1)

Checkbox, `<defaultValue>false</defaultValue>`. Byte-for-byte the shape of
`objects/Transaction__c/fields/Tasks_Fanned_Out__c.field-meta.xml`. This is the idempotency marker
the flow filters on and the service re-checks.

### A4 — `Activity.Onboarding_Completed_Date__c` (S2)

Type `Date`. Label **"Onboarding Completed Date"** — checked against every existing
`objects/Activity/fields/*.field-meta.xml` `<label>`; no collision (existing labels: Blocked Reason,
Onboarding Status, Onboarding Category, Owner Label, Task Group, Conditional, Inbound Message ID…).
Lives under `objects/Activity/fields/` (custom Task fields are declared on `Activity`, not `Task`).
Naming follows ARCHITECTURE §1: date-only ⇒ `Date` suffix, never `DateTime`.

### A5 — Flow `Onboarding_Task_Fanout` (S1)

Direct mirror of `flows/Transaction_Task_Fanout.flow-meta.xml`:
`processType=AutoLaunchedFlow`, `triggerType=RecordAfterSave`, `recordTriggerType=CreateAndUpdate`,
`doesRequireRecordChangedToMeetCriteria=true`, `apiVersion=67.0`, `status=Active`, one `actionCalls`
of `actionType=apex` / `actionName=OnboardingFanoutService` passing `$Record.Id`.

Start filters (`filterLogic=and`), mirroring the Transaction shape exactly:
- `Start_Date__c` `IsNull` `false`
- `Tasks_Fanned_Out__c` `EqualTo` `false`

⚠ Why `CreateAndUpdate` rather than Create-only, despite the brief saying "fires on creation": the
due dates are `Start_Date__c + Due_Day_Offset__c`. An Onboarding created with a blank Start Date would
fan out 45 tasks with **null due dates** and then be permanently flagged, which is exactly the
`Contract_Executed_Date__c` case the Transaction filter exists to prevent. S4 always supplies a Start
Date, so on the automated path this still fires on creation.

### A6 — S3 formula fields

Deferred to §6.3 / OQ-3 — the field names and the retire-vs-reuse choice are the user's decision, and
the permission-set consequences are hub work (§3).

---

## 5. 🟢 DEVELOPMENT / APEX WORK

All classes `with sharing` unless a header justifies otherwise; all SOQL in selectors; no SOQL/DML in
loops; every public method takes collections. `.claude/rules/apex-layering-rule.md` applies throughout.

### D1 — `OnboardingTaskDefProvider.cls` — layer=provider (S1)

Direct mirror of `TaskGroupDefProvider.cls`. **NOT a selector**: Custom Metadata is not subject to FLS
or sharing, `WITH USER_MODE` is inert on `__mdt`, and the `sf-apex` rule mandates
`getAll()`/`getInstance()` over SOQL. One method,
`getAllOrderedByCategoryAndSequence()`, returning `Onboarding_Task_Def__mdt.getAll().values()` with an
in-memory `System.Comparator` sort (copy `TaskGroupDefProvider.SequenceComparator`, including its
nulls-first semantics).

### D2 — `OnboardingFanoutService.cls` — layer=service (S1)

Mirrors `TaskFanoutService.cls`. **Mirror the skeleton, not the body** — the Transaction body's
group-letter join and conditional gate have no counterpart here.

- `@InvocableMethod fanOut(List<InputDTO> requests)` returning `void`; `InputDTO` is an inner class
  with one `@InvocableVariable(required=true) Id onboardingId`. `.claude/rules/invocable-rule.md`:
  List-in, `void` or List-out, DTO inner class — matches the Transaction precedent exactly.
- De-dupes the incoming ids, then **exactly one** `System.enqueueJob(new
  OnboardingFanoutQueueable(ids, 0))`.
- `fanOutNow(List<Id> onboardingIds)` is the synchronous worker: read defs from D1, read Onboardings
  from D4, skip any with `Tasks_Fanned_Out__c == true` (unless the `@TestVisible bypassDedupe` seam is
  set), build Tasks, one bulk insert, one bulk flag update.
- Task field mapping: `Onboarding__c` = parent id (**the custom lookup, never `WhatId`** — that is what
  keeps checklist tasks off the Activity timeline, per `TaskFanoutService.cls:115`) ·
  `OwnerId` = `Onboarding__c.OwnerId` (C3) · `Subject` = `Subject__c` ·
  `Onboarding_Category__c` = `Category__c` · `Task_Sequence__c` = `Sequence__c` ·
  `Task_Owner_Label__c` = `Owner_Label__c` · `Source_System__c` = `Source_System__c` ·
  `Conditional__c` = `Conditional__c` · `Onboarding_Status__c` = `Default_Status__c` ?? `'Not Started'` ·
  `Status` = `'Open'` (the seed's convention: `'Completed'` only when complete) ·
  `ActivityDate` = `Start_Date__c.addDays(Due_Day_Offset__c)` when `Start_Date__c != null`.
- 🔴 **`Database.insert(tasks, true, AccessLevel.SYSTEM_MODE)` and `Database.update(flags, true,
  AccessLevel.SYSTEM_MODE)`.** Same argument as `TaskFanoutService.cls:134-145`: the flow declares no
  `<runInMode>`, so it runs as whoever saved the Onboarding — on the S4 path that is the **deal driver
  closing an Opportunity**, who holds `DPEG_PropertyMgmt_View` (read-only) and no Create on Task.
  `allOrNone = true` because a silently-absent checklist is the bug being fixed.
- 🔴 **`SYSTEM_MODE` does not lift sharing** (ARCHITECTURE §2). `Onboarding__c` is **Private OWD**
  (`Onboarding__c.object-meta.xml:165`), shared to `DPEG_Property_Mgmt_Team` only, and only where
  `Status__c != ''` (`sharingRules/Onboarding__c.sharingRules-meta.xml`). The flag update must run in
  a narrow `private without sharing` context. **This is not cosmetic: a sharing-filtered idempotency
  marker does not disable the feature, it inverts it into a duplicate-maker.**

### D3 — `OnboardingFanoutQueueable.cls` — layer=queueable (S1)

Direct mirror of `TaskFanoutQueueable.cls`, including the `ChainFinalizer` (chain advanced from the
Finalizer so a failed chunk does not strand the ones behind it) and the `Test.isRunningTest()` guard
on chaining. `CHUNK_SIZE = 100`.

**Why async — the arithmetic, which is different from the Transaction case and must be stated
honestly.** At 45 tasks per Onboarding a 200-record trigger chunk is 9,000 Task rows, which *fits*
under the 10,000 DML-row limit. It fits with **10% headroom and nothing else in the cascade**, and
three things immediately consume that headroom: the flag update, the `TaskRollupTrigger` after-insert
that D6 makes fire on all 9,000 new Tasks (its own selector read + `Onboarding__c` DML), and the 10s
synchronous CPU ceiling versus 60s async. The synchronous ceiling is 222 Onboardings — arithmetic, not
inefficiency. At `CHUNK_SIZE = 100` each job inserts ~4,500 rows.

### D4 — `OnboardingSelector.cls` — additions (S1, S4)

Two new methods. ⚠ **`WITH SYSTEM_MODE` on both, and the justification goes in the class header at
each method's own declaration** (ARCHITECTURE §2 — "the mode is a property of the METHOD, never of the
class"; the existing header currently asserts *"there is NO guest/automation path on `Onboarding__c`,
so NO `SYSTEM_MODE` appears here"* — **that sentence becomes false and must be corrected in place**).

- `selectByIdsForFanout(Set<Id> ids)` → `Id, OwnerId, Start_Date__c, Tasks_Fanned_Out__c`.
- `selectByPropertyAssetIds(Set<Id> assetIds)` → `Id, Property_Asset__c` (S4 idempotency read).

🔴 Both must sit in a **`private without sharing` inner class** — Private OWD, and both back
idempotency guards. Copy the shape and the header argument from
`PropertyAssetSelector.selectByPropertyIds`, which solved the identical problem one object over.

`selectActive()` is **not** modified by S1/S2/S4. S3 may touch its field list (§6.3).

### D5 — `TaskRollupTrigger` context expansion + `OnboardingTaskDomain.cls` — layer=domain (S2)

- `triggers/TaskRollupTrigger.trigger` becomes `(before insert, before update, after insert, after
  update, after delete, after undelete)`. **Correct the trigger's header comment**, which today
  describes an after-only, `Transaction__c`-only rollup.
- `TaskRollupTriggerHandler` gains `beforeInsert()` / `beforeUpdate()` overrides that delegate to a new
  pure Domain class.
- `OnboardingTaskDomain.stampCompletion(List<Task> newList, Map<Id,Task> oldMap)` — **zero SOQL, zero
  DML** (domain purity rule). Logic:
  - `if (t.Onboarding__c == null) continue;` ← the guard that keeps the org-wide blast radius at one
    field read per Task.
  - Entering `Onboarding_Status__c == 'Complete'` (insert: no prior; update: prior != 'Complete') and
    `Onboarding_Completed_Date__c == null` ⇒ set `Onboarding_Completed_Date__c = Date.today()`.
  - Leaving `'Complete'` ⇒ set `Onboarding_Completed_Date__c = null`.
  - **`ActivityDate` is never written.** That is the whole defect.
- `OnboardingService.completeTask` (`classes/OnboardingService.cls:43`): **delete
  `t.ActivityDate = Date.today();`**. The trigger now owns the completion stamp, so every write path —
  checklist LWC, standard UI, data loader, API — behaves identically.
- Late completion is then derivable as `Onboarding_Completed_Date__c − ActivityDate` (> 0 ⇒ late). **No
  `Days_Late__c` field is proposed** — it was not requested.
- ⚠ Why not standard `Task.CompletedDateTime`: the repo already measured it and rejected it —
  `DispositionTaskController.cls:63-65`, *"`Task.CompletedDateTime` is auto-stamped on close and never
  cleared on reopen."* A reopened checklist item would keep a stale completion date forever. It is also
  never written on the Onboarding path today because `Onboarding_Status__c`, not `Status`, is the field
  the checklist drives.

**Blast radius of D5, stated plainly:** `before insert` / `before update` now fire on **every Task in
the org** — the 82-task Transaction fan-out, Broker Protection pipeline Tasks, EAC companion Tasks,
Disposition closing Tasks, and every hand-created Activity. The `Onboarding__c == null` early return
makes the added cost one field comparison per Task, with no query, no DML and no possibility of a
`Database.update` failure. There is no cheaper way to make a stamp survive a standard-UI edit.

### D6 — `TaskRollupTriggerHandler` routes `Onboarding__c` (S3)

Add `collectOnboardingIds(List<Task>)` mirroring the existing `collectDealIds`, and call
`OnboardingTaskRollupService.recalc(...)` from all four after-contexts with the same
insert/undelete = new · delete = old · **update = new ∪ old** (re-parent must recompute the losing and
the gaining Onboarding) sourcing the existing handler documents.

### D7 — `OnboardingTaskRollupService.cls` — three fixes (S3)

1. 🔴 **`update upd.values();` (line 41) → `Database.update(upd.values(), true,
   AccessLevel.SYSTEM_MODE)` inside a narrow `private without sharing` context.** Today this only ever
   runs as a PM user completing their own checklist item, so it works. The moment D6 lands, **any**
   user who edits, deletes or undeletes a Task fires it — and `Onboarding__c` is Private OWD shared
   only to `DPEG_Property_Mgmt_Team`. `SYSTEM_MODE` alone lifts CRUD/FLS but **never sharing**; this
   exact combination has already produced a silent, `allOrNone=false`-swallowed failure on this project
   (see `.claude/agent-memory-local/salesforce-design/system-mode-dml-still-enforces-sharing.md`).
   Use `allOrNone = true` so it cannot fail silently.
2. **Remove the explicit `OnboardingTaskRollupService.recalc(...)` call from
   `OnboardingService.completeTask` (line 48-50).** With D6 in place the trigger fires on the same
   `update t`, so leaving it would recompute twice per click. ⚠ `OnboardingService`'s class header
   documents a "two DML statements, no Savepoint" transactionality argument that stops being accurate —
   **rewrite that header block**, do not leave it.
3. **Write `Oldest_Open_Days__c`** — currently nothing does, yet `OnboardingController.getTimeSla`
   reads it (`OnboardingController.cls:180-181`). Definition is ambiguous ⇒ **OQ-4**. It cannot be a
   formula: `Task` is not master-detail to `Onboarding__c`, so no roll-up summary is possible and no
   formula can aggregate children.

### D8 — `PropertyAssetTrigger` + `PropertyAssetTriggerHandler` + `OnboardingAutoCreateService` (S4)

- **`triggers/PropertyAssetTrigger.trigger`** — one line, `after insert` only:
  `new PropertyAssetTriggerHandler().run();`
- **`PropertyAssetTriggerHandler.cls`** extends `TriggerHandler`, overrides `afterInsert()` only,
  delegates to the service. No SOQL, no DML, no logic.
- **`OnboardingAutoCreateService.cls`**:
  - Filter `Trigger.new` to assets with **`Closing_Date__c != null`** (C2 — the entire safety property
    of this feature). Empty ⇒ return before any query: **zero SOQL, zero DML** on an ordinary asset
    insert, matching `PropertyAssetService.createAssets`.
  - Idempotency read via `OnboardingSelector.selectByPropertyAssetIds` (D4); drop any asset that
    already carries an Onboarding. Keyed on `Property_Asset__c` **alone**, no status filter — the same
    reasoning `PropertyAssetService` recorded for re-acquisition.
  - Build `Onboarding__c(Property_Asset__c = asset.Id, Stage__c = 'Property Set up',
    **`Status__c = 'In Progress'` set EXPLICITLY**, `Start_Date__c = Date.today()`,
    `Target_Completion_Date__c = <OQ-5>`)`.
    🔴 `Status__c` is explicit and not left to the picklist default for a measured reason: the only
    sharing rule on the object is `Status__c notEqual ''`. **A blank status makes the new Onboarding
    invisible to the entire PM team** — the identical trap `PropertyAssetService.STATUS_ACTIVE`
    documents one object over. Both `'Property Set up'` and `'In Progress'` are members of their
    restricted picklists (verified against the `valueSet` blocks), so neither can fail the DML.
  - One `Database.insert(list, <OQ-9>, AccessLevel.SYSTEM_MODE)`. `SYSTEM_MODE` because the running
    user is the deal driver, who holds `DPEG_PropertyMgmt_View` — read-only on `Onboarding__c`.
  - Notification: **one** `GroupNotifier.notify(List<Request>)` call carrying one `Request` per new
    Onboarding — **not** `send()` in a loop. `GroupNotifier`'s own header measures a looping caller at
    9 queries per record / 1,800 per chunk, and the batched entry point is the guardrail against it.
    `recipientGroup = 'DPEG_Property_Mgmt_Team'`, `targetRecordId = <new Onboarding Id>`.
  - 🔴 `GroupNotifier` sends under the **`Acquisitions_Deal_Update`** custom notification type — it is
    a hardcoded private constant with no override. A Property Management alert will be branded as an
    Acquisitions Deal Update. **OQ-6.**
- ⚠ **`PropertyAssetService.cls:121-125` must be amended in the same PR.** It currently asserts, as a
  verified fact, *"Starts no downstream automation… no `Property_Asset__c` trigger"*. This build makes
  that false. Leaving it is worse than never having written it.

### D9 — `TestDataFactory` additions

Per ARCHITECTURE §2 ("always use `TestDataFactory`"): a builder for in-memory
`Onboarding_Task_Def__mdt` rows (CMDT cannot be inserted in tests but **can** be constructed in
memory — that is what `TaskFanoutService.taskDefsOverride` exists for) and a `createOnboardingTasks`
variant carrying `Onboarding_Completed_Date__c`.

⚠ `TestDataFactory.createOnboardings` (line 3011-3033) sets only `Tasks_*` counters — **it assigns
none of the five S3 candidate fields.** That is the single most reassuring measured fact available for
S3 and nobody else will find it: the factory itself survives a formula conversion untouched; only the
two named test classes and the seed script break (C1).

### D10 — Tests

`.claude/rules/bulk-test-rule.md` applies at **251**; no content objects are involved, so
`.claude/rules/content-publication-rule.md` does not narrow it. Test classes:
`OnboardingFanoutServiceTest`, `OnboardingTaskDefProviderTest`, `OnboardingTaskDomainTest`,
`OnboardingAutoCreateServiceTest`, `PropertyAssetTriggerHandlerTest`, plus amendments to
`TaskRollupTriggerHandlerTest`, `OnboardingServiceTest`, `OnboardingTaskRollupServiceTest`,
`OnboardingControllerTest`, `OnboardingSelectorTest`, `PropertyAssetServiceTest`.

The 251-record bulk cases the brief specifically asked to be safe:
- **251 `Onboarding__c` inserted in one transaction** ⇒ 251 × 45 = 11,295 Task rows. Must prove the
  work lands in the Queueable and that the synchronous transaction stays inside limits. ⚠ Chained jobs
  do not execute in test context (`TaskFanoutQueueable.ChainFinalizer`'s own note) — assert on
  Onboardings enqueued and on **one chunk's** checklist content, and say so in the header rather than
  writing an assertion that cannot fire.
- **251 `Property_Asset__c` with `Closing_Date__c` set** ⇒ 251 Onboardings, one notification batch.
- **251 Tasks updated** ⇒ D6's rollup recomputes without SOQL/DML in a loop.
- ⚠ **Assert governor headroom on counters captured INSIDE the async context**, not on
  `Limits.getQueries()` after `Test.stopTest()` — `stopTest` restores the pre-test counters and the
  obvious assertion is silently vacuous.

**UAT ONB-001** ("Complete a task on an onboarding record ⇒ Completion % and Tasks-Complete roll up;
overdue count refreshes") is satisfied by D5+D6+D7 and should be pinned as a named test — including
the S2 half the FSD implies: the task's **original due date survives** the completion.

---

## 6. EXECUTION ORDER

### 6.1 Wave 1 — S1 + S2 + S4 (no field-type surgery, no test-suite risk)

1. **A1** CMDT object + fields → deploy. *(Nothing references it yet.)*
2. **A3** `Tasks_Fanned_Out__c`, **A4** `Onboarding_Completed_Date__c` → deploy. **Hub FLS grants (§3)
   must land in the same pass** or the fields are invisible to everyone including System Administrator.
3. **A2** run `scripts/load-onboarding-task-defs.apex`. *Must precede any test that reads the defs
   without the `@TestVisible` override; the deploy itself does not depend on it.*
4. **D1, D4, D2, D3** → deploy. **D4 before D2** (service calls selector).
5. **A5** flow `Onboarding_Task_Fanout` → deploy. *Last in S1: activating it before the Apex exists
   fails, and activating it before the CMDT is loaded fans out zero tasks and permanently flags the
   record.*
6. **D5** (trigger context + domain + `OnboardingService` line 43) → deploy.
7. **D6, D7** → deploy. *D7's `without sharing` + `SYSTEM_MODE` fix must land **with or before** D6 —
   D6 is what exposes the sharing failure.*
8. **D8** `PropertyAssetTrigger` + handler + service, and the `PropertyAssetService` header amendment.
   *Last, because it is the only item that can roll back an Opportunity close (OQ-9).*
9. **D9, D10**.

### 6.2 Deploy-order rule that bites here

Restricted picklists **are** enforced by DML in this org. `Onboarding_Category__c` and
`Source_System__c` are both `<restricted>true</restricted>`, so the CMDT rows must carry the exact
literals or the fan-out insert fails at runtime, not at deploy. Verify the loader's strings against
`objects/Activity/fields/Onboarding_Category__c.field-meta.xml` character-for-character (note
`Property Set up` — lowercase "up" — and the `&`s).

### 6.3 Wave 2 — S3 formula conversion (SEPARATE PR, gated on OQ-3)

Recommended scope, narrowed on the evidence:

| Field | Recommendation | Reason |
|---|---|---|
| `Is_Past_Target__c` | **New formula field** | It is the one field that is provably broken: nothing writes it, so FSD 5.1.8's "past target date" tile reads 0 forever (`OnboardingController.cls:151,179`). It is **time-dependent** — a rollup that only fires on Task change would go stale the day after the target passes. Formula: `NOT(ISBLANK(Target_Completion_Date__c)) && Target_Completion_Date__c < TODAY() && NOT(ISPICKVAL(Stage__c, "Onboarding Complete"))` |
| `Age_Days__c` | **New formula field** | Also time-dependent. `IF(ISBLANK(Start_Date__c), null, TODAY() - Start_Date__c)`. Use `formulaTreatBlanksAs = BlankAsBlank` **plus** the explicit `ISBLANK` guard — `BlankAsZero` would make a blank Start Date read as "started today" |
| `Completion_Pct__c` | **Leave stored** | Already written correctly by D7, and after D6 it is written on **every** path. Converting buys nothing and costs the full C1 blast radius including an `OnboardingTaskRollupService` compile break |
| `Oldest_Open_Days__c` | **Leave stored, written by D7** | A child aggregate. No formula can express it (Task is not master-detail) |
| `Days_To_Onboard__c` | **BLOCKED — leave as-is** | Requires an actual-completion date that **does not exist** on the object. OQ-4 |

**Path: new API names, not erase-and-reuse.** Two waves (create formula alongside → repoint the ~6
reader sites → retire the old field) instead of five (sever every reference → delete → **manual,
irreversible Setup ERASE** → recreate → restore). The erase path takes the entire test suite red in
between. If the user insists on keeping the current API names, price it as five waves and be explicit
that a deleted field keeps its name reserved until erased.

⚠ If new names are chosen, `Past_Target__c` looks free — but
`docs/superpowers/plans/2026-06-29-property-management-onboarding.md:532` shows it was the **original**
name before the shipped field became `Is_Past_Target__c`. A previously deployed-then-deleted field
keeps its API name reserved. **Verify against the live org before proposing it; do not assume.**

---

## 7. ❓ OPEN QUESTIONS

### Blocking (cannot implement without an answer)

- **OQ-1a — The 2 missing Performance Tracking tasks.** The seed has 1 (`Track KPIs in Salesforce`);
  FSD 5.1.5 specifies 3. **Deliberately not invented.** Need: subject text ×2, owner label, source
  system (one of `Yardi`/`Excel`/`Salesforce`/`Email`), due-day offset. *Fallback if unavailable: ship
  45 and add the 2 later — the CMDT makes that a data-only change requiring no code and no deploy.*
- **OQ-2 — `Due_Day_Offset__c` values for all 45 rows.** The seed carries **absolute** demo dates, not
  offsets. A mechanical derivation exists (`seed date − Park North's `Start_Date__c` of 2026-04-18`,
  producing offsets of roughly +2 … +88 days), but those dates were authored as illustrative demo data,
  so deriving SLAs from them would bake demo values into production. **Options:** (a) use the
  mechanical derivation as the v1 baseline; (b) the user supplies real per-task offsets; (c) all
  offsets 0 and PM sets dates by hand. Recommend (a) with (b) to follow.
- **OQ-3 — S3 conversion scope + field names + retire-vs-reuse.** See §6.3. Needs: which of the two
  recommended fields to convert, the new API names, and confirmation that the hub permission-set edits
  (§3) are acceptable.
- **OQ-4 — Two undefined field semantics.**
  - `Days_To_Onboard__c`: `OnboardingController.getKpis().avgDaysToOnboard` depends on it, but nothing
    writes it and the seed's values are arbitrary (Park North: 28, against a 74-day Start→Target span).
    There is **no actual-completion date on `Onboarding__c`**, and the KPI is computed over *active*
    records only (`selectActive()` excludes `Onboarding Complete`), so "days to onboard" cannot mean
    elapsed-to-finish for the rows it is averaged over. Need the intended definition — and if it is
    "days from start to actual completion", that is a **new Date field plus a stamp**, which is
    additional scope requiring approval.
  - `Oldest_Open_Days__c`: days-past-due of the most overdue open task, or days-since-creation of the
    oldest open task? The latter needs `CreatedDate` added to
    `TaskSelector.selectByOnboardingIds` (safe — that method is already `SYSTEM_MODE`).
- **OQ-5 — `Target_Completion_Date__c` for auto-created Onboardings (S4).** No SLA anywhere in the
  FSD. Options: leave null (honest, but `Is_Past_Target__c` is then permanently false and
  `ORDER BY Target_Completion_Date__c NULLS LAST` loses its sort key); `Start_Date__c + N` with the
  user choosing N; or derive from `MAX(Due_Day_Offset__c)` in the CMDT. Recommend `Start_Date__c + N`
  with an explicit, named constant.
- **OQ-9 — S4 `allOrNone` on the Onboarding insert.** `true` matches `PropertyAssetService` and fails
  loudly — but it means **an Onboarding defect blocks Acquisitions from closing deals**, which is the
  module boundary the user approved crossing. `false` degrades to a silently-missing Onboarding.
  Recommend `true` for consistency, but this is a business call, not a technical one.

### Non-blocking (a default is proposed; correct it if wrong)

- **OQ-1 — One CMDT or two?** Recommend one (§A1).
- **OQ-6 — Notification type.** `GroupNotifier` hardcodes `Acquisitions_Deal_Update`. Accept the
  mis-branding, or add a PM notification type (new metadata + a `GroupNotifier` signature change that
  touches five existing callers)? Recommend accept for v1.
- **OQ-7 — Onboarding Lead / Task owner.** `Onboarding_Lead__c` is `Text(120)`, so S4 cannot assign a
  User. Default: leave it blank, and let fanned-out Tasks take `Onboarding__c.OwnerId` — which on the
  automated path is the **deal driver who closed the Opportunity**, not a property manager. The PM team
  still gets Edit via the sharing rule. Correct owner assignment would need a `Lookup(User)`, i.e. new
  scope.
- **OQ-8 — S4 trigger context.** `after insert` only (recommended). An asset given a Closing Date
  *after* creation gets no Onboarding. Adding `after update` widens the surface and re-opens the
  seed/test-immunity question.
- **OQ-10 — Backfill.** Existing seeded Tasks and any task already completed through the checklist LWC
  have a destroyed `ActivityDate` and a null `Onboarding_Completed_Date__c`. Backfill via a one-off
  script, or accept the gap? Recommend accept — the original dates are already lost and cannot be
  reconstructed.

---

## 8. POST-DEPLOY GATES (verification only — no code)

1. `groups/DPEG_Property_Mgmt_Team` — confirm it has **user members** in the target org. Empty ⇒ S4's
   notification degrades to a `System.debug` and nobody is ever told (§3).
2. Read back `Onboarding_Task_Def__mdt` record count = 45 (or 47) after the async loader completes.
   `enqueueDeployment` returns before the records exist.
3. Create one `Property_Asset__c` via a real Closed-Won Opportunity and confirm: 1 Onboarding, status
   `In Progress`, 45 Tasks, `Tasks_Fanned_Out__c = true`, PM team notified.
4. Re-save that asset and that Onboarding — confirm **still 45 Tasks and still 1 Onboarding**.
5. Complete one Task from the **standard UI** (not the LWC) — confirm the rollups move and the
   original `ActivityDate` is unchanged.
6. Run a seed script and confirm it creates **zero** Onboardings (proves the C2 discriminator).
7. Diff every hub permission set against `HEAD` before deploying — a `PermissionSet` deploy replaces
   its whole `<fieldPermissions>` set, and two other builds are editing the same files.

---

## 9. PROMPTS FOR SPECIALIST AGENTS

Gate this on the user answering **OQ-1a, OQ-2, OQ-3, OQ-4, OQ-5 and OQ-9** first. OQ-3 gates Wave 2
only; Wave 1 can start once OQ-1a/2/5/9 are answered.

### 🔵 salesforce-admin — Wave 1 declarative

```
Read ARCHITECTURE.md and .claude/rules/salesforce-global-rule.md. Record mcp=unavailable
(salesforce-api-context is not configured in this repo) and fall back to the per-type skill.
Do NOT deploy. Do NOT touch applications/, tabs/ or permissionsets/ — hub edits are consolidated
separately.

Implement A1-A5 of agent-output/design-onboarding-checklist.md §4:

1. CustomObject Onboarding_Task_Def__mdt (visibility Public) + 8 fields, all
   fieldManageability=DeveloperControlled. Copy the exact XML shape from
   objects/Transaction_Task_Def__mdt/ — that is the in-repo precedent.
2. Onboarding__c.Tasks_Fanned_Out__c — Checkbox, defaultValue false. Byte-for-byte the shape of
   objects/Transaction__c/fields/Tasks_Fanned_Out__c.field-meta.xml.
3. Activity.Onboarding_Completed_Date__c — Date, label "Onboarding Completed Date".
   Custom Task fields live under objects/Activity/fields/, not objects/Task/fields/.
4. scripts/load-onboarding-task-defs.apex — Apex Metadata API loader mirroring
   scripts/load-transaction-task-defs.apex. Do NOT create .md-meta.xml files:
   .forceignore:16 excludes **/customMetadata/** because file-based CMDT record deploys throw
   UNKNOWN_EXCEPTION in this org. Source the 45 rows VERBATIM from
   scripts/seed-onboarding-tasks.apex:8-58. Category__c and Source_System__c must match the
   restricted picklist literals character-for-character (note "Property Set up", lowercase "up",
   and the "&" characters) — restricted picklists ARE enforced by DML in this org.
   Due_Day_Offset__c values: <per the user's OQ-2 answer>.
5. flows/Onboarding_Task_Fanout.flow-meta.xml — direct mirror of
   flows/Transaction_Task_Fanout.flow-meta.xml: AutoLaunchedFlow, RecordAfterSave,
   CreateAndUpdate, doesRequireRecordChangedToMeetCriteria=true, apiVersion 67.0, status Active,
   one apex actionCall to OnboardingFanoutService passing $Record.Id. Start filters (and):
   Start_Date__c IsNull false, Tasks_Fanned_Out__c EqualTo false.

Output a HUB FILE REQUESTS list for anything you would otherwise have added to a permission set.
```

### 🟢 salesforce-developer — Wave 1 Apex

```
Read ARCHITECTURE.md, .claude/rules/apex-layering-rule.md, .claude/rules/bulk-test-rule.md and
.claude/rules/invocable-rule.md. Record mcp=unavailable. Do NOT deploy. Do NOT touch
permissionsets/, tabs/ or applications/.

Implement D1-D9 of agent-output/design-onboarding-checklist.md §5. Read these files FIRST and
mirror their structure: TaskFanoutService.cls, TaskFanoutQueueable.cls, TaskGroupDefProvider.cls,
TaskRollupTriggerHandler.cls, PropertyAssetService.cls, PropertyAssetSelector.cls, GroupNotifier.cls.

Mirror the SKELETON of the Transaction fan-out, not its body — the group-letter join and the
conditional gate have no Onboarding counterpart.

Six non-negotiables, each measured against this repo:

1. Onboarding__c is PRIVATE OWD, shared only to DPEG_Property_Mgmt_Team and only where
   Status__c != ''. AccessLevel.SYSTEM_MODE lifts CRUD/FLS but NEVER sharing. Both the fan-out
   idempotency read and the Tasks_Fanned_Out__c flag write must sit in a narrow
   `private without sharing` inner class — a sharing-filtered idempotency guard does not disable
   the feature, it inverts it into a duplicate-maker. Copy the argument and shape from
   PropertyAssetSelector.selectByPropertyIds.

2. OnboardingTaskRollupService.recalc line 41 currently does a bare `update upd.values();`.
   Change it to Database.update(..., true, AccessLevel.SYSTEM_MODE) inside a `without sharing`
   context, IN THE SAME CHANGE that routes Onboarding through TaskRollupTrigger — the routing is
   what exposes the failure.

3. S4 keys on Property_Asset__c.Closing_Date__c != null. PropertyAssetService.cls:361 is its ONLY
   writer; TestDataFactory.createPropertyAssets (line 1350) and all nine seed scripts leave it
   blank. That is what keeps ~66 existing test classes and every seed script from minting
   Onboardings. State this fact in the service header.

4. OnboardingAutoCreateService must set Status__c = 'In Progress' EXPLICITLY. The only sharing
   rule on Onboarding__c is `Status__c notEqual ''` — a blank status hides the record from the
   entire PM team.

5. Delete `t.ActivityDate = Date.today();` from OnboardingService.cls:43, delete the explicit
   recalc call at lines 48-50, and REWRITE that class's header — its documented "two DML
   statements, no Savepoint" transactionality argument stops being accurate.

6. Amend two stale class/trigger headers in the same PR: PropertyAssetService.cls:121-125
   ("Starts no downstream automation… no Property_Asset__c trigger") and
   TaskRollupTrigger.trigger's after-only / Transaction-only description. Also correct
   OnboardingSelector.cls's header claim that "there is NO guest/automation path on Onboarding__c,
   so NO SYSTEM_MODE appears here."

Use GroupNotifier.notify(List<Request>) with one Request per new Onboarding — a single batched
call, never send() in a loop (its header measures 9 queries per record for the looping shape).
Target group DPEG_Property_Mgmt_Team.
```

### 🟡 salesforce-unit-testing

```
Read .claude/rules/bulk-test-rule.md. Bulk volume is 251 (no content objects involved, so
.claude/rules/content-publication-rule.md does not narrow it). Use TestDataFactory for all data.

Cover D10 of agent-output/design-onboarding-checklist.md §5. Required scenarios:
- 251 Onboarding__c inserted in one transaction (251 x 45 = 11,295 Task rows) — assert the work
  lands in the Queueable and the synchronous transaction stays inside limits.
- 251 Property_Asset__c with Closing_Date__c set — 251 Onboardings, one notification batch.
- 251 Property_Asset__c WITHOUT Closing_Date__c — assert ZERO Onboardings created. This is the
  regression guard for the whole existing test suite.
- 251 Tasks updated — rollups recompute with no SOQL/DML in a loop.
- Idempotency: re-run the fan-out and the auto-create; assert no duplicates either time.
- UAT ONB-001: complete a task; Completion % and Tasks-Complete roll up, overdue count refreshes,
  AND the task's original ActivityDate is unchanged.
- Completion stamp via a NON-LWC path (direct DML) — proves the trigger, not the service, owns it.
- Reopen a completed task — assert Onboarding_Completed_Date__c is cleared.

Two traps:
- Chained Queueable jobs do not execute in test context. Assert on enqueue + one chunk's content,
  and say so in the class header rather than writing an assertion that cannot fire.
- Assert governor headroom on counters captured INSIDE the async context, not on
  Limits.getQueries() after Test.stopTest() — stopTest restores pre-test counters and the obvious
  assertion is silently vacuous.
```
