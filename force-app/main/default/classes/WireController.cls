/**
 * Backs the disposition Wire (anti-fraud verification) LWC. Reads the current Wire's
 * verification state and saves edits to it.
 *
 * All SOQL is delegated to WireSelector per ARCHITECTURE.md §2 — this controller holds no
 * inline SOQL.
 *
 * Thin controller (P6 controller thinning). The upsert / stamp logic lives in WireService
 * per .claude/rules/apex-layering-rule.md; saveWire() only marshals input, delegates,
 * re-reads the saved row and shapes it into a view DTO, and maps failures to an
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5). Every @AuraEnabled method
 * (read and write) maps failures the same way: platform detail goes to the debug log
 * (admin-only) and the user gets a fixed, generic user-safe message.
 */
public with sharing class WireController {

    // Fixed, generic user-safe message for a failed write. Never interpolate platform text
    // or exception detail into it (ARCHITECTURE.md §5).
    private static final String WRITE_FAILURE_MESSAGE =
        'This wire could not be saved. Refresh the page and try again, or contact your administrator.';
    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    public class WireRow {
        @AuraEnabled public String id;
        @AuraEnabled public Boolean verbalVerificationCompleted;
        @AuraEnabled public String verifierName;
        @AuraEnabled public String verifierPhone;
        @AuraEnabled public String verifiedDateTime;
        @AuraEnabled public String wireInstructionsSource;
        @AuraEnabled public Decimal confirmedWireAmount;
        @AuraEnabled public Integer fieldsComplete;
    }

    // Shapes a Wire__c into the view DTO. Null-safe: a null Wire (no Wire yet for the
    // Disposition) maps to a null row, preserving getWire's original contract.
    private static WireRow buildRow(Wire__c w) {
        if (w == null) {
            return null;
        }
        WireRow r = new WireRow();
        r.id = w.Id;
        r.verbalVerificationCompleted = w.Verbal_Verification_Completed__c;
        r.verifierName = w.Verifier_Name__c;
        r.verifierPhone = w.Verifier_Phone__c;
        r.verifiedDateTime = w.Verified_DateTime__c != null
            ? String.valueOf(w.Verified_DateTime__c) : null;
        r.wireInstructionsSource = w.Wire_Instructions_Source__c;
        r.confirmedWireAmount = w.Confirmed_Wire_Amount__c;
        Integer done = 0;
        if (w.Verbal_Verification_Completed__c) done++;
        if (w.Verifier_Name__c != null) done++;
        if (w.Verifier_Phone__c != null) done++;
        if (w.Verified_DateTime__c != null) done++;
        if (w.Wire_Instructions_Source__c != null) done++;
        if (w.Confirmed_Wire_Amount__c != null) done++;
        r.fieldsComplete = done;
        return r;
    }

    @AuraEnabled(cacheable=true)
    public static WireRow getWire(Id dispositionId) {
        try {
            return buildRow(WireSelector.selectMostRecentByDispositionId(dispositionId));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'WireController.getWire on ' + dispositionId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled(cacheable=false)
    public static WireRow saveWire(Id dispositionId, String wireId,
            Boolean verbalDone, String verifierName, String verifierPhone,
            String wireSource, Decimal confirmedAmount) {
        try {
            WireService.saveWire(dispositionId, wireId, verbalDone, verifierName,
                verifierPhone, wireSource, confirmedAmount);
            // Re-read the most-recent Wire for the Disposition (the just-saved row) and
            // shape it, preserving saveWire's original "return getWire(dispositionId)" contract.
            return buildRow(WireSelector.selectMostRecentByDispositionId(dispositionId));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'WireController.saveWire on disposition ' + dispositionId
                + ', wire ' + wireId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
