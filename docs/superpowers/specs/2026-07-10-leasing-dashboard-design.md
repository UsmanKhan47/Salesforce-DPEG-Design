# Leasing Dashboard — Design

- **Date:** 2026-07-10
- **Branch:** `feature/pm-role-dashboards` (continues the role-dashboards work; PM already built there)
- **Source mockup:** "Leasing Dashboard · Leasing Team" (vacancy pipeline, negotiation tracker, deal velocity, lease status — Salesforce workflow layer over Yardi)
- **Status:** Approved approach — second of three role dashboards (PM done; Maintenance next). This spec covers **Leasing only.**

## Purpose

A native Salesforce dashboard for the leasing team: vacant units, active prospects, LOIs outstanding, leases signed this month, average days-to-lease, and renewals confirmed, plus a vacancy-pipeline table, monthly leasing velocity, and renewal-negotiation status. Data comes from the existing lease-tracker objects (`Lease_Inquiry__c`, `Lease_Renewal__c`) and rent-roll `Unit__c`; Salesforce captures negotiation workflow, lease creation stays in Yardi.

Each dashboard component is backed by its own report (native requirement). No new objects — every widget maps to existing objects plus one formula field.

## Scope / Non-goals

- **In scope:** 2 new fields on `Lease_Inquiry__c`, 7 new reports + 2 reused, one dashboard, a seed script, FLS additions.
- **Out of scope:** the Maintenance dashboard (its own spec); the mockup's colored header/badge/caption (HTML chrome); the mockup's illustrative stage labels (LOI Sent / Negotiating / Prospect / Gone Dark) — the real `Lease_Inquiry__c.Stage__c` picklist is used instead (Inquiry Received / LOI Received / LOI Signed / Lease Drafting / Lease Signed); a "Unit/Suite" column in the vacancy table (no such field on `Lease_Inquiry__c` — **dropped** per decision; Property + Space Required convey the space).
- **Reuse:** the org's existing `Leasing` report folder and `Leasing` dashboard folder (from sibling branches). New reports land in the existing `Leasing` folder; the dashboard in the existing `Leasing` dashboard folder alongside `Lease_Pipeline` / `Lease_Renewals`.

## Cross-branch note

`Lease_Inquiry__c` / `Lease_Renewal__c` live on sibling branches (lease-activity / lease-renewal), `Unit__c` on rent-roll — all in the org. This branch's new field/report/dashboard XML deploys to the org (the superset) and rides as cross-branch artifacts, consistent with the PM dashboard and how the org already works.

## New fields on `Lease_Inquiry__c`

