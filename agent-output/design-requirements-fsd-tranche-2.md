# 📋 DESIGN REQUIREMENTS — DPEG Acquisitions FSD Gap Closure, Tranche 2

**Branch:** `feature/acquisitions-fsd-tranche-1` (as instructed — tranche 2 continues on the tranche-1 branch)
**Source:** `docs/DPEG Acquisitions Module Revised FSD v2_0.docx` §14.2, §18.3, §18.4, §23, §24.1, §24.2, §27.5
**Verified against:** repo @ 2026-08-16, after tranche 1 landed. `ARCHITECTURE.md`, `CLAUDE.md`, `.claude/rules/*` and `agent-output/design-requirements-fsd-tranche-1.md` read first.
**Scope:** requirements only. No implementation files written.

> ⚠ **ONE INFORMATION GAP, STATED UP FRONT.** This agent has **no execution tool** (no Bash, no Node, no shell), so `docs/DPEG Acquisitions Module Revised FSD v2_0.docx` **could not be extracted or read directly** — the Read tool refuses binary files. Everything below is verified against the **repo**, which is exhaustive; the **FSD's own wording** is taken from the brief's line-by-line summary. The one place this actually bites is §24.1's *"eight named Opportunity list views"* — the eight **names** are not available to me. The mapping in Item 3 is derived from the sub-state splits the brief quotes and happens to land on exactly eight active views, but the names must be confirmed (**Q3**).

---

## 🔴 PREMISE CORRECTIONS — READ BEFORE PRICING ANYTHING

Ten statements in the brief (or implied by it) were checked against the code. Each changes a design decision, and four of them **remove work**.

