# Rent Roll Tab on Property Asset — Design

- **Date:** 2026-07-10
- **Branch:** `feature/rent-roll` (off `main`)
- **Source design:** Claude Design project "Broker Tracking System Prototype" → `Rent Roll.dc.html` (Rent Roll tab content only)
- **Status:** Approved approach — real child objects + seeded dummy data; Yardi integration later

## Purpose

Show a property's rent roll (units, tenants, rents, lease terms, NNN charges, rent step schedules) on the Property Asset record page, in a dedicated **Rent Roll** tab. Data is a read-only mirror of Yardi Voyager: dummy records now, nightly Yardi upsert later. Salesforce never writes back.

## Scope / Non-goals

- **In scope:** two new child objects, one Apex controller + test, one LWC, one new Property Asset record page flexipage, perm set FLS, seed script.
- **Out of scope:** the mock's global header/record header/tab chrome (Salesforce provides these); any Yardi integration plumbing; changes to any other page, app, or object; edit UI of any kind (mirror is read-only).
- The existing `Vacant_Area__c` field on `Property_Asset__c` (used by Sell Meter) is untouched; rent-roll occupancy is computed independently from units.

## Data model

Read-only Yardi-mirror philosophy (same as Work Order Tracker): store what Yardi sends, derive nothing that Yardi already provides. All NNN amounts are stored, not formulas.

### `Unit__c` — label "Unit", plural "Units", auto-number `UNIT-{0000}`

| Field | Type | Notes |
|---|---|---|
| `Property_Asset__c` | Master-Detail(Property_Asset__c) | relationship name `Units` |
| `Suite_Number__c` | Text(20) | nullable — a vacant unit can have no suite yet |
| `Tenant_Name__c` | Text(120) | text, not Contact lookup — Yardi owns tenant identity |
| `Square_Feet__c` | Number(18,0) | |
| `Status__c` | Picklist: Occupied, Vacant (default Vacant) | |
| `Lease_Start__c` / `Lease_End__c` | Date | null for vacant |
| `Current_Monthly_Rent__c` | Currency(16,2) | |
| `Current_Rent_PSF__c` | Currency(16,2) | annualized $/SF |
| `Asking_Rent_PSF__c` | Currency(16,2) | vacant units only |
| `Estimated_NNN_PSF__c` | Currency(16,2) | vacant units only |
| `NNN_Property_Tax__c` | Currency(16,2) | monthly |
| `NNN_Insurance__c` | Currency(16,2) | monthly |
| `NNN_CAM__c` | Currency(16,2) | monthly |
| `NNN_Monthly_Total__c` | Currency(16,2) | monthly, stored (mirrored) |
| `NNN_PSF__c` | Currency(16,2) | annualized $/SF, stored (mirrored) |
| `Yardi_Unit_Id__c` | Text(50), External ID, unique (case-insensitive) | future upsert key |

### `Rent_Step__c` — label "Rent Step", plural "Rent Steps", auto-number `RS-{0000}`

| Field | Type | Notes |
|---|---|---|
| `Unit__c` | Master-Detail(Unit__c) | relationship name `Rent_Steps` |
| `Period_Start__c` / `Period_End__c` | Date | nullable |
| `Period_Label__c` | Text(80) | display override for fuzzy periods ("Years 6–10", "Not yet defined") |
| `Monthly_Rent__c` | Currency(16,2) | null → row renders italic note instead |
| `Rent_PSF__c` | Currency(16,2) | |
| `Type__c` | Picklist: Current Term, Renewal Option | |
| `Note__c` | Text(255) | e.g. "3% annual bumps" |
| `Sort_Order__c` | Number(4,0) | display order within unit |

No external ID on steps: on sync, a unit's steps are wholesale replaced.

## Apex

`RentRollController` (`with sharing`):

