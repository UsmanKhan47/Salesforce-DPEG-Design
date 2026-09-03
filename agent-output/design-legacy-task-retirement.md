# Design — M5: Retiring the legacy Task-based Transaction checklist

**Date:** 2026-09-03 · **Agent:** salesforce-design · **Status:** requirements + design. **Nothing implemented.**
**Implements:** `agent-output/design-transaction-fsd-gaps.md` §7 M5, deferred to here by
`agent-output/design-checklist-cutover-and-stage-gate.md` §A8.
**Retirement ORDER constraint inherited from:** `agent-output/phase4-migration-design.md` §8.4.
**Does not supersede:** anything. GATE-B2/B3/B4 (`CriticalDateService` wiring) stay closed and untouched.

---

## 0. Process gates and evidence discipline

```
intent=app | best_matched_skill=none | skill_selection=complete
mcp=unavailable | mcp_tools=none
```

`.claude/rules/salesforce-global-rule.md` mandates a `salesforce-api-context` MCP attempt per metadata
type. A real attempt was made: `.mcp.json` declares only the `salesforce` server and this agent's tool
set is file-system only (Read / Write / Edit / Glob / Grep) — **no MCP tools, no `sf` CLI, no org
access**. Recorded `mcp=unavailable` and fell back to the per-type skills plus in-repo evidence, as
every prior `agent-output/` design in this repo has done.

### 0.1 🔴 READ THIS BEFORE TREATING ANY CLAIM IN THIS FILE AS FACT

This repo has a documented incident where an unverified count in an `agent-output/` file was re-read
as fact by later subagents. Every claim below is therefore tagged.

| Claim | Source | Status |
|---|---|---|
| Zero `Task` rows with `Transaction_Deal__c` populated exist org-wide | The brief | ⚠ **NOT verified by me.** No org access. **This is the entire safety argument for the field deletions and is re-asserted as a mandatory pre-flight probe in §5 R0.** |
| Exactly one `Transaction__c` (TXN-0285), 11 `Checklist__c`, 82 `Checklist_Item__c` | The brief | ⚠ Not verified by me. |
| `Transaction_Task_Fanout` v2 Active, `0Afiw000000WVofCAG`, v1 Obsolete | The brief | ⚠ Version Ids and org status not verified. ✅ **The SOURCE half IS verified:** `flows/Transaction_Task_Fanout.flow-meta.xml:47,56,80` calls `ChecklistFanoutService` and filters `Checklist_Fanned_Out__c`; `<status>Active</status>` at line 90. |
| Suite green 3,719/3,719 | The brief | ⚠ Not verified by me. |
| 82 Tasks deleted 2026-09-02, Recycle Bin until ~2026-09-17 | The brief | ⚠ Not verified. The 15-day retention is a platform constant, not something I measured. |
| Every "KEEP / RETIRE / AMEND" verdict below | This repo's working tree | ✅ **Verified by reading the cited file and line.** Each carries its citation. |
| The org contains a stale `Activity`-scoped validation rule with no source file | `objects/Task/validationRules/...:34-40` | ⚠ **The FILE says it must be removed separately and does not claim it was.** Whether it still exists in `usman-dpeg` is **unverifiable from here** — see §3.2. |

### 0.2 Where I disagree with the brief, stated up front rather than buried

Four of the brief's premises are wrong against the working tree. All four make the change **narrower**,
not wider. They are argued with file+line in §2 and §3.

1. **The validation rule exists in TWO source copies, not three.** There is no
   `objects/Activity/validationRules/` directory. A third copy may still exist **in the org**, orphaned
   with no source file. That is a different problem with a different fix (§3.2).
2. **THREE of the eleven `Activity` fields the brief lists are used by Property Management** —
   `Task_Owner_Label__c`, `Task_Sequence__c`, `Conditional__c`. This falsifies
   `phase4-migration-design.md` §8.2's "exactly nine are Transaction-only". Only **eight** are
   Transaction-only (§3.1).
3. **`TaskRollupService` is NOT retirable yet, and not for a Property Management reason.**
   `ChecklistMigrationService.cls:638` calls `TaskRollupService.recalc` inside `rollback` — which *is*
   the cutover rollback for the still-open 15-day window (§4, §5).
4. **`Transaction_Task_Actions` IS retirable** (GATE-B11 answered "retire"), and I nearly got this
   wrong. Two files in the NEW model name that custom permission, but both name it only in **historical
   prose explaining what the legacy class had to do**, in the past tense. Neither calls it (§3.4).
   `Transaction_Prereq_Override`, by contrast, has a **real production caller in the new model** and
   must be KEPT.

---

## 1. Scope

### In scope
Retiring the **Transaction arm** of the legacy Task checklist: its Apex, its LWC branches, its
Transaction-only `Activity` fields, its list view, its validation rule, its permission-set grants, and
the one script that can recreate it.

### Explicitly out of scope (from the brief, restated so nothing drifts in)
- Renaming the `Tasks_*` counters — deferred, separate change (§4.2 explains why and what the rename
  would cost).
- Anything Onboarding / Property Management.
- Anything Broker Protection.
- Integration or notification work.
- `CriticalDateService` wiring — GATE-B2/B3/B4 stay open.

---

## 2. Shared-component analysis — the three things that must survive

### 2.1 `TaskRollupTrigger` — 🟢 **THE CONTEXT LIST DOES NOT CHANGE AT ALL**

This is the single most useful finding for scoping the trigger work, and it runs opposite to
`phase4-migration-design.md` §8.4, which says to retire "`TaskRollupTrigger`'s Transaction contexts".

**There are no Transaction-only contexts.** Read `TaskRollupTriggerHandler.cls:70-108`:

| Context | Transaction arm | Onboarding / other arm | Survives? |
|---|---|---|---|
| `before insert` | `TaskPrerequisiteService.clampOnInsert` (`:74`) | `OnboardingTaskDomain.stampCompletion` (`:71`) | ✅ **YES** — PM needs it |
| `before update` | `TaskPrerequisiteService.enforceOnUpdate` (`:82`) | `OnboardingTaskDomain.stampCompletion` (`:78`) | ✅ **YES** — PM needs it |
| `after insert` | `recalcDeals(collectDealIds(...))` (`:86`) | `recalcOnboardings(...)` (`:87`) | ✅ **YES** |
| `after update` | `:91-93` | `:95-97` | ✅ **YES** |
| `after delete` | `:101` | `:102` | ✅ **YES** |
| `after undelete` | `:106` | `:107` | ✅ **YES** |

Every one of the six contexts carries an Onboarding responsibility.
⇒ **`triggers/TaskRollupTrigger.trigger` changes by ZERO lines of executable code.** Its header
(`:12-17`, `:26-37`) describes the `TaskPrerequisiteService` SOQL cost in the before-update context and
becomes wrong — that is a **comment-only** edit.

**What actually goes from `TaskRollupTriggerHandler`:**
- `collectDealIds` (`:116-127`) — private, Transaction-only projection of `Transaction_Deal__c`.
- `recalcDeals` (`:133-137`) — private, calls `TaskRollupService.recalc`.
- The four `recalcDeals(...)` call sites (`:86, :93, :101, :106`).
- The two `TaskPrerequisiteService` calls (`:74`, `:82`).

**What must NOT be touched:** `recalcOnboardings` (`:158-165`), including its
`OnboardingTaskRollupService.isTriggerRecalcSuppressed()` guard, and every
`OnboardingTaskDomain.*` call. `TaskRollupTriggerHandler.cls:154` already says
*"Deliberately gates the ONBOARDING branch only. `recalcDeals` is untouched"* — after M5 that sentence
also needs correcting, because `recalcDeals` will not exist.

⚠ **After removing both `TaskPrerequisiteService` calls, `beforeInsert` and `beforeUpdate` each hold
exactly one statement.** Do not "simplify" by dropping the contexts — see the table above.

### 2.2 The `Activity` fields — 🔴 **THREE OF ELEVEN ARE PROPERTY MANAGEMENT'S**

`objects/Activity/fields/` holds 20 fields. Per-field evidence, gathered by opening every non-test
production hit rather than counting greps (grep hits on these names are heavily inflated by same-named
fields on `Wire__c`, `Checklist_Item__c`, `Task_Group_Def__mdt` and `Onboarding_Task_Def__mdt` — see
§2.4).

| Field | Type | Verdict | Evidence |
|---|---|---|---|
| `Transaction_Deal__c` | Lookup(Transaction__c) | 🟥 **RETIRE** | Written `TaskFanoutService.cls:196`; read by `TaskSelector` legacy methods only; `TestDataFactory.cls:1410,1446`. No PM/BP/Disposition consumer found. |
| `Task_Group__c` | Picklist (11 values) | 🟥 **RETIRE** | Written `TaskFanoutService.cls:199`. Read by 4 `TaskSelector` methods (all retiring), the list view, `TestDataFactory`. No PM consumer. |
| `Verbal_Verification_Completed__c` | Checkbox | 🟥 **RETIRE** | `TaskSelector:208,667,727` (retiring methods) + `TransactionTaskService`. ⚠ **Same name exists on `Wire__c` and `Checklist_Item__c` — both LIVE, both untouched.** |
| `Verified_By__c` | Text | 🟥 **RETIRE** | `TaskSelector:209,727` + `TransactionTaskService`. Exists on no other object. |
| `Verified_At__c` | DateTime | 🟥 **RETIRE** | `TaskSelector:209,727` + `TransactionTaskService`. Exists on no other object. |
| `Verification_Phone__c` | Text | 🟥 **RETIRE** | `TaskSelector:209,728` + `TransactionTaskService`. ⚠ Same name on `Checklist_Item__c` — LIVE, untouched. |
| `Blocked_By__c` | Text(20) | 🟥 **RETIRE** (Phase 0) | Written `TaskFanoutService.cls:212`; read by `TaskPrerequisiteService`, the Task VR, `scripts/backfill-task-blocked-by.apex`. ⚠ Same name on `Checklist_Item__c` (a real self-lookup) — LIVE. |
| `Is_Prerequisite_Met__c` | Checkbox | 🟥 **RETIRE** (Phase 0) | Written by `TaskPrerequisiteService`; read by the Task VR. ⚠ Same name on `Checklist_Item__c` — LIVE. |
| **`Task_Owner_Label__c`** | Text | 🟩 **KEEP — PROPERTY MANAGEMENT READS IT** | 🔴 `OnboardingFanoutService.cls:291` WRITES it. `TaskSelector.selectChecklistByOnboardingId` (`:312`) SELECTS it **`WITH USER_MODE`**. `OnboardingController.cls:235` renders it (`it.owner = t.Task_Owner_Label__c`). Deleting it breaks the PM onboarding checklist UI. |
| **`Task_Sequence__c`** | Number | 🟩 **KEEP — PROPERTY MANAGEMENT WRITES IT** | 🔴 `OnboardingFanoutService.cls:290` (`tk.Task_Sequence__c = d.Sequence__c`). Write-only on the PM side today, but deleting it is a compile break of `OnboardingFanoutService` and silently loses PM's per-task ordinal. |
| **`Conditional__c`** | Checkbox | 🟩 **KEEP — PROPERTY MANAGEMENT WRITES IT** | 🔴 `OnboardingFanoutService.cls:293` (`tk.Conditional__c = (d.Conditional__c == true)`). Same shape as above. |

