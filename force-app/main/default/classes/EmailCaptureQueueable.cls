/**
 * Async wrapper for BOTH halves of the EAC capture pipeline. Deliberately THIN: it
 * carries the captured EmailMessage Ids across the transaction boundary, builds the
 * shared anchor index ONCE, and runs the adopter and then the guard. No decision, no
 * SOQL and no DML lives here.
 *
 * ⚠ RENAMED FROM `EmailThreadGuardQueueable` 2026-08-02, when the adopter was added.
 * A class named "guard" that also ADOPTS is a trap for the next reader, and this repo
 * names things for what they are. The rename is mechanical — the sweep entry points are
 * the SERVICES (`EmailThreadAdopterService.run` / `EmailThreadGuardService.run`), so no
 * runbook, backfill script or scheduled job referenced this class by name.
 *
 * ═══ 🔴 WHY THIS HOP EXISTS AT ALL ═══
 * The work cannot run synchronously in the trigger. Einstein Activity Capture inserts
 * the `EmailMessageRelation` rows — the record of WHICH Leads a capture landed on —
 * AFTER the `EmailMessage` itself, within the same transaction. A synchronous
 * after-insert check would query those relations and legitimately find NONE, concluding
 * "not Lead-related" for every capture and making the guard a permanent no-op.
 * Post-commit execution is the only point at which the association is visible.
 *
 * This class is therefore NOT an optional performance nicety and must not be "optimized
 * away" back into the trigger, however tempting the single-hop version looks in a diff.
 *
 * ═══ 🔴 THE THREE THINGS THIS EXECUTE METHOD GETS RIGHT, IN ORDER ═══
 *   1. **ONE INDEX, BUILT ONCE.** Both services ask the same question of the same anchor
 *      data with opposite polarity. Building it here and passing it down is what makes
 *      the two features normalize identifiers IDENTICALLY BY CONSTRUCTION rather than by
 *      convention (EmailThreadAnchorService header, defect P4). Calling the one-argument
 *      `run(Set<Id>)` on either service would silently double the anchor read AND
 *      reintroduce the drift the shared index exists to prevent.
 *   2. **ADOPTER FIRST, ALWAYS.** Adoption is what makes an Opportunity-anchored capture
 *      visibly anchored. Running the guard first would delete such a capture — related
 *      only to an unrelated same-address Lead — seconds before the adopter ever saw it
 *      (finding P6). The guard re-reads the messages, so it observes the `RelatedToId`
 *      the adopter just wrote and keeps the row via its widened guard 4.
 *   3. **THE ADOPTER'S FAILURE IS ISOLATED, THE GUARD'S IS NOT.** The adopter call is
 *      wrapped in its own try/catch so an adoption failure can never prevent the guard
 *      from cleaning EAC's over-association — the deployed, live behaviour must not
 *      regress because a new feature threw. The guard is deliberately left UNWRAPPED:
 *      its failure surfaces as a failed `AsyncApexJob`, which is the visibility this
 *      module wants, and a silently disabled guard is the failure mode the whole feature
 *      exists to avoid.
 *
 * ═══ LAYER / SHARING ═══
 * `with sharing` per ARCHITECTURE.md §2. Note that this is not the effective mode of the
 * work: both services declare `without sharing` (justified in their own headers) and
 * Apex uses the declaring class's mode, so the elevated scope stays contained in the two
 * classes that need it — the same containment pattern as BrokerPortalController →
 * BrokerPortalService.
 *
 * NOT `Database.AllowsCallouts` — neither service makes one, and adding the interface
 * would widen this job's contract for nothing.
 *
 * NOT `System.Finalizer` either, and that is a decision rather than an omission (PMD
 * raises `QueueableWithoutFinalizer` here). A Finalizer exists to run compensating work
 * when a job dies, but this job HAS no compensating work: the guard is SELF-HEALING (it
 * re-examines a capture the next time EAC re-syncs it) and adoption is CONVERGENT (a
 * re-run recomputes the same target and writes only on difference — see
 * EmailThreadAdopterService D5). A Finalizer would add a second failure surface to
 * protect work that needs no protection. Failures stay visible in `AsyncApexJob`.
 *
 * @see EmailThreadAnchorService.cls (the shared index and the single normalization)
 * @see EmailThreadAdopterService.cls (runs FIRST — the RelatedToId writes)
 * @see EmailThreadGuardService.cls (runs SECOND — the deletes, and the seven gotchas)
 * @see EmailMessageTriggerHandler.cls (the only enqueuer)
 */
public with sharing class EmailCaptureQueueable implements Queueable {

    /** Captured EmailMessage Ids to examine post-commit. Immutable once constructed. */
    private final Set<Id> messageIds;

    /**
     * GOVERNOR COUNTERS for the WHOLE execution — captured inside the async context,
     * which is the only place they mean anything: `Test.stopTest()` restores the pre-test
     * limit counters, so a `Limits.getQueries()` assertion written after it is silently
     * vacuous. Same pattern and the same reason as
     * `ExtractAddressQueueable.lastRunQueryCount`.
     *
     * The budget is CONSTANT, not per-message — anchor read + message/companion reads for
     * each service + the guard's relation read. A change that adds one query per captured
     * message fails in `EmailThreadAdopterServiceTest.adopterAt251Captures_isBulkSafe`
     * rather than in a live EAC batch.
     */
    @TestVisible
    private static Integer lastRunQueryCount = 0;
    @TestVisible
    private static Integer lastRunDmlStatements = 0;

    /**
     * Captures the message Ids to examine once the transaction that produced them has
     * committed (and, critically, once EAC has written their EmailMessageRelation rows).
     *
     * @param messageIds EmailMessage Ids from the firing trigger context; both services
     *                   treat null/empty as a no-op, so no guard is needed here.
     */
    public EmailCaptureQueueable(Set<Id> messageIds) {
        this.messageIds = messageIds;
    }

    /**
     * Builds the shared anchor index, adopts, then guards. See the class header for why
     * the order and the asymmetric error handling are both load-bearing.
     *
     * ⚠ The `catch (Exception)` around the adopter is intentionally broad and
     * intentionally silent-but-logged. It is a BLAST-RADIUS boundary, not error
     * recovery: whatever the adopter fails on, the guard's deployed behaviour must still
     * run. PMD's `AvoidDebugStatements` / broad-catch findings here are accepted on the
     * same grounds recorded in EmailThreadGuardService.purge — this repo has no logging
     * framework and this is an error path, not main-path instrumentation.
     *
     * @param context Platform-supplied queueable context; unused.
     */
    public void execute(QueueableContext context) {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        EmailThreadAnchorService.AnchorIndex anchors =
            EmailThreadAnchorService.index(messageIds);
        try {
            EmailThreadAdopterService.run(messageIds, anchors);
        } catch (Exception adoptionFailure) {
            System.debug(LoggingLevel.ERROR,
                'EAC adopter failed; guard still runs: ' + adoptionFailure);
        }
        EmailThreadGuardService.run(messageIds, anchors);

        lastRunQueryCount = Limits.getQueries() - queriesBefore;
        lastRunDmlStatements = Limits.getDmlStatements() - dmlBefore;
    }
}
