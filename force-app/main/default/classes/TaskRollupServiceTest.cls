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
    // ═══ 🔴 REWRITTEN 2026-08-17. THE PREVIOUS "ROUTE B" WAS STRUCTURALLY IMPOSSIBLE ══════════
    // These two tests had been red since at least 2026-08-12 (they were committed PARKED, see
    // commit ebd700e "PARKED / NOT DEPLOYED"). Two separate, compounding causes, both measured
    // against usman-dpeg on 2026-08-17 rather than reasoned about:
    //
    // CAUSE 1 — the persona could not create a Task, and no permission set could ever fix it.
    // The old fixture ran on `Minimum Access - Salesforce` and assigned Broker_Protection_Access,
    // claiming that set supplied "Task object CRUD (Create/Read/Edit)". That was read off the
    // permission set FILE, which does declare <object>Task</object> with allowCreate=true. It is
    // not what the org has:
    //     SELECT SobjectType, COUNT(Id) FROM ObjectPermissions
    //     WHERE SobjectType IN ('Task','Event','Transaction__c','Lead') GROUP BY SobjectType
    //       -> Lead 53, Transaction__c 8, Task ABSENT, Event ABSENT
    // ZERO ObjectPermissions rows exist for Task/Event anywhere in this org, on any permission set
    // OR profile: Activity CRUD is not permission-set-grantable here, the platform accepts the
    // block on deploy and stores nothing. It lives on the PROFILE as its own boolean —
    //     SELECT Name, PermissionsEditTask FROM Profile
    //       -> Minimum Access - Salesforce = false     Standard User = true
    // — so the assignment was inert and the tests failed `System.TypeException: DML operation
    // INSERT not allowed on Task`. The persona now runs on `Standard User`, the least-privileged
    // profile in this org that can create a Task at all. It still grants NO FLS on any
    // Metadata-API-deployed custom field, so it costs the test nothing (see the DISCRIMINATION
    // section below). Broker_Protection_Access is dropped: an inert assignment carrying a comment
    // that explains its non-existent purpose is how the next reader loses another day.
    //
    // CAUSE 2 — 🔴 AND THIS IS THE ONE THAT KILLS ROUTE B OUTRIGHT. With CRUD fixed, the insert
    // then failed `System.DmlException: Operation failed due to fields being inaccessible on
    // Sobject Task`. Ordinary DML on Task in this org is FLS-enforced, and the ONLY custom field
    // the bulk fixture writes is Transaction_Deal__c — so it is that field, by elimination.
    // ⇒ INSERTING THE FIXTURE REQUIRES EDIT FLS ON EXACTLY THE FIELD THIS TEST MUST WITHHOLD, and
    // FLS edit implies read, so there is no grant that satisfies both halves. "Have the restricted
    // principal insert the checklist Task itself" is not a fixture that needs more permissions —
    // it is a self-contradiction, and no amount of permission-set work reaches it.
    //
    // THE FIX — FIRE THE TRIGGER WITH AN UPDATE, NOT AN INSERT. The fixture (parent + checklist
    // Tasks) is built in the DEFAULT full-access context and OWNED BY the persona; the persona
    // then edits a STANDARD field on its own Task inside System.runAs, which re-fires
    // TaskRollupTrigger under THEIR identity and runs the exact selector call the incident died
    // on. Nothing about the property under test is lost:
    //   - the recompute still runs inside a trigger, on the persona's behalf, with no FLS on
    //     Transaction_Deal__c — that is the whole claim;
    //   - a USER_MODE query still throws `No such column 'Transaction_Deal__c' on entity 'Task'`,
    //     still escapes as CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY, and still rolls back the
    //     persona's own DML. Only which DML gets rolled back changed.
    // It is also the REACHABLE form of the defect: a principal with no FLS on Transaction_Deal__c
    // can never insert a checklist Task in the first place, so the only way they ever reach this
    // trigger in production is by editing one — marking a checklist item complete, exactly what
    // OnboardingService.completeTask does on the sibling module.
    // ⚠ The fixture Tasks MUST be owned by the persona. Activity is `sharingModel Private` here
    // with no sharing rules, so an admin-owned Task is invisible to them and the recompute would
    // silently count zero — the identical trap that was independently costing TaskSelectorTest's
    // two Route A pins their green (fixed in the same pass).
    //
    // DISCRIMINATION — the property the whole test exists for, verified rather than assumed:
    //     SELECT Parent.Name, Parent.IsOwnedByProfile FROM FieldPermissions
    //     WHERE Field = 'Task.Transaction_Deal__c'
    //       -> DPEG_Transaction_Team, DPEG_Junior_Analyst_PSG, DPEG_TaskChecklist_View,
    //          DPEG_Task_Edit, sfdc_slack  —  ALL IsOwnedByProfile = false.
    // NO PROFILE grants it, `Standard User` included, and none of those four sets is assigned
    // below. Restore `WITH USER_MODE` on TaskSelector.selectByTransactionDealIds and both tests go
    // RED again at the persona's `update`. ⚠ If a future admin ever grants
    // Task.Transaction_Deal__c at the PROFILE level, these tests silently stop discriminating —
    // re-run the query above before trusting a green result.
    //
    // ⚠ RENAMED in the same pass: `..._triggerFiredInsertSucceeds_...` would now be a lie, since
    // the trigger is fired by an update. Old -> new is
    //   testRecalc_minimumAccessUserNoFLS_triggerFiredInsertSucceeds_pinsThe82TaskProductionIncident
    //     -> testRecalc_noFlsUser_triggerFiredRecomputeSucceeds_pinsThe82TaskProductionIncident
    //   testRecalc_minimumAccessUserNoFLS_bulk251_triggerFiredInsertSucceedsAcrossSecondBatchChunk
    //     -> testRecalc_noFlsUser_bulk251_triggerFiredRecomputeSucceedsAcrossSecondBatchChunk
    //
    // Deliberately no try/catch in either: on the OLD code the trigger's uncaught QueryException
    // surfaces at the persona's DML statement as a System.DmlException and fails the method
    // outright — that failure IS the regression pin.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 REGRESSION PIN — reproduces the production failure the TaskSelector WITH SYSTEM_MODE
     * change fixes, at small scale (the real incident happened at 82 Tasks in one trigger batch
     * chunk). The persona edits its own checklist Task, which re-fires TaskRollupTrigger under
     * their identity; the rollup then reads Transaction_Deal__c — the field they have no FLS on.
     */
    @isTest
    static void testRecalc_noFlsUser_triggerFiredRecomputeSucceeds_pinsThe82TaskProductionIncident() {
        User noFlsUser = buildTaskCapableNoFlsUser('rollupFlsA');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert noFlsUser;
            assignPermissionSets(noFlsUser.Id, new Set<String>{ 'DPEG_Transaction_Edit' });
        }

        // Fixture built in the DEFAULT full-access context — writing Transaction_Deal__c needs
        // edit FLS this persona must NOT have (see the design note above). OWNED BY the persona:
        // Activity is Private here, so an admin-owned Task would be invisible to the recompute and
        // the rollup would count zero, and the persona must own the Transaction__c for the
        // rollup's own `update` to pass sharing (DPEG_Transaction_Edit grants View All, not
        // Modify All).
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        t.OwnerId = noFlsUser.Id;
        insert t;
        Id txnId = t.Id;

        // Mirrors TaskFanoutQueueable's Day-0 checklist shape (Transaction_Deal__c + Task_Group__c).
        List<Task> checklist = new List<Task>{
            new Task(Transaction_Deal__c = txnId, Subject = 'Sign PSA', Status = 'Completed',
                Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1,
                OwnerId = noFlsUser.Id),
            new Task(Transaction_Deal__c = txnId, Subject = 'Open Escrow', Status = 'Not Started',
                Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 2,
                ActivityDate = Date.today().addDays(-1), OwnerId = noFlsUser.Id)
        };
        insert checklist;

        Test.startTest();
        System.runAs(noFlsUser) {
            // The reachable form of the incident: the persona touches a STANDARD field on its own
            // checklist Task (it cannot write Transaction_Deal__c, and does not). That re-fires
            // TaskRollupTrigger -> TaskRollupService -> selectByTransactionDealIds under THEIR
            // identity. Under the reverted WITH USER_MODE the query throws `No such column
            // 'Transaction_Deal__c' on entity 'Task'`, escapes as
            // CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY and rolls this update back — no try/catch, so
            // that surfaces here as a DmlException and fails the method. That failure IS the pin.
            update new List<Task>{
                new Task(Id = checklist[0].Id, Status = 'Completed'),
                new Task(Id = checklist[1].Id, Status = 'Not Started')
            };
        }
        Test.stopTest();

        Transaction__c reloaded = [SELECT Tasks_Complete__c, Tasks_Overdue__c FROM Transaction__c WHERE Id = :txnId];
        System.assertEquals(1, reloaded.Tasks_Complete__c,
            'The persona\'s own edit (and the trigger-fired rollup recompute it caused) succeeded '
            + 'for a principal who can work with Transaction__c but has no FLS grant on '
            + 'Transaction_Deal__c, and counted the one completed checklist Task');
        System.assertEquals(1, reloaded.Tasks_Overdue__c,
            'The open, past-due checklist Task is also counted, proving the rollup arithmetic — not '
            + 'just the DML — completed correctly under this persona');
    }

    /**
     * Bulk companion to the test above (.claude/rules/bulk-test-rule.md — 251+ for a real trigger
     * with no exemption). The production incident happened at 82 Tasks (one trigger batch chunk);
     * 251 forces a SECOND TaskRollupTrigger batch chunk, proving the WITH SYSTEM_MODE fix holds
     * across both chunks, not just the first.
     */
    @isTest
    static void testRecalc_noFlsUser_bulk251_triggerFiredRecomputeSucceedsAcrossSecondBatchChunk() {
        User noFlsUser = buildTaskCapableNoFlsUser('rollupFlsB');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert noFlsUser;
            assignPermissionSets(noFlsUser.Id, new Set<String>{ 'DPEG_Transaction_Edit' });
        }

        // Fixture in the default full-access context, owned by the persona — see the sibling test
        // above and the design note for why both halves of that are load-bearing.
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        t.OwnerId = noFlsUser.Id;
        insert t;
        Id txnId = t.Id;

        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < 150; i++) {
            tasks.add(new Task(Transaction_Deal__c = txnId, Subject = 'Complete ' + i, Status = 'Completed',
                OwnerId = noFlsUser.Id));
        }
        for (Integer i = 0; i < 101; i++) {
            tasks.add(new Task(Transaction_Deal__c = txnId, Subject = 'Open ' + i, Status = 'Not Started',
                ActivityDate = Date.today().addDays(10), OwnerId = noFlsUser.Id));
        }
        insert tasks;

        Test.startTest();
        System.runAs(noFlsUser) {
            // 251 Tasks re-touched in ONE DML by the persona -> TaskRollupTrigger fires across a
            // SECOND batch chunk under their identity, which is the property this bulk companion
            // exists for (.claude/rules/bulk-test-rule.md). Standard field only: the persona
            // cannot write Transaction_Deal__c and must not need to.
            List<Task> touched = new List<Task>();
            for (Task existing : tasks) {
                touched.add(new Task(Id = existing.Id, Status = existing.Status));
            }
            update touched;
        }
        Test.stopTest();

        Transaction__c reloaded = [SELECT Tasks_Complete__c, Tasks_Overdue__c FROM Transaction__c WHERE Id = :txnId];
        System.assertEquals(150, reloaded.Tasks_Complete__c,
            'All 150 completed Tasks are counted after the persona\'s 251-row update, which crosses '
            + 'a second trigger batch chunk');
        System.assertEquals(0, reloaded.Tasks_Overdue__c,
            'The 101 open Tasks have a future ActivityDate, so none are overdue');

        Integer totalTasks = [SELECT COUNT() FROM Task WHERE Transaction_Deal__c = :txnId];
        System.assertEquals(251, totalTasks, 'All 251 Tasks are present and were re-touched in a single bulk DML');
    }

    /**
     * Builds (but does not insert) a user on the `Standard User` profile — the LEAST-privileged
     * profile in this org that can create a Task at all (`PermissionsEditTask = true`, measured;
     * `Minimum Access - Salesforce` is `false`, and no permission set can supply it because Task
     * has zero ObjectPermissions rows org-wide — see the design note above this section).
     *
     * 🔴 What the profile does NOT give is the point: it grants NO FLS on any Metadata-API-
     * deployed custom field, so this persona still cannot read Task.Transaction_Deal__c. That is
     * the single fact the regression pins depend on. Each test assigns, via assignPermissionSets
     * below, only the custom-OBJECT CRUD it needs — never a set that declares the withheld Task
     * fields (DPEG_Task_Edit / DPEG_TaskChecklist_View / DPEG_Transaction_Team must never be
     * assigned here).
     */
    private static User buildTaskCapableNoFlsUser(String tag) {
        Profile minimumAccessProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
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
