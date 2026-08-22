/**
 * The trigger for the nightly receivables sync (FSD 5.9.6).
 *
 * LAYER - Schedulable. No SOQL, no DML, no logic: it exists only to enqueue the ingest.
 *
 * === SCHEDULING THIS IS A POST-DEPLOY GATE, AND MISSING IT FAILS COMPLETELY SILENTLY ===
 * A scheduled-job INSTANCE is not deployable metadata. A deploy that skips this step leaves the class
 * present, compiled, tested, covered and COMPLETELY INERT: zero mirror rows, zero Cases, zero alerts,
 * zero errors, zero failed `AsyncApexJob` rows.
 *
 *   System.schedule('DPEG Receivables Sync', '0 0 3 * * ?', new ReceivablesSyncSchedule());
 *
 * WARNING - THE ABSENCE OF EVIDENCE IS ESPECIALLY DECEPTIVE HERE. This feature's whole audit design
 * assumes a `Sync_Run__c` row exists for every night. An unscheduled job produces NO row at all,
 * which reads identically to "the job ran and had nothing to do" only if you do not check dates.
 * Verify in Setup, and verify by listing `Sync_Run__c` for the last seven days.
 *
 * === WHO OWNS THE SCHEDULE IS PART OF THE GATE ===
 * A Queueable executes as whoever enqueued it, so the scheduling principal is the identity that:
 *   - owns every `Sync_Run__c` and `Receivables_Summary__c` row the job creates;
 *   - must hold External Credential principal access for the ASB callout once the spoke exists.
 * Every selector and every DML in this feature is sharing-escaped precisely so a CHANGE of that
 * principal cannot silently break the job - but the escapes are the thing to verify rather than
 * assume. Confirm, AS THE SCHEDULING PRINCIPAL, that a pass updates a mirror row and a Case that
 * principal does not own. If the `without sharing` inner classes are ever watered down in review, the
 * symptom is an all-zeros run summary indistinguishable from a healthy quiet night.
 *
 * === CADENCE - NIGHTLY, AND EARLY ===
 * FSD 5.9.6's own cadence. Re-running is safe: the duplicate-Case guard makes a second pass in one
 * day a genuine no-op for Case creation, and the escalation ladder's one-way markers make it a no-op
 * for alerts. Scheduling it LESS often delays every rung; not scheduling it at all disables the
 * feature entirely.
 *
 * @see ReceivablesIngestQueueable.cls (the work)
 * @see NdaExpiryAlertSchedule.cls     (the in-repo precedent for this shape and this gate)
 */
public with sharing class ReceivablesSyncSchedule implements Schedulable {

    /** 03:00 daily. Early enough that the mirror is fresh before the property managers start. */
    public static final String CRON_NIGHTLY = '0 0 3 * * ?';
    /** The job name used by `scheduleNightly()`; also what to look for in Setup. */
    public static final String JOB_NAME = 'DPEG Receivables Sync';

    /**
     * Start one ingestion pass.
     *
     * @param context The schedulable context (unused; required by the interface).
     */
    public void execute(SchedulableContext context) {
        System.enqueueJob(new ReceivablesIngestQueueable());
    }

    /**
     * Convenience helper for the post-deploy gate, so the cron expression is not retyped by hand.
     *
     * @return The `CronTrigger` Id of the scheduled job.
     * @example
     * ReceivablesSyncSchedule.scheduleNightly();
     */
    public static String scheduleNightly() {
        return System.schedule(JOB_NAME, CRON_NIGHTLY, new ReceivablesSyncSchedule());
    }
}
