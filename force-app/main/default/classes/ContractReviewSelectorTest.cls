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

    // selectByOpportunityIds — the bulk existence read added for
    // OpportunityReviewService.createReviewRecords idempotency (Module A2).

    @isTest
    static void selectByOpportunityIds_bulk_returnsMatching() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createContractReviews(BULK_N, opp.Id, true);

        Test.startTest();
        List<Contract_Review__c> result = ContractReviewSelector.selectByOpportunityIds(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 Contract Reviews for the Opportunity set');
        Assert.areEqual(opp.Id, result[0].Opportunity__c, 'Opportunity__c must be populated for the idempotency drop');
    }

    @isTest
    static void selectByOpportunityIds_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<Contract_Review__c> nullResult = ContractReviewSelector.selectByOpportunityIds(null);
        List<Contract_Review__c> emptyResult = ContractReviewSelector.selectByOpportunityIds(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // selectNegotiationContextById — the fetch-for-use read added for the PSA version-log write
    // (PsaVersionService.saveVersion), which derives the counterparty LABEL from it.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectNegotiationContextById_returnsBothSideDiscriminators() {
        // Both fields are load-bearing and neither is redundant: RecordTypeId is authoritative,
        // Disposition__c is the fallback for the migration window in which every row is on Master.
        // Reading them with get() rather than dot-notation is deliberate: getPopulatedFieldsAsMap()
        // DROPS a selected-but-null field, so it cannot pin a field list, while the direct get()
        // returns null on a selected-and-null field and THROWS System.SObjectException on a field
        // that was never selected. That asymmetry is the whole mechanism of this test.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Contract_Review__c cr = TestDataFactory.createContractReview(opp.Id, true);

        Test.startTest();
        Contract_Review__c result = ContractReviewSelector.selectNegotiationContextById(cr.Id);
        Test.stopTest();

        Assert.areEqual(cr.Id, result.Id, 'Should return the Contract Review identified by Id');
        try {
            result.get('RecordTypeId');
            result.get('Disposition__c');
        } catch (System.SObjectException e) {
            Assert.fail('selectNegotiationContextById MUST select BOTH RecordTypeId and '
                + 'Disposition__c. PsaVersionService reads them to decide whether the counterparty '
                + 'is the Seller or the Buyer, and Ball_In_Court__c INVERTS between the two — so a '
                + 'narrowed field list writes the opposite of what happened, on a sale, silently. '
                + 'Platform message: ' + e.getMessage());
        }
    }

    @isTest
    static void selectNegotiationContextById_missing_throwsQueryException() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        Contract_Review__c cr = TestDataFactory.createContractReview(opp.Id, true);
        Id ghostId = cr.Id;
        delete cr;

        Test.startTest();
        try {
            ContractReviewSelector.selectNegotiationContextById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // selectByDispositionIds — the bulk existence read behind
    // DispositionStageEntryService's `PSA`-stage idempotency.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectByDispositionIds_bulk_returnsMatching() {
        Disposition__c disposition =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        TestDataFactory.createDispositionContractReviews(BULK_N, disposition.Id, true);

        Test.startTest();
        List<Contract_Review__c> result =
            ContractReviewSelector.selectByDispositionIds(new Set<Id>{ disposition.Id });
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(),
            'Should return all 251 Contract Reviews for the Disposition set');
        Assert.areEqual(disposition.Id, result[0].Disposition__c,
            'Disposition__c must be populated — it is the key the caller drops entrants by');
    }

    /**
     * 🔴 THE DISCRIMINATOR. Without it a query that had drifted to an unfiltered
     * `SELECT Id, Disposition__c FROM Contract_Review__c` would pass the bulk test above and then
     * suppress disposition auto-create for every disposition in the org the moment any acquisition
     * PSA existed.
     */
    @isTest
    static void selectByDispositionIds_excludesAcquisitionRows() {
        Disposition__c disposition =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        Contract_Review__c sellSide =
            TestDataFactory.createDispositionContractReview(disposition.Id, true);
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createContractReview(opp.Id, true); // buy-side, no Disposition__c

        Test.startTest();
        List<Contract_Review__c> result =
            ContractReviewSelector.selectByDispositionIds(new Set<Id>{ disposition.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the disposition-parented Contract Review may come back — an acquisition PSA has '
            + 'a null Disposition__c and must not match');
        Assert.areEqual(sellSide.Id, result[0].Id, 'And it must be the sell-side row');
    }

    @isTest
    static void selectByDispositionIds_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<Contract_Review__c> nullResult = ContractReviewSelector.selectByDispositionIds(null);
        List<Contract_Review__c> emptyResult =
            ContractReviewSelector.selectByDispositionIds(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }
}
