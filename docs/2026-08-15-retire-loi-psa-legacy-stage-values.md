# Retire Legacy LOI and PSA Stage Sequences (Acquisition Observations, Phase 3 — P3-D1 + P3-D3)

**Date:** 2026-08-15
**Author:** Documentation Agent
**Status:** Deployed to `usman-dpeg` (declarative only — P3-D1 additive step, then P3-D3 subtractive step). No Apex or LWC touched in this change.

---

## 📋 Overview

### Original Request

> From `agent-output/runbook-acquisition-observations-phase3.md` (Phase 3 of the Acquisition App
> Observations Fix Pack, itself sourced from `docs/superpowers/specs/2026-08-14-acquisition-app-
> observations-design.md`, approved at Gate 1):
>
> **Observation 5** — `LOI__c.Stage__c`'s acquisition (buy-side) sequence should move from the legacy
> `Draft → Prepare/Review → Sent → Counter → Completed` to `Draft → Under Review → Submitted →
> Negotiation → Signed`, with the four old values retired.
>
> **Observation 7** — `Contract_Review__c.Negotiation_Status__c`'s acquisition (buy-side PSA) sequence
> should move from `Initial Draft → Revised → Ready for Execution → Executed` to `Draft → Negotiation
> → Signed → Executed`, with the three old values removed **from the acquisition record type only**
> (they must stay active on the field — the sell-side `Disposition_PSA` record type still runs on all
> three).

### Business Objective

The buy-side LOI and PSA stage labels had drifted from the vocabulary the Acquisitions team actually
uses day to day (e.g. "Counter" vs. "Negotiation", "Completed" vs. "Signed"), and — for the LOI —
never distinguished an internal-approval hop ("Prepare/Review") from a value that also had to serve
the newer disposition (sell-side) record type cleanly. This change renames the buy-side sequences to
match current usage, without deleting historical data and without disturbing the sell-side sequences
that share the same two custom fields.

### Summary

Two acquisition-only picklist sequences were replaced in a two-step **add → migrate → repoint →
retire** pattern (additive step P3-D1, then subtractive step P3-D3), executed by
`agent-output/p3-d3-retire-loi-psa/apply-d3.js` for the subtractive half. `LOI__c.Stage__c` gained
three new values and deactivated (never deleted) its four legacy ones. `Contract_Review__c
.Negotiation_Status__c` gained three new values and **deactivated nothing** — its three legacy values
were removed only from the `Acquisition_PSA` record type's inclusion list, because `Disposition_PSA`
still needs them. Along the way, two related Path Assistants, one validation rule, a formula field,
two quick-action labels, and (as findings beyond the original brief) a notification flow and a
before-save sync flow were also updated so nothing silently broke. A parallel Apex change
(P3-D2, `RecordStageAdvanceService`, not documented here) split the two objects' record-type-aware
stage maps to match.

---

## 🏗️ Components Created / Modified

All work in this change is **declarative metadata only** — no Apex classes, triggers, or LWCs were
created or modified as part of this documented change (the sibling Apex change, P3-D2, is a separate,
already-landed unit of work — see *Related Work* below).

### Admin Components (Declarative)

#### Custom Fields — value-set changes

| Object | Field API Name | Change |
|--------|----------------|--------|
| `LOI__c` | `Stage__c` | +3 values (`Submitted`, `Negotiation`, `Signed`), appended. 4 legacy values (`Prepare/Review`, `Sent`, `Counter`, `Completed`) **deactivated**, never deleted. `<description>` and `<inlineHelpText>` rewritten. |
| `Contract_Review__c` | `Negotiation_Status__c` | +3 values (`Draft`, `Negotiation`, `Signed`), **inserted before `Executed`** (not appended — see *Key Design Decisions*). **Nothing deactivated.** `<description>` rewritten. |
| `LOI__c` | `Is_Advance_Allowed__c` (formula checkbox) | Formula rewritten: 3 transitional clauses dropped (`<> "Completed"`, `<> "Sent"`, the `Prepare/Review` disjunction), replaced by `<> "Signed"`, `<> "Submitted"`, and a `RecordType.DeveloperName` guard on the `Under Review` clause. See *Key Design Decisions* (C1). |