| # | Brief / FSD said | Repo says | Consequence |
|---|---|---|---|
| **P1** | Item 1: the market layer has "no callout service, no fetch button, no scheduled pull" | ✅ True — **and there is also a HALF-BUILT STUB the brief did not name.** `Opportunity.Placer_Last_Synced_DateTime__c` and `Opportunity.CoStar_Last_Synced_DateTime__c` exist, and their `<description>`s both read *"Stamped by the Sync button on the Placer/CoStar card."* **There is no Sync button anywhere in the repo** — verified: zero quickActions, zero LWC, zero Flow, zero Apex references. Their only other appearance is an FLS grant in `DPEG_Acquisition_Edit`. | "Last Synced" is not a field to invent — it is a field to **re-home and correct**. Two orphans whose descriptions assert automation that does not exist. |
| **P2** | 🔴 Implied: `Opportunity.Market_Cap_Rate__c` is a market-data mirror available for the snapshot | ❌ **It is OWNED by `flows/Underwriting_Opp_Sync`**, which copies `Underwriting__c.Market_Cap_Rate__c` (and `My_Cap_Rate__c`) onto the Opportunity on every Underwriting save. | Any market snapshot written to that field is **silently overwritten** on the next Underwriting edit. It is an **underwriting** mirror, not a market one. Do not touch it. |
| **P3** | Item 1: the freeze mechanism needs deciding, and `ApprovalAuditService`'s calling flows *"need* `<runInMode>SystemModeWithoutSharing</runInMode>`*"* | ✅ Correct trap — **already fixed in the exact flow this feature needs.** `flows/Opportunity_UW_Approved_Notify` already carries `<runInMode>SystemModeWithoutSharing</runInMode>`, is `RecordAfterSave` on Opportunity filtered `Underwriting_Status__c = 'Approved by Principals'` with `doesRequireRecordChangedToMeetCriteria = true` (entry semantics), and **already calls invocable Apex that updates the Opportunity and works.** `Underwriting_Approval.finalApprovalRecordLock = false`. | The freeze is **one more `actionCall` in a flow that is already proven to write to the Opportunity in the approver's transaction.** No new flow, no queueable, no approval-lock analysis, no `runInMode` change. |
| **P4** | Item 2 gap #3: "IR is currently notified on LOI SIGNED, not on entering the LOI stage" | ✅ True, **and the Acquisitions half of #3 is already delivered** — `Opportunity_UW_Approved_Notify` sends *"Underwriting approved - LOI pending"* to `Acquisitions_Team`. | But see P5: it is delivered on **one route only**. |
| **P5** | 🔴 Item 2 gap #5: "`PSA_Ready_Notify` notifies Acquisitions only; Legal is on `PSA_Version_Notify` instead" | ❌ **Those are not the same event.** `PSA_Ready_Notify` fires on `Contract_Review__c.Negotiation_Status__c ∈ {Ready for Execution, Signed}` — a **document** milestone late in the PSA phase. FSD #5's event is **the DEAL entering `Under Contract (PSA)`**, for which **no flow exists at all**. | Gap #5 is a **new flow**, not an edit to `PSA_Ready_Notify`. Adding `Legal_Team` to `PSA_Ready_Notify` would notify Legal at the wrong moment and on both PSA record types (that flow deliberately serves acquisition **and** disposition). |
| **P6** | 🔴 Item 3 §24.2: "add a **Top 5 Largest Deals** LWC" | ❌ **It is already built and already on `flexipages/Lead_Funnel`.** The bundle is named `recentOpportunities`, but `OpportunityFunnelController.getRecentOpportunities` reads *"Top 5 deals by asking price (largest first); deals without an asking price sort last"* and calls `OpportunitySelector.selectTopByAskingPrice(5)`. Columns are Deal Name / Stage / Deal Type / Asking Price / NOI / Age. | The component is **misnamed, not missing.** The only real gap is the FSD's *"any stage except Closed"*: `selectTopByAskingPrice` has **no stage filter at all**, so Closed Won and Dead/Pass deals occupy the list today. **One query clause + one label.** |
| **P7** | Item 3 §24.2: "replace the **standard** Recent Leads component" | ❌ `recentLeads` is a **custom LWC** (`masterLabel 'Recent Leads'`, description *"Recent Acquisitions leads with stage, channel, guidance price, and broker protection expiry"*, six columns including data-completeness and broker-protection age). | §24.2's replacement ask is **already satisfied**. Nothing to do. |
| **P8** | Item 3 §24.1: split the LOI view three ways and the PSA view two ways | ⚠ **A Salesforce list-view filter cannot traverse a lookup.** Opportunity has exactly **one** `LOI` stage and **one** `Under Contract (PSA)` stage; the five sub-states are **child-record** states (`LOI__c` / `Contract_Review__c`). | The splits require a **formula field on Opportunity** — which is precisely the mechanism the five deployed `Deal_Tracker_*` views already use via `Deal_Bucket__c`. See Item 3 for the one risk this carries. |
| **P9** | 🔴 Item 3: *"Dead and Disqualified deals are hidden from every active list view is an explicit FSD requirement — verify"* | ❌ **Not satisfied, and the reason is worse than a missing filter.** Measured across all ten views: the five `Deal_Tracker_*` views and `Offers_Due_Soon` **do** exclude dead (via `Deal_Bucket__c`'s stage clause / an explicit `StageName notEqual`). `All_Deals` (label **"Active Deals"**) and `Default_Opportunity_Pipeline` carry **no dead exclusion whatsoever**. `Live_Deals` filters `Deal_Category__c = 'Live'` — and **nothing in the entire application ever writes `Deal_Category__c = 'Dead'`**: the sole writer is `flows/Transaction_Complete_Close`, which writes `'Closed'`, and the field is a restricted picklist **defaulting to `Live`**. | "Live Deals" shows dead deals, permanently and silently. And a deal that reaches Closed Won via the Advance Stage button (not via `Transaction_Complete_Close`) keeps `Deal_Category__c = 'Live'` and stays in "Live Deals" for ever — the same route-vs-state defect recorded elsewhere in this repo. **Filter on `StageName`, never on `Deal_Category__c`.** |
| **P10** | Item 2: "there is no Development or Construction group" | ✅ Confirmed — 10 groups exist (`Acquisitions_Team`, `DPEG_Acquisitions_Team`, `Legal_Team`, `Investor_Relations`, `Transactions_Team`, `DPEG_Transactions_Team`, `Due_Diligence`, `Principals`, `LOI_Panel`, `DPEG_Property_Mgmt_Team`) and none is Dev/Construction. ⚠ Group **files carry no members** (`Acquisitions_Team.group-meta.xml` is `doesIncludeBosses` + `name` only), confirming membership is not deployable. | Creating the group is a **prerequisite deliverable**, and populating it is a **post-deploy gate**. See the `GroupNotifier` note in Item 2 for why an empty group is not merely quiet. |

---

## 🎯 WHAT THE USER REQUESTED

Three FSD gap-closure items, requirements only:
1. The **market data MANUAL layer** (§18.4 "Integration Off" fallback, §27.5), designed so the eventual ASB integration is a data-source flip — including the §18.3 **snapshot-and-freeze at underwriting lock**.
2. **Notification recipient corrections** (§23 gaps #1, #3, #5, #7, and FSD stage 8).
3. **Home page and list views** (§24.1, §24.2).

Nothing beyond this is proposed. Findings outside these three items are listed in one place at the end and are **not** folded into the build.

---

# ITEM 1 — Market data MANUAL layer + snapshot-and-freeze

## 1.1 The shape of the answer

Two layers, on two objects, for one reason each:

| Layer | Object | Contents | Why there |
|---|---|---|---|
| **LIVE** | `Property__c` | provider metrics + per-provider control fields (`Data Source`, `Last Synced`, `Fetch Status`) | This is where the whole market block **already** lives (`Placer_URL__c`, `CoStar_URL__c`, `Monthly_Visits__c`, `Trade_Area_Population__c`, `Market_Rent_PSF__c`, `Market_Cap_Rate__c`, …). Market data is a property of the **property**, not of a deal — two deals can target one property (`PropertyAssetService`'s idempotency key is the Property for exactly this reason). An ASB spoke would key on address/property. |
| **SNAPSHOT** | `Opportunity` | `Market_Data_Snapshot__c` + `Market_Data_As_Of_Date__c`, written once on entry to underwriting approval | The freeze must be **per-deal**. Freezing the Property would freeze it for the *other* deal too, and would block the very integration the design exists to enable. It also sits alongside the existing approval audit stamps (`UW_Approved_By__c`, `UW_Approval_Date__c`). |

🔴 **This split is what makes the integration a data-source flip.** When ASB exposes a spoke, it populates the same `Property__c` fields, sets `*_Data_Source__c = 'Integrated'` and stamps `*_Last_Synced_DateTime__c`. Nothing downstream changes: the manual layer, the record page, the snapshot composer and the freeze are all provider-agnostic.

## 1.2 Field reconciliation — ADOPT / CREATE / LEAVE ALONE

### ADOPT (existing fields; do NOT create a second one)

| Existing field | FSD name it satisfies | Note |
|---|---|---|
| `Property__c.Market_Rent_PSF__c` (Currency) | CoStar → **Market Rent (PSF)** | Exact match. Conforms to §1 rule 5 (per-unit rate, suffix the unit). **Creating a `CoStar_Market_Rent_PSF__c` would be the duplication the brief explicitly forbids.** |
| `Property__c.Market_Cap_Rate__c` (Percent, `<description>` = *"CoStar via ASB (stub)"*) | CoStar market cap rate | Already labelled as a CoStar stub. Adopt. |
| `Property__c.Placer_Fetch_Status__c` (restricted picklist Success / Error) | Placer → **Sync Status** | Adopt under its existing name rather than creating `Placer_Sync_Status__c`. ⚠ **Add a third value `Not Synced` and make it the default** — today both values are `<default>false</default>`, so a manually-entered property reads blank, which is indistinguishable from "never attempted". |
| `Property__c.Placer_URL__c`, `CoStar_URL__c` | §18.4 link layer | Already done. Untouched. |
| `Property__c.Monthly_Visits__c`, `Trade_Area_Population__c`, `Peak_Hour__c`, `YoY_Growth__c`, `Visitor_Demographics__c`, `Comp_Monthly_Visits__c`, `Comp_Sales__c` | the Placer body the FSD's ranks sit alongside | **Leave alone.** They become the Placer block governed by `Placer_Data_Source__c`. No renames — a rename is delete-and-recreate on this platform. |
| `Property__c.Days_On_Market_Avg__c`, `Occupancy_Rate_Market__c` | not FSD-named | **Leave alone** — see the `% Leased` note below. |

### CREATE on `Property__c` (12 fields)

**Placer snapshot block (FSD §18.4):**

| Field | Type | Note |
|---|---|---|
| `Placer_State_Rank__c` | Number(6,0) | |
| `Placer_State_Percentile__c` | Percent(5,2) | |
| `Placer_MSA_Rank__c` | Number(6,0) | |
| `Placer_National_Rank__c` | Number(6,0) | |

**CoStar snapshot block (FSD §18.4):**

| Field | Type | Note |
|---|---|---|
| `CoStar_Pct_Leased__c` | Percent(5,2) | 🔴 **Deliberately NOT folded into `Occupancy_Rate_Market__c`.** Leased ≠ occupied in CRE — a signed-but-not-yet-occupied space is leased and not occupied. Collapsing them would silently change what an existing field means, which is the `Unit__c` Text-vs-MasterDetail defect class (§1 rule 9 prohibition 1). §1 rule 9 mandates the `_Pct__c` suffix for a Number whose name would otherwise read categorical. |
| `CoStar_Location_Score__c` | Number(4,1) | `_Score__c` per §1 rule 9. |
| `CoStar_Asking_Rent_PSF__c` | Currency | §1 rule 5 — per-unit rate, suffix the unit. Distinct from `Market_Rent_PSF__c`: asking is what the landlord wants, market is what the market clears at. |
| `CoStar_Exit_Cap_Rate__c` | Percent(5,2) | The FSD names *"Cap Compression / Exit Cap"* as one line. **Store the exit cap only.** "Compression" is a derived comparison (exit vs entry/market) whose exact definition the FSD does not give, and a stored field with an unstated definition is the "confident wrong answer" failure mode. Flagged as an out-of-scope finding. |

**Control fields (§18.4 "Data Source / Last Synced / Sync Status", per provider):**

| Field | Type | Note |
|---|---|---|
| `Placer_Data_Source__c` | restricted picklist: `Manual` (default) / `Integrated` | |
| `CoStar_Data_Source__c` | restricted picklist: `Manual` (default) / `Integrated` | |
| `Placer_Last_Synced_DateTime__c` | DateTime | §1 rule 6 / rule 9 — `_DateTime__c`, never `_Date`. |
| `CoStar_Last_Synced_DateTime__c` | DateTime | as above |
| `CoStar_Fetch_Status__c` | restricted picklist: `Not Synced` (default) / `Success` / `Error` | Twin of the adopted `Placer_Fetch_Status__c`, same three values. |

⚠ **`*_Data_Source__c` has NO consumer today and that is correct.** Nothing branches on it and nothing should — it is a **provenance label**, not a switch. Building a switch with only one branch is how a feature ships inert. Its value arrives the day the spoke lands, when a human can tell a typed number from a fetched one at a glance and the flip is a data change.

### CREATE on `Opportunity` (2 fields — the snapshot)

| Field | Type | Note |
|---|---|---|
| `Market_Data_As_Of_Date__c` | Date | The FSD's "Market Data As-Of Date". Deliberately on the **snapshot** layer, not the live one — the live layer's freshness is already carried by the two `*_Last_Synced_DateTime__c` fields, and a third overlapping date is how two surfaces come to disagree. |
| `Market_Data_Snapshot__c` | Long Text Area (32,768) | The frozen, composed, human-readable copy of every market value at underwriting lock. **See Q1 — this is the one genuine user decision in this tranche.** |

### LEAVE ALONE — and say why in the file

| Field | Verdict |
|---|---|
| `Opportunity.Market_Cap_Rate__c`, `Opportunity.My_Cap_Rate__c` | 🔴 **DO NOT TOUCH.** Owned by `flows/Underwriting_Opp_Sync` (P2). Any market value written here is silently overwritten. |
| `Opportunity.Monthly_Visits__c` | Leave. Its own `<description>` already admits *"Mirrors `Property__c.Monthly_Visits__c`; the two are not reconciled."* It is the duplication this design exists to stop repeating. **Do not extend the pattern; do not add a second one.** |
| `Opportunity.Placer_Last_Synced_DateTime__c`, `Opportunity.CoStar_Last_Synced_DateTime__c` | Orphans (P1). **Recommend: correct their `<description>` only**, to state that no Sync button exists and that the live sync markers now live on `Property__c`. Deleting them is a separate change (field deletion is blocked by references, and they carry FLS grants in `DPEG_Acquisition_Edit`) — flagged as a follow-up, not folded in. |

## 1.3 🔴 The freeze mechanism — the substantive design question

### Freeze by SNAPSHOT, never by LOCK

The obvious mechanism — a `Market_Data_Locked__c` checkbox plus validation rules refusing edits to the market fields — is **wrong here, on three independent grounds**:

1. **It freezes the wrong scope.** The market fields live on `Property__c`, which is shared by every deal targeting that property. Locking at Deal A's underwriting approval freezes the data for Deal B, which has not been underwritten at all.
2. **It blocks the thing this whole design exists to enable.** The point of §18.4 is that an ASB spoke will one day keep refreshing these fields. A lock that prevents refresh is a lock that must be removed the day the integration ships.
3. **It solves the wrong problem.** §18.3's stated intent is *"later refreshes cannot silently change numbers principals already reviewed"* — that is an **evidentiary** requirement about what was reviewed, not a prohibition on the data moving.

⇒ **The live layer keeps moving; the reviewed numbers are copied, once, at lock.**

### Where it lives — and why the answer is already sitting in the repo

`flows/Opportunity_UW_Approved_Notify`:

```
object            Opportunity
triggerType       RecordAfterSave
filter            Underwriting_Status__c = 'Approved by Principals'
doesRequireRecordChangedToMeetCriteria   true      ← ENTRY semantics, fires once per transition
runInMode         SystemModeWithoutSharing          ← ALREADY SET
actionCalls       Stamp_Approval_Audit (ApprovalAuditService)  →  Notify_LOI_Pending
```

Every hazard the brief warned about is **already closed in this one file**:

- 🔴 **The approver is read-only on Opportunity.** That is the incident recorded in ARCHITECTURE §2 (`System.TypeException: DML operation UPDATE not allowed on Opportunity`, which is **not** a `DmlException` and so escaped the class's own catch and rolled back the whole approval). This flow already carries `<runInMode>SystemModeWithoutSharing</runInMode>`, and `ApprovalAuditService` already performs an Opportunity `update` from inside it **and works today**. That is a live proof, not an inference.
- **The approval record lock.** `Opportunity.Underwriting_Approval` declares `<finalApprovalRecordLock>false</finalApprovalRecordLock>`, so the record is unlocked when the final approval actions fire. No `ENTITY_IS_LOCKED`, no deferred queueable (contrast `LoiPrimaryStampQueueable` / `DispositionNdaStampQueueable`, both of which exist because their records **are** locked).
- **Entry semantics.** `doesRequireRecordChangedToMeetCriteria = true` means the snapshot happens on the **transition into** approval, not on every subsequent save.

⇒ **The freeze is one additional `actionCall`, chained after `Stamp_Approval_Audit`.** No new flow, no new trigger, no queueable, no `runInMode` change, no lock analysis.

⚠ **Re-approval RE-SNAPSHOTS, deliberately.** If underwriting is rejected and re-approved, the second approval reviewed the data as it then stood, so the snapshot should follow it. Entry semantics guarantee this happens only on a genuine transition. Do **not** make it fill-if-blank: that would leave principals' second review permanently misrepresented by their first.

### Why Apex rather than a flow record-update

The composition is ~15 nullable values into one labelled, ordered block. In Flow that is a formula resource that has to null-guard every value, and it would live in a file nobody diffs. In Apex it is one method, and — decisively — **the live layer and the frozen text are then composed in exactly one place, so they cannot drift.** The flow already calls invocable Apex (`ApprovalAuditService`), so this adds a second `actionCall` and no new mechanism.

### `MarketDataSnapshotService` — the four decisions that matter

1. **`@InvocableMethod` signature.** `List<Request>` in, `List<Result>` out, both inner classes with `@InvocableVariable` — per `.claude/rules/invocable-rule.md`. `ApprovalAuditService` is the in-repo precedent. Flow batches interviews, so a single-record signature would silently drop every record but the first.

2. **ONE query, and it is `WITH SYSTEM_MODE`.** Read the Opportunities by Id, traversing the parent: `SELECT Id, Property__c, Property__r.<the market field set> FROM Opportunity WHERE Id IN :ids WITH SYSTEM_MODE`. It belongs in `OpportunitySelector` (a new method), **not** in the service — `.claude/rules/apex-layering-rule.md`.
   - **MODE is not optional.** Every field in that SELECT is a Metadata-API-deployed custom, and such fields arrive with **no FLS for any profile, System Administrator included**. Under `USER_MODE` the read throws `System.QueryException: No such column …` — which is an **FLS denial wearing a schema error** — inside an invocable called from an approval-triggered flow, i.e. it takes the approval down with it.
   - ⚠ **SHARING is a SEPARATE question and the recommended shape sidesteps it.** Parent-lookup traversal in SOQL is not sharing-filtered — sharing filters the **root** rows, and the approver can see the Opportunity they just approved. Reading the Property **as the root object** would raise the full `PropertySelector` sharing problem (`Property__c` is `sharingModel Private`; its single sharing rule is an **owner** rule scoped to rows owned by the `Acquisition` **queue**, and a `LeadConvertService`-created Property is owned by the converter, so a principal approver is not reached — the read would return zero rows and the snapshot would be **silently empty while the As-Of Date stamped**). ⇒ **Traverse from Opportunity. Do not add a root-level `Property__c` read.** If traversal turns out to be filtered, the fallback is a `private without sharing` inner class on `PropertySelector`, mirroring the existing `FolderCreationReads` / `AssetCreationReads` — named here so nobody has to rediscover it.

3. **The catch must be WIDE and must be SELF-REPORTING.** ARCHITECTURE §2 records both halves of this: a `DmlException`-only catch let a `TypeException` roll back an approval, **and** the widened catch alone would have been *worse* than the bug, because the approval would then succeed while the stamp stayed silently blank. So:
   - `catch (Exception e)` — wide, because a `QueryException` is not a `DmlException`.
   - 🔴 **On failure, write the reason INTO `Market_Data_Snapshot__c`** (`"Market data snapshot failed: <message>"`). A snapshot field that reports its own absence costs nothing and turns the exact failure that used to be invisible into something a human reads on the record. This is the answer to "the widened catch is silent".
   - Never rethrow. A market snapshot must never roll back an approval.

4. **DML is `Database.update(list, false, AccessLevel.SYSTEM_MODE)`.** The approver holds Read, not Edit, on Opportunity (`DPEG Principal PSG`, measured and recorded in ARCHITECTURE), and the two new fields have no FLS for anyone. `allOrNone = false` so one bad row cannot take the batch — and the failed row's absence is visible on the record itself, per (3).

**Governor budget: 1 SOQL / 1 DML per invocation, CONSTANT in record count.** No SOQL or DML in loops.

### Residuals, stated rather than hidden

- **R1 — a deal with no `Property__c` gets an empty snapshot.** Only `LeadConvertService` creates and links a Property, so a manually built deal has none. Same residual as `PropertyAssetService` (R1) and `DealFolderService` (R1). ⇒ **Write `"No property linked to this deal — no market data to snapshot."` into the field** rather than leaving it blank, so the state is legible.
- **R2 — a deal approved BEFORE deploy day has no snapshot, for ever.** Entry semantics see only transitions from deploy forward. Same shape as `DealFolderService` R5. No remedy is proposed; a one-off anonymous-Apex backfill is the named option if it is ever wanted.
- **R3 — the snapshot records what the *Property* held, not what a principal actually looked at.** If a principal read a CoStar tab in a browser rather than the record, the snapshot is not evidence of that. The FSD's requirement is about the fields, so this is in scope of the ask; it is recorded so the field is not later over-claimed.

## 1.4 Surfacing

The new Property fields must be visible or the "manual layer" does not exist. `Property__c` has **no flexipage** in this repo — it uses `layouts/Property__c-Property Layout.layout-meta.xml`. ⇒ add two layout sections, **"Placer.ai"** and **"CoStar"**, each holding its provider's metrics **plus its three control fields**.

The two Opportunity snapshot fields go on `flexipages/Opportunity_Record_Page`, **read-only** (`uiBehavior: readonly`), next to the existing `UW_Approved_By__c` / `UW_Approval_Date__c` block.

⚠ **Field instances only — no quick actions.** Adding a quick action to a flexipage in App Builder silently empties that page's inherited action list (recorded repo incident; no test catches it). Nothing here needs one.

🔴 **FOUND, NOT REQUESTED — the Opportunity record page already has mis-wired "Placer" and "CoStar" sections.** `flexipage_fieldSection12` (label **"Placer"**) resolves through `Facet-sf20vh0mky` → `Facet-9vvjxhojbz8`, which contains **`OneDrive_Folder_URL__c`** and nothing else. `flexipage_fieldSection13` (label **"CoStar"**) contains only `CoStar_URL__c` plus an empty column. Meanwhile `Placer_URL__c` sits in an unrelated facet alongside `Rejection_Reason__c` and `Offer_Due_Date__c`. See **Q2** — repairing this is cheap and directly serves the item, but it was not requested.

---

# ITEM 2 — Notification recipient corrections (FSD §23)

## 2.1 🔴 The governing decision: key on the STATE, not on the ROUTE

Three of the five gaps are "when the deal reaches stage X, tell teams A and B". The tempting fix is to add an `actionCall` to whichever flow already fires near that moment. **That is wrong here and the repo already paid for it once** (`StageAdvanceService.NEXT_STAGE`'s own comment: *"reach 'Closed Won' from EITHER key, so half the closes carry no `Transaction__c` at all"*).

Measured for this tranche:

- `NEXT_STAGE` contains **no `'Underwriting' => 'LOI'` entry** — the Advance Stage button routes Underwriting into the **approval**, and `Underwriting_Approval`'s final action `UW_Set_Stage_Initiate_LOI` writes the stage. But a human can still move the stage from the **Path** or by editing the record. ⇒ hanging the LOI notification off `Opportunity_UW_Approved_Notify` covers **one of two routes**, and the miss is invisible.
- `Closed Won` is reachable from **`Under Contract (PSA)`** and from **`About to Close`** via the button, **and** from `flows/Transaction_Complete_Close`. Three routes.

⇒ **Build gaps #3, #5 and stage 8 as three new stage-ENTRY flows on `Opportunity`.** Each is `RecordAfterSave`, `recordTriggerType CreateAndUpdate`, `doesRequireRecordChangedToMeetCriteria true`, with a **single-value** `StageName` filter.

🔴 **THREE FLOWS, NOT ONE — and the reason is a platform mechanism, not style.** A single flow with `filterLogic or` across the three stage values would **never fire on the LOI → Under Contract (PSA) transition**: the record already satisfied the OR at `LOI`, so it does not *change to meet* the criteria and `doesRequireRecordChangedToMeetCriteria` suppresses it. One value per flow is the only shape in which entry semantics are expressible for adjacent stages.

⚠ **All three new flows take `<runInMode>SystemModeWithoutSharing</runInMode>`.** `Transaction_Complete_Close` writes `StageName = 'Closed Won'` with **no `<runInMode>`**, i.e. as the Transactions persona, and `DPEG_Transaction_Team` is not an acquisitions persona. `GroupNotifier` is `without sharing` and its selectors are already `SYSTEM_MODE` (the "Notifier automation" row in ARCHITECTURE §2), so this is belt-and-braces — but it costs nothing and removes the exact failure class that took down `ApprovalAuditService`.

## 2.2 The five gaps

| FSD | Event | Today | Change |
|---|---|---|---|
| **#1** | Dev / Construction Review completed | `Dev_Review_Opinion_Notify` and `Con_Review_Opinion_Notify` each send ONE notification, to `Acquisitions_Team` | **+1 `actionCall` in each flow**, to the new `Development_Construction_Team` group. Chain it after the existing call; do not replace it. |
| **#3** | Deal moves to **LOI** | `Opportunity_UW_Approved_Notify` sends "Underwriting approved - LOI pending" to `Acquisitions_Team` — **approval route only** (P4 + §2.1) | **NEW `Opportunity_LOI_Entry_Notify`** (`StageName = 'LOI'`) → `Acquisitions_Team` **and** `Investor_Relations`. **AND remove `Notify_LOI_Pending` from `Opportunity_UW_Approved_Notify`**, re-pointing `Stamp_Approval_Audit`'s connector at the new market-snapshot action (Item 1). Otherwise the approval route double-notifies Acquisitions. |
| **#5** | Deal moves to **Under Contract (PSA)** | **nothing** — `PSA_Ready_Notify` is a different, later, document-level event (P5) | **NEW `Opportunity_PSA_Entry_Notify`** (`StageName = 'Under Contract (PSA)'`) → `Acquisitions_Team` **and** `Legal_Team`. **Leave `PSA_Ready_Notify` and `PSA_Version_Notify` alone** — both are correct for their own events and `PSA_Ready_Notify` deliberately serves both PSA record types. |
| **#7** | PSA executed | `ContractExecutionService.stampOpportunities` batches three notifications: `Transactions_Team`, `Investor_Relations`, `Due_Diligence` | **+1 `buildNotification('Acquisitions_Team', …)`** inside the existing loop. One line. See the budget note below. |
| **stage 8** | Closed Won → Property Asset created; PM and IR notified | `PropertyAssetService.ensureOnClosedWon` creates the asset; **no notification anywhere** | **NEW `Opportunity_Closed_Won_Notify`** (`StageName = 'Closed Won'`) → `DPEG_Property_Mgmt_Team` **and** `Investor_Relations`. |

🔴 **Why stage 8 is a FLOW and not a line in `PropertyAssetService`.** Two reasons, and the second is the sharper one: (a) `PropertyAssetService` is trigger-bound while the FSD's event is the stage entry, and a flow keyed on stage entry covers `Transaction_Complete_Close` as well as both button routes; (b) **`PropertyAssetService` skips a deal with a null `Property__c` entirely and silently** (its documented residual). A notification hung there would inherit that skip — the deals most in need of a human's attention would be the ones nobody is told about.

## 2.3 The new group

**`Development_Construction_Team`** — one Regular group, `doesIncludeBosses true`, matching `Acquisitions_Team.group-meta.xml`.

**One group, not two.** The FSD names *"Development & Construction Team"* as a single team, both review flows notify the same audience, and one group is one membership gate rather than two. (**Q — resolved by recommendation, not asked**: if the two functions later need separating, adding a second group and a second `actionCall` is additive.)

🔴 **An empty group is not merely quiet — read `GroupNotifier` before assuming otherwise.** Its `resolveRecipients` falls back to the **group's own Id** when a group has no user members, and its own comment qualifies that fallback as *"proven to work for queues"* — a **Queue**, not a Regular group. Its `send` comment then records the measured behaviour that matters: *"ONE BAD ID KILLS THE WHOLE CALL … a recipient Id that resolves to nothing raises `System.HandledException: Invalid parameter value for: recipientIds` and NO recipient in the set is notified."* Failure is caught and degrades to a debug line, so nothing errors visibly. ⇒ **populating the group is post-deploy gate G1**, and it is load-bearing rather than tidy-up.

## 2.4 The one governor note, with the arithmetic

`GroupNotifier`'s measured cost model (its own header, measured on `usman-dpeg` 2026-08-14) is **≈ 6.0 ms CPU + 0.22 ms × |recipients| per `send()`**, with zero SOQL and zero DML per send. `ContractExecutionService.stampOpportunities` sends **3 notifications per Opportunity**; gap #7 makes it **4**.

At a full 200-row `Contract_Review__c` chunk that is **600 → 800 sends**, i.e. roughly **3.7 s → 5.0 s** of synchronous CPU against a **10 s** limit, before the rest of the transaction. This is a **pre-existing** exposure that gap #7 widens by ~25%, not a new one, and a 200-row chunk of PSAs simultaneously flipping to `Executed` is a data-load scenario rather than an ordinary day. **Recommendation: build it as asked, and record the arithmetic in the class header** so the next person adding a fifth recipient does it with the number in front of them.

---

# ITEM 3 — Home page and list views (FSD §24)

## 3.1 §24.2 — Home page: three asks, two already done

| Ask | Verdict |
|---|---|
| Replace the standard Recent Leads component | ✅ **Already done** (P7). `recentLeads` is a custom LWC. **No work.** |
| Add a **Top 5 Largest Deals** component | ✅ **Already built** (P6) — it is `recentOpportunities`, already on `flexipages/Lead_Funnel`, already ordered `Asking_Price__c DESC NULLS LAST`. |
| …showing the five biggest **active** deals, **any stage except Closed** | ❌ **This is the only real gap.** `OpportunitySelector.selectTopByAskingPrice` has **no stage filter at all**, so Closed Won and Dead/Pass deals occupy the list. |
| §14.2 portfolio deals on the home page | 🚩 **DEFER to tranche 3.** `Portfolio_Deal__c` and `Is_Portfolio_Parent__c` exist and are read/written by **nothing** — verified repo-wide (only three permission sets, one path assistant and one report reference them). A home-page component over two fields nothing maintains renders permanent zeroes. |

### The change

1. **`OpportunitySelector.selectTopByAskingPrice(Integer maxRows)`** gains `WHERE StageName NOT IN ('Closed Won', 'Dead/Pass')`.
   - ⚠ Use `NOT IN` on **`StageName`**, never on `Deal_Category__c` (P9 — nothing ever writes `'Dead'`).
   - ⚠ `'Dead/Pass'` is the **literal** form in Apex and in list-view filters; `Dead%2FPass` is required only inside `BusinessProcess` / `RecordType` / picklist metadata. Getting this backwards yields a filter that silently never matches.
   - ⚠ **This is a behaviour change for the method's only caller.** `OpportunitySelectorTest.selectTopByAskingPrice_ordersDescendingAndLimits` builds its fixture without a stage filter in mind — if any fixture row sits on a closed stage, that test now fails. **This is one of the two places in this tranche where "no tests run" genuinely bites** (see G6).
2. **The LWC is renamed by LABEL only.** Change `recentOpportunities.js-meta.xml`'s `<masterLabel>` to `Top 5 Largest Deals` and the card heading in `recentOpportunities.html`. **Do NOT rename the bundle** — that is a new folder, a deleted folder, a `flexipages/Lead_Funnel` edit and a Jest path change, for a label. Add a one-line header comment recording that the bundle name is historical.

## 3.2 §24.1 — Opportunity list views

### The mechanism, and its one risk

The FSD's splits are **child-record states**; a list-view filter cannot traverse a lookup (P8). The in-repo answer is already deployed: `Deal_Bucket__c` is a **text formula on Opportunity** and the five `Deal_Tracker_*` views filter `Deal_Bucket__c equals <value>`. ⇒ **one new text formula field, `Opportunity.Deal_Sub_Stage__c`, filtered by five new views.**

🔴 **THE SINGLE HIGHEST-RISK ASSUMPTION IN THIS TRANCHE, STATED PLAINLY.** `Deal_Bucket__c` proves that a **same-object** formula is filterable in a list view. It does **not** prove that a **cross-object** formula is. The design below therefore keeps **three of five branches same-object** so the fallback is cheap:

| Branch | Reads | If cross-object filtering fails |
|---|---|---|
| `PSA - Executed` | `Contract_Signed__c` (same object) | unaffected |
| `PSA - Negotiation` | `Contract_Signed__c` (same object) | unaffected |
| `LOI - Pending` | `LOI_Approved__c` (same object) | unaffected |
| `LOI - Submitted` | `LOI_Approved__c` + `Primary_LOI__r.LOI_Signed__c` | needs an Opportunity-level mirror of LOI signature |
| `LOI - Accepted` | `Primary_LOI__r.LOI_Signed__c` | as above |

**Named fallback:** a `Checkbox` on Opportunity maintained by the already-live `flows/LOI_Signed_Notify` (which fires on exactly `LOI__c.LOI_Signed__c = true`), turning the formula fully same-object. Do not build it speculatively — verify first (**G2**).

### `Opportunity.Deal_Sub_Stage__c` — Text formula

```
IF( OR( ISPICKVAL(StageName, 'Dead/Pass'), ISPICKVAL(Deal_Category__c, 'Dead') ), '',
IF( ISPICKVAL(StageName, 'LOI'),
      IF( AND( NOT(ISBLANK(Primary_LOI__c)), Primary_LOI__r.LOI_Signed__c ), 'LOI - Accepted',
      IF( LOI_Approved__c,                                                    'LOI - Submitted',
                                                                              'LOI - Pending' ) ),
IF( ISPICKVAL(StageName, 'Under Contract (PSA)'),
      IF( Contract_Signed__c, 'PSA - Executed', 'PSA - Negotiation' ),
      '' ) ) )
```

Six things about it are load-bearing:

1. **Dead is tested FIRST and returns blank**, so all five sub-views inherit the dead exclusion for free and cannot drift from it. Same shape as `Deal_Bucket__c`.
2. **A blank `Primary_LOI__c` / `Primary_Contract__c` falls to the ENTRY state, not to blank.** Tranche 1 established (Item 3, c-2) that `Primary_Contract__c` is stamped only for the Contract Review `OpportunityReviewService` itself creates, so an irregularly-created child leaves it null. A deal sitting at the LOI stage with no LOI record genuinely *is* "LOI - Pending". Failing to a meaningful bucket beats dropping out of every view.
3. **Acquisition-only, structurally.** Reaching through `Primary_LOI__c` from an Opportunity can only ever reach an acquisition LOI (a disposition LOI hangs off `Disposition__c` and has no Opportunity). That matters because `LOI__c.Stage__c`'s acquisition and disposition value sets **overlap at `Under Review`** since Phase 3 — the field's own header retracts the old "fully disjoint" claim. This formula never reads `Stage__c` **and** never reaches a disposition row, so the overlap cannot mislead it. Same structural argument tranche 1 used for the Offering shell.
4. **`LOI_Approved__c` means "DPEG approved sending the LOI", not "the seller accepted".** Its `<description>` is explicit. That is exactly the Pending→Submitted boundary.
5. **`Contract_Signed__c` is stamped by `ContractExecutionService` at PSA execution.** ⚠ Its `<description>` says *"Checked when the LOI is fully executed"* — **that description is stale and wrong**; the class header is authoritative. Flagged.
6. **Use `TEXT(...)`/`ISPICKVAL(...)`, never `==` on a picklist**, and never `ISPICKVAL` on `LOI__c.Stage__c` — the standing repo rule, because `Prepare/Review` carries a literal slash.

### The eight views

| # | View | Filter | Action |
|---|---|---|---|
| 1 | `Deal_Tracker_All` — *All Deals* | `Deal_Bucket__c notEqual Dead` | **keep** |
| 2 | `Deal_Tracker_Interested` — *Interested Deals* | `Deal_Bucket__c equals Interested Deals` | **keep** |
| 3 | `Deal_Tracker_LOI_Pending` | `Deal_Sub_Stage__c equals LOI - Pending` | **new** |
| 4 | `Deal_Tracker_LOI_Submitted` | `Deal_Sub_Stage__c equals LOI - Submitted` | **new** |
| 5 | `Deal_Tracker_LOI_Accepted` | `Deal_Sub_Stage__c equals LOI - Accepted` | **new** |
| 6 | `Deal_Tracker_PSA_Negotiation` | `Deal_Sub_Stage__c equals PSA - Negotiation` | **new** |
| 7 | `Deal_Tracker_PSA_Executed` | `Deal_Sub_Stage__c equals PSA - Executed` | **new** |
| 8 | `Deal_Tracker_Closed` — *Bought / Closed* | `Deal_Bucket__c equals Bought/Closed` | **keep** |

All five new views: `filterScope Everything`, same seven columns as the existing `Deal_Tracker_*` family (Name, StageName, `Deal_Status__c`, `Deal_Type__c`, `Asset_Type__c`, `Asking_Price__c`, CloseDate) plus `Deal_Sub_Stage__c`.

**Retire** `Deal_Tracker_LOI` and `Deal_Tracker_PSA` — superseded by the splits, and leaving them makes ten "Deal Tracker" views where the FSD names eight. (Alternative, one line: keep them as roll-ups and accept ten. Recommended: retire, via a destructive change.)

**Fix the dead-exclusion defect (P9)** — add `StageName notEqual Dead/Pass` to:
- `All_Deals` (label *"Active Deals"* — the worst offender: an active-labelled view with no dead exclusion at all)
- `Live_Deals`
- `Default_Opportunity_Pipeline`

⚠ **Do NOT "fix" `Live_Deals` by making something write `Deal_Category__c = 'Dead'`.** That would be a new stored field to maintain, with a backfill, to replace a filter that is one line. And it would not fix `All_Deals` or `Default_Opportunity_Pipeline` at all.

⚠ **"Disqualified" is a `Lead` status, not an Opportunity stage.** On Opportunity the analogue is `Dead/Pass`. The Lead half of the FSD sentence is already satisfied — `LeadFunnelController` / the Lead views handle it and are out of this item's scope.

---

# 🔵 ADMIN WORK (`salesforce-admin`)

| # | Item | Detail |
|---|---|---|
| **A1** | 12 new `Property__c` fields | The Placer block (4), the CoStar block (4) and the control fields (4), exactly as listed in §1.2. Every `<description>` must state whether the value is manually entered today and which provider owns it. |
| **A2** | `Property__c.Placer_Fetch_Status__c` — add a value | Add `Not Synced` and make it `<default>true</default>`. Additive; no existing row holds it. |
| **A3** | 2 new `Opportunity` fields | `Market_Data_As_Of_Date__c` (Date) and `Market_Data_Snapshot__c` (Long Text Area 32768). Descriptions must say both are **system-written at underwriting approval** and are not for manual entry. |
| **A4** | Correct 2 orphan descriptions | `Opportunity.Placer_Last_Synced_DateTime__c` / `CoStar_Last_Synced_DateTime__c`: state that no Sync button exists, that nothing reads or writes them, and that the live sync markers now live on `Property__c`. **Do not delete them in this tranche.** |
| **A5** | 1 new `Opportunity` formula field | `Deal_Sub_Stage__c`, Text formula, exactly as in §3.2, with the full rationale in an **XML comment INSIDE the root element** (never above it — that breaks `sf` deploy at conversion with *"unable to find matching parent xml file"*; `<description>` caps at 255). Precedent: `Deal_Bucket__c`. |
| **A6** | **FLS for A1 + A3 + A5, declared IN FILE** | `Property__c` fields → the three sets that already carry `Property__c.Monthly_Visits__c` / `Market_Rent_PSF__c` / `Placer_URL__c`: **`DPEG_Acquisition_Edit`** (editable), **`DPEG_Acquisition_View`** (readable), **`DPEG_Property_View`** (readable). `Opportunity` fields → the three that already carry `Opportunity.Deal_Bucket__c`: **`DPEG_Acquisition_Edit`**, **`DPEG_Acquisition_View`**, **`DPEG_Opportunity_View`**. ⚠ `Deal_Sub_Stage__c` is a formula → readable only. 🔴 **A `PermissionSet` deploy REPLACES its entire `<fieldPermissions>` set** — reconcile each file against the org before editing (paid twice on this project). |
| **A7** | `Property__c-Property Layout` | Two new sections, **"Placer.ai"** and **"CoStar"**, each holding its provider's metrics plus its three control fields. |
| **A8** | `Opportunity_Record_Page` | Add `Market_Data_As_Of_Date__c` and `Market_Data_Snapshot__c` as **read-only** field instances (`uiBehavior: readonly`) beside the UW approval stamps. **Field instances only — no quick action** (adding one silently empties the page's inherited action list). |
| **A9** | New group `Development_Construction_Team` | Regular, `doesIncludeBosses true`, mirroring `Acquisitions_Team.group-meta.xml`. Membership is **not deployable** → gate G1. |
| **A10** | Edit `Dev_Review_Opinion_Notify` + `Con_Review_Opinion_Notify` | One additional `GroupNotifier` `actionCall` each, `recipientGroup = Development_Construction_Team`, chained after the existing call. Do not change the existing call, its title or its entry criteria. |
| **A11** | 3 NEW flows | `Opportunity_LOI_Entry_Notify`, `Opportunity_PSA_Entry_Notify`, `Opportunity_Closed_Won_Notify`. All: `AutoLaunchedFlow`, `RecordAfterSave`, `CreateAndUpdate`, `object Opportunity`, **single-value `StageName` filter**, `doesRequireRecordChangedToMeetCriteria true`, `<runInMode>SystemModeWithoutSharing</runInMode>`, `apiVersion 67.0`. Recipients per §2.2. 🔴 The single-value filter is mandatory — see §2.1. |
| **A12** | Edit `Opportunity_UW_Approved_Notify` | **Remove** the `Notify_LOI_Pending` `actionCall` (superseded by A11's LOI-entry flow, which covers both routes) and re-point `Stamp_Approval_Audit`'s `<connector>` at the new `Snapshot_Market_Data` action (D3). Leave `runInMode`, the filter and `doesRequireRecordChangedToMeetCriteria` exactly as they are. |
| **A13** | 5 new Opportunity list views | Per the §3.2 table, `filterScope Everything`, columns as specified. |
| **A14** | 3 list-view fixes + 2 retirements | Add `StageName notEqual Dead/Pass` to `All_Deals`, `Live_Deals`, `Default_Opportunity_Pipeline`. Retire `Deal_Tracker_LOI` and `Deal_Tracker_PSA` (destructive change). |
| **A15** | *(conditional on Q2)* Repair the mis-wired Placer / CoStar sections on `Opportunity_Record_Page` | Not in scope unless the user says yes. |

**Complexity routing: `salesforce-admin`.** Fields, picklist values, FLS, a layout, flexipage field instances, one group, five flow files and eight list views. There is **no multi-object schema design, no OWD / sharing-model design, no subflow orchestration and no fault-path architecture** — every new flow is a two-node notify flow of the exact shape already deployed nine times in this repo. **Not `salesforce-solution-architect`.**

---

# 🟢 DEVELOPMENT WORK (`salesforce-developer`)

| # | Item | Detail |
|---|---|---|
| **D1** | **`OpportunitySelector.selectMarketSnapshotSourceByIds(Set<Id>)`** (new method) | Selects `Id, Name, Property__c` plus the traversed `Property__r.<market field set>`. 🔴 `WITH SYSTEM_MODE`, justified **at the method** on automation-path grounds (every field is a Metadata-API-deployed custom with no FLS for any profile, including the deploying administrator; a `USER_MODE` throw here takes the approval down). Class stays `with sharing` and **no `without sharing` inner class is added** — the root object is the Opportunity the approver just approved, and parent traversal is not sharing-filtered. Record the fallback (`PropertySelector.<…>Reads`) in the header rather than building it. |
| **D2** | **`MarketDataSnapshotService`** (new) | `@InvocableMethod`, `List<Request>` in / `List<Result>` out, inner DTOs with `@InvocableVariable` (`.claude/rules/invocable-rule.md`; `ApprovalAuditService` is the precedent). Composes the snapshot text, stamps `Market_Data_As_Of_Date__c = Date.today()` (captured **once**, never per record), and writes both fields. `Database.update(list, false, AccessLevel.SYSTEM_MODE)`. `catch (Exception e)` — **wide**, and **self-reporting**: on failure write the reason into `Market_Data_Snapshot__c`. Never rethrow. **1 SOQL / 1 DML per invocation, constant in record count.** |
| **D3** | **`flows/Opportunity_UW_Approved_Notify`** — the wiring half | The new `Snapshot_Market_Data` `actionCall` (`actionType apex`, `actionName MarketDataSnapshotService`) chained after `Stamp_Approval_Audit`. Paired with A12. |
| **D4** | **`ContractExecutionService.stampOpportunities`** (edit) | One `notifications.add(buildNotification('Acquisitions_Team', …, o.Id));` inside the existing loop (gap #7). Record the `GroupNotifier` CPU arithmetic (§2.4) in the class header. Change nothing else — the Offering shell, the Day-0 stamp and the three existing notifications are untouched. |
| **D5** | **`OpportunitySelector.selectTopByAskingPrice`** (edit) | Add `WHERE StageName NOT IN ('Closed Won', 'Dead/Pass')`. Literal `'Dead/Pass'`, not the encoded form. Amend the method Javadoc: it now backs a **"largest ACTIVE deals"** list. |
| **D6** | **`lwc/recentOpportunities`** (edit) | `<masterLabel>` → `Top 5 Largest Deals`; card heading in the `.html` to match. **Do not rename the bundle.** Add a header comment recording that the bundle name is historical and why it was not renamed. |
| **D7** | **Tests** | New: `MarketDataSnapshotServiceTest` (happy path; a deal with a null `Property__c` yields the "no property linked" text, not a blank; a re-approval re-snapshots; a failure writes its reason rather than throwing). Amended: `OpportunitySelectorTest.selectTopByAskingPrice_ordersDescendingAndLimits` must be re-checked against the new stage filter, and a case added proving a Closed Won row is excluded. `ContractExecutionServiceTest` must stay green with the fourth notification. ⚠ `.claude/rules/bulk-test-rule.md`'s **251-record** mandate applies to D2 (a Flow-invoked bulk entry point) with no exemption. |
| **D8** | **`ARCHITECTURE.md`** (edit, same PR — §6) | §1 `Property__c` row gains the market-data block and the two-layer split; §2 Key Apex Services gains `MarketDataSnapshotService`; the `WITH SYSTEM_MODE` table gains **one** row (`OpportunitySelector.selectMarketSnapshotSourceByIds`) arguing MODE and SHARING as **separate** decisions and recording why no `without sharing` inner class was needed; update the running "N `SYSTEM_MODE` queries across M selector classes" count. |

**Complexity routing: `salesforce-developer`.** One invocable service, two selector methods, a one-line service edit and an LWC label. **No integration, no Named Credentials, no callouts, no Platform Events, no LDV, no async.** 🔴 The Placer/CoStar **integration is explicitly out of scope** — this tranche builds the fallback mode the FSD specifies for when it is off. **Not `salesforce-technical-architect`.**

**Unit testing:** `salesforce-unit-testing` after D1–D6.

---

# 🔗 EXECUTION ORDER

1. **A1 → A2 → A3 → A5** — every field the Apex and the list views reference. Apex will not compile and list views will not deploy without them.
2. **A6** (FLS) — immediately after, in the **same** deploy wave. A field with no FLS is invisible to every persona including the deployer, and a `USER_MODE` reader throws `No such column`.
3. **A7 + A8** (surfacing) — the manual layer does not exist until a human can type into it.
4. **D1 → D2 → D3 + A12** (Item 1 freeze). D3 and A12 are **one edit to one file** and must land together; splitting them leaves the flow with a dangling connector.
5. **A9** (group) → **A10 + A11** (Item 2 flows) → **D4** (gap #7). A11 must land before A12 removes `Notify_LOI_Pending`, or Acquisitions loses a notification it has today (**G7**).
6. **D5 → D6** (Item 3 home page). Independent of everything above.
7. **A13 + A14** (list views) — **after A5 + A6**; a list view whose filter field does not exist, or which the deploying user cannot read, fails at deploy.
8. **D7** (tests) → **D8** (`ARCHITECTURE.md`, same PR per §6).
9. **A15** — only if the user answers yes to Q2.

---

# ❓ OPEN QUESTIONS — USER DECISION REQUIRED (Gate 1)

Three. Everything else in this document has a defensible default and has been decided rather than asked.

| # | Question | Options | Recommendation |
|---|---|---|---|
| **Q1** | 🔴 **What shape is the frozen market snapshot?** | **(a)** ONE composed Long Text `Market_Data_Snapshot__c` + `Market_Data_As_Of_Date__c`. **(b)** ~15 typed snapshot fields on Opportunity, one per live metric, + the date. | **(a).** Three reasons. (i) The snapshot's job is **evidentiary** — "what did the principals see" — and a labelled text block answers that completely. (ii) (b) costs ~15 new fields, ~15 FLS grants across three permission sets, ~15 assignments, **and a new field every time the market set grows** — and a metric added to the live layer but forgotten in the snapshot fails **silently**, with the snapshot still claiming completeness. (iii) (a) is composed by one method, so the live and frozen layers cannot drift. **Cost, stated:** a text block is **not reportable or filterable per metric**. If someone later wants "average market cap rate at underwriting lock across all deals", that needs (b). If that report is already known to be wanted, say so now — retrofitting typed fields means a backfill from parsed text, which is worse than building them today. |
| **Q2** | **Scope: repair the mis-wired Placer / CoStar sections on `Opportunity_Record_Page`?** | **(a)** yes, fix them in this tranche; **(b)** no, record as a finding | **(a)** — but it is genuinely optional. The page has sections **labelled** "Placer" and "CoStar" that render `OneDrive_Folder_URL__c` and `CoStar_URL__c` respectively, while `Placer_URL__c` sits in an unrelated section next to `Rejection_Reason__c`. It is a ~15-line flexipage edit with no code, and it is the surface a user will look at first for the feature this item delivers. It was **not requested**, which is the only reason it is a question. |
| **Q3** | ⚠ **Confirm the FSD §24.1 list-view names.** | The eight in §3.2, or the FSD's own eight | **Confirm the FSD's.** I could not read the .docx (no execution tool in this agent). The eight views in §3.2 are derived from the sub-state splits the brief quotes and land on exactly eight active views, but the **labels** are a guess. Renaming a list view later is free; discovering the FSD wanted a ninth is not. **Paste §24.1's list and I will re-map in one pass.** |

---

# 🚦 POST-DEPLOY GATES (none of these is deployable metadata, and none fails loudly)

| # | Gate | Failure mode if skipped |
|---|---|---|
| **G1** | 🔴 **Populate `Development_Construction_Team`.** Group membership is not deployable. | Gap #1 notifications reach nobody. `GroupNotifier`'s empty-group fallback sends to the **group's own Id**, and its own header qualifies that as *"proven to work for queues"* — this is a Regular group. A bad recipient Id raises `Invalid parameter value for: recipientIds` and **no recipient in the set is notified**; the exception is caught and degrades to a debug line. Nothing errors, nothing logs, no test fails. |
| **G2** | 🔴 **Verify `Deal_Sub_Stage__c` is usable as a list-view FILTER in the org.** Save one of the five views by hand before trusting the deploy. | The single highest-risk assumption here (§3.2). `Deal_Bucket__c` proves a **same-object** formula filters; it does not prove a **cross-object** one does. If it fails, only the two LOI-Submitted/Accepted branches are affected and the named fallback is an Opportunity-level LOI-signed checkbox maintained by the already-live `LOI_Signed_Notify`. |
| **G3** | **Reconcile every touched permission set against the org before deploying it** (A6). | A `PermissionSet` deploy **REPLACES** its entire `<fieldPermissions>` set. An org-side-only grant absent from the file is silently wiped. Paid twice on this project. |
| **G4** | **Confirm `Investor_Relations`, `Legal_Team` and `DPEG_Property_Mgmt_Team` memberships are correct and non-empty.** | This tranche reaches **four other teams' inboxes** for the first time. An empty group has the same failure mode as G1; a wrongly-populated one is worse, because it looks like it works. |
| **G5** | 🔴 **Approve one underwriting as a REAL principal (not an administrator) and read `Market_Data_Snapshot__c`.** | An administrator passes every permission check for reasons unrelated to the design. The failure this gate catches is a stamped `Market_Data_As_Of_Date__c` beside an empty or "snapshot failed" body — i.e. the freeze recording nothing. Also verify the deal actually has a `Property__c` (residual R1). |
| **G6** | **Run `OpportunitySelectorTest`, `ContractExecutionServiceTest` and `MarketDataSnapshotServiceTest` before this reaches anyone.** | 🔴 **The two places where "no tests run" genuinely bites.** D5 changes the behaviour of an existing selector method whose existing test builds fixtures with no stage filter in mind; D4 adds a fourth notification to a class whose test asserts notification counts. Both fail **loudly** when run and **invisibly** when not. Everything else in this tranche is declarative or additive. |
| **G7** | **Confirm `Opportunity_LOI_Entry_Notify` is ACTIVE before / with A12.** | A12 removes `Notify_LOI_Pending`. If A11's replacement is missing or `Draft`, Acquisitions **loses** a notification it has today, on every route, silently. |
| **G8** | **Verify the two retired list views (`Deal_Tracker_LOI`, `Deal_Tracker_PSA`) are not pinned in anyone's Lightning nav or referenced by an org-side report.** | List-view deletion is a destructive change; org-side references are not represented in this repo. |
| **G9** | **After the eventual ASB spoke lands: flip `*_Data_Source__c` to `Integrated` and confirm nothing branches on it.** | Recorded here so the flip is a known, one-line data change rather than a rediscovery. This is the whole point of the item. |

---

# 🚩 FLAGGED — DROP / DEFER / RE-SCOPE

| Item | Flag |
|---|---|
| **§24.2 "replace the standard Recent Leads component"** | 🚩 **DROP — already done.** `recentLeads` is a custom LWC with six columns including broker-protection age (P7). There is nothing to replace. |
| **§24.2 "add a Top 5 Largest Deals LWC"** | 🚩 **RE-SCOPE from "build an LWC" to "add one WHERE clause and change one label".** The component exists and is deployed; only the "except Closed" filter is missing (P6). This is the largest single cost reduction in the tranche. |
| **§14.2 portfolio deals on the home page** | 🚩 **DEFER to tranche 3.** `Portfolio_Deal__c` / `Is_Portfolio_Parent__c` are read and written by nothing. A component over them renders permanent zeroes — the "shipped inert" trap this project has been caught by twice. |
| **§23 #5 as literally framed in the brief** | ⚠ **RE-SPECIFY.** "Add Legal to `PSA_Ready_Notify`" would notify Legal at a different event (document ready-for-signature, not deal entering PSA) and on both PSA record types. Build a stage-entry flow instead; leave `PSA_Ready_Notify` and `PSA_Version_Notify` alone (P5). |
| **§23 #3 as literally framed** | ⚠ **RE-SPECIFY.** The Acquisitions half already exists but only on the approval route; the fix is to move the whole notification to a stage-entry flow, not to add IR alongside it (P4 + §2.1). |
| **§18.4 "Cap Compression / Exit Cap"** | ⚠ **RE-SCOPE to Exit Cap only.** "Compression" is a derived comparison whose base (entry cap? market cap? underwritten cap?) the FSD does not define. Storing it with an unstated definition produces a confident wrong number. Build `CoStar_Exit_Cap_Rate__c`; add the comparison when someone names the two operands. |
| **§18.4 "% Leased" vs `Occupancy_Rate_Market__c`** | ⚠ **Do NOT adopt the existing field.** Leased ≠ occupied in CRE. Create `CoStar_Pct_Leased__c` separately; folding them would silently redefine a live field. |
| **The freeze as a LOCK** | 🚩 **DROP the lock reading entirely.** A `Market_Data_Locked__c` + validation-rule design freezes a Property shared by other deals and blocks the integration this item exists to enable. Snapshot, do not lock (§1.3). |

## Findings OUT OF SCOPE — reported, not folded in

1. **`Deal_Category__c` is a restricted picklist that nothing ever sets to `'Dead'`.** Its only writer is `Transaction_Complete_Close` (`'Closed'`). Consequences: `Live_Deals` shows dead deals; `Deal_Bucket__c`'s `ISPICKVAL(Deal_Category__c,'Dead')` clause is unreachable code carried by the stage clause beside it; and a deal reaching Closed Won via the Advance Stage button (not the flow) stays `'Live'` for ever. **This tranche routes around it** (filter on `StageName`) rather than fixing it. The real fix is either to retire the field or to have `OpportunityReviewTriggerHandler` maintain it — a separate design.
2. **`Opportunity.Contract_Signed__c`'s `<description>` is wrong.** It reads *"Checked when the LOI is fully executed"*; `ContractExecutionService` stamps it at **PSA** execution. One-line correction, not folded in because it is unrelated to the three items.
3. **`flows/LOI_Signed_Notify` has no record-type or parent criterion.** It fires on any `LOI__c.LOI_Signed__c = true`, including a **disposition** LOI, and tells IR to *"begin the Offering Memorandum"* for a sale. Same defect class `PSA_Ready_Notify`'s header records for its own object. Not folded in because Item 2's list does not include it; worth its own pass.
4. **`Opportunity.Placer_Last_Synced_DateTime__c` / `CoStar_Last_Synced_DateTime__c` are deletable orphans** once A4 corrects their descriptions — zero readers, zero writers, FLS in one permission set. Deletion is a separate, low-risk change.
5. **`Property__c` has no Lightning record page** — only a classic layout. Every other acquisitions object in this app has a flexipage. Not required by this item; noted because A7 is a layout edit and a future reader may expect a flexipage.
6. **`recentOpportunities` is misnamed** and will stay misnamed after D6 (label changed, bundle name kept). Recorded so the mismatch is legible as a decision rather than an oversight.

---

# 📝 PROMPTS FOR SPECIALIST AGENTS

## 🔵 PROMPT FOR `salesforce-admin`

```
Read ARCHITECTURE.md and .claude/rules/* first. Work on branch
feature/acquisitions-fsd-tranche-1. Create metadata files only — DO NOT DEPLOY.
API version 67.0. Package directory force-app/main/default.

=== ITEM 1 — MARKET DATA MANUAL LAYER ===

1. TWELVE new custom fields on Property__c. Every <description> must name the
   provider and state that the value is manually entered today because no ASB
   spoke exists.
   Placer block:
     Placer_State_Rank__c        Number(6,0)
     Placer_State_Percentile__c  Percent(5,2)
     Placer_MSA_Rank__c          Number(6,0)
     Placer_National_Rank__c     Number(6,0)
   CoStar block:
     CoStar_Pct_Leased__c        Percent(5,2)
     CoStar_Location_Score__c    Number(4,1)
     CoStar_Asking_Rent_PSF__c   Currency
     CoStar_Exit_Cap_Rate__c     Percent(5,2)
   Control fields:
     Placer_Data_Source__c   restricted picklist: Manual (default), Integrated
     CoStar_Data_Source__c   restricted picklist: Manual (default), Integrated
     Placer_Last_Synced_DateTime__c   DateTime
     CoStar_Last_Synced_DateTime__c   DateTime
     CoStar_Fetch_Status__c  restricted picklist: Not Synced (default), Success, Error

   🔴 DO NOT create Market_Rent_PSF__c, Market_Cap_Rate__c, Monthly_Visits__c,
   Trade_Area_Population__c, Peak_Hour__c, YoY_Growth__c, Visitor_Demographics__c,
   Comp_Monthly_Visits__c, Comp_Sales__c, Days_On_Market_Avg__c or
   Occupancy_Rate_Market__c on Property__c — ALL OF THEM ALREADY EXIST and are the
   fields this layer adopts. Duplicating any of them is the specific failure this
   design exists to avoid.
   🔴 CoStar_Pct_Leased__c is DELIBERATELY separate from the existing
   Occupancy_Rate_Market__c — leased and occupied are different facts in CRE. Say so
   in its <description>.

2. Property__c.Placer_Fetch_Status__c: ADD one value, 'Not Synced', and make it
   <default>true</default>. Do not remove or rename Success/Error. This field is the
   FSD's "Sync Status" for Placer under an existing name; CoStar_Fetch_Status__c above
   is its twin.

3. TWO new custom fields on Opportunity:
     Market_Data_As_Of_Date__c   Date
     Market_Data_Snapshot__c     Long Text Area, 32768, visibleLines 20
   Both <description>s must state: system-written by MarketDataSnapshotService when
   the deal ENTERS underwriting approval (Underwriting_Status__c = 'Approved by
   Principals'); NOT for manual entry; a re-approval re-snapshots deliberately.

4. Correct the <description> of the two EXISTING orphan fields
   Opportunity.Placer_Last_Synced_DateTime__c and
   Opportunity.CoStar_Last_Synced_DateTime__c. They currently claim to be "Stamped by
   the Sync button on the Placer/CoStar card" — VERIFIED: there is no Sync button
   anywhere in this repo (no quickAction, no LWC, no Flow, no Apex). Replace with:
   nothing reads or writes this field; the live sync markers now live on Property__c;
   this field is a deletion candidate. DO NOT DELETE THEM.

5. 🔴 DO NOT TOUCH Opportunity.Market_Cap_Rate__c or Opportunity.My_Cap_Rate__c.
   flows/Underwriting_Opp_Sync copies Underwriting__c's values onto them on every
   Underwriting save, so anything written there is silently overwritten.

6. Property__c-Property Layout: two new sections, "Placer.ai" and "CoStar", each
   holding its provider's metrics (existing + new) plus its three control fields.

7. flexipages/Opportunity_Record_Page: add Market_Data_As_Of_Date__c and
   Market_Data_Snapshot__c as READ-ONLY field instances (uiBehavior: readonly) beside
   the existing UW_Approved_By__c / UW_Approval_Date__c block.
   ⚠ Field instances ONLY. Do not add a quick action to this page — doing so silently
   empties the page's inherited action list, and no test catches it.

=== ITEM 2 — NOTIFICATION RECIPIENTS ===

8. NEW group Development_Construction_Team (Regular, doesIncludeBosses true), mirroring
   groups/Acquisitions_Team.group-meta.xml. ONE group, not two — the FSD names a single
   "Development & Construction Team" and both review flows notify the same audience.
   ⚠ Membership is not deployable metadata; populating it is a post-deploy gate.

9. EDIT flows/Dev_Review_Opinion_Notify and flows/Con_Review_Opinion_Notify: add ONE
   further GroupNotifier actionCall to each, recipientGroup =
   Development_Construction_Team, chained after the existing Acquisitions_Team call.
   Do not change the existing call, its title, or the start filters.

10. THREE NEW flows. All identical in shape: AutoLaunchedFlow, apiVersion 67.0,
    triggerType RecordAfterSave, recordTriggerType CreateAndUpdate, object Opportunity,
    ONE StageName filter, doesRequireRecordChangedToMeetCriteria true,
    <runInMode>SystemModeWithoutSharing</runInMode>, status Active. Each calls
    GroupNotifier twice (chained), targetRecordId = $Record.Id, body = $Record.Name.

      Opportunity_LOI_Entry_Notify      StageName = 'LOI'
        -> Acquisitions_Team   "Deal moved to LOI"
        -> Investor_Relations  "Deal moved to LOI - IR green light"

      Opportunity_PSA_Entry_Notify      StageName = 'Under Contract (PSA)'
        -> Acquisitions_Team   "Deal under contract (PSA)"
        -> Legal_Team          "Deal under contract (PSA) - legal review"

      Opportunity_Closed_Won_Notify     StageName = 'Closed Won'
        -> DPEG_Property_Mgmt_Team  "Deal closed - Property Asset created"
        -> Investor_Relations       "Deal closed"

    🔴 THREE FLOWS, NOT ONE, AND THE SINGLE-VALUE FILTER IS MANDATORY. A single flow
    with filterLogic 'or' across the three stages would NEVER fire on the
    LOI -> Under Contract (PSA) transition: the record already satisfied the OR at LOI,
    so it does not CHANGE TO MEET the criteria and doesRequireRecordChangedToMeetCriteria
    suppresses it. Silently.
    🔴 THESE ARE STAGE-ENTRY FLOWS ON PURPOSE, not additions to an existing flow.
    StageAdvanceService.NEXT_STAGE has no 'Underwriting' => 'LOI' entry (the button routes
    into the approval) but a human can move the stage from the Path; and Closed Won is
    reachable from Under Contract (PSA), from About to Close, and from
    flows/Transaction_Complete_Close. Keying on the ROUTE covers a subset, invisibly.

11. EDIT flows/Opportunity_UW_Approved_Notify:
    - REMOVE the Notify_LOI_Pending actionCall entirely (superseded by
      Opportunity_LOI_Entry_Notify, which covers both routes to the LOI stage).
    - Re-point Stamp_Approval_Audit's <connector> at a new actionCall named
      Snapshot_Market_Data (actionType apex, actionName MarketDataSnapshotService,
      inputParameter recordId = $Record.Id) — coordinate with the developer agent,
      which owns that class.
    - Leave runInMode, the start filter, doesRequireRecordChangedToMeetCriteria and
      Stamp_Approval_Audit itself EXACTLY as they are. This flow already carries
      <runInMode>SystemModeWithoutSharing</runInMode> and that is load-bearing: an
      approval-triggered flow runs as the APPROVER, who is read-only on Opportunity in
      this org, and removing it rolls back the entire approval.

=== ITEM 3 — LIST VIEWS ===

12. NEW formula field Opportunity.Deal_Sub_Stage__c, type Text, formula:

      IF( OR( ISPICKVAL(StageName, 'Dead/Pass'), ISPICKVAL(Deal_Category__c, 'Dead') ), '',
      IF( ISPICKVAL(StageName, 'LOI'),
            IF( AND( NOT(ISBLANK(Primary_LOI__c)), Primary_LOI__r.LOI_Signed__c ), 'LOI - Accepted',
            IF( LOI_Approved__c,                                                    'LOI - Submitted',
                                                                                    'LOI - Pending' ) ),
      IF( ISPICKVAL(StageName, 'Under Contract (PSA)'),
            IF( Contract_Signed__c, 'PSA - Executed', 'PSA - Negotiation' ),
            '' ) ) )

    Put the full rationale in an XML COMMENT INSIDE the root <CustomField> element
    (never above it — that breaks sf deploy at conversion with "unable to find matching
    parent xml file"; <description> caps at 255). Follow the house precedent in
    objects/Opportunity/fields/Deal_Bucket__c. The comment must record:
    (i) this exists because a Salesforce LIST VIEW FILTER CANNOT TRAVERSE A LOOKUP, and
        the five FSD sub-states are child-record states on LOI__c / Contract_Review__c;
    (ii) Dead is tested FIRST and returns blank, so all five sub-views inherit the dead
        exclusion and cannot drift from it;
    (iii) a blank Primary_LOI__c falls to the ENTRY state ('LOI - Pending'), NOT to
        blank — Primary_* lookups are stamped only for children OpportunityReviewService
        itself creates, so an irregularly-created child leaves them null and a
        blank-returns-blank formula would drop that deal out of every view;
    (iv) it is ACQUISITION-ONLY STRUCTURALLY: reaching through Primary_LOI__c from an
        Opportunity can only reach an acquisition LOI, which is why the Phase-3 overlap
        of LOI__c.Stage__c's acquisition and disposition value sets at 'Under Review'
        cannot mislead it — and note that this formula never reads Stage__c at all;
    (v) LOI_Approved__c means "DPEG approved SENDING the LOI", not "the seller
        accepted" — that is the Pending/Submitted boundary;
    (vi) Contract_Signed__c is stamped by ContractExecutionService at PSA EXECUTION.
        ⚠ That field's own <description> says "when the LOI is fully executed" and is
        WRONG; the class header is authoritative.
    (vii) 🔴 UNVERIFIED: Deal_Bucket__c proves a SAME-OBJECT formula is filterable in a
        list view; it does not prove a CROSS-OBJECT one is. Three of the five branches
        are deliberately same-object so the fallback is cheap. Named fallback: an
        Opportunity-level LOI-signed checkbox maintained by the already-live
        flows/LOI_Signed_Notify. VERIFY IN ORG BEFORE TRUSTING THE DEPLOY.

13. FIVE new Opportunity list views, filterScope Everything, filter
    Deal_Sub_Stage__c equals <value>, columns = the same seven the existing
    Deal_Tracker_* views use plus Deal_Sub_Stage__c:
      Deal_Tracker_LOI_Pending       'LOI - Pending'        label "Deal Tracker: LOI Pending"
      Deal_Tracker_LOI_Submitted     'LOI - Submitted'      label "Deal Tracker: LOI Submitted"
      Deal_Tracker_LOI_Accepted      'LOI - Accepted'       label "Deal Tracker: LOI Accepted"
      Deal_Tracker_PSA_Negotiation   'PSA - Negotiation'    label "Deal Tracker: PSA Negotiation"
      Deal_Tracker_PSA_Executed      'PSA - Executed'       label "Deal Tracker: PSA Executed"

14. Add a filter  StageName notEqual Dead/Pass  to THREE existing list views:
      All_Deals  (label "Active Deals" — today it has NO dead exclusion at all)
      Live_Deals
      Default_Opportunity_Pipeline
    🔴 Use StageName, NEVER Deal_Category__c. VERIFIED: nothing in this application ever
    writes Deal_Category__c = 'Dead' — its only writer is flows/Transaction_Complete_Close,
    which writes 'Closed', and the field is a restricted picklist DEFAULTING to 'Live'.
    Live_Deals' apparent dead exclusion therefore does not work.
    ⚠ 'Dead/Pass' is the LITERAL form in a ListView filter. The Dead%2FPass encoding
    applies inside BusinessProcess / RecordType / picklist metadata only. The deployed
    Dead_Deals and Offers_Due_Soon views are the local precedent for the literal form.

15. RETIRE (destructive change) Deal_Tracker_LOI and Deal_Tracker_PSA — superseded by
    the five splits above.

Do NOT add any other field, object, validation rule, permission set, approval process,
report, dashboard, sharing rule or quick action. Do not delete the two orphan Opportunity
sync-date fields. Do not deploy.

FLS (do this LAST, and reconcile FIRST):
  Property__c new fields  -> DPEG_Acquisition_Edit (editable), DPEG_Acquisition_View
                             (readable), DPEG_Property_View (readable) — the three sets
                             that already carry Property__c.Monthly_Visits__c /
                             Market_Rent_PSF__c / Placer_URL__c.
  Opportunity new fields  -> DPEG_Acquisition_Edit, DPEG_Acquisition_View,
                             DPEG_Opportunity_View — the three that already carry
                             Opportunity.Deal_Bucket__c. Deal_Sub_Stage__c is a formula,
                             so readable only, editable false, in all three.
  🔴 A PermissionSet deploy REPLACES its entire <fieldPermissions> set. Reconcile each
  file against the org BEFORE editing it and drop no existing entry. This has been paid
  for twice on this project.
  ⚠ Metadata-API-deployed fields arrive with NO field permissions for ANY profile,
  System Administrator included — which is why every Apex read of these fields is
  WITH SYSTEM_MODE.
```

## 🟢 PROMPT FOR `salesforce-developer`

```
Read ARCHITECTURE.md and .claude/rules/* first. Work on branch
feature/acquisitions-fsd-tranche-1. API version 67.0. Do not deploy.
Use TestDataFactory. Every selector method is WITH USER_MODE unless justified at its
own declaration.

=== ITEM 1 — MARKET DATA SNAPSHOT AND FREEZE ===

1. EDIT OpportunitySelector — add:
     selectMarketSnapshotSourceByIds(Set<Id> opportunityIds) -> List<Opportunity>
   selecting Id, Name, Property__c and the traversed Property__r.<market field set>
   (Monthly_Visits__c, Trade_Area_Population__c, Peak_Hour__c, YoY_Growth__c,
   Comp_Monthly_Visits__c, Market_Rent_PSF__c, Market_Cap_Rate__c,
   Occupancy_Rate_Market__c, Days_On_Market_Avg__c, plus all TWELVE new
   Placer_*/CoStar_* fields the admin agent is creating).
   🔴 WITH SYSTEM_MODE, justified AT THE METHOD, and state MODE and SHARING as TWO
   SEPARATE decisions:
     MODE — every field in the SELECT is a Metadata-API-deployed custom, and such fields
     arrive with NO field permissions for ANY profile, System Administrator included. A
     USER_MODE read throws System.QueryException "No such column" — an FLS DENIAL wearing
     a schema error — inside an invocable called from an APPROVAL-TRIGGERED flow, i.e. it
     takes the approval down with it. Same shape as the Disposition NDA auto-create row in
     ARCHITECTURE.md §2's automation-path table.
     SHARING — deliberately NOT escaped, and the reason is structural: the ROOT object is
     the Opportunity the approver has just approved, and parent-lookup traversal is not
     sharing-filtered. Reading Property__c as a ROOT object would raise the full problem
     (Private OWD; its single sharing rule is an OWNER rule scoped to rows owned by the
     Acquisition QUEUE, and a LeadConvertService-created Property is owned by the
     converter, so a principal approver is not reached — the read would return zero rows
     and the snapshot would be SILENTLY EMPTY while the As-Of Date stamped). Record in the
     header that IF traversal ever proves to be filtered, the remedy is a
     `private without sharing` inner class on PropertySelector mirroring the existing
     FolderCreationReads / AssetCreationReads — never `without sharing` on the whole class.
   Class stays `with sharing`. No inner class is added today.

2. NEW: MarketDataSnapshotService (with sharing).
   @InvocableMethod, List<Request> in / List<Result> out, both inner classes with
   @InvocableVariable fields (.claude/rules/invocable-rule.md; ApprovalAuditService is the
   in-repo precedent). A single-record signature silently drops every record but the first
   when Flow batches interviews.
   - Reads via selectMarketSnapshotSourceByIds. ONE query for the whole set.
   - Composes a labelled, ordered, multi-line text block of every market value, each line
     "Label: value" with a fixed, locale-independent format (never DateTime.format).
     Header line names the source Property and the composition date.
   - Stamps Market_Data_As_Of_Date__c = Date.today(), captured ONCE per invocation, never
     Date.today() per record.
   - Writes Market_Data_Snapshot__c + Market_Data_As_Of_Date__c via
     Database.update(list, false, AccessLevel.SYSTEM_MODE). SYSTEM_MODE because the
     approver holds Read and NOT Edit on Opportunity in this org (DPEG Principal PSG,
     measured — it is the ApprovalAuditService incident) and because both new fields have
     no FLS for anyone. allOrNone = false so one bad row cannot take the batch.
   - 🔴 catch (Exception e), NOT catch (DmlException). A QueryException is not a
     DmlException, and ARCHITECTURE §2 records that a DmlException-only catch let a
     TypeException escape and roll back a whole approval.
   - 🔴 AND THE WIDE CATCH ALONE IS NOT ENOUGH — ARCHITECTURE records that the widened
     catch would have been WORSE than the bug, because the approval then succeeds while the
     stamp stays silently blank. So on failure WRITE THE REASON INTO
     Market_Data_Snapshot__c ("Market data snapshot failed: <message>"). A field that
     reports its own absence costs nothing and makes the one previously-invisible failure
     legible on the record.
   - NEVER rethrow. A market snapshot must not roll back an approval.
   - A deal with a null Property__c gets the literal text "No property linked to this deal
     - no market data to snapshot." rather than a blank. Only LeadConvertService creates
     and links a Property, so a manually built deal has none — the same residual
     PropertyAssetService (R1) and DealFolderService (R1) carry.
   - Budget: 1 SOQL / 1 DML per invocation, CONSTANT in record count. No SOQL or DML in
     loops.
   - Class header must record WHY THE VENUE IS THIS FLOW AND NEEDS NO QUEUEABLE:
     flows/Opportunity_UW_Approved_Notify already carries
     <runInMode>SystemModeWithoutSharing</runInMode>; Opportunity.Underwriting_Approval
     declares finalApprovalRecordLock = false; and ApprovalAuditService already updates the
     Opportunity from inside this exact flow and works today. That is a live proof, not an
     inference. Contrast LoiPrimaryStampQueueable and DispositionNdaStampQueueable, which
     exist ONLY because their records ARE locked — do not copy them here.
   - Class header must also record that ENTRY SEMANTICS
     (doesRequireRecordChangedToMeetCriteria = true) mean a RE-APPROVAL RE-SNAPSHOTS,
     deliberately: the second approval reviewed the data as it then stood. Do NOT make it
     fill-if-blank.

3. Coordinate with the admin agent on flows/Opportunity_UW_Approved_Notify: the new
   Snapshot_Market_Data actionCall (actionType apex, actionName MarketDataSnapshotService,
   inputParameter recordId = $Record.Id) chains AFTER Stamp_Approval_Audit, and
   Notify_LOI_Pending is removed. That is ONE edit to ONE file — it must land as one change.

=== ITEM 2 — GAP #7 ===

4. EDIT ContractExecutionService.stampOpportunities: add ONE line inside the existing
   per-Opportunity loop —
     notifications.add(buildNotification('Acquisitions_Team',
         'PSA executed', o.Name + ': the PSA is executed.', o.Id));
   Change NOTHING else. The Offering shell, the Day-0 stamp and the three existing
   notifications (Transactions_Team, Investor_Relations, Due_Diligence) are untouched.
   Record the arithmetic in the class header: GroupNotifier's measured cost is
   ~6.0 ms CPU + 0.22 ms x |recipients| per send(), so a full 200-row Contract_Review__c
   chunk moves from 600 to 800 sends, roughly 3.7 s -> 5.0 s against a 10 s synchronous CPU
   limit. This is a pre-existing exposure widened by ~25%, not a new one — but the next
   person adding a fifth recipient must see the number.

=== ITEM 3 — TOP 5 LARGEST DEALS ===

5. EDIT OpportunitySelector.selectTopByAskingPrice(Integer maxRows): add
     WHERE StageName NOT IN ('Closed Won', 'Dead/Pass')
   ⚠ LITERAL 'Dead/Pass'. The Dead%2FPass encoding applies inside BusinessProcess /
   RecordType / picklist metadata only; getting it backwards yields a filter that silently
   never matches.
   ⚠ Filter on StageName, NEVER on Deal_Category__c — nothing in this application ever
   writes Deal_Category__c = 'Dead'.
   Amend the Javadoc: the method now backs a "largest ACTIVE deals" list.
   🔴 THIS IS A BEHAVIOUR CHANGE FOR ITS ONLY CALLER
   (OpportunityFunnelController.getRecentOpportunities) and for the existing test
   OpportunitySelectorTest.selectTopByAskingPrice_ordersDescendingAndLimits, whose fixture
   was built without a stage filter in mind. Re-check that fixture.

6. EDIT lwc/recentOpportunities: <masterLabel> -> "Top 5 Largest Deals" in the
   .js-meta.xml, and the card heading in the .html to match.
   🔴 DO NOT RENAME THE BUNDLE. That is a new folder, a deleted folder, a
   flexipages/Lead_Funnel edit and a Jest path change, for a label. Add a header comment
   recording that the bundle name is historical, that the component has ALWAYS shown the
   top 5 by asking price (OpportunitySelector.selectTopByAskingPrice), and that the rename
   was deliberately label-only.
   DO NOT touch lwc/recentLeads — it is already the custom component FSD §24.2 asks for.

=== TESTS ===

7. NEW MarketDataSnapshotServiceTest:
   - happy path: an approved deal with a Property gets a non-blank snapshot and today's
     as-of date;
   - a deal with a NULL Property__c gets the "No property linked" text, NOT a blank
     (the falsifier for treating an empty snapshot as acceptable);
   - a second approval RE-SNAPSHOTS (the falsifier for a fill-if-blank "optimisation");
   - a forced failure writes its reason into Market_Data_Snapshot__c and does NOT throw;
   - .claude/rules/bulk-test-rule.md's 251-record mandate applies with NO exemption —
     this is a Flow-invoked bulk entry point. Assert 1 SOQL / 1 DML at 251.
8. AMEND OpportunitySelectorTest.selectTopByAskingPrice_ordersDescendingAndLimits for the
   new stage filter, and add a case proving a Closed Won row and a Dead/Pass row are both
   excluded.
9. ContractExecutionServiceTest must stay green with the fourth notification.

=== ARCHITECTURE.md (§6 — same PR) ===

10. Update:
    - §1 Current objects: the Property__c row gains the market-data block and the
      LIVE-on-Property / SNAPSHOT-on-Opportunity split, and states that
      *_Data_Source__c has NO consumer today BY DESIGN (a provenance label, not a switch).
    - §2 Key Apex Services: add MarketDataSnapshotService, naming its venue
      (Opportunity_UW_Approved_Notify), why no queueable is needed
      (finalApprovalRecordLock = false + a live proof that ApprovalAuditService already
      updates the Opportunity from that flow), and the self-reporting catch.
    - §2 WITH SYSTEM_MODE table: ONE new row for
      OpportunitySelector.selectMarketSnapshotSourceByIds, arguing MODE and SHARING as
      SEPARATE decisions and recording why NO `without sharing` inner class was needed
      (root object is the approver's own Opportunity; parent traversal is not
      sharing-filtered) plus the named fallback if that ever proves false.
    - Update the running "N SYSTEM_MODE queries across M selector classes" count.
    - §3: note that the Placer/CoStar integration remains UNBUILT and that this tranche
      delivers §18.4's "Integration Off" fallback only; no new §3 exception is created,
      because no callout is added.

Do not deploy. Do not add anything not listed above. In particular: do NOT build a
Placer or CoStar callout service, a Named Credential, an External Credential, a scheduled
pull or a Sync button — the integration is explicitly out of scope for this tranche.
```

---

**Complexity routing summary**

| Item | Declarative | Programmatic |
|---|---|---|
| 1 — Market data manual layer + freeze | **`salesforce-admin`** (14 fields, 1 picklist value, 1 layout, 1 flexipage, FLS, 1 flow edit) | **`salesforce-developer`** (1 selector method, 1 invocable service) |
| 2 — Notification recipients | **`salesforce-admin`** (1 group, 2 flow edits, 3 new flows, 1 flow edit) | **`salesforce-developer`** (1 line in `ContractExecutionService`) |
| 3 — Home page + list views | **`salesforce-admin`** (1 formula field, 5 new views, 3 view fixes, 2 retirements) | **`salesforce-developer`** (1 selector clause, 1 LWC label) |

No item routes to `salesforce-solution-architect` (no multi-object schema design, no OWD/sharing-model design, no subflow orchestration, no fault-path architecture) or to `salesforce-technical-architect` (no integration, no Named Credentials, no callouts, no Platform Events, no LDV, no async) — the Placer/CoStar **integration is deliberately out of scope**, and this tranche builds the fallback the FSD specifies for when it is off.
