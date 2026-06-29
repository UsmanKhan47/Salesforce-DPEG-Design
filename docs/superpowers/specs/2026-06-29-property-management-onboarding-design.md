# Property Management App — Onboarding (Design Spec)

**Date:** 2026-06-29
**Status:** Approved (design); pending implementation plan
**Target org:** DPEG-Acq-3 (default scratch org)
**Source design:** `Property Onboarding Tracker.dc.html` (Claude Design project `3e5c5349-0d33-4612-bb65-22fe6a314c6e`)

## 1. Goal

Add a third-line **Property Management** Lightning app to the DPEG org that tracks
post-acquisition property onboarding. It delivers the two screens from the design:

- **Screen 1 — Onboarding Home**: an App Page dashboard (KPIs, properties-in-onboarding
  table, portfolio progress, risk & alerts, time & SLA).
- **Screen 2 — Property Record**: an `Onboarding__c` record page with a native Path,
  highlights panel, and an interactive onboarding checklist driven by standard Tasks.

The build mirrors the existing **Transaction app** conventions: one custom object with
summary/rollup fields, per-component LWCs reading aggregates from an Apex controller,
checklist items as **standard Tasks** with custom fields, a `*RollupService`, a
permission set with explicit FLS, and an Apex seed script.

## 2. Key architectural decision

The checklist on Screen 2 (45 items in 7 categories) is task-level data. To honor the
"single new object" decision while still building a functional checklist, checklist items
are **standard Salesforce Tasks** (Activities) related to `Onboarding__c` — exactly the
pattern the Transaction app uses (`Task.Transaction_Deal__c` lookup + custom Task fields +
`TaskRollupService`). `Onboarding__c` remains the only new custom object.

The Screen 1 dashboard reads **summary fields on `Onboarding__c`** (the controller sums
them across active records), just as the Transaction dashboard reads `Transaction__c`
rollup fields. Only **Park North** is fanned out to real Tasks (for Screen 2); the other
five onboardings carry seeded summary numbers so the dashboard renders faithfully without
seeding 600+ Task rows. The rollup service recomputes a fanned-out onboarding's summary
fields from its Tasks so the two screens stay coherent for Park North.

## 3. Data model

### 3.1 `Onboarding__c` (new custom object)

Auto-number name (e.g. `ONB-{0000}`); "Allow Activities" enabled (Tasks relate via the
`Onboarding__c` lookup field below).

| Field | API name | Type | Notes / drives |
|---|---|---|---|
| Property Asset | `Property_Asset__c` | Lookup(`Property_Asset__c`) | parent; name/type/address highlights |
| Stage | `Stage__c` | Picklist (8 values, below) | native Path (Screen 2), Stage column (Screen 1) |
| Status | `Status__c` | Picklist: On Track / In Progress / At Risk / Blocked / Complete | Status pill, highlights badge |
| Start Date | `Start_Date__c` | Date | Start column, SLA age math |
| Target Completion | `Target_Completion_Date__c` | Date | Target column, "past target" math |
| Onboarding Lead | `Onboarding_Lead__c` | Text(120) | Owner column / Onboarding Lead highlight |
| Completion % | `Completion_Pct__c` | Number(3,0) | % Complete column, avg-%-complete KPI |
| Tasks Total | `Tasks_Total__c` | Number(4,0) | denominator |
| Tasks Complete | `Tasks_Complete__c` | Number(4,0) | portfolio breakdown, progress |
| Tasks In Progress | `Tasks_In_Progress__c` | Number(4,0) | portfolio breakdown |
| Tasks Not Started | `Tasks_Not_Started__c` | Number(4,0) | portfolio breakdown |
| Tasks Blocked | `Tasks_Blocked__c` | Number(4,0) | portfolio breakdown |
| Tasks N/A | `Tasks_NA__c` | Number(4,0) | portfolio breakdown |
| Open Tasks | `Tasks_Open__c` | Number(4,0) | Open column |
| Overdue Tasks | `Tasks_Overdue__c` | Number(4,0) | Overdue KPI, Risk & Alerts |
| Blocked (alert) | `Tasks_Blocked_Now__c` | Number(4,0) | Risk & Alerts "Blocked tasks" |
| Stalled > 7d | `Tasks_Stalled__c` | Number(4,0) | Risk & Alerts |
| Due next 7d | `Tasks_Due_7d__c` | Number(4,0) | Risk & Alerts |
| Days to Onboard | `Days_To_Onboard__c` | Number(4,0) | Time & SLA, avg time-to-onboard KPI |
| Age (days) | `Age_Days__c` | Number(4,0) | Time & SLA avg age |
| Oldest Open (days) | `Oldest_Open_Days__c` | Number(4,0) | Time & SLA oldest open |
| Past Target | `Past_Target__c` | Checkbox | Time & SLA "past target duration" count |