#### Record Types — inclusion-list changes

| Object | Record Type | Change |
|--------|-------------|--------|
| `LOI__c` | `Acquisition_LOI` | `Stage__c` inclusion list: gained `Under Review`, `Submitted`, `Negotiation`, `Signed` (P3-D1); the 4 legacy values were dropped at P3-D3. Final list (5): `Draft, Under Review, Submitted, Negotiation, Signed`. |
| `LOI__c` | `Disposition_LOI` | **Values unchanged.** Only its XML comment/`<description>` was corrected (its "fully disjoint" claim is now false — see below). |
| `Contract_Review__c` | `Acquisition_PSA` | `Negotiation_Status__c` inclusion list: gained `Draft`, `Negotiation`, `Signed` (P3-D1, 7-value transitional state); the 3 legacy values (`Initial Draft`, `Revised`, `Ready for Execution`) were dropped at P3-D3, and the record-type default was **flipped** from `Initial Draft` to `Draft`. Final list (4): `Draft, Negotiation, Signed, Executed`. |
| `Contract_Review__c` | `Disposition_PSA` | **Values unchanged.** Only its XML comment/`<description>` was corrected (its "both record types share one vocabulary" claim is now false). |

#### Validation Rules

| Object | Rule Name | Change |
|--------|-----------|--------|
| `Opportunity` | `Completed_LOI_Before_PSA` | LOI-side leg rewritten. P3-D1 shipped `AND(<> 'Completed', <> 'Signed')` (correct on both sides of the row migration); P3-D3 dropped the `'Completed'` leg, leaving `TEXT(Primary_LOI__r.Stage__c) <> 'Signed'`. |

#### Path Assistants

| Path | Record Type | Change |
|------|-------------|--------|
| `LOI_Path_Acquisition` | `Acquisition_LOI` | 9-step transitional state (P3-D1) collapsed at P3-D3 to the final 5 steps: `Draft, Under Review, Submitted, Negotiation, Signed`. |
| `Contract_Review_Path_Acquisition` | `Acquisition_PSA` | 7-step transitional state (P3-D1) collapsed at P3-D3 to the final 4 steps: `Draft, Negotiation, Signed, Executed`. |

#### Flows (found beyond the original brief, fixed in the same P3-D1 deploy)

| Flow | Change | Why |
|------|--------|-----|
| `Contract_Review_Stage_Sync` (before-save, C4) | New `Is_Draft` decision rule → `Set_Stage_Drafting`, alongside the existing `Is_Initial_Draft` rule. | This flow recomputes the coarse `Stage__c` projection from `Negotiation_Status__c` on every save and had no rule for the new `Draft` value — every new-value save would have fallen to its DEFAULT branch and shown `Stage__c = 'Review'` on a brand-new acquisition PSA instead of `'PSA Drafting'`. |
| `PSA_Ready_Notify` (after-save, C4b — **not in any original brief**) | Entry criteria widened from `Negotiation_Status__c = 'Ready for Execution'` to `... OR Negotiation_Status__c = 'Signed'`. | Found by sweeping `flows/` for `Negotiation_Status__c` rather than by following the requirements doc. This flow had no record-type criterion and served both PSA record types on one value. Removing `Ready for Execution` from `Acquisition_PSA` (observation 7) would have made every acquisition PSA pass `Negotiation → Signed → Executed` **without ever matching this flow again** — the "PSA ready for execution" notification to `Acquisitions_Team` would have stopped arriving for every acquisition deal, permanently, with nothing erroring and no test failing. |

#### Quick Actions — label-only (beyond the brief, cosmetic)

