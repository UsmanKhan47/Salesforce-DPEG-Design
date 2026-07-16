/**
 * @description Test class for SellMeterController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Reported coverage was 0% going into this pass; the prior test methods
 * already exercised the GREEN/YELLOW/RED banding and the summary rollup
 * thoroughly, so the 0% most likely reflects "not yet executed by
 * RunLocalTests" rather than a defect — see the final report. Adds exact
 * boundary coverage (30 / 90 days), an empty-portfolio scenario, and a
 * 251-record data-volume read test per .claude/rules/bulk-test-rule.md.
 * @author Unit Testing Agent
 */
@isTest
private class SellMeterControllerTest {

    @testSetup
    static void setup() {
        Property__c pA = TestDataFactory.createProperty(false);
        pA.Asset_Type__c = 'Retail';
        Property__c pB = TestDataFactory.createProperty(false);
        pB.Asset_Type__c = 'Multifamily';
        Property__c pC = TestDataFactory.createProperty(false);
        pC.Asset_Type__c = 'Office';
        insert new List<Property__c>{ pA, pB, pC };

        // Readiness band is driven by days until Peak_Sell_Date__c:
        //   Asset 0: peak in 15 days  -> GREEN  (<= 30)
        //   Asset 1: peak in 60 days  -> YELLOW (31-90)
        //   Asset 2: peak in 120 days -> RED    (> 90)
        //   Asset 3: no peak date     -> RED    (null guard)
        // All use NOI=1,000,000, Cap=5.0 -> Implied=20,000,000; only Asset 0 is
        // above its target (18M), giving a 2M portfolio upside.
        Date today = Date.today();
        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(4, pA.Id, false);
        assets[0].Property__c = pA.Id;
        assets[0].NOI__c = 1000000;
        assets[0].Market_Cap_Rate__c = 5.0;
        assets[0].Target_Sale_Price__c = 18000000;
        assets[0].Argus_Signal__c = 'Sell Now';
        assets[0].Peak_Sell_Date__c = today.addDays(15);

        assets[1].Property__c = pB.Id;
        assets[1].NOI__c = 1000000;
        assets[1].Market_Cap_Rate__c = 5.0;
        assets[1].Target_Sale_Price__c = 20500000;
        assets[1].Argus_Signal__c = '12 mo';
        assets[1].Peak_Sell_Date__c = today.addDays(60);

        assets[2].Property__c = pC.Id;
        assets[2].NOI__c = 1000000;
        assets[2].Market_Cap_Rate__c = 5.0;
        assets[2].Target_Sale_Price__c = 22000000;
        assets[2].Argus_Signal__c = 'Hold';
        assets[2].Peak_Sell_Date__c = today.addDays(120);

        assets[3].Property__c = pA.Id;
        assets[3].NOI__c = null;
        assets[3].Market_Cap_Rate__c = null;
        assets[3].Target_Sale_Price__c = null;
        assets[3].Argus_Signal__c = null;
        assets[3].Peak_Sell_Date__c = null;

        insert assets;
    }

    @isTest
    static void testGetPortfolio_bandThresholds() {
        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        Test.stopTest();

        System.assertEquals(4, rows.size(), 'Four assets expected');

        // Results are ORDER BY Name; factory names 'Test Asset 0..3' sort in insertion order.
        SellMeterController.PropertyRow a0 = rows[0];
        System.assertEquals('GREEN', a0.sellMeter, 'Asset 0: peak in 15 days should be GREEN');
        System.assertNotEquals(null, a0.impliedValue, 'Implied value should be computed for asset 0');
        System.assertEquals('Sell Now', a0.argusSignal, 'Argus signal should pass through');
        System.assertEquals('Retail', a0.assetType, 'Asset type cross-object lookup should resolve');

        SellMeterController.PropertyRow a1 = rows[1];
        System.assertEquals('YELLOW', a1.sellMeter, 'Asset 1: peak in 60 days should be YELLOW');

        SellMeterController.PropertyRow a2 = rows[2];
        System.assertEquals('RED', a2.sellMeter, 'Asset 2: peak in 120 days should be RED');

        SellMeterController.PropertyRow a3 = rows[3];
        System.assertEquals('RED', a3.sellMeter, 'Asset 3: no peak date should be RED');
        System.assertEquals(null, a3.impliedValue, 'Asset 3: null NOI should leave impliedValue null');
    }

