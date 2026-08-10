/**
 * Tests for PropertyAssetSelector (P4 cleanup wave E — Disposition module).
 *
 * Both selector methods are now filtered to SELL CANDIDATES only:
 *   Property__c != null AND Peak_Sell_Date__c != null
 * so the Sell Meter widget shows real disposition-evaluation assets rather than
 * every Property_Asset__c row (un-parented seed junk / assets not yet on the
 * meter). These tests therefore always set BOTH Property__c and Peak_Sell_Date__c
 * on the records they expect back, and assert that records missing either are
 * excluded.
 *
 * ⚠ selectPeakSellDateById IS THE EXCEPTION TO THAT FILTER and is tested as one. It backs
 * DispositionService's sell-meter gate, which must be able to READ a null peak date —
 * a null peak is precisely what bands RED and refuses the creation. If that method ever
 * acquires the sell-candidate filter, a refusal turns into a QueryException and the user
 * gets the generic write-failure message instead of the sell-meter wording;
 * selectPeakSellDateById_nullPeakDate_stillReturnsTheRow exists to go red if it does.
 *
 * No @TestSetup: each method creates exactly the assets it needs and asserts
 * against the org total, which equals what it created (SeeAllData=false).
 *
 * No runAs USER_MODE test — Property_Asset__c is custom, FLS gap 0.
 */
