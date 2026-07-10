# Property Management Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native Salesforce "Property Management" dashboard — 6 KPI metrics + 5 body components — each backed by its own report, with three new read-only Yardi-mirror objects (Delinquency, CAM Reconciliation, Insurance Policy) and seeded dummy data.

**Architecture:** Three new Lookup-to-Property_Asset objects hold the delinquency/CAM/insurance data. A formula field on `Unit__c` powers count-based occupancy. Eight native reports (Summary format) feed a native Dashboard's metric/bar/table components. All read-only; Yardi ETL later.

**Tech Stack:** Salesforce metadata API 62.0 — CustomObject, CustomField, Report, Dashboard, PermissionSet, anonymous Apex seed.

## Global Constraints

- Branch: `feature/pm-role-dashboards` (off main). Commit after every task.
- API version **62.0**. Default org **DPEG-Acq-3**. Run all `sf` from repo root `f:\Acquisition-Design-Salesforce`.
- **Deploy order:** objects/fields → perm set → reports → dashboard → seed. Reports reference objects; the dashboard references reports by `Folder/ReportApiName`. A dashboard deployed before its reports exist fails. Deploy each layer as its own successful deploy.
- New objects are **standalone Lookup** children of `Property_Asset__c` (NOT master-detail): `sharingModel` ReadWrite, `enableReports` true, read-only enforced via perm set only.
- New fields get NO FLS on deploy — the perm-set task is mandatory (else "No such column" in report UI). These lookups are standalone (NOT master-detail), so they DO take `fieldPermissions` — the perm set grants read FLS on each `Property_Asset__c` lookup too. (Only master-detail fields must omit FLS.)
- **Shared perm set** `Property_Management_Access` is shared across sibling branches in the org: deploy the org-superset version with `--ignore-conflicts`, then commit only the minimal diff (established gotcha).
- Reports live in a new `Property Management` report folder; the dashboard in a new `Property Management` dashboard folder. Report `reportType` for a custom object = `CustomEntity$<ApiName>`.
- Dashboard running user = `test-3iuncy5c1je5@example.com`, `dashboardType` SpecifiedUser (matches existing `Work_Order_Health`; repoint on promotion).
- `Unit__c`, `Lease_Renewal__c`, `Property_Asset__c` live on sibling branches, not main. Their field/report/dashboard XML deploys to the org (which has them) but rides as cross-branch artifacts on this branch — expected, matches how the org works.

---

### Task 1: Three new objects + fields + Unit__c occupancy field

**Files (all Create except the Unit__c field):**
- `force-app/main/default/objects/Delinquency__c/Delinquency__c.object-meta.xml` + 6 field files
- `force-app/main/default/objects/CAM_Reconciliation__c/CAM_Reconciliation__c.object-meta.xml` + 5 field files
- `force-app/main/default/objects/Insurance_Policy__c/Insurance_Policy__c.object-meta.xml` + 6 field files
- `force-app/main/default/objects/Unit__c/fields/Occupied_Flag__c.field-meta.xml` (field only — object already exists in org)

**Interfaces:**
- Consumes: existing `Property_Asset__c`, `Unit__c` (in org).
- Produces: `Delinquency__c` (rel `Delinquencies`), `CAM_Reconciliation__c` (rel `CAM_Reconciliations`), `Insurance_Policy__c` (rel `Insurance_Policies`), and `Unit__c.Occupied_Flag__c`. Field API names below are the contract for Tasks 2–5.

- [ ] **Step 1: Write the three object files**

Each object-meta.xml uses this shape (shown for Delinquency; repeat for the other two with their label/plural/displayFormat). Copy the 30 `<actionOverrides>` Default blocks from `force-app/main/default/objects/Property__c/Property__c.object-meta.xml` OR author them; the minimum deployable object needs the tail below — the actionOverrides are optional for deploy but include them to match repo objects. Minimal valid object:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <allowInChatterGroups>false</allowInChatterGroups>
    <compactLayoutAssignment>SYSTEM</compactLayoutAssignment>
    <deploymentStatus>Deployed</deploymentStatus>
    <enableActivities>false</enableActivities>
    <enableBulkApi>true</enableBulkApi>
    <enableFeeds>false</enableFeeds>
    <enableHistory>false</enableHistory>
    <enableLicensing>false</enableLicensing>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <enableSharing>true</enableSharing>
    <enableStreamingApi>true</enableStreamingApi>
    <externalSharingModel>Private</externalSharingModel>
    <label>Delinquency</label>
    <nameField>
        <displayFormat>DEL-{0000}</displayFormat>
        <label>Delinquency Number</label>
        <type>AutoNumber</type>
    </nameField>
    <pluralLabel>Delinquencies</pluralLabel>
    <searchLayouts></searchLayouts>
    <sharingModel>ReadWrite</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
```

For CAM_Reconciliation__c: label `CAM Reconciliation`, plural `CAM Reconciliations`, displayFormat `CAM-{0000}`, nameField label `CAM Reconciliation Number`.
For Insurance_Policy__c: label `Insurance Policy`, plural `Insurance Policies`, displayFormat `INS-{0000}`, nameField label `Insurance Policy Number`.

- [ ] **Step 2: Write Delinquency__c fields (6)**

`fields/Property_Asset__c.field-meta.xml` (Lookup — note: NOT master-detail):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Property_Asset__c</fullName>
    <deleteConstraint>SetNull</deleteConstraint>
    <label>Property Asset</label>
    <referenceTo>Property_Asset__c</referenceTo>
    <relationshipLabel>Delinquencies</relationshipLabel>
    <relationshipName>Delinquencies</relationshipName>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Lookup</type>
</CustomField>
```

