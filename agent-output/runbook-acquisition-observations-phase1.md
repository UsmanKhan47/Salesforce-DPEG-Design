# Deploy Runbook — Acquisition Observations, Phase 1 (declarative)

**Author:** salesforce-solution-architect · **Date:** 2026-08-14
**Target org:** `usman-dpeg` (`usman.khan.dpeg@avanzasolutions.com`, `00Diw000000Fqw1EAC`)
**Source:** `docs/superpowers/specs/2026-08-14-acquisition-app-observations-design.md` §2,
`agent-output/design-requirements-acquisition-observations.md` §3 / §5 / §6.1 / §7 / §8 / §9 C12–C13

**NOTHING IN THIS PACK HAS BEEN DEPLOYED.** Every step below is pending.

This document exists so DevOps can execute D2, D3 and D4 without re-deriving anything. Where a
step needs a file that does not exist yet (the D4 destructive package), the exact contents are
given inline — build them at that step, not before.

---

## 0. Amendments applied to the source design — read first

| # | Amendment | Effect here |
|---|---|---|
| 1 | Extraction-score denominator is **NINE** deal-process keys, signed off. `property_name`, `property_address`, `guidance_price`, `guidance_cap_rate`, `offer_due_date`, `sale_process`, `listing_broker_name`, `listing_broker_email`, `listing_status`. The six physical keys are excluded. | Affects the **developer** half. Recorded here because the field descriptions state it, so a later change to the denominator must update `objects/Lead/fields/Extraction_Score_Pct__c.field-meta.xml` too. |
| 2 | Observation 4 (`Underwriting__c.Stage__c = 'Rejected'`) is **WITHDRAWN**. | Nothing added. Do not reintroduce. |
| 3 | Do not deploy from this build. | Metadata only. |

### 0.1 Second-pass amendments — 2026-08-14, later the same day

This runbook was extended after the first build stalled. **Four things changed; nothing above was
undone.** Read these before executing any step, because two of them change what a step deploys.

| # | Amendment | Effect here |
|---|---|---|
| 4 | 🔴 **USER DECISION — the new Lead validation rule DROPS its Property Address leg.** It now enforces **Deal Type and Listing Status only**. The incumbent `Property_And_Email_Required_To_Progress` already blocks `Under Review` on a blank address, and two rules firing produced two error messages for one missing field. The incumbent was **not** touched. | §6 rewritten. The rule file's `<errorConditionFormula>`, `<description>`, `<errorMessage>` and XML comment all changed. **A residual is now open — see §6.** |
| 5 | 🔴 **`DPEG_Admin_Access` gains the eight new `fieldPermissions`.** Measured by the Apex build: without them **33 of 36 `EmailToLeadServiceTest` methods fail** the P1-A deploy's own test run. This is a **deploy blocker**, not a persona-visibility nicety. | **P1-A's deploy list grew by one file** and its verification expects **32** `FieldPermissions` rows, not 24. See §3 P1-A. |
| 6 | **D3's declarative half is APPLIED IN THE TREE**; the **D4 package now EXISTS on disk**. | `Opportunity_Record_Page`'s two `Deal_Type__c` criteria now read `Retail` — see §3 P1-D3 for the deploy-timing constraint this creates. D4 is `agent-output/p1-d4-retire-commercial/` — see §3 P1-D4. |
| 8 | 🔴 **USER DECISION — the `OUTCOME_NO_ADDRESS` residual opened by amendment 4 is CLOSED.** The incumbent `Property_And_Email_Required_To_Progress` had its **`<errorMessage>` extended** to explain that some leads legitimately arrive with no property address and that supplying one is the intended action. **Its formula, name and every other element are untouched** — verified by diff. | **P1-A's deploy list grew by one file** (the incumbent rule). §6 marks the residual closed and records the 250/255 count. No migration, no org query. |
| 7 | **Correction to the source spec.** Spec §2.6 D1 says to add `Retail` to `Deal_Type__c` on `Lead`, `Opportunity` **and `Contract_Review__c`**. The third is **wrong and unbuildable**: `Contract_Review__c.Deal_Type__c` is a **formula Text** field (`TEXT(Opportunity__r.Deal_Type__c)`), as are the `Construction_` and `Development_Feasibility_Review__c` twins. Formula fields have no value set. | Nothing to do at D1 or D4. All three start returning `Retail` on their own after **[MIG]**. Verified 2026-08-14 by opening all five `Deal_Type__c` files in the repo. |

### 0.2 Re-review pass — 2026-08-14, third pass

One critical metadata gap and three documentation drifts. **Nothing above was undone; no scope was
added.** Everything else in Phase 1 passed the re-review with zero regressions.

| # | Change | Where |
|---|---|---|
| 9 | 🔴 **C4 — `Listing_Status__c` was not enumerated on EITHER Lead record type.** The third route to the outage review C1 closes; both affected files are in the P1-A/P1-D1 deploy lists. **Fixed additively on both.** The rule it acts on is repo-**asserted**, not measured — recorded as such, with a falsification procedure. | §1, new "C4" section. Files: `objects/Lead/recordTypes/{Acquisition_Broker,IR_Investor}.recordType-meta.xml` |
| 10 | **Drift — gate G3's consequence was understated.** "The persona sees blanks" was true only while the new fields were score displays. A missing FLS grant on `Listing_Status__c` **blocks the analyst**: field does not render, validation rule fires anyway. Untestable by construction. | §4 G3 + new "G3 expanded" |
| 11 | **Drift — §7 and P1-D2 said the `Commercial`→`Retail` Apex was "handed back / not in this build". It is APPLIED in the tree.** Reconciled against disk, per item, with line numbers. **Plus a new failure-scope warning:** `RunLocalTests` fails in the HUNDREDS until P1-D1 deploys, not the 4 scoped to `EmailToLeadServiceTest`. | §3 P1-D2 (rewritten), §7 (bullet 1 struck) |
| 12 | **Drift — the D4 README's Contents table still described `package.xml` as "Empty companion manifest".** Pre-W4 wording, contradicting that file's own D4b section. An operator could have "restored" the empty manifest and reinstated W4 on the **irreversible** pass. Also added `<version>67.0</version>` to `destructiveChangesPost.xml` (optional, cosmetic). | `agent-output/p1-d4-retire-commercial/README.md`, `destructiveChangesPost.xml` |

### 0.3 Re-review pass 3 — 2026-08-14. **APPROVED WITH WARNINGS. Documentation only; zero metadata changed.**

C4 verified fixed, all three drifts closed, zero regressions. Four documentation items, **and one
of them retracts a generalisation this runbook itself made.**

| # | Change | Where |
|---|---|---|
| 13 | 🔴 **G3 widened from one field to EVERY field the rule tests.** The rule blocks on `Deal_Type__c` **OR** `Listing_Status__c`; `Deal_Type__c` is granted only by `DPEG_Acquisition_Edit` / `_View`, so **the analyst persona must hold `DPEG_Acquisition_Edit`** and **`Broker_Protection_Access` is NOT sufficient on its own for a human**. `Lead.Deal_Type__c` added to the P1-A verification as a second query. | §4 "G3 expanded", §3 P1-A |
| 14 | 🔴 **Finding C — a generalisation made by this runbook is FALSIFIED.** `applyPropertyBlock` writes `Asset_Type__c` and `Deal_Type__c` (lines 397–398) with **no** `Broker_Protection_Access` grant, and production works ⇒ "assignment ⇒ FLS enforcement throws" does not hold generally. Amendment 5's 33-failure measurement stands — it concerned the **deploying admin**, a different principal. ⚠ **What the principal actually holds is NOT measured** — stated as inference, with the cheap check named. **The remedy is NOT to widen the permission set.** | §2 Finding C |
| 15 | **W2 — FLS is only half of "can the analyst see it".** `Lead_Record_Page`'s only source-side assignment is one app-level `actionOverride` at `formFactor Large`, and **neither VR field appears in any of the 228 `layouts/` files** ⇒ a fallback page renders neither while the VR fires everywhere. **PRE-EXISTING and org-state — not introduced here, not a file fix.** | §4, beside G3 |
| 16 | **W3 — P1-D3's "Apex/LWC half" paragraph was stale** and contradicted the P1-D2 table ~100 lines above. Reconciled; **every line number re-derived, not copied.** C13 recorded as CLOSED. The four test classes still asserting on `'Commercial'` are named — they break on the **irreversible** pass. | §3 P1-D3 |

---

## 1. Current repo state

The working tree is at **P1-D1 state**: fully additive. `Commercial` and `Retail` coexist
everywhere; nothing has been removed. This is deliberate — the tree must be deployable at the next
step, and D4 is subtractive.

### Created

| File | Notes |
|---|---|
| `force-app/main/default/objects/Lead/fields/Listing_Status__c.field-meta.xml` | Picklist, restricted, `On Market` / `Off Market`, no default |
| `force-app/main/default/objects/Lead/fields/Extraction_Score_Pct__c.field-meta.xml` | Number(3,0) |
| `force-app/main/default/objects/Lead/fields/Fields_Captured_Count__c.field-meta.xml` | Number(3,0) |
| `force-app/main/default/objects/Lead/fields/Fields_Missing_Count__c.field-meta.xml` | Number(3,0) |
| `force-app/main/default/objects/Opportunity/fields/Listing_Status__c.field-meta.xml` | identical type |
| `force-app/main/default/objects/Opportunity/fields/Extraction_Score_Pct__c.field-meta.xml` | identical type |
| `force-app/main/default/objects/Opportunity/fields/Fields_Captured_Count__c.field-meta.xml` | identical type |
| `force-app/main/default/objects/Opportunity/fields/Fields_Missing_Count__c.field-meta.xml` | identical type |
| `force-app/main/default/objects/Lead/validationRules/Deal_Facts_Required_For_Under_Review.validationRule-meta.xml` | see §6 |
| `force-app/main/default/objects/Opportunity/recordTypes/Retail.recordType-meta.xml` | clone of `Commercial` |
| `force-app/main/default/objects/Opportunity/businessProcesses/Retail.businessProcess-meta.xml` | clone of `Commercial` |

