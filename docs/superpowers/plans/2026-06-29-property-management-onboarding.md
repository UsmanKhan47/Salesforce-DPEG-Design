# Property Management — Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a new **Property Management** Salesforce app with an **Onboarding** tab (Screen 1 dashboard), a new **`Onboarding__c`** object, and an `Onboarding__c` record page (Screen 2 checklist), faithfully reproducing the `Property Onboarding Tracker` design.

**Architecture:** One new custom object `Onboarding__c` (one record per property in onboarding) carries summary/rollup number fields the dashboard aggregates. Checklist items are **standard Tasks** related to `Onboarding__c` via a custom lookup, with custom Task fields (category, source system, onboarding status). Per-component LWCs read aggregates from an `OnboardingController` Apex class; an `OnboardingTaskRollupService` recomputes a record's summary fields from its Tasks. This mirrors the existing **Transaction app** exactly.

**Tech Stack:** Salesforce metadata API (`sf` CLI v2), Apex, Lightning Web Components (API 62.0), SLDS, FlexiPages, native Path. Spec: `docs/superpowers/specs/2026-06-29-property-management-onboarding-design.md`.

## Global Constraints

- **No git in this repo.** The environment is not a git repository. Every task ends with a **deploy + verify** step (deploy the metadata, confirm `Status: Succeeded`, run Apex tests / query / manual UI check) **instead of a commit**. Do not run `git` commands.
- **Target org:** `DPEG-Acq-3` (the default org). All commands pass `-o DPEG-Acq-3` explicitly.
- **Shell:** Windows PowerShell. Run `sf` commands from the repo root `f:\Acquisition-Design-Salesforce`. Do **not** prefix with `cd`.
- **API version:** LWC bundles use `<apiVersion>62.0</apiVersion>` to match every existing component.
- **FLS gotcha:** sf-deployed custom fields receive **no** field-level security. Every new `Onboarding__c` and Task field MUST be granted read (and edit where writable) in the `Property_Management_Access` permission set, or LWC/Apex SOQL throws `No such column`. Assign the perm set to yourself after deploy: `sf org assign permset -n Property_Management_Access -o DPEG-Acq-3`.
- **Deploy ordering:** A permission set referencing an Apex class fails to deploy if the class does not yet exist. The perm set is created in Task 4 with field/object/tab perms only; `<classAccesses>` entries are added in the task that creates each class.
- **Picklist ↔ category alignment:** `Onboarding__c.Stage__c` has 8 values; `Task.Onboarding_Category__c` reuses values 1–7 (same spelling) so a task rolls into its stage.
- **Design tokens (verbatim):** navy `#1B3A6B`, teal `#1A7A6B`, amber `#D4940A`, red `#C0392B`, green `#2E844A`, grey `#6B7280`, muted `#9CA3AF`. Cards: white, 12px radius, border `1px #E7E7E7`, shadow `0 2px 6px rgba(8,7,7,0.05)`. Status colors — Complete teal, In Progress amber, Not Started grey, Blocked red, N/A muted. Source-system tags — Yardi navy, Excel green, Salesforce blue `#0E6E97`, Email grey. % bar: ≥80 teal, ≥50 amber, else red.

## File Structure

```
force-app/main/default/
  objects/Onboarding__c/
    Onboarding__c.object-meta.xml                 # Task 1
    fields/*.field-meta.xml                        # Task 1 (22 fields + 5 formulas)
    compactLayouts/Onboarding_Highlights.compactLayout-meta.xml   # Task 1
  objects/Task/fields/                             # Task 2 (5 custom Task fields)
    Onboarding__c.field-meta.xml
    Onboarding_Category__c.field-meta.xml
    Source_System__c.field-meta.xml
    Onboarding_Status__c.field-meta.xml
    Blocked_Reason__c.field-meta.xml
  applications/Property_Management.app-meta.xml    # Task 3 / Task 19
  tabs/Onboarding.tab-meta.xml                     # Task 3 (AppPage tab → Screen 1)
  tabs/Onboarding__c.tab-meta.xml                  # Task 3 (object tab)
  permissionsets/Property_Management_Access.permissionset-meta.xml  # Task 4 (+ edits T5,T14,T19)
  classes/
    OnboardingController.cls(+meta)                # Task 5 (+ getChecklist T16)
    OnboardingControllerTest.cls(+meta)            # Task 5 (+ T16)
    OnboardingTaskRollupService.cls(+meta)         # Task 14
    OnboardingTaskRollupServiceTest.cls(+meta)     # Task 14
  lwc/
    onboardingKpis/                                # Task 7
    onboardingPropertyList/                        # Task 8
    onboardingPortfolioProgress/                   # Task 9
    onboardingRiskAlerts/                          # Task 10
    onboardingTimeSla/                             # Task 11
    onboardingChecklist/                           # Task 17
    onboardingChecklistProgress/                   # Task 18
    onboardingTaskProgressByCategory/              # Task 18
  flexipages/Onboarding_Home.flexipage-meta.xml    # Task 12 (Screen 1)
  flexipages/Onboarding_Record_Page.flexipage-meta.xml  # Task 19 (Screen 2)
  pathAssistants/Onboarding_Path.pathAssistant-meta.xml # Task 13
scripts/seed-onboarding.apex                       # Task 6 (+ Park North tasks T15)
```

Reused existing components (no changes): `c-stat-card` (`lwc/statCard`), `c-list-datatable` (`lwc/listDatatable`, custom `pill`/`progress` cell types), `c-onboarding-card-child` (`lwc/onboardingCardChild`).

---
<!-- ===================== PHASE 0 — FOUNDATION ===================== -->
## Phase 0 — Foundation (prerequisites 1–4)

### Task 1: `Onboarding__c` object, fields, and compact layout

**Files:**
- Create: `force-app/main/default/objects/Onboarding__c/Onboarding__c.object-meta.xml`
- Create: `force-app/main/default/objects/Onboarding__c/fields/*.field-meta.xml` (27 files — see table)
- Create: `force-app/main/default/objects/Onboarding__c/compactLayouts/Onboarding_Highlights.compactLayout-meta.xml`

**Interfaces:**
- Produces: object `Onboarding__c` with the fields named in the table; consumed by every later task.

- [ ] **Step 1: Create the object definition**

`force-app/main/default/objects/Onboarding__c/Onboarding__c.object-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <compactLayoutAssignment>Onboarding_Highlights</compactLayoutAssignment>
    <deploymentStatus>Deployed</deploymentStatus>
    <enableActivities>true</enableActivities>
    <enableBulkApi>true</enableBulkApi>
    <enableFeeds>false</enableFeeds>
    <enableHistory>true</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <enableSharing>true</enableSharing>
    <enableStreamingApi>true</enableStreamingApi>
    <externalSharingModel>Private</externalSharingModel>
    <label>Onboarding</label>
    <nameField>
        <displayFormat>ONB-{0000}</displayFormat>
        <label>Onboarding Number</label>
        <trackHistory>false</trackHistory>
        <type>AutoNumber</type>
    </nameField>
    <pluralLabel>Onboardings</pluralLabel>
    <searchLayouts></searchLayouts>
    <sharingModel>ReadWrite</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
```

- [ ] **Step 2: Create the lookup field**

`fields/Property_Asset__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Property_Asset__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <label>Property Asset</label>
    <referenceTo>Property_Asset__c</referenceTo>
    <relationshipLabel>Onboardings</relationshipLabel>
    <relationshipName>Onboardings</relationshipName>
    <required>false</required>
    <trackHistory>false</trackHistory>
    <trackTrending>false</trackTrending>
    <type>Lookup</type>
</CustomField>
```

- [ ] **Step 3: Create the two picklist fields**

`fields/Stage__c.field-meta.xml` (8 values, "Property Set up" default):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Stage__c</fullName>
    <label>Stage</label>
    <required>false</required>
    <trackHistory>false</trackHistory>
    <trackTrending>false</trackTrending>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Property Set up</fullName><default>true</default><label>Property Set up</label></value>
            <value><fullName>Unit &amp; Tenant Setup</fullName><default>false</default><label>Unit &amp; Tenant Setup</label></value>
            <value><fullName>Vendor &amp; Expense Management</fullName><default>false</default><label>Vendor &amp; Expense Management</label></value>
            <value><fullName>NNN Reconciliation &amp; Billing Setup</fullName><default>false</default><label>NNN Reconciliation &amp; Billing Setup</label></value>
            <value><fullName>Tenant Communication &amp; Transition</fullName><default>false</default><label>Tenant Communication &amp; Transition</label></value>
            <value><fullName>Performance Tracking</fullName><default>false</default><label>Performance Tracking</label></value>
            <value><fullName>Leasing</fullName><default>false</default><label>Leasing</label></value>
            <value><fullName>Onboarding Complete</fullName><default>false</default><label>Onboarding Complete</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
```

`fields/Status__c.field-meta.xml` (5 values, "In Progress" default):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Status__c</fullName>
    <label>Status</label>
    <required>false</required>
    <trackHistory>false</trackHistory>
    <trackTrending>false</trackTrending>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>On Track</fullName><default>false</default><label>On Track</label></value>
            <value><fullName>In Progress</fullName><default>true</default><label>In Progress</label></value>
            <value><fullName>At Risk</fullName><default>false</default><label>At Risk</label></value>
            <value><fullName>Blocked</fullName><default>false</default><label>Blocked</label></value>
            <value><fullName>Complete</fullName><default>false</default><label>Complete</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
```

- [ ] **Step 4: Create the Number / Date / Text / Checkbox fields from this template**

For each row in the table, create `fields/<API>.field-meta.xml` using the matching template.

