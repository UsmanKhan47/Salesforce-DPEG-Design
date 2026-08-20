# DESIGN REQUIREMENTS — Disposition Flow Redesign (On-Market / Off-Market Stage Overhaul)

**Source of truth:** `C:\Users\usman.khan\.claude\plans\now-we-have-a-linear-phoenix.md` (approved plan, user-confirmed).
**Status:** Design already confirmed at Gate 1. This document is the *transcription* of that plan into
admin / development work items for the downstream specialist agents. **It adds no scope.** Where the
plan is silent on a name, this document says so explicitly rather than inventing one.

**Branch:** `feature/disposition-redesign` (new branch, per user-confirmed decision 4).
**API version:** 67.0 (`sfdx-project.json` → `sourceApiVersion`).
**Package directory:** `force-app/main/default`.

---

## 1. REQUIREMENT SUMMARY AND SCOPE

### 1.1 What is being built

The client has redefined the disposition flow. The module today runs a 10-value
`Disposition__c.Disposition_Stage__c` picklist across two record types (`On_Market`, `Off_Market`),
an Initiate button that creates a Disposition directly with no popup and no approval, three approval
processes carrying **no** `finalApprovalActions` (stage moves are manual via Path), and stage-routed
LWCs.

The redesign:

| New On-Market sequence (11 stages) | New Off-Market sequence (9 stages) |
|---|---|
| Disposition Readiness | Disposition Readiness |
| BOV Outreach | — |
| Broker Selection | Broker Selection |
| NDA | NDA |
| Release Materials | Release Materials |
| Active Listing | — |
| Offer Selection | Offer Selection |
| LOI | LOI |
| PSA | PSA |
| Closing | Closing |
| Sale Closes | Sale Closes |

**Stage surgery:** ADD `Broker Selection`, `Release Materials`, `Offer Selection`, `Sale Closes`.
REMOVE `Call for Offers`, `Disposition Offer`, `Completed`. Migrate existing org rows off the three
removed values between the two deploys.

NDA moves into the On-Market path (the "NDA is off-market only" doctrine recorded in the record-type
XML comments, `dispositionSidebar.js` and `All_NDAs_Signed_Before_Progression` is dead and must be
rewritten wherever it is asserted).

### 1.2 Transition ownership map (drives every work item below)

| Transition | Owner |
|---|---|
| Readiness → BOV Outreach (On) / Broker Selection (Off) | `Sale_Decision_Approval` final approval (record-type-dependent target) |
| BOV Outreach → Broker Selection (On) | new `BOV_Submission__c.Broker_Finalize_Approval` |
| Broker Selection → NDA (On) | manual quick action |
| Broker Selection → NDA (Off) | adapted `Broker_Selection_Approval` |
| NDA → Release Materials (both) | manual quick action, gated by the all-NDAs-signed VR |
| Release Materials → Active Listing (On) | manual quick action |
| Active Listing (On) / Release Materials (Off) → Offer Selection | offer-selection **submission** (explicit service DML) |
| Offer Selection → LOI | new `Disposition_Offer__c.Offer_Selection_Approval` |
| LOI → PSA | manual quick action |
| PSA → Closing | existing `ContractExecutionService` — **unchanged** |
| Closing → Sale Closes | `Closing_Approval` final approval; wire VR backstop |

### 1.3 Load-bearing design decisions carried from the plan

- **D-1 — approval auto-advance is a SEMAPHORE, not a direct stage FieldUpdate.**
  A final-approval FieldUpdate writes only `Disposition__c.Approval_Advance_Pending__c` (for
  Disposition-target approvals) or `Approval_Status__c` on the child (BOV / Offer approvals). A
  direct stage FieldUpdate is **forbidden** — it bypasses validation rules, which is the reasoning
  already recorded in the existing approval XMLs and in
  `Wire_Complete_Before_Completed`'s comment. An approval-triggered flow is also **rejected** — it
  runs as the approver (known org incident, see memory `flow-runinmode-runs-as-approver`).
  The semaphore re-fires `DispositionTrigger`; the after-update handler detects false→true and
  enqueues a Queueable that writes the stage with ordinary
  `Database.update(..., AccessLevel.SYSTEM_MODE)` — validation rules still evaluate, approver CRUD
  is irrelevant, and the `recordEditability = AdminOnly` lock has definitively released by the time
  the job runs. Child-object approvals (BOV / Offer) update the **parent synchronously** in their
  own trigger — the parent is not the locked record — with `allOrNone = false` and SYSTEM_MODE, the
  same shape as `ContractExecutionService`.
- **D-2 — stage-advance framework.** Register `Disposition__c` in
  `RecordStageAdvanceService.CONFIG_BY_TYPE`. `StageConfig.byRecordType` already supports
  per-record-type sequences natively; `defaultTypeKey = 'On_Market'`. The maps hold **only manual
  hops**, so the Advance button structurally cannot skip an approval- or machine-owned hop.
  Gate: the existing `Disposition_Deal_Actions` custom permission (`DISPOSITION_DRIVER`).
- **D-3 — offer selection is two steps.** Selecting an offer advances
  Active Listing / Release Materials → **Offer Selection** by explicit service DML (with savepoint)
  *and* submits the offer for approval. The approval then advances Offer Selection → LOI. The stage
  always tells the truth; a rejected offer parks at Offer Selection for a re-pick.
- **D-4 — new formula field `Disposition__c.Is_On_Market__c`** (`RecordType.DeveloperName = 'On_Market'`)
  exists solely so flexipage visibility rules can test the record type. Never `{!$User...}`;
  spanning `{!Record.RecordType...}` in a FlexiPage rule is unverified and is not to be used.
- **D-5 — new `c/dispositionCallForOffers` card.** The existing `callForOffersList` /
  `callForOffersPanel` bundles are Opportunity-scoped — **do not touch them**.

### 1.4 Explicitly out of scope

- `ContractExecutionService` (PSA → Closing) — no functional change.
- `DispositionStageEntryService` — no functional change (comment rewrite only).
- `DispositionService.findOrCreate` — untouched.
- `callForOffersList` / `callForOffersPanel` — untouched (Opportunity-scoped).
- Any new custom permission — `Disposition_Deal_Actions` already exists and is reused.

