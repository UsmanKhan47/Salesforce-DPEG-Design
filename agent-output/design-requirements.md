# DESIGN REQUIREMENTS — Move Principal Approval from Opportunity to Underwriting__c

**Date:** 2026-08-28
**Repo:** `f:\Acquisition-Design-Salesforce`  ·  **Branch:** `qa/lifecycle-simulation-2026-08-27`
**Org:** `usman-dpeg` (NON-SANDBOX Enterprise Edition)
**Status:** Analysis + plan only. NO metadata created or modified by this agent.

---

## 0. WHAT THE USER REQUESTED

> "We need the approval on Underwriting, not on Opportunity. Once the user clicks Initiate
> Underwriting, the Underwriting record is created, and there will be a validation on the Initiate
> LOI button — if the underwriting is not approved, it will not move on to LOI."

Gate-1 decisions D1–D4 are taken and are designed to, not re-asked. The five agreed pieces are
validated below; four of the five stand, **one (piece 2) rests on a false premise and one (piece 3)
contains a defect that would permanently strand deals.**

---

## 1. 🔴 CONTRADICTED PREMISES — READ BEFORE ANYTHING ELSE

Five things in the brief are wrong or incomplete against the repo. Each is measured, with the file.

### C-1. "Nothing in the org currently sets `Underwriting__c.Stage__c = 'Approved'`" — **FALSE**

`classes/ApprovalAuditService.cls:72-83` already does exactly this, today, on principal sign-off:

```apex
for (Underwriting__c uw : UnderwritingSelector.selectIdsByOpportunityIds(approvedUwOpps)) {
    uwUpdates.add(new Underwriting__c(Id = uw.Id, Stage__c = 'Approved',
                                      Status__c = 'Approved by Principals'));
}
```

It is invoked by `flows/Opportunity_UW_Approved_Notify` (action `Stamp_Approval_Audit`), which fires
on the Opportunity's transition into `Underwriting_Status__c = 'Approved by Principals'`.
`classes/RecordStageAdvanceService.cls:1354-1372` documents the same fact, and
`classes/UnderwritingGateTest.cls:105-111` asserts it and is green.

**So the Underwriting Path does NOT stick at "In Progress" forever today** — it reaches Approved via
a three-hop chain (Opportunity approval → `UW_Set_Status_Approved` → notify flow → `ApprovalAuditService`).
The chain is fragile and indirect, and this change legitimately replaces it — but it is a
**replacement, not a dead-end fix**, and piece 2's stated justification must be retracted rather than
carried into the implementation prompts.

### C-2. 🔴 Piece 3's formula would PERMANENTLY STRAND any deal whose LOI approval is rejected

Piece 3 specifies `TEXT(Primary_Underwriting__r.Stage__c) <> 'Approved'`. That is wrong on its own,
and the failure is unrecoverable through the UI:

1. `approvalProcesses/Opportunity.LOI_Approval` `finalRejectionActions` → `Set_Stage_Underwriting`
   moves a rejected deal from `LOI` back to `Underwriting`
   (`workflows/Opportunity.workflow-meta.xml:14-22`).
   `No_Backward_Stage_Movement` CARVE-OUT 1 exists specifically to permit it.
2. By then the Underwriting record has normally been walked to its terminal
   `Stage__c = 'Completed'` (`Underwriting__c.Move_to_Completed`, gated at `Approved`,
   `flexipages/Underwriting_Record_Page.flexipage-meta.xml:80-93`).
3. The deal driver clicks **Initiate LOI** again. `Stage__c` reads `'Completed'`, not `'Approved'`
   → the VR **blocks**.
4. There is no route back. `'Completed'` is the terminal of `UNDERWRITING_NEXT_STAGE`
   (`RecordStageAdvanceService.cls:1374-1378`), no button targets `'Approved'`, and `Stage__c` is
   `<restricted>true</restricted>` — so only a direct admin edit can unstick it.

Today's `NOT(UW_Approved__c)` has no such hole because the flag **latches** — the VR's own comment
records this as "Known, accepted".

**REQUIRED CORRECTION.** The error condition must name **both** terminal-side values, exactly the
`list-both` shape `Completed_LOI_Before_PSA` already uses in the same folder:

```
AND(
    ISCHANGED(StageName),
    ISPICKVAL(StageName, 'LOI'),
    TEXT(Primary_Underwriting__r.Stage__c) <> 'Approved',
    TEXT(Primary_Underwriting__r.Stage__c) <> 'Completed'
)
```

`TEXT(...)` not `ISPICKVAL(...)`: the repo's standing rule, and independently required here because
`ISPICKVAL` resolves its literal at deploy time against a cross-object picklist.

**No `NOT(ISBLANK(Primary_Underwriting__c))` guard** — deliberately unlike `Completed_LOI_Before_PSA`.
That rule exempts the blank case because a *sibling* rule (`Approved_LOI_Before_PSA`) already owns it
and two messages for one problem is worse than one. **Here no sibling rule exists**, so the blank
lookup must stay **fail-closed**: a deal with no underwriting record must not enter LOI. State this in
the file's XML comment so nobody "fixes" it by copying the sibling.

### C-3. Retiring the old approval silently kills the **UW_Approved_By__c / UW_Approval_Date__c audit stamp** — not mentioned in the brief

`ApprovalAuditService.latestApprovedStepByTarget` reads `ProcessInstanceStep` by
`ProcessInstance.TargetObjectId`. After retirement there is **no Opportunity ProcessInstance**, so:

- `latestApproval` is empty → `step == null` → `UW_Approved_By__c` / `UW_Approval_Date__c` are never
  stamped, and `approvedUwOpps` stays empty so the Underwriting child block never runs either.
- The class swallows failures by design, so **this regression is completely silent.**
- `scripts/verify-junior-lifecycle.apex:58-60` asserts `UW_Approved__c && UW_Approved_By__c != null`
  and is the only thing that would notice.

The mirror-field mechanism must therefore also repoint the audit read to the **Underwriting record's**
approval history. Section 4 does this in the same class, in the same DML.

### C-4. 🔴 `Underwriting__c` has **no Approval History and no Recall route** — the new approval is unrecallable as designed

- `flexipages/Underwriting_Record_Page.flexipage-meta.xml` contains **no** `force:relatedListContainer`
  (grep of `componentName`: highlightsPanel, pathAssistant, column ×2, fieldSection,
  `force:relatedListSingleContainer`, tab ×2, tabset, dealMessageLog).
- `layouts/Underwriting__c-Underwriting Layout.layout-meta.xml` contains **no**
  `RelatedProcessHistoryList`.

Per the measured note in `flexipages/Disposition_Record_Page.flexipage-meta.xml:186-212` and
`layouts/Disposition_Offer__c-...:73-74`, **the layout-driven Approval History related list is the
only route to Recall Approval Request**, and `force:relatedListSingleContainer` pointed at approval
history deploys green and renders nothing (`INVALID_TYPE` from the related-list UI API).

