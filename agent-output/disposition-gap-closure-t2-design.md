# Disposition BA Gap Closure — TRANCHE 2 Design (Sell Meter / Home page)

**Date:** 2026-08-31
**Agent:** salesforce-design (analysis only — no metadata, no Apex, no org writes)
**Branch at time of writing:** `qa/lifecycle-simulation-2026-08-27`
**Scope:** exactly the five numbered items in the request. Nothing added, nothing expanded.
**Sources read, in the order requested:** `agent-output/disposition-ba-stories-gap-analysis.md`
(including the USER-CONFIRMED conflict resolutions A1-A4/C1/D1-D4/E1-E4/B1-B3 and the Gate 1
record, all treated as settled decisions), `agent-output/disposition-gap-closure-t1-design.md`
(DEPLOYED, `0Afiw000000UCLVCA4`), `ARCHITECTURE.md`, `CLAUDE.md`, `.claude/rules/*.md`.

---

## 0. Mandatory gate declarations

```
intent=type | best_matched_skill=none (design step only — no metadata generated here)
skill_selection=complete
mcp=unavailable | mcp_tools=none
```

`.claude/rules/salesforce-global-rule.md` mandates a `salesforce-api-context` MCP call per metadata
type. **A real attempt is not possible from this agent** — `.mcp.json` configures only the
`salesforce` server and subagents carry no MCP tools. Recorded `mcp=unavailable`, `mcp_tools=none`.
Every implementing agent must re-attempt and re-record per metadata type and fall back to the
per-type skill.

**Consequence carried into the plan:** any XML shape not already exercised in this repo is a
**blocking gate with a one-item dry-run and a readback**, never a guess. Two shapes qualify here —
**G-3** (`formulaTreatBlanksAs` on a Date-referencing Text formula) and **G-6** (the ordering
constraint between a new `CustomPermission` and the `customPermissions` entry that names it).

---

## 1. Premise verification — measured against the repo before designing

Fourteen load-bearing claims were checked against the tree. **Nine hold. Fourteen findings below are
new, incomplete or wrong in the request in a way that changes the design.** They lead, because they
drive every recommendation that follows.

### 1.1 CONFIRMED

| Claim | Evidence |
|---|---|
| `SellMeterService.bandForPeak` is `<=30` GREEN / `<=90` YELLOW / else+null RED, and is the single function shared by the read path and the write gate | `SellMeterService.cls:50-61`; `SellMeterController.cls:66,109`; `DispositionService.cls:319`, `:437` |
| `SellMeterController.getMeterSummary` sums `implied - target` for **every** in-the-money asset regardless of band | `SellMeterController.cls:74-82` — the band `if/else` at :67-73 and the upside `if` at :75 are siblings, not nested |
| `PropertyRow.meterScore` is computed (`impliedValue / targetPrice`) and never rendered | `SellMeterController.cls:114`; `sellMeterList.js:25-42` COLUMNS has no `meterScore` entry |
| `lwc/sellMeterList.allRows` force-orders by `METER_ORDER` and splices the first RED row into the last page-1 slot | `sellMeterList.js:84-97` |
| No column is `sortable`; there is no `onsort` handler | `sellMeterList.js:25-42`, and no `handleSort` in the file |
| `lwc/sellMeterList` has **no permission check of any kind**; label/enablement derive from the band alone | `sellMeterList.js:114-117` |
| `_confirmOverride` uses `LightningConfirm` (Promise&lt;boolean&gt;) and its header records "there is still no override REASON field … a deliberate scope decision, not an oversight" | `sellMeterList.js:273-292` |
| The LWC's three band labels are byte-identical to the formula's three output strings | `sellMeterList.js:16-18` `Sell now` / `Getting Close` / `Hold - Not yet` vs `Sell_Readiness_Band__c.field-meta.xml:5` |
| `Property_Asset__c` is shared with Property Management, and `Sell_Readiness_Band__c` / `Argus_Signal__c` are granted across modules | permission-set grep, §1.2 P-1 for the corrected list |
| Nothing in this tranche's blast radius is force-ignored (`objects/Property_Asset__c/**`, `reports/Dispositions/**`, `dashboards/Dispositions/**`, `permissionsets/**`, `lwc/**`, `classes/**`, `customPermissions/**` all deploy) | `.forceignore` — checked by grep, no match for any of them |

### 1.2 🔴 FOURTEEN FINDINGS THAT CHANGE THE DESIGN

---

**P-1. The band formula's consumer list is larger than the request states — SIX permission sets and
FOUR reports, not "both dashboard donuts" and four sets.**

`Property_Asset__c.Sell_Readiness_Band__c` is granted `readable=true, editable=false` by **six**
permission sets, not four:

| Set | Band | `Readiness_Score__c` | `Argus_Signal__c` | `Peak_Sell_Date__c` |
|---|---|---|---|---|
| `Disposition_Dashboard_Access` | ✅ RO | ✅ RO | ❌ | ❌ |
| `DPEG_Disposition_View` | ✅ RO | ✅ RO | ✅ RO | ❌ |
| `DPEG_Disposition_Edit` | ✅ RO | ✅ RO | ✅ RO | ❌ |
| `DPEG_PropertyAsset_View` | ✅ RO | ✅ RO | ✅ RO | ✅ RO |
| `DPEG_PropertyMgmt_View` | ✅ RO | ✅ RO | ✅ RO | ✅ RO |
| `DPEG_PropertyMgmt_Edit` | ✅ RO | ✅ RO | ✅ **RW** | ✅ **RW** |

And **four** reports group by the band, not two:

| Report | Role | Grouping | Also carries |
|---|---|---|---|
| `Dispositions/Readiness_Mix` | Donut "Readiness Signal By Count" | `Sell_Readiness_Band__c` | `Argus_Signal__c` as a column |
| `Dispositions/Readiness_Signal_By_Value_Avk` | Donut "Readiness Signal By Value" | `Sell_Readiness_Band__c` | `Argus_Signal__c` as a column |
| `Dispositions/Portfolio_Sell_Readiness` | **Metric "Avg Sell Readiness"** | `Sell_Readiness_Band__c` | avg of `Sell_Readiness_Score__c` |
| `Dispositions/Total_Argus_Value` | (report only, no dashboard component found) | `Sell_Readiness_Band__c` | — |

✅ **Good news buried in this:** the dashboard names the field, not a value —
`Disposition_Dashboard_Junior.dashboard-meta.xml:136,174` carry
`<groupingColumn>Property_Asset__c.Sell_Readiness_Band__c</groupingColumn>`. **Repointing the
formula requires no dashboard edit and no report edit at all**, provided the output strings are
preserved. That is the entire reason the strings are load-bearing, and it is worth stating in the
prompt so nobody "tidies" them.

---

**P-2. 🔴 A3's stated goal — "so Home and the Dashboard can no longer disagree" — is NOT achieved by
repointing the formula. Three independent disagreements exist and item 1 closes only one of them.**

