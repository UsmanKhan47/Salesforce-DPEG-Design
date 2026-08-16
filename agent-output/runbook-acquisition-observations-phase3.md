# Deploy Runbook — Acquisition Observations, Phase 3 (declarative)

**Author:** salesforce-solution-architect · **Date:** 2026-08-14
**Target org:** `usman-dpeg` (`usman.khan.dpeg@avanzasolutions.com`, `00Diw000000Fqw1EAC`)
**Source:** `docs/superpowers/specs/2026-08-14-acquisition-app-observations-design.md` §0.0 / §4.2 / §4.3,
`agent-output/design-requirements-acquisition-observations.md` §3 (Phase 3) / §7 (Phase 3) / §9 C1/C2/C4/C9
**Model:** `runbook-acquisition-observations-phase1.md` and `-phase2.md` — same shape, same conventions.

**NOTHING IN THIS PACK HAS BEEN DEPLOYED.** Every step below is pending.
**Phase 3 is serialised AFTER Phase 2**, which is itself after Phase 1. See §0.3 — Phase 2 is
measured as **not yet in the org**.

Two changes, one phase:

| Observation | Object | Change |
|---|---|---|
| **5** | `LOI__c.Stage__c` | acquisition sequence → `Draft → Under Review → Submitted → Negotiation → Signed`; four old values deactivated |
| **7** | `Contract_Review__c.Negotiation_Status__c` | acquisition sequence → `Draft → Negotiation → Signed → Executed`; **NOTHING deactivated** |

Both run the same `add → migrate → repoint → retire` shape Phases 1 and 2 used.

