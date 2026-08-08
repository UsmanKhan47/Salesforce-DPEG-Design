/**
 * Failure reporter for `AttachmentPersistQueueable` — the inbound broker-email FILE JOB.
 *
 * ═══ WHY THIS CLASS EXISTS AT ALL ═══
 * The file job's whole purpose is to be the one transaction whose death costs nothing
 * irreplaceable. But "costs nothing" is only true if the death is RECORDED: a job that dies
 * silently leaves a staging row reading `Attachment_Status__c = 'Pending'` forever, a carrier
 * `Attachment` nobody retries, and no queryable evidence that anything went wrong. That is the
 * R1 lesson from the EAC adopter, recorded in ARCHITECTURE.md — a fail-soft write whose ENTIRE
 * failure surface is `allOrNone = false` plus a `System.debug` produces zero writes and no
 * durable signal, which is indistinguishable from "nothing needed writing".
 *
 * A Finalizer is the only mechanism that can report it, because a Queueable's own `catch` is
 * useless against the exception family that motivated this redesign: `System.UnexpectedException:
 * ContentPublication Limit exceeded` **escapes `catch (Exception e)` through two nested layers**
 * (measured, M3). SP-3 measured what a Finalizer does instead — it fires on BOTH an ordinary
 * unhandled exception and an `UnexpectedException`, in test AND production, and **its own DML
 * commits durably in a fresh transaction after the parent's rollback**.
 *
 * ⚠ `EmailCaptureQueueable`'s class header explains why *it* deliberately has NO Finalizer: its
 * work is self-healing and convergent, so there is nothing to compensate for. **That reasoning
 * does not transfer here.** This job's failure would otherwise destroy the only record of itself.
 * Two classes, opposite decisions, both correct.
 *
 * ═══ 🔴 THE ONE THING NEVER TO "TIDY": DETECTION IS A MESSAGE SUBSTRING, NEVER A TYPE CHECK ═══
 * SP-3 measured `ctx.getException().getTypeName()` reporting **`System.AsyncException`**, NOT
 * `System.UnexpectedException` — the platform WRAPS the original exception and preserves its real
 * type and message only as TEXT INSIDE the wrapper's `getMessage()`. An
 * `instanceof System.UnexpectedException` test would therefore SILENTLY NEVER MATCH and the
 * circuit breaker would never trip, with nothing failing to reveal it. `isPublicationLimitFailure`
 * exists as its own pure static method precisely so a test can pin it against the verbatim
 * message from the 2026-08-06 outage log — that test is the only Apex-provable part of the
 * breaker (design §8.2 T7).
 *
 * ═══ EVERYTHING HERE IS WRAPPED ═══
 * A failure to record a failure must not become a second failure. Each step is independently
 * guarded so a broken status stamp cannot prevent the note, and neither can prevent the breaker.
 *
 * ═══ LAYER ═══
 * Finalizer. It holds NO SOQL and NO DML of its own — the staging write is delegated to
 * `InboundEmailStagingService.markAttachmentStatus` and the breaker to `ContentPublicationBudget`.
 * Its writes are a SEPARATE TRANSACTION from the job's, so they sit outside every pinned
 * governor budget by construction.
 *
 * @see AttachmentPersistQueueable.cls (attaches this as its FIRST statement)
 * @see ContentPublicationBudget.trip() (the breaker this may set)
 * @see agent-output/design-requirements-attachment-persistence-v2.md §6.5, §7, §11.3
 * @see agent-output/spike-attachment-persistence-v2.md (SP-3, the measured wrapper behaviour)
 */
