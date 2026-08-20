# Disposition Tranche 2 — Deal Summary, Broker Replacement History, Buyer Activity Timeline

**Date:** 2026-08-20
**Author:** Documentation Agent
**Status:** Metadata, Apex and LWC for all four workstreams (Validations, Broker History, Deal
Summary, Buyer Timeline) are present and internally consistent in the repo. Everything described
below is **dry-run validated only** — no live deploy is claimed or verified in this document (see
[Test/Verification Evidence](#-testverification-evidence)). One open decision (`Reason__c`'s
picklist values) is explicitly unconfirmed and must not be treated as final.

---

## 📋 Overview

### Original Request

> the Deal Summary lwc on disposition record to show NDA, LOI and PSA, visible on every stage

> a component which will show broker history — for example if broker was replaced

> a buyer activity timeline. Once an NDA is fully executed, automatically record the signed date.
> From that date, track how long it takes us to release the confidential materials, then track how
> long the buyer takes to review and respond.

Full item-by-item scope, including the discovery items and open decisions quoted throughout this
document, lives in `agent-output/disposition-tranche-2-requirements.md` (the design agent's output,
whose own header records "decisions are USER-CONFIRMED"). This document does not repeat that
transcription; it records what the repo actually contains today and calls out every place a claim in
the design doc turned out to need reconciliation once the code was written.

### Business Objective

A disposition (sell-side) deal today spans up to 11 stages across three related objects (NDA, LOI,
Contract Review/PSA), a broker relationship that can be replaced mid-deal with no record of why, and
a buyer journey (NDA signed → materials released → offer received) that nobody could see end to end.
This tranche closes all three gaps: one always-visible summary card so a driver never has to click
into three separate related lists to see deal state; an append-only audit log so a broker swap is a
recorded decision instead of an overwritten field; and a computed timeline so the business can finally
answer "how long does it take a signed buyer to get materials, and how long do they take to respond"
instead of reconstructing it by hand from three objects' timestamps.

### Summary

Three new/expanded surfaces ship: `lwc/dispositionDealSummary`, an ungated card in the record page
**sidebar** (placed first, before `dispositionSidebar`) reading NDA counts + latest NDA/LOI/PSA state
across four independent, narrowly-scoped fail-soft reads; a new child object `BOV_Broker_Change__c`
plus `lwc/bovBrokerChangeHistory`, recording every BOV broker swap with both parties' names, firms,
reason and notes, written as the last DML inside `BovSubmissionService.replaceSelectedBroker`'s
existing savepoint; and `lwc/dispositionBuyerTimeline`, backed by the org's **first-ever `NDA__c`
trigger**, which stamps a buyer Contact's name onto each NDA and computes two durations (days to
release materials, days for the buyer to respond) while deliberately never reading the latching
`NDA_Signed__c` checkbox. Alongside these three, the tranche also shipped Workstream A — required
fields, two "only one Selected sibling" trigger guards, six sanity validation rules, and the
`NDA_Signed__c` latch fix that Workstream D's timeline depends on for correctness — because the design
doc identified it as a load-bearing prerequisite, not a separate ask. A same-day code review pass also
found and fixed an already-**live**, already-deployed defect unrelated to any of the three asks: five
Contact-lookup fields (three of them pre-existing) were filtering on a checkbox (`Is_Broker__c`) that
zero live Contacts carry, silently refusing every real broker in the org.

---

## 🏗️ Key Design Decisions and Rationale

### The broker lookup filter defect — the most important finding in this tranche

**What was wrong, and for how long.** Three fields deployed **before** this tranche —
`Disposition__c.Broker__c`, `Broker_Assignment__c.Broker__c`, `Lease_Inquiry__c.Broker__c` — carried
an active, non-optional lookup filter testing `Contact.Is_Broker__c = True`. A same-day code review
measured this live on `usman-dpeg`:

```
SELECT COUNT(Id) FROM Contact WHERE Is_Broker__c = true                 -> 0
SELECT COUNT(Id) FROM Contact WHERE RecordType.DeveloperName = 'Broker' -> 19
```

**Zero Contacts satisfied the filter these three fields enforced. Nineteen real brokers existed, all
on the `Contact.Broker` record type.** The broker "definition" in this application had migrated from
the checkbox to the record type at some earlier point, and only `BOV_Submission__c.Broker__c` — the
one field added *in this tranche*, and the only one of the family written against the current
definition from the start — was repointed to the record-type predicate. The three older fields were
never touched, so every off-market broker pick, every broker assignment, and every lease-inquiry
broker pick had been silently refusing all 19 real brokers.

**All five are now on the record-type predicate**, `Contact.RecordType.DeveloperName = 'Broker'`: the
three pre-existing fields above, plus the two new lookups this tranche adds on `BOV_Broker_Change__c`
(`Outgoing_Broker__c`, `Incoming_Broker__c`). Each field's own XML comment carries a "🔴 RECONCILED
2026-08-20 (code review)" block quoting the measurement and naming all five sibling files corrected in
the same pass — read `objects/Disposition__c/fields/Broker__c.field-meta.xml` for the fullest version
of the writeup; the other four cross-reference it rather than repeating it.

**Why nothing caught it before this tranche.** `TestDataFactory.createBrokerContact(s)` sets **both**
`Is_Broker__c = true` **and** the `Contact.Broker` record type on every fixture it builds, so every
existing test satisfied both the retired predicate and the current one simultaneously — a test fixture
built to be safe against either definition cannot distinguish which one a field is actually enforcing.
Production Contacts, by contrast, satisfy only the current one (the record type). The three older
fields therefore deployed green, passed every Apex and Jest test that ever touched them, and simply
never worked for a real user picking a real broker.

**How it survived code review too.** `Disposition__c.Broker__c`'s own header comment, added when the
field was created, *already stated* the broker definition had moved to the record type — in the same
file, a few lines above a `<lookupFilter><filterItems>` block that still read
`Contact.Is_Broker__c = True`. The comment documented the migration directly above a filter that had
never migrated. A reviewer reading the prose without independently reading the twelve lines of XML
underneath it would have every reason to believe the field was already correct.

