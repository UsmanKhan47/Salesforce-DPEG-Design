# Disposition Stage-Flow Conformance Audit

**Spec audited:** `spec-disposition.md` (Part 2 — Disposition; lines 192–351 of the source document)
**Implementation audited:** `F:\Acquisition-Design-Salesforce` @ `main` (abcb4b3), metadata read directly
**Date:** 2026-08-09
**Scope:** READ-ONLY. No metadata created, modified or deployed.

---

## 1. Verdict summary

| # | Spec section (spec line) | Verdict |
|---|---|---|
| 0 | **On-market vs off-market path split exists at all** (2, 107) | **NOT ALIGNED** — no record type, no picklist, no branch. One undifferentiated 5-value stage picklist. |
| 1 | Sell meter thresholds 30 / 31–90 / >90 (4, 109) | **ALIGNED** — exact match in `SellMeterController.bandForPeak` |
| 2 | Green → Initiate creates the Disposition (4) | **PARTIAL** — button works; gate is client-side only, no server-side check |
| 3 | Yellow shown as "Override" (4) | **PARTIAL** — label renders, **click is a silent no-op** |
| 4 | Red button cannot be clicked (4) | **ALIGNED** |
| 5 | Approval: Sale decision, any 1 of 4 principals (6, 111) | **NOT ALIGNED** — no approval process on `Disposition__c` at all |
| 6 | BOV Outreach: pack to 5–6 brokers vs deadline (9) | **PARTIAL** — date/counter fields exist, hand-keyed; no outreach mechanism, no 5–6 enforcement |
| 7 | Approval: Broker selection, any 1 of 4 principals (11) | **NOT ALIGNED** — does not exist |
| 8 | BOV Submission field set (14) | **ALIGNED** — all 7 named fields present |
| 9 | BOV statuses Selected / Backup (15, 18) | **ALIGNED** — exact strings; note default is `Backup` |
| 10 | Active Listing ≈ 2 months (22) | **PARTIAL** — `Days_On_Market__c` formula + `Listing_Status__c` bands exist; nothing computes or fires |
| 11 | No traction in month 1 → decide whether to change broker (22) | **NOT ALIGNED** — no timer, no task, no alert; `listingAlerts` LWC is an empty stub |
| 12 | Buyer NDA states Not Sent → Sent → Signed / Declined (28–41) | **PARTIAL** — `Pending`/`Sent`/`Signed`; **`Declined` missing**, `Not Sent` named `Pending` |
| 13 | NDA sent for signature via DocuSign (27) | **NOT ALIGNED** — a `DocuSign` picklist *value* exists; **no DocuSign integration anywhere in the repo** |
| 14 | NDA signed → notify Disposition team + principals (38) | **NOT ALIGNED** — no notification |
| 15 | NDA declined → notify Disposition team (41) | **NOT ALIGNED** — state does not exist, so neither does the notification |
| 16 | Off-market: multiple NDAs (buyer + introducing broker), gate on all-signed (114) | **PARTIAL** — many-NDAs-per-Disposition is structurally supported; **no all-signed gate**, no counter-sign concept, no party-role field |
| 17 | Call for Offers date held on the Broker Listing (43) | **ALIGNED** — `Broker_Listing__c.Call_For_Offers_Date__c` |
| 18 | Call for Offers as a stage (42) | **NOT ALIGNED** — no such stage value |
| 19 | Call for Offers notification (46) | **OPEN QUESTION** — spec says "To be filled" |
| 20 | Disposition Offer field set incl. earnest money + financing (48, 119) | **ALIGNED** — all six named fields present |
| 21 | **No negotiation on the offer record** (48, 119) | **NOT ALIGNED — structural conflict.** The offer record carries the spec's five LOI stages plus DPEG/buyer counter prices |
| 22 | Disposition LOI record with its own 5 stages (52–74, 124) | **NOT ALIGNED** — `LOI__c` has no `Disposition__c` relationship and none of the five values |
| 23 | LOI counter history, every round recorded (66, 72, 128) | **NOT ALIGNED for disposition** — `Counter_Offer__c` exists but is a child of the acquisition `LOI__c` only |
| 24 | LOI notifications (57, 65, 71, 75, 127) | **NOT ALIGNED** — none exist |
| 25 | Disposition PSA record, our legal drafts first (77–90, 130) | **NOT ALIGNED** — `Contract_Review__c` is Opportunity-only; `PSA_Version__c.Direction__c` is acquisition-directional |
| 26 | PSA stages Initial Draft → Revised → Ready for Execution → Executed (79–89) | **PARTIAL** — the exact four values exist on `Contract_Review__c.Negotiation_Status__c`, wrong parent |
| 27 | PSA stage derived by before-save flow (132) | **ALIGNED in mechanism** — `Contract_Review_Stage_Sync` does exactly this; carries the "writes to `Stage__c` are silently discarded" trap |
| 28 | PSA notifications, incl. off-market Executed → +Finance (81–90, 144) | **NOT ALIGNED** — none exist for disposition |
| 29 | Closing stage exists (91) | **ALIGNED** |
| 30 | Approval: Final sale terms + closing wire, 1 of 4 principals (94, 148) | **NOT ALIGNED** — does not exist |
| 31 | Wire check must be complete before funds move (92, 146) | **NOT ALIGNED** — no validation rule, no Apex gate, no approval entry criterion |
| 32 | Wire: the six confirmation fields (97, 151) | **ALIGNED** — all six exist, all optional |
| 33 | Completed terminal stage (101, 155) | **ALIGNED** |
| 34 | Departments: Disposition / Legal / IR / Principals / Finance | **NEEDS ORG VERIFICATION** — no Legal/IR/Finance/Principal permission set or queue in the repo |
| 35 | Notifications overall (all lines) | **NOT ALIGNED** — **zero** flows or notification types reference `Disposition__c` |

**Headline:** stages 1–3 of the on-market path (Readiness, BOV Outreach, Active Listing) and the Closing/Wire data model are largely built and materially correct. Everything from **Call for Offers onward — Call for Offers, LOI, PSA — has no disposition-side representation at all**, the off-market path does not exist as a concept, and the module has **no approvals and no notifications whatsoever**.

---

## 2. Line-by-line findings

### 2.0 Foundational — on-market vs off-market (spec 2, 107)

> "## Disposition — selling on the market" / "## Disposition — selling off the market"

**There is no path split.** Evidence:

- `force-app/main/default/objects/Disposition__c/` contains only `Disposition__c.object-meta.xml` and `fields/` — **no `recordTypes/` directory**. A repo-wide `find -name "*.recordType-meta.xml"` returns exactly two files, both `Opportunity/recordTypes/` (`Commercial`, `Land`).
- `Disposition__c` has 19 custom fields; none is a channel/method/type discriminator (`Sell_Decision_Trigger__c` is a *why-we-are-selling* picklist — Sell Meter Green / Principal Decision / Fund Maturity / Market Opportunity — not on-market vs off-market).
- `pathAssistants/Disposition_Path.pathAssistant-meta.xml:35` — `<recordTypeName>__MASTER__</recordTypeName>`. One path for all dispositions.

