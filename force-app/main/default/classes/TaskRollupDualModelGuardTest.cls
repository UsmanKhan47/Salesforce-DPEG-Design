/**
 * Pins the Phase 4 M0 DUAL-MODEL TIEBREAK in `TaskRollupService.recalc`: the legacy rollup must
 * skip any deal whose `Checklist_Fanned_Out__c` is true.
 *
 * 🔴 A SEPARATE TEST CLASS FROM `TaskRollupServiceTest`, DELIBERATELY. That file has uncommitted
 * edits from a concurrent workstream in this same tree, and appending to it would either collide
 * or silently take that session's copy. The repo already uses standalone gate test classes for
 * exactly this shape (`StageApprovalGatesTest`, `UnderwritingGateTest`,
 * `NdaDealProgressionGateTest`), and coverage is measured per PRODUCTION class, not per test
 * class, so nothing is lost.
 *
 * 🔴 EVERY TEST HERE HAS A CONTROL. A guard test that only asserts the guarded case passes
 * vacuously if the guard is a no-op — the counters could be unchanged because nothing ever wrote
 * them. So each refusal test is paired with an identical deal that is NOT claimed, and asserts
 * that one DID move. That pairing is the falsifier: delete the guard and the paired assertion
 * goes red, not just the first one.
 *
 * ⚠ TWO OF THESE DRIVE THE GUARD THROUGH THE TRIGGER, NOT BY CALLING `recalc` DIRECTLY. This
 * project has measured the difference before — `with sharing` was enforced via a trigger and not
 * via a direct test call — and the trigger is the only path production ever uses.
 *
 * @see force-app/main/default/classes/TaskRollupService.cls
 * @see agent-output/phase4-migration-design.md §1
 */
@isTest
private class TaskRollupDualModelGuardTest {

    /** Enough deals to force a SECOND trigger batch firing on the Task DML. */
    private static final Integer BULK_TASKS = 251;

    /**
     * `createTransactionsOnChecklistModel` pre-sets `Tasks_Fanned_Out__c`, which is what stops
     * `flows/Transaction_Task_Fanout` enqueuing the legacy 70-Task fan-out and writing the very
     * counters these tests assert on. Without it every assertion here measures the wrong writer.
     */
    @TestSetup
    static void setupTestData() {
        TestDataFactory.createTransactionsOnChecklistModel(2, true);
    }

    /**
     * CONTROL for every refusal test below. An unclaimed deal is still owned by the Task model
     * and its counters must move.
     */
    @isTest
    static void shouldWriteCounters_WhenDealIsNotClaimed() {
        Transaction__c deal = unclaimedDeal();
        insertClosedChecklistTask(deal.Id);

        Test.startTest();
        TaskRollupService.recalc(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, reloaded(deal.Id).Tasks_Complete__c,
            'An UNCLAIMED deal is still owned by the Task model, so the legacy rollup must write '
            + 'its counters. If this is 0 the guard is over-reaching and every legacy deal in the '
            + 'org has stopped rolling up.');
        Assert.areEqual(0, TaskRollupService.lastRunSkippedDealCount,
            'Nothing should have been skipped for an unclaimed deal.');
    }

    /** The tiebreak itself, called directly. */
    @isTest
    static void shouldSkipDeal_WhenChecklistModelHasClaimedIt() {
        Transaction__c deal = unclaimedDeal();
        // 🔴 CLAIM FIRST, THEN INSERT. Reversing these two lines is why this test failed on
        // 2026-09-02, and the failure message pointed at the GUARD rather than at the fixture.
        // `insertClosedChecklistTask` fires TaskRollupTrigger, and on a still-unclaimed deal the
        // guard correctly lets the rollup through and writes Tasks_Complete__c = 1. `claim` does
        // not zero it, so the assertion below then read 1 and looked exactly like a guard that had
        // failed to skip. The guard was never wrong. Claiming first means the ONLY save that could
        // move the counter already sees the claim.
        claim(deal.Id);
        insertClosedChecklistTask(deal.Id);

        Test.startTest();
        TaskRollupService.recalc(new Set<Id>{ deal.Id });
        Test.stopTest();

        // ⚠ NULL, NOT ZERO, AND THAT IS THE POINT. The guard means the legacy rollup never wrote
        // this deal AT ALL, and TestDataFactory does not seed the counters - so the field is still
        // null. Asserting 0 here reads as "written, with the value 0", which is a DIFFERENT and
        // weaker claim, and it is what produced the misleading "Expected: 0, Actual: null".
        Assert.isNull(reloaded(deal.Id).Tasks_Complete__c,
            'A CLAIMED deal belongs to ChecklistRollupService. The legacy rollup must not write '
            + 'its counters AT ALL - that is the last-writer-wins race the tiebreak exists to stop.');
        Assert.areEqual(1, TaskRollupService.lastRunSkippedDealCount,
            'The guard should have reported exactly one skipped deal.');
    }