> 🔴 **GATE LABELS IN THIS DOCUMENT ARE PREFIXED `P3-` AND THAT PREFIX IS LOAD-BEARING, NOT
> DECORATION (added 2026-08-14).** Two documents number gates `G1…Gn` — this runbook's §4, and
> `agent-output/design-requirements-acquisition-observations.md` §8 — and **these two spaces agree
> NOWHERE.** Not at G1, not at any number. This is the worse case of the two the pack has found:
> Phase 4's local space at least agreed with requirements §8 through G3.
>
> | This runbook (now `P3-Gn`) | The SAME bare number in requirements §8 |
> |---|---|
> | G1 finish Tranche 3B/3C's record-type row migration | G1 **schedule `CallForOffersAlertSchedule`** |
> | G2 record-type assignment + per-profile default | G2 **verify the `Acquisition` queue's membership** |
> | G3 render probe on `LOI_Record_Page` | G3 **assign the permission sets** (§8's render probe is **G6**) |
> | G4 confirm `PSA_Ready_Notify` still fires | G4 **reconcile the permission sets org → repo** |
> | G5 confirm the coarse `Stage__c` projection | G5 **record-type visibility + the `Retail` default** |
> | G6 re-point org-side reports and dashboards | G6 **render probe** (§8's reports gate is **G8**) |
> | G7 decide §1.6's open residual | G7 **verify `LeadConfig` in Setup** |
> | G8 confirm `LOI_Path` is not swept into a deploy | G8 **re-point reports and dashboards** |
>
> An operator cross-referencing a bare "G3" or "G6" between the two documents lands on **the wrong
> gate**, in a pack whose entire safety story is "follow the gates". Every local gate here is
> therefore **`P3-G1…P3-G8`**, and any reference to a gate in the other document names it explicitly
> as **requirements §8 Gn**. ⚠ Cross-document gate references in this runbook are, as of 2026-08-14,
> confined to **this box** and to **§1.10's closing line** (which contrasts `P3-G6` with requirements
> §8's `G6` and `G8`). Both name their document. That is a measured fact about this file, not a
> licence to write a bare `Gn` into it later.
>
> ⚠ **The other three runbooks are NOT all in this state — do not generalise from this one.**
> **Phase 4** carries the same treatment under **`P4-G1…P4-G7`**; its space agrees with requirements
> §8 through G3 and diverges from G4. **Phases 1 and 2 are deliberately NOT prefixed and must not
> be:** Phase 1 uses a strict SUBSET of requirements §8's numbers with identical meanings, and
> Phase 2 stays inside that space and extends it upward (G8-a, G8-b, G9–G13). Prefixing either
> would break an agreement that currently holds. The asymmetry is a recorded decision, not an
> oversight — see the pointer box in requirements §8.

---

## 0. Read this before anything else

### 0.1 🔴 OBSERVATION 4 IS WITHDRAWN — nothing about Underwriting is in this phase

`Underwriting__c.Stage__c` is **not touched**. No `Rejected` value, no Path step, no
`Underwriting_Record_Page` edit, no rejection-side flow, no approval wiring. Spec §4.1 is void
(spec §0.0). Requirements **C5, C6 and C8 are retired with it** and must not be actioned — C8's
parenthesised-OR `booleanFilter` hazard in particular belongs to a page this phase never opens.

### 0.2 🔴 O3 IS A HARD STOP — `Negotiation_Status__c` LOSES NOTHING

`Initial Draft`, `Revised` and `Ready for Execution` stay **ACTIVE on the field**. They are removed
from the **`Acquisition_PSA` record type only**. `Disposition_PSA` runs on all three and is
untouched. Deactivating any of them deletes the entire sell-side PSA sequence.

⚠ The LOI half and the PSA half **look like the same change and are not.** On `LOI__c.Stage__c`
the four retired values ARE deactivated, because no record type still uses them. On
`Negotiation_Status__c` nothing is. `agent-output/p3-d3-retire-loi-psa/apply-d3.js` asserts this
(mutation **M6** in its falsifier), so the mistake fails loudly rather than shipping.

### 0.3 🔴 MEASURED ORG FACTS — taken 2026-08-14 against `usman-dpeg`. Read these; several change what a step means.

**(a) Picklist restriction — describe the field, do not trust the repo.**

| Field | org `restrictedPicklist` | repo `<restricted>` | Agree? |
|---|---|---|---|
| `LOI__c.Stage__c` | **true** | `true` | ✅ |
| `Contract_Review__c.Negotiation_Status__c` | **true** | `true` | ✅ |
| `Opportunity.StageName` | 🔴 **false** | n/a (StandardValueSet) | — |

**What that buys this phase:** because `LOI__c.Stage__c` is genuinely restricted **in the org**,
the P3-D3 deactivation is a **real control** — after it, DML writing `Prepare/Review`, `Sent`,
`Counter` or `Completed` is REJECTED, not stored. Had it come back `false`, deactivation would only
have removed the values from pickers while Apex, Flow, Data Loader and the API all kept writing
them silently, and the whole retirement would have been cosmetic.

🔴 **`Opportunity.StageName` is `restrictedPicklist: false`, and that is PHASE 2's problem, not
this one — but it lands here because Phase 3 edits a rule that reads it.** An unrestricted picklist
**stores an off-list value silently**. Two consequences carry into this runbook: a green Apex run is
**not** evidence a stage deploy landed (only the org describe is), and Phase 2's deactivation of
`PSA` will **not** stop anything from writing `PSA` afterwards.

🔴 **THE TRANSFERABLE RULE, AND IT IS THE ONLY SAFE ONE: DESCRIBE THE FIELD FIRST.** Repo state is
not org state. The repo said `restricted=true` for both custom fields and was right; it says nothing
useful about the standard one. Neither outcome was knowable without asking the org.

**(b) The restricted-picklist / check-only question is OPEN. Do not resolve it in either direction.**
Does a restricted-picklist value added by a **check-only** deploy become DML-valid within that run?
**Three** observations now exist on this programme:

| | Phase 1 | Phase 2 — 🔴 **RETRACTED** | Phase 3 — new, 2026-08-14 |
|---|---|---|---|
| Field under test | a restricted picklist | `Opportunity.StageName` — since measured **`restrictedPicklist: false`** (fact (a)) | `Contract_Review__c.Negotiation_Status__c` — **genuinely restricted**, org and repo agree (fact (a)) |
| Setup | value added by a check-only deploy | same, **with the picklist metadata in the check-only payload** | same, `Draft` added by a check-only deploy |
| DML using the value | **REJECTED** — DML-invisible | ACCEPTED — **claim withdrawn** | **REJECTED** — DML-invisible |

**Why Phase 2's row is struck.** The field it tested was not restricted at all, so an off-list value
stores silently regardless of what the payload carried — the payload was never the operative
variable. A reviewer who endorsed that reading has withdrawn the endorsement on the same grounds.
🔴 **Naming a controlling variable is not the same as naming the right one**, and a confidently
named wrong one is worse than none because it ends the search.

**Tally: two observations for DML-invisible, one retracted for valid. That is suggestive and it is
not conclusive.** The two surviving runs still differ in deploy route and in payload contents — which
is exactly why the question stays **OPEN**. Do not close it on this evidence, and do not design any
step around either answer.

This runbook therefore still makes exactly one claim about check-only runs, unchanged and
outcome-independent: **a check-only run is never the [ORG-Q] evidence for a step.** Whatever the
mechanism, the value is gone the instant the run rolls back. Every verification below reads the org
after a **real, committed** deploy.

> ### 🔴 OPERATIONAL CONSEQUENCE — a validation run taken BEFORE P3-D1 WILL show a large block of restricted-picklist failures. That is a DEPLOY-ORDERING ARTIFACT, not a defect.
>
> Measured on this branch, 2026-08-14, as the org stands: baseline **35** failures, **79** after —
> and **all 44 of that increase was one artifact**, `bad value for restricted picklist field: Draft`.
> Bucketed: `Draft` **11 → 58**; every other bucket **unchanged**.
>
> **Expected shape, so nobody mistakes it for a regression:**
> - the messages **name the new values** the branch adds (`Draft` today; the same mechanism applies
>   to `Submitted` / `Negotiation` / `Signed` wherever a test writes one);
> - they appear only in a run whose payload does **not** carry P3-D1's field files;
> - they **disappear the moment P3-D1 deploys the values**, with no other change.
>
> **Three things not to do:**
> 1. Do **not** chase them as test defects — the tests are already written to the post-migration
>    vocabulary, which is correct.
> 2. Do **not** "fix" the tests back to the old values (`Initial Draft`, `Prepare/Review`, `Sent`,
>    `Counter`, `Completed`). That reverses §6's handoff and re-introduces the exact assertions the
>    migration exists to retire — and it would pass, which is what makes it dangerous.
> 3. Do **not** read the totals as the signal. Compare **buckets** against the baseline; a real
>    regression is a bucket that is not one of the new values.
>
> **The diagnostic technique used to establish this, and its guardrail.** The Phase 3 test-fix
> developer separated "this failure is the missing value" from "this failure is real" by flipping
> `<restricted>true</restricted>` → `false` on a **scratchpad COPY** of the field file and running
> against that. Legitimate, and worth reusing — it is a probe, not a change. 🔴 **The copy only,
> never the shipped file.** The shipped field files are untouched and must stay `restricted=true`:
> fact (a) is the whole reason P3-D3 is a real control rather than a cosmetic. A probe copy must
> never be deployed and never be committed.

**(c) 🔴 PHASE 2 IS NOT DEPLOYED. Measured, not assumed.** `Opportunity.StageName` in the org holds
11 values: `PSA` is **ACTIVE** and `Under Contract (PSA)` is **ABSENT**. The repo's
`standardValueSets/OpportunityStage` holds 12 and carries both. So Phase 2's P2-D1 has not run.
Phase 3 must not start until Phase 2 has completed through P2-D3. *(Checked while there: the org's
`Portfolio Deal` stage IS present in the repo file, so Phase 2's replace-not-merge hazard has no
known casualty on this value.)*

**(d) 🔴 THERE ARE MASTER-RECORD-TYPE ROWS ON A VALUE THIS PHASE RETIRES.** This is the single most
important measurement in this runbook and it changes the migration filter — see §3 `[MIG]`.

```
LOI__c                                        Contract_Review__c
  Acquisition_LOI  Draft         1              Acquisition_PSA  Executed        2
  Acquisition_LOI  Completed     1              Disposition_PSA  Initial Draft   3
  (MASTER)         Completed     1  🔴          (MASTER)         Executed        1
  Disposition_LOI  Received      3
```

Tranche 3B/3C's post-deploy row migration onto the record types is **incomplete** — one LOI and one
Contract Review are still on **Master**. A migration filtered on
`RecordTypeId = <Acquisition_LOI>` would **miss the Master LOI sitting on `Completed`** and strand
it on a value that P3-D3 then deactivates. Because the field is genuinely restricted (fact (a)),
that row becomes **unsaveable** until someone changes its stage by hand, and its Path renders blank.

⚠ **These counts are a snapshot.** Re-run the queries in §3 immediately before executing; do not
plan against these numbers.

🔴 **THE CORRECTION THIS FORCES IS WRITTEN OUT IN FULL, WRONG-VS-RIGHT, AT THE `[MIG]` STEP IN §3.
Do not write a migration filter from this section — go and read that box.** The natural filter
(`= 'Acquisition_LOI'`) is the wrong one, and the cost of getting it wrong is a record that can
never be saved again.

**(e) 🔴 HARD PREREQUISITE FOR ANY VALIDATION OF THIS BRANCH — `Opportunity.Deal_Type__c = 'Retail'`
IS COMMITTED BUT NOT DEPLOYED.**

Phase 1 added `Retail` to `Opportunity.Deal_Type__c` (commit `22c6113`). It is in the repo and it is
**not in the org**. `TestDataFactory` writes `Deal_Type__c = 'Retail'` on every Opportunity it
builds, and that field is `<restricted>true</restricted>` — so unless
`objects/Opportunity/fields/Deal_Type__c.field-meta.xml` is in the payload, **every fixture dies at
insert before a single line of test logic runs.** Measured 2026-08-14: **126 failures**, all of that
one shape.

**This is a prerequisite, not a footnote.** It is not specific to Phase 3 — it applies to any
validation, check-only or test run of this branch — and it fails in a way that **buries every other
signal in the run**, including (b)'s artifact and any genuine regression. Include the field file in
the payload of any such run.

⚠ Deploying it for real belongs to **Phase 1**, not here. It is not added to any §3 file list, and
Phase 3 must not adopt it as one of its own steps.

### 0.4 Scope boundaries observed

- **Apex and LWC were NOT touched.** A developer agent owns them concurrently. §6 is the handoff.
- **No API name was renamed.** `Completed_LOI_Before_PSA`, `LOI__c.Mark_Completed`,
  `LOI__c.Mark_Countered` keep their API names; only **labels** and **values** moved. Renaming a
  quick action is a delete-and-recreate whose blast radius includes FlexiPage `valueListItems`.
- **`objectTranslations/` is NOT in any Phase 3 deploy.** See §1.4.
- **No disposition file's picklist values changed.** Two disposition record-type files were edited
  — **comment and `<description>` text only** — because each asserted a property this phase falsifies.
  §2 is the diff gate that proves it.

---

## 1. Current repo state

> # 🔴 THE ONE THING TO CARRY OUT OF PHASE 3: THE TWO OBJECTS **SWAPPED** PROPERTIES
>
> `LOI__c.Stage__c` and `Contract_Review__c.Negotiation_Status__c` are the acquisition /
> disposition sibling pair, and repo prose has long reasoned **from one to the other**. Phase 3
> made them exchange the property every one of those arguments rests on:
>
> | | before 2026-08-14 | after | in effect from |
> |---|---|---|---|
> | `LOI__c.Stage__c` | **DISJOINT** | 🔴 **OVERLAPS** at `Under Review` | **P3-D1** |
> | `Contract_Review__c.Negotiation_Status__c` | **IDENTICAL** | ✅ **DISJOINT** except the terminal `Executed` | 🔴 **P3-D3 — NOT D1** |
>
> > 🔴 **THE TWO HALVES DO NOT LAND TOGETHER, AND THE WINDOW BETWEEN THEM IS THE NEAR-TERM STATE —
> > nothing in this pack is deployed yet.** The LOI overlap arrives at **P3-D1**, with the three new
> > values. The PSA disjointness arrives **only at P3-D3**: the additive step leaves `Acquisition_PSA`
> > carrying **seven** values, including `Initial Draft`, `Revised` and `Ready for Execution` — every
> > one of which `Disposition_PSA` also carries and keeps (decision O3, nothing is deactivated).
> > **For the whole D1 → D3 window the two PSA sets are NOT disjoint and a status-keyed rule on
> > `Contract_Review__c` is NOT self-limiting.** The `after` column is the post-migration END STATE.
> > ⚠ Reading it as if it took effect on 2026-08-14 inverts the fact for exactly the period this
> > table will be read in — which is the opposite of what this block exists to do.
> > `flexipages/Contract_Review_Record_Page` already states the qualifier in the same words: *"from
> > P3-D3 a rule keyed on any NON-terminal status value here WOULD be self-limiting"*. Both master
> > picklist files now carry it too.
>
> **"The sets are disjoint, so a rule keyed on a stage value is SELF-LIMITING to its record type"
> was true of LOI and false of the PSA. It is false of LOI from P3-D1 and true of the PSA only from
> P3-D3.** Anyone
> carrying that sentence in either direction after this date is reasoning from the **inverse** of
> the facts — and it fails **silently**: a rule that stops being self-limiting renders a button on
> the wrong record type; one that becomes self-limiting hides it. Neither errors, and no test sees
> it.
>
> **It has already cost real work, in both directions:**
> - LOI lost it ⇒ `Submit_for_Approval` on `LOI_Record_Page` keys on a now-shared value and carries
>   the **open, undecided residual** in §1.6 / gate **P3-G7**; and `Is_Advance_Allowed__c`'s approval
>   clause needed a `RecordType.DeveloperName` guard — the only clause in that formula with one.
> - PSA gained it ⇒ a stage-keyed rule **would** work on `Contract_Review_Record_Page` **from P3-D3**
>   (not before — see the box above). That
>   option was assessed and **declined** in favour of the custom-permission check, so it is a known
>   declined option rather than an undiscovered one.
>
> ⚠ **The TERMINALS did not move on either object** (`Signed` vs `Executed`; `Executed` shared but
> sole-terminal on the PSA). That is why every terminal-state test still works by naming values
> while the *middle* of the sequence does not — the overlap is mid-sequence, which is the harder
> case to notice.
>
> ⇒ **RULE: never inherit a disjointness claim across this object pair. Re-derive it from the two
> record type files at the moment you need it. It has already inverted once.** The same statement
> is written into both master picklist files so it is found from the code side too.

The working tree is at **P3-D1 + P3-D2 state**: every additive change and every repoint is applied.
The subtractive step (P3-D3) is **staged as a script, not applied**, so the tree stays deployable
at the current step.

### 1.1 Modified — the LOI half (observation 5)

| File | Change |
|---|---|
| `objects/LOI__c/fields/Stage__c.field-meta.xml` | **+3 values** (`Submitted`, `Negotiation`, `Signed`) APPENDED. `<description>` + `<inlineHelpText>` rewritten. New XML comment carrying the disjointness retraction and the ordering arithmetic. |
| `objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml` | `Stage__c` block **+4** (`Under Review`, `Submitted`, `Negotiation`, `Signed`), keeping the four retiring ones. `<description>` rewritten. Two retractions added. |
| `objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml` | 🔴 **values UNCHANGED — comment only.** Its "FULLY DISJOINT" paragraph is now false. |
| `objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml` | **C1.** Formula rewritten + a `RecordType.DeveloperName` guard added. Header instruction retracted. See §1.5. |
| `flexipages/LOI_Record_Page.flexipage-meta.xml` | 3 stage criteria repointed. Disjointness comment rewritten; an **open residual** recorded. See §1.6. |
| `pathAssistants/LOI_Path_Acquisition.pathAssistant-meta.xml` | **+4 steps** (9 total, transitional). Two retractions. |
| `objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml` | **C2.** LOI leg now names **both** terminals. Phase 2's edit to this file was left intact. See §1.7. |
| `quickActions/LOI__c.Mark_Completed.quickAction-meta.xml` | `<label>` `Completed` → `Signed`. **Beyond the brief — see §1.8.** |
| `quickActions/LOI__c.Mark_Countered.quickAction-meta.xml` | `<label>` `Counter` → `Negotiation`. **Beyond the brief — see §1.8.** |

### 1.2 Modified — the PSA half (observation 7)

| File | Change |
|---|---|
| `objects/Contract_Review__c/fields/Negotiation_Status__c.field-meta.xml` | **+3 values INSERTED before `Executed`** — not appended, see §1.3. `<description>` rewritten. New XML comment. **Nothing deactivated.** |
| `objects/Contract_Review__c/recordTypes/Acquisition_PSA.recordType-meta.xml` | `Negotiation_Status__c` block **+3**, keeping the three retiring ones (7 total, transitional). `<description>` rewritten. Retraction added. |
| `objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml` | 🔴 **values UNCHANGED — comment and `<description>` only.** Both asserted the two types share one vocabulary. |
| `pathAssistants/Contract_Review_Path_Acquisition.pathAssistant-meta.xml` | **+3 steps** (7 total, transitional). Two retractions. |
| `flows/Contract_Review_Stage_Sync.flow-meta.xml` | **C4.** New `Is_Draft` decision rule → `Set_Stage_Drafting`. `Is_Initial_Draft` kept. New XML comment. |
| `flows/PSA_Ready_Notify.flow-meta.xml` | 🔴 **C4b — NOT IN ANY BRIEF. See §1.9.** Entry criteria widened to `Ready for Execution` **OR** `Signed`. |

### 1.3 🔴 THE ORDERING ARITHMETIC — one field needed an APPEND, the other an INSERT

Runtime Path order comes from the **field's** value order (`sorted=false`) filtered by the record
type. A record type can only include or exclude — **never re-order**. So where the new values sit
in the master list decides what the Path renders, and this was checked per field rather than
carried across.

**`LOI__c.Stage__c` — APPEND is sufficient.** The one shared value, `Under Review`, already sits at
position 7:

```
Acquisition_LOI  →  Draft(1), Under Review(7), Submitted(11), Negotiation(12), Signed(13)   ✅ monotonic
Disposition_LOI  →  Received(6), Under Review(7), Countered by DPEG(8),
                    Counter Received from Buyer(9), Executed(10)                            ✅ UNCHANGED
```

🔴 **`Contract_Review__c.Negotiation_Status__c` — APPEND WOULD HAVE BEEN WRONG, so the three values
were INSERTED before `Executed`.** The shared value here is the **TERMINAL** and it already sat at
position 4:

```
appended  →  Acquisition_PSA renders  Executed(4), Draft(5), Negotiation(6), Signed(7)
                                      🔴 THE FINISH LINE FIRST
inserted  →  Acquisition_PSA renders  Draft(4), Negotiation(5), Signed(6), Executed(7)      ✅
             Disposition_PSA renders  Initial Draft(1), Revised(2),
                                      Ready for Execution(3), Executed(7)                   ✅ UNCHANGED
```

**It deploys green either way and no test can see it.** Three fields in this programme have now
needed three different answers — LOI append, PSA insert, and `NDA__c.Status__c` an interleave
(`Not Sent` moved ahead of `Sent`). **Redo the arithmetic for every value ever added; the answer
does not transfer, even between two fields changed on the same day.**

### 1.4 ⚠ `objectTranslations/` is deliberately untouched, and it was already incomplete

`objectTranslations/LOI__c-en_US/Stage__c.fieldTranslation-meta.xml` enumerates **five** of the
field's values — the original acquisition set. The five disposition values added in Tranche 3B were
**never added to it** and nothing broke, so the three added here are not added either.
`Contract_Review__c-en_US/Negotiation_Status__c` is worse: it still lists `Seller Counter` and
`Buyer Counter`, both removed from the field on 2026-08-05.

**Neither file is in any Phase 3 deploy list.** ⚠ Do not let directory-scoped tooling pick up
`objectTranslations/`: after P3-D3 the LOI file would name four **deactivated** values, and whether
the Metadata API accepts that is **UNVERIFIED in this org**. Bringing these files up to date is a
worthwhile separate change; doing it inside this phase adds an untested failure mode to a migration.

### 1.5 🔴 C1 — `Is_Advance_Allowed__c` broke three ways, and only ONE of them needed a record type

The field's header carried an explicit instruction: *"DO NOT ADD A `RecordType.DeveloperName` TEST
TO THIS FORMULA. It is not needed — the value sets are disjoint at the terminal stage."* **The
premise died; the instruction is retracted in the file.** Note its own qualifier — *disjoint at the
terminal stage* — is **still true**, which is exactly why two of the three breaks needed no guard.

| # | Break | Fix | Guard? |
|---|---|---|---|
| 1 | Terminal moved `Completed` → `Signed`, so the formula returned TRUE at the new terminal ⇒ **Advance Stage renders on a FINISHED acquisition LOI and then refuses the click** | `+ TEXT(Stage__c) <> "Signed"` | no — `Signed` is acquisition-only |
| 2 | 🔴 `Under Review` became **SHARED**. The approval clause repointed to it would go LIVE on disposition ⇒ **a disposition LOI at step 2 of 5 loses Advance Stage** unless `LOI_Status__c = 'Approved'`, which nothing sell-side ever writes | `RecordType.DeveloperName <> "Acquisition_LOI"` as the FIRST disjunct of that clause **only** | **YES** |
| 3 | Branch point moved `Sent` → `Submitted` | `+ TEXT(Stage__c) <> "Submitted"` | no — both acquisition-only |

**Break 1 is the THIRD occurrence of one defect** in this repo — D20/C1 (`NE 'Signed'` not
excluding `Declined`) and D22 (`<> "Completed"` not excluding `Executed`) are both already recorded
in this same field's comment. A terminal-state test written against one value set and inherited by
another. That history is now three entries long and is written into the file.

**Why the guard is scoped to one disjunction, not the top level:** this field backs **both** record
types' Advance Stage entries (that is what D22 established). A top-level record-type test would
return FALSE on every disposition LOI and delete the sell-side button outright — reintroducing the
exact 3B gap D22 closed.

**Fallback if the merge field is rejected at deploy:** substitute `NOT(ISBLANK(Disposition__c))` for
that one disjunct; nothing else changes. `RecordType.DeveloperName` has in-repo precedent that has
passed this org's check-only validation (`NDA__c.Is_Decline_Allowed__c`,
`All_NDAs_Signed_Before_Progression`).

⚠ **A Master-type row reads blank on the merge field, so the guard goes inert and the button
shows — fail-OPEN, deliberately.** §0.3(d) measured a real Master LOI, so this is a live path, not a
hypothetical. It is the right answer: `RecordStageAdvanceService`'s `defaultTypeKey` routes a Master
LOI to the acquisition sequence, and the server gate refuses anything illegitimate anyway.

**Three clauses are transitional** (`<> "Completed"`, `<> "Sent"`, the whole `Prepare/Review`
disjunction). They name the OLD values alongside the new ones, which makes the formula correct on
**both sides** of the row migration and leaves no window in either direction. They come out at
P3-D3.

### 1.6 🔴 OPEN RESIDUAL — `Submit for Approval` is no longer self-limiting, and I did NOT close it

**This departs from the build brief, which said all four acquisition visibility rules on
`LOI_Record_Page` gain a record-type criterion. Here is the reasoning; overrule it if you disagree.**

**First, what actually changed.** Only ONE of the four gates becomes shared:

| Entry | Gate | After |
|---|---|---|
| `Submit_for_Approval` | `Stage__c EQUAL Prepare/Review` | → `Under Review` 🔴 **SHARED** |
| `Mark_Countered` | `Stage__c EQUAL Sent` | → `Submitted` — acquisition-only, still self-limiting |
| `Mark_Completed` | `Stage__c EQUAL Sent` | → `Submitted` — acquisition-only, still self-limiting |
| `Advance_Stage` (acquisition) | permission + `Is_Advance_Allowed__c` | no stage criterion; the record-type question moved into the formula (§1.5) |

**Second, a record-type criterion is not directly expressible.**
`NDA__c.Is_Decline_Allowed__c`'s header states it plainly — *"A flexipage visibility rule cannot
express a record-type test directly, so the discriminator has to be a field on the record"* — and a
sweep of **every** flexipage in the repo returns **zero** `{!Record.RecordType.*}` criteria.
⚠ **That is REPO-ASSERTED AND UNMEASURED.** Nobody has tried it in this org and been refused.

**Third, the in-repo remedy has a real cost.** A new formula checkbox arrives with **no field
permissions for any profile**, and a visibility rule referencing a field the running user cannot
read evaluates **FALSE**. Adding one would make **ONE currently-working acquisition button**
newly dependent on a brand-new field's FLS — across every acquisition permission set plus any
profile-provisioned persona this repo cannot see. That is the same class of trade
`Is_Decline_Allowed__c`'s own header **refuses** to make for the acquisition Advance Stage rule.

> 🔴 **CORRECTED 2026-08-14 — this figure read "three currently-working acquisition buttons" and
> was wrong by a factor of three. Gate P3-G7 was being asked to decide on it.**
>
> The four-rule figure came from the **build brief**, which assumed all four acquisition
> visibility rules on `LOI_Record_Page` would need a record-type criterion. **§1.6's own table
> directly above overruled that** — only `Submit_for_Approval` becomes shared — and then the
> overruled number was quoted forward into this paragraph, into remedy (b), and into
> `Acquisition_LOI.recordType-meta.xml`. A discriminator would be added to **exactly one rule**:
> `Mark_Countered` and `Mark_Completed` move to `Submitted`, which is acquisition-only, so they
> stay self-limiting and need no criterion; `Advance_Stage` carries no stage criterion at all.
>
> ⚠ **THE DECISION DOES NOT CHANGE, and the smaller number must not be read as reopening it.**
> One button newly dependent on a brand-new field's FLS is still an instance of the retired
> `*_Driver__c` defect class — a rule referencing a field the user cannot read evaluates FALSE
> with no error and no log — which is exactly why that model was retired on 2026-08-12. What
> changes is that **P3-G7 is now handed the true cost**, and a decision that turns on cost cannot be
> taken against a figure inflated threefold. Correcting a number that supports your own
> recommendation is the point of recording it.

**Decision: repoint the values, record the residual.** An acquisition driver opening a *disposition*
LOI at `Under Review` will see `Submit for Approval`; clicking it targets `Opportunity.LOI_Approval`
and a disposition LOI has no `Opportunity__c`, so it **fails loudly**. This is the same residual
class the page already names and accepts for Advance Stage.

**Three remedies, if that is judged unacceptable — take the decision explicitly:**

| | Remedy | Cost |
|---|---|---|
| **(a)** | Try `{!Record.RecordType.DeveloperName} EQUAL Acquisition_LOI` as a third criterion | cheapest, and it **falsifies the repo assertion either way**. ⚠ A green deploy is NOT sufficient evidence — this page has MEASURED a construct that deploys, survives a retrieve and is then ignored by the renderer. Probe **both** directions. |
| **(b)** | Add `Is_Acquisition_LOI__c` (formula checkbox) + read FLS in the same change | proven shape, known cost, **ONE** button newly FLS-dependent (corrected from "three" — see the box above). Ship the FLS grant on every acquisition permission set in the SAME deploy as the field, or the button vanishes for everyone. |
| **(c)** | Add `{!Record.Is_Advance_Allowed__c} EQUAL false` as a third criterion | **NOT RECOMMENDED.** It happens to discriminate correctly and costs nothing, but couples this button to a formula written for a different button, so a future edit breaks it silently. Recorded because it is the cheapest and someone will find it. |

**Also recorded in the file: why the three repoints deploy at P3-D2 and not earlier.** A transitional
duplicate-entry shape (one entry per old value, one per new — the shape the two `Advance_Stage`
entries already prove works here) was **considered and rejected**: it would make `Counter` and
`Completed` visible at `Submitted` while `c/loiMarkCountered` still passes the hardcoded constant
`'Counter'`, so a driver clicking it would write a **retired value onto a migrated LOI**. A hidden
button for one maintenance window beats a visible button wired to the wrong constant.

### 1.7 🔴 C2 — the rule names BOTH terminals, which removes the window the brief implied

Requirements C2 describes a straight swap `'Completed'` → `'Signed'`. A straight swap is correct on
exactly one side of the migration and catastrophic on the other, **in both directions**: swap early
and every live LOI still reads `Completed` so the rule blocks **every** deal from entering
`Under Contract (PSA)`; swap late and every migrated LOI reads `Signed` with the same result.

The error condition is therefore `AND(<> 'Completed', <> 'Signed')` — it fires only when the LOI is
**neither** — so it is correct **before, during and after** the migration and ships in the additive
P3-D1 step. Same list-both-then-drop shape Phase 2 used on `Deal_Pipeline_by_Stage`. The
`'Completed'` leg is dropped at P3-D3.

⚠ **It is safe to deploy before `Signed` exists, and that is a property of `TEXT()`, not luck.**
`TEXT(picklist) <> 'literal'` is a string comparison and the literal is never resolved against the
value set. `ISPICKVAL` would **not** be safe — it validates its literal at deploy time. That is a
second, independent reason for the standing TEXT()-not-ISPICKVAL rule on this field.

✅ **Phase 2's edit to this same file was left intact** — verify by confirming
`ISPICKVAL(StageName, 'Under Contract (PSA)')` still reads exactly that. Phase 3's edit lands
**after** Phase 2's, as requirements §7 requires.

### 1.8 ⚠ Two quick-action LABELS were changed — BEYOND THE BRIEF, strike them if unwanted

`LOI__c.Mark_Completed` was labelled **"Completed"** and now writes `Signed`;
`LOI__c.Mark_Countered` was labelled **"Counter"** and now writes `Negotiation`. The incumbent
convention on this object is **label == target stage**, so both labels were moved to match. API
names are unchanged, exactly as Phase 2 did for `Opportunity.Advance_to_PSA`.

Zero functional risk (labels only). Listed here because the brief did not ask for it: a button
reading "Completed" that writes `Signed` is a defect, but it is one you may prefer to fix elsewhere.

### 1.9 🔴 C4b — `flows/PSA_Ready_Notify` was in NO brief and would have failed silently for ever

**Found by sweeping `flows/` for `Negotiation_Status__c`, not by following the requirements doc.**

It is an after-save record-triggered flow on `Contract_Review__c` whose ONLY entry criterion was
`Negotiation_Status__c = 'Ready for Execution'`, with **no record-type criterion** — so it has
always served both PSA record types. Observation 7 removes `Ready for Execution` from
`Acquisition_PSA`, so every acquisition PSA would pass `Negotiation → Signed → Executed` **without
ever matching this flow**. The "PSA ready for execution" notification to `Acquisitions_Team` would
stop arriving for every acquisition deal, permanently, with nothing erroring and no test failing.

**A notification that stops arriving is indistinguishable from a quiet week.** That is why this is
recorded as a find rather than a tidy-up.

**Fix: `filterLogic` `or` over `Ready for Execution` **and** `Signed`** — `Signed` being the
acquisition analogue (the step immediately before `Executed` in both sequences). A **swap** would
have moved the identical outage onto the sell-side path, which still runs on `Ready for Execution`.
Additive, correct on both sides of the migration, so it ships at **P3-D1**. The two values are
mutually exclusive per record type, so the OR cannot double-notify, and `Disposition_PSA`'s
behaviour is byte-for-byte unchanged.

**Sibling checked and deliberately NOT changed:** `flexipages/Contract_Review_Record_Page` gates both
Advance Stage entries on `Negotiation_Status__c NE 'Executed'`. **Correct as-is** — unlike LOI, the
PSA terminal did **not** move. `flows/LOI_Signed_Notify` keys on the `LOI_Signed__c` checkbox, not
on `Stage__c`. `flows/Counter_Offer_Notify` keys on `ISBLANK(LOI__r.Disposition__c)`. Neither is
affected.

### 1.10 🔴 BARE-TOKEN SWEEP of `reports/`, `dashboards/`, `listViews/` — run, and every hit opened

Phase 2 was caught by a report filter storing a multi-value picklist selection as **one comma-joined
string inside a single `<value>` element**, which every delimiter-anchored pattern walks straight
past. The sweep is therefore on the **bare token**:

```bash
node -e "
const fs=require('fs'),path=require('path');
const NAMES=['Prepare/Review','Prepare%2FReview','Sent','Counter','Completed',
             'Initial Draft','Revised','Ready for Execution'];
const TOK=NAMES.map(n=>new RegExp('(^|[^A-Za-z0-9_])'+n.replace(/[.*+?^\${}()|[\]\\\\\\/]/g,'\\\\\$&')+'([^A-Za-z0-9_]|\$)'));
(function walk(d){for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);
 if(e.isDirectory())walk(p);
 else if(/\.(report|dashboard|listView)-meta\.xml\$/.test(e.name))
  fs.readFileSync(p,'utf8').split(/\r?\n/).forEach((l,i)=>TOK.forEach((t,j)=>{
   if(t.test(l))console.log(NAMES[j]+'  '+p+':'+(i+1)+': '+l.trim());}));
}})('force-app/main/default');"
```

**Result, 2026-08-14 — ONE hit across all eight values, and it is a FALSE POSITIVE:**

```
Completed   reports/Work_Orders/Resolved_MTD.report-meta.xml:12: <value>Completed,Closed</value>
```

**Opened in full.** Its `<column>` and `groupingsDown` are both `Work_Order__c.Status__c`; its
`reportType` is `CustomEntity$Work_Order__c`. Nothing to do with `LOI__c.Stage__c`. ⚠ **Note it is
the exact comma-joined mid-string shape that caught Phase 2** — same trap, different object.

**`Prepare/Review`, `Prepare%2FReview`, `Sent`, `Counter`, `Initial Draft`, `Revised` and
`Ready for Execution` return ZERO hits.** ⚠ `Completed` and `Sent` are ACTIVE values on OTHER
objects' fields (`Underwriting__c.Stage__c`, both Feasibility Review `Stage__c` fields,
`NDA__c.Status__c` on both record types), so any future sweep must be **FIELD-scoped, never
string-scoped**.

