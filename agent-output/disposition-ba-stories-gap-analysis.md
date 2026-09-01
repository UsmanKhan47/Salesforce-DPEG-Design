# Disposition BA User Stories — Gap Analysis Against the Built Application

**Date:** 2026-08-31
**Author:** Main agent (analysis only — no code, metadata or org changes made)
**Scope:** All 69 BA user stories supplied for the Disposition module, read line by line against
the repo at `qa/lifecycle-simulation-2026-08-27` (HEAD contains every disposition commit:
`7fcae73` redesign → `df13fcd` buyer-timeline intervals).
**Explicitly out of scope, per the request:** integration stories and notification stories.
They are still listed below with a ⏭️ verdict so the count reconciles, but no gap detail is given.

---

## ⚠ Two caveats that apply to every line below

1. **This is a REPO analysis, not an ORG analysis.** Nothing here was measured against
   `usman-dpeg`. That distinction has bitten this project twice this month — most recently on
   2026-08-31, when an eight-workstream build the documentation described as "deployed" turned out
   to be entirely absent from the org. Before any of these gaps is scheduled, the "✅ Built" rows
   should be re-confirmed live, not taken from this document.
2. **Several "gaps" are places where the client already overruled the FSD at UAT.** Those are
   marked 🔁 and must be treated as *decisions to re-open with the BA*, not as defects to fix. The
   biggest three are called out in "Conflicts with decisions already taken" at the end.

Verdict key: ✅ built as specified · 🟡 partial or divergent · ❌ not built · ⏭️ deferred
(integration/notification) · 🔁 conflicts with a recorded prior decision.

---

## A. App, objects and access (stories 1–8)

### 1. Dedicated Disposition app — 🟡 partial

| AC | Verdict | Evidence |
|---|---|---|
| App visible in App Launcher to users with the Disposition permission set | ✅ | `applications/Disposition.app-meta.xml`; visibility granted by `DPEG_App_Disposition` |
| DHANANI logo in header | ✅ | `brand.logo = DPEG_Logo_Clear`, `headerColor #1B7A4B`, `shouldOverrideOrgTheme = true` |
| Nav bar shows Home, Dispositions, Brokers, Disposition Dashboard **in that order** | 🟡 | Actual order is **Home, Dispositions, Brokers, Reports, Disposition Dashboard** — a 5th tab (`standard-report`) sits between Brokers and the Dashboard. Either the story is under-specified or the Reports tab is unwanted. |
| Home is the default landing tab | ✅ | `Sell_Meter` AppPage tab, labelled "Home", is first in the list |
| Dispositions tab dropdown opens the Disposition object list views | ❌ | **`Disposition__c` has zero list views in the repo** — no `listViews/` folder and no `<listViews>` in the object file. Any list views the org shows today were made by hand in the UI and are not source-controlled. |

Also worth flagging: `Disposition_Dashboard.tab-meta.xml` is a **Web tab hard-coding an 18-char
dashboard Id** (`01Ziw000000hSvWEAU`). That is a known recurring break in this repo — it dies on
every org rebuild and produces "invalid cross reference id".

### 2. On-Market / Off-Market record types with their own paths — 🟡 partial

| AC | Verdict | Evidence |
|---|---|---|
| Record Types "On-Market Sale" (11 stages) and "Off-Market Sale" (9 stages) | ✅ (naming differs) | `recordTypes/On_Market` (11 values) and `recordTypes/Off_Market` (9 values). Labels are **"On Market" / "Off Market"**, not "On-Market Sale" / "Off-Market Sale". |
| Path reflects the correct stage list per record type | ✅ | Two rebuilt path assistants; picklist master order deliberately *interleaved* so both render |
| Record type set at Conversion 5 from the sale-decision choice | 🟡 | It **is** set at initiate — but by the **submitter** in `sellMeterInitiateModal`, before the approval, not by the approving principal. See story 15. |
| Record type cannot be changed once Broker/NDA begins without admin intervention | ❌ | No validation rule locks `RecordTypeId`. `Disposition__c` has only 3 validation rules and none of them touch record type. |
| Separate page layouts per record type | ❌ | **One layout only** — `layouts/Disposition__c-Disposition Layout`, assigned with no `<recordType>` qualifier on any profile. Stage-specific screens are achieved instead by LWC (`dispositionMain`/`dispositionSidebar`) and FlexiPage visibility rules, which is arguably better, but it is not what the AC says. |

### 3. `Disposition__c` with the FSD Table 24 field set — 🟡 significant gaps

Auto-number `DISP-{0000}` ✅. Present and correct: Disposition Stage, Property Asset, Selected
Broker, Brokers Contacted, Package Sent, Submission Deadline, Responses Received, Days On Market
(formula off `Listing_Date__c`), PSA Executed, Title Company, Closing Statement Uploaded, Net Sale
Proceeds (formula `Gross - Selling Costs`).

Gaps against Table 24:

| Table 24 field | Status |
|---|---|
| **Target Sale Price** | ❌ not on `Disposition__c` — lives on `Property_Asset__c`, surfaced as a spanning field |
| **NOI** | ❌ same — `Property_Asset__r.NOI__c` |
| **Market Cap Rate** | ❌ same — `Property_Asset__r.Market_Cap_Rate__c` |
| **Calculated Value** (NOI ÷ cap rate, formula) | ❌ **does not exist anywhere as a field** — computed in Apex (`SellMeterController.getPortfolio`) only |
| **Sell Meter Score** (implied ÷ target, formula) | ❌ same — Apex-only (`PropertyRow.meterScore`), never rendered |
| **List Date** | 🟡 named `Listing_Date__c` on Disposition; a second `List_Date__c` exists on `Broker_Listing__c` |
| **Call For Offers Date** | ❌ not on Disposition — only on `Broker_Listing__c` |
| **Offers Received** | ❌ not on Disposition at all — only on `Broker_Listing__c` (a plain Number) |
| **The six wire-gate fields** | 🟡 correctly modelled on the child `Wire__c` (all six + `Verified_DateTime__c`), not on Disposition; the parent carries only the derived `Wire_Verification_Completed__c` |
| Property Asset is a **required** lookup | ❌ `<required>false</required>` |
| Lookups from BOV Response / Broker Listing / Disposition Offer / NDA → Disposition | ✅ all four exist |

🔴 **Structural note that affects several later stories.** Every child is a **Lookup**, never a
Master-Detail, so **no roll-up summary field is possible on `Disposition__c` from any of them** —
and indeed zero rollups exist. `Responses_Received__c`, `Brokers_Contacted__c` and
`NDA_Count__c`/`Signed_NDA_Count__c` are plain Numbers; the NDA pair is maintained by a flow, the
BOV pair by **nothing at all** (grep shows they are read by `BovController` and written by no
production code). Any "counts automatically" AC therefore needs a deliberate mechanism choice.

### 4. BOV Response object — 🟡 built under a different name, one field family missing

**There is no `BOV_Response__c`.** The real object is **`BOV_Submission__c`** (`BOV-{0000}`). Three
stale files under `.claude/agent-memory/` still say `BOV_Response__c`; they are wrong and should be
corrected whatever else is decided.

| AC | Verdict |
|---|---|
| Broker Firm, Contact, BOV Amount, Days To Market, Success Rate | ✅ (`Broker_Firm__c`, `Contact_Name__c` + `Broker__c` lookup, `BOV_Amount__c`, `Days_To_Market__c`, `Hist_Success_Rate__c`) |
| Lookup to parent Disposition | ✅ |
| BOV Score is a 0–100 weighted formula | ✅ but weighted differently — **50 % value-vs-target + 25 % commission (inverse) + 25 % days-to-market**. `Hist_Success_Rate__c` is captured and **not used in the score**. |
| Status picklist Selected / Backup | ✅ (`Submission_Status__c`, restricted, Backup default) |

