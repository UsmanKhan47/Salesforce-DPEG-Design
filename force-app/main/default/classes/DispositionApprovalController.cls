/**
 * Backs the four DISPOSITION "Submit for Approval" quick actions (`c/dispositionSubmitForApproval`)
 * and the Select Offer screen action (`c/dispositionOfferSelect`). The sell-side twin of
 * OpportunityApprovalController, added 2026-08-19 with the disposition flow redesign (DEV-2).
 *
 * Thin controller (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md). All orchestration —
 * deriving WHICH approval a Submit click means, the entry-criteria pre-checks, the duplicate-pending
 * gate, the exclusivity write and the savepoint — lives in DispositionApprovalService. These two
 * methods only marshal input, delegate, and map failures to an AuraHandledException at the LWC
 * boundary (ARCHITECTURE.md §5).
 *
 * ── 🔴 THE THREE CATCHES, AND WHY THE ORDER IS LOAD-BEARING ─────────────────
 *   1. `AccessDeniedException`  — the running user is not a disposition driver. Surfaced VERBATIM,
 *      carrying the shared denial wording every gate in this org uses. Ordered FIRST because a
 *      denial falling through to the generic clause would be masked as "could not be submitted…
 *      contact your administrator", which hides the actual reason and sends the user to the wrong
 *      person.
 *   2. `ApprovalException`      — a user-actionable rule violation (no Selected broker, wire not
 *      verified, wrong stage, already pending) or a validation rule's own message. Surfaced
 *      VERBATIM: every one of these strings was authored to be read by a user, and the whole point
 *      of the pre-checks in the service is that this message reaches them instead of the platform's
 *      "no applicable approval process was found".
 *   3. `Exception`              — anything unexpected. Masked behind a FIXED generic message with no
 *      exception detail concatenated into it, so raw Approval.process / platform text is never
 *      leaked (the OpportunityApprovalController contract, code-review W2).
 *
 * Apex requires each subclass catch above `catch (Exception e)`; the generic catch must stay
 * BENEATH them, never replace them. Delete catch 2 and every designed refusal in this feature —
 * including the authored wire-verification message that is the entire mitigation for
 * `Closing_Approval`'s new entry criterion — reaches the user as "refresh the page", advice that
 * can never work.
 *
 * ⚠ THE PERMISSION ASSERT IS NOT HERE. It is the FIRST STATEMENT OF EACH SERVICE METHOD, unlike
 * OpportunityApprovalController which asserts in the controller. That is deliberate: these service
 * methods are also reachable from Apex and Flow, and putting the gate at the service boundary means
 * a future caller cannot acquire the write path by skipping the controller. The catch clause here
 * exists to translate the resulting exception, not to perform the check.
 *
 * @see force-app/main/default/classes/DispositionApprovalService.cls (all logic)
 * @see force-app/main/default/classes/OpportunityApprovalController.cls (the acquisitions twin)
 */
public with sharing class DispositionApprovalController {

    // Fixed, generic user-safe message for an unexpected submission failure. Never interpolate
    // platform/exception text into it (ARCHITECTURE.md §5).
    private static final String SUBMIT_FAILURE_MESSAGE =
        'This could not be submitted for approval. Refresh the page or contact your administrator.';

    // Fixed, generic user-safe message for an unexpected offer-selection failure. Separate wording
    // from the submit one so a toast tells the reader WHICH action failed — two different fixes.
    private static final String SELECT_OFFER_FAILURE_MESSAGE =
        'The offer could not be selected. Refresh the page or contact your administrator.';

    /**
     * Submits whichever approval this disposition's stage and record type call for.
     *
     * @param dispositionId the Disposition__c the quick action was clicked on
     * @return an authored confirmation naming which approval was submitted
     * @throws AuraHandledException when the running user is not a disposition driver, when a
     *         user-actionable rule blocks the submission (its guidance is surfaced), or — with a
     *         fixed generic message — on an unexpected failure.
     */
    @AuraEnabled
    public static String submitForApproval(Id dispositionId) {
        try {
            return DispositionApprovalService.submitForApproval(dispositionId);
        } catch (DispositionActionPermissionService.AccessDeniedException e) {
            throw ahe(e.getMessage());
        } catch (DispositionApprovalService.ApprovalException e) {
            // User-actionable rule violation — surface the guidance verbatim.
            System.debug(LoggingLevel.INFO, 'DispositionApprovalController.submitForApproval '
                + 'refused on ' + dispositionId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionApprovalController.submitForApproval on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(SUBMIT_FAILURE_MESSAGE);
        }
    }

    /**
     * Selects the winning offer, advances the disposition to `Offer Selection`, and submits the
     * offer for approval — all or nothing (design D-3).
     *
     * @param dispositionId the Disposition__c the screen action was launched from
     * @param offerId       the Disposition_Offer__c chosen in the radio list
     * @return an authored confirmation
     * @throws AuraHandledException as above; a blocked stage advance surfaces the validation rule's
     *         own message, which is the only thing that identifies the gate.
     */
    @AuraEnabled
    public static String selectOffer(Id dispositionId, Id offerId) {
        try {
            return DispositionApprovalService.selectOffer(dispositionId, offerId);
        } catch (DispositionActionPermissionService.AccessDeniedException e) {
            throw ahe(e.getMessage());
        } catch (DispositionApprovalService.ApprovalException e) {
            System.debug(LoggingLevel.INFO, 'DispositionApprovalController.selectOffer refused on '
                + dispositionId + '/' + offerId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionApprovalController.selectOffer on '
                + dispositionId + '/' + offerId + ': ' + e.getMessage() + ' | '
                + e.getStackTraceString());
            throw ahe(SELECT_OFFER_FAILURE_MESSAGE);
        }
    }

    /**
     * ⚠ `setMessage` AS WELL AS THE CONSTRUCTOR. An AuraHandledException built from the constructor
     * alone surfaces "Script-thrown exception" to the client on some paths; setting the message
     * explicitly is what makes the authored text actually arrive. Same helper, same reason, as
     * every other controller in this repo.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}
