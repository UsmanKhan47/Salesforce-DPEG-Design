# Sell Meter — Disposition App Landing Page

**Date:** 2026-06-08  
**App:** Disposition (`#1B7A4B`)  
**Status:** Approved, ready for implementation

---

## Overview

The Sell Meter is the landing page of the Disposition app. It shows a portfolio-level table of all `Property_Asset__c` records ranked by a computed Meter Score (Implied Value ÷ Target Price), with a GREEN / YELLOW / RED disposition signal and a sidebar legend explaining the thresholds.

---

## Schema Change

**One new field on `Property_Asset__c`:**

| Field | Type | Values |
|---|---|---|
| `Argus_Signal__c` | Picklist | Sell Now / 12 mo / Hold |

Manual stub data entry for Phase 1. No formula fields — Implied Value and Meter Score are computed in Apex.

`gen-metadata.mjs` must be updated to include `Argus_Signal__c` so the script stays the source of truth. The `DPEG_Acquisitions` permission set must grant Read + Edit FLS on `Argus_Signal__c` (consistent with every new field added to the module).

---

## Apex Controller — `SellMeterController`

Single `@AuraEnabled(cacheable=true)` method `getPortfolio()`.

**SOQL:** Queries all `Property_Asset__c` records, cross-referencing `Property__r.Asset_Type__c` via the existing lookup.

**Computed fields (per row):**
- `impliedValue` = `NOI__c / (Market_Cap_Rate__c / 100)` — cap rate stored as a percentage (e.g., `6.5` not `0.065`)
- `meterScore` = `impliedValue / Target_Sale_Price__c`
- `sellMeter` = `'GREEN'` if meterScore ≥ 1.05, `'YELLOW'` if ≥ 0.95, `'RED'` if < 0.95

**Inner class `PropertyRow` fields:**

| Field | Type | Source |
|---|---|---|
| `id` | String | `Property_Asset__c.Id` |
| `name` | String | `Property_Asset__c.Name` |
| `assetType` | String | `Property__r.Asset_Type__c` |
| `noi` | Decimal | `NOI__c` |
| `mktCapRate` | Decimal | `Market_Cap_Rate__c` |
| `impliedValue` | Decimal | computed |
| `targetPrice` | Decimal | `Target_Sale_Price__c` |
| `meterScore` | Decimal | computed |
| `sellMeter` | String | computed (GREEN / YELLOW / RED) |
| `argusSignal` | String | `Argus_Signal__c` |

Null guards: skip computation if NOI, cap rate, or target price is null or zero.

**Test class:** `SellMeterControllerTest` — covers threshold branching (GREEN ≥ 1.05, YELLOW ≥ 0.95, RED < 0.95) and null-guard paths.

---

## LWCs

### `sellMeterHeader` — region1 (full-width header)

Wires to `getPortfolio` to read record count. Renders a single horizontal bar:
- **Left:** "Portfolio · Sell Meter — All Properties" (bold title)
- **Right:** "N assets · CoStar last sync: [hardcoded stub string in LWC] · Yardi: 2h ago" (muted meta text; live sync timestamps are out of scope for Phase 1)

Styling: white background, bottom border — matches the `totalLeads` header bar pattern.

---

### `sellMeterList` — region2 (main/left column)

Wires to `getPortfolio`. Renders a table with columns:

`PROPERTY` · `TYPE` · `NOI (YARDI)` · `MKT CAP` · `IMPLIED VALUE` · `TARGET PRICE` · `METER SCORE` · `SELL METER` · `ARGUS SIGNAL` · `ACTION`

**Formatting:**
- NOI / IMPLIED VALUE / TARGET PRICE → `$1.8M`, `$28.3M` (millions, 1 decimal)
- MKT CAP → `6.5%`
- METER SCORE → `1.05×`
- SELL METER → pill badge:
  - GREEN: bg `#1B7A4B`, white text
  - YELLOW: bg `#B45309`, white text
  - RED: bg `#B91C1C`, white text

**ACTION column (three states):**
- GREEN → filled blue "Initiate →" button (stub click handler; flow wired in a future phase)
- YELLOW → outline "Monitor" button (no-op)
- RED → plain "Hold" text (no button)

---

### `sellMeterLegend` — region3 (right sidebar)

Fully static — no wire needed. Three stacked cards matching `docs/sell-meter-score-disposition.png`:

| Band | Threshold | Description |
|---|---|---|
| GREEN | ≥ 1.05 | Auto-email Ali + Nick + Nikil · Executive Dashboard flagged · Junior prompted for BOV outreach |
| YELLOW | ≥ 0.95 | Approaching watchlist · weekly monitoring · no BOV yet |
| RED | < 0.95 | No automated action · asset remains under management |

Each card uses a left-border accent in its meter color, consistent with the `stat` border-top pattern from `totalLeads`.

---

## Flexipage + Navigation

**New flexipage:** `Sell_Meter` (AppPage, template `flexipage:appHomeTemplateHeaderTwoColumns`)

| Region | Component |
|---|---|
| `region1` | `c:sellMeterHeader` |
| `region2` | `c:sellMeterList` |
| `region3` | `c:sellMeterLegend` |

**New tab:** `Sell_Meter.tab-meta.xml` pointing at the `Sell_Meter` flexipage.

**Disposition app:** `Sell_Meter` added as the first nav tab so the app lands there on open. Existing tabs (Offering, Transaction, Property Asset, Reports, Dashboards) follow.

---

## Deploy Order

Following the established deploy-order gotcha (rolling back all components on any failure):

1. **Deploy first:** `Argus_Signal__c` field + Apex classes (`SellMeterController`, `SellMeterControllerTest`) + three LWCs
2. **Deploy second:** `Sell_Meter` flexipage + `Sell_Meter` tab + updated `Disposition` app

---

## Out of Scope (Future Phases)

- "Initiate →" flow wiring (screenshots pending from user)
- CoStar / Yardi live sync timestamps (currently stubbed)
- Automation triggered by Sell Meter color changes
