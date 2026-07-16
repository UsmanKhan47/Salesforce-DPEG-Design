/**
 * Tests for ContractReviewSelector. Covers selectLatestByOpportunityId (returns a
 * List of 0 or 1 rows — found / none / null-input / 251-bulk) and the fetch-for-use
 * resolver selectOpportunityIdRequiredById (found / missing).
 */
@isTest
private class ContractReviewSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectLatestByOpportunityId_returnsRelated() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Contract_Review__c cr = TestDataFactory.createContractReview(opp.Id, true);

        Test.startTest();
        List<Contract_Review__c> result = ContractReviewSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Should return exactly one row when a Contract Review exists');
        Assert.areEqual(cr.Id, result[0].Id, 'Should return the related Contract Review');
        Assert.areEqual(cr.Contract_Value__c, result[0].Contract_Value__c, 'Contract_Value__c must be populated for the Deal Summary card');
    }

    @isTest
    static void selectLatestByOpportunityId_bulk_returnsSingleRow() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createContractReviews(BULK_N, opp.Id, true);

        Test.startTest();
        List<Contract_Review__c> result = ContractReviewSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'LIMIT 1 must return a single row even with 251 children');
        Assert.isNotNull(result[0].Stage__c, 'Returned Contract Review has its card fields populated');
    }

    @isTest
    static void selectLatestByOpportunityId_none_returnsEmptyList() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        List<Contract_Review__c> result = ContractReviewSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'An Opportunity with no Contract Review returns an empty list, not null');
    }

    @isTest
    static void selectLatestByOpportunityId_nullInput_returnsEmptyList() {
        Test.startTest();
        List<Contract_Review__c> result = ContractReviewSelector.selectLatestByOpportunityId(null);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'Null input returns an empty list, not null');
    }

    @isTest
    static void selectOpportunityIdRequiredById_returnsParentId() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Contract_Review__c cr = TestDataFactory.createContractReview(opp.Id, true);

        Test.startTest();
        Contract_Review__c result = ContractReviewSelector.selectOpportunityIdRequiredById(cr.Id);
        Test.stopTest();

        Assert.areEqual(opp.Id, result.Opportunity__c, 'Should expose the parent Opportunity Id for resolveDealId');
    }

    @isTest
    static void selectOpportunityIdRequiredById_missing_throwsQueryException() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Contract_Review__c cr = TestDataFactory.createContractReview(opp.Id, true);
        Id ghostId = cr.Id;
        delete cr;

        Test.startTest();
        try {
            ContractReviewSelector.selectOpportunityIdRequiredById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }
}