public with sharing class AttachmentPersistFinalizer implements System.Finalizer {

    /**
     * The verbatim platform text that identifies a ContentPublication quota refusal, as it
     * appeared in the 2026-08-06 outage log:
     *   `System.UnexpectedException: ContentPublication Limit exceeded.`
     * and as SP-3 measured it surviving inside the `System.AsyncException` wrapper.
     */
    @TestVisible private static final String PUBLICATION_LIMIT_TOKEN =
        'ContentPublication Limit exceeded';

    /**
     * §7 copy for the "the file job died" mode. 🔴 It must name what SURVIVED, because the whole
     * value of the redesign is that the answer is "everything except, temporarily, the file".
     */
    @TestVisible private static final String NOTE_PREFIX = 'NOT SAVED: the file job failed — ';
    @TestVisible private static final String NOTE_SUFFIX =
        '. The Lead, the claim, this row AND THE ATTACHED FILE BYTES are all intact; it will be '
        + 'retried. AsyncApexJob ';

    /** The staging row whose file work this finalizer reports on. */
    private final Id stagingId;

    /**
     * @param stagingId The Inbound_Email_Staging__c row the failing job was working; may be null,
     *                  in which case the finalizer degrades to a debug line and the breaker check.
     */
    public AttachmentPersistFinalizer(Id stagingId) {
        this.stagingId = stagingId;
    }

    /**
     * Record the parent job's outcome. On SUCCESS this does nothing at all — the job stamps its
     * own terminal state, and a second write here would only be able to disagree with it.
     *
     * On `UNHANDLED_EXCEPTION` it does three things, in this order and each independently
     * guarded:
     *   1. stamp `Attachment_Status__c = 'Failed'` — which is what puts the row back in
     *      `AttachmentCarrierSweepBatch`'s work queue, so "failed" means "will be retried";
     *   2. append the durable §7 note naming the wrapped message and the AsyncApexJob Id;
     *   3. trip the circuit breaker IF, and only if, the message identifies a ContentPublication
     *      refusal.
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
                'AttachmentPersistFinalizer: file job ' + jobId + ' failed for staging '
                + stagingId + ': ' + message);

            // Step 1 + 2 — status and note in one call. markAttachmentStatus is itself fail-soft.
            try {
                InboundEmailStagingService.markAttachmentStatus(
                    stagingId,
                    InboundEmailStagingService.ATTACHMENT_STATUS_FAILED,
                    NOTE_PREFIX + message + NOTE_SUFFIX + jobId + '.');
            } catch (Exception recordFailure) {
                System.debug(LoggingLevel.ERROR,
                    'AttachmentPersistFinalizer: could not record the failure on staging '
                    + stagingId + ': ' + recordFailure.getMessage());
            }

            // Step 3 — the breaker. Deliberately AFTER the record, so a breaker failure cannot
            // cost the row its retry marker.
            if (isPublicationLimitFailure(message)) {
                ContentPublicationBudget.trip();
            }
        } catch (Exception e) {
            // A failure to record a failure must not become a second failure.
            System.debug(LoggingLevel.ERROR,
                'AttachmentPersistFinalizer.execute failed for staging ' + stagingId + ': '
                + e.getTypeName() + ' | ' + e.getMessage());
        }
    }

    /**
     * 🔴 SUBSTRING, NEVER A TYPE CHECK.
     *
     * SP-3 measured the platform WRAPPING a `System.UnexpectedException` as
     * `System.AsyncException` before handing it to a Finalizer, preserving the original type and
     * message only as text inside `getMessage()`. An `instanceof` test against either type
     * silently never matches, so the breaker would never trip and nothing would fail to reveal
     * it. Pinned by design §8.2 T7 against the verbatim 2026-08-06 outage message.
     *
     * The comparison is case-INSENSITIVE, a deliberate superset of the design's literal
     * `.contains(...)`: the cost is nil and the failure mode it removes — a platform string whose
     * casing drifts by one character silently disabling the whole breaker — is exactly the class
     * of silent gap this feature exists to close.
     *
     * PURE: no SOQL, no DML, no state. That is what makes it unit-testable at zero quota cost.
     *
     * @param message The finalizer's `ctx.getException().getMessage()`; null/blank is false.
     * @return true when this failure was a ContentPublication quota refusal.
     * @example
     * Boolean tripIt = AttachmentPersistFinalizer.isPublicationLimitFailure(message);
     */
    @TestVisible
    private static Boolean isPublicationLimitFailure(String message) {
        return String.isNotBlank(message)
            && message.containsIgnoreCase(PUBLICATION_LIMIT_TOKEN);
    }
}
