# Maintenance Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native "Maintenance Dashboard" — 6 KPI metrics + a work-order aging bar, an active-work-order FlexTable, an SLA-tiers table, and a vendor-performance table — each backed by its own report, using `Work_Order__c` plus one new formula field and seeded demo data.

**Architecture:** One `Resolution_Days__c` formula field on `Work_Order__c` enables vendor performance. 9 new native reports (+ reuse of `Open_Work_Orders_by_Priority`) land in the existing `Work Orders` report folder and feed a native dashboard in the existing `Work Orders` dashboard folder. No new objects.

**Tech Stack:** Salesforce metadata API 62.0 — CustomField, Report, Dashboard, PermissionSet, anonymous Apex seed.

## Global Constraints

- Branch: `feature/pm-role-dashboards` (already checked out). Commit after every task.
- API **62.0**. Default org **DPEG-Acq-3**. Run `sf` from repo root `f:\Acquisition-Design-Salesforce` (use the PowerShell tool for `sf` if Git Bash throws `'C:\Program' is not recognized`). Deploys use `--ignore-conflicts`.
- **Deploy order:** field → perm set → reports → dashboard → seed.
- **Native metadata gotchas (proven on PM + Leasing — follow exactly):**
  - Dashboard **Metric** needs a **Summary** report; **FlexTable** needs a **Tabular** report with `showDetails=true`; a **Table** component works for grouping + one aggregate; **Chart** needs a Summary grouping.
  - Dashboard summary column = a separate `<aggregate>Average|Sum|Maximum</aggregate>` element (order aggregate → axisBinding → column) + bare `<column>Obj.Field__c</column>` — NOT `a!`/`s!` inline.
  - `componentType`: `Bar` = horizontal, `Column` = vertical. `FlexTable` (`flexTableColumn type=detail` + optional `flexTableSortInfo` sortOrder 1 asc / 2 desc + `header`) for multi-column detail tables; legacy `Table` for grouping+aggregate.
  - A report **can't list its grouping field in `<columns>`**. Custom-object report type = `CustomEntity$Work_Order__c`.
  - New fields get NO FLS on deploy → "No such column" until the perm set grants it (even the scratch admin). Verify field existence via Tooling API (`sf sobject describe` caches stale). Verify report data via `sf apex run` + `Reports.ReportManager.runReport(id,true)` (`sf org api request rest` is NOT in this CLI).
- Reports go in the existing `Work Orders` folder; dashboard in the existing `Work Orders` dashboard folder (`<name>Work Orders</name>`). Both folder metas are included (idempotent) so the deploy is self-contained.
- Dashboard running user `test-3iuncy5c1je5@example.com`, dashboardType SpecifiedUser (repoint on promotion).
- Real `Work_Order__c` values: Priority `Critical`/`High`/`Medium`/`Low`; Status `New`/`In Progress`/`On Hold`/`Completed`/`Closed`; Category HVAC/Plumbing/etc. `Is_Open__c`, `Is_Escalation__c`, `Hours_Open__c`, `SLA_Target_Hours__c` are formulas. Required fields for insert: `Subject__c`, `Reported_Date__c` (datetime).
- Cross-branch artifacts (field on Work_Order__c, reports referencing it) are expected — the org is the superset.

---

### Task 1: `Resolution_Days__c` field on `Work_Order__c`

**Files (Create):**
- `force-app/main/default/objects/Work_Order__c/fields/Resolution_Days__c.field-meta.xml`

**Interfaces:**
- Consumes: existing `Work_Order__c` (in org).
- Produces: `Work_Order__c.Resolution_Days__c` (Number formula). Used by Tasks 2, 3 (Vendor_Performance report).

- [ ] **Step 1: Write the field**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Resolution_Days__c</fullName>
    <label>Resolution Days</label>
    <formula>Completed_Date__c - Reported_Date__c</formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>1</scale>
    <trackTrending>false</trackTrending>
    <type>Number</type>
