# Lease Renewal Tracker — Design

**Date:** 2026-07-03
**Branch:** `feature/lease-renewal-tracker` (cut from `feature/lease-activity-tracker` HEAD)
**Prototype:** `docs/superpowers/specs/lease-renewal-tracker-prototype.html` (Claude Design, "Lease Renewal Tracker.dc.html")
**App:** Property Management (existing Lightning app)

## Purpose

Track lease renewal conversations from the moment a lease is flagged for renewal (by Yardi,
cosmetically — no real integration) to a signed amendment or a lost tenant. "The notepad Yardi
never gave you": an append-only timeline per renewal, non-responsive tenant flags, expiry
countdowns, and a native approval loop for rates that need owner sign-off.

Decisions locked with the user:
- Records created **manually + seed script** (no Yardi integration; "Synced from Yardi" chrome is cosmetic).
- Property linked via **`Property_Asset__c` lookup** (same as Broker Assignments / Onboarding); tenant + unit are text.
- Rate escalation uses a **native Approval Process** (like the LOI build).
- **Generic labels** — no "Nikil" in metadata (stage `Escalated for Approval`, card "Needs Approval").
- Salesforce-native chrome wherever possible: Kanban list view, Path, compact-layout highlights, detail sections, native dashboard.

## Objects

### `Lease_Renewal__c` — AutoNumber `LR-{0000}`, one record per renewal conversation

| Field | Type | Notes |
|---|---|---|
| `Tenant_Name__c` | Text(120), required | |
| `Property_Asset__c` | Lookup(Property_Asset__c), required | deleteConstraint Restrict not needed — default |
| `Property_Display_Name__c` | Formula (Text) | `Property_Asset__r.Name` (mirror Broker Assignment) |
| `Unit__c` | Text(60) | e.g. "Suite 120" |
| `Space_Sq_Ft__c` | Number(9,0) | |
| `Lease_Start__c` | Date | |
| `Lease_End__c` | Date, required | drives all expiry math |
| `Current_Rent__c` | Text(80) | display fidelity, e.g. "$26.00 / sq ft NNN" |
| `Renewal_Option__c` | Checkbox | pre-set renewal option exists on the lease |
| `Preset_Terms__c` | Text(255) | e.g. "3% annual escalation, 5-yr option" |
| `Proposed_Rate__c` | Number(6,2) | $/sq ft |
| `Option_Honored__c` | Checkbox | |
| `Approval_Status__c` | Picklist: `N/A` (default), `Pending`, `Approved`, `Rejected` | set by approval process; editable=false on layout not required — keep editable for admin fixes |
| `Stage__c` | Picklist, default `Not Yet Started`, **required=false** (avoid auto-inject-on-layout gotcha) | values below |
| `Status__c` | Picklist: `Active` (default), `Closed Won`, `Closed Lost` | flow-managed |
| `Handling_Person__c` | Lookup(User) | |
| `Last_Contact_Date__c` | Date | stamped by `addUpdate` (non-System methods) |
| `Renewed_Date__c` | Date | stamped by status-sync flow when Stage becomes `Renewed` (if blank) — mirrors `Signed_Date__c` pattern |
| `Days_To_Expiry__c` | Formula (Number) | `Lease_End__c - TODAY()` |
| `Days_Since_Contact__c` | Formula (Number) | blank-safe: `IF(ISBLANK(Last_Contact_Date__c), null, TODAY() - Last_Contact_Date__c)` |
| `Expiry_Health__c` | Formula (Text) | Active only: 🔴 ≤30d, 🟡 31–90d, 🟢 >90d; closed → "—" |
| `Non_Responsive__c` | Formula (Checkbox) | Active && Stage ∈ {Notice Sent, Awaiting Tenant Response, Negotiating, Escalated for Approval} && `Days_Since_Contact__c > 14` |

**14-day non-responsive threshold is hardcoded** in `Non_Responsive__c` (prototype default;
documented here as the single place to change it).

