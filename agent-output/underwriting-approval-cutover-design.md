# Underwriting Approval Cutover — Design Requirements

**Date:** 2026-09-01
**Requested by:** user (following a live failure: Junior Dhanani clicked *Submit for Approval* on an Underwriting record and received a masked error)
**Confirmed end state:** the principal approval process lives on `Underwriting__c`.
**Status:** requirements only. No implementation metadata or Apex is produced by this document.

```
skill_selection=complete | intent=type | best_matched_skill=none (no metadata is generated here)
mcp=unavailable | mcp_tools=none
```

**MCP disclosure — read this, do not treat it as boilerplate.** This agent's tool set is
file-system only (Read / Write / Edit / Glob / Grep). There is no `salesforce-api-context` MCP
server exposed to it and no `sf` CLI or org access, so no MCP call was possible to make. Nothing
below is an MCP result and nothing below is an org readback. **Every statement about the ORG is
either (a) your measurement, restated, or (b) an inference from repo files, explicitly labelled.**
Every statement about the REPO was read from the files named. The verification wave (W0) exists
because that distinction is load-bearing here.

---

## 0. The finding that changes the shape of the answer

You framed the danger as: *deactivating the Opportunity process before its replacement writer is
live leaves the live validation rule with no writer, and every deal is blocked from LOI.*

That is correct as stated — **and it is avoidable entirely**, because of one fact:

> `UnderwritingApprovalStampService.stampParent` writes **`UW_Approved__c = true`** —
> `force-app/main/default/classes/UnderwritingApprovalStampService.cls:134`.
> That is the *same field*, with the *same value*, that `UW_Set_Approved_Flag` writes
> (`force-app/main/default/workflows/Opportunity.workflow-meta.xml:49-51`,
> `<field>UW_Approved__c</field>` / `<literalValue>1</literalValue>`).

So the new chain **satisfies the org's current validation rule**. The replacement writer and the
old writer target the same field. There is therefore no need to move the validation rule and the
approval process in lockstep, and no need to accept a blocked window. The rule repoint becomes the
*last* act, not a coupled one.

**Answer to your question 1, up front: there is no unavoidable blocked window, provided the
validation-rule repoint is deferred to the final wave and preceded by a data backfill.** The one
window that does exist is narrower and different from the one you feared — see §4, W3.

### 0.1 The single largest risk in this repo right now, which is not on your list

The repo currently holds **three undeployed files whose contents ARE the cutover**:

| File | Undeployed content | What a broad deploy would do |
|---|---|---|
| `approvalProcesses/Underwriting__c.Underwriting_Approval.approvalProcess-meta.xml` | `<active>true</active>` | activate the new process |
| `approvalProcesses/Opportunity.Underwriting_Approval.approvalProcess-meta.xml` | `<active>false</active>` | deactivate the old one |
| `objects/Opportunity/validationRules/Underwriting_Approved_Before_LOI.validationRule-meta.xml` | formula reading `Primary_Underwriting__r.Stage__c` | repoint the LOI gate |

Any `sf project deploy start --source-dir force-app` — or any manifest that sweeps those
directories — **performs the entire cutover in one shot, in an order Salesforce chooses, with no
proof step and no backfill.** That is precisely the failure mode you are trying to sequence around,
and it can be triggered accidentally by the concurrent session, which is not working on this
feature and has no reason to know these files are staged.

🔴 **Requirement R-0: every deploy in this plan is an explicit component list (`--metadata` or a
purpose-built manifest). No directory-wide or repo-wide deploy is permitted between now and the end
of W5, by anyone.** This should be communicated to the other session before W1 starts.

### 0.2 The workaround may not be the one you think it is

You noted a workaround exists ("submit from the Opportunity, whose process is Active"). **Verify
which button that is before relying on it.** The deployed `OpportunityApprovalService` explicitly
refuses an Opportunity submission at `StageName = 'Underwriting'`:

`OpportunityApprovalService.cls:216-222` — at the Underwriting stage it throws
`UNDERWRITING_MOVED_MESSAGE` ("Underwriting approval now runs on the Underwriting record…"),
**before** `Approval.process` can match the still-active Opportunity process.

So the Apex-backed *Submit for Approval* quick action on the Opportunity does **not** work. The only
remaining route is the **platform** *Submit for Approval* button on the Opportunity's Approval
History related list. That list is declared
(`layouts/Opportunity-Opportunity Layout.layout-meta.xml:344` `RelatedProcessHistoryList`, plus
`flexipages/Opportunity_Record_Page.flexipage-meta.xml:1433` `force:relatedListContainer`), so it
should render — but whether the *button* is available to the deal driver's persona is unverified.

**If that button is not available to Junior, there is no workaround at all and this is more urgent
than "urgent but not an emergency".** This is verification item V-0 and it comes first.

---

## 1. What the user requested (scope)

Design the cutover of the principal underwriting approval from `Opportunity.Underwriting_Approval`
to `Underwriting__c.Underwriting_Approval`, using the components that already exist in the repo.
Deliver: deploy order with inter-step org state, per-step rollback, the validation-rule timing
decision, proof that the replacement writer is equivalent, an admin/developer split, the test
impact, and a plain statement of anything that is a bad idea.

**Not requested and therefore not designed here:** any new field, any new reject-handling
mechanism, any change to approvers, any change to LOI/NDA/PSA approvals, any new test. Where I
believe something ought to be reconsidered, it is raised in §8 as a decision for you — not
specified as work.

---

## 2. Measured current state, restated and annotated

Your measurements, taken as given (re-verification is W0):

| # | Fact | Source |
|---|---|---|
| M1 | Org `ProcessDefinition`: exactly one row — `Underwriting_Approval`, table `Opportunity`, **Active**. No process on `Underwriting__c`. | yours |
| M2 | Repo `Underwriting__c.Underwriting_Approval` is `<active>true</active>`, not in the org. | yours + file |
| M3 | Repo `Opportunity.Underwriting_Approval` is `<active>false</active>` with a "RETIRED 2026-08-28 / DO NOT REACTIVATE" comment. Org has it **Active**. | yours + file |
| M4 | `OpportunityApprovalService.resolveApprovalTargetId` routes `Underwriting__c` → itself (`:316-318`). Deployed. Hence `NO_APPLICABLE_PROCESS` → masked. | yours + file |
| M5 | `workflows/Underwriting__c.workflow-meta.xml`'s `UW_Stage_Approved` / `UW_Status_Approved`: 0 of 2 in the org. The new approval references both by name in `finalApprovalActions` → cannot deploy without them. | yours + file |
| M6 | `UnderwritingApprovalStampService` absent from the org. | yours |
| M7 | `flows/Underwriting_Approval_Sync` not in the org. | yours |
| M8 | Org VR `Underwriting_Approved_Before_LOI` keys on `NOT(UW_Approved__c)`; repo copy keys on `Primary_Underwriting__r.Stage__c`. Repo copy undeployed. | yours |
| M9 | Pending `ProcessInstance` count = **0**. No recall is needed. | yours |

