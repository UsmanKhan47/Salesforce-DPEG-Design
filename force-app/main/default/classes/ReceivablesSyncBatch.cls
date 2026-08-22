/**
 * The nightly delinquency lifecycle: FSD 5.9.6 steps 3-6 across every mirror row this run wrote,
 * then the date-driven alerts of 5.9.7, then the audit row is closed.
 *
 * LAYER - Batch. `Database.Stateful` ONLY to carry the counters across chunks. NOT
 * `Database.AllowsCallouts`: the feed is already landed by the time this starts, and declaring
 * callouts it does not make would invite somebody to add one.
 *
 * === SCOPE = 200, AND IT IS A THROUGHPUT NUMBER RATHER THAN A CALLOUT BUDGET ===
 * Do NOT copy `DealFolderSweepBatch`'s SCOPE = 10 - that number is a callout budget for a job making
 * seven HTTP calls per record, and none of that arithmetic applies here. The binding costs in this
 * job are SOQL, DML and the trigger cascade, and at 200 the budget per chunk is:
 *   SOQL  1 duplicate-Case guard read + at most 3 for GroupNotifier group/type resolution, which is
 *         transaction-cached and therefore 3 TOTAL rather than 3 per call = 4 of 200.
 *   DML   at most 3 - insert new Cases, update existing Cases, update mirror rows.
 * TRIGGER CASCADE ARITHMETIC, which is what actually punishes a larger scope: a bulk DML fires
 * triggers in 200-record batches, costing `ceil(rows / 200)` SOQL AND DML statements PER trigger. At
 * SCOPE = 200 each DML statement is exactly one firing. At SCOPE = 2000 the same three statements
 * would fire thirty times. This is not hypothetical - it cost the onboarding stream 23 + 23 at
 * production scale in this same repo.
 *
 * === WHY THE ALERTS RUN IN `finish()` AND NOT IN `execute()` ===
 * The stale-follow-up, promise-to-pay-breach and write-off alerts are driven by the passage of TIME
 * and by Case state, not by tonight's feed. Per chunk they would re-query the same set N times and
 * would still MISS any Case whose tenant is absent from the feed - the population most likely to have
 * been forgotten. Once per run, in `finish()`, is both cheaper and more correct. FSD 5.9.6 describes
 * ONE nightly job, so no second schedulable is introduced for them.
 *
 * === `Lifecycle_Ran__c = true` IS WRITTEN HERE AND ONLY HERE ===
 * That boolean is the entire test surface for the halt rule: it is true only when steps 3-6 actually
 * executed. Every halt path in `ReceivablesIngestQueueable` leaves it false and never reaches this
 * class.
 *
 * @see ReceivablesIngestQueueable.cls (what starts this, and every halt path that does not)
 * @see DelinquencyCaseService.cls     (steps 3-6)
 */
