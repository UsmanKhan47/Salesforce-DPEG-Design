# Disposition LOI stages — Received → Under Review → Negotiation → Signed

**Request (user, 2026-08-21):** *"Received, under review, negotiations, Signed these should be the LOI stages in case of disposition — make sure not to change any flow on acquisition."*

**Org:** `usman-dpeg` (**PRODUCTION**) · API 67.0 · branch `feature/acquisitions-fsd-tranche-1`
**Status:** design only. No implementation metadata or code written by this document.

---

## 0. THE ACQUISITION CONSTRAINT — WHAT THIS PLAN TOUCHES THAT AN ACQUISITION LOI CAN SEE

Read this section first. Everything else is subordinate to it.

### 0.1 There are exactly THREE acquisition-visible items, and only one is a real decision

| # | Item | Acquisition-visible? | Behaviour change on acquisition? | Avoidable? |
|---|---|---|---|---|
| 1 | `objects/LOI__c/fields/Stage__c.field-meta.xml` — `<description>` + `<inlineHelpText>` | **YES** (help bubble on the Stage field of every LOI) | **NO** — value set, order, default and restriction all byte-identical; the *acquisition clause of the sentence* is byte-identical | Yes, by leaving the text stale. **Recommend changing it.** |
| 2 | `objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml` — `<description>` + `<inlineHelpText>` | **YES** (help bubble; formula backs the acquisition Advance Stage button) | **NO** — 🔴 **the formula needs NO change**, see §1.2 | Yes, by leaving the text stale. **Recommend changing it.** |
| 3 | `flows/LOI_Signed_Status_Sync.flow-meta.xml` — the file itself needs **no edit**, but its *scope silently widens* | **NO** on an acquisition record | **NO** on acquisition; **YES on disposition** (new latch + date stamp) | Only by *adding* a criterion — which would be a change to a live acquisition flow. **Recommend accepting the widening.** See §1.3 and gate **G2**. |

Items 1 and 2 are **text on a shared field**. Both files enumerate the disposition sequence, so both become factually wrong the moment this ships. In both cases the *acquisition* half of the sentence is unchanged character-for-character. No formula, no value set, no ordering, no FLS.

### 0.2 The one item that CAN break acquisition if handled naively — and how to not do that

🔴 **`objects/LOI__c/validationRules/Final_Price_Required_Before_Executed.validationRule-meta.xml`.**

Its formula is `TEXT(Stage__c) = "Executed"`. The file's own header states the technique it relies on:

> *"'Executed', NOT 'Signed'. NAMING THE VALUE IS WHAT SCOPES THIS RULE TO THE DISPOSITION PATH… An acquisition LOI can never carry 'Executed', so this rule is structurally unreachable from the acquisition path without any record type criterion at all."*
> *"🔴 DO NOT 'HARMONISE' THIS WITH THE ACQUISITION TERMINAL BY ADDING 'Signed' TO THE TEST. Acquisition LOIs reach 'Signed' through an approval process that this rule has never gated, and adding it would block a live acquisition workflow."*

**This change destroys that technique.** After it, `Signed` is the terminal on *both* record types, so the two terminals are no longer distinct and a value-named rule cannot scope itself any more.

⇒ **The naive repoint — `TEXT(Stage__c) = "Signed"` — is a direct violation of the user's constraint.** It would require `Final_Agreed_Price__c` on every future acquisition LOI advancing to Signed, blocking `RecordStageAdvanceService.advanceTo(loiId, 'Signed')` behind `LOI__c.Mark_Completed`. **Do not do it.** This is gate **G1**.

The plan's answer (recommended option, §2 G1) is a **discriminator on the LOOKUP, not on the record type**:

```
AND(
    OR(ISNEW(), ISCHANGED(Stage__c)),
    NOT(ISBLANK(Disposition__c)),
    TEXT(Stage__c) = "Signed",
    ISBLANK(Final_Agreed_Price__c)
)
```

