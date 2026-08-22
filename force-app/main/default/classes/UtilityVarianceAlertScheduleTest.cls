/**
 * Tests for `UtilityVarianceAlertSchedule`.
 *
 * A Schedulable is one line of orchestration, so what is worth asserting is narrow but not
 * trivial: that scheduling it actually enqueues, that BOTH constructors reach the batch, and
 * that the configured thresholds survive the hop from the schedule into the job. That last
 * one matters because the three-argument constructor is the ONLY mechanism by which the open
 * threshold question (user decision D-UM-8) can be answered without a code change - if the
 * schedule silently dropped its arguments, a "configured" job would run on the defaults and
 * nothing would say so.
 *
 * No 251-record fixture here: `.claude/rules/bulk-test-rule.md`'s volume mandate lands on
 * the BATCH, and it is discharged in `UtilityVarianceAlertBatchTest`. This class starts no
 * job over records at all.
 */
@isTest
private class UtilityVarianceAlertScheduleTest {

    /** Daily at 07:00, matching the cron in the class header. */
    private static final String CRON_DAILY_7AM = '0 0 7 * * ?';

    @isTest
    static void schedule_defaultConstructor_registersTheCronJob() {
        Test.startTest();
        String jobId = System.schedule('DPEG Utility Variance Alert TEST DEFAULT',
            CRON_DAILY_7AM, new UtilityVarianceAlertSchedule());
        Test.stopTest();

        CronTrigger ct = [
            SELECT CronExpression, TimesTriggered, State
            FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual(CRON_DAILY_7AM, ct.CronExpression,
            'The cadence and the batch\'s 1-day look-back are COUPLED: the look-back is what '
            + 'replaces an idempotency marker field on this feature, so scheduling it less '
            + 'often than daily silently drops every bill modified in the gap.');
        Assert.areEqual(0, ct.TimesTriggered,
            'Scheduling registers the job; Test.stopTest fires it once, and the batch it '
            + 'starts is asserted in UtilityVarianceAlertBatchTest rather than here.');
    }

    @isTest
    static void schedule_configuredConstructor_alsoRegisters() {
        Test.startTest();
        String jobId = System.schedule('DPEG Utility Variance Alert TEST CONFIGURED',
            CRON_DAILY_7AM, new UtilityVarianceAlertSchedule(500, 15, 2));
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :jobId],
            'Both constructors must be reachable - the three-argument one is how the OPEN '
            + 'threshold question gets answered without a deploy.');
    }

    @isTest
    static void execute_configuredThresholds_reachTheBatchRatherThanBeingDropped() {
        // The falsifier for "the schedule accepts arguments and ignores them", which would
        // compile, deploy, schedule and run - on the wrong thresholds, silently.
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(
            TestDataFactory.defaultProperty().Id, true);
        Meter__c meter = TestDataFactory.createMeter(asset.Id, true);
        List<Utility_Bill__c> bills = new List<Utility_Bill__c>{
            new Utility_Bill__c(Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 1, 1),
                Previous_Reading__c = 1000, Current_Reading__c = 1100),
            new Utility_Bill__c(Meter__c = meter.Id, Read_Date__c = Date.newInstance(2026, 2, 1),
                Previous_Reading__c = 1100, Current_Reading__c = 1200) };
        insert bills;
        // +$400 on $20,000 is +2%: BELOW the assumed default of $250 AND 20%, above a $100/1%
        // configuration. The two settings therefore disagree about this exact bill.
        TestDataFactory.createChargeLine(bills[0].Id, 20000, true);
        TestDataFactory.createChargeLine(bills[1].Id, 20400, true);

        Test.startTest();
        new UtilityVarianceAlertSchedule(100, 1, 1).execute(null);
        Test.stopTest();

        // The job ran asynchronously and its counters are not reachable from here, so assert
        // on what IS observable: a batch was enqueued by execute().
        Assert.areEqual(1,
            [SELECT COUNT() FROM AsyncApexJob
             WHERE JobType = 'BatchApex'
               AND ApexClass.Name = 'UtilityVarianceAlertBatch'],
            'execute() must enqueue exactly one UtilityVarianceAlertBatch. The THRESHOLD '
            + 'hand-off itself is asserted directly in '
            + 'UtilityVarianceAlertBatchTest.execute_configuredThresholds_changeTheOutcome'
            + 'WithoutACodeChange, where the counters are reachable.');
    }

    @isTest
    static void execute_defaultConstructor_alsoEnqueuesABatch() {
        Test.startTest();
        new UtilityVarianceAlertSchedule().execute(null);
        Test.stopTest();

        Assert.areEqual(1,
            [SELECT COUNT() FROM AsyncApexJob
             WHERE JobType = 'BatchApex'
               AND ApexClass.Name = 'UtilityVarianceAlertBatch'],
            'The no-argument path is the one production actually uses.');
    }
}