public with sharing class ReceivablesSyncBatch
        implements Database.Batchable<SObject>, Database.Stateful {

    /** See the class header. A throughput number, not a callout budget. */
    public static final Integer SCOPE = 200;

    @TestVisible private static final String STATUS_COMPLETED = 'Completed';
    @TestVisible private static final String REASON_NONE = 'None';

    private final Id syncRunId;
    /** Captured ONCE so a long run cannot straddle midnight and disagree with itself. */
    private final Date asOf;

    private Integer casesOpened = 0;
    private Integer casesEscalated = 0;
    private Integer casesClosed = 0;
    private Integer chunksFailed = 0;
    private String firstChunkError;

    /**
     * @param syncRunId The audit row whose rows this pass processes; required.
     */
    public ReceivablesSyncBatch(Id syncRunId) {
        this.syncRunId = syncRunId;
        this.asOf = Date.today();
    }

    /**
     * @param context Batch context.
     * @return Locator over the mirror rows this run wrote. Delegated to the selector, per
     *         `.claude/rules/apex-layering-rule.md` - the batch owns no SOQL of its own.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        return ReceivablesSummarySelector.queryLifecycleLocator(syncRunId);
    }

    /**
     * Steps 3-6 for one chunk.
     *
     * A chunk that throws is COUNTED AND SWALLOWED rather than allowed to abort the batch. One bad
     * property must not cost every other property its nightly refresh, and the failure is recorded on
     * the audit row so it is visible rather than merely survived.
     *
     * @param context Batch context.
     * @param scope   Mirror rows, at most `SCOPE`.
     */
    public void execute(Database.BatchableContext context, List<Receivables_Summary__c> scope) {
        try {
            DelinquencyCaseService.LifecycleResult result =
                DelinquencyCaseService.processSummaries(scope);
            casesOpened += result.casesOpened;
            casesEscalated += result.casesEscalated;
            casesClosed += result.casesClosed;
        } catch (Exception e) {
            chunksFailed++;
            if (firstChunkError == null) {
                firstChunkError = e.getTypeName() + ': ' + e.getMessage();
            }
        }
    }

    /**
     * The date-driven alerts, then close the audit row.
     *
     * @param context Batch context.
     */
    public void finish(Database.BatchableContext context) {
        String alertError;
        try {
            PaymentCommitmentService.SweepResult sweep = PaymentCommitmentService.sweepBreaches(asOf);
            casesOpened += 0; // reopened Cases are counted separately below, not as opens
            DelinquencyAlertService.AlertResult alerts = DelinquencyAlertService.sweepAlerts(asOf);
            alertError = summariseSweep(sweep, alerts);
        } catch (Exception e) {
            alertError = 'Alert sweep failed: ' + e.getTypeName() + ': ' + e.getMessage();
        }

        Sync_Run__c run = new Sync_Run__c(Id = syncRunId);
        run.Status__c = STATUS_COMPLETED;
        run.Halt_Reason__c = REASON_NONE;
        run.Cases_Opened__c = casesOpened;
        run.Cases_Escalated__c = casesEscalated;
        run.Cases_Closed__c = casesClosed;
        // True ONLY here. Every halt path leaves it false and never reaches this class.
        run.Lifecycle_Ran__c = true;
        run.Finished_DateTime__c = System.now();
        run.Halt_Detail__c = buildDetail(alertError);
        new AuditWrites().updateRun(run);
    }

    /**
     * @param sweep  Commitment sweep counters.
     * @param alerts Alert sweep counters.
     * @return A one-line summary for the audit row, so a healthy run still says what it did.
     */
    private String summariseSweep(PaymentCommitmentService.SweepResult sweep,
            DelinquencyAlertService.AlertResult alerts) {
        return 'Breached ' + sweep.breached + '; reopened ' + sweep.reopened
            + '; stale reminders ' + alerts.staleReminders
            + '; write-offs routed ' + alerts.writeOffsRouted + '.';
    }

    /**
     * @param alertSummary The alert-sweep line, or an error.
     * @return Combined detail, abbreviated to fit the 4000-character long text field.
     */
    private String buildDetail(String alertSummary) {
        List<String> parts = new List<String>();
        if (alertSummary != null) {
            parts.add(alertSummary);
        }
        if (chunksFailed > 0) {
            parts.add('Chunks failed: ' + chunksFailed + '. First error: ' + firstChunkError);
        }
        return parts.isEmpty() ? null : String.join(parts, ' ').abbreviate(3900);
    }

    /**
     * ESCAPED. `Sync_Run__c` OWD is Private; the row was inserted by the queueable's principal and
     * this batch may not be the same principal. `SYSTEM_MODE` covers the Metadata-API-deployed fields
     * but never sharing, and a refused update here would leave the run stuck on `Running` forever -
     * which the next night's baseline read would then skip, silently disabling the row-count-change
     * arm of the health check.
     */
    private without sharing class AuditWrites {
        private void updateRun(Sync_Run__c run) {
            Database.update(run, false, AccessLevel.SYSTEM_MODE);
        }
    }
}
