/**
 * Tests for PropertySelector (Tranche 5A — the first and only `Property__c` SOQL in the
 * application).
 *
 * The class holds ONE method, `selectAssetSeedByIds`, which backs
 * `PropertyAssetService.ensureOnClosedWon`. Three properties are worth pinning and each has
 * its own test: the FIELD SET (an asset cannot be built without both values), the
 * NULL/EMPTY contract (the caller must be able to short-circuit without a wasted query), and
 * the NOT-FOUND contract (an Id that resolves to nothing is absent from the result rather
 * than a null row — that absence is what makes the service skip instead of building a
 * nameless asset that would fail the whole deal close).
 *
 * ⚠ NO `System.runAs` MODE TEST, AND THAT IS NOT AN OMISSION. The query is
 * `WITH SYSTEM_MODE` inside a `private without sharing` inner class specifically so that the
 * running principal's FLS and sharing cannot change the answer — so a bare-user `runAs`
 * asserting "it still returns rows" would pass whether or not the inner class existed, and
 * would therefore falsify nothing. What the decision actually rests on is measured org/repo
 * state (`Property__c` is `sharingModel = Private`; `viewAllRecords` comes from four
 * permission sets none of which `DPEG_Transaction_Team` holds), recorded in the selector's
 * header. The real proof is post-deploy gate A-G4, run AS a Transactions persona.
 *
 * No @TestSetup: each method builds exactly the rows it needs and asserts against them.
 */
@isTest
private class PropertySelectorTest {

    /** Matches the repo-standard bulk count (.claude/rules/bulk-test-rule.md). */
    private static final Integer BULK_N = 251;

    /**
     * THE FIELD SET IS THE CONTRACT. `Name` becomes `Property_Asset__c.Name`, which is a
     * MANDATORY Text field — losing it turns a deal close into a REQUIRED_FIELD_MISSING
     * rollback. `Asset_Type__c` feeds the `Property_Type__c` allow-list map. Narrowing this
     * SELECT breaks the caller, so both are asserted by value rather than by non-null.
     */
    @isTest
    static void selectAssetSeedByIds_returnsNameAndAssetType() {
        Property__c prop = TestDataFactory.createProperty(true);

        Test.startTest();
        List<Property__c> result =
            PropertySelector.selectAssetSeedByIds(new Set<Id>{ prop.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'The one requested property should be returned');
        Assert.areEqual(prop.Id, result[0].Id, 'Id must be selected — it becomes the asset lookup');
        Assert.areEqual('Test Property 0', result[0].Name,
            'Name must be selected — it becomes the mandatory Property_Asset__c.Name');
        Assert.areEqual('Retail', result[0].Asset_Type__c,
            'Asset_Type__c must be selected — it is the only input to the Property_Type__c map');
    }

    /**
     * A property Id that no longer resolves is simply ABSENT, not a null row. That absence is
     * what `PropertyAssetService` counts as `runSkippedUnreadableProperty` and skips, instead
     * of building an asset with no Name and failing the entire deal close for every other deal
     * in the same chunk.
     */
    @isTest
    static void selectAssetSeedByIds_missingId_isAbsentNotNull() {
        Property__c live = TestDataFactory.createProperty(true);
        Property__c doomed = TestDataFactory.createProperty(true);
        Id ghostId = doomed.Id;
        delete doomed;

        Test.startTest();
        List<Property__c> result =
            PropertySelector.selectAssetSeedByIds(new Set<Id>{ live.Id, ghostId });
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the surviving property comes back; a deleted Id yields no row at all');
        Assert.areEqual(live.Id, result[0].Id, 'The surviving row is the one that is returned');
    }

    /**
     * NULL/EMPTY SHORT-CIRCUIT. The wrapper returns an empty list WITHOUT issuing SOQL, which
     * is what lets the caller's "a chunk that closes no deal costs zero queries" budget hold.
     * The query count is asserted, not just the return value — returning empty after paying
     * for a query would satisfy a naive assertion while breaking the budget.
     */
    @isTest
    static void selectAssetSeedByIds_nullOrEmpty_returnsEmptyAndCostsNoQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> fromNull = PropertySelector.selectAssetSeedByIds(null);
        List<Property__c> fromEmpty = PropertySelector.selectAssetSeedByIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'An empty input returns an empty list, never null');
        Assert.areEqual(0, spent, 'Neither short-circuit may issue SOQL');
    }

    /**
     * Bulk read per .claude/rules/bulk-test-rule.md: 251 properties in ONE call, one query.
     * A read has no trigger chunking, so what this actually pins is that the caller never
     * degrades into a per-record query — the same property the service's own budget test
     * asserts from the other side.
     */
    @isTest
    static void selectAssetSeedByIds_bulk251_readsAllInOneQuery() {
        List<Property__c> properties = TestDataFactory.createProperties(BULK_N, true);
        Set<Id> ids = new Map<Id, Property__c>(properties).keySet();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> result = PropertySelector.selectAssetSeedByIds(ids);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 properties should be returned');
        Assert.areEqual(1, spent, 'A 251-Id read costs exactly one query, not 251');
    }
}
