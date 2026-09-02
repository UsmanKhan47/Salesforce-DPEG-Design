# Design — `NDA__c.Property__c` population + Dead/Pass off-ramp

**Date:** 2026-09-02 · **Agent:** salesforce-design · **Scope:** design only, no implementation metadata or Apex.
**Org:** `usman-dpeg` (API 67.0) · **Branch:** `qa/lifecycle-simulation-2026-08-27`

> **Provenance rule for this document.** Every claim below carries its `file:line`. Claims marked
> 🟡 **UNVERIFIED-IN-ORG** are read off the repo and are *deterministic inferences*, not org probes —
> this agent has file-system tools only (no `sf` CLI, no `salesforce-api-context` MCP, no org access;
> see §7). Do not promote a 🟡 to a fact by quoting this document. Two figures in a recent design here
> were wrong and propagated because agents read the doc as authority.

---

## §0 — Findings that contradict or materially extend the brief

Read this section before anything else. Three of the brief's framings change the shape of the work.

| # | Brief said | Measured | Consequence |
|---|---|---|---|
| **0.1** | Item A — "property must be populated once nda record is created", timing "settled" | 🔴 **On the lead-conversion path `Opportunity.Property__c` is NULL at the moment the NDA is created, and the `Property__c` ROW does not exist yet either.** `ensureNda` is insert-only (`OpportunityReviewService.cls:639-642`) and routes from **after insert** (`OpportunityReviewTriggerHandler.cls:101-103,121`). `LeadConvertService.stampConvertedOpportunities` runs from the **Lead after-update** trigger *after* the Opportunity already exists (`LeadConvertService.cls:308-314`), and only there does it `createProperties` (`:321`) then set `o.Property__c` (`:612-614`) in a later `update` (`:324`). | Stamping "at creation" alone **reproduces the reported symptom** for every lead-converted deal. The design must also cover the parent's later update, or ship nothing. This is the crux the brief flagged, and it resolves **against** the naive reading of the user's words. |
| **0.2** | Item B — "no Dead/Pass off-ramp action… `Acquisitions_Deal_Path` mentions 'Dead' once" | 🔴 **The Path already has a full Dead/Pass step, and it already prompts for the Rejection Reason** — `pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml:17-21`, `<fieldNames>Rejection_Reason__c</fieldNames>`, info *"Deal dropped at any stage. Rejection Reason is required."* **But that Path is `<recordTypeName>__MASTER__</recordTypeName>` (`:51`) and is the ONLY Opportunity PathAssistant in the repo** (measured across all 24 files in `pathAssistants/`). Opportunity carries record types `Land` and `Retail`, and `LeadConvertService` stamps one on **every** converted deal — with a `Retail` default added 2026-08-31 specifically so no deal lands untyped (`LeadConvertService.cls:615-646`). | 🟡 The most likely cause of *"I can't see dead button at any level"* is **not a missing button** — it is that the whole Path renders nothing on a record-typed deal. The repo states the rule itself: *"Once record types exist, a `__MASTER__` path renders for the Master type only — which after the row migration is NO ROWS"* (`pathAssistants/NDA_Path.pathAssistant-meta.xml:17-19`). **Resolve this before building anything.** |
| **0.3** | Item A/4 — "confirm FLS grants exist for the personas on that path" | `NDA__c.Property__c` is granted by **exactly one** permission set in the repo: `DPEG_Acquisition_Edit` (`:903`, `editable=true`). It is **absent** from `DPEG_Acquisition_View`, `DPEG_Admin_Access`, `DPEG_Disposition_Edit`, `DPEG_Disposition_View`, `DPEG_Opportunity_View`. | A read-only Principal and a bare System Administrator will still see **nothing** after the fix — the field is not FLS-denied to them, it is *absent from their accessible schema*. Widening is a **security decision**, not a bug fix; see §3-D. |
| **0.4** | Item B/3 — "⚠ this repo has a recorded incident where enabling Dynamic Actions silently emptied a page's action bar" | Dynamic Actions is **already enabled** on this page — `flexipages/Opportunity_Record_Page.flexipage-meta.xml:163-166` (`enableActionsConfiguration = true`) with 8 `valueListItems` already wired (`:9-156`). | That specific incident **does not apply** here (nothing is being enabled). The live risk is the *other* recorded one: **a FlexiPage deploy replaces the org copy**, and this page has been hand-edited in App Builder before. See §6-G3. |
| **0.5** | Item B/2 — the `%2F` warning | Confirmed and narrowed. `'Dead%2FPass'` appears in **exactly three files**, all `objects/Opportunity/businessProcesses/` (`Land:33`, `Retail:40`, `Commercial:18`). Every other surface uses the decoded `'Dead/Pass'`. Full table in §2.5. | **Nothing this design adds needs the encoded form.** |
| **0.6** | Item A/5 — "the map is already resolved once per chunk; say whether it covers the NDA path" | It does **not**. `propertyByOpp` is built inside `createReviewRecords` (`OpportunityReviewService.cls:326,352`) and only for deals entering the **LOI** stage. `ensureNda` is a separate method with its own scope. | 🟢 **But no query is needed anyway.** `ensureNda` receives `newOpps` = `Trigger.new`, so `o.Property__c` is already in memory. The LOI block's own comment states the pattern: *"read from Trigger.new rather than re-queried"* (`:525-527`). The cost of the creation-time half is **zero SOQL, zero extra DML**. |

---

## §1 — ITEM A · `NDA__c.Property__c` is never populated

### 1.1 What is true today (all measured)