**What this adds up to: the org is mid-cutover.** The 2026-08-28 change landed its *Apex and page*
half and none of its *declarative* half. That is why the button exists, routes correctly, and
targets a process that does not exist. The most important consequence is that **the repo↔org
boundary of that change is not known**, only sampled. W0 exists to establish it precisely rather
than by inference.

### 2.1 Repo-derived facts you did not list, each of which changes the plan

| # | Fact | Where | Why it matters |
|---|---|---|---|
| F1 | `UnderwritingApprovalStampService` writes `UW_Approved__c = true` **and** `Underwriting_Status__c = 'Approved by Principals'`, in one `Database.update`. | `UnderwritingApprovalStampService.cls:132-136` | This is the whole answer to §0 and to your question 4. |
| F2 | `RecordStageAdvanceService.UNDERWRITING_NEXT_STAGE` has **no** `'In Progress' => 'Approved'` entry — the comment at `:1455` says reaching `Approved` "is the approval process's job". | `RecordStageAdvanceService.cls:1453-1457` | There is **no manual route** to `Stage__c = 'Approved'` on the child. Once the VR reads the child, the new approval is the *only* writer that can satisfy it. This is why the VR must go last, and why there is no user-side escape hatch after it flips. |
| F3 | No quick action exists for `In Progress → Approved`; `Underwriting_Record_Page` deliberately omits one (`:74-77`). | `flexipages/Underwriting_Record_Page.flexipage-meta.xml` | Confirms F2 — there is no competing one-click hop to retire. Nothing to do here; recorded so nobody goes looking. |
| F4 | `TestDataFactory.approveUnderwriting` already sets **both** `UW_Approved__c = true` **and** the primary child's `Stage__c = 'Approved'` ("⚠ both, since 2026-08-28"). | `TestDataFactory.cls:1060-1110`, comment at `:898-899` | The VR repoint is **test-neutral**. No test fixture needs editing for W5. |
| F5 | `LOI_Approval` writes `LOI_Approved__c` via the `Set_LOI_Approved_Flag` field update, and `LOI_Approval_Stamp` is an **after-save record-triggered flow** keyed on `LOI_Approved__c = true` with `doesRequireRecordChangedToMeetCriteria = true`. Both are live and active. | `workflows/Opportunity.workflow-meta.xml:19-21`, `flows/LOI_Approval_Stamp.flow-meta.xml:105-124` | This is the **in-repo precedent** that an approval's `finalApprovalActions` field update *does* fire an after-save record-triggered flow in this org. It is the strongest evidence available for the new chain — see §5. |
| F6 | `Underwriting__c.Stage__c` and `Status__c` are both `<restricted>true</restricted>`; `'Approved'` and `'Approved by Principals'` both exist in their value sets. `Underwriting__c` has **no record types**. | `objects/Underwriting__c/fields/Stage__c.field-meta.xml`, `…/Status__c.field-meta.xml`, no `recordTypes/` folder | The two field updates cannot be refused by a restricted picklist, and the "a new approval needs a record-type criterion" concern does not apply to this object. Nothing to design. |
| F7 | `flows/Underwriting_Opp_Sync` is an after-save flow on `Underwriting__c` with **no entry filter** that performs its own `recordUpdates` on the parent Opportunity (4 numeric fields). | `flows/Underwriting_Opp_Sync.flow-meta.xml:38-77` | Once `Underwriting_Approval_Sync` is active there will be **two** Opportunity DMLs per Underwriting save, from two flows with no declared order. See §5.3 — it is safe, but the flow header's "exactly one Opportunity DML" wording is narrower than it reads. |
| F8 | Four seed scripts set `Underwriting__c.Stage__c = 'Approved'` by direct DML. | `scripts/seed-fsd-02-flagship-shallow.apex:149`, `…-03:56`, `…-04:61`, `…-05:86` | Activating the sync flow (W1) changes what those seeds do — they will now also stamp the parent and fire the market-data freeze. Not harmful; must be named so it is not diagnosed as a defect later. |
| F9 | `ProcessInstanceSelector` filters by `TargetObjectId`, not by `ProcessDefinition.DeveloperName`. | `ProcessInstanceSelector.cls:63,139,220` | The `DeveloperName` collision that `DispositionApprovalTrackerService.cls:93` warns about ("`Underwriting_Approval` exists TWICE in this org") becomes *true* after W2 but breaks nothing, because no selector keys on that name alone. Recorded so it is not re-discovered as a scare. |
| F10 | `quickActions/Underwriting__c.Advance_Stage.quickAction-meta.xml` still exists in the repo although `Underwriting_Record_Page` removed its entry on 2026-08-27. | file present | An orphan action file. Not a bypass (F2 — the map has no entry it could use). Out of scope; flagged only so it is not mistaken for a live hop. |

---

## 3. Verification wave W0 — no deploy, and it gates everything

Nothing in W1-W5 may start until W0 is complete. W0 costs an hour and removes the largest
unknowable: **which half of the 2026-08-28 change is already live.**

