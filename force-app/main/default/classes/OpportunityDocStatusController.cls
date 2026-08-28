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
                // Date_Sent__c pairs with the 'Sent' step, which the 2026-08-16 reorder made the
                // TERMINAL acquisition state (Pending -> Received -> Signed -> Sent). It therefore
                // records the day DPEG returned the SIGNED copy to the broker, not the day an NDA
                // went out awaiting signature. The DTO member is named for that meaning rather
                // than for the field, so the next reader does not have to re-derive it.
                //
                // 🔴 AMENDED 2026-08-27 — THE STEP THIS MEMBER IS NAMED FOR NO LONGER EXISTS ON
                // THE BUY SIDE, AND THE MEMBER WAS DELIBERATELY *NOT* RENAMED. The user removed
                // 'Sent' from the Acquisition_NDA record type in Setup (measured live: that type
                // offers exactly Pending | Received | Signed), so on an ACQUISITION NDA there is
                // no longer any step whose completion means "the signed copy went back". The map
                // hop that drove records into it is gone from
                // RecordStageAdvanceService.NDA_ACQUISITION_NEXT_STAGE in the same change.
                //
                // ⚠ THE FIELD IS NOT DEAD, WHICH IS THE PART THAT IS EASY TO GET WRONG.
                // Date_Sent__c is NOT stamped by any flow, trigger or service anywhere in this
                // repo — it is hand-entered, and it is on the NDA layout and record page with no
                // Status__c gating. So a user can still populate it on an acquisition NDA and this
                // card will still render "Signed copy returned <date>" for a record that never
                // passed a 'Sent' step. It also stays populated on every row worked before
                // 2026-08-27, under either of the two meanings the value has carried.
                // 🔴 RENAMING THIS MEMBER, RETIRING THE FIELD, RE-WORDING lwc/dealDocStatus's
                // label or changing NDA__c.Days_Out__c (IF(ISBLANK(Date_Sent__c), null,
                // TODAY() - Date_Sent__c)) ARE ALL USER DECISIONS AND WERE EXPLICITLY OUT OF SCOPE
                // OF THE 2026-08-27 CORRECTIVE. Note the DTO member name is load-bearing across
                // the Apex/LWC boundary — lwc/dealDocStatus reads `ndaSignedCopyReturned` by name
                // and its Jest suite asserts the rendered string, so a rename is a two-file change
                // plus a test update, not a tidy-up.
                d.ndaSignedCopyReturned = nda.Date_Sent__c;
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
        /**
         * Sourced from NDA__c.Date_Sent__c. Renamed from `ndaSent` on 2026-08-16: after the
         * acquisition NDA reorder (Pending -> Received -> Signed -> Sent) that field marks the
         * LAST step, so "sent" named the wrong end of the exchange and implied the deal was
         * still waiting on the counterparty when it is in fact past the NDA gate.
         *
         * ⚠ HISTORICAL ROWS CARRY THE OLD MEANING AND NOTHING DISTINGUISHES THEM. The value set
         * was reordered, not migrated, so an NDA worked before 2026-08-16 has Date_Sent__c
         * stamped when the BLANK NDA went out. There is no discriminator on the record, so this
         * is stated rather than guarded — a status-conditional label would invent a rule the
         * data cannot support.
         */
        @AuraEnabled public Date ndaSignedCopyReturned;
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
