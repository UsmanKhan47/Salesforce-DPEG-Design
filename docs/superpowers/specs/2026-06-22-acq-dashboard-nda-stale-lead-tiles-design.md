# Acquisitions Dashboard — NDA Expiry & Stale Leads Tiles

**Date:** 2026-06-22
**Status:** Approved (design)

## Goal

Add two new KPI metric tiles to the **Acquisitions Dashboard**
(`force-app/main/default/dashboards/Acquisitions/Acquisitions_Dashboard_Junior.dashboard-meta.xml`):

1. **NDAs Expiring (Month)** — signed NDAs whose expiry falls in the current calendar month.
2. **7-Day Stale Leads** — open Leads with no activity in the last 7 days.

These are distinct from the two similarly-named tiles already on the dashboard:
- Existing "NDAs This Month" filters on `Date_Sent__c = THIS_MONTH` (NDAs *sent*, not *expiring*).
- Existing "7-Day Stale Deals" filters Opportunities on `LAST_ACTIVITY` (stale *Deals*, not *Leads*).

## Component 1 — NDAs Expiring (Month)

- **Report:** new `Acquisitions/NDAs_Expiring_This_Month` (Summary, RowCount).
- **Report type:** existing `NDAs` custom report type (`baseObject = NDA__c`).
- **Filter:**
  - `NDA__c.Status__c = Signed`
  - `NDA__c.NDA_Expiry_Date__c = THIS_MONTH`
- **Report-type change:** `NDAs.reportType` does not currently expose `NDA_Expiry_Date__c`.
  A custom report type can only filter/column on exposed fields, so add `NDA_Expiry_Date__c`
  to its sections.
- **Tile:** Metric, label "NDAs Expiring (Month)". Watch-item styling (low count = ok/blue,
  rising = amber/red), consistent with existing tiles.

## Component 2 — 7-Day Stale Leads

- **Report:** new `Acquisitions/Stale_Leads_7Day` (Summary, RowCount).
- **Report type:** standard **Leads** report type (natively exposes "Last Activity").
  The exact metadata `reportType` token (e.g. `LeadList`) is confirmed against the org during
  implementation; if the standard type is unsuitable, fall back to a custom report type.
- **Filter (open leads gone cold):**
  - `IsConverted = false`
  - `Status != Disqualified` AND `Status != Converted` (this org's Lead Status picklist is
    New / Under Review / Qualified / Converted / Disqualified — there is no standard
    "Closed - Not Converted"; Disqualified = dead, Converted = promoted out of the funnel)
  - Staleness via filter logic capturing **both** cold and never-touched leads:
    `(Last Activity < LAST_N_DAYS:7) OR (Last Activity is blank AND Created Date < LAST_N_DAYS:7)`
  - Boolean filter: `1 AND 2 AND 3 AND (4 OR (5 AND 6))`
    where 1=IsConverted false, 2=Status≠Disqualified, 3=Status≠Converted,
    4=Last Activity < LAST_N_DAYS:7, 5=Last Activity blank, 6=Created < LAST_N_DAYS:7.
- **Rationale for the refinement:** the existing Stale Deals report uses a bare
  `LAST_ACTIVITY < LAST_N_DAYS:7`. A "less than" date filter excludes blank values, so for
  bulk-imported leads that never get a logged activity the metric would be misleadingly low.
  Including the never-touched-but-old branch keeps the number meaningful.
- **Tile:** Metric, label "7-Day Stale Leads". Watch-item styling (rising = red).

## Dashboard layout

12-column grid, `rowHeight = 36`.

- **NDAs Expiring (Month)** → fills the existing empty slot at **row 4, col 9–11**
  (completes that metric row to four tiles).
- **7-Day Stale Leads** → new metric row at **row 8, col 0–2** (colSpan 3, rowSpan 4).
- The two existing charts (Deal Stage Pipeline, Broker Leaderboard) shift down from
  `rowIndex 8` → `rowIndex 12`.

## Out of scope

- No changes to the existing "NDAs This Month" or "7-Day Stale Deals" tiles/reports.
- No new objects or fields (`NDA_Expiry_Date__c` already exists; staleness uses standard
  Last Activity / Created Date / IsConverted / Status).

## Delivery

Deploy report-type change, both reports, and the updated dashboard via `sf` to the scratch
org (DPEG-Acq-2). Note: this workspace is not a git repo, so the spec is not committed.
