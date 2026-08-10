# IR / Acquisitions Segregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Investor Relations its own Lead / Contact / Account population that the Acquisitions, Transactions and Property Management teams cannot see, and vice versa — enforced by record-level sharing, not by UI convention.

**Architecture:** Record types partition Lead, Contact and Account into an acquisitions half and an IR half. **Account is the sharing boundary and Contact inherits it** through the existing `ControlledByParent` OWD, so only Account and Lead flip to Private. Criteria-based sharing rules grant each record type to that team's public group; a new `Investor_Relations_Manager` role sits as a *sibling* of the existing team roles so the hierarchy cannot leak sideways. Apex changes are additive stamps on four existing classes — no new triggers, objects or services.

**Spec:** `docs/superpowers/specs/2026-08-10-ir-acquisition-lead-contact-segregation-design.md`

**Tech Stack:** Salesforce Metadata API 67.0, Apex, `sf` CLI v2, Salesforce record types / criteria-based sharing rules / permission sets.

## Global Constraints

- **API version 67.0** on all Apex and metadata (`sfdx-project.json` → `sourceApiVersion`).
- **All SOQL lives in selectors** and uses `WITH USER_MODE` unless an automation-path justification is written at the method's own declaration (`ARCHITECTURE.md` §2).
- **`with sharing` on every service, selector, domain and controller.** `without sharing` requires written justification in the class header.
- **Test data comes from `TestDataFactory`** (`force-app/main/default/classes/TestDataFactory.cls`). Never `@isTest(SeeAllData=true)`.
- **90%+ coverage per team-owned class.**
- 🔴 **A PermissionSet deploy REPLACES that file's entire `<fieldPermissions>` set.** Every grant that must survive has to be declared in-file. This wiped a live `Task.WhoId` grant twice in August 2026.
- 🔴 **Sharing rules deploy ONE AT A TIME.** A batch deploy rolls all of them back on a single failure.
- 🔴 **An XML comment must sit INSIDE the root element.** A comment above the root breaks `sf` deploy at source conversion with a misleading "unable to find matching parent xml file".
- 🔴 **`profiles/**` and `settings/**` are `.forceignore`d.** Never rely on a repo profile or settings file as evidence of org state — read it back from Setup.
- 🔴 **Metadata-API-deployed record types are visible to NO profile by default**, exactly like FLS on new fields. Every persona permission set needs explicit `<recordTypeVisibilities>`.
- **Per `CLAUDE.md`, the main agent orchestrates and does not implement.** Metadata tasks → `salesforce-admin`. Apex tasks → `salesforce-developer`. Test classes → `salesforce-unit-testing`. Every task passes `salesforce-code-review` before `salesforce-devops` deploys.
- **Record type API names are fixed and used verbatim throughout:**
  `Lead.Acquisition_Broker`, `Lead.IR_Investor`, `Contact.Broker`, `Contact.Investor`, `Account.Broker_Firm`, `Account.Investor_Entity`.
- 🔴 **EVERY record-type helper in this plan guards on `info != null && info.isAvailable()`** — and provisioning, not the guard, is the primary answer.

  **This bullet reversed itself once. Read the whole thing before changing it again.** An earlier version said to drop `isAvailable()`, on the reasoning that Apex DML writes in system mode so the guard could only cause records to land unstamped. **That reasoning was wrong and was falsified by measurement on 2026-08-10** (Task 3, reproduced live via `ContactSelectorTest`): a plain `insert` — already CRUD/FLS-bypassing — still threw `System.DmlException: INVALID_CROSS_REFERENCE_KEY, Record Type ID` under `System.runAs` for a user lacking the record type.

  **The measured rule: record-type visibility is enforced on Apex DML UNCONDITIONALLY. `AccessLevel` / `SYSTEM_MODE` governs CRUD, FLS and sharing — never record-type visibility.**

  So the two failure modes are not "throws" versus "works", they are:
  - **guarded** → the record lands **unstamped**, matches no sharing rule after Task 12, and is visible only to its owner. Silent.
  - **unguarded** → the **INSERT THROWS**. On the inbound-email path that destroys the broker email outright — no Lead, no claim, no audit row. That is strictly worse, and is the same shape as this repo's ContentPublication outage.

  **Therefore: guard everywhere, and treat the guard as a fail-soft backstop rather than the solution.** The actual fix is to provision every principal that creates records with the record type it needs — via permission sets, which is what Task 2 did for the human personas. `isAvailable()` exists for the principals that cannot be reliably provisioned (the Site guest user, the Email Service context user) so that a provisioning gap costs an unstamped record instead of a destroyed email.

  🔴 **Because the guard hides a provisioning gap, Task 14 MUST verify that no record lands unstamped in real use** — the `verify-record-type-backfill.apex` script from Task 7 is the detector, and it needs re-running after the pipeline tests, not only before the OWD flip.
- **Sharing rules:** `RecordTypeId` criteria take the record type **LABEL** (`Broker Firm`), and `<sharedTo>` accepts exactly **one** target per rule. Both established empirically 2026-08-10.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `objects/Lead/recordTypes/{Acquisition_Broker,IR_Investor}.recordType-meta.xml` | Lead partition |
| `objects/Contact/recordTypes/{Broker,Investor}.recordType-meta.xml` | Contact partition (layout/FLS/reporting only — **not** sharing) |
| `objects/Account/recordTypes/{Broker_Firm,Investor_Entity}.recordType-meta.xml` | Account partition — **the sharing boundary** |
| `objects/Contact/validationRules/Record_Type_Matches_Account.validationRule-meta.xml` | Stops a Contact and its Account disagreeing about which team owns them |
| `objects/Account/validationRules/Record_Type_Is_Immutable.validationRule-meta.xml` | Stops an Account flipping type and dragging its Contacts across |
| `permissionsets/DPEG_IR_Edit.permissionset-meta.xml` | IR persona object + investor FLS |
| `permissionsets/DPEG_IR_View.permissionset-meta.xml` | Read-only variant for the Principal |
| `permissionsets/DPEG_App_Investor_Relations.permissionset-meta.xml` | App + tab visibility only |
| `permissionsetgroups/DPEG_Investor_Relations_PSG.permissionsetgroup-meta.xml` | Composed IR persona |
| `roles/Investor_Relations_Manager.role-meta.xml` | Sibling role under `DPEG_Principal` |
| `applications/Investor_Relations.app-meta.xml` | The IR app |
| `scripts/apex/backfill-record-types.apex` | T3 backfill |
| `scripts/apex/verify-record-type-backfill.apex` | T3 gate query |
| `docs/2026-08-10-ir-segregation-runbook.md` | The manual OWD flip + in-org steps |

**Modified:**

| Path | Change |
|---|---|
| `sharingRules/Account.sharingRules-meta.xml` | Two criteria-based rules |
| `sharingRules/Lead.sharingRules-meta.xml` | Two criteria-based rules added; existing owner rule untouched |
| `groups/Investor_Relations.group-meta.xml` | `doesIncludeBosses` → `false` |
| `permissionsets/DPEG_Acquisition_{Edit,View}.permissionset-meta.xml` | `<recordTypeVisibilities>` for Lead |
| `permissionsets/DPEG_Contact_{Edit,View}.permissionset-meta.xml` | `<recordTypeVisibilities>` + broker-only FLS |
| `classes/TestDataFactory.cls` | Record-type stamping on Account / Contact / Lead builders |
| `classes/EmailToLeadService.cls` | Stamp `Acquisition_Broker` |
| `classes/BrokerPortalService.cls` | Stamp `Acquisition_Broker` |
| `classes/LeadConvertService.cls` | Stamp converted Contact + Account; governor contract 3 → ≤5 DML |
| `classes/ContactSelector.cls`, `classes/AccountSelector.cls` | Record-type-scoped matching |
| `classes/LeadConvertServiceTest.cls`, `EmailToLeadServiceTest.cls`, `BrokerPortalServiceTest.cls`, `ContactSelectorTest.cls`, `AccountSelectorTest.cls` | New assertions |

---

## Task 0: Branch and the two verification gates

The whole plan rests on two facts nobody has checked. Both are cheap to test and expensive to discover at Task 11.

**Files:** none (investigation + runbook stub)

**Interfaces:**
- Produces: a written answer to G1 and G2, recorded in `docs/2026-08-10-ir-segregation-runbook.md`.

- [ ] **Step 1: Branch off `main`**

The current branch `feature/stage-by-stage-alignment` is unrelated work with a large dirty tree. Do not build on it.

```bash
git status --short | head
git checkout main
git pull
git checkout -b feature/ir-acquisitions-segregation
```

- [ ] **Step 2: G1 — does criteria-based sharing accept `RecordTypeId` in this org?**

In Setup → Sharing Settings → Account → *Account Sharing Rules* → New, choose "Based on criteria" and open the Field dropdown. Confirm **Record Type** is listed.

Record the answer in the runbook. If **Record Type is absent**, the fallback is a `Business_Unit__c` picklist (values `Acquisitions` / `Investor Relations`) on Lead and Account, stamped by the same code that stamps the record type, with all four sharing rules keyed on it instead. That fallback changes Tasks 1, 4, 5 and 11 only — flag it and stop for a decision rather than improvising.

- [ ] **Step 3: G2 — what is the real current OWD for Lead and Account?**

The repo says `Lead.sharingModel = ReadWriteTransfer` and `Account.sharingModel = ReadWrite`, but OWD on standard objects is not deployable metadata, so neither value is evidence.

Read both from Setup → Sharing Settings and write the actual values into the runbook. If Lead is **already Private**, Task 12's Lead half is a no-op — good news, but it must be confirmed rather than assumed.

- [ ] **Step 4: Create the runbook with both answers**