With `recordEditability = AdminOnly` (D3), a mis-submitted Underwriting record would be **locked with
no way to recall it**. Both halves must ship: the layout block AND the FlexiPage component.
The Opportunity side already has both (`Opportunity_Record_Page:1438` +
`Opportunity-Opportunity Layout:344`) — which is what makes the step-1 recall possible.

### C-5. The seed scripts are **already immune** — no seed sweep needed

`scripts/seed-fsd-02/03/04/05-*.apex` already set the Underwriting child to
`Stage__c = 'Approved', Status__c = 'Approved by Principals'` **before** moving the Opportunity to
`'LOI'` (e.g. `seed-fsd-03:56-60`, `seed-fsd-02:145-149`). The corrected VR therefore passes on every
seeded deal with **zero edits**. Their `update new Opportunity(..., UW_Approved__c = true, ...)` lines
become redundant but harmless — leave them (they keep the mirror truthful under D4).

**Smaller true findings, recorded so they are not re-derived:**

| Premise | Verdict |
|---|---|
| `Underwriting__c.Opportunity__c` is a Lookup | ✅ CONFIRMED (`fields/Opportunity__c.field-meta.xml:12`, `deleteConstraint SetNull`) |
| `Submit_for_Approval` already renders at `Stage__c = 'In Progress'` | ✅ CONFIRMED (`Underwriting_Record_Page:34-47`, pure `1 AND 2`) |
| `Primary_Underwriting__c` is a Lookup on Opportunity, so `Primary_Underwriting__r.Stage__c` is a legal VR reference | ✅ CONFIRMED (`fields/Primary_Underwriting__c.field-meta.xml:13`) |
| `'Approved'` is on the master value set; `Underwriting__c` has **no record types** | ✅ CONFIRMED (`Underwriting__c/Stage__c.field-meta.xml:24-28`; no `recordTypes/` dir). The field IS `<restricted>true</restricted>`, so the write would have been refused had the value been absent — **the check was necessary, and it passes.** |
| Nothing in scope is `.forceignore`d | ✅ CONFIRMED — no entry covers `approvalProcesses/`, `flows/`, `workflows/`, `objects/Underwriting__c/**`, `objects/Opportunity/**`, `layouts/Underwriting__c-*`, `flexipages/`, or the classes. ⚠ `flowDefinitions/**` IS ignored: new flows must carry `<status>Active</status>` in the `.flow-meta.xml` itself. |
| `Opportunity.Submit_for_Approval` reachability | ⚠ The quick action **exists** but appears on **neither** `Opportunity_Record_Page` **nor** `Opportunity-Opportunity Layout`. Its only reach is a direct `@AuraEnabled` call or an admin adding it. This lowers the practical risk of open item (b) to near zero — the message fix is still required (§6). |

---

## 2. BLOCKING DECISION GATES

Two items cannot be resolved from the repo. They must be answered before the admin/dev agents run.

### GATE A — one new field on `Underwriting__c`, or drop the reject direction?

🔴 **Measured fact that forces this gate: `Stage__c` DOES NOT CHANGE ON REJECTION, so no
`Stage__c`-keyed mechanism can see a rejection at all.** The approval's entry criterion is
`Stage__c = 'In Progress'`; nothing moves it during the pending window; D2's "returns to 'In Progress'"
is therefore a **same-value, no-op field update**. A record-triggered flow with
`doesRequireRecordChangedToMeetCriteria = true` never fires; without that flag it fires on the
*submission* save too and would clear `Underwriting_Complete__c` at exactly the wrong moment.
`Status__c` fails identically (it is already `'In Progress'` — seeded that way by
`OpportunityReviewService.cls:489`).

| Option | Cost | Verdict |
|---|---|---|
| **A1 (RECOMMENDED)** — new `Underwriting__c.Approval_Status__c`, restricted picklist `Approved` / `Rejected`, written by the approval's own `finalApprovalActions` / `finalRejectionActions` field updates. The new sync flow keys on **its** change and branches. | 1 field + 1 workflow file | **Exact in-repo precedent:** `Disposition_Offer__c.Approval_Status__c` + `Set_Offer_Approval_Approved` / `Set_Offer_Approval_Rejected` (`approvalProcesses/Disposition_Offer__c.Offer_Selection_Approval:116-128`). Own-record updates, so the Lookup constraint does not bite. **Bonus: single-writer.** The seed scripts and `TestDataFactory` write `Stage__c`, never this, so they are immune to the new automation by construction — today's seed behaviour is preserved byte-for-byte, and a manual `Stage__c` edit cannot fake an approval. |
| **A2** — key on `Stage__c = 'Approved'`; accept that `Opportunity.Underwriting_Complete__c` is **no longer auto-cleared on rejection**. | 0 new metadata | Defensible: the approval's own description already records that Section 12B "no longer gates submission", and D3's lock inversion hands the analyst edit access back on rejection so they can untick it. But it is a **silent behaviour loss** vs. today's `UW_Reopen_For_Revision`, and it makes the seeds fire the market-data freeze (behaviour change). |
| **A3 (REJECTED)** — `finalRejectionActions` writes `Stage__c = 'In Progress'` | — | Measurably a **no-op**. Must not be chosen. |
| **A4 (REJECTED)** — `finalRejectionActions` writes `Stage__c = 'Requested'` | — | Detectable, but contradicts D2, and "Requested" means "not started", which is false for a reworked model. |
| **A5 (REJECTED)** — `initialSubmissionActions` to set a marker on submit | — | `initialSubmissionActions` and `recallActions` appear **nowhere** in `approvalProcesses/**`; the XML shape is unproven at 67.0 and a block that deploys green and never fires is worse than the gap. |

**Ask the user: A1 or A2?**

### GATE B — the approval page loses two fields the principals see today

`Opportunity.Underwriting_Approval.approvalPageFields` shows `Name, Owner, StageName,
Asking_Price__c, My_Price__c, Underwritten_NOI__c, My_Cap_Rate__c, Underwriting_Notes__c`.

`Asking_Price__c` and `Underwriting_Notes__c` are **Opportunity** fields. An `Underwriting__c`
approval page cannot show them, and `Underwriting__c` has **no counterpart for either** (verified
against `objects/Underwriting__c/fields/`: 18 fields, no notes field, no asking price).

**Ask the user:** accept the loss (approvers open the parent deal via the `Opportunity__c` lookup on
the page), or is a field needed? **Do not invent one.**

Proposed page fields, all confirmed to exist and all granted read by `DPEG_Acquisition_View`:
`Name, Owner, Opportunity__c, My_Price__c, My_Cap_Rate__c, Market_Cap_Rate__c, Underwritten_NOI__c,
Target_Return__c, Principal_Price_Decision__c, Stage__c`.

### VERIFY-BEFORE-DEPLOY (org-side, not answerable from this repo)

