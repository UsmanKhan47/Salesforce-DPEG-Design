# Phase 4 — Transaction checklist migration (M0 → M4)

**Date:** 2026-09-02 · **Agent:** salesforce-technical-architect · **Status:** designed + implemented, **not deployed, not run, not committed**.

Scope is §7 M0 → M4 of `agent-output/design-transaction-fsd-gaps.md`. M5 is Phase 5; §8 below says what it needs.

Everything asserted here was measured from the working tree today. Where the design doc's premise turned out to be
stale or wrong, it is corrected with the file and the line that falsifies it, not restated.

---

## 0. Three premises in the brief that are wrong, and they change the plan

Read these first — two of them make Phase 4 **smaller** than briefed, and the third makes it **harder**.

### 0.1 🔴 The wire gate does **not** refuse the migration's link stamp. It cannot. Measured.

The brief says a mass migration that writes `Blocked_By__c` on open items "will be refused row by row unless it
runs as a holder of `Transaction_Prereq_Override`". That is true of a **re-link** or a **clear**. It is **false**
of the first stamp, and the migration only ever does the first stamp.

`ChecklistItemPrerequisiteService.enforceChunk`:

```apex
candidate.linkChanged = priorBlockedBy != null && item.Blocked_By__c != priorBlockedBy;
```

with the comment directly above it: *"GAINING a link for the first time is NOT a change — that is the fan-out's
second pass **and the migration**, and refusing it would make the feature uninstallable."* Branch (B) — the disarm
refusal, the only branch with an override — is gated on `candidate.linkChanged`. On a `null -> X` write it is
false, so (B) never evaluates and **the override is never consulted.**

The other three branches, checked one at a time against the migration's actual saves:

| Branch | Fires when | The migration's link-stamp UPDATE |
|---|---|---|
| **(A)** primary control, no override ever | `entering` (open → done) **and** prerequisite not met | ✅ Never fires. The stamp pass writes `Blocked_By__c` + `Is_Prerequisite_Met__c` and **nothing else** — `Flag__c` is untouched, so `entering` is false on every row, including rows migrated already-complete. |
| **(D)** illegitimate link write, no override | writing a link that is self, unresolvable, or cross-deal | ✅ Never fires. Both targets are same-deal rows this transaction just inserted; `written` resolves and `written.Checklist__r.Transaction__c == storedSelf.Checklist__r.Transaction__c`. |
| **(B)** disarming a live gate, **has** the override | `linkChanged` (prior non-null) and the stored target is open | ✅ Never fires — `linkChanged` is false. |

The validation rule is the other half and it also passes, for a separate reason:
`Prerequisite_Must_Be_Met_To_Complete` is `AND(OR(ISNEW(), ISCHANGED(Flag__c)), ...)`. The stamp pass is neither
new nor a `Flag__c` change, so the rule does not evaluate — **including on the awkward real case: a live deal
where B3 was completed while B2 is still open** (entirely possible; Phase 0's gate only shipped 2026-08-31, so
every older deal predates it). That row migrates, keeps its history, and carries `Is_Prerequisite_Met__c = false`
— visible, reportable, and refused only if somebody later re-touches its `Flag__c`. That is the correct outcome
and it required no override.

**What the gate DOES refuse, and the migration is built around it:**

> 🔴 **INSERT an item that is already `Completed`/`Verified` AND carries `Blocked_By__c` in the same statement.**
> `clampOnInsert` forces `Is_Prerequisite_Met__c = false` whenever a link is present at insert — deliberately,
> with no lookup, because a sibling read in before-insert would cost ~21 SOQL on the fan-out cascade — and the
> VR's `ISNEW()` arm then refuses the row. It refuses **whatever the prerequisite's real state is**. With
> `allOrNone = false` it would *silently drop exactly the completed B3/I8 rows*, which is the worst possible
> failure: a migration that reports success and loses the two most important rows on the deal.

⇒ **The migration inserts every item with `Blocked_By__c` BLANK and stamps the links in a second `update`.**
That is not a workaround invented here — it is byte-for-byte the shape `ChecklistFanoutService.fanOutNow` already
uses (its PASS 2 / PASS 3), the shape `scripts/backfill-task-blocked-by.apex` uses on the Task model, and the
shape `TaskPrerequisiteServiceTest.allowsBackfillOfAnAlreadyCompleteDependent` pins. Reusing it means the gate
is not a Phase 4 risk at all; it is a Phase 4 *constraint on statement ordering*, and the ordering is enforced
structurally: `ChecklistMigrationService` has exactly one item-insert site and it never sets `Blocked_By__c`.

`Transaction_Prereq_Override` is therefore **not required to run the migration** and the runner should **not** be
granted it. It stays what it is: the escape hatch for repairing a wrong-but-resolvable link on an open row.

### 0.2 ⚠ There is no `ChecklistMigrationBatch`, and there should not be. It is a Queueable chain.

