# DPEG — Unit Testing Agent Context

> **Purpose:** Pre-loaded context for the salesforce-unit-testing subagent.
> Covers TestDataFactory usage, DPEG-specific test patterns, profile names, and coverage requirements.

---

## Non-Negotiable Test Rules

1. **Coverage target: 90%+ per class.** Aim for 95%+ on service classes.
2. **Always use `TestDataFactory`** — never construct records inline. Use DPEG-specific builder methods (see below).
3. **Never `@isTest(SeeAllData=true)`** — all data created within the test context.
4. **Bulk tests** insert **251+ records** to verify chunking and governor limit safety.
5. **`System.runAs()`** for any test involving profile-specific FLS or record visibility.
6. **Callout mocks**: use `Test.setMock(HttpCalloutMock.class, new PlaidCalloutMock())` or `new ASBCalloutMock()` for any test that exercises a class touching external systems.
7. **Test method naming**: `test_<MethodName>_<Scenario>` — e.g., `test_execute_bulkInsert251Records`.
8. **Assertion messages**: every `System.assert*()` call must include a descriptive message string.

---

## TestDataFactory — DPEG-Specific Builders

All DPEG custom object builder methods are in `force-app/main/default/classes/TestDataFactory.cls`.

| Method | Returns | Notes |
|---|---|---|
| `buildBrokerFirmAccount(String name)` | `Account` | `Account_Type__c = 'Broker Firm'` |
| `createBrokerFirmAccount(String name, Boolean doInsert)` | `Account` | Insert variant |
| `buildInvestingEntityAccount(String name, String entityType)` | `Account` | `Account_Type__c = 'Investing Entity'`; `entityType` = LLC/Trust/Corp/Individual |
| `createInvestingEntityAccount(String name, String entityType, Boolean doInsert)` | `Account` | Insert variant |
| `buildInvestorContact(Id accountId, String firstName, String lastName, String role)` | `Contact` | `role` = Primary or Secondary |
| `createInvestorContact(Id accountId, String firstName, String lastName, String role, Boolean doInsert)` | `Contact` | Insert variant |
| `buildInvestor(Id contactId)` | `Investor__c` | Links to Contact |
| `createInvestor(Id contactId, Boolean doInsert)` | `Investor__c` | Insert variant |
| `buildInvestingEntityContact(Id accountId, Id contactId, String signerRole)` | `Investing_Entity_Contact__c` | `signerRole` = Primary or Secondary |
| `buildOffering(String name, Decimal targetRaise)` | `Offering__c` | Status = Draft |
| `createOffering(String name, Decimal targetRaise, Boolean doInsert)` | `Offering__c` | Insert variant |
| `buildCommitment(Id investingEntityId, Id offeringId, Decimal amount)` | `Commitment__c` | Status = Committed |
| `createCommitment(Id investingEntityId, Id offeringId, Decimal amount, Boolean doInsert)` | `Commitment__c` | Insert variant |
| `buildInvestment(Id investingEntityId, Id offeringId, Decimal amountFunded)` | `Investment__c` | Status = Active |
| `createInvestment(Id investingEntityId, Id offeringId, Decimal amountFunded, Boolean doInsert)` | `Investment__c` | Insert variant |
| `buildDistribution(Id investmentId, Decimal amount)` | `Distribution__c` | ACH_Status__c = Pending |
| `createDistribution(Id investmentId, Decimal amount, Boolean doInsert)` | `Distribution__c` | Insert variant |
| `buildContribution(Id investmentId, Decimal amount)` | `Contribution__c` | Match_Status__c = Pending |
| `buildTransaction(Id opportunityId, String stage)` | `Transaction__c` | |
| `createTransaction(Id opportunityId, String stage, Boolean doInsert)` | `Transaction__c` | Insert variant |
| `buildCriticalDate(Id transactionId, String dateType, Date dateValue)` | `Critical_Date__c` | |
| `buildPropertyAsset(Id propertyId, String status)` | `Property_Asset__c` | status = Active or Disposed |
| `buildDisposition(Id propertyAssetId, Decimal targetSalePrice)` | `Disposition__c` | |
| `createDisposition(Id propertyAssetId, Decimal targetSalePrice, Boolean doInsert)` | `Disposition__c` | Insert variant |
| `buildShareTransfer(Id transferorInvestmentId, Id transfereeAccountId, Decimal units, Decimal amount)` | `Share_Transfer__c` | Transfer_Type__c = Partial |

---

## Profile Names for `System.runAs()` Tests

| Profile Name | Use For |
|---|---|
| `'IR Manager'` | SSN/EIN field access tests, Distribution batch, Share Transfer approval |
| `'IR Associate'` | Confirm SSN/EIN is hidden, no approval authority |
| `'Acquisitions Rep'` | Deal pipeline tests, no IR financial field access |
| `'Transactions Lead'` | Critical date tests, wire amount visibility |
| `'Finance / CFO'` | Distribution read-only, Disposition visibility |
| `'Principal'` | All-module access tests |
| `'Standard User'` | Use as base for generic tests |

---

## Common Test Patterns for DPEG

### Bulk test (Acquisitions — Lead dedup)
```apex
List<Lead> leads = new List<Lead>();
for (Integer i = 0; i < 251; i++) {
    leads.add(TestDataFactory.buildLead('Broker ' + i, 'CBRE', '123 Main St ' + i));
}
insert leads;
// Assert duplicate rule logic...
```

### FLS test (IR — SSN hidden from IR Associate)
```apex
User irAssociate = TestDataFactory.createUserWithProfile('IR Associate', 'irassoc', 'Simon', 'Test', true);
System.runAs(irAssociate) {
    Contact c = [SELECT Id FROM Contact WHERE Id = :contactId WITH USER_MODE];
    // Attempt to access SSN__c — should throw or return null
}
```

### Callout mock (Plaid distribution)
```apex
Test.startTest();
Test.setMock(HttpCalloutMock.class, new PlaidCalloutMock());
DistributionBatchService.processBatch(distributionIds);
Test.stopTest();
// Assert Distribution__c.Plaid_Transfer_ID__c is populated
```

### Conversion test (Commitment → Investment — Conversion 8)
```apex
Commitment__c c = TestDataFactory.createCommitment(entityId, offeringId, 100000, true);
Contribution__c contrib = TestDataFactory.buildContribution(null, 100000);
// Simulate Plaid full-match: set contrib.Match_Status__c = 'Matched'
// Assert Investment__c created with correct Amount_Funded__c
```

---

## Mock Classes Location

- `force-app/main/default/classes/PlaidCalloutMock.cls` — simulates successful Plaid/ASB transfer response
- `force-app/main/default/classes/ASBCalloutMock.cls` — simulates ASB generic success/failure responses
