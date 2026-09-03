# Design — Checklist cutover (Part A) + Stage-advancement gate (Part B)

**Date:** 2026-09-02 · **Agent:** salesforce-design · **Status:** requirements + design. **Nothing implemented.**
**Supersedes, in part:** `agent-output/phase4-migration-design.md` M1/M2 (see §0.2).
**Does not supersede:** `agent-output/design-transaction-fsd-gaps.md` §7 M3/M4/M5, which still stand.

---

## 0. Process gates and evidence discipline

```
intent=app | best_matched_skill=none | skill_selection=complete
mcp=unavailable | mcp_tools=none
```

`.claude/rules/salesforce-global-rule.md` mandates a `salesforce-api-context` MCP attempt per metadata
type. A real attempt was made and it **is not configured in this repo**: `.mcp.json` declares only the
`salesforce` server, and this agent's tool set is file-system only (Read / Write / Edit / Glob / Grep)
— no MCP tools, no `sf` CLI, no org access. Recorded `mcp=unavailable` and fell back to the per-type
skills plus in-repo evidence, exactly as every prior `agent-output/` design in this repo has done.

### 0.1 🔴 What I measured versus what I was told — read this before treating any number here as fact

This repo has a documented incident (`design-docs-become-agent-authority`) where an unverified count
in an `agent-output/` file was re-read as fact by later subagents. So:

| Claim | Source | Status |
|---|---|---|
| TXN-0285 `a0Riw000000AsOvEAK`, Stage `Open Contract`, owner Danish Rehman, `Loan_Required__c = true` | The brief | ⚠ **NOT verified by me.** No org access. |
| 82 legacy `Task` rows, spread A6 B5 C7 D5 E6 F12 G6 H5 H2:5 I10 J15 | The brief | ⚠ Not verified by me. **The spread is consistent** with `scripts/load-task-group-defs.apex` + `load-transaction-task-defs.apex`, which I did read. |
| `Tasks_Complete__c = 0`, `Tasks_Total__c = 82`, `Wire_Open_Risks__c = 2`, `Tasks_Fanned_Out__c = true` | The brief | ⚠ Not verified by me. **These four numbers are the whole safety argument for Part A and are re-asserted as a mandatory pre-flight probe in A0.1.** |
| Zero `Checklist__c` / `Checklist_Item__c` rows | The brief | ⚠ Not verified by me. |
| Sharing fix `0Afiw000000Vm8PCAS` deployed | The brief | ⚠ Not verified by me. `ChecklistFanoutService.FanoutWrites` exists in the working tree, so the *source* half is real. |
| Group → stage map, item counts per group | `scripts/load-task-group-defs.apex:24-44` | ✅ **Verified in-repo.** |
| Both fan-out invocables take `List<InputDTO>` with `@InvocableVariable public Id transactionId` | `ChecklistFanoutService.cls:194-219`, `TaskFanoutService.cls:108-133` | ✅ **Verified in-repo.** |
| `Transaction__c` has no validation rules | `objects/Transaction__c/validationRules/` does not exist | ✅ Verified. |
| No flow writes `Transaction__c.Stage__c` | grepped all 13 flows referencing `Stage__c` | ✅ Verified. |

### 0.2 🔴 What this document forgoes, stated plainly and not buried

**The user chose to delete the 82 Tasks and re-fan-out rather than run `ChecklistMigrationService`
(M1). That choice is not re-argued here.** It is safe *only* because `Tasks_Complete__c = 0`, so there
is no completion history, no comment, no wire-verification evidence and no due-date drift to carry
across. Three consequences follow and they are real costs, not paperwork:

1. **The M2 reconciliation is never run in its designed form.** `ChecklistMigrationAuditService`'s
   twelve checks (`phase4-migration-design.md` §3) — in particular check 6, `WIRE_FLAG_MISMATCH`, the
   RISK 1 canary that proves `Checklist_Item__c.Is_Wire_Verification__c` agrees with the legacy
   `Subject.contains('anti-fraud')` parse on the *same rows* — do not gate this cutover.
   ⇒ **§A0.4 substitutes a cheaper, read-only version of that evidence and it is MANDATORY, not
   optional.** It is weaker: it proves the CMDT *definitions* agree with the live Tasks, not that the
   fan-out's output agrees. §A3 closes the rest with two numbers.
2. **`ChecklistMigrationService`, `ChecklistMigrationQueueable`, `ChecklistMigrationDomain`,
   `ChecklistMigrationAuditService`, `TaskRollupService`'s dual-model tiebreak, and the three
   `scripts/*-checklist-migration.apex` remain deployed and NEVER EXERCISED IN PRODUCTION.** Their
   only evidence is unit-test coverage. If a second live deal ever needs migrating rather than
   re-fanning, that code is still untested against real data on the day it is needed.
   ⚠ `ChecklistMigrationService.rollback` is the exception — Part A reuses it (§A6), so *that* method
   does get a production exercise if a rollback is ever needed.
3. **The dual-model window that the tiebreak in `TaskRollupService.recalc` exists to police never
   opens on this deal.** After A1 the deal has zero `Task` rows, so `TaskRollupTrigger` can never fire
   for it, guard or no guard. The tiebreak becomes belt-and-braces immediately rather than after M5.

---

## 1. Corrected premises in the brief

Two of the brief's stated facts are wrong against the working tree. Both are corrected here rather
than restated, with the file that falsifies them.

### 1.1 🔴 There ARE custom quick actions on `Transaction__c` — five of them

The brief says *"there are **no** custom quick actions on `Transaction__c` (no `quickActions`
directory exists, and the org confirms none). So the gate must live on the record, not on an action."*

**The directory exists and holds five files:**

```
quickActions/Transaction__c.Advance_Stage.quickAction-meta.xml        (retired, still present)
quickActions/Transaction__c.Move_to_Due_Diligence.quickAction-meta.xml
quickActions/Transaction__c.Move_to_Closing_Prep.quickAction-meta.xml
quickActions/Transaction__c.Move_to_Post_Closing.quickAction-meta.xml
quickActions/Transaction__c.Move_to_Closed_Won.quickAction-meta.xml
```

All four live ones point at the same `advanceRecordStage` LWC and are on the record page
(`Transaction_Record_Page.flexipage-meta.xml:84-140`, each gated on
`{!$Permission.CustomPermission.Transaction_Stage_Actions}` AND its own source stage).
They call `RecordStageAdvanceService.advance(recordId)` → `setStage` →
`RecordStageAdvanceService.cls:2624`, a bare `update record;`.

**The brief's CONCLUSION is unchanged and is now argued from stronger ground, not weaker.** There are
at least five writers of `Transaction__c.Stage__c` — four named quick actions, the standard Path's
"Mark Stage as Complete" (`runtime_sales_pathassistant:pathAssistant`, flexipage line 186), inline
edit, the API/Data Loader, and the seed scripts. Putting a gate on any subset of *actions* leaves the
rest open. **The gate belongs on the record.**

✅ **And the quick-action route surfaces an `addError` message verbatim.** `setStage` catches
`DmlException` and rethrows `RecordStageAdvanceException(e.getDmlMessage(0))` with a
`getNumDml() > 0` guard — its own comment says surfacing the platform message verbatim "is the POINT
of routing these writes through Apex". So the gate's message reaches the user unmangled on the button
path as well as on the Path/inline-edit path. This is verified, not assumed.

### 1.2 ⚠ `Critical_Date__c.Transaction__c` is no longer `Restrict`

`design-transaction-fsd-gaps.md` RISK 2 ("no cheap rollback; the Transaction cannot be deleted") is
**stale**. `phase4-migration-design.md` §6 records the field relaxed to `required=false` +
`deleteConstraint=SetNull` on 2026-08-31 under GATE-B3. Deleting TXN-0285 is therefore *possible*.
**It is still not the rollback** — see §A6. Noted only so nobody re-derives the old constraint.

---

# PART A — CUT OVER TXN-0285 TO THE NEW MODEL

## A. Ordered sequence

Each step names its reversal. Steps A0.1–A0.5 are read-only and change nothing.

---

### A0 — PRE-FLIGHT. All read-only. **A0.2 is a hard gate: if it fails, STOP.**

#### A0.1 Record the four numbers that are the entire safety argument

```apex
// scripts/preflight-checklist-cutover.apex  (new)
SELECT Id, Name, Stage__c, OwnerId, CreatedById, Loan_Required__c, Contract_Executed_Date__c,
       Tasks_Fanned_Out__c, Checklist_Fanned_Out__c,
       Tasks_Total__c, Tasks_Complete__c, Tasks_Overdue__c, Wire_Open_Risks__c
FROM Transaction__c
```

**Expected, and every one is a STOP condition if it differs:**

| Field | Expected | If it differs |
|---|---|---|
| row count | **1** (TXN-0285) | A second deal exists that this design has not reasoned about. STOP. |
| `Tasks_Complete__c` | **0** | 🔴 **HARD STOP.** The user's choice of delete-and-re-fan is safe *only* at zero. Any non-zero value means completion history would be destroyed, and the correct path becomes M1 after all. |
| `Tasks_Total__c` | 82 | Record it; it is asserted again in A3. |
| `Wire_Open_Risks__c` | **2** | Record it. This is the RISK 1 canary and A3 asserts the same number on the other model. If it is already 0, the legacy parse is already broken and A3's comparison becomes vacuous. |
| `Tasks_Overdue__c` | *record whatever it is* | The new model recomputes it from `Contract_Executed_Date__c + Due_Day_Offset__c`, so it may legitimately differ. See A3. |
| `Checklist_Fanned_Out__c` | **false** | true means something already claimed this deal. STOP. |
| `Tasks_Fanned_Out__c` | true | Expected. It stays true forever; see A7. |

Also record the Task census:

```apex
SELECT Task_Group__c, COUNT(Id) FROM Task
WHERE Transaction_Deal__c = :dealId GROUP BY Task_Group__c
```
Expected: A6 B5 C7 D5 E6 F12 G6 H5 H2:5 I10 J15 = 82.

And the two comparison sets:
```apex
SELECT Id, Task_Group__c, Task_Sequence__c, Subject FROM Task
WHERE Transaction_Deal__c = :dealId
  AND Subject LIKE '%anti-fraud%'          -- expect exactly 2 (B2, I7)
```
```apex
-- the CRITICAL set, matched the way transactionTaskGroups.js:11 matches it (parenthesised),
-- NOT by bare substring: a bare 'critical' wrongly catches A4 and A5.
-- Expect exactly 4: B2, F12, I7, J4.
```

#### A0.2 🔴 HARD GATE — prove the CMDT rows carry the new columns

**This is the single largest silent-failure risk in Part A, and it cannot be answered from the repo.**
`.forceignore:16` ignores `**/customMetadata/**`, so CMDT *records* never deploy; the only path is
`scripts/load-task-group-defs.apex` and `scripts/load-transaction-task-defs.apex`. Both scripts in the
working tree DO write the new columns (`load-task-group-defs.apex:24-44` writes `Stage__c`;
`load-transaction-task-defs.apex:153-157` writes `Is_Critical__c`, `Is_Wire_Verification__c`,
`Blocked_By_Sequence__c`). **Whether they have been RE-RUN against `usman-dpeg` is unverifiable from
here.**

If they have not been re-run, `ChecklistFanoutService` produces 82 items with:
`Stage__c` NULL (every phase tab renders empty), `Is_Critical__c` false (zero CRITICAL flags),
`Is_Wire_Verification__c` false (**`Wire_Open_Risks__c` = 0 — the Wire Sentinel silently reads zero,
which is RISK 1 landing for real**), and `Blocked_By__c` NULL on B3/I8 (**the wire-fraud gate is
disarmed on the new model with nothing erroring anywhere**).

