# BOV Auto-Selection & Preferred Brokers — Design

**Date:** 2026-08-24
**Author:** Salesforce Design Agent
**Org:** `usman-dpeg` — 🔴 **PRODUCTION**
**Branch:** `feature/disposition-redesign`
**Status:** Plan only. No implementation metadata or code written by this agent.

**Verification basis:** every claim is grounded in a file read in this session, path quoted.
🔴 **This agent has no org access and no `salesforce-api-context` MCP** (`.mcp.json` declares only the
`salesforce` server, and subagents get no MCP tools). Nothing here is backed by a live describe or a
dry-run. Everything I could not resolve from the file system is in [§11 Gates](#11-gates--must-be-resolved-before-build).

---

## 0. Read this first — six findings that contradict or complete the brief

| # | Finding | Where |
|---|---|---|
| **F-1** | 🔴 **The BOV exclusivity guard already exists — and it will REFUSE naive auto-selection.** The brief asks "does an equivalent guard exist [for BOVs] or is one needed". `BovSubmissionSelectionGuardService` was built 2026-08-20, is wired at `beforeInsert` **and** `beforeUpdate`, and refuses any save leaving two `Selected` rows. A before-context auto-selection that promotes a new row **cannot demote the committed incumbent in the same statement** (the incumbent is not in `Trigger.new` on an insert), so the guard sees `others = 1` and **rejects the user's own insert**. This single fact determines the whole architecture. | [§3.2](#32-hard-problem-2--exclusivity-under-bulk) |
| **F-2** | 🔴 **`bovComparisonMatrix` is NOT a FlexiPage component.** `bovComparisonMatrix.js-meta.xml` is 5 lines: `apiVersion 67.0`, `isExposed=false`, **no `targetConfigs` at all**. It is rendered as a child of `dispositionMain.html` line 9 under `if:true={isBovOutreach}`. The brief's "`targetConfig` property or a wrapper?" is a false dichotomy — **neither**. The answer is a plain `@api` property and a second `<c-bov-comparison-matrix>` tag in `dispositionMain.html`. | [§3.6](#36-hard-problem-6--the-second-matrix-instance) |
| **F-3** | 🔴 **"Broker Activity Timeline" is `lwc/dispositionBuyerTimeline`, a SIDEBAR FlexiPage card — it is not inside, above, or below the matrix today.** `dispositionBuyerTimeline.js-meta.xml:5` `<masterLabel>Broker Activity Timeline</masterLabel>`; its `itemInstance` is in the `sidebar` region of `Disposition_Record_Page.flexipage-meta.xml` (~line 1204). **"We will not show Broker Activity timeline here" is already true by construction and requires ZERO work.** Acting on it is actively dangerous — see [§9 S-6](#9-what-could-silently-go-wrong). | [§3.6](#36-hard-problem-6--the-second-matrix-instance) |
| **F-4** | 🔴 **"All fields optional" is achievable for four of the six, and IMPOSSIBLE for two without amending two validation rules.** The brief assumes layout-Required is the blocker. It is not: `bovAddResponseModal.html:58-104` hand-writes `required` on each `lightning-input-field`, and the file's own comment states *"`lightning-record-edit-form` does NOT inherit layout requiredness when the fields are listed explicitly, which is why each one has to say so."* The real blockers are two **active, unguarded** validation rules — `Broker_Required_On_Submission` (`ISBLANK(Broker__c)`) and `BOV_Amount_Required_On_Submission` (`ISBLANK(BOV_Amount__c)`) — which fire on **every** save and are not bypassed by `SYSTEM_MODE`. | [§3.7](#37-hard-problem-7--the-reused-modal) |
| **F-5** | 🔴 **The `Approval_Pending__c` parent mirror is documented in four files and DOES NOT EXIST.** `Approval_Pending__c.field-meta.xml:19-21` says *"WHAT READS IT: BovSubmissionTriggerHandler ONLY, in after update context, which mirrors the value onto the PARENT"*; both workflow field-update `<description>`s repeat it; the approval process comment repeats it. **`grep Approval_Pending__c force-app/**/*.cls` returns ZERO matches.** The child flag is written by the approval and read by nothing. The parent's `Disposition__c.Approval_Pending__c` is written only by the three *Disposition-target* approvals. ⇒ The lock must be evaluated from the **child** rows, and `Submit_Selected_Broker` does **not** currently hide during a broker approval (pre-existing, adjacent, **not in scope**). | [§3.3](#33-hard-problem-3--the-lock) |
| **F-6** | 🔴 **Every `TestDataFactory` BOV fixture scores `null`, so the existing suite cannot exercise auto-selection at all.** `TestDataFactory.cls:2846-2856` states it plainly: the Dispositions the factory builds *"do not set `Asking_Price__c`, so the formula's guard returns null regardless"*. Under the recommended "null is never auto-selected" rule ([§3.1](#31-hard-problem-1--where-does-auto-selection-run)) that means **the entire existing test suite stays green while proving nothing about this feature**, and every new test must set `Asking_Price__c` explicitly. A green `RunLocalTests` is not evidence here. | [§7](#7-test-impact) |

**Two smaller corrections to the brief's framing.**
The brief says *"`BovController.replaceSelectedBroker` and `BovSubmissionService` already implement the demote-old / promote-new exclusivity sweep. Reuse, do not duplicate."* Reusing `BovSubmissionService.replaceSelectedBroker` **as the auto-selection writer is the wrong call** and I recommend against it: it is `@AuraEnabled`-reachable, it calls `DispositionActionPermissionService.assertDispositionActionAccess()` (a *human* permission gate that a trigger has no business asserting), it **requires** a `reason` and **unconditionally inserts a `BOV_Broker_Change__c` history row**, and it takes a savepoint and three DML statements. Reuse the *shape* and the invariant; do not reuse the method. Full argument in [§3.2](#32-hard-problem-2--exclusivity-under-bulk).

The brief also describes the guard as belonging to "the offer twin" (`DispositionOfferSelectionGuardService`). Both exist. The BOV one is the **primary** of the pair — its own header says so, because `Submission_Status__c` is user-editable (`DPEG_Disposition_Edit` grants `editable=true`, `DPEG_Disposition_Edit.permissionset-meta.xml:1327-1331`) while `Disposition_Offer__c.Is_Selected__c` is read-only FLS.

---

## 1. What the user asked for — restated, nothing added

1. `bovComparisonMatrix` carries **three** header buttons: **Add Broker Response**, **Replace Broker**, **Add Preferred Broker**.
2. **Remove the `Select Broker` button.** Its job is replaced by automatic scoring.
3. **Selected status is set automatically from the score**, recomputing until the approval is sent, then locked. Replace Broker remains the deliberate human override.
4. **Add Preferred Broker** opens the same `bovAddResponseModal` bundle, titled "Add Preferred Broker", with all fields optional.
5. A **second instance** of `bovComparisonMatrix` renders **above** the existing one, listing preferred brokers, **with no buttons**.
6. **Broker Activity Timeline is not shown** in that context.
7. **Submit Selected Broker → "Send Broker Approval"** (label-only; explicitly out of this agent's scope per the brief, but it is the lock's trigger — see [§3.3](#33-hard-problem-3--the-lock)).

Preferred brokers are a **separate list, never auto-selected**, flagged by a new field.

---

## 2. Naming decisions (propose; user to confirm)

| Proposed API name | Type | Object | Convention check (`ARCHITECTURE.md` §1) |
|---|---|---|---|
| **`Is_Preferred_Broker__c`** | Checkbox, default `false` | `BOV_Submission__c` | ✅ Boolean `Is_` prefix. ⚠ **Not** `Preferred_Broker__c` — the relationship rule reserves an object-shaped bare name for a lookup, and type-suffix discipline explicitly bans a non-lookup field camouflaged as one. |
| **`Is_Manually_Appointed__c`** | Checkbox, default `false` | `BOV_Submission__c` | ✅ Boolean `Is_` prefix. Written by `BovSubmissionService.replaceSelectedBroker` on the challenger; the permanent "a human chose this" marker. See [§3.3](#33-hard-problem-3--the-lock). |
| `Auto_Rescore` | new `BOV_Broker_Change__c.Reason__c` value | — | ⚠ **Recommended AGAINST** — see [§3.2](#32-hard-problem-2--exclusivity-under-bulk). Listed so the rejection is visible. |

---

## 3. The hard problems

### 3.1 Hard problem 1 — where does auto-selection run?

**Answer: BOTH. `BOV_Submission__c` after-insert/after-update AND `Disposition__c` after-update. Yes, the parent's save must recompute.**

**Why the parent hook is mandatory, not a nicety.** `BOV_Score__c`'s 50-point Value term is
`50 * MIN(BOV_Amount__c / Disposition__r.Asking_Price__c, 1.10) / 1.10`
(`BOV_Score__c.field-meta.xml:5-15`), and the whole formula returns `null` when the parent's
`Asking_Price__c` is blank or `<= 0`. `TestDataFactory.cls:2846-2856` and the prior design
(`agent-output/bov-scoring-and-selection.md` §2.5) both record that **no disposition in the org had an
asking price**. So the modal sequence on a real sale is:

1. Analyst logs three BOV responses. All score `null`. Nothing is selectable.
2. Analyst later types the Asking Price on the **Disposition**. All three scores materialise in one
   parent save, **with zero child DML**.
3. If selection only runs on child saves, **no broker is ever auto-selected** — and there may be no
   further reason to edit a BOV again. The sale sits at `BOV Outreach` with no appointment and the
   feature looks broken.

That is not an edge case; on the evidence it is the **primary** path. So:

- **Hook:** `DispositionTriggerHandler.afterUpdate`. The context already exists —
  `DispositionTrigger.trigger:24` declares `after update`. No trigger file change.
- **Key:** `Asking_Price__c` changed (old != new) on the Disposition. Zero-query fast path otherwise,
  matching the "an ordinary Disposition save costs nothing" contract that trigger's header already
  carries.
- **Direction is safe:** the write is parent → child. `Disposition__c` is the entry object of three
  `AdminOnly` approvals, which lock *the Disposition*, not its children. Children are locked only by
  `Broker_Finalize_Approval`, and a locked child is precisely the locked state — so it is never
  written. See [§3.3](#33-hard-problem-3--the-lock).

**The child hook** is `after insert` + `after update` on `BOV_Submission__c`, keyed on any of
`BOV_Amount__c`, `Commission_Rate__c`, `Days_To_Market__c`, `Submission_Status__c`,
`Is_Preferred_Broker__c` changing, plus every insert.
⚠ **`BovSubmissionTrigger.trigger:51` declares `before insert, before update, after update` — there is
NO `after insert` today**, and its header says so explicitly (*"⚠ NO `after insert`. Nothing needs
it"*). That comment must be retracted in place, not deleted, in the same change.

**🔴 It must be an AFTER context, not a before context.** A before context can set the incoming row's
own `Submission_Status__c` in memory for free, which is tempting — but it **cannot demote the
committed incumbent**, and demoting it as a separate statement is exactly what F-1 shows the guard
refuses. See [§3.2](#32-hard-problem-2--exclusivity-under-bulk).

#### The null-score question (the brief asks it directly)

**Recommendation: a `null` score is NOT a rank. A row with a null score is never auto-selected, and
if every candidate scores null, NOTHING is selected and the disposition keeps no Selected broker.**

- It is what the formula *means*. `BlankAsBlank` plus the explicit `ISBLANK` guard returns `null`
  deliberately, to say "not scoreable", not "worst". `Disposition__c.Days_On_Market__c` is the
  in-repo precedent for a Number formula returning `null`.
- The alternative — treating null as rankable and breaking the tie on `CreatedDate ASC` — means the
  **oldest** BOV wins on every un-priced disposition. That is "auto-select the first one that
  arrived", which is not scoring, and it would appoint a broker for a sale nobody has priced.
- ⚠ **The cost, stated plainly:** this is why F-6 bites. Every existing fixture scores null, so the
  entire suite is invisible to this feature and every new test must set `Asking_Price__c` on its own
  disposition fixture.

**Empty-state consequence:** the matrix currently shows a `Backup`/`Selected` pill for every row
(`bovComparisonMatrix.js:135`). Under this rule an un-priced sale shows all-`Backup` and a `—` score,
which is honest. **The user has not asked for an empty-state message and I am not proposing one.**

---

### 3.2 Hard problem 2 — exclusivity under bulk

**A guard exists: `BovSubmissionSelectionGuardService` (2026-08-20). Do not build a second one. Build
the writer to satisfy it.**

The guard's evaluation rule (its own header, lines 56-64):

> Error ONLY on a record being INSERTED AS Selected, or CHANGED TO Selected, when — **AFTER APPLYING
> EVERY INCOMING ROW'S NEW VALUE IN MEMORY** — another Selected sibling remains on the same
> Disposition.

Rows present in `Trigger.new` are subtracted from the committed count
(`BovSubmissionSelectionGuardService.cls:237-245`). That is the whole mechanism, and it dictates the
writer's shape exactly.

**🔴 The one DML that works, traced through the guard:**

New BOV `X` (score 90) inserted; committed incumbent `Y` (score 80, `Selected`).
Service issues **ONE** `Database.update([{Y → Backup}, {X → Selected}], true, SYSTEM_MODE)`.
→ `beforeUpdate` fires, `Trigger.new` = `[Y, X]`.
→ PASS 1: `Y` is not Selected in memory → skipped. `X` is Selected, `oldMap[X]` = `Backup` → `becomingSelected = [X]`. `incomingIds = {X, Y}`.
→ PASS 2: query returns `Y` (committed Selected) — but `Y ∈ incomingIds` → **skipped**. `committedByParent = {}`.
→ PASS 3: `others = 0 + 1 - 1 = 0` → **passes**. ✅

**🔴 Two shapes that are REFUSED, and they are the obvious implementations:**

| Shape | Outcome |
|---|---|
| Before-insert: set `X.Submission_Status__c = 'Selected'` in memory, demote `Y` in a separate DML | **REFUSED.** `Y` is not in `Trigger.new` on an insert, so PASS 2 counts it: `others = 1 + 1 - 1 = 1 > 0`. The guard `addError`s on `X` and **the user's insert is rolled back with a message about Replace Broker.** |
| After context, two DMLs: promote `X` first, then demote `Y` | **REFUSED** on statement 1, same arithmetic. (Demote-then-promote happens to pass, but relying on statement ordering for correctness is exactly the fragility the guard's header warns about.) |

The guard's header already names this trap for the *existing* service
(`BovSubmissionSelectionGuardService.cls:66-73`): *"If that service is ever split into two DML
statements it WILL start being refused here — which is the correct alarm, not a regression to work
around."* Auto-selection is the second class of caller that has to obey it.

**🔴 Do NOT reuse `BovSubmissionService.replaceSelectedBroker` as the auto-selection writer.** Four
independent blockers, any one sufficient:

1. `BovSubmissionService.cls:262` — `DispositionActionPermissionService.assertDispositionActionAccess()`.
   A trigger asserting a *human action* permission would refuse auto-selection for any principal who
   can save a BOV but is not a "disposition driver".
2. `BovSubmissionService.cls:266-268` — `reason` is **required** and refused when blank. There is no
   honest human reason for a rescore.
3. `BovSubmissionService.cls:383-407` — it **unconditionally inserts** a `BOV_Broker_Change__c` row.
   Auto-selection on a bulk load would spam that append-only log; a 251-row insert split across two
   trigger chunks writes **two** rows for one net outcome.
4. It takes a savepoint and does 3 DML across 3 objects, per invocation. Wrong budget for a trigger.

**Recommendation: a new `BovAutoSelectionService` (`layer=service`).** It owns exactly one invariant —
"the highest-scoring, non-preferred, unlocked submission is the Selected one" — and it does **one bulk
DML**. It shares the guard, the selector and the ordering with the existing service; it does not
duplicate them.

**Should it write a `BOV_Broker_Change__c` history row? Recommendation: NO.** And the argument is not
"logging is expensive" — it is that **the case the history object exists for cannot arise here**:

- The guard's header (lines 40-46) objects to trigger self-healing because *"demoting a submission
  WITHOUT also clearing its `Approval_Status__c` recreates precisely the state
  `replaceSelectedBroker` exists to prevent"*.
- **Under the lock in [§3.3](#33-hard-problem-3--the-lock), auto-selection only ever operates on a
  disposition where NO submission has been submitted, approved, rejected or manually appointed.** So
  every row it demotes has `Approval_Status__c = null` already, and every row it demotes was itself
  put there by the algorithm. There is no human decision to overwrite and no approval to revoke.
- Writing that into `BOV_Broker_Change__c` — whose `Logged_By__c` would be whoever happened to save a
  BOV, and whose `Reason__c` would be a synthetic value — **dilutes the exact log Workstream B built
  to record human decisions.**

⚠ **But that leaves NO audit trail at all**, because `BOV_Submission__c.object-meta.xml:149` is
`<enableHistory>false</enableHistory>`. **Recommendation: enable Field History Tracking on the object
and on `Submission_Status__c`** (admin work, [§5](#5-admin-work)). That is the cheap, correct place
for "the system flipped this, at this time".

**Belt-and-braces:** set `Approval_Status__c = null` on the demoted row anyway. It is provably already
null (above), costs nothing, and cannot regress.

**Budget (must be asserted in tests):**

| Context | SOQL | DML |
|---|---|---|
| Chunk where nothing relevant changed | **0** | **0** |
| Chunk where selection must be evaluated | **1** (siblings + lock state, one query keyed on the parent Id set) | **0 or 1** |

Constant in the number of submissions, matching the contract
`BovSubmissionSelectionGuardService` and `BovSubmissionBrokerStampService` already carry.

**Recursion:** the service's own `Database.update` re-enters `beforeUpdate`/`afterUpdate`. It
terminates naturally (the winner is already Selected, so the second pass computes zero writes), but
add an explicit `@TestVisible private static Boolean suppress` reentrancy flag and assert the DML
count — this repo has a measured incident (`trigger-cascade-on-bulk-insert`) where a re-entrant
counter recompute cost `ceil(rows/200)` extra DML.

---

### 3.3 Hard problem 3 — the lock

**What marks "approval sent": `Approval_Pending__c` is reliable ON THE SUBMISSION, and is the
right primary signal — but it alone is not sufficient, and the parent copy is unusable (F-5).**

`Approval_Pending__c.field-meta.xml:11-17` and `Broker_Finalize_Approval.approvalProcess-meta.xml:144-179`
agree, and I verified all four hooks are present in the approval file:

| Event | Hook | Writes |
|---|---|---|
| Submit | `initialSubmissionActions` → `Set_Broker_Approval_Pending` | `true` |
| Approved | `finalApprovalActions` → `Clear_Broker_Approval_Pending` (2nd action) | `false` |
| Rejected | `finalRejectionActions` → `Clear_Broker_Approval_Pending` (2nd action) | `false` |
| Recalled | `recallActions` → `Clear_Broker_Approval_Pending` | `false` |

All four exist. This is the complete four-exit-path shape, and it is one of the few places in this
repo where `initialSubmissionActions` and `recallActions` are actually wired.

**🔴 Alone it is not enough, because it goes FALSE on approval.** The user's rule is "locks once the
approval is sent" — a lock that releases the moment the principals approve would let the next BOV
save swap out the *approved* broker.

**Recommended lock predicate — evaluated over ALL of a disposition's submissions, in the same single
query the service already issues:**

```
LOCKED(disposition) ⟺ ∃ submission where
      Approval_Pending__c   = true        // in flight
   OR Approval_Status__c   != null        // a decision was made (Approved OR Rejected)
   OR Is_Manually_Appointed__c = true     // a human used Replace Broker
```

Each leg answers a question the others cannot:

| Leg | Covers | Behaviour on recall |
|---|---|---|
| `Approval_Pending__c` | the pending window | → `false`. **Unlocks.** ✅ |
| `Approval_Status__c != null` | approved **and** rejected, permanently | stays `null` on recall (a recall fires no status update) → contributes nothing. ✅ |
| `Is_Manually_Appointed__c` | the deliberate human override surviving anything | unaffected |

**Recall → selection UNLOCKS and resumes recomputing.** Correct: a recall means "I did not mean to
send that yet". The approval never happened, nothing was decided, and the state is byte-identical to
pre-submission. This falls out of the predicate with no special case.

**Rejection → selection stays LOCKED. Recommendation, and the brief asks for the intended behaviour
explicitly.** `Broker_Finalize_Approval`'s own comment (line 47-49): *"REJECTION MOVES NOTHING.
Set_Broker_Approval_Rejected records the outcome and the Disposition stays at BOV Outreach so a
different submission can be selected and resubmitted."* A rejection is a **decision by the principals
about this broker**. If auto-selection resumed, the algorithm would answer a question a human just
answered by hand — and since the rejected broker is still the highest scorer, it would either
re-select the same broker (a no-op that looks like the system ignoring the rejection) or, on the next
BOV arrival, silently swap in a different broker with no actor. **The remedy after a rejection is
Replace Broker, which is exactly the deliberate human override the user preserved.**

**🔴 `Is_Manually_Appointed__c` is not optional, and here is why.**
`BovSubmissionService.replaceSelectedBroker` **clears `Approval_Status__c` on BOTH rows**
(`BovSubmissionService.cls:308` and `:333`) — deliberately, so the new broker needs a fresh approval.
Without the third leg, a manual Replace Broker after a rejection would leave `Approval_Pending__c =
false` and `Approval_Status__c = null` everywhere ⇒ **auto-selection UNLOCKS and undoes the human's
deliberate pick on the very next BOV save.** That directly violates settled decision 1. The flag is
set on the challenger inside that service's existing single bulk write — **zero extra DML**.

**Why the lock is not only a business rule — it is what prevents `ENTITY_IS_LOCKED`.**
`Broker_Finalize_Approval` is `recordEditability = AdminOnly` (line 180), and
`BovSubmissionTriggerHandler.cls:34-39` records that *"`AccessLevel.SYSTEM_MODE` does not lift a
lock"*. An unlocked auto-selection that tried to demote a submission with a pending approval would
throw `ENTITY_IS_LOCKED` inside an `allOrNone = true` bulk update — **rolling back the unrelated BOV
the user was trying to save.** The lock is the guard against that, and the two must never be
decoupled.

**FLS note that is load-bearing:** `Approval_Pending__c` has **no `fieldPermissions` entry in any
permission set, deliberately** (`DPEG_Disposition_View.permissionset-meta.xml:129-132`, and the same
paragraph in `_Edit`). The lock query **must** be `WITH SYSTEM_MODE` — a `USER_MODE` read of that
field throws `System.QueryException: No such column` for literally every user including System
Administrator. **Do not "fix" this by granting FLS**; both files carry an explicit "do not complete
the set" instruction.

---

### 3.4 Hard problem 4 — ties

**`ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC`.**

This is the repo's precedent (all three ranked queries in `BovSubmissionSelector` carry it, added
2026-08-21) — but precedent is the weaker half of the argument. **The strong argument is that it is
the same order the matrix displays.** `BovSubmissionSelector.selectByDispositionId:132` uses exactly
this clause, and `BovController.getSubmissions` passes rows through in order to
`bovComparisonMatrix`. If auto-selection used any other tie-break, the green **Selected** pill would
land on a row that is *not* the top row of the table the user is looking at — which reads as a bug and
is unfalsifiable from the UI.

`Id ASC` is not decoration: `CreatedDate` alone ties for two rows created in the same transaction
(every bulk insert, every seed script), and SOQL promises no order for a fully-tied sort.

---

### 3.5 Hard problem 5 — sharing and mode

**Three separate refusals. `SYSTEM_MODE` addresses one of them. All three must be answered
independently.**

| Refusal | Applies? | Answer |
|---|---|---|
| **CRUD / FLS** on the read | Yes — `Approval_Pending__c` has no FLS anywhere (F-5 / §3.3) | Selector method `WITH SYSTEM_MODE`, justified at its **own declaration** per `ARCHITECTURE.md` §2 (*"The mode is a property of the METHOD, never of the class"*). New method on `BovSubmissionSelector`; do **not** widen `selectSelectedByDispositionIds` — its `WHERE Submission_Status__c = 'Selected'` is the guard's counting predicate and adding terms to it inverts the guard into a permitter (that class's header makes this exact argument about `Broker__c != NULL`). |
| **CRUD / FLS** on the write | Yes — `Approval_Status__c` is granted **read-only** in both disposition sets | `Database.update(writes, true, AccessLevel.SYSTEM_MODE)` |
| **🔴 RECORD-LEVEL SHARING** on the write | **YES, and this is the one that bites** | A `private without sharing` inner class holding **only** the one statement |

**The sharing argument, concretely.** `BOV_Submission__c.object-meta.xml:164` is
`<sharingModel>Private</sharingModel>`. Auto-selection runs as whoever saved a BOV — routinely a
different person from the owner of the *sibling* row being demoted (four brokers, four analysts, one
sale). `DPEG_Disposition_Edit` and `DPEG_Disposition_View` both carry `viewAllRecords = true` and
**neither carries `modifyAllRecords`** — the exact combination `BovSubmissionTriggerHandler.cls:381-390`
documents as *"THE TRAP: the idempotency read above returns the row (read access exists) and the write
is then refused (edit access does not). A read that succeeds is not evidence a write will."*

The brief is right that four sites were fixed for this today. **This is a fifth site of the same
shape** and it must be designed in from the start, not discovered in UAT.

**Prescribed shape — copy `BovSubmissionTriggerHandler.ParentAdvanceWrites` (lines 373-419) exactly:**

- Outer service stays `with sharing`. Selector stays `with sharing`.
- `private without sharing` inner class, **one statement**, over a list the caller built.
- It cannot query, cannot choose rows, cannot widen — every Id came back from a `with sharing`-class
  selector read, so a submission the running user cannot **see** is still never written.
- ⚠ **`allOrNone = true`, not `false`.** This diverges from `ParentAdvanceWrites` and the divergence
  is deliberate: there, `allOrNone = false` protects an *approval* that is irreplaceable. Here a
  half-applied swap leaves **two Selected rows** — the exact defect the guard exists to prevent. A
  refusal is the correct outcome and the user's save is rolled back with a real message.
- 🔴 **Inspect the `SaveResult`s anyway** and expose them on a `@TestVisible static
  List<String> lastRunSelectionFailures`, mirroring
  `BovSubmissionTriggerHandler.recordParentWriteFailures`. That handler's header records the
  retraction that made this mandatory: *"'cannot recover' is not 'must not report'. Un-inspected
  results are what let the sibling handler's identical statement fail in production and look exactly
  like success."*

**The residual, named rather than hidden:** the *read* stays `with sharing`, so a Selected sibling the
running user cannot see is absent from the count and auto-selection would promote a second Selected
row — which the **guard** then refuses in the before context. The guard is the backstop, and it fails
in the safe direction (a refusal, not a duplicate). Bounded by `viewAllRecords = true` on both
disposition sets.

---

### 3.6 Hard problem 6 — the second matrix instance

**Answer: neither a `targetConfig` property nor a wrapper. A plain `@api` property on the existing
bundle, and a second tag in `dispositionMain.html`.**

**Why not `targetConfig` (F-2).** `bovComparisonMatrix.js-meta.xml` is `isExposed=false` with no
`targetConfigs`. Adding one means **exposing the bundle to Lightning App Builder**, which is a far
larger change than it looks: it lets an admin drop uncontrolled copies onto any page, it creates a
FlexiPage-side surface with its own `componentInstanceProperties` failure modes (this page has two
recorded incidents of exactly that — `bovBrokerChangeHistory` failed with *"Invalid property
[recordId]"*, `dispositionDealSummary` bound to an empty string), and it does not even solve the
problem, because the component is not a FlexiPage item — it is a child of `dispositionMain`.

**Why not a wrapper bundle.** A `bovPreferredBrokerMatrix` wrapper would have to duplicate the
`COLUMNS` array, the `getSubmissions` wire, and — decisively — the **un-destructured `_wired`
invariant** that `bovComparisonMatrix.js:50-57` calls load-bearing: *"a 'tidying' edit back to
`wired({ data, error })` compiles, passes every render test, and silently turns those refreshes into
no-ops."* Two copies of that contract is two chances to lose it.

**Recommended shape:**

```
lwc/dispositionMain/dispositionMain.html   (inside if:true={isBovOutreach}, ABOVE the existing tag)
    <c-bov-comparison-matrix record-id={recordId} preferred-only hide-actions>
    <c-bov-comparison-matrix record-id={recordId}>          ← existing, unchanged markup
```

`bovComparisonMatrix.js` gains two `@api` booleans, defaulting `false` so **the existing instance's
behaviour is unchanged by construction**:

| Property | Effect |
|---|---|
| `preferredOnly` | `rows` getter filters `r.isPreferred === true`; default instance filters `!== true` |
| `hideActions` | the whole `<div slot="actions">` block does not render |

**Data: ONE wire, filtered client-side. Do not add a second Apex method.** `getSubmissions` already
returns every submission for the disposition. Adding an `isPreferred` member to `BovController.BovRow`
and filtering in the `rows` getter costs zero extra SOQL, zero extra cache entries, and — the real
reason — **guarantees the two instances cannot disagree about the same broker's numbers**, which is
the exact contract that forced `brokerOptionLabel` out of this component and into `c/utils`
(`bovComparisonMatrix.js:16-26`).

🔴 **The card title must differ**, or two cards both read "BOV Comparison Matrix (n)". Propose
"Preferred Brokers ({count})" for the top instance via a third `@api cardTitle` or a getter branch.
**The user did not specify this — see [§11 Q-4](#11-gates--must-be-resolved-before-build).**

⚠ **The Status column is misleading on the preferred instance.** Preferred rows are never Selected, so
the pill always reads "Backup" — a word that means "runner-up broker" and is wrong for a preferred
broker. **Not specified by the user; Q-4.**

**The Broker Activity Timeline (F-3).** It is `lwc/dispositionBuyerTimeline`, a **sidebar FlexiPage
card**, ungated except for a `Disposition_Stage__c NE 'Disposition Readiness'` rule added 2026-08-24.
It is not rendered inside `dispositionMain`, not inside the matrix, and not near either instance.
**The requirement is already satisfied. Change nothing.** The FlexiPage is explicitly OUT of scope for
this work — see [§9 S-6](#9-what-could-silently-go-wrong) for why touching it is the single most
expensive mistake available here.

---

### 3.7 Hard problem 7 — the reused modal

**"All fields optional" is achievable for four of the six without touching the layout. It is
impossible for `Broker__c` and `BOV_Amount__c` without amending two validation rules.**

#### Layer 1 — layout requiredness: NOT a blocker (F-4)

`bovAddResponseModal.html:73-87` states it: *"`lightning-record-edit-form` does NOT inherit layout
requiredness when the fields are listed explicitly, which is why each one has to say so."* The six
`required` attributes are hand-written on the `lightning-input-field` elements. Making them
conditional (`required={isRequired}` driven by a new `@api isPreferred`) is a template change only.
**No change to `BOV Submission Layout` is needed**, which matters — that file is already modified in
the working tree per `git status`.

⚠ The same comment carries the standing instruction *"🔴 IF THE LAYOUT IS EVER RELAXED, RELAX THESE IN
THE SAME CHANGE."* Conditioning them is not relaxing them; the default path keeps all six. Retract the
comment in place to record that a second, preferred-broker mode exists.

#### Layer 2 — validation rules: THE actual blocker

| Field | Layout | Validation rule | Optional on the preferred path? |
|---|---|---|---|
| `Disposition__c` | Required | — | n/a — forced by `withParent()` (`bovAddResponseModal.js:132-134`) |
| `Broker__c` | Required | 🔴 `Broker_Required_On_Submission` — `ISBLANK(Broker__c)`, **unguarded** | ❌ needs a VR amendment |
| `BOV_Amount__c` | Required | 🔴 `BOV_Amount_Required_On_Submission` — `ISBLANK(BOV_Amount__c)`, **unguarded** | ❌ needs a VR amendment |
| `Cap_Rate__c` | Required | none | ✅ template only |
| `Commission_Rate__c` | Required | none | ✅ template only |
| `Days_To_Market__c` | Required | none | ✅ template only |
| `Hist_Success_Rate__c` | Edit | none | ✅ already optional |

Both rules are unguarded invariants by design and **`SYSTEM_MODE` does not bypass a validation rule**
(`Broker_Required_On_Submission`'s own comment, line 51-52). Amending them means adding a
preferred-broker exemption:

```
AND( NOT(Is_Preferred_Broker__c), ISBLANK(Broker__c) )
AND( NOT(Is_Preferred_Broker__c), ISBLANK(BOV_Amount__c) )
```

🔴 **`BOV_Amount_Required_On_Submission`'s header anticipates this exact change** (lines 41-48): *"NO
STATUS EXEMPTION, BECAUSE THERE IS NO STATUS TO EXEMPT… 🔴 IF A NON RESPONSE VALUE IS EVER ADDED TO
`Submission_Status__c`, THIS RULE MUST BE AMENDED IN THE SAME CHANGE or it will freeze every such
row."* A preferred broker is precisely that shape — a row that is not a response — arriving via a flag
rather than a status value. The instruction applies.

#### 🔴 My recommendation diverges from the literal request on ONE field, and I am flagging rather than deciding

**Keep `Broker__c` required even on the preferred path.** A "preferred broker" with no broker Contact
is an empty row: `BovSubmissionBrokerStampService` derives `Broker_Firm__c` and `Contact_Name__c`
**from** `Broker__c` (`BovSubmissionTriggerHandler.cls:188-197`), so a blank lookup produces a
preferred-broker row whose Firm and Contact columns both render `—` — a row identifying nobody, in a
list whose entire purpose is to identify somebody.

`BOV_Amount__c` is different and should genuinely be exempted: a preferred broker is a firm you'd like
to use, not a firm that has quoted. **Q-3.**

#### Layer 3 — the modal itself

- `@api isPreferred` (default `false`), driving: the `lightning-modal-header` label ("Add Preferred
  Broker" vs "Add Broker Response"), the six `required` attributes, and a hidden
  `Is_Preferred_Broker__c = true` injected in `withParent()` — **which is the one place that already
  knows how to force a field onto the payload**, and the reason it must go there is the same reason
  `Disposition__c` does: `handleSave` and `handleSubmit` are two genuinely separate submit paths.
- ⚠ **`Submission_Status__c` must be forced to `Backup` and its input removed on the preferred path.**
  It currently renders with `value={defaultStatus}` and is user-editable
  (`bovAddResponseModal.html:145-149`). A user setting a preferred row to `Selected` would enter it
  into `Broker_Finalize_Approval` (entry criterion is `Submission_Status__c = 'Selected'`, nothing
  else) and appoint a broker with no BOV amount.
- ⚠ **`lightning-input-field` cannot render `Is_Preferred_Broker__c` if the running user lacks
  `editable` FLS** — it is a hard runtime error, not a soft skip (the same failure the file's own
  `BOV_Score__c` retraction describes). Since it is injected programmatically rather than rendered,
  the field is FLS-checked by `lightning-record-edit-form` on the **payload** and vanishes silently
  with a success toast if not editable. **This is why the FLS grant must deploy before the LWC** —
  see [§6](#6-deploy-ordering) and [§9 S-2](#9-what-could-silently-go-wrong).

---

## 4. Summary of the mechanism

```
BOV_Submission__c after insert / after update ──┐
                                                 ├─→ BovAutoSelectionService.reselect(Set<Id> dispositionIds)
Disposition__c after update (Asking_Price__c) ──┘        │
                                                          │  1 SOQL (SYSTEM_MODE):
                                                          │     all submissions per disposition,
                                                          │     ordered BOV_Score__c DESC NULLS LAST,
                                                          │            CreatedDate ASC, Id ASC
                                                          │     carrying Approval_Pending__c,
                                                          │             Approval_Status__c,
                                                          │             Is_Manually_Appointed__c,
                                                          │             Is_Preferred_Broker__c
                                                          │
                                                          ├─ LOCKED?  → return, 0 DML
                                                          ├─ winner = first row with a NON-NULL score
                                                          │            AND Is_Preferred_Broker__c = false
                                                          ├─ no winner → return, 0 DML
                                                          ├─ winner already Selected AND no other
                                                          │  Selected row → return, 0 DML  (idempotent)
                                                          │
                                                          └─ ONE Database.update([demote…, promote], true,
                                                                SYSTEM_MODE) from a
                                                                `private without sharing` inner class
                                                                  → re-enters beforeUpdate
                                                                  → BovSubmissionSelectionGuardService PASSES
                                                                     (both rows in Trigger.new)
```

---

## 5. Admin work

*(`salesforce-admin`. Simple declarative work: two fields, two VR amendments, FLS, history tracking.
No multi-object schema design, no security-model design, so `salesforce-solution-architect` is not
warranted.)*

| # | Type | File | Action |
|---|---|---|---|
| A1 | CustomField | `objects/BOV_Submission__c/fields/Is_Preferred_Broker__c.field-meta.xml` | **NEW.** Checkbox, `defaultValue false`, `trackHistory false`. |
| A2 | CustomField | `objects/BOV_Submission__c/fields/Is_Manually_Appointed__c.field-meta.xml` | **NEW.** Checkbox, `defaultValue false`, `trackHistory false`. System-written by `BovSubmissionService.replaceSelectedBroker` only. |
| A3 | PermissionSet | `permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml` | `Is_Preferred_Broker__c` **readable + editable**; `Is_Manually_Appointed__c` **readable, editable=false**. |
| A4 | PermissionSet | `permissionsets/DPEG_Disposition_View.permissionset-meta.xml` | Both **readable, editable=false**. |
| A5 | ValidationRule | `objects/BOV_Submission__c/validationRules/BOV_Amount_Required_On_Submission.validationRule-meta.xml` | Amend to `AND(NOT(Is_Preferred_Broker__c), ISBLANK(BOV_Amount__c))`. |
| A6 | ValidationRule | `objects/BOV_Submission__c/validationRules/Broker_Required_On_Submission.validationRule-meta.xml` | **ONLY IF Q-3 says so.** Same shape. |
| A7 | CustomObject | `objects/BOV_Submission__c/BOV_Submission__c.object-meta.xml` | `<enableHistory>false</enableHistory>` → `true` (line 149). |
| A8 | CustomField | `objects/BOV_Submission__c/fields/Submission_Status__c.field-meta.xml` | add `<trackHistory>true</trackHistory>`. |

**Hard constraints for the admin agent:**

- 🔴 **A `PermissionSet` deploy REPLACES its entire `<fieldPermissions>` set.** Both files must be
  diffed against `HEAD` before deploying. `DPEG_Disposition_Edit` is **already modified in the working
  tree** per `git status` — reconcile, do not overwrite.
- 🔴 **`Is_Manually_Appointed__c` must be `editable=false` in `DPEG_Disposition_Edit`.** It is the
  lock's permanence leg; a user who can clear it can un-lock a broker the principals decided on. Same
  reasoning as `Disposition_Offer__c.Is_Selected__c` and `BOV_Submission__c.Approval_Status__c`, both
  read-only in both sets for the same reason (`DPEG_Disposition_View:73-76`).
- ⚠ **Do NOT grant FLS on `Approval_Pending__c`.** Both permission sets carry an explicit
  "do not complete the set" instruction. The lock query is `SYSTEM_MODE` precisely so it does not need it.
- ⚠ `<description>` is capped at **255 characters** on `CustomField` and `ValidationRule`. Longer
  rationale goes in an XML comment **inside** the root element (a comment above the root breaks `sf`
  at source conversion with a misleading parent-xml error).
- ⚠ Neither VR amendment may be deployed **before** A1, or the formula references a field that does
  not exist.
- ⚠ **No FlexiPage change. No layout change.** See [§9 S-6](#9-what-could-silently-go-wrong).

---

## 6. Development work

*(`salesforce-developer`. Standard Apex service/selector/trigger-handler + LWC work — no integration,
no callouts, no LDV. `salesforce-technical-architect` is not warranted.)*

### Apex, by layer

| Layer | Class | Change |
|---|---|---|
| **Selector** | `BovSubmissionSelector` | **+1 method** `selectSelectionContextByDispositionIds(Set<Id>)` — `WITH SYSTEM_MODE`, justified at its own declaration, `ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC`. Selects `Id, Disposition__c, Submission_Status__c, BOV_Score__c, Approval_Pending__c, Approval_Status__c, Is_Manually_Appointed__c, Is_Preferred_Broker__c, Broker_Firm__c`. 🔴 **Do not widen `selectSelectedByDispositionIds`** — its `WHERE` is the guard's counting predicate. ⚠ Re-count the SYSTEM_MODE tally in the class header; that line has decayed three times and says so. |
| **Selector** | `BovSubmissionSelector.selectByDispositionId` | **+`Is_Preferred_Broker__c`** in the SELECT. 🔴 **This read is `WITH USER_MODE`** — adding a field is an **FLS change**, and a missing grant throws `No such column` and blanks the whole matrix for everyone. A3/A4 are a **hard prerequisite**. |
| **Service** *(new)* | `BovAutoSelectionService` | The mechanism in [§4](#4-summary-of-the-mechanism). `with sharing`. One `private without sharing` inner class holding the single `Database.update(writes, true, SYSTEM_MODE)`. `@TestVisible static List<String> lastRunSelectionFailures`. `@TestVisible static Boolean suppressReentry`. Zero-query fast path. |
| **Service** | `BovSubmissionService.replaceSelectedBroker` | **+1 field** `Is_Manually_Appointed__c = true` on the challenger's existing write (`:328-334`). **Zero new DML, zero new SOQL.** Do not touch anything else in this method. |
| **Handler** | `BovSubmissionTriggerHandler` | **+`afterInsert()`** override; **+call** in `afterUpdate()`, keyed on the score inputs / status / preferred flag changing. ⚠ `handleApprovedSelections` stays untouched and stays first. ⚠ **Retract in place** the header's "TWO/THREE JOBS" count and the trigger's *"⚠ NO `after insert`. Nothing needs it"* comment. |
| **Trigger** | `BovSubmissionTrigger.trigger` | **+`after insert`** to the context list (line 51). One-line change; the file stays a pure delegation. |
| **Handler** | `DispositionTriggerHandler` | **+call** in the existing `afterUpdate`, keyed on `Asking_Price__c` changing. Zero-cost fast path otherwise. No trigger file change (`after update` already declared). |

### LWC

| Bundle | Change |
|---|---|
| `bovComparisonMatrix` | **DELETE** the `Select Broker` button (`.html:19-25`), `canSelectBroker` (`.js:183-185`) and `handleSelectBroker` (`.js:315-327`). **ADD** an "Add Preferred Broker" button and `handleAddPreferredBroker`. **ADD** `@api preferredOnly`, `@api hideActions` (both default `false`) and filter in the `rows` getter. ⚠ **Do not touch `_wired` or `_openBrokerModal`.** ⚠ `canReplaceBroker` and `_backupOptions` are unchanged — `_backupOptions` should now **also** exclude preferred rows so a preferred broker cannot be appointed via Replace Broker. |
| `bovAddResponseModal` | **ADD** `@api isPreferred`. Drives the header label, the six conditional `required` attributes, forcing `Is_Preferred_Broker__c = true` and `Submission_Status__c = 'Backup'` in `withParent()`, and removing the `Submission_Status__c` input on the preferred path. ⚠ Both submit paths funnel through `withParent()` — that is the only correct place. |
| `dispositionMain` | **ADD** a second `<c-bov-comparison-matrix preferred-only hide-actions>` **above** the existing tag, inside `if:true={isBovOutreach}`. Existing tag byte-unchanged. |
| `BovController` | `BovRow` **+`@AuraEnabled public Boolean isPreferred`**, mapped in `getSubmissions`. No signature change, no new method. |

---

## 7. Deploy ordering

Load-bearing. A Metadata-API-deployed custom field arrives with **no FLS for anyone, System
Administrator included** — this repo has a recorded incident.

| Wave | Contents | Why it cannot move later |
|---|---|---|
| **0 — gate** | Answer Q-1…Q-5 ([§11](#11-gates--must-be-resolved-before-build)). Query the org: `SELECT COUNT(Id) FROM BOV_Submission__c WHERE Submission_Status__c = 'Selected' GROUP BY Disposition__c HAVING COUNT(Id) > 1` and `SELECT COUNT(Id) FROM Disposition__c WHERE Asking_Price__c != null`. | The second query tells you whether auto-selection will do **anything at all** on day one. If it returns 0, the feature is inert in production and UAT will report "it doesn't work". |
| **1** | A1, A2 (the two Checkbox fields) | Everything downstream references them. |
| **2** | A3, A4 (FLS) — **diff against `HEAD` first** | 🔴 `selectByDispositionId` is `USER_MODE`. If the Apex in wave 4 lands first, `getSubmissions` throws `No such column` and **the entire BOV Comparison Matrix disappears for every user**. Also: the modal's programmatic `Is_Preferred_Broker__c` payload key is FLS-checked by `lightning-record-edit-form` and **dropped silently with a success toast** without `editable`. |
| **3** | A5, A6 (VR amendments), A7, A8 (history tracking) | VRs reference A1. Must land **before** the modal can save a blank-amount preferred row. |
| **4** | Apex: selector → service → handlers → trigger; then `BovController` | Standard dependency order. |
| **5** | LWC: `bovAddResponseModal` → `bovComparisonMatrix` → `dispositionMain` | Child before parent. `dispositionMain` last. |
| **6** | Test classes + Jest | |

⚠ **`sf` dry-runs skip byte-identical components** (`state: Unchanged`) — a green dry-run can mean
"never validated". Comment-only edits do not count as a diff. Verify per-component state.

---

## 8. Test impact

### Jest — `lwc/bovComparisonMatrix/__tests__/bovComparisonMatrix.test.js`

**8 tests break hard** (they call `selectBtn(element).click()` on `null` → `TypeError`):

| Line | Test |
|---|---|
| 441 | `REPLACE BROKER is HIDDEN until a submission is Selected — SELECT BROKER takes its place` (asserts `selectBtn` **not** null, line 449) |
| 523 | `SELECT: opens the SAME modal bundle in first-appointment mode with EVERY submission` |
| 554 | `🔴 SELECT: a null score renders an EM DASH, never 0` |
| 573 | `🔴 SELECT: two brokers with an IDENTICAL name and firm are still distinguishable` |
| 594 | `🔴 SELECT SUCCESS: toasts the SERVER message STICKY, then refreshes THIS wire` |
| 627 | `SELECT CANCELLED: no toast and no refresh` |
| 644 | `SELECT: a modal that fails to OPEN toasts its OWN message and does not refresh` |
| 669 | `SELECT: never navigates` |

🔴 **3 more tests survive VACUOUSLY and are the more dangerous half** — lines **465**, **477** and
**490** each assert `expect(selectBtn(element)).toBeNull()`. They will pass because the button no
longer exists, not because the visibility logic is right. Their comments (e.g. line 460-464,
*"EXACTLY ONE OF THE TWO, ALWAYS"*) become false. **Delete them or re-point them at the new
Add Preferred Broker button; do not leave them green.**

Also required: the `SELECT` tests at 554/573 covered the **null-score em dash** and the
**duplicate-broker disambiguator** — behaviours that still exist and are still worth pinning. They
must be **re-homed onto the Replace path**, not simply deleted. `_backupOptions` and
`brokerOptionLabel` (`c/utils`) are the code under test.

New Jest coverage needed: the two-instance render in `dispositionMain`, `preferredOnly` filtering,
`hideActions` suppressing the whole action slot, the modal's `isPreferred` label and conditional
`required`, and `@sa11y/jest` on both instances.

### Apex

| Class | Impact |
|---|---|
| `BovSubmissionSelectionGuardTest` | 🔴 **`existingReplaceSelectedBrokerService_stillSucceeds` is the falsifier and must never be deleted** (that guard's header says so). **Add the twin:** `autoSelectionSwap_isNotRefusedByTheGuard`. This is the single most important new test in the tranche. |
| `BovSubmissionServiceTest` | +assert `Is_Manually_Appointed__c = true` on the challenger after a replace. |
| `BovSubmissionTriggerHandlerTest` | New `after insert` context is now live for every fixture. Re-assert the zero-query/zero-DML fast path. |
| `BovControllerTest` | +`isPreferred` mapping. |
| `BovSubmissionSelectorTest` | +the new selection-context method. ⚠ Its header already carries a deferred-coverage note about needing `Asking_Price__c` for differing scores — this is where that debt comes due. |
| **`TestDataFactory`** | 🔴 **Needs a new fixture that sets `Asking_Price__c` on the disposition.** Without it every auto-selection test is vacuous (F-6). Do **not** change `createBovSubmissions`' default — that would flip every existing negative fixture across the suite. Add a *new* method. |
| **New:** `BovAutoSelectionServiceTest` | See below. |

**Bulk mandate.** `.claude/rules/bulk-test-rule.md`'s **251-record** requirement **applies in full** —
this is a trigger path that loops over a collection, and there is no exemption to claim.
⚠ 251 BOVs on one disposition span **two** trigger chunks (200 + 51), so auto-selection runs twice and
may flip twice before settling. **Assert the END STATE (exactly one Selected, and it is the highest
scorer across all 251) and assert the DML count is constant** — not that it flipped once.

Mandatory test list for `BovAutoSelectionServiceTest`:

1. Highest score is promoted; incumbent demoted; **exactly one Selected**.
2. All-null scores → **nothing selected, zero DML** (the F-6 rule).
3. Preferred row with the highest score → **not selected**.
4. Ties on score → oldest `CreatedDate` wins; identical `CreatedDate` → lowest `Id`.
5. Lock: `Approval_Pending__c = true` → no write.
6. Lock: `Approval_Status__c = 'Approved'` → no write.
7. Lock: `Approval_Status__c = 'Rejected'` → **no write** (the settled behaviour, §3.3).
8. Lock: `Is_Manually_Appointed__c = true` → no write.
9. **Recall unlocks** — `Approval_Pending__c` back to `false` with `Approval_Status__c` still null → recomputes.
10. Parent `Asking_Price__c` set → all children rescore → winner selected, **with zero child DML from the user**.
11. Idempotency: re-running when the winner is already Selected → **zero DML**.
12. 🔴 **Non-owner runs the save** (a second `User` owning the sibling) → the swap still succeeds. This is the ONLY test that proves the `without sharing` escape. Build the persona the way `TestDataFactory` already does for `DispositionOfferTriggerHandler` — with `DPEG_Disposition_Edit`, which carries `viewAllRecords` and **no** `modifyAllRecords`, so a pass can only come from the escape.
13. 251-record bulk insert; 251-record bulk update.
14. `lastRunSelectionFailures` is **empty** on the happy path (asserting it makes a removed sharing escape fail with a real `StatusCode`).

---

## 9. What could silently go wrong

*In this codebase's specific idiom: a green deploy that does nothing, a guard that fails open, a
selection that flips without anyone noticing.*

**S-1 — 🔴 The feature is inert in production and everything is green.** If no `Disposition__c` has an
`Asking_Price__c`, every score is `null`, nothing is ever auto-selected, and there is **no error
anywhere**. The deploy succeeds, `RunLocalTests` passes (F-6 — the fixtures score null too, so they
never reach the promotion path), UAT reports "it doesn't work" and the first hypothesis will be the
trigger. **Detection:** wave-0 query `SELECT COUNT(Id) FROM Disposition__c WHERE Asking_Price__c != null`.
**Mitigation:** name this in the handover as a data prerequisite, and set `Asking_Price__c` in the
seed scripts.

**S-2 — 🔴 Preferred brokers save as ordinary brokers, with a success toast.**
`lightning-record-edit-form` FLS-checks **every key in the payload including programmatic ones**, and
a non-editable field is **dropped silently**. If A3 (`Is_Preferred_Broker__c` editable in
`DPEG_Disposition_Edit`) has not landed, "Add Preferred Broker" creates a row with the flag `false` —
which lands it in the **bottom** matrix and makes it **auto-selectable**. This repo has a recorded
incident of exactly this shape. **Detection:** after the first preferred save,
`SELECT Id, Is_Preferred_Broker__c FROM BOV_Submission__c ORDER BY CreatedDate DESC LIMIT 1`.

**S-3 — 🔴 A selection flips and nothing records it.** `BOV_Submission__c` is
`<enableHistory>false</enableHistory>` (line 149) and this design deliberately writes **no**
`BOV_Broker_Change__c` row for automatic swaps ([§3.2](#32-hard-problem-2--exclusivity-under-bulk)).
Without **A7/A8** there is *no* trail at all: a broker who was Selected on Monday is Backup on Tuesday
and nobody can say when or why. A7/A8 are not optional polish.

**S-4 — 🔴 The guard fails OPEN under sharing, and that inverts it.** The guard's read is
`with sharing` + `SYSTEM_MODE`; a Selected sibling the running user cannot **see** is absent from the
count, so the guard **permits** a second Selected row instead of blocking one. Its own header names
this (lines 131-136) and bounds it with `viewAllRecords = true` on both disposition sets. **Auto-selection
increases the number of principals who save BOVs**, so it widens the population this bound depends on.
If `DPEG_Admin_Access` (which grants **no** `BOV_Submission__c.Broker__c` at all, measured 2026-08-21)
or any new persona ever saves a BOV, the bound is gone. **Detection:** the wave-0 duplicate-Selected
`GROUP BY … HAVING COUNT(Id) > 1` query, re-run periodically.

**S-5 — 🔴 A user's ordinary BOV save is rolled back with a message about Replace Broker.** If the
writer is implemented in a before context or as two DML statements, the guard `addError`s the *user's*
row with `DUPLICATE_SELECTED_MESSAGE` ("Use the Replace Broker action on the Disposition…"). The user
sees a confusing refusal on a save that had nothing to do with selection, and it is 100% reproducible
but attributed to the wrong feature. **This is F-1 and it is the most likely single implementation
error in this tranche.** The falsifier is
`BovSubmissionSelectionGuardTest.autoSelectionSwap_isNotRefusedByTheGuard`.

**S-6 — 🔴 Someone "implements" requirement 6 and hides the Broker Activity Timeline org-wide.**
`dispositionBuyerTimeline` is a **sidebar FlexiPage card** with **no relationship to the matrix**
(F-3). The requirement is already satisfied. An implementer who takes it literally will add a
`visibilityRule` to `Disposition_Record_Page.flexipage-meta.xml` and hide the card everywhere — and
the FlexiPage failure modes on this exact page are documented and severe: **a FlexiPage deploy can
roll back and still report success**, and **enabling Dynamic Actions silently empties a page's action
bar**. The file's own comment (~line 399) lists the four `Submit_*` Dynamic Actions and their
criteria "byte for byte" precisely because a previous retrieve destroyed 476 lines of it.
**Instruction: no FlexiPage change in this tranche. None.**

**S-7 — ⚠ `Submit_Selected_Broker` does not hide while a broker approval is pending, and it never
did.** F-5: the documented `Approval_Pending__c` mirror onto the parent does not exist in any Apex, so
the Dynamic Action's `Approval_Pending__c EQUAL false` criterion is fed by a field the BOV path never
writes. This is **pre-existing and out of scope**, but it will surface during UAT of "Send Broker
Approval" and will look like this tranche caused it. Named here so it is attributed correctly.
⚠ It also means **four metadata files carry a false statement** about that mirror; whoever next edits
them should retract in place, not delete.

**S-8 — ⚠ Re-entrancy inflates the DML count invisibly.** The service's own `Database.update` re-fires
both before-context services and `afterUpdate`. It terminates naturally, but on a 251-row bulk load
the extra pass is `ceil(rows/200)` additional trigger firings. This repo has a measured incident where
exactly this cost 23 SOQL **and** 23 DML at production scale. **Assert the DML count, not just the end
state.**

**S-9 — ⚠ A preferred broker can be appointed via Replace Broker.** `_backupOptions`
(`bovComparisonMatrix.js:198-202`) filters only `isSelected !== true`. Unless it also excludes
preferred rows, the Replace Broker picker offers them — and the server has no reason to refuse, since
`replaceSelectedBroker` knows nothing about the flag. The result is a Selected broker with no BOV
amount entering `Broker_Finalize_Approval`. **One-line client fix; consider a server-side refusal in
`replaceSelectedBroker` as well — Q-5.**

---

## 10. Rollback

**Reversible in one deploy, at every wave, and the ordering is the reverse of [§7](#7-deploy-ordering).**

| To undo | Action | Risk |
|---|---|---|
| **Auto-selection only** (keep preferred brokers) | Remove the `BovAutoSelectionService` call from `BovSubmissionTriggerHandler.afterInsert/afterUpdate` and `DispositionTriggerHandler.afterUpdate`. Leave the service class deployed and unreferenced. | ⚠ **Selection state does not revert.** Whatever the algorithm selected stays Selected. This is fine — `Submission_Status__c` is user-editable in `DPEG_Disposition_Edit` and Replace Broker still works. |
| **Restore the Select Broker button** | Revert `bovComparisonMatrix.html` + `.js` + the 11 Jest tests from git. `handleSelectBroker` reaches `BovSubmissionService.replaceSelectedBroker`, which is **untouched by this design apart from one added field assignment** — so the server path is still intact and the revert is purely client-side. | Low. This is the main reason not to touch `replaceSelectedBroker`'s logic. |
| **Preferred brokers** | Revert the two VR amendments, the LWC changes, and `dispositionMain.html`. | ⚠ **Leave the two Checkbox fields deployed.** Deleting a custom field is delete + **manual Erase in Setup** before the name can be reused, and Salesforce refuses to delete a field Apex references. A dormant `false` checkbox is inert. |
| **History tracking (A7/A8)** | Revert. | ⚠ **Field history rows already captured are not deleted** and remain queryable. That is a feature, not a problem. |
| **Everything** | Revert the branch. | 🔴 **`Is_Manually_Appointed__c` will have been written `true` on some rows by `replaceSelectedBroker`.** Harmless once nothing reads it. Do not attempt a data cleanup. |

🔴 **The one thing that is NOT cleanly reversible: A7 (`enableHistory` on the object).** Turning
history tracking off and on again does not restore the gap. Decide once.

---

## 11. Gates — must be resolved before build

| # | Question | Why it blocks |
|---|---|---|
| **Q-1** | Confirm the two new API names: **`Is_Preferred_Broker__c`** and **`Is_Manually_Appointed__c`**. | An API-name change after deploy is delete + **manual Erase** + create, and a deleted name stays reserved until erased. Cheapest decision in the tranche; most expensive to change later. |
| **Q-2** | 🔴 **Rejection keeps selection LOCKED** ([§3.3](#33-hard-problem-3--the-lock)). Confirm. | The brief asks for the intended behaviour and says a rejected approval "parks the deal". I have proposed locked-until-a-human-acts. The opposite (unlock on rejection) is one predicate leg to delete, but changes the feature's meaning. |
| **Q-3** | 🔴 **Is `Broker__c` genuinely optional on a preferred broker?** I recommend **no** — a preferred broker with no broker Contact renders as an empty row ([§3.7](#37-hard-problem-7--the-reused-modal)). | Determines whether A6 exists. The user said "all the fields will be optional"; I am flagging the conflict rather than deciding it. |
| **Q-4** | What is the **title** of the preferred-brokers card, and should its **Status column** be hidden? Both instances currently read "BOV Comparison Matrix (n)", and a preferred row's pill always reads "Backup". | Not specified. I will not invent copy. |
| **Q-5** | Should `replaceSelectedBroker` **refuse** a preferred submission server-side, or is the client filter enough? ([§9 S-9](#9-what-could-silently-go-wrong)) | The service's own doctrine is *"the server must not depend on a client affordance for correctness"* — which argues for the server check. It is ~3 lines and one constant. |
| **V-1** | 🔴 **No org verification is possible from this agent.** Before wave 1, run the two wave-0 queries and confirm: (a) how many Dispositions carry an `Asking_Price__c`; (b) whether any disposition already has two Selected rows. | (a) decides whether the feature does anything at all in production; (b) decides whether the guard will immediately start refusing saves on live data. |
| **V-2** | Confirm `Submit_Selected_Broker` is the **only** path into `Broker_Finalize_Approval`. `DispositionService.initiateAndSubmit` submits from a modal and bypasses `DispositionApprovalService` on the sibling path. | If a second submit path exists, `initialSubmissionActions` still fires (it is route-independent), so the lock holds — but confirm rather than assume. |

---

## 12. Prompts for specialist agents

### 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md and agent-output/bov-autoselect-preferred-brokers.md (sections 5, 7, 9)
before starting. Org is usman-dpeg — PRODUCTION. Do NOT deploy; create metadata files only.

Create/amend exactly these eight items and nothing else. API version 67.0.

1. NEW objects/BOV_Submission__c/fields/Is_Preferred_Broker__c.field-meta.xml
   Checkbox, defaultValue false, trackHistory false, trackTrending false.
   Label "Preferred Broker".

2. NEW objects/BOV_Submission__c/fields/Is_Manually_Appointed__c.field-meta.xml
   Checkbox, defaultValue false, trackHistory false, trackTrending false.
   Label "Manually Appointed". SYSTEM FIELD — written only by
   BovSubmissionService.replaceSelectedBroker. Say so in the description.

3. permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml
   + Is_Preferred_Broker__c    readable=true, editable=true
   + Is_Manually_Appointed__c  readable=true, editable=FALSE

4. permissionsets/DPEG_Disposition_View.permissionset-meta.xml
   + both fields, readable=true, editable=false

5. objects/BOV_Submission__c/validationRules/BOV_Amount_Required_On_Submission.validationRule-meta.xml
   errorConditionFormula -> AND(NOT(Is_Preferred_Broker__c), ISBLANK(BOV_Amount__c))
   Nothing else in that file changes.

6. objects/BOV_Submission__c/validationRules/Broker_Required_On_Submission.validationRule-meta.xml
   ONLY IF gate Q-3 answered "yes". Same shape. If Q-3 is unanswered, SKIP and say so.

7. objects/BOV_Submission__c/BOV_Submission__c.object-meta.xml
   <enableHistory>false</enableHistory> -> true  (line 149)

8. objects/BOV_Submission__c/fields/Submission_Status__c.field-meta.xml
   + <trackHistory>true</trackHistory>

NON-NEGOTIABLE CONSTRAINTS:
- A PermissionSet deploy REPLACES the whole <fieldPermissions> set. DIFF BOTH FILES AGAINST
  HEAD FIRST. DPEG_Disposition_Edit is ALREADY MODIFIED in the working tree per git status —
  reconcile with those changes, do not overwrite them.
- Is_Manually_Appointed__c MUST be editable=false in DPEG_Disposition_Edit. It is a lock flag;
  a user who can clear it can un-lock a broker the principals decided on. Same reasoning as
  Disposition_Offer__c.Is_Selected__c and BOV_Submission__c.Approval_Status__c.
- Do NOT grant FLS on Approval_Pending__c. Both permission-set files carry an explicit
  "do not complete the set" instruction. Leave it alone.
- <description> is capped at 255 chars on CustomField and ValidationRule. Longer rationale goes
  in an XML comment INSIDE the root element — a comment ABOVE the root breaks `sf` at source
  conversion with a misleading "unable to find matching parent xml file" error.
- 🔴 DO NOT TOUCH flexipages/Disposition_Record_Page.flexipage-meta.xml OR
  layouts/BOV_Submission__c-BOV Submission Layout.layout-meta.xml. Both are out of scope.
  The "Broker Activity Timeline" requirement is ALREADY satisfied — that card is
  lwc/dispositionBuyerTimeline in the sidebar and has no relationship to the matrix.
- Deploy order when the time comes: fields -> permission sets -> validation rules. A VR
  referencing Is_Preferred_Broker__c cannot deploy before the field.
- No MCP api-context tooling is available here. Record mcp=unavailable and fall back to the
  per-type skills.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md, .claude/rules/apex-layering-rule.md, .claude/rules/bulk-test-rule.md and
agent-output/bov-autoselect-preferred-brokers.md IN FULL before starting — especially §3.2
(the guard), §3.3 (the lock), §3.5 (sharing) and §9 (silent failures). Org is usman-dpeg —
PRODUCTION. API version 67.0. Do NOT deploy.

Before writing anything, read these four files end to end:
  classes/BovSubmissionSelectionGuardService.cls
  classes/BovSubmissionTriggerHandler.cls   (esp. the ParentAdvanceWrites inner class)
  classes/BovSubmissionService.cls
  lwc/bovComparisonMatrix/bovComparisonMatrix.js

APEX
1. NEW classes/BovAutoSelectionService.cls — layer=service, `with sharing`.
   reselect(Set<Id> dispositionIds):
     - ONE selector call. Zero-query fast path when the set is empty.
     - LOCKED(disposition) if ANY of its submissions has Approval_Pending__c = true
       OR Approval_Status__c != null OR Is_Manually_Appointed__c = true. Locked -> return.
     - winner = first row with a NON-NULL BOV_Score__c AND Is_Preferred_Broker__c = false,
       under ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC.
     - No winner (all null / all preferred) -> return, ZERO DML. A null score is NOT a rank.
     - Winner already Selected and no other Selected row -> return, ZERO DML (idempotent).
     - 🔴 ONE Database.update(writes, true, AccessLevel.SYSTEM_MODE) carrying the demotion(s)
       AND the promotion in the SAME statement. Splitting it into two statements gets the save
       REFUSED by BovSubmissionSelectionGuardService — read that class's header before writing
       a line. Demoted rows also get Approval_Status__c = null.
     - 🔴 That statement lives in a `private without sharing` inner class holding ONLY it.
       Copy the shape and the header discipline of
       BovSubmissionTriggerHandler.ParentAdvanceWrites. Reason: BOV_Submission__c is OWD
       Private, this runs as whoever saved a BOV, and both disposition permission sets grant
       viewAllRecords with NO modifyAllRecords — so a sibling owned by someone else is refused
       at RECORD level and SYSTEM_MODE does not lift that.
     - allOrNone = TRUE (diverging from ParentAdvanceWrites — a half-applied swap leaves two
       Selected rows). INSPECT the SaveResults into a @TestVisible static
       List<String> lastRunSelectionFailures.
     - @TestVisible static Boolean suppressReentry.
   🔴 DO NOT call BovSubmissionService.replaceSelectedBroker. It asserts a human permission,
   requires a reason, and unconditionally inserts a BOV_Broker_Change__c row. Four blockers,
   each sufficient — §3.2 of the design.
   🔴 Write NO BOV_Broker_Change__c row from this service. §3.2 explains why.

2. classes/BovSubmissionSelector.cls
   + selectSelectionContextByDispositionIds(Set<Id>), WITH SYSTEM_MODE, justified at its OWN
     declaration. SELECT Id, Disposition__c, Submission_Status__c, BOV_Score__c,
     Approval_Pending__c, Approval_Status__c, Is_Manually_Appointed__c, Is_Preferred_Broker__c,
     Broker_Firm__c. ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC.
     SYSTEM_MODE is forced by Approval_Pending__c, which has NO FLS in ANY permission set by
     design — a USER_MODE read throws "No such column" for everyone including admins.
   + Is_Preferred_Broker__c in selectByDispositionId's SELECT.
     🔴 That method is WITH USER_MODE. This is an FLS CHANGE. The permission-set grants MUST
     be live first or getSubmissions throws and the WHOLE matrix disappears for everyone.
   🔴 DO NOT widen selectSelectedByDispositionIds — its WHERE is the guard's counting predicate.
   Re-count the SYSTEM_MODE tally in the class header; that line has decayed three times.

3. classes/BovSubmissionService.cls — ONE change only: add
   Is_Manually_Appointed__c = true to the challenger's EXISTING write (~line 328). Zero new
   DML, zero new SOQL. Touch nothing else in that method.

4. classes/BovSubmissionTriggerHandler.cls — add afterInsert(); call BovAutoSelectionService
   from afterInsert and afterUpdate, keyed on BOV_Amount__c / Commission_Rate__c /
   Days_To_Market__c / Submission_Status__c / Is_Preferred_Broker__c changing (every insert
   qualifies). handleApprovedSelections is UNTOUCHED and stays first.
   RETRACT IN PLACE (do not delete) the header's job/context count.

5. triggers/BovSubmissionTrigger.trigger — add `after insert` to the context list.
   RETRACT IN PLACE the "⚠ NO `after insert`. Nothing needs it" comment.

6. classes/DispositionTriggerHandler.cls — in the EXISTING afterUpdate, call
   BovAutoSelectionService when Asking_Price__c changed. Zero-cost fast path otherwise.
   No trigger file change (after update already declared). This hook is MANDATORY, not
   optional: the score is parent-derived, so an asking-price edit re-ranks every child with
   zero child DML, and without this hook no broker is ever auto-selected on a sale that was
   priced after its BOVs arrived — which is the primary path (§3.1).

7. classes/BovController.cls — BovRow + `@AuraEnabled public Boolean isPreferred`, mapped in
   getSubmissions. No signature change, no new method.

LWC
8. lwc/bovComparisonMatrix — DELETE the Select Broker button (.html:19-25), canSelectBroker
   (.js:183-185) and handleSelectBroker (.js:315-327). ADD an "Add Preferred Broker" button
   opening c/bovAddResponseModal with label "Add Preferred Broker" and isPreferred=true.
   ADD @api preferredOnly and @api hideActions (both default false) and filter in the `rows`
   getter. ALSO exclude preferred rows from _backupOptions.
   🔴 DO NOT touch the un-destructured `_wired` wire result or _openBrokerModal — the class
   header explains why an innocuous edit there silently kills every refresh.

9. lwc/bovAddResponseModal — ADD @api isPreferred. It drives: the modal header label; the six
   `required` attributes (conditional, default path unchanged); forcing
   Is_Preferred_Broker__c = true AND Submission_Status__c = 'Backup' inside withParent(); and
   REMOVING the Submission_Status__c input on the preferred path (a preferred row saved as
   'Selected' would enter Broker_Finalize_Approval and appoint a broker with no BOV amount).
   withParent() is the ONLY correct injection point — both submit paths funnel through it.
   Note: the six `required` attributes are hand-written in this template and are NOT inherited
   from the page layout, so NO LAYOUT CHANGE IS NEEDED.

10. lwc/dispositionMain/dispositionMain.html — add a second
    <c-bov-comparison-matrix record-id={recordId} preferred-only hide-actions> ABOVE the
    existing tag, inside if:true={isBovOutreach}. Leave the existing tag byte-identical.
    Do NOT touch the FlexiPage — the matrix is not a FlexiPage component (isExposed=false,
    no targetConfigs) and the Broker Activity Timeline requirement is already satisfied.

TESTS — see §8 of the design for the full list. Non-negotiable:
- BovSubmissionSelectionGuardTest gains autoSelectionSwap_isNotRefusedByTheGuard. Do NOT
  delete existingReplaceSelectedBrokerService_stillSucceeds.
- 251-record bulk insert AND update on the trigger path. 251 rows span TWO chunks, so
  auto-selection runs twice — assert the END STATE plus a CONSTANT DML count, not one flip.
- A NON-OWNER test proving the `without sharing` escape works. Assign DPEG_Disposition_Edit
  (viewAllRecords, no modifyAllRecords), following the existing persona fixture in
  TestDataFactory.
- 🔴 TestDataFactory needs a NEW fixture setting Asking_Price__c on the disposition. Without
  it every score is null and every auto-selection test is VACUOUS. Do NOT change
  createBovSubmissions' default — that would flip negative fixtures across the whole suite.
- 8 Jest tests in bovComparisonMatrix.test.js break hard (lines 441, 523, 554, 573, 594, 627,
  644, 669) and 3 more (465, 477, 490) will pass VACUOUSLY. Fix all eleven. Re-home the
  null-score em-dash and duplicate-broker assertions onto the Replace path — those behaviours
  still exist.
```

---

## 13. Execution order

```
Gate Q-1…Q-5 + V-1/V-2   (user + org query)
      ↓
salesforce-admin         A1-A8  (fields → FLS → VRs → history tracking)
      ↓
salesforce-developer     Apex (selector → service → handlers → trigger → controller)
                         then LWC (modal → matrix → dispositionMain)
      ↓
salesforce-unit-testing  BovAutoSelectionServiceTest + the guard's twin test +
                         the 11 Jest repairs + the TestDataFactory fixture
      ↓
salesforce-code-review
      ↓
salesforce-devops (waves 1-6, in order) + salesforce-documentation
```

**Admin must complete before Developer.** Not a preference: `selectByDispositionId` is `WITH
USER_MODE`, and Apex that selects `Is_Preferred_Broker__c` before its FLS grant exists throws
`System.QueryException: No such column` and blanks the entire BOV Comparison Matrix for every user.
