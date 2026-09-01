# LOI Approval Cutover — Design Requirements

**Date:** 2026-09-01
**Request (verbatim):** *"Make sure that we must have approval on LOI record page not on opportunity."*
**Status:** requirements only. No implementation metadata and no Apex is produced by this document.
**Sibling:** `agent-output/underwriting-approval-cutover-design.md` (the equivalent cutover, executed
2026-08-28 → 2026-09-01). This document is written **against** that one — where the Underwriting
answer transfers it says so, and where it does **not** transfer it says so in capitals.

```
skill_selection=complete | intent=type | best_matched_skill=none (no metadata is generated here)
mcp=unavailable | mcp_tools=none
```

**MCP disclosure — read this, do not treat it as boilerplate.** This agent's tool set is
file-system only (Read / Write / Edit / Glob / Grep). There is no `salesforce-api-context` MCP server
exposed to it, no `sf` CLI and no org access, so no MCP call was possible to make. **Nothing below is
an org readback.** Every statement about the REPO was read from the file and line named. Every
statement about the ORG is labelled either **[MEASURE]** (you must measure it; W0 tells you how) or
**[INFERRED]** (derived from repo files and possibly wrong). There is exactly one figure in this
document that came from anywhere but a file I read in this session, and it is labelled as such.

---

## 0. Five findings that change the shape of the answer before any wave is designed

### 0.1 🔴 THE BUTTON IS **ALREADY** ON THE LOI RECORD PAGE. Only the PROCESS is on the Opportunity.

This is the first thing to establish because it changes what the user is actually asking for.

| What | Where it lives today |
|---|---|
| The *Submit for Approval* **button** | `flexipages/LOI_Record_Page.flexipage-meta.xml:476` — `LOI__c.Submit_for_Approval`, a 5-criterion Dynamic Action. Also `layouts/LOI__c-LOI Layout.layout-meta.xml:209`, sortOrder 1 (dormant while the FlexiPage is assigned). |
| The **quick action** | `quickActions/LOI__c.Submit_for_Approval.quickAction-meta.xml` → LWC `submitForApproval`. |
| The **routing** | `OpportunityApprovalService.resolveApprovalTargetId` (`:319-321`): `LOI__c` → `LoiSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c` — **it returns the PARENT DEAL.** |
| The **approval process** | `approvalProcesses/Opportunity.LOI_Approval.approvalProcess-meta.xml`, parented by **Opportunity**, entry `Opportunity.StageName = 'LOI'`. |
| The approval **history**, the **record lock**, the **approval page**, the **Recall** route | All on the **Opportunity**. |

There is **no** *Submit for Approval* quick action on the Opportunity record page at all — a repo-wide
sweep of `flexipages/`, `layouts/` and `quickActions/` for `Submit_for_Approval` returns exactly two
objects: `LOI__c` and `Underwriting__c`. So the user is not describing a button in the wrong place.
They are describing the fact that clicking the LOI's button puts the approval **on the deal**.

⇒ **This is the same shape as the Underwriting cutover** (button on the child, process on the parent,
move the process). It is not a "this already works" case. But the scope must be confirmed — see
decision **D-1** in §7, because a smaller reading of the request exists and is much cheaper.

### 0.2 🔴 THE UNDERWRITING "THERE IS NO UNAVOIDABLE WINDOW" ANSWER **DOES NOT TRANSFER**.

The Underwriting plan's central finding was that `UnderwritingApprovalStampService` **already wrote
the exact field the live validation rule read** (`UW_Approved__c`), so the replacement writer and the
retired writer were interchangeable and the VR repoint decoupled entirely.

I ran the equivalent check here. It fails.

- `Opportunity.LOI_Approval`'s `finalApprovalActions` fires **one** field update,
  `Set_LOI_Approved_Flag` → `Opportunity.LOI_Approved__c = true`
  (`workflows/Opportunity.workflow-meta.xml:18-27`).
- A repo-wide grep for `LOI_Approved__c` (excluding `profiles/**`, which is `.forceignore`d) returns
  **exactly one production writer**: that field update. Every other hit is a permission set, a
  reader, a test fixture (`TestDataFactory.placeApprovedLoi:1150,1154`) or a seed script
  (`scripts/seed-fsd-03-flagship-deep.apex:71`, `scripts/seed-fsd-04-flagship-closed-won.apex:78`).
- `objects/Opportunity/validationRules/Approved_LOI_Before_PSA.validationRule-meta.xml:40` reads
  `NOT(LOI_Approved__c)` and blocks entry to `Under Contract (PSA)`.
- **There is no `LoiApprovalStampService`.** `classes/` contains no such file. The Underwriting
  equivalent existed, fully written and tested, before its design was started.

⇒ **Deactivating `Opportunity.LOI_Approval` with nothing else changed blocks every deal from
`Under Contract (PSA)`, permanently, with no route out.** The window the Underwriting plan proved
away is real here. The plan must therefore **build and prove a replacement writer first** — and W1
stops being "deploy inert prerequisites that already exist" and becomes **new Apex + a new flow + a
new workflow file**, none of which exist today.

### 0.3 🔴 REJECTION IS **NOT** A NO-OP HERE, UNLIKE UNDERWRITING — SO DECISION D2 CANNOT BE INHERITED.

The Underwriting design dropped reject handling (its decision D2) and could argue the loss was small,
because its `finalRejectionActions` would have written the value the record already held.

`Opportunity.LOI_Approval`'s `finalRejectionActions` is **`Set_Stage_Underwriting` →
`Opportunity.StageName = 'Underwriting'`** (`Opportunity.workflow-meta.xml:28-37`). That is a real,
visible, load-bearing state change: it rewinds the deal a full stage. It is:

- pinned by a test — `LoiGateTest.rejectionReturnsDealToUnderwriting:65-87`;
- carved out of a validation rule — `No_Backward_Stage_Movement` **CARVE-OUT 1**
  (`:221-225`, `ISPICKVAL(PRIORVALUE(StageName),'LOI') AND ISPICKVAL(StageName,'Underwriting')`);
