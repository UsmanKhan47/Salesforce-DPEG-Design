# Design — Day-0 rollup sharing fix (Task model + Checklist model)

**Date:** 2026-09-02
**Org:** `usman-dpeg` (EE, `IsSandbox=false`, API 67.0)
**Trigger:** measured production failure, `AsyncApexJob 707iw0000046Rh6AAE` (2026-09-02T11:22:47Z)
**Status:** DESIGN ONLY — nothing implemented. Two findings below **change the approved scope**
and need a decision before any agent writes code.

---

## 0. READ THIS FIRST — TWO FINDINGS THAT CHANGE THE APPROVED SCOPE

The brief approved four items. Verifying them against the repo produced two results that
contradict the brief's own premises. Both are stated up front because acting on the brief
literally would ship a change that **leaves production exactly as broken**.

### 🔴 FINDING A — Item 1 alone does not fix the outage. The failure moves ONE statement down.

`TaskFanoutService.fanOutNow` ends with **two** statements, in this order:

```apex
Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);   // the 82 Tasks
Database.update(toFlag,   true, AccessLevel.SYSTEM_MODE);   // Tasks_Fanned_Out__c + Tasks_Total__c
```

The `insert` fires `TaskRollupTrigger` after-insert **synchronously**, which is where the
measured throw happens today — so statement 2 is never reached. Fix `TaskRollupService` and
statement 1 completes… and then statement 2 runs: a `Transaction__c` **update**, performed by
Junior, against a deal owned by Danish, `MaxAccessLevel = 'Read'`. `SYSTEM_MODE` lifts CRUD/FLS
and never sharing, so it is refused, `allOrNone = true` aborts the Queueable execution, and
**all 82 Task inserts roll back again**. Same user-visible symptom, same empty LWC state, a
different `ExtendedStatus`.

`TaskRollupService`'s own header already names this failure pattern in the 2026-08-05 entry:
*"the repair stopped one statement short and the failure moved downstream."* This is the same
mistake, one iteration later.

⇒ **Item 1 must be extended to `TaskFanoutService.fanOutNow`'s `toFlag` update.** It is filed
below as **Item 1c** and it is not optional — without it the fix is unobservable in production.

### 🔴 FINDING B — Item 2's stated justification does not hold. The M3 blocker is a DIFFERENT class.

The brief says *"the new model carries the identical `with sharing` + `SYSTEM_MODE` shape on the
same chain, so a Phase 4 M3 cutover would fail identically."* The shape is identical. **The chain
is not.** Traced statement by statement:

| Statement | Reached on the Day-0 chain post-M3? | Fails for Junior? |
|---|---|---|
| `ChecklistFanoutService` PASS 1 — `insert Checklist__c` | ✅ yes | 🔴 **YES** — master-detail child insert needs EDIT on the master |
| PASS 2 — `insert Checklist_Item__c` | ✅ yes | 🔴 **YES** — same, two hops |
| PASS 3 — `update` prerequisite links | ✅ yes | 🔴 **YES** |
| PASS 4 — `update Transaction__c` (flag + 4 counters) | ✅ yes | 🔴 **YES** |
| `ChecklistRollupService.recalc` → `RollupWrites.commitRollups` | ❌ **NO — the rollup is SUPPRESSED across all four statements** (`ChecklistFanoutService.cls:296`, restored in a `finally`) | n/a |

`ChecklistRollupService` is **never reached on the Day-0 path**, so the Day-0 driver is not a
named caller for it. Its other two live callers still hold Edit sharing by construction:

* `ChecklistItemTrigger` — `writeRequiresMasterRead=false` on **both** links
  (`Checklist__c.Transaction__c`, `Checklist_Item__c.Checklist__c`, verified in the field XML) is
  the **stricter** setting: read **and write** on the master is required to edit the detail. A
  user who just saved an item provably holds Edit on the deal.
* `ChecklistFanoutService.reconcile` → its trailing explicit `recalc` (`cls:518`) fires from
  `TransactionTriggerHandler` only when `Loan_Required__c` changed — i.e. the principal just
  edited the deal.

⇒ **`ChecklistRollupService`'s own bar is NOT met.** Its header says: *"RESTORING IT IS A ONE-WORD
CHANGE BACK TO `without sharing`, AND IT MUST COME WITH A NAMED CALLER IN THIS BLOCK. Never flip
it back on a hypothetical."* Flipping it now, on the brief's premise, would be flipping it on a
hypothesis that this design has falsified — the exact thing the block forbids.

⇒ **Recommendation: re-scope Item 2 from `ChecklistRollupService` to `ChecklistFanoutService`.**
The latent M3 defect the brief is right to want fixed is real, is four statements wide, and lives
one class earlier. `ChecklistRollupService`'s block still gets rewritten — to record that the
Day-0 caller was **examined and does not reach this class**, with the suppression evidence and the
coupling ("if suppression is ever removed, re-open this"). That satisfies the brief's instruction
to update the block rather than leave it standing, without a dishonest keyword flip.

**DECISION REQUIRED (Gate 1):** approve Finding A (Item 1c) and Finding B (re-scope Item 2 →
Item 2′). If you would rather flip `ChecklistRollupService` anyway, say so and it will be written
with the caveat recorded — but it is not what the evidence supports.

---

## 1. ROOT CAUSE

**One sentence:** an ownership reassignment introduced on 2026-08-28 broke the premise of a
sharing decision made on 2026-08-05, so every write in the Day-0 chain is now performed by a
principal who has **Read** on the record and needs **Edit**, and `AccessLevel.SYSTEM_MODE` — which
the whole chain relies on — lifts CRUD/FLS and **never** sharing.

The full causal chain, all of it measured:

1. `ContractExecutionService.openTransactionsOnAboutToClose` inserts `Transaction__c` as the deal
   driver (Junior) and, at **`cls:359`**, sets `OwnerId = resolveTransactionOwnerId()` → Danish.
   The insert itself succeeds (a new row has no pre-existing sharing to be denied on) — proven by
   TXN-0284 existing.
2. Identity never changes downstream: `Transaction_Task_Fanout` declares no `runInMode`;
   `TaskFanoutService.fanOut` enqueues; **a Queueable runs as its enqueuer**. Everything from here
   runs as **Junior**.