Two more in-repo artefacts were opened and cleared:
`reports/Acquisitions/LOIs_Submitted` groups on **`LOI_Status__c`**, not `Stage__c` — unaffected
despite its name. `dashboards/Acquisitions/Acquisitions_Dashboard_Junior`'s "LOIs Submitted" metric
reads that report.

**Anything else is org-side and belongs to gate P3-G6** — this runbook's reports-and-dashboards
gate, whose own cell cites *this* sweep by name ("§1.10's sweep clears the **repo**").

> 🔴 **[CORRECTED 2026-08-14 — this line read "belongs to gate **G8**", and that was a POINTER
> DEFECT, not merely an unprefixed label. It is the only edit in the Phase 3 renumbering that
> changes which gate a sentence sends you to, so it is marked rather than folded in silently.**
>
> A bare `G8` here resolves to the wrong gate **in both spaces at once**, which is why it survived
> review:
> - read as **this runbook's** G8, it is *"confirm `LOI_Path` is not swept into a deploy"* — a
>   PathAssistant question with nothing to do with reports or dashboards;
> - read as **requirements §8's** G8, it is *"re-point any report or dashboard filtering
>   `Deal_Type__c = 'Commercial'` or `StageName = 'PSA'`"* — the right ACTIVITY but the wrong
>   FIELDS, belonging to Phases 1 and 2. It would send an operator sweeping for the two values this
>   phase does not touch, and away from `LOI__c.Stage__c` / `Contract_Review__c.Negotiation_Status__c`,
>   which are the ones §1.10 has just finished clearing in the repo.
>
> Either way the org-side half of THIS phase's sweep goes unassigned — silently, because both
> destinations are real gates that exist and read plausibly. ⚠ **This is the concrete case for the
> prefix**, not a hypothetical one: the collision had already produced a live mis-pointer in this
> document before anyone was looking for it.]
>
> ⚠ Not requirements §8's **G6** either — that is the render probe. §8's reports gate is its **G8**;
> this runbook's is **P3-G6**. They are different sweeps over different fields and neither
> substitutes for the other.

