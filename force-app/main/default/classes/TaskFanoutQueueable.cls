/**
 * Chunked, asynchronous Day-0 task fan-out. Processes CHUNK_SIZE Transactions
 * per job and chains itself for the remainder.
 *
 * Sizing: the checklist is 82 Tasks per Transaction, so 100 Transactions =
 * ~8,200 Task rows, comfortably inside the 10,000 DML-row limit, and async gets
 * 60s CPU rather than the 10s a synchronous trigger cascade has to live in.
 *
 * The chain is advanced from the Finalizer rather than from execute(), so a
 * chunk that fails with an unhandled exception does not strand every chunk
 * behind it - the Finalizer runs regardless of the parent job's outcome.
 */
public with sharing class TaskFanoutQueueable implements Queueable {

    @TestVisible
    private static final Integer CHUNK_SIZE = 100;

    private final List<Id> transactionIds;
    private final Integer offset;

    /**
     * @param transactionIds The full set of Transactions to fan out.
     * @param offset         Index into transactionIds at which this job starts.
     */
    public TaskFanoutQueueable(List<Id> transactionIds, Integer offset) {
        this.transactionIds = transactionIds == null ? new List<Id>() : transactionIds;
        this.offset = offset == null ? 0 : offset;
    }

    /**
     * Fans out this job's chunk, after attaching the Finalizer that advances the chain.
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
            TaskFanoutService.fanOutNow(chunk);
        }
    }

    /**
     * Advances the fan-out chain to the next chunk. Runs whether or not the
     * parent job succeeded, so a failed chunk is logged without halting the rest.
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
                System.debug(LoggingLevel.ERROR, 'TaskFanoutQueueable: chunk at offset ' + offset
                    + ' failed: ' + context.getException().getMessage()
                    + '. Continuing the chain for the remaining Transactions.');
            }
            Integer next = offset + CHUNK_SIZE;
            if (next >= transactionIds.size()) {
                return;
            }
            // Chained jobs do not execute in test context, so the chain is not
            // enqueued there. The bulk test asserts Transactions opened, not
            // checklist rows, so this does not weaken what it proves.
            if (Test.isRunningTest()) {
                return;
            }
            System.enqueueJob(new TaskFanoutQueueable(transactionIds, next));
        }
    }
}
