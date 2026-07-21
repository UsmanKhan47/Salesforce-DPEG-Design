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
 */
public with sharing class OpportunityApprovalController {

    // Fixed, generic user-safe message for an unexpected submission failure. Never
    // interpolate platform/exception text into it (ARCHITECTURE.md §5, code-review W2).
    private static final String SUBMIT_FAILURE_MESSAGE =
        'The deal could not be submitted for approval. Refresh the page or contact your administrator.';

    @AuraEnabled
    public static String submitForApproval(Id recordId) {
        try {
            return OpportunityApprovalService.submitForApproval(recordId);
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