| # | Check | Why it is fatal |
|---|---|---|
| V1 | The two approvers hold a permission set granting `Underwriting__c` read. `DPEG_Acquisition_View` grants `allowRead=true, viewAllRecords=true` (`:1791-1799`), which also solves the Private OWD (`sharingRules/Underwriting__c.sharingRules-meta.xml` is **EMPTY** — zero rules on a Private object). There is **no `DPEG Principal` permission set in this repo**; the org is the only source of truth. | Without it the approval request opens on a record the principal cannot see. |
| V2 | Exactly ONE pending `ProcessInstance` on `Underwriting_Approval` (§3 step 1). | A stranded instance cannot be actioned or recalled. |
| V3 | `Opportunity_Record_Page`'s `force:relatedListContainer` has `showActionBar = true` (needed for the Recall button in step 1). | Determines whether step 1 is a UI recall or an anonymous-Apex recall. |

---

## 3. EXECUTION ORDER

Step 1 is the recall and is **non-negotiably first**.

| # | Step | Owner | Type |
|---|---|---|---|
| **1** | **RECALL the one pending `Underwriting_Approval` instance** (details below) | Human (submitter or SysAdmin) | Operational |
| 2 | Answer GATE A + GATE B; confirm V1–V3 | User / DevOps | Gate |
| 3 | `Underwriting__c.Approval_Status__c` field + `workflows/Underwriting__c.workflow-meta.xml` field updates *(A1 only)* | Admin | Metadata |
| 4 | Approval History: `layouts/Underwriting__c-Underwriting Layout` `relatedLists` block **AND** `flexipages/Underwriting_Record_Page` `force:relatedListContainer` — **two files, neither works alone** | Admin | Metadata |
| 5 | NEW `approvalProcesses/Underwriting__c.Underwriting_Approval.approvalProcess-meta.xml` (`<active>false</active>` initially) | Admin | Metadata |
| 6 | NEW `flows/Underwriting_Approval_Sync.flow-meta.xml` | Admin | Metadata |
| 7 | Apex: `ApprovalAuditService`, `OpportunityApprovalService`, `StageAdvanceService`, `TestDataFactory` | Developer | Apex |
| 8 | LWC: `submitForApproval` confirm wording + its Jest test | Developer | LWC |
| 9 | **DEACTIVATE** `Opportunity.Underwriting_Approval` (`<active>false</active>`) | Admin | Metadata |
| 10 | Rewrite `Opportunity.Underwriting_Approved_Before_LOI` (the corrected two-value formula, §C-2) | Admin | Metadata |
| 11 | **ACTIVATE** the new `Underwriting__c` approval (`<active>true</active>`) | Admin | Metadata |
| 12 | Test classes (§7) | Unit Testing | Apex |
| 13 | Post-deploy verification (§8), incl. **re-submitting the deal recalled in step 1** | DevOps + Human | Verification |

**Why steps 9 → 10 → 11 in that order.** Between 9 and 10 the old VR still reads
`NOT(UW_Approved__c)`, which is the *permissive* state for every already-approved deal — no deal is
blocked in the window. Repointing the VR (10) **before** the new approval is live (11) means an
un-approved deal is correctly refused rather than being handed a hop the new process cannot yet
grant. Doing 10 before 9 would mean neither process could satisfy the new formula.

⚠ **Do not fold step 5+11 into one deploy.** Two active approval processes whose entry criteria are on
different objects cannot collide, but shipping the new one inactive first gives a clean revert
boundary for the layout/FlexiPage half (step 4) — the same G4 discipline
`LOI_Record_Page.flexipage-meta.xml:406-410` records as having been skipped, to its cost.

### Step 1 in full — the recall

- **Who.** `allowedSubmitters` is `owner`, so the **record owner** of the deal, or any user with
  *Modify All Data*. Nobody else can recall it.
- **How (primary).** Open the Opportunity → **Approval History** related list → **Recall Approval
  Request**. Confirmed available: `Opportunity_Record_Page:1438` carries
  `force:relatedListContainer` and `Opportunity-Opportunity Layout:344` carries
  `RelatedProcessHistoryList`. `allowRecall` is `true` on the process. Verify V3 first.
- **How (fallback).** Anonymous Apex, run **as the submitter or a SysAdmin**:
  ```apex
  ProcessInstanceWorkitem wi = [
      SELECT Id FROM ProcessInstanceWorkitem
      WHERE ProcessInstance.ProcessDefinition.DeveloperName = 'Underwriting_Approval'
        AND ProcessInstance.Status = 'Pending' LIMIT 1];
  Approval.ProcessWorkitemRequest r = new Approval.ProcessWorkitemRequest();
  r.setWorkitemId(wi.Id);
  r.setAction('Removed');
  Approval.process(r);
  ```
- **Verification — server-side, not counter-reading.** Both must return **0**:
  ```sql
  SELECT COUNT() FROM ProcessInstance
   WHERE ProcessDefinition.DeveloperName = 'Underwriting_Approval' AND Status = 'Pending'
  SELECT COUNT() FROM ProcessInstanceWorkitem
   WHERE ProcessInstance.ProcessDefinition.DeveloperName = 'Underwriting_Approval'
  ```
- ⚠ **A recall fires NO actions** — no field update, no stamp. The deal simply unlocks at
  `StageName = 'Underwriting'` with `UW_Approved__c` still false. That is the correct end state.
- ⚠ **The recalled deal must be re-submitted from its Underwriting record after step 11.** It is the
  org's only active deal; add it to the §8 checklist by name.

---

## 4. 🔵 ADMIN WORK (`salesforce-admin`)

### A-1. NEW `approvalProcesses/Underwriting__c.Underwriting_Approval.approvalProcess-meta.xml`

Copy the shape of `approvalProcesses/Disposition_Offer__c.Offer_Selection_Approval` — same object
class (a child with a Lookup parent), same approvers, same `FirstResponse`.

- `<active>` — `false` at step 5, `true` at step 11.
- `allowRecall` `true`; `allowedSubmitters` `owner`.
- `entryCriteria` → `Underwriting__c.Stage__c` equals `In Progress`.
- Approvers — **UNCHANGED per D1**: `nikhil.dhanani@usmandpeg.uat`,
  `aftab.ali.dpeg.usman@avanzasolutions.com`, `whenMultipleApprovers = FirstResponse`.
- `recordEditability` → **`AdminOnly`** (D3).
- `finalApprovalRecordLock` `false`; `finalRejectionRecordLock` `false`.
- `showApprovalHistory` `true`; `enableMobileDeviceAccess` `false`; `processOrder` `1`.
- `approvalPageFields` — per GATE B.
- `finalApprovalActions` → field updates on **its own record**:
  `Stage__c = 'Approved'`, `Status__c = 'Approved by Principals'`, *(A1)* `Approval_Status__c = 'Approved'`.
- `finalRejectionActions` → *(A1)* `Approval_Status__c = 'Rejected'`. *(A2: none — nothing to write.)*
- ⚠ Any XML comment must sit **INSIDE** the root element (`sf` fails source conversion otherwise).
- ⚠ `<description>` under 255 chars, per the repo's uniform rule.

