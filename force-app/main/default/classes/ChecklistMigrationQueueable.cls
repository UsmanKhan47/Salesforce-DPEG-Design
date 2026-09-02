/**
 * Chunked, asynchronous Phase 4 M1 migration. Processes `CHUNK_SIZE` Transactions per job and
 * chains itself for the remainder. Launched by `scripts/migrate-transaction-checklists.apex`.
 *
 * 🔴 A QUEUEABLE CHAIN, NOT `Database.Batchable` — AND THAT IS A DECISION, NOT AN OVERSIGHT.
 * Design §7 M1 says `Database.executeBatch(batch, 50)`. A Batchable needs a `Database.QueryLocator`
 * over `Transaction__c`; ALL `Transaction__c` SOQL lives in `TransactionSelector`, and that file is
 * owned by a concurrent workstream and is off-limits this week — adding a locator to it is exactly
 * the hub-file collision `agent-output/hub-consolidation-tracker.md` exists to prevent. Three
 * things make the chain the better shape anyway:
 *   1. It is `ChecklistFanoutQueueable` verbatim — same chunking, same `ChainFinalizer`, same
 *      suppression discipline. One proven shape, not two.
 *   2. THE OPERATOR NAMES THE DEALS, so a 3-deal pilot is the SAME CODE PATH as an org-wide run.
 *      For a one-shot migration of live data that is a feature, not a limitation.
 *   3. It needs no new `Transaction__c` SOQL at all: `selectForChecklistFanout` already exists,
 *      is already `SYSTEM_MODE`, and takes a describe-validated list of extra field names.
 *
 * 🔴 `CHUNK_SIZE = 25`, NOT the fan-out 50, AND THE REASON IS HEAP, NOT DML ROWS. ⚠ THE HEAP
 * FIGURES ARE ESTIMATED FROM ROW COUNTS, NOT MEASURED — nothing here has been run against an
 * org. The DML-row arithmetic IS exact. The full
 * arithmetic is in `ChecklistMigrationService`'s header; the headline is that DML rows are
 * comfortable at either size (25 x 96 = 2,400 of 10,000) but this job holds BOTH models in memory
 * at once — the `Task` rows, the projected items, the coordinate index and the findings — where
 * the fan-out holds only the new side. 50 deals is ~8,750 sObjects against a 12 MB async ceiling;
 * 25 is ~4,375.
 * ⚠ DO NOT RAISE THIS WITHOUT REDOING THAT ARITHMETIC. `TaskFanoutQueueable`'s 100 was correct for
 * the model it was sized against and became wrong the moment the row count per deal changed. The
 * same is true of any number written here.
 *
 * The chain is advanced from the Finalizer rather than from `execute()`, so a chunk that fails —
 * `UNABLE_TO_LOCK_ROW` on a master-detail insert is the realistic one — does not strand every
 * chunk behind it. The failed chunk's deals simply stay un-migrated, which is safe and re-runnable
 * because `ChecklistMigrationService.migrate` is idempotent on `Checklist_Fanned_Out__c`.
 *
 * @see force-app/main/default/classes/ChecklistMigrationService.cls
 * @see force-app/main/default/classes/ChecklistFanoutQueueable.cls (the shape this inherits)
 * @see agent-output/phase4-migration-design.md §0.2, §5
 */
public with sharing class ChecklistMigrationQueueable implements Queueable {

    @TestVisible
    private static final Integer CHUNK_SIZE = 25;

    /** Outcomes from the last executed chunk. Test instrumentation only. */
    @TestVisible
    private static List<ChecklistMigrationService.MigrationResult> lastChunkResults =
        new List<ChecklistMigrationService.MigrationResult>();

    private final List<Id> transactionIds;
    private final Integer offset;

    /**
     * @param transactionIds The full set of Transactions to migrate.
     * @param offset         Index into `transactionIds` at which this job starts.
     */
    public ChecklistMigrationQueueable(List<Id> transactionIds, Integer offset) {
        this.transactionIds = transactionIds == null ? new List<Id>() : transactionIds;
        this.offset = offset == null ? 0 : offset;
    }

    /**
     * Migrates this job's chunk, after attaching the Finalizer that advances the chain.
     *
     * @param context Queueable context (unused).
     */
    public void execute(QueueableContext context) {
        System.attachFinalizer(new ChainFinalizer(transactionIds, offset));

        List<Id> chunk = new List<Id>();
        Integer endIndex = Math.min(offset + CHUNK_SIZE, transactionIds.size());
        for (Integer i = offset; i < endIndex; i++) {
            chunk.add(transactionIds[i]);
        }
        if (!chunk.isEmpty()) {
            lastChunkResults = ChecklistMigrationService.migrate(chunk);
        }
    }

    /**
     * Advances the migration chain to the next chunk. Runs whether or not the parent job
     * succeeded, so a failed chunk is recorded without halting the rest.
     */
    public class ChainFinalizer implements System.Finalizer {

        private final List<Id> transactionIds;
        private final Integer offset;

        /**
         * @param transactionIds The full set of Transactions being migrated.
         * @param offset         Index the parent job started at.
         */
        public ChainFinalizer(List<Id> transactionIds, Integer offset) {
            this.transactionIds = transactionIds;
            this.offset = offset;
        }

        /**
         * @param context Finalizer context carrying the parent job's result.
         */
        public void execute(FinalizerContext context) {
            if (context != null && context.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
                // Not a main-path debug: this branch runs only when a chunk has already failed,
                // and it is the only record of WHICH deals were in it — the AsyncApexJob row shows
                // the failure but not its scope. The affected deals stay un-migrated and the run
                // can simply be repeated; nothing needs unwinding.
                System.debug(LoggingLevel.ERROR, 'ChecklistMigrationQueueable: chunk at offset '
                    + offset + ' failed: ' + context.getException().getMessage()
                    + '. Those deals remain on the Task model. Continuing the chain.');
            }
            Integer next = offset + CHUNK_SIZE;
            if (next >= transactionIds.size()) {
                return;
            }
            // Chained jobs do not execute in test context, so the chain is not enqueued there.
            // The chunk-boundary tests assert what ONE chunk did, which is what this class
            // controls.
            if (Test.isRunningTest()) {
                return;
            }
            System.enqueueJob(new ChecklistMigrationQueueable(transactionIds, next));
        }
    }
}
