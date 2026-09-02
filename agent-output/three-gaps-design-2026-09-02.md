# Three Gaps — Design Requirements

**Date:** 2026-09-02
**Branch:** `qa/lifecycle-simulation-2026-08-27`
**Status:** requirements only. No implementation metadata and no Apex is produced by this document.
**Siblings this is written against:** `agent-output/underwriting-approval-cutover-design.md` (2026-09-01),
`agent-output/loi-approval-cutover-design.md` (2026-09-01), `agent-output/hide-submit-while-pending.md`
(2026-08-21). Where their answers transfer it says so; where they are now **stale or falsified** it
says so in capitals.
**Deliberately not cited:** `agent-output/design-requirements.md` (per the brief — historical artefact).

```
skill_selection=complete | intent=type | best_matched_skill=none (no metadata is generated here)
mcp=unavailable | mcp_tools=none
```

---

## 0. Tooling disclosure — read this, it is not boilerplate

This agent's tool set is **file-system only** (Read / Write / Edit / Glob / Grep). There is no
`salesforce-api-context` MCP server exposed to it, no `sf` CLI, no org access and **no git**. A real
attempt to reach MCP was not possible to make; `.mcp.json` in this repo configures only the
`salesforce` server and subagents receive no MCP tools at all.

Consequently:

- **Nothing below is an org readback.** Every statement about the REPO was read from the file and
  line named, in this session, on this working tree.
- Every statement about the **ORG** is labelled **[MEASURE]** (nobody knows it yet; §9 says how to
  find out) or **[INFERRED]** (derived from repo files and possibly wrong).
- I could not run `git log`, so **commit `2997bed` was not read**. Everything I say about the two
  cutovers comes from the four repo files they left behind, which are self-describing and dated.
- No figure in this document describes another session's live working tree. Count it yourself.

---

## 1. NINE CORRECTIONS TO THE BRIEF'S PREMISES, EACH MEASURED

Read these before the item sections; four of them change what the work is.

### C1 🟢 `initialSubmissionActions` and `recallActions` are NO LONGER unproven in this repo. `hide-submit-while-pending.md` SHIPPED.

The brief asks whether that prior design "still applies". It does more than apply — **it was built,
and item 1 is its second instance, not its first.** Four approval processes now carry both elements:

| File | `initialSubmissionActions` | `recallActions` |
|---|---|---|
| `approvalProcesses/Disposition__c.Sale_Decision_Approval.approvalProcess-meta.xml` | `:276-281` | `:284-289` |
| `approvalProcesses/Disposition__c.Closing_Approval.approvalProcess-meta.xml` | `:204-209` | `:212-217` |
| `approvalProcesses/Disposition__c.Broker_Selection_Approval.approvalProcess-meta.xml` | `:218-223` | `:226-231` |
| `approvalProcesses/BOV_Submission__c.Broker_Finalize_Approval.approvalProcess-meta.xml` | `:195-200` | `:203-208` |

with the two flag fields (`objects/Disposition__c/fields/Approval_Pending__c.field-meta.xml`,
`objects/BOV_Submission__c/fields/Approval_Pending__c.field-meta.xml`), four workflow field updates
(`workflows/Disposition__c.workflow-meta.xml:59-63`, `workflows/BOV_Submission__c.workflow-meta.xml:59-64`),
the four Dynamic Actions criteria on `flexipages/Disposition_Record_Page.flexipage-meta.xml:333-334`,
a list view built on it (`objects/Disposition__c/listViews/Awaiting_Approval.listView-meta.xml:7`),
and two Apex classes that reason about the recall unlock
(`BovAutoSelectionService.cls:351`, `BovAutoSelectionServiceTest.cls:734`).

**What still transfers unchanged:** the four-exit-path rule (submit / approve / reject / **recall**),
the "a `recallActions` block that deploys green and never fires is *worse* than the bug" warning
(`Sale_Decision_Approval:88-100`), the polarity + FLS trap (a rule on an unreadable field evaluates
FALSE and hides the button for everyone, silently), and the alphabetical element ordering
(`initialSubmissionActions` after `finalRejectionRecordLock`, `recallActions` after `processOrder`).

**What is now cheaper:** the XML shape is no longer a blocking gate. Copy `Sale_Decision_Approval`.

⚠ **The one thing I cannot see is whether the behavioural readback was ever run.** That file's
`:93-100` mandates: submit → flag TRUE + button gone → **recall** → flag FALSE + button back. If it
was run, item 1 inherits proven mechanics. If it was skipped, item 1 inherits an unproven one on
three more objects. **[MEASURE] — M-1 in §9.**

### C2 The Underwriting approval's `approvalPageFields` does NOT contain `Status__c`

`approvalProcesses/Underwriting__c.Underwriting_Approval.approvalProcess-meta.xml:99-110` lists
`Name, Owner, Opportunity__c, My_Price__c, My_Cap_Rate__c, Market_Cap_Rate__c, Underwritten_NOI__c,
Target_Return__c, Principal_Price_Decision__c, Stage__c`. The brief names `approvalPageFields` as a
`Status__c` consumer. It is not one. Only `finalApprovalActions` (`:141-144`) is.

### C3 `UnderwritingSelector` never selects `Status__c`

Every `SELECT` in that class: `:48`, `:70`, `:100`, `:124`, `:170`, `:199`, `:262`, `:283`. None
names `Status__c`. The only occurrence is a **warning comment** at `:185-188` telling a future reader
to select `Stage__c` and not the "coarse `Status__c` this object also carries". Removing the field
costs this class a comment edit, not a query change.

### C4 `UnderwritingApprovalStampService` writes the PARENT's field, not the child's

`UnderwritingApprovalStampService.cls:132-136` writes `Opportunity.UW_Approved__c` and
`Opportunity.Underwriting_Status__c`. It never touches `Underwriting__c.Status__c`. Under option (a)
of item 2 this class is **untouched**.

### C5 `flows/Underwriting_Opp_Sync` is not a consumer of either field

Its `<description>` (`:33`) says the opposite in so many words: *"Opp.Underwriting_Status__c is
deliberately NOT synced - the approval process owns it."* It syncs four numeric fields.

### C6 `flows/Underwriting_Approval_Sync` keys on `Stage__c`, not on status

Its entry filter is `Stage__c` → `'Approved'`; `Underwriting_Status__c` appears only in its header
comment (`:16-17`) explaining what the *downstream* freeze keys on.

⇒ **Netting C2-C6: the brief's "9 consumers" over-counts by three.** The real inventory is in §3.2.

### C7 🟢 The `Is_Advance_Allowed__c` hazard the brief flags in red is INERT

`objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml:212-222`:

```
AND( Stage <> "Signed", Stage <> "Executed", Stage <> "Submitted",
     OR( RecordType.DeveloperName <> "Acquisition_LOI",
         TEXT(Stage__c) <> "Under Review",
         TEXT(LOI_Status__c) = "Approved" ),      <-- clause 4
     TEXT(LOI_Status__c) <> "Pending Approval" )  <-- clause 5
```

On the only population that can ever hold `'Pending Approval'` — an **Acquisition_LOI at
`Stage__c = 'Under Review'`**, because that pair *is* the approval's `entryCriteria`
(`LOI__c.LOI_Approval:180-192`) and `recordEditability = AdminOnly` freezes the stage while pending —
**clause 4 is already FALSE** (record type matches, stage matches, status is not `'Approved'`).
Clause 5 therefore changes nothing on that row. Advance Stage is **already** hidden during the pending
window and **already** hidden after a rejection, today, with no new writer.

The brief's instruction ("it must be stated, not discovered") is honoured — but the statement is the
opposite of the one expected: **writing `'Pending Approval'` costs no Advance-Stage behaviour at all.**
The real strand is on the **Submit** button, and it is §2.2.

### C8 ⚠ `Opportunity.LOI_Approval` is ALREADY DEACTIVATED — the LOI approval file's header is stale

`approvalProcesses/Opportunity.LOI_Approval.approvalProcess-meta.xml:8-9` — *"🔴 RETIRED 2026-09-01
(W5 of the LOI approval cutover). `<active>` set to false. DO NOT REACTIVATE"* — and `:79`
`<active>false</active>`, with `:66-67` recording *"There are ZERO active approval processes on
Opportunity after this deploy."*

Meanwhile `approvalProcesses/LOI__c.LOI_Approval.approvalProcess-meta.xml:128-129` and `:142-143`
still say W5 "is still NOT authorised" and that the Opportunity process "remains ACTIVE as the escape
hatch". **Two files in the same folder disagree about the same fact.** [INFERRED] the
`Opportunity.LOI_Approval` file is the later and correct one; the LOI__c header needs an in-place
annotation. **[MEASURE] — M-2.** This matters for item 1 only as a reminder that these headers have
already drifted once in 24 hours.

### C9 🔴 Item 3 HAS NO MECHANISM TODAY. There is no path from an Opportunity to its Transaction.

- `objects/Transaction__c/fields/Opportunity__c.field-meta.xml:12` — `<type>Lookup</type>`,
  `deleteConstraint SetNull`, `relationshipName` **`Transactions`** (plural — a child relationship).
- `force-app/main/default/objects/Opportunity/fields/*Transaction*` — **no files.**
- Repo-wide grep for `Primary_Transaction`, `Transaction__r`, `Transactions__r` outside
  `Critical_Date__c` — **zero hits.**

A validation rule on Opportunity can traverse a lookup **up**, never **down** to a child. The three
sibling gates all work because the Opportunity carries a `Primary_*` lookup
(`Underwriting_Approved_Before_LOI:80-81` reads `Primary_Underwriting__r.Stage__c`). **Nothing
equivalent exists for Transaction.** Item 3 is therefore not a one-line validation rule; it needs a
carrier. §4.3.

### C10 🟢 …and the INVERSE automation already exists and already works

`flows/Transaction_Complete_Close.flow-meta.xml` is a `RecordAfterSave` flow on `Transaction__c`,
entry `Status__c EqualTo 'Closed'` **AND** `Opportunity__c IsNull false`
(`:78-91`), whose `Close_Opportunity` element updates `$Record.Opportunity__r` with
`StageName = 'Closed Won'`, `Deal_Category__c = 'Closed'`, `Deal_Status__c = 'Asset Under Management'`
(`:42-69`), then notifies the Acquisitions team.

**On the intended path, the deal is closed BY the transaction closing.** Item 3 is not "add the
missing automation" — it is "**close the side doors**". That is a much smaller and much safer change,
and it reframes the whole item.

---

# 2. ITEM 1 — "Submit for approval should not be visible once it has been sent for approval to Principals"

## 2.0 What exists now, measured

