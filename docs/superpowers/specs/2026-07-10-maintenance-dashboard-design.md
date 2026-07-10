# Maintenance Dashboard — Design

- **Date:** 2026-07-10
- **Branch:** `feature/pm-role-dashboards` (third of the three role dashboards; PM + Leasing already built there)
- **Source mockup:** "Maintenance Dashboard · Fernando / Haylie" (work-order tracking, vendor dispatch, aging alerts, escalation rules — Yardi + Salesforce)
- **Status:** Approved approach — final role dashboard. This spec covers **Maintenance only.**

## Purpose

A native Salesforce dashboard for the maintenance team: open work orders, priority/escalation counts, resolution throughput, work-order aging, an active-work-order priority list, SLA tiers, and vendor performance. All data is `Work_Order__c` (a read-only Yardi mirror); Salesforce adds the SLA/aging/escalation views Yardi lacks.

Each dashboard component is backed by its own report (native requirement). One new formula field; no new objects.

## Scope / Non-goals

- **In scope:** 1 new field on `Work_Order__c` (`Resolution_Days__c`), 9 new reports + 1 reused, one dashboard, a seed script, FLS.
- **Out of scope:** the mockup's colored header/badge/caption (HTML chrome); the mockup's illustrative labels that don't match real picklists (see below); star ratings on Vendor Performance (no backing field — avg resolution days shown instead).
- **Reuse:** the org's existing `Work Orders` report folder and `Work Orders` dashboard folder (from the work-order-tracker branch). New reports land in the existing `Work Orders` folder; the dashboard joins `Work_Order_Health` in the existing `Work Orders` dashboard folder.

## Mockup-label → real-value mapping (decisions)

The mockup uses illustrative labels; the real `Work_Order__c` picklists differ. Adjudicated:
- **"Emergency / High"** → Priority in (`Critical`, `High`) and open. (Real priority values: Critical / High / Medium / Low — no "Emergency".)
- **"Vendor Dispatched"** → count of open work orders at Status = `In Progress` (active assignments). (No "Dispatched" status exists.)
- **"Recurring Scheduled"** → **replaced** with a real KPI: count at Status = `On Hold`. (No "Recurring/Inspection" category exists; no schema invented.)
- **SLA Escalation Rules** → data-driven report grouped by `Priority__c` showing the SLA target hours (`SLA_Target_Hours__c`, a real per-record formula), instead of a static text table (native dashboards have no free-text widget).
- **Vendor Performance** → report grouped by `Vendor__c` with AVERAGE resolution days; no star ratings.

## Cross-branch note

`Work_Order__c` lives on the work-order-tracker branch, in the org. This branch's field/report/dashboard XML deploys to the org (the superset) and rides as cross-branch artifacts, consistent with PM and Leasing.

## New field on `Work_Order__c`

`Resolution_Days__c` — Formula (Number, 1 dp): `Completed_Date__c - Reported_Date__c` (datetime − datetime = days), `formulaTreatBlanksAs` BlankAsBlank (null while not completed → excluded from vendor averages). Drives Vendor Performance.

## Reports — existing `Work Orders` folder

Metrics need Summary/Matrix; FlexTables need Tabular; charts need Summary groupings.

| # | Report API name | Source | Format | Serves | Reuse? |
|---|---|---|---|---|---|
| 1 | `Open_Work_Orders_by_Priority` | `Work_Order__c` Is_Open, grouped by Priority | Summary | KPI "Open Work Orders" (grand total) | **Reuse existing** |
| 2 | `Critical_High_Open` | `Work_Order__c` Is_Open, Priority in (Critical, High) | Summary, count | KPI "Emergency / High" | New |
| 3 | `Escalated_Overdue` | `Work_Order__c` Is_Escalation=true | Summary, count | KPI "Overdue >15d" | New |
| 4 | `In_Progress_WOs` | `Work_Order__c` Status=In Progress | Summary, count | KPI "Vendor Dispatched" | New |
| 5 | `Resolved_MTD` | `Work_Order__c` Status in (Completed, Closed), Completed_Date this month | Summary, count | KPI "Resolved MTD" | New |
| 6 | `On_Hold_WOs` | `Work_Order__c` Status=On Hold | Summary, count | KPI "On Hold" | New |
| 7 | `WO_Aging_Buckets` | `Work_Order__c` Is_Open, bucket `Hours_Open__c` (0-3d ≤72 / 4-7d / 8-14d / >15d) | Summary | "Work Order Aging" bar | New |
| 8 | `Active_WO_Priority` | `Work_Order__c` Is_Open (Property, Subject, Priority, Vendor, Hours_Open) | Tabular | "Active Work Orders" FlexTable | New |
| 9 | `SLA_Tiers_by_Priority` | `Work_Order__c` grouped by Priority, MAX `SLA_Target_Hours__c` | Summary | "SLA Escalation Rules" table | New |
| 10 | `Vendor_Performance` | `Work_Order__c` completed (Resolution_Days≥0.1), grouped by Vendor, AVERAGE `Resolution_Days__c` | Summary | "Vendor Performance" table | New |

