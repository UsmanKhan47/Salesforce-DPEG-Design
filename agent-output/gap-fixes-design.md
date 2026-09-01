# Design Requirements — E2E Gap Fixes (Gaps 1-4)

**Date:** 2026-08-31
**Source:** E2E test of Acquisition → Transaction on `usman-dpeg`, four gaps, user has chosen the resolution for each.
**Scope:** Requirements only. No metadata, no Apex written.

---

## 0. Tooling gate — MCP status (recorded, not fabricated)

```
intent=type | best_matched_skill=none (design stage, no metadata generated) | skill_selection=complete
mcp=unavailable | mcp_tools=none
```

A real attempt was made: **this agent's tool set is Read / Write / Edit / Glob / Grep only.** There is
no `salesforce-api-context` MCP server, no `sf` CLI, and no org access from the design stage. This
matches the standing finding in the user's memory (`api-context-mcp-not-configured`): `.mcp.json`
declares only the `salesforce` server and subagents receive no MCP tools at all.

**Consequence for the prompts below:** every item marked 🔵 ADMIN or 🟢 DEV must re-run the per-type
skill + MCP gate itself. Two shapes in this design were **not** confirmable from here and are called
out as gates rather than guessed: (a) whether a `CustomField` value-set edit and its dependent
`RecordType` `picklistValues` blocks resolve inside **one** deploy payload (§1.6), and (b) the
default `runInMode` of a before-save record-triggered Flow at API 67.0 (§2.5).

---

## 1. 🔴 PREMISES IN THE BRIEF THAT THE REPO CONTRADICTS

Read this section before the gap designs. Four of these change the work.

### C-1. `Transaction_Complete_Close` does **not** create the Property Asset

The brief says the flow "sets the Opportunity to Closed Won **and creates the Property Asset**."
`force-app/main/default/flows/Transaction_Complete_Close.flow-meta.xml` (98 lines, read in full) does
exactly three things and none of them is a Property Asset:

1. `recordUpdates/Close_Opportunity` → `$Record.Opportunity__r`: `Deal_Category__c='Closed'`,
   `Deal_Status__c='Asset Under Management'`, `StageName='Closed Won'`.
2. `actionCalls/Congratulate` → `GroupNotifier`, group `Acquisitions_Team`.
3. Nothing else. There is no `recordCreates` element in the file.

The Property Asset is minted **downstream**, by `PropertyAssetService.ensureOnClosedWon`, which runs
on `OpportunityReviewTrigger` — and `StageAdvanceService.NEXT_STAGE`'s own comment (lines 135-140)
says *why* it lives there rather than in this flow:

> 🔴 BOTH 'Under Contract (PSA)' AND 'About to Close' MAP TO 'Closed Won', AND THAT PAIR IS
> LOAD-BEARING OUTSIDE THIS CLASS. `PropertyAssetService.ensureOnClosedWon` lives on
> `OpportunityReviewTrigger` — rather than in the `Transaction_Complete_Close` flow — precisely
> because of it: **a deal driver can reach 'Closed Won' from EITHER key, so half the closes carry
> no `Transaction__c` at all.**

**Why it matters:** it means the Gap 2 chain is `Stage → Status → flow → Opportunity → trigger →
Property Asset`, i.e. **two** automation hops past the flow, not one. Anything that makes the flow
fire also fires the Property Asset trigger. See §2.6.

### C-2. Gap 3's "invisible handoff" is not merely invisible — the Path actively states the opposite

`force-app/main/default/pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml:37`, the
guidance text on the `Under Contract (PSA)` step, currently reads:

> "Seller issues the first PSA draft; a Contract Review opens automatically. Log every version and
> counter in the negotiation log. On full execution (Negotiation Status = Executed) **the Transaction
> is created, the 75-task fan-out fires**, and Transactions + IR + Due Diligence are notified."

Both bolded claims are false, and each is a separate gap:

- **"the Transaction is created"** — `ContractExecutionService`'s header, lines 34-38, says the
  opposite explicitly: *"Creating the Transaction MOVED out of `handleExecution` on 2026-08-05 (user
  decision) … Do not re-add Transaction creation to `handleExecution`."* The same retraction is
  written again at `RecordStageAdvanceService.cls:1198-1202`.
- **"75-task"** — Gap 4.

So Gap 3's user-facing surface already exists, is already the right place, and currently tells the
user the step they must perform has already happened automatically. **This collapses Gap 3 from
"design a new prompt" to "correct an existing false statement", which is why §3 recommends it over
every alternative.**

### C-3. There is a **competing button** at the same stage, and it skips the Transaction entirely

`flexipages/Opportunity_Record_Page.flexipage-meta.xml` shows the action bar at
`StageName = 'Under Contract (PSA)'` renders **two** relevant actions:

| Action | Visibility rule | Effect |
|---|---|---|
| `Opportunity.Move_to_About_to_Close` (`:126-140`) | `StageName EQUAL 'Under Contract (PSA)'` AND `Acquisition_Deal_Actions` | → `About to Close` → `ContractExecutionService.openTransactionsOnAboutToClose` → Transaction + 82-task fan-out |
| `Opportunity.Close_Deal` (`:141-161`) | `(StageName EQUAL 'Under Contract (PSA)' OR EQUAL 'About to Close')` AND `Acquisition_Deal_Actions` | → `Closed Won` **directly**, no Transaction, no fan-out |

`StageAdvanceService.NEXT_STAGE:160` confirms the shortcut is derivable, not exotic:
`'Under Contract (PSA)' => 'Closed Won'`.

**Why it matters:** "make the next step obvious" is under-specified against this. The real failure
mode is not a user who does nothing; it is a user who clicks the *adjacent* button and closes the
deal with no Transaction — the exact outcome `StageAdvanceService` already warns about. Any Gap 3
fix that only *adds* a hint, without saying something about `Close_Deal`, leaves that path open.
§3.4 raises this as an explicit open decision rather than designing around it.

### C-4. `Retail Strip`'s blast radius is much larger than "reports, list views, flows, Apex"

The brief's standing-rule sweep was run. **13 files, 30 occurrences** outside the two record types
and the field itself. Full inventory in §1.3. The two the brief did not anticipate:

- `scripts/seed-fsd-06-volume-pipeline.apex:75-86` holds an explicit **two-map translation layer**
  built solely because the value sets diverge (`'Retail Strip' => 'Retail'` for Property,
  `'Retail Strip' => 'Retail Strip'` for Opportunity). Aligning the sets makes both maps identity
  maps — this script's whole reason for existing partly evaporates.
- `data/opportunities.json` (4 rows) + `scripts/gen-data.mjs` + `scripts/gen-metadata.mjs:221`
  regenerate the divergence on the next org rebuild. `gen-metadata.mjs:221` hardcodes the six-value
  Opportunity list inline while lines 101 and 206 use a shared `ASSET` constant — that asymmetry
  *is* the origin of the divergence.

### C-5. Minor: `Transaction__c.Move_to_Closed_Won` quick action is named for the retired value

The file is `quickActions/Transaction__c.Move_to_Closed_Won.quickAction-meta.xml`; its `<label>` is
already `Closed` and its comment already documents the 2026-08-28 rename. Only the **file/API name**
is stale. This looks mid-change but is not: renaming a QuickAction API name is a delete+create that
would require repointing `flexipages/Transaction_Record_Page.flexipage-meta.xml`'s action list in the
same deploy, for zero functional gain. **Recommendation: leave it. Do not "tidy" it inside these
gaps.** Flagged only because the brief asked what looks mid-change.

---

## 2. 🚦 BLOCKING GATES — answer before any implementation agent starts

| # | Gate | Why it blocks | Owner |
|---|---|---|---|
| **G-1** | **Run `SELECT COUNT() FROM Opportunity WHERE Asset_Type__c = 'Retail Strip'` against `usman-dpeg`, and record the number.** | The entire rename-over-additive recommendation (§1.4) rests on this being **0**. The brief asserts 3 Opportunities all null; that must be *measured*, not carried forward, because `data/opportunities.json` seeds four `Retail Strip` rows and any org rebuild since the measurement reintroduces them. **If the count is > 0, stop and re-decide** — a Metadata-API value-set edit that drops `<fullName>Retail Strip</fullName>` is a **delete**, not a rename, and on a `restricted=true` picklist the surviving rows become unupdatable. | 🔵 admin / devops |
| **G-2** | **Confirm the target value set: 8 (match Lead) or 10 (match Property).** The user decision says *"align Opportunity to match Lead"* = 8. The brief's own prose then says Opportunity "lacks Hospitality, Medical Office, **C-Store and Storage**" = 10. | These are different deliverables. §1.2 recommends **8** and gives the reason; confirm before deploying, because adding a value later is cheap but removing one is another G-1. | 👤 user |
| **G-3** | **Confirm that `Stage__c = 'Closed'` ⇒ `Status__c = 'Closed'` is intended to apply to `INSERT` as well as `UPDATE`.** | Two seed scripts insert `Status__c='Active'` **with** `Stage__c='Closed'` in the same row (§2.6). An insert-and-update rule flips them; an update-only rule leaves them inconsistent. Recommendation: **both**, see §2.3. | 👤 user |
| **G-4** | **Does `Retail_Strip` appear in any org-only artifact the repo cannot see?** Specifically: dashboard filters, Einstein/report subscriptions, and `Transaction_Task_Def__mdt` / any `__mdt` rows — `**/customMetadata/**` is force-ignored (`.forceignore:16`) so **no CMDT row is in this repo at all**. | The standing rule is "grep the repo **AND** query the org". Only half is done. | 🔵 admin |
| **G-5** | **Retrieve-and-diff `pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml` from the org immediately before deploying §3.** | Same clobber class as the FlexiPage incident: a PathAssistant deploy replaces the org copy, guidance text is editable in Setup, and there is no version history. Cheaper than the FlexiPage case but the same failure. | 🔴 devops |

