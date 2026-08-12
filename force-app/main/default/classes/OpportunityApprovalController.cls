/**
 * Backs the custom "Submit for Approval" quick action on the LOI, Underwriting,
 * and Contract Review record pages (and works on the Opportunity itself). A custom
 * action because Lightning's dynamic native Submit-for-Approval doesn't render reliably.
 *
 * Thin controller (code-review W3 controller thinning). The approval-submission
 * orchestration — parent-deal resolution, the duplicate-pending gate, the Approval.process
 * submission, and the stage-based error derivation — lives in OpportunityApprovalService
 * per .claude/rules/apex-layering-rule.md and ARCHITECTURE.md §2. This method only marshals
 * input, delegates, and maps failures to an AuraHandledException at the LWC boundary
 * (ARCHITECTURE.md §5):
 *   - a user-actionable OpportunityApprovalService.ApprovalException is surfaced verbatim;
 *   - any other (unexpected) failure maps to a FIXED generic message with no exception
 *     detail concatenated into it, so raw Approval.process / platform text is no longer
 *     leaked to the user (code-review W2).
 *
 * ── PERMISSION (server-side, first statement in the method) ────────────────────
 * The method opens with OpportunityActionPermissionService.assertDealActionAccess(). Submitting a
 * deal into the principal approval is an acquisitions deal-driving action, gated by the
 * `Acquisition_Deal_Actions` custom permission — but until this existed the only gate was the
 * Dynamic Actions visibility rule, which any direct @AuraEnabled call bypasses. The assert asks the
 * same question the visibility rules ask, so no user gains or loses access.
 *
 * ⚠ THE GATE WAS `User.Deal_Driver__c` UNTIL 2026-08-12, and that field's DESCRIPTION was the thing
 * naming "Submit for Approval on Underwriting/LOI" as in scope. The field is retired (deleted in a
 * later phase) and nothing reads it, so that description is no longer authoritative for anything —
 * this header and the service's are. See OpportunityActionPermissionService for why the flag model
 * was retired.
 *
 * The AccessDeniedException clause is ordered ahead of the generic catch on purpose: a denial
 * falling through to the generic clause would be masked as "could not be submitted... contact your
 * administrator", which hides the actual reason.
 */
public with sharing class OpportunityApprovalController {

    // Fixed, generic user-safe message for an unexpected submission failure. Never
    // interpolate platform/exception text into it (ARCHITECTURE.md §5, code-review W2).
    private static final String SUBMIT_FAILURE_MESSAGE =
        'The deal could not be submitted for approval. Refresh the page or contact your administrator.';

    /**
     * Submits the deal (or the parent deal of an LOI / Underwriting / Contract Review record) into
     * the principal approval process.
     *
     * @param recordId the record whose parent deal is submitted
     * @return a user-facing confirmation message
     * @throws AuraHandledException when the running user is not a deal driver, when a user-actionable
     *         approval rule blocks the submission (its guidance is surfaced), or — with a fixed
     *         generic message — on an unexpected failure.
     */
    @AuraEnabled
    public static String submitForApproval(Id recordId) {
        try {
            OpportunityActionPermissionService.assertDealActionAccess();
            return OpportunityApprovalService.submitForApproval(recordId);
        } catch (OpportunityActionPermissionService.AccessDeniedException e) {
            // Not a deal driver. Surface the agreed denial wording verbatim — identical to what the
            // LWC shows for the client-side gate.
            throw ahe(e.getMessage());
        } catch (OpportunityApprovalService.ApprovalException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OpportunityApprovalController.submitForApproval on '
                + recordId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(SUBMIT_FAILURE_MESSAGE);
        }
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}
