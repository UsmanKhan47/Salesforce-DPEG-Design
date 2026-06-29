@isTest
private class TaskRollupServiceTest {

    @isTest
    static void testRollup() {
        Transaction__c t = new Transaction__c(Status__c = 'Active');
        insert t;

        List<Task> tasks = new List<Task>{
            new Task(Transaction_Deal__c = t.Id, Subject = 'a', Status = 'Completed'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'b', Status = 'Completed'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'c', Status = 'Not Started')
        };

        Test.startTest();
        insert tasks; // trigger -> recalc
        Test.stopTest();

        Transaction__c r = [SELECT Tasks_Complete__c FROM Transaction__c WHERE Id = :t.Id];
        System.assertEquals(2, r.Tasks_Complete__c, 'Two completed tasks counted');

        tasks[2].Status = 'Completed';
        update tasks[2];
        r = [SELECT Tasks_Complete__c FROM Transaction__c WHERE Id = :t.Id];
        System.assertEquals(3, r.Tasks_Complete__c, 'Now three completed');

        delete tasks[0];
        r = [SELECT Tasks_Complete__c FROM Transaction__c WHERE Id = :t.Id];
        System.assertEquals(2, r.Tasks_Complete__c, 'Two after deleting one completed task');
    }
}