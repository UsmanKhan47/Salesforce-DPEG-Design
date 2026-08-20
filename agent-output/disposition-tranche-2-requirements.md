# Disposition Redesign — Tranche 2 Requirements

**Target branch:** `feature/disposition-redesign`
**Written:** 2026-08-20 · **Author:** salesforce-design
**Status:** decisions are USER-CONFIRMED. This document converts them to an admin/dev split. It does
not re-litigate them. It *does* record where the confirmed decisions collide with live metadata.

> ⚠ **BRANCH MISMATCH — read before starting.** The working tree is currently on
> `feature/acquisitions-fsd-tranche-1`, not `feature/disposition-redesign`, and four seed scripts are
> modified but uncommitted (`scripts/seed-disposition-bulk.apex`, `seed-disposition-offers.apex`,
> `seed-sell-meter.apex`, `seed-sell-readiness.apex`). Commit or stash those and cut/checkout the
> target branch before any agent writes metadata. This repo has a measured incident of a second
> concurrent session building into the same tree; do not start work until the branch is right.

---

## §0 — CONTRADICTED PREMISES AND LIVE-METADATA CONFLICTS

Everything in this section was measured against `force-app/main/default` on this branch. Read it
before §1. Nothing downstream is safe to plan around until these are absorbed.

### 🔴 C-1 — `NDA__c.Date_Signed__c` IS NOT READABLE BY ANY DISPOSITION PERSONA. Workstreams C and D are both built on it.

Measured — the complete list of `NDA__c` field grants in **both** `DPEG_Disposition_Edit` and
`DPEG_Disposition_View` is exactly four fields:

```
NDA__c.Counter_Signed_Date__c
NDA__c.Is_Decline_Allowed__c
NDA__c.Party_Role__c
NDA__c.Status__c
```

`Date_Signed__c`, `Disposition__c`, `Counterparty_Name__c`, `NDA_Signed__c` and `Date_Sent__c` are
granted **only** in `DPEG_Acquisition_Edit` / `DPEG_Acquisition_View`
(`DPEG_Acquisition_View.permissionset-meta.xml:796,813,818,828,848`). A disposition persona cannot
read any of them.

Consequences, all of which must be funded by this tranche:

1. **Workstream C** wants `NDA.Date_Signed__c` on the Deal Summary card → blank/throw for every
   disposition persona until granted.
2. **Workstream D**'s entire timeline is `Date_Signed__c` → same.
3. 🔴 **A pre-existing latent defect this tranche will incidentally fix.**
   `NdaSelector.selectLatestByDispositionId` is `WITH USER_MODE` and filters
   `WHERE Disposition__c = :dispositionId`. `USER_MODE` enforces FLS on `WHERE` fields, not just
   `SELECT` fields — and `NDA__c.Disposition__c` is not granted to either disposition set. That query
   therefore almost certainly **throws today** for every disposition-only persona, is swallowed by
   `BovController.readNdaStatusFailSoft`, and the BOV Outreach NDA pill silently renders "No NDA"
   forever. The fail-soft catch is working exactly as its header predicted and is hiding a real
   provisioning gap. **Verify this in-org before "fixing" it** — but the grant C/D needs anyway
   (`Disposition__c` + `Date_Signed__c`) is the fix.

**Do not reach for `WITH SYSTEM_MODE`.** These are reads a human explicitly asked for
(ARCHITECTURE.md §2). The fix is a permission set, every time.

### 🔴 C-2 — `required=true` on `BOV_Submission__c.Broker__c` collides head-on with a written DO-NOT in that field's own header.

Salesforce does not permit `deleteConstraint = SetNull` on a **required** lookup — a required lookup
must use `Restrict`. `BOV_Submission__c.Broker__c` is `SetNull` today, and its header says, in terms:

> 🔴 **DO NOT "FIX" THIS BY SWITCHING TO deleteConstraint Restrict.** That would make the seed fail
> loudly but would also block legitimate Contact deletion for the whole org, and it would diverge
> from all four sibling lookups.

So `required=true` on that field is not a one-line attribute flip; it forces a delete-constraint
change the codebase has explicitly refused. **⇒ Workstream A1 must use a VALIDATION RULE for
`Broker__c`, not `required=true`.** See §2 A1 for the full field-vs-rule decision table.
⚠ Confirm the platform constraint at deploy time (a check-only deploy of `required=true` + `SetNull`
will reject if the rule holds); the recommendation stands either way for the reasons in §2 A1.

### 🔴 C-3 — "Only one selected offer" is ALREADY enforced, and a trigger guard there closes a *narrower* hole than the brief implies.

`Disposition_Offer__c.Is_Selected__c` is:
- written **only** by `DispositionApprovalService.selectOffer`, which already clears every sibling in
  the same transaction, under a savepoint, in **ONE bulk DML** (asserted in that class's own BULK
  header block);
- **read-only FLS in BOTH permission sets** — `DPEG_Disposition_Edit` lists it at line 119 among the
  fields it deliberately keeps read-only.

The invariant is therefore already unbreakable through the UI, through LDS, and through any
`USER_MODE` Apex. The residual is API / data-loader / anonymous-Apex / `SYSTEM_MODE` writes only.

