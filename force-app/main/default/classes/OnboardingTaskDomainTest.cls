/**
 * Tests OnboardingTaskDomain — the completion stamp that replaced the `ActivityDate`
 * overwrite, and the Onboarding-id projection behind the rollup routing.
 *
 * ═══ WHY THE STAMP IS TESTED THROUGH REAL DML, NOT ONLY AS A PURE FUNCTION ═══
 * The defect being fixed was that completion only worked from ONE LWC path. A test that calls
 * `stampCompletion(list, map)` directly proves the function, but it CANNOT prove the thing
 * that actually broke: that a completion arriving from the standard UI, the API or Data Loader
 * is stamped too. So the behavioural tests here go through ordinary `insert` / `update` DML —
 * i.e. through `TaskRollupTrigger`'s new before-contexts — and never through
 * `OnboardingService`. The direct-call tests cover the null-collection edges that DML cannot
 * reach.
 *
 * ⚠ FIXTURES DELIBERATELY DO NOT USE THE FAN-OUT. `TestDataFactory.createOnboardings` ships
 * `Tasks_Fanned_Out__c = true`, which keeps the `Onboarding_Task_Fanout` flow from minting 45
 * extra Tasks at `Test.stopTest()` and silently changing every count asserted below.
 *
 * `.claude/rules/bulk-test-rule.md` applies at 251 — these are trigger-driven Task DML paths,
 * and no content object is involved, so `.claude/rules/content-publication-rule.md` does not
 * narrow it.
 */
@isTest
private class OnboardingTaskDomainTest {

    /** .claude/rules/bulk-test-rule.md — 251 forces a SECOND trigger chunk. */
    private static final Integer BULK_N = 251;

    private static Onboarding__c newOnboarding() {
        return TestDataFactory.createOnboarding(null, true);
    }