| Object | Button + rule | Behaviour while an approval is pending |
|---|---|---|
| `Underwriting__c` | `flexipages/Underwriting_Record_Page.flexipage-meta.xml:48-63` — `booleanFilter` `1 AND 2`: `{!$Permission.CustomPermission.Acquisition_Deal_Actions}` EQUAL true **AND** `{!Record.Stage__c}` EQUAL `In Progress` | 🔴 **STAYS VISIBLE.** `Stage__c` does not move during the pending window — `'In Progress'` *is* the entry criterion (`Underwriting__c.Underwriting_Approval:129-135`) and `finalApprovalActions` only fire at the end. Nothing in the rule can see approval state. |
| `LOI__c` | `flexipages/LOI_Record_Page.flexipage-meta.xml:476-505` — `1 AND 2 AND 3 AND 4 AND 5`: custom permission, `LOI_Status__c` **NE `Pending Approval`**, `LOI_Status__c` NE `Approved`, `Stage__c` EQUAL `Under Review`, `RecordType.DeveloperName` EQUAL `Acquisition_LOI` | 🟠 **STAYS VISIBLE, but the criterion for hiding it is already written.** Criterion 2 (`:484-488`) is inert because nothing writes `'Pending Approval'`. |

**Confirmed: nothing in the repo writes `LOI_Status__c = 'Pending Approval'`.** Repo-wide grep — the
only hits are the picklist definitions (`fields/LOI_Status__c.field-meta.xml:19-21`, both record
types), `gen-metadata.mjs:174`, comments, **one test fixture** (`LoiGateTest.cls:22`), and two
scripts (`seed-nda-loi-metrics.apex:30`, `verify-junior-lifecycle.apex:64`). The only production
writers of that field are `ApprovalAuditService` (→ `'Approved'`) and `CounterOfferService:197`
(→ `'Countered'`), plus, since the cutover, `workflows/LOI__c.workflow-meta.xml:48-58`
(`LOI_Status_Approved` → `'Approved'`). **[MEASURE] M-3: an org-only Flow with no repo file could
still write it; `profiles/**` and `settings/**` are force-ignored here.**

**The Apex guard, verbatim:** `OpportunityApprovalService.cls:296-298`

```apex
if (!ProcessInstanceSelector.selectPendingByTargetId(targetId).isEmpty()) {
    throw new ApprovalException('This record is already pending approval.');
}
```

and its own comment at `:290-295` says the LOI page criterion *"is inert (nothing writes that value),
so this Apex check is the only thing standing between a second click and a duplicate submission."*

### Answer to the brief's third question, directly

Item 1 **complements** the Apex guard. It does not replace it and does not make it unreachable:

- `layouts/LOI__c-LOI Layout.layout-meta.xml:209` carries `LOI__c.Submit_for_Approval` in its
  `platformActionList` at sortOrder 1, **with no visibility rules at all**. It is dormant only while
  the FlexiPage is the assigned page (`flexipages/LOI_Record_Page…:371-378` argues this at length).
  Any context that renders the default layout gets the button back unconditionally.
- `layouts/Underwriting__c-Underwriting Layout.layout-meta.xml:90-94` — identical shape,
  `Underwriting__c.Submit_for_Approval`, sortOrder 1, no rules.
- The `@AuraEnabled` entry point is callable directly; list views, Classic, mobile and the API are
  not governed by Dynamic Actions.

🔴 **KEEP THE APEX GUARD. A hidden button is a UX affordance, never a control.** This is the same
conclusion `hide-submit-while-pending.md §0.1` reached for the Disposition family, and
`DispositionApprovalService.cls:331-333` was correctly left untouched there.

## 2.1 LOI — the free route, and its one real cost

**The lead in the brief is correct: criterion 2 already exists and adding a writer activates it.**
The mechanics are safe:

- ✅ `flows/LOI_Approval_Sync.flow-meta.xml:94-105` filters `LOI_Status__c EqualTo 'Approved'`,
  `recordTriggerType = Update`, `doesRequireRecordChangedToMeetCriteria = true`. Writing
  `'Pending Approval'` at submission **does not fire it**; the later `'Pending Approval' → 'Approved'`
  transition **does**. The parent-mirror chain is unaffected.
- ✅ `Is_Advance_Allowed__c` is unaffected (C7).
- ✅ Writing a locked record from an approval action is proven in-repo, twice, on `AdminOnly`
  processes (`Sale_Decision_Approval:95-100` writes `Disposition__c` from `finalApprovalActions`;
  `Broker_Finalize_Approval:111-116` writes its own locked `BOV_Submission__c` from
  `finalRejectionActions`). 🔴 **No Apex alternative exists** — `AccessLevel.SYSTEM_MODE` does not
  lift a record lock and a Queueable outlives nothing (`BovSubmissionTriggerHandler.cls:34-39`,
  `triggers/BovSubmissionTrigger.trigger:35-41`).
- 🟢 **A free pending indicator.** `lwc/dealDocStatus/dealDocStatus.js:18` already maps
  `'Pending Approval' → 'amber'`. Activating this value lights that badge with no UI work.
- 🟢 **A free rejection marker.** `LOI__c.LOI_Approval` has **no `finalRejectionActions`** (D-3), so
  today a rejection changes *nothing* anywhere and only the approval history records it. The LOI
  cutover design called an `LOI_Status__c = 'Rejected'` stamp *"a cheap, in-scope gain"* (§5.2). Item
  1 forces you to write the rejection exit anyway — so you get it.

### 🔴 THE CRUX, AND IT IS SOLVED, NOT NOTED

The brief is right that a rejected LOI would be stranded at `'Pending Approval'` forever with Submit
hidden. **The fix is the four-exit rule, which this repo already enforces.** But there is a second
problem the brief does not name, and it is the one that decides the design:

> **A workflow field update writes a LITERAL. It cannot restore the previous value.**

`Approval_Pending__c` on `Disposition__c` is a **Checkbox**, so "clear it" is unambiguous. `LOI_Status__c`
is a **nine-value restricted picklist**, so every exit path must name a value:

| Exit | Hook | Value it must write | Cost |
|---|---|---|---|
| Submit | `initialSubmissionActions` | `Pending Approval` | — |
| Approved | `finalApprovalActions` (already exists, `LOI_Status_Approved`) | `Approved` | none — unchanged |
| Rejected | `finalRejectionActions` (**new**) | `Rejected` | 🟢 a genuine gain (see above) |
| **Recalled** | `recallActions` (**new**) | 🔴 **???** | **lossy — this is the decision** |

A recall must restore "whatever it was before", and the only candidates are `Draft` (the field
default) or `Working`. **If the LOI had been countered, `CounterOfferService.cls:197` had written
`'Countered'`, and a recall would silently clobber it.** Counter-then-submit-then-recall is not
hypothetical; it is the ordinary negotiation shape on this object.

Both values exist on both record types (all nine are enumerated identically on
`recordTypes/Acquisition_LOI.recordType-meta.xml` and `Disposition_LOI.recordType-meta.xml`), and
`Stage__c` restriction **is** enforced by DML on this org — so nothing is refused at runtime. The
cost is purely informational, and it is real.

### The two LOI options

| | **L-A — reuse `LOI_Status__c`** | **L-B — new `Approval_Pending__c` Checkbox on `LOI__c`** |
|---|---|---|
| New fields | 0 | 1 (+ FLS in 2 permission sets) |
| FlexiPage change | **none** — criterion 2 already there | append a 6th criterion, `booleanFilter` `1 AND 2 AND 3 AND 4 AND 5` → `… AND 6` |
| Workflow file | 3 new `fieldUpdates` in `workflows/LOI__c.workflow-meta.xml` | 2 new `fieldUpdates` |
| Recall | 🔴 **lossy** — clobbers `Countered` | 🟢 lossless |
| Rejection marker | 🟢 free (`'Rejected'`) | ❌ not included (a separate decision) |
| Pending badge in `dealDocStatus` | 🟢 free | ❌ none |
| Symmetry with Underwriting (§2.2) | ❌ two different mechanisms | 🟢 one mechanism on both objects |
| Precedent | new shape | **exactly** `Disposition__c` / `BOV_Submission__c`, 4 processes deep |

**My recommendation: L-A, with the recall value set to `Draft`, IF and only if the user accepts the
counter-clobber.** It is genuinely cheaper, it activates a criterion someone already wrote for this
purpose, and it delivers the rejection marker the previous design wanted and could not justify
building. If the counter-clobber is unacceptable, take L-B and add the `'Rejected'` write to
`finalRejectionActions` anyway — the two are separable.

This is **decision D-1**.

## 2.2 Underwriting — the button is reachable, and only a new field can hide it

**The visibility rule cannot be made to hide the button without a new field.** Its two criteria
(`Underwriting_Record_Page:51-61`) read a custom permission and `Stage__c`, and:

- `Stage__c` cannot move during the pending window — `'In Progress'` is the entry criterion and
  `recordEditability = AdminOnly` locks the record.
- There is no approval-state token available to a FlexiPage `<leftValue>`. Every `leftValue` in every
  rule in this repo is `{!Record.<Field>}`, `{!Record.RecordType.DeveloperName}` or
  `{!$Permission.CustomPermission.<Name>}` — the LOI page's own repo sweep found *"31 flexipages, 108
  `<leftValue>` criteria in total"* and no others (`LOI_Record_Page:335-340`).
- A **formula** field cannot reach `ProcessInstance` either. (Same platform assertion
  `hide-submit-while-pending.md §0.2` could not verify from a file; it is **[MEASURE] M-4**, and it is
  cheap — if approval state *is* formula-reachable, both halves of item 1 collapse to one formula
  field.)

### The brief's reachability question, answered

> *"Note `recordEditability = AdminOnly` locks the record while pending, so establish whether the
> button is even reachable then."*

[INFERRED] **yes, it is reachable, and this is exactly the reported defect.** The lock disables record
*editing*; it does not remove quick actions from a Dynamic Actions list, and the
`Submit_for_Approval` quick action performs no DML on the Underwriting record — it calls
`OpportunityApprovalService.submitForApproval`, which reads and then calls `Approval.process`. So the
button renders, the click is accepted, and the user gets *"This record is already pending approval."*
**[MEASURE] M-5** — open a submitted Underwriting record as the deal driver and look. This is the one
observation that decides whether item 1 has anything to do on this object at all.

### U-A — the recommended shape (and the only one with precedent)

A new **Checkbox `Underwriting__c.Approval_Pending__c`**, default `false`, written **only** by the
approval process:

| Event | Hook on `Underwriting__c.Underwriting_Approval` | Field update in `workflows/Underwriting__c.workflow-meta.xml` |
|---|---|---|
| Submit | `initialSubmissionActions` (**new element**) | `Set_UW_Approval_Pending` → `1` |
| Approved | `finalApprovalActions` — a **third** `<action>` alongside the existing `UW_Stage_Approved` / `UW_Status_Approved` (`:136-145`), which stay and stay first | `Clear_UW_Approval_Pending` → `0` |
| Rejected | `finalRejectionActions` (**new element** — this file has none) | `Clear_UW_Approval_Pending` → `0` |
| Recalled | `recallActions` (**new element**) | `Clear_UW_Approval_Pending` → `0` |