### A-2. NEW `workflows/Underwriting__c.workflow-meta.xml`

Field updates referenced above. Precedent file: `workflows/Disposition_Offer__c.workflow-meta.xml`.
Must deploy **before** A-1.

### A-3. *(A1 only)* NEW `objects/Underwriting__c/fields/Approval_Status__c.field-meta.xml`

Restricted picklist, values `Approved` / `Rejected`, no default. Mirrors
`Disposition_Offer__c.Approval_Status__c`. Add read FLS to `DPEG_Acquisition_View` and
`DPEG_Acquisition_Edit` in the same deploy.
⚠ **A PermissionSet deploy REPLACES its whole `fieldPermissions` set** — the edit must be additive
against the current repo file, and hub files must be diffed against HEAD before deploying.

### A-4. Approval History on `Underwriting__c` — TWO FILES, NEITHER WORKS ALONE

1. `layouts/Underwriting__c-Underwriting Layout.layout-meta.xml` — add a `relatedLists` block with
   `<relatedList>RelatedProcessHistoryList</relatedList>` and the standard five columns copied from
   `layouts/Opportunity-Opportunity Layout:338-345`.
2. `flexipages/Underwriting_Record_Page.flexipage-meta.xml` — add `force:relatedListContainer`
   (identifier `relatedLists`, `showActionBar = true`).
   🔴 **NOT `force:relatedListSingleContainer`** — measured `INVALID_TYPE`; it deploys green and
   renders nothing.

🔴 **FlexiPage deploy hazard.** A FlexiPage deploy REPLACES the org copy and there is no version
history. Before touching this file: `sf project retrieve start --metadata FlexiPage:Underwriting_Record_Page
--target-metadata-dir <tmp>` and diff — **never a plain retrieve over the project tree.** Also read
`SetupAuditTrail` for App Builder saves newer than the last retrieve, and do **not** toggle
`enableActionsConfiguration` (already `true`; toggling silently empties the whole action bar).

### A-5. NEW `flows/Underwriting_Approval_Sync.flow-meta.xml`

**DECISION: a SEPARATE flow. `Underwriting_Opp_Sync` is NOT extended.** Four independent reasons:

1. **ENTRY SEMANTICS.** `Underwriting_Opp_Sync` has **no entry filter and no
   `doesRequireRecordChangedToMeetCriteria`** — it fires on every save of every Underwriting record.
   The mirror stamp must be **transition-scoped**, because `MarketDataSnapshotService`'s freeze
   depends on `Opportunity.Underwriting_Status__c` genuinely *transitioning*. Folding an
   entry-scoped stamp into an every-save flow means hand-rolling `$Record__Prior` logic to
   reproduce a platform primitive, imperfectly.
2. **THE FILE'S OWN RECORDED DECISION FORBIDS IT.** `Underwriting_Opp_Sync`'s description states:
   *"Opp.Underwriting_Status__c is deliberately NOT synced - the approval process owns it."*
   Under this design **the approval still owns it**, via the new flow. Extending the sync flow would
   force a retraction of a decision that is still true.
3. **THE REJECT DIRECTION NEEDS A DIFFERENT ENTRY CONDITION.** A flow has ONE `<start>`.
   `Underwriting_Opp_Sync` cannot carry two.
4. **BLAST RADIUS.** `Underwriting_Opp_Sync` pushes the deal's headline numbers and is live and
   working. A separate flow can be deactivated for diagnosis without taking the numbers down.

**Shape:**
- Object `Underwriting__c`, `RecordAfterSave`, `CreateAndUpdate`,
  `doesRequireRecordChangedToMeetCriteria = true`.
- Entry filter — **A1:** `Approval_Status__c` not null (then a Decision branches Approved / Rejected).
  **A2:** `Stage__c EqualTo 'Approved'`, no branch.
- 🔴 `<runInMode>SystemModeWithoutSharing</runInMode>` — **mandatory**. This flow runs as the
  **approver**, and the approving principals are deliberately **read-only on Opportunity**
  (`MarketDataSnapshotService.cls:33-35`, measured). Without it the write silently does nothing.
- `<status>Active</status>` in the file (`flowDefinitions/**` is `.forceignore`d).
- **Approved branch** → `actionCalls` → apex `ApprovalAuditService`,
  `recordId = $Record.Id`, `gate = 'UnderwritingChild'`.
  🔴 **The parent write is done in APEX, not in a flow `recordUpdate`.** Reason:
  `ApprovalAuditService.cls:101-107` records a measurement that `SystemModeWithoutSharing` on the
  flow did **NOT** lift the access mode and the stamp "silently wrote nothing" until
  `AccessLevel.SYSTEM_MODE` was stated at the DML. Routing through Apex puts the write on the
  proven path *and* fixes C-3 in the same statement. `ApprovalAuditService` is already
  `without sharing`, which is separately required — `SYSTEM_MODE` lifts CRUD/FLS but **never
  sharing**, and the approver may not own the deal.
- **Rejected branch** *(A1 only)* → `recordUpdate` on `$Record.Opportunity__r` setting
  `Underwriting_Complete__c = false`.

### A-6. REWRITE `objects/Opportunity/validationRules/Underwriting_Approved_Before_LOI.validationRule-meta.xml`

Use the **corrected four-clause formula from §C-2** — not the three-clause version in the brief.

- `errorDisplayField` stays `StageName`.
- New `errorMessage`, ≤255 chars, naming the real remedy:
  *"This deal cannot enter LOI until its Underwriting record has been approved by the principals.
  Open the deal's Underwriting record and use Submit for Approval."*
- Rewrite the existing XML comment: it currently claims the rule is "safe against the legitimate
  route by construction" because `Underwriting_Approval` sets `StageName = 'LOI'` and
  `UW_Approved__c` in the same save. That argument **dies** with this change and must be
  **retracted in place**, along with the "Known, accepted: `UW_Approved__c` is never cleared"
  paragraph — replaced by the C-2 two-value rationale and the deliberate absence of an `ISBLANK`
  guard.

### A-7. DEACTIVATE `approvalProcesses/Opportunity.Underwriting_Approval.approvalProcess-meta.xml`

🔴 **"Retire" means DEACTIVATE, not DELETE.** A `destructiveChanges` delete of an ApprovalProcess
requires no `ProcessInstance` history to exist; this process **has** history, so the delete will
fail. Set `<active>false</active>`, keep the file, and add an in-root XML comment recording the date,
the replacement, and "DO NOT REACTIVATE".

**Consequently, LEAVE the four `UW_*` field updates in `workflows/Opportunity.workflow-meta.xml`.**
They are referenced by the retained (inactive) process file; deleting them breaks its references.
They become inert. Record that in the workflow file's comment.

---

## 5. 🟢 DEVELOPMENT WORK (`salesforce-developer`)

All four classes are `with sharing` except `ApprovalAuditService`, which is `without sharing` with a
justification already in its header (ARCHITECTURE.md §2). No inline SOQL is added anywhere — every
read stays in its selector.

