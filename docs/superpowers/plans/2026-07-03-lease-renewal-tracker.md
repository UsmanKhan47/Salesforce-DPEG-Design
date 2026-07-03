# Lease Renewal Tracker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native Lease Renewal Tracker module in the Property Management app: `Lease_Renewal__c` pipeline with Kanban/Path/highlights, append-only timeline, non-responsive flags, native rate-approval process, app-home page, and dashboard.

**Architecture:** Two custom objects (`Lease_Renewal__c` + MD child `Renewal_Activity__c`) with formula-driven health flags; native chrome (Kanban list view, pathAssistant, compact-layout highlights, detail panel, approval process); custom LWCs only for the timeline composer and app-home widgets, all backed by one Apex controller. Mirrors the Lease Activity Tracker module's structure file-for-file.

**Tech Stack:** Salesforce DX (`sf` CLI on Windows PowerShell), Apex, LWC, metadata XML. Org: scratch org `test-3iuncy5c1je5@example.com` (default).

**Spec:** `docs/superpowers/specs/2026-07-03-lease-renewal-tracker-design.md`

## Global Constraints

- Branch: `feature/lease-renewal-tracker`. Commit + push after every task. Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Run `Set-Location F:\Acquisition-Design-Salesforce` before EVERY `sf` command (PowerShell CWD drifts). Never append `2>&1` to `sf` commands. Add `-c` to deploys if a spurious `SourceConflictError` appears (verify the org copy first only if the file was org-edited; these objects are new).
- Stage picklist (exact 9 values, this order): `Not Yet Started` (default), `Notice Sent`, `Awaiting Tenant Response`, `Negotiating`, `Escalated for Approval`, `Amendment Drafted`, `Renewed`, `Not Renewing`, `Vacating`.
- Approval_Status picklist: `N/A` (default), `Pending`, `Approved`, `Rejected`.
- Non-responsive threshold is **14 days**, hardcoded ONLY in `Non_Responsive__c` formula.
- Stage accents (LWC pills): Not Yet Started `#7A9ED4`, Notice Sent `#4A71B8`, Awaiting Tenant Response `#C88010`, Negotiating `#B8651A`, Escalated for Approval `#1A3464`, Amendment Drafted `#A88020`, Renewed `#198A40`, Not Renewing `#8A8680`, Vacating `#6B6862`.
- Method badge colors: Call `#1A4880`/`#EBF3FC`, Email `#7A4A00`/`#FDF5E6`, Visit `#4A2A7A`/`#F3EEFB`, Note `#132850`/`#E8EFF7`, System `#5A5752`/`#EDEBE7`.
- KPI icon colors (light suite standard): Active `#7A9ED4`, Expiring `#D8BE72`, Non-Responsive `#E58A8A`, Renewed (YTD) `#8FCBAA`.
- `Stage__c` and `Status__c` metadata `<required>false</required>` and NOT on the page layout (auto-inject gotcha); grant FLS in perm set.
- Required fields (`Tenant_Name__c`, `Lease_End__c`) get NO `fieldPermissions` entries (deploy rejects FLS on required fields).
- Flexipages: exactly ONE `<componentInstance>` per `<itemInstances>`.
- Approval History on the record page = `force:relatedListSingleContainer` with `relatedListApiName=ProcessSteps` (all other tokens fail).
- Approval step needs `<whenMultipleApprovers>FirstResponse</whenMultipleApprovers>` even with one approver.
- Native Submit-for-Approval never renders in Lightning — use the headless-LWC quick action pattern.
- Apex tests: never assert timestamp ORDER between rows created in the same test (frozen clock); order queries `Entry_Date__c DESC NULLS LAST, Name DESC` and assert on content.
- Reports: `reportType` is `CustomEntity$Lease_Renewal__c`; report columns prefixed `Lease_Renewal__c.`; dashboard bar `componentType` is `Bar` (not HorizontalBar) with `<chartAxisRange>Auto</chartAxisRange>`.

## File Structure

```
force-app/main/default/
  objects/Lease_Renewal__c/            # object + 22 fields + compact layout + 4 list views (Task 1)
  objects/Renewal_Activity__c/         # MD child + 3 fields (Task 1)
  flows/Lease_Renewal_Status_Sync.flow-meta.xml            (Task 2)
  workflows/Lease_Renewal__c.workflow-meta.xml             (Task 3: 5 field updates)
  approvalProcesses/Lease_Renewal__c.Renewal_Rate_Approval.approvalProcess-meta.xml (Task 3)
  classes/LeaseRenewalController.cls(+meta)                (Task 4)
  classes/LeaseRenewalControllerTest.cls(+meta)            (Task 4)
  quickActions/Lease_Renewal__c.Submit_for_Approval.quickAction-meta.xml (Task 5)
  lwc/renewalSubmitForApproval/        # headless quick action (Task 5)
  layouts/Lease_Renewal__c-Lease Renewal Layout.layout-meta.xml (Task 5)
  pathAssistants/Lease_Renewal_Path.pathAssistant-meta.xml (Task 5)
  lwc/renewalTimeline/                 # record-page timeline (Task 6)
  flexipages/Lease_Renewal_Record_Page.flexipage-meta.xml  (Task 6)
  lwc/renewalKpis/ lwc/renewalList/ lwc/renewalNeedsApproval/ lwc/renewalAttention/ (Task 7)
  flexipages/Lease_Renewals_Home.flexipage-meta.xml        (Task 8)
  tabs/Lease_Renewals.tab-meta.xml  tabs/Lease_Renewal__c.tab-meta.xml (Task 8)
  applications/Property_Management.app-meta.xml            (modified Tasks 6+8)
  permissionsets/Property_Management_Access.permissionset-meta.xml (modified Tasks 1,4,8)
  reports/Leasing/  dashboards/Leasing/                    (Task 9)
scripts/seed-lease-renewals.apex                           (Task 10)
```

---

### Task 1: Objects, fields, list views, compact layout, perm set FLS

**Files:**
- Create: `force-app/main/default/objects/Lease_Renewal__c/Lease_Renewal__c.object-meta.xml`
- Create: `force-app/main/default/objects/Lease_Renewal__c/fields/*.field-meta.xml` (22 files below)
- Create: `force-app/main/default/objects/Lease_Renewal__c/compactLayouts/Lease_Renewal_Compact.compactLayout-meta.xml`
- Create: `force-app/main/default/objects/Lease_Renewal__c/listViews/{All,Renewal_Pipeline,Non_Responsive,Expiring_90_Days}.listView-meta.xml`
- Create: `force-app/main/default/objects/Renewal_Activity__c/Renewal_Activity__c.object-meta.xml`
- Create: `force-app/main/default/objects/Renewal_Activity__c/fields/{Lease_Renewal__c,Method__c,Details__c,Entry_Date__c}.field-meta.xml`
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Produces: object/field API names exactly as written here; every later task depends on them verbatim.

- [ ] **Step 1: Write `Lease_Renewal__c` object + compact layout**

`objects/Lease_Renewal__c/Lease_Renewal__c.object-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <compactLayoutAssignment>Lease_Renewal_Compact</compactLayoutAssignment>
    <deploymentStatus>Deployed</deploymentStatus>
    <description>One lease renewal conversation, from Yardi-flagged expiry to signed amendment or lost tenant. Records are never deleted; closing changes Status.</description>
    <enableActivities>false</enableActivities>
    <enableHistory>true</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <label>Lease Renewal</label>
    <pluralLabel>Lease Renewals</pluralLabel>
    <nameField>
        <displayFormat>LR-{0000}</displayFormat>
        <label>Renewal Number</label>
        <type>AutoNumber</type>
    </nameField>
    <sharingModel>ReadWrite</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
```

`objects/Lease_Renewal__c/compactLayouts/Lease_Renewal_Compact.compactLayout-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CompactLayout xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Lease_Renewal_Compact</fullName>
    <fields>Tenant_Name__c</fields>
    <fields>Stage__c</fields>
    <fields>Lease_End__c</fields>
    <fields>Days_To_Expiry__c</fields>
    <fields>Approval_Status__c</fields>
    <label>Lease Renewal Compact</label>
</CompactLayout>
```

- [ ] **Step 2: Write the 22 `Lease_Renewal__c` fields**

Each file at `objects/Lease_Renewal__c/fields/<FullName>.field-meta.xml`. All share the wrapper:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    ...body...
</CustomField>
```
Bodies (write each as its own complete file with the wrapper above):

`Tenant_Name__c`:
```xml
    <fullName>Tenant_Name__c</fullName>
    <label>Tenant</label>
    <length>120</length>
    <required>true</required>
    <type>Text</type>
    <unique>false</unique>
```
`Property_Asset__c` (required on LAYOUT only, like Lease Inquiry):
```xml
    <fullName>Property_Asset__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <label>Property</label>
    <referenceTo>Property_Asset__c</referenceTo>
    <relationshipLabel>Lease Renewals</relationshipLabel>
    <relationshipName>Lease_Renewals</relationshipName>
    <required>false</required>
    <type>Lookup</type>
```
`Property_Display_Name__c`:
```xml
    <fullName>Property_Display_Name__c</fullName>
    <description>Property name spanned from the linked Property Asset for lists and reports.</description>
    <formula>Property_Asset__r.Name</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <label>Property Name</label>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
```
`Unit__c`:
```xml
    <fullName>Unit__c</fullName>
    <label>Unit</label>
    <length>60</length>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
```
`Space_Sq_Ft__c`:
```xml
    <fullName>Space_Sq_Ft__c</fullName>
    <label>Space (Sq Ft)</label>
    <precision>9</precision>
    <required>false</required>
    <scale>0</scale>
    <type>Number</type>
    <unique>false</unique>
```
`Lease_Start__c`:
```xml
    <fullName>Lease_Start__c</fullName>
    <label>Lease Start</label>
    <required>false</required>
    <type>Date</type>
```
`Lease_End__c`:
```xml
    <fullName>Lease_End__c</fullName>
    <label>Lease End</label>
    <required>true</required>
    <type>Date</type>
```
`Current_Rent__c`:
```xml
    <fullName>Current_Rent__c</fullName>
    <description>Display-fidelity current rate from Yardi, e.g. "$26.00 / sq ft NNN".</description>
    <label>Current Rent</label>
    <length>80</length>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
```
`Renewal_Option__c`:
```xml
    <fullName>Renewal_Option__c</fullName>
    <defaultValue>false</defaultValue>
    <description>A pre-set renewal option exists on the lease. When false, a new rate needs approval.</description>
    <label>Renewal Option Exists</label>
    <type>Checkbox</type>
```
`Preset_Terms__c`:
```xml
    <fullName>Preset_Terms__c</fullName>
    <label>Pre-Set Renewal Terms</label>
    <length>255</length>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
```
`Proposed_Rate__c`:
```xml
    <fullName>Proposed_Rate__c</fullName>
    <description>Proposed renewal rate in $ per sq ft.</description>
    <label>Proposed Rate ($/Sq Ft)</label>
    <precision>6</precision>
    <required>false</required>
    <scale>2</scale>
    <type>Number</type>
    <unique>false</unique>
```
`Option_Honored__c`:
```xml
    <fullName>Option_Honored__c</fullName>
    <defaultValue>false</defaultValue>
    <label>Renewal Option Honored</label>
    <type>Checkbox</type>
```
`Approval_Status__c`:
```xml
    <fullName>Approval_Status__c</fullName>
    <description>Owner sign-off on the proposed rate. Managed by the Renewal Rate Approval process.</description>
    <label>Approval Status</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>N/A</fullName><default>true</default><label>N/A</label></value>
            <value><fullName>Pending</fullName><default>false</default><label>Pending</label></value>
            <value><fullName>Approved</fullName><default>false</default><label>Approved</label></value>
            <value><fullName>Rejected</fullName><default>false</default><label>Rejected</label></value>
        </valueSetDefinition>
    </valueSet>
```
`Stage__c`:
```xml
    <fullName>Stage__c</fullName>
    <label>Stage</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Not Yet Started</fullName><default>true</default><label>Not Yet Started</label></value>
            <value><fullName>Notice Sent</fullName><default>false</default><label>Notice Sent</label></value>
            <value><fullName>Awaiting Tenant Response</fullName><default>false</default><label>Awaiting Tenant Response</label></value>
            <value><fullName>Negotiating</fullName><default>false</default><label>Negotiating</label></value>
            <value><fullName>Escalated for Approval</fullName><default>false</default><label>Escalated for Approval</label></value>
            <value><fullName>Amendment Drafted</fullName><default>false</default><label>Amendment Drafted</label></value>
            <value><fullName>Renewed</fullName><default>false</default><label>Renewed</label></value>
            <value><fullName>Not Renewing</fullName><default>false</default><label>Not Renewing</label></value>
            <value><fullName>Vacating</fullName><default>false</default><label>Vacating</label></value>
        </valueSetDefinition>
    </valueSet>
```
`Status__c`:
```xml
    <fullName>Status__c</fullName>
    <label>Status</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Active</fullName><default>true</default><label>Active</label></value>
            <value><fullName>Closed Won</fullName><default>false</default><label>Closed Won</label></value>
            <value><fullName>Closed Lost</fullName><default>false</default><label>Closed Lost</label></value>
        </valueSetDefinition>
    </valueSet>
```
`Handling_Person__c`:
```xml
    <fullName>Handling_Person__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <label>Handling Person</label>
    <referenceTo>User</referenceTo>
    <relationshipName>Handled_Lease_Renewals</relationshipName>
    <required>false</required>
    <type>Lookup</type>
```
`Last_Contact_Date__c`:
```xml
    <fullName>Last_Contact_Date__c</fullName>
    <description>Date of the last tenant contact. Stamped by LeaseRenewalController.addUpdate for non-System methods.</description>
    <label>Last Contact</label>
    <required>false</required>
    <type>Date</type>
```
`Renewed_Date__c`:
```xml
    <fullName>Renewed_Date__c</fullName>
    <description>Stamped by the status-sync flow when Stage first becomes Renewed. Powers the Renewed (YTD) KPI.</description>
    <label>Renewed Date</label>
    <required>false</required>
    <type>Date</type>
```
`Days_To_Expiry__c`:
```xml
    <fullName>Days_To_Expiry__c</fullName>
    <formula>Lease_End__c - TODAY()</formula>
    <formulaTreatBlanksAs>BlankAsBlanks</formulaTreatBlanksAs>
    <label>Days to Expiry</label>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>
    <type>Number</type>
    <unique>false</unique>
```
`Days_Since_Contact__c`:
```xml
    <fullName>Days_Since_Contact__c</fullName>
    <formula>TODAY() - Last_Contact_Date__c</formula>
    <formulaTreatBlanksAs>BlankAsBlanks</formulaTreatBlanksAs>
    <label>Days Since Contact</label>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>
    <type>Number</type>
    <unique>false</unique>
```
`Expiry_Health__c`:
```xml
    <fullName>Expiry_Health__c</fullName>
    <description>Expiry urgency signal for Kanban cards and list views. Red at 30 days, amber at 90.</description>
    <formula>IF(NOT(ISPICKVAL(Status__c, "Active")), "—", IF((Lease_End__c - TODAY()) &lt;= 30, "🔴 Critical", IF((Lease_End__c - TODAY()) &lt;= 90, "🟡 Approaching", "🟢 Comfortable")))</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <label>Expiry Health</label>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
```
`Non_Responsive__c` (the ONLY place the 14-day threshold lives):
```xml
    <fullName>Non_Responsive__c</fullName>
    <description>Tenant has gone quiet: active, in an outreach stage, and more than 14 days since last contact. The 14-day threshold is a working assumption — change it here only.</description>
    <formula>AND(ISPICKVAL(Status__c, "Active"), OR(ISPICKVAL(Stage__c, "Notice Sent"), ISPICKVAL(Stage__c, "Awaiting Tenant Response"), ISPICKVAL(Stage__c, "Negotiating"), ISPICKVAL(Stage__c, "Escalated for Approval")), NOT(ISBLANK(Last_Contact_Date__c)), (TODAY() - Last_Contact_Date__c) &gt; 14)</formula>
    <label>Non-Responsive</label>
    <type>Checkbox</type>
