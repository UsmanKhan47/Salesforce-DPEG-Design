# Disposition BA Gap Closure — TRANCHE 4 Design (BOV scoring, broker selection, Brokers Console)

**Date:** 2026-09-01
**Agent:** salesforce-design (analysis only — no metadata, no Apex, no org writes)
**Branch at time of writing:** `qa/lifecycle-simulation-2026-08-27`
**Scope:** exactly the five numbered items in the request. Nothing added, nothing expanded.
**Sources read, in the order requested:** `agent-output/disposition-ba-stories-gap-analysis.md`
(including the USER-CONFIRMED resolutions A1-A4 / B1-B3 / C1 / D1-D4 / E1-E4, the Gate 1 (T1)
record D-1…D-13, and the OPEN VERIFICATION DEBT section — all treated as settled);
`agent-output/disposition-gap-closure-t1-design.md` (DEPLOYED `0Afiw000000UCLVCA4`),
`-t2-design.md` (DEPLOYED `0Afiw000000UJwTCAW`), `-t3-design.md` (validated, pending deploy);
`docs/2026-08-19-disposition-flow-redesign.md`, `docs/2026-08-20-disposition-tranche-2.md`;
`ARCHITECTURE.md`, `CLAUDE.md`, `.claude/rules/*.md`.

**Output file:** this file. `agent-output/design-requirements.md` was NOT written, as instructed.

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
Grep). There is no `sf` CLI and no Salesforce MCP here. Everything below labelled "measured" was
measured **in the repo**, and is never presented as an org measurement. Every question that can only
be answered against `usman-dpeg` is escalated in §5.1 as a gate with the exact query, and none is
guessed.

**Consequence carried into the plan:** any behaviour not already exercised in this repo is a
**blocking gate with a one-item dry-run and a readback**, never an assumption. Two qualify here —
**G-3** (the compiled-formula budget of the re-weighted `BOV_Score__c`) and **G-5** (an
`Opportunity` object grant that may be defeated by record-level sharing, which no permission-set
file can tell you).

---

## 1. Premise verification — measured against the repo before designing

Thirty-one load-bearing claims were checked. **Eight hold as stated. Twenty-three findings below are
new, incomplete or wrong in the request in a way that changes the design.** They lead, because they
drive every recommendation that follows.

🔴 **The single most important one: ITEM 2 IS ALREADY BUILT AND SHIPPED. Both halves of it —
the 3-response threshold AND the "Matrix Generated ✓" badge — exist in the repo today, are pinned
by two Jest tests, and are rendered on the BOV Outreach stage.** The request and the gap analysis
(story 19) both state that neither exists. See P-1.

### 1.1 CONFIRMED

| Claim | Evidence |
|---|---|
| `Is_Buyer_Ready__c` / `Is_Known_Performer__c` exist, are Checkboxes, are INERT (no formula, flow or Apex reads them) | both field files present, each with a T1 header block titled "TRANCHE-4 IMPLICATION" |
| Their FLS shipped in T1 — read in `DPEG_Disposition_View`, read+**edit** in `DPEG_Disposition_Edit` | `DPEG_Disposition_View:1562-1571`, `DPEG_Disposition_Edit:2385-2388`. **No FLS work for item 1.** |
| `BOV_Score__c` is 50 value + 25 commission (inverse) + 25 speed, and `Hist_Success_Rate__c` is not in it | `BOV_Score__c.field-meta.xml:32-42` |
| `BovAutoSelectionService` auto-selects the top scorer and recomputes on every ranking-affecting save | `BovAutoSelectionService.reselect` change keys; `planFor` PASS B |
| The `BOV_Score__c` null guard is load-bearing (`ISBLANK` → null, `BlankAsBlank`) and depends on `ORDER BY BOV_Score__c DESC NULLS LAST` | field header; `BovSubmissionSelector:181`; `planFor`'s `scoredWinner == null` branch |
| ✅ **`Disposition__c.Responses_Received__c` NOW HAS A REAL WRITER** — as the request asks me to confirm | `DispositionCounterRollupService` via `BovSubmissionSelector.countByDispositionIds`, routed from `BovSubmissionTriggerHandler` on after insert / update / delete / **undelete** (T1 item 7, D-5/D-9). FLS was flipped to **read-only in both sets** in the same pass (`DPEG_Disposition_Edit:1618-1622`, `:2405-2410`). It is no longer hand-typed. |
| `brokersList`'s six columns match the AC exactly and nothing is sortable or filterable | `brokersList.js:27-34` — no `sortable`, no `onsort`, no filter control in the template |
| `BovSubmissionService.replaceSelectedBroker` promotes a Backup, sets `Is_Manually_Appointed__c`, and writes a full `BOV_Broker_Change__c` audit row | class header, "four writes that must not come apart" |

### 1.2 🔴 TWENTY-THREE FINDINGS THAT CHANGE THE DESIGN

---

**P-1. 🔴 ITEM 2 IS ALREADY BUILT — BOTH THE THRESHOLD AND THE BADGE. THE REQUEST AND THE GAP
ANALYSIS ARE BOTH WRONG ABOUT IT.**

`BovController.getOutreachSummary:154`:

```apex
s.matrixGenerated = s.responsesReceived >= 3;
```

`OutreachSummary` carries `@AuraEnabled public Boolean matrixGenerated` (`:73`). And
`bovOutreach.html:12-14`:

```html
<template if:true={summary.matrixGenerated}>
    <span class="matrix-badge"><span class="badge-dot"></span>Matrix Generated ✓</span>
</template>
```

Pinned by two Jest tests — `bovOutreach.test.js:76` ("renders the asset title, **matrix badge** and
four stat cards", asserting `.matrix-badge` is not null) and `:98` ("hides the matrix badge when the
matrix is not generated", emitting `matrixGenerated: false` and asserting it is null).

`c-bov-outreach` renders at exactly one place — `dispositionSidebar.html:8-10`, gated
`if:true={isBovOutreach}` — i.e. on the same stage, on the same page, in the sidebar beside the
matrix. **The threshold is 3, the number is the counter, the badge string is verbatim the AC's, and
the surface is the BOV Outreach screen.**

⇒ Item 2 is not a build. It is a **confirmation plus one alignment decision** (P-2). This is by far
the largest correction in this document and it removes an entire item from the tranche.

---

**P-2. 🔴 BUT THE BADGE AND THE MATRIX COUNT DIFFERENT POPULATIONS, AND THAT IS THE ONLY REAL WORK
LEFT IN ITEM 2.**

- `matrixGenerated` derives from `Disposition__c.Responses_Received__c`, which
  `BovSubmissionSelector.countByDispositionIds` computes over **every child row regardless of
  status** — T1 decision **D-9**, pinned by
  `countByDispositionIds_countsEveryStatus_notJustSelected`. That includes the **preferred** row.
- `bovComparisonMatrix._visible` is `(this._data || []).filter((r) => r.isPreferred !== true)` —
  it **excludes** the preferred row, and its own header says the exclusion "is a fact about the
  MATRIX … rather than a mode of it".

⇒ On a sale with two scored responses and one preferred broker, `Responses_Received__c = 3`, the
badge reads **"Matrix Generated ✓"**, and the matrix beside it renders **two rows**. Nobody can tell
from the screen why. This is the honest content of item 2. **Decision D-4.**

---

**P-3. 🔴 A `BOV_Score__c` FORMULA CHANGE RE-RANKS *READS* INSTANTLY AND DOES NOT RE-RANK
`Submission_Status__c` AT ALL. THE DIVERGENCE IS PERMANENT UNTIL AN UNRELATED SAVE.**

The request asks "say exactly what happens to existing Selected / Backup rows". The answer is not
"they re-rank" and it is not "nothing happens":

- `BOV_Score__c` is a formula, so **every read of it changes the moment the deploy lands** — the
  matrix, the Replace Broker picker labels (`c/utils brokerOptionLabel` names the score), the
  `BOV_Tracker` report, `ORDER BY BOV_Score__c DESC`.
- `Submission_Status__c` is **stored**. `BovAutoSelectionService` runs only from a trigger, and its
  update path (`reselect`) qualifies a parent only when one of six keys changed:
  `BOV_Amount__c`, `Commission_Rate__c`, `Days_To_Market__c`, `Submission_Status__c`,
  `Is_Preferred_Broker__c`, `Approval_Pending__c` — **or on insert / delete / a
  `Property_Asset__c.Target_Sale_Price__c` change.** A formula deploy is none of those. Even a
  no-op re-save of a BOV row does **not** qualify.

⇒ Immediately after deploy, an unlocked sale shows a **new top scorer with the old "Selected"
pill**, indefinitely. That is the exact "green deploy, UAT reports it doesn't work" shape
`BovAutoSelectionService`'s own header warns about for the missing parent hook. **Decision D-3**
covers whether to accept it or run a backfill, and names the in-contract backfill entry point.

---

**P-4. ✅ A MANUALLY-APPOINTED BROKER *IS* PROTECTED — AND THE LOCK IS WIDER THAN THE REQUEST
ASSUMES: IT IS PER-DISPOSITION, NOT PER-ROW.**

`planFor` returns **no writes at all** if ANY sibling on the disposition carries
`Approval_Pending__c = true` **OR** `Approval_Status__c != null` **OR**
`Is_Manually_Appointed__c = true`. So:

| State | Effect of the re-weighting |
|---|---|
| A human used Replace Broker (`Is_Manually_Appointed__c`) | **Nothing moves.** Permanently. |
| `Broker_Finalize_Approval` pending, approved **or rejected** | **Nothing moves.** |
| Approval recalled | Lock releases, and the sale re-ranks on the next qualifying save |
| Preferred slot | **Never moves** — PASS A is score-independent by construction (a preferred row is exempt from `BOV_Amount_Required_On_Submission` and legitimately scores null) |
| Unlocked, scored, no preferred row | **The scored slot can move** — this is the only case |

⇒ The blast radius of the re-weighting is exactly: *unlocked dispositions with at least two
scoreable non-preferred responses whose ranking the new weights invert*.

---

**P-5. ✅ ITEM 1 NEEDS NO FLS CHANGE AND NO SELECTOR WIDENING — MEASURED, NOT ASSUMED.**

`BOV_Score__c`'s own header: *"formula fields compute in SYSTEM context so the FLS on
`Target_Sale_Price__c` does not gate this field."* Both new terms are **same-object Checkboxes**, so
the formula gains **zero** cross-object hops (the 15-relationship limit is untouched) and **zero**
`WITH USER_MODE` exposure. `BovSubmissionSelector.selectByDispositionId` does not need either flag
for the score to work.

⚠ It needs them only if the matrix should **display** the flags — see **D-2**.

---

**P-6. ⚠ `formulaTreatBlanksAs = BlankAsBlank` DOES NOT INTERACT WITH A CHECKBOX, BUT THE SEMANTIC
WARNING IN `Is_Buyer_Ready__c`'S HEADER SURVIVES ANYWAY AND MUST GO TO THE BA.**

That header warns: *"folding this Boolean in with BlankAsZero would make an unset flag score as an
explicit 'no', which is a different fact from 'not yet assessed'."* A Checkbox on a saved row is
never null, so no enum setting changes this — **the field is structurally incapable of expressing
"not yet assessed"**. Under any additive weighting, an analyst who has not got round to assessing a
broker penalises them exactly as much as one who assessed them and said no. That is a business
consequence, not a formula bug, and the BA must accept it. It is the argument for a **bonus-on-top**
weighting rather than a **reallocation** — and against it, see **D-1**.

---

**P-7. ⚠ `Hist_Success_Rate__c` REMAINS CAPTURED, GRANTED IN BOTH SETS, AND UNUSED — AND AFTER THIS
ITEM THAT IS A SECOND DELIBERATE OMISSION, NOT THE ORIGINAL ONE.**

The gap analysis flagged it under story 4. The request scopes item 1 to the two flags only. Leaving
it out is correct per scope, but after T4 the module will carry *three* captured broker-quality
inputs of which *two* score and one does not, with no note saying why. Report it; do not build it.

---

**P-8. 🔴 ITEM 5'S CENTRAL PREMISE IS FALSE. `DispositionTractionService` DOES **NOT** MEASURE FROM
`Broker_Listing__c.List_Date__c`. IT MEASURES FROM `Disposition__c.Listing_Date__c`.**

`DispositionTractionService.evaluateAll:559` — `evaluate(d.Listing_Date__c, offers, firstOffer)`.
`BrokerListingController.getListing:169` — `Date listingDate = bl.Disposition__r.Listing_Date__c;`.

And both files argue the choice deliberately, **naming this exact request as the thing they are
defending against**:

> `DispositionTractionService:166-172` — *"THE CLOCK IS THE PARENT'S, NOT THE LISTING'S — UNCHANGED
> BY THIS REVISION, AND IT WAS DELIBERATELY LEFT ALONE. `Disposition__c.Listing_Date__c` is the
> start of the MARKETING PERIOD, which survives a broker change; `Broker_Listing__c.List_Date__c` is
> per-broker and restarts when a second listing row opens. **Using the child's date would silently
> reset the clock the moment a broker was replaced — i.e. exactly when the clock matters most.**"*

> `BrokerListingController:164-168` — *"keying on the child would silently restart the six-week
> clock the moment a broker was replaced — which, **now that this card carries a Replace Broker
> button, is one click away rather than hypothetical**."*

⇒ "Restart the Active Listing clock" as literally written means **rewriting
`Disposition__c.Listing_Date__c`**, which reverses a decision recorded twice, in two files, in
capitals. It is a Gate 1 question and the recommendation is to refuse the literal reading. **D-9.**

---

**P-9. 🟢 AND THE REPO HAS ALREADY DESIGNED THE ANSWER. IT IS WRITTEN DOWN, IN ADVANCE, IN THE
CLASS THAT WOULD HAVE COLLIDED WITH IT.**

`DispositionStageEntryService.openBrokerListings`' header:

> *"⚠ IT IS DELIBERATELY *NOT* KEYED ON THE BROKER, and that is what keeps the broker-change history
> model reachable: `BrokerListingSelector.selectMostRecentByDispositionId` is already
> `ORDER BY CreatedDate DESC LIMIT 1`, i.e. already written as 'the current listing among several',
> **so a deliberate broker change APPENDS a second row and the card follows the new broker with no
> schema change.** Auto-create must never be the thing that appends it — a stage re-entry is not a
> broker change."*

and, on `Contact_Name__c`: *"LEFT BLANK … A human fills it, **or the future broker-change action
supplies it**."*

`BrokerListingSelector:41-45` repeats it: *"Do not narrow it to a single-row assumption."*

⇒ The intended shape of item 5 is: **`replaceSelectedBroker` appends a second `Broker_Listing__c`
with `List_Date__c = TODAY()`**, the card follows it for free, and `Disposition__c.Listing_Date__c`
— the marketing clock, the badge, the report and the KPI — is untouched. **D-9 recommends this.**

---

**P-10. 🔴 BUT APPENDING A LISTING DOES NOT, BY ITSELF, RESTART ANY NUMBER THE USER SEES. THE CARD'S
"Days on Market" COMES FROM THE PARENT.**

`BrokerListingController.ListingRow.daysOnMarket` is stamped from `t.daysOnMarket` — the traction
service's parent-clock value. Appending a listing changes `listDate` on the card and nothing else.

✅ **The broker-scoped number already exists, is already queried, and is already granted.** T1
shipped `Broker_Listing__c.Days_On_Market_Live__c` (`IF(ISBLANK(List_Date__c), null, TODAY() -
List_Date__c)`) and T1's repoint put it **into the SELECT** —
`BrokerListingSelector.selectMostRecentByDispositionId:100`. `BrokerListingController` **does not map
it to any DTO member**, so it is selected and unread today. Surfacing it costs **zero selector
change, zero query, zero FLS work.**

🔴 **And its own header forbids exactly one use of it:** *"NOTHING MAY READ THIS FORMULA TO DRIVE AN
ALERT OR ESCALATION."* Displaying it as "Days with this broker" is a display; using it to compute a
band is not. The distinction must be written into the DTO member's ApexDoc.

---

**P-11. 🔴 `replaceSelectedBroker` IS REACHABLE AT **BOV OUTREACH**, WHERE NO LISTING EXISTS — AND
CREATING ONE THERE WOULD PERMANENTLY POISON THE STAGE-ENTRY AUTO-CREATE.**

Two entry points, both markup-composed:

| Surface | Stage | File |
|---|---|---|
| `c/bovBrokerPanel` "Replace Broker" | **BOV Outreach** | `dispositionMain.html:42`, `if:true={isBovOutreach}` |
| `c/brokerListing` "Replace Broker" | **Active Listing** | `dispositionMain.html:69`, `if:true={isActiveListing}` |

`openBrokerListings`' idempotency test is *"this disposition already has a broker listing"* —
**simple presence, any listing**. So a listing created during BOV Outreach makes the Active Listing
auto-create a **permanent no-op**, leaving the sale with a listing whose `List_Date__c` predates the
listing and whose `Broker_Firm__c` was never stamped from `Selected_Broker__c`. Silent, and
unrecoverable without hand repair.

⇒ Any listing write in `replaceSelectedBroker` **must be conditional on a listing already existing**
(equivalently: on the sale having reached Active Listing). **D-10.**

---

**P-12. 🔴 THE GAP ANALYSIS ATTRIBUTES REPLACE BROKER TO THE WRONG COMPONENT. `brokerReplaceQuickAction`
IS A PROPERTY-MANAGEMENT BUNDLE ON A DIFFERENT OBJECT.**

Story 31 reads *"`brokerReplaceQuickAction` / `bovReplaceBrokerModal` → `BovSubmissionService`"*.
Measured: `lwc/brokerReplaceQuickAction` is bound to
`quickActions/Broker_Assignment__c.Replace_Broker.quickAction-meta.xml` — the **leasing broker
assignment** feature, a different object and a different service. A repo-wide grep for
`bovReplaceBrokerModal` returns no quick action at all.

⇒ **The disposition Replace Broker has no quick action.** Its only routes are the two markup tags in
P-11. Anyone implementing item 5 by editing a quick action will be editing the PM module.

---

**P-13. 🔴 A LIVE DEFECT ADJACENT TO ITEM 5, FOUND WHILE VERIFYING IT: AFTER A REPLACEMENT AT ACTIVE
LISTING, THE LISTING ROW STILL NAMES THE **OLD** BROKER.**

`Broker_Listing__c.Broker_Firm__c` is stamped **once**, at stage entry, from
`Disposition__c.Selected_Broker__c` (`openBrokerListings`). `replaceSelectedBroker` updates
`Selected_Broker__c` on the parent (write 3) and **nothing re-stamps the child**.
`BovSubmissionService`'s own header even names the propagation — *"which is the value
`Broker_Listing__c` copies on entry to Active Listing, so a stale name propagates into the listing
record and outlives the mistake"* — but only as an argument for its savepoint.

⇒ Today the Active Listing card shows the **new** broker in the Replace Broker modal and the **old**
firm in the listing row. This is independent of the clock question and is fixed for free by D-9's
append (the new row carries the new firm). Report it either way.

---

**P-14. 🔴 `brokersList` RENDERS ONLY `slice(0, 5)`. SORTING A FIVE-ROW SLICE OF A SERVER-ORDERED
TOP-5 IS ALMOST MEANINGLESS.**

`brokersList.js:85` — `this.data.brokers.slice(0, 5)`, with the comment *"Show only the top 5 (sorted
by closed volume); the rest are reachable via View All."* `count` (`:102`) reports the **full**
length, so the card already says "Brokers (19)" above five rows, and `brokersList.test.js:80` pins
exactly that.