### 1.5 Risk register (carried verbatim from the plan; every agent must read it)

1. Stage values are governed in lockstep across ~15 artifacts: the field, 2 record types, 3 path
   assistants, the LWC routers, the flexipage visibility rules, the services, 2 validation rules,
   the approvals, the object translations, `TestDataFactory`, and the seed / query scripts.
2. **New fields have NO FLS until the permission-set deploy lands.** A visibility rule reading a
   field the user cannot see fails **silently** and hides every gated action
   (memory: `metadata-field-fls-gotcha`).
3. **PermissionSet deploys REPLACE the whole `fieldPermissions` set** — diff against HEAD first
   (memory: `content-publication-and-permset-replace`).
4. **FlexiPage deploys can roll back and still report success** — read the page back in-org
   (memory: `flexipage-template-pattern`).
5. **`sf project retrieve` UNIONS picklist values** — it will silently restore locally-deleted values
   (memory: `retrieve-merges-picklist-values`).
6. **Recall any pending Disposition approvals before deploy 1** — `Broker_Selection_Approval`'s entry
   criteria change under them.
7. Transition window (deploy 1 → migration): rows still on the old stages briefly lose sidebar
   offer-card routing. **Accepted.**
8. A queueable-budget-exhausted advance skip leaves the semaphore `true` — documented,
   admin-visible, recoverable.
9. **Shared working tree** — a second session may be building into this repo concurrently. Diff hub
   files (permission sets, flexipages) against HEAD before deploying
   (memory: `commit-retrieves-before-editing`).

---

## 2. ADMIN / DECLARATIVE WORK ITEMS

**Routing:** this is complex multi-object declarative work (5 approval processes across 3 objects,
record-type union surgery, 9 quick actions with Dynamic Actions, security model changes) →
`salesforce-solution-architect`.

### PHASE 0 — Pre-removal sweep (no files written)

**A-0.** Before any file is touched:
- `git checkout -b feature/disposition-redesign`.
- Diff the hub files against HEAD: `permissionsets/DPEG_Disposition_View.permissionset-meta.xml`,
  `permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml`,
  `flexipages/Disposition_Record_Page.flexipage-meta.xml`.
- Org query to size the migration:
  `SELECT RecordType.DeveloperName, Disposition_Stage__c, COUNT(Id) FROM Disposition__c GROUP BY RecordType.DeveloperName, Disposition_Stage__c`
- Recall any pending `Disposition__c` approvals (risk 6).
- Known repo hit-list for the three doomed values (already grepped, confirmed):
  `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml`;
  both record types; `pathAssistants/Disposition_Path_On_Market`,
  `Disposition_Path_Off_Market`, and legacy inactive `Disposition_Path`;
  `validationRules/All_NDAs_Signed_Before_Progression`, `validationRules/Wire_Complete_Before_Completed`;
  `lwc/dispositionMain` (js + `__tests__`), `lwc/dispositionSidebar` (js + `__tests__`);
  `flexipages/Disposition_Record_Page.flexipage-meta.xml` (lines 292 and 333);
  `objectTranslations/Disposition__c-en_US/Disposition_Stage__c.fieldTranslation-meta.xml`;
  `classes/TestDataFactory.cls`; `scripts/seed-disposition.apex`, `scripts/seed-disp0002.apex`,
  `scripts/query-dispositions.apex`, `scripts/verify-disposition-reports.apex`.

---

### PHASE 1 — Additive schema (DEPLOY 1)

**A-1. Picklist — add 4 values, keep the 3 doomed values.**
`force-app/main/default/objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml`
Add: `Broker Selection`, `Release Materials`, `Offer Selection`, `Sale Closes`.
Do **not** remove `Call for Offers`, `Disposition Offer`, `Completed` in this deploy — they are
removed in Deploy 2, after the migration.

**A-2. Record types — transition-window UNION.**
`objects/Disposition__c/recordTypes/On_Market.recordType-meta.xml`
`objects/Disposition__c/recordTypes/Off_Market.recordType-meta.xml`
Each type's `Disposition_Stage__c` `picklistValues` block must list **old values ∪ new values** for
the transition window. Both files must continue to enumerate `Sell_Decision_Trigger__c` in full
(a record type file that omits a picklist silently drops its values from that type).
**Rewrite the in-XML design comments in both files** — the "NDA and Disposition Offer are
off-market stage values ONLY … Do not 'helpfully' add them here" doctrine in `On_Market` and the
matching "no NDA on-market" narrative in `Off_Market` are now FALSE. Keep the comment **inside** the
root element and keep `<description>` under 255 characters (memory: `xml-comment-must-be-inside-root`).

**A-3. New fields (5).**

| # | File | Type | Notes |
|---|---|---|---|
| A-3a | `objects/Disposition__c/fields/Approval_Advance_Pending__c.field-meta.xml` | Checkbox | The D-1 semaphore. System-written only. **No FLS for anyone** — deliberately absent from both permission sets. |
| A-3b | `objects/Disposition__c/fields/Is_On_Market__c.field-meta.xml` | Formula (Checkbox) | `RecordType.DeveloperName = 'On_Market'`. Exists for flexipage visibility rules (D-4). Needs **read FLS**. |
| A-3c | `objects/BOV_Submission__c/fields/Approval_Status__c.field-meta.xml` | Picklist | Values `Approved`, `Rejected`. Blank = unsubmitted. |
| A-3d | `objects/Disposition_Offer__c/fields/Is_Selected__c.field-meta.xml` | Checkbox | Entry criterion for `Offer_Selection_Approval`. |
| A-3e | `objects/Disposition_Offer__c/fields/Approval_Status__c.field-meta.xml` | Picklist | Values `Approved`, `Rejected`. Blank = unsubmitted. |