`fields/Tenant_Name__c.field-meta.xml` — Text(120):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Tenant_Name__c</fullName>
    <label>Tenant Name</label>
    <length>120</length>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Text</type>
    <unique>false</unique>
</CustomField>
```

`fields/Unit_Suite__c.field-meta.xml` — Text(20), same shape as Tenant_Name__c with `<fullName>Unit_Suite__c</fullName>`, `<label>Unit / Suite</label>`, `<length>20</length>`.

`fields/Balance__c.field-meta.xml` — Currency(16,2):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Balance__c</fullName>
    <label>Balance</label>
    <precision>16</precision>
    <required>false</required>
    <scale>2</scale>
    <trackTrending>false</trackTrending>
    <type>Currency</type>
</CustomField>
```

`fields/Aging_Bucket__c.field-meta.xml` — restricted Picklist:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Aging_Bucket__c</fullName>
    <label>Aging Bucket</label>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>1-30 Days</fullName><default>false</default><label>1-30 Days</label></value>
            <value><fullName>31-60 Days</fullName><default>false</default><label>31-60 Days</label></value>
            <value><fullName>61-90 Days</fullName><default>false</default><label>61-90 Days</label></value>
            <value><fullName>90+ Days</fullName><default>false</default><label>90+ Days</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
```

`fields/Yardi_AR_Id__c.field-meta.xml` — External ID Text(50):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Yardi_AR_Id__c</fullName>
    <label>Yardi AR Id</label>
    <caseSensitive>false</caseSensitive>
    <externalId>true</externalId>
    <length>50</length>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Text</type>
    <unique>true</unique>
</CustomField>
```

- [ ] **Step 3: Write CAM_Reconciliation__c fields (5)**

`Property_Asset__c.field-meta.xml` — same Lookup shape as Delinquency's but `<relationshipLabel>CAM Reconciliations</relationshipLabel>` and `<relationshipName>CAM_Reconciliations</relationshipName>`.

`Reconciliation_Year__c.field-meta.xml` — Text(4), label `Reconciliation Year`.

`Status__c.field-meta.xml` — restricted Picklist with default:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Status__c</fullName>
    <label>Status</label>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value><fullName>Pending</fullName><default>true</default><label>Pending</label></value>
            <value><fullName>In Review</fullName><default>false</default><label>In Review</label></value>
            <value><fullName>Approved</fullName><default>false</default><label>Approved</label></value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
```

`Amount__c.field-meta.xml` — Currency(16,2), label `Amount`.

`Yardi_CAM_Id__c.field-meta.xml` — External ID Text(50), label `Yardi CAM Id`.

- [ ] **Step 4: Write Insurance_Policy__c fields (6)**

`Policy_Name__c.field-meta.xml` — Text(120), label `Policy Name`.

`Property_Asset__c.field-meta.xml` — Lookup shape, `<relationshipLabel>Insurance Policies</relationshipLabel>`, `<relationshipName>Insurance_Policies</relationshipName>`.

`Carrier__c.field-meta.xml` — Text(80), label `Carrier`.

`Expiry_Date__c.field-meta.xml` — Date:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Expiry_Date__c</fullName>
    <label>Expiry Date</label>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Date</type>
</CustomField>
```

`Days_To_Expiry__c.field-meta.xml` — Formula Number:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Days_To_Expiry__c</fullName>
    <label>Days To Expiry</label>
    <formula>Expiry_Date__c - TODAY()</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>
    <trackTrending>false</trackTrending>
    <type>Number</type>
</CustomField>
```

`Yardi_Policy_Id__c.field-meta.xml` — External ID Text(50), label `Yardi Policy Id`.

- [ ] **Step 5: Write Unit__c occupancy formula field**

`force-app/main/default/objects/Unit__c/fields/Occupied_Flag__c.field-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Occupied_Flag__c</fullName>
    <label>Occupied Flag</label>
    <formula>IF(ISPICKVAL(Status__c, &apos;Occupied&apos;), 100, 0)</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>
    <trackTrending>false</trackTrending>
    <type>Number</type>
