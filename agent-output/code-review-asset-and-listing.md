# Code Review — Tranche 5 (Property Asset auto-create + Active Listing traction monitor)

**Branch** `feature/stage-by-stage-alignment` · **HEAD** `4dabd6c` · **Reviewed** 2026-08-10
**Scope** Item A (`PropertyAssetService`, `PropertySelector`, `PropertyAssetSelector`, `OpportunityReviewTriggerHandler`) + Item B (`DispositionTractionService/Controller`, `DispositionOfferSelector`, `BrokerListingController/Selector`, `DispositionSelector`, `DispositionStageEntryService`, `DispositionTriggerHandler`, `DispositionTrigger`, four LWC bundles, two permission sets, `ARCHITECTURE.md`) — read-only.

| Severity | Count |
|---|---|
| 🔴 CRITICAL | 1 |
| 🟡 WARNING | 3 |
| 🟢 SUGGESTION | 3 |

**Verdict: CHANGES REQUIRED — one blocker, and it is a two-line metadata edit plus three comment rewrites.** The Apex, the LWC and the test suites are in good shape and I would approve them as they stand. The blocker is the half of decision D28-Q2 that was not done: the Disposition Path still teaches the retired 6-week clock, on the same record page where the new panel now teaches the 60-day one.

---

## 🔴 CRITICAL

### C1 — Both Disposition Path files still carry the retired 6-week clock, and three XML comments tell the next reader not to fix it

D27.1: *"That text is now **wrong and must be corrected**, on BOTH paths."*
D28-Q2: *"CHANGE ALL SIX PLACES to 60/30 … plus **both Path files**, an XML comment telling future readers not to fix the other one, `lwc/listingAlerts.html`, and `lwc/dispositionOffer/dispositionOffer.html:22`."*

Four of the six landed (`BrokerListingController`, `listingAlerts.html`, `dispositionOffer.html`, and the three test files). The Path files did not.

**`force-app/main/default/pathAssistants/Disposition_Path_On_Market.pathAssistant-meta.xml:51`** — `<active>true</active>`, so this is live:

```xml
<info>6-week marketing clock starts on listing date. Week 4 triggers YELLOW flag. Week 6 triggers Hard Stop + escalation to Ali.</info>
```

**`force-app/main/default/pathAssistants/Disposition_Path.pathAssistant-meta.xml:27`** — identical string (inactive path, so the text is cosmetic; its comment is not — see below).

Why this is a blocker rather than tidy-up:

1. **It contradicts the feature being shipped, on one screen.** After Item B deploys, a user standing on the Active Listing step of a Disposition sees the Path guidance say *"Week 4 YELLOW … Week 6 Hard Stop"* while `c-listing-alerts` next to it says *"Day 34 — Traction checkpoint: no offers"* and *"Day 60 marketing period ends"*. `BrokerListingController.cls:14-18` names that exact failure — "a badge and a panel that contradict each other on the same screen" — as the reason the two surfaces were made to share one computation. The Path is a third surface, and it disagrees with both.
2. **It promises a notification that does not exist.** *"escalation to Ali"* is a D9-deferred alert; nothing in this org sends it. That is precisely the defect for which the `listingAlerts` mock was condemned in D28-Q4 ("a component rendering a fixed lie is worse than an empty one"), and `listingAlerts.test.js:267-279` now has a permanent text-level falsifier banning `alert to` / `week 4` / `week 6` from the panel. The Path renders the banned strings four feet away.
3. **Three stale comments actively instruct the fix not to be made** — the "stale comment asserting something the change made untrue" trap:
   - `Disposition_Path_On_Market…:10-13` — *"The Active Listing text is under an OPEN question … and was copied forward UNEDITED on purpose. Editing it here would silently pre-empt that question."*
   - `Disposition_Path…:11-15` — *"is under an OPEN question … **Do not reconcile it here or in the new paths until that question is answered.**"*
   - `Disposition_Path_Off_Market…:26-28` — *"is under an OPEN user question about a 2-month vs 6-week clock … do not …"*

   D27.1 answered that question on 2026-08-10. The copy-forward discipline was correct at the time and worked exactly as intended; it now needs collecting.

**Fix**

- `Disposition_Path_On_Market…:51` — replace the `<info>` with 60/30 wording carrying no notification promise, e.g.
  `60-day marketing clock starts on the listing date. At day 30 with no offers, review the listing internally and decide whether to change the broker; day 60 with no offers ends the marketing period. An offer counts as traction.`
