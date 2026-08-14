# Deploy Runbook — Acquisition Observations, Phase 2 (declarative)

**Author:** salesforce-solution-architect · **Date:** 2026-08-14
**Target org:** `usman-dpeg` (`usman.khan.dpeg@avanzasolutions.com`, `00Diw000000Fqw1EAC`)
**Source:** `docs/superpowers/specs/2026-08-14-acquisition-app-observations-design.md` §3,
`agent-output/design-requirements-acquisition-observations.md` §3 (Phase 2) / §6.2 / §7 (Phase 2) / §8 / §9 C7
**Model:** `agent-output/runbook-acquisition-observations-phase1.md` — same shape, same conventions.

**NOTHING IN THIS PACK HAS BEEN DEPLOYED.** Every step below is pending.
**Phase 2 is serialised AFTER Phase 1.** Do not start P2-D1 until Phase 1 has completed through P1-D4.

The change is one thing: `Opportunity.StageName` value `PSA` → `Under Contract (PSA)`.
It is a **value migration on live records**, not a new stage, so it runs in the same
add → migrate → repoint → retire shape Phase 1 used.

---

## 0. Read this before anything else

### 0.1 🔴 C7 — the twelve DISPOSITION files that must NOT be touched

`Disposition__c.Disposition_Stage__c` has **its own, unrelated `PSA` value**. It is the stage
at which `DispositionStageEntryService` opens the **sell-side** `Contract_Review__c`. It has
nothing to do with `Opportunity.StageName`.

A repo-wide find/replace on `PSA` renames both. The result **deploys green and passes every
Apex test**, because the rename would be internally consistent across code and metadata while
being semantically wrong — it would break the two disposition Paths, `dispositionSidebar`,
`All_NDAs_Signed_Before_Progression`, the field translation, both disposition record types and
the sell-side PSA auto-create, with nothing anywhere reporting a problem.

**This list is reproduced here in full so a future operator has it in front of them rather
than having to rediscover it** (source: requirements §6.2, "THE DANGEROUS HALF"):

| # | File | Why it is disposition |
|---|---|---|
| 1 | `objects/Disposition__c/fields/Disposition_Stage__c.field-meta.xml` | the value definition itself |
| 2 | `objects/Disposition__c/recordTypes/On_Market.recordType-meta.xml` | enumerates the value |
| 3 | `objects/Disposition__c/recordTypes/Off_Market.recordType-meta.xml` | enumerates the value |
| 4 | `objects/Disposition__c/validationRules/All_NDAs_Signed_Before_Progression.validationRule-meta.xml` | gates the disposition stage |
| 5 | `objectTranslations/Disposition__c-en_US/Disposition_Stage__c.fieldTranslation-meta.xml` | the field translation |
| 6 | `pathAssistants/Disposition_Path_On_Market.pathAssistant-meta.xml` | disposition Path step |
| 7 | `pathAssistants/Disposition_Path_Off_Market.pathAssistant-meta.xml` | disposition Path step |
| 8 | `flexipages/Disposition_Record_Page.flexipage-meta.xml` | disposition visibility rules |
| 9 | `lwc/dispositionSidebar/**` | disposition UI |
| 10 | `lwc/dispositionSidebar/__tests__/**` | its Jest suite |
| 11 | `classes/DispositionStageEntryService.cls` | the sell-side PSA auto-create |
| 12 | `classes/DispositionStageEntryServiceTest.cls` | **12 occurrences — the single largest `PSA` count in the whole repo, and every one is disposition** |

**Verified for this build:** none of the twelve files above is modified. Re-run that check as a
gate on every Phase 2 deploy — see §3 P2-D2.

> ⚠ **A THIRTEENTH FILE THE GATE GUARDS, deliberately not renumbered into the table above.**
> The twelve-file list is reproduced verbatim from requirements §6.2 and is left as sourced.
> But `pathAssistants/Disposition_Path.pathAssistant-meta.xml` — a third, **inactive**
> (`<active>false</active>`) disposition Path — carries **`PSA_Executed__c`** (L60, L62). It has
> no `Disposition_Stage__c` `PSA` value, so it is not a C7 file in the original sense, yet it is
> precisely what the **bare-token `PSA` sweep** of §1.2 would hit. The §3 P2-D2 gate pattern
> therefore covers it too (re-review S-1). Being inactive makes it *worse*: a corruption there
> shows up nowhere in the UI.

> 🔴 **AMENDED 2026-08-14 — THE GATE'S ORIGINAL PATTERN WAS A SUBSTRING MATCH ON `Disposition`
> AND IT IS TOO BROAD. IT NOW FIRES ON LEGITIMATE WORK.**
> The check was first written as `git status --porcelain -- force-app | grep -iE "Disposition"`,
> and it was calibrated when nothing disposition-named was dirty. It is now **false-positive** on
> concurrent Phase 3 work: `objects/Contract_Review__c/recordTypes/Disposition_PSA` and
> `objects/LOI__c/recordTypes/Disposition_LOI` are **disposition-NAMED record types on
> ACQUISITION-side objects**, they are **not** on the twelve-file list above, and Phase 3 edits
> them by design (measured 2026-08-14: both diffs are comment/`<description>` text only — **zero**
> `<picklistValues>` changes).
>
> ⚠ **This matters more than a cosmetic false alarm.** A gate that fires on expected work gets
> waved through, and the run in which it fires for the REAL reason looks exactly like the four
> before it. An over-broad safety check does not fail safe — it decays into noise and then fails
> open. The corrected pattern in §3 P2-D2 matches the twelve C7 paths and nothing else.

### 0.2 Encoding — do NOT encode this value

`Under Contract (PSA)` contains spaces and parentheses but **no `/`**, so **no `%2F` encoding
applies anywhere**. Write it literally in every file type: `StandardValueSet`,
`BusinessProcess`, `RecordType`, `PathAssistant`, `ValidationRule`, `FlexiPage`, `ListView`.

The trap is real and one file over: `Dead/Pass` **is** encoded `Dead%2FPass` inside
`BusinessProcess` and `RecordType` metadata, and sits three entries above the new value in all
three business-process files. The encoding applies to **slashes**, not to punctuation in
general. `objects/Opportunity/businessProcesses/Retail.businessProcess-meta.xml` already
carried a comment warning about exactly this before Phase 2 started.

### 0.3 Scope boundaries observed

- **Apex and LWC were NOT touched.** The developer agent owns them concurrently. `git status`
  shows Apex/LWC modifications; those are theirs, not this build's.
- **No API name was renamed.** `Opportunity.Advance_to_PSA` (quick action),
  `Approved_LOI_Before_PSA` / `Completed_LOI_Before_PSA` (validation rules) and
  `Deal_Tracker_PSA` (list view) keep their API names. Only **labels** and **values** moved.
  Renaming any of them is a delete-and-recreate with a much larger blast radius (FlexiPage
  `valueListItems`, page layouts, saved URLs), and the observation does not require it. The new
  value still contains the string "PSA", so the names do not become misleading.
- **No approval process needed a change.** Measured 2026-08-14: `Opportunity.LOI_Approval` and
  `Opportunity.Underwriting_Approval` have `entryCriteria` of `StageName equals LOI` and
  `StageName equals Underwriting` respectively. Neither references the PSA stage.

---

## 1. Current repo state

The working tree is at **P2-D1 + P2-D2 state**: the new value is added everywhere *and* every
live acquisition reference is repointed. The subtractive step (P2-D3) is **staged as a script,
not applied** — the tree must stay deployable at the current step.

### Modified — P2-D1, additive (both values present and active)

| File | Change |
|---|---|
| `standardValueSets/OpportunityStage.standardValueSet-meta.xml` | `+ Under Contract (PSA)` immediately after `PSA`. `forecastCategory Forecast`, `probability 85`, `closed false`, `won false` — **copied verbatim from the outgoing `PSA` entry**, not chosen. `<sorted>false</sorted>`, so the position is the displayed pipeline order. |
| `objects/Opportunity/businessProcesses/Land.businessProcess-meta.xml` | `+ Under Contract (PSA)`, keeping `PSA` |
| `objects/Opportunity/businessProcesses/Retail.businessProcess-meta.xml` | `+ Under Contract (PSA)`, keeping `PSA` |
| `objects/Opportunity/businessProcesses/Commercial.businessProcess-meta.xml` | `+ Under Contract (PSA)`, keeping `PSA` — see the note below |
| `reports/Acquisitions/Deal_Pipeline_by_Stage.report-meta.xml` | 🔴 `STAGE_NAME` filter `+ Under Contract (PSA)`, keeping `PSA`. **The C1 miss — see §1.1**, which also explains why this file is at P2-D1 and not, as first drafted, at P2-D2. |

