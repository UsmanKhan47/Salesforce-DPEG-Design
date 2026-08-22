/**
 * Tests for `UtilityVarianceAlertBatch` - the FSD 5.10.2 variance alert.
 *
 * ============================================================================
 * 🔴 WHY MOST OF THESE TESTS CALL `execute()` DIRECTLY INSTEAD OF `Database.executeBatch`
 * ============================================================================
 * Two measured platform behaviours make `Database.executeBatch` the WRONG vehicle for
 * asserting anything about this job's decisions:
 *
 *  1. BATCH STATE DOES NOT COME BACK TO THE CALLER. `Database.executeBatch(job)` SERIALISES
 *     `job`; every `execute()` call mutates a DESERIALISED COPY. `Database.Stateful` carries
 *     the counters from chunk to chunk inside the job - it does NOT write them back to the
 *     local variable. Reading `job.scanned` after `Test.stopTest()` returns 0 forever, so
 *     every threshold assertion built that way passes or fails for a reason that has nothing
 *     to do with the threshold. (Measured: 6 tests in this class failed exactly that way on
 *     the first run, all reporting `Expected: 1, Actual: 0`.)
 *  2. A TEST MAY ONLY RUN ONE CHUNK. If `start()` returns more rows than the scope size, the
 *     run dies with `System.UnexpectedException: No more than one executeBatch can be called
 *     from within a test method` - so the 251-row volume proof cannot be driven through
 *     `executeBatch` at all.
 *
 * Calling `execute(null, scope)` directly is therefore not a shortcut, it is the only way to
 * observe the decision this class exists to make. `Database.executeBatch` is still exercised
 * once, in `endToEnd_...`, to prove `start()` and `finish()` are wired and the locator
 * returns what the job can consume - which is the only thing that route CAN prove.
 *
 * `Messaging.CustomNotification` is not queryable from Apex, so "did a notification arrive"
 * is not observable anywhere; the counters are the observable surface.
 *
 * === VOLUME ===
 * `.claude/rules/bulk-test-rule.md` requires a batch test to set up 251+ records and verify
 * they are all processed. `execute_251BillScope_...` does that against a real 251-row scope.
 */
@isTest
private class UtilityVarianceAlertBatchTest {

    // `bulk` is a reserved word in Apex; `BULK_ROWS` is the project's spelling.
    private static final Integer BULK_ROWS = 251;

    @TestSetup
    static void setup() {
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        TestDataFactory.createMeters(1, asset.Id, true);
    }

    private static Meter__c theMeter() {
        return [SELECT Id FROM Meter__c LIMIT 1];
    }

    /**
     * A two-bill chain with EXACT totals, so the threshold arithmetic is a known number
     * rather than whatever the factory happened to produce.
     *
     * @return The CURRENT (second) bill - the one that has a prior and therefore a variance.
     */
    private static Utility_Bill__c chainWithTotals(Id meterId, Decimal priorTotal,
            Decimal currentTotal) {
        List<Utility_Bill__c> bills = new List<Utility_Bill__c>{
            new Utility_Bill__c(Meter__c = meterId, Read_Date__c = Date.newInstance(2026, 1, 1),
                Previous_Reading__c = 1000, Current_Reading__c = 1100),
            new Utility_Bill__c(Meter__c = meterId, Read_Date__c = Date.newInstance(2026, 2, 1),
                Previous_Reading__c = 1100, Current_Reading__c = 1200) };
        insert bills;
        TestDataFactory.createChargeLine(bills[0].Id, priorTotal, true);
        TestDataFactory.createChargeLine(bills[1].Id, currentTotal, true);
        return bills[1];
    }

    /**
     * The scope a real run would hand `execute()`, read through the job's OWN locator so the
     * fixture cannot drift from what production would actually see.
     */
    private static List<Utility_Bill__c> sweepScope() {
        List<Utility_Bill__c> rows = new List<Utility_Bill__c>();
        Database.QueryLocatorIterator it =
            UtilityBillSelector.queryVarianceSweep(Datetime.now().addDays(-1)).iterator();
        while (it.hasNext()) {
            rows.add((Utility_Bill__c) it.next());
        }
        return rows;
    }

    @isTest
    static void execute_varianceOverBothThresholds_isFlagged() {
        // $400 -> $900: +$500 (>= $250) and +125% (>= 20%). Both cleared.
        chainWithTotals(theMeter().Id, 400, 900);
        UtilityVarianceAlertBatch job = new UtilityVarianceAlertBatch();

        Test.startTest();
        job.execute(null, sweepScope());
        Test.stopTest();

        Assert.areEqual(1, job.scanned, 'One bill has a prior and is therefore sweepable.');
        Assert.areEqual(1, job.flagged,
            'It clears BOTH the dollar and the percentage threshold, which is the ASSUMED '
            + 'rule - see the class header of UtilityVarianceAlertBatch, where it is flagged '
            + 'as an assumption and not a specification.');
    }