plus a **third criterion** on `Underwriting_Record_Page:50-62`:
`{!Record.Approval_Pending__c}` **EQUAL** `false`, `booleanFilter` `1 AND 2` → `1 AND 2 AND 3`.

⚠ Use `EQUAL` + lowercase `false`, the polarity proven on `Disposition_Record_Page`. `NE` against a
boolean is not proven on this org.

⚠ **FLS is load-bearing and fail-closed.** With `EQUAL false` polarity, a missing grant makes the rule
evaluate FALSE and hides the button **for everyone, permanently, with no error logged anywhere** —
the same symptom as the defect. Mirror the grant matrix of the field the sibling criterion already
reads: `Underwriting__c.Stage__c` is granted `readable` in `DPEG_Acquisition_View:1700-1702` and
`readable + editable` in `DPEG_Acquisition_Edit:1758-1760`, and read-only in
`Opportunity_Stage_Actions_Access` (`:98`). The new field goes **read-only in all three**.
🔴 A PermissionSet deploy **replaces its whole `fieldPermissions` set** — insert one block each, diff
against `HEAD`, confirm zero deletions.

⚠ **Deploy the permission sets WITH OR BEFORE the FlexiPage. Never after.**

⚠ **Naming.** `Approval_Pending__c` deviates from `ARCHITECTURE.md` §1's Boolean convention
(`Is_`/`Has_`, or `<Subject>_<PastParticiple>`) — "Pending" is a present participle. It is chosen for
**exact symmetry with the two existing `Approval_Pending__c` fields**, which a reader will inevitably
compare it to. `Is_Approval_Pending__c` is the strict-conformance alternative. Whichever is chosen,
use the same name on both `Underwriting__c` and (if L-B) `LOI__c`. **Decision D-2.**

### U-B — the option I am naming so it is refused deliberately

Repurpose `Underwriting__c.Status__c` as the pending marker (add a `'Pending Approval'` value) instead
of deleting it in item 2. It costs no new field. **I recommend against it**: it directly contradicts
item 2's stated intent, it re-loads a field the user has just asked to remove, and it makes items 1
and 2 mutually blocking instead of merely adjacent. Named because it is the obvious idea and someone
will have it.

## 2.3 What item 1 does NOT include

Not requested, not designed: no pending indicator beyond what already exists, no change to
approvers, no change to `allowRecall` / `recordEditability` / `entryCriteria` / `approvalPageFields`
on either process, no change to `DispositionApprovalService` or the Disposition family, no change to
`Disposition_Offer__c.Offer_Selection_Approval` (`:84` records that it deliberately has no pending
flag — out of scope, but worth the user knowing it is the one remaining approval without one).

🟢 **A pending indicator is already free on both objects.** Both record pages carry Approval History
in the `header` region with the Recall button above the fold:
`Underwriting_Record_Page:29-41` (`force:relatedListContainer`) +
`layouts/Underwriting__c-Underwriting Layout:121-150` (`RelatedProcessHistoryList`), and the LOI
equivalents landed in the same cutover (`LOI__c.LOI_Approval:112-118`). **Two files, neither works
alone** — `force:relatedListSingleContainer` returns `INVALID_TYPE` for approval history here.

---

# 3. ITEM 2 — remove `Underwriting__c.Status__c` 🔴 THE RISKY ONE

## 3.1 🟢 THE FINDING FIRST: they ARE redundant, and it is the OPPOSITE of the brief's hypothesis

The brief asks whether `Status__c` carries a value `Stage__c` cannot express, and nominates
`'Approved by Principals'`. **Measured, both files, both `<restricted>true</restricted>`:**

| `Stage__c` (`fields/Stage__c.field-meta.xml:12-34`) | `Status__c` (`fields/Status__c.field-meta.xml:12-29`) |
|---|---|
| `Requested` (default) | — *(no counterpart)* |
| `In Progress` | `In Progress` (default) |
| `Approved` | `Approved by Principals` |
| `Completed` | `Complete` |

`Stage__c` is a **strict superset**. It expresses everything `Status__c` expresses, plus `Requested`.
`'Approved by Principals'` is exactly `Stage__c = 'Approved'` — written by the **same
`finalApprovalActions`, in the same action set, on the same save**
(`Underwriting__c.Underwriting_Approval:136-145` → `workflows/Underwriting__c.workflow-meta.xml`
`UW_Stage_Approved` / `UW_Status_Approved`). They cannot disagree on that transition.

`Stage__c`'s own `<description>` (`:4`) already frames it this way: *"Coarse `Status__c` (In
Progress/Complete/Approved by Principals) stays for reporting."*

**And `'Complete'` is a dead value.** Repo-wide grep for a write of `Status__c = 'Complete'` on either
`Underwriting__c` or `Opportunity`: **zero hits.** (Every match is `Task.Onboarding_Status__c`, a
different field on a different object.) So of three values, one is dead and two are duplicates.

⇒ **Removing `Underwriting__c.Status__c` loses no information.** The user's reasoning is correct.

⚠ **One genuine disagreement, and it is small.** At `Stage__c = 'Requested'`, `Status__c` reads its
default `'In Progress'`. A report grouped on `Status__c` therefore counts requested-but-not-started
underwritings as in-progress. That is an argument *for* removal, not against it.

## 3.2 Measured consumer inventory — repo only

### `Underwriting__c.Status__c` (the child field)

