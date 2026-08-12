/**
 * The ASYNC VENUE for SharePoint deal-folder creation — Gate-1 decision (i), D1 **Option A**
 * (a Queueable chained from the trigger) rather than the design's recommended Option B.
 *
 * Chained from `DealFolderService.ensureOnClosedWon`, ONCE per trigger chunk, carrying the Ids of
 * the properties that chunk claimed. It walks at most `MAX_PROPERTIES_PER_TRANSACTION` of them and
 * RE-ENQUEUES ITSELF for the remainder.
 *
 * ═══ 🔴 WHY IT MUST BE ASYNC, AND WHY IT MUST SELF-CHAIN ═══
 * Two separate reasons, and neither substitutes for the other:
 *   1. **Callouts cannot be made with uncommitted DML pending.** The trigger transaction has just
 *      written the deal close; a synchronous callout would throw
 *      `You have uncommitted work pending`. This alone forces async.
 *   2. **The lifecycle-subfolder decision costs 7 callouts per deal against a hard limit of 100 per
 *      transaction.** One job can therefore serve about ten deals, and a 251-deal bulk close cannot
 *      be done in one job at any batch size. The full arithmetic — including why the CUMULATIVE
 *      CALLOUT TIME limit binds before the count limit, and why N is 10 rather than the arithmetic
 *      maximum of 14 — is in `DealFolderService`'s header and is not repeated here so it cannot
 *      drift into two versions.
 *
 * ═══ 🔴 EXACTLY ONE `System.enqueueJob`, AND THAT IS A PLATFORM CONSTRAINT ═══
 * `Limits.getLimitQueueableJobs()` is **1** inside an asynchronous transaction, not 50. A second
 * enqueue in one link throws `System.LimitException: Too many queueable jobs added to the queue: 2`
 * and takes the link with it. So the deferred remainder is returned by the service as ONE list and
 * dispatched by ONE call — never one job per property, and never a job per chunk of the remainder.
 * `RoutingRetrySweepBatch`'s header records the same constraint from the other direction (it is why
 * that batch runs at SCOPE = 1).
 *
 * Chaining itself is NOT subject to the 50-per-transaction cap, because each link is its own
 * transaction — that is precisely what makes an unbounded deal count expressible at all.
 *
 * ═══ ⚠ THE CHAIN IS SUPPRESSED INSIDE `@isTest`, AND THE SEAM IS HOW IT IS TESTED ═══
 * Chaining a Queueable from a Queueable raises `System.AsyncException: Maximum stack depth has been
 * reached` in test context — a platform behaviour, not a bug in this class, and the reason the
 * design flagged Option A's chaining seam as "structurally hard to test". The enqueue is therefore
 * guarded by `Test.isRunningTest()` and the DECISION is exposed on `lastRunChainedIds`, so a test
 * asserts WHICH properties would have been carried forward rather than asserting that the platform
 * performed the enqueue. Same shape as `EmailThreadAdopterService`'s `AdoptionWriter` seam, taken
 * for the same reason: assert the decision when the platform refuses the act.
 *
 * ═══ 🔴 A DEAD LINK IS NOT A LOST FOLDER ═══
 * Every property in the payload was stamped `Pending` SYNCHRONOUSLY, before this job existed. So a
 * link that dies — uncatchably, or by exhausting its own budget, or because the running user has no
 * SharePoint credential grant — leaves its rows in `DealFolderSweepBatch`'s work queue. The
 * Finalizer adds the durable WHY; the sweep provides the retry. Neither is optional, and the sweep
 * is the one that must be SCHEDULED (see `DealFolderSweepSchedule`).
 *
 * ⚠ THE RUNNING PRINCIPAL IS THE ENQUEUING USER. Measured live: a Queueable reports
 * `RAN AS USERNAME: usman.khan.dpeg@...`, not Automated Process — so per-user External Credential
 * Principal Access applies to this job, and a deal closed by a persona without
 * `SharePoint_Integration_Access` will fail here every time, by design, visibly.
 *
 * LAYER — Queueable. No SOQL, no DML, no callouts of its own: it is the venue and the chain, and
 * `DealFolderService` is the work. `Database.AllowsCallouts` because the service it calls makes
 * them.
 *
 * @see DealFolderService.cls      (the work, the budget arithmetic and the never-throw contract)
 * @see DealFolderFinalizer.cls    (the durable failure record for an uncatchable death)
 * @see DealFolderSweepBatch.cls   (the retry, and why it is more load-bearing under Option A)
 */
public with sharing class DealFolderQueueable implements Queueable, Database.AllowsCallouts {

    /** The properties this link and its successors owe a folder, in service order. */
    private final List<Id> propertyIds;

    /**
     * What THIS link handed to the next one — the test seam described in the class header.
     *
     * A static, so it holds only what the current transaction decided. It is a DECISION seam, not a
     * monitoring surface: the durable record of every outstanding property is
     * `Property__c.SharePoint_Folder_Status__c`, which is queryable and is what the sweep consumes.
     */
    @TestVisible private static List<Id> lastRunChainedIds;

    /**
     * Build one link of the folder-creation chain.
     *
     * @param propertyIds The properties owed a SharePoint folder. Null and empty are tolerated —
     *                    the job simply does nothing — because a caller that finds nothing owed
     *                    should not have to guard the constructor.
     */
    public DealFolderQueueable(List<Id> propertyIds) {
        this.propertyIds = (propertyIds == null) ? new List<Id>() : propertyIds;
    }

    /**
     * Create up to `DealFolderService.MAX_PROPERTIES_PER_TRANSACTION` folder trees, then chain the
     * remainder.
     *
     * 🔴 `attachFinalizer` IS THE FIRST STATEMENT, ABOVE EVERYTHING. The same rule
     * `RoutingFailureFinalizer` and `AttachmentPersistFinalizer` carry, for the same measured
     * reason: SP-R1 measured heap and CPU `LimitException`s escaping a `catch (Exception e)` wrapped
     * directly around the failing code, so a `try/catch` cannot substitute for a Finalizer — and
     * anything placed above the attach can kill the job before the thing that would record it
     * exists.
     *
     * @param ctx The queueable context (unused; required by the interface).
     */
    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new DealFolderFinalizer(propertyIds));

        List<Id> remaining = DealFolderService.createFolders(propertyIds);
        lastRunChainedIds = remaining;

        if (remaining == null || remaining.isEmpty()) {
            return;
        }
        // ⚠ EXACTLY ONE enqueue (the async cap is 1), and suppressed under @isTest where the
        // platform refuses a chain outright. The decision is on lastRunChainedIds either way; the
        // rows themselves are still Pending, so even a suppressed chain is recoverable by the sweep.
        if (!Test.isRunningTest()) {
            System.enqueueJob(new DealFolderQueueable(remaining));
        }
    }
}
