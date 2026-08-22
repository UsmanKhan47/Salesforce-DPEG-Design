/**
 * THE SINGLE INGEST ENTRY POINT. Every provider funnels here, and nothing past this line knows or
 * can ask where the rows came from.
 *
 * LAYER - Service. Orchestration only: it calls selectors for data, a domain for the mapping and the
 * health verdict, and owns the mirror DML. No inline SOQL.
 *
 * === WHY THIS ONE METHOD IS WHAT MAKES THE FEATURE PLUGGABLE ===
 * `StubReceivablesFeedProvider` and `AsbReceivablesFeedProvider` produce the same
 * `List&lt;ReceivablesFeedDTO&gt;` and hand it to `ingest`. From here down - mirror upsert, Case
 * lifecycle, escalation ladder, every alert - the code is identical and untested against any
 * particular source. That is what makes switching to the live Yardi feed a Setup edit rather than a
 * rebuild, and it is why a future ASB PUSH adapter (an inbound `@RestResource`, deliberately DEFERRED
 * per design D5) would be ONE new thin class calling this same method, with zero downstream change.
 * FUTURE ENTRY POINT SEAM: name it here when it is built.
 *
 * === DELIBERATE DEVIATION: THE HEALTH CHECK RUNS BEFORE THE UPSERT, NOT AFTER ===
 * FSD 5.9.6 numbers the steps Load (1) then Health check (2), and the design document reproduces that
 * order. This implementation checks FIRST and states the deviation rather than hiding it. The reason:
 * every input the check needs (`feedAsOf`, `rows.size()`, the previous baseline) is available before
 * a single row is written, and the mirror is a SCREEN humans read. Loading a collapsed or stale feed
 * and only then declining to open Cases would still publish wrong balances to every property manager
 * and to the section 6.1 and 6.5 dashboards. Checking first makes `Lifecycle_Ran__c = false` mean the
 * crisp, single-assertion thing it should mean: NOTHING WAS WRITTEN AT ALL.
 * Consequence to know: on a halt, `Rows_Upserted__c` is 0 rather than the row count. `Row_Count__c`
 * still records what the feed offered, so the audit row still says how big the suspect feed was.
 *
 * === `allOrNone = false` MAKES PARTIAL FAILURE SILENT, SO THE FAILURES ARE CAPTURED, NOT DISCARDED ===
 * The upsert is partial-success on purpose - one bad row must not cost the other 500. But that turns
 * every refusal into a `SaveResult` nobody reads by default. Every failure is therefore counted into
 * `Rows_Failed__c` and the first few messages are written into `Sync_Run__c.Halt_Detail__c`, so a run
 * that "succeeded" while dropping 200 rows is visible on the audit row instead of invisible.
 *
 * SHARING - `with sharing` on the class; the mirror DML is escaped in `MirrorWrites`. See that inner
 * class for why.
 *
 * @see ReceivablesFeedProvider.cls        (the swap point feeding this method)
 * @see ReceivablesHealthCheckDomain.cls   (the halt rule)
 * @see ReceivablesSyncBatch.cls           (the lifecycle this hands off to)
 */
