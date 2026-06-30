# Broker Assignments (PM Leasing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native Broker Assignments feature in the Property Management Lightning app — a custom object tracking which broker lists which property, a dashboard list page, a record detail page, a broker scorecard, and a daily stale-check-in reminder job — faithfully matching the approved prototype.

**Architecture:** One custom object `Broker_Assignment__c` (lookups to `Property_Asset__c` and `Contact`) backs everything. Cross-object **formula fields** surface property/broker display data (mirroring `Onboarding__c`). A single `with sharing` Apex controller returns DTOs to `@wire`d LWCs (the established `OnboardingController` pattern). LWCs reuse the existing `c-list-datatable` (+`pill`/`progress` cell types) and `c-stat-card`. Flexipage app-page tabs host the dashboards; a flexipage record page hosts the detail LWC. A `Schedulable` Apex job creates follow-up Tasks for overdue check-ins.

**Tech Stack:** Salesforce DX metadata (API 62.0), Apex (`with sharing`, `@AuraEnabled`), LWC, flexipages, `sf` CLI v2 on Windows PowerShell.

## Global Constraints

- **Visual source of truth:** `docs/superpowers/specs/broker-tracker-prototype.html`. Every LWC must reproduce the markup, spacing, colors, and copy of its corresponding prototype section. The spec is `docs/superpowers/specs/2026-06-30-broker-assignments-design.md`.
- **Object name is `Broker_Assignment__c`** — never `Broker_Listing__c` (a different, existing object; do not touch it).
- **Property link = lookup to `Property_Asset__c`**; address/sqft/type are reached by spanning `Property_Asset__r.Property__r.*` (Square_Footage__c, Address__c) and `Property_Asset__r.Property_Type__c`.
- **Broker = lookup to `Contact`**; firm/email/phone come from `Contact.Broker_Firm__c` / `Contact.Email` / `Contact.Phone`.
- **Status picklist values (exact):** `Active` (default) · `Fully Leased` · `Replaced` · `Terminated`. **Reason picklist:** `Leased Up` · `Performance Issue` · `Company Decision` · `Other`.
- **Thresholds are 14 (warn/“Follow up”, amber) and 21 (overdue, red)**, used identically in Apex (constants `WARN_DAYS=14`, `OVERDUE_DAYS=21`) and LWC (`@api warnDays=14`, `@api overdueDays=21`). Flags apply only to `Active` listings: `> 21` → Overdue; `>= 14 && <= 21` → Follow up; `< 14` → On track.
- **Status colors (exact):** Active bg `#EBF9F1` fg `#146830` dot `#22A652`; Fully Leased bg `#E2E0DB` fg `#3F3C38` dot `#8A8680`; Replaced bg `#FDF0F0` fg `#B52020` dot `#D93636`; Terminated bg `#F9CECE` fg `#8B1A1A` dot `#B52020`; amber flag bg `#FDF5E6` fg `#7A4A00` dot/bar `#C88010`; red flag bg `#FDF0F0` fg `#8B1A1A` dot/bar `#D93636`. Brand navy `#0C1E3C`/`#132850`, gold `#C8A045`, link `#1A3464`, neutral surface `#F5F3EF`, border-subtle `#E2E0DB`, border-default `#C8C4BE`, text `#1A1714`/`#524F4A`/`#8A8680`.
- **Records are never deleted.** Closing a listing only changes `Status__c`.
- **All LWC bundles use `apiVersion` 62.0.** All Apex uses `with sharing`. Controller read methods are `@AuraEnabled(cacheable=true)`; mutation methods are `@AuraEnabled` (no cache).
- **Deploy (PowerShell):** `sf project deploy start -d <path> --ignore-conflicts`. **Test:** `sf apex run test --tests <Class> --result-format human --synchronous`. **Anonymous apex:** `sf apex run -f <file>`. Use the PowerShell tool for `sf data query` (the Bash tool mis-parses `C:\Program Files`).
- **Commit after each task.** Branch: create/checkout `feature/broker-assignments` before Task 1 (do NOT commit to `main`). Commit messages end with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- There is **no LWC Jest harness** in this repo. LWC/flexipage/tab/app/perm-set tasks are verified by a successful `sf project deploy start` (the platform compiles the bundle and validates references) plus a described visual check. Apex tasks carry real unit tests run with `sf apex run test`.

---

## File Structure

**New Apex** (`force-app/main/default/classes/`):
- `BrokerAssignmentController.cls` (+`.cls-meta.xml`) — DTOs + read methods + mutation actions.
- `BrokerAssignmentControllerTest.cls` (+meta) — unit tests for the controller.
- `BrokerCheckInReminderSchedulable.cls` (+meta) — daily `Schedulable` that creates follow-up Tasks for overdue Active assignments.
- `BrokerCheckInReminderSchedulableTest.cls` (+meta) — unit tests for the job.

**New object** (`force-app/main/default/objects/Broker_Assignment__c/`):
- `Broker_Assignment__c.object-meta.xml` — autonumber name `BA-{0000}`.
- `fields/*.field-meta.xml` — the 14 fields in the spec.
- `compactLayouts/Broker_Assignment_Compact.compactLayout-meta.xml`.
- `listViews/All.listView-meta.xml`.

**New LWCs** (`force-app/main/default/lwc/`):
- `brokerAssignmentKpis/` — 4 KPI stat cards (reuses `c-stat-card`).
- `brokerAssignmentList/` — the assignments table (reuses `c-list-datatable`) + status tabs + broker filter + New Assignment button.
- `brokerPortfolioStatus/` — donut + stacked bar + legend.
- `brokerCheckInAlerts/` — 4 alert tiles.
- `brokerAssignmentDetail/` — record-page **main** detail (Details/History/Notes tabs, status path, Log Check-in / Replace / Close-out). No internal right column — the sidebar is a separate LWC.
- `brokerListingActivity/` — record-page **right sidebar**: Listing Active Days + Last Check-In.
- `brokerTotals/` — app-page **right rail**: brokers with their total properties.
- `brokerScorecard/` — per-broker outcome cards.

**New UI metadata:**
- `flexipages/Broker_Assignments_Home.flexipage-meta.xml` — app page (KPIs + list + rail).
- `flexipages/Broker_Assignment_Record_Page.flexipage-meta.xml` — record page (detail LWC).
- `flexipages/Broker_Scorecard.flexipage-meta.xml` — app page (scorecard).
- `tabs/Broker_Assignments.tab-meta.xml` — flexipage tab → `Broker_Assignments_Home`.
- `tabs/Broker_Scorecard.tab-meta.xml` — flexipage tab → `Broker_Scorecard`.
- `tabs/Broker_Assignment__c.tab-meta.xml` — object tab (record access + standard New).

**Modified:**
- `applications/Property_Management.app-meta.xml` — add 3 tabs + a `View` actionOverride for `Broker_Assignment__c`.
- `permissionsets/Property_Management_Access.permissionset-meta.xml` — object/field/class/tab access for the new object.

**New script:**
- `scripts/seed-broker-assignments.apex` — seed brokers, property assets, and 10 assignments (so the dashboards render with realistic data).

---

## Task 1: `Broker_Assignment__c` object, fields, object tab, perm-set object/field access

**Files:**
- Create: `force-app/main/default/objects/Broker_Assignment__c/Broker_Assignment__c.object-meta.xml`
- Create: `force-app/main/default/objects/Broker_Assignment__c/fields/Property_Asset__c.field-meta.xml`
- Create: `…/fields/Broker__c.field-meta.xml`
- Create: `…/fields/Status__c.field-meta.xml`
- Create: `…/fields/Listing_Start_Date__c.field-meta.xml`
- Create: `…/fields/Listing_End_Date__c.field-meta.xml`
- Create: `…/fields/Reason_Ended__c.field-meta.xml`
- Create: `…/fields/Last_Check_In_Date__c.field-meta.xml`
- Create: `…/fields/Days_Since_Check_In__c.field-meta.xml`
- Create: `…/fields/Property_Display_Name__c.field-meta.xml`
- Create: `…/fields/Property_Type_Display__c.field-meta.xml`
- Create: `…/fields/Address_Display__c.field-meta.xml`
- Create: `…/fields/Gross_Sq_Ft__c.field-meta.xml`
- Create: `…/fields/Broker_Name__c.field-meta.xml`
- Create: `…/fields/Broker_Firm__c.field-meta.xml`
- Create: `…/fields/Broker_Email__c.field-meta.xml`
- Create: `…/fields/Broker_Phone__c.field-meta.xml`
- Create: `…/fields/Leased_Area__c.field-meta.xml`
- Create: `…/fields/Vacant_Area__c.field-meta.xml`
- Create: `…/fields/Listing_Active_Days__c.field-meta.xml`
- Create: `force-app/main/default/objects/Property_Asset__c/fields/Vacant_Area__c.field-meta.xml`
- Create: `force-app/main/default/objects/Broker_Assignment__c/compactLayouts/Broker_Assignment_Compact.compactLayout-meta.xml`
- Create: `force-app/main/default/objects/Broker_Assignment__c/listViews/All.listView-meta.xml`
- Create: `force-app/main/default/tabs/Broker_Assignment__c.tab-meta.xml`
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Produces: object `Broker_Assignment__c` with these fields named exactly as in the spec; lookups `Property_Asset__c`, `Broker__c`; picklists `Status__c`, `Reason_Ended__c`; dates `Listing_Start_Date__c`, `Listing_End_Date__c`, `Last_Check_In_Date__c`; editable number `Leased_Area__c`; formula fields `Days_Since_Check_In__c` (Number), `Listing_Active_Days__c` (Number), `Vacant_Area__c` (Number), `Property_Display_Name__c`, `Property_Type_Display__c`, `Address_Display__c`, `Gross_Sq_Ft__c` (Number), `Broker_Name__c`, `Broker_Firm__c`, `Broker_Email__c`, `Broker_Phone__c`. Also adds `Property_Asset__c.Vacant_Area__c` (Number). The object tab API name is `Broker_Assignment__c`.

- [ ] **Step 1: Object definition.** Create `Broker_Assignment__c.object-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <deploymentStatus>Deployed</deploymentStatus>
    <description>One broker-to-property listing assignment. Records are never deleted; closing a listing changes Status.</description>
    <enableActivities>true</enableActivities>
    <enableHistory>true</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <label>Broker Assignment</label>
    <pluralLabel>Broker Assignments</pluralLabel>
    <nameField>
        <displayFormat>BA-{0000}</displayFormat>
        <label>Assignment Number</label>
        <type>AutoNumber</type>
    </nameField>
    <sharingModel>ReadWrite</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
```

- [ ] **Step 2: Lookup fields.** `Property_Asset__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Property_Asset__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <label>Property Asset</label>
    <referenceTo>Property_Asset__c</referenceTo>
    <relationshipLabel>Broker Assignments</relationshipLabel>
    <relationshipName>Broker_Assignments</relationshipName>
    <required>false</required>
    <type>Lookup</type>
</CustomField>
```

`Broker__c.field-meta.xml` (lookup to Contact; the prototype filters to brokers — enforce with a lookup filter):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Broker__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <label>Broker</label>
    <referenceTo>Contact</referenceTo>
    <relationshipLabel>Broker Assignments</relationshipLabel>
    <relationshipName>Broker_Assignments</relationshipName>
    <required>false</required>
    <type>Lookup</type>
    <lookupFilter>
        <active>true</active>
        <booleanFilter>1</booleanFilter>
        <errorMessage>The selected Contact is not flagged as a broker (Is_Broker__c).</errorMessage>
        <filterItems>
            <field>Contact.Is_Broker__c</field>
            <operation>equals</operation>
            <value>true</value>
        </filterItems>
        <isOptional>false</isOptional>
    </lookupFilter>
</CustomField>
```

- [ ] **Step 3: Picklists.** `Status__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Status__c</fullName>
    <label>Status</label>
    <required>true</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Active</fullName><default>true</default><label>Active</label></value>
            <value><fullName>Fully Leased</fullName><default>false</default><label>Fully Leased</label></value>
            <value><fullName>Replaced</fullName><default>false</default><label>Replaced</label></value>
            <value><fullName>Terminated</fullName><default>false</default><label>Terminated</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
```

`Reason_Ended__c.field-meta.xml` (same shape, `required=false`, values `Leased Up`, `Performance Issue`, `Company Decision`, `Other`, none default).

- [ ] **Step 4: Date fields.** `Listing_Start_Date__c`, `Listing_End_Date__c`, `Last_Check_In_Date__c` — each:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Listing_Start_Date__c</fullName>
    <label>Listing Start Date</label>
    <required>false</required>
    <type>Date</type>
</CustomField>
```

(Repeat with `Listing_End_Date__c`/"Listing End Date" and `Last_Check_In_Date__c`/"Last Check-In Date".)

- [ ] **Step 5: Days-idle formula.** `Days_Since_Check_In__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Days_Since_Check_In__c</fullName>
    <label>Days Since Check-In</label>
    <formula>IF(ISBLANK(Last_Check_In_Date__c), null, TODAY() - Last_Check_In_Date__c)</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <precision>18</precision>
    <scale>0</scale>
    <required>false</required>
    <type>Number</type>
    <unique>false</unique>
</CustomField>
```

- [ ] **Step 6: Property display formulas.** Mirror `Onboarding__c` exactly.

`Property_Display_Name__c` → `<formula>Property_Asset__r.Property_Name__c</formula>`, type `Text`.
`Property_Type_Display__c` → `<formula>TEXT(Property_Asset__r.Property_Type__c)</formula>`, type `Text`.
`Address_Display__c` → `<formula>Property_Asset__r.Property__r.Address__c</formula>`, type `Text`.
`Gross_Sq_Ft__c` → `<formula>Property_Asset__r.Property__r.Square_Footage__c</formula>`, type `Number` precision 18 scale 0.