The guard is still worth building — it is the same argument
`Disposition__c.Broker_Lookup_Is_Off_Market_Only` makes about a visibilityRule ("it constrains a
browser, not the API") — but **the priority is not equal to the BOV case.** `BOV_Submission__c
.Submission_Status__c` IS user-editable (granted read+edit in `DPEG_Disposition_Edit:1239`), so that
invariant is breakable by hand today. **Build the BOV guard first; the offer guard is defence in
depth.**

### 🔴 C-4 — Two repo files already ASSERT the `NDA_Signed__c` latch fix that Workstream A3 is going to build. They are wrong today.

`pathAssistants/NDA_Path_Disposition.pathAssistant-meta.xml:22-25`:

> "MOVING A SIGNED NDA TO DECLINED IS SAFE AND IS THE INTENDED RECOVERY: the before-save flow
> `NDA_Signed_Status_Sync` **defaults everything that is not Signed to `NDA_Signed__c = FALSE`**, and
> it never clears `Date_Signed__c`."

`objects/NDA__c/fields/Is_Decline_Allowed__c.field-meta.xml:32-34` repeats the claim
("`NDA_Signed_Status_Sync` re-derives `NDA_Signed__c`").

**Both are false.** The flow's `Set_Signed_False` assignment is defined but has no inbound connector
(`Is_Signed` carries `<defaultConnectorLabel>Not Signed</defaultConnectorLabel>` with no
`<defaultConnector>`). A3 makes the claim *partly* true — for `Declined` only, not for "everything
that is not Signed". **Both comments must be corrected in the same change**, or the repo carries a
claim that is still overstated after the fix.

### ✅ C-5 — The flow's own header already prescribes the A3 solution, and the confirmed requirement is SAFER than the header's suggestion.

`NDA_Signed_Status_Sync`'s in-root comment says a future implementer

> "MUST exempt the acquisition terminal `Sent` explicitly (e.g. branch on
> `RecordType.DeveloperName`, or on `Status__c != 'Sent'` for `Acquisition_NDA` rows) rather than
> restoring a blanket `Status != 'Signed' => false` rule."

The user-confirmed requirement — clear on **`Declined` only** — is strictly narrower and needs no
record-type test at all, because **`Declined` is exposed only on the `Disposition_NDA` record type**
(`NDA__c.Status__c` description: "Acquisition_NDA exposes Pending, Sent, Received, Signed.
Disposition_NDA exposes Not Sent, Sent, Signed, Declined"). The acquisition `Signed → Sent`
transition can never reach the new branch. See §2 A3 for the exact routing.

### 🔴 C-6 — `NDA__c` HAS NO TRIGGER AT ALL, and `DispositionOfferTrigger` has no `before insert`.

The complete trigger inventory is eight files; there is **no `NdaTrigger`**. Workstream D's buyer
Contact stamp on `NDA__c` therefore needs a **new trigger + new handler**, not "another service".
That is its own dev item with its own org-wide blast radius (it will fire on every `NDA__c` insert
and update in the org, acquisition NDAs included).

`DispositionOfferTrigger` is `(before update, after update)` — **no `before insert`**. A buyer stamp
on offer creation is dead on arrival until that context list is expanded, and the trigger's header
carries an argument for the current split that becomes incomplete and must be corrected in place.
This is the exact failure mode measured on `BovSubmissionTrigger` on 2026-08-20.

### ⚠ C-7 — "Zero disposition records" is contradicted by a measurement recorded YESTERDAY.

`Broker_Lookup_Is_Off_Market_Only.validationRule-meta.xml:105-106` records, queried on `usman-dpeg`
on 2026-08-20:

```
GROUP BY RecordType.DeveloperName over all Disposition__c -> On_Market 8, and nothing else.
```

The brief states all disposition records were deleted. One of the two is stale. **Re-run the count
at deploy time rather than citing either line.** The data-risk conclusions in §5 assume zero rows; if
eight `On_Market` rows exist, A1 and A4 become behaviour-changing on live data and A1's
required-field decision changes (see §2 A1).

### ⚠ C-8 — `brokerAssignmentHistory` is NOT a child-history-object pattern. The "mirror" is UX-level only.

`BrokerAssignmentService.replaceBroker` snapshots the outgoing broker as **another
`Broker_Assignment__c` row** (`Status__c = 'Disposed'`), and `lwc/brokerAssignmentHistory` is a
component on the **`Broker_Assignment__c` record page** reading same-object rows via
`BrokerAssignmentController.getDetail(assignmentId)`.

Workstream B asks for a **new child object** hung off `Disposition__c`, rendered on the
**Disposition** record page. That is a different schema shape and a different anchor record. Mirror
these things: the five-parameter service signature, the reason picklist + notes capture, the
"nothing is deleted" framing, the savepoint-wraps-snapshot-and-swap atomicity, the notes-preview +
"View" popup UX. Do **not** mirror: the same-object snapshot, or `getDetail`'s single-record shape.

### ⚠ C-9 — `NDA_Count__c` / `Signed_NDA_Count__c` live on `Disposition__c`, not `NDA__c`, and they are maintained by a FLOW.

The brief lists them under "NDA". They are `Disposition__c` Number fields maintained by the
`NDA_Signed_Rollup` **after-save flow**, both marked `DERIVED - DO NOT HAND-EDIT`, both wrapped in
`BLANKVALUE(...,0)` by every reader because pre-existing rows hold null. This is the in-repo
precedent for a **maintained counter** standing in for an impossible roll-up summary — and it is a
Flow, not Apex. Relevant to Constraint 1 (§1).

### ⚠ C-10 — `LOI__c.LOI_Status__c` is dead vocabulary on the disposition path.

`LOI_Signed_Status_Sync`'s header states `LOI_Status__c` is "a separate approval/deal vocabulary
field that **no automation ever sets**". On a disposition LOI it will read `Draft` (its default)
unless an analyst types something. Showing it on the Deal Summary card next to `Stage__c` will
routinely display "Draft" beside "Executed". See §2 C for the recommended field set.

### ✅ C-11 — Premises the brief got RIGHT (verified, no action)

- Only `Disposition__c` carries validation rules — exactly three, all `<active>true</active>`
  (`All_NDAs_Signed_Before_Progression`, `Wire_Complete_Before_Sale_Closes`,
  `Broker_Lookup_Is_Off_Market_Only`). `BOV_Submission__c`, `Disposition_Offer__c`,
  `Broker_Listing__c`, `NDA__c`, `LOI__c`, `Contract_Review__c` have zero.
- `Date_Signed__c` is already auto-stamped by `NDA_Signed_Status_Sync` (`Stamp_Signed_Date`, gated on
  `Date_Signed_Is_Blank`). Reuse it.
- `NDA_Signed__c` latches true forever; the warning banner is real and verbatim.
- `NDA__c.Party_Role__c` = `{Buyer, Introducing Broker}`; auto-create mints only the Buyer row
  (`DispositionStageEntryService.openBuyerNdas`).
- Every child→`Disposition__c` relationship is a **Lookup**. No roll-up summaries are possible.
- `dispositionMain` is flexipage-gated to 4 of 11 stages (`BOV Outreach`, `Active Listing`,
  `Closing`, `Sale Closes`).
- The disposition LOI terminal is `Executed`; acquisition is `Signed`; `LOI_Signed_Status_Sync` keys
  on `Stage__c = 'Signed'` and is therefore **acquisition-only by construction**, so
  `LOI_Signed_Date__c` is **structurally always blank on a disposition LOI**. The card must not show
  it.
- `TestDataFactory.createBovSubmissions` sets `Broker_Firm__c` / `Contact_Name__c` text and leaves
  `Broker__c` **null**. (This is *also* why the whole existing suite stays green against the
  change-keyed broker stamp — that is a measured fact worth keeping.)
- `BOV_Submission__c` has `enableHistory false`, `sharingModel Private`.
- `BovSubmissionService.replaceSelectedBroker` writes three values and leaves **no** audit trail.
- The append-only log precedent is four instances, all written by an Apex **service**, never a Flow
  or trigger: `Lease_Activity__c`, `Deal_Message__c`, `Counter_Offer__c`, `PSA_Version__c`. All carry
  `Entry_DateTime__c` + `Details__c` (except `PSA_Version__c`, which uses `Version_Date__c` +
  `Summary__c`).

### ⚠ C-12 — Flexipage slot correction

The brief says an always-visible card must not go inside `dispositionMain` **or**
`dispositionSidebar`. That is right, but for two *different* reasons, and only one of them is a
flexipage rule:

| Slot | `visibilityRule` on the flexipage? | Why it is still unsuitable |
|---|---|---|
| `c_dispositionMain` (main) | **Yes** — `1 OR 2 OR 3 OR 4`, four stages | Gated *and* branches internally |
| `dispositionSidebar` (sidebar) | **No — none** | Branches internally in JS: renders only at `BOV Outreach`, `Closing`, and four offer stages. Renders **nothing** at `Disposition Readiness`, `Broker Selection`, `NDA`, `PSA`, `Sale Closes`. |

Genuinely ungated top-level slots in `Disposition_Record_Page`: the `subheader` region (holds only
the Path), the `main` region's `relatedLists` / `ndasList` / `loisList` / `contractReviewsList`
item instances, and the `sidebar` region's two item instances. See §2 C for the recommended
placement.

---

## §1 — SCOPE AND THE TWO CONSTRAINT SOLUTIONS

### 1.1 What is in scope (four workstreams, all user-confirmed)

- **A — Validations.** All four groups: required fields; single-Selected enforcement; the
  `NDA_Signed__c` latch fix; sanity rules.
- **B — Broker replacement history.** New child object, service extension, modal extension, history
  LWC.
- **C — Deal Summary card.** One always-visible LWC on the Disposition record page.
- **D — Buyer activity timeline.** Per-buyer Contact lookups, a materials-released date, a timeline
  component.

### 1.2 🔴 CONSTRAINT 1 — enforcing "only one Selected sibling" without a roll-up and without a VR

**Why the obvious mechanisms are unavailable.** A validation rule evaluates against the single record
being saved and has no access to sibling rows. A roll-up summary requires Master-Detail, and every
child→`Disposition__c` relationship in this module is a Lookup. `NDA_Count__c`'s own field header
states this in terms: *"a validation rule cannot count children."*

**Two viable mechanisms, and the decision.**

| Mechanism | In-repo precedent | Verdict |
|---|---|---|
| Maintained counter on the parent + VR reading the counter | `NDA_Count__c` / `Signed_NDA_Count__c` via the `NDA_Signed_Rollup` **Flow** | **Rejected.** A counter is *eventually* correct — the after-save flow writes the parent after the child commits, so the VR that reads it fires on the *next* save, not this one. That is acceptable for a stage gate (which is what the NDA counters gate) and useless for an exclusivity invariant, which must refuse the offending save itself. It also adds two derived fields and a second automation to keep in sync. |
| **Before-context trigger guard calling `addError()`** | `BovSubmissionTrigger` already carries `before insert, before update`; `DispositionOfferTrigger` carries `before update` | **CHOSEN.** Refuses the save that would create the second Selected row, in the same transaction, with an authored message. |

**Layering placement (per `.claude/rules/apex-layering-rule.md`).** The guard needs a sibling read,
so it cannot be a Domain method (Domain = zero SOQL). It is:

```
BovSubmissionTrigger (before insert, before update)   ← already exists, no change
  └─ BovSubmissionTriggerHandler.beforeInsert/.beforeUpdate   ← route only
       └─ BovSubmissionSelectionGuardService.enforceSingleSelected(List<BOV_Submission__c> incoming,
                                                                   Map<Id,BOV_Submission__c> oldMap)
            └─ BovSubmissionSelector.selectSelectedByDispositionIds(Set<Id>)   ← the ONE query
```

Identical shape for `DispositionOfferTrigger` →
`DispositionOfferSelectionGuardService.enforceSingleSelected` →
`DispositionOfferSelector.selectSelectedByDispositionIds`.

**🔴 REJECT, not self-heal. The justification, because the brief asks for one.**

`BovSubmissionService.replaceSelectedBroker` self-heals (it demotes **all** currently-Selected
siblings) and that is correct **there** and wrong **here**, for four reasons:

1. **The service was ASKED to change the appointment.** A trigger was not. A blind self-heal silently
   demotes a sibling the user never named, in a save that was about something else entirely.
2. **A correct self-heal cannot be a one-field write.** Demoting a submission without also clearing
   its `Approval_Status__c` recreates precisely the state the replace service exists to prevent — an
   `'Approved'` status on a broker who is no longer appointed, which "reads as an appointment nobody
   made" (that class's header, 🔴 block). So the trigger would have to perform a second, consequential
   write with no actor, no reason and no audit trail — while **Workstream B exists specifically
   because that gap is unacceptable.** Self-heal here would create the exact defect B is fixing.
3. **Refusal is the only safe answer to a bulk load.** A data loader pushing 500 rows with three
   Selected on one disposition should be told which rows are wrong, not silently have two of them
   rewritten.
4. **The self-heal already exists at the one place it belongs.** Adding a second, weaker copy in a
   trigger gives the codebase two disagreeing owners of one invariant.

**🔴 THE GUARD MUST NOT FIRE ON THE REPLACE SERVICE'S OWN SWAP — and it will not, if written to the
rule below.** `replaceSelectedBroker` demotes and promotes in a **single**
`Database.update(writes, ...)`, so a before-update context sees both rows. Same for
`DispositionApprovalService.selectOffer` ("`selectOffer` still performs ONE bulk DML over the
disposition's offers"). The evaluation rule is therefore:

> **Error only on a record that is being INSERTED as, or CHANGED TO, Selected, when — after applying
> every incoming row's new value in memory — another Selected sibling remains on the same
> disposition.**

Two corollaries that are load-bearing and must be in the class header:

- **A row already Selected, saved for an unrelated reason, is never blocked.** Otherwise a
  pre-existing double-Selected pair becomes permanently unsavable, i.e. frozen — the failure mode
  `Broker_Lookup_Is_Off_Market_Only`'s header argues at length must be avoided ("an unguarded rule
  cannot trap a record here, and that is what makes it safe").
- **Any save that REDUCES the Selected count is always permitted.** That is the remedy path. A guard
  that blocks the remedy is worse than no guard.

**Bulk safety.**
- Exactly **one** selector query per trigger chunk, keyed on the `Set<Id>` of parent dispositions
  drawn from the incoming rows. No SOQL and no DML inside any loop.
- **Zero-query fast path:** if no incoming row is being inserted-as or changed-to Selected, return
  before the query. This is the same "an ordinary save costs nothing" contract
  `BovSubmissionBrokerStampService` and `DispositionTrigger`'s before path already carry, and it is
  what keeps the guard invisible to the 251-record bulk tests of every unrelated feature.
- The selector method is `WITH SYSTEM_MODE`, justified **at its own declaration** in the selector
  class header on automation-path grounds (ARCHITECTURE.md §2): the running user asked to save a
  submission, not to read its siblings, and `USER_MODE` *throws* rather than degrading — inside a
  before-trigger that throw escapes as `CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY` and rolls back the
  user's own save.
  ⚠ **Sharing is a separate question and the answer is "keep `with sharing`".** Both objects are
  `sharingModel Private`, but every row in scope hangs off a disposition the running user is
  currently editing. This is **not** the `InboundEmailStagingSelector.RoutingReads` shape (rows owned
  by a different principal). Do **not** add a `without sharing` inner class.
  🔴 But note the asymmetry it creates: a sharing-filtered read that misses a Selected sibling
  **inverts the guard into a permitter**, not a blocker. State the residual in the header; it is
  bounded by the fact that the guard is defence in depth behind an authored service, not the primary
  enforcement.

### 1.3 🔴 CONSTRAINT 2 — the `NDA_Signed__c` latch fix that must not break acquisition

**The requirement:** clear `NDA_Signed__c` when an NDA is **Declined**, and never on the legitimate
acquisition `Signed → Sent` transition.

**Why `Sent` is the trap:** the acquisition NDA sequence was reversed on 2026-08-16 to
`Pending → Received → Signed → Sent`, making **`Sent` the acquisition TERMINAL status, reached AFTER
`Signed`**. `Opportunity.NDA_Signed_Before_Deal_Progression` gates Underwriting / LOI / Under
Contract (PSA) / About to Close / Closed Won on `Primary_NDA__r.NDA_Signed__c`. Connecting the
existing `Set_Signed_False` default branch would make the final Advance Stage click un-sign the NDA
and lock the deal out of every stage past the gate. The flow's own banner says so.

**The exact condition — a NEW decision, not the existing default connector.**

```
Is_Signed  (existing)
  ├── Status_Is_Signed  (Status__c = 'Signed')     → Set_Signed_True → Needs_Signed_Date  [UNCHANGED]
  └── defaultConnector "Not Signed"                → Is_Declined     [NEW — this is the only edit]

Is_Declined  (NEW decision)
  ├── Status_Is_Declined  (Status__c = 'Declined') → Set_Signed_False   [the EXISTING, currently
  │                                                                      orphaned assignment]
  └── defaultConnector "Not Declined"              → (end)  [no connector — Pending, Not Sent,
                                                             Sent, Received all fall through
                                                             untouched, INCLUDING acquisition's
                                                             terminal 'Sent']
```

**Why no record-type test is needed, and why that is better than the flow header's own suggestion.**
`Declined` is exposed **only** on the `Disposition_NDA` record type (`NDA__c.Status__c` description,
verified). An acquisition NDA can never carry it, so the new branch is structurally unreachable from
the acquisition path — the exemption is achieved by *naming a value*, not by *testing a record type*.
That is strictly more robust than the header's suggested `RecordType.DeveloperName` branch, because
it survives a record-type rename and it does not depend on rows having been migrated off `Master`
(`RecordStageAdvanceService` still carries a null/Master fallback, and `NdaSelector.queryExpiryAlerts`
records why a record-type filter can ship a feature inert).

**What must change alongside the flow (mandatory, not optional):**

1. `pathAssistants/NDA_Path_Disposition.pathAssistant-meta.xml` lines 22-25 — the claim
   "defaults everything that is not Signed to FALSE" becomes *"clears the checkbox when the NDA is
   marked Declined"*. Retract in place, do not delete (this repo's convention).
2. `objects/NDA__c/fields/Is_Decline_Allowed__c.field-meta.xml` lines 32-34 — same correction to
   "`NDA_Signed_Status_Sync` re-derives `NDA_Signed__c`".
3. `flows/NDA_Signed_Status_Sync.flow-meta.xml`'s in-root comment — the "IF ANYONE CONNECTS THE
   DEFAULT BRANCH" banner is now **partly executed**. Rewrite it to say: the default branch is
   connected to a `Declined`-only decision as of this change; the hazard it warned about is
   `Status != 'Signed' ⇒ false`, which is still forbidden and still would break acquisition.
   🔴 Do not delete the banner — the hazard it names is still live.
4. `NDA__c.NDA_Signed__c`'s field metadata has **no `<description>` at all** today (it is a bare
   9-line file). Add one recording that the checkbox is set on `Signed` and cleared **only** on
   `Declined`, and that it is read by the Opportunity progression gate.

**Behaviour change, stated plainly:** `Signed → Declined` on a disposition NDA now clears
`NDA_Signed__c`, where previously it left it true. `Date_Signed__c` is still never cleared — so a
declined party retains a signature date with a false checkbox. **That asymmetry is exactly why
Workstream D must not key on either field alone** (see §2 D).

---

## §2 — ADMIN WORK (`salesforce-admin` / `salesforce-solution-architect`)

All paths are relative to repo root. API version 67.0 throughout.

### A1 — Required fields

**Decision table: `required=true` vs. validation rule.**

| Field | Mechanism | Why |
|---|---|---|
| `BOV_Submission__c.Broker__c` | 🔴 **Validation rule** — `Broker_Required_On_Submission` | See §0 C-2: `required=true` forces `deleteConstraint` from `SetNull` to `Restrict`, which the field header explicitly forbids. A VR also lets the rule be scoped later (e.g. exempt a status) without a schema change. |
| `BOV_Submission__c.BOV_Amount__c` | **`required=true`** on the field | Currency, no lookup constraint, no delete-constraint interaction. `required` is the cheaper, self-documenting mechanism and it surfaces the asterisk on the layout. ⚠ It also blocks "response logged, amount pending" — confirmed acceptable by the user's "required" instruction. |
| `Disposition_Offer__c` buyer | **Validation rule** — `Buyer_Required_On_Offer` | The buyer field is *changing identity* in Workstream D (Text → Contact lookup as the entry point). A VR is one file to amend; `required=true` on `Buyer_Name__c` would have to be un-set and re-set on the lookup, which is a schema change on live data. See the sequencing note below. |
| `Disposition_Offer__c.Offer_Amount__c` | **`required=true`** on the field | Same reasoning as `BOV_Amount__c`. |

**🔴 SEQUENCING — the offer-buyer requirement depends on Workstream D.** Today the only buyer field
is `Buyer_Name__c` (Text). Workstream D adds a Buyer Contact lookup and makes it the entry point.
**Recommendation:** write `Buyer_Required_On_Offer` against `Buyer_Name__c` now (it is what analysts
type today and it delivers value immediately), and **amend the same rule file** in Workstream D to
require the lookup instead. One file, two edits, no schema churn. The alternative — defer the offer
half to D — is acceptable but delays half of A1 to the last tranche.

**Files:**

```
force-app/main/default/objects/BOV_Submission__c/validationRules/Broker_Required_On_Submission.validationRule-meta.xml   [NEW]
force-app/main/default/objects/BOV_Submission__c/fields/BOV_Amount__c.field-meta.xml                                      [EDIT: required=false → true]
force-app/main/default/objects/Disposition_Offer__c/validationRules/Buyer_Required_On_Offer.validationRule-meta.xml        [NEW]
force-app/main/default/objects/Disposition_Offer__c/fields/Offer_Amount__c.field-meta.xml                                 [EDIT: required=false → true]
```

**Formula shapes** (the implementing agent owns the final text; these are the semantics):
- `Broker_Required_On_Submission` — `ISBLANK(Broker__c)`. **No `ISCHANGED`/`ISNEW` guard**, matching
  `Broker_Lookup_Is_Off_Market_Only`'s reasoning: this is an INVARIANT, not a transition, and an
  unguarded rule here is self-clearing (the remedy — picking a broker — is itself a permitted save).
  `errorDisplayField` = `Broker__c`.
- `Buyer_Required_On_Offer` — `ISBLANK(Buyer_Name__c)` (→ `ISBLANK(Buyer__c)` after D).
  `errorDisplayField` = the field named.

**🔴 A1 BLAST RADIUS — `TestDataFactory` and the whole BOV test surface.**

`TestDataFactory.createBovSubmissions` (line 2496) sets `Broker_Firm__c` / `Contact_Name__c` and
leaves `Broker__c` **null**. Every fixture it produces will be refused the moment
`Broker_Required_On_Submission` deploys. Required changes:

1. `createBovSubmissions(Integer, Id, Boolean)` must set `Broker__c`. It needs a broker Contact, and
   `Broker__c` carries an **ACTIVE, non-optional lookup filter** on `Contact.Is_Broker__c = true`, so
   it must come from `createBrokerContact` / `createBrokerContacts`, never `createContacts`.
2. Add a **lazily-built shared broker scaffold** (`defaultBrokerContact()`), mirroring
   `defaultPropertyAsset()` / `defaultDisposition()`, so a 251-record setup stays one line and one
   Contact serves all 251 submissions. Do **not** mint 251 Contacts.
3. Add a `createBovSubmissions(count, dispositionId, brokerId, doInsert)` overload for tests that
   need distinct brokers per submission (the BOV comparison matrix tests do).
4. ⚠ `Broker_Firm__c` / `Contact_Name__c` must **stop** being hard-set by the factory where the
   `Broker__c` stamp now derives them — otherwise fixtures assert against factory strings that
   `BovSubmissionBrokerStampService` overwrites. Check each call site.
5. `BOV_Amount__c` is already set by the factory — `required=true` needs no factory change there.
6. `createDispositionOffers` already sets `Buyer_Name__c` and `Offer_Amount__c` — no change needed
   for A1, but see D.
7. 🔴 **Sweep the seed scripts.** `scripts/seed-disposition-bulk.apex` and
   `scripts/seed-disposition-offers.apex` are modified-but-uncommitted right now and will break the
   same way. `scripts/seed-broker-contacts.apex` holds the `BROKER_LOOKUPS` map that must already
   know about `BOV_Submission__c.Broker__c`; verify it does.

### A2 — Single-Selected enforcement (ADMIN portion: none)

No admin metadata. The mechanism is a trigger guard — see §3 D2/D3. Listed here only so the
workstream reads complete.

### A3 — `NDA_Signed__c` latch fix

```
force-app/main/default/flows/NDA_Signed_Status_Sync.flow-meta.xml                       [EDIT — see §1.3]
force-app/main/default/pathAssistants/NDA_Path_Disposition.pathAssistant-meta.xml       [EDIT — correct lines 22-25]
force-app/main/default/objects/NDA__c/fields/Is_Decline_Allowed__c.field-meta.xml       [EDIT — correct lines 32-34]
force-app/main/default/objects/NDA__c/fields/NDA_Signed__c.field-meta.xml               [EDIT — add <description>]
```

Flow edit is: add one `<decisions>` element (`Is_Declined`), add a `<defaultConnector>` to
`Is_Signed` pointing at it, add a `<connector>` from the new decision's `Status_Is_Declined` rule to
the existing `Set_Signed_False` assignment. **`Set_Signed_False` itself is unchanged** — it stops
being orphaned, which is the whole point.

⚠ Increment the flow's version and update the paired `FlowDefinition` `activeVersionNumber` per this
repo's existing flow-deploy convention.

### A4 — Sanity rules

Six new validation rules across three objects. None of these objects has a validation rule today, so
each is the first on its object.

```
force-app/main/default/objects/Disposition_Offer__c/validationRules/Counter_Price_Is_Positive.validationRule-meta.xml       [NEW]
force-app/main/default/objects/Disposition_Offer__c/validationRules/Term_Days_Are_Not_Negative.validationRule-meta.xml      [NEW]
force-app/main/default/objects/LOI__c/validationRules/Counter_Price_Is_Positive.validationRule-meta.xml                     [NEW]
force-app/main/default/objects/LOI__c/validationRules/Term_Days_Are_Not_Negative.validationRule-meta.xml                    [NEW]
force-app/main/default/objects/LOI__c/validationRules/Final_Price_Required_Before_Executed.validationRule-meta.xml          [NEW]
force-app/main/default/objects/Contract_Review__c/validationRules/Execution_Date_Not_In_Future.validationRule-meta.xml      [NEW]
```

| Rule | Object | Fields (all verified present) | Semantics |
|---|---|---|---|
| `Counter_Price_Is_Positive` | `Disposition_Offer__c` | `Buyer_Counter_Price__c`, `DPEG_Counter_Price__c` | `OR(<field> <= 0, ...)` — null-safe via `NOT(ISBLANK(...))` first. A blank counter is legitimate; a zero or negative one is not. |
| `Counter_Price_Is_Positive` | `LOI__c` | `Counter_Price__c` | Same. |
| `Term_Days_Are_Not_Negative` | `Disposition_Offer__c` | `Closing_Period_Days__c`, `Due_Diligence_Days__c` | `< 0` blocked. **Zero is permitted** (an all-cash no-DD offer is real). |
| `Term_Days_Are_Not_Negative` | `LOI__c` | `Closing_Period_Days__c`, `Due_Diligence_Days__c` | Same. |
| `Final_Price_Required_Before_Executed` | `LOI__c` | `Final_Agreed_Price__c`, `Stage__c` | Blocks `Stage__c` moving to **`Executed`** while `Final_Agreed_Price__c` is blank. 🔴 **`Executed`, not `Signed`** — `Executed` is the DISPOSITION terminal; `Signed` is acquisition's and this rule must not fire there. Use `TEXT(Stage__c) = "Executed"`, never `ISPICKVAL` (`RecordStageAdvanceService`'s standing rule; `Prepare/Review`'s literal slash is the reason). Guard with `ISCHANGED(Stage__c)` so it gates the transition, matching `All_NDAs_Signed_Before_Progression`. |
| `Execution_Date_Not_In_Future` | `Contract_Review__c` | `Execution_Date__c` | `Execution_Date__c > TODAY()`. Unguarded invariant (self-clearing). |

**⚠ Two things the implementing agent must respect on every one of these six files:**

1. **The rationale comment goes INSIDE the root element.** `ValidationRule.Description` is capped at
   255 characters; a comment above `<ValidationRule>` breaks `sf` deploy at conversion with a
   misleading "unable to find matching parent xml file" error. Every existing VR in this repo carries
   that warning verbatim — copy it.
2. **`LOI__c` and `Contract_Review__c` are DUAL-RECORD-TYPE objects serving both modules.** A rule
   deployed on either fires on **acquisition** records too. `Counter_Price_Is_Positive` and
   `Term_Days_Are_Not_Negative` are safe there (they are arithmetic invariants true on both paths).
   `Final_Price_Required_Before_Executed` is safe **only because it names `Executed`**, which
   acquisition never reaches. `Execution_Date_Not_In_Future` on `Contract_Review__c` **DOES fire on
   acquisition PSAs** — confirm that is intended (it almost certainly is; a future execution date is
   wrong on either path) and say so in the rule's comment.
   🔴 Do **not** attempt to scope these with `RecordType.DeveloperName` "for safety" — see
   `Broker_Lookup_Is_Off_Market_Only`'s Master-record-type argument and
   `NdaSelector.queryExpiryAlerts`'s "ships inert" warning. A value-named rule is more robust here.

### A5 — Permission-set FLS (spans all four workstreams)

```
force-app/main/default/permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml   [EDIT]
force-app/main/default/permissionsets/DPEG_Disposition_View.permissionset-meta.xml   [EDIT]
```

🔴 **A `PermissionSet` deploy REPLACES the file's entire `fieldPermissions` set.** Every edit must be
**surgical and diffed against `HEAD`** before deploy. This repo has already paid for that once.

**Grants required (readable=true; editable per the table):**

| Field | Edit set | View set | Needed by |
|---|---|---|---|
| `NDA__c.Date_Signed__c` | read + **edit** | read | C, D |
| `NDA__c.Disposition__c` | read | read | C, D — **and it retroactively fixes the BOV pill, §0 C-1** |
| `NDA__c.Buyer__c` *(new, D)* | read + edit | read | D |
| `NDA__c.Counterparty_Name__c` *(becomes derived in D)* | read (**not** edit — it is stamped) | read | D |
| `NDA__c.Materials_Released_Date__c` *(new, D)* | read + edit | read | D |
| `Disposition_Offer__c.Buyer__c` *(new, D)* | read + edit | read | D |
| every field on the new history object *(B)* | read only — the object is **written only by the service** | read only | B |

**⚠ `NDA__c.NDA_Signed__c` is deliberately NOT granted to the disposition sets.** Workstream D
forbids reading it (§2 D), and granting a field only so that nobody may use it re-opens the exact
trap. Leave it out.

**⚠ `DPEG_Admin_Access` is NOT a casualty here and must NOT be widened.** Measured: it grants **zero**
`BOV_Submission__c` business fields and zero of the four `NDA__c` disposition fields today, so a bare
administrator already cannot read this module's business fields. This tranche creates no new admin
regression. Do not "fix" a problem it does not have.
🔴 But acceptance MUST still include opening the Disposition record page **as a user holding
`DPEG_Disposition_Edit`** — an analyst smoke test against a System Administrator session proves
nothing about a `Minimum Access` persona.

**⚠ Object-level CRUD for the new B object.** `DPEG_Disposition_Edit` must carry `allowRead=true`
with `allowCreate` / `allowEdit` / `allowDelete` **false** (the service writes in `SYSTEM_MODE`; a
history row a user can edit is not history). `DPEG_Disposition_View` gets read-only. Mirror the
`Disposition_Offer__c.Is_Selected__c` FLS argument.

### A6 — Flexipage placement (Workstreams B and C)

```
force-app/main/default/flexipages/Disposition_Record_Page.flexipage-meta.xml   [EDIT]
```

- **C — Deal Summary card:** add a new `<itemInstances>` as the **FIRST** item in the `sidebar`
  region (before `dispositionSidebar`), with **no `visibilityRule`**. Rationale: the sidebar is where
  a user glances; it is the only region with a genuinely ungated top-level slot that is not a related
  list; and putting it above `dispositionSidebar` means it is present on the seven stages where
  `dispositionSidebar` renders nothing at all.
  *Alternative if the user prefers the main column:* a new `<itemInstances>` in the `main` region
  **after `contractReviewsList`**, also ungated. Both are ungated slots; the sidebar is recommended.
- **B — history LWC:** add a new `<itemInstances>` in the `main` region **after
  `contractReviewsList`** (the brief's named slot), ungated. History is a reading surface, not a
  glance surface, and the main column has the width for a multi-column table.

🔴 **Two flexipage hazards this repo has measured:**
1. A FlexiPage deploy can roll back on a design-time error and **report success**. Read the page back
   after deploying.
2. Do **not** enable Dynamic Actions on this page while editing it in App Builder — it silently
   empties the inherited action bar, and no automated check sees it.

### A7 — New object metadata for Workstream B

See §3 D4 for the object/field inventory (it is listed with the development work because the service
and the schema are one change). Admin owns the `.object-meta.xml`, `fields/`, `listViews/`,
`compactLayouts/`, the layout, and the sharing rule.

🔴 **Sharing rules deploy ONE AT A TIME.** A batch rolls all of them back. Every disposition child
object in this repo has a `sharingRules` file (`BOV_Submission__c`, `Broker_Listing__c`,
`Disposition_Offer__c`, `NDA__c`, `Disposition__c`); the new object needs one modelled on
`BOV_Submission__c.sharingRules-meta.xml` (one `sharingOwnerRules` entry, `Edit` to
`DPEG_Acquisitions_Team` from `roleAndSubordinates: Acquisitions_Analyst`).
⚠ Group and queue membership is **not deployable** — confirm the group exists in the target org.

---

## §3 — DEVELOPMENT WORK (`salesforce-developer`)

### D1 — (reserved: no dev work in A1/A3/A4 beyond the `TestDataFactory` changes in A1)

`TestDataFactory` edits listed under A1 are **development** work and must go to the developer agent,
not the admin agent. They are the largest single risk in Workstream A.

### D2 — BOV single-Selected guard

**New:**
```
force-app/main/default/classes/BovSubmissionSelectionGuardService.cls   (+ -meta.xml)
force-app/main/default/classes/BovSubmissionSelectionGuardServiceTest.cls
```
**Edited:**
```
force-app/main/default/classes/BovSubmissionSelector.cls        — add selectSelectedByDispositionIds(Set<Id>)
force-app/main/default/classes/BovSubmissionTriggerHandler.cls  — route beforeInsert/beforeUpdate to the guard
```
**Unchanged:** `triggers/BovSubmissionTrigger.trigger` — it already declares
`before insert, before update, after update`. ✅ No context expansion needed. (Contrast D3.)

**Signature:**
```apex
public static void enforceSingleSelected(List<BOV_Submission__c> incoming,
                                         Map<Id, BOV_Submission__c> oldMap)
```
`oldMap` is null on insert. Semantics, fast path, sharing/mode and the reject-not-self-heal argument
are specified in §1.2 — **copy that reasoning into the class header verbatim in substance**; the
downstream agents do not read this document.

**Selector method:**
```apex
public static List<BOV_Submission__c> selectSelectedByDispositionIds(Set<Id> dispositionIds)
// SELECT Id, Disposition__c, Submission_Status__c
// FROM BOV_Submission__c
// WHERE Disposition__c IN :dispositionIds AND Submission_Status__c = 'Selected'
// WITH SYSTEM_MODE
```
Null/empty-safe, returns empty list. `WITH SYSTEM_MODE` justified **at the method's own Javadoc**
(ARCHITECTURE.md §2 says the class headers are the authoritative inventory — and `NdaSelector`'s
header records that this repo has already miscounted that inventory once, so **re-count, don't
assert**).

### D3 — Offer single-Selected guard

**New:**
```
force-app/main/default/classes/DispositionOfferSelectionGuardService.cls   (+ -meta.xml)
force-app/main/default/classes/DispositionOfferSelectionGuardServiceTest.cls
```
**Edited:**
```
force-app/main/default/classes/DispositionOfferSelector.cls        — add selectSelectedByDispositionIds(Set<Id>)
force-app/main/default/classes/DispositionOfferTriggerHandler.cls  — route beforeInsert/beforeUpdate
force-app/main/default/triggers/DispositionOfferTrigger.trigger    — 🔴 ADD `before insert`
```

🔴 **`DispositionOfferTrigger` currently declares `(before update, after update)`.** Adding
`before insert` is its own change with its own blast radius: the trigger now fires on **every**
`Disposition_Offer__c` insert in the org, where previously nothing did. That is safe **only** because
of the zero-query fast path (§1.2). The trigger file's header carries an argument for the current
two-context split ("BOTH CONTEXTS, AND THE SPLIT IS THE SAME ONE `DispositionTrigger` MAKES") that
becomes incomplete — **correct it in place, retracting rather than deleting**, exactly as
`BovSubmissionTrigger`'s header was corrected on 2026-08-20.

⚠ Priority: this guard closes the API-only residual described in §0 C-3. If delivery is split, D3
lands **after** D2.

### D4 — Workstream B: broker replacement history

#### D4.1 New object

**Proposed API name: `BOV_Broker_Change__c`.**
⚠ **OPEN NAMING ITEM — flagged, not invented.** The user did not name it. Alternatives considered:
`Broker_Replacement__c` (ambiguous with `Broker_Assignment__c`'s replace), `BOV_Broker_History__c`
("History" collides with the platform's `__History` concept). `BOV_Broker_Change__c` follows
ARCHITECTURE.md §1 (`Title_Case_With_Underscores`, no prefix, acronym fully uppercase) and reads
correctly under the Disposition related list. **Pick one spelling and use it everywhere.**

Object settings: `nameField` AutoNumber `BBC-{0000}`; `sharingModel Private`; `externalSharingModel
Private`; `enableHistory false`; `enableActivities false`; `enableReports true`; `enableSearch true`;
`enableBulkApi true`; `deploymentStatus Deployed`; `visibility Public`. (Copied from
`BOV_Submission__c.object-meta.xml`.)

#### D4.2 Fields

| API name | Type | Notes |
|---|---|---|
| `Disposition__c` | Lookup → `Disposition__c` | The anchor. Relationship name `BOV_Broker_Changes`; **check the name is free on `Disposition__c` before deploying** (relationship names are unique per parent). `deleteConstraint SetNull`. |
| `Outgoing_BOV_Submission__c` | Lookup → `BOV_Submission__c` | ⚠ Two lookups to one object cannot both be named `BOV_Submission__c`; the convention's own "API names must be unique" escape applies. **OPEN NAMING ITEM.** |
| `Incoming_BOV_Submission__c` | Lookup → `BOV_Submission__c` | Same. |
| `Outgoing_Broker__c` | Lookup → `Contact` | Role-named lookup — explicitly permitted by ARCHITECTURE.md §1. ⚠ Add the **same active, non-optional `Is_Broker__c = true` lookupFilter** the four sibling broker lookups carry, or a hand-crafted row can name a non-broker. |
| `Incoming_Broker__c` | Lookup → `Contact` | Same. |
| `Outgoing_Broker_Firm__c` | Text(255) | 🔴 **A SNAPSHOT, and it is not redundant.** `scripts/seed-broker-contacts.apex` mass-deletes every broker Contact and all these lookups are `SetNull` — so the lookups can be nulled with no error. A history row whose broker column reads blank is not history. Stamp the firm string at write time. |
| `Incoming_Broker_Firm__c` | Text(255) | Same. |
| `Reason__c` | Picklist, **restricted** | ⚠ **OPEN DECISION — values not specified by the user.** `Broker_Assignment__c.Reason_Ended__c` is `{Leased Up, Performance Issue, Company Decision, Other}` — "Leased Up" is a leasing term and wrong for a disposition BOV. **Proposed, needs confirmation:** `Performance Issue`, `Better BOV Received`, `Broker Withdrew`, `Company Decision`, `Other`. Do not ship without a decision. |
| `Notes__c` | Long Text Area(32768) | Mirrors `Broker_Assignment__c.Replacement_Notes__c`. |
| `Entry_DateTime__c` | DateTime | Matches the four-instance append-only-log convention (`Lease_Activity__c`, `Deal_Message__c`). |
| `Logged_By__c` | Lookup → `User` | The actor. Precedent name: `Lease_Activity__c.Logged_By__c`. ⚠ `CreatedById`/`CreatedDate` are free and automatic and would cover both this and `Entry_DateTime__c`; the explicit fields are specified because the brief says "mirror the existing pattern" and the pattern uses them. Flag to the user if they'd rather use the free system fields. |

🔴 **Check every proposed `<label>` against the object's siblings before writing it.** Salesforce
permits duplicate labels and they make the report field picker, the Setup field list and the Dynamic
Forms palette unusable. This repo has already been bitten (`Contact_Name__c` was already labelled
"Contact" and `Broker_Display__c` "Broker" on `BOV_Submission__c`).

#### D4.3 Service change

```
force-app/main/default/classes/BovSubmissionService.cls   [EDIT — signature change]
```

```apex
// BEFORE
public static String replaceSelectedBroker(Id dispositionId, Id newSubmissionId)
// AFTER  (mirrors BrokerAssignmentService.replaceBroker's 5-param shape)
public static String replaceSelectedBroker(Id dispositionId, Id newSubmissionId,
                                           String reason, String notes)
```

The history row is inserted **inside the existing savepoint**, alongside the two existing writes. All
three (or four) writes commit or none do. 🔴 **The history insert must be the LAST DML**, after the
submission swap and the parent stamp — a history row recording a replacement that then failed is
worse than no history.

⚠ **The service's class header currently says "1 SOQL + 2 DML".** That becomes 1 SOQL + 3 DML.
Correct the budget line; this repo treats those budgets as contracts.
⚠ The header's BULK block ("per-transaction-singleton @AuraEnabled operation… the 251-record mandate
does not apply") is **still true** and should be carried forward unchanged.

Effective date: `BrokerAssignmentService.replaceBroker` takes an `effectiveDate` parameter. **The
user did not ask for one here** and `Entry_DateTime__c` is the write time. Do **not** add an
effective-date parameter — that is scope the user did not request. (Flagged so the "mirror exactly"
instruction is not over-applied.)

#### D4.4 Controller change

```
force-app/main/default/classes/BovController.cls   [EDIT]
```
`replaceSelectedBroker` gains `reason` and `notes` parameters and passes them straight through. The
three-catch structure, their order, and both fixed generic messages are **unchanged** — that
structure is documented and deliberate.

#### D4.5 Modal change

```
force-app/main/default/lwc/bovReplaceBrokerModal/bovReplaceBrokerModal.html   [EDIT]
force-app/main/default/lwc/bovReplaceBrokerModal/bovReplaceBrokerModal.js     [EDIT]
force-app/main/default/lwc/bovReplaceBrokerModal/__tests__/…                  [NEW/EDIT]
```
Add a **reason** `lightning-combobox` (required) and a **notes** `lightning-textarea` (optional).
🔴 **The `handleConfirm` parameter names must match the new Apex signature verbatim** — the file
already carries that instruction as a comment.
🔴 **Do not re-author the returned warning message.** The component's header forbids it, at length,
for a reason that still holds.
⚠ Source the reason picklist values via `getPicklistValues` / `getObjectInfo` (LDS), not a hardcoded
JS array — a hardcoded array silently diverges the day someone adds a value.

#### D4.6 History LWC + controller

```
force-app/main/default/lwc/bovBrokerChangeHistory/…              [NEW]
force-app/main/default/classes/BovBrokerChangeController.cls     [NEW]  (thin)
force-app/main/default/classes/BovBrokerChangeSelector.cls       [NEW]  (WITH USER_MODE — read-for-display)
```
Modelled on `brokerAssignmentHistory`: rows sorted most-recent-first, `Reason:` line, notes preview
truncated at 60 chars with a "View" popup, an intro line in the same voice ("Every broker ever
appointed to this sale — nothing is deleted.").
⚠ Anchored on `recordId = Disposition__c.Id`, **not** an assignment Id.
⚠ **Empty state matters here more than on `brokerAssignmentHistory`.** Most dispositions will never
have a replacement. Render "No broker changes recorded" — never an error banner, never a spinner
that never resolves.

`WITH USER_MODE` on the selector (a read the user asked for). 🔴 Whoever adds a field to that SELECT
later must re-check the FLS grant matrix — see §0 C-1 for what happens when they don't.

### D5 — Workstream C: Deal Summary card

```
force-app/main/default/lwc/dispositionDealSummary/dispositionDealSummary.js           [NEW]
force-app/main/default/lwc/dispositionDealSummary/dispositionDealSummary.html         [NEW]
force-app/main/default/lwc/dispositionDealSummary/dispositionDealSummary.css          [NEW]
force-app/main/default/lwc/dispositionDealSummary/dispositionDealSummary.js-meta.xml  [NEW]
force-app/main/default/lwc/dispositionDealSummary/__tests__/dispositionDealSummary.test.js [NEW]
```

**Data access decision: IMPERATIVE APEX, not LDS.** ⚠ This diverges from ARCHITECTURE.md §5's
LDS-first priority and the divergence must be argued in the component header. The reason:

- The card needs the **latest child of three different objects** (`NDA__c`, `LOI__c`,
  `Contract_Review__c`) hanging off one `Disposition__c`, plus two parent counters.
- `getRelatedListRecords` would need three separate wires, each of which must be sorted and
  truncated client-side, and none of which can express "latest by `CreatedDate` with an `Id DESC`
  tie-break" — a tie-break `NdaSelector.selectLatestByDispositionId` documents as **required**
  (CreatedDate is second-granular; two NDAs in one second make the card non-deterministic).
- ARCHITECTURE.md §5 item 3 permits imperative Apex "when LDS cannot express the query".
- The controller must be a thin wrapper over a service/selectors, per the layering rule.

**Recommended alternative if the user prefers LDS:** `NDA_Count__c` and `Signed_NDA_Count__c` are
already on the parent, so an `getRecord` wire on `Disposition__c` covers the NDA *counts* with zero
Apex; only the LOI and PSA rows need Apex. Flag this as a possible simplification but ship the Apex
version — the LOI/PSA halves need it regardless.

```
force-app/main/default/classes/DispositionDealSummaryController.cls  [NEW — thin]
force-app/main/default/classes/DispositionDealSummaryService.cls     [NEW — orchestration, zero SOQL]
force-app/main/default/classes/LoiSelector.cls                       [EDIT — add selectLatestByDispositionId]
force-app/main/default/classes/ContractReviewSelector.cls            [EDIT — add selectLatestByDispositionId]
force-app/main/default/classes/NdaSelector.cls                       [EDIT — see field-list note below]
```

**Exact field set the card displays:**

| Row | Fields | Notes |
|---|---|---|
| **NDA** | `Disposition__c.NDA_Count__c`, `Disposition__c.Signed_NDA_Count__c` (as "3 of 4 signed"), latest `NDA__c.Status__c`, latest `NDA__c.Date_Signed__c` | 🔴 Both counters must be read through `BLANKVALUE`-equivalent null coalescing in JS — pre-existing rows hold **null**, not 0. Every existing reader does this; the card must too. `Date_Signed__c` requires the A5 grant. |
| **LOI** | `LOI__c.Stage__c`, `LOI__c.Offer_Price__c`, `LOI__c.Ball_In_Court__c` | 🔴 **`LOI_Signed_Date__c` is EXCLUDED — it is structurally always blank on a disposition LOI** (§0 C-11). Displaying it would render a permanent em-dash that reads as missing data. **`LOI_Status__c` is EXCLUDED** — no automation sets it, so it reads `Draft` beside a `Stage__c` of `Executed` (§0 C-10). Both exclusions must be stated in the component header or someone will "fix" the omission. |
| **PSA** | `Contract_Review__c.Negotiation_Status__c`, `Contract_Review__c.Execution_Date__c`, `Contract_Review__c.Latest_Version__c` | All three granted in both permission sets already. ✅ No FLS work. |

**Fail-soft per row, not per card.** 🔴 Follow `BovController.readNdaStatusFailSoft`'s precedent
exactly: each of the three reads gets its own **narrow** try/catch so an FLS gap on one object
degrades one row instead of blanking the whole card. That method's header explains why in terms —
copy the reasoning. This matters here more than anywhere, because the card is on **every stage**: a
card that red-banners is a permanent eyesore on 11 stages instead of 4.

**Placement:** §2 A6. Ungated slot. `js-meta.xml` targets `lightning__RecordPage`, `apiVersion 67.0`,
`isExposed true`, `<property name="recordId" type="String"/>`.
⚠ **`<description>` in a `.js-meta.xml` is capped at 255 characters and ONLY a deploy catches a
breach** — Jest, the SLDS linter and code review have all passed a 258-character one in this repo.

### D6 — Workstream D: buyer activity timeline

#### D6.1 Schema (admin-owned files, dev-owned consequences)

```
force-app/main/default/objects/NDA__c/fields/Buyer__c.field-meta.xml                     [NEW — Lookup → Contact]
force-app/main/default/objects/NDA__c/fields/Materials_Released_Date__c.field-meta.xml   [NEW — Date]
force-app/main/default/objects/Disposition_Offer__c/fields/Buyer__c.field-meta.xml       [NEW — Lookup → Contact]
```

**Naming:** `Buyer__c` on both — a role-named `Contact` lookup, explicitly permitted by
ARCHITECTURE.md §1, and unique on each object. ⚠ Check the label against each object's existing
labels first (see D4.2's duplicate-label warning). Relationship names: `Buyer_NDAs` /
`Buyer_Disposition_Offers` on `Contact` — **verify both are free** (the four existing `Contact`
lookups use `Broker_Assignments`, `Brokered_Dispositions`, `Lease_Inquiries`,
`Brokered_Opportunities`, plus `Brokered_BOV_Submissions` added 2026-08-20).

**🔴 LOOKUP FILTER — RECOMMENDATION: leave BOTH UNFILTERED, and do NOT add `Is_Buyer__c`.**
The user asked for a recommendation. Reasons:
1. `Is_Broker__c` works because a broker is a **durable role** — the same Contact brokers many deals
   over years, and `seed-broker-contacts.apex` maintains the population. A buyer is **deal-scoped**:
   the counterparty on one sale, often a one-time principal, frequently created *at the moment* the
   NDA is opened.
2. An **active, non-optional** filter (which is what all four broker lookups use) would make the
   analyst set a checkbox on a brand-new Contact before they can name them on an NDA — a two-step
   dance during a live negotiation, with a refusal message that names an internal field.
3. `Is_Broker__c` has a real maintenance cost this repo already carries: `TestDataFactory` needed a
   whole `createBrokerContacts` family, and every fixture that forgets it fails on the filter. A
   second such field doubles that.
4. There is **no population to filter against**. `Is_Broker__c` was added with a seed script behind
   it; `Is_Buyer__c` would be false on 100% of Contacts on day one and the lookup would offer
   nothing.

**If the user wants scoping anyway:** add `Is_Buyer__c` with an **`isOptional=true`** lookupFilter
(a suggestion, not a refusal). Do not ship an active non-optional one.

**`Materials_Released_Date__c` — RECOMMENDATION: BOTH (analyst-entered, with a default on stage
entry).** Reasons:
- A pure default cannot express "materials went to buyer A on Tuesday and buyer B on Friday", which
  is the whole point of making it per-buyer.
- A pure manual field will be blank on most rows, and the timeline's middle hop disappears.
- The default gives a correct value for the common case (everyone gets the package when the
  disposition enters `Release Materials`) and the analyst overrides the exceptions.
- **Placement:** a new private method in `DispositionStageEntryService`, alongside the existing
  `openBuyerNdas` / `stampListingDates` / `openBrokerListings`. It runs on entry to
  `Release Materials`, and it must be **idempotent and blank-only** — stamp only where
  `Materials_Released_Date__c` is null, never overwrite. That is the same shape as
  `NDA_Signed_Status_Sync`'s `Date_Signed_Is_Blank` gate and `openBuyerNdas`'s idempotency guard.
- ⚠ It writes a **child** record from a **parent** trigger, so it is an **after** context (the child
  is not the record being saved and is not the record any approval locks).

#### D6.2 Stamp services (mirror `BovSubmissionBrokerStampService` — SKELETON, not body)

```
force-app/main/default/classes/NdaBuyerStampService.cls                     [NEW]
force-app/main/default/classes/DispositionOfferBuyerStampService.cls        [NEW]
force-app/main/default/triggers/NdaTrigger.trigger                          [NEW]  🔴
force-app/main/default/classes/NdaTriggerHandler.cls                        [NEW]  🔴
force-app/main/default/triggers/DispositionOfferTrigger.trigger             [EDIT — before insert, see D3]
force-app/main/default/classes/DispositionOfferTriggerHandler.cls           [EDIT]
force-app/main/default/classes/ContactSelector.cls                          [EDIT — bulk name/firm read]
```

**🔴 `NDA__c` HAS NO TRIGGER TODAY.** `NdaTrigger` + `NdaTriggerHandler` are new artefacts. The
trigger must declare `before insert, before update` (before-context, so the stamp rides the user's
own save and no lock can refuse it). Its header must state that it is the **only** `NDA__c` trigger
in the org and that it fires on **every** `NDA__c` insert and update **including acquisition NDAs** —
which is safe only because the stamp is change-keyed and returns after one in-memory pass with **zero
queries** when `Buyer__c` did not change.

**Mirror from `BovSubmissionBrokerStampService`:**
- change-keyed detection (`if (newRec.Buyer__c == priorBuyer) continue;`) — this is what structurally
  protects every other writer;
- two-pass collect-then-assign;
- exactly one selector query per chunk;
- the before-context / `ENTITY_IS_LOCKED` argument;
- the constant-query-budget contract.

**Do NOT mirror the composition logic.** `DispositionBrokerStampService` composes ONE field from
`Name + ' - ' + Firm` via `composeLabel()` with a 244-char length proof. Here it is **one field
copied straight across** on each object:
- `NDA__c.Buyer__c` → `NDA__c.Counterparty_Name__c` (Text 120 — 🔴 **truncate at 120, not 244**; a
  `Contact.Name` longer than 120 chars is possible and a `STRING_TOO_LONG` on an NDA save is a hard
  failure);
- `Disposition_Offer__c.Buyer__c` → `Disposition_Offer__c.Buyer_Name__c` (Text — check the length in
  the field file and truncate to it).

So `SEPARATOR`, `composeLabel` and the arithmetic are all wrong to copy and each would ship as
plausible-looking dead or incorrect code.

**Writer table — build it before writing the guard.** Who now re-enters these new before contexts?
`DispositionStageEntryService.openBuyerNdas` (auto-creates the Buyer NDA), `RecordStageAdvanceService`,
the `NDA_Signed_Status_Sync` before-save flow, `NdaExpiryAlertBatch.MarkerWrites`,
`DispositionNdaStampQueueable`, `TestDataFactory`, hand edits. The change-keyed guard makes them all
skips.
✅ **And `TestDataFactory` setting the derived TEXT but never the LOOKUP is why the existing test
suite stays green by construction.** Say that in the doc and in the test class header — it is the
single most reassuring measured fact available and nobody else will find it.

**Seed guard — TWO maps, not one.** `scripts/seed-broker-contacts.apex` holds `BROKER_LOOKUPS`
(broker Contact lookups to null-check) *and* `STORED_DENORM_TEXT`. The new buyer lookups are **not**
broker lookups so they do not belong in `BROKER_LOOKUPS` — but if any seed script mass-deletes buyer
Contacts, the same `SetNull` corruption applies and the stored text is left naming a vanished
Contact. ⚠ `STORED_DENORM_TEXT` is `Map<String, String>` and physically cannot hold two fields per
object; check its shape before extending it.

#### D6.3 Timeline component

```
force-app/main/default/lwc/dispositionBuyerTimeline/…                    [NEW]
force-app/main/default/classes/DispositionBuyerTimelineController.cls    [NEW — thin]
force-app/main/default/classes/DispositionBuyerTimelineService.cls       [NEW — orchestration, zero SOQL]
force-app/main/default/classes/NdaSelector.cls                           [EDIT — selectBuyerTimelineByDispositionId]
force-app/main/default/classes/DispositionOfferSelector.cls              [EDIT — selectEarliestByBuyerIds]
```

**Per buyer, the component computes:**

| Column | Source | Rule |
|---|---|---|
| Buyer | `NDA__c.Buyer__r.Name`, falling back to `Counterparty_Name__c` | The fallback covers rows created before `Buyer__c` existed. |
| NDA signed | `NDA__c.Date_Signed__c` | 🔴 **Only when `Status__c = 'Signed'`.** See below. |
| Materials released | `NDA__c.Materials_Released_Date__c` | Blank is normal. |
| First offer | earliest `Disposition_Offer__c.Offer_Date__c` where `Buyer__c` = this buyer | The clock stops here (user-confirmed). |
| Days to release | `Materials_Released_Date__c − Date_Signed__c` | Null if either end is null. Never render a negative as a duration — render `—` and flag the row. |
| Days for buyer to respond | `first Offer_Date__c − Materials_Released_Date__c` | Same. |

**🔴 THE TIMELINE MUST NOT READ `NDA_Signed__c`. STATE THIS EXPLICITLY IN THE CLASS AND COMPONENT
HEADERS.** The checkbox latches true and — even after Workstream A3 — it is only *cleared* on
`Declined`; it stays true through `Sent`, and it would have stayed true forever for a party who
walked away before A3 landed. Reading it would show a signed NDA for a counterparty who refused.
**Use `Status__c` and `Date_Signed__c`.**

⚠ **And `Date_Signed__c` alone is not sufficient either — this is the sharper half of the same
trap.** `NDA_Signed_Status_Sync` **never clears `Date_Signed__c`**, by explicit design
(`NDA_Path_Disposition`: "it never clears `Date_Signed__c` — so the historical signature date is
retained while the record stops counting as signed"). A `Signed → Declined` party therefore keeps a
non-null `Date_Signed__c`. **The gate is `Status__c = 'Signed'`; `Date_Signed__c` is only the value
displayed once that gate passes.**

**Declined parties — how they render (user asked; `NDA__c.allowDelete` is FALSE by decision D20 so
they persist):**
- **Included, never hidden.** A declined party is audit evidence, and hiding them would make the
  timeline disagree with the NDAs related list sitting on the same page.
- Rendered as a **visually distinct terminated row**: the buyer name, a `Declined` badge, and
  **em-dashes in all three date columns and both duration columns**. Do not show their retained
  `Date_Signed__c` — it is exactly the misleading value this whole section exists to suppress.
- Sorted **last**, after active parties, mirroring `brokerAssignmentHistory`'s active-first sort.
- ⚠ **Accessibility:** a badge or colour alone is not an accessible state. The row must carry the
  word "Declined" as text (or an equivalent `aria-label`), not just a coloured pill. This repo has a
  measured incident of a text→badge swap deleting accessible content that a test already pinned.

**Selector notes:**
- `selectBuyerTimelineByDispositionId` — `WITH USER_MODE` (read the user asked for), selecting
  `Id, Buyer__c, Buyer__r.Name, Counterparty_Name__c, Status__c, Date_Signed__c,
  Materials_Released_Date__c, Party_Role__c`.
  🔴 **Every one of those custom fields is an FLS gate** (§0 C-1, §2 A5) and `USER_MODE` throws on
  the first one missing. The permission-set edit and this method are **one atomic change**; deploy
  the permission sets **before or with** the Apex.
  ⚠ Filter to `Party_Role__c = 'Buyer'` — an `Introducing Broker` NDA is not a buyer and must not
  appear as a timeline row.
- `selectEarliestByBuyerIds(Set<Id> buyerIds, Id dispositionId)` — one query for the whole set, never
  one per buyer. `ORDER BY Offer_Date__c ASC, Id ASC` (tie-break required; `Offer_Date__c` is a
  Date, so ties are routine).

---

## §4 — EXECUTION ORDER AND ACCEPTANCE CRITERIA

### 4.1 🔴 WORKSTREAM SIZING — THE WORKSTREAMS ARE NOT COMPARABLE. SPLIT DELIVERY.

The user asked to be told if any workstream is materially bigger. **Two are.**

| Workstream | New files | Edited files | New Apex classes | New objects | Trigger changes | Size |
|---|---|---|---|---|---|---|
| **A** — Validations | 7 VRs | 2 fields, 1 flow, 3 comment corrections, `TestDataFactory` | 2 guard services + 2 test classes | 0 | 1 (add `before insert` to offers) | **Medium** |
| **B** — Broker history | 1 object + 11 fields + 1 layout + 1 sharing rule + 1 LWC | service signature, controller, modal, 2 permsets, flexipage | 3 | **1** | 0 | **LARGE** |
| **C** — Deal Summary card | 1 LWC + 2 Apex | 3 selectors, 2 permsets, flexipage | 2 | 0 | 0 | **Small–Medium** |
| **D** — Buyer timeline | 3 fields + 1 LWC + 2 stamp services + **1 trigger + 1 handler** + 2 Apex | 3 selectors, 2 handlers, 1 trigger, `DispositionStageEntryService`, 2 permsets, `TestDataFactory` | 5 | 0 | **2** (new `NdaTrigger`; `before insert` on offers) | **LARGEST** |

**D is the largest** — it stands up an entirely new trigger on a dual-module object (`NDA__c` serves
both Acquisitions and Dispositions), expands a second trigger's context list, adds two stamp
services, and touches the org's most heavily-commented selector. **B is second** — it is the only
workstream introducing a new custom object, with the sharing-rule / FLS / layout / relationship-name
tail that implies.

### 4.2 PROPOSED BUILD ORDER (five tranches — recommended split)

```
2.1  A3 (latch fix + 3 comment corrections)
     └─ Smallest, highest correctness value, zero dependencies, and it makes two
        existing repo claims TRUE that are false today.

2.2  A1 (required fields + TestDataFactory + seed sweep) + A4 (sanity rules)
     └─ A1's TestDataFactory work is the largest hidden cost in Workstream A.
        Do it before anything else adds fixtures.
     └─ Buyer_Required_On_Offer targets Buyer_Name__c here; amended in 2.5.

2.3  C (Deal Summary card) + the NDA FLS grants
     └─ Cheap, visible, and its permission-set edit is a prerequisite for 2.5.
     └─ Incidentally repairs the BOV Outreach NDA pill (§0 C-1 item 3).

2.4  B (broker replacement history)
     └─ Self-contained in the BOV module. No dependency on 2.3 or 2.5.

2.5  D (buyer timeline) + A2 (both single-Selected guards)
     └─ A2's offer guard needs `before insert` on DispositionOfferTrigger, and so
        does D's offer buyer stamp. Doing them together means ONE trigger-context
        expansion, one header correction, one blast-radius review.
     └─ Amend Buyer_Required_On_Offer to require Buyer__c.
```

⚠ **If A2's BOV guard is wanted sooner** (it closes a hole a user can hit by hand today, unlike the
offer guard), split it: BOV guard into 2.2, offer guard stays in 2.5. `BovSubmissionTrigger` already
has both before contexts, so the BOV guard costs no trigger change.

### 4.3 DEPLOY ORDERING (within any tranche)

1. **Object / field metadata first.** Apex referencing a new field will not compile until it exists,
   and a layout will not deploy referencing a field that does not exist.
2. **Permission sets before or with the Apex.** They are one atomic change in effect — a `USER_MODE`
   selector widened before its grants lands red-banners the feature. **Diff every permission-set edit
   against `HEAD` first**; a `PermissionSet` deploy replaces the whole `fieldPermissions` set.
3. **Layouts.**
4. **Apex** (selector → service → controller → trigger/handler).
5. **LWC.**
6. **Flexipage last**, and **read it back** — a FlexiPage deploy can roll back on a design-time error
   and report success.
7. **Sharing rules ONE AT A TIME**, on their own, after everything else. A batch rolls all of them
   back.
8. **Flows** (A3): deploy the new version and the `FlowDefinition` together.

### 4.4 TEST REQUIREMENTS

**Bulk (`.claude/rules/bulk-test-rule.md`) — 251 records, and where it does and does not apply:**

| Class | 251 required? | Why |
|---|---|---|
| `BovSubmissionSelectionGuardService` | ✅ **YES** | Trigger-driven, loops over `Trigger.new`. Needs 251-record insert **and** 251-record update tests, forcing a second trigger batch chunk. |
| `DispositionOfferSelectionGuardService` | ✅ **YES** | Same. |
| `NdaBuyerStampService` | ✅ **YES** | Trigger-driven. |
| `DispositionOfferBuyerStampService` | ✅ **YES** | Trigger-driven. |
| `BovSubmissionService.replaceSelectedBroker` | ❌ No | Per-transaction-singleton `@AuraEnabled`; existing exemption in the class header **stays valid** and must be restated in the test class header so review does not demand 251. |
| `BovBrokerChangeController` / `DispositionDealSummaryController` / `DispositionBuyerTimelineController` | ❌ No (volume) | Read-only, one record per call. ✅ But **do** test the timeline with a realistic buyer count and assert a **constant query budget** — see below. |

**🔴 The "unchanged lookup ⇒ text untouched, ZERO queries" falsifier — required for BOTH new stamp
services.** This is the single most valuable test in Workstream D and the one that makes a future
regression fail *here* instead of in production:

```
Given 251 NDAs (resp. offers) with Buyer__c already set and Counterparty_Name__c (resp.
Buyer_Name__c) hand-set to a sentinel string,
When they are updated with Buyer__c UNCHANGED,
Then every sentinel string is byte-identical afterwards
 AND the stamp service performed ZERO SOQL queries.
```
⚠ Capture the query count **inside** the trigger context (a `@TestVisible static Integer
lastRunQueryCount` on the service), **not** via `Limits.getQueries()` after `Test.stopTest()` —
`stopTest` restores the pre-test counters and the obvious assertion is silently vacuous. This repo
has already been bitten.
⚠ Long-text and text fields **strip trailing whitespace on save** — never assert a composed string
survives a DML round-trip byte-for-byte if it ends in whitespace.

**Guard-specific tests (both guards):**
1. Insert one Selected — passes.
2. Insert a second Selected on the same disposition — **refused**, with the authored message.
3. 🔴 **`BovSubmissionService.replaceSelectedBroker` still succeeds** — the demote+promote arrive in
   one DML and net to exactly one Selected. **This is the test that proves the guard did not break
   the existing feature.**
4. 🔴 **`DispositionApprovalService.selectOffer` still succeeds** — same reason.
5. 🔴 A **pre-existing double-Selected pair** can still be repaired: saving one of them to `Backup` is
   permitted. (The freeze-trap test.)
6. A row already Selected, saved for an unrelated field change while a stale second Selected exists,
   is **not** blocked.
7. Two dispositions in one bulk transaction, each getting its own Selected — both pass, **one query
   total**.
8. Bulk 251 with zero Selected changes — **zero queries** (fast path).

**A3 flow tests:**
1. Disposition NDA `Sent → Signed` → `NDA_Signed__c` true, `Date_Signed__c` stamped.
2. Disposition NDA `Signed → Declined` → `NDA_Signed__c` **false**, `Date_Signed__c` **retained**.
3. 🔴 **Acquisition NDA `Signed → Sent` → `NDA_Signed__c` STAYS TRUE.** This is the regression test
   for the entire hazard the flow header warns about. It must exist and it must be named so that
   nobody deletes it.
4. Acquisition NDA `Pending → Received` → checkbox untouched.
5. Opportunity progression past the NDA gate still works after an acquisition NDA reaches `Sent`.

**A1 tests:** every existing test class touching `createBovSubmissions` must still pass — that is the
acceptance criterion, not a new test. Run `RunLocalTests`.
⚠ If ~500 field-access errors appear, that is **permission sets not ASSIGNED to the running user**,
not a code defect. This repo has that measured.

**LWC tests:** Jest + `@sa11y/jest` for all three new components (`bovBrokerChangeHistory`,
`dispositionDealSummary`, `dispositionBuyerTimeline`), per ARCHITECTURE.md §5.
⚠ Assert on the **rendered attribute**, not on the getter — a getter bound to a custom element's
attribute is written unconditionally, so `undefined` renders `title="undefined"`. Return `''`.
⚠ Jest is **local-only** and never deploys. Run the SLDS linter before deploying any LWC.

**Coverage target: 90%+ per class** (ARCHITECTURE.md §2).

### 4.5 ACCEPTANCE CRITERIA

**A1** — Saving a BOV Submission with no `Broker__c` is refused with an authored message naming the
field. Saving one with a broker but no `BOV_Amount__c` is refused by the platform's required-field
error. `RunLocalTests` is green. `scripts/seed-disposition-bulk.apex` runs clean.

**A2** — A second Selected BOV cannot be created on a disposition by any means (UI, API, anonymous
Apex, data loader). Replace Broker still works. Select Offer still works. A pre-existing
double-Selected pair is repairable.

**A3** — Marking a disposition NDA `Declined` clears `NDA_Signed__c` while retaining
`Date_Signed__c`. 🔴 Advancing an acquisition NDA `Signed → Sent` leaves `NDA_Signed__c` **true** and
the Opportunity can still progress past the NDA gate. Three repo comments now match the flow.

**A4** — A negative counter price, a negative term-day count, an `Executed` LOI with no final agreed
price, and a future PSA execution date are each refused. **No acquisition LOI or PSA workflow is
blocked** — verify by running an acquisition PSA to `Executed` and an acquisition LOI to `Signed`.

**B** — Replacing a BOV broker writes a history row carrying both brokers, both firms (as stamped
text), the reason, the notes, the actor and the timestamp. The row survives deletion of both broker
Contacts. Deleting the history row is not possible for any disposition persona. The history LWC
renders on the Disposition record page at **every** stage, and shows an empty state on a disposition
that has never had a replacement. A failed replacement leaves **no** history row (savepoint).

**C** — The Deal Summary card renders on **all 11 disposition stages**, including
`Disposition Readiness`, `Broker Selection`, `NDA`, `PSA` and `Sale Closes` where
`dispositionSidebar` renders nothing. It shows NDA counts (never "null of null"), LOI stage/price/
ball-in-court, and PSA status/execution date/version. It shows **no** LOI signed date and **no** LOI
status. An FLS gap on one object degrades **one row**, not the card.
🔴 **Verified as a user holding `DPEG_Disposition_Edit`**, not as a System Administrator.

**D** — Picking a buyer Contact on an NDA stamps `Counterparty_Name__c`; changing it re-stamps;
leaving it unchanged touches nothing and costs zero queries. Same on `Disposition_Offer__c`.
Entering `Release Materials` stamps `Materials_Released_Date__c` on blank buyer NDAs only, never
overwriting. The timeline shows one row per **buyer** (`Party_Role__c = 'Buyer'` only), computes both
durations, renders a declined party as a terminated row with the word "Declined" and em-dashes in
every date column — **including a declined party whose `Date_Signed__c` is populated.**
🔴 A buyer whose NDA was `Signed` then `Declined` shows **no** signed date.

---

## §5 — RISKS, DATA IMPACT, AND OUT OF SCOPE

### 5.1 Behaviour-changing on live data

| Change | Live-data impact |
|---|---|
| A1 required fields / VRs | 🔴 **Every existing BOV Submission with a null `Broker__c` becomes unsavable** until a broker is picked. §0 C-7: the brief says zero disposition rows exist; a VR header written **2026-08-20** records **8 `On_Market` dispositions**. **Re-run `SELECT COUNT(Id) FROM BOV_Submission__c WHERE Broker__c = null` at deploy time.** A non-zero result is an escalation, not a deploy. |
| A3 latch fix | Changes behaviour only on `→ Declined`. No existing row is rewritten (a before-save flow does not retro-fire). 🔴 Existing `Declined` NDAs keep `NDA_Signed__c = true` until they are next saved. If any exist, a one-off touch-update is needed — **check and decide; do not assume zero**. |
| A4 sanity rules | Any existing row already violating an invariant becomes unsavable. All four rules are self-clearing (the remedy is a permitted save). Re-measure `Contract_Review__c` for future execution dates before deploying `Execution_Date_Not_In_Future`. |
| A2 guards | No existing row is rewritten. A disposition already carrying two Selected rows keeps them — the guard only refuses *new* violations, and the repair path stays open by design. |
| B | Additive. No existing behaviour changes except `replaceSelectedBroker`'s signature (an internal API with exactly two callers). |
| C | Purely additive read surface. |
| D | Additive schema. The `Release Materials` default is new automation on an existing stage transition — it fires on the next entry, not retroactively. Existing NDAs have a null `Buyer__c` and their `Counterparty_Name__c` is **untouched** (change-keyed guard). |

### 5.2 Risk register

1. 🔴 **The `NDA__c` FLS gap (§0 C-1) is the single largest schedule risk.** Two of four workstreams
   are blocked behind a permission-set edit that must be surgical, diffed against `HEAD`, and
   verified as a real persona. Underestimating it will surface as "the card is a red banner" on the
   day of the demo.
2. 🔴 **`NdaTrigger` is a new trigger on a dual-module object.** Every acquisition NDA insert and
   update in the org begins running new code. The change-keyed fast path is what makes it safe, and
   it must be tested with the zero-query falsifier, not asserted.
3. 🔴 **`required=true` vs `deleteConstraint` (§0 C-2).** If the platform constraint is confirmed, the
   VR route is mandatory; if it is not, the VR route is still recommended and the reasoning is in
   §2 A1. Either way, **do not silently switch `Broker__c` to `Restrict`** — a repo header forbids it.
4. **`TestDataFactory` blast radius.** A1's factory change touches every BOV test class in the repo.
   Budget for a full `RunLocalTests` cycle and expect a first-run failure list.
5. **Relationship-name collisions.** Three new `Contact`/`Disposition__c`/`BOV_Submission__c`
   relationship names are proposed. A `relationshipName` is disruptive to change after deploy —
   settle them before the first deploy, while it costs nothing.
6. **Duplicate field labels.** Check every proposed label against its object's existing labels.
   Salesforce permits duplicates; humans cannot use them.
7. **255-character caps.** `ValidationRule.description`, `CustomField.inlineHelpText`,
   `RecordType.description` and **LWC `.js-meta.xml` `<description>`** are all capped at 255. Only a
   deploy catches the LWC one. Put long rationale in an XML comment **inside the root element**.
8. **Concurrent sessions share this working tree.** Diff hub files (the two permission sets and
   `Disposition_Record_Page`) against `HEAD` before deploying — this repo has a measured incident of
   a shared FlexiPage and three permission sets silently becoming the union of two features.
9. **`mcp__salesforce__deploy_metadata` is intermittently classifier-blocked.** The fix is explicit
   allow-rules in `.claude/settings.local.json`, not a retry.

### 5.3 OPEN ITEMS — flagged, not invented

These need a decision before the implementing agent writes the file. None is a blocker for starting
tranches 2.1–2.3.

| # | Item | Default if unanswered |
|---|---|---|
| O-1 | New history object API name — `BOV_Broker_Change__c` proposed | Use the proposal; pick once and use it everywhere |
| O-2 | `Reason__c` picklist values (the `Broker_Assignment__c` set is leasing vocabulary and does not transfer) | `Performance Issue`, `Better BOV Received`, `Broker Withdrew`, `Company Decision`, `Other` — **confirm before shipping** |
| O-3 | `Outgoing_BOV_Submission__c` / `Incoming_BOV_Submission__c` naming (two lookups, one target) | Use the proposal |
| O-4 | `Entry_DateTime__c` + `Logged_By__c` vs the free `CreatedDate` / `CreatedById` | Follow the four-instance repo pattern (explicit fields) |
| O-5 | Buyer lookup filter — recommendation is **unfiltered, no `Is_Buyer__c`** (§3 D6.1) | Unfiltered |
| O-6 | Whether `Execution_Date_Not_In_Future` firing on **acquisition** PSAs is intended | Assume yes; state it in the rule comment |
| O-7 | Whether `Buyer_Required_On_Offer` ships in 2.2 against `Buyer_Name__c` or defers to 2.5 | Ship in 2.2, amend in 2.5 |
| O-8 | Deal Summary card placement — sidebar-first (recommended) vs main-after-`contractReviewsList` | Sidebar-first |

### 5.4 EXPLICITLY OUT OF SCOPE

- **Any change to the acquisition NDA sequence, `NDA_Path_Acquisition`, or
  `Opportunity.NDA_Signed_Before_Deal_Progression`.** A3 touches acquisition only by *not* touching
  it.
- **Connecting `NDA_Signed_Status_Sync`'s default branch to a blanket `Status != 'Signed' ⇒ false`
  rule.** Forbidden. The branch goes to a `Declined`-only decision and nothing else.
- **Converting any child→`Disposition__c` lookup to Master-Detail** to obtain roll-up summaries. Not
  requested, and it would change OWD, sharing, ownership and delete behaviour across the module.
- **Changing `deleteConstraint` on any broker `Contact` lookup** (§0 C-2).
- **Widening `DPEG_Admin_Access`** (§2 A5).
- **`NDA__c.allowDelete`** — stays FALSE per decision D20. Declined NDAs persist; the timeline renders
  them.
- **`NDA__c.Counter_Signed_Date__c`** — remains a record of fact, not a gate input. "Executed" is
  `Status__c = 'Signed'` (user-confirmed).
- **Retiring `Broker_Firm__c` / `Contact_Name__c` / `Buyer_Name__c` / `Counterparty_Name__c`.** All
  become derived; **none is retired.** Five live consumers read the BOV pair.
- **Field History Tracking on any object in this tranche.** `enableHistory` stays `false` on
  `BOV_Submission__c`; Workstream B's history object is the answer, not `__History`.
- **Reactivating `LOI_Signed_Notify`.**
- **Backfilling `Buyer__c` on existing NDAs or offers.** Not requested. The timeline degrades to
  `Counterparty_Name__c` / `Buyer_Name__c` for legacy rows.
- **Any Task, Chatter post, email alert or notification** on broker replacement, NDA decline, or
  offer selection. The user asked for a history row and a timeline, not notifications.
- **A `dispositionMain` or `dispositionSidebar` refactor.** The new cards get their own ungated
  slots; the existing components are untouched.
