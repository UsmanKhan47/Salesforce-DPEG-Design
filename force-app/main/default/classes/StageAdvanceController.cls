/**
 * Backs the per-stage "advance" quick actions on the Opportunity. Each button is shown
 * only on its source stage via Dynamic Actions on the Highlights Panel.
 *
 *   advance(recordId)          - moves the deal to the single "primary" next stage for
 *                                its current stage (Begin Review, Initiate Underwriting,
 *                                Advance to PSA, Close Deal), or, from Underwriting,
 *                                submits it into the principal LOI approval.
 *   advanceTo(recordId, stage) - moves the deal to an explicit target stage, used for the
 *                                branch actions off Under Review (Send to Development /
 *                                Construction Review).
 *
 * Thin controller (P6 controller thinning). The stage-routing map, the stage write, and
 * the approval hand-off live in StageAdvanceService per .claude/rules/apex-layering-rule.md
 * and ARCHITECTURE.md §2; each @AuraEnabled method only marshals input, delegates, and maps
 * failures to an AuraHandledException at the LWC boundary (ARCHITECTURE.md §5).
 *
 * Gates preserved: Under Review -> Underwriting hits the signed-NDA validation rule and
 * its message is surfaced (via StageAdvanceException); Underwriting -> LOI goes through the
 * approval process (StageAdvanceService -> OpportunityApprovalService), whose user-actionable
 * messages the service re-wraps as a StageAdvanceException so they surface verbatim here. An
 * unexpected failure (e.g. a missing/inaccessible Opportunity, or an unexpected approval
 * failure) maps to a fixed, generic message with no exception detail concatenated into it.
 */
public with sharing class StageAdvanceController {

    // Fixed, generic user-safe message for an unexpected failure (e.g. the deal could not
    // be loaded). Never interpolate platform text into it (ARCHITECTURE.md §5).
    private static final String READ_FAILURE_MESSAGE =
        'This deal could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    @AuraEnabled
    public static String advance(Id recordId) {
        try {
            return StageAdvanceService.advance(recordId);
        } catch (StageAdvanceService.StageAdvanceException e) {
            // "No next step" / the surfaced signed-NDA validation message / a re-wrapped
            // user-actionable approval-submission message.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'StageAdvanceController.advance on ' + recordId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled
    public static String advanceTo(Id recordId, String target) {
        try {
            return StageAdvanceService.advanceTo(recordId, target);
        } catch (StageAdvanceService.StageAdvanceException e) {
            // Blank target / no record / the surfaced validation message.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'StageAdvanceController.advanceTo on ' + recordId
                + ' -> ' + target + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