Each uses `<formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>`. Example `Address_Display__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Address_Display__c</fullName>
    <label>Address</label>
    <formula>Property_Asset__r.Property__r.Address__c</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <required>false</required>
    <type>Text</type>
</CustomField>
```

- [ ] **Step 7: Broker display formulas.** `Broker_Name__c` → `<formula>Broker__r.Name</formula>`; `Broker_Firm__c` → `<formula>Broker__r.Broker_Firm__c</formula>`; `Broker_Email__c` → `<formula>Broker__r.Email</formula>`; `Broker_Phone__c` → `<formula>Broker__r.Phone</formula>`. All type `Text`, `formulaTreatBlanksAs` `BlankAsZero`. (Note: `Broker_Firm__c` here is a **formula** on the new object — distinct from `Contact.Broker_Firm__c`.)

- [ ] **Step 7b: Area + listing-active fields.** `Property_Asset__c/fields/Vacant_Area__c.field-meta.xml` (source of vacancy):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Vacant_Area__c</fullName>
    <label>Vacant Area (Sq Ft)</label>
    <precision>18</precision>
    <scale>0</scale>
    <required>false</required>
    <type>Number</type>
    <unique>false</unique>
</CustomField>
```

`Broker_Assignment__c/fields/Leased_Area__c.field-meta.xml` (editable listing field):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Leased_Area__c</fullName>
    <label>Leased Area (Sq Ft)</label>
    <precision>18</precision>
    <scale>0</scale>
    <required>false</required>
    <type>Number</type>
    <unique>false</unique>
</CustomField>
```

`Broker_Assignment__c/fields/Vacant_Area__c.field-meta.xml` (display formula → property section):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Vacant_Area__c</fullName>
    <label>Vacant Area (Sq Ft)</label>
    <formula>Property_Asset__r.Vacant_Area__c</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <precision>18</precision>
    <scale>0</scale>
    <required>false</required>
    <type>Number</type>
    <unique>false</unique>
</CustomField>
```

`Broker_Assignment__c/fields/Listing_Active_Days__c.field-meta.xml` (days the listing has been active — to end date if closed, else to today):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Listing_Active_Days__c</fullName>
    <label>Listing Active Days</label>
    <formula>IF(ISBLANK(Listing_Start_Date__c), null, IF(ISBLANK(Listing_End_Date__c), TODAY(), Listing_End_Date__c) - Listing_Start_Date__c)</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <precision>18</precision>
    <scale>0</scale>
    <required>false</required>
    <type>Number</type>
    <unique>false</unique>
</CustomField>
```

- [ ] **Step 8: Compact layout + list view.** `Broker_Assignment_Compact.compactLayout-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CompactLayout xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Broker_Assignment_Compact</fullName>
    <fields>Property_Display_Name__c</fields>
    <fields>Broker_Name__c</fields>
    <fields>Status__c</fields>
    <fields>Days_Since_Check_In__c</fields>
    <label>Broker Assignment Compact</label>
</CompactLayout>
```

`listViews/All.listView-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>All</fullName>
    <columns>Property_Display_Name__c</columns>
    <columns>Broker_Name__c</columns>
    <columns>Status__c</columns>
    <columns>Last_Check_In_Date__c</columns>
    <columns>Days_Since_Check_In__c</columns>
    <filterScope>Everything</filterScope>
    <label>All</label>
</ListView>
```

- [ ] **Step 9: Object tab.** `tabs/Broker_Assignment__c.tab-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <customObject>true</customObject>
    <motif>Custom51: Apple</motif>
</CustomTab>
```

- [ ] **Step 10: Perm set — object + field + tab access.** In `Property_Management_Access.permissionset-meta.xml`, add an `<objectPermissions>` block for `Broker_Assignment__c` (allowCreate/Edit/Read true, allowDelete false — records are never deleted; modifyAll/viewAll false), `<fieldPermissions>` editable+readable for every editable field (`Property_Asset__c`, `Broker__c`, `Status__c`, `Listing_Start_Date__c`, `Listing_End_Date__c`, `Reason_Ended__c`, `Last_Check_In_Date__c`, `Leased_Area__c`) and **readable-only** (`editable=false`) for the 11 formula fields (`Days_Since_Check_In__c`, `Listing_Active_Days__c`, `Vacant_Area__c`, `Property_Display_Name__c`, `Property_Type_Display__c`, `Address_Display__c`, `Gross_Sq_Ft__c`, `Broker_Name__c`, `Broker_Firm__c`, `Broker_Email__c`, `Broker_Phone__c`), plus editable+readable for `Property_Asset__c.Vacant_Area__c`, and a `<tabSettings>` for `Broker_Assignment__c` = `Visible`. Insert the blocks in the existing alphabetical-ish grouping. Object block example:

```xml
    <objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Broker_Assignment__c</object>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
```

Formula field example (editable=false; formula fields CANNOT be editable or the deploy fails):

```xml
    <fieldPermissions>
        <editable>false</editable>
        <field>Broker_Assignment__c.Days_Since_Check_In__c</field>
        <readable>true</readable>
    </fieldPermissions>
```

- [ ] **Step 11: Deploy.**

Run: `sf project deploy start -d force-app/main/default/objects/Broker_Assignment__c -d force-app/main/default/objects/Property_Asset__c/fields/Vacant_Area__c.field-meta.xml -d force-app/main/default/tabs/Broker_Assignment__c.tab-meta.xml -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml --ignore-conflicts`
Expected: `Status: Succeeded`. If a formula references a non-existent path it fails here — fix the spanning path against `Property_Asset__r.Property__r.*` (or `Property_Asset__r.Vacant_Area__c` for the vacancy formula).

- [ ] **Step 12: Smoke test the schema.** With PowerShell:

Run: `sf data query -q "SELECT Id, QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName = 'Broker_Assignment__c'"`
Expected: one row.
Then create one record and read the formula back (replace `<ASSET_ID>`/`<CONTACT_ID>` with real ids from `SELECT Id FROM Property_Asset__c LIMIT 1` / `SELECT Id FROM Contact WHERE Is_Broker__c = true LIMIT 1`; if none exist, skip — Task 2 seeds them):
Run: `sf data create record -s Broker_Assignment__c -v "Status__c=Active Last_Check_In_Date__c=2026-06-01"`
Run: `sf data query -q "SELECT Name, Status__c, Days_Since_Check_In__c FROM Broker_Assignment__c ORDER BY CreatedDate DESC LIMIT 1"`
Expected: `Days_Since_Check_In__c` = 29 (2026-06-30 − 2026-06-01). Delete the smoke record afterward: `sf data delete record -s Broker_Assignment__c -w "Name=<the BA-#>"`.

- [ ] **Step 13: Commit.**

```bash
git add force-app/main/default/objects/Broker_Assignment__c force-app/main/default/objects/Property_Asset__c/fields/Vacant_Area__c.field-meta.xml force-app/main/default/tabs/Broker_Assignment__c.tab-meta.xml force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "feat: Broker_Assignment__c object, fields, tab, perm-set access"
```

---

## Task 2: Seed script (brokers, property assets, 10 assignments)

**Files:**
- Create: `scripts/seed-broker-assignments.apex`

**Interfaces:**
- Consumes: `Broker_Assignment__c` and its fields (Task 1).
- Produces: ~4 broker Contacts (`Is_Broker__c=true`), ≥6 `Property_Asset__c` (with parent `Property__c` carrying Address/Square_Footage/Asset_Type), and 10 `Broker_Assignment__c` rows mirroring the prototype seed (lines 430–455 of the prototype). Dates are anchored to a fixed "today" of 2026-06-30.

- [ ] **Step 1: Write the seed script.** It must be idempotent-ish (guard by a marker) so re-runs don't duplicate. Use the prototype's exact properties/brokers/assignments. Key shape:

```apex
// scripts/seed-broker-assignments.apex
// Seeds the Broker Assignments demo dataset to match the prototype.
Date TODAY_ANCHOR = Date.newInstance(2026, 6, 30);

// 1) Brokers as Contacts (Is_Broker__c=true). Upsert by a deterministic email.
Map<String, Contact> brokers = new Map<String, Contact>();
brokers.put('b1', new Contact(LastName='Webb', FirstName='Marcus', Email='marcus.webb@lee-associates.com', Phone='(713) 555-0142', Is_Broker__c=true, Broker_Firm__c='Lee & Associates', Broker_Status__c='Active'));
brokers.put('b2', new Contact(LastName='Nair', FirstName='Priya', Email='priya.nair@cbre.com', Phone='(281) 555-0198', Is_Broker__c=true, Broker_Firm__c='CBRE Houston', Broker_Status__c='Active'));
brokers.put('b3', new Contact(LastName='Reyes', FirstName='Daniel', Email='daniel.reyes@colliers.com', Phone='(832) 555-0173', Is_Broker__c=true, Broker_Firm__c='Colliers', Broker_Status__c='Active'));
brokers.put('b4', new Contact(LastName='Koch', FirstName='Sandra', Email='sandra.koch@naipartners.com', Phone='(713) 555-0226', Is_Broker__c=true, Broker_Firm__c='NAI Partners', Broker_Status__c='Active'));
upsert brokers.values() Email; // Email is the external-ish key; if Email isn't unique-upsertable, query-then-insert by Email instead.

// 2) Properties + Property Assets. Create Property__c (address/sqft/type) then Property_Asset__c linked to it.
//    Reuse if a Property_Asset__c with the same Property_Name__c (Name) already exists.
//    Prototype properties (id,name,addr,sqft,type → Asset_Type__c maps to Retail/Mixed-Use/etc.; Property_Asset__c.Property_Type__c is Retail/Industrial/Multifamily/Office/Mixed-Use):
//      p1 Westgate Plaza      / 8420 Westheimer Rd, Houston, TX / 42000 / Retail
//      p2 Sterling Crossing   / 1205 N Shepherd Dr, Houston, TX / 28500 / Retail
//      p3 Magnolia Commons    / 3340 FM 1960, Spring, TX        / 65200 / Retail
//      p4 Bayou Bend Center   / 770 Studemont St, Houston, TX   / 19800 / Mixed-Use
//      p5 Katy Mills Strip    / 5000 Katy Fwy, Katy, TX         / 51400 / Retail
//      p6 Heights Marketplace / 1820 W 18th St, Houston, TX     / 33750 / Retail
// Build Map<String,Property_Asset__c> keyed p1..p6.

// 3) Assignments (10) — prototype lines 444–454. status/start/end/reason/lastCheckIn exactly:
//   a1 p1 b1 Active        2026-05-12  -          -                  2026-06-25
//   a2 p2 b2 Active        2026-04-02  -          -                  2026-06-04
//   a3 p3 b3 Active        2026-03-15  -          -                  2026-06-12
//   a4 p4 b4 Fully Leased  2025-09-01  2026-02-20 Leased Up          2026-02-15
//   a5 p5 b1 Replaced      2025-06-10  2025-11-30 Performance Issue  2025-11-20
//   a6 p5 b2 Active        2025-12-01  -          -                  2026-06-28
//   a7 p6 b3 Terminated    2025-08-15  2026-01-10 Company Decision   2026-01-05
//   a8 p6 b4 Active        2026-01-15  -          -                  2026-06-08
//   a9 p1 b3 Replaced      2024-11-01  2025-04-30 Performance Issue  2025-04-20
//   a10 p3 b4 Fully Leased 2024-05-01  2025-02-28 Leased Up          2025-02-20
// Guard: if [SELECT COUNT() FROM Broker_Assignment__c] > 0 then System.debug('already seeded') and return.
insert assignmentList;
System.debug('Seeded ' + assignmentList.size() + ' broker assignments.');
```

Write the full concrete Apex (no comments-as-code) — expand each map literal and the assignment list. If `Contact.Email` is not upsertable as an external id, query existing brokers by Email first, insert missing, then build the id map. Map `Asset_Type__c` on `Property__c` (values incl. Retail, Mixed-Use) and `Property_Type__c` on `Property_Asset__c` (Retail/Mixed-Use) per the table above.

- [ ] **Step 2: Run the seed.**

Run: `sf apex run -f scripts/seed-broker-assignments.apex`
Expected: debug log `Seeded 10 broker assignments.` and no exceptions.

- [ ] **Step 3: Verify counts.**

Run (PowerShell): `sf data query -q "SELECT Status__c, COUNT(Id) c FROM Broker_Assignment__c GROUP BY Status__c"`
Expected: Active 5, Fully Leased 2, Replaced 2, Terminated 1.

- [ ] **Step 4: Commit.**

```bash
git add scripts/seed-broker-assignments.apex
git commit -m "chore: seed script for Broker Assignments demo data"
```

---

## Task 3: `BrokerAssignmentController` + tests