### 5. Broker Listing — 🟡 partial

| AC | Verdict |
|---|---|
| Object exists, lookup to Disposition | ✅ (`BL-{0000}`) |
| Lookup to the selected broker | ❌ **no broker lookup** — only `Broker_Firm__c` / `Contact_Name__c` Text fields |
| List Date and Days On Market exist | ✅ both |
| Days On Market **live-computed** from List Date | ❌ on this object it is a **plain Number**, not a formula. (The formula version lives on `Disposition__c`, off `Listing_Date__c`.) |
| Exactly one active Broker Listing per On-Market sale | ❌ no validation rule, no trigger, no flow — `Broker_Listing__c` has none of the three |

### 6. Disposition Offer — ✅ built (story contains an error)

`OFFER-{0000}`, all six Table 26 fields present, Disposition lookup present.

🔴 **The story's Status AC is wrong and the code is right.** The story says "Status picklist is
Received / Countered / Accepted / Rejected", and story 35 says "Offer Financing Type tracks Received
→ Countered → Accepted → Rejected". FSD §19.3 carries the same error. The repo correctly splits
these into two fields: `Offer_Status__c` (Received / Under Review / Countered by DPEG / Counter
Received from Buyer / Accepted / Rejected / Withdrawn by Buyer) and `Offer_Financing_Type__c`
(All Cash / Financed with contingency / Financed no contingency). **Recommend the story be
corrected, not the code.**

"Offers Received rolls up automatically" — ❌, see the structural note under story 3.

### 7. NDA object — 🟡 three gate fields missing

`NDA-{0000}` ✅, Disposition lookup ✅, two record types (`Acquisition_NDA` / `Disposition_NDA`) ✅.

| Table 27 field | Status |
|---|---|
| Party Type (Buyer / Connecting Broker) | 🟡 `Party_Role__c` = **Buyer / Introducing Broker** — value label differs from the story's "Connecting Broker" |
| Party Name | ✅ `Counterparty_Name__c` (Text 120), stamped from `Buyer__c` by `NdaBuyerStampService` |
| Status: Prepare → Approved → Sent → Signed → Declined | ✅ (the Disposition record type restricts to exactly those five) |
| **Principal Approved (checkbox + date)** | ❌ **does not exist** |
| Sent / Signed / Counter-Signed dates | ✅ |
| **Approved for Release** | ❌ **does not exist** — release is gated instead on `Signed_NDA_Count__c == NDA_Count__c` at the Disposition level |
| Materials Released Date | ✅ |
| **Buyer Response Date** | ❌ — buyer/broker responses are logged as child `Release_Materials_Response__c` rows carrying `Entry_DateTime__c` instead |
| OneDrive Link, Notes | ✅ |
| One NDA per party | 🟡 nothing enforces it; the model allows it |

### 8. A single permission set for the Disposition team — 🟡 divergent by design

There is **no single set**. Access is split three ways, deliberately: `DPEG_Disposition_Edit`
(Analyst persona, CRU), `DPEG_Disposition_View` (Principal persona, read-only), and
`DPEG_App_Disposition` (app + 5 tabs, no data). A 4th, `Disposition_Dashboard_Access`, grants 12
dashboard fields.

| AC | Verdict |
|---|---|
| Read/Write on Disposition, BOV, Broker Listing, Disposition Offer, NDA | ✅ in the Edit set (delete withheld everywhere) |
| **Read-only on Property** | ❌ **neither Disposition set grants `Property__c` or `Property_Asset__c` at all** — yet 8 of the 13 disposition reports and both dashboard donuts run on `Property_Asset__c`. A Disposition-only user cannot read the dashboard's own data. |
| **Read-only on Transaction / Offering (IR hand-off)** | ❌ neither object is granted by either set |
| Integrated market-data (CoStar/Argus) read-only for everyone | ❌ **no CoStar or Argus field appears in either Disposition set.** Where Argus *is* granted — `Disposition_Dashboard_Access` — `Argus_Value__c` is granted **editable**, the opposite of the AC. |
| App + tab visibility included | 🟡 present, but in a separate set (`DPEG_App_Disposition`) |
| Tested with a non-admin user | Unknown — not verifiable from source |

⚠ Recall the standing hazard: **a PermissionSet deploy REPLACES that set's entire `fieldPermissions`
collection.** Any consolidation here is a hub-file edit and must follow the parallel-build protocol.

---

## B. Home / Sell Meter (stories 9–14)

### 9. Four summary cards — 🟡

Cards, order, labels and icons all match (`sellMeterStats`: Sell now / Getting Close / Hold - Not
yet / Portfolio Upside) ✅. Counts come from the day-count bands ✅. Refresh on change ✅ (wire +
cacheable read).

❌ **Portfolio Upside is computed over every in-the-money asset in the portfolio, not only green
ones.** `SellMeterController.getMeterSummary` adds `implied − target` for any asset where that is
positive, regardless of band. The AC says "across sell-ready (green) properties".

### 10. Sell Meter table — 🟡

| AC | Verdict |
|---|---|
| Columns Property / NOI / Market Cap Rate / Target Sale Price / Peak Sell Date / Projected Value / Sell Meter / Action | ✅ (labels abbreviated: "Mkt Cap", "Projected Value at Peak") |
| Calculated Value = NOI ÷ cap rate | ✅ computed server-side (`impliedValue`) |
| **Sell Meter Score shown as a multiple (1.07×)** | ❌ `meterScore` is computed and **never rendered**. The Sell Meter column shows the band pill, not the multiple. |
| Badge shows colour band + countdown ("Sell now \| 12d") | ✅ exactly this format |
| Paginates 5 rows per page | ✅ `PAGE_SIZE = 5` |
| **Sorts on every column** | ❌ no column is `sortable`, there is no `onsort` handler. Rows are force-ordered by band, with a deliberate hack that lifts the first RED row onto page 1. |

### 11. Readiness Indicator panel — 🟡

`sellMeterLegend` renders the three bands ✅. Thresholds are exactly Green ≤ 30 d / Yellow 31–90 d /
Red > 90 d or null, in one shared function `SellMeterService.bandForPeak` used by **both** the read
path and the server-side write gate ✅ — a good property worth preserving.

❌ "Recalculated daily (scheduled batch)" — **no such batch exists.** The band is a pure function
evaluated at read time, so it is always current; the AC's *mechanism* is simply not the one built.
Separately, there is a **second, disagreeing band definition** in metadata:
`Property_Asset__c.Sell_Readiness_Band__c` is a formula off the `Argus_Signal__c` picklist
(Sell Now / 12 mo / Hold), not off the peak date — and **that** is the field both dashboard donuts
group by. So the Home page and the Dashboard can legitimately disagree about which band a property
is in.

### 12. Action column — ✅ / ❌ on one AC

Green → "Initiate", Yellow → "Override", Red → "Hold" and disabled ✅ (and the red block is enforced
server-side too, in `DispositionService`, so it survives a direct Apex call).

❌ "Override is visible only to principals" — there is **no permission check of any kind** in
`sellMeterList`. The button's label and enablement are derived from the band alone.

### 13 & 66. Initiate creates a Conversion 5 record that **freezes** the Sell Meter values — ❌ 🔁

**This is the single largest functional gap in the module.**

- Creating at "Disposition Readiness" ✅ (`DispositionService.initiateAndSubmit`).
- Property stays in the portfolio, no status change ✅.
- **Freezing NOI, peak sell date, projected value and target price — not implemented.** Those four
  fields do not exist on `Disposition__c`. The record page reads them live through spanning fields
  (`Property_Asset__r.NOI__c`, `.Market_Cap_Rate__c`, `.Peak_Sell_Date__c`,
  `.Target_Sale_Price__c`), and `BOV_Submission__c.BOV_Score__c` scores against the **live**
  `Property_Asset__r.Target_Sale_Price__c`. A market-data refresh therefore silently re-prices every
  BOV score on an in-flight deal and changes the numbers a principal approved on.
