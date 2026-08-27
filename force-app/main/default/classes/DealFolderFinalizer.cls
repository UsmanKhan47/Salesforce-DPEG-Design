/**
 * The SharePoint deal-folder job's FAILURE REPORTER. Attached as the first statement of
 * `DealFolderQueueable.execute`; on an unhandled death it stamps `Failed` and a durable,
 * human-readable reason onto the properties that link was carrying.
 *
 * ═══ 🔴 WHY A FINALIZER AND NOT A `try/catch` — MEASURED, NOT ASSUMED ═══
 * SP-R1 (2026-08-08, recorded in `RoutingFailureFinalizer`'s header) ran heap- and CPU-exhausting
 * Queueables with `catch (Exception e)` positioned DIRECTLY around the failing code: **the catch
 * never ran in either case.** A Finalizer fires anyway, in its own fresh transaction, and SP-3
 * measured that its DML COMMITS DURABLY even after the parent transaction's total rollback. That is
 * the mechanism this class depends on, and it is the only mechanism available for the failure
 * family that matters here — a job that walks 70 callouts is a genuine candidate for exhausting the
 * callout, CPU or cumulative-callout-time limits, all of which are UNCATCHABLE.
 *
 * The design named a Finalizer mandatory rather than optional the moment D1 Option A was chosen
 * (§6.4). This is that class.
 *
 * ═══ IT RECORDS; IT DOES NOT RETRY ═══
 * `DealFolderSweepBatch` is the retry, and it already sees these rows — they were stamped `Pending`
 * synchronously (at CLAIM-STAGE entry since 2026-08-27, which is a deal's first forward step rather
 * than its close) and `Failed` is in the same work queue. Re-enqueueing from here would be worse than
 * useless: a Finalizer's enqueue is accepted-but-never-executed inside `@isTest`, so the retry
 * would be untestable, and an uncatchable failure is usually DETERMINISTIC, so an immediate replay
 * would burn the same budget the same way. The same division of labour `RoutingFailureFinalizer`
 * (records) and `RoutingRetrySweepBatch` (retries) already use.
 *
 * ⚠ THE SWEEP IS THEREFORE LOAD-BEARING FOR THIS CLASS TOO. Without a scheduled sweep, this
 * Finalizer produces a perfectly explained `Failed` row that nothing will ever act on — which is a
 * WORSE state than a bare `Pending`, because it reads as handled.
 *
 * ═══ ⚠ ONLY `UNHANDLED_EXCEPTION` IS ACTED ON ═══
 * A Finalizer fires on SUCCESS as well. Acting on a successful run would overwrite the `Created`
 * stamps the job just committed, which is the one thing worse than not reporting a failure.
 *
 * ⚠ NO TYPE CHECK ON THE EXCEPTION. SP-3 and SP-R1 both measured the platform WRAPPING an
 * uncatchable failure as `System.AsyncException` while preserving the real type and message only as
 * TEXT inside `getMessage()` — and SP-R2 measured an ordinary custom exception arriving UNWRAPPED.
 * The wrapping varies by failure family, so this class records the type and the message verbatim
 * and classifies nothing. Anyone adding an `instanceof` here should read those two findings first.
 *
 * LAYER — Finalizer. No SOQL and no DML of its own: the read-then-stamp goes through
 * `DealFolderService.markFailed`, which is fail-soft by contract. Budget: 1 SOQL / <= 1 DML, in its
 * own transaction, outside every pinned `DealFolderService` budget by construction.
 *
 * @see DealFolderQueueable.cls        (attaches it as the FIRST statement)
 * @see DealFolderService.markFailed   (the read-then-stamp, and why it re-reads)
 * @see RoutingFailureFinalizer.cls    (the precedent, and the SP-R1 measurement)
 */
public with sharing class DealFolderFinalizer implements System.Finalizer {

    /** Opening line of the durable failure text, so a human reading `Property__c` knows the folder
     *  job DIED rather than that SharePoint refused a request. Those need different responses. */
    @TestVisible private static final String PREFIX =
        'the SharePoint deal-folder job terminated abnormally (no request was necessarily sent). ';

    /** Copy naming the recovery path, because the row itself is the only place a human looks. */
    @TestVisible private static final String SUFFIX =
        ' Nothing was committed by this attempt. The scheduled DealFolderSweepBatch will retry this '
        + 'property; if that job is not scheduled, nothing will.';

    /** The payload the dying link was carrying. May include properties an EARLIER link already
     *  completed, which is exactly why `markFailed` re-reads before it writes. */
    private final List<Id> propertyIds;

    /**
     * Capture the payload whose failure this finalizer will report.
     *
     * @param propertyIds The queueable's payload; null-safe.
     */
    public DealFolderFinalizer(List<Id> propertyIds) {
        this.propertyIds = (propertyIds == null) ? new List<Id>() : propertyIds;
    }

    /**
     * Record an abnormal termination against the payload's properties.
     *
     * @param ctx The finalizer context — `getResult()`, `getException()` and `getAsyncApexJobId()`
     *            are all consumed; the job Id is included in the stamp so the failure can be tied
     *            back to an `AsyncApexJob` row.
     */
    public void execute(System.FinalizerContext ctx) {
        if (ctx == null || ctx.getResult() != System.ParentJobResult.UNHANDLED_EXCEPTION) {
            return; // a successful run already wrote its own stamps — do not overwrite them
        }
        Exception cause = ctx.getException();
        String detail = (cause == null)
            ? 'no exception was reported by the platform'
            : cause.getTypeName() + ' | ' + cause.getMessage();

        DealFolderService.markFailed(
            propertyIds,
            PREFIX + detail + ' [AsyncApexJob ' + ctx.getAsyncApexJobId() + ']' + SUFFIX);
    }
}
