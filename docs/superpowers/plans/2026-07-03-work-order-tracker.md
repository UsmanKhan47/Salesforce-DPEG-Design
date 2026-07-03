# Work Order Tracker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native, read-only Work Order Tracker module in the Property Management app: `Work_Order__c` with formula-driven SLA health, native Path/highlights/detail sections, a read-only activity timeline, home page, and dashboard — a Salesforce mirror of Yardi maintenance work orders.

**Architecture:** Two custom objects (`Work_Order__c` + MD child `Work_Order_Activity__c`) with formula SLA fields; native chrome (Path, compact-layout highlights, detail panel, list views); read-only everywhere except the one Salesforce-side `Delay_Reason__c` field; custom LWCs only for the read-only timeline and app-home widgets, all backed by one read-only Apex controller. Mirrors the Lease Renewal Tracker module minus its approval process and composer.

**Tech Stack:** Salesforce DX (`sf` CLI on Windows PowerShell), Apex, LWC, metadata XML. Org: scratch org `test-3iuncy5c1je5@example.com` (default).

**Spec:** `docs/superpowers/specs/2026-07-03-work-order-tracker-design.md`

## Global Constraints

- Branch: `feature/work-order-tracker`. Commit + push after every task. Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Run `Set-Location F:\Acquisition-Design-Salesforce` before EVERY `sf` command (PowerShell CWD drifts). Never append `2>&1` to `sf` commands. Add `-c` to deploys if a spurious `SourceConflictError` appears on already-committed/org-synced files (app, perm set, reports); new files also `-c`.
- Priority picklist: `Critical`, `High`, `Medium` (default), `Low`. Status picklist: `New` (default), `In Progress`, `On Hold`, `Completed`, `Closed`. Category: `HVAC`, `Plumbing`, `Electrical`, `Refrigeration`, `General`, `Doors & Locks`, `Landscaping`. Delay_Reason: `—` (default), `Vendor delay`, `Tenant unresponsive`, `Other`. Owner_Role: `Property Manager`, `Maintenance`. Activity Kind: `Sync`, `Status`, `Vendor`, `Note`, `Flag`.
- SLA tiers (hours): Critical 24, High 48, Medium 168, Low 360. **Due-soon window = final 30%** of the SLA window, hardcoded ONLY in `SLA_Health__c`.
- `Status__c` metadata `<required>false</required>` and NOT on the page layout (Path + highlights manage it; auto-inject gotcha); grant FLS in perm set.
- Required fields (`Subject__c`, `Reported_Date__c`) get NO `fieldPermissions` entries; nor does the master-detail field `Work_Order_Activity__c.Work_Order__c`.
- Every layout field is `Readonly` EXCEPT `Delay_Reason__c` (`Edit`). No New/Submit/Clone actions — read-only mirror.
- `formulaTreatBlanksAs` valid enum is **`BlankAsBlank`** (singular), never `BlankAsBlanks`.
- Flexipages: exactly ONE `<componentInstance>` per `<itemInstances>`. RecordPage-target LWC `targetConfig` must NOT include `objects=`.
- Priority accents: Critical `#B01818`, High `#9A4B00`, Medium `#8B6800`, Low `#5A5752`. Status accents: New `#4A71B8`, In Progress `#1A3464`, On Hold `#C88010`, Completed `#198A40`, Closed `#8A8680`. Kind badge colors: Sync `#5A5752`/`#EDEBE7`, Status `#1A3464`/`#E8EFF7`, Vendor `#9A4B00`/`#FDF2E7`, Note `#132850`/`#E8EFF7`, Flag `#1A4880`/`#EBF3FC`. KPI icon colors: Open `#7A9ED4`, Breached `#E58A8A`, Due Soon `#D8BE72`, Untouched `#B39DDB`.
- Apex tests: never assert timestamp ORDER between rows created in the same test (frozen clock); order queries `Entry_Date__c DESC NULLS LAST, Name DESC` and assert on content.
- Reports: `reportType` is `CustomEntity$Work_Order__c`; report columns prefixed `Work_Order__c.`; dashboard bar `componentType` is `Bar` (not HorizontalBar) with `<chartAxisRange>Auto</chartAxisRange>`; report `<sortColumn>`/`<sortOrder>` go at the end of the Report element.

## File Structure

```
force-app/main/default/
  objects/Work_Order__c/               # object + fields + compact layout + 5 list views (Task 1)
  objects/Work_Order_Activity__c/      # MD child + 4 fields (Task 1)
  flows/Work_Order_Touch_Sync.flow-meta.xml                (Task 2)
  classes/WorkOrderController.cls(+meta)                    (Task 3)
  classes/WorkOrderControllerTest.cls(+meta)               (Task 3)
  layouts/Work_Order__c-Work Order Layout.layout-meta.xml  (Task 4)
  pathAssistants/Work_Order_Path.pathAssistant-meta.xml    (Task 4)
  lwc/workOrderTimeline/               # read-only record-page timeline (Task 5)
  flexipages/Work_Order_Record_Page.flexipage-meta.xml     (Task 5)
  applications/Property_Management.app-meta.xml            (modified Tasks 5+7)
  lwc/workOrderKpis/ lwc/workOrderList/ lwc/workOrderEscalations/ lwc/workOrderUntouched/ (Task 6)
  flexipages/Work_Orders_Home.flexipage-meta.xml           (Task 7)
  tabs/Work_Orders.tab-meta.xml  tabs/Work_Order__c.tab-meta.xml (Task 7)
  permissionsets/Property_Management_Access.permissionset-meta.xml (modified Tasks 1,3,7)
  reports/Work_Orders/  dashboards/Work_Orders/            (Task 8)
scripts/seed-work-orders.apex                              (Task 9)
```

---

### Task 1: Objects, fields, list views, compact layout, perm set FLS

**Files:**
- Create: `force-app/main/default/objects/Work_Order__c/Work_Order__c.object-meta.xml`
- Create: `force-app/main/default/objects/Work_Order__c/fields/*.field-meta.xml` (24 files below)
- Create: `force-app/main/default/objects/Work_Order__c/compactLayouts/Work_Order_Compact.compactLayout-meta.xml`
- Create: `force-app/main/default/objects/Work_Order__c/listViews/{My_Open_Work_Orders,Escalations,Breached_SLA,Untouched,All_Work_Orders}.listView-meta.xml`
- Create: `force-app/main/default/objects/Work_Order_Activity__c/Work_Order_Activity__c.object-meta.xml`
- Create: `force-app/main/default/objects/Work_Order_Activity__c/fields/{Work_Order__c,Kind__c,Detail__c,Entry_Date__c,Actor__c}.field-meta.xml`
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Produces: object/field API names exactly as written here; every later task depends on them verbatim.

- [ ] **Step 1: Write `Work_Order__c` object + compact layout**

`objects/Work_Order__c/Work_Order__c.object-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <compactLayoutAssignment>Work_Order_Compact</compactLayoutAssignment>
    <deploymentStatus>Deployed</deploymentStatus>
    <description>A maintenance work order mirrored read-only from Yardi. Salesforce never writes back except the Delay Reason flag.</description>
    <enableActivities>false</enableActivities>
    <enableHistory>true</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <label>Work Order</label>
    <pluralLabel>Work Orders</pluralLabel>
    <nameField>
        <displayFormat>WO-{0000}</displayFormat>
        <label>Work Order Number</label>
        <type>AutoNumber</type>
    </nameField>
    <sharingModel>ReadWrite</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
```

`objects/Work_Order__c/compactLayouts/Work_Order_Compact.compactLayout-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CompactLayout xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Work_Order_Compact</fullName>
    <fields>Subject__c</fields>
    <fields>Priority__c</fields>
    <fields>Status__c</fields>
    <fields>SLA_Health__c</fields>
    <fields>SLA_Due_Date__c</fields>
    <label>Work Order Compact</label>
</CompactLayout>
```

- [ ] **Step 2: Write the 24 `Work_Order__c` fields**

Each file at `objects/Work_Order__c/fields/<FullName>.field-meta.xml` with the wrapper:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    ...body...
</CustomField>
```
Bodies:

`Subject__c`:
```xml
    <fullName>Subject__c</fullName>
    <label>Subject</label>
    <length>120</length>
    <required>true</required>
    <type>Text</type>
    <unique>false</unique>
```
`Description__c`:
```xml
    <fullName>Description__c</fullName>
    <description>The tenant's own words describing the problem.</description>
    <label>Description</label>
    <length>4000</length>
    <type>LongTextArea</type>
    <visibleLines>4</visibleLines>
```
`Category__c`:
```xml
    <fullName>Category__c</fullName>
    <label>Category</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>HVAC</fullName><default>false</default><label>HVAC</label></value>
            <value><fullName>Plumbing</fullName><default>false</default><label>Plumbing</label></value>
            <value><fullName>Electrical</fullName><default>false</default><label>Electrical</label></value>
            <value><fullName>Refrigeration</fullName><default>false</default><label>Refrigeration</label></value>
            <value><fullName>General</fullName><default>false</default><label>General</label></value>
            <value><fullName>Doors &amp; Locks</fullName><default>false</default><label>Doors &amp; Locks</label></value>
            <value><fullName>Landscaping</fullName><default>false</default><label>Landscaping</label></value>
        </valueSetDefinition>
    </valueSet>
```
`Priority__c`:
```xml
    <fullName>Priority__c</fullName>
    <label>Priority</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Critical</fullName><default>false</default><label>Critical</label></value>
            <value><fullName>High</fullName><default>false</default><label>High</label></value>
            <value><fullName>Medium</fullName><default>true</default><label>Medium</label></value>
            <value><fullName>Low</fullName><default>false</default><label>Low</label></value>
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
            <value><fullName>New</fullName><default>true</default><label>New</label></value>
            <value><fullName>In Progress</fullName><default>false</default><label>In Progress</label></value>
            <value><fullName>On Hold</fullName><default>false</default><label>On Hold</label></value>
            <value><fullName>Completed</fullName><default>false</default><label>Completed</label></value>
            <value><fullName>Closed</fullName><default>false</default><label>Closed</label></value>
        </valueSetDefinition>
    </valueSet>
```
`Property_Asset__c`:
```xml
    <fullName>Property_Asset__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <label>Property</label>
    <referenceTo>Property_Asset__c</referenceTo>
    <relationshipLabel>Work Orders</relationshipLabel>
    <relationshipName>Work_Orders</relationshipName>
    <required>false</required>
    <type>Lookup</type>
