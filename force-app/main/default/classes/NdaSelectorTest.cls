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
        // 'Sent': it is the acquisition sequence's TERMINAL (no hop at all) and a mid-sequence hop
        // to 'Signed' on the disposition one. ⚠ This line read "(acquisition -> Received,
        // disposition -> Signed)" until the acquisition reorder of 2026-08-16
        // (Pending -> Received -> Signed -> Sent), which moved 'Sent' from second position to last;
        // the divergence it illustrates got SHARPER, not weaker — one record type now refuses where
        // the other writes. Narrowing the SELECT does not
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

    // ═════════════════════════════════════════════════════════════════════════
    // queryExpiryAlerts — the reminder job's WORK QUEUE (FSD Tranche 1, Item 2)
    //
    // 🔴 EVERY FILTER BELOW IS A SEPARATE WAY TO SHIP THE FEATURE WRONG, AND TWO OF THEM SHIP IT
    // WRONG *SILENTLY*: a locator that returns nothing produces an all-zeros finish() summary
    // indistinguishable from "no NDA is expiring". They are tested one at a time for that reason.
    //
    // ⚠ These tests run the locator through `Database.getQueryLocator` and iterate it, because the
    // filters and the ORDER BY are exactly the half a direct `NdaExpiryAlertBatch.execute(...)`
    // call skips.
    // ═════════════════════════════════════════════════════════════════════════

    /** Drain the reminder locator into a list of Ids, in locator order. */
    private static List<Id> expiryAlertIds() {
        List<Id> ids = new List<Id>();
        Database.QueryLocator locator = NdaSelector.queryExpiryAlerts();
        Database.QueryLocatorIterator it = locator.iterator();
        while (it.hasNext()) {
            ids.add(((NDA__c) it.next()).Id);
        }
        return ids;
    }

    /** A SIGNED acquisition NDA expiring `days` from today. */
    private static NDA__c signedAcquisitionNdaExpiringIn(Id opportunityId, Integer days) {
        NDA__c nda = TestDataFactory.createSignedNdas(1, opportunityId, false)[0];
        nda.NDA_Expiry_Date__c = Date.today().addDays(days);
        insert nda;
        return nda;
    }

    @isTest
    static void queryExpiryAlerts_selectsASignedAcquisitionNdaInsideTheCeiling() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = signedAcquisitionNdaExpiringIn(opp.Id, 3);

        Test.startTest();
        List<Id> ids = expiryAlertIds();
        Test.stopTest();

        Assert.isTrue(ids.contains(nda.Id),
            'A signed acquisition NDA three days from expiry is exactly the population this job '
            + 'exists for');
    }

    /**
     * 🔴 THE FINDING-A TEST. The obvious implementation of "acquisition NDAs only" —
     * `RecordType.DeveloperName = 'Acquisition_NDA'` — returns ZERO ROWS for every un-migrated row
     * until post-deploy gate T-A1/T-B, because every live NDA still sits on MASTER. The job would
     * run daily, log all zeros and look completely healthy.
     *
     * This test deliberately creates its NDA with **no record type stamped at all**, which is the
     * migration-window shape, and requires it to be selected anyway. A record-type filter fails
     * here; the `Opportunity__c != NULL` discriminator passes.
     */
    @isTest
    static void queryExpiryAlerts_selectsAnAcquisitionNdaWithNoRecordTypeStamped() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = new NDA__c(
            Opportunity__c = opp.Id,
            Status__c = 'Signed',
            NDA_Signed__c = true,
            Date_Signed__c = Date.today(),
            Is_Non_Expiring__c = false,
            NDA_Expiry_Date__c = Date.today().addDays(2),
            Counterparty_Name__c = 'Master-type Counterparty'
        );
        insert nda;

        Test.startTest();
        List<Id> ids = expiryAlertIds();
        Test.stopTest();

        Assert.isTrue(ids.contains(nda.Id),
            '🔴 The discriminator is Opportunity__c != NULL, NOT the record type. A record-type '
            + 'filter would miss this row — and every live acquisition NDA is this shape until '
            + 'post-deploy gate T-A1/T-B, so the feature would ship INERT while looking healthy');
    }

    @isTest
    static void queryExpiryAlerts_ignoresADispositionNda() {
        // The other half of the discriminator: a sell-side NDA carries Disposition__c and a NULL
        // Opportunity__c, so the split is exact and survives the migration in both directions.
        Disposition__c disp = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        NDA__c nda = TestDataFactory.createDispositionNda(disp.Id, false);
        nda.Status__c = 'Signed';
        nda.NDA_Signed__c = true;
        nda.NDA_Expiry_Date__c = Date.today().addDays(2);
        insert nda;

        Test.startTest();
        List<Id> ids = expiryAlertIds();
        Test.stopTest();

        Assert.isFalse(ids.contains(nda.Id),
            'A disposition NDA is not the Acquisition team\'s to chase');
    }

    @isTest
    static void queryExpiryAlerts_ignoresANonExpiringNda() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createSignedNdas(1, opp.Id, false)[0];
        nda.NDA_Expiry_Date__c = Date.today().addDays(2);
        nda.Is_Non_Expiring__c = true;
        insert nda;

        Test.startTest();
        List<Id> ids = expiryAlertIds();
        Test.stopTest();

        Assert.isFalse(ids.contains(nda.Id),
            'Is_Non_Expiring__c = true means the date is not a deadline — matching the deployed '
            + 'NDAs_Expiring_This_Month report, so the report and the reminder cannot disagree');
    }

    @isTest
    static void queryExpiryAlerts_ignoresAnUnsignedNda() {
        // Gate 1 decision Q2.1(a): SIGNED only, matching the deployed report exactly. An NDA still
        // being chased is a different problem with a different owner.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createNda(opp.Id, false); // seeds at 'Pending'
        nda.NDA_Expiry_Date__c = Date.today().addDays(2);
        insert nda;

        Test.startTest();
        List<Id> ids = expiryAlertIds();
        Test.stopTest();

        Assert.isFalse(ids.contains(nda.Id),
            'Only Signed NDAs are reminded about — Status__c = \'Signed\' matches the deployed '
            + 'Acquisitions/NDAs_Expiring_This_Month report');
    }

    @isTest
    static void queryExpiryAlerts_ignoresAnNdaWithNoExpiryDateAtAll() {
        // ⚠ Note this also covers the NDA auto-created by OpportunityReviewService on every
        // Opportunity insert, which carries no expiry date — so it can never pollute the queue.
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c nda = TestDataFactory.createSignedNdas(1, opp.Id, false)[0];
        nda.NDA_Expiry_Date__c = null;
        insert nda;

        Test.startTest();
        List<Id> ids = expiryAlertIds();
        Test.stopTest();

        Assert.isFalse(ids.contains(nda.Id), 'No expiry date means no countdown and no reminder');
    }

    @isTest
    static void queryExpiryAlerts_appliesTheCeilingButDeliberatelyNoFloor() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c beyondCeiling = signedAcquisitionNdaExpiringIn(opp.Id, 6);
        NDA__c onCeiling = signedAcquisitionNdaExpiringIn(opp.Id, 5);
        NDA__c longExpired = signedAcquisitionNdaExpiringIn(opp.Id, -120);

        Test.startTest();
        List<Id> ids = expiryAlertIds();
        Test.stopTest();

        Assert.isFalse(ids.contains(beyondCeiling.Id),
            'Six days out is outside the widest rung and is never even read');
        Assert.isTrue(ids.contains(onCeiling.Id),
            'and the ceiling is inclusive at exactly the widest rung — narrowing it below 5 is the '
            + 'ONLY way to break this feature');
        Assert.isTrue(ids.contains(longExpired.Id),
            '🔴 THERE IS DELIBERATELY NO FLOOR. An NDA whose expiry passed with no marker genuinely '
            + 'is owed its one reminder; the monotone marker is what stops it spamming. Adding a '
            + 'floor is an ALERT-LOSS decision, not a tuning knob');
    }

    @isTest
    static void queryExpiryAlerts_ordersBySoonestExpiryWithAnIdTieBreak() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        NDA__c later = signedAcquisitionNdaExpiringIn(opp.Id, 4);
        NDA__c sooner = signedAcquisitionNdaExpiringIn(opp.Id, 1);

        Test.startTest();
        List<Id> ids = expiryAlertIds();
        Test.stopTest();

        Assert.isTrue(ids.indexOf(sooner.Id) < ids.indexOf(later.Id),
            'Soonest expiry first. ⚠ NDA_Expiry_Date__c is a Date, so many rows share one value — '
            + 'the Id ASC tie-break is what keeps chunk composition deterministic between passes');
    }

    /**
     * 251 rows through the real locator. `.claude/rules/bulk-test-rule.md`, no exemption claimed.
     *
     * ⚠ They share ONE parent Opportunity on purpose: 251 Opportunities would cost 251
     * auto-created NDAs and 251 Primary_NDA__c stamps in the fixture, which measures the fixture
     * rather than the locator. The discriminator under test is `Opportunity__c != NULL`, not which
     * deal it points at.
     */
    @isTest
    static void queryExpiryAlerts_bulk251RowsAreAllSelectedAndOrdered() {
        Opportunity opp = TestDataFactory.createOpportunity(null, true);
        List<NDA__c> ndas = TestDataFactory.createSignedNdas(BULK_N, opp.Id, false);
        for (Integer i = 0; i < ndas.size(); i++) {
            ndas[i].NDA_Expiry_Date__c = Date.today().addDays(Math.mod(i, 6));
        }
        insert ndas;

        Test.startTest();
        List<Id> ids = expiryAlertIds();
        Test.stopTest();

        Set<Id> selected = new Set<Id>(ids);
        Integer inside = 0;
        for (NDA__c nda : ndas) {
            if (selected.contains(nda.Id)) {
                inside++;
            }
        }
        Assert.areEqual(BULK_N, inside,
            'All 251 rows are inside the ceiling (0-5 days) and all 251 are selected');
    }


    // ═══════════════════════════════════════════════════════════════════════════════════════
    // 🔴 SEVEN `selectSignedBuyerNdas_*` TESTS WERE DELETED HERE ON 2026-08-21, WITH THE METHOD.
    // ═══════════════════════════════════════════════════════════════════════════════════════
    // `NdaSelector.selectSignedBuyerNdasByDispositionId` backed the Log Offer buyer picker. DPEG
    // communicates only with the appointed listing broker, so the picker was removed and the
    // query lost its only caller.
    //
    // ⚠ THIS IS RECORDED RATHER THAN SILENTLY DROPPED BECAUSE THE TESTS WERE THE VALUABLE HALF.
    // They were four NEGATIVE tests — one per predicate — each asserting ABSENCE, which is the
    // only shape that catches a dropped filter:
    //   `Party_Role__c = 'Buyer'`   the INTRODUCING BROKER becomes a buyer option;
    //   `Status__c = 'Signed'`      an unsigned or DECLINED party stays selectable;
    //   `Buyer__c != NULL`          a legacy NDA produces an option with no Contact Id in it;
    //   `Disposition__c = :id`      another sale's buyer appears on this one.
    // 🔴 IF A BUYER-SHAPED READ IS EVER REBUILT, RECOVER THESE FROM GIT HISTORY RATHER THAN
    // RE-DERIVING THEM. Three of the four predicates are non-obvious and one of them
    // (`Party_Role__c`) is the one most easily forgotten and the most damaging to forget.
    //
    // ⚠ `selectBuyerTimelineByDispositionId` IS STILL HERE AND ITS TESTS LIVE IN
    // `DispositionBuyerTimelineTest`, NOT IN THIS CLASS. It was retargeted the same day (it now
    // selects `Name` and `Broker__c` instead of the buyer fields) and it was NOT deleted — do not
    // read this block as covering both.
}
