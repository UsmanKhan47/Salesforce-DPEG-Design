@isTest
private class SellMeterControllerTest {
    @testSetup
    static void setup() {
        Property__c pA = new Property__c(Name = 'Prop A', Asset_Type__c = 'Retail');
        Property__c pB = new Property__c(Name = 'Prop B', Asset_Type__c = 'Multifamily');
        Property__c pC = new Property__c(Name = 'Prop C', Asset_Type__c = 'Office');
        insert new List<Property__c>{ pA, pB, pC };

        // Readiness band is driven by days until Peak_Sell_Date__c:
        //   Asset A: peak in 15 days  → GREEN  (<= 30)
        //   Asset B: peak in 60 days  → YELLOW (31-90)
        //   Asset C: peak in 120 days → RED    (> 90)
        //   Asset D: no peak date     → RED    (null guard)
        // NOI/Cap/Target still drive impliedValue + the portfolio-upside metric.
        // All use NOI=1000000, Cap=5.0 → Implied=20000000; only A is above target (upside 2M).
        Date today = Date.today();
        insert new List<Property_Asset__c>{
            new Property_Asset__c(Name = 'Test Asset A', Property__c = pA.Id,
                NOI__c = 1000000, Market_Cap_Rate__c = 5.0, Target_Sale_Price__c = 18000000,
                Argus_Signal__c = 'Sell Now', Peak_Sell_Date__c = today.addDays(15)),
            new Property_Asset__c(Name = 'Test Asset B', Property__c = pB.Id,
                NOI__c = 1000000, Market_Cap_Rate__c = 5.0, Target_Sale_Price__c = 20500000,
                Argus_Signal__c = '12 mo', Peak_Sell_Date__c = today.addDays(60)),
            new Property_Asset__c(Name = 'Test Asset C', Property__c = pC.Id,
                NOI__c = 1000000, Market_Cap_Rate__c = 5.0, Target_Sale_Price__c = 22000000,
                Argus_Signal__c = 'Hold', Peak_Sell_Date__c = today.addDays(120)),
            new Property_Asset__c(Name = 'Test Asset D', Property__c = pA.Id,
                NOI__c = null, Market_Cap_Rate__c = null, Target_Sale_Price__c = null)
        };
    }

    @isTest
    static void testThresholds() {
        Test.startTest();
        List<SellMeterController.PropertyRow> rows = SellMeterController.getPortfolio();
        Test.stopTest();

        System.assertEquals(4, rows.size(), 'Four assets expected');

        // Results are ORDER BY Name so A/B/C/D is deterministic.
        SellMeterController.PropertyRow a = rows[0];
        System.assertEquals('GREEN', a.sellMeter, 'Asset A: peak in 15 days should be GREEN');
        System.assertNotEquals(null, a.impliedValue, 'Implied value should be computed for A');
        System.assertEquals('Sell Now', a.argusSignal, 'Argus signal should pass through');
        System.assertEquals('Retail', a.assetType, 'Asset type cross-object lookup should resolve');

        SellMeterController.PropertyRow b = rows[1];
        System.assertEquals('YELLOW', b.sellMeter, 'Asset B: peak in 60 days should be YELLOW');

        SellMeterController.PropertyRow c = rows[2];
        System.assertEquals('RED', c.sellMeter, 'Asset C: peak in 120 days should be RED');

        SellMeterController.PropertyRow d = rows[3];
        System.assertEquals('RED', d.sellMeter, 'Asset D: no peak date should be RED');
        System.assertEquals(null, d.impliedValue, 'Asset D: null NOI should leave impliedValue null');
    }

    @isTest
    static void testMeterSummary() {
        Test.startTest();
        SellMeterController.MeterSummary s = SellMeterController.getMeterSummary();
        Test.stopTest();

        System.assertEquals(1, s.green, 'One asset (A) within 30 days of peak');
        System.assertEquals(1, s.yellow, 'One asset (B) 30-90 days from peak');
        System.assertEquals(2, s.red, 'Two assets (C far out, D no date)');
        // Only Asset A is in the money: implied 20M - target 18M = 2M upside.
        System.assertEquals(2000000, s.upside, 'Portfolio upside is Asset A only');
    }
}