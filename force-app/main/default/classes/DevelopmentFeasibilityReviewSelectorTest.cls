/**
 * Tests for DevelopmentFeasibilityReviewSelector. Covers the sole method,
 * selectLatestByOpportunityId, which returns a List of 0 or 1 rows
 * (found / none / null-input / 251-bulk).
 */
@isTest
private class DevelopmentFeasibilityReviewSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectLatestByOpportunityId_returnsRelated() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Development_Feasibility_Review__c review = TestDataFactory.createDevelopmentReview(opp.Id, null, true);

        Test.startTest();
        List<Development_Feasibility_Review__c> result = DevelopmentFeasibilityReviewSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Should return exactly one row when a review exists');
        Assert.areEqual(review.Id, result[0].Id, 'Should return the related Development Feasibility Review');
        Assert.areEqual('Requested', result[0].Stage__c, 'Stage__c must be populated for the Deal Summary card');
    }

    @isTest
    static void selectLatestByOpportunityId_bulk_returnsSingleRow() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createDevelopmentReviews(BULK_N, opp.Id, null, true);

        Test.startTest();
        List<Development_Feasibility_Review__c> result = DevelopmentFeasibilityReviewSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'LIMIT 1 must return a single row even with 251 children');
        Assert.isNotNull(result[0].CreatedDate, 'Returned review has its card fields populated');
    }

    @isTest
    static void selectLatestByOpportunityId_none_returnsEmptyList() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        List<Development_Feasibility_Review__c> result = DevelopmentFeasibilityReviewSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'An Opportunity with no Development Feasibility Review returns an empty list, not null');
    }

    @isTest
    static void selectLatestByOpportunityId_nullInput_returnsEmptyList() {
        Test.startTest();
        List<Development_Feasibility_Review__c> result = DevelopmentFeasibilityReviewSelector.selectLatestByOpportunityId(null);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'Null input returns an empty list, not null');
    }
}
