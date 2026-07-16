/**
 * Backs the dealMessageLog LWC - the shared, append-only communication tracker
 * shown in the Messages tab on LOI, Underwriting, and Contract Review record
 * pages (same interaction pattern as the Lease Activity / Lease Renewal
 * timelines). The parent object is derived from the record Id, so one component
 * and one controller serve all three objects.
 */
public with sharing class DealMessageController {

    private static final Map<String, SObjectField> PARENT_FIELDS = new Map<String, SObjectField>{
        'LOI__c'             => Deal_Message__c.LOI__c,
        'Underwriting__c'    => Deal_Message__c.Underwriting__c,
        'Contract_Review__c' => Deal_Message__c.Contract_Review__c
    };

    public class Entry {
        @AuraEnabled public String id;
        @AuraEnabled public String method;
        @AuraEnabled public String direction;
        @AuraEnabled public String details;
        @AuraEnabled public String revision;
        @AuraEnabled public String enteredBy;
        @AuraEnabled public Datetime entryDate;
    }

    @AuraEnabled(cacheable=true)
    public static List<Entry> getMessages(Id recordId) {
        if (recordId == null) {
            return new List<Entry>();
        }
        String parentField = parentFieldFor(recordId);
        List<Entry> entries = new List<Entry>();
        for (Deal_Message__c m : Database.query(
            'SELECT Id, Method__c, Direction__c, Details__c, Revision__c, Entry_Date__c, CreatedDate, CreatedBy.Name ' +
            'FROM Deal_Message__c WHERE ' + parentField + ' = :recordId ' +
            'ORDER BY Entry_Date__c DESC, CreatedDate DESC, Id DESC'
        )) {
            Entry e = new Entry();
            e.id = m.Id;
            e.method = m.Method__c;
            e.direction = m.Direction__c;
            e.details = m.Details__c;
            e.revision = m.Revision__c;
            e.enteredBy = m.CreatedBy.Name;
            e.entryDate = m.Entry_Date__c != null ? m.Entry_Date__c : m.CreatedDate;
            entries.add(e);
        }
        return entries;
    }

    @AuraEnabled
    public static void addMessage(Id recordId, String method, String direction, String details, String revision) {
        if (recordId == null) {
            throw new AuraHandledException('No record to log the message against.');
        }
        if (String.isBlank(details)) {
            throw new AuraHandledException('Enter what was communicated before saving.');
        }
        String parentField = parentFieldFor(recordId);
        // MIGRATION (D1) — dual-write. Entry_Date__c is a DateTime whose _Date suffix
        // breaks ARCHITECTURE.md §1 rule 9; Entry_DateTime__c replaces it. Both are
        // written from ONE stamp so the two fields can never disagree by a millisecond,
        // which keeps the D2 backfill's old-vs-new equality check clean. Readers stay
        // on Entry_Date__c until D3; drop Entry_Date__c at D4.
        Datetime entryStamp = Datetime.now();
        Deal_Message__c m = new Deal_Message__c(
            Method__c = String.isBlank(method) ? 'Note' : method,
            Direction__c = String.isBlank(direction) ? 'Internal' : direction,
            Details__c = details.trim(),
            Revision__c = String.isBlank(revision) ? null : revision.trim(),
            Entry_Date__c = entryStamp,
            Entry_DateTime__c = entryStamp
        );
        m.put(PARENT_FIELDS.get(parentField), recordId);
        insert m;
    }

    /** The Deal_Message__c lookup matching the record's object; throws for anything else. */
    private static String parentFieldFor(Id recordId) {
        String objectName = recordId.getSobjectType().getDescribe().getName();
        if (!PARENT_FIELDS.containsKey(objectName)) {
            throw new AuraHandledException('The message tracker is not available on ' + objectName + '.');
        }
        return objectName;
    }
}