</CustomField>
```
(datetime − datetime = number of days. Only the field file under `Work_Order__c/fields/` — do NOT add a `Work_Order__c.object-meta.xml`; the object lives in the org.)

- [ ] **Step 2: Deploy**

Run: `sf project deploy start -d force-app/main/default/objects/Work_Order__c/fields/Resolution_Days__c.field-meta.xml -o DPEG-Acq-3 --ignore-conflicts`
Expected: `Status: Succeeded`, 1 CustomField.

- [ ] **Step 3: Verify (Tooling API)**

Run: `sf data query --use-tooling-api -o DPEG-Acq-3 -q "SELECT DeveloperName FROM CustomField WHERE EntityDefinition.QualifiedApiName='Work_Order__c' AND DeveloperName='Resolution_Days'"`
Expected: one row. (SOQL `data query` on the field says "No such column" until Task 2 grants FLS — expected.)

- [ ] **Step 4: Commit**
```bash
git add force-app/main/default/objects/Work_Order__c
git commit -m "Work_Order: Resolution_Days formula (Completed - Reported) for vendor performance"
```

---

### Task 2: Perm set FLS for `Resolution_Days__c`

**Files:**
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Consumes: field from Task 1.
- Produces: FLS so the Vendor_Performance report/queries see the field.

**Shared-file procedure (proven on PM + Leasing):** commit a MINIMAL branch diff (1 line), DEPLOY the org-superset so sibling grants aren't wiped.

- [ ] **Step 1: Add the fieldPermission to the minimal branch file**

Insert among the existing `<fieldPermissions>` group (before the LAST `</fieldPermissions>` so the group stays contiguous):
```xml
    <fieldPermissions><editable>false</editable><field>Work_Order__c.Resolution_Days__c</field><readable>true</readable></fieldPermissions>
```

- [ ] **Step 2: Build the superset and deploy**
```bash
sf project retrieve start -m "PermissionSet:Property_Management_Access" -o DPEG-Acq-3 --target-metadata-dir /tmp/mwops --unzip
```
Splice the same line into the retrieved org-live file (before its LAST `</fieldPermissions>`), copy over the working file, then:
```bash
sf project deploy start -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -o DPEG-Acq-3 --ignore-conflicts
```
Expected: `Status: Succeeded`.

- [ ] **Step 3: Restore minimal file, verify FLS, commit**

Overwrite the working file with the minimal version (main base + prior branch additions + this 1 line). Verify: `sf data query -o DPEG-Acq-3 -q "SELECT Resolution_Days__c FROM Work_Order__c LIMIT 1"` → 0/1 rows (not "No such column").
```bash
git add force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "Property_Management_Access: read FLS for Work_Order Resolution_Days"
```
Confirm the committed diff shows ONLY the 1 added line vs the branch's prior HEAD.

---

### Task 3: 9 new reports (existing `Work Orders` folder)

**Files (Create):**
- `force-app/main/default/reports/Work_Orders.reportFolder-meta.xml` (idempotent — `<name>Work Orders</name>`)
- `force-app/main/default/reports/Work_Orders/{Critical_High_Open, Escalated_Overdue, In_Progress_WOs, Resolved_MTD, On_Hold_WOs, WO_Aging_Buckets, Active_WO_Priority, SLA_Tiers_by_Priority, Vendor_Performance}.report-meta.xml`

**Interfaces:**
- Consumes: field from Task 1; existing `Work_Order__c`.
- Produces: 9 reports at `Work_Orders/<ApiName>`. (The Open metric reuses pre-existing `Work_Orders/Open_Work_Orders_by_Priority` — do NOT recreate it.)

After deploy, open each report (empty pre-seed is fine). Directory is `Work_Orders/` (underscore); folder display name has a space.

- [ ] **Step 1: Folder meta** — `reports/Work_Orders.reportFolder-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ReportFolder xmlns="http://soap.sforce.com/2006/04/metadata">
    <name>Work Orders</name>
