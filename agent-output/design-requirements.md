# Design Requirements — Broker definition moves from `Contact.Is_Broker__c` to the `Contact.Broker` record type

**Date:** 2026-08-20
**Branch:** `feature/disposition-redesign`
**Design agent run:** requirements analysis only. No metadata, Apex, or scripts were modified.

---

## 🎯 What the user requested (verbatim)

> "Derek Simmons is my contact broker but on adding BOV response when I click on broker contact then it doesn't populate any broker. We don't have to validate on checkbox instead we have a record type on Contact — we need to validate from that."

**Confirmed scope (settled with the user before this run — not re-opened here):**

1. Scope is **all 6 lookup filters + all Apex** — one consistent definition of "broker", in one change.
2. `Contact.Is_Broker__c` **stays in place, unused**. No delete, no backfill, no layout/permission-set removal. Additive rule: add → repoint → retire later.
3. The 6 Master-record-type Contacts and the 3 duplicate "Derek Simmons" rows are **reported, not fixed**.

---

## 🔴 SECTION 0 — CONTRADICTED PREMISES (read before anything else)

The brief was right about the concept and right about most of the inventory. It is **wrong or stale on four material points**, two of which materially change the size and the sequencing of the work.

### 0.1 🔴 `TestDataFactory` ALREADY stamps the `Contact.Broker` record type. The brief's central test-fallout claim is false.

The brief states:

> "`TestDataFactory.createBrokerContacts` (line ~623) sets `Is_Broker__c = true`. ~15 test classes depend on it… Once the filters move to record type, every one of those tests fails at DML unless the factory stamps the Broker record type."

**Measured — `TestDataFactory.cls:580-585`, inside `createContacts` (not `createBrokerContacts`):**

```apex
Id brokerRt = recordTypeId(Contact.SObjectType, 'Broker');
if (brokerRt != null) {
    for (Contact c : contacts) {
        c.RecordTypeId = brokerRt;
    }
}
```

`createBrokerContacts` delegates to `createContacts` (`:621`), so **every Contact the factory produces already carries the Broker record type**. Independent proof inside the suite itself: `ContactSelectorTest.selectByEmails_251DistinctEmailsWithAccounts_returnsAll` (`:535-547`) builds its 251 rows with plain `createContacts(...)` and asserts all 251 come back from `selectByEmails`, which **already filters `RecordType.DeveloperName = 'Broker'`**. That test could not pass if the factory left the record type unset.

**⇒ The mass test-migration the brief priced does not exist.** The factory needs **no change** for the happy path. Two narrower, real problems replace it — see 0.2 and 3.2.

### 0.2 🔴 The real test risk is the opposite one: the factory's record-type stamp is *conditional*, and it silently degrades

`recordTypeId()` (`TestDataFactory.cls:324-329`) returns **null** when `!info.isAvailable()` for the running user, and the caller then leaves `RecordTypeId` unset — deliberately, and documented at length at `:270-322` after a live `INVALID_CROSS_REFERENCE_KEY` reproduction.

Consequence under the new definition: inside `System.runAs(<persona without Contact.Broker record-type visibility>)`, the factory produces a **Master**-record-type Contact. Today that Contact still satisfies the `Is_Broker__c` filter (the factory sets the checkbox unconditionally). **Under a record-type filter it will be refused at DML** with `FIELD_FILTER_VALIDATION_EXCEPTION`.

Measured grant matrix for `Contact.Broker` `recordTypeVisibilities`:

| Permission set | Grants `Contact.Broker`? |
|---|---|
| `DPEG_Contact_Edit` (`:91`) | ✅ |
| `DPEG_Contact_View` (`:91`) | ✅ |
| `DPEG_Admin_Access` (`:482`) | ✅ |
| `Lead_Stage_Actions_Access` (`:82`) | ✅ |
| `DPEG_Disposition_Edit` / `DPEG_Disposition_View` | ❌ |
| `DPEG_Acquisition_Edit` / `DPEG_Acquisition_View` | ❌ |
| `Broker_Protection_Access` | ❌ |