Cross-object formula helpers for the highlights panel (read-only):
`Property_Asset__r.Property_Name__c` (property name), `Property_Asset__r.Property_Type__c`
(type), and via the grandparent `Property_Asset__r.Property__r` →
`Address__c` / `Square_Footage__c` (address, gross sq ft). All exist on those objects, so
no extra storage fields are needed on `Onboarding__c`.

`Stage__c` picklist values (order = Path order):

1. Property Set up
2. Unit & Tenant Setup
3. Vendor & Expense Management
4. NNN Reconciliation & Billing Setup
5. Tenant Communication & Transition
6. Performance Tracking
7. Leasing
8. Onboarding Complete

### 3.2 Standard Task custom fields (checklist items)

| Field | API name | Type | Notes |
|---|---|---|---|
| Onboarding | `Onboarding__c` | Lookup(`Onboarding__c`) | parent link |
| Category | `Onboarding_Category__c` | Picklist | values 1–7 of `Stage__c` (the 7 groups) |
| Source System | `Source_System__c` | Picklist: Yardi / Excel / Salesforce / Email | system tag |
| Onboarding Status | `Onboarding_Status__c` | Picklist: Not Started / In Progress / Complete / Blocked / Not Applicable | richer than open/closed; drives item control + badges |
| Blocked Reason | `Blocked_Reason__c` | Text(255) | shown when status = Blocked |

Standard `ActivityDate` = due date. Owner is shown as a text label (Isha Patel / Fernando
Ruiz / Endya Williams / Accounting Queue) — **reuse the existing `Task.Task_Owner_Label__c`
custom field** (already present from the Transaction app) rather than adding a new one.

## 4. Components

### 4.1 Screen 1 — Onboarding Home (App Page flexipage `Onboarding_Home`)

Template `flexipage:appHomeTemplateHeaderTwoColumns`:
- **Header region:** `onboardingKpis`
- **Left/main region:** `onboardingPropertyList`
- **Right region:** `onboardingPortfolioProgress`, `onboardingRiskAlerts`, `onboardingTimeSla`

LWCs (all read `OnboardingController`, `@AuraEnabled(cacheable=true)`):

| LWC | Reuses | Renders |
|---|---|---|
| `onboardingKpis` | `c-stat-card` | 4 tiles: Properties in onboarding, Avg % complete, Overdue tasks, Avg time-to-onboard |
| `onboardingPropertyList` | `c-list-datatable` (pill + progress cell types) | "Properties In Onboarding (N)" table: Property (link), Start, Target, Stage, % Complete, Open, Status, Owner; "View All" → object list |
| `onboardingPortfolioProgress` | — | donut (avg %), Tasks Completed X/Y, stacked status breakdown (Complete / In Progress / Not Started / Blocked / N/A) |
| `onboardingRiskAlerts` | `c-onboarding-card-child` | 4 tiles: Overdue, Blocked, Stalled > 7d, Due next 7d |
| `onboardingTimeSla` | `c-onboarding-card-child` | 4 tiles: Avg days to onboard, Avg age of active, Past target duration, Oldest open (days) |

**Not built (per user):** `onboardingCategoryBars` (% Complete by Category),
`onboardingTrend` (Onboardings Completed per Month), `onboardingOwnerLoad` (Open Tasks by
Owner).

### 4.2 Screen 2 — Property Record (`Onboarding_Record_Page` flexipage)

- **Highlights:** native record highlights via a compact layout on `Onboarding__c`
  (Property name, Status badge, Completion %, Target Completion, Onboarding Lead,
  Tasks Complete). Edit/Clone/Delete are standard.
