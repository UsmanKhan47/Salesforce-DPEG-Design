/**
 * Tests for LoiSelector. Covers the two read-for-display methods (selectById,
 * selectLatestByOpportunityId — found / none / null / 251-bulk) and the
 * fetch-for-use resolver (selectOpportunityIdRequiredById — found / missing).
 */
@isTest
private class LoiSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectById_returnsRecordWithFields() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);

        Test.startTest();
        LOI__c result = LoiSelector.selectById(loi.Id);
        Test.stopTest();

        Assert.areEqual(loi.Id, result.Id, 'Should return the LOI identified by Id');
        Assert.areEqual(loi.Offer_Price__c, result.Offer_Price__c, 'Offer_Price__c must be populated for the Deal Summary card');
    }

    @isTest
    static void selectById_nullInput_returnsNull() {
        Test.startTest();
        LOI__c result = LoiSelector.selectById(null);
        Test.stopTest();
        Assert.isNull(result, 'Null input returns null (read-for-display)');
    }

    @isTest
    static void selectById_missing_returnsNull() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);
        Id ghostId = loi.Id;
        delete loi;

        Test.startTest();
        LOI__c result = LoiSelector.selectById(ghostId);
        Test.stopTest();
        Assert.isNull(result, 'A missing LOI is a normal state for the card — returns null, not throws');
    }

    @isTest
    static void selectLatestByOpportunityId_returnsRelated() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);

        Test.startTest();
        LOI__c result = LoiSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.areEqual(loi.Id, result.Id, 'Should return the related LOI');
    }

    @isTest
    static void selectLatestByOpportunityId_bulk_returnsSingleRow() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createLois(BULK_N, opp.Id, true);

        Test.startTest();
        LOI__c result = LoiSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();

        Assert.isNotNull(result, 'LATEST must return one LOI even with 251 children');
        Assert.isNotNull(result.Offer_Price__c, 'Returned LOI has its card fields populated');
    }

    @isTest
    static void selectLatestByOpportunityId_none_returnsNull() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        LOI__c result = LoiSelector.selectLatestByOpportunityId(opp.Id);
        Test.stopTest();
        Assert.isNull(result, 'An Opportunity with no LOI returns null');
    }

    @isTest
    static void selectLatestByOpportunityId_nullInput_returnsNull() {
        Test.startTest();
        LOI__c result = LoiSelector.selectLatestByOpportunityId(null);
        Test.stopTest();
        Assert.isNull(result, 'Null input returns null');
    }

    @isTest
    static void selectOpportunityIdRequiredById_returnsParentId() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);

        Test.startTest();
        LOI__c result = LoiSelector.selectOpportunityIdRequiredById(loi.Id);
        Test.stopTest();

        Assert.areEqual(opp.Id, result.Opportunity__c, 'Should expose the parent Opportunity Id for resolveDealId');
    }

    @isTest
    static void selectOpportunityIdRequiredById_missing_throwsQueryException() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);
        Id ghostId = loi.Id;
        delete loi;

        Test.startTest();
        try {
            LoiSelector.selectOpportunityIdRequiredById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }
}
