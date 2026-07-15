# Work Order Tracker — Design

**Date:** 2026-07-03
**Branch:** `feature/work-order-tracker` (cut from `feature/lease-renewal-tracker` HEAD)
**Prototype:** `docs/superpowers/specs/work-order-tracker-prototype.html` (Claude Design, "Work Order Tracker.dc.html")
**App:** Property Management (existing Lightning app)
**Reference build:** Lease Renewal Tracker (`docs/superpowers/specs/2026-07-03-lease-renewal-tracker-design.md`) — same structure, minus approval + composer.

## Purpose

A **read-only mirror of Yardi maintenance work orders** with a Salesforce-side lens the property team lacks in Yardi: SLA breach / due-soon / on-track health by priority tier, an "Untouched" flag (nobody has acted), Escalations (Critical/High that breached), and a single Salesforce-only "Reason for Delay" flag so leadership sees *why* a ticket is stuck. Work orders are created/dispatched/closed in Yardi; this module never writes back — except `Delay_Reason__c`.

Decisions locked with the user:
- **Custom `Work_Order__c`** object (NOT standard WorkOrder/Entitlements) — consistent with the PM suite.
- **Faithful read-only:** records seeded as if synced; every field read-only on the layout EXCEPT `Delay_Reason__c`; activity history is a read-only seeded child list; **no create/edit UI, no composer, no approval**.
- **Formula-driven SLA** (not Entitlements/Milestones).
- **Generic labels** (no seeded person names in metadata; sample names only in the seed rows).
- Native chrome wherever possible: Path, compact-layout highlights, detail sections, native dashboard.

## Objects

### `Work_Order__c` — AutoNumber `WO-{0000}`

| Field | Type | Notes |
|---|---|---|
| `Subject__c` | Text(120), required | short title |
| `Description__c` | LongTextArea(4000) | tenant's words |
| `Category__c` | Picklist | HVAC / Plumbing / Electrical / Refrigeration / General / Doors & Locks / Landscaping |
| `Priority__c` | Picklist, default Medium | Critical / High / Medium / Low |
| `Status__c` | Picklist, default New, **required=false** | New / In Progress / On Hold / Completed / Closed |
| `Property_Asset__c` | Lookup(Property_Asset__c) | deleteConstraint SetNull |
| `Property_Display_Name__c` | Formula(Text) | `Property_Asset__r.Name` |
| `Unit__c` | Text(60) | |
| `Tenant_Name__c` | Text(120) | |
| `Vendor__c` | Text(120) | assigned vendor (from Yardi) |
| `Owner_User__c` | Lookup(User) | the PM/maintenance owner (named Owner_User__c to avoid the reserved standard OwnerId) |
| `Owner_Role__c` | Picklist | Property Manager / Maintenance |
| `Reported_Date__c` | DateTime, required | the "synced from Yardi" origin timestamp; SLA math anchors here (NOT CreatedDate — seed sets offsets) |
| `First_Touched_Date__c` | DateTime | blank ⇒ Untouched |
| `Completed_Date__c` | DateTime | set when Completed/Closed |
| `Delay_Reason__c` | Picklist: `—`(default) / `Vendor delay` / `Tenant unresponsive` / `Other` | **the only editable field** |
| `SLA_Target_Hours__c` | Formula(Number) | `CASE(Priority__c,"Critical",24,"High",48,"Medium",168,"Low",360,168)` |
| `SLA_Due_Date__c` | Formula(DateTime) | `Reported_Date__c + (SLA_Target_Hours__c/24)` |
| `Hours_Open__c` | Formula(Number) | open: `(NOW()-Reported_Date__c)*24`; resolved: `(Completed_Date__c-Reported_Date__c)*24` |
| `Is_Open__c` | Formula(Checkbox) | `NOT(ISPICKVAL(Status__c,"Completed") \|\| ISPICKVAL(Status__c,"Closed"))` |
| `SLA_Health__c` | Formula(Text) | resolved → "🟢 Resolved"; else past due → "🔴 Breached"; else remaining ≤ 30% window → "🟡 Due Soon"; else "🟢 On Track" |
| `SLA_Breached__c` | Formula(Checkbox) | `Is_Open__c && NOW() > SLA_Due_Date__c` |
| `Untouched__c` | Formula(Checkbox) | `Is_Open__c && ISBLANK(First_Touched_Date__c)` |
| `Is_Escalation__c` | Formula(Checkbox) | `SLA_Breached__c && (Critical OR High)` |

**Due-soon window = 30%**, hardcoded ONLY in `SLA_Health__c` (prototype working assumption; documented single point of change).
SLA tiers (confirmed, not assumptions): Critical 24h, High 48h, Medium 168h (7d), Low 360h (15d).

