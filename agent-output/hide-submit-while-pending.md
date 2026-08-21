# Design Requirements — Hide the four Disposition Submit-for-Approval actions while their approval is pending

**Date:** 2026-08-21
**Branch:** `feature/acquisitions-fsd-tranche-1`
**Design agent run:** requirements analysis only. No metadata, Apex, LWC or scripts were modified by this run.
**Deliverable path:** `agent-output/hide-submit-while-pending.md` (this file)

---

## 🎯 What the user requested (verbatim)

> "Once the submit selected broker is initiated we need to hide that button until the broker is rejected."

**Confirmed scope, settled with the user before this run and not re-opened here:**

1. All **four** Submit-for-Approval quick actions on `Disposition__c`, not just `Submit_Selected_Broker`.
2. Hide the button while **its** approval is genuinely pending; show it again if the request comes back — by rejection **or by recall**.
3. **No pending indicator.** Just hide it.

| Quick action | Stage gate today | Approval submitted | Approval TARGET record |
|---|---|---|---|
| `Submit_Sale_Decision` | `Disposition Readiness` | `Sale_Decision_Approval` | `Disposition__c` |
| `Submit_Selected_Broker` | `BOV Outreach` | `Broker_Finalize_Approval` | the Selected **`BOV_Submission__c`** |
| `Submit_Broker_Selection` | `Broker Selection` + off-market | `Broker_Selection_Approval` | `Disposition__c` |
| `Submit_Closing_Approval` | `Closing` + wire complete | `Closing_Approval` | `Disposition__c` |

Target column verified against `force-app/main/default/classes/DispositionApprovalService.cls:265-336` (the branch table at `:228-254` and the code at `:284-329`).

---

## 🔵 SECTION 0 — YOUR THREE STATED PREMISES, VERIFIED

All three are **correct**. Two need a material correction to the reasoning behind them, and the third needs a stronger disqualification than the one you offered.

### 0.1 ✅ CONFIRMED — the server already refuses a double-submit

`DispositionApprovalService.cls:331-333`:

```apex
if (!ProcessInstanceSelector.selectPendingByTargetId(targetId).isEmpty()) {
    throw new ApprovalException(ALREADY_PENDING_MESSAGE);
}
submit(targetId);
```

`ALREADY_PENDING_MESSAGE` is defined at `:209-210` as `'This record is already pending approval.'`.
`ProcessInstanceSelector.selectPendingByTargetId` (`force-app/main/default/classes/ProcessInstanceSelector.cls:30-40`) is `WHERE TargetObjectId = :targetObjectId AND Status = 'Pending' WITH USER_MODE`.

**Your header quote is accurate and load-bearing.** `DispositionApprovalService.cls:251-254`:

> "⚠ THE PENDING GATE IS APPLIED TO THE TARGET, NOT TO THE DISPOSITION. On the `BOV Outreach` branch the target is the submission, so a Disposition with an unrelated pending approval does not block a broker submission, and a re-click on an already-submitted broker is refused. Gating the Disposition instead would get both cases wrong."

⇒ **This is a UX change layered over a working guard, and the new UI flag MUST reproduce the same target-scoping.** A single "any approval pending anywhere" flag on the Disposition would hide the wrong buttons. In practice this costs nothing extra, because the four approvals' entry stages are mutually exclusive (`Disposition Readiness` / `BOV Outreach` / `Broker Selection` / `Closing`) and each rule already AND-s its own stage, so one flag AND-ed with the existing stage criterion is target-scoped **by construction**. That is a property of this specific stage layout, not a general truth — record it, because a fifth approval sharing a stage would break it silently.

🔴 **Consequence for the deliverable: `ProcessInstanceSelector` and `DispositionApprovalService` need NO change.** The server guard stays exactly as it is. It is now the second line of defence behind the hidden button, which is the correct arrangement — the FlexiPage rule is a UX affordance and any direct `@AuraEnabled` call bypasses it, as `DispositionApprovalService.cls:74-78` already states.

### 0.2 ✅ CONFIRMED — a FlexiPage visibility rule can only read fields on the record itself

Verified by reading every `<visibilityRule>` in `force-app/main/default/flexipages/Disposition_Record_Page.flexipage-meta.xml` (14 rules, lines 277-452 in the action list, plus `:650-656`, `:752-774`, `:793-815`). Every single `leftValue` in the file is one of exactly two forms:

- `{!Record.<FieldApiName>}` — `Disposition_Stage__c`, `Is_On_Market__c`, `Wire_Verification_Completed__c`
- `{!$Permission.CustomPermission.Disposition_Deal_Actions}`

There is **no** approval-state token, no `{!Record.<child>__r...}`, and no spanning `{!Record.RecordType...}` anywhere. The page's own comment at `:180` records that spanning to `RecordType` was **avoided as unverified on this org**, which is exactly why the formula checkbox `Is_On_Market__c` was created — an in-repo precedent for "when the rule needs a fact the rule cannot reach, materialise it as a field on the record".

**Additional confirmation that a formula cannot substitute for a stored field here:** a formula on `Disposition__c` cannot reach *down* to `BOV_Submission__c` (child), and `ProcessInstance` is not reachable from `Disposition__c` by any relationship a formula can traverse. Approval state is not exposed to the formula engine at all. ⚠ This last point is a platform fact I could not verify from a file in this repo — it is stated as a constraint, not as a measurement, and it is folded into gate **G2** below rather than assumed.

⇒ **A stored field on `Disposition__c` is required.** See §1 for the three alternatives that were considered and rejected before accepting that.

### 0.3 🔴 CONFIRMED, AND STRONGER THAN YOU PUT IT — reusing `Approval_Advance_Pending__c` is wrong three independent ways

Your suspicion is right. Here is the proof, each item from a file:

**(a) It fires on the wrong EVENT.** `objects/Disposition__c/fields/Approval_Advance_Pending__c.field-meta.xml:10-16`:

> "WHAT WRITES IT: the workflow field update `Set_Approval_Advance_Pending` … fired as a `finalApprovalActions` entry by THREE approval processes … **It only ever writes TRUE.**
> WHAT CLEARS IT: `DispositionApprovalAdvanceQueueable`, in the same DML that writes the new stage. Nothing else clears it."

It goes true on **final approval** and is cleared milliseconds later by an async job. It is never true while an approval is *pending*. It is the wrong signal, not a reusable one.

**(b) It has NO FLS anywhere, and a rule reading an unreadable field evaluates FALSE.** Same file, `:33-39`:

> "🔴 THIS FIELD DELIBERATELY HAS NO FIELD-LEVEL SECURITY IN ANY PERMISSION SET, AND THAT IS NOT AN OVERSIGHT TO 'FIX' … Adding a grant would put a machine flag on a user's screen and invite a hand-edit that would fire a spurious stage advance."

Confirmed independently: `DPEG_Disposition_View.permissionset-meta.xml:88-92` and `DPEG_Disposition_Edit.permissionset-meta.xml:132-136` both carry the matching "Do not 'complete the set' by adding it" instruction. Combined with the page's own warning at `flexipages/Disposition_Record_Page.flexipage-meta.xml:124-129` ("A visibility rule on an unreadable field evaluates FALSE and hides the action with NO error anywhere"), a rule of the form `Approval_Advance_Pending__c EQUAL false` would evaluate **false for every user in the org** and hide all four buttons permanently. Reuse would therefore require reversing an explicitly-argued security decision.

**(c) D-1 REQUIRES it to be left true on a failed advance — which is the exact permanent-hide trap.** `docs/2026-08-19-disposition-flow-redesign.md:96-100`:

> "**A refusal leaves the semaphore `true` by design, not by omission.** … any refusal … leaves both the stage and the flag exactly where they were"

and the live example at `docs/2026-08-19-disposition-flow-redesign.md:438-452` — **two real records (`DISP-0009`, `DISP-0010`) are expected to strand the semaphore true** at `Closing`. Wiring the button to that flag would hide `Submit_Closing_Approval` forever on exactly those two records.

⇒ **A new, separate field. Do not reuse.** Both fields will then live on the same object with confusingly similar names; §4 mandates a cross-reference banner in each file, following the precedent this repo already set for `BOV_Submission__c.Approval_Status__c` vs `Submission_Status__c` (`docs/2026-08-19-disposition-flow-redesign.md:181` — "A **second, distinct** field … do not conflate them").

---

## 🔴 SECTION 1 — IS A STORED FIELD NECESSARY? FOUR ALTERNATIVES, ALL REJECTED

