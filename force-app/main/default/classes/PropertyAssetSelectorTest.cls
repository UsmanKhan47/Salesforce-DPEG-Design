/**
 * Tests for PropertyAssetSelector (P4 cleanup wave E — Disposition module).
 *
 * Both selector methods are unfiltered full-object reads (the Sell Meter is
 * portfolio-wide), so these tests deliberately use NO @TestSetup: each method
 * creates exactly the assets it needs and asserts against the org total, which
 * equals what it created (SeeAllData=false).
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

        Assert.areEqual(1, result.size(), 'Exactly one Property Asset exists');
        Assert.areEqual(80000, result[0].NOI__c, 'NOI__c should be selected');
        Assert.areEqual(6.5, result[0].Market_Cap_Rate__c, 'Market_Cap_Rate__c should be selected');
        Assert.areEqual(1300000, result[0].Target_Sale_Price__c, 'Target_Sale_Price__c should be selected');
        Assert.areEqual(Date.today().addDays(45), result[0].Peak_Sell_Date__c, 'Peak_Sell_Date__c should be selected');
    }

    @isTest
    static void selectAllForPortfolio_ordersByNameAndPopulatesFields() {
        Property__c prop = TestDataFactory.createProperty(true);
        // Factory names these 'Test Asset 0/1/2' — ORDER BY Name is ascending 0,1,2.
        TestDataFactory.createPropertyAssets(3, prop.Id, true);

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(3, result.size(), 'All three assets should return');
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
        TestDataFactory.createPropertyAssets(BULK_N, prop.Id, true);

        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForMeterSummary();
        Test.stopTest();

        Assert.areEqual(BULK_N, result.size(), 'All 251 assets should be read by the portfolio-wide scan');
    }

    @isTest
    static void selectAllForPortfolio_noAssets_returnsEmpty() {
        Test.startTest();
        List<Property_Asset__c> result = PropertyAssetSelector.selectAllForPortfolio();
        Test.stopTest();

        Assert.areEqual(0, result.size(), 'With no assets the scan returns an empty list, not null');
    }
}
