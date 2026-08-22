/**
 * One nightly ingestion pass: open the audit row, resolve the provider, fetch, ingest, hand off to
 * the lifecycle batch.
 *
 * LAYER - Queueable. `Database.AllowsCallouts` because `AsbReceivablesFeedProvider` makes one.
 *
 * === A `Sync_Run__c` ROW IS WRITTEN FOR EVERY RUN, INCLUDING EVERY HALT ===
 * That record IS the FSD 5.9.6 halt rule. A rule that refuses to act but leaves no trace is
 * indistinguishable from a job that never ran, and "no delinquency alerts arrived" is
 * indistinguishable from "nobody is delinquent". Every exit path below writes one, with a
 * `Halt_Reason__c` picklist value that says which arm fired.
 *
 * === THE SIX HALT REASONS, AND WHY THEY ARE NOT ONE GENERIC FAILURE ===
 *   Disabled                  a human switched it off. The nightly no-op is correct.
 *   Config Missing            somebody INTENDED it to run and it cannot - unset thresholds, blank
 *                             provider name, or a provider class name that no longer resolves.
 *   Callout Failure           the bus refused, timed out, or is not provisioned.
 *   Parse Failure             the payload arrived and was not the agreed shape.
 *   Stale Feed                the feed could not be proven fresh.
 *   Row Count Below Minimum / Row Count Change Exceeded - the feed is the wrong SIZE.
 * Collapsing these would make a forgotten post-deploy gate look identical to a middleware outage.
 *
 * === NEVER FALL BACK TO THE STUB ===
 * When `Type.forName` cannot resolve the configured class, this halts as `Config Missing`. It does
 * NOT quietly run `StubReceivablesFeedProvider` instead. A silent stub fallback in production would
 * publish FIXTURE balances as if they were Yardi's, open Cases against them, and email principals
 * about tenants who owe nothing - and the run would look perfectly healthy. This is the single most
 * important line in the class.
 *
 * === RUNS AS THE ENQUEUING USER ===
 * A Queueable executes as whoever enqueued it (measured in this repo on `DealFolderQueueable`). So
 * the scheduling principal is the one whose External Credential principal access governs the ASB
 * callout, and the one who owns every `Sync_Run__c` and mirror row it creates - which is precisely
 * why every selector and every DML in this feature is sharing-escaped.
 *
 * POST-DEPLOY GATE: nothing schedules this. See `ReceivablesSyncSchedule`.
 *
 * @see ReceivablesSyncService.cls (the single ingest entry point)
 * @see ReceivablesSyncBatch.cls   (the lifecycle this hands off to)
 */