---

## 3. GAP 1 — `Opportunity.Asset_Type__c` alignment + conversion carry-over

### 1.1 Measured state (repo, verified — matches the brief exactly)

| Field | File | Values |
|---|---|---|
| `Lead.Asset_Type__c` | `objects/Lead/fields/Asset_Type__c.field-meta.xml` | Retail, Land, Industrial, Office, Multifamily, Mixed-Use, Hospitality, Medical Office (**8**), `restricted=true` |
| `Property__c.Asset_Type__c` | `objects/Property__c/fields/Asset_Type__c.field-meta.xml` | + C-Store, Storage (**10**), `restricted=true` |
| `Opportunity.Asset_Type__c` | `objects/Opportunity/fields/Asset_Type__c.field-meta.xml` | Retail **Strip**, Office, Industrial, Land, Multifamily, Mixed-Use (**6**), `restricted=true` |

Both Opportunity record types carry an `Asset_Type__c` `picklistValues` block with the same 6 values:
`recordTypes/Retail.recordType-meta.xml:39-65`, `recordTypes/Land.recordType-meta.xml:7-33`.
**Structural count verified:** each file has 10 `<picklist>` blocks and 47 `<values>` entries
(`Land.recordType-meta.xml` greps to 58 total `<picklist>|<fullName>` = 10 + 47 + 1 root). The brief's
Wave B measurement holds; any edit must preserve all ten blocks and change only the `Asset_Type__c`
one.

### 1.2 Target value set — recommend **8, matching Lead** (G-2)

Match Lead, not Property. Reasons:

- The only writer being added is **Lead → Opportunity**. A Lead can never carry `C-Store` or
  `Storage`; they are not on `Lead.Asset_Type__c`. Adding them to Opportunity would create two values
  no automation can ever produce.
- Nothing copies Opportunity → Property. `LeadConvertService:781` writes Property **from the Lead**,
  and `PropertyAssetService` (header `:43`) maps `Property__r.Asset_Type__c` → `Property_Type__c`
  through an allow-list. Property's extra two values serve the PM/asset side and have no acquisition
  counterpart.
- Lead ⊂ Property (8 ⊂ 10) already holds, so the Lead → Property write stays total.

Resulting Opportunity set (order = Lead's order, so a future diff of the three files is readable):
`Retail, Land, Industrial, Office, Multifamily, Mixed-Use, Hospitality, Medical Office`.

### 1.3 Full `Retail Strip` sweep — 13 files, 30 occurrences

Run per the standing rule (`picklist-removal-sweep-rule`). Grouped by what happens if missed.

**A. Must change — the value set itself (3 files, deploy together, §1.6)**

| File | Lines |
|---|---|
| `force-app/main/default/objects/Opportunity/fields/Asset_Type__c.field-meta.xml` | 13-17 (`<fullName>` + `<label>`) |
| `force-app/main/default/objects/Opportunity/recordTypes/Retail.recordType-meta.xml` | 61-64 |
| `force-app/main/default/objects/Opportunity/recordTypes/Land.recordType-meta.xml` | 29-32 |

**B. Must change — Apex that would break at compile-check or assert (2 files)**

| File | Line | Note |
|---|---|---|
| `classes/TestDataFactory.cls` | 828-829 | The literal **and** the comment above it, which documents the divergence being removed. `createOpportunities` is the factory nearly every Opportunity test uses — a stale literal here is refused by DML on a restricted picklist and reds a wide swathe of the suite. |
| `classes/OpportunityFunnelControllerTest.cls` | 119 | `assertEquals('Retail Strip', top.assetType, …)` — flips to `'Retail'`. |

**C. Must change — seed / generator scripts (`retirement-checklist` item 1: these RESURRECT it)**

| File | Line(s) | Note |
|---|---|---|
| `scripts/gen-metadata.mjs` | 221 | 🔴 **The root cause.** Lines 101 and 206 build Lead's and Property's `Asset_Type__c` from a shared `ASSET` constant; line 221 hardcodes the six-value Opportunity list inline. Point it at `ASSET` (or the 8-value subset) or the divergence regenerates. |
| `scripts/gen-data.mjs` | 25, 26, 27, 32 | Row literals; also line 42 does `d[3].split(' ')[0]` to derive the Property value from `'Retail Strip'` → `'Retail'`. **That `.split()` becomes a no-op and should be removed, not left**, or it silently truncates any future two-word value (`Medical Office` → `Medical`). |
| `data/opportunities.json` | 13, 32, 51, 146 | 4 rows. |
| `scripts/seed-deal.apex` | 12 | |
| `scripts/seed-fsd-06-volume-pipeline.apex` | 29, 34, 43, 47, 52, 57, 62, 64, 66, and the two maps at 75-86 | Both maps become identity maps; the comment at 75-83 explaining the divergence becomes false and must be retracted, not deleted. |
| `scripts/seed-fsd-07-portfolio-deal.apex` | 30, 31, 32 | **Prose only** — inside an email-body string literal describing properties. Cosmetic; changing it is optional but keeps a grep clean. |

**D. Must NOT change — value-agnostic readers, listed so nobody "fixes" them**

- **12 Opportunity list views** (`objects/Opportunity/listViews/*`) reference `Asset_Type__c` **as a
  `<columns>` entry only**. Verified: no `<filters>` anywhere in the repo compares to `Retail Strip`.
- **2 reports** — `reports/Acquisitions/Deal_Status_Breakdown.report-meta.xml:337` and
  `reports/Acquisitions/Active_Deals_by_Asset_Type.report-meta.xml:19` — reference the field, not the
  value. Grouping labels will re-render as `Retail`. (Standing warning still applies: reports do not
  block a picklist change and would have failed silently if they *had* filtered on it.)
- **3 formula fields** pass the value through unchanged and need no redeploy:
  `Contract_Review__c.Asset_Type__c`, `Construction_Feasibility_Review__c.Asset_Type__c`,
  `Development_Feasibility_Review__c.Asset_Type__c`, all `TEXT(Opportunity__r.Asset_Type__c)`.
  ⚠ Their **output** changes for any row whose parent holds `Retail Strip` — which is G-1 again.
- **`flexipages/Opportunity_Record_Page.flexipage-meta.xml:1126, 1250`** and
  `layouts/Opportunity-Opportunity Layout.layout-meta.xml:67` — field placement, no value literal.
  **Do not open the FlexiPage for this gap.** Nothing in Gap 1 requires it.
- **`permissionsets/DPEG_Acquisition_View|Edit`, `DPEG_Opportunity_View`** already grant
  `Opportunity.Asset_Type__c`. **No FLS work.** Adding values to an existing field does not change
  field permissions.
- **`profiles/**`** — 40+ hits, all force-ignored (`.forceignore:28`). Never deploy, never reconcile.
  Ignore entirely.
- **`.superpowers/sdd/*.md`** and `manifest/package.xml` — briefs and a manifest member list. No value
  literals for Opportunity.

### 1.4 Rename vs. add-and-retire — **recommend rename**, conditional on G-1

The project's stance is additive-never-rename. **This case should be the exception, and here is the
argument rather than the assertion.**

The additive rule protects two things: (i) **data** that holds the old value, and (ii) **readers**
that compare against the literal. Neither is present:

- **Data:** zero rows, *if* G-1 confirms. This is the whole conditional.
- **Readers:** every value-agnostic reader is in list D above. Every literal comparison is in list B
  or C — files we are editing anyway, all of them ours.

Add-and-retire is actively **worse** here, not merely more expensive:

1. It leaves `Retail` and `Retail Strip` both active on a restricted picklist that already has a
   describe-based allow-list reading it (`LeadConvertService.activePicklistValues`). That helper would
   accept **either**, so a hand-entered `Retail Strip` stays reachable forever and the funnel keeps
   reporting two asset types for one thing — the exact defect Gap 1 exists to close.
2. Deactivating rather than deleting leaves the value visible as a historical grouping in
   `Active_Deals_by_Asset_Type`, which is a report about asset types.
3. There is no migration to stage, so the additive pattern's three phases (add → backfill → repoint →
   retire) degenerate to (add → retire) with nothing in between.

