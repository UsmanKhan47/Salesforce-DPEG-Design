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

    // ─────────────────────────────────────────────────────────────────────────
    // WITH SYSTEM_MODE regression coverage (2026-08-05). TaskSelector.selectByTransactionDealIds
    // moved from WITH USER_MODE to WITH SYSTEM_MODE after a REPRODUCED production failure: a
    // non-admin created a Transaction__c with Contract_Executed_Date__c set, the Day-0 fan-out
    // inserted its checklist Tasks, TaskRollupTrigger fired after-insert, TaskRollupService called
    // this selector, and the old WITH USER_MODE query threw
    // `No such column 'Transaction_Deal__c' on entity 'Task'` — an FLS denial for a persona with
    // no permission-set grant on that field — rolling back all 82 Task inserts. See
    // TaskSelector.selectByTransactionDealIds's own Javadoc for the full incident.
    //
    // ⚠ ROUTE B, REVISED 2026-08-05 after a failed deploy (job 0Afiw000000FALdCAO). These two
    // tests need the restricted principal to insert the checklist Task ITSELF (to fire the
    // trigger under their own identity, exactly as production did) — unlike TaskSelectorTest's
    // selector-level pins, there is no read-only escape hatch here: the Task insert is plain,
    // unenforced DML, and TaskRollupService.recalc's own `update` of Transaction__c is too. Both
    // of those are OBJECT-level CRUD checks (Create on Task, Edit on Transaction__c) that ARE
    // enforced by the platform for ordinary DML even without any WITH clause — this is what the
    // first version of this test got wrong: it built a `Minimum Access - Salesforce` user with
    // ZERO permission set assignments, and that profile grants NO object CRUD on Transaction__c
    // at all, so the parent-record work threw `System.SecurityException: Access to entity
    // 'Transaction__c' denied` before the Task-FLS behavior under test was ever reached.
    //
    // The fix mirrors the real production principal (someone who can work with Transaction__c but
    // lacks the Task checklist FLS) by assigning exactly two permission sets, verified by reading
    // both files' metadata directly rather than assumed:
    //   - DPEG_Transaction_Edit    -> Transaction__c/Critical_Date__c object CRUD + FLS on their
    //     OWN fields (needed for the rollup's own `update Transaction__c`). Declares NO Task
    //     field permissions at all.
    //   - Broker_Protection_Access -> Task object CRUD (Create/Read/Edit — needed for the
    //     checklist Task insert itself). Its Task field grants are ActivityDate/Description/
    //     WhatId (plus WhoId and RFC-threading fields granted for its own, unrelated feature) —
    //     NONE of Transaction_Deal__c, Onboarding__c, or Onboarding_Status__c. It is a
    //     cross-module borrow purely for this object-CRUD grant: it is the ONLY permission set in
    //     the repo that grants Task CRUD without ALSO granting the checklist FLS this test needs
    //     withheld (DPEG_Task_Edit and DPEG_TaskChecklist_View are the only two sets in the repo
    //     that declare Task.Transaction_Deal__c, and neither is assigned here).
    //
    // These two tests reproduce the EXACT trigger-fired path (no direct selector call) and assert
    // the insert now SUCCEEDS. Deliberately no try/catch: on the OLD code, TaskRollupTrigger's
    // uncaught QueryException surfaces at this `insert` statement as a System.DmlException, which
    // fails the test method outright — that failure IS the regression pin.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 REGRESSION PIN — reproduces the production failure this session's TaskSelector change
     * fixes, at small scale (mirroring the shape of the real incident, which happened at 82
     * Tasks in one trigger batch chunk).
     */
    @isTest
    static void testRecalc_minimumAccessUserNoFLS_triggerFiredInsertSucceeds_pinsThe82TaskProductionIncident() {
        User minAccessUser = buildMinimumAccessUser('rollupFlsA');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert minAccessUser;
            assignPermissionSets(minAccessUser.Id, new Set<String>{ 'DPEG_Transaction_Edit', 'Broker_Protection_Access' });
        }

        Id txnId;
        Test.startTest();
        System.runAs(minAccessUser) {
            Transaction__c t = TestDataFactory.createTransaction(null, null, false);
            TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
            insert t; // Create CRUD on Transaction__c comes from DPEG_Transaction_Edit
            txnId = t.Id;

            // Mirrors TaskFanoutQueueable's Day-0 checklist shape (Transaction_Deal__c +
            // Task_Group__c) — the exact insert that rolled back in production under WITH USER_MODE.
            // Create CRUD on Task comes from Broker_Protection_Access; neither assigned permission
            // set grants FLS on Transaction_Deal__c.
            insert new List<Task>{
                new Task(Transaction_Deal__c = txnId, Subject = 'Sign PSA', Status = 'Completed',
                    Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1),
                new Task(Transaction_Deal__c = txnId, Subject = 'Open Escrow', Status = 'Not Started',
                    Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 2,
                    ActivityDate = Date.today().addDays(-1))
            };
        }
        Test.stopTest();

        Transaction__c reloaded = [SELECT Tasks_Complete__c, Tasks_Overdue__c FROM Transaction__c WHERE Id = :txnId];
        System.assertEquals(1, reloaded.Tasks_Complete__c,
            'The insert (and the trigger-fired rollup recompute it caused) succeeded for a principal '
            + 'who can work with Transaction__c but has no FLS grant on Transaction_Deal__c, and '
            + 'counted the one completed checklist Task');
        System.assertEquals(1, reloaded.Tasks_Overdue__c,
            'The open, past-due checklist Task is also counted, proving the rollup arithmetic — not '
            + 'just the insert — completed correctly under this persona');
    }

    /**
     * Bulk companion to the test above (.claude/rules/bulk-test-rule.md — 251+ for a real trigger
     * with no exemption). The production incident happened at 82 Tasks (one trigger batch chunk);
     * 251 forces a SECOND TaskRollupTrigger batch chunk, proving the WITH SYSTEM_MODE fix holds
     * across both chunks, not just the first.
     */
    @isTest
    static void testRecalc_minimumAccessUserNoFLS_bulk251_triggerFiredInsertSucceedsAcrossSecondBatchChunk() {
        User minAccessUser = buildMinimumAccessUser('rollupFlsB');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert minAccessUser;
            assignPermissionSets(minAccessUser.Id, new Set<String>{ 'DPEG_Transaction_Edit', 'Broker_Protection_Access' });
        }

        Id txnId;
        Test.startTest();
        System.runAs(minAccessUser) {
            Transaction__c t = TestDataFactory.createTransaction(null, null, false);
            TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
            insert t;
            txnId = t.Id;

            List<Task> tasks = new List<Task>();
            for (Integer i = 0; i < 150; i++) {
                tasks.add(new Task(Transaction_Deal__c = txnId, Subject = 'Complete ' + i, Status = 'Completed'));
            }
            for (Integer i = 0; i < 101; i++) {
                tasks.add(new Task(Transaction_Deal__c = txnId, Subject = 'Open ' + i, Status = 'Not Started',
                    ActivityDate = Date.today().addDays(10)));
            }
            insert tasks; // 251 Tasks, one DML -> forces a second TaskRollupTrigger batch chunk
        }
        Test.stopTest();

        Transaction__c reloaded = [SELECT Tasks_Complete__c, Tasks_Overdue__c FROM Transaction__c WHERE Id = :txnId];
        System.assertEquals(150, reloaded.Tasks_Complete__c,
            'All 150 completed Tasks are counted after a 251-row insert that crosses a second trigger '
            + 'batch chunk');
        System.assertEquals(0, reloaded.Tasks_Overdue__c,
            'The 101 open Tasks have a future ActivityDate, so none are overdue');

        Integer totalTasks = [SELECT COUNT() FROM Task WHERE Transaction_Deal__c = :txnId];
        System.assertEquals(251, totalTasks, 'All 251 Tasks were inserted in the single bulk DML');
    }

    /**
     * Builds (but does not insert) a user on the 'Minimum Access - Salesforce' profile. By itself
     * this profile grants NO object CRUD on any custom object and NO FLS on any custom field.
     * Each test assigns exactly the permission sets it needs via assignPermissionSets below — see
     * the design note above this section for which, and why.
     */
    private static User buildMinimumAccessUser(String tag) {
        Profile minimumAccessProfile = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Min',
            LastName = 'Access',
            Alias = 'minroll',
            Email = 'min.access.rollup@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccessProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    /**
     * Assigns the named permission sets to an already-inserted user. PermissionSetAssignment is a
     * setup object, so callers must invoke this inside the same
     * `System.runAs(new User(Id = UserInfo.getUserId()))` isolation block used for the User
     * insert itself — mixing setup-object TYPES together in one transaction is fine; mixing
     * setup and non-setup objects together is what throws MIXED_DML_OPERATION.
     */
    private static void assignPermissionSets(Id userId, Set<String> permissionSetNames) {
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
            assignments.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id));
        }
        insert assignments;
    }
}