- 🔁 **The codebase moved deliberately *away* from this.** `initiateAndSubmit`'s own step-4 comment
  says "**NO price is stamped** … `Asking_Price__c` is retired from this flow and its two former
  consumers read the asset's `Target_Sale_Price__c` directly", and commit `8d790f6` is titled
  "Score BOVs against the asset Target Sale Price (**Expected Value retired**)". Re-introducing a
  freeze reverses a decision taken on 2026-08-24, and would need the BOV score formula changed with
  it. **Confirm with the BA before anything is built.**

### 14. Principal Override with a recorded reason — ❌

- Override appears only on Yellow, Red never offers it ✅.
- Confirming creates the Disposition and submits the same approval as Initiate ✅.
- ❌ **No principal-only visibility** (see story 12).
- ❌ **No free-text reason is captured.** `sellMeterList._confirmOverride` is a yes/no
  `LightningConfirm`; its own header states "there is still **no override REASON field** … a
  deliberate scope decision". There is no reason log.

---

## C. On-Market flow — BOV, broker selection (stories 15–21)

### 15. Sale decision auto-routes with an explicit On/Off-Market choice — 🟡

| AC | Verdict |
|---|---|
| Reaching Disposition Readiness auto-submits Approval #1 | ✅ `Sale_Decision_Approval`, submitted server-side by `initiateAndSubmit` |
| Any single principal's approval satisfies the gate | 🟡 `whenMultipleApprovers = FirstResponse` ✅ — but **only two named approvers are wired**: `nikhil.dhanani@usmandpeg.uat` and `aftab.ali.dpeg.usman@avanzasolutions.com`. **Junior and Nick are missing from all five processes.** |
| **The approval screen requires the approver to pick On-Market or Off-Market** | ❌ the choice is made by the **submitter** in `sellMeterInitiateModal` *before* submission. The approver only approves or rejects. |
| Record blocked from advancing until Approved | ✅ `recordEditability = AdminOnly` locks the record while pending, and the stage advance is driven by the approval's own semaphore |

### 16. Send BOV package to 5–6 brokers and track replies — 🟡

Fields present and shown together on the BOV Outreach card (`bovOutreach` +
`BovController.getOutreachSummary`) ✅. Submission Deadline ✅.

❌ **`Brokers_Contacted__c` and `Responses_Received__c` have no writer.** No Apex, flow or trigger
sets them; they are read-only in practice and must be typed by hand. "Responses Received increments
as each broker's reply is captured" is not implemented.
Also, nothing in the app *sends* a package — this is a manual step with a date field.

### 17. "Add Broker Response" action — ✅

`bovBrokerPanel` → `bovAddResponseModal` creates a `BOV_Submission__c` capturing firm, contact,
amount, days-to-market and success rate; two validation rules refuse an amount-less or broker-less
submission; `BOV_Score__c` is a formula so it is available immediately; the matrix re-renders. ✅

### 18. Preferred Broker — ✅ (mechanism differs from the AC's wording)

`Is_Preferred_Broker__c` + `BovPreferredBrokerService` + `bovPreferredBroker` ✅. It is displayed
alongside responses and selection history ✅.

🟡 Nuance worth knowing: since 2026-08-24 the preferred broker occupies a **second, independent
"Selected" slot** rather than pre-empting the scored winner — `Is_System_Selected__c` distinguishes
the two. So "pre-selected when Broker Selection is reached" is true in effect, but there are
deliberately two selected rows, not one.

### 19. Auto-build the comparison matrix at 3+ responses — 🟡

`bovComparisonMatrix` exists and scores every response out of 100 ✅.

❌ There is **no 3-response threshold and no "Matrix Generated ✓" status** — the matrix simply
renders whatever responses exist, from the first one.
🟡 The scoring inputs differ from the AC: it weighs BOV amount vs the asset's Target Sale Price,
commission, and days-to-market. It does **not** use Buyer Ready / Known Performer (see 20).
✅ Manual override exists (Replace Broker) and the weights are documented in the field XML — though
they are hard-coded in a formula, not configurable.

### 20. Buyer Ready / Known Performer flags — ❌ (partly)

- ❌ **`Buyer_Ready__c` and `Known_Performer__c` do not exist anywhere in the repo.** Grep returns
  zero hits across all metadata, Apex and LWC.
- ✅ Selected / Backup ranking exists, and `BovAutoSelectionService` marks the top scorer Selected
  and leaves the rest Backup, recomputed on every ranking-affecting save.
- ✅ Manual override exists and is fully audited: `BovSubmissionService.replaceSelectedBroker`
  writes an append-only `BOV_Broker_Change__c` row with outgoing/incoming broker + firm, a
  restricted `Reason__c` picklist, free-text `Notes__c`, `Logged_By__c` and `Entry_DateTime__c`.
  **This is stronger than the AC asks for.**

### 21. Approval #2 — Broker Selection — ✅ / 🟡

