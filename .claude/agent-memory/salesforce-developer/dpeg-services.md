# DPEG — Developer Agent Context

> **Purpose:** Pre-loaded context for the salesforce-developer subagent.
> Covers the Apex service layer map, integration patterns, conversion logic, and coding standards.

---

## API Version

**66.0** — all generated Apex must use `@apiVersion` 66.0 in `-meta.xml` files.

---

## Apex Layering (Mandatory)

| Layer | File Pattern | Responsibility |
|---|---|---|
| Trigger | `<Object>Trigger.trigger` | Thin — one line delegating to handler. No logic. |
| Trigger Handler | `<Object>TriggerHandler.cls` | Routes before/after DML events to domain methods. Bulk-safe. |
| Domain | `<Object>Domain.cls` | Per-object business rules on collections (`List<SObject>`). |
| Service | `<Feature>Service.cls` | Cross-object orchestration. Invoked by LWC, Flow, or Trigger. |
| Selector | `<Object>Selector.cls` | ALL SOQL for that object. Nothing else queries it. |
| DTO | `<Feature>DTO.cls` | Structured input/output for REST endpoints and `@AuraEnabled` methods. |
| Batch/Queueable | `<Feature>Batch.cls` | Async processing. One job class per feature. |

---

## Non-Negotiable Coding Standards

1. **`with sharing`** on every service, selector, domain, and controller class. `without sharing` requires written justification in the class header `@description`.
2. **`WITH USER_MODE`** in every SOQL statement (enforces FLS + CRUD in one clause, API 66.0+). Never inline SOQL outside selector classes.
3. **Bulkification**: every public method accepts `List<SObject>`, not a single record. No SOQL or DML inside loops.
4. **`@AuraEnabled` methods** wrap all logic in try/catch and throw `AuraHandledException` with a user-safe message. Never expose raw exception messages.
5. **`DPEGException`**: use the shared `DPEGException` class for internal exception signalling (see `force-app/main/default/classes/DPEGException.cls`).
6. **Test data**: always use `TestDataFactory`. Never `@isTest(SeeAllData=true)`. Bulk tests insert 251+ records.
7. **Callouts**: all ASB/Plaid/external callouts in `PlaidCalloutService.cls` or an equivalent dedicated service. Never inline `Http` calls in domain or service classes. Use `HttpCalloutMock` in tests — see `PlaidCalloutMock.cls` and `ASBCalloutMock.cls`.
8. **Named Credentials**: all callout endpoints use Named Credentials. The single SF Named Credential points to the ASB endpoint — not directly to Plaid, Yardi, or CoStar.

---

## Anticipated Service Classes

| Class | Purpose |
|---|---|
| `LeadConversionService.cls` | Conversion 1 (broker) and Conversion 7 (investor) — dedup, Account/Contact match-or-create, Investor__c + Investing_Entity_Contact__c creation |
| `ContractHandoffService.cls` | Conversions 2 & 3 — create Transaction__c and Offering__c simultaneously when `Contract_Signed__c = TRUE` |
| `ClosingService.cls` | Conversion 4 — promote Property__c → Property_Asset__c on Transaction close |
| `PlaidContributionService.cls` | Conversion 8 — reconcile Contribution__c, create Investment__c when Plaid confirms full wire |
| `ShareTransferService.cls` | Conversion 9 — reduce Transferor Investment__c, create Transferee Investment__c, calculate pro-rata cost basis |
| `DistributionBatchService.cls` | Build distribution batch payload, call ASB endpoint via `PlaidCalloutService`, store transfer IDs on Distribution__c |
| `SellMeterService.cls` | Recalculate Sell_Meter__c (GREEN/YELLOW/RED) on NOI or cap rate change; notify Principals on GREEN transition |
| `PlaidCalloutService.cls` | All HTTP callouts to ASB endpoint. Wraps `Http`, uses Named Credential. Mocked via `PlaidCalloutMock` in tests. |
| `IRDocumentService.cls` | Create IR_Document__c records on Salesforce Files upload; trigger portal sharing rules |

---