**Consequence:** the two paths cannot be distinguished, so neither their differing stage sequences nor their differing notification targets (spec 144: off-market PSA Executed also notifies Finance) can be expressed today.

### 2.1 Disposition Readiness (spec 3–7, 108–112)

> spec:4 — "green when the property's peak sell date is thirty days away or less; yellow between thirty-one and ninety days, shown as Override; red beyond that, and the button cannot be clicked."

**Thresholds: exact match.** `classes/SellMeterController.cls:90-101`:

```apex
private static String bandForPeak(Date peak) {
    if (peak == null) { return 'RED'; }
    Integer days = Date.today().daysBetween(peak);
    if (days <= 30) { return 'GREEN'; }
    else if (days <= 90) { return 'YELLOW'; }
    return 'RED';
}
```

≤30 GREEN, 31–90 YELLOW, >90 RED — and a **null peak date is RED**, which the spec does not address but is the safe reading. **ALIGNED.**

**Button labels: match.** `lwc/sellMeterList/sellMeterList.js:107-110`:

```js
actionLabel: meter === 'GREEN' ? 'Initiate' : (meter === 'YELLOW' ? 'Override' : 'Hold'),
actionName:  meter === 'GREEN' ? 'initiate' : (meter === 'YELLOW' ? 'override' : 'hold'),
actionDisabled: meter === 'RED'
```

Red is disabled — **ALIGNED** with spec:4.

**🔴 "Override" is a dead button.** `lwc/sellMeterList/sellMeterList.js:160-164`:

```js
handleRowAction(event) {
    const action = event.detail && event.detail.action;
    if (!action || action.name !== 'initiate') { return; }
```

A yellow row's `override` action is discarded silently — no toast, no navigation, no record. The user sees an enabled button that does nothing. **PARTIAL / defect.** The spec implies Override is a real (presumably justified/logged) path.

**The gate is client-side only.** `classes/DispositionService.cls:31-39` — `findOrCreate(Id assetId)` reads the most recent Disposition or inserts a new one. It never reads `Peak_Sell_Date__c` and never checks a band. `DispositionController.findOrCreate` (`classes/DispositionController.cls:44-53`) is a thin `@AuraEnabled(cacheable=false)` pass-through with no assertion. Any user with create access on `Disposition__c` can call it directly for a red asset. Compare the Opportunity deal actions, which assert server-side via `OpportunityActionPermissionService`. **PARTIAL.**

> spec:6 — "Approval: Sale decision. Any one of the four principals, first to respond decides"

**Does not exist.** `force-app/main/default/approvalProcesses/` contains exactly two files, both on Opportunity:
`Opportunity.LOI_Approval.approvalProcess-meta.xml`, `Opportunity.Underwriting_Approval.approvalProcess-meta.xml`.
Both are `<whenMultipleApprovers>FirstResponse</whenMultipleApprovers>` (LOI_Approval:27, Underwriting_Approval:29) with **two** named approvers (`nikhil.dhanani@…`, `aftab.ali.dpeg.usman@…`), not four. So the *pattern* the spec wants is already proven in this org, but there is **no approval on `Disposition__c` at any stage**, and the principal roster is 2 rather than 4. **NOT ALIGNED.**

### 2.2 BOV Outreach (spec 8–12)

> spec:9 — "An information pack goes to five or six brokers against a submission deadline"

Supported as **data capture only**:
- `Disposition__c/fields/Package_Sent__c.field-meta.xml` — Date
- `Disposition__c/fields/Submission_Deadline__c.field-meta.xml` — Date
- `Disposition__c/fields/Brokers_Contacted__c.field-meta.xml` — Number (hand-keyed, **not** a rollup)
- `Disposition__c/fields/Responses_Received__c.field-meta.xml` — Number (hand-keyed, **not** a rollup of `BOV_Submission__c`)
- `pathAssistants/Disposition_Path.pathAssistant-meta.xml:12-17` surfaces `Package_Sent__c` + `Submission_Deadline__c` on the BOV Outreach step with guidance text "Send OM packages to 5-6 brokers."

There is no outreach send, no template, no deadline reminder, and no rule enforcing 5–6. The counts can drift from the actual `BOV_Submission__c` children because they are entered by hand. **PARTIAL.**

`classes/BovController.cls:78` — `s.matrixGenerated = s.responsesReceived >= 3;` drives the comparison-matrix reveal (`lwc/dispositionMain/dispositionMain.html:8-10`). This is a repo-invented "3+ responses" rule the spec does not mention; harmless but undocumented in the spec.

> spec:11 — "Approval: Broker selection. Any one of the four principals, first to respond decides"

**NOT ALIGNED.** No approval process exists. Broker selection is a free-hand picklist flip on `BOV_Submission__c.Submission_Status__c` plus a Text write to `Disposition__c.Selected_Broker__c` — with nothing recording who decided or when. Note also `Disposition__c/fields/Selected_Broker__c.field-meta.xml` is **Text(255), not a lookup**, so the chosen broker is a string, not a record.

### 2.3 BOV Submission (spec 13–20)

> spec:14 — "Holds the firm and contact, the value and cap rate, days to market, proposed commission and a score."

Field-by-field against `objects/BOV_Submission__c/fields/`:

| Spec term | Field | Type | Verdict |
|---|---|---|---|
| firm | `Broker_Firm__c` | Text(255) | ✓ |
| contact | `Contact_Name__c` | Text(255) | ✓ |
| value | `BOV_Amount__c` | Currency | ✓ |
| cap rate | `Cap_Rate__c` | Percent | ✓ |
| days to market | `Days_To_Market__c` | Number(4,0) | ✓ |
| proposed commission | `Commission_Rate__c` | Percent(5,1) | ✓ |
| score | `BOV_Score__c` | Number(4,0) | ✓ |

**All seven present — ALIGNED.** Extras beyond spec (not defects): `Hist_Success_Rate__c`, `Broker_Display__c` (formula), `Property_Name__c` (formula), `Selected_Broker__c` (formula), `Disposition__c` (lookup).

> spec:15 / spec:18 — statuses **Selected** / **Backup**

`objects/BOV_Submission__c/fields/Submission_Status__c.field-meta.xml` — restricted picklist, exactly `Backup` (default=true) and `Selected`. **ALIGNED, exact string match.** One nuance worth confirming with the client: the default is `Backup`, so an unreviewed reply already reads as "not chosen".

Spec:16's "one jockey / single point of contact" intent is **not enforced** — nothing prevents two `BOV_Submission__c` rows on one Disposition from both being `Selected`. No validation rule exists on this object (repo-wide VR inventory: 11 rules, none on any disposition object).

### 2.4 Active Listing (spec 21–25)

> spec:22 — "about two months on the market. If there is no traction within the first month — no offers and no real interest — the team discusses it internally and decides whether to change the broker."

