/**
 * Tests for UnderwritingSelector. Covers the two read-for-display methods
 * (selectById, selectLatestByOpportunityId — found / none / null / 251-bulk) and
 * the fetch-for-use resolver (selectOpportunityIdRequiredById — found / missing).
 */
@isTest
private class UnderwritingSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectById_returnsRecordWithFields() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Underwriting__c uw = TestDataFactory.createUnderwriting(opp.Id, true);

        Test.startTest();
        Underwriting__c result = UnderwritingSelector.selectById(uw.Id);
        Test.stopTest();

        Assert.areEqual(uw.Id, result.Id, 'Should return the Underwriting identified by Id');
        Assert.areEqual('Requested', result.Stage__c, 'Stage__c must be populated for the Deal Summary card');
    }

    @isTest
    static void selectById_nullInput_returnsNull() {
        Test.startTest();
        Underwriting__c result = UnderwritingSelector.selectById(null);
        Test.stopTest();
        Assert.isNull(result, 'Null input returns null');
    }

    @isTest
    static void selectLatestByOpportunityId_returnsRelated() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Underwriting__c uw = TestDataFactory.createUnderwriting(opp.Id, true);

        Test.startTest();
        Underwriting__c result = UnderwritingSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.areEqual(uw.Id, result.Id, 'Should return the related Underwriting');
    }

    @isTest
    static void selectLatestByOpportunityId_bulk_returnsSingleRow() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createUnderwritings(BULK_N, opp.Id, true);

        Test.startTest();
        Underwriting__c result = UnderwritingSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.isNotNull(result, 'LATEST must return one Underwriting even with 251 children');
        Assert.areEqual('Requested', result.Stage__c, 'Returned Underwriting has its card fields populated');
    }

    @isTest
    static void selectLatestByOpportunityId_none_returnsNull() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        Underwriting__c result = UnderwritingSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();
        Assert.isNull(result, 'An Opportunity with no Underwriting returns null');
    }

    @isTest
    static void selectLatestByOpportunityId_nullInput_returnsNull() {
        Test.startTest();
        Underwriting__c result = UnderwritingSelector.selectLatestByOpportunityId(null);
        Test.stopTest();
        Assert.isNull(result, 'Null input returns null');
    }

    @isTest
    static void selectOpportunityIdRequiredById_returnsParentId() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Underwriting__c uw = TestDataFactory.createUnderwriting(opp.Id, true);

        Test.startTest();
        Underwriting__c result = UnderwritingSelector.selectOpportunityIdRequiredById(uw.Id);
        Test.stopTest();

        Assert.areEqual(opp.Id, result.Opportunity__c, 'Should expose the parent Opportunity Id for resolveDealId');
    }

    @isTest
    static void selectOpportunityIdRequiredById_missing_throwsQueryException() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Underwriting__c uw = TestDataFactory.createUnderwriting(opp.Id, true);
        Id ghostId = uw.Id;
        delete uw;

        Test.startTest();
        try {
            UnderwritingSelector.selectOpportunityIdRequiredById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }
}