public with sharing class ReceivablesIngestQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final String STATUS_RUNNING = 'Running';
    @TestVisible private static final String STATUS_HALTED = 'Halted';
    @TestVisible private static final String STATUS_FAILED = 'Failed';
    @TestVisible private static final String REASON_DISABLED = 'Disabled';
    @TestVisible private static final String REASON_CONFIG_MISSING = 'Config Missing';
    @TestVisible private static final String REASON_CALLOUT_FAILURE = 'Callout Failure';
    @TestVisible private static final String REASON_PARSE_FAILURE = 'Parse Failure';
    /** Source recorded when no provider could be resolved, so `Source__c` is never left blank. */
    @TestVisible private static final String SOURCE_UNKNOWN = 'Stub';

    /** Id of the audit row the last execution wrote. Test assertion surface. */
    @TestVisible private static Id lastSyncRunId;

    /**
     * Run one ingestion pass.
     *
     * @param context The queueable context (unused; required by the interface).
     */
    public void execute(QueueableContext context) {
        DateTime startedAt = System.now();

        // ── Gate 0: is the feature configured and switched on? Costs ZERO SOQL. ─────────────────
        if (!ReceivablesSyncConfig.isReady()) {
            String reason = ReceivablesSyncConfig.unavailableReason();
            writeHalt(startedAt, reason, detailForUnavailable(reason), null, SOURCE_UNKNOWN, 0);
            return;
        }

        String providerName = ReceivablesSyncConfig.providerClassName();

        // ── Gate 1: does the configured class still exist and still implement the interface? ────
        ReceivablesFeedProvider provider = resolveProvider(providerName);
        if (provider == null) {
            writeHalt(startedAt, REASON_CONFIG_MISSING,
                'Provider class "' + providerName + '" could not be resolved to a '
                + 'ReceivablesFeedProvider. A class referenced only by a config string can be '
                + 'deleted or renamed with no compile error. Refusing to fall back to the stub - a '
                + 'fixture-driven run in production would publish balances Yardi never sent.',
                providerName, SOURCE_UNKNOWN, 0);
            return;
        }

        // ── Open the audit row. From here every exit path updates this record. ─────────────────
        Sync_Run__c run = new Sync_Run__c(
            Started_DateTime__c = startedAt,
            Status__c = STATUS_RUNNING,
            Provider_Class_Name__c = providerName,
            Source__c = provider.sourceLabel(),
            Lifecycle_Ran__c = false
        );
        new AuditWrites().insertRun(run);
        lastSyncRunId = run.Id;

        // ── Fetch. Providers must not throw for an ordinary failure, but a defective one might. ─
        ReceivablesFeedResult feed;
        try {
            feed = provider.fetch(new ReceivablesFeedRequest(run.Id, startedAt, null));
        } catch (System.JSONException e) {
            finishRun(run, STATUS_HALTED, REASON_PARSE_FAILURE, e.getMessage(), null, 0, 0, 0);
            return;
        } catch (Exception e) {
            finishRun(run, STATUS_FAILED, REASON_CALLOUT_FAILURE,
                e.getTypeName() + ': ' + e.getMessage(), null, 0, 0, 0);
            return;
        }
        if (feed == null) {
            finishRun(run, STATUS_HALTED, REASON_CALLOUT_FAILURE,
                'Provider returned null.', null, 0, 0, 0);
            return;
        }

        // ── Health check + mirror upsert, behind the ONE entry point. ──────────────────────────
        ReceivablesSyncService.IngestResult ingest =
            ReceivablesSyncService.ingest(feed.rows, feed.feedAsOf, run.Id);

        if (ingest.isHealthy != true) {
            finishRun(run, STATUS_HALTED, ingest.haltReason, ingest.haltDetail,
                feed.feedAsOf, ingest.rowCount, 0, 0);
            return;
        }

        // Healthy. Record the load, leave Status Running, and hand the lifecycle to the batch -
        // which is what stamps Completed and Lifecycle_Ran__c once steps 3-6 have actually run.
        run.Feed_As_Of_DateTime__c = feed.feedAsOf;
        run.Row_Count__c = ingest.rowCount;
        run.Rows_Upserted__c = ingest.rowsUpserted;
        run.Rows_Failed__c = ingest.rowsFailed;
        run.Halt_Detail__c = ingest.haltDetail;
        new AuditWrites().updateRun(run);

        Database.executeBatch(new ReceivablesSyncBatch(run.Id), ReceivablesSyncBatch.SCOPE);
    }

    /**
     * `Type.forName` dispatch - the swap point.
     *
     * @param className The configured Apex class name.
     * @return An instance, or null when the name does not resolve, is not instantiable, or does not
     *         implement `ReceivablesFeedProvider`. Every one of those is a halt, never a fallback.
     */
    @TestVisible
    private static ReceivablesFeedProvider resolveProvider(String className) {
        if (String.isBlank(className)) {
            return null;
        }
        Type providerType = Type.forName(className);
        if (providerType == null) {
            return null;
        }
        try {
            Object instance = providerType.newInstance();
            return (instance instanceof ReceivablesFeedProvider)
                ? (ReceivablesFeedProvider) instance
                : null;
        } catch (Exception e) {
            // Abstract class, no no-arg constructor, or a constructor that threw.
            System.debug(LoggingLevel.WARN,
                'ReceivablesIngestQueueable: provider instantiation failed - ' + e.getMessage());
            return null;
        }
    }

    /**
     * @param reason The `Halt_Reason__c` value.
     * @return Operator-facing detail explaining what to do about it.
     */
    private static String detailForUnavailable(String reason) {
        return (reason == REASON_DISABLED)
            ? 'Receivables_Sync_Config__c.Is_Enabled__c is false. The nightly no-op is deliberate.'
            : 'Receivables_Sync_Config__c is missing a provider class name or both opening '
              + 'thresholds. Custom setting DATA is not deployable - create the org-default row in '
              + 'Setup. There is deliberately no hardcoded fallback.';
    }

    /**
     * Writes a halt audit row for a run that never got as far as opening one.
     *
     * @param startedAt    Run start.
     * @param reason       `Halt_Reason__c` value.
     * @param detail       `Halt_Detail__c` text.
     * @param providerName Configured provider name, or null.
     * @param source       `Source__c` value (restricted picklist - never blank).
     * @param rowCount     Rows offered by the feed.
     */
    private static void writeHalt(DateTime startedAt, String reason, String detail,
            String providerName, String source, Integer rowCount) {
        Sync_Run__c run = new Sync_Run__c(
            Started_DateTime__c = startedAt,
            Finished_DateTime__c = System.now(),
            Status__c = STATUS_HALTED,
            Halt_Reason__c = reason,
            Halt_Detail__c = detail,
            Provider_Class_Name__c = providerName,
            Source__c = source,
            Row_Count__c = rowCount,
            Rows_Upserted__c = 0,
            Rows_Failed__c = 0,
            Cases_Opened__c = 0,
            Cases_Escalated__c = 0,
            Cases_Closed__c = 0,
            Lifecycle_Ran__c = false
        );
        new AuditWrites().insertRun(run);
        lastSyncRunId = run.Id;
    }

    /**
     * Closes an already-open audit row.
     *
     * @param run          The audit row.
     * @param status       `Status__c` value.
     * @param reason       `Halt_Reason__c` value.
     * @param detail       `Halt_Detail__c` text.
     * @param feedAsOf     The feed's clock, if one was obtained.
     * @param rowCount     Rows offered.
     * @param rowsUpserted Rows written.
     * @param rowsFailed   Rows refused.
     */
    private static void finishRun(Sync_Run__c run, String status, String reason, String detail,
            DateTime feedAsOf, Integer rowCount, Integer rowsUpserted, Integer rowsFailed) {
        run.Status__c = status;
        run.Halt_Reason__c = reason;
        run.Halt_Detail__c = (detail == null) ? null : detail.abbreviate(3900);
        run.Feed_As_Of_DateTime__c = feedAsOf;
        run.Row_Count__c = rowCount;
        run.Rows_Upserted__c = rowsUpserted;
        run.Rows_Failed__c = rowsFailed;
        run.Cases_Opened__c = 0;
        run.Cases_Escalated__c = 0;
        run.Cases_Closed__c = 0;
        // The single assertion for FSD 5.9.6's first safety rule: nothing was created or escalated.
        run.Lifecycle_Ran__c = false;
        run.Finished_DateTime__c = System.now();
        new AuditWrites().updateRun(run);
    }

    /**
     * ESCAPED. `Sync_Run__c` OWD is Private and rows are owned by whichever principal ran the job.
     * `SYSTEM_MODE` covers the Metadata-API-deployed fields (which arrive with FLS for nobody) but
     * never sharing, so a change of scheduling principal would otherwise make the audit row
     * un-updatable - losing the halt evidence this whole class exists to produce.
     */
    private without sharing class AuditWrites {
        private void insertRun(Sync_Run__c run) {
            Database.insert(run, true, AccessLevel.SYSTEM_MODE);
        }
        private void updateRun(Sync_Run__c run) {
            Database.update(run, true, AccessLevel.SYSTEM_MODE);
        }
    }
}