What exists:
- `Disposition__c/fields/Listing_Date__c` (Date) and `Days_On_Market__c` (formula: `IF(ISBLANK(Listing_Date__c), null, TODAY() - Listing_Date__c)`)
- `Broker_Listing__c/fields/Days_On_Market__c`, `List_Date__c`, `Offers_Received__c`
- `Broker_Listing__c/fields/Listing_Status__c` — restricted picklist `On Track` / `At Risk` / `Hard Stop`
- `pathAssistants/Disposition_Path.pathAssistant-meta.xml:9` guidance text: *"6-week marketing clock starts on listing date. Week 4 triggers YELLOW flag. Week 6 triggers Hard Stop + escalation to Ali."*

**Nothing implements that sentence.** `Listing_Status__c` has no formula and no flow writing it — it is hand-set. There is no scheduled job for dispositions (the only `Schedulable` in the disposition space, `BrokerCheckInReminderSchedulable.cls:11`, queries `Broker_Assignment__c` — the Property-Management leasing module, not `Disposition__c`).

**🔴 `lwc/listingAlerts/listingAlerts.js` is a two-line empty stub:**

```js
import { LightningElement } from 'lwc';
export default class ListingAlerts extends LightningElement {}
```

It is rendered on the Active Listing stage (`lwc/dispositionMain/dispositionMain.html:14`) and displays nothing. This is the surface where the month-1 traction alert would live.

**Broker-change mechanism: absent.** There is a `quickActions/Broker_Assignment__c.Replace_Broker.quickAction-meta.xml` and a `lwc/brokerReplaceQuickAction` — but they target `Broker_Assignment__c` (PM leasing), **not** `Disposition__c` / `Broker_Listing__c`. Changing the disposition broker today means hand-editing `Disposition__c.Selected_Broker__c` (a Text field) with no history, no re-selection record, and no notification.

`Disposition__c/fields/Next_Broker_Checkin__c` (Date) exists and backs `reports/Dispositions/Broker_Alert_Due.report-meta.xml`, but no automation ever writes it. **NOT ALIGNED.** Also note the spec's period is **two months**; the path guidance says **six weeks** — a spec/implementation-intent conflict worth resolving.

### 2.5 Buyer NDA — on-market (spec 26–41)

> spec:28–40 — states **Not Sent → Sent → Signed, or Declined**

`objects/NDA__c/fields/Status__c.field-meta.xml` — restricted picklist:

| Spec | Implemented | Verdict |
|---|---|---|
| Not Sent | **`Pending`** (default) | name mismatch |
| Sent | `Sent` | ✓ |
| Signed | `Signed` | ✓ |
| **Declined** | *absent* | **missing** |

`pathAssistants/NDA_Path.pathAssistant-meta.xml` mirrors the three values (Pending / Sent / Signed) with no Declined step. **PARTIAL.** Adding `Declined` is additive and low-risk; renaming `Pending` → `Not Sent` is a picklist value change requiring the standing repo sweep rule (grep repo + query org before removing any picklist value).

**Disposition linkage: correct.** `objects/NDA__c/fields/Disposition__c.field-meta.xml` is a Lookup to `Disposition__c` whose `<description>` reads *"For buyer-side NDAs in the Disposition module — links the NDA to the Disposition it protects (Opportunity is left blank in this context)."* So `NDA__c` is already dual-parented exactly as ARCHITECTURE.md §1 says. **ALIGNED.**

> spec:27 — "sent for signature via docusign"

**No DocuSign integration exists.** A repo-wide grep for `docusign` across `.cls`, `.js`, `.html`, `.xml` returns four hits and no integration:
1. `objects/NDA__c/fields/Method__c.field-meta.xml` — a picklist value `DocuSign` (alongside `Wet Sign`)
2. `objectTranslations/NDA__c-en_US/Method__c.fieldTranslation-meta.xml` — its translation
3. `classes/TestDataFactory.cls` — test data
4. `lwc/transactionTaskGroups/__tests__/transactionTaskGroups.test.js` — a test fixture string

No Named Credential, no External Credential, no Apex callout service, no envelope/status object. Signature status is a human-entered picklist. **NOT ALIGNED.** (DocuSign *org* setup, e.g. a managed package, is **NEEDS ORG VERIFICATION** — but nothing in source integrates with one.)

`flows/NDA_Signed_Status_Sync.flow-meta.xml` (before-save, `NDA__c`) derives `NDA_Signed__c` from `Status__c` and stamps `Date_Signed__c` on first Signed. That is real and works — but it is a field sync, not a signature integration and not a notification.

> spec:38 — "Notification: Disposition team and principals when the NDA is signed"
> spec:41 — "Notification: Disposition team" on Declined

**NOT ALIGNED.** `grep -ril "Disposition" force-app/main/default/flows/` returns **nothing** — zero flows in the repo reference `Disposition__c`. `notificationtypes/` contains only `Acquisitions_Deal_Update` and `Broker_Portal_New_Lead`. There is no Disposition custom notification type, no disposition email alert, no disposition-side flow of any kind.

### 2.6 NDA — off-market (spec 113–117)

> spec:114 — "The buyer signs… If a broker introduced them, that broker signs one too. We counter-sign both… information is released only once every NDA is signed."

- **Multiple NDAs per Disposition: structurally supported.** `NDA__c.Disposition__c` is a plain Lookup with `<relationshipName>NDAs</relationshipName>`, so N NDAs may hang off one Disposition today.
- **Party role: absent.** `NDA__c` has `Counterparty_Name__c` (Text) but no field distinguishing *buyer* from *introducing broker*, so "did the broker's NDA come back?" is not queryable.
- **Counter-signature: absent.** No DPEG-signature field or date; `NDA_Signed__c` is a single boolean.
- **All-signed gate: absent.** `Disposition__c` has **zero validation rules** (repo VR inventory below), no rollup of unsigned NDAs, and nothing blocks advancing the stage. Contrast the acquisition side, which *does* have this pattern: `objects/Opportunity/validationRules/NDA_Signed_Before_Deal_Progression.validationRule-meta.xml`.
- **Per-NDA signed notification (spec:117): absent** (see 2.5).

**PARTIAL** — the container works, the rules do not.

Repo-wide validation rules (11 total, for reference): `Competing_Broker_Submission__c/Winning_Lead_Required`, `Deal_Message__c/Exactly_One_Parent`, `Lead/Property_And_Email_Required_To_Convert`, `Lead/Property_And_Email_Required_To_Progress`, `Opportunity/{Approved_LOI_Before_PSA, Close_Date_Before_About_To_Close, Contract_Signed_Before_Closed_Won, NDA_Signed_Before_Deal_Progression, No_Backward_Stage_Movement, Underwriting_Approved_Before_LOI}`, `Property_Registry__c/Winning_Lead_Required`. **None on any disposition object.**

### 2.7 Call for Offers (spec 42–46)

> spec:43 — "The call-for-offers date is held on the Broker Listing."

