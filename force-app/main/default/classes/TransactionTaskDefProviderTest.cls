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

    /**
     * Directly exercises the GroupSequenceComparator's defensive tie/null branches
     * (in both compareStrings and compareDecimals), which the real deployed data
     * never reaches. CMDT cannot be inserted in a test, so the comparator is
     * invoked on in-memory Transaction_Task_Def__mdt instances — no DML required.
     */
    @isTest
    static void groupSequenceComparator_handlesTiesAndNulls() {
        TransactionTaskDefProvider.GroupSequenceComparator comparator =
            new TransactionTaskDefProvider.GroupSequenceComparator();

        Transaction_Task_Def__mdt a5 = new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = 5);
        Transaction_Task_Def__mdt a5Again = new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = 5);
        Transaction_Task_Def__mdt a3 = new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = 3);
        Transaction_Task_Def__mdt aNullSeq = new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = null);
        Transaction_Task_Def__mdt aNullSeqAgain = new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = null);
        Transaction_Task_Def__mdt b5 = new Transaction_Task_Def__mdt(Group_Letter__c = 'B', Sequence__c = 5);
        Transaction_Task_Def__mdt nullGroup = new Transaction_Task_Def__mdt(Group_Letter__c = null, Sequence__c = 5);
        Transaction_Task_Def__mdt nullGroupAgain = new Transaction_Task_Def__mdt(Group_Letter__c = null, Sequence__c = 5);

        // Same group letter -> compareDecimals tie/null branches
        System.assertEquals(0, comparator.compare(a5, a5Again), 'Same group + equal sequence -> tie');
        System.assertEquals(0, comparator.compare(aNullSeq, aNullSeqAgain), 'Same group + both null sequence -> tie');
        System.assertEquals(-1, comparator.compare(aNullSeq, a5), 'Null sequence sorts before non-null within a group');
        System.assertEquals(1, comparator.compare(a5, aNullSeq), 'Non-null sequence sorts after null within a group');
        System.assertEquals(-1, comparator.compare(a3, a5), 'Smaller sequence sorts first within a group');
        System.assertEquals(1, comparator.compare(a5, a3), 'Larger sequence sorts last within a group');

        // Group letter differs / nulls -> compareStrings tie/null branches
        System.assertEquals(0, comparator.compare(nullGroup, nullGroupAgain), 'Both null group + equal sequence -> tie');
        System.assertEquals(-1, comparator.compare(nullGroup, a5), 'Null group sorts before non-null group');
        System.assertEquals(1, comparator.compare(a5, nullGroup), 'Non-null group sorts after null group');
        System.assert(comparator.compare(a5, b5) < 0, 'Group A sorts before group B');
        System.assert(comparator.compare(b5, a5) > 0, 'Group B sorts after group A');
    }
}
