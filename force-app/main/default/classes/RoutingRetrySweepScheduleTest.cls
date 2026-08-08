/**
 * Test class for RoutingRetrySweepSchedule — the HOURLY trigger for RoutingRetrySweepBatch. No
 * SOQL, no DML, no logic of its own: it exists only to start the batch, so this class proves
 * exactly that and nothing more.
 *
 * ═══ ZERO ContentPublication COST ═══ No content object is touched anywhere in this class.
 *
 * ⚠ HOURLY, NOT DAILY — unlike AttachmentCarrierSweepSchedule's mirror. This test uses an hourly
 * cron expression to match the class's own documented schedule; do not "harmonize" it to the
 * carrier sweep's daily one. See RoutingRetrySweepSchedule.cls's header for why the difference is
 * load-bearing (a claim is time-ordered).
 *
 * @see RoutingRetrySweepSchedule.cls
 * @author Unit Testing Agent
 */
@isTest
private class RoutingRetrySweepScheduleTest {

    @isTest
    static void execute_schedulesTheRoutingRetrySweepBatchAtScopeOne() {
        Test.startTest();
        String jobId = System.schedule('Routing Retry Sweep Test',
            '0 0 * * * ?', new RoutingRetrySweepSchedule());
        Test.stopTest();

        // Test.stopTest() runs the scheduled job synchronously, so by this point the batch it
        // started should be queryable as its own AsyncApexJob.
        Assert.areEqual(1, [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'RoutingRetrySweepBatch'
        ], 'Scheduling and firing must start exactly one RoutingRetrySweepBatch execution');

        CronTrigger cronRow = [SELECT CronExpression, State FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 * * * ?', cronRow.CronExpression,
            'HOURLY — a claim is time-ordered, so retry latency is a real cost (unlike the daily '
            + 'carrier sweep). Do not change this to a daily expression to "match" the file pipeline');
    }
}