§7 M1 says `Database.executeBatch(batch, 50)`. A `Database.Batchable` needs a `QueryLocator` over
`Transaction__c`, all `Transaction__c` SOQL lives in `TransactionSelector`, and **`TransactionSelector` is owned
by a concurrent session and is on the do-not-touch list**. Adding a locator there would be exactly the hub-file
collision `agent-output/hub-consolidation-tracker.md` exists to prevent.

The Queueable chain is not a compromise, it is the better shape here:

- it is `ChecklistFanoutQueueable` verbatim — same chunking, same `ChainFinalizer` so one failed chunk does not
  strand the chunks behind it, same suppression discipline;
- the operator names the deals, so a **3-deal pilot** is the same code path as an org-wide run — which for a
  one-shot live-data migration is a feature, not a limitation;
- it needs **no new `Transaction__c` SOQL at all**: `TransactionSelector.selectForChecklistFanout(Set<Id>,
  Set<String>)` already exists, is already `SYSTEM_MODE`, and its second parameter is a describe-validated list
  of extra field API names. `ChecklistRollupService` already calls it with an empty set. The migration calls it
  with the five legacy counter fields it needs. **Stated plainly because it is a reuse and not what the parameter
  is named after:** the cleaner long-term shape is a dedicated `TransactionSelector.selectForChecklistMigration`,
  and whoever owns the next hub pass should add it. It is not added here because that file is not mine this week.

### 0.3 ✅ M2 can be a **mechanism**, not just a check — and that removes the last-writer race entirely

The brief's complaint is exact: *"§7's M2 reconciliation is a check, not a mechanism."* It is now both, because
the comparison is computable **before any DML**. The migration builds the new rows in memory from the deal's own
`Task` rows; the old model's counters are recomputable from those same `Task` rows in the same transaction. So:

> **A deal is migrated only if its projected new-model state reconciles exactly with its live Task state.
> A deal that does not reconcile is not migrated at all — nothing is inserted for it and its flag stays false.**

The consequence is that a disagreement is loud in the only way that survives an async job with no UI: **the deal
visibly does not move.** `Checklist_Fanned_Out__c = false` after a migration run is a queryable, unambiguous
"this deal was refused", and `ChecklistMigrationAuditService` then explains each one line by line.

---

## 1. The counter guard — decision: **implement the proposed tiebreak, unchanged**

### The collision

`ChecklistRollupService.recalc` refuses to write `Tasks_Total__c` / `Tasks_Complete__c` / `Tasks_Overdue__c` /
`Wire_Open_Risks__c` unless `Checklist_Fanned_Out__c` is true. Nothing is symmetric on the other side:
`TaskRollupService.recalc` recomputes all four from `Task` rows on **any** checklist-Task save, for **any** deal,
including one already cut over. From M1 that is last-writer-wins on a live deal — and the *loser* is the model
the UI is rendering, so the dashboard number and the checklist on screen disagree with each other
non-deterministically.

### Alternatives considered and rejected

| Option | Verdict |
|---|---|
| Rely on M2 to prove the two agree | ✗ It proves it **at one instant**. The race is continuous — every subsequent Task edit re-runs it. A proof is not a lock. |
| Suppress `TaskRollupService` from the migration only | ✗ Closes the migration transaction and nothing after it. The race is created by *ordinary user Task edits after cutover*, which the migration cannot suppress. |
| Delete/deactivate `TaskRollupTrigger` at M1 | ✗ Shared with Property Management (Onboarding rollups, the onboarding completion stamp, the Phase 0 wire gate). Blast radius far outside Transactions. |
| Make the four counters roll-up summaries | ✗ Settled and closed in `ChecklistRollupService`'s header for three independent reasons; two of the four cannot be roll-ups at all. |
| Give the Checklist model its own four counters | ✗ Repoints eleven reports and a dashboard for a problem a boolean solves. Contradicts the whole "both services write the same four fields so consumers are model-agnostic" property that `TaskRollupService`'s header rests on. |
| **Skip deals whose `Checklist_Fanned_Out__c` is true** | ✅ **Chosen.** |

### Why the proposed tiebreak is right

It is **strictly narrowing** — it can only ever cause *fewer* writes, never a different value. It adds no field,
repoints no report, and touches no LWC. It inverts cleanly into a single sentence that is now true in both
directions: **the Task model owns a deal until the Checklist model claims it, and `Checklist_Fanned_Out__c` is
the claim.** And it is written by exactly one class (`ChecklistFanoutService`, plus the migration), which is why
`TestDataFactory` and every seed script are immune by construction rather than by a bypass flag.

### What it costs — the field is genuinely not in the query today

`TaskRollupService.recalc` reads only `Task` (via `TaskSelector.selectByTransactionDealIds`, `WITH SYSTEM_MODE`).
It has no `Transaction__c` read at all, so the guard is **one extra SOQL per `recalc` call**. Two mitigations
make that a wash or better:

1. **The guard read goes FIRST and can short-circuit the Task read.** On a fully migrated deal `recalc` now costs
   **1 SOQL and 0 DML** where it previously cost 1 SOQL and 1 DML. It is cheaper after cutover than before.
