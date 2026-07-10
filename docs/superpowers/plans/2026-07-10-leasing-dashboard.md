# Leasing Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native "Leasing Dashboard" — 6 KPI metrics + a vacancy-pipeline table, monthly velocity chart, and renewal-negotiation table — each backed by its own report, using existing lease objects plus two new `Lease_Inquiry__c` fields and seeded demo data.

**Architecture:** Two formula/date fields on `Lease_Inquiry__c` enable avg-days-to-lease. 8 new native reports (+ reuse of `Active_Pipeline_By_Stage`) land in the existing `Leasing` report folder and feed a native dashboard in the existing `Leasing` dashboard folder. No new objects.

**Tech Stack:** Salesforce metadata API 62.0 — CustomField, Report, Dashboard, PermissionSet, anonymous Apex seed.

## Global Constraints

- Branch: `feature/pm-role-dashboards` (already checked out — continues the role-dashboards work). Commit after every task.
- API **62.0**. Default org **DPEG-Acq-3**. Run `sf` from repo root `f:\Acquisition-Design-Salesforce`. Deploys use `--ignore-conflicts` (shared org).
- **Deploy order:** fields → perm set → reports → dashboard → seed.
- **Native metadata gotchas (proven on the PM dashboard — follow exactly):**
  - Dashboard **Metric** components need a **Summary** report (Tabular leaves the metric blank). **FlexTable** components need a **Tabular** report with `showDetails=true`. **Chart** components need a Summary grouping.
  - Dashboard summary column = a separate `<aggregate>Average|Sum</aggregate>` element (order: aggregate → axisBinding → column) + bare `<column>Obj.Field__c</column>` — NOT `a!`/`s!` inline prefixes.
  - `componentType`: `Bar` = horizontal, `Column` = vertical. Detail tables use `FlexTable` (`flexTableColumn` with `type>detail` per column + optional `flexTableSortInfo` `sortOrder>1` for asc + `header`), NOT legacy `Table` (which shows only grouping+count). `HorizontalBar` is not a valid enum.
  - A report **can't list its grouping field in `<columns>`**. `Unit__c` is master-detail to `Property_Asset__c`, so its report type is the parent-child `CustomEntityCustomEntity$Property_Asset__c$Unit__c` (standalone `CustomEntity$Unit__c` is invalid). Custom-object report type otherwise = `CustomEntity$<ApiName>`.
  - New fields get NO FLS on deploy → "No such column" until the perm set grants it (even to the scratch admin). `sf sobject describe` caches stale; use Tooling API for ground truth. `sf org api request rest` is NOT in this CLI — verify report data via `sf apex run` + `Reports.ReportManager.runReport(id,true)`.
- Reports go in the existing `Leasing` folder; dashboard in the existing `Leasing` dashboard folder (`<name>Leasing</name>`). Both folder metas are included (idempotent) so the deploy is self-contained.
- Dashboard running user `test-3iuncy5c1je5@example.com`, dashboardType SpecifiedUser (repoint on promotion).
- Real `Lease_Inquiry__c.Stage__c` values: `Inquiry Received`, `LOI Received`, `LOI Signed`, `Lease Drafting`, `Lease Signed`. Real `Lease_Renewal__c.Stage__c` values include `Renewed`. Both objects have `Status__c` with value `Active`.
- Cross-branch artifacts (fields on Lease_Inquiry__c/Unit__c, reports referencing them) are expected — the org is the superset.

---

### Task 1: Two fields on `Lease_Inquiry__c`

**Files (Create):**
- `force-app/main/default/objects/Lease_Inquiry__c/fields/Inquiry_Date__c.field-meta.xml`
- `force-app/main/default/objects/Lease_Inquiry__c/fields/Days_To_Sign__c.field-meta.xml`

**Interfaces:**
- Consumes: existing `Lease_Inquiry__c` (in org).
- Produces: `Lease_Inquiry__c.Inquiry_Date__c` (Date) and `Days_To_Sign__c` (Number formula). Used by Tasks 2, 3 (Avg_Days_To_Lease report), 5 (seed).