Two processes cover this by path: `BOV_Submission__c.Broker_Finalize_Approval` (on-market, targets
the submission so the approver sees that broker's economics) and
`Disposition__c.Broker_Selection_Approval` (off-market only, entry criterion `Is_On_Market__c =
False`) ✅. Record cannot advance until approved ✅. Any-one-of ✅ (but only 2 of 4 approvers — see 15).

🟡 "If a broker previously sold DPEG the property, that history is visible on the selection screen" —
partially: `bovBrokerChangeHistory` shows *this deal's* broker swaps, and the Broker Hub shows
firm-level closed volume, but there is no per-property "this broker sold us this building" surface
on the selection screen.

---

## D. NDA workflow (stories 22–27)

### 22. Enter the buyer / connecting broker as a record — ✅

`Party_Role__c` (Buyer / Introducing Broker) + `Counterparty_Name__c` + a `Buyer__c` Contact lookup,
one NDA per party, `Disposition__c` lookup ✅. Label wording differs ("Introducing" vs "Connecting").

### 23. Auto-populate the NDA template and route to a principal — ❌

- ❌ **No document generation exists.** Nothing populates an NDA template with the party name and
  property address. The NDA record holds a `OneDrive_URL__c` to a document produced outside the
  system.
- ❌ **No `Principal_Approved__c` checkbox/date field, and no NDA approval process.** The five
  approval processes cover Sale Decision, Broker Selection (×2), Offer Selection and Closing —
  **Approval #3 (NDA issue) is not built.** The `Status__c` picklist carries a "Approved" value, but
  nothing routes, records who approved, or blocks Send on it.
- ✅ The Prepare-before-populate ordering is implicit in the status path only.

### 24. DocuSign send, executed doc saved, Approved for Release — ⏭️ / ❌ split

- ⏭️ DocuSign send + auto-save of the executed document: **integration, out of scope here.**
- ❌ **`Approved_For_Release__c` does not exist**, so "automatically checked once fully executed"
  cannot be built as written. The equivalent today is the `NDA_Signed__c` latch + the
  `NDA_Signed_Rollup` / `NDA_Signed_Status_Sync` flows maintaining `Signed_NDA_Count__c` on the
  parent.
- ✅ Status tracks Not Sent → Sent → Signed → Declined, and Declined is flagged (`ndaMarkDeclined`
  quick action, `Is_Decline_Allowed__c` formula).

### 25. A late buyer must go through the same NDA workflow — 🟡

✅ A new NDA can be added at any stage, and the `All_NDAs_Signed_Before_Progression` validation rule
blocks *stage advancement* past Release Materials / Active Listing / Offer Selection / LOI / PSA /
Closing / Sale Closes whenever any NDA on the deal is unsigned. It applies identically to both
record types ✅.

🟡 But the gate is **deal-level, not party-level**: "Materials Release actions are blocked for any
party whose NDA is not Approved for Release" cannot be expressed today, because there is no
per-party release flag and no per-party release action. The rule blocks *everyone* if *anyone* is
unsigned — stricter in one direction, and unable to express per-party release in the other.

### 26. Declined NDA is flagged and a fresh NDA can be issued — ✅ mostly

Declined settable before Signed ✅; declined rows are retained, never deleted ✅; a new NDA for the
same party can be created ✅ (`DPEG_Disposition_Edit` grants NDA create).

🟡 "A Declined NDA blocks that party from Approved for Release" — no such flag; the effect is
achieved indirectly through the signed-count rule, and note that `NDA_Signed_Rollup` deliberately
**counts Declined rows** (decision D20/C2), which is the behaviour to re-confirm with the BA.

### 27. Materials only to Approved-for-Release parties — 🟡

✅ The public-teaser exemption is not modelled but also not blocked (nothing gates a teaser).
✅ `Materials_Released_Date__c` exists on the NDA.
❌ Not recorded automatically — there is no "Release Materials" action that stamps it; it is a
manual date, and the release step is expressed as a *stage* with a response log
(`Release_Materials_Response__c` + `releaseMaterialsResponseLog`), not as a per-party action.

---

## E. Buyer activity, listing clock, offers (stories 28–37)

### 28. Buyer activity timeline — ✅

`dispositionBuyerTimeline` + `DispositionBuyerTimelineService` merge buyer-role NDAs and Release
Materials responses into one chronological list, showing release date, elapsed review time and
response intervals ✅. The design deliberately avoids reading the latching `NDA_Signed__c` checkbox.

🟡 Buyer responses are entered manually ✅, but as `Release_Materials_Response__c` rows (broker-
scoped, `Entry_DateTime__c`), not as an `NDA__c.Buyer_Response_Date__c` field.

### 29. Follow-up reminder when a buyer goes quiet — ⏭️ notification, out of scope.

### 30. Days on Market with Week 2 / 4 / 6 alerts — 🟡 🔁

✅ Days on Market is computed and displayed (`DispositionTractionService`, `brokerListing`).
🔁 **The rungs are Week 1 / Week 4 / Week 6, not Week 2 / 4 / 6.** This was settled by the user on
2026-08-21 as the *third* dispute over these numbers, explicitly overriding
`DPEG-Stage-by-Stage.docx`. The new story reverts to Week 2. **This needs an explicit BA decision —
do not just change the constant.**
❌ The ladder is **render-time only**. There is no batch or schedulable that walks listings and
raises time-based alerts, so nothing is *sent* at any rung (the email/dashboard-flag halves of the
AC are the notification part, out of scope, but the *detection* job is also absent).

### 31. Replace Broker button — ✅

`brokerReplaceQuickAction` / `bovReplaceBrokerModal` → `BovSubmissionService.replaceSelectedBroker`
promotes a backup to Selected, sets `Is_Manually_Appointed__c` (which locks auto-selection out), and
writes the audit row ✅. Never automatic ✅ — `BovAutoSelectionService` explicitly yields once a human
has taken over.
🟡 "restarts the Active Listing clock" — the clock measures from `List_Date__c`; nothing resets it on
replacement.

### 32. Call for Offers date + recalculating reminders — 🟡

✅ `Broker_Listing__c.Call_For_Offers_Date__c` exists and is rendered by `dispositionCallForOffers`.
🟡 It lives on the listing, not the Disposition (story 3 puts it on Disposition).
❌ **No reminders on the disposition side.** `CallForOffersAlertBatch` fires at 7/3/1/0 days — but it
is **Opportunity-scoped (the acquisition module)**, keyed on `Opportunity.Offer_Due_Date__c`, and
never reads `Broker_Listing__c`. The "start of month / one week before / on the day" ladder and its
recalculation on date change do not exist for dispositions.

### 33. Log every submission as a Disposition Offer; pause the clock — 🟡

✅ `dispositionLogOfferModal` creates an offer with all six terms including
`Offer_Financing_Type__c`.
✅ **Clock pause is implemented and well-designed** — `DispositionTractionService` measures to
`min(today, firstOfferDate)`, so the clock stops by construction rather than by a stored flag.
❌ `Offers Received` does not increment on the Disposition (no such field — see story 3).

### 34. "Week 4 — At Risk" badge on screen and dashboard — 🟡 🔁

✅ The badge string survives in exactly one place: `brokerListing`'s header, beside the Replace
Broker button.
✅ `Broker Alert Due` is a dashboard KPI (report `Dispositions/Broker_Alert_Due`).
✅ It clears when an offer is logged (the clock pauses).
🔁 **UAT on 2026-08-21 deleted four surfaces from `listingAlerts`** at the user's explicit request
("we don't need listing traction… no need to show count of disposition offers"): the band pill, the
detail sentence, the clock progress bar and the milestone list. The new story asks for the badge
"on the Active Listing screen", which is close to what was removed. Confirm which the BA wants.

### 35. Side-by-side offer comparison — 🟡 🔁

✅ All offers on a Disposition render together (`dispositionOffer` sidebar, plus the native related
list and the `dispositionOfferSelect` screen).
❌ **The comparison does not show the terms.** `dispositionOfferSelect` requests only Name, Broker
name, Offer Amount and Offer Date. Earnest Money, Due Diligence Days and Closing Period Days are not
on any comparison surface.
🔁 `Offer_Financing_Type__c` was **removed from this screen at UAT on 2026-08-21** ("No need to show
financing not started"). The story asks for it back.
(The AC's "Offer Financing Type tracks Received → Countered → …" is the story error noted at 6.)

### 36. Select the winning offer and route Approval #4 — ✅

`dispositionOfferSelect` marks one offer `Is_Selected__c`, a before-context guard refuses a second
selected sibling, and `Disposition_Offer__c.Offer_Selection_Approval` fires on
`Is_Selected__c = True` ✅. On approval, `DispositionOfferTriggerHandler` marks the offer Accepted,
stamps `Accepted_Offer_Price__c` and moves the parent from Offer Selection → LOI ✅. Blocked until
approved ✅. (Approver roster gap per story 15.)

### 37. Rejected and countered offers stay visible — ✅

Nothing deletes offers; `Offer_Status__c` carries Countered/Rejected/Withdrawn; delete permission is
withheld from both personas ✅. 🟡 "the selected offer visually distinguished" — `Is_Selected__c`
exists; whether the sidebar visually marks it should be confirmed in the browser.

---

## F. Off-Market path (stories 38–40)

### 38. Nine-stage Off-Market path — ✅

Record type ✅, exact stage order matches the AC ✅ (Disposition Readiness → Broker Selection → NDA →
Release Materials → Offer Selection → LOI → PSA → Closing → Sale Closes; BOV Outreach and Active
Listing are excluded from the record type). On-market-only surfaces are hidden by FlexiPage
visibility rules and by `dispositionMain`'s stage routing ✅.
🟡 The stage is labelled **"Broker Selection"** on both paths; the story calls the off-market one
"Broker/Buyer Selection".

### 39. Enter the direct buyer and any connecting broker — 🟡

✅ `Disposition__c.Broker__c` is an off-market-only Contact lookup, enforced by the
`Broker_Lookup_Is_Off_Market_Only` validation rule, and stamped to `Selected_Broker__c` text.
✅ No listing-broker or clock fields render on the off-market path.
🟡 **The buyer's own identity is thin.** A 2026-08-21 change ("Broker-only model: drop buyer
identity") removed buyer identity from parts of this flow; the buyer survives as
`Disposition_Offer__c.Buyer__c` / `Buyer_Name__c` and `NDA__c.Buyer__c`, but there is no
Broker/Buyer Selection screen that captures the buyer as a first-class party before NDA.

### 40. Off-Market release gate + one-week timer — 🟡

✅ The gate is the same `All_NDAs_Signed_Before_Progression` rule, applied identically on both paths.
✅ Buyer responses are entered manually, consistent with the shared workflow.
❌ **No one-week timer.** No batch, schedulable or flow fires a follow-up a week after materials go
out. (The reminder delivery is out of scope as a notification, but the timer itself does not exist.)

---

## G. LOI, PSA, closing (stories 41–49)

### 41. LOI versions retained — 🟡

✅ `Counter_Offer__c` is an append-only counter/revision log per LOI, surfaced by `loiCounterOffer`,
and `Disposition__c.Primary_LOI__c` + the FlexiPage's LOI section show current status ✅. The same
mechanism serves both paths ✅.
🟡 It is a **counter-offer log, not a document version history** — there is no LOI equivalent of
`PSA_Version__c`, so a revised LOI document is not stored as a distinct version with its own URL.

### 42. PSA status progression — 🟡

`Contract_Review__c.Negotiation_Status__c` exists with **seven** values — Initial Draft, Revised,
Ready for Execution, Draft, Negotiation, Signed, Executed — i.e. the four the story names *plus*
three legacy ones, and "Negotiation" rather than "Negotiations".
❌ **Nothing enforces the order**; it is an ordinary picklist with no state-machine validation rule.
❌ No "Rahila drafts first" seller-drafts flag exists.
✅ `Disposition__c.PSA_Executed__c` feeds the Closing Readiness Panel — but note it is a **Checkbox**,
where FSD Table 24 and this story call it a **Date**. `Contract_Review__c.Execution_Date__c` carries
the date.

### 43. PSA revisions retained — ✅

`PSA_Version__c` (Contract_Review lookup, `Direction__c`, `Document_URL__c`, `Summary__c`,
`Version_Date__c`) is an append-only version log, visible to both personas (read granted in both
sets; update deliberately withheld from the Edit persona by decision D24) ✅.

### 44. Closing Readiness Panel — ✅

`dispositionClosing` / `DispositionController.getClosingSummary` returns exactly the four states the
AC asks for: `psaExecuted`, `titleCompany`, `closingStatementUploaded`, and `wireCreated`
(`!d.Wires__r.isEmpty()`) ✅.

### 45. Six wire verification fields — ✅

`Wire__c` carries exactly Verifier Name, Verifier Phone, Wire Instructions Source, Confirmed Wire
Amount, Verbal Verification Completed and Verified Date/Time ✅. `WireService.saveWire` stamps
`Verified_DateTime__c` from the verbal flag ✅.

### 46. Block the wire record from saving until all six are complete — ❌

- ❌ **`Wire__c` has zero validation rules.** Partial saves are permitted by design — the LWC saves
  progressively and shows a completion badge.
- 🟡 The "4/6" counter exists (`fieldsComplete`, with a green/amber badge) ✅, but it reports
  progress rather than blocking.
- ✅ The real gate is one level up: `Wire_Complete_Before_Sale_Closes` on `Disposition__c` refuses
  the move to Sale Closes unless `Wire_Verification_Completed__c` is true, and
  `Closing_Approval`'s entry criterion requires the same flag.
- ❌ "cannot be bypassed from the UI" — the *stage* gate cannot, but the *record* gate does not exist.

### 47. Principal wire sign-off — ✅ / 🟡

`Closing_Approval` fires only when stage = Closing **and** `Wire_Verification_Completed__c = True` ✅,
routes through the shared approvals engine ✅, any-one-of ✅ — with the same 2-of-4 approver roster
gap (story 15).

### 48. Closing statement attached, status tracked — 🟡

✅ `Closing_Statement_Uploaded__c` exists and drives the panel.
🟡 There is **no upload UI** and no automation linking a `ContentDocument` to the flag — the checkbox
is ticked by hand. (Note the standing ContentPublication quota rule before designing any file-based
alternative.)

### 49. Conversion 6 — sale Closed, property Sold, off the dashboards — ❌

- 🟡 The sale reaches **"Sale Closes"** (terminal, gated by the wire rule and reached via
  `Closing_Approval`'s auto-advance) — the label is "Sale Closes", not "Closed".
- ❌ **Nothing sets `Property_Asset__c.Status__c = 'Disposed'`.** Grep across all Apex and flows finds
  no writer; the only place the value is written is an unrelated Broker Assignment migration script.
- ❌ **Nothing removes the property from the portfolio dashboards.** Both sell-meter queries filter
  on `Property__c != null AND Peak_Sell_Date__c != null` with **no `Status__c` filter**, so a sold
  asset keeps appearing on the Sell Meter and in the readiness donuts.

### 50. IR notified with net proceeds — ⏭️ notification, out of scope.
(For reference, `Net_Sale_Proceeds__c` exists as a formula, and `OfferingService` already opens the
IR `Offering__c` shell on the *acquisition* PSA — nothing analogous fires on a disposition close.)

---

## H. Approvals engine (stories 51–53)

### 51. One consistent Approval record object — ❌ (by design)

- ❌ **No `Approval__c` object exists**, and no generic approval-log object of any name.
- ✅ The five approval *types* are all covered — but by **native Approval Processes across three
  objects**, with per-object `Approval_Status__c` / `Approval_Pending__c` fields, except #3 (NDA
  issue) which is **not built at all** (story 23).
- 🟡 The audit trail therefore lives in `ProcessInstance` / `ProcessInstanceStep`, which
  `DispositionApprovalHistoryService` reads and consolidates. That is a legitimate architecture and
  arguably better than a shadow object — but it is not what the AC describes, and it means approver
  identity is only obtainable via that read (the `ApprovalAuditService` invocable exists precisely
  because field updates cannot capture it).

### 52. A tracker showing all five approvals in one place — 🟡

✅ `dispositionApprovalHistory` + `DispositionApprovalHistoryService` build a **consolidated history
across all three objects** (Disposition, selected BOV submission, selected offer), newest first, on
the record page.
🟡 It is a **history of what has happened**, not a five-row checklist of pending-vs-complete for all
five types. With NDA approval absent, only four types can ever appear.

### 53. Any one of the four principals; #4 and #5 wired — 🟡

✅ `whenMultipleApprovers = FirstResponse` on every process.
✅ Approval #4 (`Offer_Selection_Approval`) and #5 (`Closing_Approval`) are both wired.
❌ **Only 2 of the 4 principals are named approvers** on all five processes. Junior and Nick are not
in any of them — so "a single principal being unavailable never blocks the sale" is only half true
today. This is the cheapest high-value fix in the whole list.

---

## I. Notifications (stories 54–56) — ⏭️ out of scope

For reference only: there is no reusable notification framework and no `Notification__c` object.
Alerting today is four independent daily batches (`CallForOffersAlertBatch`, `NdaExpiryAlertBatch`,
`StageDelayAlertBatch`, `BrokerCounterRecalcBatch`) plus eight record-triggered flows, each with its
own recipients. ⚠ Two standing hazards if this is ever picked up: `GroupNotifier` hardcodes the
`Acquisitions_Deal_Update` group, so reuse arrives mis-branded; and **every `*Schedule` class is inert
until someone runs `System.schedule` post-deploy** — it fails silently with zero errors.

---

## J. Brokers Console (stories 57–59)

### 57. Snapshot cards — ✅

`brokerStats` renders exactly Total Broker Firms / Total Brokers / Active Listings / Offers Received,
each with an icon ✅.

### 58. Broker track record list — 🟡

`brokersList` columns are Broker, Firm, Active Listings, Offers, Closed Volume, Status — an exact
match ✅.
❌ "The list can be sorted/filtered" — no sort or filter affordance on the datatable.

### 59. One place for every broker relationship across every sale — 🟡

✅ `BrokerController.getBrokerHub` aggregates across brokers portfolio-wide, and drill-through to the
broker Contact works.
🟡 **The Broker Hub page is shared with the Acquisition app** (same `Broker_Hub` FlexiPage, same
`Broker_Hub` tab in both apps), and brokers are Contacts on the `Contact.Broker` record type — i.e.
it is a *broker* console, not specifically a *disposition* broker console. Whether "across every
Disposition sale record" means dispositions only, or all deals, should be settled with the BA.
🟡 Drill-down "into that broker's individual listings and offers" lands on the Contact record, not on
a listings/offers view.

---

## K. Disposition Dashboard (stories 60–62)

### 60. Top-line KPIs — ✅ (labels differ)

All five exist as Metric components on `Disposition_Dashboard_Junior`: Listed with Broker
(titled **"Active Listing"**), Sell Ready (titled **"Disposition Readiness"**), BOVs Ordered (titled
**"BOV Outreach"**), Avg Sell Readiness, Broker Alert Due (red) ✅.

### 61. BOV Tracker + Sell Readiness by Property Type — ✅

Both tables exist, sourced from `Dispositions/BOV_Tracker` (BOV_Submission report type, sorted by
amount) and `Dispositions/Sell_Readiness_By_Type` (Property_Asset, by Argus value) ✅. Property Type
values include the four the AC names plus Mixed-Use.

### 62. Readiness donuts by count and by value — ✅ with a caveat

Both donuts exist, grouped by `Property_Asset__c.Sell_Readiness_Band__c`, one on row count and one on
sum of `Argus_Value__c` ✅.
🟡 **They band by the Argus-signal formula, not by the 30/90-day peak-date rule** the Home page uses
(see story 11). The dashboard and Home page can show different band counts for the same portfolio.
⚠ Also: a Disposition-only user has **no `Property_Asset__c` read grant** (story 8), so these two
donuts and five other reports will not render for that persona.

---

## L. Market data and security (stories 63–69)

### 63. Deep links to CoStar and the Argus model — ❌

`Property__c.CoStar_URL__c` exists (acquisition side), but **neither the Disposition record page nor
`Property_Asset__c` carries a CoStar or Argus link field**, and neither appears on
`Disposition_Record_Page`. No Argus URL field exists anywhere.

### 64 / 65 / 67 / 68. CoStar pull, Argus Altus pull, AWS Secrets Manager, one-way Lambda/ASB — ⏭️

Out of scope as integrations.
⚠ One architectural flag for whenever these come back: `ARCHITECTURE.md` §3 already carries **three
standing direct-callout exceptions and zero ASB-routed implementations (3 of 3)**, and §3.5 states in
terms that a **fourth exception is not a judgement call** — it is the point at which the ASB-hub
architecture is provably aspirational. Stories 64/65/68 describe exactly the ASB/Lambda routing that
does not yet exist anywhere in this application, so they should be raised as an architecture question
before they are scheduled as build items.

### 66. Values frozen at Conversion 5 — ❌ — see story 13. Same gap, same conflict.

### 69. Tamper-proof integrated fields and wire timestamp — ❌

| AC | Verdict |
|---|---|
| Integrated CoStar/Argus fields read-only with a visible timestamp | ❌ no CoStar/Argus field is granted by either Disposition set; where Argus *is* granted (`Disposition_Dashboard_Access`) `Argus_Value__c` is **editable**; `Property_Asset__c` carries no `*_Last_Synced_DateTime__c` field at all |
| **Verified Date/Time cannot be backdated** | ❌ `Wire__c.Verified_DateTime__c` is granted **`editable=true`** in `DPEG_Disposition_Edit`, and `Wire__c` has no validation rule. It is directly editable today. |
| Six-field wire gate cannot be bypassed from the UI | 🟡 the *stage* gate holds; the *record-level* six-field gate does not exist (story 46) |

---

## Summary counts

| Verdict | Count |
|---|---|
| ✅ Built as specified | 20 |
| 🟡 Partial / divergent | 27 |
| ❌ Not built | 13 |
| ⏭️ Deferred (integration / notification) | 9 |

---

## The five things worth deciding first

1. **The Conversion 5 freeze (13, 66).** Not built, and the codebase moved *deliberately away* from
   it on 2026-08-24 ("Expected Value retired"). Everything else on this list is additive; this one
   reverses a recorded decision and changes the BOV scoring formula with it.
2. **Two of four principals are missing from all five approval processes (15, 21, 47, 53).** Small,
   contained, and the AC "a single principal being unavailable never blocks the sale" is currently
   false.
3. **Permission-set access to `Property_Asset__c` / `Property__c` / `Offering__c` / `Transaction__c`
   (8).** A Disposition-only user cannot read the data behind their own dashboard. Note this is a
   hub-file edit: a permission-set deploy **replaces** the whole `fieldPermissions` collection.
4. **The NDA gate fields (7, 23, 24, 27).** `Principal_Approved__c`, `Approved_For_Release__c` and
   `Buyer_Response_Date__c` are all absent, and Approval #3 does not exist. Six stories hang off
   these three fields, so they should be decided as one item rather than six.
5. **Two disagreeing readiness-band definitions (11, 62).** The Home page bands on days-to-peak; the
   dashboard bands on the Argus signal picklist. Whichever is right, they should not both exist.

## ✅ Conflict resolutions — USER-CONFIRMED 2026-08-31

These were put to the user as explicit either/or choices and answered. They are decisions, not
assumptions, and they override the story text where the two disagree.

| Ref | Conflict | Decision |
|---|---|---|
| **A1** | Freeze Sell Meter values at Conversion 5 (stories 13, 66) | **NO FREEZE.** The 2026-08-24 live-values design stands (`Asking_Price__c` stays retired, `BOV_Score__c` keeps scoring against the live `Property_Asset__r.Target_Sale_Price__c`). Stories 13 and 66 are **consciously not-built**, not overlooked. |
| **A2** | Broker-clock rungs Week 1 vs Week 2 (story 30) | **CHANGE TO WEEK 2 / 4 / 6.** This is the **fourth** revision of these thresholds. `DispositionTractionService`'s header must record it as a decision made on 2026-08-31, in the same retract-in-place style it already uses for the 2026-08-21 revision — a future reader must not be able to re-derive a different number from any document. |
| **A3** | Two disagreeing readiness-band definitions (stories 11, 62) | **DAYS-TO-PEAK IS CANONICAL.** `SellMeterService.bandForPeak` (≤30 GREEN / ≤90 YELLOW / else RED) is the single definition. `Property_Asset__c.Sell_Readiness_Band__c` and both dashboard donuts must be repointed off `Argus_Signal__c` so Home and the Dashboard can no longer disagree. |
| **A4** | One permission set vs the persona split (story 8) | **KEEP THE PERSONA SPLIT** (`DPEG_Disposition_View` / `_Edit` / `_App_Disposition`); no Permission Set Group. Close the real gaps instead: read-only `Property__c`, `Property_Asset__c`, `Offering__c`, `Transaction__c`; Argus/CoStar read-only everywhere, including fixing `Disposition_Dashboard_Access`'s editable `Argus_Value__c`. Amend the AC to "one set per persona". |
| **C1** | Where Call For Offers Date and Days On Market live (stories 3 vs 5) | **BROKER LISTING OWNS BOTH.** Convert `Broker_Listing__c.Days_On_Market__c` from a plain Number to a live formula off `List_Date__c`, and retire the duplicate formula on `Disposition__c`. A sale can carry more than one listing after a broker replacement, so these facts belong to the listing. |
| **D1** | Generic `Approval__c` object (story 51) | **KEEP NATIVE.** No shadow object. Build the genuinely missing **Approval #3 (NDA issue)** plus `NDA__c.Principal_Approved__c` + its date, and extend `DispositionApprovalHistoryService` so all five types appear in the existing consolidated card. |
| **D2** | Save-blocking wire validation rule (story 46) | **KEEP PROGRESSIVE SAVE** and the 4/6 counter; the stage gate and `Closing_Approval`'s entry criterion remain the real gate. Close the actual hole instead: `Wire__c.Verified_DateTime__c` is `editable=true` with no validation rule and **can be backdated today** — make it non-editable and stamped only by `WireService`. |
| **D4** | Rebuild the surfaces UAT deleted on 2026-08-21 (stories 34, 35) | **EXISTING BADGE IS ENOUGH.** The 2026-08-21 removal stands: no band pill, detail line, clock bar or milestone list returns to `listingAlerts`, and `Offer_Financing_Type__c` stays off the offer-selection screen. Story 34 is satisfied by the badge already on `brokerListing`'s header. ⚠ Story 35's *other* ACs (showing Earnest Money / Due Diligence Days / Closing Period in the comparison) were never part of the UAT removal and remain in scope. |

Second round, also USER-CONFIRMED 2026-08-31:

| Ref | Conflict | Decision |
|---|---|---|
| **E1** | Story 15 — the approving principal picks On-Market / Off-Market on the approval screen | **KEEP THE CHOICE AT INITIATE.** The submitter picks in `sellMeterInitiateModal`; the approval stays a straight approve/reject. Amend the AC. Rationale carried forward: the record is `AdminOnly`-locked while pending, and creating with an unset record type reproduces exactly the Master/unset state that caused the C-2 defect in the 2026-08-19 redesign. |
| **E2** | Story 23 — auto-populate the NDA template with party name and property address | **DEFERRED — "leave NDA template for now."** No document generation and no template field-stamping is built in this programme. ⚠ Note the split: the *Approve* half of story 23 (`Principal_Approved__c` + date, and Approval #3) is a **separate, confirmed D1 decision and REMAINS IN SCOPE**. Only the template-population half is deferred. |
| **E3** | Story 7 — party type "Connecting Broker" vs "Introducing Broker" | **KEEP `Introducing Broker`.** Amend the story. No picklist surgery, so the standing grep-repo-and-query-org sweep is not triggered. |
| **E4** | Story 1 — four nav tabs vs the five the app carries | **KEEP THE REPORTS TAB.** The Disposition folder holds 13 reports and needs an entry point. Amend the AC to list five tabs. |
| **D3** | Story 2 — separate page layouts per record type | **KEEP THE LWC APPROACH.** Stage-specific screens stay driven by `dispositionMain` / `dispositionSidebar` routing plus FlexiPage visibility rules, which is finer-grained than a per-record-type layout. Amend the AC. |

### Gate 1 (Tranche 1 design) — USER-CONFIRMED 2026-08-31

Design: `agent-output/disposition-gap-closure-t1-design.md`. The design pass **falsified six of the
premises this analysis handed it**; two would have produced a broken deploy. Corrections recorded
here so the gap analysis above is not read as still-true:

- **Item 6 is delete + create, not an edit.** Salesforce cannot convert an existing field into a
  Formula, and the retired API name stays reserved until manually ERASED in Setup. The consumer list
  in this document was also incomplete: `DPEG_Disposition_Edit` grants
  `Broker_Listing__c.Days_On_Market__c` as `editable=true`, **which is a deploy error on a formula
  field**, and three seed scripts assign it. Retiring `Disposition__c.Days_On_Market__c` is
  separately blocked — `Avg_Days_on_Market` is a `Disposition__c` report type and cannot render a
  `Broker_Listing__c` field. **Retirement is deferred out of T1.**
- **`BovSubmissionTrigger` refuses `after undelete` in writing** (2026-08-24), and
  `DispositionOfferTrigger` lacks three of the four contexts the counters need.
- **`required=true` forces `deleteConstraint Restrict`**, which `BOV_Score__c`'s null-chain guard
  depends on, and reds nine `TestDataFactory` call sites.
- **`Release_Materials_Response__c` is broker-scoped, not buyer-scoped** — no `Buyer__c`, no
  `NDA__c` lookup. Story 28's implied overlap with `Buyer_Response_Date__c` does not exist; the two
  are complementary.
- **Item 11 is inverted:** the disposition sets grant *none* of the 10 Argus/CoStar fields today, so
  10 of 11 changes are a **new read-only grant**, not a downgrade. Only
  `Disposition_Dashboard_Access.Argus_Value__c` is a true downgrade.

| Ref | Decision |
|---|---|
| **D-1** | `Is_Approved_For_Release__c` is a **FORMULA** checkbox, `ISPICKVAL(Status__c,'Signed')` — no counter-signature, consistent with decision Q6. Cannot latch; a Declined NDA reads FALSE automatically. |
| **D-2** | T1 ships `Buyer_Response_Date__c` **field + FLS only**; the `dispositionBuyerTimeline` read is deferred (a `USER_MODE` selector widening on a card that deliberately does not fail soft). |
| **D-3** | **Ship the live formula now**, documented in its own XML as **RAW ELAPSED DAYS, not the escalation clock**. `DispositionTractionService` remains the clock's owner; nothing may read the formula to drive an alert. A third days-on-market definition now exists deliberately. |
| **D-4** | New field name: **`Days_On_Market_Live__c`** (Number formula, scale 0) on `Broker_Listing__c`. |
| **D-5** | `BovSubmissionTrigger` gains `after undelete`, routing **only** the counter recompute — never `BovAutoSelectionService`. Its 2026-08-24 refusal is retracted **in place**, not deleted. |
| **D-6** | Item 8 ships as a **VALIDATION RULE, not `required=true`**, keeping `deleteConstraint SetNull` (precedent: `BOV_Submission__c.Broker_Required_On_Submission`). ⚠ Does not literally satisfy story 3's "required lookup" wording. The 9 test call sites need repair either way. |
| **D-7** | Record-type lock boundary: **changeable only at `Disposition Readiness`**, locked from `BOV Outreach` onward. Admin escape is the new custom permission `Disposition_Record_Type_Override`, gated `NOT($Permission...)` — a validation rule is **not** bypassed by Modify All Data. |
| **D-8** | Boolean naming follows **ARCHITECTURE.md §1**: `Is_Approved_For_Release__c`, `Is_Buyer_Ready__c`, `Is_Known_Performer__c`, with labels "Approved for Release" / "Buyer Ready" / "Known Performer" so BA-facing surfaces read as the stories ask. `Principal_Approved__c` already conforms. |
| **D-9** | Both counters count **all** child rows regardless of status (story 37 keeps Rejected/Countered/Withdrawn visible). Default 0. |
| **D-10** | The counter's parent write is `SYSTEM_MODE` **inside a narrow `private without sharing` inner class**. `SYSTEM_MODE` lifts CRUD/FLS but never sharing, and `viewAllRecords=true` is READ, not WRITE. |
| **D-11** | IR hand-off grant is a **named minimal field set**, not all 84 fields on the four objects. |
| **D-12** | Wire timestamp: **remove the editable grant AND add a validation rule**, with a 1-minute tolerance window. The naive VR shapes each break `WireService.saveWire`. |
| **D-13** | Retrieve and diff the org's `Disposition__c` list views **before** writing any — a source list view whose `fullName` collides silently replaces the hand-made org one. |

Adopted without a separate question, as recommended and unopposed:

| Ref | Decision |
|---|---|
| **B1** | The story and FSD §19.3 are **wrong**; `Offer_Status__c` and `Offer_Financing_Type__c` stay two separate fields. Correct the story, not the code. |
| **B2** | **No rename.** `BOV_Submission__c` keeps its name; the 3 stale `.claude/agent-memory/` files that still say `BOV_Response__c` get corrected. |
| **B3** | Story 32's "spelled out in full, never abbreviated" is **already satisfied** — every rendered label reads "Call for Offers"; `CFO` appears only in JS constants and test titles. No work. |

---

## Conflicts with decisions already taken — raise with the BA, do not silently "fix"

| Story | The story asks for | What was decided, and when |
|---|---|---|
| 13 / 66 | Freeze NOI / peak / projected / target at initiate | 2026-08-24 — `Asking_Price__c` retired from the initiate flow; BOV score repointed to the **live** asset target price |
| 30 | Week **2** / 4 / 6 broker-clock rungs | 2026-08-21 — user settled the **third** dispute on these numbers as Week **1** / 4 / 6, explicitly overriding `DPEG-Stage-by-Stage.docx` |
| 34 | "Week 4 — At Risk" badge on the Active Listing screen | 2026-08-21 UAT deleted the band pill, detail line, clock bar and offer count from `listingAlerts` ("we don't need listing traction") — the label survives in one place only |
| 35 | Offer Financing Type in the comparison view | 2026-08-21 UAT removed it from the offer-selection screen ("No need to show financing not started") |
| 6 / 35 | `Offer Financing Type` = Received/Countered/Accepted/Rejected | **The story (and FSD §19.3) is wrong** — the repo correctly splits status from financing type. Recommend correcting the story. |
| 4 | Object named `BOV_Response__c` | Built as `BOV_Submission__c`; three stale `.claude/agent-memory/` files still say otherwise and should be corrected either way |

---

## 🔴 OPEN VERIFICATION DEBT — carried forward from Tranches 1 and 2

**User decision 2026-08-31: proceed to Tranche 3; seed and browser-verify later.**

Both tranches are **deployed and structurally verified** (T1 `0Afiw000000UCLVCA4`, T2
`0Afiw000000UJwTCAW` — 67 components, 399 tests, zero coverage warnings between them, every field
and grant read back server-side). Neither has been **seen**.

### Why: the org has no data behind these features

Measured on `usman-dpeg` 2026-08-31, immediately after the T2 deploy:

| | |
|---|---|
| `Property_Asset__c` total | **1** |
| Property Assets **on the Sell Meter** (`Property__c != null AND Peak_Sell_Date__c != null`) | **0** |
| `Property__c` | 6 |
| `Disposition__c` | **0** |

The Sell Meter home page therefore renders **zero rows**, and no disposition record page, dashboard
KPI or approval path has a record to run against.

⚠ **This also retires a number quoted earlier in this document and in the T2 design.** The
"Portfolio Upside drops 75-80% under green-only" estimate derived from
`scripts/seed-asset-sell-signals.apex`, whose own header contradicts itself (`6/6/11` on one line,
`5/7/11` implied on another). There is **no population to drop**. Do not re-quote that figure.

### What remains unverified, and why review cannot discharge it

Tranche 1 proved the cost of assuming: a `ListView` Checkbox filter using `true` instead of `1` was
valid XML, a real field and a valid operator, and passed **two full code-review passes** — only a
deploy found it. Everything below is that same class of risk.

- **Sell Meter card** — nine columns at the `Sell_Meter.flexipage` region2 width; the sort affordance
  rendering AND responding (`sellMeter` is a **custom `pill` column type** now marked `sortable`, a
  combination never rendered anywhere); five stat tiles across the region1 header band including the
  3+2 wrap below 1280px.
- 🔴 **The disabled Override state as a REAL non-principal.** An admin smoke test proves nothing —
  Modify All Data bypasses the gate entirely.
- **Both dashboard donuts, "Avg Sell Readiness", and "Sell Readiness by Property Type"** — a report
  grouping on a changed formula produces **no metadata diff at all**.
- **The six Tranche 1 list views** rendering, alongside the two pre-existing hand-made org views
  (`Dispostion`, `Dispostions` — both misspelled, both survived the deploy).
- **The band's daily drift** — now a function of `TODAY()`, so five reports and both donuts change
  day to day with no record edit and no audit trail. Correct and intended; needs to be seen once and
  explained to the BA.

### Two open questions a real run has still not answered

1. Whether the `Property_Asset__c` SetNull cascade reaches `DispositionCounterRollupService.recordFailures`
   in production. The T1 test deliberately does not answer it, so that class header's "expected
   refusal #1" remains an **unverified claim**.
2. Whether a blank override reason can reach the server. It is **client-enforced only** — argued
   explicitly in `DispositionService.initiateAndSubmit`'s header, not an oversight.

### Owed to Tranche 3
`Disposition__c.Sell_Meter_Override_Reason__c` is **not** on `Sale_Decision_Approval`'s
`approvalPageFields`. Deferred from T2 because approvals are T3's boundary and an active approval
process may need deactivate/reactivate to accept the change.

---

## 🔴 CORRECTION TO THIS DOCUMENT — story 19 was assessed WRONG (2026-09-01)

**Story 19 (auto-build the comparison matrix at 3+ responses) is marked 🟡 above with "There is
no 3-response threshold and no 'Matrix Generated ✓' status." BOTH HALVES ALREADY EXIST.**

- `BovController.getOutreachSummary:154` computes `s.matrixGenerated = s.responsesReceived >= 3`.
- `bovOutreach.html:12-14` renders the literal `Matrix Generated ✓` badge.
- Both are pinned by two Jest tests.

**Why the original audit missed it.** The story names the *comparison matrix*, so the audit looked in
`bovComparisonMatrix`. The threshold and the badge live in the **sibling card `bovOutreach`**,
rendered by `dispositionSidebar` on the BOV Outreach stage. Looking in the component the story names
was reasonable and still produced the wrong answer — a reminder that in this codebase a story's
subject and the component that implements it are frequently not the same bundle.

**The real gap is narrower and was invisible from the story text.** The badge counts **every** child
row — including the preferred broker, per Tranche 1 decision D-9 ("both counters count all child rows
regardless of status") — while the matrix itself **excludes** the preferred broker. So
"Matrix Generated ✓" can sit above a two-row comparison table. That is the only thing worth building
for story 19, and it is a consistency fix, not a feature.

## Three further premise corrections from the Tranche 4 design

1. 🔴 **Story 31's "restart the Active Listing clock" is built on a false premise in this document.**
   `DispositionTractionService` measures from **`Disposition__c.Listing_Date__c`**, not
   `Broker_Listing__c.List_Date__c` as stated above. Two class headers refuse the child-date reading
   in capitals, naming this exact button — `BrokerListingController:164-168`: *"keying on the child
   would silently restart the six-week clock the moment a broker was replaced — which, now that this
   card carries a Replace Broker button, is one click away rather than hypothetical."* The repo has
   already designed the alternative: a deliberate broker change **appends** a listing, and
   `Days_On_Market_Live__c` (shipped in T1, already selected, already granted) is currently unread.
2. ⚠ **A `BOV_Score__c` formula change re-ranks READS, not APPOINTMENTS.** `Submission_Status__c` is
   *stored*; `BovAutoSelectionService.reselect` fires on six change keys and **a deploy is not one of
   them**. So a new top scorer would sit beside a stale `Selected` pill indefinitely until something
   re-saves the row. A manually-appointed broker **is** protected — the lock is per-disposition,
   evaluated across all siblings.
3. ⚠ **Replace Broker also fires at BOV Outreach**, and `openBrokerListings`' idempotency test is
   simple presence — so a listing created at BOV Outreach makes the Active Listing auto-create a
   **permanent silent no-op**. That negative is the highest-value test in story 31.

⚠ Also: this document attributes Replace Broker to `brokerReplaceQuickAction`. That component is
bound to **`Broker_Assignment__c`** — a Property Management feature on a different object. The
disposition-side action is `BovSubmissionService.replaceSelectedBroker` via `bovReplaceBrokerModal`.