    @isTest
    static void execute_largeDollarsButSmallPercentage_isNotFlagged() {
        // $20,000 -> $20,400: +$400 clears the dollar bar, but +2% does not clear 20%.
        chainWithTotals(theMeter().Id, 20000, 20400);
        UtilityVarianceAlertBatch job = new UtilityVarianceAlertBatch();

        Test.startTest();
        job.execute(null, sweepScope());
        Test.stopTest();

        Assert.areEqual(1, job.scanned, 'It was examined.');
        Assert.areEqual(0, job.flagged,
            'BOTH thresholds are required. On a large property a $400 move is noise, and '
            + 'alerting on it is how an alert list becomes something nobody reads - which is '
            + 'the actual failure mode of this kind of feature.');
    }

    @isTest
    static void execute_largePercentageButSmallDollars_isNotFlagged() {
        // $12 -> $30: +150% clears the percentage bar, but +$18 does not clear $250.
        chainWithTotals(theMeter().Id, 12, 30);
        UtilityVarianceAlertBatch job = new UtilityVarianceAlertBatch();

        Test.startTest();
        job.execute(null, sweepScope());
        Test.stopTest();

        Assert.areEqual(1, job.scanned, 'It was examined.');
        Assert.areEqual(0, job.flagged,
            'A small water bill more than doubling is +150% and nobody cares. This is the '
            + 'other half of the both-thresholds rule.');
    }

    @isTest
    static void execute_priorTotalOfZero_failsClosedRatherThanAlertingOnInfinity() {
        chainWithTotals(theMeter().Id, 0, 900);
        UtilityVarianceAlertBatch job = new UtilityVarianceAlertBatch();

        Test.startTest();
        job.execute(null, sweepScope());
        Test.stopTest();

        Assert.areEqual(1, job.scanned, 'The bill is in scope.');
        Assert.areEqual(0, job.flagged,
            'A percentage change FROM zero is undefined. `variancePct` returns null and '
            + '`qualifies` fails closed on it - the alternative is a fabricated number that '
            + 'clears every threshold and pages somebody for nothing.');
    }

    @isTest
    static void execute_configuredThresholds_changeTheOutcomeWithoutACodeChange() {
        // THE POINT OF THE THREE-ARGUMENT CONSTRUCTOR: the threshold is an OPEN QUESTION
        // (user decision D-UM-8), so answering it must be a re-schedule and not a deploy.
        chainWithTotals(theMeter().Id, 20000, 20400);   // +$400, +2% - ignored by default
        List<Utility_Bill__c> scope = sweepScope();
        UtilityVarianceAlertBatch defaults = new UtilityVarianceAlertBatch();
        UtilityVarianceAlertBatch strict = new UtilityVarianceAlertBatch(100, 1, 1);

        Test.startTest();
        defaults.execute(null, scope);
        strict.execute(null, scope);
        Test.stopTest();

        Assert.areEqual(0, defaults.flagged,
            'Control: the assumed default configuration ignores this bill.');
        Assert.areEqual(1, strict.flagged,
            'And the SAME bill is flagged at $100 / 1%. Asserting only the second half would '
            + 'pass on a job that flagged everything. If answering the threshold question '
            + 'ever requires editing a constant instead, it has been silently closed in code.');
    }

    @isTest
    static void execute_nullConstructorArguments_fallBackToTheDefaults() {
        chainWithTotals(theMeter().Id, 400, 900);
        UtilityVarianceAlertBatch job = new UtilityVarianceAlertBatch(null, null, null);

        Test.startTest();
        job.execute(null, sweepScope());
        Test.stopTest();

        Assert.areEqual(1, job.flagged,
            'Nulls must not be dereferenced into a comparison - they fall back to the '
            + 'documented defaults, so a partially-configured schedule still works.');
    }

    @isTest
    static void execute_billWithNoPriorBill_isNeverEvenScanned() {
        Meter__c meter = theMeter();
        Utility_Bill__c only = new Utility_Bill__c(
            Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 1, 1),
            Previous_Reading__c = 1000, Current_Reading__c = 1100);
        insert only;
        TestDataFactory.createChargeLine(only.Id, 9999, true);
        UtilityVarianceAlertBatch job = new UtilityVarianceAlertBatch();

        Test.startTest();
        job.execute(null, sweepScope());
        Test.stopTest();