⚠ **What "rename" actually means at the API layer, stated so nobody is surprised:** the Metadata API
keys a picklist value on `<fullName>`. Deploying a value set without `Retail Strip` and with `Retail`
is a **delete plus a create**, not a rename. That is exactly why G-1 is a hard gate and not advice.
This is a *value* rename inside a value set, so the `api-name-rename-is-delete-create` "name stays
reserved until ERASED" trap does not apply — but the delete semantics do.

### 1.5 🔴 THE HIGHEST-VALUE FINDING IN THIS GAP — the carry-over guard is record-type-blind

`LeadConvertService.applyDealFields` already has an established, self-documented pattern for exactly
this write (`:604-613`):

```apex
// Restricted picklists — see the class header. An unknown value is DROPPED, never pushed.
o.Sale_Process__c   = picklistValueOrNull(l.Sale_Process__c,   saleProcessValues());
o.Parse_Confidence__c = picklistValueOrNull(l.Parse_Confidence__c, parseConfidenceValues());
o.Listing_Status__c = picklistValueOrNull(l.Listing_Status__c, listingStatusValues());
```

backed by `activePicklistValues(Schema.SObjectField)` (`:1106-1114`), which reads
`field.getDescribe().getPicklistValues()`.

**A field describe is blind to the record-type subset.** This is measured, twice, in the user's own
memory (`restricted-picklist-is-enforced-by-dml`, four instances; `record-type-subset-breaks-seeds`,
2026-08-29): a value active on the master value set but absent from the record type is **refused at
the DML layer** with `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`.

Why this has not bitten yet, and why Asset_Type__c is different: **`Sale_Process__c`,
`Parse_Confidence__c` and `Listing_Status__c` have no `picklistValues` block in either record type
file** (verified — the ten blocks are `Asset_Type__c`, `Deal_Category__c`, `Deal_Status__c`,
`Deal_Type__c`, `ForecastCategoryName`, `LeadSource`, `Offer_Status__c`, `Rejection_Reason__c`,
`Type`, `Underwriting_Status__c`). They are unconstrained by record type, so the describe guard is
sufficient. **`Asset_Type__c` is the first guarded picklist in this class whose record-type subset is
a real constraint.**

Concretely, if the field gains `Hospitality` but the record types do not:

1. A Hospitality Lead converts. `activePicklistValues` sees `Hospitality` active → guard **passes**.
2. `o.Asset_Type__c = 'Hospitality'` on a `Retail`-typed Opportunity.
3. `update updates` is **all-or-none by design** (class header `:150-158`).
4. DML refuses → **the entire chunk's stamping rolls back**: `RecordTypeId`, `Property__c` link,
   `Lead_Approved_By__c`, `Broker__c`, every field, **for every Lead in that chunk**, not just the
   Hospitality one. The class header says this is precisely the failure mode the guard exists to
   prevent, and the guard cannot see it.

⇒ **The record types are not optional and not a nicety. They are the fix.** This is the concrete
mechanism behind the user's "record types MUST deploy BEFORE any dependent Apex" constraint.

**Should the guard be hardened to be record-type-aware?** No — not in this change. It would mean a
`getRecordTypeInfos()`-based describe per record type, threading `RecordTypeId` into
`applyDealFields`, and it would trade a loud rollback for a silent drop on a field the user has just
asked to be populated. Keeping the sets in lockstep is the correct control. **But a comment saying
so belongs at `activePicklistValues`**, because the next person to add a record-type-restricted
picklist to this class will not re-derive it. Included in the DEV prompt.

### 1.6 Deploy order

```
STEP 1  ── ONE deploy payload, all three files together ──
        objects/Opportunity/fields/Asset_Type__c.field-meta.xml      (6 -> 8 values, Retail Strip -> Retail)
        objects/Opportunity/recordTypes/Retail.recordType-meta.xml   (Asset_Type__c block only)
        objects/Opportunity/recordTypes/Land.recordType-meta.xml     (Asset_Type__c block only)

        WHY ONE PAYLOAD: split it either way and it fails.
          field first  -> the org's record types still reference a value that no longer exists
          RT first     -> the RT references 'Retail'/'Hospitality'/'Medical Office' before the field offers them
        The Metadata API deploys CustomField ahead of RecordType within a single payload.
        ⚠ NOT CONFIRMABLE FROM HERE (mcp=unavailable). Prove it with a --dry-run first;
          if the dry-run rejects it, fall back to: deploy the field with BOTH old and new values,
          then the record types, then the field with the old value removed. Three deploys, same end state.

STEP 2  ── verification, before any Apex ──
        REST describe (NOT a retrieve — a retrieve UNIONS local and remote picklist values and
        would show 'Retail Strip' restored whether or not it was; see `retrieve-merges-picklist-values`).
        Then read objects/Opportunity/recordTypes/*.recordType-meta.xml back from the REPO, not the org
        — a RecordType retrieve STRIPS picklistValues entirely (`recordtype-retrieve-strips-picklist-values`),
        so the repo file is the sole record. DO NOT commit a "sync from org" of these two files.
        Confirm 10 blocks / 47 values each, unchanged except the Asset_Type__c block.

STEP 3  ── Apex + tests + seeds ──
        classes/LeadConvertService.cls        (the carry-over)
        classes/TestDataFactory.cls           (:828-829)
        classes/OpportunityFunnelControllerTest.cls (:119)
        classes/LeadConvertServiceTest.cls    (new coverage, see DEV prompt)

STEP 4  ── non-deployed assets, any time after step 1 ──
        scripts/gen-metadata.mjs, scripts/gen-data.mjs, data/opportunities.json,
        scripts/seed-deal.apex, scripts/seed-fsd-06-volume-pipeline.apex, scripts/seed-fsd-07-portfolio-deal.apex
```

### 1.7 What happens on drift (the brief asked explicitly)

**Once aligned: nothing.** Lead's 8 ⊆ Opportunity's 8, so every Lead value is legal.

**If they drift again** — say someone adds `Data Center` to Lead only — the behaviour is already
decided by the existing helper and needs no new design:
`picklistValueOrNull` returns `null`, the Opportunity field is left blank, the conversion succeeds,
and **nothing is logged**. The header states this as the intended contract: *"An unknown value is
DROPPED, never pushed."*

Say plainly what that costs: **the exact symptom of Gap 1 returns, silently, for that value.** The
funnel reports a null asset type and no error appears anywhere. The mitigation is not code — it is
the three-file lockstep and the note at §1.5.

⚠ **And the dangerous drift is the other direction:** a value added to the *field* but not to the
*record types* is NOT dropped — it passes the guard and rolls back the whole chunk (§1.5). Drift on
the field is soft; drift on the record type is hard.

---

## 4. GAP 2 — `Transaction__c.Status__c` has no writer

### 2.1 Measured state

| | |
|---|---|
| `Transaction__c.Stage__c` | `Open Contract` (default) · `Due Diligence` · `Closing Prep` · `Post-Closing` · `Closed` — `restricted=true` |
| `Transaction__c.Status__c` | `Draft` (default) · `Active` · `Closed` — `restricted=true` |
| Record types | **None.** `objects/Transaction__c/` has no `recordTypes/` folder. |
| Validation rules | **None.** No `validationRules/` folder. Confirmed independently by the quick action's own comment. |
| Trigger | **None.** `triggers/` has 11 triggers; no `TransactionTrigger`. |

### 2.2 Every reader and writer of both fields (the brief asked explicitly, and this repo has a recorded incident here)

**Writers of `Status__c` — production:** exactly one.
`ContractExecutionService.cls:342` sets `Status__c='Active'` at Transaction creation (alongside
`Stage__c='Open Contract'`). **Nothing anywhere writes `'Closed'` or `'Draft'`.** So the field is
genuinely half-alive: born `Active`, never advanced. Gap 2 supplies the missing terminal write.

**Writers of `Status__c` — non-production:**
- `scripts/verify-junior-lifecycle.apex:115` — `update new Transaction__c(Id = txn.Id, Status__c = 'Closed');`
  ⇒ **this is the manual workaround from the E2E test, already committed as a script line.** After
  Gap 2 it becomes dead (it sets Status without moving Stage, producing the inverse inconsistency).
  Should be replaced by a Stage write. Listed in the ADMIN/DEV prompts.
- `scripts/seed-transactions.apex` (5 rows), `scripts/seed-transactions-nondestructive.apex` (5 rows),
  `TaskFanoutServiceTest`, `TransactionSelectorTest`, `TransactionControllerTest`, `TestDataFactory`.

**Writers of `Stage__c`:** `ContractExecutionService:343` (creation only) and
`RecordStageAdvanceService.setStage` (`:2457-2477`) driven by four quick actions
(`Move_to_Due_Diligence`, `…Closing_Prep`, `…Post_Closing`, `…Closed_Won`) via the
`advanceRecordStage` LWC. Plus seeds.

**Readers keyed on `Status__c`:**
- `flows/Transaction_Complete_Close` — `Status__c EqualTo 'Closed'` **AND** `Opportunity__c IsNull
  false`, `RecordAfterSave`, `CreateAndUpdate`, `doesRequireRecordChangedToMeetCriteria=true`.
