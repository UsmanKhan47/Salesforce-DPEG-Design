/**
 * Pins `ChecklistMigrationQueueable` - the Phase 4 M1 chunk chain.
 *
 * ⚠ 251 IS UNREACHABLE AND MEANINGLESS FOR THIS CLASS, so it asserts at the CHUNK BOUNDARY
 * instead - the same carve-out `ChecklistFanoutServiceTest` takes at 51 deals, recorded here so
 * review does not demand a literal 251. Two independent reasons:
 *   1. 251 deals x 96 rows = 24,096 DML rows against the 10,000-row limit. The job would fail on
 *      arithmetic, proving nothing about the code under test.
 *   2. `CHUNK_SIZE` is 25, so 26 deals is the smallest input that exercises BOTH branches of the
 *      chain decision (this chunk, and there is a next one). Every deal past 26 walks the same
 *      two lines. Testing a volume production cannot reach is the anti-pattern
 *      `.claude/rules/bulk-test-rule.md` exists to prevent.
 * The 251-record mandate IS honoured where it is reachable, on `Checklist_Item__c`, in
 * `ChecklistMigrationServiceTest.migratesTwoHundredFiftyOneItemsOnOneDeal`.
 *
 * ⚠ CHAINED JOBS DO NOT EXECUTE IN TEST CONTEXT, and the Finalizer declines to enqueue when
 * `Test.isRunningTest()`. So these tests assert what ONE chunk did - which is exactly what this
 * class controls - never what the chain eventually produced.
 *
 * 🔴 THE 26-DEAL FIXTURE GIVES EACH DEAL ONE TASK, NOT 82. The property under test is the CHUNK
 * SLICING, and 26 x 82 Tasks would spend the fixture budget proving something
 * `ChecklistMigrationServiceTest` already proves per deal. The one Task per deal is a real
 * wire-verification coordinate so every deal genuinely reconciles - a fixture that failed the
 * gate would make the slicing assertion vacuous.
 *
 * @see force-app/main/default/classes/ChecklistMigrationQueueable.cls
 */
@isTest
private class ChecklistMigrationQueueableTest {

    private static final String GROUP_B = 'B. Earnest Money Wire';
    private static final String WIRE_SUBJECT =
        'Call title company to verbally verify wiring instructions (anti-fraud)';
    /** One more than `CHUNK_SIZE`, so the chain has a first chunk AND a remainder. */
    private static final Integer OVER_ONE_CHUNK = 26;

    @isTest
    static void migratesTheWholeInput_WhenItFitsInOneChunk() {
        List<Id> dealIds = seedDeals(3);

        Test.startTest();
        System.enqueueJob(new ChecklistMigrationQueueable(dealIds, 0));
        Test.stopTest();

        Assert.areEqual(3, claimedCount(), 'All three deals fit in one chunk and must migrate.');
        Assert.areEqual(3, ChecklistMigrationQueueable.lastChunkResults.size(),
            'The chunk should have reported on all three.');
    }

    /**
     * 🔴 THE CHUNK BOUNDARY. With 26 deals the first job must take exactly `CHUNK_SIZE` = 25 and
     * leave the 26th for the chain. Because chained jobs do not run in tests, the 26th stays
     * un-migrated - and that is the assertion, not a defect.
     */
    @isTest
    static void migratesExactlyOneChunk_WhenTheInputExceedsIt() {
        List<Id> dealIds = seedDeals(OVER_ONE_CHUNK);

        Test.startTest();
        System.enqueueJob(new ChecklistMigrationQueueable(dealIds, 0));
        Test.stopTest();

        Assert.areEqual(25, claimedCount(),
            'Exactly CHUNK_SIZE deals per job. If this is 26 the slicing has stopped bounding the '
            + 'work and the heap argument for CHUNK_SIZE = 25 no longer holds.');
        Assert.areEqual(25, ChecklistMigrationQueueable.lastChunkResults.size(),
            'And the chunk should have reported on exactly those 25.');
    }