```bash
mkdir -p docs
```

Create `docs/2026-08-10-ir-segregation-runbook.md` containing: the G1 and G2 answers with the date observed, and a placeholder "Manual Setup steps" section that Tasks 1, 11 and 12 will fill in.

- [ ] **Step 5: Commit**

```bash
git add docs/2026-08-10-ir-segregation-runbook.md
git commit -m "docs: IR segregation runbook with sharing/OWD verification gates"
```

---

## Task 1: Record types on Lead, Contact and Account

**Delegate to:** `salesforce-admin`

**Files:**
- Create: `force-app/main/default/objects/Lead/recordTypes/Acquisition_Broker.recordType-meta.xml`
- Create: `force-app/main/default/objects/Lead/recordTypes/IR_Investor.recordType-meta.xml`
- Create: `force-app/main/default/objects/Contact/recordTypes/Broker.recordType-meta.xml`
- Create: `force-app/main/default/objects/Contact/recordTypes/Investor.recordType-meta.xml`
- Create: `force-app/main/default/objects/Account/recordTypes/Broker_Firm.recordType-meta.xml`
- Create: `force-app/main/default/objects/Account/recordTypes/Investor_Entity.recordType-meta.xml`

**Interfaces:**
- Produces: six record types addressable as `Lead.Acquisition_Broker`, `Lead.IR_Investor`, `Contact.Broker`, `Contact.Investor`, `Account.Broker_Firm`, `Account.Investor_Entity`. Tasks 2, 3, 4, 5, 6, 8, 10 and 11 all reference these exact developer names.

- [ ] **Step 1: Write `Lead.Acquisition_Broker`**

Follow the house style established by `objects/NDA__c/recordTypes/Acquisition_NDA.recordType-meta.xml` — long rationale in an XML comment **inside** the root element, short `<description>` under 255 characters.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<RecordType xmlns="http://soap.sforce.com/2006/04/metadata">
    <!--
        THIS NOTE LIVES IN A COMMENT, NOT IN <description>. RecordType.Description is capped
        at 255 characters. A comment is repo-only and never reaches the Metadata API. It must
        sit INSIDE the root element - a comment above <RecordType> breaks `sf` deploy at
        source conversion with a misleading "unable to find matching parent xml file".

        THE ACQUISITIONS BROKER LEAD. Every Lead that existed before 2026-08-10 is this type,
        and every Lead the inbound email pipeline, the Broker Portal, or a manual acquisitions
        entry creates is this type.

        THIS RECORD TYPE IS LOAD-BEARING FOR SECURITY, NOT PRESENTATION. Once Lead OWD is
        Private (plan Task 12), the criteria-based sharing rule Lead_Acquisition_Broker is the
        ONLY thing granting DPEG_Acquisitions_Team access to these rows. A Lead left without a
        record type matches NO sharing rule and becomes invisible to everyone except its owner.
        That is why the backfill (Task 3) is gated on a zero-row query and why the Apex stamps
        (Tasks 4 and 5) ship BEFORE the backfill runs.
    -->
    <fullName>Acquisition_Broker</fullName>
    <active>true</active>
    <description>Acquisitions broker lead. Governs sharing once Lead OWD is Private - see the XML comment in this file.</description>
    <label>Acquisition Broker</label>
</RecordType>
```

- [ ] **Step 2: Write `Lead.IR_Investor`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<RecordType xmlns="http://soap.sforce.com/2006/04/metadata">
    <!--
        THE INVESTOR RELATIONS LEAD. Net new as of 2026-08-10 - no existing Lead carries this
        type and the backfill deliberately does not create any.

        SECURITY-LOAD-BEARING, same as the sibling type: the Lead_IR_Investor sharing rule is
        the only thing granting the Investor_Relations group access once Lead OWD is Private.

        NO APEX PATH CREATES THIS TYPE. The inbound email pipeline, the Broker Portal and lead
        conversion all stamp Acquisition_Broker explicitly. IR leads are created by hand or by
        a future IR intake that does not yet exist.
    -->
    <fullName>IR_Investor</fullName>
    <active>true</active>
    <description>Investor Relations lead. Governs sharing once Lead OWD is Private - see the XML comment in this file.</description>
    <label>IR Investor</label>
</RecordType>
```

- [ ] **Step 3: Write the four remaining record types**

Same shape. Use these exact values:

| File | `<fullName>` | `<label>` | Comment must state |
|---|---|---|---|
| `Contact/recordTypes/Broker.recordType-meta.xml` | `Broker` | `Broker` | Contact record types drive **layout, FLS and reporting only — NOT sharing**. Contact sharing is inherited from its Account via `ControlledByParent`. The `Record_Type_Matches_Account` validation rule (Task 8) is what keeps the two from disagreeing. |
| `Contact/recordTypes/Investor.recordType-meta.xml` | `Investor` | `Investor` | Same, plus: net new, no existing Contact carries it. |
| `Account/recordTypes/Broker_Firm.recordType-meta.xml` | `Broker_Firm` | `Broker Firm` | **This is the actual sharing boundary for both Account and Contact.** Shared to Acquisitions, Transactions AND Property Management — all three consume broker Contacts through `Broker_Assignment__c.Broker__c`, `Lease_Inquiry__c.Broker__c` and `Opportunity.Broker__c`. The split is "everyone except IR", not two-way. |
| `Account/recordTypes/Investor_Entity.recordType-meta.xml` | `Investor_Entity` | `Investor Entity` | The IR boundary. Assumes investors are modelled as **entities** (LLCs, trusts, funds), each with an Account — see the spec §3 switch point if that turns out to be wrong. |

- [ ] **Step 3b: 🔴 ENUMERATE EVERY PICKLIST ON ALL SIX RECORD TYPES**

**This step was missing from the plan's first draft and is a Critical defect fix (Task 1 review, 2026-08-10).** The templates in Steps 1-3 above show only `fullName` / `active` / `description` / `label`; that shape is **incomplete for this repo**.

**A record type file that omits a picklist silently drops ALL of that picklist's values from that record type.** This project has already been bitten by it on five objects — every record type under `NDA__c`, `Contract_Review__c`, `Disposition__c` and `LOI__c` enumerates every picklist and carries a warning comment saying exactly this. Read `objects/LOI__c/recordTypes/Acquisition_LOI.recordType-meta.xml` for the house pattern.

The blast radius here is larger than on those custom objects, because Lead, Contact and Account are **standard objects with many standard picklists**, and Task 7 backfills every existing record onto these types:

- `Lead.Status` in this org is customised — `New / Under Review / Qualified / Converted / Disqualified`. Dropping it breaks the Lead Path, `LeadActionPermissionService`, `EmailToLeadService.STATUS_NEW`, `BrokerPortalService`, `TestDataFactory` and the live inbound pipeline at once.
- Also affected: `Lead.LeadSource`, `Rating`, `Industry`, `Salutation`, `Deal_Type__c`, `Asset_Type__c`, `Disqualification_Reason__c`, `Sale_Process__c`, `Parse_Confidence__c`, `Broker_Priority__c`; `Contact.LeadSource`, `Salutation`, `Broker_Status__c`, `Broker_Specialty__c`, `Broker_Priority__c`; `Account.Type`, `Industry`, `Rating`, `Ownership`, `AccountSource` and every other picklist those three objects carry.

🔴 **Derive the values from the ORG, not from the repo's field files.** `sf project retrieve` UNIONS local and remote picklist values, so a repo field file can list values the org no longer has. Enumerate from a live describe:

```bash
sf sobject describe --sobject Lead --target-org usman-dpeg > /tmp/lead-describe.json
sf sobject describe --sobject Contact --target-org usman-dpeg > /tmp/contact-describe.json
sf sobject describe --sobject Account --target-org usman-dpeg > /tmp/account-describe.json
```

For each object, list every field of type `picklist` or `multipicklist` where `active` is true, and write a `<picklistValues>` block per picklist into **both** of that object's record types. Preserve the current `<default>` — exactly one value may be default per picklist, or none.

⚠ Both record types on an object get the **same, complete** value set at this stage. Narrowing a value set per record type is a *later*, deliberate change (that is how `NDA__c` restricts `Declined` to the disposition type) and is explicitly **not** in scope here — this task must be behaviour-neutral for every existing record.

- [ ] **Step 4: Deploy and verify all six exist in the org**

```bash
sf project deploy start --source-dir force-app/main/default/objects/Lead/recordTypes --source-dir force-app/main/default/objects/Contact/recordTypes --source-dir force-app/main/default/objects/Account/recordTypes
```

Then confirm they are really there — a green deploy is not the proof:

```bash
sf data query --query "SELECT SobjectType, DeveloperName, IsActive FROM RecordType WHERE SobjectType IN ('Lead','Contact','Account') ORDER BY SobjectType, DeveloperName"
```

Expected: exactly 6 rows, all `IsActive = true`.

- [ ] **Step 5: Record the manual page-assignment step in the runbook**

⚠ **Layout and Lightning-record-page assignment per record type is NOT deployable here** — layout assignment lives in Profile metadata and `profiles/**` is `.forceignore`d. Add to the runbook's "Manual Setup steps": assign the existing `Lead Layout`, `Contact Layout` and `Account Layout` to both record types for now, and note that IR-specific layouts are Task 13's business, not this task's.

- [ ] **Step 6: Commit**

```bash
git add force-app/main/default/objects/Lead/recordTypes force-app/main/default/objects/Contact/recordTypes force-app/main/default/objects/Account/recordTypes docs/2026-08-10-ir-segregation-runbook.md
git commit -m "feat: add Lead/Contact/Account record types for IR-Acquisitions segregation"
```

---

## Task 2: Grant record type visibility to every existing persona