⚠ `BOV_Submission__c` and `Disposition_Offer__c` **already carry a status-like picklist each**
(`Submission_Status__c`, `Offer_Status__c`). `Approval_Status__c` is a *second, distinct* field on
each — do not conflate them (memory: `verify-something-writes-the-trigger-value`).

**A-4. Permission sets — read on the new visible fields.**
`permissionsets/DPEG_Disposition_View.permissionset-meta.xml`
`permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml`
- Add read on `Disposition__c.Is_On_Market__c`, `BOV_Submission__c.Approval_Status__c`,
  `Disposition_Offer__c.Is_Selected__c`, `Disposition_Offer__c.Approval_Status__c`.
- **Verify** `Disposition__c.Wire_Verification_Completed__c` read is present — the
  `Submit_Closing_Approval` visibility rule reads it, and a visibility rule on an unreadable field
  fails silently.
- **`Approval_Advance_Pending__c` gets NO entry in either set** (A-3a).
- ⚠ A PermissionSet deploy replaces `fieldPermissions` wholesale — **diff against HEAD before
  writing** (risk 3, risk 9).

**A-5. New workflow field updates (3 files, all new — no `Disposition__c`, `BOV_Submission__c` or
`Disposition_Offer__c` workflow file exists in the repo today).**

| File | FieldUpdates |
|---|---|
| `workflows/Disposition__c.workflow-meta.xml` (new) | `Set_Approval_Advance_Pending` → `Approval_Advance_Pending__c = true` |
| `workflows/BOV_Submission__c.workflow-meta.xml` (new) | `Set_BOV_Approval_Approved` / `Set_BOV_Approval_Rejected` → `Approval_Status__c` |
| `workflows/Disposition_Offer__c.workflow-meta.xml` (new) | `Set_Offer_Approval_Approved` / `Set_Offer_Approval_Rejected` → `Approval_Status__c` |

⚠ The plan writes the BOV / Offer update names as the shorthand `Set_*_Approval_Approved/Rejected`.
The names in the table are the transcription of that shorthand; the solution-architect agent may
adjust casing/segments to match repo convention but must then use the same names in A-7 and A-9.

---

### PHASE 3 — Approval processes (DEPLOY 1)

**A-6. `approvalProcesses/Disposition__c.Sale_Decision_Approval.approvalProcess-meta.xml` — MODIFY.**
- Add `finalApprovalActions` → field update `Set_Approval_Advance_Pending`.
- Rewrite `<description>` — the current text ends "No field updates fire on approval or rejection …
  the stage is advanced by a human afterwards", which becomes false with this change.
- Everything else (entry criterion `Disposition_Stage__c = Disposition Readiness`, the two
  principals, `FirstResponse`, `recordEditability = AdminOnly`) is unchanged.

**A-7. `approvalProcesses/BOV_Submission__c.Broker_Finalize_Approval.approvalProcess-meta.xml` — NEW.**
- Entry criteria: `BOV_Submission__c.Submission_Status__c = 'Selected'`.
- Same two principal approvers and `whenMultipleApprovers = FirstResponse` as `Sale_Decision_Approval`.
- `recordEditability = AdminOnly` — this locks the **submission**, not the Disposition, which is
  precisely why the parent update in D-1 can be synchronous.
- `finalApprovalActions` → `Set_BOV_Approval_Approved`; `finalRejectionActions` → `Set_BOV_Approval_Rejected`.
- `approvalPageFields`: BOV-relevant fields (`Broker_Display__c`, `BOV_Amount__c`, `Cap_Rate__c`,
  `Commission_Rate__c`, `Days_To_Market__c`, `Hist_Success_Rate__c`, `Property_Name__c`) — the
  solution-architect agent selects the final list from the object's real fields.

**A-8. `approvalProcesses/Disposition__c.Broker_Selection_Approval.approvalProcess-meta.xml` — ADAPT.**
- Entry criteria → `Disposition_Stage__c = 'Broker Selection'` **AND** record type = Off Market.
- Add `finalApprovalActions` → `Set_Approval_Advance_Pending`.
- Swap `approvalPageFields` to surface `Selected_Broker__c`.
- Rewrite the description / rationale — the existing rationale is dead.
- ⚠ Risk 6: pending instances of this process must be recalled before deploy 1.

**A-9. `approvalProcesses/Disposition_Offer__c.Offer_Selection_Approval.approvalProcess-meta.xml` — NEW.**
- Entry criteria: `Disposition_Offer__c.Is_Selected__c = true`.
- `finalApprovalActions` → `Set_Offer_Approval_Approved`; `finalRejectionActions` → `Set_Offer_Approval_Rejected`.
- `approvalPageFields`: offer fields (`Buyer_Name__c`, `Offer_Amount__c`, `Offer_Date__c`,
  `Earnest_Money_Proposed__c`, `Due_Diligence_Days__c`, `Closing_Period_Days__c`,
  `Offer_Financing_Type__c`) — final list chosen by the solution-architect agent.

**A-10. `approvalProcesses/Disposition__c.Closing_Approval.approvalProcess-meta.xml` — MODIFY.**
- **Add entry criterion `Wire_Verification_Completed__c = true`.** This kills the
  AdminOnly-lock / wire-rollup deadlock.
- Add `finalApprovalActions` → `Set_Approval_Advance_Pending`.
- Rewrite the description. ⚠ **This supersedes the documented design Q4 decision** recorded in
  `Wire_Complete_Before_Completed`'s XML comment ("WHY THIS SHAPE, NOT AN APPROVAL entryCriteria …
  putting the flag in Closing_Approval's entryCriteria would surface an unmet gate as the platform's
  'no applicable approval process was found'"). The new argument must be carried in the rewritten
  description **and** in the VR's comment (see A-16) — the mitigation is `dispositionSubmitForApproval`'s
  authored pre-check message (D-2 / dev item DEV-2), which replaces the platform's unhelpful error.

---

### PHASE 4 — Quick actions + flexipage (DEPLOY 1)

**A-11. Nine new quick actions.** All are `force-app/main/default/quickActions/Disposition__c.<Name>.quickAction-meta.xml`,
`type = LightningWebComponent`, `actionSubtype = Action`, `optionsCreateFeedItem = false` — the
shape of the existing `Transaction__c.Advance_Stage` / `Opportunity.Begin_Review` files.

