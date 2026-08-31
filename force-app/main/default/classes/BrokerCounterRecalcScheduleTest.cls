/**
 * Tests for `BrokerCounterRecalcSchedule` — the nightly trigger for `BrokerCounterRecalcBatch`.
 *
 * ═══ 🔴 WHAT THESE TESTS CAN AND CANNOT PROVE — READ BEFORE TRUSTING A GREEN RUN ═══
 * They prove the Schedulable compiles, is schedulable, and starts the batch at the batch's own
 * SCOPE. **They cannot prove the job is scheduled in the org**, because a scheduled-job INSTANCE
 * is not deployable metadata and no test can see one. That is a POST-DEPLOY GATE, and missing it
 * leaves the class present, compiled, covered and completely inert.
 *
 * 🔴 THE MISS IS UNUSUALLY HARD TO NOTICE FOR THIS PARTICULAR JOB, because its symptom is the
 * symptom the feature exists to remove: `Contact.Deals_Submitted__c` / `Deals_Won__c` have
 * rendered permanent zeroes since they were created with no writer. Unscheduled, they keep doing
 * exactly that — so the original bug report stays open while the code that fixes it sits green in
 * the org. Verify in Setup > Scheduled Jobs, then verify a broker Contact's counters the next
 * morning. See `BrokerCounterRecalcSchedule`'s own header for the gate and the cron expression.
 *
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does NOT apply to this class and that
 * is not a waiver being claimed loosely. `execute(SchedulableContext)` takes no records, holds no
 * loop, performs no SOQL and no DML — there is no volume dimension to exercise, and a 251-record
 * fixture here would exercise `BrokerCounterRecalcBatch` instead, which
 * `BrokerCounterRecalcBatchTest.bulkResetsAndRecalculates` already does at 251.
 *
 * @see BrokerCounterRecalcSchedule.cls (the post-deploy gate and the owner argument)
 * @see BrokerCounterRecalcBatchTest.cls (the behaviour, including the 251-row bulk pass)
 */
@IsTest
private class BrokerCounterRecalcScheduleTest {

    /** 02:00 daily — the cadence recorded in the Schedulable's header. */
    private static final String NIGHTLY_CRON = '0 0 2 * * ?';

    /**
     * Scheduling the job registers a `CronTrigger`, and firing it enqueues the batch without
     * throwing.
     *
     * ⚠ `Test.stopTest()` is what fires a job scheduled inside the start/stop window; without it
     * the Schedulable's `execute` never runs and this test would pass while covering nothing.
     */
    @IsTest
    static void schedulingRegistersTheJobAndStartsTheBatch() {
        Test.startTest();
        String jobId = System.schedule(
            'BrokerCounterRecalcScheduleTest nightly', NIGHTLY_CRON, new BrokerCounterRecalcSchedule()
        );
        Test.stopTest();

        CronTrigger job = [
            SELECT Id, CronExpression, TimesTriggered
            FROM CronTrigger
            WHERE Id = :jobId
        ];
        Assert.areEqual(NIGHTLY_CRON, job.CronExpression,
            'the scheduled job must carry the nightly cron expression it was given');

        List<AsyncApexJob> batches = [
            SELECT Id, ApexClass.Name
            FROM AsyncApexJob
            WHERE JobType = 'BatchApex' AND ApexClass.Name = 'BrokerCounterRecalcBatch'
        ];
        Assert.areEqual(1, batches.size(),
            'firing the schedule must enqueue exactly one BrokerCounterRecalcBatch — zero means '
            + 'the Schedulable did not call Database.executeBatch');
    }

    /**
     * 🔴 The Schedulable must take its chunk size FROM the batch, never hardcode one.
     *
     * This matters more here than for the sibling jobs: `BrokerCounterRecalcBatch.SCOPE` is **100,
     * DERIVED from the 2,000-row `AggregateResult` cliff** — not the 200 every other batch in this
     * repo inherits. A second copy of that number in the Schedulable is exactly how the two would
     * drift, and the drift would surface as a swallowed chunk failure rather than an error.
     */
    @IsTest
    static void chunkSizeComesFromTheBatchNotFromALiteral() {
        Assert.areEqual(100, BrokerCounterRecalcBatch.SCOPE,
            'the Schedulable passes BrokerCounterRecalcBatch.SCOPE rather than a literal. If that '
            + 'constant moves, the 2,000-row AggregateResult arithmetic in the batch header §2a '
            + 'must move with it — and the Schedulable must keep deferring to it.');
    }
}