- [ ] **Step 1: Write `Inquiry_Date__c.field-meta.xml`**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Inquiry_Date__c</fullName>
    <label>Inquiry Date</label>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Date</type>
</CustomField>
```

- [ ] **Step 2: Write `Days_To_Sign__c.field-meta.xml`**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Days_To_Sign__c</fullName>
    <label>Days To Sign</label>
    <formula>Signed_Date__c - Inquiry_Date__c</formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>
    <trackTrending>false</trackTrending>
    <type>Number</type>
</CustomField>
```
(Only field files under `Lease_Inquiry__c/fields/` — do NOT add a `Lease_Inquiry__c.object-meta.xml`; the object lives in the org/on the lease-activity branch.)

- [ ] **Step 3: Deploy**

Run: `sf project deploy start -d force-app/main/default/objects/Lease_Inquiry__c/fields/Inquiry_Date__c.field-meta.xml -d force-app/main/default/objects/Lease_Inquiry__c/fields/Days_To_Sign__c.field-meta.xml -o DPEG-Acq-3 --ignore-conflicts`
Expected: `Status: Succeeded`, 2 CustomField.

- [ ] **Step 4: Verify (Tooling API — not FLS-gated)**

Run: `sf data query --use-tooling-api -o DPEG-Acq-3 -q "SELECT DeveloperName FROM CustomField WHERE EntityDefinition.QualifiedApiName='Lease_Inquiry__c' AND DeveloperName IN ('Inquiry_Date','Days_To_Sign')"`
Expected: both rows returned. (SOQL `data query` on the fields will say "No such column" until Task 2 grants FLS — that is expected, not a failure.)

- [ ] **Step 5: Commit**
```bash
git add force-app/main/default/objects/Lease_Inquiry__c
git commit -m "Lease_Inquiry: Inquiry_Date + Days_To_Sign fields for avg-days-to-lease"
```

---

### Task 2: Perm set FLS for the 2 new fields

**Files:**
- Modify: `force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml`

**Interfaces:**
- Consumes: fields from Task 1.
- Produces: FLS so reports/queries see the fields (else "No such column").

**Shared-file procedure (proven on PM):** commit a MINIMAL branch diff (main base + these 2 lines), but DEPLOY the org-superset so sibling grants aren't wiped.

- [ ] **Step 1: Add the 2 fieldPermissions to the minimal branch file**

Add among the existing `<fieldPermissions>` group (keep the group contiguous — insert before the LAST `</fieldPermissions>`):
```xml
    <fieldPermissions><editable>false</editable><field>Lease_Inquiry__c.Inquiry_Date__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>false</editable><field>Lease_Inquiry__c.Days_To_Sign__c</field><readable>true</readable></fieldPermissions>
```

- [ ] **Step 2: Build the superset and deploy**
```bash
sf project retrieve start -m "PermissionSet:Property_Management_Access" -o DPEG-Acq-3 --target-metadata-dir /tmp/lpms --unzip
```
Splice the same 2 `fieldPermissions` lines into the retrieved org-live file (before its LAST `</fieldPermissions>`), copy it over the working file, then:
```bash
sf project deploy start -d force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml -o DPEG-Acq-3 --ignore-conflicts
```
Expected: `Status: Succeeded`.

- [ ] **Step 3: Restore minimal file, verify FLS, commit**

Overwrite the working file with the minimal version (main base + the 2 new lines). Verify the admin can now see the field:
`sf data query -o DPEG-Acq-3 -q "SELECT Days_To_Sign__c FROM Lease_Inquiry__c LIMIT 1"` → 0/1 rows (not "No such column").
```bash
git add force-app/main/default/permissionsets/Property_Management_Access.permissionset-meta.xml
git commit -m "Property_Management_Access: read FLS for Lease_Inquiry avg-days fields"
```
Confirm the committed diff shows ONLY the 2 added lines vs main.

---

### Task 3: 8 new reports (existing `Leasing` folder)