Priority accents (LWC pills, from prototype): Critical `#B01818`/`#FDECEC`, High `#9A4B00`/`#FDF2E7`, Medium `#8B6800`/`#FBF6EB`, Low `#5A5752`/`#EDEBE7`.
Status accents: New `#4A71B8`, In Progress `#1A3464`, On Hold `#C88010`, Completed `#198A40`, Closed `#8A8680`.
SLA pill tones: Breached red `#8B1A1A`/`#FDF0F0`; Due Soon amber `#7A4A00`/`#FDF5E6`; On Track / Resolved green `#146830`/`#EBF9F1`.

### `Work_Order_Activity__c` — MD child, AutoNumber `WOA-{0000}`

Read-only synced history (append-only by convention; **no UI to create**). Fields: `Work_Order__c` (MD, relationship `Work_Order_Activities`), `Kind__c` (Picklist: Sync/Status/Vendor/Note/Flag), `Detail__c` (LongTextArea), `Entry_Date__c` (DateTime), `Actor__c` (Text — "Yardi" or a person). sharingModel ControlledByParent.

Kind badge colors (LWC): Sync `#5A5752`/`#EDEBE7`, Status `#1A3464`/`#E8EFF7`, Vendor `#9A4B00`/`#FDF2E7`, Note `#132850`/`#E8EFF7`, Flag `#1A4880`/`#EBF3FC`.

## Automation

**Record-triggered flow `Work_Order_Touch_Sync`** (before-save, create+update) — keeps the derived timestamps honest so the Untouched/Resolved formulas are correct even though data is "synced":
1. If `Status__c` != New AND `First_Touched_Date__c` is blank → set `First_Touched_Date__c = $Flow.CurrentDateTime`.
2. If (`Status__c` = Completed OR Closed) AND `Completed_Date__c` is blank → set `Completed_Date__c = $Flow.CurrentDateTime`.

No approval process. No composer. No status cascade beyond the two stamps above.

## Record page (`Work_Order_Record_Page`, template `recordHomeWithSubheaderTemplateDesktop`)

- **Header:** `force:highlightsPanel`. Compact layout `Work_Order_Compact`: Subject, Priority, Status, SLA_Health, SLA_Due_Date.
- **Subheader:** native Path `Work_Order_Path` on `Status__c` (New → In Progress → Completed → Closed; On Hold present as a step), guidance text per status. (Path is the requested native status visual; in a real integration Yardi drives status — here seed/admin sets it.)
- **Main tabs:**
  - *Activity* — `workOrderTimeline` LWC (read-only; below).
  - *Related* — related lists `Work_Order_Activities__r`, `CombinedAttachments`.
- **Sidebar:** `force:detailPanel`.

**Layout `Work_Order__c-Work Order Layout`** (every field `Readonly` EXCEPT `Delay_Reason__c`):
- **Work Order**: Subject, Description, Category, Priority, Property_Asset, Unit, Tenant_Name, Vendor, Owner_User, Owner_Role (all Readonly).
- **SLA & Aging**: Reported_Date (Readonly), First_Touched_Date (Readonly), Completed_Date (Readonly), SLA_Due_Date (Readonly), SLA_Health (Readonly), Hours_Open (Readonly), Untouched (Readonly).
- **Reason for Delay**: `Delay_Reason__c` (**Edit** — the only editable item; section note "Salesforce-only — never written back to Yardi").
- **System Information**: CreatedBy, LastModifiedBy (Readonly).
- **Status is NOT on the layout** (Path + highlights manage it). Status/Priority/etc. read-only means the record is a faithful mirror. `Status__c` needs perm-set FLS (required=false).
- `platformActionList`: Edit, Delete (no Submit/Clone; read-only mirror).

