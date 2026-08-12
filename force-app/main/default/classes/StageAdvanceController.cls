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
 *
 * ── PERMISSION (server-side, first statement in every method) ──────────────────
 * Both methods open with OpportunityActionPermissionService.assertDealActionAccess(). Until this
 * existed the gate was purely the Dynamic Actions visibility rule on the Highlights Panel, which is
 * a UX AFFORDANCE ONLY — any user with Opportunity edit access and class access could call these
 * @AuraEnabled methods directly and drive a deal through every stage. The assert asks the exact
 * same question the visibility rules ask (`{!$Permission.CustomPermission.Acquisition_Deal_Actions}`
 * on the running user, with the documented "Modify All Data" bypass), so no user gains or loses
 * access; what changes is that the rule is now enforced rather than merely displayed.
 *
 * ⚠ THE TOKEN HAS THREE SEGMENTS — `$Permission.CustomPermission.<Name>`. The two-segment
 * `{!$Permission.<Name>}` and the alternative `{!$CustomPermission.<Name>}` were both REJECTED by
 * the Metadata API on 2026-08-12, so a rule copied from a shortened form fails the deploy.
 *
 * ⚠ THAT QUESTION WAS `{!$User.Deal_Driver__c} EQUAL true` UNTIL 2026-08-12. The flag model was
 * retired for both the rules and this assert IN THE SAME CHANGE, which is what keeps the two halves
 * asking one question — a flexipage rule that referenced a FIELD evaluated FALSE for anyone without
 * FLS on it, hiding the button with no error anywhere. A custom permission has no FLS.
 * `OpportunityActionPermissionService`'s header carries the measured incidents.
 *
 * The assert runs INSIDE the try with its own catch clause, ahead of the StageAdvanceException and
 * generic clauses. That ordering matters: an AccessDeniedException reaching the generic catch would
 * be masked as "This deal could not be loaded", telling the user to refresh the page over a
 * permissions problem. Its own clause surfaces the agreed denial wording instead.
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

    /**
     * Moves the deal to the primary next stage for its current stage, or — from Underwriting —
     * submits it into the principal LOI approval.
     *
     * @param recordId the Opportunity to advance
     * @return a user-facing confirmation message
     * @throws AuraHandledException when the running user is not a deal driver, when there is no next
     *         step, when a validation rule blocks the write (its message is surfaced), or — with a
     *         fixed generic message — on an unexpected failure.
     */
    @AuraEnabled
    public static String advance(Id recordId) {
        try {
            OpportunityActionPermissionService.assertDealActionAccess();
            return StageAdvanceService.advance(recordId);
        } catch (OpportunityActionPermissionService.AccessDeniedException e) {
            // Not a deal driver. Surface the agreed denial wording verbatim — identical to what the
            // LWC shows for the client-side gate, so one condition never produces two phrasings.
            throw ahe(e.getMessage());
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

    /**
     * Moves the deal to an explicit target stage — the branch actions off Under Review, the PSA
     * off-ramp, and the pre-authorized Dead/Pass off-ramp.
     *
     * @param recordId the Opportunity to advance
     * @param target   the explicit target StageName; must be one of
     *                 StageAdvanceService.ALLOWED_EXPLICIT_TARGETS
     * @return a user-facing confirmation message
     * @throws AuraHandledException when the running user is not a deal driver, when the target is
     *         blank or not an allowed explicit target, when a validation rule blocks the write, or —
     *         with a fixed generic message — on an unexpected failure.
     */
    @AuraEnabled
    public static String advanceTo(Id recordId, String target) {
        try {
            OpportunityActionPermissionService.assertDealActionAccess();
            return StageAdvanceService.advanceTo(recordId, target);
        } catch (OpportunityActionPermissionService.AccessDeniedException e) {
            // Not a deal driver — see advance() above.
            throw ahe(e.getMessage());
        } catch (StageAdvanceService.StageAdvanceException e) {
            // Blank target / target outside the allow-list / no record / the surfaced validation
            // message.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'StageAdvanceController.advanceTo on ' + recordId
                + ' -> ' + target + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