    /**
     * THE COST CLAIM, ASSERTED RATHER THAN COMMENTED. On a fully claimed set the guard read
     * SHORT-CIRCUITS the Task read and the write, so the call costs 1 SOQL and 0 DML — cheaper
     * than before the guard existed, which is the whole argument for putting the read first.
     * ⚠ Both counters are captured INSIDE `recalc`; `Test.stopTest()` restores the pre-test
     * governor counters, so reading `Limits.getQueries()` out here would measure nothing.
     */
    @isTest
    static void shouldCostOneQueryAndNoDml_WhenEveryDealIsClaimed() {
        Transaction__c deal = unclaimedDeal();
        // 🔴 CLAIM FIRST, THEN INSERT. Reversing these two lines is why this test failed on
        // 2026-09-02, and the failure message pointed at the GUARD rather than at the fixture.
        // `insertClosedChecklistTask` fires TaskRollupTrigger, and on a still-unclaimed deal the
        // guard correctly lets the rollup through and writes Tasks_Complete__c = 1. `claim` does
        // not zero it, so the assertion below then read 1 and looked exactly like a guard that had
        // failed to skip. The guard was never wrong. Claiming first means the ONLY save that could
        // move the counter already sees the claim.
        claim(deal.Id);
        insertClosedChecklistTask(deal.Id);

        Test.startTest();
        TaskRollupService.recalc(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, TaskRollupService.lastRunQueryCount,
            'A fully claimed set must cost exactly the guard read - the Task read is skipped.');
        Assert.areEqual(0, TaskRollupService.lastRunDmlCount,
            'A fully claimed set must write nothing at all.');
    }

    /** The mixed set is where a naive implementation writes zeroes over the unclaimed deal. */
    @isTest
    static void shouldWriteOnlyUnclaimedDeals_WhenSetIsMixed() {
        List<Transaction__c> deals = allDeals();
        Transaction__c legacy = deals[0];
        Transaction__c migrated = deals[1];
        // Claim BEFORE inserting the migrated deal task - see the note in
        // shouldSkipDeal_WhenChecklistModelHasClaimedIt. The legacy deal is deliberately NOT
        // claimed, so its task DOES roll up, which is the control half of this pairing.
        claim(migrated.Id);
        insertClosedChecklistTask(legacy.Id);
        insertClosedChecklistTask(migrated.Id);

        Test.startTest();
        TaskRollupService.recalc(new Set<Id>{ legacy.Id, migrated.Id });
        Test.stopTest();

        Assert.areEqual(1, reloaded(legacy.Id).Tasks_Complete__c,
            'The unclaimed half of a mixed set must still roll up.');
        Assert.isNull(reloaded(migrated.Id).Tasks_Complete__c,
            'The claimed half of a mixed set must be left alone - NULL, never written, not '
            + 'written-as-zero. See the note in shouldSkipDeal_WhenChecklistModelHasClaimedIt.');
        Assert.areEqual(1, TaskRollupService.lastRunSkippedDealCount,
            'Exactly one deal in the mixed set was claimed.');
    }