**`Stage__c` values (9, in path order):** `Not Yet Started`, `Notice Sent`,
`Awaiting Tenant Response`, `Negotiating`, `Escalated for Approval`, `Amendment Drafted`,
`Renewed`, `Not Renewing`, `Vacating`.

Stage accents (for LWC pills, from prototype): Not Yet Started `#7A9ED4`, Notice Sent `#4A71B8`,
Awaiting Tenant Response `#C88010`, Negotiating `#B8651A`, Escalated for Approval `#1A3464`,
Amendment Drafted `#A88020`, Renewed `#198A40`, Not Renewing `#8A8680`, Vacating `#6B6862`.

### `Renewal_Activity__c` — Master-Detail child, AutoNumber `RA-{0000}`

Mirrors `Lease_Activity__c`: `Lease_Renewal__c` (MD, relationship `Renewal_Activities`),
`Method__c` (Picklist: `Call`, `Email`, `Visit`, `Note`, `System`), `Details__c` (LongTextArea),
`Entry_Date__c` (DateTime). Append-only by convention (no delete UI; timeline never edits).

Method badge colors (LWC): Call `#1A4880`/`#EBF3FC`, Email `#7A4A00`/`#FDF5E6`,
Visit `#4A2A7A`/`#F3EEFB`, Note `#132850`/`#E8EFF7`, System `#5A5752`/`#EDEBE7`.

## Automation

1. **Record-triggered flow `Lease_Renewal_Status_Sync`** (before-save, create+update):
   Stage `Renewed` → Status `Closed Won` + stamp `Renewed_Date__c = $Flow.CurrentDate` if blank;
   Stage `Not Renewing` or `Vacating` → Status `Closed Lost`.
   (No reverse sync; reopening is a manual admin edit.)
2. **`LeaseRenewalController.addUpdate(renewalId, method, details)`**: inserts a
   `Renewal_Activity__c` (Entry_Date = now) and, when `method != 'System'`, updates parent
   `Last_Contact_Date__c = today`.
3. **Approval Process `Renewal_Rate_Approval`** (on `Lease_Renewal__c`, active):
   - Entry criteria: `Status__c = Active`.
   - Manual submission via quick action `Lease_Renewal__c.Submit_for_Approval` — headless LWC
     `renewalSubmitForApproval` calling `LeaseRenewalController.submitForApproval(recordId)`
     (Apex `Approval.ProcessSubmitRequest`), toast + `getRecordNotifyChange` — exact mirror of
     the Opportunity/LOI pattern (`Opportunity.Submit_for_Approval`). Added to the layout's
     platformActionList as `<actionType>QuickAction</actionType>`.
   - Initial submission actions: field updates → `Stage__c = 'Escalated for Approval'`, `Approval_Status__c = 'Pending'`.
   - Single step, assigned approver = the org admin user (same pattern as `LOI_Approval`); set `whenMultipleApprovers` (known deploy gotcha).
   - Final approval actions: `Approval_Status__c = 'Approved'`, `Stage__c = 'Negotiating'` (rate cleared to present to tenant), unlock.
   - Final rejection actions: `Approval_Status__c = 'Rejected'`, `Stage__c = 'Negotiating'`, unlock.
   - Recall: unlock only.

## Record page (`Lease_Renewal_Record_Page`, template `recordHomeWithSubheaderTemplateDesktop`)

- **Header:** `force:highlightsPanel`. Compact layout `Lease_Renewal_Compact`: Tenant_Name,
  Stage, Lease_End, Days_To_Expiry, Approval_Status.
- **Subheader:** native Path `Lease_Renewal_Path` on `Stage__c`, 9 steps, guidance text per stage
  (from prototype stage hints, e.g. Not Yet Started: "Expiry near, outreach not begun").
- **Main tabs:**
  - *Timeline* — `renewalTimeline` LWC (below).
  - *Related* — related lists: `Renewal_Activities__r`, Approval History
    (`RelatedApprovalHistoryList` token gotcha), `CombinedAttachments`.