| ID | Check | How | Why it gates |
|---|---|---|---|
| **V-0** | Is the workaround real? Open a deal at `StageName = 'Underwriting'` as Junior's persona and confirm the **platform** *Submit for Approval* button is present and usable on the Approval History related list. | UI, as the persona — not as an admin | If absent, there is no workaround (§0.2) and the urgency assessment changes. |
| **V-1** | Re-confirm M1, M3, M9 immediately (not at W0 — again at the top of **W2 and W4**). Query `ProcessDefinition` and `ProcessInstance … Status='Pending'`. | SOQL | M9 was measured before this design existed. The workaround is in active use; someone may submit between now and W4, re-creating exactly the pending instance the 2026-08-28 header describes as a trap. |
| **V-2** | Establish the exact repo↔org diff for the whole change set with a **check-only deploy** of the component list in §4, reading the per-component `Changed` / `Unchanged` report. | `sf project deploy start --dry-run` with an explicit component list | This is the only way to learn, component by component, what the org lacks. ⚠ A green dry-run alone proves nothing (byte-identical components report `Unchanged` and are *skipped*, never validated) — the *report*, not the verdict, is the deliverable here. |
| **V-3** | Specifically confirm the deployment state of `UnderwritingSelector` (does the org copy have the `ApprovalAutomationReads` inner class with **both** `selectByIds` and `selectByOpportunityIds`?) and `ApprovalAuditService` (does it read the CHILD's history?). | Tooling API `ApexClass.Body` / `LastModifiedDate`, or V-2's report | **Inference, to be confirmed:** the deployed `ApprovalAuditService` calls `selectByOpportunityIds` (`ApprovalAuditService.cls:91`), so if it is the new version the selector's inner class must already be live too, and the Apex payload reduces to `UnderwritingApprovalStampService` + its test. If that inference is wrong the Apex payload is three classes, not one. |
| **V-4** | Confirm the org copy of the VR body byte-for-byte (M8) and **save it** — that saved copy is the W5 rollback artifact. | retrieve to a target metadata dir | Approval processes are hard to reverse; a VR is trivial to reverse *only if you kept the old body*. |
| **V-5** | Confirm whether `layouts/Underwriting__c-Underwriting Layout` (the `RelatedProcessHistoryList` block, `:143-150`) and `flexipages/Underwriting_Record_Page` (the `force:relatedListContainer`, `:133-149`) are live. | V-2's report | With `recordEditability = AdminOnly`, the **first** submission after W2 locks a record. If the Approval History list is absent there is no Recall route and that record is stuck. These two files are *neither works alone*. |
| **V-6** | Confirm a principal approver who does **not** own an `Underwriting__c` record can open it. `Underwriting__c` is OWD Private with zero sharing rules (`UnderwritingSelector.cls:227`). | `UserRecordAccess` query for one principal against a record owned by someone else | If approvers cannot see the record, the approval page and the Recall route are both compromised, and the `without sharing` escapes in the stamp path are load-bearing rather than belt-and-braces. |
| **V-7** | `git status` / `git diff HEAD` on every file in the §4 component list, plus a fresh org retrieve-and-diff of `Underwriting_Record_Page` and `Underwriting__c-Underwriting Layout` **immediately** before W1 deploys them. | git + targeted retrieve | Concurrent session (§7). A FlexiPage deploy *replaces* the org copy; this repo has lost hand-made App Builder edits that way before. |
| **V-8** | Capture a **baseline** `ApexTestResult` run (or at minimum the current failing-test list with timestamps) before any deploy. | `sf apex run test` + query | A post-deploy test failure is not attributable to us without a baseline. 🔴 **COUNT THE SHARED TREE AT EXECUTION TIME — never trust a figure written in this document.** This row originally asserted "~85 class files mid-edit by another session"; measured 2026-09-01 it was 8, all Broker-Protection, all already deployed, and every other modified `.cls` was OUR OWN work. Any number here describing another session's live working tree is stale by construction within minutes, and acting on it makes you exclude your own changes. Run `git status` and ask the other session for their exhaustive list. |

---

## 4. The deploy order (question 1), with org state between every step

Five waves. **Exactly one component in the whole plan is not cleanly reversible** — and it is
isolated in a wave of its own, on purpose.

---

### W1 — Inert prerequisites

**Components** (deploy as one explicit list; include only those V-2 reported as `Changed`):

| Component | Type | Owner |
|---|---|---|
| `workflows/Underwriting__c.workflow-meta.xml` (`UW_Stage_Approved`, `UW_Status_Approved`) | Workflow field updates | admin |
| `classes/UnderwritingApprovalStampService.cls` + `UnderwritingApprovalStampServiceTest.cls` | Apex | developer |
| `classes/UnderwritingSelector.cls` — **only if V-3 says the org copy lacks `ApprovalAutomationReads.selectByIds`** | Apex | developer |
| `classes/ApprovalAuditService.cls` (+ its test) — **only if V-3 says the org copy still reads the deal's history** | Apex | developer |
| `flows/Underwriting_Approval_Sync.flow-meta.xml` (`<status>Active</status>`) | Flow | admin |
| `layouts/Underwriting__c-Underwriting Layout.layout-meta.xml` — only if V-5 says missing | Layout | admin |
| `flexipages/Underwriting_Record_Page.flexipage-meta.xml` — only if V-5 says missing | FlexiPage | admin |

**Ordering rule inside W1:** the workflow field updates must land **before** the approval process
(W2) — the approval references them by name and cannot deploy otherwise. Both the approval file's
header (`:71-78`) and the workflow file's own header (`:32-34`) state this as load-bearing. The
Apex must land before or with the flow (`Underwriting_Approval_Sync` binds
`UnderwritingApprovalStampService` by name at deploy/activation).

**Test level:** `NoTestRun` or `RunSpecifiedTests`. **`RunLocalTests` cannot pass between now and
the end of W2** — the six failing tests in §6 cannot go green until the approval process exists. A
test-gated W1 deploy will fail for a reason that is not a defect. (`usman-dpeg` is a trial EE org,
not production, so no coverage gate applies.)

**Org state after W1 — production behaviour is UNCHANGED:**
- Two workflow field updates exist on `Underwriting__c`, referenced by nothing (the file
  deliberately has no `<rules>` element — `:10-13`), so they are inert.
- An Apex class exists that nothing calls.
- An after-save flow on `Underwriting__c` is active and fires on `Stage__c` **transitioning to**
  `'Approved'`. **In production, nothing can produce that transition** (F2/F3: no map entry, no
  button, no approval process). So the flow is production-dormant.
- Approval History renders (empty) on Underwriting records.
- The LOI gate, the Opportunity approval and `UW_Approved__c` are all untouched. **No deal is
  affected in any way.**

⚠ **W1 is production-inert but NOT test-inert or seed-inert.** Because `TestDataFactory.approveUnderwriting`
(F4) and four seed scripts (F8) write `Underwriting__c.Stage__c = 'Approved'` by direct DML, the
newly-active flow now fires for them: each such write additionally stamps the parent
(`UW_Approved__c`, `Underwriting_Status__c`) and thereby fires `Opportunity_UW_Approved_Notify`
(market-data freeze + audit stamp). Five test methods and four seed scripts change behaviour at W1
— enumerated in §6.3. **None of them is a 251-record bulk caller** (every
`TestDataFactory.approveUnderwriting` call site is single-record), so there is no governor
exposure.

**Rollback from W1:**
- Fully reversible. Nothing here has created history.
- Flow: `Underwriting_Approval_Sync` must be **deactivated first** (redeploy with
  `<status>Draft</status>` or `Obsolete`) — an active flow cannot be destructively deleted. This
  deactivation is also the plan's **cheapest kill switch**: it stops the parent mirror without
  touching an approval process. Keep it in mind for W3.
- Apex + workflow field updates: `destructiveChanges.xml`, safe because nothing references them
  yet (the approval process does not exist until W2).
- Layout / FlexiPage: redeploy the **copies saved at V-7**. This is the only reason V-7 says
  *save*, not merely *diff*.

---

### W2 — Activate the new approval process 🔴 THE IRREVERSIBLE STEP

**Component:** `approvalProcesses/Underwriting__c.Underwriting_Approval.approvalProcess-meta.xml`,
as written, `<active>true</active>`. Nothing else in this payload.

**Precondition (re-run V-1 minutes before):** `ProcessInstance` pending count = 0 for both
definitions. The repo's own stated procedure for deploying an approval process here is
*recall pending instances, then deploy with `<active>true</active>`*
(`Disposition__c.Broker_Selection_Approval:88-94`). Pending = 0 already satisfies it (M9).

**Org state after W2:**
- **Both processes are active, on different objects.** They cannot conflict: `Approval.process`
  routes purely by object + entry criteria, an `Underwriting__c` submission can only match the
  Underwriting process, and an `Opportunity` submission can only match the Opportunity one.
- *Submit for Approval* on the Underwriting record **works** — the reported defect is fixed at this
  moment, and no later step is required to fix it.
- The Opportunity route (§0.2) still works and remains available as an escape hatch.
- `UW_Approved__c` now has **two** possible writers. Both write `true`. The org's live VR is
  satisfied by either. **The LOI gate is not blocked and never has been in this plan.**
- `ProcessDefinition.DeveloperName = 'Underwriting_Approval'` becomes non-unique (F9 — harmless).

**Rollback from W2:** redeploy the same file with `<active>false</active>`. That returns *behaviour*
to the W1 state.
🔴 **It does not return the ORG to the W1 state, and nothing can.** Once one `ProcessInstance`
exists against the new definition, a `destructiveChanges` delete is refused (that is exactly why
the retired Opportunity file is kept forever — see its header, `:14-16`). The `ProcessDefinition`
row and its history are permanent. **This is the point of no return; everything reversible has
deliberately been placed before it and everything risky after it.**

**If W2's deploy itself fails** (e.g. an unknown field-update name because W1 was skipped or
partially applied): an ApprovalProcess deploys as a single atomic component, so the org is left
**exactly at the W1 state**. Safe failure.