```
`Property_Display_Name__c`:
```xml
    <fullName>Property_Display_Name__c</fullName>
    <description>Property name spanned from the linked Property Asset for lists and reports.</description>
    <formula>Property_Asset__r.Name</formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
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
`Tenant_Name__c`:
```xml
    <fullName>Tenant_Name__c</fullName>
    <label>Tenant</label>
    <length>120</length>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
```
`Vendor__c`:
```xml
    <fullName>Vendor__c</fullName>
    <label>Vendor</label>
    <length>120</length>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
```
`Owner_User__c`:
```xml
    <fullName>Owner_User__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <label>Owner</label>
    <referenceTo>User</referenceTo>
    <relationshipName>Owned_Work_Orders</relationshipName>
    <required>false</required>
    <type>Lookup</type>
```
`Owner_Role__c`:
```xml
    <fullName>Owner_Role__c</fullName>
    <label>Owner Role</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Property Manager</fullName><default>false</default><label>Property Manager</label></value>
            <value><fullName>Maintenance</fullName><default>false</default><label>Maintenance</label></value>
        </valueSetDefinition>
    </valueSet>
```
`Reported_Date__c`:
```xml
    <fullName>Reported_Date__c</fullName>
    <description>When the work order was reported/synced from Yardi. Anchors all SLA math (used instead of CreatedDate so seed offsets are deterministic).</description>
    <label>Reported Date</label>
    <required>true</required>
    <type>DateTime</type>
```
`First_Touched_Date__c`:
```xml
    <fullName>First_Touched_Date__c</fullName>
    <description>When someone first acted on this work order. Blank means Untouched.</description>
    <label>First Touched</label>
    <required>false</required>
    <type>DateTime</type>
```
`Completed_Date__c`:
```xml
    <fullName>Completed_Date__c</fullName>
    <label>Completed Date</label>
    <required>false</required>
    <type>DateTime</type>
```
`Delay_Reason__c` (the ONLY editable field):
```xml
    <fullName>Delay_Reason__c</fullName>
    <description>Salesforce-only flag for WHY this is stuck. Never written back to Yardi.</description>
    <label>Reason for Delay</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>—</fullName><default>true</default><label>—</label></value>
            <value><fullName>Vendor delay</fullName><default>false</default><label>Vendor delay</label></value>
            <value><fullName>Tenant unresponsive</fullName><default>false</default><label>Tenant unresponsive</label></value>
            <value><fullName>Other</fullName><default>false</default><label>Other</label></value>
        </valueSetDefinition>
    </valueSet>
```
`SLA_Target_Hours__c`:
```xml
    <fullName>SLA_Target_Hours__c</fullName>
    <description>SLA window in hours by priority: Critical 24, High 48, Medium 168, Low 360.</description>
    <formula>CASE(TEXT(Priority__c), "Critical", 24, "High", 48, "Medium", 168, "Low", 360, 168)</formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <label>SLA Target (Hours)</label>
    <precision>6</precision>
    <required>false</required>
    <scale>0</scale>
    <type>Number</type>
    <unique>false</unique>
```
`SLA_Due_Date__c`:
```xml
    <fullName>SLA_Due_Date__c</fullName>
    <formula>Reported_Date__c + (SLA_Target_Hours__c / 24)</formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <label>SLA Due</label>
    <required>false</required>
    <type>DateTime</type>
```
`Hours_Open__c`:
```xml
    <fullName>Hours_Open__c</fullName>
    <formula>IF(OR(ISPICKVAL(Status__c, "Completed"), ISPICKVAL(Status__c, "Closed")), IF(ISBLANK(Completed_Date__c), 0, (Completed_Date__c - Reported_Date__c) * 24), (NOW() - Reported_Date__c) * 24)</formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <label>Hours Open</label>
    <precision>9</precision>
    <required>false</required>
    <scale>0</scale>
    <type>Number</type>
    <unique>false</unique>
```
`Is_Open__c`:
```xml
    <fullName>Is_Open__c</fullName>
    <formula>NOT(OR(ISPICKVAL(Status__c, "Completed"), ISPICKVAL(Status__c, "Closed")))</formula>
    <label>Is Open</label>
    <type>Checkbox</type>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
```
`SLA_Health__c`:
```xml
    <fullName>SLA_Health__c</fullName>
    <description>Resolved when closed; else Breached past due; else Due Soon in the final 30% of the SLA window; else On Track. The 30% due-soon window is the one working assumption — change it here only.</description>
    <formula>IF(NOT(Is_Open__c), "🟢 Resolved", IF(NOW() &gt; SLA_Due_Date__c, "🔴 Breached", IF((SLA_Due_Date__c - NOW()) * 24 &lt;= 0.30 * SLA_Target_Hours__c, "🟡 Due Soon", "🟢 On Track")))</formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <label>SLA Health</label>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
```
`SLA_Breached__c`:
```xml
    <fullName>SLA_Breached__c</fullName>
    <formula>AND(Is_Open__c, NOW() &gt; SLA_Due_Date__c)</formula>
    <label>SLA Breached</label>
    <type>Checkbox</type>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
```
`Untouched__c`:
```xml
    <fullName>Untouched__c</fullName>
    <formula>AND(Is_Open__c, ISBLANK(First_Touched_Date__c))</formula>
    <label>Untouched</label>
    <type>Checkbox</type>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
```
`Is_Escalation__c`:
```xml
    <fullName>Is_Escalation__c</fullName>
    <description>A breached, still-open Critical or High work order — surfaces on the Escalations view.</description>
    <formula>AND(SLA_Breached__c, OR(ISPICKVAL(Priority__c, "Critical"), ISPICKVAL(Priority__c, "High")))</formula>
    <label>Is Escalation</label>
    <type>Checkbox</type>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
```

- [ ] **Step 3: Write the 5 list views**

`objects/Work_Order__c/listViews/My_Open_Work_Orders.listView-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>My_Open_Work_Orders</fullName>
    <columns>NAME</columns>
    <columns>Subject__c</columns>
    <columns>Property_Display_Name__c</columns>
    <columns>Priority__c</columns>
    <columns>Status__c</columns>
    <columns>SLA_Health__c</columns>
    <columns>Hours_Open__c</columns>
    <columns>Owner_User__c</columns>
    <filters>
        <field>Is_Open__c</field>
        <operation>equals</operation>
        <value>1</value>
    </filters>
    <filterScope>Everything</filterScope>
    <label>My Open Work Orders</label>
</ListView>
```
`Escalations.listView-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Escalations</fullName>
    <columns>NAME</columns>
    <columns>Subject__c</columns>
    <columns>Property_Display_Name__c</columns>
    <columns>Priority__c</columns>
    <columns>Status__c</columns>
    <columns>SLA_Health__c</columns>
    <columns>Hours_Open__c</columns>
    <filters>
        <field>Is_Escalation__c</field>
        <operation>equals</operation>
        <value>1</value>
    </filters>
    <filterScope>Everything</filterScope>
    <label>Escalations</label>
</ListView>
```
`Breached_SLA.listView-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Breached_SLA</fullName>
    <columns>NAME</columns>
    <columns>Subject__c</columns>
    <columns>Property_Display_Name__c</columns>
    <columns>Priority__c</columns>
    <columns>Status__c</columns>
    <columns>Hours_Open__c</columns>
    <filters>
        <field>SLA_Breached__c</field>
        <operation>equals</operation>
        <value>1</value>
    </filters>
    <filterScope>Everything</filterScope>
    <label>Breached SLA</label>
</ListView>
```
`Untouched.listView-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Untouched</fullName>
    <columns>NAME</columns>
    <columns>Subject__c</columns>
    <columns>Property_Display_Name__c</columns>
    <columns>Priority__c</columns>
    <columns>Reported_Date__c</columns>
    <columns>SLA_Health__c</columns>
    <filters>
        <field>Untouched__c</field>
        <operation>equals</operation>
        <value>1</value>
    </filters>
    <filterScope>Everything</filterScope>
    <label>Untouched</label>
</ListView>
```
`All_Work_Orders.listView-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ListView xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>All_Work_Orders</fullName>
    <columns>NAME</columns>
    <columns>Subject__c</columns>
    <columns>Property_Display_Name__c</columns>
    <columns>Category__c</columns>
    <columns>Priority__c</columns>
    <columns>Status__c</columns>
    <columns>SLA_Health__c</columns>
    <columns>Owner_User__c</columns>
    <filterScope>Everything</filterScope>
    <label>All Work Orders</label>
</ListView>
```

- [ ] **Step 4: Write `Work_Order_Activity__c` object + fields**

`objects/Work_Order_Activity__c/Work_Order_Activity__c.object-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <deploymentStatus>Deployed</deploymentStatus>
    <description>Read-only status/activity history entry on a Work Order, from the Yardi sync. Never edited in Salesforce.</description>
    <enableActivities>false</enableActivities>
    <enableHistory>false</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <label>Work Order Activity</label>
    <pluralLabel>Work Order Activities</pluralLabel>
    <nameField>
        <displayFormat>WOA-{0000}</displayFormat>
        <label>Activity Number</label>
        <type>AutoNumber</type>
    </nameField>
    <sharingModel>ControlledByParent</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
```
Fields (same `<CustomField>` wrapper):

`Work_Order__c`:
```xml
    <fullName>Work_Order__c</fullName>
    <label>Work Order</label>
    <referenceTo>Work_Order__c</referenceTo>
    <relationshipLabel>Work Order Activities</relationshipLabel>
    <relationshipName>Work_Order_Activities</relationshipName>
    <relationshipOrder>0</relationshipOrder>
    <reparentableMasterDetail>false</reparentableMasterDetail>
    <type>MasterDetail</type>
    <writeRequiresMasterRead>false</writeRequiresMasterRead>
```
`Kind__c`:
```xml
    <fullName>Kind__c</fullName>
    <label>Kind</label>
    <required>false</required>
    <type>Picklist</type>
    <valueSet>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Sync</fullName><default>true</default><label>Sync</label></value>
            <value><fullName>Status</fullName><default>false</default><label>Status</label></value>
            <value><fullName>Vendor</fullName><default>false</default><label>Vendor</label></value>
            <value><fullName>Note</fullName><default>false</default><label>Note</label></value>
            <value><fullName>Flag</fullName><default>false</default><label>Flag</label></value>
        </valueSetDefinition>
    </valueSet>
```
`Detail__c`:
```xml
    <fullName>Detail__c</fullName>
    <label>Detail</label>
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
`Actor__c`:
```xml
    <fullName>Actor__c</fullName>
    <description>Who/what produced the entry — "Yardi" or a person's name.</description>
    <label>Actor</label>
    <length>120</length>
    <required>false</required>
    <type>Text</type>
    <unique>false</unique>
```

- [ ] **Step 5: Add object perms + FLS to the perm set**

In `permissionsets/Property_Management_Access.permissionset-meta.xml`, add within the existing element groups (keep ordering: classAccesses…fieldPermissions…objectPermissions…tabSettings):

Two `objectPermissions`:
```xml
    <objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>true</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Work_Order__c</object>
        <viewAllRecords>true</viewAllRecords>
    </objectPermissions>
    <objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>true</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Work_Order_Activity__c</object>
        <viewAllRecords>true</viewAllRecords>
    </objectPermissions>
```
`fieldPermissions` (editable=true, readable=true) for every NON-required, NON-formula, NON-MD field:
`Work_Order__c`: `Category__c`, `Priority__c`, `Status__c`, `Property_Asset__c`, `Unit__c`, `Tenant_Name__c`, `Vendor__c`, `Owner_User__c`, `Owner_Role__c`, `First_Touched_Date__c`, `Completed_Date__c`, `Delay_Reason__c`, `Description__c`; and `Work_Order_Activity__c`: `Kind__c`, `Detail__c`, `Entry_Date__c`, `Actor__c`.
`fieldPermissions` (readable-only, `editable=false`) for the formula fields: `Property_Display_Name__c`, `SLA_Target_Hours__c`, `SLA_Due_Date__c`, `Hours_Open__c`, `Is_Open__c`, `SLA_Health__c`, `SLA_Breached__c`, `Untouched__c`, `Is_Escalation__c`.
Pattern:
```xml
    <fieldPermissions>
        <editable>true</editable>
        <field>Work_Order__c.Status__c</field>
        <readable>true</readable>
    </fieldPermissions>
```
Do NOT add `Subject__c`, `Reported_Date__c` (required) or `Work_Order_Activity__c.Work_Order__c` (MD).

- [ ] **Step 6: Deploy and verify**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/objects/Work_Order__c -d force-app/main/default/objects/Work_Order_Activity__c -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml --json
```
Expected: `"status": "Succeeded"`. Then smoke-test (write to a scratch .apex file, run `sf apex run -f <file> --json`):
```apex
Property__c pr = new Property__c(Name='WO Verify Prop', Address__c='1 Test', City__c='Houston', State__c='TX', Square_Footage__c=10000, Asset_Type__c='Retail');
insert pr;
Property_Asset__c pa = new Property_Asset__c(Name='WO Verify Asset', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active');
insert pa;
Work_Order__c w = new Work_Order__c(Subject__c='AC down', Property_Asset__c=pa.Id, Priority__c='Critical', Status__c='In Progress', Reported_Date__c=Datetime.now().addHours(-30));
insert w;
w = [SELECT SLA_Target_Hours__c, SLA_Due_Date__c, Hours_Open__c, Is_Open__c, SLA_Health__c, SLA_Breached__c, Is_Escalation__c, Untouched__c FROM Work_Order__c WHERE Id=:w.Id];
System.assertEquals(24, w.SLA_Target_Hours__c);
System.assertEquals(true, w.SLA_Breached__c, 'reported 30h ago on a 24h SLA is breached');
System.assertEquals(true, w.Is_Escalation__c, 'Critical + breached');
System.assert(w.SLA_Health__c.contains('Breached'));
insert new Work_Order_Activity__c(Work_Order__c=w.Id, Kind__c='Sync', Detail__c='created', Entry_Date__c=Datetime.now());
delete w; delete pa; delete pr;  // MD child cascades
System.debug('SMOKE OK');
```
Expected: success, `SMOKE OK`.

- [ ] **Step 7: Commit and push**