```

- [ ] **Step 3: Write the 4 list views**

`objects/Lease_Renewal__c/listViews/All.listView-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>All</fullName>
    <columns>NAME</columns>
    <columns>Tenant_Name__c</columns>
    <columns>Property_Display_Name__c</columns>
    <columns>Unit__c</columns>
    <columns>Lease_End__c</columns>
    <columns>Days_To_Expiry__c</columns>
    <columns>Expiry_Health__c</columns>
    <columns>Stage__c</columns>
    <columns>Approval_Status__c</columns>
    <columns>Status__c</columns>
    <filterScope>Everything</filterScope>
    <label>All Renewals</label>
</ListView>
```
`Renewal_Pipeline.listView-meta.xml` (the board — user switches Display As → Kanban, grouped by Stage; that toggle is UI-side, not metadata):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Renewal_Pipeline</fullName>
    <columns>NAME</columns>
    <columns>Tenant_Name__c</columns>
    <columns>Property_Display_Name__c</columns>
    <columns>Lease_End__c</columns>
    <columns>Days_To_Expiry__c</columns>
    <columns>Expiry_Health__c</columns>
    <columns>Non_Responsive__c</columns>
    <columns>Stage__c</columns>
    <filterScope>Everything</filterScope>
    <label>Renewal Pipeline</label>
</ListView>
```
`Non_Responsive.listView-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Non_Responsive</fullName>
    <columns>NAME</columns>
    <columns>Tenant_Name__c</columns>
    <columns>Property_Display_Name__c</columns>
    <columns>Days_Since_Contact__c</columns>
    <columns>Last_Contact_Date__c</columns>
    <columns>Stage__c</columns>
    <columns>Lease_End__c</columns>
    <filters>
        <field>Non_Responsive__c</field>
        <operation>equals</operation>
        <value>1</value>
    </filters>
    <filterScope>Everything</filterScope>
    <label>Non-Responsive</label>
</ListView>
```
`Expiring_90_Days.listView-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Expiring_90_Days</fullName>
    <columns>NAME</columns>
    <columns>Tenant_Name__c</columns>
    <columns>Property_Display_Name__c</columns>
    <columns>Lease_End__c</columns>
    <columns>Days_To_Expiry__c</columns>
    <columns>Expiry_Health__c</columns>
    <columns>Stage__c</columns>
    <filters>
        <field>Status__c</field>
        <operation>equals</operation>
        <value>Active</value>
    </filters>
    <filters>
        <field>Days_To_Expiry__c</field>
        <operation>lessOrEqual</operation>
        <value>90</value>
    </filters>
    <filterScope>Everything</filterScope>
    <label>Expiring ≤ 90 Days</label>
</ListView>
```

- [ ] **Step 4: Write `Renewal_Activity__c` object + fields**

`objects/Renewal_Activity__c/Renewal_Activity__c.object-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <deploymentStatus>Deployed</deploymentStatus>
    <description>Append-only timeline entry on a Lease Renewal. Never edited or deleted.</description>
    <enableActivities>false</enableActivities>
    <enableHistory>false</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <label>Renewal Activity</label>
    <pluralLabel>Renewal Activities</pluralLabel>
    <nameField>
        <displayFormat>RA-{0000}</displayFormat>
        <label>Activity Number</label>
        <type>AutoNumber</type>
    </nameField>
    <sharingModel>ControlledByParent</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
```
Fields (same `<CustomField>` wrapper):

`Lease_Renewal__c`:
```xml
    <fullName>Lease_Renewal__c</fullName>
    <label>Lease Renewal</label>
    <referenceTo>Lease_Renewal__c</referenceTo>
    <relationshipLabel>Renewal Activities</relationshipLabel>
    <relationshipName>Renewal_Activities</relationshipName>
    <relationshipOrder>0</relationshipOrder>
    <reparentableMasterDetail>false</reparentableMasterDetail>
    <type>MasterDetail</type>
    <writeRequiresMasterRead>false</writeRequiresMasterRead>
```
`Method__c`:
```xml
    <fullName>Method__c</fullName>
    <label>Method</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Call</fullName><default>true</default><label>Call</label></value>
            <value><fullName>Email</fullName><default>false</default><label>Email</label></value>
            <value><fullName>Visit</fullName><default>false</default><label>Visit</label></value>
            <value><fullName>Note</fullName><default>false</default><label>Note</label></value>
            <value><fullName>System</fullName><default>false</default><label>System</label></value>
        </valueSetDefinition>
    </valueSet>
```
`Details__c`:
```xml
    <fullName>Details__c</fullName>
    <label>Details</label>
    <length>32768</length>
    <type>LongTextArea</type>
    <visibleLines>3</visibleLines>
```
`Entry_Date__c`:
```xml
    <fullName>Entry_Date__c</fullName>
    <label>Entry Date</label>
    <required>false</required>
    <type>DateTime</type>
```

- [ ] **Step 5: Add object perms + FLS to the perm set**

