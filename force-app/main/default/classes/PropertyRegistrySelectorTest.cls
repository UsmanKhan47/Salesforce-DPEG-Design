/**
 * Test class for PropertyRegistrySelector. Covers all three selector methods:
 * exact-key winner lookup, recent-with-winner (with its LIMIT 200 cap), and
 * orphan-by-key. Per ARCHITECTURE.md §2 all SOQL is in the selector, so these
 * tests call the selector directly rather than through a service.
 *
 * @author Unit Testing Agent
 */
@isTest
private class PropertyRegistrySelectorTest {

    @TestSetup
    static void setupTestData() {
        TestDataFactory.createLead(true);
    }

    private static Id winnerLeadId() {
        return [SELECT Id FROM Lead LIMIT 1].Id;
    }

    // ── selectByPropertyKeyWithWinner ───────────────────────────────────────

    @isTest
    static void selectByPropertyKeyWithWinner_exactKeyMatch_returnsRow() {
        Id winnerId = winnerLeadId();
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('100 main st', winnerId, true);

        Test.startTest();
        List<Property_Registry__c> results =
            PropertyRegistrySelector.selectByPropertyKeyWithWinner(new Set<String>{ '100 main st' });
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Exact key match should return the one registered row');
        Assert.areEqual(reg.Id, results[0].Id, 'Returned row should be the registered property');
        Assert.areEqual(winnerId, results[0].Winning_Lead__c, 'Winning_Lead__c should be populated');
    }

    @isTest
    static void selectByPropertyKeyWithWinner_excludesNullWinnerRows() {
        Id winnerId = winnerLeadId();
        Property_Registry__c orphan = TestDataFactory.createPropertyRegistry('200 orphan st', winnerId, true);
        orphan.Winning_Lead__c = null; // legal post-insert (VR is ISNEW()-scoped only)
        update orphan;

        Test.startTest();
        List<Property_Registry__c> results =
            PropertyRegistrySelector.selectByPropertyKeyWithWinner(new Set<String>{ '200 orphan st' });
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A row with a null Winning_Lead__c must never be returned as a "claimed" match');
    }

    @isTest
    static void selectByPropertyKeyWithWinner_nullOrEmptyKeys_returnsEmpty() {
        Test.startTest();
        List<Property_Registry__c> nullResult = PropertyRegistrySelector.selectByPropertyKeyWithWinner(null);
        List<Property_Registry__c> emptyResult =
            PropertyRegistrySelector.selectByPropertyKeyWithWinner(new Set<String>());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null keys should short-circuit to an empty list, never null');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty keys should short-circuit to an empty list');
    }

    @isTest
    static void selectByPropertyKeyWithWinner_bulk251_returnsAll251() {
        Id winnerId = winnerLeadId();
        List<Property_Registry__c> registries = TestDataFactory.createPropertyRegistries(251, winnerId, true);
        Set<String> keys = new Set<String>();
        for (Property_Registry__c r : registries) {
            keys.add(r.Property_Key__c);
        }

        Test.startTest();
        List<Property_Registry__c> results = PropertyRegistrySelector.selectByPropertyKeyWithWinner(keys);
        Test.stopTest();

        Assert.areEqual(251, results.size(),
            'All 251 registered keys with a winner should be returned by one query (no LIMIT on this selector)');
    }

    // ── selectRecentWithWinner ───────────────────────────────────────────────

    @isTest
    static void selectRecentWithWinner_returnsNewestFirstWithinCutoff() {
        Id winnerId = winnerLeadId();
        Property_Registry__c older = TestDataFactory.createPropertyRegistry('300 older st', winnerId, false);
        older.Registered_DateTime__c = Datetime.now().addDays(-5);
        Property_Registry__c newer = TestDataFactory.createPropertyRegistry('400 newer st', winnerId, false);
        newer.Registered_DateTime__c = Datetime.now().addDays(-1);
        insert new List<Property_Registry__c>{ older, newer };

        Test.startTest();
        List<Property_Registry__c> results = PropertyRegistrySelector.selectRecentWithWinner(Datetime.now().addDays(-10));
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Both registrations within the cutoff window should be returned');
        Assert.areEqual(newer.Id, results[0].Id, 'Newest registration should be first (ORDER BY Registered_DateTime__c DESC)');
        Assert.areEqual(older.Id, results[1].Id, 'Older registration should be second');
    }

    @isTest
    static void selectRecentWithWinner_excludesRowsBeforeCutoff() {
        Id winnerId = winnerLeadId();
        Property_Registry__c tooOld = TestDataFactory.createPropertyRegistry('500 too old st', winnerId, false);
        tooOld.Registered_DateTime__c = Datetime.now().addDays(-100);
        insert tooOld;

        Test.startTest();
        List<Property_Registry__c> results = PropertyRegistrySelector.selectRecentWithWinner(Datetime.now().addDays(-30));
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A registration older than the cutoff should be excluded');
    }

    @isTest
    static void selectRecentWithWinner_nullCutoff_returnsEmpty() {
        Test.startTest();
        List<Property_Registry__c> results = PropertyRegistrySelector.selectRecentWithWinner(null);
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A null cutoff should short-circuit to an empty list');
    }

    @isTest
    static void selectRecentWithWinner_bulk251_cappedAtLimit200() {
        Id winnerId = winnerLeadId();
        TestDataFactory.createPropertyRegistries(251, winnerId, true);

        Test.startTest();
        List<Property_Registry__c> results = PropertyRegistrySelector.selectRecentWithWinner(Datetime.now().addDays(-1));
        Test.stopTest();

        Assert.areEqual(200, results.size(),
            'The selector\'s LIMIT 200 must cap the result set even when 251 rows qualify by cutoff');
    }

    // ── selectOrphanByPropertyKey ────────────────────────────────────────────

    @isTest
    static void selectOrphanByPropertyKey_returnsOrphanRow() {
        Id winnerId = winnerLeadId();
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('600 orphan candidate st', winnerId, true);
        reg.Winning_Lead__c = null;
        update reg;

        Test.startTest();
        List<Property_Registry__c> results =
            PropertyRegistrySelector.selectOrphanByPropertyKey('600 orphan candidate st');
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'The orphaned (winner-nulled) row should be returned');
        Assert.areEqual(reg.Id, results[0].Id, 'Returned row should be the orphaned registry');
        Assert.isNull(results[0].Winning_Lead__c, 'Orphan row should still have a null winner');
    }

    @isTest
    static void selectOrphanByPropertyKey_keyHasLiveWinner_returnsEmpty() {
        Id winnerId = winnerLeadId();
        TestDataFactory.createPropertyRegistry('700 claimed st', winnerId, true);

        Test.startTest();
        List<Property_Registry__c> results = PropertyRegistrySelector.selectOrphanByPropertyKey('700 claimed st');
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A key with a live winner is not an orphan and must not be returned');
    }

    @isTest
    static void selectOrphanByPropertyKey_blankKey_returnsEmpty() {
        Test.startTest();
        List<Property_Registry__c> nullResult = PropertyRegistrySelector.selectOrphanByPropertyKey(null);
        List<Property_Registry__c> blankResult = PropertyRegistrySelector.selectOrphanByPropertyKey('   ');
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null key should short-circuit to an empty list');
        Assert.isTrue(blankResult.isEmpty(), 'Blank key should short-circuit to an empty list');
    }
}
