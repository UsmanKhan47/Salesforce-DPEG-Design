# Disposition BA Gap Closure — TRANCHE 3 Design (Approvals)

**Date:** 2026-08-31
**Agent:** salesforce-design (analysis only — no metadata, no Apex, no org writes)
**Branch at time of writing:** `qa/lifecycle-simulation-2026-08-27`
**Scope:** exactly the four numbered items in the request. Nothing added, nothing expanded.
**Sources read, in the order requested:** `agent-output/disposition-ba-stories-gap-analysis.md`
(including the USER-CONFIRMED resolutions A1-A4 / C1 / D1-D4 / E1-E4 / B1-B3, the Gate 1 record and
the OPEN VERIFICATION DEBT section, all treated as settled decisions);
`agent-output/disposition-gap-closure-t1-design.md` (DEPLOYED `0Afiw000000UCLVCA4`) and
`…-t2-design.md` (DEPLOYED `0Afiw000000UJwTCAW`); `docs/2026-08-19-disposition-flow-redesign.md`
(decisions D-1 and C-2 treated as inviolable); `ARCHITECTURE.md`, `CLAUDE.md`, `.claude/rules/*.md`.

---

## 0. Mandatory gate declarations, and the limits of this agent

```
intent=type | best_matched_skill=none (design step only — no metadata generated here)
skill_selection=complete
mcp=unavailable | mcp_tools=none
```

`.claude/rules/salesforce-global-rule.md` mandates a `salesforce-api-context` MCP call per metadata
type. **A real attempt is not possible from this agent** — `.mcp.json` configures only the
`salesforce` server and subagents carry no MCP tools. Recorded `mcp=unavailable`, `mcp_tools=none`.
Every implementing agent must re-attempt and re-record per metadata type, and fall back to the
per-type skill.

🔴 **THIS AGENT HAS NO ORG ACCESS.** Its tool set is file-system only (Read / Write / Edit / Glob /
Grep). There is no `sf` CLI and no Salesforce MCP here. The request contains four instructions to
"query the org" (the four principals' usernames; pending `ProcessInstance` rows; the deactivate /
reactivate behaviour; the NDA record-type value subset). **Every one of them is escalated below as a
blocking gate with the exact query to run, and none of them is guessed.** Where the repo contains
evidence that bears on the answer, that evidence is given — but repo evidence is not an org
measurement and is never presented as one.

**Consequence carried into the plan:** any XML shape not already exercised in this repo is a
**blocking gate with a one-item dry-run and a readback**, never a guess. Two shapes qualify here —
**G-3** (changing `assignedApprover` on an ACTIVE approval process) and **G-4** (a `LongTextArea` as
an `approvalPageFields` entry). `ARCHITECTURE.md` §3.4 records what guessing an unproven shape costs.

---

## 1. Premise verification — measured against the repo before designing

Twenty-three load-bearing claims were checked. **Nine hold as stated. Eighteen findings below are
new, incomplete or wrong in the request in a way that changes the design.** They lead, because they
drive every recommendation that follows.

### 1.1 CONFIRMED

| Claim | Evidence |
|---|---|
| All five processes name exactly two approvers, `type=user`, `whenMultipleApprovers = FirstResponse` | `Sale_Decision_Approval:153-165`, `Broker_Selection_Approval:153-168`, `Closing_Approval:137-152`, `Broker_Finalize_Approval:132-147`, `Offer_Selection_Approval:91-106` |
| All five are `<active>true</active>`, `allowRecall=true`, `recordEditability=AdminOnly` | same five files |
| Approval #3 (NDA issue) does not exist | `approvalProcesses/` holds 8 files; none targets `NDA__c` |
| `NDA__c.Principal_Approved__c` (Checkbox) and `Principal_Approved_Date__c` (Date) exist, with **no writer** | both field files present; repo-wide grep finds them only in the two field files, the two disposition permission sets, and the T1 design doc |
| `Disposition_NDA` `Status__c` is exactly `Prepare → Approved → Sent → Signed`, plus `Declined`, **no default** | `recordTypes/Disposition_NDA.recordType-meta.xml:250-272` and its 2026-08-25 amendments |
| `NDA__c` has two record types with different `Status__c` sets; `Acquisition_NDA` is `Pending / Received / Signed` | `recordTypes/Acquisition_NDA…`, cited at `RecordStageAdvanceService:234-236` |
| `Is_Approved_For_Release__c` is `ISPICKVAL(Status__c,'Signed')` with **no record-type guard**, and reads TRUE on acquisition NDAs | field file `:78-84`, S-2 note |
| `Disposition__c.Sell_Meter_Override_Reason__c` exists (LongTextArea 4000) and is **not** in `Sale_Decision_Approval`'s `approvalPageFields` | field file; approval file `:144-150` |
| `lwc/dispositionApprovalHistory` + controller + service build a consolidated history across three objects, newest first | `DispositionApprovalHistoryService.cls:320-344` |

### 1.2 🔴 EIGHTEEN FINDINGS THAT CHANGE THE DESIGN

---

**P-1. The two-approver roster is REPO-WIDE, not disposition-specific. It is 8 of 8 approval
processes, not 5.**

`Opportunity.LOI_Approval`, `Opportunity.Underwriting_Approval` and
`Underwriting__c.Underwriting_Approval` name the **same two users** with the same `FirstResponse`
setting (`Underwriting__c.Underwriting_Approval:113-123`). Item 1 as scoped fixes five of eight and
leaves the acquisition module at two principals.

That is not a reason to widen the tranche — it is a fact the BA needs, because after this ships
"any one of four principals" will be true on the sell side and false on the buy side, and the next
person to read `Opportunity.LOI_Approval` will not know whether that is a decision or an oversight.
**Decision D-3.**

---

**P-2. 🔴 Editing `approvalPageFields` on an ACTIVE approval process is ALREADY PROVEN IN THIS REPO.
Item 4 is not gated by the same question as item 1.**

The request states item 4 "is gated by the same deactivate/reactivate question as item 1". Measured:

- `Broker_Selection_Approval`'s **2026-08-20** amendment changed `approvalPageFields` (dropped three
  BOV fields, added `Broker__c`) on a process that was already `<active>true</active>`, and shipped.
- `Sale_Decision_Approval`, `Broker_Selection_Approval`, `Closing_Approval` and
  `Broker_Finalize_Approval` all gained `initialSubmissionActions`, `recallActions` and a second
  `finalApprovalActions` entry on **2026-08-21**, in place, active.
- All five had their process `<label>` and their step `<label>` changed on **2026-08-26** — a change
  **inside `<approvalStep>`** — in place, active.

**Not one of those four edits mentions deactivating anything.** The repo's own operating procedure
for these files is stated in `Broker_Selection_Approval:88-94`: *"RECALL ANY PENDING INSTANCES
BEFORE DEPLOYING"* — recall, then deploy with `<active>true</active>`. There is no deactivate step
anywhere in this repo's approval history.

⇒ **Item 4 carries the pending-instance question and nothing else.** Item 4's real unknown is a
different one entirely — see P-13 and G-4.

---

**P-3. What IS unproven is item 1's change, and it is unproven for a specific reason: no edit in
this repo has ever touched `assignedApprover`'s CONTENT.**

The 2026-08-26 rename edited `<approvalStep><label>` — a sibling of `<assignedApprover>`, not its
child. Adding an `<approver>` element changes the **step definition**, which the Setup UI refuses on
an active process. Whether the Metadata API refuses it, silently versions it, or accepts it, is
**not exercised anywhere in this repo and cannot be established from here**. That is exactly the
class of unknown `ARCHITECTURE.md` §3.4 warns about, and the failure direction matters: a deploy
that reports success while the org keeps two approvers is the dangerous outcome, because nothing in
the test suite can observe an approver roster. → **G-3**, a one-file dry-run, a readback of
`ProcessInstance`/`ProcessDefinition` metadata, **and a real submit-and-look**, before the other four.

---

**P-4. ⚠ The pending-instance question is very probably MOOT, and the measurement is cheap.**

The gap analysis measured `usman-dpeg` on 2026-08-31: **0 `Disposition__c` records.** Three of the
five processes target `Disposition__c`, so they can have zero pending instances by construction. The
other two target children of a Disposition. **That is a strong prior, not a measurement** —
`BOV_Submission__c.Disposition__c` and `Disposition_Offer__c.Disposition__c` are Lookups, so an
orphaned child row is possible. → **G-2** measures it in one query. Expect zero; do not assume it.

---

**P-5. 🔴 `c/dispositionApprovalHistory` IS NOT PLACED ON ANY FLEXIPAGE IN THIS REPO. The card item 3
proposes to extend renders nowhere today.**

A repo-wide grep for `dispositionApprovalHistory` returns seven files: the bundle itself, its test,
its CSS, the two Apex classes, `ProcessInstanceSelector` (a comment), and
`DPEG_Apex_Access` (a comment). **No `flexipages/*.xml` names it.** `Disposition_Record_Page`'s
`componentName` list is: `force:highlightsPanel`, `force:relatedListContainer`,
`runtime_sales_pathassistant:pathAssistant`, `dispositionMain`, and in the sidebar
`dispositionDealSummary`, `dispositionSidebar`, `bovBrokerChangeHistory`, `dispositionBuyerTimeline`.

The bundle's own header opens *"the CONSOLIDATED, READ-ONLY 'Approval History' card in the
Disposition record page sidebar"* and the FlexiPage's 2026-08-26 retrieve note enumerates the
sidebar without it. **One of those two is wrong.** Either the bundle was built and never placed, or
it was placed in App Builder and the retrieve did not capture it — and this repo has a measured
incident of a FlexiPage deploy clobbering App Builder edits with no version history (2026-08-25,
recorded in this very file). → **G-7** resolves it against the org. Until it is resolved, "extend
the existing tracker" is a change to a component **nobody can see**, and item 3's deliverable
necessarily includes **placing** it.

---

**P-6. 🔴 A ONE-CLICK BYPASS OF APPROVAL #3 ALREADY EXISTS, AND IT IS HELD BY THE WRONG PERSONA.**

This is the single most consequential correction in this document.

`RecordStageAdvanceService`'s `NDA_DISPOSITION_NEXT_STAGE` map carries **`'Prepare' => 'Approved'`**
(class header `:64`, `:73-76`), gated on `DISPOSITION_DRIVER` = the `Disposition_Deal_Actions`
custom permission. `NDA_Record_Page` renders a quick action for it:

```
quickActions/NDA__c.Move_to_Approved.quickAction-meta.xml   label "Approved"
NDA_Record_Page:294  <value>NDA__c.Move_to_Approved</value>
                     visible when Disposition_Deal_Actions AND Status = 'Prepare' AND
                                  RecordType.DeveloperName = Disposition_NDA
```