| # | File (`quickActions/Disposition__c.…`) | `lightningWebComponent` | Screen? |
|---|---|---|---|
| A-11a | `Submit_Sale_Decision` | `dispositionSubmitForApproval` (new) | headless |
| A-11b | `Submit_Selected_Broker` | `dispositionSubmitForApproval` | headless |
| A-11c | `Submit_Broker_Selection` | `dispositionSubmitForApproval` | headless |
| A-11d | `Submit_Closing_Approval` | `dispositionSubmitForApproval` | headless |
| A-11e | `Advance_to_NDA` | `advanceRecordStage` (existing) | headless |
| A-11f | `Advance_to_Release_Materials` | `advanceRecordStage` | headless |
| A-11g | `Advance_to_Active_Listing` | `advanceRecordStage` | headless |
| A-11h | `Advance_to_PSA` | `advanceRecordStage` | headless |
| A-11i | `Select_Offer` | `dispositionOfferSelect` (new) | **ScreenAction** |

**A-12. Flexipage — Dynamic Actions block and its visibility rules.**
`force-app/main/default/flexipages/Disposition_Record_Page.flexipage-meta.xml`
- Add the Dynamic Actions `valueList` property block (copy the property block from the Opportunity
  record page) listing the nine actions from A-11.
- Every action's visibility rule is **AND-ed** with
  `{!$Permission.CustomPermission.Disposition_Deal_Actions} EQUAL true`.
  ⚠ **Three-segment form only.** `{!$Permission.<Name>}` and `{!$CustomPermission.<Name>}` are both
  REJECTED by the Metadata API (measured 2026-08-12; see `RecordStageAdvanceService.StageActionGate`).

| Action | Additional visibility criteria |
|---|---|
| `Submit_Sale_Decision` | `Disposition_Stage__c` = `Disposition Readiness` |
| `Submit_Selected_Broker` | `Disposition_Stage__c` = `BOV Outreach` |
| `Submit_Broker_Selection` | `Disposition_Stage__c` = `Broker Selection` AND `Is_On_Market__c` = false |
| `Submit_Closing_Approval` | `Disposition_Stage__c` = `Closing` AND `Wire_Verification_Completed__c` = true |
| `Advance_to_NDA` | `Disposition_Stage__c` = `Broker Selection` AND `Is_On_Market__c` = true |
| `Advance_to_Release_Materials` | `Disposition_Stage__c` = `NDA` |
| `Advance_to_Active_Listing` | `Disposition_Stage__c` = `Release Materials` AND `Is_On_Market__c` = true |
| `Advance_to_PSA` | `Disposition_Stage__c` = `LOI` |
| `Select_Offer` | (`Active Listing` AND `Is_On_Market__c` = true) OR (`Release Materials` AND `Is_On_Market__c` = false) |

- Also in the same file: change `Completed` → `Sale Closes` in the **two existing visibility rules**
  (currently lines **292** — the `c_dispositionMain` `1 OR 2 OR 3 OR 4` rule — and **333** — the
  `flexipage_fieldSection` "Details" `1 AND 2 AND 3 AND 4` rule).
- ⚠ **Enabling Dynamic Actions in App Builder silently empties a page's inherited action bar**
  (memory: `dynamic-actions-discards-inherited-actions`), and a FlexiPage deploy can roll back while
  reporting success (risk 4). **Read the page back in-org after deploy 1** — this is verification
  step 1 in §4.

---

### PHASE 6 — Validation rules (DEPLOY 2, AFTER the migration)

**A-13. `objects/Disposition__c/validationRules/All_NDAs_Signed_Before_Progression.validationRule-meta.xml` — MODIFY.**
- **Drop the `RecordType.DeveloperName = 'Off_Market'` term** — NDA is now an on-market stage too.
- Gated stages become: `Release Materials`, `Active Listing`, `Offer Selection`, `LOI`, `PSA`,
  `Closing`, `Sale Closes`.
- Keep `ISCHANGED(Disposition_Stage__c)` (not `ISNEW`) and both `BLANKVALUE(...,0)` guards — the XML
  comment explains why each is load-bearing.
- **Rewrite the XML comment.** The "WHY THE RECORD-TYPE TEST IS REQUIRED" and "only Disposition
  Offer and NDA are off-market-only" paragraphs are now false. Follow the file's own convention:
  quote and retract, do not silently delete. Keep `<description>` ≤ 255 characters.

**A-14. Rename-by-recreate the wire gate.**
- NEW: `objects/Disposition__c/validationRules/Wire_Complete_Before_Sale_Closes.validationRule-meta.xml`
  — same shape, `ISPICKVAL(Disposition_Stage__c, 'Sale Closes')`.
- OLD: `Wire_Complete_Before_Completed` goes into `destructiveChangesPost.xml`.
- ⚠ A validation-rule API-name change is a delete + create, not a rename
  (memory: `api-name-rename-is-delete-create`).
- Carry the A-10 supersession note into the new rule's comment: the wire flag is now BOTH an entry
  criterion on `Closing_Approval` AND this backstop.

---

### PHASE 8 — Removal + cleanup (DEPLOY 2 + one manual org step)

**A-15. Trim the picklist and both record types to their final value sets.**
- `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml` — remove `Call for Offers`,
  `Disposition Offer`, `Completed`.
- `On_Market.recordType-meta.xml` — final 11 values.
- `Off_Market.recordType-meta.xml` — final 9 values.

**A-16. Path assistants.**
- `pathAssistants/Disposition_Path_On_Market.pathAssistant-meta.xml` — rebuild to the 11 steps.
- `pathAssistants/Disposition_Path_Off_Market.pathAssistant-meta.xml` — rebuild to the 9 steps.
- `pathAssistants/Disposition_Path.pathAssistant-meta.xml` — legacy inactive path, **delete**
  via `destructiveChangesPost.xml`.

