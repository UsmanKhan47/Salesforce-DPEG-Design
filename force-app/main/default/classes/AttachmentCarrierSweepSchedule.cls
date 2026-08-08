/**
 * Daily trigger for `AttachmentCarrierSweepBatch` — the retry/replay engine for inbound
 * broker-email attachment carriers.
 *
 * 🔴 **SCHEDULING THIS IS A DEPLOY GATE, NOT A NICE-TO-HAVE.** A scheduled-job INSTANCE is not
 * deployable metadata, so a deploy that skips it leaves this class present, compiled and inert —
 * and with it EVERY retry path in the attachment design. A carrier deferred by the heap gate, a
 * carrier held back by the daily budget, a carrier stranded by a failed file job and a carrier
 * that should have expired at 14 days would all simply sit on their staging rows forever. That
 * is exactly the class of silent gap the whole 2026-08-06 redesign exists to close, so it is a
 * RECORDED, VERIFIED post-deploy step (design §10.2 A5, §13 step 6, UAT U13).
 *
 * Schedule it off-peak, e.g.:
 *   System.schedule('Attachment Carrier Sweep', '0 0 3 * * ?', new AttachmentCarrierSweepSchedule());
 *
 * ⚠ SCOPE IS TAKEN FROM `AttachmentCarrierSweepBatch.SCOPE` AND MUST NOT BE OVERRIDDEN HERE.
 * It is 1 because each staging row needs its own 12 MB async heap budget for the conversion heap
 * gate to remain valid — see that class's header.
 *
 * LAYER — Schedulable. No SOQL, no DML, no logic: it exists only to start the batch.
 *
 * @see AttachmentCarrierSweepBatch.cls (what it runs, and why SCOPE is 1)
 * @see agent-output/design-requirements-attachment-persistence-v2.md §6.4, §11.5
 */
public with sharing class AttachmentCarrierSweepSchedule implements Schedulable {

    /**
     * Start one carrier sweep.
     *
     * @param ctx The schedulable context (unused; required by the interface).
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new AttachmentCarrierSweepBatch(), AttachmentCarrierSweepBatch.SCOPE);
    }
}