---

### W3 — Live proof 🔴 NO DEPLOY, AND IT IS NOT OPTIONAL

The chain replacing one workflow field update is **four hops long** (§5). A green deploy proves
none of them. Prove it on one designated record before anything is retired.

Required conditions for the proof run:
1. The record is a real `Underwriting__c` at `Stage__c = 'In Progress'` whose parent deal has not
   yet reached LOI.
2. **The approver must be one of the two named principals AND must NOT own the Underwriting
   record.** An approver-owns-the-record test proves nothing about the sharing axis — this project
   has already shipped exactly that bug once, and every test in the suite has approver == owner.
3. Submit via the **Underwriting record's own** *Submit for Approval* button, not by Apex.

Assertions (all must hold; any one failing stops the plan and W4 does not run):

| # | Assertion | Which hop it proves |
|---|---|---|
| P-1 | `ProcessInstance.TargetObjectId` = the **Underwriting** Id; the deal has none | routing |
| P-2 | Child `Stage__c = 'Approved'`, `Status__c = 'Approved by Principals'` | `finalApprovalActions` → workflow field updates |
| P-3 | Parent `UW_Approved__c = true` **and** `Underwriting_Status__c = 'Approved by Principals'` | field update → **record-triggered flow fires** → Apex → parent DML. **This is the hop with no direct precedent on this object.** |
| P-4 | Parent `UW_Approved_By__c` = the approver's Id, `UW_Approval_Date__c` not null | `ApprovalAuditService` reading the **child's** history |
| P-5 | Parent `Market_Data_As_Of_Date__c` = today | the freeze transition survived being fired from a second Opportunity DML in the same transaction (§5.3) |
| P-6 | The deal's `StageName` is **still** `'Underwriting'` | the deliberate loss of the old auto-advance is real and understood, not a surprise later |
| P-7 | Approval History renders on the Underwriting record and *Recall Approval Request* is visible while pending | V-5's two files actually work together |

**The window you asked about lives here, and it is not the one you feared.** Between W2 and a
passing W3, a deal driver who submits and gets approved is depending on an unproven chain. If any
hop fails, the failure is **silent**: the child reads `Approved`, the deal never learns, and *that*
deal is blocked from LOI with nothing to point at. Mitigations, both already in the plan: (a) prove
on a designated record before announcing the button, and (b) the Opportunity route stays live until
W4, so an affected deal has a manual path.

