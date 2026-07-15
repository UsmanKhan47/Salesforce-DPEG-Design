# Broker Assignments (PM Leasing) — Design Spec

**Date:** 2026-06-30
**Status:** Approved (prototype + translation + scope confirmed by user)
**Visual source of truth:** [`broker-tracker-prototype.html`](./broker-tracker-prototype.html) (Claude Design export, project `Broker Tracking System Prototype`). All markup, spacing, colors, and copy in the LWCs must match this prototype.

## Problem

The Property Management (PM) team manually tracks which broker is listing which property, how long it's been since the broker last checked in, and the outcome when a listing closes (leased up, broker replaced, terminated). This is done in spreadsheets today. We are building it natively in the Property Management Lightning app.

## Approved decisions

1. **One new object: `Broker_Assignment__c`** — one record = one broker↔property listing. (Name avoids collision with the existing, unrelated `Broker_Listing__c` disposition object.)
2. **Property link = lookup to `Property_Asset__c`** (the PM portfolio object the Onboarding feature already uses). Address / Sq Ft / Asset Type are reached by spanning `Property_Asset__r.Property__r.*`, exactly as `Onboarding__c` already does with its `Gross_Sq_Ft__c` / `Address_Display__c` formulas.
3. **Broker = lookup to `Contact`** (filtered to `Is_Broker__c = true`). Firm = `Contact.Broker_Firm__c`; email/phone = standard `Contact.Email` / `Contact.Phone`.
4. **Records are never deleted.** Closing a listing changes `Status__c`; the per-property history is preserved and shown on the record.
5. **Scope = the full prototype:** the Broker Assignments list page (a flexipage app-page tab with KPIs + table + right rail), a **New Assignment** button on the list LWC that opens the standard create-record modal (no custom create page), the custom record detail page (Details / History / Notes tabs, status path, Log Check-in / Replace Broker / Close-out actions), the Broker Scorecard tab, and a daily scheduled-Apex job that creates follow-up Tasks for stale check-ins.

## Data model

`Broker_Assignment__c` (Auto Number Name `BA-{0000}`):

| Field | Type | Notes |
|---|---|---|
| `Property_Asset__c` | Lookup(`Property_Asset__c`) | the listed property |
| `Broker__c` | Lookup(`Contact`) | the listing broker |
| `Status__c` | Picklist | `Active` (default) · `Fully Leased` · `Replaced` · `Terminated` |
| `Listing_Start_Date__c` | Date | |
| `Listing_End_Date__c` | Date | blank while Active |
| `Reason_Ended__c` | Picklist | `Leased Up` · `Performance Issue` · `Company Decision` · `Other` |
| `Last_Check_In_Date__c` | Date | |
| `Days_Since_Check_In__c` | Formula(Number) | `IF(ISBLANK(Last_Check_In_Date__c), null, TODAY() - Last_Check_In_Date__c)` |
| `Property_Display_Name__c` | Formula(Text) | `Property_Asset__r.Property_Name__c` |
| `Property_Type_Display__c` | Formula(Text) | `TEXT(Property_Asset__r.Property_Type__c)` |
| `Address_Display__c` | Formula(Text) | `Property_Asset__r.Property__r.Address__c` |
| `Gross_Sq_Ft__c` | Formula(Number) | `Property_Asset__r.Property__r.Square_Footage__c` |
| `Broker_Name__c` | Formula(Text) | `Broker__r.Name` |
| `Broker_Firm__c` | Formula(Text) | `Broker__r.Broker_Firm__c` |
| `Broker_Email__c` | Formula(Text) | `Broker__r.Email` |
| `Broker_Phone__c` | Formula(Text) | `Broker__r.Phone` |
| `Leased_Area__c` | Number | editable listing field, shown in the Listing section |
| `Vacant_Area__c` | Formula(Number) | `Property_Asset__r.Vacant_Area__c`, shown in the Property section |
| `Listing_Active_Days__c` | Formula(Number) | `IF(ISBLANK(Listing_Start_Date__c), null, IF(ISBLANK(Listing_End_Date__c), TODAY(), Listing_End_Date__c) - Listing_Start_Date__c)` |

Plus a new field on **`Property_Asset__c`**: `Vacant_Area__c` (Number, "Vacant Area (Sq Ft)") — the vacancy source the assignment's `Vacant_Area__c` formula spans to.

## Additions (post-approval)

- **Record page right sidebar:** a `brokerListingActivity` LWC showing **Listing Active Days** (`Listing_Active_Days__c`) and **Last Check-In** (`Last_Check_In_Date__c`).
- **Property section** of the record detail shows **Vacant Area** (`Vacant_Area__c`); **Listing section** shows **Leased Area** (`Leased_Area__c`).
- **App-page right rail:** a `brokerTotals` LWC listing **Brokers with their total properties** (distinct `Property_Asset__c` count per broker).

## Behavior / thresholds

- **Days idle** = `Days_Since_Check_In__c`. Only meaningful for `Active` listings.
- **Follow-up flag** (Active only): `> 21` days → **Overdue** (red); `>= 14` and `<= 21` → **Follow up** (amber); `< 14` → **On track** (green). Thresholds 14 (warn) / 21 (overdue) are the prototype defaults and must be the defaults here (LWC `@api` props + Apex constants).
- **KPIs:** Total assignments · Active listings · Check-in overdue (Active & days > 21) · Fully leased.
- **Portfolio Status:** donut = Active / Total; stacked bar + legend over the four statuses.
- **Check-in Alerts:** Overdue check-ins (>21) · Due for follow-up (14–21) · On track (<14) · Active listings.
- **Scorecard:** per-broker card — Active / Fully Leased / Replaced / Terminated counts, all-time total, a stacked bar, "View listings" → list filtered to that broker.
- **History:** every `Broker_Assignment__c` with the same `Property_Asset__c`, oldest→newest; the open record highlighted.

## Status colors (exact)

| Status | bg | fg | dot |
|---|---|---|---|
| Active | `#EBF9F1` | `#146830` | `#22A652` |
| Fully Leased | `#E2E0DB` | `#3F3C38` | `#8A8680` |
| Replaced | `#FDF0F0` | `#B52020` | `#D93636` |
| Terminated | `#F9CECE` | `#8B1A1A` | `#B52020` |
| Follow-up flag (amber) | `#FDF5E6` | `#7A4A00` | `#C88010` (bar `#C88010`) |
| Overdue flag (red) | `#FDF0F0` | `#8B1A1A` | `#D93636` (bar `#D93636`) |

Brand palette: navy `--brand-primary` `#0C1E3C` / hover `#132850`; icon navy-700 `#132850`; avatar navy-800 `#0C1E3C` with gold-300 `#E0C47E` text; page-header icon gold-500 `#C8A045`; link `#1A3464`; neutral surface `#F5F3EF`; border-subtle `#E2E0DB`, border-default `#C8C4BE`; text-primary `#1A1714`, text-secondary `#524F4A`, text-tertiary `#8A8680`.

## Out of scope

- No custom "New Assignment" page — the standard create-record modal handles creation.
- No changes to the existing `Broker_Listing__c` disposition object.