    /**
     * The offset is what makes a resumed chain pick up where the last one stopped. Starting at 25
     * on a 26-deal input must migrate the ONE remaining deal, not re-migrate the first 25.
     */
    @isTest
    static void migratesTheRemainder_WhenStartedAtAnOffset() {
        List<Id> dealIds = seedDeals(OVER_ONE_CHUNK);

        Test.startTest();
        System.enqueueJob(new ChecklistMigrationQueueable(dealIds, 25));
        Test.stopTest();

        Assert.areEqual(1, claimedCount(),
            'Only the 26th deal is in this chunk. Anything higher means the offset was ignored '
            + 'and a resumed chain would redo work it had already done.');
        Assert.areEqual(dealIds[25], ChecklistMigrationQueueable.lastChunkResults[0].transactionId,
            'And it must be the RIGHT deal - the one at the offset, not the first in the list.');
    }

    /** An offset past the end is the natural terminal state of a chain and must be a no-op. */
    @isTest
    static void doesNothing_WhenTheOffsetIsPastTheEnd() {
        List<Id> dealIds = seedDeals(2);
        ChecklistMigrationQueueable.lastChunkResults =
            new List<ChecklistMigrationService.MigrationResult>();

        Test.startTest();
        System.enqueueJob(new ChecklistMigrationQueueable(dealIds, 99));
        Test.stopTest();

        Assert.areEqual(0, claimedCount(), 'Nothing should have been migrated.');
        Assert.areEqual(0, ChecklistMigrationQueueable.lastChunkResults.size(),
            'And the service should not have been called at all.');
    }

    /** A null or empty input must not throw - a chain can legitimately be launched with neither. */
    @isTest
    static void doesNothing_WhenTheInputIsNull() {
        ChecklistMigrationQueueable.lastChunkResults =
            new List<ChecklistMigrationService.MigrationResult>();

        Test.startTest();
        System.enqueueJob(new ChecklistMigrationQueueable(null, null));
        Test.stopTest();

        Assert.areEqual(0, ChecklistMigrationQueueable.lastChunkResults.size(),
            'A null input list and a null offset must both be tolerated.');
    }

    /**
     * The Finalizer is what keeps the chain moving after a failed chunk, so it must be reachable
     * and must not throw on the success path. Chained jobs do not enqueue in test context, so the
     * assertion is that executing it is safe - not that a successor appeared.
     */
    @isTest
    static void finalizerIsSafeToExecuteOnTheSuccessPath() {
        List<Id> dealIds = seedDeals(1);
        ChecklistMigrationQueueable.ChainFinalizer finalizer =
            new ChecklistMigrationQueueable.ChainFinalizer(dealIds, 0);

        Test.startTest();
        finalizer.execute(null);
        Test.stopTest();

        Assert.areEqual(0, claimedCount(),
            'The Finalizer advances the chain; it does not migrate anything itself.');
    }

    // ── fixtures ──────────────────────────────────────────────────────────────────────────

    /**
     * @param count Deals to create.
     * @return Their Ids, each with ONE wire-verification Task so every deal reconciles.
     */
    private static List<Id> seedDeals(Integer count) {
        List<Transaction__c> deals =
            TestDataFactory.createTransactionsOnChecklistModel(count, true);
        List<Task> tasks = new List<Task>();
        List<Id> dealIds = new List<Id>();
        for (Transaction__c deal : deals) {
            dealIds.add(deal.Id);
            tasks.add(new Task(
                Subject = WIRE_SUBJECT,
                Status = 'Not Started',
                Priority = 'Normal',
                ActivityDate = Date.today().addDays(14),
                Transaction_Deal__c = deal.Id,
                Task_Group__c = GROUP_B,
                Task_Sequence__c = 2,
                Task_Owner_Label__c = 'CFO',
                Conditional__c = false,
                Verbal_Verification_Completed__c = false
            ));
        }
        insert tasks;

        ChecklistMigrationService.groupDefsOverride = new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(Letter__c = 'B', Group_Name__c = 'Earnest Money Wire',
                Owner_Label__c = 'CFO', Sequence__c = 2, Stage__c = 'Open Contract',
                Conditional__c = false)
        };
        ChecklistMigrationService.taskDefsOverride = new List<Transaction_Task_Def__mdt>{
            new Transaction_Task_Def__mdt(Group_Letter__c = 'B', Sequence__c = 2,
                Subject__c = WIRE_SUBJECT, Owner_Label__c = 'CFO', Is_Critical__c = true,
                Is_Wire_Verification__c = true)
        };
        return dealIds;
    }

    /** @return How many deals the checklist model has claimed. */
    private static Integer claimedCount() {
        return [SELECT COUNT() FROM Transaction__c WHERE Checklist_Fanned_Out__c = true];
    }
}