⇒ "Sort by Broker" today would reorder five rows chosen by closed volume — it would never surface
the alphabetically-first broker. The item is only meaningful if the sort is applied **before** the
slice. **D-6.**

---

**P-15. 🔴 FOUR OF SIX `brokersList` COLUMNS BIND PRE-FORMATTED STRINGS, INCLUDING TWO THAT ARE
NUMBERS STRINGIFIED. `sortable: true` ALONE WOULD SORT THEM LEXICOGRAPHICALLY.**

| Column | `fieldName` | Value today | Naive sort result |
|---|---|---|---|
| Broker | `recordUrl` | `/lightning/r/Contact/003.../view` | by record **Id** |
| Firm | `firm` | raw string or `'—'` | correct, `'—'` sorts oddly |
| Active Listings | `activeListings` | `String(b.activeListings)` | `'1', '10', '2'` |
| Offers | `offers` | `String(b.offers)` | `'1', '10', '2'` |
| Closed Volume | `volumeLabel` | `'$10.0M'`, `'$500K'`, `'—'` | `'$10.0M' < '$2.0M'` |
| Status | `status` (custom `pill` type) | `'Active'` / `'Inactive'` | alphabetical, not rank |

This is the **exact** trap Tranche 2 measured on `sellMeterList`. The pattern to reuse is already in
the repo — `sellMeterList.js:101` `SORT_KEY` + `:266` `const field = SORT_KEY[this.sortedBy] ||
this.sortedBy;` + `:316` "Raw values for SORT_KEY. Bound to no column; rendered nowhere." — with its
own header warning that a `fieldName` missing from the map falls back to itself.

✅ **And every raw value is already in the payload.** `BrokerController.BrokerRow` carries `name`,
`firm`, `status`, `activeListings` (Integer), `offers` (Integer), `closedVolume` (Decimal).
**No Apex change is needed for item 4.**

---

**P-16. ✅ ITEM 4 NEEDS NO APEX, NO SELECTOR CHANGE AND NO PERMISSION CHANGE — VERIFIED.**

`ContactSelector.selectBrokersRankedByClosedVolume:236-245` has **no `LIMIT`** and already returns
the whole broker population with all seven `Broker_*` stat fields, `WITH USER_MODE`. The slice is
purely client-side. Sorting and filtering the full list is free.

---

**P-17. 🔴 ITEM 4 IS CROSS-MODULE IN FIVE FILES, NOT ONE. THE FULL CONSUMER LIST, MEASURED.**

| Consumer | Evidence |
|---|---|
| `flexipages/Broker_Hub.flexipage-meta.xml` | the only FlexiPage naming `brokersList` (region2) |
| `applications/Acquisition.app-meta.xml:115` | `<tabs>Broker_Hub</tabs>` |
| `applications/Disposition.app-meta.xml:64` | `<tabs>Broker_Hub</tabs>` |
| `permissionsets/DPEG_App_Acquisition:15` | grants the tab |
| `permissionsets/DPEG_App_Disposition:19` | grants the tab |
| `permissionsets/DPEG_Admin_Access:788` | grants the tab |

`brokersList.js-meta.xml` is `isExposed=true` with `lightning__AppPage` + `lightning__HomePage`
targets, so an admin may also have dropped it on a Home page in the org — **not visible from the
repo** (G-6).

⚠ **And the layout constraint is real.** `Broker_Hub` uses
`flexipage:appHomeTemplateHeaderTwoColumns`, and `brokersList` is in **region2** — a half-width
column already carrying six columns. A filter row plus sort chevrons goes into that width.

⇒ **Every acquisition user of the Broker Hub gets this change identically.** There is no way to scope
it to the Disposition app without splitting the page and the tab, which is not in scope.

---

**P-18. 🔴 ITEM 3 — THE ONLY JOINABLE "SOLD DPEG THE PROPERTY" PATH EXISTS, AND IT MEANS SOMETHING
SUBTLY DIFFERENT FROM WHAT THE STORY SAYS.**

The chain is complete and every hop is a real lookup:

```
Disposition__c.Property_Asset__c
  -> Property_Asset__c.Property__c            (Lookup -> Property__c, SetNull)
  <- Opportunity.Property__c                  (Lookup -> Property__c, relationshipName Opportunities)
     Opportunity.StageName = 'Closed Won'     (a real, used value — BrokerFirmControllerTest, BrokerCounterRecalcBatch)
     Opportunity.Broker__c                    (Lookup -> Contact, relationshipName Brokered_Opportunities)
  == BOV_Submission__c.Broker__c              (Lookup -> Contact, active RecordType='Broker' filter)
```

🔴 **But `Opportunity.Broker__c`'s own field header forbids the reading the story wants:**

> *"This is the SUBMITTING broker — the person whose email produced the Lead and who therefore holds
> the Broker Protection claim — **not the listing broker named in the OM**. Those two are frequently
> DIFFERENT people (measured on Boulevard Corners: submitting broker `usmankhan-96@hotmail.com` vs
> `Listing_Broker_Name__c` "Marco Zando"), so this field must never be conflated with
> `Listing_Broker_Name__c` / `Listing_Broker_Email__c`."*

`Listing_Broker_Name__c` and `Listing_Broker_Email__c` are **Text**, not lookups — they cannot be
joined to a Contact at all.

⇒ What the data can honestly answer is **"this broker BROUGHT DPEG this building"**, not "this broker
sold it to us". The two coincide often and not always. **D-11** puts the wording to the BA rather
than quietly labelling a submitting broker as the seller's agent.

---

**P-19. 🔴 NEITHER DISPOSITION PERMISSION SET GRANTS `Opportunity` — AND A GRANT ALONE MAY NOT BE
ENOUGH, BECAUSE OF SHARING.**

Measured in both files: `objectPermissions` exists for `Property_Asset__c` and `Property__c` (both
`allowRead=true`, `viewAllRecords=false` — granted by T1), and **there is no
`<object>Opportunity</object>` entry in either set.**

Two separate blockers, and the second is the one that kills a naive implementation:

1. **CRUD/FLS.** A `WITH USER_MODE` read of `Opportunity` from a disposition persona throws
   `System.QueryException`. Granting it is a **new cross-module authorization boundary** — the
   disposition personas would gain read on the acquisition pipeline. That is a
   `salesforce-solution-architect` decision, not an admin one.
2. 🔴 **SHARING, WHICH NO PERMISSION-SET FILE CAN ANSWER.** `viewAllRecords=false` is the shape T1
   used for `Property__c`/`Property_Asset__c`. On `Opportunity` that means the disposition analyst
   sees only Opportunities shared to them — plausibly **none**. `SYSTEM_MODE` does **not** fix this
   (ARCHITECTURE.md §2: it bypasses CRUD/FLS only). The failure direction is the worst one: the card
   renders "no prior history" — an **honest-looking wrong answer**, not an error. → **G-5**.

---

**P-20. 🔴 ITEM 3 HAS NO OFF-MARKET SURFACE TO LAND ON. `dispositionMain` HAS FOUR STAGE BRANCHES
AND "BROKER SELECTION" IS NOT ONE OF THEM.**

`dispositionMain.html` renders, in full: `isBovOutreach` → `c-bov-broker-panel`;
`isReleaseMaterials` → `c-release-materials-response-log`; `isActiveListing` → `c-broker-listing` +
`c-listing-alerts` + `c-backup-brokers`; `isClosing` → `c-wire-verification`. **There is no
`Broker Selection` branch at all.**

Story 21's approval is split by record type (T3 P-14): on-market it is
`BOV_Submission__c.Broker_Finalize_Approval` (submitted from BOV Outreach), off-market it is
`Disposition__c.Broker_Selection_Approval` at the `Broker Selection` stage. ⇒ **"visible on the
selection screen" can only be delivered on the on-market path in T4.** Building an off-market
Broker Selection card is a new surface and is out of scope. **D-13.**

---

**P-21. 🔴 `BOV_Submission__c.Broker__c` IS DELIBERATELY ABSENT FROM THE MATRIX'S READ — BUT THE
USUAL OBJECTION TO WIDENING DOES NOT BITE HERE, AND A DIFFERENT ONE DOES.**

