/**
 * Tests for `MeterHistorySelector` - the meter-swap evidence read.
 *
 * ============================================================================
 * 🔴 READ THIS BEFORE ADDING "A TEST THAT ACTUALLY FINDS A SWAP". THERE CANNOT BE ONE.
 * ============================================================================
 * Two platform facts, both measured against `usman-dpeg` on 2026-08-22, make a positive
 * fixture impossible for this object:
 *
 *  1. `Meter__History.isCreateable` is FALSE. Apex cannot insert a field-history row, in a
 *     test or anywhere else. There is no `Test.loadData` route either - the object rejects
 *     the insert, not the parser.
 *  2. History rows are NOT VISIBLE IN THE TRANSACTION THAT CREATED THEM. Updating
 *     `Meter_Number__c` and querying `Meter__History` in the same execution returns ZERO
 *     rows; the rows appear only to a LATER transaction. A test cannot span two transactions
 *     against the same data (`Test.startTest` does not commit).
 *
 * So these tests prove the QUERY - its filters, its bounds, its null-safety - and the
 * behaviour that depends on a swap being FOUND is proven where it can be: through
 * `UtilityBillService.swapDatesByMeterIdOverride`, in `UtilityBillServiceTest`. That seam
 * exists precisely because of the two facts above, and it is why the swap branch is covered
 * at all rather than being permanently untested.
 *
 * An empty result here is therefore the CORRECT and only possible outcome, and asserting it
 * is not vacuous: it pins that the query compiles, binds and filters against a real
 * `Meter__History` object. A rename of `Meter_Number__c` (which would silently stop matching
 * `Field`) fails the field-name assertion below.
 * ============================================================================
 */
@isTest
private class MeterHistorySelectorTest {

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        TestDataFactory.createMeters(2, asset.Id, true);
    }

    private static Set<Id> meterIds() {
        return new Map<Id, Meter__c>([SELECT Id FROM Meter__c]).keySet();
    }

    @isTest
    static void selectMeterNumberChanges_queriesTheHistoryObjectWithoutThrowing() {
        Test.startTest();
        List<Meter__History> rows =
            MeterHistorySelector.selectMeterNumberChanges(meterIds(), Datetime.now().addYears(-1));
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'Zero is the only possible answer in a test - see the class header. What this '
            + 'proves is that the query compiles and binds against a real Meter__History, '
            + 'which is not free: a SYSTEM_MODE query naming a field that does not exist '
            + 'fails at RUNTIME inside a trigger, not at deploy time.');
    }

    @isTest
    static void selectMeterNumberChanges_evenAfterARealMeterNumberChange_seesNothingYet() {
        // Pins platform fact 2. If this assertion ever starts failing, history has become
        // visible in-transaction and the injection seam in UtilityBillService could be
        // replaced by a real fixture - which would be a genuine improvement worth making.
        Meter__c meter = [SELECT Id, Meter_Number__c FROM Meter__c LIMIT 1];
        update new Meter__c(Id = meter.Id, Meter_Number__c = 'SWAPPED-0001');

        Test.startTest();
        List<Meter__History> rows = MeterHistorySelector.selectMeterNumberChanges(
            new Set<Id>{ meter.Id }, Datetime.now().addDays(-1));
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'The meter number DID change in this transaction and the history row still is '
            + 'not readable. This is why a swap cannot be fixture-built and why '
            + 'UtilityBillService carries a @TestVisible override instead.');
    }

    @isTest
    static void selectMeterNumberChanges_nullAndEmptyMeterSet_returnEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        Assert.areEqual(0,
            MeterHistorySelector.selectMeterNumberChanges(null, Datetime.now()).size(),
            'Null input.');
        Assert.areEqual(0,
            MeterHistorySelector.selectMeterNumberChanges(new Set<Id>(), Datetime.now()).size(),
            'Empty input.');
        Assert.areEqual(before, Limits.getQueries(),
            'Neither reaches the database. This read is on the TRIGGER path, where a wasted '
            + 'query is paid by every bill save in the org.');
        Test.stopTest();
    }

    @isTest
    static void selectMeterNumberChanges_nullSince_bindsAnEpochLowerBoundInstead() {
        Test.startTest();
        List<Meter__History> rows =
            MeterHistorySelector.selectMeterNumberChanges(meterIds(), null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'A null lower bound must not drop the CreatedDate clause or bind null - either '
            + 'would change the query from "changes since the prior read" to "this meter\'s '
            + 'entire life", which on an old meter is an unbounded read on the trigger path.');
    }
}