- `@AuraEnabled(cacheable=true) static RentRollDTO getRentRoll(Id propertyAssetId)`
- One SOQL query on `Unit__c` with a `Rent_Steps__r` sub-select (ordered by `Sort_Order__c`), filtered by `Property_Asset__c = :propertyAssetId`.
- Returns DTO:
  - `summary`: `totalSqFt`, `occupiedSqFt`, `vacantSqFt`, `occupiedPct`, `vacantPct`, `monthlyRent` (sum of occupied `Current_Monthly_Rent__c`), `occupiedCount`, `vacantCount`, `blendedPsf` (= monthlyRent × 12 ÷ occupiedSqFt; null when no occupied sq ft), `nnnMonthlyTotal` (sum), `lastSynced` (max `LastModifiedDate` across units; null when no units).
  - `units[]`: raw field values + nested `steps[]`.
- Percentages and blended PSF are computed server-side; all display formatting happens client-side.
- `RentRollControllerTest`: happy path (mixed occupied/vacant, summary math incl. blendedPsf), empty property (zero units → empty list, null summary aggregates), null-heavy vacant unit (no suite, no rents).

## LWC `rentRoll`

Single component. `target: lightning__RecordPage`; `@api recordId`; wires `getRentRoll`.

Reproduces the design's Rent Roll tab content:

1. **Summary bar** — property name/address line omitted (redundant with the record header); Total sq ft; Occupied sq ft + %; Vacant sq ft + %; Current monthly rent + "N occupied units"; two-tone occupancy progress bar (navy occupied / amber vacant); "Read-only — mirrored from Yardi Voyager 7S" pill; "Last synced: <formatted datetime>".
2. **Units table** — columns: Suite #, Tenant, Sq Ft, Monthly Rent, Rent/Sq Ft, Lease Start → End, NNN Monthly, chevron.
   - **Sorting:** Suite (numeric), Sq Ft, Monthly Rent, Lease End are sortable, three-state cycle (asc → desc → off), null/vacant values always sort last. Client-side.
   - **Expiry dot** next to the lease term (occupied units with a lease end only): months-out = days ÷ 30.44; > 12 green, 6–12 amber, < 6 red; `title` tooltip "Lease ends <date> — about N months out". Legend in the card header.
   - **Vacant rows:** amber background, italic "— Vacant —", Rent/Sq Ft shows `$X.XX asking` when `Asking_Rent_PSF__c` set, NNN shows `$X.XX/SF est.` when `Estimated_NNN_PSF__c` set, otherwise "—". Not expandable.
   - **Expandable occupied rows:** click toggles a full-width panel (multi-expand allowed; first row not pre-expanded): NNN breakdown chips (Property Tax / Insurance / CAM / Total · $PSF/SF) + rent step schedule table (Period, Monthly Rent, $/Sq Ft, Type tag navy "Current Term" / gold "Renewal Option"). Period displays `Period_Label__c` if set, else `M/D/YYYY – M/D/YYYY`. A step is **Active now** (gold row highlight + badge) when both dates are present and today falls within. Null rent renders `Note__c` (or "—") in italics.
   - **NNN tooltip:** hovering the NNN Monthly value on an occupied unit shows a fixed-position dark tooltip with the Tax/Insurance/CAM/Total breakdown (escapes table clipping, like the mock).
   - **Totals footer:** "N occupied · N vacant", total sq ft with occ/vac split, total monthly rent, blended $/SF, total NNN monthly.
3. **Footnote** — "Rent roll data is created and maintained in Yardi only. This view refreshes with the nightly sync — Salesforce never writes back."
4. **States** — empty (no units): card with a short "No rent roll data — units sync from Yardi" message; wire error: inline error card with the message; never blocks the rest of the record page.

Styling: custom component CSS reproducing the design (navy/gold/success/warning palette as CSS custom properties, monospace stack for numerics, SLDS base font). Custom `<table>` markup, not `lightning-datatable` (expandable rows + custom cells).

## Flexipage

New `Property_Asset_Record_Page` (Property_Asset__c record page): header region with highlights panel; tabs **Details** (record detail), **Related** (related lists), **Rent Roll** (the `rentRoll` LWC, full width). Assigned org default via a `View` action override with `type=Flexipage` (object-level, so it applies in Disposition and Property Management apps alike); if the object-level override is rejected on deploy, fall back to app-level actionOverrides on both apps.

