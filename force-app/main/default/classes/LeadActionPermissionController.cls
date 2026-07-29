/**
 * LeadActionPermissionController — thin @AuraEnabled boundary that tells the Lead stage quick
 * actions whether the running user is allowed to run them.
 *
 * Consumed by the shared c/leadStatusChange util, which every Lead quick action bundle
 * (leadConvertAction, leadMarkUnderReview, leadMarkQualified, leadDisqualify) calls before it does
 * any work. All logic lives in LeadActionPermissionService (ARCHITECTURE.md §2 /
 * .claude/rules/apex-layering-rule.md); this class only delegates and maps failure to a user-safe
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). It mirrors the P6 thin-controller
 * precedent (StageAdvanceController / LeadConvertActionController), including the `ahe()` helper.
 *
 * ── WHY cacheable=true ────────────────────────────────────────────────────────
 * The method performs no DML and its answer cannot change within a user's session without a
 * permission change (which forces a session refresh anyway). `cacheable=true` lets the platform
 * serve the four quick actions on a Lead page from ONE server round trip and lets the LWCs call it
 * imperatively on every click without any client-side memoization of their own.
 *
 * ── WHY IT RETURNS A BOOLEAN INSTEAD OF THROWING ──────────────────────────────
 * This is a QUESTION, not an action. Returning false lets the caller render a denial message
 * itself; throwing would force every caller into a catch block for the ordinary "not allowed"
 * case. The corresponding ASSERTION (which does throw) lives on the service and is used by
 * LeadConvertActionController, where a denial must actually stop work.
 *
 * ── CLASS ACCESS ──────────────────────────────────────────────────────────────
 * This controller is granted in DPEG_Apex_Access (the broad Apex-invoke set every persona holds)
 * rather than only in the Lead permission sets. That is deliberate: a user WITHOUT Lead access must
 * still be able to reach this method so it can honestly answer `false`. If class access were
 * limited to the Lead sets, an unauthorized user's call would fail with an Apex access error rather
 * than a clean denial — the LWC treats both as "denied", but the error path produces a worse
 * message and hides genuine faults.
 *
 * @see force-app/main/default/classes/LeadActionPermissionService.cls (all logic)
 * @see force-app/main/default/lwc/leadStatusChange/leadStatusChange.js (sole consumer)
 */
public with sharing class LeadActionPermissionController {

    // Fixed, generic user-safe message for an unexpected failure of the permission lookup itself
    // (e.g. a setup-object access failure under WITH USER_MODE). Never interpolate platform text
    // into it (ARCHITECTURE.md §5).
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
     * Whether the running user may drive the Lead stage quick actions (Convert, Mark Under Review,
     * Mark Qualified, Disqualify).
     *
     * @return true when the user holds Lead_Stage_Actions_Access or Broker_Protection_Access —
     *         directly or through a permission set group — or has "Modify All Data"; false
     *         otherwise.
     * @throws AuraHandledException with a fixed generic message when the permission lookup itself
     *         fails unexpectedly. The LWC treats a thrown check exactly like `false`, so the gate
     *         fails CLOSED.
     * @example
     * const allowed = await hasLeadActionAccess();
     */
    @AuraEnabled(cacheable=true)
    public static Boolean hasLeadActionAccess() {
        try {
            return LeadActionPermissionService.hasLeadActionAccess();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeadActionPermissionController.hasLeadActionAccess: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(CHECK_FAILURE_MESSAGE);   // unexpected/system errors: masked message, stack logged
        }
    }
}