- `TransactionSelector.STATUS_ACTIVE = 'Active'` — used in **four** queries (`:132/152`, `:168`,
  `:220`). These back the Active-Transactions KPI tile, `transactionKpis`, `activeTransactionsList`
  and the Transaction dashboard.
- `TransactionController.cls:51` — `Boolean isActive = (t.Status__c == 'Active');`
- `scripts/fanout-seeded-transactions.apex:43` — `WHERE Status__c = 'Active'`.

**Readers keyed on `Stage__c`:** `RecordStageAdvanceService.TRANSACTION_NEXT_STAGE`, the Transaction
Path, and the four quick actions' FlexiPage visibility rules. **Nothing else.** No flow, no VR, no
formula, no report filter keys on `Stage__c`. (`Risk__c` separately carries a `'Closed'` value in
seeds — a third field, unrelated, do not conflate.)

⚠ **The shared-terminal-value hazard, checked and cleared.** `Status__c='Closed'` and
`Stage__c='Closed'` are two different fields that coincidentally share a string, and
`TransactionControllerTest:116-119` and `:160-162` already carry warning comments saying so. This is
the same shape as the incident in `shared-terminal-value-splits`. **Here it is safe, because the two
readers are disjoint** — every `Status__c` reader filters on the field name, not the string, and the
one place they meet (`TransactionControllerTest`) is a test that pins the distinction. Gap 2 makes
the coincidence *causal*, which is the user's stated intent — but it means those two test comments
become misleading and must be updated in the same change (they currently say the values are
unrelated).

### 2.3 🔵 RECOMMENDED: a before-save record-triggered Flow

**Component:** `force-app/main/default/flows/Transaction_Stage_Closed_Sets_Status.flow-meta.xml` (new)

| Property | Value |
|---|---|
| `processType` | `AutoLaunchedFlow` |
| `triggerType` | `RecordBeforeSave` |
| `recordTriggerType` | `CreateAndUpdate` (per G-3) |
| `object` | `Transaction__c` |
| Entry criteria | `Stage__c EqualTo 'Closed'` |
| `doesRequireRecordChangedToMeetCriteria` | `true` |
| Action | one `assignments` element: `$Record.Status__c` = `'Closed'` |
| `status` | `Active` |
| `apiVersion` | `67.0` |

**Why before-save, over every alternative:**

