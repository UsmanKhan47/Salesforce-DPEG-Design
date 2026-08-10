# Design Requirements — Disposition Foundations (TRANCHE 2)

**Source of truth:** `docs/DPEG-Stage-by-Stage.docx` Part 2 (extract: scratchpad `spec-disposition.md`)
**Binding decisions:** `agent-output/stage-by-stage-decisions.md` (D1–D10) — not re-litigated below
**Evidence base:** `agent-output/stage-by-stage-audit-disposition.md`
**Conventions:** `ARCHITECTURE.md` §1 (naming), §2 (Apex layering, `WITH SYSTEM_MODE` table), §5 (LWC)
**Date:** 2026-08-09
**Status:** awaiting Gate 1

---

## 0. FLAG AT GATE 1 — questions whose answers change this design

Seven. Q1, Q2, Q3, Q6 and Q7 change what gets built. Q4 and Q5 are answered here with a
recommendation and need only a yes/no.

| # | Question | Why it changes the design | Recommendation |
|---|---|---|---|
| **Q1** | **Which record type does the Sell Meter "Initiate" / "Override" button create?** The document starts BOTH paths identically at Disposition Readiness (spec 3 and 108), so on-market vs off-market is not knowable at creation. | Three different builds. (a) Apex stamps `On_Market` always → deterministic, one line, repo-visible. (b) Prompt the user to choose → needs a custom modal (`LightningModal`); `LightningConfirm` cannot carry a three-way answer. (c) Leave `RecordTypeId` null → the platform applies the **running user's profile default**, and profiles are `.forceignore`d, so the behaviour is org state this repo cannot see, set or verify. | **(a)** — `DispositionService.findOrCreate` stamps `On_Market` explicitly. An off-market deal is switched by editing the record type early, while the record is still at Readiness. This is what D5 anticipated ("record-type change on a live record is possible but awkward"). |
| **Q2** | **What should the yellow-band "Override" button actually do?** (audit open question 6 — the document says only "shown as Override"). | Determines whether new metadata is needed. Confirm-only = LWC change alone. "Record an override reason" = a new field + a modal. "Require approval" = a fourth approval process. | **Confirm-then-create.** `LightningConfirm.open()` naming the days-to-peak, then the identical `findOrCreate` call with a distinct success toast. No new field, no new approval — the document asks for neither, and Rule 1 forbids inventing them. |
| **Q3** | **A `Disposition__c` can have many `Wire__c` children. What does "the wire check is complete" mean?** (a) the most recent Wire is complete, (b) at least one is, (c) all are. | Decides the rollup flow's logic and therefore what the validation rule actually enforces. | **(a) the most recent Wire** — because that is already the definition the UI uses (`WireSelector.selectMostRecentByDispositionId`, `WireController.getWire`). Any other choice makes the badge the user sees and the gate that blocks them disagree. |
| **Q4** | **Does the wire gate block SUBMISSION of the Closing approval, or only the Closing → Completed transition?** | Entry criteria vs validation rule. | **Only Closing → Completed**, via a validation rule. Putting the flag in the approval's `entryCriteria` means an unmet gate surfaces as *"no applicable approval process was found"* — a misleading platform error the user cannot act on. Instead the flag is added to the approval's `approvalPageFields` so the approver **sees** the wire state when deciding. |
| **Q5** | **What does a Disposition sitting at the new `LOI` or `PSA` stage do before Tranche 3?** (the prompt asks for this explicitly) | Determines whether a placeholder component is built now. | **Nothing new is built.** See §6 — the stage is valid and path-rendered, the record page falls back to the Details field section, and the Path step's guidance text names where the negotiation currently lives. No placeholder LWC. |
| **Q6** | **Migrate every existing `Disposition__c` row to `On_Market`?** Adding record types leaves existing rows on the **Master** record type, which shows all ten stage values and matches **neither** new Path. | Without the migration, every existing disposition renders with no Path and an unrestricted stage picklist. It is a mass update on live rows, so it needs an explicit yes. | **Yes, all rows → `On_Market`.** Every disposition built to date is broker-listed by construction (BOV Outreach / Active Listing are the only stages with UI). |
| **Q7** | **Grant the disposition personas read access to `NDA__c`?** Required by the `bovOutreach` pill fix (item 5b). `NDA__c` is granted **only** by `DPEG_Acquisitions`, `DPEG_Acquisition_Edit` and `DPEG_Acquisition_View` — `DPEG_Disposition_Edit`/`View` grant it **not at all**. | Without it, a `WITH USER_MODE` NDA read throws `QueryException`, which `BovController.getOutreachSummary`'s catch converts into the generic read-failure message — **blanking the whole BOV Outreach tile** for every disposition-only user. That is a worse outcome than today's hard-coded lie. | **Yes** — grant `NDA__c` read + `Status__c` read on `DPEG_Disposition_View` and `DPEG_Disposition_Edit`; **and also** make the NDA read fail-soft so a missing grant degrades the pill to "unknown" instead of killing the tile. Both, not either. |

**Also raised, not blocking:** the Active Listing Path guidance text (`Disposition_Path…:9`) says *"6-week
marketing clock… Week 4 YELLOW… Week 6 Hard Stop"* while the document says ~2 months with a month-1
check — decisions-file OPEN #2. The traction monitor is out of scope, so **this text is copied forward
verbatim and NOT edited**. Editing it would silently pre-empt an open question.

---

## 1. PREMISE CORRECTIONS — three findings that reduce or redirect the stated scope

Recon against the metadata contradicted three assumptions carried in from D5 and the brief. All three
make the tranche cheaper or safer; none expands it.

### 1.1 The LWCs do **not** need to branch on record type (D5's consequence list is over-stated)

D5 says `lwc/dispositionMain` + `lwc/dispositionSidebar` "will need to branch on record type too".
They do not — because the per-record-type value sets this tranche creates are **disjoint for every
path-specific stage**:

| Stage value | On_Market | Off_Market |
|---|---|---|
| BOV Outreach, Active Listing, Call for Offers | ✔ | ✘ |
| NDA, Disposition Offer | ✘ | ✔ |
| Disposition Readiness, LOI, PSA, Closing, Completed | ✔ | ✔ |

Reading `Disposition_Stage__c` therefore already tells the component which path it is on for every
stage that renders anything path-specific. Record-type awareness becomes necessary only when a
**shared** stage must render differently per path — which does not arise in this tranche (the one known
case, the off-market PSA-Executed → +Finance notification, is a Flow and is deferred by D9).

**Consequence:** no `getObjectInfo` / `RecordTypeId` wiring, no new `@wire`, no new Apex, and the two
Jest suites keep their existing shape. If a shared stage later diverges, add it then.

### 1.2 The record page needs **no** new flexipage and **no** record-type page assignment