**Probe:**
```apex
SELECT DeveloperName, Letter__c, Stage__c, Sequence__c, Conditional__c, Condition_Field__c
FROM Task_Group_Def__mdt ORDER BY Sequence__c
-- expect 11 rows, EVERY Stage__c non-blank, F conditional on Loan_Required__c

SELECT COUNT(Id) FROM Transaction_Task_Def__mdt                      -- expect 82
SELECT COUNT(Id) FROM Transaction_Task_Def__mdt WHERE Is_Critical__c = true            -- expect 4
SELECT COUNT(Id) FROM Transaction_Task_Def__mdt WHERE Is_Wire_Verification__c = true   -- expect 2
SELECT COUNT(Id) FROM Transaction_Task_Def__mdt WHERE Blocked_By_Sequence__c != null   -- expect 2
```
⚠ Use SOQL, not `getAll()`, for anything you intend to eyeball — and note the repo rule
(`ARCHITECTURE.md` §2): `getAll()`/`getInstance()` **silently truncate LongTextArea to 255**. Every
column above is short text / number / checkbox precisely so `TransactionTaskDefProvider.getAll()`
stays safe; that property is what the fan-out depends on and is worth re-confirming rather than
assumed.

**If any count is wrong: re-run the two loader scripts, then re-probe. Do not proceed on a partial
result.** The loader re-run is an ordered step, not an afterthought.

#### A0.3 Prove the new model is actually deployed

```apex
Schema.getGlobalDescribe().containsKey('Checklist__c')        // true
Schema.getGlobalDescribe().containsKey('Checklist_Item__c')   // true
```
and confirm `ChecklistFanoutService`, `ChecklistRollupService`, `ChecklistItemPrerequisiteService`,
`ChecklistItemTriggerHandler`, `ChecklistController` are all `ApexClass` rows in the org, and that
`Checklist_Item__c`'s `Prerequisite_Must_Be_Met_To_Complete` validation rule is **active**.
⚠ That rule and `ChecklistItemTriggerHandler` are a pair: the rule's own header says deploying it
without the handler "makes every gated item permanently uncompletable". Both, or neither.

#### A0.4 🔴 MANDATORY — run the M2 audit in PROJECTED mode, before anything is deleted

`ChecklistMigrationAuditService` has a **PROJECTED** mode for un-migrated deals: it builds the new
model in memory from the deal's live `Task` rows and reports all twelve checks without any DML
(`phase4-migration-design.md` §3, "an un-migrated deal is compared against a fresh projection"). It is
read-only and it is available right now.

```
sf apex run --file scripts/reconcile-checklist-migration.apex --target-org usman-dpeg
```
(with TXN-0285 in `TARGET_IDS`)

**Expected: `CUTOVER: CLEAR`.**

This is the substitute for the forgone M2 and it recovers most of its value for free. It proves, on
this deal's actual rows: coordinate parity (every Task has a definition and vice versa), that
`Is_Wire_Verification__c` agrees with the `anti-fraud` parse at the coordinate level
(`WIRE_FLAG_MISMATCH`), that the critical set is right *for the groups this deal actually has*
(`CRITICAL_COUNT`, which the audit derives rather than hardcoding to 4), and that the prerequisite
pairs resolve (`PREREQ_UNRESOLVED`).

⚠ **State its limit honestly: it validates the CMDT DEFINITIONS against the live Tasks, using
`ChecklistMigrationDomain`'s projection code. The cutover will actually use
`ChecklistFanoutService.buildItem`, which is DIFFERENT CODE reading the SAME definitions.** So a clean
PROJECTED run does not prove the fan-out's output. §A3 closes that gap by asserting the output
directly.

#### A0.5 Confirm the operator

