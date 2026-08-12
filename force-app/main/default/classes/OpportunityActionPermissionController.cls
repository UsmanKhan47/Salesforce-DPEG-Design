/**
 * OpportunityActionPermissionController — thin @AuraEnabled boundary that tells the Opportunity
 * stage quick actions whether the running user is allowed to run them.
 *
 * Consumed by the shared c/dealActionGuard util, which every Opportunity quick-action bundle
 * (advanceDealStage, dealSendToDevelopmentReview, dealSendToConstructionReview,
 * dealMoveToAboutToClose, submitForApproval) calls before it does any work. All logic lives in
 * OpportunityActionPermissionService (ARCHITECTURE.md §2 /
 * .claude/rules/apex-layering-rule.md); this class only delegates and maps failure to a user-safe
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). It mirrors
 * LeadActionPermissionController exactly, including the `ahe()` helper.
 *
 * ── WHY cacheable=true ────────────────────────────────────────────────────────
 * The method performs no DML and its answer cannot change within a user's session without a
 * permission or User-record change. `cacheable=true` lets the platform serve every quick action on
 * an Opportunity page from ONE server round trip and lets the LWCs call it imperatively on each
 * click without any client-side memoization of their own.
 *
 * ── WHY IT RETURNS A BOOLEAN INSTEAD OF THROWING ──────────────────────────────
 * This is a QUESTION, not an action. Returning false lets the caller render a denial message
 * itself; throwing would force every caller into a catch block for the ordinary "not allowed" case.
 * The corresponding ASSERTION (which does throw) lives on the service and is used by
 * StageAdvanceController and OpportunityApprovalController, where a denial must actually stop work.
 *
 * ── CLASS ACCESS ──────────────────────────────────────────────────────────────
 * Granted in DPEG_Apex_Access (the broad Apex-invoke set every persona holds) as well as in
 * DPEG_Acquisitions, rather than only in the deal-driver set. That is deliberate: a user who is NOT
 * a deal driver must still be able to reach this method so it can honestly answer `false`. If class
 * access were limited to the deal-driver personas, an unauthorized user's call would fail with an
 * Apex access error rather than a clean denial — the LWC treats both as "denied", but the error path
 * produces a worse message and hides genuine faults. Same rationale as
 * LeadActionPermissionController.
 *
 * @see force-app/main/default/classes/OpportunityActionPermissionService.cls (all logic)
 * @see force-app/main/default/lwc/dealActionGuard/dealActionGuard.js (sole consumer)
 */
public with sharing class OpportunityActionPermissionController {

    // Fixed, generic user-safe message for an unexpected failure of the permission lookup itself
    // (e.g. a setup-object access failure under WITH USER_MODE). Never interpolate platform text
    // into it (ARCHITECTURE.md §5). Note this is NOT the denial message — a denial returns false.
    private static final String CHECK_FAILURE_MESSAGE =
        'Unable to verify your permissions. Please try again or contact your administrator.';

    /**
     * Wraps a user-safe message in an AuraHandledException whose getMessage() the LWC can read.
     * Setting the message explicitly is required — the single-arg constructor alone leaves
     * getMessage() returning "Script-thrown exception" at the LWC boundary.
     */
    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * Whether the running user may drive the Opportunity stage quick actions (Begin Review, Send to
     * Development / Construction Review, Initiate Underwriting, Initiate LOI, Advance to PSA, Move
     * to About to Close, Close Deal, Submit for Approval).
     *
     * @return true when the user holds the `Acquisition_Deal_Actions` custom permission (granted by
     *         the `Acquisition_Deal_Driver` permission set), or has "Modify All Data"; false
     *         otherwise. ⚠ Until 2026-08-12 this read FLS on `User.Deal_Driver__c` AND that flag's
     *         value — both factors are retired; see the service's class header.
     * @throws AuraHandledException with a fixed generic message when the permission lookup itself
     *         fails unexpectedly. The LWC treats a thrown check exactly like `false`, so the gate
     *         fails CLOSED.
     * @example
     * const allowed = await hasDealActionAccess();
     */
    @AuraEnabled(cacheable=true)
    public static Boolean hasDealActionAccess() {
        try {
            return OpportunityActionPermissionService.hasDealActionAccess();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OpportunityActionPermissionController.hasDealActionAccess: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(CHECK_FAILURE_MESSAGE);   // unexpected/system errors: masked message, stack logged
        }
    }
}