`objects/Broker_Listing__c/fields/Call_For_Offers_Date__c.field-meta.xml` — Date, on `Broker_Listing__c`, which has `Disposition__c` (Lookup). It is surfaced in `lwc/brokerListing/brokerListing.js:36`. **ALIGNED, exactly as specified — right field on the right object.**

> spec:42 — "Call for Offers — broker-listed sales only" (a stage)

`Disposition_Stage__c` has no `Call for Offers` value. **NOT ALIGNED** as a *stage*; the date exists but the deal never sits in this state.

> spec:46 — "Notification: To be filled"

**OPEN QUESTION** — carried to §5.

### 2.8 Disposition Offer (spec 47–51, 118–122)

> spec:48 — "the buyer, the amount, the due diligence and closing periods"
> spec:119 — "…the earnest money and the financing type"

| Spec term | Field | Type | Verdict |
|---|---|---|---|
| buyer | `Buyer_Name__c` | Text | ✓ |
| amount | `Offer_Amount__c` | Currency | ✓ |
| due diligence period | `Due_Diligence_Days__c` | Number | ✓ |
| closing period | `Closing_Period_Days__c` | Number | ✓ |
| earnest money (off-mkt) | `Earnest_Money_Proposed__c` | Currency | ✓ |
| financing type (off-mkt) | `Offer_Financing_Type__c` | Picklist: All Cash / Financed (with contingency) / Financed (no contingency) | ✓ |

**All six present — ALIGNED.** (The off-market-only fields exist unconditionally, which is fine given there is no path split, but see §4.)

> spec:48 — "**All the negotiation happens there** [the LOI], **not here**."
> spec:119 — "If an offer is strong enough to take forward, the LOI process begins, and all the negotiation happens there."

**🔴 This is the sharpest structural mismatch in the audit.** `objects/Disposition_Offer__c/fields/Offer_Status__c.field-meta.xml:12-46` is a restricted picklist whose first four values are, verbatim, the spec's **LOI stages**:

```
Received  |  Under Review  |  Countered by DPEG  |  Counter Received from Buyer  |  Accepted  |  Rejected  |  Withdrawn by Buyer
```

Alongside it the offer record carries four negotiation fields:
`DPEG_Counter_Price__c`, `DPEG_Counter_Date__c`, `Buyer_Counter_Price__c`, `Final_Agreed_Price__c`.

So the implementation puts the *entire* counter-negotiation on the offer record — precisely what the spec forbids — while the spec's LOI record does not exist. This is not a missing feature; it is the **same negotiation modelled in the wrong place**, which means migrating it is a data question, not just a build question.

A second, related defect: the offer holds only the **latest** counter (single price fields), so "every round is recorded" (spec:128) is unachievable on this shape regardless of where it lives.

**Comparison support (spec:48, "Offers are compared against one another") is thin.** `lwc/dispositionOffer/dispositionOffer.js:12-27` reads the related list via LDS and renders only buyer / amount / date; `handleLogOffer` (line 43) navigates to a blank new-record page. There is no comparison view (contrast `bovComparisonMatrix`, which exists for BOVs). No Apex touches `Disposition_Offer__c` at all — the only reference outside metadata is `classes/TestDataFactory.cls`.

### 2.9 LOI — disposition (spec 52–75, 123–128)

> spec:53–74 — a disposition LOI record with stages **Received → Under Review → Countered by DPEG → Counter Received from Buyer → Executed**

**The disposition LOI does not exist.**

1. **No relationship.** `objects/LOI__c/fields/` contains 28 fields; the only parents are `Opportunity__c` and `Property__c`. There is **no `Disposition__c` lookup**.
2. **No record types.** `LOI__c` has no `recordTypes/` directory (repo-wide there are only the two Opportunity record types).
3. **Different stages.** `objects/LOI__c/fields/Stage__c.field-meta.xml` is restricted to `Draft` (default) / `Prepare/Review` / `Sent` / `Counter` / `Completed`, with `<description>Drives the LOI Lightning Path: Draft - Prepare/Review - Counter - Completed.</description>`. **None of the five disposition values exists anywhere in the repo** on `LOI__c`. (They exist only on `Disposition_Offer__c.Offer_Status__c` — see 2.8.)
4. **Direction is inverted.** The acquisition LOI is *ours going out* (`Submitted_Date__c`, `LOI_Signed__c`, `Approved_By__c`, a `Submit_for_Approval` quick action). The disposition LOI is *theirs coming in* (spec:53: "on a sale it comes from their side").

**Counter history: the mechanism exists but is bound to the wrong parent.** `objects/Counter_Offer__c/fields/` — `LOI__c` (parent), `Direction__c`, `Counter_Price__c`, `Counter_Cap_Rate__c`, `Counter_Date__c`, `Counter_Response__c`, `Revision_Number__c`, `Subsequent_Version__c`. Backed by `CounterOfferService` / `lwc/loiCounterOffer`, and notified by `flows/Counter_Offer_Notify.flow-meta.xml`. This is a good, reusable round-by-round history — but it hangs off the acquisition LOI, and its `Direction__c` semantics are acquisition-shaped.

**Everything downstream is acquisition-shaped too:** `pathAssistants/LOI_Path`, `quickActions/LOI__c.{Advance_Stage, Edit_LOI, Mark_Completed, Mark_Countered, Submit_for_Approval}`, `approvalProcesses/Opportunity.LOI_Approval`, `flows/{LOI_Approval_Stamp, LOI_Signed_Notify}`, `RecordStageAdvanceService`'s `LOI__c` entry.

**LOI notifications (spec 57, 65, 71, 75, 127): NOT ALIGNED** — nothing disposition-side exists.

**NOT ALIGNED.** See §4 for the record-type-vs-new-object decision.

### 2.10 PSA — disposition (spec 76–90, 129–144)

> spec:77 — "On a sale **our own legal team prepares the contract, not the buyer's**"
> spec:79–89 — Initial Draft → Revised → Ready for Execution → Executed

**The four stage values already exist — on the wrong object.** `objects/Contract_Review__c/fields/Negotiation_Status__c.field-meta.xml` is a restricted picklist of exactly `Initial Draft` (default) / `Revised` / `Ready for Execution` / `Executed`. **Exact string match to the spec.** Its `<description>` confirms the intent: *"Junior's Section 15 PSA lifecycle… Moved ONLY by the deal driver via the Advance Stage quick action… Synced to the coarse Stage__c by the Contract_Review_Stage_Sync flow… Executed triggers the transaction handoff."*

But:
- `objects/Contract_Review__c/fields/` has **only `Opportunity__c`** as a parent — no `Disposition__c` lookup, no record types.
- `objects/PSA_Version__c/fields/Direction__c.field-meta.xml` is `Seller` / `Ours`, described as *"Who sent this PSA version: Seller (their draft/counter to us) or Ours (our redline back)."* On a **disposition DPEG *is* the seller**, so this vocabulary inverts and would be actively misleading if reused unchanged.
- `Executed` on the acquisition side triggers `ContractExecutionService` → creates a `Transaction__c`. On a disposition, Executed must move to **Closing** on the `Disposition__c`, not mint an acquisition Transaction. Reusing the object without branching would fire the wrong automation.
- Nothing models "our legal issues the **first** draft" — on the acquisition side the first draft arrives from the seller.