**Files:**
- Create: `force-app/main/default/classes/BrokerAssignmentController.cls` (+`.cls-meta.xml`, `<apiVersion>62.0</apiVersion>`, status Active)
- Create: `force-app/main/default/classes/BrokerAssignmentControllerTest.cls` (+meta)
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml` (add `classAccesses` for `BrokerAssignmentController`)

**Interfaces:**
- Consumes: `Broker_Assignment__c` + fields (Task 1).
- Produces (LWC tasks consume these exact signatures):
  - `WARN_DAYS = 14`, `OVERDUE_DAYS = 21` (public static final Integer).
  - `Kpis getKpis()` → `{Integer total, active, overdue, leased}`.
  - `List<Row> getAssignments()` → each `Row {Id id; Id brokerId; String propertyName; String propertyAddr; String brokerName; String brokerFirm; String status; Date startDate; Date endDate; Date lastCheckIn; Integer daysIdle; String reason;}` (all rows, unsorted; LWC filters/sorts).
  - `Portfolio getPortfolio()` → `{Integer total, active, leased, replaced, terminated}`.
  - `Alerts getAlerts()` → `{Integer overdue, dueSoon, onTrack, active}`.
  - `List<BrokerCard> getScorecard()` → each `{Id brokerId; String name; String firm; Integer active, leased, replaced, terminated, total;}`.
  - `List<BrokerTotal> getBrokerTotals()` → each `{Id brokerId; String name; String firm; Integer totalProperties;}` (distinct `Property_Asset__c` per broker), ordered by `totalProperties` desc.
  - `Detail getDetail(Id assignmentId)` → `{Id id; String propertyName, propertyType, propertyAddr; Integer grossSqFt, vacantArea, leasedArea, activeDays; String brokerName, brokerFirm, brokerEmail, brokerPhone; String status; Date startDate, endDate, lastCheckIn; Integer daysIdle; String reason; Id propertyAssetId; List<HistoryRow> history;}`.
  - `HistoryRow {Id id; String brokerName, brokerFirm, status; Date startDate, endDate; String reason; Boolean current;}`.
  - `void logCheckIn(Id assignmentId)` — sets `Last_Check_In_Date__c = Date.today()`.
  - `void closeOut(Id assignmentId, String status, Date endDate, String reason)` — sets Status/end/reason (status ∈ Fully Leased/Replaced/Terminated).
  - `Id replaceBroker(Id assignmentId, Id newBrokerId, Date effectiveDate, String reason)` — marks the old `Replaced` (end=effectiveDate, reason), inserts a new `Active` row (same Property_Asset__c, Broker=newBrokerId, start=lastCheckIn=effectiveDate), returns the new id.

- [ ] **Step 1: Write the failing tests.** `BrokerAssignmentControllerTest.cls`. `@testSetup` builds a Property + Property_Asset + 2 broker Contacts + assignments covering each status and each flag band. Use `Date.today()` offsets so the days-idle bands are deterministic (e.g. lastCheckIn today-30 = overdue, today-17 = dueSoon, today-3 = onTrack). Tests:

```apex
@isTest
private class BrokerAssignmentControllerTest {
    @testSetup static void setup() {
        Property__c pr = new Property__c(Name='Westgate Plaza', Address__c='8420 Westheimer Rd', City__c='Houston', State__c='TX', Square_Footage__c=42000, Asset_Type__c='Retail');
        insert pr;
        Property_Asset__c pa = new Property_Asset__c(Name='Westgate Plaza', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active', Vacant_Area__c=8000);
        insert pa;
        List<Contact> bk = new List<Contact>{
            new Contact(LastName='Webb', Email='mw@x.com', Phone='1', Is_Broker__c=true, Broker_Firm__c='Lee'),
            new Contact(LastName='Nair', Email='pn@x.com', Phone='2', Is_Broker__c=true, Broker_Firm__c='CBRE')
        };
        insert bk;
        Date t = Date.today();
        insert new List<Broker_Assignment__c>{
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[0].Id, Status__c='Active', Listing_Start_Date__c=t.addDays(-40), Last_Check_In_Date__c=t.addDays(-30), Leased_Area__c=12000), // overdue
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[1].Id, Status__c='Active', Listing_Start_Date__c=t.addDays(-25), Last_Check_In_Date__c=t.addDays(-17)), // dueSoon
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[0].Id, Status__c='Active', Listing_Start_Date__c=t.addDays(-10), Last_Check_In_Date__c=t.addDays(-3)),  // onTrack
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[1].Id, Status__c='Fully Leased', Listing_Start_Date__c=t.addDays(-300), Listing_End_Date__c=t.addDays(-120), Reason_Ended__c='Leased Up', Last_Check_In_Date__c=t.addDays(-125)),
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=bk[0].Id, Status__c='Replaced', Listing_Start_Date__c=t.addDays(-400), Listing_End_Date__c=t.addDays(-250), Reason_Ended__c='Performance Issue', Last_Check_In_Date__c=t.addDays(-255))
        };
    }
    @isTest static void kpis() {
        BrokerAssignmentController.Kpis k = BrokerAssignmentController.getKpis();
        System.assertEquals(5, k.total);
        System.assertEquals(3, k.active);
        System.assertEquals(1, k.overdue, 'only the 30-day-idle Active is > 21');
        System.assertEquals(1, k.leased);
    }
    @isTest static void alerts() {
        BrokerAssignmentController.Alerts a = BrokerAssignmentController.getAlerts();
        System.assertEquals(1, a.overdue);
        System.assertEquals(1, a.dueSoon);
        System.assertEquals(1, a.onTrack);
        System.assertEquals(3, a.active);
    }
    @isTest static void portfolio() {
        BrokerAssignmentController.Portfolio p = BrokerAssignmentController.getPortfolio();
        System.assertEquals(5, p.total);
        System.assertEquals(3, p.active);
        System.assertEquals(1, p.leased);
        System.assertEquals(1, p.replaced);
        System.assertEquals(0, p.terminated);
    }
    @isTest static void rowsAndDetailAndHistory() {
        List<BrokerAssignmentController.Row> rows = BrokerAssignmentController.getAssignments();
        System.assertEquals(5, rows.size());
        Id anId = rows[0].id;
        BrokerAssignmentController.Detail d = BrokerAssignmentController.getDetail(anId);
        System.assertEquals('Westgate Plaza', d.propertyName);
        System.assertEquals(5, d.history.size(), 'all 5 share one Property Asset');
        System.assert(d.grossSqFt == 42000);
        System.assertEquals(8000, d.vacantArea, 'vacancy spans from the Property Asset');
        System.assertNotEquals(null, d.activeDays);
    }
    @isTest static void scorecard() {
        List<BrokerAssignmentController.BrokerCard> cards = BrokerAssignmentController.getScorecard();
        System.assertEquals(2, cards.size());
        Integer totals = 0; for (BrokerAssignmentController.BrokerCard c : cards) totals += c.total;
        System.assertEquals(5, totals);
    }
    @isTest static void brokerTotals() {
        List<BrokerAssignmentController.BrokerTotal> t = BrokerAssignmentController.getBrokerTotals();
        System.assertEquals(2, t.size());
        for (BrokerAssignmentController.BrokerTotal bt : t) System.assertEquals(1, bt.totalProperties, 'all assignments share one Property Asset');
    }
    @isTest static void logCheckInUpdates() {
        Broker_Assignment__c a = [SELECT Id FROM Broker_Assignment__c WHERE Status__c='Active' LIMIT 1];
        Test.startTest(); BrokerAssignmentController.logCheckIn(a.Id); Test.stopTest();
        Broker_Assignment__c after = [SELECT Last_Check_In_Date__c FROM Broker_Assignment__c WHERE Id=:a.Id];
        System.assertEquals(Date.today(), after.Last_Check_In_Date__c);
    }
    @isTest static void closeOutChangesStatus() {
        Broker_Assignment__c a = [SELECT Id FROM Broker_Assignment__c WHERE Status__c='Active' LIMIT 1];
        Test.startTest(); BrokerAssignmentController.closeOut(a.Id, 'Fully Leased', Date.today(), 'Leased Up'); Test.stopTest();
        Broker_Assignment__c after = [SELECT Status__c, Listing_End_Date__c, Reason_Ended__c FROM Broker_Assignment__c WHERE Id=:a.Id];
        System.assertEquals('Fully Leased', after.Status__c);
        System.assertEquals('Leased Up', after.Reason_Ended__c);
        System.assertEquals(Date.today(), after.Listing_End_Date__c);
    }
    @isTest static void replaceBrokerOpensNewKeepsOld() {
        Broker_Assignment__c a = [SELECT Id, Property_Asset__c FROM Broker_Assignment__c WHERE Status__c='Active' LIMIT 1];
        Contact nb = [SELECT Id FROM Contact WHERE Is_Broker__c=true AND Email='pn@x.com' LIMIT 1];
        Test.startTest();
        Id newId = BrokerAssignmentController.replaceBroker(a.Id, nb.Id, Date.today(), 'Performance Issue');
        Test.stopTest();
        Broker_Assignment__c oldA = [SELECT Status__c, Listing_End_Date__c, Reason_Ended__c FROM Broker_Assignment__c WHERE Id=:a.Id];
        Broker_Assignment__c newA = [SELECT Status__c, Broker__c, Property_Asset__c, Listing_Start_Date__c FROM Broker_Assignment__c WHERE Id=:newId];
        System.assertEquals('Replaced', oldA.Status__c);
        System.assertEquals('Active', newA.Status__c);
        System.assertEquals(nb.Id, newA.Broker__c);
        System.assertEquals(a.Property_Asset__c, newA.Property_Asset__c);
    }
}
```

- [ ] **Step 2: Run tests — verify they FAIL** (class doesn't exist yet).

Run: `sf apex run test --tests BrokerAssignmentControllerTest --result-format human --synchronous`
Expected: compile error / `does not exist`.

- [ ] **Step 3: Implement the controller.** Single SOQL over `Broker_Assignment__c` (selecting the formula display fields + lookups) reused by all read methods. Full class:

```apex
public with sharing class BrokerAssignmentController {
    public static final Integer WARN_DAYS = 14;
    public static final Integer OVERDUE_DAYS = 21;

    private static List<Broker_Assignment__c> queryAll() {
        return [
            SELECT Id, Status__c, Listing_Start_Date__c, Listing_End_Date__c, Reason_Ended__c,
                   Last_Check_In_Date__c, Days_Since_Check_In__c, Listing_Active_Days__c,
                   Leased_Area__c, Vacant_Area__c,
                   Property_Asset__c, Property_Display_Name__c, Property_Type_Display__c,
                   Address_Display__c, Gross_Sq_Ft__c,
                   Broker__c, Broker_Name__c, Broker_Firm__c, Broker_Email__c, Broker_Phone__c
            FROM Broker_Assignment__c
            ORDER BY CreatedDate DESC
        ];
    }
    private static Integer idle(Broker_Assignment__c a) {
        return a.Days_Since_Check_In__c == null ? null : (Integer) a.Days_Since_Check_In__c;
    }
    private static Boolean isOverdue(Broker_Assignment__c a) {
        Integer d = idle(a); return a.Status__c == 'Active' && d != null && d > OVERDUE_DAYS;
    }

    public class Kpis { @AuraEnabled public Integer total; @AuraEnabled public Integer active; @AuraEnabled public Integer overdue; @AuraEnabled public Integer leased; }
    @AuraEnabled(cacheable=true)
    public static Kpis getKpis() {
        Kpis k = new Kpis(); k.total=0; k.active=0; k.overdue=0; k.leased=0;
        for (Broker_Assignment__c a : queryAll()) {
            k.total++;
            if (a.Status__c == 'Active') k.active++;
            if (a.Status__c == 'Fully Leased') k.leased++;
            if (isOverdue(a)) k.overdue++;
        }
        return k;
    }

    public class Row {
        @AuraEnabled public Id id; @AuraEnabled public Id brokerId;
        @AuraEnabled public String propertyName; @AuraEnabled public String propertyAddr;
        @AuraEnabled public String brokerName; @AuraEnabled public String brokerFirm;
        @AuraEnabled public String status; @AuraEnabled public Date startDate; @AuraEnabled public Date endDate;
        @AuraEnabled public Date lastCheckIn; @AuraEnabled public Integer daysIdle; @AuraEnabled public String reason;
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getAssignments() {
        List<Row> out = new List<Row>();
        for (Broker_Assignment__c a : queryAll()) {
            Row r = new Row();
            r.id=a.Id; r.brokerId=a.Broker__c;
            r.propertyName=a.Property_Display_Name__c; r.propertyAddr=a.Address_Display__c;
            r.brokerName=a.Broker_Name__c; r.brokerFirm=a.Broker_Firm__c;
            r.status=a.Status__c; r.startDate=a.Listing_Start_Date__c; r.endDate=a.Listing_End_Date__c;
            r.lastCheckIn=a.Last_Check_In_Date__c; r.daysIdle=idle(a); r.reason=a.Reason_Ended__c;
            out.add(r);
        }
        return out;
    }

    public class Portfolio { @AuraEnabled public Integer total; @AuraEnabled public Integer active; @AuraEnabled public Integer leased; @AuraEnabled public Integer replaced; @AuraEnabled public Integer terminated; }
    @AuraEnabled(cacheable=true)
    public static Portfolio getPortfolio() {
        Portfolio p = new Portfolio(); p.total=0; p.active=0; p.leased=0; p.replaced=0; p.terminated=0;
        for (Broker_Assignment__c a : queryAll()) {
            p.total++;
            if (a.Status__c=='Active') p.active++;
            else if (a.Status__c=='Fully Leased') p.leased++;
            else if (a.Status__c=='Replaced') p.replaced++;
            else if (a.Status__c=='Terminated') p.terminated++;
        }
        return p;
    }

    public class Alerts { @AuraEnabled public Integer overdue; @AuraEnabled public Integer dueSoon; @AuraEnabled public Integer onTrack; @AuraEnabled public Integer active; }
    @AuraEnabled(cacheable=true)
    public static Alerts getAlerts() {
        Alerts al = new Alerts(); al.overdue=0; al.dueSoon=0; al.onTrack=0; al.active=0;
        for (Broker_Assignment__c a : queryAll()) {
            if (a.Status__c != 'Active') continue;
            al.active++;
            Integer d = idle(a);
            if (d != null && d > OVERDUE_DAYS) al.overdue++;
            else if (d != null && d >= WARN_DAYS) al.dueSoon++;
            else al.onTrack++;
        }
        return al;
    }

    public class BrokerCard {
        @AuraEnabled public Id brokerId; @AuraEnabled public String name; @AuraEnabled public String firm;
        @AuraEnabled public Integer active; @AuraEnabled public Integer leased; @AuraEnabled public Integer replaced;
        @AuraEnabled public Integer terminated; @AuraEnabled public Integer total;
    }
    @AuraEnabled(cacheable=true)
    public static List<BrokerCard> getScorecard() {
        Map<Id, BrokerCard> byBroker = new Map<Id, BrokerCard>();
        for (Broker_Assignment__c a : queryAll()) {
            if (a.Broker__c == null) continue;
            BrokerCard c = byBroker.get(a.Broker__c);
            if (c == null) { c = new BrokerCard(); c.brokerId=a.Broker__c; c.name=a.Broker_Name__c; c.firm=a.Broker_Firm__c; c.active=0; c.leased=0; c.replaced=0; c.terminated=0; c.total=0; byBroker.put(a.Broker__c, c); }
            c.total++;
            if (a.Status__c=='Active') c.active++;
            else if (a.Status__c=='Fully Leased') c.leased++;
            else if (a.Status__c=='Replaced') c.replaced++;
            else if (a.Status__c=='Terminated') c.terminated++;
        }
        return byBroker.values();
    }

    public class BrokerTotal {
        @AuraEnabled public Id brokerId; @AuraEnabled public String name; @AuraEnabled public String firm; @AuraEnabled public Integer totalProperties;
    }
    @AuraEnabled(cacheable=true)
    public static List<BrokerTotal> getBrokerTotals() {
        Map<Id, BrokerTotal> byBroker = new Map<Id, BrokerTotal>();
        Map<Id, Set<Id>> propsByBroker = new Map<Id, Set<Id>>();
        for (Broker_Assignment__c a : queryAll()) {
            if (a.Broker__c == null) continue;
            BrokerTotal bt = byBroker.get(a.Broker__c);
            if (bt == null) { bt = new BrokerTotal(); bt.brokerId=a.Broker__c; bt.name=a.Broker_Name__c; bt.firm=a.Broker_Firm__c; bt.totalProperties=0; byBroker.put(a.Broker__c, bt); propsByBroker.put(a.Broker__c, new Set<Id>()); }
            if (a.Property_Asset__c != null) propsByBroker.get(a.Broker__c).add(a.Property_Asset__c);
        }
        for (Id bid : byBroker.keySet()) byBroker.get(bid).totalProperties = propsByBroker.get(bid).size();
        List<BrokerTotal> out = byBroker.values();
        out.sort(new BrokerTotalComparator());
        return out;
    }
    // Sorts brokers by distinct-property count, highest first.
    private class BrokerTotalComparator implements Comparator<BrokerTotal> {
        public Integer compare(BrokerTotal a, BrokerTotal b) { return b.totalProperties - a.totalProperties; }
    }

    public class HistoryRow {
        @AuraEnabled public Id id; @AuraEnabled public String brokerName; @AuraEnabled public String brokerFirm;
        @AuraEnabled public String status; @AuraEnabled public Date startDate; @AuraEnabled public Date endDate;
        @AuraEnabled public String reason; @AuraEnabled public Boolean current;
    }
    public class Detail {
        @AuraEnabled public Id id; @AuraEnabled public Id propertyAssetId;
        @AuraEnabled public String propertyName; @AuraEnabled public String propertyType; @AuraEnabled public String propertyAddr;
        @AuraEnabled public Integer grossSqFt; @AuraEnabled public Integer vacantArea; @AuraEnabled public Integer leasedArea; @AuraEnabled public Integer activeDays;
        @AuraEnabled public String brokerName; @AuraEnabled public String brokerFirm; @AuraEnabled public String brokerEmail; @AuraEnabled public String brokerPhone;
        @AuraEnabled public String status; @AuraEnabled public Date startDate; @AuraEnabled public Date endDate; @AuraEnabled public Date lastCheckIn;
        @AuraEnabled public Integer daysIdle; @AuraEnabled public String reason; @AuraEnabled public List<HistoryRow> history;
    }
    @AuraEnabled(cacheable=true)
    public static Detail getDetail(Id assignmentId) {
        List<Broker_Assignment__c> recs = queryAll();
        Broker_Assignment__c a;
        for (Broker_Assignment__c r : recs) if (r.Id == assignmentId) { a = r; break; }
        if (a == null) return null;
        Detail d = new Detail();
        d.id=a.Id; d.propertyAssetId=a.Property_Asset__c;
        d.propertyName=a.Property_Display_Name__c; d.propertyType=a.Property_Type_Display__c; d.propertyAddr=a.Address_Display__c;
        d.grossSqFt = a.Gross_Sq_Ft__c == null ? null : (Integer) a.Gross_Sq_Ft__c;
        d.vacantArea = a.Vacant_Area__c == null ? null : (Integer) a.Vacant_Area__c;
        d.leasedArea = a.Leased_Area__c == null ? null : (Integer) a.Leased_Area__c;
        d.activeDays = a.Listing_Active_Days__c == null ? null : (Integer) a.Listing_Active_Days__c;
        d.brokerName=a.Broker_Name__c; d.brokerFirm=a.Broker_Firm__c; d.brokerEmail=a.Broker_Email__c; d.brokerPhone=a.Broker_Phone__c;
        d.status=a.Status__c; d.startDate=a.Listing_Start_Date__c; d.endDate=a.Listing_End_Date__c; d.lastCheckIn=a.Last_Check_In_Date__c;
        d.daysIdle=idle(a); d.reason=a.Reason_Ended__c;
        // history = same Property Asset, oldest -> newest
        List<HistoryRow> hist = new List<HistoryRow>();
        List<Broker_Assignment__c> same = [
            SELECT Id, Broker_Name__c, Broker_Firm__c, Status__c, Listing_Start_Date__c, Listing_End_Date__c, Reason_Ended__c
            FROM Broker_Assignment__c WHERE Property_Asset__c = :a.Property_Asset__c
            ORDER BY Listing_Start_Date__c ASC NULLS FIRST
        ];
        for (Broker_Assignment__c h : same) {
            HistoryRow hr = new HistoryRow();
            hr.id=h.Id; hr.brokerName=h.Broker_Name__c; hr.brokerFirm=h.Broker_Firm__c; hr.status=h.Status__c;
            hr.startDate=h.Listing_Start_Date__c; hr.endDate=h.Listing_End_Date__c; hr.reason=h.Reason_Ended__c;
            hr.current = (h.Id == a.Id);
            hist.add(hr);
        }
        d.history = hist;
        return d;
    }

    @AuraEnabled
    public static void logCheckIn(Id assignmentId) {
        update new Broker_Assignment__c(Id=assignmentId, Last_Check_In_Date__c=Date.today());
    }
    @AuraEnabled
    public static void closeOut(Id assignmentId, String status, Date endDate, String reason) {
        update new Broker_Assignment__c(Id=assignmentId, Status__c=status,
            Listing_End_Date__c = endDate == null ? Date.today() : endDate, Reason_Ended__c=reason);
    }
    @AuraEnabled
    public static Id replaceBroker(Id assignmentId, Id newBrokerId, Date effectiveDate, String reason) {
        Date eff = effectiveDate == null ? Date.today() : effectiveDate;
        Broker_Assignment__c old = [SELECT Id, Property_Asset__c FROM Broker_Assignment__c WHERE Id=:assignmentId LIMIT 1];
        update new Broker_Assignment__c(Id=old.Id, Status__c='Replaced', Listing_End_Date__c=eff, Reason_Ended__c=reason);
        Broker_Assignment__c neu = new Broker_Assignment__c(
            Property_Asset__c=old.Property_Asset__c, Broker__c=newBrokerId, Status__c='Active',
            Listing_Start_Date__c=eff, Last_Check_In_Date__c=eff);
        insert neu;
        return neu.Id;
    }
}
```

- [ ] **Step 4: Add class access to the perm set.** Add to `Property_Management_Access.permissionset-meta.xml`:

```xml
    <classAccesses>
        <apexClass>BrokerAssignmentController</apexClass>
        <enabled>true</enabled>
    </classAccesses>
```

- [ ] **Step 5: Deploy + run tests — verify PASS.**

Run: `sf project deploy start -d force-app/main/default/classes/BrokerAssignmentController.cls -d force-app/main/default/classes/BrokerAssignmentControllerTest.cls -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml --ignore-conflicts`
Run: `sf apex run test --tests BrokerAssignmentControllerTest --result-format human --synchronous`
Expected: all 9 tests pass.

- [ ] **Step 6: Commit.**

```bash
git add force-app/main/default/classes/BrokerAssignmentController.cls force-app/main/default/classes/BrokerAssignmentController.cls-meta.xml force-app/main/default/classes/BrokerAssignmentControllerTest.cls force-app/main/default/classes/BrokerAssignmentControllerTest.cls-meta.xml force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "feat: BrokerAssignmentController with DTOs, actions, and tests"
```

---

## Task 4: `brokerAssignmentKpis` LWC (4 KPI cards)

**Files:**
- Create: `force-app/main/default/lwc/brokerAssignmentKpis/brokerAssignmentKpis.js`
- Create: `…/brokerAssignmentKpis.html`
- Create: `…/brokerAssignmentKpis.css`
- Create: `…/brokerAssignmentKpis.js-meta.xml`

**Interfaces:**
- Consumes: `getKpis` from `BrokerAssignmentController` (`{total, active, overdue, leased}`); `c-stat-card` (`@api value, label, iconName, iconColor`).
- Produces: a component exposed on `lightning__AppPage`.

Prototype reference: list-view KPI cards (prototype lines ~95–106). Labels + icons: **Total assignments** (`utility:record`/clipboard, color navy `#132850`), **Active listings** (`utility:trending`, success `#198A40`), **Check-in overdue** (`utility:warning`, warning `#A06200`), **Fully leased** (`utility:success`/check-circle, neutral `#6B6760`).

- [ ] **Step 1: js-meta.xml.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Broker Assignment KPIs</masterLabel>
    <description>Four KPI cards for the Broker Assignments dashboard.</description>
    <targets>
        <target>lightning__AppPage</target>
        <target>lightning__HomePage</target>
    </targets>
</LightningComponentBundle>
```

- [ ] **Step 2: JS.**

```js
import { LightningElement, wire } from 'lwc';
import getKpis from '@salesforce/apex/BrokerAssignmentController.getKpis';

export default class BrokerAssignmentKpis extends LightningElement {
    k;
    @wire(getKpis) wired({ data }) { if (data) this.k = data; }
    get cards() {
        const k = this.k || {};
        return [
            { key: 'total',   value: k.total ?? 0,   label: 'Total Assignments', iconName: 'utility:record', iconColor: '#132850' },
            { key: 'active',  value: k.active ?? 0,  label: 'Active Listings',   iconName: 'utility:trending', iconColor: '#198A40' },
            { key: 'overdue', value: k.overdue ?? 0, label: 'Check-in Overdue',  iconName: 'utility:warning', iconColor: '#A06200' },
            { key: 'leased',  value: k.leased ?? 0,  label: 'Fully Leased',      iconName: 'utility:success', iconColor: '#6B6760' }
        ];
    }
}
```

- [ ] **Step 3: HTML** (grid of `c-stat-card`, matching the onboarding KPI strip):

```html
<template>
    <div class="kpi-grid">
        <template for:each={cards} for:item="c">
            <c-stat-card key={c.key} value={c.value} label={c.label} icon-name={c.iconName} icon-color={c.iconColor}></c-stat-card>
        </template>
    </div>
</template>
```

- [ ] **Step 4: CSS.**

```css
.kpi-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; }
@media (max-width: 1024px) { .kpi-grid { grid-template-columns: repeat(2, 1fr); } }
```

- [ ] **Step 5: Deploy.**

Run: `sf project deploy start -d force-app/main/default/lwc/brokerAssignmentKpis --ignore-conflicts`
Expected: `Succeeded`.

- [ ] **Step 6: Commit.** `git add force-app/main/default/lwc/brokerAssignmentKpis && git commit -m "feat: brokerAssignmentKpis LWC"`

---

## Task 5: `brokerAssignmentList` LWC (assignments table + filters + New button)

**Files:**
- Create: `force-app/main/default/lwc/brokerAssignmentList/brokerAssignmentList.js`
- Create: `…/brokerAssignmentList.html`
- Create: `…/brokerAssignmentList.css`
- Create: `…/brokerAssignmentList.js-meta.xml`

**Interfaces:**
- Consumes: `getAssignments` (`List<Row>`, Task 3); `c-list-datatable` with custom `pill` (`wrapStyle`,`dotStyle`) and `progress` (`wrapStyle`,`trackStyle`,`barStyle`,`numStyle`,`text`) cell types; `NavigationMixin`.
- Produces: a component exposed on `lightning__AppPage` with `@api warnDays` (default 14) and `@api overdueDays` (default 21).

This is the core of the prototype list (prototype lines ~110–175 and the `renderVals` row/flag logic at lines ~480–619). Reproduce: a header (broker icon + "Broker Assignments (N)"), **status filter tabs** (All / Active / Leased / Replaced / Terminated with counts), a **broker `<select>` filter**, a **New Assignment** button, then the table. Columns: **Property** (url → record, with address subtitle), **Broker** (name + firm subtitle), **Status** (pill), **Listed** (start; "Ended …"/"Listing open" subtitle), **Last check-in** (date), **Days idle** (progress bar + days, sortable), **Follow-up** (flag pill / "—"). Because `c-list-datatable` renders one value per cell, model the two-line cells as two columns is wrong — instead follow the onboarding pattern of single-value cells; for the subtitle lines use the `pill`/`text` value and accept a single line, OR (preferred, to match the prototype's two-line cells) keep Property/Broker/Listed as plain `text` columns showing the primary value and put the secondary detail into the value with a separator. Match onboarding's approach: Property as `url` type linking to `/lightning/r/Broker_Assignment__c/${id}/view`.

- [ ] **Step 1: js-meta.xml.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Broker Assignment List</masterLabel>
    <description>Broker assignments table with status filters, broker filter, days-idle flags, and a New Assignment button.</description>
    <targets>
        <target>lightning__AppPage</target>
        <target>lightning__HomePage</target>
    </targets>
    <targetConfigs>
        <targetConfig targets="lightning__AppPage,lightning__HomePage">
            <property name="warnDays" type="Integer" default="14" label="Follow-up threshold (days)"/>
            <property name="overdueDays" type="Integer" default="21" label="Overdue threshold (days)"/>
        </targetConfig>
    </targetConfigs>
</LightningComponentBundle>
```

