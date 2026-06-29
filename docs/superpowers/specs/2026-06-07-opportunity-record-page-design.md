# Opportunity Record Page — Design

**Date:** 2026-06-07
**Status:** Approved (design); ready for implementation
**Org:** scratch `DPEG-Acq-2`

## Goal

A custom Lightning **record page** for `Opportunity` that matches the HTML
prototype: a Highlights header, a stage path bar, a tabbed body (Underwriting /
NDA / LOI·Approval / Related), and an Activities right sidebar. Built on the same
"Header and Right Sidebar" layout family used by the `Lead_Funnel` AppPage, but as
a **RecordPage**-type flexipage.

## Decisions (from brainstorming)

- **Tab contents = custom LWCs** styled to the prototype (not stock Record Detail).
- **Child cardinality = 1:1** — exactly one Underwriting / NDA / LOI per Opportunity;
  each card loads that single record.
- **NDA / LOI tabs** = styled cards built from existing fields (no new screenshots).
- **GRM field** = new **Number(4,1)** field on `Underwriting__c`, manually entered
  (Excel model stays with Junior; SF captures output).
- **Stages** = **custom LWC** path (read-only in v1).
- **Activities** = standard Activities in the **right sidebar only**; the redundant
  "Activity" tab is dropped.
- **Assignment** = **Org Default** Opportunity record page.

## Layout

RecordPage flexipage on the standard record "Header and Right Sidebar" template.
Exact template dev name + region names confirmed at build time via the deploy-error
probe (see memory `flexipage-template-pattern`). Three zones:

| Zone | Contents |
|------|----------|
| Header (full width) | Standard **Highlights Panel** (`Deal_Highlights` compact layout) → custom **`dealStagePath`** LWC stacked below |
| Main (wide left) | Standard **Tabs**: Underwriting, NDA, LOI · Approval, Related |
| Sidebar (right) | Standard **Activities** (Timeline + composer) |

## Custom LWCs

All target `lightning__RecordPage`, `objects: Opportunity`, apiVersion 62.0.

1. **`dealStagePath`** — reads `Opportunity.StageName` via `getRecord`/`getRecordUi`,
   renders the 7 pipeline stages as chevrons (New, Under Review, Underwriting, LOI
   Submitted, LOI Signed, Under Contract, Closed Won). completed=green,
   current=blue, future=grey. The off-path values `Dead/Pass` and `Portfolio Deal`
   are not shown on the bar. Read-only display (no stage change in v1).

2. **`underwritingCard`** — hero card. Loads the single `Underwriting__c` for the
   record. Two-column grid, right-aligned values, header "Underwriting__c — 10 Key
   Fields", right sub-note, and the blue CoStar/Placer info callout. 10 fields:
   My Price, My Cap Rate, Market Cap Rate, Underwritten NOI, Target Return,
   Hold Period, Equity Required, Projected Loan, **GRM**, OneDrive URL (rendered as
   a "↗ vN · date" link from `Underwriting_OneDrive_URL__c`).

3. **`ndaCard`** — styled card from `NDA__c`: Status, Date Sent, Date Signed, NDA
   Expiry, Method, NDA Signed, OneDrive URL.

4. **`loiApprovalCard`** — styled card from `LOI__c`: Offer Price/Cap Rate, Counter
   Price/Cap Rate, Submitted / Counter Received / Counter Response Due / LOI Signed
   dates, LOI Status; an **Approval** subsection showing LOI Status + Approved Date
   (display only — no approval *process*, per Phase-1 "no automation").

## Apex

**`OpportunityChildController`** + test class. Three `@AuraEnabled(cacheable=true)`
methods — `getUnderwriting(recordId)`, `getNda(recordId)`, `getLoi(recordId)` — each
returns the single child sObject where `Opportunity__c = :recordId` (null-safe when
none exists). Test seeds an Opportunity + one child each and asserts retrieval +
the empty case.

## Schema change

Add `GRM__c` to `Underwriting__c` via `scripts/gen-metadata.mjs`
(`{ name: 'GRM__c', label: 'GRM', type: 'Number', scale: 1 }`), re-run the
generator, then add FLS to the `DPEG_Acquisitions` permission set and the field to
the Underwriting layout.

## Build / deploy order (avoids the all-or-nothing rollback gotcha)

1. Schema: `GRM__c` + perm set + layout — deploy.
2. Apex `OpportunityChildController` + test — deploy.
3. The 4 LWCs — deploy.
4. Flexipage + Org-Default record-page assignment — deploy.

Each is its own successful deploy so a later failure can't roll back the earlier
components (see memory `flexipage-template-pattern` deploy gotcha).

## Out of scope (future)

- Clickable stage change on the path bar.
- Real LOI approval process (Phase-1 has no automation).
- Multiple child records per deal (model is 1:1 for now).