@isTest
private class PropertyAssetSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectAllForMeterSummary_populatesFields() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        asset.NOI__c = 80000;
        asset.Market_Cap_Rate__c = 6.5;
        asset.Target_Sale_Price__c = 1300000;
        asset.Peak_Sell_Date__c = Date.today().addDays(45);
        insert asset;

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForMeterSummary();
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'Exactly one sell-candidate Property Asset exists');
        Assert.areEqual(80000, result[0].NOI__c, 'NOI__c should be selected');
        Assert.areEqual(6.5, result[0].Market_Cap_Rate__c, 'Market_Cap_Rate__c should be selected');
        Assert.areEqual(1300000, result[0].Target_Sale_Price__c, 'Target_Sale_Price__c should be selected');
        Assert.areEqual(Date.today().addDays(45), result[0].Peak_Sell_Date__c, 'Peak_Sell_Date__c should be selected');
    }

    @isTest
    static void selectAllForPortfolio_ordersByNameAndPopulatesFields() {
        Property__c prop = TestDataFactory.createProperty(true);
        // Factory names these 'Test Asset 0/1/2' — ORDER BY Name is ascending 0,1,2.
        // Build unsinserted so we can stamp Peak_Sell_Date__c (the filter requires it).
        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(3, prop.Id, false);
        for (Property_Asset__c a : assets) {
            a.Peak_Sell_Date__c = Date.today().addDays(45);
        }
        insert assets;

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three sell-candidate assets should return');
        for (Integer i = 1; i < result.size(); i++) {
            Assert.isTrue(result[i - 1].Name <= result[i].Name, 'Rows must be ordered by Name ascending');
        }
        Assert.areEqual('Retail', result[0].Property__r.Asset_Type__c,
            'Property__r.Asset_Type__c should be selected via the parent path');
        Assert.isNotNull(result[0].Id, 'Id must be selected for the row-mapping caller');
        Assert.isNotNull(result[0].NOI__c, 'NOI__c should be selected');
    }

    @isTest
    static void selectAllForMeterSummary_bulk251_readsAll() {
        Property__c prop = TestDataFactory.createProperty(true);
        // Build unsinserted so every one of the 251 gets a Peak_Sell_Date__c and
        // therefore qualifies under the sell-candidate filter.
        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(BULK_N, prop.Id, false);
        for (Property_Asset__c a : assets) {
            a.Peak_Sell_Date__c = Date.today().addDays(45);
        }
        insert assets;

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForMeterSummary();
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 sell-candidate assets should be read by the portfolio scan');
    }

    @isTest
    static void selectAllForPortfolio_noAssets_returnsEmpty() {
        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'With no assets the scan returns an empty list, not null');
    }

    @isTest
    static void selectAllForPortfolio_excludesNonCandidates() {
        Property__c prop = TestDataFactory.createProperty(true);

        // Candidate: non-null Property AND non-null Peak_Sell_Date -> INCLUDED.
        Property_Asset__c candidate = TestDataFactory.createPropertyAsset(prop.Id, false);
        candidate.Peak_Sell_Date__c = Date.today().addDays(20);

        // Non-candidate A: has a Property but NO peak date -> EXCLUDED.
        Property_Asset__c noPeak = TestDataFactory.createPropertyAsset(prop.Id, false);
        noPeak.Peak_Sell_Date__c = null;

        // Non-candidate B: has a peak date but a NULL Property lookup -> EXCLUDED.
        Property_Asset__c noProperty = TestDataFactory.createPropertyAsset(null, false);
        noProperty.Peak_Sell_Date__c = Date.today().addDays(20);

        insert new List<Property_Asset__c>{ candidate, noPeak, noProperty };

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the sell candidate is returned; the no-peak and no-property assets are excluded by the filter');
        Assert.areEqual(candidate.Id, result[0].Id, 'The single returned row must be the candidate');
    }

    @isTest
    static void selectAllForMeterSummary_excludesNonCandidates() {
        Property__c prop = TestDataFactory.createProperty(true);

        // Candidate — distinctive NOI marks the row we expect back.
        Property_Asset__c candidate = TestDataFactory.createPropertyAsset(prop.Id, false);
        candidate.Peak_Sell_Date__c = Date.today().addDays(20);
        candidate.NOI__c = 12345;

        // Non-candidate A: Property set, no peak date -> EXCLUDED.
        Property_Asset__c noPeak = TestDataFactory.createPropertyAsset(prop.Id, false);
        noPeak.Peak_Sell_Date__c = null;

        // Non-candidate B: peak date set, null Property lookup -> EXCLUDED.
        Property_Asset__c noProperty = TestDataFactory.createPropertyAsset(null, false);
        noProperty.Peak_Sell_Date__c = Date.today().addDays(20);

        insert new List<Property_Asset__c>{ candidate, noPeak, noProperty };

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForMeterSummary();
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the sell candidate is returned; the no-peak and no-property assets are excluded by the filter');
        Assert.areEqual(12345, result[0].NOI__c,
            'The single returned row must be the candidate (matched by its distinctive NOI)');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectPeakSellDateById — the sell-meter gate's read (fetch-for-use)
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectPeakSellDateById_returnsThePeakDate() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        asset.Peak_Sell_Date__c = Date.today().addDays(45);
        insert asset;

        Test.startTest();
        Property_Asset__c result = PropertyAssetSelector.selectPeakSellDateById(asset.Id);
        Test.stopTest();

        Assert.areEqual(asset.Id, result.Id, 'The requested asset should be returned');
        Assert.areEqual(Date.today().addDays(45), result.Peak_Sell_Date__c,
            'Peak_Sell_Date__c must be populated - it is the gate\'s only input');
    }

    /**
     * 🔴 A NULL PEAK DATE IS A ROW, NOT A MISS. DispositionService bands a null peak RED
     * and refuses the creation with a user-safe message. If this method ever filters on
     * Peak_Sell_Date__c != null the row disappears, the single-row assignment throws
     * QueryException, and the user gets "This change could not be saved. Refresh the page
     * and try again" for a permanent, deliberate refusal. This test is the fence.
     */
    @isTest
    static void selectPeakSellDateById_nullPeakDate_stillReturnsTheRow() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        asset.Peak_Sell_Date__c = null;
        insert asset;

        Test.startTest();
        Property_Asset__c result = PropertyAssetSelector.selectPeakSellDateById(asset.Id);
        Test.stopTest();

        Assert.areEqual(asset.Id, result.Id,
            'An asset with no peak date must still be READABLE - the null is what bands it RED');
        Assert.isNull(result.Peak_Sell_Date__c, 'The null peak date passes through as null');
    }

    /**
     * FETCH-FOR-USE contract: a miss throws the native System.QueryException rather than
     * returning null. That is what lets DispositionController tell a platform failure
     * (generic message) apart from a sell-meter refusal (the sell-meter wording).
     */
    @isTest
    static void selectPeakSellDateById_missingId_throwsQueryException() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Id ghostId = asset.Id;
        delete asset;

        Test.startTest();
        Boolean threw = false;
        try {
            PropertyAssetSelector.selectPeakSellDateById(ghostId);
            Assert.fail('A deleted asset Id must not resolve to a row');
        } catch (System.QueryException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'fetch-for-use: a miss throws QueryException, it does not return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // selectByPropertyIds — the Closed Won idempotency guard's read (Tranche 5A)
    //
    // ⚠ This method is the ONE `WITH SYSTEM_MODE` + `without sharing` read on this class.
    // The mode and the sharing keyword cannot be falsified by a test running as an
    // administrator, so what these tests pin is the CONTRACT the service depends on:
    // the key is Property__c alone (no Status__c filter), the field set is minimal, the
    // null/empty short-circuit costs no query, and a property with no asset is simply
    // absent. The mode/sharing decisions rest on measured repo state recorded in the
    // method header and are proved by post-deploy gate A-G4, as a non-admin persona.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectByPropertyIds_returnsTheExistingAssetsPropertyLink() {
        Property__c withAsset = TestDataFactory.createProperty(true);
        Property__c withoutAsset = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(withAsset.Id, true);

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectByPropertyIds(
            new Set<Id>{ withAsset.Id, withoutAsset.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'Only the property that already carries an asset produces a row');
        Assert.areEqual(asset.Id, result[0].Id, 'Id must be selected');
        Assert.areEqual(withAsset.Id, result[0].Property__c,
            'Property__c must be selected — the caller keys the whole guard on it');
    }

    /**
     * 🔴 NO `Status__c` FILTER. A `Disposed` asset still counts as "this property already has
     * an asset", so a re-acquisition does NOT mint a second one — D27.3's "never a second
     * asset for one property", read literally. If a future change adds
     * `AND Status__c = 'Active'` to this query, a bought-sold-rebought property silently
     * grows a rival asset and splits the whole Property Management tree in two. This test is
     * the fence.
     */
    @isTest
    static void selectByPropertyIds_disposedAssetStillCounts() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, false);
        asset.Status__c = 'Disposed';
        insert asset;

        Test.startTest();
        List<Property_Asset__c> result =
            PropertyAssetSelector.selectByPropertyIds(new Set<Id>{ prop.Id });
        Test.stopTest();

        Assert.areEqual(1, result.size(),
            'A Disposed asset must still be seen by the idempotency guard');
    }

    @isTest
    static void selectByPropertyIds_nullOrEmpty_returnsEmptyAndCostsNoQuery() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property_Asset__c> fromNull = PropertyAssetSelector.selectByPropertyIds(null);
        List<Property_Asset__c> fromEmpty =
            PropertyAssetSelector.selectByPropertyIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'A null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'An empty input returns an empty list, never null');
        Assert.areEqual(0, spent, 'Neither short-circuit may issue SOQL');
    }

    @isTest
    static void selectByPropertyIds_bulk251_readsAllInOneQuery() {
        List<Property__c> properties = TestDataFactory.createProperties(BULK_N, true);
        List<Property_Asset__c> assets = new List<Property_Asset__c>();
        for (Property__c p : properties) {
            assets.add(new Property_Asset__c(Name = p.Name, Property__c = p.Id, Status__c = 'Active'));
        }
        insert assets;
        Set<Id> ids = new Map<Id, Property__c>(properties).keySet();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Property_Asset__c> result = PropertyAssetSelector.selectByPropertyIds(ids);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 existing assets should be returned');
        Assert.areEqual(1, spent, 'A 251-Id read costs exactly one query, not 251');
    }
}
