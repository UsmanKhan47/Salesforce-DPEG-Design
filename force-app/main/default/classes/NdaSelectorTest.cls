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

    // selectByOpportunityIds — the bulk existence read added for
    // OpportunityReviewService.ensureNda idempotency (Module A2).

    @isTest
    static void selectByOpportunityIds_bulk_returnsMatching() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        // OpportunityReviewService.ensureNda auto-creates one NDA on Opportunity
        // insert; add 250 more for a deterministic total of 251.
        TestDataFactory.createNdas(BULK_N - 1, opp.Id, true);

        Test.startTest();
        List<NDA__c> result = NdaSelector.selectByOpportunityIds(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'Should return all 251 NDAs for the Opportunity set');
        Assert.areEqual(opp.Id, result[0].Opportunity__c, 'Opportunity__c must be populated for the idempotency drop');
    }

    @isTest
    static void selectByOpportunityIds_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<NDA__c> nullResult = NdaSelector.selectByOpportunityIds(null);
        List<NDA__c> emptyResult = NdaSelector.selectByOpportunityIds(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null input returns an empty list, not null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty input returns an empty list, not null');
    }

    // selectStageRequiredById — the fetch-for-use read added for the generic stage-advance quick
    // action (RecordStageAdvanceService.advance).

    @isTest
    static void selectStageRequiredById_returnsTheStageField() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createNda(opp.Id, true);

        Test.startTest();
        NDA__c result = NdaSelector.selectStageRequiredById(nda.Id);
        Test.stopTest();

        Assert.areEqual(nda.Id, result.Id, 'Should return the NDA identified by Id');
        // ⚠ NDA__c's stage field is Status__c, NOT Stage__c — one of only two of the six
        // stage-controlled deal children shaped that way. A selector that quietly selected
        // a differently-named field would make the generic service read null and refuse every
        // advance with "this record has no stage set".
        Assert.areEqual('Pending', result.Status__c,
            'Status__c is the NDA stage field and must be populated for the advance');
        // 🔴 FIELD-LIST CONTRACT. RecordTypeId is what lets RecordStageAdvanceService tell an
        // Acquisition_NDA from a Disposition_NDA — the two sequences diverge on the SHARED value
        // 'Sent' (acquisition -> Received, disposition -> Signed). Narrowing the SELECT does not
        // fail loudly; it silently routes every NDA to the acquisition sequence, so the only way to
        // catch it is to assert the field was actually QUERIED.
        //
        // ⚠ SObject.get(String) IS THE ONLY INSTRUMENT THAT WORKS HERE, AND THAT IS MEASURED, NOT
        // ASSUMED (usman-dpeg, 2026-08-09):
        //     SELECT Id, Status__c, RecordTypeId  -> getPopulatedFieldsAsMap() = {Id, Status__c}
        // A queried field whose VALUE is null is DROPPED from that map, so containsKey() cannot
        // tell "never selected" from "selected and empty" — and this fixture is exactly the empty
        // case until the record types are assigned. get() discriminates cleanly: it THREW
        // System.SObjectException for an unqueried field and RETURNED null for a queried null one.
        try {
            Object recordTypeId = result.get('RecordTypeId');
            Assert.isTrue(recordTypeId == null || recordTypeId instanceof Id,
                'RecordTypeId must come back as an Id or null, never anything else');
        } catch (System.SObjectException e) {
            Assert.fail('selectStageRequiredById MUST select RecordTypeId — without it the '
                + 'stage-advance service cannot distinguish the two NDA record types and silently '
                + 'applies the acquisition sequence to a disposition NDA. The field was not part '
                + 'of the SELECT: ' + e.getMessage());
        }
    }

    @isTest
    static void selectStageRequiredById_missing_throwsQueryException() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createNda(opp.Id, true);
        Id ghostId = nda.Id;
        delete nda;

        Test.startTest();
        try {
            NdaSelector.selectStageRequiredById(ghostId);
            Assert.fail('A missing fetch-for-use Id must throw QueryException');
        } catch (System.QueryException e) {
            Assert.isNotNull(e.getMessage(), 'QueryException expected for a non-existent Id');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectLatestByDispositionId — the DISPOSITION-side read backing the BOV
    // Outreach NDA pill (BovController.getOutreachSummary).
    //
    // NDA__c is dual-parented and BOTH lookups are optional, so a disposition NDA
    // carries Disposition__c with Opportunity__c left blank. These fixtures build
    // exactly that shape: TestDataFactory.createNda(null, false) then stamp the
    // Disposition. Nothing about NDA__c itself changes here (D7 owns that).
    // ═══════════════════════════════════════════════════════════════════════════

    /** A disposition-parented NDA, built the way the Disposition module really makes them. */
    private static NDA__c dispositionNda(Id dispositionId, String status) {
        NDA__c nda = TestDataFactory.createNda(null, false);
        nda.Disposition__c = dispositionId;
        nda.Status__c = status;
        insert nda;
        return nda;
    }

    @isTest
    static void selectLatestByDispositionId_returnsTheLatestStatus() {
        Disposition__c disp = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        NDA__c older = dispositionNda(disp.Id, 'Pending');
        NDA__c newer = dispositionNda(disp.Id, 'Signed');
        // In-transaction CreatedDate is identical across both rows, so ORDER BY
        // CreatedDate DESC is otherwise nondeterministic between them.
        Test.setCreatedDate(older.Id, System.now().addMinutes(-5));

        Test.startTest();
        NDA__c result = NdaSelector.selectLatestByDispositionId(disp.Id);
        Test.stopTest();

        Assert.areEqual(newer.Id, result.Id, 'The most recently created NDA is the one the pill shows');
        Assert.areEqual('Signed', result.Status__c, 'Status__c must be populated - it IS the pill');
    }

    /**
     * The CreatedDate TIE, pinned. Deliberately NO Test.setCreatedDate: both NDAs are created
     * inside one transaction, so CreatedDate is identical (it is second-granular) and
     * `ORDER BY CreatedDate DESC` alone leaves the winner arbitrary. The `, Id DESC`
     * tie-break is what makes it the later row, every time.
     *
     * 🔴 WHY THIS MATTERS BEYOND TIDINESS (code review W4): the BOV pill and the Flow-computed
     * gate are asserted to read "the same row". Wire_Verification_Rollup's Flow Get Records can
     * carry only ONE sort field, so the selector is the half that CAN be made deterministic —
     * and a non-deterministic selector would make the two disagree by construction. Mirrors
     * WireSelectorTest.selectMostRecentByDispositionId_returnsMostRecentWire, which pins the
     * identical tie-break on the identical shape.
     */
    @isTest
    static void selectLatestByDispositionId_createdDateTie_breaksOnIdDesc() {
        Disposition__c disp = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        dispositionNda(disp.Id, 'Pending');
        NDA__c later = dispositionNda(disp.Id, 'Signed');

        Test.startTest();
        NDA__c result = NdaSelector.selectLatestByDispositionId(disp.Id);
        Test.stopTest();

        Assert.areEqual(later.Id, result.Id,
            'ORDER BY CreatedDate DESC, Id DESC must resolve a same-transaction CreatedDate tie '
            + 'to the later row - without the Id DESC tie-break this is arbitrary');
    }

    /**
     * 🔴 "No NDA yet" is the NORMAL state for most dispositions and must return null, never
     * throw. A throw here would reach BovController's outer catch and blank the entire BOV
     * Outreach tile — the exact failure the fail-soft wrapper exists to prevent, arriving
     * through the front door instead.
     */
    @isTest
    static void selectLatestByDispositionId_noNda_returnsNull() {
        Disposition__c disp = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);

        Test.startTest();
        NDA__c result = NdaSelector.selectLatestByDispositionId(disp.Id);
        Test.stopTest();

        Assert.isNull(result, 'A Disposition with no NDA returns null (read-for-display)');
    }

    @isTest
    static void selectLatestByDispositionId_nullInput_returnsNull() {
        Test.startTest();
        NDA__c result = NdaSelector.selectLatestByDispositionId(null);
        Test.stopTest();
        Assert.isNull(result, 'Null input returns null');
    }

    /**
     * The two parents are separate lookups, not one parameterised query. An NDA hanging off
     * an Opportunity must be invisible to the Disposition read and vice versa — otherwise a
     * disposition would display an acquisition counterparty's NDA status as its own.
     */
    @isTest
    static void selectLatestByDispositionId_ignoresOpportunityParentedNdas() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createNda(opp.Id, true);
        Disposition__c disp = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);

        Test.startTest();
        NDA__c result = NdaSelector.selectLatestByDispositionId(disp.Id);
        Test.stopTest();

        Assert.isNull(result,
            'An Opportunity-parented NDA must not leak into the Disposition read');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectByDispositionIds — the SET-based read behind DispositionStageEntryService's
    // idempotency ("never a second BUYER NDA on one disposition", D19.1).
    //
    // ⚠ This is the class's first WITH SYSTEM_MODE method. The tests below cannot
    // prove the mode itself: the test-running user is an administrator, for whom
    // USER_MODE and SYSTEM_MODE return the same rows on a custom object they own.
    // What they CAN pin is the field list, which is the contract that makes the
    // caller's idempotency work — and that is what they do.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectByDispositionIds_bulk_returnsMatchingAcrossSeveralParents() {
        Disposition__c first = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        Disposition__c second = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        TestDataFactory.createDispositionNdas(2, first.Id, true);
        TestDataFactory.createDispositionNdas(1, second.Id, true);
        Disposition__c unrelated = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        TestDataFactory.createDispositionNdas(1, unrelated.Id, true);

        Test.startTest();
        List<NDA__c> rows = NdaSelector.selectByDispositionIds(
            new Set<Id>{ first.Id, second.Id });
        Integer queries = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(3, rows.size(),
            'All NDAs for the requested dispositions come back, and only those - a disposition '
            + 'outside the set must not leak in');
        Assert.areEqual(1, queries,
            'ONE query for the whole set. The caller runs this once per TRIGGER CHUNK, so a '
            + 'per-parent query here would be SOQL in a loop at 200 dispositions');
    }

    /**
     * 🔴 THE FIELD LIST IS A CONTRACT, AND THIS IS WHERE IT IS ENFORCED.
     * DispositionStageEntryService suppresses auto-create on `Party_Role__c = 'Buyer'` grouped by
     * `Disposition__c`. Dropping either field does NOT fail loudly — SObject.get() throws only for
     * a field that was never SELECTED, which is exactly the falsifier used here (a queried field
     * whose value is null is silently absent from getPopulatedFieldsAsMap, so containsKey cannot
     * pin this). Narrowing the SELECT would make the service mint a SECOND buyer NDA on a
     * disposition that already has one.
     */
    @isTest
    static void selectByDispositionIds_selectsTheIdempotencyFields() {
        Disposition__c disp = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        TestDataFactory.createDispositionNda(disp.Id, true);

        Test.startTest();
        NDA__c row = NdaSelector.selectByDispositionIds(new Set<Id>{ disp.Id })[0];
        Test.stopTest();

        Assert.areEqual(disp.Id, row.Disposition__c,
            'Disposition__c is how the caller groups results back to a parent');
        Assert.areEqual('Buyer', row.Party_Role__c,
            'Party_Role__c IS the idempotency key (D19.1) - the buyer NDA is auto-created and the '
            + 'broker NDA is added by hand, so "has any NDA" is the wrong suppression test');
        // These two are not used by the idempotency rule itself but are part of the declared
        // contract; get() throws for a never-selected field, which is what makes this falsifiable.
        Assert.isNotNull(row.get('Status__c'), 'Status__c is part of the declared field list');
        row.get('RecordTypeId'); // must not throw - selected, may legitimately be null pre-T-A1
    }

    @isTest
    static void selectByDispositionIds_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<NDA__c> nullResult = NdaSelector.selectByDispositionIds(null);
        List<NDA__c> emptyResult = NdaSelector.selectByDispositionIds(new Set<Id>());
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, nullResult.size(), 'Null input returns an empty list, never null');
        Assert.areEqual(0, emptyResult.size(), 'Empty input returns an empty list');
        Assert.areEqual(0, used,
            'Neither guard may issue a query. The caller reaches this on every ordinary '
            + 'Disposition save in the org, so a wasted query here is a wasted query everywhere');
    }

    /**
     * The mirror of selectLatestByDispositionId_ignoresOpportunityParentedNdas, on the set-based
     * read: an acquisition NDA must never be able to suppress a disposition's auto-create.
     */
    @isTest
    static void selectByDispositionIds_ignoresOpportunityParentedNdas() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        TestDataFactory.createNda(opp.Id, true);
        Disposition__c disp = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);

        Test.startTest();
        List<NDA__c> rows = NdaSelector.selectByDispositionIds(new Set<Id>{ disp.Id });
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'An Opportunity-parented NDA must not appear in the Disposition read - if it did, an '
            + 'unrelated acquisition NDA could suppress a disposition\'s auto-created buyer NDA');
    }
}