In `permissionsets/Property_Management_Access.permissionset-meta.xml`, insert alphabetically-consistent blocks alongside the existing Lease_Inquiry__c entries (keep the file's existing element ordering: classAccesses…fieldPermissions…objectPermissions…tabSettings):

Two `objectPermissions` blocks:
```xml
    <objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>true</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Lease_Renewal__c</object>
        <viewAllRecords>true</viewAllRecords>
    </objectPermissions>
    <objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>true</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Renewal_Activity__c</object>
        <viewAllRecords>true</viewAllRecords>
    </objectPermissions>
```
`fieldPermissions` (editable=true, readable=true) for every NON-required, NON-formula, NON-MD field:
`Lease_Renewal__c.Property_Asset__c`, `Unit__c`, `Space_Sq_Ft__c`, `Lease_Start__c`, `Current_Rent__c`, `Renewal_Option__c`, `Preset_Terms__c`, `Proposed_Rate__c`, `Option_Honored__c`, `Approval_Status__c`, `Stage__c`, `Status__c`, `Handling_Person__c`, `Last_Contact_Date__c`, `Renewed_Date__c`; and `Renewal_Activity__c.Method__c`, `Details__c`, `Entry_Date__c`.
Formula fields get readable-only blocks (`editable=false`): `Property_Display_Name__c`, `Days_To_Expiry__c`, `Days_Since_Contact__c`, `Expiry_Health__c`, `Non_Responsive__c`. Pattern:
```xml
    <fieldPermissions>
        <editable>true</editable>
        <field>Lease_Renewal__c.Stage__c</field>
        <readable>true</readable>
    </fieldPermissions>
```
Do NOT add `Tenant_Name__c`, `Lease_End__c` (required) or `Renewal_Activity__c.Lease_Renewal__c` (MD).

- [ ] **Step 6: Deploy and verify**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/objects/Lease_Renewal__c -d force-app/main/default/objects/Renewal_Activity__c -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml --json
```
Expected: `"status": "Succeeded"`. Then smoke-test in anonymous Apex (write to a scratch file, run `sf apex run -f <file> --json`):
```apex
Property__c pr = new Property__c(Name='Plan Verify Prop', Address__c='1 Test', City__c='Houston', State__c='TX', Square_Footage__c=10000, Asset_Type__c='Retail');
insert pr;
Property_Asset__c pa = new Property_Asset__c(Name='Plan Verify Asset', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active');
insert pa;
Lease_Renewal__c r = new Lease_Renewal__c(Tenant_Name__c='Smoke Tenant', Property_Asset__c=pa.Id, Lease_End__c=Date.today().addDays(20), Last_Contact_Date__c=Date.today().addDays(-20), Stage__c='Notice Sent');
insert r;
r = [SELECT Days_To_Expiry__c, Expiry_Health__c, Non_Responsive__c, Status__c FROM Lease_Renewal__c WHERE Id=:r.Id];
System.assertEquals(20, r.Days_To_Expiry__c);
System.assert(r.Expiry_Health__c.contains('Critical'));
System.assertEquals(true, r.Non_Responsive__c);
insert new Renewal_Activity__c(Lease_Renewal__c=r.Id, Method__c='Call', Details__c='smoke', Entry_Date__c=Datetime.now());
delete r; delete pa; delete pr;  // MD child cascades
System.debug('SMOKE OK');
```
Expected: success, `SMOKE OK` in log.

- [ ] **Step 7: Commit and push**

```powershell
git add force-app/main/default/objects/Lease_Renewal__c force-app/main/default/objects/Renewal_Activity__c force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "Lease Renewal Tracker: Lease_Renewal__c + Renewal_Activity__c objects, list views, FLS" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 2: Status-sync flow

**Files:**
- Create: `force-app/main/default/flows/Lease_Renewal_Status_Sync.flow-meta.xml`

**Interfaces:**
- Consumes: `Lease_Renewal__c.Stage__c/Status__c/Renewed_Date__c` (Task 1).
- Produces: guarantee used by Task 4 tests and Task 10 seed — setting Stage to a terminal value auto-sets Status (+ stamps `Renewed_Date__c` once for Renewed).

- [ ] **Step 1: Write the flow**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Flow xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <assignments>
        <name>Set_Closed_Won</name>
        <label>Set Closed Won</label>
        <locationX>50</locationX>
        <locationY>288</locationY>
        <assignmentItems>
            <assignToReference>$Record.Status__c</assignToReference>
            <operator>Assign</operator>
            <value><stringValue>Closed Won</stringValue></value>
        </assignmentItems>
        <connector><targetReference>Needs_Renewed_Date</targetReference></connector>
    </assignments>
    <assignments>
        <name>Stamp_Renewed_Date</name>
        <label>Stamp Renewed Date</label>
        <locationX>50</locationX>
        <locationY>504</locationY>
        <assignmentItems>
            <assignToReference>$Record.Renewed_Date__c</assignToReference>
            <operator>Assign</operator>
            <value><elementReference>$Flow.CurrentDate</elementReference></value>
        </assignmentItems>
    </assignments>
    <assignments>
        <name>Set_Closed_Lost</name>
        <label>Set Closed Lost</label>
        <locationX>314</locationX>
        <locationY>288</locationY>
        <assignmentItems>
            <assignToReference>$Record.Status__c</assignToReference>
            <operator>Assign</operator>
            <value><stringValue>Closed Lost</stringValue></value>
        </assignmentItems>
    </assignments>
    <decisions>
        <name>Terminal_Stage</name>
        <label>Terminal Stage?</label>
        <locationX>182</locationX>
        <locationY>180</locationY>
        <defaultConnectorLabel>Still in flight</defaultConnectorLabel>
        <rules>
            <name>Is_Renewed</name>
            <conditionLogic>and</conditionLogic>
            <conditions>
                <leftValueReference>$Record.Stage__c</leftValueReference>
                <operator>EqualTo</operator>
                <rightValue><stringValue>Renewed</stringValue></rightValue>
            </conditions>
            <connector><targetReference>Set_Closed_Won</targetReference></connector>
            <label>Renewed</label>
        </rules>
        <rules>
            <name>Is_Lost</name>
            <conditionLogic>or</conditionLogic>
            <conditions>
                <leftValueReference>$Record.Stage__c</leftValueReference>
                <operator>EqualTo</operator>
                <rightValue><stringValue>Not Renewing</stringValue></rightValue>
            </conditions>
            <conditions>
                <leftValueReference>$Record.Stage__c</leftValueReference>
                <operator>EqualTo</operator>
                <rightValue><stringValue>Vacating</stringValue></rightValue>
            </conditions>
            <connector><targetReference>Set_Closed_Lost</targetReference></connector>
            <label>Not Renewing / Vacating</label>
        </rules>
    </decisions>
    <decisions>
        <name>Needs_Renewed_Date</name>
        <label>Needs Renewed Date?</label>
        <locationX>50</locationX>
        <locationY>396</locationY>
        <defaultConnectorLabel>Already stamped</defaultConnectorLabel>
        <rules>
            <name>Stamp</name>
            <conditionLogic>and</conditionLogic>
            <conditions>
                <leftValueReference>$Record.Renewed_Date__c</leftValueReference>
                <operator>IsNull</operator>
                <rightValue><booleanValue>true</booleanValue></rightValue>
            </conditions>
            <connector><targetReference>Stamp_Renewed_Date</targetReference></connector>
            <label>Stamp</label>
        </rules>
    </decisions>
    <environments>Default</environments>
    <interviewLabel>Lease Renewal Status Sync {!$Flow.CurrentDateTime}</interviewLabel>
    <label>Lease Renewal Status Sync</label>
    <processType>AutoLaunchedFlow</processType>
    <start>
        <locationX>56</locationX>
        <locationY>0</locationY>
        <connector><targetReference>Terminal_Stage</targetReference></connector>
        <object>Lease_Renewal__c</object>
        <recordTriggerType>CreateAndUpdate</recordTriggerType>
        <triggerType>RecordBeforeSave</triggerType>
    </start>
    <status>Active</status>
</Flow>
```

- [ ] **Step 2: Deploy**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/flows/Lease_Renewal_Status_Sync.flow-meta.xml --json
```
Expected: Succeeded.

- [ ] **Step 3: Verify with anonymous Apex**

Write to a scratchpad file and run `sf apex run -f <file> --json`:
```apex
Property__c pr = new Property__c(Name='Flow Verify Prop', Address__c='1 Test', City__c='Houston', State__c='TX', Square_Footage__c=10000, Asset_Type__c='Retail');
insert pr;
Property_Asset__c pa = new Property_Asset__c(Name='Flow Verify Asset', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active');
insert pa;
Lease_Renewal__c r = new Lease_Renewal__c(Tenant_Name__c='Flow Tenant', Property_Asset__c=pa.Id, Lease_End__c=Date.today().addDays(60));
insert r;
r.Stage__c = 'Renewed'; update r;
r = [SELECT Status__c, Renewed_Date__c FROM Lease_Renewal__c WHERE Id=:r.Id];
System.assertEquals('Closed Won', r.Status__c);
System.assertEquals(Date.today(), r.Renewed_Date__c);
Lease_Renewal__c r2 = new Lease_Renewal__c(Tenant_Name__c='Flow Tenant 2', Property_Asset__c=pa.Id, Lease_End__c=Date.today().addDays(60), Stage__c='Vacating');
insert r2;
r2 = [SELECT Status__c FROM Lease_Renewal__c WHERE Id=:r2.Id];
System.assertEquals('Closed Lost', r2.Status__c);
delete r; delete r2; delete pa; delete pr;
System.debug('FLOW OK');
```
Expected: `FLOW OK`.

- [ ] **Step 4: Commit and push**

```powershell
git add force-app/main/default/flows/Lease_Renewal_Status_Sync.flow-meta.xml
git commit -m "Lease Renewal Tracker: stage-to-status sync flow with Renewed_Date stamp" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 3: Renewal Rate Approval process

**Files:**
- Create: `force-app/main/default/workflows/Lease_Renewal__c.workflow-meta.xml`
- Create: `force-app/main/default/approvalProcesses/Lease_Renewal__c.Renewal_Rate_Approval.approvalProcess-meta.xml`

**Interfaces:**
- Consumes: `Approval_Status__c`, `Stage__c`, `Status__c` (Task 1).
- Produces: active approval process `Renewal_Rate_Approval`; submit → Stage=`Escalated for Approval` + Approval_Status=`Pending`; approve → `Approved` + Stage=`Negotiating`; reject → `Rejected` + Stage=`Negotiating`. Task 4's `submitForApproval` and tests depend on these exact transitions.

- [ ] **Step 1: Write the field updates**

`workflows/Lease_Renewal__c.workflow-meta.xml` (5 updates; `Set_Stage_Negotiating` is shared by approve + reject):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workflow xmlns="http://soap.sforce.com/2006/04/metadata">
    <fieldUpdates>
        <fullName>Set_Stage_Escalated</fullName>
        <field>Stage__c</field>
        <literalValue>Escalated for Approval</literalValue>
        <name>Set Stage Escalated</name>
        <notifyAssignee>false</notifyAssignee>
        <operation>Literal</operation>
        <protected>false</protected>
        <reevaluateOnChange>false</reevaluateOnChange>
    </fieldUpdates>
    <fieldUpdates>
        <fullName>Set_Approval_Pending</fullName>
        <field>Approval_Status__c</field>
        <literalValue>Pending</literalValue>
        <name>Set Approval Pending</name>
        <notifyAssignee>false</notifyAssignee>
        <operation>Literal</operation>
        <protected>false</protected>
        <reevaluateOnChange>false</reevaluateOnChange>
    </fieldUpdates>
    <fieldUpdates>
        <fullName>Set_Approval_Approved</fullName>
        <field>Approval_Status__c</field>
        <literalValue>Approved</literalValue>
        <name>Set Approval Approved</name>
        <notifyAssignee>false</notifyAssignee>
        <operation>Literal</operation>
        <protected>false</protected>
        <reevaluateOnChange>false</reevaluateOnChange>
    </fieldUpdates>
    <fieldUpdates>
        <fullName>Set_Approval_Rejected</fullName>
        <field>Approval_Status__c</field>
        <literalValue>Rejected</literalValue>
        <name>Set Approval Rejected</name>
        <notifyAssignee>false</notifyAssignee>
        <operation>Literal</operation>
        <protected>false</protected>
        <reevaluateOnChange>false</reevaluateOnChange>
    </fieldUpdates>
    <fieldUpdates>
        <fullName>Set_Stage_Negotiating</fullName>
        <field>Stage__c</field>
        <literalValue>Negotiating</literalValue>
        <name>Set Stage Negotiating</name>
        <notifyAssignee>false</notifyAssignee>
        <operation>Literal</operation>
        <protected>false</protected>
        <reevaluateOnChange>false</reevaluateOnChange>
    </fieldUpdates>
</Workflow>
```

- [ ] **Step 2: Write the approval process**

`approvalProcesses/Lease_Renewal__c.Renewal_Rate_Approval.approvalProcess-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApprovalProcess xmlns="http://soap.sforce.com/2006/04/metadata">
    <active>true</active>
    <allowRecall>true</allowRecall>
    <allowedSubmitters>
        <type>owner</type>
    </allowedSubmitters>
    <approvalPageFields>
        <field>Name</field>
        <field>Tenant_Name__c</field>
        <field>Current_Rent__c</field>
        <field>Proposed_Rate__c</field>
        <field>Lease_End__c</field>
    </approvalPageFields>
    <approvalStep>
        <allowDelegate>false</allowDelegate>
        <assignedApprover>
            <approver>
                <name>test-3iuncy5c1je5@example.com</name>
                <type>user</type>
            </approver>
            <whenMultipleApprovers>FirstResponse</whenMultipleApprovers>
        </assignedApprover>
        <label>Rate Approval</label>
        <name>Rate_Approval_Step</name>
    </approvalStep>
    <enableMobileDeviceAccess>false</enableMobileDeviceAccess>
    <entryCriteria>
        <criteriaItems>
            <field>Lease_Renewal__c.Status__c</field>
            <operation>equals</operation>
            <value>Active</value>
        </criteriaItems>
    </entryCriteria>
    <finalApprovalActions>
        <action>
            <name>Set_Approval_Approved</name>
            <type>FieldUpdate</type>
        </action>
        <action>
            <name>Set_Stage_Negotiating</name>
            <type>FieldUpdate</type>
        </action>
    </finalApprovalActions>
    <finalApprovalRecordLock>false</finalApprovalRecordLock>
    <finalRejectionActions>
        <action>
            <name>Set_Approval_Rejected</name>
            <type>FieldUpdate</type>
        </action>
        <action>
            <name>Set_Stage_Negotiating</name>
            <type>FieldUpdate</type>
        </action>
    </finalRejectionActions>
    <finalRejectionRecordLock>false</finalRejectionRecordLock>
    <initialSubmissionActions>
        <action>
            <name>Set_Stage_Escalated</name>
            <type>FieldUpdate</type>
        </action>
        <action>
            <name>Set_Approval_Pending</name>
            <type>FieldUpdate</type>
        </action>
    </initialSubmissionActions>
    <label>Renewal Rate Approval</label>
    <processOrder>1</processOrder>
    <recordEditability>AdminOnly</recordEditability>
    <showApprovalHistory>true</showApprovalHistory>
</ApprovalProcess>
```

- [ ] **Step 3: Deploy (workflow + approval together)**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/workflows/Lease_Renewal__c.workflow-meta.xml -d force-app/main/default/approvalProcesses --json
```
Expected: Succeeded.

- [ ] **Step 4: Verify submit → approve via anonymous Apex**

```apex
Property__c pr = new Property__c(Name='Appr Verify Prop', Address__c='1 Test', City__c='Houston', State__c='TX', Square_Footage__c=10000, Asset_Type__c='Retail');
insert pr;
Property_Asset__c pa = new Property_Asset__c(Name='Appr Verify Asset', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active');
insert pa;
Lease_Renewal__c r = new Lease_Renewal__c(Tenant_Name__c='Appr Tenant', Property_Asset__c=pa.Id, Lease_End__c=Date.today().addDays(90), Stage__c='Negotiating', Proposed_Rate__c=24.00);
insert r;
Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
req.setObjectId(r.Id);
Approval.process(req);
r = [SELECT Stage__c, Approval_Status__c FROM Lease_Renewal__c WHERE Id=:r.Id];
System.assertEquals('Escalated for Approval', r.Stage__c);
System.assertEquals('Pending', r.Approval_Status__c);
Approval.ProcessWorkitemRequest wi = new Approval.ProcessWorkitemRequest();
wi.setWorkitemId([SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId=:r.Id LIMIT 1].Id);
wi.setAction('Approve');
Approval.process(wi);
r = [SELECT Stage__c, Approval_Status__c FROM Lease_Renewal__c WHERE Id=:r.Id];
System.assertEquals('Negotiating', r.Stage__c);
System.assertEquals('Approved', r.Approval_Status__c);
delete r; delete pa; delete pr;
System.debug('APPROVAL OK');
```
Expected: `APPROVAL OK` (self-approval works in this org — submitter==approver is allowed).

- [ ] **Step 5: Commit and push**

```powershell
git add force-app/main/default/workflows/Lease_Renewal__c.workflow-meta.xml force-app/main/default/approvalProcesses/Lease_Renewal__c.Renewal_Rate_Approval.approvalProcess-meta.xml
git commit -m "Lease Renewal Tracker: native Renewal Rate Approval process" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 4: LeaseRenewalController + tests

**Files:**
- Create: `force-app/main/default/classes/LeaseRenewalController.cls` + `.cls-meta.xml`
- Create: `force-app/main/default/classes/LeaseRenewalControllerTest.cls` + `.cls-meta.xml`
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml` (add classAccess)

**Interfaces:**
- Consumes: objects/fields (Task 1), status-sync flow (Task 2), approval process transitions (Task 3).
- Produces (LWCs in Tasks 5–7 import these exact names):
  - `getHomeKpis()` → `{active, expiring90, nonResponsive, renewedYtd}` (Integers)
  - `getRecentRenewals()` / `getNeedsApproval()` / `getAttention()` → `List<Row>`; Row = `{id, tenant, property, unit, leaseEnd(Date), daysToExpiry(Integer), stage, status, closed(Boolean), approvalStatus, lastContact(Date), daysSinceContact(Integer), nonResponsive(Boolean)}`
  - `getTimeline(Id renewalId)` → `{entries:[{id, method, details, enteredBy, entryDate(Datetime)}], stage, status, closed, nonResponsive, daysSinceContact, canLog}`
  - `addUpdate(Id renewalId, String method, String details)` → void
  - `submitForApproval(Id recordId)` → String

- [ ] **Step 1: Write the test class (TDD — this defines the contract)**

`classes/LeaseRenewalControllerTest.cls`:
```apex
@isTest
private class LeaseRenewalControllerTest {
    @testSetup static void setup() {
        Property__c pr = new Property__c(Name='Westgate Plaza', Address__c='8420 Westheimer Rd', City__c='Houston', State__c='TX', Square_Footage__c=42000, Asset_Type__c='Retail');
        insert pr;
        Property_Asset__c pa = new Property_Asset__c(Name='Westgate Plaza', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active');
        insert pa;
        Date t = Date.today();
        // r1 non-responsive + expiring<=90; r2 fresh no contact; r3 critical <=30d;
        // r4 Renewed (flow -> Closed Won + Renewed_Date); r5 Vacating (flow -> Closed Lost);
        // r6 pending approval, active.
        List<Lease_Renewal__c> rs = new List<Lease_Renewal__c>{
            new Lease_Renewal__c(Tenant_Name__c='Riverside Dental', Property_Asset__c=pa.Id, Unit__c='Suite 120', Lease_End__c=t.addDays(80), Stage__c='Awaiting Tenant Response', Last_Contact_Date__c=t.addDays(-20)),
            new Lease_Renewal__c(Tenant_Name__c='Pearl Nails', Property_Asset__c=pa.Id, Unit__c='Suite 3', Lease_End__c=t.addDays(150), Stage__c='Not Yet Started'),
            new Lease_Renewal__c(Tenant_Name__c='Golden Wok', Property_Asset__c=pa.Id, Unit__c='Unit 8', Lease_End__c=t.addDays(25), Stage__c='Negotiating', Last_Contact_Date__c=t.addDays(-3), Proposed_Rate__c=25.20),
            new Lease_Renewal__c(Tenant_Name__c='Anytime Fitness', Property_Asset__c=pa.Id, Unit__c='Anchor B', Lease_End__c=t.addDays(-2), Stage__c='Renewed'),
            new Lease_Renewal__c(Tenant_Name__c='Elite Barbers', Property_Asset__c=pa.Id, Unit__c='Suite 7', Lease_End__c=t.addDays(28), Stage__c='Vacating'),
            new Lease_Renewal__c(Tenant_Name__c='TechHub Coworking', Property_Asset__c=pa.Id, Unit__c='Floor 2', Lease_End__c=t.addDays(40), Stage__c='Escalated for Approval', Approval_Status__c='Pending', Last_Contact_Date__c=t.addDays(-7), Proposed_Rate__c=24.00)
        };
        insert rs;
        insert new List<Renewal_Activity__c>{
            new Renewal_Activity__c(Lease_Renewal__c=rs[0].Id, Method__c='System', Details__c='Lease flagged for renewal.', Entry_Date__c=Datetime.now().addDays(-30)),
            new Renewal_Activity__c(Lease_Renewal__c=rs[0].Id, Method__c='Email', Details__c='Sent renewal notice to tenant.', Entry_Date__c=Datetime.now().addDays(-20))
        };
    }
    private static Lease_Renewal__c byTenant(String t) {
        return [SELECT Id, Status__c, Stage__c, Approval_Status__c, Last_Contact_Date__c, Renewed_Date__c FROM Lease_Renewal__c WHERE Tenant_Name__c = :t LIMIT 1];
    }

    @isTest static void homeKpis() {
        LeaseRenewalController.HomeKpis k = LeaseRenewalController.getHomeKpis();
        System.assertEquals(4, k.active, 'r1, r2, r3, r6 are Active');
        System.assertEquals(3, k.expiring90, '80d, 25d, 40d actives are within 90');
        System.assertEquals(1, k.nonResponsive, 'only r1 is >14d silent in an outreach stage');
        System.assertEquals(1, k.renewedYtd, 'r4 stamped Renewed_Date today by the flow');
    }
    @isTest static void recentRenewalsCapsAtSix() {
        Property_Asset__c pa = [SELECT Id FROM Property_Asset__c LIMIT 1];
        List<Lease_Renewal__c> extra = new List<Lease_Renewal__c>();
        for (Integer i = 0; i < 3; i++) {
            extra.add(new Lease_Renewal__c(Tenant_Name__c='Extra ' + i, Property_Asset__c=pa.Id, Lease_End__c=Date.today().addDays(100 + i)));
        }
        insert extra;
        List<LeaseRenewalController.Row> rows = LeaseRenewalController.getRecentRenewals();
        System.assertEquals(6, rows.size(), 'capped at 6');
        System.assertEquals('Westgate Plaza', rows[0].property, 'property name spans from the asset');
    }
    @isTest static void needsApproval() {
        List<LeaseRenewalController.Row> rows = LeaseRenewalController.getNeedsApproval();
        System.assertEquals(1, rows.size());
        System.assertEquals('TechHub Coworking', rows[0].tenant);
        System.assertEquals('Pending', rows[0].approvalStatus);
    }
    @isTest static void attentionListsNonRespAndCritical() {
        List<LeaseRenewalController.Row> rows = LeaseRenewalController.getAttention();
        System.assertEquals(2, rows.size(), 'r1 non-responsive + r3 within 30d');
        System.assertEquals('Golden Wok', rows[0].tenant, 'sorted by lease end ascending (25d first)');
        System.assertEquals('Riverside Dental', rows[1].tenant);
        System.assertEquals(true, rows[1].nonResponsive);
    }
    @isTest static void timelineNewestFirstWithContext() {
        LeaseRenewalController.TimelineView v = LeaseRenewalController.getTimeline(byTenant('Riverside Dental').Id);
        System.assertEquals(2, v.entries.size());
        System.assertEquals('Email', v.entries[0].method, 'newest (by Entry_Date__c) first');
        System.assertEquals(true, v.canLog);
        System.assertEquals(true, v.nonResponsive);
        System.assertEquals(false, v.closed);
        System.assertEquals(20, v.daysSinceContact);
    }
    @isTest static void timelineClosedCannotLog() {
        LeaseRenewalController.TimelineView v = LeaseRenewalController.getTimeline(byTenant('Anytime Fitness').Id);
        System.assertEquals(false, v.canLog);
        System.assertEquals(true, v.closed);
    }
    @isTest static void addUpdateInsertsAndStampsContact() {
        Id rid = byTenant('Pearl Nails').Id;
        Test.startTest();
        LeaseRenewalController.addUpdate(rid, 'Call', 'Reached the owner; scheduling terms talk.');
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Renewal_Activity__c WHERE Lease_Renewal__c = :rid]);
        System.assertEquals(Date.today(), byTenant('Pearl Nails').Last_Contact_Date__c, 'non-System method stamps last contact');
    }
    @isTest static void addUpdateSystemDoesNotStamp() {
        Id rid = byTenant('Pearl Nails').Id;
        LeaseRenewalController.addUpdate(rid, 'System', 'Renewal window opened.');
        System.assertEquals(null, byTenant('Pearl Nails').Last_Contact_Date__c, 'System entries are not tenant contact');
    }
    @isTest static void addUpdateBlankDetailsThrows() {
        Id rid = byTenant('Pearl Nails').Id;
        Boolean threw = false;
        try { LeaseRenewalController.addUpdate(rid, 'Call', '   '); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw);
        System.assertEquals(0, [SELECT COUNT() FROM Renewal_Activity__c WHERE Lease_Renewal__c = :rid]);
    }
    @isTest static void addUpdateBadMethodThrows() {
        Boolean threw = false;
        try { LeaseRenewalController.addUpdate(byTenant('Pearl Nails').Id, 'Fax', 'nope'); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw);
    }
    @isTest static void statusSyncSetsClosedWonAndStampsOnce() {
        Property_Asset__c pa = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Lease_Renewal__c r = new Lease_Renewal__c(Tenant_Name__c='Stamp Once', Property_Asset__c=pa.Id, Lease_End__c=Date.today().addDays(10), Renewed_Date__c=Date.today().addDays(-30));
        insert r;
        r.Stage__c = 'Renewed'; update r;
        r = [SELECT Status__c, Renewed_Date__c FROM Lease_Renewal__c WHERE Id = :r.Id];
        System.assertEquals('Closed Won', r.Status__c);
        System.assertEquals(Date.today().addDays(-30), r.Renewed_Date__c, 'existing Renewed_Date is never overwritten');
    }
    @isTest static void statusSyncSetsClosedLost() {
        Lease_Renewal__c r = byTenant('Golden Wok');
        r.Stage__c = 'Not Renewing'; update r;
        System.assertEquals('Closed Lost', byTenant('Golden Wok').Status__c);
    }
    @isTest static void submitForApprovalEscalates() {
        Id rid = byTenant('Golden Wok').Id;
        Test.startTest();
        String msg = LeaseRenewalController.submitForApproval(rid);
        Test.stopTest();
        System.assert(msg != null && msg.length() > 0);
        Lease_Renewal__c r = byTenant('Golden Wok');
        System.assertEquals('Escalated for Approval', r.Stage__c);
        System.assertEquals('Pending', r.Approval_Status__c);
    }
    @isTest static void submitTwiceThrows() {
        Id rid = byTenant('Golden Wok').Id;
        LeaseRenewalController.submitForApproval(rid);
        Boolean threw = false;
        try { LeaseRenewalController.submitForApproval(rid); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'second submit while pending is blocked');
    }
    @isTest static void submitClosedThrows() {
        Boolean threw = false;
        try { LeaseRenewalController.submitForApproval(byTenant('Anytime Fitness').Id); } catch (AuraHandledException e) { threw = true; }
        System.assert(threw, 'closed renewals fail the entry criteria');
    }
}
```
`classes/LeaseRenewalControllerTest.cls-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Write the controller**

`classes/LeaseRenewalController.cls`:
```apex
/**
 * Backs the Lease Renewal Tracker: home-page widgets, the record-page timeline,
 * and the Submit-for-Approval quick action. Timeline entries are append-only.
 */
public with sharing class LeaseRenewalController {

    private static final Set<String> METHODS = new Set<String>{ 'Call', 'Email', 'Visit', 'Note', 'System' };
    private static final String ROW_QUERY =
        'SELECT Id, Tenant_Name__c, Property_Display_Name__c, Unit__c, Lease_End__c, Days_To_Expiry__c, ' +
        'Stage__c, Status__c, Approval_Status__c, Last_Contact_Date__c, Days_Since_Contact__c, Non_Responsive__c ' +
        'FROM Lease_Renewal__c ';

    public class HomeKpis {
        @AuraEnabled public Integer active;
        @AuraEnabled public Integer expiring90;
        @AuraEnabled public Integer nonResponsive;
        @AuraEnabled public Integer renewedYtd;
    }
    @AuraEnabled(cacheable=true)
    public static HomeKpis getHomeKpis() {
        HomeKpis k = new HomeKpis();
        k.active = 0; k.expiring90 = 0; k.nonResponsive = 0; k.renewedYtd = 0;
        Date yearStart = Date.newInstance(Date.today().year(), 1, 1);
        for (Lease_Renewal__c r : [SELECT Status__c, Days_To_Expiry__c, Non_Responsive__c, Renewed_Date__c FROM Lease_Renewal__c]) {
            if (r.Status__c == 'Active') {
                k.active++;
                if (r.Days_To_Expiry__c != null && r.Days_To_Expiry__c <= 90) k.expiring90++;
                if (r.Non_Responsive__c) k.nonResponsive++;
            }
            if (r.Renewed_Date__c != null && r.Renewed_Date__c >= yearStart) k.renewedYtd++;
        }
        return k;
    }

    public class Row {
        @AuraEnabled public Id id;
        @AuraEnabled public String tenant;
        @AuraEnabled public String property;
        @AuraEnabled public String unit;
        @AuraEnabled public Date leaseEnd;
        @AuraEnabled public Integer daysToExpiry;
        @AuraEnabled public String stage;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean closed;
        @AuraEnabled public String approvalStatus;
        @AuraEnabled public Date lastContact;
        @AuraEnabled public Integer daysSinceContact;
        @AuraEnabled public Boolean nonResponsive;
    }
    private static Row toRow(Lease_Renewal__c r) {
        Row w = new Row();
        w.id = r.Id; w.tenant = r.Tenant_Name__c; w.property = r.Property_Display_Name__c; w.unit = r.Unit__c;
        w.leaseEnd = r.Lease_End__c;
        w.daysToExpiry = r.Days_To_Expiry__c == null ? null : (Integer) r.Days_To_Expiry__c;
        w.stage = r.Stage__c; w.status = r.Status__c; w.closed = r.Status__c != 'Active';
        w.approvalStatus = r.Approval_Status__c;
        w.lastContact = r.Last_Contact_Date__c;
        w.daysSinceContact = r.Days_Since_Contact__c == null ? null : (Integer) r.Days_Since_Contact__c;
        w.nonResponsive = r.Non_Responsive__c == true;
        return w;
    }
    private static List<Row> toRows(List<Lease_Renewal__c> recs) {
        List<Row> out = new List<Row>();
        for (Lease_Renewal__c r : recs) out.add(toRow(r));
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Row> getRecentRenewals() {
        return toRows(Database.query(ROW_QUERY + 'ORDER BY CreatedDate DESC LIMIT 6'));
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getNeedsApproval() {
        return toRows(Database.query(ROW_QUERY +
            'WHERE Approval_Status__c = \'Pending\' AND Status__c = \'Active\' ORDER BY Lease_End__c ASC NULLS LAST'));
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getAttention() {
        return toRows(Database.query(ROW_QUERY +
            'WHERE Status__c = \'Active\' AND (Non_Responsive__c = true OR Days_To_Expiry__c <= 30) ORDER BY Lease_End__c ASC NULLS LAST'));
    }

    public class Entry {
        @AuraEnabled public Id id;
        @AuraEnabled public String method;
        @AuraEnabled public String details;
        @AuraEnabled public String enteredBy;
        @AuraEnabled public Datetime entryDate;
    }
    public class TimelineView {
        @AuraEnabled public List<Entry> entries;
        @AuraEnabled public String stage;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean closed;
        @AuraEnabled public Boolean nonResponsive;
        @AuraEnabled public Integer daysSinceContact;
        @AuraEnabled public Boolean canLog;
    }
    @AuraEnabled(cacheable=true)
    public static TimelineView getTimeline(Id renewalId) {
        Lease_Renewal__c r = [SELECT Stage__c, Status__c, Non_Responsive__c, Days_Since_Contact__c
                              FROM Lease_Renewal__c WHERE Id = :renewalId LIMIT 1];
        TimelineView v = new TimelineView();
        v.stage = r.Stage__c; v.status = r.Status__c; v.closed = r.Status__c != 'Active';
        v.nonResponsive = r.Non_Responsive__c == true;
        v.daysSinceContact = r.Days_Since_Contact__c == null ? null : (Integer) r.Days_Since_Contact__c;
        v.canLog = !v.closed;
        v.entries = new List<Entry>();
        // Frozen-clock gotcha: same-transaction rows share timestamps, so tie-break on Name DESC.
        for (Renewal_Activity__c a : [SELECT Id, Method__c, Details__c, Entry_Date__c, CreatedBy.Name
                                      FROM Renewal_Activity__c WHERE Lease_Renewal__c = :renewalId
                                      ORDER BY Entry_Date__c DESC NULLS LAST, Name DESC]) {
            Entry e = new Entry();
            e.id = a.Id; e.method = a.Method__c; e.details = a.Details__c;
            e.enteredBy = a.CreatedBy.Name; e.entryDate = a.Entry_Date__c;
            v.entries.add(e);
        }
        return v;
    }

    @AuraEnabled
    public static void addUpdate(Id renewalId, String method, String details) {
        if (String.isBlank(details)) throw ahe('Enter the outcome before saving.');
        if (String.isBlank(method) || !METHODS.contains(method)) throw ahe('Choose a valid contact method.');
        insert new Renewal_Activity__c(
            Lease_Renewal__c = renewalId, Method__c = method,
            Details__c = details.trim(), Entry_Date__c = Datetime.now());
        // A Yardi/system note is not tenant contact — only human methods reset the clock.
        if (method != 'System') {
            update new Lease_Renewal__c(Id = renewalId, Last_Contact_Date__c = Date.today());
        }
    }

    @AuraEnabled
    public static String submitForApproval(Id recordId) {
        if (recordId == null) throw ahe('No record was provided.');
        if (![SELECT Id FROM ProcessInstance WHERE TargetObjectId = :recordId AND Status = 'Pending'].isEmpty()) {
            throw ahe('This renewal is already pending approval.');
        }
        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(recordId);
            Approval.process(req);
            return 'The renewal rate has been submitted for approval.';
        } catch (Exception e) {
            throw ahe(e.getMessage());
        }
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}
```
`classes/LeaseRenewalController.cls-meta.xml`: same ApexClass XML as the test's meta file.

- [ ] **Step 3: Add class access to the perm set**

In `permissionsets/Property_Management_Access.permissionset-meta.xml`, next to the existing `classAccesses` entries:
```xml
    <classAccesses>
        <apexClass>LeaseRenewalController</apexClass>
        <enabled>true</enabled>
    </classAccesses>
```

- [ ] **Step 4: Deploy with tests**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/classes/LeaseRenewalController.cls -d force-app/main/default/classes/LeaseRenewalControllerTest.cls -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -l RunSpecifiedTests -t LeaseRenewalControllerTest --json
```
Expected: Succeeded, `numberTestErrors: 0`, 15 tests run. If a test fails, fix the controller (or a wrong expectation) and redeploy — do not weaken assertions.

- [ ] **Step 5: Commit and push**

```powershell
git add force-app/main/default/classes force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "Lease Renewal Tracker: LeaseRenewalController + 15 tests" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 5: Submit quick action, page layout, Path

**Files:**
- Create: `force-app/main/default/lwc/renewalSubmitForApproval/renewalSubmitForApproval.js` + `.js-meta.xml`
- Create: `force-app/main/default/quickActions/Lease_Renewal__c.Submit_for_Approval.quickAction-meta.xml`
- Create: `force-app/main/default/layouts/Lease_Renewal__c-Lease Renewal Layout.layout-meta.xml`
- Create: `force-app/main/default/pathAssistants/Lease_Renewal_Path.pathAssistant-meta.xml`

**Interfaces:**
- Consumes: `LeaseRenewalController.submitForApproval(recordId)` (Task 4).
- Produces: quick action `Lease_Renewal__c.Submit_for_Approval` on the layout's platformActionList; path `Lease_Renewal_Path`; layout WITHOUT Stage/Status fields.

- [ ] **Step 1: Headless quick-action LWC**

`lwc/renewalSubmitForApproval/renewalSubmitForApproval.js` (headless — NO .html file):
```js
import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import submitForApproval from '@salesforce/apex/LeaseRenewalController.submitForApproval';

// Headless quick action: one click submits the renewal rate into the
// Renewal Rate Approval process, toasts the result, and refreshes the record.
export default class RenewalSubmitForApproval extends LightningElement {
    @api recordId;

    @api async invoke() {
        try {
            const message = await submitForApproval({ recordId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Submitted for approval', message, variant: 'success' })
            );
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (e) {
            const message =
                (e && e.body && e.body.message) || 'Could not submit this renewal for approval.';
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Submit for approval failed', message, variant: 'error', mode: 'sticky' })
            );
        }
    }
}
```
`lwc/renewalSubmitForApproval/renewalSubmitForApproval.js-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <targets>
        <target>lightning__RecordAction</target>
    </targets>
    <targetConfigs>
        <targetConfig targets="lightning__RecordAction">
            <actionType>Action</actionType>
        </targetConfig>
    </targetConfigs>
</LightningComponentBundle>
```

- [ ] **Step 2: Quick action metadata**

`quickActions/Lease_Renewal__c.Submit_for_Approval.quickAction-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<QuickAction xmlns="http://soap.sforce.com/2006/04/metadata">
    <actionSubtype>Action</actionSubtype>
    <label>Submit for Approval</label>
    <lightningWebComponent>renewalSubmitForApproval</lightningWebComponent>
    <optionsCreateFeedItem>false</optionsCreateFeedItem>
    <type>LightningWebComponent</type>
</QuickAction>
```

- [ ] **Step 3: Page layout**

`layouts/Lease_Renewal__c-Lease Renewal Layout.layout-meta.xml` — NOTE: Stage__c and Status__c are deliberately absent (Path + flow manage them). The quick action goes in `platformActionList` (NOT `quickActionList` — LWC actions there fail deploy).
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Layout xmlns="http://soap.sforce.com/2006/04/metadata">
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>Renewal</label>
        <layoutColumns>
            <layoutItems><behavior>Required</behavior><field>Tenant_Name__c</field></layoutItems>
            <layoutItems><behavior>Required</behavior><field>Property_Asset__c</field></layoutItems>
            <layoutItems><behavior>Edit</behavior><field>Unit__c</field></layoutItems>
            <layoutItems><behavior>Edit</behavior><field>Space_Sq_Ft__c</field></layoutItems>
        </layoutColumns>
        <layoutColumns>
            <layoutItems><behavior>Edit</behavior><field>Handling_Person__c</field></layoutItems>
            <layoutItems><behavior>Edit</behavior><field>Last_Contact_Date__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Days_Since_Contact__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Non_Responsive__c</field></layoutItems>
        </layoutColumns>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>Renewal Terms</label>
        <layoutColumns>
            <layoutItems><behavior>Edit</behavior><field>Proposed_Rate__c</field></layoutItems>
            <layoutItems><behavior>Edit</behavior><field>Option_Honored__c</field></layoutItems>
        </layoutColumns>
        <layoutColumns>
            <layoutItems><behavior>Edit</behavior><field>Approval_Status__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Expiry_Health__c</field></layoutItems>
        </layoutColumns>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>Lease Snapshot</label>
        <layoutColumns>
            <layoutItems><behavior>Edit</behavior><field>Lease_Start__c</field></layoutItems>
            <layoutItems><behavior>Required</behavior><field>Lease_End__c</field></layoutItems>
            <layoutItems><behavior>Edit</behavior><field>Current_Rent__c</field></layoutItems>
        </layoutColumns>
        <layoutColumns>
            <layoutItems><behavior>Edit</behavior><field>Renewal_Option__c</field></layoutItems>
            <layoutItems><behavior>Edit</behavior><field>Preset_Terms__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Days_To_Expiry__c</field></layoutItems>
        </layoutColumns>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>System Information</label>
        <layoutColumns>
            <layoutItems><behavior>Readonly</behavior><field>CreatedById</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Renewed_Date__c</field></layoutItems>
        </layoutColumns>
        <layoutColumns>
            <layoutItems><behavior>Readonly</behavior><field>LastModifiedById</field></layoutItems>
        </layoutColumns>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>
    <layoutSections>
        <customLabel>false</customLabel>
        <detailHeading>false</detailHeading>
        <editHeading>false</editHeading>
        <layoutColumns/>
        <style>CustomLinks</style>
    </layoutSections>
    <platformActionList>
        <actionListContext>Record</actionListContext>
        <platformActionListItems>
            <actionName>Lease_Renewal__c.Submit_for_Approval</actionName>
            <actionType>QuickAction</actionType>
            <sortOrder>0</sortOrder>
        </platformActionListItems>
        <platformActionListItems>
            <actionName>Edit</actionName>
            <actionType>StandardButton</actionType>
            <sortOrder>1</sortOrder>
        </platformActionListItems>
        <platformActionListItems>
            <actionName>Clone</actionName>
            <actionType>StandardButton</actionType>
            <sortOrder>2</sortOrder>
        </platformActionListItems>
        <platformActionListItems>
            <actionName>Delete</actionName>
            <actionType>StandardButton</actionType>
            <sortOrder>3</sortOrder>
        </platformActionListItems>
    </platformActionList>
    <showEmailCheckbox>false</showEmailCheckbox>
    <showHighlightsPanel>false</showHighlightsPanel>
    <showInteractionLogPanel>false</showInteractionLogPanel>
    <showRunAssignmentRulesCheckbox>false</showRunAssignmentRulesCheckbox>
    <showSubmitAndAttachButton>false</showSubmitAndAttachButton>
</Layout>
```

- [ ] **Step 4: Path**

`pathAssistants/Lease_Renewal_Path.pathAssistant-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<PathAssistant xmlns="http://soap.sforce.com/2006/04/metadata">
    <active>true</active>
    <entityName>Lease_Renewal__c</entityName>
    <fieldName>Stage__c</fieldName>
    <masterLabel>Lease Renewal Path</masterLabel>
    <pathAssistantSteps>
        <info>Expiry is approaching but outreach has not begun. Start within 180 days of lease end.</info>
        <picklistValueName>Not Yet Started</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <fieldNames>Last_Contact_Date__c</fieldNames>
        <info>Renewal notice delivered to the tenant. Log the touch so the contact clock starts.</info>
        <picklistValueName>Notice Sent</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <fieldNames>Last_Contact_Date__c</fieldNames>
        <info>Waiting on the tenant. Log every follow-up in the Timeline — after 14 quiet days the renewal flags as non-responsive.</info>
        <picklistValueName>Awaiting Tenant Response</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <fieldNames>Proposed_Rate__c</fieldNames>
        <info>Terms under discussion. Record the proposed rate; log each round in the Timeline.</info>
        <picklistValueName>Negotiating</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <fieldNames>Proposed_Rate__c</fieldNames>
        <fieldNames>Approval_Status__c</fieldNames>
        <info>No pre-set option — the proposed rate needs owner sign-off. Use Submit for Approval; the decision moves this back to Negotiating.</info>
        <picklistValueName>Escalated for Approval</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <info>Both sides aligned — the amendment is being drafted and signed.</info>
        <picklistValueName>Amendment Drafted</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <fieldNames>Renewed_Date__c</fieldNames>
        <info>Amendment executed and entered into Yardi. Status flips to Closed Won automatically.</info>
        <picklistValueName>Renewed</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <info>Tenant declined to renew. Status flips to Closed Lost; the unit returns to market.</info>
        <picklistValueName>Not Renewing</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <info>Tenant is vacating at lease end. Status flips to Closed Lost; coordinate move-out and turnover.</info>
        <picklistValueName>Vacating</picklistValueName>
    </pathAssistantSteps>
    <recordTypeName>__MASTER__</recordTypeName>
</PathAssistant>
```

- [ ] **Step 5: Deploy**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/lwc/renewalSubmitForApproval -d force-app/main/default/quickActions/Lease_Renewal__c.Submit_for_Approval.quickAction-meta.xml -d "force-app/main/default/layouts/Lease_Renewal__c-Lease Renewal Layout.layout-meta.xml" -d force-app/main/default/pathAssistants/Lease_Renewal_Path.pathAssistant-meta.xml --json
```
Expected: Succeeded (4 components).

- [ ] **Step 6: Commit and push**

```powershell
git add force-app/main/default/lwc/renewalSubmitForApproval force-app/main/default/quickActions "force-app/main/default/layouts/Lease_Renewal__c-Lease Renewal Layout.layout-meta.xml" force-app/main/default/pathAssistants/Lease_Renewal_Path.pathAssistant-meta.xml
git commit -m "Lease Renewal Tracker: submit quick action, layout, path" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 6: renewalTimeline LWC + record page

**Files:**
- Create: `force-app/main/default/lwc/renewalTimeline/renewalTimeline.{js,html,css}` + `.js-meta.xml`
- Create: `force-app/main/default/flexipages/Lease_Renewal_Record_Page.flexipage-meta.xml`
- Modify: `force-app/main/default/applications/Property_Management.app-meta.xml` (add actionOverride)

**Interfaces:**
- Consumes: `getTimeline(renewalId)` / `addUpdate(renewalId, method, details)` (Task 4 signatures).
- Produces: flexipage `Lease_Renewal_Record_Page` (Task 8's tab/app work assumes it exists).

- [ ] **Step 1: renewalTimeline JS**

`lwc/renewalTimeline/renewalTimeline.js`:
```js
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTimeline from '@salesforce/apex/LeaseRenewalController.getTimeline';
import addUpdate from '@salesforce/apex/LeaseRenewalController.addUpdate';

const METHOD_META = {
    Call:   { fg: '#1A4880', bg: '#EBF3FC' },
    Email:  { fg: '#7A4A00', bg: '#FDF5E6' },
    Visit:  { fg: '#4A2A7A', bg: '#F3EEFB' },
    Note:   { fg: '#132850', bg: '#E8EFF7' },
    System: { fg: '#5A5752', bg: '#EDEBE7' }
};
const badge = (m) => {
    const x = METHOD_META[m] || METHOD_META.Note;
    return `display:inline-flex;align-items:center;font-size:10px;font-weight:700;letter-spacing:0.03em;text-transform:uppercase;padding:2px 7px;border-radius:9999px;background:${x.bg};color:${x.fg}`;
};

// Append-only renewal timeline: entries newest-first with method badges, a
// non-responsive pill in the header, and a Log Follow-Up composer (method +
// outcome both mandatory). Mirrors the leaseNegotiationLog patterns.
export default class RenewalTimeline extends LightningElement {
    @api recordId;
    _wired;
    view;
    adding = false;
    upMethod = '';
    upDetails = '';
    error = '';

    @wire(getTimeline, { renewalId: '$recordId' })
    wired(result) {
        this._wired = result;
        if (result.data) this.view = result.data;
    }

    get count() { return this.view && this.view.entries ? this.view.entries.length : 0; }
    get canLog() { return this.view && this.view.canLog; }
    get nonResponsive() { return !!(this.view && this.view.nonResponsive); }
    get silentText() { return `Non-responsive · ${this.view.daysSinceContact}d silent`; }
    get methodOptions() {
        // "System" is reserved for seeded/Yardi entries — humans pick a real touch.
        return ['Call', 'Email', 'Visit', 'Note'].map((m) => ({ label: m, value: m }));
    }

    get entries() {
        const rows = (this.view && this.view.entries) || [];
        return rows.map((e, i) => ({
            id: e.id,
            details: e.details,
            enteredBy: e.enteredBy || '—',
            method: e.method || 'Note',
            methodStyle: badge(e.method),
            entryDate: e.entryDate,
            isLatest: i === 0,
            showLine: i < rows.length - 1,
            markerClass: i === 0 ? 'rt-marker rt-marker--latest' : 'rt-marker'
        }));
    }

    openComposer() { this.adding = true; this.upMethod = ''; this.upDetails = ''; this.error = ''; }
    cancel() { this.adding = false; this.error = ''; }
    onDetails(e) { this.upDetails = e.detail.value; this.error = ''; }
    onMethod(e) { this.upMethod = e.detail.value; }

    save() {
        if (!this.upMethod) { this.error = 'Choose how the tenant was contacted.'; return; }
        if (!this.upDetails || !this.upDetails.trim()) { this.error = 'Enter the outcome before saving.'; return; }
        addUpdate({ renewalId: this.recordId, method: this.upMethod, details: this.upDetails })
            .then(() => {
                this.adding = false;
                // Refresh the record so highlights/detail (Last Contact, flags) update live.
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                return refreshApex(this._wired);
            })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({ title: 'Follow-up logged to the timeline', variant: 'success' }));
            })
            .catch((e) => {
                this.error = (e && e.body && e.body.message) || 'Unexpected error';
            });
    }
}
```

- [ ] **Step 2: renewalTimeline HTML**

`lwc/renewalTimeline/renewalTimeline.html`:
```html
<template>
    <div class="rt-card">
        <div class="rt-head">
            <div class="rt-head-left">
                <span class="rt-head-icon">
                    <lightning-icon icon-name="utility:clock" size="x-small" variant="inverse"></lightning-icon>
                </span>
                <div>
                    <div class="rt-title">Timeline</div>
                    <div class="rt-sub">{count} entries · append-only, never overwritten</div>
                </div>
                <template if:true={nonResponsive}>
                    <span class="rt-nonresp"><span class="rt-nonresp-dot"></span>{silentText}</span>
                </template>
            </div>
            <template if:true={canLog}>
                <lightning-button
                    variant="brand"
                    label="Log Follow-Up"
                    icon-name="utility:add"
                    onclick={openComposer}
                    disabled={adding}>
                </lightning-button>
            </template>
        </div>

        <template if:true={adding}>
            <div class="rt-composer">
                <div class="rt-composer-row">
                    <lightning-combobox
                        label="Method"
                        required
                        placeholder="Select…"
                        value={upMethod}
                        options={methodOptions}
                        onchange={onMethod}
                        variant="label-stacked">
                    </lightning-combobox>
                </div>
                <lightning-textarea
                    class="rt-textarea"
                    label="Outcome"
                    required
                    value={upDetails}
                    onchange={onDetails}
                    placeholder="Left voicemail, tenant confirmed interest, sent counter…">
                </lightning-textarea>
                <template if:true={error}>
                    <div class="rt-error">{error}</div>
                </template>
                <div class="rt-composer-actions">
                    <lightning-button
                        class="slds-m-right_x-small"
                        variant="brand"
                        label="Save to timeline"
                        icon-name="utility:check"
                        onclick={save}>
                    </lightning-button>
                    <lightning-button variant="neutral" label="Cancel" onclick={cancel}></lightning-button>
                </div>
            </div>
        </template>

        <div class="rt-body">
            <template for:each={entries} for:item="e">
                <div key={e.id} class="rt-entry">
                    <div class="rt-rail">
                        <span class={e.markerClass}></span>
                        <template if:true={e.showLine}><span class="rt-line"></span></template>
                    </div>
                    <div class="rt-content">
                        <div class="rt-entry-head">
                            <span class="rt-entry-left">
                                <span class="rt-by">{e.enteredBy}</span>
                                <span style={e.methodStyle}>{e.method}</span>
                            </span>
                            <lightning-formatted-date-time
                                class="rt-date"
                                value={e.entryDate}
                                year="numeric" month="short" day="2-digit"
                                hour="2-digit" minute="2-digit">
                            </lightning-formatted-date-time>
                        </div>
                        <div class="rt-details">{e.details}</div>
                        <template if:true={e.isLatest}><span class="rt-latest">Latest</span></template>
                    </div>
                </div>
            </template>
            <div class="rt-foot-note">
                <lightning-icon icon-name="utility:lock" size="xx-small"></lightning-icon>
                Entries are permanent. Logging a follow-up never erases what came before.
            </div>
        </div>
    </div>