- `Inquiry_Date__c` — Date. The date the inquiry was received. Real, controllable field (unlike system `CreatedDate`, which a seed can't set) so average days-to-lease is meaningful and reproducible.
- `Days_To_Sign__c` — Formula (Number, 0 dp): `Signed_Date__c - Inquiry_Date__c`, `formulaTreatBlanksAs` BlankAsBlank (null when not yet signed → excluded from the average). Report AVERAGE over signed inquiries = "Avg Days to Lease".

## Reports — existing `Leasing` folder

Native Metric components need Summary/Matrix; FlexTables need Tabular; charts need Summary groupings.

| # | Report API name | Source | Format | Serves | Reuse? |
|---|---|---|---|---|---|
| 1 | `Vacant_Units` | `Unit__c` Status=Vacant (parent-child report type `CustomEntityCustomEntity$Property_Asset__c$Unit__c`) | Summary, count | KPI "Vacant Units" | New |
| 2 | `Active_Pipeline_By_Stage` | `Lease_Inquiry__c` active, grouped by Stage | Summary | KPI "Prospects in Pipeline" (grand-total count) | **Reuse existing** |
| 3 | `LOIs_Outstanding` | `Lease_Inquiry__c` Stage=`LOI Received` | Summary, count | KPI "LOIs Outstanding" | New |
| 4 | `Leases_Signed_MTD` | `Lease_Inquiry__c` Stage=`Lease Signed` AND Signed_Date = THIS MONTH | Summary, count | KPI "Leases Signed MTD" | New |
| 5 | `Avg_Days_To_Lease` | `Lease_Inquiry__c` Signed (Days_To_Sign not null), AVERAGE of `Days_To_Sign__c` | Summary | KPI "Avg Days to Lease" (grand-total avg) | New |
| 6 | `Renewals_Confirmed` | `Lease_Renewal__c` Stage=`Renewed` | Summary, count | KPI "Renewals Confirmed" | New |
| 7 | `Active_Inquiries` | `Lease_Inquiry__c` active (Property, Space Required, Tenant, Stage, Days in Stage) | Tabular | "Vacancy Pipeline" FlexTable | **Reuse existing** (verify columns; if they don't fit, new `Vacancy_Pipeline` Tabular) |
| 8 | `Leasing_Velocity_MTD` | `Lease_Inquiry__c` Stage=`Lease Signed`, grouped by `Signed_Date__c` calendar month | Summary, count | "Leasing Velocity" column chart | New |
| 9 | `Renewal_Negotiations` | `Lease_Renewal__c` active (Tenant, Property, Stage, Proposed_Rate) | Tabular | "Renewal Negotiation Status" FlexTable | New |

7 new reports (#1,3,4,5,6,8,9) + 2 reused (#2, #7).

## Dashboard — `Leasing_Team_Dashboard` (existing `Leasing` dashboard folder)

- **Type:** SpecifiedUser; running user `test-3iuncy5c1je5@example.com` (matches existing dashboards; repoint on promotion).
- **Top row — 6 metrics:** Vacant Units (rpt 1) · Prospects in Pipeline (rpt 2 grand total) · LOIs Outstanding (rpt 3) · Leases Signed MTD (rpt 4) · Avg Days to Lease (rpt 5 grand-total avg) · Renewals Confirmed (rpt 6).
- **Body:**
  - Vacancy Pipeline — **FlexTable** (rpt 7): Property, Space Required, Tenant, Stage, Days in Stage.
  - Leasing Velocity MTD — **Column chart** (rpt 8, count by signed month).
  - Renewal Negotiation Status — **FlexTable** (rpt 9): Tenant, Property, Stage, Proposed Rate.

Native metadata gotchas (from the PM build) apply: `<aggregate>Average|Sum</aggregate>` element (not `a!`/`s!` inline); `Bar`=horizontal / `Column`=vertical; a report feeding both a metric and a FlexTable must be split by format.

## Security

`Property_Management_Access` gains read FLS on `Lease_Inquiry__c.Inquiry_Date__c` and `Days_To_Sign__c` (the perm set already grants the objects). Shared-file superset-deploy + minimal-commit procedure as before.

## Seed data — `scripts/seed-leasing-dashboard.apex`

Idempotent (delete prior seeded rows by marker, re-insert). Reaches mockup-like numbers on top of existing data:
- **Lease inquiries (marked `Initial_Notes__c` starting `LEASESEED`):** ~18 active across open stages (Inquiry Received / LOI Received / LOI Signed / Lease Drafting) so "Prospects in Pipeline" ≈ 18; **5** at Stage `LOI Received` → "LOIs Outstanding" = 5; **3** at Stage `Lease Signed` with `Signed_Date__c` = this month and `Inquiry_Date__c` ≈ 47 days earlier → "Leases Signed MTD" = 3 and "Avg Days to Lease" ≈ 47; a spread of signed inquiries across recent months → the velocity chart shows a monthly trend.
- **Renewals (marked, e.g. `Tenant_Name` prefix `LSEED-`):** enough at Stage `Renewed` so "Renewals Confirmed" ≈ 6; a few active (Notice Sent / Awaiting Tenant Response / Negotiating) with `Proposed_Rate__c` set → the Renewal Negotiation FlexTable.
- **Vacant units:** already 12 in the org (PM seed + Cypresswood) → "Vacant Units" ≈ 12; no new units needed.

## Testing & verification

- Deploy fields → perm set → reports → dashboard → seed (reports reference the objects; dashboard references reports).
- Run the seed; verify: Prospects ≈18, LOIs Outstanding =5, Leases Signed MTD =3, Avg Days to Lease ≈47, Renewals Confirmed ≈6, Vacant Units ≈12.
- Verify the 3 metric-source Summary reports and the 2 FlexTable Tabular reports render via the Analytics/Apex Reports API (as in the PM build).
- User does final visual sign-off on the dashboard.

## Future (context only)

Lease creation stays in Yardi; Salesforce captures negotiation history. On promotion: repoint the dashboard running user, add folder sharing, and the same read-only hardening posture as the other modules.