</ReportFolder>
```

- [ ] **Step 2: `Critical_High_Open.report-meta.xml`** (KPI Emergency/High)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Work_Order__c.Subject__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Is_Open__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>1</value>
        </criteriaItems>
        <criteriaItems>
            <column>Work_Order__c.Priority__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Critical,High</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Work_Order__c.Priority__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Critical / High Open</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
(A picklist filter with comma-separated `<value>Critical,High</value>` matches either — the report "equals" operator treats it as IN for picklists.)

- [ ] **Step 3: `Escalated_Overdue.report-meta.xml`** (KPI Overdue >15d)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Work_Order__c.Subject__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Is_Escalation__c</column>
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
    <name>Escalated Overdue</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 4: `In_Progress_WOs.report-meta.xml`** (KPI Vendor Dispatched)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Work_Order__c.Subject__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>In Progress</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Work_Order__c.Status__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>In Progress Work Orders</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 5: `Resolved_MTD.report-meta.xml`** (KPI Resolved MTD)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Work_Order__c.Subject__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Completed,Closed</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Work_Order__c.Status__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Resolved MTD</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
    <timeFrameFilter>
        <dateColumn>Work_Order__c.Completed_Date__c</dateColumn>
        <interval>INTERVAL_THISMONTH</interval>
    </timeFrameFilter>
</Report>
```

- [ ] **Step 6: `On_Hold_WOs.report-meta.xml`** (KPI On Hold)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Work_Order__c.Subject__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>On Hold</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Work_Order__c.Status__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>On Hold Work Orders</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 7: `WO_Aging_Buckets.report-meta.xml`** (Work Order Aging bar)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <buckets>
        <bucketType>number</bucketType>
        <developerName>BucketField_Aging</developerName>
        <masterLabel>Aging Bucket</masterLabel>
        <nullTreatment>n</nullTreatment>
        <sourceColumnName>Work_Order__c.Hours_Open__c</sourceColumnName>
        <useOther>false</useOther>
        <values><sourceValues><to>72</to></sourceValues><value>0-3 days</value></values>
        <values><sourceValues><from>72</from><to>168</to></sourceValues><value>4-7 days</value></values>
        <values><sourceValues><from>168</from><to>336</to></sourceValues><value>8-14 days</value></values>
        <values><sourceValues><from>336</from></sourceValues><value>&gt;15 days</value></values>
    </buckets>
    <columns><field>Work_Order__c.Subject__c</field></columns>
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
        <field>BucketField_Aging</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Work Order Aging</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
(Number-bucket boundaries `to` inclusive / `from` exclusive; grouping ref is the bare `BucketField_Aging`. Verify band membership on deploy.)

- [ ] **Step 8: `Active_WO_Priority.report-meta.xml`** (Active Work Orders FlexTable — Tabular)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Work_Order__c.Property_Display_Name__c</field></columns>
    <columns><field>Work_Order__c.Subject__c</field></columns>
    <columns><field>Work_Order__c.Priority__c</field></columns>
    <columns><field>Work_Order__c.Vendor__c</field></columns>
    <columns><field>Work_Order__c.Hours_Open__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Is_Open__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>1</value>
        </criteriaItems>
    </filter>
    <format>Tabular</format>
    <name>Active Work Orders — Priority</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <sortColumn>Work_Order__c.Hours_Open__c</sortColumn>
    <sortOrder>Desc</sortOrder>
</Report>
```

- [ ] **Step 9: `SLA_Tiers_by_Priority.report-meta.xml`** (SLA Tiers Table)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns>
        <aggregateTypes>Maximum</aggregateTypes>
        <field>Work_Order__c.SLA_Target_Hours__c</field>
    </columns>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Work_Order__c.Priority__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>SLA Tiers by Priority</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 10: `Vendor_Performance.report-meta.xml`** (Vendor Performance Table)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns>
        <aggregateTypes>Average</aggregateTypes>
        <field>Work_Order__c.Resolution_Days__c</field>
    </columns>
    <filter>
        <criteriaItems>
            <column>Work_Order__c.Resolution_Days__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>greaterOrEqual</operator>
            <value>0.1</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Work_Order__c.Vendor__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Vendor Performance</name>
    <reportType>CustomEntity$Work_Order__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```
(The `>= 0.1` filter excludes not-yet-completed rows whose `Resolution_Days__c` is null, so the report Average isn't diluted by zeros — same fix pattern as Leasing's Avg_Days_To_Lease.)

- [ ] **Step 11: Deploy**

Run: `sf project deploy start -d force-app/main/default/reports/Work_Orders.reportFolder-meta.xml -d force-app/main/default/reports/Work_Orders -o DPEG-Acq-3 --ignore-conflicts`
Expected: `Status: Succeeded`. If a report fails on a field name/enum, confirm via Tooling API and correct (e.g., `Property_Display_Name__c` exists on Work_Order__c).

