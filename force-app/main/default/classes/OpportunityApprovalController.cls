/**
 * Backs the custom "Submit for Approval" quick action on the LOI, Underwriting,
 * and Contract Review record pages (and works on the Opportunity itself). The
 * approval processes live on the Opportunity, so a submission from a child
 * record resolves its parent deal first, then submits it - the process whose
 * entry criteria the deal meets (Underwriting_Approval at Stage = Underwriting,
 * LOI_Approval at Stage = LOI) picks it up. A custom action because
 * Lightning's dynamic native Submit-for-Approval doesn't render reliably.
 */
public with sharing class OpportunityApprovalController {

    @AuraEnabled
    public static String submitForApproval(Id recordId) {
        if (recordId == null) {
            throw ahe('No record was provided.');
        }
        Id dealId = resolveDealId(recordId);
        if (dealId == null) {
            throw ahe('This record is not linked to a deal (Opportunity) yet.');
        }
        // Block a duplicate submission while one is already pending.
        if (![SELECT Id FROM ProcessInstance
              WHERE TargetObjectId = :dealId AND Status = 'Pending'].isEmpty()) {
            throw ahe('This deal is already pending approval.');
        }
        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(dealId);
            Approval.process(req);
            return 'The deal has been submitted for approval.';
        } catch (Exception e) {
            // Most common: "No applicable approval process was found" when the deal
            // is at a stage no active process covers.
            throw ahe(e.getMessage());
        }
    }

    /** The Opportunity behind the clicked record (LOI / Underwriting / Contract Review pass through their parent). */
    private static Id resolveDealId(Id recordId) {
        String objectName = recordId.getSobjectType().getDescribe().getName();
        if (objectName == 'Opportunity') {
            return recordId;
        }
        if (objectName == 'LOI__c') {
            return [SELECT Opportunity__c FROM LOI__c WHERE Id = :recordId LIMIT 1].Opportunity__c;
        }
        if (objectName == 'Underwriting__c') {
            return [SELECT Opportunity__c FROM Underwriting__c WHERE Id = :recordId LIMIT 1].Opportunity__c;
        }
        if (objectName == 'Contract_Review__c') {
            return [SELECT Opportunity__c FROM Contract_Review__c WHERE Id = :recordId LIMIT 1].Opportunity__c;
        }
        throw ahe('Submit for Approval is not available on ' + objectName + '.');
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}