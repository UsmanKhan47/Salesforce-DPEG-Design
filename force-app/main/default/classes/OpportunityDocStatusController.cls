/**
 * Sidebar data provider for the Opportunity record page (the "Deal Summary" card):
 * returns NDA and LOI status, plus the latest related Development / Construction
 * feasibility review and Contract review for a deal. NDA/LOI use the designated
 * Primary_NDA__c / Primary_LOI__c when set, otherwise the most recent related record.
 *
 * All SOQL is delegated to the object selectors per ARCHITECTURE.md §2 — this
 * controller holds no inline SOQL. Read-only: there are no mutation methods here.
 *
 * Thin controller (P6 controller thinning — boundaries only, no DML to extract). The
 * single @AuraEnabled read wraps its work in a try/catch that maps a failure to a
 * user-safe AuraHandledException at the LWC boundary (ARCHITECTURE.md §5): platform
 * detail goes to the debug log (admin-only) and the user gets a fixed, generic message
 * with no exception detail concatenated into it.
 */
public with sharing class OpportunityDocStatusController {

    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'The deal summary could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    @AuraEnabled(cacheable=true)
    public static DocStatus getDocStatus(Id opportunityId) {
        try {
            DocStatus d = new DocStatus();
            if (opportunityId == null) {
                return d;
            }

            Opportunity opp = OpportunitySelector.selectPrimaryRefsById(opportunityId);

            // --- NDA: primary, else latest related ---
            NDA__c nda;
            if (opp.Primary_NDA__c != null) {
                nda = NdaSelector.selectById(opp.Primary_NDA__c);
            }
            if (nda == null) {
                nda = NdaSelector.selectLatestByOpportunityId(opportunityId);
            }
            if (nda != null) {
                d.hasNda = true;
                d.ndaId = nda.Id;
                d.ndaName = nda.Name;
                d.ndaStatus = nda.Status__c;
                d.ndaSent = nda.Date_Sent__c;
                d.ndaExpiry = nda.NDA_Expiry_Date__c;
                d.ndaSigned = nda.NDA_Signed__c == true;
            }

            // --- Underwriting: primary, else latest related ---
            Underwriting__c uw;
            if (opp.Primary_Underwriting__c != null) {
                uw = UnderwritingSelector.selectById(opp.Primary_Underwriting__c);
            }
            if (uw == null) {
                uw = UnderwritingSelector.selectLatestByOpportunityId(opportunityId);
            }
            if (uw != null) {
                d.hasUnderwriting = true;
                d.underwritingId = uw.Id;
                d.underwritingName = uw.Name;
                d.underwritingStage = uw.Stage__c;
                d.underwritingPrice = uw.My_Price__c;
                d.underwritingVerdict = uw.Verdict__c;
                d.underwritingOpened = uw.CreatedDate.date();
            }

            // --- LOI: primary, else latest related ---
            LOI__c loi;
            if (opp.Primary_LOI__c != null) {
                loi = LoiSelector.selectById(opp.Primary_LOI__c);
            }
            if (loi == null) {
                loi = LoiSelector.selectLatestByOpportunityId(opportunityId);
            }
            if (loi != null) {
                d.hasLoi = true;
                d.loiId = loi.Id;
                d.loiName = loi.Name;
                d.loiStatus = loi.LOI_Status__c;
                d.loiOfferPrice = loi.Offer_Price__c;
                d.loiCapRate = loi.Offer_Cap_Rate__c;
                d.loiSubmitted = loi.Submitted_Date__c;
            }

            // --- Development feasibility review: latest related ---
            for (Development_Feasibility_Review__c dev :
                    DevelopmentFeasibilityReviewSelector.selectLatestByOpportunityId(opportunityId)) {
                d.hasDevelopment = true;
                d.developmentId = dev.Id;
                d.developmentStage = dev.Stage__c;
                d.developmentOpened = dev.CreatedDate.date();
            }

            // --- Construction feasibility review: latest related ---
            for (Construction_Feasibility_Review__c con :
                    ConstructionFeasibilityReviewSelector.selectLatestByOpportunityId(opportunityId)) {
                d.hasConstruction = true;
                d.constructionId = con.Id;
                d.constructionStage = con.Stage__c;
                d.constructionOpened = con.CreatedDate.date();
            }

            // --- Contract review: latest related ---
            for (Contract_Review__c cr :
                    ContractReviewSelector.selectLatestByOpportunityId(opportunityId)) {
                d.hasContract = true;
                d.contractId = cr.Id;
                d.contractStage = cr.Stage__c;
                d.contractValue = cr.Contract_Value__c;
                d.contractDate = (cr.Execution_Date__c != null) ? cr.Execution_Date__c : cr.PSA_Date__c;
            }

            return d;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OpportunityDocStatusController.getDocStatus: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class DocStatus {
        @AuraEnabled public Boolean hasNda = false;
        @AuraEnabled public Id ndaId;
        @AuraEnabled public String ndaName;
        @AuraEnabled public String ndaStatus;
        @AuraEnabled public Date ndaSent;
        @AuraEnabled public Date ndaExpiry;
        @AuraEnabled public Boolean ndaSigned = false;

        @AuraEnabled public Boolean hasUnderwriting = false;
        @AuraEnabled public Id underwritingId;
        @AuraEnabled public String underwritingName;
        @AuraEnabled public String underwritingStage;
        @AuraEnabled public Decimal underwritingPrice;
        @AuraEnabled public String underwritingVerdict;
        @AuraEnabled public Date underwritingOpened;

        @AuraEnabled public Boolean hasLoi = false;
        @AuraEnabled public Id loiId;
        @AuraEnabled public String loiName;
        @AuraEnabled public String loiStatus;
        @AuraEnabled public Decimal loiOfferPrice;
        @AuraEnabled public Decimal loiCapRate;
        @AuraEnabled public Date loiSubmitted;

        @AuraEnabled public Boolean hasDevelopment = false;
        @AuraEnabled public Id developmentId;
        @AuraEnabled public String developmentStage;
        @AuraEnabled public Date developmentOpened;

        @AuraEnabled public Boolean hasConstruction = false;
        @AuraEnabled public Id constructionId;
        @AuraEnabled public String constructionStage;
        @AuraEnabled public Date constructionOpened;

        @AuraEnabled public Boolean hasContract = false;
        @AuraEnabled public Id contractId;
        @AuraEnabled public String contractStage;
        @AuraEnabled public Decimal contractValue;
        @AuraEnabled public Date contractDate;
    }
}
