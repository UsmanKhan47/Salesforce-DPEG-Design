/**
 * Tests for TaskSelector (P4, Module C — Transactions; SHARED cross-module selector).
 *
 * Covers all three relocated/contract queries:
 *   - selectChecklistByTransactionDealIds : field population, ORDER BY
 *     Task_Sequence__c, the `Task_Group__c != null` filter, the null/empty-input
 *     guard, and a 251-record bulk read on the Set<Id> method (bulk-test-rule).
 *   - selectOpenByWhatIdsAndSubjectPrefix  : open-only + subject-prefix filtering,
 *     null/empty/blank guards, a 251-record bulk read across 251 distinct WhatIds,
 *     AND the standard-object USER_MODE proof (a Standard User reads rows under
 *     WITH USER_MODE — design §5/§7 requirement for standard-object selectors).
 *   - selectRequiredById : happy path (Id + Description selected) and the
 *     missing-Id -> System.QueryException contract completeWireVerification relies on.
 *
 * @TestSetup builds one Transaction with the fan-out Flow suppressed
 * (Contract_Executed_Date__c = null) so no async checklist fan-out is enqueued
 * during setup. Tests query for that Transaction rather than re-calling a
 * default*() accessor — the TestDataFactory header warns the static scaffold
 * cache does NOT survive the @TestSetup boundary.
 *
 * @see force-app/main/default/classes/WireSelectorTest.cls (P4 pilot test template)
 * @see agent-output/p4-selector-design.md (§3 #18, §5, §7)
 */
@isTest
private class TaskSelectorTest {

    private static final String GROUP_A = 'A. Contract Execution & Title Opening';
    private static final String REMINDER_PREFIX = 'Check in with broker';

    @testSetup
    static void setup() {
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert t;
    }