The field's header: *"⚠ THIS FIELD IS DELIBERATELY NOT ADDED TO `BovSubmissionSelector` OR TO
`BovController`. Nothing reads it."* Confirmed: `selectByDispositionId:174-177` does not select it,
and `BovController.BovRow` has no member for it.

The repo's standing objection to widening a `USER_MODE` read is
`selectSelectedBrokerByDispositionId:298-324`, whose measured grant matrix names
**`DPEG_Admin_Access` — NO ROW AT ALL** for `BOV_Submission__c.Broker__c`.

✅ **That objection does not apply to `selectByDispositionId`**, because `DPEG_Admin_Access` carries
**zero** `BOV_Submission__c` field grants of any kind (stated at `selectByDispositionId:139-142` and
again in `Broker__c`'s own header), so that persona **already cannot run this query at all**.
Exposure is unchanged, not widened. Both disposition sets already grant `Broker__c` read.

⚠ The objection that *does* apply is the architectural one: `BovController.getSubmissions` has a
**single outer catch** that masks any failure as the generic message and blanks the whole matrix
(`:137-140`). The repo's own answer to that is the second-method + narrow-catch pattern
(`readNdaStatusFailSoft`, `DispositionOfferFormService`). **D-12.**

---

**P-22. 🔴 `BovController.getSubmissions` HAS NO FAIL-SOFT SEAM, SO ANY NEW READ ADDED INSIDE IT CAN
BLANK THE ENTIRE COMPARISON MATRIX.**

`:137-140` catches `Exception` and throws `READ_FAILURE_MESSAGE`; `bovComparisonMatrix` renders
`loadError` and `_data = []`. There is exactly one narrow-catch precedent on this class —
`readNdaStatusFailSoft` (`:247-256`), whose header states the doctrine in terms: *"Degrading one pill
is strictly better than blanking the whole card."* Item 3's Opportunity read must follow it.

---

**P-23. ⚠ THE MATRIX'S `Score` COLUMN RENDERS A HARDCODED-COLOUR PROGRESS BAR, AND THE STATUS/PILL
COLUMNS EVERYWHERE IN THIS FEATURE USE LITERAL HEX.**

`bovComparisonMatrix.js:29-32` (`#2e7d32`, `#2BAFAC`), `brokersList.js:6-12` (`#e8f5e9`, `#43A047`,
`#eef1f4`, `#94a3b8`). ARCHITECTURE.md §5 requires SLDS 2 design tokens. This is **pre-existing**
and is not a T4 item — but any *new* markup in items 3 and 4 must use `--slds-g-*` tokens, which
will make the new elements visibly inconsistent with the old ones on the same card. Name it; do not
silently uplift the existing colours (that is a `uplifting-components-to-slds2` pass, out of scope).

---

**P-24. ⚠ `c/bovComparisonMatrix`, `c/bovBrokerPanel` AND `c/bovOutreach` ARE `isExposed=false`
CHILDREN, NOT FLEXIPAGE COMPONENTS. NOTHING IN ITEMS 1-3 IS AN APP BUILDER CHANGE.**

`bovComparisonMatrix.js-meta.xml` is `<isExposed>false</isExposed>` with no targets;
`bovBrokerPanel.js-meta.xml` says why in terms: *"composed into `c/dispositionMain` in MARKUP, not
placed in App Builder … exposing it would let an admin drop a second copy of the BOV Outreach broker
workspace onto the page."* `Disposition_Record_Page`'s component list contains `dispositionMain`,
`dispositionSidebar`, `bovBrokerChangeHistory`, `dispositionApprovalTracker`,
`dispositionBuyerTimeline` — **and none of the BOV bundles**.

⇒ Items 1-3 touch **no FlexiPage**. That removes the clobber hazard from three of five items. Item 4
touches `Broker_Hub.flexipage` only if the layout has to change (it should not — see D-8).

---

**P-25. ⚠ `Disposition__c.Days_On_Market__c` AND THE `Avg_Days_on_Market` REPORT ARE DOWNSTREAM OF
THE ITEM-5 CLOCK DECISION, AND T1 ALREADY DOCUMENTED WHY THEY CANNOT BE REPOINTED.**

`Disposition__c.Days_On_Market__c` is `IF(ISBLANK(Listing_Date__c), null, TODAY() -
Listing_Date__c)`. `reports/Dispositions/Avg_Days_on_Market.report-meta.xml` is reportType
`CustomEntity$Disposition__c` and its only measure is that field —
`Days_On_Market_Live__c.field-meta.xml:87-98` records that **no Disposition-with-Broker-Listing
report type exists**, so the report cannot be moved onto the listing.

⇒ If item 5 resets `Disposition__c.Listing_Date__c` (D-9 option A), **that report and the
`Broker Alert Due` dashboard KPI change meaning with no metadata diff at all** — the
canonicalising-a-definition trap. It is the strongest single argument against option A.

---

**P-26. ⚠ `Broker_Listing__c.Listing_Status__c` HAS ONLY THREE VALUES — `On Track` / `At Risk` /
`Hard Stop` — SO THERE IS NO WAY TO MARK A SUPERSEDED LISTING "CLOSED".**

`<restricted>true</restricted>`, default `On Track`. If item 5 appends a second listing (D-9), the
old row keeps a live-looking status and the object still has **no validation rule, trigger or flow**
enforcing story 5's "exactly one active Broker Listing per On-Market sale" (gap analysis story 5).

⇒ Appending is still correct — the header at P-9 designed for it and
`selectMostRecentByDispositionId` already picks the current one — but the BA should know that the
superseded row remains visible in the related list looking active. Adding a `Superseded` value is a
restricted-picklist change and triggers the standing grep-repo-and-query-org sweep. **Out of scope;
reported.** **D-10.**

---

**P-27. 🔴 THE `Broker_Listing__c` INSERT IS THE **FOURTH** DML IN `replaceSelectedBroker`'S
SAVEPOINT, AND THE BUDGET LINE IN ITS HEADER IS A CONTRACT THAT HAS ALREADY BEEN CORRECTED ONCE.**

Header: *"1 SOQL + 3 DML"*, with an explicit ⚠ that it *"said '1 SOQL + 2 DML' until 2026-08-20 and
was corrected in the same change that added the third DML … a header that undercounts its own DML is
how a budget line stops being a contract."* Item 5 makes it **1-2 SOQL + 4 DML** (the extra SOQL only
if the "does a listing already exist" check cannot ride an existing read — it cannot;
`selectStatusesByDispositionId` reads BOV rows, not listings). The header must be corrected in the
same change, in the same style.

---

**P-28. ⚠ `Brokers_Contacted__c` IS STILL HAND-TYPED, SO THE "n of m" TILE BESIDE THE BADGE IS HALF
AUTOMATED.**

`BovControllerTest:96` — *"`Brokers_Contacted__c` is NOT trigger-owned and stays hand-set."*
`bovOutreach.js:56` renders `${responsesReceived} of ${brokersContacted}`. So "3 of 0" is reachable
and looks like a defect. Not in scope (T1 closed only the responses half); reported so the BA is not
surprised when the badge appears above a `3 of 0`.

---

**P-29. 🔴 `git status` SHOWS A CONCURRENT STREAM IN THIS WORKING TREE, INCLUDING A **DELETED**
OPPORTUNITY RECORD TYPE.**

`D force-app/main/default/objects/Opportunity/recordTypes/Commercial.recordType-meta.xml`, plus
modified `DPEG_Transaction_Edit` / `_View`, six `tabs/*`, three dashboards, nine seed scripts, and
`BrokerProtectionConfig.cls`. Item 3 designs onto `Opportunity`. **Do not start item 3 without
resolving that deletion** — this repo has a measured incident (2026-08-16) of a second session
building a whole feature into the same tree mid-run. → **G-6**.

---

**P-30. ⚠ THE `pill` CUSTOM COLUMN TYPE MARKED `sortable` IS A COMBINATION THIS REPO HAS DEPLOYED
ONCE AND NEVER SEEN RENDER.**

`lwc/listDatatable` registers `pill` and `progress` as `static customTypes`. T2 marked
`sellMeterList`'s `pill` column `sortable: true`, and the OPEN VERIFICATION DEBT section names it
explicitly: *"a custom `pill` column type now marked `sortable`, a combination never rendered
anywhere"*. Item 4's Status column is the same shape. **It inherits an open, unverified precedent —
it does not establish one.**

---

**P-31. ⚠ THREE OF THE FIVE ITEMS ARE PINNED BY JEST TESTS THAT WILL PASS VACUOUSLY OR BREAK.**

- `brokersList.test.js:80` — *"shows the full count but only the top-5 rows"*. Under D-6 (sort
  before slice) this **stays green with the default sort** and therefore proves nothing about
  sorting. A new fixture must be added where the default order and a sorted order differ.
- `bovOutreach.test.js:44` hardcodes `matrixGenerated: true` in the fixture — it pins the **badge**,
  never the **threshold**. `BovControllerTest` is where the `>= 3` boundary must be pinned (2 → false,
  3 → true), and **it is not clear that it is** (`BovControllerTest:98` sets
  `Responses_Received__c = 4`, above the boundary, and `:321` sets 2). A boundary test at exactly 3
  is the missing net for D-4.
- `BovAutoSelectionServiceTest` has **~15 query/DML-budget assertions** naming exact counts
  (`bulk251ApprovesAtConstantCost`, the `FOUR per chunk` comments at `:1345-1356`). Item 1 changes
  no counts, but item 5's fourth DML sits in `BovSubmissionServiceTest`, whose header records the
  bulk-rule exemption for that method — **that exemption reasoning must be re-stated, not silently
  inherited**, because appending a listing adds an object to the transaction.

---

## 2. Decisions for Gate 1

These are the only genuinely open questions. Each carries a recommendation and its evidence.
**Nothing here re-opens a USER-CONFIRMED resolution.**

