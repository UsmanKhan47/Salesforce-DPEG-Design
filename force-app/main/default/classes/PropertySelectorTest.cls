/**
 * Tests for PropertySelector — now THREE methods, not one (added 2026-08-11 for the SharePoint
 * deal-folder feature): `selectAssetSeedByIds` (Tranche 5A, `PropertyAssetService`),
 * `selectFolderStateByIds` and `queryFolderSweep` (the SharePoint feature, `DealFolderService` /
 * `DealFolderSweepBatch`).
 *
 * For `selectAssetSeedByIds`: three properties are worth pinning and each has its own test: the
 * FIELD SET (an asset cannot be built without both values), the NULL/EMPTY contract (the caller
 * must be able to short-circuit without a wasted query), and the NOT-FOUND contract (an Id that
 * resolves to nothing is absent from the result rather than a null row — that absence is what
 * makes the service skip instead of building a nameless asset that would fail the whole deal
 * close).
 *
 * For `selectFolderStateByIds` / `queryFolderSweep`: the FIELD SET (all four SharePoint fields plus
 * `Name`, the folder-name source), the NULL/EMPTY short-circuit for the by-Ids method, and the
 * NOT-FOUND contract mirroring the asset-seed method's. `queryFolderSweep`'s own WHERE-clause
 * discrimination (Pending/Failed included, Created/Skipped excluded) is proven end-to-end through
 * `DealFolderSweepBatchTest` instead of re-asserted here at the raw-locator level, since a
 * `Database.QueryLocator` exposes no row-count API a selector test could assert against directly.
 *
 * ⚠ NO `System.runAs` MODE/SHARING TEST FOR ANY OF THE THREE METHODS, AND THAT IS NOT AN OMISSION.
 * Every one of them is `WITH SYSTEM_MODE` inside a `private without sharing` inner class
 * specifically so that the running principal's FLS and sharing cannot change the answer — a
 * bare-user `runAs` asserting "it still returns rows" would pass whether or not the inner class
 * existed, and would therefore falsify nothing (the same reasoning already recorded here for
 * `selectAssetSeedByIds`, and in `DealFolderServiceTest`'s header for the SharePoint pair). What the
 * decision actually rests on is measured org/repo state — `Property__c` is `sharingModel =
 * Private`; its one sharing rule is an owner rule scoped to the `Acquisition` queue, which does not
 * reach a `LeadConvertService`-owned Property; `viewAllRecords` comes from four permission sets
 * none of which `DPEG_Transaction_Team` holds — recorded in the selector's own header for both
 * inner classes. The real proof is a post-deploy gate run AS a genuinely under-provisioned persona
 * (e.g. `DPEG_Transaction_Team`), never an Apex `runAs` block, which cannot falsify a
 * `SYSTEM_MODE`/`without sharing` read at all.
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

    // ═════════════════════════════════════════════════════════════════════════════════════
    // selectFolderStateByIds — added 2026-08-11 for the SharePoint deal-folder feature
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** THE FIELD SET IS THE CONTRACT: `Name` is the folder-name source, the three SharePoint
     *  fields are the idempotency guard and the stamp-without-a-second-read optimisation. */
    @isTest
    static void selectFolderStateByIds_returnsNameAndAllFourSharePointFields() {
        Property__c prop = TestDataFactory.createProperty(true);
        update new Property__c(
            Id = prop.Id,
            SharePoint_Folder_ID__c = 'item-77',
            SharePoint_Folder_URL__c = 'https://contoso.sharepoint.com/x/item-77',
            SharePoint_Folder_Status__c = 'Created'
        );

        Test.startTest();
        List<Property__c> result = PropertySelector.selectFolderStateByIds(new Set<Id>{ prop.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(), '');
        Assert.areEqual('Test Property 0', result[0].Name,
            'Name must be selected — it is the source DealFolderService.sanitizeFolderName sanitizes');
        Assert.areEqual('item-77', result[0].SharePoint_Folder_ID__c,
            'The idempotency guard field must be selected');
        Assert.areEqual('https://contoso.sharepoint.com/x/item-77', result[0].SharePoint_Folder_URL__c, '');
        Assert.areEqual('Created', result[0].SharePoint_Folder_Status__c, '');
    }

    @isTest
    static void selectFolderStateByIds_missingId_isAbsentNotNull() {
        Property__c live = TestDataFactory.createProperty(true);
        Property__c doomed = TestDataFactory.createProperty(true);
        Id ghostId = doomed.Id;
        delete doomed;

        Test.startTest();
        List<Property__c> result =
            PropertySelector.selectFolderStateByIds(new Set<Id>{ live.Id, ghostId });
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Only the surviving property comes back');
        Assert.areEqual(live.Id, result[0].Id, '');
    }

    @isTest
    static void selectFolderStateByIds_nullOrEmpty_returnsEmptyAndCostsNoQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> fromNull = PropertySelector.selectFolderStateByIds(null);
        List<Property__c> fromEmpty = PropertySelector.selectFolderStateByIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), '');
        Assert.areEqual(0, spent,
            'Neither short-circuit may issue SOQL — this is what keeps a chunk that closes no deal '
            + 'at ZERO queries on the DealFolderService side');
    }

    /** Bulk read per .claude/rules/bulk-test-rule.md: 251 properties in ONE call, one query — the
     *  same property `DealFolderService.claimFolders` relies on for its constant-per-chunk budget. */
    @isTest
    static void selectFolderStateByIds_bulk251_readsAllInOneQuery() {
        List<Property__c> properties = TestDataFactory.createProperties(BULK_N, true);
        Set<Id> ids = new Map<Id, Property__c>(properties).keySet();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property__c> result = PropertySelector.selectFolderStateByIds(ids);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 properties should be returned');
        Assert.areEqual(1, spent, 'A 251-Id read costs exactly one query, not 251');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // queryFolderSweep — added 2026-08-11 for DealFolderSweepBatch
    // ═════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void queryFolderSweep_returnsANonNullLocator() {
        Test.startTest();
        Database.QueryLocator locator = PropertySelector.queryFolderSweep();
        Test.stopTest();

        Assert.isNotNull(locator, 'The batch\'s start() depends on this never being null');
    }

    /**
     * The WHERE-clause discrimination itself (Pending/Failed included, Created/Skipped excluded)
     * is proven end-to-end through `DealFolderSweepBatchTest`
     * (`sweepBatch_createdAndSkippedRows_areNeverTouchedByTheBatch`), which can observe the effect
     * — which rows the batch actually touches — since a `Database.QueryLocator` exposes no
     * row-count or content API a selector-level test could assert against directly without driving
     * it through real batch execution. Deliberately not re-proven here at the raw-locator level.
     */
}