</CustomField>
```

(Only the field file goes under `Unit__c/fields/` — do not add a `Unit__c.object-meta.xml` to this branch; the object already lives in the org and on the rent-roll branch.)

- [ ] **Step 6: Deploy**

Run: `sf project deploy start -d force-app/main/default/objects/Delinquency__c -d force-app/main/default/objects/CAM_Reconciliation__c -d force-app/main/default/objects/Insurance_Policy__c -d force-app/main/default/objects/Unit__c/fields/Occupied_Flag__c.field-meta.xml -o DPEG-Acq-3 --ignore-conflicts`
Expected: `Status: Succeeded` (3 objects + 17 new-object fields + 1 Unit field).

- [ ] **Step 7: Verify**

Run: `sf data query -o DPEG-Acq-3 -q "SELECT QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName IN ('Delinquency__c','CAM_Reconciliation__c','Insurance_Policy__c')"`
Expected: all three listed.
Run: `sf data query -o DPEG-Acq-3 -q "SELECT Occupied_Flag__c, Status__c FROM Unit__c LIMIT 3"`
Expected: occupied units return 100, vacant return 0.

- [ ] **Step 8: Commit**

```bash
git add force-app/main/default/objects/Delinquency__c force-app/main/default/objects/CAM_Reconciliation__c force-app/main/default/objects/Insurance_Policy__c force-app/main/default/objects/Unit__c
git commit -m "PM dashboard objects: Delinquency/CAM/Insurance Yardi mirrors + Unit occupancy flag"
```

---

### Task 2: Perm set — read-only access to the new objects

**Files:**
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Consumes: objects/fields from Task 1.
- Produces: PM users can read Delinquency/CAM/Insurance + Unit occupancy. Without this, the report builder shows "No such column".

**Shared-file procedure (established gotcha):** the branch commit must be minimal (main base + these blocks), but the *deploy* must go to the org-superset (which holds sibling branches' grants) so it isn't wiped. Do BOTH.

- [ ] **Step 1: Build the minimal branch file**

Start the branch file from main's version (already checked out — it currently has only Onboarding/Task content). Add, in the correct element-group positions (PermissionSet XML groups by element type; keep each block among its own kind, and each group must stay contiguous):

Object permissions — add after the existing `<objectPermissions>` block(s):
```xml
    <objectPermissions>
        <allowCreate>false</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>false</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Delinquency__c</object>
        <viewAllRecords>true</viewAllRecords>
    </objectPermissions>
    <objectPermissions>
        <allowCreate>false</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>false</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>CAM_Reconciliation__c</object>
        <viewAllRecords>true</viewAllRecords>
    </objectPermissions>
    <objectPermissions>
        <allowCreate>false</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>false</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Insurance_Policy__c</object>
        <viewAllRecords>true</viewAllRecords>
    </objectPermissions>
```

Field permissions — add among the existing `<fieldPermissions>` lines (all read-only; 18 fields):
```xml
    <!-- PM dashboard fields (Yardi mirror, read-only): -->
    <fieldPermissions><editable>false</editable><field>Delinquency__c.Property_Asset__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Delinquency__c.Tenant_Name__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Delinquency__c.Unit_Suite__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Delinquency__c.Balance__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Delinquency__c.Aging_Bucket__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Delinquency__c.Yardi_AR_Id__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>CAM_Reconciliation__c.Property_Asset__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>CAM_Reconciliation__c.Reconciliation_Year__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>CAM_Reconciliation__c.Status__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>CAM_Reconciliation__c.Amount__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>CAM_Reconciliation__c.Yardi_CAM_Id__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Insurance_Policy__c.Policy_Name__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Insurance_Policy__c.Property_Asset__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Insurance_Policy__c.Carrier__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Insurance_Policy__c.Expiry_Date__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Insurance_Policy__c.Days_To_Expiry__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Insurance_Policy__c.Yardi_Policy_Id__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Unit__c.Occupied_Flag__c</field><readable>true</readable></fieldPermissions>
```

- [ ] **Step 2: Build the deploy-superset and deploy it**

The org's live perm set has sibling grants (broker/lease/work-order/rent-roll) not on this branch; deploying the minimal branch file directly would wipe them. Instead:

```bash
# retrieve org-live perm set to a temp dir
sf project retrieve start -m "PermissionSet:Property_Management_Access" -o DPEG-Acq-3 \
  --target-metadata-dir /tmp/pmps --unzip
```
Splice the same object/field blocks (from Step 1) into the retrieved file — insert the objectPermissions before its LAST `</objectPermissions>` and the fieldPermissions before its LAST `</fieldPermissions>` (so groups stay contiguous — the "Element X is duplicated" error means a group was broken). Copy the spliced superset over the working file, then:

```bash
sf project deploy start -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -o DPEG-Acq-3 --ignore-conflicts
```
Expected: `Status: Succeeded`.

- [ ] **Step 3: Restore the minimal branch file and commit**

Overwrite the working file with the minimal version from Step 1 (main base + new blocks only), then:
```bash
git add force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "Property_Management_Access: read-only PM dashboard objects + occupancy field"
```
Verify the committed diff shows ONLY the 3 objectPermissions + 18 fieldPermissions additions vs main (no sibling content).

---

### Task 3: Report folder + 8 reports

**Files (all Create):**
- `force-app/main/default/reports/Property_Management.reportFolder-meta.xml`
- `force-app/main/default/reports/Property_Management/{Managed_Properties, Occupancy_by_Property, Renewals_Due_90d, Renewal_Pipeline_Buckets, Delinquency_Aging, CAM_Pending, CAM_Reconciliation_Status, Insurance_Expiring}.report-meta.xml`

**Interfaces:**
- Consumes: objects/fields from Task 1.
- Produces: 8 reports at `Property_Management/<ApiName>`, referenced by the Task 4 dashboard. Report API name = file name; `<name>` = display label.

Bucket/aggregate/lookup-grouping report XML is fiddly — after deploy, open each report in the org to confirm it renders (groupings populate, buckets split correctly); adjust boundaries if off. This is the verification for this task.

- [ ] **Step 1: Folder meta**

`reports/Property_Management.reportFolder-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ReportFolder xmlns="http://soap.sforce.com/2006/04/metadata">
    <name>Property Management</name>