**Rollback from a failed W3:** deactivate `Underwriting_Approval_Sync` (W1's kill switch) and/or
redeploy the approval as `<active>false</active>`. Behaviour returns to pre-cutover with the old
route intact. Any deal already half-processed needs its `UW_Approved__c` set by hand.

---

### W4 — Deactivate `Opportunity.Underwriting_Approval`

**Component:** `approvalProcesses/Opportunity.Underwriting_Approval.approvalProcess-meta.xml`,
`<active>false</active>`. Nothing else.

**Precondition:** W3 fully passed, **and** V-1 re-run immediately before. If anyone used the
Opportunity workaround since W0, a pending instance exists and must be recalled from the UI first
(record owner or Modify All Data), exactly as the file's own header instructs (`:18-34`).

**Do NOT delete anything.** "Retire" means deactivate:
- The four `UW_*` field updates in `workflows/Opportunity.workflow-meta.xml` stay. The retained
  inactive file still references them by name and deleting them breaks it. They go inert.
- The `Opportunity.Underwriting_Approval` file itself stays forever — a destructive delete requires
  no `ProcessInstance` history and this process has history.

**Org state after W4:**
- `UW_Approved__c` has **exactly one** writer again: the new chain. This is the state the VR repoint
  needs, and the first moment it is safe.
- `StageName = 'LOI'` is no longer written by anything automatic. **Initiate LOI becomes a
  deliberate click** (`StageAdvanceService.NEXT_STAGE` `'Underwriting' => 'LOI'`,
  `StageAdvanceService.cls:158`), gated by the still-old VR, which the new chain satisfies. This is
  a real user-visible change: previously approval moved the deal to LOI by itself. **Tell the deal
  drivers.**
- `flows/Opportunity_UW_Approved_Notify`'s `Stamp_Approval_Audit` call becomes structurally
  unchanged but dependent on the child's history — already handled if V-3 confirmed the new
  `ApprovalAuditService`.
- The Opportunity escape hatch is gone.

**Rollback from W4:** redeploy `<active>true</active>`. Mechanically trivial. ⚠ It contradicts the
file's own "DO NOT REACTIVATE" comment, so it is a **conscious, temporary** exception, not a quiet
undo — record it if used.

---

### W5 — Backfill, then repoint the validation rule

Two ordered acts. **The backfill is a precondition of the deploy, not a follow-up.**

**W5a — Backfill (data, no metadata).** Identify every deal that the new rule would newly block:

> Deals whose `StageName` has **not yet** reached LOI, with `UW_Approved__c = true`, and whose
> `Primary_Underwriting__c` is blank **or** whose `Primary_Underwriting__r.Stage__c` is neither
> `'Approved'` nor `'Completed'`.

Each of those was approved under the old regime, is entitled to enter LOI today, and would be
refused tomorrow. Two sub-classes, both real:
- **Child exists but is behind.** Walk it to `Approved`. Note F2: there is no button for this;
  it is an admin DML.
- **`Primary_Underwriting__c` is blank.** The new rule is deliberately **fail-closed** on a blank
  lookup and has *no* blank-lookup exemption — the rule's own header states this and forbids adding
  one (`:45-55`). Under the old rule such a deal could enter LOI. These need a child record created
  and designated (`scripts/backfill-underwriting-records.apex` exists and creates them at
  `Stage__c = 'Requested'` — it is a starting point, not a fix, because `Requested` does not satisfy
  the new rule).

Deals already at LOI or beyond are **grandfathered**: the rule is `ISCHANGED(StageName)`-scoped and
never fires on a deal already sitting there.

**W5b — Deploy the VR.** Single component:
`objects/Opportunity/validationRules/Underwriting_Approved_Before_LOI.validationRule-meta.xml`.

**Org state after W5:** the LOI gate reads the child's own `Stage__c` (naming both `'Approved'` and
`'Completed'` — the second value is load-bearing and prevents a permanent strand on the LOI-rejection
re-entry loop; see the rule's header `:29-43`). `UW_Approved__c` becomes a pure mirror/reporting
field with no gate role.

**Rollback from W5:** redeploy the org body saved at **V-4**. Cheapest rollback in the plan, and the
reason V-4 exists.

---

### 4.1 Summary — is there a blocked window?

| Wave | Deals blocked from LOI? | Reversible? |
|---|---|---|
| W1 | No — nothing changes for any deal | Yes, fully |
| W2 | No — both writers live, old VR satisfied by either | Behaviour yes; the `ProcessDefinition` row, never |
| W3 | No — but a **silent-failure exposure** exists until P-1…P-7 pass | Yes (kill switch) |
| W4 | No — the new chain writes the field the live VR reads | Yes (reactivate) |
| W5 | **Only if W5a is skipped**, and then only for the specific deals it identifies | Yes, cheaply |

**There is no unavoidable window.** Every candidate window in this plan is created by doing two
steps together that do not need to be together.

---

## 5. Question 4 — does the replacement genuinely replace the field update?

### 5.1 What IS replaced — same field, same value, same transaction

| Old (`Opportunity.Underwriting_Approval` `finalApprovalActions`) | New | Verdict |
|---|---|---|
| `UW_Set_Approved_Flag` → `UW_Approved__c = true` | `UnderwritingApprovalStampService.cls:134` → `UW_Approved__c = true` | ✅ **Replaced.** Same field, same value, same transaction. |
| `UW_Set_Status_Approved` → `Underwriting_Status__c = 'Approved by Principals'` | `UnderwritingApprovalStampService.cls:135` → same literal, **same DML shell** | ✅ **Replaced**, and deliberately in one save so the market-data freeze still sees a transition. |

### 5.2 What is NOT replaced — three losses, only one of which is documented as such

| Old action | Replacement | Verdict |
|---|---|---|
| `UW_Set_Stage_Initiate_LOI` → `StageName = 'LOI'` | **Nothing.** The deal driver must click Initiate LOI. | ❌ **Not replaced — deliberately.** An approval process can field-update only its own record or a Master-Detail parent, and `Underwriting__c.Opportunity__c` is a **Lookup** (`deleteConstraint SetNull`), so the new process *structurally cannot* touch the Opportunity. This is a user-visible workflow change, not a defect. |
| `UW_Reopen_For_Revision` → `Underwriting_Complete__c = 0` on reject | **Nothing.** | ❌ **Not replaced.** Accepted regression D2, pinned by a test on purpose. See §8.1 — I think this is the weakest part of the design. |
| — | `UW_Approved_By__c` / `UW_Approval_Date__c` | ➕ Written by `ApprovalAuditService` one save later, from the **child's** history. Unchanged in kind, repointed in source. |

### 5.3 The mechanism question — and the honest answer

The old writer was **one hop**: approval → field update on the Opportunity itself.
The new writer is **four hops**:

```
approval granted
  → finalApprovalActions: UW_Stage_Approved / UW_Status_Approved write the CHILD's own fields
    → that re-save fires the after-save record-triggered flow Underwriting_Approval_Sync
      (entry: Stage__c EqualTo 'Approved', doesRequireRecordChangedToMeetCriteria = true)
      → Apex action UnderwritingApprovalStampService.stampParent
        → ONE Database.update on the parent Opportunity (UW_Approved__c + Underwriting_Status__c)
          → Opportunity_UW_Approved_Notify (transition-scoped) → ApprovalAuditService + MarketDataSnapshotService
```

**Hop 2→3 — "does a workflow field update fired by an approval process trigger an after-save
record-triggered flow?" — is the one that carries risk, and I will not assert it from memory.**
What I can give you is the **in-repo precedent** (F5), which is as close to proof as a repo can get:

- `LOI_Approval` (Opportunity, **active in the org today**) fires `Set_LOI_Approved_Flag`, a
  workflow field update writing `LOI_Approved__c = true`.
- `LOI_Approval_Stamp` is an **after-save record-triggered flow** on Opportunity, entry
  `LOI_Approved__c EqualTo true`, `doesRequireRecordChangedToMeetCriteria = true` — structurally
  identical to `Underwriting_Approval_Sync`.
- `LoiGateTest` walks the real approval and asserts the downstream stamp.

So the shape is **live, exercised and tested in this org** — on Opportunity. It is not proven on
`Underwriting__c`. That is the entire justification for making W3 a mandatory gate rather than a
nice-to-have. **P-3 is the assertion that closes it.**

**Three further silent-failure modes on that chain, and where each is already handled:**

| Mode | Handled where | Still needs proving |
|---|---|---|
| The child read returns empty because the approver cannot see the Underwriting row (OWD Private, zero sharing rules) | `UnderwritingSelector.ApprovalAutomationReads` is `without sharing` + `WITH SYSTEM_MODE` (`:241,265`) | Only if V-3 confirms that version is deployed |
| The parent write silently does nothing for a non-owner approver | `ParentStampWriter` is `without sharing` + `AccessLevel.SYSTEM_MODE` + `allOrNone = true` so it throws loudly (`UnderwritingApprovalStampService.cls:173-176`) | W3 with a **non-owner** approver — this is the whole reason condition 2 is stated |
| The freeze transition is consumed by a *second* parent write in the same transaction | Two flows do write the parent (F7): `Underwriting_Opp_Sync` (4 numeric fields, no entry filter) and `Underwriting_Approval_Sync`. **Neither writes the other's trigger field**, so the freeze fires on the stamp's save regardless of flow order. Safe. | P-5 confirms it empirically |

⚠ **A wording correction worth carrying forward:** `Underwriting_Approval_Sync`'s header says the
freeze "depends on the mirror stamp landing in exactly one Opportunity DML" (`:59-63`). Read
literally that is not achievable — `Underwriting_Opp_Sync` also writes the parent on the same save.
What the header actually means, and what is true, is *one DML for the stamp's own two fields*. Do
not let a future reader "fix" `Underwriting_Opp_Sync` on the strength of the looser reading.

---

## 6. Question 6 — every test whose behaviour changes

### 6.1 The six currently failing on `NO_APPLICABLE_PROCESS` — all go green at W2

| # | Class.method | Why it fails now |
|---|---|---|
| 1 | `UnderwritingGateTest.principalApprovalStampsTheDealMirrorWithoutAdvancingTheStage` | `Approval.process` on an Underwriting at `In Progress` — no process exists |
| 2 | `UnderwritingGateTest.principalRejectionLeavesTheUnderwritingInProgressAndClearsNothing` | same |
| 3 | `UnderwritingGateTest.underwritingSubmitsFromInProgressWithoutCompleteFlag` | submits via `OpportunityApprovalController` and asserts a pending instance on the child |
| 4 | `OpportunityApprovalServiceTest.submitsFromUnderwritingRecordTargetsTheUnderwritingItself` | asserts the **positive** (instance exists AND targets the child); its own comment (`:133-137`) says this half was deferred to post-deploy |
| 5 | `OpportunityApprovalServiceTest.underwritingWithParentAtLoiNeverEntersLoiApproval` | the fixture needs the submission to genuinely succeed on the child's own process |
| 6 | `ApprovalAuditServiceTest.anApprovalOnTheUnderwritingRecordStampsTheDealsAuditFields` | its header (`:59-65`) states the fixture is "UNBUILDABLE" until this deploys — a deliberate tripwire for exactly this moment |

These six are the **acceptance criteria for W2**, not merely a side effect. #1 in particular walks
the entire four-hop chain and is the automated twin of W3's P-2…P-5.

### 6.2 Tests that begin RUNNING for the first time (W1)

`UnderwritingApprovalStampServiceTest` — 7 methods
(`stampsBothMirrorFieldsInOneSaveAndFiresTheMarketDataFreeze`, `perRecordCostDoesNotGrowWithBatchSize`,
`twoUnderwritingsOnOneDealCollapseToASingleUpdateShell`, `orphanUnderwritingIsSkippedNotThrown`,
`aValidRequestIsStampedEvenWhenBatchedWithAnOrphan`, `nullEmptyAndBlankRequestsDoNothing`,
`reStampingIsIdempotent`). Currently absent from the org along with the class under test. These are
not "moving" — they have never run in this org, so treat their first green as new information, not
as a regression check.

### 6.3 Tests that change behaviour at **W1**, not W2 — the non-obvious set

Once `Underwriting_Approval_Sync` is active, **every** call to `TestDataFactory.approveUnderwriting`
writes the child to `Stage__c = 'Approved'` (F4) and therefore now also fires the stamp → the parent
mirror → `Opportunity_UW_Approved_Notify` (audit stamp + market-data freeze). Five call sites:

| Class.method | New side effects to expect |
|---|---|
| `StageApprovalGatesTest.underwritingApprovedGate_blocksLoiEntryUntilApproved` | parent gains `Underwriting_Status__c`, `Market_Data_As_Of_Date__c`, `UW_Approval_Date__c` |
| `StageAdvanceServiceTest` (`:124`) | same |
| `StageAdvanceControllerTest` (`:81`) | same |
| `NdaDealProgressionGateTest` (`:36`) | same |
| `OpportunityApprovalServiceTest.underwritingWithParentAtLoiNeverEntersLoiApproval` (`:193`) | same |

**None of these is a 251-record bulk caller** — every call site is single-record — so there is no
governor exposure. Any of them that asserts one of those parent fields is *unset* will flip; none
appears to, but this is the set to re-run and read carefully at W1 rather than at W2.

### 6.4 Tests that do NOT move, recorded so they are not chased

- `OpportunityApprovalControllerTest.submitsFromUnderwritingRecordNeverSubmitsTheParent` — its
  comment (`:107-110`) says the assertion holds in **both** cases, by design. Passes before and
  after.
- `OpportunityApprovalServiceTest.anUnderwritingSubmissionIsUnaffectedByTheNdaGate` — passes before
  and after, but for a **different reason** each time (today: `NO_APPLICABLE_PROCESS` swallowed by
  its catch-all; after: refused for its own `Requested` stage). It is currently near-vacuous. Not
  work — just do not read its green as evidence of anything at W2.
- All `TestDataFactory`-based fixtures at **W5**: `approveUnderwriting` already satisfies **both**
  rule versions (F4), so **no test fixture needs editing for the VR repoint.**

### 6.5 One deliberate follow-up the suite is already asking for

`StageApprovalGatesTest.underwritingApprovedGate_blocksLoiEntryUntilApproved:68-75` loosened its
message assertion to `'cannot enter LOI until'` specifically to survive this migration, and says
**"Tighten to the full new string once that rule ships."** That is a post-W5 chore the suite has
pre-recorded. Raising it here so it is a decision, not an omission — it is not designed in this doc.

---

## 7. Concurrent-session collision surface (constraint)

I cannot run git from this agent. The component list to check against the other session's working
set (V-7) is:

| Component | Collision risk |
|---|---|
| `classes/ApprovalAuditService.cls` (+ test) | ⚠ **Shared with the LOI gate.** RESOLVED 2026-09-01: `git status` on this file is CLEAN and the concurrent session confirmed it is not theirs. No coordination needed; treat as a pure org-vs-repo staleness question. |
| `classes/UnderwritingSelector.cls` | ⚠ Same reasoning, lower likelihood |
| `classes/UnderwritingApprovalStampService.cls` (+ test) | 🟢 New file, no other consumer |
| `flexipages/Underwriting_Record_Page.flexipage-meta.xml` | 🔴 The other session holds **`NDA_Record_Page`**, not this one — but a FlexiPage deploy *replaces* the org copy and this repo has already lost hand-made App Builder edits that way. Retrieve-and-diff seconds before deploying. |
| `layouts/Underwriting__c-Underwriting Layout.layout-meta.xml` | 🟢 Not named as theirs |
| `workflows/Underwriting__c.workflow-meta.xml`, both `approvalProcesses/*`, the VR, `flows/Underwriting_Approval_Sync` | 🟢 Not named as theirs |
| **Permission sets, app nav, tabs** | 🟢 **This plan touches none.** Deliberate — a permission-set deploy replaces its whole `fieldPermissions` set, and hub files are where parallel streams collide. |
| `classes/DispositionApprovalTrackerService.cls` | ⚠ Theirs, and its header (`:93`) already documents the `Underwriting_Approval` DeveloperName collision that W2 makes real. It needs no change (F9), but tell them it has become true. |

🔴 **Also communicate R-0 (§0.1) to the other session before W1.** A repo-wide deploy from their
side performs this entire cutover accidentally.

---

## 8. Question 7 — things I think are a bad idea, stated plainly

**8.1 Dropping reject handling entirely (decision D2) is the weakest part of this design, and I
would re-open it before W2, not after.**
On rejection: the child stays at `Stage__c = 'In Progress'` (that value *is* the entry criterion, so
nothing moves), `Underwriting_Complete__c` is no longer cleared, and — the part that matters — **no
record-triggered automation anywhere can detect that a rejection happened.** A same-value write is
not a change. The only durable evidence is the approval history. In an org where this approval is
the gate to LOI, a rejected deal is now a deal that silently stops with no signal to its driver and
nothing any report can key on. The design documents this honestly in four places and pins it with a
test, which is the right way to accept a loss — but it is still a loss, and it is *cheaper to fix
before W2 than after*, because editing an active approval process to add a `finalRejectionActions`
entry is a live-process edit rather than a fresh deploy. In-repo precedent for the shape exists
(`Disposition_Offer__c.Approval_Status__c` + `Set_Offer_Approval_Approved/Rejected`). **I am not
designing that here** — it is a new field and you did not ask for one. I am asking you to confirm
D2 deliberately, with today's information, rather than inherit it from 2026-08-28.

**8.2 Do not deploy this as one atomic payload.** It is the intuitive move ("one deploy, no
windows") and it is wrong here: it bundles the one irreversible component with eight reversible
ones, so any failure forces reasoning about partial rollback of a mixed payload — and, worse, it
removes the proof step (W3) between activating the new process and retiring the old one. The
windows it "closes" do not exist anyway (§4.1).

**8.3 Do not land the validation-rule repoint with, or before, the process swap** (this is your
question 3, answered directly):

| Timing | Result |
|---|---|
| **Before** the swap | 🔴 **Catastrophic.** The rule would read `Primary_Underwriting__r.Stage__c`, and F2 proves **nothing in the org can write `'Approved'` to that field** — no map entry, no button, no approval process. Every deal is blocked from LOI with no route out. This is the blocked window you were worried about, and this ordering is the only way to actually create it. |
| **Same payload** as the swap | 🔴 Bad. Component order within a deploy is Salesforce's choice. If the rule activates while the *old* process is still active, the old process's `UW_Set_Stage_Initiate_LOI` field update (`StageName = 'LOI'`) meets a rule whose child-stage condition is not satisfied — a live approval could be refused mid-flight. It also fuses the irreversible step to a reversible one. |
| **After** W4, with a backfill (W5) | ✅ **Correct.** The only casualties are the specific deals W5a identifies, and W5a exists to fix them first. |

**8.4 Do not delete anything.** Not the four `UW_*` field updates in
`workflows/Opportunity.workflow-meta.xml` (the retained inactive approval still references them by
name), not the retired approval file (a destructive delete is refused once history exists), and not
`quickActions/Underwriting__c.Advance_Stage` (orphaned, harmless, out of scope — F10).

**8.5 Do not treat a green deploy as the acceptance criterion.** The one hop with no precedent on
this object (hop 2→3, §5.3) fails *silently* if it fails at all. The acceptance criterion is W3's
P-1…P-7 on a live record, approved by a non-owner principal.

**8.6 Do not run `RunLocalTests` as a deploy gate before W2 completes.** The suite is already red
(the six in §6.1) and cannot go green until the approval process exists. A test-gated W1 fails for a
reason that is not a defect, and with many class files modified in the shared tree, the result would
not be attributable anyway. Baseline first (V-8), `RunSpecifiedTests` in between, full
`RunLocalTests` once at the end of W2.

**8.7 Do not assume the workaround is available** until V-0 confirms it (§0.2). The Apex-backed
quick action on the Opportunity refuses at the Underwriting stage; only the platform button on the
Approval History related list can reach the still-active process.

---

## 9. Admin vs Developer split

### 9.1 Honest statement of scope before the prompts

**There is no new code to write, and no new metadata to author.** Every component this cutover needs
already exists in `force-app`. Both prompts below are therefore *verify, sequence, deploy, prove* —
not *build*. If either specialist finds themselves authoring a new field, a new flow branch, a new
class or a new test, they have exceeded this design and should stop and come back.

---

### 🔵 PROMPT FOR `salesforce-admin`

```
Execute the declarative half of the Underwriting approval cutover described in
agent-output/underwriting-approval-cutover-design.md. Read that document first; it is the
specification. Author NO new metadata — every file you deploy already exists in force-app.
If you find yourself creating a file, stop and report.

Record `mcp=complete|unavailable` + `mcp_tools=<list>` per metadata type before any deploy,
and load the matching per-type skill. Note: `.mcp.json` in this repo configures only the
`salesforce` server, so `salesforce-api-context` is expected to be unavailable — make a real
attempt, record the result, fall back to the skill.

BLOCKING PRECONDITION (R-0): confirm with the concurrent session that no repo-wide or
directory-wide deploy will run until this cutover completes. Three staged files in
approvalProcesses/ and objects/Opportunity/validationRules/ would perform the entire cutover
accidentally, unsequenced. Every deploy you make is an explicit component list.

W0 — verification only, no deploy. Complete V-0 through V-8 from §3 of the design and report
     the results. Do not proceed on any item that comes back other than expected.
     V-4 and V-7 require you to SAVE the org copies you retrieve — they are the rollback
     artifacts for W1 and W5.

W1 — deploy, as ONE explicit component list, only those components V-2 reported as `Changed`:
       workflows/Underwriting__c.workflow-meta.xml
       flows/Underwriting_Approval_Sync.flow-meta.xml         (Active)
       layouts/Underwriting__c-Underwriting Layout.layout-meta.xml     (if missing)
       flexipages/Underwriting_Record_Page.flexipage-meta.xml          (if missing)
     Coordinate with the developer stream: the Apex in their prompt must land in this same
     wave, before or with the flow.
     Test level: NoTestRun or RunSpecifiedTests. RunLocalTests CANNOT pass until W2.
     Re-run V-7's retrieve-and-diff on the FlexiPage and the layout seconds before deploying.

W2 — re-run V-1 (pending ProcessInstance count must be 0 for both definitions), then deploy
     ONE component: approvalProcesses/Underwriting__c.Underwriting_Approval, as written,
     <active>true</active>. Nothing else in this payload. This is the irreversible step.

W3 — no deploy. Run the live proof in §4/W3: submit a real Underwriting record at
     Stage__c = 'In Progress', approved by a named principal who does NOT own the record.
     Report P-1 through P-7 individually. If any fails, STOP — do not run W4 — and report.

W4 — re-run V-1. If a pending instance exists on Opportunity.Underwriting_Approval, a human
     must recall it in Setup first (see that file's own header). Then deploy ONE component:
     approvalProcesses/Opportunity.Underwriting_Approval, <active>false</active>.
     Delete NOTHING — not the four UW_* field updates in workflows/Opportunity.workflow-meta.xml,
     not the approval file itself.

W5 — W5a first: run the backfill query in §4/W5a and report the affected deals BEFORE fixing
     anything. Both sub-classes (child behind, and blank Primary_Underwriting__c) need
     handling. Then W5b: deploy ONE component, the validation rule
     objects/Opportunity/validationRules/Underwriting_Approved_Before_LOI.

After W4, tell the deal drivers that approval no longer advances the deal to LOI — Initiate LOI
is now a deliberate click.
```

---

### 🟢 PROMPT FOR `salesforce-developer`

```
Support the Apex half of the Underwriting approval cutover described in
agent-output/underwriting-approval-cutover-design.md. Read that document first.

WRITE NO NEW APEX AND NO NEW TESTS. Every class this cutover needs already exists in
force-app/main/default/classes. Your job is to establish which org copies are stale and to
deploy the repo versions of exactly those. If you find yourself authoring a method, a class or
a test method, you have exceeded this design — stop and report.

W0 (verification, contributes to the admin stream's V-3):
  Determine, for each of these three classes, whether the ORG copy matches the repo copy:
    - UnderwritingApprovalStampService  (measured ABSENT from the org — expect to deploy)
    - UnderwritingSelector              (does the org copy carry the ApprovalAutomationReads
                                         inner class with BOTH selectByIds and
                                         selectByOpportunityIds?)
    - ApprovalAuditService              (does the org copy read the CHILD's approval history,
                                         i.e. call selectByOpportunityIds?)
  Use a check-only deploy's per-component Changed/Unchanged report and/or the Tooling API.
  Do not infer from LastModifiedDate alone.
  Working hypothesis to confirm or falsify: because the deployed ApprovalAuditService is
  believed to call selectByOpportunityIds, UnderwritingSelector is probably already current and
  the payload reduces to UnderwritingApprovalStampService + its test. If that is wrong, say so —
  it changes the W1 payload from one class to three.

W1 (deploy, coordinated into the admin stream's W1 payload, BEFORE or WITH
    flows/Underwriting_Approval_Sync, which binds the Apex action by name):
    - classes/UnderwritingApprovalStampService.cls + UnderwritingApprovalStampServiceTest.cls
    - classes/UnderwritingSelector.cls        ONLY if W0 showed it stale
    - classes/ApprovalAuditService.cls (+test) ONLY if W0 showed it stale
  Test level: NoTestRun or RunSpecifiedTests. RunLocalTests cannot pass until W2 —
  six tests (listed in §6.1) are failing on NO_APPLICABLE_PROCESS by construction.

  ⚠ Before deploying ApprovalAuditService or UnderwritingSelector, check `git status` — a
  concurrent session has files mid-edit — COUNT THEM YOURSELF, do not trust any figure in this doc — and ApprovalAuditService is shared with the
  LOI gate. If either file is in their working set, do NOT carry it; report and coordinate.

W2+ (verification only, no code):
  After the admin stream activates the approval process, run the six tests in §6.1 of the design
  and confirm they go green. Then run the five tests in §6.3 — they change behaviour at W1
  because TestDataFactory.approveUnderwriting now fires the newly-active sync flow — and report
  anything that moved. Capture a baseline test result BEFORE W1 so post-deploy failures are
  attributable.

  Do NOT edit any test fixture for the W5 validation-rule repoint. TestDataFactory
  .approveUnderwriting already satisfies BOTH rule versions (it sets UW_Approved__c AND the
  primary child's Stage__c = 'Approved'). If a fixture appears to need editing, that is a signal
  something else is wrong — report it rather than patching it.
```

---

## 10. Open decisions for the user (not designed here)

| # | Decision | Why it needs you |
|---|---|---|
| D-a | **Confirm or re-open D2** — rejection produces no automated signal at all (§8.1). Confirming it is a legitimate answer; inheriting it silently is not. | Adding a rejection marker is a new field, which you did not request. |
| D-b | Accept that approval no longer advances the deal to LOI (§5.2) and that Initiate LOI becomes a manual click, and decide who tells the deal drivers. | User-visible workflow change. |
| D-c | Whether the `StageApprovalGatesTest` message assertion is tightened after W5 (§6.5). | The suite has pre-recorded the request; it is a chore, not a defect. |
| D-d | If V-0 finds the workaround is not actually available to Junior's persona, confirm whether the urgency assessment changes (§0.2). | Changes "urgent but not an emergency" to something else. |
```