- named as writer #4 of `StageName` in `OpportunityStageEntryService`'s header (`:66-67`);
- and it is the **entire reason** the freshly-rewritten `Underwriting_Approved_Before_LOI` names
  **both** `'Approved'` and `'Completed'` (that rule's own header, `:29-43`: *"LOI_Approval's
  finalRejectionActions fires Set_Stage_Underwriting … the deal would be PERMANENTLY STRANDED the
  second time the driver clicks Initiate LOI"*).

An approval on `LOI__c` **structurally cannot** perform that write (see 0.4). So this is a **user
decision**, not an accepted inheritance. It is decision **D-3** in §7.

### 0.4 The relationship is a **Lookup**, so the same structural loss applies — confirmed, not assumed.

`objects/LOI__c/fields/Opportunity__c.field-meta.xml:12` — `<type>Lookup</type>`,
`<deleteConstraint>SetNull</deleteConstraint>`, `referenceTo` Opportunity, `relationshipName` `LOIs`.

An approval process can field-update **only its own record or a Master-Detail parent**. So an
approval parented by `LOI__c` **cannot write any Opportunity field** — not `LOI_Approved__c`, not
`StageName`. Both of the old process's actions (one approval, one rejection) are Opportunity writes,
so **100% of the old process's field updates are structurally unreachable from the new one.** The
Underwriting cutover lost one of three; this one loses two of two.

### 0.5 🔴 THE LOI IS OWNED BY A **QUEUE**, SO `allowedSubmitters = owner` MAY NOT MEAN ANYTHING. **[MEASURE]**

`OpportunityReviewService`'s header (`:170-186`) is explicit: *"The LOI block pins OwnerId to the
`Acquisition` QUEUE on every auto-created acquisition LOI"*, with a documented degraded fallback to
the deal's owner when the queue cannot be resolved.
`ACQUISITION_QUEUE_DEVELOPER_NAME = 'Acquisition'` (`:288`).

`Opportunity.LOI_Approval` today has `<allowedSubmitters><type>owner</type></allowedSubmitters>`
(`:5-7`) — on an Opportunity, whose owner is a person, that is unambiguous. On a **queue-owned**
`LOI__c` row it is not, and I will not assert what Salesforce does. **This must be measured before the
new process is authored** (V-6). If `owner` does not resolve to the queue's members, the submitter
set has to be expressed some other way, and that is a design change, not a transcription.

⚠ Note also that four sharing rules exist on `LOI__c` **precisely because** of this queue ownership
(`sharingRules/LOI__c.sharingRules-meta.xml:118-145`) — a queue has no place in the role hierarchy.

### 0.6 R-0 carries over unchanged: **no directory-wide or repo-wide deploy.**

The Underwriting cutover's three staged files may still be in a mixed repo↔org state, and this plan
will add more staged `<active>` values of its own. Any `sf project deploy start --source-dir
force-app` performs whatever is staged, in an order Salesforce chooses, with no proof step.
🔴 **Every deploy in this plan is an explicit component list, and the concurrent session must be told
so before W1.**

---

## 1. Scope

**In scope, if the user confirms D-1:** relocating the principal LOI approval from
`Opportunity.LOI_Approval` to a new approval process parented by `LOI__c` (Acquisition record type
only), together with whatever is required for the deal-level gates that read its output to keep
working.

**Explicitly not designed here** (each is raised in §7 as a decision, never specified as work): any
change to the approvers, any change to the disposition LOI path, any change to the Underwriting or
PSA approvals, any new picklist value, any change to `Is_Advance_Allowed__c`, any new test.

---

## 2. Repo-derived facts. Every row was read from the file and line named.

### 2.1 The process being retired

| # | Fact | Source |
|---|---|---|
| F1 | `Opportunity.LOI_Approval` — `<active>true</active>`, entry `Opportunity.StageName = 'LOI'`, one step, two named principals, `whenMultipleApprovers = FirstResponse`, `allowDelegate false`, `allowRecall true`. | `approvalProcesses/Opportunity.LOI_Approval…:3,33-39,16-31` |
| F2 | `recordEditability = AdminOnly` — **it locks the OPPORTUNITY while pending.** `finalApprovalRecordLock` and `finalRejectionRecordLock` are both `false`. | same file, `:46,53,56` |
| F3 | `finalApprovalActions`: **one** action, `Set_LOI_Approved_Flag`. `finalRejectionActions`: **one** action, `Set_Stage_Underwriting`. | same file, `:40-52` |
| F4 | `approvalPageFields`: `Name, Owner, StageName, Amount, Asking_Price__c, My_Price__c`. **Four of those six are Opportunity-only** — `LOI__c` has no `StageName`, no `Amount`, no `Asking_Price__c` and no `My_Price__c` (the `objects/LOI__c/fields/` directory was walked: 25 fields, none of them these). | same file, `:8-15`; `objects/LOI__c/fields/` |

### 2.2 The object being moved onto

| # | Fact | Source |
|---|---|---|
| F5 | 🔴 `LOI__c` has **TWO record types** — `Acquisition_LOI` and `Disposition_LOI`. `Underwriting__c` had none. Any approval here **needs a record-type criterion**; a stage value alone will not scope it. | `objects/LOI__c/recordTypes/` |
| F6 | 🔴 `Stage__c` is `restricted=true` and the record types carry **different subsets**. `Acquisition_LOI` = Draft, Under Review, Submitted, Negotiation, Signed. Restriction **IS enforced by Apex DML in this org** — reproduced as `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`. | `fields/Stage__c…:230`, `recordTypes/Acquisition_LOI…:255-277`, `Stage__c` header `:204-212` |
| F7 | 🔴 `'Under Review'` — the stage at which the Submit button renders — is **SHARED by both record types** since 2026-08-14. A rule keyed on it is **not** self-limiting. | `fields/Stage__c…:20-24`; `Is_Advance_Allowed__c` header `:80-88` |
| F8 | `LOI_Status__c` is a **second, separate** restricted picklist (9 values incl. `Pending Approval`, `Approved`, `Rejected`), enumerated **in full and identically on both record types**. | `fields/LOI_Status__c…`; `recordTypes/Acquisition_LOI…:216-254` |
| F9 | 🔴 **Nothing in production ever writes `LOI_Status__c = 'Pending Approval'.`** Grep across the whole repo: the only production writers of that field are `ApprovalAuditService:156` (→ `'Approved'`) and `CounterOfferService:197` (→ `'Countered'`). Every `'Pending Approval'` hit is a seed script, a test, a picklist definition or a comment. | repo-wide grep |
| F10 | `LOI__c` is `sharingModel Private` / `externalSharingModel Private`, `enableSharing true`. | `LOI__c.object-meta.xml:155,165` |
| F11 | 🔴 **Both Approval History files are MISSING for `LOI__c`.** The layout's only related list is `RelatedNoteList` (`:239-241`) — no `RelatedProcessHistoryList`. The FlexiPage's only related list is `CombinedAttachments` via `force:relatedListSingleContainer` (`:785-802`) — no `force:relatedListContainer`. The page's own header already states this as finding 4 (`:388-393`). | both files |
| F12 | 🟢 **Approver visibility is NOT a problem here, unlike Underwriting.** `DPEG_Acquisition_View` grants `LOI__c` `allowRead=true` **and `viewAllRecords=true`** (`:1902-1910`), plus read FLS on every relevant field including `Stage__c` (`:803`) and `LOI_Status__c` (`:758`), plus `recordTypeVisibilities` for `LOI__c.Acquisition_LOI` (`:2007-2010`). The principals hold it via `DPEG_Principal_PSG` (`:21`). Four sharing rules exist as well, two of them for exactly this population. | files named |
| F13 | `LOI__c` has **no `objectPermissions` `allowEdit`** on `DPEG_Acquisition_View` (`:1905` `allowEdit=false`). The approvers are read-only on the object, as `ApprovalAuditService:167-169` records ("DPEG Principal PSG: Read yes, Edit no, measured"). | files named |
| F14 | There is **no `workflows/LOI__c.workflow-meta.xml`.** The 8 workflow files are Case, Transaction__c, BOV_Submission__c, Disposition_Offer__c, Disposition__c, Underwriting__c, Opportunity, NDA__c. A new one is a W1 prerequisite. | `workflows/` |

### 2.3 The consumers of what the approval produces

| # | Fact | Source | Why it matters |
|---|---|---|---|
| F15 | `Approved_LOI_Before_PSA` blocks entry to `Under Contract (PSA)` on `ISBLANK(Primary_LOI__c) OR NOT(LOI_Approved__c)`. | that VR, `:35-42` | The gate with one writer. §0.2. |
| F16 | `Completed_LOI_Before_PSA` **already** reads the child: `TEXT(Primary_LOI__r.Stage__c) <> 'Signed'`. | that VR, `:143-148` | A child-side gate for the same transition already exists, works, and is proven. It is the model to copy — and it means the PSA gate is *already half* off the Opportunity. |
| F17 | `flows/LOI_Approval_Stamp` is an **after-save flow on Opportunity**, entry `LOI_Approved__c EqualTo true` + `doesRequireRecordChangedToMeetCriteria`. It performs **three** actions in order: `ApprovalAuditService(gate='LOI')` → `GroupNotifier(LOI_Panel)` → `GroupNotifier(Acquisitions_Team, "LOI approved - send to broker")`. | that flow, `:74-124` | All three die the moment `LOI_Approved__c` stops being written. Two of them are **notifications to humans** — the loudest possible silent failure. |
| F18 | 🔴 `ApprovalAuditService`'s LOI branch reads **the OPPORTUNITY's own approval history** (`latestApproval.get(o.Id)`, `:152`) and stamps the deal's `Primary_LOI__c` with `LOI_Status__c='Approved'`, `Approved_By__c`, `Approved_Date__c`, `Approval_Comments__c` (`:149-163`). Its header says this is *"UNCHANGED, and it must stay that way"* (`:11-12`). | that class | **This is the identical trap the Underwriting move hit in the same class.** Move the approval and `TargetObjectId` changes, the map lookup returns null, the stamp writes nothing — **and the class swallows every failure by design** (`:181-190`). |
| F19 | 🔴 …and the consequence is worse than an audit gap. `Is_Advance_Allowed__c`'s formula requires `TEXT(LOI_Status__c) = "Approved"` for an `Acquisition_LOI` at `'Under Review'`. That value has exactly one production writer: `ApprovalAuditService` (F9). | `Is_Advance_Allowed__c:212-222` | If F18's stamp dies, `Is_Advance_Allowed__c` stays FALSE, the `Move_to_Submitted` button never renders, and **the LOI can never leave `'Under Review'`.** Silent, and it hides an action rather than throwing. |
| F20 | The Submit button's own gate reads `LOI_Status__c NE 'Pending Approval'` and `NE 'Approved'` (`flexipage :484-493`). Combined with F9, criterion 2 **never changes state in production** — the button stays visible after submission and a second click is refused by `ProcessInstanceSelector.selectPendingByTargetId` in Apex, not by the page. | files named | Not a defect to fix here. Recorded so nobody designs around a criterion that is inert. |
| F21 | `No_Backward_Stage_Movement` **CARVE-OUT 1** exists solely for the LOI-rejection transition, and `LoiGateTest` documents at length (`:89-104`) that `rejectionReturnsDealToUnderwriting` does **not** actually pin it (approval field updates bypass validation rules in this org); the real pin is `directLoiToUnderwritingUpdate_isAllowedByCarveOut1_notByApproval`. | files named | See §5.2 — this is where the sharpest non-obvious consequence lives. |
| F22 | `StageAdvanceService.NEXT_STAGE` maps `'LOI' => 'Under Contract (PSA)'` (`:159`). `setStage`'s `DmlException` catch rethrows `getDmlMessage(0)`, so a VR message surfaces verbatim (`:238-245`). | that class | Whatever gate replaces F15 will surface correctly with **zero Apex change**, exactly as `Underwriting_Approved_Before_LOI` does today. |
| F23 | 🔴 `OpportunityApprovalService` carries a **signed-NDA pre-check** added 2026-08-30 that fires **only** when `targetId.getSobjectType() == Opportunity.SObjectType` **and** `deal.StageName == 'LOI'` (`:268-279`). | that class | Repoint `resolveApprovalTargetId` to return the LOI and **this gate stops firing entirely** — it is 30 hours old and its own header calls it load-bearing. §5.3. |
| F24 | `TestDataFactory.placeApprovedLoi` creates the LOI with **`LOI_Status__c = 'Approved'`** already set (`:1142`), then sets `Primary_LOI__c` + `LOI_Approved__c` on the deal. | that class | 🟢 **Free finding:** a new gate keyed on `Primary_LOI__r.LOI_Status__c = 'Approved'` would be **test-neutral, zero fixture edits** — the same gift F4 was to the Underwriting plan. A gate keyed on a *new* field would not be. |
| F25 | ⚠ `scripts/verify-junior-lifecycle.apex` — cited by `ApprovalAuditService`'s header as the one repo artifact that would notice a dead audit stamp — **is itself stale and cannot run.** It writes `StageName = 'LOI Under Approval'` (`:66`), asserts `'Initiate LOI'` (`:59`) and `'LOI Submitted'` (`:77`), and sets `LOI_Prep_Approved__c` — none of those stage values exist in the current 9-stage model. | that script | **The safety net named in the class header does not exist.** Do not cite it as coverage. |
| F26 | `ApprovalAuditServiceTest` **deliberately does not test the LOI gate at all** (`:31-34`: *"It is unchanged … Adding a shallow duplicate here would imply the LOI half moved too"*). The only coverage is `LoiGateTest`. | that class | The coverage is thinner than it looks, and the one test that exists runs as an admin who is also the approver and the owner. |

---

## 3. W0 — verification wave. No deploy. It gates everything.

Nothing in W1+ may start until W0 is complete and reported. Several of these are **stop conditions**,
not information-gathering.

| ID | Check | How | Why it gates |
|---|---|---|---|
| **V-0** | 🔴 **Confirm the scope with the user before measuring anything else.** Present decision **D-1** (§7). | conversation | §0.1. If the user's meaning is "the button should be on the LOI page", it already is, and this entire plan is unnecessary. Do not spend W0 on a plan that is not wanted. |
| **V-1** | Is `Opportunity.LOI_Approval` **Active**, and how many `ProcessInstance` rows are **Pending** against it? | `SELECT Id, Name, TableEnumOrId, State FROM ProcessDefinition`; `SELECT COUNT() FROM ProcessInstance WHERE Status='Pending'` grouped by `ProcessDefinitionId` | A stranded pending instance can be neither actioned nor recalled after its process is deactivated. **Re-run this immediately before W4 and again before W5** — the submit route stays live throughout, so someone may submit in between. |
| **V-2** | Establish the exact repo↔org diff for every component in §4 via a **check-only deploy**, and read the per-component `Changed` / `Unchanged` report. | `sf project deploy start --dry-run` with an explicit component list | ⚠ A green dry-run proves nothing on its own: byte-identical components report `Unchanged` and are **skipped, never validated**. The **report** is the deliverable, not the verdict. Also establishes whether the Underwriting cutover's own staged files are still undeployed. |
| **V-3** | 🔴 **Confirm F9 against the org, not the repo: does anything write `LOI_Status__c = 'Pending Approval'`?** Check for org-only Flows/Processes/workflow rules with no repo file. | Tooling API `FlowDefinitionView` / `WorkflowFieldUpdate`; `SetupAuditTrail` | The whole "the button stays visible after submission" reading rests on F9. A repo grep cannot see an org-only automation, and `settings/**` and `profiles/**` are `.forceignore`d in this repo. |
| **V-4** | 🔴 **Is the LOI audit stamp actually working in production today?** Query live `LOI__c` rows whose deal has `LOI_Approved__c = true` and check whether `LOI_Status__c = 'Approved'` and `Approved_By__c` is non-null. | SOQL | F18/F19. If it is **already** silently failing, the "regression" this move causes is not a regression, and the priority order in §4 changes. Do not assume it works because a test passes — see V-5. |
| **V-5** | 🔴 **Read the ORG's copy of `LoiGateTest`, method by method.** Compare the method names and bodies against `force-app/main/default/classes/LoiGateTest.cls`. | Tooling API `ApexClass.Body`, or `ApexTestResult` grouped by `MethodName` | **This is the Underwriting lesson repeating.** The deployed `UnderwritingGateTest` had different method names from the repo and passed against OLD behaviour, so three "expected failures" in that spec never existed. Any test named in §6 is a claim about the repo until this check is done. |
| **V-6** | 🔴 **Measure what `allowedSubmitters type=owner` does on a QUEUE-OWNED record.** And separately: query the live `OwnerId` of every `Acquisition_LOI` row — how many are actually queue-owned versus on the degraded fallback? | live probe on a throwaway LOI + `SELECT OwnerId, Owner.Type FROM LOI__c` | §0.5. If `owner` does not resolve, the submitter set must be redesigned and that is a **new user decision**, not a transcription of F1. |
| **V-7** | Confirm F12 empirically: open an acquisition `LOI__c` record **as one of the two named principals**, not as an administrator. Confirm they can see it and can see `Stage__c` / `LOI_Status__c` / the offer fields. | UI, as the persona | The Underwriting plan's V-6 found one of the two principals was a System Administrator whose access **proved nothing** about the Private OWD. Use the non-admin one, or the run is vacuous. Also confirms the `Principals` public group is not empty — **group membership is not deployable metadata.** |
| **V-8** | Confirm F11 against the org — is there a `RelatedProcessHistoryList` on the org's `LOI__c-LOI Layout`, or a `force:relatedListContainer` on the org's `LOI_Record_Page`? | V-2's report, plus a retrieve-and-diff | With `recordEditability = AdminOnly`, the **first** submission after the new process activates locks that LOI with **no Recall route**. Two files, **neither works alone**. |
| **V-9** | 🔴 Retrieve `flexipages/LOI_Record_Page` and `layouts/LOI__c-LOI Layout` from the org and **diff against HEAD**, seconds before any deploy that touches them. **Save the retrieved copies** — they are the W1 rollback artifact. | targeted retrieve + `git diff` | A FlexiPage deploy **replaces** the org copy and there is no version history. This repo has lost hand-made App Builder edits that way. `LOI_Record_Page`'s own header records a renderer probe whose result may have driven a hand edit. |
| **V-10** | Retrieve and **save** the org body of `Approved_LOI_Before_PSA`. | targeted retrieve | It is the cheapest rollback in the plan, and only if you kept the old body. |
| **V-11** | Capture a **baseline** `ApexTestResult` run before any deploy, with timestamps. | `sf apex run test` + query | A post-deploy failure is not attributable without a baseline. 🔴 **Count the shared working tree yourself at execution time** (`git status`) and ask the concurrent session for their exhaustive file list. Do not trust any figure written in this document or the Underwriting one about another session's tree — the Underwriting doc's "~85 class files" was measured at 8. |
| **V-12** | Confirm whether the **platform** *Submit for Approval* button on the Opportunity's Approval History related list is available to the deal driver's persona. | UI, as the persona | This is the only fallback route if the LOI button breaks mid-cutover. The Underwriting plan discovered its assumed workaround was refused by Apex before it could reach the process. Here there is no Apex refusal on the Opportunity path, but the *button's availability* is still unverified. |

---

## 4. Wave-by-wave deploy order, with org state and reversibility between each

Seven waves. **The order is different from the Underwriting cutover**, because §0.2 removes the
"activate new, prove, then retire old" luxury: here the replacement writer does not exist yet.

The governing principle is unchanged: **everything reversible before the one irreversible step,
everything risky after it, and a live proof between activating the new process and retiring the
old.**

---

### W1 — Build and land the replacement writer, entirely inert

**Purpose:** make it possible for `Opportunity.LOI_Approved__c` (and the three actions hanging off
it) to be written by something other than the retiring approval process — *before* anything is
retired.

**Components (all NEW; none of these files exists today):**

| Component | Type | Owner |
|---|---|---|
| `workflows/LOI__c.workflow-meta.xml` — the `finalApprovalActions` / `finalRejectionActions` field updates the new process will reference **by name** | Workflow field updates | admin |
| A parent-mirror Apex service (the `UnderwritingApprovalStampService` shape: `without sharing`, one `Database.update(..., AccessLevel.SYSTEM_MODE)`, `allOrNone = true` so it throws loudly) + its test | Apex | developer |
| An **after-save record-triggered flow on `LOI__c`**, entry-scoped on the marker the approval writes, calling that service | Flow | admin |
| `layouts/LOI__c-LOI Layout.layout-meta.xml` — add `RelatedProcessHistoryList` | Layout | admin |
| `flexipages/LOI_Record_Page.flexipage-meta.xml` — add `force:relatedListContainer` for approval history | FlexiPage | admin |

**Ordering inside W1 is load-bearing:** the workflow field updates must land **before** W2 (the
approval references them by name and cannot deploy otherwise — the same requirement
`Underwriting__c.Underwriting_Approval`'s header records at `:71-78`). The Apex must land **before or
with** the flow, which binds it by name.

🔴 **`force:relatedListSingleContainer` returns `INVALID_TYPE` for approval history in this org** —
measured on `Disposition_Record_Page`. The LOI page currently uses `…SingleContainer` for its
attachments list; the approval history entry must use `force:relatedListContainer`. Deploying green
is not proof — open the record and look.

**Org state after W1 — production behaviour is UNCHANGED:**
- Field updates on `LOI__c` referenced by nothing (the workflow file has no `<rules>`), so inert.
- An Apex class nothing calls.
- An after-save flow on `LOI__c` that fires on a transition **nothing in production can currently
  produce** — provided the marker chosen is one no live writer touches (see D-4 in §7 and the
  `single-writer` caution below).
- Approval History renders (empty) on LOI records.
- `Opportunity.LOI_Approval`, `LOI_Approved__c`, `Approved_LOI_Before_PSA`: all untouched. **No deal
  is affected in any way.**

⚠ **W1 is production-inert but NOT test-inert or seed-inert, and the marker choice decides how
badly.** `TestDataFactory.placeApprovedLoi:1142` already inserts LOIs at `LOI_Status__c = 'Approved'`
(F24), and `CounterOfferService:197` writes `'Countered'` on every counter. If the flow keys on
`LOI_Status__c = 'Approved'` with `recordTriggerType = CreateAndUpdate`, it fires on **every**
`placeApprovedLoi` call and on the counter path. Enumerate the call sites and check whether any is a
251-record bulk caller before choosing. A marker that **only the approval writes** makes the factory
and the seeds immune by construction and is strictly better — but it is a new field, which the user
has not asked for. That is decision **D-4**.

**Rollback from W1:** fully reversible; nothing here creates history.
- The flow must be **deactivated first** (redeploy `<status>Draft</status>`) — an active flow cannot
  be destructively deleted. **This deactivation is also the plan's cheapest kill switch; name it as
  one and keep it in reach through W5.**
- Apex + workflow field updates: `destructiveChanges.xml`, safe because the approval does not exist
  until W2.
- Layout / FlexiPage: redeploy the copies **saved at V-9**.

---

### W2 — Activate the new `LOI__c` approval process 🔴 THE IRREVERSIBLE STEP

**Component:** one new `approvalProcesses/LOI__c.<Name>.approvalProcess-meta.xml`, `<active>true</active>`.
Nothing else in this payload.

Three things this file must get right that the Underwriting one did not have to:

1. 🔴 **A record-type criterion is mandatory** (F5/F7). `'Under Review'` is carried by *both* record
   types, so a stage-only entry criterion would pull disposition LOIs into an acquisition approval.
   ⚠ **[MEASURE]** whether `ApprovalProcess.entryCriteria` accepts `LOI__c.RecordTypeId` as a
   `criteriaItems` field, or whether a `<formula>`-style criterion is required. There is no in-repo
   precedent for a record-type criterion on an approval process — the seven existing approval files
   were checked. Do not guess the XML shape; a malformed guess here is exactly the class of failure
   ARCHITECTURE.md §3.4 records for the SharePoint credential. Run a throwaway check-only probe under
   a scratch name, in **both** directions.
2. 🔴 **Whatever `finalApprovalActions` writes to `Stage__c` (if anything) must be a value
   `Acquisition_LOI` carries** (F6) — restriction **is** enforced by DML here, and a refusal inside
   an approval transaction rolls the approval back and tells the approver something unintelligible.
   Writing `LOI_Status__c` instead avoids the question entirely: all nine values are on both record
   types (F8).
3. **`allowedSubmitters` cannot be copied from F1 until V-6 answers.** See §0.5.

**Precondition:** re-run V-1 minutes before. Pending count on `Opportunity.LOI_Approval` must be **0**,
or those instances must be recalled in Setup first.

**Org state after W2:**
- **Both processes are active, on different objects.** They cannot conflict — `Approval.process`
  routes by object + entry criteria, and an `LOI__c` submission can only match the LOI process.
- ⚠ **But the LOI button still submits the PARENT** — `resolveApprovalTargetId` is not repointed
  until W4. So in W2/W3 the new process is reachable **only** by the platform *Submit for Approval*
  button on the LOI's newly-added Approval History related list, or by direct `Approval.process`.
  That is deliberate: it gives you a proof route that does not disturb the live path.
- `LOI_Approved__c` still has exactly one writer. `Approved_LOI_Before_PSA` is unaffected. **No deal
  is blocked.**

**Rollback from W2:** redeploy `<active>false</active>`. That returns *behaviour* to the W1 state.
🔴 **It does not return the ORG to the W1 state, and nothing can.** Once one `ProcessInstance` exists
against the new definition, a `destructiveChanges` delete is refused — which is exactly why
`Opportunity.Underwriting_Approval` is kept forever as a deactivated file. The `ProcessDefinition`
row and its history are permanent.

**If W2's deploy itself fails** (e.g. an unknown field-update name because W1 was partial): an
ApprovalProcess deploys as a single atomic component, so the org is left **exactly at W1**. Safe
failure.

---

### W3 — Live proof 🔴 NO DEPLOY, AND IT IS NOT OPTIONAL

The chain replacing one workflow field update is **four hops long** and a green deploy proves none of
them. The one hop with no precedent on this object — *does a workflow field update fired by an
approval process on `LOI__c` trigger an after-save record-triggered flow on `LOI__c`?* — fails
**silently** if it fails.

✅ The strongest available evidence that it works is **in-repo and on this very feature**:
`Opportunity.LOI_Approval` → `Set_LOI_Approved_Flag` → `flows/LOI_Approval_Stamp` (entry
`LOI_Approved__c EqualTo true`, `doesRequireRecordChangedToMeetCriteria`) is live, active and
asserted by `LoiGateTest`. That is the *identical structure*, on the Opportunity. It is not proof on
`LOI__c`, which is why W3 is a gate.

**Required conditions:**
1. A real `Acquisition_LOI` at the entry stage, whose parent deal is at `StageName = 'LOI'` and has
   **not** yet reached `Under Contract (PSA)`.
2. 🔴 **The approver must be one of the two named principals AND must NOT own the record.** Given
   F12/queue ownership this is easy to satisfy here — but per V-7, **the principal used must be the
   non-administrator one**, or the run proves nothing about anything.
3. Submitted from the **LOI record's own** Approval History related list, not by Apex.

**Assertions — all must hold; any one failing stops the plan and W4 does not run:**

| # | Assertion | Hop proved |
|---|---|---|
| P-1 | `ProcessInstance.TargetObjectId` = the **LOI** Id; the deal has none for this decision | routing |
| P-2 | The LOI's own `finalApprovalActions` fields landed, and were **not** refused by the restricted picklist / record type | F6, and the `isAvailable()`-as-approver trap |
| P-3 | Parent `Opportunity.LOI_Approved__c = true` | 🔴 **the hop with no precedent on this object**: field update → after-save flow → Apex → parent DML, run as a read-only, non-owning approver |
| P-4 | `flows/LOI_Approval_Stamp` still fired: the primary LOI carries `LOI_Status__c='Approved'`, `Approved_By__c`, `Approved_Date__c`, `Approval_Comments__c` | F17/F18 — the audit stamp survived the move |
| P-5 | Both `GroupNotifier` notifications were delivered (LOI_Panel, Acquisitions_Team) | F17 — the two human-facing actions |
| P-6 | The **Opportunity is editable** during the pending window, and the **LOI is locked** | the `AdminOnly` lock moved objects (F2) |
| P-7 | Approval History renders on the LOI and *Recall Approval Request* is visible while pending | V-8's two files actually work together |
| P-8 | `Is_Advance_Allowed__c` is now TRUE and the `Move_to_Submitted` button renders | F19 — the LOI can still leave `'Under Review'` |
| P-9 | 🔴 **A separate REJECTION run.** Reject a second LOI and record exactly what happens to the deal's `StageName`. | §0.3 / D-3 — this is the assertion that makes the rejection loss concrete rather than theoretical |

**The window lives here, and it is a silent-failure exposure, not a blocked-deal window.** Between W2
and a passing W3 nothing has changed for any deal, because the live route still goes to the
Opportunity. That is the entire reason W4 is separate from W2.

**Rollback from a failed W3:** deactivate the W1 flow (kill switch) and/or redeploy the approval as
`<active>false</active>`.

---

### W4 — Repoint the submit route

**Components:** `classes/OpportunityApprovalService.cls` (+ test), and `flexipages/LOI_Record_Page`
only if the Submit button's visibility criteria need to change to match the new entry criteria.

Two edits, and the second is the one that gets forgotten:

1. `resolveApprovalTargetId`: `LOI__c` → **itself**, not `LoiSelector…Opportunity__c`.
2. 🔴 **`assertNdaSignedForLoiSubmission` must be repointed in the same change** (F23). It returns
   immediately unless the target is an Opportunity at `StageName = 'LOI'`. Repoint the resolver
   without touching it and the signed-NDA gate — added 2026-08-30, 30 hours before this document —
   **silently stops firing.** Its own header calls it a "REFUSAL THAT WOULD OTHERWISE NOT HAPPEN".
   ⚠ Its class header also states that a validation rule on `LOI__c` was **dead code** for this path
   *because* no DML touches the LOI row. After this change DML *does* touch the LOI row, so that
   reasoning is retracted and a VR becomes viable — but that is a redesign, not a repoint. Keep it in
   Apex for this wave.
3. Also repoint the stage-derived refusal messages (`:223-226`, `'No approval applies at the X stage
   - LOI approval runs at the LOI stage'`) — they now describe a process that no longer accepts an
   Opportunity.

⚠ **Also align the Submit button's visibility with the new entry criteria.** Today the page gates on
`Stage__c = 'Under Review'` while the process gates on `Opportunity.StageName = 'LOI'` — **they do
not agree today**, which is why a Submit click can currently produce `NO_APPLICABLE_PROCESS`. The
Underwriting design deliberately made its button rule and its entry criterion agree *by construction*
(that approval's header, `:52-56`). Do the same here; it is free at this point and expensive later.

**Org state after W4:**
- The LOI button submits the **LOI**. The user's request is satisfied at this moment.
- 🔴 **`Opportunity.LOI_Approval` is still ACTIVE and still reachable** via the platform button on the
  Opportunity's Approval History related list. That is deliberate — it is the escape hatch, and it
  stays until W5.
- `LOI_Approved__c` now has **two** writers. Both write `true`. `Approved_LOI_Before_PSA` is satisfied
  by either. **No deal is blocked.**

**Rollback from W4:** redeploy the previous class body. Cheap, and reversible.

---

### W5 — Deactivate `Opportunity.LOI_Approval`

**Component:** that file, `<active>false</active>`. Nothing else.

**Precondition:** W3 passed in full, W4 stable, **and V-1 re-run immediately before.** If anyone used
the Opportunity route since W0, a pending instance exists and must be recalled from the UI first.

**Do NOT delete anything.** "Retire" means deactivate:
- `Set_LOI_Approved_Flag` and `Set_Stage_Underwriting` in `workflows/Opportunity.workflow-meta.xml`
  **stay.** The retained inactive approval file still references them by name; deleting them breaks
  it. They go inert — exactly as the four `UW_*` field updates did (that file's header, `:3-16`).
- The approval file itself stays forever, with a "DO NOT REACTIVATE" comment. A destructive delete
  requires zero `ProcessInstance` history and this process has history.

**Org state after W5 — and this is where the losses become real:**
- `LOI_Approved__c` has exactly one writer again: the new chain.
- 🔴 **Rejection no longer returns the deal to `Underwriting`** (unless D-3 says otherwise).
  `No_Backward_Stage_Movement` CARVE-OUT 1 becomes dead — harmless, but its comment now describes a
  path that does not exist, and `OpportunityStageEntryService`'s writer list (`:66-67`) becomes
  wrong. Both should be annotated in place, not deleted.
- 🔴 **`Underwriting_Approved_Before_LOI`'s "name both `Approved` and `Completed`" rationale is now
  historical** — the re-entry loop it protects against was created by this rejection. **Do not
  "simplify" that rule.** The `'Completed'` leg is still correct (an LOI-rejected deal that was
  rewound *before* this change still exists in the data), it just no longer has a live producer.
  Annotate it; changing it is a separate decision.
- The Opportunity is no longer locked while an LOI approval is pending.

**Rollback from W5:** redeploy `<active>true</active>`. Mechanically trivial, and it contradicts the
file's own retirement comment, so it is a **conscious, temporary** exception — record it if used.

---

### W6 — Backfill, then repoint the PSA gate (optional; see D-2)

Only if the user wants `Approved_LOI_Before_PSA` moved off the Opportunity mirror flag onto the
child's own field. **It is not required for anything else in this plan to work**, because the new
chain writes `LOI_Approved__c` (that is the entire point of W1).

**W6a — backfill.** Identify every deal the new rule would newly block: not yet at
`Under Contract (PSA)`, `LOI_Approved__c = true`, but whose `Primary_LOI__c` is blank or whose
`Primary_LOI__r.<new gate field>` does not read the approved value. Two sub-classes, both real —
child behind, and blank lookup. ⚠ A blank-lookup exemption is **already owned** by
`Approved_LOI_Before_PSA` itself (`ISBLANK(Primary_LOI__c)`), and `Completed_LOI_Before_PSA`'s header
(`:70-75`) explains at length why two messages for one problem is worse than one. Keep that split.

**W6b — deploy the VR.** Single component. 🟢 **Test-neutral if the gate reads
`Primary_LOI__r.LOI_Status__c = 'Approved'`** — `TestDataFactory.placeApprovedLoi` already sets it
(F24). It is **not** test-neutral against a new field.

**Rollback from W6:** redeploy the org body saved at **V-10**. Cheapest rollback in the plan.

---

### 4.1 Answer: is there a window where a deal is blocked?

| Wave | Deals blocked? | Reversible? |
|---|---|---|
| W1 | No — nothing changes for any deal | Yes, fully |
| W2 | No — new process is unreachable from the live route | Behaviour yes; the `ProcessDefinition` row, never |
| W3 | No — but a **silent-failure exposure** exists until P-1…P-9 pass | Yes (kill switch) |
| W4 | No — both writers live, the existing VR satisfied by either | Yes, cheaply |
| W5 | No — provided W1's writer is **proven**, not merely deployed | Yes (reactivate) |
| W6 | **Only if W6a is skipped**, and then only for the deals it identifies | Yes, cheaply |

**There is no unavoidable blocked window — but the reason is different from Underwriting's, and it is
weaker.** Underwriting had no window because a replacement writer already existed and was already
proven. Here there is no window **only because W1 builds one and W3 proves it before W5 retires the
original**. Collapse W1/W2/W5 into one deploy — the intuitive "one atomic cutover" — and the window
in §0.2 opens immediately: every deal in the org blocked from `Under Contract (PSA)` with no route
out. **That is the single most dangerous thing anyone could do to this plan.**

---

## 5. Every field update on the old process, and its fate

`Opportunity.LOI_Approval` has exactly **two** field updates. Both are Opportunity writes. Both are
structurally unreachable from a Lookup child (§0.4).

### 5.1 `finalApprovalActions` → `Set_LOI_Approved_Flag` → `Opportunity.LOI_Approved__c = true`

| Aspect | Verdict |
|---|---|
| Direct replacement | ❌ **Not possible from the new process.** |
| Indirect replacement | ⚠ **REPLACED-DIFFERENTLY, and the replacement must be BUILT** — W1's flow → Apex → one parent DML. This is the `UnderwritingApprovalStampService` shape, but no such class exists for the LOI and it is genuinely new work. |
| What breaks if it is not built | `Approved_LOI_Before_PSA` (§0.2) — **every deal blocked from PSA**. Plus all three actions of `LOI_Approval_Stamp` (F17): the audit stamp, and **two group notifications to humans**. Plus, transitively, `Is_Advance_Allowed__c` (F19) — the LOI cannot leave `'Under Review'`. |
| Also affected | `Deal_Sub_Stage__c`, a formula field reading `LOI_Approved__c` (`:64`). It follows the flag automatically; no work. |

### 5.2 `finalRejectionActions` → `Set_Stage_Underwriting` → `Opportunity.StageName = 'Underwriting'`

**This one is the sharp edge, and I do not think it can be replaced cleanly. State it to the user
rather than designing around it.**

| Aspect | Verdict |
|---|---|
| Direct replacement | ❌ Not possible from the new process. |
| Indirect replacement | ⚠ **Possible in principle** (a second branch of W1's flow → an Apex parent write), **but it does not behave the same way**, for one measured reason: |
| 🔴 **The replacement loses the validation-rule bypass.** | `LoiGateTest:89-104` and `No_Backward_Stage_Movement`'s header (`:116-128`) both record this org's finding that **approval-process field updates bypass custom validation rules entirely**. An Apex `update` does not. So a rejection rewind performed in Apex would newly have to satisfy `No_Backward_Stage_Movement` (carve-out 1 covers it — fine) **and `NDA_Signed_Before_Deal_Progression`, which gates entry to `Underwriting`** (`LoiGateTest:109` signs the NDA specifically to isolate this). A deal at LOI whose NDA was un-signed or repointed would have its **rejection refused** — and depending on how the write is wrapped, either the whole approval rolls back or the rewind is swallowed. |
| Cheap partial replacement | 🟢 **The LOI's own side of a rejection IS replaceable and is better than Underwriting's.** `LOI_Status__c` already carries a `'Rejected'` value on the `Acquisition_LOI` record type (F8). `finalRejectionActions` can write it directly on the LOI's own record — a real, queryable, reportable marker, unlike the Underwriting case where nothing changed. And `Is_Advance_Allowed__c` correctly keeps a `'Rejected'` LOI blocked at `'Under Review'` with no formula change. |
| Verdict | ❌ **The deal-stage rewind is LOST by default.** The LOI-side marker is a cheap, in-scope gain. This split is decision **D-3**. |

### 5.3 Not a field update, but lost the same way

| Thing | Fate |
|---|---|
| The **signed-NDA pre-check** (`OpportunityApprovalService.assertNdaSignedForLoiSubmission`, F23) | ⚠ **Silently stops firing** the moment `resolveApprovalTargetId` is repointed, unless repointed in the same change. W4 item 2. |
| `approvalPageFields` — `StageName`, `Amount`, `Asking_Price__c`, `My_Price__c` (F4) | ❌ **LOST.** `LOI__c` has no counterpart for any of the four. Approvers lose the deal's stage, its amount, the asking price and DPEG's price from the approval screen. The Underwriting cutover hit the identical problem and escalated it as a user gate rather than inventing fields (that file's header, `:45-50`). **Do the same — this is decision D-5, not work.** The LOI does carry `Offer_Price__c`, `Offer_Cap_Rate__c`, `NOI__c`, `Earnest_Money__c`, `Due_Diligence_Days__c`, `Closing_Period_Days__c` and `Opportunity__c`, which are arguably *better* fields for an LOI decision — but that is the user's call, not mine. |
| The **record lock** (`recordEditability = AdminOnly`, F2) | ⚠ **MOVES OBJECTS.** Today it freezes the Opportunity while an LOI approval is pending; after the move it freezes the LOI and leaves the deal editable. Probably an improvement. It is still a behaviour change and P-6 exists to observe it. |
| `ApprovalAuditService`'s LOI branch (F18) | ⚠ **Dies silently unless repointed in the same change**, exactly as the Underwriting branch did. The repoint is *simpler* here than it was there: the approval history now hangs off the LOI, and the record to stamp **is** the LOI, so the deal→`Primary_LOI__c` mapping query (`:151`) can go away entirely. That is a simplification, but it is still a code change and it must not be deferred. |

---

## 6. Every test whose behaviour changes

🔴 **Read V-5 first. Every row below is a claim about the REPO's copy.** The Underwriting cutover
found the org's `UnderwritingGateTest` had different method names and was passing against old
behaviour, so three predicted failures did not exist. Verify each against `ApexClass.Body` or
`ApexTestResult` before treating any of it as an acceptance criterion.

### 6.1 Goes RED at W5 (deactivating the old process) unless repointed

| # | Class.method | Why |
|---|---|---|
| 1 | `LoiGateTest.firstResponseApprovalStampsLoiAuditTrail:17-62` | `Approval.process(o.Id)` on an Opportunity at LOI; asserts `submitted.isSuccess()` at `:30`. `NO_APPLICABLE_PROCESS`. Also asserts `o.LOI_Approved__c` (`:54`) and the four LOI audit fields (`:56-61`) — the whole chain. |
| 2 | `LoiGateTest.rejectionReturnsDealToUnderwriting:65-87` | Same submission, plus `assertEquals('Underwriting', …)` at `:84`. Fails **twice over** — the submission, and §0.3. |
| 3 | `OpportunityApprovalServiceTest.submitsFromLoiRecordResolvesParent:283-293` | Asserts an LOI submission lands a `ProcessInstance` on the **parent** (`:293`). Contradicted by W4 by design. |
| 4 | `OpportunityApprovalServiceTest` routing assertion `:233,239-240` | `Assert.areEqual(o.Id, fromLoi, 'UNCHANGED: an LOI still resolves to its parent deal — LOI_Approval runs on the deal')`. This assertion **is** the thing being changed. |
| 5 | `OpportunityApprovalServiceTest.<ineligible-stage message>:355-356` | Asserts the refusal contains `'LOI approval runs at the LOI stage'`. That sentence stops being true. |

### 6.2 Goes RED at W4, or must move with it — the signed-NDA family (F23)

All of these exercise `assertNdaSignedForLoiSubmission` through an **Opportunity** target at LOI:
`signedNdaAtLoiStillSubmits:411`, `unsignedPrimaryNdaAtLoiIsRefusedWithTheTypedException:428`,
`blankPrimaryNdaAtLoiIsRefused:456`, `theNdaGateDoesNotFireAtAnyStageButLoi:488`, and the fixture at
`:519-532`. **[MEASURE]** each: after W4 some will fail outright and some will pass **vacuously**
(the gate returns at its first condition and asserts nothing). The vacuous ones are the dangerous
ones — they stay green while the gate is gone.

### 6.3 🔴 Passes but becomes VACUOUS — do not read its green as evidence

| Class.method | Why |
|---|---|
| `OpportunityApprovalServiceTest.underwritingWithParentAtLoiNeverEntersLoiApproval:185-215` | Its own comment (`:178-180`) states the fixture only means something because *"LOI_Approval really is still active — it is deliberately NOT part of this change."* After W5 it is not. The test asserts no instance is created; that becomes true for a reason unrelated to the defect it pins. **The 2026-08-28 cross-approval regression becomes unfalsifiable.** |
| `LoiGateTest.directLoiToUnderwritingUpdate_isAllowedByCarveOut1_notByApproval:106-121` | 🟢 **Unaffected — no `Approval.process` anywhere in it.** After W5 it becomes the **only** remaining pin on `No_Backward_Stage_Movement` CARVE-OUT 1. Its own docstring already argues why it, and not its sibling, is the real pin. Protect it. |

### 6.4 Changes behaviour at W1 — the non-obvious set

Depends entirely on the marker chosen (D-4). If W1's flow keys on `LOI_Status__c = 'Approved'` with
`CreateAndUpdate`, then **every** caller of `TestDataFactory.placeApprovedLoi` fires it on insert
(F24) and gains parent side effects. Known callers to re-run and read carefully at W1:
`StageApprovalGatesTest`, `StageAdvanceServiceTest`, `StageAdvanceControllerTest`,
`OpportunityReviewServiceTest`, plus the seeds at `seed-fsd-03:71`, `seed-fsd-04:78`,
`seed-fsd-02:156`, `seed-fsd-05:91`, `seed-deal:45`, `seed-nda-loi-metrics:28-32`.
**Check whether any is a 251-record bulk caller before choosing the marker.** I did not verify this
for every call site; the Underwriting equivalent found none, but that is not evidence about these.

### 6.5 Coverage that does not exist and should not be assumed

- `ApprovalAuditServiceTest` **deliberately does not test the LOI gate** (F26, `:31-34`).
- `scripts/verify-junior-lifecycle.apex` **cannot run** — it is written against a retired stage model
  (F25). `ApprovalAuditService`'s header names it as the safety net for exactly this class of silent
  failure. **That safety net does not exist.** Say so; do not repair it as part of this change.

---

## 7. Open decisions that are genuinely the user's

| # | Decision | Why it is theirs |
|---|---|---|
| **D-1** | 🔴 **Confirm the scope before anything else.** The *Submit for Approval* button is **already on the LOI record page** (§0.1). What is on the Opportunity is the approval **process** — its history, its lock, its approval screen and its Recall route. Is the request (a) "move the process to the LOI record", the full cutover designed here, or (b) something narrower that already works? | The whole plan exists or does not exist on this answer. It is also the cheapest question to ask. |
| **D-2** | **Where should the PSA gate read from after the move?** Leaving `Approved_LOI_Before_PSA` on `LOI_Approved__c` is safe and requires no W6 — the new chain writes that field. Repointing it to the child's own field is *tidier* and matches what `Underwriting_Approved_Before_LOI` just did, but costs a backfill and a wave. | A preference about where truth lives, with a real data-migration cost. Not a correctness question. |
| **D-3** | 🔴 **What should happen on rejection?** Today the deal is rewound `LOI → Underwriting` and a test pins it. After the move that write is structurally impossible from the new process, and an Apex substitute **newly has to satisfy the signed-NDA validation rule** the current bypass sidesteps (§5.2). Three options: (i) accept the loss and stamp `LOI_Status__c = 'Rejected'` on the LOI only; (ii) also rebuild the deal rewind in Apex and accept that it can be refused; (iii) keep rejection handling on the Opportunity by not moving at all. | A visible workflow change with a measured, non-obvious side effect. The Underwriting cutover inherited its equivalent decision silently and its own design document flags that as its weakest part. **Do not repeat that here.** |
| **D-4** | **Which field does the new approval write, and therefore what does the mirror flow key on?** `LOI_Status__c = 'Approved'` costs no new field and is **test-neutral** (F24) — but `TestDataFactory` and six seed scripts already write it, so the flow is not seed-inert. A **new single-purpose marker field** makes the fixtures immune by construction but is a new field the user did not request. | A new field is scope. The trade is real and small either way. |
| **D-5** | 🔴 **Four of the six approval-page fields have no counterpart on `LOI__c`** — `StageName`, `Amount`, `Asking_Price__c`, `My_Price__c` (F4). Approvers lose that context from the approval screen. Which LOI fields should replace them? | Information loss for the two named principals. **Do not invent fields to close it** — that is what the Underwriting file's header refused to do, correctly. |
| **D-6** | If V-6 finds `allowedSubmitters = owner` does not work on a queue-owned record: **who may submit?** | A submitter set is an access decision. |
| **D-7** | `Underwriting_Approved_Before_LOI`'s dual-value formula (`'Approved'` OR `'Completed'`) was justified **by the LOI rejection loop** this change removes (§4/W5). Leave it (recommended — the data it protects still exists) or revisit it? | A live validation rule whose rationale changes underneath it. Worth a conscious "leave it alone". |

---

## 8. Things I think are a bad idea, stated plainly

**8.1 🔴 Do not deploy this as one atomic payload — and here that is not a style preference, it is the
difference between a working cutover and blocking every deal in the org from `Under Contract (PSA)`.**
The intuition ("one deploy, no windows") was *merely* wrong for Underwriting. Here it is actively
dangerous: `Opportunity.LOI_Approved__c` has exactly one writer (§0.2), and a payload that deactivates
`Opportunity.LOI_Approval` before its replacement is **proven** — not merely deployed — leaves
`Approved_LOI_Before_PSA` with nothing that can satisfy it. `RecordStageAdvanceService`/`NEXT_STAGE`
offers no manual route around it and the message is a validation-rule toast with no remedy the user
can perform.

**8.2 🔴 Do not deactivate the old process in the same wave that repoints the submit route.** W4 and
W5 are separate on purpose. W4 makes the new route live while the old process is still active as an
escape hatch; W5 removes the hatch only after the new route has been used. Merging them means the
first failure has no fallback.

**8.3 🔴 Do not copy `Opportunity.LOI_Approval`'s XML onto `LOI__c` and change the object name.**
Three of its properties do not transfer and each fails differently: `allowedSubmitters = owner`
against a **queue-owned** record (§0.5, unmeasured); `entryCriteria` with **no record-type criterion**
on a value shared by both record types (F5/F7 — it would pull disposition LOIs into an acquisition
approval); and `approvalPageFields` naming **four fields that do not exist** on `LOI__c` (F4 — that
one at least fails at deploy rather than silently).

**8.4 ⚠ Do not "simplify" `ApprovalAuditService` by deleting the deal→`Primary_LOI__c` mapping without
repointing the history read in the same edit.** The mapping becomes unnecessary — the record to stamp
*is* the approval's target — but the history read (`latestApproval.get(o.Id)`) is the half that must
change, and the class **swallows its own failures by design**. Delete one without the other and the
LOI audit stamp writes nothing, forever, with no error; and via F19 the LOI then cannot leave
`'Under Review'`. This is the exact failure the same class already suffered on the Underwriting
branch four days ago.

**8.5 ⚠ Do not treat a green deploy as the acceptance criterion.** The two hops with no precedent on
this object — the record-type criterion in `entryCriteria`, and the field-update → after-save-flow →
Apex → parent-DML chain run as a non-owning read-only approver — both fail **silently**. W3's
P-1…P-9, on a live record, with the **non-administrator** principal, is the acceptance criterion.

**8.6 ⚠ Do not delete anything.** Not `Set_LOI_Approved_Flag` or `Set_Stage_Underwriting` (the
retained inactive approval file still references them by name), not the approval file (a destructive
delete is refused once history exists), not `No_Backward_Stage_Movement` CARVE-OUT 1 (dead but
harmless; annotate it), and not the `'Completed'` leg of `Underwriting_Approved_Before_LOI` (D-7).

**8.7 ⚠ Do not run `RunLocalTests` as a deploy gate between W4 and W5.** The tests in §6.1/§6.2 are
red by construction during that interval. Baseline first (V-11), `RunSpecifiedTests` in between, one
full `RunLocalTests` after W5 — and only against a baseline you captured yourself.

**8.8 ⚠ Do not repair `scripts/verify-junior-lifecycle.apex` as part of this change.** It is broken
against a stage model retired two phases ago (F25). Repairing it is a legitimate task; doing it here
would mean debugging an unrelated 100-line script inside an approval cutover, and the repaired script
would then be the *only* thing asserting behaviour that a proper test should assert.

**8.9 ⚠ I would raise D-3 (rejection) BEFORE W2, not after.** Adding a `finalRejectionActions` entry to
an **active** approval process is a live-process edit; adding it to the file before it is ever
activated is a plain deploy. The Underwriting cutover made exactly this mistake and its own design
document says so.

---

## 9. Admin vs Developer split

### 9.1 Honest statement of scope before the prompts

**Unlike the Underwriting cutover, this one requires NEW code and NEW metadata.** That plan's prompts
both said "author nothing, every file already exists". That is **false here**: the parent-mirror Apex
service, the `LOI__c` workflow file, the `LOI__c` after-save flow, the approval process itself, and
the two Approval-History files do not exist in `force-app`. Anyone told "just deploy what's there"
will not find it.

**But nothing should be authored until W0 reports and D-1…D-6 are answered.** Several of the
decisions change what gets built, not merely how.

---

### 🔵 PROMPT FOR `salesforce-admin`

```
Execute the declarative half of the LOI approval cutover described in
agent-output/loi-approval-cutover-design.md. Read that document first; it is the specification.

🔴 STOP CONDITION: do not begin W1 until the user has answered decisions D-1 through D-6 in §7.
D-1 alone may cancel this work entirely (the Submit for Approval button is ALREADY on the LOI
record page; only the approval process is on the Opportunity). D-3, D-4, D-5 and D-6 each change
what gets built.

Record `mcp=complete|unavailable` + `mcp_tools=<list>` per metadata type before any deploy, and
load the matching per-type skill. Note: `.mcp.json` in this repo configures only the `salesforce`
server, so `salesforce-api-context` is expected to be unavailable — make a real attempt, record
the result, fall back to the skill.

BLOCKING PRECONDITION (R-0): confirm with the concurrent session that no repo-wide or
directory-wide deploy will run until this cutover completes. Every deploy you make is an explicit
component list.

W0 — verification only, no deploy. Complete V-0 through V-12 from §3 and report each result
     individually. Do not proceed on any item that comes back other than expected.
     V-9 and V-10 require you to SAVE the org copies you retrieve — they are the rollback
     artifacts for W1 and W6.
     🔴 V-4 and V-6 are stop conditions. V-4 asks whether the LOI audit stamp is working in
     production TODAY; if it is not, report that before designing around it. V-6 asks what
     `allowedSubmitters type=owner` does on a QUEUE-OWNED record — auto-created acquisition LOIs
     are owned by the `Acquisition` queue, so the current process's submitter setting may not
     transfer at all.

W1 — author and deploy, as ONE explicit component list:
       workflows/LOI__c.workflow-meta.xml            (NEW — the approval's field updates)
       flows/<LOI approval mirror>.flow-meta.xml     (NEW — after-save on LOI__c, Active)
       layouts/LOI__c-LOI Layout.layout-meta.xml     (ADD RelatedProcessHistoryList)
       flexipages/LOI_Record_Page.flexipage-meta.xml (ADD force:relatedListContainer)
     🔴 The approval-history entry MUST use force:relatedListContainer. This org returns
     INVALID_TYPE for force:relatedListSingleContainer on approval history — measured on
     Disposition_Record_Page. Deploying green is not proof; open the record and look.
     🔴 Re-run V-9's retrieve-and-diff on the FlexiPage and the layout SECONDS before deploying.
     A FlexiPage deploy replaces the org copy and this repo has lost hand-made edits that way.
     Coordinate with the developer stream: their Apex must land before or with the flow.
     Test level: NoTestRun or RunSpecifiedTests.

W2 — re-run V-1 (pending ProcessInstance count on Opportunity.LOI_Approval must be 0), then deploy
     ONE component: the new approvalProcesses/LOI__c.<Name>. This is the irreversible step.
     🔴 It MUST carry a record-type criterion. 'Under Review' is shared by BOTH LOI record types.
     🔴 The entryCriteria record-type construct has NO in-repo precedent on an approval process.
     Probe it with a throwaway check-only validation under a scratch name, in BOTH directions
     (accepted for a real field, REJECTED for a bogus one behind the same hop) before authoring
     the real file. Do not guess the XML shape.
     🔴 Anything finalApprovalActions writes to Stage__c must be a value Acquisition_LOI carries —
     restriction IS enforced by Apex DML in this org, and a refusal inside an approval transaction
     rolls the approval back.

W3 — NO DEPLOY. Run the live proof in §4/W3. Submit a real Acquisition_LOI, approved by a named
     principal who does NOT own the record and is NOT a System Administrator. Report P-1 through
     P-9 individually, INCLUDING P-9 (a separate rejection run — record exactly what happens to
     the deal's StageName). If any fails, STOP — do not run W4 — and report.

W4 — coordinate with the developer stream (see their prompt). Deploy the FlexiPage visibility
     change only if the Submit button's criteria need to match the new entry criteria.

W5 — re-run V-1. Recall any pending instance in Setup first. Then deploy ONE component:
     approvalProcesses/Opportunity.LOI_Approval, <active>false</active>.
     Delete NOTHING — not Set_LOI_Approved_Flag, not Set_Stage_Underwriting, not the file itself.
     Annotate in place (do not edit the logic of): No_Backward_Stage_Movement CARVE-OUT 1, and
     Underwriting_Approved_Before_LOI's dual-value rationale — both now describe a path with no
     live producer.

W6 — only if the user answered D-2 in favour of it. W6a (backfill + report affected deals) BEFORE
     W6b (the validation rule).

After W5, tell the deal drivers what changed: where the approval now lives, that the deal is no
longer locked while an LOI approval is pending, and — depending on D-3 — that a rejection no
longer rewinds the deal to Underwriting.
```

---

### 🟢 PROMPT FOR `salesforce-developer`

```
Support the Apex half of the LOI approval cutover described in
agent-output/loi-approval-cutover-design.md. Read that document first.

🔴 STOP CONDITION: do not write anything until D-1, D-3 and D-4 in §7 are answered. D-4 decides
what the mirror flow keys on and therefore what your service is triggered by.

⚠ UNLIKE THE UNDERWRITING CUTOVER, THIS ONE REQUIRES NEW CODE. Do not look for an existing
`LoiApprovalStampService` — there is none. That is the central finding of §0.2.

W0 (verification, contributes to the admin stream):
  - V-4: query live LOI__c rows whose deal has LOI_Approved__c = true and report whether
    LOI_Status__c = 'Approved' and Approved_By__c are actually populated. This establishes whether
    the LOI audit stamp works in production TODAY.
  - V-5: 🔴 read the ORG's copy of LoiGateTest and OpportunityApprovalServiceTest, method by
    method, and compare against the repo. The Underwriting cutover found the deployed
    UnderwritingGateTest had different method names and was passing against OLD behaviour, so
    three predicted failures never existed. Report the diff before anyone treats §6 as fact.
  - V-11: capture a baseline ApexTestResult run with timestamps. COUNT THE SHARED WORKING TREE
    YOURSELF (`git status`) — do not trust any figure in this document or the Underwriting one.

W1 (new Apex, deployed with or before the admin stream's flow):
  A parent-mirror service in the UnderwritingApprovalStampService shape — read that class before
  writing this one and copy its structure, not its content:
    - `without sharing` with a written justification in the class header (ARCHITECTURE.md §2);
    - ONE Database.update on the parent Opportunity, AccessLevel.SYSTEM_MODE, allOrNone = true so
      it throws loudly rather than writing nothing;
    - it runs as the APPROVER, who is read-only on Opportunity (measured — see
      ApprovalAuditService:167-169). SYSTEM_MODE lifts CRUD/FLS but NEVER sharing, which is why
      `without sharing` is also required;
    - it must write Opportunity.LOI_Approved__c = true. That field has exactly ONE writer today
      (the retiring approval's field update) and Approved_LOI_Before_PSA reads it. If your service
      does not write it, deactivating the old process blocks every deal from Under Contract (PSA).
    - orphan handling: an LOI with a blank Opportunity__c must be SKIPPED, not thrown on.
    - all SOQL in a selector (LoiSelector), per .claude/rules/apex-layering-rule.md.
  Plus its test class. Bulk expectations per .claude/rules/bulk-test-rule.md.

W4 (repoint the submit route — TWO edits, and the second is the one that gets forgotten):
  1. OpportunityApprovalService.resolveApprovalTargetId: LOI__c -> ITSELF (currently :319-321
     returns the parent via LoiSelector).
  2. 🔴 assertNdaSignedForLoiSubmission (:268-279) MUST be repointed in the SAME change. It
     returns immediately unless the target is an Opportunity at StageName = 'LOI'. Repoint the
     resolver without touching it and the signed-NDA gate — added 2026-08-30 and described in its
     own header as "a REFUSAL THAT WOULD OTHERWISE NOT HAPPEN" — silently stops firing.
     ⚠ Its header also says a validation rule on LOI__c is dead code for this path BECAUSE no DML
     touches the LOI row. After this change DML does. Note the retraction in place; do not act on
     it in this wave.
  3. The stage-derived refusal messages at :223-226 name a process that will no longer accept an
     Opportunity. Repoint them.
  4. 🔴 ApprovalAuditService's LOI branch (:149-163) reads the OPPORTUNITY's approval history
     (latestApproval.get(o.Id)) — repoint it to the LOI's own history in this same change. If you
     do not, it writes nothing, forever, AND SWALLOWS ITS OWN FAILURE BY DESIGN — and because
     Is_Advance_Allowed__c requires LOI_Status__c = 'Approved', the LOI then cannot leave
     'Under Review'. This is the identical failure this class already suffered on the Underwriting
     branch on 2026-08-28; read the 🔴 REPOINTED block in its header.

W5+ (verification only): re-run the tests listed in §6 and report. Pay particular attention to
  §6.3 — two tests PASS but become VACUOUS. Do not read their green as evidence.

WRITE NO NEW VALIDATION RULE and NO NEW FIELD. If either appears necessary, that is a decision in
§7 that has not been answered — report it rather than building it.
```

---

## 10. What could not be established from the repo, restated in one place

Each of these is a genuine "cannot be known without measuring the org", not a gap in the reading:

1. Whether `Opportunity.LOI_Approval` is actually Active in the org, and its pending-instance count (V-1).
2. Whether anything in the org — with no repo file — writes `LOI_Status__c = 'Pending Approval'` (V-3).
3. Whether the LOI audit stamp is working in production today (V-4).
4. Whether the ORG's `LoiGateTest` matches the repo's (V-5).
5. What `allowedSubmitters type=owner` does on a queue-owned record, and how many live LOIs are
   actually queue-owned (V-6).
6. Whether `ApprovalProcess.entryCriteria` accepts a record-type criterion at API 67.0, and in what
   XML shape (W2).
7. Whether either Approval-History file is present in the org copies of the LOI layout / FlexiPage (V-8).
8. Whether the `Principals` public group has members — **group membership is not deployable
   metadata**, and an empty group looks identical to a working one (V-7).
9. Whether any `placeApprovedLoi` call site is a 251-record bulk caller (§6.4).

**Do not let any of the above be answered by inference from this document.** Where I have written
[INFERRED], it may be wrong; where I have written [MEASURE], it is not yet known to anyone.