    private static Id transactionId() {
        return [SELECT Id FROM Transaction__c LIMIT 1].Id;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectChecklistByTransactionDealIds
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectChecklistByTransactionDealIds_populatesFieldsAndOrdersBySequence() {
        Id txnId = transactionId();
        Datetime verifiedAt = Datetime.newInstance(2026, 7, 16, 9, 15, 0);

        // Inserted out of sequence to prove ORDER BY Task_Sequence__c.
        Task second = new Task(
            Transaction_Deal__c = txnId, Subject = 'Open Escrow', Task_Group__c = GROUP_A,
            Task_Owner_Label__c = 'Danish', Status = 'Not Started', ActivityDate = Date.today().addDays(2),
            Task_Sequence__c = 2, Description = 'second note'
        );
        Task first = new Task(
            Transaction_Deal__c = txnId, Subject = 'Sign PSA', Task_Group__c = GROUP_A,
            Task_Owner_Label__c = 'Danish', Status = 'Completed', ActivityDate = Date.today(),
            Task_Sequence__c = 1, Verbal_Verification_Completed__c = true, Verified_By__c = 'Jane Verifier',
            Verification_Phone__c = '555-0100', Verified_At__c = verifiedAt, Description = 'first note'
        );
        // Must be excluded — no Task_Group__c.
        Task ungrouped = new Task(
            Transaction_Deal__c = txnId, Subject = 'Ad-hoc', Status = 'Not Started', Task_Sequence__c = 3
        );
        insert new List<Task>{ second, first, ungrouped };

        Test.startTest();
        List<Task> rows = TaskSelector.selectChecklistByTransactionDealIds(new Set<Id>{ txnId });
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Only the two Task_Group__c-bearing checklist Tasks are returned; the ungrouped Task is filtered out');
        Assert.areEqual(1, rows[0].Task_Sequence__c, 'ORDER BY Task_Sequence__c must return sequence 1 first even though it was inserted second');
        Assert.areEqual('Sign PSA', rows[0].Subject, 'Subject is selected');
        Assert.areEqual(GROUP_A, rows[0].Task_Group__c, 'Task_Group__c is selected');
        Assert.areEqual('Danish', rows[0].Task_Owner_Label__c, 'Task_Owner_Label__c is selected');
        Assert.areEqual('Completed', rows[0].Status, 'Status is selected');
        Assert.areEqual(true, rows[0].IsClosed, 'IsClosed is selected (derived from the Completed status)');
        Assert.areEqual(Date.today(), rows[0].ActivityDate, 'ActivityDate is selected');
        Assert.areEqual(true, rows[0].Verbal_Verification_Completed__c, 'Verbal_Verification_Completed__c is selected');
        Assert.areEqual('Jane Verifier', rows[0].Verified_By__c, 'Verified_By__c is selected');
        Assert.areEqual('555-0100', rows[0].Verification_Phone__c, 'Verification_Phone__c is selected');
        Assert.areEqual(verifiedAt, rows[0].Verified_At__c, 'Verified_At__c is selected');
        Assert.areEqual('first note', rows[0].Description, 'Description is selected');
        Assert.areEqual(2, rows[1].Task_Sequence__c, 'The sequence-2 Task sorts after sequence-1');
    }

    @isTest
    static void selectChecklistByTransactionDealIds_nullOrEmpty_returnsEmpty() {
        Test.startTest();
        List<Task> forNull = TaskSelector.selectChecklistByTransactionDealIds(null);
        List<Task> forEmpty = TaskSelector.selectChecklistByTransactionDealIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null id set short-circuits to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty id set short-circuits to an empty list, not null');
    }

    @isTest
    static void selectChecklistByTransactionDealIds_bulk251_readsAllViaSetId() {
        Id txnId = transactionId();
        TestDataFactory.createChecklistTasks(251, txnId, true);

        Test.startTest();
        List<Task> rows = TaskSelector.selectChecklistByTransactionDealIds(new Set<Id>{ txnId });
        Test.stopTest();

        Assert.areEqual(251, rows.size(), 'The Set<Id> checklist read returns all 251 Tasks at bulk volume');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectOpenByWhatIdsAndSubjectPrefix
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectOpenByWhatIdsAndSubjectPrefix_returnsOnlyOpenMatchingSubject() {
        Account acct = TestDataFactory.createAccount(true);

        Task openMatch = new Task(WhatId = acct.Id, Subject = REMINDER_PREFIX + ' — Acme', Status = 'Not Started');
        Task closedMatch = new Task(WhatId = acct.Id, Subject = REMINDER_PREFIX + ' — Beta', Status = 'Completed');
        Task openOther = new Task(WhatId = acct.Id, Subject = 'Unrelated follow-up', Status = 'Not Started');
        insert new List<Task>{ openMatch, closedMatch, openOther };

        Test.startTest();
        List<Task> rows = TaskSelector.selectOpenByWhatIdsAndSubjectPrefix(
            new Set<Id>{ acct.Id }, REMINDER_PREFIX);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the open Task whose Subject starts with the prefix is returned');
        Assert.areEqual(openMatch.Id, rows[0].Id, 'The open, subject-matching Task is the one returned');
        Assert.areEqual(acct.Id, rows[0].WhatId, 'WhatId is selected so the caller can build its idempotency set');
    }

    @isTest
    static void selectOpenByWhatIdsAndSubjectPrefix_nullEmptyBlank_returnsEmpty() {
        Account acct = TestDataFactory.createAccount(true);

        Test.startTest();
        List<Task> forNullIds = TaskSelector.selectOpenByWhatIdsAndSubjectPrefix(null, REMINDER_PREFIX);
        List<Task> forEmptyIds = TaskSelector.selectOpenByWhatIdsAndSubjectPrefix(new Set<Id>(), REMINDER_PREFIX);
        List<Task> forBlankPrefix = TaskSelector.selectOpenByWhatIdsAndSubjectPrefix(new Set<Id>{ acct.Id }, '   ');
        Test.stopTest();

        Assert.areEqual(0, forNullIds.size(), 'Null whatIds short-circuits to empty');
        Assert.areEqual(0, forEmptyIds.size(), 'Empty whatIds short-circuits to empty');
        Assert.areEqual(0, forBlankPrefix.size(), 'A blank subject prefix short-circuits to empty (never a bare LIKE %)');
    }

    @isTest
    static void selectOpenByWhatIdsAndSubjectPrefix_bulk251_readsAllAcrossDistinctWhatIds() {
        // Build unsaved, then insert with Duplicate Rules bypassed: 251 near-identical
        // Accounts trip the org's standard Account duplicate rule at the 200-row chunk
        // boundary (matches on City/State similarity, not Name), which is noise here —
        // the point is a 251-row Set<Id> read, not duplicate detection.
        List<Account> accounts = TestDataFactory.createAccounts(251, false);
        insertBypassingDuplicateRules(accounts);
        Set<Id> whatIds = new Set<Id>();
        List<Task> tasks = new List<Task>();
        for (Account a : accounts) {
            whatIds.add(a.Id);
            tasks.add(new Task(WhatId = a.Id, Subject = REMINDER_PREFIX + ' — ' + a.Name, Status = 'Not Started'));
        }
        insert tasks;

        Test.startTest();
        List<Task> rows = TaskSelector.selectOpenByWhatIdsAndSubjectPrefix(whatIds, REMINDER_PREFIX);
        Test.stopTest();

        Assert.areEqual(251, rows.size(), 'The Set<Id> open-reminder probe returns a row for each of the 251 distinct WhatIds');
    }

    /**
     * Standard-object USER_MODE proof (design §5/§7). A freshly created Standard
     * User — with none of the custom-field permsets — reads the reminder Task
     * under WITH USER_MODE, confirming the FLS-bearing standard field WhatId is
     * readable for that persona (the exact §5 claim for Task). The Account + Task
     * DML runs inside System.runAs to (a) avoid MIXED_DML_OPERATION with the
     * setup-object User insert and (b) make the Standard User the Task owner, so
     * record visibility is guaranteed and the test isolates the FLS question.
     */
    @isTest
    static void selectOpenByWhatIdsAndSubjectPrefix_standardUser_userModeReturnsRows() {
        User standardUser = buildStandardUser();
        // Isolate the setup-object (User) DML in its own runAs context so the
        // non-setup Account/Task DML below cannot raise MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert standardUser;
        }

        Test.startTest();
        System.runAs(standardUser) {
            Account acct = new Account(Name = 'Broker Firm');
            insertBypassingDuplicateRules(new List<SObject>{ acct });
            Task reminder = new Task(
                WhatId = acct.Id,
                Subject = REMINDER_PREFIX + ' — Broker Firm',
                Status = 'Not Started',
                ActivityDate = Date.today()
            );
            insert reminder;

            List<Task> rows = TaskSelector.selectOpenByWhatIdsAndSubjectPrefix(
                new Set<Id>{ acct.Id }, REMINDER_PREFIX);

            Assert.areEqual(1, rows.size(),
                'A Standard User must read the open reminder Task under WITH USER_MODE — WhatId is Standard User READ=true per design §5');
            Assert.areEqual(acct.Id, rows[0].WhatId,
                'WhatId (an FLS-bearing standard Task field) is returned under USER_MODE for a Standard User');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectRequiredById
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectRequiredById_existingId_returnsTaskWithDescription() {
        Task t = new Task(Subject = 'Verify wire', Status = 'Not Started', Description = 'existing comments');
        insert t;

        Test.startTest();
        Task result = TaskSelector.selectRequiredById(t.Id);
        Test.stopTest();

        Assert.areEqual(t.Id, result.Id, 'selectRequiredById returns the record for the given Id');
        // Reading Description proves it is in the SELECT — a SELECT Id-only query
        // would throw SObjectException on this access.
        Assert.areEqual('existing comments', result.Description,
            'Description must be selected so completeWireVerification can decide whether to append its note');
    }

    @isTest
    static void selectRequiredById_missingId_throwsQueryException() {
        Task t = new Task(Subject = 'Temp', Status = 'Not Started');
        insert t;
        Id deletedId = t.Id;
        delete t;

        Test.startTest();
        try {
            TaskSelector.selectRequiredById(deletedId);
            Assert.fail('A Task Id that no longer exists should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching Task row: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // P4 Onboarding + Task-rollup cleanup wave — new method coverage
    // ═════════════════════════════════════════════════════════════════════════

    // ─────────────────────────────────────────────────────────────────────────
    // selectChecklistByOnboardingId
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectChecklistByOnboardingId_populatesSelectedFields() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, true);
        Task t = new Task(
            Onboarding__c = o.Id, Subject = 'Set up meters', Onboarding_Category__c = 'Property Set up',
            Onboarding_Status__c = 'Blocked', Source_System__c = 'Yardi', Task_Owner_Label__c = 'Isha Patel',
            ActivityDate = Date.today().addDays(4), Blocked_Reason__c = 'Awaiting vendor', Description = 'kickoff note'
        );
        insert t;

        Test.startTest();
        List<Task> rows = TaskSelector.selectChecklistByOnboardingId(o.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The one checklist Task under the Onboarding is returned');
        Task r = rows[0];
        Assert.areEqual('Set up meters', r.Subject, 'Subject is selected');
        Assert.areEqual('Property Set up', r.Onboarding_Category__c, 'Onboarding_Category__c is selected');
        Assert.areEqual('Blocked', r.Onboarding_Status__c, 'Onboarding_Status__c is selected');
        Assert.areEqual('Yardi', r.Source_System__c, 'Source_System__c is selected');
        Assert.areEqual('Isha Patel', r.Task_Owner_Label__c, 'Task_Owner_Label__c is selected');
        Assert.areEqual(Date.today().addDays(4), r.ActivityDate, 'ActivityDate is selected');
        Assert.areEqual('Awaiting vendor', r.Blocked_Reason__c, 'Blocked_Reason__c is selected');
        Assert.areEqual('kickoff note', r.Description, 'Description is selected');
    }

    @isTest
    static void selectChecklistByOnboardingId_ordersByCategoryThenActivityDateNullsLast() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, true);
        // ORDER BY on a picklist uses the picklist's DEFINITION order, NOT alphabetical.
        // Onboarding_Category__c (sorted=false) defines Performance Tracking (pos 6)
        // BEFORE Leasing (pos 7), so 'Performance Tracking' sorts first. Within a
        // category, ActivityDate ascending with NULLS LAST.
        Task lateLeasing = new Task(Onboarding__c = o.Id, Subject = 'L-late', Onboarding_Category__c = 'Leasing',
            Onboarding_Status__c = 'Not Started', ActivityDate = Date.today().addDays(5));
        Task nullLeasing = new Task(Onboarding__c = o.Id, Subject = 'L-null', Onboarding_Category__c = 'Leasing',
            Onboarding_Status__c = 'Not Started', ActivityDate = null);
        Task earlyLeasing = new Task(Onboarding__c = o.Id, Subject = 'L-early', Onboarding_Category__c = 'Leasing',
            Onboarding_Status__c = 'Not Started', ActivityDate = Date.today().addDays(1));
        Task perf = new Task(Onboarding__c = o.Id, Subject = 'P-one', Onboarding_Category__c = 'Performance Tracking',
            Onboarding_Status__c = 'Not Started', ActivityDate = Date.today());
        insert new List<Task>{ lateLeasing, nullLeasing, earlyLeasing, perf };

        Test.startTest();
        List<Task> rows = TaskSelector.selectChecklistByOnboardingId(o.Id);
        Test.stopTest();

        Assert.areEqual(4, rows.size(), 'All four checklist Tasks are returned');
        Assert.areEqual('P-one', rows[0].Subject, 'Performance Tracking (picklist pos 6) sorts before Leasing (pos 7)');
        Assert.areEqual('L-early', rows[1].Subject, 'Leasing group; earliest ActivityDate leads');
        Assert.areEqual('L-late', rows[2].Subject, 'Later Leasing ActivityDate second');
        Assert.areEqual('L-null', rows[3].Subject, 'Null ActivityDate sorts LAST within the Leasing group');
    }

    @isTest
    static void selectChecklistByOnboardingId_nullId_returnsEmpty() {
        Test.startTest();
        List<Task> rows = TaskSelector.selectChecklistByOnboardingId(null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A null onboardingId short-circuits to an empty list, not null');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectForOnboardingCompletion
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectForOnboardingCompletion_existingId_returnsMutableFieldSet() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, true);
        Task t = new Task(
            Onboarding__c = o.Id, Subject = 'Complete me', Onboarding_Status__c = 'Not Started',
            Status = 'Open', Description = 'existing note'
        );
        insert t;

        Test.startTest();
        Task result = TaskSelector.selectForOnboardingCompletion(t.Id);
        Test.stopTest();

        Assert.areEqual(t.Id, result.Id, 'The record for the given Id is returned');
        // Reading each of these proves it is in the SELECT — completeTask needs
        // every one (Onboarding__c to recalc, Status/Onboarding_Status__c to flip,
        // Description to append). A SELECT Id,Description-only reuse would throw here.
        Assert.areEqual(o.Id, result.Onboarding__c, 'Onboarding__c is selected so completeTask can recalc the right parent');
        Assert.areEqual('Not Started', result.Onboarding_Status__c, 'Onboarding_Status__c is selected');
        Assert.areEqual('Open', result.Status, 'Status is selected');
        Assert.areEqual('existing note', result.Description, 'Description is selected so the note can be appended');
    }

    @isTest
    static void selectForOnboardingCompletion_missingId_throwsQueryException() {
        Task t = new Task(Subject = 'Temp', Status = 'Not Started');
        insert t;
        Id deletedId = t.Id;
        delete t;

        Test.startTest();
        try {
            TaskSelector.selectForOnboardingCompletion(deletedId);
            Assert.fail('A Task Id that no longer exists should raise a QueryException');
        } catch (System.QueryException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains('no rows'),
                'Exception should indicate no matching Task row: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectByOnboardingIds
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectByOnboardingIds_populatesFieldsAcrossParents() {
        List<Onboarding__c> obs = TestDataFactory.createOnboardings(2, null, true);
        Task a = new Task(Onboarding__c = obs[0].Id, Subject = 'a', Onboarding_Status__c = 'In Progress',
            ActivityDate = Date.today().addDays(-2));
        Task b = new Task(Onboarding__c = obs[1].Id, Subject = 'b', Onboarding_Status__c = 'Complete',
            ActivityDate = Date.today().addDays(3));
        insert new List<Task>{ a, b };
        Set<Id> ids = new Set<Id>{ obs[0].Id, obs[1].Id };

        Test.startTest();
        List<Task> rows = TaskSelector.selectByOnboardingIds(ids);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both parents\' Tasks are returned in one query');
        Map<Id, Task> byParent = new Map<Id, Task>();
        for (Task t : rows) {
            byParent.put(t.Onboarding__c, t);
        }
        Assert.areEqual('In Progress', byParent.get(obs[0].Id).Onboarding_Status__c, 'Onboarding_Status__c is selected');
        Assert.areEqual(Date.today().addDays(-2), byParent.get(obs[0].Id).ActivityDate, 'ActivityDate is selected');
        Assert.areEqual('Complete', byParent.get(obs[1].Id).Onboarding_Status__c, 'Second parent status is selected');
    }

    @isTest
    static void selectByOnboardingIds_bulk251_readsAllViaSetId() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, true);
        TestDataFactory.createOnboardingTasks(251, o.Id, true);

        Test.startTest();
        List<Task> rows = TaskSelector.selectByOnboardingIds(new Set<Id>{ o.Id });
        Test.stopTest();

        Assert.areEqual(251, rows.size(), 'The Set<Id> read returns all 251 checklist Tasks at bulk volume');
    }

    @isTest
    static void selectByOnboardingIds_nullOrEmpty_returnsEmpty() {
        Test.startTest();
        List<Task> forNull = TaskSelector.selectByOnboardingIds(null);
        List<Task> forEmpty = TaskSelector.selectByOnboardingIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null id set short-circuits to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty id set short-circuits to an empty list, not null');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectByTransactionDealIds  (rollup read — no Task_Group__c filter)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectByTransactionDealIds_populatesFieldsAndIncludesUngroupedTasks() {
        Id txnId = transactionId();
        Task closed = new Task(Transaction_Deal__c = txnId, Subject = 'done', Status = 'Completed',
            Task_Group__c = GROUP_A, ActivityDate = Date.today().addDays(-1));
        // Deliberately NO Task_Group__c — proves this rollup read does NOT apply the
        // `Task_Group__c != null` filter that selectChecklistByTransactionDealIds does.
        Task ungrouped = new Task(Transaction_Deal__c = txnId, Subject = 'Verify wiring (anti-fraud)',
            Status = 'Not Started', Verbal_Verification_Completed__c = false);
        insert new List<Task>{ closed, ungrouped };

        Test.startTest();
        List<Task> rows = TaskSelector.selectByTransactionDealIds(new Set<Id>{ txnId });
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both Tasks are returned — including the one with no Task_Group__c');
        Map<String, Task> bySubject = new Map<String, Task>();
        for (Task t : rows) {
            bySubject.put(t.Subject, t);
        }
        Assert.areEqual(txnId, bySubject.get('done').Transaction_Deal__c, 'Transaction_Deal__c is selected (rollup keys its maps on it)');
        Assert.areEqual(true, bySubject.get('done').IsClosed, 'IsClosed is selected');
        Assert.areEqual(Date.today().addDays(-1), bySubject.get('done').ActivityDate, 'ActivityDate is selected');
        Assert.areEqual(false, bySubject.get('Verify wiring (anti-fraud)').Verbal_Verification_Completed__c,
            'Verbal_Verification_Completed__c is selected');
    }

    @isTest
    static void selectByTransactionDealIds_bulk251_readsAllViaSetId() {
        Id txnId = transactionId();
        // Suppressed Transaction (no Contract_Executed_Date__c) so no async fan-out;
        // the TaskRollupTrigger recalc that fires on insert is the production path.
        TestDataFactory.createChecklistTasks(251, txnId, true);

        Test.startTest();
        List<Task> rows = TaskSelector.selectByTransactionDealIds(new Set<Id>{ txnId });
        Test.stopTest();

        Assert.areEqual(251, rows.size(), 'The Set<Id> rollup read returns all 251 Tasks at bulk volume');
    }

    @isTest
    static void selectByTransactionDealIds_nullOrEmpty_returnsEmpty() {
        Test.startTest();
        List<Task> forNull = TaskSelector.selectByTransactionDealIds(null);
        List<Task> forEmpty = TaskSelector.selectByTransactionDealIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null id set short-circuits to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty id set short-circuits to an empty list, not null');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectByWhatIdAndSubjects
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectByWhatIdAndSubjects_returnsOnlyMatchingSubjectsWithGuardedFields() {
        Account acct = TestDataFactory.createAccount(true);
        List<String> subjects = new List<String>{ 'PSA Executed', 'Title Company Engaged' };

        Task match1 = new Task(WhatId = acct.Id, Subject = 'PSA Executed', Status = 'Completed');
        Task match2 = new Task(WhatId = acct.Id, Subject = 'Title Company Engaged', Status = 'Not Started');
        Task other = new Task(WhatId = acct.Id, Subject = 'Closing Statement Received', Status = 'Not Started');
        insert new List<Task>{ match1, match2, other };

        Test.startTest();
        List<Task> rows = TaskSelector.selectByWhatIdAndSubjects(acct.Id, subjects);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Only the two Tasks whose Subject is in the list are returned');
        Map<String, Task> bySubject = new Map<String, Task>();
        for (Task t : rows) {
            bySubject.put(t.Subject, t);
        }
        Assert.isTrue(bySubject.containsKey('PSA Executed'), 'Matching subject PSA Executed returned');
        Assert.isTrue(bySubject.containsKey('Title Company Engaged'), 'Matching subject Title Company Engaged returned');
        Assert.isFalse(bySubject.containsKey('Closing Statement Received'), 'Subject not in the list is excluded');
        // The guarded field set (Id, Subject, IsClosed, LastModifiedDate) the
        // DispositionTaskController completedDate guard depends on.
        Assert.areEqual(true, bySubject.get('PSA Executed').IsClosed, 'IsClosed is selected (Completed => closed)');
        Assert.areEqual(false, bySubject.get('Title Company Engaged').IsClosed, 'IsClosed is selected (Not Started => open)');
        Assert.areNotEqual(null, bySubject.get('PSA Executed').LastModifiedDate, 'LastModifiedDate is selected (guard needs it)');
    }

    @isTest
    static void selectByWhatIdAndSubjects_nullWhatIdOrEmptySubjects_returnsEmpty() {
        Account acct = TestDataFactory.createAccount(true);

        Test.startTest();
        List<Task> forNullWhatId = TaskSelector.selectByWhatIdAndSubjects(null, new List<String>{ 'PSA Executed' });
        List<Task> forNullSubjects = TaskSelector.selectByWhatIdAndSubjects(acct.Id, null);
        List<Task> forEmptySubjects = TaskSelector.selectByWhatIdAndSubjects(acct.Id, new List<String>());
        Test.stopTest();

        Assert.areEqual(0, forNullWhatId.size(), 'A null whatId short-circuits to empty');
        Assert.areEqual(0, forNullSubjects.size(), 'A null subjects list short-circuits to empty');
        Assert.areEqual(0, forEmptySubjects.size(), 'An empty subjects list short-circuits to empty');
    }

    /**
     * Standard-object USER_MODE proof (design §5/§7) for the new closing-checklist
     * read. selectByWhatIdAndSubjects selects only always-readable standard fields
     * (Id/Subject/IsClosed/LastModifiedDate) and filters on WhatId — the one
     * FLS-bearing standard field in play, which design §5 measured as Standard User
     * READ=true. A fresh Standard User (no custom permsets) reads the row under
     * WITH USER_MODE. DML runs inside System.runAs to avoid MIXED_DML_OPERATION
     * with the setup-object User insert and to make the Standard User the owner.
     */
    @isTest
    static void selectByWhatIdAndSubjects_standardUser_userModeReturnsRows() {
        User standardUser = buildStandardUser();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert standardUser;
        }

        Test.startTest();
        System.runAs(standardUser) {
            Account acct = new Account(Name = 'Closing Co');
            insertBypassingDuplicateRules(new List<SObject>{ acct });
            Task closing = new Task(WhatId = acct.Id, Subject = 'PSA Executed', Status = 'Not Started');
            insert closing;

            List<Task> rows = TaskSelector.selectByWhatIdAndSubjects(
                acct.Id, new List<String>{ 'PSA Executed' });

            Assert.areEqual(1, rows.size(),
                'A Standard User reads the closing-checklist Task under WITH USER_MODE — WhatId is Standard User READ=true per design §5');
            Assert.areEqual('PSA Executed', rows[0].Subject,
                'Subject (an always-readable standard field) is returned under USER_MODE for a Standard User');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Broker Protection (inbound-email staging model) — RFC threading queries.
    // Added 2026-07-31: TaskSelector gained these two methods with the Phase 3 staging
    // model, and selectLatestByThreadOrMessageIds gained a `, Id DESC` tie-break with the
    // D1 multi-property redesign (design C-3). Both were previously exercised only
    // indirectly through ExtractAddressQueueableTest; the direct selector-level coverage
    // below closes that gap, in particular for the tie-break, which is the single most
    // load-bearing new ordering rule this session's change depends on (R7).
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectByInboundMessageId_existingMessageId_returnsTheTask() {
        Task t = new Task(Subject = 'Inbound email', Status = 'Completed', TaskSubtype = 'Email',
            Inbound_Message_Id__c = 'msg-selector-1@example.invalid');
        insert t;

        Test.startTest();
        List<Task> rows = TaskSelector.selectByInboundMessageId('msg-selector-1@example.invalid');
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'A Task carrying this Message-ID should be found');
        Assert.areEqual(t.Id, rows[0].Id, 'The matching Task should be returned');
    }

    @isTest
    static void selectByInboundMessageId_blankOrUnmatched_returnsEmpty() {
        Test.startTest();
        List<Task> forBlank = TaskSelector.selectByInboundMessageId('');
        List<Task> forNull = TaskSelector.selectByInboundMessageId(null);
        List<Task> forUnmatched = TaskSelector.selectByInboundMessageId('never-logged@example.invalid');
        Test.stopTest();

        Assert.areEqual(0, forBlank.size(), 'A blank Message-ID short-circuits to empty without querying');
        Assert.areEqual(0, forNull.size(), 'A null Message-ID short-circuits to empty without querying');
        Assert.areEqual(0, forUnmatched.size(), 'A Message-ID nothing has logged returns empty, not an error');
    }

    @isTest
    static void selectLatestByThreadOrMessageIds_matchesOnThreadKey() {
        Task viaThreadKey = new Task(Subject = 'root', Status = 'Completed', TaskSubtype = 'Email',
            Inbound_Message_Id__c = 'root-msg@example.invalid', Thread_Key__c = 'root-msg@example.invalid');
        insert viaThreadKey;

        Test.startTest();
        List<Task> rows = TaskSelector.selectLatestByThreadOrMessageIds(
            new Set<String>{ 'root-msg@example.invalid' });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'A single logged Task in the thread should be found');
        Assert.areEqual(viaThreadKey.Id, rows[0].Id,
            'Matches on Thread_Key__c, the conversation root every message in a thread shares');
    }

    @isTest
    static void selectLatestByThreadOrMessageIds_matchesOnInboundMessageIdWhenNotTheThreadRoot() {
        // The OR's second half: a reply can cite a specific earlier message's Message-ID
        // directly, distinct from matching on Thread_Key__c.
        Task cited = new Task(Subject = 'cited directly', Status = 'Completed', TaskSubtype = 'Email',
            Inbound_Message_Id__c = 'cited-msg@example.invalid', Thread_Key__c = 'some-other-root@example.invalid');
        insert cited;

        Test.startTest();
        List<Task> rows = TaskSelector.selectLatestByThreadOrMessageIds(
            new Set<String>{ 'cited-msg@example.invalid' });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'A reply citing this exact Message-ID should still find the Task');
        Assert.areEqual(cited.Id, rows[0].Id, 'Matches on Inbound_Message_Id__c even though it is not this Task\'s own Thread_Key__c');
    }

    @isTest
    static void selectLatestByThreadOrMessageIds_nullOrEmpty_returnsEmpty() {
        Test.startTest();
        List<Task> forNull = TaskSelector.selectLatestByThreadOrMessageIds(null);
        List<Task> forEmpty = TaskSelector.selectLatestByThreadOrMessageIds(new Set<String>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null message-id set short-circuits to empty, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty message-id set short-circuits to empty, not null');
    }

    /**
     * C-3 / R7: N Tasks logged for one multi-property email are inserted in ONE bulk DML and
     * therefore share a CreatedDate to the millisecond, so `CreatedDate DESC` alone leaves the
     * winner UNDEFINED. This is the selector-level proof of the `, Id DESC` tie-break added
     * 2026-07-31 — see the method's own Javadoc. (End-to-end coverage of the full ascending-
     * priority insert contract lives in ExtractAddressQueueableTest.)
     */
    @isTest
    static void selectLatestByThreadOrMessageIds_tiedCreatedDate_idDescBreaksTheTie() {
        List<Task> sameThread = new List<Task>{
            new Task(Subject = 'lower priority', Status = 'Completed', TaskSubtype = 'Email',
                Inbound_Message_Id__c = 'tie-msg-1@example.invalid', Thread_Key__c = 'tie-root@example.invalid'),
            new Task(Subject = 'higher priority', Status = 'Completed', TaskSubtype = 'Email',
                Inbound_Message_Id__c = 'tie-msg-2@example.invalid', Thread_Key__c = 'tie-root@example.invalid')
        };
        // ONE bulk DML — the mechanism that produces the tied CreatedDate this tie-break exists for.
        insert sameThread;
        List<Task> requeried = [SELECT Id, CreatedDate FROM Task WHERE Id IN :sameThread ORDER BY CreatedDate ASC];
        Assert.areEqual(requeried[0].CreatedDate, requeried[1].CreatedDate,
            'Precondition: both Tasks must share a CreatedDate, or this test proves nothing about the tie-break');

        Test.startTest();
        List<Task> rows = TaskSelector.selectLatestByThreadOrMessageIds(
            new Set<String>{ 'tie-root@example.invalid' });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'LIMIT 1 returns exactly one row');
        Assert.areEqual(sameThread[1].Id, rows[0].Id,
            'With a tied CreatedDate, `, Id DESC` must resolve the winner to the Task inserted SECOND '
            + '(the higher Id) — without this tie-break the result is undefined, which is exactly '
            + 'what silently breaks reply threading for a multi-property email (design C-3)');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EAC Thread Guard (added 2026-08-02) — the two WITH SYSTEM_MODE reads.
    // Behavioural coverage of the guard itself lives in EmailThreadGuardServiceTest;
    // these are the selector-level proofs of the two contracts that class depends on:
    // that selectByIds returns the CreatedBy.UserType fingerprint, and that
    // selectThreadAnchorsByAnchorValues matches on BOTH threading keys and BOTH bracket
    // forms, scoped by anchor VALUE rather than by the
    // Leads it was handed.
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectByIds_returnsTheCreatedByUserTypeFingerprint() {
        Task companion = new Task(Subject = 'EAC companion', Status = 'Completed', TaskSubtype = 'Email');
        insert companion;

        Test.startTest();
        List<Task> rows = TaskSelector.selectByIds(new Set<Id>{ companion.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The companion Task should be returned');
        Assert.isNotNull(rows[0].CreatedBy, 'CreatedBy must be traversed, or the guard cannot fingerprint anything');
        Assert.isNotNull(rows[0].CreatedBy.UserType, 'The fingerprint field itself must be populated');
        Assert.areNotEqual('AutomatedProcess', rows[0].CreatedBy.UserType,
            'A Task created by the running user reports a real user type — NOT AutomatedProcess, '
            + 'which is precisely why the guard needs a test seam to reach its delete path');
    }

    @isTest
    static void selectByIds_nullOrEmpty_returnsEmpty() {
        Test.startTest();
        List<Task> forNull = TaskSelector.selectByIds(null);
        List<Task> forEmpty = TaskSelector.selectByIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null Id set short-circuits to empty without querying');
        Assert.areEqual(0, forEmpty.size(), 'An empty Id set short-circuits to empty without querying');
    }

    /**
     * Replaces the by-Lead test: the method is now scoped BY ANCHOR VALUE, because the
     * adopter has no record set to scope by — the anchor is what NAMES the record.
     */
    @isTest
    static void selectThreadAnchorsByAnchorValues_matchesOnEitherThreadingKey() {
        List<Lead> leads = TestDataFactory.createLeads(2, true);
        insert new List<Task>{
            new Task(WhoId = leads[0].Id, Subject = 'root', Status = 'Completed', TaskSubtype = 'Email',
                Thread_Key__c = 'guard-root@example.invalid', Inbound_Message_Id__c = 'guard-root@example.invalid'),
            new Task(WhoId = leads[0].Id, Subject = 'later message', Status = 'Completed', TaskSubtype = 'Email',
                Thread_Key__c = 'guard-other-root@example.invalid', Inbound_Message_Id__c = 'guard-msg-2@example.invalid'),
            new Task(WhoId = leads[1].Id, Subject = 'unmatched', Status = 'Completed', TaskSubtype = 'Email',
                Thread_Key__c = 'guard-unrelated@example.invalid', Inbound_Message_Id__c = 'guard-elsewhere@example.invalid')
        };

        Test.startTest();
        List<Task> rows = TaskSelector.selectThreadAnchorsByAnchorValues(
            new Set<String>{ 'guard-root@example.invalid', 'guard-msg-2@example.invalid' });
        Test.stopTest();

        Assert.areEqual(2, rows.size(),
            'Both halves of the OR must match: one anchor on Thread_Key__c (the conversation root) '
            + 'and one on Inbound_Message_Id__c (a specific cited message). The third Task carries '
            + 'neither requested value and must not leak in');
    }

    /**
     * 🔴 THE P4/E3 FIX. The pipeline stores Thread_Key__c UNBRACKETED and
     * Inbound_Message_Id__c BRACKETED (measured on both live anchor rows in usman-dpeg
     * 2026-08-02), while EAC supplies bracketed identifiers. The selector binds BOTH forms,
     * so a NORMALIZED (unbracketed) candidate finds an anchor stored either way. Before this,
     * the ThreadIdentifier leg could never match and the guard ran on one leg only.
     */
    @isTest
    static void selectThreadAnchorsByAnchorValues_matchesBothBracketForms() {
        Lead broker = TestDataFactory.createLead(true);
        insert new List<Task>{
            new Task(WhoId = broker.Id, Subject = 'unbracketed anchor', Status = 'Completed',
                TaskSubtype = 'Email', Thread_Key__c = 'bracket-probe@example.invalid'),
            new Task(WhoId = broker.Id, Subject = 'bracketed anchor', Status = 'Completed',
                TaskSubtype = 'Email', Inbound_Message_Id__c = '<bracket-probe@example.invalid>')
        };

        Test.startTest();
        List<Task> rows = TaskSelector.selectThreadAnchorsByAnchorValues(
            new Set<String>{ 'bracket-probe@example.invalid' });
        Test.stopTest();

        Assert.areEqual(2, rows.size(),
            'ONE normalized candidate must find the anchor stored UNBRACKETED (Thread_Key__c) AND '
            + 'the one stored BRACKETED (Inbound_Message_Id__c). Binding a single form is exactly '
            + 'the live defect this replaces');
    }

    @isTest
    static void selectThreadAnchorsByAnchorValues_nullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        List<Task> forNull = TaskSelector.selectThreadAnchorsByAnchorValues(null);
        List<Task> forEmpty = TaskSelector.selectThreadAnchorsByAnchorValues(new Set<String>());
        List<Task> forBlank = TaskSelector.selectThreadAnchorsByAnchorValues(new Set<String>{ '', '   ' });
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null value set short-circuits to empty without querying');
        Assert.areEqual(0, forEmpty.size(), 'An empty value set short-circuits to empty without querying');
        Assert.areEqual(0, forBlank.size(),
            'Blank candidates are dropped before binding, so the query is skipped rather than run '
            + 'with an all-blank filter');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Trigger-driven rollup recomputes (added 2026-08-05) — the two WITH SYSTEM_MODE reads that
    // replaced WITH USER_MODE after a REPRODUCED production failure (see each method's own
    // Javadoc in TaskSelector for the full incident). These are the SELECTOR-level regression
    // pins:
    //   - a principal with NO FLS on the custom fields these queries read must still get rows
    //     back (the old USER_MODE code threw `No such column ... on entity 'Task'` for exactly
    //     this shape of persona);
    //   - the companion proof that this fix does NOT widen anything: a user with no sharing to
    //     another user's Task still sees NOTHING, because WITH SYSTEM_MODE bypasses FLS/CRUD
    //     only, never sharing, and this class stays `with sharing`.
    //
    // ⚠ REVISED 2026-08-05 after a failed deploy (job 0Afiw000000FALdCAO — 8/48 new tests failed
    // with `System.SecurityException: Access to entity 'Transaction__c'/'Onboarding__c' denied`).
    // The original version of these four tests built a `Minimum Access - Salesforce` user with
    // ZERO permission set assignments and then performed Transaction__c/Onboarding__c DML AS that
    // user inside `System.runAs`. That profile grants NO object-level CRUD at all on ANY custom
    // object (not even Read), so the Transaction__c/Onboarding__c INSERT itself threw before the
    // code ever reached the Task read this test exists to pin — discriminating nothing, since
    // that failure is identical whether TaskSelector uses WITH USER_MODE or WITH SYSTEM_MODE.
    //
    // ⚠ AMENDED 2026-08-17 — ROUTE A WAS RIGHT AND INCOMPLETE. Moving the fixture DML out of
    // `runAs` removed the CRUD obstacle but silently introduced a SHARING one: the Task was then
    // owned by the test-running admin, Activity is `sharingModel Private` here with no sharing
    // rules, and SYSTEM_MODE bypasses FLS/CRUD but NEVER sharing — so the restricted principal saw
    // ZERO rows and the two FLS pins below failed `Expected: 1, Actual: 0`. That reads as "the
    // SYSTEM_MODE fix does not work" and is nothing of the kind. Both now set
    // `OwnerId = minAccessUser.Id` on the fixture Task, which is what the two
    // ..._systemModeDoesNotBypassSharing_... tests further down were ALREADY doing — they passed
    // throughout for exactly that reason, and the discrepancy between the two halves of this
    // section was the tell. Ownership is the correct isolation: it holds record visibility
    // CONSTANT so the only variable left is the withheld FLS, which is what these two pin.
    //
    // THE FIX (Route A). None of the four tests below perform ANY DML on Transaction__c or
    // Onboarding__c as the restricted principal. The parent record (and the Task itself) is
    // created in the DEFAULT test-running context — full access, no `runAs` — and the restricted
    // principal performs ONLY the read-only `TaskSelector` call. This needs no object-level grant
    // at all: `WITH SYSTEM_MODE` bypasses object CRUD as well as field FLS (proven by this same
    // class's EAC methods below, which already run this way in production for a principal holding
    // zero permission sets), so a zero-permission-set user reaching only the SELECT is not a
    // weaker test — it is the strongest version of it. Only the ONE thing the fixed and reverted
    // code disagree on (the withheld Transaction_Deal__c / Onboarding__c / Onboarding_Status__c
    // FLS) is what changes the outcome now.
    //
    // End-to-end coverage through the real callers, where the restricted principal DOES have to
    // perform DML (to fire the trigger, and because the rollup itself writes back to the parent),
    // lives in TaskRollupServiceTest / OnboardingTaskRollupServiceTest — see those files' own
    // design notes for how object CRUD is granted there (Route B) without leaking the withheld
    // Task FLS.
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 🔴 REGRESSION PIN — reproduces, at the selector level, the production failure recorded in
     * TaskSelector.selectByTransactionDealIds's own Javadoc (2026-08-05). The Transaction__c and
     * its checklist Task are created in the default (full-access) test context; the restricted
     * principal performs ONLY the SELECT. A principal with NO FLS on Transaction_Deal__c must
     * still get rows back under WITH SYSTEM_MODE. Under the OLD WITH USER_MODE code this exact
     * call threw `No such column 'Transaction_Deal__c' on entity 'Task'` for precisely this
     * shape of persona. If this is ever reverted alongside a "harmonizing" change back to
     * WITH USER_MODE, this test goes red here.
     */
    @isTest
    static void selectByTransactionDealIds_minimumAccessUserNoFLS_returnsRows_pinsProductionIncident() {
        User minAccessUser = buildMinimumAccessUser('txnFls');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert minAccessUser;
        }

        // Parent + Task created in the default (full-access) context — the restricted principal
        // below never performs any DML at all; it only reads.
        //
        // 🔴 OwnerId IS LOAD-BEARING (added 2026-08-17). Without it the Task is owned by the
        // test-running admin, and Activity's sharing model in this org is Private
        // (objects/Activity/Activity.object-meta.xml, no sharingRules anywhere in the repo), so
        // minAccessUser could not see the row AT ALL and this test failed `Expected: 1, Actual: 0`
        // — reading as a broken fix when nothing was broken. WITH SYSTEM_MODE bypasses FLS and
        // CRUD and NEVER sharing (that is the whole point of the sibling
        // ..._systemModeDoesNotBypassSharing_... pins below, which already set OwnerId for exactly
        // this reason). Making the restricted principal the OWNER isolates the ONE variable this
        // test is about — the withheld Transaction_Deal__c FLS — from record visibility, which is
        // a different question with its own dedicated test.
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert t;
        insert new Task(Transaction_Deal__c = t.Id, Subject = 'Sign PSA', Status = 'Completed',
            OwnerId = minAccessUser.Id);

        Test.startTest();
        System.runAs(minAccessUser) {
            List<Task> rows = TaskSelector.selectByTransactionDealIds(new Set<Id>{ t.Id });

            Assert.areEqual(1, rows.size(),
                'A principal with NO permission-set FLS on Transaction_Deal__c must still see rows '
                + 'under WITH SYSTEM_MODE. The old WITH USER_MODE code threw a QueryException for '
                + 'exactly this persona (the reproduced 2026-08-05 production incident) — see this '
                + 'method\'s own Javadoc.');
            Assert.areEqual(t.Id, rows[0].Transaction_Deal__c,
                'Transaction_Deal__c — the exact field the production incident could not read — is populated');
        }
        Test.stopTest();
    }

    /**
     * The same latent defect, fixed pre-emptively for selectByOnboardingIds (it had no
     * reproduced incident of its own — it is invoked directly from OnboardingService.completeTask
     * rather than from a trigger — but read the identical custom fields under the identical
     * WITH USER_MODE call before this change). Same Route A shape as the test above.
     */
    @isTest
    static void selectByOnboardingIds_minimumAccessUserNoFLS_returnsRows_pinsSameLatentDefect() {
        User minAccessUser = buildMinimumAccessUser('onbFls');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert minAccessUser;
        }

        // 🔴 OwnerId is load-bearing for the same reason given in the sibling test above: Activity
        // is Private in this org, WITH SYSTEM_MODE never bypasses sharing, and an admin-owned
        // fixture Task is invisible to this persona — which failed as `Expected: 1, Actual: 0` and
        // looked like the SYSTEM_MODE fix not working. Ownership isolates the withheld
        // Onboarding__c / Onboarding_Status__c FLS from record visibility.
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        insert o;
        insert new Task(Onboarding__c = o.Id, Subject = 'Set up meters', Onboarding_Status__c = 'Not Started',
            OwnerId = minAccessUser.Id);

        Test.startTest();
        System.runAs(minAccessUser) {
            List<Task> rows = TaskSelector.selectByOnboardingIds(new Set<Id>{ o.Id });

            Assert.areEqual(1, rows.size(),
                'A principal with NO permission-set FLS on Onboarding__c/Onboarding_Status__c must '
                + 'still see rows under WITH SYSTEM_MODE — the same latent defect '
                + 'selectByTransactionDealIds hit in production, fixed pre-emptively here.');
            Assert.areEqual(o.Id, rows[0].Onboarding__c, 'Onboarding__c is populated for this persona');
        }
        Test.stopTest();
    }

    /**
     * ⚠ SHARING-BOUNDARY PIN. WITH SYSTEM_MODE bypasses FLS and CRUD ONLY — it must NEVER widen
     * record-level visibility, and this class stays `with sharing`. Task/Event's sharing model in
     * this org is Private (objects/Activity/Activity.object-meta.xml declares
     * `<sharingModel>Private</sharingModel>`, and no sharingRules-meta.xml exists anywhere in the
     * repo for Activity), so a user who does not own a checklist Task and shares no
     * role-hierarchy/sharing-rule access to its owner must still see ZERO rows here, exactly as
     * before this change. Includes a POSITIVE CONTROL (the owner DOES see their own row, asserted
     * first) so a fixture regression that produced no visible Task at all cannot pass silently as
     * a false "sharing works" result.
     */
    @isTest
    static void selectByTransactionDealIds_systemModeDoesNotBypassSharing_nonOwnerSeesNoRows() {
        User owner = buildMinimumAccessUser('txnShareOwner');
        User outsider = buildMinimumAccessUser('txnShareOut');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ owner, outsider };
        }

        // Created in the default (full-access) context; ownership is assigned via OwnerId rather
        // than by running the DML as `owner` — neither restricted user ever performs any DML here.
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert t;
        insert new Task(Transaction_Deal__c = t.Id, Subject = 'Owner-only checklist Task',
            Status = 'Not Started', OwnerId = owner.Id);

        Test.startTest();
        System.runAs(owner) {
            List<Task> rows = TaskSelector.selectByTransactionDealIds(new Set<Id>{ t.Id });
            Assert.areEqual(1, rows.size(),
                'POSITIVE CONTROL: the Task\'s own owner must see it. If this returns 0, the fixture '
                + 'itself is broken (e.g. no Task was actually created), and the outsider assertion '
                + 'below would pass for the wrong reason.');
        }
        System.runAs(outsider) {
            List<Task> rows = TaskSelector.selectByTransactionDealIds(new Set<Id>{ t.Id });
            Assert.areEqual(0, rows.size(),
                'A non-owner with no role-hierarchy relationship to the Task owner, no sharing rule, and '
                + 'no View/Modify All Data must see ZERO rows even under WITH SYSTEM_MODE — sharing is '
                + 'still enforced. A non-zero result here would mean SYSTEM_MODE (or a dropped '
                + '`with sharing`) is leaking row visibility, not just bypassing FLS.');
        }
        Test.stopTest();
    }

