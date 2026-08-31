/**
 * Chunked, asynchronous checklist fan-out. Processes `CHUNK_SIZE` Transactions per job and chains
 * itself for the remainder.
 *
 * 🔴 `CHUNK_SIZE = 50`, NOT the legacy 100. The arithmetic is derived in full in
 * `ChecklistFanoutService`'s header and is not repeated here, but the headline is: the new model
 * writes 96 rows per Transaction (11 checklists + 82 items + a 2-row prerequisite second pass + 1
 * deal update), so 100 Transactions is 9,600 rows with the rollup suppressed and 10,800 without -
 * a hard `Too many DML rows: 10001`. 50 lands at 4,800, roughly 52% headroom.
 * ⚠ DO NOT RAISE THIS WITHOUT RE-DOING THAT ARITHMETIC. `TaskFanoutQueueable`'s 100 was correct for
 * the model it was sized against and became wrong the moment the row count per deal changed; the
 * same is true of any number written here.
 *
 * The chain is advanced from the Finalizer rather than from `execute()`, so a chunk that fails with
 * an unhandled exception does not strand every chunk behind it - the Finalizer runs regardless of
 * the parent job's outcome. That shape is inherited deliberately from `TaskFanoutQueueable`.
 *
 * @see force-app/main/default/classes/ChecklistFanoutService.cls
 */
public with sharing class ChecklistFanoutQueueable implements Queueable {

    @TestVisible
    private static final Integer CHUNK_SIZE = 50;

    private final List<Id> transactionIds;
    private final Integer offset;

    /**
     * @param transactionIds The full set of Transactions to fan out.
     * @param offset         Index into `transactionIds` at which this job starts.
     */
    public ChecklistFanoutQueueable(List<Id> transactionIds, Integer offset) {
        this.transactionIds = transactionIds == null ? new List<Id>() : transactionIds;
        this.offset = offset == null ? 0 : offset;
    }

    /**
     * Fans out this job's chunk, after attaching the Finalizer that advances the chain.
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
            ChecklistFanoutService.fanOutNow(chunk);
        }
    }

    /**
     * Advances the fan-out chain to the next chunk. Runs whether or not the parent job succeeded,
     * so a failed chunk is logged without halting the rest.
     */
    public class ChainFinalizer implements System.Finalizer {

        private final List<Id> transactionIds;
        private final Integer offset;

        /**
         * @param transactionIds The full set of Transactions being fanned out.
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
                // Not a main-path debug: this branch runs only when a chunk has already failed, and
                // it is the only record that it did (the job row shows the failure, not which deals).
                System.debug(LoggingLevel.ERROR, 'ChecklistFanoutQueueable: chunk at offset '
                    + offset + ' failed: ' + context.getException().getMessage()
                    + '. Continuing the chain for the remaining Transactions.');
            }
            Integer next = offset + CHUNK_SIZE;
            if (next >= transactionIds.size()) {
                return;
            }
            // Chained jobs do not execute in test context, so the chain is not enqueued there. The
            // chunk-boundary tests assert what ONE chunk did, which is what this class controls.
            if (Test.isRunningTest()) {
                return;
            }
            System.enqueueJob(new ChecklistFanoutQueueable(transactionIds, next));
        }
    }
}