```powershell
git add force-app/main/default/objects/Work_Order__c force-app/main/default/objects/Work_Order_Activity__c force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "Work Order Tracker: Work_Order__c + Work_Order_Activity__c objects, formula SLA, list views, FLS" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 2: Touch-sync flow

**Files:**
- Create: `force-app/main/default/flows/Work_Order_Touch_Sync.flow-meta.xml`

**Interfaces:**
- Consumes: `Work_Order__c.Status__c/First_Touched_Date__c/Completed_Date__c` (Task 1).
- Produces: guarantee used by Task 3 tests and Task 9 seed — a non-New status stamps First_Touched (if blank); a Completed/Closed status stamps Completed_Date (if blank). Keeps `Untouched__c` and the Resolved health honest.

- [ ] **Step 1: Write the flow**

`flows/Work_Order_Touch_Sync.flow-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Flow xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <assignments>
        <name>Stamp_First_Touched</name>
        <label>Stamp First Touched</label>
        <locationX>176</locationX>
        <locationY>288</locationY>
        <assignmentItems>
            <assignToReference>$Record.First_Touched_Date__c</assignToReference>
            <operator>Assign</operator>
            <value><elementReference>$Flow.CurrentDateTime</elementReference></value>
        </assignmentItems>
        <connector><targetReference>Completed_Check</targetReference></connector>
    </assignments>
    <assignments>
        <name>Stamp_Completed</name>
        <label>Stamp Completed</label>
        <locationX>132</locationX>
        <locationY>504</locationY>
        <assignmentItems>
            <assignToReference>$Record.Completed_Date__c</assignToReference>
            <operator>Assign</operator>
            <value><elementReference>$Flow.CurrentDateTime</elementReference></value>
        </assignmentItems>
    </assignments>
    <decisions>
        <name>Needs_First_Touch</name>
        <label>Needs First Touch?</label>
        <locationX>176</locationX>
        <locationY>180</locationY>
        <defaultConnectorLabel>No</defaultConnectorLabel>
        <defaultConnector><targetReference>Completed_Check</targetReference></defaultConnector>
        <rules>
            <name>Touch</name>
            <conditionLogic>and</conditionLogic>
            <conditions>
                <leftValueReference>$Record.Status__c</leftValueReference>
                <operator>NotEqualTo</operator>
                <rightValue><stringValue>New</stringValue></rightValue>
            </conditions>
            <conditions>
                <leftValueReference>$Record.First_Touched_Date__c</leftValueReference>
                <operator>IsNull</operator>
                <rightValue><booleanValue>true</booleanValue></rightValue>
            </conditions>
            <connector><targetReference>Stamp_First_Touched</targetReference></connector>
            <label>Touch</label>
        </rules>
    </decisions>
    <decisions>
        <name>Completed_Check</name>
        <label>Needs Completed Date?</label>
        <locationX>132</locationX>
        <locationY>396</locationY>
        <defaultConnectorLabel>No</defaultConnectorLabel>
        <rules>
            <name>Stamp</name>
            <conditionLogic>and</conditionLogic>
            <conditions>
                <leftValueReference>$Record.Completed_Date__c</leftValueReference>
                <operator>IsNull</operator>
                <rightValue><booleanValue>true</booleanValue></rightValue>
            </conditions>
            <conditions>
                <leftValueReference>$Record.Is_Open__c</leftValueReference>
                <operator>EqualTo</operator>
                <rightValue><booleanValue>false</booleanValue></rightValue>
            </conditions>
            <connector><targetReference>Stamp_Completed</targetReference></connector>
            <label>Stamp</label>
        </rules>
    </decisions>
    <environments>Default</environments>
    <interviewLabel>Work Order Touch Sync {!$Flow.CurrentDateTime}</interviewLabel>
    <label>Work Order Touch Sync</label>
    <processType>AutoLaunchedFlow</processType>
    <start>
        <locationX>50</locationX>
        <locationY>0</locationY>
        <connector><targetReference>Needs_First_Touch</targetReference></connector>
        <object>Work_Order__c</object>
        <recordTriggerType>CreateAndUpdate</recordTriggerType>
        <triggerType>RecordBeforeSave</triggerType>
    </start>
    <status>Active</status>
</Flow>
```
Note: `Is_Open__c` is a formula field available in before-save context (formula fields are computed for the in-memory record), so the `Completed_Check` decision reads it correctly. `EqualTo false` means the status is Completed or Closed.

- [ ] **Step 2: Deploy**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/flows/Work_Order_Touch_Sync.flow-meta.xml --json
```
Expected: Succeeded.

- [ ] **Step 3: Verify with anonymous Apex**

```apex
Property__c pr = new Property__c(Name='Flow WO Prop', Address__c='1 Test', City__c='Houston', State__c='TX', Square_Footage__c=10000, Asset_Type__c='Retail');
insert pr;
Property_Asset__c pa = new Property_Asset__c(Name='Flow WO Asset', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active');
insert pa;
// New with no touch -> stays untouched
Work_Order__c a = new Work_Order__c(Subject__c='New one', Property_Asset__c=pa.Id, Priority__c='Low', Status__c='New', Reported_Date__c=Datetime.now().addHours(-2));
insert a;
a = [SELECT First_Touched_Date__c, Untouched__c FROM Work_Order__c WHERE Id=:a.Id];
System.assertEquals(null, a.First_Touched_Date__c);
System.assertEquals(true, a.Untouched__c);
// Move to In Progress -> first touch stamped
a.Status__c = 'In Progress'; update a;
a = [SELECT First_Touched_Date__c, Untouched__c FROM Work_Order__c WHERE Id=:a.Id];
System.assertNotEquals(null, a.First_Touched_Date__c);
System.assertEquals(false, a.Untouched__c);
// Complete -> completed date stamped
a.Status__c = 'Completed'; update a;
a = [SELECT Completed_Date__c, Is_Open__c FROM Work_Order__c WHERE Id=:a.Id];
System.assertNotEquals(null, a.Completed_Date__c);
System.assertEquals(false, a.Is_Open__c);
delete a; delete pa; delete pr;
System.debug('FLOW OK');
```
Expected: `FLOW OK`.

- [ ] **Step 4: Commit and push**

```powershell
git add force-app/main/default/flows/Work_Order_Touch_Sync.flow-meta.xml
git commit -m "Work Order Tracker: touch-sync flow (first-touched + completed stamps)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 3: WorkOrderController + tests

**Files:**
- Create: `force-app/main/default/classes/WorkOrderController.cls` + `.cls-meta.xml`
- Create: `force-app/main/default/classes/WorkOrderControllerTest.cls` + `.cls-meta.xml`
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml` (add classAccess)

**Interfaces:**
- Consumes: objects/fields (Task 1), touch-sync flow (Task 2).
- Produces (LWCs in Tasks 5–6 import these exact names):
  - `getHomeKpis()` → `{open, breached, dueSoon, untouched}` (Integers)
  - `getRecentWorkOrders()` / `getEscalations()` / `getUntouched()` → `List<Row>`; Row = `{id, subject, property, unit, priority, status, slaHealth, hoursOpen(Integer), breached(Boolean), untouched(Boolean), isOpen(Boolean)}`
  - `getActivity(Id workOrderId)` → `{entries:[{id, kind, detail, actor, entryDate(Datetime)}], untouched(Boolean)}`

- [ ] **Step 1: Write the test class (TDD — this defines the contract)**

`classes/WorkOrderControllerTest.cls`:
```apex
@isTest
private class WorkOrderControllerTest {
    @testSetup static void setup() {
        Property__c pr = new Property__c(Name='Westgate Plaza', Address__c='8420 Westheimer Rd', City__c='Houston', State__c='TX', Square_Footage__c=42000, Asset_Type__c='Retail');
        insert pr;
        Property_Asset__c pa = new Property_Asset__c(Name='Westgate Plaza', Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active');
        insert pa;
        Datetime n = Datetime.now();
        // w1 Critical breached+escalation (30h ago, 24h SLA), In Progress
        // w2 High new + untouched (2h ago), on track
        // w3 Medium due-soon (160h ago on 168h SLA) In Progress
        // w4 Low resolved (Completed)
        // w5 Critical resolved (Closed)
        List<Work_Order__c> ws = new List<Work_Order__c>{
            new Work_Order__c(Subject__c='AC down', Property_Asset__c=pa.Id, Unit__c='Suite 120', Category__c='HVAC', Priority__c='Critical', Status__c='In Progress', Reported_Date__c=n.addHours(-30), First_Touched_Date__c=n.addHours(-29), Delay_Reason__c='Vendor delay'),
            new Work_Order__c(Subject__c='Lot lights out', Property_Asset__c=pa.Id, Unit__c='Common', Category__c='Electrical', Priority__c='High', Status__c='New', Reported_Date__c=n.addHours(-2)),
            new Work_Order__c(Subject__c='Faucet drip', Property_Asset__c=pa.Id, Unit__c='Suite 200', Category__c='Plumbing', Priority__c='Medium', Status__c='In Progress', Reported_Date__c=n.addHours(-160), First_Touched_Date__c=n.addHours(-150)),
            new Work_Order__c(Subject__c='Outlet dead', Property_Asset__c=pa.Id, Unit__c='Unit 8', Category__c='Electrical', Priority__c='Low', Status__c='Completed', Reported_Date__c=n.addHours(-100), First_Touched_Date__c=n.addHours(-90), Completed_Date__c=n.addHours(-20)),
            new Work_Order__c(Subject__c='RTU failure', Property_Asset__c=pa.Id, Unit__c='Suite 120', Category__c='HVAC', Priority__c='Critical', Status__c='Closed', Reported_Date__c=n.addHours(-300), First_Touched_Date__c=n.addHours(-299), Completed_Date__c=n.addHours(-280))
        };
        insert ws;
        insert new List<Work_Order_Activity__c>{
            new Work_Order_Activity__c(Work_Order__c=ws[0].Id, Kind__c='Sync', Actor__c='Yardi', Detail__c='Created from tenant call.', Entry_Date__c=n.addHours(-30)),
            new Work_Order_Activity__c(Work_Order__c=ws[0].Id, Kind__c='Vendor', Actor__c='Yardi', Detail__c='Vendor assigned: Gulf Coast HVAC.', Entry_Date__c=n.addHours(-28))
        };
    }
    private static Work_Order__c bySubject(String s) {
        return [SELECT Id, Status__c, First_Touched_Date__c, Completed_Date__c FROM Work_Order__c WHERE Subject__c = :s LIMIT 1];
    }

    @isTest static void homeKpis() {
        WorkOrderController.HomeKpis k = WorkOrderController.getHomeKpis();
        System.assertEquals(3, k.open, 'w1, w2, w3 are open');
        System.assertEquals(1, k.breached, 'only w1 is breached (w3 medium still within 168h)');
        System.assertEquals(1, k.dueSoon, 'w3 at 160/168h is inside the final 30% window');
        System.assertEquals(1, k.untouched, 'w2 is New with no first-touch');
    }
    @isTest static void recentCapsAtSix() {
        Property_Asset__c pa = [SELECT Id FROM Property_Asset__c LIMIT 1];
        List<Work_Order__c> extra = new List<Work_Order__c>();
        for (Integer i = 0; i < 4; i++) {
            extra.add(new Work_Order__c(Subject__c='Extra ' + i, Property_Asset__c=pa.Id, Priority__c='Low', Status__c='New', Reported_Date__c=Datetime.now().addHours(-i)));
        }
        insert extra;
        List<WorkOrderController.Row> rows = WorkOrderController.getRecentWorkOrders();
        System.assertEquals(6, rows.size(), 'capped at 6 open');
        System.assertEquals('Westgate Plaza', rows[0].property, 'property name spans from the asset');
    }
    @isTest static void escalationsOnlyCriticalHighBreached() {
        List<WorkOrderController.Row> rows = WorkOrderController.getEscalations();
        System.assertEquals(1, rows.size());
        System.assertEquals('AC down', rows[0].subject);
        System.assertEquals(true, rows[0].breached);
    }
    @isTest static void untouchedList() {
        List<WorkOrderController.Row> rows = WorkOrderController.getUntouched();
        System.assertEquals(1, rows.size());
        System.assertEquals('Lot lights out', rows[0].subject);
        System.assertEquals(true, rows[0].untouched);
    }
    @isTest static void activityNewestFirstWithContext() {
        WorkOrderController.ActivityView v = WorkOrderController.getActivity(bySubject('AC down').Id);
        System.assertEquals(2, v.entries.size());
        System.assertEquals('Vendor', v.entries[0].kind, 'newest (by Entry_Date__c) first');
        System.assertEquals('Yardi', v.entries[0].actor);
        System.assertEquals(false, v.untouched, 'AC down has a first-touch');
    }
    @isTest static void activityEmptyForUntouched() {
        WorkOrderController.ActivityView v = WorkOrderController.getActivity(bySubject('Lot lights out').Id);
        System.assertEquals(0, v.entries.size());
        System.assertEquals(true, v.untouched);
    }
    @isTest static void resolvedCountsInKpiOpenExcluded() {
        // w4 Completed + w5 Closed are excluded from open KPIs and lists.
        for (WorkOrderController.Row r : WorkOrderController.getRecentWorkOrders()) {
            System.assertEquals(true, r.isOpen, 'recent list is open-only');
        }
    }
}
```
`classes/WorkOrderControllerTest.cls-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Write the controller**

`classes/WorkOrderController.cls`:
```apex
/**
 * Backs the read-only Work Order Tracker: home-page widgets and the record-page
 * activity timeline. No mutation methods — work orders are managed in Yardi.
 */