- [ ] **Step 12: Verify each report opens**

Run: `sf org open -o DPEG-Acq-3 -p "/lightning/o/Report/home"` → open the Work Orders folder → confirm the 9 new reports open without error.

- [ ] **Step 13: Commit**
```bash
git add force-app/main/default/reports/Work_Orders.reportFolder-meta.xml force-app/main/default/reports/Work_Orders
git commit -m "Maintenance dashboard reports: 9 native reports (priority, escalation, aging, SLA, vendor)"
```

---

### Task 4: Maintenance dashboard (existing `Work Orders` dashboard folder)

**Files (Create):**
- `force-app/main/default/dashboards/Work_Orders.dashboardFolder-meta.xml` (idempotent — `<name>Work Orders</name>`)
- `force-app/main/default/dashboards/Work_Orders/Maintenance_Dashboard.dashboard-meta.xml`

**Interfaces:**
- Consumes: the 9 reports from Task 3 + the reused `Work_Orders/Open_Work_Orders_by_Priority`.
- Produces: the dashboard (data appears after Task 5 seeds).

**Design refinement from the PM build:** SLA Tiers and Vendor Performance are rendered as **Bar charts** (not legacy Tables). A legacy Table component shows grouping + *record count*, NOT the summarized value (this is exactly why PM's CAM/Insurance tables had to become FlexTables). A Bar chart on a Summary report reliably shows the aggregate (MAX SLA hours by Priority; AVG resolution days by Vendor). This supersedes the spec's "Table" wording for these two.

- [ ] **Step 1: Folder meta** — `dashboards/Work_Orders.dashboardFolder-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<DashboardFolder xmlns="http://soap.sforce.com/2006/04/metadata">
    <name>Work Orders</name>
</DashboardFolder>
```

- [ ] **Step 2: Dashboard file** — `dashboards/Work_Orders/Maintenance_Dashboard.dashboard-meta.xml`:
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
                <metricLabel>Open Work Orders</metricLabel>
                <report>Work_Orders/Open_Work_Orders_by_Priority</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>2</colSpan><columnIndex>2</columnIndex><rowIndex>0</rowIndex><rowSpan>4</rowSpan>
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
                <metricLabel>Critical / High</metricLabel>
                <report>Work_Orders/Critical_High_Open</report>
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
                <indicatorHighColor>#C23934</indicatorHighColor>
                <indicatorLowColor>#C23934</indicatorLowColor>
                <indicatorMiddleColor>#C23934</indicatorMiddleColor>
                <metricLabel>Overdue &gt;15d</metricLabel>
                <report>Work_Orders/Escalated_Overdue</report>
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
                <indicatorHighColor>#1B7A4B</indicatorHighColor>
                <indicatorLowColor>#1B7A4B</indicatorLowColor>
                <indicatorMiddleColor>#1B7A4B</indicatorMiddleColor>
                <metricLabel>Vendor Dispatched</metricLabel>
                <report>Work_Orders/In_Progress_WOs</report>
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
                <indicatorHighColor>#1B7A4B</indicatorHighColor>
                <indicatorLowColor>#1B7A4B</indicatorLowColor>
                <indicatorMiddleColor>#1B7A4B</indicatorMiddleColor>
                <metricLabel>Resolved MTD</metricLabel>
                <report>Work_Orders/Resolved_MTD</report>
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
                <indicatorHighColor>#8A5A00</indicatorHighColor>
                <indicatorLowColor>#8A5A00</indicatorLowColor>
                <indicatorMiddleColor>#8A5A00</indicatorMiddleColor>
                <metricLabel>On Hold</metricLabel>
                <report>Work_Orders/On_Hold_WOs</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan><columnIndex>0</columnIndex><rowIndex>4</rowIndex><rowSpan>8</rowSpan>
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
                <groupingColumn>BucketField_Aging</groupingColumn>
                <groupingSortProperties/>
                <legendPosition>Bottom</legendPosition>
                <report>Work_Orders/WO_Aging_Buckets</report>
                <showPercentage>false</showPercentage>
                <showValues>true</showValues>
                <sortBy>RowLabelAscending</sortBy>
                <title>Work Order Aging</title>
                <useReportChart>false</useReportChart>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan><columnIndex>6</columnIndex><rowIndex>4</rowIndex><rowSpan>8</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <componentType>FlexTable</componentType>
                <flexComponentProperties>
                    <decimalPrecision>-1</decimalPrecision>
                    <flexTableColumn><reportColumn>Work_Order__c.Property_Display_Name__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Work_Order__c.Subject__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Work_Order__c.Priority__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Work_Order__c.Vendor__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Work_Order__c.Hours_Open__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableSortInfo><sortColumn>Work_Order__c.Hours_Open__c</sortColumn><sortOrder>2</sortOrder></flexTableSortInfo>
                    <hideChatterPhotos>true</hideChatterPhotos>
                </flexComponentProperties>
                <groupingSortProperties/>
                <header>Active Work Orders — Priority View</header>
                <report>Work_Orders/Active_WO_Priority</report>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan><columnIndex>0</columnIndex><rowIndex>12</rowIndex><rowSpan>6</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartAxisRange>Auto</chartAxisRange>
                <chartSummary><aggregate>Maximum</aggregate><axisBinding>y</axisBinding><column>Work_Order__c.SLA_Target_Hours__c</column></chartSummary>
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
                <report>Work_Orders/SLA_Tiers_by_Priority</report>
                <showPercentage>false</showPercentage>
                <showValues>true</showValues>
                <sortBy>RowValueDescending</sortBy>
                <title>SLA Target Hours by Priority</title>
                <useReportChart>false</useReportChart>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan><columnIndex>6</columnIndex><rowIndex>12</rowIndex><rowSpan>6</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartAxisRange>Auto</chartAxisRange>
                <chartSummary><aggregate>Average</aggregate><axisBinding>y</axisBinding><column>Work_Order__c.Resolution_Days__c</column></chartSummary>
                <componentType>Bar</componentType>
                <decimalPrecision>1</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <drillEnabled>true</drillEnabled>
                <drillToDetailEnabled>true</drillToDetailEnabled>
                <enableHover>true</enableHover>
                <expandOthers>false</expandOthers>
                <groupingColumn>Work_Order__c.Vendor__c</groupingColumn>
                <groupingSortProperties/>
                <legendPosition>Bottom</legendPosition>
                <report>Work_Orders/Vendor_Performance</report>
                <showPercentage>false</showPercentage>
                <showValues>true</showValues>
                <sortBy>RowValueAscending</sortBy>
                <title>Vendor Performance — Avg Resolution Days</title>
                <useReportChart>false</useReportChart>
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
    <title>Maintenance Dashboard</title>
    <titleColor>#000000</titleColor>
    <titleSize>12</titleSize>
</Dashboard>
```

- [ ] **Step 3: Deploy**

Run: `sf project deploy start -d force-app/main/default/dashboards/Work_Orders.dashboardFolder-meta.xml -d force-app/main/default/dashboards/Work_Orders -o DPEG-Acq-3 --ignore-conflicts`
Expected: `Status: Succeeded`. If `BucketField_Aging` grouping or an `<aggregate>` column is rejected, the error names it — confirm it matches the Task 3 report's grouping/summary and fix.

- [ ] **Step 4: Commit**
```bash
git add force-app/main/default/dashboards/Work_Orders.dashboardFolder-meta.xml force-app/main/default/dashboards/Work_Orders
git commit -m "Maintenance dashboard: native 6-metric + aging bar + active FlexTable + SLA/vendor bars"
```

---

### Task 5: Seed script + end-to-end verification

**Files (Create):**
- `scripts/seed-maintenance-dashboard.apex`

**Interfaces:**
- Consumes: Task 1 field; existing `Work_Order__c`.
- Produces: demo data so every component populates.

- [ ] **Step 1: Write the seed script**

`scripts/seed-maintenance-dashboard.apex`:
```apex
// Seeds Maintenance dashboard demo data. Idempotent: work orders marked Subject__c starting 'WOSEED-'.
// Required fields: Subject__c, Reported_Date__c. Vendor__c is text; Property_Asset__c optional (Property_Display_Name is a formula).
delete [SELECT Id FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%'];

Datetime now = Datetime.now();
String[] vendors = new String[]{'AirPro HVAC','TopShield Roofing','ProPlumb','Elec Solutions'};
String[] cats = new String[]{'HVAC','Plumbing','Electrical','Refrigeration','General'};
List<Work_Order__c> wos = new List<Work_Order__c>();

// ---- OPEN work orders (~37): staggered ages drive aging buckets + escalation ----
// 6 escalated (>15d old, Critical/High) — reported 16-26 days ago
for (Integer i = 0; i < 6; i++) {
    wos.add(new Work_Order__c(Subject__c='WOSEED- Escalated ' + i,
        Reported_Date__c=now.addDays(-(16 + i*2)), Priority__c=(Math.mod(i,2)==0?'Critical':'High'),
        Status__c=(Math.mod(i,2)==0?'In Progress':'New'), Category__c=cats[Math.mod(i,cats.size())],
        Vendor__c=vendors[Math.mod(i,vendors.size())]));
}
// 20 In Progress (Vendor Dispatched), varied recent ages for aging spread
for (Integer i = 0; i < 20; i++) {
    Integer ageDays = new Integer[]{1,2,3,5,6,9,11,13}[Math.mod(i,8)];
    wos.add(new Work_Order__c(Subject__c='WOSEED- InProg ' + i,
        Reported_Date__c=now.addDays(-ageDays), Priority__c=new String[]{'Medium','High','Low','Medium'}[Math.mod(i,4)],
        Status__c='In Progress', Category__c=cats[Math.mod(i,cats.size())], Vendor__c=vendors[Math.mod(i,vendors.size())]));
}
// 8 On Hold
for (Integer i = 0; i < 8; i++) {
    wos.add(new Work_Order__c(Subject__c='WOSEED- OnHold ' + i,
        Reported_Date__c=now.addDays(-(4 + i)), Priority__c=new String[]{'Low','Medium'}[Math.mod(i,2)],
        Status__c='On Hold', Category__c=cats[Math.mod(i,cats.size())], Vendor__c=vendors[Math.mod(i,vendors.size())]));
}
// 3 New (to round open toward ~37)
for (Integer i = 0; i < 3; i++) {
    wos.add(new Work_Order__c(Subject__c='WOSEED- New ' + i,
        Reported_Date__c=now.addDays(-i), Priority__c='Medium', Status__c='New',
        Category__c=cats[Math.mod(i,cats.size())], Vendor__c=vendors[Math.mod(i,vendors.size())]));
}

// ---- RESOLVED this month (~40): Completed_Date this month, Reported a few days earlier -> Resolution_Days ----
// Per-vendor average resolution days differ: AirPro 3.2, TopShield 5.8, ProPlumb 8.1, Elec 12.0 (approx)
Decimal[] vAvg = new Decimal[]{3, 6, 8, 12};
Date monthStart = Date.today().toStartOfMonth();
for (Integer i = 0; i < 40; i++) {
    Integer v = Math.mod(i, 4);
    Integer resDays = (Integer)vAvg[v] + Math.mod(i, 3) - 1;   // small spread around the vendor average
    if (resDays < 1) resDays = 1;
    // completed on a day within this month (day 1..min(today, 28))
    Integer maxDay = Math.min(Date.today().day(), 28);
    Datetime completed = Datetime.newInstance(monthStart.addDays(Math.mod(i, maxDay)), Time.newInstance(12,0,0,0));
    wos.add(new Work_Order__c(Subject__c='WOSEED- Resolved ' + i,
        Reported_Date__c=completed.addDays(-resDays), Completed_Date__c=completed,
        Priority__c=new String[]{'Medium','High','Low'}[Math.mod(i,3)],
        Status__c=(Math.mod(i,4)==0?'Closed':'Completed'), Category__c=cats[Math.mod(i,cats.size())],
        Vendor__c=vendors[v]));
}

// Assign a property round-robin so the Active Work Orders table's Property column populates
// (Property_Display_Name__c is a formula off Property_Asset__c). Uses the 4 PM-seed properties if present.
List<Id> propIds = new List<Id>();
for (Property_Asset__c p : [SELECT Id FROM Property_Asset__c
        WHERE Name IN ('Park North Retail','Riverside Commons','Oak Street Center','Sunset Mixed-Use') ORDER BY Name]) {
    propIds.add(p.Id);
}
if (!propIds.isEmpty()) {
    for (Integer i = 0; i < wos.size(); i++) wos[i].Property_Asset__c = propIds[Math.mod(i, propIds.size())];
}
insert wos;

System.debug('Maintenance seed: ' + wos.size() + ' work orders. '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Is_Open__c=true] + ' open, '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Status__c='In Progress'] + ' in progress, '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Status__c='On Hold'] + ' on hold, '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Completed_Date__c = THIS_MONTH] + ' resolved MTD, '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Is_Escalation__c=true] + ' escalated.');
```

- [ ] **Step 2: Run it**

Run: `sf apex run -f scripts/seed-maintenance-dashboard.apex -o DPEG-Acq-3`
Expected: `Executed successfully.` debug `Maintenance seed: 77 work orders. 37 open, 20 in progress, 8 on hold, 40 resolved MTD, ~6 escalated.` (escalated count may vary with the Is_Escalation formula threshold — report the actual.)

- [ ] **Step 3: Verify aggregates**

Run: `sf data query -o DPEG-Acq-3 -q "SELECT Status__c, COUNT(Id) n FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' GROUP BY Status__c"`
Expected: In Progress ≈26 (20+6 escalated in-progress), On Hold 8, Completed/Closed ≈40, New ≈5.
Run: `sf data query -o DPEG-Acq-3 -q "SELECT COUNT(Id) FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Is_Open__c=true"` → ≈37.
Run: `sf data query -o DPEG-Acq-3 -q "SELECT Vendor__c, AVG(Resolution_Days__c) a FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Resolution_Days__c != null GROUP BY Vendor__c"` → 4 vendors with differing averages.

- [ ] **Step 4: Verify report bindings (Apex Reports API)**

Write `scripts/tmp-verify-wo.apex` running these reports by DeveloperName and printing grand totals: `In_Progress_WOs` (expect ≈26), `On_Hold_WOs` (expect 8), `Resolved_MTD` (expect ≈40), `Escalated_Overdue` (actual escalated), `Vendor_Performance` (grand-total avg days), `SLA_Tiers_by_Priority` (renders per-priority). Example per report:
```apex
Id rid = [SELECT Id FROM Report WHERE DeveloperName='In_Progress_WOs'].Id;
Reports.ReportResults r = Reports.ReportManager.runReport(rid, true);
System.debug('In_Progress_WOs grandTotal=' + r.getFactMap().get('T!T').getAggregates()[0].getValue());
```
Run `sf apex run -f scripts/tmp-verify-wo.apex -o DPEG-Acq-3`. Delete the temp file after (do not commit).

- [ ] **Step 5: Visual check (user sign-off)**

Run: `sf org open -o DPEG-Acq-3 -p "/lightning/o/Dashboard/home"` → Work Orders folder → **Maintenance Dashboard** → Refresh. Confirm 6 metrics (Open ≈37, Critical/High, Overdue >15d, Vendor Dispatched ≈26, Resolved MTD ≈40, On Hold 8), the Work Order Aging bar (buckets), the Active Work Orders FlexTable (Property/Issue/Priority/Vendor/Days Open), SLA Target Hours by Priority bar, and Vendor Performance bar (avg days). Compare to the mockup.

- [ ] **Step 6: Commit**
```bash
git add scripts/seed-maintenance-dashboard.apex
git commit -m "Seed script: Maintenance dashboard demo data (open/in-progress/on-hold/resolved work orders)"
```

---

## Plan deviations from spec (intentional)

- SLA Tiers and Vendor Performance render as **Bar charts**, not legacy Tables: a legacy Table shows grouping + record count, not the summarized value (the PM CAM/Insurance lesson), so a Bar reliably shows MAX SLA hours by Priority and AVG resolution days by Vendor.
- "Emergency / High" filters real Priority values `Critical,High`; "Vendor Dispatched" = Status `In Progress`; "On Hold" replaces the mockup's "Recurring Scheduled" — all per the adjudicated decisions.
- `Resolved_MTD` uses a `timeFrameFilter` INTERVAL_THISMONTH on `Completed_Date__c`.
- `Vendor_Performance` filters `Resolution_Days__c >= 0.1` so not-yet-completed nulls don't dilute the report Average.