---

## 2. The disposition diff gate — a hard stop on every Phase 3 deploy

Two disposition record-type files are modified. **Both changes are comment and `<description>` text
only; neither file's `<picklistValues>` changed.** Confirm before approving any deploy:

```bash
git diff -- force-app/main/default/objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml \
             force-app/main/default/objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml \
  | grep -E '^[+-]' | grep -vE '^[+-]{3}' | grep -E '<(values|fullName|default|picklist)>'
```

Must print **nothing**. A single line here means a disposition value set moved.

⚠ Why they were touched at all: each asserted a property this phase falsifies —
`Disposition_LOI` that "no stage value appears on both record types", `Disposition_PSA` that "both
record types expose the same four values". Both are load-bearing documentation that other files
cite by name, and **neither shows anything in a values diff**, which is exactly why the retraction
had to be written into the file rather than left to a runbook.

---

## 3. Deploy sequence

Legend: **[MIG]** = an org data migration runs between this step and the next.
**[ORG-Q]** = verified by an org query, **not** by a green deploy.

### P3-D1 — additive: add every new value, and every edit that is correct on BOTH sides of the migration

```
force-app/main/default/objects/LOI__c/fields/Stage__c.field-meta.xml
force-app/main/default/objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml
force-app/main/default/objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml
force-app/main/default/objects/LOI__c/recordTypes/Disposition_LOI.recordType-meta.xml
force-app/main/default/pathAssistants/LOI_Path_Acquisition.pathAssistant-meta.xml
force-app/main/default/objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml
force-app/main/default/objects/Contract_Review__c/fields/Negotiation_Status__c.field-meta.xml
force-app/main/default/objects/Contract_Review__c/recordTypes/Acquisition_PSA.recordType-meta.xml
force-app/main/default/objects/Contract_Review__c/recordTypes/Disposition_PSA.recordType-meta.xml
force-app/main/default/pathAssistants/Contract_Review_Path_Acquisition.pathAssistant-meta.xml
force-app/main/default/flows/Contract_Review_Stage_Sync.flow-meta.xml
force-app/main/default/flows/PSA_Ready_Notify.flow-meta.xml
```