**What is NOT changed, and why.** `Opportunity.Broker__c` carries no `<lookupFilter>` element at all
(verified by reading the file directly, twice) — it was never a sibling of this family despite three
files in the repo previously claiming it was, and none is being added: that field is machine-stamped
by `LeadConvertService` at conversion, and an active filter there would make lead conversion fail hard
for the exact non-Broker-record-type Contacts Broker Protection's intake path creates. `Is_Broker__c`
itself is retained on `Contact` but is no longer the definition; its retirement is a separate, deferred
task, out of scope here.

### The timeline's central correctness property: what it must never read

The user's own framing — "once an NDA is fully executed, automatically record the signed date" —
sounds like a one-field read (`NDA_Signed__c`), and the design doc's discovery work (§0 C-4/C-5,
§1.3) found that reading it, or its date field alone, would both be silently wrong:

- **`NDA_Signed__c` latches.** Even after this tranche's own fix (below), the checkbox is only ever
  *cleared* on `Declined`; it stays `true` through `Sent`, `Received`, `Pending` and `Not Sent`, and
  for any row saved before this tranche it can still read `true` after the party declined. A timeline
  reading it would show a signed NDA for a counterparty who refused — directly beside the NDAs related
  list on the same page, which would say `Declined`. `NdaSelector.selectBuyerTimelineByDispositionId`
  does not select the field, and `DispositionBuyerTimelineService`'s header states in terms: *"THIS
  TIMELINE MUST NOT READ `NDA__c.NDA_Signed__c`. IT DOES NOT. DO NOT ADD IT."*
- **`Date_Signed__c` alone is not sufficient — the sharper half of the same trap.** The before-save
  flow `NDA_Signed_Status_Sync` never clears `Date_Signed__c`, by explicit, pre-existing design (the
  Path Assistant's own comment: *"it never clears `Date_Signed__c` — so the historical signature date
  is retained while the record stops counting as signed"*). A `Signed → Declined` party therefore keeps
  a non-null `Date_Signed__c` forever.

**The gate is `Status__c = 'Signed'`; `Date_Signed__c` is only the value displayed once that gate
passes.** `DispositionBuyerTimelineService.buildRow` tests `Status__c` first and only then reads the
date — the header calls this ordering "the whole point," because reversing the two tests is the same
output today and one careless edit away from leaking a declined party's retained signature date. A
declined party's row is built and returned **before** either date field is ever touched (an early
`return` inside `buildRow`), so there is no code path — however the arithmetic downstream is later
changed — that could leak the retained date onto a declined row.

### Declined parties are shown, not hidden

`NDA__c.allowDelete` stays `false` on both disposition permission sets (a pre-existing decision, D20),
so a declined party persists as a real, permanent row. The timeline renders it deliberately, not by
omission:

- **Audit evidence, and consistency with the page it sits on.** Hiding a declined party would make the
  timeline disagree with the NDAs related list on the same record page — an analyst would count three
  parties in one component and two in the other, with nothing to explain the difference.
