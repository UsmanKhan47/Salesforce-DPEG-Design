/**
 * Failure reporter for `ExtractAddressQueueable` — the inbound broker-email ROUTING JOB.
 *
 * ═══ WHY THIS CLASS EXISTS AT ALL ═══
 * `AttachmentPersistQueueable` was made safe by giving it a Finalizer, a status field, a work
 * queue and a sweeper — but that job deliberately owns NOTHING irreplaceable. The routing job is
 * the opposite: it owns **the Lead, the `Property_Registry__c` claim, the
 * `Competing_Broker_Submission__c` audit row and the Task**, and until 2026-08-08 it had none of
 * those four protections. Its uncatchable death therefore left a staging row reading
 * `Status__c = 'Pending'` with `Outcome__c` and `Error__c` both null, forever, with a failed
 * `AsyncApexJob` as the only evidence anywhere that a broker's email had been destroyed — and
 * nothing to retry it. Worse, a stranded row carrying no attachment sits at
 * `Attachment_Status__c = 'None'`, which is not in the file sweeper's work queue at all, so it was
 * not merely skipped by the one existing retry engine: it was never even selected.
 *
 * 🔴 **A `try/catch (Exception e)` CANNOT SUBSTITUTE FOR THIS, AND THAT IS MEASURED, NOT ASSUMED.**
 * SP-R1 (2026-08-08, `usman-dpeg`) ran a heap-exhausting and a CPU-exhausting Queueable with the
 * failing code wrapped in a `catch (Exception e)` positioned directly around it. **The catch block
 * never ran in either case** — zero caught rows, both jobs reported `UNHANDLED_EXCEPTION`. That is
 * the literal premise `ExtractAddressQueueable`'s own wrapping catch depends on, and it is false
 * for exactly the failure family this class targets.
 *
 * SP-3 and SP-R1 together establish the mechanism that DOES work: a Finalizer fires on
 * `UNHANDLED_EXCEPTION` — including on an uncatchable governor `LimitException` — and **its own
 * DML commits durably in a fresh transaction after the parent's rollback**. SP-R2 additionally
 * measured `System.attachFinalizer` succeeding inside a `Queueable, Database.AllowsCallouts`
 * class shaped exactly like `ExtractAddressQueueable`, and still firing after a real HTTP callout
 * had been made — which is what clears the concrete risk that every previously-measured Finalizer
 * in this repo was on a PLAIN Queueable.
 *
 * ⚠ `EmailCaptureQueueable`'s header explains why *it* deliberately has NO Finalizer: its work is
 * self-healing and convergent, so there is nothing to compensate for. **That reasoning does not
 * transfer here** — this job's failure destroys the only record of itself, and a lost claim is
 * recoverable only by manual registry surgery. Three classes, three decisions, all correct.
 *
 * ═══ 🔴 IT RECORDS. IT DOES NOT RETRY. ═══
 * SP-2 Q3 measured that a Finalizer's own `System.enqueueJob` works in production, so an immediate
 * retry from here is technically available. It is deliberately NOT taken (design D3):
 *
 *   1. an uncatchable failure is usually DETERMINISTIC, not transient — heap and CPU depend on the
 *      email's own size and shape, so an instant re-run of identical input fails identically and
 *      burns a real LLM callout doing it;
 *   2. it is structurally UNTESTABLE — SP-2 Q3 also measured a Finalizer's enqueue being accepted
 *      but NEVER EXECUTED inside `@isTest`, which would add a third untestable seam to a module
 *      that already documents two;
 *   3. **two retry mechanisms cannot share one cap.** `Routing_Attempt_Count__c` is incremented in
 *      exactly one place (this class, via the service) and consulted in exactly one place
 *      (`RoutingRetrySweepBatch`). 🔴 That is also why this class does NOT clamp the counter to the
 *      attempt cap and must never be "improved" to do so — clamping here would BE a second
 *      consumer of the retry policy, and the cap would then live in two files that drift.
 *
 * ═══ 🔴 THE ONE THING NEVER TO "TIDY": DETECTION IS A MESSAGE SUBSTRING, NEVER A TYPE CHECK ═══
 * SP-3 measured `ctx.getException().getTypeName()` reporting `System.AsyncException` rather than
 * the real `System.UnexpectedException`. **SP-R1 GENERALISED THAT BEYOND THE ContentPublication
 * CASE**: a heap `LimitException` and a CPU `LimitException` BOTH arrived wrapped as
 * `System.AsyncException`, with the real type and message preserved only as TEXT inside
 * `getMessage()` (`System.LimitException: Apex heap size too large: 52481351`). An `instanceof`
 * or `getTypeName()` test would therefore silently never match, and nothing would fail to reveal
 * it.
 *
 * ⚠ **BUT THE WRAPPING IS NOT UNIVERSAL — DO NOT INVERT THE RULE.** SP-R2 measured an ORDINARY
 * custom exception thrown after a callout arriving at the Finalizer with its REAL, UNWRAPPED type.
 * So a type check is not merely unreliable, it is unreliable in a way that varies by failure
 * family. Substring matching is the only approach that is correct in both cases, which is why
 * `classify` is a pure `@TestVisible` static with no dependency on the exception object at all.
 *
 * ═══ EVERYTHING HERE IS WRAPPED ═══
 * A failure to record a failure must not become a second failure. Each step is independently
 * guarded, and the outer `catch (Exception)` exists so a broken classification can never cost the
 * row its status stamp.
 *
 * ═══ LAYER ═══
 * Finalizer. It holds NO SOQL and NO DML of its own — the staging write is delegated to
 * `InboundEmailStagingService.markRoutingFailed`. Its writes are a SEPARATE TRANSACTION from the
 * job's, so they sit outside every pinned `ExtractAddressQueueable` governor budget BY
 * CONSTRUCTION (N=1: 30 SOQL / 20 DML / 7 DML; N=10: 120 SOQL / 43 DML). Budget for this class:
 * **1 SOQL / 1 DML, constant.**
 *
 * @see ExtractAddressQueueable.cls (attaches this as its FIRST statement)
 * @see RoutingRetrySweepBatch.cls (the only consumer of the counter this increments)
 * @see AttachmentPersistFinalizer.cls (the file pipeline's mirror of this class)
 * @see agent-output/design-requirements-routing-resilience.md §3.1, §3.2, §3.4
 * @see agent-output/spike-routing-resilience.md (SP-R1, SP-R2 — the measured behaviour above)
 */