> 🔴 **DEPLOY NOTHING ELSE AT THIS STEP.** In particular do **not** let tooling pick up
> `flexipages/`, `quickActions/` or `objectTranslations/`. The tree already carries the P3-D2
> repoints, and shipping the FlexiPage here hides three acquisition buttons before the migration
> has run (§1.6).
>
> 🔴 **BOTH FLOWS BELONG HERE, NOT WITH THE APEX, AND `Contract_Review_Stage_Sync` IS THE URGENT
> ONE.** It is a **before-save** flow, so it fires on **every row the migration writes**. If it does
> not yet know `Draft`, the migration itself stamps coarse `Stage__c = 'Review'` across the whole
> live acquisition population — a data defect, not just a rendering one. Both edits are purely
> additive and correct on both sides, which is what lets them ship early.
>
> ⚠ Deploy the **field before or with** its record type — a `picklistValues` block naming a value
> the org does not have fails the deploy. One deploy containing both resolves it.

**[ORG-Q] Verify — the describe is the only real evidence** (§0.3(b): a check-only run proves the
XML parses and nothing about org state). ⚠ **If you take a validation run before this step, read
§0.3(b) and §0.3(e) first** — one block of `bad value for restricted picklist field` failures is
expected here and is an ordering artifact, and a missing `Deal_Type__c` will bury the whole run:

```bash
sf sobject describe --sobject LOI__c --target-org usman.khan.dpeg@avanzasolutions.com > loi_after.json
sf sobject describe --sobject Contract_Review__c --target-org usman.khan.dpeg@avanzasolutions.com > cr_after.json
```

| Field | Required after P3-D1 |
|---|---|
| `LOI__c.Stage__c` | **13** values, ALL ACTIVE. `restrictedPicklist` still **true**. |
| `Contract_Review__c.Negotiation_Status__c` | **7** values, ALL ACTIVE, `Initial Draft` still the field default. `restrictedPicklist` still **true**. |

⚠ **Capture the BEFORE describe too, and diff it.** Both are custom fields, so the
`StandardValueSet` replace-not-merge hazard does not apply — but the check costs nothing and the
count is the whole evidence. Required shape: exactly **+3** values on each field, **zero** removed.
A single removed value is a STOP.

**Record-type value sets — the describe cannot see these; retrieve and read them back:**
```bash
sf project retrieve start \
  --metadata "RecordType:LOI__c.Acquisition_LOI" \
  --metadata "RecordType:LOI__c.Disposition_LOI" \
  --metadata "RecordType:Contract_Review__c.Acquisition_PSA" \
  --metadata "RecordType:Contract_Review__c.Disposition_PSA" \
  --target-org usman.khan.dpeg@avanzasolutions.com \
  --target-metadata-dir <scratch> --unzip --wait 20
```
`Acquisition_LOI` must list **9** `Stage__c` values; `Acquisition_PSA` **7** `Negotiation_Status__c`
values; **both disposition files must be byte-identical to before on their `<picklistValues>`.**
⚠ An **empty** retrieve proves nothing — confirm each file is non-empty first.

---

### [MIG] — the row migration

> # 🔴 STOP — READ THE FILTER BEFORE YOU WRITE ONE
>
> **The natural filter to write is the WRONG one. Copy the right-hand column.**
>
> | ❌ WRONG — do not use | ✅ RIGHT — use this |
> |---|---|
> | `WHERE RecordType.DeveloperName = 'Acquisition_LOI'` | `WHERE RecordType.DeveloperName != 'Disposition_LOI'` |
> | `WHERE RecordType.DeveloperName = 'Acquisition_PSA'` | `WHERE RecordType.DeveloperName != 'Disposition_PSA'` |
> | `WHERE RecordTypeId = '012iw0000009yeXAAQ'` | (never filter on a hardcoded record-type Id) |
> | **any filter on the VALUE alone**, e.g. `WHERE Stage__c = 'Completed'` | — it would move the disposition rows too |
>
> **WHY, IN ONE SENTENCE: there are rows on the MASTER record type, and `= 'Acquisition_*'`
> excludes them while `!= 'Disposition_*'` includes them.**
>
> A Master row's `RecordType.DeveloperName` is **blank**. Blank is `!= 'Disposition_LOI'` — so the
> right-hand filter picks it up — and blank is **not** `= 'Acquisition_LOI'`, so the left-hand
> filter silently drops it.
>
> **WHAT THE WRONG FILTER COSTS — this is not a tidiness point:**
>
> 1. The Master LOI stays on `Completed`.
> 2. P3-D3 **deactivates** `Completed`.
> 3. `LOI__c.Stage__c` is **`restrictedPicklist: true` in the org** — MEASURED, §0.3(a) — so a
>    restricted picklist **rejects** an inactive value at DML.
> 4. ⇒ **That record can no longer be saved at all.** Any edit to any field on it fails, because
>    the save re-validates the stage it is already holding. It is recoverable only by an
>    administrator reactivating the value or hand-changing the stage first.
> 5. Its Path renders blank, and nothing anywhere errors until someone tries to save it.
>
> **This was measured, not anticipated** (§0.3(d)), and independently re-verified by the
> coordinator: two LOIs sit on `Completed`, **one of them with a NULL record type**. It is not a
> hypothetical edge case — it is one of the two rows this migration has to move.
>
> ⚠ **A Master row is acquisition-side by construction**, so moving it is correct as well as
> necessary: `Disposition_LOI` did not exist before Tranche 3B, and `Disposition_PSA` before 3C.
> The `!=` filter is therefore not a loosening — it is the accurate expression of "everything
> that is not sell-side".

🔴 **THE FILTER IS BY RECORD TYPE, NEVER BY VALUE — AND "BY RECORD TYPE" MEANS `NOT Disposition`,
NOT `= Acquisition`.** §0.3(d) measured a live LOI on the **Master** record type sitting on
`Completed`. A filter of `RecordType.DeveloperName = 'Acquisition_LOI'` misses it and strands it on
a value P3-D3 then deactivates — and because the field is genuinely restricted, that row becomes
unsaveable until a human changes its stage by hand.

**Re-measure first. Do not plan against §0.3(d)'s snapshot:**
```bash
sf data query --query "SELECT RecordTypeId, Stage__c, COUNT(Id) n FROM LOI__c GROUP BY RecordTypeId, Stage__c" \
  --target-org usman.khan.dpeg@avanzasolutions.com --json
sf data query --query "SELECT RecordTypeId, Negotiation_Status__c, COUNT(Id) n FROM Contract_Review__c GROUP BY RecordTypeId, Negotiation_Status__c" \
  --target-org usman.khan.dpeg@avanzasolutions.com --json
```
> ⚠ `sf data query` fails under Git Bash on this machine (`'C:\Program' is not recognized`). Run it
> from **PowerShell**, or via `powershell.exe -NoProfile -Command "..."`. `sf sobject describe`
> works in either shell.

