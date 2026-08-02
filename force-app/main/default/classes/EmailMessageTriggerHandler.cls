/**
 * Trigger handler for the standard EmailMessage object. Its single job is to enqueue
 * the EAC capture pipeline — adopter then guard — for every newly captured email.
 *
 * ⚠ THE ENQUEUE COUNT IS STILL EXACTLY ONE PER TRIGGER CHUNK, and that is a constraint
 * rather than a coincidence (adopter added 2026-08-02). Both halves run inside the SAME
 * job (EmailCaptureQueueable) precisely so this handler's cap math below is unchanged: a
 * second enqueue per chunk would halve the throughput ceiling that protects EAC's own
 * insert, for no correctness gain. A future third EmailMessage concern belongs inside
 * that queueable too, not in a second `System.enqueueJob` here.
 *
 * ═══ FIRST STANDARD-OBJECT TRIGGER DRIVEN BY AN EXTERNAL CAPTURE SYSTEM ═══
 * Every other trigger in this repo fires on records THIS app creates. This one fires
 * on rows Einstein Activity Capture writes on its own schedule, in bulk, as a
 * principal none of this repo's permission sets provision. Three consequences worth
 * knowing before changing anything here:
 *
 *   • VOLUME IS NOT OURS TO CONTROL. EAC batch-inserts captures, so this handler can
 *     see hundreds of rows across several trigger chunks in one transaction. Nothing
 *     per-record may ever happen here.
 *   • THE WORK MUST BE ASYNC. `EmailMessageRelation` rows land AFTER the
 *     EmailMessage in the same transaction, so the guard's association check is
 *     meaningless until post-commit. See EmailCaptureQueueable's header.
 *   • THE RUNNING PRINCIPAL IS NOT A HUMAN. The guard's selectors run
 *     `WITH SYSTEM_MODE` for exactly this reason.
 *
 * ═══ 🔴 WHY THE QUEUEABLE-LIMIT CHECK IS LOAD-BEARING ═══
 * `Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()` is NOT defensive
 * boilerplate. Apex caps `System.enqueueJob` at 50 calls per transaction, and THIS
 * HANDLER'S ENQUEUE COUNT IS PROPORTIONAL TO EAC'S BATCH SIZE, which nothing in this
 * org controls: triggers fire in chunks of 200, so a 10,001-row EAC capture batch
 * runs afterInsert 51 times and the 51st enqueue would throw
 * `System.LimitException: Too many queueable jobs added to the queue`. That
 * exception would roll back EAC's own insert — the guard would take the captures
 * down with it.
 *
 * The same check also absorbs an ALREADY-SATURATED transaction, where other
 * automation has consumed the slots before EAC's insert lands.
 *
 * Skipping is always safe and throwing never is, because the guard is SELF-HEALING
 * (EmailThreadGuardService gotcha 6): a capture missed here is examined again the
 * next time EAC re-syncs it, and the one-off sweep (`EmailThreadGuardService.run`
 * over a date window) is the documented remedy for any tail the cap truncates. Do
 * not "tighten" this into an unconditional enqueue.
 *
 * ⚠ MEASURED, NOT ASSUMED — the legacy "only 1 queueable per TEST transaction" rule
 * does NOT apply in this org: `ExtractAddressQueueableTest` enqueues 25 jobs in a
 * single test transaction and passes. The cap is 50 in tests as in production, which
 * is why the 251-row bulk test (two chunks → two enqueues) is a valid test rather
 * than an immediate limit failure.
 *
 * ═══ LAYER ═══
 * Handler (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md): routes context,
 * holds no SOQL, no DML and no business logic. The decision lives in
 * EmailThreadGuardService. Named for the OBJECT, not the feature, because this org
 * enforces one trigger per object — a future second EmailMessage concern belongs in
 * this same handler, not in a second trigger.
 *
 * @see triggers/EmailMessageTrigger.trigger (one line, delegates here)
 * @see EmailCaptureQueueable.cls (adopter then guard, in one job)
 * @see EmailThreadAdopterService.cls / EmailThreadGuardService.cls
 */
public with sharing class EmailMessageTriggerHandler extends TriggerHandler {

    /**
     * Enqueues the capture pipeline for the captured messages in this trigger chunk.
     * A no-op when no queueable slot is available.
     *
     * There is deliberately NO null/empty guard on `newMap`. `afterInsert()` is reached
     * only through the base dispatcher, which fires it solely on AFTER_INSERT, and
     * `Trigger.newMap` in that context always holds at least one row. A guard here would
     * be unreachable in production — and unreachable code cannot be honestly tested, so
     * it was removed rather than propped up with a test that fabricates a state the
     * platform never produces.
     */
    protected override void afterInsert() {
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return;
        }
        System.enqueueJob(new EmailCaptureQueueable(newMap.keySet()));
    }
}