Without this, no user can create a Lead, Contact or Account at all, and `Database.convertLead` fails outright. It is the same trap as FLS on a newly deployed field.

**Delegate to:** `salesforce-admin`

**Files:**
- Modify: `force-app/main/default/permissionsets/DPEG_Acquisition_Edit.permissionset-meta.xml`
- Modify: `force-app/main/default/permissionsets/DPEG_Acquisition_View.permissionset-meta.xml`
- Modify: `force-app/main/default/permissionsets/DPEG_Contact_Edit.permissionset-meta.xml`
- Modify: `force-app/main/default/permissionsets/DPEG_Contact_View.permissionset-meta.xml`
- Modify: `force-app/main/default/permissionsets/Lead_Stage_Actions_Access.permissionset-meta.xml`
- Modify: `force-app/main/default/permissionsets/Broker_Protection_Access.permissionset-meta.xml`
- Modify: `force-app/main/default/permissionsets/DPEG_Admin_Access.permissionset-meta.xml`

**Interfaces:**
- Consumes: the six record types from Task 1.
- Produces: every existing persona can create and read acquisition-side records. Task 10 does the same for the IR persona.

- [ ] **Step 1: Confirm which of these files touch Lead, Contact or Account**

```bash
cd force-app/main/default/permissionsets
grep -l -E "<object>(Lead|Contact|Account)</object>" *.permissionset-meta.xml
```

Every file listed needs the matching `<recordTypeVisibilities>` block. A file granting only `Contact` gets only the Contact record types.

- [ ] **Step 2: Add acquisition-side visibility to each**

`<recordTypeVisibilities>` blocks sort alphabetically by `<recordType>` in the file, matching the existing convention in `DPEG_Disposition_Edit.permissionset-meta.xml`. For a permission set granting Lead:

```xml
    <recordTypeVisibilities>
        <recordType>Lead.Acquisition_Broker</recordType>
        <visible>true</visible>
    </recordTypeVisibilities>
```

For one granting Contact:

```xml
    <recordTypeVisibilities>
        <recordType>Contact.Broker</recordType>
        <visible>true</visible>
    </recordTypeVisibilities>
```

For one granting Account:

```xml
    <recordTypeVisibilities>
        <recordType>Account.Broker_Firm</recordType>
        <visible>true</visible>
    </recordTypeVisibilities>
```

🔴 **Grant the acquisition-side type ONLY.** Do not add `Lead.IR_Investor`, `Contact.Investor` or `Account.Investor_Entity` to any of these files. Granting exactly one visible record type per object per persona is half of the boundary — a user who cannot see the IR record type cannot create an IR record, no matter what the sharing rules say.

- [ ] **Step 3: `DPEG_Admin_Access` is the one exception**

Give it **all six**. It already carries `recordTypeVisibilities` for other objects, so follow that file's existing pattern. Admins are outside this boundary by design (spec §5).

- [ ] **Step 4: Re-verify no `fieldPermissions` were lost**

🔴 A PermissionSet deploy replaces the whole `<fieldPermissions>` set. Adding a `<recordTypeVisibilities>` block must not disturb them.

```bash
git diff --stat force-app/main/default/permissionsets/
git diff force-app/main/default/permissionsets/ | grep -c "^-.*fieldPermissions"
```

Expected: the second command prints `0`. Any removed `fieldPermissions` line is a defect — restore it before deploying.

- [ ] **Step 5: Deploy and verify as a real persona**

```bash
sf project deploy start --source-dir force-app/main/default/permissionsets
```

Then confirm in-org that a **non-admin** acquisitions user can still create a Lead. An admin smoke test proves nothing here — `DPEG_Admin_Access` got all six types in Step 3, so it cannot fail the way a real persona can.

- [ ] **Step 6: Commit**

```bash
git add force-app/main/default/permissionsets
git commit -m "feat: grant acquisition-side record type visibility to existing personas"
```

---

## Task 3: TestDataFactory record-type stamping

This is the highest-volume risk in the plan. The suite is 600+ tests and most create a Lead or a Contact; without this they inherit whatever the test user's profile default happens to be.

**Delegate to:** `salesforce-developer`, then `salesforce-unit-testing`

**Files:**
- Modify: `force-app/main/default/classes/TestDataFactory.cls:434-540`

**Interfaces:**
- Consumes: the six record types from Task 1.
- Produces: `TestDataFactory.recordTypeId(Schema.SObjectType, String)` — a private static helper returning `Id` or `null`. `createAccounts`, `createContacts` and `createLeads` stamp the acquisition-side type when it is available.

- [ ] **Step 1: Write the failing test**

Add to `force-app/main/default/classes/TestDataFactoryTest.cls`:

```apex
@IsTest
static void factoryStampsAcquisitionSideRecordTypes() {
    Lead l = TestDataFactory.createLead(true);
    Account a = TestDataFactory.createAccount(true);
    Contact c = TestDataFactory.createContact(a.Id, true);

    Lead readLead = [SELECT RecordType.DeveloperName FROM Lead WHERE Id = :l.Id];
    Account readAccount = [SELECT RecordType.DeveloperName FROM Account WHERE Id = :a.Id];
    Contact readContact = [SELECT RecordType.DeveloperName FROM Contact WHERE Id = :c.Id];

    Assert.areEqual('Acquisition_Broker', readLead.RecordType.DeveloperName,
        'Factory Leads must be acquisition-side; an unstamped Lead matches no sharing rule once OWD is Private.');
    Assert.areEqual('Broker_Firm', readAccount.RecordType.DeveloperName,
        'Factory Accounts must be broker firms.');
    Assert.areEqual('Broker', readContact.RecordType.DeveloperName,
        'Factory Contacts must be brokers, matching their Account per Record_Type_Matches_Account.');
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
sf apex run test --class-names TestDataFactoryTest --result-format human --wait 10
```

Expected: FAIL — the record types are unset, so `RecordType.DeveloperName` is null.

- [ ] **Step 3: Add the helper to `TestDataFactory`**

Place it next to the other private helpers (`requirePositive`, `insertIf`, `nextUnique`):

```apex
    /**
     * The Id of a record type by developer name, or null when it does not exist in this org
     * or is not available to the running user.
     *
     * Null is a legitimate answer, not an error: the caller then leaves RecordTypeId unset and
     * the platform applies its own default. That is what lets this factory work in an org where
     * the segregation record types have not deployed yet, so plan Tasks 1 and 3 can land in
     * either order and no existing test goes red on a partial deploy.
     *
     * A describe, not a query - it costs no SOQL, which matters because this runs inside every
     * governor-pinned test in the suite.
     */
    private static Id recordTypeId(Schema.SObjectType sobjType, String developerName) {
        Schema.RecordTypeInfo info = sobjType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }
```

- [ ] **Step 4: Stamp the three builders**

In `createAccounts`, immediately before `insertIf(doInsert, accounts);`:

```apex
        Id brokerFirmRt = recordTypeId(Account.SObjectType, 'Broker_Firm');
        if (brokerFirmRt != null) {
            for (Account a : accounts) {
                a.RecordTypeId = brokerFirmRt;
            }
        }
```

In `createContacts`, immediately before `insertIf(doInsert, contacts);`:

```apex
        Id brokerRt = recordTypeId(Contact.SObjectType, 'Broker');
        if (brokerRt != null) {
            for (Contact c : contacts) {
                c.RecordTypeId = brokerRt;
            }
        }
```

In `createLeads`, immediately before `insertIf(doInsert, leads);`:

```apex
        Id acqRt = recordTypeId(Lead.SObjectType, 'Acquisition_Broker');
        if (acqRt != null) {
            for (Lead l : leads) {
                l.RecordTypeId = acqRt;
            }
        }
```

`createBrokerContacts` delegates to `createContacts(count, accountId, false)` and needs no change — it inherits the stamp.

- [ ] **Step 5: Run the new test, then the whole suite**

```bash
sf apex run test --class-names TestDataFactoryTest --result-format human --wait 10
sf apex run test --test-level RunLocalTests --result-format human --wait 30
```

Expected: the new test PASSES, and **the full suite is no worse than its pre-change baseline**. Capture the baseline count before starting if you do not already have it. Any newly-red test is almost certainly asserting on a record type or a layout — fix it here, not later.

- [ ] **Step 6: Commit**

```bash
git add force-app/main/default/classes/TestDataFactory.cls force-app/main/default/classes/TestDataFactoryTest.cls
git commit -m "test: stamp acquisition-side record types in TestDataFactory"
```

---

## Task 4: Stamp `Acquisition_Broker` on the two Lead-creating paths

**Delegate to:** `salesforce-developer`, then `salesforce-unit-testing`

**Files:**
- Modify: `force-app/main/default/classes/EmailToLeadService.cls` (around line 217, `createLeadFromExtracted`)
- Modify: `force-app/main/default/classes/BrokerPortalService.cls:68-88`
- Test: `force-app/main/default/classes/EmailToLeadServiceTest.cls`, `force-app/main/default/classes/BrokerPortalServiceTest.cls`

**Interfaces:**
- Consumes: `Lead.Acquisition_Broker` from Task 1.
- Produces: every Lead minted by the inbound email pipeline or the guest Broker Portal carries `Acquisition_Broker`. Task 7's backfill assumes this is already live.

- [ ] **Step 1: Write the failing tests**

In `EmailToLeadServiceTest.cls`:

