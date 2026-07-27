/**
 * LeadConvertActionController — thin @AuraEnabled boundary for the custom "Convert" button on the
 * Lead record page (the leadStageActions LWC).
 *
 * Mirrors the P6 thin-controller precedent (StageAdvanceController), including its `ahe()` helper:
 * it only marshals the single recordId into the bulk service call, unwraps the index-aligned
 * result, and maps any failure to a user-safe AuraHandledException at the LWC boundary
 * (ARCHITECTURE.md §5). All conversion logic lives in LeadConvertActionService
 * (ARCHITECTURE.md §2 / .claude/rules/apex-layering-rule.md).
 *
 * The status-only Lead stage transitions (New -> Under Review -> Qualified, plus the Disqualified
 * off-ramp) are performed entirely client-side via LDS updateRecord in the LWC — they never reach
 * this controller. Only the irreversible Convert action needs Apex, because it runs
 * Database.convertLead.
 *
 * Failures are handled in two tiers, mirroring StageAdvanceController: a user-actionable convert
 * failure (a DmlException — e.g. a missing "Convert Leads" permission, a validation-rule block, or an
 * already-converted Lead) has its message surfaced verbatim (via `ahe`) so the user sees the real
 * reason; any other, unexpected/system error (e.g. an error deep in the trigger-driven
 * LeadConvertService) is logged and masked behind a fixed generic message with no platform text
 * concatenated into it (ARCHITECTURE.md §5). Not `cacheable`: this method performs DML.
 *
 * @see force-app/main/default/classes/LeadConvertActionService.cls (conversion logic)
 * @see force-app/main/default/classes/StageAdvanceController.cls (thin-controller precedent)
 */
public with sharing class LeadConvertActionController {

    // Fixed, generic user-safe message for an unexpected/system failure during conversion (e.g. an
    // error deep in the trigger-driven LeadConvertService). Never interpolate platform text into it
    // (ARCHITECTURE.md §5).
    private static final String CONVERT_FAILURE_MESSAGE =
        'Unable to convert this lead. Please try again or contact your administrator.';

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
     * Converts a single Qualified Lead and returns the new Opportunity's Id for the LWC to
     * navigate to. Delegates to LeadConvertActionService.convert (bulk-shaped) and unwraps the
     * single result.
     *
     * @param leadId the Lead to convert (the current record on the Lead page)
     * @return the Id of the Opportunity created by the conversion
     * @throws AuraHandledException carrying the verbatim failure message on a user-actionable
     *         DmlException (e.g. a missing "Convert Leads" permission, a validation-rule block, or an
     *         already-converted Lead), or a fixed generic message on any unexpected/system error
     */
    @AuraEnabled
    public static Id convertLead(Id leadId) {
        try {
            return LeadConvertActionService.convert(new List<Id>{ leadId })[0];
        } catch (DmlException e) {
            throw ahe(e.getMessage());   // user-safe convert failures (missing Convert Leads perm, validation, already-converted) surfaced verbatim
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeadConvertActionController.convertLead(' + leadId + '): '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(CONVERT_FAILURE_MESSAGE);   // unexpected/system errors: masked message, stack logged
        }
    }
}
