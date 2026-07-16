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
        if (!ProcessInstanceSelector.selectPendingByTargetId(dealId).isEmpty()) {
            throw ahe('This deal is already pending approval.');
        }
        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(dealId);
            Approval.process(req);
            return 'The deal has been submitted for approval.';
        } catch (Exception e) {
            // Turn the raw NO_APPLICABLE_PROCESS into a reason the submitter can act
            // on. The two processes run at the Underwriting and LOI stages; anything
            // else meets no entry criteria.
            Opportunity deal = OpportunitySelector.selectStageRequiredById(dealId);
            if (deal.StageName != 'Underwriting' && deal.StageName != 'LOI') {
                throw ahe('No approval applies at the ' + deal.StageName +
                    ' stage - principal approval runs at Underwriting, LOI approval at LOI.');
            }
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
            return LoiSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c;
        }
        if (objectName == 'Underwriting__c') {
            return UnderwritingSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c;
        }
        if (objectName == 'Contract_Review__c') {
            return ContractReviewSelector.selectOpportunityIdRequiredById(recordId).Opportunity__c;
        }
        throw ahe('Submit for Approval is not available on ' + objectName + '.');
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}