## Security

`Property_Management_Access` perm set gains: object **Read** on `Unit__c` and `Rent_Step__c` (no create/edit/delete — Yardi is the writer), field read on every new field. This also covers the metadata-FLS gotcha (fields deployed via `sf` get no FLS until a perm set grants it).

## Seed data

`scripts/apex/seed_rent_roll.apex`: idempotent — finds Property Asset named "Cypresswood Retail" (creates it if missing), deletes its existing units, inserts the design's exact data (all units get fake `Yardi_Unit_Id__c` values `Y-CW-###`):

| Suite | Tenant | SqFt | Status | Lease | Rent/mo | PSF | NNN tax/ins/CAM = total (PSF) |
|---|---|---|---|---|---|---|---|
| 200 | Yei Dental | 2,600 | Occupied | 12/18/2020 → 12/31/2030 | 6,196.67 | 28.60 | 704.15 / 270.83 / 325.00 = 1,299.98 (6.00) |
| 103 | Vape City | 990 | Occupied | 1/1/2026 → 1/1/2031 | 2,640.00 | 32.00 | 170.00 / 140.00 / 350.00 = 660.00 (8.00) |
| 100 | Premiumrx Pharmacy | 1,200 | Occupied | 3/6/2023 → 9/30/2028 | 2,400.00 | 24.00 | 300.00 / 50.00 / 350.00 = 700.00 (7.00) |
| 101 | Cell Phone Store | 750 | Occupied | 1/1/2026 → 12/31/2028 | 1,312.50 | 21.00 | 250.00 / 40.00 / 210.00 = 500.00 (8.00) |
| 210 | — | 1,235 | Vacant | — | — | — | — |
| — | — | 2,241 | Vacant | — | — (asking PSF 27.00) | — | est. NNN PSF 7.25 |

Rent step schedules (per unit, `Sort_Order__c` ascending):

- **Suite 200:** 1/1/2023–12/31/2025 $5,633.33 ($26.00) Current Term; 1/1/2026–12/31/2030 $6,196.67 ($28.60) Current Term; 1/1/2031–12/31/2035 $6,816.33 ($31.46) Renewal Option; 1/1/2036–12/31/2040 $7,498.83 ($34.61) Renewal Option.
- **Suite 103:** five annual Current Term steps 1/1/2026–12/31/2030: $2,640.00 ($32.00), $2,719.20 ($32.96), $2,800.88 ($33.95), $2,885.03 ($34.97), $2,971.65 ($36.02); then two Renewal Option steps (1/1/2031–12/31/2035, 1/1/2036–12/31/2040) with null rent and note "3% annual bumps".
- **Suite 100:** 12/1/2023–10/31/2024 $2,200.00 ($22.00); 11/1/2024–10/31/2025 $2,300.00 ($23.00); 11/1/2025–10/31/2028 $2,400.00 ($24.00) — all Current Term; label-only Renewal Options "Years 6–10" $2,700.00 ($27.00) and "Years 11–15" $3,000.00 ($30.00).
- **Suite 101:** three annual Current Term steps 1/1/2026–12/31/2028: $1,312.50 ($21.00), $1,338.75 ($21.42), $1,365.53 ($21.82); label-only Renewal Option "Not yet defined", null rent, note "2 five-year options at Fair Market Rent".

## Testing & verification

- Apex unit tests (above) pass in the scratch org.
- Deploy to the default scratch org, run the seed script, open the Cypresswood Retail Property Asset → Rent Roll tab, and visually compare against the mock (summary numbers: 9,016 total / 5,540 occ 61.4% / 3,476 vac 38.6% / $12,549.17 rent / $27.18 blended / $3,159.98 NNN).
- User does the final visual sign-off (same as prior modules).

## Future Yardi integration (context only, not built now)

Nightly job upserts `Unit__c` by `Yardi_Unit_Id__c`, wholesale-replaces each unit's `Rent_Step__c` children, and deletes units no longer in Yardi. The LWC and controller need no changes.