</ReportFolder>
```

- [ ] **Step 2: `Managed_Properties.report-meta.xml`** (KPI Properties)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Property_Asset__c.Name</field></columns>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Property_Asset__c.Property_Type__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Managed Properties</name>
    <reportType>CustomEntity$Property_Asset__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 3: `Occupancy_by_Property.report-meta.xml`** (KPI Occupancy + occupancy chart)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <aggregates>
        <acrossGroupingContext>GLOBAL</acrossGroupingContext>
        <calculatedFormula>Unit__c.Occupied_Flag__c:AVG</calculatedFormula>
        <datatype>number</datatype>
        <developerName>FORMULA1</developerName>
        <downGroupingContext>GLOBAL</downGroupingContext>
        <isActive>false</isActive>
        <isCrossBlock>false</isCrossBlock>
        <masterLabel>Occupancy %</masterLabel>
        <scale>0</scale>
    </aggregates>
    <columns>
        <aggregateTypes>Average</aggregateTypes>
        <field>Unit__c.Occupied_Flag__c</field>
    </columns>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Unit__c.Property_Asset__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Occupancy by Property</name>
    <reportType>CustomEntity$Unit__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
(The dashboard's occupancy metric/chart use the built-in average summary column `a!Unit__c.Occupied_Flag__c`. The `<aggregates>` block is optional/inactive — kept as a labeled helper; if it errors on deploy, delete the whole `<aggregates>` element and rely on the `Average` column summary.)

- [ ] **Step 4: `Renewals_Due_90d.report-meta.xml`** (KPI Renewals Due 90d)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Renewal__c.Tenant_Name__c</field></columns>
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
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Lease_Renewal__c.Stage__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Renewals Due 90d</name>
    <reportType>CustomEntity$Lease_Renewal__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 5: `Renewal_Pipeline_Buckets.report-meta.xml`** (renewal pipeline chart)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <buckets>
        <bucketType>number</bucketType>
        <developerName>BucketField_RenewalBucket</developerName>
        <masterLabel>Renewal Bucket</masterLabel>
        <nullTreatment>n</nullTreatment>
        <sourceColumnName>Lease_Renewal__c.Days_To_Expiry__c</sourceColumnName>
        <useOther>false</useOther>
        <values><sourceValues><to>0</to></sourceValues><value>Expired - M2M</value></values>
        <values><sourceValues><from>0</from><to>30</to></sourceValues><value>0-30d</value></values>
        <values><sourceValues><from>30</from><to>60</to></sourceValues><value>31-60d</value></values>
        <values><sourceValues><from>60</from><to>90</to></sourceValues><value>61-90d</value></values>
        <values><sourceValues><from>90</from><to>180</to></sourceValues><value>91-180d</value></values>
    </buckets>
    <columns><field>Lease_Renewal__c.Tenant_Name__c</field></columns>
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
            <value>180</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Lease_Renewal__c.BucketField_RenewalBucket</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Renewal Pipeline Buckets</name>
    <reportType>CustomEntity$Lease_Renewal__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
(Number-bucket boundaries are `from`-exclusive / `to`-inclusive: `to=0` → ≤0 (Expired–M2M); `from=0,to=30` → 0<v≤30; etc. Verify on deploy; nudge boundaries if a value lands in the wrong band.)

- [ ] **Step 6: `Delinquency_Aging.report-meta.xml`** (KPI Delinquent Tenants + aging chart)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns>
        <aggregateTypes>Sum</aggregateTypes>
        <field>Delinquency__c.Balance__c</field>
    </columns>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Delinquency__c.Aging_Bucket__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Delinquency Aging</name>
    <reportType>CustomEntity$Delinquency__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 7: `CAM_Pending.report-meta.xml`** (KPI CAM Recon Pending)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>CAM_Reconciliation__c.Property_Asset__c</field></columns>
    <filter>
        <criteriaItems>
            <column>CAM_Reconciliation__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>notEqual</operator>
            <value>Approved</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>CAM_Reconciliation__c.Status__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>CAM Recon Pending</name>
    <reportType>CustomEntity$CAM_Reconciliation__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 8: `CAM_Reconciliation_Status.report-meta.xml`** (CAM table)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>CAM_Reconciliation__c.Reconciliation_Year__c</field></columns>
    <columns><field>CAM_Reconciliation__c.Status__c</field></columns>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>CAM_Reconciliation__c.Property_Asset__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>CAM Reconciliation Status</name>
    <reportType>CustomEntity$CAM_Reconciliation__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
(Native dashboard table conditional formatting is numeric-only, so the Approved/In Review/Pending status shows as plain text — no color. Acceptable; the mockup's colored pills are not natively reproducible on a report table.)

- [ ] **Step 9: `Insurance_Expiring.report-meta.xml`** (KPI Insurance + alerts table)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Insurance_Policy__c.Carrier__c</field></columns>
    <columns><field>Insurance_Policy__c.Days_To_Expiry__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Insurance_Policy__c.Days_To_Expiry__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>lessOrEqual</operator>
            <value>60</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Insurance_Policy__c.Policy_Name__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Insurance Expiring</name>
    <reportType>CustomEntity$Insurance_Policy__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 10: Deploy**

Run: `sf project deploy start -d force-app/main/default/reports/Property_Management.reportFolder-meta.xml -d force-app/main/default/reports/Property_Management -o DPEG-Acq-3 --ignore-conflicts`
Expected: `Status: Succeeded` (1 folder + 8 reports). If a report fails on the `<aggregates>`/`<buckets>` XML, read the error, apply the fallback noted in that step, redeploy.

- [ ] **Step 11: Verify each report opens**

Run: `sf org open -o DPEG-Acq-3 -p "/lightning/o/Report/home"` — open the Property Management folder, confirm all 8 reports open without error (they'll be empty until Task 5 seeds data; the point is they render/compile).

- [ ] **Step 12: Commit**

```bash
git add force-app/main/default/reports/Property_Management.reportFolder-meta.xml force-app/main/default/reports/Property_Management
git commit -m "PM dashboard reports: 8 native reports (occupancy, renewals, delinquency, CAM, insurance)"
```

---

### Task 4: Dashboard folder + Property Management dashboard

**Files (all Create):**
- `force-app/main/default/dashboards/Property_Management.dashboardFolder-meta.xml`
- `force-app/main/default/dashboards/Property_Management/Property_Management_Overview.dashboard-meta.xml`

**Interfaces:**
- Consumes: the 8 reports from Task 3 (referenced as `Property_Management/<ApiName>`).
- Produces: the dashboard, activated in the PM app in Task 5's verification.

- [ ] **Step 1: Folder meta**

`dashboards/Property_Management.dashboardFolder-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<DashboardFolder xmlns="http://soap.sforce.com/2006/04/metadata">
    <name>Property Management</name>