- [ ] **Step 2: JS.** Port the prototype helpers `statusMeta`, `flagFor`, `fmt`, and the row builder. Client-side status+broker filter and days-idle sort. The styling tokens are the exact hex from Global Constraints.

```js
import { LightningElement, wire, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getAssignments from '@salesforce/apex/BrokerAssignmentController.getAssignments';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const STATUS_META = {
    'Active':       { bg:'#EBF9F1', fg:'#146830', dot:'#22A652' },
    'Fully Leased': { bg:'#E2E0DB', fg:'#3F3C38', dot:'#8A8680' },
    'Replaced':     { bg:'#FDF0F0', fg:'#B52020', dot:'#D93636' },
    'Terminated':   { bg:'#F9CECE', fg:'#8B1A1A', dot:'#B52020' }
};
const pillWrap = (m) => `display:inline-flex;align-items:center;gap:6px;background:${m.bg};color:${m.fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const pillDot  = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

const STATUS_TABS = [
    { key:'all', label:'All' }, { key:'Active', label:'Active' }, { key:'Fully Leased', label:'Leased' },
    { key:'Replaced', label:'Replaced' }, { key:'Terminated', label:'Terminated' }
];

const COLUMNS = [
    { label:'Property', fieldName:'recordUrl', type:'url', typeAttributes:{ label:{ fieldName:'propertyName' }, target:'_self' } },
    { label:'Broker', fieldName:'brokerName', type:'text' },
    { label:'Status', fieldName:'status', type:'pill', typeAttributes:{ wrapStyle:{ fieldName:'statusWrap' }, dotStyle:{ fieldName:'statusDot' } } },
    { label:'Listed', fieldName:'startLabel', type:'text', initialWidth:120 },
    { label:'Last check-in', fieldName:'checkInLabel', type:'text', initialWidth:130 },
    { label:'Days idle', fieldName:'daysText', type:'progress', initialWidth:160, sortable:true,
      typeAttributes:{ wrapStyle:'display:flex;align-items:center;gap:9px;min-width:120px',
        trackStyle:'width:60px;height:6px;background:#E2E0DB;border-radius:9999px;overflow:hidden',
        barStyle:{ fieldName:'daysBar' }, numStyle:{ fieldName:'daysNumStyle' }, text:{ fieldName:'daysText' } } },
    { label:'Follow-up', fieldName:'flagLabel', type:'pill', typeAttributes:{ wrapStyle:{ fieldName:'flagWrap' }, dotStyle:{ fieldName:'flagDot' } } }
];

export default class BrokerAssignmentList extends NavigationMixin(LightningElement) {
    @api warnDays = 14;
    @api overdueDays = 21;
    columns = COLUMNS;
    _data = [];
    @track statusFilter = 'all';
    @track brokerFilter = 'all';
    @track sortDesc = true;

    @wire(getAssignments) wired({ data }) { if (data) this._data = data; }

    fmt(d) { if (!d) return '—'; const p = String(d).split('-').map(Number); return `${MONTHS[p[1]-1]} ${p[2]}, ${p[0]}`; }
    flagFor(r) {
        if (r.status !== 'Active') return null;
        const d = r.daysIdle;
        if (d != null && d > this.overdueDays) return { label:'Overdue', m:{bg:'#FDF0F0',fg:'#8B1A1A',dot:'#D93636'}, bar:'#D93636' };
        if (d != null && d >= this.warnDays)  return { label:'Follow up', m:{bg:'#FDF5E6',fg:'#7A4A00',dot:'#C88010'}, bar:'#C88010' };
        return { label:'On track', m:{bg:'#EBF9F1',fg:'#146830',dot:'#22A652'}, bar:'#22A652' };
    }
    get statusTabs() {
        return STATUS_TABS.map(t => {
            const count = t.key === 'all' ? this._data.length : this._data.filter(a => a.status === t.key).length;
            const active = this.statusFilter === t.key;
            return { key:t.key, label:t.label, count, value:t.key,
                cls: active ? 'sf-tab sf-tab--active' : 'sf-tab' };
        });
    }
    get brokerOptions() {
        const seen = new Map();
        this._data.forEach(a => { if (a.brokerId && !seen.has(a.brokerId)) seen.set(a.brokerId, a.brokerName); });
        return [{ value:'all', label:'All brokers' }, ...[...seen].map(([value,label]) => ({ value, label }))];
    }
    get rows() {
        let rows = this._data.filter(a =>
            (this.statusFilter === 'all' || a.status === this.statusFilter) &&
            (this.brokerFilter === 'all' || a.brokerId === this.brokerFilter));
        rows = rows.map(a => {
            const m = STATUS_META[a.status] || STATUS_META['Active'];
            const flag = this.flagFor(a);
            const d = a.daysIdle;
            const barColor = a.status === 'Active' ? (flag ? flag.bar : '#22A652') : '#C8C4BE';
            const barW = Math.max(4, Math.min((d || 0) / this.overdueDays, 1) * 100);
            return {
                id: a.id, propertyName: a.propertyName || '—',
                recordUrl: `/lightning/r/Broker_Assignment__c/${a.id}/view`,
                brokerName: a.brokerName || '—',
                status: a.status, statusWrap: pillWrap(m), statusDot: pillDot(m.dot),
                startLabel: this.fmt(a.startDate),
                checkInLabel: this.fmt(a.lastCheckIn),
                _days: d == null ? -1 : d,
                daysText: d == null ? '—' : `${d}d`,
                daysBar: `width:${barW}%;height:100%;background:${barColor};border-radius:9999px`,
                daysNumStyle: `font-weight:700;font-size:12px;color:${a.status==='Active' && flag ? flag.m.fg : '#524F4A'};font-variant-numeric:tabular-nums`,
                flagLabel: (a.status === 'Active' && flag) ? flag.label : '—',
                flagWrap: (a.status === 'Active' && flag) ? pillWrap(flag.m) : 'color:#8A8680',
                flagDot: (a.status === 'Active' && flag) ? pillDot(flag.m.dot) : ''
            };
        });
        rows.sort((x,y) => this.sortDesc ? (y._days - x._days) : (x._days - y._days));
        return rows;
    }
    get count() { return this.rows.length; }
    get sortIcon() { return this.sortDesc ? '↓' : '↑'; }

    handleStatus(e) { this.statusFilter = e.currentTarget.dataset.key; }
    handleBroker(e) { this.brokerFilter = e.detail ? e.detail.value : e.target.value; }
    toggleSort() { this.sortDesc = !this.sortDesc; }
    newAssignment() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Broker_Assignment__c', actionName: 'new' }
        });
    }
}
```

- [ ] **Step 3: HTML.** A `lightning-card` shell (matching `onboardingPropertyList`) with a custom header row (status tabs as buttons, a `lightning-combobox` for broker filter, and a `lightning-button` "New Assignment"), then `c-list-datatable`. Reproduce the prototype header layout/colors with the `.sf-*` classes from Step 4:

```html
<template>
    <lightning-card>
        <div slot="title" class="hdr">
            <span class="hdr-icon"><lightning-icon icon-name="utility:company" size="x-small" variant="inverse"></lightning-icon></span>
            <span class="hdr-title">Broker Assignments ({count})</span>
        </div>
        <div slot="actions">
            <lightning-button variant="brand" label="New Assignment" icon-name="utility:add" onclick={newAssignment}></lightning-button>
        </div>
        <div class="toolbar">
            <div class="tabs">
                <template for:each={statusTabs} for:item="t">
                    <button key={t.key} data-key={t.key} class={t.cls} onclick={handleStatus}>{t.label}<span class="tab-count">{t.count}</span></button>
                </template>
            </div>
            <lightning-combobox class="broker-filter" variant="label-hidden" value={brokerFilter} options={brokerOptions} onchange={handleBroker}></lightning-combobox>
        </div>
        <c-list-datatable key-field="id" data={rows} columns={columns} column-widths-mode="fixed" hide-checkbox-column
            onheaderaction={toggleSort}></c-list-datatable>
        <div slot="footer" class="note">Records are never deleted — closed listings stay visible by changing status. Click any row to open it.</div>
    </lightning-card>