`Disposition_Deal_Actions` is granted by **`DPEG_Disposition_Edit` — the ANALYST set** — and its own
file forbids it on `DPEG_Disposition_View`, the Principal set (recorded in T2's P-5). So today **an
analyst moves a disposition NDA from `Prepare` to `Approved` in one click, and a principal cannot.**
Adding an approval whose final action writes the same value, and leaving that button in place, ships
an approval anyone can walk around.

The repo already forbids exactly this shape, in the same class, in terms:

> `RecordStageAdvanceService:143-148` — *"Adding `Broker Selection -> NDA` to the off-market map
> would hand a user a one-click bypass of `Broker_Selection_Approval`."*

⇒ **Item 2 is not only "build an approval". It is "build an approval AND retire the hop and the
button that currently perform the same transition."** Three files move together:
`RecordStageAdvanceService`'s map, `NDA_Record_Page`'s `actionNames` entry, and the quick action
file (which the page comment says must be retired with its entry). **Decision D-7.**

---

**P-7. 🔴 `NDA_Record_Page` and `NDA__c-NDA Layout` have NO approval-history surface, so an
`AdminOnly` NDA approval would lock the record with NO route to Recall.**

- `NDA_Record_Page` carries `force:relatedListSingleContainer` (line 674) and **not**
  `force:relatedListContainer`. `Disposition_Record_Page:188-197` records the measured API fact:
  the Single container answers `INVALID_TYPE` for `ProcessSteps` / `RelatedProcessHistoryList` /
  `ApprovalHistory`, so pointing it at approval history **deploys green and renders nothing**.
- `layouts/NDA__c-NDA Layout` carries exactly one related list: `RelatedNoteList`. There is no
  `RelatedProcessHistoryList` block.

Both halves are required and **neither works alone** — the same two-file fix
`Disposition_Record_Page` made on 2026-08-19 (code review C-3), for the same reason: with
`recordEditability = AdminOnly` and `allowRecall = true`, the related list's action bar is the only
Recall route in the UI. Without it, a submitted NDA whose approver is on leave is a locked record
with a Path, uneditable fields, and nothing on screen explaining why.

---

**P-8. 🔴 `NDA_Record_Page` has `enableActionsConfiguration = true`, so the platform's generic
"Submit for Approval" button is NOT inherited. A submit route has to be built.**

`NDA_Record_Page:412-413`. Turning Dynamic Actions on discards the page's inherited
`platformActionList` entirely (measured on this project) — which is why that page enumerates
`Move_to_*`, `Mark_Declined` and `Edit_NDA` explicitly. There is no `Submit` entry. **Decision D-9.**

---

**P-9. `NdaTrigger` is `before insert, before update` and NOTHING ELSE. There is no after-update
context on `NDA__c`.**

`triggers/NdaTrigger.trigger:52`, with a header block titled *"WHY `before insert, before update`
AND NOTHING ELSE"*. ⇒ There is no trigger seam for an approval mirror, and adding one is a widening
of a trigger the repo deliberately kept narrow (`Is_Approved_For_Release__c`'s header rejected a
trigger-written field on exactly that ground). **Everything item 2 writes must be written by
workflow field updates**, which is also what makes it route-independent.

---

**P-10. `NDA__c` has no `workflows/` file and no `validationRules/` folder. Both are absences, not
oversights, and one of them is a new file.**

`force-app/main/default/workflows/` holds seven files; `NDA__c` is not among them.
`objects/NDA__c/validationRules/` does not exist. Item 2 therefore creates
`workflows/NDA__c.workflow-meta.xml` — precedent: `BOV_Submission__c` and `Disposition_Offer__c`
each got a new workflow file in the same change as their new approval process, and both those
approval files carry the same deploy-order note: **the workflow must land FIRST or the approval file
fails on an unknown field update.**

---

**P-11. The acquisition path is protected by DML as well as by criteria — and the failure direction
is a REFUSED APPROVAL, not a bad write. State it; still add the criterion.**

`NDA__c.Status__c` is `<restricted>true</restricted>`, and this repo has measured **four times** that
the record-type subset is enforced by DML, not just the UI (`Acquisition_NDA`'s 2026-08-20
correction; the `Review` incident on 2026-08-25; the `Sent` incident on 2026-08-27). `Acquisition_NDA`
exposes `Pending / Received / Signed` — **neither `Prepare` nor `Approved`**. So:

- an acquisition NDA can never reach `Status__c = 'Prepare'` and so can never satisfy the entry
  criterion;
- if it somehow did, the final approval's `Status__c = 'Approved'` field update would be **refused
  by DML at the approver's click** — a failed approval with an opaque restricted-picklist error, not
  a value parked on the wrong record type.

⇒ The explicit `Is_Disposition_NDA__c = true` criterion is still required, and
`Broker_Selection_Approval`'s own retraction says why: *"'Broker Selection' is on BOTH record types'
value sets … so the new entry stage is NOT self-limiting the way BOV Outreach was."* A value set can
change in Setup in one click, three times in eleven days on this very object. Do not rely on
self-limitation.

✅ **And `Is_Disposition_NDA__c` is the right discriminator, already built and already granted.**
`RecordType.DeveloperName = "Disposition_NDA"`, read FLS in both disposition sets, exact same shape
as `Is_On_Market__c` in `Broker_Selection_Approval`'s criterion 2. On a Master-typed row it reads
FALSE, so the process **fails closed** — the correct polarity for a disposition-only gate, and the
opposite of `Broker_Selection_Approval`'s documented fail-open residual.

---

**P-12. `Principal_Approved_Date__c` is a `Date`, and T1 explicitly deferred the Date-vs-DateTime
question TO THIS TRANCHE. A workflow field update can write `TODAY()` to it and nothing else.**

`Principal_Approved_Date__c`'s own header: *"If Tranche 3's final approval action stamps NOW()
rather than TODAY(), this field is the wrong type and must become a DateTime named
`Principal_Approved_DateTime__c` instead — additively, per the same delete+create constraint …
Confirm the required precision before Tranche 3 wires a writer."* **Decision D-6.**

---

**P-13. 🔴 Item 4's real unknown is not deactivation — it is whether a `LongTextArea` can be an
`approvalPageFields` entry at all. And if it cannot, the field is invisible to EVERYONE.**

Every `approvalPageFields` entry across all eight approval files is `Name`, `Owner`, a picklist, a
checkbox, a currency, a number, a text, a lookup or a formula. **There is no LongTextArea anywhere**,
so the shape is unproven here.

And `Sell_Meter_Override_Reason__c` is on **no FlexiPage and no page layout** — a repo-wide grep
returns only `DispositionService`, its test, `sellMeterList.js`, the two permission sets, the field
file and the custom permission file. ⇒ **the approval page is currently the only place that field
could ever be read by a human.** If the Metadata API refuses it there, item 4 does not degrade — it
delivers nothing, and the T2 audit fact stays write-only. → **G-4**, with a named fallback in
**D-18**.

✅ One half of item 4 is already de-risked: `DPEG_Disposition_View` grants
`Disposition__c.Sell_Meter_Override_Reason__c` `readable=true` (line 1831), so the approving
principal **can** read it. An approver who cannot read an `approvalPageFields` entry sees a blank,
not an error — a trap `Broker_Finalize_Approval` and `Offer_Selection_Approval` both call out. Not a
trap here.

---

**P-14. 🔴 The five processes are not five TYPES. Two of them are the same BA type, and after item 2
there will be SIX processes for FIVE types.**

| BA approval type | Process(es) | Applies to |
|---|---|---|
| #1 Sale Decision | `Disposition__c.Sale_Decision_Approval` | both record types |
| #2 Broker Selection | `BOV_Submission__c.Broker_Finalize_Approval` | **On_Market only** |
| #2 Broker Selection | `Disposition__c.Broker_Selection_Approval` | **Off_Market only** (entry criterion `Is_On_Market__c = False`) |
| #3 NDA issue | *(item 2 builds it)* | Disposition NDAs only |
| #4 Offer Selection | `Disposition_Offer__c.Offer_Selection_Approval` | both |
| #5 Closing | `Disposition__c.Closing_Approval` | both |

A five-row checklist must therefore **collapse the two broker processes into one row** and mark the
non-applicable variant **N/A by record type**, not "missing". A tracker that lists six rows, or that
shows a permanently-empty off-market row on an on-market sale, reports a defect that does not exist.
**Decision D-15.**

---

**P-15. `Offer_Selection_Approval` is the ONE of five with no `initialSubmissionActions` and no
`recallActions`, and `Disposition_Offer__c` has NO `Approval_Pending__c` field.**

`Disposition_Offer__c/fields/` contains `Approval_Status__c` and no pending flag;
`BOV_Submission__c/fields/` contains both. ⇒ **A tracker keyed on the `Approval_Pending__c` flags
would be structurally blind on the offer type.** Key it on `ProcessInstance.Status` — which the
existing service already reads and already publishes raw. **Decision D-17.**

---

**P-16. `ProcessInstanceSelector.selectHistoryByTargetIds` selects `ProcessDefinition.Name` — a
LABEL that has been renamed twice — and not `DeveloperName`.**

`ProcessInstanceSelector.cls:121-132`. The 2026-08-26 rename changed four of the five labels
("Sale Decision Approval" → "Decide to Sell Approval"; "Broker Finalize Approval" → "Broker Selection
Approval (BOV)"; "Broker Selection Approval" → "Broker Selection Approval (Off-Market)"). A checklist
that identifies an approval type by matching that string is keyed on **copy**, and the copy has
already moved once inside this programme. The stable key is `ProcessDefinition.DeveloperName`, which
the selector does not currently request.

✅ Widening it is safe: `ProcessDefinition` is a system entity whose fields are non-permissionable,
which is the exact property that makes a `USER_MODE` spanning read safe (measured on this project
2026-08-28). The selector's header already argues the same for `ProcessDefinition.Name`. **This is
not an FLS change.**

---

**P-17. 🔴 `DispositionApprovalHistoryService.resolveTargets` resolves THREE objects. NDAs are not
among them — so an NDA approval would not appear in the existing card at all. And adding them breaks
a pinned governor assertion.**

`resolveTargets` (`:320-344`) queries `DispositionSelector.selectNameById`,
`BovSubmissionSelector.selectApprovalTargetsByDispositionId` and
`DispositionOfferSelector.selectApprovalTargetsByDispositionId`. An `NDA__c` `ProcessInstance` would
have a `TargetObjectId` absent from `targetsById`, and `getHistory` `continue`s past it (`:298-302`).

`DispositionApprovalHistoryServiceTest.manyChildren_costsExactlyFourQueries` (`:373-390`) asserts
`Assert.areEqual(4, used, …)`. Adding an NDA lookup makes it **five**. The assertion must move in the
same change, with its message updated — it is the class's *"highest-value governor assertion"* and
must not be deleted to make a build green.

✅ `NdaSelector` already exists and already has `selectByDispositionIds` (`WITH SYSTEM_MODE`, an
automation read). The tracker read is a **user-requested** read on a record page, so it needs its own
`WITH USER_MODE` method in the same selector — not a reuse of the automation one. The selector's
header already enumerates two SYSTEM_MODE methods and seven USER_MODE ones and must gain the new
method's line.

---

**P-18. `DPEG_Apex_Access` grants Apex by CONTROLLER NAME, so any new controller is a THIRD hub
permission-set edit — and a PermissionSet deploy replaces the whole file.**

`DPEG_Apex_Access` carries `<apexClass>DispositionApprovalController</apexClass>` and
`<apexClass>DispositionApprovalHistoryController</apexClass>`, each with an incident comment
(`:99-113` records a **live break on 2026-08-21** — *"no such class named
'DispositionApprovalController'"* — caused by shipping a controller without its grant). Item 2's
submit route needs the same entry. Three permission-set files are therefore in this tranche's blast
radius (`DPEG_Apex_Access`, and `DPEG_Disposition_View`/`_Edit` only if D-10 adds a field), and
`git status` already shows `DPEG_Transaction_Edit` / `_View` modified by work that is not this
tranche. → **G-6**, and the parallel-build hub-file protocol.

---

## 2. Decisions for Gate 1

These are the only genuinely open questions. Each carries a recommendation and its evidence.
**Nothing here re-opens a USER-CONFIRMED resolution.**

| # | Decision | Recommendation |
|---|---|---|
| **D-1** | 🔴 **Item 1 — the two additional principals' exact `Username` values.** Nothing in this repo names Junior or Nick. All eight approval processes name only `nikhil.dhanani@usmandpeg.uat` and `aftab.ali.dpeg.usman@avanzasolutions.com`. | **BLOCKED ON G-1.** The names must come from the org, not from this document. If either has no `IsActive = true` User, **item 1 becomes a provisioning request, not a metadata edit**, and must be reported as such — an `<approver><name>` naming a nonexistent username fails the deploy, and one naming an *inactive* user is worse: it deploys and silently routes to somebody who cannot respond, which `FirstResponse` masks for as long as the other three answer. |
| **D-2** | **Item 1 — mechanism: four hardcoded `type=user` approvers, or a queue / public group?** | **Four hardcoded users.** It matches all eight existing processes, and the alternative is worse here: **group and queue membership is NOT deployable metadata**, so a deployed-but-unpopulated queue routes every approval to nobody, silently — the same failure class as this project's empty `Acquisitions_Deal_Update` public group. ⚠ Say the residual out loud: four hardcoded org-specific usernames are **not portable** to a sandbox or a production org, and the whole roster must be re-authored there. That is already true of the two in place. |
| **D-3** | **Item 1 — scope: five disposition processes only (P-1).** | **Yes, five only** — the request says exactly these five. But record the resulting asymmetry in each edited file's XML comment and report it to the BA: after this, "any one of four principals" is true on the sell side and false on the buy side (`Opportunity.LOI_Approval`, `Opportunity.Underwriting_Approval`, `Underwriting__c.Underwriting_Approval`). Confirm you want the acquisition three left alone. |
| **D-4** | **Item 2 — the approval's developer name and entry criteria.** | **`approvalProcesses/NDA__c.NDA_Issue_Approval.approvalProcess-meta.xml`.** Entry: `Status__c equals 'Prepare'` **AND** `Is_Disposition_NDA__c equals True`, `booleanFilter 1 AND 2` — byte-identical in shape to `Broker_Selection_Approval`'s two-criterion form. ⚠ The name is **shorthand — flagged, not invented**; confirm or supply. |
| **D-5** | **Item 2 — what `finalApprovalActions` writes.** | **Three field updates, one block:** `Status__c = 'Approved'`, `Principal_Approved__c = true`, `Principal_Approved_Date__c = TODAY()`. All three are required and none is redundant — `Principal_Approved__c`'s own header states the design in terms: *"Tranche 3's final approval action should set BOTH — the stage-position picklist AND this audit pair — in the same transaction. Do not treat one as redundant with the other."* The picklist drives the Path; the pair is the audit fact. |
| **D-6** | **Item 2 — `Principal_Approved_Date__c` stays a `Date`, or becomes a DateTime (P-12)?** | **KEEP `Date`.** Story 23 asks for "checkbox + date"; a workflow field update writes `TODAY()` cleanly; and the **precise timestamp already exists and is already surfaced** — `ProcessInstance.CompletedDate` and each `ProcessInstanceStep.CreatedDate` are read by `DispositionApprovalHistoryService` and rendered by the card. Converting is a delete + create with a reserved API name (T1 item 6's machinery) for information the tracker already shows. Mark the field header's open question **ANSWERED and dated**, quote-and-retract, do not delete it. |
| **D-7** | 🔴 **Item 2 — retire the competing one-click writer (P-6)?** | **YES, and it is not optional.** Remove `'Prepare' => 'Approved'` from `RecordStageAdvanceService.NDA_DISPOSITION_NEXT_STAGE`; remove the `NDA__c.Move_to_Approved` entry from `NDA_Record_Page`'s `actionNames`; and per that page's own convention ("Retire both together") delete `quickActions/NDA__c.Move_to_Approved`. Keep `'Approved' => 'Sent'`, `'Sent' => 'Signed'`, the legacy `'Not Sent' => 'Sent'` and the `Declined` explicit target **untouched**. Add a `NO_NEXT_STEP_HINTS` entry naming the approval as the owner of the `Prepare` hop, exactly as the Disposition config does for its seven approval-owned transitions — otherwise the Advance path refuses at `Prepare` with wording that reads like a bug. ⚠ **Alternative if you want the button kept:** it must then be re-gated onto a Principal-held token, which is a new custom permission and a new authorization boundary — more work than retiring it, and it leaves two writers for one transition. |
| **D-8** | **Item 2 — `recordEditability` and `allowRecall`.** | **`AdminOnly` + `allowRecall = true`**, matching all five siblings. ⚠ **This makes P-7's two-file Approval History addition MANDATORY, not a nicety** — without it a submitted NDA is locked with no Recall route anywhere in the UI. Confirm you accept the lock; the alternative (`recordEditability = AllowOwner`) diverges from every other approval in the module and lets the owner edit `Status__c` out from under a pending approval. |
| **D-9** | **Item 2 — the submit route (P-8).** | **A new headless quick action + LWC + `NdaApprovalService`**, mirroring `Submit_Sale_Decision` / `c/dispositionSubmitForApproval` / `DispositionApprovalService.submitForApproval`. The service pre-checks (`Status__c = 'Prepare'`, record type is Disposition_NDA, no pending instance via `ProcessInstanceSelector.selectPendingByTargetId`) with authored messages, asserts `DispositionActionPermissionService.assertDispositionActionAccess()` as its first statement, and calls the one-argument `Approval.process(request)` with only `setObjectId` set. **Rejected alternative:** adding the platform `Submit` entry to `actionNames` — cheaper, but the redesign dropped that button on the Disposition page precisely because it routes around the authored pre-checks, and here it would surface an unmet entry criterion as the platform's opaque *"no applicable approval process was found."* |
| **D-10** | **Item 2 — does the NDA get an `Approval_Pending__c` flag and the four-action clear pattern?** | **NO in T3 — but state what that costs.** The four Disposition/BOV processes carry it to hide their Submit buttons; here the server already refuses a second submit with an authored message. What is genuinely worse without it: while the approval is pending, the record is `AdminOnly`-locked, so **`Mark Declined` renders and throws `ENTITY_IS_LOCKED`** if clicked. That is a noisy refusal, not a silent one, and closing it costs a new field + FLS in two permission sets + four workflow field updates + four action blocks + two FlexiPage criteria. Confirm you accept the noisy refusal, or approve the extra work explicitly. |
| **D-11** | **Item 2 — rejection behaviour.** | **No `finalRejectionActions` at all.** A rejected NDA stays at `Status__c = 'Prepare'`, the lock releases, and it can be corrected and resubmitted — the same "parked for a re-pick" shape `Offer_Selection_Approval` documents. ⚠ And note the trap this avoids: a rejection field update writing `Status__c = 'Prepare'` would be **writing the value the record already holds** — the exact no-op failure measured on the Underwriting approval move. Confirm nothing downstream needs to observe a rejection. |
| **D-12** | **Item 2 — the acquisition path, stated explicitly (as the request requires).** | **NOTHING CHANGES ON `Acquisition_NDA`.** It cannot enter the process (`Prepare` is not on its value set, and criterion 2 excludes it by record type); no field update can reach it; `NDA__c.Advance_Stage` and the three acquisition `Move_to_*` entries on `NDA_Record_Page` are untouched; `Is_Approved_For_Release__c` is unchanged. The only shared artefact edited is `RecordStageAdvanceService`, and only its **disposition** map — the class header's two surviving reasons for keeping the two maps split (the gate, and the `Declined` allow-list) are both strengthened by this change, not weakened. |
| **D-13** | 🔴 **Item 2 — `Is_Approved_For_Release__c`'s missing record-type guard (T1 note S-2).** T1 recorded it as *"Tranche 3 is expected to wire a reader."* | **DO NOT WIRE A READER IN T3, AND DO NOT CHANGE THE FORMULA.** Nothing in this tranche's four items needs to read it: item 2's gate is `Status__c = 'Prepare'`, not "approved for release". Changing the formula to add `AND(Is_Disposition_NDA__c, …)` is a behaviour change to a field with zero consumers, which is cost without benefit and creates a diff nobody can test. **Amend the S-2 note in place** to record that T3 examined it, wired no reader, and that the guard stays the reader's responsibility — so T4/T6 does not read "Tranche 3 was expected to" and assume it happened. Confirm. |
| **D-14** | **Item 3 — extend `dispositionApprovalHistory`, or build a sibling (P-5, P-17)?** | **EXTEND — and PLACE it.** One bundle, one Apex round trip, one FlexiPage edit. The checklist is derived **client-side** from the payload `getHistory` already returns, plus one new DTO member (`processApiName`) and the NDA targets. A sibling component would repeat four or five queries on every page view and could disagree with the card beside it about the same approval. ⚠ **The deliverable includes placing the bundle on `Disposition_Record_Page`** — pending G-7 it renders nowhere, so "extending" it changes nothing visible. Recommended position: the **sidebar tab**, after `bovBrokerChangeHistory`, matching the sidebar's existing card idiom. Confirm the region. |
| **D-15** | **Item 3 — the five rows, and how the two broker processes collapse (P-14).** | **Five rows, fixed order, matching the FSD numbering:** `1 Sale Decision` · `2 Broker Selection` · `3 NDA Issue` · `4 Offer Selection` · `5 Closing`. Row 2 reads whichever of the two broker processes applies **to this record type** and marks the other **N/A**, never "not started". Confirm the five labels. |
| **D-16** | **Item 3 — the NDA row when a sale has several NDAs (one per party).** | **Aggregate: `n of m approved`**, with the row state `Pending` if any NDA has a pending instance, `Approved` only when every disposition NDA on the sale has one, `Not started` when none has been submitted. ⚠ Confirm: this is the one row whose cardinality is not 1, and a naive "show the latest" would report a sale as approved on the strength of one party out of three. |
| **D-17** | **Item 3 — the state vocabulary, and where state comes from (P-15).** | **Derive from `ProcessInstance.Status`, never from the `Approval_Pending__c` flags** (the offer object has none). Vocabulary reuses the bundle's existing `STATUS_META` map exactly — `Pending` / `Approved` / `Rejected` / `Recalled` (raw `Removed`) / `Reassigned` / `No Response` — plus two new states the map does not have: **`Not started`** (no instance) and **`N/A`** (wrong record type). Keep the mapping in JS, not Apex, per the bundle's own recorded reason (a copy decision, pinned in Jest, changeable without a deploy). |
| **D-18** | 🔴 **Item 4 — the fallback if a `LongTextArea` is refused on the approval page (P-13, G-4).** | **Fallback: add `Sell_Meter_Override_Reason__c` to the Disposition record page instead** (a `flexipage:fieldSection` entry on `Disposition_Record_Page`, or the classic layout), so the approver can click through from the approval request and read it — the record is `AdminOnly`-locked, which blocks editing, not viewing. ⚠ It is a strictly worse answer (one more click, and the approver has to know to look), which is why it is a fallback and not the plan. Confirm you want the fallback taken automatically if G-4 fails, or reported back for a decision. |
| **D-19** | **Item 4 — position in the list.** | **Immediately after `Sell_Decision_Trigger__c`**, so the approver reads *why* next to *what kind*. T2 made `Sell_Decision_Trigger__c` honest — it now reads `Principal Decision` on an override instead of the default `Sell Meter Green` — and the free text is that value's explanation. Confirm. |

---

## 3. Item-by-item design

### 🔵 Item 1 — the two missing principals on five approval processes (stories 15, 21, 47, 53) — ADMIN

**Deliver:** two additional `<approver>` elements inside `<assignedApprover>` in **five files**.
Nothing else in any of the five changes — not `whenMultipleApprovers`, not `<label>`, not
`<name>Principal_Review_Step</name>`, not `entryCriteria`, not any action block.

| File | Current | After |
|---|---|---|
| `Disposition__c.Sale_Decision_Approval` | 2 approvers, `FirstResponse` | 4 approvers, `FirstResponse` |
| `Disposition__c.Broker_Selection_Approval` | " | " |
| `Disposition__c.Closing_Approval` | " | " |
| `BOV_Submission__c.Broker_Finalize_Approval` | " | " |
| `Disposition_Offer__c.Offer_Selection_Approval` | " | " |

`whenMultipleApprovers = FirstResponse` is **already correct and must not be touched** — it is what
makes "any one of the four satisfies the gate" true. The AC's second half ("a single principal being
unavailable never blocks the sale") is satisfied by the roster, not by the setting.

**Order inside `<assignedApprover>`:** append the two new `<approver>` blocks after the existing two.
Under `FirstResponse` the order has no runtime meaning; appending keeps the diff to two additions per
file and makes the change reviewable.

🔴 **Sequencing (G-1 → G-2 → G-3 → the other four).** Establish the usernames; sweep pending
instances; prove the shape on **`Sale_Decision_Approval` alone** with a check-only dry-run, a
readback, **and a real submission that shows four approvers on the request**; only then the other
four. This mirrors exactly the protocol
`Sale_Decision_Approval:88-100` already imposed on itself for the unproven `recallActions` shape —
*"That file is deliberately deployed and behaviourally proven FIRST AND ALONE."*

⚠ **A green deploy is not proof.** Nothing in the Apex or Jest suite can observe an approver roster.
The acceptance criterion is a submitted approval request showing four assignees.

**Risk: MEDIUM.** Mechanically trivial (10 XML elements). The risk is entirely (a) inventing a
username, which is why D-1 is blocked, and (b) an unproven metadata shape on an active process whose
failure direction is silent.

---

### 🔵🟢 Item 2 — Approval #3, NDA issue (stories 23, 24, 51; decision D-1 from Tranche 1)

Six artefacts, in a strict order. **T1 already shipped the two fields and their FLS in both
disposition permission sets — item 2 adds no field and needs no FLS pass** (unless D-10 is
overturned).

#### 2a. `workflows/NDA__c.workflow-meta.xml` — NEW FILE (ADMIN)

Three `fieldUpdates`, no rules, no alerts:

| Name | Field | Operation |
|---|---|---|
| `Set_NDA_Status_Approved` | `Status__c` | Literal value `Approved` |
| `Set_NDA_Principal_Approved` | `Principal_Approved__c` | Literal `true` |
| `Set_NDA_Principal_Approved_Date` | `Principal_Approved_Date__c` | Formula `TODAY()` |

🔴 **This file must land BEFORE the approval process file** or the approval fails on an unknown field
update — the same load-bearing note `BOV_Submission__c.Broker_Finalize_Approval:59-60` and
`Disposition_Offer__c.Offer_Selection_Approval:56-58` both carry.

⚠ **`Set_NDA_Status_Approved` writes a RESTRICTED picklist value.** `Approved` is on
`Disposition_NDA` and **not** on `Acquisition_NDA`, and this org has measured four times that the
subset is DML-enforced. The record-type criterion in 2b is what keeps this write reachable only where
the value exists. **The `recordTypes/Disposition_NDA` file must be live in the org before this
deploys** — record-type-before-Apex/workflow ordering is mandatory here (G-8).

#### 2b. `approvalProcesses/NDA__c.NDA_Issue_Approval.approvalProcess-meta.xml` — NEW FILE (ADMIN)

| Element | Value | Why |
|---|---|---|
| `active` | `true` | |
| `allowRecall` | `true` | D-8 |
| `recordEditability` | `AdminOnly` | matches all five siblings; makes 2e mandatory |
| `allowedSubmitters` | `<type>owner</type>` | matches all five siblings. ⚠ See the residual below. |
| `entryCriteria` | `booleanFilter 1 AND 2`; `NDA__c.Status__c equals Prepare`; `NDA__c.Is_Disposition_NDA__c equals True` | D-4, P-11 |
| `approvalStep` | 4 approvers (item 1's roster), `FirstResponse`, `allowDelegate false`, `<name>Principal_Review_Step</name>` | consistent with all eight |
| step `<label>` | e.g. `Principal approves NDA release` | 🔴 **must be distinct.** The 2026-08-26 rename exists precisely because five identical "Principal Review" labels meant approvers could not tell which decision they were being asked for. Do not reintroduce the defect on a sixth. |
| `finalApprovalActions` | the three field updates from 2a | D-5 |
| `finalRejectionActions` | *(none)* | D-11 |
| `initialSubmissionActions` / `recallActions` | *(none)* | D-10 |
| `showApprovalHistory` | `true` | |
| `approvalPageFields` | `Name`, `Owner`, `Disposition__c`, `Counterparty_Name__c`, `Party_Role__c`, `Status__c`, `OneDrive_URL__c` | ⚠ **every one must have read FLS in `DPEG_Disposition_View`** — an approver who cannot read a field on the approval page sees a blank, not an error (the note both child-object approvals carry). Verify against that file before writing; do not add a field to this list without checking. |
| `<description>` | ≤ 255 chars | the five existing files carry 442-617-char descriptions, so the cap is **not** enforced here — but every file in this programme keeps under 255 so the rule never has to be re-measured. Follow the convention. |
| XML comment | inside the root element | a comment above the root breaks `sf` at source conversion. |

⚠ **`allowedSubmitters = owner` residual, stated not hidden.** Disposition NDAs are auto-created by
`DispositionStageEntryService` at `DISPOSITION_NDA_INITIAL_STATUS = 'Prepare'`, so the owner is
whoever advanced the Disposition into the NDA stage. A *different* analyst picking the deal up cannot
submit. That is identical to all five siblings and is accepted for consistency — but say it, because
it is the first approval in this module on an object created by automation rather than by the person
who works it.

#### 2c. `RecordStageAdvanceService` — retire the competing hop (DEVELOPER)

Per **D-7**: remove `'Prepare' => 'Approved'` from `NDA_DISPOSITION_NEXT_STAGE`; add a
`NO_NEXT_STEP_HINTS` entry naming `NDA_Issue_Approval` as the owner of that transition. Retract the
2026-08-25 paragraph that added the hop **in place** (quote it, date the retraction) — this class's
header has been rewritten three times on this exact map and the history is explicitly the point.
Everything else in both NDA maps is untouched.

⚠ `RecordStageAdvanceServiceTest` will have a test asserting the `Prepare → Approved` hop; it must
be **inverted to a refusal test**, not deleted, so the bypass cannot come back silently.

#### 2d. The submit route (ADMIN + DEVELOPER), per D-9

| Layer | Component |
|---|---|
| Quick action | `quickActions/NDA__c.Submit_NDA_Approval.quickAction-meta.xml` — `LightningWebComponent`, headless, `actionSubtype Action`, label e.g. "Submit for Approval". No `<description>` (0 of 80 quick actions in this repo carry one). |
| LWC | a headless `RecordAction` bundle, mirroring `c/dispositionSubmitForApproval` (permission pre-flight, toast, `notifyRecordUpdateAvailable`). Jest + `@sa11y/jest` required. |
| Service | **new** `NdaApprovalService.submitForApproval(Id ndaId)` — `with sharing`, `DispositionActionPermissionService.assertDispositionActionAccess()` as the **first statement**, then authored pre-checks, then `ProcessInstanceSelector.selectPendingByTargetId(ndaId)` for the already-pending refusal, then the one-argument `Approval.process`. |
| Controller | **new** thin `@AuraEnabled` wrapper throwing `AuraHandledException` at the boundary. |
| FlexiPage | one `valueListItems` entry on `NDA_Record_Page`, `booleanFilter 1 AND 2 AND 3`: `{!$Permission.CustomPermission.Disposition_Deal_Actions} EQUAL true` (🔴 three-segment form only — the other two spellings are rejected by the Metadata API), `{!Record.Status__c} EQUAL Prepare`, `{!Record.RecordType.DeveloperName} EQUAL Disposition_NDA`. Placed where `Move_to_Approved` was. |

🔴 **Do NOT modify `DispositionActionPermissionService`** — its header states *"THE TWO CLASSES ARE
ONE DESIGN ON TWO MODULES — CHANGE BOTH OR NEITHER"* against its `OpportunityActionPermissionService`
twin. Call it; do not touch it.

🔴 **`DPEG_Apex_Access` must gain the new controller's `<apexClass>` entry, in the same wave.** That
file records a live production break on 2026-08-21 caused by omitting exactly this (P-18).

#### 2e. Approval History on the NDA — MANDATORY, two files (ADMIN), per P-7 / D-8

1. `flexipages/NDA_Record_Page` gains a **`force:relatedListContainer`** component (identifier
   `relatedLists`, `showActionBar = true`). 🔴 **Not `force:relatedListSingleContainer`** — the page's
   three existing lists use the Single container correctly because their targets are ordinary child
   relationships; approval history is not one, and the Single container answers `INVALID_TYPE` and
   renders nothing while deploying green.
2. `layouts/NDA__c-NDA Layout` gains a `relatedLists` entry `RelatedProcessHistoryList`, **alongside
   the existing `RelatedNoteList`, not replacing it.**

Neither half works alone. Without both, the first submitted NDA is a locked record with no Recall
route — the precise gap `Disposition_Record_Page` closed on 2026-08-19.

**Risk: HIGH.** Not for any one artefact, but because item 2 is six coupled artefacts across four
metadata types plus Apex, with a strict deploy order, a competing writer that must be retired in the
same wave, and a lock whose escape hatch is itself two files.

---

### 🟢 Item 3 — the five-approval tracker (story 52) — DEVELOPER

**Decision:** extend, do not duplicate (D-14). The deliverable is **one new section inside
`c/dispositionApprovalHistory`**, plus the placement the bundle has never had.

#### What "extend" actually costs

| Layer | Change |
|---|---|
| `ProcessInstanceSelector.selectHistoryByTargetIds` | add `ProcessDefinition.DeveloperName` to the SELECT (P-16). Not an FLS change — `ProcessDefinition` fields are non-permissionable. Amend the method's own mode note. |
| `NdaSelector` | **new** `selectApprovalTargetsByDispositionId(Id)`, `WITH USER_MODE`, returning **every** disposition NDA on the sale — `Id, Name, Counterparty_Name__c, Party_Role__c, Status__c`. ⚠ **Unfiltered by status**, matching the two sibling methods' documented rule: *"an approval-history read filters on nothing but parentage."* Add its line to the class header's USER_MODE inventory (it goes from 7 to 8). |
| `DispositionApprovalHistoryService.resolveTargets` | a fourth loop adding NDA targets. `targetDetail` = `Counterparty_Name__c`, falling back to `Party_Role__c`, else null — the same shape `brokerHint` already uses. |
| `ApprovalRow` DTO | one new `@AuraEnabled String processApiName`. |
| `DispositionApprovalHistoryServiceTest` | 🔴 `manyChildren_costsExactlyFourQueries` becomes **five**. Rename it, update the message, and add NDAs to the fixture. Do not delete it (P-17). |
| `lwc/dispositionApprovalHistory` | a **checklist section above the history list**: five fixed rows, state derived client-side from the payload. |
| `flexipages/Disposition_Record_Page` | **place the bundle** (D-14) — pending G-7. |

#### The checklist logic (client-side, zero extra queries)

```
row 1  Sale Decision      NDA_Issue is not it → key: Sale_Decision_Approval
row 2  Broker Selection   on-market  → Broker_Finalize_Approval   (off-market row = N/A)
                          off-market → Broker_Selection_Approval  (on-market row = N/A)
row 3  NDA Issue          NDA_Issue_Approval, aggregated n-of-m across the sale's NDAs (D-16)
row 4  Offer Selection    Offer_Selection_Approval
row 5  Closing            Closing_Approval
```

Record type comes from an LDS `getRecord` on `Disposition__c.Is_On_Market__c` — the formula checkbox
built for exactly this purpose, already read FLS in both disposition sets, and the discriminator this
repo standardises on (never a bare `{!Record.RecordType.*}`, which is repo-asserted and unmeasured at
the FlexiPage layer). ⚠ **Fail-open direction:** `Is_On_Market__c` reads FALSE on a Master-typed row,
so such a row would show the off-market broker variant. Bounded — `DispositionService` stamps a
record type on every row it creates — and identical to `Broker_Selection_Approval`'s own accepted
residual.

**Row state** = the newest matching `ProcessInstance`'s status, mapped through the bundle's existing
`STATUS_META` plus `Not started` and `N/A` (D-17). "Newest" not "any": a resubmitted approval must
report its current state, not its first.

#### 🔴 What this card is NOT, and must say so

**It offers no actions.** Recall stays reachable only from `force:relatedListContainer` in the
FlexiPage header region — and only for the three Disposition-target approvals, because that component
matches `TargetObjectId`. The bundle's header already carries this warning; the checklist must not be
read as a route to act. ⚠ **State the gap plainly to the BA:** a pending `Broker_Finalize_Approval`
or `Offer_Selection_Approval` will now be *visible* on the Disposition as "Pending", while Recall for
it still requires navigating to the BOV submission / offer record. Making the tracker's pending rows
look actionable without being actionable is the one way this item makes things worse.

**Risk: MEDIUM-HIGH.** The Apex is small and the query cost stays fixed. The risk is (a) the pinned
governor assertion, which must move deliberately rather than be made green; (b) the record-type
asymmetry in row 2, which is easy to get backwards and which **no test in this org can currently
exercise, because there are zero Dispositions**; (c) the placement, which lands on a FlexiPage this
repo has already lost App Builder edits on once.

---

### 🔵 Item 4 — `Sell_Meter_Override_Reason__c` on the Sale Decision approval page — ADMIN

**Deliver:** one `<field>` element in
`approvalProcesses/Disposition__c.Sale_Decision_Approval.approvalProcess-meta.xml`, positioned after
`Sell_Decision_Trigger__c` (D-19):

```
Name · Owner · Disposition_Stage__c · Property_Asset__c · Sell_Decision_Trigger__c
                                                        · Sell_Meter_Override_Reason__c   ← new
```

✅ **De-risked by measurement:** `approvalPageFields` edits on an active process are proven in this
repo (P-2), and `DPEG_Disposition_View` already grants the field read (P-13), so the approver will
not see a blank.

🔴 **The one real unknown is the field TYPE.** No `LongTextArea` appears in any `approvalPageFields`
list in this repo. → **G-4**: a check-only dry-run of this one file, a readback, and — because a
readback of the XML proves only that the element persisted — **a look at a live approval request
page**. If it is refused, take **D-18**'s fallback rather than dropping the item silently: the field
is currently on no page at all, so a refusal here leaves a T2 audit fact that literally nobody can
read.

⚠ **Sequencing with item 1.** Both edits touch the same file. **Do them in one edit and one deploy**,
not two — a second deploy of an approval process is a second exposure to the pending-instance
question and to whatever G-3 discovers. Item 1's roster and item 4's page field land together in
`Sale_Decision_Approval`, and that file is the one G-3 proves the shape on.

**Risk: MEDIUM.** One element. The exposure is the unproven field type and the fact that failure here
is invisible (a field that does not render looks exactly like a field with no value).

---

## 4. Admin / Solution-Architect / Developer split

### 🔵 ADMIN (`salesforce-admin`)

| Item | Deliverable |
|---|---|
| 1 | Two `<approver>` elements in each of five `approvalProcess-meta.xml` files. `Sale_Decision_Approval` FIRST AND ALONE. |
| 4 | One `approvalPageFields` entry — **in the same edit as item 1's roster on that file**. |
| 2a | **New** `workflows/NDA__c.workflow-meta.xml` (3 field updates). |
| 2b | **New** `approvalProcesses/NDA__c.NDA_Issue_Approval.approvalProcess-meta.xml`. |
| 2d | **New** `quickActions/NDA__c.Submit_NDA_Approval.quickAction-meta.xml`; `NDA_Record_Page` action entry. |
| 2d/D-7 | `NDA_Record_Page` — **remove** the `NDA__c.Move_to_Approved` entry; **delete** that quick action file. |
| 2e | `NDA_Record_Page` — add `force:relatedListContainer`; `layouts/NDA__c-NDA Layout` — add `RelatedProcessHistoryList`. |
| D-18 fallback *(only if G-4 fails)* | `Sell_Meter_Override_Reason__c` onto `Disposition_Record_Page` / the Disposition layout. |

### 🟤 SOLUTION-ARCHITECT (`salesforce-solution-architect`)

| Item | Deliverable |
|---|---|
| 2d | **ONE consolidated pass** over `permissionsets/DPEG_Apex_Access.permissionset-meta.xml`: add the new NDA approval controller's `<apexClass>` entry. |
| D-10 *(only if overturned)* | the `NDA__c.Approval_Pending__c` FLS grant across `DPEG_Disposition_View` + `_Edit`. |

Routed here rather than to admin because it is an authorization edit on a shared hub file with
replace semantics, and because `git status` already shows two other permission sets modified by work
that is not this tranche — `CLAUDE.md`'s routing trigger for this agent.

🔴 **A `PermissionSet` deploy REPLACES the file's entire `fieldPermissions` AND `classAccesses`
collections.** A complete pre-deploy reconciliation needs `FieldPermissions` **+ `ObjectPermissions`
+ `SetupEntityAccess`** — a custom-permission grant is invisible to the first two (measured
2026-08-31).

⚠ **No new fields, no new FLS, in the base plan.** T1 already granted `Principal_Approved__c`,
`Principal_Approved_Date__c` and `Is_Approved_For_Release__c` read in both disposition sets, and T2
granted `Sell_Meter_Override_Reason__c` read in both. **Verified in the files, not assumed.**

### 🟢 DEVELOPER (`salesforce-developer`)

| Item | Deliverable |
|---|---|
| 2c | `RecordStageAdvanceService` — remove `'Prepare' => 'Approved'`, add the `NO_NEXT_STEP_HINTS` entry, retract the 2026-08-25 paragraph in place; invert the corresponding test to a refusal test. |
| 2d | **New** `NdaApprovalService` + controller + headless LWC bundle; Apex tests + Jest + `@sa11y/jest`. |
| 3 | `ProcessInstanceSelector` widening; **new** `NdaSelector` USER_MODE method; `DispositionApprovalHistoryService.resolveTargets` fourth target + `processApiName`; the 4→5 query assertion; the checklist section in `c/dispositionApprovalHistory` + Jest + `@sa11y/jest`. |

**No integration, no Named Credential, no ASB/Plaid/Yardi touchpoint** —
`salesforce-technical-architect` is **not** required for this tranche.

---

## 5. Deploy order

| Wave | Contents | Why here |
|---|---|---|
| **0** | **GATES, no writes.** G-1 … G-9. Nothing is written until every blocking gate has an answer. | Every one of these has produced a silent failure on this project or is structurally unobservable in a test. |
| **1** | **G-3 PROOF: `Sale_Decision_Approval` ALONE** — item 1's two approvers **and** item 4's page field, one edit, check-only dry-run, readback, then a real submission showing four approvers and the reason field on the request page. | The unproven shape (P-3) and the unproven field type (P-13) both live in this one file. Prove them together, once, on the process the module enters through. |
| **2** | **The other four approval processes** — item 1's roster only. | Only after wave 1's behavioural readback passes. Same "first and alone" protocol `Sale_Decision_Approval` already imposed on itself for `recallActions`. |
| **3** | **`workflows/NDA__c.workflow-meta.xml`.** | 🔴 Must precede the approval process or it fails on an unknown field update. Requires `recordTypes/Disposition_NDA` to be live (G-8) because it writes a restricted value. |
| **4** | **`approvalProcesses/NDA__c.NDA_Issue_Approval`.** | Needs wave 3. |
| **5** | **Apex** — `RecordStageAdvanceService` map retirement; `NdaApprovalService` + controller; `NdaSelector` method; `ProcessInstanceSelector`; `DispositionApprovalHistoryService` + its test. | 🔴 **The map retirement (2c) must land in the SAME wave as, or BEFORE, the FlexiPage edit that removes the button (wave 7).** Reversing it leaves a live one-click bypass of a live approval. Layering order within the wave: selectors → services → controllers. |
| **6** | **`DPEG_Apex_Access`** — the new controller grant. | 🔴 Must be same-wave-or-later than wave 5. A `classAccesses` entry naming a class the org does not hold fails the deploy of the entire set; a controller without its grant is a live break (2026-08-21). |
| **7** | **LWC + FlexiPages + layout, LAST.** `c/dispositionApprovalHistory` checklist; the NDA submit bundle; `NDA_Record_Page` (submit entry + `Move_to_Approved` removal + `force:relatedListContainer`); `NDA__c-NDA Layout`; `Disposition_Record_Page` placement. | Needs waves 4-6. FlexiPages last, per this repo's standing order — reversing it hides buttons for everyone, silently. |
| **8** | **Documentation** — header retractions in `RecordStageAdvanceService`, `Principal_Approved_Date__c` (D-6), `Is_Approved_For_Release__c`'s S-2 note (D-13), and the bundle's "in the sidebar" claim (P-5). | Independent; last, so the retractions describe what actually shipped. |
| **9** | **BROWSER ACCEPTANCE. Not a deploy, and NOT DISCHARGEABLE TODAY.** | See §5.2. |

### 5.1 Gates

| # | Gate | Blocking? | Why |
|---|---|---|---|
| **G-1** | 🔴 **Establish the four principals in `usman-dpeg`.** `SELECT Id, Name, Username, IsActive, Profile.Name FROM User WHERE IsActive = true` — and identify which rows are "Junior" and "Nick". **If either does not exist as an active user, STOP and report it as a provisioning question.** | **YES** | Inventing a username fails the deploy; naming an inactive one deploys and routes silently to nobody, which `FirstResponse` masks. This design deliberately contains no candidate usernames. |
| **G-2** | 🔴 **Pending-instance sweep.** `SELECT Id, Status, TargetObjectId, ProcessDefinition.DeveloperName, CreatedDate FROM ProcessInstance WHERE Status = 'Pending'`. Recall every hit on the five processes before deploying. | **YES** | `Broker_Selection_Approval:88-94` requires it in terms and states the 2026-08-19 measurement *"has now aged past a day and must be re-run at deploy time, not cited."* Expect zero (0 Dispositions), but the child objects are Lookups so an orphan is possible (P-4). |
| **G-3** | 🔴 **Can an ACTIVE approval process accept an `assignedApprover` change via the Metadata API?** One-file check-only dry-run on `Sale_Decision_Approval`; readback; **then a real submission showing four assignees.** If it is refused, the answer to "does this need deactivate/reactivate" is yes, and G-2's result becomes load-bearing rather than precautionary. | **YES** | Unproven shape, no MCP (P-3). The dangerous direction is a green deploy that leaves two approvers, which no test can see. |
| **G-4** | 🔴 **Can a `LongTextArea` be an `approvalPageFields` entry at 67.0?** Same one-file dry-run; readback; **then look at a live approval request page.** | **YES** | No precedent in this repo (P-13). Failure leaves the T2 audit fact unreadable by anyone (the field is on no page). |
| **G-5** | ⚠ **Dry-run per-component `state`.** Check each component's `state`, not the top-level status. | No | A byte-identical component reports `Unchanged` and **skips validation entirely**; a comment-only edit does not count as a change. The wave-8 documentation files will legitimately report `Unchanged`. |
| **G-6** | 🔴 **Retrieve and diff against HEAD *and* against the org before touching:** `flexipages/NDA_Record_Page`, `flexipages/Disposition_Record_Page`, `layouts/NDA__c-NDA Layout`, `permissionsets/DPEG_Apex_Access`. | **YES** | A FlexiPage deploy **clobbers App Builder edits with no version history** — measured on this project 2026-08-25, and recorded inside `Disposition_Record_Page` itself. A PermissionSet deploy **replaces** whole collections. `git status` shows a concurrent stream editing other permission sets. Also read `SetupAuditTrail` for page saves newer than the last retrieve. |
| **G-7** | 🔴 **Is `c/dispositionApprovalHistory` on the org's `Disposition_Record_Page`?** The repo says no (P-5). | **YES** | Determines whether item 3 is "extend a live card" or "extend a card nobody can see, and place it". If the org HAS it and the repo does not, the repo copy is stale and deploying it **deletes the card**. |
| **G-8** | 🔴 **Re-measure `Disposition_NDA`'s live `Status__c` subset** via the UI API picklist-values endpoint for record type `012iw0000009yeaAAA` — **not** a RecordType retrieve, which strips `picklistValues`. Confirm `Prepare` and `Approved` are both present. | **YES** | Two values left this record type on a single day (2026-08-25), each time in Setup first, each time breaking Apex that named them. The workflow field update in wave 3 writes `Approved`; if it has been removed in Setup, every approval fails at the approver's click. |
| **G-9** | ⚠ **`sf sobject describe` is a stale cache.** Verify anything new via Tooling API with an explicit `TableEnumOrId`. And **`--tests` runs the ORG's copy** of a test class — include every changed test class in the payload. | No | Both measured on this project; the second is how a targeted run reports 100% while executing fewer methods than the repo has. |

### 5.2 🔴 What a deploy can and cannot discharge — read this before promising acceptance

The org holds **0 `Disposition__c` records, 1 `Property_Asset__c` (none on the Sell Meter), and
6 `Property__c`** (measured 2026-08-31; a user-accepted deferral). Split accordingly:

**A deploy + readback CAN discharge:**
- item 1's roster — via a readback of the deployed `ApprovalProcess` metadata (structure only);
- item 4's page field — that the element persisted;
- item 2's six artefacts existing, compiling, and the Apex/Jest suites passing;
- item 3's Apex query count (`Assert.areEqual(5, used, …)`) and every Jest assertion.

**Only DATA can discharge — and none of it is dischargeable today:**
- 🔴 that four assignees actually appear on a submitted approval request (item 1's *entire* AC);
- 🔴 that `Sell_Meter_Override_Reason__c` **renders** on a live approval page (item 4's entire AC);
- that submitting an NDA locks it, that Recall is reachable from the new related list, and that
  approving writes all three fields;
- that the `Prepare` Advance button is gone and the Submit button is in its place;
- that the checklist shows five rows with the correct N/A on each record type, and the `n of m` NDA
  aggregate;
- 🔴 **the whole of item 2 and item 3 as a real non-admin persona.** An admin smoke test proves
  nothing about a `Disposition_Deal_Actions` gate — Modify All Data bypasses it — and nothing about
  an approver's `approvalPageFields` FLS.

⇒ **T3's acceptance criterion is a browser walkthrough on a seeded sale, not a deploy result.** T1
already paid for the alternative: a `ListView` Checkbox filter that was valid XML, a real field and a
valid operator passed **two full code-review passes** and was caught only by a deploy. Everything in
the "data" column above is that same class of risk, one layer further out.

---

## 6. Per-item risk register

| # | Item | Risk | Dominant hazard |
|---|---|---|---|
| 1 | Four principals on five processes | **MED** | 🔴 **G-1 is unanswerable from here** — the usernames must come from the org, and if Junior/Nick have no active User this is provisioning, not metadata. 🔴 **G-3 is an unproven metadata shape on an ACTIVE process** whose failure direction is a green deploy that changed nothing; no test in the suite can observe an approver roster. ✅ Mitigated by P-4: with 0 Dispositions the pending-instance risk is very probably nil. ⚠ Leaves the three acquisition processes at two approvers (P-1). |
| 2 | Approval #3 — NDA issue | **HIGH** | 🔴 **A one-click bypass already exists and is held by the ANALYST persona** (P-6) — the approval is decorative unless `Prepare => Approved` and `Move_to_Approved` are retired in the same wave. 🔴 **`AdminOnly` + no approval-history surface on `NDA_Record_Page` or the NDA layout = a locked record with no Recall route** (P-7); the fix is two files and neither works alone. 🔴 Six coupled artefacts, four metadata types, a strict deploy order, and a **restricted picklist write** whose value can be removed in Setup in one click (G-8). ⚠ No trigger seam exists (P-9), so everything must be a workflow field update. ✅ Mitigated: T1 already shipped both fields **and their FLS in both sets**, so there is no permission-set field pass at all. |
| 3 | Five-approval tracker | **MED-HIGH** | 🔴 **The component being "extended" is on no page in this repo** (P-5) — and if the ORG has it, deploying the repo copy of the FlexiPage **deletes it** (G-7). 🔴 The pinned `manyChildren_costsExactlyFourQueries` assertion breaks by design and must be moved deliberately, not made green (P-17). 🔴 **Five rows, six processes** (P-14): row 2 is record-type-dependent and easy to invert, and there is **no data in the org to catch an inversion**. ⚠ The type key must be `DeveloperName`, not the twice-renamed label (P-16), and the state must come from `ProcessInstance`, not the flags (P-15). |
| 4 | Override reason on the approval page | **MED** | 🔴 **A `LongTextArea` in `approvalPageFields` is unproven in this repo, and the field is on NO other page** (P-13) — a refusal leaves the T2 audit fact permanently unreadable, and a field that does not render looks exactly like a field with no value. ✅ Mitigated twice: `approvalPageFields` edits on an ACTIVE process are **proven** here (P-2, 2026-08-20), and `DPEG_Disposition_View` already grants the read, so no blank-for-the-approver trap (P-13). |

---

## 7. Confirmed OUT of Tranche 3

Restated so no implementing agent widens scope. **None of these is designed above.**

- **BOV scoring, the matrix threshold, Buyer Ready / Known Performer, broker surfaces** — Tranche 4.
- **The Week 2 rung change (A2), detection jobs, reminder ladders, timers** — Tranche 5.
- **Offer comparison columns, closing statement, PSA status, Conversion 6, CoStar/Argus deep links**
  — Tranche 6.
- **A generic `Approval__c` log object** — **D1: KEEP NATIVE.** Approval state stays on
  `ProcessInstance` + per-object fields. Not revisited.
- **The Conversion 5 freeze** — **A1: NO FREEZE.** Not revisited.
- Anything integration- or notification-shaped.

**Additionally flagged here and deliberately NOT built, so they are not mistaken for oversights:**

- **The three acquisition approval processes keep two approvers** (P-1). Out of scope by the
  request's own wording; surfaced as D-3.
- **`Is_Approved_For_Release__c`'s missing record-type guard** (T1 S-2). Examined, **no reader wired
  in T3**, formula unchanged — D-13. The note gets amended in place so T4/T6 does not assume T3
  handled it.
- **`NDA__c.Approval_Pending__c` and the four-action clear pattern** — D-10. Not built; the cost
  (a noisy `ENTITY_IS_LOCKED` on Mark Declined during the pending window) is named rather than hidden.
- **`Offer_Selection_Approval`'s missing `initialSubmissionActions` / `recallActions`** (P-15). It is
  the only one of five without them, and `Disposition_Offer__c` has no pending flag. Reported;
  **not fixed here** — it would be a fifth and sixth approval-process edit outside the four items.
- **Recall for the two child-object approvals** is still only reachable from the child record, not
  from the Disposition. Item 3 makes those approvals *visible* on the parent without making them
  *actionable* there. Reported (§3 item 3); not closed.
- **The `Not Sent` and `Review` orphan values** on `NDA__c.Status__c` — active on the master set, on
  no record type, on zero rows. Deactivating them is a separate user decision already recorded on the
  field file, and item 2 does not touch them.
- **`allowedSubmitters = owner`** on the new NDA approval means an analyst who did not create the NDA
  cannot submit it. Consistent with all five siblings; reported, not changed.
- **`c/dispositionApprovalHistory`'s header claims a placement it does not have** (P-5). Corrected in
  wave 8's documentation pass only — a comment fix, not a behaviour change.

---

## 8. Prompts for the specialist agents

Only what was requested. No extras.

### 🔵 PROMPT FOR `salesforce-admin`

```
Create/modify the metadata described in agent-output/disposition-gap-closure-t3-design.md §3 and
§4's admin table. Do NOT edit any permission set — that is a separate consolidated pass owned by
salesforce-solution-architect. Do NOT deploy.

🔴 GATES FIRST. Do not write anything until G-1, G-2, G-3, G-4, G-6, G-7 and G-8 in §5.1 have
answers. In particular:
  - G-1: the two new approvers' Usernames MUST come from a User query in usman-dpeg. This design
    deliberately contains NO candidate usernames. If Junior or Nick has no IsActive=true User,
    STOP and report it as a provisioning question — do not invent a username, and do not name an
    inactive one (that deploys and routes silently to nobody, which FirstResponse masks).
  - G-6: retrieve and diff NDA_Record_Page, Disposition_Record_Page and NDA__c-NDA Layout against
    HEAD *and* against the org before editing. A FlexiPage deploy clobbers App Builder edits with
    no version history — measured on this project 2026-08-25 and recorded inside
    Disposition_Record_Page itself.

ITEM 1 + ITEM 4 — Sale_Decision_Approval FIRST AND ALONE, IN ONE EDIT:
  Add the two new <approver> blocks (type=user) after the existing two inside <assignedApprover>,
  AND add <field>Sell_Meter_Override_Reason__c</field> to <approvalPageFields> immediately after
  Sell_Decision_Trigger__c.
  🔴 DO NOT TOUCH whenMultipleApprovers (FirstResponse is already correct and is what makes
  "any one of four" true), the step <name>/<label>, entryCriteria, or any action block.
  🔴 Deploy this ONE file check-only, read it back, AND submit a real disposition to confirm FOUR
  assignees and the reason field render on the approval request page. A green deploy proves
  neither. Nothing in the Apex or Jest suite can observe an approver roster.
  ⚠ G-4: a LongTextArea in approvalPageFields is exercised NOWHERE in this repo (every existing
  entry is Name/Owner/picklist/checkbox/currency/number/text/lookup/formula). If it is refused,
  take design D-18's fallback and report it — Sell_Meter_Override_Reason__c is on NO FlexiPage and
  NO layout, so the approval page is currently the only place a human could ever read it.
  ✅ Already verified, do not re-litigate: approvalPageFields edits on an ACTIVE process ARE proven
  here (Broker_Selection_Approval, 2026-08-20), and DPEG_Disposition_View already grants read on
  the field, so the approver will not see a blank.

ITEM 1 — the other four, only after the above readback passes:
  Disposition__c.Broker_Selection_Approval, Disposition__c.Closing_Approval,
  BOV_Submission__c.Broker_Finalize_Approval, Disposition_Offer__c.Offer_Selection_Approval.
  Roster only. Nothing else in those four files changes.
  Record in each file's XML comment that the three ACQUISITION approval processes
  (Opportunity.LOI_Approval, Opportunity.Underwriting_Approval, Underwriting__c.Underwriting_Approval)
  deliberately keep two approvers — per Gate 1 decision D-3 — so the asymmetry reads as a decision.

ITEM 2a — NEW FILE workflows/NDA__c.workflow-meta.xml. Three fieldUpdates, no rules, no alerts:
  Set_NDA_Status_Approved            Status__c -> literal 'Approved'
  Set_NDA_Principal_Approved         Principal_Approved__c -> literal true
  Set_NDA_Principal_Approved_Date    Principal_Approved_Date__c -> formula TODAY()
  🔴 THIS FILE MUST DEPLOY BEFORE THE APPROVAL PROCESS or that file fails on an unknown field
  update (same note BOV_Submission__c and Disposition_Offer__c's approval files both carry).
  🔴 Status__c is a RESTRICTED picklist whose record-type subset DML DOES enforce here (measured
  4x). 'Approved' is on Disposition_NDA and NOT on Acquisition_NDA. Confirm G-8 first.
  ⚠ Principal_Approved_Date__c stays a Date and is stamped TODAY(), per decision D-6.

ITEM 2b — NEW FILE approvalProcesses/NDA__c.NDA_Issue_Approval.approvalProcess-meta.xml.
  The full element table is in §3 item 2b. Key points:
  entryCriteria booleanFilter "1 AND 2": Status__c equals Prepare AND Is_Disposition_NDA__c equals
  True. Is_Disposition_NDA__c is a formula on RecordType.DeveloperName that already exists and is
  already granted read in both disposition sets; it FAILS CLOSED on a Master-typed row, which is
  the correct polarity for a disposition-only gate.
  active=true, allowRecall=true, recordEditability=AdminOnly, allowedSubmitters type=owner,
  showApprovalHistory=true, whenMultipleApprovers=FirstResponse, allowDelegate=false,
  step <name>Principal_Review_Step</name>.
  🔴 The step <label> MUST BE DISTINCT from the other five (e.g. "Principal approves NDA release").
  The 2026-08-26 rename exists precisely because five identical "Principal Review" labels meant
  approvers could not tell which decision they were being asked for.
  finalApprovalActions = the three field updates from 2a. NO finalRejectionActions,
  NO initialSubmissionActions, NO recallActions (decisions D-10/D-11).
  approvalPageFields: Name, Owner, Disposition__c, Counterparty_Name__c, Party_Role__c, Status__c,
  OneDrive_URL__c — VERIFY each is readable in DPEG_Disposition_View before writing; an approver
  who cannot read a field sees a blank, not an error.
  <description> under 255 chars; all rationale in an XML COMMENT INSIDE the root element (a comment
  above the root breaks `sf` at source conversion).

ITEM 2d — the submit route:
  NEW quickActions/NDA__c.Submit_NDA_Approval.quickAction-meta.xml — LightningWebComponent,
  actionSubtype Action, headless, no <description> (0 of 80 quick actions in this repo carry one).
  NDA_Record_Page: add its valueListItems entry with booleanFilter "1 AND 2 AND 3":
    {!$Permission.CustomPermission.Disposition_Deal_Actions} EQUAL true   ← three-segment form ONLY
    {!Record.Status__c} EQUAL Prepare
    {!Record.RecordType.DeveloperName} EQUAL Disposition_NDA
  Place it where Move_to_Approved was.

ITEM 2d / DECISION D-7 — RETIRE THE COMPETING WRITER. THIS IS NOT OPTIONAL:
  🔴 Remove the <value>NDA__c.Move_to_Approved</value> valueListItems entry from NDA_Record_Page,
  and DELETE quickActions/NDA__c.Move_to_Approved.quickAction-meta.xml. That page's own comment
  says an entry and its quick action are retired together.
  WHY: today an ANALYST moves a disposition NDA Prepare -> Approved in one click via that button
  and RecordStageAdvanceService's 'Prepare' => 'Approved' hop, gated on Disposition_Deal_Actions —
  which DPEG_Disposition_Edit grants and which DPEG_Disposition_View is FORBIDDEN to carry. Leaving
  it in place ships an approval anyone can walk around. RecordStageAdvanceService's own header
  already forbids this exact shape for Broker Selection -> NDA.
  The Apex half of this retirement is owned by salesforce-developer and must land in the SAME wave
  or EARLIER — never after.

ITEM 2e — APPROVAL HISTORY ON THE NDA. MANDATORY, TWO FILES, NEITHER WORKS ALONE:
  1. flexipages/NDA_Record_Page: add force:relatedListContainer (identifier relatedLists,
     showActionBar=true).
     🔴 NOT force:relatedListSingleContainer. Measured on usman-dpeg at 67.0 and recorded in
     Disposition_Record_Page: the UI API behind the Single container answers INVALID_TYPE for
     ProcessSteps / RelatedProcessHistoryList / ApprovalHistory, so it deploys green and renders
     NOTHING. The page's three existing Single containers are correct for ordinary child
     relationships and must be left alone.
  2. layouts/NDA__c-NDA Layout: add a relatedLists entry RelatedProcessHistoryList ALONGSIDE the
     existing RelatedNoteList, not replacing it.
  WHY: recordEditability=AdminOnly locks a submitted NDA, and the related list's action bar is the
  only Recall route in the UI. Without both halves the first submitted NDA is a locked record with
  no way out — the exact gap Disposition_Record_Page closed on 2026-08-19 (code review C-3).

Record mcp=unavailable / mcp_tools=none per metadata type after a real attempt, and fall back to
the per-type skill. Do NOT deploy. Create/modify the metadata files only.
```

### 🟤 PROMPT FOR `salesforce-solution-architect`

```
Execute the ACCESS pass in agent-output/disposition-gap-closure-t3-design.md §4, as a SINGLE
consolidated edit to exactly ONE file:
  force-app/main/default/permissionsets/DPEG_Apex_Access.permissionset-meta.xml

BEFORE editing (GATE G-6):
  - Retrieve it from usman-dpeg and diff against HEAD. A PermissionSet deploy REPLACES the file's
    entire classAccesses AND fieldPermissions collections; an org/repo divergence silently revokes
    live grants. Report any divergence and STOP rather than reconciling silently.
  - A complete reconciliation needs FieldPermissions + ObjectPermissions + SetupEntityAccess.
  - git status already shows DPEG_Transaction_Edit and DPEG_Transaction_View modified by work that
    is NOT this tranche. Confirm no concurrent stream is editing DPEG_Apex_Access.

THEN, additively: add one <classAccesses> entry for the new NDA approval CONTROLLER class created
by salesforce-developer (§3 item 2d). Controllers only — this file grants controllers, not
services or selectors; follow the file's existing convention exactly.

🔴 DEPLOY ORDER: the Apex class must land in the SAME deploy as this file or an EARLIER one. A
classAccesses entry naming a class the org does not hold fails the deploy of the ENTIRE set. This
file's own header records a LIVE PRODUCTION BREAK on 2026-08-21 caused by the opposite mistake —
shipping DispositionApprovalController without its grant, producing "no such class named
'DispositionApprovalController'".

⚠ THERE IS NO FIELD-PERMISSION WORK IN THIS TRANCHE, and that is verified, not assumed:
  - Tranche 1 already granted NDA__c.Principal_Approved__c, NDA__c.Principal_Approved_Date__c and
    NDA__c.Is_Approved_For_Release__c read (editable=false) in BOTH DPEG_Disposition_View and
    DPEG_Disposition_Edit.
  - Tranche 2 already granted Disposition__c.Sell_Meter_Override_Reason__c read (editable=false)
    in both sets, which is what lets item 4's approvalPageFields entry render for the approver.
  Do NOT re-add any of them. Do NOT touch DPEG_Disposition_View or DPEG_Disposition_Edit unless
  Gate 1 decision D-10 is overturned and an NDA__c.Approval_Pending__c field is added — in which
  case that grant is read-only in both sets, in one consolidated pass.

Record mcp=unavailable / mcp_tools=none after a real attempt. Do NOT deploy.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Implement the DEVELOPER work in agent-output/disposition-gap-closure-t3-design.md §3 items 2c, 2d
and 3, and §4's developer table. Do NOT deploy.

ITEM 2c — RETIRE THE COMPETING ONE-CLICK WRITER (decision D-7). DO THIS FIRST:
  RecordStageAdvanceService: remove 'Prepare' => 'Approved' from NDA_DISPOSITION_NEXT_STAGE.
  KEEP 'Approved' => 'Sent', 'Sent' => 'Signed', the legacy 'Not Sent' => 'Sent' hop and the
  Declined explicit target EXACTLY as they are. Touch NOTHING in the acquisition map.
  Add a NO_NEXT_STEP_HINTS entry naming NDA__c.NDA_Issue_Approval as the owner of the Prepare hop —
  without it the Advance path refuses at Prepare with wording that reads like a bug, which is the
  same reason the Disposition config carries hints for its seven approval-owned transitions.
  🔴 RETRACT THE 2026-08-25 PARAGRAPH THAT ADDED THAT HOP **IN PLACE** — quote it, mark it
  retracted, date it. This class's header has been rewritten three times on this exact map and the
  header says the history is the point. Do not delete it.
  🔴 The existing test that asserts the Prepare -> Approved hop must be INVERTED into a refusal
  test, not deleted, so the bypass cannot silently return.
  WHY: that hop plus quickActions/NDA__c.Move_to_Approved let an ANALYST perform in one click the
  exact transition the new approval owns. Disposition_Deal_Actions is granted by
  DPEG_Disposition_Edit (Analyst) and is FORBIDDEN on DPEG_Disposition_View (Principal), so the
  bypass is held by the wrong persona. This class's own header already forbids this shape for
  Broker Selection -> NDA in terms.

ITEM 2d — the NDA submit route:
  NEW NdaApprovalService.submitForApproval(Id ndaId) — `with sharing`, layer=service.
  🔴 FIRST STATEMENT: DispositionActionPermissionService.assertDispositionActionAccess().
  🔴 DO NOT MODIFY DispositionActionPermissionService — its header states "THE TWO CLASSES ARE ONE
  DESIGN ON TWO MODULES — CHANGE BOTH OR NEITHER" against its OpportunityActionPermissionService
  twin. Call it; do not touch it.
  Then authored pre-checks with user-safe messages: no record; wrong record type; Status is not
  'Prepare'; already pending (via ProcessInstanceSelector.selectPendingByTargetId). Then the
  ONE-ARGUMENT Approval.process(request) with only setObjectId set — the same shape all five
  existing processes are submitted with; there is no setProcessDefinitionNameOrId anywhere in this
  repo and there must not be one now.
  NEW thin controller (@AuraEnabled, AuraHandledException at the boundary only).
  NEW headless RecordAction LWC bundle mirroring c/dispositionSubmitForApproval. Jest +
  @sa11y/jest required.
  ⚠ NDA__c has NO SOQL outside NdaSelector and NdaTrigger is `before insert, before update` ONLY —
  there is no after-update seam and you must not add one. Everything the approval writes is a
  workflow field update, owned by salesforce-admin.
  ⚠ The new CONTROLLER needs a DPEG_Apex_Access classAccesses entry — owned by
  salesforce-solution-architect, but it must land with or after your class. Flag it in your output.

ITEM 3 — the five-approval tracker, by EXTENDING c/dispositionApprovalHistory (decision D-14):
  a) ProcessInstanceSelector.selectHistoryByTargetIds: add ProcessDefinition.DeveloperName to the
     SELECT. It stays WITH USER_MODE — ProcessDefinition is a system entity whose fields are
     non-permissionable, so this is NOT an FLS change. Amend that method's own mode note.
     🔴 WHY: the DTO currently publishes ProcessDefinition.Name, a LABEL that was renamed on four
     of the five processes on 2026-08-26. Keying a checklist on it keys it on copy.
  b) NdaSelector: NEW selectApprovalTargetsByDispositionId(Id), WITH USER_MODE, returning EVERY
     disposition NDA on the sale (Id, Name, Counterparty_Name__c, Party_Role__c, Status__c),
     UNFILTERED by status — the same rule the two sibling methods document: "an approval-history
     read filters on nothing but parentage."
     ⚠ Do NOT reuse selectByDispositionIds — that is the SYSTEM_MODE automation read. Add the new
     method's line to the class header's USER_MODE inventory (7 becomes 8).
  c) DispositionApprovalHistoryService.resolveTargets: a fourth loop adding NDA targets.
     targetDetail = Counterparty_Name__c, else Party_Role__c, else null — same shape as brokerHint.
     Add one @AuraEnabled String processApiName to ApprovalRow, populated from
     ProcessDefinition.DeveloperName.
     🔴 manyChildren_costsExactlyFourQueries WILL FAIL. It becomes FIVE. Rename it, update the
     assertion message, and add NDAs to the fixture. DO NOT DELETE IT — the class header calls it
     "the highest-value governor assertion in this class" and it is the only thing standing between
     this card and SOQL-in-a-loop on a page render.
  d) lwc/dispositionApprovalHistory: a CHECKLIST SECTION above the existing history list. Five
     fixed rows in FSD order: Sale Decision, Broker Selection, NDA Issue, Offer Selection, Closing.
     🔴 FIVE ROWS, SIX PROCESSES. Row 2 reads Broker_Finalize_Approval on an ON-MARKET sale and
     Broker_Selection_Approval on an OFF-MARKET one, and marks the other variant "N/A" — never
     "not started". Get the record type from an LDS getRecord on Disposition__c.Is_On_Market__c
     (the formula checkbox built for exactly this, already granted read in both sets). Never a bare
     {!Record.RecordType.*} — that shape is repo-asserted and unmeasured at the FlexiPage layer.
     🔴 THE NDA ROW AGGREGATES: "n of m approved" across every disposition NDA on the sale.
     Pending if any is pending; Approved only when all are; Not started when none has been
     submitted. It is the one row whose cardinality is not 1.
     🔴 DERIVE STATE FROM ProcessInstance.Status, NEVER from the Approval_Pending__c flags —
     Disposition_Offer__c has no such field, so a flag-keyed tracker is blind on the offer type.
     Reuse the bundle's existing STATUS_META map verbatim (including Removed -> "Recalled") and add
     only "Not started" and "N/A". Keep the mapping in JS, not Apex, for the reason the bundle's
     header already gives.
     ⚠ THE CARD OFFERS NO ACTIONS AND MUST NOT START. Recall stays reachable only from
     force:relatedListContainer in the FlexiPage header region, and only for the three
     Disposition-target approvals. Do not add a Recall button here without reading that
     component's FlexiPage comment first.
     Jest + @sa11y/jest for the new section; use the newest matching ProcessInstance per type, not
     an arbitrary one.

  🔴 BEFORE ANY OF ITEM 3: c/dispositionApprovalHistory IS ON NO FLEXIPAGE IN THIS REPO. A
  repo-wide grep finds it only in its own bundle, its two Apex classes and two comments. Its own
  header claims it is "in the Disposition record page sidebar" and that claim is unverified. GATE
  G-7 resolves this against the org FIRST. If the org HAS the card and the repo does not, deploying
  the repo's Disposition_Record_Page DELETES it. The placement itself is a FlexiPage edit and is
  owned by salesforce-admin under the retrieve-and-diff gate.

Every class with SOQL must be a Selector. `with sharing` everywhere unless separately justified in
the class header. Jest + @sa11y/jest for every changed and new LWC bundle. SLDS 2 tokens, no new
hardcoded colours. Record mcp=unavailable / mcp_tools=none after a real attempt.
```

---

## 9. Summary

- **4 of 4 items designed.** Nothing added, nothing expanded. Everything that looked adjacent —
  the acquisition approvals' roster, `Is_Approved_For_Release__c`'s record-type guard, an NDA
  pending flag, `Offer_Selection_Approval`'s missing action blocks, Recall for the child approvals —
  is raised as a **decision or a flagged non-item**, not built.
- **Eighteen premises in the request are incomplete or wrong** in ways that change the design. The
  four that would have produced a wrong build:
  - **P-6** — a **one-click bypass of Approval #3 already exists** (`Move_to_Approved` +
    `RecordStageAdvanceService`'s `Prepare => Approved` hop), and it is held by the **Analyst**
    persona, not the Principal. Building the approval without retiring it ships an approval anyone
    can walk around.
  - **P-7 + P-8** — `NDA_Record_Page` has **no approval-history surface and no inherited Submit
    button**. An `AdminOnly` NDA approval would be un-submittable and, once submitted by any other
    route, un-recallable.
  - **P-5** — the tracker item 3 proposes to extend **is on no FlexiPage in this repo**, and its own
    header says otherwise. Until G-7 resolves that against the org, "extend it" is a change to
    something nobody can see — and deploying the repo's FlexiPage could *delete* an org-side copy.
  - **P-2** — item 4 is **not** gated by the deactivate/reactivate question: `approvalPageFields`
    edits on an active process are already proven here (2026-08-20). Its real unknown is that a
    **`LongTextArea` has never been an approval page field in this repo**, and the field is on no
    other page, so a refusal makes it unreadable by anyone.
- ✅ **Three pieces of good news that cut the work:** T1 already shipped both NDA fields **and their
  FLS in both disposition sets**; T2 already granted the override-reason read to
  `DPEG_Disposition_View`, so item 4's approver will not see a blank; and
  `NDA__c.Is_Disposition_NDA__c` already exists, is already granted, and fails **closed** on a
  Master row — so item 2's record-type scoping needs no new field and no formula.
- **19 decisions (D-1 … D-19)** need confirmation before build; each carries a recommendation and
  its evidence. **D-1 is hard-blocked** — this agent cannot query `User`.
- **9 gates (G-1 … G-9), six of them blocking.** Two are unproven metadata shapes that must be
  proven on `Sale_Decision_Approval` **first and alone**, with a behavioural readback, exactly as
  that file's own 2026-08-21 protocol demands.
- 🔴 **The single most important sentence in this document:** *a deploy cannot discharge either
  headline AC in this tranche.* "Four assignees appear on the approval request" and
  "the override reason renders on the approval page" are both **browser facts on a seeded sale**,
  and the org holds **zero `Disposition__c` records**. §5.2 splits every gate into what a deploy can
  close and what only data can.