**`workOrderTimeline` LWC** (read-only — clone of renewalTimeline's *display* half, NO composer):
- Card header "Activity & Status History" with entry count and, when `Untouched__c`, a purple "Untouched" pill.
- Entries newest-first (`ORDER BY Entry_Date__c DESC NULLS LAST, Name DESC` — frozen-clock gotcha), each with Kind badge, actor, date, detail; "Latest" tag on the first. Footer note "History arrives with the nightly Yardi sync." No Log button, no textarea.

## App experience (Property Management app)

### App-home tab `Work_Orders` → flexipage `Work_Orders_Home` (`appHomeTemplateHeaderTwoColumns`)
- **Header region:** `workOrderKpis` — 4 `c-stat-card`s (light icon colors): Open Work Orders `#7A9ED4`, Breached SLA `#E58A8A`, Due Soon `#D8BE72`, Untouched `#B39DDB`.
- **Left (main):** `workOrderList` — "Open Work Orders (N)" via `c-list-datatable`, 6 rows: Subject (link) / Property·Unit / Priority (pill) / Status (accent pill) / SLA (health pill) / Days Open. **No New button** (read-only). Footer: centered View All → `My_Open_Work_Orders` list view (GenerateUrl pattern).
- **Right column:** `workOrderEscalations` — `Is_Escalation__c` = true, most-overdue first (subject, property, priority pill, hours-over pill; empty state "Nothing is on fire."); `workOrderUntouched` — `Untouched__c` = true (subject, property·priority sub, SLA pill; empty state "Everything has been picked up.").

### Object tab `Work_Order__c` — list views
- `My_Open_Work_Orders` (default) — `Is_Open__c` = true.
- `Escalations` — `Is_Escalation__c` = true.
- `Breached_SLA` — `SLA_Breached__c` = true.
- `Untouched` — `Untouched__c` = true.
- `All_Work_Orders`.

### Dashboard (native)
New folder **Work_Orders** (report folder + dashboard folder). Reports (`reportType CustomEntity$Work_Order__c`): `Open_Work_Orders_by_Priority` (Summary, Bar, Is_Open__c=true), `SLA_Breaches` (Tabular, SLA_Breached__c=1), `Work_Orders_by_Category` (Summary by Category, Is_Open__c=true), `Untouched_Work_Orders` (Tabular, Untouched__c=1). Dashboard `Work_Order_Health`: 3 metrics (Open / Breached SLA / Untouched) + Open-by-Priority Bar + By-Category Bar. (Dashboard bar `componentType Bar` + `chartAxisRange`; chart `reportName` = DeveloperName — known gotchas.)

## Apex

**`WorkOrderController`** (with sharing, read-only — mirrors sibling controllers' read methods, NO mutations):
- `getHomeKpis()` → `{open, breached, dueSoon, untouched}` (Integers).
- `getRecentWorkOrders()` → 6 open WOs (ORDER BY Reported_Date__c DESC) as Row wrappers {id, subject, property, unit, priority, status, slaHealth, hoursOpen, breached, untouched, isOpen}.
- `getEscalations()` → `Is_Escalation__c`=true, ORDER BY SLA_Due_Date__c ASC.
- `getUntouched()` → `Untouched__c`=true, ORDER BY Reported_Date__c ASC.
- `getActivity(workOrderId)` → `{entries:[{id, kind, detail, actor, entryDate}], untouched}` newest-first.

**`WorkOrderControllerTest`** — @testSetup builds Property__c → Property_Asset__c + work orders spanning priorities/statuses/dates (breached, due-soon, untouched, resolved) + activities; asserts each method + the Touch-Sync flow (first-touch + completed stamps). Content-based asserts (no timestamp-order asserts — frozen-clock gotcha). Deploy with RunSpecifiedTests.

## Permissions & seed

- `Property_Management_Access` perm set: object CRUD for both objects (create needed for the seed to run under a non-admin too, though seed runs as admin); FLS for all non-required, non-formula fields (incl. Status__c since required=false; `Delay_Reason__c` editable=true; the read-only-on-layout fields still get FLS readable/editable so the app can query them); formula fields readable-only; tab visibility `Work_Order__c`, `Work_Orders`; class access `WorkOrderController`.
- `scripts/seed-work-orders.apex` — idempotent (guard on existing WO records), ~15 work orders across the 6 seeded Property Assets covering: every Priority; every Status incl. On Hold; ≥2 Escalations (Critical/High past due, open); ≥2 more Breached at Medium/Low; ≥2 Untouched (New, `First_Touched_Date__c` null, inside SLA); ≥3 with `Delay_Reason__c` set; several Completed/Closed for the by-category averages. **All dates offset from `Datetime.now()`** (e.g. Critical reported now−30h so it's breached; a New Low reported now−2h so it's on-track+untouched). Each WO gets 1–5 `Work_Order_Activity__c` entries, first `Kind=Sync` ("Work order created…"), later Status/Vendor/Note/Flag entries mirroring the prototype histories.

## Deploy / build gotchas to honor (from suite memory + Lease Renewal)

- `Set-Location F:\Acquisition-Design-Salesforce` before every `sf` command; avoid `2>&1`.
- `formulaTreatBlanksAs` valid enum is **`BlankAsBlank`** (singular).
- Custom fields deployed via metadata get no FLS — perm set in the same deploy batch.
- Required fields (`Subject__c`, `Reported_Date__c`) get NO `fieldPermissions`; nor does the MD field.
- One `componentInstance` per `itemInstances` in flexipages; RecordPage targetConfig rejects `objects=`.
- Split deploys when app/tab reference new components; `-c` for spurious source-tracking conflicts (verified pattern this session).
- Reports: `reportType CustomEntity$Work_Order__c`; dashboard bar `componentType Bar` (not HorizontalBar) + `chartAxisRange`; report `<sortColumn>`/`<sortOrder>` at end of Report element.
- Apex frozen-clock: assert content, not row order; `ORDER BY Entry_Date__c DESC NULLS LAST, Name DESC`.
- `Owner`/`OwnerId` and `when`/`system` are reserved — hence `Owner_User__c`.

## Out of scope

Real Yardi integration; standard WorkOrder object / Entitlement Management / Milestones; creating or editing work orders in the UI (read-only mirror; seed stands in for the nightly sync); an activity composer; approval; the prototype's global header/search chrome; email alerts.
