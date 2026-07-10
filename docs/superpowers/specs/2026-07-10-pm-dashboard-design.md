# Property Management Dashboard — Design

- **Date:** 2026-07-10
- **Branch:** `feature/pm-role-dashboards` (off `main`)
- **Source mockup:** "Property Management Dashboard · Isha" (occupancy, renewals, CAM reconciliation, insurance, delinquency — Yardi ETL read-only display layer)
- **Status:** Approved approach — first of three role dashboards (PM, then Leasing, then Maintenance). This spec covers **Property Management only.**

## Purpose

A native Salesforce dashboard giving the property manager (Isha) one view of the managed portfolio: property count, occupancy, upcoming lease renewals, tenant delinquency/AR aging, CAM reconciliation status, and insurance expiry. Data is a read-only mirror of Yardi (dummy-seeded now, nightly Yardi ETL later); Salesforce is the visibility/workflow layer and never writes back.

Each dashboard component is backed by its own saved report (native dashboard requirement).

## Scope / Non-goals

- **In scope:** 3 new read-only objects (Delinquency, CAM Reconciliation, Insurance Policy), one helper formula field on `Unit__c`, 8 reports (some reused), one dashboard, a seed script, and read-only perm-set access.
- **Out of scope:** the Leasing and Maintenance dashboards (their own later specs); the mockup's colored header, "Phase 2" badge, and caption (HTML chrome, not native dashboard features); the "+2% vs last quarter" occupancy trend (no historical data exists); any write-back or workflow on the new objects.
- **Reuse:** the org already has a `Leasing` report folder and a `Work Orders` folder from sibling branches. For this PM dashboard, all 8 reports are new (native Metric components require Summary/Matrix reports, and the existing renewal report is Tabular). Report reuse applies to the later Leasing/Maintenance dashboards.

## Cross-branch note

The source objects span unmerged branches: `Unit__c`/`Property_Asset__c` (rent-roll), `Lease_Renewal__c` (lease-renewal-tracker), plus the 3 new objects here. All coexist in the shared org DPEG-Acq-3, so the dashboard works, but this branch's report/dashboard/field XML references objects defined on other branches. This matches how the org already operates (org is the superset); the `Unit__c.Occupied_Flag__c` field rides as a cross-branch artifact until branches merge.

## Data model — 3 new read-only objects

Yardi-mirror pattern (same philosophy as `Work_Order__c`): standalone **Lookup** to `Property_Asset__c` (not master-detail — avoids the Light-Application-object constraint and keeps them reportable independently), `enableReports=true`, read-only via perm set. Auto-number names.

### `Delinquency__c` — label "Delinquency", plural "Delinquencies", `DEL-{0000}`

| Field | Type | Notes |
|---|---|---|
| `Property_Asset__c` | Lookup(Property_Asset__c) | relationshipName `Delinquencies` |
| `Tenant_Name__c` | Text(120) | |
| `Unit_Suite__c` | Text(20) | optional |
| `Balance__c` | Currency(16,2) | AR balance owed |
| `Aging_Bucket__c` | Picklist (restricted): `1–30 Days`, `31–60 Days`, `61–90 Days`, `90+ Days` | drives KPI + aging chart |
| `Yardi_AR_Id__c` | Text(50), External ID, unique (case-insensitive) | future upsert key |

### `CAM_Reconciliation__c` — label "CAM Reconciliation", plural "CAM Reconciliations", `CAM-{0000}`

| Field | Type | Notes |
|---|---|---|
| `Property_Asset__c` | Lookup(Property_Asset__c) | relationshipName `CAM_Reconciliations` |
| `Reconciliation_Year__c` | Text(4) | e.g. "2024" |
| `Status__c` | Picklist (restricted): `Pending` (default), `In Review`, `Approved` | not-Approved = pending KPI |
| `Amount__c` | Currency(16,2) | optional |
| `Yardi_CAM_Id__c` | Text(50), External ID, unique (case-insensitive) | |

