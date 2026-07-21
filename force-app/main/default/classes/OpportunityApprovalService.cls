/**
 * Service behind the custom "Submit for Approval" quick action. Backs
 * OpportunityApprovalController, and is called by StageAdvanceService for the
 * Underwriting -> LOI approval hand-off.
 *
 * Owns the approval-submission ORCHESTRATION extracted from OpportunityApprovalController
 * in the controller-thinning fix (code-review W3): resolving the parent deal from the
 * clicked record (LOI / Underwriting / Contract Review pass through their parent), the
 * duplicate-pending gate, the Approval.process submission, and the stage-based
 * "no applicable process" error derivation. Per .claude/rules/apex-layering-rule.md and
 * ARCHITECTURE.md §2 this orchestration is Service work, not Controller work.
 *
 * The approval processes live on the Opportunity, so a submission from a child record
 * resolves its parent deal first, then submits it — the process whose entry criteria the
 * deal meets (Underwriting_Approval at Stage = Underwriting, LOI_Approval at Stage = LOI)
 * picks it up.
 *
 * All SOQL is delegated to selectors (ProcessInstanceSelector / OpportunitySelector /
 * LoiSelector / UnderwritingSelector / ContractReviewSelector) — this service holds no
 * inline SOQL.
 *
 * EXCEPTION CONTRACT (code-review W2 — no raw platform text may reach the user):
 *   - A user-actionable rule violation throws a TYPED {@link ApprovalException} whose
 *     message is safe to surface verbatim (no record, not linked to a deal, already
 *     pending, unsupported object, or a stage that meets no approval entry criteria).
 *   - An UNEXPECTED failure (a QueryException from a missing/inaccessible record, or a
 *     genuine Approval.process / platform error at an otherwise-eligible stage) is left to
 *     propagate RAW. This service NEVER throws AuraHandledException — the caller
 *     (controller) maps the raw failure to a fixed, generic, user-safe message so the raw
 *     platform text is not leaked (ARCHITECTURE.md §5).
 *
 * @see force-app/main/default/classes/OpportunityApprovalController.cls (thin caller)
 * @see force-app/main/default/classes/StageAdvanceService.cls (Underwriting -> LOI hand-off)
 */
public with sharing class OpportunityApprovalService {

    private static final String STAGE_UNDERWRITING = 'Underwriting';
    private static final String STAGE_LOI = 'LOI';

    /**
     * Raised when a submission cannot proceed and the reason is user-actionable and safe to
     * surface verbatim: no record supplied, the record is not linked to a deal, a submission
     * is already pending, the object type is unsupported, or the deal's stage meets no
     * approval entry criteria. An UNEXPECTED failure is deliberately NOT wrapped in this type
     * — it propagates raw for the caller to mask with a fixed generic message.
     */
    public class ApprovalException extends Exception {}

    /**
     * Submits the deal behind a clicked record into whichever approval process its stage
     * matches (Underwriting_Approval at Stage = Underwriting, LOI_Approval at Stage = LOI).
     *
     * @param recordId the clicked record: an Opportunity, or an LOI / Underwriting /
     *                 Contract Review child that resolves to its parent deal.
     * @return a user-facing confirmation message.
     * @throws ApprovalException for a user-actionable rule violation (message safe to
     *                 surface verbatim).
     * @throws System.QueryException / platform Exception on an unexpected failure (the
     *                 caller masks it with a fixed generic message).
     */
    public static String submitForApproval(Id recordId) {
        if (recordId == null) {
            throw new ApprovalException('No record was provided.');
        }
        Id dealId = resolveDealId(recordId);
        if (dealId == null) {
            throw new ApprovalException('This record is not linked to a deal (Opportunity) yet.');
        }
        // Block a duplicate submission while one is already pending.
        if (!ProcessInstanceSelector.selectPendingByTargetId(dealId).isEmpty()) {
            throw new ApprovalException('This deal is already pending approval.');
        }
        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(dealId);
            Approval.process(req);
            return 'The deal has been submitted for approval.';
        } catch (Exception e) {
            // Turn the raw NO_APPLICABLE_PROCESS into a reason the submitter can act on. The
            // two processes run at the Underwriting and LOI stages; anything else meets no
            // entry criteria -> a user-actionable ApprovalException (surfaced verbatim).
            Opportunity deal = OpportunitySelector.selectStageRequiredById(dealId);
            if (deal.StageName != STAGE_UNDERWRITING && deal.StageName != STAGE_LOI) {
                throw new ApprovalException('No approval applies at the ' + deal.StageName +
                    ' stage - principal approval runs at Underwriting, LOI approval at LOI.');
            }
            // At an eligible stage the process should apply; a failure here is unexpected.
            // Propagate raw so the controller masks it with a fixed generic message rather
            // than leaking platform approval text to the user (code-review W2). Defensive:
            // not reachable in normal operation — the pending-gate above prevents
            // ALREADY_IN_PROCESS and an eligible stage always matches its process.
            throw e;
        }
    }

    /** The Opportunity behind the clicked record (LOI / Underwriting / Contract Review pass through their parent). */
    private static Id resolveDealId(Id recordId) {
        String objectName = recordId.getSobjectType().getDescribe().getName();
        if (objectName == 'Opportunity') {
            return recordId;
        }
        if (objectName == 'LOI__c') {
            return LoiSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c;
        }
        if (objectName == 'Underwriting__c') {
            return UnderwritingSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c;
        }
        if (objectName == 'Contract_Review__c') {
            return ContractReviewSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c;
        }
        throw new ApprovalException('Submit for Approval is not available on ' + objectName + '.');
    }
}