| Disagreement | Home page | Dashboard | Closed by item 1? |
|---|---|---|---|
| **Band definition** | `bandForPeak(Peak_Sell_Date__c)` | `CASE(TEXT(Argus_Signal__c), …)` | ✅ **yes** |
| **POPULATION** | `WHERE Property__c != null AND Peak_Sell_Date__c != null` — **no `Status__c` filter**, so a Disposed asset stays on the meter (story 49's open gap) | `WHERE Status__c = 'Active'` — **no peak/property filter**, so an asset with no peak date is counted | ❌ **no** |
| **The "Sell Ready" KPI** | `sellMeterStats` "Sell now" count = GREEN band | `Dispositions/Sell_Ready_Argus`, which **filters `Argus_Signal__c equals 'Sell Now'`** and groups by `Argus_Signal__c`. It is not a band consumer at all, and it has **no `Status__c` filter either** | ❌ **no** |

Evidence: `PropertyAssetSelector.cls:69,93`; `Readiness_Mix.report-meta.xml:8-13`;
`Sell_Ready_Argus.report-meta.xml:6-20`.

So after item 1 ships exactly as scoped, a principal comparing the Home cards to the dashboard
donuts will **still** see different numbers, and the "Disposition Readiness" KPI tile will still be
Argus-driven. That is not a reason to widen the tranche unilaterally — it is a **Gate 1 decision**
(**D-3**). What must not happen is shipping item 1 and reporting A3 as closed.

---

**P-3. ✅ Item 1 is an IN-PLACE formula edit — unlike Tranche 1's item 6, and the contrast matters.**

T1's P-1 established that Salesforce cannot convert an existing field **into** a Formula, making
that item a delete + create with a reserved API name. **That does not apply here.**
`Sell_Readiness_Band__c` and `Readiness_Score__c` are **already formula fields**
(`<formula>` present, no `<defaultValue>`, no stored type). Changing a formula's *expression* in
place is legal and is a single-component deploy. The return type must not change (Text stays Text,
Number stays Number) — and it does not need to.

Consequence: **no additive-deprecation pattern, no new API name, no ERASE step, no seed-script
compile breakage, no `editable=true` deploy error.** Item 1 is dramatically cheaper than T1 item 6
looked. Do not import that item's machinery.

---

**P-4. 🔴 The "em-dash" branch is neither an em dash nor a survivor — and both halves are visible
behaviour changes.**

The current formula's else-branch is, after XML unescaping, the **literal six-character string**
`&#8212;` — an unresolved HTML entity, not `—`. Reports and dashboard legends render text, not HTML,
so today's null-Argus donut segment is almost certainly **labelled `&#8212;` on screen**. That is a
pre-existing cosmetic defect, not something this tranche introduces.

More importantly, **under days-to-peak the fourth branch becomes unreachable**: `bandForPeak` returns
one of exactly three values and maps `null` to RED. So:

1. the `&#8212;` donut segment **disappears entirely**, and
2. **every asset that currently sits in it moves into `Hold - Not yet`**, changing both donuts' counts
   and the "Avg Sell Readiness" metric's grouping.

Both are correct under A3 and both are user-visible. They must be stated to the BA before deploy, not
discovered on the dashboard.

---

**P-5. 🔴 `Disposition_Deal_Actions` IS THE WRONG TOKEN FOR ITEM 5(a) — reusing it would invert the
AC exactly.** This is the single most consequential correction in this document.

The request cites `Disposition_Deal_Actions` + `DispositionActionPermissionService` as the in-repo
precedent. The *shape* is right. The *token* is precisely backwards:

- `customPermissions/Disposition_Deal_Actions.customPermission-meta.xml:102-105` carries a red
  banner: *"🔴 `DPEG_Disposition_View` DOES NOT AND MUST NOT CARRY THIS PERMISSION. Principals hold
  the View set and APPROVE dispositions; granting it there would put the submit and advance buttons
  in front of the approvers of those submissions. The two disposition sets are deliberately
  asymmetric on this grant."*
- The grant lives in `DPEG_Disposition_Edit:1262-1265` — the **Analyst** set — and via
  `DPEG_Junior_Analyst_PSG` the whole junior-analyst population holds it.

So gating the Override on that token would show it to **analysts** and hide it from **principals** —
the exact inverse of stories 12 and 14.

Two further constraints on the mechanism:

- `DispositionActionPermissionService.cls:10-14` states *"🔴 THE TWO CLASSES ARE ONE DESIGN ON TWO
  MODULES — CHANGE BOTH OR NEITHER"* (its twin is `OpportunityActionPermissionService`). **That class
  must not be modified.** A new, separately-named service is required.
- `sellMeterList.js:265-268` records why it does not import `c/dealActionGuard`: *"that util imports
  an Opportunity permission controller at module scope, which would give the Disposition dashboard a
  hard dependency on an Opportunity gate for ten lines of code."* That reasoning still holds — do not
  reuse `c/dealActionGuard` or `c/recordStageGuard` here.

⇒ Item 5(a) needs a **new custom permission**, a **new permission service**, and a **new cacheable
controller method**. See **D-8**.

---

**P-6. 🔴 `DispositionService` carries a recorded REFUSAL to assert a permission on the create paths
— and its own pre-written condition for flipping that refusal is exactly what item 5(a) does.**

`DispositionService.cls:55-91` argues at length that neither `findOrCreate` nor `initiateAndSubmit`
asserts `Disposition_Deal_Actions`, and gives the surviving reason:

> *"1'. … `DPEG_Principal_PSG` carries … `DPEG_Disposition_View` — the READ-ONLY disposition set,
> which does NOT carry the token. A Principal can therefore open the Sell Meter and would be NEWLY
> DENIED by an assert here … 2'. ⚠ THE MARGIN IS NARROWER THAN IT WAS … **If `DPEG_Disposition_View`
> ever gains the token, or the Principal is meant to be refused the create, the assert becomes
> correct and should be added on BOTH create paths at once — not on one.**"*

And `initiateAndSubmit`'s own header (`:390-394`) repeats it: *"THERE IS NO
`assertDispositionActionAccess()` AT THE TOP OF THIS METHOD AND THAT IS A DECISION, NOT AN
OMISSION … Adding one here closes the Sell Meter for every junior analyst."*

Two consequences the request does not name:

1. **The assert must NOT be method-wide.** A blanket assert on `initiateAndSubmit` would close GREEN
   Initiate to analysts, which no story asks for. The gate must fire **only on the YELLOW branch** —
   which the server can already derive, because it computes the band itself at
   `DispositionService.cls:437`. No new parameter, no client-supplied trust.
2. **`findOrCreate` is a second, live `@AuraEnabled` bypass.** `DispositionController.findOrCreate`
   (`:69`) is still exposed, still creates on YELLOW with no confirmation and no modal, and the class
   header says it "has other callers". No LWC calls it today, but it is reachable. Per the header's
   own instruction ("on BOTH create paths at once — not on one"), the YELLOW assert belongs on both.

---

**P-7. 🔴 A structured override-reason field ALREADY EXISTS, is ALREADY ON THE APPROVAL SCREEN, and
ALREADY LIES on every override.**

`Disposition__c.Sell_Decision_Trigger__c` is a **restricted picklist** with values
`Sell Meter Green` (**`default=true`**), `Principal Decision`, `Fund Maturity`, `Market Opportunity`.
It appears in `approvalProcesses/Disposition__c.Sale_Decision_Approval.approvalProcess-meta.xml:149`
as an `approvalPageFields` entry — so the approving principal sees it on the approval screen.

**Nothing writes it.** A repo-wide grep (excluding force-ignored `profiles/**`) finds it only in:
the approval process, `manifest/package.xml`, the two record types (enumerated in full), the two
permission sets, an objectTranslation, and a comment in `dispositionSidebar.test.js`. There is no
Apex, flow or trigger writer.

⇒ **Today, a disposition created by pressing Override on a YELLOW asset arrives at the approver
showing "Sell Meter Green".** That is a live defect, and setting this field on the override path is
the highest-value, lowest-cost half of item 5(b) — **it needs no new field and no picklist surgery**,
because `Principal Decision` already exists on both record types.

⚠ If a *new* value were added instead, it would require editing **both** `recordTypes/On_Market.xml`
and `recordTypes/Off_Market.xml` (each file's own comment says a record type must enumerate every
picklist or values are silently dropped), restricted picklists **are** DML-enforced in this org, and
record-type-before-Apex deploy ordering would become mandatory. Reusing `Principal Decision` avoids
all of it.

---

**P-8. 🔴 Item 2's existing test PASSES VACUOUSLY under the change. It ships with no regression net
unless a new fixture is added.**

`SellMeterControllerTest.cls:37-41,107-110`: four assets, all `NOI=1,000,000 / Cap=5.0 →
implied 20,000,000`; **only Asset 0 is in the money** (target 18M) and Asset 0 is the **GREEN** one
(peak in 15 days). The assertion is `System.assertEquals(2000000, s.upside, …)`.

Green-only summing produces **the same 2,000,000**. The test is green before and after and proves
nothing. Item 2 must add an **in-the-money YELLOW (and/or RED) asset whose upside must now be
excluded** — otherwise the behaviour change has no test at all.

---

**P-9. 🔴 "Story 10 lists Calculated Value as a column" is not what the gap analysis says.**

`agent-output/disposition-ba-stories-gap-analysis.md` §10 lists story 10's column AC as
*"Property / NOI / Market Cap Rate / Target Sale Price / Peak Sell Date / Projected Value /
Sell Meter / Action"* — verdict **✅ built** — and carries *Calculated Value = NOI ÷ cap rate* as a
**separate AC already marked ✅** ("computed server-side (`impliedValue`)"). Calculated Value is
**not** in the column list, and its AC is **not** an open gap.

⇒ Surfacing `impliedValue` as a ninth column is **new scope**, not gap closure. Raised as **D-5**,
recommendation: **do not build it**.

---

**P-10. 🔴 Item 4's naive form produces lexicographic nonsense — every sortable-looking column's
`fieldName` points at a PRE-FORMATTED STRING.**

✅ The mechanism works: `lwc/listDatatable` is `class ListDatatable extends LightningDatatable`, so
`sortable` / `sorted-by` / `sorted-direction` / `onsort` are all inherited. But
`lightning-datatable` **does not sort data itself** — it raises `onsort` and the parent must sort.
And in `sellMeterList.allRows` the row fields bound to columns are:

| Column | `fieldName` | Value shape | Naive sort result |
|---|---|---|---|
| Property | `recordUrl` | `/lightning/r/Property_Asset__c/<Id>/view` | sorts by **record Id** |
| NOI | `noiLabel` | `'$2.0M'` | `'$10.0M' < '$2.0M'` — **wrong** |
| Mkt Cap | `capRateLabel` | `'6.5%'` | string, breaks at 10% |
| Target Price | `targetLabel` | `'$30.0M'` | same as NOI |
| Peak Sell Date | `peakDateLabel` | `'Jan 1, 2020'` | sorts **alphabetically by month name** |
| Projected Value at Peak | `peakValueLabel` | `'$34.0M'` | same as NOI |
| Sell Meter | `sellMeter` | `'Sell now \| 12d'` | alphabetical, ignores band order |

The in-repo precedent is `lwc/loiCounterOffer` (`:47-112` columns, `:269-283` sort), which keeps
**raw** values on the row for numeric/date columns and remaps `recordUrl → name`:

```js
const field = this.sortedBy === 'recordUrl' ? 'name' : this.sortedBy;
```

`lwc/releaseMaterialsResponseLog:126-132,237,463-474` is the deliberate counter-precedent (no
`sortable`, because the server owns the order) and explains the trap in terms.

---

**P-11. 🔴 The RED-splice hack — the "existing deliberate behaviour" item 4 conflicts with — is
COMPLETELY UNTESTED today.**

`lwc/sellMeterList/__tests__/sellMeterList.test.js` has two fixtures:
- `PORTFOLIO` — **3 rows**, so page 1 already contains the RED row and the splice branch at
  `sellMeterList.js:91-97` is never entered;
- `SIX_GREEN` — six GREEN rows, with the comment *"(no RED -> no page-1 reorder)"*.

No test drives ≥6 rows with a RED beyond index 4. So the hack has **no regression net**, and any
change to it will pass the suite silently. The `DATA BRANCH` test (`:333-362`) *does* pin the band
ordering `['Gateway Plaza','Harbor Point','Cedar Commons']` — that assertion survives if the default
(unsorted) view keeps band order.

---

**P-12. 🔴 The disposition permission sets do NOT grant six of the `Property_Asset__c` fields the
Sell Meter reads. The page works only because both persona PSGs also carry a PROPERTY MANAGEMENT
set.**

`PropertyAssetSelector.selectAllForMeterSummary` / `.selectAllForPortfolio` are `WITH USER_MODE` and
read `NOI__c`, `Market_Cap_Rate__c`, `Target_Sale_Price__c`, `Peak_Sell_Date__c`,
`Projected_Value_At_Peak__c`, `Property__c` (the last also in the **WHERE clause**, which
`USER_MODE` enforces FLS on) plus `Property__r.Asset_Type__c` and `Argus_Signal__c`.

Neither `DPEG_Disposition_View` nor `DPEG_Disposition_Edit` grants **any** of those six. T1's item-10
pass granted eight `Property_Asset__c` fields — `Argus_Signal__c`, `Argus_Value__c`,
`Property_Name__c`, `Property_Type__c`, `Readiness_Score__c`, `Sell_Readiness_Band__c`,
`Sell_Readiness_Score__c`, `Status__c` — and **none of the six the Sell Meter actually queries**.

It works today because **both** relevant permission set groups also carry `DPEG_PropertyMgmt_View`,
which grants all 17 `Property_Asset__c` fields:

- `DPEG_Principal_PSG` → `DPEG_PropertyMgmt_View` ✅
- `DPEG_Junior_Analyst_PSG` → `DPEG_PropertyMgmt_View` ✅

⚠ Two things follow. First, **the Disposition Sell Meter has an undocumented hard dependency on a
Property Management permission set**; trimming PM access from either group takes the Home page down
with a red banner, not a degraded render (`USER_MODE` throws, it does not degrade). Second,
`DispositionService.cls:81` describes `DPEG_Principal_PSG` as carrying *"`DPEG_Apex_Access`,
`DPEG_App_Disposition` and `DPEG_Disposition_View`"* — that is 3 of its 13 members and omits the one
that makes the page work. **Class headers can be wrong; this one is.**

✅ **The good consequence for this tranche:** items 2 and 3 read only fields already in the SELECT, so
**neither widens a `USER_MODE` query and neither is an FLS change.** Item 1 changes a formula's
referenced field, and **formula evaluation does not enforce FLS on referenced fields** — so
`Disposition_Dashboard_Access`, which grants the band but not `Peak_Sell_Date__c`, keeps working.
**T2 needs no `fieldPermissions` change at all except the two new artefacts in item 5.**

---

**P-13. `Argus_Signal__c` is editable in exactly ONE permission set — and it is a Property Management
one.**

`DPEG_PropertyMgmt_Edit:589-592` is the only `editable=true` grant. The disposition sets got
`editable=false` in T1's item 11. So "keep it as an analyst input" means **keep it as a Property
Management input** — the disposition analyst cannot set it today and will not be able to after this
tranche. That is a fact the BA needs, because it determines who maintains a field the dashboard's
"Disposition Readiness" KPI still depends on (P-2).

---

**P-14. `Readiness_Score__c` is NOT orphanable — it has a live dashboard consumer.**

`Dispositions/Sell_Readiness_By_Type.report-meta.xml:11-14` sums `Readiness_Score__c`, and that
report backs the dashboard's **"Sell Readiness by Property Type"** table (story 61, ✅ built).
Today `Sum(Readiness_Score__c)` = "how many Argus-Sell-Now assets of this property type". Retiring or
blanking the field silently empties a dashboard column — and reports do not block field deletion,
they break silently.

⚠ Separately: **a third readiness measure exists and is out of A3's scope.**
`Property_Asset__c.Sell_Readiness_Score__c` is a **stored Percent field**, hand-seeded (30-92) by
three seed scripts, and it is what the dashboard's **"Avg Sell Readiness"** metric averages
(`Portfolio_Sell_Readiness`). It is not derived from Argus and not derived from the peak date. A3
does not mention it. Flagged, **not in scope**.

**Also, documentation that becomes false and must be amended in place** (this repo's convention —
quote and retract, never silently edit): `scripts/seed-asset-sell-signals.apex:37-40`,
`scripts/seed-lakeline-asset-repair.apex:121-122`, and `classes/PropertyAssetService.cls:72-75` all
state the two formulas' current definitions verbatim.

---

## 2. Decisions for Gate 1

These are the only genuinely open questions. Each carries a recommendation and its evidence.
**Nothing here re-opens a USER-CONFIRMED resolution.**

| # | Decision | Recommendation |
|---|---|---|
| **D-1** | **Item 1 — the repointed `Sell_Readiness_Band__c` formula, and the fate of the 4th branch (P-4).** Under days-to-peak the else-branch is unreachable: `bandForPeak` returns three values and maps null to RED. | **Three branches, no fourth.** Mirror `bandForPeak` exactly, `null` peak → `"Hold - Not yet"`. Confirm you accept that the current fourth donut segment **disappears** and its assets move into `Hold - Not yet`. Alternative (rejected): keep a 4th `"Not modelled"` bucket for null peaks — it would make the Dashboard band-set differ from the Home band-set again, which is what A3 exists to stop. |
| **D-2** | **Item 1 — `Readiness_Score__c`: repoint, retire, or leave on Argus?** It has a live consumer (P-14). | **REPOINT, and derive it from the band field rather than re-deriving the rule:** `IF(Sell_Readiness_Band__c = "Sell now", 1, 0)`. One definition, structurally incapable of drifting from the band — the same property `SellMeterService.bandForPeak` was created to guarantee. Meaning changes from "count of Argus-Sell-Now" to "count of GREEN", which is what A3 asks for. Retiring it is refused: it would empty a live dashboard column silently. |
| **D-3** | **🔴 Item 1 — `Argus_Signal__c` itself, AND the `Sell_Ready_Argus` KPI (P-2).** After D-1/D-2 the picklist has no derived consumer, but it is still a **report filter** (`Sell_Ready_Argus`, backing the dashboard's "Disposition Readiness" tile) and a **column** on three more reports. | **(a) KEEP `Argus_Signal__c`** as a Property-Management-maintained market-data input with no derived consumer. Do **not** retire it in T2 — a retirement sweep would have to repoint one filter, four report columns, `SellMeterController.getPortfolio`'s `argusSignal` payload and its test assertion, and four seed scripts. Record the "no derived consumer" status in the field's XML comment so a future reader does not assume it still drives the band. **(b) SEPARATELY: `Sell_Ready_Argus` still disagrees with Home.** Repointing it (`Sell_Readiness_Band__c equals "Sell now"`) is one report file and finishes A3's intent — but it is **not one of the five scoped items**. Confirm whether to add it. My recommendation is **yes, add it**, because leaving it is shipping "the dashboard and Home agree" while the largest tile on that dashboard still does not. |
| **D-4** | **Item 2 — green-only, and the card label.** "Portfolio Upside" describes a portfolio-wide number; after the change it is a green-band-only number. | **Make the change, and RENAME the card to "Sell-Ready Upside"** (`sellMeterStats.js:30`). A number that quietly shrinks by ~75-80% under an unchanged label is the shape that gets reported as a data bug. Confirm the label, or confirm you want the label held. |
| **D-5** | **Item 3 — does "Calculated Value" surface? (P-9)** The gap analysis does not list it as a column and marks its AC ✅ already. | **NO.** It is new scope, and a ninth column on a 5-row card in a two-column FlexiPage region is a width problem no code review can see. If you want it, say so and it will be designed — but it should be an explicit addition, not inferred. |
| **D-6** | **Item 3 — format and null behaviour for the Sell Meter Score.** | **New column "Meter Score", `type: 'text'`, value `1.07×`** (`toFixed(2)` + `×` MULTIPLICATION SIGN), **placed immediately left of the "Sell Meter" pill**. Null → `'—'`, matching every other formatter in the component (`_fmtM`, `capRateLabel`). `meterScore` is null when NOI or cap rate is null **or** when target price is null/zero — one `—` covers all three. Confirm the label wording ("Meter Score" vs "Sell Meter Score" — the pill column is already "Sell Meter", so two columns starting "Sell Meter" read badly). |
| **D-7** | **Item 4 — sort on raw values, or convert the columns to native datatable types?** | **Sort on RAW values; keep the compact `$2.0M` labels.** Converting to `type:'currency'/'percent'/'date-local'` (the `loiCounterOffer` shape) would render `$2,000,000.00` and `1/1/2020` on the user's home screen — a visible formatting regression — and the compact labels must be kept anyway, because `sellMeterList` hands `noiLabel`/`capRateLabel`/`targetLabel`/`peakDateLabel` to `sellMeterInitiateModal` precisely so the popup and the row cannot disagree (pinned by 4 Jest assertions). Add hidden raw keys and a `SORT_KEY` map; `recordUrl → name` per the `loiCounterOffer` precedent. |
| **D-8** | **🔴 Item 4 — how sorting and the RED-splice hack are reconciled (a documented intentional feature).** | **The hack applies to the DEFAULT (unsorted) view only.** While `sortedBy` is undefined: band order + splice, exactly as today. The first user sort sets `sortedBy` and **disables both** the band ordering and the splice. Sorting also **resets the pager to page 1** (otherwise a user sorting from page 3 lands on an arbitrary window). No "clear sort" affordance unless you want one. ⚠ Confirm explicitly: **this is a behaviour change to a feature whose comment calls it deliberate** ("so the opening screen showcases all three states"), and after any sort the opening screen no longer showcases all three. |
| **D-9** | **🔴 Item 5(a) — the custom permission's NAME and its sole grantor (P-5).** `Disposition_Deal_Actions` cannot be reused; its own file forbids it on the Principal set. | **New `CustomPermission` `Disposition_Sell_Meter_Override`**, granted by **`DPEG_Disposition_View` ONLY** (the Principal persona, reaching all four principals through `DPEG_Principal_PSG`). ⚠ The name is **shorthand — flagged, not invented**; confirm or supply. ⚠ "The four principals" is a `PermissionSetAssignment` question and assignments are **not deployable metadata** — the deliverable is "whoever holds `DPEG_Principal_PSG`", and who that is must be verified in the org, not in this repo. |
| **D-10** | **🔴 Item 5(a) — where the server assert fires (P-6).** | **On the YELLOW branch only, on BOTH create paths.** `DispositionService` already computes the band at `:319` and `:437`; assert immediately after, only when the band is YELLOW. This satisfies the class header's own condition for flipping its recorded refusal, keeps GREEN Initiate open to analysts (which no story asks to close), and needs no new parameter and no client-supplied trust. Adding it to only `initiateAndSubmit` is refused by the header in terms. Confirm. |
| **D-11** | **🔴 Item 5(a) — what a NON-principal sees on a YELLOW row, and the workflow consequence.** | **A DISABLED button still labelled "Override"** — mirroring the RED "Hold" idiom already in the component, so the analyst can see the action exists and who to ask. Hiding it entirely produces a blank cell that reads as a rendering fault. ⚠ **Confirm the consequence:** after this, a junior analyst **cannot start a disposition on a YELLOW asset at all**. That is what stories 12/14 ask for, and it is a removal of a capability the analyst persona has today. |
| **D-12** | **🔴 Item 5(b) — where the override reason is CAPTURED.** `LightningConfirm` returns only a boolean (correct in the request). Two live options, both of which break existing Jest tests. | **Replace `LightningConfirm` with a new `c/sellMeterOverrideModal`** (a `LightningModal` that both asks the override question **and** collects the reason, resolving `{confirmed, reason}`). It preserves the two invariants the component's headers defend: the override question is still the **first** thing the user sees (`sellMeterList.js:180-186`), and `sellMeterInitiateModal` stays **byte-identical in its UI**, so the "deliberately identical apart from the toast title" property survives. The reason threads `overrideModal → sellMeterList → sellMeterInitiateModal (pass-through @api, not rendered) → Apex`. **Rejected alternative:** an override-only `lightning-textarea` inside `sellMeterInitiateModal` — cheaper, but it makes the two paths visibly different, reversing a recorded decision, and the modal's header says the paths must not diverge. |
| **D-13** | **🔴 Item 5(b) — where the reason is STORED.** | **Two fields on `Disposition__c`, not a log object.** (i) Stamp the **existing** `Sell_Decision_Trigger__c = 'Principal Decision'` on the override path — it already exists on both record types, already appears on the approval screen, and **currently reads "Sell Meter Green" on every override, which is false** (P-7). (ii) Add **`Sell_Meter_Override_Reason__c`**, Long Text Area, read-only FLS in **both** sets (precedent: `BOV_Broker_Change__c`'s C3 reconciliation — an audit fact the analyst who created it must not be able to rewrite). **Why not an append-only log object like `BOV_Broker_Change__c`:** that object exists because a broker can be replaced **many times** per disposition. The override happens **at most once** — both create paths early-return on an existing disposition, and the meter governs starting a sale, never reopening one. Cardinality 1 ⇒ a field on the parent, not a child table. Confirm the field name (shorthand, flagged). |
| **D-14** | **Item 5(b) — is the reason MANDATORY, and does it reach the approval screen?** | **Mandatory on the override path** (a blank reason reproduces exactly the state this item exists to fix), enforced by the modal's confirm-disabled getter — the same mechanism `sellMeterInitiateModal.confirmDisabled` already uses, and for the same reason its header gives (`required` on a `lightning-*` input only fires on `reportValidity()`, which nothing calls). **Do NOT add it to `Sale_Decision_Approval`'s `approvalPageFields` in T2** — that is an approval-process edit, approvals are Tranche 3's boundary, and an active approval process may need deactivate/reactivate to accept the change. Record it as owed to T3. Confirm both halves. |

---

## 3. Item-by-item design

### 🔵 Item 1 — Readiness-band canonicalisation (A3) — ADMIN

**Deliver:** an in-place `<formula>` edit on **two existing formula fields**, plus a documentation
sweep. **No new field, no delete, no rename, no FLS change, no report edit, no dashboard edit.**

#### 1a. `Property_Asset__c.Sell_Readiness_Band__c`

```
IF( ISBLANK(Peak_Sell_Date__c), "Hold - Not yet",
IF( Peak_Sell_Date__c - TODAY() <= 30, "Sell now",
IF( Peak_Sell_Date__c - TODAY() <= 90, "Getting Close",
    "Hold - Not yet" )))
```

🔴 **THE THREE OUTPUT STRINGS ARE A CONTRACT AND MUST BE BYTE-IDENTICAL TO TODAY'S.** They are what
lets four reports, two dashboard donuts and one metric keep working with **zero** edits, because the
dashboard groups on the FIELD (`<groupingColumn>Property_Asset__c.Sell_Readiness_Band__c`), not on a
value. They are also byte-identical to `lwc/sellMeterList`'s `METER` labels (`:16-18`) and to
`lwc/sellMeterStats`'s card labels (`:27-29`), which is what makes Home and the Dashboard read the
same after this change.

**If any string changed:** every report grouping silently re-buckets (a summary report does not
error on an unexpected group value, it just shows a new row), both donut legends change, the
"Avg Sell Readiness" metric's grand total is unaffected but its grouping is not, and Home/Dashboard
wording diverges again. There is no upside. **Do not change them.**

**Correctness notes, each traced to `SellMeterService.bandForPeak:50-61`:**

| `bandForPeak` | Formula clause | Why |
|---|---|---|
| `peak == null → RED` | `ISBLANK(...) → "Hold - Not yet"` FIRST | Must precede the arithmetic; a null date in `Peak_Sell_Date__c - TODAY()` yields null, and a null comparison is false, which would fall through to the wrong branch. |
| `days <= 30 → GREEN` (**including negative**) | `<= 30`, no lower bound | An already-past peak is GREEN by design ("sell now"). A `&&  >= 0` guard would be a behaviour change. |
| `days <= 90 → YELLOW` | `<= 90` | 31-90 inclusive. |
| else RED | trailing `"Hold - Not yet"` | — |

⚠ **GATE G-3.** `Sell_Readiness_Band__c` currently carries **no** `<formulaTreatBlanksAs>` (it
references only a picklist). After the repoint it references a **Date**. Whether the Metadata API
requires, accepts or rejects that element on a Date-referencing Text formula at 67.0 is **not
exercised anywhere in this repo** and cannot be confirmed without MCP. Per the standing rule: keep
every other element byte-identical, deploy this one field as a **dry-run first**, and **read the
formula back**. A rejected enum fails loudly, which is the safe direction; a silently-accepted wrong
one is not.

#### 1b. `Property_Asset__c.Readiness_Score__c` (D-2)

```
IF( Sell_Readiness_Band__c = "Sell now", 1, 0 )
```

Keep `<formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>`, `precision 18`, `scale 0`,
`type Number` — byte-identical except `<formula>`. Deriving from the band field rather than
re-deriving the day arithmetic makes the two structurally incapable of disagreeing, which is the same
property `SellMeterService` was created to guarantee for the Apex side.

**Consumer:** `Dispositions/Sell_Readiness_By_Type` sums it into the dashboard's "Sell Readiness by
Property Type" table. Its meaning changes from "Argus says Sell Now" to "days-to-peak says GREEN".
That is the intended effect of A3 and is a **visible number change on the dashboard**.

#### 1c. `Argus_Signal__c` (D-3a) — KEPT, re-scoped, not orphaned

No metadata change to the field. Add an XML comment recording that **as of this change it has no
derived consumer** — the two formulas that read it no longer do — and that it survives as a
market-data input maintained by `DPEG_PropertyMgmt_Edit` (the only `editable=true` grant, P-13) and
consumed **directly** by:

- `Dispositions/Sell_Ready_Argus` — **as a FILTER** (`equals 'Sell Now'`) and a grouping; backs the
  dashboard "Disposition Readiness" metric. **See D-3b.**
- `Dispositions/Readiness_Mix`, `Readiness_Signal_By_Value_Avk`, `Properties_in_AUM` — as a column.
- `SellMeterController.getPortfolio:105` → `PropertyRow.argusSignal`, which is **selected, returned
  and never rendered** by `sellMeterList` (no column binds it). Asserted alive by
  `SellMeterControllerTest:88`. Dead payload — flagged, **not removed in T2** (removing it is a
  `USER_MODE` selector narrowing plus a test edit, and it is not one of the five items).

#### 1d. Documentation sweep (4 named sites) — the definitions are quoted verbatim in code

| File | Line(s) | What is now false |
|---|---|---|
| `scripts/seed-asset-sell-signals.apex` | 37-40 | Quotes both formulas verbatim and states "They are DERIVED from `Argus_Signal__c`, so stamping the signal populates them for free." Both halves become false. ⚠ The script still works — it also writes `Peak_Sell_Date__c` — but for a different reason. |
| `scripts/seed-lakeline-asset-repair.apex` | 121-122 | Quotes both formulas verbatim. |
| `classes/PropertyAssetService.cls` | 72-75 | Lists both as formulas derived from Argus. |
| `objects/Property_Asset__c/fields/Peak_Sell_Date__c.field-meta.xml` | 4 | `<description>` says "Used by the Sell Meter list." It is now also the dashboard's band driver. |

Amend **in place** (quote-and-retract), per this repo's convention — never silently edit.

**Risk: MEDIUM.** Low mechanically (two `<formula>` edits), but it is a **cross-module change to a
shared object** that alters four reports, two donuts and one dashboard metric with **no metadata
diff on any of them**. The failure mode is entirely at render time, which is exactly the class
Tranche 1's `ListView` Checkbox filter belongs to. **G-4 (browser check) is not optional here.**

---

### 🟢 Item 2 — Portfolio Upside → green-only (story 9) — DEVELOPER

**Deliver:** one guard in `SellMeterController.getMeterSummary`, one test fixture, one label (D-4).

**The change** (`SellMeterController.cls:74-82`): the upside `if` is currently a **sibling** of the
band `if/else` at `:67-73`. It becomes conditional on `band == SellMeterService.BAND_GREEN` — using
the constant, never the literal `'GREEN'`.

⚠ The band is already computed on line 66 and is already in scope. **No extra query, no extra field,
no FLS change** (P-12): `NOI__c`, `Market_Cap_Rate__c` and `Target_Sale_Price__c` are already in
`selectAllForMeterSummary`'s SELECT.

#### 🔴 Quantified impact — and why it must be MEASURED, not quoted

The seed scripts build the demo portfolio so that **every** asset is in the money:
`scripts/seed-asset-sell-signals.apex:56-62` derives `NOI = argusValue × cap / 100` (so
`implied = argusValue` exactly) and then sets `target = argusValue × 0.87-0.95` — *"below fair value,
so the portfolio-upside tile shows a positive number."*

⇒ Today's tile sums **every asset on the meter**. Green-only cuts it to the GREEN subset. The seed
header claims a full-portfolio meter of **6 GREEN / 6 YELLOW / 11 RED** at line 70 and, three lines
later at line 78, arithmetic implying **5 / 7 / 11** — **the script's own header is internally
inconsistent**, so no number in this repo is quotable. Order of magnitude: **the tile drops by
roughly 75-80%.**

Worse, the bands **drift daily**: `Peak_Sell_Date__c = today.addDays(d)` was stamped at seed time and
`bandForPeak` is evaluated at read time, so every asset's band has moved since. **The real number
must be measured in `usman-dpeg` immediately before deploy** — see **G-2**.

#### 🔴 The existing test is vacuous (P-8) — this is the required work

`SellMeterControllerTest:107-110` asserts `2000000` and its only in-the-money asset is the GREEN one,
so it passes identically before and after. The item must add:

1. an **in-the-money YELLOW** asset (peak 60 days out, implied > target) whose upside is **excluded**;
2. an **in-the-money RED** asset (peak 120 days out) whose upside is **excluded**;
3. an assertion that the total equals **only** the GREEN contribution — with a comment naming this
   test as the regression net, because the pre-existing one is not.

**Risk: MEDIUM.** Three lines of production code; the risk is entirely (a) the visible number change
on the user's home screen and (b) the vacuous-test trap, which is how a change like this ships with
a green suite and no proof.

---

### 🟢 Item 3 — Sell Meter Score as a multiple (story 10) — DEVELOPER

**Deliver:** one new column in `lwc/sellMeterList`, one formatter, Jest coverage. **No Apex change,
no selector change, no FLS change** — `meterScore` is already computed and already on the wire
(`SellMeterController.cls:114`, `PropertyRow.meterScore` is `@AuraEnabled`).

| | |
|---|---|
| Column | `{ label: 'Meter Score', fieldName: 'meterScoreLabel', type: 'text' }` (D-6), inserted **immediately before** the existing "Sell Meter" pill column |
| Row field | `meterScoreLabel: this._fmtMultiple(r.meterScore)` in `allRows`'s `.map()` |
| Formatter | `_fmtMultiple(v) { return v == null ? '—' : parseFloat(v).toFixed(2) + '×'; }` |
| Null / zero target | `'—'` — the server already returns `null` when NOI, cap rate **or** target price is null/zero, so one branch covers all three. `_fmtM` and `capRateLabel` already use `'—'`; do not invent a second placeholder. |
| Raw sort key (item 4) | `meterScore` (the raw Decimal), via the `SORT_KEY` map |

**Calculated Value:** **not surfaced** — see **D-5** and P-9. If the user overrides that, the same
pattern applies with `_fmtM(r.impliedValue)`, label "Calculated Value", and the width question in
**G-5** becomes load-bearing.

⚠ **`×` is U+00D7 MULTIPLICATION SIGN, not the letter `x`.** It is announced as "times" by screen
readers, where `x` is announced as the letter. `@sa11y/jest` is mandatory on this bundle; the new
column is plain text in a labelled column, so no new accessible-name work is required — but the
existing suite's `toBeAccessible()` must still pass with the extra column.

⚠ **No new colours.** The component's band pills already use hardcoded hex inline styles
(`sellMeterList.js:16-18`) — a **pre-existing** SLDS-2 deviation that is **not in this tranche's
scope and must not be "fixed" here**. The new column adds no colour, so it introduces no new
deviation.

⚠ **Nine columns on a 5-row card in a two-column FlexiPage region** (`Sell_Meter.flexipage`, region2
of `appHomeTemplateHeaderTwoColumns`) with `column-widths-mode="auto"`. **This is a rendering
outcome, not a deploy outcome.** Per the standing hazard, it needs a browser check (**G-5**).

**Risk: LOW-MEDIUM.** The only real exposure is layout width.

---

### 🟢 Item 4 — Sortable columns (story 10) — DEVELOPER

🔴 **This is the highest-behaviour-risk item in the tranche**, and it reverses a documented
intentional feature (D-8).

#### The mechanism

✅ Works out of the box: `lwc/listDatatable` extends `LightningDatatable`, so `sortable`,
`sorted-by`, `sorted-direction` and `onsort` are inherited (`listDatatable.js:11`). The datatable
**raises** `onsort` and the parent **performs** the sort. In-repo precedent: `lwc/loiCounterOffer`
(`:52-111` columns, `:269-283` sort + `handleSort`).

#### 🔴 Sort on RAW values, not on the rendered labels (P-10, D-7)

Add a `SORT_KEY` map alongside `COLUMNS`, and keep the raw values on each row:

| Column `fieldName` | Sort key | Raw value on the row |
|---|---|---|
| `recordUrl` | `name` | already present |
| `noiLabel` | `noi` | add (raw Decimal from the wire) |
| `capRateLabel` | `mktCapRate` | add |
| `targetLabel` | `targetPrice` | add |
| `peakDateLabel` | `peakSellDate` | add — the raw `'YYYY-MM-DD'` string sorts **chronologically** under a plain string compare, so no Date parsing is needed |
| `peakValueLabel` | `projectedValueAtPeak` | add |
| `meterScoreLabel` (item 3) | `meterScore` | add |
| `sellMeter` | `meterOrder` | add — `METER_ORDER[meter] ?? 3`, **not** the pill string `'Sell now \| 12d'` |
| Action | *(not sortable)* | — |

The Action column and the pill column's *label* are presentation; the pill sorts by band rank, which
is the only ordering that means anything.

`handleSort` follows the precedent verbatim, plus one addition:

```js
handleSort(event) {
    this._sortedBy = event.detail.fieldName;
    this._sortedDirection = event.detail.sortDirection;
    this._page = 1;               // ← NEW, see D-8
}
```

#### 🔴 The reconciliation with the RED-splice hack (D-8)

`allRows` gains one branch at the top:

- **`_sortedBy` undefined (default view):** today's behaviour, unchanged — `METER_ORDER` sort, then
  the splice at `:91-97`. The `DATA BRANCH` Jest test (`:333-362`) keeps passing untouched.
- **`_sortedBy` set (user has sorted):** sort by `SORT_KEY[_sortedBy]` in `_sortedDirection`;
  **skip the band ordering and skip the splice entirely.**

⚠ **Say this to the BA in these words:** after any sort, the opening screen no longer guarantees a
RED row on page 1, which is the property the splice was written to provide
(`sellMeterList.js:89-90`). The hack's comment must be amended **in place** to say it now applies to
the default view only.

#### 🔴 The splice has no test today (P-11) — build one

Because no existing fixture reaches the branch, item 4 must add:
1. a **≥6-row mixed-band fixture with the only RED beyond index 4**, asserting the splice fires in
   the default view (this is a **new** regression net for **existing** behaviour, not for the change);
2. a test that the same fixture, after a sort event, is in sort order with **no** splice;
3. a test that sorting from page 2 lands on page 1;
4. `sorted-by` / `sorted-direction` reaching the datatable so the header arrow renders.

⚠ Jest is **local-only and never deploys**. It proves the sort function; it does **not** prove the
datatable renders a sort affordance. That is a browser check (**G-5**).

**Risk: HIGH.** Not technically — it is ~40 lines — but because it changes the ordering of the
user's home screen, disables a documented feature under a condition, and the feature it disables has
no existing test to tell anyone if it breaks in the default path too.

---

### 🔵🟢 Item 5 — The Override action — ADMIN + SOLUTION-ARCHITECT + DEVELOPER

Two separable gaps. **5(a) is an authorization change; 5(b) is an audit change.** They share a modal
and should ship together, but they are independently testable.

#### 5(a) Principal-only visibility

**New metadata (ADMIN):**

| Artefact | Detail |
|---|---|
| `customPermissions/Disposition_Sell_Meter_Override.customPermission-meta.xml` | `label` "Disposition Sell Meter Override", `isLicensed false`. ⚠ `<description>` is capped at **255 chars** on `CustomPermission` — measured on this project 2026-08-12. All rationale goes in an **XML comment inside the root element** (a comment above the root breaks `sf` at source conversion). |
| `permissionsets/DPEG_Disposition_View` | one `<customPermissions><enabled>true</enabled><name>Disposition_Sell_Meter_Override</name></customPermissions>` entry. **This set and no other.** |

🔴 **Write the asymmetry into the new permission's XML comment**, quoting
`Disposition_Deal_Actions`'s banner, so the next reader does not "restore symmetry":
`Disposition_Deal_Actions` lives on `_Edit` (Analyst) and is forbidden on `_View`;
`Disposition_Sell_Meter_Override` lives on `_View` (Principal) and must **not** be added to `_Edit`.
The two tokens are deliberate mirror images and merging them collapses the whole gate.

**New Apex (DEVELOPER):**

| Layer | Component |
|---|---|
| Service | **new** `SellMeterOverridePermissionService` — `hasSellMeterOverrideAccess()` + `assertSellMeterOverrideAccess()`, `AccessDeniedException`, transaction-scoped memoization, `FeatureManagement.checkPermission` first (0 SOQL) then the `PermissionSetAssignmentSelector.selectForCurrentUser()` Modify-All-Data bypass. Shape copied from `DispositionActionPermissionService:279-352`. |
| Controller | `SellMeterController` gains `@AuraEnabled(cacheable=true) static Boolean hasOverrideAccess()` — a thin wrapper, `AuraHandledException` at the boundary, matching the class's existing two-catch idiom. |
| Service (edit) | `DispositionService.findOrCreate` **and** `.initiateAndSubmit`: after the band is computed and the RED refusal is thrown, **if the band is YELLOW, `assertSellMeterOverrideAccess()`** (D-10). |
| Controller (edit) | `DispositionController` gains a catch for the new `AccessDeniedException` so the denial surfaces as authored text, not as the generic write-failure wording — the same two-catch shape the class already documents for `SellMeterGateException`. |

🔴 **Do NOT modify `DispositionActionPermissionService`** — its header forbids one-sided change
against its `OpportunityActionPermissionService` twin (P-5).
🔴 **Do NOT import `c/dealActionGuard` or `c/recordStageGuard`** into `sellMeterList` — its own
comment (`:265-268`) explains why, and that reasoning is unchanged.
🔴 **The header retractions are mandatory, in place, quote-not-delete:**
`DispositionService.cls:87-91` states the exact condition under which its refusal flips. That
paragraph must be marked SATISFIED and dated, not deleted — it is the evidence that this assert was
added deliberately rather than by someone who did not read it.

**LWC (DEVELOPER):** `sellMeterList` gains `@wire(hasOverrideAccess)`. In `allRows`, the YELLOW
branch's `actionDisabled` becomes `!this._canOverride`; the label stays `'Override'` (D-11). The
existing `handleRowAction` early-return already refuses a disabled action name only for `'hold'` — it
must also refuse `'override'` when `_canOverride` is false, because **the client gate is a UX
affordance only and the server is the real gate**.

⚠ **The wire resolves asynchronously.** Default `_canOverride` to **`false`** so the button is
disabled during the round trip, never enabled-then-disabled. Fail closed on wire error, matching
`DispositionActionPermissionService`'s documented "the LWC guard treats a thrown check exactly like
false" contract.

⚠ **Relevant memory, and it is why a criteria gate is correct here:** `getObjectInfo.updateable` has
**no record context**, so an LWC gate cannot see sharing. This gate is **criteria-based** (does the
running user hold a custom permission?), not owner- or record-based, so that trap does not apply —
`FeatureManagement.checkPermission` answers a question about the *user*, and the answer is identical
for every row. Stated so nobody "improves" it into a per-record check.

⚠ **Rejected alternative:** `@salesforce/customPermission/Disposition_Sell_Meter_Override` — zero
Apex, zero SOQL, and genuinely tempting. Rejected because (i) it is used **nowhere** in this repo, so
its behaviour here is unproven, and (ii) it does **not** honour the Modify-All-Data bypass every
sibling gate in this codebase provides, which would lock a bare System Administrator out of the
button with no diagnosis path.

#### 5(b) A free-text reason, captured and logged

🔴 **This reverses a recorded scope decision.** `sellMeterList._confirmOverride`'s header
(`:273-280`) states: *"What survives is the OTHER half: there is still no override REASON field. The
override is recorded only by this dialog having been answered and by the distinct success-toast title
below, which is a deliberate scope decision, not an oversight."* That paragraph must be **retracted
in place**, quoting it, with the date and the story number — the repo's convention and the reason
anyone can tell an overturned decision from a forgotten one.

**New metadata (ADMIN):**

| Field | Type | FLS |
|---|---|---|
| `Disposition__c.Sell_Meter_Override_Reason__c` | **Long Text Area**, `length 4000`, `visibleLines 3`, not required, no default | `readable=true, editable=false` in **BOTH** `DPEG_Disposition_View` and `DPEG_Disposition_Edit`. Precedent: `BOV_Broker_Change__c`'s 2026-08-20 C3 reconciliation — *"granting `allowEdit` … would let the very analyst who replaced a broker go back and rewrite who did it and when."* |

🔴 **The FLS grant must land in the SAME wave as the field.** A Metadata-API field arrives with **no**
FLS for anyone, System Administrator included, and an ungranted field **aborts the whole DML
statement** rather than degrading.

**No new picklist value.** `Sell_Decision_Trigger__c = 'Principal Decision'` already exists on both
record types (P-7), so no `recordTypes/*.xml` edit, no restricted-picklist DML risk, and no
record-type-before-Apex ordering constraint. If a new value were ever wanted, **both** record type
files must be edited (each file's comment: *"a record type file must list EVERY picklist on the
object or values are silently dropped from that type"*).

**Capture (DEVELOPER), per D-12:**

```
sellMeterList.handleRowAction('override')
  → c/sellMeterOverrideModal.open({ propertyName })        ← NEW bundle, replaces LightningConfirm
      resolves undefined            → cancelled, say nothing
      resolves { reason }           → confirmed
  → sellMeterInitiateModal.open({ …existing…, overrideReason })   ← NEW pass-through @api, NOT rendered
  → DispositionController.initiateAndSubmit(assetId, recordTypeDeveloperName, overrideReason)
```

The new modal keeps the existing confirm's exact wording, `theme: 'warning'`, and the property name
in the message (pinned by `sellMeterList.test.js:640-641`), and adds a **required**
`lightning-textarea`. Its confirm button uses the `confirmDisabled`-getter idiom
(`sellMeterInitiateModal.js:145-153`), because `required` on a `lightning-*` input only fires on
`reportValidity()` and nothing calls it — that trap is already documented in this bundle.

**Persistence (DEVELOPER):** `DispositionService.initiateAndSubmit` **step 4** stamps both fields in
the **same DML as the insert** — `Sell_Decision_Trigger__c = 'Principal Decision'` and
`Sell_Meter_Override_Reason__c = overrideReason`, **only when the band is YELLOW**. One DML, no extra
query.

🔴 **It MUST be at insert.** `Sale_Decision_Approval` sets `recordEditability = AdminOnly`, which
locks the record the instant `submitSaleDecision` runs on the very next line. A stamp attempted after
submission fails.

⚠ `findOrCreate` takes no reason parameter and is not being given one — it is the legacy path, has no
UI, and its YELLOW branch is now refused for non-principals anyway (5a). Its header must record that
a YELLOW creation through it produces **no reason**, so nobody reads a blank reason as data loss.

**Test impact (DEVELOPER):**
- `sellMeterList.test.js` — the five tests built on `jest.mock('lightning/confirm')` and the
  `['confirm','modal']` call-order assertion (`:271-300`, `:605-655`, `:657-678`) all repoint to the
  new modal mock. ⚠ The suite's own header explains that `LightningModal.open()` is a static and the
  repo-local stub **throws** on purpose so an unmocked suite fails loudly — the new bundle needs the
  same `jest.mock` treatment as `c/sellMeterInitiateModal`.
- New Jest for `c/sellMeterOverrideModal` (required for every LWC) + `@sa11y/jest`.
- New Apex tests: the YELLOW assert denies a non-holder and permits a holder on **both** create
  paths, and the two fields are stamped on YELLOW and **not** stamped on GREEN.
- ⚠ `DispositionServiceTest` / `DispositionControllerTest` run existing YELLOW-band creations. Under
  5(a) those now require the permission. **A `System.runAs` user holding the new permission is
  needed, or those tests go red** — and per the standing hazard, a denial test run as a System
  Administrator proves nothing, because Modify All Data bypasses the gate.

**Risk: HIGH.** 5(a) reverses a recorded refusal, removes a capability from a live persona, and
depends on a permission-set assignment this repo cannot see. 5(b) reverses a second recorded
decision and rewrites the most heavily-tested interaction on the page.

---

## 4. Admin / Solution-Architect / Developer split

### 🔵 ADMIN (`salesforce-admin`)

| Item | Deliverable |
|---|---|
| 1a | `Property_Asset__c.Sell_Readiness_Band__c` — `<formula>` edit, in place. Strings byte-preserved. |
| 1b | `Property_Asset__c.Readiness_Score__c` — `<formula>` edit, in place. |
| 1c | `Argus_Signal__c` — XML comment only (re-scoped, no derived consumer). |
| 1d | Four documentation amendments (2 seed scripts, 1 class header, 1 field description) — quote-and-retract. |
| 3b *(only if D-3b is approved)* | `Dispositions/Sell_Ready_Argus` — repoint filter + grouping to `Sell_Readiness_Band__c`. |
| 5a | `customPermissions/Disposition_Sell_Meter_Override.customPermission-meta.xml`. |
| 5b | `Disposition__c.Sell_Meter_Override_Reason__c` (Long Text Area). |

### 🟤 SOLUTION-ARCHITECT (`salesforce-solution-architect`)

| Item | Deliverable |
|---|---|
| 5a + 5b access | **ONE consolidated pass** over `DPEG_Disposition_View` (add the `customPermissions` entry + the new field grant) and `DPEG_Disposition_Edit` (the new field grant only). Routed here rather than to admin because it is an authorization-boundary change across two personas on shared hub files with replace semantics — `CLAUDE.md`'s routing trigger for this agent. |

🔴 **A `PermissionSet` deploy REPLACES that set's entire `fieldPermissions` collection.** Both edits
are one pass over each file. And a complete pre-deploy reconciliation needs `FieldPermissions` **+
`ObjectPermissions` + `SetupEntityAccess`** — measured 2026-08-31, a custom-permission grant is
invisible to the first two, so a `FieldPermissions`-only diff will report the `customPermissions`
entry as absent when it is present.

### 🟢 DEVELOPER (`salesforce-developer`)

| Item | Deliverable |
|---|---|
| 2 | `SellMeterController.getMeterSummary` green-only guard; `sellMeterStats.js:30` label (D-4); **new** non-vacuous fixtures in `SellMeterControllerTest`. |
| 3 | `sellMeterList` — new "Meter Score" column, `_fmtMultiple`, Jest. |
| 4 | `sellMeterList` — `sortable` columns, `SORT_KEY` map, raw row values, `handleSort` + page reset, the default-view branch in `allRows`; **new** splice regression test; Jest + `@sa11y`. |
| 5a | **New** `SellMeterOverridePermissionService`; `SellMeterController.hasOverrideAccess`; YELLOW assert on **both** `DispositionService` create paths; `DispositionController` catch; `sellMeterList` wire + disabled state; header retractions in place; Apex + Jest tests including a non-admin denial persona. |
| 5b | **New** `c/sellMeterOverrideModal` bundle (+ Jest + `@sa11y`); `sellMeterInitiateModal` pass-through `@api overrideReason`; `initiateAndSubmit` 3rd parameter + step-4 stamp; repoint the five `LightningConfirm` tests; `_confirmOverride` header retraction. |

**No integration, no Named Credential, no ASB/Plaid/Yardi touchpoint** — `salesforce-technical-architect`
is **not** required for this tranche.

---

## 5. Deploy order

| Wave | Contents | Why here |
|---|---|---|
| **0** | **GATES, no writes.** G-1 … G-7 below. Nothing is written until every gate has an answer. | Every one of these has produced a silent failure on this project before. |
| **1** | **Schema, additive only** — `Disposition__c.Sell_Meter_Override_Reason__c` and `customPermissions/Disposition_Sell_Meter_Override`. | Apex referencing the field will not compile, and a `customPermissions` entry naming a permission the org does not hold **fails the whole permission-set deploy** (`DPEG_Admin_Access`'s own header records this from T1). |
| **2** | **The consolidated permission pass** — `DPEG_Disposition_View` (custom permission + field read) and `DPEG_Disposition_Edit` (field read), in ONE deploy across the two files. | 🔴 A field with no FLS **aborts the whole DML statement**; a `PermissionSet` deploy **replaces** the whole `fieldPermissions` collection, so this cannot be split. Must follow wave 1. |
| **3** | **Item 1 formulas** — `Sell_Readiness_Band__c` first, **alone, as a dry-run** (G-3), read back, then `Readiness_Score__c`. | `Readiness_Score__c` **references** `Sell_Readiness_Band__c` (D-2), so the band must land first or the second formula will not compile. |
| **4** | **Reports** — `Sell_Ready_Argus` repoint, **only if D-3b is approved**. | Needs the band's new meaning to be live first, or the KPI shows the old bucketing under a new name for one window. |
| **5** | **Apex** — service → controller → `DispositionService` asserts + stamp. | Layering order; needs waves 1-2 for the field, the permission and the grants. |
| **6** | **LWC** — items 2, 3, 4, and the two modal bundles. | Needs wave 5's `hasOverrideAccess` and the 3-arg `initiateAndSubmit` to exist. |
| **7** | **Documentation sweep** — the four amended files, plus every header retraction. | Independent; last so the retractions describe what actually shipped. |
| **8** | **BROWSER ACCEPTANCE** (G-4, G-5). **Not a deploy.** | The acceptance criterion for items 1, 3 and 4 is what renders, not what deploys. |

### Gates

| # | Gate | Why |
|---|---|---|
| **G-1** | **Measure the current band divergence in `usman-dpeg`.** Anonymous Apex over the union population, printing a cross-tab of `Sell_Readiness_Band__c` (today) × `bandForPeak(Peak_Sell_Date__c)` (tomorrow), plus each donut's before/after counts and the size of the vanishing `&#8212;` bucket. | The BA is about to see two donuts change. This is the number to show them. The seed script's own header is internally inconsistent (P-8/§Item 2), so **nothing in this repo is quotable**. |
| **G-2** | **Measure the Portfolio Upside before/after** over `WHERE Property__c != null AND Peak_Sell_Date__c != null`: total in-the-money upside vs GREEN-only upside. | Item 2 changes a headline number on the home screen by an estimated 75-80%. |
| **G-3** | **`formulaTreatBlanksAs` on a Date-referencing Text formula — one-field dry-run + readback.** | Unproven shape at 67.0, no MCP. `ARCHITECTURE.md` §3.4 records what guessing an unproven shape costs. |
| **G-4** | **Browser check both donuts, "Avg Sell Readiness" and "Sell Readiness by Property Type" after wave 3.** | 🔴 Green source ≠ working. T1's `ListView` Checkbox filter was valid XML, a real field and a valid operator, and was invisible to two code-review passes. A report grouping on a changed formula produces **no metadata diff on the report** — there is nothing for a reviewer to look at. |
| **G-5** | **Browser check the Sell Meter card**: nine columns at the FlexiPage's two-column width, the sort affordance renders and sorts, the splice still fires in the default view, and the Override button's disabled state **as a real non-principal persona**. | Rendering, ordering and permission-chrome outcomes; none is a deploy result. ⚠ An admin smoke test proves nothing about the gate — Modify All Data bypasses it. |
| **G-6** | **Confirm `customPermissions/Disposition_Sell_Meter_Override` lands in the SAME deploy as, or an EARLIER one than, `DPEG_Disposition_View`.** | `DPEG_Admin_Access`'s T1 header: *"A `customPermissions` entry naming a permission the target org does not yet hold fails the deploy of this entire set."* |
| **G-7** | **Retrieve and diff, against HEAD *and* against the org, before touching:** `DPEG_Disposition_View`, `DPEG_Disposition_Edit`, and `dashboards/Dispositions/Disposition_Dashboard_Junior.dashboard-meta.xml` (**currently `M` in `git status` from work that is not this tranche**). | A shared working tree plus replace semantics. A FlexiPage/dashboard deploy also **clobbers App Builder edits with no version history** — measured on this project 2026-08-25. |

### Standing deploy hygiene

- 🔴 **Check per-component `state` in the dry-run output, not the top-level status.** A byte-identical
  component reports `Unchanged` and **skips validation entirely**; a comment-only edit does not count
  as a change. Item 1's formula edits and item 1d's comment amendments will land in the same package —
  the comment-only files will report `Unchanged` and that is **expected**, not a failure.
- 🔴 **`sf sobject describe` is a stale cache.** Verify the new field via Tooling API `CustomField`
  with an explicit `TableEnumOrId`. Same-named siblings exist in this org.
- 🔴 **`--tests` runs the ORG's copy of a test class.** Include every changed test class in the
  deployment payload, or a targeted run can execute fewer methods than the repo has and still report
  100%.

---

## 6. Per-item risk register

| # | Item | Risk | Dominant hazard |
|---|---|---|---|
| 1 | Readiness-band canonicalisation | **MED** | 🔴 Cross-module change to a shared object that alters **4 reports + 2 donuts + 1 metric with zero metadata diff on any of them** — the failure is render-time only (G-4). Plus: the `&#8212;` bucket vanishes and its assets move to `Hold - Not yet`; the strings are a contract; **A3 is not fully closed by this item** (P-2). ✅ Mitigated by P-3: it is an in-place formula edit, not T1 item 6's delete+create. |
| 2 | Portfolio Upside green-only | **MED** | 🔴 A headline number on the home screen drops an estimated **75-80%**; and the **existing test passes vacuously**, so without new fixtures the change ships with no regression net. |
| 3 | Meter Score column | **LOW-MED** | Nine columns at a two-column FlexiPage width — a rendering outcome no deploy or review can see (G-5). No Apex, no selector, no FLS change. |
| 4 | Sortable columns | **HIGH** | 🔴 Every sortable-looking column binds a **pre-formatted string**, so the naive form sorts `'$10.0M' < '$2.0M'` and dates by month name. Reverses a documented intentional feature (the splice) **which has no test today**. Changes the ordering of the user's home screen. |
| 5a | Principal-only Override | **HIGH** | 🔴 The cited precedent token is **exactly inverted** (P-5). Reverses a recorded refusal in `DispositionService` (P-6) — whose own header pre-authorised the flip and required it on **both** create paths. `findOrCreate` is a second live bypass. **Removes a capability from the junior-analyst persona.** Depends on a `PermissionSetAssignment` this repo cannot see. Existing YELLOW-band Apex tests go red without a permission-holding `runAs` persona. |
| 5b | Override reason | **MED-HIGH** | 🔴 Reverses a second recorded scope decision. Rewrites the **most heavily-tested interaction in the bundle** (5 `LightningConfirm` tests incl. a call-order assertion). Must stamp **at insert** — `AdminOnly` locks the record on the next line. ✅ Mitigated by P-7: the structured half needs **no new picklist value and no record-type surgery**, and it fixes a live defect (the approval screen says "Sell Meter Green" on every override). |

---

## 7. Confirmed OUT of Tranche 2

Restated so no implementing agent widens scope. **None of these is designed above.**

- **The Conversion 5 freeze (13/66)** — **A1: NO FREEZE.** Live values stand; `Asking_Price__c` stays
  retired; `BOV_Score__c` keeps scoring against the live asset `Target_Sale_Price__c`.
- **Approvals, the approver roster, the NDA approval (D1), the approval tracker** — **Tranche 3.**
  Includes D-14's deferred `approvalPageFields` addition.
- **BOV scoring / matrix / broker surfaces** — **Tranche 4.**
- **The Week 2 rung change (A2), detection jobs, reminder ladders, timers** — **Tranche 5.**
- **Offer comparison columns, closing statement, PSA status, Conversion 6, CoStar/Argus deep links**
  — **Tranche 6.**
- Anything integration- or notification-shaped.

**Additionally flagged here and deliberately NOT built, so they are not mistaken for oversights:**

- **`Sell_Readiness_Score__c`** — a **third** readiness measure, a hand-seeded stored Percent feeding
  the "Avg Sell Readiness" metric. A3 does not mention it (P-14).
- **The population disagreement** between Home (`Property__c != null AND Peak_Sell_Date__c != null`,
  no `Status__c` filter) and the Dashboard (`Status__c = 'Active'`). Closing it is entangled with
  story 49's Conversion 6 gap ("nothing sets `Status__c = 'Disposed'`") — **Tranche 6** (P-2).
- **`Argus_Signal__c` retirement.** Kept and re-scoped (D-3a); a retirement sweep would touch one
  report filter, four report columns, one Apex payload + its assertion, and four seed scripts.
- **`PropertyRow.argusSignal`** — selected, returned, never rendered. Dead payload, flagged, not
  removed (removing it is a `USER_MODE` selector narrowing plus a test edit).
- **`Disposition_Dashboard_Access` has no `objectPermissions` at all** — its field grants are inert
  without object read from another set. T1 flagged it; still true; still not fixed here.
- **`sellMeterList`'s hardcoded hex band colours** — a pre-existing SLDS-2 deviation. Not fixed here,
  and the new column adds no colour.
- **The undocumented cross-module dependency (P-12)**: the Sell Meter works only because both persona
  PSGs carry `DPEG_PropertyMgmt_View`. **Recommend recording it in `PropertyAssetSelector`'s header**
  as a one-line documentation task — but it is a finding to report, not a change to make.

---

## 8. Prompts for the specialist agents

Only what was requested. No extras.

### 🔵 PROMPT FOR `salesforce-admin`

```
Create the metadata described in agent-output/disposition-gap-closure-t2-design.md §3, items
1a-1d, 5a (the CustomPermission only) and 5b (the field only). Do NOT edit any permission set —
that is a separate consolidated pass owned by salesforce-solution-architect.

Item 1a — Property_Asset__c.Sell_Readiness_Band__c: edit <formula> IN PLACE. Both fields are
  ALREADY formula fields, so this is a legal in-place edit — it is NOT Tranche 1 item 6's
  delete+create situation. Do not create a new field, do not rename, do not change <type>.
  🔴 THE THREE OUTPUT STRINGS ARE A CONTRACT: "Sell now", "Getting Close", "Hold - Not yet",
  byte-identical to today. Four reports group by this field and two dashboard donuts name it in
  <groupingColumn>; preserving the strings is what lets all six keep working with ZERO edits.
  The formula is in §3 item 1a. The ISBLANK branch must come FIRST.
  ⚠ GATE G-3: keep every element other than <formula> byte-identical. Deploy this ONE field as a
  dry-run and READ THE FORMULA BACK before touching anything else. Whether
  <formulaTreatBlanksAs> is required/accepted/rejected on a Date-referencing Text formula at 67.0
  is not exercised anywhere in this repo. Do not guess it.

Item 1b — Property_Asset__c.Readiness_Score__c: <formula> becomes
  IF( Sell_Readiness_Band__c = "Sell now", 1, 0 ). Keep BlankAsZero, precision 18, scale 0,
  type Number. It must deploy AFTER 1a — it references that field.

Item 1c — Property_Asset__c.Argus_Signal__c: XML COMMENT ONLY, no metadata change. Record that as
  of this change it has NO derived consumer, that it survives as a market-data input editable only
  via DPEG_PropertyMgmt_Edit, and list its four remaining direct consumers named in §3 item 1c.

Item 1d — amend IN PLACE (quote the old text, mark it retracted, date it — never silently edit):
  scripts/seed-asset-sell-signals.apex:37-40
  scripts/seed-lakeline-asset-repair.apex:121-122
  force-app/main/default/classes/PropertyAssetService.cls:72-75
  objects/Property_Asset__c/fields/Peak_Sell_Date__c.field-meta.xml (<description>)

Item 5a — customPermissions/Disposition_Sell_Meter_Override.customPermission-meta.xml.
  <description> is capped at 255 chars on CustomPermission; put the rationale in an XML COMMENT
  INSIDE the root element (a comment above the root breaks `sf` at source conversion).
  🔴 The comment must quote Disposition_Deal_Actions' own banner and state the deliberate
  asymmetry: Disposition_Deal_Actions lives on DPEG_Disposition_Edit and is FORBIDDEN on
  DPEG_Disposition_View; this new token lives on DPEG_Disposition_View and must NOT be added to
  DPEG_Disposition_Edit. They are mirror images; merging them collapses the gate.

Item 5b — Disposition__c.Sell_Meter_Override_Reason__c: LongTextArea, length 4000, visibleLines 3,
  not required, no default. Do NOT add a picklist value to Sell_Decision_Trigger__c — the existing
  'Principal Decision' value is being reused precisely to avoid editing both record type files.

Record mcp=unavailable / mcp_tools=none per metadata type after a real attempt, and fall back to
the per-type skill. Do NOT deploy. Create/modify the metadata files only.
```

### 🟤 PROMPT FOR `salesforce-solution-architect`

```
Execute the ACCESS pass in agent-output/disposition-gap-closure-t2-design.md §4, as a SINGLE
consolidated edit to exactly two files:
  force-app/main/default/permissionsets/DPEG_Disposition_View.permissionset-meta.xml
  force-app/main/default/permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml

BEFORE editing (GATE G-7):
  - Retrieve both from usman-dpeg and diff against HEAD. A PermissionSet deploy REPLACES the
    file's entire fieldPermissions collection; an org/repo divergence silently revokes live
    grants. Report any divergence and STOP rather than reconciling silently.
  - A complete reconciliation needs FieldPermissions + ObjectPermissions + SetupEntityAccess.
    Measured 2026-08-31: a custom-permission grant is INVISIBLE to the first two, so a
    FieldPermissions-only diff will report the customPermissions entry as absent when it is
    present. Query SetupEntityAccess explicitly.
  - Confirm no concurrent stream is editing these files (git status already shows other
    permission sets modified by work that is not this tranche).

THEN, additively:
  DPEG_Disposition_View:
    - <customPermissions><enabled>true</enabled><name>Disposition_Sell_Meter_Override</name>
    - fieldPermissions Disposition__c.Sell_Meter_Override_Reason__c readable=true editable=FALSE
  DPEG_Disposition_Edit:
    - fieldPermissions Disposition__c.Sell_Meter_Override_Reason__c readable=true editable=FALSE
    - 🔴 DO NOT add the custom permission here. See customPermissions/
      Disposition_Sell_Meter_Override's XML comment for why the asymmetry is the design.

editable=FALSE in BOTH sets is deliberate: this is an approval-audit fact written by SYSTEM-mode
Apex. Precedent: BOV_Broker_Change__c's 2026-08-20 C3 reconciliation.

🔴 DEPLOY ORDER: customPermissions/Disposition_Sell_Meter_Override and the new field must land in
the SAME deploy as this file or an EARLIER one. A customPermissions entry naming a permission the
org does not hold fails the deploy of the ENTIRE set, and a field with no FLS aborts the whole
DML statement rather than degrading.

Record mcp=unavailable / mcp_tools=none after a real attempt. Do NOT deploy.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Implement the DEVELOPER work in agent-output/disposition-gap-closure-t2-design.md §3, items 2, 3,
4, 5a and 5b, and §4's developer table.

ITEM 2 — Portfolio Upside green-only:
  SellMeterController.getMeterSummary: the upside block at :74-82 becomes conditional on the band
  already computed at :66 being SellMeterService.BAND_GREEN. Use the constant, never 'GREEN'.
  Rename the sellMeterStats.js:30 card label to "Sell-Ready Upside" (per Gate 1 D-4).
  🔴 THE EXISTING TEST IS VACUOUS. SellMeterControllerTest:107-110 asserts upside 2,000,000 and
  its only in-the-money asset is the GREEN one, so it passes identically before and after. Add an
  in-the-money YELLOW asset and an in-the-money RED asset whose upside must be EXCLUDED, and say
  in the test comment that these are the regression net because the pre-existing one is not.

ITEM 3 — Meter Score column in lwc/sellMeterList:
  New column { label:'Meter Score', fieldName:'meterScoreLabel', type:'text' } immediately BEFORE
  the existing 'Sell Meter' pill column. meterScore is ALREADY computed and already on the wire —
  no Apex change, no selector change, no FLS change.
  Formatter: null -> '—' (the component's existing placeholder), else toFixed(2) + '×'
  (MULTIPLICATION SIGN, not the letter x — screen readers announce it as "times").
  Do NOT add a 'Calculated Value' column. It is out of scope (design D-5).

ITEM 4 — sortable columns:
  🔴 SORT ON RAW VALUES, NOT ON THE RENDERED LABELS. Every column's fieldName currently binds a
  pre-formatted string ('$2.0M', '6.5%', 'Jan 1, 2020', 'Sell now | 12d', a record URL), so
  sortable:true alone sorts '$10.0M' before '$2.0M' and dates alphabetically by month name.
  Add a SORT_KEY map and carry the raw values on each row. The mapping table is in §3 item 4.
  The pill column sorts by METER_ORDER rank, never by the pill string.
  Copy the shape from lwc/loiCounterOffer:269-283 (including the recordUrl -> name remap).
  DO NOT convert the columns to native currency/percent/date-local types: the compact labels are
  handed to sellMeterInitiateModal so the popup and the row cannot disagree, and four Jest
  assertions pin them.
  🔴 RECONCILE WITH THE RED-SPLICE HACK (design D-8): while sortedBy is undefined, allRows keeps
  today's METER_ORDER sort AND the splice at :91-97, unchanged. Once the user sorts, BOTH are
  skipped. handleSort also resets _page to 1. Amend the splice's comment IN PLACE to say it now
  applies to the default view only — do not delete it.
  🔴 THE SPLICE HAS NO TEST TODAY: the 3-row fixture already has RED on page 1 and the 6-row
  fixture is all GREEN. Add a >=6-row mixed-band fixture whose only RED sits beyond index 4 and
  assert the splice fires in the default view and does NOT fire after a sort.

ITEM 5a — principal-only Override:
  🔴 DO NOT reuse Disposition_Deal_Actions. It is granted by DPEG_Disposition_Edit (Analyst) and
  its own file forbids it on DPEG_Disposition_View (Principal) — reusing it inverts the AC.
  🔴 DO NOT modify DispositionActionPermissionService: its header forbids one-sided change against
  its OpportunityActionPermissionService twin.
  🔴 DO NOT import c/dealActionGuard or c/recordStageGuard into sellMeterList — sellMeterList.js
  :265-268 explains why, and that reasoning is unchanged.
  Build NEW SellMeterOverridePermissionService (hasSellMeterOverrideAccess /
  assertSellMeterOverrideAccess / AccessDeniedException / transaction-scoped memoization /
  FeatureManagement.checkPermission first at 0 SOQL, then the Modify-All-Data bypass), copying the
  shape from DispositionActionPermissionService:279-352.
  Add @AuraEnabled(cacheable=true) SellMeterController.hasOverrideAccess() as a thin wrapper.
  🔴 THE SERVER ASSERT IS ON THE YELLOW BRANCH ONLY, ON BOTH CREATE PATHS —
  DispositionService.findOrCreate AND .initiateAndSubmit. A method-wide assert would close GREEN
  Initiate to analysts, which no story asks for. The band is already computed at :319 and :437.
  🔴 DispositionService.cls:87-91 pre-authorised exactly this and required BOTH paths at once.
  Mark that paragraph SATISFIED and dated — quote it, do NOT delete it.
  DispositionController gains a catch for the new AccessDeniedException so the denial surfaces as
  authored text, matching the existing two-catch shape.
  sellMeterList wires hasOverrideAccess, defaults it to FALSE (fail closed during the round trip
  and on wire error), sets actionDisabled on the YELLOW branch, keeps the 'Override' label, and
  ALSO refuses the 'override' action name in handleRowAction when access is false — the client
  gate is a UX affordance only.
  ⚠ Existing YELLOW-band Apex tests will go red without a System.runAs user holding the new
  permission. An admin-run denial test proves nothing — Modify All Data bypasses the gate.

ITEM 5b — the override reason:
  New bundle c/sellMeterOverrideModal (a LightningModal) REPLACES the LightningConfirm at
  sellMeterList.js:282-292. It keeps the existing wording, theme:'warning' and the property name
  in the message, and adds a REQUIRED lightning-textarea. Enforce required with a
  confirmDisabled getter — sellMeterInitiateModal.js:145-153 documents why the `required`
  attribute alone is decoration here. It resolves undefined on cancel, { reason } on confirm.
  sellMeterInitiateModal gains a PASS-THROUGH @api overrideReason that it does NOT render — this
  keeps the "override and initiate paths are deliberately identical" invariant its header defends.
  DispositionController/Service.initiateAndSubmit take a 3rd String parameter. Step 4 stamps, in
  the SAME DML as the insert and ONLY when the band is YELLOW:
     Sell_Decision_Trigger__c = 'Principal Decision'   (existing value — no picklist surgery)
     Sell_Meter_Override_Reason__c = overrideReason
  🔴 IT MUST BE AT INSERT. Sale_Decision_Approval sets recordEditability=AdminOnly and locks the
  record on the very next line.
  🔴 Sell_Decision_Trigger__c defaults to 'Sell Meter Green' and NOTHING writes it today, so every
  override currently presents to the approver as "Sell Meter Green". That is the defect this fixes.
  Do NOT add the reason to Sale_Decision_Approval's approvalPageFields — approvals are Tranche 3.
  Retract sellMeterList._confirmOverride's "there is still no override REASON field ... a
  deliberate scope decision" paragraph IN PLACE, quoting it, with the date and story number.
  Repoint the five LightningConfirm-based tests (:271-300, :605-655, :657-678) to the new modal.
  ⚠ LightningModal.open() is a static and the repo-local stub THROWS on purpose so an unmocked
  suite fails loudly — the new bundle needs the same jest.mock treatment as c/sellMeterInitiateModal.

Every class with SOQL must be a Selector. `with sharing` everywhere unless separately justified in
the class header. Jest + @sa11y/jest for every changed and new LWC bundle. SLDS 2 tokens — add no
new hardcoded colours (the existing band hex values are a pre-existing deviation and are OUT of
scope). Do NOT deploy.
```

---

## 9. Summary

- **5 of 5 items designed.** Nothing added, nothing expanded. Three candidate expansions
  (Calculated Value, `Sell_Ready_Argus`, `Argus_Signal__c` retirement) are raised as **decisions**,
  not built.
- **Fourteen premises in the request are incomplete or wrong** in ways that change the design. The
  three that would have produced a wrong build:
  - **P-5** — `Disposition_Deal_Actions` is granted to the **Analyst** set and is **forbidden** on
    the Principal set by its own file. Using it for item 5(a) would have shown the Override to
    analysts and hidden it from principals: the AC, exactly inverted.
  - **P-7** — a structured reason field (`Sell_Decision_Trigger__c`) **already exists**, is
    **already on the approval screen**, and **already reports "Sell Meter Green" on every
    override**. Item 5(b) is cheaper than scoped *and* fixes a live defect nobody had named.
  - **P-2** — repointing the band formula does **not** make Home and the Dashboard agree. Two more
    disagreements survive (population, and the Argus-filtered "Disposition Readiness" KPI). Shipping
    item 1 and reporting A3 closed would be wrong.
- ✅ **P-3 is the good news:** both fields are already formulas, so item 1 is an **in-place edit** —
  none of Tranche 1 item 6's delete+create machinery applies.
- ✅ **P-12:** items 2, 3 and 4 need **no FLS change whatsoever**. The only permission work in the
  tranche is the two new artefacts in item 5.
- **14 decisions (D-1 … D-14)** need confirmation before build; each carries a recommendation and
  its evidence.
- **7 gates (G-1 … G-7)** must pass before anything is written.
- **Highest-risk items:** 4 (sorting on pre-formatted strings + reversing an untested intentional
  feature), 5a (an inverted precedent, a reversed refusal, a capability removed from a live persona),
  5b (rewriting the bundle's most-tested interaction).
- **The single most valuable gate:** **G-1 and G-2 together.** Items 1 and 2 change three numbers on
  the principals' home screen and two donuts on their dashboard, and **not one of those changes
  produces a metadata diff anyone can review.** Measure them in `usman-dpeg` and show the BA the
  before/after before deploying, not after.
