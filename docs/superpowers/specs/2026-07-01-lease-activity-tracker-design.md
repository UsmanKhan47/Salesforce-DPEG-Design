# Lease Activity Tracker — Design of Record

**App:** Property Management (Leasing) — sits alongside Broker Tracker.
**Source prototype:** `docs/superpowers/specs/lease-activity-tracker-prototype.html`
(Claude Design "Lease Activity Tracker.dc.html").

**Goal:** Track every leasing inquiry from a broker-introduced prospect through
signed lease, as a native Salesforce pipeline — Kanban board, stage Path,
highlights panel, detail sections — with a custom append-only negotiation log.

## Approved decisions (2026-07-01)
1. Objects: **`Lease_Inquiry__c`** (deal) + **`Lease_Activity__c`** (log entry).
2. People: **generic roles + User lookup** — Ball in Court is a role picklist
   (Landlord / Tenant / Legal / Construction / Broker); Handling Person is a User lookup.
3. Dashboard: **native Reports + Dashboard** (not LWC).
4. Kanban: **native Kanban list view** grouped by Stage (drag-to-advance);
   an `Aging__c` 🟢/🟡/🔴 formula keeps the aging signal visible on cards.

## Native vs custom
| Prototype screen | Native translation |
|---|---|
| Pipeline Board (Kanban) | Native Kanban list view on `Lease_Inquiry__c` grouped by `Stage__c` |
| Stage progression | Native **Path** (`Lease_Inquiry_Path`) on `Stage__c` |
| Ball-in-court header | Native highlights panel via compact layout |
| Inquiry record + Locked LOI terms | Native record-page detail sections (LOI terms gated by Stage) |
| Negotiation history + Add Update composer | **Custom LWC** `leaseNegotiationLog` + `LeaseInquiryController` |
| KPIs + Dashboard | Native reports + `Lease_Pipeline` dashboard (embedded on an app page) |
| New Inquiry form | Native New action (field defaults) + record-triggered Flow seeds first log entry |

## Data model

### `Lease_Inquiry__c` — AutoNumber `LI-{0000}`, records never deleted
| Field | Type | Notes |
|---|---|---|
| `Tenant_Name__c` | Text(120), required | prospect/tenant |
| `Broker__c` | Lookup(Contact) | broker who introduced them |
| `Property_Asset__c` | Lookup(Property_Asset__c) | the space |
| `Space_Required__c` | Number(9,0) | sq ft |
| `Stage__c` | Picklist, required, default *Inquiry Received* | Inquiry Received · LOI Received · LOI Negotiation · LOI Signed · Lease Drafting · Lease Signed |
| `Ball_In_Court__c` | Picklist, default *Landlord* | Landlord · Tenant · Legal · Construction · Broker |
| `Handling_Person__c` | Lookup(User) | deal owner/handler |
| `Status__c` | Picklist, default *Active* | Active · Closed Won · Closed Lost |
| `LOI_Date__c` | Date | |
| `Stage_Start_Date__c` | Date | reset by Flow whenever Stage changes; drives aging |
| `Days_In_Stage__c` | Formula(Number) | 0 if closed, else `TODAY() - Stage_Start_Date__c` |
| `Aging__c` | Formula(Text) | closed→"🟢 Signed"; >14→"🔴 Overdue"; >7→"🟡 Aging"; else "🟢 On track" |
| `Base_Rent__c` | Text(60) | locked LOI term, e.g. "$34.00 / sq ft NNN" |
| `Lease_Term__c` | Text(30) | e.g. "7 years" |
| `Free_Rent__c` | Text(30) | e.g. "4 months" |
| `TI_Allowance__c` | Text(30) | e.g. "$45.00 / sq ft" |
| `Commencement_Date__c` | Date | |
| `Initial_Notes__c` | LongText(2000) | consumed by the open-log Flow, then informational |
| `Broker_Name__c` | Formula(Text) | `Broker__r.Name` |
| `Broker_Firm__c` | Formula(Text) | `Broker__r.Broker_Firm__c` |
| `Property_Name__c` | Formula(Text) | `Property_Asset__r.Name` |

### `Lease_Activity__c` — AutoNumber `LA-{0000}`, append-only log entry
| Field | Type | Notes |
|---|---|---|
| `Lease_Inquiry__c` | Master-Detail(Lease_Inquiry__c) | parent deal |
| `Entry_Date__c` | DateTime, default NOW() | |
| `Logged_By__c` | Lookup(User), default $User.Id | who logged it |
| `Ball_In_Court__c` | Picklist | who it was handed to |
| `Details__c` | LongText(4000), required | the update text |

## Automation (record-triggered Flows)
- **`Lease_Inquiry_Stage_Timer`** — before-save, create+update: when `ISNEW()` OR
  `ISCHANGED(Stage__c)`, set `Stage_Start_Date__c = TODAY()`. Single source of truth
  for the days-in-stage timer (covers Path, Kanban drag, and the LWC).
- **`Lease_Inquiry_Open_Log`** — after-save, create only: insert one `Lease_Activity__c`
  (`Details__c` = `Initial_Notes__c` or a fallback line, `Ball_In_Court__c` = the
  inquiry's ball, `Logged_By__c` = CreatedById).

## LWC `leaseNegotiationLog` (record page)
- Append-only timeline of `Lease_Activity__c` children, newest first.
- "Add Update" composer: Details textarea, Ball-in-court select, optional
  "Advance to next stage → <next>" checkbox.
- Save → `LeaseInquiryController.addUpdate(inquiryId, details, ball, advance)`:
  insert `Lease_Activity__c`; set parent `Ball_In_Court__c`; if advance, set
  `Stage__c` to next stage (timer reset handled by the Flow).
  `notifyRecordUpdateAvailable` refreshes Path + highlights.
- Apex `getLog(inquiryId)` returns entries + whether a next stage exists.

## App wiring
- Object tab `Lease_Inquiry__c` → the Kanban board + list views (All, Active Pipeline, My Open).
- App page `Lease_Pipeline` (flexipage) with the native Dashboard component → added as a tab.
- Both tabs added to `Property_Management.app`.
- `Property_Management_Access` perm set: object CRUD, FLS for all new fields, tab visibility.

## Build order (each chunk = its own deploy)
1. Objects + fields + picklists (`Lease_Inquiry__c`, `Lease_Activity__c`) + perm set FLS.
2. Path + compact layout + page layouts.
3. Flows (stage timer, open log).
4. Apex `LeaseInquiryController` + test; LWC `leaseNegotiationLog`.
5. Record page flexipage (Path, highlights, detail sections, LWC) + object View override.
6. List views (incl. Kanban-ready Active Pipeline) + object tab.
7. Reports + `Lease_Pipeline` dashboard + app page + tabs + app wiring.
8. Seed script (sample inquiries mirroring the prototype) for demo.