public with sharing class WorkOrderController {

    private static final String ROW_QUERY =
        'SELECT Id, Subject__c, Property_Display_Name__c, Unit__c, Priority__c, Status__c, ' +
        'SLA_Health__c, Hours_Open__c, SLA_Breached__c, Untouched__c, Is_Open__c ' +
        'FROM Work_Order__c ';

    public class HomeKpis {
        @AuraEnabled public Integer open;
        @AuraEnabled public Integer breached;
        @AuraEnabled public Integer dueSoon;
        @AuraEnabled public Integer untouched;
    }
    @AuraEnabled(cacheable=true)
    public static HomeKpis getHomeKpis() {
        HomeKpis k = new HomeKpis();
        k.open = 0; k.breached = 0; k.dueSoon = 0; k.untouched = 0;
        for (Work_Order__c w : [SELECT Is_Open__c, SLA_Breached__c, SLA_Health__c, Untouched__c FROM Work_Order__c]) {
            if (w.Is_Open__c) {
                k.open++;
                if (w.SLA_Breached__c) k.breached++;
                if (w.SLA_Health__c != null && w.SLA_Health__c.contains('Due Soon')) k.dueSoon++;
                if (w.Untouched__c) k.untouched++;
            }
        }
        return k;
    }

    public class Row {
        @AuraEnabled public Id id;
        @AuraEnabled public String subject;
        @AuraEnabled public String property;
        @AuraEnabled public String unit;
        @AuraEnabled public String priority;
        @AuraEnabled public String status;
        @AuraEnabled public String slaHealth;
        @AuraEnabled public Integer hoursOpen;
        @AuraEnabled public Boolean breached;
        @AuraEnabled public Boolean untouched;
        @AuraEnabled public Boolean isOpen;
    }
    private static List<Row> toRows(List<Work_Order__c> recs) {
        List<Row> out = new List<Row>();
        for (Work_Order__c w : recs) {
            Row r = new Row();
            r.id = w.Id; r.subject = w.Subject__c; r.property = w.Property_Display_Name__c; r.unit = w.Unit__c;
            r.priority = w.Priority__c; r.status = w.Status__c; r.slaHealth = w.SLA_Health__c;
            r.hoursOpen = w.Hours_Open__c == null ? null : (Integer) w.Hours_Open__c;
            r.breached = w.SLA_Breached__c == true; r.untouched = w.Untouched__c == true; r.isOpen = w.Is_Open__c == true;
            out.add(r);
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Row> getRecentWorkOrders() {
        return toRows(Database.query(ROW_QUERY + 'WHERE Is_Open__c = true ORDER BY Reported_Date__c DESC LIMIT 6'));
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getEscalations() {
        return toRows(Database.query(ROW_QUERY + 'WHERE Is_Escalation__c = true ORDER BY SLA_Due_Date__c ASC NULLS LAST'));
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getUntouched() {
        return toRows(Database.query(ROW_QUERY + 'WHERE Untouched__c = true ORDER BY Reported_Date__c ASC NULLS LAST'));
    }

    public class Entry {
        @AuraEnabled public Id id;
        @AuraEnabled public String kind;
        @AuraEnabled public String detail;
        @AuraEnabled public String actor;
        @AuraEnabled public Datetime entryDate;
    }
    public class ActivityView {
        @AuraEnabled public List<Entry> entries;
        @AuraEnabled public Boolean untouched;
    }
    @AuraEnabled(cacheable=true)
    public static ActivityView getActivity(Id workOrderId) {
        Work_Order__c w = [SELECT Untouched__c FROM Work_Order__c WHERE Id = :workOrderId LIMIT 1];
        ActivityView v = new ActivityView();
        v.untouched = w.Untouched__c == true;
        v.entries = new List<Entry>();
        // Frozen-clock gotcha: same-transaction rows share timestamps, so tie-break on Name DESC.
        for (Work_Order_Activity__c a : [SELECT Id, Kind__c, Detail__c, Actor__c, Entry_Date__c
                                         FROM Work_Order_Activity__c WHERE Work_Order__c = :workOrderId
                                         ORDER BY Entry_Date__c DESC NULLS LAST, Name DESC]) {
            Entry e = new Entry();
            e.id = a.Id; e.kind = a.Kind__c; e.detail = a.Detail__c; e.actor = a.Actor__c; e.entryDate = a.Entry_Date__c;
            v.entries.add(e);
        }
        return v;
    }
}
```
`classes/WorkOrderController.cls-meta.xml`: same ApexClass XML as the test's meta file.

- [ ] **Step 3: Add class access to the perm set**

In `permissionsets/Property_Management_Access.permissionset-meta.xml`, next to the existing `classAccesses` entries:
```xml
    <classAccesses>
        <apexClass>WorkOrderController</apexClass>
        <enabled>true</enabled>
    </classAccesses>
```

- [ ] **Step 4: Deploy with tests**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/classes/WorkOrderController.cls -d force-app/main/default/classes/WorkOrderControllerTest.cls -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -l RunSpecifiedTests -t WorkOrderControllerTest --json
```
Expected: Succeeded, `numberTestErrors: 0`, 7 tests run. If a test fails, fix the controller (or a genuinely wrong expectation) — do not weaken assertions.

- [ ] **Step 5: Commit and push**

```powershell
git add force-app/main/default/classes force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "Work Order Tracker: WorkOrderController + 7 tests" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 4: Page layout + Path

**Files:**
- Create: `force-app/main/default/layouts/Work_Order__c-Work Order Layout.layout-meta.xml`
- Create: `force-app/main/default/pathAssistants/Work_Order_Path.pathAssistant-meta.xml`

**Interfaces:**
- Consumes: `Work_Order__c` fields (Task 1).
- Produces: the layout (Status/Priority read-only; only `Delay_Reason__c` editable; Status absent) + path `Work_Order_Path`.

- [ ] **Step 1: Page layout**

`layouts/Work_Order__c-Work Order Layout.layout-meta.xml` — every item `Readonly` EXCEPT `Delay_Reason__c` (`Edit`); `Status__c` deliberately absent (Path + highlights manage it). Only Edit/Delete in the action list (read-only mirror — no New/Submit/Clone).
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Layout xmlns="http://soap.sforce.com/2006/04/metadata">
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>Work Order</label>
        <layoutColumns>
            <layoutItems><behavior>Readonly</behavior><field>Subject__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Description__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Category__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Priority__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Property_Asset__c</field></layoutItems>
        </layoutColumns>
        <layoutColumns>
            <layoutItems><behavior>Readonly</behavior><field>Unit__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Tenant_Name__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Vendor__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Owner_User__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Owner_Role__c</field></layoutItems>
        </layoutColumns>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>SLA &amp; Aging</label>
        <layoutColumns>
            <layoutItems><behavior>Readonly</behavior><field>Reported_Date__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>First_Touched_Date__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Completed_Date__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>SLA_Due_Date__c</field></layoutItems>
        </layoutColumns>
        <layoutColumns>
            <layoutItems><behavior>Readonly</behavior><field>SLA_Health__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Hours_Open__c</field></layoutItems>
            <layoutItems><behavior>Readonly</behavior><field>Untouched__c</field></layoutItems>
        </layoutColumns>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>Reason for Delay (Salesforce-only)</label>
        <layoutColumns>
            <layoutItems><behavior>Edit</behavior><field>Delay_Reason__c</field></layoutItems>
        </layoutColumns>
        <layoutColumns/>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>System Information</label>
        <layoutColumns>
            <layoutItems><behavior>Readonly</behavior><field>CreatedById</field></layoutItems>
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
            <actionName>Edit</actionName>
            <actionType>StandardButton</actionType>
            <sortOrder>0</sortOrder>
        </platformActionListItems>
        <platformActionListItems>
            <actionName>Delete</actionName>
            <actionType>StandardButton</actionType>
            <sortOrder>1</sortOrder>
        </platformActionListItems>
    </platformActionList>
    <showEmailCheckbox>false</showEmailCheckbox>
    <showHighlightsPanel>false</showHighlightsPanel>
    <showInteractionLogPanel>false</showInteractionLogPanel>
    <showRunAssignmentRulesCheckbox>false</showRunAssignmentRulesCheckbox>
    <showSubmitAndAttachButton>false</showSubmitAndAttachButton>
</Layout>
```

- [ ] **Step 2: Path**

`pathAssistants/Work_Order_Path.pathAssistant-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<PathAssistant xmlns="http://soap.sforce.com/2006/04/metadata">
    <active>true</active>
    <entityName>Work_Order__c</entityName>
    <fieldName>Status__c</fieldName>
    <masterLabel>Work Order Path</masterLabel>
    <pathAssistantSteps>
        <info>Reported and synced from Yardi. SLA clock is running — nobody has acted yet.</info>
        <picklistValueName>New</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <fieldNames>Vendor__c</fieldNames>
        <info>Someone picked it up — dispatched and/or a vendor assigned. Watch the SLA due time.</info>
        <picklistValueName>In Progress</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <fieldNames>Delay_Reason__c</fieldNames>
        <info>Stuck waiting on something. Flag the Reason for Delay so leadership sees why on the dashboard.</info>
        <picklistValueName>On Hold</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <fieldNames>Completed_Date__c</fieldNames>
        <info>Work finished. Completed date is stamped automatically.</info>
        <picklistValueName>Completed</picklistValueName>
    </pathAssistantSteps>
    <pathAssistantSteps>
        <info>Closed with the nightly Yardi sync. No further action.</info>
        <picklistValueName>Closed</picklistValueName>
    </pathAssistantSteps>
    <recordTypeName>__MASTER__</recordTypeName>
</PathAssistant>
```

- [ ] **Step 3: Deploy**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d "force-app/main/default/layouts/Work_Order__c-Work Order Layout.layout-meta.xml" -d force-app/main/default/pathAssistants/Work_Order_Path.pathAssistant-meta.xml --json
```
Expected: Succeeded (2 components).

- [ ] **Step 4: Commit and push**

```powershell
git add "force-app/main/default/layouts/Work_Order__c-Work Order Layout.layout-meta.xml" force-app/main/default/pathAssistants/Work_Order_Path.pathAssistant-meta.xml
git commit -m "Work Order Tracker: read-only layout + status path" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 5: workOrderTimeline LWC + record page

**Files:**
- Create: `force-app/main/default/lwc/workOrderTimeline/workOrderTimeline.{js,html,css}` + `.js-meta.xml`
- Create: `force-app/main/default/flexipages/Work_Order_Record_Page.flexipage-meta.xml`
- Modify: `force-app/main/default/applications/Property_Management.app-meta.xml` (add actionOverride)

**Interfaces:**
- Consumes: `getActivity(workOrderId)` (Task 3 — returns `{entries:[{id, kind, detail, actor, entryDate}], untouched}`).
- Produces: flexipage `Work_Order_Record_Page` (Task 7's tab/app work assumes it exists).

- [ ] **Step 1: workOrderTimeline JS (read-only — NO composer)**

`lwc/workOrderTimeline/workOrderTimeline.js`:
```js
import { LightningElement, api, wire } from 'lwc';
import getActivity from '@salesforce/apex/WorkOrderController.getActivity';

const KIND_META = {
    Sync:   { fg: '#5A5752', bg: '#EDEBE7' },
    Status: { fg: '#1A3464', bg: '#E8EFF7' },
    Vendor: { fg: '#9A4B00', bg: '#FDF2E7' },
    Note:   { fg: '#132850', bg: '#E8EFF7' },
    Flag:   { fg: '#1A4880', bg: '#EBF3FC' }
};
const badge = (kind) => {
    const x = KIND_META[kind] || KIND_META.Note;
    return `display:inline-flex;align-items:center;font-size:10px;font-weight:700;letter-spacing:0.03em;text-transform:uppercase;padding:2px 7px;border-radius:9999px;background:${x.bg};color:${x.fg}`;
};

// Read-only activity/status history on the Work Order record page. History arrives
// with the nightly Yardi sync — there is no compose box.
export default class WorkOrderTimeline extends LightningElement {
    @api recordId;
    view;

    @wire(getActivity, { workOrderId: '$recordId' })
    wired({ data }) {
        if (data) this.view = data;
    }

    get count() { return this.view && this.view.entries ? this.view.entries.length : 0; }
    get untouched() { return !!(this.view && this.view.untouched); }
    get hasEntries() { return this.count > 0; }

    get entries() {
        const rows = (this.view && this.view.entries) || [];
        return rows.map((e, i) => ({
            id: e.id,
            detail: e.detail,
            actor: e.actor || 'Yardi',
            kind: e.kind || 'Note',
            kindStyle: badge(e.kind),
            entryDate: e.entryDate,
            isLatest: i === 0,
            showLine: i < rows.length - 1,
            markerClass: i === 0 ? 'wot-marker wot-marker--latest' : 'wot-marker'
        }));
    }
}
```

- [ ] **Step 2: workOrderTimeline HTML**

`lwc/workOrderTimeline/workOrderTimeline.html`:
```html
<template>
    <div class="wot-card">
        <div class="wot-head">
            <div class="wot-head-left">
                <span class="wot-head-icon">
                    <lightning-icon icon-name="utility:clock" size="x-small" variant="inverse"></lightning-icon>
                </span>
                <div>
                    <div class="wot-title">Activity &amp; Status History</div>
                    <div class="wot-sub">{count} entries · from the nightly Yardi sync</div>
                </div>
                <template if:true={untouched}>
                    <span class="wot-untouched">Untouched</span>
                </template>
            </div>
        </div>

        <div class="wot-body">
            <template if:true={hasEntries}>
                <template for:each={entries} for:item="e">
                    <div key={e.id} class="wot-entry">
                        <div class="wot-rail">
                            <span class={e.markerClass}></span>
                            <template if:true={e.showLine}><span class="wot-line"></span></template>
                        </div>
                        <div class="wot-content">
                            <div class="wot-entry-head">
                                <span class="wot-entry-left">
                                    <span class="wot-by">{e.actor}</span>
                                    <span style={e.kindStyle}>{e.kind}</span>
                                </span>
                                <lightning-formatted-date-time
                                    class="wot-date"
                                    value={e.entryDate}
                                    year="numeric" month="short" day="2-digit"
                                    hour="2-digit" minute="2-digit">
                                </lightning-formatted-date-time>
                            </div>
                            <div class="wot-detail">{e.detail}</div>
                            <template if:true={e.isLatest}><span class="wot-latest">Latest</span></template>
                        </div>
                    </div>
                </template>
            </template>
            <template if:false={hasEntries}>
                <div class="wot-empty">No activity yet — nothing has synced for this work order.</div>
            </template>
            <div class="wot-foot-note">
                <lightning-icon icon-name="utility:lock" size="xx-small"></lightning-icon>
                History arrives with the nightly sync. Assigning vendors and closing tickets happens in Yardi — never here.
            </div>
        </div>
    </div>
</template>
```

- [ ] **Step 3: workOrderTimeline CSS + meta**

`lwc/workOrderTimeline/workOrderTimeline.css`:
```css
:host { display:block; font-family:'Salesforce Sans', Arial, sans-serif; color:#181818; }

.wot-card { background:#fff; border:1px solid #E2E0DB; border-radius:8px; box-shadow:0 1px 2px rgba(7,20,40,0.06); overflow:hidden; }

.wot-head { display:flex; align-items:center; justify-content:space-between; gap:10px; padding:14px 20px; border-bottom:1px solid #E2E0DB; }
.wot-head-left { display:flex; align-items:center; gap:10px; }
.wot-head-icon { width:26px; height:26px; border-radius:50%; background:#1A3464; display:inline-flex; align-items:center; justify-content:center; flex-shrink:0; }
.wot-title { font-size:15px; font-weight:700; line-height:1.1; color:#1A1714; }
.wot-sub { font-size:11px; color:#8A8680; margin-top:2px; }
.wot-untouched { display:inline-flex; align-items:center; background:#F3EEFB; color:#4A2A7A; border:1px solid #D9C9F0; font-size:10px; font-weight:700; padding:2px 8px; border-radius:9999px; text-transform:uppercase; letter-spacing:0.03em; margin-left:8px; }

.wot-body { padding:16px 20px; }
.wot-entry { display:flex; gap:12px; padding-bottom:18px; }
.wot-rail { display:flex; flex-direction:column; align-items:center; flex-shrink:0; }
.wot-marker { width:12px; height:12px; border-radius:50%; background:#B0AEA8; border:2px solid #fff; box-shadow:0 0 0 2px #E2E0DB; margin-top:3px; flex-shrink:0; }
.wot-marker--latest { background:#1A3464; box-shadow:0 0 0 2px #D6E0EE; }
.wot-line { flex:1; width:2px; background:#E2E0DB; margin-top:2px; }
.wot-content { flex:1; padding-bottom:2px; min-width:0; }
.wot-entry-head { display:flex; align-items:center; justify-content:space-between; gap:8px; flex-wrap:wrap; }
.wot-entry-left { display:inline-flex; align-items:center; gap:7px; }
.wot-by { font-size:12px; font-weight:700; color:#1A1714; }
.wot-date { font-size:11px; color:#8A8680; }
.wot-detail { font-size:13px; color:#1A1714; line-height:1.55; margin-top:5px; white-space:pre-wrap; word-break:break-word; }
.wot-latest { display:inline-block; margin-top:8px; font-size:10px; font-weight:700; letter-spacing:0.05em; text-transform:uppercase; color:#7A5A00; background:#FBF2DA; padding:2px 7px; border-radius:9999px; }
.wot-empty { padding:8px 0 14px; color:#8A8680; font-size:13px; }
.wot-foot-note { display:flex; align-items:center; gap:7px; padding:10px 0 2px; color:#8A8680; font-size:11px; border-top:1px dashed #E2E0DB; }
```
`lwc/workOrderTimeline/workOrderTimeline.js-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Work Order Timeline</masterLabel>
    <description>Read-only activity &amp; status history on a Work Order, from the Yardi sync.</description>
    <targets>
        <target>lightning__RecordPage</target>
    </targets>
</LightningComponentBundle>
```
(Do NOT add `objects=` to the targetConfig — known deploy rejection.)

- [ ] **Step 4: Record page flexipage**

`flexipages/Work_Order_Record_Page.flexipage-meta.xml` (one componentInstance per itemInstances):
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
                <identifier>workOrderPath</identifier>
            </componentInstance>
        </itemInstances>
        <name>subheader</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>workOrderTimeline</componentName>
                <identifier>workOrderTimelineComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>activityContent</name>
        <type>Facet</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>parentFieldApiName</name>
                    <value>Work_Order__c.Id</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>relatedListApiName</name>
                    <value>Work_Order_Activities__r</value>
                </componentInstanceProperties>
                <componentName>force:relatedListSingleContainer</componentName>
                <identifier>workOrderActivitiesList</identifier>
            </componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance>
                <componentInstanceProperties>
                    <name>parentFieldApiName</name>
                    <value>Work_Order__c.Id</value>
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
                    <value>activityContent</value>
                </componentInstanceProperties>
                <componentInstanceProperties>
                    <name>title</name>
                    <value>Activity</value>
                </componentInstanceProperties>
                <componentName>flexipage:tab</componentName>
                <identifier>activityTab</identifier>
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
    <masterLabel>Work Order Record Page</masterLabel>
    <sobjectType>Work_Order__c</sobjectType>
    <template>
        <name>flexipage:recordHomeWithSubheaderTemplateDesktop</name>
    </template>
    <type>RecordPage</type>
</FlexiPage>
```

- [ ] **Step 5: Assign the page via app actionOverride**

In `applications/Property_Management.app-meta.xml`, add after the last existing `actionOverrides` block (the Lease_Renewal_Record_Page one) and before `<brand>`:
```xml
    <actionOverrides>
        <actionName>View</actionName>
        <comment>Work Order Record Page</comment>
        <content>Work_Order_Record_Page</content>
        <formFactor>Large</formFactor>
        <skipRecordTypeSelect>false</skipRecordTypeSelect>
        <type>Flexipage</type>
        <pageOrSobjectType>Work_Order__c</pageOrSobjectType>
    </actionOverrides>
```

- [ ] **Step 6: Deploy (LWC+flexipage first, then app)**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/lwc/workOrderTimeline -d force-app/main/default/flexipages/Work_Order_Record_Page.flexipage-meta.xml --json
sf project deploy start -d force-app/main/default/applications/Property_Management.app-meta.xml -c --json
```
Expected: both Succeeded. The app deploy may report a spurious SourceConflictError first — retry with `-c` (already included above).

- [ ] **Step 7: Commit and push**

```powershell
git add force-app/main/default/lwc/workOrderTimeline force-app/main/default/flexipages/Work_Order_Record_Page.flexipage-meta.xml force-app/main/default/applications/Property_Management.app-meta.xml
git commit -m "Work Order Tracker: read-only timeline LWC + record page" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 6: Home-page widget LWCs (workOrderKpis, workOrderList, workOrderEscalations, workOrderUntouched)

**Files:**
- Create: `force-app/main/default/lwc/workOrderKpis/workOrderKpis.{js,html,css}` + `.js-meta.xml`
- Create: `force-app/main/default/lwc/workOrderList/workOrderList.{js,html,css}` + `.js-meta.xml`
- Create: `force-app/main/default/lwc/workOrderEscalations/workOrderEscalations.{js,html,css}` + `.js-meta.xml`
- Create: `force-app/main/default/lwc/workOrderUntouched/workOrderUntouched.{js,html,css}` + `.js-meta.xml`

**Interfaces:**
- Consumes: `getHomeKpis`, `getRecentWorkOrders`, `getEscalations`, `getUntouched` (Task 3 Row shape), shared `c-stat-card` (attrs value, label, icon-name, icon-color) and `c-list-datatable` (custom `pill` cell type: typeAttributes wrapStyle/dotStyle).
- Produces: the four component names Task 7's flexipage references.

All four `.js-meta.xml` files use this shape (adjust masterLabel/description per component):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <isExposed>true</isExposed>
    <masterLabel>Work Order KPIs</masterLabel>
    <description>KPI strip for the Work Orders home page.</description>
    <targets>
        <target>lightning__AppPage</target>
        <target>lightning__HomePage</target>
    </targets>
</LightningComponentBundle>
```

- [ ] **Step 1: workOrderKpis**

`workOrderKpis.js`:
```js
import { LightningElement, wire } from 'lwc';
import getHomeKpis from '@salesforce/apex/WorkOrderController.getHomeKpis';

// Top KPI strip on the Work Orders home page.
export default class WorkOrderKpis extends LightningElement {
    k;
    @wire(getHomeKpis) wired({ data }) { if (data) this.k = data; }

    get cards() {
        const k = this.k || {};
        return [
            { key: 'open',      value: k.open ?? 0,      label: 'Open Work Orders', iconName: 'utility:wrench',   iconColor: '#7A9ED4' },
            { key: 'breached',  value: k.breached ?? 0,  label: 'Breached SLA',     iconName: 'utility:warning',  iconColor: '#E58A8A' },
            { key: 'dueSoon',   value: k.dueSoon ?? 0,   label: 'Due Soon',         iconName: 'utility:clock',    iconColor: '#D8BE72' },
            { key: 'untouched', value: k.untouched ?? 0, label: 'Untouched',        iconName: 'utility:preview',  iconColor: '#B39DDB' }
        ];
    }
}
```
`workOrderKpis.html`:
```html
<template>
    <div class="kpi-grid">
        <template for:each={cards} for:item="c">
            <c-stat-card key={c.key} value={c.value} label={c.label} icon-name={c.iconName} icon-color={c.iconColor}></c-stat-card>
        </template>
    </div>
</template>
```
`workOrderKpis.css`:
```css
.kpi-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; }
@media (max-width: 1024px) { .kpi-grid { grid-template-columns: repeat(2, 1fr); } }
```

- [ ] **Step 2: workOrderList**

`workOrderList.js`:
```js
import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRecentWorkOrders from '@salesforce/apex/WorkOrderController.getRecentWorkOrders';

const PRIORITY_ACCENT = { Critical: '#B01818', High: '#9A4B00', Medium: '#8B6800', Low: '#5A5752' };
const pillWrap = (bg, fg) => `display:inline-flex;align-items:center;gap:6px;background:${bg};color:${fg};font-size:11px;font-weight:600;padding:3px 10px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

const COLUMNS = [
    { label: 'Work Order', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'subject' }, target: '_self' } },
    { label: 'Property · Unit', fieldName: 'propUnit', type: 'text' },
    { label: 'Priority', fieldName: 'priority', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'priorityWrap' }, dotStyle: { fieldName: 'priorityDot' } } },
    { label: 'Status', fieldName: 'status', type: 'text' },
    { label: 'SLA', fieldName: 'slaText', type: 'pill', typeAttributes: { wrapStyle: { fieldName: 'slaWrap' }, dotStyle: { fieldName: 'slaDot' } } },
    { label: 'Days Open', fieldName: 'daysOpen', type: 'text', initialWidth: 110 }
];

// Open Work Orders list on the Work Orders home page (6 newest, View All footer).
export default class WorkOrderList extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    _data = [];
    listUrl = '#';
    @wire(getRecentWorkOrders) wired({ data }) { if (data) this._data = data; }

    connectedCallback() {
        this[NavigationMixin.GenerateUrl](this.listPageRef).then((url) => { this.listUrl = url; });
    }
    get listPageRef() {
        return {
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Work_Order__c', actionName: 'list' },
            state: { filterName: 'My_Open_Work_Orders' }
        };
    }

    get rows() {
        return this._data.map((w) => {
            const pc = PRIORITY_ACCENT[w.priority] || '#5A5752';
            const h = w.slaHealth || '';
            let slaWrap;
            let slaDot = '';
            let slaText;
            if (h.indexOf('Breached') >= 0) { slaText = 'Breached'; slaWrap = pillWrap('#FDF0F0', '#8B1A1A'); slaDot = dot('#D93636'); }
            else if (h.indexOf('Due Soon') >= 0) { slaText = 'Due Soon'; slaWrap = pillWrap('#FDF5E6', '#7A4A00'); slaDot = dot('#C88010'); }
            else if (h.indexOf('Resolved') >= 0) { slaText = 'Resolved'; slaWrap = pillWrap('#EBF9F1', '#146830'); }
            else { slaText = 'On Track'; slaWrap = pillWrap('#EBF9F1', '#146830'); slaDot = dot('#22A652'); }
            const days = w.hoursOpen == null ? 0 : Math.floor(w.hoursOpen / 24);
            return {
                id: w.id,
                recordUrl: `/lightning/r/Work_Order__c/${w.id}/view`,
                subject: w.subject || '—',
                propUnit: `${w.property || '—'}${w.unit ? ' · ' + w.unit : ''}`,
                priority: w.priority || '—',
                priorityWrap: pillWrap(`${pc}18`, pc),
                priorityDot: dot(pc),
                status: w.status || '—',
                slaText, slaWrap, slaDot,
                daysOpen: `${days}d`
            };
        });
    }
    get count() { return this.rows.length; }

    viewAll(event) {
        if (event) event.preventDefault();
        this[NavigationMixin.Navigate](this.listPageRef);
    }
}
```
`workOrderList.html`:
```html
<template>
    <lightning-card>
        <div slot="title" class="hdr">
            <span class="hdr-icon">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#7A9ED4" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>
                </svg>
            </span>
            <span class="hdr-title">Open Work Orders ({count})</span>
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
`workOrderList.css`:
```css
.hdr { display:flex; align-items:center; gap:9px; }
.hdr-icon { display:inline-flex; align-items:center; justify-content:center; flex-shrink:0; }
.hdr-title { font-size:16px; font-weight:700; color:#1A1714; }
.view-all-footer { text-align: center; }
.view-all-footer a { font-weight: 600; color: #0B5CAB; text-decoration: none; }
.view-all-footer a:hover { text-decoration: underline; }
```
(No New button — read-only mirror.)

