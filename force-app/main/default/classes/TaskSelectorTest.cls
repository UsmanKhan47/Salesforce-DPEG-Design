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
}