**Not in scope and not to be touched** (already correctly excluded by `phase4-migration-design.md`
§8.2): `Onboarding__c`, `Onboarding_Category__c`, `Onboarding_Status__c`, `Onboarding_Completed_Date__c`,
`Blocked_Reason__c`, `Source_System__c`, `Inbound_Message_Id__c`, `Thread_Key__c`.

⇒ **Eight fields retire, three previously-listed fields stay.**

🟡 **Open question for the user, not a decision I should take:** the three KEPT fields are now
*PM-only*, but they carry Transaction-shaped names (`Task_Sequence__c`, `Task_Owner_Label__c`) and
`Task_Sequence__c` / `Conditional__c` are **write-only** on the PM side — nothing reads them. Whether PM
wants to retire them, or read them, is a Property Management decision and is **out of scope by the
brief's own boundary**. Raise it; do not fold it in.

### 2.3 The CMDT providers — 🟢 **BOTH ARE LIVE. RETIRING THEM WOULD BREAK THE NEW MODEL.**

The brief's suspicion is correct and I can pin it exactly:

```
ChecklistFanoutService.cls:986   : TaskGroupDefProvider.getAllOrderedBySequence();
ChecklistFanoutService.cls:993   : TransactionTaskDefProvider.getAllOrderedByGroupAndSequence();
```

| Component | Verdict | Note |
|---|---|---|
| `TaskGroupDefProvider` + Test | 🟩 **KEEP** | Sole change: its header (`:14`) lists `Conditional__c` etc. — accurate, no edit needed. |
| `TransactionTaskDefProvider` + Test | 🟩 **KEEP** | |
| `Task_Group_Def__mdt`, `Transaction_Task_Def__mdt` (types + all fields) | 🟩 **KEEP** | |
| `scripts/load-task-group-defs.apex`, `scripts/load-transaction-task-defs.apex` | 🟩 **KEEP** | `.forceignore:16` ignores `**/customMetadata/**`, so these scripts are the ONLY way the definitions reach an org. Deleting them makes the new model un-seedable. |

🔴 **One live coupling M5 must NOT break, carried forward from `phase4-migration-design.md` §8.7:** the
`(anti-fraud)` / `(CRITICAL - frequently missed)` markers in `Transaction_Task_Def__mdt.Subject__c`.
Those markers become cosmetic **only** once `TaskRollupService`'s subject parse
(`TaskRollupService.cls:48`) and `utilsTransactionChecklist`'s `LEGACY_CRITICAL_RE` / `LEGACY_WIRE_RE`
are both gone. **Do not clean the markers out of the CMDT subjects in this change.** They are also still
asserted by `ChecklistCaptureDefProviderTest.everyCoordinateStillMatchesItsLoaderSubject`
(`ChecklistCaptureDefProvider.cls:24`), which is new-model code.

### 2.4 🔴 The name-collision map — read this before running any sweep

Seven of the names in scope also exist as **different fields on other, live objects**. A `grep` that
does not disambiguate will produce a false blast radius, and a `destructiveChanges` entry that names
the wrong object is a production outage.

| Name | Also exists on | Status of the twin |
|---|---|---|
| `Verbal_Verification_Completed__c` | `Wire__c`, `Checklist_Item__c` | **LIVE.** `Wire__c`'s is read by `flows/Wire_Verification_Rollup:49`, `WireService:52`, `WireSelector:55`, `WireController:50,58`, and granted in `DPEG_Disposition_View:1335` / `DPEG_Disposition_Edit:2088`. **Disposition depends on it.** |
| `Verification_Phone__c` | `Checklist_Item__c` | LIVE (new model) |
| `Blocked_By__c` | `Checklist_Item__c` | LIVE (new model, a real self-lookup) |
| `Is_Prerequisite_Met__c` | `Checklist_Item__c` | LIVE (new model) |
| `Conditional__c` | `Task_Group_Def__mdt`, `Onboarding_Task_Def__mdt` | LIVE — the CMDT columns that drive **both** fan-outs |
| `Tasks_Fanned_Out__c` | `Onboarding__c` | 🔴 **LIVE AND LOAD-BEARING.** `flows/Onboarding_Task_Fanout:41` filters on it; `TestDataFactory:3955` presets it on every factory Onboarding and its header (`:3924-3942`) calls that "DELIBERATE AND LOAD-BEARING". |
| `Tasks_Total__c` / `Tasks_Complete__c` / `Tasks_Overdue__c` | `Onboarding__c` | LIVE (PM rollups) |

**Every destructiveChanges member in this change must be written `Activity.<Field>` or
`Transaction__c.<Field>` explicitly.** Note the asymmetry recorded at
`Broker_Protection_Access.permissionset-meta.xml:121-122`: fields are **declared** under
`objects/Activity/fields/` but are **granted** as `Task.<Field>` in a permission set — `Activity` is not
a valid SObject prefix there.

---

## 3. Component-by-component inventory with verdicts and evidence

Legend: 🟥 **RETIRE** · 🟨 **KEEP-FOR-NOW** (with a stated trigger condition) · 🟩 **KEEP** ·
🟦 **AMEND**

### 3.1 Apex

| Component | Verdict | Evidence |
|---|---|---|
| `TaskFanoutService` | 🟥 RETIRE | Production entry point was `flows/Transaction_Task_Fanout`, repointed (`:47,:56`). Remaining callers: `TaskFanoutQueueable.cls:43`, `scripts/fanout-seeded-transactions.apex:83`, tests. Both go with it. |
| `TaskFanoutServiceTest` | 🟥 RETIRE | |
| `TaskFanoutQueueable` | 🟥 RETIRE | Sole caller `TaskFanoutService.cls:125`; self-chains at `:84`. |
| `TaskPrerequisiteService` | 🟥 RETIRE | Its own header: *"PHASE 0 IS DELIBERATELY TEMPORARY and is discarded when the `Checklist_Item__c` model lands (design §10, M5)"* (`TaskRollupTriggerHandler.cls:25-26`) and *"Onboarding is untouched"* (`TaskPrerequisiteService.cls:88`). Only callers: `TaskRollupTriggerHandler:74,82`. |
| `TaskPrerequisiteServiceTest` | 🟥 RETIRE | Also uses `TestDataFactory.createChecklistTasks` (4 hits) — see §3.6. |
| `TransactionTaskService` | 🟥 RETIRE | Only consumer is `TransactionTaskController`. `TransactionActionPermissionService.cls:143` calls it *"the only task-gate consumer"*. |
| `TransactionTaskServiceTest` | 🟥 RETIRE | |
| `TransactionTaskController` | 🟥 RETIRE | Consumers are the three LWC legacy branches (§3.5) — all removed in the same payload. |
| `TransactionTaskControllerTest` | 🟥 RETIRE | |
| **`TaskRollupService`** | 🟨 **KEEP-FOR-NOW** | 🔴 `ChecklistMigrationService.cls:638` calls `TaskRollupService.recalc(rolledBack)` — **that is the cutover rollback** (`design-checklist-cutover-and-stage-gate.md` §A6 R1). **Trigger condition: retire only after the Recycle-Bin window closes (~2026-09-17) and the cutover is declared final.** See §5. |
| `TaskRollupServiceTest`, `TaskRollupDualModelGuardTest` | 🟨 KEEP-FOR-NOW | Follow `TaskRollupService`. The dual-model tiebreak (`phase4-migration-design.md` §8.6) dies with it. |
| `TaskRollupTriggerHandler` | 🟦 AMEND | §2.1. Remove `collectDealIds`, `recalcDeals`, 4 call sites, 2 `TaskPrerequisiteService` calls. 🔴 **The 4 `recalcDeals` call sites must go in the SAME payload as `TaskRollupService`'s deletion, not before.** |
| `TaskRollupTriggerHandlerTest` | 🟦 AMEND | Keep the Onboarding assertions; drop the deal-rollup ones. |
| `triggers/TaskRollupTrigger.trigger` | 🟦 AMEND — **comment only** | §2.1. Zero executable-line change. |
| `TaskSelector` | 🟦 AMEND — **4 of 14 methods** | Header (`:6-24`) calls itself *"a contract, not a private helper"*. RETIRE: `selectChecklistByTransactionDealIds` (`:202`), `selectByTransactionDealIds` (`:619`, incl. the `RollupReads` inner class at `:665`), `selectChecklistByDealsAndSequences` (`:1078`), `selectRequiredById` (`:268`, sole consumer `TransactionTaskService.completeWireVerification`). 🟨 `selectForChecklistMigration` (`:720`) follows `ChecklistMigrationService`. 🟩 **UNTOUCHED (9):** `selectOpenByWhatIdsAndSubjectPrefix`, `selectChecklistByOnboardingId`, `selectForOnboardingCompletion`, `selectByOnboardingIds`, `selectByWhatIdAndSubjects`, `selectByInboundMessageId`, `selectLatestByThreadOrMessageIds`, `selectByIds`, `selectThreadAnchorsByAnchorValues`. |
| `TaskSelectorTest` | 🟦 AMEND | Also uses `createChecklistTasks` (2 hits). |
| `TransactionSelector` | 🟦 AMEND | RETIRE `selectByIdsWithConditionFields` (`:133`) and its `BASE_FIELDS` constant (`:106-108`). 🔴 **`BASE_FIELDS` is a DYNAMIC `List<String>` containing the literal `'Tasks_Fanned_Out__c'` — a deleted field there is a RUNTIME failure, not a compile break.** 🟩 `CHECKLIST_BASE_FIELDS` (`:187-189`) does **not** name `Tasks_Fanned_Out__c` — verified; the new model's fan-out is safe. Update the consumer inventory in the class header (`:7`, `:20`, `:56-63`) and the SYSTEM_MODE mode inventory (`phase4-migration-design.md` §8.5). |
| `TransactionActionPermissionService` | 🟦 AMEND | RETIRE `hasTaskActionAccess` (`:348`), `assertTaskActionAccess` (`:375`), `TASK_ACTION_CUSTOM_PERMISSION` (`:490`). 🟩 **KEEP `hasPrereqOverrideAccess`** — `ChecklistItemPrerequisiteService.cls:554` is a **real production call**, not prose. 🟩 KEEP `hasTransactionActionAccess` (`RecordStageAdvanceService.cls:2581`). |
| `TransactionActionPermissionServiceTest` | 🟦 AMEND | |
| `TransactionStageGateService` | 🟦 AMEND — **comment only** | Reads `Checklist_Item__c` only (verified: every `Task` hit at `:41,48-53,70` is prose). Its fail-open rationale at `:48` (*"for as long as `TaskFanoutService` is deployed"*) becomes stale. |
| `ChecklistMigrationService` / `Domain` / `Queueable` / `AuditService` + tests | 🟨 KEEP-FOR-NOW | Reads legacy Tasks (`TaskSelector.selectForChecklistMigration`) and calls `TaskRollupService.recalc`. With zero legacy Tasks org-wide it is dead code — but `rollback` is the live cutover reversal. **Same trigger condition as `TaskRollupService`.** ⚠ `design-checklist-cutover-and-stage-gate.md` §0.2 already records that this stack has NEVER been exercised in production. |
| `TaskGroupDefProvider`, `TransactionTaskDefProvider` | 🟩 **KEEP — LIVE** | §2.3 |
| `OnboardingFanoutService`, `OnboardingTaskDomain`, `OnboardingTaskRollupService`, `OnboardingController`, `OnboardingTaskDefProvider` | 🟩 **KEEP — DO NOT TOUCH** | Constraint 9 |
| `TestDataFactory` | 🟦 AMEND | §3.6 — 🔴 suite-wide compile break if not bundled |

