# BOV Submission — Broker Contact Lookup

**Design requirements — admin vs. development split**
Produced 2026-08-20 by `salesforce-design`. Target branch: `feature/disposition-redesign` (⚠ see C-0).
Grounded against `ARCHITECTURE.md`, `.claude/rules/apex-layering-rule.md`, `.claude/rules/bulk-test-rule.md`
and a live sweep of `force-app/main/default`.

The decisions in §1 are **already user-confirmed**. This document converts them into an implementable
split and records what the sweep contradicted or added.

---

## §0. CONFLICTS AND ADDITIONS FOUND AGAINST LIVE METADATA

Read this section before §2/§3. Everything else in the brief was verified correct.

### C-0 — Branch mismatch (verify before any file is written)
The task names branch `feature/disposition-redesign`. The working tree's git status at the start of
this session reports **`feature/acquisitions-fsd-tranche-1`**, with four seed scripts already dirty
(`seed-disposition-bulk.apex`, `seed-disposition-offers.apex`, `seed-sell-meter.apex`,
`seed-sell-readiness.apex`). This agent has no shell access and could not re-check.
**Confirm the branch and commit or stash those four files before starting** — one of the files this
change edits is a seed script, and this tree has previously been shared by concurrent sessions.

### C-1 🔴 The label "Contact" is already taken on this object
`BOV_Submission__c.Contact_Name__c` carries `<label>Contact</label>` **today**
(`objects/BOV_Submission__c/fields/Contact_Name__c.field-meta.xml:5`). `Broker_Display__c` carries
`<label>Broker</label>` and `Broker_Firm__c` carries `<label>Broker Firm</label>`.

So of the three names the brief floated, two collide. Salesforce permits duplicate field labels on
one object, but the field picker in reports, Setup, the Dynamic Forms palette and every list-view
column chooser would then show two entries called "Contact" with no way to tell them apart — and
`Contact_Name__c` is *staying in the schema*, only leaving the layout.

**DECISION: label the new field `Broker Contact`.** It is unique on the object, unambiguous next to
`Broker Firm`, and matches the user's mental model ("contact will be a dropdown" → "Broker Contact").

### C-2 🔴 The trigger has no before context — this is the brief's largest omission
`triggers/BovSubmissionTrigger.trigger:13` is:

```apex
trigger BovSubmissionTrigger on BOV_Submission__c (after update) {
```

**After update only.** A before-save stamp cannot run at all until this line changes to
`(before insert, before update, after update)` and `BovSubmissionTriggerHandler` gains
`beforeInsert()` / `beforeUpdate()` overrides. The brief describes the service but never the context
expansion that makes it reachable. Both halves are mandatory; see D-2 and D-3.

Contrast `DispositionTrigger`, which already carries `(before insert, before update, after insert,
after update)` — which is exactly why the sibling service dropped straight in yesterday and this one
will not.

### C-3 ⚠ "Mirror `DispositionBrokerStampService` exactly" is right about the SKELETON and wrong about the BODY
The two problems are not identical, and copying the body produces a bug:

| | `DispositionBrokerStampService` | This service |
|---|---|---|
| Target fields | **ONE** — `Selected_Broker__c` | **TWO** — `Broker_Firm__c`, `Contact_Name__c` |
| Composition | `Name + ' - ' + Broker_Firm__c` via `composeLabel()` | **None.** Straight field-to-field copy |
| `SEPARATOR` constant | Required | **Must not exist** |
| Blank-firm branch | Bare name, no trailing separator | `Broker_Firm__c = null`, `Contact_Name__c = Name` |
| Length proof | 121 + 3 + 120 = 244 ≤ 255 | `Name` ≤ 121 ≤ 255 and `Contact.Broker_Firm__c` Text(**120**) ≤ 255. Independent, both trivially safe |

**Mirror these, verbatim in substance:** the change-keyed detection (`if (d.Broker__c == priorBroker)
continue;`), the two-pass collect-then-assign structure, the single-query-per-chunk budget, the
before-context/`ENTITY_IS_LOCKED` reasoning, the `ContactSelector.selectBrokerLabelsByIds`
(`WITH SYSTEM_MODE`) call, the null-oldMap-on-insert handling, and the "no Contact resolved ⇒ leave
text unchanged" branch.
**Do not mirror:** `SEPARATOR`, `composeLabel`, the 244-character arithmetic, or the record-type /
`visibilityRule` scoping argument (there is no FlexiPage here — see C-6).

### C-4 🔴 The seed guard needs TWO edits, not one — and one of them is a shape change
`scripts/seed-broker-contacts.apex` holds **two** maps, and the brief names only the first:

1. `BROKER_LOOKUPS` (line 209) — four entries. Add `'BOV_Submission__c' => 'Broker__c'`. Straightforward.
2. `STORED_DENORM_TEXT` (line 223) — `Map<String, String>`, **one field per object**. Its header says:
   > *"🔴 DISPOSITION IS THE ONLY ENTRY, AND THAT IS A MEASURED FACT, NOT AN OMISSION. …
   > Broker_Assignment__c.Broker_Name__c / Broker_Firm__c / Broker_Email__c and
   > Lease_Inquiry__c.Broker_Name__c / Broker_Firm__c are all FORMULA fields over Broker__r.*, so they
   > self-heal to blank; Opportunity has no copy."*

   **That measured fact stops being true the moment this field lands.** `BOV_Submission__c.Broker_Firm__c`
   and `Contact_Name__c` are **stored Text(255)**, not formulas — the exact "corruption that reads as
   health" shape the guard exists for, and *worse* than the Disposition case because
   `Broker_Display__c` is a formula over both stored texts, so the comparison matrix would keep
   rendering a deleted broker's firm and name with nothing to notice.

   The map's `Map<String, String>` shape holds one field per object and **cannot express two**.
   Widening it to `Map<String, List<String>>` (and the STEP 2 SELECT-builder, the STEP 4 `row.put`
   loop and the log line at ~350 that read it) is a structural change to the script, not an entry.

3. The header prose says **"FOUR LOOKUPS POINT AT THOSE CONTACTS"** (line 17), lists four by name
   (lines 20-24), and line 208 asserts *"The four below are the complete set in this repo as of
   2026-08-20"*. All three become false. Line 205's banner —
   *"🔴 IF A FIFTH Contact LOOKUP IS EVER ADDED, ADD IT HERE"* — is this change's instruction.

🔴 **GATE (needs a call, do not invent one):** should the `FORCE` path in STEP 4 *blank*
`BOV_Submission__c.Broker_Firm__c` / `Contact_Name__c` the way it blanks `Selected_Broker__c`?
**Design recommends NO — scan and report only.** On Disposition the text is a *derived display copy*
and blanking it makes the record honest. On BOV_Submission__c the text **is the response data**: it is
the matrix's "Broker Firm" and "Contact" columns, and `BovSubmissionTriggerHandler` copies
`Broker_Firm__c` verbatim onto `Disposition__c.Selected_Broker__c` on approval. Blanking it would
destroy the on-market approval stamp to repair an off-market-shaped hazard. Adding the object to
`BROKER_LOOKUPS` alone already gets the analyst a named ORPHAN RISK line per row, which is the point.
If the reviewer disagrees, do the `Map<String, List<String>>` widening; if they agree, item 2 above
reduces to a **header correction only** and the script keeps its current shape.

### C-5 ✅ No selector change and no DTO change are needed — and adding them would be a regression
The brief asks the question; the sweep answers it. All three `BovSubmissionSelector` methods read the
**derived text**, never the lookup:

| Method | Mode | Selects | Needs `Broker__c`? |
|---|---|---|---|
| `selectByDispositionId` | `WITH USER_MODE` | `Broker_Firm__c, Contact_Name__c, …` | **No** |
| `selectSelectedByDispositionId` | `WITH USER_MODE` | `Broker_Firm__c, Contact_Name__c, Submission_Status__c` | **No** |
| `selectStatusesByDispositionId` | `WITH SYSTEM_MODE` | `Broker_Firm__c, Submission_Status__c, Approval_Status__c` | **No** |

The stamp reads `Trigger.new` / `Trigger.oldMap`, which are populated by the platform — it issues no
`BOV_Submission__c` SOQL at all.

🔴 **Adding `Broker__c` to either USER_MODE method would be an FLS change with no consumer.**
`USER_MODE` throws rather than degrades, so on a Metadata-API-deployed field (no FLS for anyone,
System Administrator included) the comparison matrix would show its red error banner for every
persona until the permission-set deploy landed — in exchange for a field nothing reads. Same reasoning
`selectSelectedByDispositionId` already records verbatim for `Approval_Status__c`.

Likewise `BovController.BovRow` must **not** gain a `broker` / `brokerId` member: `bovComparisonMatrix`
renders `brokerFirm` and `contactName` (columns "Broker Firm" and "Contact"), `backupBrokers` renders
`{r.brokerFirm} · {r.contactName}`, and neither needs a Contact Id. **No LWC file changes in this wave.**