```apex
@IsTest
static void createdLeadCarriesTheAcquisitionRecordType() {
    // Arrange the same LeadRequest the existing happy-path test uses, then:
    Test.startTest();
    Lead created = EmailToLeadService.createLeadFromExtracted(request);
    Test.stopTest();

    Lead readBack = [SELECT RecordType.DeveloperName FROM Lead WHERE Id = :created.Id];
    Assert.areEqual('Acquisition_Broker', readBack.RecordType.DeveloperName,
        'An inbound broker Lead without this record type matches no sharing rule once Lead OWD '
        + 'is Private, so the acquisitions team never sees it.');
}
```

In `BrokerPortalServiceTest.cls`, the equivalent against the guest submission entry point.

- [ ] **Step 2: Run both and confirm they fail**

```bash
sf apex run test --class-names EmailToLeadServiceTest,BrokerPortalServiceTest --result-format human --wait 10
```

Expected: FAIL — `RecordType.DeveloperName` is null.

- [ ] **Step 3: Add the shared helper to `EmailToLeadService`**

```apex
    /** The Acquisition_Broker record type developer name. */
    @TestVisible
    private static final String RT_ACQUISITION_BROKER = 'Acquisition_Broker';

    /**
     * The Acquisition_Broker record type Id, or null when it does not exist in this org.
     *
     * 🔴 GUARDED ON isAvailable(), AND THAT GUARD IS A FAIL-SOFT BACKSTOP, NOT THE FIX.
     *
     * MEASURED 2026-08-10: record-type visibility is enforced on Apex DML UNCONDITIONALLY.
     * `AccessLevel` / SYSTEM_MODE governs CRUD, FLS and sharing — never record-type visibility.
     * A plain `insert` for a principal lacking the record type throws
     * `System.DmlException: INVALID_CROSS_REFERENCE_KEY, Record Type ID`.
     *
     * Both callers here run as a principal nobody provisions through the UI — the Email Service
     * context user and the Site guest user. WITHOUT this guard, a provisioning gap would not
     * produce an unstamped Lead, it would DESTROY THE INBOUND EMAIL: no Lead, no registry claim,
     * no audit row, no bounce. That is the ContentPublication failure shape and it is the one
     * outcome this pipeline must never have.
     *
     * WITH the guard, the same gap costs an UNSTAMPED Lead — recoverable, and detectable by
     * `scripts/apex/verify-record-type-backfill.apex`.
     *
     * ⚠ THE REAL FIX IS PROVISIONING, NOT THIS GUARD. Confirm in-org that the Email Service
     * context user and the Site guest user can both access Lead.Acquisition_Broker; the guard
     * exists so that verifying it is a task rather than an incident.
     *
     * Null remains a legitimate answer for the ONE case it should be: the record type does not
     * exist in this org at all. The caller then leaves RecordTypeId unset and the platform
     * applies its default, so an inbound broker email is still routable in an org where the
     * segregation metadata has not deployed yet. This pipeline must never lose an email over a
     * metadata gap.
     *
     * A describe, not a query. It costs no SOQL, which is why it does not move this class's
     * pinned query budget.
     */
    public static Id acquisitionBrokerRecordTypeId() {
        Schema.RecordTypeInfo info = Lead.SObjectType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(RT_ACQUISITION_BROKER);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }
```

- [ ] **Step 4: Stamp in `createLeadFromExtracted`**

Immediately after `Lead lead = new Lead();` (line 217):

```apex
        Id acqRt = acquisitionBrokerRecordTypeId();
        if (acqRt != null) {
            lead.RecordTypeId = acqRt;
        }
```

- [ ] **Step 5: Stamp in `BrokerPortalService`**

After `l.Status = 'New';` (line 80), reusing the helper rather than re-deriving it:

```apex
        Id acqRt = EmailToLeadService.acquisitionBrokerRecordTypeId();
        if (acqRt != null) {
            l.RecordTypeId = acqRt;
        }
```

⚠ `BrokerPortalService` is `without sharing` and runs as the Site guest user, who may well not hold record type visibility. That is exactly why `acquisitionBrokerRecordTypeId()` above **keeps the `isAvailable()` guard**: record-type visibility is enforced on DML regardless of mode (measured 2026-08-10), so without the guard an unprovisioned guest user would make the portal submission **throw** rather than land unstamped.

🔴 **The guard is a backstop, not the fix.** Verify in-org that both the Site guest user and the Email Service context user can access `Lead.Acquisition_Broker`, and record the result in the runbook. If either cannot, its Leads land unstamped and become invisible after Task 12 — silently. `scripts/apex/verify-record-type-backfill.apex` is the detector, and Task 14 must re-run it *after* exercising both pipelines, not only before the OWD flip.

- [ ] **Step 6: Run the tests and the pinned governor tests**

```bash
sf apex run test --class-names EmailToLeadServiceTest,BrokerPortalServiceTest,ExtractAddressQueueableTest --result-format human --wait 10
```

Expected: PASS, including `ExtractAddressQueueableTest`'s `lastRunQueryCount` / `lastRunDmlCount` assertions — a describe costs no SOQL, so those budgets must be **unchanged**. If any moved, the helper is querying when it should be describing.

- [ ] **Step 7: Commit**

```bash
git add force-app/main/default/classes/EmailToLeadService.cls force-app/main/default/classes/BrokerPortalService.cls force-app/main/default/classes/EmailToLeadServiceTest.cls force-app/main/default/classes/BrokerPortalServiceTest.cls
git commit -m "feat: stamp Acquisition_Broker record type on inbound and portal Leads"
```

---

## Task 5: Stamp the converted Contact and Account

Standard lead conversion does **not** map Contact or Account record types — the converted records take whatever is default for the *running user's profile*, and profiles are `.forceignore`d, so that is unverifiable fiction. This task makes it deterministic.

**Delegate to:** `salesforce-developer`, then `salesforce-unit-testing`

**Files:**
- Modify: `force-app/main/default/classes/LeadConvertService.cls:150-161` and the class-header governor contract at lines 40-80
- Test: `force-app/main/default/classes/LeadConvertServiceTest.cls:836-841`

**Interfaces:**
- Consumes: `Contact.Broker`, `Account.Broker_Firm` from Task 1.
- Produces: `LeadConvertService`'s documented budget becomes **2 SOQL / ≤5 DML, constant in batch size** (was 2 / 3).

- [ ] **Step 1: Write the failing test**

```apex
@IsTest
static void conversionStampsBrokerRecordTypesOnContactAndAccount() {
    Lead l = TestDataFactory.createLead(true);

    Test.startTest();
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setConvertedStatus('Converted');
    Database.LeadConvertResult res = Database.convertLead(lc);
    Test.stopTest();

    Assert.isTrue(res.isSuccess(), 'Conversion must succeed.');

    Contact c = [SELECT RecordType.DeveloperName FROM Contact WHERE Id = :res.getContactId()];
    Account a = [SELECT RecordType.DeveloperName FROM Account WHERE Id = :res.getAccountId()];

    Assert.areEqual('Broker', c.RecordType.DeveloperName,
        'Conversion does not map Contact record types - without the explicit stamp the converted '
        + 'Contact takes the running user profile default, which may be Investor.');
    Assert.areEqual('Broker_Firm', a.RecordType.DeveloperName,
        'An Account left off Broker_Firm matches no sharing rule once Account OWD is Private.');
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
sf apex run test --class-names LeadConvertServiceTest --result-format human --wait 10
```

Expected: FAIL on the Contact assertion.

- [ ] **Step 3: Add the stamp to `stampConvertedOpportunities`**

The Lead carries `ConvertedContactId` and `ConvertedAccountId`, so no query is needed. Append after `stampBrokerContactRoles(oppToLead);` (line 161):

```apex
        // 4. Stamp the converted Contact and Account with their broker record types.  [DML 4, DML 5]
        stampConvertedPartyRecordTypes(oppToLead.values());
```

Then add the method:

```apex
    /**
     * Stamp Contact.Broker and Account.Broker_Firm onto the records standard conversion just
     * created.
     *
     * WHY THIS EXISTS. Database.convertLead does NOT map record types onto the Contact or the
     * Account - they take whatever is default for the RUNNING USER'S PROFILE. Profiles are
     * .forceignore'd in this repo, so that default is unverifiable from source and can differ
     * per persona. Once Account OWD is Private, an Account on the wrong record type (or none)
     * matches no sharing rule and takes its Contacts with it, because Contact is
     * ControlledByParent. Deterministic beats depending on a file we cannot read.
     *
     * GOVERNOR CONTRACT - this raises the class budget from 3 DML to <=5, and that was a
     * deliberate decision, not drift. Both statements are isEmpty()-guarded and both are
     * CONSTANT IN BATCH SIZE, which is the property that actually matters: one statement for
     * every converted Contact in the chunk, one for every Account, never one per record.
     * A matched Account (LeadConvertMatchService reusing an existing broker firm) is already
     * stamped from the Task 3 backfill, so the ordinary repeat-broker path writes fewer rows -
     * but the statement count is what is pinned, so the contract states the worst case.
     *
     * Both use allOrNone = false for the same reason the Property insert does: a failure to
     * stamp a record type must not roll back the structural RecordTypeId / Property__c link on
     * the Opportunity, which `update updates` guarantees all-or-none above.
     */
    private static void stampConvertedPartyRecordTypes(List<Lead> convertedLeads) {
        Id contactRt = recordTypeId(Contact.SObjectType, 'Broker');
        Id accountRt = recordTypeId(Account.SObjectType, 'Broker_Firm');

        List<Contact> contactUpdates = new List<Contact>();
        List<Account> accountUpdates = new List<Account>();
        Set<Id> seenAccountIds = new Set<Id>();

        for (Lead l : convertedLeads) {
            if (contactRt != null && l.ConvertedContactId != null) {
                contactUpdates.add(new Contact(Id = l.ConvertedContactId, RecordTypeId = contactRt));
            }
            // Several Leads can converge on ONE Account (Smart Lead Conversion reuses a firm),
            // and a duplicate Id in one DML statement throws DUPLICATE_VALUE.
            if (accountRt != null && l.ConvertedAccountId != null && seenAccountIds.add(l.ConvertedAccountId)) {
                accountUpdates.add(new Account(Id = l.ConvertedAccountId, RecordTypeId = accountRt));
            }
        }

        if (!contactUpdates.isEmpty()) {
            Database.update(contactUpdates, false);
        }
        if (!accountUpdates.isEmpty()) {
            Database.update(accountUpdates, false);
        }
    }

    /**
     * The Id of a record type by developer name, or null when it does not exist in this org or
     * is not available to the running user. A describe, not a query - it costs no SOQL, so the
     * class's 2-SOQL contract is unchanged.
     */
    private static Id recordTypeId(Schema.SObjectType sobjType, String developerName) {
        Schema.RecordTypeInfo info = sobjType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }
```