`Property_Address__c` was **not** created — it already exists on both objects.
`Parse_Confidence__c` is untouched and must not be conflated with the new score.

### Modified

| File | Change |
|---|---|
| `objects/Lead/fields/Deal_Type__c.field-meta.xml` | `+Retail` value |
| `objects/Opportunity/fields/Deal_Type__c.field-meta.xml` | `+Retail` value |
| `objects/Lead/recordTypes/Acquisition_Broker.recordType-meta.xml` | `+Retail` in `Deal_Type__c`; 🔴 **+ the whole `Listing_Status__c` `<picklistValues>` block (re-review C4)** |
| `objects/Lead/recordTypes/IR_Investor.recordType-meta.xml` | `+Retail` in `Deal_Type__c`; 🔴 **+ the whole `Listing_Status__c` `<picklistValues>` block (re-review C4)** |
| `objects/Opportunity/recordTypes/Land.recordType-meta.xml` | `+Retail` in `Deal_Type__c` |
| `objects/Opportunity/recordTypes/Commercial.recordType-meta.xml` | `+Retail` in `Deal_Type__c` |
| `permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml` | +8 FLS (editable), +`Opportunity.Retail` RT visibility |
| `permissionsets/DPEG_Acquisition_View.permissionset-meta.xml` | +8 FLS (read-only) |
| `permissionsets/DPEG_Opportunity_View.permissionset-meta.xml` | +4 FLS (read-only, Opportunity only) |
| `permissionsets/Broker_Protection_Access.permissionset-meta.xml` | +4 FLS (Lead only, editable); VERIFY query updated `Lead 28 → 32` |
| `permissionsets/DPEG_Admin_Access.permissionset-meta.xml` | **de-duplicated** (see §2 Finding B), +`Opportunity.Retail` RT visibility, **+8 FLS (4 Lead + 4 Opportunity, editable) — amendment 5** |
| `flexipages/Opportunity_Record_Page.flexipage-meta.xml` | **D3 repoint APPLIED** — the two `{!Record.Deal_Type__c}` criteria (lines 58, 1381) now read `Retail`. ⚠ **Deploy this file at D3, never at D1** — see §3 P1-D3. |

**C12 is satisfied:** the `Deal_Type__c` value is enumerated on **four** record-type files, all
four carry `Retail`, and the new `Retail` record type is a transitional fifth enumeration during
the window.

### 🔴 C4 (re-review, 2026-08-14) — `Listing_Status__c` was missing from BOTH Lead record types

**Measured before the fix:** each of `objects/Lead/recordTypes/Acquisition_Broker` and
`IR_Investor` enumerated exactly ten `<picklist>` blocks — `Asset_Type__c`, `Broker_Priority__c`,
`Deal_Type__c`, `Disqualification_Reason__c`, `Industry`, `LeadSource`, `Parse_Confidence__c`,
`Rating`, `Sale_Process__c`, `Status`. **`Listing_Status__c` was the only custom picklist on Lead
absent from both**, while its two on-page neighbours (`Sale_Process__c`, `Parse_Confidence__c`)
were present. This was a plan defect in the brief that created the field — the same class of
defect the FIX 2026-08-10 comment inside those files exists to record.

**Fixed:** both files now enumerate `Listing_Status__c` with both values (`On Market`,
`Off Market`, no default), in the same shape `Sale_Process__c` uses, inserted in the existing
alphabetical order. **Purely additive — `git diff` on the record-type directory shows zero removed
lines.** Both files are already in the P1-D1 deploy list, so no deploy list changed.

⚠ **NEW DEPLOY DEPENDENCY, and the existing order already satisfies it:** these two files now
name a field that P1-A creates. **P1-A must precede P1-D1** — it already does. A `picklistValues`
block naming a field that does not exist yet fails the deploy, so do not reorder those two steps
and do not deploy the record types early "because they are only record types".

#### 🔴 THE RULE THIS FIX ACTS ON IS REPO-ASSERTED, NOT MEASURED IN THIS ORG

The drop-on-omission behaviour — *"a record type file that omits a picklist silently drops ALL of
that picklist's values from that type"* — is asserted in requirements §3 (the `Disposition_LOI`
instruction), in the P1-D4 README, and in the FIX 2026-08-10 comment inside both record-type files.
**It is asserted, not measured. No describe in this org has confirmed it.** Do not repeat it as
established fact.

**The fix was made anyway, and that is a deliberate asymmetry, not sloppiness:**

| If the assertion is… | Cost of having made this edit | Cost of NOT having made it |
|---|---|---|
| **wrong** | zero — enumerating the complete value set is a no-op | zero |
| **right** | zero | 🔴 the analyst sees a rendered, editable, FLS-granted `Listing_Status__c` with **no selectable values**, cannot satisfy `Deal_Facts_Required_For_Under_Review`, and every pipeline-created Lead strands at `New` |

Nothing catches the right-hand case: no Apex writes `Lead.Status = 'Under Review'`; the validation
rule reads its fields in system context so it fires regardless; and a picklist with no available
values still accepts a system-mode Apex write. It is the **third route** to the outage review C1
closed on `Lead_Record_Page` and gate G3 closes on FLS.

**⚠ PHASE 3 HITS THIS SAME QUESTION** for the LOI and PSA record types, where the answer changes
what must ship rather than merely being free insurance. **Falsify it before then.**

**The cheap falsification — three steps, no migration, no risk:**

1. Deploy `Lead.Listing_Status__c` (P1-A).
2. Deploy **one** record type file — `Acquisition_Broker` — with the block present.
3. Describe the field *scoped to that record type* and record the answer:

```bash
# values available on the record type (the authoritative read)
sf data query --use-tooling-api \
  --query "SELECT Id, DeveloperName FROM RecordType WHERE SobjectType='Lead'" \
  --target-org usman.khan.dpeg@avanzasolutions.com
# then, in Setup or via the UI API record-defaults call for that record type Id,
# confirm Listing_Status__c offers On Market / Off Market.
```

The decisive comparison is against a picklist the file **omits**. Until 2026-08-14 that comparison
was free — `Listing_Status__c` itself was the omitted one. It no longer is, so pick another
deliberately-omitted picklist, or run the check in a scratch org where a value can be removed and
put back. **Record the result here when it is taken; until then this row stays "asserted".**

---

## 2. Reconciliation record (org → repo, 2026-08-14)

All five permission sets were retrieved from `usman-dpeg` and diffed **before** any was edited.
Re-run this before any future edit; a past clean reconciliation is a snapshot, not a guarantee.

```bash
sf project retrieve start \
  --metadata "PermissionSet:DPEG_Acquisition_Edit" \
  --metadata "PermissionSet:DPEG_Acquisition_View" \
  --metadata "PermissionSet:DPEG_Opportunity_View" \
  --metadata "PermissionSet:Broker_Protection_Access" \
  --metadata "PermissionSet:DPEG_Admin_Access" \
  --target-org usman.khan.dpeg@avanzasolutions.com \
  --target-metadata-dir <scratch> --unzip --wait 20
```
An **empty** retrieve proves nothing — confirm each file is non-empty before trusting the diff.

| Set | org fieldPerms | repo fieldPerms | org-only | Verdict |
|---|---|---|---|---|
| `DPEG_Acquisition_Edit` | 290 | 290 | 0 | clean |
| `DPEG_Acquisition_View` | 290 | 290 | 0 | clean |
| `DPEG_Opportunity_View` | 63 | 63 | 0 | clean |
| `Broker_Protection_Access` | 77 | 72 | 5 × `Event.*` | **explained, not drift — see below** |
| `DPEG_Admin_Access` | 10 | 10 | 0 | clean on fields; **6 duplicate record types in repo** |

### Finding A — RAISED, THEN FALSIFIED. Do not "fix" it.

The five org-only rows are `Event.Description`, `Event.Inbound_Message_Id__c`,
`Event.Thread_Key__c`, `Event.WhatId`, `Event.WhoId`.

