# DPEG — Code Review Agent Context

> **Purpose:** Pre-loaded context for the salesforce-code-review subagent.
> Covers DPEG-specific review standards that go beyond generic Apex best practices.

---

## Review Verdict Criteria

| Verdict | Condition |
|---|---|
| **APPROVED** | All mandatory checks pass; no critical or high issues |
| **APPROVED WITH WARNINGS** | No critical issues; medium issues documented but non-blocking |
| **CHANGES REQUIRED** | Any critical issue present (security, sharing, bulkification, callout pattern) |

---

## Mandatory Checks — Apex

### Sharing & Security (Critical)
- [ ] Every service, selector, domain, and controller class declares `with sharing`
- [ ] `without sharing` present? → requires written justification in `@description` tag
- [ ] Every SOQL query uses `WITH USER_MODE` (not `WITH SYSTEM_MODE` unless justified)
- [ ] No hardcoded credentials or endpoints — all use Named Credentials (`ASB_Endpoint`)
- [ ] `Plaid_Access_Token__c` is never read in UI-accessible code — system/Apex only
- [ ] `SSN__c` and `Tax_ID_EIN__c` never appear in SOQL `SELECT` clauses accessible to non-IR-Manager code

### Bulkification (Critical)
- [ ] Every public method accepts `List<SObject>`, not a single `Id` or `SObject`
- [ ] No SOQL queries inside `for` loops
- [ ] No DML statements inside `for` loops
- [ ] Trigger handlers delegate to domain/service, never process logic inline

### Error Handling (Critical)
- [ ] `@AuraEnabled` methods wrap logic in try/catch and throw `AuraHandledException` with user-safe message
- [ ] Internal exceptions use `DPEGException` class — never `throw new Exception()`
- [ ] Callout failures surface via `DPEGException`, not swallowed silently

### Layering (High)
- [ ] SOQL only in Selector classes — never in Domain, Service, or Controller
- [ ] Trigger files contain only: `TriggerHandler.handle(Trigger.new, Trigger.old, ...)` — zero logic
- [ ] No cross-object DML in Domain classes (that belongs in Service)
- [ ] DTOs used at `@AuraEnabled` boundaries, not raw SObjects

### Integration (Critical)
- [ ] External HTTP callouts only in `PlaidCalloutService` or equivalent dedicated callout class
- [ ] No direct Plaid/Yardi/CoStar API calls — all route through ASB Named Credential
- [ ] Tests use `PlaidCalloutMock` or `ASBCalloutMock` — no live callouts in tests

---

## Mandatory Checks — Test Classes

- [ ] Uses `TestDataFactory` — no inline record construction for custom objects
- [ ] No `@isTest(SeeAllData=true)` anywhere
- [ ] At least one bulk test method with 251+ records for every service class
- [ ] `System.runAs()` used for profile/FLS-sensitive assertions
- [ ] All `System.assert*()` calls include a descriptive message string
- [ ] Coverage ≥ 90% per class (unit-testing agent should have already ensured this)
- [ ] Mock classes (`PlaidCalloutMock`, `ASBCalloutMock`) used for any callout path

---

## Mandatory Checks — LWC

- [ ] `AuraHandledException` caught and displayed via `lightning/platformShowToastEvent`
- [ ] SLDS 2 design tokens (`--slds-g-*`) used — no hardcoded colours or spacing values
- [ ] LDS wire adapters used for simple record reads/writes before reaching for Apex
- [ ] Jest test file present at `__tests__/<componentName>.test.js`
- [ ] No inline `console.log` left in production code

---

## Mandatory Checks — Metadata / Declarative

- [ ] All new custom objects have OWD = Private (no exceptions without justification)
- [ ] FLS applied correctly to sensitive fields (SSN, EIN, Plaid token, wire amounts)
- [ ] Masked formula companion fields (`_Masked__c`) created for every restricted PII text field
- [ ] No Aura components — LWC only
- [ ] No OmniStudio metadata (DPEG does not use OmniStudio)
- [ ] All Flows are Record-Triggered, Scheduled, or Screen Flow — no Process Builder
- [ ] Field History Tracking enabled on financial state-change fields of new objects

---

## DPEG-Specific Anti-Patterns (Flag as Critical)

| Anti-Pattern | Why It's Critical |
|---|---|
| Direct `Http` callout to Plaid/Yardi endpoint in Apex | Bypasses ASB; credentials must be in ASB vault not SF |
| Inline SOQL in a Service or Domain class | Breaks selector pattern; also bypasses `WITH USER_MODE` |
| Single-record trigger handler (no bulkification) | Will fail at 200+ records in IR distribution batches |
| `SSN__c` on a page layout accessible to non-IR-Manager profiles | PII exposure; regulatory risk |
| `Plaid_Access_Token__c` on any page layout | Security credential exposure |
| `@isTest(SeeAllData=true)` | Tests will fail in scratch org where no real data exists |
| Flow calling Apex without governor limit awareness | Distribution batches process 100s of records; must be async |
| OWD set to Public on any financial object | Investors would see each other's data |