- [ ] **Step 4: Confirm the Lead trigger query selects both fields**

`stampConvertedPartyRecordTypes` reads `ConvertedContactId` and `ConvertedAccountId` off `Trigger.new`. Verify `LeadConvertTrigger` / the handler passes Leads carrying them — in an after-update trigger `Trigger.new` holds every field, so no selector change should be needed. If a test fails with a null Id, that assumption is wrong and the fields must be added to whichever selector feeds the call.

- [ ] **Step 5: Update the class header and the governor test**

In the header block at lines 40-80, change the DML contract from 3 to `<=5` and add the two new statements to the enumeration, keeping the existing explanation of why `update updates` stays all-or-none.

In `LeadConvertServiceTest.cls` around line 841, update the pinned `dmlDelta` assertion to the new ceiling, with a message that names *why* it moved:

```apex
    Assert.isTrue(dmlDelta <= 5,
        'LeadConvertService is pinned at <=5 DML statements, CONSTANT in batch size. It moved '
        + 'from 3 to 5 in the IR segregation change to stamp the converted Contact and Account '
        + 'record types. A number that grows with record count means a statement moved inside a loop.');
    Assert.areEqual(2, queryDelta, 'SOQL is unchanged at 2 - record types are resolved by describe, not query.');
```

- [ ] **Step 6: Run the tests**

```bash
sf apex run test --class-names LeadConvertServiceTest,LeadConvertMatchServiceTest,LeadConvertActionServiceTest --result-format human --wait 10
```

Expected: all PASS, `queryDelta` still exactly 2.

- [ ] **Step 7: Add the bulk assertion**

The governor contract claims constancy in batch size, so prove it:

```apex
@IsTest
static void conversionDmlIsConstantAcross251Leads() {
    List<Lead> leads = TestDataFactory.createLeads(251, true);
    List<Database.LeadConvert> converts = new List<Database.LeadConvert>();
    for (Lead l : leads) {
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus('Converted');
        converts.add(lc);
    }

    Integer dmlBefore = Limits.getDmlStatements();
    Test.startTest();
    Database.convertLead(converts, false);
    Test.stopTest();
    Integer dmlDelta = Limits.getDmlStatements() - dmlBefore;

    Assert.isTrue(dmlDelta <= 5,
        '251 Leads must cost the same DML statements as one. A delta that scales with the input '
        + 'means a statement is inside the loop.');
}
```

Run it and confirm PASS.

- [ ] **Step 8: Commit**

```bash
git add force-app/main/default/classes/LeadConvertService.cls force-app/main/default/classes/LeadConvertServiceTest.cls
git commit -m "feat: stamp broker record types on converted Contact and Account"
```

---

## Task 6: Scope conversion matching to the broker record type

The populations never overlap today. This makes that a structural guarantee rather than a policy the next person can violate.

**Delegate to:** `salesforce-developer`, then `salesforce-unit-testing`

**Files:**
- Modify: `force-app/main/default/classes/ContactSelector.cls:225-238` (`selectByEmails`)
- Modify: `force-app/main/default/classes/AccountSelector.cls:72-84` (`selectByNames`)
- Test: `force-app/main/default/classes/ContactSelectorTest.cls`, `force-app/main/default/classes/AccountSelectorTest.cls`

**Interfaces:**
- Consumes: `Contact.Broker`, `Account.Broker_Firm` from Task 1.
- Produces: signatures unchanged — `selectByEmails(Set<String>)` and `selectByNames(Set<String>)` keep returning `List<Contact>` / `List<Account>`. `LeadConvertMatchService` needs **no change**.

- [ ] **Step 1: Write the failing tests**

In `ContactSelectorTest.cls`:

```apex
@IsTest
static void selectByEmailsIgnoresInvestorContacts() {
    Account investorAccount = TestDataFactory.createAccount(false);
    investorAccount.RecordTypeId = [SELECT Id FROM RecordType
        WHERE SobjectType = 'Account' AND DeveloperName = 'Investor_Entity' LIMIT 1].Id;
    insert investorAccount;

    Contact investor = TestDataFactory.createContact(investorAccount.Id, false);
    investor.Email = 'shared.address@example.invalid';
    investor.RecordTypeId = [SELECT Id FROM RecordType
        WHERE SobjectType = 'Contact' AND DeveloperName = 'Investor' LIMIT 1].Id;
    insert investor;

    List<Contact> matched = ContactSelector.selectByEmails(
        new Set<String>{ 'shared.address@example.invalid' });

    Assert.areEqual(0, matched.size(),
        'An investor Contact must never be a lead-conversion match target - attaching an '
        + 'acquisition deal to an IR Contact would drag it across the security boundary.');
}
```

The mirror test in `AccountSelectorTest.cls` for an `Investor_Entity` Account matched by name.

- [ ] **Step 2: Run both and confirm they fail**

```bash
sf apex run test --class-names ContactSelectorTest,AccountSelectorTest --result-format human --wait 10
```

Expected: FAIL — both return 1 row.

- [ ] **Step 3: Scope `ContactSelector.selectByEmails`**

```apex
    public static List<Contact> selectByEmails(Set<String> emails) {
        if (emails == null || emails.isEmpty()) {
            return new List<Contact>();
        }
        return [
            SELECT Id, Email, AccountId, CreatedDate
            FROM Contact
            WHERE Email IN :emails
              AND AccountId != null
              AND RecordType.DeveloperName = 'Broker'
            WITH USER_MODE
            ORDER BY CreatedDate ASC, Id ASC
        ];
    }
```

Extend the existing method Javadoc with:

```
     * RECORD TYPE SCOPE (2026-08-10, IR segregation). Restricted to Contact.Broker. The broker
     * and investor populations are disjoint by policy, so this filter changes no behaviour
     * today - it makes the guarantee STRUCTURAL. Without it, one shared email address between
     * a broker and an investor would attach an acquisition deal to an IR Contact and its
     * Investor_Entity Account, which is precisely the boundary this module exists to hold.
     *
     * ⚠ A Contact on the MASTER record type will not match. That is intended and is why the
     * Task 3 backfill is gated on a zero-row query before OWD flips.
```

- [ ] **Step 4: Scope `AccountSelector.selectByNames`** the same way with `AND RecordType.DeveloperName = 'Broker_Firm'`, and the parallel Javadoc note.

- [ ] **Step 5: Run the tests**

```bash
sf apex run test --class-names ContactSelectorTest,AccountSelectorTest,LeadConvertMatchServiceTest --result-format human --wait 10
```

Expected: PASS. `LeadConvertMatchServiceTest`'s 3-SOQL pin is unchanged — a `WHERE` clause adds no query.

- [ ] **Step 6: Commit**

```bash
git add force-app/main/default/classes/ContactSelector.cls force-app/main/default/classes/AccountSelector.cls force-app/main/default/classes/ContactSelectorTest.cls force-app/main/default/classes/AccountSelectorTest.cls
git commit -m "feat: scope lead-conversion matching to broker record types"
```

---

## Task 7: Backfill every existing record

🔴 This must run **after** Tasks 4 and 5 are deployed. Between the backfill finishing and the stamping code shipping, every inbound broker email would mint an unstamped Lead — and an unstamped Lead disappears at Task 12.

**Delegate to:** `salesforce-admin`

**Files:**
- Create: `scripts/apex/backfill-record-types.apex`
- Create: `scripts/apex/verify-record-type-backfill.apex`

**Interfaces:**
- Consumes: the six record types (Task 1), the stamps (Tasks 4, 5).
- Produces: **zero** Lead, Contact or Account rows without an acquisition-side record type. Task 12 is gated on this.

- [ ] **Step 1: Write the verification query first**

`scripts/apex/verify-record-type-backfill.apex`:

```apex
// GATE for plan Task 12. Every count below MUST be 0 before OWD flips to Private.
// A record with no record type (or the Master type) matches no criteria-based sharing rule
// and becomes invisible to everyone except its owner the instant OWD changes.
Id leadRt    = Lead.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Acquisition_Broker').getRecordTypeId();
Id contactRt = Contact.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Broker').getRecordTypeId();
Id accountRt = Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Broker_Firm').getRecordTypeId();

System.debug('Leads unstamped:    ' + [SELECT COUNT() FROM Lead    WHERE RecordTypeId != :leadRt    AND IsConverted = false]);
System.debug('Contacts unstamped: ' + [SELECT COUNT() FROM Contact WHERE RecordTypeId != :contactRt]);
System.debug('Accounts unstamped: ' + [SELECT COUNT() FROM Account WHERE RecordTypeId != :accountRt]);
```

- [ ] **Step 2: Run it and record the starting counts**

```bash
sf apex run --file scripts/apex/backfill-record-types.apex 2>&1 | grep -E "unstamped"
```

Write the three numbers into the runbook. They are the "before" half of the evidence.