**Number template** (replace `API`, `LABEL`, `PRECISION`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>API</fullName>
    <externalId>false</externalId>
    <label>LABEL</label>
    <precision>PRECISION</precision>
    <required>false</required>
    <scale>0</scale>
    <trackHistory>false</trackHistory>
    <trackTrending>false</trackTrending>
    <type>Number</type>
    <unique>false</unique>
</CustomField>
```

**Date template:** same shell, body `<label>LABEL</label><required>false</required><trackHistory>false</trackHistory><trackTrending>false</trackTrending><type>Date</type>`.
**Text template:** body adds `<length>120</length>` and `<type>Text</type>`.
**Checkbox template:** body `<label>LABEL</label><defaultValue>false</defaultValue><trackHistory>false</trackHistory><trackTrending>false</trackTrending><type>Checkbox</type>`.

| API name | Label | Type | Precision |
|---|---|---|---|
| `Start_Date__c` | Start Date | Date | — |
| `Target_Completion_Date__c` | Target Completion Date | Date | — |
| `Onboarding_Lead__c` | Onboarding Lead | Text(120) | — |
| `Completion_Pct__c` | Completion % | Number | 3 |
| `Tasks_Total__c` | Tasks Total | Number | 4 |
| `Tasks_Complete__c` | Tasks Complete | Number | 4 |
| `Tasks_In_Progress__c` | Tasks In Progress | Number | 4 |
| `Tasks_Not_Started__c` | Tasks Not Started | Number | 4 |
| `Tasks_Blocked__c` | Tasks Blocked | Number | 4 |
| `Tasks_NA__c` | Tasks N/A | Number | 4 |
| `Tasks_Open__c` | Open Tasks | Number | 4 |
| `Tasks_Overdue__c` | Overdue Tasks | Number | 4 |
| `Tasks_Blocked_Now__c` | Blocked Tasks (Alert) | Number | 4 |
| `Tasks_Stalled__c` | Stalled Over 7 Days | Number | 4 |
| `Tasks_Due_7d__c` | Due Next 7 Days | Number | 4 |
| `Days_To_Onboard__c` | Days To Onboard | Number | 4 |
| `Age_Days__c` | Age (Days) | Number | 4 |
| `Oldest_Open_Days__c` | Oldest Open (Days) | Number | 4 |
| `Past_Target__c` | Past Target | Checkbox | — |

- [ ] **Step 5: Create the 5 formula fields**

`fields/Property_Name__c.field-meta.xml` (Text formula, one hop):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Property_Name__c</fullName>
    <label>Property Name</label>
    <formula>IF(ISBLANK(Property_Asset__c), TEXT(Name), Property_Asset__r.Property_Name__c)</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
</CustomField>
```

`fields/Property_Type_Display__c.field-meta.xml` — Text formula `TEXT(Property_Asset__r.Property_Type__c)`, label `Property Type`.
`fields/Address_Display__c.field-meta.xml` — Text formula `Property_Asset__r.Property__r.Address__c`, label `Address`.
`fields/Gross_Sq_Ft__c.field-meta.xml` — Number formula (`<precision>18</precision><scale>0</scale>`) `Property_Asset__r.Property__r.Square_Footage__c`, label `Gross Sq Ft`.
`fields/Tasks_Display__c.field-meta.xml` — Text formula `TEXT(Tasks_Complete__c) & " / " & TEXT(Tasks_Total__c)`, label `Tasks`.

(Each formula field uses the same shell as `Property_Name__c`: `<fullName>`, `<label>`, `<formula>`, `<formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>`, `<required>false</required>`, `<type>`, and for Number formulas `<precision>`/`<scale>`.)

- [ ] **Step 6: Create the compact layout**

`compactLayouts/Onboarding_Highlights.compactLayout-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CompactLayout xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Onboarding_Highlights</fullName>
    <fields>Property_Name__c</fields>
    <fields>Status__c</fields>
    <fields>Completion_Pct__c</fields>
    <fields>Target_Completion_Date__c</fields>
    <fields>Onboarding_Lead__c</fields>
    <fields>Tasks_Display__c</fields>
    <label>Onboarding Highlights</label>
</CompactLayout>
```

- [ ] **Step 7: Deploy and verify**

Run: `sf project deploy start -d force-app/main/default/objects/Onboarding__c -o DPEG-Acq-3`
Expected: `Status: Succeeded`. Then confirm the object exists:
Run: `sf data query -q "SELECT QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName='Onboarding__c'" -o DPEG-Acq-3`
Expected: one row returned.

---

### Task 2: Standard Task custom fields (checklist items)

**Files:**
- Create: `force-app/main/default/objects/Task/fields/Onboarding__c.field-meta.xml`
- Create: `force-app/main/default/objects/Task/fields/Onboarding_Category__c.field-meta.xml`
- Create: `force-app/main/default/objects/Task/fields/Source_System__c.field-meta.xml`
- Create: `force-app/main/default/objects/Task/fields/Onboarding_Status__c.field-meta.xml`
- Create: `force-app/main/default/objects/Task/fields/Blocked_Reason__c.field-meta.xml`

**Interfaces:**
- Produces: `Task.Onboarding__c` (lookup), `Task.Onboarding_Category__c`, `Task.Source_System__c`, `Task.Onboarding_Status__c`, `Task.Blocked_Reason__c`. Consumed by Tasks 14–18 and the seed (Task 15).

- [ ] **Step 1: Create the Task → Onboarding lookup**

`objects/Task/fields/Onboarding__c.field-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Onboarding__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <label>Onboarding</label>
    <referenceTo>Onboarding__c</referenceTo>
    <relationshipLabel>Checklist Tasks</relationshipLabel>
    <relationshipName>Checklist_Tasks</relationshipName>
    <required>false</required>
    <trackHistory>false</trackHistory>
    <trackTrending>false</trackTrending>
    <type>Lookup</type>
</CustomField>
```

- [ ] **Step 2: Create `Onboarding_Category__c` (7 values = Stage values 1–7)**

`objects/Task/fields/Onboarding_Category__c.field-meta.xml` — Picklist, `restricted=true`, values (none default): `Property Set up`, `Unit & Tenant Setup`, `Vendor & Expense Management`, `NNN Reconciliation & Billing Setup`, `Tenant Communication & Transition`, `Performance Tracking`, `Leasing`. (Use the Stage__c picklist XML shape; escape `&` as `&amp;`; label `Onboarding Category`.)

- [ ] **Step 3: Create `Source_System__c`**

Picklist, `restricted=true`, values: `Yardi`, `Excel`, `Salesforce`, `Email`. Label `Source System`.

- [ ] **Step 4: Create `Onboarding_Status__c`**

Picklist, `restricted=true`, values: `Not Started` (default), `In Progress`, `Complete`, `Blocked`, `Not Applicable`. Label `Onboarding Status`.

- [ ] **Step 5: Create `Blocked_Reason__c`**

Text(255). Label `Blocked Reason`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Blocked_Reason__c</fullName>
    <externalId>false</externalId>
    <label>Blocked Reason</label>
    <length>255</length>
    <required>false</required>
    <trackHistory>false</trackHistory>
    <trackTrending>false</trackTrending>
    <type>Text</type>
    <unique>false</unique>
</CustomField>
```

- [ ] **Step 6: Deploy and verify**

Run: `sf project deploy start -d force-app/main/default/objects/Task/fields -o DPEG-Acq-3`
Expected: `Status: Succeeded` listing the 5 Task fields as `Created`.

---

### Task 3: Property Management app + Onboarding tab + object tab

**Files:**
- Create: `force-app/main/default/tabs/Onboarding.tab-meta.xml`
- Create: `force-app/main/default/tabs/Onboarding__c.tab-meta.xml`
- Create: `force-app/main/default/applications/Property_Management.app-meta.xml`

**Interfaces:**
- Consumes: flexipage `Onboarding_Home` (created in Task 12 — the tab references it by name; deploy of the tab succeeds only once the flexipage exists, so this task's deploy is bundled with Task 12). The app + object tab deploy now.
- Produces: app `Property_Management`, tabs `Onboarding` and `Onboarding__c`.

- [ ] **Step 1: Create the object tab**

`tabs/Onboarding__c.tab-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <customObject>true</customObject>
    <motif>Custom51: Apple</motif>
</CustomTab>
```

- [ ] **Step 2: Create the AppPage tab (Screen 1)**

`tabs/Onboarding.tab-meta.xml` (references the `Onboarding_Home` flexipage built in Task 12):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPage>Onboarding_Home</flexiPage>
    <label>Onboarding</label>
    <motif>Custom51: Apple</motif>
</CustomTab>
```

- [ ] **Step 3: Create the application**

`applications/Property_Management.app-meta.xml` (the `View` actionOverride to the record page is added in Task 19):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomApplication xmlns="http://soap.sforce.com/2006/04/metadata">
    <brand>
        <headerColor>#2E844A</headerColor>
        <logo>DPEG_Logo_Clear</logo>
        <logoVersion>1</logoVersion>
        <shouldOverrideOrgTheme>true</shouldOverrideOrgTheme>
    </brand>
    <description>DPEG post-acquisition property onboarding — checklist tracking, SLA and risk.</description>
    <formFactors>Large</formFactors>
    <isNavAutoTempTabsDisabled>false</isNavAutoTempTabsDisabled>
    <isNavPersonalizationDisabled>true</isNavPersonalizationDisabled>
    <isNavTabPersistenceDisabled>true</isNavTabPersistenceDisabled>
    <label>Property Management</label>
    <navType>Standard</navType>
    <tabs>Onboarding</tabs>
    <tabs>Onboarding__c</tabs>
    <tabs>standard-report</tabs>
    <uiType>Lightning</uiType>
</CustomApplication>
```

- [ ] **Step 4: Deploy the object tab only (the AppPage tab + app deploy in Task 12 with the flexipage)**

Run: `sf project deploy start -d force-app/main/default/tabs/Onboarding__c.tab-meta.xml -o DPEG-Acq-3`
Expected: `Status: Succeeded`. (Deploying `Onboarding.tab` now would fail — `Onboarding_Home` flexipage does not exist yet. It is deployed in Task 12.)

---

### Task 4: Permission set `Property_Management_Access` (fields, object, tabs)

**Files:**
- Create: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Produces: perm set granting object + FLS + tab access. `<classAccesses>` are appended in Tasks 5, 14, 19.

- [ ] **Step 1: Create the permission set**

Grant object perms on `Onboarding__c`; FLS read on every `Onboarding__c` field from Task 1 (editable=true for the writable ones: Stage, Status, dates, lead, the summary numbers, Past_Target; editable=false for the 5 formula fields); FLS read+edit on the 5 Task fields from Task 2; tab visibility for `Onboarding__c` and `standard-Task`. Use this shape (one `fieldPermissions` block per field):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Object, field, tab and Apex access for the Property Management (Onboarding) app.</description>
    <hasActivationRequired>false</hasActivationRequired>
    <label>Property Management Access</label>
    <objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>true</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Onboarding__c</object>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
    <!-- One block per writable field (editable=true): -->
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Stage__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Status__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Property_Asset__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Start_Date__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Target_Completion_Date__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Onboarding_Lead__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Completion_Pct__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_Total__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_Complete__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_In_Progress__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_Not_Started__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_Blocked__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_NA__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_Open__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_Overdue__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_Blocked_Now__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_Stalled__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Tasks_Due_7d__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Days_To_Onboard__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Age_Days__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Oldest_Open_Days__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Onboarding__c.Past_Target__c</field><readable>true</readable></fieldPermissions>
    <!-- Formula fields are read-only (editable=false): -->
    <fieldPermissions><editable>false</editable><field>Onboarding__c.Property_Name__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Onboarding__c.Property_Type_Display__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Onboarding__c.Address_Display__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Onboarding__c.Gross_Sq_Ft__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Onboarding__c.Tasks_Display__c</field><readable>true</readable></fieldPermissions>
    <!-- Task custom fields: -->
    <fieldPermissions><editable>true</editable><field>Task.Onboarding__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Task.Onboarding_Category__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Task.Source_System__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Task.Onboarding_Status__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Task.Blocked_Reason__c</field><readable>true</readable></fieldPermissions>
    <tabSettings><tab>Onboarding__c</tab><visibility>Visible</visibility></tabSettings>
    <tabSettings><tab>standard-Task</tab><visibility>Visible</visibility></tabSettings>
</PermissionSet>
```

- [ ] **Step 2: Deploy and assign**

Run: `sf project deploy start -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -o DPEG-Acq-3`
Expected: `Status: Succeeded`.
Run: `sf org assign permset -n Property_Management_Access -o DPEG-Acq-3`
Expected: `Permsets assigned`.

- [ ] **Step 3: Verify foundation (prerequisites 1–4 done)**

Run: `sf data create record -s Onboarding__c -v "Stage__c='Property Set up' Status__c='In Progress'" -o DPEG-Acq-3`
Expected: `Successfully created record`. Then delete it:
Run: `sf data query -q "SELECT Id FROM Onboarding__c LIMIT 1" -o DPEG-Acq-3` → note the Id → `sf data delete record -s Onboarding__c -i <Id> -o DPEG-Acq-3`.

<!-- END PHASE 0 -->

<!-- ===================== PHASE 1 — SCREEN 1 (DASHBOARD) ===================== -->
## Phase 1 — Screen 1: Onboarding Home dashboard

### Task 5: `OnboardingController` (dashboard methods) + test

**Files:**
- Create: `force-app/main/default/classes/OnboardingController.cls` (+ `.cls-meta.xml`)
- Create: `force-app/main/default/classes/OnboardingControllerTest.cls` (+ `.cls-meta.xml`)
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Produces: `OnboardingController.getKpis()`→`Kpis{propertiesInOnboarding,avgCompletionPct,overdueTasks,avgDaysToOnboard}`; `getOnboardings()`→`List<Row>{id,name,propertyName,startDate,targetDate,stage,completionPct,openTasks,status,owner}`; `getPortfolio()`→`Portfolio{tasksComplete,tasksTotal,complete,inProgress,notStarted,blocked,na}`; `getRiskAlerts()`→`RiskAlerts{overdue,blocked,stalled,due7d}`; `getTimeSla()`→`TimeSla{avgDaysToOnboard,avgAge,pastTarget,oldestOpen}`. Consumed by LWCs in Tasks 7–11.

- [ ] **Step 1: Write the failing test**

`force-app/main/default/classes/OnboardingControllerTest.cls`:

```apex
@isTest
private class OnboardingControllerTest {
    @testSetup static void setup() {
        List<Onboarding__c> obs = new List<Onboarding__c>{
            new Onboarding__c(Stage__c='Unit & Tenant Setup', Status__c='In Progress',
                Onboarding_Lead__c='Isha Patel', Completion_Pct__c=80, Tasks_Open__c=5,
                Start_Date__c=Date.newInstance(2026,5,1), Target_Completion_Date__c=Date.newInstance(2026,7,1),
                Tasks_Total__c=100, Tasks_Complete__c=80, Tasks_In_Progress__c=10, Tasks_Not_Started__c=6,
                Tasks_Blocked__c=2, Tasks_NA__c=2, Tasks_Overdue__c=6, Tasks_Blocked_Now__c=2,
                Tasks_Stalled__c=3, Tasks_Due_7d__c=4, Days_To_Onboard__c=20, Age_Days__c=10,
                Oldest_Open_Days__c=15, Past_Target__c=false),
            new Onboarding__c(Stage__c='Leasing', Status__c='At Risk',
                Onboarding_Lead__c='Endya Williams', Completion_Pct__c=40, Tasks_Open__c=12,
                Start_Date__c=Date.newInstance(2026,6,1), Target_Completion_Date__c=Date.newInstance(2026,8,1),
                Tasks_Total__c=100, Tasks_Complete__c=40, Tasks_In_Progress__c=30, Tasks_Not_Started__c=24,
                Tasks_Blocked__c=4, Tasks_NA__c=2, Tasks_Overdue__c=8, Tasks_Blocked_Now__c=3,
                Tasks_Stalled__c=5, Tasks_Due_7d__c=6, Days_To_Onboard__c=28, Age_Days__c=14,
                Oldest_Open_Days__c=41, Past_Target__c=true),
            new Onboarding__c(Stage__c='Onboarding Complete', Status__c='Complete',
                Tasks_Total__c=50, Tasks_Complete__c=50)  // terminal — excluded from active
        };
        insert obs;
    }
    @isTest static void kpis() {
        Test.startTest();
        OnboardingController.Kpis k = OnboardingController.getKpis();
        Test.stopTest();
        System.assertEquals(2, k.propertiesInOnboarding, 'only active counted');
        System.assertEquals(60, k.avgCompletionPct, '(80+40)/(100+100) = 60%');
        System.assertEquals(14, k.overdueTasks, '6+8');
        System.assertEquals(24, k.avgDaysToOnboard, '(20+28)/2');
    }
    @isTest static void rows() {
        List<OnboardingController.Row> rows = OnboardingController.getOnboardings();
        System.assertEquals(2, rows.size());
        System.assertEquals('Isha Patel', rows[0].owner);
    }
    @isTest static void portfolio() {
        OnboardingController.Portfolio p = OnboardingController.getPortfolio();
        System.assertEquals(200, p.tasksTotal);
        System.assertEquals(120, p.complete);
        System.assertEquals(6, p.blocked);
    }
    @isTest static void riskAndSla() {
        OnboardingController.RiskAlerts a = OnboardingController.getRiskAlerts();
        System.assertEquals(14, a.overdue);
        System.assertEquals(5, a.blocked);
        OnboardingController.TimeSla t = OnboardingController.getTimeSla();
        System.assertEquals(1, t.pastTarget);
        System.assertEquals(41, t.oldestOpen);
    }
}
```

`OnboardingControllerTest.cls-meta.xml` (and `OnboardingController.cls-meta.xml`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Deploy the test to verify it fails to compile (controller missing)**

Run: `sf project deploy start -d force-app/main/default/classes/OnboardingControllerTest.cls -o DPEG-Acq-3`
Expected: FAIL — `Invalid type: OnboardingController` (the controller does not exist yet).

- [ ] **Step 3: Write the controller**

`force-app/main/default/classes/OnboardingController.cls`:

```apex
public with sharing class OnboardingController {

    private static final String DONE_STAGE = 'Onboarding Complete';
    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }

    // Active = still onboarding (not the terminal stage).
    private static List<Onboarding__c> activeOnboardings() {
        return [
            SELECT Id, Name, Property_Name__c, Stage__c, Status__c,
                   Start_Date__c, Target_Completion_Date__c, Onboarding_Lead__c,
                   Completion_Pct__c, Tasks_Total__c, Tasks_Complete__c, Tasks_In_Progress__c,
                   Tasks_Not_Started__c, Tasks_Blocked__c, Tasks_NA__c, Tasks_Open__c,
                   Tasks_Overdue__c, Tasks_Blocked_Now__c, Tasks_Stalled__c, Tasks_Due_7d__c,
                   Days_To_Onboard__c, Age_Days__c, Oldest_Open_Days__c, Past_Target__c
            FROM Onboarding__c
            WHERE Stage__c != :DONE_STAGE
            ORDER BY Target_Completion_Date__c NULLS LAST
        ];
    }

    public class Kpis {
        @AuraEnabled public Integer propertiesInOnboarding;
        @AuraEnabled public Integer avgCompletionPct;
        @AuraEnabled public Integer overdueTasks;
        @AuraEnabled public Integer avgDaysToOnboard;
    }

    @AuraEnabled(cacheable=true)
    public static Kpis getKpis() {
        Kpis k = new Kpis();
        Integer count = 0; Decimal totTasks = 0, compTasks = 0; Integer overdue = 0;
        Decimal dtoSum = 0; Integer dtoCount = 0;
        for (Onboarding__c o : activeOnboardings()) {
            count++;
            totTasks += nz(o.Tasks_Total__c);
            compTasks += nz(o.Tasks_Complete__c);
            overdue += (Integer) nz(o.Tasks_Overdue__c);
            if (o.Days_To_Onboard__c != null) { dtoSum += o.Days_To_Onboard__c; dtoCount++; }
        }
        k.propertiesInOnboarding = count;
        k.avgCompletionPct = totTasks > 0 ? (Integer) Math.round(100 * compTasks / totTasks) : 0;
        k.overdueTasks = overdue;
        k.avgDaysToOnboard = dtoCount > 0 ? (Integer) Math.round(dtoSum / dtoCount) : 0;
        return k;
    }

    public class Row {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String propertyName;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date targetDate;
        @AuraEnabled public String stage;
        @AuraEnabled public Integer completionPct;
        @AuraEnabled public Integer openTasks;
        @AuraEnabled public String status;
        @AuraEnabled public String owner;
    }

    @AuraEnabled(cacheable=true)
    public static List<Row> getOnboardings() {
        List<Row> rows = new List<Row>();
        for (Onboarding__c o : activeOnboardings()) {
            Row r = new Row();
            r.id = o.Id; r.name = o.Name; r.propertyName = o.Property_Name__c;
            r.startDate = o.Start_Date__c; r.targetDate = o.Target_Completion_Date__c;
            r.stage = o.Stage__c; r.completionPct = (Integer) nz(o.Completion_Pct__c);
            r.openTasks = (Integer) nz(o.Tasks_Open__c); r.status = o.Status__c;
            r.owner = o.Onboarding_Lead__c;
            rows.add(r);
        }
        return rows;
    }

    public class Portfolio {
        @AuraEnabled public Integer tasksComplete;
        @AuraEnabled public Integer tasksTotal;
        @AuraEnabled public Integer complete;
        @AuraEnabled public Integer inProgress;
        @AuraEnabled public Integer notStarted;
        @AuraEnabled public Integer blocked;
        @AuraEnabled public Integer na;
    }

    @AuraEnabled(cacheable=true)
    public static Portfolio getPortfolio() {
        Portfolio p = new Portfolio();
        p.tasksComplete = 0; p.tasksTotal = 0; p.complete = 0; p.inProgress = 0;
        p.notStarted = 0; p.blocked = 0; p.na = 0;
        for (Onboarding__c o : activeOnboardings()) {
            p.tasksTotal += (Integer) nz(o.Tasks_Total__c);
            p.complete += (Integer) nz(o.Tasks_Complete__c);
            p.inProgress += (Integer) nz(o.Tasks_In_Progress__c);
            p.notStarted += (Integer) nz(o.Tasks_Not_Started__c);
            p.blocked += (Integer) nz(o.Tasks_Blocked__c);
            p.na += (Integer) nz(o.Tasks_NA__c);
        }
        p.tasksComplete = p.complete;
        return p;
    }

    public class RiskAlerts {
        @AuraEnabled public Integer overdue;
        @AuraEnabled public Integer blocked;
        @AuraEnabled public Integer stalled;
        @AuraEnabled public Integer due7d;
    }

    @AuraEnabled(cacheable=true)
    public static RiskAlerts getRiskAlerts() {
        RiskAlerts a = new RiskAlerts();
        a.overdue = 0; a.blocked = 0; a.stalled = 0; a.due7d = 0;
        for (Onboarding__c o : activeOnboardings()) {
            a.overdue += (Integer) nz(o.Tasks_Overdue__c);
            a.blocked += (Integer) nz(o.Tasks_Blocked_Now__c);
            a.stalled += (Integer) nz(o.Tasks_Stalled__c);
            a.due7d += (Integer) nz(o.Tasks_Due_7d__c);
        }
        return a;
    }

    public class TimeSla {
        @AuraEnabled public Integer avgDaysToOnboard;
        @AuraEnabled public Integer avgAge;
        @AuraEnabled public Integer pastTarget;
        @AuraEnabled public Integer oldestOpen;
    }

    @AuraEnabled(cacheable=true)
    public static TimeSla getTimeSla() {
        TimeSla t = new TimeSla();
        Decimal dtoSum = 0; Integer dtoCount = 0; Decimal ageSum = 0; Integer ageCount = 0;
        Integer pastTarget = 0; Integer oldest = 0;
        for (Onboarding__c o : activeOnboardings()) {
            if (o.Days_To_Onboard__c != null) { dtoSum += o.Days_To_Onboard__c; dtoCount++; }
            if (o.Age_Days__c != null) { ageSum += o.Age_Days__c; ageCount++; }
            if (o.Past_Target__c == true) pastTarget++;
            if (o.Oldest_Open_Days__c != null && o.Oldest_Open_Days__c > oldest) {
                oldest = (Integer) o.Oldest_Open_Days__c;
            }
        }
        t.avgDaysToOnboard = dtoCount > 0 ? (Integer) Math.round(dtoSum / dtoCount) : 0;
        t.avgAge = ageCount > 0 ? (Integer) Math.round(ageSum / ageCount) : 0;
        t.pastTarget = pastTarget;
        t.oldestOpen = oldest;
        return t;
    }
}
```

- [ ] **Step 4: Add class access to the permission set**

In `Property_Management_Access.permissionset-meta.xml`, add immediately after the opening `<PermissionSet ...>` line:

```xml
    <classAccesses><apexClass>OnboardingController</apexClass><enabled>true</enabled></classAccesses>
```

- [ ] **Step 5: Deploy controller + test + perm set, run the test**

Run: `sf project deploy start -d force-app/main/default/classes/OnboardingController.cls force-app/main/default/classes/OnboardingControllerTest.cls force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -o DPEG-Acq-3`
Expected: `Status: Succeeded`.
Run: `sf apex run test -t OnboardingControllerTest -o DPEG-Acq-3 -w 10 -r human`
Expected: `Pass Rate: 100%`, 4 methods pass.

---

### Task 6: Seed 6 onboardings (`scripts/seed-onboarding.apex`)

**Files:**
- Create: `scripts/seed-onboarding.apex`

**Interfaces:**
- Produces: 6 `Property_Asset__c` + 6 `Onboarding__c` records whose summary fields sum to the mockup dashboard numbers.

- [ ] **Step 1: Write the seed script**

`scripts/seed-onboarding.apex`:

```apex
// Seed the 6 onboardings shown on Screen 1. Aggregates hit the mockup:
//   6 properties; Σcomplete/Σtotal = 412/605 = 68%; Σoverdue = 14; avg days-to-onboard = 24.
//   Portfolio breakdown Σ: complete 412, in-progress 96, not-started 61, blocked 14, N/A 22.
//   Risk Σ: overdue 14, blocked-now 5, stalled 8, due-7d 19. SLA: avg age 12, past-target 2, oldest 41.
// Destructive on Onboarding__c demo data (scratch org); reuses Property_Asset__c by name.
delete [SELECT Id FROM Onboarding__c];

List<String> names = new List<String>{
    'Apex Beset Mall','Park North','The Fountains','Riverside Commons','Westgate Plaza','Dollar Tree Center'
};
Map<String, Property_Asset__c> assetByName = new Map<String, Property_Asset__c>();
for (Property_Asset__c a : [SELECT Id, Property_Name__c FROM Property_Asset__c WHERE Property_Name__c IN :names]) {
    assetByName.put(a.Property_Name__c, a);
}
List<Property_Asset__c> newAssets = new List<Property_Asset__c>();
for (String n : names) {
    if (!assetByName.containsKey(n)) newAssets.add(new Property_Asset__c(Name = n, Property_Name__c = n));
}
if (!newAssets.isEmpty()) { insert newAssets; for (Property_Asset__c a : newAssets) assetByName.put(a.Property_Name__c, a); }
Id idApex = assetByName.get('Apex Beset Mall').Id;
Id idPark = assetByName.get('Park North').Id;
Id idFnt  = assetByName.get('The Fountains').Id;
Id idRiv  = assetByName.get('Riverside Commons').Id;
Id idWest = assetByName.get('Westgate Plaza').Id;
Id idDoll = assetByName.get('Dollar Tree Center').Id;

List<Onboarding__c> obs = new List<Onboarding__c>{
    new Onboarding__c(Property_Asset__c=idApex, Stage__c='Tenant Communication & Transition',
        Status__c='In Progress', Onboarding_Lead__c='Isha Patel', Completion_Pct__c=84, Tasks_Open__c=7,
        Start_Date__c=Date.newInstance(2026,5,2), Target_Completion_Date__c=Date.newInstance(2026,7,15),
        Tasks_Total__c=120, Tasks_Complete__c=95, Tasks_In_Progress__c=12, Tasks_Not_Started__c=9,
        Tasks_Blocked__c=2, Tasks_NA__c=2, Tasks_Overdue__c=2, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=1,
        Tasks_Due_7d__c=4, Days_To_Onboard__c=20, Age_Days__c=10, Oldest_Open_Days__c=20, Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idPark, Stage__c='NNN Reconciliation & Billing Setup',
        Status__c='In Progress', Onboarding_Lead__c='Fernando Ruiz', Completion_Pct__c=72, Tasks_Open__c=13,
        Start_Date__c=Date.newInstance(2026,4,18), Target_Completion_Date__c=Date.newInstance(2026,6,30),
        Tasks_Total__c=45, Tasks_Complete__c=32, Tasks_In_Progress__c=6, Tasks_Not_Started__c=5,
        Tasks_Blocked__c=1, Tasks_NA__c=1, Tasks_Overdue__c=5, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=0,
        Tasks_Due_7d__c=3, Days_To_Onboard__c=28, Age_Days__c=14, Oldest_Open_Days__c=30, Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idFnt, Stage__c='Unit & Tenant Setup',
        Status__c='At Risk', Onboarding_Lead__c='Endya Williams', Completion_Pct__c=41, Tasks_Open__c=22,
        Start_Date__c=Date.newInstance(2026,6,1), Target_Completion_Date__c=Date.newInstance(2026,8,10),
        Tasks_Total__c=130, Tasks_Complete__c=70, Tasks_In_Progress__c=30, Tasks_Not_Started__c=22,
        Tasks_Blocked__c=5, Tasks_NA__c=3, Tasks_Overdue__c=4, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=3,
        Tasks_Due_7d__c=4, Days_To_Onboard__c=22, Age_Days__c=8, Oldest_Open_Days__c=15, Past_Target__c=true),
    new Onboarding__c(Property_Asset__c=idRiv, Stage__c='Tenant Communication & Transition',
        Status__c='On Track', Onboarding_Lead__c='Isha Patel', Completion_Pct__c=95, Tasks_Open__c=3,
        Start_Date__c=Date.newInstance(2026,3,22), Target_Completion_Date__c=Date.newInstance(2026,5,30),
        Tasks_Total__c=90, Tasks_Complete__c=80, Tasks_In_Progress__c=5, Tasks_Not_Started__c=2,
        Tasks_Blocked__c=1, Tasks_NA__c=2, Tasks_Overdue__c=0, Tasks_Blocked_Now__c=0, Tasks_Stalled__c=0,
        Tasks_Due_7d__c=2, Days_To_Onboard__c=18, Age_Days__c=16, Oldest_Open_Days__c=12, Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idWest, Stage__c='Unit & Tenant Setup',
        Status__c='In Progress', Onboarding_Lead__c='Fernando Ruiz', Completion_Pct__c=58, Tasks_Open__c=15,
        Start_Date__c=Date.newInstance(2026,5,20), Target_Completion_Date__c=Date.newInstance(2026,7,28),
        Tasks_Total__c=110, Tasks_Complete__c=70, Tasks_In_Progress__c=25, Tasks_Not_Started__c=10,
        Tasks_Blocked__c=3, Tasks_NA__c=2, Tasks_Overdue__c=1, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=2,
        Tasks_Due_7d__c=3, Days_To_Onboard__c=30, Age_Days__c=12, Oldest_Open_Days__c=28, Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idDoll, Stage__c='Property Set up',
        Status__c='Blocked', Onboarding_Lead__c='Endya Williams', Completion_Pct__c=12, Tasks_Open__c=28,
        Start_Date__c=Date.newInstance(2026,6,10), Target_Completion_Date__c=Date.newInstance(2026,8,22),
        Tasks_Total__c=110, Tasks_Complete__c=65, Tasks_In_Progress__c=18, Tasks_Not_Started__c=13,
        Tasks_Blocked__c=2, Tasks_NA__c=12, Tasks_Overdue__c=2, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=2,
        Tasks_Due_7d__c=3, Days_To_Onboard__c=26, Age_Days__c=12, Oldest_Open_Days__c=41, Past_Target__c=true)
};
insert obs;
System.debug('Inserted ' + obs.size() + ' onboardings.');
```

- [ ] **Step 2: Run the seed and verify aggregates**

Run: `sf apex run -f scripts/seed-onboarding.apex -o DPEG-Acq-3`
Expected: `Compiled successfully` / `Executed successfully`.
Run: `sf data query -q "SELECT COUNT(Id) c, SUM(Tasks_Total__c) tot, SUM(Tasks_Complete__c) comp, SUM(Tasks_Overdue__c) od FROM Onboarding__c" -o DPEG-Acq-3`
Expected: `c=6, tot=605, comp=412, od=14`.

---

### Task 7: `onboardingKpis` LWC

**Files:**
- Create: `force-app/main/default/lwc/onboardingKpis/onboardingKpis.{js,html,css,js-meta.xml}`

**Interfaces:**
- Consumes: `OnboardingController.getKpis`. Renders 4 `c-stat-card` tiles.

- [ ] **Step 1: JS**

`onboardingKpis.js`:

```js
import { LightningElement, wire } from 'lwc';
import getKpis from '@salesforce/apex/OnboardingController.getKpis';

const CARD_META = [
    { key: 'props',   label: 'Properties in Onboarding', iconName: 'utility:home',     color: '#1B3A6B' },
    { key: 'avg',     label: 'Avg % Complete',           iconName: 'utility:trending', color: '#1A7A6B' },
    { key: 'overdue', label: 'Overdue Tasks',            iconName: 'utility:warning',  color: '#D4940A' },
    { key: 'days',    label: 'Avg Time-to-Onboard',      iconName: 'utility:event',    color: '#1B3A6B' }
];

export default class OnboardingKpis extends LightningElement {
    kpis;
    @wire(getKpis) wired({ data }) { if (data) this.kpis = data; }
    get metrics() {
        const k = this.kpis || {};
        const values = {
            props:   k.propertiesInOnboarding != null ? String(k.propertiesInOnboarding) : '0',
            avg:     (k.avgCompletionPct != null ? k.avgCompletionPct : 0) + '%',
            overdue: k.overdueTasks != null ? String(k.overdueTasks) : '0',
            days:    (k.avgDaysToOnboard != null ? k.avgDaysToOnboard : 0) + 'd'
        };
        return CARD_META.map((m) => ({
            key: m.key, label: m.label, iconName: m.iconName, iconColor: m.color, displayValue: values[m.key]
        }));
    }
}
```

- [ ] **Step 2: HTML**

`onboardingKpis.html`:

```html
<template>
    <div class="dashboard-cards">
        <div class="cards-row">
            <template for:each={metrics} for:item="metric">
                <c-stat-card
                    key={metric.key}
                    value={metric.displayValue}
                    label={metric.label}
                    icon-name={metric.iconName}
                    icon-color={metric.iconColor}>
                </c-stat-card>
            </template>
        </div>
    </div>
</template>
```

- [ ] **Step 3: CSS**

`onboardingKpis.css`:

```css
.dashboard-cards { padding: 2px 0; }
.cards-row { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
@media (max-width: 1024px) { .cards-row { grid-template-columns: repeat(2, 1fr); } }
```

- [ ] **Step 4: Meta**

`onboardingKpis.js-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Onboarding KPIs</masterLabel>
    <description>Onboarding Home header — 4 KPI cards.</description>
    <targets>
        <target>lightning__AppPage</target>
        <target>lightning__HomePage</target>
    </targets>
</LightningComponentBundle>
```

- [ ] **Step 5: Deploy**

Run: `sf project deploy start -d force-app/main/default/lwc/onboardingKpis -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

---

### Task 8: `onboardingPropertyList` LWC

**Files:**
- Create: `force-app/main/default/lwc/onboardingPropertyList/onboardingPropertyList.{js,html,css,js-meta.xml}`

**Interfaces:**
- Consumes: `OnboardingController.getOnboardings`, `c-list-datatable` (`pill`, `progress` cell types).

- [ ] **Step 1: JS**

`onboardingPropertyList.js`:

```js
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getOnboardings from '@salesforce/apex/OnboardingController.getOnboardings';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const STATUS = {
    'On Track':    ['#E2F0EC', '#1A7A6B'],
    'In Progress': ['#FBF1DA', '#D4940A'],
    'At Risk':     ['#FAE6E2', '#C0392B'],
    'Blocked':     ['#FAE6E2', '#C0392B'],
    'Complete':    ['#E2F0EC', '#1A7A6B']
};
const FALLBACK = ['#EEF1F4', '#94a3b8'];
const pillWrap = (bg) => `display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:9999px;font-weight:600;color:#3e3e3e;background:${bg}`;
const pillDot = (c) => `width:7px;height:7px;border-radius:50%;background:${c};flex-shrink:0`;
const pctColor = (p) => (p >= 80 ? '#1A7A6B' : p >= 50 ? '#D4940A' : '#C0392B');

const COLUMNS = [
    { label: 'Property', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'propertyName' }, target: '_self' } },
    { label: 'Start', fieldName: 'startLabel', type: 'text' },
    { label: 'Target', fieldName: 'targetLabel', type: 'text' },
    { label: 'Stage', fieldName: 'stage', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: { fieldName: 'stageDot' } } },
    {
        label: '% Complete', fieldName: 'pctText', type: 'progress',
        typeAttributes: {
            wrapStyle: 'display:flex;align-items:center;gap:10px;min-width:150px',
            trackStyle: 'width:96px;height:8px;background:#ECEBEA;border-radius:9999px;overflow:hidden',
            barStyle: { fieldName: 'pctBar' },
            numStyle: 'color:#3B3B3B;font-weight:700;white-space:nowrap;font-size:12px;font-variant-numeric:tabular-nums',
            text: { fieldName: 'pctText' }
        }
    },
    { label: 'Open', fieldName: 'openTasks', type: 'number', cellAttributes: { alignment: 'center' } },
    { label: 'Status', fieldName: 'status', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'statusWrap' }, dotStyle: { fieldName: 'statusDot' } } },
    { label: 'Owner', fieldName: 'owner', type: 'text' }
];

