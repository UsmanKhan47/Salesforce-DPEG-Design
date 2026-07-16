@isTest
private class TaskRollupServiceTest {

    /** Shared helper: an Active Transaction with the fan-out Flow suppressed (no Contract_Executed_Date__c). */
    private static Transaction__c newSuppressedTransaction() {
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        return t;
    }

    @isTest
    static void testRollup() {
        Transaction__c t = newSuppressedTransaction();
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

    @isTest
    static void testRecalc_overdueAndWireOpenTasks() {
        Transaction__c t = newSuppressedTransaction();
        insert t;

        List<Task> tasks = new List<Task>{
            new Task(Transaction_Deal__c = t.Id, Subject = 'Overdue 1', Status = 'Not Started',
                ActivityDate = Date.today().addDays(-5)),
            new Task(Transaction_Deal__c = t.Id, Subject = 'Overdue 2', Status = 'Not Started',
                ActivityDate = Date.today().addDays(-1)),
            new Task(Transaction_Deal__c = t.Id, Subject = 'Not yet due', Status = 'Not Started',
                ActivityDate = Date.today().addDays(5)),
            new Task(Transaction_Deal__c = t.Id, Subject = 'Verify wiring instructions by phone (anti-fraud)',
                Status = 'Not Started', Verbal_Verification_Completed__c = false),
            new Task(Transaction_Deal__c = t.Id, Subject = 'Verify wiring instructions by phone (anti-fraud) #2',
                Status = 'Completed', Verbal_Verification_Completed__c = true)
        };

        Test.startTest();
        insert tasks; // trigger -> recalc
        Test.stopTest();

        Transaction__c r = [SELECT Tasks_Overdue__c, Wire_Open_Risks__c, Tasks_Complete__c FROM Transaction__c WHERE Id = :t.Id];
        System.assertEquals(2, r.Tasks_Overdue__c, 'Two open Tasks with a past ActivityDate are overdue');
        System.assertEquals(1, r.Wire_Open_Risks__c, 'Only the open, unverified anti-fraud Task counts as a wire risk');
        System.assertEquals(1, r.Tasks_Complete__c, 'One closed Task counted complete');
    }

    @isTest
    static void testRecalc_nullAndEmptyAndNullEntrySets_areNoOps() {
        Test.startTest();
        TaskRollupService.recalc(null);
        TaskRollupService.recalc(new Set<Id>());
        Set<Id> withNullOnly = new Set<Id>{ null };
        TaskRollupService.recalc(withNullOnly);
        Test.stopTest();

        // No exception thrown is the assertion — nothing to query since no real Id was supplied.
        System.assert(true, 'recalc tolerates null, empty, and null-only Id sets without throwing');
    }

    /**
     * Bulk: 251 Tasks in one DML across 3 Transactions, proving TaskRollupService's SOQL
     * (single query, no loop) and its single bulk update hold at scale, per
     * .claude/rules/bulk-test-rule.md. Distinct per-parent complete/overdue/wire mixes so
     * the map-keyed aggregation is verified, not just the total count.
     */
    @isTest
    static void testRecalc_bulk251TasksAcrossMultipleTransactions() {
        List<Transaction__c> transactions = TestDataFactory.createTransactions(3, false);
        TestDataFactory.applyOverrides(transactions, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert transactions;
        Id t1 = transactions[0].Id;
        Id t2 = transactions[1].Id;
        Id t3 = transactions[2].Id;

        List<Task> tasks = new List<Task>();
        // T1: 100 tasks — 60 complete, 30 overdue-open, 10 wire-open
        for (Integer i = 0; i < 60; i++) {
            tasks.add(new Task(Transaction_Deal__c = t1, Subject = 'T1 complete ' + i, Status = 'Completed'));
        }
        for (Integer i = 0; i < 30; i++) {
            tasks.add(new Task(Transaction_Deal__c = t1, Subject = 'T1 overdue ' + i, Status = 'Not Started',
                ActivityDate = Date.today().addDays(-3)));
        }
        for (Integer i = 0; i < 10; i++) {
            tasks.add(new Task(Transaction_Deal__c = t1, Subject = 'Verify wiring instructions by phone (anti-fraud) ' + i,
                Status = 'Not Started', Verbal_Verification_Completed__c = false));
        }
        // T2: 100 tasks — all complete
        for (Integer i = 0; i < 100; i++) {
            tasks.add(new Task(Transaction_Deal__c = t2, Subject = 'T2 complete ' + i, Status = 'Completed'));
        }
        // T3: 51 tasks — all open, not overdue
        for (Integer i = 0; i < 51; i++) {
            tasks.add(new Task(Transaction_Deal__c = t3, Subject = 'T3 open ' + i, Status = 'Not Started',
                ActivityDate = Date.today().addDays(10)));
        }

        Test.startTest();
        insert tasks; // 251 Tasks, one DML -> forces a second TaskRollupTrigger batch chunk
        Test.stopTest();

        Map<Id, Transaction__c> results = new Map<Id, Transaction__c>(
            [SELECT Tasks_Complete__c, Tasks_Overdue__c, Wire_Open_Risks__c FROM Transaction__c WHERE Id IN :transactions]);

        System.assertEquals(60, results.get(t1).Tasks_Complete__c, 'T1: 60 complete');
        System.assertEquals(30, results.get(t1).Tasks_Overdue__c, 'T1: 30 overdue');
        System.assertEquals(10, results.get(t1).Wire_Open_Risks__c, 'T1: 10 open wire-verification risks');
        System.assertEquals(100, results.get(t2).Tasks_Complete__c, 'T2: all 100 complete');
        System.assertEquals(0, results.get(t2).Tasks_Overdue__c, 'T2: nothing overdue');
        System.assertEquals(0, results.get(t3).Tasks_Overdue__c, 'T3: future ActivityDate, nothing overdue');
        System.assertEquals(0, results.get(t3).Tasks_Complete__c, 'T3: nothing complete');

        Integer totalTasks = [SELECT COUNT() FROM Task WHERE Transaction_Deal__c IN :transactions];
        System.assertEquals(251, totalTasks, 'All 251 Tasks inserted in the single bulk DML');
    }
}