> spec:132 — "The stage follows the negotiation status"

**ALIGNED in mechanism, with a live trap.** `flows/Contract_Review_Stage_Sync.flow-meta.xml` is exactly this derivation. `Contract_Review__c.Stage__c` is a coarse picklist (`PSA Drafting` / `Review` / `Contract Execution`, plus three `isActive=false` legacy values) recomputed from `Negotiation_Status__c`. Per the documented org behaviour, **writing `Stage__c` directly commits and is then silently discarded** — a success toast, `LastModifiedDate` moves, value unchanged. Any disposition-side PSA that reuses this object inherits that trap and must drive `Negotiation_Status__c`.

**PSA notifications (spec 81, 84, 87, 90, 135–144): NOT ALIGNED.** Acquisition analogues exist and are clonable — `flows/PSA_Ready_Notify.flow-meta.xml`, `flows/PSA_Version_Notify.flow-meta.xml` — but neither references a Disposition.

**Off-market difference (spec:144): PSA Executed notifies Disposition team AND Finance**, versus on-market's Disposition team only (spec:90). **Unexpressible today** — there is no path discriminator (§2.0) and no notification layer.

### 2.11 Closing (spec 91–95, 145–149)

> spec:92 — "The principals go through the completed PSA and approve here, and **the wire check must be complete before funds move**."

- **Stage exists.** `Disposition_Stage__c` includes `Closing`. `pathAssistants/Disposition_Path.pathAssistant-meta.xml:18-23` shows `PSA_Executed__c` + `Title_Company__c` on that step with the info text *"Wire fraud prevention gate (6 fields) must be complete before wiring."* — **the rule is documented as guidance text and implemented nowhere.**
- **Approval (spec:94): NOT ALIGNED.** No approval process on `Disposition__c`.
- **Wire gate: NOT ALIGNED.** `classes/WireService.cls:43-64` — `saveWire` unconditionally applies the fields and `upsert w;`. No completeness check, no exception, no `Database.setSavepoint` guard. No validation rule on `Wire__c` or `Disposition__c`. `lwc/wireVerification/wireVerification.js:45-51` reads a server-computed `fieldsComplete` and colours a badge green at 6 — **display only, nothing blocks**. There is no "funds move" action in the app at all, so there is nothing for a gate to guard yet.
- **Closing checklist exists but is unrelated to the spec.** `classes/DispositionTaskService.cls:27-31` find-or-creates three standard Tasks: `PSA Executed`, `Title Company Engaged`, `Closing Statement Received`. Useful, not spec'd, not a gate.

### 2.12 Wire (spec 96–100, 150–154)

> spec:97 — "Six fields must be confirmed before funds move: where the payment instructions came from, that verbal verification was completed, the verifier's name, their phone number, the date and time of verification, and the confirmed amount."

| # | Spec field | Implemented field | Type | `required` |
|---|---|---|---|---|
| 1 | where instructions came from | `Wire_Instructions_Source__c` | Text(255) | false |
| 2 | verbal verification completed | `Verbal_Verification_Completed__c` | Checkbox (default false) | n/a |
| 3 | verifier's name | `Verifier_Name__c` | Text(255) | false |
| 4 | verifier's phone | `Verifier_Phone__c` | Phone | false |
| 5 | date and time of verification | `Verified_DateTime__c` | DateTime | false |
| 6 | confirmed amount | `Confirmed_Wire_Amount__c` | Currency(18,2) | false |

**All six exist and are correctly typed — ALIGNED on the data model.** (`objects/Wire__c/fields/`; plus `Disposition__c` lookup with `relationshipName` `Wires`.)

**Enforcement: NOT ALIGNED.** Every field is optional; there is no validation rule, no required-on-layout guarantee in source, and no Apex assertion. A `Wire__c` with all six blank saves cleanly.

**One nuance to confirm with the client:** `classes/WireService.cls:57-61` **auto-stamps** `Verified_DateTime__c = Datetime.now()` the first time the verbal checkbox is ticked, and **clears it** whenever the checkbox is unticked. That records *when the box was ticked in Salesforce*, not *when the call happened*. For an anti-fraud control the spec describes as a confirmed fact, a user-entered datetime may be the correct reading.

### 2.13 Completed (spec 101–105, 155–159)

`Disposition_Stage__c` includes `Completed`; `pathAssistants/Disposition_Path.pathAssistant-meta.xml:24-29` gives it a step with `Closing_Date__c` + `Net_Sale_Proceeds__c`. **ALIGNED.** Nothing enforces terminality (no `No_Backward_Stage_Movement` equivalent — that VR exists only on Opportunity).

### 2.14 Departments (all stages)

Spec names five: **Disposition, Legal, IR, Principals, Finance.**

