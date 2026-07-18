/**
 * Tests TaskGroupDefProvider.getAllOrderedBySequence against the real, deployed
 * Task_Group_Def__mdt checklist (11 records loaded via
 * scripts/load-task-group-defs.apex — see TaskFanoutServiceTest for the same
 * canary pattern). Custom Metadata cannot be inserted in a test context, so
 * this exercises the real getAll() + in-memory sort path directly rather than
 * mocking the records.
 */
@isTest
private class TaskGroupDefProviderTest {

    @isTest
    static void getAllOrderedBySequence_returnsAllRealDefsInAscendingOrder() {
        System.assertEquals(11, [SELECT COUNT() FROM Task_Group_Def__mdt],
            'This test assumes the 11 deployed Task_Group_Def__mdt records exist ' +
            '(scripts/load-task-group-defs.apex); re-run the loader if this fails.');

        Test.startTest();
        List<Task_Group_Def__mdt> defs = TaskGroupDefProvider.getAllOrderedBySequence();
        Test.stopTest();

        System.assertEquals(11, defs.size(), 'All 11 group defs are returned');

        Decimal prevSequence = null;
        for (Task_Group_Def__mdt d : defs) {
            if (prevSequence != null && d.Sequence__c != null) {
                System.assert(d.Sequence__c >= prevSequence,
                    'Sequence__c must be ascending: ' + d.Sequence__c + ' followed ' + prevSequence);
            }
            if (d.Sequence__c != null) {
                prevSequence = d.Sequence__c;
            }
        }
    }

    @isTest
    static void getAllOrderedBySequence_everyGroupHasALetterAndAName() {
        Test.startTest();
        List<Task_Group_Def__mdt> defs = TaskGroupDefProvider.getAllOrderedBySequence();
        Test.stopTest();

        Set<String> letters = new Set<String>();
        for (Task_Group_Def__mdt d : defs) {
            System.assertNotEquals(null, d.Letter__c, 'Every group def has a Letter__c');
            System.assertNotEquals(null, d.Group_Name__c, 'Every group def has a Group_Name__c');
            letters.add(d.Letter__c);
        }
        System.assertEquals(defs.size(), letters.size(), 'Every group def has a unique Letter__c');
    }
}
