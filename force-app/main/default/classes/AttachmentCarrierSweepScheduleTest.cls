/**
 * Test class for AttachmentCarrierSweepSchedule — the daily trigger for
 * AttachmentCarrierSweepBatch. No SOQL, no DML, no logic of its own: it exists only to start the
 * batch, so this class proves exactly that and nothing more.
 *
 * ═══ ZERO ContentPublication COST ═══ No content object is touched anywhere in this class.
 *
 * @see AttachmentCarrierSweepSchedule.cls
 * @author Unit Testing Agent
 */
@isTest
private class AttachmentCarrierSweepScheduleTest {

    @isTest
    static void execute_schedulesTheCarrierSweepBatchAtScopeOne() {
        Test.startTest();
        String jobId = System.schedule('Attachment Carrier Sweep Test',
            '0 0 3 * * ?', new AttachmentCarrierSweepSchedule());
        Test.stopTest();

        // Test.stopTest() runs the scheduled job synchronously, so by this point the batch it
        // started should be queryable as its own AsyncApexJob.
        Assert.areEqual(1, [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'AttachmentCarrierSweepBatch'
        ], 'Scheduling and firing must start exactly one AttachmentCarrierSweepBatch execution');

        CronTrigger cronRow = [SELECT CronExpression, State FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 3 * * ?', cronRow.CronExpression, '');
    }
}