### `Insurance_Policy__c` — label "Insurance Policy", plural "Insurance Policies", `INS-{0000}`

| Field | Type | Notes |
|---|---|---|
| `Policy_Name__c` | Text(120) | e.g. "Maple Portfolio" (some are portfolios, not single assets) |
| `Property_Asset__c` | Lookup(Property_Asset__c) | optional; relationshipName `Insurance_Policies` |
| `Carrier__c` | Text(80) | optional |
| `Expiry_Date__c` | Date | |
| `Days_To_Expiry__c` | Formula (Number, 0 dp) = `Expiry_Date__c - TODAY()` | drives KPI + alerts (≤60 = expiring) |
| `Yardi_Policy_Id__c` | Text(50), External ID, unique (case-insensitive) | |

## Helper field on `Unit__c`

`Occupied_Flag__c` — Formula (Number, 0 dp): `IF(ISPICKVAL(Status__c,'Occupied'), 100, 0)`. Occupancy in the mockup is **unit-count based** (Park North 23/24 ≈ 96%, Riverside 23/26 ≈ 88%, Oak 20/22 ≈ 91%, Sunset 14/18 ≈ 78%). Using 100/0 means a report's **AVERAGE** of this field equals occupancy as a percentage number (89 = 89%) — no custom summary formula needed. The grand-total average is the portfolio metric; the per-property average is the chart. Deployed to the org's existing `Unit__c`; carried as a lone field file on this branch.

## Reports — folder `Property Management` (new report folder)

| # | Report API name | Source | Format / grouping | Serves |
|---|---|---|---|---|
| 1 | `Managed_Properties` | `Property_Asset__c` | Summary, record count | KPI "Properties" |
| 2 | `Occupancy_by_Property` | `Unit__c` | Summary grouped by `Property_Asset__c`, AVERAGE of `Occupied_Flag__c` | KPI "Portfolio Occupancy" (grand-total avg) **and** "Occupancy by Property" bar |
| 3 | `Renewals_Due_90d` | `Lease_Renewal__c`, Status=Active, Days_To_Expiry ≤90 | Summary, record count | KPI "Renewals Due 90d" |
| 4 | `Renewal_Pipeline_Buckets` | `Lease_Renewal__c`, Status=Active | Summary grouped by a **bucket column** on `Days_To_Expiry__c`: `<0 → Expired–M2M`, `0–30`, `31–60`, `61–90`, `91–180` | "Lease Renewal Pipeline" column chart |
| 5 | `Delinquency_Aging` | `Delinquency__c` | Summary grouped by `Aging_Bucket__c`, `SUM(Balance__c)` + record count | KPI "Delinquent Tenants" (grand-total record count) **and** "Delinquency Aging" |
| 6 | `CAM_Pending` | `CAM_Reconciliation__c`, Status ≠ Approved | Summary, record count | KPI "CAM Recon Pending" |
| 7 | `CAM_Reconciliation_Status` | `CAM_Reconciliation__c`, all rows | Summary grouped by property (Property, Year, Status shown) | "CAM Reconciliation" table |
| 8 | `Insurance_Expiring` | `Insurance_Policy__c`, Days_To_Expiry ≤60 | Summary, record count (Policy, Days_To_Expiry shown) | KPI "Insurance Expiring" **and** "Insurance Expiry Alerts" list |

All 8 reports are new. (Planning refinement: the existing tabular `Renewals_Expiring_Soonest` cannot source a native Metric component — those require Summary/Matrix — so a dedicated Summary report `Renewals_Due_90d` is added instead of reusing it. Report reuse will apply more to the later Leasing/Maintenance dashboards, which have matching summary reports.)

## Dashboard — `Property_Management` (new dashboard folder `Property Management`)

