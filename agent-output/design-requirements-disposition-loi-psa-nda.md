# Design Requirements — Disposition LOI, Disposition PSA, NDA Record Types (TRANCHE 3)

**Source of truth:** `docs/DPEG-Stage-by-Stage.docx` Part 2 (extract: scratchpad `spec-disposition.md`), Part 1 lines 35–45 (NDA states)
**Binding decisions:** `agent-output/stage-by-stage-decisions.md` — D6, D7, D9, D10, D14, **D14.1**. Not re-litigated below.
**Evidence base:** `agent-output/stage-by-stage-audit-disposition.md` §2.5, §2.6, §2.9, §2.10, §4.2–§4.4 — plus the corrections in §1 below, which were found by re-reading the metadata rather than the audit.
**Plugs into:** `agent-output/design-requirements-disposition-foundations.md` §6 (the Tranche-2 seam). Every Tranche-2 post-deploy gate still applies; this document adds to them.
**Conventions:** `ARCHITECTURE.md` §1 (naming), §2 (Apex layering, `WITH SYSTEM_MODE` table), §5 (LWC guard utils)
**Branch:** `feature/stage-by-stage-alignment` — Tranche 2 built, validated, **not deployed, not merged**. Both tranches deploy in one window.
**Date:** 2026-08-09
**Status:** awaiting Gate 1

---

## 0. FLAG AT GATE 1

### 0.1 🔴 RECOMMENDATION: SPLIT THIS TRANCHE INTO THREE BUILD CYCLES

**Yes, split it — and split it by BUILD, not by DEPLOY.**

The three in-scope items are not one feature. They are **three independent record-type introductions on three live objects** (`LOI__c`, `NDA__c`, `Contract_Review__c`), each of which recreates the whole D11/Q6 problem — existing rows land on **Master**, match no Path, and show the unrestricted value set — plus **one destructive picklist-and-field migration** on a fourth object. Tranche 2 was 119 components for **one** record-type introduction. This is materially larger than 3× that, and the destructive item has a failure mode the other three do not.

Proposed cut, in dependency order:

| Cycle | Contents | Why this line |
|---|---|---|
| **3A** | **NDA record types (D7/D14.1) + the record-type-aware `RecordStageAdvanceService`** + the off-market all-signed gate | Self-contained and lowest-risk: the acquisition change is purely additive (`Received`), and the disposition NDA is the off-market path's FIRST stage, so without it the off-market path Tranche 2 built has nothing at its first step. **D14.1 requires the shared service change here anyway**, so 3B inherits it finished. |
| **3B** | **Disposition LOI + the `Disposition_Offer__c` migration** | Inseparable. Tranche 2 §6.3 states the migration "must not begin before the disposition LOI record exists to migrate *to*". |
| **3C** | **Disposition PSA** | Smallest, cleanest premise (see §1.1 — the phantom-Transaction risk is already gone), depends on nothing in 3A/3B beyond the shared record-type-assignment discipline. |

**Deploy grouping is unchanged: Tranche 2 + 3A + 3B + 3C go out in one window**, for exactly the reason D14 gives — Tranche 2 shipped `LOI` and `PSA` as stage values with nothing behind them. Splitting the *build* buys three reviewable units instead of one 400-component review; splitting the *deploy* would ship the empty stages D14 exists to prevent.

If the user insists on a single build cycle, that is workable — but the code review then has to hold four independent migrations in its head at once, and the C1-class defect in Tranche 2 (two correct artifacts, wrong together) is precisely the kind a large review misses.

### 0.2 Questions whose answers change the design

**Blocking — the build differs materially by answer.**

| # | Question | Why it changes the design | Recommendation |
|---|---|---|---|
| **Q1** | 🔴 **Which persona may drive the disposition LOI / NDA / PSA stage actions?** Every stage quick action on `LOI__c`, `NDA__c` and `Contract_Review__c` is gated — in Apex by `RecordStageAdvanceService` → `OpportunityActionPermissionService.hasDealActionAccess()`, and on the record page by the visibility rule `{!$User.Deal_Driver__c} EQUAL true`. That gate is **two-factor**: FLS on `User.Deal_Driver__c` (granted only by `Acquisition_Deal_Driver`) **and** the flag true. No disposition persona holds either. | Without an answer the entire feature is **invisible and unusable to disposition users** — they will see an LOI record with no buttons and get "You do not have permission" from any direct call. Three builds: (a) grant `Deal_Driver__c` to disposition users — zero new metadata, but it also grants the six Opportunity deal actions to a disposition persona; (b) a new `StageActionGate.DISPOSITION_DRIVER` + `User.Disposition_Driver__c` + a `Disposition_Deal_Driver` permission set, mirroring the proven two-factor mechanism, and `hasStageActionAccess` gains a per-record load so the gate can differ by record type; (c) no gate on the disposition record types at all. | **(b).** `Deal_Driver__c` is an acquisition flag by name and by its permission set, and this repo already records that *"membership and the flag are different questions… adding a permission-set name to this gate REPLACES a two-factor condition with a one-factor one for every holder."* Option (b) is also the only one that gives the flexipage a **deployable** thing to bind a visibility rule to — a rule cannot call Apex, and `ARCHITECTURE.md` §5 says the binding must be a User field or a Custom Permission. |
| **Q2** | 🔴 **Exactly which `Disposition_Offer__c.Offer_Status__c` values retire?** D6 names four: `Received`, `Under Review`, `Countered by DPEG`, `Counter Received from Buyer`. **`Received` is the field's `<default>true</default>` and its arrival state.** Retiring all four leaves `Accepted` / `Rejected` / `Withdrawn by Buyer` — three outcomes and no state for an offer that has just come in, and no default. | Reading A (literal D6): four values go, and the field needs a new default and a new arrival value invented — which Rule 1 forbids. Reading B: D6's own sentence is *"the offer becomes **capture + comparison** only"*, and capture requires a capture state; `Received`/`Under Review` **on an offer** mean "an offer arrived" / "we are comparing it", which is not negotiation. Only `Countered by DPEG` and `Counter Received from Buyer` are negotiation. | **Reading B — retire the two counter values only.** It is faithful to D6's stated intent, needs no invented value, keeps the default, and shrinks the destructive surface from four values to two. ⚠ This is a request for a *reading* of D6, not an alternative to it. If the user confirms Reading A, say what the new default should be. |
| **Q3** | 🔴 **How does a disposition LOI / PSA / NDA get created?** On the acquisition side `OpportunityReviewService` auto-creates all three on Opportunity stage entry and stamps `Primary_<X>__c`. The document uses the identical phrasing for the disposition ("LOI record — created here", "PSA record — created here"). There is **no `Disposition__c` trigger in this repo** and no `Primary_*` lookup on `Disposition__c`. | Auto-create = a new `DispositionTrigger` + handler + service extension + `Primary_LOI__c`/`Primary_Contract__c` lookups on `Disposition__c` + idempotency + bulk tests, and it fires on a record that **three approval processes lock**. Manual = a related list with a New button on `Disposition_Record_Page`, zero Apex. | **Manual, via related lists.** The brief does not ask for auto-creation, Rule 1 forbids adding it, and the approval-lock interaction (`Sale_Decision_Approval` and `Closing_Approval` both set `recordEditability = AdminOnly`) is exactly the C1 shape. Record-type visibility scoped per persona means the New button applies the right type with no chooser (see §4.6). |
| **Q4** | **Does the off-market all-signed gate block every forward stage, or only the `NDA → Disposition Offer` hop?** `Disposition_Stage__c` is freely settable — the `No_Backward_Stage_Movement` VR is Opportunity-only, and nothing stops a user jumping `NDA → LOI`. | Gating only `Disposition Offer` is self-limiting by stage value (it is off-market-only) and needs no record-type test. Gating every later stage covers the jump but must name `LOI`, `PSA`, `Closing`, `Completed` — which are **shared with on-market** — so the rule needs `$RecordType.DeveloperName = "Off_Market"`. | **Block every forward stage**, with the record-type test. A gate that a single click bypasses is not a gate, and the document is categorical: *"Nothing is shared until this is done."* |

**Confirm — smaller, but each has a wrong answer.**

