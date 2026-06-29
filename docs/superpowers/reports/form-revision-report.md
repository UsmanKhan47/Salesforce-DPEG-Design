# Broker Portal Intake Form Revision Report

**Date:** 2026-06-22
**Org:** DPEG-Acq-3 (test-3iuncy5c1je5@example.com)
**Deploy ID:** 0AfIm000009s6GSKAY

---

## Change A — Fields Removed

### `brokerDealIntakeForm.html`
- Removed `lightning-input` for **Guidance Price** (`data-field="guidancePrice"`, type currency, required)
- Removed `lightning-input` for **Guidance Cap Rate** (`data-field="guidanceCapRate"`, type number)
- Removed `lightning-input` for **CoStar Link** (`data-field="coStarLink"`, type url)
- Removed `lightning-textarea` for **Deal Notes** (`data-field="dealNotes"`)

### `brokerDealIntakeForm.js`
- Removed state properties: `guidancePrice = null`, `guidanceCapRate = null`, `coStarLink = ''`, `dealNotes = ''`
- Removed from `handleSubmit` payload: `guidancePrice`, `guidanceCapRate`, `coStarLink`, `dealNotes` (including the `parseFloat` conversions)
- Removed from `handleReset`: `this.guidancePrice = null`, `this.guidanceCapRate = null`, `this.coStarLink = ''`, `this.dealNotes = ''`
- `handleChange`, `validate`, and `@wire` left untouched

### `BrokerPortalController.cls`
- Removed from `DealSubmission` inner class: `guidancePrice`, `guidanceCapRate`, `coStarLink`, `dealNotes` properties
- Removed from `submitDeal`: assignments `l.Guidance_Price__c`, `l.Guidance_Cap_Rate__c`, `l.CoStar_Link__c`, `l.Deal_Notes__c`
- Removed from `validate()`:
  - `if (sub.guidancePrice == null || sub.guidancePrice <= 0)` — guidance-price-required check
  - `if (sub.guidanceCapRate != null && ...)` — cap-rate range check
  - `if (String.isNotBlank(sub.coStarLink) && !isValidUrl(...))` — CoStar URL format check
  - `if (String.isNotBlank(sub.coStarLink) && sub.coStarLink.length() > 255)` — CoStar length cap
  - `if (String.isNotBlank(sub.dealNotes) && sub.dealNotes.length() > 32768)` — dealNotes length cap
- Removed helper method `isValidUrl(String value)` (now unused)
- All other validation retained: firstName/lastName/brokerageFirm/email required, email format, asset-type & deal-type picklist validity, length caps for firstName/lastName/brokerageFirm/email/phone/propertyAddress

### `BrokerPortalControllerTest.cls`
- Removed from `validInput()`: `d.guidancePrice = 5000000`, `d.guidanceCapRate = 6.25`, `d.coStarLink = 'https://costar.com/listing/1'`, `d.dealNotes = 'Anchored center.'`
- Removed from `submitDeal_happyPath_insertsStampedLead`: SELECT columns `Guidance_Price__c`, `Guidance_Cap_Rate__c`, `CoStar_Link__c`, `Deal_Notes__c`; also removed assertion `System.Assert.areEqual(5000000, l.Guidance_Price__c, ...)`
- **Deleted test methods:**
  - `submitDeal_nonPositivePrice_rejected` — zero/non-positive Guidance Price rejection
  - `submitDeal_capRateOutOfRange_rejected` — cap rate out-of-range rejection
  - `submitDeal_badCoStarUrl_rejected` — invalid CoStar URL rejection

---

## Change B — Two Sections, Personal First

The LWC HTML was reordered into exactly two sections:

1. **"Your Details"** (section header `<h3>`) → First Name, Last Name, Brokerage Firm, Email, Phone
2. **"Deal Details"** (section header `<h3>`) → Property Address, Asset Type, Deal Type

The hidden honeypot `<div class="hp">` and `<div class="form__actions">` (submit button + spinner) remain after section 2. The page header, error banner, and confirmation state (`lwc:if={submitted}`) are unchanged.

---

## Deploy Result

```
Status: Succeeded
Deploy ID: 0AfIm000009s6GSKAY
Components: 3/3 (100%)
  - BrokerPortalController (ApexClass)
  - BrokerPortalControllerTest (ApexClass)
  - brokerDealIntakeForm (LightningComponentBundle)
Elapsed Time: 6.97s
```

---

## Test Results

```
TEST NAME                                                                 OUTCOME  RUNTIME (MS)
------------------------------------------------------------------------  -------  ------------
BrokerPortalControllerTest.submitDeal_happyPath_insertsStampedLead        Pass     95
BrokerPortalControllerTest.submitDeal_honeypotFilled_skipsInsert          Pass     6
BrokerPortalControllerTest.submitDeal_invalidAssetType_rejected           Pass     8
BrokerPortalControllerTest.submitDeal_invalidDealType_rejected            Pass     5
BrokerPortalControllerTest.submitDeal_invalidEmail_rejected               Pass     5
BrokerPortalControllerTest.submitDeal_missingEmail_rejected               Pass     4
BrokerPortalControllerTest.submitDeal_missingFirm_rejected                Pass     5
BrokerPortalControllerTest.submitDeal_missingLastName_rejected            Pass     4
BrokerPortalControllerTest.submitDeal_missingPropertyAddress_rejected     Pass     4
BrokerPortalControllerTest.submitDeal_openDuplicate_setsFlag              Pass     111
BrokerPortalControllerTest.submitDeal_overLengthPropertyAddress_rejected  Pass     4
BrokerPortalControllerTest.getFormMetadata_returnsActiveOptions           Pass     32
BrokerPortalControllerTest.submitDeal_closedDuplicate_doesNotSetFlag      Pass     654
BrokerPortalControllerTest.submitDeal_differentAddress_doesNotSetFlag     Pass     114

Outcome: Passed | Tests Ran: 14 | Pass Rate: 100% | Fail Rate: 0%
Test Run Id: 707Im00000Uzdcs
Test Execution Time: 1051ms
```
