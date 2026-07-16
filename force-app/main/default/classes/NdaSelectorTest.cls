/**
 * Tests for NdaSelector. Covers selectById (found / null-input / missing) and
 * selectLatestByOpportunityId (related / none / null-input), plus a 251-NDA bulk
 * read proving the LATEST query returns exactly one row at scale.
 */
@isTest
private class NdaSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectById_returnsRecordWithFields() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createNda(opp.Id, true);

        Test.startTest();
        NDA__c result = NdaSelector.selectById(nda.Id);
        Test.stopTest();

        Assert.areEqual(nda.Id, result.Id, 'Should return the NDA identified by Id');
        Assert.areEqual('Pending', result.Status__c, 'Status__c must be populated for the Deal Summary card');
    }

    @isTest
    static void selectById_nullInput_returnsNull() {
        Test.startTest();
        NDA__c result = NdaSelector.selectById(null);
        Test.stopTest();
        Assert.isNull(result, 'Null input returns null (read-for-display)');
    }

    @isTest
    static void selectById_missing_returnsNull() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createNda(opp.Id, true);
        Id ghostId = nda.Id;
        delete nda;

        Test.startTest();
        NDA__c result = NdaSelector.selectById(ghostId);
        Test.stopTest();
        Assert.isNull(result, 'A missing NDA is a normal state for the card — returns null, not throws');
    }

    @isTest
    static void selectLatestByOpportunityId_returnsRelated() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        // OpportunityReviewService.ensureNda auto-creates an NDA on Opportunity insert, so the
        // opp already has one. Create a second and stamp it newer — in-transaction CreatedDate
        // is identical, so ORDER BY CreatedDate DESC is otherwise nondeterministic between them.
        NDA__c nda = TestDataFactory.createNda(opp.Id, true);
        Test.setCreatedDate(nda.Id, System.now().addMinutes(1));

        Test.startTest();
        NDA__c result = NdaSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.areEqual(nda.Id, result.Id, 'Should return the latest (this) NDA');
    }

    @isTest
    static void selectLatestByOpportunityId_bulk_returnsSingleRow() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createNdas(BULK_N, opp.Id, true);

        Test.startTest();
        NDA__c result = NdaSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.isNotNull(result, 'LATEST must return one NDA even with 251 children');
        Assert.areEqual('Pending', result.Status__c, 'Returned NDA has its card fields populated');
    }

    @isTest
    static void selectLatestByOpportunityId_none_returnsNull() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        // ensureNda auto-creates an NDA on insert; delete it to reach the genuine
        // no-NDA state this asserts.
        delete [SELECT Id FROM NDA__c WHERE Opportunity__c = :opp.Id];

        Test.startTest();
        NDA__c result = NdaSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();
        Assert.isNull(result, 'An Opportunity with no NDA returns null');
    }

    @isTest
    static void selectLatestByOpportunityId_nullInput_returnsNull() {
        Test.startTest();
        NDA__c result = NdaSelector.selectLatestByOpportunityId(null);
        Test.stopTest();
        Assert.isNull(result, 'Null input returns null');
    }
}
