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

        Assert.areEqual(opp.Id, result.Opportunity__c, 'Should expose the parent Opportunity Id for resolveApprovalTargetId');
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

    // selectStageRequiredById — the fetch-for-use read added for the generic stage-advance quick
    // action (RecordStageAdvanceService.advance).

    @isTest
    static void selectStageRequiredById_returnsTheStageField() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);

        Test.startTest();
        LOI__c result = LoiSelector.selectStageRequiredById(loi.Id);
        Test.stopTest();

        Assert.areEqual(loi.Id, result.Id, 'Should return the LOI identified by Id');
        // ⚠ Stage__c drives the Path; LOI_Status__c is the APPROVAL's field. Selecting the wrong one
        // here would couple the quick action to the approval and make the Path never move.
        Assert.areEqual('Draft', result.Stage__c,
            'Stage__c must be populated for the advance');
    }

    @isTest
    static void selectStageRequiredById_missing_throwsQueryException() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);
        Id ghostId = loi.Id;
        delete loi;

        Test.startTest();
        try {
            LoiSelector.selectStageRequiredById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }

    /**
     * 🔴 THE DO-NOT-NARROW CONTRACT ON RecordTypeId, MADE FALSIFIABLE (Tranche 3B).
     *
     * RecordStageAdvanceService reads this field through getPopulatedFieldsAsMap(), which CANNOT
     * distinguish "the selector did not select it" from "it was selected and is null" — so dropping
     * it from the SELECT degrades every disposition LOI to the ACQUISITION sequence, gate and
     * allow-list, silently, with every stage-map walk still green.
     *
     * ⚠ MEASURED (recorded on RecordStageAdvanceService.recordTypeIdOf): a SELECTED-but-NULL field
     * is DROPPED from getPopulatedFieldsAsMap() entirely, so `containsKey` cannot pin this. Only
     * the direct `get()` can: it returns null on a selected-and-null field and throws
     * System.SObjectException on a field that was never selected. That asymmetry is the whole
     * mechanism of this test, and it is why the assertion is a try/catch rather than an areEqual.
     */
    @isTest
    static void selectStageRequiredById_selectsRecordTypeId() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);

        Test.startTest();
        LOI__c result = LoiSelector.selectStageRequiredById(loi.Id);
        Test.stopTest();

        try {
            result.get('RecordTypeId');
        } catch (System.SObjectException e) {
            Assert.fail('selectStageRequiredById MUST select RecordTypeId. Without it '
                + 'RecordStageAdvanceService silently applies the ACQUISITION sequence, gate and '
                + 'explicit-target allow-list to every disposition LOI — no error, no failing walk '
                + 'test, and a sale driven by the buy-side path. Platform message: '
                + e.getMessage());
        }
    }

    // selectNegotiationContextById — the fetch-for-use read added for the counter-offer write
    // (CounterOfferService.saveCounterOffer), which derives the counterparty LABEL from it.

    @isTest
    static void selectNegotiationContextById_returnsBothSideDiscriminators() {
        // Both fields are load-bearing and neither is redundant: RecordTypeId is authoritative,
        // Disposition__c is the fallback for the migration window in which every row is on Master.
        // Reading them with get() rather than dot-notation is deliberate — see the measured
        // asymmetry documented on selectStageRequiredById_selectsRecordTypeId.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);

        Test.startTest();
        LOI__c result = LoiSelector.selectNegotiationContextById(loi.Id);
        Test.stopTest();

        Assert.areEqual(loi.Id, result.Id, 'Should return the LOI identified by Id');
        try {
            result.get('RecordTypeId');
            result.get('Disposition__c');
        } catch (System.SObjectException e) {
            Assert.fail('selectNegotiationContextById MUST select BOTH RecordTypeId and '
                + 'Disposition__c. CounterOfferService reads them to decide whether the '
                + 'counterparty is the Seller or the Buyer, and Ball_In_Court__c INVERTS between '
                + 'the two — so a narrowed field list writes the opposite of what happened. '
                + 'Platform message: ' + e.getMessage());
        }
    }

    @isTest
    static void selectNegotiationContextById_missing_throwsQueryException() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        LOI__c loi = TestDataFactory.createLoi(opp.Id, true);
        Id ghostId = loi.Id;
        delete loi;

        Test.startTest();
        try {
            LoiSelector.selectNegotiationContextById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // selectByDispositionIds — the bulk existence read behind
    // DispositionStageEntryService's `LOI`-stage idempotency.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectByDispositionIds_bulk_returnsMatching() {
        Disposition__c disposition =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        TestDataFactory.createDispositionLois(BULK_N, disposition.Id, true);

        Test.startTest();
        List<LOI__c> result = LoiSelector.selectByDispositionIds(new Set<Id>{ disposition.Id });
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 LOIs for the Disposition set');
        Assert.areEqual(disposition.Id, result[0].Disposition__c,
            'Disposition__c must be populated — it is the key the caller drops entrants by');
    }

    /**
     * 🔴 THE DISCRIMINATOR. Without it a query that had drifted to an unfiltered
     * `SELECT Id, Disposition__c FROM LOI__c` would pass the bulk test above and then suppress
     * disposition auto-create for every disposition in the org the moment any acquisition LOI
     * existed — which is to say, immediately.
     */
    @isTest
    static void selectByDispositionIds_excludesAcquisitionRows() {
        Disposition__c disposition =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        LOI__c sellSide = TestDataFactory.createDispositionLoi(disposition.Id, true);
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createLoi(opp.Id, true); // buy-side, no Disposition__c

        Test.startTest();
        List<LOI__c> result = LoiSelector.selectByDispositionIds(new Set<Id>{ disposition.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the disposition-parented LOI may come back — an acquisition LOI has a null '
            + 'Disposition__c and must not match');
        Assert.areEqual(sellSide.Id, result[0].Id, 'And it must be the sell-side row');
    }

    @isTest
    static void selectByDispositionIds_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<LOI__c> nullResult = LoiSelector.selectByDispositionIds(null);
        List<LOI__c> emptyResult = LoiSelector.selectByDispositionIds(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }
}