| # | Alternative | Verdict and evidence |
|---|---|---|
| A1 | **Read approval state directly in the visibility rule** | ❌ Impossible. §0.2 — no such token exists in any of the 14 rules on this page; the file's only two `leftValue` forms are `{!Record.…}` and `{!$Permission.CustomPermission.…}`. |
| A2 | **Formula field deriving pending state** | ❌ Impossible for both branches. Cannot reach a child (`BOV_Submission__c`) and cannot reach `ProcessInstance`. The repo's own workaround for an unreachable fact is a materialised field — `Is_On_Market__c` (`flexipages/Disposition_Record_Page.flexipage-meta.xml:180`, `docs/2026-08-19-disposition-flow-redesign.md:180`). Verify the `ProcessInstance` half under gate **G2**. |
| A3 | **Let the LWC hide the button** | ❌ Structurally impossible for these four. `dispositionSubmitForApproval` is a **headless `RecordAction`** (`docs/2026-08-19-disposition-flow-redesign.md:301` — "Headless `RecordAction` backing all four `Submit_*` quick actions"). A headless action has no rendering surface; the platform renders the button from the quick action, and the LWC only runs *after* the click. Achieving this in an LWC means building a **new visible card** and deleting four quick actions — a far larger change than requested, and it still requires the FlexiPage edit. |
| A4 | **Do nothing — rely on the server refusal** | ❌ This is the status quo the user rejected. Worth stating only because it is the fallback if gate **G1** cannot be resolved: today the click is refused with an authored, user-safe message, so the current behaviour is *safe but noisy*, not broken. |

⇒ **A stored Checkbox on `Disposition__c` is the only mechanism available.** That conclusion is forced, not preferred.

---

## 🔴 SECTION 2 — THE TWO TRAPS, SOLVED

### 2.1 TRAP 2 first, because it determines the answer to TRAP 1

**The lock is total, and it rules out every Apex-based setter and clearer on the Disposition.**

`triggers/BovSubmissionTrigger.trigger:35-41` states this in measured terms:

> "🔴 AND THE LOCK ARGUMENT NOW CUTS THE OTHER WAY … any post-save second DML against a submission with a pending approval throws `ENTITY_IS_LOCKED`, and **a Queueable does not fix it (a pending approval outlives the job)**."

and `classes/BovSubmissionTriggerHandler.cls:34-39`:

> "`Disposition__c` is the entry object of three approval processes, all `recordEditability = AdminOnly`, so a write to a Disposition WHILE ONE OF ITS OWN APPROVALS IS PENDING throws `ENTITY_IS_LOCKED` — and **`AccessLevel.SYSTEM_MODE` does not lift a lock**."

⇒ **Nothing in Apex — synchronous, `SYSTEM_MODE`, Queueable, or Finalizer — can write to a `Disposition__c` while one of its own approvals is pending.** The entire pending window is unwritable by code.

**The one writer that is not blocked is the approval process's own field update.** This repo already proves it, twice:

- `Sale_Decision_Approval` fires `Set_Approval_Advance_Pending` on `Disposition__c` as a `finalApprovalActions` entry (`approvalProcesses/Disposition__c.Sale_Decision_Approval.approvalProcess-meta.xml:95-100`) — a write to the very record it locked.
- `Broker_Finalize_Approval` fires `Set_Broker_Approval_Rejected` as a `finalRejectionActions` entry on its own `AdminOnly`-locked `BOV_Submission__c` (`approvalProcesses/BOV_Submission__c.Broker_Finalize_Approval.approvalProcess-meta.xml:111-116`, `:120`).

So **approval and rejection actions are proven in-repo** to write a locked record. `initialSubmissionActions` and `recallActions` are **not** used anywhere in this repo (grep across `force-app/main/default/approvalProcesses/**` returns zero hits for either element) — that is escalated as gate **G1**, not assumed.

**Ordering answer, stated plainly:** there is **no ordering problem to solve**, because there is no Apex write to order. The flag is set by the approval process's `initialSubmissionActions` *as part of* `Approval.process()`, inside the same transaction as `DispositionApprovalService.submit()` (`:487-491`), and is cleared by the same process's terminal actions. Apex never touches the field on the Disposition-target branches.

⚠ **And this is why the "write it in Apex before `Approval.process`" shape is wrong even though it would technically work.** It has three holes the declarative shape does not:

1. `DispositionService.initiateAndSubmit` submits `Sale_Decision_Approval` from the Sell Meter modal, on a route that never touches `DispositionApprovalService` (`docs/2026-08-19-disposition-flow-redesign.md:280`, and the approval file's own `:47-49`). An Apex setter would have to be added there too.
2. The platform's generic Submit button was dropped from *this page* (`flexipages/Disposition_Record_Page.flexipage-meta.xml:103-109`) but is still reachable from list views, Classic, mobile and the API. `initialSubmissionActions` covers every route by construction.
3. It reproduces the shape of the incident you flagged — Apex writing on behalf of an approval flow. `initialSubmissionActions` is not Apex and does not run as anybody's CRUD.

🔴 **The `flow-runinmode-runs-as-approver` shape is NOT repeated by this design.** No Flow is introduced. No Apex runs in the approver's context on the Disposition-target branches. The one Apex write this design does add (§5, BOV branch) runs in an `after update` trigger on `BOV_Submission__c` that **already exists and already writes the parent Disposition in exactly this situation** with `Database.update(parentUpdates, false, AccessLevel.SYSTEM_MODE)` (`classes/BovSubmissionTriggerHandler.cls:280-295`) — a shape whose `allOrNone = false` and `SYSTEM_MODE` choices are argued in that file at `:280-294` precisely so an approver's CRUD cannot roll back an approval.

### 2.2 TRAP 1 — RECALL

**Exactly how the flag gets cleared on recall: `<recallActions>` on the approval process, firing a workflow field update that writes the flag to false.**

`recallActions` is the ApprovalProcess element that fires when a submitter recalls. It is the **only** hook for that event — a recall fires no rejection action, produces no `ProcessInstance` status the record can see, and there is no trigger context for it. There is no alternative mechanism; if `recallActions` is unavailable the design cannot satisfy the requirement and the fallback is A4 (§1).

**All five processes set `allowRecall = true` and none currently carries `recallActions`:**

| Approval process | `allowRecall` | Has `recallActions` today |
|---|---|---|
| `Disposition__c.Sale_Decision_Approval` | `:59` true | ❌ none |
| `Disposition__c.Broker_Selection_Approval` | `:100` true | ❌ none |
| `Disposition__c.Closing_Approval` | `:76` true | ❌ none |
| `BOV_Submission__c.Broker_Finalize_Approval` | `:63` true | ❌ none |
| `Disposition_Offer__c.Offer_Selection_Approval` | `:61` true | ❌ none (out of scope) |

🔴 **Recall is not hypothetical on this page — it is a feature that was deliberately made reachable three days ago.** `flexipages/Disposition_Record_Page.flexipage-meta.xml:158-167` (code review finding C-3) added the Approval History component *specifically* so `allowRecall = true` stopped being unreachable from the UI:

> "All five set `allowRecall=true` and `recordEditability=AdminOnly`, so a submitted record LOCKS, and the Recall button lives ONLY in the Approval History related list. With no such list on the page, `allowRecall=true` was unreachable from the UI"

and `Offer_Selection_Approval`'s own comment (`:46`) states records "must therefore be recalled first". **Recall is now a routine, one-click, expected operation on this page.** A design that leaves the button hidden after a recall would break a workflow the previous change went out of its way to enable — which is precisely your "strictly worse than the problem being fixed".

⚠ **Deliberate corollary: the requirement is NOT "hidden until rejected".** It is "hidden while an approval is genuinely pending", and the flag's lifetime is exactly the `ProcessInstance.Status = 'Pending'` window. All four terminal transitions clear it (§6).

---

## 🔴 SECTION 3 — BLOCKING GATES (resolve before any file is written)

### G1 — 🔴 HIGHEST RISK: `initialSubmissionActions` and `recallActions` are UNPROVEN XML shapes in this repo

**I could not resolve this.** The `salesforce-api-context` MCP tools are **not in this agent's tool set** — I have file-system tools only, so no real attempt was possible and I will not guess. Grep across all seven files in `force-app/main/default/approvalProcesses/` returns **zero** occurrences of `initialSubmissionActions` and **zero** of `recallActions`. There is nothing in this repo to copy.

What I *can* state from the files, as candidate shape only:

- `finalApprovalActions` / `finalRejectionActions` both take a repeating `<action>` child with `<name>` + `<type>FieldUpdate</type>` (`Sale_Decision_Approval:95-100`, `Broker_Finalize_Approval:104-116`). `initialSubmissionActions` and `recallActions` are the same `ApprovalAction` type and are expected to take the identical child shape.
- **Element order in these files is alphabetical** (verified by reading `Sale_Decision_Approval` end to end: `active`, `allowRecall`, `allowedSubmitters`, `approvalPageFields`, `approvalStep`, `description`, `enableMobileDeviceAccess`, `entryCriteria`, `finalApprovalActions`, `finalApprovalRecordLock`, `finalRejectionRecordLock`, `label`, `processOrder`, `recordEditability`, `showApprovalHistory`). On that pattern `initialSubmissionActions` goes **after `finalRejectionRecordLock`, before `label`**, and `recallActions` goes **after `processOrder`, before `recordEditability`**. ⚠ Alphabetical ordering is an *observation about five files*, not a schema reading. Confirm it.

**Required resolution protocol — assign to `salesforce-admin`, must complete before ANY approval-process file is edited:**

1. Load the matching approval-process skill AND call `salesforce-api-context` (`get_metadata_type_fields` / `get_metadata_type_fields_properties` on `ApprovalProcess` → `initialSubmissionActions`, `recallActions`). Record `mcp=complete` + `mcp_tools=<list>`, or `mcp=unavailable` after a **real** attempt.
2. Prove the shape on **ONE** process first — `Sale_Decision_Approval`, the simplest (single entry criterion, one existing final action) — via a **check-only dry-run** against `usman-dpeg`.
3. 🔴 **Read the process back from the org and prove the BEHAVIOUR, not the deploy.** Submit a test disposition, confirm the flag went true; **recall it**, confirm the flag went false. Deploy success is not proof — this repo has measured green-but-inert deploys on FlexiPages (`flexipages/Disposition_Record_Page.flexipage-meta.xml:151-153`, `:264-267`) and on a settings tree.
4. Only then replicate to the remaining three.

⚠ **The failure mode if this is guessed wrong is the dangerous direction.** A `recallActions` block that deploys but never fires produces exactly the permanent-hide defect this design exists to prevent, on an unlocked record with no route to resubmit — and nothing logs it. If step 3's recall test cannot be performed, **do not ship**; fall back to A4.

### G2 — Confirm no formula/rollup route exists before accepting a new field

Recommendation is **new field** (§1). But one claim in §0.2 is a platform assertion I could not verify from a file: that approval state is unreachable from the formula engine. Ask `salesforce-admin` to confirm during G1 (the same MCP session). If a formula-reachable approval-state field *does* exist on this org's `Disposition__c`, **the entire A-1/A-2/A-3/A-4 metadata below collapses to one formula field and the FlexiPage edit**, and this design should be re-cut.

⚠ Separately confirmed and **not** a route: `BOV_Submission__c.Disposition__c` is `<type>Lookup</type>`, not Master-Detail (`objects/BOV_Submission__c/fields/Disposition__c.field-meta.xml:11`). That kills **both** the roll-up-summary route and the cross-object workflow-field-update route for the BOV branch, and is why §5's Apex mirror exists.

### G3 — Field API name (user decision, one line)

Recommended: **`Approval_Pending__c`** on `Disposition__c`, and **`Approval_Pending__c`** on `BOV_Submission__c`.

- ⚠ It does not strictly satisfy `ARCHITECTURE.md` §1's Boolean convention (`Is_`/`Has_` prefix, or `<Subject>_<PastParticiple>`) — "Pending" is a present participle. The sibling `Approval_Advance_Pending__c` already carries the same deviation, so the recommendation buys **consistency with the one field a reader will inevitably compare it to** at the cost of a documented convention deviation.
- Strict-conformance alternative: `Is_Approval_Pending__c`.
- 🔴 Whichever is chosen, both field files must carry a **mutual disambiguation banner** — see A-1's mandate.

### G4 — What happens to records with an approval already pending at deploy time?

A new Checkbox defaults `false` (the shape used by `Approval_Advance_Pending__c.field-meta.xml:50`). Any Disposition or BOV submission **already pending at cutover** will read `false` and show its Submit button. The server still refuses with `ALREADY_PENDING_MESSAGE`, so this is a **UX regression on a finite, transient set, not a correctness defect** — and it self-heals the moment that approval terminates.

Two options; the user picks:
- **(a) Accept it.** Simplest. The population is small and self-clearing.
- **(b) Recall pending approvals before deploying** — which is already the standing instruction for a Disposition deploy (`flexipages/Disposition_Record_Page.flexipage-meta.xml:165-167`: "The deploy plan's own risk item requires recalling pending Disposition approvals before deploying").

⚠ **Do NOT propose a backfill script that sets the flag true from `ProcessInstance`.** The Disposition-target rows are locked and the write would throw `ENTITY_IS_LOCKED` (§2.1) — a script that cannot possibly succeed on the exact rows it targets.

---

## 🔵 ADMIN WORK (`salesforce-admin`)

### A-1 — Two new Checkbox fields

| # | File to create | Field | Type | Default |
|---|---|---|---|---|
| 1 | `force-app/main/default/objects/Disposition__c/fields/Approval_Pending__c.field-meta.xml` | `Approval_Pending__c` | Checkbox | `false` |
| 2 | `force-app/main/default/objects/BOV_Submission__c/fields/Approval_Pending__c.field-meta.xml` | `Approval_Pending__c` | Checkbox | `false` |

Copy the file shape from `objects/Disposition__c/fields/Approval_Advance_Pending__c.field-meta.xml` (`fullName`, `defaultValue`, `description`, `inlineHelpText`, `label`, `trackHistory`, `trackTrending`, `type`). ⚠ Keep the XML comment **inside** the root element — a comment above `<CustomField>` breaks `sf` at source conversion (that file's own `:3-6`).

🔴 **Both files must carry a mutual disambiguation banner.** Required content, per the `Approval_Status__c` / `Submission_Status__c` precedent:

- On `Disposition__c.Approval_Pending__c`: *"A SECOND, DISTINCT field from `Approval_Advance_Pending__c` — do not conflate them. This one is TRUE while an approval is PENDING and is written only by approval `initialSubmissionActions` / `finalApprovalActions` / `finalRejectionActions` / `recallActions`, plus `BovSubmissionTriggerHandler` for the BOV branch. `Approval_Advance_Pending__c` is the D-1 auto-advance semaphore, goes true on FINAL APPROVAL, and is cleared by a Queueable."*
- On `Approval_Advance_Pending__c.field-meta.xml`: add the reciprocal one-line pointer. **Additive only — do not rewrite or delete any existing text in that file**, per this repo's quote-and-retract convention.

Also state in the `Disposition__c` file: it is **not on any page layout and not on any FlexiPage `fieldInstance`** — read only by the four Dynamic Actions rules — and name the four actions, mirroring the checkable-count convention at `DPEG_Disposition_View.permissionset-meta.xml:94-97`.

⚠ **Do NOT add a validation rule, a trigger guard, or a "must not be hand-edited" enforcement.** Not requested; read-only FLS (A-2) is the control.

### A-2 — FLS: read-only in exactly two permission sets

| Permission set | Grant |
|---|---|
| `force-app/main/default/permissionsets/DPEG_Disposition_View.permissionset-meta.xml` | `Disposition__c.Approval_Pending__c` — `readable=true`, `editable=false` |
| `force-app/main/default/permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml` | same |

**Verified grant matrix for the precedent field `Is_On_Market__c`** (the field the four sibling rules already read): granted read-only in `DPEG_Disposition_View:811-815` and `DPEG_Disposition_Edit:1522-1526`, and **nowhere else**. `DPEG_Admin_Access` grants `Disposition__c.Wire_Verification_Completed__c` (`:165`) but **not** `Disposition_Stage__c` (grep: `Disposition__c.Disposition_Stage__c` appears only in the two Disposition sets, `View:723` and `Edit:1434`) — so an Admin-Access-only user already cannot satisfy the existing stage criteria on any of these four rules. Mirroring `Is_On_Market__c` exactly is therefore correct and complete.

🔴 **This is the introduced-bug hazard the user named, and it is real.** `flexipages/Disposition_Record_Page.flexipage-meta.xml:124-129`:

> "🔴 THE RULES READ TWO NEW FIELDS, AND FLS IS LOAD-BEARING … A visibility rule on an unreadable field evaluates FALSE and hides the action with NO error anywhere … those two files MUST NOT LAG THIS ONE."

With the polarity chosen in A-4 (`EQUAL false`), a missing grant hides **all four buttons for everyone, silently and permanently** — the same symptom as the defect being fixed. **The two permission sets must land WITH OR BEFORE the FlexiPage, never after.**

⚠ `BOV_Submission__c.Approval_Pending__c` needs **no** FLS grant — nothing in the UI reads it and its only readers are a workflow field update and a trigger, both system context. State that decision in the field file explicitly so a later reviewer does not "complete the set" (same wording as `DPEG_Disposition_View:88-92`).
⚠ A PermissionSet deploy **replaces `fieldPermissions` wholesale** (`DPEG_Disposition_View:446`). Insert one block each, immediately after the `Disposition__c.Is_On_Market__c` block, and diff against `HEAD` to confirm zero deletions before deploying.

### A-3 — Workflow field updates (4 new, across 2 files)

| File | New `fieldUpdates` | Field | `literalValue` |
|---|---|---|---|
| `force-app/main/default/workflows/Disposition__c.workflow-meta.xml` | `Set_Approval_Pending` | `Approval_Pending__c` | `1` |
| same | `Clear_Approval_Pending` | `Approval_Pending__c` | `0` |
| `force-app/main/default/workflows/BOV_Submission__c.workflow-meta.xml` | `Set_Broker_Approval_Pending` | `Approval_Pending__c` | `1` |
| same | `Clear_Broker_Approval_Pending` | `Approval_Pending__c` | `0` |

Copy the exact element set from `workflows/Disposition__c.workflow-meta.xml:45-55` — `fullName`, `description`, `field`, `literalValue`, `name`, `notifyAssignee=false`, `operation=Literal`, `protected=false`, `reevaluateOnChange=false`. Checkbox literal `1`/`0` is confirmed by `Set_Approval_Advance_Pending`'s `<literalValue>1</literalValue>` (`:49`).

🔴 **`reevaluateOnChange` stays `false`.** Both workflow files argue this at length (`Disposition__c.workflow-meta.xml:32-35`) — it re-evaluates workflow *rules*, and there are none. Triggers re-run regardless.
🔴 **Do NOT add a `<rules>` element to either file.** Both files carry an explicit prohibition (`Disposition__c:17-18`, `BOV_Submission__c:12-14`) — an active rule writing these flags would fire on an ordinary edit.

### A-4 — FlexiPage: four visibility rules, exact change

File: `force-app/main/default/flexipages/Disposition_Record_Page.flexipage-meta.xml`

🔴 **EDIT THE XML DIRECTLY. DO NOT OPEN THIS PAGE IN APP BUILDER AND DO NOT TOUCH `enableActionsConfiguration`.** The file's own `:216-230` records that an App Builder save on 2026-08-19 silently dropped `Edit`/`Clone`/`Delete` from the twelve-item action list, org-wide, and that *opening the page in App Builder at all* is the trigger. This has now happened twice.

The change per action is: **append one `<criteria>` block and renumber `<booleanFilter>`.** The new criterion, byte-identical in all four:

```xml
<criteria>
    <leftValue>{!Record.Approval_Pending__c}</leftValue>
    <operator>EQUAL</operator>
    <rightValue>false</rightValue>
</criteria>
```

⚠ Lowercase `false`, matching the four existing `Is_On_Market__c` criteria in this file (`:319`, `:340`, `:377`, `:408`). Do **not** use `NE`/`true` — the `EQUAL` + lowercase-boolean form is the one proven on this page; `NE` against a boolean is not.

| # | `valueListItems` value | Line | `booleanFilter` today | `booleanFilter` after | New criterion index |
|---|---|---|---|---|---|
| 1 | `Disposition__c.Submit_Sale_Decision` | `:276` | `1 AND 2` (`:278`) | `1 AND 2 AND 3` | 3, appended after `:288` |
| 2 | `Disposition__c.Submit_Selected_Broker` | `:292` | `1 AND 2` (`:294`) | `1 AND 2 AND 3` | 3, appended after `:304` |
| 3 | `Disposition__c.Submit_Broker_Selection` | `:308` | `1 AND 2 AND 3` (`:310`) | `1 AND 2 AND 3 AND 4` | 4, appended after `:325` |
| 4 | `Disposition__c.Submit_Closing_Approval` | `:434` | `1 AND 2 AND 3` (`:436`) | `1 AND 2 AND 3 AND 4` | 4, appended after `:451` |

**Append the new criterion LAST in each rule** (after the `Disposition_Deal_Actions` criterion), so every existing index keeps its meaning and the diff is purely additive.

🔴 **DO NOT TOUCH, in this or any other rule on this page:**
- The `{!$Permission.CustomPermission.Disposition_Deal_Actions}` criterion in any of the four — three-segment form only; `{!$Permission.<Name>}` and `{!$CustomPermission.<Name>}` are both rejected by the Metadata API, measured 2026-08-12 (`:118-120`).
- `Select_Offer`'s `(1 OR 2) AND (3 OR 4) AND 5` filter (`:389`) and its deliberately duplicated criterion 1/3 (`:131-144`). **`Select_Offer` is out of scope** — see O-2.
- The five non-Submit `Advance_*` / `Select_Offer` entries, the three bare `Edit`/`Clone`/`Delete` entries (`:454-462`), `enableActionsConfiguration` (`:470`), the `c_dispositionMain` rule (`:752-774`), the `flexipage_fieldSection` "Details" rule (`:793-815`), the `FieldBroker` fieldInstance rule (`:650-656`), the Approval History component in the `header` region (`:496-513`), or the two relocated sidebar components (`:992-1010`).
- **The action list must still contain exactly TWELVE `valueListItems`** after this change. Adding a criterion adds no entry.

Add a dated entry to the in-root comment recording the change, the polarity choice, and the FLS dependency, following the file's existing convention.

⚠ **Also required by the same "never open App Builder" rule:** before deploying, diff this file against `HEAD` and against the **live org** (Tooling API), per `:220-224`. A concurrent session has previously built into this same tree.

### A-5 — Approval processes: four files, three new elements each

| File | Add `initialSubmissionActions` | Add to `finalApprovalActions` | Add `finalRejectionActions` | Add `recallActions` |
|---|---|---|---|---|
| `approvalProcesses/Disposition__c.Sale_Decision_Approval.approvalProcess-meta.xml` | `Set_Approval_Pending` (new element) | `Clear_Approval_Pending` as a **second** `<action>` alongside the existing `Set_Approval_Advance_Pending` (`:95-100`) | `Clear_Approval_Pending` (**new element** — this file has none) | `Clear_Approval_Pending` (new element) |
| `approvalProcesses/Disposition__c.Broker_Selection_Approval.approvalProcess-meta.xml` | `Set_Approval_Pending` | `Clear_Approval_Pending` (second action) | `Clear_Approval_Pending` (new element) | `Clear_Approval_Pending` |
| `approvalProcesses/Disposition__c.Closing_Approval.approvalProcess-meta.xml` | `Set_Approval_Pending` | `Clear_Approval_Pending` (second action, alongside `:121-126`) | `Clear_Approval_Pending` (new element) | `Clear_Approval_Pending` |
| `approvalProcesses/BOV_Submission__c.Broker_Finalize_Approval.approvalProcess-meta.xml` | `Set_Broker_Approval_Pending` | `Clear_Broker_Approval_Pending` (second action, alongside `Set_Broker_Approval_Approved` at `:104-109`) | `Clear_Broker_Approval_Pending` (second action, alongside the **existing** `Set_Broker_Approval_Rejected` at `:111-116`) | `Clear_Broker_Approval_Pending` |

🔴 **Blocked on G1.** Do not write `initialSubmissionActions` or `recallActions` into any of these until the shape and the *behaviour* are proven on `Sale_Decision_Approval` alone.

🔴 **DO NOT CHANGE, in any of the four:** `active`, `allowRecall` (stays `true` — it is what makes the recall clearing meaningful and what C-3 made reachable), `allowedSubmitters`, `approvalPageFields`, `approvalStep`, `entryCriteria` (in particular `Closing_Approval`'s two-criterion filter at `:108-120`), `finalApprovalRecordLock`, `finalRejectionRecordLock`, `processOrder`, `recordEditability` (**stays `AdminOnly`** — the lock is load-bearing for D-1), `showApprovalHistory`.
🔴 **Do not remove or reorder the existing `Set_Approval_Advance_Pending` action.** The D-1 semaphore must keep firing; the new clear is an *addition* to `finalApprovalActions`, not a replacement.
⚠ `Disposition_Offer__c.Offer_Selection_Approval` is **out of scope** (O-2).
⚠ Element placement: alphabetical per §G1's observation, confirmed under G1 first.

### A-6 — Nothing else

**No page layout change. No new permission set. No validation rule. No custom permission. No path assistant change. No new quick action. No change to `Disposition_Deal_Actions`.** None were requested and none is needed.

---

## 🟢 DEVELOPMENT WORK (`salesforce-developer`)

Read `ARCHITECTURE.md` §2 and `.claude/rules/apex-layering-rule.md` first. **The Apex surface of this change is one method in one existing trigger handler.** Everything else is declarative.

### D-1 — `BovSubmissionTriggerHandler`: mirror the BOV pending flag onto the parent Disposition

**Layer:** Trigger Handler. **File:** `force-app/main/default/classes/BovSubmissionTriggerHandler.cls`. **Context:** the existing `afterUpdate()` (`:208-213`).

**Why Apex is unavoidable here and nowhere else:** `Submit_Selected_Broker`'s approval targets the `BOV_Submission__c`, but the FlexiPage rule can only read a field on `Disposition__c` (§0.2). `BOV_Submission__c.Disposition__c` is a **Lookup**, not Master-Detail (`objects/BOV_Submission__c/fields/Disposition__c.field-meta.xml:11`), so **neither** a roll-up summary **nor** a cross-object workflow field update can carry the value up. A trigger mirror is the only route.

**Why it is safe here, in the same terms the file already argues (`:32-56`):** the record being written is the **parent** Disposition, which `Broker_Finalize_Approval` does not lock (it locks the submission), and no Disposition-target approval can be pending at `BOV Outreach` — their entry stages are `Disposition Readiness`, `Broker Selection` + off-market, and `Closing`. This is the identical justification that already permits `handleApprovedSelections`' synchronous parent write.

**Specification:**

- Add a second private method to `afterUpdate()`, e.g. `mirrorPendingFlagToParents(newList, oldMap)`, alongside the existing `handleApprovedSelections` call.
- Detect a **transition** on `Approval_Pending__c` (`old != new`), never merely "is true" — the same shape `DispositionTriggerHandler` uses for the D-1 semaphore and `handleApprovedSelections` uses for `Approval_Status__c` (`:246-252`). Skip rows with a null `Disposition__c`.
- Build `Map<Id, Boolean>` keyed on parent Id and write `new Disposition__c(Id = parentId, Approval_Pending__c = value)`.
- **`Database.update(updates, false, AccessLevel.SYSTEM_MODE)`** — the identical shape and identical reasoning as `:295`: `SYSTEM_MODE` because this runs as the approver/submitter who is read-only on `Disposition__c` and because the new field is granted read-only in both permission sets; `allOrNone = false` because an all-or-none failure would roll back the approval itself.
- 🔴 **ZERO SOQL.** No parent read is needed — the write is `Id` + one field. Do not add a `DispositionSelector` call, and do **not** widen `DispositionSelector.selectApprovalContextById`'s SELECT (that method is `WITH USER_MODE`, backs all four approval branches, and widening it is an FLS change with a documented failure mode — `DPEG_Disposition_View:419-425`).
- 🔴 **No current-stage guard, deliberately.** `handleApprovedSelections` guards on `BOV Outreach` because it moves the stage forward and a stale re-approval would drag the sale backwards (`:59-72`). This method writes a UI flag that is only *read* at `BOV Outreach`, so a write at any other stage is inert. Adding a guard would buy nothing and would create a path where the flag can stick true.
- **Write direction is fail-open by construction:** a wrong `true` is the only dangerous value, and this method writes `true` on exactly one event — a submission entering the approval. A wrong `false` merely restores today's behaviour (button visible, server refuses with `ALREADY_PENDING_MESSAGE`).

⚠ **Update the class header.** It currently reads "THREE CONTEXTS AND THREE JOBS" (`:8-10`) and its BULK budget table (`:120-129`) states `afterUpdate` costs "ONE selector query + ONE `Database.update` per chunk". Both change. Follow this repo's **correct-in-place, do not delete** convention. The new job adds **zero queries** and, when batched into the same `Database.update`, **zero additional DML** — if kept as a separate DML statement, say so explicitly and state the new budget as two.

⚠ **Do NOT touch:** `beforeInsert()`/`beforeUpdate()` (`:172-206`), `BovSubmissionBrokerStampService`, `BovSubmissionSelectionGuardService`, `handleApprovedSelections`, or `triggers/BovSubmissionTrigger.trigger` (`before insert, before update, after update` already covers this — **no new context is needed**).

### D-2 — Tests

Per `.claude/rules/bulk-test-rule.md`, `BovSubmissionTriggerHandler` is **trigger-driven and carries no exemption** — its own header says so at `:120-122`. The new method needs:

- A **251-record bulk test** asserting the per-chunk cost stays **constant** (zero queries added; DML count unchanged or +1), not merely that 251 rows produced 251 mirrors. That is the property the existing bulk tests in this class already assert.
- Transition tests: false→true mirrors true; true→false mirrors false; **no change → zero DML** (the free path).
- A null-`Disposition__c` row is skipped.
- Use `TestDataFactory` (`ARCHITECTURE.md` §2). Never `SeeAllData=true`.
- ⚠ The content-publication rule (`.claude/rules/content-publication-rule.md`) does **not** apply — no `ContentVersion`/`ContentNote`/`ContentDocument` is involved.

⚠ **No test can observe a FlexiPage visibility rule or an approval `recallActions` firing.** Both are verified by the manual readback protocol in G1 step 3 and §8, not by Apex. Say so in the test class header so review does not demand a test that cannot exist.

### D-3 — Nothing else in Apex

**No change to** `DispositionApprovalService`, `DispositionApprovalController`, `DispositionApprovalAdvanceService`, `DispositionApprovalAdvanceQueueable`, `DispositionTriggerHandler`, `DispositionService`, `DispositionSelector`, `ProcessInstanceSelector`, `BovSubmissionSelector`, `BovSubmissionService`, `RecordStageAdvanceService`, or **any LWC** (`dispositionSubmitForApproval` is unchanged — it is headless and runs only after a click that can no longer happen). The server-side pending guard at `DispositionApprovalService.cls:331-333` stays exactly as written and remains the authoritative check.

---

## 🔄 SECTION 6 — THE CLEARING MECHANISM, EVERY EXIT PATH

### Branch A — `Submit_Sale_Decision`, `Submit_Broker_Selection`, `Submit_Closing_Approval` (target = `Disposition__c`)

| Event | Mechanism | Writes `Disposition__c.Approval_Pending__c` | Record locked at that moment? |
|---|---|---|---|
| **Submit** (any route: quick action, `initiateAndSubmit`, generic Submit, API) | `initialSubmissionActions` → `Set_Approval_Pending` | **true** | Lock is being applied in this same transaction. Approval field updates are the one writer not blocked. |
| **Approved** | `finalApprovalActions` → `Clear_Approval_Pending` (**second** action, alongside the untouched `Set_Approval_Advance_Pending`) | **false** | Lock releases; `finalApprovalRecordLock = false`. |
| **Rejected** | `finalRejectionActions` → `Clear_Approval_Pending` (new element) | **false** | Lock releases; `finalRejectionRecordLock = false`. Proven in-repo by `Broker_Finalize_Approval:111-116`. |
| **Recalled** | `recallActions` → `Clear_Approval_Pending` (new element) | **false** | Lock releases on recall. **This is the trap-1 fix and the only hook for the event.** |

**Answer to "what clears the flag on approval, given the stage moves anyway":** it is cleared **explicitly** by `finalApprovalActions`, not left to the stage condition. That is the whole point — the `NDA_Signed__c` failure mode is a flag whose clearing depends on one specific path. Here every one of the four terminal transitions clears it, so the flag's lifetime is exactly the pending window and it cannot outlive it. A re-pick after a rejected offer, a second Closing submission, a re-entry to any stage — all find the flag `false`.

⚠ **One accepted interaction with D-1, named rather than hidden.** If the approval succeeds but the auto-advance is refused (a validation rule, an exhausted queueable budget — `docs/2026-08-19-disposition-flow-redesign.md:96-100`, `:598-606`), `Approval_Advance_Pending__c` sticks `true` while `Approval_Pending__c` is correctly `false`. The record sits at its old stage with the Submit button visible, and clicking it re-submits the same approval. **This is today's behaviour unchanged** — nothing hides that button now either — so it is a pre-existing residual, not one this change introduces. It is listed in the risk register as R-4 with the standing detection query.

### Branch B — `Submit_Selected_Broker` (target = the Selected `BOV_Submission__c`)

| Event | Mechanism on `BOV_Submission__c` | Then | Net `Disposition__c.Approval_Pending__c` |
|---|---|---|---|
| **Submit** | `initialSubmissionActions` → `Set_Broker_Approval_Pending` → `Approval_Pending__c = true` | `BovSubmissionTrigger` afterUpdate → **D-1 mirror** → `Database.update(..., false, SYSTEM_MODE)` on the parent | **true** |
| **Approved** | `finalApprovalActions` → `Set_Broker_Approval_Approved` (existing) **+** `Clear_Broker_Approval_Pending` (new) | same trigger pass mirrors `false`; `handleApprovedSelections` independently advances the parent to `Broker Selection` | **false** |
| **Rejected** | `finalRejectionActions` → `Set_Broker_Approval_Rejected` (existing) **+** `Clear_Broker_Approval_Pending` (new) | mirror → `false`; stage stays at `BOV Outreach` for a re-pick (`Broker_Finalize_Approval:47-49`) | **false** |
| **Recalled** | `recallActions` → `Clear_Broker_Approval_Pending` (new) | mirror → `false` | **false** |

⚠ **Both halves of the Approved row happen in ONE trigger pass** — the field update writes `Approval_Status__c` and `Approval_Pending__c` in the same save, so `afterUpdate` sees both. Batching the mirror into `handleApprovedSelections`' existing `Database.update` is permitted and preferred (it keeps DML at one per chunk); keeping it separate is acceptable if the header's budget note is updated accordingly.

⚠ **`BovSubmissionService.replaceSelectedBroker` needs no change.** It clears the demoted submission's `Approval_Status__c` and promotes the challenger in one DML (`docs/2026-08-19-disposition-flow-redesign.md:289`); it never touches `Approval_Pending__c`, so the mirror is a no-op on that path. And a submission with a *pending* approval cannot be replaced at all — it is locked (`triggers/BovSubmissionTrigger.trigger:35-41`).

---

## ⚠ SECTION 7 — RISK REGISTER

| # | Risk | Severity | Direction | Mitigation |
|---|---|---|---|---|
| R-1 | **`recallActions` deploys green but never fires.** The button stays hidden permanently on an unlocked, recallable record with no route to resubmit — strictly worse than today. | 🔴 Critical | Fail-closed | **G1 step 3 is mandatory and behavioural**: submit → recall → confirm the flag went false, in the org, on `Sale_Decision_Approval` alone, before the other three are written. If the recall test cannot run, do not ship. |
| R-2 | **FLS missed on the new field.** A rule reading an unreadable field evaluates FALSE → all four buttons hidden for everyone, silently, with no error logged anywhere. | 🔴 Critical | Fail-closed | A-2. Deploy the two permission sets **with or before** the FlexiPage. Post-deploy, acceptance-test as a real disposition-driver persona, **never as an admin** (`docs/2026-08-19-disposition-flow-redesign.md:433-436` — "Modify All Data" bypasses the gate for an unrelated reason). |
| R-3 | **A pending `BOV_Submission__c` is DELETED.** `BovSubmissionTrigger` declares no delete context (`:51`), so the mirror never fires and the parent flag sticks `true` — `Submit_Selected_Broker` hidden permanently at `BOV Outreach`. | 🟠 Medium | Fail-closed | Low probability (a locked record resists deletion by non-admins). Documented recovery query in §8. Adding `after delete` is **deliberately not proposed** — it is scope the user did not request. Flagged as **O-3**. |
| R-4 | **Stuck D-1 semaphore + cleared pending flag** → the record shows a Submit button at a stage it already passed approval for, and clicking re-submits. | 🟡 Low | Fail-open | **Pre-existing, not introduced.** Standing detection query already documented (`docs/2026-08-19-disposition-flow-redesign.md:461-470`). Two live records are already in this state (`DISP-0009`, `DISP-0010`, `:443`). |
| R-5 | **FlexiPage deploy rolls back and reports success**, or App Builder is opened and silently drops `Edit`/`Clone`/`Delete` again — measured twice on this exact file (`:151-153`, `:216-230`). | 🔴 Critical | Silent | Never open the page in App Builder. Read the page back from the org after deploying and **count exactly twelve `valueListItems`** plus confirm the four new criteria. |
| R-6 | **Records already pending at cutover** read `false` and show their button. | 🟡 Low | Fail-open | G4. Self-clearing. Server still refuses with an authored message. |
| R-7 | **Field-name confusion** — `Approval_Pending__c` vs `Approval_Advance_Pending__c` on the same object; a future maintainer wires the wrong one. | 🟠 Medium | Latent | A-1's mandatory mutual disambiguation banners, following the `Approval_Status__c` / `Submission_Status__c` precedent. Alternative: pick a maximally distinct name (G3). |
| R-8 | **Target-scoping breaks if a fifth approval is added at a shared stage.** The one-flag design is correct only because the four entry stages are mutually exclusive (§0.1). | 🟡 Low | Latent | Record the dependency in the `Disposition__c.Approval_Pending__c` field file, in the same style as the "ONE UPDATE SERVES ALL THREE APPROVALS" note at `workflows/Disposition__c.workflow-meta.xml:37-39`. |
| R-9 | **Concurrent session in this working tree.** `git status` shows four modified seed scripts; a prior incident had a second session build a whole feature into shared hub files. | 🟠 Medium | Silent | Diff `Disposition_Record_Page.flexipage-meta.xml` and both permission sets against `HEAD` **and** against the live org before deploying. |

---

## ❓ SECTION 8 — OPEN QUESTIONS (kept separate from the design)

- **O-1 — Field API name.** `Approval_Pending__c` (sibling symmetry, deviates from `ARCHITECTURE.md` §1's Boolean convention exactly as `Approval_Advance_Pending__c` already does) or `Is_Approval_Pending__c` (strict conformance, no sibling symmetry)? Recommendation: `Approval_Pending__c`. **Needs a one-word answer.**
- **O-2 — `Select_Offer` is out of scope. Confirm.** It submits `Offer_Selection_Approval` on `Disposition_Offer__c` (`allowRecall = true`, `AdminOnly`, `:61`/`:118`) and is not one of the four Submit actions. It has the same double-submit surface, but hiding it is a different question (it is a picker, not a submit button — the offer to submit is chosen inside a ScreenAction). **Not designed here. Say if it should be.**
- **O-3 — `after delete` on `BovSubmissionTrigger`?** Closes R-3. **Not proposed** — it is scope the user did not request and it adds a trigger context to a file whose header argues carefully about which contexts exist and why. Ask before adding.
- **O-4 — Cutover handling for already-pending approvals.** G4(a) accept, or G4(b) recall all pending Disposition approvals before deploying? The recall-before-deploy instruction already exists as a standing rule for this page.
- **O-5 — Should the flag be `editable` for an administrative unstick?** Recommendation **no** (read-only, matching `Is_On_Market__c`, `Is_Selected__c` and both `Approval_Status__c` fields). Recovery for R-1/R-3 is anonymous Apex or Data Loader, not a hand edit. **Detection/recovery query to publish alongside the standing semaphore query:**
  ```sql
  SELECT Id, Name, Disposition_Stage__c FROM Disposition__c
  WHERE Approval_Pending__c = true
    AND Id NOT IN (SELECT TargetObjectId FROM ProcessInstance WHERE Status = 'Pending')
  ```
  Any row returned is a stuck flag with no pending approval behind it — the exact R-1/R-3 signature.
- **O-6 — "No pending indicator" is already satisfied for free, and that is worth knowing before confirming it.** The user asked for no indicator, so none is designed. But the Approval History component added by C-3 now sits in the **header** region with `showActionBar = true` (`flexipages/Disposition_Record_Page.flexipage-meta.xml:496-513`) — so a driver whose button vanishes already sees who holds the approval and already has the Recall button, above the fold, on every record. **No additional indicator is needed, and this is why.** Confirm this satisfies the intent.
- **O-7 — `ARCHITECTURE.md` update.** Recommendation: **not required.** No new object, no new integration boundary, no new Apex layering pattern — the trigger-handler mirror is a second instance of a pattern that class already uses. Flagged only because `CLAUDE.md` requires the question be asked.

---

## 🔗 SECTION 9 — EXECUTION ORDER

Deploy order is load-bearing at three points and each one has a documented failure mode.

1. **G1** — resolve `initialSubmissionActions` / `recallActions` on **one** process; check-only dry-run; **behavioural readback including a real recall**. Everything below is blocked on this. **G2 / G3 / G4** are user/admin decisions and can run in parallel.
2. **A-1** — the two Checkbox fields. Must land **before** A-3 (a field update naming a non-existent field fails the deploy — `workflows/Disposition__c.workflow-meta.xml:41-43`).
3. **A-3** — the four workflow field updates. Must land **before** A-5 (an approval process naming a non-existent field update fails the deploy — same reference, and `Broker_Finalize_Approval:59-61`).
4. **A-5** — the four approval processes. `Sale_Decision_Approval` first and alone, per G1 step 2/3; the other three only after its recall behaviour is proven.
5. **A-2** — the two permission sets. Must land **with or before** step 6. 🔴 Reversing 5 and 6 hides all four buttons for everyone, silently (R-2).
6. **A-4** — the FlexiPage. **Last.** Read it back and count twelve action entries (R-5).
7. **D-1 + D-2** — the trigger-handler mirror and its tests. Independent of 2–6 and can run in parallel; must be live **before** `Broker_Finalize_Approval` gains `initialSubmissionActions` in a real org, or a submission will set a BOV flag nothing mirrors (the same sequencing argument `Sale_Decision_Approval:53-56` makes for the D-1 semaphore hook).

⚠ **Before any deploy:** diff `Disposition_Record_Page.flexipage-meta.xml`, `DPEG_Disposition_View` and `DPEG_Disposition_Edit` against `HEAD` **and** against the live org (R-9).

---

## 📝 SECTION 10 — PROMPTS FOR SPECIALIST AGENTS

### 🔵 `salesforce-admin`

```
Read ARCHITECTURE.md and .claude/rules/salesforce-global-rule.md first. Follow the per-type
skill-load + salesforce-api-context loop for EVERY metadata type below, one type at a time.

FIRST, AND BLOCKING (gate G1) - resolve the ApprovalProcess XML shape for two elements that
appear NOWHERE in this repo: <initialSubmissionActions> and <recallActions>. Grep confirms zero
occurrences across all seven files in force-app/main/default/approvalProcesses/. Load the
approval-process skill, then call salesforce-api-context (get_metadata_type_fields /
get_metadata_type_fields_properties on ApprovalProcess). Record mcp=complete + mcp_tools=<list>,
or mcp=unavailable after a REAL attempt. Do not guess.
Candidate shape (observation, not schema): both are ApprovalAction type and should take the same
repeating <action><name>..</name><type>FieldUpdate</type></action> child as finalApprovalActions
(Disposition__c.Sale_Decision_Approval:95-100). Element order in these five files is ALPHABETICAL,
so initialSubmissionActions goes after finalRejectionRecordLock and before label; recallActions
goes after processOrder and before recordEditability. CONFIRM that, do not assume it.

Prove the shape on ONE process only - Disposition__c.Sale_Decision_Approval - with a CHECK-ONLY
dry-run against usman-dpeg. Then READ THE BEHAVIOUR BACK FROM THE ORG: submit a test disposition,
confirm Approval_Pending__c went TRUE; RECALL it; confirm the flag went FALSE. Deploy success is
NOT proof - this repo has measured green-but-inert FlexiPage deploys twice. If the recall test
cannot be run, STOP and report; do not write the other three files.

Also confirm under G2: is approval/lock state reachable by a FORMULA field on Disposition__c? If
yes, report it - the whole design collapses to one formula field plus the FlexiPage edit.

THEN, in this order:

A-1  CREATE two Checkbox fields, defaultValue false, copying the file shape from
     objects/Disposition__c/fields/Approval_Advance_Pending__c.field-meta.xml (keep the XML
     comment INSIDE the root element - a comment above <CustomField> breaks sf at conversion):
       objects/Disposition__c/fields/Approval_Pending__c.field-meta.xml
       objects/BOV_Submission__c/fields/Approval_Pending__c.field-meta.xml
     BOTH files MUST carry a mutual disambiguation banner vs Approval_Advance_Pending__c
     ("a SECOND, DISTINCT field - do not conflate them"), and you must ALSO add a reciprocal
     one-line pointer to Approval_Advance_Pending__c.field-meta.xml - ADDITIVE ONLY, do not
     rewrite or delete any existing text in that file.
     State in the Disposition__c file: not on any layout, not on any FlexiPage fieldInstance,
     read ONLY by these four Dynamic Actions - Submit_Sale_Decision, Submit_Selected_Broker,
     Submit_Broker_Selection, Submit_Closing_Approval.
     State in the BOV_Submission__c file: deliberately NO FLS in any permission set - nothing in
     the UI reads it; do not "complete the set".
     Field API name is gate G3 - confirm Approval_Pending__c vs Is_Approval_Pending__c with the
     user before writing.

A-3  ADD four fieldUpdates, copying the element set from workflows/Disposition__c.workflow-meta
     .xml:45-55 exactly (notifyAssignee=false, operation=Literal, protected=false,
     reevaluateOnChange=false):
       workflows/Disposition__c.workflow-meta.xml      Set_Approval_Pending  literalValue 1
                                                        Clear_Approval_Pending literalValue 0
       workflows/BOV_Submission__c.workflow-meta.xml    Set_Broker_Approval_Pending  1
                                                        Clear_Broker_Approval_Pending 0
     🔴 DO NOT add a <rules> element to either file - both carry an explicit prohibition.
     🔴 reevaluateOnChange stays false.

A-5  EDIT four approval processes (BLOCKED on G1; Sale_Decision first and ALONE):
       Disposition__c.Sale_Decision_Approval      + initialSubmissionActions Set_Approval_Pending
       Disposition__c.Broker_Selection_Approval     + Clear_Approval_Pending as a SECOND action
       Disposition__c.Closing_Approval                inside the EXISTING finalApprovalActions
                                                    + finalRejectionActions (NEW element)
                                                    + recallActions (NEW element)
       BOV_Submission__c.Broker_Finalize_Approval  same four, using Set_/Clear_Broker_Approval_
                                                   Pending; its finalRejectionActions ALREADY
                                                   EXISTS - add a second action to it, do not
                                                   replace Set_Broker_Approval_Rejected.
     🔴 DO NOT remove or reorder Set_Approval_Advance_Pending - the D-1 semaphore must keep firing.
     🔴 DO NOT change active, allowRecall (stays true), allowedSubmitters, approvalPageFields,
        approvalStep, entryCriteria, finalApprovalRecordLock, finalRejectionRecordLock,
        processOrder, recordEditability (stays AdminOnly), showApprovalHistory.
     🔴 Disposition_Offer__c.Offer_Selection_Approval is OUT OF SCOPE - do not touch it.

A-2  ADD read-only FLS in BOTH permission sets, ONE <fieldPermissions> block each, inserted
     immediately after the existing Disposition__c.Is_On_Market__c block:
       permissionsets/DPEG_Disposition_View.permissionset-meta.xml   (after :811-815)
       permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml   (after :1522-1526)
     <editable>false</editable> <field>Disposition__c.Approval_Pending__c</field>
     <readable>true</readable>
     NOTHING for BOV_Submission__c.Approval_Pending__c and nothing in DPEG_Admin_Access - the
     precedent field Is_On_Market__c is granted in exactly these two sets and nowhere else, and
     DPEG_Admin_Access does not even grant Disposition_Stage__c.
     ⚠ A PermissionSet deploy REPLACES fieldPermissions wholesale. Diff against HEAD and confirm
     zero deletions and nothing reordered.

A-4  EDIT flexipages/Disposition_Record_Page.flexipage-meta.xml. LAST.
     🔴 EDIT THE XML DIRECTLY. DO NOT OPEN THIS PAGE IN APP BUILDER. An App Builder save has
     already silently dropped Edit/Clone/Delete from this page's action list TWICE - opening it
     there at all is the trigger. DO NOT touch enableActionsConfiguration.
     APPEND one criteria block, LAST in each rule (after the Disposition_Deal_Actions criterion),
     and renumber booleanFilter:
       Submit_Sale_Decision     (:276)  "1 AND 2"        -> "1 AND 2 AND 3"
       Submit_Selected_Broker   (:292)  "1 AND 2"        -> "1 AND 2 AND 3"
       Submit_Broker_Selection  (:308)  "1 AND 2 AND 3"  -> "1 AND 2 AND 3 AND 4"
       Submit_Closing_Approval  (:434)  "1 AND 2 AND 3"  -> "1 AND 2 AND 3 AND 4"
     The criterion, byte-identical in all four:
       <criteria><leftValue>{!Record.Approval_Pending__c}</leftValue>
       <operator>EQUAL</operator><rightValue>false</rightValue></criteria>
     ⚠ lowercase false, EQUAL not NE - matching the four existing Is_On_Market__c criteria in
     this file. NE against a boolean is unproven here.
     🔴 DO NOT touch: any {!$Permission.CustomPermission.Disposition_Deal_Actions} criterion (the
     three-segment form is the only one the Metadata API accepts); Select_Offer's
     "(1 OR 2) AND (3 OR 4) AND 5" filter or its duplicated criterion 1/3; the five Advance_*/
     Select_Offer entries; the three bare Edit/Clone/Delete entries; c_dispositionMain's rule;
     flexipage_fieldSection's Details rule; the FieldBroker fieldInstance rule; the Approval
     History component in the header region; the two relocated sidebar components.
     🔴 THE ACTION LIST MUST STILL CONTAIN EXACTLY TWELVE valueListItems.
     Add a dated entry to the in-root comment recording the change, the EQUAL/lowercase-false
     polarity choice, and the FLS dependency.

NOTHING ELSE. No page layout change, no new permission set, no validation rule, no custom
permission, no path assistant change, no new quick action, no change to Disposition_Deal_Actions.
Do not deploy - create/modify metadata files only, and report the G1 result before A-5.
⚠ Another session may be working in this tree. Diff the FlexiPage and both permission sets
against HEAD and against the live org before anything is handed to devops.
```

### 🟢 `salesforce-developer`

```
Read ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md first. The Apex surface of this
change is ONE new private method in ONE existing trigger handler. Do not expand it.

D-1  classes/BovSubmissionTriggerHandler.cls - add a second job to the EXISTING afterUpdate()
     (:208-213), alongside handleApprovedSelections.

     WHY: Submit_Selected_Broker's approval targets the BOV_Submission__c, but a FlexiPage
     visibility rule can only read a field on Disposition__c. BOV_Submission__c.Disposition__c is
     a LOOKUP, not Master-Detail (objects/BOV_Submission__c/fields/Disposition__c.field-meta.xml
     :11), so NEITHER a roll-up summary NOR a cross-object workflow field update can carry the
     value up. A trigger mirror is the only route.

     WHY IT IS SAFE: the record written is the PARENT Disposition, which Broker_Finalize_Approval
     does NOT lock (it locks the submission), and no Disposition-target approval can be pending at
     BOV Outreach. That is the same justification already in this file at :32-56 for
     handleApprovedSelections' synchronous parent write.

     SPEC:
       - Detect a TRANSITION on BOV_Submission__c.Approval_Pending__c (old != new), never merely
         "is true" - same shape as handleApprovedSelections' Approval_Status__c detection
         (:246-252). Skip rows whose Disposition__c is null.
       - Write new Disposition__c(Id = parentId, Approval_Pending__c = value) via
         Database.update(updates, false, AccessLevel.SYSTEM_MODE) - identical shape and identical
         reasoning to :295. SYSTEM_MODE because this runs as the approver/submitter, who is
         read-only on Disposition__c and on this new field. allOrNone=false because an
         all-or-none failure would roll back THE APPROVAL ITSELF.
       - 🔴 ZERO SOQL. No parent read is needed. Do NOT add a DispositionSelector call and do NOT
         widen DispositionSelector.selectApprovalContextById's SELECT - that method is WITH
         USER_MODE, backs all four approval branches, and widening it is an FLS change with a
         documented failure mode.
       - 🔴 NO current-stage guard, deliberately. handleApprovedSelections guards on BOV Outreach
         because it MOVES the stage; this method writes a UI flag that is only READ at BOV
         Outreach, so a write at any other stage is inert. A guard would create a path where the
         flag sticks true.
       - Prefer batching into handleApprovedSelections' existing Database.update so DML stays at
         one per chunk. If kept separate, say so and restate the budget.

     UPDATE THE CLASS HEADER. It says "THREE CONTEXTS AND THREE JOBS" (:8-10) and its BULK budget
     (:120-129) says afterUpdate costs ONE query + ONE Database.update per chunk. Both change.
     Follow this repo's correct-in-place convention - retract and amend, do not delete.

     🔴 DO NOT touch: beforeInsert()/beforeUpdate() (:172-206), BovSubmissionBrokerStampService,
     BovSubmissionSelectionGuardService, handleApprovedSelections, or
     triggers/BovSubmissionTrigger.trigger - its (before insert, before update, after update)
     context list already covers this and needs NO new context.

D-2  Tests. This handler is trigger-driven and its own header (:120-122) states the
     .claude/rules/bulk-test-rule.md 251-record mandate applies with NO exemption. Required:
       - a 251-record bulk test asserting the per-chunk cost stays CONSTANT (zero queries added,
         DML unchanged or +1), not merely that 251 rows produced 251 mirrors;
       - false->true mirrors true; true->false mirrors false; NO CHANGE costs ZERO DML;
       - a null-Disposition__c row is skipped.
     Use TestDataFactory. Never SeeAllData=true.
     ⚠ Record in the test class header that NO Apex test can observe a FlexiPage visibility rule
     or an approval recallActions firing - both are verified by a manual org readback, not by a
     test - so review does not demand a test that cannot exist.

🔴 NO OTHER APEX AND NO LWC. Do not change DispositionApprovalService (its pending guard at
:331-333 stays exactly as written and remains the authoritative check),
DispositionApprovalController, DispositionApprovalAdvanceService,
DispositionApprovalAdvanceQueueable, DispositionTriggerHandler, DispositionService,
DispositionSelector, ProcessInstanceSelector, BovSubmissionSelector, BovSubmissionService,
RecordStageAdvanceService, or lwc/dispositionSubmitForApproval (it is headless and only runs
after a click that can no longer happen).
```

---

## 📌 SECTION 11 — WHAT I COULD NOT DO THE WAY YOU ASSUMED

Stated plainly, as requested.

1. **I could not resolve the `initialSubmissionActions` / `recallActions` XML shape.** This agent has file-system tools only — no `salesforce-api-context` MCP, no `sf` CLI, no org access — so no real attempt was possible, and there is **no precedent in this repo to copy** (zero occurrences of either element across all seven approval-process files). It is escalated as blocking gate **G1** with a one-process dry-run + behavioural-readback protocol. This is the single highest risk in the change and its failure mode is fail-closed.
2. **"Hide until the broker is rejected" is not implementable as literally stated, and shipping it would be a regression.** Recall fires no rejection action, and Recall was *deliberately made reachable on this page three days ago* (C-3, `flexipages/Disposition_Record_Page.flexipage-meta.xml:158-167`) precisely because a locked record with an absent approver had no escape route. The design implements "hidden while genuinely pending" instead, with `recallActions` as the fourth clearing path.
3. **One of the four actions cannot be done declaratively.** `Submit_Selected_Broker`'s approval targets the child `BOV_Submission__c`, whose relationship to `Disposition__c` is a **Lookup**, not Master-Detail — which independently rules out both a roll-up summary and a cross-object workflow field update. That branch requires ~25 lines of Apex in an existing trigger handler. Three of four are pure metadata; the fourth is not, and no amount of design removes that.
4. **Your instinct about `Approval_Advance_Pending__c` was right, and for three reasons rather than one** — wrong event (fires on approval, not submit), no FLS anywhere by explicit decision (a rule reading it would hide the button for everyone), and D-1 requires it left `true` on a failed advance, with two live records already in that state.
5. **The "stale true after approval" bug you anticipated does not arise in this design**, because `finalApprovalActions` clears the flag explicitly rather than relying on the stage moving. That is the deliberate difference from `NDA_Signed__c`: the flag is cleared on **all four** terminal transitions, so its lifetime is exactly the pending window and it cannot outlive it on any path.
6. **The "no pending indicator" requirement is already met without designing one** — the Approval History component sits in the page's `header` region with `showActionBar = true`, so a driver whose button vanishes already sees who holds the approval and already has the Recall button. Flagged as **O-6** for confirmation rather than assumed.
