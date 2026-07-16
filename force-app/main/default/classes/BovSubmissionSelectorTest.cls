/**
 * Tests for BovSubmissionSelector (P4 cleanup wave E — Disposition module).
 *
 * Covers the one relocated query: field population, BOV_Score__c DESC NULLS LAST
 * ordering, the empty-result contract, and a 251-record data-volume read
 * (.claude/rules/bulk-test-rule.md).
 *
 * @TestSetup builds the Property -> Property_Asset -> Disposition scaffold with
 * explicit parent Ids (never default*()), and every test queries for that
 * Disposition — the TestDataFactory header warns the static scaffold cache does
 * NOT survive the @TestSetup boundary.
 *
 * No System.runAs USER_MODE test: BOV_Submission__c is a custom object and P3
 * proved the custom-field FLS gap is 0, so the running user reads every selected
 * field (the runAs assertion is reserved for standard-object selectors).
 */
@isTest
private class BovSubmissionSelectorTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(asset.Id, true);
    }

    private static Id dispositionId() {
        return [SELECT Id FROM Disposition__c LIMIT 1].Id;
    }

    @isTest
    static void selectByDispositionId_populatesEverySelectedField() {
        Id dispId = dispositionId();
        // Factory defaults are known values; asserting them proves each field is selected.
        TestDataFactory.createBovSubmission(dispId, true);

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Exactly one BOV submission exists for the Disposition');
        BOV_Submission__c s = result[0];
        Assert.areEqual('Test Brokerage 0', s.Broker_Firm__c, 'Broker_Firm__c should be selected');
        Assert.areEqual('Test Broker 0', s.Contact_Name__c, 'Contact_Name__c should be selected');
        Assert.areEqual(1200000, s.BOV_Amount__c, 'BOV_Amount__c should be selected');
        Assert.areEqual(2.5, s.Commission_Rate__c, 'Commission_Rate__c should be selected');
        Assert.areEqual(30, s.Days_To_Market__c, 'Days_To_Market__c should be selected');
        Assert.areEqual(75, s.Hist_Success_Rate__c, 'Hist_Success_Rate__c should be selected');
        Assert.areEqual(6.25, s.Cap_Rate__c, 'Cap_Rate__c should be selected');
        Assert.areEqual(80, s.BOV_Score__c, 'BOV_Score__c should be selected');
        Assert.areEqual('Backup', s.Submission_Status__c, 'Submission_Status__c should be selected');
    }

    @isTest
    static void selectByDispositionId_ordersByScoreDescNullsLast() {
        Id dispId = dispositionId();
        List<BOV_Submission__c> subs = TestDataFactory.createBovSubmissions(3, dispId, false);
        subs[0].BOV_Score__c = 90;
        subs[1].BOV_Score__c = 80;
        subs[2].BOV_Score__c = null;
        insert subs;

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three submissions should return');
        Assert.areEqual(90, result[0].BOV_Score__c, 'Highest score should sort first');
        Assert.areEqual(80, result[1].BOV_Score__c, 'Middle score should sort second');
        Assert.isNull(result[2].BOV_Score__c, 'A null score should sort last (NULLS LAST)');
    }

    @isTest
    static void selectByDispositionId_noSubmissions_returnsEmpty() {
        Id dispId = dispositionId();

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A Disposition with no submissions returns an empty list, not null');
    }

    @isTest
    static void selectByDispositionId_bulk251_readsAll() {
        Id dispId = dispositionId();
        TestDataFactory.createBovSubmissions(BULK_N, dispId, true);

        Test.startTest();
        List<BOV_Submission__c> result = BovSubmissionSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 submissions under the Disposition should be read');
    }
}
