/**
 * Tests TaskRollupTriggerHandler: the Task trigger routes every context
 * (insert / update / delete / undelete) to TaskRollupService, and the deal-id
 * projection sources from the correct collection per context. Behaviour is
 * asserted through the observable Transaction__c rollups, exactly as the trigger
 * fires them.
 *
 * ═══ ⚠ AMENDED 2026-08-22 — THE HANDLER NOW ROUTES A SECOND PARENT ═══
 * `Onboarding__c` is routed alongside `Transaction__c` on all four after-contexts. Before this
 * change the onboarding rollups fired from ONE LWC only (`OnboardingService.completeTask`
 * called the recompute directly), so a checklist item completed from the standard UI, the API
 * or Data Loader — or deleted — never moved the Onboarding's counters. The
 * `routesOnboarding*` methods below are the proof, and they deliberately use PLAIN DML rather
 * than `OnboardingService`, because going through the service would prove only the path that
 * already worked.
 *
 * ⚠ FIXTURES SUPPRESS BOTH FAN-OUTS. `TestDataFactory.createTransactions` ships a
 * `Contract_Executed_Date__c` and `createOnboardings` ships `Tasks_Fanned_Out__c = true`;
 * without suppressing the first and relying on the second, the Day-0 and checklist fan-outs
 * would materialise 82 and 45 extra Tasks at `Test.stopTest()` and every count below would be
 * measuring them instead.
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

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 ONBOARDING ROUTING — the second parent, added 2026-08-22
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** A checklist Task on an Onboarding. Plain DML only — never through OnboardingService. */
    private static Task onboardingTask(Id onboardingId, String status, Date due) {
        return new Task(
            Subject = 'Checklist item',
            Status = 'Open',
            Onboarding__c = onboardingId,
            Onboarding_Status__c = status,
            Onboarding_Category__c = 'Property Set up',
            Source_System__c = 'Salesforce',
            ActivityDate = due
        );
    }

    private static Onboarding__c reloadedOnboarding(Id onboardingId) {
        return [
            SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_Open__c, Tasks_Overdue__c,
                   Completion_Pct__c
            FROM Onboarding__c WHERE Id = :onboardingId
        ];
    }

    /**
     * All four after-contexts route `Onboarding__c`, sourcing from the correct collection each
     * time. Mirrors `routesInsertUpdateDeleteAndUndelete` one parent over.
     */
    @isTest
    static void routesOnboardingInsertUpdateDeleteAndUndelete() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, true);
        Date due = Date.today().addDays(10);
        List<Task> tasks = new List<Task>{
            onboardingTask(o.Id, 'Complete', due),
            onboardingTask(o.Id, 'Complete', due),
            onboardingTask(o.Id, 'Not Started', due)
        };

        Test.startTest();
        insert tasks; // insert context -> collects from new
        Assert.areEqual(2, reloadedOnboarding(o.Id).Tasks_Complete__c,
            'After insert: two complete checklist items counted — with NO Apex call from this '
            + 'test, i.e. through the trigger the LWC-only path never used');

        tasks[2].Onboarding_Status__c = 'Complete';
        update tasks[2]; // update context -> collects from new AND old
        Assert.areEqual(3, reloadedOnboarding(o.Id).Tasks_Complete__c, 'After update: now three');

        delete tasks[0]; // delete context -> collects from old
        Assert.areEqual(2, reloadedOnboarding(o.Id).Tasks_Complete__c,
            'After delete: two remain — a deleted checklist item must move the counters, which is '
            + 'a case the LWC path could not reach at all');

        undelete tasks[0]; // undelete context -> collects from new
        Assert.areEqual(3, reloadedOnboarding(o.Id).Tasks_Complete__c, 'After undelete: back to three');
        Test.stopTest();
    }

    /**
     * RE-PARENTING recomputes BOTH the losing and the gaining Onboarding. This is why the update
     * context unions new and old, and it is the one case a naive "collect from Trigger.new"
     * implementation gets wrong while every single-parent test still passes.
     */
    @isTest
    static void reParentingAChecklistTaskRecomputesBothOnboardings() {
        Onboarding__c losing = TestDataFactory.createOnboarding(null, true);
        Onboarding__c gaining = TestDataFactory.createOnboarding(null, true);
        Task t = onboardingTask(losing.Id, 'Complete', Date.today().addDays(5));
        insert t;
        Assert.areEqual(1, reloadedOnboarding(losing.Id).Tasks_Complete__c, 'Precondition');

        Test.startTest();
        update new Task(Id = t.Id, Onboarding__c = gaining.Id);
        Test.stopTest();

        Assert.areEqual(0, reloadedOnboarding(losing.Id).Tasks_Total__c,
            'The LOSING Onboarding is recomputed — sourcing only from Trigger.new would leave it '
            + 'permanently counting a Task it no longer owns');
        Assert.areEqual(1, reloadedOnboarding(gaining.Id).Tasks_Total__c,
            'and the gaining one picks it up');
    }

    /**
     * 🔴 UAT ONB-001, INCLUDING THE HALF THE FSD ONLY IMPLIES. Completing a checklist item rolls
     * up Completion % and Tasks-Complete and refreshes the overdue count — AND the item's
     * ORIGINAL DUE DATE SURVIVES. Driven by plain DML, so it pins the standard-UI path.
     */
    @isTest
    static void uatOnb001_completingAnItemRollsUpAndLeavesTheDueDateIntact() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, true);
        Date overdueDue = Date.today().addDays(-5);
        Date futureDue = Date.today().addDays(20);
        List<Task> tasks = new List<Task>{
            onboardingTask(o.Id, 'Not Started', overdueDue),
            onboardingTask(o.Id, 'Not Started', futureDue)
        };
        insert tasks;

        Onboarding__c before = reloadedOnboarding(o.Id);
        Assert.areEqual(2, before.Tasks_Open__c, 'Precondition: both items open');
        Assert.areEqual(1, before.Tasks_Overdue__c, 'Precondition: one of them overdue');
        Assert.areEqual(0, before.Completion_Pct__c, 'Precondition: nothing complete');

        Test.startTest();
        update new Task(Id = tasks[0].Id, Onboarding_Status__c = 'Complete', Status = 'Completed');
        Test.stopTest();

        Onboarding__c after = reloadedOnboarding(o.Id);
        Assert.areEqual(1, after.Tasks_Complete__c, 'Tasks-Complete rolls up');
        Assert.areEqual(50, after.Completion_Pct__c, 'Completion % rolls up (1 of 2)');
        Assert.areEqual(1, after.Tasks_Open__c, 'one item remains open');
        Assert.areEqual(0, after.Tasks_Overdue__c,
            'and the overdue count refreshes — the overdue item is the one that was completed');

        Task completed = [SELECT ActivityDate, Onboarding_Completed_Date__c FROM Task WHERE Id = :tasks[0].Id];
        Assert.areEqual(overdueDue, completed.ActivityDate,
            'THE ORIGINAL DUE DATE SURVIVES. Overwriting ActivityDate on completion was the defect '
            + 'this change exists to fix, and it destroyed the very date the overdue count above '
            + 'is computed from');
        Assert.areEqual(Date.today(), completed.Onboarding_Completed_Date__c,
            'and the completion is recorded on its own field, so "was it late?" stays answerable');
    }

    /**
     * A Task with NEITHER lookup costs nothing at all. The handler runs on every Task in the
     * org, so this is the assertion that keeps a hand-created Activity from paying for two
     * rollup services it has no parent in.
     */
    @isTest
    static void aTaskWithNeitherParentCostsNoQueriesOrDml() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        insert new Task(Subject = 'An ordinary activity', Status = 'Open');
        Integer queriesAdded = Limits.getQueries() - queriesBefore;
        Integer dmlAdded = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesAdded,
            'A Task with no Transaction_Deal__c and no Onboarding__c must trigger NO selector '
            + 'read — both recalc guards return on an empty id set');
        Assert.areEqual(1, dmlAdded, 'and only the caller\'s own insert');
    }

    /**
     * Bulk (.claude/rules/bulk-test-rule.md): 251 checklist Tasks across three Onboardings in
     * one DML forces a second trigger chunk and proves the onboarding projection and the single
     * query / single update hold at scale.
     */
    @isTest
    static void bulk251ChecklistTasksAcrossOnboardingsRollUpPerOnboarding() {
        List<Onboarding__c> onboardings = TestDataFactory.createOnboardings(3, null, true);
        Id o1 = onboardings[0].Id;
        Id o2 = onboardings[1].Id;
        Id o3 = onboardings[2].Id;
        Date due = Date.today().addDays(10);

        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < 100; i++) {
            tasks.add(onboardingTask(o1, 'Complete', due));
        }
        for (Integer i = 0; i < 100; i++) {
            tasks.add(onboardingTask(o2, 'Complete', due));
        }
        for (Integer i = 0; i < 51; i++) {
            tasks.add(onboardingTask(o3, 'Not Started', due));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        insert tasks; // 251 Tasks, one DML, TWO trigger chunks
        Integer queriesAdded = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(100, reloadedOnboarding(o1).Tasks_Complete__c, 'O1: 100 complete');
        Assert.areEqual(100, reloadedOnboarding(o2).Tasks_Complete__c, 'O2: 100 complete');
        Assert.areEqual(0, reloadedOnboarding(o3).Tasks_Complete__c, 'O3: none complete');
        Assert.areEqual(51, reloadedOnboarding(o3).Tasks_Total__c, 'O3: all 51 counted');
        Assert.areEqual(251,
            [SELECT COUNT() FROM Task WHERE Onboarding__c IN :onboardings],
            'All 251 Tasks inserted in the single bulk DML');
        // ⚠ Measured around the DML, NOT after Test.stopTest() — stopTest restores the pre-test
        // counters and the obvious version of this assertion is silently vacuous.
        Assert.areEqual(2, queriesAdded,
            'ONE selector read per trigger chunk — 2 chunks = 2 queries, INDEPENDENT of the 251. '
            + 'If this grew with the record count, the rollup moved into a per-record loop');
    }
}
