/**
 * Service for the per-stage "advance" quick actions on the Opportunity.
 *
 * Owns the business logic and DML behind StageAdvanceController (P6 controller thinning):
 * the current-stage -> next-stage routing map, the stage write, and the Underwriting-step
 * hand-off into the principal LOI approval. Per .claude/rules/apex-layering-rule.md and
 * ARCHITECTURE.md §2 this routing + DML is Service work, not Controller work — the
 * controller now only marshals input, delegates here, and maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5).
 *
 * All SOQL is delegated to OpportunitySelector — this service holds no inline SOQL.
 *
 * GATES PRESERVED (behaviour-preserving): Under Review -> Underwriting still hits the
 * signed-NDA validation rule, and the rule's message is surfaced to the submitter — the
 * DmlException is caught here and rethrown as a StageAdvanceException carrying
 * getDmlMessage(0), which the controller re-throws verbatim. Underwriting -> LOI still
 * goes through the approval process rather than a direct write.
 *
 * APPROVAL HAND-OFF: the Underwriting branch delegates to
 * OpportunityApprovalService.submitForApproval — the approval-submission service extracted
 * from OpportunityApprovalController in the code-review W3 controller-thinning fix. This
 * replaces the former service->controller call (StageAdvanceService -> the *Controller),
 * restoring correct layering (ARCHITECTURE.md §2). The service raises a typed
 * OpportunityApprovalService.ApprovalException for user-actionable reasons; this service
 * re-wraps it as a StageAdvanceException so its user-safe message is surfaced verbatim
 * through the controller's existing boundary (behaviour-preserving — the user sees the same
 * message). An unexpected raw failure is left to propagate to the controller's fixed generic
 * (masked) catch, so no raw platform text is leaked (code-review W2).
 *
 * EXPLICIT-TARGET ALLOW-LIST: `advanceTo` accepts only the branch/off-ramp stages listed in
 * ALLOWED_EXPLICIT_TARGETS. See that constant for the full rationale — in short, it used to write
 * any non-blank string it was handed, which let a direct @AuraEnabled call reach any stage and skip
 * every gate. This is a tightening only; no legitimate caller loses a transition.
 *
 * PERMISSION: the deal-driver check lives at the CONTROLLER boundary
 * (OpportunityActionPermissionService.assertDealActionAccess in StageAdvanceController), not here.
 * This service is also reached from OpportunityApprovalService's own entry point and from tests, and
 * a service that silently refuses work based on the running user is far harder to reason about than
 * one guarded at its public entry points.
 *
 * @see force-app/main/default/classes/StageAdvanceController.cls (thin caller + permission assert)
 * @see force-app/main/default/classes/OpportunityApprovalService.cls (approval submission)
 * @see force-app/main/default/classes/OpportunitySelector.cls (all SOQL)
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (the gate)
 */
