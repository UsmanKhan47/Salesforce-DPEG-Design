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

    // selectByOpportunityIds — the bulk existence read added for
    // OpportunityReviewService.createReviewRecords idempotency (Module A2).

    @isTest
    static void selectByOpportunityIds_bulk_returnsMatching() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createUnderwritings(BULK_N, opp.Id, true);

        Test.startTest();
        List<Underwriting__c> result = UnderwritingSelector.selectByOpportunityIds(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 Underwritings for the Opportunity set');
        Assert.areEqual(opp.Id, result[0].Opportunity__c, 'Opportunity__c must be populated for the idempotency drop');
    }

    @isTest
    static void selectByOpportunityIds_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<Underwriting__c> nullResult = UnderwritingSelector.selectByOpportunityIds(null);
        List<Underwriting__c> emptyResult = UnderwritingSelector.selectByOpportunityIds(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }

    // selectIdsByOpportunityIds — the Id-only bulk read added for ApprovalAuditService
    // (advance related Underwritings to Approved on principal sign-off). Distinct from
    // selectByOpportunityIds: minimal field list (Id only) to preserve the original
    // audit read's small FLS surface (P4 cleanup wave G).

    @isTest
    static void selectIdsByOpportunityIds_bulk_returnsMatching() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createUnderwritings(BULK_N, opp.Id, true);

        Test.startTest();
        List<Underwriting__c> result = UnderwritingSelector.selectIdsByOpportunityIds(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 Underwritings for the Opportunity set');
        Assert.isNotNull(result[0].Id, 'Id must be populated for the Approved-advance update');
    }

    @isTest
    static void selectIdsByOpportunityIds_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<Underwriting__c> nullResult = UnderwritingSelector.selectIdsByOpportunityIds(null);
        List<Underwriting__c> emptyResult = UnderwritingSelector.selectIdsByOpportunityIds(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }

    // selectStageRequiredById — the fetch-for-use read added for the generic stage-advance quick
    // action (RecordStageAdvanceService.advance).

    @isTest
    static void selectStageRequiredById_returnsTheStageField() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Underwriting__c record = TestDataFactory.createUnderwriting(opp.Id, true);

        Test.startTest();
        Underwriting__c result = UnderwritingSelector.selectStageRequiredById(record.Id);
        Test.stopTest();

        Assert.areEqual(record.Id, result.Id, 'Should return the Underwriting identified by Id');
        // ⚠ Stage__c (the Path field), NOT the coarse Status__c this object also carries. The
        // factory sets Stage__c = 'Requested' and Status__c = 'In Progress' — deliberately
        // different values, so this assertion FAILS if the selector ever reads the wrong one.
        Assert.areEqual('Requested', result.Stage__c,
            'Stage__c must be populated for the advance');
    }

    @isTest
    static void selectStageRequiredById_missing_throwsQueryException() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Underwriting__c record = TestDataFactory.createUnderwriting(opp.Id, true);
        Id ghostId = record.Id;
        delete record;

        Test.startTest();
        try {
            UnderwritingSelector.selectStageRequiredById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }
}
