/**
 * The RETRY / REPLAY engine for the inbound broker-email ROUTING transaction.
 *
 * ═══ WHAT IT IS FOR ═══
 * `RoutingFailureFinalizer` makes a routing death DURABLE; this class is what makes it
 * RECOVERABLE. Together they give the routing row the same four defined exits the file pipeline's
 * carrier already has:
 *
 *   PROCESSED  markRouted / markSkipped                        — terminal, success
 *   ERROR      markRouted with errorText                       — terminal, HUMAN queue
 *   FAILED     RoutingFailureFinalizer                         — RETRIED ← by this class
 *   ABANDONED  this class, at the attempt cap or the age cap   — terminal, stamps Error
 *
 * ═══ 🔴 IT DISPATCHES `Failed` AND NOTHING ELSE. THIS IS A SAFETY PROOF, NOT A PREFERENCE. ═══
 * `Status__c = 'Failed'` is written by exactly one thing — `RoutingFailureFinalizer`, which fires
 * only on `ParentJobResult.UNHANDLED_EXCEPTION`. SP-5 measured, in this org, that an unhandled
 * exception in a Queueable **rolls back that queueable's own DML** (a marker Task insert and a
 * Lead update both vanished, while an earlier transaction's work survived byte-for-byte). So a
 * `Failed` row provably carries **no Lead, no registry claim, no competing submission, no Task and
 * no staging stamp** from the attempt that failed, and a replay is byte-for-byte a first run.
 * `Failed` is therefore not a label — it IS the replay-safety proof.
 *
 * 🔴 **`Error` HAS THE OPPOSITE PROPERTY AND MUST NEVER BE DISPATCHED.** `Error` means
 * `ExtractAddressQueueable`'s own catch RAN, which means the transaction COMMITTED. Walking the
 * branches of what may already be on disk:
 *
 *   • Lead committed, claim returned UNCLAIMED (a lock timeout) → a replay takes branch (e) and
 *     mints a **SECOND Lead**, which takes the claim; the first Lead is orphaned and unclaimed.
 *   • Registry row committed, the winning submission NOT (a DmlException swallowed between the
 *     two inserts in `registerWinner`) → a replay misses at branch (b) and takes branch (d), so
 *     **the winning broker is filed as a COMPETING submission against their own Lead**, corrupting
 *     the adjudication trail.
 *
 * Neither is recoverable except by manual registry surgery. `Error` is a HUMAN queue; the list
 * view is the remedy, not this batch. The same is true of a stranded `Pending` row, which is
 * ambiguous by construction (it may be a rolled-back job, a job that never ran, or a fully
 * successful run whose fail-soft status stamp was the only thing that failed) — that queue is
 * deliberately NOT built here.
 *
 * The `Failed`-only rule is enforced TWICE on purpose: `queryRoutingRetrySweep()` filters on it,
 * and `execute()` re-checks it in memory. The second check is what a test can falsify by handing
 * `execute()` an `Error` or `Processed` row directly, and it is what protects the rule if anyone
 * ever widens the locator.
 *
 * ═══ 🔴 `SCOPE = 1` IS LOAD-BEARING, FOR A DIFFERENT REASON THAN THE CARRIER SWEEP'S ═══
 * `AttachmentCarrierSweepBatch` uses SCOPE = 1 to give each row its own 12 MB async heap budget.
 * Here the binding constraint is the QUEUEABLE cap: **`Limits.getLimitQueueableJobs()` is 1 inside
 * an asynchronous transaction, not 50.** A batch `execute()` is asynchronous, so a second
 * `System.enqueueJob` in one chunk throws `System.LimitException: Too many queueable jobs added to
 * the queue: 2` — which would abort the chunk and, at any scope above 1, make the sweep's
 * throughput depend on how many rows happened to land together. One row per transaction is the
 * only shape in which "one dispatch per row" is expressible at all. Raising it breaks the feature,
 * not merely its efficiency.
 *
 * It also makes the per-row work in `execute()` a loop over exactly ONE element, which is why the
 * DML inside it does not breach `.claude/rules/apex-layering-rule.md`'s no-DML-in-loops rule — the
 * same justification `AttachmentCarrierSweepBatch` carries.
 *
 * ═══ BULK TESTING — WHAT 251 CAN AND CANNOT PROVE HERE ═══
 * `.claude/rules/bulk-test-rule.md`'s 251-row mandate applies (this is a batch, and staging rows
 * are free — they consume no `ContentPublication`, so the content rule's 20-row ceiling does not
 * apply). But note what the number can prove: **a test method executes only ONE chunk of a batch**,
 * so at SCOPE = 1 a 251-row fixture proves the LOCATOR selects and orders 251 rows and that the
 * batch starts cleanly over them — it does not and cannot drive 251 `execute()` calls. A direct
 * `execute(ctx, <251 rows>)` call is likewise not a meaningful test: 251 dispatches is
 * unreachable in production (the queueable cap is 1) and 251 abandons would exhaust the DML limit,
 * so it would measure a shape this batch can never be in. Assert constant PER-ROW cost instead,
 * and assert the four dispatch decisions (design §9 T4) by calling `execute()` with hand-built
 * rows.
 *
 * ═══ IDEMPOTENT AND CONVERGENT ═══
 * A successful retry stamps `Processed`, which REMOVES the row from this work queue; a failed
 * retry re-stamps `Failed` with an incremented counter, which walks it toward the cap. Either way
 * a second pass is free and the population strictly shrinks. Even the dispatch-failure path is
 * convergent: it records through `markRoutingFailed`, so a row whose enqueue keeps failing
 * eventually reaches the attempt cap and is abandoned rather than retried forever.
 *
 * ═══ LAYER ═══
 * Batch. It holds NO SOQL of its own — `start()` delegates to
 * `InboundEmailStagingSelector.queryRoutingRetrySweep()` per the layering rule — and no DML of its
 * own: every write goes through `InboundEmailStagingService`. Budget per `execute()`:
 * **0 SOQL / ≤ 1 DML / ≤ 1 enqueue** on every path except the dispatch-failure path, which spends
 * 1 SOQL + 1 DML to record itself and is by definition not the success path.
 *
 * @see RoutingFailureFinalizer.cls (writes the 'Failed' state this consumes)
 * @see RoutingRetrySweepSchedule.cls (the hourly trigger — schedule it or every retry is dead)
 * @see AttachmentCarrierSweepBatch.cls (the file pipeline's mirror, and the class whose skip
 *      predicate had to widen the moment 'Failed' became writable)
 * @see agent-output/design-requirements-routing-resilience.md §3.1, §3.3, §8
 */