public with sharing class ReceivablesSyncService {

    /** Cap on how many upsert failure messages are written into `Halt_Detail__c` (a 4000-char field). */
    @TestVisible
    private static final Integer MAX_LOGGED_FAILURES = 10;

    /** What one ingest did. Returned so the caller can stamp the audit row without re-querying. */
    public class IngestResult {
        /** True when the feed passed the health check and the mirror was written. */
        public Boolean isHealthy = false;
        /** `Sync_Run__c.Halt_Reason__c` value; `'None'` when healthy. */
        public String haltReason = ReceivablesHealthCheckDomain.REASON_NONE;
        /** `Sync_Run__c.Halt_Detail__c` text; null when healthy and nothing failed. */
        public String haltDetail;
        /** Rows the feed offered, recorded even on a halt. */
        public Integer rowCount = 0;
        /** Rows successfully upserted. Zero on a halt - see the class header. */
        public Integer rowsUpserted = 0;
        /** Rows the upsert refused. */
        public Integer rowsFailed = 0;
    }

    /**
     * THE ENTRY POINT. Health-check a feed and, if it passes, write it to the mirror.
     *
     * The brief specifies `ingest(List&lt;FeedDTO&gt;)`; this is that method with the two pieces of
     * metadata the halt rule cannot work without. `rows` is the payload and is the only thing that
     * varies by source. `feedAsOf` is the FEED's own clock - not Salesforce's - and passing it
     * separately is what stops a caller quietly substituting `System.now()` and making the staleness
     * arm permanently vacuous. `syncRunId` is stamped on every row so per-row staleness is auditable.
     *
     * @param rows      Normalized feed rows; null/empty safe.
     * @param feedAsOf  The feed's own as-of timestamp. NULL IS TREATED AS STALE, deliberately.
     * @param syncRunId The audit row this ingest belongs to; required for the row stamp.
     * @return What happened; never null. The caller stamps `Sync_Run__c` from it.
     * @example
     * ReceivablesSyncService.IngestResult r =
     *     ReceivablesSyncService.ingest(feed.rows, feed.feedAsOf, runId);
     */
    public static IngestResult ingest(List<ReceivablesFeedDTO> rows, DateTime feedAsOf, Id syncRunId) {
        IngestResult result = new IngestResult();
        List<ReceivablesFeedDTO> feedRows = (rows == null) ? new List<ReceivablesFeedDTO>() : rows;
        result.rowCount = feedRows.size();

        // ── STEP 2 FIRST (see the class header): decide whether this feed may be acted on at all ──
        Sync_Run__c baseline = SyncRunSelector.selectLastCompleted();
        ReceivablesHealthCheckDomain.Verdict verdict = ReceivablesHealthCheckDomain.evaluate(
            feedAsOf,
            result.rowCount,
            (baseline == null) ? null : baseline.Row_Count__c,
            System.now(),
            ReceivablesSyncConfig.stalenessToleranceHours(),
            ReceivablesSyncConfig.minimumRowCount(),
            ReceivablesSyncConfig.maximumRowCountChangePct()
        );
        if (verdict.isHealthy != true) {
            result.haltReason = verdict.haltReason;
            result.haltDetail = verdict.haltDetail;
            return result;
        }

        result.isHealthy = true;
        if (feedRows.isEmpty()) {
            // Healthy but empty: legitimate when nobody is delinquent and the floor arm is unarmed.
            return result;
        }

        // ── STEP 1: resolve the joins ONCE, then map, then one DML ────────────────────────────────
        Map<String, Unit__c> unitsByKey =
            ReceivablesUnitSelector.selectByYardiUnitIds(ReceivablesSummaryDomain.collectUnitKeys(feedRows));
        Map<String, Id> userIdsByUsername =
            UserSelector.selectActiveByUsernames(ReceivablesSummaryDomain.collectManagerUsernames(feedRows));

        List<Receivables_Summary__c> records = ReceivablesSummaryDomain.toRecords(
            feedRows, unitsByKey, userIdsByUsername, syncRunId, feedAsOf);

        List<Database.UpsertResult> saveResults = new MirrorWrites().upsertMirror(records);
        applyUpsertOutcome(result, saveResults);
        return result;
    }

    /**
     * Convenience overload for a provider result.
     *
     * @param feed      A provider's result; null-safe.
     * @param syncRunId The audit row this ingest belongs to.
     * @return What happened; never null.
     */
    public static IngestResult ingest(ReceivablesFeedResult feed, Id syncRunId) {
        if (feed == null) {
            // A null feed carries no clock, which the health check reads as stale. Route it through
            // the same path rather than short-circuiting, so the halt reason is produced by the one
            // class that owns halt reasons.
            return ingest(new List<ReceivablesFeedDTO>(), null, syncRunId);
        }
        return ingest(feed.rows, feed.feedAsOf, syncRunId);
    }

    /**
     * Counts successes and failures, and preserves the first few failure messages so a partial
     * upsert is visible on the audit row rather than silent.
     *
     * @param result      The result to populate.
     * @param saveResults The upsert outcomes, index-aligned to the records.
     */
    private static void applyUpsertOutcome(IngestResult result, List<Database.UpsertResult> saveResults) {
        List<String> failures = new List<String>();
        for (Database.UpsertResult saveResult : saveResults) {
            if (saveResult.isSuccess()) {
                result.rowsUpserted++;
                continue;
            }
            result.rowsFailed++;
            if (failures.size() < MAX_LOGGED_FAILURES) {
                List<String> messages = new List<String>();
                for (Database.Error error : saveResult.getErrors()) {
                    messages.add(error.getStatusCode() + ': ' + error.getMessage());
                }
                failures.add(String.join(messages, ' | '));
            }
        }
        if (!failures.isEmpty()) {
            result.haltDetail = 'Upsert refused ' + result.rowsFailed + ' of ' + saveResults.size()
                + ' rows. First ' + failures.size() + ': ' + String.join(failures, ' || ');
        }
    }

    /**
     * THE MIRROR WRITE, ESCAPED.
     *
     * `Receivables_Summary__c` OWD is Private and every existing row is owned by whichever principal
     * first inserted it. `AccessLevel.SYSTEM_MODE` lifts CRUD and FLS - which the Metadata-API-
     * deployed mirror fields need, since they arrive with FLS for nobody - and NEVER lifts sharing.
     *
     * So without this escape, the first night the job runs under a different principal every UPDATE
     * to an existing row is refused. With `allOrNone = false` those refusals become `SaveResult`s,
     * they land in `Rows_Failed__c`, and the mirror freezes at yesterday's balances while the run
     * reports Completed. Confined to the one statement that needs it, per ARCHITECTURE.md section 2.
     */
    private without sharing class MirrorWrites {

        /**
         * @param records Mirror rows to upsert on the unique external id.
         * @return Index-aligned upsert results; never null.
         */
        private List<Database.UpsertResult> upsertMirror(List<Receivables_Summary__c> records) {
            if (records == null || records.isEmpty()) {
                return new List<Database.UpsertResult>();
            }
            return Database.upsert(
                records,
                Receivables_Summary__c.Yardi_AR_Id__c,
                false,
                AccessLevel.SYSTEM_MODE
            );
        }
    }
}