| Option | Verdict |
|---|---|
| **Before-save Flow** ✅ | Zero DML, zero SOQL, zero recursion risk. Runs for **every** writer — the quick action, an inline Path edit, the API, a data loader, a seed script — which is the property Gap 2 needs, since `RecordStageAdvanceService` is not the only writer. No new automation *surface* on `Transaction__c` (a flow already exists on this object). Declarative ⇒ 🔵 admin, no test class, no code review round-trip. |
| Add a Transaction branch to `RecordStageAdvanceService.setStage` ❌ | `setStage` (`:2457-2477`) is **deliberately generic** — it writes `config.stageField` and nothing else, for **eight** objects. An `if (objectType == Transaction__c…)` there is the first object-specific special case in a dispatcher whose entire design argument (see `passesGate`'s comment at `:2413-2417`) is that per-object behaviour must not be flattened into shared code. It also only covers the button, missing the Path and the API. |
| New `TransactionTrigger` + `TransactionTriggerHandler` ❌ | Correct by ARCHITECTURE §2 if a trigger were needed, but it is not. Cost: a new trigger + handler + test class + a **251-record bulk test** (`bulk-test-rule`) on the one object that fans out **82 Tasks each** — 251 × 82 = 20,582 rows. And it opens a new automation surface on the object whose trigger cascade already has a recorded incident (`trigger-cascade-on-bulk-insert`). Enormously more expensive for a one-field assignment. |
| Change the flow's trigger condition to `Stage__c` ❌ | **The user explicitly forbade this.** Also correct to forbid: `Status__c` is the coarse state that `TransactionSelector` and the whole Active-KPI surface read; repointing the close trigger to `Stage__c` would leave `Status__c` permanently unwritten and the KPIs permanently wrong. |
| A formula field ❌ | `Status__c` is a writable restricted picklist that `ContractExecutionService` sets to `'Active'`. Converting it to a formula is a stored→formula change — a suite-wide compile break plus loss of the `'Active'` write. |

### 2.4 Naming check against ARCHITECTURE §1

No new fields. `Stage__c` (lifecycle → Path) and `Status__c` (current state) already match the
documented convention exactly; this gap makes the relationship between them real rather than
aspirational, which is the convention working as intended.

### 2.5 ⚠ One shape to confirm (mcp=unavailable)

The Flow's `<runInMode>`. The user's memory (`flow-runinmode-runs-as-approver`) records an incident
where an absent `<runInMode>` meant **user context**. **Empirically that is probably not a problem
here:** a before-save flow's assignment mutates the in-flight record and performs no DML, so CRUD/FLS
on a `recordUpdate` never enters the picture — and the sibling `Transaction_Complete_Close` also
omits `<runInMode>` and successfully updates a parent Opportunity today. **But confirm it, do not
assume:** deploy, then have a real `DPEG_Transaction_Team` persona (not an admin) advance a
Transaction to `Closed` and read `Status__c` back. Deploy success is not proof.

### 2.6 🔴 Behaviour changes this causes — the honest list

**(a) Two seed scripts insert a row that this flow will change.**

`scripts/seed-transactions.apex:68-74` and `scripts/seed-transactions-nondestructive.apex:83-89`
insert *"Pasadena Industrial"* with `Status__c='Active'` **and** `Stage__c='Closed'` in the same row.
With the flow live and `recordTriggerType=CreateAndUpdate`, that row is inserted as `Closed`.

Consequences, traced through:
- `scripts/fanout-seeded-transactions.apex:43` (`WHERE Status__c='Active'`) loses that row → it never
  gets its 82-task fan-out. **Probably correct** (it is a closed deal) but it is a change.
- The Active-Transactions KPI drops 5 → 4. `seed-transactions.apex:77` then prints *"Inserted 5
  active transactions"*, which becomes a lie. Cosmetic but it is exactly how a wrong count hides.
- 🟢 **`Transaction_Complete_Close` does NOT fire on this row** — its second filter is `Opportunity__c
  IsNull false`, and neither seed row sets `Opportunity__c`. So the C-1 chain (Opportunity → Closed
  Won → `PropertyAssetService.ensureOnClosedWon` → a new Property Asset) is **blocked for these
  two seeds**. Verified, and it is the only reason (a) is a minor issue rather than a serious one.

  🔴 **But that protection is incidental, not designed.** Any future seed or fixture that inserts
  `Stage__c='Closed'` **with** an `Opportunity__c` will, from the moment this flow deploys, close the
  parent Opportunity, mint a Property Asset, and post a Chatter congratulation to `Acquisitions_Team`
  — on insert. Anyone writing a Transaction fixture must know this. It belongs in the flow's
  `<description>` and in `TestDataFactory.createTransaction`'s Javadoc.

**(b) The real production path gets longer, correctly.**
Today: `Post-Closing` → click *Closed* → `Stage__c='Closed'`, nothing else.
After: same click also sets `Status__c='Closed'` → the after-save flow fires → parent Opportunity to
`Closed Won` / `Asset Under Management` / `Deal_Category__c='Closed'` → `OpportunityReviewTrigger` →
`PropertyAssetService.ensureOnClosedWon` mints the Property Asset → `GroupNotifier` posts to
`Acquisitions_Team`. **That is the intended end-to-end close, and it is what the E2E test had to do
by hand.** It is also four automation hops behind one button click, all inside the user's
transaction. Worth a smoke test at volume, not just single-record.

⚠ `GroupNotifier`'s recipient is a **public group**, and group membership is not deployable
(`alerting-and-email-inventory`, `groupnotifier-is-acquisitions-branded`). If `Acquisitions_Team` is
empty in `usman-dpeg`, step 5 silently notifies nobody and the E2E will look like it worked. Not in
scope to fix; flagged so the acceptance test does not assert on it.

**(c) Tests to review** (not necessarily change):
- `TransactionControllerTest.cls:116-122` and `:160-165` — already set `Status='Closed'` +
  `Stage='Closed'`, so they still pass. **Their comments become wrong** and must be updated.
- `TransactionControllerTest.cls:158` — `Status='Active'`, `Stage='Post-Closing'`: unaffected.
- `TransactionSelectorTest`, `TaskFanoutServiceTest`, `TestDataFactory.createTransaction` — none sets
  `Stage__c='Closed'`; unaffected. **Verify by grep before deploying, not by assumption** — the
  authoritative check is `Stage__c` = `'Closed'` on `Transaction__c`, which today returns exactly the
  five hits listed in §2.2.

**(d) `scripts/verify-junior-lifecycle.apex:115`** should change from writing `Status__c='Closed'`
directly to writing `Stage__c='Closed'`, so the script exercises the fix instead of bypassing it.
Leaving it as-is is not a *break* — it just re-creates the inverse inconsistency (Status closed,
Stage stuck) and stops being a valid lifecycle verification.

---

## 5. GAP 3 — make the PSA → About to Close handoff obvious (staying manual)

### 3.1 Measured state

- `ContractExecutionService.handleExecution` stamps `Contract_Signed__c`,
  `Contract_Executed_Date__c` (Day 0) and `Deal_Status__c='Contract Signed'`, opens the IR
  `Offering__c` shell, and sends **four** notifications (Transactions, IR, Due Diligence,
  Acquisitions). The deal stays at `Under Contract (PSA)`.
- `Opportunity.Move_to_About_to_Close` (LWC `dealMoveToAboutToClose`) → `StageAdvanceService.advanceTo`
  → `About to Close` → `OpportunityReviewTrigger` → `ContractExecutionService
  .openTransactionsOnAboutToClose` → the Transaction and the 82-task fan-out.
- The Path guidance for that stage **currently claims the Transaction was already created** (C-2).
- A competing `Close_Deal` button is visible at the same stage and reaches `Closed Won` with no
  Transaction (C-3).
- A lagging safety net already exists: `StageDelayService` + `Stage_Threshold_Def__mdt`, a flat **14
  days** per open stage, so a deal parked at `Under Contract (PSA)` does eventually get chased.

### 3.2 ✅ RECOMMENDATION: correct the Path guidance step. One file, one element, nothing new.

**Component:** `force-app/main/default/pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml`
**Change:** the `<info>` element of the `Under Contract (PSA)` step (line 37) **only**. Nothing else
in the file.

Suggested replacement (final wording is the user's — this is the required content, not prose to
rubber-stamp):

> Seller issues the first PSA draft; a Contract Review opens automatically. Log every version and
> counter in the negotiation log. On full execution (Negotiation Status = Executed) the deal is
> stamped Contract Signed with the Day-0 date, and Transactions + IR + Due Diligence + Acquisitions
> are notified. **➜ NEXT: click "Move to About to Close" to open the Transaction and fire the 82-task
> Day-0 checklist. This does not happen automatically.**

**Why this, over the four alternatives the brief named:**

| Option | Verdict |
|---|---|
| **Path guidance step** ✅ | The one place in the product whose entire purpose is "what do I do at this stage", already rendered on the page at exactly this stage, **already containing the false claim that is causing the gap**. Fixing it removes an active lie *and* adds the instruction, in one element. Zero new components, zero FLS, zero Apex, zero Jest, zero SLDS, no code review. `recordTypeName=__MASTER__` (verified, `:51`) so a single edit covers **both** the Land and Retail record types. |
| Field help text | Passive — only visible on hover, on a field the user is not looking for. Does not correct C-2. Cheap, and fine as a *complement* on `Contract_Executed_Date__c`, but not as the answer. |
| A new field (e.g. `Next_Step__c` formula) | Adds schema for a static string. Needs FLS in `DPEG_Acquisition_View`/`Edit` (a permission set deploy **replaces** its whole `fieldPermissions` set — `content-publication-and-permset-replace`), plus layout **and** FlexiPage placement, so it inherits every FlexiPage risk below **and** adds schema. Worst ratio of the four. |
| A new LWC prompt on the record page | Highest fidelity, highest cost, and the risk the brief itself flagged: a FlexiPage deploy **replaces** the org copy with no version history, and this repo already lost hand-made App Builder edits that way (`flexipage-deploy-clobbers-app-builder-edits`, 2026-08-25). It also needs a Jest test, an `@sa11y` test, an SLDS-2 lint pass, a `<description>` under 255 chars (`xml-comment-must-be-inside-root`), and code review. **For a sentence.** |
| A fifth notification ❌ | Named here because it is the obvious idea and it is **already budget-blocked**. `ContractExecutionService`'s header (`:51-60`) carries a measured `GroupNotifier` CPU model — ≈6.0 ms per send + 0.22 ms per recipient — and states that going from 3 to 4 recipients took a 200-row chunk from ~3.7 s to ~5.0 s **against a 10 s limit**, with an explicit *"READ THIS BEFORE ADDING A FIFTH RECIPIENT"*. Do not add one. |
| Lower the `Stage_Threshold_Def__mdt` threshold for this stage ❌ | It is a **batch reminder days later**, not an in-context prompt, so it does not solve the stated problem. It also breaks the "flat 14 across all eight open stages" recorded user decision, and `**/customMetadata/**` is force-ignored so the row is org-only and invisible to review. |

### 3.3 Preconditions to verify before this lands (it is cheap but not free)

1. **G-5** — retrieve and diff the PathAssistant against the org first. Same clobber class as the
   FlexiPage incident; guidance text is Setup-editable.
2. **The Path must actually render.** Two known ways it silently does not:
   - `pathAssistantEnabled` is an **org-wide master switch** and scratch/org rebuilds lose it
     (`path-assistant-org-switch`). If Paths are off org-wide, this fix is invisible and the whole
     recommendation collapses.
   - Record pages are assigned **per app** (`record-pages-are-assigned-per-app`). Verified:
     `applications/Acquisition.app-meta.xml:15` overrides Opportunity `View` →
     `Opportunity_Record_Page`, and that page carries
     `runtime_sales_pathassistant:pathAssistant` at `:224`. ✅ **Covered for the Acquisition app.**
     ⚠ `standard__LightningSales` and `standard__Marketing` also expose the Opportunity tab with **no**
     `actionOverride`, so a user opening a deal from the Sales app gets the object-default page. If
     the acquisitions persona ever works there, the guidance is invisible. Confirm which apps the
     persona uses.
3. Do **not** touch any other `<pathAssistantSteps>` block. The `About to Close` step (`:7-11`) is
   correct as written.

### 3.4 ⚠ OPEN DECISION, NOT DESIGNED AROUND — the `Close_Deal` shortcut

Per C-3, `Opportunity.Close_Deal` is visible at `Under Contract (PSA)` and reaches `Closed Won`
without ever creating a Transaction. `StageAdvanceService` already records the consequence: *"half
the closes carry no `Transaction__c` at all."*

**Saying this plainly, as asked: a guidance sentence does not close that hole.** It makes the right
button more discoverable while leaving the wrong one one click away, equally styled, at the same
stage.

Three ways to handle it. **This design does not pick one — it is outside the user's stated decision
("keep it manual, make the next step obvious") and picking it silently would be scope creep.**

- **(i) Do nothing.** Accept that `Under Contract (PSA)` → `Closed Won` is a legitimate business path
  (a deal that closes without a managed transaction). Cheapest, and possibly correct — but it should
  be a *decision*, not a leftover.
- **(ii) Narrow `Close_Deal`'s visibility rule** to `StageName EQUAL 'About to Close'` only —
  a two-line edit to the FlexiPage's `booleanFilter` at `:144` (`(1 OR 2) AND 3` → `2 AND 3`) that
  forces every close through the Transaction. **Requires opening the FlexiPage**, so it carries the
  full retrieve-and-diff-seconds-before-deploy protocol. Also a real behaviour restriction that may
  break a legitimate workflow.
- **(iii) Say so in the guidance text** — e.g. append *"Closing the deal directly from here skips the
  Transaction."* Zero extra cost, rides on the change already being made, does not restrict anything.

If the user wants one now, **(iii)** is the one consistent with "make it obvious, keep it manual".

---

## 6. GAP 4 — the 75-task figure is wrong (82 in 11 groups)

### 4.1 The count is confirmed, and the 82 figure is already load-bearing elsewhere

`TaskFanoutServiceTest.cls:210-211` and `TransactionTaskDefProviderTest.cls:14-15` both **assert**
`82 = [SELECT COUNT() FROM Transaction_Task_Def__mdt]`, and `TaskFanoutServiceTest:192` names
"82 `Transaction_Task_Def__mdt` / 11 `Task_Group_Def__mdt`". The newer classes (`TaskFanoutService`,
`TaskFanoutQueueable`, `TaskRollupService`, `TaskSelector`, `TransactionTaskService`,
`TaskRollupTriggerHandler`) all say 82. **The 75s are stragglers, not a competing source of truth.**

⚠ **The CMDT rows themselves are NOT in this repo.** `.forceignore:16` excludes
`**/customMetadata/**`; there is no `customMetadata/Transaction_Task_Def*` file. The rows are loaded
into the org by `scripts/load-transaction-task-defs.apex`. So the brief's "CMDT descriptions"
sub-item **cannot be addressed from source** — if any CMDT row's description says 75, it must be
fixed in that loader script and/or in Setup. **Add a `75` grep of
`scripts/load-transaction-task-defs.apex` to the DEV prompt** (this design did not read that file's
contents; it was identified by name only).

### 4.2 🔴 CHANGE — live claims that are wrong

| # | File | Line(s) | Current | Note |
|---|---|---|---|---|
| 1 | `pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml` | 37 | "the 75-task fan-out fires" | **User-facing.** Same element as Gap 3 §3.2 — **fix both in one edit.** |
| 2 | `classes/TaskRollupService.cls` | 3 | `drives the "N / 75" highlights tile` | **Materially wrong.** The tile is `Tasks_Display__c` = `TEXT(Tasks_Complete__c) & " / " & TEXT(Tasks_Total__c)` — verified — so it renders `N / 82`. This header is the last "75" that describes a *live rendered value*. |
| 3 | `classes/TestDataFactory.cls` | 1278-1279 | "fans out ~75 Tasks per Transaction; 251 Transactions x 75 = **18,825** rows against the 10,000" | 🔴 **The arithmetic is wrong, not just the adjective.** 251 × 82 = **20,582**. The warning understates the overflow by 1,757 rows. `TaskFanoutServiceTest:248` already carries the correct figure — copy it. |
| 4 | `classes/ContractExecutionService.cls` | 37, 181, 286, 358 | "75-task checklist", "~75-task Day-0 checklist", "~75 checklist tasks", "~75-row Day-0 checklist" | 4 occurrences. |
| 5 | `classes/ContractExecutionServiceTest.cls` | 314, 552, 829, 870, 1184, 1384, 1403, 1417 | ~75 / 75-task / ~75-row | 8 occurrences, several inside assertion **messages** (552, 870, 1403, 1417) — those are strings a failing test prints. |
| 6 | `classes/ContractReviewTriggerHandlerTest.cls` | 88 | "the 75-task checklist" | Inside an assertion message. |
| 7 | `objects/Opportunity/validationRules/Executed_PSA_Before_Contract_Date.validationRule-meta.xml` | 16, 22, 25 (XML comment) + **174 (`<description>`)** | "Day-0 75-task fan-out", "MIS-DATED 75-task checklist", "~75 checklist tasks", and in `<description>`: "mis-dated 75-task Transaction checklist" | ⚠ `<description>` is capped at **255 chars**; `75`→`82` is same-length so it is safe, but do not reflow the line. |
| 8 | `docs/2026-08-16-fsd-gap-tranche-1.md` | 29, 140, 144, 462 | 75-task / ~75 tasks | |
| 9 | `docs/2026-08-04-danish-transaction-access-notification.md` | 31, 100, 290 | ~75-task ×2, "(creates the ~75-task Day-0 checklist)" in an ASCII diagram | ⚠ line 290 is inside a box-drawing diagram — `75`→`82` preserves width. |

**Totals: 9 files, 25 occurrences.**

### 4.3 🟢 DO **NOT** CHANGE — historical records and unrelated 75s

Changing any of these makes the repo *less* accurate. Listed explicitly because a naive
find-and-replace of `75` would hit every one.

| File | Line(s) | Why it stays |
|---|---|---|
| `lwc/activeTransactionsList/activeTransactionsList.js` | 13 | *"This file **used to carry** `const TASKS_TOTAL = 75;`"* — a quote-and-retract recording the fix. |
| `lwc/activeTransactionsList/__tests__/activeTransactionsList.test.js` | 191 | *"hardcoded 75 this row was 85% and never turned green"* — describes the historical bug the test pins. |
| `classes/TransactionSelector.cls` | 205 | *"The LWC **used to** hardcode 75 while … showed 82"* — historical, and already states 82. |
| `classes/TransactionController.cls` | 103 | Same sentence, same reason. |
| `classes/TransactionControllerTest.cls` | 220 | `75` **days** time-to-close. Unrelated. |
| `classes/DealFolderService.cls` | 404 | `~75` **seconds** timeout headroom. Unrelated. |
| `scripts/seed-transactions.apex` `:70`, `scripts/seed-transactions-nondestructive.apex` `:85` | | `Tasks_Complete__c = 75` is **seed data**, not a count claim. It renders `75 / 82` on the closed demo row, which is arguably wrong-looking. **Optional** — call it out to the user rather than deciding. |
| `agent-output/**`, `docs/2026-08-27-deal-folder-claim-stages.md`, `docs/2026-07-31-llm-field-extraction.md` | | Coverage percentages, ratios, `6.75`, line-number references. All unrelated. |

### 4.4 Where the "user story" saying 75 lives

Not found in the repo as a tracked artifact. The FSD-derived claim is captured at
`docs/2026-08-16-fsd-gap-tranche-1.md:140` (*"FSD §29.1 claimed…"*). The FSD itself
(`docs/DPEG_Technical_Solution_Design_v1.3.docx`) was **not** searched — a `.docx` is a zip and this
agent cannot read it usefully. ⚠ **If the user story lives there, it is out of reach from source and
must be corrected by hand.** Flagged, not silently dropped.

---

## 7. Parallelism and ordering

```
GAP 1  ─────────────────────────────────────────►  independent
GAP 2  ─────────────────────────────────────────►  independent
GAP 4  ─────────────────────────────────────────►  independent (docs only)
                    │
GAP 3  ─────────────┴───────────────────────────►  SHARES ONE FILE WITH GAP 4
```

- **Gaps 1, 2 and 4 are fully independent** — disjoint objects, disjoint files, disjoint deploys.
  Run in parallel.
- **Gap 3 and Gap 4 collide on exactly one element:** `pathAssistants/Acquisitions_Deal_Path
  .pathAssistant-meta.xml`, `<pathAssistantSteps>` for `Under Contract (PSA)`, the `<info>` text at
  line 37. Gap 3 rewrites it; Gap 4 item #1 changes `75`→`82` inside it. **Do them as ONE edit in ONE
  agent.** Two agents editing that file concurrently is exactly the shared-hub-file failure recorded
  in `parallel-build-hub-file-protocol` and `commit-retrieves-before-editing`.
- **Within Gap 1, the order is mandatory** (§1.6): value set + record types (one payload) → verify →
  Apex → seeds. This is the "record types before Apex" constraint, and §1.5 is the mechanism.
- **Within Gap 2 there is no ordering constraint** — one new flow file.

---

## 8. Prompts for specialist agents

### 🔵 PROMPT A — `salesforce-admin` (Gap 1, declarative half)

```
Gap 1, declarative half. Align Opportunity.Asset_Type__c to Lead.Asset_Type__c.
Read agent-output/gap-fixes-design.md §3 in full before starting. Do not deploy — create metadata
files only; deployment is the devops agent's step. Record mcp=complete|unavailable + tools per
.claude/rules/salesforce-global-rule.md for BOTH CustomField and RecordType (RecordType needs its
own API-context call; the parent's does not cover it).

🚦 BLOCKING — do not edit anything until this is answered:
  G-1  Ask devops to run against usman-dpeg:
         SELECT COUNT() FROM Opportunity WHERE Asset_Type__c = 'Retail Strip'
       If the count is NOT 0, STOP and report back. The whole rename approach depends on it,
       because a Metadata-API value-set edit that drops <fullName>Retail Strip</fullName> is a
       DELETE, and on a restricted picklist the surviving rows become unupdatable.
  G-2  Confirm the target is 8 values (match Lead), not 10 (match Property).

EDIT EXACTLY THREE FILES. Nothing else.

1. force-app/main/default/objects/Opportunity/fields/Asset_Type__c.field-meta.xml
   Final <valueSetDefinition>, in this order, each <fullName> == <label>, all <default>false</default>:
     Retail, Land, Industrial, Office, Multifamily, Mixed-Use, Hospitality, Medical Office
   Keep <restricted>true</restricted> and <sorted>false</sorted> exactly as they are.
   Remove the 'Retail Strip' <value> block entirely.

2. force-app/main/default/objects/Opportunity/recordTypes/Retail.recordType-meta.xml
3. force-app/main/default/objects/Opportunity/recordTypes/Land.recordType-meta.xml
   In EACH file, change ONLY the <picklistValues> block whose <picklist> is Asset_Type__c.
   Replace 'Retail Strip' with 'Retail' and ADD 'Hospitality' and 'Medical Office'
   (each <fullName> + <default>false</default>). Alphabetical, matching the existing style:
     Hospitality, Industrial, Land, Medical Office, Mixed-Use, Multifamily, Office, Retail

🔴 STRUCTURAL INVARIANT — verify after editing, and report the numbers:
   Each record-type file must still have EXACTLY 10 <picklistValues> blocks and 47 <values>
   entries. (Was 47 with 6 asset types; is 49 with 8. State the new number explicitly in your
   report so the change is auditable.) Do NOT reformat, reorder or touch any other block.

🔴 DO NOT "SYNC FROM ORG". A RecordType retrieve returns ONLY fullName/active/description/label —
   it STRIPS every picklistValues block. These two repo files are the SOLE record of the
   record-type value subsets. Committing a retrieved copy is a silent production regression.
   Verify the field change with a REST describe, never with a retrieve (a retrieve UNIONS local
   and remote picklist values and will appear to restore 'Retail Strip').

🔴 DEPLOY ORDER (hand to devops, do not deploy yourself):
   All THREE files in ONE payload — field first is what the Metadata API does internally.
   Split either way and it fails: field-first leaves the org's record types pointing at a
   deleted value; RT-first names values the field does not yet offer.
   The single-payload behaviour is NOT confirmed (mcp=unavailable) — require a --dry-run.
   If the dry-run rejects it, fall back to three deploys: field with BOTH old and new values,
   then the record types, then the field with 'Retail Strip' removed.

DO NOT: touch profiles (force-ignored), permission sets (Opportunity.Asset_Type__c is already
granted in DPEG_Acquisition_View, DPEG_Acquisition_Edit and DPEG_Opportunity_View — adding values
to an existing field changes no FLS), list views (columns only, no value filters), reports,
layouts, or flexipages/Opportunity_Record_Page.flexipage-meta.xml. None of them is in scope and
the FlexiPage carries a clobber risk for zero benefit.
```

### 🟢 PROMPT B — `salesforce-developer` (Gap 1, code half — AFTER Prompt A is deployed)

```
Gap 1, code half. Carry Lead.Asset_Type__c onto the Opportunity at conversion, and repoint every
'Retail Strip' literal. Read agent-output/gap-fixes-design.md §3, especially §1.5, before starting.
DO NOT START until the record types from Prompt A are deployed and verified in usman-dpeg — §1.5
explains why a code-first deploy rolls back whole conversion chunks.

1. classes/LeadConvertService.cls
   Follow the EXISTING pattern in this class exactly; invent nothing.
   a) Add a memoized cache + accessor beside the four at :198-248, using
      activePicklistValues(Opportunity.Asset_Type__c).
      ⚠ NAME COLLISION: assetTypeValues() / assetTypeValuesCache already exist at :198/:205 and
        hold PROPERTY__C's values (used at :781). Your new one is for OPPORTUNITY. Name them so
        the two can never be confused (e.g. opportunityAssetTypeValues /
        opportunityAssetTypeValuesCache) and leave the Property pair untouched.
   b) In applyDealFields (:584), beside the three existing restricted-picklist writes at :604-613:
        o.Asset_Type__c = picklistValueOrNull(l.Asset_Type__c, opportunityAssetTypeValues());
      Zero new SOQL, zero new DML — the value is already on `l`, and `o` is already in the
      `updates` list the caller writes with one statement. The class header's governor contract
      is UNCHANGED; say so in a one-line comment and do NOT restate the header's numbers (that
      has gone stale twice already — see the notes at :548 and :634).
   c) Add a comment at activePicklistValues (:1106) recording this, because the next person will
      not re-derive it:
        This helper reads the FIELD describe, which is BLIND to the record-type value subset. A
        value active on the field but absent from the Opportunity Land/Retail record types passes
        this guard and is then REFUSED at DML with INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST,
        rolling back the ALL-OR-NONE `update updates` for EVERY Lead in the chunk. Asset_Type__c
        is the first guarded picklist here that carries a record-type block (Sale_Process__c,
        Parse_Confidence__c and Listing_Status__c carry none). Keep the field value set and BOTH
        record-type blocks in lockstep; do not "harden" this helper instead.

2. classes/TestDataFactory.cls :828-829
   'Retail Strip' -> 'Retail'. REWRITE the comment above it — it currently documents the
   divergence being removed. Replace, do not delete: say the three sets are now aligned
   (Lead 8 = Opportunity 8 subset of Property 10) as of 2026-08-31.

3. classes/OpportunityFunnelControllerTest.cls :119
   assertEquals('Retail Strip', ...) -> 'Retail'.

4. classes/LeadConvertServiceTest.cls — add coverage for the new write:
   - a converted Lead carrying 'Retail' lands 'Retail' on the Opportunity;
   - a converted Lead carrying 'Hospitality' lands 'Hospitality' (this is the value that proves
     the record types were widened — it is the whole point of the gap);
   - a Lead with a null Asset_Type__c leaves the Opportunity null and does not throw;
   - the existing bulk test (bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities,
     251 leads / two convertLead chunks) must still assert the per-invocation governor bound is
     UNCHANGED. A describe is not a query; if that assertion moves, you added a query.

5. Non-deployed assets (see §1.3 list C for exact lines):
   - scripts/gen-metadata.mjs :221 — 🔴 the root cause. Lines 101 and 206 use a shared ASSET
     constant; 221 hardcodes the 6-value Opportunity list. Point it at the shared source or the
     divergence regenerates on the next org rebuild.
   - scripts/gen-data.mjs :25,26,27,32 and :42 — line 42's `d[3].split(' ')[0]` exists ONLY to
     turn 'Retail Strip' into 'Retail'. REMOVE the .split(), do not leave it: it would silently
     truncate 'Medical Office' to 'Medical'.
   - data/opportunities.json :13,32,51,146
   - scripts/seed-deal.apex :12
   - scripts/seed-fsd-06-volume-pipeline.apex :29,34,43,47,52,57,62,64,66 and the two maps at
     :75-86 — both maps become identity maps. QUOTE-AND-RETRACT the :75-83 comment explaining
     the divergence rather than deleting it.
   - scripts/seed-fsd-07-portfolio-deal.apex :30,31,32 — prose inside an email body string.
     Optional; do it to keep the grep clean.

DO NOT: change any list view, report, layout, flexipage, permission set or profile. DO NOT make
activePicklistValues record-type-aware (§1.5 argues against it). DO NOT touch the Property-side
assetTypeValues() at :198-209 or the write at :781.
```

### 🔵 PROMPT C — `salesforce-admin` (Gap 2)

```
Gap 2. Transaction__c.Status__c has no writer. Read agent-output/gap-fixes-design.md §4 before
starting. Create metadata only; do not deploy. Record mcp=complete|unavailable + tools per
.claude/rules/salesforce-global-rule.md for the Flow type.

🚦 CONFIRM FIRST (G-3): does this apply on INSERT as well as UPDATE? The design recommends both;
   §2.6(a) explains what changes in two seed scripts if you say yes.

CREATE ONE FILE:
  force-app/main/default/flows/Transaction_Stage_Closed_Sets_Status.flow-meta.xml
    processType                            AutoLaunchedFlow
    triggerType                            RecordBeforeSave
    recordTriggerType                      CreateAndUpdate   (per G-3)
    object                                 Transaction__c
    doesRequireRecordChangedToMeetCriteria true
    entry filter                           Stage__c EqualTo 'Closed'
    one <assignments>                      $Record.Status__c = 'Closed'
    status                                 Active
    apiVersion                             67.0

  BEFORE-SAVE is deliberate and load-bearing. Do NOT make it after-save: an after-save flow would
  add a DML on Transaction__c and re-enter the object's own automation. A before-save assignment
  mutates the in-flight record with zero DML and zero SOQL. It also fires for EVERY writer — the
  advanceRecordStage quick action, an inline Path edit, the API, a data loader, a seed script —
  which is the property this gap needs, because RecordStageAdvanceService is not the only writer.

  WRITE THIS INTO THE FLOW'S <description> (and keep it under 255 characters — the cap is real
  and only a deploy catches an overflow):
    Sets Status__c=Closed when Stage__c reaches Closed. Status__c=Closed is the trigger for
    Transaction_Complete_Close, which closes the parent Opportunity. Inserting a Transaction with
    Stage__c=Closed AND an Opportunity__c will therefore close that Opportunity on insert.

ALSO UPDATE (same change, they become wrong the moment this deploys):
  - classes/TransactionControllerTest.cls :116-119 and :160-162 — both carry comments stating
    that Status__c='Closed' and Stage__c='Closed' are unrelated fields that coincidentally share
    a value. That is no longer true. Rewrite them to say the two are now causally linked by
    Transaction_Stage_Closed_Sets_Status, and that only Status__c drives the Active-only filter
    under test. The assertions themselves do not change.
  - scripts/verify-junior-lifecycle.apex :115 — currently `update new Transaction__c(Id = txn.Id,
    Status__c = 'Closed');`, i.e. the manual E2E workaround. Change it to write Stage__c='Closed'
    so the script exercises the fix instead of bypassing it.

DO NOT:
  - change flows/Transaction_Complete_Close.flow-meta.xml. Its trigger condition stays
    Status__c = 'Closed'. The user was explicit.
  - add a branch to classes/RecordStageAdvanceService.cls. setStage (:2457) is generic across
    eight objects on purpose; an object-specific special case there is rejected in §2.3.
  - create a TransactionTrigger. There is none today and this does not justify one (it would
    require a 251-record bulk test on the object that fans out 82 Tasks each = 20,582 rows).
  - add a validation rule. Transaction__c has no validationRules/ folder and this gap adds none.
  - rename quickActions/Transaction__c.Move_to_Closed_Won.quickAction-meta.xml. Its label is
    already 'Closed'; only the API name is stale, and renaming it is a delete+create that would
    force a matching FlexiPage edit for zero functional gain (§C-5).

ACCEPTANCE — a deploy result is NOT proof (§2.5):
  1. As a real DPEG_Transaction_Team persona (NOT an admin), advance a Transaction from
     Post-Closing to Closed via the quick action. Read Status__c back — it must be 'Closed'.
  2. On a Transaction WITH an Opportunity__c, confirm the parent reaches Closed Won and that
     PropertyAssetService.ensureOnClosedWon mints the Property Asset (§C-1: the flow does NOT
     create it — OpportunityReviewTrigger does, two hops later).
  3. Do NOT assert on the Chatter congratulation. GroupNotifier targets the Acquisitions_Team
     PUBLIC GROUP, whose membership is not deployable; an empty group notifies nobody, silently.
```

### 🔵 PROMPT D — `salesforce-admin` (Gaps 3 + 4 — ONE agent, they share a file)

```
Gaps 3 and 4 combined. They edit the SAME element and must not be split across two agents. Read
agent-output/gap-fixes-design.md §5 and §6 before starting. Documentation and guidance text only —
no new components, no Apex, no schema, no FlexiPage.

🚦 BLOCKING (G-5): before editing, have devops RETRIEVE
   force-app/main/default/pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml from
   usman-dpeg and DIFF it against HEAD. A PathAssistant deploy REPLACES the org copy and guidance
   text is Setup-editable with no version history — the same failure that lost hand-made App
   Builder edits on 2026-08-25. If the org copy differs, stop and report the diff.

🚦 ALSO VERIFY (or the whole Gap 3 fix is invisible):
   (a) pathAssistantEnabled is ON org-wide. It is a master switch that org rebuilds lose.
   (b) Which app the acquisitions persona uses. applications/Acquisition.app-meta.xml:15
       overrides Opportunity View -> Opportunity_Record_Page, which carries
       runtime_sales_pathassistant:pathAssistant at :224 — covered. But standard__LightningSales
       and standard__Marketing expose the Opportunity tab with NO actionOverride, so a deal opened
       from the Sales app renders the object-default page and this guidance never appears.

── GAP 3 + GAP 4 item #1: ONE EDIT ──
File: force-app/main/default/pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml
Element: the <info> of the <pathAssistantSteps> whose <picklistValueName> is
         'Under Contract (PSA)' (line 37). NOTHING ELSE IN THE FILE.

The current text is FALSE on two counts and both must go:
  - it says "the Transaction is created" on PSA execution. It is NOT. ContractExecutionService's
    header (:34-38) says creation moved to openTransactionsOnAboutToClose on 2026-08-05 and
    states "Do not re-add Transaction creation to handleExecution". The same retraction is at
    RecordStageAdvanceService.cls:1198-1202.
  - it says "75-task". It is 82.

Replacement content (adjust wording with the user; these facts are required):
  "Seller issues the first PSA draft; a Contract Review opens automatically. Log every version and
   counter in the negotiation log. On full execution (Negotiation Status = Executed) the deal is
   stamped Contract Signed with the Day-0 date, and Transactions + IR + Due Diligence +
   Acquisitions are notified. NEXT: click 'Move to About to Close' to open the Transaction and
   fire the 82-task Day-0 checklist. This does not happen automatically."

  ⚠ ASK THE USER before adding anything about the Close_Deal shortcut (§3.4). Close_Deal is
    visible at this same stage and reaches Closed Won with NO Transaction — StageAdvanceService
    :135-140 says "half the closes carry no Transaction__c at all". Option (iii) in §3.4 is to
    append "Closing the deal directly from here skips the Transaction." It is NOT in the user's
    stated scope, so do not add it unasked.

  recordTypeName is __MASTER__ (:51), so this one edit covers BOTH the Land and Retail record
  types. Do not touch the 'About to Close' step at :7-11 — it is correct.

── GAP 4: the remaining 75 -> 82 corrections ──
CHANGE these, exactly these lines (§6 §4.2):
  classes/TaskRollupService.cls                                   :3     ("N / 75" -> "N / 82";
      verified: Tasks_Display__c = TEXT(Tasks_Complete__c) & " / " & TEXT(Tasks_Total__c), so the
      tile really does render 82)
  classes/TestDataFactory.cls                                     :1278-1279
      🔴 FIX THE ARITHMETIC, not just the word: "251 Transactions x 75 = 18,825" must become
      "251 x 82 = 20,582". TaskFanoutServiceTest:248 already carries the correct figure.
  classes/ContractExecutionService.cls                            :37, :181, :286, :358
  classes/ContractExecutionServiceTest.cls                        :314, :552, :829, :870, :1184,
                                                                  :1384, :1403, :1417
  classes/ContractReviewTriggerHandlerTest.cls                    :88
  objects/Opportunity/validationRules/Executed_PSA_Before_Contract_Date.validationRule-meta.xml
                                                                  :16, :22, :25, :174
      ⚠ :174 is <description>, capped at 255 chars. 75->82 is same-length; do not reflow.
  docs/2026-08-16-fsd-gap-tranche-1.md                            :29, :140, :144, :462
  docs/2026-08-04-danish-transaction-access-notification.md       :31, :100, :290
      ⚠ :290 is inside an ASCII box diagram; 75->82 preserves the width.

ALSO GREP (this design did not read its contents):
  scripts/load-transaction-task-defs.apex for '75'. The 82 CMDT rows are NOT in this repo —
  **/customMetadata/** is force-ignored (.forceignore:16) — so any CMDT description saying 75
  must be fixed in that loader and/or by hand in Setup. Report what you find.

🔴 DO NOT CHANGE — these are HISTORICAL RECORDS and changing them makes the repo LESS accurate.
   A blanket find-and-replace of "75" hits every one of them:
     lwc/activeTransactionsList/activeTransactionsList.js                    :13
     lwc/activeTransactionsList/__tests__/activeTransactionsList.test.js     :191
     classes/TransactionSelector.cls                                        :205
     classes/TransactionController.cls                                      :103
       (all four are quote-and-retract notes recording the 75->82 fix itself)
     classes/TransactionControllerTest.cls  :220   — 75 DAYS time-to-close, unrelated
     classes/DealFolderService.cls          :404   — ~75 SECONDS timeout, unrelated
     agent-output/**, docs/2026-08-27-deal-folder-claim-stages.md,
     docs/2026-07-31-llm-field-extraction.md      — coverage %, ratios, 6.75, line numbers

⚠ OPTIONAL, ASK THE USER: scripts/seed-transactions.apex:70 and
  scripts/seed-transactions-nondestructive.apex:85 set Tasks_Complete__c = 75, which renders
  "75 / 82" on the closed demo row. That is seed DATA, not a count claim. Changing it to 82 makes
  the demo read cleanly; leaving it is also defensible.

⚠ OUT OF REACH: docs/DPEG_Technical_Solution_Design_v1.3.docx was NOT searched (a .docx is a zip;
  this repo has no Python/LibreOffice). If the "75-task" user story lives there, it must be
  corrected by hand. Report this to the user rather than dropping it.
```

---

## 9. Things I think are a bad idea — said plainly

1. **Deploying the Gap 1 Apex before the record types.** §1.5. It does not fail politely: it rolls
   back the entire conversion stamping for every Lead in the chunk, structural fields included, and
   the error names a picklist rather than a record type. This is the single most likely way these
   four gaps produce a production incident.

2. **Making `LeadConvertService.activePicklistValues` record-type-aware.** It looks like the robust
   fix. It trades a loud, correct rollback for a silent drop on the exact field the user just asked
   to be populated — recreating Gap 1 invisibly. Keep the three files in lockstep instead.

3. **Add-and-retire for `Retail Strip`.** §1.4. On a restricted picklist read by a describe-based
   allow-list, leaving both values active means the allow-list accepts either and the divergence
   survives the fix that was meant to remove it.

4. **Building an LWC for Gap 3.** §3.2. A Jest test, an `@sa11y` test, an SLDS-2 lint pass, a
   sub-255-char `<description>`, a code review, and a FlexiPage deploy that replaces the org copy
   with no version history — to display a sentence, next to an existing component whose entire
   purpose is displaying that sentence and which currently displays the *opposite* of it.

5. **Adding a fifth notification on PSA execution.** §3.2. `ContractExecutionService`'s header
   carries a measured CPU budget (~5.0 s of a 10 s limit at a 200-row chunk) and an explicit "READ
   THIS BEFORE ADDING A FIFTH RECIPIENT".

6. **Special-casing `Transaction__c` inside `RecordStageAdvanceService.setStage`.** §2.3. That method
   is generic across eight objects by design, and it would still miss the Path and the API.

7. **A blanket find-and-replace of `75` for Gap 4.** §4.3. It would corrupt four quote-and-retract
   notes that are the repo's only record of the 75→82 fix, plus a 75-day metric and a 75-second
   timeout. The list is 25 occurrences in 9 files, enumerated; use it.

8. **"Syncing" the Opportunity record types from the org after the Gap 1 deploy.** A RecordType
   retrieve strips every `picklistValues` block. Committing the result silently deletes the
   record-type value subsets for all ten picklists, on both record types.

9. **Treating a green deploy as acceptance for any of these four.** Gap 1's real test is a
   Hospitality-lead conversion; Gap 2's is a non-admin persona clicking the button and reading
   `Status__c` back; Gap 3's is a browser check that the Path renders in the app the persona uses.
   This repo has recorded incidents for "689/689 deployed, 0 errors" on a deploy that rolled back
   everything, and for dry-runs that skip unchanged components entirely.