**Files (Create):**
- `force-app/main/default/reports/Leasing.reportFolder-meta.xml` (idempotent — `<name>Leasing</name>`)
- `force-app/main/default/reports/Leasing/{Vacant_Units, LOIs_Outstanding, Leases_Signed_MTD, Avg_Days_To_Lease, Renewals_Confirmed, Vacancy_Pipeline, Leasing_Velocity_MTD, Renewal_Negotiations}.report-meta.xml`

**Interfaces:**
- Consumes: objects/fields from Task 1; existing `Lease_Inquiry__c`, `Lease_Renewal__c`, `Unit__c`.
- Produces: 8 reports at `Leasing/<ApiName>` for the Task 4 dashboard. (The Prospects metric reuses the pre-existing `Leasing/Active_Pipeline_By_Stage` — do not recreate it.)

After deploy, open each report to confirm it renders (empty is fine pre-seed; buckets/groupings valid).

- [ ] **Step 1: Folder meta** — `reports/Leasing.reportFolder-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<ReportFolder xmlns="http://soap.sforce.com/2006/04/metadata">
    <name>Leasing</name>
</ReportFolder>
```

- [ ] **Step 2: `Vacant_Units.report-meta.xml`** (KPI Vacant Units)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Unit__c.Suite_Number__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Unit__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Vacant</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Property_Asset__c.Property_Name__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Vacant Units</name>
    <reportType>CustomEntityCustomEntity$Property_Asset__c$Unit__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 3: `LOIs_Outstanding.report-meta.xml`** (KPI LOIs Outstanding)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Inquiry__c.Tenant_Name__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Lease_Inquiry__c.Stage__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>LOI Received</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Lease_Inquiry__c.Stage__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>LOIs Outstanding</name>
    <reportType>CustomEntity$Lease_Inquiry__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 4: `Leases_Signed_MTD.report-meta.xml`** (KPI Leases Signed MTD)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Inquiry__c.Tenant_Name__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Lease_Inquiry__c.Stage__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Lease Signed</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Lease_Inquiry__c.Stage__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Leases Signed MTD</name>
    <reportType>CustomEntity$Lease_Inquiry__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
    <timeFrameFilter>
        <dateColumn>Lease_Inquiry__c.Signed_Date__c</dateColumn>
        <interval>INTERVAL_CURMONTH</interval>
    </timeFrameFilter>
</Report>
```

- [ ] **Step 5: `Avg_Days_To_Lease.report-meta.xml`** (KPI Avg Days to Lease)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns>
        <aggregateTypes>Average</aggregateTypes>
        <field>Lease_Inquiry__c.Days_To_Sign__c</field>
    </columns>
    <filter>
        <criteriaItems>
            <column>Lease_Inquiry__c.Stage__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Lease Signed</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Lease_Inquiry__c.Stage__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Avg Days To Lease</name>
    <reportType>CustomEntity$Lease_Inquiry__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 6: `Renewals_Confirmed.report-meta.xml`** (KPI Renewals Confirmed)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Renewal__c.Tenant_Name__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Lease_Renewal__c.Stage__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Renewed</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Day</dateGranularity>
        <field>Lease_Renewal__c.Stage__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Renewals Confirmed</name>
    <reportType>CustomEntity$Lease_Renewal__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 7: `Vacancy_Pipeline.report-meta.xml`** (Vacancy Pipeline FlexTable — Tabular)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Inquiry__c.Property_Name__c</field></columns>
    <columns><field>Lease_Inquiry__c.Space_Required__c</field></columns>
    <columns><field>Lease_Inquiry__c.Tenant_Name__c</field></columns>
    <columns><field>Lease_Inquiry__c.Stage__c</field></columns>
    <columns><field>Lease_Inquiry__c.Days_In_Stage__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Lease_Inquiry__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Active</value>
        </criteriaItems>
    </filter>
    <format>Tabular</format>
    <name>Vacancy Pipeline</name>
    <reportType>CustomEntity$Lease_Inquiry__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <sortColumn>Lease_Inquiry__c.Days_In_Stage__c</sortColumn>
    <sortOrder>Desc</sortOrder>
</Report>
```

