/**
 * Backs the Disposition closing workspace LWCs. Reads the closing-summary tile and
 * find-or-creates the Disposition a Property Asset's closing workflow hangs off.
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DispositionController.findOrCreate on ' + assetId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
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
