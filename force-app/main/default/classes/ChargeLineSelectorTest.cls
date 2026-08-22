/**
 * Tests for `ChargeLineSelector`.
 *
 * Read-only, so `.claude/rules/bulk-test-rule.md`'s 251 mandate does not apply (it exists to
 * force a second trigger batch firing, which a query has no equivalent of).
 */
@isTest
private class ChargeLineSelectorTest {

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        Meter__c meter = TestDataFactory.createMeter(asset.Id, true);
        List<Utility_Bill__c> bills = TestDataFactory.createUtilityBills(2, meter.Id, true);
        TestDataFactory.createChargeLines(4, bills[0].Id, true);
        TestDataFactory.createChargeLines(1, bills[1].Id, true);
    }

    private static List<Utility_Bill__c> bills() {
        return [SELECT Id FROM Utility_Bill__c ORDER BY Read_Date__c];
    }

    @isTest
    static void selectByBillIds_returnsComponentsLargestFirst() {
        Id billId = bills()[0].Id;

        Test.startTest();
        List<Charge_Line__c> lines =
            ChargeLineSelector.selectByBillIds(new Set<Id>{ billId });
        Test.stopTest();

        Assert.areEqual(4, lines.size(), 'Every component on that bill.');
        Assert.isTrue(lines[0].Charge_Amount__c >= lines[1].Charge_Amount__c,
            'Largest amount first, so the driver of a variance is the first row a reviewer '
            + 'sees during the monthly review.');
    }

    @isTest
    static void selectByBillIds_severalBills_areReturnedTogetherAndGroupedByBill() {
        Set<Id> ids = new Map<Id, Utility_Bill__c>(bills()).keySet();

        Test.startTest();
        List<Charge_Line__c> lines = ChargeLineSelector.selectByBillIds(ids);
        Test.stopTest();

        Assert.areEqual(5, lines.size(),
            'One query serves N bills - the caller must never loop a query per bill.');
        Assert.areEqual(lines[0].Utility_Bill__c, lines[1].Utility_Bill__c,
            'ORDER BY Utility_Bill__c first, so a caller can bucket the rows in one pass.');
    }

    @isTest
    static void selectByBillIds_nullAndEmpty_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        Assert.areEqual(0, ChargeLineSelector.selectByBillIds(null).size(), 'Null input.');
        Assert.areEqual(0, ChargeLineSelector.selectByBillIds(new Set<Id>()).size(),
            'Empty input.');
        Assert.areEqual(before, Limits.getQueries(), 'Neither reaches the database.');
        Test.stopTest();
    }
}