public with sharing class RoutingFailureFinalizer implements System.Finalizer {

    /**
     * The verbatim platform text identifying an Apex HEAP exhaustion, as SP-R1 measured it
     * surviving inside the `System.AsyncException` wrapper:
     *   `System.LimitException: Apex heap size too large: 52481351`
     * The numeric tail varies per run, so only the stable prefix is matched.
     */
    @TestVisible private static final String HEAP_LIMIT_TOKEN = 'Apex heap size too large';

    /**
     * The verbatim platform text identifying an Apex CPU-time exhaustion, as SP-R1 measured it:
     *   `System.LimitException: Apex CPU time limit exceeded`
     */
    @TestVisible private static final String CPU_LIMIT_TOKEN = 'Apex CPU time limit exceeded';

    /** Classification labels written into the durable note. Short on purpose — a human scanning
     *  the Errors list view needs to tell "this email is too big and always will be" from
     *  "something transient happened" at a glance, without reading a stack trace. */
    @TestVisible private static final String CLASS_HEAP = 'heap limit (deterministic — this email '
        + 'will fail again at the same size)';
    @TestVisible private static final String CLASS_CPU = 'CPU limit (deterministic — this email '
        + 'will fail again at the same shape)';
    @TestVisible private static final String CLASS_OTHER = 'unclassified';

    /**
     * The durable §7-style copy. 🔴 It must name what SURVIVED and what did NOT, because the whole
     * value of the `Failed` state is that the answer to "did anything commit?" is provably "no".
     */
    @TestVisible private static final String NOTE_PREFIX = 'ROUTING FAILED: the routing job died '
        + 'with an unhandled exception — ';
    @TestVisible private static final String NOTE_MIDDLE = '. Classified as ';
    @TestVisible private static final String NOTE_SUFFIX = '. NOTHING was committed by that '
        + 'attempt (no Lead, no registry claim, no submission, no Task), so it is safe to retry '
        + 'and it will be retried automatically. The raw email and its headers on THIS row are '
        + 'intact. AsyncApexJob ';

    /** The staging row whose routing this finalizer reports on. */
    private final Id stagingId;

    /**
     * @param stagingId The Inbound_Email_Staging__c row the failing job was routing; may be null,
     *                  in which case the finalizer degrades to a debug line and writes nothing.
     */
    public RoutingFailureFinalizer(Id stagingId) {
        this.stagingId = stagingId;
    }

    /**
     * Record the parent routing job's outcome.
     *
     * On SUCCESS — and on every result other than `UNHANDLED_EXCEPTION` — this does NOTHING AT
     * ALL. That is not an optimisation: the job stamps its own terminal state through
     * `markRouted`, and a second write here could only ever DISAGREE with it. In particular a
     * caught, stamped `Error` row must never be dragged into `Failed`, because the two have
     * opposite replay-safety properties (see `InboundEmailStagingService.STATUS_FAILED`).
     *
     * On `UNHANDLED_EXCEPTION` it performs exactly one delegated write: stamp
     * `Status__c = 'Failed'`, increment `Routing_Attempt_Count__c`, and APPEND a durable note
     * naming the wrapped message, the classification and the `AsyncApexJob` Id. Stamping 'Failed'
     * is what puts the row into `RoutingRetrySweepBatch`'s work queue, so "failed" here means
     * "will be retried".
     *
     * @param ctx The finalizer context supplied by the platform.
     */
    public void execute(System.FinalizerContext ctx) {
        try {
            if (ctx == null || ctx.getResult() != System.ParentJobResult.UNHANDLED_EXCEPTION) {
                return;
            }

            Exception cause = ctx.getException();
            String message = (cause == null) ? 'unknown failure' : cause.getMessage();
            String jobId = String.valueOf(ctx.getAsyncApexJobId());

            System.debug(LoggingLevel.ERROR,
                'RoutingFailureFinalizer: routing job ' + jobId + ' failed for staging '
                + stagingId + ': ' + message);

            if (stagingId == null) {
                // Nothing addressable to record against. The debug line above is all there is —
                // and this is unreachable in practice, since the queueable cannot be constructed
                // without an Id.
                return;
            }

            try {
                InboundEmailStagingService.markRoutingFailed(
                    stagingId,
                    NOTE_PREFIX + message + NOTE_MIDDLE + classify(message) + NOTE_SUFFIX
                        + jobId + '.');
            } catch (Exception recordFailure) {
                System.debug(LoggingLevel.ERROR,
                    'RoutingFailureFinalizer: could not record the failure on staging '
                    + stagingId + ': ' + recordFailure.getMessage());
            }
        } catch (Exception e) {
            // A failure to record a failure must not become a second failure.
            System.debug(LoggingLevel.ERROR,
                'RoutingFailureFinalizer.execute failed for staging ' + stagingId + ': '
                + e.getTypeName() + ' | ' + e.getMessage());
        }
    }

    /**
     * 🔴 SUBSTRING, NEVER A TYPE CHECK. See the class header for the two independent measurements
     * that force this: SP-R1 (heap and CPU `LimitException`s both arrive WRAPPED as
     * `System.AsyncException`) and SP-R2 (an ordinary custom exception arrives UNWRAPPED). A type
     * test is wrong in the first case and right in the second, so it is not usable at all; a
     * substring test is correct in both.
     *
     * The comparison is case-INSENSITIVE, a deliberate superset of a literal `.contains(...)`:
     * the cost is nil and the failure mode it removes — a platform string whose casing drifts by
     * one character silently disabling the classification — is exactly the class of silent gap
     * this feature exists to close.
     *
     * The classification is ADVISORY. Nothing branches on it: every `UNHANDLED_EXCEPTION` is
     * recorded and retried identically regardless of the label. It exists so a human triaging the
     * routing-error list view can separate "deterministic, stop waiting for the retry to fix it"
     * from "unknown, let the sweeper try again" without opening a debug log.
     *
     * PURE: no SOQL, no DML, no state, no dependency on the exception object. That is what makes
     * it unit-testable against a verbatim message string at zero cost (design §9 T3).
     *
     * @param message The finalizer's `ctx.getException().getMessage()`; null/blank is unclassified.
     * @return A short human label for the failure family.
     * @example
     * String label = RoutingFailureFinalizer.classify(
     *     'System.LimitException: Apex heap size too large: 52481351');
     */
    @TestVisible
    private static String classify(String message) {
        if (String.isBlank(message)) {
            return CLASS_OTHER;
        }
        if (message.containsIgnoreCase(HEAP_LIMIT_TOKEN)) {
            return CLASS_HEAP;
        }
        if (message.containsIgnoreCase(CPU_LIMIT_TOKEN)) {
            return CLASS_CPU;
        }
        return CLASS_OTHER;
    }
}