- **Path:** native Salesforce **Path** on `Stage__c` (8 stages), with "Mark Stage as
  Complete" (same pattern as the LOI / Development Review paths).
- **`onboardingChecklist`** (left): category group tiles (7) + filter chips
  (All / In Progress / Blocked / Not Applicable / Overdue) + item rows reading Tasks
  grouped by `Onboarding_Category__c`. Each row: status control, name (strike-through when
  Complete/N/A), source-system tag, status badge, blocked reason, owner avatar + due,
  notes/attachment icons, View link. Header: "Onboarding Checklist — X of Y complete (Z%)".
- **Sidebar:** `onboardingChecklistProgress` (overall %, X of Y) and
  `onboardingTaskProgressByCategory` (per-category done/total tiles — mirrors
  `transactionChecklistSummary`).

**Not built (per user):** `onboardingCriticalDates`.

## 5. Apex

- **`OnboardingController`** — DTOs mirroring `TransactionController`:
  - `getKpis()` → counts, avg completion %, Σ overdue, avg days-to-onboard.
  - `getOnboardings()` → table rows (one per active `Onboarding__c`).
  - `getPortfolio()` → tasks complete/total + status breakdown counts.
  - `getRiskAlerts()` → overdue / blocked / stalled / due-7d sums.
  - `getTimeSla()` → avg days, avg age, past-target count, oldest open.
  - `getChecklist(Id onboardingId)` → tasks grouped by category for Screen 2.
- **`OnboardingTaskRollupService`** — recomputes the `Onboarding__c` summary fields from
  its Tasks (`Onboarding_Status__c` distribution, overdue/blocked/stalled/due-7d, %). Runs
  for fanned-out onboardings (Park North). Mirrors `TaskRollupService`.

## 6. App, tabs, permission set

- **App** `Property_Management` — label "Property Management"; `View` action override on
  `Onboarding__c` → `Onboarding_Record_Page`; tabs: `Onboarding` (App Page = Screen 1),
  `Onboarding__c` (object), `standard-report`. (Optional later: an Onboarding Dashboard
  tab.)
- **Tab** `Onboarding` (CustomTab → flexipage `Onboarding_Home`) — the user's prerequisite
  tab that shows the first screen.
- **Permission set** `Property_Management_Access` — object perms on `Onboarding__c`,
  explicit **FLS** for every new `Onboarding__c` and Task field (sf-deployed fields get no
  FLS by default — see §8), Apex class access (`OnboardingController`,
  `OnboardingTaskRollupService`), tab visibility (`Onboarding`, `Onboarding__c`,
  `standard-Task`).

## 7. Seed data (`scripts/seed-onboarding.apex`)

Destructive-then-reseed on demo data, in the style of `seed-transactions.apex`.

### 7.1 Six onboardings (Screen 1 table + dashboard)

Stage column values map the mockup's short labels onto `Stage__c`:
*Tenant Transition → Tenant Communication & Transition; NNN & Billing → NNN
Reconciliation & Billing Setup; Unit & Tenant → Unit & Tenant Setup; Kickoff & Setup →
Property Set up.*

| Property | Start | Target | Stage | % | Open | Status | Lead |
|---|---|---|---|---|---|---|---|
| Apex Beset Mall | 05/02/2026 | 07/15/2026 | Tenant Communication & Transition | 84 | 7 | In Progress | Isha Patel |
| Park North | 04/18/2026 | 06/30/2026 | NNN Reconciliation & Billing Setup | 72 | 13 | In Progress | Fernando Ruiz |
| The Fountains | 06/01/2026 | 08/10/2026 | Unit & Tenant Setup | 41 | 22 | At Risk | Endya Williams |
| Riverside Commons | 03/22/2026 | 05/30/2026 | Tenant Communication & Transition | 95 | 3 | On Track | Isha Patel |
| Westgate Plaza | 05/20/2026 | 07/28/2026 | Unit & Tenant Setup | 58 | 15 | In Progress | Fernando Ruiz |
| Dollar Tree Center | 06/10/2026 | 08/22/2026 | Property Set up | 12 | 28 | Blocked | Endya Williams |

