# Stage-by-Stage Conformance — Decisions Taken (2026-08-09)

Source document: `docs/DPEG-Stage-by-Stage.docx`
Extracted text: scratchpad `stage-by-stage.md` (351 lines; Part 1 Acquisition = 1–191, Part 2 Disposition = 192–351)

These four were answered by the user **before** any build work, at the start of the audit. They
constrain what the gap-closure work may do, so read them before acting on either audit file.

## D1 — "Retail deals only" means Commercial. Wording only.

The document gates Construction Review on "Retail deals only". The org's Opportunity record types
are **Land** and **Commercial**.

**Decision: "Retail" is the business's word for Commercial. NO metadata change.** Construction
Review stays gated on the Commercial record type. Do not rename the record type, its business
process, its path, or any downstream label; do not add a third record type.

## D2 — DocuSign is planned, not yet licensed.

**Decision: build the NDA status model (Not Sent → Sent → Signed, or Declined) as a manually-driven
status now, and leave a clean seam for DocuSign later.** No integration work in this pass. Statuses
must be shaped so an envelope-status callback could drive them later without reshaping the picklist
or the gates that read it. The executed file is attached by hand for now.

## D3 — Acquisition "Call for Offers": EXTEND the existing gate, do not replace it.

The document (spec-acquisition.md lines ~51–56) asks for call-for-offers emails to be matched
against live deals, with the offer due date stamped on the matched deal. The pipeline today
**hard-gates** these emails and creates nothing — rule U2 (`ExtractAddressQueueable.isCallForOffersGated`),
added 2026-08-03 on the user's explicit instruction ("if email is related to call for offers then we
must not store it as a lead, simple"), documented in `ARCHITECTURE.md` § INTAKE RULES V2.

**Decision: both hold. The rule that a call-for-offers email never creates a Lead is UNCHANGED.**
On top of it, add: match the extracted property address against live deals; on a match, stamp the
offer due date on that deal and hold the broker, the best-and-final requirement and the email
alongside it; **on no match, create nothing** — which is what the document itself specifies, and is
exactly the current behaviour.

⚠ This means the 2026-08-03 decision is NOT reversed. Anyone implementing this must not remove the
gate or re-enable Lead creation on this branch.

## D4 — ⚠ SUPERSEDED BY D9/D10 (2026-08-09). Read those first; kept for the record.

The document names "four principals, first to respond decides" for **Underwriting Approval**, **LOI
Approval**, **Sale decision**, **Broker selection**, and **Closing**.

**Decision: the same four people for all five.** Model as ONE public group referenced by all five
approval processes, each configured first-to-respond (not unanimous). No separate acquisition and
disposition approver sets; no additional IR/Finance step on Closing.

⚠ Note against existing state, **corrected after the audit**: both deployed approvals are already
`FirstResponse` with `allowedSubmitters = owner` — those halves are correct and must NOT be touched
(changing `whenMultipleApprovers` on a live process breaks pending work-item loops). What is wrong is
only the **approver count: two named users** (`nikhil.dhanani@…`, `aftab.ali.dpeg.usman@…`), not four.
`groups/Principals.group-meta.xml` exists but is not referenced as the approver.

🔴 **BLOCKED: the other two principals' names are not known**, and approver identity is org state.
Group membership is not deployable metadata, so this carries a post-deploy gate either way.

---

## D5 — Disposition on-market vs off-market: **Record Type on `Disposition__c`**.

`On_Market` / `Off_Market`, each with its own Path and its own **record-type-specific `Disposition_Stage__c`
value set**, so an off-market disposition never surfaces BOV Outreach / Active Listing / Call for
Offers, and an on-market one never surfaces the off-market NDA / Disposition Offer steps. Mirrors the
existing `Opportunity` Land/Commercial precedent.

Consequences to plan for: record types must be assigned in every profile and permission set granting
`Disposition__c`; existing rows need a default; `Disposition_Path` (currently `__MASTER__`) becomes two
paths; `lwc/dispositionMain` + `lwc/dispositionSidebar` branch on stage today and will need to branch on
record type too. **This unblocks the off-market PSA-Executed → +Finance notification, which is
inexpressible without it.**

⚠ Mid-flight switching (a direct sale that fails and goes to a broker) was NOT selected as an explicit
requirement. Record-type change on a live record is possible but awkward; if it turns out to be a real
business case, it needs its own action rather than a hand-edit.

## D6 — Disposition LOI: **record type on `LOI__c`, and migrate the negotiation off the offer record.**

Add a `Disposition__c` lookup and an `Acquisition_LOI` / `Disposition_LOI` record-type pair to `LOI__c`,
with a record-type-specific `Stage__c` value set carrying the five disposition values (Received → Under
Review → Countered by DPEG → Counter Received from Buyer → Executed). This inherits `Counter_Offer__c`,
`CounterOfferService`, `lwc/loiCounterOffer` and `Counter_Offer_Notify` — which is what makes "every
round is recorded" achievable at all.

🔴 **Then retire the negotiation from `Disposition_Offer__c`**: `Offer_Status__c`'s four LOI-shaped values
(`Received`, `Under Review`, `Countered by DPEG`, `Counter Received from Buyer`) plus
`DPEG_Counter_Price__c`, `DPEG_Counter_Date__c`, `Buyer_Counter_Price__c`, `Final_Agreed_Price__c`. The
offer becomes capture + comparison only, per the document.

⚠ **This half is a DATA MIGRATION, not a schema change**, and is the highest-risk item in the programme.
The standing picklist-removal rule applies in full (grep the repo **and** query the org before removing
any value — `Received` / `Under Review` / `Accepted` are common strings likely active on other fields).
Live rows carrying the retiring values must be resolved before retire, and reports/list views checked.

⚠ Risks to the **live, deployed acquisition LOI** that must be held: `LOI__c.Stage__c` is
`<restricted>true</restricted>`, so new values become globally available and are then restricted per
record type — the acquisition Path and value set must be verified unchanged. `RecordStageAdvanceService`
holds a single flat `Map<SObjectType, StageConfig>` with one linear `NEXT_STAGE` per object; it must
become **record-type-aware**, which its current shape does not express. Acquisition-directional fields
(`Submitted_Date__c`, `Approved_By__c`, the `Submit_for_Approval` quick action) must be layout-excluded
from the disposition record type, **not deleted**.

## D7 — NDA: **record types on `NDA__c`, one for Acquisition and one for Disposition.**

The object is already dual-parented (Opportunity / Disposition) and the two sides need **different state
sets**, which a single shared restricted picklist cannot express:

- **Disposition RT:** Not Sent → Sent → Signed, plus **Declined** (all four required by Part 2; `Declined`
  does not exist today at all)
- **Acquisition RT:** the Part 1 states

Record types give per-type value sets and per-type Paths, so neither side sees the other's states. Also
carries the off-market additions from Part 2: a `Party_Role__c` (Buyer / Introducing Broker) and a
counter-signature, plus the all-signed release gate.

🔴 **STILL OPEN — the acquisition record type's middle value.** Part 1 says `Pending → Received → Signed`;
the org has `Pending → Sent → Signed`, with `Date_Sent__c` pairing to `Sent`, and
`RecordStageAdvanceService.NDA_NEXT_STAGE` encoding `Pending ⇒ Sent ⇒ Signed`. Choosing `Received` means
migrating existing acquisition NDAs currently sitting on `Sent`. Not yet decided — do not build the
acquisition RT's value set until it is.

## D8 — Call for Offers matching: **claim-pipeline deals only.**