- [ ] **Step 3: Write the backfill**

`scripts/apex/backfill-record-types.apex`:

```apex
// Backfill: every pre-existing Lead / Contact / Account is Acquisitions (spec section 1 -
// IR is net new, so there is nothing to classify). Chunked at 10,000 to stay inside the
// anonymous-Apex DML row limit; re-run until the verify script reports 0.
Id leadRt    = Lead.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Acquisition_Broker').getRecordTypeId();
Id contactRt = Contact.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Broker').getRecordTypeId();
Id accountRt = Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Broker_Firm').getRecordTypeId();

// Accounts FIRST - Contact.Record_Type_Matches_Account (plan Task 8) is not deployed yet,
// but ordering it this way keeps the data consistent at every intermediate point anyway.
List<Account> accounts = [SELECT Id FROM Account WHERE RecordTypeId != :accountRt LIMIT 10000];
for (Account a : accounts) { a.RecordTypeId = accountRt; }
update accounts;
System.debug('Accounts stamped: ' + accounts.size());

List<Contact> contacts = [SELECT Id FROM Contact WHERE RecordTypeId != :contactRt LIMIT 10000];
for (Contact c : contacts) { c.RecordTypeId = contactRt; }
update contacts;
System.debug('Contacts stamped: ' + contacts.size());

List<Lead> leads = [SELECT Id FROM Lead WHERE RecordTypeId != :leadRt AND IsConverted = false LIMIT 10000];
for (Lead l : leads) { l.RecordTypeId = leadRt; }
update leads;
System.debug('Leads stamped: ' + leads.size());
```

⚠ Updating a Lead fires `LeadConvertTrigger`; updating an Account or Contact fires no trigger in this repo. The Lead trigger's `justConvertedByOpportunity` short-circuits unless `IsConverted` flips false→true, so a record-type-only update does no extra work — but run the backfill **outside business hours** anyway, because it touches every Lead in the org.

- [ ] **Step 4: Run the backfill, then the verify, repeatedly**

```bash
sf apex run --file scripts/apex/backfill-record-types.apex
sf apex run --file scripts/apex/verify-record-type-backfill.apex 2>&1 | grep -E "unstamped"
```

Repeat until all three counts read **0**. Record the final zero-row output in the runbook — that output is the Task 12 gate.

- [ ] **Step 5: Commit**

```bash
git add scripts/apex/backfill-record-types.apex scripts/apex/verify-record-type-backfill.apex docs/2026-08-10-ir-segregation-runbook.md
git commit -m "chore: record type backfill scripts and verified zero-row gate"
```

---

## Task 8: Validation rules keeping Contact and Account in agreement

Contact visibility is *derived* from its Account. The boundary leaks the moment the two disagree, so these rules are part of the deliverable, not hardening for later.

**Delegate to:** `salesforce-admin`

**Files:**
- Create: `force-app/main/default/objects/Contact/validationRules/Record_Type_Matches_Account.validationRule-meta.xml`
- Create: `force-app/main/default/objects/Account/validationRules/Record_Type_Is_Immutable.validationRule-meta.xml`

**Interfaces:**
- Consumes: the six record types (Task 1), a completed backfill (Task 7 — deploying these before the backfill would block the backfill itself).

- [ ] **Step 1: Write the Contact rule**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ValidationRule xmlns="http://soap.sforce.com/2006/04/metadata">
    <!--
        THIS NOTE LIVES IN A COMMENT, NOT IN <description>. ValidationRule.Description is capped
        at 255 characters. The comment must sit INSIDE the root element - one placed above the
        root breaks `sf` deploy at source conversion.

        WHY THIS RULE IS SECURITY, NOT DATA HYGIENE. Contact OWD is ControlledByParent, so a
        Contact is visible to exactly the people who can see its Account. The Account record type
        is what the criteria-based sharing rules key on. A Broker Contact parented to an
        Investor_Entity Account is therefore visible to Investor Relations and invisible to
        Acquisitions - the exact leak this feature exists to prevent - and nothing else in the
        system would notice.

        IT BLOCKS REPARENTING AS WELL AS CREATION, deliberately. Moving a Contact between
        Accounts is the quieter half of the leak: no field on the Contact changes, so no audit
        trail reads as suspicious.

        A Contact with NO Account is permitted (Contact.AccountId is optional and the standard
        Contact Layout allows it). Such a Contact is owner-visible only under ControlledByParent,
        so it cannot leak across the boundary - it is simply invisible, which fails safe.
    -->
    <fullName>Record_Type_Matches_Account</fullName>
    <active>true</active>
    <description>A Contact's record type must match its Account's. Contact sharing is inherited from the Account, so a mismatch leaks the Contact to the wrong team. See the XML comment in this file.</description>
    <errorConditionFormula>AND(
    NOT(ISBLANK(AccountId)),
    NOT(ISBLANK(TEXT(Account.RecordType.DeveloperName))),
    OR(
        AND(
            RecordType.DeveloperName = "Broker",
            Account.RecordType.DeveloperName &lt;&gt; "Broker_Firm"
        ),
        AND(
            RecordType.DeveloperName = "Investor",
            Account.RecordType.DeveloperName &lt;&gt; "Investor_Entity"
        )
    )
)</errorConditionFormula>
    <errorDisplayField>AccountId</errorDisplayField>
    <errorMessage>A Broker contact must belong to a Broker Firm account, and an Investor contact to an Investor Entity account. Record-level access is inherited from the account, so a mismatch would expose this contact to the wrong team.</errorMessage>
</ValidationRule>
```

⚠ `RecordType.DeveloperName` in a validation-rule formula is referenced without `TEXT()`. If the org rejects the formula, try `$RecordType.DeveloperName` for the record's own type — verify the exact accepted syntax against this org rather than assuming.

- [ ] **Step 2: Write the Account rule**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ValidationRule xmlns="http://soap.sforce.com/2006/04/metadata">
    <!--
        THIS NOTE LIVES IN A COMMENT, NOT IN <description>. See the sibling Contact rule for the
        reason - description is capped at 255 characters and the comment must be inside the root.

        AN ACCOUNT'S RECORD TYPE IS THE SHARING BOUNDARY FOR ITSELF AND EVERY CONTACT UNDER IT.
        Changing it does not move one record, it moves the whole subtree across the team
        boundary, silently and with no per-Contact audit trail. There is no legitimate
        end-user workflow that does this: a misfiled Account is an admin correction, made
        deliberately, not a mid-workflow edit.

        ADMINS ARE OUT OF SCOPE BY DESIGN (spec section 5) - a user with Modify All Data is
        already outside this boundary everywhere else in the org, so the rule does not attempt
        to stop them; $Permission is deliberately not consulted. If an exemption is ever needed,
        add a custom permission and gate on $Permission - never widen the rule itself.
    -->
    <fullName>Record_Type_Is_Immutable</fullName>
    <active>true</active>
    <description>An account's record type cannot be changed - it is the sharing boundary for the account and every contact under it. See the XML comment in this file.</description>
    <errorConditionFormula>AND(
    NOT(ISNEW()),
    ISCHANGED(RecordTypeId)
)</errorConditionFormula>
    <errorMessage>An account's record type cannot be changed. It controls which team can see this account and all of its contacts. Contact a system administrator if this account is filed under the wrong team.</errorMessage>
</ValidationRule>
```

- [ ] **Step 3: Deploy**

```bash
sf project deploy start --source-dir force-app/main/default/objects/Contact/validationRules --source-dir force-app/main/default/objects/Account/validationRules
```

- [ ] **Step 4: Prove both rules fire**

Run the full suite first — a validation rule can break unrelated tests that build cross-type fixtures:

```bash
sf apex run test --test-level RunLocalTests --result-format human --wait 30
```

Then verify by hand in the org: create an Investor Contact under a Broker Firm Account and confirm the save is refused; edit a Broker Firm Account's record type and confirm the same. A rule that deploys green but never fires is the failure mode here.

- [ ] **Step 5: Commit**

```bash
git add force-app/main/default/objects/Contact/validationRules force-app/main/default/objects/Account/validationRules
git commit -m "feat: validation rules keeping Contact and Account record types in agreement"
```

---

## Task 9: Scope duplicate and matching rules per record type

**Delegate to:** `salesforce-admin`

**Files:** in-org configuration; document in `docs/2026-08-10-ir-segregation-runbook.md`

**Interfaces:**
- Consumes: the six record types (Task 1).

- [ ] **Step 1: Inventory the active rules**

Setup → Duplicate Management → Duplicate Rules. `TestDataFactory`'s header notes the standard Account rule is Alert/Allow with fuzzy name matching. Record every active rule on Lead, Contact and Account with its current condition.

- [ ] **Step 2: Add a record-type condition to each**

For every active rule, add a condition restricting it to a single record type — so a broker Account is never offered as a merge candidate for an investor Account, and vice versa. A cross-type merge is the one operation that would collapse the boundary in a single click and cannot be undone.

- [ ] **Step 3: Verify by hand**

Create an `Investor_Entity` Account with the same name as an existing `Broker_Firm` Account. Confirm no duplicate alert is raised across the two types, and that same-type duplicate detection still works.

- [ ] **Step 4: Record in the runbook and commit**

```bash
git add docs/2026-08-10-ir-segregation-runbook.md
git commit -m "docs: record-type-scoped duplicate rules"
```

---

## Task 10: The IR persona — role, group, permission sets, PSG

**Delegate to:** `salesforce-admin`