KPI targets: 6 properties; avg % complete 68%; overdue 14; avg time-to-onboard 24d.
Portfolio: 412 / 605 complete; breakdown Complete 412 / In Progress 96 / Not Started 61 /
Blocked 14 / N/A 22. Risk & Alerts: Overdue 14, Blocked 5, Stalled > 7d 8, Due next 7d 19.
Time & SLA: avg days to onboard 24, avg age 12, past target 2, oldest open 41. These are
seeded as per-record summary numbers that sum/average to the targets. (Demo numbers are
illustrative; minor cross-card inconsistencies in the mockup are reproduced as-is.)

Each onboarding's `Property_Asset__c` lookup points to a seeded/existing Property Asset.

### 7.2 Park North — 45 checklist Tasks (Screen 2)

Stage = NNN Reconciliation & Billing Setup; 32 of 45 complete (72%). Full list (name,
status, owner, due, system, flags):

**Property Set up (7, all Complete)**
1. Create new property record — Isha Patel — 04/20/2026 — Salesforce — notes
2. Enter basic property details (name, address, sq ft, type) — Isha Patel — 04/21/2026 — Salesforce — notes, file
3. Link bank accounts for rent & expenses — Fernando Ruiz — 04/24/2026 — Yardi — file
4. Set up property GL accounts — Accounting Queue — 04/25/2026 — Yardi
5. Configure property management settings — Isha Patel — 04/26/2026 — Yardi
6. Upload property photos & documents — Endya Williams — 04/28/2026 — Salesforce — file
7. Assign onboarding owner & timeline — Isha Patel — 04/22/2026 — Salesforce — notes

**Unit & Tenant Setup (14)**
1. Enter unit inventory (all units) — Complete — Fernando Ruiz — 05/02/2026 — Yardi — file
2. Enter tenant leases (all tenants) — Complete — Fernando Ruiz — 05/06/2026 — Yardi — notes, file
3. Verify lease terms vs abstracts — Complete — Endya Williams — 05/08/2026 — Excel — notes
4. Enter base rent schedules — Complete — Fernando Ruiz — 05/09/2026 — Yardi
5. Enter rent escalations / bumps — Complete — Fernando Ruiz — 05/12/2026 — Yardi
6. Set up recurring charges — Complete — Fernando Ruiz — 05/13/2026 — Yardi
7. Enter security deposits — Complete — Accounting Queue — 05/14/2026 — Yardi
8. Map tenants to units — Complete — Fernando Ruiz — 05/10/2026 — Yardi
9. Verify occupancy / vacancy status — Complete — Endya Williams — 05/15/2026 — Yardi
10. Reconcile rent roll to closing statement — Complete — Accounting Queue — 05/16/2026 — Excel — file
11. Set up CAM pro-rata share per tenant — In Progress — Fernando Ruiz — 07/03/2026 — Excel — notes
12. Enter lease options & renewals — In Progress — Endya Williams — 07/05/2026 — Excel
13. Import outstanding tenant balances (A/R) — Blocked — Accounting Queue — 06/18/2026 — Yardi — overdue, notes — reason "Blocked: awaiting seller closing statement"
14. Enter co-tenancy / exclusivity clauses — Not Started — Endya Williams — 07/10/2026 — Salesforce

**Vendor & Expense Management (8)**
1. Enter vendor list & W-9s — Complete — Accounting Queue — 05/20/2026 — Yardi — file
2. Set up recurring vendor payments — Complete — Accounting Queue — 05/22/2026 — Yardi
3. Map expense GL accounts — Complete — Accounting Queue — 05/23/2026 — Yardi
4. Enter service contracts (landscaping, security) — Complete — Endya Williams — 05/25/2026 — Excel — file
5. Enter insurance policies & premiums — Complete — Accounting Queue — 05/26/2026 — Yardi — file
6. Load historical operating expenses — Complete — Accounting Queue — 05/28/2026 — Excel
7. Set up utility accounts & transfers — In Progress — Endya Williams — 07/02/2026 — Email — notes
8. Set up lockbox services — Not Applicable — Accounting Queue — — Email — reason "tenants remit via ACH"