In source (`permissionsets/`, 35 files): `DPEG_App_Disposition`, `DPEG_Disposition_Edit`, `DPEG_Disposition_View`, `Disposition_Dashboard_Access`. **No Legal, IR, Finance or Principal permission set exists.** No queue metadata for a Disposition team is in the repo (the repo's only queue work is the Acquisition queue, and per prior findings queue/group **membership is not deployable**).

**NEEDS ORG VERIFICATION** — role hierarchy, public groups, queue membership and the four principals' identities live in the org, not in source. Note also that `profiles/**` is `.forceignore`d in this repo, so profile-level access is invisible to any file-based check.

### 2.15 Notifications — full enumeration

Every notification the spec asks for, against what exists:

| # | Spec line | Trigger | Recipients | Exists? |
|---|---|---|---|---|
| 1 | 38 | NDA Signed (on-mkt) | Disposition team + principals | ✗ |
| 2 | 41 | NDA Declined | Disposition team | ✗ (state missing too) |
| 3 | 46 | Call for Offers | *"To be filled"* | ✗ / undefined |
| 4 | 57 | LOI Received | Disposition team | ✗ |
| 5 | 65 | LOI Countered by DPEG (every counter) | Disposition team | ✗ |
| 6 | 71 | LOI Counter Received from Buyer (every counter) | Disposition team | ✗ |
| 7 | 75 | LOI Executed | Legal | ✗ |
| 8 | 81 | PSA Initial Draft | Disposition team + Legal | ✗ |
| 9 | 84 | PSA Revised (each version) | Disposition team + Legal | ✗ |
| 10 | 87 | PSA Ready for Execution | Disposition team | ✗ |
| 11 | 90 | PSA Executed (**on-market**) | Disposition team | ✗ |
| 12 | 117 | NDA Signed (**off-market**, each NDA) | Disposition team | ✗ |
| 13 | 127 | LOI counters / LOI executed (off-mkt) | Disposition team / Legal | ✗ |
| 14 | 144 | PSA Executed (**off-market**) | Disposition team **+ Finance** | ✗ |

**14 of 14 missing.** Evidence: `grep -ril "Disposition" force-app/main/default/flows/` → no matches (25 flows, none disposition-side). `notificationtypes/` → only `Acquisitions_Deal_Update.notiftype-meta.xml` and `Broker_Portal_New_Lead.notiftype-meta.xml`.

Clonable acquisition precedents: `Counter_Offer_Notify`, `LOI_Signed_Notify`, `PSA_Version_Notify`, `PSA_Ready_Notify`, `Opportunity_UW_Approved_Notify`, `Transaction_Opened_Notify`.

---

## 3. Gaps requiring build work

Ordered by importance. **S** ≈ ≤1 day, **M** ≈ 2–5 days, **L** ≈ >1 week.

1. **On-market vs off-market path discriminator on `Disposition__c`.** *(NEW RECORD TYPE or picklist — decision in §4.1.)* Touches: `Disposition__c` object + a new field or `recordTypes/`, `Disposition_Path` (would become two paths), `Disposition_Record_Page` flexipage, `lwc/dispositionMain` + `lwc/dispositionSidebar` (both branch on stage today), every permission set granting the object. **Size: M.** **Dependency: blocks items 2, 8, 9 and the off-market notification split** — nothing else can branch until this exists. **Risk:** record types on a live object require assigning them to existing rows and to every profile/permission set.

2. **Missing stage values on `Disposition_Stage__c`: `Call for Offers`, `LOI`, `PSA` (on-market) and `NDA`, `Disposition Offer` (off-market).** Touches: `Disposition_Stage__c.field-meta.xml`, `Disposition_Path` (steps per stage), `dispositionMain`/`dispositionSidebar` branch logic, `DispositionController.getClosingSummary` consumers, the Disposition dashboard reports that group by stage. **Size: S** for the picklist, **M** including path + page branching. **Depends on #1** if the two paths are to show different stage sets.

3. **Disposition LOI — record + 5 stages + counter history + notifications.** *(NEW record type on `LOI__c` **or** a new object — decision in §4.2.)* Touches: `LOI__c` (`Disposition__c` lookup, record type, per-RT picklist value set), `Counter_Offer__c` (must reach a disposition LOI), `LOI_Path` (second path), `LOI__c` quick actions, `RecordStageAdvanceService`'s `LOI__c` entry (its `NEXT_STAGE` map is linear and single-valued today), 4 new flows/notifications. **Size: L.** **Risk:** the acquisition LOI is live, gated and deployed — any change to `LOI__c.Stage__c`'s value set or to `RecordStageAdvanceService` can regress it.

4. **Migrate negotiation off `Disposition_Offer__c`.** Remove/retire `Offer_Status__c`'s four LOI-shaped values plus `DPEG_Counter_Price__c`, `DPEG_Counter_Date__c`, `Buyer_Counter_Price__c`, `Final_Agreed_Price__c` once #3 lands; leave the offer as capture + comparison only. **Size: M.** **Risk: this is the highest-risk item in the list** — it is a *data migration*, not just a schema change, and the standing repo rule applies (grep repo + query org before removing any picklist value; `Received` / `Under Review` / `Accepted` etc. are common strings likely active on other fields). Also verify no report or list view filters on these values.

5. **Wire-complete gate before funds move.** Touches: a validation rule on `Wire__c` (or `Disposition__c` on stage exit), and/or an entry criterion on the Closing approval (#6). **Size: S.** **Note:** the app has no "funds move" action today, so decide what the gate actually guards — most naturally the Closing→Completed transition and/or approval submission.

6. **Three approval processes on `Disposition__c`** — Sale decision (Readiness), Broker selection (BOV Outreach), Final sale terms + closing wire (Closing). All `FirstResponse`. Touches: `approvalProcesses/Disposition__c.*`, plus stamp flows if approver identity must be recorded (`ApprovalAuditService` is the precedent — and carries the `<runInMode>SystemModeWithoutSharing</runInMode>` requirement, since an approval-triggered flow runs as the **approver**, who is read-only here). **Size: M.** **Dependency:** the four principals' user records must exist — the two deployed approvals name only **two** approvers. **NEEDS ORG VERIFICATION.**

7. **Notification layer for Disposition (14 notifications).** Touches: a new `Disposition_Update` notification type, ~8–10 record-triggered flows, recipient groups/queues. **Size: L** (M if the recipient groups already exist in the org). **Dependency:** recipient groups for Disposition team / Legal / IR / Finance / Principals — **NEEDS ORG VERIFICATION**. **Depends on #1** for the on/off-market PSA-Executed split (#14 in the table).

8. **NDA: add `Declined`, rename `Pending` → `Not Sent`, add party role + counter-sign, add the all-signed gate.** Touches: `NDA__c.Status__c`, `NDA_Path`, `flows/NDA_Signed_Status_Sync` (its `Is_Signed` decision defaults everything non-Signed to false — verify Declined behaves), a new `Party_Role__c` picklist (Buyer / Introducing Broker), counter-sign date field, a rollup or VR for the all-signed gate. **Size: M.** **Risk:** the picklist-value sweep rule applies to renaming `Pending`; `NDA__c` is shared with the acquisition module, so the value set change hits Opportunity NDAs too.

9. **Disposition PSA.** *(Reuse `Contract_Review__c` with a record type + `Disposition__c` lookup, or a new object — decision in §4.3.)* Touches: `Contract_Review__c`, `PSA_Version__c` (`Direction__c` vocabulary inverts on a sale), `Contract_Review_Stage_Sync` flow, `ContractExecutionService` (must NOT mint a `Transaction__c` for a disposition), `Contract_Review_Negotiation_Path`, 4 notifications. **Size: L.** **Risk:** `ContractExecutionService` fires the acquisition Transaction handoff on `Executed` — reusing the object without branching would create spurious Transactions on every sale.

10. **Active-Listing traction monitor + broker change.** Touches: `lwc/listingAlerts` (currently a two-line empty stub), a scheduled job or formula driving `Broker_Listing__c.Listing_Status__c`, a "Change Broker" quick action + `Broker_Listing__c` history, `Disposition__c.Next_Broker_Checkin__c` automation. **Size: M.** **Open:** the spec says two months / month-1 checkpoint; the path guidance text says six weeks / week 4 / week 6 — resolve before building.

11. **`Disposition__c.Selected_Broker__c` is Text(255), not a lookup.** Should be a `Contact` (or `BOV_Submission__c`) lookup so broker identity is a record. Touches: the field, `BOV_Submission__c.Selected_Broker__c` (a formula pulling it through), `BovController.OutreachSummary.selectedBroker`, `lwc/bovOutreach`. **Size: S–M.** Data migration on existing rows.

12. **"Override" button does nothing (yellow band).** `lwc/sellMeterList/sellMeterList.js:160-164` early-returns on any action other than `initiate`. Decide the intended behaviour (confirm dialog + create with an override reason?), then implement. **Size: S.** Also worth adding the **server-side** sell-meter assertion in `DispositionService.findOrCreate` — the gate is client-only today.

13. **`Brokers_Contacted__c` / `Responses_Received__c` are hand-keyed Numbers, not rollups** of `BOV_Submission__c`. They drive the outreach tile and the `>= 3` matrix reveal, so they can silently disagree with the child records. **Size: S** (both are Lookup-parented, so a true roll-up summary needs Master-Detail or Apex/flow-maintained counters).

14. **`bovOutreach` NDA pill is hard-coded.** `lwc/bovOutreach/bovOutreach.js:12` — `_ndaStatus = 'Signed';` with a comment saying to wire it to the NDA record. It displays "Signed" unconditionally. **Size: S.** Worth fixing regardless of the wider NDA work — it currently misreports a compliance state.

15. **Only one `Selected` BOV submission should be possible** ("the one jockey", spec:16). No rule enforces it. **Size: S** (validation rule or flow).

---

## 4. Structural decisions the user must make

### 4.1 On-market vs off-market: record type, or picklist?

**Recommendation: a Record Type on `Disposition__c`** (`On_Market` / `Off_Market`).

Reasoning: the two paths differ in their **stage sequence**, which is exactly what a record type buys — `PathAssistant` is keyed by `recordTypeName` (see `Disposition_Path.pathAssistant-meta.xml:35`, currently `__MASTER__`), and a per-record-type picklist value set lets on-market expose `BOV Outreach` / `Active Listing` / `Call for Offers` while off-market exposes `NDA` / `Disposition Offer` — with neither showing the other's stages. A plain picklist cannot restrict the stage value set, so users would see all nine stages on every disposition and the path would be wrong for half of them. Record types also give per-type page layouts (the off-market path has no Broker Listing at all) and per-type flow entry criteria for the differing PSA-Executed notification (spec:90 vs 144).

Cost: record types must be assigned in every profile/permission set, and existing rows need a default. Precedent exists in this repo — `Opportunity` already uses `Land` / `Commercial` record types with per-type sales processes for exactly this reason.

**Alternative worth raising with the client first:** if the two paths will *always* share the same stage picklist and differ only in which stages get used, a simple `Sale_Channel__c` picklist is far cheaper. Ask whether an off-market deal can ever go to market (i.e. change channel mid-flight) — a record type change mid-record is possible but awkward, and that answer should decide it.

### 4.2 Disposition LOI: record type on `LOI__c`, or a new object?

**Recommendation: a record type on `LOI__c`** (`Acquisition_LOI` / `Disposition_LOI`) plus a `Disposition__c` lookup and a **record-type-specific value set** on `Stage__c`.

Reasoning **for** reuse: an LOI is the same business artefact in both directions, and `Counter_Offer__c` — the round-by-round history the spec explicitly requires ("Every round is recorded, both our counters and the buyer's", spec:128) — is already a child of `LOI__c` with `Direction__c`, `Revision_Number__c` and a working `Counter_Offer_Notify` flow. Reusing `LOI__c` means that history, the `loiCounterOffer` LWC and `CounterOfferService` come free. Building a new object means re-implementing all of it.

Reasoning **against** a new object beyond the duplication: two objects named LOI is a maintenance trap of the kind ARCHITECTURE.md already warns about elsewhere ("THREE SIMILARLY-NAMED LEAD-CONVERSION CLASSES").

**The risks to price in, honestly:**
- `LOI__c.Stage__c` is `<restricted>true</restricted>`. Adding five values makes them *globally* available and then restricts them per record type — so the acquisition Path and `RecordStageAdvanceService`'s `LOI__c` map must be verified unchanged. `RecordStageAdvanceService` is documented as a single `Map<SObjectType, StageConfig>`; it would need to become record-type-aware, which its current shape does not express.
- Several `LOI__c` fields are acquisition-directional (`Submitted_Date__c`, `Approved_By__c`, `Submit_for_Approval` quick action). They must be layout-excluded from the disposition record type, not deleted.
- `approvalProcesses/Opportunity.LOI_Approval` is Opportunity-entry-criteria'd, so it will not accidentally fire — verify.

**A third option worth a moment: extend `Disposition_Offer__c` upward** rather than adding an LOI, since it *already* holds the five stages and the counter fields. Reject this — the spec is unambiguous that offers are compared and *then* an LOI begins (one LOI per selected offer, many offers per disposition), and collapsing them destroys that cardinality. But it does mean item 3.4 (the migration) is the real cost of doing this right.

### 4.3 Disposition PSA: reuse `Contract_Review__c`, or a new object?

**Recommendation: reuse `Contract_Review__c` with a record type + `Disposition__c` lookup**, but treat the automation branch as the bulk of the work, not the schema.

Reasoning: `Negotiation_Status__c` **already has the exact four values the spec names** (`Initial Draft` / `Revised` / `Ready for Execution` / `Executed`), `PSA_Version__c` already gives version history, `Contract_Review_Stage_Sync` already derives the coarse stage from the negotiation status (spec:132 verbatim), and `Contract_Review_Negotiation_Path` already renders it. Duplicating that is pure waste.

**The three things that must branch, and they are not optional:**
1. **`ContractExecutionService`** stamps the Opportunity and creates a `Transaction__c` on `Executed`. On a disposition it must instead move `Disposition_Stage__c` to `Closing`. Without a record-type branch, every executed sale mints a phantom acquisition Transaction.
2. **`PSA_Version__c.Direction__c` (`Seller` / `Ours`) inverts.** On a sale *we* are the seller. Either add `Buyer` as a value, or relabel per record type, or (cleanest) rename to a direction-neutral pair like `Counterparty` / `Ours`. Leaving it is the kind of quiet semantic inversion that produces wrong reports for a year.
3. **`Stage__c` is derived and silently discards direct writes.** Any new disposition quick action must drive `Negotiation_Status__c`. This is a documented org behaviour, not a theory.

Also note the spec's "our legal issues the **first** draft" (spec:80) inverts the acquisition assumption that the first draft arrives from the seller — a default-value and guidance-text change, but check `Contract_Review_Stage_Sync`'s conditions don't encode the acquisition assumption.

### 4.4 Where does the disposition NDA's party role live?

**Recommendation: a `Party_Role__c` picklist on `NDA__c`** (`Buyer` / `Introducing Broker`), plus a counter-signature date. Not a new object — the spec describes at most two NDAs per buyer, and `NDA__c` is already dual-parented (Opportunity / Disposition) with a working status sync. The all-signed gate is then a validation rule or a rollup counting unsigned NDAs on the Disposition.

---

## 5. Open questions for the user

1. **Call for Offers notification (spec:46) is literally "To be filled."** Who is notified, and on what event — the date being set, the date arriving, or offers being received? This is a genuine hole in the spec, not an oversight in the build.

2. **How many principals, and who?** The spec says "any one of the **four** principals" at three separate approvals. The two deployed approval processes name **two** approvers (`nikhil.dhanani@…`, `aftab.ali.dpeg.usman@…`) with `FirstResponse`. Are there four principals in this org, or is "four" aspirational? *(NEEDS ORG VERIFICATION.)*

3. **Two months or six weeks on market?** Spec:22 says "about two months… no traction within the first month." `Disposition_Path.pathAssistant-meta.xml:9` says "6-week marketing clock… Week 4 triggers YELLOW flag. Week 6 triggers Hard Stop + escalation to Ali." These are different clocks with different checkpoints. Which is authoritative?

4. **Is DocuSign actually licensed/installed in this org?** Nothing in source integrates with it; `NDA__c.Method__c` merely has a `DocuSign` value a human picks. If a DocuSign managed package is installed, the build is "wire the envelope status back"; if not, it is a full integration and, per ARCHITECTURE §3.1, should route through ASB rather than a direct callout. *(NEEDS ORG VERIFICATION.)*

5. **Can a disposition switch between off-market and on-market mid-flight?** (e.g. direct outreach fails, so it goes to a broker.) This decides §4.1 — a record type is awkward to change on a live record; a picklist is not.

6. **What does "Override" do on a yellow sell meter?** Today the button renders and does nothing. Should it create the Disposition with an override reason recorded, require an approval, or be removed?

7. **What are the existing counter values on `Disposition_Offer__c` in the live org?** Before retiring `Offer_Status__c`'s LOI-shaped values (§3.4), we need to know how many production rows carry `Countered by DPEG` / `Counter Received from Buyer` and whether they must migrate to the new LOI record or can be abandoned. *(NEEDS ORG VERIFICATION.)*

8. **Who are "Disposition team", "Legal", "IR", "Finance" as Salesforce constructs?** Public groups, queues, roles, or permission sets? All 14 notifications and the department column depend on this, and none of it is in source. *(NEEDS ORG VERIFICATION.)*

9. **Should `Verified_DateTime__c` be user-entered rather than auto-stamped?** `WireService.cls:57-61` stamps `Datetime.now()` when the verbal checkbox is ticked. The spec calls it "the date and time of verification" — a fact about a phone call, which may have happened earlier.

10. **Is the "3+ BOV responses reveals the comparison matrix" rule (`BovController.cls:78`) intentional?** It exists in code and in the path guidance but appears nowhere in the spec.

---

## Appendix — evidence index

| Claim | File |
|---|---|
| Disposition stage values (5) | `force-app/main/default/objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml:13-37` |
| No record types except Opportunity | `find force-app/main/default/objects -name "*.recordType-meta.xml"` → 2 hits, both `Opportunity/recordTypes/` |
| Single master path | `force-app/main/default/pathAssistants/Disposition_Path.pathAssistant-meta.xml:35` |
| Sell-meter bands | `force-app/main/default/classes/SellMeterController.cls:90-101` |
| Initiate/Override/Hold labels; red disabled | `force-app/main/default/lwc/sellMeterList/sellMeterList.js:107-110` |
| Override is a no-op | `force-app/main/default/lwc/sellMeterList/sellMeterList.js:160-164` |
| No server-side sell-meter gate | `force-app/main/default/classes/DispositionService.cls:31-39` |
| Only 2 approval processes, both Opportunity, 2 approvers, FirstResponse | `force-app/main/default/approvalProcesses/` (2 files); `Opportunity.LOI_Approval…:19-27`, `Opportunity.Underwriting_Approval…:21-29` |
| BOV field set (7/7) | `force-app/main/default/objects/BOV_Submission__c/fields/` |
| BOV statuses Selected/Backup | `force-app/main/default/objects/BOV_Submission__c/fields/Submission_Status__c.field-meta.xml` |
| `matrixGenerated = responses >= 3` | `force-app/main/default/classes/BovController.cls:78` |
| `listingAlerts` is an empty stub | `force-app/main/default/lwc/listingAlerts/listingAlerts.js` (2 lines) |
| Broker check-in schedulable targets PM, not Disposition | `force-app/main/default/classes/BrokerCheckInReminderSchedulable.cls:11` |
| NDA statuses Pending/Sent/Signed (no Declined) | `force-app/main/default/objects/NDA__c/fields/Status__c.field-meta.xml` |
| NDA→Disposition lookup exists, with description | `force-app/main/default/objects/NDA__c/fields/Disposition__c.field-meta.xml` |
| No DocuSign integration | repo-wide grep `docusign` → 4 hits: `Method__c` field, its translation, `TestDataFactory.cls`, one Jest fixture |
| Call-for-offers date on Broker Listing | `force-app/main/default/objects/Broker_Listing__c/fields/Call_For_Offers_Date__c.field-meta.xml` |
| Offer field set (6/6) | `force-app/main/default/objects/Disposition_Offer__c/fields/` |
| **LOI stages live on the OFFER record** | `force-app/main/default/objects/Disposition_Offer__c/fields/Offer_Status__c.field-meta.xml:12-46` |
| Counter fields on the offer | `Disposition_Offer__c/fields/{DPEG_Counter_Price__c, DPEG_Counter_Date__c, Buyer_Counter_Price__c, Final_Agreed_Price__c}` |
| `LOI__c` has no Disposition lookup | `force-app/main/default/objects/LOI__c/fields/` (28 files; parents = `Opportunity__c`, `Property__c`) |
| Acquisition LOI stage values | `force-app/main/default/objects/LOI__c/fields/Stage__c.field-meta.xml` |
| Counter history parented to `LOI__c` | `force-app/main/default/objects/Counter_Offer__c/fields/LOI__c.field-meta.xml` |
| PSA four states exist on Contract Review | `force-app/main/default/objects/Contract_Review__c/fields/Negotiation_Status__c.field-meta.xml` |
| Contract Review is Opportunity-only | `force-app/main/default/objects/Contract_Review__c/fields/` |
| `Stage__c` derived by before-save flow | `force-app/main/default/flows/Contract_Review_Stage_Sync.flow-meta.xml`; `Negotiation_Status__c` `<description>` |
| PSA version direction is acquisition-shaped | `force-app/main/default/objects/PSA_Version__c/fields/Direction__c.field-meta.xml` |
| Wire six fields, all optional | `force-app/main/default/objects/Wire__c/fields/` |
| No wire gate | `force-app/main/default/classes/WireService.cls:43-64` |
| Wire datetime auto-stamped | `force-app/main/default/classes/WireService.cls:57-61` |
| Zero validation rules on any disposition object | `find force-app/main/default/objects -name "*.validationRule-meta.xml"` → 11 hits, none disposition |
| Zero flows reference Disposition | `grep -ril "Disposition" force-app/main/default/flows/` → no matches |
| Only 2 notification types, neither disposition | `force-app/main/default/notificationtypes/` |
| Hard-coded NDA pill | `force-app/main/default/lwc/bovOutreach/bovOutreach.js:12` |
| Record page branches on stage only | `force-app/main/default/lwc/dispositionMain/dispositionMain.html`, `lwc/dispositionSidebar/dispositionSidebar.html` |
| `Disposition_Offer__c` untouched by Apex | `grep -rln "Disposition_Offer__c" classes/` → `TestDataFactory.cls` only |
