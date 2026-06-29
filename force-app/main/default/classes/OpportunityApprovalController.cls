/**
 * Backs the custom "Submit for Approval" quick action on the Opportunity.
 * Submits the deal into the LOI approval process from a single click, so we don't
 * depend on Lightning's dynamic native Submit-for-Approval action (which doesn't
 * render reliably). Mirrors the process rules: submission only succeeds when the
 * record meets an active approval process's entry criteria (Stage = LOI Under Approval).
 */
public with sharing class OpportunityApprovalController {

    @AuraEnabled
    public static String submitForApproval(Id recordId) {
        if (recordId == null) {
            throw ahe('No record was provided.');
        }
        // Block a duplicate submission while one is already pending.
        if (![SELECT Id FROM ProcessInstance
              WHERE TargetObjectId = :recordId AND Status = 'Pending'].isEmpty()) {
            throw ahe('This deal is already pending approval.');
        }
        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(recordId);
            Approval.process(req);
            return 'The deal has been submitted for LOI approval.';
        } catch (Exception e) {
            // Most common: "No applicable approval process was found" when the deal
            // is not at the LOI Under Approval stage.
            throw ahe(e.getMessage());
        }
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}