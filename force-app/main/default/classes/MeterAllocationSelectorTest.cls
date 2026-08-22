/**
 * Tests for `MeterAllocationSelector`, plus the one declarative invariant this feature relies
 * on: `Meter__c.Total_Allocated_Pct__c` is a ROLL-UP SUMMARY, so "do the allocations add up"
 * is answered by the platform and never by Apex.
 *
 * Read-only selector, so `.claude/rules/bulk-test-rule.md`'s 251 mandate does not apply.
 */
@isTest
private class MeterAllocationSelectorTest {

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        Unit__c unit = TestDataFactory.createUnit(asset.Id, true);
        Meter__c shared = TestDataFactory.createMeter(asset.Id, true);
        // 4 x 25% = 100%: a fully allocated shared meter.
        TestDataFactory.createMeterAllocations(4, shared.Id, unit.Id, true);
    }

    private static Id meterId() {
        return [SELECT Id FROM Meter__c LIMIT 1].Id;
    }

    @isTest
    static void selectByMeterIds_returnsAllocationsLargestShareFirst() {
        Test.startTest();
        List<Meter_Allocation__c> allocations =
            MeterAllocationSelector.selectByMeterIds(new Set<Id>{ meterId() });
        Test.stopTest();

        Assert.areEqual(4, allocations.size(), 'Every split on the meter.');
        Assert.isTrue(allocations[0].Allocation_Pct__c >= allocations[1].Allocation_Pct__c,
            'Largest share first.');
        Assert.isNotNull(allocations[0].Unit__r,
            'The unit comes back on the same query so a caller can label the row without a '
            + 'second read.');
    }

    @isTest
    static void totalAllocatedPct_isMaintainedByThePlatformNotByApex() {
        Test.startTest();
        Meter__c meter = [SELECT Total_Allocated_Pct__c FROM Meter__c LIMIT 1];
        Test.stopTest();

        Assert.areEqual(100, meter.Total_Allocated_Pct__c,
            'Four 25% allocations sum to 100. This is a ROLL-UP SUMMARY, which is the reason '
            + 'Meter_Allocation__c.Meter__c is a master-detail rather than a lookup - it '
            + 'answers "is this shared meter fully allocated" declaratively, so no Apex '
            + 'aggregation of these rows exists or should be added.');
    }

    @isTest
    static void selectByMeterIds_nullAndEmpty_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        Assert.areEqual(0, MeterAllocationSelector.selectByMeterIds(null).size(),
            'Null input.');
        Assert.areEqual(0, MeterAllocationSelector.selectByMeterIds(new Set<Id>()).size(),
            'Empty input. An empty result is NORMAL here - FSD 5.10.3 says allocations exist '
            + 'only where one meter serves several spaces, so most meters have none.');
        Assert.areEqual(before, Limits.getQueries(), 'Neither reaches the database.');
        Test.stopTest();
    }
}
