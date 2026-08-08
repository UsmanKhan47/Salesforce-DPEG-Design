/**
 * HOURLY trigger for `RoutingRetrySweepBatch` — the retry engine for the inbound broker-email
 * routing transaction.
 *
 * 🔴 **SCHEDULING THIS IS A DEPLOY GATE, NOT A NICE-TO-HAVE.** A scheduled-job INSTANCE is not
 * deployable metadata, so a deploy that skips it leaves this class present, compiled and inert —
 * and with it EVERY routing retry in the design. A staging row whose routing job died would be
 * stamped `Failed` by `RoutingFailureFinalizer`, appear correctly in the routing-failed list view,
 * and then sit there forever with a broker's Lead and registry claim never created. That is a
 * WORSE outcome than today's stranded `Pending`, because the row now LOOKS handled. It is
 * therefore a RECORDED, VERIFIED post-deploy step (design §10 A6, §13 step 9, UAT U2).
 *
 * ⚠ HOURLY, NOT DAILY — and the difference is not taste. This module's whole purpose is
 * FIRST-BROKER-WINS, and a claim is TIME-ORDERED: a broker whose email died and is retried an hour
 * later can still lose the property to a broker who submitted afterwards but routed cleanly in
 * between. Retry latency is therefore a real cost paid by a real broker, unlike the file
 * pipeline's daily carrier sweep, where a late file is merely late. Cron has no "every hour"
 * keyword, so this is scheduled as one job per hour, or with a single expression:
 *
 *   System.schedule('Routing Retry Sweep', '0 0 * * * ?', new RoutingRetrySweepSchedule());
 *
 * ═══ 🔴 WHO SCHEDULES IT IS PART OF THE GATE — NOT ONLY THAT IT IS SCHEDULED ═══
 * **The schedule must be owned by a principal with View All on `Inbound_Email_Staging__c`** (a
 * System Administrator satisfies this). Record the owning user in the deployment log alongside the
 * cron expression, and re-verify it whenever that user is deactivated.
 *
 * The engine itself no longer depends on this — `InboundEmailStagingSelector.RoutingReads` and
 * `InboundEmailStagingService.RoutingWrites` are `without sharing`, so the sweep SEES and STAMPS
 * every failed row regardless of who runs it. But one leg is deliberately left open, and it is the
 * dispatched job rather than the dispatcher:
 *
 *   `System.enqueueJob(new ExtractAddressQueueable(row.Id, …))` runs as the ENQUEUING user, and
 *   that job loads its row through `InboundEmailStagingSelector.selectById`, which is
 *   **`with sharing`** and is explicitly out of scope for this change (it is the critical path of
 *   every inbound email, and the design fences it off). Under this object's `Private` OWD, a
 *   scheduling principal without View All would therefore get `getStaging(...) == null`, and the
 *   retried job would log "staging record not found" and return — no exception, no Finalizer, no
 *   counter increment, so the row is re-dispatched every hour forever.
 *
 * That is why this is a named operational requirement rather than a preference. The clean
 * structural fix — giving `selectById` the same treatment — is a separate, reviewed change.
 *
 * ⚠ SCOPE IS TAKEN FROM `RoutingRetrySweepBatch.SCOPE` AND MUST NOT BE OVERRIDDEN HERE. It is 1
 * because `Limits.getLimitQueueableJobs()` is **1** inside an asynchronous transaction, so one
 * dispatch per chunk is the only shape in which per-row retry is expressible — see that class's
 * header.
 *
 * ⚠ RE-RUNNING IS FREE. The sweep is convergent: a successful retry stamps `Processed` and a
 * failed one advances the attempt counter, so both remove the row from the queue eventually and an
 * extra pass writes nothing. There is no harm in scheduling it more often than hourly; there is
 * real harm in scheduling it less often, or not at all.
 *
 * LAYER — Schedulable. No SOQL, no DML, no logic: it exists only to start the batch.
 *
 * @see RoutingRetrySweepBatch.cls (what it runs, and why SCOPE is 1)
 * @see AttachmentCarrierSweepSchedule.cls (the file pipeline's mirror — DAILY, deliberately)
 * @see agent-output/design-requirements-routing-resilience.md §3.1, §10 A6, §12 D7
 */
public with sharing class RoutingRetrySweepSchedule implements Schedulable {

    /**
     * Start one routing retry sweep.
     *
     * @param ctx The schedulable context (unused; required by the interface).
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new RoutingRetrySweepBatch(), RoutingRetrySweepBatch.SCOPE);
    }
}