**Extract first, so the change is reversible:**
```sql
SELECT Id, Stage__c, RecordTypeId FROM LOI__c
WHERE RecordType.DeveloperName != 'Disposition_LOI'
  AND Stage__c IN ('Prepare/Review','Sent','Counter','Completed')

SELECT Id, Negotiation_Status__c, RecordTypeId FROM Contract_Review__c
WHERE RecordType.DeveloperName != 'Disposition_PSA'
  AND Negotiation_Status__c IN ('Initial Draft','Revised','Ready for Execution')
```
⚠ **`!=` on `RecordType.DeveloperName` is what includes Master rows** (their `RecordTypeId` is the
object's default and `DeveloperName` is blank, which is `!= 'Disposition_LOI'`). Verify each
extract's row count against the group-by above **before** updating; if the two disagree, stop —
the filter is not selecting what you think.

**The value maps:**

| `LOI__c.Stage__c` | → | | `Contract_Review__c.Negotiation_Status__c` | → |
|---|---|---|---|---|
| `Prepare/Review` | `Under Review` | | `Initial Draft` | `Draft` |
| `Sent` | `Submitted` | | `Revised` | `Negotiation` |
| `Counter` | `Negotiation` | | `Ready for Execution` | `Signed` |
| `Completed` | `Signed` | | `Executed` | **unchanged** |

> ## 🔴 EXPECTED RESULT: THE CONTRACT REVIEW HALF UPDATES **ZERO ROWS**. THAT IS SUCCESS, NOT A FAILED STEP.
>
> Measured 2026-08-14 and independently re-verified: `Contract_Review__c` holds **six** rows —
> five with a record type, one on Master — and **not one of them holds `Initial Draft`, `Revised`
> or `Ready for Execution` on the acquisition or Master side**. The live distribution is:
>
> | Record type | Value | Rows | Migrates? |
> |---|---|---|---|
> | `Acquisition_PSA` | `Executed` | 2 | **no** — `Executed` is unchanged |
> | (MASTER) | `Executed` | 1 | **no** — same reason |
> | `Disposition_PSA` | `Initial Draft` | 3 | 🔴 **NO — these must NOT move** |
>
> **So the extract returns 0 rows and the update writes 0 rows.** An operator who sees that has
> run the step correctly. Do **not** "fix" it by widening the filter — the only rows in the org
> holding `Initial Draft` are the three sell-side ones, and a value-scoped migration would move
> **exactly the wrong three records**, silently rewriting `Disposition_PSA`'s live sequence into
> acquisition vocabulary.
>
> ⚠ **Run the extract anyway.** The population changes, and a future run may have real rows. The
> zero is today's answer, not the step's definition.
>
> ⚠ **Contrast the LOI half, which is NOT a no-op:** two rows move (`Completed → Signed`), and one
> of the two is the Master row the filter box above exists for.

🔴 **As measured on 2026-08-14 the Contract Review migration is a NO-OP: ZERO acquisition or Master
rows hold any of the three retiring values.** The only rows holding `Initial Draft` are the **three
`Disposition_PSA`** rows, which must **not** move. That is the brief's warning confirmed against a
real population: a value-scoped migration would have moved exactly the wrong three records.

**Run it as an administrator.** `Contract_Review__c` is reachable from Opportunity approvals whose
`recordEditability` is `AdminOnly`.

**⚠ AUTOMATION THAT FIRES ON THIS UPDATE — checked from the files, not assumed:**

| Automation | Fires? | Effect |
|---|---|---|
| `Contract_Review_Stage_Sync` (before-save, `CreateAndUpdate`) | **YES, on every migrated row** | Re-derives coarse `Stage__c`. **Correct only because C4 shipped at P3-D1** — this is the reason for that ordering. |
| `PSA_Ready_Notify` (after-save) | 🔴 **NO — not on `Ready for Execution → Signed`.** See the box below. | It fires only on a row that did **not** meet the criteria before the update and does after. |
| `Completed_LOI_Before_PSA` | **NO** | `ISCHANGED(StageName)`-scoped, on **Opportunity**. The migration writes LOI and Contract Review rows, never `StageName`. |
| `Counter_Offer_Notify` | NO | triggers on `Counter_Offer__c` insert only |
| `LOI_Signed_Notify` | NO | keys on the `LOI_Signed__c` checkbox |
| `ContractExecutionService` | NO | keys on `Executed`, which no row migrates **to** |

> ## 🔴 CORRECTED 2026-08-14 — DO NOT PRE-ANNOUNCE A NOTIFICATION. `PSA_Ready_Notify` DOES **NOT** FIRE ON THE `Ready for Execution → Signed` MIGRATION.
>
> This table predicted the **opposite** of what will happen, and the guidance it carried
> ("re-notifies once … say so beforehand") would have made the notification's **absence** read as
> "did the OR widening break the flow?" — sending an operator to debug a flow that is working
> exactly as designed.
>
> **The mechanism, read off the file rather than assumed.**
> `flows/PSA_Ready_Notify` now has `<filterLogic>or</filterLogic>` over **both** values, and
> `<doesRequireRecordChangedToMeetCriteria>true</doesRequireRecordChangedToMeetCriteria>`. That
> flag means *fire only when the record did NOT meet the entry criteria before this save and does
> after*. A row on `Ready for Execution` **already satisfied the OR**, and after the migration it
> satisfies it via the other disjunct. Met-before **and** met-after ⇒ **no fire**.
>
> | Transition | Met criteria before? | After? | Fires? |
> |---|---|---|---|
> | `Ready for Execution → Signed` (the migration) | **yes** | yes | 🔴 **NO** |
> | `Revised → Signed` (a real acquisition advance) | no | yes | ✅ yes |
> | `Negotiation → Signed` (post-D3 acquisition advance) | no | yes | ✅ yes |
> | `Initial Draft → Ready for Execution` (disposition) | no | yes | ✅ yes |
>
> **THE GENERAL RULE, which is the transferable part:** *widening entry criteria to an OR makes
> transitions **inside** the new set stop firing; it never makes them double-fire.* The intuition
> that an OR "matches more, so it notifies more" is right about the *set* and backwards about the
> *transitions*, because `doesRequireRecordChangedToMeetCriteria` keys on the **boundary**, not on
> membership. Widening the set moves the boundary **outward**, so every hop that used to cross it
> and now sits wholly inside it goes silent. Apply this to any future OR-widening of a flow entry
> criterion in this repo.
>
> ⚠ **The flow is correct and needs no change** — this is a defect in the runbook's prediction
> only. §1.9's reason for the OR (a swap would move the outage onto the sell-side path) is
> unaffected, and gate **P3-G4** still stands: it verifies the two ✅ rows above, which are the
> transitions the feature actually exists for.
>
> ⚠ **This is moot today anyway, and the arithmetic says so twice.** The expected-result box above
> measured **zero** acquisition or Master rows holding any of the three retiring values, so no row
> makes this transition on 2026-08-14 at all. The correction is recorded because the population
> changes and a future run may have real rows — and because the *reasoning* would otherwise be
> carried into the next OR-widening.

**[ORG-Q] Verify — the first two must be 0 and the second pair must account for every row:**
```sql
SELECT COUNT() FROM LOI__c WHERE RecordType.DeveloperName != 'Disposition_LOI'
  AND Stage__c IN ('Prepare/Review','Sent','Counter','Completed')
SELECT COUNT() FROM Contract_Review__c WHERE RecordType.DeveloperName != 'Disposition_PSA'
  AND Negotiation_Status__c IN ('Initial Draft','Revised','Ready for Execution')
```
Then confirm the rows ARRIVED rather than vanishing, and that **the disposition rows did not move**:
```sql
SELECT RecordTypeId, Stage__c, COUNT(Id) FROM LOI__c GROUP BY RecordTypeId, Stage__c
SELECT RecordTypeId, Negotiation_Status__c, COUNT(Id) FROM Contract_Review__c
  GROUP BY RecordTypeId, Negotiation_Status__c
```
A zero on the first pair alone is **also** what a migration that DELETED rows would produce. The
`Disposition_LOI` and `Disposition_PSA` lines must be identical to the pre-migration read.

⚠ **The Contract Review zero proves nothing on its own — it was already zero before the step ran**
(see the expected-result box above). For that half, the evidence is the **group-by**: three rows
still on `Disposition_PSA` / `Initial Draft`, unmoved. If that line reads anything else, a
value-scoped filter was used and the sell-side sequence has been rewritten.

---

### P3-D2 — repoint every reference that MOVES

```
force-app/main/default/flexipages/LOI_Record_Page.flexipage-meta.xml
force-app/main/default/quickActions/LOI__c.Mark_Completed.quickAction-meta.xml
force-app/main/default/quickActions/LOI__c.Mark_Countered.quickAction-meta.xml
```
Plus the **developer agent's** Apex and LWC repoints, **in the same deploy** — see §6.

> 🔴 **THE FLEXIPAGE AND THE LWC CONSTANTS MUST TRAVEL TOGETHER.** The page makes `Counter` and
> `Completed` visible at `Submitted`; `c/loiMarkCountered` and `c/loiMarkCompleted` carry the
> hardcoded target constants. Ship the page without the bundles and a driver writes a **retired
> value onto a migrated LOI**. Ship the bundles without the page and the buttons never appear.
>
> ⚠ **Window:** between `[MIG]` and this deploy, `Submit for Approval`, `Counter` and `Completed`
> are **hidden** on every acquisition LOI. That is deliberate (§1.6) and is why `[MIG]` and P3-D2
> must share ONE maintenance window, exactly as Phase 2 required.
>
> ⚠ **Read the FlexiPage back after deploying it.** A FlexiPage deploy can roll back with a
> design-time error and still report success. Retrieve and diff — a green deploy is not evidence.
>
> ⚠ **Do NOT enable Dynamic Actions.** It is already `true` on this page; turning it on where it is
> off silently empties that page's action bar.

**[ORG-Q] Verify the criteria actually moved:**
```bash
sf project retrieve start --metadata "FlexiPage:LOI_Record_Page" \
  --target-org usman.khan.dpeg@avanzasolutions.com --target-metadata-dir <scratch> --unzip --wait 20
```
In the retrieved file: `<rightValue>Under Review</rightValue>` appears **once**,
`<rightValue>Submitted</rightValue>` **twice**, and `Prepare/Review` / `Sent` **zero** times.

**Functional smoke, as a real acquisition deal driver (not an admin — the admin bypass makes an
admin smoke test worthless):** take an LOI through `Draft → Under Review`, confirm **Submit for
Approval** appears and **Advance Stage** does **not** until the LOI reads `Approved`; approve;
advance to `Submitted`; confirm **Negotiation** and **Signed** both appear; take one to `Signed` and
confirm **Advance Stage disappears** (that is break 1 of §1.5, and it is the assertion no test can
make).

---

### P3-D3 — retire

🔴 **PRECONDITION, RE-RUN IMMEDIATELY BEFORE EXECUTING — not trusted from the migration:**
```sql
SELECT COUNT() FROM LOI__c WHERE Stage__c IN ('Prepare/Review','Sent','Counter','Completed')
```
Must be **0 at this moment**. It was 0 after the migration and can have drifted back: until the
P3-D2 Apex lands, `RecordStageAdvanceService`'s acquisition map still derives the OLD values, so
Advance Stage keeps minting rows on them. ⚠ Note this query is deliberately **not**
record-type-scoped — after the migration *no* record type should hold these values at all.

Apply the staged package:
```bash
node agent-output/p3-d3-retire-loi-psa/apply-d3.js --check   # validates, writes nothing
node agent-output/p3-d3-retire-loi-psa/apply-d3.js           # writes, all-or-nothing
```

**What it does — 13 edits across 7 files:** deactivates the four retired values on
`LOI__c.Stage__c`; removes them from `Acquisition_LOI` and from `LOI_Path_Acquisition` (9 steps → 5);
drops the transitional `'Completed'` leg from `Completed_LOI_Before_PSA`; drops the three
transitional clauses from `Is_Advance_Allowed__c`; removes the three retiring values from
`Acquisition_PSA` and promotes `Draft` to its record-type default; removes the three retiring steps
from `Contract_Review_Path_Acquisition` (7 → 4).

🔴 **It touches `Negotiation_Status__c` NOT AT ALL, and asserts that nobody else has either.**

**The package's assertions were FALSIFIED, not merely written** —
`node agent-output/p3-d3-retire-loi-psa/falsify.js` builds ten deliberately mutated copies of the
tree, runs the real script against each in an isolated temp directory, and requires that every one
exits non-zero **and leaves every file byte-identical**, plus a positive control on a clean tree.
Result 2026-08-14: **10/10 caught, nothing written, positive control applies 7 files cleanly.** The
mutations include the O3 violation (M6) and the missing record-type guard (M4). Re-run it if the
tree changes; an assertion never seen to go red is an unverified claim.

Then deploy:
```
force-app/main/default/objects/LOI__c/fields/Stage__c.field-meta.xml
force-app/main/default/objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml
force-app/main/default/objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml
force-app/main/default/pathAssistants/LOI_Path_Acquisition.pathAssistant-meta.xml
force-app/main/default/objects/Opportunity/validationRules/Completed_LOI_Before_PSA.validationRule-meta.xml
force-app/main/default/objects/Contract_Review__c/recordTypes/Acquisition_PSA.recordType-meta.xml
force-app/main/default/pathAssistants/Contract_Review_Path_Acquisition.pathAssistant-meta.xml
```

⚠ **`<isActive>false</isActive>` ordering is `<fullName>` → `<default>` → `<isActive>` → `<label>`**,
taken from `objects/Contract_Review__c/fields/Stage__c.field-meta.xml`, which carries three
deactivated values in exactly that shape. Unlike Phase 2's `StandardValue` case this is a
**`CustomValue` precedent on a custom field**, so it is not an extrapolation.

⚠ **Nothing is DELETED** (decision O3). An inactive value keeps every historical row, report filter
and Path reference resolvable; a deleted one breaks reports and dashboards silently. Deletion is a
separately-scoped follow-up with its own preconditions.

**[ORG-Q] Verify:**
```bash
sf sobject describe --sobject LOI__c --target-org usman.khan.dpeg@avanzasolutions.com
sf sobject describe --sobject Contract_Review__c --target-org usman.khan.dpeg@avanzasolutions.com
```

| Check | Required |
|---|---|
| `LOI__c.Stage__c` | 13 values; `Prepare/Review`, `Sent`, `Counter`, `Completed` **inactive or absent — record which**; the other 9 ACTIVE |
| 🔴 `Contract_Review__c.Negotiation_Status__c` | **7 values, ALL SEVEN STILL ACTIVE.** A single inactive value here is an O3 violation. |
| `Acquisition_PSA` (retrieve) | exactly 4 `Negotiation_Status__c` values, `Draft` default |
| `Disposition_PSA` (retrieve) | **unchanged** — 4 values, `Initial Draft` default |

**Then re-verify the restriction actually bites** — this is the payoff of §0.3(a) and it is the only
check that proves the retirement is a control rather than a cosmetic:
⚠ **The `SELECT` below is a PROBE-ROW PICKER, not a migration filter — do not copy its `WHERE`
clause into the `[MIG]` step.** Here `= 'Acquisition_LOI'` is correct and deliberate: the probe
wants one genuine acquisition row to attempt a write against. The migration wants *every row that
is not sell-side*, which is a different question with a different answer
(`!= 'Disposition_LOI'`). This is the only remaining `= 'Acquisition_*'` in this runbook outside
the wrong-vs-right box, and it is flagged so it cannot be mistaken for a fourth copy of the filter.

```
// anonymous Apex, on a scratch/dev copy first
LOI__c l = [SELECT Id FROM LOI__c WHERE RecordType.DeveloperName = 'Acquisition_LOI' LIMIT 1];
l.Stage__c = 'Completed';
try { update l; System.debug('🔴 STORED — the value is NOT restricted'); }
catch (Exception e) { System.debug('✅ REJECTED: ' + e.getMessage()); }
```

**Prose touch-ups the script deliberately does NOT make** (structural edits are scripted; prose is
not, so a drift cannot half-apply a sentence). After running it, update: `Is_Advance_Allowed__c`'s
`<description>` (drop the "Completed, Sent and Prepare/Review are named alongside their
replacements" sentence), `Completed_LOI_Before_PSA`'s `<description>` (drop "or the retired
Completed"), and the "transitional" notes in both pathAssistant comments and both acquisition
record-type comments.

---

## 4. Post-deploy gates — org state, not deployable, each fails silently

🔴 **These labels are `P3-Gn`, and they are NOT interchangeable with requirements §8's `Gn`.** The
two spaces agree at **no number at all** — G1, G3 and G6 in particular mean three different things
in each document. Cross-reference by document, never by bare number; the full mapping, and what
happens if you do not, is in the label box at the top of this runbook.

| # | Gate | If missed |
|---|---|---|
| **P3-G1** | 🔴 **Complete Tranche 3B/3C's UNFINISHED row migration onto the record types.** §0.3(d) measured 1 LOI and 1 Contract Review still on **Master**. This phase's `[MIG]` filter is written to include them, so Phase 3 is safe — but a Master LOI renders **no Path at all** (a Path is per record type) and reads blank on `RecordType.DeveloperName`, so §1.5's guard goes inert on it. | Rows with no Path, and a fail-open Advance Stage button. Nothing errors. |
| **P3-G2** | **Record-type assignment + per-profile DEFAULT** for `Acquisition_LOI` / `Acquisition_PSA`. `PermissionSet.recordTypeVisibilities` has **no `<default>` element** and `profiles/**` is `.forceignore`d, so only a Profile can name a default and it never deploys. | New LOIs/Contract Reviews land on Master, re-creating P3-G1 continuously. |
| **P3-G3** | 🔴 **Render probe on `LOI_Record_Page`, BOTH directions, as a real non-admin persona.** Acquisition driver on an acquisition LOI at `Under Review` → **Submit for Approval visible**; at `Signed` → **Advance Stage NOT visible**; disposition driver on a disposition LOI at `Under Review` → **Advance Stage VISIBLE** (that is §1.5 break 2, the sell-side outage this phase averts). **The non-visible halves are the ones that falsify.** | A visibility rule can deploy, survive a retrieve and be **ignored by the renderer** — measured in this repo. No Apex test, Jest test or file check sees it. |
| **P3-G4** | **Confirm `PSA_Ready_Notify` still fires**, on BOTH record types: an acquisition PSA reaching `Signed` and a disposition PSA reaching `Ready for Execution` must each notify `Acquisitions_Team`. | §1.9's outage, undetected. A notification that stops arriving looks like a quiet week. |
| **P3-G5** | **Confirm the coarse `Stage__c` projection.** A brand-new acquisition PSA on `Draft` must show `Stage__c = 'PSA Drafting'`, **not** `Review`. | C4's defect, shipped green. `Stage__c` is derived, so a direct write commits and is silently discarded — there is no manual workaround. |
| **P3-G6** | **Re-point org-side reports and dashboards** filtering `LOI__c.Stage__c` or `Contract_Review__c.Negotiation_Status__c`. §1.10's sweep clears the **repo**; org-side artefacts are not fully represented here. | They break **silently** — they reference by name and do not block the change. |
| **P3-G7** | **Decide §1.6's open residual** — accept it, or pick remedy (a)/(b)/(c). 🔴 **Decide on the CORRECTED cost: remedy (b) makes ONE button newly FLS-dependent, not three.** That figure was inflated threefold until 2026-08-14 (it came from the build brief, which §1.6 had already overruled), and it is the whole basis on which (b) was set aside — so re-read §1.6's correction box before choosing. Remedy (a) also **falsifies the repo's unmeasured claim** that a flexipage rule cannot express a record-type test. ⚠ Scope the residual correctly when judging it: the exposed population is a user holding the **`Acquisition_Deal_Actions`** custom permission, so a pure sell-side driver sees nothing. | An acquisition driver sees Submit for Approval on a disposition LOI. Fails loudly, so it is a UX defect rather than a hole — which is why it needs a decision rather than a test. |
| **P3-G8** | **Confirm `LOI_Path` (the deactivated master Path) is not swept into a deploy.** It still lists the four retired values. Whether a `PathAssistant` referencing an **inactive** value deploys is **UNVERIFIED in this org**. | A future full-directory deploy fails on a file nobody is thinking about. If it is rejected, move its five `<info>` texts into its XML comment and empty its steps — it exists only as the record of that prose. |

---

## 5. Rollback

| Step | Reversible? | How |
|---|---|---|
| P3-D1 | yes | Wholly additive. Remove the new values and re-deploy; nothing holds them yet. |
| **[MIG]** | **only from the CSVs** | Re-upsert the extracts. **Take them.** After P3-D3 this is unrecoverable for the LOI half — the target values are inactive and the field is genuinely restricted, so the old values cannot be written back without reactivating them first. |
| P3-D2 | yes | Revert the commit; re-deploy the FlexiPage and both quick actions. Must revert **with** the Apex/LWC. |
| P3-D3 | **partially** | Reactivating a picklist value is a deploy, so the LOI half is recoverable. Re-adding the three values to `Acquisition_PSA` is likewise a deploy. **But nothing restores row values** — a row migrated `Completed → Signed` stays `Signed`. |

---

## 6. Handoffs — what this build did NOT do

| Item | Owner |
|---|---|
| ✅ **DELIVERED 2026-08-14 — DO NOT RE-RAISE.** `RecordStageAdvanceService`: `LOI_ACQUISITION_NEXT_STAGE`, `LOI_ACQUISITION_EXPLICIT_TARGETS`, and **C9 — the `CONTRACT_REVIEW_NEXT_STAGE` split**. Verified in `classes/RecordStageAdvanceService.cls`: `CONTRACT_REVIEW_ACQUISITION_NEXT_STAGE` (723) and `CONTRACT_REVIEW_DISPOSITION_NEXT_STAGE` (749), each wired to its own gate (1157/1159), rename documented (646). Falsifier: `RecordStageAdvanceServiceTest.psaSequencesAreSplitPerRecordType`, which asserts **both** directions in one test so a reverted single-map build cannot satisfy it. 🔴 **This row read "must be SPLIT" until 2026-08-14 and was re-reported as outstanding by a reviewer who took `Contract_Review_Record_Page`'s PRE-SPLIT comment as current** — a phantom open item generated by stale prose. That flexipage comment is now marked inline. **Verify any Apex name a comment mentions against the class before repeating it.** | 🟢 `salesforce-developer` — done |
| `c/loiMarkCountered` / `c/loiMarkCompleted`: hardcoded constants → `Negotiation` / `Signed`. **Changed in the bundle, never computed** — the server validates them against a record-type-scoped allow-list and that is the security-relevant half. **Must ship in the same deploy as the FlexiPage** (§3 P3-D2). | 🟢 `salesforce-developer` |
| 🔴 **C3 — `OpportunityReviewService` must stamp `Negotiation_Status__c = 'Draft'` EXPLICITLY, describe-guarded.** It stamps nothing today and takes the FIELD default (`Initial Draft`), which after P3-D3 is not on `Acquisition_PSA`. Apex DML does **not** enforce record-type picklist restriction, so it commits **silently**, the Path renders blank and the stage map has no entry. **The P3-D3 record-type default flip does NOT fix this** — a record-type default does not apply to Apex DML. Do **not** fix it by moving the field default; `Disposition_PSA` needs it. | 🟢 `salesforce-developer` |
| `RecordStageAdvanceControllerTest.cls:75` asserts `'Prepare/Review'`. Fails **loudly** after the migration. | 🟢 `salesforce-developer` |
| Regression: `CounterOfferServiceTest`, `PsaVersionServiceTest` (one design applied to two objects; both derive `Ball_In_Court__c` from the parent's record type and the PSA value set moves under them), plus `RecordStageAdvanceServiceTest`, `OpportunityReviewServiceTest`, `ContractExecutionServiceTest`. | 🟢 `salesforce-developer` |
| Deploying anything; the `[MIG]`; every `[ORG-Q]`; scheduling nothing (this phase adds no jobs). | 🔴 `salesforce-devops` |
| **Verified false positives — DO NOT CHANGE.** `LeaseInquiryController.cls:21` and `lwc/leaseStatusSummary` reference `'Prepare/Review'` / `'Completed'` on **`Lease_Inquiry__c` / `Lease__c`**, unrelated objects with their own value sets. `objectTranslations/Lease__c-en_US/Stage__c` likewise. | — |

---

## 7. Rule-gate record (`.claude/rules/salesforce-global-rule.md`)

```
intent=type | best_matched_skill=sf-metadata | skill_selection=complete
```

| Metadata type | Skill loaded | `salesforce-api-context` MCP |
|---|---|---|
| `CustomField` (picklist) | `sf-custom-field` | `mcp=unavailable`, `mcp_tools=none` |
| `CustomField` (formula) | `sf-custom-field` | `mcp=unavailable`, `mcp_tools=none` |
| `RecordType` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |
| `ValidationRule` | `sf-validation-rule` | `mcp=unavailable`, `mcp_tools=none` |
| `PathAssistant` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |
| `FlexiPage` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |
| `QuickAction` | `sf-metadata` | `mcp=unavailable`, `mcp_tools=none` |
| `Flow` | `sf-flow` | `mcp=unavailable`, `mcp_tools=none` |

The `salesforce-api-context` MCP server exposes no tools in this environment — none of
`get_metadata_type_sections`, `get_metadata_type_context`, `get_metadata_type_fields`,
`get_metadata_type_fields_properties` or `search_metadata_types` is available to call.
`ARCHITECTURE.md` §3.4 records the same unavailability, as do the Phase 1 and Phase 2 runbooks.
Every file was therefore generated from the loaded skill plus **in-repo deployed precedent**, which
was the stronger source for the four questions that actually mattered: `Prepare%2FReview` encoding
(RecordType only, literal everywhere else), `<isActive>` element ordering
(`Contract_Review__c/fields/Stage__c`), `RecordType.DeveloperName` in a formula
(`NDA__c.Is_Decline_Allowed__c`), and the 255-character `RecordType.description` cap. ⚠ That last
item was written as "the 255-character `<description>` cap" and is corrected here: the cap is a
property of the OWNING element, not of `<description>`, and on `CustomField` it is **1000**. §7.1
carries the table and the miss that conflation produced.

### 7.1 🔴 The caps — CORRECTED 2026-08-14. The previous claim was false and is the reason nobody re-checked.

> **RETRACTED, verbatim:** *"Four breached 255 on the first pass and were rewritten … **All are now
> ≤ 255.**"*
>
> **That last sentence was wrong.** `objects/LOI__c/fields/Is_Advance_Allowed__c.field-meta.xml`
> shipped with an `<inlineHelpText>` of **258** against a 255 cap. It was the **only** over-cap
> element in the entire changed set, and it was recorded as fixed while it was not. **A Metadata
> API deploy is atomic**, so that one element would have failed the whole P3-D1 payload — including
> the `Stage__c` and `Negotiation_Status__c` values that `[MIG]`, P3-D2 and P3-D3 all depend on.
>
> ⚠ **The claim of measurement is what did the damage, not the miss.** A stated "all measured, all
> within limits" is exactly the sentence a reviewer stops at. If a measurement cannot be re-run
> from what is written down, do not assert its result.

**Fixed.** `Is_Advance_Allowed__c` `<inlineHelpText>` is now **241 / 255**, with 14 characters of
headroom rather than the zero a minimal 3-character trim would have left. Two cuts: the leading
`"System field. "` (which also makes it open like `Stage__c.inlineHelpText` on the same object), and
`"(Signed or Executed)"` → `"(Signed/Executed)"`. Meaning is unchanged — it still states when the
Advance Stage button is available on each record type. The field's own comment records this so the
prefix is not restored.

**Re-measured across the whole changed set — the result, not a claim:**

| | |
|---|---|
| Files parsed | **17** (the 15 in §1.1/§1.2, plus `LOI_Path_Disposition` and `DPEG_Disposition_Edit`, both touched by the W-2 correction) |
| Capped/text elements measured | **79** |
| **Cap breaches** | **0** |
| Over 255 but **not** 255-capped | 2 `PathAssistant` `<info>` (reported, not breaches — see below) |

**HOW it was measured — reproduce it exactly, because two things silently corrupt this check:**

1. **A parser, not a grep.** `System.Xml.XmlDocument.Load(path)` respects the file's encoding
   declaration. A `Get-Content -Raw` / regex read mangles the non-ASCII characters (`⚠`, `🔴`, `—`)
   these files are full of, so the lengths come out wrong.
2. **Measure the DECODED string.** The cap applies to the value Salesforce stores, not the bytes on
   disk. `&apos;` is **6** characters in the file and **1** against the cap, so a raw-text measure
   over-counts and a stored-value measure is the only correct one. (`Completed_LOI_Before_PSA` is
   entity-heavy and is exactly where this diverges.)

**🔴 THE CAPS DIFFER BY OWNING TYPE AND ARE EASY TO CONFLATE — this is what the miss was made of.**
`<description>` sits directly above `<inlineHelpText>` in a field file and their caps differ by a
factor of four:

| Element | Cap | Note |
|---|---|---|
| `CustomField.description` | **1000** | not 255 — the roomy one |
| `CustomField.inlineHelpText` | **255** | 🔴 the one that was breached |
| `RecordType.description` | **255** | breached earlier in this phase, caught, fixed |
| `ValidationRule.description` | **255** | |
| `ValidationRule.errorMessage` | **255** | |
| `PathAssistant.<info>` | **NOT 255-capped** | see below |

⚠ **`PathAssistant` `<info>` is NOT capped at 255**, and the evidence is an incumbent deployed
value: `Contract_Review_Path_Acquisition`'s `Revised` step carries **286**. ⚠ **This phase now
RELIES on that property rather than merely observing it** — its own new `Negotiation` step is
**278** characters. 278 < 286, so the incumbent covers it. 🔴 **But P3-D3 CUTS the `Revised` step**,
after which the repo's longest surviving `<info>` is that new 278-character one and the 286-character
evidence is gone from the tree. If `<info>` ever needs re-establishing, this paragraph is the record.

⚠ **A green local parse is not a green deploy.** These caps are enforced server-side; parsing only
proves the XML is well-formed. What it *does* prove is the class of defect that bit this phase twice
in one day — see §7.2.

### 7.2 ⚠ `--` inside a comment body — hit twice on 2026-08-14, in this pack

An XML comment cannot contain two consecutive hyphens. Both occurrences were caught by a parser and
neither by review:

1. a manifest comment quoting a destructive-changes CLI flag;
2. the paragraph in `Is_Advance_Allowed__c` **explaining the over-cap fix** — the prose about a
   deploy defect introduced a deploy defect.

**The rule: never paste a CLI flag verbatim into an XML comment.** Name the command and describe the
flag. Use a single hyphen, a semicolon, or a reword. All 17 files were re-parsed after every edit in
this pass; the current tree parses clean.

### 7.3 Re-run both checks before the P3-D1 deploy — they are cheap and neither is implied by a green build

Both are pure reads and neither touches the org:

- **Parse** every file in the P3-D1 payload with `System.Xml.XmlDocument.Load()`. Catches `--` in a
  comment body, a comment sitting above the root element, and any malformed edit. This is the check
  that would have caught both §7.2 occurrences at the moment they were written.
- **Cap-sweep** the same payload, resolving each `<description>`'s cap from its **owning element**
  (§7.1's table) and measuring the **decoded** value. This is the check that would have caught the
  258.

⚠ **Re-run them after ANY prose edit, including one that only touches a comment.** Both defects this
pass fixed were introduced by comment-only edits to files that had already been reviewed — which is
precisely the category a reviewer skips.