2. **It reuses `TransactionSelector.selectForChecklistFanout(dealIds, new Set<String>())`** — the identical call
   `ChecklistRollupService` already makes for the identical purpose. No new selector method, no new field list,
   no `TransactionSelector` edit.

Worst case is the dual-model window on a legacy deal: 2 SOQL instead of 1. The binding path is the **legacy Day-0
fan-out cascade**, which is *not* suppressed on the Transaction arm (`TaskRollupTriggerHandler.recalcOnboardings`
gates the Onboarding branch; `recalcDeals` is deliberately untouched). `TaskFanoutQueueable.CHUNK_SIZE = 100` ×
82 Tasks = 8,200 rows inserted in one statement → `ceil(8200/200) = 41` after-insert firings:

| | SOQL | DML statements |
|---|---|---|
| today | 41 | 41 |
| with the guard | **82** | 41 |

Async limits are 200 SOQL / 150 DML statements. 82 of 200 is 41 % — real, headroom-consuming, and **bounded and
temporary**: it exists only while a deal is on the Task model, and M3 stops creating such deals. It is pinned by
an in-context counter assertion, not by inspection. If it ever became the binding constraint the fix is to lower
`TaskFanoutQueueable.CHUNK_SIZE`, which is a one-line change to a class M5 deletes anyway.

**Implemented in `TaskRollupService.recalc`.** This is the one sanctioned change to the live legacy stack.

