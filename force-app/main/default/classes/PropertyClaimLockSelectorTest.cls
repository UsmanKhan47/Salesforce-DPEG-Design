/**
 * Test class for PropertyClaimLockSelector: the concurrency-control lock-partition
 * selector backing PropertyClaimService's W4 FOR UPDATE serialization. Per
 * ARCHITECTURE.md §2 all SOQL is in the selector, so these tests call the selector
 * directly rather than through PropertyClaimService.
 *
 * NOTE on bulk-test scope (.claude/rules/bulk-test-rule.md): both selector methods
 * take a single clusterKey String (not a collection), matching the existing
 * single-key precedent in this module — PropertyRegistrySelector.selectOrphanByPropertyKey
 * also takes one key and has no 251-bulk test in PropertyRegistrySelectorTest, since a
 * bulk scenario would not exercise a different code path for a single-value lookup.
 *
 * @author Unit Testing Agent
 */
@isTest
private class PropertyClaimLockSelectorTest {

    // ── selectByClusterKey (no lock) ─────────────────────────────────────────

    @isTest
    static void selectByClusterKey_existingRow_returnsIt() {
        Property_Claim_Lock__c lockRow = TestDataFactory.createPropertyClaimLock('100 main', true);

        Test.startTest();
        List<Property_Claim_Lock__c> results = PropertyClaimLockSelector.selectByClusterKey('100 main');
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'The existing lock row for the cluster key should be returned');
        Assert.areEqual(lockRow.Id, results[0].Id, 'The returned row should be the one inserted for this cluster key');
    }

    @isTest
    static void selectByClusterKey_unregisteredKey_returnsEmpty() {
        Test.startTest();
        List<Property_Claim_Lock__c> results = PropertyClaimLockSelector.selectByClusterKey('999 never claimed');
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A cluster key with no lock row yet should return an empty list, not null');
    }

    @isTest
    static void selectByClusterKey_blankKey_returnsEmpty() {
        Test.startTest();
        List<Property_Claim_Lock__c> nullResult = PropertyClaimLockSelector.selectByClusterKey(null);
        List<Property_Claim_Lock__c> blankResult = PropertyClaimLockSelector.selectByClusterKey('   ');
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(), 'A null cluster key should short-circuit to an empty list, never querying');
        Assert.isTrue(blankResult.isEmpty(), 'A blank (whitespace) cluster key should short-circuit to an empty list');
    }

    // ── selectByClusterKeyForUpdate (FOR UPDATE lock) ────────────────────────

    @isTest
    static void selectByClusterKeyForUpdate_existingRow_returnsLockedRow() {
        Property_Claim_Lock__c lockRow = TestDataFactory.createPropertyClaimLock('200 main', true);

        Test.startTest();
        List<Property_Claim_Lock__c> results = PropertyClaimLockSelector.selectByClusterKeyForUpdate('200 main');
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'The existing lock row should be returned WITH a FOR UPDATE lock held');
        Assert.areEqual(lockRow.Id, results[0].Id, 'The returned row should be the one inserted for this cluster key');
    }

    @isTest
    static void selectByClusterKeyForUpdate_unregisteredKey_returnsEmpty() {
        Test.startTest();
        List<Property_Claim_Lock__c> results =
            PropertyClaimLockSelector.selectByClusterKeyForUpdate('999 never claimed for update');
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'A cluster key with no lock row yet should return an empty list, not null');
    }

    @isTest
    static void selectByClusterKeyForUpdate_blankKey_returnsEmpty() {
        Test.startTest();
        List<Property_Claim_Lock__c> nullResult = PropertyClaimLockSelector.selectByClusterKeyForUpdate(null);
        List<Property_Claim_Lock__c> blankResult = PropertyClaimLockSelector.selectByClusterKeyForUpdate('   ');
        Test.stopTest();

        Assert.isTrue(nullResult.isEmpty(),
            'A null cluster key should short-circuit to an empty list, never attempting a FOR UPDATE query');
        Assert.isTrue(blankResult.isEmpty(), 'A blank (whitespace) cluster key should short-circuit to an empty list');
    }
}