    /**
     * THE ONE THAT MATTERS IN PRODUCTION. `recalc` is only ever reached from `TaskRollupTrigger`,
     * so a guard proven by a direct call is not proven on the path users take. Here a real Task
     * save fires the real trigger.
     */
    @isTest
    static void shouldSkipDeal_WhenTriggerFiresOnAClaimedDeal() {
        List<Transaction__c> deals = allDeals();
        Transaction__c legacy = deals[0];
        Transaction__c migrated = deals[1];
        Task legacyTask = insertOpenChecklistTask(legacy.Id);
        Task migratedTask = insertOpenChecklistTask(migrated.Id);
        claim(migrated.Id);
        // The claim write itself must not have moved the counters; reset them so the assertion
        // below cannot pass on a stale value.
        update new List<Transaction__c>{
            new Transaction__c(Id = legacy.Id, Tasks_Complete__c = 0),
            new Transaction__c(Id = migrated.Id, Tasks_Complete__c = 0)
        };

        Test.startTest();
        legacyTask.Status = 'Completed';
        migratedTask.Status = 'Completed';
        update new List<Task>{ legacyTask, migratedTask };
        Test.stopTest();

        Assert.areEqual(1, reloaded(legacy.Id).Tasks_Complete__c,
            'Completing a checklist Task on an UNCLAIMED deal must still roll up through the '
            + 'trigger. If this is 0 the guard broke the live Task model.');
        Assert.areEqual(0, reloaded(migrated.Id).Tasks_Complete__c,
            'Completing a checklist Task on a CLAIMED deal must NOT move the deal counters. This '
            + 'is the exact production scenario from M1 onward: the legacy Tasks are still there '
            + 'and still editable, and without the tiebreak this save would overwrite the '
            + 'checklist model numbers non-deterministically.');
    }

    /**
     * Bulk. 251 Tasks in ONE statement crosses the 200-row trigger batch boundary, so the trigger
     * fires TWICE and `recalc` re-enters — the shape that turns a per-record query into a limit
     * failure.
     *
     * ⚠ 251 TASKS ON TWO DEALS, NOT 251 DEALS. `.claude/rules/bulk-test-rule.md`'s mandate is
     * about crossing the chunk boundary, and Tasks are what this trigger batches on. 251
     * Transactions would be 251 x 82 = 20,582 rows against the 10,000 DML-row limit, which
     * `TestDataFactory.createChecklistTasks` already documents as a real overflow — testing a
     * volume production cannot reach is the anti-pattern the rule exists to prevent.
     */
    @isTest
    static void shouldStayConstantCost_WhenBulkTasksCrossTheChunkBoundary() {
        List<Transaction__c> deals = allDeals();
        Transaction__c legacy = deals[0];
        Transaction__c migrated = deals[1];
        claim(migrated.Id);

        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < BULK_TASKS; i++) {
            tasks.add(buildChecklistTask(
                Math.mod(i, 2) == 0 ? legacy.Id : migrated.Id, i + 1, true));
        }

        Test.startTest();
        insert tasks;
        Test.stopTest();