| # | Decision | Recommendation |
|---|---|---|
| **D-1** | 🔴 **Item 1 — the weighting. The story ("weighing BOV amount against expected value plus the Buyer Ready and Known Performer flags") is not a specification. Reallocate to 100, or bonus-on-top with a cap?** | **REALLOCATE: 40 value / 20 commission / 20 speed / 10 Buyer Ready / 10 Known Performer = 100.** Arithmetic and a worked rank inversion are in §3 item 1. Rejected alternative — **bonus on top, `MIN(base + 20, 100)`** — because the cap compresses the top of the range and manufactures ties exactly among the best brokers, which is the one region where the score has to discriminate; and because `BOV_Score__c` is documented, labelled and reported as "0-100", so a formula that can exceed 100 before clamping is a second definition. ⚠ **This needs BA sign-off on the NUMBER, not just the shape.** 20 of 100 points for two hand-entered checkboxes is roughly equivalent to a **55% swing in bid price** (see §3). If that is too strong, the same shape works at 45/22.5/22.5/5/5. |
| **D-2** | **Item 1 — should the two flags be VISIBLE in the comparison matrix, so a rank is explicable?** | **YES, as two small pills or a single "Buyer Ready · Known Performer" cell.** A score that moves for a reason nobody can see on the screen is the complaint this whole tranche exists to answer. Cost: two fields added to `BovSubmissionSelector.selectByDispositionId` and two `BovRow` members. ✅ FLS is **already granted read in both disposition sets**, and `DPEG_Admin_Access` holds **zero** `BOV_Submission__c` grants so it already cannot run that query — exposure is unchanged (P-21). ⚠ If you decline, the design still works; the score simply changes for invisible reasons. Confirm. |
| **D-3** | 🔴 **Item 1 — what happens to LIVE data on deploy day (P-3): accept the read/stored divergence, or run a one-off backfill?** | **ACCEPT IT IN `usman-dpeg` (there are ZERO dispositions, so the divergence is empty), and SHIP THE BACKFILL SCRIPT UNUSED, documented, for the first org that has data.** The in-contract entry point is `BovAutoSelectionService.reselect(existingSubmissions, null)` — a **public** method whose own ApexDoc says a null `priorById` means *"Insert, or an update whose old row is unavailable: always re-rank"*, so every parent qualifies. No new public API, no hack. ⚠ It must chunk by disposition (the DML/SOQL limits are per transaction) and it will re-fire `DispositionCounterRollupService`. 🔴 It will **not** move a locked or manually-appointed sale, which is correct (P-4). Confirm you want the script written but not run. |
| **D-4** | 🔴 **Item 2 — the badge and the matrix count different populations (P-2). Align them, or accept?** | **ALIGN THE BADGE TO THE MATRIX: count NON-PREFERRED responses for `matrixGenerated`.** The badge asserts a fact about the comparison matrix, and the matrix compares scored responses; a preferred broker "usually has no numbers to compare" (`bovComparisonMatrix._visible`'s own header). One line in `BovController.getOutreachSummary` plus one selector method, or — cheaper and preferred — derive it from the payload `getSubmissions` already returns. ⚠ **REJECTED alternative: changing `Responses_Received__c` itself.** That field answers *"how many brokers came back"*, is pinned by `countByDispositionIds_countsEveryStatus_notJustSelected`, and is decision **D-9 from T1**. Do not touch it. ⚠ The "n of m" tile keeps using the all-rows counter, which is correct for it. |
| **D-5** | **Item 2 — should the comparison matrix TABLE be hidden below 3 responses, so "the system builds it at 3+" is literally true?** | **NO. Keep the table rendering from the first response; the badge is the status indicator.** Hiding it would delete the only surface showing early responses, and the card's own header states it is *"visible in EVERY state, including the two empty ones, and that is DELIBERATE"* — its error banner and the panel's Add Broker Response button are the recovery path on an empty sale. Amend the AC to "the matrix is available from the first response and is marked **Matrix Generated ✓** once three or more have been received". ⚠ If the BA insists on hiding it, say so at Gate 1 — it is a three-line change but it reverses a documented decision. |
| **D-6** | 🔴 **Item 4 — sort the FULL broker list then slice 5, or remove the slice and paginate (P-14)?** | **SORT THE FULL LIST, THEN SLICE 5.** It keeps the card's "top N + View All" idiom and the region2 width, and it makes sorting *mean* something (sort by Offers → the top five by offers). ⚠ It also changes what the card shows the moment a user sorts, which is the intended behaviour but must be described to the BA as such. Rejected alternative — a pager like `sellMeterList`'s — because it doubles the card's height in a half-width column and `View All` already exists. **Default (unsorted) order must remain closed-volume DESC**, i.e. the server order, unchanged. |
| **D-7** | **Item 4 — what does "filtered" mean? The AC does not say.** | **Two controls: a free-text search over Broker name + Firm, and a Status combobox (All / Active / Inactive).** Both client-side over the full payload, zero Apex, zero FLS. `Broker_Status__c` is already in the payload and already drives the pill. ⚠ Rejected: a Firm picklist (firms are free text and this org has duplicate/near-duplicate firm strings — `BrokerController` lower-cases and trims them just to count them) and a specialty filter (`specialty` is in the DTO but is **not a column**, so filtering on an invisible field is a UI nobody can reason about). **Confirm the filter set — this is the one place the AC is genuinely silent.** |
| **D-8** | **Item 4 — does anything change on `Broker_Hub.flexipage` or the tab?** | **NO — and that is the recommendation, not just the finding.** Keep the filter row inside the `lightning-card` body, above the datatable, so the FlexiPage and both apps are untouched. This avoids the measured 2026-08-25 App Builder clobber entirely (P-24). ⚠ But **report to the BA that the change is cross-module regardless**: the same card is the Acquisition app's Broker Hub (P-17). Confirm the acquisition team is content to receive sort + filter on that page. |
| **D-9** | 🔴 **Item 5 — THE MODELLING QUESTION. What does "restart the Active Listing clock" mean?** | **DO NOT RESET `Disposition__c.Listing_Date__c`. APPEND A NEW `Broker_Listing__c` WITH `List_Date__c = TODAY()`, AND SURFACE THE ALREADY-EXISTING `Days_On_Market_Live__c` AS A SECOND, BROKER-SCOPED NUMBER.** Three reasons, each sufficient: (1) two class headers refuse the reset in capitals and name this exact button as the hazard (P-8); (2) the reset would silently change `Disposition__c.Days_On_Market__c`, the `Avg_Days_on_Market` report and the `Broker Alert Due` KPI **with no metadata diff** (P-25); (3) the append route is **already designed for, in writing, in the class that would have collided with it**, and needs no schema change (P-9). ⚠ **The honest statement to the BA:** Days-on-Market is two facts — *how long has this property been on the market* (a market fact, survives a broker change) and *how long has THIS broker had it* (a performance fact, restarts). The AC conflates them. This design gives both, side by side, and the escalation ladder stays on the market clock. **Rejected alternative A (reset the parent):** destroys the market fact and reverses two recorded decisions. **Rejected alternative B (do nothing, amend the AC):** leaves broker performance unmeasurable, which is the story's actual point. |
| **D-10** | 🔴 **Item 5 — when is the new listing row created, given Replace Broker also fires at BOV Outreach (P-11)?** | **ONLY WHEN A `Broker_Listing__c` ALREADY EXISTS FOR THE DISPOSITION.** That is exactly equivalent to "the sale has reached Active Listing", it needs no stage read, and it is the single condition that keeps `openBrokerListings`' presence-based idempotency guard intact. A replacement at BOV Outreach therefore writes no listing — correct, because the marketing period has not started. ⚠ Say the residual out loud: the **superseded** listing row keeps a live-looking `Listing_Status__c` (only `On Track`/`At Risk`/`Hard Stop` exist — P-26), and story 5's "exactly one active listing" is still unenforced. Adding a `Superseded` value is a restricted-picklist change that triggers the standing repo-grep + org-query sweep. **Out of T4; confirm you accept the visible extra row.** |
| **D-11** | 🔴 **Item 3 — the semantics. `Opportunity.Broker__c` is the SUBMITTING broker, explicitly not the listing broker (P-18). Is "this broker brought DPEG this building" the fact the BA wants?** | **PUT IT TO THE BA BEFORE BUILDING, AND LABEL THE UI WITH WHAT THE DATA ACTUALLY SAYS.** Recommended label: **"Brought us this building — DEAL-0042, closed 12 Mar 2024"**, never "sold us". The alternative reading (the seller's listing broker) lives in `Listing_Broker_Name__c` / `Listing_Broker_Email__c`, which are **Text and cannot be joined to a Contact at all** — matching on a name string would be a new fuzzy-match surface and is not proposed. ⚠ If the BA means the listing broker, **item 3 is not buildable on this data model** and should be deferred with that stated. |
| **D-12** | 🔴 **Item 3 — where does the read live, and how does it fail?** | **A NEW `BrokerSaleHistoryService` + a new `OpportunitySelector` method, read from a SEPARATE `@AuraEnabled` method, NOT folded into `BovController.getSubmissions`.** `getSubmissions` has one outer catch that blanks the entire comparison matrix (P-22); the repo's own doctrine on this class is *"degrading one pill is strictly better than blanking the whole card"*. A second cacheable method keyed on `dispositionId` returns a `Set<Id>` of broker Contacts with prior closed acquisitions on this asset's property, the client decorates matching rows, and any failure degrades to **no decoration**. ⚠ The new controller **needs a `classAccesses` entry on `DPEG_Apex_Access`** — T3 shipped a controller without one and the deploy was green while the component was dead for every non-admin. |
| **D-13** | 🔴 **Item 3 — on-market only, or build an off-market surface too (P-20)?** | **ON-MARKET ONLY.** `dispositionMain` has no `Broker Selection` branch, so off-market has no selection screen to decorate. Building one is a new card, a new stage branch and a new set of Jest pins — well outside "make history visible". **Report the asymmetry to the BA explicitly**: after T4 an on-market principal sees prior-deal history when choosing a broker and an off-market one does not. |
| **D-14** | 🔴 **Item 3 — the `Opportunity` access decision (P-19). Grant it, or refuse the item?** | **BLOCKED ON G-5, AND DO NOT GRANT BLIND.** Sequence: (1) measure whether a real `DPEG_Disposition_View`-only user can see ANY `Opportunity` row today, and what `Opportunity`'s org-wide default actually is (standard-object OWD is UI-only and is not in the repo); (2) only then choose. If sharing denies the rows, a permission grant delivers a card that says "no prior history" on every broker — **an honest-looking wrong answer**, which is worse than not shipping. ⚠ **`SYSTEM_MODE` is not the fix** — it bypasses CRUD/FLS and never sharing. If the answer is "the rows are not visible", the fallback is **D-15**. |
| **D-15** | **Item 3 — the fallback if G-5 says the Opportunity rows are unreachable.** | **Fall back to `Contact` broker counters, which are already maintained and already granted through the Contact permission sets:** `Deals_Won__c`, `Deals_Submitted__c`, `Closed_Volume__c` (maintained by `BrokerCounterRecalcBatch`). ⚠ **It is a strictly weaker answer and must be labelled as one** — it says "this broker has closed 4 deals with DPEG", not "this broker brought us THIS building", which is the whole point of story 21. Recommend reporting the gap rather than shipping the weaker card silently. Confirm which you want. |
| **D-16** | **Item 5 — does the new listing row carry the new broker's contact name?** | **YES.** `openBrokerListings` leaves `Contact_Name__c` blank and its header says *"A human fills it, **or the future broker-change action supplies it**."* The challenger's `Contact_Name__c` and `Broker_Firm__c` are already on the row `selectStatusesByDispositionId` returns, so it costs no query. This also closes P-13's stale-firm defect by construction. |
| **D-17** | **Item 5 — what does the Active Listing card show once there are two clocks?** | **Two labelled values: "Days on Market" (unchanged, the parent/marketing clock, still the band's input) and "Days with this broker" (`Days_On_Market_Live__c`, already selected and already granted — P-10).** 🔴 The new DTO member's ApexDoc must repeat the field's own prohibition verbatim: **nothing may read it to drive an alert or a band.** Confirm the second label's wording. |

---

## 3. Item-by-item design

### 🔵 Item 1 — fold Buyer Ready / Known Performer into `BOV_Score__c` (story 20) — ADMIN

**Deliver:** one edited `<formula>` in
`objects/BOV_Submission__c/fields/BOV_Score__c.field-meta.xml`, plus its `<description>`,
`<inlineHelpText>` and an amended XML comment. **Nothing else in the file changes** — not
`formulaTreatBlanksAs`, not `precision`/`scale`, not the label.

#### The proposed formula (D-1)

```
IF(
    OR(
        ISBLANK(Disposition__r.Property_Asset__r.Target_Sale_Price__c),
        Disposition__r.Property_Asset__r.Target_Sale_Price__c <= 0,
        ISBLANK(BOV_Amount__c)
    ),
    null,
      (40 * MIN(BOV_Amount__c / Disposition__r.Property_Asset__r.Target_Sale_Price__c, 1.10) / 1.10)
    + IF(ISBLANK(Commission_Rate__c), 0, 20 * (3 - MAX(1, MIN(3, Commission_Rate__c * 100))) / 2)
    + IF(ISBLANK(Days_To_Market__c),   0, 20 * (60 - MAX(15, MIN(60, Days_To_Market__c))) / 45)
    + IF(Is_Buyer_Ready__c,     10, 0)
    + IF(Is_Known_Performer__c, 10, 0)
)
```

🔴 **The null guard is BYTE-IDENTICAL and must stay that way.** The whole `IF(OR(...), null, ...)`
wrapper, and `formulaTreatBlanksAs = BlankAsBlank`, are unchanged. `BovAutoSelectionService` skips
null-scored rows; `ORDER BY BOV_Score__c DESC NULLS LAST` keeps them off the front. The field's own
header: *"Changing the guard to a 0 would silently make every unpriced sale auto-appoint whichever
broker quoted first."*

⚠ **The two flags sit INSIDE the guard, not outside it.** A row with no `BOV_Amount__c` but both
flags ticked must still score **null**, not 20 — otherwise an unpriced response becomes rankable and
the guard is defeated from the other end.

#### The arithmetic, and the rank inversion it produces

Existing term shapes (unchanged, only rescaled): value is linear in bid/target, capped at 110% of
target; commission is inverse-linear from 1% (full marks) to 3% (zero); speed is inverse-linear from
15 days (full marks) to 60 days (zero).

| | Broker A | Broker B |
|---|---|---|
| Bid vs target | **105%** | 98% |
| Commission | 2.5% | 2.5% |
| Days to market | 30 | 30 |
| Buyer Ready / Known Performer | ✗ / ✗ | **✓ / ✓** |
| **Today** — value 50·(1.05/1.10)=47.73 / 44.55 · commission 6.25 · speed 16.67 | **70.65 ← wins** | 67.47 |
| **Proposed** — value 40·(1.05/1.10)=38.18 / 35.64 · commission 5.00 · speed 13.33 · flags 0 / 20 | 56.51 | **73.97 ← wins** |

⇒ The two flags are worth 20 points, and 20 points of the 40-point value term corresponds to **55%
of target sale price**. In plain terms: *a Buyer-Ready, Known-Performing broker beats a stranger
bidding materially more.* That is what the story asks for; it is also a large lever to hand to two
hand-entered checkboxes, and it is **the number the BA must sign off**. A 45/22.5/22.5/5/5 variant
halves the lever with no structural change.

#### What happens to live data — the answer the request asked for (P-3, P-4)

| Population | Effect |
|---|---|
| Every score DISPLAYED anywhere | changes **instantly** on deploy (formula) |
| `Submission_Status__c` on a **locked** sale (approval pending / decided, or `Is_Manually_Appointed__c`) | 🔴 **never changes.** A manually-appointed broker is fully protected — the lock is evaluated over ALL siblings and returns zero writes |
| The **preferred** slot | never changes — score plays no part in PASS A |
| `Submission_Status__c` on an **unlocked, scored** sale | changes **only on the next qualifying save**: a BOV insert/delete/undelete, a change to one of the six keys, or a `Property_Asset__c.Target_Sale_Price__c` edit. **A formula deploy is not a qualifying save.** |
| `usman-dpeg` today | **zero** dispositions and **zero** BOV submissions ⇒ nothing to re-rank |

#### Budget (G-3)

Source grows from ~380 to ~500 characters, well under the 5,000-character source cap. The **3,900
compiled** cap is the one that cannot be computed from here — but the two added terms are
**same-object Checkbox** references, which add no relationship expansion, and the count of unique
cross-object relationships is **unchanged at 1** (`Disposition__r.Property_Asset__r`, already used
twice). Risk is low and the failure is **loud** (a deploy error), which is the safe direction.

**Risk: MEDIUM.** The formula is mechanically small. The risk is entirely (a) the weighting number,
which is a business decision this document can only propose; and (b) P-3's silent read/stored
divergence in any org that has data.

---

### 🟢 Item 2 — the comparison-matrix threshold (story 19) — DEVELOPER, and mostly ALREADY DONE

🔴 **Confirmed built:** the `>= 3` threshold (`BovController:154`) and the `Matrix Generated ✓`
badge (`bovOutreach.html:12-14`), both live, both Jest-pinned, both on the BOV Outreach screen.

✅ **Confirmed as requested:** `Disposition__c.Responses_Received__c` has a real writer as of
Tranche 1 — `DispositionCounterRollupService`, recomputing (never incrementing) from
`BovSubmissionSelector.countByDispositionIds` on `BOV_Submission__c` **after insert / update /
delete / undelete**, and the field was flipped to **read-only** in both permission sets in the same
pass. The trigger for the badge is reliable.

**The only work left is D-4's alignment:**

| Change | Where |
|---|---|
| `matrixGenerated` counts **non-preferred** responses | `BovController.getOutreachSummary` — derive from the submissions the matrix itself shows, not from `Responses_Received__c` |
| A boundary test at exactly 3 | `BovControllerTest` — 2 → false, 3 → true, and a 3-with-one-preferred → **false** case, which is the whole point of the change (P-31) |
| The `matrixGenerated` DTO member's comment | record that it deliberately diverges from `Responses_Received__c`, and why |

🔴 **Do NOT touch `Responses_Received__c` or `countByDispositionIds`.** They answer "how many brokers
came back", that is T1 decision D-9, and it is pinned by
`countByDispositionIds_countsEveryStatus_notJustSelected`.

⚠ Report to the BA: the tile beside the badge reads `{responsesReceived} of {brokersContacted}` and
`Brokers_Contacted__c` is **still hand-typed** (P-28), so "3 of 0" is reachable.

**Risk: LOW.** One derivation and three tests, on a feature that already works.

---

### 🟢 Item 3 — broker sale-history on the selection screen (story 21) — DEVELOPER + SOLUTION-ARCHITECT

**Gated on G-5 / D-14. Do not build before that measurement.**

#### The data path (P-18), and what it can honestly say

```
Disposition__c.Property_Asset__r.Property__c            <- one value, read from the disposition
Opportunity WHERE Property__c = :thatProperty
            AND StageName = 'Closed Won'
            AND Broker__c IN :theBovRespondentsContactIds
```

Answers: **"this broker brought DPEG this building, on DEAL-xxxx, closed <date>"**. It does **not**
answer "this broker was the seller's listing agent" — that is `Listing_Broker_Name__c`, free Text,
unjoinable (D-11).

#### Components

| Layer | Deliverable |
|---|---|
| `BovSubmissionSelector` | **new** `selectBrokerContactIdsByDispositionId(Id)`, `WITH USER_MODE`, `SELECT Id, Broker__c WHERE Disposition__c = :id AND Broker__c != NULL`. ⚠ A **new method**, not a widening of `selectByDispositionId` — the repo's own precedent (`selectSelectedBrokerByDispositionId:298-324`) and P-22's blanking hazard. Add its line to the class header's mode inventory. |
| `DispositionSelector` | reuse an existing method if one already returns `Property_Asset__r.Property__c`; otherwise **one** new `USER_MODE` method selecting exactly that. `Property_Asset__c` and `Property__c` object read were both granted by T1. |
| `OpportunitySelector` | **new** `selectClosedWonByPropertyAndBrokers(Id propertyId, Set<Id> brokerIds)` returning `Id, Name, CloseDate, Broker__c`. 🔴 Mode is **G-5's answer**, and its justification goes at the method's own declaration. |
| **new** `BrokerSaleHistoryService` | `with sharing`, `layer=service`. Returns `Map<Id /*brokerContactId*/, PriorDeal>` — one line per broker, newest closed deal. Zero SOQL of its own. |
| **new** thin controller | `@AuraEnabled(cacheable=true) getPriorDeals(Id dispositionId)`, `AuraHandledException` at the boundary. 🔴 **needs a `classAccesses` entry on `DPEG_Apex_Access`.** |
| `c/bovComparisonMatrix` | a **second wire** on the new method; decorate matching rows with a badge in the Broker Firm cell (or a seventh narrow column). 🔴 **Its own `catch` degrades to no decoration** — never to `loadError`. |
| `c/bovPreferredBroker` | the preferred broker is the one the panel puts *above* the matrix and is excluded from it. Decide whether it gets the same badge — recommend **yes**, same payload, one extra binding. |

⚠ **`Broker__c` on the matrix rows.** The client needs a broker Contact Id per row to match against
the service's map. Either add `Broker__c` to `selectByDispositionId` + `BovRow` (P-21 shows the usual
objection does not bite, since `DPEG_Admin_Access` already cannot run that query), or key the
decoration on the **submission Id** by having the service return submission Ids instead of Contact
Ids. **Recommend the latter** — it keeps `Broker__c` out of the matrix's `USER_MODE` read entirely
and honours the field header's "deliberately not added" note without needing to retract it.

**Risk: HIGH.** Not for the code, which is small, but because **G-5 can invalidate the whole item**,
and because the failure mode of getting it wrong is a card that confidently says "no prior history"
for every broker on every deal.

---

### 🟢 Item 4 — `brokersList` sort and filter (story 58) — DEVELOPER

**Zero Apex. Zero permission-set change. Zero FlexiPage change** (P-16, D-8). One LWC bundle.

#### Sort (P-15, D-6)

Reuse `sellMeterList`'s pattern exactly — do not reinvent it.

```js
const SORT_KEY = {
    recordUrl:      'name',          // the Broker column renders a url; sort the person's name
    firm:           'firm',
    activeListings: '_activeListings',   // raw Integer, bound to no column
    offers:         '_offers',           // raw Integer, bound to no column
    volumeLabel:    '_closedVolume',     // raw Decimal
    status:         '_statusRank'        // Active = 0, Inactive = 1 — RANK, never the pill string
};
```

- Every column gets `sortable: true`; each row carries the raw `_`-prefixed keys, rendered nowhere.
- `handleSort` sets `sortedBy` / `sortDirection`; `sortedBy` **undefined** keeps the server order
  (closed volume DESC, then Name) so the opening screen is byte-identical to today.
- **Sort the full list, THEN `slice(0, 5)`.** `count` keeps reporting the full length.
- ⚠ `'—'` is the null placeholder for `firm` and `volumeLabel`. Sort on the **raw** value with an
  explicit null policy (nulls last, both directions), not on the dash.

#### Filter (D-7)

- A `lightning-input type="search"` matching `name` **or** `firm`, case-insensitive, on the full
  list before sorting.
- A `lightning-combobox` for Status: All / Active / Inactive, from the two values the pill already
  knows.
- `count` should report the **filtered** length with the unfiltered total beside it, e.g.
  `Brokers (7 of 19)` — otherwise the header contradicts the table. ⚠ This changes the string
  `brokersList.test.js:86` asserts; update that pin deliberately.
- Both controls live **inside the card body**, above `c-list-datatable`, so region2's width and the
  FlexiPage are untouched.

#### Tests

- 🔴 **The existing "top-5 slice" test passes vacuously under D-6** with the default sort. Add a
  fixture where the closed-volume order and (say) the alphabetical order put **different brokers**
  in the top five, and assert the swap.
- Assert numeric sort explicitly with values that break lexicographically (1, 2, 10).
- Assert the pill column sorts by rank, not by the string.
- `@sa11y/jest` on the new controls; SLDS 2 tokens for any new styling (P-23).

**Risk: MEDIUM.** Mechanically contained and Apex-free. The risks are (a) the display-string trap,
which is why the SORT_KEY map is mandatory; (b) **it lands identically in the Acquisition app**
(P-17); (c) the `pill`-column `sortable` combination is still browser-unverified from T2 (P-30).

---

### 🟢 Item 5 — Replace Broker restarts the broker clock (story 31) — DEVELOPER

**Per D-9: the marketing clock is not touched. A second listing row is appended.**

#### `BovSubmissionService.replaceSelectedBroker` — a fourth write

Inside the **existing savepoint**, after write 3 (the parent stamp) and before or after write 4 (the
history row):

```
IF a Broker_Listing__c already exists for this disposition            <- D-10, the ONLY condition
THEN insert Broker_Listing__c(
        Disposition__c    = dispositionId,
        List_Date__c      = Date.today(),                              <- the broker clock restarts
        Broker_Firm__c    = challenger.Broker_Firm__c,
        Contact_Name__c   = challenger.Contact_Name__c,                <- D-16, closes P-13
        Listing_Status__c = LISTING_INITIAL_STATUS )
```

- 🔴 **The existence check is the entire safety mechanism** (P-11). Without it, a Replace Broker at
  BOV Outreach creates a listing that makes `openBrokerListings` a permanent no-op for that sale.
  The check goes through `BrokerListingSelector.selectByDispositionIds` (existing) or
  `selectMostRecentByDispositionId` (existing) — **no new selector method**.
- 🔴 **The class header's budget line must be corrected in place** from "1 SOQL + 3 DML" to
  "1-2 SOQL + 3-4 DML", in the same quote-and-retract style it already uses for the previous
  correction (P-27).
- ⚠ `Listing_Status__c` must be `LISTING_INITIAL_STATUS` (`On Track`) — a fresh broker starts on
  track. The **superseded** row keeps whatever status it had (P-26, D-10).
- ✅ `selectMostRecentByDispositionId` is already `ORDER BY CreatedDate DESC LIMIT 1`, so
  `c/brokerListing` follows the new row with **no change at all** (P-9).
- ⚠ The insert's DML mode must match `openBrokerListings`' reasoning, not inherit it blindly:
  `DPEG_Disposition_Edit` grants `Broker_Listing__c` `allowCreate = true` and every field written
  here `editable = true`, so `USER_MODE` genuinely works for the Analyst persona. But
  `replaceSelectedBroker` already asserts `DispositionActionPermissionService`, so the caller is by
  construction a disposition driver. **Recommend `USER_MODE`** and argue it at the statement — it is
  a user-requested write in a user-invoked service, which is exactly ARCHITECTURE.md §2's default.

#### `BrokerListingController.ListingRow` — one new member (D-17)

`daysWithThisBroker`, mapped from `bl.Days_On_Market_Live__c` — **already in the SELECT**
(`BrokerListingSelector:100`), already granted read in both sets, already unread. Zero selector
change, zero FLS change, zero extra query.

🔴 **Its ApexDoc must repeat the field's own prohibition verbatim:** *"NOTHING MAY READ THIS FORMULA
TO DRIVE AN ALERT OR ESCALATION."* `daysOnMarket` (the parent clock) stays the band's only input;
this member is display-only.

#### `c/brokerListing`

Two labelled values side by side — **"Days on Market"** (unchanged) and **"Days with this broker"**
(new). The traction badge, the band, the At-Risk styling and the Replace Broker button are all
unchanged.

#### Tests

- `BovSubmissionServiceTest`: a replacement **with** an existing listing appends exactly one row with
  today's date, the challenger's firm and contact; a replacement **without** one appends **nothing**
  (the D-10 negative case, which is the test that stops P-11 coming back).
- 🔴 A test proving `Disposition__c.Listing_Date__c` is **unchanged** by a replacement — that is the
  D-9 decision, pinned.
- 🔴 A test proving the traction band is unchanged across a replacement (the marketing clock did not
  restart) while `Days_On_Market_Live__c` reads 0 on the new row.
- The class header's existing bulk-rule **exemption reasoning must be re-stated**, not inherited —
  the transaction now touches a fourth object (P-31).
- Jest: `brokerListing` renders both numbers; `@sa11y/jest`.

**Risk: MEDIUM-HIGH.** Contained code, but it edits the module's most heavily-argued service inside
its savepoint, and the D-10 condition is the kind of thing that is easy to drop and impossible to
notice — the sale simply never gets its real listing, silently, months later.

---

## 4. Admin / Solution-Architect / Developer split

### 🔵 ADMIN (`salesforce-admin`)

| Item | Deliverable |
|---|---|
| 1 | `objects/BOV_Submission__c/fields/BOV_Score__c.field-meta.xml` — the re-weighted `<formula>`, updated `<description>` and `<inlineHelpText>`, and an amended XML comment recording the T4 weighting decision. **Nothing else in the file.** |
| 1 | Amend the "TRANCHE-4 IMPLICATION" blocks in `Is_Buyer_Ready__c` / `Is_Known_Performer__c` **in place** — the four numbered warnings become "addressed, and here is how", quote-and-retract, never deleted. |

**No other admin work in this tranche.** No new fields, no new picklist values, no FlexiPage, no
layout, no validation rule, no approval process.

### 🟤 SOLUTION-ARCHITECT (`salesforce-solution-architect`)

| Item | Deliverable |
|---|---|
| 3 | 🔴 **G-5 first.** Then, only if it passes: the `Opportunity` object read grant + the minimum field set (`Name`, `StageName`, `CloseDate`, `Property__c`, `Broker__c`) across `DPEG_Disposition_View` and `DPEG_Disposition_Edit`, as ONE consolidated pass. This is a **new cross-module authorization boundary**, which is why it is routed here and not to admin. |
| 3 | One `<apexClass>` entry on `DPEG_Apex_Access` for the new broker-sale-history **controller**. |

🔴 **A `PermissionSet` deploy REPLACES the file's entire `fieldPermissions`, `objectPermissions`
AND `classAccesses` collections.** A complete pre-deploy reconciliation needs
`FieldPermissions` + `ObjectPermissions` + **`SetupEntityAccess`** — a custom-permission grant is
invisible to the first two.

⚠ `git status` shows `DPEG_Transaction_Edit` / `_View` already modified by work that is **not** this
tranche (P-29). Follow the parallel-build hub-file protocol.

⚠ **Items 1, 2, 4 and 5 need NO permission-set change at all, and that is verified, not assumed:**
T1 granted both flags' FLS in both sets; `Responses_Received__c` read; `Property__c` /
`Property_Asset__c` object read; `Broker_Listing__c.Days_On_Market_Live__c` read; and
`BOV_Submission__c.Broker__c` read. **Do not re-add any of them.**

### 🟢 DEVELOPER (`salesforce-developer`)

| Item | Deliverable |
|---|---|
| 2 | `BovController.getOutreachSummary` — derive `matrixGenerated` from non-preferred responses (D-4); `BovControllerTest` boundary tests at 2 / 3 / 3-with-one-preferred. |
| 3 | New `OpportunitySelector` method; new `BovSubmissionSelector` method; new `BrokerSaleHistoryService`; new thin controller; the matrix decoration + Jest + `@sa11y/jest`. **All gated on G-5.** |
| 4 | `lwc/brokersList` — `SORT_KEY`, raw sort keys on each row, `handleSort`, search input, status combobox, sort-then-slice; Jest incl. a non-vacuous top-5 test. |
| 5 | `BovSubmissionService.replaceSelectedBroker` — the conditional fourth write + the corrected budget header; `BrokerListingController.ListingRow.daysWithThisBroker`; `lwc/brokerListing` second value; Apex + Jest tests incl. the D-10 negative and the "parent clock unchanged" pin. |
| 1 (D-3) | `scripts/` — the re-rank backfill script, **written and NOT run**, calling `BovAutoSelectionService.reselect(existingSubmissions, null)`, chunked by disposition, with a guard banner. |

**No integration, no Named Credential, no ASB/Plaid/Yardi touchpoint** —
`salesforce-technical-architect` is **not** required for this tranche.

---

## 5. Deploy order

| Wave | Contents | Why here |
|---|---|---|
| **0** | **GATES, no writes.** G-1 … G-8. | Two of them (G-5, G-6) can cancel or reshape an item. |
| **1** | **Item 4 — `lwc/brokersList` ALONE.** | Zero Apex, zero permissions, zero FlexiPage. It is the only item that can ship without touching anything else, and it exercises the `pill`-sortable combination T2 left unverified (P-30) on a low-stakes card. Ship it first and **look at it in a browser**. |
| **2** | **Item 1 — `BOV_Score__c`.** | A single field file. 🔴 Must land BEFORE any test that asserts a score value. ⚠ Run the whole disposition Apex suite: the formula feeds `BovAutoSelectionService`, `BovSubmissionSelector`'s ORDER BY, `DispositionApprovalService` and the `BOV_Tracker` report. |
| **3** | **Item 2 — `BovController` + `BovControllerTest`.** | Independent of everything else. Small. |
| **4** | **Item 5 — `BovSubmissionService` + `BrokerListingController` + tests, THEN `lwc/brokerListing`.** | Apex before LWC, per this repo's standing order. |
| **5** | **Item 3 Apex — selectors → service → controller.** | Only after G-5 passes. |
| **6** | **`DPEG_Apex_Access` (+ the Opportunity grant, if G-5 passed).** | 🔴 Same wave as, or later than, wave 5. A `classAccesses` entry naming a class the org does not hold fails the deploy of the ENTIRE set; a controller without its grant is a live break (T3 shipped one, green, dead for every non-admin). |
| **7** | **Item 3 LWC — `bovComparisonMatrix` decoration.** | Needs waves 5-6. |
| **8** | **Documentation** — the amended headers in `Is_Buyer_Ready__c` / `Is_Known_Performer__c`, `BovSubmissionService`'s budget line, `DispositionStageEntryService`'s "the future broker-change action supplies it" note (now shipped), and a correction to the gap analysis's story 19 and story 31 rows. | Last, so the retractions describe what actually shipped. |
| **9** | **BROWSER ACCEPTANCE. Not a deploy, and NOT FULLY DISCHARGEABLE TODAY.** | See §5.2. |

### 5.1 Gates

| # | Gate | Blocking? | Why |
|---|---|---|---|
| **G-1** | 🔴 **BA sign-off on the weighting number (D-1).** 40/20/20/10/10, or the 45/22.5/22.5/5/5 variant, or another. | **YES** | This is a business decision that changes which broker a live sale appoints. No agent can make it, and the request itself flags it for sign-off. |
| **G-2** | 🔴 **BA answer on D-11's semantics** — does "previously sold DPEG the property" mean the broker who **brought** the deal (`Opportunity.Broker__c`, joinable) or the seller's **listing** agent (`Listing_Broker_Name__c`, free text, not joinable)? | **YES** | If it is the latter, item 3 is not buildable on this data model and must be deferred with that stated. |
| **G-3** | ⚠ **Compiled-formula budget on `BOV_Score__c`.** Deploy the field check-only, alone, and read the compiled size back. | No (fails loud) | 3,900-char compiled cap. Low risk — the added terms are same-object Checkboxes and add no relationship expansion — but the request asked for it to be budgeted, and a deploy error is the safe failure direction. |
| **G-4** | 🔴 **Sweep for anything that ASSERTS a `BOV_Score__c` VALUE.** Grep `classes/` and `lwc/` for numeric score assertions and for `BOV_Score__c` in seed scripts and reports. | **YES** | A re-weighting changes every computed score. Any test asserting `68.81`-style values reds, and any seed script that hand-sets a score is now inconsistent with the formula. `BovControllerTest`, `BovAutoSelectionServiceTest`, `BovSubmissionSelectorTest` and `bovComparisonMatrix.test.js` are the first places to look. |
| **G-5** | 🔴 **CAN A DISPOSITION PERSONA ACTUALLY SEE AN `Opportunity` ROW?** Two measurements, both required: (a) `SELECT Id, DefaultOpportunityAccess FROM Organization` (standard-object OWD is **UI-only** and is not in the repo); (b) run `SELECT COUNT() FROM Opportunity` **as a real `DPEG_Disposition_View`-only user**, not as an admin. | **YES** | P-19. A permission grant that sharing then defeats produces a card saying "no prior history" on every broker — an honest-looking wrong answer. `SYSTEM_MODE` does **not** fix sharing. If (b) returns 0, take D-15's fallback or defer the item. |
| **G-6** | 🔴 **Resolve the concurrent working-tree state before item 3.** `git status` shows `objects/Opportunity/recordTypes/Commercial.recordType-meta.xml` **deleted**, plus two permission sets, six tabs, three dashboards and nine seed scripts modified by work that is not this tranche. Also retrieve and diff `Broker_Hub.flexipage` and `DPEG_Apex_Access` against the org. | **YES** | Measured 2026-08-16: a second session built a whole feature into this tree mid-run. A FlexiPage deploy clobbers App Builder edits with no version history (2026-08-25). A PermissionSet deploy replaces whole collections. |
| **G-7** | ⚠ **Is `brokersList` on any FlexiPage the repo does not know about?** It is `isExposed=true` with `lightning__AppPage` + `lightning__HomePage` targets. Query the org's `FlexiPage` metadata for `brokersList`. | No | P-17. The repo shows one placement; an App Builder placement would be invisible here, and item 4 changes the component for every placement. |
| **G-8** | ⚠ **Dry-run per-component `state`, and `sf sobject describe` is a stale cache.** Check each component's `state`, not the top-level status; verify any field via Tooling `CustomField` with an explicit `TableEnumOrId`; include every changed test class in the payload (`--tests` runs the **org's** copy). | No | All three measured on this project. Wave 8's documentation files will legitimately report `Unchanged`. |

### 5.2 🔴 What a deploy can and cannot discharge — per item, as the request asks

The org holds **0 `Disposition__c`, 1 `Property_Asset__c` (none on the Sell Meter), 6 `Property__c`**
(measured 2026-08-31). Every item in this tranche is data-dependent. Split honestly:

| Item | A deploy + readback CAN discharge | Only DATA can discharge |
|---|---|---|
| **1 — scoring** | the formula compiles, deploys, and is under the compiled cap; every Apex/Jest assertion | 🔴 that the re-weighting actually inverts a ranking; that `BovAutoSelectionService` appoints the right broker; that a manually-appointed broker survives it. **Needs at least one priced disposition with 2+ scoreable responses.** |
| **2 — matrix threshold** | the derivation, and the 2/3/3-with-preferred boundary tests | 🔴 that the badge appears at the third response on a real sale; that it does **not** appear when the third response is the preferred broker. **Needs 3 BOV rows on one disposition.** |
| **3 — sale history** | the classes compile, the queries are legal, the grant deploys | 🔴 **essentially everything.** Needs a `Property_Asset__c` linked to a `Property__c`, a **Closed Won** Opportunity on that Property with a `Broker__c`, and a BOV submission from that same broker. That chain does not exist in this org. 🔴 **And it must be walked as a real non-admin** — an admin smoke test proves nothing about G-5's sharing question. |
| **4 — sort/filter** | ✅ **almost all of it.** Jest proves the sort function, the filter and the slice order. | ⚠ that the sort chevrons **render and respond** on a custom `pill` column in a half-width region — a browser fact, and the same one T2 left open (P-30). Broker Contacts **do** exist in this org (~19 on the Broker record type), so item 4 is the **one item that can be seen today**. |
| **5 — listing clock** | the fourth write, the D-10 negative, the "parent clock unchanged" pin, and both card values in Jest | 🔴 that Replace Broker at Active Listing appends a row and the card follows it; that Replace Broker at BOV Outreach appends **nothing**; that "Days with this broker" reads 0 and "Days on Market" does not. **Needs a disposition at Active Listing with a listing row and two BOV submissions.** |

#### 🔴 Should this tranche ship before the org is reseeded? A direct answer.

**Split it. Ship item 4 now; hold items 1, 3 and 5 until there is data. Item 2 can go either way.**

- **Item 4 is genuinely verifiable today** — the Broker Hub has ~19 real broker Contacts, and the
  card is the one surface in this tranche with a live population.
- **Item 1 must not ship blind.** It is the only change in the programme that **decides which broker
  gets a listing**, its effect is invisible in a green deploy, and P-3 means the visible score and
  the stored appointment will disagree on any org that has data. Shipping a scoring change that
  nobody has ever watched re-rank a real sale is the exact shape of the T1 `ListView` incident, one
  layer further out.
- **Item 5 must not ship blind.** Its highest-consequence branch is a **negative** (D-10: append
  nothing at BOV Outreach), and a negative that is wrong is silent for months.
- **Item 3 is blocked on G-5 anyway**, and G-5 itself needs a real non-admin user and real
  Opportunity rows.

⇒ **Recommendation: seed before waves 2, 4, 5 and 7.** The minimum fixture is one Property_Asset
linked to a Property, one priced disposition on it, three BOV submissions (one preferred), one
Closed-Won Opportunity on the same Property naming one of those brokers, and the sale advanced to
Active Listing. `scripts/seed-disposition.apex` and the demo-seed runbook already build most of it.
Everything above is a browser walkthrough, not a deploy result.

---

## 6. Per-item risk register

| # | Item | Risk | Dominant hazard |
|---|---|---|---|
| 1 | Fold the two flags into `BOV_Score__c` | **MED** | 🔴 **The weighting is a business decision, not a technical one** (G-1) — 20 of 100 points ≈ a 55% bid-price swing, handed to two hand-entered checkboxes. 🔴 **P-3: the deploy changes every DISPLAYED score instantly and NO stored appointment**, so the matrix shows a new winner beside an old "Selected" pill until an unrelated save. ⚠ **P-6: a Checkbox cannot express "not yet assessed"**, so an unassessed broker is penalised exactly like a rejected one. ⚠ **G-4: every test asserting a score value reds.** ✅ Mitigated three ways: the null guard is untouched; a manually-appointed or under-approval sale cannot move (P-4); the preferred slot is score-independent (P-4); and there is **no FLS work at all** (P-5). |
| 2 | Matrix threshold | **LOW** | 🔴 **The item is already built** (P-1) — the real risk is *rebuilding it* and ending up with two thresholds. ⚠ The one genuine defect is the badge/matrix population mismatch (P-2), whose fix must **not** touch `Responses_Received__c` (T1 D-9, pinned). ⚠ The existing Jest test pins the badge, never the boundary (P-31). |
| 3 | Broker sale history | **HIGH** | 🔴 **G-5 can invalidate the whole item**: neither disposition set grants `Opportunity`, and a grant may still be defeated by record-level sharing, producing a confident wrong answer (P-19). 🔴 **The data means something other than the story says** — `Opportunity.Broker__c` is the SUBMITTING broker and its own header forbids the conflation (P-18). 🔴 **There is no off-market selection screen to put it on** (P-20). ⚠ **`getSubmissions` has one outer catch that blanks the whole matrix** (P-22) — the read must be a separate method with a narrow catch. ⚠ New controller ⇒ `DPEG_Apex_Access` entry, the thing T3 shipped without. |
| 4 | `brokersList` sort + filter | **MED** | 🔴 **Four of six columns bind display strings, two of them stringified numbers** — `sortable:true` alone gives `'1','10','2'` and `'$10.0M' < '$2.0M'` (P-15). 🔴 **The card renders only the top 5**, so sorting is meaningless unless it happens before the slice (P-14, D-6). 🔴 **It lands identically in the Acquisition app** — one FlexiPage, two apps, three permission sets (P-17). ⚠ The `pill`-column `sortable` combination is still browser-unverified from T2 (P-30). ⚠ The existing top-5 test goes vacuous (P-31). ✅ Mitigated: **zero Apex, zero permissions, zero FlexiPage**, every raw value already in the payload (P-16), and the SORT_KEY pattern already exists in-repo. |
| 5 | Replace Broker restarts the clock | **MED-HIGH** | 🔴 **The stated premise is false** — the clock is the PARENT's `Listing_Date__c`, and two class headers refuse the child-date reading in capitals while naming this exact button (P-8). 🔴 **The D-10 condition is a NEGATIVE and its failure is silent**: a listing created at BOV Outreach makes the Active Listing auto-create a permanent no-op with a wrong date and no error (P-11). 🔴 Edits the module's most heavily-argued service inside its savepoint; the budget header is a contract that has already been corrected once (P-27). ⚠ The superseded listing row keeps a live-looking status and story 5's "one active listing" is still unenforced (P-26). ✅ Mitigated three ways: the append route is **already designed for in writing** (P-9); `Days_On_Market_Live__c` is **already shipped, already selected, already granted** (P-10); and it closes the stale-firm defect P-13 for free. |

---

## 7. Confirmed OUT of Tranche 4

Restated so no implementing agent widens scope. **None of these is designed above.**

- **The Week 2/4/6 rung change (A2), broker-clock detection jobs, Call-for-Offers reminder ladders,
  the off-market one-week timer** — Tranche 5. ⚠ Item 5 touches `DispositionTractionService`'s
  *inputs* not at all: `WEEK_1_DAYS` / `WEEK_4_DAYS` / `WEEK_6_DAYS` are **not** edited here.
- **Offer comparison columns, closing statement upload, PSA status ordering, Conversion 6,
  CoStar/Argus deep links** — Tranche 6.
- **The Conversion 5 freeze** — **A1: NO FREEZE.** Not revisited. `BOV_Score__c` keeps scoring
  against the **live** `Property_Asset__r.Target_Sale_Price__c`.
- **`Dispositions/Sell_Ready_Argus` repoint** — A3 stays partially open by user decision.
- Anything integration- or notification-shaped.

**Additionally flagged here and deliberately NOT built, so they are not mistaken for oversights:**

- **`Hist_Success_Rate__c` stays out of the score** (P-7). Captured, granted in both sets, unused.
  After T4 that is a second deliberate omission and should be recorded on the field.
- **`Brokers_Contacted__c` is still hand-typed** (P-28), so the "n of m" tile beside the newly-aligned
  badge is half automated and "3 of 0" is reachable. Reported; not fixed.
- **The stale `Broker_Listing__c.Broker_Firm__c` after a replacement** (P-13) is fixed *only for
  replacements at Active Listing*, as a side effect of D-9's append. A replacement that happens
  before Active Listing still leaves the stamp to `openBrokerListings`, which is correct.
- **`Broker_Listing__c` has no `Superseded` status and no "one active listing" rule** (P-26). Adding
  a picklist value triggers the standing grep-repo-and-query-org sweep. Out of scope.
- **Off-market broker selection has no screen at all** (P-20). Item 3 is on-market only (D-13).
- **The hardcoded hex in `bovComparisonMatrix` and `brokersList`** (P-23). Pre-existing; new markup
  uses SLDS 2 tokens, the old colours are not touched, and the inconsistency is named rather than
  quietly uplifted.
- **`bovComparisonMatrix`'s "Score" column shows the number but never the weights.** After item 1 the
  matrix will show a score whose composition is only documented in the field XML. D-2 (showing the
  two flags) partly answers it; a full weight breakdown is not proposed.
- **`brokerReplaceQuickAction` / `Broker_Assignment__c.Replace_Broker`** — the PM leasing feature the
  gap analysis confused with this one (P-12). **Not touched.** The gap analysis's story 31 row should
  be corrected in wave 8.

---

## 8. Prompts for the specialist agents

Only what was requested. No extras.

### 🔵 PROMPT FOR `salesforce-admin`

```
Modify exactly ONE field file plus two XML comments, per
agent-output/disposition-gap-closure-t4-design.md §3 item 1 and §4's admin table. Do NOT deploy.

🔴 GATES FIRST. Do not write anything until G-1 (the BA has signed off on the WEIGHTING NUMBER)
and G-4 (the sweep for tests/scripts that assert a BOV_Score__c VALUE) have answers.

ITEM 1 — objects/BOV_Submission__c/fields/BOV_Score__c.field-meta.xml, <formula> only:

IF(
    OR(
        ISBLANK(Disposition__r.Property_Asset__r.Target_Sale_Price__c),
        Disposition__r.Property_Asset__r.Target_Sale_Price__c <= 0,
        ISBLANK(BOV_Amount__c)
    ),
    null,
      (40 * MIN(BOV_Amount__c / Disposition__r.Property_Asset__r.Target_Sale_Price__c, 1.10) / 1.10)
    + IF(ISBLANK(Commission_Rate__c), 0, 20 * (3 - MAX(1, MIN(3, Commission_Rate__c * 100))) / 2)
    + IF(ISBLANK(Days_To_Market__c),   0, 20 * (60 - MAX(15, MIN(60, Days_To_Market__c))) / 45)
    + IF(Is_Buyer_Ready__c,     10, 0)
    + IF(Is_Known_Performer__c, 10, 0)
)

🔴 THE NULL GUARD IS BYTE-IDENTICAL AND MUST STAY THAT WAY. Do NOT change
formulaTreatBlanksAs (it stays BlankAsBlank), precision, scale or the label. That guard is
load-bearing: BovAutoSelectionService skips null-scored rows and BovSubmissionSelector's
ORDER BY BOV_Score__c DESC NULLS LAST depends on it. The field's own header says changing the
guard to a 0 "would silently make every unpriced sale auto-appoint whichever broker quoted first."
🔴 THE TWO FLAGS GO INSIDE THE GUARD, NOT AFTER IT. A row with no BOV_Amount__c but both flags
ticked must still score null, not 20.

Update <description> and <inlineHelpText> to state the new weighting (Value 40 / Commission 20 /
Speed 20 / Buyer Ready 10 / Known Performer 10) and that a blank Target Sale Price still yields a
blank score.

Amend the XML comment INSIDE the root element (a comment ABOVE <CustomField> breaks `sf` at source
conversion) to record: the T4 weighting decision and its date; that the 50/25/25 form is retired;
and that the value basis is UNCHANGED (Property_Asset__r.Target_Sale_Price__c — decision A1, NO
FREEZE). Quote-and-retract the old weighting, do not delete it.

ALSO amend, IN PLACE, the "🔴 TRANCHE-4 IMPLICATION" blocks in
  objects/BOV_Submission__c/fields/Is_Buyer_Ready__c.field-meta.xml   (the full block)
  objects/BOV_Submission__c/fields/Is_Known_Performer__c.field-meta.xml (which points at the above)
Its four numbered warnings became "addressed, and here is how":
  1. compiled-cap budgeted (G-3) — the added terms are SAME-OBJECT checkboxes, so the count of
     unique cross-object relationships is unchanged at 1;
  2. the null guard survived intact;
  3. BlankAsBlank was NOT changed — and note that it does not interact with a Checkbox at all,
     so the "unset flag scores as an explicit no" concern is a BUSINESS fact accepted by the BA,
     not something the enum can fix;
  4. the live re-ranking question was answered by design decision D-3.
Quote-and-retract. Do not delete.

⚠ NO PERMISSION-SET WORK. Verified, not assumed: T1 already granted Is_Buyer_Ready__c and
Is_Known_Performer__c read in DPEG_Disposition_View and read+EDIT in DPEG_Disposition_Edit. A
formula field computes in SYSTEM context, so the score needs no FLS at all.

⚠ NO OTHER ADMIN WORK IN THIS TRANCHE. No new fields, no picklist values, no FlexiPage, no
layout, no validation rule, no approval process.

Record mcp=unavailable / mcp_tools=none per metadata type after a real attempt, and fall back to
the per-type skill. Do NOT deploy.
```

### 🟤 PROMPT FOR `salesforce-solution-architect`

```
Execute the ACCESS work in agent-output/disposition-gap-closure-t4-design.md §4. Do NOT deploy.

🔴 GATE G-5 COMES FIRST AND IT CAN CANCEL THE WHOLE OF ITEM 3. Two measurements, BOTH required:
  (a) SELECT Id, DefaultOpportunityAccess FROM Organization
      — standard-object OWD is UI-only and is NOT in this repo, so it cannot be read from source.
  (b) Run SELECT COUNT() FROM Opportunity AS A REAL DPEG_Disposition_View-ONLY USER, not as an
      administrator. Modify All Data makes an admin smoke test prove nothing here.
  If (b) returns 0, STOP and report it. A permission grant that record-level sharing then defeats
  produces a card saying "no prior history" for every broker on every deal — an honest-looking
  WRONG answer, which is worse than not shipping. SYSTEM_MODE does NOT fix this: it bypasses
  CRUD/FLS and never sharing (ARCHITECTURE.md §2).

ONLY IF G-5 PASSES — one consolidated, additive pass over exactly two files:
  DPEG_Disposition_View.permissionset-meta.xml
  DPEG_Disposition_Edit.permissionset-meta.xml
adding <objectPermissions> for Opportunity (allowRead=true, everything else false,
viewAllRecords=false — matching the shape T1 used for Property__c and Property_Asset__c) and
fieldPermissions readable=true for the MINIMUM field set only:
  Opportunity.StageName, Opportunity.Property__c, Opportunity.Broker__c, Opportunity.CloseDate
(Name needs no FieldPermissions row.)
🔴 THIS IS A NEW CROSS-MODULE AUTHORIZATION BOUNDARY — the disposition personas gain read on the
acquisition pipeline. Record that in each file's comment as a decision, with its date and the
design reference, so it does not read as a slip.

SEPARATELY, and in the same wave as or later than the Apex: add ONE <apexClass> entry on
permissionsets/DPEG_Apex_Access.permissionset-meta.xml for the new broker-sale-history CONTROLLER
created by salesforce-developer. Controllers only — that file grants controllers, not services or
selectors; follow its existing convention exactly.
🔴 That file's own header records a LIVE PRODUCTION BREAK on 2026-08-21 caused by shipping a
controller without its grant, and Tranche 3 repeated it: a GREEN deploy with a dead component for
every non-admin.

BEFORE EDITING (GATE G-6):
  - Retrieve all three files and diff against HEAD *and* against the org. A PermissionSet deploy
    REPLACES the file's entire fieldPermissions, objectPermissions AND classAccesses collections.
    A complete reconciliation needs FieldPermissions + ObjectPermissions + SetupEntityAccess — a
    custom-permission grant is invisible to the first two.
  - git status already shows DPEG_Transaction_Edit and DPEG_Transaction_View modified by work that
    is NOT this tranche, plus a DELETED Opportunity record type
    (objects/Opportunity/recordTypes/Commercial.recordType-meta.xml). Resolve that deletion before
    designing anything onto Opportunity. Report divergence and STOP rather than reconciling
    silently.

⚠ ITEMS 1, 2, 4 AND 5 NEED NO PERMISSION-SET CHANGE AT ALL, and that is VERIFIED, not assumed:
  - T1 granted BOV_Submission__c.Is_Buyer_Ready__c / Is_Known_Performer__c (read in View,
    read+edit in Edit), Disposition__c.Responses_Received__c (read-only in BOTH — flipped from
    editable in that same pass), Broker_Listing__c.Days_On_Market_Live__c (read), and
    Property__c / Property_Asset__c object read in both sets.
  - BOV_Submission__c.Broker__c has been granted read in both sets since 2026-08-20.
  Do NOT re-add any of them. Do NOT touch DPEG_App_Acquisition, DPEG_App_Disposition or
  DPEG_Admin_Access — item 4 introduces no new tab, object, field or class.

Record mcp=unavailable / mcp_tools=none after a real attempt. Do NOT deploy.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Implement the DEVELOPER work in agent-output/disposition-gap-closure-t4-design.md §3 items 2, 3, 4
and 5, and §4's developer table. Do NOT deploy.

════════════════════════════════════════════════════════════════════════════
ITEM 4 FIRST — lwc/brokersList sort + filter. ZERO APEX, ZERO PERMISSIONS, ZERO FLEXIPAGE.
════════════════════════════════════════════════════════════════════════════
🔴 DO NOT just add `sortable: true`. FOUR of the six columns bind PRE-FORMATTED strings and two of
them are numbers stringified:
    recordUrl      '/lightning/r/Contact/003.../view'   -> would sort by record Id
    activeListings String(n)                            -> would sort '1','10','2'
    offers         String(n)                            -> same
    volumeLabel    '$10.0M' / '$500K' / '—'             -> '$10.0M' sorts before '$2.0M'
    status         a custom `pill` column                -> would sort alphabetically, not by rank
Build a SORT_KEY map (column fieldName -> raw row field) and carry raw '_'-prefixed values on each
row, bound to no column and rendered nowhere. Copy the pattern from lwc/sellMeterList.js:101 and
:266 (`const field = SORT_KEY[this.sortedBy] || this.sortedBy;`) verbatim in shape — including its
warning that a fieldName MISSING from the map silently falls back to itself.
Sort the STATUS column by RANK (Active 0, Inactive 1), never by the pill string.
✅ Every raw value is already in BrokerController.BrokerRow — name, firm, status, activeListings
(Integer), offers (Integer), closedVolume (Decimal). ContactSelector.selectBrokersRankedByClosedVolume
has NO LIMIT and already returns the whole population. DO NOT TOUCH ANY APEX FOR THIS ITEM.

🔴 SORT THE FULL LIST, THEN slice(0, 5) — decision D-6. The card renders only the top 5 today
(brokersList.js:85), so sorting AFTER the slice would reorder five rows already chosen by closed
volume and could never surface the alphabetically-first broker.
`sortedBy` undefined MUST preserve today's exact order (server order: closed volume DESC, Name ASC).

FILTER (decision D-7): a lightning-input type="search" matching name OR firm (case-insensitive),
and a lightning-combobox Status = All / Active / Inactive. Both client-side over the full payload,
applied BEFORE the sort and the slice. Put both controls INSIDE the lightning-card body, above
c-list-datatable — NOT on the FlexiPage. Broker_Hub uses appHomeTemplateHeaderTwoColumns and
brokersList sits in region2, a HALF-WIDTH column already carrying six columns.
Update the header count to read "Brokers (7 of 19)" when filtered; that changes the string the
existing test asserts — update that pin deliberately.

🔴 THIS IS A CROSS-MODULE CHANGE. Broker_Hub is ONE FlexiPage and ONE tab appearing in BOTH
applications/Acquisition.app-meta.xml:115 and applications/Disposition.app-meta.xml:64, granted by
DPEG_App_Acquisition, DPEG_App_Disposition and DPEG_Admin_Access. Every acquisition user gets this
change identically. Do NOT edit the FlexiPage, the tab or any permission set.

TESTS: brokersList.test.js:80 ("shows the full count but only the top-5 rows") stays GREEN under
the default sort and therefore proves NOTHING about sorting. Add a fixture where the closed-volume
order and the alphabetical order put DIFFERENT brokers in the top five, and assert the swap.
Assert numeric sort with values that break lexicographically (1, 2, 10). Assert the pill column
sorts by rank. @sa11y/jest on the new controls. SLDS 2 design tokens for any new styling — do NOT
uplift the existing hardcoded hex (that is a separate uplift pass).

════════════════════════════════════════════════════════════════════════════
ITEM 2 — the matrix threshold. 🔴 IT IS ALREADY BUILT. DO NOT REBUILD IT.
════════════════════════════════════════════════════════════════════════════
BovController.getOutreachSummary:154 already computes `s.matrixGenerated = s.responsesReceived >= 3`
and bovOutreach.html:12-14 already renders the "Matrix Generated ✓" badge, pinned by
bovOutreach.test.js:76 and :98. Building a second threshold would give the module two.

THE ONLY CHANGE (decision D-4): make `matrixGenerated` count NON-PREFERRED responses.
WHY: Responses_Received__c counts EVERY child row including the preferred broker (T1 decision D-9),
while bovComparisonMatrix._visible EXCLUDES `isPreferred === true`. So on a sale with two scored
responses plus one preferred broker the badge says "Matrix Generated ✓" beside a two-row matrix,
and nothing on the screen explains it.
🔴 DO NOT TOUCH Disposition__c.Responses_Received__c OR BovSubmissionSelector.countByDispositionIds.
That field answers "how many brokers came back", it is T1 decision D-9, and it is pinned by
countByDispositionIds_countsEveryStatus_notJustSelected. The "n of m" tile keeps using it.
Prefer deriving the count from the submissions already read rather than adding a query.

TESTS: BovControllerTest currently sets Responses_Received__c to 4 (:98) and 2 (:321) — never 3.
Add boundary tests at EXACTLY 2 (false), EXACTLY 3 (true), and 3-with-one-preferred (false). The
last one is the whole point of the change.

════════════════════════════════════════════════════════════════════════════
ITEM 5 — Replace Broker restarts the BROKER clock, not the marketing clock.
════════════════════════════════════════════════════════════════════════════
🔴 THE BRIEF'S PREMISE IS FALSE AND YOU MUST NOT ACT ON IT. DispositionTractionService does NOT
measure from Broker_Listing__c.List_Date__c. It measures from Disposition__c.Listing_Date__c
(evaluateAll:559; BrokerListingController:169). Both files argue that choice deliberately and NAME
THIS BUTTON as the hazard:
  DispositionTractionService:166-172 — "Using the child's date would silently reset the clock the
  moment a broker was replaced — i.e. exactly when the clock matters most."
  BrokerListingController:164-168 — "...which, now that this card carries a Replace Broker button,
  is one click away rather than hypothetical."
🔴 DO NOT WRITE Disposition__c.Listing_Date__c. Ever, in this item. Resetting it would also change
Disposition__c.Days_On_Market__c, the Dispositions/Avg_Days_on_Market report and the Broker Alert
Due KPI with NO metadata diff at all.

WHAT TO BUILD (decision D-9) — and the repo already designed it, in
DispositionStageEntryService.openBrokerListings' header: "a deliberate broker change APPENDS a
second row and the card follows the new broker with no schema change ... Contact_Name__c ... A
human fills it, or the future broker-change action supplies it."

In BovSubmissionService.replaceSelectedBroker, INSIDE THE EXISTING SAVEPOINT, add a FOURTH write:
    IF a Broker_Listing__c already exists for this disposition:
        insert Broker_Listing__c(Disposition__c = dispositionId,
                                 List_Date__c   = Date.today(),
                                 Broker_Firm__c = challenger.Broker_Firm__c,
                                 Contact_Name__c= challenger.Contact_Name__c,
                                 Listing_Status__c = 'On Track')
🔴 THE EXISTENCE CONDITION IS NOT OPTIONAL AND IS THE WHOLE SAFETY MECHANISM (decision D-10).
Replace Broker is ALSO reachable at BOV Outreach (dispositionMain.html:42, via c/bovBrokerPanel),
where no listing exists. DispositionStageEntryService.openBrokerListings' idempotency test is
SIMPLE PRESENCE — "this disposition already has a broker listing" — so a listing created at BOV
Outreach makes the Active Listing auto-create a PERMANENT NO-OP, leaving the sale with a listing
whose List_Date__c predates the listing and whose Broker_Firm__c was never stamped. Silent, and
unrecoverable without hand repair.
Use the EXISTING BrokerListingSelector.selectMostRecentByDispositionId / selectByDispositionIds
for the check — do NOT add a selector method.
🔴 CORRECT THE CLASS HEADER'S BUDGET LINE IN PLACE, from "1 SOQL + 3 DML" to "1-2 SOQL + 3-4 DML",
in the same quote-and-retract style it already uses — that header says in terms that "a header
that undercounts its own DML is how a budget line stops being a contract."
DML MODE: recommend USER_MODE and argue it AT THE STATEMENT. DPEG_Disposition_Edit grants
Broker_Listing__c allowCreate=true and every field written here editable=true (measured, and
openBrokerListings' own header says so), and replaceSelectedBroker already asserts
DispositionActionPermissionService, so the caller is by construction a disposition driver. Do NOT
inherit openBrokerListings' SYSTEM_MODE reasoning — that block is automation nobody asked for; this
one is a user-invoked action.
🔴 DO NOT MODIFY DispositionActionPermissionService — its header says "THE TWO CLASSES ARE ONE
DESIGN ON TWO MODULES — CHANGE BOTH OR NEITHER."

Then surface the broker clock (decision D-17):
  BrokerListingController.ListingRow gains ONE member, daysWithThisBroker, mapped from
  bl.Days_On_Market_Live__c — which is ALREADY IN THE SELECT
  (BrokerListingSelector.selectMostRecentByDispositionId:100, T1's repoint) and ALREADY GRANTED
  read in both sets. ZERO selector change, ZERO FLS change, ZERO extra query.
  🔴 ITS APEXDOC MUST REPEAT THE FIELD'S OWN PROHIBITION VERBATIM: "NOTHING MAY READ THIS FORMULA
  TO DRIVE AN ALERT OR ESCALATION." daysOnMarket (the parent clock) stays the band's ONLY input.
  lwc/brokerListing renders two labelled values: "Days on Market" (unchanged) and "Days with this
  broker" (new). The traction badge, band, at-risk styling and Replace Broker button are unchanged.

TESTS (BovSubmissionServiceTest):
  - replacement WITH an existing listing appends exactly ONE row, today's date, challenger's firm
    and contact name;
  - 🔴 replacement WITHOUT an existing listing appends NOTHING — this negative is the test that
    stops the D-10 defect coming back, and its failure is otherwise silent for months;
  - 🔴 Disposition__c.Listing_Date__c is UNCHANGED by a replacement (decision D-9, pinned);
  - the traction band is unchanged across a replacement while Days_On_Market_Live__c reads 0 on
    the new row.
  RE-STATE the class header's bulk-rule exemption reasoning rather than inheriting it — the
  transaction now touches a FOURTH object.

════════════════════════════════════════════════════════════════════════════
ITEM 3 — broker sale history. 🔴 BLOCKED ON GATES G-2 AND G-5. DO NOT START WITHOUT BOTH.
════════════════════════════════════════════════════════════════════════════
G-2: the BA must confirm the SEMANTICS. Opportunity.Broker__c's own field header says in terms it
is the SUBMITTING broker, "NOT the listing broker named in the OM", and names a MEASURED case where
they differ (Boulevard Corners). The listing broker lives in Listing_Broker_Name__c /
Listing_Broker_Email__c, which are TEXT and cannot be joined to a Contact at all. If the BA means
the listing broker, this item is NOT BUILDABLE on this data model — report that and stop.
G-5: neither disposition permission set grants Opportunity, and a grant may still be defeated by
record-level sharing. Owned by salesforce-solution-architect.

THE JOIN (on-market only — decision D-13; dispositionMain has NO Broker Selection branch, so
off-market has no selection screen to decorate):
  Disposition__c.Property_Asset__r.Property__c
  -> Opportunity WHERE Property__c = :that AND StageName = 'Closed Won' AND Broker__c IN :brokerIds

LAYERS:
  NEW OpportunitySelector method selectClosedWonByPropertyAndBrokers(Id, Set<Id>) returning
    Id, Name, CloseDate, Broker__c. Mode is G-5's answer; justify it at the method's declaration.
  NEW BovSubmissionSelector.selectBrokerContactIdsByDispositionId(Id), WITH USER_MODE.
    🔴 A NEW METHOD, NOT a widening of selectByDispositionId. The precedent and its reasoning are
    at selectSelectedBrokerByDispositionId:298-324. Add its line to the class header's mode
    inventory.
  NEW BrokerSaleHistoryService (with sharing, layer=service, zero SOQL of its own).
  NEW thin controller, @AuraEnabled(cacheable=true), AuraHandledException at the boundary only.
    🔴 IT NEEDS A DPEG_Apex_Access classAccesses ENTRY — owned by salesforce-solution-architect,
    but it must land with or after your class. Flag it in your output. Tranche 3 shipped a
    controller without one: green deploy, dead component for every non-admin.
  lwc/bovComparisonMatrix: a SECOND wire on the new method; decorate matching rows.
    🔴 ITS CATCH DEGRADES TO NO DECORATION, NEVER TO loadError. Do NOT fold this read into
    BovController.getSubmissions — that method has ONE outer catch that masks everything as the
    generic message and BLANKS THE ENTIRE MATRIX. The doctrine is stated on that class at
    readNdaStatusFailSoft:225-245: "Degrading one pill is strictly better than blanking the whole
    card."
  Key the decoration on the SUBMISSION Id, not the broker Contact Id, so BOV_Submission__c.Broker__c
  never has to enter the matrix's USER_MODE read — that field's own header says it is
  "DELIBERATELY NOT ADDED TO BovSubmissionSelector OR TO BovController".
  LABEL IT HONESTLY (decision D-11): "Brought us this building — DEAL-0042, closed 12 Mar 2024".
  NEVER "sold us".

Every class with SOQL must be a Selector. `with sharing` everywhere unless separately justified in
the class header. Jest + @sa11y/jest for every changed and new LWC bundle. SLDS 2 tokens, no new
hardcoded colours. Record mcp=unavailable / mcp_tools=none after a real attempt.

⚠ ALSO DELIVER (decision D-3), WRITTEN BUT NOT RUN: a scripts/ backfill that re-ranks existing
sales after item 1's formula change, calling BovAutoSelectionService.reselect(existingSubmissions,
null) — a PUBLIC method whose ApexDoc says a null priorById means "always re-rank". Chunk by
disposition (per-transaction SOQL/DML limits) and carry a guard banner. It will correctly move
NOTHING on a locked or manually-appointed sale. usman-dpeg has ZERO dispositions, so it is for the
first org that has data.
```

---

## 9. Summary

- **5 of 5 items designed.** Nothing added, nothing expanded. Everything that looked adjacent —
  `Hist_Success_Rate__c`, `Brokers_Contacted__c`, the "one active listing" rule, a `Superseded`
  listing status, the off-market selection screen, the hardcoded hex — is raised as a **decision or
  a flagged non-item**, not built.

- 🔴 **The headline correction: ITEM 2 IS ALREADY BUILT.** `BovController:154` computes the `>= 3`
  threshold and `bovOutreach.html:12-14` renders the literal `Matrix Generated ✓` badge, both live,
  both Jest-pinned, both on the BOV Outreach screen. The request and the gap analysis both say
  neither exists. What remains is one alignment: **the badge counts the preferred broker and the
  matrix does not**, so "Matrix Generated ✓" can sit above a two-row table.

- 🔴 **The second correction: ITEM 5's PREMISE IS FALSE.** The clock is
  `Disposition__c.Listing_Date__c`, not `Broker_Listing__c.List_Date__c`, and two class headers
  refuse the child-date reading in capitals while naming the Replace Broker button as the hazard.
  ✅ **But the repo already designed the answer** — `openBrokerListings`' header says a deliberate
  broker change **appends** a listing and the card follows it with no schema change, and T1 already
  shipped `Days_On_Market_Live__c`, already in the SELECT, already granted, currently unread. Item 5
  gives the BA **both clocks side by side** and destroys neither.

- 🔴 **The four other premises that would have produced a wrong build:**
  - **P-3** — a `BOV_Score__c` deploy changes every DISPLAYED score instantly and **no stored
    appointment at all**; a formula deploy is not one of `reselect`'s six change keys, so the matrix
    would show a new winner beside an old "Selected" pill indefinitely.
  - **P-11** — Replace Broker also fires at **BOV Outreach**, and a listing created there makes the
    Active Listing auto-create a **permanent silent no-op**.
  - **P-19** — neither disposition permission set grants `Opportunity`, and a grant may still be
    defeated by record-level sharing, delivering a card that says "no prior history" for every
    broker. `SYSTEM_MODE` cannot fix it.
  - **P-14/P-15** — `brokersList` renders `slice(0, 5)` and binds display strings for four of six
    columns, two of them stringified numbers. `sortable: true` alone gives `'1','10','2'` on a
    five-row slice.

- ✅ **Four pieces of good news that cut the work materially:** item 1 needs **no FLS and no selector
  change** (a formula computes in SYSTEM context, and both flags are same-object Checkboxes); item 4
  needs **no Apex, no permission set and no FlexiPage** (every raw value is already in the payload
  and the selector has no `LIMIT`); item 5's broker-clock number is **already shipped, already
  queried and already granted**; and a **manually-appointed broker is fully protected** from the
  re-weighting by a lock the module already evaluates over every sibling.

- **17 decisions (D-1 … D-17)** need confirmation before build; each carries a recommendation and
  its evidence. **D-1 (the weighting number) and D-11 (what "sold us" means) are business decisions
  no agent can make.**

- **8 gates (G-1 … G-8), five of them blocking.** G-5 can cancel item 3 outright.

- 🔴 **The single most important sentence in this document:** *four of the five items cannot be
  verified at all in `usman-dpeg` today.* The org holds **0 dispositions, 0 BOV submissions and 1
  property asset**. **Item 4 is the only one with a live population** (~19 broker Contacts).
  §5.2 recommends **splitting the tranche**: ship item 4 now, seed the org, then ship items 1, 2, 3
  and 5 — because item 1 decides which broker gets a listing and item 5's highest-consequence
  behaviour is a **negative**, and neither is observable in a green deploy.