### D-1. `StageAdvanceService.cls` — Initiate LOI becomes a plain stage advance (piece 4)

- `NEXT_STAGE` gains `'Underwriting' => 'LOI'`.
- `advance()` — **delete** the entire `if (o.StageName == 'Underwriting') { ... }` branch
  (lines 147-158) and its `try/catch (OpportunityApprovalService.ApprovalException)`.
  The stage write then flows through `setStage()`, whose existing
  `catch (DmlException e) { throw new StageAdvanceException(e.getDmlMessage(0)); }` **surfaces the
  new VR's message verbatim in the user's toast — no extra work, and that is the whole gate.**
- **Header retractions (repo convention — retract in place, do not delete):**
  - the `APPROVAL HAND-OFF` block,
  - `GATES PRESERVED`'s clause *"Underwriting -> LOI still goes through the approval process rather
    than a direct write"*,
  - the `NEXT_STAGE` comment *"Underwriting is absent because that step is an approval submission,
    not a stage write."*
- **Cross-file retraction:** `RecordStageAdvanceService.cls:1366-1367` says
  *"Exactly the same shape as StageAdvanceService.NEXT_STAGE deliberately omitting 'Underwriting'"* —
  that comparison is now false and must be retracted there too. Its
  `NO_NEXT_STEP_HINTS['Underwriting|In Progress']` entry and `UNDERWRITING_NEXT_STAGE` itself are
  **CORRECT AS-IS and must not be touched** — the UW record still has no button from `In Progress`,
  and reaching `Approved` is still the approval's job.

### D-2. `OpportunityApprovalService.cls` — resolve to the UNDERWRITING record (open item **(a)**, RESOLVED)

**DECISION: branch inside the existing service. No new LWC, no new controller, no parameter.**

Rejected alternatives and why:
- *New LWC + controller* — duplicates the guard, the toast, the `getRecordNotifyChange` and a whole
  Jest suite, for a routing decision. It also puts the routing on the **client**, where the
  Underwriting page's visibility rule already is; a direct `@AuraEnabled` call bypasses it. The
  repo's own tightening precedent (`ALLOWED_EXPLICIT_TARGETS`) says routing belongs server-side.
- *A parameter on the shared `@AuraEnabled` method* — makes the target a caller-supplied value, which
  is exactly the class of hole `ALLOWED_EXPLICIT_TARGETS` was created to close.

**Change:** rename `resolveDealId` → `resolveApprovalTargetId` and make the `Underwriting__c` branch
return `recordId` itself. `Opportunity`, `LOI__c`, `Contract_Review__c` are **unchanged** — LOI_Approval
is not changing.

Everything downstream then works with no further edits:
- `ProcessInstanceSelector.selectPendingByTargetId(targetId)` now guards duplicate submission on the
  **Underwriting** record. Correct.
- `OpportunityActionPermissionService.assertDealActionAccess()` is a custom-permission check with no
  object context. Unchanged.

🔴 **This also closes a live latent defect.** Today, clicking Submit for Approval on an Underwriting
record whose *parent* sits at `StageName = 'LOI'` submits the deal into **`LOI_Approval`** — the
Underwriting page's visibility rule keys on the child's `Stage__c`, never on the parent's stage.
After this change that is unreachable by construction. Record it in the header.

### D-3. `OpportunityApprovalService.cls` — the ineligible-target messages (open item **(b)**, RESOLVED)

**The current behaviour after retirement, traced:** an Opportunity at `StageName = 'Underwriting'`
resolves to itself → pending check passes → `Approval.process` throws `NO_APPLICABLE_PROCESS`
(`LOI_Approval`'s entry is `StageName = 'LOI'`, so **there is no wrong-process risk — the two entry
criteria are mutually exclusive on `StageName`**) → the catch's guard
`deal.StageName != STAGE_UNDERWRITING && != STAGE_LOI` is **FALSE**, so it falls through to
`throw e` → the controller masks it with
*"The deal could not be submitted for approval. Refresh the page or contact your administrator."*

That is user-safe but useless, and it is the exact confusion this whole change exists to remove.

**Change:**
1. Drop `'Underwriting'` from the Opportunity-target eligible set (leave only `'LOI'`).
2. Add a dedicated, user-safe `ApprovalException` for the Underwriting stage:
   *"Underwriting approval now runs on the Underwriting record. Open this deal's Underwriting record
   and use Submit for Approval there."*
3. Repoint the generic ineligible-stage message to name only the LOI gate.
4. Add the mirror guard for an **`Underwriting__c` target** whose `Stage__c != 'In Progress'`:
   *"An underwriting is submitted for principal approval from the In Progress stage."*
   (Derive it in the catch from the already-loaded record — do **not** add a pre-check query.)
5. Retract the header's *"The approval processes live on the Opportunity"* paragraph in place.

**Class name stays `OpportunityApprovalService`.** Renaming an Apex class is delete-and-create, it
still owns `LOI_Approval` on the Opportunity, and the repo's 40-char class-name ceiling makes any
rename a fresh risk for zero benefit.

### D-4. `ApprovalAuditService.cls` — new `UnderwritingChild` gate (fixes C-3, performs the mirror write)

Add a third gate alongside `Underwriting` and `LOI`. For `gate == 'UnderwritingChild'` the
`recordId` is an **`Underwriting__c` Id**:

1. Read the newest approved `ProcessInstanceStep` whose `ProcessInstance.TargetObjectId` is the
   **Underwriting record** — the existing `ProcessInstanceStepSelector.AuditReads`
   (`without sharing` + `SYSTEM_MODE`) already does exactly this and takes a `Set<Id>`. No selector
   change needed.
2. Resolve the parent Opportunity via `UnderwritingSelector` (existing method
   `selectOpportunityIdRequiredById`, already used by `resolveApprovalTargetId`). No inline SOQL.
3. Build **ONE** `Opportunity` shell per deal carrying **all four** fields and commit them in the
   **existing single** `Database.update(oppUpdates, true, AccessLevel.SYSTEM_MODE)`:

   | Field | Value | Why |
   |---|---|---|
   | `UW_Approved__c` | `true` | D4 — mirror must keep working |
   | `Underwriting_Status__c` | `'Approved by Principals'` | 🔴 **THE FREEZE TRIGGER** |
   | `UW_Approved_By__c` | `step.ActorId` | fixes C-3 |
   | `UW_Approval_Date__c` | `step.CreatedDate` | fixes C-3 |

   🔴 **One DML for all four is load-bearing.** `Opportunity_UW_Approved_Notify` has
   `doesRequireRecordChangedToMeetCriteria = true`. Splitting the write means a *second* save on
   which `Underwriting_Status__c` is already `'Approved by Principals'` — no transition, and every
   subsequent audit field arrives on a save the freeze cannot see.