**Files:**
- Create: `force-app/main/default/roles/Investor_Relations_Manager.role-meta.xml`
- Create: `force-app/main/default/permissionsets/DPEG_IR_Edit.permissionset-meta.xml`
- Create: `force-app/main/default/permissionsets/DPEG_IR_View.permissionset-meta.xml`
- Create: `force-app/main/default/permissionsets/DPEG_App_Investor_Relations.permissionset-meta.xml`
- Create: `force-app/main/default/permissionsetgroups/DPEG_Investor_Relations_PSG.permissionsetgroup-meta.xml`
- Modify: `force-app/main/default/groups/Investor_Relations.group-meta.xml`
- Modify: `force-app/main/default/permissionsetgroups/DPEG_Principal_PSG.permissionsetgroup-meta.xml`

**Interfaces:**
- Consumes: the six record types (Task 1), the `Investor_Relations` app (Task 13 — deploy the app first or omit `applicationVisibilities` until it exists).
- Produces: `DPEG_Investor_Relations_PSG`, assignable to IR users. Task 11's sharing rules target the `Investor_Relations` group.

- [ ] **Step 1: Create the role**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Role xmlns="http://soap.sforce.com/2006/04/metadata">
    <name>Investor Relations Manager</name>
    <parentRole>DPEG_Principal</parentRole>
</Role>
```

🔴 The parent **must** be `DPEG_Principal`, making this a sibling of `Acquisitions_Analyst`, `Transactions_Coordinator` and `Property_Management_Coordinator`. Siblings do not see each other's records under Private OWD, so the boundary holds by construction. Parenting it anywhere else — under `Acquisitions_Analyst`, for instance — silently grants acquisitions upward access to every IR record.

- [ ] **Step 2: Fix the group flag**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Group xmlns="http://soap.sforce.com/2006/04/metadata">
    <doesIncludeBosses>false</doesIncludeBosses>
    <name>Investor Relations</name>
</Group>
```

`doesIncludeBosses` was `true` while `DPEG_Acquisitions_Team` is `false`. Setting it to `false` leaves the **role hierarchy** as the single mechanism granting the Principal upward access. Two mechanisms doing one job is how this drifts.

- [ ] **Step 3: Create `DPEG_IR_Edit`**

Model it on `DPEG_Contact_Edit`. It must contain:
- `<objectPermissions>` for Lead, Contact and Account: `allowCreate`/`allowRead`/`allowEdit` true, `allowDelete` false, **`viewAllRecords` and `modifyAllRecords` both `false`**.
- `<recordTypeVisibilities>` for `Lead.IR_Investor`, `Contact.Investor`, `Account.Investor_Entity` — **and nothing else**. Granting only the IR type is what stops an IR user creating a broker record at all.
- `<fieldPermissions>` for the standard Lead/Contact/Account fields IR needs.

🔴 **Do NOT grant any broker field**: `Contact.Broker_Firm__c`, `Broker_License__c`, `Broker_Priority__c`, `Broker_Specialty__c`, `Broker_Status__c`, `Is_Broker__c`, `Active_Listings__c`, `Avg_Days_On_Market__c`, `Closed_Volume__c`, `Deals_Submitted__c`, `Deals_Won__c`, `Offers_Received__c`, `NDA_On_File__c`. Nor any acquisitions Lead field (`Guidance_Price__c`, `NOI__c`, `Property_Address__c`, `Deal_Type__c`, and the rest of the deal-screening set).

🔴 **Every grant must be declared in-file** — a PermissionSet deploy replaces the whole `<fieldPermissions>` set.

- [ ] **Step 4: Create `DPEG_IR_View`** — the same file with every `<editable>` and `allowCreate`/`allowEdit` set to `false`.

- [ ] **Step 5: Create `DPEG_App_Investor_Relations`**

Model exactly on `DPEG_App_Acquisition.permissionset-meta.xml`: `applicationVisibilities` for `Investor_Relations` plus `tabSettings` for `standard-Lead`, `standard-Contact`, `standard-Account` and `standard-report`. **No object or field permissions** — the description must say so, matching the sibling file's wording.

- [ ] **Step 6: Create the PSG**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PermissionSetGroup xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Investor Relations persona: Edit on the IR-record-type Lead/Contact/Account population only, plus Investor Relations app and tab visibility. Deliberately carries NO acquisition, disposition, transaction or property-management access - the IR boundary is enforced by record type visibility here and by criteria-based sharing rules on Account and Lead.</description>
    <label>DPEG Investor Relations PSG</label>
    <permissionSets>DPEG_Base_Access</permissionSets>
    <permissionSets>DPEG_IR_Edit</permissionSets>
    <permissionSets>DPEG_App_Investor_Relations</permissionSets>
</PermissionSetGroup>
```

- [ ] **Step 7: Give the Principal read access to the IR side**

Add `<permissionSets>DPEG_IR_View</permissionSets>` to `DPEG_Principal_PSG.permissionsetgroup-meta.xml` and extend that file's `<description>` to mention IR. The Principal already sees IR records through the role hierarchy; without this they would have the record access and no object permission to use it.

- [ ] **Step 8: Deploy and verify**

```bash
sf project deploy start --source-dir force-app/main/default/roles --source-dir force-app/main/default/groups --source-dir force-app/main/default/permissionsets --source-dir force-app/main/default/permissionsetgroups
```

⚠ **Group and queue membership is not deployable.** Adding actual users to the `Investor_Relations` group is an in-org step — add it to the runbook.

- [ ] **Step 9: Commit**

```bash
git add force-app/main/default/roles force-app/main/default/groups force-app/main/default/permissionsets force-app/main/default/permissionsetgroups docs/2026-08-10-ir-segregation-runbook.md
git commit -m "feat: Investor Relations role, permission sets and PSG"
```

---

## Task 11: Criteria-based sharing rules

**Delegate to:** `salesforce-admin`

**Files:**
- Modify: `force-app/main/default/sharingRules/Account.sharingRules-meta.xml`
- Modify: `force-app/main/default/sharingRules/Lead.sharingRules-meta.xml`

**Interfaces:**
- Consumes: record types (Task 1), the `Investor_Relations` group (Task 10), a completed backfill (Task 7).
- Produces: the four rules Task 12's OWD flip depends on.

- [ ] **Step 1: G1 is ANSWERED — read this before writing anything**

Settled empirically against `usman-dpeg` on 2026-08-10 (check-only validation, commit `f941dce`):

1. ✅ **`RecordTypeId` IS accepted** as a criteria-based sharing rule field. The `Business_Unit__c` fallback is NOT needed and must not be built.
2. 🔴 **The criteria `<value>` is the record type LABEL, not the developer name.** `Broker_Firm` was rejected with `Picklist value does not exist`; `Broker Firm` was accepted. So: `Broker Firm`, `Investor Entity`, `Acquisition Broker`, `IR Investor`.
3. 🔴 **`<sharedTo>` accepts exactly ONE target per rule** — `sharedTo can only contain a single element`. **The four-rule design in the table above is not deployable as written.** Every multi-group grant becomes one rule per group, so the real count is **six**:

| Rule | Criteria (RecordTypeId = label) | Shared to |
|---|---|---|
| `Account_Broker_Firm_Internal_Acquisitions` | `Broker Firm` | `DPEG_Acquisitions_Team` |
| `Account_Broker_Firm_Internal_Transactions` | `Broker Firm` | `DPEG_Transactions_Team` |
| `Account_Broker_Firm_Internal_PropertyMgmt` | `Broker Firm` | `DPEG_Property_Mgmt_Team` |
| `Account_Investor_Entity_IR` | `Investor Entity` | `Investor_Relations` |
| `Lead_Acquisition_Broker` | `Acquisition Broker` | `DPEG_Acquisitions_Team` |
| `Lead_IR_Investor` | `IR Investor` | `Investor_Relations` |

The three `Broker Firm` rules carry **identical** criteria and identical `<accountSettings>`; only `<sharedTo>` differs.

**The first three already exist** in `sharingRules/Account.sharingRules-meta.xml` and have passed check-only validation. This task adds `Account_Investor_Entity_IR` and the two Lead rules, then deploys.

- [ ] **Step 2: Write the Account rules**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<SharingRules xmlns="http://soap.sforce.com/2006/04/metadata">
    <sharingCriteriaRules>
        <fullName>Account_Broker_Firm_Internal</fullName>
        <accessLevel>Edit</accessLevel>
        <accountSettings>
            <caseAccessLevel>None</caseAccessLevel>
            <contactAccessLevel>Edit</contactAccessLevel>
            <opportunityAccessLevel>None</opportunityAccessLevel>
        </accountSettings>
        <label>Account Broker Firm Internal</label>
        <sharedTo>
            <group>DPEG_Acquisitions_Team</group>
            <group>DPEG_Transactions_Team</group>
            <group>DPEG_Property_Mgmt_Team</group>
        </sharedTo>
        <criteriaItems>
            <field>RecordTypeId</field>
            <operation>equals</operation>
            <value>Broker Firm</value>
        </criteriaItems>
    </sharingCriteriaRules>
</SharingRules>
```

⚠ `contactAccessLevel` inside `<accountSettings>` is what actually carries the Contact across — Contact is `ControlledByParent`, so **this single element is the whole Contact half of the feature.** Set it to `Edit`; object CRUD in each permission set remains the ceiling, so Property Management stays read-only through `DPEG_PropertyMgmt_View` regardless.

⚠ The `<value>` for a `RecordTypeId` criterion is the record type **label**, not the developer name or the Id. Verify the exact accepted form against the org on the first rule before writing the other three.

- [ ] **Step 3: Write `Account_Investor_Entity_IR`** — the same shape, `<value>Investor Entity</value>`, `<sharedTo><group>Investor_Relations</group></sharedTo>`.

- [ ] **Step 4: Write the two Lead rules**