</template>
```

- [ ] **Step 3: renewalTimeline CSS + meta**

`lwc/renewalTimeline/renewalTimeline.css`:
```css
:host { display:block; font-family:'Salesforce Sans', Arial, sans-serif; color:#181818; }

.rt-card { background:#fff; border:1px solid #E2E0DB; border-radius:8px; box-shadow:0 1px 2px rgba(7,20,40,0.06); overflow:hidden; }

/* header */
.rt-head { display:flex; align-items:center; justify-content:space-between; gap:10px; padding:14px 20px; border-bottom:1px solid #E2E0DB; }
.rt-head-left { display:flex; align-items:center; gap:10px; }
.rt-head-icon { width:26px; height:26px; border-radius:50%; background:#1A3464; display:inline-flex; align-items:center; justify-content:center; flex-shrink:0; animation:rt-pulse 2.4s ease-out infinite; }
@keyframes rt-pulse {
    0%   { box-shadow:0 0 0 0 rgba(26,52,100,0.40); }
    70%  { box-shadow:0 0 0 9px rgba(26,52,100,0); }
    100% { box-shadow:0 0 0 0 rgba(26,52,100,0); }
}
@media (prefers-reduced-motion: reduce) {
    .rt-head-icon { animation:none; }
}
.rt-title { font-size:15px; font-weight:700; line-height:1.1; color:#1A1714; }
.rt-sub { font-size:11px; color:#8A8680; margin-top:2px; }
.rt-nonresp { display:inline-flex; align-items:center; gap:5px; background:#FDECEC; color:#B01818; border:1px solid #F3B0B0; font-size:11px; font-weight:700; padding:3px 11px; border-radius:9999px; text-transform:uppercase; letter-spacing:0.03em; margin-left:8px; }
.rt-nonresp-dot { width:6px; height:6px; border-radius:50%; background:#D42B2B; }

/* composer */
.rt-composer { padding:16px 20px; background:#F3F6FB; border-bottom:1px solid #D6E0EE; }
.rt-composer-row { margin-bottom:10px; max-width:260px; }
.rt-textarea { display:block; }
.rt-error { margin-top:10px; font-size:12px; color:#8B1A1A; }
.rt-composer-actions { display:flex; gap:10px; margin-top:14px; }

/* timeline */
.rt-body { padding:16px 20px; }
.rt-entry { display:flex; gap:12px; padding-bottom:18px; }
.rt-rail { display:flex; flex-direction:column; align-items:center; flex-shrink:0; }
.rt-marker { width:12px; height:12px; border-radius:50%; background:#B0AEA8; border:2px solid #fff; box-shadow:0 0 0 2px #E2E0DB; margin-top:3px; flex-shrink:0; }
.rt-marker--latest { background:#1A3464; box-shadow:0 0 0 2px #D6E0EE; }
.rt-line { flex:1; width:2px; background:#E2E0DB; margin-top:2px; }
.rt-content { flex:1; padding-bottom:2px; min-width:0; }
.rt-entry-head { display:flex; align-items:center; justify-content:space-between; gap:8px; flex-wrap:wrap; }
.rt-entry-left { display:inline-flex; align-items:center; gap:7px; }
.rt-by { font-size:12px; font-weight:700; color:#1A1714; }
.rt-date { font-size:11px; color:#8A8680; }
.rt-details { font-size:13px; color:#1A1714; line-height:1.55; margin-top:5px; white-space:pre-wrap; word-break:break-word; }
.rt-latest { display:inline-block; margin-top:8px; font-size:10px; font-weight:700; letter-spacing:0.05em; text-transform:uppercase; color:#7A5A00; background:#FBF2DA; padding:2px 7px; border-radius:9999px; }

.rt-foot-note { display:flex; align-items:center; gap:7px; padding:10px 0 2px; color:#8A8680; font-size:11px; border-top:1px dashed #E2E0DB; }
```
`lwc/renewalTimeline/renewalTimeline.js-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Renewal Timeline</masterLabel>
    <description>Append-only follow-up timeline on a Lease Renewal, with a Log Follow-Up composer.</description>
    <targets>
        <target>lightning__RecordPage</target>
    </targets>
</LightningComponentBundle>
```
(Do NOT add `objects=` to the targetConfig — known deploy rejection.)

- [ ] **Step 4: Record page flexipage**

`flexipages/Lease_Renewal_Record_Page.flexipage-meta.xml` (one componentInstance per itemInstances; Approval History = `ProcessSteps`):
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
                <identifier>leaseRenewalPath</identifier>
            </componentInstance>
        </itemInstances>
        <name>subheader</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>renewalTimeline</componentName>
                <identifier>renewalTimelineComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>timelineContent</name>
        <type>Facet</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>parentFieldApiName</name>
                    <value>Lease_Renewal__c.Id</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>relatedListApiName</name>
                    <value>Renewal_Activities__r</value>
                </componentInstanceProperties>
                <componentName>force:relatedListSingleContainer</componentName>
                <identifier>renewalActivitiesList</identifier>
            </componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>parentFieldApiName</name>
                    <value>Lease_Renewal__c.Id</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>relatedListApiName</name>
                    <value>ProcessSteps</value>
                </componentInstanceProperties>
                <componentName>force:relatedListSingleContainer</componentName>
                <identifier>approvalHistoryList</identifier>
            </componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>parentFieldApiName</name>
                    <value>Lease_Renewal__c.Id</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>relatedListApiName</name>
                    <value>CombinedAttachments</value>
                </componentInstanceProperties>
                <componentName>force:relatedListSingleContainer</componentName>
                <identifier>notesAttachmentsList</identifier>
            </componentInstance>
        </itemInstances>
        <name>relatedContent</name>
        <type>Facet</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>body</name>
                    <value>timelineContent</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>title</name>
                    <value>Timeline</value>
                </componentInstanceProperties>
                <componentName>flexipage:tab</componentName>
                <identifier>timelineTab</identifier>
            </componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>body</name>
                    <value>relatedContent</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>title</name>
                    <value>Related</value>
                </componentInstanceProperties>
                <componentName>flexipage:tab</componentName>
                <identifier>relatedTab</identifier>
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
                <componentName>force:detailPanel</componentName>
                <identifier>recordDetail</identifier>
            </componentInstance>
        </itemInstances>
        <name>sidebar</name>
        <type>Region</type>
    </flexiPageRegions>
    <masterLabel>Lease Renewal Record Page</masterLabel>
    <sobjectType>Lease_Renewal__c</sobjectType>
    <template>
        <name>flexipage:recordHomeWithSubheaderTemplateDesktop</name>
    </template>
    <type>RecordPage</type>
</FlexiPage>
```

- [ ] **Step 5: Assign the page via app actionOverride**

In `applications/Property_Management.app-meta.xml`, add after the `Lease__c` actionOverrides block:
```xml
    <actionOverrides>
        <actionName>View</actionName>
        <comment>Lease Renewal Record Page</comment>
        <content>Lease_Renewal_Record_Page</content>
        <formFactor>Large</formFactor>
        <skipRecordTypeSelect>false</skipRecordTypeSelect>
        <type>Flexipage</type>
        <pageOrSobjectType>Lease_Renewal__c</pageOrSobjectType>
    </actionOverrides>
```

- [ ] **Step 6: Deploy (flexipage+LWC first, then app)**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/lwc/renewalTimeline -d force-app/main/default/flexipages/Lease_Renewal_Record_Page.flexipage-meta.xml --json
sf project deploy start -d force-app/main/default/applications/Property_Management.app-meta.xml --json
```
Expected: both Succeeded. If `ProcessSteps` is rejected on this object, drop that one itemInstances block (Approval History then lives only in the highlights-panel notifications) and note it in the commit message — do not swap in `RelatedApprovalHistoryList` (known-invalid).

- [ ] **Step 7: Commit and push**

```powershell
git add force-app/main/default/lwc/renewalTimeline force-app/main/default/flexipages/Lease_Renewal_Record_Page.flexipage-meta.xml force-app/main/default/applications/Property_Management.app-meta.xml
git commit -m "Lease Renewal Tracker: timeline LWC + record page with path and approval history" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 7: Home-page widget LWCs (renewalKpis, renewalList, renewalNeedsApproval, renewalAttention)

**Files:**
- Create: `force-app/main/default/lwc/renewalKpis/renewalKpis.{js,html,css}` + `.js-meta.xml`
- Create: `force-app/main/default/lwc/renewalList/renewalList.{js,html,css}` + `.js-meta.xml`
- Create: `force-app/main/default/lwc/renewalNeedsApproval/renewalNeedsApproval.{js,html,css}` + `.js-meta.xml`
- Create: `force-app/main/default/lwc/renewalAttention/renewalAttention.{js,html,css}` + `.js-meta.xml`

**Interfaces:**
- Consumes: `getHomeKpis`, `getRecentRenewals`, `getNeedsApproval`, `getAttention` (Task 4 Row shape), existing shared components `c-stat-card` (attrs: value, label, icon-name, icon-color) and `c-list-datatable` (lightning-datatable subclass with custom `pill` cell type taking typeAttributes wrapStyle/dotStyle).
- Produces: the four component names Task 8's flexipage references.

All four `.js-meta.xml` files use this shape (adjust masterLabel/description per component):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Renewal KPIs</masterLabel>
    <description>KPI strip for the Lease Renewals home page.</description>
    <targets>
        <target>lightning__AppPage</target>
        <target>lightning__HomePage</target>
    </targets>
</LightningComponentBundle>
```

- [ ] **Step 1: renewalKpis**

`renewalKpis.js`:
```js
import { LightningElement, wire } from 'lwc';
import getHomeKpis from '@salesforce/apex/LeaseRenewalController.getHomeKpis';

// Top KPI strip on the Lease Renewals home page.
export default class RenewalKpis extends LightningElement {
    k;
    @wire(getHomeKpis) wired({ data }) { if (data) this.k = data; }

    get cards() {
        const k = this.k || {};
        return [
            { key: 'active',   value: k.active ?? 0,        label: 'Active Renewals',      iconName: 'utility:event',    iconColor: '#7A9ED4' },
            { key: 'expiring', value: k.expiring90 ?? 0,    label: 'Expiring ≤ 90 Days',   iconName: 'utility:clock',    iconColor: '#D8BE72' },
            { key: 'nonresp',  value: k.nonResponsive ?? 0, label: 'Non-Responsive',       iconName: 'utility:comments', iconColor: '#E58A8A' },
            { key: 'renewed',  value: k.renewedYtd ?? 0,    label: 'Renewed (YTD)',        iconName: 'utility:success',  iconColor: '#8FCBAA' }
        ];
    }
}
```
`renewalKpis.html`:
```html
<template>
    <div class="kpi-grid">
        <template for:each={cards} for:item="c">
            <c-stat-card key={c.key} value={c.value} label={c.label} icon-name={c.iconName} icon-color={c.iconColor}></c-stat-card>
        </template>
    </div>
</template>
```
`renewalKpis.css`:
```css
.kpi-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; }
@media (max-width: 1024px) { .kpi-grid { grid-template-columns: repeat(2, 1fr); } }
```

- [ ] **Step 2: renewalList**

`renewalList.js`:
```js
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRecentRenewals from '@salesforce/apex/LeaseRenewalController.getRecentRenewals';

const STAGE_ACCENT = {
    'Not Yet Started': '#7A9ED4', 'Notice Sent': '#4A71B8', 'Awaiting Tenant Response': '#C88010',
    'Negotiating': '#B8651A', 'Escalated for Approval': '#1A3464', 'Amendment Drafted': '#A88020',
    'Renewed': '#198A40', 'Not Renewing': '#8A8680', 'Vacating': '#6B6862'
};
const pillWrap = (bg, fg) => `display:inline-flex;align-items:center;gap:6px;background:${bg};color:${fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Tenant', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'tenant' }, target: '_self' } },
    { label: 'Property', fieldName: 'property', type: 'text' },
    { label: 'Lease Expiry', fieldName: 'leaseEnd', type: 'date', initialWidth: 120, typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' } },
    { label: 'Days Left', fieldName: 'daysText', type: 'pill', initialWidth: 120, typeAttributes: { wrapStyle: { fieldName: 'daysWrap' }, dotStyle: { fieldName: 'daysDot' } } },
    { label: 'Stage', fieldName: 'stage', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'stageWrap' }, dotStyle: '' } },
    { label: 'Last Contact', fieldName: 'contactText', type: 'pill', initialWidth: 140, typeAttributes: { wrapStyle: { fieldName: 'contactWrap' }, dotStyle: { fieldName: 'contactDot' } } }
];

// Recent Renewals list on the Lease Renewals home page (6 newest, View All footer).
export default class RenewalList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data = [];
    listUrl = '#';
    @wire(getRecentRenewals) wired({ data }) { if (data) this._data = data; }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => { this.listUrl = url; });
    }
    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Lease_Renewal__c', actionName: 'list' },
            state: { filterName: 'All' }
        };
    }

    get rows() {
        return this._data.map((q) => {
            const sc = STAGE_ACCENT[q.stage] || '#4A71B8';
            const d = q.daysToExpiry;
            let daysText;
            let daysWrap;
            let daysDot = '';
            if (q.closed) {
                daysText = q.stage === 'Renewed' ? 'Renewed' : (q.stage === 'Vacating' ? 'Vacating' : 'Not renew');
                daysWrap = q.stage === 'Renewed' ? pillWrap('#EBF9F1', '#146830') : pillWrap('#E2E0DB', '#3F3C38');
            } else if (d == null) {
                daysText = '—'; daysWrap = pillWrap('#EDEBE7', '#5A5752');
            } else if (d < 0) {
                daysText = 'Expired'; daysWrap = pillWrap('#FDF0F0', '#8B1A1A'); daysDot = dot('#D93636');
            } else if (d <= 30) {
                daysText = `${d}d left`; daysWrap = pillWrap('#FDF0F0', '#8B1A1A'); daysDot = dot('#D93636');
            } else if (d <= 90) {
                daysText = `${d}d left`; daysWrap = pillWrap('#FDF5E6', '#7A4A00'); daysDot = dot('#C88010');
            } else {
                daysText = `${d}d left`; daysWrap = pillWrap('#EBF9F1', '#146830'); daysDot = dot('#22A652');
            }
            let contactText;
            let contactWrap;
            let contactDot = '';
            if (q.closed) {
                contactText = '—'; contactWrap = pillWrap('transparent', '#524F4A');
            } else if (q.daysSinceContact == null) {
                contactText = 'No contact yet'; contactWrap = pillWrap('transparent', '#8A8680');
            } else if (q.nonResponsive) {
                contactText = `${q.daysSinceContact}d ago`; contactWrap = pillWrap('#FDECEC', '#B01818'); contactDot = dot('#D42B2B');
            } else {
                contactText = `${q.daysSinceContact}d ago`; contactWrap = pillWrap('transparent', '#524F4A');
            }
            return {
                id: q.id,
                recordUrl: `/lightning/r/Lease_Renewal__c/${q.id}/view`,
                tenant: q.tenant || '—',
                property: q.property || '—',
                leaseEnd: q.leaseEnd,
                daysText, daysWrap, daysDot,
                stage: q.stage,
                stageWrap: `display:inline-flex;align-items:center;font-size:11px;font-weight:600;padding:3px 9px;border-radius:6px;background:${sc}18;color:${sc};border:1px solid ${sc}44;white-space:nowrap`,
                contactText, contactWrap, contactDot
            };
        });
    }
    get count() { return this.rows.length; }

    newRenewal() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Lease_Renewal__c', actionName: 'new' }
        });
    }
    viewAll(event) {
        if (event) event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}
```
`renewalList.html`:
```html
<template>
    <lightning-card>
        <div slot="title" class="hdr">
            <span class="hdr-icon">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#7A9ED4" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M8 2v4M16 2v4M3 10h18"/><rect width="18" height="18" x="3" y="4" rx="2"/>
                </svg>
            </span>
            <span class="hdr-title">Recent Renewals ({count})</span>
        </div>
        <div slot="actions" class="hdr-actions">
            <lightning-button variant="brand" label="New Renewal" icon-name="utility:add" onclick={newRenewal}></lightning-button>
        </div>
        <c-list-datatable
            key-field="id"
            data={rows}
            columns={columns}
            column-widths-mode="fixed"
            hide-checkbox-column>
        </c-list-datatable>
        <div slot="footer" class="view-all-footer">
            <a href={listUrl} onclick={viewAll}>View All</a>
        </div>
    </lightning-card>
</template>
```
`renewalList.css`:
```css
.hdr { display:flex; align-items:center; gap:9px; }
.hdr-icon { display:inline-flex; align-items:center; justify-content:center; flex-shrink:0; }
.hdr-title { font-size:16px; font-weight:700; color:#1A1714; }
.hdr-actions { display:flex; align-items:center; justify-content:flex-end; gap:12px; flex-wrap:wrap; }
.view-all-footer { text-align: center; }
.view-all-footer a { font-weight: 600; color: #0B5CAB; text-decoration: none; }
.view-all-footer a:hover { text-decoration: underline; }
```

- [ ] **Step 3: renewalNeedsApproval**

`renewalNeedsApproval.js`:
```js
import { LightningElement, wire } from 'lwc';
import getNeedsApproval from '@salesforce/apex/LeaseRenewalController.getNeedsApproval';

const pill = (bg, fg) => `display:inline-flex;align-items:center;gap:5px;background:${bg};color:${fg};font-size:11px;font-weight:700;padding:3px 9px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

// Right-column widget: rate decisions awaiting owner sign-off.
export default class RenewalNeedsApproval extends LightningElement {
    _data = [];
    @wire(getNeedsApproval) wired({ data }) { if (data) this._data = data; }

    get rows() {
        return this._data.map((q) => {
            const d = q.daysToExpiry == null ? 0 : q.daysToExpiry;
            let wrap;
            let dotStyle;
            if (d <= 30) { wrap = pill('#FDF0F0', '#8B1A1A'); dotStyle = dot('#D93636'); }
            else if (d <= 90) { wrap = pill('#FDF5E6', '#7A4A00'); dotStyle = dot('#C88010'); }
            else { wrap = pill('#EBF9F1', '#146830'); dotStyle = dot('#22A652'); }
            return {
                id: q.id,
                recordUrl: `/lightning/r/Lease_Renewal__c/${q.id}/view`,
                tenant: q.tenant || '—',
                sub: `${q.stage} · ${q.property || '—'}`,
                daysText: `${d}d left`,
                daysWrap: wrap,
                daysDot: dotStyle
            };
        });
    }
    get hasRows() { return this._data.length > 0; }
}
```
`renewalNeedsApproval.html`:
```html
<template>
    <article class="na-card">
        <div class="na-hd">
            <span class="na-icon">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#1A3464" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="m16 16 2 2 4-4"/><path d="M21 10V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l2-1.14"/>
                </svg>
            </span>
            <div>
                <div class="na-title">Needs Approval</div>
                <div class="na-sub">Rate decisions awaiting sign-off</div>
            </div>
        </div>
        <template if:true={hasRows}>
            <div class="na-body">
                <template for:each={rows} for:item="r">
                    <a key={r.id} href={r.recordUrl} class="na-row">
                        <div class="na-main">
                            <div class="na-name">{r.tenant}</div>
                            <div class="na-metasub">{r.sub}</div>
                        </div>
                        <span style={r.daysWrap}><span style={r.daysDot}></span>{r.daysText}</span>
                    </a>
                </template>
            </div>
        </template>
        <template if:false={hasRows}>
            <div class="na-empty">All caught up.</div>
        </template>
    </article>
</template>
```
`renewalNeedsApproval.css`:
```css
.na-card { background:#fff; border:1px solid #E2E0DB; border-radius:8px; box-shadow:0 1px 2px rgba(7,20,40,0.06); padding:18px; display:block; }
.na-hd { display:flex; align-items:center; gap:9px; margin-bottom:6px; }
.na-icon { width:26px; height:26px; border-radius:50%; background:#E8EFF7; display:inline-flex; align-items:center; justify-content:center; flex-shrink:0; }
.na-title { font-size:16px; font-weight:700; color:#1A1714; line-height:1.1; }
.na-sub { font-size:11px; color:#8A8680; margin-top:2px; }
.na-body { display:flex; flex-direction:column; }
.na-row { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:11px 4px; border-bottom:1px solid #EDECEA; text-decoration:none; }
.na-row:last-child { border-bottom:none; }
.na-row:hover { background:#F7FAFF; }
.na-name { font-size:14px; font-weight:700; color:#1565C0; }
.na-metasub { font-size:12px; color:#524F4A; margin-top:2px; }
.na-empty { padding:20px 4px; text-align:center; color:#8A8680; font-size:13px; }
```

- [ ] **Step 4: renewalAttention**

`renewalAttention.js`:
```js
import { LightningElement, wire } from 'lwc';
import getAttention from '@salesforce/apex/LeaseRenewalController.getAttention';

const pill = (bg, fg) => `display:inline-flex;align-items:center;gap:5px;background:${bg};color:${fg};font-size:11px;font-weight:700;padding:3px 9px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

// Right-column widget: renewals that need a nudge — tenant gone quiet or lease
// expiring within 30 days.
export default class RenewalAttention extends LightningElement {
    _data = [];
    @wire(getAttention) wired({ data }) { if (data) this._data = data; }

    get rows() {
        return this._data.map((q) => {
            const nonResp = q.nonResponsive;
            const d = q.daysToExpiry == null ? 0 : q.daysToExpiry;
            return {
                id: q.id,
                recordUrl: `/lightning/r/Lease_Renewal__c/${q.id}/view`,
                tenant: q.tenant || '—',
                sub: nonResp ? `Non-responsive · ${q.daysSinceContact}d silent` : `${q.stage} · expires soon`,
                pillText: d < 0 ? 'Expired' : `${d}d left`,
                pillWrap: nonResp ? pill('#FDECEC', '#B01818') : pill('#FDF0F0', '#8B1A1A'),
                pillDot: nonResp ? dot('#D42B2B') : dot('#D93636')
            };
        });
    }
    get hasRows() { return this._data.length > 0; }
}
```
`renewalAttention.html`:
```html
<template>
    <article class="ra-card">
        <div class="ra-hd">
            <span class="ra-icon">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#E58A8A" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4M12 17h.01"/>
                </svg>
            </span>
            <div>
                <div class="ra-title">Needs Attention</div>
                <div class="ra-sub">Gone quiet, or expiring within 30 days</div>
            </div>
        </div>
        <template if:true={hasRows}>
            <div class="ra-body">
                <template for:each={rows} for:item="r">
                    <a key={r.id} href={r.recordUrl} class="ra-row">
                        <div class="ra-main">
                            <div class="ra-name">{r.tenant}</div>
                            <div class="ra-metasub">{r.sub}</div>
                        </div>
                        <span style={r.pillWrap}><span style={r.pillDot}></span>{r.pillText}</span>
                    </a>
                </template>
            </div>
        </template>
        <template if:false={hasRows}>
            <div class="ra-empty">Every renewal is on track.</div>
        </template>
    </article>
</template>
```
`renewalAttention.css`:
```css
.ra-card { background:#fff; border:1px solid #E2E0DB; border-radius:8px; box-shadow:0 1px 2px rgba(7,20,40,0.06); padding:18px; display:block; }
.ra-hd { display:flex; align-items:center; gap:9px; margin-bottom:6px; }
.ra-icon { width:26px; height:26px; border-radius:50%; background:#FDECEC; display:inline-flex; align-items:center; justify-content:center; flex-shrink:0; }
.ra-title { font-size:16px; font-weight:700; color:#1A1714; line-height:1.1; }
.ra-sub { font-size:11px; color:#8A8680; margin-top:2px; }
.ra-body { display:flex; flex-direction:column; }
.ra-row { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:11px 4px; border-bottom:1px solid #EDECEA; text-decoration:none; }
.ra-row:last-child { border-bottom:none; }
.ra-row:hover { background:#FFF7F7; }
.ra-name { font-size:14px; font-weight:700; color:#1565C0; }
.ra-metasub { font-size:12px; color:#524F4A; margin-top:2px; }
.ra-empty { padding:20px 4px; text-align:center; color:#8A8680; font-size:13px; }
```

- [ ] **Step 5: Deploy and commit**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/lwc/renewalKpis -d force-app/main/default/lwc/renewalList -d force-app/main/default/lwc/renewalNeedsApproval -d force-app/main/default/lwc/renewalAttention --json
```
Expected: Succeeded.
```powershell
git add force-app/main/default/lwc/renewalKpis force-app/main/default/lwc/renewalList force-app/main/default/lwc/renewalNeedsApproval force-app/main/default/lwc/renewalAttention
git commit -m "Lease Renewal Tracker: home-page widget LWCs" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 8: Home flexipage, tabs, app navigation, perm-set tabs

**Files:**
- Create: `force-app/main/default/flexipages/Lease_Renewals_Home.flexipage-meta.xml`
- Create: `force-app/main/default/tabs/Lease_Renewals.tab-meta.xml`
- Create: `force-app/main/default/tabs/Lease_Renewal__c.tab-meta.xml`
- Modify: `force-app/main/default/applications/Property_Management.app-meta.xml` (add 2 tabs)
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml` (add 2 tabSettings)

**Interfaces:**
- Consumes: the 4 LWCs (Task 7).
- Produces: `Lease_Renewals` app-home tab visible in the Property Management app.

- [ ] **Step 1: Home flexipage**

`flexipages/Lease_Renewals_Home.flexipage-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<FlexiPage xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>renewalKpis</componentName>
                <identifier>renewalKpisComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>region1</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>renewalList</componentName>
                <identifier>renewalListComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>region2</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>renewalNeedsApproval</componentName>
                <identifier>renewalNeedsApprovalComponent</identifier>
            </componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance>
                <componentName>renewalAttention</componentName>
                <identifier>renewalAttentionComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>region3</name>
        <type>Region</type>
    </flexiPageRegions>
    <masterLabel>Lease Renewals Home</masterLabel>
    <template>
        <name>flexipage:appHomeTemplateHeaderTwoColumns</name>
    </template>
    <type>AppPage</type>
</FlexiPage>
```

- [ ] **Step 2: Tabs**

`tabs/Lease_Renewals.tab-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPage>Lease_Renewals_Home</flexiPage>
    <label>Lease Renewals</label>
    <motif>Custom51: Apple</motif>
</CustomTab>
```
`tabs/Lease_Renewal__c.tab-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <customObject>true</customObject>
    <motif>Custom51: Apple</motif>
</CustomTab>
```

- [ ] **Step 3: App navigation**

In `applications/Property_Management.app-meta.xml`, after `<tabs>Lease__c</tabs>` add:
```xml
    <tabs>Lease_Renewals</tabs>
    <tabs>Lease_Renewal__c</tabs>
```

- [ ] **Step 4: Perm-set tab visibility**

In `permissionsets/Property_Management_Access.permissionset-meta.xml`, alongside existing `tabSettings`:
```xml
    <tabSettings>
        <tab>Lease_Renewals</tab>
        <visibility>Visible</visibility>
    </tabSettings>
    <tabSettings>
        <tab>Lease_Renewal__c</tab>
        <visibility>Visible</visibility>
    </tabSettings>
```

- [ ] **Step 5: Deploy (flexipage + tabs first, then app + perm set)**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/flexipages/Lease_Renewals_Home.flexipage-meta.xml -d force-app/main/default/tabs/Lease_Renewals.tab-meta.xml -d force-app/main/default/tabs/Lease_Renewal__c.tab-meta.xml --json
sf project deploy start -d force-app/main/default/applications/Property_Management.app-meta.xml -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml --json
```
Expected: both Succeeded. (Two deploys because the app references tabs that must exist first.)

- [ ] **Step 6: Commit and push**

```powershell
git add force-app/main/default/flexipages/Lease_Renewals_Home.flexipage-meta.xml force-app/main/default/tabs force-app/main/default/applications/Property_Management.app-meta.xml force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "Lease Renewal Tracker: home page, tabs, app navigation" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 9: Reports + dashboard

**Files:**
- Create: `force-app/main/default/reports/Leasing/Active_Renewals_by_Stage.report-meta.xml`
- Create: `force-app/main/default/reports/Leasing/Non_Responsive_Renewals.report-meta.xml`
- Create: `force-app/main/default/reports/Leasing/Renewals_Needing_Approval.report-meta.xml`
- Create: `force-app/main/default/reports/Leasing/Renewals_Expiring_Soonest.report-meta.xml`
- Create: `force-app/main/default/dashboards/Leasing/Lease_Renewals.dashboard-meta.xml`

**Interfaces:**
- Consumes: `Lease_Renewal__c` fields (Task 1). Report type token: `CustomEntity$Lease_Renewal__c`; columns prefixed `Lease_Renewal__c.`.
- Produces: dashboard `Leasing/Lease_Renewals` reachable from the app's existing Dashboards tab.

- [ ] **Step 1: Reports**

`reports/Leasing/Active_Renewals_by_Stage.report-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <chart>
        <backgroundColor1>#FFFFFF</backgroundColor1>
        <backgroundColor2>#FFFFFF</backgroundColor2>
        <backgroundFadeDir>Diagonal</backgroundFadeDir>
        <chartSummaries>
            <axisBinding>y</axisBinding>
            <column>RowCount</column>
        </chartSummaries>
        <chartType>HorizontalBar</chartType>
        <enableHoverLabels>true</enableHoverLabels>
        <expandOthers>true</expandOthers>
        <groupingColumn>Lease_Renewal__c.Stage__c</groupingColumn>
        <location>CHART_TOP</location>
        <showAxisLabels>true</showAxisLabels>
        <showValues>true</showValues>
        <size>Medium</size>
        <summaryAxisRange>Auto</summaryAxisRange>
        <textColor>#000000</textColor>
        <textSize>12</textSize>
        <titleColor>#000000</titleColor>
        <titleSize>18</titleSize>
    </chart>
    <columns>
        <field>Lease_Renewal__c.Tenant_Name__c</field>
    </columns>
    <filter>
        <criteriaItems>
            <column>Lease_Renewal__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Active</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Lease_Renewal__c.Stage__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Active Renewals by Stage</name>
    <reportType>CustomEntity$Lease_Renewal__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
`reports/Leasing/Non_Responsive_Renewals.report-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Renewal__c.Tenant_Name__c</field></columns>
    <columns><field>Lease_Renewal__c.Property_Display_Name__c</field></columns>
    <columns><field>Lease_Renewal__c.Days_Since_Contact__c</field></columns>
    <columns><field>Lease_Renewal__c.Last_Contact_Date__c</field></columns>
    <columns><field>Lease_Renewal__c.Stage__c</field></columns>
    <columns><field>Lease_Renewal__c.Lease_End__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Lease_Renewal__c.Non_Responsive__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>1</value>
        </criteriaItems>
    </filter>
    <format>Tabular</format>
    <name>Non-Responsive Renewals</name>
    <reportType>CustomEntity$Lease_Renewal__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
`reports/Leasing/Renewals_Needing_Approval.report-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Renewal__c.Tenant_Name__c</field></columns>
    <columns><field>Lease_Renewal__c.Property_Display_Name__c</field></columns>
    <columns><field>Lease_Renewal__c.Proposed_Rate__c</field></columns>
    <columns><field>Lease_Renewal__c.Lease_End__c</field></columns>
    <columns><field>Lease_Renewal__c.Days_To_Expiry__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Lease_Renewal__c.Approval_Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Pending</value>
        </criteriaItems>
        <criteriaItems>
            <column>Lease_Renewal__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Active</value>
        </criteriaItems>
    </filter>
    <format>Tabular</format>
    <name>Renewals Needing Approval</name>
    <reportType>CustomEntity$Lease_Renewal__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
`reports/Leasing/Renewals_Expiring_Soonest.report-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Renewal__c.Tenant_Name__c</field></columns>
    <columns><field>Lease_Renewal__c.Property_Display_Name__c</field></columns>
    <columns><field>Lease_Renewal__c.Unit__c</field></columns>
    <columns><field>Lease_Renewal__c.Lease_End__c</field></columns>
    <columns><field>Lease_Renewal__c.Days_To_Expiry__c</field></columns>
    <columns><field>Lease_Renewal__c.Stage__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Lease_Renewal__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Active</value>
        </criteriaItems>
        <criteriaItems>
            <column>Lease_Renewal__c.Days_To_Expiry__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>lessOrEqual</operator>
            <value>90</value>
        </criteriaItems>
    </filter>
    <format>Tabular</format>
    <name>Renewals Expiring Soonest</name>
    <reportType>CustomEntity$Lease_Renewal__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 2: Dashboard**

`dashboards/Leasing/Lease_Renewals.dashboard-meta.xml` (3 metrics on top, stage bar below; `componentType Bar` + `chartAxisRange` — NEVER HorizontalBar or legendPosition-on-bar-report gotchas):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Dashboard xmlns="http://soap.sforce.com/2006/04/metadata">
    <backgroundEndColor>#FFFFFF</backgroundEndColor>
    <backgroundFadeDirection>Diagonal</backgroundFadeDirection>
    <backgroundStartColor>#FFFFFF</backgroundStartColor>
    <dashboardGridLayout>
        <dashboardGridComponents>
            <colSpan>4</colSpan>
            <columnIndex>0</columnIndex>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary>
                    <column>RowCount</column>
                </chartSummary>
                <componentChartTheme>light</componentChartTheme>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorBreakpoint1>1.0</indicatorBreakpoint1>
                <indicatorBreakpoint2>2.0</indicatorBreakpoint2>
                <indicatorHighColor>#C8A045</indicatorHighColor>
                <indicatorLowColor>#C8A045</indicatorLowColor>
                <indicatorMiddleColor>#C8A045</indicatorMiddleColor>
                <metricLabel>Expiring ≤ 90 Days</metricLabel>
                <report>Leasing/Renewals_Expiring_Soonest</report>
                <showRange>false</showRange>
            </dashboardComponent>
            <rowIndex>0</rowIndex>
            <rowSpan>4</rowSpan>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>4</colSpan>
            <columnIndex>4</columnIndex>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary>
                    <column>RowCount</column>
                </chartSummary>
                <componentChartTheme>light</componentChartTheme>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorBreakpoint1>1.0</indicatorBreakpoint1>
                <indicatorBreakpoint2>1.0</indicatorBreakpoint2>
                <indicatorHighColor>#C23934</indicatorHighColor>
                <indicatorLowColor>#1B7A4B</indicatorLowColor>
                <indicatorMiddleColor>#C23934</indicatorMiddleColor>
                <metricLabel>Non-Responsive Tenants</metricLabel>
                <report>Leasing/Non_Responsive_Renewals</report>
                <showRange>false</showRange>
            </dashboardComponent>
            <rowIndex>0</rowIndex>
            <rowSpan>4</rowSpan>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>4</colSpan>
            <columnIndex>8</columnIndex>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary>
                    <column>RowCount</column>
                </chartSummary>
                <componentChartTheme>light</componentChartTheme>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorBreakpoint1>1.0</indicatorBreakpoint1>
                <indicatorBreakpoint2>2.0</indicatorBreakpoint2>
                <indicatorHighColor>#132850</indicatorHighColor>
                <indicatorLowColor>#132850</indicatorLowColor>
                <indicatorMiddleColor>#132850</indicatorMiddleColor>
                <metricLabel>Needs Approval</metricLabel>
                <report>Leasing/Renewals_Needing_Approval</report>
                <showRange>false</showRange>
            </dashboardComponent>
            <rowIndex>0</rowIndex>
            <rowSpan>4</rowSpan>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>12</colSpan>
            <columnIndex>0</columnIndex>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartAxisRange>Auto</chartAxisRange>
                <chartSummary>
                    <axisBinding>y</axisBinding>
                    <column>RowCount</column>
                </chartSummary>
                <componentChartTheme>light</componentChartTheme>
                <componentType>Bar</componentType>
                <decimalPrecision>0</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <drillEnabled>true</drillEnabled>
                <drillToDetailEnabled>true</drillToDetailEnabled>
                <enableHover>true</enableHover>
                <expandOthers>false</expandOthers>
                <groupingColumn>Lease_Renewal__c.Stage__c</groupingColumn>
                <groupingSortProperties/>
                <legendPosition>Bottom</legendPosition>
                <report>Leasing/Active_Renewals_by_Stage</report>
                <showPercentage>false</showPercentage>
                <showPicturesOnCharts>false</showPicturesOnCharts>
                <showValues>true</showValues>
                <sortBy>RowLabelAscending</sortBy>
                <title>Active Renewals by Stage</title>
                <useReportChart>false</useReportChart>
            </dashboardComponent>
            <rowIndex>4</rowIndex>
            <rowSpan>8</rowSpan>
        </dashboardGridComponents>
        <numberOfColumns>12</numberOfColumns>
        <rowHeight>36</rowHeight>
    </dashboardGridLayout>
    <dashboardType>SpecifiedUser</dashboardType>
    <isGridLayout>true</isGridLayout>
    <owner>test-3iuncy5c1je5@example.com</owner>
    <runningUser>test-3iuncy5c1je5@example.com</runningUser>
    <textColor>#000000</textColor>
    <title>Lease Renewals</title>
    <titleColor>#000000</titleColor>
    <titleSize>12</titleSize>
</Dashboard>
```

- [ ] **Step 3: Deploy (reports first, then dashboard)**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/reports/Leasing --json
sf project deploy start -d force-app/main/default/dashboards/Leasing/Lease_Renewals.dashboard-meta.xml --json
```
Expected: both Succeeded (the first re-deploys the 6 existing Leasing reports too — harmless).

- [ ] **Step 4: Commit and push**

```powershell
git add force-app/main/default/reports/Leasing force-app/main/default/dashboards/Leasing
git commit -m "Lease Renewal Tracker: 4 reports + Lease Renewals dashboard" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 10: Seed data + end-to-end verification

**Files:**
- Create: `scripts/seed-lease-renewals.apex`

**Interfaces:**
- Consumes: everything. Idempotent (skips if any `Lease_Renewal__c` exists).

- [ ] **Step 1: Write the seed script**

`scripts/seed-lease-renewals.apex` (all dates are offsets from `Date.today()`; the `Renewed` record relies on the flow to set Closed Won + Renewed_Date; timeline entries inserted with `Entry_Date__c` offsets, first entry always Method=System):
```apex
// Seed Lease Renewal Tracker demo data. Idempotent: skips when renewals exist.
// Run: sf apex run -f scripts/seed-lease-renewals.apex
if (![SELECT Id FROM Lease_Renewal__c LIMIT 1].isEmpty()) {
    System.debug('Seed skipped — Lease Renewal records already exist.');
} else {
    // --- ensure 6 property assets ---
    List<String> names = new List<String>{ 'Westgate Plaza', 'Sterling Crossing', 'Magnolia Commons', 'Bayou Bend Center', 'Katy Mills Strip', 'Heights Marketplace' };
    Map<String, Property_Asset__c> assets = new Map<String, Property_Asset__c>();
    for (Property_Asset__c a : [SELECT Id, Name FROM Property_Asset__c WHERE Name IN :names]) assets.put(a.Name, a);
    List<Property__c> newProps = new List<Property__c>();
    for (String n : names) {
        if (!assets.containsKey(n)) newProps.add(new Property__c(Name=n, Address__c='100 ' + n + ' Dr', City__c='Houston', State__c='TX', Square_Footage__c=40000, Asset_Type__c='Retail'));
    }
    insert newProps;
    List<Property_Asset__c> newAssets = new List<Property_Asset__c>();
    for (Property__c p : newProps) newAssets.add(new Property_Asset__c(Name=p.Name, Property__c=p.Id, Property_Type__c='Retail', Status__c='Active'));
    insert newAssets;
    for (Property_Asset__c a : newAssets) assets.put(a.Name, a);

    Date t = Date.today();
    List<Lease_Renewal__c> rs = new List<Lease_Renewal__c>{
        // 0 Riverside Dental — critical expiry + NON-RESPONSIVE (17d), approved rate
        new Lease_Renewal__c(Tenant_Name__c='Riverside Dental', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit__c='Suite 120', Space_Sq_Ft__c=2200, Lease_Start__c=t.addDays(-1800), Lease_End__c=t.addDays(25), Current_Rent__c='$26.00 / sq ft NNN', Renewal_Option__c=false, Proposed_Rate__c=30.00, Approval_Status__c='Approved', Stage__c='Awaiting Tenant Response', Last_Contact_Date__c=t.addDays(-17)),
        // 1 Sunbelt Rentals — negotiating, option honored
        new Lease_Renewal__c(Tenant_Name__c='Sunbelt Rentals', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit__c='Bay 4', Space_Sq_Ft__c=5400, Lease_Start__c=t.addDays(-2500), Lease_End__c=t.addDays(70), Current_Rent__c='$18.00 / sq ft NNN', Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 5-yr option', Proposed_Rate__c=18.54, Option_Honored__c=true, Stage__c='Negotiating', Last_Contact_Date__c=t.addDays(-4)),
        // 2 Golden Wok — notice sent, option
        new Lease_Renewal__c(Tenant_Name__c='Golden Wok', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit__c='Unit 8', Space_Sq_Ft__c=1600, Lease_Start__c=t.addDays(-1090), Lease_End__c=t.addDays(49), Current_Rent__c='$24.00 / sq ft NNN', Renewal_Option__c=true, Preset_Terms__c='$25.20 flat, 3-yr option', Proposed_Rate__c=25.20, Option_Honored__c=true, Stage__c='Notice Sent', Last_Contact_Date__c=t.addDays(-12)),
        // 3 Pearl Nails — not started, needs approval (Pending, not yet escalated)
        new Lease_Renewal__c(Tenant_Name__c='Pearl Nails', Property_Asset__c=assets.get('Heights Marketplace').Id, Unit__c='Suite 3', Space_Sq_Ft__c=1200, Lease_Start__c=t.addDays(-1095), Lease_End__c=t.addDays(105), Current_Rent__c='$22.00 / sq ft NNN', Renewal_Option__c=false, Approval_Status__c='Pending', Stage__c='Not Yet Started'),
        // 4 Metro Urgent Care — not started, comfortable
        new Lease_Renewal__c(Tenant_Name__c='Metro Urgent Care', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit__c='Suite 200', Space_Sq_Ft__c=4200, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(151), Current_Rent__c='$28.00 / sq ft NNN', Renewal_Option__c=true, Preset_Terms__c='2.5% annual escalation, 5-yr option', Proposed_Rate__c=28.70, Option_Honored__c=true, Stage__c='Not Yet Started'),
        // 5 TechHub Coworking — escalated for approval (Pending)
        new Lease_Renewal__c(Tenant_Name__c='TechHub Coworking', Property_Asset__c=assets.get('Katy Mills Strip').Id, Unit__c='Floor 2', Space_Sq_Ft__c=8800, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(34), Current_Rent__c='$20.00 / sq ft NNN', Renewal_Option__c=false, Proposed_Rate__c=24.00, Approval_Status__c='Pending', Stage__c='Escalated for Approval', Last_Contact_Date__c=t.addDays(-7)),
        // 6 Bright Smiles Ortho — amendment drafted
        new Lease_Renewal__c(Tenant_Name__c='Bright Smiles Ortho', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit__c='Suite 210', Space_Sq_Ft__c=2600, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(85), Current_Rent__c='$27.00 / sq ft NNN', Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 5-yr option', Proposed_Rate__c=27.81, Option_Honored__c=true, Stage__c='Amendment Drafted', Last_Contact_Date__c=t.addDays(-2)),
        // 7 Cafe Verde — NON-RESPONSIVE (22d), far expiry
        new Lease_Renewal__c(Tenant_Name__c='Cafe Verde', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit__c='Bay 1', Space_Sq_Ft__c=1900, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(180), Current_Rent__c='$23.00 / sq ft NNN', Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 3-yr option', Proposed_Rate__c=23.69, Option_Honored__c=true, Stage__c='Notice Sent', Last_Contact_Date__c=t.addDays(-22)),
        // 8 Anytime Fitness — RENEWED (flow -> Closed Won + Renewed_Date = today)
        new Lease_Renewal__c(Tenant_Name__c='Anytime Fitness', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit__c='Anchor B', Space_Sq_Ft__c=9200, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(-2), Current_Rent__c='$16.00 / sq ft NNN', Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 5-yr option', Proposed_Rate__c=16.48, Option_Honored__c=true, Stage__c='Renewed', Last_Contact_Date__c=t.addDays(-14)),
        // 9 Dollar Depot — not renewing (flow -> Closed Lost)
        new Lease_Renewal__c(Tenant_Name__c='Dollar Depot', Property_Asset__c=assets.get('Katy Mills Strip').Id, Unit__c='Unit 12', Space_Sq_Ft__c=3100, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(60), Current_Rent__c='$19.00 / sq ft NNN', Renewal_Option__c=false, Proposed_Rate__c=23.00, Approval_Status__c='Approved', Stage__c='Not Renewing', Last_Contact_Date__c=t.addDays(-20)),
        // 10 Elite Barbers — vacating (flow -> Closed Lost)
        new Lease_Renewal__c(Tenant_Name__c='Elite Barbers', Property_Asset__c=assets.get('Heights Marketplace').Id, Unit__c='Suite 7', Space_Sq_Ft__c=900, Lease_Start__c=t.addDays(-1095), Lease_End__c=t.addDays(28), Current_Rent__c='$30.00 / sq ft NNN', Renewal_Option__c=false, Stage__c='Vacating', Last_Contact_Date__c=t.addDays(-26)),
        // 11 Prime Insurance — negotiating expansion
        new Lease_Renewal__c(Tenant_Name__c='Prime Insurance', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit__c='Suite 150', Space_Sq_Ft__c=2000, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(95), Current_Rent__c='$25.00 / sq ft NNN', Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 5-yr option', Proposed_Rate__c=26.50, Stage__c='Negotiating', Last_Contact_Date__c=t.addDays(-1))
    };
    insert rs;

    Datetime now = Datetime.now();
    List<Renewal_Activity__c> acts = new List<Renewal_Activity__c>();
    // helper-free: (renewal index, days ago, method, text)
    List<List<Object>> entries = new List<List<Object>>{
        new List<Object>{ 0, 35, 'System', 'Lease flagged for renewal — no pre-set renewal option on file. A new rate needs approval before outreach.' },
        new List<Object>{ 0, 28, 'Email',  'Sent renewal notice with a request to schedule a terms discussion.' },
        new List<Object>{ 0, 23, 'Call',   'Owner approved a proposed rate of $30.00/sq ft NNN, 5-yr term.' },
        new List<Object>{ 0, 17, 'Email',  'Emailed the $30.00/sq ft counter to the tenant. Awaiting their response.' },
        new List<Object>{ 1, 43, 'System', 'Renewal window opened — pre-set option in place: 3% annual escalation on a 5-year extension.' },
        new List<Object>{ 1, 21, 'Email',  'Sent the option-rate renewal notice at $18.54/sq ft. Tenant asked about TI for a dock upgrade.' },
        new List<Object>{ 1, 4,  'Call',   'Tenant wants $8/sq ft TI toward the dock. Weighing a longer term for the improvement allowance.' },
        new List<Object>{ 2, 31, 'System', 'Renewal flagged — pre-set option: $25.20/sq ft flat on a 3-year extension.' },
        new List<Object>{ 2, 12, 'Email',  'Delivered the renewal notice at the option rate. Owner reviewing next week.' },
        new List<Object>{ 3, 2,  'System', 'Lease flagged for renewal — 105 days to expiry. No pre-set option; new rate needs approval before outreach.' },
        new List<Object>{ 4, 7,  'System', 'Renewal window opened — 151 days out. Pre-set option in place. Ready to start outreach.' },
        new List<Object>{ 5, 48, 'System', 'Renewal flagged — no pre-set option. Market has moved; a new rate must be established.' },
        new List<Object>{ 5, 14, 'Visit',  'Met the operator on-site. They want to stay but pushed back on any increase above $22. Comps are at $24.' },
        new List<Object>{ 5, 7,  'Note',   'Escalated for approval — recommending $24.00/sq ft given current comps.' },
        new List<Object>{ 6, 34, 'System', 'Renewal flagged — pre-set 3% escalation option.' },
        new List<Object>{ 6, 18, 'Email',  'Tenant elected the renewal option at $27.81/sq ft. Aligned on a 5-year extension.' },
        new List<Object>{ 6, 2,  'Note',   'Amendment drafted with the option rate and updated dates. Sent for signature.' },
        new List<Object>{ 7, 30, 'System', 'Renewal window opened — pre-set 3% escalation option, 3-yr extension.' },
        new List<Object>{ 7, 22, 'Email',  'Sent the option-rate notice at $23.69/sq ft. No reply — followed up once with no response.' },
        new List<Object>{ 8, 73, 'System', 'Renewal flagged — pre-set 3% escalation option.' },
        new List<Object>{ 8, 41, 'Call',   'Tenant confirmed renewal at the option rate of $16.48/sq ft on a 5-year extension.' },
        new List<Object>{ 8, 14, 'Note',   'Amendment fully executed and entered into Yardi. Renewed — closed won.' },
        new List<Object>{ 9, 63, 'System', 'Renewal flagged — no pre-set option.' },
        new List<Object>{ 9, 35, 'Call',   'Owner approved a $23.00/sq ft renewal offer. Presented to the tenant.' },
        new List<Object>{ 9, 20, 'Email',  'Tenant declined — closing this location. Marked not renewing; unit returns to market.' },
        new List<Object>{ 10, 54, 'System', 'Renewal flagged — no pre-set option.' },
        new List<Object>{ 10, 26, 'Visit',  'Tenant confirmed in person they are relocating and will vacate at lease end.' },
        new List<Object>{ 11, 24, 'System', 'Renewal window opened — pre-set 3% escalation option available at $25.75/sq ft.' },
        new List<Object>{ 11, 12, 'Email',  'Tenant wants a larger footprint and will pay above the option rate. Exploring $26.50/sq ft with expansion.' },
        new List<Object>{ 11, 1,  'Call',   'Confirmed the adjacent suite frees up next month. Negotiating combined terms.' }
    };
    for (List<Object> e : entries) {
        acts.add(new Renewal_Activity__c(
            Lease_Renewal__c = rs[(Integer) e[0]].Id,
            Method__c = (String) e[2],
            Details__c = (String) e[3],
            Entry_Date__c = now.addDays(-(Integer) e[1])
        ));
    }
    insert acts;
    System.debug('Seeded ' + rs.size() + ' lease renewals with ' + acts.size() + ' timeline entries.');
}
```

- [ ] **Step 2: Run the seed**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf apex run -f scripts/seed-lease-renewals.apex --json
```
Expected: success:true.

- [ ] **Step 3: End-to-end verification**

1. Full test suite for the module + neighbors (regression):
```powershell
sf apex run test -n LeaseRenewalControllerTest -n LeaseInquiryControllerTest -n BrokerAssignmentControllerTest --wait 10 --result-format human
```
Expected: 100% pass.
2. KPI sanity via anonymous Apex:
```apex
LeaseRenewalController.HomeKpis k = LeaseRenewalController.getHomeKpis();
System.assertEquals(9, k.active, '12 seeded minus 3 closed');
System.assertEquals(2, k.nonResponsive, 'Riverside Dental + Cafe Verde');
System.assertEquals(1, k.renewedYtd, 'Anytime Fitness');
System.assert(k.expiring90 >= 4, 'several actives inside 90 days');
System.assertEquals(2, [SELECT COUNT() FROM Lease_Renewal__c WHERE Approval_Status__c='Pending' AND Status__c='Active']);
System.debug('E2E KPIS OK');
```
3. Remind the user (in the final report) to do the one manual UI step: on the Lease Renewal object tab, select the "Renewal Pipeline" list view → gear → **Display As → Kanban** (grouped by Stage) — Kanban display mode isn't metadata-deployable.

- [ ] **Step 4: Commit and push**

```powershell
git add scripts/seed-lease-renewals.apex
git commit -m "Lease Renewal Tracker: idempotent seed script (12 renewals, offset dates)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```
