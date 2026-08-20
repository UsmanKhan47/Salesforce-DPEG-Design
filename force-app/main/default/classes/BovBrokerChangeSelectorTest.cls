/**
 * @description Tests BovBrokerChangeSelector — the one read against the disposition BOV's
 * append-only broker-replacement log (2026-08-20, Tranche 2 Workstream B / design D4.6).
 *
 * Covers: field population, the newest-first ordering and its same-transaction tie-break, parent
 * scoping, the empty-result contract, the null guard, and the documented 200-row cap under a
 * 251-record data volume (.claude/rules/bulk-test-rule.md).
 *
 * ⚠ WHY THE BULK TEST ASSERTS 200 AND NOT 251, DELIBERATELY. `.claude/rules/bulk-test-rule.md`
 * mandates a 251-record volume and this test inserts 251 — but the method under test carries an
 * explicit `LIMIT 200` defensive cap, so returning 251 rows would mean the cap had been silently
 * removed. The 251 rows are the volume; 200 is the correct ANSWER to that volume, and asserting it
 * is what makes the cap a tested contract rather than a comment. (This is not the
 * `.claude/rules/content-publication-rule.md` exemption — `BOV_Broker_Change__c` is an ordinary
 * custom object and consumes no ContentPublication quota.)
 *
 * ⚠ THE FIXTURE ROWS ARE BUILT BY `TestDataFactory.createBovBrokerChanges`, NOT BY CALLING THE
 * SERVICE. In production `BovSubmissionService.replaceSelectedBroker` is the only legitimate writer,
 * but a read test that had to perform 251 whole broker swaps to get 251 rows would be testing the
 * writer. The WRITE is proved in `BovSubmissionServiceTest`; this class proves only the read.
 *
 * NO `System.runAs` USER_MODE TEST, AND THAT IS A GAP WORTH NAMING. The query is `WITH USER_MODE`
 * and every column on this object is a 2026-08-20 custom field granted by `DPEG_Disposition_View` /
 * `DPEG_Disposition_Edit`; a genuine FLS regression (a permission-set deploy dropping one field —
 * which REPLACES the whole grant list, so it is a live risk) would surface as a QueryException here
 * and no test in this class would catch it. The same reasoning `BovSubmissionSelectorTest` records
 * applies — the runAs assertion is reserved for standard-object selectors — but on THIS object the
 * risk is real rather than theoretical, because the grant is one deploy old.
 *
 * @see force-app/main/default/classes/BovBrokerChangeSelector.cls
 */
@isTest
private class BovBrokerChangeSelectorTest {

