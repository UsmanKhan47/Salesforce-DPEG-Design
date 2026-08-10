public with sharing class BovController {

    public class BovRow {
        @AuraEnabled public String id;
        @AuraEnabled public String brokerFirm;
        @AuraEnabled public String contactName;
        @AuraEnabled public Decimal bovAmount;
        @AuraEnabled public Decimal commissionRate;
        @AuraEnabled public Integer daysToMarket;
        @AuraEnabled public Decimal histSuccessRate;
        @AuraEnabled public Decimal capRate;
        @AuraEnabled public Integer bovScore;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isSelected;
    }

    public class OutreachSummary {
        @AuraEnabled public String assetName;
        @AuraEnabled public Date packageSent;
        @AuraEnabled public Date submissionDeadline;
        @AuraEnabled public Integer responsesReceived;
        @AuraEnabled public Integer brokersContacted;
        @AuraEnabled public String selectedBroker;
        @AuraEnabled public Boolean matrixGenerated;
        /**
         * Status__c of the disposition's most recent NDA__c, or NULL when there is no NDA
         * yet — which is the normal state for most dispositions and is NOT an error.
         * lwc/bovOutreach renders null as "No NDA".
         *
         * ⚠ Null is ALSO what a failed NDA read degrades to (see getOutreachSummary). The
         * two are deliberately indistinguishable to the client: both mean "we cannot show
         * you a signed NDA", and neither is worth a second field or a second pill state.
         */
        @AuraEnabled public String ndaStatus;
    }

    // Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never
    // interpolate platform text or exception detail into it — the detail goes to the
    // debug log (admin-only) and the user gets this. A deleted / invalid Disposition Id
    // surfaces here as this message rather than a raw QueryException.
    private static final String READ_FAILURE_MESSAGE =
        'The BOV information could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    @AuraEnabled(cacheable=true)
    public static List<BovRow> getSubmissions(Id dispositionId) {
        try {
            List<BOV_Submission__c> subs = BovSubmissionSelector.selectByDispositionId(dispositionId);
            List<BovRow> rows = new List<BovRow>();
            for (BOV_Submission__c s : subs) {
                BovRow r = new BovRow();
                r.id = s.Id;
                r.brokerFirm = s.Broker_Firm__c;
                r.contactName = s.Contact_Name__c;
                r.bovAmount = s.BOV_Amount__c;
                r.commissionRate = s.Commission_Rate__c;
                r.daysToMarket = s.Days_To_Market__c != null ? s.Days_To_Market__c.intValue() : null;
                r.histSuccessRate = s.Hist_Success_Rate__c;
                r.capRate = s.Cap_Rate__c;
                r.bovScore = s.BOV_Score__c != null ? s.BOV_Score__c.intValue() : null;
                r.status = s.Submission_Status__c;
                r.isSelected = 'Selected'.equals(s.Submission_Status__c);
                rows.add(r);
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BovController.getSubmissions on ' + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled(cacheable=true)
    public static OutreachSummary getOutreachSummary(Id dispositionId) {
        try {
            Disposition__c d = DispositionSelector.selectOutreachById(dispositionId);
            OutreachSummary s = new OutreachSummary();
            s.assetName = d.Property_Asset__r != null ? d.Property_Asset__r.Name : '';
            s.packageSent = d.Package_Sent__c;
            s.submissionDeadline = d.Submission_Deadline__c;
            s.responsesReceived = d.Responses_Received__c != null ? d.Responses_Received__c.intValue() : 0;
            s.brokersContacted = d.Brokers_Contacted__c != null ? d.Brokers_Contacted__c.intValue() : 0;
            s.selectedBroker = d.Selected_Broker__c;
            s.matrixGenerated = s.responsesReceived >= 3;
            s.ndaStatus = readNdaStatusFailSoft(dispositionId);
            return s;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BovController.getOutreachSummary on ' + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * The disposition's latest NDA status, or null when there is none — or when the read
     * itself fails.
     *
     * 🔴 THE NARROW TRY/CATCH IS THE ENTIRE POINT OF THIS METHOD AND MUST NOT BE FOLDED
     * BACK INTO getOutreachSummary's OUTER CATCH. NDA__c is granted to the disposition
     * personas by DPEG_Disposition_View / DPEG_Disposition_Edit (Gate 1 Q7), but a
     * permission set deploy REPLACES its whole grant list, so that grant is one unrelated
     * redeploy away from vanishing — and a `WITH USER_MODE` read of an object the running
     * user cannot see THROWS rather than returning empty. Inside the outer catch that
     * QueryException becomes READ_FAILURE_MESSAGE and the ENTIRE BOV Outreach tile
     * disappears for every disposition-only user. Degrading one pill is strictly better
     * than blanking the whole card, and both worse than the hard-coded "Signed" this
     * replaced.
     *
     * ⚠ The grant and this catch are BOTH required — Gate 1 Q7 says "both, not either".
     * This is defence in depth, not a substitute for provisioning NDA__c.
     *
     * catch (Exception), not catch (QueryException): the failure mode being defended
     * against is an FLS/CRUD denial, which the platform reports as a QueryException today,
     * but nothing about this method's contract depends on the exception's type and a
     * narrower catch would only re-open the tile-blanking path for a neighbouring failure.
     *
     * @param dispositionId the disposition whose NDA to read
     * @return the latest NDA's Status__c; null when there is no NDA or the read failed
     */
    private static String readNdaStatusFailSoft(Id dispositionId) {
        try {
            NDA__c nda = NdaSelector.selectLatestByDispositionId(dispositionId);
            return (nda == null) ? null : nda.Status__c;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BovController NDA status read degraded on '
                + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            return null;
        }
    }
}