</template>
```

(Sorting via the column header: `c-list-datatable` extends `lightning-datatable`; wire `onsort` if preferred. Simpler: keep the "Days idle" header sortable and handle `onsort` to flip `sortDesc`. If `onsort` is used, change Step 2 `toggleSort` to read `event.detail.sortDirection`.)

- [ ] **Step 4: CSS.** Reproduce the prototype's segmented status tabs + colors:

```css
.hdr { display:flex; align-items:center; gap:9px; }
.hdr-icon { width:26px; height:26px; border-radius:50%; background:#132850; display:inline-flex; align-items:center; justify-content:center; }
.hdr-title { font-size:16px; font-weight:700; color:#1A1714; }
.toolbar { display:flex; align-items:center; gap:12px; flex-wrap:wrap; padding:0 1rem 0.75rem; }
.tabs { display:inline-flex; background:#E2E0DB; border-radius:6px; padding:3px; gap:2px; }
.sf-tab { display:inline-flex; align-items:center; gap:6px; height:28px; padding:0 11px; border:none; border-radius:4px; cursor:pointer; font-size:12px; font-weight:600; background:transparent; color:#524F4A; }
.sf-tab--active { background:#fff; color:#1A1714; box-shadow:0 1px 2px rgba(7,20,40,0.12); }
.tab-count { font-size:10px; font-weight:600; color:#8A8680; }
.broker-filter { min-width:170px; }
.note { font-size:12px; color:#8A8680; text-align:left; }
```

- [ ] **Step 5: Deploy.**

Run: `sf project deploy start -d force-app/main/default/lwc/brokerAssignmentList --ignore-conflicts`
Expected: `Succeeded`.

- [ ] **Step 6: Commit.** `git add force-app/main/default/lwc/brokerAssignmentList && git commit -m "feat: brokerAssignmentList LWC with filters and New Assignment button"`

---

## Task 6: `brokerPortfolioStatus` + `brokerCheckInAlerts` + `brokerTotals` LWCs (right rail)

**Files:**
- Create: `force-app/main/default/lwc/brokerPortfolioStatus/{brokerPortfolioStatus.js,.html,.css,.js-meta.xml}`
- Create: `force-app/main/default/lwc/brokerCheckInAlerts/{brokerCheckInAlerts.js,.html,.css,.js-meta.xml}`
- Create: `force-app/main/default/lwc/brokerTotals/{brokerTotals.js,.html,.css,.js-meta.xml}`

**Interfaces:**
- Consumes: `getPortfolio` (`{total,active,leased,replaced,terminated}`), `getAlerts` (`{overdue,dueSoon,onTrack,active}`), and `getBrokerTotals` (`List<{brokerId,name,firm,totalProperties}>`), Task 3.
- Produces: three components exposed on `lightning__AppPage`.

Prototype reference: Portfolio Status widget (lines ~178–205) — a donut (active/total green arc) + active/total readout + a stacked status bar + legend. Check-in Alerts widget (lines ~207–218) — a 2×2 grid of tiles. Use exact colors from Global Constraints. The donut can be an inline SVG (copy the prototype's `<svg viewBox="0 0 120 120">` with two circles; compute `stroke-dasharray` from pct).

- [ ] **Step 1: `brokerPortfolioStatus` js-meta.xml** (isExposed true, targets AppPage+HomePage, masterLabel "Broker Portfolio Status").

- [ ] **Step 2: `brokerPortfolioStatus` JS.**

```js
import { LightningElement, wire } from 'lwc';
import getPortfolio from '@salesforce/apex/BrokerAssignmentController.getPortfolio';

const SEG = [
    { key:'active', label:'Active', color:'#22A652' },
    { key:'leased', label:'Fully Leased', color:'#C8A045' },
    { key:'replaced', label:'Replaced', color:'#D93636' },
    { key:'terminated', label:'Terminated', color:'#8B1A1A' }
];
const CIRC = 2 * Math.PI * 50;

export default class BrokerPortfolioStatus extends LightningElement {
    p;
    @wire(getPortfolio) wired({ data }) { if (data) this.p = data; }
    get pct() { const p = this.p || {}; return p.total ? Math.round(100 * p.active / p.total) : 0; }
    get dash() { const arc = (this.pct/100) * CIRC; return `${arc.toFixed(1)} ${(CIRC-arc).toFixed(1)}`; }
    get active() { return (this.p && this.p.active) || 0; }
    get total() { return (this.p && this.p.total) || 0; }
    get segments() {
        const p = this.p || {}; const total = p.total || 1;
        return SEG.map(s => ({ key:s.key, color:s.color, count:p[s.key] || 0,
            barStyle:`width:${((p[s.key]||0)/total)*100}%;background:${s.color};height:100%`,
            dotStyle:`width:9px;height:9px;border-radius:2px;background:${s.color};flex-shrink:0` }))
            .filter(s => true); // legend shows all four; bar segments with 0 simply render 0-width
    }
}
```

- [ ] **Step 3: `brokerPortfolioStatus` HTML** — port prototype lines ~180–204: a `lightning-card` (or styled `<div>`) titled "Portfolio Status" (navy circle icon), the donut SVG using `{dash}`, the `{pct}%`/active-total readout, the stacked bar (`for:each={segments}` → `<div style={s.barStyle}>`), and the legend (`for:each={segments}` → dot + label + count). CSS: copy the inline measurements (donut 112px, hole 74px, bar height 9px, etc.) from the prototype into the `.css`.

- [ ] **Step 4: `brokerCheckInAlerts` js-meta.xml** (isExposed true, AppPage+HomePage, masterLabel "Broker Check-in Alerts").

- [ ] **Step 5: `brokerCheckInAlerts` JS.**

```js
import { LightningElement, wire } from 'lwc';
import getAlerts from '@salesforce/apex/BrokerAssignmentController.getAlerts';

const TILES = [
    { key:'overdue', label:'Overdue check-ins', bg:'#FDF0F0', fg:'#8B1A1A', bd:'#F9CECE' },
    { key:'dueSoon', label:'Due for follow-up', bg:'#FDF5E6', fg:'#7A4A00', bd:'#FAEAC8' },
    { key:'onTrack', label:'On track',          bg:'#EBF9F1', fg:'#146830', bd:'#CCEEDD' },
    { key:'active',  label:'Active listings',    bg:'#E8EFF7', fg:'#1A3464', bd:'#B8CDE8' }
];
export default class BrokerCheckInAlerts extends LightningElement {
    a;
    @wire(getAlerts) wired({ data }) { if (data) this.a = data; }
    get tiles() {
        const a = this.a || {};
        return TILES.map(t => ({ key:t.key, label:t.label, value:a[t.key] ?? 0,
            tileStyle:`background:${t.bg};border:1px solid ${t.bd};border-radius:6px;padding:12px 14px;color:${t.fg}` }));
    }
}
```

- [ ] **Step 6: `brokerCheckInAlerts` HTML** — port prototype lines ~207–218: a `lightning-card`/styled box titled "Check-in Alerts" (red shield icon), a 2-col grid of tiles (`for:each={tiles}` → `<div style={t.tileStyle}>` with a big mono number `{t.value}` + caps `{t.label}`).

- [ ] **Step 7: `brokerTotals` js-meta.xml** (isExposed true, AppPage+HomePage, masterLabel "Brokers — Total Properties").

- [ ] **Step 8: `brokerTotals` JS.**

```js
import { LightningElement, wire } from 'lwc';
import getBrokerTotals from '@salesforce/apex/BrokerAssignmentController.getBrokerTotals';

export default class BrokerTotals extends LightningElement {
    _data = [];
    @wire(getBrokerTotals) wired({ data }) { if (data) this._data = data; }
    initials(name){ return (name||'').split(' ').map(w=>w[0]).join('').slice(0,2).toUpperCase(); }
    get rows() {
        return this._data.map(b => ({
            brokerId: b.brokerId, name: b.name || '—', firm: b.firm || '',
            initials: this.initials(b.name), total: b.totalProperties || 0,
            unitLabel: (b.totalProperties === 1) ? 'property' : 'properties'
        }));
    }
    get hasRows() { return this.rows.length > 0; }
}
```

- [ ] **Step 9: `brokerTotals` HTML.** A styled card titled "Brokers — Total Properties" (navy circle icon, matching the other rail widgets), then a list: each row = avatar initials (navy `#0C1E3C` bg, gold `#E0C47E` text), name + firm, and a right-aligned big count + `{r.unitLabel}`. Use `for:each={rows}`. Empty state when `!hasRows`.

```html
<template>
    <article class="bt-card">
        <div class="bt-hd"><span class="bt-icon"><lightning-icon icon-name="utility:user" size="x-small" variant="inverse"></lightning-icon></span><span class="bt-title">Brokers — Total Properties</span></div>
        <template if:true={hasRows}>
            <ul class="bt-list">
                <template for:each={rows} for:item="r">
                    <li key={r.brokerId} class="bt-row">
                        <span class="bt-avatar">{r.initials}</span>
                        <span class="bt-name"><span class="bt-n">{r.name}</span><span class="bt-f">{r.firm}</span></span>
                        <span class="bt-count">{r.total}<span class="bt-unit">{r.unitLabel}</span></span>
                    </li>
                </template>
            </ul>
        </template>
        <template if:false={hasRows}><div class="bt-empty">No brokers assigned yet.</div></template>
    </article>
</template>
```

- [ ] **Step 10: `brokerTotals` CSS** (match the rail card chrome used by the other two widgets):

```css
.bt-card { background:#fff; border:1px solid #E2E0DB; border-radius:8px; box-shadow:0 1px 2px rgba(7,20,40,0.06); padding:18px; }
.bt-hd { display:flex; align-items:center; gap:9px; margin-bottom:14px; }
.bt-icon { width:26px; height:26px; border-radius:50%; background:#132850; display:inline-flex; align-items:center; justify-content:center; }
.bt-title { font-size:16px; font-weight:700; color:#1A1714; }
.bt-list { list-style:none; margin:0; padding:0; display:flex; flex-direction:column; gap:10px; }
.bt-row { display:flex; align-items:center; gap:12px; }
.bt-avatar { width:34px; height:34px; border-radius:50%; background:#0C1E3C; color:#E0C47E; font-size:12px; font-weight:700; display:inline-flex; align-items:center; justify-content:center; flex-shrink:0; }
.bt-name { display:flex; flex-direction:column; flex:1; min-width:0; }
.bt-n { font-size:14px; font-weight:600; color:#1A1714; }
.bt-f { font-size:12px; color:#8A8680; }
.bt-count { font-size:20px; font-weight:700; color:#132850; display:flex; align-items:baseline; gap:5px; }
.bt-unit { font-size:11px; font-weight:600; color:#8A8680; }
.bt-empty { font-size:13px; color:#8A8680; }
```

- [ ] **Step 11: Deploy all three.**

Run: `sf project deploy start -d force-app/main/default/lwc/brokerPortfolioStatus -d force-app/main/default/lwc/brokerCheckInAlerts -d force-app/main/default/lwc/brokerTotals --ignore-conflicts`
Expected: `Succeeded`.

- [ ] **Step 12: Commit.** `git add force-app/main/default/lwc/brokerPortfolioStatus force-app/main/default/lwc/brokerCheckInAlerts force-app/main/default/lwc/brokerTotals && git commit -m "feat: portfolio status + check-in alerts + brokers-total-properties rail LWCs"`

---

## Task 7: Broker Assignments Home flexipage + tab + wire into app

**Files:**
- Create: `force-app/main/default/flexipages/Broker_Assignments_Home.flexipage-meta.xml`
- Create: `force-app/main/default/tabs/Broker_Assignments.tab-meta.xml`
- Modify: `force-app/main/default/applications/Property_Management.app-meta.xml`
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Consumes: `brokerAssignmentKpis`, `brokerAssignmentList`, `brokerPortfolioStatus`, `brokerCheckInAlerts`, `brokerTotals` (Tasks 4–6).
- Produces: tab API name `Broker_Assignments`.

- [ ] **Step 1: Flexipage** (mirror `Onboarding_Home`: `appHomeTemplateHeaderTwoColumns`, region1 = KPIs, region2 = list, region3 = portfolio + alerts).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<FlexiPage xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPageRegions>
        <itemInstances>
            <componentInstance><componentName>brokerAssignmentKpis</componentName><identifier>brokerAssignmentKpisComponent</identifier></componentInstance>
        </itemInstances>
        <name>region1</name><type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance><componentName>brokerAssignmentList</componentName><identifier>brokerAssignmentListComponent</identifier></componentInstance>
        </itemInstances>
        <name>region2</name><type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance><componentName>brokerPortfolioStatus</componentName><identifier>brokerPortfolioStatusComponent</identifier></componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance><componentName>brokerCheckInAlerts</componentName><identifier>brokerCheckInAlertsComponent</identifier></componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance><componentName>brokerTotals</componentName><identifier>brokerTotalsComponent</identifier></componentInstance>
        </itemInstances>
        <name>region3</name><type>Region</type>
    </flexiPageRegions>
    <masterLabel>Broker Assignments Home</masterLabel>
    <template><name>flexipage:appHomeTemplateHeaderTwoColumns</name></template>
    <type>AppPage</type>
</FlexiPage>
```

- [ ] **Step 2: Tab.** `tabs/Broker_Assignments.tab-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPage>Broker_Assignments_Home</flexiPage>
    <label>Broker Assignments</label>
    <motif>Custom51: Apple</motif>
</CustomTab>
```

- [ ] **Step 3: App.** In `Property_Management.app-meta.xml`, add after `<tabs>standard-report</tabs>`:

```xml
    <tabs>Broker_Assignments</tabs>
    <tabs>Broker_Assignment__c</tabs>
```

- [ ] **Step 4: Perm set tab visibility.** Add `<tabSettings><tab>Broker_Assignments</tab><visibility>Visible</visibility></tabSettings>`.

- [ ] **Step 5: Deploy.**

Run: `sf project deploy start -d force-app/main/default/flexipages/Broker_Assignments_Home.flexipage-meta.xml -d force-app/main/default/tabs/Broker_Assignments.tab-meta.xml -d force-app/main/default/applications/Property_Management.app-meta.xml -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml --ignore-conflicts`
Expected: `Succeeded`. (Flexipages can emit design-time errors that still deploy; if a component name is wrong it will fail — fix the `componentName` to match the bundle folder.)

- [ ] **Step 6: Visual check.** Open the Property Management app → **Broker Assignments** tab. Verify: 4 KPI cards top, the assignments table with seeded rows (status tabs + broker filter + New Assignment button), and the right rail (donut + alert tiles + the Brokers — Total Properties list). Confirm the overdue Active rows show the red "Overdue" flag and the days-idle bars render.

- [ ] **Step 7: Commit.** `git add force-app/main/default/flexipages/Broker_Assignments_Home.flexipage-meta.xml force-app/main/default/tabs/Broker_Assignments.tab-meta.xml force-app/main/default/applications/Property_Management.app-meta.xml force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml && git commit -m "feat: Broker Assignments home flexipage + tab wired into PM app"`

---

## Task 8: `brokerAssignmentDetail` LWC + record page + app actionOverride

**Files:**
- Create: `force-app/main/default/lwc/brokerAssignmentDetail/{brokerAssignmentDetail.js,.html,.css,.js-meta.xml}`
- Create: `force-app/main/default/lwc/brokerListingActivity/{brokerListingActivity.js,.html,.css,.js-meta.xml}`
- Create: `force-app/main/default/flexipages/Broker_Assignment_Record_Page.flexipage-meta.xml`
- Modify: `force-app/main/default/applications/Property_Management.app-meta.xml` (add a `View` actionOverride for `Broker_Assignment__c`)

**Interfaces:**
- Consumes: `getDetail(assignmentId)` (Detail + history), `logCheckIn`, `closeOut`, `replaceBroker` (Task 3); `getAssignments` is NOT needed here. Uses `refreshApex`, `notifyRecordUpdateAvailable`, `lightning/uiRecordApi`. For the Replace dialog's "incoming broker" picker, query brokers via a new `@AuraEnabled(cacheable=true) List<BrokerOption> getBrokerOptions()` — **add this method to `BrokerAssignmentController` in this task** (returns `{Id id; String label}` for `Contact WHERE Is_Broker__c=true`), and grant it implicitly via the existing class access. (Add a one-line test `getBrokerOptionsReturnsBrokers` to `BrokerAssignmentControllerTest` and re-run.)
- The record page uses the **`flexipage:recordHomeWithSubheaderTemplateDesktop`** template (regions `header`/`main`/`sidebar`, same as `Onboarding_Record_Page`): `header` = `force:highlightsPanel`, `main` = `brokerAssignmentDetail` (the prototype detail **without** its internal right column), `sidebar` = `brokerListingActivity`.
- `brokerListingActivity` is a separate LWC exposed on `lightning__RecordPage` that reads `@api recordId` and uses `lightning/uiRecordApi` `getRecord` on `Broker_Assignment__c` fields `Listing_Active_Days__c`, `Last_Check_In_Date__c`, `Days_Since_Check_In__c` — no Apex.
- Produces: two components exposed on `lightning__RecordPage` reading `@api recordId`.

Prototype reference: the detail view (lines ~210–340 in the prototype + the close-out modal lines ~363–384 + replace modal lines ~386–415 + the `markStatus`/`saveDraft`/`confirmCloseout`/`confirmReplace`/`logCheckin` logic at lines ~488–540 and the detail `renderVals` at lines ~624–670). Reproduce: a header card (property name, status badge, Log Check-in / Replace Broker / Back buttons), a **status path** (Active→Fully Leased→Replaced→Terminated chevrons) + "Mark as {status}" button, a tab strip (Details / History / Notes & Attachments), the Details grid (Property / Listing / Broker sections), the History list (per-property, current highlighted), a Notes empty state, and the Close-out + Replace modals. **Do NOT include the prototype's internal right "check-in cadence" column** — that lives in the separate `brokerListingActivity` sidebar LWC (Steps 5b–5d). So `brokerAssignmentDetail` renders as a single full-width column (header card + path + tabbed card). In the **Property** section add a **Vacant Area** field (`detail.vacantArea`, formatted with thousands + " sq ft"); in the **Listing** section add a **Leased Area** field (`detail.leasedArea`, same formatting).

- [ ] **Step 1: Add `getBrokerOptions` to the controller.** Append to `BrokerAssignmentController`:

```apex
    public class BrokerOption { @AuraEnabled public Id id; @AuraEnabled public String label; }
    @AuraEnabled(cacheable=true)
    public static List<BrokerOption> getBrokerOptions() {
        List<BrokerOption> out = new List<BrokerOption>();
        for (Contact c : [SELECT Id, Name, Broker_Firm__c FROM Contact WHERE Is_Broker__c = true ORDER BY Name]) {
            BrokerOption o = new BrokerOption(); o.id=c.Id; o.label = c.Broker_Firm__c == null ? c.Name : (c.Name + ' · ' + c.Broker_Firm__c); out.add(o);
        }
        return out;
    }
```

Add to `BrokerAssignmentControllerTest`:

```apex
    @isTest static void getBrokerOptionsReturnsBrokers() {
        System.assertEquals(2, BrokerAssignmentController.getBrokerOptions().size());
    }
```

- [ ] **Step 2: js-meta.xml.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Broker Assignment Detail</masterLabel>
    <description>Record-page detail for a broker assignment: details, per-property history, status path, and check-in/replace/close-out actions.</description>
    <targets>
        <target>lightning__RecordPage</target>
    </targets>
    <targetConfigs>
        <targetConfig targets="lightning__RecordPage" objects="Broker_Assignment__c">
            <property name="warnDays" type="Integer" default="14" label="Follow-up threshold (days)"/>
            <property name="overdueDays" type="Integer" default="21" label="Overdue threshold (days)"/>
        </targetConfig>
    </targetConfigs>
</LightningComponentBundle>
```

- [ ] **Step 3: JS.** Wire `getDetail({ assignmentId: '$recordId' })`. Port `statusMeta`/`flagFor`/`fmt`. Implement tab state (`details`/`history`/`notes`), the status path (draft status), and action handlers calling Apex then `refreshApex(this._wire)` + `notifyRecordUpdateAvailable([{ recordId: this.recordId }])`. Skeleton:

```js
import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getDetail from '@salesforce/apex/BrokerAssignmentController.getDetail';
import getBrokerOptions from '@salesforce/apex/BrokerAssignmentController.getBrokerOptions';
import logCheckIn from '@salesforce/apex/BrokerAssignmentController.logCheckIn';
import closeOut from '@salesforce/apex/BrokerAssignmentController.closeOut';
import replaceBroker from '@salesforce/apex/BrokerAssignmentController.replaceBroker';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const STATUS_META = { 'Active':{bg:'#EBF9F1',fg:'#146830',dot:'#22A652'},'Fully Leased':{bg:'#E2E0DB',fg:'#3F3C38',dot:'#8A8680'},'Replaced':{bg:'#FDF0F0',fg:'#B52020',dot:'#D93636'},'Terminated':{bg:'#F9CECE',fg:'#8B1A1A',dot:'#B52020'} };
const REASONS = ['Leased Up','Performance Issue','Company Decision','Other'];

export default class BrokerAssignmentDetail extends LightningElement {
    @api recordId;
    @api warnDays = 14;
    @api overdueDays = 21;
    d; _wire;
    @track tab = 'details';
    @track closingOut = false; @track replacing = false;
    @track draftStatus; @track draftEnd; @track draftReason; @track repBrokerId; @track repReason='Performance Issue'; @track repDate;
    _saving = false;

    @wire(getDetail, { assignmentId: '$recordId' })
    wired(result) { this._wire = result; if (result.data) { this.d = result.data; this.draftStatus = result.data.status; } }
    @wire(getBrokerOptions) brokerOpts;

    fmt(v){ if(!v) return '—'; const p=String(v).split('-').map(Number); return `${MONTHS[p[1]-1]} ${p[2]}, ${p[0]}`; }
    get meta(){ return STATUS_META[this.d ? this.d.status : 'Active']; }
    // tab getters
    get showDetails(){ return this.tab==='details'; }
    get showHistory(){ return this.tab==='history'; }
    get showNotes(){ return this.tab==='notes'; }
    selectDetails(){ this.tab='details'; } selectHistory(){ this.tab='history'; } selectNotes(){ this.tab='notes'; }
    // status path
    get pathStages(){ return ['Active','Fully Leased','Replaced','Terminated'].map(k=>({ key:k, label:k, on:this.draftStatus===k })); }
    pickStage(e){ this.draftStatus = e.currentTarget.dataset.key; }
    get markLabel(){ return `Mark as ${this.draftStatus}`; }
    get canReplace(){ return this.d && this.d.status === 'Active'; }
    get historyRows(){ /* map d.history into row styles, current highlighted */ return (this.d && this.d.history || []).map(h=>({ ...h, rangeDisp:`${this.fmt(h.startDate)} → ${h.endDate?this.fmt(h.endDate):'present'}`, wrap: this.badge(h.status) })); }
    badge(s){ const m=STATUS_META[s]||STATUS_META['Active']; return `display:inline-flex;align-items:center;gap:6px;background:${m.bg};color:${m.fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px`; }

    async refresh(){ await refreshApex(this._wire); notifyRecordUpdateAvailable([{ recordId: this.recordId }]); }
    async handleLogCheckIn(){ await logCheckIn({ assignmentId: this.recordId }); await this.refresh(); }
    markStatus(){ if(this.draftStatus==='Active'){ /* no-op or save */ } else { this.draftEnd=null; this.draftReason=null; this.closingOut=true; } }
    cancelCloseout(){ this.closingOut=false; this.draftStatus=this.d.status; }
    async confirmCloseout(){ await closeOut({ assignmentId:this.recordId, status:this.draftStatus, endDate:this.draftEnd, reason:this.draftReason }); this.closingOut=false; await this.refresh(); }
    openReplace(){ this.replacing=true; this.repBrokerId=null; this.repReason='Performance Issue'; this.repDate=null; }
    closeReplace(){ this.replacing=false; }
    async confirmReplace(){ await replaceBroker({ assignmentId:this.recordId, newBrokerId:this.repBrokerId, effectiveDate:this.repDate, reason:this.repReason }); this.replacing=false; await this.refresh(); }
    get reasonOptions(){ return REASONS.map(r=>({label:r,value:r})); }
    get brokerOptionList(){ return (this.brokerOpts && this.brokerOpts.data || []).map(o=>({label:o.label,value:o.id})); }
    onDraftEnd(e){ this.draftEnd=e.target.value; } onDraftReason(e){ this.draftReason=e.detail.value; }
    onRepBroker(e){ this.repBrokerId=e.detail.value; } onRepReason(e){ this.repReason=e.detail.value; } onRepDate(e){ this.repDate=e.target.value; }
}
```

Fill in the remaining display getters (status badge style, days-idle highlight, formatted dates, `grossSqFt`/`vacantArea`/`leasedArea` each formatted with `toLocaleString()` + " sq ft" or "—" when null, address/type) so the HTML binds to concrete values — no `{{ }}` left and no logic in the template beyond `for:each`/`if:true`.

- [ ] **Step 4: HTML + CSS.** Port the prototype detail markup (header card, status path with chevron `clip-path`, tab strip, Details grid sections with the grey section headers, History rows, Notes empty state, cadence side card) and the two modals (`closingOut`, `replacing`) using `template if:true`. Use `lightning-combobox`/`lightning-input type="date"` inside the modals. Buttons gated by `canReplace`. Copy the exact inline measurements/colors from the prototype into `.css`. Modals: a fixed overlay `<section>` with `role="dialog"`.

- [ ] **Step 5a: `brokerListingActivity` js-meta.xml.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Broker Listing Activity</masterLabel>
    <description>Record-page sidebar: listing active days and last check-in for a broker assignment.</description>
    <targets>
        <target>lightning__RecordPage</target>
    </targets>
    <targetConfigs>
        <targetConfig targets="lightning__RecordPage" objects="Broker_Assignment__c"></targetConfig>
    </targetConfigs>
</LightningComponentBundle>
```

- [ ] **Step 5b: `brokerListingActivity` JS** — read the formula fields via `getRecord` (no Apex):

```js
import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import ACTIVE_DAYS from '@salesforce/schema/Broker_Assignment__c.Listing_Active_Days__c';
import LAST_CHECKIN from '@salesforce/schema/Broker_Assignment__c.Last_Check_In_Date__c';
import DAYS_IDLE from '@salesforce/schema/Broker_Assignment__c.Days_Since_Check_In__c';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export default class BrokerListingActivity extends LightningElement {
    @api recordId;
    record;
    @wire(getRecord, { recordId: '$recordId', fields: [ACTIVE_DAYS, LAST_CHECKIN, DAYS_IDLE] })
    wired(result) { if (result.data) this.record = result.data; }

    get activeDays() { const v = getFieldValue(this.record, ACTIVE_DAYS); return v == null ? '—' : `${v}`; }
    get daysIdle() { const v = getFieldValue(this.record, DAYS_IDLE); return v == null ? '—' : `${v}`; }
    get lastCheckIn() {
        const v = getFieldValue(this.record, LAST_CHECKIN);
        if (!v) return '—';
        const p = String(v).split('-').map(Number); return `${MONTHS[p[1]-1]} ${p[2]}, ${p[0]}`;
    }
}
```

- [ ] **Step 5c: `brokerListingActivity` HTML** — a card titled "Listing Activity" (green clock icon) with a big "Listing Active Days" number, the "Last Check-In" date, and a small "days since check-in" line:

```html
<template>
    <article class="la-card">
        <div class="la-hd"><span class="la-icon"><lightning-icon icon-name="utility:clock" size="x-small" variant="inverse"></lightning-icon></span><span class="la-title">Listing Activity</span></div>
        <div class="la-big">{activeDays}<span class="la-unit">active days</span></div>
        <div class="la-row"><span class="la-lbl">Last check-in</span><span class="la-val">{lastCheckIn}</span></div>
        <div class="la-row"><span class="la-lbl">Days since check-in</span><span class="la-val">{daysIdle}</span></div>
    </article>
</template>
```

- [ ] **Step 5d: `brokerListingActivity` CSS** (match the rail-card chrome):

```css
.la-card { background:#fff; border:1px solid #E2E0DB; border-radius:8px; box-shadow:0 1px 2px rgba(7,20,40,0.06); padding:18px 20px; }
.la-hd { display:flex; align-items:center; gap:9px; margin-bottom:14px; }
.la-icon { width:26px; height:26px; border-radius:50%; background:#198A40; display:inline-flex; align-items:center; justify-content:center; }
.la-title { font-size:15px; font-weight:700; color:#1A1714; }
.la-big { font-size:32px; font-weight:700; color:#132850; display:flex; align-items:baseline; gap:8px; margin-bottom:14px; }
.la-unit { font-size:13px; font-weight:500; color:#524F4A; }
.la-row { display:flex; align-items:center; justify-content:space-between; padding:8px 0; border-top:1px solid #E2E0DB; }
.la-lbl { font-size:12px; color:#524F4A; }
.la-val { font-size:13px; font-weight:600; color:#1A1714; }
```

- [ ] **Step 5e: Deploy `brokerListingActivity`.** `sf project deploy start -d force-app/main/default/lwc/brokerListingActivity --ignore-conflicts` → `Succeeded`.

- [ ] **Step 5: Record page flexipage.** `Broker_Assignment_Record_Page.flexipage-meta.xml` (type `RecordPage`, sobjectType `Broker_Assignment__c`) — copy the template + region names from `Onboarding_Record_Page.flexipage-meta.xml`: `flexipage:recordHomeWithSubheaderTemplateDesktop` with `header` (force:highlightsPanel), `main` (the detail LWC), `sidebar` (the activity LWC):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<FlexiPage xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>force:highlightsPanel</componentName>
                <identifier>highlightsPanel</identifier>
            </componentInstance>
        </itemInstances>
        <name>header</name><type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance><componentName>brokerAssignmentDetail</componentName><identifier>brokerAssignmentDetailComponent</identifier></componentInstance>
        </itemInstances>
        <name>main</name><type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance><componentName>brokerListingActivity</componentName><identifier>brokerListingActivityComponent</identifier></componentInstance>
        </itemInstances>
        <name>sidebar</name><type>Region</type>
    </flexiPageRegions>
    <masterLabel>Broker Assignment Record Page</masterLabel>
    <sobjectType>Broker_Assignment__c</sobjectType>
    <template><name>flexipage:recordHomeWithSubheaderTemplateDesktop</name></template>
    <type>RecordPage</type>
</FlexiPage>
```

- [ ] **Step 6: App actionOverride.** In `Property_Management.app-meta.xml`, add a second `<actionOverrides>` block (after the Onboarding one) for `Broker_Assignment__c`:

```xml
    <actionOverrides>
        <actionName>View</actionName>
        <comment>Broker Assignment Record Page</comment>
        <content>Broker_Assignment_Record_Page</content>
        <formFactor>Large</formFactor>
        <skipRecordTypeSelect>false</skipRecordTypeSelect>
        <type>Flexipage</type>
        <pageOrSobjectType>Broker_Assignment__c</pageOrSobjectType>
    </actionOverrides>
```

- [ ] **Step 7: Deploy + test.**

Run: `sf project deploy start -d force-app/main/default/classes/BrokerAssignmentController.cls -d force-app/main/default/classes/BrokerAssignmentControllerTest.cls -d force-app/main/default/lwc/brokerAssignmentDetail -d force-app/main/default/lwc/brokerListingActivity -d force-app/main/default/flexipages/Broker_Assignment_Record_Page.flexipage-meta.xml -d force-app/main/default/applications/Property_Management.app-meta.xml --ignore-conflicts`
Run: `sf apex run test --tests BrokerAssignmentControllerTest --result-format human --synchronous`
Expected: deploy `Succeeded`, all 10 tests pass (9 + `getBrokerOptionsReturnsBrokers`).

- [ ] **Step 8: Visual check.** Open a Broker Assignment record. Verify the **main** column shows Details/History/Notes tabs + status path (with Vacant Area in the Property section and Leased Area in the Listing section), the **right sidebar** shows the Listing Activity card (active days + last check-in), and that **Log Check-in** sets today's date (days-idle resets), **Close-out** changes status + sets end/reason, **Replace Broker** closes the old as Replaced and opens a new Active record (navigates/refreshes), and History shows every broker for that property with the current one highlighted.

- [ ] **Step 9: Commit.** `git add force-app/main/default/lwc/brokerAssignmentDetail force-app/main/default/lwc/brokerListingActivity force-app/main/default/flexipages/Broker_Assignment_Record_Page.flexipage-meta.xml force-app/main/default/applications/Property_Management.app-meta.xml force-app/main/default/classes/BrokerAssignmentController.cls force-app/main/default/classes/BrokerAssignmentControllerTest.cls force-app/main/default/classes/*.cls-meta.xml && git commit -m "feat: broker assignment record detail page + listing activity sidebar"`

---

## Task 9: `brokerScorecard` LWC + scorecard tab

**Files:**
- Create: `force-app/main/default/lwc/brokerScorecard/{brokerScorecard.js,.html,.css,.js-meta.xml}`
- Create: `force-app/main/default/flexipages/Broker_Scorecard.flexipage-meta.xml`
- Create: `force-app/main/default/tabs/Broker_Scorecard.tab-meta.xml`
- Modify: `force-app/main/default/applications/Property_Management.app-meta.xml` (add `<tabs>Broker_Scorecard</tabs>`)
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml` (tab visibility)

**Interfaces:**
- Consumes: `getScorecard` (`List<BrokerCard>`, Task 3); `NavigationMixin` (View listings → navigate to Broker Assignments tab; acceptable simplification: navigate to the `Broker_Assignments` app page via `standard__navItemPage` with `apiName:'Broker_Assignments'`).
- Produces: tab API name `Broker_Scorecard`.

Prototype reference: scorecard cards (lines ~318–340). Each card: avatar initials (navy bg, gold text), name + firm, "View listings" button, the big active count + "active now · N assigned all-time", a stacked bar (active/leased/replaced/terminated), and a 4-stat footer (Active/Leased/Replaced/Terminated). Colors: active `#22A652`/`#146830`, leased gold `#C8A045`/`#8B6800`, replaced `#D93636`/`#B52020`, terminated `#8B1A1A`.

- [ ] **Step 1: js-meta.xml** (isExposed true, AppPage+HomePage, masterLabel "Broker Scorecard").

- [ ] **Step 2: JS.**

```js
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getScorecard from '@salesforce/apex/BrokerAssignmentController.getScorecard';

const BARS = [ ['active','#22A652'], ['leased','#C8A045'], ['replaced','#D93636'], ['terminated','#8B1A1A'] ];

export default class BrokerScorecard extends NavigationMixin(LightningElement) {
    _data = [];
    @wire(getScorecard) wired({ data }) { if (data) this._data = data; }
    initials(name){ return (name||'').split(' ').map(w=>w[0]).join('').slice(0,2).toUpperCase(); }
    get cards() {
        return this._data.map(b => {
            const total = b.total || 1;
            const bars = BARS.map(([k,c]) => ({ key:k, n:b[k]||0, style:`width:${((b[k]||0)/total)*100}%;background:${c};height:100%` })).filter(s=>s.n>0);
            return { brokerId:b.brokerId, name:b.name, firm:b.firm, initials:this.initials(b.name),
                active:b.active||0, leased:b.leased||0, replaced:b.replaced||0, terminated:b.terminated||0, total:b.total||0, bars };
        });
    }
    viewListings() {
        this[NavigationMixin.Navigate]({ type:'standard__navItemPage', attributes:{ apiName:'Broker_Assignments' } });
    }
}
```

- [ ] **Step 3: HTML + CSS.** Port the prototype scorecard grid (2-col) and card markup using `for:each={cards}`. The "View listings" button calls `viewListings`. Copy exact measurements/colors into `.css`.

- [ ] **Step 4: Flexipage** `Broker_Scorecard.flexipage-meta.xml` — an AppPage (`flexipage:appHomeTemplateDefault` single region, or copy the two-column template and put the scorecard in region1). Single-region example:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<FlexiPage xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPageRegions>
        <itemInstances>
            <componentInstance><componentName>brokerScorecard</componentName><identifier>brokerScorecardComponent</identifier></componentInstance>
        </itemInstances>
        <name>region1</name><type>Region</type>
    </flexiPageRegions>
    <masterLabel>Broker Scorecard</masterLabel>
    <template><name>flexipage:appHomeTemplateDefault</name></template>
    <type>AppPage</type>
</FlexiPage>
```

(If `appHomeTemplateDefault` is not a valid template name in this org, reuse `flexipage:appHomeTemplateHeaderTwoColumns` and place the component in `region1`, leaving region2/region3 empty.)

- [ ] **Step 5: Tab + app + perm.** `tabs/Broker_Scorecard.tab-meta.xml` (flexiPage `Broker_Scorecard`, label "Broker Scorecard", motif Custom51: Apple). Add `<tabs>Broker_Scorecard</tabs>` to the app (after `Broker_Assignment__c`). Add the tab `<tabSettings>` Visible to the perm set.

- [ ] **Step 6: Deploy.**

Run: `sf project deploy start -d force-app/main/default/lwc/brokerScorecard -d force-app/main/default/flexipages/Broker_Scorecard.flexipage-meta.xml -d force-app/main/default/tabs/Broker_Scorecard.tab-meta.xml -d force-app/main/default/applications/Property_Management.app-meta.xml -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml --ignore-conflicts`
Expected: `Succeeded`.

- [ ] **Step 7: Visual check.** Open the **Broker Scorecard** tab; verify a card per broker with correct active/leased/replaced/terminated counts and a working "View listings" → Broker Assignments tab.

- [ ] **Step 8: Commit.** `git add force-app/main/default/lwc/brokerScorecard force-app/main/default/flexipages/Broker_Scorecard.flexipage-meta.xml force-app/main/default/tabs/Broker_Scorecard.tab-meta.xml force-app/main/default/applications/Property_Management.app-meta.xml force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml && git commit -m "feat: broker scorecard LWC + tab"`

---

## Task 10: Daily stale-check-in scheduled Apex + tests

**Files:**
- Create: `force-app/main/default/classes/BrokerCheckInReminderSchedulable.cls` (+meta)
- Create: `force-app/main/default/classes/BrokerCheckInReminderSchedulableTest.cls` (+meta)
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml` (class access)

**Interfaces:**
- Consumes: `Broker_Assignment__c` + `BrokerAssignmentController.OVERDUE_DAYS` (Task 3).
- Produces: `BrokerCheckInReminderSchedulable implements Schedulable`; `Integer createReminders()` (the unit-testable core that returns the number of Tasks created).

Behavior: for each `Active` `Broker_Assignment__c` whose `Days_Since_Check_In__c > OVERDUE_DAYS`, create a follow-up `Task` (Subject `Check in with broker — <property>`, `WhatId` = the assignment, `OwnerId` = running user, `ActivityDate` = today, `Priority` High, `Status` `Not Started`) — **idempotent**: skip if an open Task with that Subject already exists for that assignment (so daily runs don't pile up duplicates).

- [ ] **Step 1: Write the failing test.**

```apex
@isTest
private class BrokerCheckInReminderSchedulableTest {
    @testSetup static void setup() {
        Property__c pr = new Property__c(Name='P', Address__c='A', Square_Footage__c=1000, Asset_Type__c='Retail'); insert pr;
        Property_Asset__c pa = new Property_Asset__c(Name='P', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active'); insert pa;
        Contact b = new Contact(LastName='Webb', Is_Broker__c=true, Broker_Firm__c='Lee'); insert b;
        Date t = Date.today();
        insert new List<Broker_Assignment__c>{
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=b.Id, Status__c='Active', Last_Check_In_Date__c=t.addDays(-40)), // overdue
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=b.Id, Status__c='Active', Last_Check_In_Date__c=t.addDays(-5)),  // fine
            new Broker_Assignment__c(Property_Asset__c=pa.Id, Broker__c=b.Id, Status__c='Replaced', Last_Check_In_Date__c=t.addDays(-90)) // closed -> ignore
        };
    }
    @isTest static void createsOneReminderForOverdueActiveOnly() {
        Test.startTest();
        Integer created = new BrokerCheckInReminderSchedulable().createReminders();
        Test.stopTest();
        System.assertEquals(1, created);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Check in with broker%']);
    }
    @isTest static void isIdempotent() {
        new BrokerCheckInReminderSchedulable().createReminders();
        Integer second = new BrokerCheckInReminderSchedulable().createReminders();
        System.assertEquals(0, second, 'second run creates no duplicates');
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Check in with broker%']);
    }
    @isTest static void schedulableExecuteRuns() {
        Test.startTest();
        String jobId = System.schedule('BrokerCheckInTest', '0 0 6 * * ?', new BrokerCheckInReminderSchedulable());
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }
}
```

- [ ] **Step 2: Run — verify FAIL.** `sf apex run test --tests BrokerCheckInReminderSchedulableTest --result-format human --synchronous` → class does not exist.

- [ ] **Step 3: Implement.**

```apex
public with sharing class BrokerCheckInReminderSchedulable implements Schedulable {
    public void execute(SchedulableContext sc) { createReminders(); }

    public Integer createReminders() {
        Integer threshold = BrokerAssignmentController.OVERDUE_DAYS;
        List<Broker_Assignment__c> overdue = [
            SELECT Id, Property_Display_Name__c, Broker__c
            FROM Broker_Assignment__c
            WHERE Status__c = 'Active' AND Days_Since_Check_In__c > :threshold
        ];
        if (overdue.isEmpty()) return 0;

        Set<Id> assignmentIds = new Set<Id>();
        for (Broker_Assignment__c a : overdue) assignmentIds.add(a.Id);

        // idempotency: existing open reminder tasks for these assignments
        Set<Id> alreadyHasOpen = new Set<Id>();
        for (Task t : [SELECT WhatId FROM Task WHERE WhatId IN :assignmentIds AND IsClosed = false AND Subject LIKE 'Check in with broker%']) {
            alreadyHasOpen.add(t.WhatId);
        }

        List<Task> toInsert = new List<Task>();
        for (Broker_Assignment__c a : overdue) {
            if (alreadyHasOpen.contains(a.Id)) continue;
            toInsert.add(new Task(
                Subject = 'Check in with broker — ' + (a.Property_Display_Name__c == null ? 'property' : a.Property_Display_Name__c),
                WhatId = a.Id,
                WhoId = a.Broker__c,
                ActivityDate = Date.today(),
                Priority = 'High',
                Status = 'Not Started'
            ));
        }
        if (!toInsert.isEmpty()) insert toInsert;
        return toInsert.size();
    }
}
```

- [ ] **Step 4: Class access.** Add `<classAccesses><apexClass>BrokerCheckInReminderSchedulable</apexClass><enabled>true</enabled></classAccesses>` to the perm set.

- [ ] **Step 5: Deploy + test — verify PASS.**

Run: `sf project deploy start -d force-app/main/default/classes/BrokerCheckInReminderSchedulable.cls -d force-app/main/default/classes/BrokerCheckInReminderSchedulableTest.cls -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml --ignore-conflicts`
Run: `sf apex run test --tests BrokerCheckInReminderSchedulableTest --result-format human --synchronous`
Expected: 3 tests pass.

- [ ] **Step 6: (Optional, manual) schedule the job in the org.** Document in the commit body that an admin runs once: `System.schedule('Broker Check-in Reminders', '0 0 6 * * ?', new BrokerCheckInReminderSchedulable());` (daily 6am). Not part of metadata.

- [ ] **Step 7: Commit.** `git add force-app/main/default/classes/BrokerCheckInReminderSchedulable.cls force-app/main/default/classes/BrokerCheckInReminderSchedulable.cls-meta.xml force-app/main/default/classes/BrokerCheckInReminderSchedulableTest.cls force-app/main/default/classes/BrokerCheckInReminderSchedulableTest.cls-meta.xml force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml && git commit -m "feat: daily stale-check-in reminder scheduled Apex + tests"`

---

## Final verification (after all tasks)

- [ ] Run the full new test set: `sf apex run test --tests BrokerAssignmentControllerTest --tests BrokerCheckInReminderSchedulableTest --result-format human --synchronous` → all pass.
- [ ] Deploy the whole feature clean: `sf project deploy start -d force-app/main/default --ignore-conflicts` → `Succeeded`.
- [ ] Walk the three tabs (Broker Assignments / a record / Broker Scorecard) against the prototype screens and confirm parity.
- [ ] Update memory file `property-management-onboarding-build.md` (or a new `broker-assignments-build.md`) with the object, controller, LWCs, tab/app wiring, and the scheduled job, plus the `Property_Asset__c` lookup decision and the `Broker_Listing__c` name-collision note.