- **Sidebar:** `force:detailPanel`.

**Layout `Lease_Renewal__c-Lease Renewal Layout`:**
- Section **Renewal**: col1 Tenant_Name (Required), Property_Asset (Required), Unit,
  Space_Sq_Ft; col2 Handling_Person, Last_Contact_Date, Days_Since_Contact (RO formula),
  Non_Responsive (RO formula).
- Section **Renewal Terms**: col1 Proposed_Rate, Option_Honored; col2 Approval_Status,
  Expiry_Health (RO formula).
- Section **Lease Snapshot**: col1 Lease_Start, Lease_End (Required), Current_Rent;
  col2 Renewal_Option, Preset_Terms, Days_To_Expiry (RO formula). ("Read-only · from Yardi" is
  prototype chrome; fields stay editable so manual creation works.)
- Section **System Information**: CreatedBy, LastModifiedBy.
- `platformActionList`: `Lease_Renewal__c.Submit_for_Approval` (QuickAction), Edit, Delete, Clone.
- **Stage and Status are NOT on the layout** (path + flow manage them; matches Lease Inquiry
  after user feedback). Both need perm-set FLS since required=false.

**`renewalTimeline` LWC** (clone of `leaseNegotiationLog` patterns):
- Card header "Timeline" with entry count and, when `Non_Responsive__c`, a red
  "Non-responsive · Nd silent" pill.
- Brand `lightning-button` "Log Follow-Up" opens an empty composer: Method combobox
  (Call/Email/Visit/Note — System reserved for seeds) + Outcome textarea, **both mandatory**;
  Save → `addUpdate` → refresh (uses `notifyRecordUpdateAvailable` so highlights/detail
  refresh too). Composer hidden when Status ≠ Active.
- Entries newest-first (`ORDER BY Entry_Date__c DESC, Name DESC` — frozen-clock test gotcha),
  each with method badge, author, date, text; "Latest" tag on first.

## App experience (Property Management app)

### App-home tab `Lease_Renewals` → flexipage `Lease_Renewals_Home` (`appHomeTemplateHeaderTwoColumns`)
- **Header region:** `renewalKpis` — 4 `c-stat-card`s, light icon colors (suite standard):
  Active Renewals `#7A9ED4`, Expiring ≤90 Days `#D8BE72`, Non-Responsive `#E58A8A`,
  Renewed (YTD) `#8FCBAA`.
- **Left (main):** `renewalList` — "Recent Renewals (N)" via `c-list-datatable`, 6 most recent:
  Tenant (link) / Property / Lease Expiry (date) / Days to Expiry (pill: red ≤30, amber ≤90,
  green else; "Renewed"/"Not renewing"/"Vacating" text when closed) / Stage (accent pill) /
  Last Contact ("Nd ago", red+bold when non-responsive, "No contact yet" when blank).
  Header action: New Renewal (NavigationMixin objectPage new). Footer: centered View All →
  `All_Renewals` list view (GenerateUrl pattern).
- **Right column:** `renewalNeedsApproval` — renewals with Approval_Status = Pending (tenant,
  property, days-left pill; empty state "All caught up."); `renewalAttention` — active renewals
  that are non-responsive OR ≤30d to expiry (tenant, reason label, silent/days pill).

### Object tab `Lease_Renewal__c` — list views
- `Renewal_Pipeline` — **native Kanban**: scope All lease renewals, no filters (closed stages
  appear as their own columns, matching the prototype board), grouped by `Stage__c`.
- `All_Renewals` (default), `Non_Responsive` (`Non_Responsive__c = true`),
  `Expiring_90_Days` (Status Active, `Days_To_Expiry__c ≤ 90`).

### Dashboard (native, existing Dashboards tab)
Folder: Leasing. New reports: `Active_Renewals_by_Stage` (bar by Stage, Active only),
`Non_Responsive_Renewals`, `Renewals_Needing_Approval`, `Renewals_Expiring_Soonest`
(sorted by Days_To_Expiry). New dashboard `Lease_Renewals` with those 4 components
(chart property is `reportName` + report DeveloperName — known gotcha; bar componentType `Bar`).