- [ ] **Step 3: workOrderEscalations**

`workOrderEscalations.js`:
```js
import { LightningElement, wire } from 'lwc';
import getEscalations from '@salesforce/apex/WorkOrderController.getEscalations';

const PRIORITY_ACCENT = { Critical: '#B01818', High: '#9A4B00', Medium: '#8B6800', Low: '#5A5752' };
const pill = (bg, fg) => `display:inline-flex;align-items:center;gap:5px;background:${bg};color:${fg};font-size:11px;font-weight:700;padding:3px 9px;border-radius:9999px;line-height:1.4;white-space:nowrap`;
const dot = (c) => `width:6px;height:6px;border-radius:50%;background:${c};flex-shrink:0`;

// Right-column widget: Critical/High work orders that have breached SLA.
export default class WorkOrderEscalations extends LightningElement {
    _data = [];
    @wire(getEscalations) wired({ data }) { if (data) this._data = data; }

    get rows() {
        return this._data.map((w) => {
            const pc = PRIORITY_ACCENT[w.priority] || '#B01818';
            return {
                id: w.id,
                recordUrl: `/lightning/r/Work_Order__c/${w.id}/view`,
                subject: w.subject || '—',
                sub: `${w.property || '—'} · ${w.priority}`,
                priorityWrap: pill(`${pc}18`, pc),
                priorityDot: dot(pc),
                priority: w.priority
            };
        });
    }
    get hasRows() { return this._data.length > 0; }
}
```
`workOrderEscalations.html`:
```html
<template>
    <article class="es-card">
        <div class="es-hd">
            <span class="es-icon">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#B01818" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4M12 17h.01"/>
                </svg>
            </span>
            <div>
                <div class="es-title">Escalations</div>
                <div class="es-sub">Critical / High that breached SLA</div>
            </div>
        </div>
        <template if:true={hasRows}>
            <div class="es-body">
                <template for:each={rows} for:item="r">
                    <a key={r.id} href={r.recordUrl} class="es-row">
                        <div class="es-main">
                            <div class="es-name">{r.subject}</div>
                            <div class="es-metasub">{r.sub}</div>
                        </div>
                        <span style={r.priorityWrap}><span style={r.priorityDot}></span>{r.priority}</span>
                    </a>
                </template>
            </div>
        </template>
        <template if:false={hasRows}>
            <div class="es-empty">Nothing is on fire.</div>
        </template>
    </article>
</template>
```
`workOrderEscalations.css`:
```css
.es-card { background:#fff; border:1px solid #E2E0DB; border-radius:8px; box-shadow:0 1px 2px rgba(7,20,40,0.06); padding:18px; display:block; }
.es-hd { display:flex; align-items:center; gap:9px; margin-bottom:6px; }
.es-icon { width:26px; height:26px; border-radius:50%; background:#FDECEC; display:inline-flex; align-items:center; justify-content:center; flex-shrink:0; }
.es-title { font-size:16px; font-weight:700; color:#1A1714; line-height:1.1; }
.es-sub { font-size:11px; color:#8A8680; margin-top:2px; }
.es-body { display:flex; flex-direction:column; }
.es-row { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:11px 4px; border-bottom:1px solid #EDECEA; text-decoration:none; }
.es-row:last-child { border-bottom:none; }
.es-row:hover { background:#FFF7F7; }
.es-name { font-size:14px; font-weight:700; color:#1565C0; }
.es-metasub { font-size:12px; color:#524F4A; margin-top:2px; }
.es-empty { padding:20px 4px; text-align:center; color:#8A8680; font-size:13px; }
```