| Fact | Evidence |
|---|---|
| The acquisition NDA is created with three fields and `Property__c` is not one of them | `OpportunityReviewService.cls:665` — `new NDA__c(Opportunity__c = oppId, Status__c = 'Pending')` + guarded `RecordTypeId` (`:666-668`) |
| Nothing anywhere writes `NDA__c.Property__c` | Repo-wide sweep for `NDA__c.Property__c` returns **1 hit, and it is a permission set** (`DPEG_Acquisition_Edit:903`). Zero Apex, zero Flow, zero seed script. Confirms the brief: an omission, never a regression. |
| The field is a Lookup, optional, `SetNull` | `objects/NDA__c/fields/Property__c.field-meta.xml:3-12` |
| It IS on the record page, unconditionally, for both record types | `flexipages/NDA_Record_Page.flexipage-meta.xml:550-559` — `Record.Property__c`, `uiBehavior=none`, **no `visibilityRule`**. This is the blank field the user is looking at. |
| It is **not** on the classic layout | `layouts/NDA__c-NDA Layout.layout-meta.xml` — zero `Property` matches |
| **Nothing reads it.** | `NdaSelector.cls` never selects `Property__c` (0 matches). `reportTypes/NDAs.reportType-meta.xml` exposes 5 columns (`Status__c`, `Date_Sent__c`, `Date_Signed__c`, `NDA_Expiry_Date__c`, `Opportunity__c`) — **`Property__c` is not among them**. `Property__c`'s own layout carries no `NDAs` related list. |
| `NDA__c` has **zero validation rules** | `objects/NDA__c/validationRules/` does not exist |
| `NDA__c` is `Private` OWD with history tracking on, but `Property__c` has `trackHistory=false` | `NDA__c.object-meta.xml:149,165`; field file `:10` |
| Only **two** sharing rules exist on `NDA__c` and **both are scoped to `Disposition_NDA`** | `sharingRules/NDA__c.sharingRules-meta.xml:80-105`. **Acquisition NDAs have no sharing rule at all** — owner + role hierarchy only. |

⚠ **Consequence of "nothing reads it":** populating this field changes **nothing downstream today**. It is a
record-page display value. If the user's underlying want is *reporting* ("NDAs by property"), that needs
`reportTypes/NDAs` widened as well — **that is not in scope here and I have not designed it.** Ask.

### 1.2 🔴 The ordering question — answered

**Two creation paths reach `ensureNda`, and they behave oppositely.**