`applications/Disposition.app-meta.xml:3-11` assigns `Disposition_Record_Page` by
`<pageOrSobjectType>Disposition__c</pageOrSobjectType>` with **no `<recordType>` element**, so one page
serves both record types automatically. This is the same shape Opportunity uses for `Land` /
`Commercial`. One small edit to the page's *visibility rules* is still required (§4.6) — but no second
flexipage and no assignment change.

### 1.3 🔴 None of the three approval processes can be submitted as things stand

`layouts/Disposition__c-Disposition Layout.layout-meta.xml:52-89` — the `platformActionList` contains
`Edit, Clone, Delete, LogACall, NewEvent, NewTask, SendEmail`. **There is no `Submit` button.** The
record page's highlights panel is configured `enableActionsConfiguration = false`
(`Disposition_Record_Page…:11-12`), so it inherits that list verbatim.

Deploying three approval processes without adding the `Submit` standard button to the layout ships
**three approvals nobody can start** — metadata that deploys green, tests green, and does nothing.
Adding it is in scope (§4.7).

⚠ Related trap (recorded, not proposed): **do not** "fix" this by enabling Dynamic Actions on
`Disposition_Record_Page`. Enabling Dynamic Actions replaces the inherited layout action list
wholesale, which on three pages in this repo silently deleted Edit/Delete/Clone. Add the button to the
**layout**.

---

## 2. WHAT WAS REQUESTED (scope statement)

Six items, all explicitly named in the brief:

1. Record types `On_Market` / `Off_Market` on `Disposition__c`, each with its own Path and its own
   `Disposition_Stage__c` value set; plus profile/permission-set assignment and a default for existing rows.
2. The five missing stage values, plus the two per-record-type restrictions.
3. Three approval processes on `Disposition__c` (Sale decision, Broker selection, Closing) — two existing
   named approvers, `FirstResponse`, submitter = owner, mirroring the deployed Opportunity pair (D10).
4. The wire-complete gate.
5. Two live defects: the dead "Override" button, and the hard-coded NDA pill.
6. A server-side sell-meter assertion in `DispositionService.findOrCreate`.