⚠ Note `profiles/**` is **force-ignored** (`.forceignore:28`), so permission sets are the only real source of record-type visibility here. Any `runAs` test whose persona is granted only a Disposition/Acquisition set and which then creates a broker Contact is a **new** failure introduced by this change. This is a targeted audit, not a factory rewrite.

### 0.3 🔴 The `seed-broker-contacts.apex` guard is ALREADY IMPLEMENTED. The brief calls it "unimplemented".

The brief states line 4 is `delete [SELECT Id FROM Contact WHERE Is_Broker__c = true];` and that the guard is open. **Both are stale.**

Measured: line 4 is a doc comment. The destructive delete was hoisted out of the inline `delete [SELECT ...]` into a 6-step structure with a working guard:

- **STEP 1** (`:337`) — hoisted `WHERE Is_Broker__c = true` query, capped, reporting the doomed roster.
- **STEP 2** (`:349`) — read-only scan of **all five** referencing lookups, before any DML.
- **STEP 3** (`:504-511`) — abort gate; `final Boolean FORCE = false;` (`:255`). A truncated scan aborts and **`FORCE` cannot override it** (`:480-489`).
- **STEP 4** — repairs `FORCE_CLEARS_DENORM = { 'Disposition__c' }` (`:315`) before the delete.
- **STEP 5** — the actual delete.

The field-XML headers that call the guard "still OPEN" (e.g. `Disposition__c/fields/Broker__c.field-meta.xml:118-119`) are **out of date relative to the script**. This is the [class-headers-can-be-wrong] pattern again — the headers are load-bearing but not automatically true.

**⇒ The work is not "build a guard". It is "repoint the guard's own query" (`:337`) so the guard scans the population it is now protecting.** If the definition moves and `:337` is left on `Is_Broker__c`, the guard scans 0 rows, reports "nothing at risk", and STEP 5's delete — if it is repointed — destroys 19 real broker Contacts with a green verdict line. **The guard query and the delete query must be repointed in the same edit or neither.**

### 0.4 ⚠ `Opportunity.Broker__c` — brief's flag CONFIRMED, and it is worse than stated

Verified: `objects/Opportunity/fields/Broker__c.field-meta.xml` has **no `<lookupFilter>` element at all** (30 lines, read in full).

At least **four** places in the repo assert it does:

- `BOV_Submission__c/fields/Broker__c.field-meta.xml:20-21` — "Disposition\_\_c.Broker\_\_c, Lease\_Inquiry\_\_c.Broker\_\_c and Opportunity.Broker\_\_c are the other three precedents and **carry the same filter**"
- `Disposition__c/fields/Broker__c.field-meta.xml:17-18` — "Lease\_Inquiry\_\_c.Broker\_\_c and Opportunity.Broker\_\_c are the other two precedents and **carry the same filter**"
- `NDA__c/fields/Buyer__c.field-meta.xml:17-20` — lists `Opportunity.Broker__c` among fields carrying "an ACTIVE, non-optional lookupFilter"
- `seed-broker-contacts.apex:32` lists it as one of the five referencing lookups (that one *is* correct — it references Contact; it just isn't filtered)

**Recommendation: OUT of scope for this change. Documentation fix IN scope.** Reasons:

1. The user's confirmed "all 6 lookups" was enumerated from the 6 that actually *have* filters. Adding a 7th filter is new behaviour, not consistency.
2. `Opportunity.Broker__c` is **machine-stamped by `LeadConvertService` at conversion**, not human-picked. An active non-optional filter there would make lead conversion fail hard for any Contact not on the Broker record type — and the Broker-Protection intake path is exactly where Master-record-type Contacts arise (see 5.1).
3. It is `SetNull` and has no denormalised copy, so it carries none of the corruption risk that motivated the other filters.

**Decision required from the user** — recorded as blocking gate **G3** below.

---

## 🔴 SECTION 1 — BLOCKING GATES (resolve before any file is written)

### G1 — 🔴 HIGHEST RISK: the `lookupFilter` record-type metadata shape is UNRESOLVED

I could **not** resolve this. The `salesforce-api-context` MCP tools are **not available in this agent's tool set** — I have only file-system tools, so I could make no real attempt and will not guess. The `sf-custom-field` skill does not cover record-type filtering (it documents `lookupFilter` only for scalar fields and `$Source` valueFields, `SKILL.md:220-228`), and the only repo example is `Contact.AccountId equals $Source.AccountId` (`sf-metadata/references/field-types-example.md:254-262`). **There is no existing record-type lookupFilter anywhere in this repo to copy.**

Candidate shapes, none verified:

| Candidate `<field>` | `<value>` | Note |
|---|---|---|
| `Contact.RecordTypeId` | `Broker` | Setup UI presents "Contact: Record Type"; the Metadata API may expect the developer name, the label, or an 18-char Id |
| `Contact.RecordType.DeveloperName` | `Broker` | Matches the SOQL form already used in `ContactSelector.selectByEmails:262` |
| `Contact.RecordType.Name` | `Broker` | Label-based; brittle if the label is ever translated or renamed |

🔴 **Why this is the top risk and not a detail:** a malformed `lookupFilter` has two failure modes on this project, and the second is the dangerous one — it can **deploy green and filter nothing**, leaving all six lookups wide open while every reviewer believes they are validated. A hardcoded 18-char Id would additionally be non-portable across orgs, which this repo has been burned by before (`.forceignore:34-37`).

**Required resolution protocol (assign to `salesforce-admin`, must complete before writing ANY of the six files):**

1. Load the `sf-custom-field` skill and call `salesforce-api-context` (`get_metadata_type_fields_properties` on `CustomField` → `lookupFilter` → `filterItems`). Record `mcp=complete` + `mcp_tools=<list>`, or `mcp=unavailable` after a real attempt.
2. Prove the shape on **ONE** field first — `BOV_Submission__c.Broker__c`, the field the user actually hit — via a **check-only dry-run** against `usman-dpeg`. Do not write the other five until one is proven.
3. 🔴 **Read the filter back from the org and confirm it actually filters** — do not accept deploy success as proof. Verify by attempting to save a Master-record-type Contact into the lookup and confirming refusal. This repo has a measured history of green deploys that changed nothing ([deploy-silent-rollback-zero-errors], [forceignored-settings-are-unverified-fiction]).
4. Only then replicate to the remaining five.

### G2 — `errorMessage` wording (needed for all six files)

Current string on all six, identical: `The selected Contact is not flagged as a broker (Is_Broker__c).`

It names the retired mechanism, so it must change. Proposed: `The selected Contact is not a Broker. Only Contacts on the Broker record type can be chosen here.` **Confirm wording with the user** — it is user-facing on six objects.

### G3 — `Opportunity.Broker__c`: in or out?

Recommendation **OUT** (see 0.4). Needs an explicit yes/no.

### G4 — Deploy-order confirmation for the seed guard

Confirm that `scripts/seed-broker-contacts.apex` STEP 1 (`:337`) and STEP 5 are repointed **in the same edit** (see 0.3). Confirm nobody runs that script against `usman-dpeg` during this change — it now holds 19 real broker Contacts.

---

## 🔵 ADMIN WORK (`salesforce-admin`)

### A1 — Repoint 6 lookup filters (blocked on G1 + G2)

All six currently carry a byte-identical `<lookupFilter>` block: `<active>true</active>`, `<booleanFilter>1</booleanFilter>`, `<field>Contact.Is_Broker__c</field>`, `<operation>equals</operation>`, `<value>True</value>`, `<isOptional>false</isOptional>`. **Verified individually — all six read exactly as the brief described.**

| # | File | Verified |
|---|---|---|
| 1 | `force-app/main/default/objects/BOV_Submission__c/fields/Broker__c.field-meta.xml` (`:127-137`) | ✅ the field the user hit |
| 2 | `force-app/main/default/objects/Disposition__c/fields/Broker__c.field-meta.xml` (`:177-187`) | ✅ |
| 3 | `force-app/main/default/objects/Broker_Assignment__c/fields/Broker__c.field-meta.xml` (`:6-16`) | ✅ |
| 4 | `force-app/main/default/objects/Lease_Inquiry__c/fields/Broker__c.field-meta.xml` (`:6-16`) | ✅ |
| 5 | `force-app/main/default/objects/BOV_Broker_Change__c/fields/Incoming_Broker__c.field-meta.xml` (`:21-31`) | ✅ |
| 6 | `force-app/main/default/objects/BOV_Broker_Change__c/fields/Outgoing_Broker__c.field-meta.xml` | ✅ (same shape) |

Change per file: `filterItems.field` + `value` to the G1-resolved shape; `errorMessage` to the G2-resolved string. **Keep `active=true`, `isOptional=false`, `booleanFilter=1` exactly as-is** — narrowing or optionalising the filter is not requested.

🔴 **Do NOT touch these two Contact lookups** — both are deliberately unfiltered with an explicit closed-decision banner (`DO NOT RE-OPEN IT`, design item O-5):
- `objects/NDA__c/fields/Buyer__c.field-meta.xml` (its `Is_Broker__c` hits are header prose explaining the absence)
- `objects/Disposition_Offer__c/fields/Buyer__c.field-meta.xml`

### A2 — Validation-rule error message

`objects/BOV_Submission__c/validationRules/Broker_Required_On_Submission.validationRule-meta.xml:125` ends with: *"…if the broker is missing, create the Contact and **tick Is Broker** first."* That instruction becomes wrong. Reword to direct the user to the Broker record type. Also update the in-file comment at `:54-56`.

### A3 — 🔴 No new permission-set work — verified, and stated explicitly as the brief asked

This change **adds no fields**, so the "Metadata-API field arrives with no FLS" hazard does **not** apply. Confirmed:
- `Contact.RecordTypeId` is a standard field requiring no FLS grant.
- `Contact.Broker` record-type visibility is already granted where broker Contacts are created (0.2 table).
- `Contact.Is_Broker__c` grants in `DPEG_Contact_View` / `DPEG_Contact_Edit` **stay untouched** per confirmed scope item 2.

⚠ One caveat, not a permission-set edit: record-type visibility governs **creating/assigning**, not **reading**. Users without `Contact.Broker` visibility will still *see* broker Contacts in the repointed lookups. Only the `runAs` test personas in 0.2 are affected.

---

## 🟢 DEVELOPMENT WORK (`salesforce-developer`)

### D1 — `ContactSelector.cls`: repoint 4 queries

Use the **in-repo precedent** — `selectByEmails:262`, `AND RecordType.DeveloperName = 'Broker'` (added 2026-08-10 for IR segregation). This change resolves the internal inconsistency that method created.

| Method | Line | Mode | Note |
|---|---|---|---|
| `selectBrokersOrderedByName` | `~105` | `USER_MODE` | backs `BrokerAssignmentController.getBrokerOptions` |
| `selectBrokersRankedByClosedVolume` | `~128` | `USER_MODE` | backs `BrokerController.getBrokerHub` |
| `selectTopBrokersByActiveListings` | `~156` | `USER_MODE` | `WHERE Is_Broker__c = true AND Active_Listings__c > 0` — keep the `Active_Listings__c` term |
| `GuestReads.selectBrokerPriorityByEmailSystem` | `~389` | `SYSTEM_MODE`, `without sharing` | see D1a |

🔴 **Leave `selectBrokerLabelsByIds` (`:332`) alone.** Its ApexDoc (`:316`) documents the deliberate absence of a broker filter. Do not "make it consistent."

**D1a — trust-model consequence of the guest path (the brief asked for this explicitly).**
`GuestReads.selectBrokerPriorityByEmailSystem` is the **public LWR Broker Portal intake** read: `WHERE Email = :trimmedEmail AND Is_Broker__c = true`, `without sharing` + `WITH SYSTEM_MODE`. Swapping the predicate to `RecordType.DeveloperName = 'Broker'` **widens** what the unauthenticated path matches, because today the `Is_Broker__c = true` term matches **zero rows org-wide** — this query is currently a guaranteed no-match. After the change it will match 19 real broker Contacts and return `Broker_Priority__c` for them.

That is the *intended* restoration of a broken feature, not a regression — but it is the one place in this change where a **guest** principal begins receiving data it currently never receives. Two properties keep it safe and both should be re-verified rather than assumed: the query is **email-equality-scoped** (a guest gets only the row matching an email they already supplied), and it selects **only `Broker_Priority__c`**. Confirm the selected field list is not widened while the predicate is changed, and confirm no `Contact.Investor` record can ever satisfy it (the record-type predicate makes this *stronger* than the checkbox did — an Investor Contact with a stray ticked checkbox would have matched before; now it cannot).

### D2 — 🔴 Two tests INVERT and will fail — the fixture becomes a positive

`TestDataFactory.createContacts` produces Broker-record-type Contacts with `Is_Broker__c = false` (0.1). Two tests use exactly that as their **"no brokers exist"** fixture and assert an empty result. Under the new predicate they will return 3 rows.

| Test | Line | Today | After |
|---|---|---|---|
| `ContactSelectorTest.selectBrokersOrderedByName_noBrokers_returnsEmpty` | `:53-62` | `createContacts(3)` → asserts `0` | returns **3** → ❌ |
| `ContactSelectorTest.selectBrokersRankedByClosedVolume_noBrokers_returnsEmpty` | `:156-165` | `createContacts(3)` → asserts `0` | returns **3** → ❌ |

This is the [retirement-checklist] item 7 pattern exactly: *a test that uses a real value as its "unknown value" fixture keeps passing while its premise inverts.* Here it fails loudly, which is the good outcome — but the fix must be a **new non-Broker fixture** (a Contact explicitly on the Investor or Master record type), **not** deleting the assertion. Losing these two tests would remove the only proof that the broker selectors exclude non-brokers.

⚠ **Unaffected, checked:** `ContactSelectorTest:332` and `:537` also use `createContacts` but assert presence/count, not exclusion. `:537` in fact *depends* on the Broker record type being stamped (0.1).

### D3 — Audit `runAs` personas that create broker Contacts (0.2)

Enumerate every test that wraps broker-Contact creation in `System.runAs(...)` with a persona granted **only** a Disposition/Acquisition/Broker-Protection set. Those inserts begin failing with `FIELD_FILTER_VALIDATION_EXCEPTION` because the factory leaves `RecordTypeId` unset for them. Fix by granting `Contact.Broker` visibility to the test persona — **not** by weakening the lookup filter.
Known starting point: `ContactSelectorTest:64-79` documents this persona pattern and uses `DPEG_Contact_Edit`, which **does** grant the record type, so it is safe. Others must be checked individually.

### D4 — 🔴 Repoint the seed guard (see 0.3) — highest data-loss risk in the change

`scripts/seed-broker-contacts.apex`: STEP 1's roster query (`:337`) and STEP 5's delete must move to the record-type definition **together**. Repointing one without the other yields a guard that scans 0 rows and reports "nothing at risk" while the delete destroys 19 live broker Contacts across 5 `SetNull` lookups. Also correct the header prose at `:3` and `:11`.

Other seed scripts referencing the flag, all needing the same predicate sweep:
`scripts/seed-broker-assignments.apex` (4 hits), `scripts/seed-lease-inquiries.apex` (4), `scripts/seed-disposition.apex` (3), `scripts/seed-disposition-bulk.apex` (3), `scripts/seed-disp0002.apex` (3).
⚠ Per `Broker_Required_On_Submission`'s header (`:108-110`), the three disposition seeds **abort** when the broker population is empty. They abort today (0 rows). After this change they will find 19 — so a previously-aborting script starts doing real work. Intended, but must be expected.

### D5 — Documentation debt (in scope, not an afterthought)

Sweep measured: **192 occurrences of `Is_Broker__c` across 84 files.** Excluding the 40 force-ignored `profiles/**` files (1 hit each, non-deploying, per `.forceignore:28`) and `docs/` (also force-ignored, `.forceignore:12`), the load-bearing prose to correct:

- The 6 field files' own headers (they describe the filter they carry).
- `objects/Contact/fields/Is_Broker__c.field-meta.xml` — must gain a banner: retained but **no longer the broker definition**, retirement deferred.
- `objects/BOV_Broker_Change__c/fields/Outgoing_Broker_Firm__c.field-meta.xml` (2 hits).
- `classes/ContactSelector.cls` — **13 hits**, mostly the class header's authoritative SOQL-mode inventory (`:33-77`). ARCHITECTURE.md §2 names selector headers as the authoritative inventory, so this one matters most.
- `classes/BovSubmissionService.cls`, `BovSubmissionBrokerStampService.cls` (`:79`), `BrokerController.cls`.
- 🔴 **Correct the four false "Opportunity.Broker\_\_c carries the same filter" claims** (0.4).
- `pathAssistants/Disposition_Path_Off_Market.pathAssistant-meta.xml` (1 hit) — check whether it is an active step *referencing* the field ([retirement-checklist] item 4). It does not block anything now (nothing is being deleted), but it must be correct before any future retirement.

---

## 🔗 EXECUTION ORDER

1. **G1** — resolve the lookupFilter shape on ONE field, dry-run, read back. Everything else is blocked on this.
2. **G2 / G3 / G4** — user decisions.
3. **A1 + A2** — the six filters and the VR message (declarative, deploys together).
4. **D1** — `ContactSelector` (4 queries). Independent of A1; can run in parallel.
5. **D2 + D3** — test fixes. Must land **with or before** A1, or `RunLocalTests` goes red.
6. **D4** — seed guard. 🔴 Both queries in one edit.
7. **D5** — documentation sweep.

⚠ **Concurrent-session hazard.** Per [commit-retrieves-before-editing], another session has previously built a whole feature into this same working tree. `git status` currently shows `DPEG_Disposition_Edit`/`DPEG_Disposition_View` and several BOV classes already modified and uncommitted, plus untracked `BovBrokerChange*` classes. **Diff every shared hub file against HEAD before deploying.**

---

## 📋 REPORT ONLY — no data changes (confirmed scope item 3)

### 5.1 Six Contacts sit on the Master record type

Org measurement: `rt=null | isb=false | 6`.

This contradicts `Contact/recordTypes/Broker.recordType-meta.xml:4-6`, which asserts *"Every Contact that existed before 2026-08-10 is this type."* It is not true for 6 rows.

This is a **known, documented, unclosed gap**: `ContactSelector.selectByEmails`'s ApexDoc (`:240-241`) already warns —

> "⚠ A Contact on the MASTER record type will not match. That is intended and is why the Task 3 backfill is gated on a zero-row query before OWD flips."

**That Task 3 backfill evidently never completed.** After this change, these 6 Contacts become invisible to **every** broker lookup and **every** broker query in the application — a strictly wider blast radius than today, where they are already invisible to `selectByEmails`. Recommend a follow-up record-type stamp as a separate deliverable.

### 5.2 "Derek Simmons" exists three times

| Id | Record type | `Is_Broker__c` |
|---|---|---|
| `003iw000000nzojAAA` | null / Master | false |
| `003iw000000o34LAAQ` | Broker | false |
| `003iw000000o39BAAQ` | Broker | false |

After this change the **two Broker-record-type rows will both appear** in the BOV broker picker — which fixes the user's reported symptom but presents them with a duplicate choice. The Master row will not appear. Recommend a dedupe as a separate deliverable.

⚠ Note the org's `Standard_Contact_Duplicate_Rule` is **active** (referenced at `TestDataFactory.cls:591`) yet three same-named rows exist — it is Alert/Allow, so it warns rather than blocks.

### 5.3 Zero Contacts carry `Is_Broker__c = true` — this is an application-wide outage, not a BOV bug

Confirmed by the brief's measurement and consistent with everything read here. Every broker lookup and every `WHERE Is_Broker__c = true` query matches nothing today. The Broker Hub, the Broker Assignment picker, the off-market Disposition broker pick, the Replace Broker modal and the guest Broker Portal priority read are **all equally broken** and none has been reported. This change fixes all of them at once.

---

## 📝 PROMPTS FOR SPECIALIST AGENTS

### 🔵 `salesforce-admin`

```
FIRST, AND BLOCKING — resolve the lookupFilter record-type metadata shape. Load the
sf-custom-field skill, then call salesforce-api-context (get_metadata_type_fields_properties
on CustomField -> lookupFilter -> filterItems). Record mcp=complete + mcp_tools=<list>, or
mcp=unavailable after a real attempt. There is NO record-type lookupFilter anywhere in this
repo to copy - do not guess the shape. Candidates: Contact.RecordTypeId / 
Contact.RecordType.DeveloperName / Contact.RecordType.Name.

Prove the shape on ONE field only - objects/BOV_Submission__c/fields/Broker__c.field-meta.xml -
with a CHECK-ONLY dry-run against usman-dpeg. Then READ THE FILTER BACK FROM THE ORG and prove
it actually refuses a Master-record-type Contact. A malformed lookupFilter can deploy green and
filter nothing. Do not proceed to the other five until one is proven. Do not hardcode an
18-char record type Id - it is not portable across orgs.

THEN repoint the lookupFilter in exactly these six files, changing ONLY filterItems.field,
filterItems.value and errorMessage. Keep active=true, isOptional=false, booleanFilter=1:
  objects/BOV_Submission__c/fields/Broker__c.field-meta.xml
  objects/Disposition__c/fields/Broker__c.field-meta.xml
  objects/Broker_Assignment__c/fields/Broker__c.field-meta.xml
  objects/Lease_Inquiry__c/fields/Broker__c.field-meta.xml
  objects/BOV_Broker_Change__c/fields/Incoming_Broker__c.field-meta.xml
  objects/BOV_Broker_Change__c/fields/Outgoing_Broker__c.field-meta.xml

New errorMessage (confirm with user first): "The selected Contact is not a Broker. Only
Contacts on the Broker record type can be chosen here."

ALSO update objects/BOV_Submission__c/validationRules/Broker_Required_On_Submission.
validationRule-meta.xml - the errorMessage (:125) tells users to "tick Is Broker", which
becomes wrong. Update the in-file comment at :54-56 too.

🔴 DO NOT touch NDA__c/fields/Buyer__c or Disposition_Offer__c/fields/Buyer__c. Both are
deliberately unfiltered and carry an explicit "DO NOT RE-OPEN IT" closed-decision banner.
🔴 DO NOT add a lookupFilter to Opportunity.Broker__c unless the user answers YES to gate G3.
🔴 DO NOT delete, backfill or de-permission Contact.Is_Broker__c - it stays in place, unused.
NO new permission set work is needed: this change adds no fields. Contact.Broker record-type
visibility is already granted in DPEG_Contact_Edit, DPEG_Contact_View, DPEG_Admin_Access and
Lead_Stage_Actions_Access.

Update the affected field-file header comments in the same change - they describe the filter
they carry, and this repo treats those headers as authoritative.
Do not deploy - create/modify metadata files only.
```

### 🟢 `salesforce-developer`

```
Read ARCHITECTURE.md §1/§2 and .claude/rules/apex-layering-rule.md first.

1. classes/ContactSelector.cls - repoint FOUR queries from `Is_Broker__c = true` to the record
   type. Use the in-repo precedent already in this same class: selectByEmails:262 uses
   `AND RecordType.DeveloperName = 'Broker'`.
     selectBrokersOrderedByName (~:105)         USER_MODE
     selectBrokersRankedByClosedVolume (~:128)  USER_MODE
     selectTopBrokersByActiveListings (~:156)   USER_MODE - KEEP the Active_Listings__c > 0 term
     GuestReads.selectBrokerPriorityByEmailSystem (~:389)  SYSTEM_MODE, without sharing
   🔴 LEAVE selectBrokerLabelsByIds (:332) ALONE - its ApexDoc (:316) documents the deliberate
   absence of a broker filter. Do not "make it consistent".
   🔴 GUEST PATH: selectBrokerPriorityByEmailSystem is the public LWR Broker Portal intake. It
   matches ZERO rows today; after this it matches 19. Keep the predicate email-equality-scoped
   and do NOT widen the selected field list beyond Broker_Priority__c while changing the
   predicate. Preserve WITH SYSTEM_MODE and the without-sharing inner class exactly.

2. 🔴 TWO TESTS WILL INVERT AND FAIL. TestDataFactory.createContacts ALREADY stamps the
   Contact.Broker record type (TestDataFactory.cls:580-585) while leaving Is_Broker__c = false,
   so these two use it as a "no brokers exist" fixture and assert 0 rows:
     ContactSelectorTest.selectBrokersOrderedByName_noBrokers_returnsEmpty (:53-62)
     ContactSelectorTest.selectBrokersRankedByClosedVolume_noBrokers_returnsEmpty (:156-165)
   Fix by giving them a genuine NON-Broker fixture (Investor or Master record type). DO NOT
   delete the assertions - they are the only proof the broker selectors exclude non-brokers.
   NOTE: ContactSelectorTest:332 and :537 also use createContacts but are UNAFFECTED (they
   assert presence, not exclusion); :537 actually depends on the Broker stamp.

3. TestDataFactory needs NO change for the happy path - it already stamps the record type.
   BUT recordTypeId() (:324-329) returns null when the record type is not available to the
   RUNNING user, leaving RecordTypeId unset. Audit every test that creates a broker Contact
   inside System.runAs with a persona granted ONLY DPEG_Disposition_*, DPEG_Acquisition_* or
   Broker_Protection_Access - none of those grant Contact.Broker visibility, so those inserts
   will start failing FIELD_FILTER_VALIDATION_EXCEPTION. Fix by granting the record type to the
   TEST PERSONA, never by weakening the lookup filter.

4. 🔴 HIGHEST DATA-LOSS RISK - scripts/seed-broker-contacts.apex. The guard is ALREADY BUILT
   (STEP 1 :337, STEP 2 :349, STEP 3 gate :504-511, FORCE=false :255) - the field headers that
   call it "still OPEN" are STALE. Repoint STEP 1's roster query (:337) AND STEP 5's delete in
   the SAME edit. Repointing one and not the other makes the guard scan 0 rows and report
   "nothing at risk" while the delete destroys 19 live broker Contacts across 5 SetNull lookups.
   Correct the header prose at :3 and :11.
   Same predicate sweep in: seed-broker-assignments.apex, seed-lease-inquiries.apex,
   seed-disposition.apex, seed-disposition-bulk.apex, seed-disp0002.apex. Expect the three
   disposition seeds - which abort today on an empty broker population - to start doing real work.

5. Documentation sweep. 🔴 Correct the FOUR false claims that Opportunity.Broker__c "carries the
   same filter" - it has NO lookupFilter at all (verified): BOV_Submission__c/fields/Broker__c
   (:20-21), Disposition__c/fields/Broker__c (:17-18), NDA__c/fields/Buyer__c (:17-20), and the
   ContactSelector class header. Update ContactSelector's header SOQL-mode inventory (13 hits,
   :33-77) - ARCHITECTURE.md §2 names selector headers as the authoritative inventory. Add a
   banner to Contact/fields/Is_Broker__c.field-meta.xml: retained but NO LONGER the broker
   definition; retirement deferred to a separate task.

🔴 DO NOT delete or backfill Contact.Is_Broker__c. DO NOT stamp record types on existing
Contacts. DO NOT dedupe the three Derek Simmons rows. All three are explicitly out of scope.
⚠ Another session may be working in this tree - diff shared files against HEAD before deploying.
```

---

## Summary of what changed vs. the brief

| Brief claim | Verdict |
|---|---|
| 6 lookup filters, identical shape | ✅ **Confirmed** — all six read individually |
| `Opportunity.Broker__c` has no filter despite headers saying so | ✅ **Confirmed** — recommend OUT of scope, fix the docs |
| 4 `ContactSelector` queries + `selectByEmails` precedent | ✅ **Confirmed** |
| `TestDataFactory` must be changed to stamp the record type; ~15 test classes fail | ❌ **FALSE** — it already stamps it (`:580-585`) |
| `seed-broker-contacts.apex` guard is unimplemented; line 4 is the delete | ❌ **FALSE / STALE** — guard is fully built; work is to repoint its query |
| lookupFilter record-type shape must be resolved via MCP | ⚠ **UNRESOLVED** — MCP unavailable to this agent; escalated as blocking gate G1 |
| No new permission-set work needed | ✅ **Confirmed and stated** — but see the `runAs` test-persona gap (0.2) |