public with sharing class RoutingRetrySweepBatch
        implements Database.Batchable<SObject>, Database.Stateful {

    /**
     * How many times routing may run for one email before the row is abandoned to the human
     * queue. **3 = the initial run plus 2 retries.**
     *
     * 🔴 THIS IS THE ONLY PLACE THE RETRY POLICY LIVES, AND THAT IS DELIBERATE (design §3.4
     * reason 3). `Routing_Attempt_Count__c` is INCREMENTED in exactly one place
     * (`InboundEmailStagingService.markRoutingFailed`, driven by the Finalizer) and CONSULTED in
     * exactly one place — here. Do not add a cap check to the Finalizer, and do not clamp the
     * counter to this value in the service: two consumers of one policy is how the cap ends up in
     * two files that drift apart with nothing failing to reveal it.
     *
     * The cap is what stops a DETERMINISTIC failure — an FLS gap, or a body that always exhausts
     * heap — from re-running hourly forever. Such a row is meant to reach a person, and this is
     * what makes it.
     */
    @TestVisible private static final Integer MAX_ATTEMPTS = 3;

    /**
     * How long a failed row may keep being retried before it is abandoned. **14 days, aligned
     * deliberately to `AttachmentCarrierSweepBatch.CARRIER_MAX_AGE_DAYS`.**
     *
     * The alignment is not cosmetic. A routing-failed row that carries an attachment is SKIPPED by
     * the file sweeper for as long as it reads 'Failed', and that carrier expires at 14 days. If
     * routing kept retrying past that point the row would outlive its own carrier — routing would
     * eventually succeed onto a Lead whose files had already been deleted as expired. Same number,
     * so that cannot happen.
     */
    @TestVisible private static final Integer ROUTING_MAX_AGE_DAYS = 14;

    /** 🔴 ONE staging row per transaction. See the class header — the async queueable cap is 1,
     *  so this cannot be raised without breaking per-row dispatch outright. */
    public static final Integer SCOPE = 1;

    /**
     * 🔴 THE ATTACHMENT CONSEQUENCE OF ABANDONING, APPENDED TO BOTH CAP NOTES.
     *
     * Abandoning stamps `Status__c = 'Error'`, and `AttachmentCarrierSweepBatch` treats `Error` as
     * terminal-and-routed — so on its next daily pass it converts the carrier with an EMPTY target
     * list, links the files to the staging row ONLY, deletes the carrier and stamps `Saved`. Those
     * are steps 2-4 of the five-step trace in that class's `ROUTING_STATUS_FAILED` header, reached
     * through a different door.
     *
     * ⚠ IT IS DEGRADED, NOT LOST, AND THE ALTERNATIVES ARE WORSE — which is why this is documented
     * rather than "fixed":
     *   • The bytes SURVIVE, permanently, as Files on the staging row. An abandoned row has no
     *     Lead and never will have one, so there is no routed link to lose — linking to the
     *     staging row is the only thing possible.
     *   • Making the file sweeper decline on "no routed target" would break the GATED-email path,
     *     where `Processed` rows legitimately have no target and their files are supposed to land
     *     on the staging row (see `AttachmentCarrierSweepBatch.routedTargets`).
     *   • Stamping a terminal `Attachment_Status__c` instead would remove the row from the file
     *     work queue while leaving the carrier bytes in place — permanent accumulation, and it
     *     could never take the EXPIRED exit.
     * The one genuine residual is a MANUAL re-drive: if a human fixes the cause and re-enqueues
     * routing after the carrier has converted, the files stay on the staging row and are not
     * linked to the new Lead. Hence the instruction in the copy.
     */
    @TestVisible private static final String NOTE_FILES =
        ' ATTACHMENTS: any file on this email will be converted by the daily carrier sweep and '
        + 'linked to THIS STAGING ROW ONLY (there is no routed record to link it to). If you '
        + 're-drive routing by hand later, re-link those files to the new record yourself — the '
        + 'carrier will already be gone.';

    /** The ABANDONED copy for the attempt cap. Names the cap so the row does not read as a
     *  mysterious error, and says plainly that nothing will retry it again. */
    @TestVisible private static final String NOTE_ATTEMPT_CAP =
        'ABANDONED: routing failed MAX_ATTEMPTS (3) times — the initial run plus 2 retries. This '
        + 'is almost certainly a DETERMINISTIC failure (the same email will fail the same way), '
        + 'so it now needs a human. Nothing was committed by any attempt; the raw email and its '
        + 'headers on this row are intact and it can be re-driven by hand once the cause is fixed.'
        + NOTE_FILES;

    /** The ABANDONED copy for the age cap. */
    @TestVisible private static final String NOTE_AGE_CAP =
        'ABANDONED: this row was still failing after ROUTING_MAX_AGE_DAYS (14), which is the same '
        + 'age at which an attachment carrier expires — retrying past it could route onto a Lead '
        + 'whose files had already been deleted. It now needs a human. Nothing was committed by '
        + 'any attempt.'
        + NOTE_FILES;

    /** Prefix for the dispatch-failure note; the row STAYS retryable and its counter advances. */
    @TestVisible private static final String NOTE_DISPATCH_FAILED =
        'ROUTING RETRY NOT DISPATCHED: the sweep could not enqueue a retry for this row — ';

    /**
     * The rows this pass DISPATCHED, in order. A decision seam for tests, not a monitoring
     * surface: it is a static, so it holds only what the CURRENT transaction did, and a batch runs
     * one transaction per chunk. Design §9's third anti-vacuity rule is what it serves — a test
     * asserting "the sweeper did not dispatch this row" must be able to fail, and counting
     * `AsyncApexJob` rows cannot distinguish this batch's own job from the one it enqueued.
     */
    @TestVisible private static List<Id> lastRunDispatchedIds;

    /** Cross-chunk counters (why this is `Database.Stateful`), summarised by finish(). */
    private Integer dispatched = 0;
    private Integer abandoned = 0;
    private Integer skipped = 0;
    private Integer failed = 0;

    /**
     * The work queue: every staging row whose routing transaction died with an unhandled
     * exception, oldest first.
     *
     * @param ctx The batch context (unused; required by the interface).
     * @return A locator over the 'Failed' rows.
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return InboundEmailStagingSelector.queryRoutingRetrySweep();
    }

    /**
     * Dispatch, abandon or skip ONE staging row (SCOPE = 1, so this list holds one element).
     *
     * Order of decisions, and why: the STATUS guard is first because it is the safety rule and
     * must hold even if the locator is ever widened; the ATTEMPT cap is next because it is the
     * ordinary terminal condition; the AGE cap is last because it only matters for a row that has
     * somehow stayed under the attempt cap for a fortnight.
     *
     * FAIL-SOFT PER ROW: a batch has no Finalizer, so — unlike the routing job this class exists
     * to rescue — a failure here is recorded here or nowhere. It is recorded through
     * `markRoutingFailed`, which keeps the row in this queue AND advances its counter, so a row
     * that can never be dispatched still converges on the abandon exit instead of retrying
     * forever.
     *
     * @param ctx   The batch context (unused).
     * @param scope The staging rows to process; SCOPE = 1.
     */
    public void execute(Database.BatchableContext ctx, List<Inbound_Email_Staging__c> scope) {
        lastRunDispatchedIds = new List<Id>();
        if (scope == null || scope.isEmpty()) {
            return;
        }
        for (Inbound_Email_Staging__c row : scope) {
            if (row == null) {
                continue;
            }
            try {
                // 🔴 SAFETY GUARD — see the class header. Only 'Failed' is provably free of
                // committed side effects. An 'Error' or 'Pending' row that somehow reaches here
                // is left exactly as it is.
                if (!InboundEmailStagingService.STATUS_FAILED.equals(row.Status__c)) {
                    skipped++;
                    continue;
                }
                if (attemptsOf(row) >= MAX_ATTEMPTS) {
                    InboundEmailStagingService.markRoutingAbandoned(
                        row.Id, row.Error__c, NOTE_ATTEMPT_CAP);
                    abandoned++;
                    continue;
                }
                if (isExpired(row)) {
                    InboundEmailStagingService.markRoutingAbandoned(
                        row.Id, row.Error__c, NOTE_AGE_CAP);
                    abandoned++;
                    continue;
                }
                // The RETRIED exit. The image is deliberately NOT replayed: base64 image bytes
                // never existed on the staging row (only Has_Image__c / Image_Mime_Type__c do),
                // so a retry runs the text-only extraction path. That is a documented degradation
                // of a retry, not a defect — and it is strictly better than the row staying
                // stranded, which is what happens today.
                System.enqueueJob(new ExtractAddressQueueable(row.Id, null, null));
                lastRunDispatchedIds.add(row.Id);
                dispatched++;
            } catch (Exception e) {
                failed++;
                System.debug(LoggingLevel.ERROR,
                    'RoutingRetrySweepBatch: staging ' + row.Id + ' failed: '
                    + e.getTypeName() + ' | ' + e.getMessage());
                InboundEmailStagingService.markRoutingFailed(
                    row.Id,
                    NOTE_DISPATCH_FAILED + e.getTypeName() + ' | ' + e.getMessage()
                        + '. The row stays in the retry queue and its attempt counter has '
                        + 'advanced, so it will be abandoned rather than retried indefinitely.');
            }
        }
    }

    /**
     * Summarise the pass. Deliberately a debug line and nothing more: the durable record of every
     * outcome already lives on each staging row's own `Status__c`, `Routing_Attempt_Count__c` and
     * `Error__c`, which are queryable and are what the routing list views surface — unlike a
     * static or a log.
     *
     * @param ctx The batch context (unused).
     */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO,
            'RoutingRetrySweepBatch finished: dispatched=' + dispatched
            + ' abandoned=' + abandoned + ' skipped=' + skipped + ' failed=' + failed);
    }

    /**
     * How many times routing has already died on this row.
     *
     * @param row The staging row, carrying `Routing_Attempt_Count__c` from the locator.
     * @return The attempt count; a null counter is 0, which is the correct reading for a row
     *         stamped by an older build before the field existed.
     */
    private static Integer attemptsOf(Inbound_Email_Staging__c row) {
        Decimal attempts = row.Routing_Attempt_Count__c;
        return (attempts == null) ? 0 : attempts.intValue();
    }

    /**
     * Whether this row has outlived `ROUTING_MAX_AGE_DAYS`.
     *
     * Age is measured from the staging row's own `CreatedDate` — the moment the broker's email
     * arrived — rather than from the last attempt, so the cap bounds how long a broker's email can
     * remain unrouted in absolute terms. Measuring from the last attempt would let a row that
     * fails slowly live indefinitely.
     *
     * @param row The staging row.
     * @return true when the row should be abandoned rather than retried.
     */
    private static Boolean isExpired(Inbound_Email_Staging__c row) {
        return row.CreatedDate != null
            && row.CreatedDate < Datetime.now().addDays(-ROUTING_MAX_AGE_DAYS);
    }
}