**A-17. Translations.**
`objectTranslations/Disposition__c-en_US/Disposition_Stage__c.fieldTranslation-meta.xml` — add the
4 new value translations, remove the 3 retired ones.

**A-18. MANUAL ORG STEP (post-deploy-2, not a metadata deploy).**
Delete the three retired picklist values in Setup. **A deploy does not delete picklist values.**
Then re-retrieve and confirm repo and org agree — ⚠ `sf project retrieve` **UNIONS** local and
remote values, so a retrieve immediately after will *restore the deleted values locally* and mimic a
failed deploy. Verify via REST describe, not via the retrieved file
(memory: `retrieve-merges-picklist-values`).

**A-19. Sweep org list views and reports** for filters on the three removed values (org op, not repo).

---

## 3. DEVELOPMENT WORK ITEMS

**Routing:** standard Apex service / trigger-handler / selector / LWC work with no external
integration, no LDV and no Named Credentials → `salesforce-developer`. All Apex must obey
`.claude/rules/apex-layering-rule.md` (SOQL only in selectors, no SOQL/DML in domain, thin triggers,
`with sharing` everywhere).

### PHASE 2 — Apex (DEPLOY 1)

**DEV-1. `classes/DispositionService.cls` + `classes/DispositionController.cls` — MODIFY.**
- New `DispositionService.initiateAndSubmit(Id assetId, String recordTypeDevName)`:
  - record-type **allow-list** on `recordTypeDevName` (`On_Market` / `Off_Market` only);
  - keep the existing idempotent-find behaviour and the RED sell-meter-band refusal;
  - create at `Disposition Readiness` with the chosen record type;
  - `Approval.ProcessSubmitRequest` to submit `Sale_Decision_Approval`;
  - pending-duplicate gate (do not resubmit an already-pending record);
  - on submit failure return `{dispositionId, submitted, message}` so the client can toast
    "created but not submitted" **and still navigate**.
- `DispositionController.initiateAndSubmit` — thin `@AuraEnabled` wrapper, `AuraHandledException` at
  the boundary.
- **`DispositionService.findOrCreate` is untouched.**

**DEV-2. `classes/DispositionApprovalService.cls` + `classes/DispositionApprovalController.cls` — NEW.**
Twin of the Opportunity equivalent.
- `submitForApproval(Id dispositionId)` derives the target from **stage + record type**:

  | Stage / RT | Behaviour |
  |---|---|
  | `Disposition Readiness` | resubmit the Disposition (`Sale_Decision_Approval`) |
  | `BOV Outreach` (On) | submit the **Selected** `BOV_Submission__c`; typed error if none is Selected |
  | `Broker Selection` (Off) | validate `Selected_Broker__c` is non-blank, then submit the Disposition |
  | `Closing` | pre-check `Wire_Verification_Completed__c` with an **authored** message, then submit the Disposition |

  Every branch: pending-approval gate + `DispositionActionPermissionService.assertDispositionActionAccess()`.
- `selectOffer(Id dispositionId, Id offerId)` (D-3): assert the current stage is
  `Active Listing` (On) or `Release Materials` (Off); flip `Disposition_Offer__c.Is_Selected__c`
  **exclusively** (clear any other selected offer); advance the Disposition to `Offer Selection` via
  ordinary DML; submit the offer for approval; **savepoint rollback if the submit fails**.
- **Apex dependencies:** `DispositionActionPermissionService` (existing —
  `hasDispositionActionAccess()` / `assertDispositionActionAccess()`), `DispositionSelector`,
  `BovSubmissionSelector` (new method, DEV-8), `DispositionOfferSelector` (existing).

**DEV-3. `classes/DispositionApprovalAdvanceService.cls` + `classes/DispositionApprovalAdvanceQueueable.cls` — NEW; `classes/DispositionTriggerHandler.cls` — MODIFY.**
- `DispositionTriggerHandler.afterUpdate` gains a hook: detect
  `Approval_Advance_Pending__c` **false → true** and enqueue the Queueable, **guarded against the
  queueable limit**.
- The Queueable maps `(record type, current stage)` → target:
  - `Disposition Readiness` → `BOV Outreach` (On_Market) / `Broker Selection` (Off_Market)
  - `Broker Selection` → `NDA` (Off_Market only)
  - `Closing` → `Sale Closes`
- It writes the stage **and clears the semaphore**, using
  `Database.update(..., false, AccessLevel.SYSTEM_MODE)`.
- **A failed write leaves the flag `true`** — visible to an admin and recoverable. Do not swallow it
  into a state that looks succeeded (memory: `validation-rules-beat-system-mode-apex`).
- ⚠ `DispositionTrigger.trigger` itself does not change — it already delegates one line to the
  handler across `before insert, before update, after insert, after update`.

**DEV-4. `triggers/BovSubmissionTrigger.trigger` + `classes/BovSubmissionTriggerHandler.cls` — NEW.**
- On `Approval_Status__c` → `Approved` where `Submission_Status__c = 'Selected'`:
  set the parent `Disposition__c.Disposition_Stage__c = 'Broker Selection'` **only if the parent is
  currently on `BOV Outreach`** (idempotency guard), and stamp
  `Disposition__c.Selected_Broker__c`.
- Parent update is synchronous, `allOrNone = false`, SYSTEM_MODE (D-1).
- Handler must extend the project's `TriggerHandler` base class; the trigger file is one line.

**DEV-5. `triggers/DispositionOfferTrigger.trigger` + `classes/DispositionOfferTriggerHandler.cls` — NEW.**
- On `Approval_Status__c` → `Approved` where `Is_Selected__c = true`:
  set own `Offer_Status__c = 'Accepted'`; set the parent stage to `LOI` **only if the parent is
  currently on `Offer Selection`**; stamp `Disposition__c.Accepted_Offer_Price__c`.
- The `LOI` stage entry then auto-creates the sell-side LOI through the existing
  `DispositionStageEntryService` — **no change is needed there**.
- Same synchronous / `allOrNone = false` / SYSTEM_MODE shape as DEV-4.