| # | Consumer | Where | Kind |
|---|---|---|---|
| 1 | `UW_Status_Approved` field update | `workflows/Underwriting__c.workflow-meta.xml:48-58` | **writer** |
| 2 | `finalApprovalActions` `<action>` naming it | `approvalProcesses/Underwriting__c.Underwriting_Approval…:141-144` | **reference by name** |
| 3 | FLS grant | `permissionsets/DPEG_Acquisition_View…:1705` | grant |
| 4 | FLS grant | `permissionsets/DPEG_Acquisition_Edit…:1763` | grant |
| 5 | Field translation | `objectTranslations/Underwriting__c-en_US/Status__c.fieldTranslation-meta.xml` | file to delete |
| 6 | Manifest member | `manifest/package.xml:768` | file edit |
| 7 | `TestDataFactory.approveUnderwriting` | `TestDataFactory.cls:1091` — `Status__c = 'In Progress'` | 🔴 **compile break** |
| 8 | `UnderwritingGateTest` | `:153`, `:157`, `:221`, `:225` | 🔴 **compile break** (2 methods) |
| 9-12 | Seed scripts writing `Status__c = 'Approved by Principals'` | `seed-fsd-02-flagship-shallow.apex:149`, `seed-fsd-03-flagship-deep.apex:56`, `seed-fsd-04-flagship-closed-won.apex:61`, `seed-fsd-05-flagship-dead.apex:86` | runtime break |
| 13 | Warning comment | `UnderwritingSelector.cls:185-188` | comment edit (C3) |
| 14 | Doc reference | `flexipages/Underwriting_Record_Page` — **none.** Grep for `Status__c`: no matches | — |
| 15 | Layout — **none.** `layouts/Underwriting__c-Underwriting Layout`: grep for `Status__c` returns no matches | — |
| 16 | Reports — **none.** No repo report references `Underwriting__c.Status__c` (only `Deal_Status_Breakdown` and `Underwriting_Outputs_Active` touch this object at all; the latter's fields are `Opportunity__c`, `My_Cap_Rate__c`, `Year_5_IRR__c`, `My_Price__c`) | — |
| 17 | List views — **none** on this object | — |

🟢 **The child field has no UI surface at all.** It is on no layout, no FlexiPage, no report, no list
view. It is invisible to every user today. That is a strong argument that removing it is low-risk —
**and equally a warning that it may already be dead weight nobody will miss, in which case the
cheapest correct answer may be to leave it alone.** See §8.2.

### `Opportunity.Underwriting_Status__c` (the parent mirror) — a different, larger animal

| Consumer | Where | Why it matters |
|---|---|---|
| `UnderwritingApprovalStampService.cls:132-136` | writes it in the **same shell** as `UW_Approved__c` | 🔴 The class header (`:130-131`) says both fields must land in ONE save |
| `flows/Opportunity_UW_Approved_Notify.flow-meta.xml:56` | entry filter, transition to `'Approved by Principals'` | 🔴 **This is the trigger of the market-data freeze** |
| `MarketDataSnapshotService.cls:76` | *"it fires on the TRANSITION into `Underwriting_Status__c = 'Approved by Principals'`"* | 🔴 the freeze itself |
| `objects/Opportunity/fields/Market_Data_As_Of_Date__c.field-meta.xml:4` | describes the same dependency | doc |
| `objects/Opportunity/fields/Market_Data_Snapshot__c.field-meta.xml:4` | same | doc |
| `flexipages/Opportunity_Record_Page.flexipage-meta.xml:803` | `<fieldItem>Record.Underwriting_Status__c` — **readonly, visible on the deal page** | 🔴 **a real UI surface** |
| `objects/Opportunity/recordTypes/Land.recordType-meta.xml:228`, `Retail…:260` | picklist value assignments on **both** record types | removal is a record-type edit too |
| `workflows/Opportunity.workflow-meta.xml:71` | `UW_Set_Status_Approved`, now **inert** (its approval is deactivated) but still referenced by name by the retained inactive process | 🔴 **must not be deleted** |
| `approvalProcesses/Opportunity.Underwriting_Approval…:48` | references it | retained-inactive |
| `permissionsets/DPEG_Opportunity_View`, `DPEG_Acquisition_View`, `DPEG_Acquisition_Edit` | FLS | grants |
| `classes/ApprovalAuditService.cls:51,166` | comments | comment |
| `TestDataFactory.cls:1048-1049` | *"`Underwriting_Status__c` is likewise left alone — writing it would fire the market-data freeze from a test fixture"* | 🔴 a deliberate fixture decision that would have to be re-argued |
| `UnderwritingGateTest.cls:161,170,229,236`; `UnderwritingApprovalStampServiceTest.cls:10,35,61`; `UnderwritingApprovalStampService.cls:23,28,73,104,131` | tests + class body | compile/assert breaks |

## 3.3 Two options, sized

### 🔵 OPTION (a) — remove the CHILD field only. **RECOMMENDED.**

**Scope:** `Underwriting__c.Status__c` and nothing else. `Opportunity.Underwriting_Status__c` stays.

**Why it is coherent and not half a job:** the parent mirror is not a duplicate of anything. The
Opportunity has **no** `Stage__c`-equivalent for underwriting — its own `StageName` is the *deal*
lifecycle, not the underwriting's. The mirror is the deal page's only view of underwriting state and
the market-data freeze's only trigger. **The user's stated reasoning — "we don't need status and
stage fields on one object" — applies to `Underwriting__c` and does not apply to `Opportunity`,
which has no underwriting stage field at all.**

**Waves (additive/retire discipline — no in-place delete):**

| Wave | Act | Notes |
|---|---|---|
| **2a-W0** | 🔴 **Org sweep before anything.** Reports, dashboards, list views, formula fields and org-only Flows referencing `Underwriting__c.Status__c` — in the **ORG**, not the repo. **[MEASURE] M-6.** Reports do **not** block field deletion here and fail **silently** afterwards. | The repo shows zero; the org may not |
| **2a-W1** | Edit `approvalProcesses/Underwriting__c.Underwriting_Approval` — **remove the `UW_Status_Approved` `<action>` from `finalApprovalActions`**, leaving `UW_Stage_Approved` alone. ⚠ **Live-process edit.** ⚠ **Combine this with item 1's additions to the same file — ONE edit, not two.** | An approval referencing a deleted field update cannot deploy; this must go first |
| **2a-W2** | Repo-side: `TestDataFactory.cls:1091` drop `Status__c`; `UnderwritingGateTest` `:153,157,221,225`; four seed scripts; `UnderwritingSelector.cls:185-188` comment; `manifest/package.xml:768`. **Deploy the Apex in the same payload as W3** — a class referencing a deleted field will not compile | 🔴 **compile break, whole suite** |
| **2a-W3** | Remove the FLS blocks from `DPEG_Acquisition_View:1705` and `DPEG_Acquisition_Edit:1763` | ⚠ permset deploy replaces `fieldPermissions` wholesale — diff against `HEAD` |
| **2a-W4** | Delete `workflows/Underwriting__c.workflow-meta.xml`'s `UW_Status_Approved` `fieldUpdates` block | only after W1 |
| **2a-W5** | `destructiveChanges.xml`: the field + `objectTranslations/Underwriting__c-en_US/Status__c.fieldTranslation-meta.xml` | 🔴 **the API name stays RESERVED until ERASED** in Setup |

**Rollback:** trivial up to W5 (re-add). After W5, re-creating a same-named field is blocked until the
deleted one is erased.

### 🟤 OPTION (b) — also remove `Opportunity.Underwriting_Status__c`

Everything in (a), **plus**: rewrite `UnderwritingApprovalStampService`'s single-shell write, rewrite
`flows/Opportunity_UW_Approved_Notify`'s entry filter onto some other trigger, re-argue
`MarketDataSnapshotService`'s freeze semantics, remove a visible field from
`Opportunity_Record_Page`, edit **both** Opportunity record types, and rewrite
`UnderwritingApprovalStampServiceTest` (whose header at `:10` says the one-save contract *is* the
thing under test).

🔴 **I recommend against (b), plainly.**

1. **It is not the same change.** (a) removes a duplicate. (b) removes the deal's only view of
   underwriting state and the *only trigger* of the market-data freeze. There is no third field to
   fall back on.
2. **The freeze would need a new trigger field.** The obvious candidate, `UW_Approved__c`, is a
   Checkbox that `TestDataFactory` sets in fixtures — the freeze would start firing from test data,
   which `TestDataFactory.cls:1048-1049` deliberately prevents today.
3. **It removes a visible field from the deal page** with no replacement — a user-facing regression
   nobody asked for.
4. The redundancy argument that justifies (a) **does not hold on Opportunity**: there is no
   underwriting `Stage__c` there to be redundant with.

If the user genuinely wants the deal page to stop showing underwriting status, that is a
**layout/FlexiPage decision** (remove the `fieldInstance` at `Opportunity_Record_Page:803`), not a
field deletion — one line, fully reversible, zero blast radius.

**Decision D-3: (a) or (b). Recommendation: (a).**

## 3.4 ⚠ Consistency the user should see before deciding

"Status and stage on one object" is **not unique to `Underwriting__c`**. Measured in this repo:

| Object | Stage field | Status field | Redundant? |
|---|---|---|---|
| `Underwriting__c` | `Stage__c` (4 values) | `Status__c` (3) | 🔴 **yes, strict subset** |
| `Transaction__c` | `Stage__c` (5, terminal `Closed`) | `Status__c` (3: Draft/Active/**Closed**) | ⚠ **partly** — and the org chose to KEEP both and add `flows/Transaction_Stage_Closed_Sets_Status` to keep them in step (commit `a8a1bb2`) |
| `LOI__c` | `Stage__c` (per record type) | `LOI_Status__c` (9) | ❌ **no** — different vocabularies, `LoiSelector.cls:121-123` documents why they are *not* to be coupled |
| `Contract_Review__c` | `Stage__c` | `Negotiation_Status__c` | ❌ no — per-record-type sequences |
| `BOV_Submission__c` | — | `Approval_Status__c` + `Submission_Status__c` | ❌ deliberately two |

⇒ **Removing it on `Underwriting__c` is correct on its own merits, but it is not a policy.** If the
user reads item 2 as "one lifecycle field per object, everywhere", **say no** — `Transaction__c`
solved the identical shape 24 hours ago by *syncing* rather than *removing*, and that decision is
explicitly protected (`Transaction_Stage_Closed_Sets_Status:21-25`: *"Do NOT change
`Transaction_Complete_Close`'s trigger condition to key on `Stage__c` instead of `Status__c` …
explicit user decision"*).

---

# 4. ITEM 3 — "A deal can't be closed until transaction is closed"

## 4.1 Measured terminal values and relationship

| Fact | Source |
|---|---|
| `Transaction__c.Stage__c`: `Open Contract` (default) → `Due Diligence` → `Closing Prep` → `Post-Closing` → **`Closed`**, `restricted=true` | `objects/Transaction__c/fields/Stage__c.field-meta.xml:12-38` |
| `Transaction__c.Status__c`: `Draft` (default) / `Active` / **`Closed`**, `restricted=true` | `…/fields/Status__c.field-meta.xml:12-28` |
| `RecordStageAdvanceService.TRANSACTION_NEXT_STAGE` — `'Post-Closing' => 'Closed'`, `'Closed'` terminal with no entry | `RecordStageAdvanceService.cls:1526-1530`, `:1487-1488` |
| The terminal was renamed `'Closed Won'` → `'Closed'` **in Setup by the user**, label AND API name | `RecordStageAdvanceService.cls:1490-1496` |
| `flows/Transaction_Stage_Closed_Sets_Status` — **before-save**, `CreateAndUpdate`, sets `Status__c = 'Closed'` when `Stage__c` reaches `Closed` | that file `:7-29`, `:32-44` |
| **Opportunity terminal is `'Closed Won'` (rank 8).** `'Dead/Pass'` is rank 0, a universal off-ramp, and is **not** a close | `No_Backward_Stage_Movement…:92-99` |
| Both `'Under Contract (PSA)'` **and** `'About to Close'` map to `'Closed Won'` in `StageAdvanceService.NEXT_STAGE` | `StageAdvanceService.cls:135-140` |
| `Transaction__c.Opportunity__c` is a **Lookup**, child→parent, `relationshipName Transactions` | that field `:8,12` |
| **Cardinality is one-to-MANY, unenforced.** `TransactionSelector.selectByOpportunityIds` is used as an idempotency guard, so at most one is created *by the service* — but nothing prevents more | `ContractExecutionService.cls:322-326` |

## 4.2 🔴 THE ORDERING DOES **NOT** ALWAYS WORK, AND IT IS MEASURED IN THE REPO

The brief asks me to "check the ordering actually works before assuming it does." It does on the
intended path and **fails on a second, equally live path.**

- The Transaction is created **only** on ENTRY to `'About to Close'`
  (`ContractExecutionService.openTransactionsOnAboutToClose:307-364`, guard at `:312-313`).
- **`'About to Close'` is optional.** `StageAdvanceService.NEXT_STAGE` maps
  `'Under Contract (PSA)' => 'Closed Won'` **directly**, and `'About to Close'` is a separate
  explicit target in `ALLOWED_EXPLICIT_TARGETS` (`:106-111`) described in that file as *"the optional
  `'Under Contract (PSA)'` off-ramp"* (`:85-86`).
- `StageAdvanceService.cls:135-140` states the consequence outright:

  > *"🔴 BOTH `'Under Contract (PSA)'` AND `'About to Close'` MAP TO `'Closed Won'`, AND THAT PAIR IS
  > LOAD-BEARING OUTSIDE THIS CLASS. `PropertyAssetService.ensureOnClosedWon` lives on
  > `OpportunityReviewTrigger` — rather than in the `Transaction_Complete_Close` flow — precisely
  > because of it: a deal driver can reach `'Closed Won'` from EITHER key, **so half the closes carry
  > no `Transaction__c` at all.**"*

⇒ **The "deal has no transaction" case is not an edge case in this org. It is roughly half the
population, by the repo's own account.** ⚠ "Half" is that class header's word, written 2026-08-27;
the live proportion is **[MEASURE] M-7**.

## 4.3 The mechanism problem, and the two ways out

Per C9, a validation rule on Opportunity cannot see a child Transaction. Two carriers:

### 🟢 OPTION T-A — a stored flag on the Opportunity, written by the flow that already closes the deal. **RECOMMENDED.**

1. New Checkbox **`Opportunity.Transaction_Closed__c`**, default `false`.
   ✅ conforms to `ARCHITECTURE.md` §1 (`<Subject>_<PastParticiple>`).
2. Its **only** writer: a third `<inputAssignments>` on the *existing* `Close_Opportunity` element of
   `flows/Transaction_Complete_Close.flow-meta.xml:42-69` — same flow, same record update, same DML.
3. New validation rule on Opportunity:
   `AND( ISCHANGED(StageName), ISPICKVAL(StageName,'Closed Won'), NOT(Transaction_Closed__c) )`

**Why this is the right shape:**

- 🟢 **The legitimate writer satisfies the rule by construction.** The flow sets `StageName` and the
  flag in **one** record update, so the rule evaluates once against the final in-memory record and
  passes. There is no ordering hazard, no cross-object read, no lookup to populate.
  ⚠ This matters more than it sounds: `Contract_Signed_Before_Closed_Won`'s own comment (`:16-21`)
  records that this flow **is** subject to validation rules and that a failure *"will make that flow
  throw and roll back the Transaction save (accepted risk)"*. T-A cannot ever be that cause. **T-B
  can.**
- 🟢 **Test-neutral at 251 records for one field write.** See §5.3 — this is decisive.
- 🟢 It closes **every** side door at once: Path, list view, API, `StageAdvanceService.advance`,
  Data Loader, any future flow.
- ⚠ It is a **monotonic latch** — nothing clears it. That is correct here (`'Closed Won'` is
  terminal and `Dead_Pass_Not_Allowed_From_Closed_Won` blocks the only exit), but it must be stated
  in the field's own description so nobody later "completes the set" with a clearing action.
- ⚠ FLS: **read-only** everywhere it is granted, like `Is_On_Market__c`. It is a machine flag; a
  hand-edit would forge a close.

### 🟤 OPTION T-B — `Opportunity.Primary_Transaction__c` lookup + a spanning rule

Matches the `Primary_NDA__c` / `Primary_LOI__c` / `Primary_Underwriting__c` precedent and gives real
reporting value. Rule: `TEXT(Primary_Transaction__r.Status__c) <> 'Closed'`.

**Costs, measured:** a new lookup + a stamp service (the `LoiPrimaryStampQueueable` shape) + a
**backfill of every existing deal** + FLS + layout + the `ContractExecutionService` insert path (which
runs `Database.insert(..., AccessLevel.SYSTEM_MODE)` because the deal driver is deliberately
Create-denied on `Transaction__c`, `:293-299`, so the parent stamp is a second DML with its own access
question).

🔴 **And its test cost is disqualifying.** See §5.3.

**Decision D-4: T-A or T-B. Recommendation: T-A.**

## 4.4 Fail-open or fail-closed on a deal with no transaction

The brief asks whether `Underwriting_Approved_Before_LOI`'s reasoning transfers. **It does not, and
the reasons are specific.**

That rule fails **closed** on a blank `Primary_Underwriting__c` and its header (`:45-55`) forbids
adding an exemption, for one stated reason: *"NO SUCH SIBLING RULE EXISTS HERE for the Underwriting →
LOI transition"* — nothing else in the rule pack would catch a blank lookup, so it must.

Here the situation is different in three ways:

1. **There is a sibling.** `Contract_Signed_Before_Closed_Won` already gates this exact transition on
   `Contract_Signed__c`, and `PropertyAssetServiceTest.cls:546` records that there are already
   **four** `ISCHANGED`-gated Closed Won rules. Item 3 makes five. `Completed_LOI_Before_PSA`'s header
   argues at length that *two error messages for one problem is worse than one*.
2. **The blocked population is enormous and structural, not accidental.** A blank
   `Primary_Underwriting__c` was a data gap. "No Transaction" is ~half of all closes **by design**
   (§4.2). Fail-closed does not clean up a gap; it **changes the workflow for half the deals**.
3. **There IS a route out, and it is a legitimate business act.** From `'Under Contract (PSA)'` (rank
   6) a driver can `advanceTo('About to Close')` (rank 7) — an allowed explicit target
   (`StageAdvanceService.cls:106-111`) — which creates the Transaction. So fail-closed means "you
   must hand the deal to the Transactions team before you can close it", which is a coherent policy
   and arguably the user's actual intent.

⇒ **This is genuinely the user's call, and it is the biggest decision in this document.**

| | **Fail-CLOSED** (no transaction ⇒ cannot close) | **Fail-OPEN** (no transaction ⇒ close allowed; only a deal *with* a transaction must wait for it) |
|---|---|---|
| Matches the user's words | 🟢 literally | ⚠ partially |
| Blast radius | 🔴 ~half of closes must now route through `'About to Close'` | 🟢 small |
| Knock-on | `StageAdvanceService.NEXT_STAGE`'s `'Under Contract (PSA)' => 'Closed Won'` hop becomes a button that always throws — it should be **repointed to `'About to Close'`** in the same change | none |
| Second knock-on | `PropertyAssetService`'s reason for living on the Opportunity trigger evaporates (the "half the closes" population disappears). **Do not act on that** — just annotate it | none |
| Existing closed deals | untouched (`ISCHANGED`-scoped, grandfathered) | untouched |
| Rule expressible in T-A | 🟢 `NOT(Transaction_Closed__c)` | 🔴 **needs a second flag** — "this deal has an open transaction" — because a Checkbox cannot distinguish "no transaction" from "transaction not closed". T-B expresses it naturally as `NOT(ISBLANK(Primary_Transaction__c)) && Status <> 'Closed'` |

🔴 **Note the coupling: fail-OPEN pushes you toward T-B, fail-CLOSED works cleanly with T-A.** Answer
D-5 before D-4.

**Decision D-5: fail-open or fail-closed. I lean fail-CLOSED with the `NEXT_STAGE` repoint**, because
it is what the user asked for, because it has a legitimate route out, and because fail-open leaves
exactly the population the user is worried about (a deal closed with no transaction ever opened)
still able to close.

## 4.5 `Dead/Pass` — do NOT gate it

🔴 **Gating `'Dead/Pass'` would be wrong and I would refuse to design it without an explicit
instruction.** A deal that dies has no transaction and never will. `'Dead/Pass'` is rank 0 and
deliberately fail-open from every stage (`No_Backward_Stage_Movement:96-106`: *"Only clause 3 (new
rank > 0) is load-bearing for the `Dead/Pass` invariant"*). Gating it would strand **every dying deal
permanently**, with the only recovery being a manual DML repoint, and it would collide with
`Dead_Pass_Not_Allowed_From_Closed_Won`, which already blocks the reverse.

The rule is scoped `ISPICKVAL(StageName,'Closed Won')` and touches nothing else. **The brief's
instinct here is correct and should be recorded as a decision taken, not an omission.**

---

# 5. TEST IMPACT — every test whose behaviour changes

🔴 **READ THIS FIRST. Every row below is a claim about the REPO's copy.** The last cutover found the
org's `UnderwritingGateTest` had different method names and was passing against old behaviour, so
three predicted failures never existed. **[MEASURE] M-8: read the ORG's `ApexClass.Body` for
`LoiGateTest`, `UnderwritingGateTest`, `PropertyAssetServiceTest`, `StageAdvanceServiceTest` and
`OpportunityApprovalServiceTest`, method by method, before treating any of §5 as an acceptance
criterion.** Also capture a **baseline** `ApexTestResult` run with timestamps first — a post-deploy
failure is not attributable without one.

## 5.1 The two tests that are RED by design — and whether anything here resolves them

| Test | Why it is red **now** (measured from the repo) | Resolved by items 1-3? |
|---|---|---|
| `LoiGateTest.rejectionReturnsDealToUnderwriting` (`:65-87`) | It calls `Approval.process(o.Id)` on an **Opportunity** at `'LOI'` (`:69-71`). `Opportunity.LOI_Approval` is now `<active>false</active>` (C8) ⇒ `NO_APPLICABLE_PROCESS`. The submit result is **not asserted**, so it fails one line later at `:74-76`, where the `ProcessInstanceWorkitem` single-row query throws `System.QueryException`. Its `:84` assertion (`StageName == 'Underwriting'`) is the deal rewind the user deliberately removed (D-3). | ❌ **No.** Neither item touches it. Its assertion pins behaviour that no longer exists. |
| `LoiGateTest.firstResponseApprovalStampsLoiAuditTrail` (`:17-62`) | Same submission (`:27-30`), and here `submitted.isSuccess()` **is** asserted at `:30` ⇒ fails on the first assert. Its downstream assertions (`:52-61`) then depend on `ApprovalAuditService` reading the **Opportunity's** history, which the cutover repointed to the LOI's. | ⚠ **Item 1 gives it a natural resolution only if L-A is chosen.** See below. |

🟢 **A genuine free finding, and it is worth knowing.** `firstResponseApprovalStampsLoiAuditTrail`
already sets `loi.LOI_Status__c = 'Pending Approval'` at `:22` as a hand-built fixture. Under **L-A**
that stops being a fixture and becomes **the state the approval itself produces** — so the correct
rewrite of this test is: delete line 22, submit the **LOI** (not the deal), assert
`LOI_Status__c == 'Pending Approval'` **while pending**, approve, assert `'Approved'`. That is a
strictly better test than the one that exists, it pins item 1's core behaviour, and it converts a
red-by-accident test into a red-by-design acceptance criterion.

⇒ **Recommendation, but it is scope the user has not asked for and I am not designing it:** rewrite
both `LoiGateTest` methods onto `LOI__c.LOI_Approval` as a **separate, explicitly-authorised chore**,
sequenced with item 1's L-A wave so the fixture change lands once. **Decision D-6.**
🔴 **Do not fold it silently into item 1.** `rejectionReturnsDealToUnderwriting`'s sibling,
`directLoiToUnderwritingUpdate_isAllowedByCarveOut1_notByApproval` (`:106-121`), is the **only**
remaining pin on `No_Backward_Stage_Movement` CARVE-OUT 1 and its own docstring (`:89-104`) explains
why. **Protect it. Do not delete it while cleaning up its neighbour.**

## 5.2 Item 1

| Test / fixture | Effect |
|---|---|
| **No Apex test can observe a FlexiPage visibility rule or an approval `recallActions` firing.** | 🔴 Item 1's acceptance criterion is a **live UI readback**, not a test run. Say so in any test-class header so review does not demand a test that cannot exist. |
| `UnderwritingGateTest.principalApprovalStampsTheDealMirrorWithoutAdvancingTheStage` (`:128-178`) | Under **U-A**, this walks the whole approval including the new `initialSubmissionActions` and `finalApprovalActions` third action. It asserts nothing about the flag today. ⚠ **Add nothing** unless the user asks — but expect it to be the natural home for `Approval_Pending__c == false` after approval. |
| `UnderwritingGateTest.principalRejectionLeavesTheUnderwritingInProgressAndClearsNothing` (`:201-244`) | 🔴 **Its whole premise is "the replacement process has NO `finalRejectionActions` at all"** (`:189`). U-A **adds one**. The test still passes (it asserts nothing about the new field), but its docstring becomes **false**. ⚠ Correct it in place, do not delete — repo convention. |
| `OpportunityApprovalServiceTest` / `OpportunityApprovalControllerTest` | Their comments at `:586` / `:118` state the LOI `'Pending Approval'` criterion **is inert**. Under L-A it stops being inert. Comment corrections; no assertion moves. |
| `LoiGateTest.cls:22` | See §5.1. |
| `scripts/seed-nda-loi-metrics.apex:30` | Already inserts an LOI at `'Pending Approval'`. Under L-A that row will render with **Submit hidden** and no pending approval behind it — a permanently-hidden button on seed data. 🔴 **Name it; either fix the seed or accept it.** |
| `scripts/verify-junior-lifecycle.apex:64` | Same value — but this script **cannot run** (it is written against a retired 2026-08 stage model). Do not repair it here. |

## 5.3 Item 3 — 🔴 THE LARGEST TEST BLAST RADIUS OF THE THREE, AND WHAT DECIDES T-A vs T-B

**Insert-at-Closed-Won is immune.** All five Closed Won rules are `ISCHANGED(StageName)`-scoped and
`ISCHANGED` is false on insert — `PropertyAssetServiceTest.cls:543-548` states this explicitly. So the
many fixtures that build a deal directly at `'Closed Won'` (`BrokerCounterRecalcBatchTest:593`,
`BrokerFirmControllerTest:72,74`, `OpportunityFunnelControllerTest:133`,
`OpportunitySelectorTest:866`, and most seeds) are unaffected.

**Only tests that UPDATE a saved deal into `'Closed Won'` are exposed.** Measured:

| Test | What it does | Effect |
|---|---|---|
| 🔴 `PropertyAssetServiceTest.close()` (`:91-97`) | `for (o : opps) o.StageName = 'Closed Won'; update opps;` — called from the **251-record bulk tests** | **Every test using it goes RED** until the fixture satisfies the new gate |
| `StageAdvanceServiceTest.advanceMovesLoiToPsaAndPsaToClosedWon` (`:66-110`) | `StageAdvanceService.advance(psaDeal.Id)` → PSA → Closed Won | RED. ⚠ Under **fail-closed + the `NEXT_STAGE` repoint** this test's *subject* changes, not just its fixture |
| `NdaDealProgressionGateTest` (`:108-112`) | already **expects** a block | ⚠ **may pass VACUOUSLY** — verify it asserts the NDA message, not merely "something threw" |
| `StageBackwardMovementGateTest`, `StageDelayServiceTest`, `StageApprovalGatesTest`, `DealFolderServiceTest`, `ContractExecutionServiceTest`, `RecordStageAdvanceServiceTest`, `StageAdvanceControllerTest`, `TransactionControllerTest`, `TopDealsControllerTest`, `OpportunitySelectorTest` | grep counts 100 `'Closed Won'` occurrences across 34 classes — most are **reads** (`WHERE StageName = …`) | **[MEASURE] M-9:** classify each as insert / update / read. Only updates are exposed. |
| Seeds: `seed-fsd-04-flagship-closed-won.apex`, `seed-fsd-06-volume-pipeline.apex`, `seed-disposition-lifecycle-01/02`, `seed-transaction-progress.apex`, `seed-transactions.apex` | 51 occurrences across 17 files | **[MEASURE] M-10:** same classification |

### 🔴 The fixture argument that decides T-A vs T-B

`TestDataFactory` already carries a **named family of gate-satisfaction helpers** (`:895-901`):

```
signPrimaryNda      -> a signed primary NDA        (Underwriting / LOI / PSA / About to Close / Closed Won)
approveUnderwriting -> primary Underwriting Stage__c = 'Approved' + UW_Approved__c   (LOI)
placeApprovedLoi    -> Primary_LOI__c + LOI_Approved__c                              (PSA)
signContract        -> Contract_Signed__c                                            (Closed Won)
```

with the stated reason: *"The gates are one family of rules; when the family changes … exactly one
place should need editing."* Item 3 adds a fifth member.

- **Under T-A**, that helper is **one field write per deal** (`Transaction_Closed__c = true`),
  batched into one DML. At 251 records: 251 field writes, one DML, **zero cascades**.
- **Under T-B**, the helper must create a real `Transaction__c` per deal and drive it to `'Closed'`.
  🔴 That fires `flows/Transaction_Stage_Closed_Sets_Status` (`CreateAndUpdate`) → `Status__c='Closed'`
  → `flows/Transaction_Complete_Close` → an Opportunity update **from inside the fixture** — and, via
  `TaskFanoutService`, **the 82-task Day-0 checklist per transaction**. At 251 deals that is ~20,600
  Task rows in a fixture. It will not run.

⇒ **T-A is not merely preferable; T-B is arguably untestable at this repo's mandated bulk volume**
(`.claude/rules/bulk-test-rule.md`, 251 records). State this to the user as the deciding fact, not as
a preference.

## 5.4 Item 2 — a suite-wide **compile** break, not an assertion break

`TestDataFactory.cls:1091` writes `Status__c = 'In Progress'` inside `approveUnderwriting`. Deleting
the field makes **`TestDataFactory` fail to compile**, and every test class in the org depends on it.
Same for `UnderwritingGateTest:153,157,221,225`.

🔴 **Therefore: the Apex edits and the field deletion must be in the SAME deploy payload, and there is
no partial state that compiles.** This is the exact class of failure this repo has recorded before for
stored→formula conversions. Also sweep `scripts/` (four seed scripts) — a seed break is silent until
someone runs it.

---

# 6. WAVE ORDER ACROSS ALL THREE ITEMS

The three items are **mostly independent**, with one hard coupling and one soft one.

🔴 **HARD COUPLING — items 1 and 2 both edit `approvalProcesses/Underwriting__c.Underwriting_Approval`,
which is ACTIVE.** Item 1 (U-A) **adds** `initialSubmissionActions`, `finalRejectionActions`,
`recallActions` and a third `finalApprovalActions` action; item 2 (a) **removes** the
`UW_Status_Approved` action from `finalApprovalActions`. **Do them as ONE edit to that file, in one
wave.** Two live-process edits where one will do is gratuitous risk.
✅ Action-block edits on an *active* process are proven in this repo — that is exactly what
`Sale_Decision_Approval:58-65` did on 2026-08-21.

⚠ **SOFT COUPLING — item 3 and item 1 both touch permission sets.** `DPEG_Acquisition_View` /
`DPEG_Acquisition_Edit` (item 1/2) and whichever sets grant Opportunity fields (item 3). A
PermissionSet deploy **replaces its whole `fieldPermissions` set**. Consolidate permission-set edits
into one pass per file, per the parallel-build protocol.

| Wave | Contents | Gate |
|---|---|---|
| **W0** | All measurements M-1…M-10 (§9). **No deploy.** Includes the org sweep for item 2 and the ORG-copy test read. | Blocks everything |
| **W1** | 🔵 Item 1 fields (`Underwriting__c.Approval_Pending__c`, + `LOI__c.Approval_Pending__c` if L-B) and item 3's `Opportunity.Transaction_Closed__c` — **fields only, inert** | after W0 |
| **W2** | 🔵 Workflow field updates: `workflows/Underwriting__c` (item 1 add), `workflows/LOI__c` (item 1), and item 2's **removal is NOT here** | fields must exist first |
| **W3** | 🔵 **The single combined edit to `Underwriting__c.Underwriting_Approval`** (item 1 additions + item 2's `UW_Status_Approved` removal) and the `LOI__c.LOI_Approval` edit (item 1). ⚠ Live-process edits. | after W2 |
| **W4** | 🔴 **BEHAVIOURAL READBACK — no deploy.** Submit → flag/status set + button gone → **RECALL** → cleared + button back → repeat for **reject**. On **one** object first (Underwriting), then the other. If recall does not clear, **revert; do not substitute a mechanism.** | Blocks W5 |
| **W5** | 🔵 Permission sets (item 1 grants + item 2 removals, **one pass per file**) | with or **before** W6 |
| **W6** | 🔵 FlexiPages: `Underwriting_Record_Page` (+ `LOI_Record_Page` if L-B). **LAST.** Read back and count the action entries. | 🔴 reversing W5/W6 hides every Submit button for everyone, silently |
| **W7** | 🟢 Item 2's Apex + seed edits **and** the workflow field-update deletion **and** the field destructive change — **one payload**, because nothing between them compiles | after W3 |
| **W8** | 🟢+🔵 Item 3: `TestDataFactory` helper + the `Transaction_Complete_Close` third `inputAssignment` + the new validation rule + (if fail-closed) the `NEXT_STAGE` repoint. ⚠ The **flow must land before or with the rule** or the first transaction close throws and rolls back a Transaction save. | last |

🔴 **R-0 CARRIES FORWARD: every deploy is an explicit component list.** Three previous cutovers staged
`<active>` flips in this tree, and a `--source-dir force-app` deploy would execute whatever is staged
in an order Salesforce chooses. Tell the concurrent session before W1. `git status` at the head of
this session showed a modified `agent-output/design-requirements.md`, six modified tabs, three
dashboards, two permission sets and eleven seed scripts — **count the tree yourself at execution
time; do not trust that list.**

---

# 7. OPEN DECISIONS THAT ARE GENUINELY THE USER'S

| # | Decision | Why it is theirs |
|---|---|---|
| **D-1** | **Item 1 / LOI: L-A (reuse `LOI_Status__c`) or L-B (new Checkbox)?** L-A is free and gives a rejection marker + a pending badge; its cost is that a **recall clobbers a `'Countered'` status**. | An accepted information loss on a live negotiation field. |
| **D-2** | **Field name:** `Approval_Pending__c` (symmetry with the two existing ones, deviates from the Boolean convention) or `Is_Approval_Pending__c` (conforms, no symmetry). One word. | A convention deviation the repo has already taken twice. |
| **D-3** | 🔴 **Item 2: option (a) child field only, or (b) also the `Opportunity.Underwriting_Status__c` mirror?** Recommendation **(a)**. (b) removes the market-data freeze's only trigger and a visible deal-page field with no replacement. | Different changes, different blast radii; §3.3. |
| **D-4** | **Item 3 carrier: T-A (stored flag) or T-B (`Primary_Transaction__c` lookup)?** Recommendation **T-A** — T-B is arguably untestable at 251 records (§5.3). | A schema decision with a reporting upside and a testing cost. |
| **D-5** | 🔴 **Item 3: fail-OPEN or fail-CLOSED on a deal with no transaction?** ~half of closes have none today (§4.2). Fail-closed makes `'About to Close'` effectively mandatory and needs `NEXT_STAGE` repointed. Recommendation **fail-CLOSED**. **Answer this before D-4.** | The single largest workflow change in this document. |
| **D-6** | **Rewrite the two red `LoiGateTest` methods onto `LOI__c.LOI_Approval`?** Not requested; §5.1 explains why item 1 (L-A) makes it natural and why it must not be folded in silently. | Scope. |
| **D-7** | Item 2 is **not** a policy. Confirm that `Transaction__c` (Stage + Status, harmonised and synced by `a8a1bb2`) and `LOI__c` (`Stage__c` + `LOI_Status__c`, deliberately decoupled) are **out of scope**. | §3.4 — the identical shape was solved the opposite way 24 hours ago. |
| **D-8** | `Disposition_Offer__c.Offer_Selection_Approval` is the one remaining approval with no pending flag (`:84`). In or out of item 1? Recommendation **out**. | Scope. |
| **D-9** | `scripts/seed-nda-loi-metrics.apex:30` seeds an LOI at `'Pending Approval'` with no approval behind it. Under L-A that row shows a permanently hidden Submit button. Fix the seed, or accept it? | Demo-data quality. |

---

# 8. THINGS I THINK ARE A BAD IDEA, STATED PLAINLY

**8.1 🔴 Do not treat a green deploy as item 1's acceptance criterion.** A `recallActions` block that
deploys and never fires leaves the flag stuck, the button hidden **permanently**, on an *unlocked*
record with no route to resubmit, and nothing logged anywhere — strictly worse than the noisy refusal
being fixed. `Sale_Decision_Approval:88-100` says this in capitals. **The acceptance criterion is a
real recall, on a real record, watched by a human.** If it cannot be run, do not ship item 1 — fall
back to today's behaviour, which is *safe but noisy*, not broken.

**8.2 ⚠ Item 2 may be worth less than it costs, and the user should hear that before approving it.**
`Underwriting__c.Status__c` is on **no layout, no FlexiPage, no report, no list view** (§3.2). No user
can see it today. Removing it buys schema hygiene and nothing else, at the price of a suite-wide
compile break (§5.4), a live-process edit, a destructive change, and a permanently reserved API name.
It is still the **right** change — the field is a strict-subset duplicate of `Stage__c` and one of its
three values is dead — but it is a **tidying** change, not a defect fix, and it should be scheduled as
one. **If the goal is "stop showing two status-ish things", the cheaper answer is the one-line
FlexiPage edit at `Opportunity_Record_Page:803`.**

**8.3 🔴 Do not remove `Opportunity.Underwriting_Status__c` (item 2 option b).** §3.3. It is not a
duplicate of anything on the Opportunity, it is the **only** trigger of the market-data freeze
(`Opportunity_UW_Approved_Notify:56` → `MarketDataSnapshotService:76`), and its obvious replacement
trigger (`UW_Approved__c`) is set by test fixtures, which would fire the freeze from test data —
precisely what `TestDataFactory.cls:1048-1049` deliberately avoids today.

**8.4 🔴 Do not gate `'Dead/Pass'` in item 3.** §4.5. It would strand every dying deal permanently.

**8.5 🔴 Do not build item 3 as a `Primary_Transaction__c` lookup without first pricing its 251-record
fixture.** §5.3. Creating a real Transaction per deal in a bulk fixture cascades into
`Transaction_Stage_Closed_Sets_Status` → `Transaction_Complete_Close` → an Opportunity update **from
inside the fixture** → 82 checklist Tasks per transaction. That is ~20,600 Task rows at
`PropertyAssetServiceTest`'s bulk volume.

**8.6 🔴 Do not implement item 3 as a check inside `StageAdvanceService`.** It would cover exactly one
of the routes to `'Closed Won'` and miss the Path, the API, list views, Data Loader and
`Transaction_Complete_Close` itself. `StageAdvanceService.cls:78-79` already records that
*"the declarative visibility rules that appear to constrain these buttons are a UX affordance only
and are trivially bypassed by calling the Apex directly"* — the same logic applies in reverse.

**8.7 ⚠ Do not delete anything in item 2's path except the field and its translation.** In particular
`workflows/Opportunity.workflow-meta.xml`'s `UW_Set_Status_Approved` (`:71`) stays — the retained
**inactive** `Opportunity.Underwriting_Approval` still references it by name, and deleting a
referenced field update breaks that file.

**8.8 ⚠ Do not run `RunLocalTests` as a deploy gate between W3 and W7.** Two `LoiGateTest` methods are
already red by construction (§5.1) and item 2 puts the suite through a deliberate compile break.
Baseline first, `RunSpecifiedTests` between, one full `RunLocalTests` at the end — against a baseline
you captured yourself.

**8.9 ⚠ Do not deploy the FlexiPages before the permission sets, and do not open either page in App
Builder.** A rule on an unreadable field evaluates FALSE and hides the button for everyone.
Separately, an App Builder save on `Disposition_Record_Page` has silently emptied an action list
**twice** in this repo, and a FlexiPage deploy **replaces** the org copy with no version history —
retrieve and diff seconds before deploying.

**8.10 ⚠ Do not "fix" `flows/Transaction_Stage_Closed_Sets_Status` or `Transaction_Complete_Close`'s
`Status__c` trigger condition while working on item 3.** That file's `:21-25` records an explicit user
decision to key on `Status__c`, not `Stage__c`.

---

# 9. WHAT CANNOT BE KNOWN WITHOUT MEASURING THE ORG

Each is a genuine measurement, not a gap in the reading. **Do not let any of these be answered by
inference from this document.**

| ID | Measurement | How |
|---|---|---|
| **M-1** | 🔴 **Was `hide-submit-while-pending`'s behavioural readback ever run?** Submit a test Disposition → is `Approval_Pending__c` TRUE and the button gone? **Recall** it → FALSE and back? | UI + SOQL, on `Disposition__c`, before item 1 relies on the mechanism |
| **M-2** | Which approval processes are **Active** in the org right now, and the pending `ProcessInstance` count for each? Two repo files disagree about `Opportunity.LOI_Approval` (C8). | `SELECT Id, Name, TableEnumOrId, State FROM ProcessDefinition`; `SELECT COUNT() FROM ProcessInstance WHERE Status='Pending'` grouped by definition |
| **M-3** | Does anything in the ORG — with no repo file — write `LOI_Status__c = 'Pending Approval'`? | Tooling `FlowDefinitionView` / `WorkflowFieldUpdate`; `SetupAuditTrail`. `profiles/**` and `settings/**` are force-ignored here, so a repo grep cannot see everything |
| **M-4** | 🟢 **Is approval/lock state reachable by a FORMULA field on a custom object at 67.0?** If yes, both halves of item 1 collapse to one formula field + the FlexiPage edit. | The cheapest question in this document. Ask it first. |
| **M-5** | Is `Underwriting__c.Submit_for_Approval` actually rendered on a record that is locked by its own pending approval? | Open one as the deal-driver persona, **not as an admin** |
| **M-6** | 🔴 Every **report, dashboard, list view and formula** in the ORG referencing `Underwriting__c.Status__c` **and** `Opportunity.Underwriting_Status__c`. Reports do not block field deletion here and fail **silently** afterwards. | Tooling API / Setup "Where is this used?" |
| **M-7** | What fraction of live `'Closed Won'` deals actually have a `Transaction__c`? The repo says "half"; that word was written 2026-08-27. | `SELECT COUNT() FROM Opportunity WHERE StageName='Closed Won' AND Id NOT IN (SELECT Opportunity__c FROM Transaction__c WHERE Opportunity__c != null)` |
| **M-8** | 🔴 The ORG's copy of `LoiGateTest`, `UnderwritingGateTest`, `PropertyAssetServiceTest`, `StageAdvanceServiceTest`, `OpportunityApprovalServiceTest` — **method by method**, against the repo. | Tooling `ApexClass.Body`, or `ApexTestResult` grouped by `MethodName`. The last cutover's three "expected failures" did not exist |
| **M-9** | Classify all 100 `'Closed Won'` occurrences across 34 test classes as **insert / update / read**. Only updates are exposed to item 3. | grep + read |
| **M-10** | Same classification for the 51 occurrences across 17 seed scripts. | grep + read |
| **M-11** | Do the two named principals hold FLS on `Underwriting__c.Stage__c` / the new flag, and can a **non-owning** principal open an `Underwriting__c` row? (OWD Private, zero sharing rules on that object.) | `UserRecordAccess`; permission-set assignment check. Use the **non-administrator** principal or the run is vacuous |
| **M-12** | Repo↔org diff for every component in §6, from a **check-only deploy's per-component `Changed`/`Unchanged` report**. ⚠ The **report** is the deliverable, not the green verdict — byte-identical components report `Unchanged` and are *skipped, never validated*. | `sf project deploy start --dry-run` with an explicit component list |

---

# 10. ADMIN vs DEVELOPER SPLIT

## 10.1 Honest statement of scope

**Item 1 is ~95% declarative** (fields, workflow field updates, approval-process elements, FlexiPage
criteria, permission sets). Its only Apex is **not changing `OpportunityApprovalService`** — the guard
at `:296-298` stays exactly as written.

**Item 2 is mixed**: declarative removal, but the field deletion forces Apex edits in
`TestDataFactory` and `UnderwritingGateTest` **in the same payload**.

**Item 3 is mixed**: one field + one flow edit + one validation rule (admin), one `TestDataFactory`
helper and, if fail-closed, one `NEXT_STAGE` map entry (developer).

**Complexity routing:** all three are `salesforce-admin` + `salesforce-developer`. None involves
integration, LDV, Named Credentials, multi-object schema design or a security model — so neither
architect variant is indicated.

## 10.2 🔵 PROMPT FOR `salesforce-admin`

```
Execute the declarative half of the three items described in
agent-output/three-gaps-design-2026-09-02.md. Read that document first; it is the specification.

🔴 STOP CONDITION: do not begin W1 until the user has answered D-1 through D-5 in §7. D-1 and D-4
decide what you build; D-5 decides what the item 3 rule says. D-3 decides how big item 2 is.

Record `mcp=complete|unavailable` + `mcp_tools=<list>` per metadata type before any deploy, and
load the matching per-type skill. `.mcp.json` here configures only the `salesforce` server, so
`salesforce-api-context` is expected to be unavailable - make a REAL attempt, record the result,
fall back to the skill.

BLOCKING PRECONDITION (R-0): every deploy is an EXPLICIT component list. No directory-wide or
repo-wide deploy until all three items complete. Tell the concurrent session before W1 - three
prior cutovers staged <active> flips in this tree. Run `git status` yourself; do not trust any
file count written in the design document.

W0 - VERIFICATION ONLY, NO DEPLOY. Complete M-1 through M-12 in §9 and report each individually.
     🔴 M-1 and M-4 are stop conditions.
     M-1: was hide-submit-while-pending's recall readback ever actually run on Disposition__c?
          If not, item 1 is standing on an unproven mechanism and you must prove it there FIRST.
     M-4: is approval/lock state reachable by a FORMULA field? If YES, report it - item 1
          collapses to one formula field plus the FlexiPage edit and this design is re-cut.
     M-6 is a stop condition for item 2: reports do NOT block field deletion in this org and
          fail SILENTLY afterwards. Sweep the ORG, not the repo.
     SAVE the org copies you retrieve for both FlexiPages and both validation rules - they are
     the rollback artifacts.

W1 - fields only, inert: Underwriting__c.Approval_Pending__c (and LOI__c.Approval_Pending__c if
     D-1 = L-B), Opportunity.Transaction_Closed__c. Copy the file shape from
     objects/Disposition__c/fields/Approval_Pending__c.field-meta.xml. Keep the XML comment
     INSIDE the root element. State in each file: system field, written ONLY by approval-process
     actions (or, for Transaction_Closed__c, ONLY by flows/Transaction_Complete_Close), never
     hand-edited, and that Transaction_Closed__c is a MONOTONIC LATCH that nothing clears.

W2 - workflow field updates. workflows/Underwriting__c.workflow-meta.xml: Set_UW_Approval_Pending
     (literalValue 1) + Clear_UW_Approval_Pending (0). workflows/LOI__c.workflow-meta.xml: per
     D-1. Copy the element set exactly from workflows/Disposition__c.workflow-meta.xml
     (notifyAssignee=false, operation=Literal, protected=false, reevaluateOnChange=false).
     🔴 Do NOT add a <rules> element to either file - both objects' workflow files carry an
     explicit prohibition and an active rule would fake an approval.

W3 - THE APPROVAL PROCESSES. 🔴 ONE combined edit to
     approvalProcesses/Underwriting__c.Underwriting_Approval.approvalProcess-meta.xml:
       ADD initialSubmissionActions, finalRejectionActions, recallActions
       ADD Clear_UW_Approval_Pending as a THIRD action inside the EXISTING finalApprovalActions
       REMOVE the UW_Status_Approved action from finalApprovalActions   <- this is item 2
     Element order is alphabetical: initialSubmissionActions after finalRejectionRecordLock and
     before label; recallActions after processOrder and before recordEditability. Copy the shape
     from Disposition__c.Sale_Decision_Approval:276-289.
     🔴 DO NOT CHANGE: active, allowRecall, allowedSubmitters, approvalPageFields, approvalStep,
     entryCriteria, finalApprovalRecordLock, finalRejectionRecordLock, processOrder,
     recordEditability (stays AdminOnly), showApprovalHistory. Do not reorder UW_Stage_Approved.
     Then the LOI__c.LOI_Approval edit per D-1.

W4 - 🔴 BEHAVIOURAL READBACK. NO DEPLOY. On Underwriting__c FIRST, alone:
       1. submit a real record at Stage__c = 'In Progress' as the deal driver;
       2. confirm the flag went TRUE and Submit for Approval is GONE from the page;
       3. RECALL it from the Approval History component in the page header;
       4. confirm the flag went FALSE and the button is BACK;
       5. repeat 1-2, then REJECT as a principal, and confirm the flag cleared.
     If step 4 fails, REVERT this file. Do not substitute another mechanism. Only after all five
     pass, repeat on LOI__c.
     ⚠ Use the deal-driver persona and a NON-ADMINISTRATOR principal. An admin proves nothing.

W5 - permission sets. ONE pass per file. Grant the new flag read-only, mirroring
     Underwriting__c.Stage__c's matrix (DPEG_Acquisition_View:1700, DPEG_Acquisition_Edit:1758,
     Opportunity_Stage_Actions_Access:98). In the SAME pass remove the Underwriting__c.Status__c
     blocks (DPEG_Acquisition_View:1705, DPEG_Acquisition_Edit:1763) if D-3 = (a).
     🔴 A PermissionSet deploy REPLACES its whole fieldPermissions set. Diff against HEAD and
     confirm zero unintended deletions before deploying.

W6 - FlexiPages, LAST. flexipages/Underwriting_Record_Page.flexipage-meta.xml: append a THIRD
     criterion to the Underwriting__c.Submit_for_Approval entry (:50-62),
     {!Record.Approval_Pending__c} EQUAL false (lowercase false - the proven polarity on this
     org; NE against a boolean is NOT proven), booleanFilter '1 AND 2' -> '1 AND 2 AND 3'.
     LOI_Record_Page only if D-1 = L-B (append a 6th criterion; the existing five stay as they
     are - criterion 2 already reads LOI_Status__c NE 'Pending Approval').
     🔴 EDIT THE XML DIRECTLY. DO NOT OPEN EITHER PAGE IN APP BUILDER and do not touch
     enableActionsConfiguration. Retrieve-and-diff against the ORG seconds before deploying.
     After deploying, READ THE PAGE BACK and count the action entries.

W7 - item 2's remaining declarative acts, only after W3 landed and only after the developer
     stream's Apex is in the SAME payload: delete the UW_Status_Approved fieldUpdates block from
     workflows/Underwriting__c.workflow-meta.xml, then destructiveChanges for
     objects/Underwriting__c/fields/Status__c.field-meta.xml and
     objectTranslations/Underwriting__c-en_US/Status__c.fieldTranslation-meta.xml, and edit
     manifest/package.xml:768.
     🔴 DELETE NOTHING ELSE. In particular workflows/Opportunity.workflow-meta.xml's
     UW_Set_Status_Approved (:71) STAYS - the retained inactive Opportunity.Underwriting_Approval
     still references it by name.
     🔴 The API name stays RESERVED until the field is ERASED in Setup.

W8 - item 3. Deploy in this order, as one list:
       1. flows/Transaction_Complete_Close.flow-meta.xml - add a THIRD inputAssignments to the
          EXISTING Close_Opportunity element (:42-69) writing Transaction_Closed__c = true.
          Change NOTHING else in that flow - its Status__c trigger condition is an explicit user
          decision recorded in Transaction_Stage_Closed_Sets_Status:21-25.
       2. the new validation rule on Opportunity, per D-5.
     🔴 THE FLOW MUST LAND BEFORE OR WITH THE RULE. Reversed, the first transaction close throws
     and rolls back the Transaction save - the exact failure mode
     Contract_Signed_Before_Closed_Won:16-21 already documents for this flow.
     If D-5 = fail-closed, coordinate with the developer stream on the NEXT_STAGE repoint.
     🔴 DO NOT gate 'Dead/Pass'. Scope the rule to ISPICKVAL(StageName,'Closed Won') only.

Author NO validation rule, NO field and NO picklist value not named above.
```

## 10.3 🟢 PROMPT FOR `salesforce-developer`

```
Support the Apex half of the three items described in
agent-output/three-gaps-design-2026-09-02.md. Read that document first.

🔴 STOP CONDITION: do not write anything until D-3, D-4, D-5 and D-6 in §7 are answered.

W0 (verification, feeds the admin stream's W0):
  - M-8: 🔴 read the ORG's copy of LoiGateTest, UnderwritingGateTest, PropertyAssetServiceTest,
    StageAdvanceServiceTest and OpportunityApprovalServiceTest METHOD BY METHOD and diff against
    the repo. The last cutover found the org's UnderwritingGateTest had different method names
    and was passing against OLD behaviour, so three predicted failures never existed. Report the
    diff before anyone treats §5 as fact.
  - M-9 / M-10: classify all 100 'Closed Won' occurrences across 34 test classes, and all 51
    across 17 seed scripts, as INSERT / UPDATE / READ. Only UPDATES are exposed to item 3 -
    ISCHANGED is false on insert, so an insert-at-Closed-Won fixture is immune.
  - M-7: what fraction of live Closed Won deals actually carry a Transaction__c? The repo says
    "half" (StageAdvanceService.cls:135-140, written 2026-08-27). Measure it; D-5 depends on it.
  - Capture a BASELINE ApexTestResult run with timestamps. Count the shared working tree
    yourself with `git status`; do not trust any figure in this document.

ITEM 1 - 🔴 WRITE NO APEX. OpportunityApprovalService's pending guard (:296-298,
  'This record is already pending approval.') STAYS EXACTLY AS WRITTEN. A hidden button is a UX
  affordance, not a control, and the platform Submit button on both objects' layouts
  (Underwriting__c-Underwriting Layout:90-94, LOI__c-LOI Layout:209) carries NO visibility rules
  at all. Two comments become stale and should be corrected IN PLACE, not deleted:
  OpportunityApprovalService.cls:290-295 and OpportunityApprovalControllerTest.cls:118 both say
  the LOI 'Pending Approval' criterion is INERT. Under D-1 = L-A it stops being inert.
  No test can observe a FlexiPage visibility rule or a recallActions firing. If you write a test
  class header touching this, SAY SO there so review does not demand a test that cannot exist.

ITEM 2 - 🔴 THIS IS A SUITE-WIDE COMPILE BREAK AND THERE IS NO INTERMEDIATE STATE THAT COMPILES.
  Deleting Underwriting__c.Status__c breaks TestDataFactory.cls:1091 (approveUnderwriting writes
  Status__c = 'In Progress'), and every test class depends on TestDataFactory. Also
  UnderwritingGateTest.cls:153, :157, :221, :225.
  Edit, in ONE payload with the admin stream's W7:
    - TestDataFactory.cls:1091 - drop the Status__c assignment (keep Stage__c = 'Approved')
    - UnderwritingGateTest - remove Status__c from the two SELECTs and the two assertions.
      ⚠ principalRejectionLeavesTheUnderwritingInProgressAndClearsNothing's DOCSTRING (:189)
      says "the replacement process has NO finalRejectionActions at all". Item 1 ADDS one.
      Correct that sentence IN PLACE - do not delete it. Repo convention.
    - UnderwritingSelector.cls:185-188 - the warning comment names a field that will not exist.
      Correct in place.
    - scripts/seed-fsd-02-flagship-shallow.apex:149, -03:56, -04:61, -05:86 - drop Status__c.
      A seed break is SILENT until someone runs it.
  🔴 DO NOT TOUCH UnderwritingApprovalStampService. It writes the PARENT's
  Opportunity.Underwriting_Status__c (:132-136), a different field on a different object, and it
  survives option (a) unchanged. If D-3 = (b), STOP and come back - that is a different design.

ITEM 3:
  1. Add a FIFTH member to TestDataFactory's named gate-satisfaction helper family (see the
     block comment at :895-901 for the convention and the reason it exists). Under D-4 = T-A it
     is ONE field write per deal (Transaction_Closed__c = true), batched into ONE DML, shaped
     exactly like signContract (:1216-1232).
     🔴 DO NOT create real Transaction__c rows in this helper. At PropertyAssetServiceTest's
     251-record bulk volume that cascades through Transaction_Stage_Closed_Sets_Status ->
     Transaction_Complete_Close -> an Opportunity update FROM INSIDE THE FIXTURE, and via
     TaskFanoutService into 82 checklist Tasks per transaction - roughly 20,600 Task rows.
  2. Repoint the fixtures M-9 identified as UPDATE-into-Closed-Won to call the new helper.
     Known: PropertyAssetServiceTest.close() (:91-97, used by the 251-record bulk tests) and
     StageAdvanceServiceTest.advanceMovesLoiToPsaAndPsaToClosedWon (:66-110).
     ⚠ NdaDealProgressionGateTest (:108-112) already EXPECTS a block - check whether it asserts
     the NDA message or merely that something threw. If the latter it will pass VACUOUSLY.
  3. ONLY IF D-5 = fail-closed: repoint StageAdvanceService.NEXT_STAGE's
     'Under Contract (PSA)' => 'Closed Won' entry to 'About to Close'.
     🔴 Read StageAdvanceService.cls:135-152 first - that pair is load-bearing for
     PropertyAssetService.ensureOnClosedWon and for DealFolderService.CLAIM_STAGES, and the file
     says renaming one key without the other silently re-opens a route-vs-state defect.
     Annotate the consequence in place: the "half the closes carry no Transaction__c" population
     that justifies PropertyAssetService living on OpportunityReviewTrigger disappears. DO NOT
     act on that - just record it.
     advanceMovesLoiToPsaAndPsaToClosedWon's SUBJECT changes, not just its fixture.

ITEM 3 / D-6 (only if authorised): rewriting LoiGateTest's two red methods onto
  LOI__c.LOI_Approval is a SEPARATE, explicitly-authorised chore. If you do it:
  🔴 PROTECT directLoiToUnderwritingUpdate_isAllowedByCarveOut1_notByApproval (:106-121). It is
  the ONLY remaining pin on No_Backward_Stage_Movement CARVE-OUT 1 and its own docstring
  (:89-104) explains why its red sibling never pinned it. Do not delete it while cleaning up
  its neighbour.

Do NOT run RunLocalTests as a deploy gate between the approval-process edit and item 2's
payload. Two LoiGateTest methods are red by construction and item 2 puts the suite through a
deliberate compile break. RunSpecifiedTests in between; one full RunLocalTests at the end,
against the baseline you captured yourself.

WRITE NO NEW VALIDATION RULE, NO NEW FIELD and NO NEW SERVICE CLASS. If any appears necessary,
that is an unanswered decision in §7 - report it rather than building it.
```
