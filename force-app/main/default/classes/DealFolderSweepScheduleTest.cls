/**
 * Test class for DealFolderSweepSchedule — the trigger for DealFolderSweepBatch. No SOQL, no DML,
 * no logic of its own: it exists only to start the batch, so this class proves exactly that.
 *
 * ⚠ DAILY, NOT HOURLY — unlike `RoutingRetrySweepSchedule`'s mirror. This test uses the class's own
 * documented cron cadence; do not "harmonize" it to the hourly routing-retry sweep. See
 * `DealFolderSweepSchedule.cls`'s header for why the difference is deliberate (nothing here is
 * time-ordered the way a broker's registry claim is).
 *
 * @see DealFolderSweepSchedule.cls
 * @see RoutingRetrySweepScheduleTest.cls (the precedent this test's shape follows)
 * @author Unit Testing Agent
 */
@isTest
private class DealFolderSweepScheduleTest {

    @isTest
    static void execute_schedulesTheDealFolderSweepBatch() {
        Test.startTest();
        String jobId = System.schedule('SharePoint Deal Folder Sweep Test',
            '0 0 2 * * ?', new DealFolderSweepSchedule());
        Test.stopTest();

        // Test.stopTest() runs the scheduled job synchronously, so by this point the batch it
        // started should be queryable as its own AsyncApexJob.
        Assert.areEqual(1, [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DealFolderSweepBatch'
        ], 'Scheduling and firing must start exactly one DealFolderSweepBatch execution');

        CronTrigger cronRow = [SELECT CronExpression, State FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 2 * * ?', cronRow.CronExpression,
            'DAILY, off-peak — a deal folder is merely late if delayed, unlike a time-ordered '
            + 'broker registry claim. Do not change this to an hourly expression to "match" routing retry');
    }
}