**DEV-6. `classes/BovController.cls` — MODIFY; backing service class — NEW.**
- `BovController.replaceSelectedBroker(Id dispositionId, Id newSubmissionId)`.
- Behaviour: demote the old Selected submission → `Backup` **and clear its `Approval_Status__c`**;
  promote the new submission → `Selected`; update `Disposition__c.Selected_Broker__c`.
- A replace performed **after** the stage already advanced does **not** re-advance — the DEV-4
  current-stage guard covers this; a fresh approval is what re-legitimizes the new broker.
- ⚠ **There is no `Bov*Service` class in the repo today** (only `BovController` and
  `BovSubmissionSelector`). The plan says "(+ service)" without naming it. The developer agent
  creates one following the `<Feature>Service` convention (suggested: `BovSubmissionService`) —
  the controller must stay thin.

**DEV-7. `classes/RecordStageAdvanceService.cls` — MODIFY (D-2).**
- Add a `Disposition__c` entry to `CONFIG_BY_TYPE`, keyed by record type, `defaultTypeKey = 'On_Market'`,
  stage field `Disposition_Stage__c`, gate `StageActionGate.DISPOSITION_DRIVER`.
- **Manual hops only:**
  - `On_Market`: `Broker Selection → NDA`, `NDA → Release Materials`,
    `Release Materials → Active Listing`, `LOI → PSA`
  - `Off_Market`: `NDA → Release Materials`, `LOI → PSA`
- Add `NO_NEXT_STEP_HINTS` entries naming the **real owner** of every blocked hop (e.g. "Broker
  Selection advances when the Broker Selection approval is approved").
- Extend `load()`'s dispatch for the new object; **no dynamic SOQL** (the class holds zero SOQL by
  design).
- Update the class header inventory — it currently says "SEVEN … objects" and "TEN StageTypeConfigs";
  `Disposition__c` makes it eight objects and twelve configs.

**DEV-8. Selectors — NEW METHODS.**
- `classes/DispositionSelector.cls` → `selectStageRequiredById(Id)` for `RecordStageAdvanceService`.
  **`WITH SYSTEM_MODE`, justified in the class header** per ARCHITECTURE.md §2 (automation-path
  exception).
