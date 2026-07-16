/**
 * Tests for QueueGroupSelector (SYSTEM_MODE guest/automation lookup). Covers the
 * found path (a seeded queue Group resolved by DeveloperName), plus the not-found
 * and blank-input contracts. Group of Type 'Queue' is insertable via Apex DML, so
 * the found path is seeded directly.
 */
@isTest
private class QueueGroupSelectorTest {

    private static final String QUEUE_DEV_NAME = 'Test_Broker_Portal_Leads_Q';

    @isTest
    static void selectQueueByDeveloperName_found() {
        Group queue = new Group(
            Name = 'Test Broker Portal Leads',
            DeveloperName = QUEUE_DEV_NAME,
            Type = 'Queue'
        );
        insert queue;

        Test.startTest();
        Group result = QueueGroupSelector.selectQueueByDeveloperName(QUEUE_DEV_NAME);
        Test.stopTest();

        Assert.isNotNull(result, 'A queue with the given DeveloperName should resolve');
        Assert.areEqual(queue.Id, result.Id, 'Should return the queue matched by DeveloperName');
    }

    @isTest
    static void selectQueueByDeveloperName_missing_returnsNull() {
        Test.startTest();
        Group result = QueueGroupSelector.selectQueueByDeveloperName('ZZ_Nonexistent_Queue_9x7');
        Test.stopTest();

        Assert.isNull(result, 'An unknown DeveloperName returns null (skip-notification state)');
    }

    @isTest
    static void selectQueueByDeveloperName_blankInput_returnsNull() {
        Test.startTest();
        Group nullResult = QueueGroupSelector.selectQueueByDeveloperName(null);
        Group blankResult = QueueGroupSelector.selectQueueByDeveloperName('   ');
        Test.stopTest();

        Assert.isNull(nullResult, 'Null input returns null');
        Assert.isNull(blankResult, 'Blank input returns null');
    }
}
