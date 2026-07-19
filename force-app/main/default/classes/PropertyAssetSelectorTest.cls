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
}
