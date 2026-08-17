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

    // ══════════════════════════════════════════════════════════════════════════
    // PROTECTION WINDOW (2026-08-17) — selectLiveByPropertyKey / selectExpiredByPropertyKey
    //
    // The two methods are COMPLEMENTS on the same key, and the pairs below are
    // written to prove that rather than to prove each in isolation: a row is
    // either live or expired, never both and never neither. A change that made
    // both return the same row would leave an incumbent in place AND adopt over
    // them, and only the paired assertions catch it.
    // ══════════════════════════════════════════════════════════════════════════

    /** The cutoff the production code derives, expressed once here. */
    private static Datetime protectionCutoff() {
        return Datetime.now().addDays(-PropertyMatchingService.PROTECTION_WINDOW_DAYS);
    }

    /** Backdate a registration so its claim sits `days` in the past. */
    private static Property_Registry__c backdate(Property_Registry__c registry, Integer days) {
        registry.Registered_DateTime__c = Datetime.now().addDays(-days);
        update registry;
        return registry;
    }

    /**
     * Convert `leadToConvert` so its registry row reads `IsConverted = true`.
     * ⚠ The Opportunity cascade is deliberately NOT suppressed —
     * `setDoNotCreateOpportunity(true)` throws UNKNOWN_EXCEPTION on this org; this
     * mirrors PropertyClaimServiceTest's fixture exactly.
     */
    private static void convertLead(Lead leadToConvert) {
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(leadToConvert.Id);
        lc.setConvertedStatus([SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel);
        Assert.isTrue(Database.convertLead(lc).isSuccess(),
            'The fixture Lead must convert for the converted-winner rule to mean anything');
    }

    // ── selectLiveByPropertyKey ─────────────────────────────────────────────

    @isTest
    static void selectLiveByPropertyKey_claimInsideTheWindow_isStillLive() {
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('800 fresh st', winnerLeadId(), true);
        backdate(reg, PropertyMatchingService.PROTECTION_WINDOW_DAYS - 1);

        Test.startTest();
        List<Property_Registry__c> live = PropertyRegistrySelector.selectLiveByPropertyKey(
            new Set<String>{ '800 fresh st' }, protectionCutoff());
        List<Property_Registry__c> expired = PropertyRegistrySelector.selectExpiredByPropertyKey(
            '800 fresh st', protectionCutoff());
        Test.stopTest();

        Assert.areEqual(1, live.size(), 'A claim one day inside the window must still protect the property');
        Assert.areEqual(reg.Id, live[0].Id, 'The live read should return the incumbent registration');
        Assert.isTrue(expired.isEmpty(), 'The same row must NOT also read as expired — live and expired are complements');
    }

    @isTest
    static void selectLiveByPropertyKey_claimOutsideTheWindow_isNoLongerLive() {
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('801 stale st', winnerLeadId(), true);
        backdate(reg, PropertyMatchingService.PROTECTION_WINDOW_DAYS + 1);

        Test.startTest();
        List<Property_Registry__c> live = PropertyRegistrySelector.selectLiveByPropertyKey(
            new Set<String>{ '801 stale st' }, protectionCutoff());
        List<Property_Registry__c> expired = PropertyRegistrySelector.selectExpiredByPropertyKey(
            '801 stale st', protectionCutoff());
        Test.stopTest();

        Assert.isTrue(live.isEmpty(), 'A claim one day past the window must release the property');
        Assert.areEqual(1, expired.size(), 'The released row must be visible to the adoption read, or the key becomes unclaimable');
        Assert.areEqual(reg.Id, expired[0].Id, 'The expired read should return the very row that was released');
    }

    @isTest
    static void selectLiveByPropertyKey_convertedWinner_neverExpires() {
        Lead winner = TestDataFactory.createLead(true);
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('802 converted st', winner.Id, true);
        backdate(reg, PropertyMatchingService.PROTECTION_WINDOW_DAYS + 365);
        convertLead(winner);

        Test.startTest();
        List<Property_Registry__c> live = PropertyRegistrySelector.selectLiveByPropertyKey(
            new Set<String>{ '802 converted st' }, protectionCutoff());
        List<Property_Registry__c> expired = PropertyRegistrySelector.selectExpiredByPropertyKey(
            '802 converted st', protectionCutoff());
        Test.stopTest();

        Assert.areEqual(1, live.size(),
            'A converted winner is a live deal — its claim must survive a year past the window');
        Assert.isTrue(live[0].Winning_Lead__r.IsConverted,
            'The spanning field the whole rule turns on must be selected and populated');
        Assert.isTrue(expired.isEmpty(),
            'A converted winner must NEVER be adoptable — that filter is what keeps the third registry DML admissible');
    }

    @isTest
    static void selectLiveByPropertyKey_nullCutoff_failsSafeTowardTheIncumbent() {
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('803 nocutoff st', winnerLeadId(), true);
        backdate(reg, PropertyMatchingService.PROTECTION_WINDOW_DAYS + 500);

        Test.startTest();
        List<Property_Registry__c> live =
            PropertyRegistrySelector.selectLiveByPropertyKey(new Set<String>{ '803 nocutoff st' }, null);
        List<Property_Registry__c> expired =
            PropertyRegistrySelector.selectExpiredByPropertyKey('803 nocutoff st', null);
        Test.stopTest();

        // Both degrade in the SAME direction: the incumbent keeps the property. A missing
        // cutoff must never be the thing that silently releases every claim in the org.
        Assert.areEqual(1, live.size(), 'A null cutoff means "no window", so an ancient claim still reads as live');
        Assert.isTrue(expired.isEmpty(), 'A null cutoff means nothing has expired, so nothing is adoptable');
    }

    @isTest
    static void selectLiveByPropertyKey_nullOrEmptyKeys_returnsEmpty() {
        Test.startTest();
        List<Property_Registry__c> nullResult =
            PropertyRegistrySelector.selectLiveByPropertyKey(null, protectionCutoff());
        List<Property_Registry__c> emptyResult =
            PropertyRegistrySelector.selectLiveByPropertyKey(new Set<String>(), protectionCutoff());
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'Null keys should short-circuit to an empty list');
        Assert.isTrue(emptyResult.isEmpty(), 'Empty keys should short-circuit to an empty list');
    }

    @isTest
    static void selectLiveByPropertyKey_excludesOrphanRows() {
        Property_Registry__c orphan = TestDataFactory.createPropertyRegistry('804 orphan live st', winnerLeadId(), true);
        orphan.Winning_Lead__c = null; // legal post-insert (the VR is ISNEW()-scoped)
        update orphan;

        Test.startTest();
        List<Property_Registry__c> live = PropertyRegistrySelector.selectLiveByPropertyKey(
            new Set<String>{ '804 orphan live st' }, protectionCutoff());
        List<Property_Registry__c> expired = PropertyRegistrySelector.selectExpiredByPropertyKey(
            '804 orphan live st', protectionCutoff());
        Test.stopTest();

        Assert.isTrue(live.isEmpty(), 'A winner-less row is not a live claim');
        Assert.isTrue(expired.isEmpty(),
            'A winner-less row is an ORPHAN, not an expired claim — the two adoption legs must stay disjoint');
    }

    // ── selectExpiredByPropertyKey ──────────────────────────────────────────

    @isTest
    static void selectExpiredByPropertyKey_nullKeyOrCutoff_returnsEmpty() {
        Test.startTest();
        List<Property_Registry__c> nullKey =
            PropertyRegistrySelector.selectExpiredByPropertyKey(null, protectionCutoff());
        List<Property_Registry__c> blankKey =
            PropertyRegistrySelector.selectExpiredByPropertyKey('   ', protectionCutoff());
        List<Property_Registry__c> nullCutoff =
            PropertyRegistrySelector.selectExpiredByPropertyKey('805 anything st', null);
        Test.stopTest();

        Assert.isTrue(nullKey.isEmpty(), 'Null key should short-circuit to an empty list');
        Assert.isTrue(blankKey.isEmpty(), 'Blank key should short-circuit to an empty list');
        Assert.isTrue(nullCutoff.isEmpty(), 'Null cutoff should short-circuit to an empty list');
    }

    @isTest
    static void selectExpiredByPropertyKey_unregisteredKey_returnsEmpty() {
        Test.startTest();
        List<Property_Registry__c> results =
            PropertyRegistrySelector.selectExpiredByPropertyKey('806 never registered st', protectionCutoff());
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A key that was never registered has nothing to adopt');
    }

    // ── the un-windowed read is retained, and its difference is the point ───

    @isTest
    static void selectByPropertyKeyWithWinner_isTheUNWINDOWEDRead_andStillReturnsAnExpiredClaim() {
        Property_Registry__c reg = TestDataFactory.createPropertyRegistry('807 legacy st', winnerLeadId(), true);
        backdate(reg, PropertyMatchingService.PROTECTION_WINDOW_DAYS + 30);

        Test.startTest();
        List<Property_Registry__c> unwindowed =
            PropertyRegistrySelector.selectByPropertyKeyWithWinner(new Set<String>{ '807 legacy st' });
        List<Property_Registry__c> windowed = PropertyRegistrySelector.selectLiveByPropertyKey(
            new Set<String>{ '807 legacy st' }, protectionCutoff());
        Test.stopTest();

        // This pair IS the defect the protection window closed, pinned so it cannot be
        // reintroduced by quietly swapping the claim path back to the older method.
        Assert.areEqual(1, unwindowed.size(),
            'selectByPropertyKeyWithWinner is deliberately un-windowed and still sees an expired claim');
        Assert.isTrue(windowed.isEmpty(),
            'selectLiveByPropertyKey must NOT — that difference is the whole feature');
    }
}
