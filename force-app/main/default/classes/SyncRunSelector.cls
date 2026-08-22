/**
 * Selector for `Sync_Run__c`, the receivables ingestion audit trail.
 *
 * MODE - both methods are `WITH SYSTEM_MODE`, and both are AUTOMATION-PATH reads per
 * ARCHITECTURE.md section 2: they run inside a queueable and a batch on the scheduling principal's
 * behalf. `Sync_Run__c` fields were deployed by the Metadata API, which grants FLS to NOBODY -
 * System Administrator included - so a `USER_MODE` read would raise
 * `System.QueryException: No such column` (an FLS denial wearing a schema error) and abort the run.
 *
 * SHARING - ESCAPED, via the `AuditReads` inner class, and this one IS load-bearing.
 * `Sync_Run__c` OWD is Private (verified 2026-08-22 via `EntityDefinition`), and every audit row is
 * owned by whichever principal ran the job that night. `SYSTEM_MODE` lifts CRUD and FLS and NEVER
 * lifts sharing. So if the scheduling principal ever changes - a staffing change, a re-schedule by a
 * different admin - a sharing-filtered `selectLastCompleted` would stop seeing the PREVIOUS
 * principal's runs and silently return null.
 *
 * That failure is not cosmetic. Null means "no baseline", which DISABLES the row-count-change arm of
 * the health check. The feed could double overnight and the run would sail through, because the only
 * check capable of noticing had quietly switched itself off. The escape is confined to the two
 * queries that need it rather than applied to the whole class.
 *
 * @see ReceivablesHealthCheckDomain.cls (the consumer of the baseline)
 */
public with sharing class SyncRunSelector {

    /** `Sync_Run__c.Status__c` value for a run that finished its whole lifecycle. */
    @TestVisible
    private static final String STATUS_COMPLETED = 'Completed';

    /**
     * The most recent COMPLETED run, used as the row-count baseline.
     *
     * Deliberately COMPLETED-only. A halted run's `Row_Count__c` is by definition a count nobody
     * trusted, and letting it become the baseline would ratchet the comparison onto bad data: one
     * truncated feed would halt, then the NEXT night's healthy feed would look like a huge increase
     * against the truncated baseline and halt too, and the job would wedge itself shut.
     *
     * @return The latest completed run, or null when none exists (first-ever run). Null is a valid
     *         answer and disables the change arm rather than halting - a first run has nothing to be
     *         compared against and must not be punished for it.
     */
    public static Sync_Run__c selectLastCompleted() {
        return new AuditReads().lastCompleted();
    }

    /**
     * One run by Id, for tests and for a caller that needs to re-read what it stamped.
     *
     * @param syncRunId The run Id; null-safe.
     * @return The run, or null.
     */
    public static Sync_Run__c selectById(Id syncRunId) {
        if (syncRunId == null) {
            return null;
        }
        return new AuditReads().byId(syncRunId);
    }

    /**
     * The sharing escape, confined to the two audit reads that need it. See the class header for why
     * a sharing-filtered baseline read silently disables the health check's change arm rather than
     * failing loudly.
     */
    private without sharing class AuditReads {

        private Sync_Run__c lastCompleted() {
            String completed = STATUS_COMPLETED;
            List<Sync_Run__c> runs = [
                SELECT Id, Row_Count__c, Feed_As_Of_DateTime__c, Finished_DateTime__c, Status__c
                FROM Sync_Run__c
                WHERE Status__c = :completed
                WITH SYSTEM_MODE
                ORDER BY Started_DateTime__c DESC, Id DESC
                LIMIT 1
            ];
            return runs.isEmpty() ? null : runs[0];
        }

        private Sync_Run__c byId(Id syncRunId) {
            List<Sync_Run__c> runs = [
                SELECT Id, Status__c, Halt_Reason__c, Halt_Detail__c, Lifecycle_Ran__c,
                       Row_Count__c, Rows_Upserted__c, Rows_Failed__c,
                       Cases_Opened__c, Cases_Escalated__c, Cases_Closed__c,
                       Started_DateTime__c, Finished_DateTime__c, Feed_As_Of_DateTime__c,
                       Provider_Class_Name__c, Source__c
                FROM Sync_Run__c
                WHERE Id = :syncRunId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            return runs.isEmpty() ? null : runs[0];
        }
    }
}
