# Development & Construction Feasibility Review Objects

**Date:** 2026-06-22
**Status:** Approved (design)

## Goal

When an Opportunity enters the **Development Review** (Land path) or **Construction Review**
(Commercial path) stage, auto-create a child review record on a dedicated custom object. Each
object has its **own Lightning Path** with its own stages. Stage-specific fields are shown under
**tabs on the record page** (not attached to path steps). Guidance text stays on the path steps.

Builds on [[opportunity-record-types-build]] (Land/Commercial record types + the
"Development Review" / "Construction Review" Opportunity stages) and mirrors the
`Transaction__c` + `Transaction_Path` pattern.

## Objects

### Development_Feasibility_Review__c
- Label "Development Feasibility Review" / plural "Development Feasibility Reviews".
- Name: AutoNumber `DFR-{0000}`. sharingModel ReadWrite; activities/history/reports/search on.
- Created when a **Land** Opp enters *Development Review*.

### Construction_Feasibility_Review__c
- Label "Construction Feasibility Review" / plural "Construction Feasibility Reviews".
- Name: AutoNumber `CFR-{0000}`. Same object settings.
- Created when a **Commercial** Opp enters *Construction Review*.

## Common fields (both objects)

| Field | Type | Notes |
|-------|------|-------|
| `Opportunity__c` | Lookup(Opportunity) | deleteConstraint SetNull; relationshipName `Development_Feasibility_Reviews` / `Construction_Feasibility_Reviews` (mirrors Transaction) |
| `Stage__c` | Picklist (restricted) | path stages; default = `Requested` |
| `Deal_Type__c` | Formula(Text) | `TEXT(Opportunity__r.Deal_Type__c)` — left half of the "Land · Multifamily" badge |
| `Asset_Type__c` | Formula(Text) | from `Opportunity__r.Asset_Type__c` — right half of the badge |
| `Summary__c` | Formula(Text) | friendly secondary label from the parent Opp (name) |

## Development — stages & fields

**Stages (`Stage__c`):** `Requested` (default) → `Feasibility analysis` → `Vendor proposals`
→ `Opinion to Junior` → `Go / Conditional` → `No-Go`

**Stage-detail fields (shown under record-page tabs):**

- *Feasibility* tab (Requested-stage fields): `Flood_Plain_Risk__c` (Picklist None/Partial/Significant),
  `Drainage_Study_Required__c` (Picklist No/Yes), `Drainage_Study_Timeline__c` (Text 40),
  `Developable_Area__c` (Percent), `Zoning_PD_Approval__c` (Picklist Not Required/Required/Obtained).
- *Proposals & Cost* tab (Feasibility-analysis-stage fields): `Proposals_Received__c` (Number 2,0),
  `Proposals_Target__c` (Text 10), `Civil_MEP_Scope__c` (Picklist Not Started/Requested/Received),
  `Architecture_Firm__c` (Text 120), `Est_Cost_Impact__c` (Text 120).

**Path guidance (info per step):**
- *Requested* — "Junior forwards the land deal from Under Review." Confirm drainage timeline with civil
  engineer; flag deal-killer cost impact to Junior; note whether a zoning change triggers the PD process.
- *Feasibility analysis* — Engineer assesses flood plain / drainage / developability. Get ≥3 like-for-like
  proposals; reach out to the MUD engineer; build the comparison sheet before taking cost up.
- *Vendor proposals / Opinion to Junior / Go / Conditional / No-Go* — one short guidance line each.

## Construction — stages & fields

**Stages (`Stage__c`):** `Requested` (default) → `Scope & Cost Review` → `GC / Vendor Proposals`
→ `Opinion to Junior` → `Go / Conditional` → `No-Go`

**Stage-detail fields (under tabs):**

- *Site & Permitting* tab: `Pad_Site_Readiness__c` (Picklist Not Ready/Partial/Ready),
  `Permitting_Status__c` (Picklist Not Started/In Progress/Approved), `Hard_Cost_Estimate__c` (Currency),
  `Entitlement_Status__c` (Picklist Not Required/Required/Obtained).
- *Bids & Cost* tab: `Bids_Received__c` (Number 2,0), `Bids_Target__c` (Text 10),
  `GC_Scope__c` (Picklist Not Started/Requested/Received), `General_Contractor__c` (Text 120),
  `Est_Cost_Impact__c` (Text 120).

**Path guidance:** *Requested* — "Junior forwards the commercial deal from Under Review"; the rest a
short guidance line each (Scope & Cost Review gets a line about getting 3 GC bids / confirming scope).

## Record pages

A Lightning record page (FlexiPage, RecordPage type) per object, assigned as the object's org-default,
containing: the **Path** component (top) and a **Tabs** component holding the field tabs above plus a
"Details" tab (Opportunity, Deal Type, Asset Type, Summary, Stage) and an Activity/related tab.
Tabs + Path metadata mirror an existing record page in the repo (e.g. the Opportunity flexipage).

## Automation

- `OpportunityReviewTrigger` on Opportunity (**after insert, after update**) →
  `OpportunityReviewService.createReviewRecords(newOpps, oldMap)`.
- For each Opp whose `StageName` **becomes** `Development Review` → create one
  `Development_Feasibility_Review__c` (Stage = Requested, Opportunity__c = opp.Id).
  Same for `Construction Review` → `Construction_Feasibility_Review__c`.
- **Create-once / idempotent:** before insert, query existing children grouped by `Opportunity__c`
  and skip any Opp that already has one. Re-entry or re-save never duplicates.
- Bulk-safe (collect ids, one query per object, one insert). Apex test class
  `OpportunityReviewServiceTest` covers: Land→Development create, Commercial→Construction create,
  no-duplicate on re-entry, bulk.

## Access & navigation

- Extend the `DPEG_Acquisitions` permission set: object CRUD + field FLS for both objects (sf-deployed
  fields get no FLS otherwise — see [[metadata-field-fls-gotcha]]) + tab visibility.
- A custom **tab** per object; both added to the **Acquisitions** app nav.

## Out of scope

- No changes to the Opportunity page or its existing (placeholder) Development/Construction tabs.
- No seed data / reports / dashboards for the new objects (can follow later).

## Delivery

Deploy in dependency order (objects+fields → pathAssistants → flexipages → tab/app → Apex+permset),
dry-run validating each wave, to the `DPEG-Acq-3` scratch org. Not a git repo, so the spec is not committed.