    /**
     * Builds an unsaved checklist Task with a due date that is NOT today, so any assertion
     * about the due date surviving can actually discriminate.
     */
    private static Task checklistTask(Id onboardingId, String status, Date due) {
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

    // ═════════════════════════════════════════════════════════════════════════════════════
    // THE STAMP, THROUGH ORDINARY DML — i.e. through the trigger, not through the LWC service
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE NON-LWC PATH. A checklist item completed by a plain `update` — the shape a
     * standard-UI edit, the REST API and Data Loader all arrive in — is stamped, and its
     * original due date is untouched. Before this change NONE of those paths stamped anything,
     * and the LWC path destroyed the due date.
     */
    @isTest
    static void completingViaPlainDmlStampsTheDateAndLeavesTheDueDateAlone() {
        Onboarding__c o = newOnboarding();
        Date originalDue = Date.today().addDays(11);
        Task t = checklistTask(o.Id, 'Not Started', originalDue);
        insert t;

        Assert.isNull(
            [SELECT Onboarding_Completed_Date__c FROM Task WHERE Id = :t.Id].Onboarding_Completed_Date__c,
            'Precondition: an incomplete item carries no completion date, so the assertion below '
            + 'cannot pass because the field was already populated at insert');

        Test.startTest();
        update new Task(Id = t.Id, Onboarding_Status__c = 'Complete');
        Test.stopTest();

        Task after = [SELECT ActivityDate, Onboarding_Completed_Date__c FROM Task WHERE Id = :t.Id];
        Assert.areEqual(Date.today(), after.Onboarding_Completed_Date__c,
            'A completion arriving from ANY write path is stamped — that is the whole point of '
            + 'owning this in a before-trigger rather than in OnboardingService');
        Assert.areEqual(originalDue, after.ActivityDate,
            'and the original due date survives — ActivityDate is never written by this domain');
    }

    /**
     * A Task INSERTED already Complete (a data load, a migration, a backfill) is stamped too.
     * The insert branch has no prior record, so "entering Complete" must be read as "is
     * Complete" — the same reading `PropertyAssetService.ensureOnClosedWon` uses for stage entry.
     */
    @isTest
    static void insertingAnAlreadyCompleteItemStampsIt() {
        Onboarding__c o = newOnboarding();
        Task t = checklistTask(o.Id, 'Complete', Date.today().addDays(4));

        Test.startTest();
        insert t;
        Test.stopTest();

        Assert.areEqual(Date.today(),
            [SELECT Onboarding_Completed_Date__c FROM Task WHERE Id = :t.Id].Onboarding_Completed_Date__c,
            'A row created already Complete is stamped on insert');
    }

    /**
     * 🔴 REOPEN CLEARS THE DATE. This is the single behaviour that disqualified the standard
     * `Task.CompletedDateTime` (auto-stamped on close, never cleared on reopen — measured in
     * `DispositionTaskController`). If this reds, a reopened checklist item is carrying a
     * completion date for work that is not finished, and every "was it late?" answer built on
     * it is wrong.
     */
    @isTest
    static void reopeningACompletedItemClearsTheCompletionDate() {
        Onboarding__c o = newOnboarding();
        Task t = checklistTask(o.Id, 'Complete', Date.today().addDays(4));
        insert t;
        Assert.areEqual(Date.today(),
            [SELECT Onboarding_Completed_Date__c FROM Task WHERE Id = :t.Id].Onboarding_Completed_Date__c,
            'Precondition: it really was stamped, so the clear below is not vacuous');

        Test.startTest();
        update new Task(Id = t.Id, Onboarding_Status__c = 'In Progress');
        Test.stopTest();

        Assert.isNull(
            [SELECT Onboarding_Completed_Date__c FROM Task WHERE Id = :t.Id].Onboarding_Completed_Date__c,
            'Leaving Complete must clear the completion date — a reopened item is not complete');
    }

    /**
     * A back-dated completion supplied IN the same save survives: the stamp only fills a BLANK
     * field. A migration importing historical completion dates must not have every one of them
     * rewritten to today.
     */
    @isTest
    static void anExplicitCompletionDateSuppliedInTheSameSaveIsNotOverwritten() {
        Onboarding__c o = newOnboarding();
        Date backDated = Date.today().addDays(-30);
        Task t = checklistTask(o.Id, 'Complete', Date.today().addDays(-45));
        t.Onboarding_Completed_Date__c = backDated;

        Test.startTest();
        insert t;
        Test.stopTest();

        Assert.areEqual(backDated,
            [SELECT Onboarding_Completed_Date__c FROM Task WHERE Id = :t.Id].Onboarding_Completed_Date__c,
            'A caller-supplied completion date wins — the stamp fills a blank, it does not overwrite');
    }

    /**
     * Re-saving an already-Complete item does NOT move its completion date. "Entering Complete",
     * not "is Complete": a PM editing the note on a finished item must not silently re-date it.
     */
    @isTest
    static void reSavingAnAlreadyCompleteItemDoesNotMoveTheDate() {
        Onboarding__c o = newOnboarding();
        Date backDated = Date.today().addDays(-30);
        Task t = checklistTask(o.Id, 'Complete', Date.today().addDays(-45));
        t.Onboarding_Completed_Date__c = backDated;
        insert t;

        Test.startTest();
        update new Task(Id = t.Id, Description = 'an unrelated later edit');
        Test.stopTest();

        Assert.areEqual(backDated,
            [SELECT Onboarding_Completed_Date__c FROM Task WHERE Id = :t.Id].Onboarding_Completed_Date__c,
            'An unrelated edit to a finished item must not re-date its completion');
    }

    /**
     * 🔴 THE ORG-WIDE BLAST-RADIUS GUARD. The before-contexts now fire on EVERY Task in the org.
     * A Task with no `Onboarding__c` must come out completely untouched, whatever its
     * `Onboarding_Status__c` happens to say.
     */
    @isTest
    static void aTaskWithNoOnboardingIsNeverStamped() {
        Task orphan = new Task(Subject = 'Not a checklist item', Status = 'Open',
            Onboarding_Status__c = 'Complete');

        Test.startTest();
        insert orphan;
        update new Task(Id = orphan.Id, Onboarding_Status__c = 'In Progress');
        Test.stopTest();

        Assert.isNull(
            [SELECT Onboarding_Completed_Date__c FROM Task WHERE Id = :orphan.Id].Onboarding_Completed_Date__c,
            'No Onboarding__c means no stamp, on insert OR update — the early return that keeps '
            + 'this trigger cheap for the Transaction fan-out, Broker Protection Tasks, EAC '
            + 'companion Tasks and every hand-created Activity in the org');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 BULK — 251 records, TWO trigger chunks
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * `.claude/rules/bulk-test-rule.md` in full: 251 Tasks in ONE transaction forces a second
     * 200-record trigger chunk, which is the only way to prove chunk 2 stamps like chunk 1.
     *
     * The budget half matters as much as the count: the stamp must add ZERO queries and ZERO
     * DML statements of its own. Measured with Limits deltas taken around the DML — NOT after
     * `Test.stopTest()`, which restores the pre-test counters and would make the obvious
     * assertion silently vacuous.
     */
    @isTest
    static void bulk251_stampsEveryItemOnBothChunksAndCostsNoQueriesOrDml() {
        Onboarding__c o = newOnboarding();
        Date originalDue = Date.today().addDays(21);
        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < BULK_N; i++) {
            tasks.add(checklistTask(o.Id, 'Not Started', originalDue));
        }
        insert tasks;

        List<Task> toComplete = new List<Task>();
        for (Task t : tasks) {
            toComplete.add(new Task(Id = t.Id, Onboarding_Status__c = 'Complete'));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        update toComplete;
        Integer queriesAdded = Limits.getQueries() - queriesBefore;
        Integer dmlAdded = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Date stampedToday = Date.today();
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Task
             WHERE Onboarding__c = :o.Id AND Onboarding_Completed_Date__c = :stampedToday],
            'All 251 items across BOTH trigger chunks are stamped');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Task WHERE Onboarding__c = :o.Id AND ActivityDate = :originalDue],
            'and all 251 keep their original due date');

        // The rollup fires alongside the stamp: 2 chunks x (1 selector read + 1 parent update).
        // The STAMP itself contributes nothing, which is what makes this ceiling meaningful.
        Assert.isTrue(queriesAdded <= 2,
            'The 251-row update must cost at most the rollup\'s 2 queries (one per chunk). Found '
            + queriesAdded + ' — if this grew, something moved into a per-record loop');
        Assert.isTrue(dmlAdded <= 3,
            'and at most the caller\'s own DML plus the rollup\'s one write per chunk. Found ' + dmlAdded);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // DIRECT CALLS — the null/empty edges DML cannot reach
    // ═════════════════════════════════════════════════════════════════════════════════════

    /** Null and empty collections are no-ops, not NullPointerExceptions. */
    @isTest
    static void nullAndEmptyCollectionsAreNoOps() {
        Test.startTest();
        OnboardingTaskDomain.stampCompletion(null, null);
        OnboardingTaskDomain.stampCompletion(new List<Task>(), new Map<Id, Task>());
        Set<Id> fromNull = OnboardingTaskDomain.collectOnboardingIds(null);
        Test.stopTest();

        Assert.isNotNull(fromNull, 'collectOnboardingIds(null) returns an empty Set, never null');
        Assert.areEqual(0, fromNull.size(), 'and it is empty');
    }

    /**
     * An update whose `oldMap` has no entry for the record (defensive — the platform always
     * supplies one, but the projection must not throw if it ever does not) is treated as
     * "was not Complete", i.e. entering.
     */
    @isTest
    static void anUpdateWithNoPriorEntryIsTreatedAsEntering() {
        Task t = new Task(Id = fakeTaskId(), Onboarding__c = fakeOnboardingId(),
            Onboarding_Status__c = 'Complete');

        Test.startTest();
        OnboardingTaskDomain.stampCompletion(new List<Task>{ t }, new Map<Id, Task>());
        Test.stopTest();

        Assert.areEqual(Date.today(), t.Onboarding_Completed_Date__c,
            'A missing prior is read as "was not Complete", so the item is entering and is stamped');
    }

    /** The id projection de-duplicates and drops nulls. */
    @isTest
    static void collectOnboardingIdsDeDupesAndDropsNulls() {
        Id a = fakeOnboardingId();
        List<Task> tasks = new List<Task>{
            new Task(Onboarding__c = a),
            new Task(Onboarding__c = a),
            new Task(Onboarding__c = null)
        };

        Test.startTest();
        Set<Id> ids = OnboardingTaskDomain.collectOnboardingIds(tasks);
        Test.stopTest();

        Assert.areEqual(1, ids.size(),
            'Two Tasks on one Onboarding project to ONE id, and the null lookup is dropped — the '
            + 'de-duplication is what keeps the rollup at one recompute per parent per chunk');
        Assert.isTrue(ids.contains(a), 'and it is the right id');
    }

    /** A valid-format Id that resolves to no row. Never inserted, so nothing to clean up. */
    private static Id fakeTaskId() {
        return Id.valueOf(Task.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
    }

    private static Id fakeOnboardingId() {
        return Id.valueOf(Onboarding__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
    }
}
