/**
 * Backs the per-stage "advance" quick actions on the Opportunity (Begin Review,
 * Initiate Underwriting, Initiate LOI, Advance to PSA, Close Deal). One shared
 * headless LWC (advanceDealStage) fires this for whichever button is showing;
 * the action is derived from the deal's CURRENT stage, and each button is made
 * visible only on its source stage via Dynamic Actions on the record page.
 *
 * Two transitions are deliberately NOT plain stage writes:
 *   - Under Review -> Underwriting is gated by the signed-NDA validation rule; a
 *     blocked save surfaces that rule's message to the user.
 *   - Underwriting -> LOI goes through the principal approval process (reusing
 *     OpportunityApprovalController.submitForApproval), so the deal only lands on
 *     LOI once the principals approve.
 */
public with sharing class StageAdvanceController {

    @AuraEnabled
    public static String advance(Id recordId) {
        if (recordId == null) {
            throw ahe('No record was provided.');
        }
        Opportunity o = [SELECT Id, StageName FROM Opportunity WHERE Id = :recordId LIMIT 1];
        switch on o.StageName {
            when 'New' {
                return setStage(o, 'Under Review', 'Deal moved to Under Review.');
            }
            when 'Under Review' {
                return setStage(o, 'Underwriting', 'Underwriting started.');
            }
            when 'Underwriting' {
                // Gated by principal approval - submit into the approval process
                // rather than writing the stage directly.
                return OpportunityApprovalController.submitForApproval(recordId);
            }
            when 'LOI' {
                return setStage(o, 'PSA', 'Deal advanced to PSA.');
            }
            when 'PSA' {
                return setStage(o, 'Closed Won', 'Deal marked Closed Won. Congratulations!');
            }
            when else {
                throw ahe('There is no next step available from the ' + o.StageName + ' stage.');
            }
        }
    }

    private static String setStage(Opportunity o, String target, String successMessage) {
        try {
            o.StageName = target;
            update o;
            return successMessage;
        } catch (DmlException e) {
            // e.g. the signed-NDA gate blocking entry into Underwriting.
            throw ahe(e.getDmlMessage(0));
        }
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}