| Quick Action | Change |
|--------------|--------|
| `LOI__c.Mark_Completed` | `<label>` `Completed` → `Signed` (API name unchanged). |
| `LOI__c.Mark_Countered` | `<label>` `Counter` → `Negotiation` (API name unchanged). |

The incumbent convention on `LOI__c` is label == target stage value; both labels were moved to match
the renamed stages so a button doesn't read "Completed" while writing `Signed`. Zero functional risk.

#### Not touched, and deliberately so

- `objectTranslations/**` — left stale on purpose; already incomplete before this change (see *Known
  Limitations*).
- `LOI_Record_Page` and `Contract_Review_Record_Page` flexipages — visibility-rule criteria were
  **repointed** to the new values (part of P3-D2's declarative sibling work per the runbook's file
  list), but no *new* record-type criterion was added to any rule in this change — see the open
  residual under *Known Limitations*.
- Both disposition record types' `<picklistValues>` — confirmed unchanged by a hard diff gate before
  every deploy (runbook §2): `git diff` on both files, filtered to `<values>/<fullName>/<default>/
  <picklist>` elements, must print nothing.

### Development Components (Code)

None in this change. A related, separately-landed Apex change (**P3-D2**, developer-owned, not part
of this doc's scope) split `RecordStageAdvanceService`'s single shared `CONTRACT_REVIEW_NEXT_STAGE`
map into two record-type-scoped maps (`CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE` /
`CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE`), each with its own gate — this is what makes the
Apex-side "advance to the next stage" allow-list record-type-aware to match the new picklist
inclusion lists. See `ARCHITECTURE.md` § 2, `RecordStageAdvanceService` row, and
`RecordStageAdvanceServiceTest.psaSequencesAreSplitPerRecordType`. That row was already current
before this documentation pass — no edit was needed there for this reason (see *ARCHITECTURE.md
Update* below).

---

## 🔑 Key Design Decisions and Rationale

Pulled directly from the field-level XML comments in the deployed metadata (the repo convention for
this project — see `ARCHITECTURE.md` § 1's audit note on why these comments, not `<description>`,
carry the full rationale).

### O3 — the two objects are deliberately asymmetric, and that asymmetry is a hard stop

`LOI__c.Stage__c` **deactivates** its four retired values. `Contract_Review__c.Negotiation_Status__c`
**deactivates nothing** — its three retired values stay active on the field because
`Disposition_PSA` still runs on all three; they are removed only from the `Acquisition_PSA` record
type's inclusion list. The two changes "look like the same change and are not." `apply-d3.js` asserts
this at deploy time (its post-condition checks fail loudly if any value on `Negotiation_Status__c`
carries `<isActive>false</isActive>`), and the falsifier harness (`falsify.js`) proves that assertion
actually catches a mutated version of the script that tries to harmonize the two.

### Ordering arithmetic differs per field — append vs. insert

Runtime Path step order comes from the **field's own value order** (`sorted=false`), filtered by
record type; a record type can only include/exclude values, never reorder them. Where a new value
lands in the master list therefore decides what a Path renders:

- **`LOI__c.Stage__c` — append was sufficient.** The one value shared with the disposition sequence
  (`Under Review`) already sat at a position correct for both sequences, so simply appending the three
  new values (`Submitted`, `Negotiation`, `Signed`) after the existing 10 produced a monotonic order
  for both record types.
- **`Contract_Review__c.Negotiation_Status__c` — append would have been wrong.** The shared value here
  is `Executed`, the **terminal** step, already at position 4. Appending would have rendered
  `Acquisition_PSA`'s Path as `Executed, Draft, Negotiation, Signed` — the finish line first, on a
  change that would have deployed green and passed every automated test. The three new values were
  therefore **inserted before `Executed`** instead.

The repo's own comment on this: *"Three fields in this programme have now needed three different
answers — LOI append, PSA insert, and `NDA__c.Status__c` an interleave. Redo the arithmetic for every
value ever added; the answer does not transfer, even between two fields changed on the same day."*

### The two objects swapped a structural property (disjoint ↔ overlapping)

Before this change, `LOI__c.Stage__c`'s acquisition and disposition value sets were **fully
disjoint** (no shared value, so a stage-keyed flexipage rule was automatically self-limiting to one
record type with no explicit record-type criterion needed), while `Contract_Review__c
.Negotiation_Status__c`'s two record types were **identical** (both ran the same four values). This
change **exchanged that property between the two objects**:

| | Before 2026-08-14 | After | In effect from |
|---|---|---|---|
| `LOI__c.Stage__c` | Disjoint | **Overlaps** at `Under Review` (reused, not renamed — it has been step 2 of the disposition sequence since Tranche 3B) | P3-D1 |
| `Contract_Review__c.Negotiation_Status__c` | Identical | **Disjoint** except the shared terminal `Executed` | Only from P3-D3 |

Both terminals stayed distinct throughout (`Signed` on acquisition LOI vs. `Executed` on disposition
LOI; `Executed` shared-but-sole-terminal on the PSA), which is why every terminal-state comparison in
the codebase kept working unmodified — it is the **middle** of each sequence that became ambiguous,
which is the harder case to notice in a diff.

**What this cost, concretely:**

- **`LOI__c.Is_Advance_Allowed__c` (C1)** — this formula backs the "Advance Stage" button's visibility
  on both LOI record types. Its acquisition-approval clause used to read `OR(TEXT(Stage__c) <>
  "Prepare/Review", TEXT(LOI_Status__c) = "Approved")`, inert on disposition only because
  `'Prepare/Review'` wasn't a disposition value. Repointing it to `'Under Review'` (now shared) with
  no guard would have made the clause **live on disposition too** — a disposition LOI at `Under
  Review` (its normal step 2 of 5) would have had Advance Stage hidden unless `LOI_Status__c =
  'Approved'`, which nothing on the sell-side path ever writes, silently dead-ending every
  disposition LOI. The fix adds a `RecordType.DeveloperName <> "Acquisition_LOI"` disjunct — the
  **only** clause in the formula that needed a record-type guard; the field's header notes this is
  the third occurrence of the same class of defect (a terminal/branch-state test written against one
  record type's value set and inherited by a second one with a different value set), following D20/C1
  and D22.
- **`Completed_LOI_Before_PSA` (C2)** — the requirements described a straight swap
  `'Completed'` → `'Signed'`, which is correct on only one side of the row migration and blocks every
  deal in the other direction. The rule instead ships as `AND(<> 'Completed', <> 'Signed')` at P3-D1
  (correct before, during, and after the migration — "list both then drop", the same shape used in
  the sibling Phase 2 change to `Deal_Pipeline_by_Stage`), then drops the `'Completed'` leg at P3-D3.
- **`Contract_Review_Stage_Sync` (C4)** and **`PSA_Ready_Notify` (C4b)** — see the Flows table above.

### A restricted picklist makes deactivation a real control, not cosmetic

Both `LOI__c.Stage__c` and `Contract_Review__c.Negotiation_Status__c` are `restrictedPicklist: true`
in the org (measured 2026-08-14, matching the repo's `<restricted>true</restricted>`). This is why
deactivating a value actually **rejects** DML that tries to write it, rather than merely hiding it
from pickers while Apex/Flow/Data Loader keep writing it silently — and it is also why the row
migration described below had to complete first: a restricted picklist rejects an inactive value at
DML, so any row still holding a deactivated value becomes unsaveable until a human changes its stage
by hand.

### The migration filter — record type, never value; `!= Disposition`, never `= Acquisition`

A measured, pre-deploy finding: two rows sat on values Phase 3 was about to retire while carrying
**no record type at all (Master)** — one LOI on `Completed`, one Contract Review on `Executed`. A
migration filter written the "natural" way (`RecordType.DeveloperName = 'Acquisition_LOI'`) would have
**missed** the Master row and left it on a value about to be deactivated, making that record
permanently unsaveable. The correct filter is the negative form: `RecordType.DeveloperName !=
'Disposition_LOI'` (and the PSA analogue), because a Master row's `RecordType.DeveloperName` is blank,
which fails the positive equality test but passes the negative inequality test. This is recorded in
the runbook as *"the natural filter to write is the WRONG one"* and is the single most safety-critical
finding in the pack.

---

## 🔄 Deploy Sequence

```
P3-D1 (additive — every new value, and every edit correct on BOTH sides of the migration)
   │  LOI__c.Stage__c              +3 values (Submitted, Negotiation, Signed)
   │  Contract_Review__c.Negotiation_Status__c  +3 values (Draft, Negotiation, Signed, inserted before Executed)
   │  Acquisition_LOI / Acquisition_PSA record types: transitional inclusion lists (9-step / 7-step Paths)
   │  Is_Advance_Allowed__c: 3 transitional clauses added, RecordType guard added
   │  Completed_LOI_Before_PSA: AND(<> 'Completed', <> 'Signed')
   │  Contract_Review_Stage_Sync, PSA_Ready_Notify: widened
   ▼
[ORG-Q] describe verification — LOI__c.Stage__c: 13 values all active; Negotiation_Status__c: 7 values all active
   ▼
[MIG] row migration — filter: RecordType.DeveloperName != 'Disposition_LOI' / != 'Disposition_PSA'
   │  (moves any Master-record-type row off the retiring values BEFORE they are deactivated/excluded)
   ▼
P3-D2 (Apex, separate change) — RecordStageAdvanceService's per-record-type stage maps split/updated
   ▼
P3-D3 (subtractive — agent-output/p3-d3-retire-loi-psa/apply-d3.js, 13 atomic edits)
   │  LOI__c.Stage__c: 4 legacy values → isActive=false
   │  Acquisition_LOI record type: 4 legacy values removed from inclusion list
   │  LOI_Path_Acquisition: 4 legacy steps removed (9 → 5 steps)
   │  Completed_LOI_Before_PSA: 'Completed' leg dropped
   │  Is_Advance_Allowed__c: 3 transitional clauses dropped
   │  Acquisition_PSA record type: 3 legacy values removed, default flipped Initial Draft → Draft
   │  Contract_Review_Path_Acquisition: 3 legacy steps removed (7 → 4 steps)
   │  Negotiation_Status__c: UNCHANGED (decision O3 — hard stop, asserted by the script)
   ▼
DEPLOYED — usman-dpeg
```

The subtractive step (`apply-d3.js`) is **two-phase and atomic**: every edit is applied in memory
first, and each edit must match its anchor text **exactly once**; if any edit fails to match, nothing
is written to disk. A companion falsifier (`falsify.js`) builds ten deliberately mutated copies of the
tree and confirms the real script rejects all ten (non-zero exit, no files written) plus a positive
control that cleanly rewrites the 7 target files on an unmutated tree. Last verified 2026-08-14:
`--check` green on all 13 edits; falsifier 10/10 mutations caught.

---

## 📁 File Locations

| Component | Path |
|-----------|------|
| LOI stage field | `force-app/main/default/objects/LOI__c/fields/Stage__c.field-meta.xml` |
| LOI advance-allowed formula | `force-app/main/default/objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml` |
| Acquisition LOI record type | `force-app/main/default/objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml` |
| Disposition LOI record type (comment-only edit) | `force-app/main/default/objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml` |
| PSA negotiation-status field | `force-app/main/default/objects/Contract_Review__c/fields/Negotiation_Status__c.field-meta.xml` |
| Acquisition PSA record type | `force-app/main/default/objects/Contract_Review__c/recordTypes/Acquisition_PSA.recordType-meta.xml` |
| Disposition PSA record type (comment-only edit) | `force-app/main/default/objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml` |
| LOI Path (acquisition) | `force-app/main/default/pathAssistants/LOI_Path_Acquisition.pathAssistant-meta.xml` |
| Contract Review Path (acquisition) | `force-app/main/default/pathAssistants/Contract_Review_Path_Acquisition.pathAssistant-meta.xml` |
| Validation rule | `force-app/main/default/objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml` |
| Coarse-stage sync flow | `force-app/main/default/flows/Contract_Review_Stage_Sync.flow-meta.xml` |
| PSA-ready notification flow | `force-app/main/default/flows/PSA_Ready_Notify.flow-meta.xml` |
| Quick actions | `force-app/main/default/quickActions/LOI__c.Mark_Completed.quickAction-meta.xml`, `LOI__c.Mark_Countered.quickAction-meta.xml` |
| Subtractive-step script + falsifier + runbook | `agent-output/p3-d3-retire-loi-psa/apply-d3.js`, `falsify.js`, `README.md` |
| Full deploy runbook | `agent-output/runbook-acquisition-observations-phase3.md` |
| Design requirements (source of the C1/C2/C4/C9/O3 findings) | `agent-output/design-requirements-acquisition-observations.md` |

---

## ⚙️ Configuration Details

### `LOI__c.Stage__c` — final state (13 total values, 9 active, 4 inactive)

| Value | Status | Record type(s) |
|---|---|---|
| `Draft` | Active (field default) | `Acquisition_LOI` |
| `Prepare/Review` | **Inactive** | retired — was `Acquisition_LOI` |
| `Sent` | **Inactive** | retired — was `Acquisition_LOI` |
| `Counter` | **Inactive** | retired — was `Acquisition_LOI` |
| `Completed` | **Inactive** | retired — was `Acquisition_LOI` |
| `Received` | Active | `Disposition_LOI` |
| `Under Review` | Active | **Both** `Acquisition_LOI` and `Disposition_LOI` |
| `Countered by DPEG` | Active | `Disposition_LOI` |
| `Counter Received from Buyer` | Active | `Disposition_LOI` |
| `Executed` | Active | `Disposition_LOI` (terminal) |
| `Submitted` | Active | `Acquisition_LOI` |
| `Negotiation` | Active | `Acquisition_LOI` |
| `Signed` | Active | `Acquisition_LOI` (terminal) |

Acquisition_LOI's final Path: `Draft → Under Review → Submitted → Negotiation → Signed`.
Disposition_LOI's Path (unchanged): `Received → Under Review → Countered by DPEG → Counter Received
from Buyer → Executed`.

### `Contract_Review__c.Negotiation_Status__c` — final state (7 total values, all active)

| Value | Record type(s) |
|---|---|
| `Initial Draft` | `Disposition_PSA` (field default) |
| `Revised` | `Disposition_PSA` |
| `Ready for Execution` | `Disposition_PSA` |
| `Draft` | `Acquisition_PSA` (record-type default) |
| `Negotiation` | `Acquisition_PSA` |
| `Signed` | `Acquisition_PSA` |
| `Executed` | **Both** `Acquisition_PSA` and `Disposition_PSA` (terminal on both) |

Acquisition_PSA's final Path: `Draft → Negotiation → Signed → Executed`.
Disposition_PSA's Path (unchanged): `Initial Draft → Revised → Ready for Execution → Executed`.

### `LOI__c.Is_Advance_Allowed__c` — final formula

```
AND(
  TEXT(Stage__c) <> "Signed",
  TEXT(Stage__c) <> "Executed",
  TEXT(Stage__c) <> "Submitted",
  OR(
    RecordType.DeveloperName <> "Acquisition_LOI",
    TEXT(Stage__c) <> "Under Review",
    TEXT(LOI_Status__c) = "Approved"
  ),
  TEXT(LOI_Status__c) <> "Pending Approval"
)
```

### `Completed_LOI_Before_PSA` — final error condition

```
AND(
    ISCHANGED(StageName),
    ISPICKVAL(StageName, 'Under Contract (PSA)'),
    NOT(ISBLANK(Primary_LOI__c)),
    TEXT(Primary_LOI__r.Stage__c) <> 'Signed'
)
```

---

## 🧪 Testing

**No `salesforce-unit-testing` or `salesforce-code-review` agent was invoked for this change** — it
is declarative metadata only (no Apex, no LWC), which is outside the scope of those agents per the
project workflow. The falsifier described above (`agent-output/p3-d3-retire-loi-psa/falsify.js`) is
the mechanism-level safety net for the subtractive script itself, not a Salesforce unit test.

The sibling Apex change (P3-D2, `RecordStageAdvanceService`'s per-record-type map split) has its own
existing test coverage, most relevantly `RecordStageAdvanceServiceTest
.psaSequencesAreSplitPerRecordType`, which is the standing falsifier for "the two PSA record types
still share one map" — it must stay green after this change, and was not independently re-run by
this documentation pass.

Note on a documented artifact (§0.3(b) of the runbook): a validation/test run taken **before** P3-D1
deploys will show a block of `bad value for restricted picklist field: Draft` failures — measured at
+44 failures (baseline 35 → 79), entirely attributable to test fixtures already written against the
post-migration vocabulary. This is a deploy-ordering artifact, not a regression, and disappears once
P3-D1's field files are in the payload.

---

## 🔒 Security

No permission sets, sharing rules, or profile changes were part of this change. No new custom fields
were introduced (both touched fields already existed), so no new FLS grants were required.

---

## 📝 Notes & Considerations

### Known Limitations / Open Items

| Item | Status |
|---|---|
| **`LOI_Record_Page`'s `Submit_for_Approval` visibility rule is no longer self-limiting (runbook § 1.6 / gate P3-G7)** | Its criterion moved `Prepare/Review` → `Under Review`, which is now shared with `Disposition_LOI`. An acquisition driver opening a *disposition* LOI at `Under Review` will now see the "Submit for Approval" button; clicking it targets `Opportunity.LOI_Approval`, which a disposition LOI has no relationship to, and fails loudly. **This was a deliberate decision to leave open**, not an oversight — the only in-repo remedy (a new formula-checkbox discriminator) would make one currently-working acquisition button newly dependent on a brand-new field's FLS, the same class of trade the repo has previously declined to make for `NDA__c.Is_Decline_Allowed__c`. Three remedies are recorded in the runbook if this is judged unacceptable; none has been chosen. |
| **Record-type picklist *inclusion list* narrowing is not independently verifiable via any available API** (SOQL, Tooling API, or a metadata retrieve+read) — confirmed narrowed only by inspecting the deployed `.recordType-meta.xml` files directly, as done for this documentation pass. A manual Setup UI check of `Acquisition_LOI` (5 Stage values) and `Acquisition_PSA` (4 Negotiation Status values) has **not** been independently performed and is a recommended follow-up. |
| **Live org row counts came back lower than a day-old runbook snapshot expected** — 1 `LOI__c` row instead of 6, 0 `Contract_Review__c` rows instead of 3+, at the time of this documentation pass. Cause not investigated as part of this change; flagged here for follow-up. |
| **4 `LOI__c.Stage__c` master values were found deleted (not deactivated) in the org during an earlier step of P3-D1**, for an unexplained reason — `Prepare/Review`, `Countered by DPEG`, `Counter Received from Buyer`, `Executed`. The team chose to redeploy the field anyway, which restored all four as a side effect of the additive, non-destructive redeploy. Setup Audit Trail was suggested as a way to identify the cause but has not been run. |
| `objectTranslations/**` for both fields remain stale and were deliberately not touched — `LOI__c-en_US/Stage__c` enumerates only the original 5 acquisition values (never updated when the 5 disposition values were added in Tranche 3B either), and `Contract_Review__c-en_US/Negotiation_Status__c` still lists two values (`Seller Counter`, `Buyer Counter`) removed from the field back on 2026-08-05. Whether the Metadata API accepts a translation file naming an inactive value is unverified in this org — bringing these files current is a worthwhile separate change. |
| A known, permanent boundary case on `Completed_LOI_Before_PSA`: any deal **already** sitting at `Under Contract (PSA)` with a non-`Signed` primary LOI is unaffected by this change and will never be caught by the rule (validation rules only fire on save when the gated field changes) — this is documented in the rule's own XML comment as an accepted, permanent limitation, not something this change attempts to retroactively correct. |

### Dependencies

- Depends on Phase 2 of the same fix pack (`Opportunity.StageName` `PSA` → `Under Contract (PSA)`)
  having deployed first — `Completed_LOI_Before_PSA`'s Opportunity-side literal is Phase 2's edit to
  the same file, and Phase 3's edit was required to land strictly after it.
- Depends on the P3-D2 Apex change (`RecordStageAdvanceService`'s record-type-aware maps) landing in
  the same window, so that the Apex-side "advance to next stage" allow-list matches the new picklist
  inclusion lists — record-type picklist restriction is UI-only and is **not** enforced by Apex DML,
  so the Apex allow-list is the only thing that actually refuses an illegitimate direct write.
- `OpportunityReviewService`'s Contract Review auto-create still stamps no `Negotiation_Status__c` and
  takes the **field-level** default (`Initial Draft`), which is not on `Acquisition_PSA`'s inclusion
  list after this change — this commits silently, since record-type picklist restriction is UI-only.
  This is tracked in the source design doc as requirements item **C3** and is developer work, not
  fixable from metadata alone; it is out of scope for this documented change.

---

## ARCHITECTURE.md Update

**No edit was made to `ARCHITECTURE.md`.** Per this task's request, `ARCHITECTURE.md` § 1 ("Current
objects") and its surrounding prose were searched for existing commentary about this change — the
task description anticipated a "large existing block of retraction commentary" written in
anticipation of this deploy (citing search terms `P3-D3` and `RETRACTED 2026-08-14`). A thorough
search (multiple grep passes across the full file, including untruncated reads of every matching
line, per this repo's own documented gotcha about grep silently truncating long matching lines) found
**no occurrence of either string, and no prose anywhere in `ARCHITECTURE.md` describing the LOI/PSA
stage retirement, the P3-D1/P3-D3 gates, or the disjoint↔overlap swap** — that entire narrative lives
in the deployed field/record-type XML comments (`LOI__c/fields/Stage__c`,
`Contract_Review__c/fields/Negotiation_Status__c`, both `Acquisition_*` record types, both Path
Assistants) and in `agent-output/runbook-acquisition-observations-phase3.md`, not in
`ARCHITECTURE.md`. `ARCHITECTURE.md` § 1's table rows for `LOI__c` and `Contract_Review__c` carry no
`Purpose` prose (both show `—`) and were unaffected.

This is consistent with `ARCHITECTURE.md` § 6's stated triggers for a mandatory update ("a custom
object is added," "a new Apex service is introduced," "an external integration is wired") — this
change touches none of them: `LOI__c` and `Contract_Review__c` are pre-existing objects, no Apex
service was created or changed by the declarative work documented here, and no integration boundary
was touched. The `RecordStageAdvanceService` row in § 2 (which *does* narrate the record-type-map
split this Phase 3 work depends on) was already current at the time of this pass and required no
edit.

---

## 📜 Change History

| Date | Author | Change Description |
|------|--------|-------------------|
| 2026-08-15 | Documentation Agent | Initial creation, documenting the P3-D1 (additive) and P3-D3 (subtractive) declarative deploys of the LOI/PSA legacy stage retirement, both completed and deployed to `usman-dpeg` prior to this pass. |