export default class OnboardingPropertyList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data;
    listUrl = '#';

    @wire(getOnboardings) wired({ data }) { if (data) this._data = data; }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => { this.listUrl = url; });
    }
    get listPageRef() {
        return { type: 'standard__objectPage', attributes: { objectApiName: 'Onboarding__c', actionName: 'list' } };
    }
    get count() { return this._data ? this._data.length : 0; }
    get rows() {
        if (!this._data) return [];
        return this._data.map((o) => {
            const pct = o.completionPct || 0;
            const [sBg, sDot] = STATUS[o.status] || FALLBACK;
            return {
                id: o.id,
                propertyName: o.propertyName || o.name,
                recordUrl: `/lightning/r/Onboarding__c/${o.id}/view`,
                startLabel: this.dateLabel(o.startDate),
                targetLabel: this.dateLabel(o.targetDate),
                stage: o.stage || '—',
                stageWrap: pillWrap('#EEF1F5'),
                stageDot: pillDot('#1B3A6B'),
                pctText: `${pct}%`,
                pctBar: `width:${pct}%;height:100%;background:${pctColor(pct)};border-radius:9999px`,
                openTasks: o.openTasks,
                status: o.status || '—',
                statusWrap: pillWrap(sBg),
                statusDot: pillDot(sDot),
                owner: o.owner || '—'
            };
        });
    }
    dateLabel(d) {
        if (!d) return '—';
        const p = String(d).split('-');
        if (p.length !== 3) return d;
        return MONTHS[parseInt(p[1], 10) - 1] + ' ' + p[2];
    }
    viewAll(event) { event.preventDefault(); this[NavigationMixin.Navigate](this.listPageRef); }
}
```

- [ ] **Step 2: HTML**

`onboardingPropertyList.html`:

```html
<template>
    <lightning-card icon-name="standard:home">
        <span slot="title">Properties In Onboarding ({count})</span>
        <c-list-datatable
            key-field="id"
            data={rows}
            columns={columns}
            column-widths-mode="auto"
            hide-checkbox-column>
        </c-list-datatable>
        <div slot="footer" class="view-all-footer">
            <a href={listUrl} onclick={viewAll}>View All</a>
        </div>
    </lightning-card>