**Path 1 — lead conversion (the dominant path for this org's intake).**

```
Lead.IsConverted = true  →  Database.convertLead inserts the Opportunity
                         →  Opportunity AFTER INSERT  →  ensureNda  ← ❌ Property__c is NULL here
                         →  Lead AFTER UPDATE (same transaction, later)
                         →  LeadConvertService.stampConvertedOpportunities
                            → createProperties()          ← the Property__c ROW is created HERE
                            → buildOpportunityUpdates()   ← o.Property__c assigned HERE
                            → update updates              ← committed HERE
```

Evidence: `LeadConvertService.cls:308-314` (javadoc: *"Called from the Lead after-update trigger. For each
lead that just converted (and created an Opportunity)"*), `:321`, `:323`, `:324`, `:612-614`;
`OpportunityReviewTriggerHandler.cls:101-103,121`; `OpportunityReviewService.cls:639-642`.
`OpportunityReviewService.cls:41` independently confirms the entry point: *"`ensureNda` RUNS ON EVERY
Opportunity INSERT — including `Database.convertLead`"*.

🟡 **UNVERIFIED-IN-ORG** — this is trigger-ordering read from source. It is deterministic (a record cannot be
updated by its own converter's after-update trigger before it exists), but §7-P1 gives a one-query org probe
that settles it from live data, and it must be run before build.

**Path 2 — manual / API creation.** `Opportunity.Property__c` is on the classic layout
(`layouts/Opportunity-Opportunity Layout.layout-meta.xml`), so a user creating a deal by hand **can** set the
property on the create form, and an API/seed insert can too. For those, `Property__c` **is** present at after
insert and a creation-time stamp works.

**⇒ A creation-time stamp alone fixes Path 2 and leaves Path 1 exactly as broken as today.** Since Path 1 is
where the user's deals come from, that would look like a shipped fix that changed nothing — the worst outcome.

**⇒ The design must have two halves.** State this to the user in the user's own terms: *"populated once the
NDA record is created"* is achievable only for deals that already have a property; for a deal converted from a
Lead, the property is attached a few milliseconds later, so the NDA has to pick it up on that step too.

### 1.3 Lookup copy vs. formula — the trade is settled by a platform constraint, not by preference

The brief asks for a recommendation with the trade stated. **Recommend: keep the stored Lookup.** The reason
is not the usual drift-vs-editability argument; it is cheaper than that:

🔴 **Salesforce does not support an in-place field type change from Lookup to Formula.** Choosing "formula"
means **deleting `NDA__c.Property__c` and creating a new field under a different API name** (a deleted API
name stays reserved until the field is ERASED, not merely deleted). That cascades into:

1. `flexipages/NDA_Record_Page.flexipage-meta.xml:556` (`<fieldItem>Record.Property__c`) must be repointed —
   and this is the hand-edited page family covered by the FlexiPage-clobber risk;
2. `permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml:901-904` carries `<editable>true</editable>`,
   which **a formula field cannot accept — the permission set would fail to deploy**;
3. the field label "Property" would have to be duplicated or changed, and this repo has a recorded trap about
   duplicate field labels;
4. `deleteConstraint SetNull` and the `NDAs` relationship name (`referenceTo Property__c`,
   `relationshipName NDAs`) are lost — nothing uses them today, but they are the only structural link.

Against that, the formula's genuine advantages (cannot drift, needs no backfill, never blank when the parent
has one, self-heals the §1.2 ordering problem for free) are real but **all of them are also obtained by the
stored design in §1.4**, at the cost of one small trigger method. The one thing the formula gives that §1.4
does not is *impossibility of divergence*; the one thing it takes away is the ability for an NDA to point at a
different property than its deal.

**Alignment with the user's words:** the user asked for it *"populated"*, which reads as a stored value. The
recommendation matches that, so there is nothing to flag as a divergence. ✅

### 1.4 Recommended shape (two halves, both cheap)

> This is a *design*, not an instruction to write code. The implementing agent owns the layering
> (`.claude/rules/apex-layering-rule.md`) and must re-derive it.

**Half 1 — stamp at creation.** In `OpportunityReviewService.ensureNda`, carry `o.Property__c` alongside the
`oppIds` set and assign it on the new `NDA__c`. Today the method collects a `Set<Id>` (`:643-648`) and loops it
(`:664`); it needs a `Map<Id, Id> propertyByOpp` built in the *same existing loop* over `newOpps`. **Zero
additional SOQL, zero additional DML, no per-record describe.** Assign unconditionally including when null —
`DispositionStageEntryService.cls:732-737` argues exactly this for `Broker__c` and the argument transfers
verbatim (a `Map.get` miss returns null; null into a lookup on a new record is identical to leaving it unset,
so a guard adds a branch with no behavioural difference and one uncovered line). **Cite that comment; do not
re-derive it.**

**Half 2 — stamp when the deal's property is set (or changes).** An Opportunity **after-update** path,
change-keyed on `Property__c`, that pushes the value onto the deal's NDA(s).

- **Reuse the existing selector:** `NdaSelector.selectByOpportunityIds` already exists and is already called
  by `ensureNda` (`OpportunityReviewService.cls:654`). No new SOQL surface.
- **Cost:** exactly **one query + one DML per trigger chunk**, and **only when at least one Opportunity in the
  chunk actually changed `Property__c`** — otherwise the whole block returns before querying. That guard
  ordering is the budget, exactly as `DispositionStageEntryService.cls:716-721` argues for its own
  `resolveBrokers` placement.
- 🟢 **The re-entry cost is measured and it is near zero.** An `NDA__c` update re-enters:
  `NdaTrigger` (before insert/update only, `triggers/NdaTrigger.trigger:52`) → `NdaBuyerStampService`, which is
  **change-keyed on `Buyer__c`** and returns *"after ONE IN-MEMORY PASS with ZERO QUERIES AND ZERO DML"* when
  `Buyer__c` did not change (`NdaTrigger.trigger:21-27`); `NDA_Signed_Status_Sync`, a **before-save** flow
  (`flows/NDA_Signed_Status_Sync.flow-meta.xml:222-224`) — in-memory, no DML; `NDA_Signed_Rollup`, an
  after-save flow whose entry filter is **`Disposition__c` IS NOT NULL** (`:202-212`, `IsNull = false`) — so
  **acquisition NDAs never enter it**. ✅
- **Where it lives:** `OpportunityReviewTriggerHandler.route` (`:119-134`) already fans out to five service
  calls on both after contexts. This is a sixth. The handler is the established seam; do not add a second
  Opportunity trigger.

**Access level.** Use `Database.insert/update(..., true, AccessLevel.SYSTEM_MODE)` and **justify it at the
declaration**, per ARCHITECTURE.md §2. The justification is `NDA__c.Property__c`'s FLS matrix in §0.3: the
field is granted on **one** permission set, so any writer running as another persona hits *"a field the running
user cannot see is absent from the accessible schema"* — the exact mechanism named in the brief. Precedents to
cite rather than re-argue: `OpportunityReviewService.cls:583-590` (the LOI block) and
`DispositionStageEntryService.cls:745-756`.

🔴 **`SYSTEM_MODE` does not lift sharing, and that matters here specifically.** `NDA__c` is `Private`
(`NDA__c.object-meta.xml:165`) and acquisition NDAs are covered by **no sharing rule**
(`sharingRules/NDA__c.sharingRules-meta.xml` — both rules are `Disposition_NDA`-scoped, `:80-105`).
- Half 1 is **safe by construction**: the NDA is created in the same transaction by the same user.
- Half 2 is **not guaranteed**: a user who edits *someone else's* deal's `Property__c` may not have share
  access to that deal's NDA, and the update would fail. Decide the failure mode explicitly (§3-B2). Do **not**
  reach for `without sharing` to paper over it — that is a separate, separately-justified decision under
  ARCHITECTURE.md §2, and it is not obviously warranted for a display field.

### 1.5 Backfill

**Population:** 🟡 **I cannot count it — no org access.** §7-P2 gives the three counting queries. Structurally
it is *every acquisition NDA ever created*, because nothing has ever written this field.

**Safety — measured, and it is good:**
- `NDA__c` has **no validation rules** ⇒ nothing can refuse the save (this repo's #1 cause of "null after
  automation" does not apply here);
- re-entry cost is the §1.4 analysis: before-save trigger short-circuits on the change key, before-save flow is
  in-memory, the after-save rollup flow is not entered for acquisition NDAs;
- `Property__c` has `trackHistory=false` ⇒ **no `NDA__c` history rows are generated**, even though the object
  has `enableHistory=true`;
- no `ContentVersion`/`ContentNote` anywhere near this ⇒ `.claude/rules/content-publication-rule.md` does not
  apply;
- **no seed script sets `NDA__c.Property__c`** (sweep of `scripts/` found 14 `Property__c =` assignments across
  7 files, all on `Broker_Assignment__c` / `Lease_*` / `Work_Order__c` / asset repair — none on `NDA__c`), so
  re-running the seeds will not fight the backfill and the backfill will not be undone.

**Shape:** an anonymous-Apex script in `scripts/`, modelled on the existing precedent
`scripts/backfill-opp-ndas.apex` — same object family, same idempotent read-then-write structure, same "safe to
re-run" contract. Run it **as an administrator** (Modify All Data), which sidesteps the §1.4 sharing concern
for the historical rows.

⚠ **Sequencing:** run the backfill **after** Half 1 + Half 2 deploy, not before — otherwise every deal converted
between the two lands unstamped and needs a second run. Also remember `.claude/rules` note in the user's own
memory: anonymous Apex here has a **script size limit** and comments count toward it.

### 1.6 What I did *not* design (and why)

- ❌ Widening `reportTypes/NDAs` to expose `Property__c`. Not requested. Flagged in §1.1 as the probable
  unstated want.
- ❌ Adding `NDA__c.Property__c` to `DPEG_Acquisition_View` / `DPEG_Admin_Access`. Security decision → §3-D.
- ❌ Making the field required, or converting the lookup to Master-Detail. See §4.
- ❌ Touching the disposition NDA path. `DispositionStageEntryService.openBuyerNdas` creates NDAs with no
  `Opportunity__c` at all (`:728-738`); there is no Opportunity to read a property from. Out of scope → §3-C.

---

## §2 — ITEM B · the Dead/Pass off-ramp

### 2.1 🔴 The single most important finding: the route may already exist and be broken for a different reason

`Acquisitions_Deal_Path.pathAssistant-meta.xml:17-21` already carries:

```xml
<pathAssistantSteps>
    <fieldNames>Rejection_Reason__c</fieldNames>
    <info>Deal dropped at any stage. Rejection Reason is required. Broker protection is preserved for future re-engagement.</info>
    <picklistValueName>Dead/Pass</picklistValueName>
</pathAssistantSteps>
```

That is *precisely* the shape §2.3 says a new action would have to be built to achieve: reachable from any
stage, and it prompts for the Rejection Reason as its key field. **The Path is a viable route, and the honest
answer may be that no new action is needed.**

**Why the user probably cannot reach it — three candidate causes, in order of likelihood:**

**C1 — 🔴 The Path does not render on record-typed deals.** `Acquisitions_Deal_Path:51` is
`<recordTypeName>__MASTER__</recordTypeName>`, and a repo-wide sweep of `pathAssistants/` shows it is the
**only** `entityName>Opportunity` Path that exists. There is no `Acquisitions_Deal_Path_Land` and no
`_Retail`. Meanwhile every converted deal is stamped `Land` or `Retail`
(`LeadConvertService.cls:586-588, 612-646`), and since 2026-08-31 a blank Deal Type **defaults to Retail**
specifically so no deal lands untyped (`:615-646`, citing a live untyped deal `006iw000000fgpiAAA`).
The repo states the platform rule in its own words at `pathAssistants/NDA_Path.pathAssistant-meta.xml:17-19`:

> *"Once record types exist, a `__MASTER__` path renders for the Master type only — which after the row
> migration is NO ROWS."*

⇒ 🟡 If that holds for Opportunity as it did for `NDA__c`, `LOI__c` and `Contract_Review__c` (all three of which
were superseded by per-record-type files — `NDA_Path_Acquisition/_Disposition`, `LOI_Path_Acquisition/
_Disposition`, `Contract_Review_Path_Acquisition/_Disposition`), then **the user sees no Path at all on a Land
or Retail deal — not just no Dead step.** That is a far bigger defect than a missing button and it went
unreported because the highlights-panel buttons cover the forward hops.

**C2 — the custom permission, not the button.** All 8 wired actions carry
`AND {!$Permission.CustomPermission.Acquisition_Deal_Actions} EQUAL true`
(`Opportunity_Record_Page:19-22, 40-43, 61-64, 86-90, 102-106, 118-122, 134-138, 150-154`).
`Acquisition_Deal_Driver` is the **only** grantor (`Acquisition_Deal_Driver.permissionset-meta.xml:66`), and
its header states: *"AN ADMIN SMOKE TEST PROVES NOTHING ABOUT THIS GATE. A bare System Administrator does not
hold the `Acquisition_Deal_Actions` custom permission… Modify All Data is an OBJECT permission that confers no
custom-permission grant"* (`:78-81`).
⇒ **Discriminator to ask the user first, costs nothing:** *on the same record, can you see "Begin Review" /
"Initiate Underwriting" / "Advance to PSA"?* If **no**, the problem is the permission-set assignment and no
Dead action would have been visible either.

**C3 — the app.** `Opportunity_Record_Page` is assigned by **one** `actionOverride`, in
`applications/Acquisition.app-meta.xml:12-19`. No other app overrides Opportunity's View action. In the
Disposition / Transaction / Property Management apps the deal opens on the **object default page**, which has
neither these actions nor (necessarily) a Path component.
⇒ **Ask which app they were in.** *"I can't see it at any level"* is consistent with "not the Acquisition app".

🔴 **Do not build the button until C1/C2/C3 are discriminated (§7-P3/P4/P5).** Building it while C1 is true
ships a button and leaves the Path silently dead for all ten steps and all their guidance text.

### 2.2 The Apex is genuinely pre-authorised — confirmed against the current class

The brief asked me to confirm rather than trust the quote. Confirmed:

- `StageAdvanceService.ALLOWED_EXPLICIT_TARGETS` contains `'Dead/Pass'` — `StageAdvanceService.cls:112-117`.
- The header reason is present verbatim at `:93-97`: *"'Dead/Pass' — pre-authorized for the deal off-ramp
  action (design doc D4)… Listed here so the eventual button needs no service change; **nothing calls it with
  this value today**."*
- `advanceTo` validates the target against that set *before* loading the record (`:263-276`) and then
  `setStage` does `o.StageName = target; update o;` inside a `try` that surfaces the `DmlException`'s first
  message verbatim (`:286-300`).
- The controller entry point exists and is already documented for this target:
  `StageAdvanceController.advanceTo` (`:104-121`), javadoc at `:93-94` naming *"the pre-authorized Dead/Pass
  off-ramp"*.

🟢 **⇒ No `StageAdvanceService` change is required for the stage write itself.** Only the reason is missing.

### 2.3 🔴 The reason is mandatory, and `advanceTo` writes only `StageName`

`Rejection_Reason_Required_On_Dead` is **active** and fires on `OR(ISNEW(), ISCHANGED(StageName))` ∧
`ISPICKVAL(StageName,'Dead/Pass')` ∧ `ISBLANK(TEXT(Rejection_Reason__c))`
(`objects/Opportunity/validationRules/Rejection_Reason_Required_On_Dead.validationRule-meta.xml:53-62`).

`advanceTo` writes exactly one field. `OpportunitySelector.selectStageRequiredById` selects **`Id, StageName`
only** (`:634-642`), so `update o` sends a partial record.

**This is already proven in the suite, and the proof also gives us the working sequence.**
`StageAdvanceServiceTest.advanceToAcceptsEveryAllowedExplicitTarget` (`:315-383`) retracts an older "leave the
Dead leg bare" comment and now stamps the reason **in its own DML, before the advance** (`:362`), with the note
(`:356-359`):

> *"STAMPED IN ITS OWN DML, WITHOUT TOUCHING StageName, so this preparation cannot itself trip the rule (which
> is ISCHANGED(StageName)-gated). StageAdvanceService loads its own copy of the row, and its selector does not
> select this field, so `update o` sends a partial record and the value stamped here survives the advance."*

⇒ A bare one-click "Mark Dead" **will** fail, as the brief says. Two shapes work:

| | **Shape A — reason then advance (no Apex change)** | **Shape B — one service call, one DML** |
|---|---|---|
| Mechanism | ScreenAction LWC collects the reason → writes `Rejection_Reason__c` alone (LDS `updateRecord`, allowed: stage unchanged ⇒ the VR does not fire) → then calls the **existing** `StageAdvanceController.advanceTo(id,'Dead/Pass')` | ScreenAction LWC collects the reason → **one new** service/controller method writes both fields in a single `update` |
| Apex diff | **Zero.** Reuses the pre-authorised path exactly as the test proves it | New method + new controller method + `ALLOWED_EXPLICIT_TARGETS` unchanged |
| Transactions | **Two.** If the user abandons after step 1, a **live deal is left carrying a Rejection Reason** | One. Atomic. |
| Server-side gate | ✅ preserved (`OpportunityActionPermissionService.assertDealActionAccess()` in `advanceTo`, `StageAdvanceController.cls:107`) | Must be re-asserted in the new method — easy to forget, and the controller header explains at length why the client-side gate alone is worthless (`:25-32`) |
| Test cost | New Jest suite only; `StageAdvanceServiceTest` untouched | New Jest suite **+** new Apex tests **+** code review |
| FLS risk | LDS write of `Rejection_Reason__c`: granted editable **only** on `DPEG_Acquisition_Edit` (`:1297`), readable on `DPEG_Acquisition_View` (`:1316`) and `DPEG_Opportunity_View` (`:404`), **absent from `DPEG_Admin_Access`**. ⚠ Repo trap: `lightning-record-edit-form`/LDS FLS-checks *every* key in the payload and silently drops non-editable ones. | Same field, same matrix; a `SYSTEM_MODE` write would bypass it but should **not** be used — this is a write the user *asked for*, so a throw is a real provisioning report |

**Recommendation: Shape B**, on one ground — Shape A can strand a Rejection Reason on a live deal, which is
exactly the kind of half-state that later reads as data corruption. But this is close, and **Shape A is the
zero-Apex option**; if the user wants the smallest possible change, Shape A is defensible and its failure mode
is cosmetic. → **§3-F, user's call.**

### 2.4 The shape must be a ScreenAction — and "consistency with the existing eight" is *not achievable*

The brief says consistency with the existing eight matters more than elegance. Measured, the eight are all
**headless** one-clickers: `actionType Action` (`lwc/dealMoveToAboutToClose/dealMoveToAboutToClose.js-meta.xml:10`),
`type LightningWebComponent`, no UI (`quickActions/Opportunity.Move_to_About_to_Close.quickAction-meta.xml:2-8`).
**A Dead action structurally cannot be one of those** — it must capture a value first.

The closest in-repo family is the repo's **two existing `ScreenAction` quick actions**, and they are already
explicitly a family with a shared structure:
- `lwc/brokerReplaceQuickAction/brokerReplaceQuickAction.js-meta.xml:12`
- `lwc/dispositionOfferSelect/dispositionOfferSelect.js-meta.xml:12`, whose header says the structure
  *"(spinner → load error → 'nothing to select' branch → form) is pattern-matched to `c/brokerReplaceQuickAction`,
  the repo's other ScreenAction quick action"* (`dispositionOfferSelect.js:153-154`), and whose CSS repeats it
  (`dispositionOfferSelect.css:1-2`).

⚠ Both of those bundles carry a Jest suite that virtual-mocks `lightning/actions` because
**`CloseActionScreenEvent` has no `sfdx-lwc-jest` stub** — copied verbatim between them
(`__tests__/dispositionOfferSelect.test.js:85-93`). A third ScreenAction must copy the same mock; discovering
this at test-writing time costs an hour.

⚠ The ScreenAction panel is **narrow and not resizable by the component**
(`dispositionOfferSelect.css:126-132`). A single picklist + two buttons fits easily; do not add a summary table.

**⇒ Recommended shape:** one `QuickAction` `Opportunity.Mark_Dead` (`type LightningWebComponent`) + one LWC
bundle with `actionType ScreenAction`, structurally pattern-matched to `brokerReplaceQuickAction`, plus its
Jest + `@sa11y/jest` suite per ARCHITECTURE.md §5.

### 2.5 🔴 `Dead/Pass` vs `Dead%2FPass` — exactly where each form is required

Measured across the whole repo. Getting this backwards **fails at runtime, not at deploy** — a set or criterion
that silently never matches.

| Surface | Form | Evidence |
|---|---|---|
| `objects/Opportunity/businessProcesses/*.businessProcess-meta.xml` | **`Dead%2FPass`** ✅ ENCODED | `Land:33`, `Retail:40`, `Commercial:18` — the **only three** encoded occurrences in the repo |
| `objects/*/recordTypes/*.recordType-meta.xml` `<picklistValues>` | ENCODED **if it ever appears** — it does not for `StageName` (Opportunity stages come via `businessProcess`, not `picklistValues`) | `Retail.recordType:13` lists the 8 picklists enumerated there; `StageName` is not one |
| Apex literal / `Set<String>` member | **`Dead/Pass`** DECODED | `StageAdvanceService.cls:116`, and its own warning at `:99-101`: *"Values are the DECODED runtime/API strings… Getting this backwards yields a set that silently never matches."* |
| PathAssistant `<picklistValueName>` | **`Dead/Pass`** DECODED | `Acquisitions_Deal_Path:20` |
| Validation rule `ISPICKVAL(...)` | **`Dead/Pass`** DECODED | `Rejection_Reason_Required_On_Dead:58`, `Dead_Pass_Not_Allowed_From_Closed_Won:70` |
| FlexiPage `visibilityRule` `<rightValue>` | **`Dead/Pass`** DECODED | `StageAdvanceService.cls:100` states it in terms (*"an Apex literal (and a visibility rule's rightValue) uses the decoded form"*); the page's other stage criteria all use plain runtime strings (e.g. `Under Contract (PSA)`, `Opportunity_Record_Page:132`) |
| LWC JS constant / SOQL bind | **`Dead/Pass`** DECODED | same rule |
| Corroborating cross-reference | — | `pathAssistants/Delinquency_Path:12-15` cites this exact pair as its own precedent |

🟢 **Nothing this design adds needs the encoded form.** The quick action, the LWC constant, the FlexiPage
criterion and any test literal all use `'Dead/Pass'`.

### 2.6 Where the action appears, and under what rule

**Terminal exclusions are already enforced declaratively — do not rebuild them in the visibility rule's logic,
but do reflect them so the button never renders as a guaranteed error.**

- `Dead_Pass_Not_Allowed_From_Closed_Won` is **active** and blocks `Closed Won → Dead/Pass`
  (`:64-73`). Its header records that the user was shown the full consequence — *"Closed Won would become
  inescapable in the app, with no bypass permission and no self-service recovery route"* — and **reaffirmed the
  decision on 2026-08-30** (`:9-16`), plus *"NO BYPASS CUSTOM PERMISSION WAS ADDED. Do not add one to 'fix' the
  dead end"* (`:41-44`). ⇒ **The button must not render at `Closed Won`.** Rendering it there produces a
  button that errors 100% of the time — the exact failure the repo just avoided for `Close_Deal` at PSA
  (`StageAdvanceService.cls:149-169`).
- It must also not render at `Dead/Pass` itself.

**Rule form.** Every existing criterion on this page uses the `EQUAL` operator; **the repo contains no example
of a negated FlexiPage criterion.** Per this project's standing rule about unknown metadata shapes, do **not**
guess a `NOT EQUAL` token. Two options, in preference order:

1. ✅ **Positive enumeration** (proven form). The stage union across both business processes is
   `New, Under Review, Development Review (Land), Construction Review (Retail), Underwriting, LOI,
   Under Contract (PSA), About to Close, Closed Won, Dead/Pass` — measured from
   `businessProcesses/Land.businessProcess-meta.xml:24-59` (9 values, no Construction Review) and
   `Retail.businessProcess-meta.xml` (9 values, Construction Review instead of Development Review).
   Non-terminal = **8 stages**. Rule: `(1 OR 2 OR … OR 8) AND 9`. Precedent for the OR-then-AND shape:
   `Initiate_Underwriting` uses `(1 OR 2 OR 3) AND 4` (`Opportunity_Record_Page:70`).
   ⚠ **9 criteria is at the edge of the FlexiPage per-rule filter limit (10).** The implementing agent must
   confirm the limit at API 67.0 via the `sf-flexipage` skill before writing.
2. If (1) does not fit, the negated form must be **proven by a check-only dry-run plus an org readback of the
   rendered page**, never by a green deploy — this repo has a recorded FlexiPage incident where a component
   *"deploys green and renders nothing"*.

**Position in the list.** Last, after `Close_Deal`. It is an off-ramp; the eight forward hops should keep their
order. (The list order in `actionNames` is the render order.)

### 2.7 Should we build the button at all?

**Give the user the honest answer, which depends on §7-P3:**

- If **C1 is true** (Path is `__MASTER__`-only and renders nothing on Land/Retail deals): the *bigger* fix is
  restoring the Path per record type — `Acquisitions_Deal_Path_Land` + `Acquisitions_Deal_Path_Retail`, cloned
  from the existing file (which is the record of the guidance text, exactly as `NDA_Path` was retained for that
  purpose, `NDA_Path:12-15`), with the existing `__MASTER__` file **deactivated, not deleted**
  (`<active>false</active>`), following the precedent verbatim. ⚠ `recordTypeName` **cannot be re-pointed on an
  existing PathAssistant** — stated twice in this repo (`NDA_Path:7-8`, `LOI_Path_Acquisition:14`). That
  restores Dead/Pass **and** the nine other steps' guidance. A separate Dead button then becomes a *convenience*,
  not a fix.
- If **C2 or C3 is true**: no build at all — assign `Acquisition_Deal_Driver`, or use the Acquisition app.
- If the Path renders fine on Land/Retail deals and the user simply wants a one-click affordance beside the
  other eight: build §2.4.

---

## §3 — Open decisions that are genuinely the user's

| # | Decision | Why it is the user's, not mine | Default if unanswered |
|---|---|---|---|
| **A1** | Item A: should the NDA also pick up the property **when the deal's property is set later** (the lead-convert case)? | It is a scope expansion beyond the literal words *"populated once nda record is created"* — but without it the fix is inert for the deals the user is looking at (§0.1). | **Blocking. Do not proceed without an answer.** |
| **A2** | Should the NDA's property **track the deal forever** (re-stamp on every parent change) or **stamp once, only when blank**? | `NDA__c.Property__c` is *editable* for `DPEG_Acquisition_Edit` (`:903`), so a user can point an NDA at a different property. Re-stamping silently clobbers that; stamp-once lets a stale value persist. | Blocking |
| **B1** | Item B: after §7-P3, is the goal **restore the Path**, **add the button**, or **both**? | §2.7 — three materially different pieces of work with different blast radii. | **Blocking.** |
| **B2** | Half 2 failure mode: if the NDA update fails (sharing, §1.4), should the **Opportunity save roll back** (`allOrNone = true`, matching `OpportunityReviewService.cls:590` and `DispositionStageEntryService.cls:756`) or **degrade silently** (`allOrNone = false`)? | Fail-closed makes a display-field stamp able to block a deal edit. Fail-open reproduces the repo's own recorded "silent failure for non-owners" incident. Neither is obviously right for a display field. | Blocking |
| **C** | Backfill scope — **acquisition NDAs only** (those with `Opportunity__c != null`), or also attempt disposition NDAs? | Disposition NDAs have no Opportunity (`DispositionStageEntryService.cls:728-738`); sourcing a property for them is a different design. | Acquisition only (recommended) |
| **D** | FLS: extend `NDA__c.Property__c` **read** to `DPEG_Acquisition_View` (read-only Principal) and/or `DPEG_Admin_Access`? | §0.3. This is a security widening across a module-partitioned RBAC model, not a bug fix. `DPEG_Admin_Access` is the repo's stand-in for the Admin profile (`profiles/**` is force-ignored), so omitting it means administrators cannot see the field they just fixed. | Blocking |
| **E** | Is the real want *reporting* (`NDAs by property`)? If so `reportTypes/NDAs` needs `Property__c` added (§1.1) — **not designed here.** | Scope. | Ask |
| **F** | Item B: **Shape A (zero Apex, two transactions)** or **Shape B (one new method, atomic)**? (§2.3) | Trade is small-diff vs. no half-states. | Shape B (recommended) |
| **G** | Which stages show the Dead action (§2.6) — all 8 non-terminal, or a narrower set (e.g. not `New`)? | Business rule. | All 8 non-terminal |

---

## §4 — Things I think are bad ideas

1. 🔴 **Building the Dead button before running §7-P3.** If the Path is invisible on record-typed deals, you
   ship a button and leave nine other steps' guidance dead, and the user will report the *next* missing thing
   in a week.
2. 🔴 **Converting `NDA__c.Property__c` to a formula.** §1.3 — it is a delete + recreate under a new API name,
   it breaks `DPEG_Acquisition_Edit`'s `editable=true` at deploy, and it buys nothing §1.4 does not.
3. 🔴 **Re-pointing `Acquisitions_Deal_Path.recordTypeName` in place.** The repo says twice it cannot be done
   (`NDA_Path:7-8`, `LOI_Path_Acquisition:14`). Clone + deactivate.
4. 🔴 **Reaching for `WITH SYSTEM_MODE` or `without sharing` when the Half-2 NDA update fails.** SYSTEM_MODE is
   correct for the CRUD/FLS half and is already the design; it is **not** a sharing fix, and a `without sharing`
   inner class for a display field is not proportionate. Answer §3-B2 instead.
5. 🔴 **Adding a bypass custom permission so a Closed Won deal can be marked Dead.**
   `Dead_Pass_Not_Allowed_From_Closed_Won:41-44` forbids it in terms and names the decision gate it would
   re-open.
6. ⚠ **Making `NDA__c.Property__c` required.** A `required=true` on a *lookup* forces
   `deleteConstraint Restrict`, and the field is currently `SetNull` (`:4`). Separately, half the population
   (deals with no property) would become unsavable.
7. ⚠ **Reflexively widening `DPEG_Admin_Access`.** Check the permission set groups first — a persona may
   already be covered, and this repo has a recorded finding that the matrix is sometimes *narrower* than feared
   and widening is the wrong answer. Also: **a `PermissionSet` deploy replaces the file's entire
   `fieldPermissions` set** — the edit must be surgical and diffed against `HEAD`.
8. ⚠ **Any directory-wide deploy.** Another session has ~11,650 committed but never-compiled lines in this
   tree, and `git status` already shows 21 modified + 9 untracked files unrelated to this work. Deploy an
   explicit component list only.

---

## §5 — Test blast radius

⚠ **Two tests are RED by design and must not be folded in, fixed, or counted as regressions:**
`LoiGateTest.rejectionReturnsDealToUnderwriting` (`LoiGateTest.cls:65`) and
`LoiGateTest.firstResponseApprovalStampsLoiAuditTrail` (`:17`). Both confirmed present in the repo copy.

🔴 **Before running any of this, check the ORG's copy method-by-method (§7-P6).** This repo has twice had an
org test class whose method names differed from the repo's, passing vacuously — and a targeted `--tests` run
executes **the org's copy**, so a green result can mean "ran fewer methods than the repo has".

### 5.1 Item A — behaviour changes

| Class | Why it is in the blast radius | Expected |
|---|---|---|
| `OpportunityReviewServiceTest.ndaOpensOnNewOpportunity` (`:356`) | Directly asserts `ensureNda`'s output | Should pass; verify it does not assert field-by-field equality on the new `NDA__c` |
| `OpportunityReviewServiceTest.ensureNda_stampsTheAcquisitionRecordType` (`:401`) | Same insert | Should pass |
| `OpportunityReviewServiceTest.bulkCreate` (`:764-780`) | The existing 251-record bulk test for this method; its comment already names `ensureNda`'s cost (`:759`) | Must still pass **and** must be re-measured for query/DML headroom after Half 2 |
| `OpportunityReviewTriggerHandlerTest` (`:31`, `:51`) | Pins the after-insert → `ensureNda` and after-update → `createReviewRecords` routing; Half 2 adds a **sixth call to `route`** | Will need a new method for the new call |
| `NdaSelectorTest` (`:48`, `:77`, `:96`, `:101`) | Compensates for the auto-created NDA | Should pass |
| `NdaSignedStatusSyncTest` (`:240-244`) | Asserts `ensureNda` stamped a primary NDA as a **precondition** | Should pass |
| `NdaExpiryAlertBatchTest` (`:91`) | Same compensation | Should pass |
| `OpportunityDocStatusControllerTest` (`:20`) | Same | Should pass |
| `OpportunityApprovalServiceTest` (`:176`, `:781`) | Same; `:781` clears the stamped primary NDA | Should pass |
| `RecordStageAdvanceServiceTest` (`:329`), `RecordStageAdvanceControllerTest` (`:36`) | Delete the auto-created NDA | Should pass |
| `OpportunitySelectorTest` (`:303`) | Same | Should pass |
| `StageDelayAlertBatch` (`:178`) | Its header prices `ensureNda()` as *"the one unavoidable cost"* of the deals it updates — **Half 2 adds a second unavoidable cost to every Opportunity update** | 🔴 Re-price. This is the highest-risk governor interaction in the list. |
| **Every test that updates an Opportunity** | Half 2 adds a potential +1 SOQL / +1 DML per chunk on the after-update path | 🔴 Price against the heaviest chain: the Day-0 82-task fan-out reached via `ContractExecutionService.openTransactionsOnAboutToClose` (`OpportunityReviewTriggerHandler.cls:127`). The repo already has a recorded incident where routing a new parent into a trigger cost `ceil(rows/200)` SOQL **and** DML at production scale. |

**New tests required** (`.claude/rules/bulk-test-rule.md` — 251 records, no content-object exemption applies):
1. Half 1 — deal created **with** a property ⇒ NDA carries it.
2. Half 1 — deal created **without** a property ⇒ NDA's `Property__c` is null, deal still saves.
3. Half 2 — deal's `Property__c` set **after** the NDA exists ⇒ NDA picks it up. **This is the lead-convert
   case and is the test that actually proves the reported bug is fixed.**
4. Half 2 — an Opportunity update that does **not** touch `Property__c` ⇒ **zero queries, zero DML** from the
   new block (the governor-headroom assertion; assert on a counter captured inside the block, not on
   `Limits.getQueries()` after `Test.stopTest()`).
5. Bulk: 251 Opportunities inserted, and 251 updated with a property change.
6. `LeadConvertServiceTest` — an end-to-end conversion asserting the NDA ends up carrying the created Property.

⚠ **Fixture cost:** `TestDataFactory` does **not** set `Opportunity.Property__c` on any Opportunity it creates
(sweep of `TestDataFactory.cls` for `Property__c` — the only Opportunity-adjacent hits are the shared
`defaultProperty()` cache at `:382,397-398` and the `createProperties` family at `:1492-1520`). Tests 1, 3, 5
and 6 must link a property explicitly, or a helper must be added next to the existing named gate-helper family
(`signPrimaryNda` / `approveUnderwriting` / `placeApprovedLoi` / `signContract`, `TestDataFactory.cls:151-152`)
whose block comment says *"when the family changes, exactly one place should need editing"* — extend it, do not
patch call sites.

### 5.2 Item B — behaviour changes

| Class | Why | Expected |
|---|---|---|
| `StageAdvanceServiceTest.advanceToAcceptsEveryAllowedExplicitTarget` (`:315-383`) | **Already exercises `advanceTo(deadDeal.Id, 'Dead/Pass')` and asserts the decoded value saves** (`:368`, `:381-382`) | ✅ Unchanged under **Shape A** (zero Apex diff). Under **Shape B**, still unchanged — but a new test is needed for the new method. |
| `StageAdvanceControllerTest` | If Shape B adds a controller method | New method needed, **including a denial test** for `assertDealActionAccess`. ⚠ A `Standard User`-based denial test proves nothing here — the personas are on `Minimum Access`. |
| **No automated test covers** `flexipages/Opportunity_Record_Page`, `quickActions/Opportunity.*`, or any `pathAssistants/*` | There is no test harness for declarative metadata in this repo | 🔴 **The acceptance criterion for Item B is a browser check on the live record page, as the correct persona, in the Acquisition app — never a deploy result.** |
| New LWC bundle | ARCHITECTURE.md §5 | Jest suite + `@sa11y/jest` accessibility matcher. Must copy the `lightning/actions` virtual mock (`__tests__/dispositionOfferSelect.test.js:85-93`) — there is no `sfdx-lwc-jest` stub for `CloseActionScreenEvent`. |

---

## §6 — Sequencing and deploy gates

**G1 — answer §3-A1, B1, B2, D before any implementation agent is invoked.** They change the artefact list.

**G2 — run §7 probes P1-P5 first.** P3 in particular can eliminate Item B's build entirely.

**G3 — FlexiPage protocol (Item B only).** `Opportunity_Record_Page` is hand-edited in App Builder and a
deploy **replaces** the org copy with no version history. Retrieve it and diff against `HEAD` **seconds
before** deploying, and check `SetupAuditTrail` for saves newer than the last retrieve. Note `git status`
already shows this page's siblings modified in this working tree by a concurrent session.

**G4 — permission set protocol (if §3-D is yes).** A `PermissionSet` deploy replaces the file's **entire**
`fieldPermissions` set. Edit surgically, diff against `HEAD`, and deploy the permission set **before or with**
the Apex.

**G5 — deploy order for Item A:** permission set (if any) → Apex (`OpportunityReviewService`,
`OpportunityReviewTriggerHandler`, selectors) + tests → **then** the backfill script. Never the backfill first.

**G6 — deploy order for Item B:** if a Path is being restored, the two new `PathAssistant` files and the
`<active>false</active>` flip on the `__MASTER__` one go **together**. If a button is being added, Apex (if
any) must land **in the same wave or earlier** than the FlexiPage, never after.

**G7 — explicit component lists only.** No `--source-dir force-app`. See §4-8.

**G8 — MCP.** `.claude/rules/salesforce-global-rule.md` requires a `salesforce-api-context` attempt per
metadata type. That MCP server is **not configured in `.mcp.json`** for this project. Implementing agents must
record `mcp=unavailable`, `mcp_tools=none` after a real attempt and fall back to the per-type skill
(`sf-flexipage`, `sf-fragment`, the quick-action and path-assistant skills), plus empirical proof for anything
whose XML shape is not already exercised in this repo — specifically the §2.6 negated-criterion question.

---

## §7 — Org probes I could not run (this agent has no org access)

This agent's tool set is file-system only: Read / Write / Edit / Glob / Grep. **No `sf` CLI, no
`salesforce-api-context` MCP, no org connection.** The following must be executed by an agent that has them
(`salesforce-devops` or `salesforce-admin`) and the results pasted back **before** implementation starts.
Every one of them is cheap.

**P1 — 🔴 settles §1.2 (the Item A crux) from live data.** If the Property row was created *after* the NDA
row, the property demonstrably did not exist when the NDA was created:
```sql
SELECT Id, Name, CreatedDate,
       Opportunity__r.CreatedDate,
       Opportunity__r.Property__c,
       Opportunity__r.Property__r.CreatedDate
FROM NDA__c
WHERE Opportunity__c != null AND Opportunity__r.Property__c != null
ORDER BY CreatedDate DESC LIMIT 20
```
Expected if §1.2 holds: `Property__r.CreatedDate` ≥ `NDA.CreatedDate` on lead-converted deals.

**P2 — backfill population (§1.5).** Three counts:
```sql
SELECT COUNT() FROM NDA__c WHERE Opportunity__c != null
SELECT COUNT() FROM NDA__c WHERE Opportunity__c != null AND Property__c = null
SELECT COUNT() FROM NDA__c WHERE Opportunity__c != null AND Property__c = null AND Opportunity__r.Property__c != null
```
The third is the number the backfill can actually fix; the gap between #2 and #3 is deals with no property at
all, which the backfill cannot help and which §3-A2 governs.

**P3 — 🔴 settles §2.1-C1 (the Item B crux).** Which record types have a Path on Opportunity? Either
`sf project retrieve start --metadata PathAssistant` and list the returned files, or read
**Setup → Object Manager → Opportunity → Path Settings** and record the record type for each. ⚠ A retrieve of
`PathAssistant` is safe (it is not force-ignored), but **do not commit a retrieved `RecordType`** — a
RecordType retrieve strips picklist values.
Pair it with the population split:
```sql
SELECT RecordType.DeveloperName, COUNT(Id) FROM Opportunity GROUP BY RecordType.DeveloperName
```
If ~0 deals are on Master, C1 is confirmed and the Path is dead for practically everyone.

**P4 — settles §2.1-C2.** Ask the user, or:
```sql
SELECT Assignee.Name FROM PermissionSetAssignment
WHERE PermissionSet.Name = 'Acquisition_Deal_Driver'
```
and confirm the reporting user is in it.

**P5 — settles §2.1-C3.** Ask the user which app they were in when they looked.

**P6 — 🔴 test-class parity.** For each class in §5, compare the org's method list with the repo's. Tooling
API `SymbolTable` on `ApexClass`, or run each class and diff the reported method names against the repo file.
Specifically check `StageAdvanceServiceTest`, `OpportunityReviewServiceTest`,
`OpportunityReviewTriggerHandlerTest` and `LeadConvertServiceTest`.

**P7 — sanity, cheap.** Confirm `Rejection_Reason_Required_On_Dead` and
`Dead_Pass_Not_Allowed_From_Closed_Won` are `active = true` in the org, not just in the repo — a force-ignore
or a drifted org copy would change §2.3's whole premise.

---

## §8 — One-paragraph summary for the user

**Item A is real, and the fix is bigger than it looks in one specific way:** the NDA is created the instant the
Opportunity is inserted, but on a lead-converted deal the Property is attached a moment *later*, by a different
trigger. So "populate it at creation" on its own would store a blank and the field would still look empty. The
fix therefore needs two halves — stamp at creation (free, no extra queries) *and* stamp when the deal's Property
is set. Keep it as the stored lookup you have; turning it into a formula would mean deleting and re-creating the
field under a new name and would break a permission set at deploy. One thing to decide: today only **one**
permission set can see that field at all, so a read-only Principal and a bare administrator will still see
nothing after the fix. **Item B may not need a button.** The deal Path *already* has a Dead/Pass step that
already asks for the Rejection Reason — but that Path is configured for the "Master" record type only, and every
deal now gets Land or Retail, which means the Path probably renders nothing at all on your deals. That would
explain "I can't see dead at any level" far better than a missing button, and it would also mean nine other
stages have quietly lost their guidance. Please check one thing first: on the same deal, can you see "Begin
Review" or "Advance to PSA"? If not, the cause is a permission, not a missing feature.