- [ ] **Step 4: workOrderUntouched**

`workOrderUntouched.js`:
```js
import { LightningElement, wire } from 'lwc';
import getUntouched from '@salesforce/apex/WorkOrderController.getUntouched';

const PRIORITY_ACCENT = { Critical: '#B01818', High: '#9A4B00', Medium: '#8B6800', Low: '#5A5752' };
const pill = (bg, fg) => `display:inline-flex;align-items:center;gap:5px;background:${bg};color:${fg};font-size:11px;font-weight:700;padding:3px 9px;border-radius:9999px;line-height:1.4;white-space:nowrap`;

// Right-column widget: open work orders nobody has acted on yet.
export default class WorkOrderUntouched extends LightningElement {
    _data = [];
    @wire(getUntouched) wired({ data }) { if (data) this._data = data; }

    get rows() {
        return this._data.map((w) => {
            const h = w.slaHealth || '';
            const breached = h.indexOf('Breached') >= 0;
            const dueSoon = h.indexOf('Due Soon') >= 0;
            let wrap;
            if (breached) wrap = pill('#FDF0F0', '#8B1A1A');
            else if (dueSoon) wrap = pill('#FDF5E6', '#7A4A00');
            else wrap = pill('#EBF9F1', '#146830');
            const label = breached ? 'Breached' : (dueSoon ? 'Due Soon' : 'On Track');
            return {
                id: w.id,
                recordUrl: `/lightning/r/Work_Order__c/${w.id}/view`,
                subject: w.subject || '—',
                sub: `${w.property || '—'} · ${w.priority}`,
                slaWrap: wrap,
                slaText: label
            };
        });
    }
    get hasRows() { return this._data.length > 0; }
}
```
`workOrderUntouched.html`:
```html
<template>
    <article class="ut-card">
        <div class="ut-hd">
            <span class="ut-icon">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#4A2A7A" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/><path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/><path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/><path d="m2 2 20 20"/>
                </svg>
            </span>
            <div>
                <div class="ut-title">Untouched</div>
                <div class="ut-sub">Nobody has acted on these yet</div>
            </div>
        </div>
        <template if:true={hasRows}>
            <div class="ut-body">
                <template for:each={rows} for:item="r">
                    <a key={r.id} href={r.recordUrl} class="ut-row">
                        <div class="ut-main">
                            <div class="ut-name">{r.subject}</div>
                            <div class="ut-metasub">{r.sub}</div>
                        </div>
                        <span style={r.slaWrap}>{r.slaText}</span>
                    </a>
                </template>
            </div>
        </template>
        <template if:false={hasRows}>
            <div class="ut-empty">Everything has been picked up.</div>
        </template>
    </article>
</template>
```
`workOrderUntouched.css`:
```css
.ut-card { background:#fff; border:1px solid #E2E0DB; border-radius:8px; box-shadow:0 1px 2px rgba(7,20,40,0.06); padding:18px; display:block; }
.ut-hd { display:flex; align-items:center; gap:9px; margin-bottom:6px; }
.ut-icon { width:26px; height:26px; border-radius:50%; background:#F3EEFB; display:inline-flex; align-items:center; justify-content:center; flex-shrink:0; }
.ut-title { font-size:16px; font-weight:700; color:#1A1714; line-height:1.1; }
.ut-sub { font-size:11px; color:#8A8680; margin-top:2px; }
.ut-body { display:flex; flex-direction:column; }
.ut-row { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:11px 4px; border-bottom:1px solid #EDECEA; text-decoration:none; }
.ut-row:last-child { border-bottom:none; }
.ut-row:hover { background:#F8F5FC; }
.ut-name { font-size:14px; font-weight:700; color:#1565C0; }
.ut-metasub { font-size:12px; color:#524F4A; margin-top:2px; }
.ut-empty { padding:20px 4px; text-align:center; color:#8A8680; font-size:13px; }
```

- [ ] **Step 5: Deploy and commit**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/lwc/workOrderKpis -d force-app/main/default/lwc/workOrderList -d force-app/main/default/lwc/workOrderEscalations -d force-app/main/default/lwc/workOrderUntouched --json
```
Expected: Succeeded.
```powershell
git add force-app/main/default/lwc/workOrderKpis force-app/main/default/lwc/workOrderList force-app/main/default/lwc/workOrderEscalations force-app/main/default/lwc/workOrderUntouched
git commit -m "Work Order Tracker: home-page widget LWCs" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 7: Home flexipage, tabs, app navigation, perm-set tabs

**Files:**
- Create: `force-app/main/default/flexipages/Work_Orders_Home.flexipage-meta.xml`
- Create: `force-app/main/default/tabs/Work_Orders.tab-meta.xml`
- Create: `force-app/main/default/tabs/Work_Order__c.tab-meta.xml`
- Modify: `force-app/main/default/applications/Property_Management.app-meta.xml` (add 2 tabs)
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml` (add 2 tabSettings)

**Interfaces:**
- Consumes: the 4 LWCs (Task 6).
- Produces: `Work_Orders` app-home tab visible in the Property Management app.

- [ ] **Step 1: Home flexipage**

`flexipages/Work_Orders_Home.flexipage-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<FlexiPage xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>workOrderKpis</componentName>
                <identifier>workOrderKpisComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>region1</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>workOrderList</componentName>
                <identifier>workOrderListComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>region2</name>
        <type>Region</type>
    </flexiPageRegions>
    <flexiPageRegions>
        <itemInstances>
            <componentInstance>
                <componentName>workOrderEscalations</componentName>
                <identifier>workOrderEscalationsComponent</identifier>
            </componentInstance>
        </itemInstances>
        <itemInstances>
            <componentInstance>
                <componentName>workOrderUntouched</componentName>
                <identifier>workOrderUntouchedComponent</identifier>
            </componentInstance>
        </itemInstances>
        <name>region3</name>
        <type>Region</type>
    </flexiPageRegions>
    <masterLabel>Work Orders Home</masterLabel>
    <template>
        <name>flexipage:appHomeTemplateHeaderTwoColumns</name>
    </template>
    <type>AppPage</type>
</FlexiPage>
```

- [ ] **Step 2: Tabs**

`tabs/Work_Orders.tab-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <flexiPage>Work_Orders_Home</flexiPage>
    <label>Work Orders</label>
    <motif>Custom51: Apple</motif>