- [ ] **Step 8: `Leasing_Velocity_MTD.report-meta.xml`** (Leasing Velocity column chart)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Inquiry__c.Tenant_Name__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Lease_Inquiry__c.Stage__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Lease Signed</value>
        </criteriaItems>
    </filter>
    <format>Summary</format>
    <groupingsDown>
        <dateGranularity>Month</dateGranularity>
        <field>Lease_Inquiry__c.Signed_Date__c</field>
        <sortOrder>Asc</sortOrder>
    </groupingsDown>
    <name>Leasing Velocity MTD</name>
    <reportType>CustomEntity$Lease_Inquiry__c</reportType>
    <scope>organization</scope>
    <showDetails>false</showDetails>
    <showGrandTotal>true</showGrandTotal>
    <showSubTotals>true</showSubTotals>
</Report>
```

- [ ] **Step 9: `Renewal_Negotiations.report-meta.xml`** (Renewal Negotiation FlexTable — Tabular)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://soap.sforce.com/2006/04/metadata">
    <columns><field>Lease_Renewal__c.Tenant_Name__c</field></columns>
    <columns><field>Lease_Renewal__c.Property_Display_Name__c</field></columns>
    <columns><field>Lease_Renewal__c.Stage__c</field></columns>
    <columns><field>Lease_Renewal__c.Proposed_Rate__c</field></columns>
    <filter>
        <criteriaItems>
            <column>Lease_Renewal__c.Status__c</column>
            <columnToColumn>false</columnToColumn>
            <isUnlocked>false</isUnlocked>
            <operator>equals</operator>
            <value>Active</value>
        </criteriaItems>
    </filter>
    <format>Tabular</format>
    <name>Renewal Negotiations</name>
    <reportType>CustomEntity$Lease_Renewal__c</reportType>
    <scope>organization</scope>
    <showDetails>true</showDetails>
    <sortColumn>Lease_Renewal__c.Stage__c</sortColumn>
    <sortOrder>Asc</sortOrder>
</Report>
```

- [ ] **Step 10: Deploy**