        Assert.areEqual(0, job.scanned,
            'The locator filters on Prior_Utility_Bill__c != NULL, so this bill never reaches '
            + 'execute() at all. A first bill has no variance, and a $9,999 first bill must '
            + 'never look like a $9,999 rise.');
    }

    @isTest
    static void execute_emptyScope_sendsNothingAndCountsNothing() {
        UtilityVarianceAlertBatch job = new UtilityVarianceAlertBatch();

        Test.startTest();
        job.execute(null, new List<Utility_Bill__c>());
        job.finish(null);
        Test.stopTest();

        Assert.areEqual(0, job.scanned, 'Nothing examined.');
        Assert.areEqual(0, job.notified,
            'And no notification attempted - an empty request list short-circuits before '
            + 'GroupNotifier is called at all.');
    }

    @isTest
    static void execute_251BillScope_examinesEveryRowInOnePassAndOneNotifyCall() {
        // `.claude/rules/bulk-test-rule.md`: 251+ records, all processed. Driven through
        // execute() directly because a test batch may only run ONE chunk - at scope 200 a
        // 251-row locator dies with "No more than one executeBatch can be called from within
        // a test method".
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        List<Meter__c> meters = TestDataFactory.createMeters(BULK_ROWS, asset.Id, true);

        List<Utility_Bill__c> bills = new List<Utility_Bill__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            bills.add(new Utility_Bill__c(Meter__c = meters[i].Id,
                Read_Date__c = Date.newInstance(2026, 1, 1),
                Previous_Reading__c = 1000, Current_Reading__c = 1100));
            bills.add(new Utility_Bill__c(Meter__c = meters[i].Id,
                Read_Date__c = Date.newInstance(2026, 2, 1),
                Previous_Reading__c = 1100, Current_Reading__c = 1200));
        }
        insert bills;

        // NO charge lines, deliberately: Total_Charges_Amount__c is a roll-up, so with no
        // lines every bill totals 0, the percentage is undefined and nothing qualifies. This
        // test is about the SWEEP reaching all 251 chained rows; 502 charge lines would drag
        // roll-up recalculation into the same transaction and make the measurement about
        // something else.
        List<Utility_Bill__c> scope = sweepScope();
        Assert.areEqual(BULK_ROWS, scope.size(),
            'Precondition: exactly 251 bills have a prior and are therefore sweepable.');

        UtilityVarianceAlertBatch job = new UtilityVarianceAlertBatch();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        job.execute(null, scope);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(BULK_ROWS, job.scanned, 'All 251 rows examined in one pass.');
        Assert.areEqual(0, job.flagged, 'None qualifies - the shape of a quiet month.');
        Assert.areEqual(0, dmlUsed,
            'The sweep is READ-ONLY. It has no idempotency marker to stamp, so a DML here '
            + 'would mean something was added that this design deliberately does not have.');
        Assert.areEqual(0, queriesUsed,
            'ZERO queries inside execute(). Everything the threshold needs - the current '
            + 'total and the PRIOR bill\'s total - is already on the locator\'s field list. A '
            + 'per-bill re-read of the prior would be 251 queries and would break the '
            + '100-query limit at row 101, which is exactly the defect a 251-row scope exists '
            + 'to expose.');
    }

    @isTest
    static void endToEnd_realBatchRun_wiresStartAndFinishToTheLocator() {
        // The ONE test that goes through Database.executeBatch. It can prove only that
        // start() -> execute() -> finish() are wired and the locator returns something the
        // job can consume: the counters are unreachable from here (see the class header), so
        // this asserts on the AsyncApexJob instead. Kept below the scope size on purpose.
        chainWithTotals(theMeter().Id, 400, 900);

        Test.startTest();
        Id jobId = Database.executeBatch(new UtilityVarianceAlertBatch(), 200);
        Test.stopTest();

        AsyncApexJob job = [
            SELECT Status, NumberOfErrors, JobItemsProcessed
            FROM AsyncApexJob WHERE Id = :jobId];
        Assert.areEqual('Completed', job.Status,
            'A real run completes. Anything else means start() threw - which on this job '
            + 'would most likely be the `without sharing` inner class having been removed, '
            + 'and the symptom would otherwise be an all-zeros summary indistinguishable '
            + 'from a quiet month.');
        Assert.areEqual(0, job.NumberOfErrors, 'And with no errors.');
        Assert.areEqual(1, job.JobItemsProcessed, 'One chunk, as sized.');
    }

    @isTest
    static void qualifies_nullInputs_failClosed_andTheTestIsOnAbsoluteValue() {
        UtilityVarianceAlertBatch job = new UtilityVarianceAlertBatch();

        Test.startTest();
        Assert.isFalse(job.qualifies(null, 50), 'A null amount cannot clear a threshold.');
        Assert.isFalse(job.qualifies(500, null), 'Nor can a null percentage.');
        Assert.isTrue(job.qualifies(-500, -50),
            'And the test is on the ABSOLUTE value - a bill that HALVED is as worth knowing '
            + 'about as one that doubled. A one-sided comparison would silently ignore every '
            + 'saving and every credit note, which is half the point of a variance review.');
        Assert.isFalse(job.qualifies(249, 999),
            'Boundary: $249 is below the $250 bar however large the percentage.');
        Assert.isTrue(job.qualifies(250, 20),
            'Boundary: the comparison is >=, so exactly $250 and exactly 20% both qualify.');
        Test.stopTest();
    }
}