</CustomTab>
```
`tabs/Work_Order__c.tab-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomTab xmlns="http://soap.sforce.com/2006/04/metadata">
    <customObject>true</customObject>
    <motif>Custom51: Apple</motif>
</CustomTab>
```

- [ ] **Step 3: App navigation**

In `applications/Property_Management.app-meta.xml`, after the LAST `<tabs>...</tabs>` line (currently `<tabs>Lease_Renewal__c</tabs>`) and before `<uiType>Lightning</uiType>`, add:
```xml
    <tabs>Work_Orders</tabs>
    <tabs>Work_Order__c</tabs>
```

- [ ] **Step 4: Perm-set tab visibility**

In `permissionsets/Property_Management_Access.permissionset-meta.xml`, alongside existing `tabSettings`:
```xml
    <tabSettings>
        <tab>Work_Orders</tab>
        <visibility>Visible</visibility>
    </tabSettings>
    <tabSettings>
        <tab>Work_Order__c</tab>
        <visibility>Visible</visibility>
    </tabSettings>
```

- [ ] **Step 5: Deploy (flexipage + tabs first, then app + perm set)**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/flexipages/Work_Orders_Home.flexipage-meta.xml -d force-app/main/default/tabs/Work_Orders.tab-meta.xml -d force-app/main/default/tabs/Work_Order__c.tab-meta.xml --json
sf project deploy start -d force-app/main/default/applications/Property_Management.app-meta.xml -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -c --json
```
Expected: both Succeeded (second deploy: retry `-c` already included for the spurious app/perm-set conflict).

- [ ] **Step 6: Commit and push**

```powershell
git add force-app/main/default/flexipages/Work_Orders_Home.flexipage-meta.xml force-app/main/default/tabs force-app/main/default/applications/Property_Management.app-meta.xml force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "Work Order Tracker: home page, tabs, app navigation" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 8: Reports + dashboard

**Files:**
- Create: `force-app/main/default/reports/Work_Orders.reportFolder-meta.xml`
- Create: `force-app/main/default/reports/Work_Orders/Open_Work_Orders_by_Priority.report-meta.xml`
- Create: `force-app/main/default/reports/Work_Orders/SLA_Breaches.report-meta.xml`
- Create: `force-app/main/default/reports/Work_Orders/Work_Orders_by_Category.report-meta.xml`
- Create: `force-app/main/default/reports/Work_Orders/Untouched_Work_Orders.report-meta.xml`
- Create: `force-app/main/default/dashboards/Work_Orders.dashboardFolder-meta.xml`
- Create: `force-app/main/default/dashboards/Work_Orders/Work_Order_Health.dashboard-meta.xml`

**Interfaces:**
- Consumes: `Work_Order__c` fields (Task 1). Report type token `CustomEntity$Work_Order__c`; columns prefixed `Work_Order__c.`.
- Produces: dashboard `Work_Orders/Work_Order_Health` reachable from the app's Dashboards.

- [ ] **Step 1: Report folder + reports**

`reports/Work_Orders.reportFolder-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ReportFolder xmlns="http://soap.sforce.com/2006/04/metadata">
    <name>Work Orders</name>
</ReportFolder>
```
`reports/Work_Orders/Open_Work_Orders_by_Priority.report-meta.xml`:
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
        <groupingColumn>Work_Order__c.Priority__c</groupingColumn>
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
        <field>Work_Order__c.Subject__c</field>
    </columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Is_Open__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>1</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Work_Order__c.Priority__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Open Work Orders by Priority</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
`reports/Work_Orders/SLA_Breaches.report-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Work_Order__c.Subject__c</field></columns>
    <columns><field>Work_Order__c.Property_Display_Name__c</field></columns>
    <columns><field>Work_Order__c.Priority__c</field></columns>
    <columns><field>Work_Order__c.Status__c</field></columns>
    <columns><field>Work_Order__c.Hours_Open__c</field></columns>
    <columns><field>Work_Order__c.Owner_User__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.SLA_Breached__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>1</value>
        </criteriaItems>
    </filter>
    <format>Tabular</format>
    <name>SLA Breaches</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
    <sortColumn>Work_Order__c.Hours_Open__c</sortColumn>
    <sortOrder>Desc</sortOrder>
</Report>
```
`reports/Work_Orders/Work_Orders_by_Category.report-meta.xml`:
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
        <groupingColumn>Work_Order__c.Category__c</groupingColumn>
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
        <field>Work_Order__c.Subject__c</field>
    </columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Is_Open__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>1</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Work_Order__c.Category__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Work Orders by Category</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
`reports/Work_Orders/Untouched_Work_Orders.report-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Work_Order__c.Subject__c</field></columns>
    <columns><field>Work_Order__c.Property_Display_Name__c</field></columns>
    <columns><field>Work_Order__c.Priority__c</field></columns>
    <columns><field>Work_Order__c.Reported_Date__c</field></columns>
    <columns><field>Work_Order__c.SLA_Health__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Untouched__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>1</value>
        </criteriaItems>
    </filter>
    <format>Tabular</format>
    <name>Untouched Work Orders</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
    <sortColumn>Work_Order__c.Reported_Date__c</sortColumn>
    <sortOrder>Asc</sortOrder>
</Report>
```

- [ ] **Step 2: Dashboard folder + dashboard**

`dashboards/Work_Orders.dashboardFolder-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<DashboardFolder xmlns="http://soap.sforce.com/2006/04/metadata">
    <name>Work Orders</name>
</DashboardFolder>
```
`dashboards/Work_Orders/Work_Order_Health.dashboard-meta.xml` (3 metrics + 2 bars; `componentType Bar` + `chartAxisRange`):
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
                <chartSummary><column>RowCount</column></chartSummary>
                <componentChartTheme>light</componentChartTheme>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorBreakpoint1>1.0</indicatorBreakpoint1>
                <indicatorBreakpoint2>2.0</indicatorBreakpoint2>
                <indicatorHighColor>#0B5394</indicatorHighColor>
                <indicatorLowColor>#0B5394</indicatorLowColor>
                <indicatorMiddleColor>#0B5394</indicatorMiddleColor>
                <metricLabel>Open Work Orders</metricLabel>
                <report>Work_Orders/Open_Work_Orders_by_Priority</report>
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
                <chartSummary><column>RowCount</column></chartSummary>
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
                <metricLabel>Breached SLA</metricLabel>
                <report>Work_Orders/SLA_Breaches</report>
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
                <chartSummary><column>RowCount</column></chartSummary>
                <componentChartTheme>light</componentChartTheme>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorBreakpoint1>1.0</indicatorBreakpoint1>
                <indicatorBreakpoint2>2.0</indicatorBreakpoint2>
                <indicatorHighColor>#8A64C8</indicatorHighColor>
                <indicatorLowColor>#8A64C8</indicatorLowColor>
                <indicatorMiddleColor>#8A64C8</indicatorMiddleColor>
                <metricLabel>Untouched</metricLabel>
                <report>Work_Orders/Untouched_Work_Orders</report>
                <showRange>false</showRange>
            </dashboardComponent>
            <rowIndex>0</rowIndex>
            <rowSpan>4</rowSpan>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan>
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
                <groupingColumn>Work_Order__c.Priority__c</groupingColumn>
                <groupingSortProperties/>
                <legendPosition>Bottom</legendPosition>
                <report>Work_Orders/Open_Work_Orders_by_Priority</report>
                <showPercentage>false</showPercentage>
                <showPicturesOnCharts>false</showPicturesOnCharts>
                <showValues>true</showValues>
                <sortBy>RowLabelAscending</sortBy>
                <title>Open by Priority</title>
                <useReportChart>false</useReportChart>
            </dashboardComponent>
            <rowIndex>4</rowIndex>
            <rowSpan>8</rowSpan>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan>
            <columnIndex>6</columnIndex>
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
                <groupingColumn>Work_Order__c.Category__c</groupingColumn>
                <groupingSortProperties/>
                <legendPosition>Bottom</legendPosition>
                <report>Work_Orders/Work_Orders_by_Category</report>
                <showPercentage>false</showPercentage>
                <showPicturesOnCharts>false</showPicturesOnCharts>
                <showValues>true</showValues>
                <sortBy>RowValueDescending</sortBy>
                <title>Open by Category</title>
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
    <title>Work Order Health</title>
    <titleColor>#000000</titleColor>
    <titleSize>12</titleSize>
</Dashboard>
```

- [ ] **Step 3: Deploy (reports first, then dashboard)**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf project deploy start -d force-app/main/default/reports/Work_Orders.reportFolder-meta.xml -d force-app/main/default/reports/Work_Orders --json
sf project deploy start -d force-app/main/default/dashboards/Work_Orders.dashboardFolder-meta.xml -d force-app/main/default/dashboards/Work_Orders/Work_Order_Health.dashboard-meta.xml --json
```
Expected: both Succeeded.

- [ ] **Step 4: Commit and push**

```powershell
git add force-app/main/default/reports/Work_Orders.reportFolder-meta.xml force-app/main/default/reports/Work_Orders force-app/main/default/dashboards/Work_Orders.dashboardFolder-meta.xml force-app/main/default/dashboards/Work_Orders
git commit -m "Work Order Tracker: 4 reports + Work Order Health dashboard" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 9: Seed data + end-to-end verification

**Files:**
- Create: `scripts/seed-work-orders.apex`

**Interfaces:**
- Consumes: everything. Idempotent (skips if any `Work_Order__c` exists).

- [ ] **Step 1: Write the seed script**

