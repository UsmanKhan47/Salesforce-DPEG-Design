/**
 * Tests TaskRollupTriggerHandler: the Task trigger routes every context
 * (insert / update / delete / undelete) to TaskRollupService, and the deal-id
 * projection sources from the correct collection per context. Behaviour is
 * asserted through the observable Transaction__c rollups, exactly as the trigger
 * fires them.
 */
@isTest
private class TaskRollupTriggerHandlerTest {

    /** An Active Transaction with the Day-0 fan-out suppressed (no Contract_Executed_Date__c). */
    private static Transaction__c newSuppressedTransaction() {
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert t;
        return t;
    }

    /** Re-queries the deal's completed-Task rollup (strongly typed, as the service test asserts it). */
    private static Transaction__c reloaded(Id transactionId) {
        return [SELECT Tasks_Complete__c FROM Transaction__c WHERE Id = :transactionId];
    }

    @isTest
    static void routesInsertUpdateDeleteAndUndelete() {
        // Given: a suppressed Transaction with two complete and one open checklist Task.
        Transaction__c t = newSuppressedTransaction();
        List<Task> tasks = new List<Task>{
            new Task(Transaction_Deal__c = t.Id, Subject = 'a', Status = 'Completed'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'b', Status = 'Completed'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'c', Status = 'Not Started')
        };

        Test.startTest();
        // Insert context -> collects from new -> recalc.
        insert tasks;
        Assert.areEqual(2, reloaded(t.Id).Tasks_Complete__c, 'After insert: two completed Tasks counted');

        // Update context -> collects from new AND old -> recalc.
        tasks[2].Status = 'Completed';
        update tasks[2];
        Assert.areEqual(3, reloaded(t.Id).Tasks_Complete__c, 'After update: now three completed');

        // Delete context -> collects from old -> recalc.
        delete tasks[0];
        Assert.areEqual(2, reloaded(t.Id).Tasks_Complete__c, 'After delete: two remain complete');

        // Undelete context -> collects from new -> recalc.
        undelete tasks[0];
        Assert.areEqual(3, reloaded(t.Id).Tasks_Complete__c, 'After undelete: back to three complete');
        Test.stopTest();
    }

    /**
     * Bulk (.claude/rules/bulk-test-rule.md): 251 Tasks in one DML across three
     * Transactions forces a second TaskRollupTrigger batch chunk and proves the
     * handler's per-context id projection and the service's single query / single
     * update hold at scale.
     */
    @isTest
    static void bulk251TasksAcrossTransactionsRollUpPerDeal() {
        List<Transaction__c> transactions = TestDataFactory.createTransactions(3, false);
        TestDataFactory.applyOverrides(transactions, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert transactions;
        Id t1 = transactions[0].Id;
        Id t2 = transactions[1].Id;
        Id t3 = transactions[2].Id;

        List<Task> tasks = new List<Task>();
        // T1: 100 complete
        for (Integer i = 0; i < 100; i++) {
            tasks.add(new Task(Transaction_Deal__c = t1, Subject = 'T1 ' + i, Status = 'Completed'));
        }
        // T2: 100 complete
        for (Integer i = 0; i < 100; i++) {
            tasks.add(new Task(Transaction_Deal__c = t2, Subject = 'T2 ' + i, Status = 'Completed'));
        }
        // T3: 51 open, not overdue
        for (Integer i = 0; i < 51; i++) {
            tasks.add(new Task(Transaction_Deal__c = t3, Subject = 'T3 ' + i, Status = 'Not Started',
                ActivityDate = Date.today().addDays(10)));
        }

        Test.startTest();
        insert tasks; // 251 Tasks, one DML
        Test.stopTest();

        Map<Id, Transaction__c> results = new Map<Id, Transaction__c>(
            [SELECT Tasks_Complete__c FROM Transaction__c WHERE Id IN :transactions]);
        Assert.areEqual(100, results.get(t1).Tasks_Complete__c, 'T1: 100 complete');
        Assert.areEqual(100, results.get(t2).Tasks_Complete__c, 'T2: 100 complete');
        Assert.areEqual(0, results.get(t3).Tasks_Complete__c, 'T3: none complete');
        Assert.areEqual(
            251,
            [SELECT COUNT() FROM Task WHERE Transaction_Deal__c IN :transactions],
            'All 251 Tasks inserted in the single bulk DML'
        );
    }
}
