/**
 * Tests for ConstructionFeasibilityReviewSelector. Covers the sole method,
 * selectLatestByOpportunityId, which returns a List of 0 or 1 rows
 * (found / none / null-input / 251-bulk).
 */
@isTest
private class ConstructionFeasReviewSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectLatestByOpportunityId_returnsRelated() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Construction_Feasibility_Review__c review = TestDataFactory.createConstructionReview(opp.Id, null, true);

        Test.startTest();
        List<Construction_Feasibility_Review__c> result = ConstructionFeasibilityReviewSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Should return exactly one row when a review exists');
        Assert.areEqual(review.Id, result[0].Id, 'Should return the related Construction Feasibility Review');
        Assert.areEqual('Requested', result[0].Stage__c, 'Stage__c must be populated for the Deal Summary card');
    }

    @isTest
    static void selectLatestByOpportunityId_bulk_returnsSingleRow() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createConstructionReviews(BULK_N, opp.Id, null, true);

        Test.startTest();
        List<Construction_Feasibility_Review__c> result = ConstructionFeasibilityReviewSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'LIMIT 1 must return a single row even with 251 children');
        Assert.isNotNull(result[0].CreatedDate, 'Returned review has its card fields populated');
    }

    @isTest
    static void selectLatestByOpportunityId_none_returnsEmptyList() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        List<Construction_Feasibility_Review__c> result = ConstructionFeasibilityReviewSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'An Opportunity with no Construction Feasibility Review returns an empty list, not null');
    }

    @isTest
    static void selectLatestByOpportunityId_nullInput_returnsEmptyList() {
        Test.startTest();
        List<Construction_Feasibility_Review__c> result = ConstructionFeasibilityReviewSelector.selectLatestByOpportunityId(null);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'Null input returns an empty list, not null');
    }

    // selectByOpportunityIds — the bulk existence read added for
    // OpportunityReviewService.createReviewRecords idempotency (Module A2).

    @isTest
    static void selectByOpportunityIds_bulk_returnsMatching() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createConstructionReviews(BULK_N, opp.Id, null, true);

        Test.startTest();
        List<Construction_Feasibility_Review__c> result =
            ConstructionFeasibilityReviewSelector.selectByOpportunityIds(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 Construction reviews for the Opportunity set');
        Assert.areEqual(opp.Id, result[0].Opportunity__c, 'Opportunity__c must be populated for the idempotency drop');
    }

    @isTest
    static void selectByOpportunityIds_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<Construction_Feasibility_Review__c> nullResult =
            ConstructionFeasibilityReviewSelector.selectByOpportunityIds(null);
        List<Construction_Feasibility_Review__c> emptyResult =
            ConstructionFeasibilityReviewSelector.selectByOpportunityIds(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }
}