4. **DELETE the existing `Underwriting__c` write block (lines 72-83).** `Stage__c = 'Approved'` and
   `Status__c = 'Approved by Principals'` are now the approval's own field updates. Leaving it in
   causes a redundant same-value DML that re-fires `Underwriting_Opp_Sync`, and it is dead code
   after retirement anyway (no Opportunity `ProcessInstanceStep` will ever be found).
5. Keep the wide `catch (Exception e)` and its comment **verbatim** — that catch exists because a
   `TypeException` from a read-only approver escaped a `DmlException`-only handler and rolled back a
   real approval on 2026-08-05. Narrowing it reopens that hole.
6. Update the class header's Gates list.

**`flows/Opportunity_UW_Approved_Notify` is left STRUCTURALLY UNTOUCHED.** After this change its
`Stamp_Approval_Audit` action becomes a permanent no-op (no Opportunity approval history will ever
exist). It is *deliberately* not removed: that flow carries the market-data freeze, edits to it are
the highest-risk change in this pack, and a no-op invocable costs one query. Document the now-dead
call in `ApprovalAuditService`'s header and in the flow's `<description>` instead.

**The chain, end to end, after the change:**

```
Principal approves the Underwriting record
  → finalApprovalActions: Stage__c='Approved', Status__c='Approved by Principals'
                          [+ Approval_Status__c='Approved' under A1]
  → flows/Underwriting_Approval_Sync (after-save, entry-scoped, SystemModeWithoutSharing)
      → ApprovalAuditService(gate='UnderwritingChild')
          → ONE Opportunity update: UW_Approved__c, Underwriting_Status__c,
            UW_Approved_By__c, UW_Approval_Date__c   [SYSTEM_MODE, without sharing]
              → flows/Opportunity_UW_Approved_Notify fires on the TRANSITION
                  → Stamp_Approval_Audit  (no-op)
                  → Snapshot_Market_Data  ✅ THE FREEZE STILL FIRES
  (separately, unchanged) flows/Underwriting_Opp_Sync pushes the four numbers up

Deal driver clicks Initiate LOI
  → StageAdvanceService.advance() → NEXT_STAGE['Underwriting'] = 'LOI' → update
      → Underwriting_Approved_Before_LOI evaluates Primary_Underwriting__r.Stage__c
        ∈ {Approved, Completed} → PASSES
      → OpportunityReviewService.createReviewRecords auto-creates the LOI__c child (unchanged)
```

### D-5. `TestDataFactory.approveUnderwriting` — repoint to the field the gate now reads

The helper currently writes **only** `Opportunity.UW_Approved__c` (`:1031-1040`), which the rewritten
VR no longer reads. Repoint it to set the deal's **primary Underwriting record** to
`Stage__c = 'Approved'`, re-reading `Primary_Underwriting__c` after insert (the trigger stamps it
after the insert returns — same shape `signPrimaryNda` already uses at `:961-1007`).

- Keep it **one DML per object, no SOQL/DML in a loop** (its documented contract; the 251-record bulk
  tests call it).
- Keep writing `UW_Approved__c` as well, so the mirror stays truthful under D4 and any test asserting
  it keeps passing.
- Keep the docstring's existing philosophy — it satisfies the **gate**, and deliberately does not
  fake `UW_Approved_By__c` / `UW_Approval_Date__c`, which only real approval history should produce.
- **Only two callers** (`StageApprovalGatesTest:76`, `NdaDealProgressionGateTest:36`) — verified by
  exact-token sweep across the repo. The blast radius is genuinely small.

### D-6. `lwc/submitForApproval` — confirm wording

`CONFIRM.message` reads *"Submit this deal for principal approval?"*. On the Underwriting record it
now submits the **underwriting**, not the deal. Change to a neutral string that reads correctly on all
four surfaces (Opportunity, LOI, Contract Review, Underwriting) — the same move
`advanceDealStage.js` made on 2026-08-27 and for the same reason. Update
`__tests__/submitForApproval.test.js` accordingly. Keep `theme: 'warning'` and the header comment
explaining why it is not `'info'`.

### D-7. Header retraction in `lwc/advanceDealStage/advanceDealStage.js`

The block *"⚠ AND THE MESSAGE SAID SOMETHING FALSE … on the Underwriting hop … `advance` does NOT
write a stage at all"* becomes false. The wording *"Move this deal to its next step?"* stays correct
(now literally a stage change on all five actions), but its **justification** must be retracted in
place. No behaviour change; no Jest change.

---

## 6. WHAT IS EXPLICITLY **NOT** CHANGING

Named so a downstream agent does not "tidy" them:

- `Opportunity.LOI_Approval` and its two field updates. Untouched.
- `LOI__c.Submit_for_Approval` on `LOI_Record_Page` (all five criteria) and in the LOI layout's
  `platformActionList`. Untouched.
- `flows/Underwriting_Opp_Sync`. Untouched — including its description.
- `flows/Opportunity_UW_Approved_Notify` structure and `MarketDataSnapshotService`. Untouched.
- `RecordStageAdvanceService.UNDERWRITING_NEXT_STAGE` and
  `NO_NEXT_STEP_HINTS['Underwriting|In Progress']`. Correct as-is (header comment only).
- `Underwriting__c.Move_to_In_Progress` / `Move_to_Completed` quick actions and their
  `Underwriting_Record_Page` visibility rules. Untouched.
- `Opportunity.Initiate_Underwriting`, `flows/Opportunity_Initiate_Underwriting`, and
  `No_Backward_Stage_Movement`'s CARVE-OUT 2. Untouched.
- `Opportunity.UW_Approved__c`, `Underwriting_Status__c`, `Underwriting_Complete__c` field metadata,
  FLS and report/dashboard references. **Retained per D4.** Only their field *descriptions* should be
  refreshed to name the new writer.
- The seed scripts (§C-5).
- `pathAssistants/Underwriting_Path`. Its `Approved` step's `info` text
  (*"check Underwriting Complete on the deal and submit for principal approval (12B)"*) is now
  slightly stale but describes a step the user still performs from the same page. **Flagged, not
  changed** — outside the five agreed pieces.

---

## 7. TEST PLAN

`.claude/rules/bulk-test-rule.md` — the 251-record mandate. `submitForApproval` and `advance()` are
per-transaction singletons (one quick-action click) and carry the existing documented exemption. The
new record-triggered flow **is** a bulk path, but 251 Underwriting records each carrying a distinct
pending approval is not reachable in production and the underlying `ApprovalAuditService` is already
collection-based with no SOQL/DML in a loop. **Record that reasoning in the test class header** (the
rule requires the exemption to be argued in place) and prove bulk-safety with a modest multi-record
test (5 records, one transaction, assert the query/DML counters), not with 251.

### Classes that MUST be rewritten