    private static final Integer BULK_N = 251;
    /** Mirrors BovBrokerChangeSelector.HISTORY_LIMIT — asserted, not assumed. */
    private static final Integer EXPECTED_CAP = 200;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(asset.Id, true);
    }

    private static Id dispositionId() {
        return [SELECT Id FROM Disposition__c LIMIT 1].Id;
    }

    private static Id secondDispositionId() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        return TestDataFactory.createDisposition(asset.Id, true).Id;
    }

    @isTest
    static void selectByDispositionId_populatesEverySelectedField() {
        Id dispId = dispositionId();
        BOV_Broker_Change__c seeded = TestDataFactory.createBovBrokerChange(dispId, true);

        Test.startTest();
        List<BOV_Broker_Change__c> result = BovBrokerChangeSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'The one seeded change must be read');
        BOV_Broker_Change__c row = result[0];
        Assert.areEqual(seeded.Id, row.Id, 'Id');
        Assert.isNotNull(row.Name, 'The BBC- AutoNumber must be selected — it is displayed AND it '
            + 'is the ORDER BY tie-break');
        Assert.areEqual(dispId, row.Disposition__c, 'The parent anchor must be selected');
        Assert.areEqual('Outgoing Brokerage 0', row.Outgoing_Broker_Firm__c,
            'The outgoing firm SNAPSHOT is the display value — see the field\'s own header for why '
            + 'it is not read through the Contact lookup');
        Assert.areEqual('Incoming Brokerage 0', row.Incoming_Broker_Firm__c, 'Incoming firm');
        Assert.areEqual('Performance Issue', row.Reason__c, 'Reason');
        Assert.areEqual('Test broker change 0', row.Notes__c, 'Notes');
        Assert.isNotNull(row.Entry_DateTime__c, 'Entry_DateTime__c');
        Assert.isNotNull(row.Logged_By__r,
            'The Logged_By__r RELATIONSHIP must be traversed, not just the lookup Id — a client '
            + 'reading .Name off a null relationship silently renders blank');
        Assert.areEqual(UserInfo.getName(), row.Logged_By__r.Name,
            'User.Name is a standard, always-readable field, which is what makes this traversal '
            + 'safe under USER_MODE (same argument as LeaseActivitySelector)');
    }

    /**
     * 🔴 NEWEST FIRST IS THE WHOLE POINT OF AN APPEND-ONLY LOG'S READ. The most recent broker change
     * is the one that explains the disposition's CURRENT broker; burying it under older rows makes
     * the card answer the wrong question.
     */
    @isTest
    static void selectByDispositionId_ordersNewestFirst() {
        Id dispId = dispositionId();
        // The factory descends Entry_DateTime__c by one minute per index, so index 0 is the newest
        // — and it is inserted FIRST, so a selector that fell back on insert order would still pass
        // this. The reversed-insert assertion below is what closes that hole.
        List<BOV_Broker_Change__c> seeded = TestDataFactory.createBovBrokerChanges(3, dispId, false);
        List<BOV_Broker_Change__c> reversed = new List<BOV_Broker_Change__c>{
            seeded[2], seeded[1], seeded[0]
        };
        insert reversed;

        Test.startTest();
        List<BOV_Broker_Change__c> result = BovBrokerChangeSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three changes must be read');
        Assert.areEqual(seeded[0].Id, result[0].Id,
            '🔴 THE NEWEST Entry_DateTime__c MUST COME FIRST — and it was inserted LAST here, so an '
            + 'implementation that leaned on insert order or on Id ASC fails this assertion');
        Assert.areEqual(seeded[1].Id, result[1].Id, 'Then the next-newest');
        Assert.areEqual(seeded[2].Id, result[2].Id, 'Then the oldest');
    }

    /**
     * The `Name DESC` tie-break, which only matters for rows sharing an `Entry_DateTime__c` — the
     * normal case for anything written in one transaction against the frozen test clock, and a real
     * case in production for two replacements inside the same second.
     */
    @isTest
    static void selectByDispositionId_sameInstantRows_areOrderedDeterministicallyByName() {
        Id dispId = dispositionId();
        Datetime shared = Datetime.newInstance(2026, 8, 20, 9, 30, 0);
        List<BOV_Broker_Change__c> rows = TestDataFactory.createBovBrokerChanges(3, dispId, false);
        for (BOV_Broker_Change__c row : rows) {
            row.Entry_DateTime__c = shared;
        }
        insert rows;

        Test.startTest();
        List<BOV_Broker_Change__c> result = BovBrokerChangeSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three must be read');
        // AutoNumbers are assigned in insert order, so DESC returns them last-inserted first. The
        // claim under test is DETERMINISM, not any particular direction: an untie-broken query may
        // return these three in any order at all.
        Assert.isTrue(result[0].Name > result[1].Name && result[1].Name > result[2].Name,
            'Rows sharing an Entry_DateTime__c must fall back on Name DESC, giving a stable order '
            + 'instead of an arbitrary one. Got: ' + result[0].Name + ', ' + result[1].Name + ', '
            + result[2].Name);
    }

    @isTest
    static void selectByDispositionId_isScopedToItsParent() {
        Id mine = dispositionId();
        Id theirs = secondDispositionId();
        TestDataFactory.createBovBrokerChanges(2, mine, true);
        TestDataFactory.createBovBrokerChanges(3, theirs, true);

        Test.startTest();
        List<BOV_Broker_Change__c> result = BovBrokerChangeSelector.selectByDispositionId(mine);
        Test.stopTest();

        Assert.areEqual(2, result.size(),
            'Another sale\'s broker history must never appear on this disposition\'s card');
        for (BOV_Broker_Change__c row : result) {
            Assert.areEqual(mine, row.Disposition__c, 'Every row must belong to the queried parent');
        }
    }

    /**
     * 🔴 EMPTY IS THE COMMON CASE, NOT AN EDGE CASE — most dispositions never replace a broker. The
     * contract is an empty List and never null, so the client can render "No broker changes
     * recorded" without having to tell empty apart from broken.
     */
    @isTest
    static void selectByDispositionId_noChanges_returnsEmptyListNotNull() {
        Id dispId = dispositionId();

        Test.startTest();
        List<BOV_Broker_Change__c> result = BovBrokerChangeSelector.selectByDispositionId(dispId);
        Test.stopTest();

        Assert.isNotNull(result, 'Never null — a null would NPE the controller\'s for-loop');
        Assert.areEqual(0, result.size(), 'A disposition with no replacements reads as empty');
    }

    @isTest
    static void selectByDispositionId_null_returnsEmptyListWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<BOV_Broker_Change__c> result = BovBrokerChangeSelector.selectByDispositionId(null);
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'A null parent reads as empty');
        Assert.areEqual(before, after,
            'The null guard must return BEFORE the SOQL — a query issued for a null parent spends a '
            + 'governor limit to learn nothing');
    }

    /**
     * 251 rows in, 200 out — the documented defensive cap, tested. See the class header for why the
     * assertion is 200 rather than the 251 the bulk rule's table names.
     */
    @isTest
    static void selectByDispositionId_bulk251_isCappedAtTheDocumentedLimit() {
        Id dispId = dispositionId();
        TestDataFactory.createBovBrokerChanges(BULK_N, dispId, true);

        Test.startTest();
        List<BOV_Broker_Change__c> result = BovBrokerChangeSelector.selectByDispositionId(dispId);
        Assert.areEqual(1, Limits.getQueries(),
            'One query for 251 rows — no SOQL in any loop');
        Test.stopTest();

        Assert.areEqual(EXPECTED_CAP, result.size(),
            'The LIMIT is a defensive cap against a data defect, not a page size. If this reads 251 '
            + 'the cap has been removed; if it reads something else, HISTORY_LIMIT changed and this '
            + 'constant was not updated with it.');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM BOV_Broker_Change__c WHERE Disposition__c = :dispId],
            'PRECONDITION: all 251 rows really were inserted — otherwise the cap assertion above '
            + 'would pass against a fixture that never reached the limit');
    }
}