Run: `sf project deploy start -d force-app/main/default/reports/Leasing.reportFolder-meta.xml -d force-app/main/default/reports/Leasing -o DPEG-Acq-3 --ignore-conflicts`
Expected: `Status: Succeeded`. (The deploy includes the pre-existing sibling reports already in `reports/Leasing/`? No — only the files present on this branch. If the deploy reports fewer than 8 new + folder, that's fine.) If a report fails on `Space_Required__c`/`Days_In_Stage__c`/`Property_Name__c` field names, confirm the field exists on `Lease_Inquiry__c` via Tooling API and correct the API name.

- [ ] **Step 11: Verify each report opens**

Run: `sf org open -o DPEG-Acq-3 -p "/lightning/o/Report/home"` → open the Leasing folder → confirm the 8 new reports open without error (empty pre-seed is fine).

- [ ] **Step 12: Commit**
```bash
git add force-app/main/default/reports/Leasing.reportFolder-meta.xml force-app/main/default/reports/Leasing
git commit -m "Leasing dashboard reports: 8 native reports (vacancy, LOIs, velocity, renewals)"
```

---

### Task 4: Leasing dashboard (existing `Leasing` dashboard folder)

**Files (Create):**
- `force-app/main/default/dashboards/Leasing.dashboardFolder-meta.xml` (idempotent — `<name>Leasing</name>`)
- `force-app/main/default/dashboards/Leasing/Leasing_Team_Dashboard.dashboard-meta.xml`

**Interfaces:**
- Consumes: the 8 reports from Task 3 + the reused `Leasing/Active_Pipeline_By_Stage`.
- Produces: the dashboard (data appears after Task 5 seeds).

Metric chartSummary uses `<aggregate>` + bare column (proven on PM); charts add `<axisBinding>y</axisBinding>`; the two detail tables are `FlexTable`.

- [ ] **Step 1: Folder meta** — `dashboards/Leasing.dashboardFolder-meta.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<DashboardFolder xmlns="http://soap.sforce.com/2006/04/metadata">
    <name>Leasing</name>
</DashboardFolder>
```

- [ ] **Step 2: Dashboard file** — `dashboards/Leasing/Leasing_Team_Dashboard.dashboard-meta.xml`:
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
                <metricLabel>Vacant Units</metricLabel>
                <report>Leasing/Vacant_Units</report>
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
                <indicatorHighColor>#0B5394</indicatorHighColor>
                <indicatorLowColor>#0B5394</indicatorLowColor>
                <indicatorMiddleColor>#0B5394</indicatorMiddleColor>
                <metricLabel>Prospects in Pipeline</metricLabel>
                <report>Leasing/Active_Pipeline_By_Stage</report>
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
                <metricLabel>LOIs Outstanding</metricLabel>
                <report>Leasing/LOIs_Outstanding</report>
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
                <metricLabel>Leases Signed MTD</metricLabel>
                <report>Leasing/Leases_Signed_MTD</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>2</colSpan><columnIndex>8</columnIndex><rowIndex>0</rowIndex><rowSpan>4</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartSummary><aggregate>Average</aggregate><column>Lease_Inquiry__c.Days_To_Sign__c</column></chartSummary>
                <componentType>Metric</componentType>
                <decimalPrecision>0</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <groupingSortProperties/>
                <indicatorHighColor>#0B5394</indicatorHighColor>
                <indicatorLowColor>#0B5394</indicatorLowColor>
                <indicatorMiddleColor>#0B5394</indicatorMiddleColor>
                <metricLabel>Avg Days to Lease</metricLabel>
                <report>Leasing/Avg_Days_To_Lease</report>
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
                <indicatorHighColor>#1B7A4B</indicatorHighColor>
                <indicatorLowColor>#1B7A4B</indicatorLowColor>
                <indicatorMiddleColor>#1B7A4B</indicatorMiddleColor>
                <metricLabel>Renewals Confirmed</metricLabel>
                <report>Leasing/Renewals_Confirmed</report>
                <showRange>false</showRange>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan><columnIndex>0</columnIndex><rowIndex>4</rowIndex><rowSpan>8</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <componentType>FlexTable</componentType>
                <flexComponentProperties>
                    <decimalPrecision>-1</decimalPrecision>
                    <flexTableColumn><reportColumn>Lease_Inquiry__c.Property_Name__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Lease_Inquiry__c.Space_Required__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Lease_Inquiry__c.Tenant_Name__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Lease_Inquiry__c.Stage__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Lease_Inquiry__c.Days_In_Stage__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableSortInfo><sortColumn>Lease_Inquiry__c.Days_In_Stage__c</sortColumn><sortOrder>2</sortOrder></flexTableSortInfo>
                    <hideChatterPhotos>true</hideChatterPhotos>
                </flexComponentProperties>
                <groupingSortProperties/>
                <header>Vacancy Pipeline — Active Negotiations</header>
                <report>Leasing/Vacancy_Pipeline</report>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>6</colSpan><columnIndex>6</columnIndex><rowIndex>4</rowIndex><rowSpan>8</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <chartAxisRange>Auto</chartAxisRange>
                <chartSummary><axisBinding>y</axisBinding><column>RowCount</column></chartSummary>
                <componentType>Column</componentType>
                <decimalPrecision>0</decimalPrecision>
                <displayUnits>Auto</displayUnits>
                <drillEnabled>true</drillEnabled>
                <drillToDetailEnabled>true</drillToDetailEnabled>
                <enableHover>true</enableHover>
                <expandOthers>false</expandOthers>
                <groupingColumn>Lease_Inquiry__c.Signed_Date__c</groupingColumn>
                <groupingSortProperties/>
                <legendPosition>Bottom</legendPosition>
                <report>Leasing/Leasing_Velocity_MTD</report>
                <showPercentage>false</showPercentage>
                <showValues>true</showValues>
                <sortBy>RowLabelAscending</sortBy>
                <title>Leasing Velocity (by month signed)</title>
                <useReportChart>false</useReportChart>
            </dashboardComponent>
        </dashboardGridComponents>
        <dashboardGridComponents>
            <colSpan>12</colSpan><columnIndex>0</columnIndex><rowIndex>12</rowIndex><rowSpan>6</rowSpan>
            <dashboardComponent>
                <autoselectColumnsFromReport>false</autoselectColumnsFromReport>
                <componentType>FlexTable</componentType>
                <flexComponentProperties>
                    <decimalPrecision>-1</decimalPrecision>
                    <flexTableColumn><reportColumn>Lease_Renewal__c.Tenant_Name__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Lease_Renewal__c.Property_Display_Name__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Lease_Renewal__c.Stage__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableColumn><reportColumn>Lease_Renewal__c.Proposed_Rate__c</reportColumn><showSubTotal>false</showSubTotal><showTotal>false</showTotal><type>detail</type></flexTableColumn>
                    <flexTableSortInfo><sortColumn>Lease_Renewal__c.Stage__c</sortColumn><sortOrder>1</sortOrder></flexTableSortInfo>
                    <hideChatterPhotos>true</hideChatterPhotos>
                </flexComponentProperties>
                <groupingSortProperties/>
                <header>Renewal Negotiation Status</header>
                <report>Leasing/Renewal_Negotiations</report>
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
    <title>Leasing Dashboard</title>
    <titleColor>#000000</titleColor>
    <titleSize>12</titleSize>
</Dashboard>
```

- [ ] **Step 3: Deploy**

Run: `sf project deploy start -d force-app/main/default/dashboards/Leasing.dashboardFolder-meta.xml -d force-app/main/default/dashboards/Leasing -o DPEG-Acq-3 --ignore-conflicts`
Expected: `Status: Succeeded`. If `Column` is rejected as an invalid enum, change that one chart to `Bar` and redeploy (note which). If a FlexTable column errors, confirm the field is an actual column in the Task 3 report.

- [ ] **Step 4: Commit**
```bash
git add force-app/main/default/dashboards/Leasing.dashboardFolder-meta.xml force-app/main/default/dashboards/Leasing
git commit -m "Leasing dashboard: native 6-metric + velocity + 2 FlexTables"
```

---

### Task 5: Seed script + end-to-end verification

**Files (Create):**
- `scripts/seed-leasing-dashboard.apex`

**Interfaces:**
- Consumes: Task 1 fields; existing objects.
- Produces: demo data so every component populates.

- [ ] **Step 1: Write the seed script**

`scripts/seed-leasing-dashboard.apex`:
```apex
// Seeds Leasing dashboard demo data. Idempotent: inquiries marked Initial_Notes__c starting 'LEASESEED',
// renewals marked Tenant_Name__c starting 'LSEED-'. Delete-by-marker then re-insert.
// NOTE: Property_Name__c (Lease_Inquiry), Days_In_Stage__c (Lease_Inquiry), Property_Display_Name__c
// (Lease_Renewal) are FORMULA/read-only — never set them. Set the Property_Asset__c lookup (they derive)
// and set Stage_Start_Date__c so Days_In_Stage computes. Requires the 4 PM-seed properties (find-or-create).
delete [SELECT Id FROM Lease_Inquiry__c WHERE Initial_Notes__c LIKE 'LEASESEED%'];
delete [SELECT Id FROM Lease_Renewal__c WHERE Tenant_Name__c LIKE 'LSEED-%'];

Map<String,Id> props = new Map<String,Id>();
for (Property_Asset__c p : [SELECT Id, Name FROM Property_Asset__c
        WHERE Name IN ('Park North Retail','Riverside Commons','Oak Street Center','Sunset Mixed-Use')]) {
    props.put(p.Name, p.Id);
}
for (String nm : new String[]{'Park North Retail','Riverside Commons','Oak Street Center','Sunset Mixed-Use'}) {
    if (!props.containsKey(nm)) { Property_Asset__c p = new Property_Asset__c(Name = nm); insert p; props.put(nm, p.Id); }
}

Date today = Date.today();
List<Lease_Inquiry__c> inq = new List<Lease_Inquiry__c>();

// 5 at LOI Received (LOIs Outstanding = 5)
for (Integer i = 1; i <= 5; i++) {
    inq.add(new Lease_Inquiry__c(Tenant_Name__c='LOI Prospect ' + i, Property_Asset__c=props.get('Park North Retail'),
        Space_Required__c=1500 + i*100, Stage__c='LOI Received', Status__c='Active',
        Inquiry_Date__c=today.addDays(-40), Stage_Start_Date__c=today.addDays(-8 - i), Initial_Notes__c='LEASESEED'));
}
// 10 more active spread across open stages (Prospects in Pipeline); Stage_Start_Date drives Days_In_Stage
String[] openStages = new String[]{'Inquiry Received','LOI Signed','Lease Drafting','Inquiry Received','LOI Signed'};
for (Integer i = 1; i <= 10; i++) {
    inq.add(new Lease_Inquiry__c(Tenant_Name__c='Prospect ' + i, Property_Asset__c=props.get('Riverside Commons'),
        Space_Required__c=800 + i*120, Stage__c=openStages[Math.mod(i, openStages.size())], Status__c='Active',
        Inquiry_Date__c=today.addDays(-30 - i), Stage_Start_Date__c=today.addDays(-i*3), Initial_Notes__c='LEASESEED'));
}
// 3 signed THIS MONTH, inquiry ~47 days before signing (Leases Signed MTD = 3; Avg Days to Lease ~47)
Integer[] gaps = new Integer[]{45, 47, 49};
for (Integer i = 0; i < 3; i++) {
    Date signed = today.addDays(-i*2);           // all within this month (i in 0..2)
    inq.add(new Lease_Inquiry__c(Tenant_Name__c='Signed MTD ' + (i+1), Property_Asset__c=props.get('Oak Street Center'),
        Space_Required__c=2000, Stage__c='Lease Signed', Status__c='Active',
        Inquiry_Date__c=signed.addDays(-gaps[i]), Signed_Date__c=signed, Initial_Notes__c='LEASESEED'));
}
// 4 signed in prior months (velocity chart trend): last month, 2mo, 3mo, 4mo ago
for (Integer m = 1; m <= 4; m++) {
    Date signed = today.addMonths(-m).toStartOfMonth().addDays(9);
    inq.add(new Lease_Inquiry__c(Tenant_Name__c='Signed M-' + m, Property_Asset__c=props.get('Sunset Mixed-Use'),
        Space_Required__c=1800, Stage__c='Lease Signed', Status__c='Active',
        Inquiry_Date__c=signed.addDays(-47), Signed_Date__c=signed, Initial_Notes__c='LEASESEED'));
}
insert inq;

// Renewals: 6 confirmed (Renewed) + 4 active negotiations with a proposed rate
List<Lease_Renewal__c> ren = new List<Lease_Renewal__c>();
for (Integer i = 1; i <= 6; i++) {
    ren.add(new Lease_Renewal__c(Tenant_Name__c='LSEED-Renewed ' + i, Property_Asset__c=props.get('Park North Retail'),
        Stage__c='Renewed', Status__c='Active', Proposed_Rate__c=25 + i));
}
String[] negStages = new String[]{'Notice Sent','Awaiting Tenant Response','Negotiating','Notice Sent'};
for (Integer i = 0; i < 4; i++) {
    ren.add(new Lease_Renewal__c(Tenant_Name__c='LSEED-Neg ' + (i+1), Property_Asset__c=props.get('Riverside Commons'),
        Stage__c=negStages[i], Status__c='Active', Proposed_Rate__c=28 + i));
}
insert ren;

System.debug('Leasing seed: ' + inq.size() + ' inquiries, ' + ren.size() + ' renewals. '
    + [SELECT COUNT() FROM Lease_Inquiry__c WHERE Stage__c='LOI Received' AND Initial_Notes__c LIKE 'LEASESEED%'] + ' LOIs, '
    + [SELECT COUNT() FROM Lease_Inquiry__c WHERE Stage__c='Lease Signed' AND Signed_Date__c = THIS_MONTH AND Initial_Notes__c LIKE 'LEASESEED%'] + ' signed MTD, '
    + [SELECT COUNT() FROM Lease_Renewal__c WHERE Stage__c='Renewed' AND Tenant_Name__c LIKE 'LSEED-%'] + ' renewed.');
```

- [ ] **Step 2: Run it**

Run: `sf apex run -f scripts/seed-leasing-dashboard.apex -o DPEG-Acq-3`
Expected: `Executed successfully.` debug `Leasing seed: 22 inquiries, 10 renewals. 5 LOIs, 3 signed MTD, 6 renewed.`

- [ ] **Step 3: Verify aggregates**

Run: `sf data query -o DPEG-Acq-3 -q "SELECT Stage__c, COUNT(Id) n FROM Lease_Inquiry__c WHERE Status__c='Active' GROUP BY Stage__c"`
Expected: LOI Received ≥5, plus open-stage spread; total active ≈ existing 5 + 22 seeded.
Run: `sf data query -o DPEG-Acq-3 -q "SELECT AVG(Days_To_Sign__c) avg FROM Lease_Inquiry__c WHERE Stage__c='Lease Signed' AND Initial_Notes__c LIKE 'LEASESEED%'"`
Expected: ≈47.
Run: `sf data query -o DPEG-Acq-3 -q "SELECT COUNT(Id) FROM Lease_Renewal__c WHERE Stage__c='Renewed'"`
Expected: ≥6.

- [ ] **Step 4: Verify report bindings (Apex Reports API, since `sf org api request rest` is unavailable)**

Write `scripts/tmp-verify-leasing.apex` running these reports by DeveloperName and printing grand totals: `Leases_Signed_MTD` (expect 3), `Avg_Days_To_Lease` (expect ≈47), `Vacant_Units` (expect ≥10), and confirm the two Tabular reports `Vacancy_Pipeline`/`Renewal_Negotiations` return detail rows. Example per report:
```apex
Id rid = [SELECT Id FROM Report WHERE DeveloperName='Leases_Signed_MTD'].Id;
Reports.ReportResults r = Reports.ReportManager.runReport(rid, true);
System.debug('Leases_Signed_MTD grandTotal=' + r.getFactMap().get('T!T').getAggregates()[0].getValue());
```
Run: `sf apex run -f scripts/tmp-verify-leasing.apex -o DPEG-Acq-3`. Delete the temp file after (do not commit it).

- [ ] **Step 5: Visual check (user sign-off)**

Run: `sf org open -o DPEG-Acq-3 -p "/lightning/o/Dashboard/home"` → Leasing folder → **Leasing Dashboard** → Refresh. Confirm 6 metrics (Vacant Units, Prospects, LOIs=5, Leases Signed MTD=3, Avg Days to Lease≈47, Renewals Confirmed≥6), the Vacancy Pipeline FlexTable (Property/Sq Ft/Tenant/Stage/Days), the Leasing Velocity column chart (bars per month), and the Renewal Negotiation FlexTable. Compare to the mockup.

- [ ] **Step 6: Commit**
```bash
git add scripts/seed-leasing-dashboard.apex
git commit -m "Seed script: Leasing dashboard demo data (inquiries + renewals)"
```

---

## Plan deviations from spec (intentional)

- Reused reports = only `Active_Pipeline_By_Stage` (Summary, active, grouped by stage → Prospects metric). The vacancy table gets a NEW `Vacancy_Pipeline` report (the existing `Active_Inquiries` has only Tenant+Stage columns and is shared by another dashboard, so it can't back the 5-column FlexTable).
- Avg-days-to-lease anchors on the new `Inquiry_Date__c` (not `CreatedDate`, which a seed can't set; not `LOI_Date__c`, which would understate inquiry→sign).
- Leases Signed MTD uses a report `timeFrameFilter` (INTERVAL_CURMONTH) on `Signed_Date__c`.
- The seed sets the `Property_Asset__c` lookup and `Stage_Start_Date__c`, NOT `Property_Name__c` / `Days_In_Stage__c` / `Property_Display_Name__c` — those are formula/read-only (verified via describe) and derive from the lookup. Reports still use those formula fields as display columns (formula fields are reportable).