- `Disposition_Path…:27` — same string, so the inactive path stays the faithful record it claims to be.
- Rewrite the three comment blocks to record that D27.1 closed the question on 2026-08-10 and that the authoritative ladder is now `DispositionTractionService` (30 / 40 / 60), so the next reader does not re-open it.
- ⚠ `pathAssistants` deploy per record type; `Disposition_Path_On_Market` and `Disposition_Path_Off_Market` "must stay in step with each other" per that file's own Closing note — the Off_Market path has no Active Listing step, so only its comment needs the edit.

---

## 🟡 WARNINGS

### W1 — "A computed value cannot go stale" is not true at the `cacheable=true` boundary, and the offers list refreshes while the traction panel does not

`DispositionTractionService.cls:57-66` rejects a scheduled job partly on the grounds that *"A stored copy can go stale; a computed one cannot."* That holds server-side. It does not hold at the client: both consumers read through `@AuraEnabled(cacheable=true)` wires (`DispositionTractionController.cls:85`, `BrokerListingController.cls:101`), and nothing anywhere invalidates them.

The concrete sequence, all on one screen:

1. `c-disposition-offer` → `handleLogOffer` (`dispositionOffer.js:43-49`) navigates to the standard new-record page for `Disposition_Offer__c`.
2. The user saves. Coming back, `c-disposition-offer`'s LDS `getRelatedListRecords` wire **is** invalidated by the record create and shows the new offer.
3. `c-listing-alerts` and `c-broker-listing` are plain Apex wires with no `refreshApex` and no notifier, so they can keep serving the cached payload — i.e. `"Month one has passed with no offers. Review the listing internally and decide whether to change the broker."` beside a list that shows an offer.

That is the wrong instruction in the one moment the feature exists to get right, and it is the same contradiction-on-one-screen defect C1 is about.

I could not measure how long the client cache actually holds across an intra-SPA navigation, so I am not claiming a fixed window — but there is no invalidation in the code, no test covers it, and the class headers currently assert the opposite.

**Fix** — either is acceptable:
- *Cheap:* state the residual in `DispositionTractionService`'s §3 block and in both LWC headers ("computed at read time, but delivered through a cacheable wire — a just-logged offer may not move the band until the page is reloaded").
- *Complete:* have `dispositionOffer` fire a `CustomEvent` when its wire's record count changes, let `dispositionMain` relay it, and have `listingAlerts` / `brokerListing` hold their wire results and call `refreshApex`. ~15 lines, no server change.

### W2 — `DispositionSelector.selectListingClockByIds`'s sharing argument does not cover the one future caller the design advertises

`DispositionSelector.cls:214-221` leaves sharing user-scoped because *"a principal who cannot SEE the disposition is not on its record page."* True and well-argued for both read paths that exist today.

But `DispositionTractionService.cls:281-284` advertises exactly one non-record-page caller — *"that constancy is the property that makes this safe to call from a future batch or Schedulable"* — and §3's seam paragraph (lines 72-80) names the deferred D9 `Schedulable` as the intended consumer of `evaluate` + `listingStatusValue`. In that context there is no record page and no viewer. Under `with sharing` the job would silently skip every disposition the scheduling principal cannot see, and because `DispositionOfferSelector` **did** go `without sharing`, the two halves would disagree with nothing to notice — the `RoutingRetrySweepBatch` shape ARCHITECTURE.md §2 records as "failing as silence."

Not a defect today. It is an inherited-justification hazard planted for the next author, in a tranche that is otherwise scrupulous about re-arguing every borrowed premise (`DispositionStageEntryService.cls:649-675` is the model).

**Fix** — doc-only, one sentence at `selectListingClockByIds`: *"This sharing conclusion is scoped to the two record-page callers. The deferred D9 Schedulable named in `DispositionTractionService`'s header has no viewer, so it must re-argue sharing before calling `evaluateAll` — see `DispositionOfferSelector.TractionReads` for the shape."*

### W3 — `Closing_Date__c` is only tested on a save shape production never performs

Both tests that assert `Closing_Date__c` supply `CloseDate` in the same DML that moves the stage:

- `PropertyAssetServiceTest.cls:127-131` (`opps[0].CloseDate = expectedClose;` then `close(opps)`)
- `PropertyAssetServiceTest.cls:364-371` (the tie-break; the ordering is deliberate and correct — see the credit below)