    @isTest
    static void testGetMeterSummary_aggregatesBandsAndUpside() {
        Test.startTest();
        SellMeterController.MeterSummary s = SellMeterController.getMeterSummary();
        Test.stopTest();

        System.assertEquals(1, s.green, 'One asset (0) within 30 days of peak');
        System.assertEquals(1, s.yellow, 'One asset (1) 30-90 days from peak');
        System.assertEquals(2, s.red, 'Two assets (2 far out, 3 no date)');
        // Only Asset 0 is in the money: implied 20M - target 18M = 2M upside.
        System.assertEquals(2000000, s.upside, 'Portfolio upside is asset 0 only');
    }

    @isTest
    static void testBandForPeak_exactBoundaries_30And90Days() {
        delete [SELECT Id FROM Property_Asset__c];
        Property__c prop = TestDataFactory.createProperty(true);
        Date today = Date.today();
        List<Property_Asset__c> assets = TestDataFactory.createPropertyAssets(2, prop.Id, false);
        assets[0].Peak_Sell_Date__c = today.addDays(30);
        assets[1].Peak_Sell_Date__c = today.addDays(90);
        insert assets;

        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        Test.stopTest();

        Map<Id, SellMeterController.PropertyRow> byId = new Map<Id, SellMeterController.PropertyRow>();
        for (SellMeterController.PropertyRow r : rows) {
            byId.put(Id.valueOf(r.id), r);
        }
        System.assertEquals('GREEN', byId.get(assets[0].Id).sellMeter, 'Exactly 30 days out should still be GREEN (<=30)');
        System.assertEquals('YELLOW', byId.get(assets[1].Id).sellMeter, 'Exactly 90 days out should still be YELLOW (<=90)');
    }

    @isTest
    static void testGetPortfolio_noAssets_returnsEmptyResults() {
        delete [SELECT Id FROM Property_Asset__c];

        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        SellMeterController.MeterSummary summary = SellMeterController.getMeterSummary();
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'No Property_Asset__c records exist, so getPortfolio should return an empty list');
        System.assertEquals(0, summary.green + summary.yellow + summary.red, 'No assets means every band count should be zero');
        System.assertEquals(0, summary.upside, 'No assets means portfolio upside should be zero');
    }

    /**
     * Data-volume read scenario per .claude/rules/bulk-test-rule.md: 251
     * Property_Asset__c rows inserted via a single bulk DML statement, to
     * prove the org-wide (no WHERE clause) query and per-row band/implied-value
     * computation in getPortfolio/getMeterSummary scale without a CPU-time or
     * heap-size breach. Filters the returned rows down to just the newly
     * inserted set so the assertion count matches the 251 inserted, per the
     * rule, despite the 4 @TestSetup assets also being visible to this query.
     */
    @isTest
    static void testGetPortfolio_251NewAssets_allRowsProcessed() {
        SellMeterController.MeterSummary before = SellMeterController.getMeterSummary();

        Property__c seedProperty = [SELECT Id FROM Property__c LIMIT 1];
        List<Property_Asset__c> bulkAssets = TestDataFactory.createPropertyAssets(251, seedProperty.Id, false);
        Date farOut = Date.today().addDays(200); // > 90 days out => RED for every new asset
        for (Property_Asset__c a : bulkAssets) {
            a.Peak_Sell_Date__c = farOut;
        }
        insert bulkAssets;
        Set<Id> bulkAssetIds = new Map<Id, Property_Asset__c>(bulkAssets).keySet();

        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        SellMeterController.MeterSummary after = SellMeterController.getMeterSummary();
        Test.stopTest();

        Integer matched = 0;
        for (SellMeterController.PropertyRow r : rows) {
            if (bulkAssetIds.contains(Id.valueOf(r.id))) {
                matched++;
                System.assertEquals('RED', r.sellMeter, 'Every bulk asset is 200 days from peak, so it should band RED');
            }
        }
        System.assertEquals(251, matched, 'All 251 newly inserted assets should be present in getPortfolio results');
        System.assertEquals(251, after.red - before.red, 'The red bucket should grow by exactly the 251 newly inserted assets');
    }
}