## Object Conversion Points — Apex Trigger Responsibilities

| Conversion | Trigger/Tool | Apex Service |
|---|---|---|
| 1: Lead → Opp + Account + Contact | Manual (Junior clicks Convert) + Flow | `LeadConversionService` |
| 2: Opp → Transaction__c | Record-Triggered Flow | `ContractHandoffService` (called by Flow via Invocable) |
| 3: Opp → Offering__c | Same Flow as #2 | `ContractHandoffService` |
| 4: Transaction__c → Property_Asset__c | Record-Triggered Flow on stage = Closed Won | `ClosingService` (Invocable) |
| 7: Lead → Account + Contact + Investor__c | Record-Triggered Flow (IR Web-to-Lead) | `LeadConversionService` (Invocable) |
| 8: Commitment__c → Investment__c | Apex trigger on Contribution__c | `PlaidContributionService` (called by trigger) |
| 9: Investment__c → Updated + New | Apex (on Approval Process approval) | `ShareTransferService` (Invocable from Process) |

---

## Integration Architecture (Critical)

**All external integrations route through ASB. Never call external APIs directly from Salesforce.**

- Salesforce → ASB: Apex callout via `PlaidCalloutService` using the `ASB_Endpoint` Named Credential
- ASB → Salesforce: REST API inbound (webhook results posted back by ASB)
- Plaid credentials: stored in ASB secrets vault. `Plaid_Access_Token__c` on `Investing_Entity__c` is a reference ID only — hidden from all UI profiles.

**ASB handlers and what triggers them:**

| ASB Handler | Direction | Triggered By |
|---|---|---|
| `plaid-transfer-initiator` | SF → ASB → Plaid | `DistributionBatchService` Apex callout |
| `plaid-wire-matcher` | Plaid → ASB → SF | Plaid webhook (ASB calls SF REST API to update `Contribution__c`) |
| `plaid-status-receiver` | Plaid → ASB → SF | Plaid status webhook → updates `Distribution__c.ACH_Status__c` |
| `yardi-soap-adapter` | Yardi → ASB → SF | ASB scheduler nightly 2 AM |
| `procore-rest-connector` | Procore → ASB → SF | ASB scheduler every 4 hours |
| `market-data-connector` | CoStar/Placer.ai → ASB → SF | ASB scheduler weekly Sunday midnight |

---

## Key Fields to Reference

- `Account.Account_Type__c` — picklist: `'Broker Firm'` or `'Investing Entity'`
- `Contact.Role__c` — picklist: `'Primary'` or `'Secondary'` (for investor contacts)
- `Investing_Entity_Contact__c.Signer_Role__c` — picklist: `'Primary'` or `'Secondary'`
- `Offering__c.Transfers_Permitted__c` — Boolean; must be TRUE before any Share_Transfer__c can be created
- `Share_Transfer__c.Transfer_Type__c` — picklist: `'Full'` or `'Partial'`
- `Distribution__c.ACH_Status__c` — picklist: `'Pending'`, `'Posted'`, `'Failed'`, `'Returned'`
- `Investment__c.Transfer_Source__c` — lookup to `Share_Transfer__c` (audit trail on transferred investments)
- `Transaction__c.Contract_Signed__c` — Boolean field that triggers Conversions 2 & 3
- `Disposition__c.Sell_Meter__c` — formula: `'GREEN'`, `'YELLOW'`, or `'RED'`
- `Critical_Date__c.Days_Remaining__c` — formula: `Date__c - TODAY()`

---

## Reference Implementations (Read Before Writing New Code)

- Selector pattern: `.claude/skills/sf-apex/references/AccountSelector.cls`
- Service pattern: `.claude/skills/sf-apex/references/AccountService.cls`
- Batch pattern: `.claude/skills/sf-apex/references/AccountDeduplicationBatch.cls`
- Test factory: `force-app/main/default/classes/TestDataFactory.cls`
- Shared exception: `force-app/main/default/classes/DPEGException.cls`
- Callout mocks: `force-app/main/default/classes/PlaidCalloutMock.cls`, `ASBCalloutMock.cls`