### 3.2 Metadata — the validation rule, and the copy that is not in source

| Component | Verdict | Evidence |
|---|---|---|
| `objects/Task/validationRules/Prerequisite_Must_Be_Met_To_Complete` | 🟥 RETIRE | Its own comment (`:9-10`): *"this whole rule is discarded at migration step M5 and is not meant to survive it."* It reads `Blocked_By__c` and `Is_Prerequisite_Met__c`, both retiring. |
| `objects/Checklist_Item__c/validationRules/Prerequisite_Must_Be_Met_To_Complete` | 🟩 **KEEP — NEW MODEL** | Same `fullName`, different object. **Do not let a `destructiveChanges` entry name it.** |
| `objects/Activity/validationRules/Prerequisite_Must_Be_Met_To_Complete` | ⚠ **NO SOURCE FILE EXISTS** | Glob over `objects/Activity/**/*.xml` returns 20 files, none a validation rule. **But** `objects/Task/validationRules/...:34-40` says in capitals: *"THE STALE `objects/Activity/validationRules/Prerequisite_Must_Be_Met_To_Complete` ORG COMPONENT MUST BE REMOVED SEPARATELY. Deleting the source file does not delete the deployed org component."* ⇒ **The brief is right that a third copy may exist — but it is an ORG-ONLY ORPHAN, invisible to every repo sweep, and whether it was ever removed is unverifiable from here.** See §5 R0 for the probe and §5 Step 5 for the fix. |

**Other metadata:**

| Component | Verdict | Evidence |
|---|---|---|
| `objects/Task/listViews/Transaction_Tasks_by_Group` | 🟥 RETIRE | Columns `Task_Group__c`, `Task_Sequence__c`, `Task_Owner_Label__c`; filter on `Task_Group__c` (`:4-13`). **It must go BEFORE the fields** — see §5. |
| `objects/Transaction__c/fields/Tasks_Fanned_Out__c` | 🟨 KEEP-FOR-NOW → RETIRE **LAST** | §4.1 |
| `objectTranslations/Transaction__c-en_US/Tasks_Fanned_Out__c.fieldTranslation-meta.xml` | 🟨 Follows the field | Must be in the same destructive payload. ✅ Verified: there is **no** `objectTranslations/Activity-en_US/` or `Task-en_US/` directory, so the eight `Activity` fields carry no translation files. |
| `customPermissions/Transaction_Task_Actions` | 🟥 RETIRE | §3.4 — **GATE-B11 answered.** |
| `customPermissions/Transaction_Prereq_Override` | 🟩 **KEEP** | §3.4 |
| `permissionsets/Transaction_Prereq_Override_Access` | 🟦 AMEND | Keep the file and the `<customPermissions>` block (`:66`). Strip the four `Task.*` `fieldPermissions` (`:90,95,100,105`). Rewrite the description (`:62`) — it currently says *"the four checklist identity fields"*, meaning Task fields. |
| `permissionsets/DPEG_Task_Edit` | 🟦 AMEND | Strip 9 `Task.*` blocks: `Blocked_By__c`(`:146`), `Description`? **no**, `Is_Prerequisite_Met__c`(`:186`), `Task_Group__c`(`:201`), `Transaction_Deal__c`(`:216`), `Verbal_Verification_Completed__c`(`:221`), `Verified_By__c`(`:226`), `Verified_At__c`(`:231`), `Verification_Phone__c`(`:236`). Plus the `<customPermissions>Transaction_Task_Actions</customPermissions>` block (`:41`). 🟩 **KEEP** `Task_Owner_Label__c`(`:206`), `Task_Sequence__c`(`:211`), `Conditional__c`(`:156`) — §2.2 — and every `Onboarding*` / `Blocked_Reason__c` / `Source_System__c` / `Description` / `WhatId` / `ActivityDate` block. |
| `permissionsets/DPEG_TaskChecklist_View` | 🟦 AMEND (**not** retire) | ⚠ Its own `<description>` (`:3`) says *"the Transaction **and Onboarding** checklists"*, and it grants `Task_Owner_Label__c` (`:11`), which PM reads. It is a member of `DPEG_Junior_Analyst_PSG` (`:115`). ⇒ Strip 7 of 8 blocks; keep `Task_Owner_Label__c`. 🟡 **Ask the user:** if the Junior Analyst persona never opens an `Onboarding__c`, the whole set is retirable and the PSG entry with it. I have no way to determine that from source. |
| `permissionsets/DPEG_Apex_Access` | 🟦 AMEND | `<apexClass>TransactionTaskController</apexClass>` (`:559`) and the header note at `:82`. 🔴 **A `classAccesses` entry for a deleted class blocks the permission-set deploy** — this must be in the same payload. |
| `manifest/package.xml` | 🟦 AMEND | Explicit members: classes at `:94-103`, the 8 `Activity.*` fields at `:250-257` (⚠ `:245 Activity.Conditional__c`, `:251 Activity.Task_Owner_Label__c`, `:252 Activity.Task_Sequence__c` **STAY**), the list view at `:2067`, `Transaction__c.Tasks_Fanned_Out__c` at `:752`. |
| `pathAssistants/Transaction_Path` | 🟩 **KEEP — DO NOT TOUCH** | `:29` lists `Tasks_Complete__c` in `<fieldNames>`. That field stays (§4.2). Recorded here because **an active Path step referencing a field blocks that field's deletion** — a reason to be certain the counters are out of scope. |

### 3.3 LWC

| Component | Verdict | Evidence |
|---|---|---|
| `lwc/utilsTransactionChecklist` | 🟦 AMEND | RETIRE `normalizeLegacyGroups` (`:346`), `LEGACY_CRITICAL_RE` (`:144`), `LEGACY_WIRE_RE` (`:147`), `MODEL_LEGACY` (`:65`) and `modelFor` (`:168`). 🟩 **KEEP the checklist-model regex constant** — the file states at `:152-155` that the two pairs were *"declared SEPARATELY on purpose: deleting the legacy pair at M5"* must not disturb the new one. Keep the module: `phaseFor`, the checklist normaliser and the capture-mode logic are new-model code. |
| `lwc/utilsTransactionChecklist/__tests__` | 🟦 AMEND | The whole `normalizeLegacyGroups` describe block (`:304-410`) and the `modelFor` block (`:54-72`) go. |
| `lwc/transactionTaskGroups` (×4 FlexiPage instances) | 🟦 AMEND | Drop the `getTaskGroups` / `completeTask` / `completeWireVerification` imports (`:15-17`), the `@wire(getRecord)` on `CHECKLIST_FANNED_OUT_FIELD` (`:5`), the `modelFor` branch (`:113-128`), and the `anti-fraud` subject regex. 🟩 The component and all four FlexiPage instances **stay**. |
| `lwc/transactionChecklistSummary` | 🟦 AMEND | `getTaskGroups` import (`:5`), `MODEL_LEGACY` branch (`:8`), `normalizeLegacyGroups` (`:11`), discriminator (`:41-58`). |
| `lwc/transactionPhaseCards` | 🟦 AMEND | `getTaskGroups` (`:5`), `MODEL_LEGACY` (`:8,64`), `normalizeLegacyGroups` (`:12,105`), `@wire(getTaskGroups)` (`:87`). |
| Jest suites for all three | 🟦 AMEND | Each mocks `TransactionTaskController.getTaskGroups`. ⚠ `transactionTaskGroups.test.js:308,317` are the explicit *"wires ONLY the checklist Apex when true / ONLY the legacy Apex when false"* pair — both die; the "true" half needs replacing with an unconditional assertion or the coverage silently disappears. |
| `lwc/transactionTaskCards` | 🟩 **KEEP — NO CHANGE** | Its header (`:12-19`) states it sums the four `Transaction__c` counters via `TransactionController.getTaskSummary` and **never reads rows**, so it never learned to discriminate. Model-agnostic. |
| `lwc/transactionCriticalDates`, `lwc/activeTransactionsList` | 🟩 KEEP | Counter/LDS readers only. |
| `flexipages/Transaction_Record_Page` | 🟩 **KEEP — NO CHANGE** | 🔴 A FlexiPage deploy **replaces** the org copy with no version history (two tabs were lost this way on 2026-08-25). There is no reason to touch this file; keeping it out of the payload is itself a control. |

