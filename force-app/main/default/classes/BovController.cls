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
    }

    @AuraEnabled(cacheable=true)
    public static List<BovRow> getSubmissions(Id dispositionId) {
        List<BOV_Submission__c> subs = [
            SELECT Id, Broker_Firm__c, Contact_Name__c, BOV_Amount__c,
                   Commission_Rate__c, Days_To_Market__c, Hist_Success_Rate__c,
                   Cap_Rate__c, BOV_Score__c, Submission_Status__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
            ORDER BY BOV_Score__c DESC NULLS LAST
        ];
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
    }

    @AuraEnabled(cacheable=true)
    public static OutreachSummary getOutreachSummary(Id dispositionId) {
        Disposition__c d = [
            SELECT Id, Property_Asset__r.Name, Package_Sent__c, Submission_Deadline__c,
                   Responses_Received__c, Brokers_Contacted__c, Selected_Broker__c
            FROM Disposition__c
            WHERE Id = :dispositionId
            LIMIT 1
        ];
        OutreachSummary s = new OutreachSummary();
        s.assetName = d.Property_Asset__r != null ? d.Property_Asset__r.Name : '';
        s.packageSent = d.Package_Sent__c;
        s.submissionDeadline = d.Submission_Deadline__c;
        s.responsesReceived = d.Responses_Received__c != null ? d.Responses_Received__c.intValue() : 0;
        s.brokersContacted = d.Brokers_Contacted__c != null ? d.Brokers_Contacted__c.intValue() : 0;
        s.selectedBroker = d.Selected_Broker__c;
        s.matrixGenerated = s.responsesReceived >= 3;
        return s;
    }
}