## Apex

**`LeaseRenewalController`** (with sharing, mirrors sibling controllers):
- `getHomeKpis()` → `{active, expiring90, nonResponsive, renewedYtd}`; `renewedYtd` = count of
  `Renewed_Date__c >= Jan 1 of current year` (field stamped by the status-sync flow — same
  mechanism as Lease Inquiry's Signed Leases (YTD)).
- `getRecentRenewals()` → 6 newest (CreatedDate DESC) row wrappers (id, tenant, property, unit,
  leaseEnd, daysToExpiry, stage, status, closed, lastContact, daysSinceContact, nonResponsive).
- `getNeedsApproval()` → Approval_Status Pending, Active, ordered by Days_To_Expiry asc.
- `getAttention()` → Active && (Non_Responsive__c = true || Days_To_Expiry__c <= 30), ordered
  by Days_To_Expiry asc.
- `getTimeline(renewalId)` → entries (newest-first) + context {stage, status, closed,
  nonResponsive, daysSinceContact, canLog}.
- `addUpdate(renewalId, method, details)` → as in Automation; validates non-blank details and
  method ∈ picklist.
- `submitForApproval(recordId)` → `Approval.ProcessSubmitRequest` into `Renewal_Rate_Approval`,
  returns a confirmation message (mirrors `OpportunityApprovalController.submitForApproval`).

**`LeaseRenewalControllerTest`** — @testSetup builds Property__c → Property_Asset__c + renewals
across stages/dates; asserts every controller method + flow status-sync + addUpdate stamping
(and System method NOT stamping). Content-based asserts, no timestamp-order asserts
(frozen-clock gotcha). Target: all tests pass, deploy with RunSpecifiedTests.

## Permissions & seed

- `Property_Management_Access` perm set: object CRUD for both objects; FLS for all non-required
  fields (incl. Stage__c, Status__c since required=false); tab visibility `Lease_Renewal__c`,
  `Lease_Renewals`; class access `LeaseRenewalController`.
- `scripts/seed-lease-renewals.apex` — idempotent (guard on existing LR records), ~12 renewals
  across the 6 seeded Property Assets covering every stage at least once, and exercising each
  alert condition: ≥2 non-responsive (last contact today−17 / today−22, in outreach stages),
  ≥2 Approval_Status Pending (one in `Escalated for Approval`, one earlier-stage), ≥1 each of
  Renewed / Not Renewing / Vacating (closed), ≥1 expiring ≤30d (red) and ≥1 in 31–90d (amber).
  **All dates as offsets from `Date.today()`** (lease ends spread across today+25 … today+180;
  contacts today−N) so alerts render on any demo date. Each seeded renewal gets 1–4 timeline
  entries, the first Method=System ("Lease flagged for renewal — …"), and closed ones get
  `Renewed_Date__c`/Status set consistently.

## Deploy / build gotchas to honor (from suite memory)

- `Set-Location F:\Acquisition-Design-Salesforce` before every `sf` command; avoid `2>&1`.
- Custom fields deployed via metadata get no FLS — perm set in the same deploy batch.
- One `componentInstance` per `itemInstances` in flexipages.
- Split deploys when app/tab reference new components; `-c` for spurious source-tracking conflicts.
- `Contact.Name` banned in formulas (n/a here); lookup fields can't have defaultValue.
- Path: `pathAssistant` metadata; picklist must exist first.
- Approval process: `whenMultipleApprovers` required; Approval History related list token
  `RelatedApprovalHistoryList`.
- Reports: chart `reportName` = DeveloperName; no `legendPosition` on bar charts.

## Out of scope

Real Yardi integration; admin UI for the 14-day threshold; drag-drop custom Kanban; prototype's
global header/search (Salesforce chrome); editing/deleting timeline entries; email alerts.