#### 🔴 On removing the discriminator: it is safe, but not for the reason the brief gives

The brief says *"removing the discriminator is only safe once no deal can be on the legacy model."*
That is true and it now holds — but there is a **second** consequence nobody has stated, and it changes
behaviour on deals that exist today:

`modelFor(false)` → `MODEL_LEGACY`. `Checklist_Fanned_Out__c` is `false` on **every Transaction that has
not yet had a contract executed** — not only on legacy deals. Today those deals render the *legacy*
component (empty, with the "Set the Contract Executed Date" empty state). After the discriminator is
removed they will render the *checklist* component with **zero rows**.

⇒ **Verify the checklist components' empty state is at least as good as the legacy one before shipping**,
and make it a named acceptance check (§7 UI-4). This is the one user-visible regression risk in the
whole change and it is invisible to every automated test in the suite.

### 3.4 🔴 GATE-B11 answered: `Transaction_Task_Actions` retires; `Transaction_Prereq_Override` stays

I nearly recorded the opposite, and the correction is worth stating because the evidence looks
identical at grep distance.

**`Transaction_Task_Actions` — RETIRE.** Two new-model files name it:
- `ChecklistItemService.cls:22` — *"So **that class had to** (a) authorise in the APPLICATION via the
  `Transaction_Task_Actions` custom permission…"* — past tense, describing `TransactionTaskService`.
  Lines 25-26 then say *"✅ `Checklist_Item__c` **IS AN ORDINARY CUSTOM OBJECT**. Its CRUD and FLS are
  grantable by an ordinary permission set."*
- `ChecklistItemSelector.cls:174-176` — identical historical framing.

Neither calls it. The only `FeatureManagement.checkPermission(TASK_ACTION_CUSTOM_PERMISSION)` in the
repo is `TransactionActionPermissionService.cls:490`, reached only from `hasTaskActionAccess` /
`assertTaskActionAccess`, whose only production consumer is `TransactionTaskService`
(`TransactionActionPermissionService.cls:143`, *"the only task-gate consumer"*).
⚠ `DPEG_Disposition_View.permissionset-meta.xml:568` names it in a comment listing custom permissions —
**a comment, not a grant.** Verify that before deploying.

**`Transaction_Prereq_Override` — KEEP.** `ChecklistItemPrerequisiteService.cls:554` is a real
conjunct in a live refusal branch:
```apex
&& !TransactionActionPermissionService.hasPrereqOverrideAccess()) {
    return MSG_DISARM;
```

**Method:** grep hits on a permission/field name are not consumers. Open every one.

### 3.5 Reports, list views, dashboards, formulas — the full reference sweep

Swept `*.report-meta.xml`, `*.listView-meta.xml`, `*.dashboard-meta.xml`, `*.flow-meta.xml`,
`*.flexipage-meta.xml`, `*.layout-meta.xml`, `*.reportType-meta.xml`, `*.pathAssistant-meta.xml`,
`*.quickAction-meta.xml`, `*.compactLayout-meta.xml` for all eleven `Activity` field names and the six
`Transaction__c` counter names.

**Result — and this is the good news of the whole change:**

| Surface | References to a RETIRING `Activity` field | References to a RETIRING `Transaction__c` field |
|---|---|---|
| Reports (`reports/**`, all 11 under `Transactions/`) | **ZERO** | **ZERO** |
| Dashboards (`dashboards/**`) | **ZERO** | **ZERO** |
| FlexiPages | **ZERO** | **ZERO** |
| Layouts | **ZERO** | **ZERO** |
| Compact layouts | **ZERO** | **ZERO** |
| Path assistants | **ZERO** | **ZERO** (`Transaction_Path:29` names `Tasks_Complete__c`, which stays) |
| Quick actions | **ZERO** | **ZERO** |
| Flows | **ZERO** | **ZERO** (`Onboarding_Task_Fanout:41` is `Onboarding__c.Tasks_Fanned_Out__c` — §2.4) |
| List views | **ONE**: `Task.Transaction_Tasks_by_Group` (3 columns + 1 filter) | **ZERO** |
| Formula fields | **ZERO** | **ZERO** (`Tasks_Open__c` / `Tasks_Display__c` are formulas over the KEPT counters) |

**What the eleven Transaction reports actually read** (verified, correcting a vague claim in the brief):
`Total_Tasks` → `Tasks_Total__c`; `Total_Completed_Tasks` → `Tasks_Complete__c`; `Overdue_Tasks` →
`Tasks_Overdue__c`; `Open_Wire_Risks` → `Wire_Open_Risks__c`; `Total_Open_Tasks` → `Tasks_Open__c` (a
formula over the counters). All are `reportType CustomEntity$Transaction__c`. The remaining six report
on `Transaction__c` without naming a counter. `Transaction_Dashboard_Junior` reads four counter columns
(`:39,65,90,142`).

⇒ **No report, dashboard or formula anywhere references anything this change deletes.** Reports do not
block field deletion and fail silently in this repo, which is exactly why this sweep had to be run — the
answer is simply that there is nothing to break.

### 3.6 Scripts

| Script | Verdict | Evidence |
|---|---|---|
| **`scripts/fanout-seeded-transactions.apex`** | 🟥 **DELETE OUTRIGHT — and this is the highest-value item in the change** | Its own header (`:60-69`) says: *"🔴 SO THE REAL HAZARD IS THE OPPOSITE OF 'INERT': this is now the only remaining way to put a deal back onto the LEGACY Task model, and it does so with no warning, on EVERY Active Transaction in the org… ⇒ DO NOT RUN THIS AGAINST usman-dpeg."* It re-arms `Tasks_Fanned_Out__c = false` (`:79`) and calls `TaskFanoutService.fanOutNow(ids)` (`:83`). ⚠ **`:75` also does `delete [SELECT Id FROM Task WHERE WhatId IN :ids OR Transaction_Deal__c IN :ids]` — the `WhatId` arm deletes unrelated Activity on those deals.** A do-not-run comment is a weaker control than deletion, and the class it calls is being deleted anyway (compile-safe). **Recommendation: delete, do not archive.** |
| `scripts/backfill-task-blocked-by.apex` | 🟥 RETIRE | Phase 0 backfill; writes `Task.Blocked_By__c`. |
| `scripts/seed-transaction-progress.apex`, `scripts/seed-transactions-nondestructive.apex` | 🟦 AMEND | Reference `Tasks_Fanned_Out__c` and legacy Task fields in comments and queries. 🔴 **Seed scripts RESURRECT retired artifacts on the next org rebuild** — the most commonly-missed item in this repo's retirement checklist. |
| `scripts/cutover-transaction-to-checklist-model.apex` | 🟨 KEEP-FOR-NOW | The Part-A runbook; reads `Tasks_Fanned_Out__c` (`:66,81,322,472,487`). Retire with the rollback window. |
| `scripts/migrate-transaction-checklists.apex`, `reconcile-checklist-migration.apex`, `rollback-transaction-checklist-migration.apex` | 🟨 KEEP-FOR-NOW | Follow the `ChecklistMigration*` stack. |
| `scripts/load-task-group-defs.apex`, `scripts/load-transaction-task-defs.apex` | 🟩 **KEEP — LIVE** | §2.3 |
| `scripts/seed-onboarding*.apex` | 🟩 KEEP — DO NOT TOUCH | PM |

### 3.7 `TestDataFactory` — 🔴 the suite-wide compile break

`TestDataFactory` writes three retiring fields in three methods:

```
:1400  createChecklistTasks(Integer, Id, Boolean)   -> Transaction_Deal__c, Task_Group__c, Task_Sequence__c
:1420  createChecklistTasks(Integer, Boolean)       -> delegates
:1431  createChecklistTasksFor(List, Integer, Bool) -> same three fields
```

Consumers: `TaskPrerequisiteServiceTest` (4), `TaskSelectorTest` (2), `TaskRollupDualModelGuardTest` (1).

🔴 **There is no intermediate state that compiles.** `TestDataFactory` is referenced by essentially every
test class, so if it names a deleted field, **the whole suite fails to compile** — not fails, *fails to
compile*. The three factory methods, their three consumers, and the field deletion must ship in **one
payload**.

⚠ `TestDataFactory:2703` sets `Transaction__c.Tasks_Fanned_Out__c = true` in
`createTransactionsOnChecklistModel`, and its header (`:2674-2678`) says that is **not** redundant:
`ChecklistFanoutServiceTest.createsChecklistsAndItemsForALoanDeal` asserts it is *still true* after a
checklist fan-out as its proof the two guards are independent (`ChecklistFanoutServiceTest:91-98`).
⇒ **Retiring `Tasks_Fanned_Out__c` requires rewriting that assertion**, and rewriting it removes the
suite's only proof that the two fan-out guards are independent. Replace it with an assertion that
`ChecklistFanoutService` is keyed on `Checklist_Fanned_Out__c` alone, or the coverage silently vanishes.
✅ The factory's *flow-suppression* device already moved off this field on 2026-09-03 (`:2650-2665`) —
it now nulls `Contract_Executed_Date__c`, which both flows share. That part is already safe.

---

