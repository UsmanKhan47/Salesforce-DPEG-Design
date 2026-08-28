@isTest
private class TransactionTaskControllerTest {

    /** Shared helper: an Active Transaction with the fan-out Flow suppressed (no Contract_Executed_Date__c). */
    private static Transaction__c newSuppressedTransaction() {
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        return t;
    }

    @isTest
    static void testGroupsAndToggle() {
        // No Contract_Executed_Date so the fan-out Flow doesn't fire; tasks inserted directly.
        Transaction__c t = newSuppressedTransaction();
        insert t;

        insert new List<Task>{
            new Task(Transaction_Deal__c = t.Id, Subject = 'A1', Task_Group__c = 'A. Contract Execution & Title Opening',
                Task_Sequence__c = 1, Task_Owner_Label__c = 'Danish', Status = 'Completed'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'A2', Task_Group__c = 'A. Contract Execution & Title Opening',
                Task_Sequence__c = 2, Task_Owner_Label__c = 'Danish', Status = 'Not Started'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'F1', Task_Group__c = 'F. Loan Package & Financing',
                Task_Sequence__c = 1, Task_Owner_Label__c = 'CFO', Status = 'Not Started')
        };

        Test.startTest();
        List<TransactionTaskController.GroupRow> groups = TransactionTaskController.getTaskGroups(t.Id);
        Id a2Id = [SELECT Id FROM Task WHERE Subject = 'A2' AND Transaction_Deal__c = :t.Id LIMIT 1].Id;
        TransactionTaskController.setTaskStatus(a2Id, true);
        Test.stopTest();

        Map<String, TransactionTaskController.GroupRow> byLetter = new Map<String, TransactionTaskController.GroupRow>();
        for (TransactionTaskController.GroupRow g : groups) {
            byLetter.put(g.letter, g);
        }
        System.assert(byLetter.containsKey('A'), 'Group A present');
        System.assertEquals(2, byLetter.get('A').total, 'Group A has 2 tasks');
        System.assertEquals(1, byLetter.get('A').complete, 'Group A had 1 complete at query time');
        System.assertEquals(50, byLetter.get('A').pct, 'Group A 50% complete');
        System.assert(byLetter.containsKey('F'), 'Group F present');
        System.assertEquals(true, byLetter.get('F').conditional, 'F is the conditional Financing group');

        // toggle persisted
        System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :a2Id].Status, 'A2 marked complete');
    }

    @isTest
    static void testWireVerificationGate() {
        Transaction__c t = newSuppressedTransaction();
        insert t;
        Task wire = new Task(Transaction_Deal__c = t.Id, Status = 'Not Started',
            Subject = 'Verify wiring instructions by phone (anti-fraud)',
            Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = 2);
        insert wire;

        Test.startTest();
        Boolean threw = false;
        try {
            TransactionTaskController.completeWireVerification(wire.Id, '', '', null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank name/phone must block closure');

        TransactionTaskController.completeWireVerification(wire.Id, 'Jane Doe', '713-555-0100', null);
        Test.stopTest();

        Task r = [
            SELECT Status, IsClosed, Verbal_Verification_Completed__c, Verified_By__c,
                   Verification_Phone__c, Verified_At__c, Description
            FROM Task WHERE Id = :wire.Id
        ];
        System.assertEquals('Completed', r.Status, 'Task closed after verification');
        System.assertEquals(true, r.Verbal_Verification_Completed__c, 'Verification flag set');
        System.assertEquals('Jane Doe', r.Verified_By__c);
        System.assertEquals('713-555-0100', r.Verification_Phone__c);
        System.assertNotEquals(null, r.Verified_At__c, 'Timestamp stamped');
        System.assert(r.Description != null && r.Description.contains('Verified by phone with Jane Doe'),
            'Step-6 note logged to comments');
    }

    @isTest
    static void testCompleteWireVerification_withCommentsAndExistingDescription_appendsInOrder() {
        Transaction__c t = newSuppressedTransaction();
        insert t;
        Task wire = new Task(Transaction_Deal__c = t.Id, Status = 'Not Started',
            Subject = 'Verify wiring instructions by phone (anti-fraud)',
            Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = 2,
            Description = 'Prior note from earlier in the deal.');
        insert wire;

        Test.startTest();
        TransactionTaskController.completeWireVerification(wire.Id, 'Jane Doe', '713-555-0100',
            'Called title company twice to confirm.');
        Test.stopTest();

        Task r = [SELECT Description FROM Task WHERE Id = :wire.Id];
        System.assert(r.Description.startsWith('Prior note from earlier in the deal.'),
            'Existing Description is preserved, not overwritten');
        System.assert(r.Description.contains('Called title company twice to confirm.'),
            'Verifier comments are appended');
        System.assert(r.Description.contains('Verified by phone with Jane Doe'),
            'Standard verification note is appended after the comments');
    }

    @isTest
    static void testCompleteTask_withNotes_setsDescriptionAndCompletes() {
        Transaction__c t = newSuppressedTransaction();
        insert t;
        Task tsk = new Task(Transaction_Deal__c = t.Id, Subject = 'A1',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1,
            Task_Owner_Label__c = 'Danish', Status = 'Not Started');
        insert tsk;

        Test.startTest();
        TransactionTaskController.completeTask(tsk.Id, '  Called the seller to confirm.  ');
        Test.stopTest();

        Task reloaded = [SELECT Status, Description FROM Task WHERE Id = :tsk.Id];
        System.assertEquals('Completed', reloaded.Status, 'Task closed');
        System.assertEquals('Called the seller to confirm.', reloaded.Description, 'Notes are trimmed and saved to Description');
    }

    @isTest
    static void testCompleteTask_blankNotes_leavesExistingDescriptionUntouched() {
        Transaction__c t = newSuppressedTransaction();
        insert t;
        Task tsk = new Task(Transaction_Deal__c = t.Id, Subject = 'A1',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1,
            Task_Owner_Label__c = 'Danish', Status = 'Not Started', Description = 'Pre-existing comment');
        insert tsk;

        Test.startTest();
        TransactionTaskController.completeTask(tsk.Id, '   '); // blank/whitespace-only
        Test.stopTest();

        Task reloaded = [SELECT Status, Description FROM Task WHERE Id = :tsk.Id];
        System.assertEquals('Completed', reloaded.Status, 'Task closed even with no new notes');
        System.assertEquals('Pre-existing comment', reloaded.Description, 'Blank notes must not overwrite existing comments');
    }

    @isTest
    static void testGetTaskGroups_noTasks_returnsEmptyList() {
        Transaction__c t = newSuppressedTransaction();
        insert t;

        Test.startTest();
        List<TransactionTaskController.GroupRow> groups = TransactionTaskController.getTaskGroups(t.Id);
        Test.stopTest();

        System.assertEquals(0, groups.size(), 'No checklist Tasks means no groups to render');
    }

    /**
     * Bulk: 251 Tasks in one DML across 3 real checklist groups, proving getTaskGroups'
     * aggregation (grouping, completion counts, percentages) holds at scale, and forcing a
     * second TaskRollupTrigger batch chunk in the same stroke, per .claude/rules/bulk-test-rule.md.
     */
    @isTest
    static void testGetTaskGroups_bulk251TasksAcrossGroups() {
        Transaction__c t = newSuppressedTransaction();
        insert t;

        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < 100; i++) {
            tasks.add(new Task(Transaction_Deal__c = t.Id, Subject = 'A' + i,
                Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = i + 1,
                Status = i < 40 ? 'Completed' : 'Not Started'));
        }
        for (Integer i = 0; i < 100; i++) {
            tasks.add(new Task(Transaction_Deal__c = t.Id, Subject = 'B' + i,
                Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = i + 1, Status = 'Completed'));
        }
        for (Integer i = 0; i < 51; i++) {
            tasks.add(new Task(Transaction_Deal__c = t.Id, Subject = 'C' + i,
                Task_Group__c = 'C. Property Condition Report (BBG)', Task_Sequence__c = i + 1, Status = 'Not Started'));
        }
        insert tasks; // 251 Tasks in one DML - forces a second trigger chunk for TaskRollupTrigger too

        Test.startTest();
        List<TransactionTaskController.GroupRow> groups = TransactionTaskController.getTaskGroups(t.Id);
        Test.stopTest();

        Map<String, TransactionTaskController.GroupRow> byLetter = new Map<String, TransactionTaskController.GroupRow>();
        Integer totalAcrossGroups = 0;
        for (TransactionTaskController.GroupRow g : groups) {
            byLetter.put(g.letter, g);
            totalAcrossGroups += g.total;
        }
        System.assertEquals(251, totalAcrossGroups, 'All 251 Tasks are accounted for across groups with no SOQL/loop truncation');
        System.assertEquals(100, byLetter.get('A').total, 'Group A has all 100 of its tasks');
        System.assertEquals(40, byLetter.get('A').complete, 'Group A completion count correct at scale');
        System.assertEquals(100, byLetter.get('B').complete, 'Group B fully complete');
        System.assertEquals(100, byLetter.get('B').pct, 'Group B percent complete rounds to 100');
        System.assertEquals(51, byLetter.get('C').total, 'Group C has all 51 of its tasks');
        System.assertEquals(0, byLetter.get('C').complete, 'Group C nothing complete yet');
    }

    // A valid-format but non-existent Id for the given type. The bare-user read throws on
    // FLS under WITH USER_MODE before any row match, so the Id need not resolve.
    private static Id fakeId(Schema.SObjectType t) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '000000000000');
    }

    // A bare Standard User with no DPEG perm sets: WITH USER_MODE SOQL selecting the custom
    // Task fields (Task_Group__c, Task_Sequence__c, …) throws for a user with no FLS on
    // them, exercising getTaskGroups' read-failure catch (P6 boundaries).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.tt.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    /**
     * Covers getTaskGroups' read-failure catch: under a bare Standard User, WITH USER_MODE
     * on the checklist query's custom Task fields throws (no FLS), and the controller maps
     * it to a user-safe AuraHandledException. Its own method because bareUser() inserts a
     * User (setup DML); the read throws at the query, so no record DML runs here
     * (avoids MIXED_DML_OPERATION).
     */
    @isTest
    static void readCatchThrowsAuraHandledException() {
        User u = bareUser();
        Id fakeTxnId = fakeId(Transaction__c.SObjectType);
        System.runAs(u) {
            Test.startTest();
            try {
                TransactionTaskController.getTaskGroups(fakeTxnId);
                Assert.fail('getTaskGroups should throw under a bare user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getTaskGroups maps read failure to AuraHandledException');
            }
            Test.stopTest();
        }
    }

    /**
     * Covers the generic write-failure catch on all three write methods: a deleted Task Id
     * makes the update / single-row read fail under admin — the deterministic way to reach
     * the write-failure catch. Kept apart from the bare-user read test so the setup-object
     * User insert and this record DML never share a transaction (MIXED_DML_OPERATION).
     */
    /**
     * REGRESSION — reported from the UI 2026-08-28. A completed checklist row read
     * "Danish · Aug 28, 2026" when the ADMIN, not Danish, had completed it: the row's meta
     * line was built from Task_Owner_Label__c, which is STATIC TEXT seeded from
     * Transaction_Task_Def__mdt naming the intended ROLE. It never changes, is not the record
     * owner, and next to a completion date it asserted something false.
     *
     * The honest fixture is one where the completer DIFFERS from the role label — exactly the
     * reported case. Here the task is labelled 'Danish' and the test-running user (standing in
     * for the admin) closes it, so completedByName and ownerLabel MUST diverge. A fixture where
     * they coincide would pass under the defective code too and prove nothing.
     *
     * ⚠ completedByName is LastModifiedBy — who last TOUCHED the record. Task has no dedicated
     * completed-by field, so a later edit to a closed task reassigns the name. That imprecision
     * is accepted and documented at the assignment site in TransactionTaskController; it is
     * still strictly better than a role label that is wrong for everyone but one person.
     */
    @isTest
    static void getTaskGroups_completedRowNamesTheCompleter_notTheStaticRoleLabel() {
        Transaction__c t = newSuppressedTransaction();
        insert t;

        insert new List<Task>{
            new Task(Transaction_Deal__c = t.Id, Subject = 'A1',
                Task_Group__c = 'A. Contract Execution & Title Opening',
                Task_Sequence__c = 1, Task_Owner_Label__c = 'Danish', Status = 'Completed'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'A2',
                Task_Group__c = 'A. Contract Execution & Title Opening',
                Task_Sequence__c = 2, Task_Owner_Label__c = 'Danish', Status = 'Not Started')
        };

        Test.startTest();
        List<TransactionTaskController.GroupRow> groups = TransactionTaskController.getTaskGroups(t.Id);
        Test.stopTest();

        TransactionTaskController.GroupRow groupA = null;
        for (TransactionTaskController.GroupRow g : groups) {
            if (g.letter == 'A') { groupA = g; }
        }
        Assert.isNotNull(groupA, 'Group A must be returned');

        TransactionTaskController.TaskRow done = groupA.tasks[0];
        TransactionTaskController.TaskRow open = groupA.tasks[1];
        Assert.areEqual(true, done.done, 'Sequence 1 is the completed task');
        Assert.areEqual(false, open.done, 'Sequence 2 is still open');

        // FIXTURE INTEGRITY — without this the two assertions below could both pass on the
        // same string and the test would be vacuous.
        Assert.areEqual('Danish', done.ownerLabel,
            'The row still carries the static ROLE label from Transaction_Task_Def__mdt');
        Assert.areNotEqual('Danish', UserInfo.getName(),
            'The completing user must not BE the role label, or this test proves nothing');

        // THE FIX: the completed row names the person who actually closed it.
        Assert.areEqual(UserInfo.getName(), done.completedByName,
            'A completed row reports WHO COMPLETED it (LastModifiedBy.Name), not the role label');
        Assert.areNotEqual(done.ownerLabel, done.completedByName,
            'completedByName must not be the static role label — that was the reported defect');
        Assert.isNotNull(done.completedDate, 'A completed row still carries its completion date');

        // Gated on IsClosed, exactly like completedDate: an open task has no completer.
        Assert.isNull(open.completedByName,
            'An OPEN task reports no completer — completedByName is IsClosed-gated like completedDate');
        Assert.isNull(open.completedDate,
            'An OPEN task reports no completion date (the pre-existing gate, pinned alongside)');

        // The GROUP header pill is a DIFFERENT field (Task_Group_Def__mdt.Owner_Label__c) and is
        // CORRECT — it is the group's owning role, not a claim about who did anything.
        Assert.isNotNull(groupA.ownerLabel,
            'The group header keeps its owning-role label; only the per-ROW meta line was wrong');
    }

    @isTest
    static void writeCatchesThrowAuraHandledException() {
        Transaction__c t = newSuppressedTransaction();
        insert t;
        List<Task> tasks = new List<Task>{
            new Task(Transaction_Deal__c = t.Id, Subject = 'del1', Status = 'Not Started'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'del2', Status = 'Not Started'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'del3', Status = 'Not Started',
                Task_Group__c = 'B. Earnest Money Wire')
        };
        insert tasks;
        Id deletedSetId = tasks[0].Id;
        Id deletedCompleteId = tasks[1].Id;
        Id deletedWireId = tasks[2].Id;
        delete tasks;

        Test.startTest();
        try {
            TransactionTaskController.setTaskStatus(deletedSetId, true);
            Assert.fail('setTaskStatus on a deleted Task should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'setTaskStatus write failure maps to AuraHandledException');
        }
        try {
            TransactionTaskController.completeTask(deletedCompleteId, 'note');
            Assert.fail('completeTask on a deleted Task should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'completeTask write failure maps to AuraHandledException');
        }
        // Valid name/phone so the rule passes and the deleted-Id single-row read (QueryException)
        // reaches the generic catch, not the WireVerificationException branch.
        try {
            TransactionTaskController.completeWireVerification(deletedWireId, 'Jane Doe', '713-555-0100', null);
            Assert.fail('completeWireVerification on a deleted Task should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'completeWireVerification write failure maps to AuraHandledException');
        }
        Test.stopTest();
    }
}