        Assert.areEqual(BULK_TASKS, [SELECT COUNT() FROM Task WHERE Transaction_Deal__c IN
                :new List<Id>{ legacy.Id, migrated.Id }],
            'All 251 Tasks should have been inserted.');
        Assert.areEqual(126, reloaded(legacy.Id).Tasks_Complete__c,
            'The unclaimed deal took the even indexes: 126 of 251.');
        Assert.isNull(reloaded(migrated.Id).Tasks_Complete__c,
            'The claimed deal must be untouched however many Tasks were saved at once - and '
            + 'UNTOUCHED means null, not zero. This assertion read "Expected: 0, Actual: null" '
            + 'on 2026-09-02, which is the guard working, not failing.');
        // The guard read is once per recalc call, never once per deal or once per Task.
        Assert.areEqual(2, TaskRollupService.lastRunQueryCount,
            'Cost must be CONSTANT per trigger chunk - one guard read plus one Task read - and '
            + 'must not grow with the number of Tasks or deals in the chunk. Captured inside '
            + 'recalc, because Test.stopTest() restores the pre-test counters.');
    }

    /** Null and empty inputs must not throw and must not query. */
    @isTest
    static void shouldDoNothing_WhenInputIsNull() {
        Test.startTest();
        TaskRollupService.recalc(null);
        Test.stopTest();

        Assert.areEqual(0, TaskRollupService.lastRunQueryCount,
            'A null input must not reach the guard read.');
    }

    /** Separate method from the null case on purpose: distinct inputs, distinct tests. */
    @isTest
    static void shouldDoNothing_WhenInputIsEmpty() {
        Test.startTest();
        TaskRollupService.recalc(new Set<Id>());
        TaskRollupService.recalc(new Set<Id>{ null });
        Test.stopTest();

        Assert.areEqual(0, TaskRollupService.lastRunQueryCount,
            'An empty set, and a set of only nulls, must not reach the guard read.');
    }

    /**
     * A deal the running user cannot SEE must be treated as STILL OWNED BY THE TASK MODEL, not as
     * claimed. Proven by deleting the deal so the selector returns nothing for its Id — the same
     * shape a sharing miss produces, without needing a second user.
     * ⚠ The write then fails for that Id, which is the correct LOUD direction: a guard whose false
     * negative is a silently stale dashboard number must not fail closed.
     */
    @isTest
    static void shouldNotTreatAnUnreadableDealAsClaimed() {
        Transaction__c deal = unclaimedDeal();
        Id dealId = deal.Id;
        delete deal;

        Test.startTest();
        Boolean threw = false;
        try {
            TaskRollupService.recalc(new Set<Id>{ dealId });
        } catch (DmlException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.areEqual(0, TaskRollupService.lastRunSkippedDealCount,
            'An unreadable deal must NOT be counted as claimed - that would silently stop '
            + 'maintaining counters nothing else maintains.');
        Assert.isTrue(threw,
            'The write for an unreadable deal must fail LOUDLY rather than being skipped.');
    }

    /** @return The first scaffold deal, unclaimed. */
    private static Transaction__c unclaimedDeal() {
        return allDeals()[0];
    }

    /** @return Both scaffold deals, ordered deterministically. */
    private static List<Transaction__c> allDeals() {
        return [
            SELECT Id, Checklist_Fanned_Out__c, Tasks_Complete__c
            FROM Transaction__c
            ORDER BY Contract_Value__c
        ];
    }

    /**
     * @param dealId The deal to reload.
     * @return It, with every field these assertions read. Every helper SELECT here lists every
     *         column its callers touch — a narrower one throws `SObjectException` at the
     *         assertion, which reads as a logic failure rather than a query one.
     */
    private static Transaction__c reloaded(Id dealId) {
        return [
            SELECT Id, Checklist_Fanned_Out__c, Tasks_Complete__c, Tasks_Overdue__c,
                   Wire_Open_Risks__c, Tasks_Total__c
            FROM Transaction__c
            WHERE Id = :dealId
        ];
    }

    /** @param dealId The deal to claim for the checklist model. */
    private static void claim(Id dealId) {
        update new Transaction__c(Id = dealId, Checklist_Fanned_Out__c = true);
    }

    /** @param dealId Parent deal. @return An inserted, closed checklist Task. */
    private static Task insertClosedChecklistTask(Id dealId) {
        Task legacyTask = buildChecklistTask(dealId, 1, true);
        insert legacyTask;
        return legacyTask;
    }

    /** @param dealId Parent deal. @return An inserted, open checklist Task. */
    private static Task insertOpenChecklistTask(Id dealId) {
        Task legacyTask = buildChecklistTask(dealId, 1, false);
        insert legacyTask;
        return legacyTask;
    }

    /**
     * @param dealId   Parent deal.
     * @param sequence Task_Sequence__c.
     * @param closed   Whether to create it Completed.
     * @return An unsaved checklist Task.
     */
    private static Task buildChecklistTask(Id dealId, Integer sequence, Boolean closed) {
        return new Task(
            Subject = 'Guard test task ' + sequence,
            Status = closed ? 'Completed' : 'Not Started',
            Priority = 'Normal',
            ActivityDate = Date.today().addDays(14),
            Transaction_Deal__c = dealId,
            Task_Group__c = 'A. Contract Execution & Title Opening',
            Task_Sequence__c = sequence
        );
    }
}