⚠ Two knock-on effects, stated so they are not met as bugs:
- `scripts/seed-transaction-progress.apex:242` calls `TaskRollupService.recalc` directly. After the tiebreak it
  is a no-op for any migrated deal. That is correct (a migrated deal's counters come from its items), and it is
  inert on a fresh demo org where nothing is migrated.
- `ChecklistMigrationService.rollback` must clear the flag **before** calling `TaskRollupService.recalc`, or the
  guard it just installed will skip the very recompute the rollback needs. Enforced by statement order in one
  method, and pinned by a test.

---

## 2. M0 → M4

Old `Task` rows are **left in place and made read-only. Nothing is converted in place and nothing is deleted.**
Both models coexist behind `Checklist_Fanned_Out__c`.

| Step | What | Reversal |
|---|---|---|
| **M0** | Deploy the counter-guard tiebreak + the migration machinery + the audit service. **Behaviour-neutral**: the guard only changes behaviour for deals with `Checklist_Fanned_Out__c = true`, of which there are zero, and the migration runs for nobody until a script invokes it. | Redeploy the prior `TaskRollupService`. Nothing else moved. |
| **M1** | Run `scripts/migrate-transaction-checklists.apex` → `ChecklistMigrationQueueable` chain, 25 deals per chunk. Per deal: read its Tasks, project 11 `Checklist__c` + N `Checklist_Item__c` mapped **by `Task_Group__c` letter + `Task_Sequence__c`**, reconcile the projection against the Tasks, and only then insert + stamp links + set `Checklist_Fanned_Out__c = true` and the four counters. A deal that fails reconciliation is skipped whole. **Pilot 3 deals first — same code path.** | `scripts/rollback-transaction-checklist-migration.apex`: clear the flag, delete the `Checklist__c` rows (cascade removes items), recompute from Tasks. Tasks were never touched. 🔴 **VALID ONLY BEFORE M3** — after the flow repoint, clearing the flag IS a change *into* the repointed criteria, so the flow re-fans and re-claims the deal and overwrites the recompute. Deactivate or re-filter the flow first. |
| **M2** | `scripts/reconcile-checklist-migration.apex` → `ChecklistMigrationAuditService`. Per deal, per check, per coordinate. **Any discrepancy blocks cutover.** Run it over the migrated population *and* over anything still un-migrated (which explains why M1 refused it). | Read-only. |
| **M3** | **Repoint the fan-out flow so NEW deals are born on the new model.** One file, four lines (§4). Deploy on its own, after M2 is clean. | Redeploy the prior flow. Data untouched. |
| **M4** | Freeze the legacy Tasks: remove the `Transaction_Task_Actions` grant from `DPEG_Task_Edit`. **Do not delete Tasks.** | Re-add the grant. |

**M4 is specified, not applied here.** `DPEG_Task_Edit` is a hub permission set and a **PermissionSet deploy
replaces its whole `<fieldPermissions>` block** — a partial edit from a parallel stream silently revokes whatever
the other stream added. Per the parallel-build protocol the change is declared for the consolidating pass:

```
force-app/main/default/permissionsets/DPEG_Task_Edit.permissionset-meta.xml
  REMOVE the <customPermissions> entry whose <name> is Transaction_Task_Actions.
  Leave everything else, and in particular DO NOT re-add the Task <objectPermissions> block —
  that file's 2026-08-28 comment explains why it must stay absent.
```

⚠ M4 makes legacy Tasks read-only **for holders of that set only**. `Transaction_Task_Actions` is also granted by
`DPEG_Disposition_View` (verified today). Whether that grant is deliberate or accidental is a question for the
permission owner; removing it is a Disposition-side change and is **out of scope** here — flagged, not touched.

---

## 3. The M2 reconciliation report

The artefact that gates cutover. Three design rules, each chosen against a way this project has been burned:

1. **No percentages, no scores, no ratios.** Every finding names a deal, a check, and — where the check is
   per-item — a **coordinate** (`B2`, `F12`, `H2:5`). A number like "97 % agreement" is unactionable and hides
   which 3 %. The trailer counts **deals**, never percent.
2. **The comparison is computed from the same rows twice, not from a stored number.** Stored
   `Transaction__c.Tasks_*` may legitimately disagree with the Tasks — the seed scripts assign them directly —
   so the stored values are reported as **ADVISORY** and never gate anything.
3. **The predicates are the deployed ones, not re-implementations.** Done-ness uses
   `ChecklistItemDomain.isDone`; the legacy wire predicate is `Subject` contains `anti-fraud` **and**
   `Verbal_Verification_Completed__c != true`, which is `TaskRollupService.recalc` line-for-line. A
   reconciliation that quietly *improved* on the old predicate would prove nothing — which is precisely why
   `ChecklistRollupService`'s open-wire predicate was deliberately built to mirror the legacy one.

### The checks, in report order

| # | Check | Severity | What a failure means |
|---|---|---|---|
| 1 | `NOT_VISIBLE` — a deal asked for that the selector did not return | 🔴 blocking | Sharing. The runner cannot edit that deal, and a silent partial is exactly what this org punishes. |
| 2 | `COORDINATE_MISSING_ITEM` / `COORDINATE_MISSING_TASK` / `COORDINATE_DUPLICATE` | 🔴 blocking | A Task with no item, an item with no Task, or two rows on one coordinate. Named individually. |
| 3 | `NO_DEFINITION` — a Task coordinate with no `Transaction_Task_Def__mdt` row | 🔴 blocking | The item would be built with `Is_Critical__c` / `Is_Wire_Verification__c` false — i.e. a wire item silently losing its flag. Refuse the deal. |
| 4 | `NO_GROUP_DEFINITION` — a group letter with no `Task_Group_Def__mdt` row | 🔴 blocking | The checklist would carry no `Stage__c`, so its phase tab renders empty. |
| 5 | `STATUS_MISMATCH` at a coordinate — `Task.IsClosed` vs `isDone(Flag__c)` | 🔴 blocking | Completion history lost or invented. |
| 6 | `WIRE_FLAG_MISMATCH` at a coordinate — legacy `anti-fraud` parse vs `Is_Wire_Verification__c` | 🔴 blocking | **The RISK 1 canary.** Proves the boolean agrees with the string parse on the same rows before the string parse stops being consulted. |
| 7 | `VERBAL_MISMATCH` / `DUE_DATE_MISMATCH` at a coordinate | 🔴 blocking | Wire evidence or the overdue source silently altered. |
| 8 | `COUNTER_MISMATCH` — all four counters, Task-derived vs item-derived | 🔴 blocking | Named per counter with both values. |
| 9 | `WIRE_ITEM_COUNT` — must be exactly 2, and they must be `B2` and `I7` | 🔴 blocking | Both coordinates are listed in the line. |
| 10 | `CRITICAL_COUNT` — must equal the CMDT-declared critical set **for the groups this deal actually has** | 🔴 blocking | ⚠ §7 says "assert the CRITICAL count is 4 per deal". **That is wrong for a no-loan deal**: `F12` lives in conditional group F, so a no-loan deal legitimately has 3 (`B2`, `I7`, `J4`). Hardcoding 4 would red-line every no-loan deal. Derived, and the expected coordinates are printed. |
| 11 | `PREREQ_UNRESOLVED` — a definition declaring a `Blocked_By` pair whose item has a null `Blocked_By__c` | 🔴 blocking | The wire gate is disarmed on that deal. |
| 12 | `STORED_COUNTER_DRIFT` | ⚪ advisory | Pre-existing Task-model drift or a seed-script assignment. Reported, never blocking. |

### Shape

```
== CHECKLIST MIGRATION RECONCILIATION ==
mode        : PERSISTED (post-migration)  |  PROJECTED (why M1 refused this deal)
deals asked : 12
--------------------------------------------------------------------------
TXN-0267  Riverbend Commons          CLEAN
TXN-0281  Harborside Flex II         DISCREPANT
  [BLOCKING] COUNTER_MISMATCH   Wire_Open_Risks__c  tasks=2  items=1
  [BLOCKING] WIRE_FLAG_MISMATCH I7   tasks=true  items=false
  [ADVISORY] STORED_COUNTER_DRIFT    Tasks_Complete__c  stored=31  tasks=29
--------------------------------------------------------------------------
DEALS COMPARED 12 | CLEAN 11 | DISCREPANT 1 | NOT VISIBLE 0
CUTOVER: BLOCKED  (1 deal has blocking discrepancies)
```

The last line is `CUTOVER: CLEAR` or `CUTOVER: BLOCKED`, deterministic, greppable, and it is the only thing
anyone needs to read. The two modes matter: a **migrated** deal is compared against its **persisted** items
(proving the DML landed what was projected); an **un-migrated** deal is compared against a **fresh projection**
(explaining exactly why M1 refused it). Same comparison code, one flag.

Both surfaces are capped at **25 deals per invocation** — heap, not SOQL. The audit holds both models in memory
at once (`25 × (82 Tasks + 82 items + 11 checklists)` ≈ 4,400 sObjects); a synchronous run has a 6 MB ceiling and
the script chunks accordingly.

---

## 4. M3 — the flow repoint, specified and deliberately NOT applied

`flows/Transaction_Task_Fanout.flow-meta.xml`, four lines:

```diff
-        <actionName>TaskFanoutService</actionName>
+        <actionName>ChecklistFanoutService</actionName>
...
-        <nameSegment>TaskFanoutService</nameSegment>
+        <nameSegment>ChecklistFanoutService</nameSegment>
...
-            <field>Tasks_Fanned_Out__c</field>
+            <field>Checklist_Fanned_Out__c</field>
```

The input parameter name (`transactionId`) is identical on both invocables, so it does not change.

**Not applied here, on purpose.** A flow file *is* the flow — there is no way to ship a repointed-but-dormant
version. Deploying it in the same payload as M0 would perform M3 on the day M0 lands, i.e. cut new deals over
before a single deal has been migrated or reconciled. It is a one-file deploy that must happen **after** M2
reads `CUTOVER: CLEAR`.

Two properties worth knowing before that deploy:
- `doesRequireRecordChangedToMeetCriteria` is `true`, so the repointed flow does **not** retroactively fire for
  the backlog of un-migrated deals — they already satisfy `Checklist_Fanned_Out__c = false` and are not
  *changing into* satisfying it. Repointing does not accidentally fan out live deals.
- A deal created after M3 gets the new model only, so `Tasks_Fanned_Out__c` stays false and it has no `Task`
  rows at all — `TaskRollupService` can never fire for it, guard or no guard.

---

## 5. Governor arithmetic — re-derived for the migration, not inherited from the fan-out

Fan-out: 96 rows/Transaction (11 + 82 + 2 + 1), `CHUNK_SIZE = 50` → 4,800 rows, and the binding limit is **SOQL,
not DML rows** — 50 × 82 = 4,100 items inserted in one statement fires after-insert in `ceil(4100/200) = 21`
batches, × 4 selector reads per `ChecklistRollupService.recalcForChecklistIds` = **84 SOQL** against a 100-query
limit. Suppression is what makes it 0.

The migration writes **the same 96 rows** but its read side is heavier and its memory side is roughly double.

**Per chunk (`CHUNK_SIZE = 25`), suppression ON:**

| | Count | Source |
|---|---|---|
| SOQL | **4** | 1 `TransactionSelector.selectForChecklistFanout` · 1 `TaskSelector.selectForChecklistMigration` · 1 `ChecklistSelector.selectByTransactionIds` (idempotency probe) · 1 fired by the link `update` — `ChecklistItemPrerequisiteService.enforceOnUpdate` spends one read per chunk, and **suppression does not cover it** (that flag is the rollup arm only, and suppressing the gate on the write it exists to police would be wrong). |
| DML statements | **4** | checklists · items · links · transactions. Limit 150. |
| DML rows | **2,400** | 25 × 96. Limit 10,000 → 76 % headroom. |
| Queueable enqueues | **1** | from the `ChainFinalizer`, never from `execute()`. |

**Why 25 and not the fan-out 50 — derived, not copied.** ⚠ The heap figures are **estimated from
row counts, not measured**; nothing here has been run against an org. The DML-row and SOQL figures
are exact arithmetic. DML rows are not the constraint (2,400 of
10,000). **Heap is.** The fan-out holds only the new side; the migration holds the Tasks *and* the projected
items *and* the coordinate maps *and* the discrepancy lines simultaneously:

| chunk | sObjects held (Tasks + items + checklists) | async heap (12 MB) |
|---|---|---|
| 50 | ~8,750 | uncomfortably close; one added field per Task moves it |
| **25** | **~4,375** | ✅ chosen |

**Suppression is mandatory and is not optional here either.** 25 × 82 = 2,050 items in one insert → 11
after-insert batches × 4 selector reads = **44 SOQL** to recompute counters for rows the same statement is still
creating — on top of the 4 above, and the migration then overwrites them anyway with values it already knows.
`ChecklistRollupService.suppressTriggerRecalc(true)` wraps all four statements, restored to the **prior** value
in a `finally` (never blindly false — `reconcile` can already have suppressed).

**What the migration does NOT pay:**
- The `Transaction__c` update sets `Checklist_Fanned_Out__c` + four counters. `TransactionTriggerHandler`'s arms
  are all change-gated on `Stage__c` / `Loan_Required__c` / `Opportunity__c` / the closed boundary, none of which
  this write moves — so the deal-close gate and the reconcile arm both collect zero ids and spend nothing.
- The CMDT reads are `getAll()`, which is free. Every new column is short text / number / checkbox precisely so
  that stays true (`getAll()` clips LongTextArea to 255 and this org has paid for that once).

**New failure mode, same as the fan-out's:** a master-detail child insert **locks its master**, so a concurrent
user edit of a `Transaction__c` during migration can raise `UNABLE_TO_LOCK_ROW` where the Task model could not.
Bounded by the chunk (25 deals) and by the migration being a one-shot. If it happens, the chunk fails, the
Finalizer keeps the chain moving, and the affected deals simply stay un-migrated — re-runnable, because the
whole thing is idempotent on `Checklist_Fanned_Out__c`.

---

## 6. Rollback — re-derived, because §7's sentence is stale

§7 RISK 2 says *"delete the deal and re-fan it is not available as a repair path"* because
`Critical_Date__c.Transaction__c` was `required=true` + `deleteConstraint=Restrict`.

**That is no longer true.** Verified in the working tree today: the field is `<required>false</required>` +
`<deleteConstraint>SetNull</deleteConstraint>`, relaxed 2026-08-31 under GATE-B3, and its own description says
the relaxation exists so *"a Transaction carrying critical dates stays deletable and a botched migration stays
reversible"*.

**Deal deletion being available does not make it the right repair, and it is not the rollback.** Deleting the
Transaction cascade-deletes the `Checklist__c` rows *and* orphans or destroys the deal's `Task` rows — the one
thing this entire strategy exists to preserve, and the one thing that cannot be reconstructed. It also destroys
`Wire__c` links, field history, and the Opportunity gate flags.

**The rollback is per-deal and additive-reversing:**

```
1. Set Checklist_Fanned_Out__c = false          ← FIRST. The counter guard now skips claimed deals,
                                                   so this must precede step 3 or the recompute no-ops.
2. Suppress the rollup, delete the deal's Checklist__c rows (master-detail cascades the items),
   restore the prior suppression value in a finally.
3. TaskRollupService.recalc(dealIds)            ← the legacy model recomputes its own four counters
                                                   from the Task rows, which were never touched.
```

Reversal properties: `Task` rows are untouched throughout, so **the Task model is authoritative again the instant
step 1 commits**. `Critical_Date__c`, `Wire__c`, `Loan__c` and `Insurance_Binder__c` are not touched by the
migration at all and need no reversal. `Transaction__c` is `enableHistory=true`, so both the claim and the
un-claim are in field history and the whole exercise is auditable — use that in M2.

⚠ Step 2 needs delete access on `Checklist__c`; `writeRequiresMasterRead=false` on both master-detail links means
that requires **Edit sharing on the Transaction**, exactly like the migration itself (§7 below).

🔴 **AND IT IS VALID ONLY BEFORE M3 — the rollback undoes itself afterwards.** Step 1 writes
`Checklist_Fanned_Out__c` true → false. M3 repoints the fan-out flow to filter on that field being
false, and the flow carries `doesRequireRecordChangedToMeetCriteria = true`, so the un-claim **is**
a record changing *into* the criteria: the flow fires, `ChecklistFanoutService` finds its only
dedupe guard now false, and the deal is re-fanned with a brand-new checklist and re-claimed —
`Tasks_Complete__c` overwritten with 0, destroying step 3 and every completion M1 carried over.
§4 below reasons about whether the repointed flow fires *retroactively* for the un-migrated backlog
(it does not) and stops there; it never asks what **else** writes that flag. After M3, a rollback
requires deactivating or re-filtering the flow first — a deploy, not a script argument. This is a
further reason M3 is sequenced only after M2 reads `CUTOVER: CLEAR`.

**Rollback of M3** is a flow redeploy. **Rollback of M4** is re-adding one grant. Neither touches data.

---

## 7. Sharing — the one thing that can make M1 fail silently, and how it is made loud

Every DML in the migration is `AccessLevel.SYSTEM_MODE`, which lifts CRUD/FLS and **never** sharing. Both
master-detail links carry `writeRequiresMasterRead=false`, which is the **stricter** setting — it requires read
**and write** on the master — so inserting a `Checklist__c` requires **Edit sharing on the `Transaction__c`**.

`Transaction__c` is OWD Private. `sharingRules/Transaction__c` grants **Edit** to the `DPEG_Transactions_Team`
public group for every deal with a non-blank `Stage__c`.

⇒ **Operator prerequisite, and it is a go-live gate, not a footnote:** the migration must be run by a member of
`DPEG_Transactions_Team`, or by a user with Modify All Data. Group membership is **not deployable**, so this
cannot be verified from the repo and must be checked in the org before M1.

⇒ **A deal the runner cannot see returns no row from the `with sharing` selector and would simply be skipped —
silently.** That is the failure class this org punishes hardest, so the migration diffs the ids it was **asked**
to migrate against the ids the selector **returned** and reports every difference as `NOT_VISIBLE`. A deal with a
blank `Stage__c` (outside the sharing rule's criteria) surfaces here rather than vanishing.

⚠ `ChecklistRollupService.RollupWrites` is `without sharing` and its header explicitly names *"a future migration
batch or Schedulable"* as the shape whose principal would lack Edit sharing, asking for a non-owner test before
re-pricing it. **This migration is that shape, and it deliberately does not rely on that escalation** — it never
routes through `ChecklistRollupService` (suppression is on and it writes the counters itself). The re-pricing
question the header poses is therefore still open and is still Phase 5's, not answered by side-effect here.

---

## 8. What M5 will need (Phase 5) — so it is not a surprise

1. **A quiet period, not a date.** M5 deletes the nine Transaction-only `Activity` fields. **A deleted field name
   stays reserved until it is ERASED**, and erasing is irreversible. Run M2 one final time immediately before.
2. **`objects/Activity/fields/` is shared with PM and Broker Protection.** Exactly nine fields are
   Transaction-only: `Task_Group__c`, `Task_Sequence__c`, `Task_Owner_Label__c`, `Transaction_Deal__c`,
   `Conditional__c`, `Verbal_Verification_Completed__c`, `Verified_By__c`, `Verified_At__c`,
   `Verification_Phone__c`. `Onboarding*`, `Source_System__c`, `Blocked_Reason__c`, `Inbound_Message_Id__c` and
   `Thread_Key__c` are **not**, and neither is `Blocked_By__c` / `Is_Prerequisite_Met__c` until Phase 0 goes with
   them.
3. **Phase 0 is discarded whole at M5** — `TaskPrerequisiteService`, its test class, the Task-scoped
   `Prerequisite_Must_Be_Met_To_Complete`, `Task.Blocked_By__c`, `Task.Is_Prerequisite_Met__c`,
   `scripts/backfill-task-blocked-by.apex`. That was always the plan and the cost was accepted up front.
4. **Retire in this order, or the compile breaks:** first `TaskRollupTriggerHandler`'s Transaction arm +
   `TaskRollupTrigger`'s Transaction contexts (**leave the Onboarding arm and the before contexts — PM needs
   them**), then `TaskRollupService` + `TaskFanoutService` + `TaskFanoutQueueable` + their tests, then the two
   `TaskSelector` methods (`selectByTransactionDealIds`, `selectChecklistByTransactionDealIds`) plus the
   `selectForChecklistMigration` this phase adds, then the fields. `TaskSelector`'s header calls itself *"a
   contract, not a private helper"* — six of its nine methods belong to PM, Disposition and Broker Protection.
5. 🔴 **`TaskSelector`'s SYSTEM_MODE mode inventory must shrink with it.** ARCHITECTURE §2 makes those class
   headers the authoritative record of which reads escape and why; a stale one tells the next security review
   that an exemption exists which does not.
6. **Delete the counter-guard tiebreak with `TaskRollupService`.** It has no meaning once nothing writes the
   counters from Tasks. Leaving it behind would be a query on every recalc for a branch that can never be taken.
7. **The `(anti-fraud)` / `(CRITICAL)` subject markers become cosmetic only at M5.** Until then, cleaning them
   out of `Transaction_Task_Def__mdt.Subject__c` and re-running the loader silently zeroes `Wire_Open_Risks__c`
   for any deal still on the Task model. `TaskRollupService`'s header and `TaskRollupServiceTest`'s CMDT guard
   both say so; both go at M5, together.
8. **Also still open at M5, and not this phase's:** `Transaction_Task_Actions` / `TransactionActionPermissionService
   .assertTaskActionAccess` (GATE-B11), the `Transaction_Tasks_by_Group` Task list view, and the
   `ChecklistRollupService.RollupWrites` `without sharing` re-pricing (§7 above).

---

## 9. Files

**Changed (production behaviour):**
- `classes/TaskRollupService.cls` — the counter-guard tiebreak. **The one sanctioned change to the live stack.**
- `classes/TaskSelector.cls` — **additive**: `selectForChecklistMigration` + its entry in the SYSTEM_MODE mode
  inventory. 🔴 Shared with PM, Disposition and Broker Protection; no existing method touched.

**New:**
- `classes/ChecklistMigrationDomain.cls` — pure projection + comparison. Zero SOQL, zero DML.
- `classes/ChecklistMigrationService.cls` — migrate / rollback orchestration.
- `classes/ChecklistMigrationQueueable.cls` — the 25-deal chunk chain + `ChainFinalizer`.
- `classes/ChecklistMigrationAuditService.cls` — the M2 report.
- Four test classes + `TaskRollupDualModelGuardTest`.
- `scripts/migrate-transaction-checklists.apex`, `scripts/reconcile-checklist-migration.apex`,
  `scripts/rollback-transaction-checklist-migration.apex`.

**Specified, deliberately not applied:** the M3 flow repoint (§4) and the M4 `DPEG_Task_Edit` grant removal (§2).

**Not touched, as instructed:** `DPEG_Admin_Access`, `DPEG_Transaction_*`, `DPEG_Disposition_*`,
`TestDataFactory`, `TransactionSelector`, `TransactionSelectorTest`, `TransactionTriggerHandler`. Also left
alone because a concurrent session has uncommitted edits in them: `ChecklistSelector`, `ChecklistControllerTest`,
`ChecklistItemServiceTest`, `TaskRollupServiceTest`, `TransactionTrigger`.

---

## 10. Cross-phase items for the coordinator to route

### 10.1 🔴 C6 — the `ChecklistOutcomeService` seam. **Recommendation: a suppression flag, set by the migration.**

**The collision.** `ChecklistOutcomeService.applyForCompletedItems` keys on `isDone(item.Flag__c)` with no
transition test and has no production caller today; Phase 5 is wiring it into an after context. M1 step 2
inserts historically-completed items — 25 deals at a time — so on the day both ship, the migration
re-applies every historical outcome in bulk, including `CriticalDateService.ensureFor`, the exact call
`TransactionTriggerHandler` withholds pending GATE-B2/B4 because it can throw inside a trigger and roll
back the caller's save. `suppressTriggerRecalc` is the rollup arm only and does not cover it.

**Shape wanted: a static suppression flag on `ChecklistOutcomeService`**, mirroring
`ChecklistRollupService.suppressTriggerRecalc` / `OnboardingTaskRollupService` — a setter, a public
`is...Suppressed()` reader so `applyForCompletedItems` can early-return and a test can pin it, and the
established discipline of restoring the **prior** value in a `finally` rather than blindly clearing it.
Name it for the meaning, not the mechanism: `suppressOutcomeApplication`.

**Why not the transition gate as the mechanism — this is the decisive point, not a preference.**
A transition test needs `Trigger.oldMap`, and **there is no `oldMap` in an after-INSERT context.** The
gate would have to answer "is a row created already-done a transition?" with a single fixed answer, and
both answers are wrong for somebody: NO silently stops outcomes ever applying to a legitimate Data Loader
or API insert of a completed item; YES lets the migration re-apply everything. **The discriminator the
transition gate needs does not exist on the context that matters here.** A flag set by exactly one caller
does exist, and it is the only thing that can tell "the migration inserted this" apart from "someone
loaded a completed item".

**But Phase 5 should add the transition gate anyway, as an independent fix.** On the UPDATE context it is
both possible and needed: without it, any unrelated edit to an already-complete item (a comment, a due
date) re-applies its outcomes. That is a Phase 5 defect whether or not the migration ever runs. Two
controls, two different failure modes — the same belt-and-braces shape as the wire gate (trigger + VR).

**Both constraints are met.** (a) The migration never applies outcomes inline, so the approved
`scripts/backfill-checklist-outcomes.apex` stays the deliberate, post-M1 path — it simply runs without
the flag set. (b) It survives 25 deals of historically-completed items in one transaction because a
static boolean is O(1): checked **once, before any SOQL or DML, never inside a loop**, so the cost does
not grow with 25 × 82 items. A static also dies with the transaction, so a failed chunk cannot leave the
flag set for the next one.

**My side is one line.** `ChecklistMigrationService.persist` already brackets all four statements with the
rollup suppression and restores the prior value in a `finally`; the outcome flag goes in the same
brackets. I will add it the moment the seam exists.

🔴 **ORDERING GATE, and it runs the other way from the usual one:** until that seam ships, **M1 must not
be run in an org where `applyForCompletedItems` is wired into an after context.** Today it has no
production caller, so M1 is safe right now — the hazard arrives with Phase 5, not with Phase 4.

### 10.2 W3 — `ChecklistItemSelector` header text (Phase 5 owns the file; not edited here)

Three corrections to `selectByTransactionIds`:

1. **Consumer count.** It says "Two callers" and then names a third. There are now **three**:
   `ChecklistRollupService.recalc`, `ChecklistFanoutService.reconcile`, and
   `ChecklistMigrationAuditService.compare` (added 2026-09-02).
2. **The third caller does not fit the existing mode justification, and should not be filed under it.**
   The first two are platform-driven — a trigger and a Queueable. The audit is **operator-driven from an
   anonymous-Apex script**, which is closer to "a read the running user asked for". `SYSTEM_MODE` is
   still correct for it, but for a *different* reason worth stating on its own line: the read spans
   eleven Metadata-API-deployed custom fields, and under `USER_MODE` one missing FLS grant raises
   `System.QueryException: No such column` — which would abort the **reconciliation that gates cutover**
   and read as "the models disagree" rather than "you lack a grant". A wrong reason recorded in a header
   ARCHITECTURE §2 calls authoritative is worse than none.
3. **The `@return` inventory omits two fields the SELECT actually returns:** `Subject__c` and
   `Blocked_By__c`. `Blocked_By__c` is load-bearing downstream — `ChecklistMigrationDomain.viewOf` reads
   it to set `hasPrerequisiteLink`, which backs the `PREREQ_UNRESOLVED` check. A future narrowing of that
   SELECT, made in good faith against the stated inventory, would silently disarm that check.