**Explicitly excluded and not designed below:** all 14 notifications (D9); the disposition LOI and PSA
records (Tranche 3 / D6); the `NDA__c` rework — `Declined`, `Party_Role__c`, the `Pending` → `Not Sent`
rename, counter-signature, the all-signed gate (Tranche 3 / D7); Call-for-Offers email matching
(Tranche 4); the Active-Listing traction monitor and broker change (blocked on OPEN #2). No validation
rules beyond the one wire gate that was asked for. No permission sets beyond edits to the three that
already grant `Disposition__c`.

---

## 3. THE COMBINED STAGE VALUE SET (the load-bearing detail)

`Disposition_Stage__c` is `<restricted>true</restricted>` with `<sorted>false</sorted>`, so **the order
of `<value>` elements in the master value set is the display order and the Path order**, and record
types cannot reorder it — they can only include or exclude.

**A single master ordering satisfies both paths.** Verified: no pair of stages is wanted in one order
on-market and the opposite order off-market.

| # | Value | Status | On_Market | Off_Market |
|---|---|---|---|---|
| 1 | `Disposition Readiness` | exists (master default) | ✔ **default** | ✔ **default** |
| 2 | `BOV Outreach` | exists | ✔ | — |
| 3 | `Active Listing` | exists | ✔ | — |
| 4 | `Call for Offers` | **NEW** | ✔ | — |
| 5 | `NDA` | **NEW** | — | ✔ |
| 6 | `Disposition Offer` | **NEW** | — | ✔ |
| 7 | `LOI` | **NEW** | ✔ | ✔ |
| 8 | `PSA` | **NEW** | ✔ | ✔ |
| 9 | `Closing` | exists | ✔ | ✔ |
| 10 | `Completed` | exists | ✔ | ✔ |

Filtered, that yields exactly the two required sequences:
- **On-market (8):** Readiness → BOV Outreach → Active Listing → Call for Offers → LOI → PSA → Closing → Completed
- **Off-market (7):** Readiness → NDA → Disposition Offer → LOI → PSA → Closing → Completed

Five values added, **zero removed** — so the standing picklist-removal sweep rule is not triggered.

⚠ **The brief's sequences are authoritative over the document's prose.** The document narrates a
"Buyer NDA" and a "Disposition Offer" inside the on-market path too (spec 26, 47), but as **records**
surfaced during other stages, not as stages. `NDA` and `Disposition Offer` are therefore off-market
stage values only. Do not "helpfully" add them to `On_Market`.

⚠ **Adding a value to a restricted picklist makes it globally selectable until the per-record-type
restriction lands.** Both must ship in **one deployment** (§7 Deploy 1) so that window is zero.

⚠ **Apex compiles against a picklist regardless of which values exist**, so a code-first deploy would
go green and then throw `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` at runtime. Metadata first, verified
in the org, before any Apex or seed data references the new values.

---

## 4. 🔵 ADMIN / DECLARATIVE WORK

Routing note: this is multi-object schema + security-model + record-type architecture on a
`sharingModel = Private` object with three new approval processes. Per the CLAUDE.md complexity gate
this sits with **`salesforce-solution-architect`**, not `salesforce-admin`.

### 4.1 Picklist — `Disposition_Stage__c`

Add the five new values from §3, **in the positions shown**, keeping `<restricted>true</restricted>`
and `<sorted>false</sorted>` unchanged. Do not alter the existing five values, their labels, or
`Disposition Readiness`'s `<default>true</default>`.

File: `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml`

### 4.2 Record types — `On_Market`, `Off_Market`

New: `objects/Disposition__c/recordTypes/On_Market.recordType-meta.xml`, `…/Off_Market.recordType-meta.xml`

- `<active>true</active>`; labels `On Market` / `Off Market`; `<description>` naming the path each serves.
- `<picklistValues>` for **`Disposition_Stage__c`** — only the values in that record type's column in §3;
  `Disposition Readiness` carries `<default>true</default>` in **both**.
- 🔴 `<picklistValues>` for **`Sell_Decision_Trigger__c` as well** — a record type file must enumerate
  **every** picklist on the object or values are silently dropped from that type. `Disposition__c` has
  exactly two picklists today. Enumerate all four `Sell_Decision_Trigger__c` values
  (`Sell Meter Green` default, `Principal Decision`, `Fund Maturity`, `Market Opportunity`) unchanged in
  both files. Precedent: `objects/Opportunity/recordTypes/Commercial.recordType-meta.xml` enumerates
  eight picklists.
- No `businessProcess` — that element is for Opportunity/Case/Lead/Solution only.

### 4.3 New field — `Disposition__c.Wire_Verification_Completed__c`

Checkbox, `<defaultValue>false</defaultValue>`, `<description>` stating it is **derived** — maintained by
the `Wire_Verification_Rollup` flow from the disposition's most recent `Wire__c`, and read by the
`Wire_Complete_Before_Completed` validation rule. Do not hand-edit.

Naming check against `ARCHITECTURE.md` §1: rule 4 (`<Subject>_<PastParticiple>` — the same shape as the
existing `PSA_Executed__c` and `Wire__c.Verbal_Verification_Completed__c`) ✔; rule 9 prohibition 1 (not
identical to an object name) ✔; prohibition 2 (the name reads Boolean and the field is Boolean) ✔.

### 4.4 Paths — replace the single `__MASTER__` path with two

Today: `pathAssistants/Disposition_Path.pathAssistant-meta.xml:35` is `<recordTypeName>__MASTER__</recordTypeName>`.

- Set `Disposition_Path` to `<active>false</active>` (deactivate; do not delete — it is the record of
  the current guidance text).
- New `Disposition_Path_On_Market` — `entityName Disposition__c`, `fieldName Disposition_Stage__c`,
  `recordTypeName On_Market`, eight steps in §3 order.
- New `Disposition_Path_Off_Market` — same, `recordTypeName Off_Market`, seven steps.

Step content — **existing steps are copied forward byte-identical** (fields *and* `<info>` text), new
steps are text-only:

| Stage | `fieldNames` | `<info>` |
|---|---|---|
| Disposition Readiness (both) | `Property_Asset__c` | copy verbatim from `Disposition_Path:32` |
| BOV Outreach (on) | `Package_Sent__c`, `Submission_Deadline__c` | copy verbatim from `:15` |
| Active Listing (on) | `Selected_Broker__c` | copy verbatim from `:9` — **do not edit** (see §0, OPEN #2) |
| Call for Offers (on) | *(none)* | new — the call-for-offers date lives on `Broker_Listing__c.Call_For_Offers_Date__c`, which is not a `Disposition__c` field and so cannot be a Path field. Say that in the text. |
| NDA (off) | *(none)* | new — one `NDA__c` per party via the existing `NDA__c.Disposition__c` lookup. State that the four-state model and the all-signed gate arrive in a later change (D7). |
| Disposition Offer (off) | *(none)* | new — offers are captured on `Disposition_Offer__c`. |
| LOI (both) | *(none)* | new — **the Tranche-3 seam, see §6.** |
| PSA (both) | *(none)* | new — **the Tranche-3 seam, see §6.** |
| Closing (both) | `PSA_Executed__c`, `Title_Company__c` | copy verbatim from `:21` |
| Completed (both) | `Closing_Date__c`, `Net_Sale_Proceeds__c` | copy verbatim from `:27` |

⚠ `PSA_Executed__c` stays on the **Closing** step exactly where it is today. Moving it to the new PSA
step is defensible but changes deployed behaviour for zero requested benefit.

### 4.5 Validation rule — the wire gate

`objects/Disposition__c/validationRules/Wire_Complete_Before_Completed.validationRule-meta.xml`

```
AND(
  ISPICKVAL(Disposition_Stage__c, 'Completed'),
  OR(ISNEW(), ISCHANGED(Disposition_Stage__c)),
  NOT(Wire_Verification_Completed__c)
)
```

- `errorDisplayField`: `Disposition_Stage__c`
- Message: *"The wire verification is not complete. All six wire confirmation fields must be confirmed on
  the Wire record before this disposition can be marked Completed."*

**Why this shape:**
- `OR(ISNEW(), ISCHANGED(...))` gates the transition **and** closes the create-at-Completed hole, without
  trapping rows already sitting at Completed (whose every subsequent edit would otherwise be blocked).
  Same shape as the deployed `Property_Registry__c.Winning_Lead_Required`.
- **Firing surface is clean.** `Disposition_Stage__c` is written by nothing but user edits — the Path, the
  Details section and inline edit. Grep confirms **no Apex, no flow and no approval field update writes
  it** (the 66 files referencing it are selectors, tests, reports, profiles and metadata). So the rule
  reaches every real writer and its message surfaces natively in the Path UI. This is also why the three
  approval processes below carry **no** `finalApprovalActions` — an approval field update would bypass
  validation rules entirely.
- 🔴 **Blast radius of `ISNEW()`:** any existing test or seed script that inserts a `Disposition__c`
  directly at `Completed` will start failing. The developer/testing agents must sweep
  `TestDataFactory.createDispositions`, `DispositionSelectorTest`, `DispositionControllerTest`,
  `BovControllerTest`, `WireServiceTest`, `WireControllerTest` and the disposition seed scripts. If the
  user prefers to avoid that sweep, drop `ISNEW()` and accept the create-at-Completed hole — say so at
  Gate 1.

### 4.6 Flexipage — stop the new stages rendering a blank page

`flexipages/Disposition_Record_Page.flexipage-meta.xml` currently splits the main region on one test:

- `flexipage_fieldSection` ("Details") visible when `Disposition_Stage__c` **EQUAL** `Disposition Readiness`
- `c_dispositionMain` visible when `Disposition_Stage__c` **NE** `Disposition Readiness`

`dispositionMain` renders content for `BOV Outreach`, `Active Listing`, `Closing` and `Completed` only.
So after §4.1 lands, a disposition at `Call for Offers`, `NDA`, `Disposition Offer`, `LOI` or `PSA` shows
`dispositionMain`, which renders **nothing** — an empty main region. That is a defect introduced *by this
change*, so fixing it is in scope.

Invert the pair so exactly one occupant always renders:

- `c_dispositionMain` visible when the stage **is one of** `BOV Outreach`, `Active Listing`, `Closing`,
  `Completed` (four `EQUAL` criteria, `booleanFilter` `1 OR 2 OR 3 OR 4`)
- `flexipage_fieldSection` visible when the stage is **none of** those four (the same four criteria as
  `NE`, ANDed)

No new components, no new facets, no assignment change.

### 4.7 Layout — add the `Submit` standard button

`layouts/Disposition__c-Disposition Layout.layout-meta.xml` → add to `platformActionList`
(`actionListContext Record`):

```xml
<platformActionListItems>
    <actionName>Submit</actionName>
    <actionType>StandardButton</actionType>
    <sortOrder>3</sortOrder>
</platformActionListItems>
```

…renumbering the existing `LogACall`/`NewEvent`/`NewTask`/`SendEmail` entries. See §1.3 — without this the
three approvals are unreachable. Do **not** enable Dynamic Actions on the page.

### 4.8 Approval processes — three, on `Disposition__c`

Clone the shape of `approvalProcesses/Opportunity.Underwriting_Approval.approvalProcess-meta.xml` — it is
the working, deployed precedent D10 points at. **Copy the two approver usernames byte-for-byte from the
deployed files** (`nikhil.dhanani@usmandpeg.uat`, `aftab.ali.dpeg.usman@avanzasolutions.com`).

Common to all three:
`<active>true</active>` · `<allowRecall>true</allowRecall>` · `<allowedSubmitters><type>owner</type>` ·
one `approvalStep` with both approvers and `<whenMultipleApprovers>FirstResponse</whenMultipleApprovers>`,
`<allowDelegate>false</allowDelegate>` · `<recordEditability>AdminOnly</recordEditability>` ·
`<showApprovalHistory>true</showApprovalHistory>` · `<finalApprovalRecordLock>false</finalApprovalRecordLock>` ·
`<finalRejectionRecordLock>false</finalRejectionRecordLock>` · **no `finalApprovalActions`, no
`finalRejectionActions`** · a `<description>` spelling out the first-response semantics (copy the wording
style from `Underwriting_Approval:34`).

| File | `processOrder` | `entryCriteria` | `approvalPageFields` |
|---|---|---|---|
| `Disposition__c.Sale_Decision_Approval` | 1 | `Disposition__c.Disposition_Stage__c` equals `Disposition Readiness` | Name, Owner, `Disposition_Stage__c`, `Property_Asset__c`, `Sell_Decision_Trigger__c` |
| `Disposition__c.Broker_Selection_Approval` | 2 | equals `BOV Outreach` | Name, Owner, `Disposition_Stage__c`, `Selected_Broker__c`, `Brokers_Contacted__c`, `Responses_Received__c`, `Submission_Deadline__c` |
| `Disposition__c.Closing_Approval` | 3 | equals `Closing` | Name, Owner, `Disposition_Stage__c`, `PSA_Executed__c`, `Title_Company__c`, `Accepted_Offer_Price__c`, `Net_Sale_Proceeds__c`, **`Wire_Verification_Completed__c`** |

Notes that matter:

- **`processOrder` is per-object**, so 1/2/3 here do not collide with Opportunity's 1/2.
- The three entry criteria are **mutually exclusive by stage**, so exactly one process ever matches. At any
  other stage the user gets the platform's "no applicable approval process" message — accepted.
- **Broker Selection is self-limiting to on-market** without a record-type criterion, because `BOV Outreach`
  exists only in the `On_Market` value set. Do not add a `RecordType` criterion; it would be redundant and
  would need maintaining.
- **No stamp automation, deliberately.** The document asks only that the principals approve; approval
  history (`showApprovalHistory`) records who and when. Adding an approver-identity stamp would require an
  approval-triggered flow, which **runs as the approver** — read-only here — and would need
  `<runInMode>SystemModeWithoutSharing</runInMode>` plus a `catch (Exception)` rather than
  `catch (DmlException)`. That is the `ApprovalAuditService` incident, which rolled back a whole approval.
  If the user wants stamped approver fields, raise it as its own item; do not fold it in.
- ⚠ `recordEditability = AdminOnly` locks the record while pending, so the Path cannot advance mid-approval.
  That is the intended behaviour (you should not advance while awaiting sign-off) but it is a visible UX
  change — call it out in UAT.
- ⚠ `whenMultipleApprovers` and the approver set **cannot be safely changed once a process has live work
  items**. Get the panel right the first time (D10).

### 4.9 Flow — `Wire_Verification_Rollup`

`flows/Wire_Verification_Rollup.flow-meta.xml` — record-triggered on `Wire__c`, **after save**, create and
update.

- 🔴 `<runInMode>SystemModeWithoutSharing</runInMode>` **declared explicitly.** `Disposition__c` is
  `sharingModel = Private`, and the IR persona who edits a Wire is not necessarily the Disposition owner or
  an editor of it. Leaving `runInMode` to the default is the exact ambiguity that produced the
  `ApprovalAuditService` failure.
- **Get Records** `Wire__c` where `Disposition__c = {!$Record.Disposition__c}`, sort `CreatedDate DESC`,
  first record only → this mirrors `WireSelector.selectMostRecentByDispositionId` (Q3).
- **Formula** `isComplete` = all six confirmed on that row:
  `Verbal_Verification_Completed__c` = true `AND NOT(ISBLANK(Verifier_Name__c)) AND NOT(ISBLANK(Verifier_Phone__c))
  AND NOT(ISNULL(Verified_DateTime__c)) AND NOT(ISBLANK(Wire_Instructions_Source__c)) AND NOT(ISNULL(Confirmed_Wire_Amount__c))`
- **Update Records** the parent `Disposition__c` → `Wire_Verification_Completed__c = {!isComplete}`.
- Assigns the value in **both** directions (an unticked verbal checkbox must set the flag back to false —
  `WireService.saveWire:59-61` already clears `Verified_DateTime__c` in that case).
- 🔴 Wire **delete** is not handled, and the stale-flag path **is reachable**. Corrected 2026-08-09 (code
  review W2 pass 2). This bullet previously read *"no permission set grants `allowDelete` on `Wire__c`, so
  the stale-flag path is unreachable"* — **both halves were false**, and the flow's `<description>` had
  inherited the claim from here. `DPEG_Acquisitions:2196–2204` grants `allowDelete` **and**
  `modifyAllRecords` on `Wire__c`; only `DPEG_Disposition_Edit:396–404` sets `allowDelete=false`; and any
  administrator holds Modify All Data regardless. ⚠ More generally: `profiles/**` is `.forceignore`d, so a
  **negative** claim about permissions can never be established from files in this repo — do not restate one.
  Consequence, now stated in the flow: `recordTriggerType` is `CreateAndUpdate`, so a delete never re-fires
  the rollup. Deleting the most recent **complete** Wire leaves the flag `true` while the badge falls back to
  an older Wire or to none — a live counter-example to the badge-equals-gate invariant, in the **fail-open**
  direction, until the next Wire save reconciles it. A `RecordAfterDelete` variant is the fix; deliberately
  out of scope for this tranche. Recorded as an **admitted gap**, not as an absent one.

### 4.10 Permission sets

Exactly **three** permission sets grant `Disposition__c` object access, and the same three carry its field
permissions — verified by grep, not assumed:

| Permission set | `Disposition__c` object | `Disposition__c` FLS |
|---|---|---|
| `DPEG_Disposition_Edit` | create/edit/read, viewAll | editable |
| `DPEG_Disposition_View` | read, viewAll | readable |
| `DPEG_Acquisitions` | full + modifyAll | editable |

Changes:

**(a) Record-type visibility** — add `<recordTypeVisibilities>` for `Disposition__c.On_Market` and
`Disposition__c.Off_Market` (`<visible>true</visible>`) to `DPEG_Disposition_Edit`, `DPEG_Acquisitions` and
`DPEG_Admin_Access`. Follow the repo precedent: record-type visibility is declared on the **create/edit**
sets (`DPEG_Acquisition_Edit`, `DPEG_Admin_Access` carry the Opportunity pair); the View sets do not.

**(b) FLS for `Wire_Verification_Completed__c`** — add to all three sets above, **`readable=true`,
`editable=false` everywhere including the Edit sets.** It is a derived anti-fraud flag; nobody should be
able to hand-tick it, and the flow writes in system mode regardless.

**(c) `NDA__c` access for the disposition personas** *(subject to Q7)* — add to `DPEG_Disposition_View`
(read) and `DPEG_Disposition_Edit` (read; edit not required by anything in this tranche):
`objectPermissions` `allowRead=true` on `NDA__c`, plus `fieldPermissions` on `NDA__c.Status__c`. Mirror the
grant shape used in `DPEG_Acquisition_View` / `DPEG_Acquisition_Edit`.

🔴 **THE PERMISSION-SET REPLACE TRAP APPLIES TO ALL FOUR FILES.** A `PermissionSet` deploy **replaces** the
set's entire `fieldPermissions` / `objectPermissions` / `recordTypeVisibilities` list with exactly what the
file declares. Any grant that exists only org-side is wiped — this bit Broker Protection twice. **Before
deploying: retrieve the four sets from the target org and reconcile against the repo copies.** Any drift is
a live grant about to be destroyed.

⚠ **Profiles are `.forceignore`d** (`profiles/**` never deploys), so profile-level record-type assignment
and the **default record type** are org state only — see §8, gates A1/A3.

### 4.11 Translations

Add the five new `Disposition_Stage__c` values to
`objectTranslations/Disposition__c-en_US/Disposition_Stage__c.fieldTranslation-meta.xml` (the file currently
enumerates only the five existing values). Cosmetic but keeps the file honest.

### 4.12 Reports — review only, no change expected

Three reports reference `Disposition_Stage__c` (`Avg_Days_on_Market`, `Listed_With_Broker`,
`BOVs_Ordered`). This tranche only **adds** values, so grouped reports gain rows and equality filters are
unaffected. Read them; do not edit unless one breaks.

---

## 5. 🟢 DEVELOPER WORK

Routing note: standard Apex service/selector/controller + LWC. **`salesforce-developer`**, not the
technical architect — no integration, no async, no governor-limit engineering.

### 5.1 Server-side sell-meter gate (brief item 6)

Today `DispositionService.findOrCreate:31-39` reads the most recent Disposition and otherwise inserts one.
It never reads `Peak_Sell_Date__c`, so the red-band block exists **only** in
`lwc/sellMeterList/sellMeterList.js:110` (`actionDisabled: meter === 'RED'`) and is bypassed by calling the
`@AuraEnabled` method directly.

**New class `SellMeterService`** (`with sharing`):
- `public static String bandForPeak(Date peak)` — the body **moved verbatim** from
  `SellMeterController.bandForPeak:90-101` (≤30 GREEN, ≤90 YELLOW, else RED; null peak → RED).
- `SellMeterController` deletes its private copy and delegates. Behaviour must be byte-identical — this is
  a move, not a rewrite. One band function, two callers, so client and server can never disagree.

**New selector method `PropertyAssetSelector.selectPeakSellDateById(Id)`**
- `SELECT Id, Peak_Sell_Date__c FROM Property_Asset__c WHERE Id = :assetId WITH USER_MODE LIMIT 1`
- **`WITH USER_MODE`, not SYSTEM_MODE.** This backs a read the user explicitly requested by clicking a
  button. It is not an automation path and does not belong in the `ARCHITECTURE.md` §2 SYSTEM_MODE table.
- Fetch-for-use: single-row SOQL assignment, so a miss throws the native `QueryException` — matching
  `OpportunitySelector.selectStageRequiredById` and the contract documented in `DispositionSelector`'s header.

**`DispositionService.findOrCreate` changes:**
- 🔴 The gate applies to the **create branch only**. If a Disposition already exists, return its Id
  unchanged — refusing to open an existing record for a now-red asset would break navigation and is not
  what the document asks.
- On the create branch: read the asset, compute the band, and if `RED` throw a new nested
  `public class SellMeterGateException extends Exception` carrying a **user-safe** message, e.g.
  *"This property is not ready to sell — its peak sell date is more than 90 days away, so a disposition
  cannot be initiated yet."* YELLOW is **permitted** (that is what Override is for).
- Stamp `RecordTypeId` (Q1): resolve `On_Market` through
  `Schema.SObjectType.Disposition__c.getRecordTypeInfosByDeveloperName()`, guarded on `isAvailable()`; when
  the type is missing or unavailable to the running user, leave `RecordTypeId` unset so the platform default
  applies rather than throwing.
- Budget goes from 1 SOQL / 1 DML to **2 SOQL / 1 DML on the create path**, 1 SOQL on the existing path.

**`DispositionController.findOrCreate` change — this one is easy to miss:**
The controller currently catches `Exception` and throws the fixed generic
`WRITE_FAILURE_MESSAGE` (`DispositionController:22-23, 46-53`). A sell-meter refusal would therefore reach
the user as *"This change could not be saved. Refresh the page and try again"* — actively misleading. Add a
**first** `catch (DispositionService.SellMeterGateException e) { throw ahe(e.getMessage()); }` and keep the
existing generic catch beneath it for everything else. The pattern is deliberate: a *designed refusal* is
user-safe by construction; a *platform failure* is not.

⚠ Layering: the service throws the raw exception; the `AuraHandledException` boundary stays in the
controller. That is the repo's stated contract (`DispositionService` class header) and must not be inverted.

### 5.2 Sell-meter "Override" (brief item 5a — Q2)

`lwc/sellMeterList/sellMeterList.js:160-164` early-returns on any action but `initiate`, so the yellow row's
enabled button is a silent no-op.

- Accept both `initiate` and `override` in `handleRowAction`.
- For `override` only: `await LightningConfirm.open({ variant: 'header', label: 'Override the sell meter?',
  message: <names the property and that its peak sell date is 31–90 days away>, theme: 'warning' })`. Proceed
  only on `=== true`; a cancel does nothing and shows nothing.
- Then the **same** `findOrCreate` call, with a distinct success toast naming it as an override.
- `hold` (red) keeps returning early — the button is `disabled` anyway, and the server now refuses it too.
- **Thresholds and labels are untouched.** `bandForPeak` and the Initiate/Override/Hold labels are an exact
  match to the document (audit §2.1) and must not change.

⚠ **Use `LightningConfirm` directly; do not import `c/dealActionGuard`.** Its `confirmAction()` export would
work, but the module also imports `OpportunityActionPermissionController` at module scope, which would give
the Disposition dashboard a hard dependency on an Opportunity permission controller for ten lines of code.
`ARCHITECTURE.md` §5 already warns the three guard utils must not be merged.

⚠ Jest: `lightning/confirm` needs a module stub in the `sellMeterList` suite (the `dealActionGuard` suites
are the in-repo precedent for how it is mocked).

### 5.3 NDA pill (brief item 5b)

`lwc/bovOutreach/bovOutreach.js:12` — `_ndaStatus = 'Signed';` renders "Signed" unconditionally,
misreporting a compliance state on every disposition.

- **New `NdaSelector.selectLatestByDispositionId(Id)`** — `WHERE Disposition__c = :dispositionId
  ORDER BY CreatedDate DESC LIMIT 1`, `WITH USER_MODE`, returning `NDA__c`-or-null (read-for-display: "no
  NDA yet" is a normal state, matching this selector's existing not-found contract).
- **`BovController.OutreachSummary`** gains `@AuraEnabled public String ndaStatus;` populated from that row's
  `Status__c`; **null when there is no NDA**.
- 🔴 **The NDA read must be inside its own narrow `try/catch`**, not the method's outer one. Without Q7's
  grant a `USER_MODE` read of `NDA__c` throws `QueryException`, the outer catch converts it to
  `READ_FAILURE_MESSAGE`, and the **entire BOV Outreach tile disappears** for every disposition-only user.
  Fail soft: swallow, log at ERROR, leave `ndaStatus` null.
- **`bovOutreach.js`**: delete the hard-coded field; `get ndaStatus()` returns `this.summary?.ndaStatus`
  or `'No NDA'` when null. Pill class map — `Signed → nda-signed`, `Sent → nda-received`, everything else
  including null → `nda-pending`. The three CSS classes already exist; no new CSS.
- Nothing about `NDA__c` itself changes here — no new values, no rename, no `Party_Role__c`. That is
  Tranche 3 (D7).

### 5.4 `dispositionSidebar` — where the offer card shows

`lwc/dispositionSidebar/dispositionSidebar.js:27` renders `c-disposition-offer` at `Active Listing` only.
With the new stages, the sidebar is empty exactly where offers are actually being taken.

`Disposition_Offer__c` **exists today and is fully built** (all six document-named fields present, audit
§2.8), so extending the branch costs nothing:

- Show `c-disposition-offer` at `Active Listing`, `Call for Offers`, `Disposition Offer` **and** `LOI`.
- No record-type check (see §1.1 — `Call for Offers` and `Disposition Offer` are mutually exclusive by
  record type already).
- `dispositionMain` needs **no JS change**: `isBovOutreach` / `isActiveListing` / `isClosing` still resolve
  correctly, and the flexipage change in §4.6 handles the stages it does not cover.

### 5.5 `TestDataFactory`

`TestDataFactory.createDispositions(...)` / `defaultDisposition()` must stamp a record type once §4.2 lands.
Left unstamped, every Apex test's disposition inherits the **test-running user's profile default** — org
state, undeployable, and different between the scratch org and `usman-dpeg`. Default to `On_Market`, with an
overload or parameter for `Off_Market`.

### 5.6 Test obligations (existing repo rules — no new scenarios invented)

- `findOrCreate` is structurally single-record-per-transaction (no trigger, no loop), so the
  `.claude/rules/bulk-test-rule.md` **per-transaction-singleton exemption applies** — record that reasoning
  in the test class header so review does not demand a 251-record test.
- Suites already touching this surface and needing updates: `DispositionControllerTest`,
  `DispositionSelectorTest`, `BovControllerTest`, `WireServiceTest`, `WireControllerTest`,
  `PropertyAssetSelectorTest`, `SellMeterControllerTest`; Jest: `sellMeterList`, `bovOutreach`,
  `dispositionMain`, `dispositionSidebar`.
- ⚠ **An FLS test that runs as an admin cannot fail.** Persona acceptance testing (§8 gate B5) is the only
  real proof for the `NDA__c` grant and the new field's FLS.

---

## 6. THE TRANCHE-3 SEAM (answering the brief's explicit question)

**What a `Disposition__c` sitting at the `LOI` stage does in the interim — stated plainly:**

`LOI` and `PSA` are **stage values naming a phase of the disposition**, not pointers to records. A
disposition advances into `LOI`, the Path renders that step, the record page falls back to the Details field
section (§4.6), the sidebar keeps showing the offer card (§5.4), and the negotiation continues to be recorded
where it is recorded **today**: on `Disposition_Offer__c`'s existing `Offer_Status__c` values and
`DPEG_Counter_Price__c` / `DPEG_Counter_Date__c` / `Buyer_Counter_Price__c` / `Final_Agreed_Price__c`. The
Path step's `<info>` text must say exactly that, so a user at this stage is not left guessing. The same
applies to `PSA`, where the disposition-side contract has no record at all yet and `PSA_Executed__c` on the
Disposition is the only marker.

**Five things this tranche deliberately does NOT do, so Tranche 3 lands cleanly:**

1. **No changes to `LOI__c`** — no `Disposition__c` lookup, no record types, no new `Stage__c` values.
   D6 owns all of it.
2. **No changes to `Contract_Review__c` / `PSA_Version__c`.**
3. **No changes to `Disposition_Offer__c`.** Retiring `Offer_Status__c`'s four LOI-shaped values and the
   four counter fields is a **data migration** and the highest-risk item in the programme (D6); it must not
   begin before the disposition LOI record exists to migrate *to*.
4. **No changes to `NDA__c`.** The `NDA` stage value lands; `Declined`, the `Pending → Not Sent` rename,
   `Party_Role__c`, counter-signature and the all-signed gate are D7 — and D7's acquisition-side value set is
   still an open question.
5. **Stage values are named for the phase (`LOI`, `PSA`), not for a record type** (`Disposition_LOI`), so
   Tranche 3's `LOI__c` record-type names cannot collide with them and the value set never has to change again.

**What Tranche 3 will find already true:** two record types with disjoint stage sets, a Path per type, the
stage values it needs already deployed and restricted, and permission sets already carrying record-type
visibility. Its work is records and automation, not foundations.

---

## 7. DEPLOYMENT ORDER

Record types before stage-value restrictions before approvals, as required — with two data/org gates
interleaved, because they cannot be deployed.

| # | Contents | Why here |
|---|---|---|
| **D1** | §4.1 picklist values + §4.2 both record types + §4.3 the new checkbox + §4.11 translations — **one deployment** | The values must exist before a record type can restrict them, and any gap between the two leaves all ten values globally selectable on every disposition. One deployment ⇒ zero exposure window. |
| **GATE A** | A1 profile record-type assignment + default · A2 migrate existing rows to `On_Market` | Org state / data. Not deployable. Must complete before any Path is activated or every existing row shows no Path. |
| **D2** | §4.10 permission sets (after the org-drift reconciliation) | Record types must exist before they can be referenced in `recordTypeVisibilities`. |
| **D3** | §4.4 two new Paths + deactivate `Disposition_Path` · §4.6 flexipage · §4.7 layout `Submit` button | Depends on D1 (record types) and GATE A2 (rows migrated). |
| **D4** | §4.9 the rollup flow, **then** §4.5 the validation rule | Flow first. Deploying the VR before the flow leaves `Wire_Verification_Completed__c` false everywhere with nothing able to set it — no disposition could reach Completed. |
| **D5** | §4.8 three approval processes | Entry criteria reference `Disposition_Stage__c`; `Closing_Approval`'s `approvalPageFields` reference the new checkbox. Both from D1. |
| **D6** | §5 all Apex + LWC + test updates | The record-type describe lookup is runtime, so there is no compile dependency — but the tests that assert the stamp need D1 in the org. |
| **GATE B** | Post-deploy verification, §8 | |

⚠ **Metadata before Apex, always.** A picklist value is invisible to the Apex compiler, so a code-first
deploy goes green and then throws `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` at runtime.

---

## 8. POST-DEPLOY GATES — org state, not metadata

Each of these is invisible to any file-based check and to a green deployment. Nothing here is optional.

**A — before the feature is usable**

- **A1.** Assign `On_Market` and `Off_Market` to every profile in use on the target org. `profiles/**` is
  `.forceignore`d, so this **cannot be deployed** and is not represented in the repo. Include **System
  Administrator** — Modify All Data is an object permission and confers no record-type access.
- **A2.** Data-migrate every existing `Disposition__c` row to `On_Market` (Q6). Adding record types leaves
  existing rows on the **Master** type, which matches neither Path and shows all ten stage values. Verify
  the count before and after.
- **A3.** Set the **default record type** per profile. Permission sets cannot express a default
  (`PermissionSet.recordTypeVisibilities` has no `default` element) — it is profile-only, and therefore org
  state. This is the second reason §5.1 stamps the record type in Apex rather than relying on it.
- **A4.** 🔴 **Verify admin FLS on `Disposition__c.Wire_Verification_Completed__c`, and verify it by opening
  the Closing approval page as *each* persona that can approve — including an administrator.** Added
  2026-08-09 (code review W2). The grant itself is now in the repo (`DPEG_Admin_Access`, read-only), but the
  *check* cannot be: **an approval page silently OMITS fields the approver cannot read.** There is no error,
  no blank row and no toast — the wire state simply is not there, so the Q4 design ("the approver sees the
  wire state when deciding") fails invisibly rather than loudly. The two named approvers are covered through
  `DPEG_Principal_PSG` → `DPEG_Disposition_View`; an admin approver is covered only by A4's grant, and only
  if `DPEG_Admin_Access` is actually **assigned**. ⚠ Assignment is org state — deploying the permission set
  does not assign it. ⚠ An admin smoke test proves nothing about the named approvers, and a named-approver
  test proves nothing about an admin: **both must be opened.**

**B — verification, before sign-off**

- **B1.** All three approval processes show **Active** in Setup. Both approver users exist and are active in
  the target org — a missing user fails the deploy; an *inactive* user does not, and silently strands every
  submission.
- **B2.** Open a real disposition and confirm **Submit for Approval** appears — as a
  `DPEG_Disposition_Edit` user, not as an admin.
- **B3.** Both Paths render: create one record of each type and check the step sequence matches §3.
- **B4.** Open **New Disposition** for each record type and read the stage picklist — confirm on-market
  shows no `NDA`/`Disposition Offer` and off-market shows no `BOV Outreach`/`Active Listing`/`Call for
  Offers`. A record-type restriction that failed to apply looks identical in source to one that worked.
- **B5.** 🔴 **Persona acceptance test as `DPEG_Disposition_Edit` and `DPEG_Disposition_View` — an admin
  smoke test proves nothing here.** Metadata-API-deployed custom fields arrive with **no** field permissions
  for any profile, System Administrator included; `WITH USER_MODE` **throws** rather than degrades. Check
  specifically: the BOV Outreach tile still loads (the `NDA__c` grant), and
  `Wire_Verification_Completed__c` is visible on the Closing approval page.
- **B6.** Save a Wire with all six fields and confirm `Wire_Verification_Completed__c` flips true; untick
  the verbal checkbox and confirm it flips back.
- **B7.** Attempt Closing → Completed with an incomplete wire and confirm the validation message appears in
  the Path UI (not a generic toast).
- **B8.** Click **Override** on a yellow row and confirm the dialog appears and creates the disposition;
  call `DispositionController.findOrCreate` directly for a red asset and confirm the refusal message is the
  sell-meter wording, not the generic write-failure text.
  🔴 **Then read the new record's record type back — the creation succeeding is not evidence that it landed
  on `On_Market`.** Added 2026-08-09 (code review S2 pass 2, D13 residual 1). Run
  `SELECT Id, RecordTypeId, Disposition_Stage__c FROM Disposition__c WHERE Id = :newId` and confirm
  `RecordTypeId` is **`On_Market`**, not the platform default.
  ⚠ **Run the whole of B8 as a `DPEG_Disposition_Edit` persona, not as an administrator.**
  `DispositionService.onMarketRecordTypeId()` (`DispositionService.cls:137–142`) guards its stamp on
  `info != null && info.isAvailable()` and **fails soft by design** — a missing record type must not block a
  live business action — so if `isAvailable()` is genuinely `false` for that persona post-deploy, the stamp is
  skipped **silently** and every disposition the Sell Meter button creates lands on the default record type:
  no Path, all ten stage values, i.e. exactly the state gate **A2** exists to eliminate, recreated one click
  at a time. `TestDataFactory` carries the identical guard, which is why the same condition would also make
  the fixtures lie. A2 verifies **migrated** rows; only this read-back verifies the **create** path.
  ⚠ The persona matters because this org has already measured `isAvailable() == false` for an *assigned*
  System Administrator while the record type Id resolved — an admin smoke test proves nothing about the
  persona gate, and the reverse also holds.
- **B9.** 🔴 **The locked-parent case — the only test that exercises the C1 fix.** Added 2026-08-09 (code
  review C1). Put a disposition at `Closing`, **submit it for `Closing_Approval`**, then save a `Wire__c`
  against it from the UI as a `DPEG_Disposition_Edit` user. **Expected: the Wire saves.** Before the fix the
  after-save flow's parent update hit a record locked by `recordEditability = AdminOnly`, threw
  `ENTITY_IS_LOCKED` with no fault connector, and **rolled the Wire save back** while telling the user to
  refresh the page. Now the flow either skips the parent write (the value is unchanged — the common case) or
  fails soft onto `Record_Flag_Update_Fault`, leaving a **stale flag**. Then **approve or recall**, save the
  Wire once more, and confirm the flag reconciles.
  🔴 **Scope of the "a stale flag is harmless" justification — it is true only *inside the lock window*.**
  Corrected 2026-08-09 (code review W1 pass 2). While the lock holds the stage cannot change either, so
  `Wire_Complete_Before_Completed` is genuinely unreachable. It is **not** harmless afterwards:
  `Closing_Approval` sets `finalApprovalRecordLock=false` **and** `finalRejectionRecordLock=false`
  (`Disposition__c.Closing_Approval.approvalProcess-meta.xml:43–44`), so the record **unlocks the moment the
  approval resolves and nothing re-fires the rollup** — the flag stays stale until someone saves a Wire
  again, which is exactly why this gate mandates that save rather than treating it as tidying up.
  ⚠ **This is the one gate that cannot be inferred from a green deploy or a green test suite** — B6 passes
  with no approval pending and would not have caught C1.
  **Run B9 in THREE orders, not two:**
  1. **wire-then-submit** — the intended order, which both `Closing` Path steps now signpost.
  2. **submit-then-wire** — the C1 failure shape. Expected: **the Wire saves.**
  3. 🔴 **submit-then-REDUCE-the-wire-then-approve — the fail-OPEN case.** Added 2026-08-09 (code review
     W1 pass 2); B9 previously walked only the fail-*closed* path. Start at `Closing` with a **complete**
     wire and the flag already `true`; submit for `Closing_Approval`; then **untick verbal verification**
     (or save a newer, incomplete Wire). `isComplete` goes `false` while the parent still holds `true`, so
     `Flag_Changed` **passes**, the update hits the locked record, the fault path swallows it, and **the flag
     stays `true`.** Approve; the record unlocks; nothing re-runs the flow. **Now attempt `Closing` →
     `Completed`: the validation rule reads the stale `true` and ALLOWS it** — a disposition Completed
     against an unverified wire, with no signal anywhere, and the approver was shown that same stale `true`
     on the approval page while deciding. **Confirm the operator must re-save the Wire before `Completed` is
     honestly reachable.**
     ⚠ **This failure is both silent and unobservable.** The fault message is captured into `faultDetail`
     and, per that variable's corrected description, a **completed** autolaunched interview is not retained —
     only *paused* interviews appear in Setup — so there is nothing to open afterwards. **This gate is the
     only control on it.**
     ⚠ Before the C1 fix this state could not occur (the untick was rolled back with the Wire save). The fix
     is still the right trade — a lost Wire record is worse than a stale flag — but it exchanged a loud
     failure for a **quiet divergence that outlives the condition used to excuse it**. This is a narrow
     instance of the already-accepted judgement call **J1** (the wire gate is a process control, not a fraud
     control); it is recorded here so the next reader does not have to rediscover it.

---

## 9. 📝 PROMPTS FOR SPECIALIST AGENTS

### 🟤 PROMPT FOR salesforce-solution-architect

```
Read ARCHITECTURE.md and agent-output/design-requirements-disposition-foundations.md first.
Build ONLY §4 of that document. Create metadata files; do not deploy.

1. §4.1  Add 5 values to Disposition__c.Disposition_Stage__c in the exact positions in §3.
         Keep restricted=true and sorted=false. Do not touch the existing 5 values or the default.
2. §4.2  Two record types, On_Market and Off_Market, with the per-type Disposition_Stage__c
         restriction from §3 AND a full enumeration of Sell_Decision_Trigger__c's 4 values in both.
         Precedent: objects/Opportunity/recordTypes/Commercial.recordType-meta.xml.
3. §4.3  New checkbox Disposition__c.Wire_Verification_Completed__c, default false, described as
         flow-derived.
4. §4.4  Deactivate Disposition_Path; create Disposition_Path_On_Market (8 steps) and
         Disposition_Path_Off_Market (7 steps). Copy every existing step's fields AND info text
         byte-identical — especially the Active Listing text, which is under an open question.
5. §4.5  Validation rule Wire_Complete_Before_Completed on Disposition__c, formula as written.
6. §4.6  Invert the two visibility rules on flexipages/Disposition_Record_Page so no stage renders
         an empty main region.
7. §4.7  Add the Submit standard button to layouts/Disposition__c-Disposition Layout.
8. §4.8  Three approval processes, cloning the shape of
         approvalProcesses/Opportunity.Underwriting_Approval. Copy the two approver usernames
         byte-for-byte from the deployed file. NO finalApprovalActions, NO finalRejectionActions,
         NO stamp flow.
9. §4.9  Flow Wire_Verification_Rollup with an EXPLICIT <runInMode>SystemModeWithoutSharing</runInMode>.
10. §4.10 Permission-set edits. BEFORE writing them, retrieve DPEG_Disposition_Edit,
         DPEG_Disposition_View, DPEG_Acquisitions and DPEG_Admin_Access from the target org and
         reconcile: a PermissionSet deploy REPLACES the whole grant list, so any org-side-only grant
         not in the file will be destroyed. Report any drift you find; do not silently overwrite.
11. §4.11 Add the 5 new values to the Disposition_Stage__c field translation.

Do NOT build: any notification, notification type, email alert or notify flow; any change to LOI__c,
Contract_Review__c, PSA_Version__c, Disposition_Offer__c or NDA__c metadata; any validation rule other
than the one named; any new permission set; any approver-identity stamp automation.
```

### 🟢 PROMPT FOR salesforce-developer

```
Read ARCHITECTURE.md and agent-output/design-requirements-disposition-foundations.md first.
Build ONLY §5 of that document. The §4 metadata must already exist in the repo.

1. §5.1 New SellMeterService with bandForPeak(Date) MOVED VERBATIM from SellMeterController;
        SellMeterController delegates to it. New PropertyAssetSelector.selectPeakSellDateById(Id),
        WITH USER_MODE, fetch-for-use. DispositionService.findOrCreate: gate the CREATE BRANCH ONLY
        (return an existing Disposition unchanged), refuse RED with a nested SellMeterGateException
        carrying a user-safe message, permit YELLOW, and stamp RecordTypeId = On_Market guarded on
        isAvailable(). DispositionController.findOrCreate: add a FIRST catch for
        SellMeterGateException rethrowing ahe(e.getMessage()); keep the generic catch beneath it.
2. §5.2 lwc/sellMeterList: handle the 'override' action — LightningConfirm.open() then the same
        findOrCreate, distinct success toast. Import lightning/confirm DIRECTLY; do NOT import
        c/dealActionGuard. Do not change bandForPeak's thresholds or the button labels.
3. §5.3 New NdaSelector.selectLatestByDispositionId(Id), WITH USER_MODE, returns NDA__c-or-null.
        BovController.OutreachSummary gains ndaStatus. The NDA read MUST sit in its own narrow
        try/catch so a missing FLS grant degrades the pill instead of blanking the whole tile.
        lwc/bovOutreach: delete the hard-coded _ndaStatus and render the real value ('No NDA' when null).
4. §5.4 lwc/dispositionSidebar: show c-disposition-offer at Active Listing, Call for Offers,
        Disposition Offer and LOI. No record-type wiring anywhere — see §1.1 for why it is not needed.
5. §5.5 TestDataFactory.createDispositions must stamp a record type (default On_Market).

Follow the repo's layering rules: all SOQL in selectors, services throw raw platform exceptions, the
AuraHandledException boundary stays in the controller. Update the existing Apex and Jest suites listed
in §5.6; the per-transaction-singleton exemption applies to findOrCreate — record that in the test
class header.

Do NOT build: any notification; any change to LOI__c, Contract_Review__c, Disposition_Offer__c or
NDA__c beyond the read path named above; a placeholder component for the LOI/PSA stages; a Disposition
LOI or PSA record of any kind.
```
