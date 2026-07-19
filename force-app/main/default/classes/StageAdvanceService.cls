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
 * LAYERING NOTE: the Underwriting branch delegates to
 * OpportunityApprovalController.submitForApproval — a pre-existing collaborator relocated
 * unchanged from the controller. submitForApproval is functionally an approval-submission
 * service exposed under a *Controller name for historical reasons; it is out of P6 scope
 * to rename, and re-homing its call here (rather than leaving SOQL + branching business
 * logic in the thinned controller) is the lesser layering compromise. Its AuraHandledException
 * messages are already user-safe and are allowed to propagate through unchanged.
 *
 * @see force-app/main/default/classes/StageAdvanceController.cls (thin caller)
 * @see force-app/main/default/classes/OpportunitySelector.cls (all SOQL)
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

    // Current stage -> the single primary next stage. Underwriting is absent because
    // that step is an approval submission, not a stage write.
    private static final Map<String, String> NEXT_STAGE = new Map<String, String>{
        'New' => 'Under Review',
        'Under Review' => 'Underwriting',
        'Development Review' => 'Underwriting',
        'Construction Review' => 'Underwriting',
        'LOI' => 'PSA',
        'PSA' => 'Closed Won',
        'About to Close' => 'Closed Won'
    };

    /**
     * Moves the deal to the single primary next stage for its current stage, or — from
     * Underwriting — submits it into the principal LOI approval.
     *
     * @param recordId the Opportunity to advance (required)
     * @return a user-facing confirmation message
     * @throws StageAdvanceException when recordId is null, there is no next step, or the
     *         stage write is blocked (the block's message is surfaced)
     * @throws System.QueryException when recordId matches no Opportunity
     * @throws AuraHandledException  propagated unchanged from the approval submission
     */
    public static String advance(Id recordId) {
        Opportunity o = load(recordId);
        if (o.StageName == 'Underwriting') {
            // Gated by principal approval - submit into the approval process.
            return OpportunityApprovalController.submitForApproval(recordId);
        }
        String target = NEXT_STAGE.get(o.StageName);
        if (target == null) {
            throw new StageAdvanceException(
                'There is no next step available from the ' + o.StageName + ' stage.');
        }
        return setStage(o, target);
    }

    /**
     * Moves the deal to an explicit target stage (the branch actions off Under Review:
     * Send to Development / Construction Review).
     *
     * @param recordId the Opportunity to advance (required)
     * @param target   the explicit target StageName (required, non-blank)
     * @return a user-facing confirmation message
     * @throws StageAdvanceException when target is blank, recordId is null, or the stage
     *         write is blocked (the block's message is surfaced)
     * @throws System.QueryException when recordId matches no Opportunity
     */
    public static String advanceTo(Id recordId, String target) {
        if (String.isBlank(target)) {
            throw new StageAdvanceException('No target stage was provided.');
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