</template>
```

- [ ] **Step 3: CSS**

`onboardingPropertyList.css`:

```css
.view-all-footer { text-align: center; }
.view-all-footer a { font-weight: 600; color: #0B5CAB; text-decoration: none; }
.view-all-footer a:hover { text-decoration: underline; }
```

- [ ] **Step 4: Meta** — same shape as Task 7 Step 4, `masterLabel` "Onboarding Property List", `description` "Properties in onboarding table.", targets `lightning__AppPage` + `lightning__HomePage`.

- [ ] **Step 5: Deploy**

Run: `sf project deploy start -d force-app/main/default/lwc/onboardingPropertyList -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

---

### Task 9: `onboardingPortfolioProgress` LWC

**Files:**
- Create: `force-app/main/default/lwc/onboardingPortfolioProgress/onboardingPortfolioProgress.{js,html,css,js-meta.xml}`

**Interfaces:**
- Consumes: `OnboardingController.getPortfolio`.

- [ ] **Step 1: JS**

`onboardingPortfolioProgress.js`:

```js
import { LightningElement, wire } from 'lwc';
import getPortfolio from '@salesforce/apex/OnboardingController.getPortfolio';

const SEG = [
    { key: 'complete',   label: 'Complete',    color: '#1A7A6B' },
    { key: 'inProgress', label: 'In Progress', color: '#D4940A' },
    { key: 'notStarted', label: 'Not Started', color: '#6B7280' },
    { key: 'blocked',    label: 'Blocked',     color: '#C0392B' },
    { key: 'na',         label: 'N/A',         color: '#9CA3AF' }
];

export default class OnboardingPortfolioProgress extends LightningElement {
    p;
    @wire(getPortfolio) wired({ data }) { if (data) this.p = data; }
    get pct() { const p = this.p; if (!p || !p.tasksTotal) return 0; return Math.round((100 * p.complete) / p.tasksTotal); }
    get donutStyle() { const v = this.pct; return `background:conic-gradient(#1A7A6B 0% ${v}%, #ECEBEA ${v}% 100%)`; }
    get pctLabel() { return this.pct + '%'; }
    get completeLabel() { return this.p ? String(this.p.complete) : '0'; }
    get totalLabel() { return this.p ? `/ ${this.p.tasksTotal}` : '/ 0'; }
    get segments() {
        const p = this.p || {}; const total = p.tasksTotal || 1;
        return SEG.map((s) => {
            const count = p[s.key] || 0;
            return {
                key: s.key, label: s.label, count,
                barStyle: `width:${(count / total) * 100}%;height:100%;background:${s.color}`,
                dotStyle: `width:9px;height:9px;border-radius:2px;background:${s.color};flex-shrink:0`
            };
        });
    }
}
```

- [ ] **Step 2: HTML**

`onboardingPortfolioProgress.html`:

```html
<template>
    <lightning-card icon-name="standard:metrics">
        <span slot="title">Portfolio Progress</span>
        <div class="body">
            <div class="top">
                <div class="donut" style={donutStyle}>
                    <div class="hole"><span class="dpct">{pctLabel}</span><span class="dcap">complete</span></div>
                </div>
                <div class="nums">
                    <div class="caps">Tasks Completed</div>
                    <div class="big"><span class="comp">{completeLabel}</span><span class="tot">{totalLabel}</span></div>
                </div>
            </div>
            <div class="stack">
                <template for:each={segments} for:item="s">
                    <div key={s.key} style={s.barStyle}></div>
                </template>
            </div>
            <div class="legend">
                <template for:each={segments} for:item="s">
                    <div key={s.key} class="leg"><span style={s.dotStyle}></span><span class="llabel">{s.label}</span><span class="lcount">{s.count}</span></div>
                </template>
            </div>
        </div>
    </lightning-card>
</template>
```

- [ ] **Step 3: CSS**

`onboardingPortfolioProgress.css`:

```css
.body { padding: 4px 14px 14px; }
.top { display: flex; align-items: center; gap: 18px; margin-bottom: 16px; }
.donut { position: relative; width: 104px; height: 104px; border-radius: 50%; display: flex; align-items: center; justify-content: center; flex: none; }
.hole { width: 74px; height: 74px; border-radius: 50%; background: #fff; display: flex; flex-direction: column; align-items: center; justify-content: center; }
.dpct { font-size: 23px; font-weight: 700; color: #181818; line-height: 1; }
.dcap { font-size: 9.5px; color: #9A9A9A; text-transform: uppercase; letter-spacing: 0.04em; margin-top: 2px; }
.caps { font-size: 11px; font-weight: 700; letter-spacing: 0.04em; text-transform: uppercase; color: #706E6B; }
.big { display: flex; align-items: baseline; gap: 7px; margin-top: 5px; }
.comp { font-size: 26px; font-weight: 700; color: #181818; line-height: 1; }
.tot { font-size: 15px; color: #9A9A9A; font-weight: 500; }
.stack { display: flex; height: 18px; border-radius: 6px; overflow: hidden; border: 1px solid #EDEDED; margin-bottom: 13px; }
.legend { display: flex; flex-wrap: wrap; gap: 6px 16px; }
.leg { display: flex; align-items: center; gap: 6px; }
.llabel { font-size: 11.5px; color: #5C5C5C; }
.lcount { font-size: 11.5px; font-weight: 700; color: #181818; }
```

- [ ] **Step 4: Meta** — same shape, `masterLabel` "Onboarding Portfolio Progress", targets `lightning__AppPage` + `lightning__HomePage`.

- [ ] **Step 5: Deploy**

Run: `sf project deploy start -d force-app/main/default/lwc/onboardingPortfolioProgress -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

---

### Task 10: `onboardingRiskAlerts` LWC

**Files:**
- Create: `force-app/main/default/lwc/onboardingRiskAlerts/onboardingRiskAlerts.{js,html,css,js-meta.xml}`

**Interfaces:**
- Consumes: `OnboardingController.getRiskAlerts`.

- [ ] **Step 1: JS**

`onboardingRiskAlerts.js`:

```js
import { LightningElement, wire } from 'lwc';
import getRiskAlerts from '@salesforce/apex/OnboardingController.getRiskAlerts';

const TILES = [
    { key: 'overdue', label: 'Overdue Tasks',   tone: 'red' },
    { key: 'blocked', label: 'Blocked Tasks',   tone: 'red' },
    { key: 'stalled', label: 'Stalled Over 7 Days', tone: 'amber' },
    { key: 'due7d',   label: 'Due Next 7 Days', tone: 'amber' }
];
const TONE = {
    red:   { bg: '#FCF3F1', border: '#F1C9C2', fg: '#C0392B' },
    amber: { bg: '#FDF8EC', border: '#F0DFB6', fg: '#B17A0A' }
};

export default class OnboardingRiskAlerts extends LightningElement {
    a;
    @wire(getRiskAlerts) wired({ data }) { if (data) this.a = data; }
    get tiles() {
        const a = this.a || {};
        return TILES.map((t) => {
            const tone = TONE[t.tone];
            return {
                key: t.key, label: t.label,
                value: a[t.key] != null ? String(a[t.key]) : '0',
                tileStyle: `border:1px solid ${tone.border};background:${tone.bg}`,
                valueStyle: `color:${tone.fg}`
            };
        });
    }
}
```

- [ ] **Step 2: HTML**

`onboardingRiskAlerts.html`:

```html
<template>
    <lightning-card icon-name="standard:incident">
        <span slot="title">Risk &amp; Alerts</span>
        <div class="grid">
            <template for:each={tiles} for:item="t">
                <div key={t.key} class="tile" style={t.tileStyle}>
                    <div class="val" style={t.valueStyle}>{t.value}</div>
                    <div class="lbl">{t.label}</div>
                </div>
            </template>
        </div>
    </lightning-card>
</template>
```

- [ ] **Step 3: CSS**

`onboardingRiskAlerts.css`:

```css
.grid { padding: 6px 14px 14px; display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.tile { border-radius: 9px; padding: 13px 14px; }
.val { font-size: 21px; font-weight: 700; line-height: 1; }
.lbl { font-size: 10.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.03em; color: #706E6B; margin-top: 5px; }
```

- [ ] **Step 4: Meta** — `masterLabel` "Onboarding Risk & Alerts", targets `lightning__AppPage` + `lightning__HomePage`.

- [ ] **Step 5: Deploy**

Run: `sf project deploy start -d force-app/main/default/lwc/onboardingRiskAlerts -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

---

### Task 11: `onboardingTimeSla` LWC

**Files:**
- Create: `force-app/main/default/lwc/onboardingTimeSla/onboardingTimeSla.{js,html,css,js-meta.xml}`

**Interfaces:**
- Consumes: `OnboardingController.getTimeSla`.

- [ ] **Step 1: JS**

`onboardingTimeSla.js`:

```js
import { LightningElement, wire } from 'lwc';
import getTimeSla from '@salesforce/apex/OnboardingController.getTimeSla';

const TILES = [
    { key: 'avgDaysToOnboard', label: 'Avg Days to Onboard', tone: 'neutral' },
    { key: 'avgAge',           label: 'Avg Age of Active',   tone: 'neutral' },
    { key: 'pastTarget',       label: 'Past Target Duration', tone: 'amber' },
    { key: 'oldestOpen',       label: 'Oldest Open (Days)',  tone: 'red' }
];
const TONE = {
    neutral: { bg: '#FAFAFA', border: '#EDEDED', fg: '#181818' },
    amber:   { bg: '#FDF8EC', border: '#F0DFB6', fg: '#B17A0A' },
    red:     { bg: '#FCF3F1', border: '#F1C9C2', fg: '#C0392B' }
};

export default class OnboardingTimeSla extends LightningElement {
    t;
    @wire(getTimeSla) wired({ data }) { if (data) this.t = data; }
    get tiles() {
        const t = this.t || {};
        return TILES.map((x) => {
            const tone = TONE[x.tone];
            return {
                key: x.key, label: x.label,
                value: t[x.key] != null ? String(t[x.key]) : '0',
                tileStyle: `border:1px solid ${tone.border};background:${tone.bg}`,
                valueStyle: `color:${tone.fg}`
            };
        });
    }
}
```

- [ ] **Step 2: HTML** — identical structure to Task 10 Step 2 but card icon `standard:date_time` and title `Time &amp; SLA`:

```html
<template>
    <lightning-card icon-name="standard:date_time">
        <span slot="title">Time &amp; SLA</span>
        <div class="grid">
            <template for:each={tiles} for:item="t">
                <div key={t.key} class="tile" style={t.tileStyle}>
                    <div class="val" style={t.valueStyle}>{t.value}</div>
                    <div class="lbl">{t.label}</div>
                </div>
            </template>
        </div>
    </lightning-card>
</template>
```

- [ ] **Step 3: CSS** — identical to Task 10 Step 3 (`onboardingTimeSla.css`):

```css
.grid { padding: 6px 14px 14px; display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.tile { border-radius: 9px; padding: 13px 14px; }
.val { font-size: 21px; font-weight: 700; line-height: 1; }
.lbl { font-size: 10.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.03em; color: #706E6B; margin-top: 5px; }
```

- [ ] **Step 4: Meta** — `masterLabel` "Onboarding Time & SLA", targets `lightning__AppPage` + `lightning__HomePage`.

- [ ] **Step 5: Deploy**

Run: `sf project deploy start -d force-app/main/default/lwc/onboardingTimeSla -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

---

### Task 12: `Onboarding_Home` flexipage + wire up tab + app (Screen 1 live)

**Files:**
- Create: `force-app/main/default/flexipages/Onboarding_Home.flexipage-meta.xml`
- Deploy: `tabs/Onboarding.tab-meta.xml` + `applications/Property_Management.app-meta.xml` (created in Task 3)

**Interfaces:**
- Consumes: the 5 LWCs (Tasks 7–11), the `Onboarding` tab + app (Task 3).

- [ ] **Step 1: Create the App Page flexipage**

`flexipages/Onboarding_Home.flexipage-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<FlexiPage xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>onboardingKpis</componentName>
                <identifier>onboardingKpisComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>region1</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>onboardingPropertyList</componentName>
                <identifier>onboardingPropertyListComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>region2</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>onboardingPortfolioProgress</componentName>
                <identifier>onboardingPortfolioProgressComponent</identifier>
            </componentInstance>
            <componentInstance>
                <componentName>onboardingRiskAlerts</componentName>
                <identifier>onboardingRiskAlertsComponent</identifier>
            </componentInstance>
            <componentInstance>
                <componentName>onboardingTimeSla</componentName>
                <identifier>onboardingTimeSlaComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>region3</name>
        <type>Region</type>
    </flexiPageRegions>
    <masterLabel>Onboarding Home</masterLabel>
    <template>
        <name>flexipage:appHomeTemplateHeaderTwoColumns</name>
    </template>
    <type>AppPage</type>
</FlexiPage>
```

- [ ] **Step 2: Deploy flexipage + tab + app together**

Run: `sf project deploy start -d force-app/main/default/flexipages/Onboarding_Home.flexipage-meta.xml force-app/main/default/tabs/Onboarding.tab-meta.xml force-app/main/default/applications/Property_Management.app-meta.xml -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

- [ ] **Step 3: Add the Onboarding (AppPage) tab to the perm set and redeploy**

In `Property_Management_Access.permissionset-meta.xml`, add:

```xml
    <tabSettings><tab>Onboarding</tab><visibility>Visible</visibility></tabSettings>
```

Run: `sf project deploy start -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

- [ ] **Step 4: Manual verification (Screen 1)**

Open the org: `sf org open -o DPEG-Acq-3 -p "/lightning/app/Property_Management"` (or App Launcher → Property Management → Onboarding tab). Confirm against the mockup:
- 4 KPI tiles read **6 / 68% / 14 / 24d**.
- "Properties In Onboarding (6)" table shows the 6 rows with stage + status pills and % bars.
- Portfolio Progress donut reads **68%**, **412 / 605**, 5-segment legend.
- Risk & Alerts reads **14 / 5 / 8 / 19**; Time & SLA reads **24 / 12 / 2 / 41**.

<!-- END PHASE 1 -->

<!-- ===================== PHASE 2 — SCREEN 2 (RECORD PAGE) ===================== -->
## Phase 2 — Screen 2: Property record page (onboarding checklist)

### Task 13: `Onboarding_Path` native Path on `Stage__c`

**Files:**
- Create: `force-app/main/default/pathAssistants/Onboarding_Path.pathAssistant-meta.xml`

**Interfaces:**
- Consumes: `Onboarding__c.Stage__c` (Task 1). Produces: a Path shown on the record page subheader (Task 19).

- [ ] **Step 1: Create the Path**

`pathAssistants/Onboarding_Path.pathAssistant-meta.xml` (one step per Stage value, in order; `&` → `&amp;`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PathAssistant xmlns="http://soap.sforce.com/2006/04/metadata">
    <active>true</active>
    <entityName>Onboarding__c</entityName>
    <fieldName>Stage__c</fieldName>
    <masterLabel>Onboarding Path</masterLabel>
    <pathAssistantSteps><info>Create the property record, link accounts, and assign the onboarding owner.</info><picklistValueName>Property Set up</picklistValueName></pathAssistantSteps>
    <pathAssistantSteps><info>Load units, leases, rent schedules, and reconcile the rent roll.</info><picklistValueName>Unit &amp; Tenant Setup</picklistValueName></pathAssistantSteps>
    <pathAssistantSteps><info>Enter vendors, service contracts, insurance, and recurring expenses.</info><picklistValueName>Vendor &amp; Expense Management</picklistValueName></pathAssistantSteps>
    <pathAssistantSteps><info>Define NNN charges, recovery pools, and generate first tenant statements.</info><picklistValueName>NNN Reconciliation &amp; Billing Setup</picklistValueName></pathAssistantSteps>
    <pathAssistantSteps><info>Send tenant communications and complete the transition.</info><picklistValueName>Tenant Communication &amp; Transition</picklistValueName></pathAssistantSteps>
    <pathAssistantSteps><info>Stand up KPI tracking in Salesforce.</info><picklistValueName>Performance Tracking</picklistValueName></pathAssistantSteps>
    <pathAssistantSteps><info>Sign the listing agreement and configure leasing.</info><picklistValueName>Leasing</picklistValueName></pathAssistantSteps>
    <pathAssistantSteps><info>Onboarding complete.</info><picklistValueName>Onboarding Complete</picklistValueName></pathAssistantSteps>
    <recordTypeName>__MASTER__</recordTypeName>
</PathAssistant>
```

- [ ] **Step 2: Deploy and verify**

Run: `sf project deploy start -d force-app/main/default/pathAssistants/Onboarding_Path.pathAssistant-meta.xml -o DPEG-Acq-3`
Expected: `Status: Succeeded`. (If it fails with "Path is not enabled," enable it in Setup → Path Settings → Enable, then redeploy.)

---

### Task 14: `OnboardingTaskRollupService` + test

**Files:**
- Create: `force-app/main/default/classes/OnboardingTaskRollupService.cls` (+ `.cls-meta.xml`)
- Create: `force-app/main/default/classes/OnboardingTaskRollupServiceTest.cls` (+ `.cls-meta.xml`)
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Produces: `OnboardingTaskRollupService.recalc(Set<Id> onboardingIds)` — recomputes the `Onboarding__c` summary fields from its checklist Tasks. Consumed by the seed (Task 15).

- [ ] **Step 1: Write the failing test**

`force-app/main/default/classes/OnboardingTaskRollupServiceTest.cls`:

```apex
@isTest
private class OnboardingTaskRollupServiceTest {
    @isTest static void recalcComputesRollups() {
        Onboarding__c o = new Onboarding__c(Stage__c='Unit & Tenant Setup', Status__c='In Progress');
        insert o;
        Date td = Date.today();
        List<Task> tasks = new List<Task>{
            new Task(Onboarding__c=o.Id, Subject='a', Onboarding_Category__c='Unit & Tenant Setup',
                Onboarding_Status__c='Complete', Status='Completed', ActivityDate=td.addDays(-30)),
            new Task(Onboarding__c=o.Id, Subject='b', Onboarding_Category__c='Unit & Tenant Setup',
                Onboarding_Status__c='In Progress', Status='Open', ActivityDate=td.addDays(3)),
            new Task(Onboarding__c=o.Id, Subject='c', Onboarding_Category__c='Unit & Tenant Setup',
                Onboarding_Status__c='Blocked', Status='Open', ActivityDate=td.addDays(-5)),
            new Task(Onboarding__c=o.Id, Subject='d', Onboarding_Category__c='Unit & Tenant Setup',
                Onboarding_Status__c='Not Applicable', Status='Open', ActivityDate=null)
        };
        insert tasks;
        Test.startTest();
        OnboardingTaskRollupService.recalc(new Set<Id>{ o.Id });
        Test.stopTest();
        Onboarding__c r = [SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_NA__c, Tasks_Open__c,
                                  Tasks_Overdue__c, Tasks_Blocked_Now__c, Completion_Pct__c
                           FROM Onboarding__c WHERE Id = :o.Id];
        System.assertEquals(4, r.Tasks_Total__c);
        System.assertEquals(1, r.Tasks_Complete__c);
        System.assertEquals(1, r.Tasks_NA__c);
        System.assertEquals(2, r.Tasks_Open__c, 'in-progress + blocked');
        System.assertEquals(1, r.Tasks_Overdue__c, 'only the open, past-due blocked task (−5d); complete excluded, in-progress is future, N/A has no date');
        System.assertEquals(1, r.Tasks_Blocked_Now__c);
        System.assertEquals(25, r.Completion_Pct__c, '1 of 4 = 25%');
    }
}
```

`.cls-meta.xml` for both classes: same `ApexClass` shell (apiVersion 62.0, status Active) as Task 5 Step 1.

- [ ] **Step 2: Deploy test to verify it fails (service missing)**

Run: `sf project deploy start -d force-app/main/default/classes/OnboardingTaskRollupServiceTest.cls -o DPEG-Acq-3`
Expected: FAIL — `Invalid type: OnboardingTaskRollupService`.

- [ ] **Step 3: Write the service**

`force-app/main/default/classes/OnboardingTaskRollupService.cls`:

```apex
public with sharing class OnboardingTaskRollupService {

    // Recompute the summary/rollup fields on each Onboarding__c from its checklist Tasks.
    public static void recalc(Set<Id> onboardingIds) {
        if (onboardingIds == null || onboardingIds.isEmpty()) return;
        Date today = Date.today();
        Date stalledCutoff = today.addDays(-7);
        Date due7dEnd = today.addDays(7);

        Map<Id, Onboarding__c> upd = new Map<Id, Onboarding__c>();
        for (Id oid : onboardingIds) {
            upd.put(oid, new Onboarding__c(Id=oid,
                Tasks_Total__c=0, Tasks_Complete__c=0, Tasks_In_Progress__c=0, Tasks_Not_Started__c=0,
                Tasks_Blocked__c=0, Tasks_NA__c=0, Tasks_Open__c=0, Tasks_Overdue__c=0,
                Tasks_Blocked_Now__c=0, Tasks_Stalled__c=0, Tasks_Due_7d__c=0, Completion_Pct__c=0));
        }

        for (Task t : [
            SELECT Onboarding__c, Onboarding_Status__c, ActivityDate
            FROM Task WHERE Onboarding__c IN :onboardingIds
        ]) {
            Onboarding__c o = upd.get(t.Onboarding__c);
            String st = t.Onboarding_Status__c;
            o.Tasks_Total__c += 1;
            Boolean isComplete = (st == 'Complete');
            Boolean isNA = (st == 'Not Applicable');
            if (isComplete) o.Tasks_Complete__c += 1;
            else if (st == 'In Progress') o.Tasks_In_Progress__c += 1;
            else if (st == 'Not Started') o.Tasks_Not_Started__c += 1;
            else if (st == 'Blocked') { o.Tasks_Blocked__c += 1; o.Tasks_Blocked_Now__c += 1; }
            if (isNA) o.Tasks_NA__c += 1;
            Boolean isOpen = (!isComplete && !isNA);
            if (isOpen) o.Tasks_Open__c += 1;
            if (isOpen && t.ActivityDate != null && t.ActivityDate < today) o.Tasks_Overdue__c += 1;
            if (st == 'In Progress' && t.ActivityDate != null && t.ActivityDate < stalledCutoff) o.Tasks_Stalled__c += 1;
            if (isOpen && t.ActivityDate != null && t.ActivityDate >= today && t.ActivityDate <= due7dEnd) o.Tasks_Due_7d__c += 1;
        }

        for (Onboarding__c o : upd.values()) {
            Decimal tot = (o.Tasks_Total__c == null) ? 0 : o.Tasks_Total__c;
            Decimal comp = (o.Tasks_Complete__c == null) ? 0 : o.Tasks_Complete__c;
            o.Completion_Pct__c = (tot > 0) ? (Integer) Math.round(100 * comp / tot) : 0;
        }
        update upd.values();
    }
}
```

- [ ] **Step 4: Add class access to the perm set**

Add to `Property_Management_Access.permissionset-meta.xml` (next to the existing `<classAccesses>`):

```xml
    <classAccesses><apexClass>OnboardingTaskRollupService</apexClass><enabled>true</enabled></classAccesses>
```

- [ ] **Step 5: Deploy and run the test**

Run: `sf project deploy start -d force-app/main/default/classes/OnboardingTaskRollupService.cls force-app/main/default/classes/OnboardingTaskRollupServiceTest.cls force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -o DPEG-Acq-3`
Expected: `Status: Succeeded`.
Run: `sf apex run test -t OnboardingTaskRollupServiceTest -o DPEG-Acq-3 -w 10 -r human`
Expected: `Pass Rate: 100%`.

---

### Task 15: Seed Park North's 45 checklist Tasks + roll up

**Files:**
- Create: `scripts/seed-onboarding-tasks.apex`

**Interfaces:**
- Consumes: the 6 onboardings (Task 6), the Task fields (Task 2), `OnboardingTaskRollupService` (Task 14).

> **Calibration:** the seed uses the literal mockup due dates (2026). The date-relative rollups (overdue, due-next-7-days, stalled) are exact when run on/around **2026-06-29** (the project's current date) and drift on other dates — acceptable for the demo (the spec notes demo numbers are illustrative).

- [ ] **Step 1: Write the task seed script**

`scripts/seed-onboarding-tasks.apex`:

```apex
// Seed Park North's 45 onboarding checklist Tasks (Screen 2), then roll up onto the Onboarding.
// Row = {category, subject, onboardingStatus, ownerLabel, sourceSystem, dueDate(or null), blockedReason(or null), hasNotes}
Id parkId = [SELECT Id FROM Onboarding__c WHERE Property_Asset__r.Property_Name__c = 'Park North' LIMIT 1].Id;
delete [SELECT Id FROM Task WHERE Onboarding__c = :parkId];

List<List<Object>> r = new List<List<Object>>{
    // Property Set up (7, all Complete)
    new List<Object>{'Property Set up','Create new property record','Complete','Isha Patel','Salesforce',Date.newInstance(2026,4,20),null,true},
    new List<Object>{'Property Set up','Enter basic property details (name, address, sq ft, type)','Complete','Isha Patel','Salesforce',Date.newInstance(2026,4,21),null,true},
    new List<Object>{'Property Set up','Link bank accounts for rent & expenses','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,4,24),null,false},
    new List<Object>{'Property Set up','Set up property GL accounts','Complete','Accounting Queue','Yardi',Date.newInstance(2026,4,25),null,false},
    new List<Object>{'Property Set up','Configure property management settings','Complete','Isha Patel','Yardi',Date.newInstance(2026,4,26),null,false},
    new List<Object>{'Property Set up','Upload property photos & documents','Complete','Endya Williams','Salesforce',Date.newInstance(2026,4,28),null,false},
    new List<Object>{'Property Set up','Assign onboarding owner & timeline','Complete','Isha Patel','Salesforce',Date.newInstance(2026,4,22),null,true},
    // Unit & Tenant Setup (14)
    new List<Object>{'Unit & Tenant Setup','Enter unit inventory (all units)','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,2),null,false},
    new List<Object>{'Unit & Tenant Setup','Enter tenant leases (all tenants)','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,6),null,true},
    new List<Object>{'Unit & Tenant Setup','Verify lease terms vs abstracts','Complete','Endya Williams','Excel',Date.newInstance(2026,5,8),null,true},
    new List<Object>{'Unit & Tenant Setup','Enter base rent schedules','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,9),null,false},
    new List<Object>{'Unit & Tenant Setup','Enter rent escalations / bumps','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,12),null,false},
    new List<Object>{'Unit & Tenant Setup','Set up recurring charges','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,13),null,false},
    new List<Object>{'Unit & Tenant Setup','Enter security deposits','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,14),null,false},
    new List<Object>{'Unit & Tenant Setup','Map tenants to units','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,10),null,false},
    new List<Object>{'Unit & Tenant Setup','Verify occupancy / vacancy status','Complete','Endya Williams','Yardi',Date.newInstance(2026,5,15),null,false},
    new List<Object>{'Unit & Tenant Setup','Reconcile rent roll to closing statement','Complete','Accounting Queue','Excel',Date.newInstance(2026,5,16),null,false},
    new List<Object>{'Unit & Tenant Setup','Set up CAM pro-rata share per tenant','In Progress','Fernando Ruiz','Excel',Date.newInstance(2026,7,3),null,true},
    new List<Object>{'Unit & Tenant Setup','Enter lease options & renewals','In Progress','Endya Williams','Excel',Date.newInstance(2026,7,5),null,false},
    new List<Object>{'Unit & Tenant Setup','Import outstanding tenant balances (A/R)','Blocked','Accounting Queue','Yardi',Date.newInstance(2026,6,18),'Blocked: awaiting seller closing statement',true},
    new List<Object>{'Unit & Tenant Setup','Enter co-tenancy / exclusivity clauses','Not Started','Endya Williams','Salesforce',Date.newInstance(2026,7,10),null,false},
    // Vendor & Expense Management (8)
    new List<Object>{'Vendor & Expense Management','Enter vendor list & W-9s','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,20),null,false},
    new List<Object>{'Vendor & Expense Management','Set up recurring vendor payments','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,22),null,false},
    new List<Object>{'Vendor & Expense Management','Map expense GL accounts','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,23),null,false},
    new List<Object>{'Vendor & Expense Management','Enter service contracts (landscaping, security)','Complete','Endya Williams','Excel',Date.newInstance(2026,5,25),null,false},
    new List<Object>{'Vendor & Expense Management','Enter insurance policies & premiums','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,26),null,false},
    new List<Object>{'Vendor & Expense Management','Load historical operating expenses','Complete','Accounting Queue','Excel',Date.newInstance(2026,5,28),null,false},
    new List<Object>{'Vendor & Expense Management','Set up utility accounts & transfers','In Progress','Endya Williams','Email',Date.newInstance(2026,7,2),null,true},
    new List<Object>{'Vendor & Expense Management','Set up lockbox services','Not Applicable','Accounting Queue','Email',null,'tenants remit via ACH',false},
    // NNN Reconciliation & Billing Setup (6)
    new List<Object>{'NNN Reconciliation & Billing Setup','Define NNN charges (CAM, taxes, insurance)','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,30),null,true},
    new List<Object>{'NNN Reconciliation & Billing Setup','Enter prior-year reconciliation true-ups','Complete','Accounting Queue','Excel',Date.newInstance(2026,6,2),null,false},
    new List<Object>{'NNN Reconciliation & Billing Setup','Set tenant billing schedules','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,6,5),null,false},
    new List<Object>{'NNN Reconciliation & Billing Setup','Set up NNN recovery pools','In Progress','Accounting Queue','Yardi',Date.newInstance(2026,6,22),null,true},
    new List<Object>{'NNN Reconciliation & Billing Setup','Configure gross-up & recovery caps','Not Started','Accounting Queue','Excel',Date.newInstance(2026,6,15),null,false},
    new List<Object>{'NNN Reconciliation & Billing Setup','Generate first NNN tenant statements','Not Started','Accounting Queue','Yardi',Date.newInstance(2026,6,20),null,false},
    // Tenant Communication & Transition (6)
    new List<Object>{'Tenant Communication & Transition','Send tenant welcome letters','Complete','Isha Patel','Email',Date.newInstance(2026,5,4),null,false},
    new List<Object>{'Tenant Communication & Transition','Notify tenants of new payment instructions','Complete','Isha Patel','Email',Date.newInstance(2026,5,5),null,false},
    new List<Object>{'Tenant Communication & Transition','Update tenant portal access','Complete','Endya Williams','Salesforce',Date.newInstance(2026,5,18),null,false},
    new List<Object>{'Tenant Communication & Transition','Schedule tenant transition meetings','Complete','Endya Williams','Email',Date.newInstance(2026,5,20),null,true},
    new List<Object>{'Tenant Communication & Transition','Collect updated tenant contact info','Complete','Endya Williams','Excel',Date.newInstance(2026,5,22),null,false},
    new List<Object>{'Tenant Communication & Transition','Send estoppel confirmation follow-ups','Not Started','Isha Patel','Email',Date.newInstance(2026,6,12),null,false},
    // Performance Tracking (1)
    new List<Object>{'Performance Tracking','Track KPIs in Salesforce','In Progress','Isha Patel','Salesforce',Date.newInstance(2026,7,15),null,true},
    // Leasing (3)
    new List<Object>{'Leasing','Sign listing agreement with brokerage','Complete','Isha Patel','Email',Date.newInstance(2026,6,1),null,false},
    new List<Object>{'Leasing','Set up available space listings','In Progress','Endya Williams','Salesforce',Date.newInstance(2026,7,8),null,false},
    new List<Object>{'Leasing','Define leasing commission schedule','Not Started','Fernando Ruiz','Excel',Date.newInstance(2026,7,12),null,false}
};

List<Task> tasks = new List<Task>();
for (List<Object> row : r) {
    String status = (String) row[2];
    tasks.add(new Task(
        OwnerId = UserInfo.getUserId(),
        Onboarding__c = parkId,
        Onboarding_Category__c = (String) row[0],
        Subject = (String) row[1],
        Onboarding_Status__c = status,
        Task_Owner_Label__c = (String) row[3],
        Source_System__c = (String) row[4],
        ActivityDate = (Date) row[5],
        Blocked_Reason__c = (String) row[6],
        Status = (status == 'Complete') ? 'Completed' : 'Open',
        Description = ((Boolean) row[7]) ? 'See onboarding notes.' : null
    ));
}
insert tasks;
OnboardingTaskRollupService.recalc(new Set<Id>{ parkId });
System.debug('Inserted ' + tasks.size() + ' Park North checklist tasks.');
```

- [ ] **Step 2: Run and verify**

Run: `sf apex run -f scripts/seed-onboarding-tasks.apex -o DPEG-Acq-3`
Expected: `Executed successfully`.
Run: `sf data query -q "SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_Overdue__c, Tasks_Due_7d__c, Tasks_Blocked_Now__c, Completion_Pct__c FROM Onboarding__c WHERE Property_Asset__r.Property_Name__c='Park North'" -o DPEG-Acq-3`
Expected: `Tasks_Total__c=45, Tasks_Complete__c=32, Tasks_Overdue__c=5, Tasks_Due_7d__c=3, Tasks_Blocked_Now__c=1, Completion_Pct__c=71`.

---

### Task 16: Add `getChecklist` to `OnboardingController`

**Files:**
- Modify: `force-app/main/default/classes/OnboardingController.cls`
- Modify: `force-app/main/default/classes/OnboardingControllerTest.cls`
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Produces: `OnboardingController.getChecklist(Id onboardingId)` → `List<ChecklistGroup>`, where `ChecklistGroup{String category; Integer total; Integer complete; List<ChecklistItem> items}` and `ChecklistItem{Id id; String name; String status; String system; String owner; Date due; String reason; Boolean hasNotes; Boolean overdue}`. Consumed by Tasks 17–18.

- [ ] **Step 1: Add the failing test method**

Append to `OnboardingControllerTest`:

```apex
    @isTest static void checklist() {
        Onboarding__c o = new Onboarding__c(Stage__c='Property Set up', Status__c='In Progress');
        insert o;
        insert new List<Task>{
            new Task(Onboarding__c=o.Id, Subject='Task A', Onboarding_Category__c='Property Set up',
                Onboarding_Status__c='Complete', Status='Completed', Source_System__c='Yardi',
                Task_Owner_Label__c='Isha Patel', ActivityDate=Date.today().addDays(-10)),
            new Task(Onboarding__c=o.Id, Subject='Task B', Onboarding_Category__c='Leasing',
                Onboarding_Status__c='Not Started', Status='Open', Source_System__c='Excel',
                Task_Owner_Label__c='Fernando Ruiz', ActivityDate=Date.today().addDays(-2))
        };
        List<OnboardingController.ChecklistGroup> groups = OnboardingController.getChecklist(o.Id);
        System.assertEquals(7, groups.size(), 'all 7 categories returned in order');
        System.assertEquals('Property Set up', groups[0].category);
        System.assertEquals(1, groups[0].total);
        System.assertEquals(1, groups[0].complete);
        OnboardingController.ChecklistGroup leasing = groups[6];
        System.assertEquals('Leasing', leasing.category);
        System.assertEquals(true, leasing.items[0].overdue, 'open & past due');
    }
```

- [ ] **Step 2: Add the method + inner classes to `OnboardingController`**

Insert before the final closing `}` of `OnboardingController`:

```apex
    public class ChecklistItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String system;
        @AuraEnabled public String owner;
        @AuraEnabled public Date due;
        @AuraEnabled public String reason;
        @AuraEnabled public Boolean hasNotes;
        @AuraEnabled public Boolean overdue;
    }
    public class ChecklistGroup {
        @AuraEnabled public String category;
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer complete;
        @AuraEnabled public List<ChecklistItem> items;
    }

    private static final List<String> CATEGORY_ORDER = new List<String>{
        'Property Set up','Unit & Tenant Setup','Vendor & Expense Management',
        'NNN Reconciliation & Billing Setup','Tenant Communication & Transition',
        'Performance Tracking','Leasing'
    };

    @AuraEnabled(cacheable=true)
    public static List<ChecklistGroup> getChecklist(Id onboardingId) {
        Map<String, ChecklistGroup> byCat = new Map<String, ChecklistGroup>();
        for (String c : CATEGORY_ORDER) {
            ChecklistGroup g = new ChecklistGroup();
            g.category = c; g.total = 0; g.complete = 0; g.items = new List<ChecklistItem>();
            byCat.put(c, g);
        }
        Date today = Date.today();
        for (Task t : [
            SELECT Id, Subject, Onboarding_Category__c, Onboarding_Status__c, Source_System__c,
                   Task_Owner_Label__c, ActivityDate, Blocked_Reason__c, Description
            FROM Task
            WHERE Onboarding__c = :onboardingId
            ORDER BY Onboarding_Category__c, ActivityDate NULLS LAST
        ]) {
            ChecklistGroup g = byCat.get(t.Onboarding_Category__c);
            if (g == null) continue;
            ChecklistItem it = new ChecklistItem();
            it.id = t.Id; it.name = t.Subject; it.status = t.Onboarding_Status__c;
            it.system = t.Source_System__c; it.owner = t.Task_Owner_Label__c;
            it.due = t.ActivityDate; it.reason = t.Blocked_Reason__c;
            it.hasNotes = String.isNotBlank(t.Description);
            Boolean isOpen = (t.Onboarding_Status__c != 'Complete' && t.Onboarding_Status__c != 'Not Applicable');
            it.overdue = isOpen && t.ActivityDate != null && t.ActivityDate < today;
            g.items.add(it);
            g.total += 1;
            if (t.Onboarding_Status__c == 'Complete') g.complete += 1;
        }
        List<ChecklistGroup> out = new List<ChecklistGroup>();
        for (String c : CATEGORY_ORDER) out.add(byCat.get(c));
        return out;
    }
```

- [ ] **Step 3: Grant FLS on `Task.Task_Owner_Label__c`**

Add to the perm set (it is read by `getChecklist`):

```xml
    <fieldPermissions><editable>true</editable><field>Task.Task_Owner_Label__c</field><readable>true</readable></fieldPermissions>
```

- [ ] **Step 4: Deploy and run tests**

Run: `sf project deploy start -d force-app/main/default/classes/OnboardingController.cls force-app/main/default/classes/OnboardingControllerTest.cls force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -o DPEG-Acq-3`
Expected: `Status: Succeeded`.
Run: `sf apex run test -t OnboardingControllerTest -o DPEG-Acq-3 -w 10 -r human`
Expected: `Pass Rate: 100%` (5 methods).

---

### Task 17: `onboardingChecklist` LWC

**Files:**
- Create: `force-app/main/default/lwc/onboardingChecklist/onboardingChecklist.{js,html,css,js-meta.xml}`

**Interfaces:**
- Consumes: `OnboardingController.getChecklist`, `@api recordId` (record page).

- [ ] **Step 1: JS**

`onboardingChecklist.js`:

```js
import { LightningElement, api, wire } from 'lwc';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const STATUS = {
    'Complete':       { fg:'#15625A', bg:'#E2F0EC', dot:'#1A7A6B', label:'Complete' },
    'In Progress':    { fg:'#8A5A00', bg:'#FBF1DA', dot:'#D4940A', label:'In Progress' },
    'Not Started':    { fg:'#4B5563', bg:'#ECEEF1', dot:'#6B7280', label:'Not Started' },
    'Blocked':        { fg:'#962518', bg:'#FAE6E2', dot:'#C0392B', label:'Blocked' },
    'Not Applicable': { fg:'#9CA3AF', bg:'#F1F2F4', dot:'#9CA3AF', label:'Not Applicable' }
};
const SYS = {
    'Yardi':      { fg:'#1B3A6B', bg:'#E8EDF6' },
    'Excel':      { fg:'#1B6E47', bg:'#E5EFE9' },
    'Salesforce': { fg:'#0E6E97', bg:'#E1F1F8' },
    'Email':      { fg:'#5B6470', bg:'#EEF0F2' }
};
const CTRL = {
    'Complete':       { bg:'#1A7A6B', border:'#1A7A6B', mark:'✓', mc:'#fff' },
    'In Progress':    { bg:'#fff',    border:'#D4940A', mark:'•', mc:'#D4940A' },
    'Not Started':    { bg:'#fff',    border:'#C7CBD1', mark:'',       mc:'#6B7280' },
    'Blocked':        { bg:'#FAE6E2', border:'#C0392B', mark:'!',      mc:'#C0392B' },
    'Not Applicable': { bg:'#F1F2F4', border:'#D1D5DB', mark:'–', mc:'#9CA3AF' }
};
const AVATAR = { 'Isha Patel':'#1B3A6B', 'Fernando Ruiz':'#1A7A6B', 'Endya Williams':'#D4940A', 'Accounting Queue':'#6B7280' };
const FILTERS = ['All','In Progress','Blocked','Not Applicable','Overdue'];

const initials = (n) => !n ? '?' : (n === 'Accounting Queue' ? 'AQ' : n.split(' ').map((w) => w[0]).join('').slice(0,2).toUpperCase());
const pctColor = (p) => (p >= 80 ? '#1A7A6B' : p >= 50 ? '#D4940A' : '#C0392B');

export default class OnboardingChecklist extends LightningElement {
    @api recordId;
    groups = [];
    selectedIndex = 0;
    filter = 'All';

    @wire(getChecklist, { onboardingId: '$recordId' })
    wired({ data }) { if (data) this.groups = data; }

    get headerLabel() {
        let total = 0, complete = 0;
        this.groups.forEach((g) => { total += g.total; complete += g.complete; });
        const pct = total ? Math.round((100 * complete) / total) : 0;
        return `${complete} of ${total} complete (${pct}%)`;
    }
    get tiles() {
        return this.groups.map((g, i) => {
            const sel = i === this.selectedIndex;
            return {
                key: g.category, letter: String.fromCharCode(65 + i), name: g.category,
                count: `${g.complete} / ${g.total}`, index: String(i),
                tileStyle: `display:flex;align-items:center;gap:11px;padding:10px 14px;border-radius:10px;cursor:pointer;min-width:200px;border:1px solid ${sel ? '#1B96FF' : '#E0E0E0'};background:${sel ? '#EAF5FE' : '#fff'}`,
                badgeStyle: `width:30px;height:30px;border-radius:50%;flex:none;display:inline-flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;${sel ? 'background:#1B96FF;color:#fff' : 'background:#fff;color:#706E6B;border:2px solid #C9C7C5'}`
            };
        });
    }
    get chips() {
        return FILTERS.map((f) => {
            const active = this.filter === f;
            return { key: f, label: f, name: f,
                chipStyle: `padding:5px 13px;border-radius:9999px;font-size:12px;font-weight:600;cursor:pointer;white-space:nowrap;background:${active ? '#1B3A6B' : '#fff'};color:${active ? '#fff' : '#5C5C5C'};border:1px solid ${active ? '#1B3A6B' : '#D7DAE0'}` };
        });
    }
    get selected() {
        const g = this.groups[this.selectedIndex];
        if (!g) return { letter: 'A', name: '', count: '0 / 0', fillStyle: 'width:0%;height:100%' };
        const pct = g.total ? Math.round((100 * g.complete) / g.total) : 0;
        return { letter: String.fromCharCode(65 + this.selectedIndex), name: g.category, count: `${g.complete} / ${g.total}`,
            fillStyle: `width:${pct}%;height:100%;background:${pctColor(pct)};border-radius:9999px` };
    }
    get items() {
        const g = this.groups[this.selectedIndex];
        if (!g) return [];
        return g.items.filter((it) => this.matches(it)).map((it) => this.enrich(it));
    }
    get isEmpty() { return this.items.length === 0; }

    matches(it) {
        const f = this.filter;
        if (f === 'All') return true;
        if (f === 'Overdue') return it.overdue;
        return it.status === f;
    }
    enrich(it) {
        const s = STATUS[it.status] || STATUS['Not Started'];
        const sys = SYS[it.system] || SYS['Email'];
        const c = CTRL[it.status] || CTRL['Not Started'];
        const done = it.status === 'Complete' || it.status === 'Not Applicable';
        const color = AVATAR[it.owner] || '#6B7280';
        return {
            id: it.id, name: it.name,
            nameStyle: `font-size:13.5px;font-weight:500;color:${done ? '#9A9A9A' : '#181818'};text-decoration:${done ? 'line-through' : 'none'}`,
            isBlocked: it.status === 'Blocked', reason: it.reason || '',
            statusLabel: s.label,
            badgeStyle: `display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:9999px;font-size:11px;font-weight:600;background:${s.bg};color:${s.fg};white-space:nowrap`,
            dotStyle: `width:6px;height:6px;border-radius:50%;background:${s.dot};flex-shrink:0`,
            system: it.system,
            sysStyle: `display:inline-flex;align-items:center;padding:2px 8px;border-radius:4px;font-size:10px;font-weight:700;letter-spacing:0.02em;background:${sys.bg};color:${sys.fg}`,
            controlStyle: `width:20px;height:20px;border-radius:5px;border:2px solid ${c.border};background:${c.bg};display:inline-flex;align-items:center;justify-content:center;font-size:${c.mark === '•' ? '15px' : '12px'};font-weight:700;color:${c.mc};flex:none;line-height:1`,
            controlMark: c.mark,
            initials: initials(it.owner),
            avatarStyle: `width:24px;height:24px;border-radius:50%;background:${color};color:#fff;font-size:9.5px;font-weight:700;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0`,
            ownerShort: it.owner === 'Accounting Queue' ? 'Accounting' : (it.owner ? it.owner.split(' ')[0] : ''),
            due: this.dateLabel(it.due),
            dueStyle: `font-size:12px;font-weight:${it.overdue ? '700' : '500'};color:${it.overdue ? '#C0392B' : '#5C5C5C'};white-space:nowrap`,
            notesColor: it.hasNotes ? '#1B3A6B' : '#CDD1D7'
        };
    }
    dateLabel(d) {
        if (!d) return '—';
        const p = String(d).split('-');
        if (p.length !== 3) return d;
        return MONTHS[parseInt(p[1], 10) - 1] + ' ' + p[2];
    }
    selectGroup(e) { this.selectedIndex = parseInt(e.currentTarget.dataset.index, 10); this.filter = 'All'; }
    selectFilter(e) { this.filter = e.currentTarget.dataset.name; }
}
```

- [ ] **Step 2: HTML**

`onboardingChecklist.html`:

```html
<template>
    <lightning-card icon-name="standard:task2">
        <span slot="title">Onboarding Checklist <span class="sub">— {headerLabel}</span></span>

        <div class="chips">
            <template for:each={chips} for:item="c">
                <div key={c.key} data-name={c.name} style={c.chipStyle} onclick={selectFilter}>{c.label}</div>
            </template>
        </div>

        <div class="tiles">
            <template for:each={tiles} for:item="g">
                <div key={g.key} data-index={g.index} style={g.tileStyle} onclick={selectGroup}>
                    <span style={g.badgeStyle}>{g.letter}</span>
                    <div class="tmeta">
                        <span class="tname">{g.name}</span>
                        <span class="tcount">{g.count}</span>
                    </div>
                </div>
            </template>
        </div>

        <div class="selhead">
            <div class="selbadge">{selected.letter}</div>
            <div class="selname">{selected.name}</div>
            <span class="selcount">{selected.count}</span>
        </div>
        <div class="seltrack"><div style={selected.fillStyle}></div></div>

        <div class="items">
            <template for:each={items} for:item="it">
                <div key={it.id} class="row">
                    <div style={it.controlStyle}>{it.controlMark}</div>
                    <div class="rmain">
                        <span style={it.nameStyle}>{it.name}</span>
                        <div class="rmeta">
                            <span style={it.sysStyle}>{it.system}</span>
                            <span style={it.badgeStyle}><span style={it.dotStyle}></span>{it.statusLabel}</span>
                            <template if:true={it.isBlocked}>
                                <span class="reason">{it.reason}</span>
                            </template>
                        </div>
                    </div>
                    <div class="rowner">
                        <div style={it.avatarStyle}>{it.initials}</div>
                        <span class="oname">{it.ownerShort} ·</span>
                        <span style={it.dueStyle}>{it.due}</span>
                    </div>
                </div>
            </template>
            <template if:true={isEmpty}>
                <div class="empty">No tasks match this filter in this category.</div>
            </template>
        </div>
    </lightning-card>
</template>
```

- [ ] **Step 3: CSS**

`onboardingChecklist.css`:

```css
.sub { font-weight: 400; color: #706E6B; font-size: 13px; }
.chips { display: flex; flex-wrap: wrap; gap: 8px; padding: 4px 14px 14px; border-bottom: 1px solid #EDEDED; }
.tiles { display: flex; flex-wrap: wrap; gap: 10px; padding: 14px; border-bottom: 1px solid #EDEDED; }
.tmeta { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
.tname { font-size: 12.5px; font-weight: 600; color: #181818; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tcount { font-size: 11.5px; color: #706E6B; }
.selhead { display: flex; align-items: center; gap: 12px; padding: 16px 14px 4px; }
.selbadge { width: 34px; height: 34px; border-radius: 8px; background: #1B3A6B; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 15px; font-weight: 700; flex: none; }
.selname { font-size: 15.5px; font-weight: 700; color: #181818; }
.selcount { font-size: 12px; font-weight: 600; color: #5C5C5C; background: #F2F2F2; border-radius: 9999px; padding: 2px 10px; }
.seltrack { height: 6px; background: #ECEBEA; border-radius: 9999px; overflow: hidden; margin: 8px 14px 4px; }
.row { display: flex; align-items: center; gap: 14px; padding: 12px 14px; border-top: 1px solid #F2F2F2; }
.rmain { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
.rmeta { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.reason { font-size: 11px; color: #C0392B; }
.rowner { display: flex; align-items: center; gap: 7px; flex: none; }
.oname { font-size: 12px; color: #5C5C5C; white-space: nowrap; }
.empty { padding: 18px 14px; border-top: 1px solid #F2F2F2; font-size: 13px; color: #9A9A9A; }
```

- [ ] **Step 4: Meta**

`onboardingChecklist.js-meta.xml` — same shell, `masterLabel` "Onboarding Checklist", target **`lightning__RecordPage`** only:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Onboarding Checklist</masterLabel>
    <description>Interactive onboarding checklist grouped by category.</description>
    <targets>
        <target>lightning__RecordPage</target>
    </targets>
</LightningComponentBundle>
```

- [ ] **Step 5: Deploy**

Run: `sf project deploy start -d force-app/main/default/lwc/onboardingChecklist -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

---

### Task 18: `onboardingChecklistProgress` + `onboardingTaskProgressByCategory` LWCs

**Files:**
- Create: `force-app/main/default/lwc/onboardingChecklistProgress/onboardingChecklistProgress.{js,html,css,js-meta.xml}`
- Create: `force-app/main/default/lwc/onboardingTaskProgressByCategory/onboardingTaskProgressByCategory.{js,html,css,js-meta.xml}`

**Interfaces:**
- Consumes: `OnboardingController.getChecklist`, `@api recordId`.

- [ ] **Step 1: `onboardingChecklistProgress.js`**

```js
import { LightningElement, api, wire } from 'lwc';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';

export default class OnboardingChecklistProgress extends LightningElement {
    @api recordId;
    groups = [];
    @wire(getChecklist, { onboardingId: '$recordId' }) wired({ data }) { if (data) this.groups = data; }
    get overall() {
        let total = 0, complete = 0;
        this.groups.forEach((g) => { total += g.total; complete += g.complete; });
        const pct = total ? Math.round((100 * complete) / total) : 0;
        return {
            pctLabel: total ? `${pct}%` : '—',
            label: total ? `${complete} of ${total} complete` : 'No checklist generated yet',
            barStyle: `width:${pct}%;height:100%;background:#C99A3F;border-radius:9999px`
        };
    }
}
```

- [ ] **Step 2: `onboardingChecklistProgress.html`**

```html
<template>
    <lightning-card icon-name="standard:task2">
        <span slot="title">Onboarding Checklist</span>
        <span slot="actions" class="pct">{overall.pctLabel}</span>
        <div class="wrap">
            <div class="track"><div style={overall.barStyle}></div></div>
            <div class="label">{overall.label}</div>
        </div>
    </lightning-card>
</template>
```

- [ ] **Step 3: `onboardingChecklistProgress.css`**

```css
.pct { font-size: 15px; font-weight: 700; color: #1A7A6B; padding-right: 8px; }
.wrap { padding: 4px 14px 14px; }
.track { height: 8px; background: #ECEBEA; border-radius: 9999px; overflow: hidden; margin-bottom: 8px; }
.label { font-size: 12px; color: #706E6B; }
```

- [ ] **Step 4: `onboardingChecklistProgress.js-meta.xml`** — same shell, `masterLabel` "Onboarding Checklist Progress", target `lightning__RecordPage`.

- [ ] **Step 5: `onboardingTaskProgressByCategory.js`**

```js
import { LightningElement, api, wire } from 'lwc';
import getChecklist from '@salesforce/apex/OnboardingController.getChecklist';

export default class OnboardingTaskProgressByCategory extends LightningElement {
    @api recordId;
    groups = [];
    @wire(getChecklist, { onboardingId: '$recordId' }) wired({ data }) { if (data) this.groups = data; }
    get tiles() {
        return this.groups.map((g) => {
            const pct = g.total ? Math.round((100 * g.complete) / g.total) : 0;
            const amber = pct < 60;
            return {
                key: g.category, name: g.category, count: `${g.complete} / ${g.total}`,
                tileStyle: `border:1px solid ${amber ? '#F0DFB6' : '#EDEDED'};background:${amber ? '#FDF8EC' : '#FAFAFA'};border-radius:9px;padding:13px 14px`
            };
        });
    }
}
```

- [ ] **Step 6: `onboardingTaskProgressByCategory.html`**

```html
<template>
    <lightning-card icon-name="standard:checklist">
        <span slot="title">Task Progress by Category</span>
        <div class="grid">
            <template for:each={tiles} for:item="t">
                <div key={t.key} class="tile" style={t.tileStyle}>
                    <div class="count">{t.count}</div>
                    <div class="name">{t.name}</div>
                </div>
            </template>
        </div>
    </lightning-card>
</template>
```

- [ ] **Step 7: `onboardingTaskProgressByCategory.css`**

```css
.grid { padding: 6px 14px 14px; display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.count { font-size: 18px; font-weight: 700; color: #181818; line-height: 1; }
.name { font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.03em; color: #706E6B; margin-top: 5px; }
```

- [ ] **Step 8: `onboardingTaskProgressByCategory.js-meta.xml`** — same shell, `masterLabel` "Task Progress by Category", target `lightning__RecordPage`.

- [ ] **Step 9: Deploy both**

Run: `sf project deploy start -d force-app/main/default/lwc/onboardingChecklistProgress force-app/main/default/lwc/onboardingTaskProgressByCategory -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

---

### Task 19: `Onboarding_Record_Page` flexipage + app override (Screen 2 live)

**Files:**
- Create: `force-app/main/default/flexipages/Onboarding_Record_Page.flexipage-meta.xml`
- Modify: `force-app/main/default/applications/Property_Management.app-meta.xml`

**Interfaces:**
- Consumes: highlights compact layout (Task 1), Path (Task 13), `onboardingChecklist` (Task 17), `onboardingChecklistProgress` + `onboardingTaskProgressByCategory` (Task 18).

- [ ] **Step 1: Create the record page**

`flexipages/Onboarding_Record_Page.flexipage-meta.xml`:

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
        <name>header</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>hideUpdateButton</name>
                    <value>false</value>
                </componentInstanceProperties>
                <componentName>runtime_sales_pathassistant:pathAssistant</componentName>
                <identifier>onboardingPath</identifier>
            </componentInstance>
        </itemInstances>
        <name>subheader</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>onboardingChecklist</componentName>
                <identifier>onboardingChecklistComp</identifier>
            </componentInstance>
        </itemInstances>
        <name>checklistContent</name>
        <type>Facet</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>force:detailPanel</componentName>
                <identifier>recordDetail</identifier>
            </componentInstance>
        </itemInstances>
        <name>detailContent</name>
        <type>Facet</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>parentFieldApiName</name>
                    <value>Onboarding__c.Id</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>relatedListApiName</name>
                    <value>CombinedAttachments</value>
                </componentInstanceProperties>
                <componentName>force:relatedListSingleContainer</componentName>
                <identifier>notesAttachmentsList</identifier>
            </componentInstance>
        </itemInstances>
        <name>notesContent</name>
        <type>Facet</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>body</name>
                    <value>checklistContent</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>title</name>
                    <value>Checklist</value>
                </componentInstanceProperties>
                <componentName>flexipage:tab</componentName>
                <identifier>checklistTab</identifier>
            </componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>body</name>
                    <value>detailContent</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>title</name>
                    <value>Details</value>
                </componentInstanceProperties>
                <componentName>flexipage:tab</componentName>
                <identifier>detailsTab</identifier>
            </componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>body</name>
                    <value>notesContent</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>title</name>
                    <value>Notes &amp; Attachments</value>
                </componentInstanceProperties>
                <componentName>flexipage:tab</componentName>
                <identifier>notesTab</identifier>
            </componentInstance>
        </itemInstances>
        <name>tabs</name>
        <type>Facet</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>tabs</name>
                    <value>tabs</value>
                </componentInstanceProperties>
                <componentName>flexipage:tabset</componentName>
                <identifier>mainTabset</identifier>
            </componentInstance>
        </itemInstances>
        <name>main</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>onboardingChecklistProgress</componentName>
                <identifier>onboardingChecklistProgressComp</identifier>
            </componentInstance>
            <componentInstance>
                <componentName>onboardingTaskProgressByCategory</componentName>
                <identifier>onboardingTaskProgressByCategoryComp</identifier>
            </componentInstance>
        </itemInstances>
        <name>sidebar</name>
        <type>Region</type>
    </flexiPageRegions>
    <masterLabel>Onboarding Record Page</masterLabel>
    <sobjectType>Onboarding__c</sobjectType>
    <template>
        <name>flexipage:recordHomeWithSubheaderTemplateDesktop</name>
    </template>
    <type>RecordPage</type>
</FlexiPage>
```

- [ ] **Step 2: Add the `View` action override to the app**

In `applications/Property_Management.app-meta.xml`, insert immediately after the opening `<CustomApplication ...>` line (before `<brand>`):

```xml
    <actionOverrides>
        <actionName>View</actionName>
        <comment>Onboarding Record Page</comment>
        <content>Onboarding_Record_Page</content>
        <formFactor>Large</formFactor>
        <skipRecordTypeSelect>false</skipRecordTypeSelect>
        <type>Flexipage</type>
        <pageOrSobjectType>Onboarding__c</pageOrSobjectType>
    </actionOverrides>
```

- [ ] **Step 3: Deploy flexipage + app**

Run: `sf project deploy start -d force-app/main/default/flexipages/Onboarding_Record_Page.flexipage-meta.xml force-app/main/default/applications/Property_Management.app-meta.xml -o DPEG-Acq-3`
Expected: `Status: Succeeded`.

- [ ] **Step 4: Manual verification (Screen 2)**

Open Park North: `sf org open -o DPEG-Acq-3 -p "/lightning/r/Onboarding__c/list"` → open the **Park North** record (or via the dashboard table link). Confirm against the mockup:
- Highlights panel shows Property name + Status + Completion % + Target + Lead + Tasks.
- Path shows the 8 stages with **NNN Reconciliation & Billing Setup** current.
- Checklist tab: header "**32 of 45 complete (71%)**", 7 group tiles with done/total, filter chips work (click "Overdue" → shows the 5 overdue items; click a group tile → switches category).
- A blocked item ("Import outstanding tenant balances (A/R)") shows the red control, Blocked badge, and reason; complete items are struck through; system tags + owner avatars render.
- Sidebar: Checklist progress **71% / 32 of 45**; Task Progress by Category tiles (Property Set up 7/7, etc.).

<!-- END PHASE 2 -->

---

## Self-Review

**Spec coverage** — every spec section maps to a task:
- §3.1 `Onboarding__c` object + fields → Task 1. §3.2 Task fields → Task 2. App/tab → Task 3. Perm set + FLS → Task 4 (+ T5/T14/T16/T12 edits). `Property_Asset__c` lookup + formulas → Task 1.
- §4.1 Screen 1 LWCs (kpis, propertyList, portfolioProgress, riskAlerts, timeSla) → Tasks 7–11; App Page → Task 12. "Not built" (categoryBars/trend/ownerLoad) → correctly absent.
- §4.2 Screen 2: highlights compact layout → Task 1; Path → Task 13; `onboardingChecklist` → Task 17; sidebar (`onboardingChecklistProgress`, `onboardingTaskProgressByCategory`) → Task 18; record page → Task 19. Critical Dates → correctly absent.
- §5 Apex: dashboard methods → Task 5; `getChecklist` → Task 16; `OnboardingTaskRollupService` → Task 14. §7 Seed → Tasks 6 + 15. §8 tokens → applied in LWC CSS/JS. §9 gotchas → Global Constraints + FLS in perm set + Path-enable note (Task 13).

**Placeholder scan** — no "TBD/TODO"; every code step has complete content. The one self-correction (Task 14 test `Tasks_Overdue__c` literal) is called out explicitly with the corrected value (1).

**Type consistency** — Apex DTO names/fields (`Kpis`, `Row`, `Portfolio`, `RiskAlerts`, `TimeSla`, `ChecklistGroup{category,total,complete,items}`, `ChecklistItem{id,name,status,system,owner,due,reason,hasNotes,overdue}`) match the LWC getters that consume them. Apex method names (`getKpis/getOnboardings/getPortfolio/getRiskAlerts/getTimeSla/getChecklist`, `OnboardingTaskRollupService.recalc`) are identical across producer and consumer tasks. Field API names match between object (Task 1), perm set (Task 4), seed (Tasks 6/15), controller SOQL (Tasks 5/16), and rollup (Task 14).