`NOT(ISBLANK(Disposition__c))` is FALSE on every acquisition LOI in the org (the acquisition side is parented by `Opportunity__c`; `DispositionStageEntryService.openDispositionLois` sets `Disposition__c` and deliberately leaves `Opportunity__c` NULL — see that method's inline comment). It also survives the Master-record-type objection that `Counter_Price_Is_Positive`'s header raises against a `RecordType.DeveloperName` test, and `Is_Advance_Allowed__c`'s header already names exactly this expression as its own record-type fallback.

### 0.3 What this plan does NOT depend on

**🔴 This plan has ZERO dependency on record-type criteria working in FlexiPage visibility rules.** The brief asked for this to be flagged loudly; the answer is that the flexipage work here is **purely subtractive** — two `<valueListItems>` blocks are deleted and nothing is added. No new `visibilityRule`, no new criterion, no reliance on `{!Record.RecordType.DeveloperName}` at runtime.

The pending working-tree change to `LOI_Record_Page` (the fifth criterion on `Submit_for_Approval`) *does* carry that dependency, and it is unproven at the renderer. §5 keeps the two waves separate for exactly that reason.

---

## 1. CONTRADICTED PREMISES — measured against the repo, not restated from the brief

The brief's affected-artifact table is right about the concept and wrong or incomplete on **seven** material points. Each was checked by reading the file.

### 1.1 ❌ `DispositionStageEntryService.cls` does NOT key the LOI→PSA hop off LOI `Executed`

The brief marks this 🔴 as "must become `Signed`". **It is false.**

`DispositionStageEntryService` keys entirely off `Disposition__c.Disposition_Stage__c` string constants — `NDA_STAGE = 'NDA'`, `LOI_STAGE = 'LOI'`, `PSA_STAGE = 'PSA'`, `RELEASE_MATERIALS_STAGE = 'Release Materials'`, `LISTING_STAGE = 'Active Listing'`. A grep for `Executed` in the file returns **three hits, all inside one doc comment about `Contract_Review__c`** (lines 732–734). It never reads `LOI__c.Stage__c` at all.

The real LOI→PSA hop on a disposition is the **manual `Disposition__c.Advance_to_PSA` quick action**, gated on `Disposition_Stage__c = 'LOI'` and backed by `RecordStageAdvanceService`'s `'LOI' => 'PSA'` entries in both `DISPOSITION_ON_MARKET_NEXT_STAGE` and `DISPOSITION_OFF_MARKET_NEXT_STAGE` (lines 1114, 1147). **Nothing in that chain reads the LOI's stage.**

⇒ **`DispositionStageEntryService.cls` needs NO functional change.** One doc comment on `DISPOSITION_LOI_INITIAL_STAGE` (line ~257) references the disjointness history and is fine as-is; `DISPOSITION_LOI_INITIAL_STAGE = 'Received'` is unchanged by this wave.

### 1.2 ❌ `Is_Advance_Allowed__c`'s FORMULA needs no change — only its help text

Current formula:

```
AND(
  TEXT(Stage__c) <> "Signed",
  TEXT(Stage__c) <> "Executed",
  TEXT(Stage__c) <> "Submitted",
  OR( RecordType.DeveloperName <> "Acquisition_LOI",
      TEXT(Stage__c) <> "Under Review",
      TEXT(LOI_Status__c) = "Approved" ),
  TEXT(LOI_Status__c) <> "Pending Approval"
)
```

Evaluated against the **new** disposition sequence:

| Disposition stage | Result | Advance Stage button | Correct? |
|---|---|---|---|
| Received | TRUE | shown → Under Review | ✅ |
| Under Review | TRUE (first disjunct: RT ≠ Acquisition_LOI) | shown → Negotiation | ✅ |
| Negotiation | TRUE | shown → Signed | ✅ |
| Signed | **FALSE** — clause 1 already excludes it | hidden | ✅ terminal |

The `<> "Signed"` clause was written for the *acquisition* terminal and is record-type-agnostic, so it **already** covers the new disposition terminal. The `<> "Executed"` clause goes inert on both sides.

**Recommendation: leave the formula alone; do not delete the `<> "Executed"` clause in this wave.** Three reasons: (a) touching a formula that backs a live acquisition button buys nothing; (b) `Executed` stays ACTIVE on the master value set (user decision 3), and the repo's standing claim that record-type picklist restriction is UI-only means a data load or direct Apex write can still park a row on it — the clause is a live guard, not dead code; (c) the file's own header records this exact clause as the fix for defect D22 and would need a fourth retraction to remove it. Update `<description>` and `<inlineHelpText>` only.

### 1.3 ➕ MISSED BY THE BRIEF — `LOI_Signed_Status_Sync` starts firing on disposition LOIs

`flows/LOI_Signed_Status_Sync.flow-meta.xml` is a **before-save flow on `LOI__c`, `CreateAndUpdate`, with NO record-type or lookup criterion**. Its single decision is `$Record.Stage__c EqualTo 'Signed'`. Its own comment:

> *"Acquisition_LOI's Stage__c sequence ends at 'Signed' (terminal); Disposition_LOI's terminal is the distinct value 'Executed', so this flow is naturally Acquisition-only with no record-type criterion needed (2026-08-18 design decision D1/D2)."*

**That premise dies with this change.** From the moment `Signed` lands on `Disposition_LOI`, every disposition LOI reaching Signed will get:
- `LOI_Signed__c = true` (a **one-way latch** — the flow has no false branch by design), and
- `LOI_Signed_Date__c = TODAY()` if blank.

Both fields are already granted `editable=true` to `DPEG_Disposition_Edit` (lines 1780–1788 of that permission set), so the persona will see them.

**Blast-radius check on `LOI_Signed__c`, performed:**
- `flows/LOI_Signed_Notify.flow-meta.xml` — fires on `LOI_Signed__c = true` and notifies Legal + Investor Relations. **Currently `<status>Draft</status>` (inactive), with `activeVersionNumber` removed from its paired FlowDefinition.** ⇒ no notification fires today. 🔴 **But reactivating it later would now also notify Legal/IR on every sell-side LOI** — a cross-module widening. Record it in that flow's header.
- `Opportunity.Deal_Sub_Stage__c` reads `Primary_LOI__r.LOI_Signed__c`. `Primary_LOI__c` is stamped only by `OpportunityReviewService`, which creates acquisition LOIs. A disposition LOI cannot reach it. **Acquisition-only, unaffected.**
- No validation rule, trigger, or selector `WHERE` clause reads `LOI__c.LOI_Signed__c`.

**Recommendation: accept the widening (gate G2).** It is semantically correct — a sell-side LOI that reaches Signed *is* signed — and it requires **zero edits to a flow that governs acquisition**, which is the safest possible answer to the user's constraint. The alternative (adding an entry criterion) means editing a live acquisition before-save flow to fix a disposition concern, which is the trade this repo repeatedly refuses.

### 1.4 ❌ `Counter_Price_Is_Positive` does NOT reference the counter stages

Its formula is `AND(NOT(ISBLANK(Counter_Price__c)), Counter_Price__c <= 0)` — a pure arithmetic invariant with no stage reference at all. Only its **XML comment** (lines 21–23) enumerates the old disposition sequence. Comment-only edit, optional, zero behaviour change. It fires on both record types today and will continue to; that is deliberate and documented.

### 1.5 ❌ `LoiSelector.cls` has no `Executed` literal in any query

Every `WHERE` clause in the file (lines 77, 99, 123, 160, 226, 249, 317, 367) filters on `Id`, `Opportunity__c` or `Disposition__c`. The three `Executed` hits (lines 146, 265, 267) are **doc-comment prose**. Comment-only.

Note line 266's claim — *"`LOI_Signed_Date__c` — `LOI_Signed_Status_Sync` keys on `Stage__c = 'Signed'`, which is the ACQUISITION terminal"* — is one of the premises §1.3 kills. It must be retracted in place, not left standing.

### 1.6 ❌ `lwc/dispositionDealSummary` needs no functional change

Its `LOI_TONE` map (lines 123–137) **already maps all thirteen `Stage__c` values**, including `Negotiation: 'progress'` and `Signed: 'complete'`. The new sequence renders correctly with no edit. Only the comment above it (lines 119–122) is stale.

`DispositionDealSummaryService.cls` passes `summary.loiStage = loi.Stage__c` straight through (line 269) with no mapping. Comment-only (lines 114–119) — and line 118's *"`LOI_Signed_Date__c` is … structurally always blank on a sale"* is another casualty of §1.3.

`dispositionDealSummary.css` carries a comment naming `Counter Received from Buyer` as the 27-character worst case that justifies `flex-wrap: wrap`. 🔴 **Keep the CSS rule.** Its Jest guard (`NARROW COLUMN: the row head wraps…`, test file lines 594–605) asserts the CSS *rules*, not the comment string, so the comment can be corrected without breaking it — but deleting `flex-wrap: wrap` or `min-width: 0` fails that test and re-opens the overflow.

### 1.7 ❌ `objectTranslations/` and `TestDataFactory` need no change

- `objectTranslations/LOI__c-en_US/Stage__c.fieldTranslation-meta.xml` enumerates only **five legacy acquisition values** (Completed, Counter, Draft, Prepare/Review, Sent). **None of the three being removed appears in it.** No edit. (`Counter_Received_Date__c.fieldTranslation` is a *field label* translation for a field that survives — untouched.)
- `TestDataFactory.createLois` / `createDispositionLoi` seed at `'Received'` (disposition) and `'Draft'` (acquisition) — line 1759. **Neither value is being removed.** No edit.

### 1.8 ➕ MISSED — additional artifacts the brief did not name

| Artifact | Why |
|---|---|
| `manifest/package.xml` lines **1816, 1818** (`loiMarkCounterReceived`, `loiMarkCounteredByDpeg`) and **2250, 2252** (`LOI__c.Mark_Counter_Received`, `LOI__c.Mark_Countered_By_DPEG`) | A retrieve against this manifest after the delete fails or silently resurrects. Remove all four `<members>` lines. |
| `classes/DispositionDealSummaryServiceTest.cls` line **271** — `loi.Stage__c = 'Executed'` on a `Disposition_LOI` fixture, asserted at line 283 | Premise dies. Repoint to `'Signed'`. Its comments at 289 and 293 assert the now-false "always blank on a sale" claim. |
| `docs/permission-set-retirement-runbook.md` line 451/454 | Maps `RecordStageAdvanceController` class access to the two retiring bundles. Documentation only — not deployable, does not block. Note it so the next retirement pass isn't misled. |
| `lwc/dispositionDealSummary/__tests__/dispositionDealSummary.test.js` lines **132, 216** | `FULL_SUMMARY.loiStage = 'Countered by DPEG'` and the pill assertion. **This test stays GREEN** (JS literal, never validated against the org) while asserting a value no disposition LOI can hold. Classic stale fixture — repoint to `'Negotiation'`. |

### 1.9 🔴 A NAME COLLISION THAT MUST NOT BE SWEPT

`objects/Disposition_Offer__c/fields/Offer_Status__c.field-meta.xml` carries its **own** picklist values `Received`, `Under Review`, `Countered by DPEG`, `Counter Received from Buyer`, `Accepted`, `Rejected`, `Withdrawn by Buyer`, plus its translation file `objectTranslations/Disposition_Offer__c-en_US/Offer_Status__c.fieldTranslation-meta.xml`.

**This is a different field on a different object and is OUT OF SCOPE.** A string-scoped sweep for `Countered by DPEG` hits it. `Stage__c`'s own header states the rule: *"Any sweep for these values must be FIELD-scoped, never string-scoped."* **Do not touch `Disposition_Offer__c`.**

### 1.10 ✅ Premises the brief got right, confirmed independently

- **`Submitted`-gated buttons stay self-limiting.** `LOI__c.Mark_Countered` and `LOI__c.Mark_Completed` are each `Acquisition_Deal_Actions` **AND** `{!Record.Stage__c} EQUAL Submitted` (flexipage lines 356–387). `Submitted` remains acquisition-only. Two independent guards. ✅
- **Zero data migration.** No repo artifact writes a disposition-LOI stage: every seed script's LOI writes are acquisition-side (`seed-fsd-02/03/04/05`, `seed-deal`, `seed-nda-loi-metrics`, `verify-junior-lifecycle`), and `TestDataFactory` seeds `'Received'`. 🔴 **Re-run `SELECT Stage__c, COUNT(Id) FROM LOI__c WHERE RecordType.DeveloperName = 'Disposition_LOI' GROUP BY Stage__c` at deploy time rather than citing the brief's measurement.** If any row sits on a removed value, stop and escalate — it is a data task, not a deploy.
- **No report or list view filters on the removed values.** Swept `force-app/main/default/reports/**` — every `Executed` hit is `Contract_Executed_Date__c` on Transaction/Opportunity.

---

## 2. BLOCKING GATES — decisions needed before implementation starts

### 🚦 G1 — `Final_Price_Required_Before_Executed`: what happens to the sell-side price guard?

The rule shipped **2026-08-20 — one day before this request**. Its scoping technique dies with this change (§0.2). Four options:

| Option | Effect | Acquisition risk | Sell-side guard |
|---|---|---|---|
| **A (recommended)** — repoint to `Signed` **+ add `NOT(ISBLANK(Disposition__c))`** as the first term | Guard preserved, scoped by the parent lookup | **NONE** — acquisition LOIs have a blank `Disposition__c`, term is FALSE, rule unreachable | ✅ kept |
| B — repoint to `Signed` + add `RecordType.DeveloperName = "Disposition_LOI"` | Guard preserved, scoped by record type | None on assigned rows, but **also excludes Master-type rows**, which `Counter_Price_Is_Positive`'s header and `Broker_Lookup_Is_Off_Market_Only` both argue against | ✅ kept, with a Master hole |
| C — repoint to `Signed` with **no** discriminator | 🔴 **VIOLATES THE CONSTRAINT** | **Blocks every future acquisition LOI reaching Signed without a Final Agreed Price** | ✅ kept |
| D — leave the formula naming `Executed` | Rule silently goes inert; nothing ever reaches `Executed` again | None | ❌ **silently lost** |

**Recommend A.** It answers the file's own "do not add a record-type test" instruction on its merits (the objection was about Master rows and a rename; a lookup test is immune to both) rather than by ignoring it, and `Is_Advance_Allowed__c`'s header already nominates `NOT(ISBLANK(Disposition__c))` as the sanctioned substitute discriminator on this exact object.

**Also required under A or B:** the file's 🔴 *"DO NOT HARMONISE… adding it would block a live acquisition workflow"* paragraph must be **retracted in place, verbatim, with the reason** (its premise — distinct terminals — is what died), not deleted. That is this repo's standing convention and there are five prior instances on these very files.

**On renaming the rule to `Final_Price_Required_Before_Signed`: RECOMMEND NO.**
1. Renaming a `ValidationRule` API name is a **delete-and-recreate**, i.e. two operations with a window in which the org has no rule. This repo already ruled on this exact question, on the sibling rule: `Completed_LOI_Before_PSA`'s header — *"the API name deliberately still reads `_Before_PSA` — renaming a ValidationRule is a delete-and-recreate, and the new value still contains 'PSA'."* That rule now tests `Signed` under a name saying `Completed`, and has done since 2026-08-14 without incident.
2. The standing project rule is additive (add → repoint → retire), never in-place rename.
3. The name is not the contract; `<description>` and `<errorMessage>` are what a user reads, and both get repointed. `<description>` is capped at 255 — **measure with a parser, not by eye** (this programme has breached that cap three times).
4. The cost of the misleading name is a one-line comment. The cost of the rename is a destructive operation on a live control in production. Keep the name.

### 🚦 G2 — Accept `LOI_Signed_Status_Sync` widening onto disposition LOIs? (§1.3)

**Recommend YES / accept.** It requires no edit to an acquisition-governing flow, it is semantically right, and `LOI_Signed_Notify` is already inactive so nothing fires. **If the user declines**, the plan gains an edit to a live acquisition before-save flow and G2 becomes the wave's highest-risk item.

### 🚦 G3 — Deactivate the three orphaned values on the master `Stage__c` value set?

After this change, `Countered by DPEG`, `Counter Received from Buyer` and `Executed` sit on the master value set but on **no record type**. User decision 3 said *do not delete* and *no manual Setup step*. Deactivating (`<isActive>false</isActive>`) is neither, but it is beyond the settled decision, so it is raised rather than assumed.

**Recommend: NOT in this wave.** Two reasons: (a) leaving them active keeps `Is_Advance_Allowed__c`'s `<> "Executed"` clause meaningful as a guard against a direct write (§1.2); (b) `Stage__c`'s header records that the four already-retired values were deactivated *after* a row migration, and no migration has run here. Revisit once the disposition path has been live for a cycle.

### 🚦 G4 — Ship the pending `LOI_Record_Page` change first, or bundle it?

**Recommend: ship it FIRST, standalone, and run its two-direction renderer probe** (documented in that file's header, lines 244–252) before this wave touches the same file. Rationale in §5.1.

---

## 3. THE CHANGE SET

### 3.1 The ordering arithmetic — checked, not inherited

`Stage__c` is `sorted=false`, so runtime Path order comes from the **master value-set order** filtered by the record type. A record type can only include or exclude, never re-order. Master order today:

```
1 Draft            6 Received        11 Submitted
2 Prepare/Review*  7 Under Review    12 Negotiation
3 Sent*            8 Countered by DPEG   13 Signed
4 Counter*         9 Counter Received from Buyer
5 Completed*      10 Executed                     (* = inactive)
```

New disposition set = **Received(6) → Under Review(7) → Negotiation(12) → Signed(13)** — strictly monotonic.
Acquisition set = Draft(1) → Under Review(7) → Submitted(11) → Negotiation(12) → Signed(13) — **byte-identical to today**.

🔴 **Therefore NO re-ordering of the master value set is required, and none may be attempted.** Any re-order would move the acquisition rendering and violate the constraint. `Stage__c`'s `<valueSet>` block must be **byte-identical** after this wave except for `<description>` / `<inlineHelpText>`.

### 3.2 Full artifact inventory

| # | File | Change | Layer |
|---|---|---|---|
| A1 | `objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml` | In the `Stage__c` `<picklistValues>` block **only**: remove `Countered by DPEG`, `Counter Received from Buyer`, `Executed`; add `Negotiation`, `Signed`. `Received` keeps `<default>true</default>`. `Ball_In_Court__c` and `LOI_Status__c` blocks **untouched**. Retract the "do not add them for symmetry" paragraph (lines 67–71) verbatim + reason. 🔴 **The `Submitted`-half of that warning STANDS** — see A1-note. `<description>` ≤255, measured. | Admin |
| A2 | `pathAssistants/LOI_Path_Disposition.pathAssistant-meta.xml` | 5 steps → 4. Delete the `Countered by DPEG`, `Counter Received from Buyer`, `Executed` steps; add `Negotiation` and `Signed` with new `<info>` prose. Keep the `Received` and `Under Review` steps' `<info>` **byte-identical**. No `<fieldNames>` on any step (object convention). Retract the loop/disjointness paragraphs. | Admin |
| A3 | `objects/LOI__c/fields/Stage__c.field-meta.xml` | 🔴 **`<valueSet>` BYTE-IDENTICAL.** Rewrite the disposition clause of `<description>` (cap 1000) and `<inlineHelpText>` (cap **255**, currently at **247**). New help text should land near 210 — **measure with an XML parser on the decoded value**, per this file's own instruction. | Admin |
| A4 | `objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml` | 🔴 **`<formula>` UNCHANGED.** `<description>` + `<inlineHelpText>` only (currently 241/255; `(Signed/Executed)` → `(Signed)` saves 9). Add a dated note recording that the `<> "Executed"` clause is now inert-but-retained and why. | Admin |
| A5 | `objects/LOI__c/validationRules/Final_Price_Required_Before_Executed.validationRule-meta.xml` | Per **G1**. **Do not rename the file or `<fullName>`.** Formula + `<description>` (≤255) + `<errorMessage>`, plus the verbatim retraction. | Admin |
| A6 | `flexipages/LOI_Record_Page.flexipage-meta.xml` | Delete the two `<valueListItems>` blocks for `LOI__c.Mark_Countered_By_DPEG` (lines 388–403) and `LOI__c.Mark_Counter_Received` (lines 404–419). **Nothing else.** Do not toggle `enableActionsConfiguration` (already `true`; toggling it silently empties the action bar). Update the header. | Admin |
| A7 | `quickActions/LOI__c.Mark_Countered_By_DPEG.quickAction-meta.xml` | **DELETE** (destructive, post) | Admin |
| A8 | `quickActions/LOI__c.Mark_Counter_Received.quickAction-meta.xml` | **DELETE** (destructive, post) | Admin |
| A9 | `objects/LOI__c/validationRules/Counter_Price_Is_Positive.validationRule-meta.xml` | Comment-only: correct the disposition enumeration at lines 21–23. Formula, description, message untouched. Optional. | Admin |
| A10 | `manifest/package.xml` | Remove `<members>` lines 1816, 1818, 2250, 2252. | Admin |
| D1 | `classes/RecordStageAdvanceService.cls` | `LOI_DISPOSITION_NEXT_STAGE` → `{'Received'=>'Under Review', 'Under Review'=>'Negotiation', 'Negotiation'=>'Signed'}`. **Delete `LOI_DISPOSITION_EXPLICIT_TARGETS`** and switch the `Disposition_LOI` `StageTypeConfig` to the **two-arg constructor** (line 1279), which supplies an empty set and makes `advanceTo()` structurally unreachable on that record type. Rewrite the class-header LOI block + both map doc-comments with verbatim retractions. **Do not add a `NO_NEXT_STEP_HINTS` entry** — see D1-note. | Developer |
| D2 | `classes/RecordStageAdvanceServiceTest.cls` | See §7. Five methods affected. | Developer |
| D3 | `classes/DispositionDealSummaryService.cls` | Comment-only (lines 114–119). Retract the `LOI_Signed_Date__c`-always-blank claim. | Developer |
| D4 | `classes/DispositionDealSummaryServiceTest.cls` | Line 271 `'Executed'` → `'Signed'`; assertion line 283; retract comments at 289 and 293. | Developer |
| D5 | `classes/LoiSelector.cls` | Comment-only (lines 146, 265–267). Retract the "acquisition terminal" claim at 266. | Developer |
| D6 | `lwc/dispositionDealSummary/dispositionDealSummary.js` | Comment-only (lines 27–41 header, 119–122). `LOI_TONE` **unchanged** — it already maps all thirteen values. | Developer |
| D7 | `lwc/dispositionDealSummary/dispositionDealSummary.css` | Comment-only. 🔴 **Keep `flex-wrap: wrap` and `min-width: 0`** — a Jest test asserts them. | Developer |
| D8 | `lwc/dispositionDealSummary/__tests__/dispositionDealSummary.test.js` | Fixture line 132 and assertion line 216: `'Countered by DPEG'` → `'Negotiation'`. | Developer |
| D9 | `lwc/loiMarkCounteredByDpeg/**` (incl. `__tests__`) | **DELETE bundle** | Developer |
| D10 | `lwc/loiMarkCounterReceived/**` (incl. `__tests__`) | **DELETE bundle** | Developer |
| D11 | `flows/LOI_Signed_Notify.flow-meta.xml` | Comment-only: record that reactivating it would now notify Legal/IR on **sell-side** LOIs too. Stays `Draft`. | Developer |
| D12 | `flows/LOI_Signed_Status_Sync.flow-meta.xml` | Under **G2 = accept**: comment-only, retracting the "Acquisition-only by construction" claim (lines 13–15 and `<description>`). 🔴 **No element, connector, decision or `<start>` change.** | Developer |

**A1-note (load-bearing):** 🔴 **`Submitted` must NOT be added to `Disposition_LOI`.** `LOI__c.Mark_Countered` and `LOI__c.Mark_Completed` are self-limited to acquisition by `{!Record.Stage__c} EQUAL Submitted`. Adding `Submitted` to the disposition set would surface both acquisition buttons on a sale. Only `Negotiation` and `Signed` are added.

**D1-note:** a disposition LOI at `Signed` will get the default refusal *"There is no next step available from the Signed stage."* — identical wording to an acquisition LOI at `Signed`, and correct for both. `NO_NEXT_STEP_HINTS` is **not** record-type-aware, and that class's header explicitly warns: *"BEFORE ADDING ANY LOI ENTRY HERE, widen the key to `<label>|<recordTypeKey>|<currentStage>`."* No entry is needed; do not add one.

### 3.3 Explicitly NOT changed

`DispositionStageEntryService.cls` · `CounterOfferService.cls` (never reads `Stage__c`) · `lwc/loiCounterOffer` · `Counter_Offer__c` · `TestDataFactory.cls` · `objectTranslations/LOI__c-en_US/**` · `layouts/LOI__c-LOI Layout.layout-meta.xml` (its `platformActionList` carries only `Submit_for_Approval`, never the Mark_* actions) · `objects/Disposition_Offer__c/**` · `objects/Opportunity/validationRules/Completed_LOI_Before_PSA` · `Opportunity.Deal_Sub_Stage__c` · all seed scripts · all reports · all permission sets · `objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml`.

---

## 4. ADMIN / DEVELOPER SPLIT — ready-to-paste prompts

### 🔵 PROMPT FOR `salesforce-admin`

```
Disposition LOI stage change on LOI__c. Target sequence for the Disposition_LOI record
type ONLY: Received -> Under Review -> Negotiation -> Signed.

HARD CONSTRAINT: nothing visible to an Acquisition_LOI record may change behaviour.
Read agent-output/disposition-loi-stages.md sections 0 and 3 before starting. Do not
deploy - create/modify metadata files only.

Read ARCHITECTURE.md, and read the in-file XML comment of every file below before
editing it. Those comments carry retractions and DO-NOT banners that are authoritative
over any instruction here.

1. objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml
   In the Stage__c <picklistValues> block ONLY: remove Countered by DPEG, Counter
   Received from Buyer, Executed. Add Negotiation and Signed. Keep Received as
   <default>true</default>. Leave the Ball_In_Court__c and LOI_Status__c blocks
   untouched and still fully enumerated.
   *** DO NOT ADD 'Submitted'. *** LOI_Record_Page self-limits Mark_Countered and
   Mark_Completed to acquisition using {!Record.Stage__c} EQUAL Submitted; adding it
   would surface two acquisition buttons on a sale.
   Retract the paragraph at lines 67-71 ("Submitted, Negotiation and Signed ... are
   DELIBERATELY ABSENT here ... Signed in particular would put the ACQUISITION terminal
   on the sell-side path") verbatim, with the reason: 'Executed' is being removed, so
   the consequence it warns of is now the intended behaviour. State that the
   'Submitted' half of the warning STANDS.
   <description> is capped at 255 - MEASURE with an XML parser on the decoded value.

2. pathAssistants/LOI_Path_Disposition.pathAssistant-meta.xml
   Five steps -> four. Keep the Received and Under Review steps' <info> text
   BYTE-IDENTICAL. Delete the three removed steps. Add Negotiation and Signed steps
   with new <info> prose reflecting the new sequence: at Negotiation, counter rounds
   are recorded by editing the Counter History on this record (the two named counter
   buttons are retired); at Signed, both sides have agreed - attach the executed
   document and move the disposition on with Advance to PSA.
   No <fieldNames> on any step - that is this object's convention for both LOI paths.
   Retract the "MIDDLE OF THIS PATH IS A LOOP" and "fully disjoint" paragraphs.

3. objects/LOI__c/fields/Stage__c.field-meta.xml
   *** THE <valueSet> BLOCK MUST BE BYTE-IDENTICAL AFTER YOUR EDIT. *** No value is
   added, removed, re-ordered or deactivated. The new disposition sequence renders
   correctly from the existing order (positions 6, 7, 12, 13 - monotonic) and any
   re-order would move the ACQUISITION rendering.
   Change ONLY <description> (cap 1000) and <inlineHelpText> (cap 255, currently
   measured at 247) to state the disposition sequence as Received, Under Review,
   Negotiation, Signed. Leave the acquisition clause of both byte-identical. MEASURE
   the new inlineHelpText with an XML parser, not by eye.

4. objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml
   *** THE <formula> MUST NOT CHANGE. *** It is already correct for the new sequence:
   clause 1 (TEXT(Stage__c) <> "Signed") is record-type-agnostic and already hides the
   button at the new disposition terminal; the RecordType-guarded Under Review
   disjunct still returns TRUE on disposition. The <> "Executed" clause goes inert and
   is deliberately RETAINED as a guard against a direct write.
   Change <description> and <inlineHelpText> only ((Signed/Executed) -> (Signed);
   currently 241/255). Add a dated note explaining the retained inert clause.

5. objects/LOI__c/validationRules/Final_Price_Required_Before_Executed.validationRule-meta.xml
   *** DO NOT RENAME THE FILE OR <fullName>. *** Renaming a ValidationRule is a
   delete-and-recreate; the in-repo precedent is Completed_LOI_Before_PSA, which still
   reads _Before_PSA while testing a renamed value.
   New errorConditionFormula:
       AND(
           OR(ISNEW(), ISCHANGED(Stage__c)),
           NOT(ISBLANK(Disposition__c)),
           TEXT(Stage__c) = "Signed",
           ISBLANK(Final_Agreed_Price__c)
       )
   The NOT(ISBLANK(Disposition__c)) term is what keeps this rule off the acquisition
   path now that both terminals are 'Signed'. It is NOT optional and it is NOT a
   RecordType test - the lookup form survives a record-type rename and does not exclude
   Master-type rows.
   Retract this file's "DO NOT HARMONISE THIS WITH THE ACQUISITION TERMINAL BY ADDING
   'Signed' TO THE TEST" paragraph VERBATIM, with the reason: the technique it defends
   (naming a value that only one record type carries) no longer works because the two
   terminals are now the same value. Record that the acquisition path is protected by
   the lookup test instead.
   Repoint <description> (cap 255 - measure) and <errorMessage> from Executed to Signed.

6. flexipages/LOI_Record_Page.flexipage-meta.xml
   Delete the two <valueListItems> blocks whose <value> is LOI__c.Mark_Countered_By_DPEG
   and LOI__c.Mark_Counter_Received. Change NOTHING ELSE - not the Submit_for_Approval
   entry (which has a pending, separately-shipped change), not either Advance_Stage
   entry, not Mark_Countered, not Mark_Completed, and DO NOT touch
   enableActionsConfiguration (it is already true; toggling it silently empties a
   page's whole action bar).
   Update the page header: the retired buttons and the fact that the two remaining
   acquisition Mark_* entries stay self-limiting because 'Submitted' is still
   acquisition-only.

7. DELETE (stage as destructiveChangesPost.xml, not as file removal alone):
   quickActions/LOI__c.Mark_Countered_By_DPEG.quickAction-meta.xml
   quickActions/LOI__c.Mark_Counter_Received.quickAction-meta.xml

8. objects/LOI__c/validationRules/Counter_Price_Is_Positive.validationRule-meta.xml
   COMMENT ONLY - correct the disposition sequence enumerated at lines 21-23. The
   formula, description and error message do not change; it is an arithmetic invariant
   and stays deliberately unscoped across both record types.

9. manifest/package.xml - remove four <members> lines: loiMarkCounterReceived (1816),
   loiMarkCounteredByDpeg (1818), LOI__c.Mark_Counter_Received (2250),
   LOI__c.Mark_Countered_By_DPEG (2252).

DO NOT TOUCH: Acquisition_LOI.recordType-meta.xml, LOI_Path_Acquisition,
objectTranslations/LOI__c-en_US/Stage__c.fieldTranslation (it enumerates only the five
legacy acquisition values and none of the three being removed), layouts/LOI__c-LOI
Layout.layout-meta.xml, any permission set, any report, and above all
objects/Disposition_Offer__c/fields/Offer_Status__c.field-meta.xml - that is a
DIFFERENT field on a DIFFERENT object that happens to carry the same two counter
labels. Sweeps on this object must be FIELD-scoped, never string-scoped.

NOTE ON TOOLING: the salesforce-api-context MCP is not configured in this repo
(.mcp.json has only the `salesforce` server). Record mcp=unavailable after a real
attempt and fall back to the per-type skill, per .claude/rules/salesforce-global-rule.md.
```

### 🟢 PROMPT FOR `salesforce-developer`

```
Apex + LWC half of the disposition LOI stage change. New Disposition_LOI sequence:
Received -> Under Review -> Negotiation -> Signed. The acquisition sequence
(Draft -> Under Review -> Submitted -> Negotiation -> Signed) must not change in any
way. Read agent-output/disposition-loi-stages.md sections 0, 1 and 7 first. Do not
deploy.

Read the class headers before editing. This codebase carries decision history,
retractions and DO-NOT-RESTORE banners in headers and they are authoritative.

1. classes/RecordStageAdvanceService.cls
   a) LOI_DISPOSITION_NEXT_STAGE becomes:
        'Received'     => 'Under Review',
        'Under Review' => 'Negotiation',
        'Negotiation'  => 'Signed'
      'Signed' is terminal and has no entry.
   b) DELETE the LOI_DISPOSITION_EXPLICIT_TARGETS constant entirely, and change the
      Disposition_LOI StageTypeConfig in CONFIG_BY_TYPE to the TWO-ARG constructor
      (gate, nextStage). That supplies an empty set and makes advanceTo() structurally
      unreachable on Disposition_LOI - which is a strengthening, and say so in the
      comment. The negotiation loop is retired: counter rounds are now recorded by
      editing Counter History on the LOI (Counter_Offer__c / c/loiCounterOffer),
      which is unchanged.
   c) LOI_ACQUISITION_NEXT_STAGE and LOI_ACQUISITION_EXPLICIT_TARGETS: DO NOT TOUCH.
   d) DO NOT add a NO_NEXT_STEP_HINTS entry. That map is not record-type-aware and its
      own doc-comment forbids an LOI entry without first widening the key. The default
      refusal ("There is no next step available from the Signed stage.") is correct
      wording on BOTH record types.
   e) Rewrite, with VERBATIM retractions rather than deletions:
      - the class header's LOI block, which states the disposition sequence and that
        the LOI is "a LOOP";
      - the "THREE of the twelve are not straight lines" paragraph - the disposition
        LOI is now LINEAR, so the count drops to TWO (the acquisition LOI branch at
        'Submitted' and the disposition NDA 'Declined' off-ramp);
      - LOI_DISPOSITION_NEXT_STAGE's own doc-comment.
   f) 🔴 RECORD A NEW HAZARD that did not exist before, in the header near
      LOI_ACQUISITION_EXPLICIT_TARGETS: 'Negotiation' and 'Signed' are now on BOTH
      record types' value sets. The per-record-type allow-list split is therefore the
      ONLY thing preventing LOI__c.Mark_Completed (which sends 'Signed') from writing a
      *legal* disposition value onto a sale via a hand-crafted advanceTo. Before this
      change, such a write produced an off-set value that at least looked wrong; now it
      would look entirely normal. Do not move the allow-list back to object level.

2. classes/RecordStageAdvanceServiceTest.cls - see section 7 of the design doc.
   FIVE methods, and two of them go quietly wrong rather than red:
   - underReviewIsSharedByBothLoiRecordTypesAndStillRoutesByRecordType (line ~836):
     expected disposition hop 'Countered by DPEG' -> 'Negotiation'. RED, mechanical.
   - dispositionLoiWalksReceivedToExecuted (line ~869): rewrite as
     dispositionLoiWalksReceivedToSigned - three hops, terminal 'Signed', and the
     Final_Agreed_Price__c pre-set must still happen at 'Received' (before the stage
     moves) so the price rule cannot fire on that same update.
   - dispositionLoiExecutedWithBlankFinalPrice_surfacesValidationRuleMessage (~923):
     rename to ..._Signed..., fixture stage 'Negotiation', expect the same message
     text repointed to Signed. Keep the "must not write" assertion.
   - dispositionLoiAcceptsTheNegotiationLoopTargets (~1640): DELETE. Its subject is
     retired. Say so in the block comment above the pair at lines 1521-1542.
   - dispositionLoiRefusesTheAcquisitionExplicitTargets (~1545): 🔴 STAYS GREEN AND ITS
     RATIONALE INVERTS. Its comment asserts "'Signed' ... is not a Disposition_LOI
     value at all" - that is now FALSE. The refusal still holds, but for a different
     and weaker reason (the value is not on the disposition ALLOW-LIST, not that it is
     off the value set). Rewrite the comments so the test still documents what it
     actually proves. Do not delete it - it is now the only cross-type allow-list guard
     with real content.
   - acquisitionLoiRefusesADispositionStageAsAnExplicitTarget (~1583) — RENAMED on
     2026-08-21 to acquisitionExplicitTargetListHasNotWidenedToTheUnion: 🔴 BECOMES
     VACUOUS AND STAYS GREEN. All three probed values ('Executed', 'Countered by DPEG',
     'Counter Received from Buyer') are now allow-listed nowhere, so it degenerates
     into the "list has not widened to the union" control its own comment says
     'Executed' alone used to be. KEEP IT, but rewrite the comment to say exactly that
     rather than leaving a claim about "the exact literals two deployed bundles send"
     when those bundles no longer exist.
   BULK: .claude/rules/bulk-test-rule.md's 251-record mandate DOES NOT APPLY here, and
   this class's own header records the exemption - advance()/advanceTo() are
   per-transaction-singleton @AuraEnabled operations invoked once per quick-action
   click. Do not add 251-record tests and do not let review demand them.

3. classes/DispositionDealSummaryServiceTest.cls - line 271 'Executed' -> 'Signed';
   assertion at 283. Retract the comments at 289 and 293: LOI_Signed_Date__c is NO
   LONGER structurally always blank on a sale, because LOI_Signed_Status_Sync keys on
   'Signed' with no record-type criterion and 'Signed' is now the disposition terminal.
   The DTO members stay absent - that decision (C-10/C-11) is unchanged, but its
   REASON for loiSignedDate has changed and the assertion message must say so.

4. classes/DispositionDealSummaryService.cls - COMMENT ONLY (lines 114-119). Same
   retraction about LOI_Signed_Date__c. summary.loiStage passes Stage__c straight
   through; no code change.

5. classes/LoiSelector.cls - COMMENT ONLY (lines 146, 265-267). No query, no WHERE
   clause and no field list changes. Retract the line-266 claim that Stage__c='Signed'
   is "the ACQUISITION terminal" - it is now both.

6. lwc/dispositionDealSummary/
   - dispositionDealSummary.js: COMMENT ONLY. The LOI_TONE map at lines 123-137 ALREADY
     maps Negotiation ('progress') and Signed ('complete') and needs no edit. Correct
     the comment at 119-122 and the header bullets at 37-41.
   - dispositionDealSummary.css: COMMENT ONLY. 🔴 KEEP `flex-wrap: wrap` on .row-head and
     `min-width: 0` on .row-left - a Jest test asserts both by source match. Only the
     comment naming 'Counter Received from Buyer' as the 27-char worst case changes.
   - __tests__/dispositionDealSummary.test.js: FULL_SUMMARY.loiStage at line 132 and the
     pill assertion at line 216: 'Countered by DPEG' -> 'Negotiation'. This test is
     GREEN today and would stay green with a dead value in it - that is why it is on
     this list.

7. DELETE these two bundles entirely, including their __tests__ folders:
   lwc/loiMarkCounteredByDpeg/
   lwc/loiMarkCounterReceived/
   Stage them in the same destructiveChangesPost.xml as the two quick actions (the
   admin agent owns that file). No permission set references either bundle - verified.
   RecordStageAdvanceController class access stays granted; five other bundles use it.

8. flows/LOI_Signed_Notify.flow-meta.xml - COMMENT ONLY, stays <status>Draft</status>.
   Add a note: reactivating it would now fire the Legal_Team and Investor_Relations
   notifiers on DISPOSITION LOIs too, because LOI_Signed__c is now set on the sell side.

9. flows/LOI_Signed_Status_Sync.flow-meta.xml - COMMENT AND <description> ONLY.
   🔴 NO element, connector, decision, assignment or <start> change - this flow governs
   a live acquisition path. Retract, verbatim, the claim "this flow is naturally
   Acquisition-only with no record-type criterion needed" and the matching sentence in
   <description>. State the new fact: from this change it also latches LOI_Signed__c
   and stamps LOI_Signed_Date__c on DISPOSITION LOIs reaching 'Signed'. Do not add a
   false branch (the existing DO-NOT banner still stands and is now load-bearing on two
   record types instead of one).

DO NOT TOUCH: DispositionStageEntryService.cls (it keys on Disposition__c.
Disposition_Stage__c string constants and never reads LOI__c.Stage__c - verified),
CounterOfferService.cls (no Stage__c reference at all), lwc/loiCounterOffer,
TestDataFactory.cls (its LOI fixtures seed 'Received' and 'Draft', neither removed),
Opportunity.Completed_LOI_Before_PSA, Opportunity.Deal_Sub_Stage__c, or any acquisition
map or allow-list.
```

---

## 5. DEPLOY ORDERING — where it is load-bearing

### 5.1 Relative to the undeployed working tree

`git status` shows an in-flight wave: `flexipages/LOI_Record_Page` (the fifth `Submit_for_Approval` criterion), `permissionsets/DPEG_Disposition_Edit`, `applications/Disposition.app`, `approvalProcesses/Disposition_Offer__c.Offer_Selection_Approval`, plus Apex sharing fixes.

**Recommendation: SHIP THE PENDING WAVE FIRST, then this one.** Reasons:

1. **Same file, two changes.** `LOI_Record_Page` is edited by both. Bundling means one deploy carries an unproven runtime construct *and* an unrelated subtractive change, and a revert becomes a tangled hand-edit rather than `git revert`.
2. **The pending change's renderer probe is a two-direction manual test** (that file's header, lines 244–252) that must be run by a human against a real disposition LOI at `Under Review` and a real acquisition LOI at `Under Review`. Both preconditions exist *today*. Run it while the fixtures are unambiguous.
3. **This wave has no dependency on it** (§0.3), so the order is free — take the safer one.
4. Per the concurrent-session hazard already recorded on this repo: **diff `LOI_Record_Page` and the three permission sets against `HEAD` immediately before deploying**, because shared hub files here have previously become a silent union of two sessions' work.

### 5.2 Within this wave — one atomic deploy

**Ship A1–A10 and D1–D12 as a SINGLE deploy, with a `destructiveChangesPost.xml` carrying the two quick actions and the two LWC bundles.** Precedent: `manifest/deal-tracker-loi-psa-retire/destructiveChangesPost.xml`.

Atomicity removes the ordering hazard rather than managing it. If the payload is nevertheless split, these are the load-bearing edges:

| Edge | Direction | Why it is load-bearing |
|---|---|---|
| **A1 (record type) BEFORE D1 (Apex map)** | 🔴 **strict** | If the repo's *unmeasured* "record-type picklist restriction is UI-only" claim is wrong, deploying the Apex map first means the very next `Advance Stage` click on a disposition LOI writes `Negotiation` to a record type that does not carry it — a restricted-picklist DML failure **in production**. Record-type-first is safe under **both** readings of the unmeasured claim. |
| **A1 and A2 (path) in ONE payload** | 🔴 **strict** | A `PathAssistant` step naming a value the record type does not expose is at best an invisible step and at worst a deploy rejection. Never leave a window where the two disagree. |
| **A5 (price VR) NOT AFTER D1** | strict | The moment `advance()` can derive `Signed` on a disposition LOI, the price guard must already be repointed, or the guard is silently absent for the length of the window. A5 uses `TEXT()`, so it is deploy-safe against any value at any time — there is no reason to defer it. |
| **A6 (flexipage) BEFORE A7/A8 (quick action delete)** | 🔴 **strict** | Deleting a quick action still referenced by a FlexiPage `<valueListItems>` fails the delete. `destructiveChangesPost` runs after the constructive package, which satisfies this by construction. |
| **D9/D10 (LWC delete) NOT BEFORE A7/A8** | strict | A quick action whose `<lightningWebComponent>` target no longer exists is a broken reference. Same payload, `destructiveChangesPost`, both together. |
| **A3 (`Stage__c` help text) — anywhere** | free | Text only. But 🔴 **the `<valueSet>` must be byte-identical** or the whole ordering analysis in §3.1 is void. |

### 5.3 Verification is a readback, never the deploy result

This repo has measured a deploy reporting *"689/689 deployed, 0 errors"* on a payload that rolled back completely, and a `RunSpecifiedTests` failure surfacing only as a `codeCoverageWarnings` entry that no error counter shows. It has also measured a FlexiPage construct that deploys, survives a retrieve, and is then ignored by the renderer.

⇒ **After deploy, prove it in the org:**
1. `sf` REST describe on `LOI__c.Stage__c` scoped to the `Disposition_LOI` record type — confirm exactly four values in the order Received, Under Review, Negotiation, Signed. **Do not use `sf project retrieve`** — a retrieve *unions* local and remote picklist values and will appear to restore the removed ones.
2. Same describe against `Acquisition_LOI` — confirm five values, unchanged.
3. Open the live disposition LOI: Path shows four steps; Advance Stage present; the two counter buttons **gone**.
4. `SELECT Id, Stage__c FROM LOI__c WHERE RecordType.DeveloperName='Disposition_LOI'` — confirm the count matches pre-deploy and no row was moved.

---

## 6. ROLLBACK

### 6.1 Trigger conditions

| Symptom | Meaning | Action |
|---|---|---|
| Path on a disposition LOI renders the wrong step order, or shows fewer/more than four steps | Master value-set order was disturbed, or the record type and path disagree | **Full revert.** Both are in the same atomic payload. |
| A disposition LOI cannot be saved — `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` | The Apex map is writing a value the record type does not expose ⇒ A1 did not land, or landed partially | **Full revert**, then re-deploy record-type-first. This also **measures** the repo's unmeasured UI-only claim — record the result in `Stage__c`'s header either way. |
| A disposition LOI cannot be saved — *"Enter the Final Agreed Price…"* at an unexpected stage | G1 discriminator wrong or missing | Deactivate **A5 only** (`<active>false</active>`) — a one-component deploy that leaves everything else live. Then fix the formula. |
| 🔴 **An ACQUISITION LOI cannot be saved or cannot reach Signed** | 🔴 **CONSTRAINT VIOLATED.** Almost certainly the G1 discriminator is missing (option C shipped by mistake) | **Immediate:** deactivate `Final_Price_Required_Before_Executed`. **Then:** full revert and re-plan. |
| Advance Stage missing on a disposition LOI at Received / Under Review / Negotiation | `Is_Advance_Allowed__c` was edited despite the instruction not to, or `Disposition_Deal_Actions` is not granted | Check the formula is byte-identical to §1.2 first. If it is, this is a permission issue, not this wave. |
| Advance Stage still shows on a disposition LOI at Signed | `Is_Advance_Allowed__c`'s clause 1 not evaluating — formula was edited | Revert that one field file. |

### 6.2 Revert mechanics

- **The constructive half is a clean `git revert`.** Every item in A1–A6, A9, D1–D8, D11, D12 is a file modification, and the previous content is in `HEAD`.
- 🔴 **The destructive half (A7, A8, D9, D10) is NOT symmetric.** Reverting restores the four source directories, but the org has already dropped the two quick actions and the two LWC bundles. Recovery requires a *constructive* re-deploy of those four components — which is why they must be staged as `destructiveChangesPost` and **why the whole wave should be validated check-only against production before the real deploy**. Keep the four deleted files in a branch until the wave is confirmed; do not rely on `git` history alone under time pressure.
- 🔴 **`Is_Advance_Allowed__c` is a formula field. It cannot be reverted by data.** If it is edited by mistake, the fix is a metadata re-deploy; there is no row-level remediation.
- **Do not revert `LOI_Signed__c` / `LOI_Signed_Date__c` values on disposition rows by hand.** The latch is one-way by design and the values are harmless (nothing active reads them on the sell side — §1.3). Clearing them is a data change nobody asked for.
- **A check-only validation is not proof for unchanged components.** Byte-identical components report `Unchanged` and are skipped, and a comment-only XML edit is stripped at source conversion, so it produces no diff at all. A green dry-run on this wave may mean several components were never validated. Rely on the §5.3 readbacks.

---

## 7. TEST IMPACT

### 7.1 Apex — `RecordStageAdvanceServiceTest.cls`

| Method | Line | Outcome without edit | Required change |
|---|---|---|---|
| `underReviewIsSharedByBothLoiRecordTypesAndStillRoutesByRecordType` | ~836 | 🔴 **RED** — asserts `'LOI moved to Countered by DPEG.'` (line 859) | Expected disposition hop → `Negotiation`. Its point (the shared `Under Review` routes by record type) is **unchanged and still valuable**. |
| `dispositionLoiWalksReceivedToExecuted` | ~869 | 🔴 **RED** — asserts a four-message walk ending `'LOI moved to Executed.'` and a final `Executed` read-back | Rewrite as `dispositionLoiWalksReceivedToSigned`: three hops + terminal refusal. ⚠ Keep the `Final_Agreed_Price__c` pre-set **at `Received`**, before the stage moves, so the price rule cannot fire on that same update. |
| `dispositionLoiExecutedWithBlankFinalPrice_surfacesValidationRuleMessage` | ~923 | 🔴 **RED** — fixture at `'Counter Received from Buyer'`, expects the Executed-worded message | Rename `..._Signed...`; fixture `'Negotiation'`; message repointed. Depends on **G1**; under G1-D delete the test and say why. |
| `dispositionLoiAcceptsTheNegotiationLoopTargets` | ~1640 | 🔴 **RED** — `advanceTo` both loop values | **DELETE.** Its subject is retired. |
| `dispositionLoiRefusesTheAcquisitionExplicitTargets` | ~1545 | ⚠️ **GREEN — and its stated rationale inverts** | Keep; rewrite comments. `'Signed'` and `'Negotiation'` are now *legal disposition values*; the refusal now proves the allow-lists are disjoint, not that the value sets are. |
| `acquisitionLoiRefusesADispositionStageAsAnExplicitTarget` → **RENAMED** `acquisitionExplicitTargetListHasNotWidenedToTheUnion` | ~1583 | ⚠️ **GREEN — and becomes VACUOUS** | Keep; rewrite comments **and the NAME** (done 2026-08-21). All three probes are now allow-listed nowhere, so the test proves only "the acquisition list has not widened to the union" — which is what its own comment says `'Executed'` alone used to prove. **Do not delete** and do not let it masquerade as a cross-type leak test. 🔴 The rename is the load-bearing half of that last sentence: the method name is what appears in test output and in §8.6, and neither surface shows the comment that disclaims the old name. |
| `loiWalksDraftToSigned`, `acquisitionLoiWithValidTermsWalksDraftToSigned`, `loiGateIsResolvedPerRecordTypeNotPerObject`, `bothRecordTypesWalkLoiToPsaThenStopNamingContractExecutionService` | — | **GREEN, correctly** | **No change.** These are the acquisition-untouched evidence (§8). |

⚠️ The two GREEN-but-wrong rows are the ones to insist on. This repo has measured four vacuously-passing assertions in a single sweep; a test that stays green while its premise inverts is this project's characteristic failure mode.

### 7.2 Apex — other

- `DispositionDealSummaryServiceTest.cls` line 271/283 — 🔴 **RED or, worse, GREEN-but-meaningless.** `'Executed'` remains on the master value set, so the DML may well be accepted even after the record-type restriction (record-type restriction is repo-asserted **UI-only and unmeasured**). If it passes, it is asserting a state no disposition LOI can legitimately occupy. Repoint to `'Signed'`. ⚠️ Under `'Signed'`, `LOI_Signed_Status_Sync` now fires on the fixture and stamps `LOI_Signed_Date__c` — the `json.contains('loiSignedDate')` assertion at line 288 still passes (the DTO has no such member) but its *message* at 289 becomes a lie and must be rewritten.
- `CounterOfferServiceTest` / `CounterOfferControllerTest` — swept: no `Stage__c` reference. **No change.**
- `DispositionStageEntryServiceTest` — **no change** (§1.1).

### 7.3 Jest

- `lwc/loiMarkCounteredByDpeg/__tests__/` and `lwc/loiMarkCounterReceived/__tests__/` — **deleted with their bundles.** Jest is local-only and never deploys, so nothing in the org is affected; but a deleted bundle with a surviving test file breaks the whole `npm test` run.
- `lwc/dispositionDealSummary/__tests__/dispositionDealSummary.test.js` — **GREEN with a dead fixture.** Repoint lines 132 and 216. The `NARROW COLUMN` CSS test (594–605) and both `@sa11y` accessibility tests stay green provided the CSS rules survive.
- No other Jest suite references an LOI stage value.

### 7.4 Bulk requirements per `.claude/rules/bulk-test-rule.md`

**The 251-record mandate does NOT apply to any test in this wave, and that must be stated in the test class header so review does not demand it.**

`RecordStageAdvanceService.cls`'s own header records the exemption verbatim: *"advance() is a per-transaction-singleton @AuraEnabled operation invoked once per quick-action click: one record, one selector read, one update, no loop over records and no collection DML."* There is no trigger, no batch, and no loop over records — a 251-record test would exercise no additional code path and would risk tripping the 150-DML limit while proving nothing, which is precisely the anti-pattern the rule's exemption clause exists to prevent.

⚠ The exemption is **narrow and does not travel**. `DispositionStageEntryService` is trigger-driven and is explicitly **not** exempt (its header carries literal 251-record bulk tests for all five stages with a documented ≤5 SOQL / ≤5 DML per-chunk budget) — which is another reason this wave must not touch it.

`.claude/rules/content-publication-rule.md` is not engaged: no `ContentVersion`, `ContentNote` or `ContentDocument` is created anywhere in this change.

---

## 8. "ACQUISITION UNTOUCHED" PROOF

Five independent checks. Each is falsifiable; none relies on a deploy succeeding.

### 8.1 Metadata diff assertions (run before deploy)

```
git diff --stat HEAD -- force-app/main/default/objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml
git diff --stat HEAD -- force-app/main/default/pathAssistants/LOI_Path_Acquisition.pathAssistant-meta.xml
```
⇒ **must be EMPTY.** Neither file is in scope.

```
git diff HEAD -- force-app/main/default/objects/LOI__c/fields/Stage__c.field-meta.xml
```
⇒ the diff **must not contain a single line inside `<valueSet>`**. Only `<description>` and `<inlineHelpText>` may appear.

```
git diff HEAD -- force-app/main/default/objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml
```
⇒ the diff **must not contain `<formula>`**.

```
git diff HEAD -- force-app/main/default/flows/LOI_Signed_Status_Sync.flow-meta.xml
```
⇒ only `<description>` and the XML comment. No `<decisions>`, `<assignments>`, `<connector>` or `<start>` line.

```
git diff HEAD -- force-app/main/default/flexipages/LOI_Record_Page.flexipage-meta.xml
```
⇒ **deletions only** within `<valueList>`, and the deleted blocks' `<value>` elements must read exactly `LOI__c.Mark_Countered_By_DPEG` and `LOI__c.Mark_Counter_Received`. No line touching `Submit_for_Approval`, `Advance_Stage`, `Mark_Countered`, `Mark_Completed` or `enableActionsConfiguration`.

### 8.2 The value-set proof

Post-deploy, via **REST describe** (never `sf project retrieve` — it unions picklist values):

- `Acquisition_LOI` → `Stage__c` = exactly `Draft, Under Review, Submitted, Negotiation, Signed`, with `Draft` default. Five values, same order.
- Master `Stage__c` value set → **thirteen values, unchanged order, unchanged active/inactive flags**. Positions 1–13 exactly as §3.1.

### 8.3 The eleven live records

```
SELECT RecordType.DeveloperName, Stage__c, COUNT(Id)
FROM LOI__c GROUP BY RecordType.DeveloperName, Stage__c
```

Run **before and after**. The acquisition rows (reported as 4 Draft + 2 Negotiation + 5 Signed) must be **identical in both runs**. Nothing in this wave writes to an acquisition LOI:
- No trigger on `LOI__c` is touched.
- `LOI_Signed_Status_Sync` is a *before-save* flow on save only — a deploy does not re-save rows.
- No `@InvocableMethod`, batch, queueable or script in this wave writes `LOI__c`.

### 8.4 The button proof (manual, in-org)

| Record | User holds | Expect |
|---|---|---|
| Acquisition LOI at `Submitted` | `Acquisition_Deal_Actions` | `Mark_Countered` **and** `Mark_Completed` **both present** — this is the check that `Submitted` was not added to `Disposition_LOI` |
| Disposition LOI at `Under Review` | `Disposition_Deal_Actions` | `Advance Stage` present; **no** counter buttons; **no** acquisition Mark_* buttons |
| Acquisition LOI at any of `Draft`/`Under Review`/`Negotiation` | `Acquisition_Deal_Actions` | `Advance Stage` present, exactly as before |
| Acquisition LOI at `Signed` | `Acquisition_Deal_Actions` | `Advance Stage` **absent** (unchanged — clause 1 has always excluded `Signed`) |

### 8.5 The validation-rule proof — the sharpest one

**This is the check that catches a G1-option-C mistake, and nothing else does.**

On an acquisition LOI at `Negotiation` with `Final_Agreed_Price__c` **blank**, advance to `Signed` (via `LOI__c.Mark_Completed`, or `RecordStageAdvanceService.advanceTo(loiId, 'Signed')`).

⇒ **It MUST SUCCEED.** If it is refused with *"Enter the Final Agreed Price…"*, the discriminator is missing and the constraint has been violated. Deactivate the rule immediately (§6.1).

The complement, on the same run: a disposition LOI at `Negotiation` with a blank `Final_Agreed_Price__c` advancing to `Signed` **must be REFUSED** — otherwise the sell-side guard has been silently lost and the wave shipped G1-option-D by accident. **Both directions are required**; either alone is indistinguishable from a rule that does nothing.

### 8.6 Acquisition Apex regression set

Run and expect green, unchanged: `RecordStageAdvanceServiceTest.loiWalksDraftToSigned`, `.acquisitionLoiWithValidTermsWalksDraftToSigned`, `.acquisitionExplicitTargetListHasNotWidenedToTheUnion` (⚠ **RENAMED 2026-08-21** from `.acquisitionLoiRefusesADispositionStageAsAnExplicitTarget` — the old name claimed a cross-type refusal the method no longer performs; see §8.5's row for it), `.loiGateIsResolvedPerRecordTypeNotPerObject`, `.bothRecordTypesWalkLoiToPsaThenStopNamingContractExecutionService`, and `RecordStageAdvanceControllerTest.advanceToWritesAnAllowedExplicitTarget` (which writes `'Signed'` on an *acquisition* LOI and asserts it lands — the complement that stops 8.5's positive case passing vacuously).

⚠ **Include the test classes in the deploy payload.** A `--tests` run executes the **org's** copy of a class, so a targeted run can silently execute fewer methods than the repo has and still report 100%.

---

## 9. OPEN UNCERTAINTIES — and the check that resolves each

| # | Uncertainty | Why it is not guessed | Resolving check |
|---|---|---|---|
| U1 | **Is record-type picklist restriction enforced by Apex DML?** The repo asserts UI-only ~20 times and has **never measured it**. This project has already measured that a *restricted value set* IS enforced (`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`), which is a different mechanism. | It decides whether §5.2's record-type-first ordering is a nicety or a hard requirement, and whether `Is_Advance_Allowed__c`'s retained `<> "Executed"` clause is a live guard or dead code. | Post-deploy, from anonymous Apex: `update new LOI__c(Id = <dispositionLoiId>, Stage__c = 'Executed')`. Accepted ⇒ UI-only confirmed. Refused ⇒ **record it in `Stage__c`'s header and correct the ~20 stale assertions**; the ordering in §5.2 becomes mandatory. |
| U2 | **Does the FlexiPage renderer honour `{!Record.RecordType.DeveloperName}`?** Validated at the metadata layer by a four-probe check-only run on 2026-08-21 (probe B proves the validator traverses the relationship), but **never seen at runtime**. | This wave does **not** depend on it (§0.3). It matters only for the pending `Submit_for_Approval` change. | The two-direction probe in `LOI_Record_Page`'s header, lines 244–252. Run it **before** this wave (§5.1). |
| U3 | **Exact live disposition-LOI row distribution.** The brief reports 1 record at `Under Review`; the measurement is dated. | A row on a removed value turns a deploy into a data escalation. | `SELECT Stage__c, COUNT(Id) FROM LOI__c WHERE RecordType.DeveloperName='Disposition_LOI' GROUP BY Stage__c` **at deploy time**. Any non-zero count on `Countered by DPEG`, `Counter Received from Buyer` or `Executed` ⇒ **STOP**. |
| U4 | **The three `Counter_*` LOI fields** (`Counter_Price__c`, `Counter_Cap_Rate__c`, `Counter_Received_Date__c`, `Counter_Response__c`, `Counter_Response_Due__c`) remain on the object and on the LOI layout. Their sell-side capture route was the two retired buttons. | User decision 2 says counter rounds move to Counter History (`Counter_Offer__c` / `c/loiCounterOffer`), which is unchanged and present in the page's `main` region. But nobody has confirmed whether the flat `Counter_*` fields should stay on the **disposition** view. | Ask the user. Deliberately **not** in scope for this wave — retiring or hiding them is a separate decision with its own blast radius (`Counter_Price_Is_Positive` gates one of them, and `seed-fsd-*` scripts populate them on the acquisition side). |
| U5 | **Exact character counts** of the new `<description>` / `<inlineHelpText>` / `<errorMessage>` values. | This programme has breached the 255 cap **three** times, and one over-cap `inlineHelpText` would fail the whole atomic payload. | Measure with `System.Xml.XmlDocument.Load()` on the **decoded stored value**, not with `Get-Content -Raw` (which mangles this repo's non-ASCII characters and reports the wrong number). |
| U6 | **MCP unavailable from this agent.** `.claude/rules/salesforce-global-rule.md` mandates `salesforce-api-context` for every metadata type, but `.mcp.json` configures only the `salesforce` server and subagents have no MCP tools. | Stated rather than silently dropped. | The implementing agents must record `mcp=unavailable` after a real attempt and fall back to the per-type skill. No metadata shape in this wave is novel — every element used (`<picklistValues>`, `<pathAssistantSteps>`, `<errorConditionFormula>`, `<valueListItems>`) has direct in-repo precedent, so no shape gate is required. |

---

## 10. SUMMARY OF DECISIONS REQUIRED FROM THE USER

1. **G1** — `Final_Price_Required_Before_Executed`: adopt option **A** (`NOT(ISBLANK(Disposition__c))` + `Signed`), keeping the rule's API name? *Recommended.*
2. **G2** — accept `LOI_Signed_Status_Sync` latching `LOI_Signed__c` / stamping `LOI_Signed_Date__c` on disposition LOIs, with **no edit** to that flow's logic? *Recommended.*
3. **G3** — leave `Countered by DPEG`, `Counter Received from Buyer` and `Executed` **active** on the master value set (orphaned, on no record type)? *Recommended.*
4. **G4** — ship the pending `LOI_Record_Page` / permission-set / approval-process wave **first**, run its renderer probe, then ship this? *Recommended.*
5. **U4** — should the flat `Counter_*` fields stay on the disposition LOI view now that the counter buttons are retired? *No recommendation — genuinely a business question.*