| # | Question | Recommendation |
|---|---|---|
| **Q5** | The acquisition record-type stamps in `OpportunityReviewService` (LOI, NDA, Contract Review) — keep the `info != null && info.isAvailable()` fail-soft guard `DispositionService` uses, or stamp unconditionally? **The LOI block runs as the APPROVER** (`ApprovalAuditService` → the approval's field update → `OpportunityReviewService`), and a principal's record-type visibility is profile state this repo can neither see nor set. D13 residual 1 already measured `isAvailable() == false` for an *assigned* System Administrator. | **Stamp unconditionally in `OpportunityReviewService`** (null-safe on the describe lookup only). The platform does not enforce record-type availability on DML — like picklist restrictions it is UI-only — so the guard buys nothing here and its failure mode is a Master-type LOI with no Path. Document the deliberate divergence from `DispositionService` in **both** class headers. |
| **Q6** | Does "all NDAs signed" mean `Status__c = 'Signed'` on every NDA, or `Signed` **and** a counter-signature date? | **`Signed` alone.** The document's release condition is *"information is released only once every NDA is signed"*; counter-signing is described as something we do, and is recorded as a fact. Two conditions where the document states one is an invention. |
| **Q7** | Disposition LOI at `Counter Received from Buyer` — the document says it *"goes round until both sides are agreed"*, so two named buttons (counter again / execute). Is `Under Review → Executed` (accept the buyer's LOI with no counter) also wanted? | **No.** Not described. Adding it to the explicit-target allow-list is a widening; leave it out and let the user ask if it turns up in UAT. |

---

## 1. PREMISE CORRECTIONS — read these before pricing anything

Ten findings from re-reading the metadata. Four make the tranche **cheaper**; five make it **larger than the brief states**; one is a verification the brief asked for, now closed.

### 1.1 ✅ CHEAPER — the phantom acquisition `Transaction__c` **cannot happen**. That risk is already gone.

The brief and audit §4.3 both say: *"`ContractExecutionService` stamps the Opportunity and creates a `Transaction__c` on `Executed`… Without a record-type branch, every executed sale mints a phantom acquisition Transaction."*

**That has not been true since 2026-08-05.** `ContractExecutionService.cls:11–20, 33–39` records that Transaction creation **moved out** of `handleExecution` into `openTransactionsOnAboutToClose`, which is triggered by **`Opportunity.StageName = 'About to Close'`** — an Opportunity stage a disposition Contract Review can never reach. And `handleExecution:113–117` already guards:

```apex
Boolean justExecuted = cr.Negotiation_Status__c == EXECUTED && (prior == null || prior.Negotiation_Status__c != EXECUTED);
if (justExecuted && cr.Opportunity__c != null) { executedOppIds.add(cr.Opportunity__c); }
```

A disposition Contract Review has a null `Opportunity__c`, so it is dropped before the stamp, before the three `GroupNotifier` calls, and before anything else. **The required change is therefore purely ADDITIVE — add the disposition behaviour — not defensive.** Nothing has to be prevented.

### 1.2 ✅ CHEAPER — `Contract_Review__c` needs **no** record-type-aware stage map

`Negotiation_Status__c`'s four values (`Initial Draft` / `Revised` / `Ready for Execution` / `Executed`) are **identical in both directions** — that is precisely why audit §4.3 recommended reuse. `RecordStageAdvanceService.CONTRACT_REVIEW_NEXT_STAGE` therefore stays **unchanged**, and so does `Contract_Review__c.Advance_Stage`'s visibility rule (`Negotiation_Status__c NE 'Executed'`), which behaves correctly on both types. **Record-type awareness in that service is needed for `LOI__c` and `NDA__c` only.**

### 1.3 ✅ CHEAPER — `Contract_Review_Stage_Sync` encodes no acquisition assumption

Audit §4.3 asked for this check. `flows/Contract_Review_Stage_Sync.flow-meta.xml:63–124` maps `Negotiation_Status__c` → `Stage__c` (`Initial Draft`→`PSA Drafting`, `Executed`→`Contract Execution`+date, everything else→`Review`) with no direction, no party and no Opportunity reference. **No change.** The documented trap — that writes to `Stage__c` commit and are silently discarded — is inherited unchanged and is why the disposition PSA must also drive `Negotiation_Status__c`.

### 1.4 ✅ CLOSED — `Opportunity.LOI_Approval` cannot fire on a disposition LOI, and neither can its quick action

Two independent verifications the brief asked for:

- `approvalProcesses/Opportunity.LOI_Approval.approvalProcess-meta.xml` is an approval on the **Opportunity** object with `entryCriteria` `Opportunity.StageName equals LOI`. It has no relationship to an `LOI__c` record at all.
- `flexipages/LOI_Record_Page.flexipage-meta.xml:10–34` — `LOI__c.Submit_for_Approval` is visible only when `{!Record.Stage__c} EQUAL 'Prepare/Review'`, a value the `Disposition_LOI` record type will not carry. **Self-limiting by the disjoint value set; no record-type criterion needed.**

### 1.5 🔴 LARGER — `RecordStageAdvanceService` is not the shape the brief describes

The brief says it *"holds a single flat `Map<SObjectType, StageConfig>` with **one linear `NEXT_STAGE` per object**"*. Two corrections:

- It already **branches**: `LOI_EXPLICIT_TARGETS = {'Counter','Completed'}` plus `advanceTo(recordId, target)`, added 2026-08-05 for the acquisition `Sent` branch. The disposition loop-back is the same shape, not a new one.
- It covers **six** objects, not five — `Contract_Review__c` was added and both the class header and `ARCHITECTURE.md` still say five.

🔴 **And the allow-list must become record-type-aware too, not just `NEXT_STAGE`.** Record-type picklist restrictions are **UI-only and are not enforced by Apex DML** (Tranche 2's code review established this for the seed scripts). So if `Executed` and `Declined` sit in `LOI__c`'s / `NDA__c`'s object-level allow-list, a hand-crafted `advanceTo` call can write a *disposition* value onto an *acquisition* record — exactly the hole `ALLOWED_EXPLICIT_TARGETS` exists to close. This is the sharpest single design point in the tranche.

🔴 **`configFor()` runs BEFORE `load()`.** Config is chosen from `Id.getSObjectType()` alone, so record-type awareness cannot be bolted onto the existing call order. The map selection must move **after** the load, and `selectStageRequiredById` must select `RecordTypeId` (see §5.1). `hasStageActionAccess()` gains a load **only if Q1 = (b)**.

### 1.6 🔴 LARGER — three record-type introductions, therefore **three** row migrations, not one

`LOI__c`, `NDA__c` and `Contract_Review__c` all have live rows and no record types today. Adding record types leaves every existing row on **Master**: no Path, unrestricted value set, and — because `RecordStageAdvanceService` will key its map on the record type — no stage map unless a fallback is designed. This is D11/Q6 three times over, and the `NDA__c` migration must **branch on which parent lookup is populated** (`Opportunity__c` → `Acquisition_NDA`, `Disposition__c` → `Disposition_NDA`), because one object serves both modules.

### 1.7 🔴 LARGER — `OpportunityReviewService` is a **third** `isAvailable()`-guard caller, and it runs as the approver

`OpportunityReviewService.cls:100` inserts `Contract_Review__c`, `:155` inserts `LOI__c`, `:230` inserts `NDA__c` — all three objects gaining record types, none stamping one. Left alone, **every auto-created acquisition child lands on Master**, one deal at a time, forever. The LOI block is the sharp one: it runs as the **approver** in `AccessLevel.SYSTEM_MODE` with a deferred `LoiPrimaryStampQueueable` back-stamp. See Q5.

### 1.8 🔴 LARGER — three vocabulary inversions the brief did not name, plus a live cross-module notification leak

The brief names `PSA_Version__c.Direction__c`. The identical inversion exists in three more places, all reached by the reuse D6 mandates:

| Artifact | Values today | On a disposition |
|---|---|---|
| `Counter_Offer__c.Direction__c` | `Seller` / `Ours` | the counterparty is the **Buyer** |
| `LOI__c.Ball_In_Court__c` | `Us` / `Seller` | **"Seller" would mean DPEG** — the exact opposite of its acquisition meaning |
| `Contract_Review__c.Ball_In_Court__c` | `Us` / `Seller` (via `PsaVersionService.cls:87`) | same inversion |
| `PSA_Version__c.Direction__c` | `Seller` / `Ours` | as the brief says |

`Ball_In_Court__c` is the dangerous one: it does not merely read oddly, it **inverts meaning**. `CounterOfferService.cls:58,74,80` and `PsaVersionService.cls:55,84,87` both hardcode `'Seller'`/`'Ours'` and `'Us'`/`'Seller'`.

🔴 **And `flows/Counter_Offer_Notify.flow-meta.xml` has NO entry criteria.** It fires on **every** `Counter_Offer__c` create and notifies `Acquisitions_Team` with the title *"LOI counter received - ball in our court"*. The moment a disposition LOI takes a counter, the acquisitions team is notified about a sale. **Gating that flow is scope CONTAINMENT, not a new notification, and is therefore not covered by D9's deferral** — D9 defers building notifications, it does not license an existing one to leak across modules.

### 1.9 🔴 LARGER — per-record-type **layout** assignment is profile-only, and profiles are `.forceignore`d

The brief requires `Submitted_Date__c`, `Approved_By__c` and the `Submit_for_Approval` action to be *"layout-excluded from the disposition record type, not deleted"*. Half of that is deployable and half is not:

- **Deployable:** a new `layouts/LOI__c-Disposition LOI Layout.layout-meta.xml` (and the NDA and Contract Review equivalents).
- **Not deployable:** the record-type→layout assignment, which lives in `Profile.layoutAssignments`. `profiles/**` never deploys from this repo. **It is a post-deploy gate, exactly like Tranche 2's A1/A3.**

The `Submit_for_Approval` **action** is already handled without a layout — §1.4.

### 1.10 🔴 LARGER — `LOI_Path`, `NDA_Path` and `Contract_Review_Negotiation_Path` are all `__MASTER__`

A Path is configured per record type. Once record types exist, a `__MASTER__` path renders for the Master type only — which after migration is *no rows*. Tranche 2 hit this exactly (`Disposition_Path` → two new files, original deactivated, `recordTypeName` **cannot be re-pointed**). So: **six new PathAssistant files and three deactivations**, including two for `Contract_Review__c` whose step content is byte-identical.

---

## 2. WHAT WAS REQUESTED (scope statement)

Four items, all explicitly named:

1. **Disposition LOI** — `Acquisition_LOI` / `Disposition_LOI` record types on `LOI__c`, a `Disposition__c` lookup, and a record-type-specific `Stage__c` value set carrying `Received → Under Review → Countered by DPEG → Counter Received from Buyer → Executed`; `RecordStageAdvanceService` made record-type-aware; acquisition-directional fields layout-excluded.
2. **Migrate the negotiation off `Disposition_Offer__c`** — a data migration, designed explicitly (§7).
3. **Disposition PSA** — record type + `Disposition__c` lookup on `Contract_Review__c`; the `Executed` → `Disposition_Stage__c = 'Closing'` branch; `PSA_Version__c.Direction__c` inversion; drive `Negotiation_Status__c`, never the derived `Stage__c`.
4. **NDA record types** — `Acquisition_NDA` (`Pending → Sent → Received → Signed`) / `Disposition_NDA` (`Not Sent → Sent → Signed`, plus `Declined`); `Party_Role__c`; counter-signature; the all-signed release gate.

**Explicitly excluded and not designed below:** all notifications (D9) — with the single exception of *gating* the existing `Counter_Offer_Notify` so it stops firing cross-module (§1.8); Call-for-Offers email matching (Tranche 4); the Active-Listing traction monitor and broker change, and **no edit to the Active Listing Path text on either path**; the Wire-delete fail-open gap (noted, not built); anything in Tranche 2 other than the two seam edits §4.8 and §5.6 that Tranche 2 §6 explicitly anticipated; DocuSign integration (D2) — the NDA states are manually driven with a clean seam.

---

## 3. THE VALUE SETS (the load-bearing detail)

All three picklists are `<restricted>true</restricted>` with `<sorted>false</sorted>`, so **element order is display order and Path order**, and a record type can only include or exclude — never reorder.

### 3.1 `LOI__c.Stage__c` — five values added, zero removed

The two sets are **completely disjoint**, so any interleaving works; append is simplest and keeps the acquisition order byte-identical.

| # | Value | Status | Acquisition_LOI | Disposition_LOI |
|---|---|---|---|---|
| 1 | `Draft` | exists (master default) | ✔ **default** | — |
| 2 | `Prepare/Review` | exists | ✔ | — |
| 3 | `Sent` | exists | ✔ | — |
| 4 | `Counter` | exists | ✔ | — |
| 5 | `Completed` | exists | ✔ | — |
| 6 | `Received` | **NEW** | — | ✔ **default** |
| 7 | `Under Review` | **NEW** | — | ✔ |
| 8 | `Countered by DPEG` | **NEW** | — | ✔ |
| 9 | `Counter Received from Buyer` | **NEW** | — | ✔ |
| 10 | `Executed` | **NEW** | — | ✔ |

**Disjointness is what makes this cheap**, and it is the same property Tranche 2 relied on: every existing flexipage visibility rule keyed on an acquisition stage value is automatically self-limiting to acquisition LOIs, and every new disposition rule is self-limiting the other way. **No flexipage record-type criterion is needed anywhere.**

### 3.2 `NDA__c.Status__c` — three values added, zero removed. ⚠ NOT disjoint.

D14.1 is additive on both sides. One master ordering serves both paths — verified, no pair is wanted in opposite orders:

| # | Value | Status | Acquisition_NDA | Disposition_NDA |
|---|---|---|---|---|
| 1 | `Not Sent` | **NEW** | — | ✔ **default** |
| 2 | `Pending` | exists (master default) | ✔ **default** | — |
| 3 | `Sent` | exists | ✔ | ✔ |
| 4 | `Received` | **NEW** | ✔ | — |
| 5 | `Signed` | exists | ✔ | ✔ |
| 6 | `Declined` | **NEW** | — | ✔ |

Filtered: acquisition = `Pending → Sent → Received → Signed` ✔ (D14.1); disposition = `Not Sent → Sent → Signed → Declined` ✔ (Part 2 lines 28–41).

⚠ **`Sent` and `Signed` are SHARED**, so unlike the LOI the stage value alone does **not** identify the record type. Any NDA visibility rule that must discriminate needs a different discriminator — see §4.4's `Is_Decline_Allowed__c`.

✅ **`flows/NDA_Signed_Status_Sync` needs no change, and that is verified rather than assumed.** Its `Is_Signed` decision tests `Status__c EqualTo 'Signed'` and defaults everything else to `NDA_Signed__c = false`. `Received`, `Not Sent` and `Declined` all take the default path and correctly yield `false`. `Date_Signed__c` is stamped once and never cleared, so a `Signed → Declined` move flips `NDA_Signed__c` false — which correctly re-blocks the acquisition `NDA_Signed_Before_Deal_Progression` VR — while retaining the historical signature date. **Confirm this behaviour in UAT (gate T-F3); do not change the flow.**

### 3.3 Direction and ball-in-court — additive only, never a rename

| Field | Add | Why not rename |
|---|---|---|
| `Counter_Offer__c.Direction__c` | `Buyer` | A rename is a **removal**, which triggers the standing sweep rule *and* a data migration on live acquisition rows, for zero benefit. |
| `PSA_Version__c.Direction__c` | `Buyer` | same |
| `LOI__c.Ball_In_Court__c` | `Buyer` | same |
| `Contract_Review__c.Ball_In_Court__c` | `Buyer` | same |

These four objects get **no record types**, so their value sets stay global. The direction is chosen by the writing service from the parent's record type (§5.3), not by the picklist.

⚠ **Adding a value to a restricted picklist makes it globally selectable until the per-record-type restriction lands.** Every picklist add in §3.1/§3.2 must ship **in the same deployment as its record types** (§6, T1) so that window is zero. §3.3's adds have no record type to restrict them and are globally selectable by design.

⚠ **Apex compiles against a picklist regardless of which values exist.** Metadata first, verified in the org, before any Apex or seed data references a new value — otherwise the deploy goes green and throws `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` at runtime.

---

## 4. 🔵 ADMIN / SOLUTION-ARCHITECT WORK

**Routing:** multi-object record-type architecture on three live objects, a cross-module security model, a derived-rollup flow with an approval-lock interaction, and a destructive migration. Per the CLAUDE.md complexity gate this is **`salesforce-solution-architect`**, not `salesforce-admin`.

### 4.1 Picklist value additions

Per §3.1, §3.2, §3.3. Keep `restricted`/`sorted` unchanged; do not touch any existing value, label or master default.

Files: `objects/LOI__c/fields/Stage__c`, `objects/NDA__c/fields/Status__c`, `objects/Counter_Offer__c/fields/Direction__c`, `objects/PSA_Version__c/fields/Direction__c`, `objects/LOI__c/fields/Ball_In_Court__c`, `objects/Contract_Review__c/fields/Ball_In_Court__c`.

Also update `objects/LOI__c/fields/Stage__c`'s `<description>` — it currently reads *"Drives the LOI Lightning Path: Draft - Prepare/Review - Counter - Completed"* and will be wrong for two reasons (it already omits `Sent`).

### 4.2 Record types — six files

| Object | Record types |
|---|---|
| `LOI__c` | `Acquisition_LOI`, `Disposition_LOI` |
| `NDA__c` | `Acquisition_NDA`, `Disposition_NDA` |
| `Contract_Review__c` | `Acquisition_PSA`, `Disposition_PSA` |

🔴 **A `recordType-meta.xml` must enumerate `<picklistValues>` for EVERY picklist on the object**, not just the one being restricted — omitted values are dropped from that record type. Precedent: `objects/Opportunity/recordTypes/Commercial.recordType-meta.xml` enumerates eight. Walk each object's `fields/` directory and enumerate every `<type>Picklist</type>` file:

- `LOI__c`: `Stage__c` (restricted per §3.1), `LOI_Status__c`, `Ball_In_Court__c`, `Counter_Response__c` if it is a picklist, and any other — **enumerate them all unchanged in both files**.
- `NDA__c`: `Status__c` (restricted per §3.2), `Method__c`, and the new `Party_Role__c`.
- `Contract_Review__c`: `Negotiation_Status__c` (**identical four values in BOTH** — see §1.2), `Stage__c` (**including the three `isActive=false` legacy values** — verify whether inactive values must be listed), `Ball_In_Court__c`, `Asset_Type__c`, `Deal_Type__c`.

Defaults per §3.1/§3.2. No `<businessProcess>` — that element is Opportunity/Case/Lead/Solution only.

Long rationale goes in an **XML comment inside the root element** (`<description>` caps at 255 on RecordType). A comment above the root breaks `sf` deploy at conversion; `Broker_Protection_Access.permissionset-meta.xml` is the correct precedent.

### 4.3 New relationship fields

| Field | Type | Notes |
|---|---|---|
| `LOI__c.Disposition__c` | Lookup → `Disposition__c`, `deleteConstraint SetNull`, `required=false`, `relationshipName Disposition_LOIs` | §1 rule 3 (field name = target object). Mirrors `NDA__c.Disposition__c`, whose `<description>` is the wording precedent. |
| `Contract_Review__c.Disposition__c` | same shape, `relationshipName Disposition_Contract_Reviews` | |

Both existing `Opportunity__c` lookups are already `required=false` (verified), so a disposition child saves with a null Opportunity — **no change needed there.**

### 4.4 New NDA fields

| Field | Type | Notes |
|---|---|---|
| `NDA__c.Party_Role__c` | restricted Picklist: `Buyer` (default), `Introducing Broker` | Part 2 line 114. Not a status → no `Status` suffix (§1 rule 7). |
| `NDA__c.Counter_Signed_Date__c` | Date | Part 2 line 114 (*"We counter-sign both"*). §1 rule 6 suffix `Date`. ⚠ Its siblings are `Date_Sent__c` / `Date_Signed__c`, which pre-date rule 6 — the new field conforms to §1 and the inconsistency is deliberate; note it in the `<description>` so review does not read it as drift. |
| `NDA__c.Is_Decline_Allowed__c` | Checkbox **formula**: `AND(NOT(ISBLANK(Disposition__c)), TEXT(Status__c) = "Sent")` | Backs the "Mark Declined" action's visibility. Exists for the same reason `LOI__c.Is_Advance_Allowed__c` exists — a flexipage visibility rule needs something it can express, and §3.2's value sets are **not** disjoint so `Status__c` alone cannot discriminate. `Disposition__c` is the discriminator because a lookup `ISBLANK` is proven, whereas a record-type traversal in a flexipage rule is not. §1 rule 4 `Is_` prefix ✓. |

### 4.5 New `Disposition__c` fields — the all-signed gate's inputs

| Field | Type | Notes |
|---|---|---|
| `Disposition__c.NDA_Count__c` | Number(3,0), default 0 | §1 rule 9 `_Count__c`. **Derived** — maintained by `NDA_Signed_Rollup`; `<description>` must say so and say "do not hand-edit". |
| `Disposition__c.Signed_NDA_Count__c` | Number(3,0), default 0 | same |

**Two fields, not one.** A single "unsigned count" reads 0 for a disposition with **no NDAs at all**, which would let the gate pass on a disposition where nothing was ever collected — the opposite of the document's rule.

⚠ `NDA__c.Disposition__c` is a **Lookup**, not Master-Detail, so a roll-up summary is unavailable. A flow-maintained pair is the only declarative option.

### 4.6 Paths — six new, three deactivated

Per §1.10. For each of the three objects: set the existing `__MASTER__` path `<active>false</active>` (deactivate, never delete — it is the record of the current guidance text and `recordTypeName` cannot be re-pointed), and create two record-type paths.

| New path | `recordTypeName` | Steps |
|---|---|---|
| `LOI_Path_Acquisition` | `Acquisition_LOI` | the five existing steps, **`<info>` text and `fieldNames` copied byte-identical** from `LOI_Path` |
| `LOI_Path_Disposition` | `Disposition_LOI` | five new steps per §3.1, text from Part 2 lines 55–74 |
| `NDA_Path_Acquisition` | `Acquisition_NDA` | the three existing steps copied byte-identical, **plus a new `Received` step** (Part 1 line 41) between `Sent` and `Signed` |
| `NDA_Path_Disposition` | `Disposition_NDA` | `Not Sent` / `Sent` / `Signed` / `Declined`, text from Part 2 lines 28–41 |
| `Contract_Review_Path_Acquisition` | `Acquisition_PSA` | the four existing steps copied byte-identical |
| `Contract_Review_Path_Disposition` | `Disposition_PSA` | the same four values; text from Part 2 lines 79–89, which inverts *who drafts first* (**our** legal issues the first draft) |

⚠ `Declined` is a terminal off-ramp, not a forward step; it renders as the last step. That is the same shape as `Dead/Pass` on the Opportunity path and is accepted.

### 4.7 Layouts and record-page action lists

**Three new layouts** (deployable), each a copy of the object's existing layout minus the acquisition-directional fields:

| New layout | Excludes |
|---|---|
| `LOI__c-Disposition LOI Layout` | `Submitted_Date__c`, `Approved_By__c`, `Approved_Date__c`, `Approval_Comments__c`, `LOI_Status__c`; **adds** `Disposition__c` |
| `NDA__c-Disposition NDA Layout` | — ; **adds** `Disposition__c`, `Party_Role__c`, `Counter_Signed_Date__c` |
| `Contract_Review__c-Disposition PSA Layout` | — ; **adds** `Disposition__c` |

🔴 **Their assignment to the record types is NOT deployable** (§1.9) — post-deploy gate T-A3.

**Record-page action lists.** `LOI_Record_Page` already has `enableActionsConfiguration = true` — Dynamic Actions is on, and the four listed actions are the *entire* action bar. Add the disposition actions as new `valueListItems`:

| Action | Visibility rule | Self-limiting because |
|---|---|---|
| `LOI__c.Advance_Stage` (existing) | `<persona> AND {!Record.Is_Advance_Allowed__c} EQUAL true` | the formula is extended in §4.9 |
| **NEW** `LOI__c.Mark_Countered_Again` | `<persona> AND {!Record.Stage__c} EQUAL 'Counter Received from Buyer'` | that value is disposition-only (§3.1) |
| **NEW** `LOI__c.Mark_Executed` | `<persona> AND {!Record.Stage__c} EQUAL 'Counter Received from Buyer'` | same |

`NDA_Record_Page` and `Contract_Review_Record_Page`: add **NEW** `NDA__c.Mark_Declined`, visible on `<persona> AND {!Record.Is_Decline_Allowed__c} EQUAL true`. Contract Review needs **no new action** (§1.2).

🔴 `<persona>` is the Q1 answer. Under the recommended (b) every rule becomes `({!$User.Deal_Driver__c} EQUAL true) OR ({!$User.Disposition_Driver__c} EQUAL true)` — ⚠ a flexipage `booleanFilter` has no negation and this repo has an **unresolved question about whether the renderer honours parentheses** (see `Is_Advance_Allowed__c`'s own XML comment, which exists because of exactly that). **Do not write a parenthesised OR.** Instead add the disposition actions as *separate* `valueListItems` entries with pure-AND rules on `Disposition_Driver__c`, duplicating the entry where both personas need the same action. Verbose, proven, and the same workaround the repo already chose once.

⚠ **Enabling Dynamic Actions on `NDA_Record_Page` or `Contract_Review_Record_Page` if it is currently off would silently delete their whole inherited action list.** `Contract_Review_Record_Page` already has it on. **Read each page before editing and report the state; do not enable it as a side effect.**

### 4.8 Disposition record page — the Tranche-2 seam

🔴 **This edits a Tranche-2 file, and that is what Tranche 2 §6 designed for**, not a reopening of it: *"the record page falls back to the Details field section… until Tranche 3."* Keep the edit minimal and re-validate the file.

`flexipages/Disposition_Record_Page.flexipage-meta.xml`: add a `force:relatedListSingleContainer` for `LOI__c` visible at `Disposition_Stage__c EQUAL 'LOI'`, one for `Contract_Review__c` at `'PSA'`, and one for `NDA__c` at `'NDA'`. These are the **creation route** (Q3) as well as the read surface — a related-list New button pre-fills the parent lookup.

⚠ The existing `flexipage_fieldSection` "Details" rule is `NE` × 4 ANDed, so it still renders at `LOI`/`PSA`/`NDA`. Adding related lists **alongside** it is additive and cannot blank the region — do **not** touch the two existing visibility rules.

### 4.9 `LOI__c.Is_Advance_Allowed__c` — extend the formula

```
AND(
  TEXT(Stage__c) <> "Completed",                    /* acquisition terminal */
  TEXT(Stage__c) <> "Executed",                     /* NEW - disposition terminal */
  TEXT(Stage__c) <> "Sent",                         /* acquisition branch */
  TEXT(Stage__c) <> "Counter Received from Buyer",  /* NEW - disposition branch */
  OR( TEXT(Stage__c) <> "Prepare/Review", TEXT(LOI_Status__c) = "Approved" ),
  TEXT(LOI_Status__c) <> "Pending Approval"
)
```

The last two terms name acquisition-only values and are inert on a disposition LOI (`LOI_Status__c` defaults to `Draft` on every LOI, so neither fires). **Keep `TEXT()` compares, never `ISPICKVAL`** — `Prepare/Review` carries a literal slash. Update the `<description>`, `<inlineHelpText>` and the in-file XML comment, which currently describe an acquisition-only rule.

### 4.10 Flow — `NDA_Signed_Rollup`

`flows/NDA_Signed_Rollup.flow-meta.xml` — record-triggered on `NDA__c`, **after save**, create and update.

- 🔴 `<runInMode>SystemModeWithoutSharing</runInMode>` **declared explicitly.** `Disposition__c` is `sharingModel = Private` and whoever works an NDA is not necessarily the Disposition owner. Leaving `runInMode` to the default is the ambiguity that produced the `ApprovalAuditService` failure.
- **Entry condition:** `Disposition__c` is not null. An acquisition NDA must not touch this.
- **Get Records** `NDA__c` where `Disposition__c = {!$Record.Disposition__c}` → count into `NDA_Count__c`; count those with `Status__c = 'Signed'` into `Signed_NDA_Count__c`.
- 🔴 **A no-change Decision before the parent update, AND a fault connector on it — both, from day one.** This is the C1 defect, one module later: `Sale_Decision_Approval`'s `entryCriteria` is `Disposition_Stage__c = 'Disposition Readiness'` with `recordEditability = AdminOnly`, so an off-market disposition sitting under the sale-decision approval is **locked** — and Readiness is exactly where NDAs start being collected on the off-market path. Without both, saving an NDA during that approval throws `ENTITY_IS_LOCKED` and **rolls the NDA save back**. `SystemModeWithoutSharing` does **not** lift an approval lock; that is measured in this repo (`ARCHITECTURE.md`, `OpportunityReviewService` row) and was re-paid in Tranche 2.
- ⚠ Inherit Tranche 2's honest residual language: a swallowed fault leaves a **stale count** until the next NDA save, and a completed autolaunched interview is **not retained**, so the fault message is not retrievable afterwards. State that in the flow `<description>`; do not repeat Tranche 2's original claim that it is observable.

### 4.11 Validation rule — the all-signed release gate

`objects/Disposition__c/validationRules/NDAs_Signed_Before_Release.validationRule-meta.xml`

```
AND(
  $RecordType.DeveloperName = "Off_Market",
  ISCHANGED(Disposition_Stage__c),
  OR( ISPICKVAL(Disposition_Stage__c, "Disposition Offer"),
      ISPICKVAL(Disposition_Stage__c, "LOI"),
      ISPICKVAL(Disposition_Stage__c, "PSA"),
      ISPICKVAL(Disposition_Stage__c, "Closing"),
      ISPICKVAL(Disposition_Stage__c, "Completed") ),
  OR( NDA_Count__c = 0, Signed_NDA_Count__c < NDA_Count__c )
)
```

- `errorDisplayField`: `Disposition_Stage__c`. Message: *"Every NDA on this disposition must be signed before information is released. Add the buyer's NDA (and the introducing broker's, if there is one) and mark each Signed before advancing."*
- **`ISCHANGED` only — deliberately NOT `OR(ISNEW(), ISCHANGED(...))`, diverging from `Wire_Complete_Before_Completed`.** Reason: Tranche 3's own test surface will create off-market dispositions directly at `LOI` and `PSA` to exercise the LOI and PSA features, and `ISNEW()` would block its own fixtures. `DispositionService.findOrCreate` is the only production creator and always creates at `Disposition Readiness`. The residual — create-directly-at-a-later-stage bypasses the gate — is accepted and must be stated in the rule's `<description>` so the divergence from its sibling reads as a decision.
- **Firing surface, re-verified:** Tranche 2 established that nothing but user edits writes `Disposition_Stage__c`. 🔴 **This tranche makes that false** — §5.4 adds the first machine writer (`ContractExecutionService` writing `Closing`). That write targets `Closing`, which **is** in the list above, so an off-market PSA executing with an unsigned NDA would be refused inside a trigger. That is correct behaviour (the gate should hold) but it must be fail-soft in Apex (§5.4) or it rolls back the PSA execution. **Update the claim in `Wire_Complete_Before_Completed`'s description and in Tranche 2 §4.5 rather than leaving a now-false statement in place.**

### 4.12 Flow — gate `Counter_Offer_Notify`

Add an entry condition to `flows/Counter_Offer_Notify.flow-meta.xml`: fire only when the parent LOI has **no** Disposition — `{!$Record.LOI__r.Disposition__c}` **IsNull = true**.

A single-hop lookup traversal in a record-triggered flow's entry conditions is well supported; a record-type traversal is not. This is why the `Disposition__c` lookup, not the record type, is the discriminator here — and it is the same reasoning as §4.4.

🔴 **Not a new notification. This stops an existing one leaking** (§1.8). Record that explicitly in the flow's `<description>` so a future reader does not "restore" it, and so it is not mistaken for a D9 violation.

### 4.13 Permission sets

🔴 **THE REPLACE TRAP APPLIES TO EVERY FILE TOUCHED.** A `PermissionSet` deploy **replaces** that set's entire `objectPermissions` / `fieldPermissions` / `recordTypeVisibilities` list with exactly what the file declares. Any grant existing only org-side is wiped. This bit Broker Protection twice. **Retrieve every set below from the target org and reconcile against the repo copy before writing. Report drift; do not silently overwrite.**

**(a) Record-type visibility — and the scoping is what makes Q3 work.**

| Permission set | `Acquisition_*` (LOI/NDA/PSA) | `Disposition_*` (LOI/NDA/PSA) |
|---|---|---|
| `DPEG_Acquisition_Edit` | visible | — |
| `DPEG_Acquisitions` | visible | visible |
| `DPEG_Admin_Access` | visible | visible |
| `DPEG_Disposition_Edit` | — | visible |

Follow the repo precedent — record-type visibility is declared on the **create/edit** sets; the View sets do not carry it. Scoping it this way means a disposition user creating an LOI from the related list sees **one** available record type, so the platform applies it with no chooser and no reliance on the profile default.

**(b) Object and field grants for the disposition personas — this is the bulk of the work.** `DPEG_Disposition_Edit` / `_View` today grant `NDA__c` (Tranche 2) and **nothing else** on these objects — no `LOI__c`, no `Counter_Offer__c`, no `Contract_Review__c`, no `PSA_Version__c`. All four need object + field grants, mirroring the shape in `DPEG_Acquisition_Edit` / `_View`.

⚠ `NDA__c` in the disposition sets carries `viewAllRecords=true`, accepted at D12/W3 with the revisit trigger recorded as *"when Tranche 3 adds NDA record types"*. **That trigger is now.** The correct long-term shape — view-all scoped to disposition NDAs — is expressible once `Disposition_NDA` exists, via a **criteria-based sharing rule** on `NDA__c` (`RecordType = Disposition_NDA`) plus a plain read. 🔴 Deploy sharing rules **one at a time** — a batch rolls all of them back. Flag this to the user as a follow-up rather than folding it in silently; it is a security narrowing on a live grant and deserves its own decision.

**(c)** New fields need FLS: `Party_Role__c`, `Counter_Signed_Date__c`, `Is_Decline_Allowed__c`, `LOI__c.Disposition__c`, `Contract_Review__c.Disposition__c` (readable/editable per persona) and `Disposition__c.NDA_Count__c` / `Signed_NDA_Count__c` (**readable, editable=false everywhere including the Edit sets** — they are derived, exactly like `Wire_Verification_Completed__c`).

**(d)** If Q1 = (b): a new `Disposition_Deal_Driver` permission set granting FLS **read** on the new `User.Disposition_Driver__c`, mirroring `Acquisition_Deal_Driver` exactly.

### 4.14 App assignment and translations

- `applications/Disposition.app-meta.xml` has `actionOverrides` for `Disposition__c` and `Property_Asset__c` only. A disposition user opening an `LOI__c` / `Contract_Review__c` / `NDA__c` record from a related list falls through to the **org default** page assignment. Add `View` actionOverrides for the three objects pointing at their existing record pages.
- Add every new picklist value to its `objectTranslations/<Object>-en_US/<Field>.fieldTranslation-meta.xml`. Cosmetic, keeps the files honest — Tranche 2 §4.11 precedent.

---

### 4.15 🔴 CORRECTION (2026-08-09, code review W1) — `DispositionNdaStampQueueable`'s stated reason for being async is FALSE on this feature's path

**Recorded here, in the design document, because the file that carries the wrong reasoning is Apex and was deliberately not edited by the declarative pass. The developer who fixes that class header should take the wording from this section.**

The class header copies the acquisition-LOI justification **verbatim**:

> *"All three also set `finalApprovalRecordLock = false`, so the record unlocks when that transaction commits, which is exactly when a Queueable runs."*

**That sentence is true of the acquisition LOI and false here, and the difference is not a nuance — it is the whole mechanism.** `finalApprovalRecordLock = false` releases the lock **on final approval**. On the LOI path the stage is entered *by the approval's own final field update*, so the transaction that fires the trigger **is** the transaction releasing the lock, and a Queueable running after commit genuinely finds the record unlocked. A **disposition** enters the `NDA` stage by an **ordinary user edit**, which has nothing to do with an approval — so a **pending** approval outlives the queueable, and `finalApprovalRecordLock` says nothing at all about that window, which can be days.

**The reachable failure, in full:**

1. An off-market disposition sits at `Disposition Readiness` under a pending `Sale_Decision_Approval`, whose `recordEditability` is `AdminOnly`.
2. An **administrator** — the one principal `AdminOnly` still permits — edits `Disposition_Stage__c` to `NDA`.
3. The trigger fires; the `NDA__c` insert succeeds correctly, because `NDA__c` is not the record under approval and is not locked.
4. `DispositionNdaStampQueueable` then runs **while the approval is still pending**. `Database.update(stamps, true, AccessLevel.SYSTEM_MODE)` throws `ENTITY_IS_LOCKED` — `SYSTEM_MODE` lifts CRUD and FLS but **does not lift an approval lock**, which is measured in this repo (`ARCHITECTURE.md`, `OpportunityReviewService`).
5. `allOrNone = true`, so the batch fails. **`Primary_NDA__c` is never stamped and nothing retries.** The only signal is a failed `AsyncApexJob`.

**The deferral is still the right shape and should NOT be changed.** It converts *"the administrator's stage change is rolled back"* into *"the back-reference is missing"*, which is the correct trade. Two things must change:

1. **The justification.** The benefit is that a lock failure costs a **back-reference** instead of the user's own edit. It is **not** that the queueable is guaranteed to find the record unlocked. As written, the next reader will conclude the stamp cannot fail — and `Primary_NDA__c` null with no retry is precisely the silent-null failure that same header says `Opportunity.Primary_LOI__c` exists to prevent.
2. **The residual must be stated and gated** — see new gate **T-E6** in §8.

**Secondary, same file, flagged not prescribed:** `allOrNone = true` on a single statement carrying up to 200 dispositions means **one** locked or deleted parent fails all 200 stamps. `Database.update(stamps, false, SYSTEM_MODE)` plus a debug of the failed rows would isolate them, but that trades a loud failure for a quiet one. It is a real choice, not an oversight, and belongs to whoever edits the class.

---

## 5. 🟢 DEVELOPER WORK

**Routing:** standard Apex service/selector changes plus three LWC edits. **`salesforce-developer`** — no integration, no async, no governor-limit engineering.

### 5.1 `RecordStageAdvanceService` — record-type-aware (D6 + D14.1, **one change serving both**)

**Shape.** `StageConfig` keeps `label`, `stageField` and `gate` per **object**; `nextStage` and `explicitTargets` become **per record type**:

```apex
private final Map<String /*rtDeveloperName*/, Map<String,String>> nextStageByType;
private final Map<String /*rtDeveloperName*/, Set<String>>        explicitTargetsByType;
private final String defaultTypeKey;   // used when RecordTypeId is null or Master
```

**Call order must change** (§1.5): `configFor()` runs before `load()`, so the map cannot be chosen until the record is in hand. Restructure `advance` / `advanceTo` to load first, resolve the record-type developer name from the loaded `RecordTypeId`, then select the map. **Resolution is a describe, not SOQL** — `recordId.getSObjectType().getDescribe().getRecordTypeInfosById().get(rtId).getDeveloperName()`. Zero added queries.

**Master / null fallback is load-bearing, not defensive.** Between the record-type deploy and the row migration (§7.1), every existing LOI and NDA carries a null `RecordTypeId`. `defaultTypeKey` must point at the **acquisition** map so those rows keep working during the window, and `Contract_Review__c` keeps a single map for both types (§1.2) so it needs no fallback at all.

**Maps:**

```
LOI__c / Acquisition_LOI   Draft -> Prepare/Review -> Sent -> Counter -> Completed   (UNCHANGED)
       explicit targets    {Counter, Completed}                                       (UNCHANGED)
LOI__c / Disposition_LOI   Received -> Under Review -> Countered by DPEG -> Counter Received from Buyer
       explicit targets    {Countered by DPEG, Executed}     <- the loop-back and the exit
NDA__c / Acquisition_NDA   Pending -> Sent -> Received -> Signed                       (D14.1: 'Sent'=>'Received' inserted)
       explicit targets    {}
NDA__c / Disposition_NDA   Not Sent -> Sent -> Signed
       explicit targets    {Declined}
```

🔴 **The allow-list must be per record type, and here is the concrete reason.** `Declined` is disposition-only, but its "Mark Declined" action keys on `Status__c = 'Sent'` — a value **shared** by both NDA record types (§3.2). Record-type picklist restrictions are not enforced by Apex DML, so an object-level allow-list would let `advanceTo(acquisitionNdaId, 'Declined')` succeed and write a disposition value onto an acquisition NDA. **Pin this with a test that asserts the refusal.**

**Selectors.** `LoiSelector.selectStageRequiredById` and `NdaSelector.selectStageRequiredById` must select `RecordTypeId`. Both are `WITH USER_MODE`; `RecordTypeId` is a standard always-readable field, so this widens the field list without widening the FLS denial surface — **say so in the method Javadoc**, because both headers currently justify a deliberately minimal field list.

**Gate.** If Q1 = (b), `hasStageActionAccess(recordId)` must load the record to know which gate applies, adding one SOQL to a `cacheable=true` path invoked once per record view. Acceptable. Add `StageActionGate.DISPOSITION_DRIVER`; `passesGate`'s `when else { allowed = false; }` already fails closed for an unwired gate — keep it.

**Headers.** Update this class's header and `ARCHITECTURE.md` §2 — both still say "five child objects" and describe a flat linear map (§1.5).

### 5.2 `OpportunityReviewService` — stamp the acquisition record types (§1.7)

Stamp `RecordTypeId` on all three inserts: `Contract_Review__c` (`:100`) → `Acquisition_PSA`, `LOI__c` (`:155`) → `Acquisition_LOI`, `NDA__c` (`:230`) → `Acquisition_NDA`. Resolve once per invocation via describe (zero SOQL), **not** per record.

Per Q5, stamp **unconditionally** (null-safe on the describe lookup), diverging from `DispositionService.onMarketRecordTypeId()`'s `isAvailable()` guard, because the LOI block runs as the approver. **Document the divergence in both class headers** so the next reader sees two deliberate patterns rather than one bug.

⚠ Do not disturb the LOI block's other invariants: `AccessLevel.SYSTEM_MODE` DML, and the deferred `LoiPrimaryStampQueueable` back-stamp that exists because `SYSTEM_MODE` does not lift an approval lock. Adding a field to the insert changes neither.

### 5.3 `CounterOfferService` and `PsaVersionService` — the direction branch (§1.8)

Both hardcode `'Seller'`/`'Ours'` and `Ball_In_Court__c = 'Us'`/`'Seller'`. Both need the counterparty label derived from the **parent's record type**, server-side:

- Accept `Buyer` alongside `Seller` and `Ours` in the direction validation.
- Derive the counterparty label once from the parent (`Disposition__c` populated → `Buyer`, else `Seller`) via the existing selector — `CounterOfferSelector` / `PsaVersionSelector` — as **one** extra SOQL on a per-click singleton operation. Do not read it in a loop and do not add inline SOQL to the service.
- `Ball_In_Court__c` becomes `fromCounterparty ? 'Us' : counterpartyLabel`.
- `CounterOfferService`'s `LOI_Status__c = 'Countered'` stamp is acquisition vocabulary. Leave it — `LOI_Status__c` is excluded from the disposition layout (§4.7) so it is invisible there, and suppressing it would be a behaviour change for no requested benefit. State that in the method Javadoc.

⚠ **`Ball_In_Court__c` is the dangerous one and deserves a test each way.** On an acquisition LOI `'Seller'` means the counterparty; on a disposition LOI it would mean **DPEG**. A test that asserts `Buyer` on a disposition parent and `Seller` on an acquisition parent is what stops a future "tidy" from collapsing them.

### 5.4 `ContractExecutionService` — the disposition branch (brief item 3.1)

Add a disposition arm to `handleExecution`: for each Contract Review that **just became `Executed`** and has `Disposition__c != null`, set that Disposition's `Disposition_Stage__c = 'Closing'`.

- 🔴 **Purely additive** (§1.1). Do not touch the existing `cr.Opportunity__c != null` guard, the Day-0 stamp, or `openTransactionsOnAboutToClose`.
- **`AccessLevel.SYSTEM_MODE` DML**, same justification as its two siblings — whoever executes the PSA (Legal, a deal driver) is not necessarily an editor of `Disposition__c`.
- 🔴 **`allOrNone = false`, and the trade must be recorded.** `Disposition__c` can be **locked** by a pending approval, and `SYSTEM_MODE` does not lift an approval lock. An all-or-none update would roll back the PSA execution — losing the legal state — to protect a stage advance. Fail-soft is right here **and its residual is visible, not silent**: the disposition sits at `PSA` while its Contract Review reads `Executed`, which any user can see and fix by hand. Say exactly that in the method Javadoc; do not claim it is harmless.
- ⚠ This write is subject to `NDAs_Signed_Before_Release` (§4.11) on an off-market disposition, which is correct and is a second reason for `allOrNone = false`.
- 🔴 **This is the first machine writer of `Disposition_Stage__c`.** Tranche 2's validation rule and design §4.5 both assert that nothing but user edits writes it. Update both claims in the same change.
- Bulk-safe: one query for the parents, one bulk `Database.update`. No SOQL/DML in a loop.

### 5.5 New quick actions and LWC bundles

Mirror the existing `LOI__c.Mark_Countered` / `Mark_Completed` bundles exactly — each is a headless LWC quick action calling `RecordStageAdvanceController.advanceTo` with a hardcoded target and sharing `c/recordStageGuard`.

| New quick action | Target | Object |
|---|---|---|
| `LOI__c.Mark_Countered_Again` | `Countered by DPEG` | `LOI__c` |
| `LOI__c.Mark_Executed` | `Executed` | `LOI__c` |
| `NDA__c.Mark_Declined` | `Declined` | `NDA__c` |

Per `ARCHITECTURE.md` §5: `LightningConfirm.open()` for the confirmation (never a toast — a toast returns nothing), permission check → confirm → act, `getRecordNotifyChange` on success (the write is imperative Apex, behind LDS's back), and the guard reads `error.body.message` only, which is **correct** for the Apex path and must not be "fixed". Each bundle keeps ownership of its own toasts. **Do not merge the three guard utils.**

### 5.6 LWC edits

- **`lwc/loiCounterOffer`** — `directionOptions` (`:111–114`) and the `DIRECTION` pill map (`:12–15`) are `Seller`/`Ours` only, and `ballBadgeLabel` (`:191`) hardcodes *"Ball: seller court"*. Add `Buyer` to the pill map and branch the option labels on whether the LOI has a Disposition. The ball badge is already suppressed off the Opportunity page (`hasBall` requires `isOnOpportunity`), so on the LOI record page it does not render — verify rather than assume, and leave the Opportunity path untouched.
- **`lwc/psaVersionLog`** — same direction-label treatment.
- **`lwc/dispositionSidebar`** — 🔴 its `isOfferStage` comment (`:43–47`) justifies showing the offer card at `LOI` **because the negotiation is still recorded on `Disposition_Offer__c`'s counter fields**. §7 removes those fields, so that justification dies with them. **Keep the card at `LOI` for context; rewrite the comment.** Leaving a now-false comment behind is the failure mode Tranche 2's review called out by name.

### 5.7 `TestDataFactory` and tests

- **`TestDataFactory` must stamp record types** on `NDA__c` (`:698`, `:1172`), `LOI__c` (`:1213`) and `Contract_Review__c` (`:1328`), defaulting to the acquisition type with an overload for the disposition type — the exact shape `createDispositions` already uses, including the **constant-first `.equals()`** allow-list (Apex `String ==` is case-insensitive; `getRecordTypeInfosByDeveloperName()` is case-sensitive).
- ⚠ `TestDataFactory.cls:1798` sets `Offer_Status__c = 'Received'`. If Q2 is answered as Reading A this line breaks at runtime; under the recommended Reading B it is untouched. **Confirm before §7 runs.**
- **`TestDataFactoryTest`** exists and its third method is **deliberately RED** pending gate A1 (D13). Adding six more record types adds more of the same; extend it with unconditional assertions per new type, and **do not guard, skip or delete any of them to obtain a green suite.**
- **Bulk rule:** `advance` / `advanceTo` / `saveCounterOffer` / `saveVersion` are per-transaction-singleton `@AuraEnabled` operations — the `.claude/rules/bulk-test-rule.md` exemption applies and the reasoning must be in the test class header. `ContractExecutionService.handleExecution` is **trigger-driven and is NOT exempt** — it needs a 251-record bulk test, and one already exists; extend it with disposition-parented rows.
- **Suites needing updates:** `RecordStageAdvanceServiceTest`, `RecordStageAdvanceControllerTest`, `LoiSelectorTest`, `NdaSelectorTest`, `CounterOfferServiceTest`, `PsaVersionServiceTest`, `ContractExecutionServiceTest`, `OpportunityReviewServiceTest`, `TestDataFactoryTest`; Jest: `loiCounterOffer`, `psaVersionLog`, `dispositionSidebar`, plus the three new bundles.
- ⚠ **An FLS or record-type test that runs as an admin cannot fail.** Persona acceptance testing (§8, gate T-D) is the only real proof.

---

## 6. DEPLOYMENT ORDER

Tranche 2's D1–D6 and GATE A run **first and unchanged**. Tranche 3 then follows. Metadata before Apex, always.

| # | Contents | Why here |
|---|---|---|
| **T1** | §4.1 all picklist adds + §4.2 all six record types + §4.3 two lookups + §4.4 three NDA fields + §4.5 two Disposition counters + §4.14 translations — **ONE deployment** | Values must exist before a record type can restrict them, and any gap leaves all ten LOI stages and all six NDA statuses globally selectable on every record. One deployment ⇒ zero exposure window. |
| **GATE T-A** | T-A1 profile record-type assignment (6 types) · T-A2 per-profile defaults · T-A3 layout assignment | Org state. Not deployable. Must precede any Path activation. |
| **GATE T-B** | **Three row migrations** (§7.1), each with a read-back | Adding record types leaves live rows on Master, matching no Path. Must precede Path activation for the same reason as Tranche 2's A2. |
| **T2** | §4.13 permission sets, after the org-drift reconciliation | Record types must exist before `recordTypeVisibilities` can name them. |
| **T3** | §4.6 six Paths + three deactivations · §4.7 layouts + record-page action lists · §4.8 Disposition record page · §4.9 the formula · §4.14 app actionOverrides | Depends on T1 and GATE T-B. |
| **T4** | §4.10 `NDA_Signed_Rollup`, **then** §4.11 the validation rule | **Flow before VR.** Deploying the rule first leaves both counters at 0 with nothing able to set them, so no off-market disposition could advance past `NDA` at all. Same lesson as Tranche 2's D4. |
| **T5** | §4.12 `Counter_Offer_Notify` entry condition | Must land **before** any disposition Counter Offer can exist, i.e. before T6. |
| **T6** | §5 all Apex + LWC + quick actions + tests | Record-type describe lookups are runtime, so there is no compile dependency — but the tests that assert the stamps need T1 in the org. |
| **GATE T-C** | **The `Disposition_Offer__c` migration** (§7.2) — its own wave, run only after the disposition LOI is live and verified | Destructive and irreversible. Nothing above depends on it. |
| **T7** | §7.2 step 5: the reduced `Offer_Status__c` value set + the `destructiveChanges.xml` field retirement | Only after GATE T-C reports zero rows on the retiring values. |
| **GATE T-D** | Post-deploy verification, §8 | |

---

## 7. DATA MIGRATION PLAN

Four migrations. Three are additive-and-reversible; the fourth is destructive. **They are listed separately because they have different risk profiles and different sign-offs.**

### 7.1 The three record-type row migrations (GATE T-B) — reversible

Adding record types leaves every existing row on **Master**. A Master row matches no record-type Path, shows the unrestricted value set, and falls through `RecordStageAdvanceService`'s `defaultTypeKey`.

| Object | Rule | Note |
|---|---|---|
| `LOI__c` | all rows → `Acquisition_LOI` | Every LOI in the org today is acquisition-side by construction — `LOI__c` has no `Disposition__c` lookup before T1. |
| `Contract_Review__c` | all rows → `Acquisition_PSA` | Same reasoning. |
| `NDA__c` | 🔴 **branch on the parent:** `Disposition__c != null` → `Disposition_NDA`; else → `Acquisition_NDA` | `NDA__c` is already dual-parented, so this is the one migration that is not a blanket update. |

**Procedure for each, and no step is optional:**

1. **Count before.** `SELECT COUNT(Id) FROM <Object>` and `SELECT COUNT(Id) FROM NDA__c WHERE Disposition__c != null`.
2. **Update**, in a script checked into `scripts/` so the evidence survives the window (J3's recommendation from Tranche 2's review).
3. 🔴 **Read back — a script that ran without error is NOT evidence the record type landed.** D13 residual 1 measured `getRecordTypeInfosByDeveloperName()` returning a real Id while `isAvailable()` was `false` for an assigned System Administrator, under which condition every guarded stamp silently no-ops. Run `SELECT RecordTypeId, COUNT(Id) FROM <Object> GROUP BY RecordTypeId` and confirm **zero rows remain on Master**.
4. **Reversal:** re-run with the previous type. Record types are a field value; nothing is destroyed.

### 7.2 The `Disposition_Offer__c` migration (GATE T-C / T7) — 🔴 DESTRUCTIVE AND IRREVERSIBLE

**Scope, under the recommended Q2 answer (Reading B):** retire `Countered by DPEG` and `Counter Received from Buyer` from `Offer_Status__c`; retire `DPEG_Counter_Price__c`, `DPEG_Counter_Date__c`, `Buyer_Counter_Price__c`, `Final_Agreed_Price__c`. `Received` (default), `Under Review`, `Accepted`, `Rejected`, `Withdrawn by Buyer` remain.

**Step 0 — MEASURE, in the target org, before anything else.** *(NEEDS ORG VERIFICATION — this design cannot query the org.)*

```sql
SELECT Offer_Status__c, COUNT(Id) FROM Disposition_Offer__c GROUP BY Offer_Status__c

SELECT Id, Name, Disposition__c, Buyer_Name__c, Offer_Amount__c, Offer_Status__c,
       DPEG_Counter_Price__c, DPEG_Counter_Date__c, Buyer_Counter_Price__c, Final_Agreed_Price__c
FROM Disposition_Offer__c
WHERE DPEG_Counter_Price__c != null OR DPEG_Counter_Date__c != null
   OR Buyer_Counter_Price__c != null OR Final_Agreed_Price__c != null
```

**Step 1 — repo sweep. Already done here; these are the complete in-repo results.**

| Consumer | Finding |
|---|---|
| Reports (`reports/`) | **Zero** references to `Offer_Status__c` or `Disposition_Offer__c` |
| Flows | **Zero** — no flow references `Disposition_Offer__c` |
| Apex / LWC | **One**: `TestDataFactory.cls:1798` sets `Offer_Status__c = 'Received'`. `lwc/dispositionOffer` renders buyer / amount / date only. No Apex touches the object otherwise. |
| Permission sets | Field permissions in `DPEG_Disposition_Edit`, `DPEG_Disposition_View`, `DPEG_Acquisitions` — the four counter fields and `Offer_Status__c` |
| Translations | `objectTranslations/Disposition_Offer__c-en_US/` — five files, one per affected field |
| Layout | `layouts/Disposition_Offer__c-Disposition Offer Layout` |
| Profiles | Present, but `profiles/**` is `.forceignore`d and never deploys |

⚠ **This sweep is necessary and not sufficient.** No file-based check can establish a negative claim about org state.

**Step 2 — ORG sweep (DevOps, before step 4).** List views on `Disposition_Offer__c`, reports and dashboard components created in-org, any in-org flow or validation rule filtering on the retiring values. 🔴 **Reports do NOT block a field deletion — they break silently afterwards.** That is the whole reason this step exists.

**Step 3 — resolve live rows.** Any row on `Countered by DPEG` or `Counter Received from Buyer` must be re-expressed as a `Disposition_LOI` plus `Counter_Offer__c` rows — which is only possible because T1–T6 landed first. **The re-expression rule needs the user's decision (part of Q2):** migrate each countered offer into a new disposition LOI with its counter rounds, or re-set the status and let the LOI be created fresh. Do not proceed to step 4 until step 0's first query returns **zero** on both values.

**Step 4 — EXPORT the four counter columns to CSV before deleting anything.** A deleted field's data is unrecoverable after the recycle-bin window. This is cheap insurance and is mandatory.

**Step 5 — retire in two moves, not one.**
1. Remove the four fields from the layout, the permission sets and the translations, and deploy the reduced `Offer_Status__c` value set. The fields are now invisible and unwritable but the data still exists.
2. After a soak period the user nominates, delete the fields via `destructiveChanges.xml`.

**Step 6 — read back.** `SELECT Offer_Status__c, COUNT(Id) FROM Disposition_Offer__c GROUP BY Offer_Status__c` returns only the surviving values; `sf sobject describe` confirms the four fields are gone; `lwc/dispositionOffer` still renders; the `dispositionSidebar` offer card still renders at `LOI`.

---

## 8. POST-DEPLOY GATES

Every Tranche-2 gate still applies. These are additional, and none is optional. All are invisible to a green deployment.

**T-A — before the feature is usable**

- **T-A1.** Assign all **six** new record types to every profile in use, **including System Administrator** — Modify All Data is an object permission and confers no record-type access. `profiles/**` is `.forceignore`d; this cannot be deployed. ⚠ Include the two **approver** profiles: `OpportunityReviewService`'s LOI block runs as the approver (§1.7).
- **T-A2.** Set the per-profile **default** record type for `LOI__c`, `NDA__c` and `Contract_Review__c`. `PermissionSet.recordTypeVisibilities` has no `default` element — profile-only, therefore org state.
- **T-A3.** Assign the three new disposition **layouts** to the three disposition record types, per profile (§1.9). Verify by opening a disposition LOI and confirming `Submitted_Date__c` / `Approved_By__c` are absent — **as a disposition persona, not as an admin.**

**T-B — migration (see §7.1)** — three read-backs, zero rows left on Master.

**T-C — the create path, which the migration gates do not cover**

- **T-C1.** Drive an Opportunity through the NDA, LOI and PSA stage entries and **read `RecordTypeId` back** on each auto-created child. A creation that succeeded is not evidence the type landed. Run the LOI case **as the approver**, because that is the principal it actually executes as.
- **T-C2.** Create an LOI, an NDA and a Contract Review from the Disposition record page's related lists **as a `DPEG_Disposition_Edit` persona** and read `RecordTypeId` back. Confirm **no record-type chooser appeared** — if one did, the §4.13(a) scoping is wrong.

**T-D — persona acceptance. 🔴 An admin smoke test proves nothing here.**

- **T-D1.** As a disposition persona: open a disposition LOI, confirm the stage actions are **visible**, advance `Received → Under Review → Countered by DPEG → Counter Received from Buyer`, then take **both** branch buttons in turn. This is the direct test of Q1 — if the persona sees no buttons, Q1 was answered wrong.
- **T-D2.** Log a counter on a disposition LOI and confirm the direction option reads **Buyer**, the recorded `Direction__c` is `Buyer`, and `Ball_In_Court__c` shows `Buyer` (not `Seller`).
- **T-D3.** Confirm the **Acquisitions team receives NO notification** for that counter (§4.12), and that an acquisition counter still does.
- **T-D4.** As an acquisition deal driver: confirm an acquisition LOI still advances `Draft → … → Completed` and still shows `Submit for Approval` at `Prepare/Review` — the live-regression check.

**T-E — the NDA feature**

- **T-E1.** Acquisition NDA advances `Pending → Sent → Received → Signed`; `NDA_Signed__c` flips true only at `Signed`.
- **T-E2.** Disposition NDA advances `Not Sent → Sent → Signed`; **Mark Declined** appears on a disposition NDA and **does not appear** on an acquisition NDA. Then call `advanceTo(acquisitionNdaId, 'Declined')` directly and confirm the refusal (§5.1). ⚠ **AMENDED 2026-08-09 (D20/C1):** this gate used to say Mark Declined appears *at `Sent`*. The built `NDA__c.Is_Decline_Allowed__c` is true at **`Not Sent`, `Sent` AND `Signed`** — every disposition state except `Declined` itself — because `NDA_DISPOSITION_EXPLICIT_TARGETS` imposes no from-stage precondition, and because `Signed → Declined` is the documented recovery in `NDA_Path_Disposition` and, under D20/C2, is now the **only** way to take a party back out of the all-signed gate's arithmetic. Test all three.
- **T-E2a.** 🔴 **The no-buttons gate — the defect this whole flexipage pass exists to close, and it is invisible to any green deploy.** As a **disposition** persona (not an admin, not an acquisition driver), open a disposition NDA and confirm **Advance Stage** and **Mark Declined** are both **visible**. Then open a **`Declined`** disposition NDA and confirm **neither** appears. Then, as an **acquisition** deal driver, open an acquisition NDA and confirm **Advance Stage still appears** — the live-regression check, because `NDA_Record_Page`'s action list was rewritten.
- **T-E2b.** 🔴 **The duplicate-entry render check — this shape has no precedent in this repo.** `NDA_Record_Page` now lists `NDA__c.Advance_Stage` **twice**, under two different pure-AND visibility rules, because a flexipage `booleanFilter` has no negation and a parenthesised OR has been measured here to deploy but not be honoured by the renderer. Confirm (a) check-only accepts two `valueListItems` carrying the same `<value>`, and (b) a user holding **both** driver flags does not see the button rendered twice on a disposition NDA. If duplicates are rejected outright, the fallback is a separate disposition quick action — **never** reintroducing an OR.
- **T-E3.** Move a `Signed` NDA to `Declined` and confirm `NDA_Signed__c` flips false, `Date_Signed__c` is retained, and the acquisition `NDA_Signed_Before_Deal_Progression` VR re-blocks (§3.2).
- **T-E4.** 🔴 **The locked-parent test — the only gate that exercises §4.10's fault path.** Put an **off-market** disposition at `Disposition Readiness`, **submit it for `Sale_Decision_Approval`**, then save an `NDA__c` against it from the UI as a disposition persona. **Expected: the NDA saves.** Then approve or recall, save the NDA again, and confirm the counters reconcile. This is C1 one module later; B6-equivalent testing with no approval pending would not catch it.
- **T-E5.** Off-market all-signed gate: with one unsigned NDA, attempt `NDA → Disposition Offer` **and** `NDA → LOI` and confirm both are refused in the Path UI with the rule's message. Sign it and confirm both are permitted. Confirm an **on-market** disposition is unaffected.
- **T-E5a.** 🔴 **The Declined arithmetic (D20/C2) — three cases, and the second is the one that used to be a permanent dead end.** (i) A disposition whose **only** NDA is `Declined`: confirm `NDA_Count__c` reads **0** and the stage is **still refused** — collecting nothing is not collecting everything, and this is the case that proves the exclusion did not open the gate. (ii) Two NDAs, buyer `Signed` and broker `Declined`: confirm the stage is **permitted**. (iii) Mark a `Signed` NDA `Declined` and confirm the counters **fall** and the gate re-evaluates. ⚠ Verify by reading `NDA_Count__c` / `Signed_NDA_Count__c` back on the parent, not by inferring from whether the stage moved — the flow's fault connector swallows a locked-parent failure into a **stale count**, which looks identical to a wrong count.
- **T-E5b.** 🔴 **The create path D19.1 depends on, and the related list that makes it reachable.** As a `DPEG_Disposition_Edit` persona, open an off-market disposition at the `NDA` stage, find the **NDAs** related list on the record page, press **New**, and confirm (a) the list is there at all, (b) **no record-type chooser appears** and the created row lands on `Disposition_NDA`, and (c) clicking into it from that list **inside the Disposition app** opens `NDA_Record_Page` — which depends on the `NDA__c` `View` actionOverride added to `Disposition.app`, not on the flexipage. Then confirm **Delete is absent**: `allowDelete` stays `false` by decision, and a delete button appearing would mean the grant list drifted.
- **T-E6.** 🔴 **The locked-parent stamp — §4.15's residual, and it is a DIFFERENT test from T-E4.** T-E4 proves the *flow's* fault path survives a locked parent; this proves what the *queueable* does. Put an off-market disposition at `Disposition Readiness`, **submit it for `Sale_Decision_Approval`**, then move `Disposition_Stage__c` to `NDA` **as an administrator** (which `recordEditability = AdminOnly` permits and no other persona can do). Then read back **both**: `Primary_NDA__c` on the disposition, and the `AsyncApexJob` for `DispositionNdaStampQueueable`. **Expected today:** the `NDA__c` row exists, `Primary_NDA__c` is **null**, and the job **failed** with `ENTITY_IS_LOCKED`. That is the accepted residual, not a surprise — but it must be *observed* rather than assumed, because the class header currently asserts it cannot happen.

**T-F — the PSA feature**

- **T-F1.** Execute a disposition PSA and confirm `Disposition_Stage__c` moves to `Closing`, **no `Transaction__c` is created**, and the Transactions / IR / Due Diligence notifications do **not** fire (§1.1 predicts all three; verify rather than assume).
- **T-F2.** Execute an **acquisition** PSA and confirm the Day-0 stamp and the three notifications still fire — the live-regression check.
- **T-F3.** Attempt a disposition PSA execution on an off-market disposition with an unsigned NDA and confirm the stage write fails **soft**: the Contract Review still reads `Executed`, the disposition still reads `PSA`, and nothing is rolled back (§5.4).

**T-G — the offer migration** — §7.2 step 6.

**T-H — `LOI__c` access for the disposition personas (D20.1). Added 2026-08-09; belongs to Tranche 3B but the grants ship with 3A's fix pass.**

- **T-H1.** 🔴 **Two-phase, and phase one is expected to fail.** The two new `SharingCriteriaRule`s in `sharingRules/LOI__c.sharingRules-meta.xml` filter on `RecordTypeId equals LOI__c.Disposition_LOI` and **cannot validate until that record type exists in the target org** — the identical D19.2 condition that produced the two NDA failures. Deploy the LOI record types first, then the rules **one at a time** (a batch rolls all of them back in this org). Four sharing-rule deploys total across 3A and this pass, never batched.
- **T-H2.** As a `DPEG_Disposition_Edit` persona, open a **disposition** LOI and confirm it is visible and editable. Then attempt to open an **acquisition** LOI and confirm it is **not** visible — that is the whole point of scoping, and an unscoped grant would hand this persona the approval flags that gate PSA entry.
- **T-H3.** As a **Principal** (`DPEG_Disposition_View` via `DPEG_Principal_PSG`), confirm a disposition LOI is visible and **read-only**. 🔴 This is the population the second rule exists for — principals are not necessarily in `DPEG_Acquisitions_Team`, and group membership is org state that no deploy can guarantee.
- **T-H4.** Confirm an **acquisition** deal driver still sees and edits acquisition LOIs exactly as before — the live-regression check for a change that touched two permission sets and added an object.
- **T-H5.** ⚠ **Open question handed to 3B, not a gate to pass:** `allowCreate` on `LOI__c` is **false** on both sets, per D20.1 read literally. That is the same shape that produced C2 — create withheld on the premise "a trigger will do it", then the trigger turning out to make only one of the two rows. If 3B's LOI auto-create is partial in that way, **this grant must move with it** rather than being rediscovered in a third review. `recordTypeVisibilities` for `LOI__c.Disposition_LOI` belongs in that same change.

---

## 9. 📝 PROMPTS FOR SPECIALIST AGENTS

*These are written for the single-cycle build. If the user accepts the §0.1 split, issue §4/§5 in three passes: 3A = §4.1(NDA+direction adds)/4.2(NDA)/4.4/4.5/4.6(NDA)/4.7(NDA)/4.10/4.11/4.13 + §5.1/5.7; 3B = the LOI half + §7.2; 3C = the PSA half.*

### 🟤 PROMPT FOR salesforce-solution-architect

```
Read ARCHITECTURE.md and agent-output/design-requirements-disposition-loi-psa-nda.md first,
including §1 PREMISE CORRECTIONS. Build ONLY §4. Create metadata files; do not deploy.

1.  §4.1  Picklist ADDS only, per §3.1/§3.2/§3.3. Zero removals. Do not touch any existing
          value, label or master default. Fix LOI__c.Stage__c's stale <description>.
2.  §4.2  SIX record types. Each file must enumerate <picklistValues> for EVERY picklist on
          its object - walk the fields/ directory, do not assume. Precedent:
          objects/Opportunity/recordTypes/Commercial.recordType-meta.xml. Defaults per §3.
          No <businessProcess>. Long rationale in an XML comment INSIDE the root element.
3.  §4.3  LOI__c.Disposition__c and Contract_Review__c.Disposition__c lookups.
4.  §4.4  NDA__c.Party_Role__c, Counter_Signed_Date__c, Is_Decline_Allowed__c (formula).
5.  §4.5  Disposition__c.NDA_Count__c and Signed_NDA_Count__c, both described as derived.
6.  §4.6  Deactivate LOI_Path, NDA_Path and Contract_Review_Negotiation_Path; create SIX
          record-type paths. Copy every existing step's fieldNames AND info text
          byte-identical. Do NOT edit the Active Listing text on either Disposition path.
7.  §4.7  Three new disposition layouts, plus the record-page action-list additions. READ
          each flexipage's enableActionsConfiguration BEFORE editing and REPORT its value -
          enabling Dynamic Actions where it is off silently deletes the whole inherited
          action list. Do NOT write a parenthesised OR in any booleanFilter; use separate
          valueListItems entries with pure-AND rules.
8.  §4.8  Disposition_Record_Page: ADD three related lists. Do NOT touch the two existing
          visibility rules.
9.  §4.9  Extend LOI__c.Is_Advance_Allowed__c. TEXT() compares, never ISPICKVAL.
10. §4.10 Flow NDA_Signed_Rollup with an EXPLICIT <runInMode>SystemModeWithoutSharing</runInMode>,
          a no-change Decision AND a fault connector - both, from day one. Read the C1
          write-up in agent-output/code-review-disposition-foundations.md before building it.
11. §4.11 Validation rule NDAs_Signed_Before_Release, formula as written, ISCHANGED only.
          Also correct the now-false "nothing but user edits writes Disposition_Stage__c"
          claim in Wire_Complete_Before_Completed's description.
12. §4.12 Add the entry condition to Counter_Offer_Notify. This STOPS an existing
          notification leaking cross-module; it is not a new notification.
13. §4.13 Permission sets. BEFORE writing, retrieve every set you touch from the target org
          and reconcile - a PermissionSet deploy REPLACES the whole grant list. Report drift;
          do not silently overwrite. Raise the NDA__c viewAllRecords narrowing as a separate
          recommendation; do not fold it in.
14. §4.14 App actionOverrides and all new picklist translations.

Do NOT build: any notification, notification type, email alert or notify flow (the §4.12
entry condition is the ONE exception and it only SUPPRESSES); any Disposition__c trigger or
auto-creation automation; any change to Disposition_Offer__c (that is §7, a later wave); any
edit to the Active Listing Path text; any validation rule other than the one named; any
record type on Counter_Offer__c, PSA_Version__c or Disposition_Offer__c.
```

### 🟢 PROMPT FOR salesforce-developer

```
Read ARCHITECTURE.md and agent-output/design-requirements-disposition-loi-psa-nda.md first,
including §1 PREMISE CORRECTIONS. Build ONLY §5. The §4 metadata must already exist in the repo.

1. §5.1 RecordStageAdvanceService: make nextStage AND explicitTargets per RECORD TYPE, not
        per object. configFor() currently runs BEFORE load(), so restructure advance/advanceTo
        to load first and resolve the record-type developer name by DESCRIBE (zero SOQL).
        defaultTypeKey falls back to the ACQUISITION map for null/Master rows - that fallback
        is what keeps live rows working between the record-type deploy and the migration.
        Contract_Review__c keeps ONE map for both types (§1.2). Widen LoiSelector and
        NdaSelector selectStageRequiredById to select RecordTypeId and justify it in the
        Javadoc. Pin with a test that advanceTo(acquisitionNdaId,'Declined') is REFUSED -
        record-type picklist restrictions are NOT enforced by Apex DML.
2. §5.2 OpportunityReviewService: stamp Acquisition_LOI / Acquisition_NDA / Acquisition_PSA on
        its three inserts, resolved once per invocation. Stamp UNCONDITIONALLY (Q5) and
        document the deliberate divergence from DispositionService's isAvailable() guard in
        BOTH headers. Do not disturb the LOI block's SYSTEM_MODE DML or its deferred
        LoiPrimaryStampQueueable back-stamp.
3. §5.3 CounterOfferService and PsaVersionService: accept 'Buyer', derive the counterparty
        label from the parent's Disposition__c via the existing selector (ONE extra SOQL, not
        in a loop), and set Ball_In_Court__c accordingly. Test BOTH directions on BOTH parents -
        'Seller' on a disposition record would mean DPEG, which inverts the field's meaning.
4. §5.4 ContractExecutionService: ADD a disposition arm to handleExecution moving
        Disposition_Stage__c to 'Closing'. AccessLevel.SYSTEM_MODE, allOrNone = FALSE, with
        the trade recorded in the Javadoc. Do NOT touch the Opportunity guard, the Day-0 stamp
        or openTransactionsOnAboutToClose - §1.1 explains why nothing needs preventing.
5. §5.5 Three new headless quick-action bundles, mirroring LOI__c.Mark_Countered exactly:
        LightningConfirm.open(), permission check -> confirm -> act, getRecordNotifyChange on
        success, sharing c/recordStageGuard. Do not merge the three guard utils.
6. §5.6 loiCounterOffer and psaVersionLog direction labels; dispositionSidebar's isOfferStage
        COMMENT (the card stays; the justification is about to become false).
7. §5.7 TestDataFactory record-type stamps on 4 creation sites, constant-first .equals()
        allow-list. Extend TestDataFactoryTest. Do NOT guard or skip its deliberately-red
        assertions to get a green suite.

Follow the repo's layering rules: all SOQL in selectors, services throw raw platform
exceptions, the AuraHandledException boundary stays in the controller. The
per-transaction-singleton bulk exemption applies to advance/advanceTo/saveCounterOffer/
saveVersion - record that in the test class headers. ContractExecutionService.handleExecution
is trigger-driven and is NOT exempt: extend its existing 251-record bulk test with
disposition-parented rows.

Do NOT build: any notification; any Disposition__c trigger; any auto-creation of a
disposition LOI/PSA/NDA; any change to Disposition_Offer__c; a generic advanceTo without a
per-record-type allow-list.
```