The operator must be able to **delete `Task` rows**. `ObjectPermissions.SobjectType` excludes
Task/Event/Activity, so Task CRUD **cannot be granted by permission set on this platform** — a set
carrying it deploys green and is silently discarded (`DPEG_Task_Edit`'s own 2026-08-28 comment). So
delete access comes from the *profile* or from Modify All Data.

⇒ **Run every Part A step as a System Administrator.** Assumption flagged: I have not verified who
will run this.

Sharing side: `ChecklistFanoutService.FanoutWrites` is `without sharing` + `SYSTEM_MODE`, so the four
write passes do not depend on the operator's sharing. **But the fan-out's one READ,
`TransactionSelector.selectForChecklistFanout`, is deliberately `with sharing` and was NOT escalated**
(`TaskRollupService.cls:224-228` records why: four other callers depend on its filter). A deal the
operator cannot read returns no row, `checklists` is empty, and `fanOutChunk` **returns silently
having done nothing**. A sysadmin with View All Data is unaffected; anyone else must be able to read
TXN-0285. This is why A3 asserts row counts rather than trusting a clean run.

---

### A1 — Delete the 82 legacy `Task` rows

```apex
// scripts/delete-transaction-checklist-tasks.apex  (new)
// Named-deal only. NO "all deals" mode, matching rollback-transaction-checklist-migration.apex.
List<Task> doomed = [SELECT Id FROM Task WHERE Transaction_Deal__c = :DEAL_ID];
// refuse if doomed.size() != expected count recorded in A0.1
delete doomed;
```

#### 🔴 What the after-delete trigger does, and why it is harmless

`TaskRollupTrigger` declares `after delete` (`TaskRollupTrigger.trigger:44`) →
`TaskRollupTriggerHandler.afterDelete` → `collectDealIds(oldList)` → `recalcDeals` →
`TaskRollupService.recalc({dealId})`.

Traced statement by statement:

1. `TransactionSelector.selectClaimFlagsForTaskRollup` — 1 SOQL. `Checklist_Fanned_Out__c` is **false**
   at this point, so the dual-model tiebreak does **not** skip the deal. Correct: the Task model still
   owns it.
2. `TaskSelector.selectByTransactionDealIds` via `TaskSelector.RollupReads` (`without sharing`) —
   returns **zero rows**, because the rows were just deleted.
3. The counter maps are seeded from `owned` (the deal id set), **not** from the query result, so a
   zero-row read still produces a full `updates` list.
4. `RollupWrites.commitRollups` — `without sharing` + `SYSTEM_MODE`, `allOrNone = true`.

**⇒ The counters become, deterministically:**

| Field | Before A1 | After A1 | Why |
|---|---|---|---|
| `Tasks_Complete__c` | 0 | **0** | recalc writes `complete` = 0. Unchanged in value. |
| `Tasks_Overdue__c` | (recorded in A0.1) | **0** | recalc writes 0. |
| `Wire_Open_Risks__c` | **2** | **0** | recalc writes 0. 🔴 **The Wire Sentinel dashboard tile reads 0 for the duration of the window between A1 and A2.** That is correct — there are momentarily no wire items — but it is visible, so do A1 and A2 in one sitting. |
| `Tasks_Total__c` | **82** | **82 (untouched)** | 🔴 `TaskRollupService.recalc` **does not write `Tasks_Total__c` at all** — read the `updates` construction at `TaskRollupService.cls:277-282`; it writes only Complete/Overdue/WireOpen. `Tasks_Total__c` is written *only* by `TaskFanoutService` and by the checklist fan-out's PASS 4. |
| `Tasks_Fanned_Out__c` | true | **true (untouched)** | Nothing clears it. See A7. |

⚠ **Interim UI state between A1 and A2:** `Checklist_Fanned_Out__c` is still false, so
`utilsTransactionChecklist.modelFor(false)` routes every checklist LWC to the **legacy** model, which
now has zero Tasks. The four `transactionTaskGroups` tabs, `transactionChecklistSummary` and
`transactionPhaseCards` render empty, and the highlights tile reads `0 / 82`. This is expected and
transient.

**Governor cost:** 1 DML statement, 82 rows. One after-delete firing (82 < 200). 2 SOQL, 1 DML inside
it. Nothing near a limit.

**Reversal:** `undelete` from the Recycle Bin. Rows are retained **15 days**. See §A6 for the ordering
constraint — the undelete must be paired with clearing `Checklist_Fanned_Out__c`, or the tiebreak eats
the recompute.

---

### A2 — Fan out the new model on TXN-0285 by DIRECT APEX, **before** repointing the flow

```apex
// scripts/fanout-checklist-for-deal.apex  (new)
// Synchronous. ONE deal. fanOutNow, not fanOut - a Queueable defers the failure and swallows the
// operator's ability to see it immediately.
ChecklistFanoutService.fanOutNow(new List<Id>{ DEAL_ID });
```

#### 🔴 Why direct invocation, and not "toggle a field to re-fire the flow"

The brief asks me to work out the minimal field manipulation that makes
`doesRequireRecordChangedToMeetCriteria = true` re-fire. Here is that arithmetic, and then why it
should not be used.

The repointed flow's criteria would be `Contract_Executed_Date__c != null AND
Checklist_Fanned_Out__c = false`. TXN-0285 **already satisfies both** (its date is set — that is how
the legacy fan-out fired — and the checklist flag is false). With
`doesRequireRecordChangedToMeetCriteria = true`, a record that already meets the criteria does **not**
re-fire on a plain save; it must transition *into* meeting them. The minimal manipulation is therefore
a **two-save toggle**: save 1 sets `Contract_Executed_Date__c = null` (leaving the criteria); save 2
restores it (entering the criteria) and fires the flow. `Tasks_Fanned_Out__c` is irrelevant to the
repointed flow — it is no longer in the criteria — and stays `true` throughout.

**Reject it, for four reasons:**

1. `Contract_Executed_Date__c` is a real business date on a real deal, and blanking it writes to
   **field history** (`Transaction__c` is `enableHistory=true`), leaving a permanent audit trail of a
   date that was never actually unknown.
2. It requires M3 (the flow repoint) to happen **first**, which is the ordering that makes rollback
   expensive — see the trap in §A6.
3. It routes the fan-out through a Queueable, so a failure lands in `AsyncApexJob` rather than in the
   operator's console. This org has two recorded outages
   (`707iw000003HEdIAAW`, `707iw0000046Rh6AAE`) whose entire cost was that an async fan-out failure was
   invisible.
4. `Contract_Executed_Date__c` also feeds `Checklist_Item__c.Due_Date__c`
   (`ChecklistFanoutService.buildItem:954-959`). Blanking it mid-flight risks a fan-out that stamps no
   due dates at all if the timing is wrong.

**Direct invocation has none of those problems and is the same code path** — the flow's only job is to
call `fanOut`, which calls `fanOutNow` via the Queueable. Calling `fanOutNow` for one deal is the
identical work, synchronously, with the failure in front of you.

#### Governor cost, re-derived for one deal

`ChecklistFanoutService`'s header derives 96 rows per Transaction at `CHUNK_SIZE = 50`. For **one**
deal: 11 `Checklist__c` inserts + 82 `Checklist_Item__c` inserts + 2 `Checklist_Item__c` link updates
+ 1 `Transaction__c` update = **96 DML rows, 4 DML statements, 2 SOQL** (the fan-out's own selector
read, plus the one the PASS 3 link update fires into
`ChecklistItemPrerequisiteService.enforceOnUpdate`). Synchronous limits are 10,000 rows / 150
statements / 100 queries. **~1% of every budget.** Nothing to tune.

⚠ **Row-lock note:** a master-detail child insert locks its master. If anybody is editing TXN-0285 in
the UI at that moment, `UNABLE_TO_LOCK_ROW` is possible. Bounded and re-runnable — the fan-out is
idempotent on `Checklist_Fanned_Out__c` and refuses a second run.

**Reversal:** `ChecklistMigrationService.rollback({dealId})` — see §A6.

---

### A3 — 🔴 VERIFY THE OUTPUT. A green run proves nothing.

This step replaces the M2 evidence that A0.4 could not supply. **Every assertion below must be run;
the two marked 🔴 are the RISK 1 canaries and a failure on either means STOP and roll back.**

```apex
// scripts/verify-checklist-cutover.apex  (new)
```

| # | Assertion | Expected | If it fails |
|---|---|---|---|
| 1 | `SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :id` | **11** | The fan-out read nothing (sharing — see A0.5) or a group definition is missing. |
| 2 | `SELECT COUNT() FROM Checklist_Item__c WHERE Checklist__r.Transaction__c = :id` | **82** | Definition count wrong; re-check A0.2. |
| 3 | Per-group item counts | A6 B5 C7 D5 E6 F12 G6 H5 H2:5 I10 J15 | Same. |
| 4 | `SELECT COUNT() FROM Checklist_Item__c WHERE ... AND Stage__c = null` | **0** | 🔴 A0.2 was skipped or the group defs carry no `Stage__c`. Every phase tab will render empty **and Part B's gate cannot attribute those items.** |
| 5 | Items grouped by `Stage__c` | Open Contract **11**, Due Diligence **46**, Closing Prep **10**, Post-Closing **15** | Group→stage map drifted. |
| 6 | Checklists grouped by `Stage__c` | Open Contract 2, Due Diligence 7, Closing Prep 1, Post-Closing 1 | Same. |
| 7 | `Checklist__c.Items_Total__c` per group, and `Items_Complete__c` | matches #3; all `Items_Complete__c` = **0** | `buildChecklist` sets `Items_Total__c` pre-insert; a NULL here is the exact bug its header describes. |
| 8 | `SELECT COUNT() FROM Checklist_Item__c WHERE ... AND Flag__c = 'CRITICAL'` | **4** | 🔴 `Is_Critical__c` not seeded. |
| 9 | `... WHERE Is_Wire_Verification__c = true` | **2**, and they are B2 and I7 | 🔴 |
| 10 | 🔴 `Transaction__c.Wire_Open_Risks__c` | **2 — the SAME number recorded in A0.1** | 🔴🔴 **THE RISK 1 CANARY.** If this reads 0, the boolean field is not seeded and the Wire Sentinel tile is silently lying. The whole point of the model rewrite has failed. **STOP. ROLL BACK.** |
| 11 | 🔴 `Transaction__c.Tasks_Total__c` | **82 — the same number recorded in A0.1** | The two models disagree on the denominator. |
| 12 | `Transaction__c.Tasks_Complete__c` | **0** | PASS 4 writes 0 explicitly. |
| 13 | `Transaction__c.Checklist_Fanned_Out__c` | **true** | PASS 4 failed; the deal will re-fan and duplicate on the next invocation. |
| 14 | `SELECT COUNT() FROM Checklist_Item__c WHERE ... AND Blocked_By__c != null` | **2** (B3→B2, I8→I7) | 🔴 The wire-fraud gate is disarmed on the new model. |
| 15 | `Is_Prerequisite_Met__c = false` on those 2 | true | `resolveLinks` sets it explicitly. |
| 16 | `Transaction__c.Tasks_Overdue__c` | ⚠ **may legitimately differ** from A0.1 | Not an error. The legacy value came from `Task.ActivityDate`; the new one from `Contract_Executed_Date__c + Due_Day_Offset__c`. Record both and, if they differ, confirm the difference is explained by that formula before proceeding. |

⚠ **`Open_Wire_Risks` report / Wire Sentinel dashboard tile:** open it after A3 and confirm it is
**non-zero**. `design-transaction-fsd-gaps.md` §6.4 names this report as the RISK 1 canary and every
one of the eleven `reports/Transactions/*` reads `Transaction__c`'s own counters, so they survive the
model change unchanged — but *unchanged* is exactly what makes a silent zero invisible.

---

### A4 — 🔴 THE SHARING PROBE. Now testable for the first time, because checklists exist.

**The assumption:** that `viewAllRecords` on `Transaction__c` propagates read access to its
`ControlledByParent` detail records. It is the sole basis for "checklist reads need no sharing
escalation" in both `ChecklistRollupService.RollupWrites`'s trip-wire block and
`ChecklistFanoutService.FanoutWrites`'s "✅ NO READ MOVES" paragraph.

**Neither file measured it, and both say so.** `Checklist__c.object-meta.xml:25-30`:
*"the outcome does not depend on whether View All is grantable on a detail object, a question that
could not be measured (no org access this session)"*. `ChecklistRollupService.cls:392-399`:
*"THE `ControlledByParent` PROPAGATION HALF IS REASONED, NOT MEASURED … Probe before relying on it in
a new context."* This step is that probe.

**Why it could not be run until now:** the probe needs a `Checklist__c` row on a deal the probe subject
does not own. Before A2 there were zero such rows org-wide.

#### The probe

Pick a subject who (a) holds `DPEG_Transaction_View` + `DPEG_Checklist_View` — i.e. `viewAllRecords=true`
on `Transaction__c`, `viewAllRecords=false` on `Checklist__c`/`Checklist_Item__c` (verified:
`DPEG_Checklist_View.permissionset-meta.xml:277,286,295`) — and (b) **does not own TXN-0285 and is not
in `DPEG_Transactions_Team`**. On the brief's facts, Junior Dhanani (the creator, not the owner) is the
natural candidate, **provided he is not in the team group**. ⚠ Group membership is **not deployable**
and cannot be read from the repo — confirm it in the org before choosing the subject, or the probe
passes for the wrong reason.

```apex
// scripts/probe-controlledbyparent-viewall.apex  (new)
// Run as the SUBJECT (sf apex run does not impersonate; use System.runAs in a test, OR log in as
// the subject and use the Developer Console). See "how to run it" below.

SELECT RecordId, HasReadAccess, HasEditAccess, MaxAccessLevel
FROM UserRecordAccess
WHERE UserId = :SUBJECT_ID
  AND RecordId IN (:DEAL_ID, :A_CHECKLIST_ID, :A_CHECKLIST_ITEM_ID)
```

**Include a CONTROL so the probe cannot pass vacuously** — the same discipline
`ARCHITECTURE.md` §3.5's Turnstile probe used:

| Probe | Record | Expected if the premise HOLDS |
|---|---|---|
| **A** | `Transaction__c` TXN-0285 | `HasReadAccess = true`, `HasEditAccess = false`, `MaxAccessLevel = 'Read'` — the exact triple `viewAllRecords` produces, already measured for this shape on 2026-09-02 (`TaskRollupService.cls:343-344`) |
| **B** | a `Checklist__c` on TXN-0285 | `HasReadAccess = **true**` |
| **C** | a `Checklist_Item__c` under that checklist | `HasReadAccess = **true**` |
| **D — control** | any `Loan__c` or `Insurance_Binder__c` (Private OWD, `viewAllRecords=true` on both in `DPEG_Checklist_View:304,313`) on a deal, owned by someone else | `HasReadAccess = true` — proves the query itself discriminates and the subject's permission sets are actually assigned |

⚠ **How to run it as the subject.** `sf apex run` executes as the authenticated user, not the subject.
Two options: (i) log in as the subject and run it from the Developer Console (a sysadmin can Login As);
(ii) run the `UserRecordAccess` query **as an admin with `WHERE UserId = :SUBJECT_ID`** — that view is
computed for the named user and is the standard way this org has diagnosed record access before
(`client-gates-are-sharing-blind`, `accountless-contact-is-owner-private`). **Prefer (ii).**
⚠ Assumption flagged: I have not verified that `UserRecordAccess` accepts a `ControlledByParent`
detail record id. If probes B/C return no rows at all (as opposed to `HasReadAccess = false`), that is
an inconclusive result, not a negative one — fall back to (i) and run an actual
`SELECT Id FROM Checklist__c WHERE Transaction__c = :DEAL_ID` as the subject and count the rows.

#### 🔴 What happens if it comes back FALSE

| Consequence | Severity |
|---|---|
| A `DPEG_Transaction_View`-only persona (Principal, Junior Analyst) opens TXN-0285 and the checklist LWCs render **empty on a deal that has 82 items** | 🔴 **User-visible regression versus the Task model.** `Checklist__c.object-meta.xml:25` promises *"VISIBILITY IS NOT REDUCED VS THE TASKS THIS REPLACES"* — that promise would be false. |
| `ChecklistRollupService.RollupWrites`'s "safe on the read side for a structural reason" argument is **void** | 🔴 The class would need a read escalation, exactly as its trip-wire block says. |
| `ChecklistFanoutService.FanoutWrites`'s "✅ NO READ MOVES, AND THAT ASYMMETRY WITH THE TASK MODEL IS THE POINT" is **void** | 🔴 The counters could then be computed from a partial view. |
| Part B's gate is **UNAFFECTED** | ✅ **This is the useful discriminator.** The gate's read is on behalf of a principal who is *updating* the Transaction, so they hold record-level **Edit**, and `ControlledByParent` propagation of *record-level* access is definitional, not the thing in question. Only *object-level View All* propagation is unproven. |

**Remedy if false:** grant `viewAllRecords=true` on `Checklist__c` and `Checklist_Item__c` in
`DPEG_Checklist_View` / `DPEG_Checklist_Edit`.
🔴 **That remedy is itself unproven** — whether `viewAllRecords=true` is even *settable* on a
`ControlledByParent` object at API 67.0 was never measured (it is set to `false` in both files today,
so nothing has tested it). If the probe fails, the remedy needs its own check-only dry-run **plus an
org readback**, per `Checklist__c.object-meta.xml`'s own framing of the question. Do not assume the
deploy succeeding means the flag took — this repo has `trackhistory-ignored-on-same-deploy-field` and
`fielddefinition-is-fls-filtered` as precedents for exactly that.
⚠ **A PermissionSet deploy REPLACES its entire `fieldPermissions` block.** Any edit to
`DPEG_Checklist_View`/`_Edit` must ship the whole file as a superset of the org.

**A4 does not block A5–A7.** If the probe fails, record it, raise it, and continue — the deal is
correct, only the view-only personas' visibility is degraded, and the fix is a permission pass.

---

### A5 — UI verification

**Which component reads which model, verified in the working tree:**

| Component | Discriminates on `Checklist_Fanned_Out__c`? | Evidence |
|---|---|---|
| `lwc/transactionTaskGroups` (×4 instances, `phase` = open/dd/close/post) | ✅ **Yes** | `transactionTaskGroups.js:5,113-128` — `@wire(getRecord)` on `CHECKLIST_FANNED_OUT_FIELD`, then `modelFor(this._fannedOut)`; its Jest suite has explicit "wires ONLY the checklist Apex when true / ONLY the legacy Apex when false" tests (`__tests__:308,317`) |
| `lwc/transactionChecklistSummary` | ✅ Yes | `transactionChecklistSummary.js:3,41-55` |
| `lwc/transactionPhaseCards` | ✅ Yes | `transactionPhaseCards.js:3,44-58` |
| `lwc/transactionCriticalDates` | ❌ **No — and that is correct** | It wires eight `Transaction__c` fields via LDS and renders four hardcoded rows. It never touches `Task`, `Checklist_Item__c` or `Critical_Date__c`, so it is **model-agnostic and needs no change** (GATE-B4). |
| `lwc/utilsTransactionChecklist` | the shared discriminator | `modelFor(fannedOut)` — `true` → new, `false` → legacy, `undefined` → undefined (renders a loading/unknown state rather than guessing) |

**What must be true for the page to render the new model correctly:**

1. `Transaction__c.Checklist_Fanned_Out__c = true` (asserted in A3 #13).
2. The viewing user has **FLS read on `Transaction__c.Checklist_Fanned_Out__c`**. 🔴 If they do not,
   `getRecord` returns no value, `_fannedOut` is `undefined`, `modelFor` returns `undefined`, and
   **every checklist component sits in its indeterminate state on a fully populated deal.** Verify the
   grant exists in `DPEG_Checklist_View`/`_Edit`/`DPEG_Transaction_View`/`_Edit` before declaring the
   page good.
3. The user holds `DPEG_Checklist_View` (or `_Edit`) — object read on `Checklist__c` /
   `Checklist_Item__c` plus FLS on the fields the controller selects.
   `DPEG_Checklist_View` is in `DPEG_Principal_PSG` and `DPEG_Junior_Analyst_PSG` (both added
   2026-09-02); `DPEG_Checklist_Edit` is in `DPEG_Transaction_Team`. Verify **assignment**, not just
   membership of the group — this org has a recorded incident where "~500 field-access errors" was
   entirely un-assigned permission sets.
4. A4's probe passes, or the view-only personas see an empty checklist (§A4).

**Browser checks, in this order:**

- Open TXN-0285. **Highlights tile reads `0 / 82`.** (`Tasks_Display__c` is a formula over
  `Tasks_Complete__c` / `Tasks_Total__c`; both models write the same two fields, so this is
  model-agnostic.)
- All **four phase tabs** populate: Open Contract 11, Due Diligence 46, Closing Prep 10,
  Post-Closing 15. 🔴 An empty tab means A3 #4/#5 was skipped — a NULL `Stage__c` on the items.
  ⚠ The tabs are labelled `Closing` / `Post Closing` in the flexipage while the picklist says
  `Closing Prep` / `Post-Closing` (`design-transaction-fsd-gaps.md` §2.12, GATE-B7). **That label
  mismatch is pre-existing and OUT OF SCOPE here** — do not fix it in this change.
- **Exactly four rows render CRITICAL** (B2, F12, I7, J4).
- **Wire Sentinel tile is non-zero.** Re-check the dashboard, not just the field.
- Tick a non-gated item (e.g. A1) and confirm `Tasks_Complete__c` moves to 1 and the group's
  `Items_Complete__c` moves to 1 — this exercises `ChecklistItemTrigger` →
  `ChecklistRollupService.recalcForChecklistIds` → the dual-model guard writing the deal counters,
  which has **never run in production**.
  ⚠ Then untick it, or the Part B gate's later testing starts from a non-clean state.
- **Negative UI control:** try to complete **B3** while **B2** is open. It must be **refused** with
  `ChecklistItemPrerequisiteService.MSG_BLOCKED` naming B2's subject. This is the first production
  exercise of the new model's wire-fraud gate and it is the one thing that would be worst to discover
  broken later.

---

### A6 — Rollback

**The rollback is `ChecklistMigrationService.rollback`, which already exists and already does exactly
the right three things in exactly the right order** (`scripts/rollback-transaction-checklist-migration.apex`):

```
1. clear Checklist_Fanned_Out__c        FIRST - the TaskRollupService tiebreak skips CLAIMED deals,
                                        so recomputing before this line is a silent no-op
2. delete the deal's Checklist__c rows  (master-detail cascades the 82 items), rollup suppressed,
                                        prior suppression restored in a finally
3. TaskRollupService.recalc(dealIds)    the legacy model recomputes its own counters
```

**But Part A changes step 3's meaning, and the script's header does not know it.** The script was
written for M1, where *"the `Task` rows were never touched"*. **In Part A they were deleted.** So step
3 recomputes from zero Tasks and writes 0/0/0. The rollback must therefore be paired with an
**undelete**, and the order matters:

#### The Part A rollback, in order

| # | Action | Why this order |
|---|---|---|
| **R1** | Run `scripts/rollback-transaction-checklist-migration.apex` with TXN-0285 in `TARGET_IDS` | Clears the flag, deletes 11 checklists + 82 items, recomputes to 0/0/0 (harmless — R2 corrects it) |
| **R2** | `undelete [SELECT Id FROM Task WHERE Transaction_Deal__c = :DEAL_ID ALL ROWS];` | 🔴 **AFTER R1, not before.** `afterUndelete` fires `TaskRollupService.recalc`; with the flag already cleared in R1 the tiebreak does **not** skip, and the counters recompute correctly from the restored 82 rows. Undeleting *first* would hit the guard on a still-claimed deal and the recompute would be silently skipped. |
| **R3** | Verify: `Tasks_Complete__c = 0`, `Tasks_Overdue__c` = the A0.1 value, **`Wire_Open_Risks__c = 2`** | 🔴 The script's own trailer says it: *"a zero there is the RISK 1 failure mode and means step 3 was skipped or the counter guard ate it."* |
| **R4** | Hand-check `Tasks_Total__c` | 🔴 **Nothing in R1–R3 writes it.** It sits at whatever the checklist fan-out's PASS 4 left (82 for this loan deal — the same value, so it happens to be correct **by coincidence, not by mechanism**). Set it explicitly if it is anything else. |
| **R5** | `Tasks_Fanned_Out__c` is still `true` and `Checklist_Fanned_Out__c` is now `false`, so **no** fan-out re-fires and the deal is back on the Task model | ✅ |

#### 🔴 The 15-day window, and the two hard constraints on the rollback

1. **`undelete` only works while the Tasks are in the Recycle Bin — 15 days.** After that, the Task
   rows cannot be reconstructed. ⇒ **Part A is reversible for 15 days and irreversible after.** State
   this to the user. (It is still cheap: `Tasks_Complete__c = 0` means the *only* thing lost is 82
   rows of definitional data that `TaskFanoutService` could in principle regenerate — but
   `Tasks_Fanned_Out__c` is `true`, so regenerating them needs the flag re-armed, which is what
   `scripts/fanout-seeded-transactions.apex` does. That is a *reconstruction*, not a restore: new
   Ids, new CreatedDate, new field history.)
2. 🔴 **AFTER A7 (the flow repoint), the rollback UNDOES ITSELF.** This is not new — the script's own
   header says it in capitals — but it applies verbatim here. R1 writes `Checklist_Fanned_Out__c`
   true → false. The repointed flow filters on that field being `false` and carries
   `doesRequireRecordChangedToMeetCriteria = true`, so **the un-claim IS a record changing into the
   criteria**: the flow fires, `ChecklistFanoutService` finds its only dedupe guard now false, and the
   deal is re-fanned and re-claimed, overwriting R2/R3.
   ⇒ **After A7, deactivate or re-filter `Transaction_Task_Fanout` before running R1, and restore it
   after. That is a deploy, not a script argument.**
   ⇒ **This is the decisive reason A2 comes BEFORE A7 in this sequence.** Doing the fan-out by direct
   invocation first keeps the rollback a one-script operation for the whole verification window.

#### What is NOT the rollback

**Deleting TXN-0285.** It is now *possible* (`Critical_Date__c.Transaction__c` was relaxed to
`SetNull` + optional on 2026-08-31 — §1.2), and it is still wrong: it destroys the `Task` rows this
whole strategy exists to preserve, plus the `Wire__c` links, the field history, and the Opportunity
gate flags (`Has_Open_Transaction__c` / `Has_Closed_Transaction__c`, maintained by
`DealTransactionGateService`, which the `Transaction_Closed_Before_Closed_Won` validation rule reads).

---

### A7 — M3: repoint the fan-out flow. **LAST, and on its own deploy.**

`flows/Transaction_Task_Fanout.flow-meta.xml`, **three lines** (the input parameter name does not
change — verified: both invocables declare `@InvocableVariable public Id transactionId`):

```diff
-        <actionName>TaskFanoutService</actionName>
+        <actionName>ChecklistFanoutService</actionName>
...
-        <nameSegment>TaskFanoutService</nameSegment>
+        <nameSegment>ChecklistFanoutService</nameSegment>
...
         <filters>
-            <field>Tasks_Fanned_Out__c</field>
+            <field>Checklist_Fanned_Out__c</field>
             <operator>EqualTo</operator>
```

#### Which flag the criteria must key on: **`Checklist_Fanned_Out__c`. Not `Tasks_Fanned_Out__c`.**

The two fields are separate **on purpose**, and `Checklist_Fanned_Out__c`'s own `<description>` calls
that "the single most important fact of the migration" (`design-transaction-fsd-gaps.md` §4.8).
Keying the repointed flow on `Tasks_Fanned_Out__c` would mean:

- **TXN-0285 would never re-fan** (its `Tasks_Fanned_Out__c` is `true` and nothing clears it) — fine
  by accident here, but wrong in general;
- worse, **`ChecklistFanoutService`'s own dedupe guard reads `Checklist_Fanned_Out__c`**
  (`fanOutChunk:274`), so the flow's guard and the service's guard would disagree. A deal could enter
  the flow repeatedly and be refused inside, or — after any script that re-arms `Tasks_Fanned_Out__c`
  — be fanned out **twice**, duplicating the entire checklist;
- and it would re-couple the two models, defeating the single-writer property that makes
  `TestDataFactory` and every seed script immune to the new fan-out by construction rather than by a
  bypass flag.

#### ✅ `ChecklistFanoutService` DOES expose a compatible `@InvocableMethod` — verified, not assumed

`ChecklistFanoutService.cls:194-219`:
```apex
@InvocableMethod(label='Fan Out Transaction Checklists'
    description='Queues creation of the Checklist and Checklist Item rows for a Transaction.')
public static void fanOut(List<InputDTO> requests)

public class InputDTO {
    @InvocableVariable(required=true label='Transaction Id' ...)
    public Id transactionId;
}
```
Identical shape and identical parameter name to `TaskFanoutService.fanOut`
(`TaskFanoutService.cls:108-133`). It satisfies `.claude/rules/invocable-rule.md` (List in, void out,
inner DTO with `@InvocableVariable`). **This is not a build item.** For a Flow Apex action, `actionName`
and `nameSegment` are the **class name**, not the method label — hence the diff above.

#### Two properties of the repoint worth knowing before the deploy

- `doesRequireRecordChangedToMeetCriteria = true`, so the repointed flow does **not** retroactively
  fire for any deal already sitting at `Checklist_Fanned_Out__c = false`. In this org that is now the
  empty set anyway (TXN-0285 is claimed after A2), but the property is what makes the repoint safe in
  general.
- A deal created *after* A7 gets the new model only: `Tasks_Fanned_Out__c` stays false, it has **zero
  `Task` rows**, and `TaskRollupService` can never fire for it — guard or no guard.

#### Deploy discipline

- **Deploy the flow ALONE**, after A3 is clean and A5 has been eyeballed. A flow file *is* the flow;
  there is no repointed-but-dormant version.
- ⚠ A **dry-run can skip an unchanged component** and report green without validating anything
  (`dryrun-skips-unchanged-components`). This file *is* changing, so it will be validated — but do not
  generalise the green.
- **Reversal:** redeploy the previous flow file. Data untouched. Keep the pre-change file to hand.

---

### A8 — 🔴 Explicitly deferred, with the one-line reason each

| Deferred | Reason |
|---|---|
| **M4** — remove the `Transaction_Task_Actions` grant from `DPEG_Task_Edit` | Moot here: the deal has zero Tasks, so there is nothing to freeze. It becomes relevant only if a second legacy deal ever exists. ⚠ Note `Transaction_Task_Actions` is **also** granted by `DPEG_Disposition_View` (`phase4-migration-design.md` §2) — a Disposition-side question, out of scope. |
| **M5** — retire `TaskFanoutService`, `TaskFanoutQueueable`, `TaskRollupService` + its dual-model tiebreak, the `TaskSelector` Transaction methods, the nine Transaction-only `Activity` fields, the `Transaction_Tasks_by_Group` list view, Phase 0's `TaskPrerequisiteService` stack | **The user's explicit instruction: separate, later change, once the new model has run a real deal.** A deleted field name stays reserved until ERASED, and erasing is irreversible — so M5 wants a quiet period, not a date. Retirement ORDER is already specified at `phase4-migration-design.md` §8.4 and must be followed or the compile breaks. |
| **Phase-label fix** (`Closing` → `Closing Prep`, `Post Closing` → `Post-Closing` on the flexipage tabs and the Path) — GATE-B7 | Pre-existing cosmetic mismatch, unrelated to this cutover, and the flexipage is a hub file whose deploy **replaces** the org copy with no version history (two tabs were lost this way on 2026-08-25). Do not bundle it. |
| **`scripts/fanout-seeded-transactions.apex` becomes inert after A7** | It re-arms `Tasks_Fanned_Out__c`, which the repointed flow no longer reads. It will silently do nothing. A one-line header correction, deferred to M5 with the rest of the Task stack. **Flagged so nobody debugs it as a fault.** |
| **`Is_Earnest_At_Risk__c`, `CriticalDateService` trigger wiring, Loan/Insurance wiring** | Phase 5 / open gates B2, B3, B4. Untouched. |

---

# PART B — STAGE-ADVANCEMENT GATE

All four of the user's decisions are taken as given and are not re-litigated:
**all items in the current stage** (not just critical) · **hard block** with a message naming what is
outstanding · **every forward stage move** · **new model only (`Checklist_Item__c`)**, built after
Part A so it is not built twice.

## B1. The mechanism decision

### The two candidates, evaluated

#### Candidate 1 — per-stage open-item roll-up summaries on `Transaction__c`

**It is technically feasible, and the brief's stated obstacle is not the real one.** The brief asks
whether "roll-up summary fields cannot filter on a *grandchild*" kills it. It does not, because the
grandchild count is **already denormalised onto the child**: `Checklist__c.Items_Total__c` and
`Items_Complete__c` are **writable Numbers maintained by `ChecklistRollupService`**, not roll-up
summaries (`Checklist__c.object-meta.xml:32-35`, `ChecklistRollupService.cls:10-24` — settled at
GATE-S1, three independent reasons, "DO NOT REOPEN"). So a roll-up on `Transaction__c` would summarise
a **direct** master-detail child and filter on **that child's own** `Stage__c`. One hop. It works.

The shape would be: a formula `Checklist__c.Items_Open__c = Items_Total__c - Items_Complete__c` (both
plain Numbers, so it is summarisable), plus **four** roll-up summary fields on `Transaction__c`
(`Open_Items_Open_Contract__c`, `…_Due_Diligence__c`, `…_Closing_Prep__c`, `…_Post_Closing__c`), each
`SUM(Checklist__c.Items_Open__c) WHERE Stage__c = <that value>`. A validation rule could then read
them: `CASE(TEXT(Stage__c), "Open Contract", Open_Items_Open_Contract__c, …) > 0` combined with
`Checklist_Fanned_Out__c` and an `ISCHANGED(Stage__c)` forward test.

**Rejected. Five reasons, any one sufficient:**

1. 🔴 **It cannot satisfy the user's stated requirement.** The decision is *"hard block with a clear
   message naming what is outstanding."* **A validation rule's `errorMessage` is a static string, not
   a formula.** It can say "complete all items in this stage first"; it can never say *which* items.
   The requirement is not negotiable and the mechanism cannot meet it.
2. 🔴 **Roll-ups on `Checklist__c.Stage__c` fail OPEN on a NULL stage.** `Checklist__c.Stage__c` has
   **no default value, deliberately** — `ChecklistFanoutService` counts unstaged rows into
   `lastRunUnstagedItemCount` precisely because *"a plausible default would hide a fan-out that failed
   to stamp the phase."* A NULL-stage checklist falls into **no** roll-up bucket, so the gate silently
   permits the move. A safety control whose failure mode is "silently stops refusing" is the wrong
   shape.
3. 🔴 **It adds five fields to a live master-detail hierarchy and one of them is a roll-up summary,
   which is a class of change this repo has already been burned by.** `editable=true` FLS on a roll-up
   summary **fails the deploy** (recorded for eight PM fields), so the permission pass must grant
   `editable=false` on all five, across `DPEG_Checklist_View`/`_Edit`,
   `DPEG_Transaction_View`/`_Edit`, `DPEG_Admin_Access` — and a **PermissionSet deploy replaces its
   entire `fieldPermissions` block**, so each file must ship as a superset of the org.
4. **Roll-up recalculation ordering is an unproven premise for a before-trigger read.** The rule would
   read the roll-up's *stored* value in the same transaction as an item save that changed it. That is
   probably fine, but "probably" is not the bar this repo sets for a gate, and there is no way to
   prove it from source.
5. **Two mechanisms where one will do.** `ChecklistRollupService` already computes exactly these
   numbers, in Apex, for exactly this hierarchy. Adding a declarative parallel path means two things
   that can disagree.

#### Candidate 2 — ✅ **CHOSEN: an Apex `before update` gate on `Transaction__c` using `addError`**

**Why it is right:**

- It is the **only** mechanism that can name the outstanding items.
- It derives "the items that exist on THIS deal" from the rows themselves — **no denominator anywhere,
  hardcoded or otherwise.**
- It can distinguish forward from backward from no-move, which a VR can only do clumsily.
- It can fail open deliberately and *visibly* (an in-context counter) rather than accidentally.
- It is **exactly consistent with how this object family already refuses things**:
  `ChecklistItemPrerequisiteService.enforceOnUpdate` refuses completions with `addError` from a
  before-update trigger, guarded by `Trigger.isExecuting` so unit tests can assert the decision
  without depending on `addError`. **Mirror that shape, including the returned refusal map.**
- 🔴 **Its message reaches the user verbatim on every write path** — including the quick-action route,
  because `RecordStageAdvanceService.setStage` catches `DmlException` and rethrows
  `getDmlMessage(0)` (§1.1). Verified, not assumed.

**What it costs:** one SOQL per before-update chunk, **and only when at least one record in that chunk
is a forward stage move on a claimed deal.** Zero otherwise. Zero DML, always. See §B4.

---

## B2. Design

### B2.1 Where the gate lives

`TransactionTriggerHandler.beforeUpdate` gains a **second** arm:

```apex
protected override void beforeUpdate() {
    TransactionStageEntryService.stampStageEntryDates(
        (List<Transaction__c>) newList, (Map<Id, Transaction__c>) oldMap);
    TransactionStageGateService.enforceOnUpdate(
        (List<Transaction__c>) newList, (Map<Id, Transaction__c>) oldMap);
}
```

**`beforeInsert` is deliberately NOT gated.** Two seed scripts insert a Transaction with
`Stage__c = 'Closed'` directly (`Transaction_Stage_Closed_Sets_Status`'s own comment says so), and a
newly inserted deal has no checklist yet by definition. Gating insert would brick every seed script
and every scratch rebuild for zero benefit.

Order within the context is immaterial to correctness — on a refusal the whole save is discarded, so
the stamp's in-memory assignment never persists — but state it in the code comment so nobody
"fixes" it.

### 🔴 B2.2 The handler header must be amended in the SAME change

`TransactionTriggerHandler`'s header currently promises:

> `beforeInsert/beforeUpdate -> TransactionStageEntryService`: pure in-memory, **ZERO SOQL and ZERO
> DML at any record count, by construction**.

That promise is about the *context*, and adding a second arm changes it. **The substance survives** —
the gate spends zero SOQL on every save that is not a forward stage move, which includes every rollup
write from `ChecklistRollupService`, `TaskRollupService` and the fan-out's PASS 4 — **but the wording
becomes false and must be rewritten**, with the new arm's own bounded cost stated. This repo punishes
stale headers hard (`ARCHITECTURE.md` §2 makes class headers the authoritative record; five separate
classes in this feature carry "THIS SAID … AND IT WAS WRONG" corrections). Amend it; do not leave it.

### B2.3 The stage order — and the trap of creating a second source of truth

The gate needs an ordinal to tell forward from backward. The order already exists **twice**:
`RecordStageAdvanceService.TRANSACTION_NEXT_STAGE` (private, `RecordStageAdvanceService.cls:1526`) and
the `Transaction__c.Stage__c` picklist value set (`restricted=true`, `sorted=false`, so authored order
is the real order).

That map's own header is emphatic: *"🔴 THE ORDER IS A USER DECISION, NOT A DERIVATION, AND IT IS THE
ONE THING HERE THAT CANNOT BE WRONG QUIETLY … Whichever order is configured becomes the ONLY order the
button offers, with nothing to signal a mistake."*

**Decision: a hardcoded ordered `List<String>` in a new `TransactionStageDomain` (layer=domain, zero
SOQL/DML), pinned by a test that asserts it agrees with BOTH other sources.**

- Not derived from `RecordStageAdvanceService` at runtime: that class is 2,600 lines and dispatches
  eight objects; making a live safety gate depend on its internals at runtime widens its blast radius.
- Not derived from the picklist describe at runtime: describe order is re-orderable in Setup by anyone,
  which would **silently invert the gate** — and `getPicklistValues()` also returns inactive values.
- **The cross-check test is the mechanism that stops the third copy drifting.** It requires making
  `RecordStageAdvanceService.TRANSACTION_NEXT_STAGE` `@TestVisible` — a one-word edit to a shared
  class, flagged here as a real (if tiny) blast-radius item.

The list, byte-identical to `Transaction__c.Stage__c` including the hyphen:
`Open Contract` (0) · `Due Diligence` (1) · `Closing Prep` (2) · `Post-Closing` (3) · `Closed` (4).

`isForward(prior, next)` returns true **only** when both resolve to an index and `index(next) >
index(prior)`. An unrecognised prior or next (including null, including a value someone adds to the
picklist without updating the domain) resolves to no index ⇒ **not forward ⇒ not gated ⇒ fail open**,
counted in `lastRunUnknownStageCount` so it is assertable rather than silent.

### B2.4 The algorithm

**Pass 1 — in memory, zero SOQL. Collect candidates.**
For each record in `Trigger.new`:
- `prior = oldMap.get(id)`; if null → skip (not an update).
- if `prior.Stage__c == deal.Stage__c` → **skip.** This is the line that makes every counter write,
  every flag write, every owner change and every rollup free.
- if `!TransactionStageDomain.isForward(prior.Stage__c, deal.Stage__c)` → **skip.** Backward and
  lateral moves are not gated (user decision 3, "every *forward* stage move").
- if `deal.Checklist_Fanned_Out__c != true` → **skip.** ✅ **The deliberate fail-open** (see B3.4).
- otherwise: candidate. Record `dealId → priorStage` (**the stage being LEFT** — that is the stage
  whose items must be complete).

**If there are no candidates: return. Zero SOQL, zero DML.**

**Pass 2 — one selector read.**
`ChecklistItemSelector.selectOpenForStageGate(Set<Id> dealIds, Set<String> stages)`:

```apex
SELECT Id, Checklist__c, Checklist__r.Transaction__c, Checklist__r.Group_Letter__c,
       Checklist__r.Stage__c, Sequence__c, Subject__c, Flag__c, Stage__c
FROM Checklist_Item__c
WHERE Checklist__r.Transaction__c IN :dealIds
  AND (Stage__c IN :stages OR Stage__c = NULL)
WITH SYSTEM_MODE
ORDER BY Checklist__r.Sequence__c ASC NULLS FIRST, Sequence__c ASC NULLS FIRST
```

- `stages` is the **union** of the candidate deals' prior stages — at most four values.
- 🔴 **`OR Stage__c = NULL` is deliberate and load-bearing.** Without it, an item the fan-out failed to
  stamp is invisible to the gate and the gate fails open silently. With it, the item is *seen* and can
  be attributed via its parent (B3.2).
- 🔴 **The done-test is NOT in the WHERE clause.** `ChecklistItemDomain.isDone` is the single
  definition of done for the whole model — *"DO NOT WRITE `Flag__c == 'Completed'` ANYWHERE ELSE"* —
  and a SOQL literal list here would be a second definition that no test would catch drifting.
  Filtering happens in memory via `isDone`.

**Mode justification (required at the declaration by `ARCHITECTURE.md` §2):**
`WITH SYSTEM_MODE`. This is a read performed **on a principal's behalf** inside a trigger, not one they
asked for. Under `USER_MODE`, one missing FLS grant on any of the eight fields raises
`System.QueryException: No such column`, which inside a before-update trigger escapes as
`CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` — **an FLS gap wearing a schema error, refusing the user's own
stage save with a message nobody can act on.** Every DPEG persona is on Minimum Access and every field
here is Metadata-API-deployed. Precedent in the same selector: `selectByTransactionIds`.

**Sharing, asked separately because `SYSTEM_MODE` never lifts it:** the principal is *updating* the
`Transaction__c`, so they hold record-level Edit on it; `Checklist_Item__c` is `ControlledByParent`
two hops up, so they read every item on that deal. ✅ **This argument does NOT depend on A4's unproven
`viewAllRecords` propagation** — it depends on *record-level* access propagating, which is the
definition of `ControlledByParent`. Say so explicitly in the header, because the two are easy to
conflate and A4 may well come back false.

**Pass 3 — in memory. Attribute, tally, refuse.**
For each returned item: `effectiveStage = item.Stage__c ?? item.Checklist__r.Stage__c`. If it is still
blank → increment `lastRunUnattributedItemCount`, **do not gate on it** (B3.2). Otherwise, if
`effectiveStage == priorStageFor(item's deal)` and `!ChecklistItemDomain.isDone(item.Flag__c)` → it is
outstanding.

For each candidate deal with at least one outstanding item, compose the message and `addError` it (in
`Trigger.isExecuting` only), returning `Map<Id, String>` so unit tests can assert the decision
directly.

### B2.5 The message

🔴 **Pure printable ASCII. No em-dash, no smart quote, no `&`, `<`, `>`, `"`.** `SObject.addError`
**HTML-escapes its message**, so an em-dash renders as `&mdash;` in the toast *and* breaks any
`contains` match written against the constant — `ChecklistItemPrerequisiteService.cls:134-138` records
that this cost a test in Phase 0. Follow that file's convention exactly, including **not quoting an
interpolated subject** (quotes render as `&quot;`).

Shape:

```
This deal cannot move to Due Diligence yet. 3 of 11 Open Contract checklist items are
still open: A4 Receive critical dates from title company; B2 Call title company to verbally
verify wiring instructions (anti-fraud); B3 Send wire request to accounting with verified
instructions. Complete them on the Open Contract tab first.
```

- The **coordinate** (`A4`, `H2:5`) comes from `Checklist__r.Group_Letter__c` + `Sequence__c` — the
  same coordinate the M2 audit and the fan-out's prerequisite index use. **Never subject text as a
  key**; the subject appears for display only.
- The `N of M` numbers are **counted from the rows returned**, not from any constant.
  🔴 `activeTransactionsList`'s header records the incident where a hardcoded denominator "reported on
  work that did not exist"; `TaskRollupService`'s header says *"Do not turn 82 into a constant
  anywhere."* Neither 11, nor 46, nor 10, nor 15, nor 82 may appear in this feature's source.
- **Cap the enumerated list at 5 coordinates + `and N more.`** At 46 Due Diligence items the message
  would otherwise be unreadable and could approach the error-message length limit.

---

## B3. The six edge cases, resolved

### B3.1 The trigger point ✅ (brief premise corrected — see §1.1)
Four named per-hop quick actions **do** exist, plus the standard Path, inline edit, the API, Data
Loader and the seed scripts. **All of them write `Stage__c` and all of them go through
`before update`.** The gate on the record covers every one. No action, page or component is modified.

### B3.2 Conditional groups — no hardcoded denominator anywhere
Group F (12 items) exists only when `Loan_Required__c = true`
(`Task_Group_Def__mdt.Condition_Field__c`, honoured at `ChecklistFanoutService.isGroupApplicable`).
So Due Diligence is **46 items on a loan deal and 34 on a no-loan deal**, and both are correct.

The gate counts **the rows it read for this deal**. It never consults
`Transaction_Task_Def__mdt`, never counts group definitions, and contains no stage-size constant.
`ChecklistMigrationAuditService`'s `CRITICAL_COUNT` check already had to solve this exact problem and
its note is the precedent: *"§7 says 'assert the CRITICAL count is 4 per deal'. That is wrong for a
no-loan deal … Hardcoding 4 would red-line every no-loan deal."*

**NULL-stage items** are attributed via the parent `Checklist__r.Stage__c`. If both are blank the item
is **un-attributable**: it is *not* counted against any stage (gating on it would brick the deal, since
the item belongs to no tab a user can find), and `lastRunUnattributedItemCount` is incremented so a
test can assert it is zero and an operator can query it after a fan-out.
🔴 **This is a known, deliberate fail-open, made assertable rather than silent** — the same device
`ChecklistFanoutService.lastRunUnstagedItemCount` uses, and A3 #4 is the check that keeps it at zero.

### B3.3 Backward moves are not gated
Handled by `TransactionStageDomain.isForward` (§B2.3). Backward, lateral (same value), and
unrecognised-value moves all skip. An unrecognised value increments `lastRunUnknownStageCount`.

### B3.4 A deal with no checklist is not blocked — deliberate fail-open
`Checklist_Fanned_Out__c != true` → skip, before any query. This covers: every seed-script deal, every
scratch-org rebuild, any pre-cutover deal that still exists, and — for as long as `TaskFanoutService`
is still deployed — any deal still on the Task model.
🔴 **The gate is deliberately NEW-MODEL-ONLY (user decision 4).** A deal on the Task model can be
advanced with 82 open Tasks and that is accepted. Do not "improve" it by adding a Task-side branch —
that arm would be deleted at M5 (Phase 0's entire fate) and it would make the gate depend on
`TaskSelector`, a class whose own header calls itself *"a contract, not a private helper"* shared with
PM, Disposition and Broker Protection.
⚠ **This fail-open must have its own negative control** (test N7b), or "no checklist ⇒ allowed" is
indistinguishable from "the gate never fires at all."

### B3.5 Interaction with existing automation — **no automation-driven stage write is blocked**

I grepped every flow referencing `Stage__c` (13 files) and read the two that touch `Transaction__c`.

| Automation | Writes `Transaction__c.Stage__c`? | Effect of the gate |
|---|---|---|
| `flows/Transaction_Stage_Closed_Sets_Status` | ❌ **No.** It is a **before-save** flow that *reads* `Stage__c = 'Closed'` and *writes* `Status__c`. | ✅ **None, and the ordering is safe.** Before-save flows run **before** Apex before-triggers, so the flow assigns `Status__c` in memory, then the gate refuses, then the **whole save rolls back including the flow's assignment**. No partial state. `Status__c` can never drift. |
| `flows/Transaction_Complete_Close` | ❌ **No.** After-save on `Transaction__c`, keyed on `Status__c = 'Closed'`; it writes to the **Opportunity**. | ✅ **None.** If the gate refuses, the save fails in the before context and this after-save flow **never runs**. So the Opportunity is not half-closed. |
| `RecordStageAdvanceService.setStage` (the four quick actions) | ✅ Yes — `update record;` at line 2624 | ✅ **Intended.** This is a *user* clicking a button, not automation. The refusal surfaces verbatim through `RecordStageAdvanceException(e.getDmlMessage(0))`. |
| `TaskRollupService` / `ChecklistRollupService` / `ChecklistFanoutService` PASS 4 / `DealTransactionGateService` | ❌ No — counters, flags and Opportunity fields only | ✅ **Zero cost.** Stage unchanged ⇒ Pass 1 skips ⇒ no query. This is what preserves the handler's zero-cost promise. |
| `ChecklistFanoutService.reconcile` (via `TransactionTriggerHandler.afterUpdate`) | ❌ No | ✅ Gated on `Loan_Required__c` changing, not stage. Unaffected. |
| Seed scripts inserting `Stage__c = 'Closed'` | insert, not update | ✅ `beforeInsert` is not gated. |
| `ContractExecutionService` (creates the Transaction) | insert | ✅ Same. |

🔴 **⇒ There is NO automation that moves a `Transaction__c` to `Closed`.** The Post-Closing → Closed
hop is the `Move_to_Closed_Won` quick action, i.e. a person. **So the gate cannot cause an
automation outage.** That is the direct answer to the brief's concern.

⚠ **But there IS a business consequence, and it is the largest one in this design, so it is stated
rather than buried:** *the deal cannot be moved to `Closed` until all 15 Post-Closing (group J) items
are complete* — including `J4 Set up auto loan payment at lender bank (CRITICAL)`. That follows
directly and correctly from user decision 3 ("every forward stage move") and is **not re-litigated**.
It is flagged in §B7 as something the business should be told before go-live, because the
consequential surprise arrives weeks after the deploy, on the day someone tries to close a deal.

### B3.6 `addError` HTML-escaping — see §B2.5. Pure ASCII, no quotes.

### B3.7 Restricted picklists
`Checklist_Item__c.Stage__c` and `Checklist__c.Stage__c` are `restricted=true` with exactly the four
non-terminal values, byte-identical to the first four of `Transaction__c.Stage__c` including the hyphen
in `Post-Closing` (verified in all three field files). `Transaction__c.Stage__c` is also
`restricted=true`, `sorted=false`.

**The gate writes no picklist**, so `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` is not reachable from
it. The restriction matters in exactly two places:
1. **`TransactionStageDomain`'s ordered list must match the value set byte-for-byte.** Pinned by the
   cross-check test (§B2.3), which asserts against the active describe values as well as
   `RecordStageAdvanceService`'s map.
2. **`Closed` is deliberately absent from the item/checklist value sets** — no task group belongs to
   the terminal stage. The gate must never look for `Stage__c = 'Closed'` items; the Post-Closing →
   Closed hop is gated on the **Post-Closing** items (the stage being left), which is what the
   algorithm does by construction.

---

## B4. Governor budget — derived, not copied

**Per `before update` chunk (max 200 records):**

| | Cost |
|---|---|
| SOQL, no forward stage move in the chunk | **0** — Pass 1 exits before any query. Covers every rollup write, every fan-out PASS 4, every counter save, every owner change. |
| SOQL, at least one candidate | **1** — `selectOpenForStageGate`, once for the whole chunk regardless of how many deals are candidates |
| DML | **0**, always |
| Describes | **0** at runtime (the ordered list is a constant; describe is used only in the test) |
| CMDT reads | **0** |

**Rows returned, worst case:** 200 deals all leaving Due Diligence on a loan deal = 200 × 46 =
**9,200 sObjects**, eight fields each.
⚠ **Estimated from row counts, not measured.** ~9,200 × 8 fields is on the order of 1.5–2 MB against
a 6 MB synchronous heap — inside it, but not comfortably, and it sits on top of whatever else the
save is doing. **Mitigations, in order of preference:**
- The realistic shape is **1 deal**: the quick actions and the Path both move one record. A 200-row
  chunk of *forward stage moves* only arises from Data Loader.
- The message is capped at 5 coordinates, so the composed strings do not grow with the row count.
- If a bulk stage advance of many deals is ever needed, **page it**. Say so in the class header.

**SOQL row limit:** 9,200 of 50,000. Not binding.

**In-context instrumentation is mandatory** — `lastRunQueryCount`, `lastRunDmlCount`,
`lastRunChunkCount`, `lastRunRefusalCount`, `lastRunUnattributedItemCount`, `lastRunUnknownStageCount`,
captured **inside the method body** and asserted directly.
🔴 `Test.stopTest()` restores the pre-test governor counters, so `Limits.getQueries()` read afterwards
**measures nothing and passes vacuously**. Every class in this feature already carries that warning
(`ChecklistFanoutService.cls:158-161`, `TransactionStageEntryService.cls:66-72`,
`TaskRollupService.cls:151-155`). Copy the device.

**Cascade check.** Does the gate add cost to the Day-0 chain? The chain is:
Opportunity 'About to Close' → `ContractExecutionService` **inserts** the Transaction (before**Insert**,
not gated) → fan-out flow → Queueable → 96 rows → PASS 4 **updates** the Transaction with counters
and the claim flag. **PASS 4 does not move `Stage__c`**, so the gate's Pass 1 skips it and spends
nothing. ✅ The Day-0 cascade cost is **unchanged**.

---

## B5. Component inventory

### New

| Component | Layer | Notes |
|---|---|---|
| `classes/TransactionStageDomain.cls` | **domain** | Ordered stage list, `isForward`, `indexOf`, coordinate formatting. **ZERO SOQL, ZERO DML** (`.claude/rules/apex-layering-rule.md` Domain Purity Rule). |
| `classes/TransactionStageDomainTest.cls` | test | The cross-check test (§B2.3) lives here. |
| `classes/TransactionStageGateService.cls` | **service** | `enforceOnUpdate(List<Transaction__c>, Map<Id, Transaction__c>) → Map<Id, String>`. `public with sharing`. Mirrors `ChecklistItemPrerequisiteService`'s shape: mutates via `addError` under `Trigger.isExecuting`, returns the decision map for tests, **trigger-only by contract** (say so in the header — a non-trigger caller would silently refuse nothing). |
| `classes/TransactionStageGateServiceTest.cls` | test | §B6. |

### Amended

| Component | Change | Risk |
|---|---|---|
| `classes/ChecklistItemSelector.cls` | **Additive**: `selectOpenForStageGate(Set<Id>, Set<String>)` + its entry in the class's SYSTEM_MODE mode inventory. **No existing method touched.** | ⚠ Shared file. `ARCHITECTURE.md` §2 makes the header the authoritative record of which reads escape and why — the new method needs its own justification paragraph, not a shrug at the existing ones (this exact correction was made to this file on 2026-09-02 for its third caller). |
| `classes/TransactionTriggerHandler.cls` | Second `beforeUpdate` arm **+ the header amendment (§B2.2, mandatory)** | Low code risk, real doc risk. |
| `classes/RecordStageAdvanceService.cls` | `@TestVisible` on `TRANSACTION_NEXT_STAGE` (one word) | ⚠ Shared, 2,600 lines, eight objects. One-word, test-only. Nothing else in that file changes. |

### Explicitly NOT touched

`ChecklistRollupService` · `ChecklistFanoutService` · `ChecklistItemPrerequisiteService` ·
`ChecklistItemService` · `ChecklistItemDomain` · `ChecklistItemTriggerHandler` · `ChecklistController` ·
`TaskRollupService` · `TaskSelector` · `TransactionSelector` · `TestDataFactory`'s existing methods ·
every LWC · every FlexiPage · every quick action · the Path · every report and dashboard ·
`Transaction_Complete_Close` · `Transaction_Stage_Closed_Sets_Status` · `Transaction_Task_Fanout`
(beyond Part A's three lines) · all permission sets · all permission set groups.

🔴 **No permission-set change is required by Part B.** The gate reads `WITH SYSTEM_MODE` and writes
nothing. **Do not open a permission file for this feature** — a PermissionSet deploy replaces its whole
`fieldPermissions` block and this repo has a live incident from exactly that.

---

## B6. Test plan

`.claude/rules/bulk-test-rule.md` applies: this is a trigger, so **251 records**.

### 🔴 The 251 mandate, and its one carve-out — recorded in the test class header so review does not demand more

- ✅ **T-BULK-1 satisfies 251 LITERALLY.** 251 `Transaction__c` rows, `Checklist_Fanned_Out__c = false`,
  all moved forward in one `update`. That is 251 rows of ordinary Transaction fixtures — cheap, and it
  forces **two** trigger chunks (200 + 51), which is the entire point of 251 over 200. It proves the
  fail-open path is bulk-safe and costs **zero SOQL**.
- ⚠ **Carve-out for the checklist-bearing volume test.** 251 deals × 82 items = **20,582
  `Checklist_Item__c` rows in one insert**, against a 10,000 DML-row limit. The fixture is
  **impossible to build**, so a 251-deal *claimed* test cannot exist. The volume test therefore runs at
  **the chunk boundary with a trimmed fixture** — the same device
  `ChecklistFanoutServiceTest.staysWithinBudgetAtTheChunkBoundary` uses, and the same reasoning
  `.claude/rules/bulk-test-rule.md`'s own "a volume production cannot reach" exemption endorses.
  **Write that arithmetic into the header.**

| # | Test | Asserts |
|---|---|---|
| **T-BULK-1** | 251 unclaimed deals, all forward-moved in one update | All 251 save. `lastRunChunkCount >= 2`. `lastRunQueryCount == 0`. `lastRunRefusalCount == 0`. |
| **T-BULK-2** | 25 claimed deals × 11 trimmed items, mixed states, one update | **`lastRunQueryCount == 1`** for the whole chunk — the anti-SOQL-in-loop proof. Refusals land on exactly the right deals. |
| **T-BULK-3** | Same 25 deals, a **counter-only** update (no stage change) | `lastRunQueryCount == 0`. This is the pin on the handler's zero-cost promise. |

### 🔴 Negative controls — a gate that never refuses is worthless. Each of these MUST FAIL the save.

| # | Scenario | Must produce |
|---|---|---|
| **N1** | Claimed deal, 1 open Open Contract item, `Stage__c` → Due Diligence | 🔴 **REFUSED.** Message contains the item's coordinate AND its subject AND `1 of 11`. |
| **N2** | Same, driven through `RecordStageAdvanceService.advance(dealId)` (the quick-action path) | 🔴 **REFUSED**, and the thrown `RecordStageAdvanceException`'s message **equals the gate's message verbatim** — proving §1.1's `getDmlMessage(0)` path is not mangling it. |
| **N3** | Same, driven through `Database.update(deal, false)` (the Data Loader shape) | 🔴 **REFUSED** — `result.isSuccess() == false`, `getErrors()` non-empty. Proves the gate is not UI-only. **`allOrNone = false` must NOT swallow it** — this org has a live incident of exactly that. |
| **N4** | Post-Closing → Closed with 1 open group-J item | 🔴 **REFUSED.** The single highest-consequence gate; it must be proven to fire, not assumed. |
| **N5a** | All 11 Open Contract items done, **one of them at `Verified` rather than `Completed`** | ✅ **ALLOWED.** 🔴 **This is the `isDone` control.** If anyone writes `Flag__c == 'Completed'`, this test reds. |
| **N5b** | The mirror: one item at `CRITICAL`, the rest done | 🔴 **REFUSED.** Proves `CRITICAL` and `None` both count as open. |
| **N6a** | **No-loan** deal (`Loan_Required__c = false`, no group F), all **34** Due Diligence items done, → Closing Prep | ✅ **ALLOWED.** 🔴 **The anti-hardcode control.** A gate expecting 46 reds here. |
| **N6b** | **Loan** deal, the same 34 done but all 12 group-F items open, → Closing Prep | 🔴 **REFUSED**, message says `12 of 46`. 🔴 **The other half of the anti-hardcode control** — N6a alone would also pass a gate that always allows. **The pair is the test; neither alone is.** |
| **N7a** | Unclaimed deal (`Checklist_Fanned_Out__c = false`), zero checklist rows, forward move | ✅ **ALLOWED**, `lastRunQueryCount == 0` |
| **N7b** | 🔴 **The control for N7a:** the *same fixture* with the flag flipped to `true` and one open item | 🔴 **REFUSED.** Without this, "fail open" is indistinguishable from "the gate never fires." |
| **N8** | Backward move, Due Diligence → Open Contract, everything open | ✅ **ALLOWED**, `lastRunQueryCount == 0` |
| **N9** | **Insert** a deal at `Stage__c = 'Due Diligence'` with no checklist | ✅ **ALLOWED.** Protects the seed scripts. |
| **N10** | Non-stage save (comment/owner/counter) on a claimed deal with open items | ✅ **ALLOWED**, `lastRunQueryCount == 0` |
| **N11** | Item with `Stage__c = null` whose parent checklist carries `Open Contract`, still open | 🔴 **REFUSED** — proves the parent-checklist fallback attributes it |
| **N12** | Item with `Stage__c = null` **and** parent `Stage__c = null` | ✅ **ALLOWED**, and **`lastRunUnattributedItemCount == 1`** — the documented fail-open, made assertable |
| **N13** | 🔴 **Message purity.** Take the composed message and assert `msg == msg.replaceAll('[^\\x20-\\x7E]', '')`, and that it contains no `&`, `<`, `>` or `"` | Guards the `addError` HTML-escape trap (`ChecklistItemPrerequisiteService.cls:134-138`) |
| **N14** | 🔴 **Order cross-check.** `TransactionStageDomain`'s list agrees with `RecordStageAdvanceService.TRANSACTION_NEXT_STAGE` walked end to end, **and** with the active `Transaction__c.Stage__c` describe values in order | The only thing standing between a third copy of the stage order and a silently inverted gate |
| **N15** | Two deals in one update, one refused and one allowed, `Database.update(deals, false)` | The allowed one **saves**; the refused one does not. Proves per-record `addError`, not a whole-chunk abort. |

**Fixtures:** `TestDataFactory` per `ARCHITECTURE.md` §2. ⚠ `TestDataFactory` is a **hub file** — check
it for an existing checklist/item builder before adding one, and if one must be added, declare it for
the consolidating pass rather than editing it from this stream
(`agent-output/hub-consolidation-tracker.md` protocol).

**Coverage:** 90%+ per class.

**Content quota:** `.claude/rules/content-publication-rule.md` is **not engaged** — nothing here
inserts `ContentVersion`, `ContentNote` or `ContentDocument`.

---

## B7. Open questions — for the business, not for an admin. **None of these blocks the build.**

| # | Question |
|---|---|
| **OQ-A** | **Closing a deal now requires all 15 Post-Closing items complete** (§B3.5), including `J4 Set up auto loan payment at lender bank (CRITICAL)`. This follows correctly from decision 3 and is not being re-argued — but the surprise arrives weeks after deploy, on the day someone tries to close a deal. **Tell the business before go-live.** |
| **OQ-B** | **Is an override wanted?** The user did not ask for one and none is designed. But `Transaction_Prereq_Override` + `Transaction_Prereq_Override_Access` is the exact in-repo precedent for "a hard gate with a narrow, permissioned escape hatch," and a deal can otherwise be stuck if an item is genuinely uncompletable. **Flagged, not built.** |
| **OQ-C** | Should the gate cover **`Checklist_Item__c` items with no stage attribution** by refusing rather than allowing? Today it allows and counts them (§B3.2). Refusing would be safer and would brick any deal whose fan-out predates a CMDT reload. **Recommendation: keep the fail-open, keep the counter, and make A3 #4 a permanent post-fan-out check instead.** |
| **OQ-D** | If A4's probe returns **false**, view-only personas see an empty checklist. Is that acceptable pending a permission fix, or is it a go-live blocker? |

---

# PROMPTS FOR SPECIALIST AGENTS

## 🔵 PROMPT FOR salesforce-admin

> **Route to `salesforce-admin`, not `salesforce-solution-architect`.** The only declarative artefact
> is a three-line edit to one existing flow. No new objects, no new fields, no security model change.

```
Read CLAUDE.md and ARCHITECTURE.md first. Record mcp=unavailable after a real attempt
(.mcp.json declares only the `salesforce` server; you have no salesforce-api-context tools) and
fall back to the per-type skill for Flow. Record the skill-selection status line before writing.

SOURCE OF TRUTH: agent-output/design-checklist-cutover-and-stage-gate.md, section A7.

ONE FILE. THREE LINES. Do not deploy it as part of any other payload.

  force-app/main/default/flows/Transaction_Task_Fanout.flow-meta.xml
    <actionName>TaskFanoutService</actionName>   ->  ChecklistFanoutService
    <nameSegment>TaskFanoutService</nameSegment> ->  ChecklistFanoutService
    <filters><field>Tasks_Fanned_Out__c</field>  ->  Checklist_Fanned_Out__c

DO NOT change: the input parameter name (`transactionId` - both invocables declare it identically,
verified), the Contract_Executed_Date__c filter, filterLogic, recordTriggerType,
triggerType, doesRequireRecordChangedToMeetCriteria, apiVersion, or <status>.

DO NOT add <runInMode>. The flow deliberately declares none - it runs as the calling user, and
that is precisely why ChecklistFanoutService.FanoutWrites is `without sharing` + SYSTEM_MODE.
Adding runInMode would silently void a sharing decision argued at length in that class's header.

🔴 SEQUENCING - THIS IS NOT A DEPLOY-WHENEVER CHANGE:
  - It ships LAST, only after Part A steps A0-A6 are complete and verified on TXN-0285.
  - It ships ALONE. A flow file IS the flow; there is no repointed-but-dormant version.
  - After it ships, the rollback script
    (scripts/rollback-transaction-checklist-migration.apex) UNDOES ITSELF unless this flow is
    deactivated first. That is a deploy, not a script argument. See section A6.
  - A dry-run can report green for an unchanged component. This file IS changing, so it will be
    validated - do not generalise that green to anything else in the payload.

REVERSAL: redeploy the pre-change file. Keep a copy.

DO NOT TOUCH, in this change or any other:
  flows/Transaction_Complete_Close (its Status__c='Closed' filter is an explicit user decision)
  flows/Transaction_Stage_Closed_Sets_Status
  flows/Onboarding_Task_Fanout, flows/Wire_Verification_Rollup
  any quickAction, any flexipage, any pathAssistant, any permission set, any permission set group,
  any object or field metadata.

🔴 NO PERMISSION-SET WORK IS REQUIRED BY THIS DESIGN. Do not open one. A PermissionSet deploy
REPLACES its entire <fieldPermissions> block and this org has a live incident from exactly that.
The ONE exception is if the section A4 probe returns FALSE - in that case STOP and report; the
remedy (viewAllRecords=true on a ControlledByParent detail object) is itself unproven at API 67.0
and needs its own check-only dry-run plus an org readback before anyone writes it.
```

## 🟢 PROMPT FOR salesforce-developer

> **Route to `salesforce-developer`, not `salesforce-technical-architect`.** Standard Apex: one
> domain class, one service, one additive selector method, a handler arm, and tests. No integration,
> no callout, no LDV, no async.

```
Read ARCHITECTURE.md (S1 naming, S2 Apex layering), .claude/rules/apex-layering-rule.md and
.claude/rules/bulk-test-rule.md first. Record mcp=unavailable after a real attempt. Do NOT deploy.

SOURCE OF TRUTH: agent-output/design-checklist-cutover-and-stage-gate.md.
Read sections B2 (design), B3 (edge cases), B4 (budget), B5 (inventory), B6 (tests) in full
before writing anything.

═══ PART A - FIVE ANONYMOUS-APEX SCRIPTS. Named-deal only. NO "all deals" mode on any of them,
matching scripts/rollback-transaction-checklist-migration.apex's refusal behaviour. ═══

1. scripts/preflight-checklist-cutover.apex        - section A0.1 + A0.2 + A0.3. It must REFUSE to
   report OK if Tasks_Complete__c != 0, if the Task census is not 82 in the expected spread, or if
   any Transaction_Task_Def__mdt / Task_Group_Def__mdt count in A0.2 is wrong. Use SOQL for the
   CMDT probe, not getAll().
2. scripts/delete-transaction-checklist-tasks.apex - section A1. Refuse unless the row count
   matches the number the operator pastes in.
3. scripts/fanout-checklist-for-deal.apex          - section A2. ChecklistFanoutService.fanOutNow
   (SYNCHRONOUS, one deal). NOT fanOut(), which defers the failure into AsyncApexJob - this org
   has two recorded outages whose whole cost was an invisible async fan-out failure.
4. scripts/verify-checklist-cutover.apex           - section A3, ALL SIXTEEN assertions. Items 10
   and 11 (Wire_Open_Risks__c == 2 and Tasks_Total__c == 82, both compared to the values recorded
   in A0.1) are the RISK 1 canaries and must print PASS/FAIL in capitals.
5. scripts/probe-controlledbyparent-viewall.apex   - section A4, INCLUDING probe D, the control.
   A probe without a control can pass vacuously; that is the standing lesson from ARCHITECTURE.md
   S3.5's Turnstile gate.

Part A needs NO new production Apex. Rollback reuses ChecklistMigrationService.rollback, which
already exists - read section A6 for the undelete pairing and the 15-day Recycle Bin window before
assuming the existing script is sufficient on its own.

═══ PART B - THE STAGE GATE. Build it AFTER Part A is verified. ═══

1. classes/TransactionStageDomain.cls  (layer=domain)
   The ordered stage list, isForward(prior,next), index lookup, coordinate formatting.
   ZERO SOQL, ZERO DML at any record count (Domain Purity Rule). Values BYTE-IDENTICAL to
   Transaction__c.Stage__c including the hyphen in Post-Closing.
   Unknown/null on either side => NOT forward => not gated, counted in lastRunUnknownStageCount.

2. classes/TransactionStageGateService.cls  (layer=service, public with sharing)
   enforceOnUpdate(List<Transaction__c>, Map<Id, Transaction__c>) -> Map<Id, String>.
   MIRROR ChecklistItemPrerequisiteService's shape exactly: addError only under
   Trigger.isExecuting, return the decision map so unit tests can assert without depending on
   addError, and state in the header that it is TRIGGER-ONLY BY CONTRACT.
   Three passes per section B2.4. Pass 1 is pure memory and must exit before any query when no
   record in the chunk is a forward stage move on a claimed deal.
   🔴 The done test is ChecklistItemDomain.isDone(item.Flag__c) IN MEMORY. Do NOT put
   Flag__c NOT IN ('Completed','Verified') in the WHERE clause - that would be a SECOND definition
   of "done" in an org whose single definition is that one method, and nothing would catch it
   drifting. Read ChecklistItemDomain's header.
   🔴 NO CONSTANT ANYWHERE FOR 11, 46, 10, 15 or 82. Count the rows you read. TaskRollupService's
   header: "Do not turn 82 into a constant anywhere"; activeTransactionsList's header records the
   incident where a hardcoded denominator reported on work that did not exist.
   Message: PURE PRINTABLE ASCII, no em-dash, no quotes around the interpolated subject - addError
   HTML-escapes and that cost a test in Phase 0 (ChecklistItemPrerequisiteService.cls:134-138).
   Cap the enumerated coordinates at 5 plus "and N more."
   In-context instrumentation: lastRunQueryCount, lastRunDmlCount, lastRunChunkCount,
   lastRunRefusalCount, lastRunUnattributedItemCount, lastRunUnknownStageCount - captured INSIDE
   the method body in a finally, NOT via Limits.getQueries() after Test.stopTest(), which restores
   the pre-test counters and makes the obvious assertion vacuous.

3. classes/ChecklistItemSelector.cls  - ADDITIVE ONLY
   Add selectOpenForStageGate(Set<Id> transactionIds, Set<String> stages) exactly as specified in
   B2.4, INCLUDING the `OR Stage__c = NULL` disjunct (without it an unstamped item is invisible and
   the gate fails open silently).
   WITH SYSTEM_MODE, justified AT ITS OWN DECLARATION per ARCHITECTURE.md S2, and the sharing
   question answered SEPARATELY in the same block: the principal is UPDATING the Transaction so
   they hold record-level Edit, and ControlledByParent propagates RECORD-level access - which is
   NOT the same as the viewAllRecords propagation that Checklist__c.object-meta.xml and
   ChecklistRollupService both record as unmeasured. Say that explicitly; the two are easy to
   conflate and the section A4 probe may come back false.
   Add the method to that class's consumer/mode inventory. TOUCH NO EXISTING METHOD - this file is
   shared and its header was corrected on 2026-09-02 for exactly this kind of omission.

4. classes/TransactionTriggerHandler.cls
   Add the second beforeUpdate arm.
   🔴 AND AMEND THE CLASS HEADER IN THE SAME CHANGE. It currently promises the beforeUpdate context
   is "pure in-memory, ZERO SOQL and ZERO DML at any record count, by construction". That sentence
   becomes false. The substance survives (zero SOQL on every save that is not a forward stage move,
   which includes every rollup write) but the wording must be rewritten with the new arm's bounded
   cost stated. This repo treats a stale header as a defect.

5. classes/RecordStageAdvanceService.cls - ONE WORD. Add @TestVisible to the private static final
   Map TRANSACTION_NEXT_STAGE (line ~1526) so the N14 cross-check test can walk it. Change NOTHING
   else in that file - it is 2,600 lines and dispatches eight objects.

TESTS - sections B6. Every negative control listed there is mandatory; a gate that never refuses is
worthless, and each MUST be shown to actually fail the save.
  - T-BULK-1 satisfies the 251 mandate LITERALLY (251 UNCLAIMED deals; cheap fixture; forces two
    chunks; asserts ZERO SOQL).
  - The claimed-deal volume test is a DOCUMENTED CARVE-OUT: 251 x 82 = 20,582 Checklist_Item__c
    rows in one insert against a 10,000 DML-row limit is impossible to build, so it runs at the
    chunk boundary with a trimmed fixture. Write that arithmetic into the test class header, citing
    .claude/rules/bulk-test-rule.md's "testing a volume production cannot reach" exemption and
    ChecklistFanoutServiceTest.staysWithinBudgetAtTheChunkBoundary as the in-repo precedent, so
    review does not demand a literal 251.
  - N2 must assert the RecordStageAdvanceException message equals the gate's message VERBATIM.
  - N3 must assert Database.update(deal, false) REFUSES - allOrNone=false must not swallow it.
  - N5a/N5b are the isDone pair; N6a/N6b are the anti-hardcode pair; N7a/N7b are the fail-open
    pair. NEITHER HALF OF ANY PAIR IS THE TEST ON ITS OWN.
  - Use TestDataFactory. It is a HUB FILE - check for an existing checklist/item builder before
    adding one, and if one is genuinely needed, DECLARE it for the consolidating pass rather than
    editing the file from this stream.
  - 90%+ coverage per class.

DO NOT TOUCH: ChecklistRollupService, ChecklistFanoutService, ChecklistItemPrerequisiteService,
ChecklistItemService, ChecklistItemDomain, ChecklistItemTriggerHandler, ChecklistController,
TaskRollupService, TaskSelector, TransactionSelector, TransactionStageEntryService, any Checklist
Migration class, any LWC, any FlexiPage, any quick action, the Path, any report or dashboard, any
permission set, any permission set group, or .forceignore.

DO NOT build: an override custom permission (OQ-B - flagged for the business, not approved), a
Task-model branch of the gate (it would be deleted at M5), any part of M4 or M5, or any
CriticalDateService trigger wiring (GATE-B2/B3/B4 are still open).
```

---

## APPENDIX — Every assumption I could not verify, in one place

Per the brief's instruction, and because this repo has a documented incident
(`design-docs-become-agent-authority`) where an unverified number in an `agent-output/` file was later
re-read as fact:

1. **I have no org access.** `mcp=unavailable`; no `sf` CLI; file-system tools only. **Every statement
   about the state of `usman-dpeg` in this document originates in the brief, not in a measurement I
   made.** That includes TXN-0285's id, stage, owner, `Loan_Required__c`, its 82 Tasks and their
   spread, all four counter values, the zero `Checklist__c` rows, and deploy `0Afiw000000Vm8PCAS`.
   §A0.1 re-asserts the load-bearing ones as a mandatory probe for exactly this reason.
2. 🔴 **UNVERIFIED, HIGHEST RISK: whether the two CMDT loader scripts have been re-run against the
   org.** The scripts in the working tree DO write `Stage__c`, `Is_Critical__c`,
   `Is_Wire_Verification__c` and `Blocked_By_Sequence__c` — but `**/customMetadata/**` is
   force-ignored, records never deploy, and a re-run cannot be seen from the repo. **If they have not
   been re-run, the fan-out produces 82 unstaged, unflagged, ungated items and `Wire_Open_Risks__c`
   reads 0 with nothing erroring.** This is §A0.2 and it is a hard gate.
3. **UNVERIFIED: that `Checklist__c`, `Checklist_Item__c`, the Phase 2/3/4/5 Apex, and the
   `Prerequisite_Must_Be_Met_To_Complete` validation rule are actually deployed and active in the
   org.** The brief implies they are. §A0.3 checks.
4. **UNVERIFIED: `viewAllRecords` propagation to `ControlledByParent` details.** That is §A4, the
   probe. Both `Checklist__c.object-meta.xml:25-30` and `ChecklistRollupService.cls:392-399` state
   they could not measure it.
5. **UNVERIFIED: whether `viewAllRecords=true` is even settable on a `ControlledByParent` object at
   API 67.0.** This is the *remedy* if §A4 fails, and it is a second unproven shape — it needs its own
   dry-run plus readback.
6. **UNVERIFIED: whether `UserRecordAccess` accepts a `ControlledByParent` detail record id.** §A4
   gives a fallback if it returns no rows.
7. **ESTIMATED, NOT MEASURED: the gate's heap at a 200-deal chunk** (~9,200 sObjects × 8 fields,
   ~1.5–2 MB). The SOQL and DML figures in §B4 are exact arithmetic; the heap figure is not.
8. **UNVERIFIED: `DPEG_Transactions_Team` public-group membership**, and therefore who is a valid §A4
   probe subject and who can run Part A. Group membership is **not deployable** and cannot be read
   from the repo.
9. **ASSUMED: the operator runs as a System Administrator.** Task delete cannot be granted by
   permission set on this platform, so Part A requires profile-level Delete on Activities or Modify
   All Data. Not confirmed with the user.
10. **CORRECTED, not assumed: the brief's "no quick actions on `Transaction__c`" is false** (§1.1) and
    `design-transaction-fsd-gaps.md` RISK 2's `deleteConstraint=Restrict` is stale (§1.2).
11. **NOT verified by me: that `Tasks_Overdue__c` will match across the two models.** §A3 #16 records
    both and states why they may legitimately differ. Do not treat a difference there as a failure
    without checking the `Contract_Executed_Date__c + Due_Day_Offset__c` arithmetic.