| Class | What breaks | Required change |
|---|---|---|
| `UnderwritingGateTest` | All three approval tests submit the **Opportunity** | Submit the **Underwriting record**. `principalApprovalAdvancesToLoi`: **delete** the `StageName == 'LOI'` assertion (approval no longer advances the deal) and keep/extend the mirror + audit assertions. `principalRejectionSendsBackForRevision`: assert against the A1/A2 outcome chosen at GATE A. `underwritingStageSubmitsWithoutCompleteFlag`: assert the pending `ProcessInstance` targets the **Underwriting** Id. |
| `OpportunityApprovalServiceTest` | `submitsFromUnderwritingRecordResolvesParent` asserts the OPPOSITE of the new behaviour | **Invert and rename** — `submitsFromUnderwritingRecordTargetsTheUnderwritingItself`. Assert `ProcessInstance.TargetObjectId == uw.Id` and that **no** Opportunity instance exists. Also repoint `ineligibleStageThrowsApprovalException` (eligible set is now `{LOI}` for an Opportunity target). |
| `OpportunityApprovalControllerTest` | Same shape via the controller | Mirror the above. |
| `StageAdvanceServiceTest` / `StageAdvanceControllerTest` | The Underwriting branch asserts an approval submission (`:108`, `:128` / `:69`, `:301`) | Flip to asserting a **stage write to `'LOI'`**, with the underwriting pre-approved via the repointed `TestDataFactory.approveUnderwriting`. |
| `StageApprovalGatesTest.underwritingApprovedGate_blocksLoiEntryUntilApproved` | Depends on `approveUnderwriting` | Works unchanged **if** D-5 is done correctly. Add the C-2 assertion below. |
| `NdaDealProgressionGateTest:36` | Same | Same. |

### New tests required

| # | Test | Proves |
|---|---|---|
| T1 | 🔴 `loiReentryIsAllowedWhenUnderwritingIsCompleted` — UW at `'Completed'`, `StageName` `Underwriting → LOI` must **succeed** | **The C-2 defect.** With the three-clause formula this test REDS. It is the permanent falsifier and the single highest-value test in this pack. |
| T2 | `loiEntryIsRefusedWhenUnderwritingIsNotApproved` — UW at `'In Progress'` → blocked, and the **message** matches the new `errorMessage` | The gate itself, message included (asserting only "blocked" would pass against the wrong rule). |
| T3 | `loiEntryIsRefusedWhenPrimaryUnderwritingIsBlank` | The deliberate **fail-closed** blank case (§C-2) — and that it produces exactly ONE message. |
| T4 | `approvalStampsAllFourMirrorFieldsInOneSave` — approve the UW record, assert `UW_Approved__c`, `Underwriting_Status__c`, `UW_Approved_By__c == UserInfo.getUserId()`, `UW_Approval_Date__c != null` | The whole D-4 chain, **and C-3's fix** (the audit stamp). |
| T5 | `submittingFromTheOpportunityAtUnderwritingNamesTheRealRoute` — assert the **new user-safe message**, and that **no** `ProcessInstance` was created | Open item **(b)**. Asserting only "it threw" would pass against the generic mask this change exists to remove. |
| T6 | `aSecondSubmissionWhilePendingIsRefused` on the Underwriting record | The duplicate-pending gate now guards the right target. |
| T7 | `theUnderwritingRecordIsLockedWhilePending` — attempt an update, expect refusal | **D3**, the deliberate lock inversion. |
| T8 | *(A1)* `rejectionClearsUnderwritingCompleteOnTheParent` and `theOrdinaryRequestedToInProgressHopDoesNot` | That the reject mechanism is scoped to a real rejection and not to the forward hop. |

⚠ `MarketDataSnapshotServiceTest` calls `snapshotMarketData` **directly** and never drives an approval
— so it is **insulated** from this change and will keep passing. That is convenient and also means
**the Apex suite does NOT prove the freeze end-to-end.** The end-to-end proof is post-deploy check
P-4 below, and it must not be skipped on the strength of a green suite.

### Jest

- `lwc/submitForApproval/__tests__/submitForApproval.test.js` — update for the D-6 wording.
- `lwc/advanceDealStage/__tests__/advanceDealStage.test.js` — no change (D-7 is comment-only).
- ⚠ Jest is local-only and never deploys. It cannot see any of the above.

---

## 8. POST-DEPLOY VERIFICATION CHECKLIST

🔴 **Read state back from the org. Do not read deploy counters.** This org has reported
`"689/689 deployed, 0 errors"` on a deploy that rolled everything back, and a green dry-run can mean
byte-identical components were reported `Unchanged` and never validated.

### Server-side reads (all must pass before any UI testing)

| # | Check |
|---|---|
| S-1 | `SELECT COUNT() FROM ProcessInstance WHERE ProcessDefinition.DeveloperName='Underwriting_Approval' AND Status='Pending'` → **0** *(step 1)* |
| S-2 | Tooling: retrieve `ApprovalProcess:Opportunity.Underwriting_Approval` and confirm `<active>false</active>`; retrieve `ApprovalProcess:Underwriting__c.Underwriting_Approval` and confirm `<active>true</active>` |
| S-3 | Tooling: `SELECT Metadata FROM ValidationRule WHERE ValidationName='Underwriting_Approved_Before_LOI'` — confirm the formula contains **both** `'Approved'` **and** `'Completed'`, and that `Primary_Underwriting__r` appears |
| S-4 | `SELECT Body FROM ApexClass WHERE Name='StageAdvanceService'` — confirm `'Underwriting' => 'LOI'` is present and the `OpportunityApprovalService.submitForApproval` branch is gone |
| S-5 | `SELECT ApiName, ActiveVersionId FROM FlowDefinitionView WHERE ApiName='Underwriting_Approval_Sync'` → active; and `Opportunity_UW_Approved_Notify` still active |
| S-6 | `sf apex run test --test-level RunLocalTests` — green, and check `ApexTestResult` timestamps to distinguish "I broke it" from a concurrent-session change |
| S-7 | Diff every hub file touched (`Underwriting_Record_Page`, the two layouts, the permission sets) against the ORG copy **immediately before** deploying — a second session shares this working tree |

### 🔴 NEGATIVE TESTS — these are the ones that actually prove the feature

| # | Scenario | Required outcome |
|---|---|---|
| **N-1** | Deal at `Underwriting`; its Underwriting record at `In Progress`. Click **Initiate LOI**. | 🔴 **REFUSED.** Toast shows the VR's `errorMessage` verbatim (not a generic "could not be advanced"). `StageName` still reads `Underwriting`. |
| **N-2** | Deal whose `Primary_Underwriting__c` is blank. Click **Initiate LOI**. | 🔴 **REFUSED** (fail-closed). Exactly **one** error message. |
| **N-3** | Submit an Underwriting record, then click **Submit for Approval** on it again while pending. | REFUSED: *"already pending approval."* Exactly one `ProcessInstance`. |
| **N-4** | While pending, edit `My_Price__c` on the Underwriting record as the analyst. | 🔴 **REFUSED** (record locked). **This is D3's whole purpose** — it is the fix, not a side effect. |
| **N-5** | While pending, edit `Amount` / `Asking_Price__c` on the **Opportunity**. | **ALLOWED.** The Opportunity is no longer locked. Confirms the lock moved rather than doubled. |
| **N-6** | Invoke Submit for Approval from the **Opportunity** at `StageName = 'Underwriting'`. | User-safe message naming the Underwriting record. **NOT** the generic mask, **NOT** a raw platform error, and **NO** `ProcessInstance` created — in particular it must not land in `LOI_Approval`. |
| **N-7** | Reject the underwriting; then click **Initiate LOI**. | REFUSED (the UW is not Approved). Under A1, `Opportunity.Underwriting_Complete__c` is now `false`. |
| **N-8** | 🔴 **The C-2 case.** Approve → Initiate LOI → walk the UW to `Completed` → submit and **reject** `LOI_Approval` (deal returns to `Underwriting`) → click **Initiate LOI** again. | 🔴 **MUST SUCCEED.** If this is refused, the three-clause formula shipped and every LOI-rejected deal in the org is permanently stranded. |