- `classes/BovSubmissionSelector.cls` → a method returning the **Selected** submission for a
  disposition (used by DEV-2's `BOV Outreach` branch; a typed error is raised when none exists).
- `classes/DispositionOfferSelector.cls` → reuse for the offer list backing `dispositionOfferSelect`;
  add a method only if no existing one fits.

**DEV-9. `classes/DispositionStageEntryService.cls` — COMMENT REWRITE ONLY.**
No functional change. Rewrite the now-false header, the NDA-stage narrative and the approval-lock
analysis (`finalApprovalRecordLock` reasoning) to match the new flow. **No behaviour may change in
this file.**

**DEV-10. `classes/TestDataFactory.cls` — MODIFY.**
Fixture updates for the new stage values and the new fields. (Note: `TestDataFactory` currently
references the removed values — see the A-0 hit-list.)

---

### PHASE 5 — LWC (DEPLOY 1)

Every bundle below needs a Jest test under `__tests__/` and `@sa11y/jest` accessibility coverage
(ARCHITECTURE.md §5). All bundles at API 67.0. Run the SLDS linter before deploy. Keep every
`.js-meta.xml` `<description>` under 255 characters — only a deploy catches a breach
(memory: `xml-comment-must-be-inside-root`).

**DEV-11. `lwc/sellMeterInitiateModal` — NEW.**
- `LightningModal`. Read-only property summary + a **mandatory** On Market / Off Market radio group.
- Buttons: Cancel, "Send for Approval".
- Apex dependency: `DispositionController.initiateAndSubmit` (DEV-1).

**DEV-12. `lwc/sellMeterList` — MODIFY.**
- The row action now opens `sellMeterInitiateModal`.
- **The sell-meter band gate is unchanged**: RED stays blocked; YELLOW keeps its existing
  `LightningConfirm` and then opens the modal.
- On success: toast + navigate to the new Disposition. On `submitted = false`, toast the
  created-but-not-submitted message and still navigate.

**DEV-13. `lwc/dispositionSubmitForApproval` — NEW.**
- Headless `RecordAction` (`lightning__RecordAction`, `actionType=Action`).
- Permission pre-flight against the **Disposition** guard —
  `DispositionActionPermissionService.hasDispositionActionAccess`, **NOT** `dealActionGuard`
  (that is the acquisitions gate).
- Imperative call to `DispositionApprovalController.submitForApproval`, then
  `getRecordNotifyChange` so the page reflects the new state.
- Apex dependency: DEV-2.

**DEV-14. `lwc/dispositionOfferSelect` — NEW.**
- ScreenAction; pattern-match the existing `brokerReplaceQuickAction` bundle.
- Radio list of the disposition's offers → `DispositionApprovalController.selectOffer` → toast →
  close the action.
- Apex dependencies: DEV-2 (`selectOffer`), offer read (DEV-8).

**DEV-15. `lwc/bovComparisonMatrix` — MODIFY; `lwc/bovReplaceBrokerModal` — NEW.**
- Add two top-right buttons to `bovComparisonMatrix`:
  - **"Add Broker Response"** — `NavigationMixin` create with defaults.
  - **"Replace Broker"** — rendered **only when exactly one submission is Selected**; opens
    `bovReplaceBrokerModal`.
- `bovReplaceBrokerModal` calls `BovController.replaceSelectedBroker`, then `refreshApex`, and
  **warns the user that a fresh approval is required**.
- Apex dependency: DEV-6.

**DEV-16. `lwc/dispositionCallForOffers` — NEW (D-5).**
- Card rendered in `dispositionMain`'s **Active Listing** block.
- Shows the call-for-offers date (`Broker_Listing__c.Call_For_Offers_Date__c`), the offers count,
  and a **+ Log Offer** action.
- ⚠ **Do not touch `lwc/callForOffersList` or `lwc/callForOffersPanel`** — those are Opportunity-scoped.

**DEV-17. `lwc/dispositionMain` — MODIFY.**
- `isClosing` currently returns `this._stage === 'Closing' || this._stage === 'Completed'`
  (`dispositionMain.js:30`). It must cover `'Sale Closes'` and drop `'Completed'`.
- Mount `dispositionCallForOffers` in the Active Listing block.
- Update `__tests__/dispositionMain.test.js` — it currently asserts on `'Completed'`.

**DEV-18. `lwc/dispositionSidebar` — MODIFY.**
- The offer-panel stage set becomes `Active Listing | Release Materials | Offer Selection | LOI`
  (drops `'Call for Offers'` and `'Disposition Offer'`, currently at `dispositionSidebar.js:65-66`).
- **Rewrite the dead "the two record types' stage value sets are DISJOINT" comment block**
  (`dispositionSidebar.js:37-41`) — with `Release Materials` and `Offer Selection` shared across
  both types, the stage value alone no longer identifies the path.
- Update `__tests__/dispositionSidebar.test.js` — it currently asserts on all three removed values.

---

### PHASE 9 — Tests

**DEV-19. Apex tests** (`salesforce-unit-testing`). 251+ records wherever the path is trigger-driven,
per `.claude/rules/bulk-test-rule.md`; per-transaction-singleton `@AuraEnabled` methods carry the
documented exemption (the shape `RecordStageAdvanceService` already uses).
- `DispositionServiceTest` — `initiateAndSubmit` happy paths for both record types, RED-band refusal,
  idempotent no-resubmit, `ProcessInstance` actually created.
- `DispositionApprovalServiceTest` — per-stage target derivation, pending gate, typed errors
  (no Selected BOV; blank `Selected_Broker__c`; wire flag false), `selectOffer` savepoint rollback.
- `DispositionApprovalAdvanceServiceTest` — **251-row semaphore chunk test**, record-type-dependent
  targets, and a VR-refusal case asserting the flag is **left true**.
- `BovSubmissionTriggerHandlerTest` / `DispositionOfferTriggerHandlerTest` — 251-row bulk,
  current-stage idempotency guards.
- End-to-end approval tests via `Approval.process` (approve **and** reject) for all five processes.
- `RecordStageAdvanceServiceTest` — map-walk additions for both Disposition record types, plus a
  refusal test proving an approval-owned hop is **not** reachable through `advance()`.
- `DispositionStageEntryServiceTest` — NDA-on-`On_Market` bulk coverage (new territory).
- `TestDataFactory` fixture updates (DEV-10).

**DEV-20. Jest** — one test file per new/touched bundle from DEV-11 … DEV-18.

---

## 4. EXECUTION ORDERING AND ACCEPTANCE CRITERIA

### 4.1 Ordering

```
PHASE 0  Branch + pre-removal sweep + recall pending approvals + GROUP BY baseline
   │
   ▼
DEPLOY 1  (additive only — nothing is removed)
   │   A-1  picklist: ADD 4 values, KEEP the 3 doomed ones
   │   A-2  record types: UNION value sets + comment rewrite
   │   A-3  5 new fields
   │   A-4  permission sets (MUST land with / before the flexipage — risk 2)
   │   A-5  3 new workflow files (field updates)
   │   DEV-1 … DEV-10  Apex
   │   A-6 … A-10  5 approval processes
   │   A-11, A-12  9 quick actions + flexipage Dynamic Actions
   │   DEV-11 … DEV-18  LWC
   │   DEV-19, DEV-20  tests
   │
   ▼
MIGRATION  (org operation, between the deploys — PHASE 7)
   │   scripts/migrate-disposition-stages.apex
   │     Call for Offers  → Active Listing
   │     Disposition Offer → Release Materials
   │     Completed         → Sale Closes
   │   Database.update(rows, false, AccessLevel.SYSTEM_MODE), per-row logging.
   │   Precedent: scripts/migrate-loi-psa-stages.apex
   │   ⚠ MUST run BEFORE the new VRs deploy — the OLD All_NDAs rule does not name
   │     'Release Materials', so the migration passes cleanly; the NEW one would block it.
   │   Stage-entry service side effects are idempotent — state that in the script header.
   │   Then: re-run the GROUP BY. REQUIRE ZERO ROWS on all three removed values.
   │   Then: sweep org list views / reports for filters on the removed values (A-19).
   │
   ▼
DEPLOY 2  (removal)
   │   A-13, A-14  validation rules (modify + rename-by-recreate)
   │   A-15  trimmed picklist + both record types (final value sets)
   │   A-16  2 rebuilt path assistants; legacy Disposition_Path destructive
   │   A-17  translations
   │   destructiveChangesPost.xml: Wire_Complete_Before_Completed, Disposition_Path
   │
   ▼
MANUAL ORG STEP  (A-18)
       Delete the 3 picklist values in Setup (a deploy cannot).
       Re-retrieve; confirm repo and org agree — remembering retrieve UNIONS values.
```

**Intra-deploy-1 dependency notes**
- **A-4 (permission sets) must not lag A-12 (flexipage).** Without read FLS on `Is_On_Market__c` and
  `Wire_Verification_Completed__c`, every gated quick action is silently hidden.
- **A-5 (field updates) must precede A-6 … A-10** — an approval process referencing a
  non-existent field update fails the deploy.
- **A-3 must precede everything** that references the new fields.
- **DEV-3 (semaphore hook) must be live before A-6/A-8/A-10** land in a real org, or an approval
  will set a flag nothing reads.

### 4.2 Acceptance criteria (from the plan's Verification section)

**AC-1 — Deploy 1 smoke.**
1. **Read the flexipage back in-org** and confirm the new action list is present — this is the
   silent-rollback check (risk 4) and is not optional.
2. Create a test Property → Initiate from the Sell Meter row → the modal renders with the read-only
   property summary and a required record-type radio.
3. Both radio choices create a Disposition with the **correct record type** and a **pending Sale
   Decision approval**.
4. Approve as a principal → the stage **auto-advances to the record-type-correct target**
   (`BOV Outreach` for On Market, `Broker Selection` for Off Market).

**AC-2 — On-Market end-to-end walk (one record).**
BOV responses → select → submit broker → approve → `Broker Selection` → `NDA` (NDA auto-created; sign
it) → `Release Materials` → `Active Listing` (CFO card renders; offers logged) → Select Offer →
approve → `LOI` (LOI auto-created) → `PSA` → `Closing` (wire completed) → submit closing → approve →
`Sale Closes`.

**AC-3 — Off-Market end-to-end walk (one record).** The same walk minus `BOV Outreach` and
`Active Listing`, with `Broker Selection → NDA` driven by the adapted `Broker_Selection_Approval`.

**AC-4 — Negative checks.**
- The Advance button is **refused** at every approval-owned hop, and the refusal message **names the
  real owner** of that hop (the `NO_NEXT_STEP_HINTS` entries from DEV-7).
- The NDA gate blocks `Release Materials` while any non-Declined NDA is unsigned.
- `Submit_Closing_Approval` is blocked (with the authored message, not the platform's "no applicable
  approval process was found") while `Wire_Verification_Completed__c` is false.
- Replace-broker clears the previous approval status and requires a fresh approval; a replace done
  after the stage already advanced does **not** re-advance the stage.

**AC-5 — Suites and migration.**
- `sf apex run test --test-level RunLocalTests` green (full local suite).
- Jest suite green.
- The migration GROUP BY returns **zero rows** on `Call for Offers`, `Disposition Offer` and
  `Completed` **before deploy 2 is attempted**.

---

## 5. PROMPTS FOR SPECIALIST AGENTS

### 🟤 PROMPT FOR `salesforce-solution-architect`

> Implement §2 (ADMIN / DECLARATIVE WORK ITEMS) of `agent-output/design-requirements.md`, items
> **A-1 through A-19**, on branch `feature/disposition-redesign`. Read `ARCHITECTURE.md` and
> `.claude/rules/salesforce-global-rule.md` first and follow the per-type skill-load → API-context →
> generate loop for every metadata type.
>
> Split the output by deploy: **A-1 … A-12 are Deploy 1**; **A-13 … A-17 are Deploy 2** and must not
> be included in the Deploy-1 payload. **A-18 and A-19 are manual org steps** — produce written
> instructions, not metadata.
>
> Hard constraints: keep every `<description>` ≤ 255 characters and put long rationale in an XML
> comment **inside** the root element; use the three-segment
> `{!$Permission.CustomPermission.Disposition_Deal_Actions}` form in FlexiPage visibility rules;
> **diff both permission sets and the flexipage against HEAD before writing** (a PermissionSet
> deploy replaces `fieldPermissions` wholesale and this working tree is shared with another
> session); `Approval_Advance_Pending__c` gets **no** FLS entry in any permission set. Rewrite —
> do not delete — the now-false design comments in both record types,
> `All_NDAs_Signed_Before_Progression` and `Wire_Complete_Before_Completed`, following each file's
> own quote-and-retract convention. Do not deploy; write metadata files only.

### 🟢 PROMPT FOR `salesforce-developer`

> Implement §3 (DEVELOPMENT WORK ITEMS) of `agent-output/design-requirements.md`, items **DEV-1
> through DEV-18**, on branch `feature/disposition-redesign`. Read `ARCHITECTURE.md` §2 and §5 and
> `.claude/rules/apex-layering-rule.md` first.
>
> Layering is non-negotiable: all SOQL in selectors, thin triggers delegating one line to a handler
> extending the project `TriggerHandler` base, `with sharing` on every class, `AuraHandledException`
> at every `@AuraEnabled` boundary. `DispositionSelector.selectStageRequiredById` uses
> `WITH SYSTEM_MODE` and **must carry its justification in the class header** per ARCHITECTURE.md's
> automation-path exception.
>
> The approval auto-advance mechanism is **fixed by design decision D-1** — a semaphore field read
> by the trigger and written by a Queueable using
> `Database.update(..., false, AccessLevel.SYSTEM_MODE)`. Do **not** substitute a direct approval
> field update on the stage (it bypasses validation rules) and do **not** substitute an
> approval-triggered flow (it runs as the approver). A failed advance must leave the semaphore
> `true`, visible and recoverable — never silently cleared.
>
> Scope discipline: `DispositionService.findOrCreate`, `ContractExecutionService` and
> `DispositionStageEntryService`'s **behaviour** are untouched; `DispositionStageEntryService` gets a
> comment rewrite only. Do not modify `lwc/callForOffersList` or `lwc/callForOffersPanel` — they are
> Opportunity-scoped. Every new/touched LWC bundle needs a Jest test plus `@sa11y/jest` coverage,
> at API 67.0, SLDS-linted, with `.js-meta.xml` `<description>` under 255 characters. Do not deploy.

### 🟡 PROMPT FOR `salesforce-unit-testing`

> Create the Apex test classes described in **DEV-19** of `agent-output/design-requirements.md`.
> Use `TestDataFactory` for all fixtures; never `SeeAllData=true`. Apply the 251-record mandate from
> `.claude/rules/bulk-test-rule.md` to the trigger-driven paths (`DispositionApprovalAdvanceService`
> semaphore chunking, `BovSubmissionTriggerHandler`, `DispositionOfferTriggerHandler`). The
> per-transaction-singleton `@AuraEnabled` methods carry the documented exemption — record that
> reasoning in the class header so review does not demand 251. Target 90%+ per class.

---

## 6. OPEN NAMING ITEMS (flagged, not invented)

The plan leaves three names as shorthand. They are transcribed above with a suggested spelling; the
implementing agent must pick one spelling and use it consistently across the workflow file, the
approval process and any Apex that references it.

1. The BOV field-update names — transcribed as `Set_BOV_Approval_Approved` / `Set_BOV_Approval_Rejected`.
2. The Offer field-update names — transcribed as `Set_Offer_Approval_Approved` / `Set_Offer_Approval_Rejected`.
3. The new BOV service class behind `BovController.replaceSelectedBroker` — the plan says
   "(+ service)"; no `Bov*Service` class exists in the repo today. Suggested: `BovSubmissionService`.
