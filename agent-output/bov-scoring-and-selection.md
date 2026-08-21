# BOV Scoring & Broker Selection — Design Requirements

**Date:** 2026-08-21
**Author:** Salesforce Design Agent
**Scope status:** The six-item list is **USER-CONFIRMED and NOT re-opened**. This document covers
*how*, *in what order*, *what breaks*, and *what the list missed*.
**Verification basis:** every claim below is grounded in a file read in this session and the path is
quoted. Anything I could not verify from the file system is in
[§10 Could Not Verify](#10-could-not-verify--must-be-checked-in-org).
🔴 **This agent has no org access and no `salesforce-api-context` MCP** (file read/write/search only).
No claim here is backed by a live describe or a dry-run.

---

## 0. Read this first — five findings that contradict the brief

| # | Finding | Where |
|---|---|---|
| **F-1** | 🔴 **"Nothing writes `BOV_Score__c`" is FALSE.** `TestDataFactory.cls:2697` writes `BOV_Score__c = 80` on **every** BOV fixture; `BovSubmissionSelectorTest.cls:68-70` and `BovControllerTest.cls:58,66,85,87` assign it; four seed scripts write it. A formula field is **not writeable in Apex** — every one of those lines becomes a **compile error**, which takes the whole test suite (and therefore every `RunLocalTests` deploy) down. This, not the field conversion, is the real blast radius of Item 1. | [§1.2](#12-blast-radius--every-reference-measured) |
| **F-2** | 🔴 **Item 6 is already built.** `bovComparisonMatrix.js:16` — `{ label: 'Broker Firm', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'brokerFirm' } } }`, and `brokerFirm` ← `BovController.BovRow.brokerFirm` ← `BOV_Submission__c.Broker_Firm__c` (`BovController.cls:80`). The firm is the **first** column and is already the click-through link. There is nothing to add. | [§6](#6--broker-firm-in-the-comparison-matrix) |
| **F-3** | 🔴 **Item 7's guard holds.** `BovSubmissionSelectionGuardService` is wired at `beforeInsert` **and** `beforeUpdate` (`BovSubmissionTriggerHandler.cls:172-206`), backed by 17 tests including four at 251 records. **Do not build a second mechanism.** Three residuals named in [§7](#7--verify-do-not-rebuild-the-single-selected-guard); the sharpest is that `BovSubmissionTrigger.trigger:51` declares no `after undelete`, and Salesforce has no *before* undelete context at all. | [§7](#7--verify-do-not-rebuild-the-single-selected-guard) |
| **F-4** | 🔴 **The validation rule Item 2 asks about would strand approved dispositions.** `DispositionApprovalAdvanceService`'s own header states its stage write is `Database.update(..., SYSTEM_MODE)` and that **"VALIDATION RULES STILL EVALUATE (SYSTEM_MODE lifts CRUD and FLS and NEVER a rule)"**, and that a refusal *deliberately* leaves `Approval_Advance_Pending__c = true` with **no error shown to the approver**. A blank-Asking-Price VR on the exit from `Disposition Readiness` would silently freeze every Sale-Decision approval. **Recommendation: a service pre-check, not a VR.** | [§2.4](#24-the-validation-rule-question--answer-no-vr-a-service-pre-check-instead) |
| **F-5** | ⚠ **`Asking_Price__c` will be invisible exactly where the score is read.** The `Details` fieldSection on `Disposition_Record_Page.flexipage-meta.xml:773-795` carries `Disposition_Stage__c NE 'BOV Outreach' AND NE 'Active Listing' AND NE 'Closing' AND NE 'Sale Closes'`. Both column facets (`Facet-45162e4e`, `Facet-0a494558`) sit **inside** that section, so a field placed in either is hidden at BOV Outreach — the one stage where an analyst reads the scores and would notice the price is wrong. | [§2.3](#23-layout--flexipage-placement) |

Two further contradictions worth stating: the brief says `dealDocStatus` covers four document rows — it
covers **six** (NDA, Underwriting, LOI, Development, Construction, Contract —
`dealDocStatus.html:10-153`); and the brief says `dispositionDealSummary` "excludes `LOI_Signed_Date__c`" —
correct, and the exclusion is stated in **three** places that must all be preserved
(`dispositionDealSummary.js:32-43`, `DispositionDealSummaryService.cls:92-101`, and
`LoiSelector.selectLatestByDispositionId`).

---

## 1 — `BOV_Score__c` becomes a formula field

### 1.1 The platform constraint (verified as far as this agent can)

`force-app/main/default/objects/BOV_Submission__c/fields/BOV_Score__c.field-meta.xml` is
`<type>Number</type>`, `<precision>4</precision>`, `<scale>0</scale>` — no `<formula>` element.

**Salesforce does not permit changing an existing custom field to or from a Formula type.** The
Change Field Type page omits Formula from the target list, and the Metadata API rejects an update
that adds `<formula>` to a previously non-formula custom field. I have **no org access to prove this
by dry-run** — see [§10](#10-could-not-verify--must-be-checked-in-org), item V-1, which makes this a
one-field check-only dry-run gate before any of the sequencing below is committed to.

In-repo corroboration that formula fields on this very object are *created as formulas* and never
converted: `Broker_Display__c`, `Property_Name__c` and `Selected_Broker__c` all carry `<formula>` from
their first commit, and `Disposition__c.Days_On_Market__c` is the repo's precedent for a **Number
formula that returns `null`** — `IF(ISBLANK(Listing_Date__c), null, TODAY() - Listing_Date__c)`.

### 1.2 Blast radius — every reference, measured

| File | Line(s) | Kind | Breaks on conversion? |
|---|---|---|---|
| `classes/TestDataFactory.cls` | 2697 | **Assignment** `BOV_Score__c = 80` | 🔴 **Compile error** — kills the whole suite |
| `classes/BovSubmissionSelectorTest.cls` | 68, 69, 70 | **Assignments** (90 / 80 / null) | 🔴 Compile error |
| `classes/BovControllerTest.cls` | 58, 66, 85, 87 | **Assignments** | 🔴 Compile error |
| `classes/BovSubmissionSelector.cls` | 84, 88, 133, 204 | `SELECT` + 3 × `ORDER BY ... DESC NULLS LAST` | No — reads are fine |
| `classes/BovController.cls` | 87 | `s.BOV_Score__c.intValue()` | No — `Integer`/`.intValue()` still valid |
| `classes/BovSubmissionService.cls` | 189 | Comment only | No |
| `classes/BovSubmissionSelectorTest.cls` | 60, 78-80 | **Assertions** on 80/90/null | ⚠ Semantically invalidated — see F-1a below |
| `lwc/bovComparisonMatrix/bovComparisonMatrix.js` | 93, 102-105 | Renders `scoreText`, `scoreBar` (already `Math.min(100, score)`) | No |
| `lwc/bovAddResponseModal/*` (js:52-72, html:114-129, `__tests__`:102-109) | — | Comments asserting the field is absent-by-choice and **"is still granted editable in `DPEG_Disposition_Edit`"** | ⚠ Comments become false; the Jest assertion `expect(rendered).not.toContain('BOV_Score__c')` still passes |
| `permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml` | 1182-1186 | `<editable>true</editable>` | 🔴 **Deploy error** — a formula field cannot be `editable=true` |
| `permissionsets/DPEG_Disposition_View.permissionset-meta.xml` | 474 | field grant | ⚠ Check `editable` value |
| `layouts/BOV_Submission__c-BOV Submission Layout.layout-meta.xml` | 51, 118-122 | Comments; field already removed from the layout by hand 2026-08-20 | ⚠ Comments become false |
| `objectTranslations/BOV_Submission__c-en_US/BOV_Score__c.fieldTranslation-meta.xml` | 4 | Translation | Follows the field |
| `manifest/package.xml` | 257 | Manifest member | Follows the field |
| `scripts/seed-disposition.apex` | 131, 136, 141, 146 | **Assignments** | 🔴 Anonymous-Apex runtime failure |
| `scripts/seed-disposition-bulk.apex` | 229-291 (10 rows) | **Assignments** | 🔴 Same — and this file is **uncommitted/modified** per git status |
| `scripts/seed-disp0002.apex` | 100-115 | **Assignments** | 🔴 Same |
| `scripts/query-bov-listing.apex` | 1-2 | Read only | No |
| `profiles/*.profile-meta.xml` × ~35 | 1332 | Field grant | ⚠ **No risk** — `force-app/main/default/profiles/**` is force-ignored (`.forceignore:28`). A future **retrieve** will restore them; strip after retrieving. |
| `docs/dpeg-application-erd-with-fields.svg` | 628 | Diagram | Cosmetic |

**F-1a — the ordering contract changes meaning, and this is the subtlest consequence.**
`BovSubmissionSelector` orders **three** queries `ORDER BY BOV_Score__c DESC NULLS LAST` (lines 88,
133, 204) and its own header calls the null behaviour load-bearing: *"unscored submissions fall to
the bottom"* (line 68). `BovSubmissionService.cls:185-192` further relies on it to make the
two-incumbent repair *"deterministic rather than arbitrary"*.

- If the formula **always returns a number**, nothing is ever null, `NULLS LAST` becomes dead syntax,
  and `BovSubmissionSelectorTest.nullScoreSortsLast` (lines 68-80) becomes **unwritable**.
- If the formula **returns `null` when un-scorable**, the contract survives intact — which is why
  the proposal below returns `null` rather than 0 when the Value dimension cannot be computed.
- 🔴 **Either way, there is a NEW instability:** all 8 existing dispositions have no
  `Asking_Price__c`, so **every existing row scores `null` on day one** and the three `ORDER BY`
  clauses degenerate to *no sort key at all* — row order becomes non-deterministic, exactly the
  second-granularity tie-break failure `dispositionDealSummary.js:14-21` argues about at length.
  **Add `, CreatedDate ASC, Id ASC` as a secondary sort to all three ORDER BY clauses in the same
  change.** This is not optional polish; without it the matrix reshuffles between page loads.

### 1.3 API name — reuse vs. new name

Repo doctrine (`ARCHITECTURE.md` §1 + this agent's standing note): every API-name change is
**delete + create**, and **a deleted custom field keeps its API name until it is permanently ERASED**
in Setup → Object Manager → Deleted Fields. "Delete then recreate in one deploy" fails with a
duplicate-name error.

There is a second, harder gate: **Salesforce refuses to delete a custom field that Apex references.**
`BOV_Score__c` is named in 6 Apex classes. So reuse is not 3 steps, it is 5.

| | **Option A — reuse `BOV_Score__c`** | **Option B — new API name** |
|---|---|---|
| Waves | **5** (strip all Apex/LWC references → destructive delete → **manual Erase in Setup** → create the formula → restore references) | **2** (create the formula under a new name → repoint readers → destructive-delete the old field) |
| Manual, irreversible steps | 1 (Erase) | 0 |
| Window where the matrix shows no score | Yes, spanning 3 deploys | No |
| Convention | ✅ `BOV_Score__c` is the correct name per `ARCHITECTURE.md` §1 type-suffix discipline | ⚠ Any alternative (`BOV_Rating_Score__c`, `Broker_Score__c`) is legal but second-best |
| Residual risk | None once done | A dead `BOV_Score__c` Number field sitting beside a live score field — the "two fields, one meaning" shape this repo has repeatedly had to explain (`Selected_Broker__c` vs `Broker__c`) |

**Backfill is not a factor.** The additive doctrine's *backfill* step exists to preserve data. A
formula recomputes from `BOV_Amount__c` / `Commission_Rate__c` / `Days_To_Market__c` /
`Hist_Success_Rate__c` / `Cap_Rate__c` / `Disposition__r.Asking_Price__c` — **there is nothing to
carry across**, and the only stored values are seed and fixture data (§1.2).

**Recommendation: Option A, reuse `BOV_Score__c`**, on the grounds that (i) there is no production
data to protect, (ii) the org already has a scheduled manual Setup cleanup wave for the three doomed
`Disposition_Stage__c` picklist values (`Disposition_Stage__c.field-meta.xml:154-156`), so a manual
Erase fits an established operating rhythm, and (iii) leaving a dead field named `BOV_Score__c` beside
the real one is the worse long-term defect. **This is a user decision — see Q-2.**

### 1.4 Sequencing (Option A) — nothing fails to compile mid-flight

> **Wave 0 (gate).** One-field check-only dry-run proving the Metadata API refuses a Number→Formula
> conversion in *this* org, and proving the formula's compiled size (V-1, V-2). Do not skip; a
> deploy-green-but-wrong outcome is this repo's documented failure mode.

1. **Wave 1 — schema prerequisite.** `Disposition__c.Asking_Price__c` (Item 2) + its two
   permission-set grants. The score formula cannot compile without it.
2. **Wave 2 — sever every Apex/LWC reference.**
   - `TestDataFactory.createBovSubmissions` — delete the `BOV_Score__c = 80` line, and in its place
     set the five **inputs** the formula consumes so fixtures still produce a predictable score.
   - `BovSubmissionSelectorTest` — delete the three assignments and the four assertions; the
     ordering test is re-authored in Wave 5 against computed values.
   - `BovControllerTest` — same.
   - `BovSubmissionSelector` — drop `BOV_Score__c` from the SELECT at line 84 **and** from the three
     ORDER BY clauses (88, 133, 204); replace with `ORDER BY CreatedDate ASC, Id ASC` temporarily.
   - `BovController.cls:87` — set `r.bovScore = null;` temporarily.
   - Four seed scripts — remove the `BOV_Score__c = …` assignments.
   - Both permission sets — remove the `BOV_Score__c` `fieldPermissions` block.
     🔴 **Diff each permission set against `HEAD` before deploying: a `PermissionSet` deploy REPLACES
     its entire `<fieldPermissions>` set** (this repo has a live incident on record).
3. **Wave 3 — destructive delete** of the `BOV_Score__c` Number field. Also remove the
   `objectTranslations` file and the `manifest/package.xml:257` member.
4. **Wave 4 — MANUAL, in Setup.** Object Manager → BOV Submission → Deleted Fields → **Erase**
   `BOV_Score__c`. Irreversible. **Confirm by re-reading the Deleted Fields list**, not by the
   absence of an error.
5. **Wave 5 — create the formula field, restore everything.** Field → both permission-set grants
   (`editable=false`, mirroring `Broker_Display__c`/`Selected_Broker__c` in the same file) → Apex
   (selector SELECT + `ORDER BY BOV_Score__c DESC NULLS LAST, CreatedDate ASC, Id ASC` × 3;
   controller line 87) → LWC → tests → seed scripts (reading, not writing).
6. **Wave 6 — corrections in place.** Update the now-false comments in
   `bovAddResponseModal.js:52-72` / `.html:114-129` (the field is no longer "one
   `lightning-input-field` away", and is no longer "granted editable"), and in
   `BOV Submission Layout.layout-meta.xml:51,118-122`.

Under **Option B** waves 3 and 4 disappear, Wave 2 becomes a repoint rather than a strip, and nothing
is ever un-referenced.

### 1.5 Proposed formula — five dimensions × 20, structural clamping

**Design rules I am committing to, stated so review can attack them:**

- 🔴 **`<formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>`, not `BlankAsZero`.** This is the
  exact trap the brief names. Under `BlankAsZero`, a blank `Days_To_Market__c` reads as **0 days**
  and a blank `Commission_Rate__c` as **0 %** — both of which score a *perfect* 20/20 on a
  lower-is-better band. `Days_On_Market__c` uses `BlankAsZero` **with** an explicit `ISBLANK` guard;
  with five guards instead of one, `BlankAsBlank` plus explicit guards is the safer pairing.
  ⚠ The consequence of `BlankAsBlank` is that any arithmetic touching a blank yields blank for the
  whole expression — which is why **every** dimension's arithmetic sits inside its own `ISBLANK`-false
  branch. Do not restructure the nesting.
- 🔴 **No division anywhere.** The Value dimension compares `BOV_Amount__c >= Asking_Price__c * 0.95`
  rather than `BOV_Amount__c / Asking_Price__c >= 0.95`. Divide-by-zero is then impossible as a
  *second* layer behind the explicit `<= 0` guard.
- 🔴 **Clamping is structural, not arithmetic.** The top band of each dimension *is* the cap: a BOV at
  300 % of ask scores 20, not 60. No `MIN`/`MAX` calls, which also saves compiled length.
- 🔴 **The score is `null`, not 0, when it cannot be computed.** `null` preserves the
  `ORDER BY … DESC NULLS LAST` contract that three selector queries and one test depend on (F-1a),
  and it is the honest answer for a sale with no asking price. It also matches the in-repo precedent
  `Days_On_Market__c`.
- A blank in one of the *other four* dimensions scores **0** for that dimension only — see §1.6 for
  why that is defensible here and where the residual is.

```
IF(
  OR( ISBLANK(Disposition__r.Asking_Price__c),
      Disposition__r.Asking_Price__c <= 0,
      ISBLANK(BOV_Amount__c) ),
  null,
  IF( BOV_Amount__c >= Disposition__r.Asking_Price__c,        20,
  IF( BOV_Amount__c >= Disposition__r.Asking_Price__c * 0.95, 16,
  IF( BOV_Amount__c >= Disposition__r.Asking_Price__c * 0.90, 12,
  IF( BOV_Amount__c >= Disposition__r.Asking_Price__c * 0.85,  8,
  IF( BOV_Amount__c >= Disposition__r.Asking_Price__c * 0.75,  4, 0)))))
  +
  IF( ISBLANK(Commission_Rate__c), 0,
  IF( Commission_Rate__c <= 1.5, 20,
  IF( Commission_Rate__c <= 2.0, 16,
  IF( Commission_Rate__c <= 2.5, 12,
  IF( Commission_Rate__c <= 3.0,  8,
  IF( Commission_Rate__c <= 4.0,  4, 0))))))
  +
  IF( ISBLANK(Days_To_Market__c), 0,
  IF( Days_To_Market__c <=  60, 20,
  IF( Days_To_Market__c <=  90, 16,
  IF( Days_To_Market__c <= 120, 12,
  IF( Days_To_Market__c <= 180,  8,
  IF( Days_To_Market__c <= 270,  4, 0))))))
  +
  IF( ISBLANK(Hist_Success_Rate__c), 0,
  IF( Hist_Success_Rate__c >= 90, 20,
  IF( Hist_Success_Rate__c >= 80, 16,
  IF( Hist_Success_Rate__c >= 70, 12,
  IF( Hist_Success_Rate__c >= 60,  8,
  IF( Hist_Success_Rate__c >= 50,  4, 0))))))
  +
  IF( ISBLANK(Cap_Rate__c), 0,
  IF( Cap_Rate__c <= 5.0, 20,
  IF( Cap_Rate__c <= 5.5, 16,
  IF( Cap_Rate__c <= 6.0, 12,
  IF( Cap_Rate__c <= 6.5,  8,
  IF( Cap_Rate__c <= 7.5,  4, 0))))))
)
```

**Band table (for the field description and for UAT):**

| Dimension | Direction | 20 | 16 | 12 | 8 | 4 | 0 |
|---|---|---|---|---|---|---|---|
| Value (`BOV_Amount__c` vs ask) | higher better | ≥ 100 % | ≥ 95 % | ≥ 90 % | ≥ 85 % | ≥ 75 % | < 75 % |
| Commission (`Commission_Rate__c`) | lower better | ≤ 1.5 % | ≤ 2.0 % | ≤ 2.5 % | ≤ 3.0 % | ≤ 4.0 % | > 4.0 % / blank |
| Days to market (`Days_To_Market__c`) | lower better | ≤ 60 | ≤ 90 | ≤ 120 | ≤ 180 | ≤ 270 | > 270 / blank |
| Track record (`Hist_Success_Rate__c`) | higher better | ≥ 90 % | ≥ 80 % | ≥ 70 % | ≥ 60 % | ≥ 50 % | < 50 % / blank |
| Cap rate (`Cap_Rate__c`) | **lower better** | ≤ 5.0 % | ≤ 5.5 % | ≤ 6.0 % | ≤ 6.5 % | ≤ 7.5 % | > 7.5 % / blank |

⚠ **`Cap_Rate__c` is `scale 2`, `Commission_Rate__c` is `scale 1`, `Hist_Success_Rate__c` is
`scale 0`** (read from the three field files). The band boundaries above are chosen to sit on
representable values in each field's own scale — a boundary of `5.25` on a `scale 1` field would be
unreachable. Do not "tidy" the boundaries without re-checking each field's scale.

### 1.6 Missing inputs — the honest answer, and why it costs almost nothing here

The brief's requirement — *"a 40/100 caused by two blanks must not be indistinguishable from a
genuinely poor broker"* — cannot be satisfied by a single Number field. But **the scenario is very
nearly unreachable on this object today**, and that is the cheap way out:

| Input | Can it be blank on a new submission? | Evidence |
|---|---|---|
| `BOV_Amount__c` | **No** | VR `BOV_Amount_Required_On_Submission`; `bovAddResponseModal.html:68-72` `required` |
| `Cap_Rate__c` | **No** | `BOV Submission Layout` `behavior=Required` (hand-edited 2026-08-20, retrieved 2026-08-21); `bovAddResponseModal.html:89-93` `required` |
| `Commission_Rate__c` | **No** | same — `bovAddResponseModal.html:95-99` |
| `Days_To_Market__c` | **No** | same — `bovAddResponseModal.html:101-105` |
| `Hist_Success_Rate__c` | ⚠ **Yes** — the only genuinely optional input | `bovAddResponseModal.html:107-111` carries no `required`, and the file's own comment says *"Optional on the layout (behavior=Edit)"* |
| `Disposition__r.Asking_Price__c` | **Yes today, on all 8 rows** | New field, Item 2 |

So the worst reachable case for a *new* submission is **one** blank dimension (Hist), i.e. a
maximum of 20 points lost to missing data — and the Asking Price case returns `null`, not a low
number, so it can never be misread as "poor broker".

**Decision:** blank scores **0** for that dimension, and the field's own `<description>` says so
verbatim. **Q-1 asks the user to pick between two ways of closing the Hist residual**; do not pick
one unilaterally.

Residual that survives either choice, and must be named in the description: **legacy rows** created
before the layout was made Required can carry blanks in more than one dimension. There are 8
dispositions' worth. They will also score `null` (no asking price), which masks the problem for now.

### 1.7 The field's `<description>` — mandatory content

Per the brief, the description must state the absolute-not-relative property. Proposed text
(⚠ **`<description>` has a 255-character cap** — this repo has been bitten by that limit; the longer
prose belongs in an XML comment *inside* the root element, per the pattern in
`Disposition_Stage__c.field-meta.xml:3-88`):

> `0-100, five dimensions x 20: value vs asking price, commission, days to market, track record, cap rate (lower is better). ABSOLUTE, not a rank - a 62 is not "second best", it is 62 of a possible 100. Blank when the disposition has no asking price.`

(233 characters.) The *"a missing input scores 0 for that dimension"* sentence, the band table and
the F-1a ordering note go in the XML comment.

### 1.8 Metadata inventory — Item 1

| Type | File | Action |
|---|---|---|
| CustomField | `objects/BOV_Submission__c/fields/BOV_Score__c.field-meta.xml` | delete (Wave 3) → recreate as Number formula (Wave 5): `<formula>`, `<formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>`, `<precision>3</precision>`, `<scale>0</scale>`, `<type>Number</type>`, `<description>` |
| PermissionSet | `permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml:1182-1186` | `editable` **true → false** (formula) |
| PermissionSet | `permissionsets/DPEG_Disposition_View.permissionset-meta.xml:474` | confirm `editable=false` |
| ObjectTranslation | `objectTranslations/BOV_Submission__c-en_US/BOV_Score__c.fieldTranslation-meta.xml` | remove with the field, recreate |
| Manifest | `manifest/package.xml:257` | remove/restore |
| Layout | `layouts/BOV_Submission__c-BOV Submission Layout.layout-meta.xml` | **no field change** (already removed by hand); comment correction only |

**Apex inventory by layer — Item 1**

| Layer | Class | Change |
|---|---|---|
| Selector | `BovSubmissionSelector` | strip then restore `BOV_Score__c` in 1 SELECT + 3 ORDER BY; **add `, CreatedDate ASC, Id ASC` to all three** (F-1a) |
| Controller | `BovController` | line 87 temporary null, then restore; **no signature change** |
| Service | `BovSubmissionService` | comment at line 189 only |
| Test support | `TestDataFactory` | delete the `BOV_Score__c` assignment; set the five formula **inputs** so fixtures produce a known score |
| Test | `BovSubmissionSelectorTest` | re-author `nullScoreSortsLast` against a fixture with **no asking price** (which is now what produces a null score) and `scoreDescendingSorts` against two dispositions with different asking prices |
| Test | `BovControllerTest` | re-author the two score assertions the same way |

**LWC inventory — Item 1:** none required. `bovComparisonMatrix.js:102-105` already handles
`score == null` (renders `—`, zero-width bar) and already clamps with `Math.min(100, score)`.

**Scripts:** `scripts/seed-disposition.apex`, `seed-disposition-bulk.apex`, `seed-disp0002.apex` —
remove the `BOV_Score__c` writes and **set `Asking_Price__c` on the dispositions they create**, or
every seeded submission scores null. ⚠ `seed-disposition-bulk.apex` is **uncommitted** per git status
— commit or stash before editing to avoid clobbering another session's work.

---

## 2 — `Asking_Price__c` on `Disposition__c`

### 2.1 The field

`Disposition__c` has **no** `Asking_Price__c` today (directory listing of
`objects/Disposition__c/fields/` — 26 files, none matching). The name is convention-correct and
already exists twice in the org (`Property__c.Asking_Price__c`, `Opportunity.Asking_Price__c`), so
`ARCHITECTURE.md` §1's currency rule ("established CRE/finance terms keep their industry name") is
satisfied.

| Property | Value | Rationale |
|---|---|---|
| `fullName` | `Asking_Price__c` | ✅ convention |
| `label` | `Asking Price` | matches both siblings |
| `type` | `Currency` | user-confirmed |
| `precision` / `scale` | `18` / **`0`** | matches `Disposition__c.Accepted_Offer_Price__c` on the **same object**. ⚠ `Property__c.Asking_Price__c` uses `scale 2` — the divergence is deliberate; same-object consistency wins, and a sale price is never quoted in cents. Flag if the user disagrees. |
| `required` | `false` | 🔴 **Never `true`.** 8 existing rows are blank; `required=true` would refuse the *next edit* of each of them — the "unguarded rule traps a record" failure `Broker_Lookup_Is_Off_Market_Only`'s header argues against. |
| `trackHistory` | `false` | matches every sibling on this object |
| `inlineHelpText` | *"The list price this sale is being marketed at. Enter it at Disposition Readiness — each broker's BOV Score compares their valuation against this number, and no score can be calculated until it is set."* | |
| `description` | *"Asking price for this sale, captured at Disposition Readiness. Feeds BOV_Submission__c.BOV_Score__c's value dimension; a blank or zero value makes every BOV score on this sale blank."* | 187 chars, under the 255 cap |

### 2.2 FLS — the grant matrix

| Permission set | `readable` | `editable` | Note |
|---|---|---|---|
| `DPEG_Disposition_Edit` | true | **true** | The analyst enters it |
| `DPEG_Disposition_View` | true | **false** | Read-only persona |
| `DPEG_Admin_Access` | — | — | ⚠ **No change.** Verified: it grants only 4 `Disposition__c` fields (`NDA_Count__c`, `Primary_NDA__c`, `Signed_NDA_Count__c`, `Wire_Verification_Completed__c`) and already does **not** grant `Disposition_Stage__c` or `Broker__c`, so it already cannot run `DispositionApprovalService.submitForApproval`. This item creates no new casualty there. |

🔴 **A Metadata-API-deployed field arrives with NO FLS for anyone, System Administrator included.**
The two permission-set edits must land **with or before** any `WITH USER_MODE` read that selects the
field, and before the FlexiPage. 🔴 **Diff both files against `HEAD` first — a `PermissionSet` deploy
replaces the whole `<fieldPermissions>` set.**

⚠ **The score formula does not need this grant.** Formula fields do not enforce FLS on the fields
they reference, so `BOV_Score__c` computes correctly for a user with no access to
`Asking_Price__c`. What *does* need the grant is the on-page display and the §2.4 pre-check.

### 2.3 Layout / FlexiPage placement

- **`layouts/Disposition__c-Disposition Layout.layout-meta.xml`** — add the field. Required: the
  classic layout still backs the New/Edit modal and the approval pages, so omitting it makes the
  field unenterable from the standard create path.
- **`flexipages/Disposition_Record_Page.flexipage-meta.xml`** — add a `fieldInstance` with
  `uiBehavior = none` to `Facet-0a494558-fee1-4b32-a27e-d8a2546e161e` (the right-hand Details
  column, alongside `Disposition_Stage__c`, `Broker__c`, `Selected_Broker__c`).
  🔴 **F-5 applies:** that facet lives inside `flexipage_fieldSection` (`Details`), whose
  `visibilityRule` at lines 773-795 is `Stage NE 'BOV Outreach' AND NE 'Active Listing' AND NE
  'Closing' AND NE 'Sale Closes'`. The field is therefore editable at `Disposition Readiness`
  (correct, per the confirmed requirement) and **invisible at BOV Outreach** (where the scores are
  read). See **Q-3**.
- 🔴 **FlexiPage deploy discipline** (this repo has two recorded incidents): deploy the FlexiPage
  **last**, check the per-component `"state"` in the dry-run — a component byte-identical to the live
  copy reports `"Unchanged"` and **skips validation entirely** — and **read the page back**, because
  a FlexiPage deploy can roll back on a design-time error and still report success.

### 2.4 The validation rule question — answer: **no VR, a service pre-check instead**

🔴 **F-4 in full.** A rule of the shape *"Asking Price must be set before leaving Disposition
Readiness"* fires on the stage-change save. The stage change out of `Disposition Readiness` is made
by `DispositionApprovalAdvanceQueueable` after the Sale Decision approval, via
`Database.update(..., SYSTEM_MODE)` — and `DispositionApprovalAdvanceService`'s own class header
states in terms:

> *"the Queueable writes the stage with ORDINARY `Database.update(..., SYSTEM_MODE)`, so **VALIDATION
> RULES STILL EVALUATE** (SYSTEM_MODE lifts CRUD and FLS and NEVER a rule)"*

and

> *"A REFUSAL LEAVES THE SEMAPHORE TRUE. THAT IS THE DESIGN, NOT A LEAK… any refusal — a validation
> rule … — leaves `Approval_Advance_Pending__c = true` and the stage where it was."*

So the VR's failure mode is: the approver clicks Approve, the approval **succeeds**, and the
disposition silently stays at `Disposition Readiness` with a stuck semaphore and **no message
anywhere**. That is the highest-severity risk in this whole document.

**Recommended instead:** a blank pre-check in
`DispositionApprovalService.submitForApproval`'s `STAGE_READINESS` branch, sitting beside the
existing `NO_BROKER_MESSAGE` and `WIRE_INCOMPLETE_MESSAGE` pre-checks that the class was built
around. It refuses **before** anything is approved, produces an authored message at the moment the
user acts, cannot strand a semaphore, and cannot trap an existing row.

- New constant, in that class's authored-message style (no field API names; names the fix):
  `'An asking price is required before the sale decision can be submitted. Enter the Asking Price on this disposition, then submit for approval.'`
- ⚠ Requires widening `DispositionSelector.selectApprovalContextById` (line 573-582) with
  `Asking_Price__c`. **That read is `WITH USER_MODE`, so widening it is an FLS change** — the two
  grants in §2.2 become *mandatory and blocking*, not merely nice. `DPEG_Admin_Access` is unaffected
  (§2.2).
- **Fallback if the user prefers a VR anyway:** it must carry the transition guard
  `AND(ISPICKVAL(PRIORVALUE(Disposition_Stage__c),'Disposition Readiness'), NOT(ISPICKVAL(Disposition_Stage__c,'Disposition Readiness')), ISBLANK(Asking_Price__c))`
  — which still does not solve F-4, only narrows what it traps. Say so out loud before shipping it.

### 2.5 What happens to the 8 existing dispositions

`Asking_Price__c` is blank on all of them → the score formula's guard returns `null` → **every BOV
submission on every existing disposition shows `—` in the Score column and a zero-width bar**, and
the three `ORDER BY … NULLS LAST` clauses have no key left (F-1a). This is *correct and visible*
rather than wrong-and-quiet, and it is the reason the formula returns `null` instead of 0. The
remedy is data entry, not code. **Update the seed scripts to set an asking price** (§1.8) so the demo
org does not present as broken.

### 2.6 Inventory — Item 2

| Type | File | Action |
|---|---|---|
| CustomField | `objects/Disposition__c/fields/Asking_Price__c.field-meta.xml` | **new** |
| PermissionSet | `DPEG_Disposition_Edit`, `DPEG_Disposition_View` | +1 `fieldPermissions` each |
| Layout | `layouts/Disposition__c-Disposition Layout.layout-meta.xml` | +1 field |
| FlexiPage | `flexipages/Disposition_Record_Page.flexipage-meta.xml` | +1 `fieldInstance` in `Facet-0a494558…` |
| Apex — Selector | `DispositionSelector.selectApprovalContextById` | +`Asking_Price__c` (only if the §2.4 pre-check is adopted) |
| Apex — Service | `DispositionApprovalService` | +1 constant, +1 pre-check in the `STAGE_READINESS` branch |
| Apex — Test | `DispositionApprovalServiceTest` | +1 refusal test, +1 happy-path with a price |
| Scripts | `seed-disposition*.apex`, `seed-disp0002.apex` | set `Asking_Price__c` |
| Validation Rule | — | **none recommended** (F-4) |

---

## 3 — Deal Summary matched to the Opportunity component

### 3.1 What actually differs (both files read in full)

| Aspect | `dealDocStatus` (Opportunity) | `dispositionDealSummary` (today) | Restyle target |
|---|---|---|---|
| Container | `<lightning-card icon-name="standard:document">` | hand-rolled `<div class="card">` + `<h2>` + `<p class="card-sub">` | 🔴 adopt `lightning-card` + `standard:document` |
| Per-row icon | tinted round chip, colour set via **inline `style` hex** on `lightning-icon` (`.html:15-17,43-45,71-73,…`) | bare `lightning-icon`, no chip, no colour | chip + colour, but via **CSS class + `--slds-c-icon-color-foreground-default`** on the wrapping span, **never** inline `style` |
| Row name | `<a class="doc-name" onclick={openNda}>` when present; `<span class="doc-name--muted">` when absent | plain `<span class="row-label">`, never a link | click-through when the record exists, muted otherwise |
| Pill | pale tint + dark text + inset 1px ring (`.css:82-116`) | **solid fill + white text** (`.css:126-165`) | soften to the `dealDocStatus` tint model, expressed in `--slds-g-*` |
| Divider | explicit `<div class="divider">` between rows | `border-bottom` on `.row` | either; keep the existing border (fewer nodes, same look) |
| Meta line | `parts.join('  ·  ')` — one line | `metaLines` array — N lines | keep the array (narrow column) |
| Empty state | per-row italic ("No NDA on this deal yet") | per-row italic (`row-hint`) — **already matches** | keep |
| **Unavailable state** | **does not exist** | `pill_blocked` + `row-hint_alert` | 🔴 **must survive** — see §3.2 |
| Rows | 6 (NDA, Underwriting, LOI, Development, Construction, Contract) | 3 (NDA, LOI, PSA) | stays 3 — **no Underwriting on a disposition** |
| Data source | `getDocStatus` wire | `getDealSummary` wire | unchanged |
| Record Ids in DTO | yes (`ndaId`, `loiId`, …) | 🔴 **NO** — `DispositionDealSummaryService.DealSummary` carries no Id members | **must be added** |

### 3.2 The three-state pill — the constraint that shapes the design

`dealDocStatus` has **two** row states (has / hasn't). `dispositionDealSummary` has **three**, and the
third exists because collapsing it hid a live provisioning gap for months
(`DispositionDealSummaryService.cls:35-48`). The restyle must therefore *add* a state to the
borrowed visual language, not inherit two and lose one:

| State | Pill text | Pill tone | Row name | Hint line |
|---|---|---|---|---|
| **Has record** | the status/stage value | mapped tone (`complete`/`progress`/`attention`/`neutral`) | **link**, brand colour | none |
| **Empty** | `No NDA` / `No LOI` / `No PSA` | `neutral` (grey tint) | muted, **not a link** | italic grey — *"No LOI on this sale yet"* |
| **Unavailable** | `Unavailable` | `blocked` — 🔴 the **only** red tone on the card, and the only one that keeps a filled/high-contrast treatment rather than a soft tint, so it never reads as "just another status" | muted, **not a link** (there is no Id to link to) | **non-italic, semibold, error colour** — *"Not readable with your current permissions — contact your administrator."* |

🔴 The precedence order in `buildRow` — `unavailable > exists > empty` (`dispositionDealSummary.js:196-244`)
— is load-bearing and must not be reordered by the restyle. A degraded row falling through to the
empty wording is the exact defect the card was built to expose.

### 3.3 Narrow-column constraints (~340px sidebar) — concrete

Content width ≈ 340px − 2 × `--slds-g-spacing-4` (1rem) ≈ **276px**. The `row-head` is
`display:flex; justify-content:space-between`. Icon chip (28px) + gap (8px) + label ("NDA") leaves
≈ 210px for the pill. Longest real pill strings, read from the tone maps:

- `Counter Received from Buyer` — 27 chars (`LOI_TONE`, `dispositionDealSummary.js:89`)
- `Ready for Execution` — 19 chars (`PSA_TONE`, line 108)
- `Countered by DPEG` — 17 chars

`.pill` currently sets `white-space: nowrap` (`.css:133`). At 0.625rem bold + `0.75rem` horizontal
padding, 27 characters ≈ **185px** — it *just* fits, with zero margin for a longer picklist value
added later. Required changes:

1. `.row-head { flex-wrap: wrap; }` — the pill drops to its own line rather than overflowing.
2. `.row-label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }` — `.row-left`
   already has `min-width: 0`, which is the half that makes ellipsis work; the label itself has no
   truncation today.
3. Keep `white-space: nowrap` **on the pill** (a wrapped two-line pill looks broken) and let it
   wrap to a new line instead, per (1).
4. The click-through link must not make the row taller: put the anchor on the existing
   `.row-label` span, not a new element.

### 3.4 Accessibility — two decisions the brief did not mention

🔴 **Do not copy `dealDocStatus`'s link pattern.** `<a class="doc-name" onclick={openNda}>` has **no
`href`**, so it is not keyboard-focusable and not announced as a link. This repo has an in-repo
correct precedent one file away: `bovComparisonMatrix.html:40` / `.js:275-278` —
`<a href={listUrl} onclick={viewAll}>` with `NavigationMixin.GenerateUrl` populating `href` and
`event.preventDefault()` in the handler. **Use that shape.**

⚠ `alternative-text={row.label}` on the `lightning-icon` (`dispositionDealSummary.html:24-28`)
currently duplicates the visible `{row.label}` text, so a screen reader says "NDA NDA". Adding a
coloured chip does not change that. Either set `alternative-text=""` (decorative, correct — the
visible label carries the meaning) **or** leave it and record why. ⚠ Check
`__tests__/dispositionDealSummary.test.js` first — this repo has a recorded incident where a
text→badge swap deleted accessible content a test already pinned.

### 3.5 Styling — the hard rule

🔴 **No inline `style`, no authored hex.** `dispositionDealSummary.css` is the repo's cleanest SLDS 2
file and its own header records three fixer-invisible traps measured on 2026-08-20:
`--slds-g-color-on-surface-1` is the **grey** one and `-3` is the darkest (the numbering reads like an
emphasis scale and is not); `--slds-g-color-disabled-container-1` is **white**; and
`--slds-g-spacing-px` **does not exist**. Fallback values must be regenerated with
`npx slds-linter lint --fix`, not hand-written.

For the per-row icon chip, set the colour on the **wrapping span** as a CSS custom property — custom
properties inherit into `lightning-icon`'s shadow tree:

```css
.row-icon        { display:inline-flex; align-items:center; justify-content:center;
                   width: var(--slds-g-sizing-8, 1.75rem); height: var(--slds-g-sizing-8, 1.75rem);
                   border-radius: var(--slds-g-radius-border-2, 0.5rem); flex: 0 0 auto; }
.row-icon_nda    { background: var(--slds-g-color-accent-container-2, …);
                   --slds-c-icon-color-foreground-default: var(--slds-g-color-accent-container-1, …); }
```

Soft-tint pills (replacing today's solid fills) should use the `*-container-2`/`*-base-*` family
rather than `*-container-1`, then be re-run through the fixer to get canonical fallbacks.

### 3.6 Inventory — Item 3

**Apex by layer**

| Layer | Class | Change |
|---|---|---|
| Service | `DispositionDealSummaryService` | +3 DTO members `ndaId`, `loiId`, `psaId` (`@AuraEnabled public String`), populated in `applyLatestNda` / `applyLatestLoi` / `applyLatestPsa`. **No new query, no new catch.** |
| Selector | `NdaSelector.selectLatestSummaryByDispositionId`, `LoiSelector.selectLatestByDispositionId`, `ContractReviewSelector.selectLatestByDispositionId` | confirm `Id` is in each SELECT list (it is required for `LIMIT 1`-shaped reads but **verify**). ⚠ Adding `Id` to a `WITH USER_MODE` SELECT is **FLS-free** — `Id` is always accessible — so this needs **no** permission-set change. |
| Controller | `DispositionDealSummaryController` | none |
| Test | `DispositionDealSummaryServiceTest` | +assertions that each Id is populated when the child exists and **null when the row is `unavailable`** (a degraded row must not leak an Id) |

**LWC**

| File | Change |
|---|---|
| `dispositionDealSummary.html` | wrap in `<lightning-card icon-name="standard:document">`; icon chip span; `<a href>`/`<span>` split on the row label; keep the `hintText` block and its two classes |
| `dispositionDealSummary.js` | `+NavigationMixin`; `+recordUrl` per row via `NavigationMixin.GenerateUrl` (async, so hold URLs in a tracked map); `+hasLink`; `+iconClass` per row; **do not touch `buildRow`'s precedence order** |
| `dispositionDealSummary.css` | soft-tint pills, icon chips, `flex-wrap`, label ellipsis — all `--slds-g-*`, fixer-regenerated |
| `__tests__/dispositionDealSummary.test.js` | update selectors; keep/extend the unavailable-vs-empty assertions; `@sa11y/jest` matcher per `ARCHITECTURE.md` §5 |
| `js-meta.xml` | unchanged (`<description>` also has a **255-char cap**, and only a deploy catches a breach) |

**FlexiPage:** unchanged — `dispositionDealSummary` stays first in `sidebar`, ungated
(`Disposition_Record_Page.flexipage-meta.xml:880-948`). 🔴 **Do not add a
`componentInstanceProperties`/`recordId` block** — that exact binding failed with
*"Field recordId does not exist"* in this tranche; `recordId` is an implicit `lightning__RecordPage`
input.

---

## 4 — "Select Broker" button and picker

### 4.1 The convergence decision: **one server mechanism, one extra client entry point**

`BovSubmissionService.replaceSelectedBroker` **already handles first appointment**. Its own javadoc
(lines 144-147):

> *"A DISPOSITION WITH NO CURRENT INCUMBENT IS NOT AN ERROR. 'Replace' degrades cleanly to 'appoint':
> nothing to demote, the challenger is promoted, the broker name is stamped."*

and the history insert nulls `Outgoing_BOV_Submission__c` / `Outgoing_Broker__c` /
`Outgoing_Broker_Firm__c` in that case (lines 279-290). **So there is no second server path to
build, and building one would be the "two mechanisms that can disagree" failure the brief warns
about.** Answer to *"what happens when someone uses it on a disposition that already has a Selected
broker"*: it **is** a replacement, executed by the same code, with the same demotion, the same
approval revocation and the same history row — because it is literally the same method.

**Client shape:**

- `bovComparisonMatrix` gains a second header button in the existing `lightning-button-group`
  (`.html:8-24`). Exactly **one** of the two renders:
  - `canSelectBroker` → `this._selected === undefined` (new getter) → **"Select Broker"**
  - `canReplaceBroker` → `this._selected !== undefined` (exists, `.js:131-133`) → **"Replace Broker"**
  ⚠ `canReplaceBroker`'s own comment says the test is deliberately *"some row is Selected"*, not
  *"exactly one"*, so that a duplicate-Selected data defect does not hide the button that repairs it.
  Keep that; `canSelectBroker` is simply its negation and inherits the property.
- **One modal bundle, not two.** Reuse `bovReplaceBrokerModal` with a new `@api isFirstAppointment`
  that switches the header label, the intro copy and the confirm-button label. Two bundles would
  drift, and the modal's non-obvious contracts (`getPicklistValues` sourcing, block-don't-degrade on
  a failed picklist read, "the returned message is the product, not a receipt", keeping the modal
  open on failure) would need to be duplicated verbatim.
- `_backupOptions` (`.js:140-147`) filters `isSelected !== true` — on a disposition with no
  incumbent that is **every** submission, which is exactly right. No change.
- The picker must show scores: add the score to each option label, e.g.
  `` `${brokerFirm} — ${formatMillions(bovAmount)} · Score ${score ?? '—'}` ``. This is a one-line
  change in `_backupOptions`; the data is already in the payload (`BovRow.bovScore`). ⚠ After Item 1
  the score is `null` on any sale without an asking price, so the `?? '—'` is required, not defensive.

### 4.2 History on a first appointment — **yes**, and it forces a picklist decision

The service writes the history row unconditionally, so a first appointment already produces one. But
**every value in `BOV_Broker_Change__c.Reason__c` presupposes a predecessor**: `Performance Issue`,
`Better BOV Received`, `Broker Withdrew`, `Company Decision`, `Other`. A first appointment can only
be logged as "Other", which is the un-attributed row the workstream exists to prevent.

🔴 **This is the moment to close a flagged-open decision.** The field's own XML says:

> *"🔴 OPEN DECISION - THE USER HAS NOT CONFIRMED THIS VALUE SET (design D4.2 / O-2) … flag it again
> before this deploys anywhere but a dry run."*

**Recommendation: add `Initial Appointment` as a sixth value** and have the modal preselect it (and
optionally hide the combobox) when `isFirstAppointment` is true. ⚠ `Reason__c` is `restricted=true`,
so the value must exist in metadata before any code sends it, and **restricted picklists ARE enforced
by Apex DML** in this org — an off-list value throws `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`. See
**Q-4**.

**Rejected alternative:** making `reason` optional when there is no incumbent. The service's own
`REASON_REQUIRED_MESSAGE` rationale forbids it — *"A history row with a blank `Reason__c` is the one
row this whole workstream exists to prevent."*

### 4.3 The success message

`REPLACED_MESSAGE` is `'Broker replaced. The new broker must be approved before the sale can
proceed.'` On a first appointment "replaced" is wrong, but the second sentence stays true
(`Approval_Status__c` is cleared on the challenger either way, lines 224-227).

**Recommendation:** the service returns one of two authored strings depending on `outgoing == null`:
- appoint: `'Broker appointed. The broker must be approved before the sale can proceed.'`
- replace: unchanged.

🔴 The modal must **not** re-author this (`bovReplaceBrokerModal.js:28-32` — *"DO NOT RE-AUTHOR THAT
WARNING HERE"*). The branch belongs in the service.

### 4.4 Inventory — Item 4

| Layer | File | Change |
|---|---|---|
| CustomField | `objects/BOV_Broker_Change__c/fields/Reason__c.field-meta.xml` | +`Initial Appointment`; **remove the "OPEN DECISION" block once confirmed** (Q-4) |
| Service | `BovSubmissionService` | +`APPOINTED_MESSAGE`; branch the return on `outgoing == null`. **No new method, no new signature.** |
| Controller | `BovController` | **none** |
| Selector | — | **none** |
| Test | `BovSubmissionServiceTest` | +no-incumbent appointment writes a history row with null Outgoing columns and returns the appoint message |
| Test support | `TestDataFactory.createBovBrokerChanges` | ⚠ hardcodes a `Reason__c` value — confirm the added value does not disturb it |
| LWC | `bovComparisonMatrix.html` | +`<lightning-button class="matrix-select" label="Select Broker">` inside the existing button group, `lwc:if={canSelectBroker}` |
| LWC | `bovComparisonMatrix.js` | +`canSelectBroker`; +`handleSelectBroker` (same body as `handleReplaceBroker`, different modal props + non-warning toast variant); score in `_backupOptions` labels |
| LWC | `bovReplaceBrokerModal.{js,html}` | +`@api isFirstAppointment`; conditional labels/copy; preselect the reason |
| Jest | `bovComparisonMatrix.test.js`, `bovReplaceBrokerModal.test.js` | exactly-one-button-renders; first-appointment path |

⚠ `handleSelectBroker` must keep the two non-obvious properties of `handleReplaceBroker`
(`.js:219-262`): the **promise is the channel** (a `LightningModal` renders in the platform layer and
a bubbling `CustomEvent` has no path back), and `refreshApex(this._wired)` requires the
**un-destructured** wire result. A "tidy" to `wired({data, error})` compiles, passes every render
test, and silently makes the refresh a no-op.

---

## 5 — "Submit Selected Broker" requires exactly one Selected

### 5.1 Placement — and the blocker nobody has mentioned

Guard belongs in **`DispositionApprovalService.submitForApproval`, the `STAGE_BOV_OUTREACH` branch**
(lines 254-261). The zero-Selected path already exists and needs no change:

```apex
BOV_Submission__c selected = BovSubmissionSelector.selectSelectedByDispositionId(disposition.Id);
if (selected == null) { throw new ApprovalException(NO_SELECTED_BOV_MESSAGE); }
```

🔴 **But `selectSelectedByDispositionId` carries `LIMIT 1` (line 134) — it structurally cannot see a
second Selected row.** Its own header even documents the resulting silent wrong answer:
*"If two rows are ever Selected the highest-scoring one wins here."* So the ">1" branch is not an
`if`; it is a selector change.

**Recommended change:** drop the `LIMIT 1`, return `List<BOV_Submission__c>`, and repoint the **one**
caller. Grep confirms the method has exactly two references: `DispositionApprovalService.cls:256` and
`BovSubmissionSelectorTest.cls:116,135,144`. Keep the `ORDER BY BOV_Score__c DESC NULLS LAST`
(+ the new `CreatedDate ASC, Id ASC` from F-1a) for determinism. Keep `WITH USER_MODE` — this read is
one a human explicitly asked for by clicking Submit, so `ARCHITECTURE.md` §2's automation-path
exception does **not** apply. Do **not** reach for the existing `selectSelectedByDispositionIds(Set<Id>)`
just because it has no `LIMIT`: it is `WITH SYSTEM_MODE`, and its justification is explicitly *"the
CALLER, not the field"* — a trigger. Borrowing it here would invalidate its own header.

Also delete the now-obsolete *"the highest-scoring one wins"* paragraph from the method's javadoc
rather than leaving it to contradict the new behaviour.

### 5.2 Exact user-facing messages

| Case | Message |
|---|---|
| **Zero Selected** | **unchanged** — `'No broker is marked Selected yet. Choose a broker in the BOV comparison matrix, then submit for approval.'` |
| **More than one Selected** | **new** — `'More than one broker response is marked Selected on this disposition, and exactly one is required. Set all but the appointed broker to Backup in the BOV comparison matrix, then submit for approval.'` |

Both reach the user verbatim: `DispositionApprovalController` catch #2 surfaces `ApprovalException`
unmodified (lines 69-73), and the class header calls that ordering load-bearing.

⚠ Style note taken from the class's own convention: name the on-screen **label** and the **fix**,
never a field API name. `Selected` and `Backup` are the two on-screen picklist labels
(`Submission_Status__c` is `restricted` to exactly those two), so quoting them is correct.

### 5.3 Honest scope note

🔴 **The ">1" branch is unreachable through the UI as of 2026-08-20.**
`BovSubmissionSelectionGuardService` refuses any save that would create a second Selected row (§7).
This guard is therefore a **backstop for data that predates the guard, or that arrives via an
undelete** (§7 R-1) — worth having, but the user should not expect to see it fire. Say so in the
method's javadoc so a future reader does not conclude it is dead code and delete it.

### 5.4 Inventory — Item 5

| Layer | File | Change |
|---|---|---|
| Selector | `BovSubmissionSelector.selectSelectedByDispositionId` | drop `LIMIT 1`; return `List<>`; add secondary sort; rewrite the "highest-scoring wins" paragraph |
| Service | `DispositionApprovalService` | +`MULTIPLE_SELECTED_BOV_MESSAGE`; three-way branch on `size()` |
| Controller | `DispositionApprovalController` | **none** |
| Test | `BovSubmissionSelectorTest` | 3 methods repointed to the `List` signature; +a two-Selected fixture |
| Test | `DispositionApprovalServiceTest` | +>1 refusal test. ⚠ Building a two-Selected fixture now requires **bypassing the trigger guard** — the guard refuses it. Insert one Selected row, then use `Test.startTest()` + a second insert and assert the guard's own message, **or** construct the two-Selected state before the guard was live (impossible). Realistic approach: unit-test the branch by calling the selector's result path directly, and pin the guard's refusal separately. Flag this to the unit-testing agent — it is the same reason `BovSubmissionSelectionGuardTest` deliberately builds no pre-existing pair (its header, lines 80-84). |
| Metadata | `quickActions/Disposition__c.Submit_Selected_Broker.quickAction-meta.xml` | **none** — it is a bare LWC quick action; the visibility rule lives in the FlexiPage (lines 291-306) and is unchanged |

---

## 6 — Broker Firm in the comparison matrix

### 🔴 Already built. Do not build it again.

`lwc/bovComparisonMatrix/bovComparisonMatrix.js:15-32` — the current column set:

| # | Label | Bound to | Source field |
|---|---|---|---|
| 1 | **Broker Firm** | `recordUrl` (url) with `label: { fieldName: 'brokerFirm' }` | **`BOV_Submission__c.Broker_Firm__c`** (`BovController.cls:80`) |
| 2 | Contact | `contactName` | `Contact_Name__c` |
| 3 | Valuation | `bovAmountLabel` | `BOV_Amount__c` |
| 4 | Days to Mkt | `daysLabel` | `Days_To_Market__c` |
| 5 | Cap Rate | `capRateLabel` | `Cap_Rate__c` |
| 6 | Score | `scoreText` (custom `progress` type) | `BOV_Score__c` |
| 7 | Status | `status` (custom `pill` type) | `Submission_Status__c` |

### Which field carries the firm — checked, not assumed

| Field | Type | Label | Content |
|---|---|---|---|
| `Broker_Firm__c` | Text(255) | **"Broker Firm"** | 🔴 **the firm.** Stamped from `Contact.Broker_Firm__c` by `BovSubmissionBrokerStampService` (its header: *"`Broker_Firm__c` IS `Contact.Broker_Firm__c`"*) |
| `Contact_Name__c` | Text(255) | "Contact" | the **person** — `Contact.Name` |
| `Broker_Display__c` | Text formula | **"Broker"** | `Broker_Firm__c & " — " & Contact_Name__c` — a **combined** display string, not the firm |

The label collision the brief flags is real (`Broker_Display__c` is labelled "Broker",
`Contact_Name__c` is labelled "Contact") — but the matrix does **not** use `Broker_Display__c`. It
already shows the firm and the contact as two separate, correctly-sourced columns.

### What the ask probably means — **Q-5, blocking for this item only**

Three candidate readings, none of which I can resolve from files:
1. The user was looking at a **different surface** — the `BOV Submission Layout`, the
   `bovOutreach` card, or the standard list view — where the firm may genuinely be absent.
2. The firm column **renders blank on their data**. That would be a *data* problem, not a column
   problem: `Broker_Firm__c` is now derived from `Contact.Broker_Firm__c`, so a broker Contact with
   a blank firm produces a blank cell (rendered `'—'`, `.js:97`). ⚠ `Broker_Display__c`'s formula
   `Broker_Firm__c & " — " & Contact_Name__c` would render a bare `" — Jane Doe"` in that case,
   which is a real cosmetic defect worth checking.
3. The user wants the **combined** `Broker_Display__c` in place of the two separate columns.

### If a column *is* added — how it fits

`c-list-datatable` is a `lightning/datatable` subclass adding `pill` and `progress` cell types
(`lwc/listDatatable/listDatatable.js`); it is used with `column-widths-mode="auto"`. Adding an 8th
column narrows the rest, and the **Score column has a hard floor** — its `wrapStyle` sets
`min-width:140px` and its `trackStyle` a 90px bar (`.js:24-26`). So an 8th column comes out of the
text columns.

**Recommendation if reading (3) is right:** *replace* columns 1 + 2 with a single
`Broker_Display__c` column (net **−1** column, more room for everything) rather than adding a
9th field. **Do not add a column without resolving Q-5** — the most likely outcome is that the
correct change is zero columns.

---

## 7 — Verify, do not rebuild: the single-Selected guard

### Verdict: **ALREADY SATISFIED.** Do not design a second mechanism.

**Wiring, verified:**
- `triggers/BovSubmissionTrigger.trigger:51` — `(before insert, before update, after update)`
- `BovSubmissionTriggerHandler.beforeInsert()` (lines 172-181) → `enforceSingleSelected(newList, null)`
- `BovSubmissionTriggerHandler.beforeUpdate()` (lines 197-206) → `enforceSingleSelected(newList, oldMap)`
- One query, no DML: `BovSubmissionSelector.selectSelectedByDispositionIds(Set<Id>)`, `WITH SYSTEM_MODE`,
  **no `LIMIT`** (deliberately — *"a `LIMIT` would cap the count and under-report a pre-existing
  duplicate, which is the one state this read must be able to see"*).

**Logic, verified line by line** (`BovSubmissionSelectionGuardService.cls:180-261`):
- Three passes: classify in memory → one query for the whole chunk → judge.
- In-memory values of rows present in `Trigger.new` **supersede** their committed values
  (`incomingIds` skip at line 240) — this is what lets `replaceSelectedBroker`'s demote-and-promote
  pass in a single `Database.update`.
- Reparenting extension: an already-Selected row moved onto an occupied disposition **is** caught
  (`prior.Disposition__c == submission.Disposition__c` at line 220).
- `addError` is field-level on `Submission_Status__c`, so it bubbles to the page error area when the
  field is off the layout **and** returns as a row error in the Bulk API.

**Does the zero-query fast path skip a case it should catch? No.** It returns only when
`becomingSelected` is empty — i.e. no row is being inserted-as or changed-to Selected **on that
disposition**. Every save that could *create* a second Selected row makes some row become Selected
by definition, so the fast path is exact rather than conservative. The three consequences the header
claims (an already-Selected row saved for another reason is never blocked; any save that *reduces*
the count is always permitted; a pre-existing pair is never frozen) all fall out of that same test.

**Test coverage:** `BovSubmissionSelectionGuardTest` — 17 methods, `BULK_N = 251`, including
`existingReplaceSelectedBrokerService_stillSucceeds` (the falsifier the guard's header names as
"must never be deleted"), `demoteAndPromoteInOneSave_isPermitted`, four 251-row cases (one-query
budget, zero-cost fast path, all-save, all-reject), and both reparenting directions.

### Residuals — real, named, none of which justifies a second mechanism

| # | Residual | Severity | Evidence |
|---|---|---|---|
| **R-1** | 🔴 **`after undelete` is not wired, and Salesforce has no *before* undelete context at all.** Restoring a previously-`Selected` submission from the Recycle Bin onto a disposition that has since appointed another broker creates a second Selected row **no guard sees**. Reachability is limited: `DPEG_Disposition_Edit`'s own description is *"Create/Read/Edit (**no Delete**) on the 5 DISP objects"*, so delete+undelete needs an admin. **Fix if wanted:** add `after undelete` to the trigger + an `afterUndelete()` override; `addError` in an after-undelete context **does** block the undelete. **Not in the confirmed six items — see Q-6, do not fold it in silently.** | Medium likelihood-weighted | `BovSubmissionTrigger.trigger:51`; `DPEG_Disposition_Edit` `<description>` |
| **R-2** | ⚠ **Sharing fail-open.** `SYSTEM_MODE` lifts CRUD and FLS and **never** sharing. A Selected sibling the running user cannot see is absent from the count, so the guard **permits** the second row rather than blocking a legitimate one. Both the guard's header (126-136) and the selector's (242-249) name this and bound it with *"both `DPEG_Disposition_Edit` and `DPEG_Disposition_View` carry `viewAllRecords = true` on the disposition child objects"*. 🔴 **I read that claim in two class headers; I did not verify it in the permission set files.** See V-3. | Low, if `viewAllRecords` holds | class headers only |
| **R-3** | `addError` on a row inside `Database.insert/update(list, false)` fails **that row** and lets the transaction continue — a bulk loader gets a silent per-row rejection, not an exception. **This is safe**: the invariant is preserved because the row does not save. Named so nobody reports it as an evasion. | None | platform behaviour |
| **R-4** | No test constructs a genuine **pre-existing** double-Selected pair. **Deliberate**, argued at lines 80-84: once the guard is live that state is unreachable and the fast path never evaluates it; a `@TestVisible` bypass switch would put a production-reachable escape hatch in the class to prove a branch that does not exist. Correct call — but it means §5's ">1" backstop has no natural fixture (see §5.4). | None | guard header |

### Work Item 7 justifies: **zero**, plus one optional follow-up

The single-Selected requirement is met. The only adjacent work is §5's submit-time backstop (a
*reporting* guard on a different surface, not a second enforcer) and, if the user wants it, R-1's
undelete context as a **separately confirmed** item.

---

## 8 — Consolidated sequencing

```
GATE 0  Dry-run proof: Number→Formula is refused (V-1); formula compiled size < 3,900 (V-2).
        Check per-component "state" — an "Unchanged" component SKIPS validation entirely.
   │
   ▼
W1  Disposition__c.Asking_Price__c  +  2 permission-set grants  (diff both vs HEAD first)
   │   then: Disposition Layout, then FlexiPage (last, read it back)
   ▼
W2  Sever every BOV_Score__c Apex/LWC/script/permset reference          ← nothing compiles against it
   ▼
W3  destructiveChanges: delete BOV_Score__c (Number)
   ▼
W4  🔴 MANUAL, IRREVERSIBLE: Setup → Deleted Fields → ERASE BOV_Score__c. Re-read the list to confirm.
   ▼
W5  Create BOV_Score__c (formula) + 2 grants (editable=false) + restore Apex/LWC/tests/scripts
   │   incl. the F-1a secondary sort on all three ORDER BY clauses
   ▼
W6  Items 3, 4, 5, 6 — independent of each other, but ALL downstream of W5:
      Item 3 (Deal Summary restyle)  — no dependency on the score at all; can run in parallel from W1
      Item 4 (Select Broker)         — needs Reason__c's new value (Q-4) + the score for the picker labels
      Item 5 (exactly-one guard)     — needs the selector's LIMIT 1 removed; touches the same
                                       BovSubmissionSelector file as W2/W5 → SEQUENCE, do not parallelise
      Item 6                         — BLOCKED on Q-5; likely zero work
   ▼
W7  Comment corrections (bovAddResponseModal, BOV Submission Layout) + RunLocalTests
```

**Hard dependencies:**
- Item 1 **⇐** Item 2 (the formula references `Disposition__r.Asking_Price__c`).
- Item 5 **⇐** Item 1 Wave 5 — both edit `BovSubmissionSelector`; W2's temporary ORDER BY strip and
  W5's restore must not collide with §5.1's `LIMIT 1` removal. **One agent, one file, in order.**
- Item 4 **⇐** `Reason__c`'s value-set decision (Q-4) — the picklist is `restricted` and DML-enforced.
- Item 3 is **independent** of all of the above.
- ⚠ **Concurrent sessions share this working tree** (measured on this repo, 2026-08-16). Four seed
  scripts are already modified-uncommitted. **Diff every shared hub file — the two permission sets and
  `Disposition_Record_Page.flexipage-meta.xml` — against `HEAD` immediately before deploying**, or the
  deploy will carry another feature's undeployed field.

---

## 9 — Risk register

| ID | Risk | Sev | Where | Mitigation |
|---|---|---|---|---|
| **R1** | `TestDataFactory` + 2 test classes + 4 seed scripts **assign** `BOV_Score__c`; a formula is not writeable → suite-wide compile failure → every `RunLocalTests` deploy fails | 🔴 **Critical** | F-1, §1.2 | Wave 2 strips all assignments before the field changes shape |
| **R2** | A blank-Asking-Price validation rule silently strands every approved Sale Decision at `Disposition Readiness` with `Approval_Advance_Pending__c = true` and **no error to the approver** | 🔴 **Critical** | F-4, §2.4 | Ship a service pre-check, not a VR |
| **R3** | `<formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>` makes a blank `Days_To_Market__c` (0 days) and a blank `Commission_Rate__c` (0 %) score a **perfect 20/20** | 🔴 High | §1.5 | `BlankAsBlank` **plus** an explicit `ISBLANK` guard opening every dimension |
| **R4** | All 8 existing dispositions score `null` → three `ORDER BY … DESC NULLS LAST` clauses lose their only sort key → the matrix reshuffles between page loads | 🔴 High | F-1a | Add `, CreatedDate ASC, Id ASC` to all three ORDER BY clauses in the same change |
| **R5** | The Wave-4 **Erase** is manual and irreversible; skipping it makes Wave 5 fail with a duplicate-name error, and the codebase is mid-strip at that point | 🔴 High | §1.3, §1.4 | Explicit gate; re-read the Deleted Fields list; Option B removes the gate entirely |
| **R6** | A `PermissionSet` deploy **replaces** the file's entire `<fieldPermissions>` set — three permission-set edits are in flight here | 🔴 High | §1.4, §2.2 | Diff each vs `HEAD` before every deploy |
| **R7** | `editable=true` on a formula field is a **deploy error**; `DPEG_Disposition_Edit:1182-1186` currently says `true` | 🔴 High | §1.2 | Flip to `false` in the same wave as the formula |
| **R8** | Formula **compiled** size exceeds 3,900 characters — `Disposition__r.Asking_Price__c` appears **7 times** and spanning references expand heavily | ⚠ Medium | §1.5 | Prove by dry-run (V-2). Fallback: collapse the Value dimension to 3 bands (20/12/0), taking spanning refs 7 → 4. ⚠ Moving the ratio into a *helper formula field* does **not** help — a formula referencing a formula is **inlined** at compile |
| **R9** | `Asking_Price__c` is invisible at `BOV Outreach` (the Details section's stage rule), so an analyst reading a wrong score cannot see or fix the input | ⚠ Medium | F-5, §2.3 | Q-3 |
| **R10** | Copying `dealDocStatus`'s `<a onclick>` with no `href` introduces a keyboard/screen-reader regression into a currently-clean bundle | ⚠ Medium | §3.4 | Use `bovComparisonMatrix.viewAll`'s `href` + `GenerateUrl` + `preventDefault` shape |
| **R11** | The restyle collapses "unavailable" into "empty", re-hiding the provisioning gap the card was built to expose | ⚠ Medium | §3.2 | Keep `buildRow`'s `unavailable > exists > empty` precedence and the three-state pill table; keep the Jest assertions |
| **R12** | The 27-character pill `Counter Received from Buyer` overflows a ~276px content width with `white-space: nowrap` | ⚠ Medium | §3.3 | `.row-head { flex-wrap: wrap }` + label ellipsis |
| **R13** | A first appointment logs `Reason__c = 'Other'` because every existing value presupposes a predecessor → the un-attributed history row Workstream B exists to prevent | ⚠ Medium | §4.2 | Add `Initial Appointment` (Q-4) |
| **R14** | R-1: an `after undelete` restore of a `Selected` submission evades the guard entirely | ⚠ Medium | §7 R-1 | Q-6 — separate, user-confirmed item |
| **R15** | `BovSubmissionSelector` is edited by Items 1 and 5 in overlapping waves; the file is also the home of three ORDER BY clauses being changed for F-1a | ⚠ Medium | §8 | Single owner, strict sequence |
| **R16** | A FlexiPage deploy can roll back on a design-time error **and report success**; a dry-run skips validation entirely for any component reporting `"state": "Unchanged"` | ⚠ Medium | §2.3 | Deploy FlexiPage last, alone; check per-component `state`; read the page back |
| **R17** | Four seed scripts are **uncommitted** in the working tree, and concurrent sessions share it | ⚠ Medium | §8 | Commit/stash before editing; diff hub files vs `HEAD` at deploy time |
| **R18** | Legacy BOV rows created before the layout was made Required can carry multiple blank dimensions, producing a low score indistinguishable from a poor broker | Low | §1.6 | Named in the field description; masked today because those rows also score `null` |
| **R19** | Retrieving after this work restores ~35 profile `BOV_Score__c` grants and can re-add deleted picklist values (a retrieve **unions** local and remote values) | Low | §1.2 | `profiles/**` is force-ignored so no deploy risk; strip after any retrieve |
| **R20** | `bovAddResponseModal` offers `Submission_Status__c` as an editable input, so a user *can* attempt to create a row straight into `Selected`. The guard refuses it correctly — but the refusal arrives as a platform error inside a `lightning-record-edit-form`, which is a poor UX for what is now a supported first-appointment flow | Low | §4.1, `bovAddResponseModal.html:131-144` | Optional: drop the field from the modal once "Select Broker" exists. **Not in scope — flag only.** |

---

## 10 — Could not verify — must be checked in org

🔴 This agent has **no `salesforce-api-context` MCP, no `sf` CLI and no org access**. The following
must be resolved by `salesforce-admin` / `salesforce-devops` before any of this is committed to.
Per `.claude/rules/salesforce-global-rule.md`, each needs a loaded per-type skill **and** a real MCP
attempt recorded as `mcp=complete` or `mcp=unavailable`.

| ID | To verify | Why it is blocking | Protocol |
|---|---|---|---|
| **V-1** | That the Metadata API **refuses** a Number→Formula conversion on `BOV_Submission__c.BOV_Score__c` in *this* org | The entire 6-wave sequence exists only because conversion is impossible. If it is possible, waves 2-4 vanish | **Check-only dry-run** on that one field. A green result is *not* proof it worked — read the field back and confirm `calculatedFormula` is populated |
| **V-2** | The formula's **compiled** character count vs the 3,900 cap | R8 | Deploy the field alone, check-only, and read the error text. Have the 3-band fallback ready |
| **V-3** | That `DPEG_Disposition_Edit` and `DPEG_Disposition_View` really carry `viewAllRecords = true` on `BOV_Submission__c` | The whole bound on §7 R-2's sharing fail-open rests on this. I read the claim in **two class headers only** — and this repo has a documented incident where a field header's confident prose sat directly above XML that contradicted it | Read both `<objectPermissions>` blocks directly |
| **V-4** | That `Id` is in the SELECT list of `NdaSelector.selectLatestSummaryByDispositionId`, `LoiSelector.selectLatestByDispositionId`, `ContractReviewSelector.selectLatestByDispositionId` | Item 3's click-through needs it | Read the three methods |
| **V-5** | The current `editable` value on `DPEG_Disposition_View:474` (`BOV_Score__c`) | R7 applies to both sets | Read the block |
| **V-6** | Whether the 8 live dispositions really hold null `Asking_Price__c` and whether their seeded `BOV_Score__c` values matter to anyone (a report, a dashboard) | The Erase is irreversible. ⚠ **Reports do not block field deletion in this org and fail silently** | `SELECT COUNT(Id) FROM Disposition__c`; grep `reports/` and `dashboards/` for `BOV_Score__c` |
| **V-7** | Whether the org is **multi-currency** | Cross-object Currency arithmetic in a formula is refused in a multi-currency org | `sf org display` / describe |
| **V-8** | The exact XML shape for a Number **formula** field's `<formulaTreatBlanksAs>` at API 67.0 | I am copying `Disposition__c.Days_On_Market__c` as the in-repo precedent, which is a legitimate basis — but it uses `BlankAsZero` and I am proposing `BlankAsBlank` | Confirm the enum value spelling via the CustomField metadata type; a bad enum fails the deploy loudly, which is the safe direction |

---

## 11 — Open questions (user decisions — **separate from everything above**)

| ID | Question | Recommendation |
|---|---|---|
| **Q-1** | `Hist_Success_Rate__c` is the **only** genuinely optional score input (the other four are already Required on the layout and/or by a validation rule). Should a blank track record (a) score **0**, or (b) make `Hist_Success_Rate__c` **required** on the layout and in `bovAddResponseModal` so it can never be blank? | **(b)** — 4 of 5 inputs are already mandatory; consistency is cheaper than a special case, and it closes the brief's "40 from blanks" concern entirely for new rows. Legacy rows are unaffected either way. |
| **Q-2** | Item 1 API name: **reuse `BOV_Score__c`** (5 waves, one manual irreversible Erase, a window with no score on the matrix) or **a new API name** (2 waves, no manual gate, a dead Number field left behind)? | **Reuse.** No production data at risk, `BOV_Score__c` is the convention-correct name, and the org already has a scheduled manual Setup cleanup wave to attach the Erase to. |
| **Q-3** | `Asking_Price__c` will be **invisible at `BOV Outreach`** because the Details section is stage-gated (F-5). Accept, or surface it read-only somewhere visible at BOV Outreach? | **Accept for this tranche.** The alternatives are a new ungated FlexiPage element or an `lwc/dispositionMain` change — neither was requested. Record it in the field's help text so the analyst knows where to find it. |
| **Q-4** | `BOV_Broker_Change__c.Reason__c` is still flagged **🔴 OPEN — user has not confirmed the value set** in its own XML. Item 4 forces the issue: a first appointment has no fitting value. Confirm the five existing values **and** add `Initial Appointment`? | **Yes to both**, and remove the OPEN DECISION block once confirmed. ⚠ `TestDataFactory.createBovBrokerChanges` hardcodes one of the values — a relabel breaks the fixture, not just a report. |
| **Q-5** | 🔴 **Item 6 blocker.** The matrix already shows `Broker_Firm__c` as its first column and as the row link. Which is the real ask: (1) a different surface, (2) the column renders blank on your data, or (3) you want the combined `Broker_Display__c` ("Firm — Person") instead of the separate Firm and Contact columns? | Cannot proceed on Item 6 without this. If **(3)**, replace columns 1+2 with one — a net *reduction*. If **(2)**, it is a `Contact.Broker_Firm__c` data gap, not an LWC change. |
| **Q-6** | §7 R-1: the guard is not wired to `after undelete`, so restoring a deleted `Selected` submission can create a second one. Add the context (a small, contained change), or accept the residual? | Accept for now — no persona holds Delete on `BOV_Submission__c`. **Raise it as its own item** rather than folding it into these six. |
| **Q-7** | Item 4's first-appointment success message: should the service return a distinct *"Broker appointed…"* string, or reuse *"Broker replaced…"*? | **Distinct string, authored in the service.** The modal must not re-author it (its own header forbids it). |

---

## 12 — Rules-conformance notes for the implementing agents

- **`.claude/rules/apex-layering-rule.md`** — every change above keeps SOQL in selectors
  (§5.1 changes a selector, not a service), keeps controllers thin (§3's DTO widening is in the
  service), and adds **no** Domain-layer SOQL. `BovSubmissionSelectionGuardService` is correctly a
  Service, not a Domain class, precisely because it needs a sibling read.
- **`.claude/rules/bulk-test-rule.md`** — none of this work adds a trigger path. The guard's 251-record
  tests already exist and must not be weakened. `BovSubmissionService.replaceSelectedBroker` keeps its
  per-transaction-singleton exemption (its header already records the reasoning so review does not
  re-demand 251); §4 adds no loop, so the exemption survives.
- **`.claude/rules/content-publication-rule.md`** — not engaged; no `ContentVersion` / `ContentNote` /
  `ContentDocument` anywhere in this scope.
- **`.claude/rules/invocable-rule.md`** — not engaged; no `@InvocableMethod` in scope.
- **`.claude/rules/salesforce-global-rule.md`** — per-type skill load + a real
  `salesforce-api-context` attempt is required for **CustomField**, **PermissionSet**, **Layout**,
  **FlexiPage** and **CustomObject/picklist** before any file is written. This design agent made no
  MCP attempt (it has no such tools); record `mcp=complete|unavailable` per type at implementation time.
- **`ARCHITECTURE.md` §1** — `Asking_Price__c` (Currency, industry term) and `BOV_Score__c`
  (Number, `_Score__c` suffix) both conform. No team-wide field prefix applies.
- **`ARCHITECTURE.md` §2** — §5.1 deliberately keeps `WITH USER_MODE` on a human-initiated read and
  declines to borrow the trigger guard's `SYSTEM_MODE` sibling. State that reasoning at the method.
- **`ARCHITECTURE.md` §5** — Item 3 stays imperative Apex (LDS cannot express the tie-broken
  latest-child-of-three-objects read); SLDS 2 `--slds-g-*` tokens only, linter clean, Jest +
  `@sa11y/jest` required.
- **API version 67.0** for anything new (`sfdx-project.json` `sourceApiVersion`).