Every production route does the opposite. `StageAdvanceService` writes `StageName` only; `Transaction_Complete_Close` writes `StageName` + `Deal_Category__c` + `Deal_Status__c`. Both therefore land in the measured branch where the org rewrites `CloseDate` to **today** — which is the branch that actually determines what `Closing_Date__c` holds in the field, and nothing pins it.

This is not a bug: `CloseDate` is a required standard field, so `Trigger.new` always carries a value and the assignment cannot null out. Two consequences are worth pinning anyway:

- the same business event stores two different meanings (**the actual close date** via Apex/Flow, **the user's planned close date** via a UI page save that submits the whole layout), and
- the earliest-wins tie-break at `PropertyAssetService.cls:320-323` is, as the header honestly says, unobservable on that path — so the only coverage it has is a test using a shape the app does not produce.

**Fix** — one test, and deliberately not one that hardcodes the org's rewrite (which would be a repo test asserting org-side automation):

```apex
// close by stage only — the shape StageAdvanceService and Transaction_Complete_Close use
update new Opportunity(Id = opps[0].Id, StageName = CLOSED_WON);
Opportunity saved = [SELECT CloseDate FROM Opportunity WHERE Id = :opps[0].Id];
Assert.areEqual(saved.CloseDate, assetsFor(properties)[0].Closing_Date__c,
    'On the route production actually takes, the asset must carry whatever CloseDate the '
    + 'save committed — this reds if the carry-over is ever dropped, under either reading '
    + 'of the org-side rewrite documented in the service header');
```

That assertion holds whether or not the rewrite happens, and goes red the day someone deletes the `closingDateByProperty` carry-over.

---

## 🟢 SUGGESTIONS

**S1 — the one surviving hardcoded threshold.** `dispositionOffer.html:31` restates *"60-day marketing clock, traction check at day 30"* as static copy. It is deliberate, commented (lines 22-29) and pinned by `dispositionOffer.test.js:81`, so it is a *known* second edit point rather than a hidden one — that is the right treatment. D28 notes a third revision is the trigger to revisit; at that point, consider dropping the numbers from this empty-state entirely, since `c-listing-alerts` states them two components over from a server payload. Confirmed by grep: no other threshold survives in Apex, LWC or CSS — `listingAlerts` reads `marketingPeriodDays` / `checkpointDays` off the payload throughout, and `BrokerListingController` holds no numbers at all.

**S2 — future-dated listing, cosmetic drift.** `DispositionTractionService.cls:215-218` clamps `days` to 0, so a listing dated a week ahead reports detail *"the day-30 traction check is due in 30 days"* while the milestone row shows `checkpointDate` = today + 37. If it matters, derive the note from `checkpointDate` rather than from the clamped day count. The clamp itself is right and is tested (`aFutureListingDateClampsToDayZero`).

**S3 — an assertion that cannot fail.** `DispositionStageEntryServiceTest.cls:1445` ends on `Assert.isTrue(true, …)`. The test does its job — it reds if `stampListingDates` throws on null/empty — but the assertion carries no information. A comment saying "the assertion is the absence of a throw", or asserting something real about the inputs, reads better.

---

## ✅ What is right, and is worth naming

Both hard questions in the brief check out, and several things here are better than the bar.

**Item A — bulk safety, idempotency and the type map.**
- Constant **2 SOQL / 1 DML per chunk**, zero on a chunk that closes nothing (`PropertyAssetService.cls:325-334`), asserted from **measured `Limits` deltas** rather than a hand tally (`cls:266-273`) so a query added *inside a selector* is caught too. The 251 test asserts `runInvocations = 2`, `runQueryCount = 4`, `runDmlCount = 2` and states the arithmetic.
- Idempotency is keyed on `Property__c` alone with no `Status__c` filter, argued (re-acquisition reactivates rather than splitting the PM tree), and holds across chunks because in-transaction DML is visible to the next chunk's read.
- **The `Property_Type__c` map genuinely cannot store an unmapped value.** Verified against metadata: `Property__c.Asset_Type__c` is restricted with exactly **10** values; `Property_Asset__c.Property_Type__c` is **unrestricted** with exactly **5**. The map holds the 5 identity pairs, `activeTypeMap()` re-checks each target against live `isActive()` picklist entries, and the assignment only happens on `mapped != null`. The `C-Store`/`Medical Office` refusals are the right call and are pinned by name. The `typeMapOverride` seam is the only way to falsify the describe guard and earns its keep — contrast the `DispositionTractionController` seam that was correctly rejected.
- No `Property_Asset__c` validation rules, no record types, `nameField` is Text, and `Property__c.Name` is Text too — so the loud-failure DML has no obvious throw surface. Checked, not assumed.
- **`twoDealsOnOneProperty_inOneChunk_createOneAsset` is a genuinely discriminating tie-break test.** The earlier date is put on the **first** record on purpose so last-wins and earliest-wins produce different answers, and the two-save ordering exists so both dates ride the same DML as the stage change. Most tie-break tests I read pass under either rule; this one cannot.

**Item B — the before-save stamp is lock-proof, and the analysis behind it is correct.**
- The three-case argument at `DispositionStageEntryService.cls:257-269` is right: `Active Listing` is not any approval's entry stage (`Broker_Selection_Approval` keys on `BOV Outreach`), case (b) is refused by the platform before any trigger runs, and case (c) — an admin advancing a locked row — is harmless precisely because an in-memory before-save assignment is not a second DML. `theListingBlockEnqueuesNothing` pins the absence of a Queueable, with the reason stated as *different* from the LOI/PSA blocks' reason.
- **Fill-if-blank cannot restart the clock**, and the fixture trap is handled everywhere: `TestDataFactory` seeds `Listing_Date__c = TODAY`, so every stamp test nulls it first, `listingStageEntryOpensOneListingAndStartsTheClock` opens with an explicit FIXTURE GUARD assertion, and `preexistingListingDateIsNotOverwritten` is the matched-pair falsifier. `stampListingDatesCostsNoQueriesNoDmlAt251` builds fresh `Disposition__c` instances so the in-memory assertion is on the code, not the factory. `reEnteringActiveListingNeverOpensASecondListing` closes the step-away-and-back case.
- **`NOT_LISTED` is genuinely distinguishable from day 0.** `evaluate` returns early with `daysOnMarket = null`, the selector reads the raw `Listing_Date__c` rather than the `BlankAsZero` formula, `brokerListing.js:37` renders a dash instead of collapsing to 0, and the LWC's `NOT_LISTED` case renders one milestone row and no clock bar. Three layers, each tested.
- **`DispositionOfferSelector.TractionReads` is as narrow as Apex allows** — one private inner class, one instance method, one aggregate query, nothing else. The outer class stays `with sharing` and holds no other query.

**Discipline worth crediting explicitly.**
- **Two idempotency guards in one tranche reached opposite sharing conclusions, each argued at its own method, with the difference stated** — `PropertyAssetSelector` went `without sharing` (a duplicate splits the entire PM tree, silently) while `BrokerListingSelector` stayed `with sharing` (a duplicate listing is visible on the record and removable by hand, and both disposition sets already hold `viewAllRecords`). That is the correct handling of the inherited-justification trap, not an inconsistency.
- `DispositionStageEntryService.cls:649-675` **refuses** to reuse the sibling blocks' SYSTEM_MODE reason and says plainly that this one is *"a genuine, bounded widening rather than a restoration"*. Rare and valuable.
- **Every "measured" claim I could check against the repo is true**: `DPEG_Disposition_Edit` grants `Broker_Listing__c` `allowCreate/allowEdit/viewAllRecords = true` with all four written fields `editable = true`; `Disposition_Offer__c` carries `viewAllRecords = true`; `DPEG_Transaction_Team` is a **PSG** whose eight member sets contain no `Property_Asset__c` permission of any kind (the four grantors are `DPEG_Acquisitions`, `DPEG_PropertyAsset_View`, `DPEG_PropertyMgmt_View/Edit`); `Listing_Status__c`'s restricted set is exactly the three values `listingStatusValue` returns; `Broker_Firm__c` and `Selected_Broker__c` are both Text; the `Property_Asset__c` criteria sharing rule really is `Status__c != ''` → `DPEG_Property_Mgmt_Team`, which is why setting `Status__c = 'Active'` is load-bearing rather than cosmetic.
- **No persona-gating gap.** `DispositionTractionController` is granted in `DPEG_Apex_Access` and `DPEG_Acquisitions`, and all four PSGs (`Junior_Analyst`, `Principal`, `Transaction_Team`, `Property_Management_Team`) carry `DPEG_Apex_Access`. `c-listing-alerts` is reached only through `dispositionMain`, which now passes `record-id` — the missing attribute was found and fixed rather than inherited. No flexipage changed, so the "ungated new component" trap does not apply here.
- `DPEG_Apex_Access.permissionset-meta.xml:42-47` carries an in-file comment about the **permission-set-replace** hazard at the point of edit. Exactly right, and inside the root element per the XML-comment rule.
- **`DispositionTractionController`'s wrong-type guard sits outside the `try`** so the generic catch cannot swallow its precise message, and the test asserts the **guard** with `Assert.fail()` positioned so removing it reds. The 88% is argued, and I agree with the rejection of the `@TestVisible` seam — I am not filing it.
- Governor assertions are snapshotted **inside** the transaction, never read after `Test.stopTest()`, with the reason cited, in all four new suites.
- **ARCHITECTURE.md §6 is current**: the `Property_Asset__c` object row, both new service rows, `DispositionStageEntryService`, the selector-count sentence (26→29 across 17→19) and two new automation-path table rows all landed in the same change.
- Test headers state what the suites **cannot** prove (the SYSTEM_MODE / `without sharing` decisions are unfalsifiable running as an admin) and name post-deploy gates A-G1/A-G2/A-G4 instead of implying coverage.

---

## File-by-file

| File | Status | 🔴 | 🟡 | 🟢 |
|---|---|---|---|---|
| `pathAssistants/Disposition_Path_On_Market.pathAssistant-meta.xml` | 🔴 | 1 | 0 | 0 |
| `pathAssistants/Disposition_Path.pathAssistant-meta.xml` | 🔴 | (C1) | 0 | 0 |
| `pathAssistants/Disposition_Path_Off_Market.pathAssistant-meta.xml` | 🔴 | (C1) | 0 | 0 |
| `PropertyAssetService.cls` | ✅ | 0 | 0 | 0 |
| `PropertyAssetServiceTest.cls` | 🟡 | 0 | 1 (W3) | 0 |
| `PropertySelector.cls` / `PropertySelectorTest.cls` | ✅ | 0 | 0 | 0 |
| `PropertyAssetSelector.cls` / `…Test.cls` | ✅ | 0 | 0 | 0 |
| `OpportunityReviewTriggerHandler.cls` | ✅ | 0 | 0 | 0 |
| `DispositionTractionService.cls` | 🟡 | 0 | 1 (W1) | 1 (S2) |
| `DispositionTractionServiceTest.cls` | ✅ | 0 | 0 | 0 |
| `DispositionTractionController.cls` / `…Test.cls` | 🟡 | 0 | 1 (W1) | 0 |
| `DispositionOfferSelector.cls` / `…Test.cls` | ✅ | 0 | 0 | 0 |
| `DispositionSelector.cls` | 🟡 | 0 | 1 (W2) | 0 |
| `BrokerListingController.cls` / `…Test.cls` | 🟡 | 0 | 1 (W1) | 0 |
| `BrokerListingSelector.cls` / `…Test.cls` | ✅ | 0 | 0 | 0 |
| `DispositionStageEntryService.cls` | ✅ | 0 | 0 | 0 |
| `DispositionStageEntryServiceTest.cls` | 🟢 | 0 | 0 | 1 (S3) |
| `DispositionTriggerHandler.cls` / `DispositionTrigger.trigger` | ✅ | 0 | 0 | 0 |
| `lwc/listingAlerts` (+ tests) | ✅ | 0 | 0 | 0 |
| `lwc/brokerListing`, `lwc/dispositionMain` | ✅ | 0 | 0 | 0 |
| `lwc/dispositionOffer` | 🟢 | 0 | 0 | 1 (S1) |
| `permissionsets/DPEG_Apex_Access`, `DPEG_Acquisitions` | ✅ | 0 | 0 | 0 |
| `ARCHITECTURE.md` | ✅ | 0 | 0 | 0 |

---

## Not filed, deliberately

- **The 88% on `DispositionTractionController`** — argued, not gamed; the seam rejection is right.
- **The broker-change mechanism** — correctly reported as needing a quick action, a layout change, a terminal `Listing_Status__c` value D28 never answered, and a service. Reporting it beat improvising it.
- **D28 decisions** — offers-only traction, hardcoded 60/30, auto-create the listing, replace the mock. All implemented as decided.
- **The pre-existing gate T-A1 record-type reds** (3 Apex failures) — verified out of scope.

## Deploy order

D28's "Item A first, Item B second" still holds and matters more now: **C1 must land with Item B, not after it.** Before Item B the Path text is merely wrong; after Item B, and only after, it is contradicted on-screen by a component the same deploy introduces.