9 new reports + 1 reused (#1).

## Dashboard — `Maintenance_Dashboard` (existing `Work Orders` dashboard folder)

- **Type:** SpecifiedUser; running user `test-3iuncy5c1je5@example.com` (repoint on promotion).
- **Top row — 6 metrics:** Open Work Orders (rpt 1) · Critical / High (rpt 2) · Overdue >15d (rpt 3) · Vendor Dispatched / In Progress (rpt 4) · Resolved MTD (rpt 5) · On Hold (rpt 6).
- **Body:**
  - Work Order Aging — **Bar** (rpt 7, count by aging bucket).
  - Active Work Orders (Priority View) — **FlexTable** (rpt 8): Property, Issue (Subject), Priority, Vendor, Days Open (Hours_Open) — 5 detail columns, so FlexTable.
  - SLA Tiers by Priority — **Table** (rpt 9): grouping Priority + MAX SLA target hours (grouping + one aggregate, so a legacy Table renders Priority | hours).
  - Vendor Performance — **Table** (rpt 10): grouping Vendor + AVG resolution days (grouping + one aggregate, legacy Table renders Vendor | avg days).

Native metadata gotchas (proven on PM + Leasing) apply: `<aggregate>` element (not a!/s!); `Bar`=horizontal / `Column`=vertical; FlexTable for detail tables; a report feeding both a metric and a FlexTable must be split; `Resolved_MTD` uses a `timeFrameFilter` INTERVAL_THISMONTH on `Completed_Date__c`.

## Security

`Property_Management_Access` gains read FLS on `Work_Order__c.Resolution_Days__c` (the perm set already grants the object). Shared-file superset-deploy + minimal-commit procedure as before.

## Seed data — `scripts/seed-maintenance-dashboard.apex`

`Work_Order__c` is a read-only Yardi mirror; the seed inserts directly (system context). Idempotent by a `Subject__c` marker prefix `WOSEED-`. Reaches demo-scale numbers on top of existing data:
- ~37 open work orders across priorities (a handful Critical/High so "Critical / High" ≈ 4–8); several with `Reported_Date__c` > 15 days ago so `Is_Escalation__c` fires (Overdue >15d ≈ 6); ~20 at Status `In Progress`; ~8 at `On Hold`; a spread of `Hours_Open__c` ages (via staggered `Reported_Date__c`) so the aging buckets populate; each with a `Vendor__c` and `Property_Asset__c`.
- ~40 completed this month (Status `Completed`/`Closed`, `Completed_Date__c` this month, `Reported_Date__c` a few days earlier) so "Resolved MTD" ≈ 40 and `Resolution_Days__c` populates for Vendor Performance across a few vendors (AirPro HVAC, TopShield Roofing, ProPlumb, Elec Solutions) with differing average days.
- Exact required fields (`Subject__c`, `Reported_Date__c`, owner) confirmed at plan time; the seed sets `Owner_User__c` (the module uses this, not OwnerId) and `Property_Asset__c` (Property_Display_Name is a formula).

## Testing & verification

- Deploy field → perm set → reports → dashboard → seed.
- Run the seed; verify: Open ≈37, Critical/High ≈4–8, Overdue ≈6, In Progress ≈20, Resolved MTD ≈40, On Hold ≈8; aging buckets non-empty; Vendor Performance shows avg days per vendor.
- Verify metric-source Summary reports and FlexTable Tabular reports render via the Apex Reports API.
- User does final visual sign-off.

## Future (context only)

Work orders sync from Yardi (read-only); Salesforce adds SLA/aging/escalation. On promotion: repoint running user, add folder sharing, harden the read-only mirror.
