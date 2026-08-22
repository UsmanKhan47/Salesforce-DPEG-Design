/**
 * Chunked, asynchronous PM onboarding checklist fan-out. Processes CHUNK_SIZE
 * Onboardings per job and chains itself for the remainder.
 *
 * Sizing: the checklist is 45 Tasks per Onboarding, so 100 Onboardings = ~4,500
 * Task rows plus 100 flag rows, comfortably inside the 10,000 DML-row limit, and
 * async gets 60s CPU rather than the 10s a synchronous trigger cascade lives in.
 * The CPU ceiling — not the row limit — is what forces async here; see
 * `OnboardingFanoutService`'s header for the arithmetic.
 *
 * The chain is advanced from the Finalizer rather than from execute(), so a chunk
 * that fails with an unhandled exception does not strand every chunk behind it —
 * the Finalizer runs regardless of the parent job's outcome.
 *
 * @see force-app/main/default/classes/TaskFanoutQueueable.cls (the mirrored pattern)
 */
public with sharing class OnboardingFanoutQueueable implements Queueable {

    @TestVisible
    private static final Integer CHUNK_SIZE = 100;

    private final List<Id> onboardingIds;
    private final Integer offset;

    /**
     * @param onboardingIds The full set of Onboardings to fan out.
     * @param offset        Index into onboardingIds at which this job starts.
     */
    public OnboardingFanoutQueueable(List<Id> onboardingIds, Integer offset) {
        this.onboardingIds = onboardingIds == null ? new List<Id>() : onboardingIds;
        this.offset = offset == null ? 0 : offset;
    }

    /**
     * Fans out this job's chunk, after attaching the Finalizer that advances the chain.
     * @param context Queueable context (unused).
     */
    public void execute(QueueableContext context) {
        System.attachFinalizer(new ChainFinalizer(onboardingIds, offset));

        List<Id> chunk = new List<Id>();
        Integer endIndex = Math.min(offset + CHUNK_SIZE, onboardingIds.size());
        for (Integer i = offset; i < endIndex; i++) {
            chunk.add(onboardingIds[i]);
        }
        if (!chunk.isEmpty()) {
            OnboardingFanoutService.fanOutNow(chunk);
        }
    }

    /**
     * Advances the fan-out chain to the next chunk. Runs whether or not the parent
     * job succeeded, so a failed chunk is logged without halting the rest.
     */
    public class ChainFinalizer implements System.Finalizer {

        private final List<Id> onboardingIds;
        private final Integer offset;

        /**
         * @param onboardingIds The full set of Onboardings being fanned out.
         * @param offset        Index the parent job started at.
         */
        public ChainFinalizer(List<Id> onboardingIds, Integer offset) {
            this.onboardingIds = onboardingIds;
            this.offset = offset;
        }

        /**
         * @param context Finalizer context carrying the parent job's result.
         */
        public void execute(FinalizerContext context) {
            if (context != null && context.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
                System.debug(LoggingLevel.ERROR, 'OnboardingFanoutQueueable: chunk at offset ' + offset
                    + ' failed: ' + context.getException().getMessage()
                    + '. Continuing the chain for the remaining Onboardings.');
            }
            Integer next = offset + CHUNK_SIZE;
            if (next >= onboardingIds.size()) {
                return;
            }
            // Chained jobs do not execute in test context, so the chain is not
            // enqueued there. The bulk test asserts Onboardings enqueued and ONE
            // chunk's checklist content, which is what the chain would produce
            // anyway — see OnboardingFanoutServiceTest's header.
            if (Test.isRunningTest()) {
                return;
            }
            System.enqueueJob(new OnboardingFanoutQueueable(onboardingIds, next));
        }
    }
}