public with sharing class StageAdvanceService {

    /**
     * Raised when a deal cannot advance and the reason is user-safe and surfaced
     * verbatim: no record / no target supplied, no next step from the current stage,
     * or a platform save block whose validation message is surfaced (the signed-NDA
     * gate). Distinct from an unexpected QueryException (missing/inaccessible record),
     * which the controller maps to a fixed generic message instead.
     */
    public class StageAdvanceException extends Exception {}

    /**
     * The ONLY stages `advanceTo` will write. This tightens a pre-existing loose coupling: the
     * method used to accept any non-blank string straight from an @AuraEnabled parameter and write
     * it, so any holder of StageAdvanceController access could move a deal to ANY stage — including
     * 'Closed Won' or 'Dead/Pass' — skipping every hop in NEXT_STAGE and the signed-NDA gate with
     * it. The declarative visibility rules that appear to constrain these buttons are a UX
     * affordance only and are trivially bypassed by calling the Apex directly.
     *
     * Membership is limited to the BRANCH-and-OFF-RAMP targets that legitimately have no single
     * derivable predecessor, which is the entire reason `advanceTo` exists alongside `advance`:
     *   - 'Development Review'  — the Land branch off Under Review (dealSendToDevelopmentReview)
     *   - 'Construction Review' — the Retail branch off Under Review (dealSendToConstructionReview)
     *   - 'About to Close'      — the optional 'Under Contract (PSA)' off-ramp
     *                             (dealMoveToAboutToClose)
     *   - 'Dead/Pass'           — pre-authorized for the deal off-ramp action (design doc D4). It is
     *                             a real stage in BOTH business processes and is reachable from any
     *                             active stage, so it can never be derived by NEXT_STAGE. Listed
     *                             here so the eventual button needs no service change; nothing calls
     *                             it with this value today.
     *
     * ⚠ Values are the DECODED runtime/API strings. 'Dead/Pass' is URL-encoded as 'Dead%2FPass' in
     * BusinessProcess/picklist METADATA only — an Apex literal (and a visibility rule's rightValue)
     * uses the decoded form. Getting this backwards yields a set that silently never matches.
     *
     * Forward hops that ARE derivable stay out of this set on purpose. They belong to `advance`,
     * which reaches them through NEXT_STAGE and therefore cannot skip a step: routing every
     * transition through an explicit target would re-open exactly the hole this set closes.
     *
     * ⚠ BEHAVIOUR CHANGE (strictly a tightening). Verified before landing: `advanceTo` has no Flow,
     * process, or Apex caller anywhere in the repo — its only callers are the three headless LWC
     * bundles, each passing a hardcoded constant from this set, plus the test classes. Adding a new
     * explicit-target action means adding its stage here.
     */
    private static final Set<String> ALLOWED_EXPLICIT_TARGETS = new Set<String>{
        'Development Review',
        'Construction Review',
        'About to Close',
        'Dead/Pass'
    };

    // Current stage -> the single primary next stage. Underwriting is absent because
    // that step is an approval submission, not a stage write.
    //
    // ⚠ 'Under Contract (PSA)' is the DECODED runtime StageName (renamed from 'PSA',
    // Acquisition Observations phase 2). It contains spaces and parentheses but no '/',
    // so — unlike 'Dead/Pass' -> 'Dead%2FPass' — NO %2F encoding applies anywhere. An
    // Apex literal, a picklist value and a visibility rule's rightValue all use this
    // exact form.
    //
    // 🔴 BOTH 'Under Contract (PSA)' AND 'About to Close' MAP TO 'Closed Won', AND THAT
    // PAIR IS LOAD-BEARING OUTSIDE THIS CLASS. PropertyAssetService.ensureOnClosedWon
    // lives on OpportunityReviewTrigger — rather than in the Transaction_Complete_Close
    // flow — precisely because of it: a deal driver can reach 'Closed Won' from EITHER
    // key, so half the closes carry no Transaction__c at all. Renaming one key without
    // the other silently re-opens that route-vs-state defect. Both moved together here.
    //
    // ⚠ DealFolderService WAS NAMED IN THIS PAIR UNTIL 2026-08-27 AND HAS BEEN REMOVED ON
    // PURPOSE. It now keys on ENTRY TO ANY OF FOUR CLAIM STAGES ('Under Review',
    // 'Underwriting', 'About to Close', 'Closed Won'), so which of the two keys above
    // reaches 'Closed Won' no longer decides whether it fires — an ordinary deal has
    // already claimed its folder at 'Under Review'. Do not re-add it here.
    // PropertyAssetService's dependency on this pair is UNCHANGED and is the entire
    // reason the paragraph above still exists.
    // ⚠ 'About to Close' IS still load-bearing for DealFolderService, but as a MEMBER OF
    // ITS CLAIM SET reached through advanceTo (which validates only the TARGET, never the
    // current stage) — a different dependency on a different mechanism. See
    // DealFolderService.CLAIM_STAGES.
    private static final Map<String, String> NEXT_STAGE = new Map<String, String>{
        'New' => 'Under Review',
        'Under Review' => 'Underwriting',
        'Development Review' => 'Underwriting',
        'Construction Review' => 'Underwriting',
        'LOI' => 'Under Contract (PSA)',
        'Under Contract (PSA)' => 'Closed Won',
        'About to Close' => 'Closed Won'
    };

    /**
     * Moves the deal to the single primary next stage for its current stage, or — from
     * Underwriting — submits it into the principal LOI approval.
     *
     * @param recordId the Opportunity to advance (required)
     * @return a user-facing confirmation message
     * @throws StageAdvanceException when recordId is null, there is no next step, the stage
     *         write is blocked (the block's message is surfaced), or the approval submission
     *         hits a user-actionable rule violation (its message is surfaced)
     * @throws System.QueryException when recordId matches no Opportunity
     */
    public static String advance(Id recordId) {
        Opportunity o = load(recordId);
        if (o.StageName == 'Underwriting') {
            // Gated by principal approval - submit into the approval process. The service
            // raises a typed ApprovalException for user-actionable reasons; re-wrap it as a
            // StageAdvanceException so its user-safe message is surfaced verbatim through the
            // controller boundary (behaviour-preserving). An unexpected raw failure propagates
            // to the controller's fixed generic (masked) catch.
            try {
                return OpportunityApprovalService.submitForApproval(recordId);
            } catch (OpportunityApprovalService.ApprovalException e) {
                throw new StageAdvanceException(e.getMessage());
            }
        }
        String target = NEXT_STAGE.get(o.StageName);
        if (target == null) {
            throw new StageAdvanceException(
                'There is no next step available from the ' + o.StageName + ' stage.');
        }
        return setStage(o, target);
    }

    /**
     * Moves the deal to an explicit target stage — the branch actions off Under Review (Send to
     * Development / Construction Review), the 'Under Contract (PSA)' off-ramp (Move to About to
     * Close), and the pre-authorized Dead/Pass off-ramp.
     *
     * The target is validated against ALLOWED_EXPLICIT_TARGETS BEFORE the record is loaded, so a
     * rejected target costs no query and reveals nothing about whether the record exists.
     *
     * @param recordId the Opportunity to advance (required)
     * @param target   the explicit target StageName (required, non-blank, and one of
     *                 ALLOWED_EXPLICIT_TARGETS)
     * @return a user-facing confirmation message
     * @throws StageAdvanceException when target is blank, target is not an allowed explicit target,
     *         recordId is null, or the stage write is blocked (the block's message is surfaced)
     * @throws System.QueryException when recordId matches no Opportunity
     * @example
     * String msg = StageAdvanceService.advanceTo(oppId, 'Development Review');
     */
    public static String advanceTo(Id recordId, String target) {
        if (String.isBlank(target)) {
            throw new StageAdvanceException('No target stage was provided.');
        }
        if (!ALLOWED_EXPLICIT_TARGETS.contains(target)) {
            // Fixed wording that does NOT echo the rejected value back to the user: a legitimate
            // caller can never reach this branch (every bundle passes a constant from the set), so
            // the only way to hit it is a hand-crafted call, and reflecting attacker-supplied text
            // into a toast has no upside.
            throw new StageAdvanceException(
                'That stage is not available from this action.');
        }
        return setStage(load(recordId), target);
    }

    private static Opportunity load(Id recordId) {
        if (recordId == null) {
            throw new StageAdvanceException('No record was provided.');
        }
        // Fetch-for-use: a missing Id throws System.QueryException (unchanged).
        return OpportunitySelector.selectStageRequiredById(recordId);
    }

    private static String setStage(Opportunity o, String target) {
        try {
            o.StageName = target;
            update o;
            return 'Deal moved to ' + target + '.';
        } catch (DmlException e) {
            // e.g. the signed-NDA gate, or a stage not valid for the deal's record type.
            // Surface the platform validation message to the submitter (behaviour-preserving).
            throw new StageAdvanceException(e.getDmlMessage(0));
        }
    }
}