3. `TaskFanoutService.fanOutNow` sets `tk.OwnerId = t.OwnerId` → all 82 Tasks are owned by
   **Danish**. The comment at `ContractExecutionService.cls:357` predicted this cascade and called
   it intended; nobody costed the sharing consequence.
4. The 82 `Task` inserts **succeed** (see §2.4 for the evidence).
5. `TaskRollupTrigger` after-insert → `TaskRollupService.recalc` →
   `Database.update(updates, true, AccessLevel.SYSTEM_MODE)` on a **Private-OWD** `Transaction__c`
   for which `UserRecordAccess` reports `HasEditAccess = false`, `MaxAccessLevel = 'Read'`.
   Refused. `allOrNone = true`. The throw escapes the after-insert trigger as
   `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back all 82 rows.

**Why Junior has Read and not Edit, from the repo rather than from the org:**
`DPEG_Transaction_View` grants `allowEdit=false`, `viewAllRecords=true`, `modifyAllRecords=false`
on `Transaction__c`. `viewAllRecords` is a record-level (sharing) grant, so it produces exactly
`HasReadAccess=true / HasEditAccess=false / MaxAccessLevel='Read'` — the measured triple. The only
Edit grants are ownership, `DPEG_Transaction_Edit`, and the `Transaction_Team_All_RW` criteria
rule sharing `Stage__c != ''` to `DPEG_Transactions_Team` at `accessLevel=Edit`. Junior holds none
of those for this record.

**Corollary that matters for the tests:** `MaxAccessLevel='Read'` also **proves Junior is not
above Danish in the role hierarchy**. `Acquisitions_Analyst` and `Transactions_Coordinator` are
siblings under `DPEG_Principal` (`roles/*.role-meta.xml`), and a hierarchy grant on a Private-OWD
custom object would have produced Edit, not Read. This is load-bearing for §3.

### The two falsified class headers

| Header | What it asserts | Why it is false |
|---|---|---|
| `TaskRollupService.cls:268-272` | *"ContractExecutionService inserts it WITHOUT setting OwnerId, so the owner defaults to the deal driver… the running user IS the owner"* | `ContractExecutionService.cls:354-360` **does** set `OwnerId`, added 2026-08-28, three weeks after this header was written. The same header's "RESIDUAL, KNOWN, NOT ADDRESSED HERE" paragraph describes today's default path. |
| `ChecklistRollupService.cls:324-325` | *"`ChecklistFanoutQueueable` — runs as its enqueuer, who created or edited the deal"* | The enqueuer **created** the deal but **cannot edit it**; "created or edited" conflates two different access facts. (This half is wrong even though, per Finding B, the class is still not reached on that path.) |

---

## 2. THE READ-VS-WRITE QUESTION, RESOLVED PER MODEL

The brief's central constraint: escalating only the write converts a loud failure into a silently
wrong dashboard. That is correct for one model and **not** correct for the other, and the
difference is structural rather than incidental. Both answers are derived below.

### 2.1 Task model — 🔴 THE READ IS FILTERED. READ AND WRITE MUST MOVE TOGETHER.

`TaskRollupService.recalc` performs **two** reads:

**Read 1 — the Task read.** `TaskSelector.selectByTransactionDealIds`, `WITH SYSTEM_MODE`, in a
`with sharing` class ⇒ **sharing-filtered**. And the filter bites completely:

* `Activity` is `sharingModel Private` (`objects/Activity/Activity.object-meta.xml`).
* **No `sharingRules/Activity*` or `sharingRules/Task*` file exists** (verified across all 198
  files in `sharingRules/`).
* Checklist Tasks attach via the custom `Transaction_Deal__c` lookup, **not `WhatId`**, so they
  inherit nothing from the parent record.
* No permission set anywhere in the repo grants `viewAllActivities` or `viewAllData`
  (grep across `permissionsets/` → zero matches).
* Junior is not above Danish in the role hierarchy (proved in §1).

⇒ Junior's Task read returns **ZERO rows**. This is not inferred — the repo already contains a
**passing test that asserts it**: `TaskSelectorTest.selectByTransactionDealIds_systemModeDoesNotBypassSharing_nonOwnerSeesNoRows`
(line 973), complete with a positive control.

⇒ Escalating only the write produces `Tasks_Complete__c = 0`, `Tasks_Overdue__c = 0`,
`Wire_Open_Risks__c = 0` — written **successfully**. Concretely: `Wire_Open_Risks__c` would read
**0 instead of 2** (B2 and I7 are the two open anti-fraud items on every deal), so the **Wire
Sentinel tile reports "no open wire risks" on a deal that has two** — which is RISK 1 of the
checklist rewrite, arriving by a different door. Strictly worse than today's loud failure.

⚠ Note the arithmetic makes this silent, not detectable: the counters map is seeded from `owned`
(`TaskRollupService.cls:203-207`), not from the query result, so a zero-row read still produces a
full `updates` list. There is no "nothing to write" short-circuit to save us.

**Read 2 — the dual-model guard read.** `TransactionSelector.selectForChecklistFanout`,
`SYSTEM_MODE`, `with sharing` ⇒ also filtered. For **Junior specifically** it is complete
(`viewAllRecords=true` returns every deal), so it is not part of the outage. But once the write is
escalated, the comment at `TaskRollupService.cls:178-182` becomes **void**: it treats an
unreadable deal as "still owned by the Task model" and justifies that by *"the subsequent write
then fails LOUDLY for that deal."* After Item 1 the write no longer fails, so a principal who
cannot read a **claimed** deal would silently miss the claim and let the Task model **overwrite
the Checklist model's counters** during the M1→M3 dual-model window. That is the exact race the
tiebreak exists to prevent.

⇒ **Item 1b** (below) escalates the guard read too, via its own dedicated selector method. It is
defensive rather than a live break (nobody today has Task-edit without deal-read), it costs zero
extra statements, and it is separable if you want to drop it.

### 2.2 Checklist model — ✅ THE READ NEEDS NO ESCALATION, AND THE REASON IS STRUCTURAL.

Asked and answered independently, as the brief requires. `ChecklistRollupService.recalc` reads
`ChecklistSelector.selectByTransactionIds` and `ChecklistItemSelector.selectByTransactionIds` —
both `SYSTEM_MODE` in `with sharing` classes, so both are sharing-filtered. That does **not**
produce the Task model's failure, for two independent reasons:

1. **`Checklist__c` and `Checklist_Item__c` are `sharingModel ControlledByParent`**, master-detail
   to `Transaction__c` (and to `Checklist__c`, which is itself master-detail to `Transaction__c`).
   Read on a detail row **is** read on its master, with no rule to maintain. There is no
   owner-based visibility to lose, because these objects **have no `OwnerId` at all**
   (`Checklist__c.object-meta.xml`, "ACCEPTED COSTS (a)"). Any principal who can read the
   `Transaction__c` reads **every** checklist and **every** item on it.
2. **The guard read already fails closed on this side.** `ChecklistRollupService.cls:225-229`
   skips any deal absent from `selectForChecklistFanout`'s map (`deal == null → continue`). So a
   principal who cannot read the deal writes **nothing** for it — no wrong number is possible.

⇒ The two cases are exhaustive: *readable deal* ⇒ complete item read via ControlledByParent;
*unreadable deal* ⇒ no write attempted. **There is no state in which the checklist rollup
publishes counters computed from a partial view.** This is the argument `TaskRollupService`'s
header demands be resolved, and on the checklist side it resolves in the read's favour.

⚠ Recorded so it is not lost: this rests on `ControlledByParent`, which is a schema property, not
on `viewAllRecords=true`, which is an assignment fact. Narrowing the permission sets cannot break
it. Adding a `Checklist_Item__c` read that does **not** traverse the master would.

### 2.3 `ChecklistFanoutService` — the writes ARE exposed (the brief asked; here is the answer)

All four of its `Database.*` statements run at `SYSTEM_MODE` in a `with sharing` class, and all
four need **Edit** sharing on the `Transaction__c`:

* PASS 1/2/3 write master-detail children. `writeRequiresMasterRead=false` on both links is the
  **stricter** setting — read **and write** on the master is required to create, edit or delete
  the detail. `ChecklistRollupService`'s 2026-09-02 correction and
  `ChecklistOutcomeService.cls:641-648` both state this correctly; the field XML confirms it.
* PASS 4 writes `Transaction__c` directly. Its comment at `cls:382-387` says *"The Day-0 path runs
  as the deal driver, who owns the Transaction they just created, so sharing is satisfied by
  ownership."* **That is the same falsified premise as `TaskRollupService`'s**, written 2026-08-31
  from the pre-2026-08-28 world.

⇒ Post-M3 the checklist Day-0 fan-out fails at **PASS 1**, before any of the rollup discussion
matters. Symptom identical to today: no checklists, no items, `Checklist_Fanned_Out__c` false, the
LWC showing its misleading empty state.

⚠ **Read completeness is NOT at risk here**: `ChecklistFanoutService` computes its counters from
the rows it just built in memory (`DealTally`), and its one read
(`selectForChecklistFanout`) is complete for any principal who can read the deal. So unlike the
Task model, escalating its **writes alone** is correct and cannot produce a wrong number.

### 2.4 Do the 82 `Task` inserts actually succeed? — ✅ YES, MEASURED

The `ExtendedStatus` reads `TaskRollupTrigger: execution of AfterInsert`. An **after**-insert
trigger only fires once the rows have been staged, so the insert reached completion. Supporting
facts: `Database.insert(..., AccessLevel.SYSTEM_MODE)` lifts the Task object CRUD that
`Minimum Access - Salesforce` withholds (`PermissionsEditTask = false`) and the
`Transaction_Deal__c` edit FLS Junior lacks; and an insert of a brand-new row has no pre-existing
record for sharing to deny. **No assumption required — the platform's own error string is the
proof.**

---

## 3. `OnboardingTaskRollupService` AUDIT (Item 4)

**Verdict: AFFECTED — and it is already in the WORSE of the two states, today, in production
code.** But the fix is the mirror image of Item 1.

| | Task/Transaction rollup | **Onboarding rollup** |
|---|---|---|
| Write | `with sharing` + `SYSTEM_MODE` → **fails loudly** | `private without sharing RollupWrites` (`cls:185`) → **always succeeds** |
| Read | `TaskSelector.selectByTransactionDealIds`, `with sharing` → filtered | `TaskSelector.selectByOnboardingIds`, `with sharing` → **filtered** |
| Net | loud rollback | 🔴 **silently wrong counters** |

The write was escalated on 2026-08-22 (correctly, and its header's reasoning is sound). The read
was left filtered. That is precisely the asymmetry the brief's constraint warns about — already
shipped, in the direction that produces wrong numbers rather than errors. `OnboardingTaskRollupService`
writes **twelve** counters including `Completion_Pct__c`, all read by `OnboardingController` and
the PM dashboards.

**Is it live?** Not on the ordinary path, and this is why it has not been noticed:
`OnboardingFanoutService` sets `tk.OwnerId = o.OwnerId` (`cls:287`), so every checklist Task is
owned by the Onboarding's owner, and the fan-out suppresses the trigger recalc and calls `recalc`
once itself. On the fan-out path owner == runner, so the read is complete. **There is no
`resolveTransactionOwnerId` equivalent on the PM side** — nothing reassigns `Onboarding__c.OwnerId`
away from its creator — which is exactly the property that has been quietly protecting it, and
exactly the property that changed on the Transaction side.

**It is reachable, though**, because `TaskRollupTriggerHandler` routes `Onboarding__c` on all four
after-contexts (2026-08-22 change) — any principal who can edit **one** onboarding Task while not
owning the rest recomputes all twelve counters from a partial view and writes them successfully.
`Onboarding__c` is Private OWD with `Onboarding_PM_All_RW` (Edit) to `DPEG_Property_Mgmt_Team`, so
a PM-group member has Edit on **every** Onboarding while seeing **only their own** Tasks
(`Activity` Private, no sharing rules). An individually-reassigned Task, an admin-created Task, or
an ownership change on the parent puts them in that state.

⇒ **INCLUDE IT** — as **Item 4′**: escalate the **read** so it matches the already-escalated
write. Do **not** touch `RollupWrites`. The repo already contains the test that will need
inverting: `TaskSelectorTest.selectByOnboardingIds_systemModeDoesNotBypassSharing_nonOwnerSeesNoRows`
(line 1009).

---

## 4. THE CHANGE SET

All escalations follow ARCHITECTURE.md §2's prescribed shape — **a narrow `private without
sharing` inner class holding only the one statement, never `without sharing` on a whole class** —
and the repo's own live precedents: `TransactionSelector.DealCloseGateReads`,
`OnboardingTaskRollupService.RollupWrites`, `OpportunitySelector.NdaGateReads`.

Every enclosing class stays `with sharing`. Every escalation is justified **at its own
declaration**, naming this incident and its `AsyncApexJob` id.

### Item 1a — `TaskSelector` : escalate the rollup Task READ

* New `private without sharing class RollupReads` holding **only** the
  `selectByTransactionDealIds` query. Public method keeps its signature and delegates.
* `selectByTransactionDealIds` has exactly **one** caller (`TaskRollupService.cls:213`) — verified
  by repo-wide grep — so no other consumer inherits the escape.
* Mode is unchanged (`WITH SYSTEM_MODE`); sharing is the separate, separately-justified decision.
* Update the class-header **MODE INVENTORY** and add a **SHARING INVENTORY** entry. The header's
  current blanket claim *"this class stays `with sharing`, so every SYSTEM_MODE method still
  returns only rows the running user can already see"* becomes false and must be corrected in the
  same change — ARCHITECTURE §2 makes these headers the authoritative inventory, and a stale one
  tells the next security review that no exemption exists.
* ⚠ Do **not** add a second method to `RollupReads` later — the `DealCloseGateReads` header's rule.

### Item 1b — `TransactionSelector` : escalate the dual-model GUARD read (defensive; separable)

* New method `selectClaimFlagsForTaskRollup(Set<Id>)` — `Id, Checklist_Fanned_Out__c` only —
  routed through a **new** `private without sharing class TaskRollupGuardReads`.
* **A new method, not a reuse of `selectForChecklistFanout`**, because that method is shared with
  `ChecklistFanoutService` and `ChecklistRollupService`, both of which **depend on the filter**
  (§2.2 reason 2). Escalating it in place would break the checklist model's fail-closed property.
* `TaskRollupService.cls:183` repoints to the new method. One query replaces one query.
* Also rewrite the `cls:178-182` comment, whose stated justification ("the write fails loudly")
  Item 1c removes.
* **Drop this item if you want the minimum change** — it is a latent inversion, not the outage.

### Item 1c — `TaskFanoutService.fanOutNow` : escalate the `toFlag` write 🔴 REQUIRED (Finding A)

* Wrap **only** `Database.update(toFlag, true, AccessLevel.SYSTEM_MODE)` in a
  `private without sharing class FanoutFlagWrites`.
* **Leave `Database.insert(toInsert, ...)` alone** — an insert of new rows needs no sharing escape,
  and narrowing the escalation to the statement that needs it is the whole discipline.
* Update the header block at `cls:223-234`, which currently reasons only about CRUD.

### Item 1d — `TaskRollupService` : escalate the counter WRITE + correct the header

* Wrap `Database.update(updates, true, AccessLevel.SYSTEM_MODE)` in a
  `private without sharing class RollupWrites` (shape mirrors `OnboardingTaskRollupService`).
* `allOrNone = true` stays. No behaviour change other than sharing.
* Header rewrite, explicitly:
  * **Strike** the falsified premise at `cls:268-272` — quote it, date it, say what falsified it
    (`ContractExecutionService.cls:359`, 2026-08-28) rather than deleting it silently.
  * **Promote** the "RESIDUAL, KNOWN, NOT ADDRESSED HERE" paragraph: it is no longer residual, it
    is the default Day-0 path, and it is now addressed.
  * **Resolve** the read-side counter-argument at `cls:273-278` — it correctly refused a write-only
    escalation; record that the objection was upheld and satisfied by moving the read (Item 1a) in
    the same change, and that a future write-only escalation is still refused.
  * Name the evidence: `AsyncApexJob 707iw0000046Rh6AAE`, deal `a0Riw000000Ao3ZEAS`, user
    `005iw000000AJhJAAW`, `UserRecordAccess` triple, and the 2026-09-01 recurrence
    (`707iw000003vC8LAAU`).

### Item 2′ — `ChecklistFanoutService` : escalate the four fan-out WRITES (re-scoped, Finding B)

* One `private without sharing class FanoutWrites` exposing the four statements
  (PASS 1 insert, PASS 2 insert, PASS 3 update, PASS 4 update) — or two if you prefer one per
  concern. **No reads move** (§2.3).
* Correct the PASS 4 comment at `cls:382-387` — its ownership premise is the same falsified one.
* Correct the PASS 1 comment at `cls:306-308`, which says *"a master-detail child insert needs no
  sharing beyond its parent"*: true as far as it goes, but the parent requirement is **Edit**, not
  Read, and the sentence reads as reassurance.

### Item 2″ — `ChecklistRollupService` : REWRITE the block, do NOT flip the keyword

The brief instructs that the "RESOLVED — THE ESCALATION IS REMOVED" block be rewritten rather than
left standing. It gets rewritten — to record a **negative** result, which is the honest one:

* State that the Day-0 driver **was** examined against this class on 2026-09-02 with the measured
  incident in hand, and does **not** reach it, because `ChecklistFanoutService` suppresses the
  rollup across all four of its statements and writes the counters itself.
* State that the sibling `TaskRollupService` **did** need the escalation, so this is a proven
  distinction rather than an untested claim.
* State the coupling explicitly: **if `ChecklistFanoutService`'s suppression is ever removed, or a
  Schedulable/batch caller appears, this block must be re-opened.** That is the named-caller trip
  wire the block asks for, made concrete.
* Correct the `cls:324-325` bullet: *"runs as its enqueuer, who created or edited the deal"* →
  the enqueuer created the deal and **cannot edit it**; the bullet's conclusion survives only
  because of suppression, not because of access.
* Keep `RollupWrites` `with sharing`, keep the inner class (as its own note already argues).

### Item 4′ — `TaskSelector.selectByOnboardingIds` : escalate the onboarding rollup READ

* Second, **separate**, `private without sharing class OnboardingRollupReads`. Not a second method
  on `RollupReads` — different question, different principal, different evidence.
* Single caller (`OnboardingTaskRollupService.cls:139`) — verified by grep.
* `OnboardingTaskRollupService.RollupWrites` is **unchanged**; its header gains a paragraph
  recording that the read half was closed on 2026-09-02 and why the pair only makes sense together.

### Explicitly NOT changed

`ContractExecutionService.resolveTransactionOwnerId` and `cls:359`; `TaskFanoutService`'s
`tk.OwnerId = t.OwnerId`; `CriticalDateService` and the `TransactionTriggerHandler` arm;
`ChecklistOutcomeService.commitDealWrites` (its refusal to copy the escalation is correct on the
completion path); any permission set, sharing rule or OWD; any LWC.

---

## 5. GOVERNOR RE-DERIVATION — ZERO DELTA

**Nothing in this design adds a query or a DML statement.** An inner-class instance method call is
not a query; wrapping an existing statement changes its access level, not its cost. Item 1b
substitutes one query for one query.

### `TaskRollupService.recalc` — per invocation

| | today | after |
|---|---|---|
| SOQL | 2 (guard read + Task read) | **2** (guard read via new method + Task read via `RollupReads`) |
| DML | 1 | **1** |
| Fully-migrated deal (guard short-circuits) | 1 SOQL / 0 DML | **1 / 0** |

### Day-0 cascade — the binding path

```
TaskFanoutQueueable.CHUNK_SIZE = 100  x  82 Tasks   =  8,200 rows in ONE Database.insert
after-insert fires in 200-row batches: ceil(8200/200) =  41 firings
    SOQL : 41 firings x 2 per recalc  =  82        (async limit 200)  -> 41%
    DML  : 41 firings x 1 per recalc  =  41        (async limit 150)  -> 27%
  + Item 1c's toFlag update            =   1 DML   -> 42 total        -> 28%
    DML rows: 8,200 + 100             =  8,300     (limit 10,000)     -> 83%
```

Identical to the figures in `TaskRollupService`'s header. The 41%/27% budget is preserved to the
statement. Item 1c's `toFlag` update is **not new** — it already exists in `fanOutNow` and is
already counted; it is simply unreachable today.

**Pinned by:** `TaskRollupDualModelGuardTest.shouldStayConstantCost_WhenBulkTasksCrossTheChunkBoundary`
asserts `TaskRollupService.lastRunQueryCount == 2`. That assertion must **still read 2** after this
change — it is the guard against an escalation being implemented as an extra query rather than a
wrapped one. ⚠ It is captured **inside** `recalc` for the reason the field's own Javadoc gives:
`Test.stopTest()` restores the pre-test governor counters, so an assertion after it passes
vacuously.

### Other classes

| Class | today | after |
|---|---|---|
| `ChecklistRollupService.recalc` | 3 SOQL / ≤2 DML | unchanged (no code change) |
| `ChecklistRollupService.recalcForChecklistIds` | 4 SOQL | unchanged |
| `ChecklistFanoutService.fanOutNow` (chunk 50) | 2 SOQL / 4 DML / 4,800 rows | **unchanged** — wrapping DML adds nothing. Pinned by `ChecklistFanoutServiceTest.staysWithinBudgetAtTheChunkBoundary` |
| `OnboardingTaskRollupService.recalc` | 1 SOQL / 1 DML | unchanged |

---

## 6. TEST PLAN

### 6.1 The non-owner negative control — `TaskRollupServiceTest` (Item 3, primary)

The existing regression pins in this class use the **"persona edits a standard field on its own
Task"** harness (documented at `cls:181-199`), which was correct for the FLS incident but
**cannot reproduce this one**: it requires the persona to own the Task, and non-ownership is the
whole defect.

**Reproduce the production shape exactly instead:**

```
driverUser  : Standard User profile (the least-privileged profile in this org that can touch Task),
              + DPEG_Transaction_View  (allowEdit=false, viewAllRecords=true)  -> Read on the deal
ownerUser   : separate user, no relationship to driverUser in the role hierarchy
deal        : Transaction__c, OwnerId = ownerUser.Id          (built in the default admin context)
              -> assert UserRecordAccess for driverUser is Read, EDIT FALSE, as a fixture guard
tasks       : Transaction_Deal__c = deal.Id, OwnerId = ownerUser.Id
              5 closed, 3 open-and-past-due, 2 open anti-fraud wire items   (10 rows)

System.runAs(driverUser) {
    Database.insert(tasks, true, AccessLevel.SYSTEM_MODE);   // exactly what TaskFanoutService does
}
```

**Assertions — all three counters correct AND NON-ZERO. "No exception" is not sufficient and the
assertion messages must say why:**

| Field | Expected | What a wrong value proves |
|---|---|---|
| `Tasks_Complete__c` | **5** | `0` ⇒ the write was escalated and the **read was not** |
| `Tasks_Overdue__c` | **3** | `0` ⇒ same |
| `Wire_Open_Risks__c` | **2** | `0` ⇒ same — and this is the Wire Sentinel tile reading "no open wire risks" on a deal with two |
| `Tasks_Fanned_Out__c` | **true** | `false` ⇒ Item 1c missing (Finding A) |

🔴 **A fixture guard is mandatory.** Assert `Tasks_Complete__c == 5` **before** trusting any
"no exception" result, and add a positive-control method in which `driverUser == ownerUser` and
the same numbers come out. Without the control, a fixture that created zero Tasks would pass a
"no exception" test and pass a `0 == 0` test.

**How it is proven to fail without the fix** — three independent, stated in the class header so
review does not have to re-derive them:

1. **Revert `TaskRollupService.RollupWrites` to `with sharing`** ⇒ the `Database.insert` above
   throws `System.DmlException: CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY, TaskRollupTrigger: execution
   of AfterInsert … INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY`. No `try/catch` — that failure
   **is** the pin, exactly as the 2026-08-05 pins are written.
2. **Revert `TaskSelector.RollupReads` to `with sharing` but keep the write escalated** ⇒ the
   insert **succeeds** and the three counters read `0 / 0 / 0`. This is the discriminator the whole
   design turns on, and it is the one a "no exception" test would miss.
3. **Revert `TaskFanoutService.FanoutFlagWrites`** ⇒ tested separately in §6.2.

### 6.2 The Day-0 end-to-end control — `TaskFanoutServiceTest` (Finding A)

Same two-user fixture; call `TaskFanoutService.fanOutNow(new List<Id>{ deal.Id })` inside
`System.runAs(driverUser)`. Assert 82 Tasks exist **and** `Tasks_Fanned_Out__c == true` **and**
`Tasks_Total__c == 82`. Reverting `FanoutFlagWrites` alone must turn this red — that is the proof
Finding A is real rather than theoretical.

### 6.3 Bulk — 251, at the chunk boundary, non-owner

`.claude/rules/bulk-test-rule.md` applies with no exemption (a real trigger, a real loop). Mirror
`TaskRollupDualModelGuardTest.shouldStayConstantCost_WhenBulkTasksCrossTheChunkBoundary`:
**251 Tasks on 2 deals**, both owned by `ownerUser`, inserted in one statement by `driverUser`,
forcing a second after-insert batch chunk. Assert the split counts (e.g. 126 / 125) **and**:

```apex
Assert.areEqual(2, TaskRollupService.lastRunQueryCount, ...);   // captured INSIDE recalc
Assert.areEqual(1, TaskRollupService.lastRunDmlCount,   ...);
```

⚠ 251 **Tasks on 2 deals**, never 251 deals — 251 × 82 = 20,582 rows against the 10,000-row limit,
which `TestDataFactory.createChecklistTasks` already documents as an overflow. Record that
reasoning in the test header so review does not demand the impossible version.

### 6.4 Inverting the two existing sharing pins — 🔴 DO NOT LET THESE GO RED SILENTLY

| Test | Today | After |
|---|---|---|
| `TaskSelectorTest.selectByTransactionDealIds_systemModeDoesNotBypassSharing_nonOwnerSeesNoRows` (line 973) | asserts outsider sees **0** rows | **inverts** — rename to `..._rollupReadEscapesSharing_nonOwnerSeesAllRows`, assert **1**, keep the positive control, and rewrite the Javadoc to explain the escape and cite this incident |
| `TaskSelectorTest.selectByOnboardingIds_systemModeDoesNotBypassSharing_nonOwnerSeesNoRows` (line 1009) | asserts outsider sees **0** rows | **inverts** for the same reason (Item 4′) |

🔴 **Both of these currently pin a PLATFORM FACT** ("`SYSTEM_MODE` never bypasses sharing") that
must not stop being pinned just because two methods now opt out of it. **Add a replacement pin on
a method that is still filtered** — recommended: `TaskSelector.selectForChecklistMigration`, whose
own Javadoc explicitly depends on the filter (`ChecklistMigrationService` diffs requested ids
against returned ids and reports the difference as `NOT_VISIBLE`). Same non-owner + positive
control shape, asserting **0** rows.

### 6.5 `OnboardingTaskRollupServiceTest` (Item 4′)

Non-owner control: `Onboarding__c` owned by `ownerUser`, checklist Tasks owned by `ownerUser`,
recompute driven by `driverUser` (in `DPEG_Property_Mgmt_Team`, so Edit on the parent via
`Onboarding_PM_All_RW`, but no visibility of the Tasks). Assert **`Tasks_Total__c` and
`Completion_Pct__c` are the FULL, NON-ZERO values**. Before Item 4′ this test writes
`0 total / 0% complete` **successfully and silently** — that is the demonstration that the
already-escalated write plus the filtered read is the worse state.

### 6.6 `ChecklistFanoutServiceTest` (Item 2′)

Non-owner control: deal owned by `ownerUser`, `fanOutNow` run as `driverUser` (Read only). Assert
11 `Checklist__c` + 82 `Checklist_Item__c` created, `Checklist_Fanned_Out__c == true`, and the
four counters non-zero where expected (`Tasks_Total__c == 82`, `Wire_Open_Risks__c == 2`).
Reverting `FanoutWrites` must fail at **PASS 1** with
`INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY` — that failure is the proof that the M3 blocker is
where Finding B says it is, and not in `ChecklistRollupService`.

⚠ `.claude/rules/content-publication-rule.md` does not apply (no `ContentVersion`/`ContentNote`).
⚠ Keep the existing `staysWithinBudgetAtTheChunkBoundary` assertions unchanged and green.

### 6.7 Regression surface to name explicitly in any deploy payload

`TaskRollupServiceTest`, `TaskRollupDualModelGuardTest`, `TaskSelectorTest`,
`TaskFanoutServiceTest`, `TaskRollupTriggerHandlerTest`, `OnboardingTaskRollupServiceTest`,
`OnboardingFanoutServiceTest`, `ChecklistFanoutServiceTest`, **`ChecklistRollupServiceTest`**,
`ChecklistMigrationServiceTest`, `ChecklistOutcomeServiceTest`, `TransactionSelectorTest`.

🔴 `ChecklistRollupServiceTest` **must be named explicitly** — that class's own header records
(2026-09-02) that the rollup is suppressed on both paths the payload's other tests exercise, so
incidental coverage for it is close to nothing with zero errors reported.
⚠ Also relevant: a dry-run skips byte-identical components as `Unchanged`, so a comment-only
header edit does not force revalidation.

---

## 7. DEFERRED — the `Transaction__c` queue swap

**Proposed by the user; analysed; rejected as a fix for this defect; retained as a separate,
later change.**

Making `Transaction__c.OwnerId` a Transactions **queue** would not fix this. Queue ownership grants
record access to queue **members**, and the running user in the failure is **Junior**, who is an
acquisitions persona and would not be a member. `UserRecordAccess` for Junior would still return
`MaxAccessLevel = 'Read'`, the `Database.update` would still be refused, and the identical failure
would recur with an owner that merely looks more institutional.

It remains worth doing on its own merits, and the ground is already prepared:
`ContractExecutionService.resolveTransactionOwnerId`'s header records it as the intended direction
and confines the entire swap surface to that one method (`Transaction__c.OwnerId` accepts a Group
Id exactly as it accepts a User Id). Neither the queue nor its membership exists yet (verified
2026-08-28: the org has only `Acquisition` and `Broker_Portal_Leads`, neither supporting
`Transaction__c`, both empty).

**Sequence it AFTER the checklist works**, so one change cannot mask the other: if both shipped
together and the fan-out then worked, nobody could say which change fixed it — and if it still
failed, the sharing fix would be wrongly suspected. ⚠ When it is scoped, note that public-group
and queue **membership is not deployable metadata**, so an empty queue is indistinguishable in the
repo from a populated one.

---

## 8. WHAT WAS ASSUMED RATHER THAN VERIFIED

Stated plainly, as instructed. Everything not listed here was read out of the repo or is quoted
from the brief's measurements.

1. 🟡 **Which permission sets Junior actually holds.** Inferred: the measured triple
   (`HasRead=true`, `HasEdit=false`, `MaxAccessLevel='Read'`) is exactly what
   `DPEG_Transaction_View`'s `allowEdit=false` + `viewAllRecords=true` produces, and no other
   grant in the repo produces it. Not read from `PermissionSetAssignment`. **Probe:**
   `SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE AssigneeId = '005iw000000AJhJAAW'`.
   Does not change any conclusion — the `UserRecordAccess` measurement is authoritative on its own.
2. 🟡 **That `viewAllRecords` on `Transaction__c` propagates read to `ControlledByParent` details.**
   This is standard platform behaviour (a detail's access is derived from its master's) and it is
   the explicit premise of `Checklist__c.object-meta.xml`'s "VISIBILITY IS NOT REDUCED VS THE TASKS
   THIS REPLACES" paragraph — but that paragraph itself says the question "could not be measured
   (no org access this session)". **Probe:** `UserRecordAccess` for Junior against a `Checklist__c`
   and a `Checklist_Item__c` on a deal he does not own. **This is the one assumption §2.2's
   conclusion rests on** — if it is false, the checklist model needs a read escalation too.
3. 🟡 **That `AccessLevel.SYSTEM_MODE` on the test's `Database.insert` lifts the profile-level
   `PermissionsEditTask` boolean.** Task CRUD is not permission-set-grantable in this org
   (`TaskRollupServiceTest.cls:152-170`: zero `ObjectPermissions` rows exist for Task/Event
   anywhere), so the test harness depends on this. Production evidently does it — the 82 inserts
   succeed as Junior — but the developer should confirm the harness compiles and runs rather than
   discovering it at deploy.
4. 🟡 **That the group `DPEG_Transactions_Team` has members.** Group membership is not deployable,
   so the repo cannot say. Irrelevant to the fix (Danish holds Edit by **ownership**, not by the
   rule), but it means the `Transaction_Team_All_RW` rule's real effect cannot be verified from
   source. Do not build any test on it.
5. 🟡 **`ChecklistMigrationService` (Phase 4 M1) was NOT audited** — it is outside the four
   approved items. It performs its own DML on `Transaction__c` and on the master-detail chain and
   is therefore likely to carry the same exposure. **Flagged for a follow-on pass**, not designed
   here.
6. 🟢 **Not an assumption, stated because it looks like one:** the claim that Junior reads zero
   Task rows is not inferred — `TaskSelectorTest` line 973 is a passing test that asserts exactly
   that shape, and the role-sibling fact plus the `MaxAccessLevel='Read'` measurement close the
   hierarchy escape route.

---

## 9. WORK SPLIT

### 🔵 ADMIN WORK (`salesforce-admin`)

**None.** No object, field, permission set, sharing rule, OWD, layout, flow or report changes.
Widening `Transaction__c` sharing is explicitly out of scope; Junior stays view-only on checklists.

Two **read-only** org probes (§8 items 1 and 2) are useful confirmations and belong to
`salesforce-devops`, not to admin — they change nothing.

### 🟢 DEVELOPER WORK (`salesforce-developer`)

All of it. Apex only, six classes plus tests. Standard service/selector work against an
established in-repo pattern — **not** integration, LDV or architectural, so
`salesforce-developer` rather than `salesforce-technical-architect`.

---

## 10. PROMPTS FOR SPECIALIST AGENTS

### 🔵 PROMPT FOR `salesforce-admin`

```
No admin work is required for this change. Do not create or modify any object, field,
permission set, sharing rule, OWD setting, page layout, flow or report.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Fix a measured production sharing failure in the Day-0 transaction checklist fan-out
(AsyncApexJob 707iw0000046Rh6AAE, 2026-09-02, deal a0Riw000000Ao3ZEAS, running user
005iw000000AJhJAAW). Read agent-output/design-rollup-sharing-fix.md in full first —
especially section 0 (two findings that change the scope) and section 2 (the read-vs-write
resolution). Do not deploy; create source only.

ROOT CAUSE: ContractExecutionService.cls:359 reassigns Transaction__c.OwnerId to Danish,
but the whole downstream chain still runs as the deal driver, who has Read and not Edit on
that record. AccessLevel.SYSTEM_MODE lifts CRUD/FLS and NEVER sharing.

Every escalation below uses ARCHITECTURE.md §2's prescribed shape: a narrow
`private without sharing` INNER CLASS holding only the one statement, justified at its own
declaration, with the enclosing class staying `with sharing`. Follow the live in-repo
precedents TransactionSelector.DealCloseGateReads and OnboardingTaskRollupService.RollupWrites.
Never put `without sharing` on a whole class. Never add a second method to an existing
escalation inner class — each escape gets its own class and its own justification.

1a. TaskSelector — wrap ONLY the selectByTransactionDealIds query in a new
    `private without sharing class RollupReads`. Keep the public signature and WITH SYSTEM_MODE.
    Update the class header's MODE INVENTORY and correct its now-false blanket statement that
    every SYSTEM_MODE method here still returns only rows the running user can see.

1b. TransactionSelector — add selectClaimFlagsForTaskRollup(Set<Id>) selecting only
    Id + Checklist_Fanned_Out__c, WITH SYSTEM_MODE, routed through a NEW
    `private without sharing class TaskRollupGuardReads`. Do NOT escalate
    selectForChecklistFanout in place — ChecklistFanoutService and ChecklistRollupService
    both depend on its sharing filter. Repoint TaskRollupService.cls:183 to the new method
    and rewrite the cls:178-182 comment, whose justification ("the write then fails loudly")
    item 1d removes.

1c. TaskFanoutService.fanOutNow — wrap ONLY `Database.update(toFlag, ...)` in a
    `private without sharing class FanoutFlagWrites`. Leave the Task insert alone (a new-row
    insert needs no sharing escape). Update the cls:223-234 header block, which reasons only
    about CRUD. THIS ITEM IS NOT OPTIONAL: without it the fix simply moves the failure one
    statement down and production stays broken.

1d. TaskRollupService — wrap `Database.update(updates, true, AccessLevel.SYSTEM_MODE)` in a
    `private without sharing class RollupWrites`; keep allOrNone = true. Rewrite the class
    header: strike the falsified premise at cls:268-272 by QUOTING it and naming what
    falsified it (ContractExecutionService.cls:359, 2026-08-28) rather than deleting it;
    promote the "RESIDUAL, KNOWN, NOT ADDRESSED HERE" paragraph to "was residual, is now the
    default Day-0 path, and is addressed here"; and resolve the read-side counter-argument at
    cls:273-278 by recording that its objection was UPHELD and satisfied by moving the read in
    item 1a — a write-only escalation is still refused.

2'. ChecklistFanoutService — wrap the four DML statements (PASS 1 insert, PASS 2 insert,
    PASS 3 update, PASS 4 update) in a `private without sharing class FanoutWrites`. Move NO
    reads. Correct the PASS 4 comment at cls:382-387 (same falsified ownership premise) and
    the PASS 1 comment at cls:306-308 (a master-detail child insert needs EDIT on the parent,
    not Read).

2". ChecklistRollupService — DO NOT change the sharing keyword. Rewrite the
    "RESOLVED - THE ESCALATION IS REMOVED" block (~lines 305-360) to record a NEGATIVE result:
    the Day-0 driver was examined against this class with the measured incident in hand and
    does not reach it, because ChecklistFanoutService suppresses the rollup across all four of
    its statements (cls:296) and writes the counters itself; the sibling TaskRollupService DID
    need the escalation, so this is a proven distinction, not an untested claim; and state the
    trip wire — if that suppression is removed, or a Schedulable/batch caller appears, this
    block must be re-opened. Correct the cls:324-325 bullet: the enqueuer created the deal and
    CANNOT edit it.

4'. TaskSelector — wrap the selectByOnboardingIds query in a SECOND, separate
    `private without sharing class OnboardingRollupReads`. Its write half
    (OnboardingTaskRollupService.RollupWrites) is ALREADY `without sharing`; leave it alone.
    Add a paragraph to OnboardingTaskRollupService's header recording that the read half was
    closed on 2026-09-02 and that the pair only makes sense together.

DO NOT CHANGE: ContractExecutionService (any line), TaskFanoutService's
`tk.OwnerId = t.OwnerId`, CriticalDateService or its trigger arm,
ChecklistOutcomeService.commitDealWrites, any permission set, sharing rule, OWD or LWC.

GOVERNOR CONSTRAINT — ZERO DELTA IS MANDATORY. Wrap existing statements; do not add a query
or a DML statement. TaskRollupService.recalc must stay at 2 SOQL / 1 DML per invocation, so
the Day-0 cascade stays at 41 firings x 2 = 82 SOQL and 41 DML against async limits of 200
and 150. TaskRollupDualModelGuardTest's `Assert.areEqual(2, TaskRollupService.lastRunQueryCount)`
must still read 2 — it is the guard against an escalation implemented as an extra query.
ChecklistFanoutService must stay at 2 SOQL / 4 DML per chunk of 50.

TESTS — the non-owner negative control is the point of the change, and "it did not throw" is
NOT sufficient:
  * Build driver != owner: the deal AND its Tasks owned by ownerUser; driverUser on the
    Standard User profile with DPEG_Transaction_View (Read, no Edit). Assert the
    UserRecordAccess fixture guard (HasEditAccess = false) before anything else.
  * Reproduce production exactly: inside System.runAs(driverUser), call
    `Database.insert(tasks, true, AccessLevel.SYSTEM_MODE)` — the existing "persona edits its
    own Task" harness at TaskRollupServiceTest.cls:181-199 CANNOT reproduce this defect,
    because it requires the persona to own the Task.
  * Assert all three counters are CORRECT AND NON-ZERO (e.g. 5 complete / 3 overdue /
    2 wire-open from a 10-row fixture). A write-only escalation yields 0/0/0 and must go red.
    Include a positive control (driver == owner) so a broken fixture cannot pass as 0 == 0.
  * Assert Tasks_Fanned_Out__c == true and Tasks_Total__c == 82 in a fanOutNow end-to-end
    test — that is what proves item 1c.
  * Bulk per .claude/rules/bulk-test-rule.md: 251 Tasks on TWO deals in one statement (never
    251 deals — 251 x 82 = 20,582 rows blows the 10,000-row limit), crossing the 200-row
    chunk boundary, with lastRunQueryCount/lastRunDmlCount asserted INSIDE the async context
    (Test.stopTest() restores the pre-test counters).
  * INVERT the two existing sharing pins that this change contradicts:
    TaskSelectorTest.selectByTransactionDealIds_systemModeDoesNotBypassSharing_nonOwnerSeesNoRows
    (line 973) and ..._selectByOnboardingIds_... (line 1009). Rename them, assert the escape,
    keep the positive controls, rewrite the Javadocs. Then ADD a replacement pin of the
    platform fact on a method that is STILL filtered — use selectForChecklistMigration, whose
    Javadoc depends on the filter for its NOT_VISIBLE reporting.
  * OnboardingTaskRollupServiceTest: non-owner control asserting Tasks_Total__c and
    Completion_Pct__c are full and non-zero (today it writes 0 / 0% silently).
  * ChecklistFanoutServiceTest: non-owner control asserting 11 checklists + 82 items +
    Checklist_Fanned_Out__c true; reverting FanoutWrites must fail at PASS 1 with
    INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY.
  * In each new test's header, record HOW it fails without the fix (which keyword to revert
    and what error/number results), so review does not have to re-derive it.

Any payload carrying these classes must name ChecklistRollupServiceTest explicitly — that
class's own header records that incidental coverage for it is close to nothing.
```
