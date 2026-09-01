/**
 * Backs the Disposition closing workspace LWCs. Reads the closing-summary tile and
 * find-or-creates the Disposition a Property Asset's closing workflow hangs off.
 *
 * ⚠ TWO CREATE ENTRY POINTS SINCE 2026-08-19 AND THEY ARE NOT THE SAME BUTTON.
 * `findOrCreate` is the ORIGINAL Sell Meter row action (record type fixed to On_Market, no
 * approval); `initiateAndSubmit` is the flow-redesign modal (`c/sellMeterInitiateModal`) where the
 * user CHOOSES the record type and the create is auto-submitted into `Sale_Decision_Approval`.
 * Both are live — `findOrCreate` has other callers and is explicitly out of the redesign's scope —
 * so do not "consolidate" them; their RETURN CONTRACTS differ (an Id vs. a three-field outcome)
 * and that difference is the feature.
 *
 * All SOQL is delegated to DispositionSelector per ARCHITECTURE.md §2 — this controller
 * holds no inline SOQL.
 *
 * Thin controller (P6 controller thinning). The find-or-create DML lives in
 * DispositionService per .claude/rules/apex-layering-rule.md; findOrCreate() only
 * marshals input, delegates, and maps failures to an AuraHandledException at the LWC
 * boundary (ARCHITECTURE.md §5). Every @AuraEnabled method (read and write) maps failures
 * the same way: platform detail goes to the debug log (admin-only) and the user gets a
 * fixed, generic user-safe message with no exception detail concatenated into it.
 */