### Positive / freeze verification

| # | Scenario | Required outcome |
|---|---|---|
| **P-1** | Re-submit the deal recalled in step 1, from its **Underwriting record**. | One `ProcessInstance` whose `TargetObjectId` is the **Underwriting** Id. Approval History renders on the Underwriting page with a **Recall** button (proves C-4's two-file fix). |
| **P-2** | Approve as one principal. | The other principal's work item is **withdrawn** (`FirstResponse`, D1 preserved): `SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :uwId` → **0**. |
| **P-3** | Read the Underwriting record. | `Stage__c = 'Approved'`, `Status__c = 'Approved by Principals'`, the Path shows **Approved**, and **Move to Completed** renders. |
| **P-4** | 🔴 **THE MARKET-DATA FREEZE.** Read the Opportunity. | `UW_Approved__c = true`; `Underwriting_Status__c = 'Approved by Principals'`; `UW_Approved_By__c` = **the principal who approved** (not the submitter, not `null`); `UW_Approval_Date__c` populated; **`Market_Data_As_Of_Date__c = TODAY`**; **`Market_Data_Snapshot__c` is non-blank AND does NOT start with `'Market data snapshot failed:'`**. Query it, do not eyeball it: <br>`SELECT Id, Market_Data_As_Of_Date__c, Market_Data_Snapshot__c FROM Opportunity WHERE Id = :oppId` |
| **P-5** | Click **Initiate LOI**. | `StageName = 'LOI'`, and `OpportunityReviewService` has auto-created the `LOI__c` child with `Primary_LOI__c` stamped. |
| **P-6** | Confirm `Underwriting_Opp_Sync` still works: edit `My_Cap_Rate__c` on the UW record post-approval. | The number mirrors onto the Opportunity, and **no second freeze fires** (`Underwriting_Status__c` does not re-transition). |

---

## 9. RISK REGISTER

| # | Risk | Mitigation |
|---|---|---|
| R1 | 🔴 The three-clause formula ships and strands every LOI-rejected deal | Test **T1**, check **N-8**. Both must be run. |
| R2 | 🔴 The mirror write silently does nothing (approver is read-only on Opportunity) | Route through `ApprovalAuditService`'s proven `AccessLevel.SYSTEM_MODE` + `without sharing`, **not** a flow `recordUpdate` relying on `runInMode` — the repo has a measured counter-example. Verify with **P-4**, which reads the field back rather than trusting a success toast. |
| R3 | 🔴 The audit stamp dies silently (C-3) | Fixed in D-4; proven by **T4** and **P-4**'s `UW_Approved_By__c` assertion. |
| R4 | 🔴 The Underwriting approval is unrecallable (C-4) | Both halves of A-4 must ship; proven by **P-1**. |
| R5 | The FlexiPage deploy clobbers unrecorded App Builder edits | `--target-metadata-dir` retrieve + diff seconds before deploying; check `SetupAuditTrail`. Never toggle `enableActionsConfiguration`. |
| R6 | Attempting to DELETE the old approval process fails (it has history) | Deactivate only (A-7); leave the four `UW_*` field updates in place. |
| R7 | `Underwriting__c.Stage__c` is directly editable (`DPEG_Acquisition_Edit:1636`), so a user with edit FLS could set `'Approved'` and bypass the approval | **No net change** — today the same set grants edit on `Opportunity.UW_Approved__c` (`:1231`), the exact field today's gate reads. The bypass surface **moves, it does not widen.** Under **A1** it actually **narrows**, because the mirror stamp and the freeze key on `Approval_Status__c`, which only the approval process writes. Recorded as a residual, **not** fixed here (out of scope). |
| R8 | The principals cannot see `Underwriting__c` | **V1**. Blocking; org-side only. |
| R9 | A concurrent session edits the same hub files | **S-7**; commit retrieves alone. |
| R10 | Approvers lose `Asking_Price__c` / `Underwriting_Notes__c` on the approval page | **GATE B** — user decision, not an invention. |

---

## 10. OPEN NAMING ITEMS (flagged, not invented)

The implementing agents must pick ONE spelling each and use it consistently everywhere:

| Item | Suggested |
|---|---|
| New flow | `Underwriting_Approval_Sync` (label "Underwriting Approval Sync") |
| New field *(A1)* | `Underwriting__c.Approval_Status__c` — mirrors `Disposition_Offer__c.Approval_Status__c` exactly |
| New field updates *(A1)* | `Set_UW_Approval_Approved` / `Set_UW_Approval_Rejected` — mirrors `Set_Offer_Approval_*` |
| Own-record field updates on the new approval | `UW_Stage_Approved`, `UW_Status_Approved` |
| New approval process | `Underwriting__c.Underwriting_Approval` (label "Underwriting Approval", step label **"Principal approves underwriting"** — the disposition wave renamed every step off the shared "Principal Review" precisely because approvers could not tell the requests apart) |
| `ApprovalAuditService` gate value | `'UnderwritingChild'` |
| Renamed private method | `resolveApprovalTargetId` |

---

## 11. MCP / RULES COMPLIANCE

`.claude/rules/salesforce-global-rule.md` mandates a `salesforce-api-context` MCP attempt for every
metadata type. **`mcp=unavailable`, `mcp_tools=none`** — this agent has no MCP tools, and `.mcp.json`
configures only the `salesforce` server. Downstream admin/dev agents must record the same status and
fall back to the per-type skill, per the rule's own fallback clause.

Unproven XML shapes escalated as gates rather than guessed: `initialSubmissionActions` and
`recallActions` (absent from every file in `approvalProcesses/**`) — **neither is used by this design.**
Every element specified above is copied from a deployed file in this repo:
`Disposition_Offer__c.Offer_Selection_Approval` (approval on a Lookup child),
`Disposition__c-Disposition Layout` + `Disposition_Record_Page` (the two-file Approval History),
`Underwriting_Opp_Sync` (a `SystemModeWithoutSharing` after-save flow on `Underwriting__c` writing its
parent Opportunity), and `workflows/Disposition_Offer__c.workflow-meta.xml`.