`scripts/seed-work-orders.apex` (all datetimes are offsets from `Datetime.now()`; a Completed/Closed record relies on Completed_Date being set explicitly; New records leave First_Touched null so Untouched is true):
```apex
// Seed Work Order Tracker demo data. Idempotent: skips when work orders exist.
// Run: sf apex run -f scripts/seed-work-orders.apex
if (![SELECT Id FROM Work_Order__c LIMIT 1].isEmpty()) {
    System.debug('Seed skipped — Work Order records already exist.');
} else {
    List<String> names = new List<String>{ 'Westgate Plaza', 'Sterling Crossing', 'Magnolia Commons', 'Bayou Bend Center', 'Katy Mills Strip', 'Heights Marketplace' };
    Map<String, Property_Asset__c> assets = new Map<String, Property_Asset__c>();
    for (Property_Asset__c a : [SELECT Id, Name FROM Property_Asset__c WHERE Name IN :names]) assets.put(a.Name, a);
    List<Property__c> newProps = new List<Property__c>();
    for (String nm : names) {
        if (!assets.containsKey(nm)) newProps.add(new Property__c(Name=nm, Address__c='100 ' + nm + ' Dr', City__c='Houston', State__c='TX', Square_Footage__c=40000, Asset_Type__c='Retail'));
    }
    insert newProps;
    List<Property_Asset__c> newAssets = new List<Property_Asset__c>();
    for (Property__c p : newProps) newAssets.add(new Property_Asset__c(Name=p.Name, Property__c=p.Id, Property_Type__c='Retail', Status__c='Active'));
    insert newAssets;
    for (Property_Asset__c a : newAssets) assets.put(a.Name, a);

    Datetime n = Datetime.now();
    List<Work_Order__c> ws = new List<Work_Order__c>{
        // 0 Critical breached escalation (30h / 24h SLA), vendor delay
        new Work_Order__c(Subject__c='AC down — no cooling in suite', Category__c='HVAC', Priority__c='Critical', Status__c='In Progress', Description__c='AC stopped completely — thermostat reads 84 and climbing.', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit__c='Suite 120', Tenant_Name__c='Riverside Dental', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-30), First_Touched_Date__c=n.addHours(-29), Delay_Reason__c='Vendor delay'),
        // 1 Critical on-track (fresh 4h)
        new Work_Order__c(Subject__c='Active water leak under sink', Category__c='Plumbing', Priority__c='Critical', Status__c='In Progress', Description__c='Water leaking under the break-room sink, spreading to the hallway.', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit__c='Bay 4', Tenant_Name__c='Sunbelt Rentals', Vendor__c='Rapid Rooter Plumbing', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-4), First_Touched_Date__c=n.addHours(-3)),
        // 2 High breached escalation (60h / 48h SLA), New + UNTOUCHED
        new Work_Order__c(Subject__c='Parking lot lights out on north side', Category__c='Electrical', Priority__c='High', Status__c='New', Description__c='Whole north row of lot lights out for two nights.', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit__c='Common area', Tenant_Name__c='Golden Wok', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-60)),
        // 3 High On Hold, tenant unresponsive (40h / 48h -> due soon)
        new Work_Order__c(Subject__c='Thermostat dead — no cooling control', Category__c='HVAC', Priority__c='High', Status__c='On Hold', Description__c='Thermostat screen blank; unit cycles on its own.', Property_Asset__c=assets.get('Heights Marketplace').Id, Unit__c='Suite 3', Tenant_Name__c='Pearl Nails', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-40), First_Touched_Date__c=n.addHours(-38), Delay_Reason__c='Tenant unresponsive'),
        // 4 High on-track (fresh)
        new Work_Order__c(Subject__c='Walk-in cooler temperature rising', Category__c='Refrigeration', Priority__c='High', Status__c='In Progress', Description__c='Walk-in cooler at 48F and climbing since this morning.', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit__c='Bay 1', Tenant_Name__c='Cafe Verde', Vendor__c='ColdChain Services', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-6), First_Touched_Date__c=n.addHours(-5)),
        // 5 Medium In Progress on-track (72h / 168h)
        new Work_Order__c(Subject__c='Restroom faucet dripping constantly', Category__c='Plumbing', Priority__c='Medium', Status__c='In Progress', Description__c='Patient restroom faucet drips non-stop even when shut tight.', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit__c='Suite 200', Tenant_Name__c='Metro Urgent Care', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-72), First_Touched_Date__c=n.addHours(-48)),
        // 6 Medium On Hold, Other (150h / 168h -> due soon)
        new Work_Order__c(Subject__c='Ceiling tile stained near entry', Category__c='General', Priority__c='Medium', Status__c='On Hold', Description__c='Large brown water stain on the ceiling tile at the entrance.', Property_Asset__c=assets.get('Katy Mills Strip').Id, Unit__c='Floor 2', Tenant_Name__c='TechHub Coworking', Vendor__c='Summit Roofing', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-150), First_Touched_Date__c=n.addHours(-140), Delay_Reason__c='Other'),
        // 7 Medium New UNTOUCHED (fresh)
        new Work_Order__c(Subject__c='Rear exit door closer broken', Category__c='Doors & Locks', Priority__c='Medium', Status__c='New', Description__c='Closer arm snapped; door slams shut hard.', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit__c='Anchor B', Tenant_Name__c='Anytime Fitness', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-10)),
        // 8 Low In Progress on-track
        new Work_Order__c(Subject__c='Monument sign lamp out', Category__c='Electrical', Priority__c='Low', Status__c='In Progress', Description__c='Monument sign panel not lighting at night for one tenant.', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit__c='Suite 210', Tenant_Name__c='Bright Smiles Ortho', Vendor__c='BrightSpark Electric', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-240), First_Touched_Date__c=n.addHours(-180)),
        // 9 Low breached (400h / 360h SLA) In Progress
        new Work_Order__c(Subject__c='Sprinkler head broken at entrance bed', Category__c='Landscaping', Priority__c='Low', Status__c='In Progress', Description__c='Sprinkler head snapped; water pools on the sidewalk.', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit__c='Suite 150', Tenant_Name__c='Prime Insurance', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-400), First_Touched_Date__c=n.addHours(-300)),
        // 10 Critical CLOSED (resolved)
        new Work_Order__c(Subject__c='RTU-2 compressor failure — no AC', Category__c='HVAC', Priority__c='Critical', Status__c='Closed', Description__c='Rooftop unit failed completely; no air movement.', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit__c='Suite 120', Tenant_Name__c='Riverside Dental', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-340), First_Touched_Date__c=n.addHours(-339), Completed_Date__c=n.addHours(-320)),
        // 11 High COMPLETED (resolved)
        new Work_Order__c(Subject__c='Sewer smell in corridor', Category__c='Plumbing', Priority__c='High', Status__c='Completed', Description__c='Strong sewer smell in the shared corridor.', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit__c='Bay 4', Tenant_Name__c='Sunbelt Rentals', Vendor__c='Rapid Rooter Plumbing', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-420), First_Touched_Date__c=n.addHours(-419), Completed_Date__c=n.addHours(-390)),
        // 12 Medium CLOSED (resolved) — Electrical
        new Work_Order__c(Subject__c='Outlet dead in suite kitchen', Category__c='Electrical', Priority__c='Medium', Status__c='Closed', Description__c='Outlet by the kitchen prep counter is dead.', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit__c='Unit 8', Tenant_Name__c='Golden Wok', Vendor__c='BrightSpark Electric', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-560), First_Touched_Date__c=n.addHours(-540), Completed_Date__c=n.addHours(-460)),
        // 13 Medium CLOSED (resolved) — HVAC
        new Work_Order__c(Subject__c='Vent noise and weak airflow', Category__c='HVAC', Priority__c='Medium', Status__c='Closed', Description__c='Vents rattle loudly and push little air.', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit__c='Suite 200', Tenant_Name__c='Metro Urgent Care', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-500), First_Touched_Date__c=n.addHours(-480), Completed_Date__c=n.addHours(-380)),
        // 14 High CLOSED (resolved) — Refrigeration
        new Work_Order__c(Subject__c='AC intermittent — cycling off', Category__c='HVAC', Priority__c='High', Status__c='Closed', Description__c='AC shuts off every hour, never gets cool.', Property_Asset__c=assets.get('Katy Mills Strip').Id, Unit__c='Unit 12', Tenant_Name__c='Dollar Depot', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-460), First_Touched_Date__c=n.addHours(-450), Completed_Date__c=n.addHours(-410))
    };
    insert ws;

    List<Work_Order_Activity__c> acts = new List<Work_Order_Activity__c>();
    // (work-order index, hours ago, kind, actor, text)
    List<List<Object>> entries = new List<List<Object>>{
        new List<Object>{ 0, 30, 'Sync',   'Yardi', 'Work order created from tenant call — AC not cooling, suite reading 84F.' },
        new List<Object>{ 0, 29, 'Status', 'Yardi', 'Status changed: New → In Progress. Dispatched in Yardi.' },
        new List<Object>{ 0, 26, 'Vendor', 'Yardi', 'Vendor assigned: Gulf Coast HVAC. Site visit completed same day.' },
        new List<Object>{ 0, 8,  'Note',   'Yardi', 'Vendor note: compressor start capacitor on backorder — ETA 2 days.' },
        new List<Object>{ 0, 4,  'Flag',   'System', 'Reason for delay flagged in Salesforce: Vendor delay.' },
        new List<Object>{ 1, 4,  'Sync',   'Yardi', 'Work order created from tenant call — active leak under sink, water spreading.' },
        new List<Object>{ 1, 3,  'Vendor', 'Yardi', 'Vendor assigned: Rapid Rooter Plumbing. Emergency dispatch — shutoff valve closed.' },
        new List<Object>{ 2, 60, 'Sync',   'Yardi', 'Work order created from tenant portal — north lot lights out, tenants closing after dark.' },
        new List<Object>{ 3, 40, 'Sync',   'Yardi', 'Work order created from tenant call — thermostat unresponsive, no cooling control.' },
        new List<Object>{ 3, 30, 'Status', 'Yardi', 'Status changed: In Progress → On Hold. Two access attempts failed — tenant not answering.' },
        new List<Object>{ 3, 12, 'Flag',   'System', 'Reason for delay flagged in Salesforce: Tenant unresponsive.' },
        new List<Object>{ 4, 6,  'Sync',   'Yardi', 'Work order created from tenant call — walk-in cooler at 48F and climbing.' },
        new List<Object>{ 4, 5,  'Vendor', 'Yardi', 'Vendor assigned: ColdChain Services. Technician en route.' },
        new List<Object>{ 5, 72, 'Sync',   'Yardi', 'Work order created from tenant portal — restroom faucet dripping constantly.' },
        new List<Object>{ 6, 150,'Sync',   'Yardi', 'Work order created — ceiling tile stained near entry, likely prior roof leak.' },
        new List<Object>{ 6, 120,'Status', 'Yardi', 'Status changed: In Progress → On Hold. Waiting on roof inspection report.' },
        new List<Object>{ 6, 24, 'Flag',   'System', 'Reason for delay flagged in Salesforce: Other — pending roof inspection.' },
        new List<Object>{ 7, 10, 'Sync',   'Yardi', 'Work order created from tenant portal — rear exit door closer broken, door slamming.' },
        new List<Object>{ 8, 240,'Sync',   'Yardi', 'Work order created during property walk — monument sign lamp out for one tenant.' },
        new List<Object>{ 8, 40, 'Vendor', 'Yardi', 'Vendor assigned: BrightSpark Electric — bundled with other electrical punch items.' },
        new List<Object>{ 9, 400,'Sync',   'Yardi', 'Work order created from tenant portal — sprinkler head broken, water pooling.' },
        new List<Object>{ 10,340,'Sync',   'Yardi', 'Work order created from tenant call — RTU-2 compressor failure, no cooling.' },
        new List<Object>{ 10,320,'Status', 'Yardi', 'Status changed: Completed → Closed. Compressor replaced, cooling restored.' },
        new List<Object>{ 11,420,'Sync',   'Yardi', 'Work order created from tenant call — sewer odor in shared corridor.' },
        new List<Object>{ 11,390,'Status', 'Yardi', 'Status changed: In Progress → Completed. Dried P-trap refilled and sealed.' },
        new List<Object>{ 12,560,'Sync',   'Yardi', 'Work order created from tenant portal — dead outlet in suite kitchen.' },
        new List<Object>{ 13,500,'Sync',   'Yardi', 'Work order created from tenant call — vent noise and weak airflow.' },
        new List<Object>{ 14,460,'Sync',   'Yardi', 'Work order created from tenant call — AC cycling off intermittently.' }
    };
    for (List<Object> e : entries) {
        acts.add(new Work_Order_Activity__c(
            Work_Order__c = ws[(Integer) e[0]].Id,
            Kind__c = (String) e[2],
            Actor__c = (String) e[3],
            Detail__c = (String) e[4],
            Entry_Date__c = n.addHours(-(Integer) e[1])
        ));
    }
    insert acts;
    System.debug('Seeded ' + ws.size() + ' work orders with ' + acts.size() + ' activity entries.');
}
```

- [ ] **Step 2: Run the seed**

```powershell
Set-Location F:\Acquisition-Design-Salesforce
sf apex run -f scripts/seed-work-orders.apex --json
```
Expected: success:true.

- [ ] **Step 3: End-to-end verification**

1. Full test suite for the module + neighbors (regression):
```powershell
sf apex run test -n WorkOrderControllerTest -n LeaseRenewalControllerTest -n LeaseInquiryControllerTest -n BrokerAssignmentControllerTest --wait 10 --result-format human
```
Expected: 100% pass.
2. KPI sanity via anonymous Apex (write to a scratchpad file, run with `sf apex run`):
```apex
WorkOrderController.HomeKpis k = WorkOrderController.getHomeKpis();
System.assertEquals(10, k.open, '15 seeded minus 5 resolved (10-14)');
System.assert(k.breached >= 3, 'AC down + lot lights + sprinkler at least');
System.assert(k.untouched >= 2, 'lot lights + door closer');
System.assertEquals(2, [SELECT COUNT() FROM Work_Order__c WHERE Is_Escalation__c = true], 'Critical/High breached: AC down + lot lights');
System.assertEquals(3, [SELECT COUNT() FROM Work_Order__c WHERE Delay_Reason__c != '—' AND Is_Open__c = true], 'three open records carry a delay reason: AC down (Vendor delay), Thermostat (Tenant unresponsive), Ceiling tile (Other)');
System.debug('E2E WO OK');
```
3. No manual UI step is required for this module — it is list + detail + dashboard only (no Kanban). The Work Order Health dashboard and reports are reachable via the app's Dashboards/Reports (App Launcher). Note this in the final report.

- [ ] **Step 4: Commit and push**

```powershell
git add scripts/seed-work-orders.apex
git commit -m "Work Order Tracker: idempotent seed script (15 work orders, offset datetimes)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

## Promotion checklist (before deploying beyond this scratch org)

- Dashboard `Work_Orders/Work_Order_Health` `owner`/`runningUser` are hardcoded to `test-3iuncy5c1je5@example.com` — repoint to the deploying admin.
- Read-only is enforced at the record page (layout Readonly + Path) but NOT at the data layer: the perm set grants create/edit/delete + editable FLS on the mirror fields, and the object tab shows a standard New button. This is deliberate demo scope — the Path (hideUpdateButton=false) is how the admin plays the role of Yardi. To lock it down for production: set the mirror fields' FLS `editable=false` (the before-save touch-sync flow runs in system mode, so stamping still works), drop create/delete (or move to an admin-only perm set), and optionally add a validation rule allowing only `Delay_Reason__c` to change.
- No Kanban / no manual UI step — the module is list + detail + dashboard only.