> **Why `Commercial` is included even though Phase 1 retires it.** The brief asked for it, and
> it costs nothing: the value is added additively, and if P1-D4 has already deleted the file
> the P2-D3 script reports a SKIP rather than failing. It exists so that a Phase-2 start that
> overlaps an unfinished Phase 1 does not leave a live record type whose business process is
> missing the new stage — which would make every deal on that record type unsavable at the new
> stage. Values are alphabetically ordered in all three files; the new value sorts between
> `PSA` and `Under Review`, which is where it was inserted.

**`forecastCategory` and `probability` are the reason this is a migration and not a new stage.**
`forecastCategory` drives every forecast roll-up and `probability` drives Expected Revenue, so a
deal moving from `PSA` to `Under Contract (PSA)` must not move in any forecast. Both were copied
from the outgoing entry; if that entry is ever edited before P2-D3, **re-copy, do not re-derive**.

### Modified — P2-D2, repoint

| File | Change | Occurrences |
|---|---|---|
| `objects/Opportunity/validationRules/Approved_LOI_Before_PSA.validationRule-meta.xml` | `ISPICKVAL(StageName,'PSA')`, `<description>`, `<errorMessage>`, comment prose | 1 formula + 3 prose |
| `objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml` | same shape | 1 formula + 6 prose |
| `objects/Opportunity/validationRules/NDA_Signed_Before_Deal_Progression.validationRule-meta.xml` | one entry in the 5-stage `OR` list, `<description>`, comment prose | 1 formula + 2 prose |
| `objects/Opportunity/validationRules/No_Backward_Stage_Movement.validationRule-meta.xml` | **4 rank-map entries** + **7 comment mentions** — see the count correction below | 4 formula + 7 prose |
| `objects/Opportunity/fields/Deal_Bucket__c.field-meta.xml` | **two strings on one line** — the stage test AND the bucket output label | 2 |
| `objects/Opportunity/listViews/Deal_Tracker_PSA.listView-meta.xml` | filter `<value>` + `<label>`. API name unchanged. | 2 |
| `pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml` | `<picklistValueName>` only | 1 |
| `quickActions/Opportunity.Advance_to_PSA.quickAction-meta.xml` | `<label>` only → `Advance to Under Contract (PSA)` | 1 |
| `flexipages/Opportunity_Record_Page.flexipage-meta.xml` | 2 `{!Record.StageName}` criteria | 2 |

⚠ **`reports/Acquisitions/Deal_Pipeline_by_Stage` is deliberately NOT in this table.** It is the
C1 miss and it is an **additive** edit, so it sits in the P2-D1 table above. §1.1 explains why.

### 🔴 1.1 C1 — an in-repo REPORT filters on `PSA`, and every delimiter-anchored sweep walked past it

**Requirements §6.2 and §5 G8-a below both say org-side reports are "not fully represented in
this repo." That is FALSE for one file**, and the file it is false for is the acquisition
pipeline report:

```
force-app/main/default/reports/Acquisitions/Deal_Pipeline_by_Stage.report-meta.xml
```
```xml
<criteriaItems>
    <column>STAGE_NAME</column>
    <operator>equals</operator>
    <value>New,Under Review,Development Review,Construction Review,Underwriting,LOI,PSA</value>
</criteriaItems>
```
It also **groups down on `STAGE_NAME`**.

**What it does after the backfill if left alone:** the operator is `equals`, so every migrated
deal fails the filter. The PSA column does not go empty — it **DISAPPEARS from the grouping and
takes its deals out of the report's totals**, with no error, no deploy failure and no failing
test. A pipeline report that silently under-reports is worse than one that visibly breaks.

**Why it was missed, and this is the reusable part:** a report filter stores a multi-value
picklist selection as **ONE comma-joined string inside a single `<value>` element**. Every
delimiter-anchored pattern the P2 inventory used — `>PSA<`, `'PSA'`, `<fullName>PSA`,
`<value>PSA</value>` — is anchored on a boundary that this shape does not have, so all four
miss it. The token is sitting there in plain text; the *patterns* were the defect, not the
coverage.

**FIX APPLIED: list BOTH values from P2-D1, drop the old one at P2-D3.**
`...,Underwriting,LOI,PSA,Under Contract (PSA)`. A report filter naming a picklist value the
org does not (yet) have **deploys fine** — it is stored as a string, not resolved against the
value set — so both-then-drop leaves **no window in either direction**: before the backfill the
old value still matches, after it the new one does, and at no point is a live deal outside the
filter. The P2-D3 drop is staged as the fifth edit in
`agent-output/p2-d3-retire-psa/apply-d3.js`.

#### 🔴 Why this file is at P2-D1 and not with the other repoints at P2-D2

**Because "correct on both sides of the backfill" is not a curiosity about this file — it is the
property that decides which step it belongs to.** P2-D2 runs *after* the backfill. Every other
P2-D2 file has to: each one **MOVES** a value, and the four `ISPICKVAL` rules plus
`Deal_Bucket__c` are hard-blocked until P2-D1 lands, because naming a value the org does not
have is a **deploy-time error** for a formula. The report has neither property — it **ADDS** a
value and resolves nothing — so nothing prevents it from going in at P2-D1, and leaving it at
P2-D2 would open a window between the backfill and that deploy in which the org's copy still
reads `...,LOI,PSA` while every just-migrated deal sits outside the filter. Short, since §4
requires the backfill and P2-D2 to share one maintenance window — but the C1 failure mode is
*silent under-reporting*, so a short window is still a window that nobody would notice. At P2-D1
it does not exist.

🔴 **It goes into P2-D1 as a NAMED PER-FILE addition, never by widening the tooling to a
directory.** P2-D1 carries a "deploy nothing else at this step" warning and that warning is
still fully in force: the tree as a whole is **not deployable** at P2-D1, because four validation
rules and `Deal_Bucket__c` reference a value the org does not yet have. Adding one explicitly
named file that is safe at that step does not weaken it; picking up `reports/` — or worse,
`objects/Opportunity/` — does.

**No XML comment was added to the report file.** Zero of the 93 files under `reports/` and
`dashboards/` carries one (measured), and the Report Builder rewrites the file on any in-org
edit — the same property that kept a comment off `Opportunity_Record_Page`. This section is the
documentation instead.

### 🔴 1.2 STANDING RULE — a picklist-value rename needs a BARE-TOKEN sweep of `reports/`, `dashboards/` and every `listViews/`

Delimiter-anchored patterns are **provably insufficient** for these three directories, because
report filters, dashboard filters and list-view filters all serialise multi-value selections as
one delimited string. Sweep on the **bare token** and read every hit by hand:

```bash
node -e "
const fs=require('fs'),path=require('path');
const TOKEN=/\bPSA\b/;                       // <- the bare value, no XML anchors
const hits=[];
(function walk(d){ if(!fs.existsSync(d))return;
  for(const e of fs.readdirSync(d,{withFileTypes:true})){ const p=path.join(d,e.name);
    if(e.isDirectory()) walk(p);
    else if(/\.(report|dashboard|listView)-meta\.xml$/.test(e.name))
      fs.readFileSync(p,'utf8').split(/\r?\n/).forEach((l,i)=>{ if(TOKEN.test(l)) hits.push(p+':'+(i+1)+': '+l.trim()); });
  }})('force-app/main/default');
console.log(hits.join('\n')||'no hits');"
```

Run it from the repo root. Re-run **2026-08-14 after this fix**: it returns exactly two files —
`Deal_Pipeline_by_Stage` (now carrying both values) and `Deal_Tracker_PSA`, whose remaining
`PSA` is only its unchanged **API name**. Those are the complete in-repo populations; anything
else is org-side and belongs to gates **G8-a** / **G8-b**.

⚠ This sweep is **in addition to**, not instead of, the syntactic sweep — a bare token over
`classes/` or `objects/` returns the unusable 76-file result §6.2 warns about. Bare token for
these three directories; syntactic form everywhere else.

