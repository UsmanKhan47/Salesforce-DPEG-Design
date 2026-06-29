# Contract Review object + Deal Summary card

**Date:** 2026-06-22
**Status:** Approved (design)

## Goal

1. Add a **Contract Review** object that auto-creates when an Opportunity reaches the
   **Under Contract** stage, with its own Lightning Path — mirroring the Development /
   Construction Feasibility Review build ([[development-construction-review-build]]).
2. Surface the Development, Construction, and Contract review records in the existing
   `dealDocStatus` LWC on the Opportunity page, and rename its card title to **Deal Summary**.

## Part 1 — Contract_Review__c

- Label "Contract Review"; AutoNumber `CTR-{0000}`; ReadWrite; activities/history/reports/search on.
- Created when a deal's Opp enters `StageName = 'Under Contract'`.
- Fields:
  | Field | Type | Notes |
  |-------|------|-------|
  | `Opportunity__c` | Lookup(Opportunity) | SetNull; relationshipName `Contract_Reviews` |
  | `Stage__c` | Picklist (restricted) | `PSA Drafting` (default) / `Contract Negotiation` / `Contract Execution (Signed)` |
  | `Deal_Type__c` | Formula(Text) | `TEXT(Opportunity__r.Deal_Type__c)` |
  | `Asset_Type__c` | Formula(Text) | `TEXT(Opportunity__r.Asset_Type__c)` |
  | `Summary__c` | Formula(Text) | `Opportunity__r.Name` |
  | `Contract_Value__c` | Currency(16,2) | Contract Terms tab |
  | `PSA_Date__c` | Date | Contract Terms tab |
  | `Execution_Date__c` | Date | Contract Terms tab |
- Compact layout `Contract_Highlights` (Summary, Deal Type, Asset Type, Stage) for the header badge.
- **Path** `Contract_Review_Path` (`Stage__c`, `__MASTER__`), guidance-only steps.
- **Record page** `Contract_Review_Record_Page`: Path + tabs — **Contract Terms**
  (Contract Value, PSA Date, Execution Date via fieldSection→column), **Details**, **Notes & Attachments**;
  activity in the sidebar. Assigned via the Acquisition app `actionOverrides`.
- Custom **tab** added to the Acquisition app nav; CRUD + FLS (formula fields read-only) + tab on
  the `DPEG_Acquisitions` permission set.

## Part 2 — Auto-create automation

Extend `OpportunityReviewService.createReviewRecords` with a third branch:
`StageName` becomes `Under Contract` → create one `Contract_Review__c` (Stage = `PSA Drafting`),
idempotent (skip opps that already have one), bulk-safe. `OpportunityReviewServiceTest` gains a
Contract-on-update case.

## Part 3 — Deal Summary card (`dealDocStatus`)

- Rename card title "Deal Documents" → **"Deal Summary"** (bundle stays `dealDocStatus`).
- Extend `OpportunityDocStatusController.getDocStatus` to also return the latest related
  Development / Construction / Contract review per Opp: id, stage, and a meta value.
- Add three rows under NDA/LOI, each rendered **only when its record exists** (`if:true`):
  - **Development** / **Construction** — pill = Stage (green `Go / Conditional`, red `No-Go`,
    blue/amber otherwise); meta = "Opened {CreatedDate}"; click opens the review.
  - **Contract** — pill = Stage (green at `Contract Execution (Signed)`, blue/amber otherwise);
    meta = `{Contract Value} · {Execution Date else PSA Date}`; click opens the contract.
- NDA / LOI rows unchanged (keep their always-shown empty state).

## Out of scope

- No seed data / reports for Contract Review.
- No bundle rename of the LWC; no other Opportunity page changes.

## Delivery

Deploy in dependency order (object+fields → path → flexipage → tab/app → Apex+permset → LWC),
dry-run validating each wave, running `OpportunityReviewServiceTest`, to `DPEG-Acq-3`.
Not a git repo, so the spec is not committed.