### C-6 ✅ The Page Layout is the only UI surface — confirmed
There is **no FlexiPage for `BOV_Submission__c` anywhere in `force-app`** (glob returned nothing;
the layout's own header records the same conclusion). `compactLayoutAssignment` is `SYSTEM`, so there
is no compact layout to update either. Editing the layout is necessary *and sufficient* — including
for the "Add Broker Response" create modal, which renders its inputs from this layout.

### C-7 ✅ No `objectTranslations` file for the new field
`objectTranslations/BOV_Submission__c-en_US/` holds a `fieldTranslation` for 12 fields — but **not**
for `Approval_Status__c`, the object's most recent addition (2026-08-19). Precedent is established:
new fields do not get one. **Do not create one, and do not flag its absence in review.**

### C-8 ⚠ "Dropdown" means a lookup search box, not a picklist
Stated so UAT does not report it as a defect. A `Lookup` with an active filter renders as a
type-ahead search input that drops down matching/recent records — not a fixed-list combobox. This is
the confirmed decision (§1.1: "searchable broker picker, NOT a static picklist"). The alternative
shape — a real combobox built from `ContactSelector.selectBrokersOrderedByName`, as
`BrokerAssignmentController.getBrokerOptions` does — was **not** chosen and is not in scope.

---

## §1. SCOPE AND CONFIRMED DECISIONS

### 1.1 What the user asked for
On the **BOV Submission** layout:
1. Remove the "Broker Selection and Approval" section.
2. Remove the Broker Firm field from data entry.
3. "Contact will be a dropdown."

### 1.2 Confirmed decisions (not open for re-litigation)
| # | Decision |
|---|---|
| D-a | The dropdown is a **Lookup to `Contact`, filtered `Is_Broker__c = true`** — a searchable broker picker. |
| D-b | The firm is **derived from the chosen contact**, never typed. |
| D-c | The derivation is a **before-save Apex stamp** onto the existing `Broker_Firm__c` and `Contact_Name__c` Text fields — **not** a formula, and **not** a repointing of Apex or LWCs. |
| D-d | **Additive.** `Broker_Firm__c` / `Contact_Name__c` remain in the schema and remain populated. Nothing is retired. |

### 1.3 Why D-c keeps every consumer working unchanged
Six consumers read the two Text fields today. All six keep working with **zero code change**, because
the fields keep being populated — only the *writer* changes from a human to the stamp:

| Consumer | Reads | Change |
|---|---|---|
| `BovSubmissionTriggerHandler` (approval → parent stamp) | `Broker_Firm__c` | none |
| `BovSubmissionService.replaceSelectedBroker` | `challenger.Broker_Firm__c` | none |
| `Broker_Display__c` formula (`Broker_Firm__c & " — " & Contact_Name__c`) | both | none |
| `BovController` → `BovRow.brokerFirm` / `.contactName` | both | none |
| `lwc/bovComparisonMatrix`, `lwc/backupBrokers` | both, via the DTO | none |
| `DispositionStageEntryService` → `Broker_Listing__c.Broker_Firm__c` | indirectly, via `Disposition__c.Selected_Broker__c` | none |

### 1.4 Explicitly OUT OF SCOPE (stated, per the brief)
- Retiring `BOV_Submission__c.Broker_Firm__c` or `Contact_Name__c`.
- Any change to `Broker_Listing__c`.
- The on-market / off-market gate logic.
- Any change to `Disposition__c.Broker__c` or `DispositionBrokerStampService`.
- A validation rule on the new lookup. (`Disposition__c` has
  `validationRules/Broker_Lookup_Is_Off_Market_Only`; **nothing analogous was requested here and none
  should be added.** Noted only so its absence is not read as an oversight.)
- Widening `Disposition_Dashboard_Access` (it grants `Broker_Display__c` / `Property_Name__c` read-only;
  both keep working because the underlying Text fields stay populated).
- Any backfill of existing `BOV_Submission__c` rows. See R-3.

---

## §2. 🔵 ADMIN WORK (`salesforce-admin`)

Three files. Metadata only — **do not deploy**; DevOps owns that.

### A-1 — New field: `BOV_Submission__c.Broker__c`
**Path:** `force-app/main/default/objects/BOV_Submission__c/fields/Broker__c.field-meta.xml` *(new)*

| Property | Value | Justification |
|---|---|---|
| `fullName` | `Broker__c` | `ARCHITECTURE.md` §1 role-named-lookup exception. All four existing Contact lookups in this org use exactly this name (`Broker_Assignment__c`, `Disposition__c`, `Lease_Inquiry__c`, `Opportunity`). |
| `type` | `Lookup` | D-a |
| `referenceTo` | `Contact` | D-a |
| `label` | **`Broker Contact`** | **C-1** — "Contact" and "Broker" are both already taken on this object. |
| `deleteConstraint` | `SetNull` | Matches all four siblings. `Restrict` was considered and rejected org-wide — see the XML comment in `objects/Disposition__c/fields/Broker__c.field-meta.xml`. The guard belongs in the seed script (A-3). |
| `relationshipName` | **`Brokered_BOV_Submissions`** | Verified non-colliding: the only custom Contact child relationships are `Broker_Assignments`, `Brokered_Dispositions`, `Lease_Inquiries`, `Brokered_Opportunities`. Follows the `Brokered_*` pattern the two other `Broker__c`-on-a-deal lookups use. |
| `relationshipLabel` | `Brokered BOV Submissions` | matches |
| `required` | `false` | Legacy rows have no broker; a required field would refuse every existing-record save. |
| `trackHistory` / `trackTrending` | `false` | `enableHistory` is `false` on the object. |

**`lookupFilter` — copy the shape from `Broker_Assignment__c.Broker__c` verbatim:**
```xml
<lookupFilter>
    <active>true</active>
    <booleanFilter>1</booleanFilter>
    <errorMessage>The selected Contact is not flagged as a broker (Is_Broker__c).</errorMessage>
    <filterItems>
        <field>Contact.Is_Broker__c</field>
        <operation>equals</operation>
        <value>True</value>
    </filterItems>
    <isOptional>false</isOptional>
</lookupFilter>
```
That `errorMessage` string is byte-identical in `Broker_Assignment__c.Broker__c` and
`Disposition__c.Broker__c`. Keep it identical here.

Include a `<description>` and `<inlineHelpText>` following `Disposition__c.Broker__c`'s pattern —
inline help must say the firm and contact name fill in automatically and must not be typed.
⚠ Both are capped at **255 characters** and only a deploy catches an overrun.

### A-2 — Page Layout edit
**Path:** `force-app/main/default/layouts/BOV_Submission__c-BOV Submission Layout.layout-meta.xml`

| Section | Action |
|---|---|
| **Information** | `Name` (Readonly) · `Disposition__c` (Edit) · **`Broker__c` (Edit)** · `Submission_Status__c` (Edit) · `OwnerId` (Edit). **Remove `Broker_Firm__c` and `Contact_Name__c` entirely.** |
| **BOV Terms** | unchanged |
| **Broker Selection and Approval** | 🔴 **delete the whole `<layoutSections>` block** (`Broker_Display__c`, `Property_Name__c`, `Selected_Broker__c`, `Approval_Status__c` — all four are formulas or approval-written, so hiding them changes no behaviour) |
| **System Information** | unchanged (`CreatedById`, `LastModifiedById`) |
| unlabeled `CustomLinks` section | unchanged |

🔴 **The `<relatedLists>` block carrying `RelatedProcessHistoryList` MUST SURVIVE VERBATIM.** It is
the only route to Recall Approval Request on this object (code review C-3, 2026-08-19), and
`Broker_Finalize_Approval` sets `allowRecall=true` + `recordEditability=AdminOnly`. Losing it strands
every submitted BOV.

⚠ **The explanatory XML comment must stay INSIDE `<Layout>`.** A comment above the root element breaks
`sf` at source conversion with a misleading "unable to find matching parent xml file" error — the
existing comment says so at lines 3-5. Extend it in place; record why the section was removed and why
the two Text fields left the layout but stayed in the schema.

⚠ `Broker__c` is a Lookup, so `behavior=Edit` is legal. (The four fields being deleted could not have
been `Edit` — formula fields with `behavior=Edit` fail the deploy outright.)

### A-3 — Permission sets (surgical, additive, diffed against HEAD)
**Paths:**
- `force-app/main/default/permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml`
- `force-app/main/default/permissionsets/DPEG_Disposition_View.permissionset-meta.xml`

| Permission set | `editable` | `readable` |
|---|---|---|
| `DPEG_Disposition_Edit` | `true` | `true` |
| `DPEG_Disposition_View` | `false` | `true` |

**Measured grant matrix — these two sets are the complete list.** They are the only permission sets
in the repo granting any `BOV_Submission__c` business field (`Broker_Firm__c`, `Contact_Name__c`,
`Disposition__c` are each granted in exactly these two).
`Disposition_Dashboard_Access` grants only `Broker_Display__c` and `Property_Name__c`, both read-only
formulas that keep evaluating — **do not touch it**.
`DPEG_Admin_Access` grants no `BOV_Submission__c` field today, so **a bare administrator already cannot
read this object's business fields; this change creates no new admin regression and
`DPEG_Admin_Access` must not be widened to fix a problem it does not have.**

🔴 **A Metadata-API-deployed custom field arrives with NO field permissions for ANY profile, System
Administrator included.** Until A-3 deploys, `Broker__c` is invisible and unwritable to everyone —
which is why A-1, A-2 and A-3 land together (see §4).

⚠ **A `PermissionSet` deploy REPLACES the file's entire `fieldPermissions` collection.** Insert the
two new `<fieldPermissions>` blocks into the existing files in alphabetical position and **diff the
result against `HEAD`** before handing off. A regenerated file drops every grant it did not re-emit —
this has already caused one live outage on this project. Do not regenerate; edit.

⚠ **Contact object access is a separate, pre-existing condition.** The picker needs read on `Contact`
to search. `DPEG_Junior_Analyst_PSG` pairs `DPEG_Disposition_Edit` with `DPEG_Contact_Edit`, and
`DPEG_Principal_PSG` pairs `DPEG_Disposition_View` with `DPEG_Contact_View`, so the real personas are
covered. A user holding `DPEG_Disposition_Edit` *directly*, with no Contact set, would see an empty
picker — **exactly the same exposure `Disposition__c.Broker__c` already carries.** Stated, not fixed;
no new grant is in scope.

---

## §3. 🟢 DEVELOPMENT WORK (`salesforce-developer`)

### D-1 — New service: `BovBrokerStampService`
**Path:** `force-app/main/default/classes/BovBrokerStampService.cls` *(+ `.cls-meta.xml`, API 67.0)*
*(Name is 21 chars; test class 25 — both clear of the 40-char cap. Listed in §6 as an open naming item.)*

```apex
public with sharing class BovBrokerStampService {
    public static void stampBrokerFields(
        List<BOV_Submission__c> newSubmissions,
        Map<Id, BOV_Submission__c> oldMap
    )
}
```

`layer=service`. **Zero inline SOQL, zero DML.** Mutates `newSubmissions` in place, returns void.

**Behaviour — the four outcomes, keyed on `Broker__c` CHANGING:**

| `Broker__c` | Result |
|---|---|
| **unchanged** | Record skipped **entirely**. Neither Text field is read, written or considered. 🔴 This is the branch that structurally protects every other writer — see D-4. |
| **cleared to null** | `Broker_Firm__c = null` **and** `Contact_Name__c = null`, in the same save. *(Recommended for symmetry with the sibling: a row with no broker lookup must not keep displaying a broker's name in the matrix. Counter-argument, stated so it can be overruled: on this object the text is response data, not a display copy. If the reviewer prefers "leave unchanged on clear", that is a one-line change — but say so in the class header, do not leave it implicit.)* |
| **set, Contact resolved** | `Contact_Name__c = broker.Name`; `Broker_Firm__c = broker.Broker_Firm__c` (**null when the Contact's firm is blank** — no placeholder, no separator). |
| **set, Contact NOT resolved** | **Both fields left UNCHANGED.** Covers "row not visible under sharing" and "row deleted between the pick and this save" identically — both mean "I cannot author a truthful value", and a stale value beside a visible lookup is self-healing on the next successful save. Blanking is the more destructive direction. |

**Structure (mirror the sibling):**
- Null/empty-safe guard, return immediately.
- **Pass 1 — detect.** `Disposition__c`-style change test:
  `Disposition prior = (oldMap == null || s.Id == null) ? null : oldMap.get(s.Id);` then
  `if (s.Broker__c == priorBroker) continue;`. On insert `oldMap` is null, so being *created* with a
  broker counts as a change and being created without one costs nothing.
- Early return when nothing changed → **zero queries**.
- **One** call to `ContactSelector.selectBrokerLabelsByIds(brokerIds)` for the whole chunk. It already
  returns `Id, Name, Broker_Firm__c` `WITH SYSTEM_MODE` — **reuse it as-is; do not add a method and do
  not add an `Is_Broker__c` filter** (the active non-optional lookup filter already guarantees
  eligibility, and re-testing it would silently no-op a later-unflagged Contact).
- Skipped entirely when every changed record merely *cleared* its broker → a bulk clear also costs zero queries.
- **Pass 2 — assign.** In-memory only.

**Class header must argue, in the sibling's style:**
- **Why before-context.** `Broker_Finalize_Approval` sets `recordEditability = AdminOnly` on this
  object, so any post-save second DML against a submission with a pending approval throws
  `ENTITY_IS_LOCKED`, and a Queueable does not fix it (a pending approval outlives the job). An
  in-memory assignment inside the save the user was already permitted to make costs zero DML and no
  lock can refuse it. Same shape as `DispositionStageEntryService.stampListingDates`.
- **Why a service, not handler-inline.** The stamp needs a Contact SOQL read;
  `.claude/rules/apex-layering-rule.md` prohibits SOQL in a TriggerHandler and in a Domain.
  ⚠ `BovSubmissionTriggerHandler`'s own header sets a precedent for keeping trivial logic in the
  handler — and explicitly conditions it on *"ZERO inline SOQL"*, which this does not satisfy.
- **Length is proven, not truncated.** `Contact.Name` ≤ 121, `Contact.Broker_Firm__c` is Text(**120**);
  both targets are Text(255). **No truncation logic; do not add `left(255)`** — dead code that would
  silently start mattering if someone widened a source field. Re-do the arithmetic here if either is widened.
- **The rename blind spot.** Keyed on `Broker__c` changing, so editing the same broker Contact's own
  `FirstName` / `LastName` / `Broker_Firm__c` never fires this trigger and leaves both Text fields
  stale until the next save that actually changes `Broker__c`. No mitigation today; named so it is not
  rediscovered as a surprise. (Verbatim the same limitation the sibling records under code review W5.)
- **Budget contract.** *At most 1 SOQL and exactly 0 DML per chunk — constant in the number of
  submissions.* A chunk in which no record changed `Broker__c` costs zero queries.
- **FLS.** A before-trigger field assignment is an in-memory SObject mutation and is **not**
  FLS-checked, so a persona without EDIT on the two Text fields still gets the stamp. A missing grant
  makes the value invisible to that persona; it does not disable the stamp.
- **Sharing.** `with sharing`. `SYSTEM_MODE` on the selector read lifts CRUD/FLS and **never** sharing;
  an unreadable Contact correctly falls into the "leave unchanged" branch. **Do not add a
  `without sharing` inner class.**

### D-2 — Trigger context expansion (C-2)
**Path:** `force-app/main/default/triggers/BovSubmissionTrigger.trigger`

```apex
trigger BovSubmissionTrigger on BOV_Submission__c (before insert, before update, after update) {
    new BovSubmissionTriggerHandler().run();
}
```
One line changes. Keep it the only `BOV_Submission__c` trigger. **Extend the file's existing header
comment** — it currently argues *why* the trigger is after-update-only ("⚠ AFTER UPDATE ONLY, AND THAT
IS A CONSEQUENCE OF WHICH RECORD IS LOCKED"). That statement becomes false; correct it **in place**
rather than deleting it, and explain that the before contexts exist for the broker stamp on the
record being saved, for the *same* lock reason stated from the other direction.

### D-3 — Handler routing
**Path:** `force-app/main/default/classes/BovSubmissionTriggerHandler.cls`

Add two overrides. `TriggerHandler` already provides empty virtuals for all seven contexts, so no base
class change is needed.

```apex
protected override void beforeInsert() {
    BovBrokerStampService.stampBrokerFields((List<BOV_Submission__c>) newList, null);
}

protected override void beforeUpdate() {
    BovBrokerStampService.stampBrokerFields(
        (List<BOV_Submission__c>) newList, (Map<Id, BOV_Submission__c>) oldMap);
}
```
`afterUpdate()` and `handleApprovedSelections` are **untouched**.

Add a **LAYERING** paragraph to the class header noting that the handler now routes to a Service for
the before contexts while keeping its own logic in `afterUpdate` — and that this is *consistent with*,
not a violation of, the existing "trivial logic stays in the handler" precedent, because that
precedent is conditioned on zero inline SOQL and the stamp needs a Contact read.

### D-4 — Why the new before contexts cannot collide with anything (state in the headers)
The change-keyed guard is a **structural** guarantee, not a timing one. Every other writer of this
object leaves `Broker__c` untouched, so each re-enters the stamp and is skipped:

| Writer | Writes | `Broker__c` touched? | Result |
|---|---|---|---|
| `workflows/BOV_Submission__c` → `Set_Broker_Approval_Approved` / `_Rejected` | `Approval_Status__c` | no | skipped |
| `BovSubmissionService.replaceSelectedBroker` (`Database.update(writes, true, AccessLevel.SYSTEM_MODE)`) | `Submission_Status__c`, `Approval_Status__c` | no | skipped |
| `TestDataFactory.createBovSubmissions` | both Text fields directly, **never `Broker__c`** | no | skipped |
| Analyst editing terms, score or status | BOV Terms fields | no | skipped |

🔴 **The `TestDataFactory` row is why every existing BOV test stays green by construction.** The
factory sets `Broker_Firm__c = 'Test Brokerage ' + i` and `Contact_Name__c = 'Test Broker ' + i` and
leaves `Broker__c` null — so on insert `null == null` is "unchanged" and the stamp never overwrites
the fixture. **Do not change `TestDataFactory.createBovSubmissions`**; tests needing a broker override
`Broker__c` themselves using `TestDataFactory.createBrokerContact(s)` (the lookup filter is active and
non-optional, so a plain `createContacts()` Contact will be refused).

⚠ Where they *would* collide, the stamp wins, and that is correct: a before trigger sees final field
values. A single save that both changed `Broker__c` and hand-typed a firm ends with the stamp. Say so
in the header so nobody re-derives it.

### D-5 — Test class: `BovBrokerStampServiceTest`
**Path:** `force-app/main/default/classes/BovBrokerStampServiceTest.cls`

`.claude/rules/bulk-test-rule.md`'s 251-record mandate **applies in full — no exemption to claim.**
This is a trigger path that loops over a collection; the per-transaction-singleton exemption does not
apply, and `.claude/rules/content-publication-rule.md` is irrelevant (no content object).
`TestDataFactory` only, never `SeeAllData=true`. 90%+ coverage. `BULK_N = 251` as a named constant.

**Required falsifiers** — the same set `DispositionBrokerStampServiceTest` carries, adjusted for two
target fields:

| # | Test | Pins |
|---|---|---|
| 1 | `nullOrEmptyList_returnsWithoutError` | null/empty contract |
| 2 | `insertWithBroker_stampsBothFields` | `Contact_Name__c == broker.Name` **and** `Broker_Firm__c == broker.Broker_Firm__c` |
| 3 | `insertWithBroker_blankFirm_stampsNameAndLeavesFirmNull` | no placeholder, no separator artefact |
| 4 | `updateBrokerChangeFromAToB_restampsBothFields` | both fields move together |
| 5 | 🔴 **`updateThatDoesNotTouchBroker_leavesBothTextFieldsUnchanged`** | **the load-bearing one.** Hand-set both Texts, then save a change to an unrelated field (e.g. `BOV_Amount__c`); both must survive byte-for-byte. This is what protects the analyst's other edits and every writer in D-4. |
| 6 | `updateWithBrokerUnchangedNonNull_handSetTextSurvivesAndCostsZeroQueries` | the skip branch costs no query even when a broker *is* set |
| 7 | `updateClearsBrokerToNull_nullsBothTextFieldsInTheSameSave` | pins whichever clear-behaviour D-1 lands on — **update this test if that decision is overruled** |
| 8 | `insertWithoutBroker_costsZeroQueriesAndLeavesTextNull` | an ordinary insert is free |
| 9 | `brokerSetButContactUnresolvable_leavesBothTextFieldsUnchanged` | absent-key branch; "leave unchanged", not "blank" |
| 10 | `maxLengthValues_saveUntruncated` | `Name` at 121 and `Broker_Firm__c` at 120 both land whole in Text(255) |
| 11 | **BULK** `bulkInsert251WithBroker_allStampedThroughTheRealTrigger` | 251 rows via real DML, all stamped |
| 12 | **BULK** 🔴 `bulk251BrokerChanges_costsExactlyOneQueryForTheWholeChunk` | **assert a CONSTANT query budget — exactly 1 — not merely "251 rows produced 251 stamps".** Constancy is the property that makes a future per-record query fail *here* instead of in production. |
| 13 | **BULK** `bulk251NoRecordChangesBroker_costsNothing` | zero queries, zero DML on the common path |
| 14 | `existingRowWithTextButNoBroker_survivesAnUnrelatedUpdate` | the legacy-data guarantee behind R-3 |

⚠ Capture query counters **inside** the save context where the assertion is about the trigger path;
`Test.stopTest()` restores pre-test counters, so the obvious post-`stopTest` assertion is silently
vacuous. Mirror how `DispositionBrokerStampServiceTest` does it.

⚠ Broker Contacts must come from `TestDataFactory.createBrokerContact(s)` — see D-4.

### D-6 — Seed-script guard
**Path:** `scripts/seed-broker-contacts.apex`

Per **C-4**. At minimum: add `'BOV_Submission__c' => 'Broker__c'` to `BROKER_LOOKUPS` (line 209) and
correct the header prose at lines 17, 20-24 and 208 from "four" to "five". The `STORED_DENORM_TEXT`
question is a gate, not an assumption — see C-4.

The script is describe-guarded and dynamic (`Schema.getGlobalDescribe()` + `Database.query`) precisely
so a not-yet-deployed field is *reported and skipped* rather than breaking compilation in a fresh
scratch org. The new entry inherits that for free — **do not convert any of it to static SOQL.**

---

## §4. EXECUTION ORDER AND ACCEPTANCE

### 4.1 Ordering (dependencies are real, not stylistic)

| Step | Item | Depends on |
|---|---|---|
| 1 | **A-1** field + **A-3** permission sets + **A-2** layout — authored and deployed **as one unit** | — |
| 2 | **D-1** service | A-1 (the field must exist for `Broker__c` to compile) |
| 3 | **D-2** trigger + **D-3** handler | D-1 |
| 4 | **D-5** tests | D-1 – D-3 |
| 5 | **D-6** seed guard | A-1 (only for a *live* run; the file itself can be edited any time) |

🔴 **Step 1 is atomic and Apex never goes first.** A field deployed without its FLS is invisible to
every persona including System Administrator; Apex deployed before the field fails to compile; a
layout referencing a field that does not exist fails the deploy.

🔴 **Within step 1, `sf` must deploy the field before the permission sets** in dependency order — the
CLI handles this within a single `project deploy start`, which is the argument for making it one deploy
rather than three.

⚠ Before deploying, **diff both permission-set files and the layout against `HEAD`.** This working
tree has previously been shared by concurrent sessions and hub files (permission sets, layouts,
FlexiPages) have silently become the union of two features.

### 4.2 Acceptance criteria

1. 🎯 **The primary criterion, verbatim from the brief:** on a Disposition at BOV Outreach, click
   **Add Broker Response** in `bovComparisonMatrix` → the create modal shows **Broker Contact** as a
   searchable picker and shows **no** Broker Firm or Contact input → pick a broker → Save → the
   **comparison matrix still shows the firm under "Broker Firm" and the person under "Contact."**
2. The create modal's **Disposition** field is pre-populated from `encodeDefaultFieldValues` (this is
   a live open question the layout's own header flags — confirm, do not assume).
3. Typing a non-broker Contact's name into the picker returns no match; forcing one via API is refused
   with *"The selected Contact is not flagged as a broker (Is_Broker__c)."*
4. The BOV Submission detail page shows **no** "Broker Selection and Approval" section, and **Approval
   History still renders** with a working **Recall Approval Request** on a submitted record.
5. Changing the Broker Contact on an existing submission re-derives both values on save; changing an
   unrelated field (e.g. BOV Amount) leaves them untouched.
6. **Open the page as an administrator** as well as as an analyst. An analyst-only smoke test never
   catches a permission-set gap.
7. Approve a Selected submission through `Broker_Finalize_Approval` → parent Disposition advances
   BOV Outreach → Broker Selection and `Selected_Broker__c` shows the firm. (Regression: proves the
   new before contexts did not disturb `afterUpdate`.)
8. `sf apex run test --class-names BovBrokerStampServiceTest BovSubmissionTriggerHandlerTest
   BovSubmissionServiceTest BovControllerTest BovSubmissionSelectorTest` — all green.
9. `sf apex run test --test-level RunLocalTests` — no new failures. *(Expected to be clean by
   construction; see D-4.)*

---

## §5. RISKS

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| **R-1** | Field deploys without FLS → invisible to everyone, admins included; or the permission-set edit is *regenerated* and drops unrelated grants (one live outage already on this project). | 🔴 High | A-3 additive + diffed against `HEAD`; deployed atomically with A-1/A-2 (§4.1). |
| **R-2** | `BROKER_LOOKUPS` not updated → a `seed-broker-contacts.apex` re-run silently nulls `Broker__c` on every BOV Submission, and the stored Texts survive → the matrix keeps showing a deleted broker with nothing to notice. | 🔴 High | D-6. The script's own line 205 banner is the instruction. |
| **R-3** | Existing `BOV_Submission__c` rows have Text values and a null `Broker__c`. | 🟢 Low — **by design** | Change-keyed detection means those rows are skipped forever; the matrix keeps rendering them. **No backfill is in scope** and none is needed. Pinned by test 14. |
| **R-4** | Contact **rename** blind spot: editing a broker's own name or firm never fires this trigger, so both Text fields go stale until the next save that changes `Broker__c`. | 🟡 Medium | **No mitigation in this wave.** Identical to the accepted limitation on `Disposition__c` (code review W5). Named in the class header so it is not rediscovered as a bug. |
| **R-5** | Adding before contexts to a trigger that had none makes it fire on **every** `BOV_Submission__c` insert and update in the org. | 🟡 Medium | The zero-cost early return (D-1) and the D-4 writer table. Tests 6, 8, 13 assert the free path directly. |
| **R-6** | An analyst can no longer record a contact name that differs from the chosen Contact's `Name` (e.g. an assistant, or a firm-only response with no named person). | 🟡 Medium | **Accepted consequence of D-b**, stated so it is not discovered in UAT. A firm-only response is still expressible: pick a Contact whose `Broker_Firm__c` is set — the blank-firm branch and its inverse are both handled. If the business needs a free-text override, that is a future wave. |
| **R-7** | `STORED_DENORM_TEXT`'s `Map<String, String>` shape cannot hold two fields per object; a partial edit could look done and behave wrongly on `FORCE`. | 🟡 Medium | C-4 makes it an explicit gate with a recommendation, not an assumption. |
| **R-8** | Concurrent-session drift in this working tree (four seed scripts already dirty; branch may not be `feature/disposition-redesign`). | 🟡 Medium | C-0 + the pre-deploy diff in §4.1. |
| **R-9** | Someone hits `QueryException: No such column` after deploy and reaches for `WITH SYSTEM_MODE`. | 🟡 Medium | 🔴 **The fix is a permission set, every time.** No `BovSubmissionSelector` USER_MODE query is being widened by this change (C-5); if one throws, the cause is a *missing grant*, not the mode. Say so in review. |

---

## §6. OPEN NAMING ITEMS (flagged, not invented)

The implementing agent picks one spelling and uses it consistently. Suggested spellings are given;
none is a decision the user has made.

| Item | Suggested | Notes |
|---|---|---|
| Service class | `BovBrokerStampService` | 21 chars. Mirrors `DispositionBrokerStampService`'s naming. `BovSubmissionBrokerStampService` (31) also fits but reads long. |
| Service method | `stampBrokerFields` | Plural "Fields" because two are stamped — deliberately *not* `stampBrokerLabel`, which would imply the sibling's single composed string. |
| Test class | `BovBrokerStampServiceTest` | 25 chars, must track whatever the service is called. |
| `relationshipName` | `Brokered_BOV_Submissions` | Verified non-colliding. `BOV_Submissions` is also free on `Contact` (the existing `BOV_Submissions` is a child relationship of `Disposition__c`, a different parent) but breaks the `Brokered_*` pattern. |
| Field label | **`Broker Contact`** | Not an open item — **decided** in C-1, because both alternatives collide with live labels. Recorded here for visibility. |

---

## §7. FULL FILE MANIFEST

**New (3)**
- `force-app/main/default/objects/BOV_Submission__c/fields/Broker__c.field-meta.xml`
- `force-app/main/default/classes/BovBrokerStampService.cls` (+ `.cls-meta.xml`)
- `force-app/main/default/classes/BovBrokerStampServiceTest.cls` (+ `.cls-meta.xml`)

**Modified (6)**
- `force-app/main/default/layouts/BOV_Submission__c-BOV Submission Layout.layout-meta.xml`
- `force-app/main/default/permissionsets/DPEG_Disposition_Edit.permissionset-meta.xml`
- `force-app/main/default/permissionsets/DPEG_Disposition_View.permissionset-meta.xml`
- `force-app/main/default/triggers/BovSubmissionTrigger.trigger`
- `force-app/main/default/classes/BovSubmissionTriggerHandler.cls`
- `scripts/seed-broker-contacts.apex`

**Deliberately NOT modified** — stated so their absence is not read as an omission:
`BovSubmissionSelector.cls`, `BovController.cls`, `ContactSelector.cls`, `TestDataFactory.cls`,
`lwc/bovComparisonMatrix/*`, `lwc/backupBrokers/*`, `objectTranslations/BOV_Submission__c-en_US/*`,
`permissionsets/Disposition_Dashboard_Access.permissionset-meta.xml`,
`objects/BOV_Submission__c/BOV_Submission__c.object-meta.xml`,
`classes/DispositionBrokerStampService.cls`, `objects/Disposition__c/fields/Broker__c.field-meta.xml`.