</DashboardFolder>
```

- [ ] **Step 2: Dashboard file**

`dashboards/Property_Management/Property_Management_Overview.dashboard-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Dashboard xmlns="http://soap.sforce.com/2006/04/metadata">
    <backgroundEndColor>#FFFFFF</backgroundEndColor>
    <backgroundFadeDirection>Diagonal</backgroundFadeDirection>
    <backgroundStartColor>#FFFFFF</backgroundStartColor>
    <dashboardGridLayout>
        <dashboardGridComponents>
            <colSpan>2</colSpan><columnIndex>0</columnIndex><rowIndex>0</rowIndex><rowSpan>4</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary><column>RowCount</column></chartSummary>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorHighColor>#0B5394</indicatorHighColor>
                <indicatorLowColor>#0B5394</indicatorLowColor>
                <indicatorMiddleColor>#0B5394</indicatorMiddleColor>
                <metricLabel>Properties</metricLabel>
                <report>Property_Management/Managed_Properties</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>2</colSpan><columnIndex>2</columnIndex><rowIndex>0</rowIndex><rowSpan>4</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary><column>a!Unit__c.Occupied_Flag__c</column></chartSummary>
                <componentType>Metric</componentType>
                <decimalPrecision>0</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorHighColor>#1B7A4B</indicatorHighColor>
                <indicatorLowColor>#1B7A4B</indicatorLowColor>
                <indicatorMiddleColor>#1B7A4B</indicatorMiddleColor>
                <metricLabel>Portfolio Occupancy %</metricLabel>
                <report>Property_Management/Occupancy_by_Property</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>2</colSpan><columnIndex>4</columnIndex><rowIndex>0</rowIndex><rowSpan>4</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary><column>RowCount</column></chartSummary>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorHighColor>#8A5A00</indicatorHighColor>
                <indicatorLowColor>#8A5A00</indicatorLowColor>
                <indicatorMiddleColor>#8A5A00</indicatorMiddleColor>
                <metricLabel>Renewals Due 90d</metricLabel>
                <report>Property_Management/Renewals_Due_90d</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>2</colSpan><columnIndex>6</columnIndex><rowIndex>0</rowIndex><rowSpan>4</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary><column>RowCount</column></chartSummary>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorHighColor>#C23934</indicatorHighColor>
                <indicatorLowColor>#C23934</indicatorLowColor>
                <indicatorMiddleColor>#C23934</indicatorMiddleColor>
                <metricLabel>Delinquent Tenants</metricLabel>
                <report>Property_Management/Delinquency_Aging</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>2</colSpan><columnIndex>8</columnIndex><rowIndex>0</rowIndex><rowSpan>4</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary><column>RowCount</column></chartSummary>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorHighColor>#8A5A00</indicatorHighColor>
                <indicatorLowColor>#8A5A00</indicatorLowColor>
                <indicatorMiddleColor>#8A5A00</indicatorMiddleColor>
                <metricLabel>CAM Recon Pending</metricLabel>
                <report>Property_Management/CAM_Pending</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>2</colSpan><columnIndex>10</columnIndex><rowIndex>0</rowIndex><rowSpan>4</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary><column>RowCount</column></chartSummary>
                <componentType>Metric</componentType>
                <decimalPrecision>-1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorHighColor>#C23934</indicatorHighColor>
                <indicatorLowColor>#C23934</indicatorLowColor>
                <indicatorMiddleColor>#C23934</indicatorMiddleColor>
                <metricLabel>Insurance Expiring</metricLabel>
                <report>Property_Management/Insurance_Expiring</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>4</colSpan><columnIndex>0</columnIndex><rowIndex>4</rowIndex><rowSpan>8</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartAxisRange>Auto</chartAxisRange>
                <chartSummary><axisBinding>y</axisBinding><column>RowCount</column></chartSummary>
                <componentType>Bar</componentType>
                <decimalPrecision>0</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <drillEnabled>true</drillEnabled>
                <drillToDetailEnabled>true</drillToDetailEnabled>
                <enableHover>true</enableHover>
                <expandOthers>false</expandOthers>
                <groupingColumn>Lease_Renewal__c.BucketField_RenewalBucket</groupingColumn>
                <groupingSortProperties/>
                <legendPosition>Bottom</legendPosition>
                <report>Property_Management/Renewal_Pipeline_Buckets</report>
                <showPercentage>false</showPercentage>
                <showValues>true</showValues>
                <sortBy>RowLabelAscending</sortBy>
                <title>Lease Renewal Pipeline</title>
                <useReportChart>false</useReportChart>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>4</colSpan><columnIndex>4</columnIndex><rowIndex>4</rowIndex><rowSpan>8</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartAxisRange>Auto</chartAxisRange>
                <chartSummary><axisBinding>y</axisBinding><column>a!Unit__c.Occupied_Flag__c</column></chartSummary>
                <componentType>HorizontalBar</componentType>
                <decimalPrecision>0</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <drillEnabled>true</drillEnabled>
                <drillToDetailEnabled>true</drillToDetailEnabled>
                <enableHover>true</enableHover>
                <expandOthers>false</expandOthers>
                <groupingColumn>Unit__c.Property_Asset__c</groupingColumn>
                <groupingSortProperties/>
                <legendPosition>Bottom</legendPosition>
                <report>Property_Management/Occupancy_by_Property</report>
                <showPercentage>false</showPercentage>
                <showValues>true</showValues>
                <sortBy>RowValueDescending</sortBy>
                <title>Occupancy by Property</title>
                <useReportChart>false</useReportChart>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>4</colSpan><columnIndex>8</columnIndex><rowIndex>4</rowIndex><rowSpan>8</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartAxisRange>Auto</chartAxisRange>
                <chartSummary><axisBinding>y</axisBinding><column>s!Delinquency__c.Balance__c</column></chartSummary>
                <componentType>Bar</componentType>
                <decimalPrecision>0</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <drillEnabled>true</drillEnabled>
                <drillToDetailEnabled>true</drillToDetailEnabled>
                <enableHover>true</enableHover>
                <expandOthers>false</expandOthers>
                <groupingColumn>Delinquency__c.Aging_Bucket__c</groupingColumn>
                <groupingSortProperties/>
                <legendPosition>Bottom</legendPosition>
                <report>Property_Management/Delinquency_Aging</report>
                <showPercentage>false</showPercentage>
                <showValues>true</showValues>
                <sortBy>RowLabelAscending</sortBy>
                <title>Delinquency Aging ($ balance)</title>
                <useReportChart>false</useReportChart>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan><columnIndex>0</columnIndex><rowIndex>12</rowIndex><rowSpan>6</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <componentType>Table</componentType>
                <drillEnabled>false</drillEnabled>
                <drillToDetailEnabled>true</drillToDetailEnabled>
                <groupingSortProperties/>
                <indicatorHighColor>#1B7A4B</indicatorHighColor>
                <indicatorLowColor>#1B7A4B</indicatorLowColor>
                <indicatorMiddleColor>#1B7A4B</indicatorMiddleColor>
                <maxValuesDisplayed>20</maxValuesDisplayed>
                <report>Property_Management/CAM_Reconciliation_Status</report>
                <showPicturesOnTables>true</showPicturesOnTables>
                <sortBy>RowLabelAscending</sortBy>
                <title>CAM Reconciliation</title>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan><columnIndex>6</columnIndex><rowIndex>12</rowIndex><rowSpan>6</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <componentType>Table</componentType>
                <drillEnabled>false</drillEnabled>
                <drillToDetailEnabled>true</drillToDetailEnabled>
                <groupingSortProperties/>
                <indicatorHighColor>#C23934</indicatorHighColor>
                <indicatorLowColor>#C23934</indicatorLowColor>
                <indicatorMiddleColor>#C23934</indicatorMiddleColor>
                <maxValuesDisplayed>20</maxValuesDisplayed>
                <report>Property_Management/Insurance_Expiring</report>
                <showPicturesOnTables>true</showPicturesOnTables>
                <sortBy>RowLabelAscending</sortBy>
                <title>Insurance Expiry Alerts</title>
            </dashboardComponent>
        </dashboardGridComponents>
        <numberOfColumns>12</numberOfColumns>
        <rowHeight>36</rowHeight>
    </dashboardGridLayout>
    <dashboardType>SpecifiedUser</dashboardType>
    <isGridLayout>true</isGridLayout>
    <owner>test-3iuncy5c1je5@example.com</owner>
    <runningUser>test-3iuncy5c1je5@example.com</runningUser>
    <textColor>#000000</textColor>
    <title>Property Management Dashboard</title>
    <titleColor>#000000</titleColor>
    <titleSize>12</titleSize>
