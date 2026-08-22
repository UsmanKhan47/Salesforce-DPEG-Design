/**
 * Tests for `UtilityBillSelector`, including the two access decisions this feature depends on:
 * the SYSTEM_MODE trigger-path chain read, and the `without sharing` batch locator.
 *
 * These are READS, so `.claude/rules/bulk-test-rule.md`'s 251 mandate (which exists to force
 * a second trigger batch firing) does not apply - a query behaves identically at 6 rows and
 * at 251. The volume proofs live in `UtilityBillTriggerTest`.
 */
@isTest
private class UtilityBillSelectorTest {

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        List<Meter__c> meters = TestDataFactory.createMeters(2, asset.Id, true);
        List<Utility_Bill__c> a = TestDataFactory.createUtilityBills(3, meters[0].Id, true);
        TestDataFactory.createUtilityBills(2, meters[1].Id, true);
        // Charge lines on the newest bill of meter A so the roll-up and rate are non-zero.
        TestDataFactory.createChargeLine(a[2].Id, 345, true);
        TestDataFactory.createChargeLine(a[1].Id, 200, true);
    }

    /**
     * Reads every row a locator would hand a batch.
     *
     * DO NOT re-run `locator.getQuery()` through `Database.query` instead. That string still
     * contains the platform's BIND PLACEHOLDERS, so the run fails with
     * `System.QueryException: Variable does not exist: tmpVar1` - which reads like a broken
     * query rather than like the wrong way to consume a locator. Measured here, twice.
     */
    private static List<Utility_Bill__c> drain(Database.QueryLocator locator) {
        List<Utility_Bill__c> rows = new List<Utility_Bill__c>();
        Database.QueryLocatorIterator it = locator.iterator();
        while (it.hasNext()) {
            rows.add((Utility_Bill__c) it.next());
        }
        return rows;
    }

    private static List<Meter__c> meters() {
        return [SELECT Id FROM Meter__c ORDER BY Meter_Number__c];
    }

    @isTest
    static void selectChainByMeterIds_returnsTheWholeChainOldestFirst() {
        Id meterA = meters()[0].Id;

        Test.startTest();
        List<Utility_Bill__c> chain =
            UtilityBillSelector.selectChainByMeterIds(new Set<Id>{ meterA });
        Test.stopTest();

        Assert.areEqual(3, chain.size(), 'Every bill for that meter, not a window.');
        Assert.isTrue(chain[0].Read_Date__c < chain[1].Read_Date__c,
            'ORDER BY Read_Date__c ASC. The chain is sequenced by the READ date, not the bill '
            + 'date - FSD 5.10.5 keeps them separate and it is the read that bounds the '
            + 'consumption period.');
        Assert.areEqual(0, UtilityBillSelector.selectChainByMeterIds(null).size(),
            'Null is safe - this runs inside a trigger.');
        Assert.areEqual(0,
            UtilityBillSelector.selectChainByMeterIds(new Set<Id>()).size(), 'Empty is safe.');
    }

    @isTest
    static void selectChainByMeterIds_doesNotLeakAcrossMeters() {
        Id meterA = meters()[0].Id;

        Test.startTest();
        List<Utility_Bill__c> chain =
            UtilityBillSelector.selectChainByMeterIds(new Set<Id>{ meterA });
        Test.stopTest();

        for (Utility_Bill__c b : chain) {
            Assert.areEqual(meterA, b.Meter__c,
                'A chain that crossed meters would compare readings taken from two different '
                + 'physical registers and call the difference consumption.');
        }
    }

    @isTest
    static void selectDetailById_carriesThePriorBillTotals() {
        Utility_Bill__c newest = [
            SELECT Id FROM Utility_Bill__c
            WHERE Prior_Utility_Bill__c != NULL
            ORDER BY Read_Date__c DESC LIMIT 1];

        Test.startTest();
        Utility_Bill__c detail = UtilityBillSelector.selectDetailById(newest.Id);
        Test.stopTest();

        Assert.isNotNull(detail, 'The bill exists and is visible.');
        Assert.isNotNull(detail.Prior_Utility_Bill__r,
            'The prior bill must come back on the same query - the variance panel explains '
            + 'the figure by naming what it was measured against.');
        Assert.isNotNull(detail.Meter__r.Meter_Number__c,
            'And the meter, so the panel does not need a second read.');
    }

    @isTest
    static void selectDetailById_missingOrNull_returnsNullRatherThanThrowing() {
        Test.startTest();
        Assert.isNull(UtilityBillSelector.selectDetailById(null),
            'A null Id is not an error - the component renders its empty state.');
        Test.stopTest();
    }

    @isTest
    static void selectRecentByMeterIds_newestFirst_andRespectsTheCap() {
        Set<Id> ids = new Map<Id, Meter__c>([SELECT Id FROM Meter__c]).keySet();

        Test.startTest();
        List<Utility_Bill__c> all = UtilityBillSelector.selectRecentByMeterIds(ids, 100);
        List<Utility_Bill__c> capped = UtilityBillSelector.selectRecentByMeterIds(ids, 2);
        List<Utility_Bill__c> coerced = UtilityBillSelector.selectRecentByMeterIds(ids, -5);
        List<Utility_Bill__c> defaulted = UtilityBillSelector.selectRecentByMeterIds(ids, null);
        Test.stopTest();

        Assert.areEqual(5, all.size(), 'Five bills across both meters.');
        Assert.isTrue(all[0].Read_Date__c >= all[1].Read_Date__c,
            'Newest read first - the register list shows the latest figures.');
        Assert.areEqual(2, capped.size(), 'The cap is honoured.');
        Assert.areEqual(1, coerced.size(),
            'A negative limit is coerced to 1, not passed to SOQL where it throws.');
        Assert.areEqual(5, defaulted.size(), 'A null limit falls back to the default of 200.');
        Assert.areEqual(0, UtilityBillSelector.selectRecentByMeterIds(null, 10).size(),
            'Null meter set is safe.');
    }

    @isTest
    static void queryVarianceSweep_returnsOnlyBillsThatHaveAPrior() {
        Test.startTest();
        List<Utility_Bill__c> found =
            drain(UtilityBillSelector.queryVarianceSweep(Datetime.now().addDays(-1)));
        Test.stopTest();

        Assert.isFalse(found.isEmpty(), 'The sweep finds the chained bills.');
        for (Utility_Bill__c b : found) {
            Assert.isNotNull(b.Prior_Utility_Bill__c,
                'A bill with no prior has no variance at all, so sweeping it would cost a '
                + 'row and a threshold test to reach a guaranteed no.');
        }
    }

    @isTest
    static void queryVarianceSweep_nullCutoff_meansEverything() {
        Test.startTest();
        Database.QueryLocator locator = UtilityBillSelector.queryVarianceSweep(null);
        Test.stopTest();

        Assert.isTrue(locator.getQuery().contains('LastModifiedDate'),
            'A null cutoff still binds a lower bound (the epoch) rather than dropping the '
            + 'clause, so the query shape - and its selectivity - never changes.');
    }

    @isTest
    static void queryVarianceSweep_futureCutoff_findsNothing() {
        Test.startTest();
        List<Utility_Bill__c> found =
            drain(UtilityBillSelector.queryVarianceSweep(Datetime.now().addDays(1)));
        Test.stopTest();

        Assert.areEqual(0, found.size(),
            'The look-back window is what replaces an idempotency marker field on this '
            + 'feature: a bill untouched since the last run is not re-alerted. If this ever '
            + 'returns rows, the window is not being applied and the alert will repeat daily '
            + 'until the team stops reading it.');
    }
}
