/**
 * Sidebar data provider for the Opportunity record page (the "Deal Summary" card):
 * returns NDA and LOI status, plus the latest related Development / Construction
 * feasibility review and Contract review for a deal. NDA/LOI use the designated
 * Primary_NDA__c / Primary_LOI__c when set, otherwise the most recent related record.
 */
public with sharing class OpportunityDocStatusController {

    @AuraEnabled(cacheable=true)
    public static DocStatus getDocStatus(Id opportunityId) {
        DocStatus d = new DocStatus();
        if (opportunityId == null) {
            return d;
        }

        Opportunity opp = [
            SELECT Id, Primary_NDA__c, Primary_LOI__c, Primary_Underwriting__c
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];

        // --- NDA: primary, else latest related ---
        NDA__c nda;
        if (opp.Primary_NDA__c != null) {
            nda = queryNda('Id = :pid', opp.Primary_NDA__c);
        }
        if (nda == null) {
            nda = queryNda('Opportunity__c = :pid ORDER BY CreatedDate DESC', opportunityId);
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
            uw = queryUnderwriting('Id = :pid', opp.Primary_Underwriting__c);
        }
        if (uw == null) {
            uw = queryUnderwriting('Opportunity__c = :pid ORDER BY CreatedDate DESC', opportunityId);
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
            loi = queryLoi('Id = :pid', opp.Primary_LOI__c);
        }
        if (loi == null) {
            loi = queryLoi('Opportunity__c = :pid ORDER BY CreatedDate DESC', opportunityId);
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
        for (Development_Feasibility_Review__c dev : [
            SELECT Id, Stage__c, CreatedDate
            FROM Development_Feasibility_Review__c
            WHERE Opportunity__c = :opportunityId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ]) {
            d.hasDevelopment = true;
            d.developmentId = dev.Id;
            d.developmentStage = dev.Stage__c;
            d.developmentOpened = dev.CreatedDate.date();
        }

        // --- Construction feasibility review: latest related ---
        for (Construction_Feasibility_Review__c con : [
            SELECT Id, Stage__c, CreatedDate
            FROM Construction_Feasibility_Review__c
            WHERE Opportunity__c = :opportunityId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ]) {
            d.hasConstruction = true;
            d.constructionId = con.Id;
            d.constructionStage = con.Stage__c;
            d.constructionOpened = con.CreatedDate.date();
        }

        // --- Contract review: latest related ---
        for (Contract_Review__c cr : [
            SELECT Id, Stage__c, Contract_Value__c, PSA_Date__c, Execution_Date__c
            FROM Contract_Review__c
            WHERE Opportunity__c = :opportunityId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ]) {
            d.hasContract = true;
            d.contractId = cr.Id;
            d.contractStage = cr.Stage__c;
            d.contractValue = cr.Contract_Value__c;
            d.contractDate = (cr.Execution_Date__c != null) ? cr.Execution_Date__c : cr.PSA_Date__c;
        }

        return d;
    }

    private static NDA__c queryNda(String tail, Id pid) {
        List<NDA__c> rows = Database.query(
            'SELECT Id, Name, Status__c, Date_Sent__c, NDA_Expiry_Date__c, NDA_Signed__c ' +
            'FROM NDA__c WHERE ' + tail + ' LIMIT 1'
        );
        return rows.isEmpty() ? null : rows[0];
    }

    private static Underwriting__c queryUnderwriting(String tail, Id pid) {
        List<Underwriting__c> rows = Database.query(
            'SELECT Id, Name, Stage__c, My_Price__c, Verdict__c, CreatedDate ' +
            'FROM Underwriting__c WHERE ' + tail + ' LIMIT 1'
        );
        return rows.isEmpty() ? null : rows[0];
    }

    private static LOI__c queryLoi(String tail, Id pid) {
        List<LOI__c> rows = Database.query(
            'SELECT Id, Name, LOI_Status__c, Offer_Price__c, Offer_Cap_Rate__c, Submitted_Date__c ' +
            'FROM LOI__c WHERE ' + tail + ' LIMIT 1'
        );
        return rows.isEmpty() ? null : rows[0];
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