### 🔴 Count correction — `No_Backward_Stage_Movement` has ELEVEN occurrences, not five

Requirements §6.2 and the build brief both say *"FIVE occurrences — four inside separate
`CASE()` blocks plus a comment."* **The four-in-the-formula half is exactly right. The comment
half is wrong by six.** Measured 2026-08-14 by parsing the file:

| Region | Count | Lines (pre-edit) |
|---|---|---|
| `<errorConditionFormula>` — four separate `CASE()` blocks | **4** | 143, 148, 153, 157 |
| XML comment | **7** | 18, 25, 36, 75, 76, 90, 113 |
| **Total** | **11** | |

The four formula sites are two rank-guard `CASE()`s plus **two more inside the "is it backward?"
comparison** — they are separate expressions, so a repoint that catches three of four leaves the
rule silently half-blind. All four were changed.

The seven comment sites matter too, and one of them is not prose: **line 36 is the RANK MAP**,
the documentation twin of the formula, which the file's own instructions tell the next editor to
maintain. All seven were changed. Per this repo's standing rule, comments are load-bearing
documentation, so this is work that moves category, not work that disappears.

### 🔴 `Deal_Bucket__c` — two different kinds of string on one line, and one has consumers outside this pack

The line read `IF(ISPICKVAL(StageName,'PSA'), 'PSA',`. **Both were changed, for different
reasons:**

- The **first** is the stage test. Leaving it would send every migrated deal to the
  `Interested Deals` fall-through bucket — silently.
- The **second** is this formula's own **output label**. It was moved so the Deal Tracker does
  not show a bucket named `PSA` full of deals whose stage reads `Under Contract (PSA)` — which
  is the exact confusion this rename exists to remove.

**The output move has three consumers and none of them is in the file:**

1. `objects/Opportunity/listViews/Deal_Tracker_PSA` — its filter is
   `Deal_Bucket__c EQUALS <value>`; the value moved with it. **They must deploy together** or
   the list view silently returns nothing. Both are in P2-D2.
2. ✅ **`classes/ContractExecutionServiceTest.cls` — DONE, do not chase it and do not "fix" it
   back.** ⚠ **This item previously read "line 139 asserts `Deal_Bucket__c == 'PSA'` … not yet
   modified in the working tree." Both halves are now stale** (re-verified 2026-08-14, re-review
   S-3a): the developer agent has repointed it, the assertion now reads
   `System.assertEquals('Under Contract (PSA)', o.Deal_Bucket__c, 'Tracker bucket follows')`, and
   it has moved to **line 157** — line 139 is now the `SELECT`. An operator acting on the old
   text would either hunt for work that is finished or, worse, revert a now-correct assertion.
   It was always the **loud** half of the output move; the `Deal_Tracker_PSA` list-view filter
   (item 1) and org-side reports (item 3) remain the silent ones.
3. Org-side **reports and dashboards** filtering or grouping `Deal_Bucket__c = 'PSA'`. These are
   the silent ones — they are not fully represented in this repo. Gate **G8**.

The other four `Deal_Tracker_*` list views filter on `Dead`, `Bought/Closed`,
`Interested Deals` and `LOI` (measured), so none of them is affected.

### Verified, do NOT change — three `PSA` strings that are not the stage

| Site | What it actually is |
|---|---|
| `flexipages/Opportunity_Record_Page` L110 `<value>Opportunity.Advance_to_PSA</value>` | the quick action's **API name** |
| `flexipages/Opportunity_Record_Page` L990/991 `Record.Primary_Contract__r.PSA_Date__c` | a **field** on `Contract_Review__c` |
| `pathAssistants/Acquisitions_Deal_Path` L9 and L37 `<info>` prose | the **PSA document** ("PSA executed and in closing/escrow", "Seller issues the first PSA draft"), on the `About to Close` and (former) `PSA` steps. Both remain correct English after the rename. |

Requirements §6.2 also flags `layouts/Contract Review Layout` as VERIFY-BEFORE-TOUCHING. It was
not opened, because it is a `Contract_Review__c` layout and cannot contain an Opportunity stage
value — **it is not in this pack's file list and was not modified.**

### Staged, NOT applied

| Package | Purpose |
|---|---|
| `agent-output/p2-d3-retire-psa/` | the subtractive P2-D3 step. `node apply-d3.js --check` validates all four edits without writing; `node apply-d3.js` writes all-or-nothing. |
| `agent-output/p2-flexipage-p1d3-safe/` | ⚠ **[CORRECTED 2026-08-14 — this row read "generates a **Phase-1-only** copy of `Opportunity_Record_Page` for P1-D3 to deploy", which is now FALSE in both halves.]** It generates a copy for **P1-D3 *and* for P2-D2** — `--phase 1` / `--phase 2` — and both copies must strip Phase 4's panel unless P4-D has already deployed. **P2-D2 no longer deploys the tree file.** See §2. |

---

## 2. 🔴 ONE FILE, THREE PHASES — who owns `Opportunity_Record_Page`

⚠ **This heading read "ONE FILE, TWO PHASES" and the sentence below it read "both phases' edits"
until 2026-08-14. Both were true when written and are now FALSE — Phase 4 edits this page as well,
and its edit changes what P2-D2 deploys. Corrected in place, not appended below, so neither wording
survives as a quotable standalone instruction.**

`flexipages/Opportunity_Record_Page.flexipage-meta.xml` now carries **all THREE phases' edits**, and
**a FlexiPage deploys whole**:

- **Phase 1** — two `{!Record.Deal_Type__c}` criteria repointed `Commercial` → `Retail`, plus
  four new Opportunity field items (`Listing_Status__c` + the three score fields). Phase 1's
  runbook assigns this file to **P1-D3** and instructs "deploy at D3, never at D1", because
  deploying it before the Deal Type backfill hides the Construction tab on every commercial deal.
- **Phase 2** — two `{!Record.StageName}` criteria repointed `PSA` → `Under Contract (PSA)`,
  gating `Opportunity.Move_to_About_to_Close` (L132) and `Opportunity.Close_Deal` (L148).
- **Phase 4** — the `c/callForOffersPanel` component in the `sidebar` region, immediately above the
  tabset holding the Activity tab. Phase 4's runbook assigns it to **P4-D**, and 🔴 **P4-D owns the
  tree copy.**

**P1-D3 comes first in the calendar. The two requirements genuinely conflict**, and both
single-deploy answers open a real window in which working buttons vanish with no error:

| If the file deploys… | Window | What is lost |
|---|---|---|
| **at P1-D3 only** ⚠ **[this cell said "(tree copy)" — that option no longer exists at all: the tree now carries Phase 4's panel, so deploying the tree at P1-D3 FAILS the deploy]** | P1-D3 → P2 backfill | every deal still on `StageName = 'PSA'` loses **Move to About to Close** AND **Close Deal**. That is the pipeline's terminal step, on the deals closest to revenue. |
| **at P2-D2 only** (skip P1-D3) | P1 backfill → P2-D2 | every deal (all now `Retail`) loses the **Construction Review tab** and **Send to Construction Review**, for the whole of P1-D4 + P2-D1 + the backfill. |

**DECISION: the file deploys TWICE, and neither window opens.** ⚠ **[AMENDED 2026-08-14 — read
THREE times: P1-D3, P2-D2 and P4-D. The two windows above are still closed by the first two
deploys; the third is Phase 4's own step and opens no window here.]**

| Step | Deploys | From |
|---|---|---|
| **P1-D3** | Phase-1 edits ONLY | a generated scratch copy — `node agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js <scratch-dir> --phase 1 --phase4 strip` |
| **P2-D2** | Phase 1 **+** Phase 2 edits, **without Phase 4's panel** | ⚠ **[CORRECTED 2026-08-14 — this cell read "the tree, `force-app/main/default/flexipages/…` — **P2-D2 owns the tree copy**". That is now FALSE and is the most dangerous stale line in this section: the tree also carries Phase 4's panel, so an operator following it ships Phase 4's UI early — before its Apex, its LWC and its three Opportunity fields exist — or, if none of that is live yet, fails the deploy.]** a generated scratch copy — `node agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js <scratch-dir> --phase 2 --phase4 strip` |
| **P4-D** | all THREE phases' edits | 🔴 the tree, `force-app/main/default/flexipages/…` — **P4-D owns the tree copy.** Phase 4's runbook §3 P4-D governs it; nothing in this runbook deploys it. |

> 🔴 **`--phase4` HAS NO DEFAULT AND MUST NOT BE GIVEN ONE — the two wrong answers are not equally
> visible.** `keep` before P4-D has deployed merely fails the deploy loudly (the org has no such
> LWC); `strip` after P4-D has deployed **silently removes a live component from the Opportunity
> record page** — no error, no log, nobody told. Only a human knows which world they are in, so the
> script refuses to guess and exits 1 when the flag is absent. Use `--phase4 keep` **only** if P4-D
> has already landed in the target org; check with
> `sf project retrieve start --metadata "FlexiPage:Opportunity_Record_Page"` and grep the retrieved
> file for `callForOffersPanel`.
>
> ⚠ **The bare form `node …/make-p1d3-copy.js <scratch-dir>` is REFUSED (exit 1).** It was the
> documented form here until 2026-08-14, and against the Phase 4 tree it exited 0 while emitting a
> copy labelled "P1-D3-safe" that carried the panel.

The generator reads the tree at run time (so it cannot go stale the way a stored patch would),
asserts there are exactly two `Under Contract (PSA)` criteria and that **each is preceded by a
`{!Record.StageName}` leftValue**, and writes nothing if either assertion fails. ⚠ **[CORRECTED
2026-08-14 — the sentence that followed, "Verified 2026-08-14: its output differs from the tree by
**exactly two lines**", is FALSE for every invocation the table above now prescribes. Under
`--phase 1 --phase4 strip` the output differs from the tree by those two stage lines **plus** the
six-line `callForOffersPanel` block; under `--phase 2 --phase4 strip` it differs by the six-line
block alone.]** Both Phase-1 `Retail` criteria still survive in every copy, and the repaired script
now asserts that against the **output** rather than the input.

⚠ **Re-run the generator immediately before the deploy it is for — P1-D3 or P2-D2 — not in
advance.** ⚠ **Do not commit its output** — it is a transient deploy artifact, not a second source
of truth.
⚠ **No XML comment was added to this FlexiPage.** App Builder rewrites the file on every
in-org edit and there is no in-repo precedent for a comment surviving that; the note lives here
instead.

⚠ **Phase 4 also edits this page** (requirements §9, "the highest-risk declarative edit in the
pack" — the call-for-offers LWC above the Activity component). ⚠ **[UPDATED 2026-08-14 — the two
sentences that stood here, "The coordinator has held that work until now. Phase 4 inherits the tree
copy as it stands after this build.", describe a state that has passed.]** Phase 4's edit is
**applied in the tree** and **P4-D now owns the tree copy**; this runbook no longer deploys it.

---

## 3. Deploy sequence

Legend: **[MIG]** = an org data migration runs between this step and the next.
**[ORG-Q]** = verified by an org query, **not** by a green deploy.

### P2-D1 — add the value, keep `PSA`

Deploy:
```
force-app/main/default/standardValueSets/OpportunityStage.standardValueSet-meta.xml
force-app/main/default/objects/Opportunity/businessProcesses/Land.businessProcess-meta.xml
force-app/main/default/objects/Opportunity/businessProcesses/Retail.businessProcess-meta.xml
force-app/main/default/objects/Opportunity/businessProcesses/Commercial.businessProcess-meta.xml
force-app/main/default/reports/Acquisitions/Deal_Pipeline_by_Stage.report-meta.xml
```
> Omit the `Commercial` file if P1-D4 has already deleted it. Its presence or absence changes
> nothing else in this sequence.
>
> 🔴 **DEPLOY NOTHING ELSE AT THIS STEP.** In particular do **not** let the tooling pick up the
> whole `objects/Opportunity/`, `flexipages/` or `reports/` directory. The tree already carries
> every P2-D2 repoint, and shipping the four validation rules here would break the backfill —
> see §4.
>
> ⚠ **The report is the fifth file and it is a DELIBERATE, NAMED addition to this step, not a
> stray.** It is the C1 miss (§1.1) and it is additive — it lists BOTH values — so it is correct
> before, during and after the backfill, which is exactly why it belongs here rather than at
> P2-D2. Deploy it **by name**; the warning above is unchanged and still forbids widening to the
> `reports/` directory.

#### 🔴 W1 — a `StandardValueSet` deploy REPLACES the whole value list. Capture BEFORE, diff AFTER.

**This is the `PermissionSet.fieldPermissions` hazard one metadata type over.** ARCHITECTURE.md
§2 records that a permission set deploy overwrites the org's entire field-permission list with
exactly what the file declares, and — separately — that **this org contains metadata with no
counterpart in this repo**. `standardValueSets/OpportunityStage.standardValueSet-meta.xml`
declares the *complete* `Opportunity.StageName` value list, so any value that exists only in
the org (added in Setup, by a package, or by a Phase this repo has not caught up with) is
**silently deleted by this deploy**, taking every deal sitting on it into an invalid state.

**A "both values are ACTIVE" check cannot see this.** It passes identically whether ten other
org-only values survived or were wiped. The only check that can see it is a **before/after diff
of the full list**.

**BEFORE P2-D1 — capture the full list. Do this first; it is not recoverable afterwards:**
```bash
sf sobject describe --sobject Opportunity --target-org usman.khan.dpeg@avanzasolutions.com \
  | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const f=JSON.parse(s).result.fields.find(x=>x.name==='StageName');console.log(f.picklistValues.map(v=>(v.active?'ACTIVE  ':'inactive')+' '+v.value).join('\n'));})" \
  > stage_values_before.txt
wc -l stage_values_before.txt      # this is n
```

**AFTER P2-D1 — capture again and diff:**
```bash
sf sobject describe --sobject Opportunity --target-org usman.khan.dpeg@avanzasolutions.com \
  | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const f=JSON.parse(s).result.fields.find(x=>x.name==='StageName');console.log(f.picklistValues.map(v=>(v.active?'ACTIVE  ':'inactive')+' '+v.value).join('\n'));})" \
  > stage_values_after.txt
diff stage_values_before.txt stage_values_after.txt
wc -l stage_values_after.txt       # must be exactly n + 1
```

**PASS is a very specific shape — anything else is a STOP:**

| Check | Required |
|---|---|
| `>` lines in the diff | **exactly one**, reading `ACTIVE   Under Contract (PSA)` |
| `<` lines in the diff | **ZERO.** A single `<` line is a value the deploy destroyed. STOP. |
| `wc -l` after | exactly **n + 1** |
| `PSA` | still present, still `ACTIVE` (it must survive until P2-D3) |

(`diff` also prints its own hunk header, e.g. `7a8` — that line is not a value and is expected.
If reading the shape by eye is fiddly, `diff ... | grep -c '^<'` must print `0` and
`diff ... | grep -c '^>'` must print `1`.)

🔴 **If a `<` line appears, do not re-deploy and do not "add it back" from memory** — the diff
you just took is the only record of what the org had. Restore the missing values into
`standardValueSets/OpportunityStage.standardValueSet-meta.xml` from `stage_values_before.txt`,
re-deploy, and re-run the diff until it is one `>` line and nothing else. Then reconcile the
repo file against the org **before** P2-D3, which deploys the same file again.

⚠ **Keep `stage_values_before.txt`.** P2-D3 deploys this same file a second time and needs the
same before/after treatment; its own "PSA is inactive or absent" check has the identical blind
spot.

⚠ **The order matters: capture before the deploy, not before the day.** Anything added in Setup
between the capture and the deploy is outside the diff's reach.

#### 🔴 MEASURED — `Opportunity.StageName` is an UNRESTRICTED picklist. Describe the field first.

**Measured 2026-08-14 by a whole-repo `checkOnly` + `RunLocalTests` run. This replaces the
"pending" block that stood here, and it OVERTURNS both the earlier claim AND the endorsement of
it — both retractions are recorded below rather than quietly dropped.**

**THE HEADLINE:**

```
Opportunity.StageName   →   restrictedPicklist: FALSE
```

**An unrestricted picklist stores an off-list value SILENTLY.** Measured directly: a two-class
payload containing **no `StandardValueSet` at all** still inserted an Opportunity at
`Under Contract (PSA)` and passed.

##### Both prior positions are retracted, and they were wrong in different ways

| Position | Status |
|---|---|
| **Phase 2's conclusion** — "the values were DML-valid *because the picklist metadata was in the check-only payload*" | 🔴 **RETRACTED by the developer**, who withdrew it rather than defending it. The result was right; the **stated cause was wrong**. The payload was **irrelevant** — the value was accepted because the field does not restrict. |
| **The reviewer's endorsement** — "Phase 2's is better-supported *because it names its controlling variable*" | 🔴 **DOES NOT HOLD.** Naming a variable is not the same as naming the RIGHT one. The variable named was payload membership; the operative one was `restrictedPicklist`, which neither observation had looked at. A confidently-named wrong variable is more misleading than an unnamed one, because it ends the search. |

⚠ **The lesson generalises past this field:** a mechanism that is *plausible* and *agrees with
the result* can still be the wrong mechanism. Both observations agreed the value was accepted
and both explained it by the deploy; neither had run `describe`.

##### On the genuinely RESTRICTED field, the question is OPEN — do not pick a winner

`Lead.Deal_Type__c` **IS** `restrictedPicklist: true` (org values `Land` / `Commercial` only) —
**Phase 1's exact field**, so this is its own ground, not an analogy. With that field's metadata
in the payload, a test inserted a Lead at `Deal_Type__c = 'Retail'` and **PASSED**, and an
explicit scan of all 20 failures for `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` returned **zero**.

So the restricted case now has **one measurement each way, on one field**, and the two runs
differ in **more than one variable at once** — deploy route *and* payload contents.
🔴 **THE MECHANISM REMAINS UNDETERMINED. This is recorded as OPEN.** Do not cite either side as
settled, and do not repeat the mistake above by endorsing whichever one has the better story.

##### 🔴 THE OPERATIONAL RULE — describe the field first

`restrictedPicklist` costs **one command** and decides **which conversation you are having**. On
an unrestricted field there is no validity question to argue about; on a restricted one the
question above is still open. Run this before reasoning about any picklist-value behaviour:

```bash
sf sobject describe --sobject Opportunity --target-org usman.khan.dpeg@avanzasolutions.com \
  | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const f=JSON.parse(s).result.fields.find(x=>x.name==='StageName');console.log('restrictedPicklist:',f.restrictedPicklist);})"
```

##### 🔴 TWO CONSEQUENCES FOR THIS RUNBOOK — this is why the finding matters beyond settling an argument

**1. A GREEN APEX RUN IS NOT EVIDENCE THAT P2-D1 DEPLOYED.** Because `StageName` is
unrestricted, a **typo'd stage string anywhere is STORED, not rejected** — `'Under Contract(PSA)'`,
`'under contract (psa)'` or any other near-miss inserts cleanly and the test passes. The
**`[ORG-Q]` describe above is the only real check** that P2-D1 landed, and the before/after diff
is the only check that it landed *without collateral*. A passing suite tells you the Apex
compiles; it tells you nothing about the value set.

**2. THE P2-D3 DEACTIVATION WILL NOT BLOCK WRITES OF `'PSA'`.** Stated again at P2-D3, because
it changes what "retired" means — see that step.

##### Caveats — recorded, not smoothed over

- ⚠ **The `StageName` fixture used no record type and no business process**, so whether a
  **record-type-scoped `BusinessProcess`** would refuse the value is **UNTESTED**. Do not read
  this finding as "standard picklists are unrestricted" — it is a measurement of ONE field in
  ONE org under ONE fixture shape.
- ⚠ **The run was `checkOnly` throughout.** It establishes nothing about deployed behaviour.
  **Every `[ORG-Q]` gate in this runbook still stands, unchanged.**
- ⚠ **`restrictedPicklist` is ORG STATE, not repo state.** If an admin ever restricts
  `StageName`, the stage half of this answer **inverts** — and nothing in this repo would change
  or fail. Re-run the describe; do not trust this paragraph across a gap in time.

##### Correction — the org is NOT partially deployed

A related observation was raised and **checked directly: it is FALSE.** The org's stored
`LeadConvertServiceTest` appeared to reference `Lead.Listing_Status__c` while the field is absent
from the describe, which looked like a partial Phase 1 deployment. It is not: the four Phase 1
fields return `totalSize 0`, `ExtractionScoreUtil` does not exist in the org, and the org's
`LeadConvertServiceTest` was last modified **2026-08-10 by Usman Khan**, four days before this
session. 🔴 **Nothing from this work has reached the org.** Recorded here so the false version
does not get re-derived from the same surface evidence.

**Business processes — the describe cannot see these; retrieve and read them back:**
```bash
sf project retrieve start \
  --metadata "BusinessProcess:Opportunity.Land" \
  --metadata "BusinessProcess:Opportunity.Retail" \
  --target-org usman.khan.dpeg@avanzasolutions.com \
  --target-metadata-dir <scratch> --unzip --wait 20
```
Each retrieved file must list **both** `PSA` and `Under Contract (PSA)`.
⚠ An **empty** retrieve proves nothing — confirm each file is non-empty before trusting it.

---

### [MIG] — the backfill

**One update:** every `Opportunity.StageName = 'PSA'` → `'Under Contract (PSA)'`.
**This is where the rename actually happens.** Everything before it is additive; everything
after it is a repoint.

Extract first, so the change is reversible:
```bash
sf data query \
  --query "SELECT Id, StageName FROM Opportunity WHERE StageName = 'PSA'" \
  --result-format csv --target-org usman.khan.dpeg@avanzasolutions.com > opp_stage_before.csv
```
Record the row count. Then produce the update CSV (`Id,StageName` with the new value on every
row) and run it:
```bash
sf data update bulk --sobject Opportunity --file opp_stage_update.csv \
  --target-org usman.khan.dpeg@avanzasolutions.com --wait 30
```

**Run it as an administrator.** Both Opportunity approval processes set
`recordEditability = AdminOnly`, so a deal that is mid-approval is editable by an admin and
refused for anyone else. Neither approval's entry criterion is the PSA stage (measured: they key
on `LOI` and `Underwriting`), so a locked PSA-stage deal is not expected — running as an admin
makes the question moot rather than relying on that expectation.

**[ORG-Q] Verify — the first must be 0 and the second must equal the extract's row count:**
```sql
SELECT COUNT() FROM Opportunity WHERE StageName = 'PSA'
SELECT COUNT() FROM Opportunity WHERE StageName = 'Under Contract (PSA)'
```
The second query is not optional. A zero on the first alone is also what a backfill that
*deleted* or *mis-staged* rows would produce.

---

### P2-D2 — repoint every live reference

Deploy (declarative half — this runbook's scope):
```
force-app/main/default/objects/Opportunity/validationRules/Approved_LOI_Before_PSA.validationRule-meta.xml
force-app/main/default/objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml
force-app/main/default/objects/Opportunity/validationRules/NDA_Signed_Before_Deal_Progression.validationRule-meta.xml
force-app/main/default/objects/Opportunity/validationRules/No_Backward_Stage_Movement.validationRule-meta.xml
force-app/main/default/objects/Opportunity/fields/Deal_Bucket__c.field-meta.xml
force-app/main/default/objects/Opportunity/listViews/Deal_Tracker_PSA.listView-meta.xml
force-app/main/default/pathAssistants/Acquisitions_Deal_Path.pathAssistant-meta.xml
force-app/main/default/quickActions/Opportunity.Advance_to_PSA.quickAction-meta.xml
<scratch-dir>/flexipages/Opportunity_Record_Page.flexipage-meta.xml     <-- GENERATED, NOT THE TREE
```
> 🔴 **THE LAST LINE IS NOT A TREE PATH, AND THAT CHANGED ON 2026-08-14.** It read
> `force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml` until then.
> **Deploying the tree copy at P2-D2 now ships Phase 4's `c/callForOffersPanel` early** — before its
> Apex, its LWC bundle and its three Opportunity fields exist — or, if none of Phase 4 is live yet,
> fails the deploy on an unresolvable component. Generate the copy immediately before the deploy:
>
> ```bash
> node agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js <scratch-dir> --phase 2 --phase4 strip
> ```
>
> `--phase 2` keeps the two stage criteria at `Under Contract (PSA)` (Phase 1's copy reverts them to
> `PSA`). **`--phase4` has no default and must not be given one:** `strip` after P4-D has deployed
> silently removes a live component from the record page, while `keep` before P4-D merely fails the
> deploy loudly — only a human knows which world they are in. Use `--phase4 keep` **only** if P4-D
> has already landed. Full reasoning and the ownership table: §2. **P4-D owns the tree copy.**

Plus the **developer agent's** Apex/LWC repoints, in the same deploy. They are not this
runbook's contents, but they must not lag: see the transient-window note in §4.

> 🔴 **`Deal_Bucket__c` and `Deal_Tracker_PSA` must travel together.** The list view filters on
> the formula's output string; if only one ships, the list silently returns nothing.
>
> ⚠ **The three `ISPICKVAL` rules and the `Deal_Bucket__c` formula cannot deploy before P2-D1.**
> `ISPICKVAL(StageName, 'Under Contract (PSA)')` against a value the org does not have is a
> deploy-time error. That is a **useful** property — it makes the wrong order fail loudly — but
> it also means the tree is not deployable for these five files until P2-D1 lands in the org.
> Phase 1's own file lists are explicit and per-file, so nothing in Phase 1 picks them up.
>
> ⚠ **Read the FlexiPage back after deploying it.** A FlexiPage deploy can roll back with a
> design-time error and still report success. Retrieve and diff — a green deploy is not evidence.
>
> ⚠ **`Deal_Pipeline_by_Stage` is NOT in this step — it went in at P2-D1, deliberately** (§1.1).
> If it did not land there, deploy it **now, by name**, before anything else in this step: until
> it does, every just-migrated deal is outside the pipeline report's filter and the report
> under-reports **silently**. It is safe at any point because it lists both values; it is only
> *unsafe to be late*.

**Verify — the C7 gate, as a hard stop on the deploy.** ⚠ **Use this pattern, not a bare
`grep -i Disposition`** — see the amendment in §0.1 for why the broad form is now
false-positive:
```bash
C7='objects/Disposition__c/|objectTranslations/Disposition__c-en_US/|pathAssistants/Disposition_Path|flexipages/Disposition_Record_Page|lwc/dispositionSidebar/|classes/DispositionStageEntryService'
git status --porcelain -- force-app | grep -E "$C7" && echo "STOP — a C7 file is modified" || echo "clean"
```
Must print `clean`. Its six alternatives cover **every C7 entry of §0.1 and the third
disposition Path noted there, and nothing else** — three of the alternatives are *directory*
prefixes (`objects/Disposition__c/`, `objectTranslations/Disposition__c-en_US/`,
`lwc/dispositionSidebar/`), so the pattern matches **61 paths in the current tree**, not twelve.
It deliberately does **not** match `Contract_Review__c/recordTypes/Disposition_PSA` or
`LOI__c/recordTypes/Disposition_LOI`, which are disposition-named record types on
**acquisition-side objects** that Phase 3 edits legitimately, nor the two Phase-3 Paths
(`LOI_Path_Acquisition`, `Contract_Review_Path_Acquisition`).

> 🔴 **CORRECTED 2026-08-14 (re-review S-1) — the `pathAssistants/` alternative lost its trailing
> underscore.** It was written `pathAssistants/Disposition_Path_`, which matches
> `Disposition_Path_On_Market` and `Disposition_Path_Off_Market` but **misses
> `pathAssistants/Disposition_Path.pathAssistant-meta.xml`** — a third, real disposition Path
> that the original over-broad `grep -iE "Disposition"` form *did* catch. Narrowing the pattern
> silently dropped it.
>
> ⚠ **It matters even though that file carries no `Disposition_Stage__c` `PSA` value.** It holds
> `PSA_Executed__c` (L60, L62), so it is exactly what a careless **bare-token `PSA` sweep** —
> the very sweep §1.2 makes a standing rule — would corrupt, and without this alternative it
> would be corrupted **unwatched**. The file is `<active>false</active>`, which makes it *more*
> dangerous, not less: nothing in the UI would show the damage.
>
> **Falsified in both directions over all 7,277 files under `force-app/main/default`:** the
> corrected pattern gains **exactly one** path (`pathAssistants/Disposition_Path.pathAssistant-meta.xml`),
> loses **zero**, and still matches **zero** of the Phase-3 and acquisition-side paths listed
> above.

🔴 **The gate that actually protects C7 is the DEPLOY LIST, not tree cleanliness.** Every P2 step
deploys an explicit, named per-file list, so a dirty tree elsewhere cannot reach the org. Before
approving, confirm the deploy's own component list contains **zero** `Disposition__c`,
`Disposition_Path_*`, `Disposition_Record_Page`, `dispositionSidebar` or
`DispositionStageEntryService` components. **That check is sufficient on its own**; the
`git status` check above is an early warning, not the control.

⚠ **If the pattern ever DOES fire, do not stop at the filename — read the diff.** The question is
never "is a disposition file dirty", it is **"did anything change a `Disposition_Stage__c`
value?"**. A comment or `<description>` edit is not the C7 hazard:
```bash
git diff -- <file> | grep -E '^[+-] *<(fullName|picklistValues|values|value|default)>'
```
Zero hits means no value moved. Both Phase 3 files measured **0** on 2026-08-14.

**[ORG-Q] Verify the rules actually moved** (a green deploy proves the XML parsed, not that the
literal changed):
```bash
sf project retrieve start \
  --metadata "ValidationRule:Opportunity.No_Backward_Stage_Movement" \
  --metadata "ValidationRule:Opportunity.NDA_Signed_Before_Deal_Progression" \
  --metadata "ValidationRule:Opportunity.Approved_LOI_Before_PSA" \
  --metadata "ValidationRule:Opportunity.Completed_LOI_Before_PSA" \
  --target-org usman.khan.dpeg@avanzasolutions.com \
  --target-metadata-dir <scratch> --unzip --wait 20
```
In the retrieved `No_Backward_Stage_Movement`, count `'Under Contract (PSA)',6` — must be **4**.
In the other three, the only `PSA` inside `<errorConditionFormula>` must be the new value.

**Functional smoke, as a real deal driver (not an admin):**
take a deal with a signed NDA and a Completed, approved LOI to `LOI`, click **Advance to Under
Contract (PSA)**, and confirm (a) the button's label reads the new text, (b) the Path highlights
the new step, (c) **Move to About to Close** and **Close Deal** appear on the record, and
(d) the deal shows in `Deal Tracker: Under Contract (PSA)`.

---

### P2-D3 — retire `PSA`

🔴 **PRECONDITION, RE-RUN IMMEDIATELY BEFORE EXECUTING — not trusted from the backfill:**
```sql
SELECT COUNT() FROM Opportunity WHERE StageName = 'PSA'
```
Must be **0 at this moment**. It was 0 after the backfill; §4 explains why it can have drifted
back above zero since. **If it is not 0, re-run the backfill on the survivors first.**

Apply the staged package:
```bash
node agent-output/p2-d3-retire-psa/apply-d3.js --check     # validates, writes nothing
node agent-output/p2-d3-retire-psa/apply-d3.js             # writes all-or-nothing
```
Then deploy:
```
force-app/main/default/standardValueSets/OpportunityStage.standardValueSet-meta.xml
force-app/main/default/objects/Opportunity/businessProcesses/Land.businessProcess-meta.xml
force-app/main/default/objects/Opportunity/businessProcesses/Retail.businessProcess-meta.xml
force-app/main/default/reports/Acquisitions/Deal_Pipeline_by_Stage.report-meta.xml
```
(and `Commercial` only if it still exists.)

What the package does: sets `<isActive>false</isActive>` on the `PSA` standard value, removes
the `PSA` `<values>` block from every business process that still lists it, and **drops `PSA`
from the `Deal_Pipeline_by_Stage` report's `STAGE_NAME` filter** (§1.1 — the C1 miss; the report
carried both values from P2-D2). **Nothing is deleted** — a stage value with history must stay
resolvable to every historical report, dashboard and audit row, which is the same reasoning
requirements §1 O3 records for the LOI and PSA picklist values.

#### 🔴 WHAT "RETIRED" ACTUALLY MEANS HERE — deactivation does NOT block writes of `'PSA'`

**MEASURED 2026-08-14: `Opportunity.StageName` is `restrictedPicklist: FALSE`** (full finding and
its caveats at P2-D1). On an **unrestricted** picklist, deactivating a value removes it **from
the pickers, not from DML**. So after this step:

| | |
|---|---|
| A user cannot **choose** `PSA` in the UI | ✅ true — this is what the step buys |
| Anything still **writing the string** `'PSA'` — Apex, Flow, API, Data Loader, an integration | 🔴 **keeps succeeding, silently, and the record lands back on the retired value** |

**This is the opposite of what a reader naturally assumes**, which is exactly why it is stated
here rather than left to be discovered. The step is a **UI retirement, not an enforcement
boundary**, and it creates no safety net.

**Three things follow, and none of them is optional:**

1. **The P2-D2 Apex/LWC repoints are the real control, not this step.** The precondition below
   already requires a fresh `COUNT() = 0`; the reason it is a *precondition* rather than a
   *nice-to-have* is that nothing here will stop the count climbing again afterwards.
2. **Re-run the zero-count query some days AFTER P2-D3, not only before it.** A writer this
   migration missed — a Flow, an integration, a saved Data Loader mapping — announces itself
   only as rows quietly reappearing on `PSA`. There is no error to wait for.
3. **Do not add a validation rule to "enforce" the retirement** without deciding that
   deliberately. It would be a real behaviour change with its own blast radius, not a tidy-up,
   and it is out of this phase's scope.

⚠ **The report edit is the only one of the three that is safe in either order relative to the
value deactivation.** It is a stored string, not a resolved reference, so a filter naming a
deactivated value neither fails to deploy nor errors at run time — it simply matches nothing,
which is the intended end state.

⚠ **The `<isActive>` element on a `StandardValue` is UNVERIFIED in this org.** The
`<default>` → `<isActive>` → `<label>` ordering is taken from
`objects/Contract_Review__c/fields/Stage__c.field-meta.xml`, which carries three deactivated
values in exactly that shape — but that is a `CustomValue` precedent, not a `StandardValue` one,
and **no `standardValueSets/*` file in this repo has ever carried `<isActive>`** (measured:
zero hits). `StandardValue` extends `CustomValue` in the Metadata API, which is why this is
expected to work; expected is not measured. The business-process half is independent and
unaffected.

> 🔴 **IF THE DEPLOY REJECTS THE ELEMENT: `--skip-svs` ALONE IS NOT THE FIX — THE REVERT IS
> STEP 1.** By the time the rejection is knowable, `apply-d3.js` has **already written**
> `<isActive>false</isActive>` into the tree. `--skip-svs` only tells a *future* run to leave
> that file alone; it does not remove what is already there. Re-running with the flag and
> nothing else leaves the repo carrying a `standardValueSets/OpportunityStage` the org refuses,
> so **every later deploy that includes that file fails**, for a reason that has nothing to do
> with the change being made at the time.
>
> **Follow `agent-output/p2-d3-retire-psa/README.md`, section
> "🔴 If the deploy rejects it — REVERT THE FILE FIRST. `--skip-svs` alone does NOT undo it."**
> That README section is the **one authoritative copy** of the recovery sequence (revert →
> confirm the element is gone → re-run with `--skip-svs` → deactivate by hand in Setup →
> Object Manager → Opportunity → Fields → Stage). It is deliberately **not** repeated here, and
> the same pointer sits in `apply-d3.js`'s own comment, so the three cannot drift apart again.

**[ORG-Q] Verify:**
```bash
sf sobject describe --sobject Opportunity --target-org usman.khan.dpeg@avanzasolutions.com
```
`Under Contract (PSA)` must be present and active. `PSA` must be **either absent from the value
list or reported `active: false`** — record which of the two you observe, because this org has
no prior inactive standard value to compare against.

Retrieve both business processes again; neither may list `PSA`.

⚠ **Re-run the W1 before/after describe diff on this deploy too.** It ships the same
`standardValueSets/OpportunityStage` file a second time, so it carries the same replace-not-merge
hazard. Expected shape here: **zero `>` lines**, and either **zero `<` lines** with `PSA` flipping
to `inactive`, **or exactly one `<` line** — `ACTIVE   PSA` — if the org drops a deactivated
standard value from the describe entirely. **Any other `<` line is a value this deploy destroyed.
STOP.**

⚠ **And read the report back — it is the one P2-D3 file with no [ORG-Q] of its own:**
```bash
sf project retrieve start --metadata "Report:Acquisitions/Deal_Pipeline_by_Stage" \
  --target-org usman.khan.dpeg@avanzasolutions.com --target-metadata-dir <scratch> --unzip --wait 20
```
Its `STAGE_NAME` `<value>` must read `...,Underwriting,LOI,Under Contract (PSA)` — **`PSA,` gone,
the new value still there**. Opening the report in the UI is the better check of the two, because
it also shows the grouping populated: the failure this guards is a report that renders fine and
is quietly missing a column.

---

## 4. 🔴 THE MIGRATION DECISION — written down, with the risk of the option not taken

Requirements §7 flags that `No_Backward_Stage_Movement` and `NDA_Signed_Before_Deal_Progression`
are `ISCHANGED(StageName)`-scoped and *"WILL fire on this update — the migration must run in a
context that satisfies them or with the rules temporarily deactivated and re-activated. Decide
which, in writing, before running it."*

### DECISION: run the backfill with **ALL validation rules ACTIVE**, strictly **between P2-D1 and P2-D2**.

**No rule is deactivated. No rule needs to be.** This is derived from the four formulas as they
stand in the org at that moment, not assumed:

| Rule | What it tests | On the backfill (`PSA` → `Under Contract (PSA)`) |
|---|---|---|
| `No_Backward_Stage_Movement` | four `CASE(TEXT(StageName), …)` rank maps that, in the org copy at that moment, still say `'PSA',6` and do **not** know the new value | `PRIORVALUE` ranks 6; the NEW value is unmapped and ranks **0**, so clause 3 (`new rank > 0`) is FALSE and the whole `AND` is false. **Does not fire.** This is the file's own documented fail-open default for unmapped stages, not a loophole. |
| `NDA_Signed_Before_Deal_Progression` | `OR` over `Underwriting, LOI, PSA, About to Close, Closed Won` | the NEW value matches no entry, so the `OR` is false. **Does not fire.** |
| `Approved_LOI_Before_PSA` | `ISPICKVAL(StageName, 'PSA')` | the NEW value is not `PSA`. **Does not fire.** |
| `Completed_LOI_Before_PSA` | `ISPICKVAL(StageName, 'PSA')` | same. **Does not fire.** |

**The ordering is the mechanism, not an incidental detail.** Every row above holds *because* the
org copy of these four rules still names the OLD value when the backfill runs. Repointing them
first (deploying P2-D2 early, or letting a directory-scoped deploy pick up the tree, which
already carries the repoints) inverts three of the four.

**Other automation was checked, not assumed.** Measured 2026-08-14:
- Four Opportunity record-triggered flows exist. **None keys on `StageName` in its entry
  criteria** — they key on `LOI_Approved__c`, `Underwriting_Status__c` and
  `Initiate_Underwriting__c`. `Opportunity_Initiate_Underwriting` mentions `StageName` only
  inside its decision/assignment, behind a `Initiate_Underwriting__c` transition the backfill
  does not cause. **No flow references the `PSA` stage value at all.**
- `OpportunityReviewService`'s stage-entry blocks still key on the OLD literals at backfill time,
  so entering the new value matches nothing and creates no children — which is correct, since
  these deals already have their Contract Review, and the block is idempotent anyway.

### The risk of the option NOT taken (temporarily deactivating the two rules)

1. **Deactivating a validation rule is org state that no deploy performs and no test detects.**
   If the re-activation is forgotten, the org silently loses both its backward-stage-movement
   block and its NDA gate, and nothing anywhere reports it. That is the same failure class as
   every gate in §5.
2. **`No_Backward_Stage_Movement` explicitly says this is not the remedy.** Its own comment
   records a user decision at the design gate that there is **no bypass permission and no admin
   escape hatch**, and states verbatim that *"deactivating the rule is NOT the remedy and should
   not be used."* Deactivating it org-wide for a migration is precisely the bypass that was
   refused, obtained by another route.
3. **The window is wider than the migration.** Everything any user saves while the rules are off
   is ungated, not just the backfilled rows.
4. **It would be based on an assumption we can falsify by reading four formulas.** The
   deactivation is only necessary if the rules fire; they do not.

### The risk of the option TAKEN, stated rather than hidden

1. **It is order-dependent.** If P2-D2 lands before the backfill, `Approved_LOI_Before_PSA`,
   `Completed_LOI_Before_PSA` and `NDA_Signed_Before_Deal_Progression` all start matching the new
   value and will reject any migrated row lacking an approved LOI, a Completed LOI or a signed
   NDA. **Mitigating property: that failure is LOUD** — per-row DML errors on the bulk job, not
   silence. The cost is a partially-migrated population, recoverable by re-running the backfill
   on the survivors. The safeguard is the per-file deploy list in P2-D1 above.
2. 🔴 **A TRANSIENT WINDOW RE-CREATES `PSA` ROWS AFTER THE ZERO-COUNT QUERY PASSES.** Between the
   backfill and the P2-D2 **Apex** deploy, `StageAdvanceService.NEXT_STAGE` still maps
   `'LOI' ⇒ 'PSA'`, so the Advance quick action keeps minting **new** rows on the old value. The
   backfill's `COUNT() = 0` is true at that instant and drifts afterwards. Those rows are also
   rank-0 in the repointed `No_Backward_Stage_Movement`, i.e. fail-open for a backward move,
   until they are migrated.
   **Remedy, and it is operational rather than formulaic:** run the backfill and the full P2-D2
   deploy (declarative **and** Apex) in **one maintenance window**, and gate P2-D3 on a **fresh**
   zero-count query rather than the backfill's. Both are written into P2-D3's precondition above
   and into `No_Backward_Stage_Movement`'s own XML comment, so the next reader of the rule finds
   it without this runbook.
3. **A deal mid-approval at the PSA stage.** `recordEditability = AdminOnly` on both approvals,
   so an admin-run backfill is unaffected. A non-admin run would be refused per row — another
   loud failure. Run as an admin.

---

## 5. Post-deploy gates — NOT deployable metadata, each fails SILENTLY

| # | Gate | If missed |
|---|---|---|
| **G8-a** | **Re-point every org-side report and dashboard filtering or grouping `Opportunity.StageName = 'PSA'`.** ⚠ **AMENDED — "not fully represented in this repo" is FALSE for one file.** `reports/Acquisitions/Deal_Pipeline_by_Stage` IS in the repo, was missed by the inventory, and is now handled in P2-D2/P2-D3 (§1.1). This gate is therefore **org-side-only leftovers**, and it is entered having already run the §1.2 bare-token sweep — which returns nothing further in-repo. | Reports and dashboards break **silently** — they reference by name and do not block the change. Deal-tracker and pipeline dashboards are the likely holders. |
| **G8-b** | **Re-point every org-side report and dashboard filtering or grouping `Deal_Bucket__c = 'PSA'`.** A **separate** sweep from G8-a: the formula's OUTPUT string moved too, and a report can filter the bucket without ever naming the stage. | Same silent break, in a place a `StageName` sweep will not look. |
| **G9** | **Re-verify the forecast.** `forecastCategory Forecast` / `probability 85` were copied verbatim, so no forecast should move. Confirm one deal's Expected Revenue and forecast category before and after the backfill. | A wrong copy shifts every in-flight deal's forecast, and nothing errors. |
| **G10** | **Record-type default and stage availability per record type.** `PermissionSet.recordTypeVisibilities` has no `default` element and `profiles/**` is `.forceignore`d, so only a Profile can name a default. Confirm in Setup that both live record types offer the new stage and no longer offer the old one after P2-D3. | Users see a stage picker that still offers a retired value, or lose the new one. |
| **G11** | **Render probe on `Opportunity_Record_Page`, as a real deal-driver persona, in both directions.** On a deal at `Under Contract (PSA)`: **Move to About to Close** and **Close Deal** must appear. On a deal at `LOI`: they must NOT. | A FlexiPage visibility rule can deploy, survive a retrieve and still be ignored by the renderer — measured in this repo on `NDA__c.Is_Decline_Allowed__c`. No Apex test, Jest test or file check can see it. |
| **G12** | **Retrieve `Opportunity_Record_Page` back and diff it after BOTH deploys.** ⚠ **[CORRECTED 2026-08-14 — this gate named them "P1-D3's scratch copy and P2-D2's tree copy". P2-D2 no longer deploys the tree copy; it deploys a `--phase 2 --phase4 strip` scratch copy, and **P4-D** owns the tree copy. See §2.]** | A FlexiPage deploy can roll back on a design-time error and still report success. |
| **G13** | **Confirm the scratch copy was generated fresh**, from the tree, at deploy time — not reused from an earlier run. ⚠ **[WIDENED 2026-08-14 — this gate said "the P1-D3 scratch copy". It now applies to P2-D2's copy as well, and to a second staleness axis: a copy generated with `--phase4 strip` before P4-D deployed becomes actively destructive if it is re-used after P4-D deploys — it would un-ship a live component.]** | A stale copy silently reverts whatever the tree gained in between. |

---

## 6. Handoffs — what this build did NOT do

| Item | Owner |
|---|---|
| Every Apex and LWC repoint in requirements §6.2 (`StageAdvanceService`, `OpportunityReviewService`, `OpportunityReviewTriggerHandler`, `ContractExecutionService`, `DealFolderService`, `PropertyAssetService`, `OpportunityFunnelController`, `TestDataFactory`, the three LWC bundles, the 14 test classes, the 2 Jest suites) | 🟢 `salesforce-developer` — **in flight, not touched by this build** |
| ✅ **`ContractExecutionServiceTest.cls` — CLOSED, nothing to hand over.** Consequence of the `Deal_Bucket__c` output move decided here. ⚠ **This row previously read "`:139` … `System.assertEquals('PSA', …)` … Not yet modified in the tree" — stale on both counts** (re-verified 2026-08-14, re-review S-3a). The assertion is repointed and now sits at **line 157**: `System.assertEquals('Under Contract (PSA)', o.Deal_Bucket__c, 'Tracker bucket follows')`. Do not re-open it; do not revert it. See §1's `Deal_Bucket__c` subsection. | 🟢 `salesforce-developer` — **done** |
| Deploying anything | 🔴 `salesforce-devops` |
| The `[MIG]` backfill and every `[ORG-Q]` | 🔴 `salesforce-devops` |
| Phase 3's edit to `Completed_LOI_Before_PSA` (the LOI child's `'Completed'` → `'Signed'`) | 🟤 `salesforce-solution-architect`, Phase 3. **It MUST land after this phase's edit to the same file**, or one overwrites the other (requirements §7 / §9 C2). The constraint is now recorded inside the rule's own XML comment as well. |
| Phase 4's `Opportunity_Record_Page` edit | 🟤 `salesforce-solution-architect`, Phase 4 — ✅ **DONE 2026-08-14.** ⚠ **[This row read "inherits the tree copy as it stands" — now stale.]** The edit is applied in the tree and **P4-D owns the tree copy**; P2-D2 deploys a generated copy instead (§2). |

---

## 7. Rule-gate record (`.claude/rules/salesforce-global-rule.md`)

```
intent=type | best_matched_skill=sf-metadata | skill_selection=complete
```

| Metadata type | Skill loaded | `salesforce-api-context` MCP |
|---|---|---|
| `StandardValueSet` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |
| `BusinessProcess` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |
| `ValidationRule` | `sf-validation-rule` | `mcp=unavailable`, `mcp_tools=none` |
| `CustomField` (formula) | `sf-custom-field` | `mcp=unavailable`, `mcp_tools=none` |
| `ListView` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |
| `PathAssistant` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |
| `QuickAction` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |
| `FlexiPage` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |

The `salesforce-api-context` MCP server exposes no tools in this environment — none of
`get_metadata_type_sections`, `get_metadata_type_context`, `get_metadata_type_fields`,
`get_metadata_type_fields_properties` or `search_metadata_types` is available to call.
`ARCHITECTURE.md` §3.4 records the same unavailability. Every file was therefore generated from
the loaded skill plus **in-repo deployed precedent**, which is the stronger source for the two
questions that actually mattered here — `Dead%2FPass` encoding (`businessProcesses/*`) and
`<isActive>` element ordering (`Contract_Review__c/fields/Stage__c`).

Public Salesforce documentation was consulted for `StandardValueSet` / `StandardValue`
(`developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_standardvalueset.htm`)
and did **not** enumerate an `isActive` field for `StandardValue`; the `CustomValue` reference
page could not be retrieved. That is why the `<isActive>` step in §3 P2-D3 is labelled
UNVERIFIED with a Setup fallback rather than presented as settled.