Match the extracted address through the existing `Property_Registry__c` route, which already resolves a
converted Lead to its `ConvertedOpportunityId` via `PropertyMatchingService.resolveLiveRecord`. **Do NOT
build an address-based Opportunity query** — there is none in the application today, and adding one to
`ExtractAddressQueueable` (the module's most incident-prone class, with pinned governor budgets) is not
worth the coverage.

**Accepted blind spot, stated rather than hidden:** a manually-created deal has no registry row and
therefore cannot be matched. Those emails fall through to "no deal matched", where — per D3 and per the
document — nothing is created.

---

## D9 — NOTIFICATIONS ARE OUT OF SCOPE FOR THIS PROGRAMME. (2026-08-09, supersedes part of D4)

Every notification the document specifies is **deferred**, on both sides:

- **Disposition: all 14** (audit §2.15). Nothing to build; the module stays notification-free.
- **Acquisition: the four corrections** — new-Lead → Acquisition queue, moving the Acquisitions-team
  notification from Converted to Qualified, retargeting the two "opinion shared" flows from
  `Recommendation__c` to `Stage__c = 'Share Opinion'`, and the missing PSA `Initial Draft` notification.
- **The Call-for-Offers T-2-day notification** (document line 56). ⚠ Note this leaves the Call for
  Offers feature (D3/D8) delivering only the match-and-stamp half. The stamped due date will sit on the
  deal with nothing announcing it — the `Offers_Due_Soon` list view is the only surface.
- **The Active Listing month-1 traction alert.** The broker-change MECHANISM is not a notification and
  stays in scope; only its alert is deferred.

**Consequence for planning:** the acquisition tranche shrinks to almost nothing, because most acquisition
gaps were notification gaps. The remaining acquisition work is the NDA record type (D7), the review-branch
NDA gate, the Dead/Pass quick action, `Property_Asset__c` on Closed Won, and Call for Offers.

**Consequence for the audits:** every row in either report whose only defect was a missing notification is
now DEFERRED, not a gap. Do not re-raise them.

⚠ **This also makes two previously-blocking questions moot for now:** what "Disposition team", "Legal",
"IR" and "Finance" are as Salesforce constructs (public groups vs queues vs roles), and the recipient
population for the new-Lead notification (the **Acquisition queue** and the **`Acquisitions_Team` public
group** are different objects in this org — that distinction must be re-established before any deferred
notification is built).

## D10 — Approvals use the TWO EXISTING approvers, not four. (2026-08-09, supersedes D4)

The document's "four principals" is **not** being chased. Nikhil (`nikhil.dhanani@…`) and Aftab
(`aftab.ali.dpeg.usman@…`) are the approver panel for testing, on every approval.

- **The two deployed acquisition approvals (`Underwriting_Approval`, `LOI_Approval`) are therefore
  CORRECT AS DEPLOYED and must NOT be touched.** They already carry `FirstResponse` and
  `allowedSubmitters = owner`. Audit gap #2 on the acquisition side is closed with zero work.
  ⚠ Do not "helpfully" repoint them at `groups/Principals.group-meta.xml` — changing
  `whenMultipleApprovers` or the approver set on a live process breaks pending work-item loops.
- **The three NEW disposition approvals still get built** (Sale decision at Readiness, Broker selection
  at BOV Outreach, Final sale terms + closing wire at Closing) — same two named approvers,
  `FirstResponse`, mirroring the acquisition processes.
- 🔴 An approval-triggered flow runs as **the APPROVER**, who is read-only on these objects. Any stamp
  flow must declare `<runInMode>SystemModeWithoutSharing</runInMode>` and catch `Exception`, not
  `DmlException` — the `ApprovalAuditService` incident is the precedent and it rolled back a whole
  approval.

---

## D11 — Gate 1 answers, Disposition Foundations (Tranche 2). 2026-08-09.

Against `agent-output/design-requirements-disposition-foundations.md` §0:

- **Q1 = (a)** — `DispositionService.findOrCreate` stamps `On_Market` **explicitly** at creation. Both
  paths start identically at Readiness, so the type is not knowable from the sell meter; an off-market
  deal is switched by changing the record type early, while still at Readiness. Rejected: leaving
  `RecordTypeId` null and inheriting the running user's **profile default** — `profiles/**` is
  `.forceignore`d, so that behaviour is org state this repo can neither set nor verify.
- **Q2 = confirm-then-create** for the yellow-band Override. `LightningConfirm.open()` naming the
  days-to-peak, then the identical creation call with a distinct success toast. **No new field, no new
  approval** — the document asks for neither, so neither is invented.
- **Q3 = the MOST RECENT `Wire__c`** defines "the wire check is complete". This matches
  `WireSelector.selectMostRecentByDispositionId` / `WireController.getWire`, which is what the UI badge
  already shows. Any other reading makes the badge the user sees and the gate that blocks them disagree.
- **Q4 = a validation rule on the Closing → Completed transition**, NOT the approval's `entryCriteria`.
  An unmet `entryCriteria` surfaces as *"no applicable approval process was found"* — a misleading
  platform error the user cannot act on. The wire flag instead appears in the Closing approval's
  `approvalPageFields` so the approver sees the state when deciding.
- **Q5 = no placeholder** for the new `LOI` / `PSA` stages. The stage is valid and path-rendered; the
  record page falls back to the Details section and the Path step's guidance names where negotiation
  currently lives until Tranche 3.
- **Q6 = YES — migrate ALL existing `Disposition__c` rows to `On_Market`.** ✅ **User-approved
  2026-08-09.** Every disposition built to date is broker-listed by construction (BOV Outreach and
  Active Listing are the only stages with UI). 🔴 **This is a mass update on LIVE rows and is NOT
  deployable metadata.** It must run in the SAME window as the record-type deploy — adding record types
  leaves existing rows on the **Master** type, which shows all ten stage values and matches **neither**
  new Path. Post-deploy gate.
- **Q7 = YES — grant `NDA__c` read to the disposition personas.** ✅ **User-approved 2026-08-09.**
  `NDA__c` is currently granted **only** by `DPEG_Acquisitions` / `DPEG_Acquisition_Edit` /
  `DPEG_Acquisition_View`; `DPEG_Disposition_Edit` / `DPEG_Disposition_View` grant it **not at all**.
  Add `NDA__c` read + `Status__c` read to both disposition sets. ⚠ **AND the fail-soft catch is still
  required — both, not either:** without it a `WITH USER_MODE` NDA read throws `QueryException`, which
  `BovController.getOutreachSummary`'s catch converts into the generic read-failure message, **blanking
  the entire BOV Outreach tile** for every disposition user. That is worse than today's hard-coded lie.
  ⚠ A `PermissionSet` deploy **REPLACES** its whole grant list — any org-side-only grant absent from the
  file is destroyed (this bit Broker Protection twice). Reconcile against the org before deploying.

### Premise corrections found during design — recorded so they are not re-introduced

1. **The LWCs do NOT need record-type branching**, contrary to D5's consequence list. The two
   record-type value sets are **disjoint for every path-specific stage**, so `Disposition_Stage__c` alone
   identifies the path. No `getObjectInfo`, no new `@wire`, no new Apex. Revisit only if a **shared**
   stage must later render differently per path.
2. **No second flexipage and no record-type page assignment.** `applications/Disposition.app-meta.xml`
   assigns the page by `pageOrSobjectType` with no `<recordType>`, so one page serves both types — the
   same shape Opportunity uses for Land/Commercial. Only the page's *visibility rules* change.
3. 🔴 **None of the three approvals would have been submittable.**
   `layouts/Disposition__c-Disposition Layout` has **no `Submit` button**, and the record page's
   highlights panel is `enableActionsConfiguration = false`, so it inherits that list verbatim. Three
   approval processes would have deployed green, tested green and done nothing. Fixed **on the layout** —
   ⚠ explicitly NOT by enabling Dynamic Actions, which has silently emptied three pages' action bars in
   this repo.

⚠ **The Active Listing Path guidance text is copied forward VERBATIM and must not be edited** — it says
"6-week marketing clock… Week 4 YELLOW… Week 6 Hard Stop" while the document says ~2 months with a
month-1 check. Editing it would silently pre-empt OPEN #2 below.

---

## D12 — Gate 2 (code review) outcome. 2026-08-09.

Verdict was **CHANGES REQUIRED**: 1 critical, 5 warnings, 4 suggestions, 3 judgement calls. Report:
`agent-output/code-review-disposition-foundations.md`.

- **User decision: FIX THE CRITICAL AND ALL FIVE WARNINGS, then re-review.**
- **W3 — `NDA__c` `viewAllRecords=true` is ACCEPTED as an explicit, informed widening.** ✅ The Q7
  grant landed broader than designed: disposition-only personas can read **every acquisition NDA**,
  not just disposition ones. Accepted because `NDA__c` is **Private OWD** and one object serves both
  modules, so a plain read would make the BOV pill **lie by omission** — reporting "No NDA" for an NDA
  that exists but is invisible to the running user. ⚠ Revisit when Tranche 3 adds NDA record types:
  the correct long-term shape is view-all **scoped to disposition NDAs**, which is not expressible
  until those record types exist. Record this in the permission-set files so it is not "tidied" away.

### 🔴 C1 — the critical finding, and why it is worth remembering beyond this fix

**`Wire_Verification_Rollup` will throw `ENTITY_IS_LOCKED` during the Closing approval and roll the
wire save back with it.** Both artifacts ship in this tranche and both key on the SAME stage: the
approval's `entryCriteria` is `Disposition_Stage__c = 'Closing'`, and `Closing` is the only stage at
which a `Wire__c` is worked at all.

1. Owner submits at `Closing` → `recordEditability = AdminOnly` **locks the Disposition**
2. IR saves the Wire → the after-save flow updates `$Record.Disposition__r` — a locked record
3. `ENTITY_IS_LOCKED`; the update element has **no fault connector, deliberately**, so it is unhandled
4. The wire save is rolled back and the user is told to "refresh the page" — advice that cannot work

🔴 **`<runInMode>SystemModeWithoutSharing</runInMode>` does NOT rescue this, and that is measured in
this repo, not general knowledge** — see `ARCHITECTURE.md`'s `OpportunityReviewService` row:
*"`SYSTEM_MODE` lifts CRUD/FLS but does NOT lift an approval lock, so the inline back-stamp still threw
`ENTITY_IS_LOCKED`."* Same trap, one module later.

⚠ **Gate 1's own Q4 answer invited this.** Putting the wire flag on the approval page "so the approver
sees the wire state when deciding" is precisely the sequence that fails. Two components each correct in
isolation, wrong together — which is the class of defect no per-file review and no green test suite
catches.

**Agreed fix:** a no-change Decision before the parent update (the flow currently writes the parent on
every wire save, changed or not), plus a **fault connector** — a stale flag is strictly better than a
lost wire, and while the record is locked the stage cannot change anyway, so the validation rule is
unreachable in that window. Plus wire-before-submit wording on the Closing Path step and a UAT gate.

### 🟡 W1 — the green test result may not survive the deploy

**The 66/66 Apex pass predates the declarative deploy.** Three existing tests insert **251 `Wire__c`
under ONE Disposition** (`DispositionControllerTest:223`, `WireControllerTest:202`,
`WireSelectorTest:105`). With the flow live, each drives a consolidated `Update Records` carrying the
same parent Id up to 200× — the classic `duplicate id in list` shape. **No precedent exists in this
repo:** `Underwriting_Opp_Sync` uses the identical shape but nothing creates 251 children under one
parent. ⚠ Treat "tests were green" as evidence about the code, NOT about the code-plus-metadata.

*(By contrast the VR's `ISNEW()` blast radius was swept twice and is genuinely clean — zero tests or
seed scripts insert at `Completed`.)*

### Remaining warnings

- **W2** `DPEG_Admin_Access` grants no FLS on `Wire_Verification_Completed__c`, and no post-deploy gate
  covers admin FLS. 🔴 **An approval page silently OMITS fields the approver cannot read** — so the Q4
  design fails invisibly rather than loudly. The named approvers are covered via
  `DPEG_Principal_PSG` → `DPEG_Disposition_View`; an admin approver is not.
- **W4** The "the badge and the gate can never disagree" invariant (D11/Q3) is asserted in four places
  and has two real divergences: Flow `Get Records` supports only ONE sort field (`CreatedDate`) against
  `WireSelector`'s `CreatedDate DESC, Id DESC`; and `!= null` vs `NOT(ISBLANK())`.
- **W5** `scripts/seed-disposition*.apex` (4 sites) still create dispositions with no `RecordTypeId`.
  §5.5 swept `TestDataFactory` but not the scripts, so seeded rows land on **Master** — the exact state
  gate A2 exists to eliminate.

---

## D13 — Gate 2 fix round: outcome and two residuals. 2026-08-09.

All six code-review findings are closed. Verified on disk and by check-only validation, not by agent
self-report (two agents in this tranche reported completion on work that could not deploy).

| Finding | Outcome |
| --- | --- |
| 🔴 **C1** approval-lock rollback | **Fixed** — `Flag_Changed` no-change Decision + `faultConnector` → `Record_Flag_Update_Fault` on `Update_Disposition_Flag`, plus wire-before-submit wording on the `Closing` step of BOTH Paths. |
| 🟡 **W1** 251 Wires vs the live flow | **BOUNDED, NOT DISPROVEN — this row was corrected 2026-08-09 after review pass 2.** ⚠ The original wording ("FALSE ALARM — disproven by running it") was **wrong and must not be quoted.** The 24-test / 0-failure run carried the **POST-FIX** flow, and `TestDataFactory.createWires` (`:1902–1917`) seeds `Verbal_Verification_Completed__c = false` and never sets `Verified_DateTime__c` — so `isComplete` is false, the parent flag is already false, and `Flag_Changed` takes the **SKIP** path. **None of the three 251-wire tests ever reaches `Update_Disposition_Flag`.** The run proved the tests still pass; it did **not** exercise the consolidated parent update. The risk is now bounded three ways — the skip path, the fault connector (a `DUPLICATE_VALUE` costs a stale flag, not the wire), and the tests passing — but it was never observed failing OR succeeding. 🔴 **The tests were still correctly left untouched**: reducing the counts would delete the bulk-safety proof. |
| 🟡 **W2** admin FLS on the approval page | **Fixed** — read on `Wire_Verification_Completed__c` in `DPEG_Admin_Access` + a post-deploy gate. |
| 🟡 **W3** NDA `viewAllRecords` | **Accepted** (see D12); rationale now in an in-root XML comment in both disposition permission sets. |
| 🟡 **W4** badge/gate divergence | **Fixed both halves** — `NdaSelector` gained `Id DESC`; the Flow's single-sort-field limit is documented as a known residual rather than left latent. |
| 🟡 **W5** seeds create Master-type rows | **Fixed** — 8 creation sites across 3 scripts stamp `On_Market`. ⚠ The brief said 4 files; `seed-disposition-offers.apex` creates **no** `Disposition__c` at all and was correctly left alone. |
| 🟢 **S1/S2** | **Fixed** — stale `bandForPeak` reference repointed to `SellMeterService`; the record-type allow-list now uses constant-first `.equals()` so a **case typo throws** instead of silently degrading. |

**Strongest evidence to date:** check-only validate `0Afiw000000HBqTCAW` — **21/21 components, 119 tests,
0 failures, 0 coverage warnings**, with `TestDataFactory` reporting `changed=true` (so the local copy
ran, not the org's).

### 🔴 RESIDUAL 1 — `isAvailable()` returned FALSE for an assigned System Administrator

During validation, `getRecordTypeInfosByDeveloperName().get('On_Market')` returned a **real Id**
(`012iw0000009s1CAAQ`) while `info.isAvailable()` was **`false`** — for a System Administrator who *is*
assigned `DPEG_Admin_Access`, and it stayed false when both `DPEG_Admin_Access` and
`DPEG_Disposition_Edit` were added to the validation package.

**Whether this is an artifact of validating brand-new record types in the same transaction, or a real
post-deploy gap, is UNDETERMINED** — distinguishing them requires an actual deploy, which was not done.
Both `TestDataFactory` and the seed scripts guard their stamp on `isAvailable()`, so under this
condition **every stamp silently no-ops**.

🔴 **Consequence for gate A2, and it changes the gate:** *a seed script that runs without error is NOT
evidence the record type landed.* A2 must **read a record back** —
`SELECT RecordTypeId, Disposition_Stage__c FROM Disposition__c` — rather than confirm the seed
completed. This is the same failure shape as `DispositionService.cls:120` being uncovered, and it is
why post-deploy gate B4 exists.

⚠ The `isAvailable()` guard was deliberately KEPT so the seeds match `TestDataFactory`. The alternative
— stamp unconditionally and fail loudly — is a live option if the read-back shows the guard misfiring
in a real deploy.

### RESIDUAL 2 — the S2 guarantee has no permanent falsifier

**There is no `TestDataFactoryTest` class in this repo.** The case-typo guarantee now holds, but nothing
would go red if a future edit broke it again — structurally the same weakness the review raised.
Deliberately not fixed here (outside the two-item scope). Worth a small pinning test.

✅ **CLOSED 2026-08-09** — `TestDataFactoryTest` now exists with three methods. Two pass (case-typo
throws and names the value; null name throws). 🔴 **The third,
`createDisposition_defaultOverload_stampsOnMarketRecordType`, is RED and is MEANT TO BE**: `On_Market`
resolved to a real Id (`012iw0000009s62AAA`) yet the inserted row carried `RecordTypeId = null`,
reproducing residual 1 through a permanent test. **This is expected in the CURRENT state** — the record
types have never been deployed and gate A1 has never run, so a record type assigned to no profile is
genuinely unavailable to everyone. It should turn green the moment A1 is done correctly and stay red if
A1 is skipped. **Do not guard, skip or delete it to obtain a green suite.**

---

## D14 — Tranche 2 HELD undeployed; Tranche 3 starts. NDA goes to four states. 2026-08-09.

- **Tranche 2 is NOT deployed and NOT merged.** It stays on `feature/stage-by-stage-alignment`,
  built / reviewed / validated (119 components, 0 errors). **Tranche 2 and Tranche 3 deploy TOGETHER in
  one window.** Rationale: Tranche 2 created `LOI` and `PSA` as `Disposition_Stage__c` values with
  **nothing behind them** (Gate 1 Q5 deliberately built no placeholder), so deploying alone would ship
  two stages a user can select and then find empty. Tranche 3 supplies the records.
- ⚠ **Every Tranche 2 post-deploy gate still applies, unchanged** — deferred, not cancelled. In
  particular: the one-deployment grouping (picklist + record types + field + translations), **flow
  BEFORE validation rule**, A1 profile record-type assignment, A3 per-profile default, A2 row migration
  **with read-back**, and clearing the schedulable-job block before deploying `classes`.

### D14.1 — Acquisition NDA: FOUR states, `Pending → Sent → Received → Signed`.

Supersedes the open question at line 118 and OPEN #1. The document's three-state
`Pending → Received → Signed` is read as describing the broker-facing milestones, not the full internal
process.

**Chosen because it is additive and needs NO data migration:** `Sent` is retained (so every existing
acquisition NDA keeps a valid value), `Date_Sent__c` keeps the field it pairs with, and `Received` is
added for the NDA coming back from the broker — the distinction the document itself draws at Part 1
lines 38 and 41 ("NDA not yet received from broker" / "The NDA has been received").

Touches: `NDA__c.Status__c` (add ONE value), `NDA_Path`, and `RecordStageAdvanceService.NDA_NEXT_STAGE`,
which encodes `Pending ⇒ Sent ⇒ Signed` today and must become `Pending ⇒ Sent ⇒ Received ⇒ Signed`
**on the acquisition record type only**.

🔴 **The DISPOSITION record type takes a DIFFERENT set** — `Not Sent → Sent → Signed` plus **`Declined`**
(Part 2 lines 28–41), which does not exist on the field at all today. This is precisely why D7 chose
record types: one shared restricted picklist cannot carry both sets. Consequently
`RecordStageAdvanceService` must become **record-type-aware** — the same change D6 requires for `LOI__c`.
**Do both in one change, not two.**

---

## D15 — Gate 1 answers, Tranche 3 (LOI / PSA / NDA). 2026-08-09.

Design: `agent-output/design-requirements-disposition-loi-psa-nda.md`.

**Build is SPLIT three ways** (design's recommendation, adopted): **3A** = NDA record types + the shared
record-type-aware `RecordStageAdvanceService` · **3B** = Disposition LOI + the offer migration
(inseparable — the migration cannot start before the LOI exists) · **3C** = Disposition PSA.
All still deploy in ONE window with Tranche 2, per D14.

- **Q1 = a NEW `User.Disposition_Driver__c` flag**, mirroring the proven two-factor `Deal_Driver__c`
  mechanism (FLS-granted by a permission set + the field value both required). Rejected: reusing
  `Deal_Driver__c` (merges two authorization boundaries — a sale driver could then drive acquisitions)
  and a permission-set membership check (the exact one-factor widening the Opportunity gate
  deliberately rejected; see `OpportunityActionPermissionService`). It is also the only thing a
  flexipage visibility rule can bind to, so the buttons can be hidden declaratively AND blocked
  server-side.
- **Q2 = KEEP `Received`; retire the other three.** `Under Review`, `Countered by DPEG` and
  `Counter Received from Buyer` retire from `Disposition_Offer__c.Offer_Status__c`; **`Received`
  stays** as the offer's genuine arrival state and its default. This is a reading of D6, not a
  departure from it — D6's intent was to remove NEGOTIATION from the offer, and an arrival state is
  not negotiation. Retiring it would leave the offer with no initial value.
- **Q3 = AUTO-CREATE on stage entry.** ⚠ **Chosen by the user with the risk stated.** See below.
- **Q4 = the all-signed gate blocks EVERY forward stage from `NDA` onward**, not just the next hop —
  matching "nothing is released until this is done" (Part 2 line 305). Requires
  `$RecordType.DeveloperName` in the rule so it applies to **off-market only**. The next-hop-only
  alternative was rejected because a user could skip `Disposition Offer` and reach `LOI` unblocked.

### 🔴 Q3 — auto-create was chosen over the recommendation. Build it the SAFE way.

The related-list option was recommended because auto-create needs a new `Disposition__c` trigger firing
on a record that **three approvals lock** (`Sale_Decision` at Readiness, `Broker_Selection` at BOV
Outreach, `Closing` at Closing) — the exact trap that produced Tranche 2's critical finding. The user
chose auto-create anyway; that is their call and it is not re-litigated here.

**It is achievable safely, and this repo already contains the pattern — reuse it, do not reinvent it.**
`OpportunityReviewService`'s **LOI block** solves the identical problem: the LOI stage is entered by the
approval process's own field update, so the code runs as the APPROVER while the deal is LOCKED by its
own approval. Its solution is two separate mechanisms because there are two separate obstacles:

1. **`AccessLevel.SYSTEM_MODE` DML** for the child insert — lifts CRUD/FLS for a read-only approver.
2. **The parent back-stamp is DEFERRED to a queueable** (`LoiPrimaryStampQueueable`) — because
   🔴 **`SYSTEM_MODE` lifts CRUD/FLS but does NOT lift an approval lock**, so an inline parent write
   still throws `ENTITY_IS_LOCKED`.

The child insert itself is safe **only because the child is not the record under approval**. Any write
back to `Disposition__c` (a `Primary_LOI__c`-style stamp) must be deferred the same way, and any rollup
flow must carry the Tranche 2 C1 shape — a **no-change Decision plus a fault connector** — from day one
rather than being retrofitted after an incident.

⚠ Note the asymmetry `OpportunityReviewService` records: **five of its six child-creation blocks
deliberately do NEITHER** of these things, because they are entered by a deal driver who has Edit. Do
not harmonize the blocks in either direction.

### Findings from design recon that change the brief

1. ✅ **The phantom `Transaction__c` risk NO LONGER EXISTS.** `ContractExecutionService` stopped
   creating Transactions on 2026-08-05 (moved to `openTransactionsOnAboutToClose`, keyed on Opportunity
   stage), and `handleExecution` already drops any Contract Review with a null `Opportunity__c`. **The
   PSA branch is ADDITIVE, not defensive.** `Contract_Review_Stage_Sync` and `Opportunity.LOI_Approval`
   also check out clean and need no change. My brief was working from stale information.
2. 🔴 **`RecordStageAdvanceService`: the ALLOW-LIST must become record-type-aware, not just
   `NEXT_STAGE`.** Record-type picklist restrictions are **not enforced by Apex DML**, so an
   object-level list would let `advanceTo(acquisitionNdaId, 'Declined')` succeed. Also `configFor()`
   runs BEFORE `load()`, so this is a **call-order change**, not a map swap. And the class already
   branches (`LOI_EXPLICIT_TARGETS` + `advanceTo`) across six objects — it is not the flat shape the
   brief assumed.
3. **Three vocabulary inversions the brief did not name**, all needing per-record-type handling:
   `Counter_Offer__c.Direction__c`, `LOI__c.Ball_In_Court__c`, `Contract_Review__c.Ball_In_Court__c` —
   `Ball_In_Court__c = 'Seller'` would mean **DPEG** on a sale.
4. 🔴 **A LIVE notification leak:** `flows/Counter_Offer_Notify` has **no entry criteria**, so the first
   disposition counter notifies `Acquisitions_Team`. **Gating it is scope containment, not a D9
   violation** — D9 defers BUILDING notifications, it does not license leaking an existing one into a
   new module.
5. ⚠ Per-record-type **layout** assignment is profile-only, so "layout-exclude the acquisition-directional
   fields" is **half deployable file, half post-deploy gate**.

---

## D16 — Disposition NDA access, auto-create scope, and a regression this programme introduces. 2026-08-09.

### D16.1 — `NDA__c` for disposition personas: **EDIT, not create.**

`DPEG_Disposition_Edit` currently holds `NDA__c` as `allowCreate=false, allowEdit=false, allowRead=true`
— the grant arrived in Tranche 2 purely so the BOV pill could **read** a status (D12/W3), and was never
meant to carry a workflow. 3A puts a workflow on it, so the persona that owns off-market NDAs cannot
work them.

**Decision: grant `allowEdit=true`. Do NOT grant `allowCreate`.** Creation is the auto-create trigger's
job (D16.2), running in system mode. Users move `Not Sent → Sent → Signed → Declined` and set
`Party_Role__c` / the counter-signature. ⚠ `allowDelete` stays **false** — an NDA is an audit artefact.

⚠ The `viewAllRecords=true` grant and its D12/W3 rationale comment stay **untouched**.

### D16.2 — Auto-create IS built, inside Tranche 3. (confirms D15/Q3)

The design **recommended manual related lists**; the user chose auto-create at D15/Q3 and, when told the
full cost, **reaffirmed it here**. It is therefore in scope and is not re-litigated again.

What it actually requires — none of which existed and none of which was in 3A's dispatch:
- a **new `DispositionTrigger` + handler** (there is **no `Disposition__c` trigger in this repo at all**)
- a service extension creating `NDA__c` / `LOI__c` / `Contract_Review__c` on `Disposition_Stage__c` entry
- **`Primary_*` lookups on `Disposition__c`** (none exist — the acquisition side stamps `Primary_NDA__c`,
  `Primary_LOI__c`, `Primary_Contract__c`; the disposition side has no equivalent)
- idempotency (never a second child of one type) and bulk tests

🔴 **It fires on a record THREE approvals lock** (`Sale_Decision` at Readiness, `Broker_Selection` at BOV
Outreach, `Closing` at Closing). **Use `OpportunityReviewService`'s LOI-block pattern — do not invent
one:** `AccessLevel.SYSTEM_MODE` DML for the child insert (the child is not the record under approval,
so it is not locked), and **defer any parent `Primary_*` stamp to a queueable**, because `SYSTEM_MODE`
lifts CRUD/FLS but **NOT an approval lock**. An inline parent write throws `ENTITY_IS_LOCKED`.

⚠ **Open sub-question, not yet answered:** off-market may need **TWO** NDAs (buyer, plus the introducing
broker if there was one) — Part 2 line 305. Auto-create of a *variable* number is ill-defined. Resolve
before building: create the buyer NDA only and let the broker NDA be added another way, or create both
and let the unused one be cancelled. This is why `Party_Role__c` exists.

### 🔴 D16.3 — A REGRESSION THIS PROGRAMME INTRODUCES INTO THE LIVE ACQUISITION FLOW. Must fix.

`OpportunityReviewService` auto-creates all three objects that are gaining record types and **stamps a
record type on NONE of them**: `:100` inserts `Contract_Review__c`, `:155` inserts `LOI__c`, `:230`
inserts `NDA__c`.

**Left alone, every auto-created ACQUISITION child lands on the Master record type — one deal at a
time, forever, silently.** This is not a disposition problem; it is damage to a working flow, caused by
adding record types to objects whose creator predates them.

Fix in whichever tranche adds each object's record types: **3A → `NDA__c`**, **3B → `LOI__c`**,
**3C → `Contract_Review__c`**. 🔴 **The LOI block is the sharp one** — it runs as the **approver** in
`AccessLevel.SYSTEM_MODE` with a deferred `LoiPrimaryStampQueueable` back-stamp, so the record-type
stamp must respect that shape rather than being inlined.

⚠ **Verification must READ `RecordTypeId` BACK** (design T-C1): a creation that succeeded is not
evidence the type landed — the same lesson as gate A2 and `TestDataFactoryTest`. Run the LOI case **as
the approver**, because that is the principal it actually executes as.

---

## D17 — `NDA__c` grants are SCOPED to disposition NDAs. 2026-08-09. Supersedes D12/W3 and D16.1.

🔴 **Why this was reopened.** D16.1 granted `allowEdit=true` on a set that already carried
`viewAllRecords=true` from D12/W3. **The two COMPOUND**: the disposition persona could edit **every NDA
in the org, acquisition NDAs included**. D12/W3 was argued and accepted on **visibility** grounds only,
so this reached past that acceptance — and the option was put to the user as "the narrowest grant that
makes the workflow operable", which it was not. That framing error was mine, not the agent's; the agent
applied the decision and then flagged that the permission set's own comment ("no disposition persona can
alter an acquisition NDA") had been made false, and retracted it.

**Not hypothetical:** an acquisition NDA edited to `Signed` satisfies
`Opportunity.NDA_Signed_Before_Deal_Progression` via `NDA_Signed_Status_Sync` — **a disposition user
could unblock an acquisition deal's NDA gate.**

**Decision: scope both grants.** Drop `viewAllRecords`, keep plain read + edit, and add a
**criteria-based sharing rule on `RecordType = Disposition_NDA`**.

⚠ **This is only expressible NOW** — the revisit trigger D12/W3 named for itself ("when Tranche 3 adds
NDA record types") has fired. It could not have been done in Tranche 2, which is why the org-wide grant
was accepted then rather than being an oversight.

⚠ Deploy **sharing rules ONE AT A TIME** — a batch deploy rolls all of them back.

## D18 — recurring agent failure modes worth knowing, 2026-08-09

Recorded because each has now cost a round-trip more than once:

1. 🔴 **The 255-char `<description>` cap on RecordType has been breached THREE times** — both Tranche 2
   record types, then `Disposition_NDA` at 266. The pattern is always the same and always caught only by
   a deploy. **Rationale belongs in an XML comment INSIDE the root element; the description is a short
   summary.** A comment ABOVE the root breaks `sf` at source conversion.
2. **The solution-architect agent reliably exhausts its budget on reconnaissance and stops immediately
   before writing files** (Tranche 2: 4 of 11 items; the flow fix; 3A: 53 tool calls, **zero** files).
   Its output is good once produced. **Hand it an explicit file list, not a brief to reason from.**
3. **Agent completion reports are not evidence.** Two agents reported "complete" on metadata that could
   not deploy at all. Every claim in this programme was verified against disk or a check-only deploy.

---

## D19 — NDA auto-create shape, and the 3A sharing-rule deploy gate. 2026-08-09.

### D19.1 — Auto-create makes the BUYER NDA only.

On entry to the `NDA` stage the trigger creates **one** `NDA__c` with `Party_Role__c = 'Buyer'`. A
**broker NDA is added from the related list** when a broker actually introduced the buyer — which the
system cannot know in advance. Rejected: creating both and cancelling the unused one, because every
direct-approach deal would carry a spurious Introducing Broker NDA that **the all-signed gate would
block on** until someone marked it `Declined`.

⚠ Consequence for the all-signed gate: it counts NDAs that EXIST. A broker NDA that was never created
cannot block, which is correct — but it also means the gate **cannot detect a broker NDA someone forgot
to add.** That is a process control, not a system one. Do not try to infer it.

### 🔴 D19.2 — 3A is a TWO-PHASE DEPLOY. The sharing rules cannot go in the first phase.

Check-only validation of 3A: **255 components, 2 errors — both `SharingCriteriaRule`**, failing
`Picklist value does not exist` on `RecordTypeId equals NDA__c.Disposition_NDA`. Everything else
(253 components) validates clean.

The value is the documented fully-qualified `Object.RecordTypeDeveloperName` form, and the record type
does not yet exist in the org — so **the cause is most likely ordering, but it is UNDETERMINED**: a
wrong value format produces the same message. Disambiguating needs a real deploy, and is not worth
further effort because the resolution is identical either way:

1. Deploy record types (and the rest of 3A) **first**
2. Then the sharing rules — 🔴 **ONE AT A TIME**, a batch rolls all of them back in this org
3. If a rule still fails once the record type has landed, **the criteria value is the only thing to
   change** — nothing else in the file is in doubt

⚠ Three further gates on these rules: **group membership is not deployable** (if
`DPEG_Acquisitions_Team` or `Principals` is empty the rules grant nothing, and "no NDAs visible" looks
identical to "no NDAs exist"); **criteria sharing recalculation is ASYNCHRONOUS**, so a persona checking
immediately after deploy may see nothing yet and that is not a failed rule; and verification must be
done **as each persona, not as an admin**.

⚠ **Two `<description>` cap breaches were found in 3A, not one** — `Disposition_NDA` at 266 **and**
`All_NDAs_Signed_Before_Progression` at 259. Both now under. Found only because lengths were **measured
mechanically** rather than eyeballed; see D18.1.

---

## D20 — 3A code review outcome + 3B access. 2026-08-09.

Verdict **CHANGES REQUIRED**: 2 critical, 3 warnings. Report: `agent-output/code-review-3a-nda.md`.
**All six focus areas came back correct** — the approval-lock pattern, the allow-list move, the
two-factor gate ordering, the D16.3 stamp read back from the DB, a real 251-record trigger test with an
exact query-budget assertion, and complete LWC error handling. **The server side is finished; the
user-facing half was never started.** Both criticals live there and neither is Apex.

### 🔴 C1 — `NDA_Record_Page` is byte-identical to its pre-3A state

`flexipages/NDA_Record_Page.flexipage-meta.xml` — `actionNames` holds one entry (`Advance_Stage`) and
`enableActionsConfiguration=true`, so that list **is** the whole action bar. Its rule requires
`{!$User.Deal_Driver__c} EQUAL true`, and a disposition driver holds `Disposition_Deal_Driver`, which
grants **no FLS on `Deal_Driver__c`** — so the criterion **can never be true** and a disposition NDA
shows **no buttons at all**. Three consequences: the `Not Sent → Sent → Signed` walk is unreachable by
its own persona; `Mark Declined` appears nowhere, making the quick action, `lwc/ndaMarkDeclined`,
`NDA_DISPOSITION_EXPLICIT_TARGETS` and the `Declined` Path step **dead**; and `NE 'Signed'` does not
exclude `Declined`, so Advance Stage still shows on a declined NDA and then refuses.
**`NDA__c.Is_Decline_Allowed__c` (design §4.4) was never built** — the discriminator is required because
`Sent` is **shared** by both record types, so `Status__c` alone cannot drive visibility.

### 🔴 C2 — TWO OF MY OWN DECISIONS CONTRADICT EACH OTHER. Resolved here.

**D16.1** set `allowCreate=false` on the premise *"creation is the trigger's job"* — true when written.
**D19.1** then made the trigger create the **buyer NDA only**. Together: the introducing-broker NDA that
D19.1 says is *"added from the related list"* **cannot be added**, and a `Declined` NDA counts toward
`NDA_Count__c` **forever** with no exit, blocking every forward stage.

**Decision: grant `allowCreate=true` on `DPEG_Disposition_Edit`, and make the all-signed gate IGNORE
`Declined` NDAs.**

🔴 **`allowDelete` stays FALSE — deliberately, against the review's own suggested remedy.** Deleting
would destroy the record that a buyer or broker refused to sign. `NDA__c` is an audit artefact
everywhere else in this application, and a declined NDA **is** the evidence of a buyer who walked away —
which is what Part 2 line 231 describes ("Nothing is released and that buyer goes no further"). The
correct fix is arithmetic, not deletion: **count only NDAs that are not `Declined`.**

⚠ Also required by D20/C2: an **NDA related list on `Disposition_Record_Page`**. There is none today, and
no `NDA__c` actionOverride in `Disposition.app` — so "added from the related list" has no related list.

### D20.1 — `LOI__c` access for disposition personas: read + edit, SCOPED by sharing rule.

`DPEG_Disposition_Edit` / `_View` grant **no `LOI__c` at all** today, so the disposition LOI would exist
with its own record type, Path and stages and be **invisible to its own persona**. Same shape as the NDA
gap, caught **before** the build this time.

Grant object read + edit (edit on the Edit set only), **no `viewAllRecords`**, plus a
**criteria-based sharing rule on `RecordType = Disposition_LOI`** — the D17 shape. 🔴 Unscoped access
would be the NDA compounding error again, and worse: an **acquisition LOI carries the approval flags
that gate PSA entry** (`Underwriting_Approved_Before_LOI`, `Approved_LOI_Before_PSA`).

### Warnings carried

- **W1** — `DispositionNdaStampQueueable` copies the LOI justification **verbatim, and it does not
  transfer.** `finalApprovalRecordLock=false` releases on *final approval*; on the LOI path the
  triggering transaction **is** the one releasing the lock, but here the stage is entered by a **user
  edit**, so a pending approval outlives the queueable. Reachable: an admin edits a locked disposition
  (`AdminOnly` permits it) → the update throws `ENTITY_IS_LOCKED`, `allOrNone=true`, **`Primary_NDA__c`
  never stamped and nothing retries.** The deferral is still right; the *reason* and the residual must be
  written down rather than inherited.
- **W2 — RECORDED SO 3B/3C DO NOT "RESTORE" IT.** `OpportunityReviewService` uses a **guarded**
  `isAvailable()` record-type stamp, reversing design Q5's "stamp unconditionally". **The reversal is
  correct:** `ensureNda` runs on **every Opportunity insert including `Database.convertLead`**, so an
  unguarded stamp throws `INVALID_CROSS_REFERENCE_KEY` before gate A1 and would break lead conversion
  org-wide. 3B (`LOI__c`) and 3C (`Contract_Review__c`) must **re-argue this, not inherit either
  answer** — the LOI insert runs as the approver in `SYSTEM_MODE` and is a different case again.
- **W3** — `NDA_Signed_Rollup` is bulk-tested many-parents only; the one-parent `DUPLICATE_VALUE` shape
  is untested. Bounded by the fault connector, which is present from day one.

---

## D21 — `Counter_Offer__c` visibility: view-all READ, no edit. 2026-08-09.

**The D17/D20.1 record-type sharing shape CANNOT be built on this object** — established, not assumed:
it has **no record types**; **no stored field identifies the deal side** (`Direction__c` cannot, because
per the token contract `Seller` is the counterparty on **both** sides, so a rule keyed on it would leak
acquisition rows while *looking* scoped); and **Salesforce does not support formula fields in
criteria-based sharing rule criteria**, ruling out a cross-object discriminator.

Residual without a fix: an unshared row is **filtered out** of a `USER_MODE` query, not refused — so the
counter card renders an **empty history, not an error**. The Edit persona sees rows they created; **a
Principal creates nothing, so they see zero** — the identical silent gap `LOI_Disposition_Principals_R`
exists to prevent.

**User decision: grant `viewAllRecords` on `Counter_Offer__c`.**

⚠ **Scoped refinement applied: `allowRead` + `viewAllRecords` = true; `allowEdit` = FALSE on BOTH
disposition sets.** The user chose view-all, not view-all-plus-edit, and the two are separable here:
`CounterOfferService` writes in **system mode**, so the feature works without object edit. Granting both
would let a disposition persona **edit acquisition counter offers** — the exact compounding error
narrowed on `NDA__c` at D17 the same day. `allowCreate` / `allowDelete` stay false.

🔴 **Accepted, informed exposure, stated rather than buried:** disposition personas can now **read every
acquisition counter offer** — DPEG's negotiating position on live purchases. Rejected alternative: a
stored discriminator checkbox on `Counter_Offer__c` set by `CounterOfferService` (which already computes
`isSaleSide` for the Buyer/Seller label) plus a criteria rule. That remains the narrow long-term shape if
the exposure is later judged too wide.

## D22 — 🔴 D20/C1 IS REPEATING ON `LOI__c`. Not yet fixed.

`LOI_Record_Page`'s `Advance_Stage` has a **single** entry gated on `{!$User.Deal_Driver__c}`, which a
disposition driver has **no FLS for** — so it can never be true for them. **No linear walk for
`Received → Under Review` or `Counter Received from Buyer → Executed`.** Exactly the C1 shape one object
later.

⚠ **Deliberately NOT guessed at.** Its second criterion is `{!Record.Is_Advance_Allowed__c}`, which
`DPEG_Disposition_Edit`'s own comment documents as **acquisition-shaped** and explicitly flags for 3B to
re-check. Copying the entry likely yields a button that never shows; dropping the criterion changes what
Advance Stage means. **Resolve the formula first, then add the entry.**

### Also outstanding from 3B's declarative close-out

- **Both new quick actions fail deploy until their LWC bundles exist** — `loiMarkCounteredByDpeg` and
  `loiMarkCounterReceived`. Deploy together, never one alone.
- **They need Apex allow-list entries**: `'Countered by DPEG'` and `'Counter Received from Buyer'` on the
  LOI **disposition** explicit-target set — 🔴 record-type-scoped, since an object-level list would permit
  writing them onto an acquisition LOI.
- **`Acquisition_LOI` deliberately EXCLUDES `Buyer`** — on a purchase DPEG *is* the buyer, so the value
  would name DPEG, the exact inversion it exists to fix. ⚠ Record-type picklist restriction is **UI-only
  and not enforced by Apex DML**, so the record-type-aware allow-list in `RecordStageAdvanceService` is
  the only thing that actually refuses it.
- **The two loop quick actions carry NO record-type criterion, deliberately** — the two `Stage__c` value
  sets are fully disjoint, so a stage-keyed visibility rule is self-limiting to its own record type.
- ⚠ **Permission-set org reconciliation was NOT performed** for this round (retrieve returned neither
  disposition set, most likely because 3A/3B are undeployed — an inference, not a measurement). Both files
  record this in-file.

---

## D23–D25 — 3C access, PSA versions, and a correction. 2026-08-09.

- **D23 — `Contract_Review__c`: read + edit, SCOPED** by two criteria sharing rules on
  `RecordType = Disposition_PSA` (`Contract_Review_Disp_Team_RW`, `Contract_Review_Disp_Principals_R`).
  The narrow D17 shape **works here** because the object now has record types **and** a stored
  `Disposition__c` discriminator — the two things `Counter_Offer__c` lacked at D21.
  ⚠ `Stage__c` granted **read-only even on the Edit set** — `Contract_Review_Stage_Sync` recomputes it
  and a direct write commits then is silently discarded. ⚠ `Opportunity__c` read but **not editable**:
  its blank is load-bearing — `ContractExecutionService.handleExecution` drops any Contract Review with
  a null `Opportunity__c`, so an editable grant would let a disposition persona mint a phantom
  acquisition `Transaction__c`.
- **D24 — `PSA_Version__c`: `viewAllRecords` = true, `allowEdit` = FALSE on both sets.** The lookup
  parent means it does **not** inherit D23's scoping. Edit stayed false because `PsaVersionService`
  writes with **plain DML (system mode)** — verified in Apex **and** by checking `lwc/psaVersionLog` for
  an LDS write path (there is none). 🔴 Named cost: this persona can log new versions but **cannot
  correct a mis-keyed summary, date or link on an existing one.** Rejected: master-detail (forces
  **cascade delete**, destroying version history with its parent) and a stored discriminator (field +
  Apex + backfill).
- 🔴 **D25 — THE VERSION-COUNTER CORRUPTION IS NOT FULLY FIXED. Accepted, with the mechanism corrected.**

### D25 in full — I stated the mechanism wrong and the agent caught it

`PsaVersionSelector.countByContractReviewId` feeds `Latest_Version__c = priorCount + 1`. A user who
cannot see prior versions counts **zero** and **rewinds a live negotiation's version counter to 1** —
rows are FILTERED, not refused, so it fails silently and writes a wrong number.

**I prescribed `WITH USER_MODE → WITH SYSTEM_MODE` as the fix. That was WRONG and must not be repeated:**
rows are filtered by **SHARING**, and sharing is governed by the class's **sharing keyword in BOTH
modes**. On a `with sharing` selector the mode change lifts CRUD/FLS and leaves the under-count
**exactly as it was**. Measured: `PSA_Version__c` is `sharingModel Private` and its sharing-rules file is
an empty `<SharingRules/>`, so a non-owner still counts 0 of 3.

The change was still made (correct on its own terms — a derived value is an automation-path read) and
the residual is **pinned by `countReadsAcrossAccessNarrowing_isTheModeFalsifier`** rather than left
latent.

**User decision: LEAVE IT.** D24's `viewAllRecords` bypasses sharing, so the **disposition** personas —
the population this tranche serves — count correctly. The residual is **acquisition** personas who do
not own prior versions on a shared PSA: a **pre-existing** defect this programme neither introduced nor
fixes. The proper fix, if ever wanted, is a narrow `private without sharing` inner class holding only
the count (the `LeadSelector.GuestReads` pattern) — **not** relaxing the whole selector.

### 3C build notes worth keeping

- **The THIRD guarded-vs-unconditional decision (`OpportunityReviewService` PSA block) = GUARDED**, on
  reasoning specific to it: `PSA` is a **sequenced gate with exactly one route in**, so blocking it
  parks every acquisition in the org at LOI; and the insert **shares one all-or-none transaction with
  four sibling children** and runs first, so a throw takes their `Primary_*` stamps and the LOI
  queueable with it. Neither 3A's (blast radius) nor 3B's (runs as the approver) argument applies.
  **Three blocks, three different justifications, same answer.**
- **`RecordStageAdvanceService` DID need a `Contract_Review__c` change — on the GATE axis, not the
  sequence.** Both record types expose the same four `Negotiation_Status__c` values, but exactly one
  permission set grants `Deal_Driver__c` FLS and exactly one grants `Disposition_Driver__c`, and they
  are **disjoint** — so the single-sequence `DEAL_DRIVER` config would have refused **every disposition
  PSA for the only persona meant to work it**: a dead feature passing every walk test.
  **"Sharing a SEQUENCE is not sharing a GATE."**
- `ContractExecutionService`'s disposition arm: synchronous write + no-change filter +
  `allOrNone = false` + `SYSTEM_MODE`. **Deferral was rejected on evidence** — `OpportunityReviewService`
  defers because *the triggering transaction itself releases the lock*; a Contract Review save releases
  no disposition approval, so a pending approval **outlives** any queueable. That is exactly the mistake
  review W1 caught in `DispositionNdaStampQueueable`, which had copied the justification verbatim.

---

## D26 — Gate 1, Tranche 4 (Call for Offers). 2026-08-10.

Design: `agent-output/design-requirements-call-for-offers.md`. **Split 4A (declarative) / 4B (Apex)** —
the boundary is where failures change character: **4A fails loudly at deploy; 4B fails SILENTLY** (a
`with sharing` read against a Private OWD returns zero rows, indistinguishable from "no deal matched",
i.e. from shipped behaviour). Deploying together lets a dead 4B hide behind a healthy 4A.

- **Q1 = OPPORTUNITY ONLY.** ⚠ **Chosen with the consequence stated.** Registry rows are created when a
  Lead is minted, and `resolveLiveRecord` returns an Opportunity Id **only for a CONVERTED winner** — so
  the stamp fires for a **minority** of matches and is inert for the rest. `Lead.Offer_Due_Date__c` and
  `Lead.Listing_Broker_*__c` already exist and are deliberately **not** used.
- **Q2 = KEEP ATTACHMENTS SUPPRESSED.** The branch must **explicitly release the carrier**, as today.
  🔴 This preserves the `ARCHITECTURE.md` invariant that the U2 gate is why *"the pipeline's
  highest-volume junk costs zero publications"* — the ContentPublication quota behind the 2026-08-06
  outage that destroyed every attachment-bearing email. **A non-null record Id would otherwise turn the
  file job on for this traffic**, because `finish()`'s last statement is `enqueueAttachmentPersist`.
  Anyone stamping a target must keep the release explicit.
- **Q3 = BEST-AND-FINAL IS NOT BUILT.** User: *"leave it."* No field, no phrase test, no prompt key.
  ⚠ The client document's *"the best-and-final requirement … held alongside it"* (spec line 53) is
  therefore **deliberately unimplemented** — record it as a known, decided gap, not an oversight.

### 🔴 D26.1 — What this feature actually delivers, stated plainly

With D9 (no notification) + Q1 (Opportunity only) + Q3 (no best-and-final), Tranche 4 ships **the
match-and-stamp half, for converted winners only**:

| Document asks for | Ships? |
| --- | --- |
| Address matched against live deals | ✅ via `Property_Registry__c` (D8) — claim-pipeline only |
| Offer due date stamped | ⚠ **converted winners only** |
| Broker held alongside | ✅ `Listing_Broker_Name__c` / `_Email__c` already exist on Opportunity |
| Best-and-final requirement | ❌ **not built (Q3)** |
| The email held alongside | ✅ Task attaches to the matched Opportunity instead of nothing |
| Nothing created on no match | ✅ already today's behaviour |
| Notify Acquisition queue T-2 days | ❌ **deferred (D9)** |

**Measured surface check:** `Offer_Due_Date__c` **IS** on `Opportunity-Opportunity Layout`, so a stamped
date is visible when someone opens the deal. It is **not** on `Opportunity_Record_Page` directly and
**no Opportunity list view filters on it**. ⚠ The design's claim that `Offers_Due_Soon` is the surface is
**wrong for this decision** — that list view is on **Lead** and **excludes converted rows**, so under
Q1 it can never show a stamped record.

**Therefore 4A adds an Opportunity list view filtered on `Offer_Due_Date__c`** — not requested, but
declarative, near-zero cost, and the only thing that makes the stamp findable without opening each deal.
Without it the feature is write-only in practice.

### Three findings that would otherwise have shipped as defects

1. 🔴 **`Opportunity` OWD is UNVERIFIED** — the repo says `ReadWrite`, but the RBAC build set 28 objects
   to Private and standard-object OWD is **UI-only, not in the Metadata API**. Needs the narrow
   `private without sharing` inner class (`LeadSelector.GuestReads` shape), with **mode and sharing
   argued SEPARATELY** — the exact D25 mistake.
2. 🔴 **The deal may be LOCKED by its own approval.** `Underwriting_Approval` / `LOI_Approval` are
   `recordEditability = AdminOnly`, and **`SYSTEM_MODE` does not lift an approval lock**. The stamp must
   be `allOrNone = false` **and** the branch wrapped so `finish()` is **always** reached — otherwise the
   Task is never logged, the Message-ID goes unrecorded, and a **redelivery re-runs the whole pipeline**.
3. 🔴 **The multi-property label trap.** `buildOutcomeSummary` prefixes `'Multi-Property (N):'` when
   N > 1, which does **not** start with `'Not Routed'` — so a two-property call-for-offers email
   **vanishes from the `Gated_Call_For_Offers` list view**, the only surface for the misclassification
   watch. No compile error, no failing test. Must ship in the same deploy.

**Governor impact:** all four pinned budgets (43 exact, 7 exact, 120, 30/20) are **untouched** — the
branch returns before `routeProperties`. New delta ≤ **+32 SOQL / +2 DML** worst case against async caps
of 200/150. The gated path has no pinned budget today; recommended ceilings 60/8. ⚠ If
`findMatchingRegistry`'s fuzzy 90-day per-property scan comes under pressure, the fix is a
transaction-scoped memo, **not** raising the budget — and that touches the claim path, so it is a
separate design.

---

## OPEN — remaining questions, each blocking its own item

1. ~~**Acquisition NDA middle state**~~ — ✅ **RESOLVED by D14.1: four states, additive.**
2. **Marketing clock** (blocks the Active Listing broker-change work): the document says ~2 months with a
   month-1 check; `Disposition_Path` guidance says a 6-week clock, week-4 yellow, week-6 hard stop.
3. **Does closing a deal auto-create a `Property_Asset__c`?** (document line 182, "the property becomes
   asset"). Today it is a `Deal_Status__c` stamp only. This is the root object of four PM modules, so
   automating it has reach.
4. **Is Dead/Pass meant to be terminal?** The document says "the only way out"; the
   `No_Backward_Stage_Movement` comment documents the Dead/Pass round-trip as the sanctioned recovery
   route, chosen over a bypass permission the user rejected.
