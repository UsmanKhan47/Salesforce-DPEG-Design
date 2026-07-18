/**
 * Tests TransactionTaskDefProvider.getAllOrderedByGroupAndSequence against the
 * real, deployed Transaction_Task_Def__mdt checklist (82 records loaded via
 * scripts/load-transaction-task-defs.apex — see TaskFanoutServiceTest for the
 * same canary pattern). Custom Metadata cannot be inserted in a test context,
 * so this exercises the real getAll() + in-memory sort path directly rather
 * than mocking the records.
 */
@isTest
private class TransactionTaskDefProviderTest {

    @isTest
    static void getAllOrderedByGroupAndSequence_returnsAllRealDefsGroupedAndOrdered() {
        System.assertEquals(82, [SELECT COUNT() FROM Transaction_Task_Def__mdt],
            'This test assumes the 82 deployed Transaction_Task_Def__mdt records exist ' +
            '(scripts/load-transaction-task-defs.apex); re-run the loader if this fails.');

        Test.startTest();
        List<Transaction_Task_Def__mdt> defs = TransactionTaskDefProvider.getAllOrderedByGroupAndSequence();
        Test.stopTest();

        System.assertEquals(82, defs.size(), 'All 82 task defs are returned');

        String prevGroup = null;
        Decimal prevSequence = null;
        for (Transaction_Task_Def__mdt d : defs) {
            if (prevGroup != null && d.Group_Letter__c != null) {
                System.assert(prevGroup.compareTo(d.Group_Letter__c) <= 0,
                    'Group_Letter__c must be non-decreasing: ' + d.Group_Letter__c + ' followed ' + prevGroup);
                if (prevGroup.equals(d.Group_Letter__c) && prevSequence != null && d.Sequence__c != null) {
                    System.assert(d.Sequence__c >= prevSequence,
                        'Within one group, Sequence__c must be ascending: ' + d.Sequence__c + ' followed ' + prevSequence);
                }
            }
            prevGroup = d.Group_Letter__c;
            prevSequence = d.Sequence__c;
        }
    }

    @isTest
    static void getAllOrderedByGroupAndSequence_everyDefHasAGroupLetterAndSubject() {
        Test.startTest();
        List<Transaction_Task_Def__mdt> defs = TransactionTaskDefProvider.getAllOrderedByGroupAndSequence();
        Test.stopTest();

        for (Transaction_Task_Def__mdt d : defs) {
            System.assertNotEquals(null, d.Group_Letter__c, 'Every task def has a Group_Letter__c');
            System.assertNotEquals(null, d.Subject__c, 'Every task def has a Subject__c');
        }
    }
}
