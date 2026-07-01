/**
 * Backs the leaseNegotiationLog LWC on the Lease Inquiry record page. Reads the
 * append-only Lease_Activity__c log (newest first) and appends a new entry. Saving
 * an update sets the parent's Ball in Court and can advance the Stage to the next
 * step; the Stage Start Date reset is handled by the before-save Stage Timer flow.
 */
public with sharing class LeaseInquiryController {

    private static final List<String> STAGES = new List<String>{
        'Inquiry Received', 'LOI Received', 'LOI Negotiation', 'LOI Signed', 'Lease Drafting', 'Lease Signed'
    };

    public class LogView {
        @AuraEnabled public List<Entry> entries;
        @AuraEnabled public String stage;
        @AuraEnabled public String ballInCourt;
        @AuraEnabled public String nextStage;
        @AuraEnabled public Boolean canAdvance;
        @AuraEnabled public Boolean closed;
    }

    public class Entry {
        @AuraEnabled public Id id;
        @AuraEnabled public String details;
        @AuraEnabled public String ball;
        @AuraEnabled public String enteredBy;
        @AuraEnabled public Datetime entryDate;
    }

    @AuraEnabled(cacheable=true)
    public static LogView getLog(Id inquiryId) {
        LogView v = new LogView();
        v.entries = new List<Entry>();
        if (inquiryId == null) {
            return v;
        }
        Lease_Inquiry__c inq = [
            SELECT Id, Stage__c, Status__c, Ball_In_Court__c
            FROM Lease_Inquiry__c
            WHERE Id = :inquiryId
        ];
        v.stage = inq.Stage__c;
        v.ballInCourt = inq.Ball_In_Court__c;
        v.closed = inq.Status__c == 'Closed Won' || inq.Status__c == 'Closed Lost';
        Integer idx = STAGES.indexOf(inq.Stage__c);
        v.canAdvance = !v.closed && idx >= 0 && idx < STAGES.size() - 1;
        v.nextStage = v.canAdvance ? STAGES[idx + 1] : null;
        for (Lease_Activity__c a : [
            SELECT Id, Details__c, Ball_In_Court__c, Entry_Date__c, Logged_By__r.Name
            FROM Lease_Activity__c
            WHERE Lease_Inquiry__c = :inquiryId
            ORDER BY Entry_Date__c DESC NULLS LAST, Name DESC
        ]) {
            Entry e = new Entry();
            e.id = a.Id;
            e.details = a.Details__c;
            e.ball = a.Ball_In_Court__c;
            e.enteredBy = a.Logged_By__r != null ? a.Logged_By__r.Name : null;
            e.entryDate = a.Entry_Date__c;
            v.entries.add(e);
        }
        return v;
    }

    @AuraEnabled
    public static Id addUpdate(Id inquiryId, String details, String ball, Boolean advance) {
        if (inquiryId == null) {
            throw new AuraHandledException('No inquiry specified.');
        }
        if (String.isBlank(details)) {
            throw new AuraHandledException('Enter what changed before saving.');
        }
        Lease_Inquiry__c inq = [
            SELECT Id, Stage__c, Status__c
            FROM Lease_Inquiry__c
            WHERE Id = :inquiryId
        ];
        Boolean closed = inq.Status__c == 'Closed Won' || inq.Status__c == 'Closed Lost';

        insert new Lease_Activity__c(
            Lease_Inquiry__c = inquiryId,
            Details__c = details.trim(),
            Ball_In_Court__c = ball,
            Logged_By__c = UserInfo.getUserId(),
            Entry_Date__c = System.now()
        );

        Lease_Inquiry__c upd = new Lease_Inquiry__c(Id = inquiryId);
        Boolean touched = false;
        if (String.isNotBlank(ball)) {
            upd.Ball_In_Court__c = ball;
            touched = true;
        }
        if (advance == true && !closed) {
            Integer idx = STAGES.indexOf(inq.Stage__c);
            if (idx >= 0 && idx < STAGES.size() - 1) {
                upd.Stage__c = STAGES[idx + 1];
                touched = true;
            }
        }
        if (touched) {
            update upd;
        }
        return inquiryId;
    }
}
