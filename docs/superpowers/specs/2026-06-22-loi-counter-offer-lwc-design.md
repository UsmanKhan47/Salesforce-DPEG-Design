# LOI Counter Offer LWC

**Date:** 2026-06-22
**Status:** Approved (design)

## Goal

On the Opportunity's **LOI tab**, add a native LWC ("Counter Offer") that lets the user record a
**Counter Price** and **Counter Response** on the deal's **Primary LOI**. After saving, the Counter
Price reflects in the LOI tab's existing `Primary_LOI__r.Counter_Price__c` field (no page reload).

## Data
- **New field** `LOI__c.Counter_Response__c` — Long Text Area (multi-line note). FLS (read/edit) on
  `DPEG_Acquisitions`; also ensure `LOI__c.Counter_Price__c` has edit FLS there (LWC writes it).
- No new object, no Apex (Lightning Data Service only).

## LWC `loiCounterOffer`
- Exposed on `lightning__RecordPage` for **Opportunity**; placed on the LOI tab (flexipage),
  above the existing field section.
- Resolves the Primary LOI id via `getRecord` wire on `Opportunity.Primary_LOI__c`.
- **States:**
  - No Primary LOI → "Set a Primary LOI on this deal to record a counter offer."
  - Collapsed → `lightning-card` "Counter Offer" + **Add** button.
  - Editing → `lightning-record-edit-form` (object `LOI__c`, record = Primary LOI) with
    `lightning-input-field` for `Counter_Price__c` and `Counter_Response__c`, plus **Save** (submit)
    / **Cancel**.
- **On save success:** `notifyRecordUpdateAvailable([{recordId: opportunityId}])` refreshes the Opp
  (and its spanning `Primary_LOI__r.Counter_Price__c`) so the tab field updates live; success toast;
  collapse back to the Add button. On error → error toast (LDS surfaces FLS/validation).
- Native components only: `lightning-card`, `lightning-button`, `lightning-record-edit-form`,
  `lightning-input-field`, `uiRecordApi` — FLS/validation handled by the platform.

## Scope / out of scope
- Save **overwrites** the Primary LOI's two fields (no counter-offer history).
- Counter Response is **not** added to the tab's field section (only Counter Price reflects there).

## Delivery
Deploy the new field + permset FLS + the LWC + the LOI-tab flexipage change to `DPEG-Acq-3`,
dry-run validating. Verify the Primary-LOI resolution and a save round-trip. Not a git repo — spec not committed.