</Dashboard>
```

- [ ] **Step 3: Deploy**

Run: `sf project deploy start -d force-app/main/default/dashboards/Property_Management.dashboardFolder-meta.xml -d force-app/main/default/dashboards/Property_Management -o DPEG-Acq-3 --ignore-conflicts`
Expected: `Status: Succeeded` (1 folder + 1 dashboard). If a component errors on a summary column ref (`a!`/`s!`), the message names it — confirm the report actually summarizes that field (Task 3) and fix the column token.

- [ ] **Step 4: Commit**

```bash
git add force-app/main/default/dashboards/Property_Management.dashboardFolder-meta.xml force-app/main/default/dashboards/Property_Management
git commit -m "PM dashboard: native 6-metric + 5-component Property Management dashboard"
```

---

### Task 5: Seed script + end-to-end verification

**Files:**
- Create: `scripts/seed-pm-dashboard.apex`

**Interfaces:**
- Consumes: objects/fields from Task 1; reports/dashboard from Tasks 3–4.
- Produces: the seeded data that makes every dashboard component populate.

- [ ] **Step 1: Write the seed script**

`scripts/seed-pm-dashboard.apex`:
```apex
// Seeds PM dashboard dummy data (Yardi ETL later). Idempotent by Yardi_*_Id__c prefix + property name.
String P = 'PMSEED';
String pat = P + '-%';