    /** Same sharing-boundary proof (with positive control) as above, for selectByOnboardingIds. */
    @isTest
    static void selectByOnboardingIds_systemModeDoesNotBypassSharing_nonOwnerSeesNoRows() {
        User owner = buildMinimumAccessUser('onbShareOwner');
        User outsider = buildMinimumAccessUser('onbShareOut');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ owner, outsider };
        }

        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        insert o;
        insert new Task(Onboarding__c = o.Id, Subject = 'Owner-only onboarding Task',
            Onboarding_Status__c = 'Not Started', OwnerId = owner.Id);

        Test.startTest();
        System.runAs(owner) {
            List<Task> rows = TaskSelector.selectByOnboardingIds(new Set<Id>{ o.Id });
            Assert.areEqual(1, rows.size(),
                'POSITIVE CONTROL: the Task\'s own owner must see it — otherwise the fixture itself is '
                + 'broken and the outsider assertion below would pass for the wrong reason.');
        }
        System.runAs(outsider) {
            List<Task> rows = TaskSelector.selectByOnboardingIds(new Set<Id>{ o.Id });
            Assert.areEqual(0, rows.size(),
                'Same sharing-boundary proof as the Transaction rollup read: WITH SYSTEM_MODE never '
                + 'bypasses sharing, so a non-owner with no hierarchy/sharing-rule access sees ZERO rows '
                + 'here too.');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Inserts fixture records with the org's active Duplicate Rules bypassed.
     * These tests create near-identical standard-object parents (Accounts) purely
     * to exercise a Set<Id> read; a Duplicate Rule that matches on City/State
     * similarity is fixture noise, not the behavior under test, so AllowSave keeps
     * the fixture immune to whatever duplicate rules the org has active.
     */
    private static void insertBypassingDuplicateRules(List<SObject> records) {
        Database.DMLOptions dmlOptions = new Database.DMLOptions();
        dmlOptions.DuplicateRuleHeader.allowSave = true;
        Database.insert(records, dmlOptions);
    }

    private static User buildStandardUser() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'selstd' + String.valueOf(Datetime.now().getTime());
        return new User(
            FirstName = 'Std',
            LastName = 'Selector',
            Alias = 'stdsel',
            Email = 'std.selector@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    /**
     * Builds (but does not insert) a user on the 'Minimum Access - Salesforce' profile with NO
     * permission set assignments — i.e. zero FLS on every custom field, matching every real DPEG
     * persona per ARCHITECTURE.md §2 ("all access comes from permission sets"). Callers that need
     * this user to see a specific custom field must assign the relevant permission set
     * themselves; the regression tests above deliberately do NOT, because the whole point is to
     * prove the SELECT no longer depends on that grant.
     */
    private static User buildMinimumAccessUser(String tag) {
        Profile minimumAccessProfile = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Min',
            LastName = 'Access',
            Alias = 'minacc',
            Email = 'min.access.selector@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = minimumAccessProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