## 4. The four questions the brief said must not be skipped

### 4.1 Is `Tasks_Fanned_Out__c` retirable, and in what order?

**Yes — LAST, after `TaskFanoutService` is deleted. Never before.**

The field is a mutex whose `true` value is `TaskFanoutService.fanOutNow`'s **only** dedupe guard
(`TaskFanoutService.cls:174`, cited in `scripts/fanout-seeded-transactions.apex:56`). It is no longer
read by any flow (`Transaction_Task_Fanout:24`: *"Tasks_Fanned_Out__c IS NOT READ BY THIS FLOW ANY MORE
AND IS NOT CLEARED BY ANYTHING"*).

**The ordering hazard, stated precisely:**

| Order | Result |
|---|---|
| Delete the field **first** | `TaskFanoutService` still exists. `TransactionSelector.BASE_FIELDS` (`:107`) is a **dynamic string list**, so this does **not** fail to compile — it throws at runtime, or, worse, if anything strips the field from the guard, `fanOutNow` loses its dedupe and **any** caller can re-create 82 Tasks on a deal that already has 82 checklist items. 🔴 **Refuse this order.** |
| Delete `TaskFanoutService` + `TaskFanoutQueueable` + `fanout-seeded-transactions.apex` **first**, then the field | ✅ Correct. Once no code reads it, the field is inert data. |

**Also required before the field goes:** the `ChecklistFanoutServiceTest:91-98` assertion rewrite
(§3.7), `TestDataFactory:2703`, `DealTransactionGateServiceTest:129,451`, the
`objectTranslations/Transaction__c-en_US/Tasks_Fanned_Out__c` file, `manifest/package.xml:752`, and the
three `scripts/seed-transaction*.apex` references.

🟡 **A defensible alternative the user may prefer: KEEP `Tasks_Fanned_Out__c` as a permanent inert
historical marker.** It is one checkbox. On TXN-0285 its `true` value is the only remaining evidence
that the deal was ever on the Task model, and once `TaskFanoutService` is gone the field cannot arm
anything. Deleting it buys schema hygiene and costs a permanently reserved API name. **This is tidying,
not a defect fix — say so and let the user choose.** My recommendation: delete it, but only in Step 6,
and be willing to drop it from scope without argument.

### 4.2 `Tasks_Total__c` / `Tasks_Complete__c` / `Tasks_Overdue__c` / `Wire_Open_Risks__c`

🟩 **CONFIRMED NOT RETIRABLE. They are the new model's counters too.** Verified consumers:

- **Written by BOTH rollups** — `ChecklistRollupService` for new deals, `TaskRollupService` for legacy
  (`lwc/transactionTaskCards/transactionTaskCards.js:17-19` states this explicitly), plus
  `ChecklistFanoutService`'s PASS 4.
- **4 reports + 1 formula report:** `Total_Tasks`, `Total_Completed_Tasks`, `Overdue_Tasks`,
  `Open_Wire_Risks`, `Total_Open_Tasks` (§3.5).
- **1 dashboard:** `Transaction_Dashboard_Junior:39,65,90,142` — including the **Wire Sentinel tile**.
- **`pathAssistants/Transaction_Path:29`** — `Tasks_Complete__c` in `<fieldNames>`. 🔴 An active Path
  step referencing a field **blocks that field's deletion**.
- **Two formula fields:** `Transaction__c.Tasks_Open__c`, `Transaction__c.Tasks_Display__c`.
- **`compactLayouts/Transaction_Highlights`** (the `0 / 82` tile).
- **LWCs:** `transactionTaskCards`, `activeTransactionsList`, `transactionChecklistSummary`.
- **Apex:** `TransactionController.getTaskSummary`, `TransactionSelector:470,538`.
- **Permission sets:** `DPEG_Transaction_View`, `DPEG_Transaction_Edit`.

🟡 **THE NAMING MISMATCH IS REAL AND IS FLAGGED, NOT BUNDLED.** After M5, four fields named `Tasks_*`
are fed exclusively by a `Checklist_Item__c` model. `Tasks_Display__c` and `Tasks_Open__c` compound it.
Per this repo's standing practice, an API-name change is **delete + create**, never in-place, and a
deleted name stays reserved until permanently ERASED. Renaming five fields would touch 5 reports, 1
dashboard, 1 Path, 1 compact layout, 3 LWCs, ~6 Apex classes and 4 permission sets. **That is its own
change, with its own gate.** Do not let it ride along on M5. Recorded here as **OQ-M5-1**.

### 4.3 Reports, list views, formulas — enumerated

See §3.5. The answer is **one list view and nothing else**. The sweep still had to be run: this repo has
a documented incident where reports referencing a deleted field broke silently, and reports do not block
deletion.

### 4.4 The additive rule

This repo's standing practice is **add → backfill → repoint → retire, never rename**
(precedent: `Unit__c` → `Unit_Label__c`, 5 deploys / ~60 files for one field).

**M5 is the RETIRE step of a sequence whose first three steps are already complete:**

| Step | Status |
|---|---|
| ADD — `Checklist__c` / `Checklist_Item__c` / `Checklist_Fanned_Out__c` and the parallel field set | ✅ Done (Phases 1-2) |
| BACKFILL — populate the new model | ✅ Done for TXN-0285 by delete-and-re-fan (cutover A1/A2), not by `ChecklistMigrationService` |
| REPOINT — flow, LWCs, stage gate, rollups | ✅ Done 2026-09-03 (`Transaction_Task_Fanout`) |
| **RETIRE** | ⬅ **this document** |

**Nothing in M5 is a rename.** No new field is created. That is why the change is unusually cheap.

**What is irreversible at each step** — see §5.

---

## 5. The ordered retirement sequence

Each step names its reversal. **Steps in R0 are read-only.**

### R0 — PRE-FLIGHT (read-only). Any failure is a STOP.

| # | Probe | Expected | If it differs |
|---|---|---|---|
| P1 | `SELECT COUNT() FROM Task WHERE Transaction_Deal__c != null` | **0** | 🔴 **HARD STOP.** Every field deletion below destroys data. The brief's central premise fails. |
| P2 | `SELECT COUNT() FROM Task WHERE Task_Group__c != null` | **0** | Second, independent probe on a different field — a non-zero here with a zero at P1 means orphaned checklist Tasks exist. |
| P3 | `SELECT Id, Tasks_Fanned_Out__c, Checklist_Fanned_Out__c, Tasks_Total__c, Tasks_Complete__c, Wire_Open_Risks__c FROM Transaction__c` | 1 row; `Checklist_Fanned_Out__c = true`; `Wire_Open_Risks__c` **non-zero** | A zero `Wire_Open_Risks__c` means the new model is already silently mis-reporting; fix that before retiring the old one. |
| P4 | `SELECT COUNT() FROM Checklist_Item__c` | **82** | |
| P5 | `SELECT Id, ValidationName, Active, EntityDefinition.QualifiedApiName FROM ValidationRule WHERE ValidationName = 'Prerequisite_Must_Be_Met_To_Complete'` (Tooling) | Rows for `Task` **and** `Checklist_Item__c`. **Record whether an `Activity` row also exists.** | 🔴 §3.2 — this is the ONLY way to discover the org-only orphan. It cannot be answered from source. |
| P6 | `SELECT Id, ApiVersion FROM ApexClass WHERE Name IN (...)` for all nine retiring classes | All present | Confirms the repo and org agree before a destructive deploy. |
| P7 | `SELECT COUNT() FROM Task WHERE Onboarding__c != null` | **> 0** if PM is live | Establishes the **negative control**: PM Tasks must still exist and still work after every step. |
| P8 | `SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE PermissionSet.Name IN ('DPEG_TaskChecklist_View','DPEG_Task_Edit')` | Record it | Feeds the §3.2 `DPEG_TaskChecklist_View` question. Group/permission-set assignment is not readable from source. |
| P9 | 🔴 **Confirm the Recycle-Bin decision with the user** (§5, Step 0) | — | |

⚠ **Do not accept a green `sf project deploy validate` as evidence for any of these.** A dry-run skips
byte-identical components and reports green without validating them, and this repo has a recorded
"689/689 deployed, 0 errors" on a deploy that rolled back everything.

### Step 0 — 🔴 THE RECYCLE-BIN DECISION. This gates everything else.

The 82 Tasks deleted on 2026-09-02 are `undelete`-able until **~2026-09-17**.
`design-checklist-cutover-and-stage-gate.md` §A6 R1-R5 is the cutover rollback, and it requires:

1. `ChecklistMigrationService.rollback` (which calls `TaskRollupService.recalc`), then
2. `undelete [SELECT Id FROM Task WHERE Transaction_Deal__c = :DEAL_ID ALL ROWS]` — **which needs
   `Task.Transaction_Deal__c` to still exist**, then
3. `TaskRollupService.recalc` recomputing from the restored 82 rows — **which needs `TaskRollupService`,
   `TaskSelector.selectByTransactionDealIds`, `Task_Group__c`, and
   `Verbal_Verification_Completed__c` to still exist.**

⇒ **Steps 3 and 4 below FORECLOSE the cutover rollback. Steps 1 and 2 do not.**

**Recommendation: split the change at that line.**

| Wave | Contents | Timing |
|---|---|---|
| **Wave 1** (safe now) | Steps 1-2 — the fan-out stack, Phase 0, the controller/service, the LWC branches, the list view, the Task VR, the permission-set grants, and `fanout-seeded-transactions.apex` | 🟢 **Ship now.** None of it is used by the rollback. Deleting `fanout-seeded-transactions.apex` **increases** safety immediately. |
| **Wave 2** (after ~2026-09-17) | Steps 3-6 — `TaskRollupService`, the `ChecklistMigration*` stack, the `TaskSelector` rollup/migration methods, the eight `Activity` fields, `Tasks_Fanned_Out__c` | 🟡 **Wait for the window to close**, or get an explicit user decision to forgo the rollback early. |

⚠ **Wave 1 is not entirely rollback-neutral and I will not pretend otherwise.** Deleting
`TaskFanoutService` removes the ability to *reconstruct* the 82 Tasks from CMDT if the undelete window
lapses. But that was always a *reconstruction* (new Ids, new CreatedDate, new field history), never a
restore, and `design-checklist-cutover-and-stage-gate.md` §A6 already says so. Raise it; do not hide it.

### Step 1 — Break the entry points (Wave 1). **Nothing is deleted yet.**

Order within the step matters:

1. **`scripts/fanout-seeded-transactions.apex` — DELETE.** No deploy needed (scripts are not metadata).
   Do this first: it is the only remaining thing that can manufacture the dual-model state, and it
   removes the risk for the rest of the change.
   **Reversal:** `git checkout` the file.
2. **LWC branch removal + `TransactionTaskController` / `TransactionTaskService` deletion + the
   `DPEG_Apex_Access` `classAccesses` edit — ONE payload.** A `classAccesses` entry for a deleted class
   blocks the permission-set deploy, so they cannot be split.
   **Reversal:** redeploy the prior bundle. Data untouched.
3. **`objects/Task/listViews/Transaction_Tasks_by_Group` — destructive.** Must precede the field
   deletions in Step 4. **Reversal:** redeploy the file.

### Step 2 — Retire Phase 0 and the fan-out (Wave 1). ONE payload.

Constructive + destructive in a **single `--manifest` payload** (this repo has measured that
`--post-destructive-changes` cannot pair with `--source-dir`):

- **Constructive:** amended `TaskRollupTriggerHandler` (remove the two `TaskPrerequisiteService` calls
  ONLY — leave `recalcDeals` for Step 3), amended `TaskRollupTriggerHandlerTest`, amended
  `TaskRollupTrigger` header, amended `TransactionActionPermissionService` + test, amended
  `DPEG_Task_Edit` (drop `Transaction_Task_Actions`), amended `Transaction_Prereq_Override_Access`
  (keep the custom permission, keep the four Task field grants **for now** — they die in Step 4),
  amended `manifest/package.xml`.
- **Destructive:** `TaskPrerequisiteService`, `TaskPrerequisiteServiceTest`, `TaskFanoutService`,
  `TaskFanoutServiceTest`, `TaskFanoutQueueable`, `TransactionTaskService`,
  `TransactionTaskServiceTest`, `Task.Prerequisite_Must_Be_Met_To_Complete` (validation rule),
  `Transaction_Task_Actions` (custom permission).
- **Also:** delete `scripts/backfill-task-blocked-by.apex`.

🔴 **A PermissionSet deploy REPLACES its entire `fieldPermissions` block.** Every amended permission set
must ship as a **complete superset of the org**, retrieved and diffed immediately before the deploy.

**Reversal:** redeploy the prior source. ⚠ **Deleted Apex classes and the custom permission come back by
redeploy; a deleted CUSTOM PERMISSION's API name is reserved until erased** — but nothing here recreates
a name, so that is not yet a hazard.

### Step 3 — Retire `TaskRollupService` and the migration stack (Wave 2). ONE payload.

- **Constructive:** `TaskRollupTriggerHandler` with `collectDealIds` / `recalcDeals` / the four call
  sites removed; `TaskSelector` with 5 methods and their SYSTEM_MODE mode-inventory entries removed;
  `TaskSelectorTest`; `TransactionSelector` with `selectByIdsWithConditionFields` + `BASE_FIELDS`
  removed and its consumer inventory corrected; `TransactionStageGateService` header; `TestDataFactory`
  with the three `createChecklistTasks*` methods removed.
- **Destructive:** `TaskRollupService`, `TaskRollupServiceTest`, `TaskRollupDualModelGuardTest`,
  `ChecklistMigrationService` + `Domain` + `Queueable` + `AuditService` + their four test classes.
- **Also:** delete `scripts/cutover-transaction-to-checklist-model.apex`,
  `scripts/migrate-transaction-checklists.apex`, `scripts/reconcile-checklist-migration.apex`,
  `scripts/rollback-transaction-checklist-migration.apex`.

🔴 **`TaskRollupTriggerHandler`'s four `recalcDeals` call sites MUST be in the same payload as
`TaskRollupService`'s deletion.** Removing the class first is a compile break; removing the call sites
first leaves a class with no caller (harmless but pointless). Same payload.

🔴 **This is the point of no return for the cutover rollback.** After Step 3, `design-checklist-cutover-
and-stage-gate.md` §A6 R1-R5 cannot be executed at all.

**Reversal:** redeploy the prior source. Data untouched. **Deleted classes break anything resolving them
by NAME** — this repo has a recorded incident from a permission-set retirement — so re-check
`DPEG_Apex_Access` and every `classAccesses` block after any partial rollback.

### Step 4 — Delete the eight `Activity` fields (Wave 2). ONE payload.

- **Constructive:** `DPEG_Task_Edit` (9 `fieldPermissions` blocks removed, complete file),
  `DPEG_TaskChecklist_View` (7 removed, complete file), `Transaction_Prereq_Override_Access` (4 removed,
  complete file, `<customPermissions>` retained), `manifest/package.xml`, amended
  `scripts/seed-transaction-progress.apex` and `scripts/seed-transactions-nondestructive.apex`.
- **Destructive:** `Activity.Transaction_Deal__c`, `Activity.Task_Group__c`,
  `Activity.Verbal_Verification_Completed__c`, `Activity.Verified_By__c`, `Activity.Verified_At__c`,
  `Activity.Verification_Phone__c`, `Activity.Blocked_By__c`, `Activity.Is_Prerequisite_Met__c`.

🔴 **DO NOT include `Activity.Task_Owner_Label__c`, `Activity.Task_Sequence__c` or
`Activity.Conditional__c`.** §2.2.
🔴 **DO NOT write `Task.<Field>` in destructiveChanges** — the fields are declared under
`objects/Activity/fields/`. (The permission sets, conversely, must say `Task.<Field>` — §2.4.)
🔴 **`Checklist_Item__c` carries same-named `Blocked_By__c`, `Is_Prerequisite_Met__c`,
`Verbal_Verification_Completed__c` and `Verification_Phone__c`, and `Wire__c` carries
`Verbal_Verification_Completed__c`. Naming any of them here is a production outage.**

**Reversal — 🔴 THIS IS THE IRREVERSIBLE STEP.** A deleted field takes its data with it. **It is safe
only because P1/P2 proved zero rows.** Redeploying the field files recreates empty fields; the org holds
nothing to lose. **The API names stay RESERVED until permanently ERASED from Setup's Deleted Fields
list, and erasing is irreversible.** Do not erase in this change — leave them in the deleted list. There
is no plan to reuse any of these names, so nothing depends on erasing them.

### Step 5 — Remove the org-only orphan validation rule (Wave 2, conditional).

**Only if P5 found an `Activity`-bound row.** It has no source file, so `sf project deploy` will never
touch it. It needs its own `destructiveChanges.xml` naming `Activity.Prerequisite_Must_Be_Met_To_Complete`
under `<name>ValidationRule</name>`.

⚠ It is **already inert** (`activity-validation-rule-does-not-enforce-on-task`: it binds to the abstract
parent and fires on neither Task nor Event — proven functionally, not just by describe). So this is
hygiene, not a fix, and it can be skipped without behavioural consequence. Say so.
⚠ After Step 4 it references two deleted fields. Verify whether an inert rule with dangling field
references still deploys/behaves — I could not determine this from source.

**Reversal:** none needed; it does nothing today.

### Step 6 — `Tasks_Fanned_Out__c` (Wave 2, optional — see §4.1).

- **Constructive:** `ChecklistFanoutServiceTest` (rewritten independence assertion),
  `TestDataFactory:2703`, `DealTransactionGateServiceTest:129,451`, `manifest/package.xml:752`, the two
  seed scripts.
- **Destructive:** `Transaction__c.Tasks_Fanned_Out__c` and
  `objectTranslations/Transaction__c-en_US/Tasks_Fanned_Out__c`.

**Reversal:** irreversible as to data (one boolean on one deal). Name reserved until erased.

---

## 6. Rollback plan

| Scenario | Rollback |
|---|---|
| Wave 1 breaks the Transaction record page | Redeploy the prior LWC bundle + `TransactionTaskController` + `TransactionTaskService` + `DPEG_Apex_Access` as one payload. Data untouched. |
| Wave 1 breaks Property Management | 🔴 It should not — Step 2 touches no Onboarding code path. If it does, the cause is almost certainly the `DPEG_Task_Edit` **superset** rule (a permission-set deploy replaces its whole `fieldPermissions` block). Retrieve the org copy, diff against HEAD, redeploy the union. |
| Wave 2 Step 3 breaks a compile | Redeploy prior source in one payload. `TaskRollupService` returns; the migration stack returns. |
| Wave 2 Step 4 deleted a field that was in use | Redeploy the field file. **The DATA is gone** — recoverable only if P1/P2 were wrong, in which case the correct answer is "P1/P2 were the gate and they failed", not a rollback. |
| The whole cutover must be reversed | 🔴 **Only possible BEFORE Step 3, and only until ~2026-09-17.** Follow `design-checklist-cutover-and-stage-gate.md` §A6 R1-R5 verbatim, including R1-before-R2 ordering (undeleting first hits the claim-flag tiebreak and the recompute is silently skipped) and A6's warning that **after the flow repoint, R1's un-claim re-fires the flow and undoes the rollback** — so deactivate `Transaction_Task_Fanout` first, then restore it. |

**What is NOT the rollback:** deleting TXN-0285. It destroys `Wire__c` links, field history, and the
Opportunity gate flags maintained by `DealTransactionGateService`.

---

## 7. Test plan

### Must still pass, unchanged — the Property Management negative control
🔴 **The single most important assertion set in this change.** Named explicitly in every payload:
`OnboardingFanoutServiceTest`, `OnboardingTaskRollupServiceTest`, `OnboardingControllerTest`,
`OnboardingServiceTest`, `TaskRollupTriggerHandlerTest` (Onboarding methods), `TaskSelectorTest`
(the 4 Onboarding methods).
Specifically: `OnboardingFanoutServiceTest` must still prove `Task_Sequence__c`, `Task_Owner_Label__c`
and `Conditional__c` are written, and `OnboardingControllerTest` must still prove
`Task_Owner_Label__c` renders. **If those three fields were wrongly deleted, these are what catch it.**

### Must still pass, unchanged — Broker Protection and Disposition
`TaskSelectorTest` (the 4 Broker Protection methods + `selectByWhatIdAndSubjects`),
`WireServiceTest`, `WireSelectorTest` (the `Wire__c.Verbal_Verification_Completed__c` twin —
§2.4), `DispositionActionPermissionServiceTest`.

### Must still pass, unchanged — the new model
`ChecklistFanoutServiceTest`, `ChecklistRollupServiceTest`, `ChecklistItemServiceTest`,
`ChecklistItemPrerequisiteServiceTest`, `ChecklistControllerTest`, `ChecklistCaptureServiceTest`,
`ChecklistCaptureDefProviderTest`, `TransactionStageGateServiceTest`, `TransactionControllerTest`,
`TransactionSelectorTest`, `DealTransactionGateServiceTest`, `ContractExecutionServiceTest`,
`RecordStageAdvanceServiceTest`.
🔴 **`ChecklistItemPrerequisiteServiceTest:355`** — the `Transaction_Prereq_Override` holder test. It is
the proof that §3.4's "keep the custom permission" verdict is right; if it reds, the permission was
wrongly retired.

### Deleted with their subjects
`TaskFanoutServiceTest`, `TaskPrerequisiteServiceTest`, `TransactionTaskServiceTest`,
`TransactionTaskControllerTest`; then (Wave 2) `TaskRollupServiceTest`, `TaskRollupDualModelGuardTest`
and the four `ChecklistMigration*Test` classes.

### Coverage arithmetic — do this BEFORE deploying
🔴 Deleting nine classes and ~six test classes changes org-wide coverage. This repo has a recorded
incident where a deploy reported *"689/689 deployed, 0 errors"* and rolled back everything, because
per-class 75% coverage failed via `codeCoverageWarnings` that no error counter surfaces.
⇒ **Run `RunLocalTests` as a check-only validation on the full payload** and read
`codeCoverageWarnings`, not the error count. Do this per wave.

### Bulk tests
`.claude/rules/bulk-test-rule.md`'s 251-record mandate applies to what **remains**, not to what is
deleted. `TaskRollupTriggerHandlerTest`'s Onboarding bulk methods must keep their 251-row shape.
**No new bulk test is required** — this change adds no code path.

### Jest
`transactionTaskGroups`, `transactionChecklistSummary`, `transactionPhaseCards`,
`utilsTransactionChecklist` — all four suites lose their legacy describe blocks.
⚠ `transactionTaskGroups.test.js:308,317` is a *paired* discriminator assertion; deleting the "false"
half leaves the "true" half asserting nothing. Replace with an unconditional "wires the checklist Apex"
assertion or the coverage silently disappears.
Run `@sa11y/jest` on all four.

### Manual / browser acceptance (the deploy result is not the acceptance criterion)
| # | Check |
|---|---|
| UI-1 | Open TXN-0285. All four phase tabs populate: Open Contract 11, Due Diligence 46, Closing Prep 10, Post-Closing 15. |
| UI-2 | Exactly four rows render CRITICAL (B2, F12, I7, J4). |
| UI-3 | Wire Sentinel dashboard tile **non-zero**. |
| UI-4 | 🔴 **Open a Transaction with NO `Contract_Executed_Date__c`.** Its checklist components must show a sensible empty state, not an error and not a spinner. §3.3 — this is the one behavioural change the automated suite cannot see. |
| UI-5 | Try to complete B3 while B2 is open — must be refused by `ChecklistItemPrerequisiteService.MSG_BLOCKED`. |
| UI-6 | 🔴 Open a PM `Onboarding__c` record. The checklist renders and the **Owner** column is populated (`Task_Owner_Label__c`). |
| UI-7 | The Task object's list-view picker no longer offers "Transaction Tasks by Group", and the six standard Task list views are intact. |

---

## 8. 🔴 Everything I assumed rather than verified

Stated plainly, per the brief's instruction.

| # | Assumption | What would confirm it |
|---|---|---|
| 1 | **Zero legacy Task rows exist org-wide.** Every field-deletion verdict rests on this. | R0 P1 + P2. **Blocking.** |
| 2 | Whether an `Activity`-bound validation rule still exists in the org. Source cannot answer it. | R0 P5 (Tooling). |
| 3 | Whether `DPEG_TaskChecklist_View` can be retired wholesale, i.e. whether the Junior Analyst persona ever opens an `Onboarding__c`. | A user/business answer, plus R0 P8. |
| 4 | Whether a validation rule with dangling field references still deploys cleanly after Step 4. | A check-only validation of Step 5 after Step 4 lands. |
| 5 | Whether `TaskFanoutService.cls:174`'s dedupe guard is the *only* production reader of `Tasks_Fanned_Out__c`. I read the class-header citation at `scripts/fanout-seeded-transactions.apex:56` and every grep hit, but did **not** read `TaskFanoutService.cls:160-180` line by line. | Open that range before Step 6. |
| 6 | That the 15-day Recycle-Bin retention applies and that the 2026-09-02 deletion is still recoverable. Platform constant, not measured here. | `SELECT COUNT() FROM Task WHERE Transaction_Deal__c != null ALL ROWS` — if it returns 82, they are still there. **Add this to R0 as P1b.** |
| 7 | That `manifest/package.xml`'s explicit member list is complete for the retiring classes. I saw `TaskFanoutService`, `TaskRollupService`, `TransactionTaskController` and tests at `:94-103` but did not page the whole `ApexClass` block. | Grep the full block before editing. |
| 8 | That no **profile** grants FLS on the eight fields in a way that blocks deletion. `profiles/**` is force-ignored in this repo, so those 20-hit-per-profile grep results are unverified fiction — but a profile grant in the ORG is real and can block a destructive change. | Attempt the destructive deploy; a `FIELD_INTEGRITY_EXCEPTION` naming a profile is the signal. |
| 9 | I did not verify that the org's deployed `TaskRollupTriggerHandler` matches the working tree. `git status` shows `TaskRollupService.cls`, `TaskSelector.cls`, `TestDataFactory.cls` and others as **modified but uncommitted**. | Retrieve and diff before the first payload. ⚠ This repo has measured a **second concurrent session** building into the same working tree. |

---

## 9. 📋 DESIGN REQUIREMENTS

```
═══════════════════════════════════════════════════════════════════════════════
                    📋 DESIGN REQUIREMENTS — M5 LEGACY TASK RETIREMENT
═══════════════════════════════════════════════════════════════════════════════

🎯 WHAT WAS REQUESTED:
Retire the Transaction arm of the legacy Task-based checklist, now that the org
has cut over to Checklist__c. Preserve everything shared with Property Management
and Broker Protection.

───────────────────────────────────────────────────────────────────────────────
                    🔵 ADMIN WORK (salesforce-admin)
───────────────────────────────────────────────────────────────────────────────

• Run the R0 pre-flight probes (§5 R0, P1-P9 + P1b) and report every result.
  P1/P2 are BLOCKING.
• Delete list view Task.Transaction_Tasks_by_Group (Step 1.3).
• Delete validation rule Task.Prerequisite_Must_Be_Met_To_Complete (Step 2).
  DO NOT touch the Checklist_Item__c rule of the same name.
• Delete custom permission Transaction_Task_Actions (Step 2).
  KEEP Transaction_Prereq_Override.
• Amend permission sets, each shipped as a COMPLETE SUPERSET of the org copy:
  DPEG_Task_Edit, DPEG_TaskChecklist_View, Transaction_Prereq_Override_Access,
  DPEG_Apex_Access.
• Delete 8 Activity fields (Step 4) — exact list in §5 Step 4.
• Conditionally delete the org-only Activity-bound validation rule (Step 5).
• Optionally delete Transaction__c.Tasks_Fanned_Out__c + its objectTranslation
  (Step 6) — user decision per §4.1.
• Amend manifest/package.xml.

───────────────────────────────────────────────────────────────────────────────
                    🟢 DEVELOPMENT WORK (salesforce-developer)
───────────────────────────────────────────────────────────────────────────────

• Delete 9 Apex classes + their tests across two waves (§5 Steps 2 and 3).
• Amend 8 Apex classes (§3.1) — TaskRollupTriggerHandler, TaskRollupTrigger
  (comment only), TaskSelector, TransactionSelector,
  TransactionActionPermissionService, TransactionStageGateService,
  TestDataFactory, plus their test classes.
• Amend 4 LWC bundles and their Jest suites (§3.3).
• Delete 2 scripts, amend 2, delete 4 more in Wave 2 (§3.6).

───────────────────────────────────────────────────────────────────────────────
                    🔗 EXECUTION ORDER
───────────────────────────────────────────────────────────────────────────────

R0 pre-flight (BLOCKING) → Step 0 Recycle-Bin decision (BLOCKING)
  → WAVE 1: Step 1 (entry points) → Step 2 (Phase 0 + fan-out)
  → [wait for ~2026-09-17 or an explicit user waiver]
  → WAVE 2: Step 3 (rollup + migration) → Step 4 (fields, IRREVERSIBLE)
            → Step 5 (org orphan) → Step 6 (optional flag)

Dependencies that cannot be reordered:
  • fanout-seeded-transactions.apex deleted FIRST (removes the live hazard)
  • list view BEFORE the fields (Step 1.3 before Step 4)
  • TaskFanoutService BEFORE Tasks_Fanned_Out__c (Step 2 before Step 6)
  • TaskRollupTriggerHandler call sites SAME PAYLOAD as TaskRollupService
  • TestDataFactory methods SAME PAYLOAD as the field deletion
  • DPEG_Apex_Access classAccesses SAME PAYLOAD as TransactionTaskController

═══════════════════════════════════════════════════════════════════════════════
```

### 🔵 PROMPT FOR salesforce-admin

```
Execute the declarative half of M5 legacy Task retirement, per
agent-output/design-legacy-task-retirement.md. Read §2, §3.2, §3.5 and §5 in full
before touching anything.

WAVE 1 ONLY unless told otherwise. Do not start Wave 2.

STEP A — Run the R0 pre-flight probes (§5 R0, P1-P9 plus P1b) and REPORT EVERY
RESULT before changing anything. P1 and P2 are BLOCKING: if any Task row carries
Transaction_Deal__c or Task_Group__c, STOP and report. P5 is a Tooling query and
is the only way to discover whether an Activity-bound validation rule still exists
in the org with no source file.

STEP B — Delete the list view objects/Task/listViews/Transaction_Tasks_by_Group.

STEP C — Delete, in ONE --manifest payload with the developer's Wave 1 Apex:
  • validation rule Task.Prerequisite_Must_Be_Met_To_Complete
  • custom permission Transaction_Task_Actions

🔴 DO NOT DELETE, under any circumstance:
  • objects/Checklist_Item__c/validationRules/Prerequisite_Must_Be_Met_To_Complete
    (same fullName, different object, NEW MODEL, must stay active)
  • customPermissions/Transaction_Prereq_Override
    (ChecklistItemPrerequisiteService.cls:554 calls it in production)
  • Activity.Task_Owner_Label__c, Activity.Task_Sequence__c,
    Activity.Conditional__c (Property Management writes all three;
    OnboardingController.cls:235 renders the first)
  • Transaction__c.Tasks_Total__c / Tasks_Complete__c / Tasks_Overdue__c /
    Wire_Open_Risks__c / Tasks_Open__c / Tasks_Display__c (the NEW model's
    counters; 5 reports, 1 dashboard, 1 Path and 1 compact layout read them)
  • Wire__c.Verbal_Verification_Completed__c and the four same-named
    Checklist_Item__c fields (name collisions — see §2.4)
  • anything under objects/Onboarding__c/ or named Onboarding*

STEP D — Amend these permission sets. 🔴 A PermissionSet deploy REPLACES its whole
fieldPermissions block, so retrieve the ORG copy, diff it against HEAD, and ship
each file as a COMPLETE SUPERSET:
  • DPEG_Task_Edit — remove the Transaction_Task_Actions customPermissions block
    and 8 Task.* fieldPermissions (Blocked_By__c, Is_Prerequisite_Met__c,
    Task_Group__c, Transaction_Deal__c, Verbal_Verification_Completed__c,
    Verified_By__c, Verified_At__c, Verification_Phone__c).
    KEEP Task_Owner_Label__c, Task_Sequence__c, Conditional__c and every
    Onboarding* / Blocked_Reason__c / Source_System__c / Description / WhatId /
    ActivityDate block.
  • DPEG_Apex_Access — remove <apexClass>TransactionTaskController</apexClass>
    (:559). This MUST be in the same payload as the class deletion or the
    permission set will not deploy.
  Note DPEG_TaskChecklist_View and Transaction_Prereq_Override_Access are Wave 2.

STEP E — Amend manifest/package.xml for everything deleted in Wave 1.

VERIFY: after deploying, run the UI-6 and UI-7 checks in §7 (a PM Onboarding
record still renders its Owner column; the Task list-view picker no longer offers
"Transaction Tasks by Group" and the six standard views are intact).

Do NOT accept a green dry-run as proof — a dry-run skips byte-identical components
and this repo has a recorded "689/689 deployed, 0 errors" on a deploy that rolled
back everything. Read codeCoverageWarnings, not the error count.
Do not deploy without the user's confirmation at the DevOps gate.
```

### 🟢 PROMPT FOR salesforce-developer

```
Execute the programmatic half of M5 legacy Task retirement, per
agent-output/design-legacy-task-retirement.md. Read §2.1, §3.1, §3.3, §3.7 and §5
in full before touching anything.

WAVE 1 ONLY unless told otherwise. Do not start Wave 2 — TaskRollupService and the
ChecklistMigration* stack are still the live cutover rollback until ~2026-09-17.

DELETE (Wave 1):
  TaskFanoutService, TaskFanoutServiceTest, TaskFanoutQueueable,
  TaskPrerequisiteService, TaskPrerequisiteServiceTest,
  TransactionTaskService, TransactionTaskServiceTest,
  TransactionTaskController, TransactionTaskControllerTest
  scripts/fanout-seeded-transactions.apex   <- DELETE THIS FIRST. It is the only
    remaining way to put a deal back on the legacy model; its own header says
    "DO NOT RUN THIS AGAINST usman-dpeg", and its line 75 also deletes unrelated
    Activity by WhatId.
  scripts/backfill-task-blocked-by.apex

AMEND (Wave 1):
  • TaskRollupTriggerHandler — remove ONLY the two TaskPrerequisiteService calls
    (:74 clampOnInsert, :82 enforceOnUpdate).
    🔴 LEAVE collectDealIds, recalcDeals and the four recalcDeals call sites —
    they go in Wave 2, in the same payload as TaskRollupService's deletion.
    🔴 LEAVE every OnboardingTaskDomain call and recalcOnboardings untouched.
  • triggers/TaskRollupTrigger.trigger — COMMENT ONLY. Its header at :12-17 and
    :26-37 describes the TaskPrerequisiteService SOQL cost and becomes wrong.
    🔴 THE CONTEXT LIST DOES NOT CHANGE. All six contexts carry an Onboarding
    responsibility (§2.1) — before insert/update are needed by
    OnboardingTaskDomain.stampCompletion.
  • TransactionActionPermissionService — remove hasTaskActionAccess (:348),
    assertTaskActionAccess (:375) and TASK_ACTION_CUSTOM_PERMISSION (:490).
    🔴 KEEP hasPrereqOverrideAccess — ChecklistItemPrerequisiteService.cls:554
    calls it. KEEP hasTransactionActionAccess — RecordStageAdvanceService:2581.
  • TaskRollupTriggerHandlerTest, TransactionActionPermissionServiceTest.
  • LWC: transactionTaskGroups, transactionChecklistSummary, transactionPhaseCards
    — remove the TransactionTaskController imports, the Checklist_Fanned_Out__c
    @wire, the modelFor branch and the anti-fraud subject regex. The components
    and all four FlexiPage instances STAY.
  • LWC: utilsTransactionChecklist — remove normalizeLegacyGroups,
    LEGACY_CRITICAL_RE, LEGACY_WIRE_RE, MODEL_LEGACY, modelFor.
    🔴 KEEP the checklist-model regex constant — the file states at :152-155 that
    the two pairs were declared separately precisely so this deletion is safe.
  • All four Jest suites. ⚠ transactionTaskGroups.test.js:308,317 is a PAIRED
    discriminator assertion; deleting the "false" half leaves the "true" half
    asserting nothing. Replace it with an unconditional assertion.
  • DO NOT touch flexipages/Transaction_Record_Page — a FlexiPage deploy replaces
    the org copy with no version history.

🔴 DO NOT DELETE OR AMEND:
  • TaskGroupDefProvider or TransactionTaskDefProvider — ChecklistFanoutService
    .cls:986 and :993 call them. Retiring them breaks the NEW model's fan-out.
  • scripts/load-task-group-defs.apex, scripts/load-transaction-task-defs.apex —
    .forceignore ignores **/customMetadata/**, so these are the only way the
    definitions reach an org.
  • The (anti-fraud) / (CRITICAL) markers in Transaction_Task_Def__mdt.Subject__c
    — still asserted by ChecklistCaptureDefProviderTest.
  • Any Onboarding* class, OnboardingTaskDomain, or the nine TaskSelector methods
    belonging to PM / Disposition / Broker Protection.
  • TestDataFactory's createChecklistTasks* methods — Wave 2 only, and they must
    ship in the SAME payload as the Activity field deletion or the entire test
    suite fails to COMPILE.

TESTS: name explicitly in the payload and require green —
  OnboardingFanoutServiceTest, OnboardingTaskRollupServiceTest,
  OnboardingControllerTest, OnboardingServiceTest, TaskRollupTriggerHandlerTest,
  TaskSelectorTest, ChecklistItemPrerequisiteServiceTest,
  ChecklistFanoutServiceTest, ChecklistControllerTest,
  TransactionStageGateServiceTest, TransactionControllerTest,
  RecordStageAdvanceServiceTest, WireServiceTest.
Run a check-only RunLocalTests validation on the full payload and read
codeCoverageWarnings — deleting nine classes changes org-wide coverage.

⚠ git status shows TaskRollupService.cls, TaskSelector.cls and TestDataFactory.cls
as modified-but-uncommitted, and this repo has measured a second concurrent session
building into the same working tree. Retrieve and diff before the first payload.
```

---

## 10. Open questions for the user

| # | Question |
|---|---|
| **OQ-M5-1** | **Rename the four `Tasks_*` counters?** Deferred by the brief. §4.2 prices it: 5 reports, 1 dashboard, 1 Path, 1 compact layout, 3 LWCs, ~6 Apex classes, 4 permission sets — and it is delete+create, with the old names reserved until erased. **Recommendation: separate change, own gate.** |
| **OQ-M5-2** | **Wave 2 timing.** Wait for the Recycle Bin to close (~2026-09-17), or waive the cutover rollback now? §5 Step 0. |
| **OQ-M5-3** | **Retire `Tasks_Fanned_Out__c` at all?** Keeping it as an inert historical marker on TXN-0285 is defensible. §4.1. |
| **OQ-M5-4** | **Can `DPEG_TaskChecklist_View` be retired wholesale?** Only if the Junior Analyst persona never opens an `Onboarding__c` — it grants `Task_Owner_Label__c`, which PM reads. §3.2. |
| **OQ-M5-5** | **PM's three orphaned fields.** After M5, `Task_Sequence__c` and `Conditional__c` are **write-only** on the PM side — `OnboardingFanoutService` sets them and nothing reads them. Should Property Management retire them, start reading them, or leave them? **Out of scope by the brief's own boundary — route to PM, do not fold in.** |
| **OQ-M5-6** | **The org-only `Activity` validation rule.** If P5 finds it: remove it (hygiene) or leave it? It is provably inert. §3.2, §5 Step 5. |