// --- 4 properties + units (count-based occupancy) ---
Map<String,Integer> propUnits = new Map<String,Integer>{
    'Park North Retail'=>24, 'Riverside Commons'=>26, 'Oak Street Center'=>22, 'Sunset Mixed-Use'=>18 };
Map<String,Integer> propVac = new Map<String,Integer>{
    'Park North Retail'=>1, 'Riverside Commons'=>3, 'Oak Street Center'=>2, 'Sunset Mixed-Use'=>4 };
Map<String,Id> propIds = new Map<String,Id>();
for (String nm : propUnits.keySet()) {
    List<Property_Asset__c> ex = [SELECT Id FROM Property_Asset__c WHERE Name = :nm LIMIT 1];
    Property_Asset__c pa = ex.isEmpty() ? new Property_Asset__c(Name = nm) : ex[0];
    if (ex.isEmpty()) insert pa;
    propIds.put(nm, pa.Id);
    delete [SELECT Id FROM Unit__c WHERE Property_Asset__c = :pa.Id AND Yardi_Unit_Id__c LIKE :pat];
}
List<Unit__c> units = new List<Unit__c>();
for (String nm : propUnits.keySet()) {
    Integer total = propUnits.get(nm), vac = propVac.get(nm);
    String pre = nm.left(3).toUpperCase();
    for (Integer i = 1; i <= total; i++) {
        units.add(new Unit__c(
            Property_Asset__c = propIds.get(nm),
            Suite_Number__c = String.valueOf(100 + i),
            Status__c = (i <= vac) ? 'Vacant' : 'Occupied',
            Yardi_Unit_Id__c = P + '-' + pre + '-' + i));
    }
}
insert units;

Id pn = propIds.get('Park North Retail');
Id rc = propIds.get('Riverside Commons');
Id os = propIds.get('Oak Street Center');
Id su = propIds.get('Sunset Mixed-Use');

// --- Delinquency: 5 tenants (1-30 sums 8200 / 31-60 = 5800 / 61-90 = 12400) ---
delete [SELECT Id FROM Delinquency__c WHERE Yardi_AR_Id__c LIKE :pat];
insert new List<Delinquency__c>{
    new Delinquency__c(Property_Asset__c=pn, Tenant_Name__c='Bluebell Bakery', Balance__c=3000, Aging_Bucket__c='1-30 Days', Yardi_AR_Id__c=P+'-AR-1'),
    new Delinquency__c(Property_Asset__c=rc, Tenant_Name__c='FitLife Gym',     Balance__c=2700, Aging_Bucket__c='1-30 Days', Yardi_AR_Id__c=P+'-AR-2'),
    new Delinquency__c(Property_Asset__c=os, Tenant_Name__c='Java Junction',   Balance__c=2500, Aging_Bucket__c='1-30 Days', Yardi_AR_Id__c=P+'-AR-3'),
    new Delinquency__c(Property_Asset__c=pn, Tenant_Name__c='Metro Bank',      Balance__c=5800, Aging_Bucket__c='31-60 Days', Yardi_AR_Id__c=P+'-AR-4'),
    new Delinquency__c(Property_Asset__c=rc, Tenant_Name__c='Cyprus Retail',   Balance__c=12400, Aging_Bucket__c='61-90 Days', Yardi_AR_Id__c=P+'-AR-5')
};

// --- CAM: 4 rows, 3 not-Approved ---
delete [SELECT Id FROM CAM_Reconciliation__c WHERE Yardi_CAM_Id__c LIKE :pat];
insert new List<CAM_Reconciliation__c>{
    new CAM_Reconciliation__c(Property_Asset__c=pn, Reconciliation_Year__c='2024', Status__c='Approved',  Yardi_CAM_Id__c=P+'-CAM-1'),
    new CAM_Reconciliation__c(Property_Asset__c=rc, Reconciliation_Year__c='2024', Status__c='In Review', Yardi_CAM_Id__c=P+'-CAM-2'),
    new CAM_Reconciliation__c(Property_Asset__c=os, Reconciliation_Year__c='2024', Status__c='Pending',   Yardi_CAM_Id__c=P+'-CAM-3'),
    new CAM_Reconciliation__c(Property_Asset__c=su, Reconciliation_Year__c='2024', Status__c='Pending',   Yardi_CAM_Id__c=P+'-CAM-4')
};