`Lead_Acquisition_Broker` (value `Acquisition Broker` → `DPEG_Acquisitions_Team`) and `Lead_IR_Investor` (value `IR Investor` → `Investor_Relations`), both `<accessLevel>Edit</accessLevel>`. Leads have no `<accountSettings>` block.

🔴 **Leave the existing `Lead_Acquisition_Queue_RW` `sharingOwnerRules` entry exactly as it is.** It is a separate mechanism covering queue-owned Leads and is not replaced by these.

- [ ] **Step 5: Deploy ONE AT A TIME**

🔴 A batch deploy of sharing rules rolls all of them back on a single failure. Add one rule to the file, deploy, confirm, then add the next:

```bash
sf project deploy start --source-dir force-app/main/default/sharingRules/Account.sharingRules-meta.xml
```

Between each, wait for the sharing recalculation to finish (Setup → Sharing Settings shows it in progress).

- [ ] **Step 6: Verify all four exist**

```bash
sf data query --query "SELECT Id, Name FROM AccountShare LIMIT 1"
```

Then confirm in Setup → Sharing Settings that all four rules are listed and recalculation has completed.

- [ ] **Step 7: Commit**

```bash
git add force-app/main/default/sharingRules
git commit -m "feat: criteria-based sharing rules for the IR-Acquisitions boundary"
```

---

## Task 12: The OWD flip

🔴 **Manual, in Setup, not deployable.** Everything before this is inert; everything after depends on it.

**Delegate to:** `salesforce-admin` (in-org), with the runbook as the record

**Files:**
- Modify: `docs/2026-08-10-ir-segregation-runbook.md`

**Interfaces:**
- Consumes: Tasks 7 (zero-row gate), 10 (groups populated), 11 (four rules recalculated).

- [ ] **Step 1: Re-run the Task 7 gate immediately before flipping**

```bash
sf apex run --file scripts/apex/verify-record-type-backfill.apex 2>&1 | grep -E "unstamped"
```

🔴 **All three counts must read 0.** Records created since the backfill are covered by the Tasks 4 and 5 stamps — but a non-zero count means one is missing, and flipping now makes those records invisible. **Do not proceed on a non-zero count.**

- [ ] **Step 2: Confirm every group has its members**

Group membership is not deployable. Verify in-org that `DPEG_Acquisitions_Team`, `DPEG_Transactions_Team`, `DPEG_Property_Mgmt_Team` and `Investor_Relations` all contain the right users. **An empty group plus Private OWD means that whole team loses access the moment you flip.**

- [ ] **Step 3: Flip Account AND Contact OWD**

🔴 **Three OWDs change here, not two.** Task 0 measured the org via `EntityDefinition.InternalSharingModel` and found **Contact is `ReadWrite`, not `ControlledByParent`** — the repo's `Contact.object-meta.xml` is wrong. Contact does **not** inherit Account sharing today, so flipping Account alone would leave every Contact Public Read/Write and deliver no Contact boundary at all.

Setup → Sharing Settings → Edit:
- **Account and Contract: `Private`**
- **Contact: `Controlled by Parent`** ← the correction. Safe because the org has **0 Contacts without an Account** (measured 2026-08-10); under `Controlled by Parent` an Account-less Contact would be visible to its owner alone.

Setting Contact to `Controlled by Parent` rather than `Private` is deliberate: it makes the Contact boundary *derived from* the Account boundary, so the two cannot drift apart. `<contactAccessLevel>` in the Task 11 Account rules is then the single mechanism carrying Contact access.

- [ ] **Step 4: Flip Lead OWD**

Same screen, Lead: **Private**. Task 0 measured it as `ReadWriteTransfer`, so this is a real change, not a no-op.

- [ ] **Step 5: Wait for recalculation, then read both back**

Sharing recalculation on a Private flip is asynchronous and org-wide. Wait for completion, then re-read both values from Setup and record them, with the timestamp, in the runbook. **A green screen is not the proof — the read-back is.**

- [ ] **Step 6: Smoke-test as a real persona immediately**

Log in as (or use Login As on) a non-admin acquisitions user and confirm they still see their Leads and broker Contacts. **An admin check proves nothing** — admins are outside this boundary by design. If access is gone, the fastest rollback is flipping OWD back to Public while the cause is diagnosed; the record types, rules and stamps are all harmless in a Public-OWD org.

- [ ] **Step 7: Commit the runbook**

```bash
git add docs/2026-08-10-ir-segregation-runbook.md
git commit -m "docs: record the OWD flip and its verified read-back"
```

---

## Task 13: The Investor Relations app

**Delegate to:** `salesforce-admin`

**Files:**
- Create: `force-app/main/default/applications/Investor_Relations.app-meta.xml`
- Create: `force-app/main/default/objects/Lead/listViews/IR_Investor_Leads.listView-meta.xml`
- Create: `force-app/main/default/objects/Contact/listViews/IR_Investor_Contacts.listView-meta.xml`

**Interfaces:**
- Consumes: record types (Task 1), `DPEG_App_Investor_Relations` (Task 10).

- [ ] **Step 1: Create the app**

Model on `applications/Acquisition.app-meta.xml`. Tabs: `standard-Lead`, `standard-Contact`, `standard-Account`, `standard-report`. `<uiType>Lightning</uiType>`, `<navType>Standard</navType>`.

- [ ] **Step 2: Create the list views**

Filter on `RecordType.DeveloperName` equals `IR_Investor` / `Investor`. Columns: name, company/account, email, phone, owner.

⚠ List views are a **convenience, not a control** — sharing already prevents an IR user seeing broker records. Do not describe them as a security measure anywhere.

- [ ] **Step 3: Add matching acquisition-side list views** on Lead and Contact, so the existing team's views stay explicit rather than relying on "everything I can see".

- [ ] **Step 4: Deploy and verify as an IR user**

```bash
sf project deploy start --source-dir force-app/main/default/applications --source-dir force-app/main/default/objects/Lead/listViews --source-dir force-app/main/default/objects/Contact/listViews
```

- [ ] **Step 5: Commit**

```bash
git add force-app/main/default/applications force-app/main/default/objects/Lead/listViews force-app/main/default/objects/Contact/listViews
git commit -m "feat: Investor Relations app and record-type list views"
```

---

## Task 14: Persona UAT

The whole feature is a claim about what four different people can and cannot see. Only this task tests that claim.

**Delegate to:** `salesforce-admin` with the user present

**Files:**
- Modify: `docs/2026-08-10-ir-segregation-runbook.md`

- [ ] **Step 1: Build the fixture**

In the org, create one `IR_Investor` Lead, one `Investor_Entity` Account, and one `Investor` Contact under it. Note their Ids. Note the Ids of one existing broker Lead, broker Account and broker Contact.

- [ ] **Step 2: Run the matrix**

Log in as each persona and record ✅/❌ for every cell. **Every cell must match.**

| Persona | Broker Lead | Broker Account | Broker Contact | IR Lead | IR Account | IR Contact |
|---|---|---|---|---|---|---|
| Acquisitions analyst | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Transactions coordinator | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| PM coordinator | ✅ | ✅ read-only | ✅ | ❌ | ❌ | ❌ |
| **IR manager** | **❌** | **❌** | **❌** | ✅ | ✅ | ✅ |
| Principal | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

Test each ❌ **three ways** — direct URL to the record Id, global search, and a report — because sharing failures often surface in only one of them.

- [ ] **Step 3: Test the enforcement rules by hand**

Confirm: an IR user cannot pick a broker record type when creating a Lead (Task 2/10 visibility); creating an `Investor` Contact under a `Broker_Firm` Account is refused (Task 8); changing an Account's record type is refused (Task 8).

- [ ] **Step 4: Confirm the broker pipeline still works end to end**

Send a test broker email through the inbound pipeline. Confirm the Lead is created, carries `Acquisition_Broker`, is visible to the acquisitions persona, and that its claim and Task were written. Then submit through the Broker Portal as a guest and confirm the same.

🔴 This is where a missing guest-user record type grant (Task 4 Step 5) surfaces. The guest path degrades **silently** to an unstamped Lead, which is invisible to everyone under Private OWD.

- [ ] **Step 5: Run the full suite one final time**

```bash
sf apex run test --test-level RunLocalTests --result-format human --wait 30
```

- [ ] **Step 6: Record results and commit**

```bash
git add docs/2026-08-10-ir-segregation-runbook.md
git commit -m "docs: persona UAT results for the IR-Acquisitions boundary"
```

---

## Self-review notes

**Spec coverage:** §3 architecture → Tasks 1, 10, 12. §4 sharing rules → Task 11. §5 keeping Accounts and Contacts separate → Tasks 8 (validation rules), 9 (duplicate rules), 2 and 10 (record type visibility as the create-side half), 14 (the `viewAllRecords` audit is covered by the Step 2 matrix). §6 Apex → Tasks 4, 5, 6. §7 sequencing → task order, with the T2-before-T3 constraint enforced by Task 7's opening note. §8 testing → Tasks 3, 5, 14. §10 open items → Task 0.

**Known gap, deliberately left:** the spec's §5 row about auditing `viewAllRecords` has no standing automated check. It is verified by hand at Task 14 and stated as a constraint in Task 10 Step 3. A repo-level guard would be a useful follow-up but does not belong in this plan's critical path.

**Type consistency:** the six record type developer names are used verbatim in Tasks 1, 2, 3, 4, 5, 6, 7, 8, 10, 11 and 13. `recordTypeId(Schema.SObjectType, String)` is defined privately in both `TestDataFactory` (Task 3) and `LeadConvertService` (Task 5) — deliberate duplication, since neither class should take a dependency on the other, and `EmailToLeadService.acquisitionBrokerRecordTypeId()` is public precisely because `BrokerPortalService` reuses it.