They are **platform-managed Event mirrors of the Task rows**, created by Salesforce itself when
the `Task.*` grants deploy. This is not inference — `Broker_Protection_Access`'s own header
comment documents it in two places: its VERIFY query has expected them since 2026-08-05 ("plus
platform-managed Event mirrors of the Task/Activity rows"), and the 2026-08-05 root-cause entry
states "Salesforce then auto-creates the platform-managed Event mirror … so Event access is not
lost."

The arithmetic closes exactly:

```
repo declared, real elements ............ 72   (72 <fieldPermissions>, 72 <field>)
  + 4 new Lead fields (this change) ..... 76
org holds ............................... 77   = 72 declared + 5 Event mirrors
```

The earlier counts of 73 and 74 were **inflated by comment prose**: lines 88–90 of that file quote
`` `<field>Activity.Inbound_Message_Id__c</field>` `` and
`` `<field>Activity.Thread_Key__c</field>` `` as examples of a historical mistake. Those are the
only `Activity.*` occurrences and **no real `<field>Activity.*</field>` element exists**. That is
what the "one repo-only entry I could not locate" turned out to be.

**Consequence: adding explicit `Event.*` rows would have been wrong.** It would declare as
managed-by-source something the platform manages, against a file whose entire history is about the
`Activity`/`Task`/`Event` prefix distinction. All six `Task.*` rows are intact, so the mirrors
regenerate on deploy.

The generalisable trap: **count elements, not grep hits, in a file whose comments quote XML.**

### Finding B — REAL, FIXED

`DPEG_Admin_Access` declared six `recordTypeVisibilities` twice: `Account.Broker_Firm`,
`Account.Investor_Entity`, `Contact.Broker`, `Contact.Investor`, `Lead.Acquisition_Broker`,
`Lead.IR_Investor`. The org holds each once.

Cause: the 2026-08-10 reconciliation appended six blocks believing they were missing. They were
not — they were in the alphabetically sorted region further down, while the appended copies sorted
*above* it and so read as a separate group.

Fixed: the duplicate block was removed. Repo now holds **16** `recordTypeVisibilities`, matching
the org exactly, with zero set difference in either direction.

### Finding C — PRE-EXISTING FLS ASYMMETRY on `Broker_Protection_Access`. **Evidence, not a defect. Do NOT close it by widening the set.**

Added 2026-08-14 (re-review). This finding exists because the *obvious* remedy is wrong, and the
reasoning that makes it look right is the reasoning amendment 5 established.

**The measurement.** `EmailToLeadService.applyPropertyBlock` assigns four fields on four
consecutive lines — `EmailToLeadService.cls:396–399` — and a fifth at line 404:

| Line | Field assigned | Granted by `Broker_Protection_Access`? |
|---|---|---|
| 396 | `Property_Name__c` | ✅ yes (editable) |
| 397 | `Asset_Type__c` | 🔴 **NO** |
| 398 | `Deal_Type__c` | 🔴 **NO** |
| 399 | `Sale_Process__c` | ✅ yes (editable) |
| 404 | `Listing_Status__c` | ✅ yes (editable) — added by this pack |

**And the pipeline runs in production today.** Two of the five fields written in one statement
block are ungranted on this set and the inserts succeed.

🔴 **WHAT THAT FALSIFIES.** Amendment 5 records that an *assignment marks a field dirty regardless
of value*, and that a plain Apex `insert` on Lead is FLS-enforced in this org — which is true, and
is why declaring eight grants on `DPEG_Admin_Access` cleared 33 test failures. **The invalid step
is generalising it to the runtime pipeline.** As stated, the premise predicts that
`applyPropertyBlock` throws on every inbound email, and it does not. So:

> **"An assignment marks the field dirty, therefore a missing FLS grant throws on insert" does
> NOT hold as a general rule.** The two ungranted siblings on lines 397–398 are the standing
> counter-example, and they have been there since before this pack.

The 33-failure measurement remains **valid and unretracted** — it concerned the **deploying
administrator's** grants (`DPEG_Admin_Access`), running the test suite. **That is a different
principal from the one the pipeline runs as.** Amendment 5 already says so ("test methods run as
the deploying user unless a `System.runAs` wraps them"); this finding is the reminder not to carry
its conclusion across the principal boundary.

#### ⚠ WHAT IS **NOT** ESTABLISHED — read this before acting on the paragraph above

**Nobody has queried what the runtime pipeline principal actually holds.** The measurement above
is repo-side only: it shows `Broker_Protection_Access` does not grant two of the fields, and that
production works. The natural explanation — *the Email Service context user holds more than that
one set, or a profile supplying the rest* — is an **INFERENCE, not a measurement.** Other
explanations are not excluded (a different enforcement path on this insert, a permission source
outside this repo, a profile-level grant that never deploys because `profiles/**` is
`.forceignore`d).

**Do not launder either half into fact.** "The general rule is falsified" is measured. "The
principal holds more" is not.

**The cheap check, if it ever matters:** query the Email Service context user's assignments.

```sql
-- 1. identify the principal (Setup → Email Services → the inbound handler's context user)
-- 2. then:
SELECT Assignee.Name, PermissionSet.Name, PermissionSet.IsOwnedByProfile
FROM PermissionSetAssignment
WHERE Assignee.Username = '<the email service context user>'
```

**Nothing in Phase 1 is blocked on this.** It is recorded so a future reader does not (a) re-derive
the falsified general rule, or (b) "fix" the asymmetry by adding `Lead.Asset_Type__c` /
`Lead.Deal_Type__c` to `Broker_Protection_Access` — which would widen the pipeline principal's
access on the strength of a premise this finding disproves, with the two ungranted siblings
standing as the evidence it is unnecessary.

### Not drift — do not copy in

The org retrieve emits `<viewAllFields>false</viewAllFields>` on every `objectPermissions` block
where the repo omits it. That is an API-added default. Omitting it deploys as `false`. It appeared
in the raw diff for four of the five sets and was deliberately not written into the repo.

---

## 3. Deploy sequence

Legend: **[MIG]** = an org data migration runs between this step and the next.
**[ORG-Q]** = verified by an org query, **not** by a green deploy.

### P1-A — the eight fields and their FLS

Deploy:
```
force-app/main/default/objects/Lead/fields/Listing_Status__c.field-meta.xml
force-app/main/default/objects/Lead/fields/Extraction_Score_Pct__c.field-meta.xml
force-app/main/default/objects/Lead/fields/Fields_Captured_Count__c.field-meta.xml
force-app/main/default/objects/Lead/fields/Fields_Missing_Count__c.field-meta.xml
force-app/main/default/objects/Opportunity/fields/Listing_Status__c.field-meta.xml
force-app/main/default/objects/Opportunity/fields/Extraction_Score_Pct__c.field-meta.xml
force-app/main/default/objects/Opportunity/fields/Fields_Captured_Count__c.field-meta.xml
force-app/main/default/objects/Opportunity/fields/Fields_Missing_Count__c.field-meta.xml
force-app/main/default/permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml
force-app/main/default/permissionsets/DPEG_Acquisition_View.permissionset-meta.xml
force-app/main/default/permissionsets/DPEG_Opportunity_View.permissionset-meta.xml
force-app/main/default/permissionsets/Broker_Protection_Access.permissionset-meta.xml
force-app/main/default/permissionsets/DPEG_Admin_Access.permissionset-meta.xml
force-app/main/default/objects/Lead/validationRules/Property_And_Email_Required_To_Progress.validationRule-meta.xml
force-app/main/default/flexipages/Lead_Record_Page.flexipage-meta.xml
force-app/main/default/objects/Lead/listViews/Lead_Funnel.listView-meta.xml
force-app/main/default/objects/Lead/listViews/Review_Queue.listView-meta.xml
```
> 🔴 **THE THREE FILES AFTER THE VALIDATION RULE ARE THE UI SURFACE, AND WITHOUT THEM P1-A IS A
> PIPELINE OUTAGE, NOT AN INCOMPLETE FEATURE (review C1, added 2026-08-14).**
> `Lead_Record_Page` is a **Dynamic Forms** page — every field is an explicit `<fieldItem>`, so a
> field absent from the file does not render at all. `Listing_Status__c` defaults blank BY DESIGN
> (the LLM is instructed not to guess it), the new `Deal_Facts_Required_For_Under_Review` blocks
> entry to `Under Review` while it is blank, and `leadMarkUnderReview` writes Status through LDS,
> so the rule fires. Ship the rule without the page and **every pipeline-created Lead is stuck at
> `New` with no field on screen to unblock it.** No test catches this — no Apex writes
> `Lead.Status = 'Under Review'`.
> The page now carries all four new fields: `Listing_Status__c` **editable**, beside its extraction
> sibling `Sale_Process__c`; the three score fields **read-only** (they are system-written), beside
> `Parse_Confidence__c`.
> The two list views add `Extraction_Score_Pct__c` as a column — the score's entire stated purpose
> in `ExtractionScoreUtil`'s header is that an analyst can rank leads by completeness, which needs
> a column, not a detail-page field.
> ⚠ **`Opportunity_Record_Page` carries the other four and is deployed at P1-D3, NOT here** — see
> that step. It is one file and must travel once.
>
> ⚠ **The validation-rule file above is the INCUMBENT rule, message-only (amendment 8).** It is not new and was
> not in the original Phase 1 scope; it carries the branch (c) explanation on behalf of
> `Deal_Facts_Required_For_Under_Review`. It changes no logic, so it needs no migration and no
> org query — but omitting it ships the explanation in the repo and not in the org. If the new
> rule `Deal_Facts_Required_For_Under_Review` travels in P1-D2 instead (§3 P1-D2), this one may
> travel with it — they must not be split across steps in a way that leaves the org showing two
> messages for one missing field.
>
> The permission sets must be in the **same** deploy as, or a later one than, the fields — a
> `fieldPermissions` entry for a field that does not exist yet fails the deploy.
>
> 🔴 **`DPEG_Admin_Access` MOVED INTO THIS STEP (amendment 5). It is a DEPLOY BLOCKER, not a
> visibility nicety, and the earlier note saying it "goes with P1-D1" is superseded.** It now
> carries the eight new `fieldPermissions` as well as the `Opportunity.Retail` visibility.
> Measured by the Apex build in a scratchpad copy: **33 of 36 `EmailToLeadServiceTest` methods
> failed** with `System.DmlException | Operation failed due to fields being inaccessible on
> Sobject Lead` — **including tests written months ago that reference none of the new fields**.
> Cause: `ExtractionScoreUtil.applyExtractionScore` assigns the three score fields on **every**
> path, the degraded all-null one included, and an assignment marks a field **dirty** regardless
> of the value; a plain Apex `insert` on Lead is **FLS-enforced** in this org. So every Lead
> insert in the suite now touches these fields. Declaring the eight grants cleared all 33.
> ⚠ **Granting the PERSONA sets does not fix this.** Test methods run as the **deploying user**
> unless a `System.runAs` wraps them, and that user is an administrator — the persona sets grant
> the persona. `DPEG_Admin_Access` exists precisely to restore what the Admin profile grants but
> never deploys (`profiles/**` is `.forceignore`d), so it is the only correct home.
> ⚠ The grants are **editable**, not read-only: the failing operation is a WRITE.
> Same symptom class as the 2026-08-05/06 `Task.WhoId` incident (ARCHITECTURE.md §2).

**[ORG-Q] Verify.** A green field deploy does **not** imply FLS: a Metadata-API-deployed custom
field arrives with no field permissions for **any** profile, System Administrator included, and
`profiles/**` is `.forceignore`d, so there is no profile fallback and no file-based check can see
the gap.

```sql
SELECT Parent.Name, Field, PermissionsRead, PermissionsEdit
FROM FieldPermissions
WHERE Field IN (
  'Lead.Listing_Status__c','Lead.Extraction_Score_Pct__c',
  'Lead.Fields_Captured_Count__c','Lead.Fields_Missing_Count__c',
  'Opportunity.Listing_Status__c','Opportunity.Extraction_Score_Pct__c',
  'Opportunity.Fields_Captured_Count__c','Opportunity.Fields_Missing_Count__c')
ORDER BY Parent.Name, Field
```
Expect **32 rows** (was 24 before amendment 5):

| Set | rows | `PermissionsEdit` |
|---|---|---|
| `DPEG_Acquisition_Edit` | 8 (4 Lead + 4 Opportunity) | true |
| `DPEG_Acquisition_View` | 8 (4 Lead + 4 Opportunity) | false |
| `DPEG_Opportunity_View` | 4 (Opportunity only) | false |
| `Broker_Protection_Access` | 4 (Lead only) | true |
| **`DPEG_Admin_Access`** | **8 (4 Lead + 4 Opportunity)** | **true** |

And the per-set totals:
```sql
SELECT Parent.Name, COUNT(Id) FROM FieldPermissions
WHERE Parent.Name IN ('DPEG_Acquisition_Edit','DPEG_Acquisition_View',
                      'DPEG_Opportunity_View','Broker_Protection_Access','DPEG_Admin_Access')
GROUP BY Parent.Name
```
Expect `DPEG_Acquisition_Edit` 298, `DPEG_Acquisition_View` 298, `DPEG_Opportunity_View` 67,
**`DPEG_Admin_Access` 18** (was 10).

🔴 **`DPEG_Admin_Access` 10 after this deploy means the eight admin grants did not land, and the
symptom is a FAILED TEST RUN, not a blank field** — 33 `EmailToLeadServiceTest` failures reading
`fields being inaccessible on Sobject Lead`, most of them in tests that have nothing to do with
this pack. Do not chase the test names; check this query first.
For `Broker_Protection_Access` use that file's own documented VERIFY query instead — it groups by
`SobjectType` and must now return **Lead 32** (was 28), Task 6, Contact 1,
`Inbound_Email_Staging__c` 24, `Competing_Broker_Submission__c` 10, `Property_Registry__c` 3, plus
the platform-managed `Event` mirrors.

🔴 **`Lead 28` after this deploy means the four new grants did not land.** The pipeline still
writes the values — the Lead insert is system-mode — so nothing errors and no test fails. The
values are simply invisible to the persona, and a blank extraction score reads as "nothing to
chase" rather than "you cannot see this".

#### 🔴 SECOND QUERY — the OTHER field the validation rule tests (added 2026-08-14, re-review)

The 32-row query above covers the four **new** fields. `Deal_Facts_Required_For_Under_Review`
blocks on `Deal_Type__c` **OR** `Listing_Status__c`, and `Deal_Type__c` is an **incumbent** field
that appears in no count on this page — so a persona missing it is invisible to every check above
while being **completely blocked**. Run this in the same sitting:

```sql
SELECT Parent.Name, Field, PermissionsRead, PermissionsEdit
FROM FieldPermissions
WHERE Field IN ('Lead.Deal_Type__c','Lead.Listing_Status__c')
ORDER BY Field, Parent.Name
```

Expect, from the repo files (measured 2026-08-14):

| Field | Sets granting it | Edit? |
|---|---|---|
| `Lead.Deal_Type__c` | `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View` | **Edit** / read |
| `Lead.Listing_Status__c` | `DPEG_Acquisition_Edit`, `DPEG_Acquisition_View`, `Broker_Protection_Access`, `DPEG_Admin_Access` | Edit / read / Edit / Edit |

🔴 **The pass condition is not "rows came back" — it is that the analyst persona holds a set
granting `PermissionsEdit = true` on BOTH rows, which in this repo means `DPEG_Acquisition_Edit`.**
`Broker_Protection_Access` alone is **not** sufficient for a human: it grants `Listing_Status__c`
and not `Deal_Type__c`, so the analyst fills the field they can see and is still blocked by one
they cannot. Full consequence table in §4, gate G3.

⚠ **Do NOT close this by adding `Lead.Deal_Type__c` to `Broker_Protection_Access`.** That widens
the *pipeline principal's* access to fix a *human's* problem, and §2 Finding C is the measurement
showing the premise behind that instinct does not hold. The remedy is an ASSIGNMENT (gate G3).

### P1-D1 — add `Retail`, keep `Commercial`

Deploy:
```
force-app/main/default/objects/Lead/fields/Deal_Type__c.field-meta.xml
force-app/main/default/objects/Opportunity/fields/Deal_Type__c.field-meta.xml
force-app/main/default/objects/Lead/recordTypes/Acquisition_Broker.recordType-meta.xml
force-app/main/default/objects/Lead/recordTypes/IR_Investor.recordType-meta.xml
force-app/main/default/objects/Opportunity/recordTypes/Land.recordType-meta.xml
force-app/main/default/objects/Opportunity/recordTypes/Commercial.recordType-meta.xml
force-app/main/default/objects/Opportunity/recordTypes/Retail.recordType-meta.xml
force-app/main/default/objects/Opportunity/businessProcesses/Retail.businessProcess-meta.xml
force-app/main/default/permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml
force-app/main/default/permissionsets/DPEG_Admin_Access.permissionset-meta.xml
```
> Deploy the **business process before or with** the record type — `Retail.recordType` references
> `<businessProcess>Retail</businessProcess>` and will not validate without it.
> The record-type visibilities are added **now, before the migration**, deliberately: visibility is
> what lets a user *select* a record type, so granting it after the migration leaves a window in
> which nobody on those sets can create a commercial deal.
> ⚠ Both permission sets also appear in P1-A (amendment 5). Re-deploying them here is harmless
> and idempotent — they are the same files, and P1-A necessarily precedes this step. If P1-A and
> P1-D1 are collapsed into one deploy, deploy each permission set **once**, not twice.

**[ORG-Q] Verify — both values and both record types present:**
```sql
SELECT Id, Name, DeveloperName, IsActive, BusinessProcessId
FROM RecordType WHERE SobjectType = 'Opportunity' ORDER BY DeveloperName
```
Expect `Commercial`, `Land`, `Retail`, all `IsActive = true`.

```bash
sf sobject describe --sobject Lead        --target-org usman.khan.dpeg@avanzasolutions.com
sf sobject describe --sobject Opportunity --target-org usman.khan.dpeg@avanzasolutions.com
```
`Deal_Type__c.picklistValues` must contain **both** `Land`, `Commercial` **and** `Retail`, all
active, on both objects.

```sql
SELECT Parent.Name, RecordType.DeveloperName FROM PermissionSetRecordTypeVisibility
WHERE Parent.Name IN ('DPEG_Acquisition_Edit','DPEG_Admin_Access')
  AND RecordType.SobjectType = 'Opportunity'
```
Expect `Commercial`, `Land`, `Retail` for each set.

### [MIG] — the backfill

Two updates, both on the org. **This is where the rename actually happens.**

1. Every `Deal_Type__c = 'Commercial'` → `'Retail'` on **`Lead`** and **`Opportunity`**.
2. Every Opportunity on the `Commercial` record type → the `Retail` record type.

Extract first so the change is reversible:
```bash
sf data query --query "SELECT Id, Deal_Type__c FROM Lead WHERE Deal_Type__c = 'Commercial'" \
  --result-format csv --target-org usman.khan.dpeg@avanzasolutions.com > lead_dealtype_before.csv
sf data query --query "SELECT Id, Deal_Type__c, RecordTypeId FROM Opportunity WHERE Deal_Type__c = 'Commercial' OR RecordType.DeveloperName = 'Commercial'" \
  --result-format csv --target-org usman.khan.dpeg@avanzasolutions.com > opp_dealtype_before.csv
```

**Validation-rule interaction — checked, not assumed.** This migration is safe to run with all
rules active:

- The new `Deal_Facts_Required_For_Under_Review` and the incumbent
  `Property_And_Email_Required_To_Progress` are both `ISCHANGED(Status)`-scoped. The backfill
  changes `Deal_Type__c` and `RecordTypeId`, never `Status`. Neither fires.
- `Property_And_Email_Required_To_Convert` is `ISCHANGED(IsConverted)`-scoped. Not fired.
- The Opportunity rules that would bite (`No_Backward_Stage_Movement`,
  `NDA_Signed_Before_Deal_Progression`) are `ISCHANGED(StageName)`-scoped. The record-type change
  does not change `StageName`. Not fired.
- The record-type change cannot invalidate a stage: `Retail.businessProcess` is a verified clone
  of `Commercial`'s — identical nine values, identical order (`Dead%2FPass` encoding included).
  Diffed at build time; the only difference is `<fullName>`.

> ⚠ **This is Phase 1's migration only.** Phase 2's `PSA → Under Contract (PSA)` migration DOES
> change `StageName` and WILL fire those two rules. That decision belongs to the Phase 2 runbook.

**[ORG-Q] Verify — all three must return 0:**
```sql
SELECT COUNT() FROM Lead        WHERE Deal_Type__c = 'Commercial'
SELECT COUNT() FROM Opportunity WHERE Deal_Type__c = 'Commercial'
SELECT COUNT() FROM Opportunity WHERE RecordType.DeveloperName = 'Commercial'
```
And confirm the rows arrived rather than vanishing:
```sql
SELECT COUNT() FROM Opportunity WHERE RecordType.DeveloperName = 'Retail'
```
must equal the pre-migration `Commercial` record-type count.

### P1-D2 — Apex (developer half)

Extraction scoring, the `listing_status` extraction key, `LeadConvertService` carry-forward, and
the new Lead validation rule. Verified by a green deploy + `RunLocalTests`.

🔴 **"Not in this build" WAS THE STATE OF THIS SECTION AND IS NOW STALE — CORRECTED 2026-08-14
(re-review drift 3). THE APEX IS ON DISK.** This sentence was written when the declarative and
programmatic halves were being built separately; the Apex half has since landed in the working
tree and §7 below said the same stale thing. Measured against the tree on 2026-08-14:

| Claimed "handed back" | Actual state on disk | Evidence |
|---|---|---|
| `LeadConvertService` record-type resolution → `Retail` | ✅ **APPLIED** | `LeadConvertService.cls:269` — `new Set<String>{ 'Land', 'Retail' }`, with an in-code comment naming this as "the Deal Type migration, phase 1 D3" |
| the C13 prompt repoint | ✅ **APPLIED** | `LLMExtractionCalloutService.cls:772` — `'deal_type must be one of: Land, Retail.\n'`; its own EDIT 2 note at line 411 records the change |
| `OpportunityFunnelController` line 98 | ✅ **APPLIED** (now line 104) | `s.commercialDeals = OpportunitySelector.countByDealType('Retail')` — the DTO member is deliberately NOT renamed; it is the wire contract `lwc/opportunityPipeline` reads |
| `TestDataFactory` `Deal_Type__c` | ✅ **APPLIED** | lines 604 (`createLeads`) and 649 (`createOpportunities`) both stamp `'Retail'` |
| Extraction scoring, `listing_status` key, conversion carry-forward | ✅ **APPLIED** | `ExtractionScoreUtil` exists and is referenced by amendment 5; `PropertyExtraction` / `LLMExtractionParser` / `EmailToLeadService` / `LeadConvertService` all modified in the tree |

**Only `Commercial` survives in `classes/`, in seven files:** `LeadConvertService.cls` and
`OpportunityFunnelController.cls` (both in *comments* recording the change),
`LLMExtractionCalloutService.cls` (its EDIT 2 note), and four test classes
(`LeadConvertActionServiceTest`, `LeadConvertServiceTest`, `LeadConvertTriggerHandlerTest`,
`OpportunityFunnelControllerTest`). **Open those four before D4** — a test asserting on
`'Commercial'` still passes today and starts failing the moment the value is deleted.

---

#### 🔴 `RunLocalTests` FAILURE SCOPE — READ THE NUMBER *AND* ITS SCOPE, NEVER JUST THE NUMBER

**`TestDataFactory` stamps `Deal_Type__c = 'Retail'` on BOTH `createLeads` (line 604) and
`createOpportunities` (line 649), and `Deal_Type__c` is a RESTRICTED picklist on both objects
(`<restricted>true</restricted>`, measured in both field files). Until P1-D1 genuinely deploys
`Retail` to the org, every factory-built Lead and Opportunity is writing a value the org does not
have.**

**Measured against the tree, 2026-08-14:**

| Measure | Value | How |
|---|---|---|
| Test classes calling `TestDataFactory.createLead(s)` / `createOpportunit*` | **73** | `grep -rlE "TestDataFactory\.(createLeads?\|createOpportunit)" force-app/main/default/classes/` — all 73 are test classes |
| `@isTest` annotations inside those 73 | **1,059** (≈986 test methods once the 73 class-level annotations are removed) | `grep -c @isTest` summed |
| Failures scoped to `EmailToLeadServiceTest` alone | 4 | the figure this note exists to contradict |

⇒ **Expect failures in the HUNDREDS, not 4.** The 73 classes are an exact count; ~986 is the
method population they contain, and the failing set is a subset of it — but it is bounded far
above 4 and spans classes with no connection to this pack (`RentRoll*`, `Onboarding*`,
`Disposition*`, anything that needs an Opportunity fixture).

**Anyone expecting 4 will either panic at the volume or — far worse — wave a genuine regression
through as "expected".** State the scope beside any failure count you report.

**Mechanism, stated at the level it was actually established:** the value set is restricted
(measured from the two field files) and `Retail` is absent from the org until P1-D1 (the pack is
undeployed, §0 amendment 3). A restricted picklist rejects an off-list value at DML with
`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` — documented platform behaviour, **not measured in this
org for this field**. ⚠ Do not conflate this with the *record-type* picklist restriction, which
ARCHITECTURE.md §2 records as UI-only and **not** enforced by Apex DML. These are different
mechanisms; only the field-level one bites here.

> 🔴 **THE MECHANISM ABOVE IS AN OPEN QUESTION, AND THE EVIDENCE AGAINST IT WAS MEASURED ON
> THIS EXACT FIELD.** Phase 2's check-only run inserted a Lead at `Deal_Type__c = 'Retail'` and
> it **PASSED**, with **zero** `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` across all 20 failures
> — while the field is `restrictedPicklist: true`. There is now one measurement each way on one
> field, and the two runs differ in more than one variable at once, so **neither side is
> settled**.
>
> **Read it before acting on the failure-scope arithmetic above:**
> `agent-output/runbook-acquisition-observations-phase2.md` §3 P2-D1, subsection
> *"On the genuinely RESTRICTED field, the question is OPEN — do not pick a winner"*.
>
> ⚠ **This pointer exists because the finding is recorded in PHASE 2's runbook while the field is
> PHASE 1's, and the two phases are separately executed and separately committed** — an operator
> running P1-D1 has no reason to open Phase 2's document (re-review S-3b). It is deliberately a
> **pointer, not a copy**: duplicating the finding would let the two drift, and the phase-2
> section carries caveats this summary does not.
>
> ⚠ **It does not change anything Phase 1 does.** Deploy P1-D1 first regardless — that is correct
> under *both* readings. What it changes is what a **surviving** failure means: if the hundreds
> of failures predicted above do **not** materialise, that is the open question resurfacing, not
> evidence that P1-D1 deployed.

**The clean signal:** after P1-D1 lands, this failure class disappears in one deploy with no code
change. If a failure survives P1-D1, it is real. **Do not "fix" `TestDataFactory` back to
`Commercial`** — that reintroduces the value D4 deletes and moves the same cliff to D4b, where it
is irreversible.

⚠ See §6 for the validation rule, which is already on disk and can travel in either P1-A or P1-D2.

### P1-D3 — repoint every live reference

Use the **classified** inventory in requirements §6.1. Do not re-run the raw grep: of 88 files, 41
are under `profiles/` (force-ignored, not references) and 5 are verified false positives —
`'C-2 Commercial'` is a **`Zoning__c`** value, three are company names
(`'Commercial Partners Inc'`, `'Commercial Small List LLC'`), one is a local variable
(`openCommercial`).

Declarative half owned by this runbook — **2 criteria in one file. ✅ APPLIED IN THE TREE
2026-08-14 (amendment 6). Nothing to edit;** ⚠ **[CORRECTED 2026-08-14 — the clause that stood
here, "this step DEPLOYS the file", is FALSE and must not be acted on. P1-D3 deploys a GENERATED
copy of this file. Deploying the TREE copy at P1-D3 fails the deploy on Phase 4's unresolvable
component — or, if Phase 4's LWC happens to be live already, silently ships Phase 4's UI at a time
Phase 4 did not choose. See the box below.]**

`force-app/main/default/flexipages/Opportunity_Record_Page.flexipage-meta.xml`

> ### 🔴 P1-D3 DEPLOYS A GENERATED COPY OF THIS FILE, NEVER THE TREE COPY (added 2026-08-14)
>
> **THREE phases now edit this one file, and a FlexiPage deploys WHOLE:** Phase 1 (the two
> `Deal_Type__c` criteria below plus the four new field items), Phase 2 (two `{!Record.StageName}`
> criteria repointed `PSA` → `Under Contract (PSA)`), and Phase 4 (the `c/callForOffersPanel`
> component in the `sidebar` region). **P4-D owns the tree copy.** P1-D3 and P2-D2 each deploy a
> generated copy. The full ownership table is in the Phase 2 runbook §2.
>
> Generate the P1-D3 copy **immediately before the deploy**, not in advance:
>
> ```bash
> node agent-output/p2-flexipage-p1d3-safe/make-p1d3-copy.js <scratch-dir> --phase 1 --phase4 strip
> ```
>
> Then deploy `<scratch-dir>/flexipages/`, not `force-app/main/default/flexipages/`.
>
> 🔴 **`--phase4` HAS NO DEFAULT AND MUST NOT BE GIVEN ONE: the two wrong answers are not equally
> visible.** `keep` before P4-D has deployed merely fails the deploy loudly (the org has no such
> LWC); `strip` after P4-D has deployed **silently removes a live component from the Opportunity
> record page** — no error, no log, nobody told. Only a human knows which world they are in, so the
> script refuses to guess and exits 1 if the flag is absent. Use `--phase4 keep` **only** if P4-D has
> already landed in the target org; check with
> `sf project retrieve start --metadata "FlexiPage:Opportunity_Record_Page"` and grep the retrieved
> file for `callForOffersPanel`.
>
> ⚠ **The bare form `node …/make-p1d3-copy.js <scratch-dir>` is REFUSED (exit 1).** It is the form
> the Phase 2 runbook documented for this step until 2026-08-14 (this runbook named no command at
> all), and against the Phase 4 tree it exited 0 while emitting a copy labelled "P1-D3-safe" that
> carried the panel. Both commands above were run and their output verified on 2026-08-14.
> ⚠ **Do not commit the output.** It is a transient deploy artifact, not a second source of truth.

| Line | Context | Change |
|---|---|---|
| 58 | `<criteria>` whose `<leftValue>` is `{!Record.Deal_Type__c}`, inside the `Opportunity.Send_to_Construction_Review` quick-action `valueListItems` visibility rule (`1 AND 2 AND 3`) | `<rightValue>Commercial</rightValue>` → `<rightValue>Retail</rightValue>` ✅ |
| 1381 | `visibilityRule` on `flexipage:tab`, identifier `constructionTab` | same substitution ✅ |

🔴 **THIS SAME FILE ALSO CARRIES THE FOUR NEW OPPORTUNITY FIELDS (review C1, added 2026-08-14).**
They were added to the `Details` field section (`Facet-d06d7c84-…`), immediately after
`Listing_Broker_Email__c` so the extracted deal facts read as one group: `Listing_Status__c`
**editable**, and `Extraction_Score_Pct__c` / `Fields_Captured_Count__c` /
`Fields_Missing_Count__c` **read-only**. Before this they had **no UI surface anywhere** — the four
Opportunity fields appeared in exactly four files repo-wide, their own definitions, with zero hits
across every layout and every list view.
⚠ **CONSEQUENCE FOR SEQUENCING: this one file now carries BOTH the D3 `Retail` repoint AND the C1
field additions, and a FlexiPage deploys whole.** It still deploys HERE, at D3, not earlier — the
`Retail` timing constraint below is unchanged and is the stricter of the two. The cost is that the
four Opportunity fields are invisible on the record page until D3, which is harmless: nothing
writes them until the P1-D2 Apex lands anyway. **Do not split the file to ship the fields sooner.**

> ⚠ Both are `{!Record.Deal_Type__c}` comparisons. Do **not** touch any other `Commercial` string
> in this file without opening the line. **Verified 2026-08-14: after the edit the file contains
> zero occurrences of `Commercial` and exactly two of `Retail`, both `<rightValue>`.**
>
> 🔴 **DEPLOY THIS FILE AT D3, NEVER AT D1 OR EARLIER.** Between the tree edit and the migration
> the file says `Retail` while live rows still say `Commercial`, so deploying it early **hides
> the Construction tab and the Send to Construction Review action on every existing commercial
> deal**. Nothing errors. If the deploy tooling picks up the whole `flexipages/` directory at an
> earlier step, exclude this file explicitly.
> ⚠ **Timing:** these two components are hidden for any deal whose `Deal_Type__c` is already
> `Retail`. That window opens at **[MIG]** and closes here. To shorten it to nothing, deploy this
> file in the same change as the migration's completion rather than waiting for the Apex.
> ⚠ **Read the page back after deploying it.** A FlexiPage deploy can roll back with a design-time
> error that still reports success. Retrieve and diff.

#### Apex/LWC half (developer) — ✅ **APPLIED. This paragraph was STALE; corrected 2026-08-14 (re-review W3).**

🔴 **It previously listed all of the below as PENDING work, with line numbers that have every one
of them moved, and it contradicted the P1-D2 reconciliation table ~100 lines above in this same
document.** An operator reading the steps in order hit "applied" at P1-D2 and "pending" here.
**Line numbers below are RE-DERIVED against the tree on 2026-08-14, not copied forward** — that is
why the old ones were wrong, and it is why they will drift again.

| File | Old claim | Actual, re-derived 2026-08-14 |
|---|---|---|
| `LeadConvertService.cls` | line 239 `new Set<String>{'Land','Commercial'}`, line 266 comment | ✅ **line 269** `new Set<String>{ 'Land', 'Retail' }`; explanatory comment **lines 265–267**; a third note at **line 296** |
| `LLMExtractionCalloutService.cls` | line 719 prompt `'deal_type must be one of: Land, Commercial.'` | ✅ **line 772** `'deal_type must be one of: Land, Retail.\n'`; the change is recorded as EDIT 2 at **line 411** |
| `OpportunityFunnelController.cls` | line 98 | ✅ **line 104** `countByDealType('Retail')` |
| `lwc/recentOpportunities/recentOpportunities.js` | line 20, badge-colour map key | ✅ **line 23** `Retail: ['#e8f1fc', '#1565c0']`; rationale comment line 19 |
| `lwc/opportunityPipeline/opportunityPipeline.js` | line 31, user-facing label | ✅ **line 35** label `'Retail Deals'`; comment line 33 |
| `TestDataFactory.cls` | lines 604/649/691 | ✅ **604** (`createLeads`), **649** (`createOpportunities`), **691** (the `createOpportunitiesByRecordType` error string, now "Expected Land or Retail") |

🔴 **C13 IS CLOSED, AND IT WAS THE ONE WITH A SILENT FAILURE MODE.** The prompt now emits
`Land, Retail`. The hazard it carried — *after D4 an un-repointed prompt instructs the model to
emit a deleted value and the describe-guard drops it silently, no exception, no log* — is
**retired, not merely deferred**. Do not revert this file to reduce a diff.

⚠ **The "15 test files" half is the part still owing attention, and it is now the ONLY `Commercial`
left in `classes/`.** A repo-wide grep of `force-app/main/default/classes/` returns **seven** files,
and three are comments recording the change (`LeadConvertService`, `OpportunityFunnelController`,
`LLMExtractionCalloutService`). The other **four are test classes**:

```
LeadConvertActionServiceTest.cls
LeadConvertServiceTest.cls
LeadConvertTriggerHandlerTest.cls
OpportunityFunnelControllerTest.cls
```

**Open those four before D4.** A test asserting on `'Commercial'` passes today — the value still
exists — and starts failing the moment D4b deletes it, i.e. on the **irreversible** pass, where a
red suite is the worst possible time to discover it. ⚠ This is separate from, and additional to,
the `RunLocalTests` scope warning in §3 P1-D2: that one clears itself when P1-D1 lands, **this one
does not clear itself at all**.

🔴 **C13 is the one with a silent failure mode.** `PropertyExtraction.dealType` is describe-validated
against the live picklist, so between D1 and D4 both values validate and nothing breaks. **After
D4 an un-repointed prompt instructs the model to emit a deleted value and the guard drops it
silently** — no exception, no log. If D3's prompt edit is missed, the defect does not appear until
D4.

**Verify:** a repo grep for `Commercial` returns only the 5 false positives, `profiles/`, and the
prose/comment set.

### P1-D4 — retire `Commercial`

✅ **THE PACKAGE NOW EXISTS: `agent-output/p1-d4-retire-commercial/` (amendment 6). The sentence
this replaces — "This package does not exist on disk, build it at this step" — is superseded.**
Read that directory's `README.md`; it is the authoritative execution order for D4 and it splits
the work into **D4a (deactivate, reversible)** and **D4b (remove, irreversible)**. What follows
in this section is the same content in narrative form, kept as the reviewable record.

| File | Role |
|---|---|
| `apply-d4.js` | The apply mechanism. `node apply-d4.js a` then `node apply-d4.js b`; add `--check` to validate without writing. **TWO-PHASE: every edit is validated in memory, asserting exactly one match each, and NOTHING is written unless ALL of them validate.** ⚠ It was *not* atomic until 2026-08-14 (review C3) — it wrote inside each edit, so a drift on edit 7 of 12 left edits 1–6 on disk, i.e. a half-applied IRREVERSIBLE pass. Pass `b` also now accepts the picklist value in EITHER the active or the deactivated form, so the README's "deactivate in Setup instead / skip the value half" fallback actually works. |
| `d4a-deactivate.diff` / `d4b-remove.diff` | Review artifacts only. **Do not `git apply` them** — they are `diff -u` snapshots of the 2026-08-14 tree and go stale silently; the script fails loudly instead. |
| `destructiveChangesPost.xml` + `package.xml` | The RecordType + BusinessProcess deletion. |

🔴 **The edits below touch FIVE record-type files, not four.** The four from §9 C12 plus the
**transitional fifth**, `Opportunity/recordTypes/Retail`, which carries `Commercial` on purpose
through the D1→D4 window. `Opportunity/recordTypes/Commercial` is not edited — it is deleted
whole.

Everything here is subtractive, which is why it was not pre-applied — the tree must stay
deployable at D1 until the migration is done.

**(a) Remove the `Commercial` value from both `Deal_Type__c` fields.** In
`objects/Lead/fields/Deal_Type__c.field-meta.xml` and
`objects/Opportunity/fields/Deal_Type__c.field-meta.xml`, delete:
```xml
            <value>
                <fullName>Commercial</fullName>
                <default>false</default>
                <label>Commercial</label>
            </value>
```
> The spec's D4 is "deactivate then delete". To deactivate first, set `<isActive>false</isActive>`
> inside the `<value>` block and deploy, then delete in a follow-up. If the deactivate pass is
> skipped, the delete still works — but only because the migration proved zero rows hold the value.
> Confirm that query returned 0 before deleting.

**(b) Remove the `Commercial` enumeration from all FOUR record-type files plus the transitional
fifth.** In each of
`objects/Lead/recordTypes/Acquisition_Broker.recordType-meta.xml`,
`objects/Lead/recordTypes/IR_Investor.recordType-meta.xml`,
`objects/Opportunity/recordTypes/Land.recordType-meta.xml`,
`objects/Opportunity/recordTypes/Retail.recordType-meta.xml`,
inside the `<picklistValues>` block whose `<picklist>` is `Deal_Type__c`, delete:
```xml
        <values>
            <fullName>Commercial</fullName>
            <default>false</default>
        </values>
```
> `Retail.recordType-meta.xml` carries this transitional value on purpose — its own XML comment
> says so. Removing it is part of D4, not an oversight to fix earlier.
> The fifth file, `Opportunity/recordTypes/Commercial.recordType-meta.xml`, is deleted whole in (d).

**(c) Remove `Opportunity.Commercial` visibility from both permission sets.** In
`permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml` and
`permissionsets/DPEG_Admin_Access.permissionset-meta.xml`, delete:
```xml
    <recordTypeVisibilities>
        <recordType>Opportunity.Commercial</recordType>
        <visible>true</visible>
    </recordTypeVisibilities>
```
> Reconcile both files org → repo again first (§2). `DPEG_Admin_Access` in particular was found
> duplicated once already.

**(d) Delete the record type and the business process.** Deleting the files from source is not
enough — a `RecordType` and a `BusinessProcess` need a destructive package. Create:

`manifest/destructiveChangesPost.xml`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>Opportunity.Commercial</members>
        <name>RecordType</name>
    </types>
    <types>
        <members>Opportunity.Commercial</members>
        <name>BusinessProcess</name>
    </types>
</Package>
```
🔴 **The companion `package.xml` is NOT empty — this instruction was wrong until 2026-08-14
(review W4) and the built package now carries the corrected file at
`agent-output/p1-d4-retire-commercial/package.xml`. Use that one; do not re-derive an empty
manifest from an older copy of this section.** `--post-destructive-changes` is correct *because*
`Opportunity.Commercial` must be removed from the two permission sets **in the same run, before**
the record type is deleted — and that only happens if those permission sets are IN the run. With
an empty manifest the run deploys nothing, the org's sets still carry
`<recordType>Opportunity.Commercial</recordType>`, and **the delete is refused**. The manifest
therefore lists all eight files `apply-d4.js b` edits:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>Lead.Deal_Type__c</members>
        <members>Opportunity.Deal_Type__c</members>
        <name>CustomField</name>
    </types>
    <types>
        <members>Lead.Acquisition_Broker</members>
        <members>Lead.IR_Investor</members>
        <members>Opportunity.Land</members>
        <members>Opportunity.Retail</members>
        <name>RecordType</name>
    </types>
    <types>
        <members>DPEG_Acquisition_Edit</members>
        <members>DPEG_Admin_Access</members>
        <name>PermissionSet</name>
    </types>
    <version>67.0</version>
</Package>
```
> ⚠ `Opportunity.Commercial` appears in `destructiveChangesPost.xml` and must **not** also appear
> above. An **empty** manifest is correct in exactly one situation — the second of the two ordered
> commands in the README's split-run fallback, where the eight files were already deployed by the
> first command.

```bash
sf project deploy start --manifest agent-output/p1-d4-retire-commercial/package.xml \
  --post-destructive-changes agent-output/p1-d4-retire-commercial/destructiveChangesPost.xml \
  --target-org usman.khan.dpeg@avanzasolutions.com
```
Then delete the two source files:
`objects/Opportunity/recordTypes/Commercial.recordType-meta.xml`,
`objects/Opportunity/businessProcesses/Commercial.businessProcess-meta.xml`.

> ⚠ **A record type must be INACTIVE before it can be deleted.** Set `<active>false</active>` in
> `Commercial.recordType-meta.xml` and deploy that first, then run the destructive package.
> ⚠ A record type with records still assigned cannot be deleted. The [MIG] query returning 0 is
> the precondition; re-run it immediately before this step, not once at migration time.
> ⚠ There is **no destructiveChanges precedent in this repo** — this is the first. Expect to
> iterate on the manifest.

**[ORG-Q] Verify:**
```sql
SELECT COUNT() FROM Lead        WHERE Deal_Type__c = 'Commercial'
SELECT COUNT() FROM Opportunity WHERE Deal_Type__c = 'Commercial'
SELECT Id, DeveloperName, IsActive FROM RecordType
WHERE SobjectType = 'Opportunity' AND DeveloperName = 'Commercial'
```
First two: 0. Third: **no rows**. Then re-describe both objects and confirm `Commercial` is gone
from `Deal_Type__c.picklistValues` on each.

---

## 4. Post-deploy gates — org state, not deployable, each fails silently

| # | Gate | If missed |
|---|---|---|
| **G3** | **Assign the permission sets.** `PermissionSetAssignment` is not deployable metadata. | 🔴 **PIPELINE-STOPPING, not cosmetic — see the expanded gate below.** A missing FLS grant on `Listing_Status__c` means the field does not render, the validation rule fires anyway, and the analyst is BLOCKED. Untestable by construction. |
| **G4** | **Re-reconcile before the D4 edits** to `DPEG_Acquisition_Edit` and `DPEG_Admin_Access`. | A deploy silently revokes an org-side-only grant. Two incidents on record (2026-08-05, 2026-08-06) plus Finding B above. |
| **G5** | **Set `Retail` as the DEFAULT Opportunity record type, per profile, in Setup — see the expanded gate below.** | New Opportunities keep defaulting to the retired type, or users get a record-type chooser they did not have. |
| **G7** | **Verify `shouldLeadConvertRequireValidation` in Setup**, not in `settings/LeadConfig`. That file is force-ignored, never deploys, and has twice been measured to contradict the org. | The Lead validation rules' behaviour at conversion is the opposite of what was designed. Fails **open**. |
| **G8** | **Re-point reports and dashboards** filtering `Deal_Type__c = 'Commercial'`. Org-side, not fully represented in the repo. | They break silently — they reference by name and do not block the change. |

### G3 expanded — the consequence is a BLOCKED ANALYST, not a blank field

🔴 **This gate's consequence was understated until 2026-08-14 (re-review drift 2). It previously
read "System-mode writes land, the persona sees blanks", and that was accurate only while the new
fields were score DISPLAYS. It has not been true since `Listing_Status__c` joined them.**

The three score fields (`Extraction_Score_Pct__c`, `Fields_Captured_Count__c`,
`Fields_Missing_Count__c`) are written by Apex and are `readOnly` **on the page**, so a missing
FLS grant on those really is cosmetic — the value lands and the persona cannot see it. (They are
nonetheless granted `editable=true` in the Edit/Admin sets; *page* read-only and *FLS* read-only
are different things, and amendment 5 explains why the write grant is a deploy blocker for the
Apex test run.)

**`Listing_Status__c` is different in kind, because a human has to WRITE it.** The failure chain:

1. `Lead_Record_Page` is a Dynamic Forms page, so the field renders only if the persona has FLS.
2. `Deal_Facts_Required_For_Under_Review` blocks `Status = 'Under Review'` while
   `Listing_Status__c` is blank — and **a validation rule reads its fields in SYSTEM context, so
   it fires whether or not the saving user can see them.**
3. `leadMarkUnderReview` writes Status through LDS, so the rule fires on the real UI path.
4. ⇒ the analyst is blocked, with **no field on screen to unblock themselves with**. Every
   pipeline-created Lead strands at `New`.

That is the same outage the `Lead_Record_Page` fix (review C1) and the record-type fix (re-review
C4) each close by a different route. **Three routes, one outage** — field not rendered because the
page omits it (C1), field rendered with zero selectable values because the record type omits it
(C4), field not rendered because the persona has no FLS (this gate). Only the first two are files.

🔴 **AND IT IS UNTESTABLE BY CONSTRUCTION — do not wait for a red test.** No Apex writes
`Lead.Status = 'Under Review'`, so no test reaches the transition; and a `System.runAs` FLS test
against a **system-mode** write cannot fail, because the write is precisely what FLS does not
govern. The org query in §3 P1-A is the only detector. **Run it.**

#### 🔴 THE GATE IS ABOUT EVERY FIELD THE RULE TESTS, NOT JUST THE NEW ONE

`Deal_Facts_Required_For_Under_Review` blocks on `ISBLANK(TEXT(Deal_Type__c))` **OR**
`ISBLANK(TEXT(Listing_Status__c))`. **Both** must be visible AND editable to the persona, or the
analyst is blocked with no on-screen remedy — and `Deal_Type__c` is the *incumbent* field, so it
is the one nobody thinks to check.

**Measured against the repo's permission sets, 2026-08-14** (grep of every
`<fieldPermissions>` element, comments stripped; **E** = editable, **R** = readable only):

| Field the rule tests | `DPEG_Acquisition_Edit` | `DPEG_Acquisition_View` | `Broker_Protection_Access` | `DPEG_Admin_Access` |
|---|---|---|---|---|
| `Lead.Deal_Type__c` | **E** | R | 🔴 **none** | 🔴 **none** |
| `Lead.Listing_Status__c` | **E** | R | E | E |

⇒ **`DPEG_Acquisition_Edit` is the ONLY set in this repo that grants edit on both.** State the
consequences plainly, because each is a different failure:

- **The analyst persona MUST hold `DPEG_Acquisition_Edit`.** Nothing else clears this gate.
- 🔴 **`Broker_Protection_Access` is NOT sufficient on its own for a human.** It grants
  `Listing_Status__c` and **not** `Deal_Type__c`, so a person holding only that set sees the new
  field, fills it, saves, and is still blocked — by a field they cannot see. That is the most
  confusing possible presentation of this gate.
- **`DPEG_Acquisition_View` alone is enough to SEE the block and not to CLEAR it.** Read-only on
  both fields. The org query below will look perfectly healthy for such a user.
- **`DPEG_Admin_Access` not granting `Deal_Type__c` is expected, not a gap to close here.** That
  set exists only to restore what the force-ignored Admin *profile* already grants; `Deal_Type__c`
  predates this pack, and it was added to that set for the new fields only (amendment 5). **Do not
  "fix" it by widening a permission set** — see the pre-existing-asymmetry finding in §2.

**Add `Lead.Deal_Type__c` to the P1-A verification query** so the gap surfaces in the same read
rather than needing a second one — see §3 P1-A. ⚠ It is an *incumbent* field, so it is **not**
part of the 32-row expectation; read it as a separate line.

#### ⚠ AND FLS IS ONLY HALF OF "CAN THE ANALYST SEE IT" — WHICH PAGE THEY GET IS THE OTHER HALF

**PRE-EXISTING and ORG-STATE. Not introduced by this pack, and NOT a file fix — recorded here so
it is not mistaken for one** (re-review W2, measured against the tree 2026-08-14).

`Lead_Record_Page` is assigned in source **exactly once**:
`applications/Acquisition.app-meta.xml` lines 3–11 — a single app-level `<actionOverrides>`,
`<actionName>View</actionName>`, **`<formFactor>Large</formFactor>`**, `<pageOrSobjectType>Lead`.
There is **no org-default and no record-type-scoped assignment in this repo at all**.

Separately: **neither `Deal_Type__c` nor `Listing_Status__c` appears in ANY file under
`layouts/`** — zero hits across all 228 layout files, the four Lead layouts
(`Lead Layout`, `Lead (Sales) / (Marketing) / (Support) Layout`) included.

⇒ Any route that does **not** land on `Lead_Record_Page` — another app, a mobile/small form
factor, a Setup or list-view drill-in that falls back to the org default, a page assignment made
in-org and absent from source — renders **neither field**, while the validation rule fires
**everywhere**, because a VR is org-wide and knows nothing about pages.

**Why this is not fixed here:** the remedy is a page ASSIGNMENT (org state, App Builder →
Activation) or adding the fields to the classic layouts — both outside this pack's scope, and the
assignment half is not deployable in a way this repo can verify. **Treat it as a G3 sibling: check
which Lead page each persona actually receives, on the form factor they actually use, before
declaring P1-A verified.** ⚠ Do not "solve" it by editing `layouts/` — the flexipage is the
designed surface (review C1) and a layout edit would create a second, drifting field list.

---

### G5 expanded — the `Retail` record-type DEFAULT. **NO DEPLOY PERFORMS THIS.**

🔴 **This is the one gate in Phase 1 that no file in this repo can satisfy, at any point in the
sequence, by any deploy.** It is written out in full because "set the default" reads like a
detail and is in fact the difference between the rename working and every new deal landing on a
record type that is about to be deleted.

**Why it cannot be deployed — two independent reasons, either sufficient:**

1. **`PermissionSet.recordTypeVisibilities` has NO `<default>` element.** Only
   `Profile.recordTypeVisibilities` carries `<default>`. Every record-type grant this pack makes
   is on a permission set, so none of them can name a default.
2. **`profiles/**` is `.forceignore`d in this repo.** Even if the profile XML were edited, it
   never deploys — and per the standing rule, a force-ignored file is unverified fiction: it has
   twice been measured to contradict the org.

**When:** immediately after **P1-D1** (so a user creating a deal during the migration window
lands on `Retail`), and re-checked after **P1-D4**. Doing it only at D4 leaves the whole window
defaulting to the outgoing type.

**Where:** Setup → Object Manager → Opportunity → Record Types is *not* where the default lives.
It is **Setup → Profiles → \<profile\> → Record Type Settings → Opportunity → Edit**, per
profile, for **every profile whose users create Opportunities**. Set `Retail` as Default and
confirm `Commercial` is removed from Selected at D4.

**[ORG-Q] Verify — this is queryable even though it is not deployable:**
```sql
SELECT Parent.Profile.Name, RecordType.DeveloperName, IsDefault
FROM ProfileRecordTypeVisibility
WHERE RecordType.SobjectType = 'Opportunity' AND IsDefault = true
```
Every row must read `Retail`. **A row still reading `Commercial` after D4 is the failure**, and
at D4b it also blocks the destructive delete.

**If missed:** before D4, new Opportunities silently keep the `Commercial` record type — so the
`RecordType.DeveloperName = 'Commercial'` count that [MIG] drove to zero starts climbing again,
and D4b's precondition re-arms. Nothing errors; the destructive deploy simply fails later with
"record type in use", or — worse, if the default was silently reassigned by the platform — users
get a record-type chooser they never had before. **This is why the [MIG] queries must be re-run
immediately before D4b rather than trusted from migration time.**

---

## 5. Rollback

| Step | Reversible? | How |
|---|---|---|
| P1-A | yes | Fields are additive and unreferenced by Apex until D2. Remove the `fieldPermissions` blocks and destructively delete the fields. |
| P1-D1 | yes | Wholly additive. Destructively delete the `Retail` record type + business process and remove the `Retail` value. |
| **[MIG]** | **only from the CSVs** | Re-upsert `lead_dealtype_before.csv` / `opp_dealtype_before.csv`. **Take them.** After D4 this is unrecoverable — the target value no longer exists. |
| P1-D3 | yes | Revert the commit. |
| P1-D4 | **NO** | Deleting a picklist value and a record type is not reversible by deploy. Recreating them does not restore row values. This is the point of no return. |

---

## 6. The Lead validation rule

`objects/Lead/validationRules/Deal_Facts_Required_For_Under_Review.validationRule-meta.xml` —
blocks entry to `Under Review` when **`Deal_Type__c` or `Listing_Status__c`** is blank.

> 🔴 **AMENDED 2026-08-14 (amendment 4) — THE PROPERTY ADDRESS LEG IS GONE. USER DECISION.**
> The spec's §2.4 defines a three-fact gate. The third fact is already enforced on the identical
> transition by the live sibling `Property_And_Email_Required_To_Progress`, so a Lead missing only
> the address tripped **both** rules and Lightning showed **two** messages for **one** missing
> field. Salesforce evaluates every active rule on a save and surfaces every failure; two messages
> for one cause is noise that trains an analyst to stop reading them.
>
> **The incumbent was NOT touched** — it is live, has production history, and carries its own
> Email leg. It is also the **stricter** of the two on address: it gates `Qualified` as well as
> `Under Review`.
>
> Post-edit lengths re-checked: `fullName` 36/40, `description` 253/255, `errorMessage` 121/255.

**✅ CLOSED — the `OUTCOME_NO_ADDRESS` clause moved to the incumbent (amendment 8, user decision,
2026-08-14).** Spec §2.4 requires that the blocking message **name the `OUTCOME_NO_ADDRESS` case**
so it reads as the intended chase rather than a pipeline bug. The new rule cannot carry it — it no
longer fires on a blank address, and a message describing a condition the rule does not test is
worse than none. So the clause now lives on the rule that actually fires:

`objects/Lead/validationRules/Property_And_Email_Required_To_Progress.validationRule-meta.xml`

| Element | Change |
|---|---|
| `<errorMessage>` | **the only element edited.** Now: *"Property Address and Email are both required before this lead can move forward. Some leads arrive with no address on purpose - the email named a property but no addressable location - so supplying one here is the intended next step, not a workaround."* **250 / 255 chars.** |
| XML comment | new section recording that this message carries the branch (c) explanation **on behalf of** `Deal_Facts_Required_For_Under_Review`, which deliberately does not test address. Both files cross-reference each other by name. |
| everything else | **untouched.** `errorConditionFormula`, `fullName`, `active`, `description`, `errorDisplayField` all unchanged — verified by diff: exactly one non-comment element differs. |

🔴 **The asymmetry is deliberate and stays: the incumbent gates BOTH `Under Review` AND
`Qualified`, so it is the stricter of the two on `Property_Address__c`.** Do not "harmonise" the
two rules, and **do not re-add an address leg to `Deal_Facts_Required_For_Under_Review`** — that is
what re-creates the double message this closed.

⚠ **Deploy consequence:** `Property_And_Email_Required_To_Progress` is a **live, incumbent rule**
and is now a modified file. It was not previously in any Phase 1 deploy list. **Add it to P1-A**
(or to whichever step first carries `objects/Lead/`), alongside the new rule. A message-only change
needs no migration and no org query — but if it is left out, the pack ships with the branch (c)
explanation written down in the repo and absent from the org, which is exactly the failure mode
this residual existed to prevent.

**Asserted, not assumed: it cannot fire on the inbound pipeline's own Lead insert.** Three
independent guarantees, any one sufficient:

1. **Structural.** `ISCHANGED()` evaluates FALSE in a validation rule on record creation, and it is
   the first term of the top-level `AND()`. Unreachable on any insert. *(Documented platform
   semantics — not probed against this org.)*
2. **Measured against the repo.** Both Lead-creating paths write `Status = 'New'`:
   `EmailToLeadService.cls:298` (`STATUS_NEW`, line 98) and `BrokerPortalService.cls:94`. A
   repo-wide grep finds no Apex that writes `'Under Review'`. Under the staging model the Lead is
   created once, complete, so there is no follow-up pipeline update either.
3. **Precedent.** The incumbent `Property_And_Email_Required_To_Progress` uses the identical
   `ISCHANGED(Status)` + `ISPICKVAL(Status,'Under Review')` shape and has been live throughout the
   pipeline's production history.

**Two open items:**

- ~~**Overlap.**~~ ✅ **RESOLVED by amendment 4** — the address leg was dropped and the double
  message is gone. `Property_And_Email_Required_To_Progress` was not touched. The replacement
  residual (the unowned `OUTCOME_NO_ADDRESS` message) is stated above.
- **Residual, still open.** `Qualified` is not gated by the new rule. The UI path is
  New → Under Review → Qualified, so in practice the gate is reached; a direct API write can
  bypass it. The incumbent does gate `Qualified` for its own fields, so there is in-repo precedent
  for adding it. Not added without a decision.

---

## 7. Handed back — not built here

- ~~**Phase 1 Apex** (developer): extraction scoring against the nine-key denominator, the
  `listing_status` extraction key, `LeadConvertService` carry-forward, `RecordTypeSelector` /
  `LeadConvertService` record-type resolution → `Retail`, and the C13 prompt repoint.~~
  ✅ **BUILT AND ON DISK — reconciled 2026-08-14 (re-review drift 3). This bullet was stale.**
  `ExtractionScoreUtil` / `ExtractionScoreUtilTest` exist; the `listing_status` key is live in
  `ExtractionScoreUtil.cls:138`, `LLMExtractionCalloutService` (EDIT 1) and `PropertyExtraction`;
  `LeadConvertService.cls:269` resolves `{'Land','Retail'}`;
  `LLMExtractionCalloutService.cls:772` emits `Land, Retail`; `OpportunityFunnelController.cls:104`
  filters on `'Retail'`; `TestDataFactory` lines 604/649 stamp `'Retail'`. **The per-item table
  and the `RunLocalTests` failure-scope warning are in §3 P1-D2 — read that before running tests.**
  ⚠ **What is still genuinely owed here is VERIFICATION, not construction:** a green deploy plus
  `RunLocalTests`, which cannot pass until P1-D1 puts `Retail` in the org, and the four test
  classes still asserting on `'Commercial'` (listed in §3 P1-D2) being opened before D4.
- **Phases 2, 3, 4** — out of scope for this runbook.
- ~~**The D4 destructive package** — specified above in full, deliberately not pre-built.~~
  ✅ **BUILT 2026-08-14 (amendment 6): `agent-output/p1-d4-retire-commercial/`.** It is a
  *staged* package, not applied to the tree — the tree stays at D1 state. Its `README.md` is the
  authoritative D4 execution order.
- ~~**One decision owed before P1-A:** the unowned `OUTCOME_NO_ADDRESS` error-message clause (§6).~~
  ✅ **CLOSED 2026-08-14 (amendment 8)** — the clause moved to `Property_And_Email_Required_To_Progress`'s
  `<errorMessage>`. **No Phase 1 decisions remain open in this runbook.**