// --- Insurance: 4 policies, 2 expiring ≤60d ---
delete [SELECT Id FROM Insurance_Policy__c WHERE Yardi_Policy_Id__c LIKE :pat];
insert new List<Insurance_Policy__c>{
    new Insurance_Policy__c(Policy_Name__c='Maple Portfolio',   Carrier__c='Northwind Mutual', Expiry_Date__c=Date.today().addDays(18),  Yardi_Policy_Id__c=P+'-POL-1'),
    new Insurance_Policy__c(Policy_Name__c='NW Industrial',     Carrier__c='Sentinel P&C',     Expiry_Date__c=Date.today().addDays(44),  Yardi_Policy_Id__c=P+'-POL-2'),
    new Insurance_Policy__c(Policy_Name__c='Park North Retail', Property_Asset__c=pn, Carrier__c='Sentinel P&C', Expiry_Date__c=Date.today().addDays(120), Yardi_Policy_Id__c=P+'-POL-3'),
    new Insurance_Policy__c(Policy_Name__c='Riverside Commons', Property_Asset__c=rc, Carrier__c='Northwind Mutual', Expiry_Date__c=Date.today().addDays(200), Yardi_Policy_Id__c=P+'-POL-4')
};

System.debug('PM seed: '
  + [SELECT COUNT() FROM Delinquency__c WHERE Yardi_AR_Id__c LIKE :pat] + ' delinquency, '
  + [SELECT COUNT() FROM CAM_Reconciliation__c WHERE Yardi_CAM_Id__c LIKE :pat] + ' CAM, '
  + [SELECT COUNT() FROM Insurance_Policy__c WHERE Yardi_Policy_Id__c LIKE :pat] + ' insurance, '
  + units.size() + ' units across ' + propIds.size() + ' properties.');
```

- [ ] **Step 2: Run it**

Run: `sf apex run -f scripts/seed-pm-dashboard.apex -o DPEG-Acq-3`
Expected: `Compiled successfully. Executed successfully.` with debug `PM seed: 5 delinquency, 4 CAM, 4 insurance, 90 units across 4 properties.`

- [ ] **Step 3: Verify aggregates match the mockup**

Run: `sf data query -o DPEG-Acq-3 -q "SELECT Aging_Bucket__c, COUNT(Id) n, SUM(Balance__c) bal FROM Delinquency__c WHERE Yardi_AR_Id__c LIKE 'PMSEED-%' GROUP BY Aging_Bucket__c"`
Expected: 1-30 Days n=3 bal=8200; 31-60 Days n=1 bal=5800; 61-90 Days n=1 bal=12400 (KPI grand-total count = 5).

Run: `sf data query -o DPEG-Acq-3 -q "SELECT COUNT(Id) FROM CAM_Reconciliation__c WHERE Yardi_CAM_Id__c LIKE 'PMSEED-%' AND Status__c != 'Approved'"`
Expected: 3.

Run: `sf data query -o DPEG-Acq-3 -q "SELECT COUNT(Id) FROM Insurance_Policy__c WHERE Yardi_Policy_Id__c LIKE 'PMSEED-%' AND Days_To_Expiry__c <= 60"`
Expected: 2.

Run: `sf data query -o DPEG-Acq-3 -q "SELECT Property_Asset__r.Name p, AVG(Occupied_Flag__c) occ FROM Unit__c WHERE Yardi_Unit_Id__c LIKE 'PMSEED-%' GROUP BY Property_Asset__r.Name"`
Expected: Park North ≈96, Riverside ≈88, Oak Street ≈91, Sunset ≈78.

- [ ] **Step 4: Visual check (user does final sign-off)**

Run: `sf org open -o DPEG-Acq-3 -p "/lightning/o/Dashboard/home"` → open the **Property Management** folder → **Property Management Dashboard**. Confirm: 6 metrics populate (Properties, Portfolio Occupancy % ≈88, Renewals Due 90d, Delinquent Tenants = 5, CAM Recon Pending = 3, Insurance Expiring = 2); Lease Renewal Pipeline bars by bucket; Occupancy by Property horizontal bars (96/88/91/78); Delinquency Aging bars ($8,200/$5,800/$12,400); CAM Reconciliation table (4 rows); Insurance Expiry Alerts table (2 rows). Compare against the mockup. **The dashboard is reachable from the Property Management app's Dashboards tab (Property Management folder) — no app-metadata change needed; optionally pin it via App Builder.**

- [ ] **Step 5: Commit**

```bash
git add scripts/seed-pm-dashboard.apex
git commit -m "Seed script: PM dashboard dummy data (4 properties, delinquency/CAM/insurance)"
```

---

## Plan deviations from spec (intentional)

- All 8 reports are new (the existing tabular `Renewals_Expiring_Soonest` can't source a native Metric component; a Summary `Renewals_Due_90d` is used instead). Reuse applies to the later Leasing/Maintenance dashboards.
- `Unit__c.Occupied_Flag__c` uses `IF(occupied,100,0)` + report AVERAGE (no custom summary formula) so the metric reads as a percentage number.
- CAM status table renders status as plain text (native dashboard-table conditional formatting is numeric-only; the mockup's colored status pills aren't natively reproducible).
- The dashboard's colored header / "Phase 2" badge / caption are mockup HTML chrome, not native dashboard features — omitted.