**NNN Reconciliation & Billing Setup (6)**
1. Define NNN charges (CAM, taxes, insurance) — Complete — Accounting Queue — 05/30/2026 — Yardi — notes
2. Enter prior-year reconciliation true-ups — Complete — Accounting Queue — 06/02/2026 — Excel — file
3. Set tenant billing schedules — Complete — Fernando Ruiz — 06/05/2026 — Yardi
4. Set up NNN recovery pools — In Progress — Accounting Queue — 06/22/2026 — Yardi — overdue, notes
5. Configure gross-up & recovery caps — Not Started — Accounting Queue — 06/15/2026 — Excel — overdue
6. Generate first NNN tenant statements — Not Started — Accounting Queue — 06/20/2026 — Yardi — overdue

**Tenant Communication & Transition (6)**
1. Send tenant welcome letters — Complete — Isha Patel — 05/04/2026 — Email — file
2. Notify tenants of new payment instructions — Complete — Isha Patel — 05/05/2026 — Email
3. Update tenant portal access — Complete — Endya Williams — 05/18/2026 — Salesforce
4. Schedule tenant transition meetings — Complete — Endya Williams — 05/20/2026 — Email — notes
5. Collect updated tenant contact info — Complete — Endya Williams — 05/22/2026 — Excel
6. Send estoppel confirmation follow-ups — Not Started — Isha Patel — 06/12/2026 — Email — overdue

**Performance Tracking (1)**
1. Track KPIs in Salesforce — In Progress — Isha Patel — 07/15/2026 — Salesforce — notes

**Leasing (3)**
1. Sign listing agreement with brokerage — Complete — Isha Patel — 06/01/2026 — Email — file
2. Set up available space listings — In Progress — Endya Williams — 07/08/2026 — Salesforce
3. Define leasing commission schedule — Not Started — Fernando Ruiz — 07/12/2026 — Excel

After insert, run `OnboardingTaskRollupService` for Park North so its summary fields match
(32/45, etc.).

## 8. Design tokens (LWC styling)

Match the mockup palette: navy `#1B3A6B`, teal `#1A7A6B`, amber `#D4940A`, red `#C0392B`,
green `#2E844A`, grey `#6B7280`, muted `#9CA3AF`. White cards, 12px radius, soft shadow
`0 2px 6px rgba(8,7,7,0.05)`, 1px `#E7E7E7` borders. Status colors — Complete teal,
In Progress amber, Not Started grey, Blocked red, N/A muted. System tags — Yardi navy,
Excel green, Salesforce blue, Email grey. Owner avatar colors — Isha navy, Fernando teal,
Endya amber, Accounting Queue grey. % bar color: ≥80 teal, ≥50 amber, else red.

## 9. Deploy considerations (known gotchas)

- **FLS:** sf-deployed custom fields get no field-level security; the permission set must
  grant read/edit on every new `Onboarding__c` and Task field, or LWC SOQL throws
  "No such column".
- **Source-tracking / CWD drift:** deploy from the repo root; watch the source-tracking
  batch behavior noted in prior Transaction/Disposition deploys.
- **BusinessProcess/Path:** native Path on a custom object needs the `Stage__c` picklist
  deployed first, then the PathAssistant metadata.
- **Apex coverage:** ship a test class for `OnboardingController` /
  `OnboardingTaskRollupService` to meet org coverage on deploy.
- Not a git repository — spec is not committed to version control.

## 10. Build phasing (review checkpoints)

1. **Foundation** — `Onboarding__c` + Task fields + `Property_Management` app +
   `Onboarding` tab + permission set. Deploy; verify the app, tab, and an empty
   `Onboarding__c` record open. (User prerequisites 1–4.)
2. **Screen 1** — `OnboardingController` + 5 LWCs + `Onboarding_Home` App Page +
   seed (6 onboardings). Verify against the mockup.
3. **Screen 2** — `Stage__c` Path + compact layout + `onboardingChecklist` +
   `OnboardingTaskRollupService` + Park North 45-task seed + sidebar LWCs +
   `Onboarding_Record_Page`. Verify against the mockup.

## 11. Out of scope (this build)

`onboardingCategoryBars`, `onboardingTrend`, `onboardingOwnerLoad` (Screen 1);
`onboardingCriticalDates` (Screen 2); a native Onboarding Dashboard tab; any change to the
existing Acquisition / Disposition / Transaction apps.