- **Every date and duration column renders an em-dash**, and the retained `Date_Signed__c` is never
  shown — suppressed in the service (`buildRow`'s early return), not in the component, specifically so
  no future template change can leak it across the `@AuraEnabled` boundary.
- **Sorted last**, after active parties, mirroring `brokerAssignmentHistory`'s active-first precedent.
  The sort happens in Apex (`DispositionBuyerTimelineService.getTimeline`), not in JavaScript — the
  component preserves server order — because, per that method's header, the ordering is "a statement
  about the data," falsifiable by an Apex test with the records in front of it, not a presentation
  preference.
- **Accessibility:** the word "Declined" (or an equivalent `aria-label`) must render as text, not only
  as a coloured badge — the design doc names a prior incident in this repo where a text-to-badge swap
  deleted accessible content a test had already pinned.

### The history insert is the last DML inside the existing savepoint

`BovSubmissionService.replaceSelectedBroker` already wrapped its submission-swap and parent-stamp
writes in one `Savepoint`. This tranche adds the `BOV_Broker_Change__c` insert as a **fourth** write
(the class header was corrected from "1 SOQL + 2 DML" to "1 SOQL + 3 DML" in the same change) and
places it **last**, still inside the same savepoint: "a history row recording a replacement that then
failed is worse than no history at all." Being last means the row can only be created once the
submission swap and the parent stamp have already succeeded; being inside the savepoint means a failure
on the history insert itself (for example, a broker Contact that has since moved off the `Broker`
record type, refused by the same lookup filter discussed above) rolls back the whole replacement rather
than leaving a partial swap with no record of it.

### The broker firm is snapshotted as text alongside the Contact lookup

`BOV_Broker_Change__c.Outgoing_Broker_Firm__c` / `Incoming_Broker_Firm__c` are Text(255) fields
stamped at write time from the submission's already-derived `Broker_Firm__c`, not left to be read
later off the `Outgoing_Broker__c` / `Incoming_Broker__c` lookups. Both lookups are
`deleteConstraint SetNull`, and `scripts/seed-broker-contacts.apex` mass-deletes every broker Contact
in the org — so a lookup can go blank with no error at all. A history row whose broker column reads
blank at that point is not history; the Text snapshot is what survives the Contact's deletion.

### The Deal Summary distinguishes "unreadable" from "empty"

`DispositionDealSummaryService` gives each of its three data rows (NDA, LOI, PSA) — actually four
independent reads, since the NDA row is fed by two objects with independent FLS — its own narrow
`try/catch`, following the precedent `BovController.readNdaStatusFailSoft` already set. But it
deliberately diverges from that precedent in one respect: `BovController`'s fail-soft catch returns
`null` for both "no NDA exists" and "the read failed," and the caller renders both as "No NDA" —
documented there as intentionally indistinguishable. `DispositionDealSummaryService` does **not** copy
that half, because the design doc's own discovery work found the BOV pill had likely been rendering
"No NDA" for every disposition persona for months, because `NDA__c.Disposition__c` was never granted
to either disposition permission set and `WITH USER_MODE` enforces FLS on `WHERE` fields too — a
permissions gap that had been indistinguishable from an empty sale, for months, because a degraded row
and an empty row looked identical. Each row on the new card therefore carries its own `...Unavailable`
boolean: an empty row says "no LOI yet," a degraded row says the read failed. Same blast radius (one
row degrades, not the whole card, which is ungated and renders on all 11 stages), but the gap is now
visible to whoever can fix it.

### Deal Summary field exclusions

The LOI row shows `Stage__c`, `Offer_Price__c` and `Ball_In_Court__c` — and deliberately **not**
`LOI_Signed_Date__c` (structurally always blank on a disposition LOI, because `LOI_Signed_Status_Sync`
keys on the acquisition terminal `Stage__c = 'Signed'`, which a sale never reaches; the disposition
terminal is `Executed`) and **not** `LOI_Status__c` (no automation ever sets it, so it reads its
`Draft` default beside a `Stage__c` of `Executed`). Both exclusions are stated in the selector, the
service DTO, and the LWC header — the design doc's own words: "an unexplained omission gets fixed,"
so each exclusion is explained in place rather than left silent.

### `NdaTrigger` — the org's first `NDA__c` trigger, and why it is safe org-wide

Before this tranche, `NDA__c` had no trigger at all — every prior automation on the object was a Flow
or an external writer. `NdaTrigger` (`before insert, before update`) is new, routes to
`NdaTriggerHandler`, and calls `NdaBuyerStampService.stampBuyerName`. Because `NDA__c` is dual-module
(serves both `Acquisition_NDA` and `Disposition_NDA`), this trigger now fires on **every** NDA insert
and update in the org, acquisition NDAs included, where previously nothing fired at all. That is safe
for a single, structural reason: the stamp is **change-keyed** on `Buyer__c` — when the field did not
change (every acquisition save, every Flow re-entry, every status advance, every expiry-marker write,
and every existing `TestDataFactory` fixture, which sets `Counterparty_Name__c` directly and leaves
`Buyer__c` null), the service returns after one in-memory pass with **zero queries and zero DML**.
`Buyer__c` is granted on neither acquisition permission set, so no acquisition surface can even set it.
The class header states plainly that this is the single most reassuring measured fact about the change:
the existing 238-class test suite (reported by the tranche's own test pass; see
[Test/Verification Evidence](#-testverification-evidence)) stays green **by construction**, not by
coincidence, because every existing writer leaves `Buyer__c` untouched.

Its twin, `DispositionOfferBuyerStampService`, required expanding `DispositionOfferTrigger`'s context
list to add `before insert` (it previously declared only `before update, after update`) — its own
in-file blast-radius argument was corrected in place, matching the same correction already made to
`BovSubmissionTrigger`'s header the same day.

### Code review reconciliation: `BOV_Broker_Change__c` CRUD on the Edit permission set

The permission-set edit for the new object originally granted the Acquisitions Analyst persona
`allowCreate` / `allowEdit` on `BOV_Broker_Change__c`, with nine of its eleven fields editable, framed
as letting an admin correct a bad backfill row. A same-day code review reconciled this: the object is
written **exclusively** by `BovSubmissionService.replaceSelectedBroker` under `AccessLevel.SYSTEM_MODE`
(an automation-path write, per ARCHITECTURE.md §2), so object CRUD was never load-bearing for the
normal path — and granting `allowEdit`, particularly on `Logged_By__c` / `Entry_DateTime__c`, would let
the very analyst who replaced a broker go back and rewrite *who* did it and *when*, exactly the
"actor can suppress the audit row" shape the service's own class header names as the one thing an audit
log must never allow. `allowCreate` and `allowEdit` are now `false` on `DPEG_Disposition_Edit`; all
eleven fields are `readable=true`, `editable=false`. `DPEG_Disposition_View` needed no correction — it
shipped read-only from the start. The service's `SYSTEM_MODE` write path is unaffected by either
change, which is the entire reason the feature keeps working with zero create/edit grants on the object.

### A live FlexiPage deploy defect, caught by dry-run before it shipped

Placing `dispositionDealSummary` on the record page's `sidebar` region was first attempted with an
explicit `<componentInstanceProperties><name>recordId</name><value>{!recordId}</value></...>` block —
the shape that looks obviously correct. A check-only dry-run against the byte-identical (then-live)
copy of the FlexiPage reported `"state": "Unchanged"` and **skipped validation entirely**, so that
original binding was never actually checked. Once the surrounding edit made the file differ from the
live copy, the same binding failed with `"Field recordId does not exist. Check spelling."` The fix —
proven correct by the fact that `dispositionSidebar`, `bovBrokerChangeHistory` and
`dispositionBuyerTimeline` all already deploy clean the same way — is to **omit the
`componentInstanceProperties` block for `recordId` entirely**. `recordId` is a `lightning__RecordPage`
implicit input; the component's own `@api recordId` receives it automatically from the platform with
no FlexiPage-side declaration required. An explicit-but-empty property registers a binding and
overrides that implicit injection with nothing, which is what actually broke the card.
⚠ `dispositionMain`, elsewhere on the same page, carries the identical empty-valued `recordId` block
and was **not** touched by this fix — flagged in the FlexiPage's own comment as a likely sibling defect
worth a follow-up sweep, not fixed here.

---

## 🧱 Components

### Custom Objects (1 new)

| Object API Name | Label | Description |
|---|---|---|
| `BOV_Broker_Change__c` | BOV Broker Change | Append-only history of BOV broker replacements on a disposition, one row per swap. `sharingModel`/`externalSharingModel` Private, `enableHistory` false, AutoNumber name `BBC-{0000}`, settings copied from `BOV_Submission__c`. |

### Custom Fields

**`BOV_Broker_Change__c` (11 new)**

| Field API Name | Type | Notes |
|---|---|---|
| `Disposition__c` | Lookup → `Disposition__c` | The anchor. Relationship `BOV_Broker_Changes`. |
| `Outgoing_BOV_Submission__c` / `Incoming_BOV_Submission__c` | Lookup → `BOV_Submission__c` | Two lookups to one object; distinct names required by convention. |
| `Outgoing_Broker__c` / `Incoming_Broker__c` | Lookup → `Contact` | Role-named. **Active, non-optional** lookup filter, `Contact.RecordType.DeveloperName = 'Broker'` (see [broker lookup filter defect](#the-broker-lookup-filter-defect--the-most-important-finding-in-this-tranche)). |
| `Outgoing_Broker_Firm__c` / `Incoming_Broker_Firm__c` | Text(255) | Snapshots stamped at write time — survive the Contact's later deletion. Never hand-typed. |
| `Reason__c` | Picklist, **restricted** | 🔴 **PROVISIONAL — not yet confirmed by the user.** Values: `Performance Issue`, `Better BOV Received`, `Broker Withdrew`, `Company Decision`, `Other`. |
| `Notes__c` | Long Text Area(32768) | Free text, mirrors `Broker_Assignment__c.Replacement_Notes__c`. |
| `Entry_DateTime__c` | DateTime | The write time — no separate effective-date parameter exists (deliberate; see the service's own header). |
| `Logged_By__c` | Lookup → `User` | The actor, stamped from `UserInfo.getUserId()`. |

**`NDA__c` (2 new)**

| Field | Type | Notes |
|---|---|---|
| `Buyer__c` | Lookup → `Contact`, **unfiltered** (no `Is_Buyer__c` gate — deliberate; a buyer is deal-scoped, not a durable role) | Role-named. Derives `Counterparty_Name__c` via `NdaBuyerStampService`, change-keyed, truncated to 120 chars. |
| `Materials_Released_Date__c` | Date | Analyst-entered **and** blank-only defaulted on entry to `Release Materials` by `DispositionStageEntryService.stampMaterialsReleasedDates`. |

**`Disposition_Offer__c` (1 new)**

| Field | Type | Notes |
|---|---|---|
| `Buyer__c` | Lookup → `Contact`, unfiltered | Derives `Buyer_Name__c` (Text 255, no truncation needed) via `DispositionOfferBuyerStampService`. |

### Validation Rules (7 new — Workstream A)

| Object | Rule | Semantics |
|---|---|---|
| `BOV_Submission__c` | `Broker_Required_On_Submission` | `ISBLANK(Broker__c)` — a VR, not `required=true`, because a required lookup cannot carry `deleteConstraint SetNull`. |
| `BOV_Submission__c` | `BOV_Amount_Required_On_Submission` | Platform `required=true` on `BOV_Amount__c`. |
| `Disposition_Offer__c` | `Buyer_Required_On_Offer` | `ISBLANK(Buyer_Name__c)` — targets the legacy text field; not yet amended to the `Buyer__c` lookup (design's tranche 2.5 amendment). |
| `Disposition_Offer__c` | `Offer_Amount_Required_On_Offer` | Platform `required=true` on `Offer_Amount__c`. |
| `Disposition_Offer__c` | `Buyer_Counter_Price_Is_Positive`, `DPEG_Counter_Price_Is_Positive` | Counter prices must be `> 0` when present; blank is legitimate. |
| `Disposition_Offer__c` | `Closing_Period_Days_Not_Negative`, `Due_Diligence_Days_Not_Negative` | Term-day fields must be `>= 0`. |

Two further sanity rules from the design doc (`LOI__c` counter-price/term-day/execution-price rules,
`Contract_Review__c.Execution_Date_Not_In_Future`) are specified in the requirements doc but were not
found deployed under `objects/LOI__c/validationRules/` or `objects/Contract_Review__c/validationRules/`
at doc-writing time — flagged here as a gap between the design doc's A4 scope and the current repo
state rather than assumed complete.

### Apex Classes

| Class | Layer | Responsibility |
|---|---|---|
| `DispositionDealSummaryService` (new) | Service | Zero-SOQL orchestration over four selector reads (NDA counters, latest NDA, latest LOI, latest PSA), each independently fail-soft. |
| `DispositionDealSummaryController` (new) | Controller | Thin `@AuraEnabled(cacheable=true)` boundary; refuses a wrong-SObject-type Id outside its own try block. |
| `BovBrokerChangeSelector` (new) | Selector | `WITH USER_MODE` read-for-display of `BOV_Broker_Change__c`, capped at 200 rows, newest first. |
| `BovBrokerChangeController` (new) | Controller | Thin wrapper over the selector. |
| `BovSubmissionService` (modified) | Service | `replaceSelectedBroker` gained `reason`/`notes` parameters and a fourth DML — the history insert, last, inside the existing savepoint, `SYSTEM_MODE`. |
| `BovController` (modified) | Controller | `replaceSelectedBroker` passthrough gained the two new parameters; three-catch structure unchanged. |
| `BovSubmissionSelectionGuard` (new) | Service | Trigger-driven guard refusing a second `Selected` `BOV_Submission__c` on one disposition; reject, not self-heal (the self-heal already lives in `replaceSelectedBroker`). |
| `DispositionOfferSelectionGuard` (new) | Service | Same shape for `Disposition_Offer__c.Is_Selected__c`. |
| `NdaTriggerHandler` (new) | Trigger Handler | Routes `before insert`/`before update` to `NdaBuyerStampService`; the first handler this object has ever had. |
| `NdaBuyerStampService` (new) | Service | Change-keyed stamp of `NDA__c.Counterparty_Name__c` from `Buyer__c`, truncated to 120 chars; clearing the lookup leaves the text unchanged (deliberate divergence from the BOV stamp precedent). |
| `DispositionOfferBuyerStampService` (new) | Service | Same shape for `Disposition_Offer__c.Buyer_Name__c` (Text 255, no truncation needed). |
| `DispositionOfferTriggerHandler` (modified) | Trigger Handler | Routes the new `before insert` context to the offer buyer stamp and the offer selection guard. |
| `DispositionBuyerTimelineService` (new) | Service | Builds one row per buyer-role NDA; the `Status__c`-gates-`Date_Signed__c` logic, negative-duration suppression, declined-last sort. Exactly 2 SOQL, 0 DML, constant regardless of buyer count. |
| `DispositionBuyerTimelineController` (new) | Controller | Thin `@AuraEnabled(cacheable=true)` boundary; a `QueryException` is **not** swallowed into an empty list — a visible error, not a confident wrong answer. |
| `DispositionStageEntryService` (modified) | Service | New private `stampMaterialsReleasedDates` — blank-only, idempotent, after-context (writes a child, not the record being saved), `SYSTEM_MODE`. |
| `NdaSelector` (modified) | Selector | +`selectLatestSummaryByDispositionId` (Deal Summary), +`selectBuyerTimelineByDispositionId` (timeline, no `LIMIT`, deliberately), +`Materials_Released_Date__c` widened into `selectByDispositionIds`. Now 9 public methods, 2 `SYSTEM_MODE`. |
| `LoiSelector`, `ContractReviewSelector` (modified) | Selector | +`selectLatestByDispositionId` each, feeding the Deal Summary's LOI/PSA rows. |
| `DispositionOfferSelector` (modified) | Selector | +`selectEarliestByBuyerIds` (one query for the whole buyer set, `ORDER BY Offer_Date__c ASC, Id ASC`) +`selectSelectedByDispositionIds` (the offer guard's one read). |
| `BovSubmissionSelector` (modified) | Selector | +`selectSelectedByDispositionIds`, the BOV guard's one read, `WITH SYSTEM_MODE`. |
| `ContactSelector` (modified) | Selector | Bulk name read reused by both new buyer stamp services. |
| `TestDataFactory` (modified) | Test support | `createBovSubmissions` now sets `Broker__c` via a shared, lazily-built `defaultBrokerContact()`; new `createBrokerContactWithFirm(firm)`; `createBovBrokerChanges` added for the new object. |

### Apex Triggers

| Trigger | Object | Events | Notes |
|---|---|---|---|
| `NdaTrigger` (new) | `NDA__c` | `before insert, before update` | **The org's first `NDA__c` trigger.** Fires on every NDA save org-wide, acquisition included; safe by construction via the change-keyed stamp (see Key Design Decisions). |
| `BovSubmissionTrigger` (modified — routing only) | `BOV_Submission__c` | `before insert, before update, after update` (unchanged) | Now also routes to `BovSubmissionSelectionGuard`. |
| `DispositionOfferTrigger` (modified — context expanded) | `Disposition_Offer__c` | `before update, after update` → **`before insert, before update, after update`** | `before insert` added to carry the offer buyer stamp and the offer selection guard. |

### Test Classes

| Test Class | Tests For |
|---|---|
| `DispositionDealSummaryServiceTest`, `DispositionDealSummaryControllerTest` | Deal Summary card (per-row fail-soft, wrong-type guard) |
| `BovBrokerChangeSelectorTest`, `BovBrokerChangeControllerTest` | Broker history read path |
| `BovSubmissionServiceTest` | `replaceSelectedBroker`'s 4-write savepoint, including the history row |
| `BovSubmissionSelectionGuardTest`, `DispositionOfferSelectionGuardTest` | Both single-Selected guards |
| `NdaBuyerStampServiceTest`, `DispositionOfferBuyerStampServiceTest` | Both buyer stamp services, including the zero-query-on-unchanged falsifier |
| `DispositionBuyerTimelineTest` | Timeline service + controller together (declined-row suppression, negative-duration flagging, legacy fallback) |
| `BrokerLookupFilterEnforcementTest` | The record-type lookup filter, with adversarial fixtures (a Broker-record-type Contact with `Is_Broker__c = false` must be accepted; an Investor-record-type Contact with `Is_Broker__c = true` must be refused) so the test cannot pass identically under the old and new predicate |

No standalone test class was found for `NdaTriggerHandler` itself; its routing is exercised indirectly
through `NdaBuyerStampServiceTest`'s trigger-driven scenarios.

### Lightning Web Components (3 new)

| Component | Placement | Notes |
|---|---|---|
| `dispositionDealSummary` | `Disposition_Record_Page` sidebar, **first item**, ungated | Imperative Apex by design (ARCHITECTURE.md §5 exception — LDS cannot express the cross-object, tie-broken "latest child of three objects" read). |
| `bovBrokerChangeHistory` | `Disposition_Record_Page` main, after `contractReviewsList`, ungated | No spinner; three states (loading/empty/unavailable), each rendered distinctly; empty state is the majority case and gets plain text, never an error banner. |
| `dispositionBuyerTimeline` | `Disposition_Record_Page` main, after `bovBrokerChangeHistory`, ungated | A read failure (`QueryException`) is surfaced as a visible error, deliberately **not** fail-soft to an empty list — an empty timeline on a sale with three engaged buyers would be a confident wrong answer nothing else on the page contradicts. |

`bovReplaceBrokerModal` was also modified (added a required `Reason__c` combobox sourced from
`getPicklistValues`/`getObjectInfo`, an optional `Notes__c` textarea) but is not new.

---

## 🔄 Data Flow

### Broker replacement → history row

```
Analyst clicks "Replace Broker" (c/bovReplaceBrokerModal, reason + notes required)
        │
        ▼
BovController.replaceSelectedBroker(dispositionId, newSubmissionId, reason, notes)
        │
        ▼
BovSubmissionService.replaceSelectedBroker
        │  Savepoint set
        │
        ├─ 1 SOQL: BovSubmissionSelector.selectStatusesByDispositionId
        │    (also the membership check — a hand-crafted call cannot promote another sale's broker)
        │
        ├─ DML 1 (SYSTEM_MODE): demote every currently-Selected sibling to Backup,
        │    clear each one's Approval_Status__c
        ├─ DML 2 (SYSTEM_MODE): promote the challenger to Selected, clear its Approval_Status__c
        ├─ DML 3 (ordinary update): stamp Disposition__c.Selected_Broker__c from the challenger's firm
        │    (throws ENTITY_IS_LOCKED if a Broker_Selection_Approval is pending — correct: the whole
        │     replacement is refused, not partially applied)
        └─ DML 4 (SYSTEM_MODE), LAST: insert BOV_Broker_Change__c
             (outgoing/incoming submission + broker + firm snapshot + reason + notes + actor + timestamp)
        │
        ▼ any DmlException
Database.rollback(beforeReplacement) — all four writes undone, platform's own lock/rule text surfaced
        │
        ▼ success
"Broker replaced. The new broker must be approved before the sale can proceed."
   (a fresh Broker_Finalize_Approval is required — the cleared Approval_Status__c is what forces it)
```

### Buyer NDA save → timeline

```
NDA__c save (any context, any module) — Buyer__c changed?
        │
        ├─ NO (the overwhelming majority) ──▶ NdaBuyerStampService returns after 1 in-memory pass,
        │                                      ZERO queries, ZERO DML
        │
        └─ YES ──▶ 1 SOQL (ContactSelector.selectNamesByIds) ──▶ Counterparty_Name__c stamped
                     (truncated to 120 chars), in-memory, before-context, no extra DML

Disposition enters "Release Materials" (afterUpdate)
        │
        ▼
DispositionStageEntryService.stampMaterialsReleasedDates
        │  1 SOQL: NdaSelector.selectByDispositionIds (buyer-role NDAs of the entering dispositions)
        │  blank-only: skip any NDA that already carries a date (analyst's own entry always wins)
        ▼
1 DML (SYSTEM_MODE): Materials_Released_Date__c = TODAY on every still-blank buyer NDA

c/dispositionBuyerTimeline renders (record page load)
        │
        ▼
DispositionBuyerTimelineController.getTimeline
        │
        ▼
DispositionBuyerTimelineService.getTimeline
        │  QUERY 1: NdaSelector.selectBuyerTimelineByDispositionId (Party_Role__c = 'Buyer' only,
        │            oldest first, NDA_Signed__c NEVER selected)
        │  QUERY 2: DispositionOfferSelector.selectEarliestByBuyerIds (whole buyer Set, one query)
        ▼
buildRow per NDA:
   Declined?  → return immediately: no dates, no durations, terminated-row treatment
   Signed?    → ndaSignedDate = Date_Signed__c   (gate first, value second)
   materialsReleasedDate = Materials_Released_Date__c
   firstOfferDate = earliest matching offer for this buyer
   daysToRelease  = span(signed, released)   — null + flagged if negative
   daysToRespond  = span(released, firstOffer) — null + flagged if negative
        ▼
Active rows (creation order) + declined rows (appended last)
```

---

## 📁 File Locations

| Component Type | Path |
|---|---|
| New object | `force-app/main/default/objects/BOV_Broker_Change__c/` (object, 11 `fields/`, `compactLayouts/`, `listViews/`) |
| New NDA/offer fields | `force-app/main/default/objects/NDA__c/fields/{Buyer__c,Materials_Released_Date__c}.field-meta.xml`; `force-app/main/default/objects/Disposition_Offer__c/fields/Buyer__c.field-meta.xml` |
| Corrected broker lookup filters | `force-app/main/default/objects/{Disposition__c,Broker_Assignment__c,Lease_Inquiry__c}/fields/Broker__c.field-meta.xml`; `force-app/main/default/objects/BOV_Broker_Change__c/fields/{Outgoing_Broker__c,Incoming_Broker__c}.field-meta.xml` |
| Validation rules | `force-app/main/default/objects/BOV_Submission__c/validationRules/{Broker_Required_On_Submission,BOV_Amount_Required_On_Submission}.validationRule-meta.xml`; `force-app/main/default/objects/Disposition_Offer__c/validationRules/{Buyer_Required_On_Offer,Offer_Amount_Required_On_Offer,Buyer_Counter_Price_Is_Positive,DPEG_Counter_Price_Is_Positive,Closing_Period_Days_Not_Negative,Due_Diligence_Days_Not_Negative}.validationRule-meta.xml` |
| `NDA_Signed__c` latch fix | `force-app/main/default/flows/NDA_Signed_Status_Sync.flow-meta.xml`; `force-app/main/default/pathAssistants/NDA_Path_Disposition.pathAssistant-meta.xml`; `force-app/main/default/objects/NDA__c/fields/{Is_Decline_Allowed__c,NDA_Signed__c}.field-meta.xml` |
| Permission sets | `force-app/main/default/permissionsets/{DPEG_Disposition_Edit,DPEG_Disposition_View}.permissionset-meta.xml` |
| FlexiPage | `force-app/main/default/flexipages/Disposition_Record_Page.flexipage-meta.xml` |
| Sharing rule (new object) | `force-app/main/default/objects/BOV_Broker_Change__c/sharingRules-meta.xml` equivalent — modelled on `sharingRules/BOV_Submission__c.sharingRules-meta.xml` |
| Apex — Deal Summary | `force-app/main/default/classes/{DispositionDealSummaryService,DispositionDealSummaryController}.cls` |
| Apex — Broker history | `force-app/main/default/classes/{BovBrokerChangeSelector,BovBrokerChangeController,BovSubmissionService,BovController}.cls` |
| Apex — Single-Selected guards | `force-app/main/default/classes/{BovSubmissionSelectionGuard,DispositionOfferSelectionGuard}.cls` |
| Apex — Buyer stamps + trigger | `force-app/main/default/classes/{NdaTriggerHandler,NdaBuyerStampService,DispositionOfferBuyerStampService,ContactSelector}.cls`; `force-app/main/default/triggers/{NdaTrigger,DispositionOfferTrigger}.trigger` |
| Apex — Buyer timeline | `force-app/main/default/classes/{DispositionBuyerTimelineService,DispositionBuyerTimelineController,DispositionStageEntryService,NdaSelector,DispositionOfferSelector,LoiSelector,ContractReviewSelector}.cls` |
| Test classes | `force-app/main/default/classes/{DispositionDealSummaryServiceTest,DispositionDealSummaryControllerTest,BovBrokerChangeSelectorTest,BovBrokerChangeControllerTest,BovSubmissionServiceTest,BovSubmissionSelectionGuardTest,DispositionOfferSelectionGuardTest,NdaBuyerStampServiceTest,DispositionOfferBuyerStampServiceTest,DispositionBuyerTimelineTest,BrokerLookupFilterEnforcementTest}.cls` |
| LWC | `force-app/main/default/lwc/{dispositionDealSummary,bovBrokerChangeHistory,dispositionBuyerTimeline,bovReplaceBrokerModal}/` |
| TestDataFactory | `force-app/main/default/classes/TestDataFactory.cls` |
| Seed scripts (in-tree, uncommitted per repo git status) | `scripts/{seed-disposition-bulk,seed-disposition-offers,seed-sell-meter,seed-sell-readiness}.apex` |
| Design source | `agent-output/disposition-tranche-2-requirements.md` |

---

## 🚨 Operations — Read Before Deploying or Running Anything

### 1. Deploy order

1. **Object/field metadata first** — Apex referencing a new field will not compile, and a layout
   referencing a field that does not exist will not deploy, until the schema lands.
2. **Permission sets before or with the Apex** — every new/widened field arrives with **no FLS for
   anyone, System Administrator included**. A `USER_MODE` selector widened before its grant lands
   red-banners the feature. Diff every permission-set edit against `HEAD` first — a `PermissionSet`
   deploy replaces the file's entire `fieldPermissions` set.
3. **Layouts.**
4. **Apex** (selector → service → controller → trigger/handler).
5. **LWC.**
6. **FlexiPage last, and read it back.** A FlexiPage deploy can roll back on a design-time error and
   still report success. This tranche's own dry-run already caught one binding defect this way (see
   Key Design Decisions) — the same discipline applies to the live deploy.
7. **Sharing rules one at a time**, on their own, after everything else — a batch rolls all of them
   back. `BOV_Broker_Change__c`'s sharing rule must not be deployed alongside any other sharing rule
   file.

### 2. Dry-run "Unchanged" components skip validation entirely

🔴 A check-only deploy **skips validation** for any component byte-identical to what is live
(`"state": "Unchanged"`), and a comment-only edit does not count as a change. This bit the FlexiPage
`recordId` binding directly in this tranche (see Key Design Decisions) — check per-component `state`
in the dry-run output, not just the top-level status, on every file in this payload.

### 3. Still open — do not ship without resolving

- **`BOV_Broker_Change__c.Reason__c`'s restricted picklist values are unconfirmed by the user.** The
  five shipped values (`Performance Issue`, `Better BOV Received`, `Broker Withdrew`,
  `Company Decision`, `Other`) are a proposed default only, and `TestDataFactory`'s new
  `createBovBrokerChanges` fixture now hard-codes one of them — a later relabel or value change will
  fail that fixture, not merely require a report update.
- **`NDA_Signed_Rollup` may not be maintaining `Disposition__c.NDA_Count__c` /
  `Signed_NDA_Count__c` — flagged for observation, not confirmed broken.** That after-save Flow runs
  `SystemModeWithoutSharing` with a fault connector that converts a failed parent update into a stale
  count rather than a visible error, so a failure there is silent by design. These same counters feed
  `All_NDAs_Signed_Before_Progression`, which gates every forward stage from NDA onward, and now also
  feed the Deal Summary card's NDA row. This could not be reproduced or disproven while writing this
  document — the org currently holds one disposition with zero NDAs, which is not enough data to test
  the rollup against. Worth a live check before this card goes in front of a driver.
- **`SmartFillEnrich` was removed from three layouts in an earlier change and will reappear on the
  next retrieve.** It originated from a retrieve of this same org, which then rejects it on deploy.
  This is a known, standing limitation, not something this tranche fixes permanently — re-strip it
  after any future retrieve that touches these layouts.
- **The two remaining Workstream A4 sanity rules named in the design doc** (`LOI__c`
  counter-price/term-day/execution-price rules and `Contract_Review__c.Execution_Date_Not_In_Future`)
  were not found on disk at doc-writing time — confirm whether they are intentionally deferred or
  simply not yet built before treating Workstream A as complete.

---

## 🧪 Test/Verification Evidence

This documentation agent has no test-execution tooling (file-read/write/search only); nothing below is
independently re-run here. The class and metadata inventory above **is** independently verified by
reading the files directly — every class, field, permission-set grant and FlexiPage placement quoted
in this document was read from the current repo state, not paraphrased from the design doc.

No standalone code-review report file exists under `agent-output/` for this tranche (unlike, for
example, `docs/2026-07-24-broker-protection.md`'s companion review doc). The findings referenced
throughout this document — the broker lookup filter reconciliation, the `BOV_Broker_Change__c`
permission-set CRUD correction, the FlexiPage `recordId` binding fix — are recorded directly in the
affected classes' and metadata files' own header comments, quoted from directly above.

**Bulk-test-rule applicability**, per each class's own header and `.claude/rules/bulk-test-rule.md`:

| Class | 251-record mandate | Why |
|---|---|---|
| `BovSubmissionSelectionGuard`, `DispositionOfferSelectionGuard` | ✅ Applies in full | Trigger-driven, loops over `Trigger.new`. |
| `NdaBuyerStampService`, `DispositionOfferBuyerStampService` | ✅ Applies in full | Trigger-driven; the required falsifier is a 251-row "unchanged lookup ⇒ zero queries" test, captured via an in-context query counter, not `Limits.getQueries()` after `Test.stopTest()`. |
| `BovSubmissionService.replaceSelectedBroker` | ❌ Exempt | Per-transaction-singleton `@AuraEnabled` operation, one disposition per click, no loop — restated in the test class header so review does not re-demand 251. |
| `DispositionDealSummaryController`/`Service`, `DispositionBuyerTimelineController`/`Service`, `BovBrokerChangeController` | ❌ Exempt (volume) | Read-only, one record per call — but each header calls for a **constant query-budget** assertion instead (Deal Summary: 4 fixed `LIMIT 1` calls; Timeline: exactly 2 queries regardless of buyer count). |

🔴 **Two of the most valuable tests in this tranche cannot pass until the schema deploys**, per the
design doc's own test-requirements section: the 251-record "unchanged ⇒ zero queries" falsifiers for
both new stamp services, and the guard tests that prove `replaceSelectedBroker` / `selectOffer` still
succeed under the new single-Selected guards. **Re-run `RunLocalTests` immediately after the live
deploy** — this document does not claim any of these have passed against a real org.

Coverage target remains 90%+ per class (ARCHITECTURE.md §2); no coverage percentages are reported for
this tranche's classes in this document, for the same no-test-execution-tooling reason stated above.

---

## 🔒 Security

- Every new Service/Selector/Controller class declares `with sharing`.
- Both buyer stamp services (`NdaBuyerStampService`, `DispositionOfferBuyerStampService`) and both
  single-Selected guards use `WITH SYSTEM_MODE` on their one selector read each, justified at the
  method's own declaration per ARCHITECTURE.md §2's automation-path exception — none of these four
  reads is one a human explicitly asked for.
- `DispositionDealSummaryService`, `DispositionBuyerTimelineService` and `BovBrokerChangeSelector` all
  read `WITH USER_MODE` — every one is a display a human opened the record page to see. The Deal
  Summary and history reads fail soft per row/card on an FLS gap; the buyer timeline deliberately does
  **not** fail soft, surfacing a `QueryException` as a visible error instead, because an empty timeline
  on a sale with real buyers is a confident wrong answer nothing else on the page contradicts.
- `BovSubmissionService.replaceSelectedBroker`'s two guarded-object writes (submission swap, history
  insert) use `AccessLevel.SYSTEM_MODE` — both fields/objects involved are 2026-08-20-vintage and
  arrive with no FLS for anyone; the parent `Disposition__c.Selected_Broker__c` stamp stays an
  ordinary `update`, deliberately, so a locked (pending-approval) disposition still refuses the whole
  replacement.
- `BOV_Broker_Change__c` object CRUD on `DPEG_Disposition_Edit` is `allowCreate=false`,
  `allowEdit=false`, `allowDelete=false`, `allowRead=true` (corrected by code review — see Key Design
  Decisions); `DPEG_Disposition_View` is read-only. The object is written exclusively by
  `BovSubmissionService.replaceSelectedBroker` under `SYSTEM_MODE`.
- The five broker Contact lookups (three pre-existing, two new on `BOV_Broker_Change__c`) now all
  enforce the same active, non-optional `Contact.RecordType.DeveloperName = 'Broker'` filter —
  previously three of the five silently enforced a filter matching zero live rows.

---

## 🏛️ ARCHITECTURE.md Update

Not touched by this tranche. Every new class follows the existing Service/Selector/Domain/
Trigger-Handler split already documented in ARCHITECTURE.md §2 — `NdaTriggerHandler` and
`DispositionOfferTriggerHandler`'s expanded context are new *instances* of the existing
trigger-handler pattern, not a new pattern. The two new `SYSTEM_MODE` selector methods
(`selectSelectedByDispositionIds` on both `BovSubmissionSelector` and `DispositionOfferSelector`) and
the two new automation-path stamp services reuse the automation-path exception ARCHITECTURE.md §2
already defines, rather than introducing a new justification shape. No new object introduces a new
external integration boundary, and no new Named Credential or ASB/Plaid/Yardi touchpoint is part of
this tranche.

---

## 📝 Notes & Considerations

### Known limitations / accepted residuals

- **A buyer Contact rename never re-stamps.** Both stamp services key on `Buyer__c` *changing*, so
  editing the linked Contact's own `FirstName`/`LastName` fires neither trigger at all — the NDA/offer
  row was not touched — and leaves `Counterparty_Name__c` / `Buyer_Name__c` stale until the next save
  that actually changes the lookup. No mitigation exists today; named here so it is not rediscovered
  as a bug.
- **Clearing `Buyer__c` does not blank the derived text field, on either object** — a deliberate
  divergence from the pre-existing `BovSubmissionBrokerStampService` precedent (which does blank on
  clear). The accepted consequence: an NDA/offer whose buyer lookup was cleared keeps displaying the
  last stamped name, indistinguishable from a legacy row.
- **Legacy rows (created before `Buyer__c` existed) never appear correctly in the "first offer"
  column** — their buyer name falls back to the typed `Counterparty_Name__c` / `Buyer_Name__c`, but
  with no Contact Id there is nothing to match an offer against, so their response duration is
  permanently `—`. No backfill is in scope or planned.
- **A negative-arithmetic date (materials released before signed, or an offer pre-dating the release)
  renders as `—` with an `hasDateAnomaly` flag**, never as a negative number — the analyst is told the
  dates disagree, not shown a nonsensical duration.

### Dependencies

- `DispositionActionPermissionService` / `Disposition_Deal_Actions` (pre-existing, Tranche 3A) gates
  `BovSubmissionService.replaceSelectedBroker` — unchanged by this tranche.
- `NdaSelector.selectBuyerTimelineByDispositionId`'s `Buyer__r.Name` traversal depends on the running
  user's permission-set **group** also carrying `DPEG_Contact_View` / `DPEG_Contact_Edit` — a
  cross-permission-set-group coupling, not a self-contained grant on the disposition sets alone.
  Verified present in both `DPEG_Principal_PSG` and `DPEG_Junior_Analyst_PSG` as of 2026-08-20.
- `scripts/seed-broker-contacts.apex` remains the single largest live hazard to every broker Contact
  lookup discussed in this document (five fields, `SetNull` on all five) — its guard against running
  against an org holding real disposition data is described in the field-level XML comments as still
  **open** as of this tranche.

---

## 📜 Change History

| Date | Author | Change Description |
|---|---|---|
| 2026-08-20 | Documentation Agent | Initial creation — documents Disposition Tranche 2 (Deal Summary card, broker replacement history, buyer activity timeline, plus the Workstream A validations they depend on) as built in the working tree, including the broker lookup filter defect discovered and fixed the same day, the code-review reconciliation on `BOV_Broker_Change__c`'s permission-set CRUD, and the FlexiPage `recordId` binding defect caught by dry-run before deployment. |