public with sharing class DispositionController {

    // Fixed, generic user-safe message for a failed write. Never interpolate platform text
    // or exception detail into it (ARCHITECTURE.md §5) — the raw DmlException text leaks
    // field API names and validation-rule internals. The detail goes to the debug log
    // (admin-only); the user gets this. The controller owns it because the
    // AuraHandledException boundary is here, not in the service.
    private static final String WRITE_FAILURE_MESSAGE =
        'This change could not be saved. Refresh the page and try again, or contact your administrator.';
    // Fixed, generic user-safe message for a failed read (a query-time or shaping failure).
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    public class DispositionRow {
        @AuraEnabled public String id;
        @AuraEnabled public String assetName;
        @AuraEnabled public String stage;
        @AuraEnabled public Boolean psaExecuted;
        @AuraEnabled public String titleCompany;
        @AuraEnabled public Boolean closingStatementUploaded;
        @AuraEnabled public Boolean wireCreated;
    }

    /**
     * Find-or-create the Disposition for a Property Asset (Sell Meter Initiate / Override).
     *
     * ⚠ THE TWO CATCHES ARE NOT INTERCHANGEABLE AND THE ORDER IS LOAD-BEARING.
     * SellMeterGateException is a DESIGNED REFUSAL — the asset's peak sell date bands RED,
     * which is a permanent business answer with a message authored in
     * DispositionService specifically to be shown to a user. It is rethrown VERBATIM.
     * Everything else is a PLATFORM FAILURE whose text leaks field API names and
     * validation-rule internals, so it is masked behind the fixed generic message.
     *
     * Delete the first catch and a deliberate refusal reaches the user as "This change
     * could not be saved. Refresh the page and try again" — advice that can never work,
     * because refreshing will refuse identically forever. Apex requires the subclass catch
     * above `catch (Exception e)`; the generic catch must stay beneath it, not be replaced
     * by it.
     *
     * ⚠ THERE ARE **THREE** CATCHES SINCE 2026-08-31 AND THE PARAGRAPH ABOVE NOW DESCRIBES TWO OF
     * THEM. `SellMeterOverridePermissionService.AccessDeniedException` (item 5a — a non-principal
     * reaching the YELLOW branch) is the second DESIGNED refusal and is rethrown verbatim for
     * exactly the reason above. The two designed catches are siblings, not a chain: their relative
     * order is free, and only their position ABOVE the generic catch is required.
     */
    @AuraEnabled(cacheable=false)
    public static String findOrCreate(Id assetId) {
        try {
            return DispositionService.findOrCreate(assetId);
        } catch (DispositionService.SellMeterGateException e) {
            // Designed refusal: INFO, not ERROR — nothing failed, the answer is "no".
            System.debug(LoggingLevel.INFO, 'DispositionController.findOrCreate refused on '
                + assetId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (SellMeterOverridePermissionService.AccessDeniedException e) {
            // 🔴 A THIRD CATCH, ADDED 2026-08-31 (item 5a), AND IT IS NOT DECORATION.
            // `findOrCreate` is a LIVE, still-exposed @AuraEnabled create path with no modal and no
            // confirmation, so it is the second way to reach a YELLOW creation. Without this catch
            // a non-principal's refusal would fall into the generic catch below and be reported as
            // "This change could not be saved. Refresh the page and try again" — advice that can
            // never work, exactly the failure the SellMeterGateException catch above exists to
            // prevent, on the exact same button.
            // Same shape, same reason: a DESIGNED refusal with an authored, user-safe message,
            // rethrown VERBATIM, logged at INFO because nothing failed.
            System.debug(LoggingLevel.INFO, 'DispositionController.findOrCreate override-refused on '
                + assetId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionController.findOrCreate on ' + assetId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    /**
     * Create a Disposition at the caller's chosen record type and submit it into
     * `Sale_Decision_Approval` — the server half of the Sell Meter "Initiate" modal
     * (`c/sellMeterInitiateModal`, DEV-11).
     *
     * ⚠ THE TWO CATCHES ARE THE SAME TWO `findOrCreate` HAS, IN THE SAME ORDER, FOR THE SAME
     * REASON — read that method's header for the full argument. SellMeterGateException is a
     * DESIGNED REFUSAL with an authored message and is rethrown VERBATIM; everything else is a
     * platform failure whose text leaks field API names and validation-rule internals and is masked
     * behind the fixed generic message.
     *
     * 🔴 A FAILED APPROVAL SUBMISSION IS NOT AN EXCEPTION AND MUST NOT BECOME ONE HERE. It arrives
     * as `outcome.submitted = false` with `outcome.dispositionId` populated, and the client's
     * contract is to toast `outcome.message` as a WARNING and STILL NAVIGATE. Turning that into a
     * thrown error would tell the user nothing was created about a record that exists — see
     * `DispositionService.submitSaleDecision`.
     *
     * ⚠ `InvalidRecordTypeException` DELIBERATELY FALLS INTO THE GENERIC CATCH. It is a caller
     * defect (the modal's radio group is mandatory and offers exactly the two allowed values), not
     * something the user can act on, so it is masked rather than surfaced. The service's own
     * declaration carries the argument.
     *
     * ⚠ THREE CATCHES SINCE 2026-08-31, NOT TWO, AND THE THIRD IS A SECOND DESIGNED REFUSAL RATHER
     * THAN A SECOND PLATFORM MASK. `SellMeterOverridePermissionService.AccessDeniedException` is
     * raised when a non-principal reaches the YELLOW branch (item 5a). Its message is authored to
     * be shown and names WHO can perform the action, which is the only useful thing to say about a
     * button the user can SEE (the Sell Meter renders Override disabled rather than hiding it), so
     * it is rethrown verbatim alongside the sell-meter refusal. Letting it fall into the generic
     * catch would tell a principal-less analyst their save failed, and they would retry forever.
     *
     * ⚠ THIS CATCH IS REACHABLE AND IS COVERED BY A REAL DENIAL PERSONA — a `Minimum Access -
     * Salesforce` user under `System.runAs`, never the test-running administrator, because Modify
     * All Data bypasses the gate and would make the test pass through the SUCCESS path while
     * reading as a denial test. See DispositionControllerTest.
     *
     * @param assetId the Property_Asset__c to initiate against
     * @param recordTypeDeveloperName `On_Market` or `Off_Market`, chosen in the modal
     * @param overrideReason the principal's free-text override reason; null on the GREEN path,
     *        collected by `c/sellMeterOverrideModal` on the YELLOW one
     * @return the outcome: Disposition Id, whether it was submitted, and an authored message
     * @throws AuraHandledException carrying the RED-band refusal or the override denial verbatim,
     *         or the fixed generic write-failure message for anything else
     */
    @AuraEnabled(cacheable=false)
    public static DispositionService.InitiateOutcome initiateAndSubmit(
        Id assetId,
        String recordTypeDeveloperName,
        String overrideReason
    ) {
        try {
            return DispositionService.initiateAndSubmit(assetId, recordTypeDeveloperName, overrideReason);
        } catch (DispositionService.SellMeterGateException e) {
            // Designed refusal: INFO, not ERROR — nothing failed, the answer is "no".
            System.debug(LoggingLevel.INFO, 'DispositionController.initiateAndSubmit refused on '
                + assetId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (SellMeterOverridePermissionService.AccessDeniedException e) {
            // The second DESIGNED refusal on this path (2026-08-31, item 5a) — see the header.
            // ⚠ The override reason is deliberately NOT logged here. It is free text a user typed
            // and the debug log is a different audience from the record it was destined for.
            System.debug(LoggingLevel.INFO, 'DispositionController.initiateAndSubmit override-refused on '
                + assetId + ': ' + e.getMessage());
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionController.initiateAndSubmit on ' + assetId
                + ' (' + recordTypeDeveloperName + '): ' + e.getMessage() + ' | '
                + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled(cacheable=true)
    public static DispositionRow getClosingSummary(Id dispositionId) {
        try {
            Disposition__c d = DispositionSelector.selectClosingSummaryById(dispositionId);
            DispositionRow row = new DispositionRow();
            row.id = d.Id;
            row.assetName = d.Property_Asset__r != null ? d.Property_Asset__r.Name : '';
            row.stage = d.Disposition_Stage__c;
            row.psaExecuted = d.PSA_Executed__c;
            row.titleCompany = d.Title_Company__c;
            row.closingStatementUploaded = d.Closing_Statement_Uploaded__c;
            row.wireCreated = !d.Wires__r.isEmpty();
            return row;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionController.getClosingSummary on ' + dispositionId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