- **Type:** `SpecifiedUser`; running user `test-3iuncy5c1je5@example.com` (matches the existing `Work_Order_Health` dashboard; repoint on promotion).
- **Top row — 6 metric components:** Properties (rpt 1) · Portfolio Occupancy % (rpt 2 grand total) · Renewals Due 90d (rpt 3) · Delinquent Tenants (rpt 5 grand total) · CAM Recon Pending (rpt 6) · Insurance Expiring (rpt 8).
- **Body components:**
  - Lease Renewal Pipeline — **column chart** (rpt 4, grouped by bucket, record count).
  - Occupancy by Property — **horizontal bar chart** (rpt 2, `Occ_Pct` per property).
  - Delinquency Aging — **bar chart** (rpt 5, `SUM(Balance__c)` by bucket).
  - CAM Reconciliation — **table** (rpt 7) with conditional formatting coloring `Status__c` (Approved green / In Review amber / Pending grey).
  - Insurance Expiry Alerts — **table** (rpt 8), sorted ascending by `Days_To_Expiry__c`.

## Security

`Property_Management_Access` perm set gains read-only object access (allowRead, viewAllRecords true; create/edit/delete/modifyAll false) and read-only FLS on every new field of `Delinquency__c`, `CAM_Reconciliation__c`, `Insurance_Policy__c`, plus read FLS on `Unit__c.Occupied_Flag__c`. (This is a shared file on a shared org — deploy the org-superset version, commit the minimal diff, per the established gotcha.)

## Seed data — `scripts/seed-pm-dashboard.apex`

Idempotent (delete existing seeded rows by their `Yardi_*_Id__c` prefix and the four seeded properties' units, re-insert). Reproduces the mockup:

- **Properties + units (for the occupancy chart):** create 4 `Property_Asset__c` matching the mockup — Park North Retail (24 units, 1 vacant), Riverside Commons (26 units, 3 vacant), Oak Street Center (22 units, 2 vacant), Sunset Mixed-Use (18 units, 4 vacant). Units carry only `Suite_Number__c` + `Status__c` (occupancy is count-based, so no sqft/rent needed). This gives per-property occupancy 96% / 88% / 91% / 78% and a portfolio grand-total that the KPI computes from live data (~88–91% depending on whether the pre-existing Cypresswood units are counted) — the KPI reflects actual seeded data, not a hardcoded 91%.
- **Delinquency (5 tenants):** 1–30 Days totaling $8,200 across 3 tenants; 31–60 Days $5,800 (1 tenant); 61–90 Days $12,400 (1 tenant). (Grand-total count = 5 → KPI; SUM by bucket → aging chart.)
- **CAM (4 rows, 3 not-Approved):** Park North = Approved, Riverside = In Review, Oak Street = Pending, Sunset = Pending → not-Approved count = 3 → KPI; all 4 rows → the status table.
- **Insurance (4 policies, 2 expiring):** Maple Portfolio (expiry TODAY+18), NW Industrial (TODAY+44) → both ≤60d; plus Park North (TODAY+120) and Riverside (TODAY+200) so the ≤60 filter is meaningful → KPI/alerts count = 2.
- Renewals draw on the existing seeded `Lease_Renewal__c` data already in the org; the seed script does not create those.

## Testing & verification

- Deploy objects/field → perm set → reports → dashboard, in that order (reports reference objects; dashboard references reports; the flexipage/app gotcha analog).
- Run the seed script; verify aggregates: Delinquency count = 5 with bucket sums $8,200/$5,800/$12,400; CAM not-Approved = 3; Insurance ≤60d = 2.
- Open the dashboard in the Property Management app, confirm all six metrics render and the five body components populate; visually compare against the mockup.
- User does final visual sign-off.

## Future Yardi integration (context only)

Nightly ETL upserts `Delinquency__c` by `Yardi_AR_Id__c`, `CAM_Reconciliation__c` by `Yardi_CAM_Id__c`, `Insurance_Policy__c` by `Yardi_Policy_Id__c` (wholesale replace per property). Reports/dashboard need no change. An integration user gets a separate write perm set.
