/**
 * Backs the Lease Renewal Tracker: home-page widgets and the record-page
 * timeline. Timeline entries are append-only.
 */
public with sharing class LeaseRenewalController {

    private static final Set<String> METHODS = new Set<String>{ 'Call', 'Email', 'Visit', 'Note', 'System' };
    private static final String ROW_QUERY =
        'SELECT Id, Tenant_Name__c, Property_Display_Name__c, Unit_Label__c, Lease_End__c, Days_To_Expiry__c, ' +
        'Stage__c, Status__c, Last_Contact_Date__c, Days_Since_Contact__c, Non_Responsive__c ' +
        'FROM Lease_Renewal__c ';

    public class HomeKpis {
        @AuraEnabled public Integer active;
        @AuraEnabled public Integer expiring90;
        @AuraEnabled public Integer nonResponsive;
        @AuraEnabled public Integer renewedYtd;
    }
    @AuraEnabled(cacheable=true)
    public static HomeKpis getHomeKpis() {
        HomeKpis k = new HomeKpis();
        k.active = 0; k.expiring90 = 0; k.nonResponsive = 0; k.renewedYtd = 0;
        Date yearStart = Date.newInstance(Date.today().year(), 1, 1);
        for (Lease_Renewal__c r : [SELECT Status__c, Days_To_Expiry__c, Non_Responsive__c, Renewed_Date__c FROM Lease_Renewal__c]) {
            if (r.Status__c == 'Active') {
                k.active++;
                if (r.Days_To_Expiry__c != null && r.Days_To_Expiry__c <= 90) k.expiring90++;
                if (r.Non_Responsive__c) k.nonResponsive++;
            }
            if (r.Status__c == 'Closed Won' && r.Renewed_Date__c != null && r.Renewed_Date__c >= yearStart) k.renewedYtd++;
        }
        return k;
    }

    public class Row {
        @AuraEnabled public Id id;
        @AuraEnabled public String tenant;
        @AuraEnabled public String property;
        @AuraEnabled public String unit;
        @AuraEnabled public Date leaseEnd;
        @AuraEnabled public Integer daysToExpiry;
        @AuraEnabled public String stage;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean closed;
        @AuraEnabled public Date lastContact;
        @AuraEnabled public Integer daysSinceContact;
        @AuraEnabled public Boolean nonResponsive;
    }
    private static Row toRow(Lease_Renewal__c r) {
        Row w = new Row();
        w.id = r.Id; w.tenant = r.Tenant_Name__c; w.property = r.Property_Display_Name__c; w.unit = r.Unit_Label__c;
        w.leaseEnd = r.Lease_End__c;
        w.daysToExpiry = r.Days_To_Expiry__c == null ? null : (Integer) r.Days_To_Expiry__c;
        w.stage = r.Stage__c; w.status = r.Status__c; w.closed = r.Status__c != 'Active';
        w.lastContact = r.Last_Contact_Date__c;
        w.daysSinceContact = r.Days_Since_Contact__c == null ? null : (Integer) r.Days_Since_Contact__c;
        w.nonResponsive = r.Non_Responsive__c == true;
        return w;
    }
    private static List<Row> toRows(List<Lease_Renewal__c> recs) {
        List<Row> out = new List<Row>();
        for (Lease_Renewal__c r : recs) out.add(toRow(r));
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Row> getRecentRenewals() {
        return toRows(Database.query(ROW_QUERY + 'ORDER BY CreatedDate DESC LIMIT 6'));
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getAttention() {
        return toRows(Database.query(ROW_QUERY +
            'WHERE Status__c = \'Active\' AND (Non_Responsive__c = true OR Days_To_Expiry__c <= 30) ORDER BY Lease_End__c ASC NULLS LAST'));
    }

    public class Entry {
        @AuraEnabled public Id id;
        @AuraEnabled public String method;
        @AuraEnabled public String details;
        @AuraEnabled public String enteredBy;
        @AuraEnabled public Datetime entryDate;
    }
    public class TimelineView {
        @AuraEnabled public List<Entry> entries;
        @AuraEnabled public String stage;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean closed;
        @AuraEnabled public Boolean nonResponsive;
        @AuraEnabled public Integer daysSinceContact;
        @AuraEnabled public Boolean canLog;
    }
    @AuraEnabled(cacheable=true)
    public static TimelineView getTimeline(Id renewalId) {
        Lease_Renewal__c r = [SELECT Stage__c, Status__c, Non_Responsive__c, Days_Since_Contact__c
                              FROM Lease_Renewal__c WHERE Id = :renewalId LIMIT 1];
        TimelineView v = new TimelineView();
        v.stage = r.Stage__c; v.status = r.Status__c; v.closed = r.Status__c != 'Active';
        v.nonResponsive = r.Non_Responsive__c == true;
        v.daysSinceContact = r.Days_Since_Contact__c == null ? null : (Integer) r.Days_Since_Contact__c;
        v.canLog = !v.closed;
        v.entries = new List<Entry>();
        // Frozen-clock gotcha: same-transaction rows share timestamps, so tie-break on Name DESC.
        for (Renewal_Activity__c a : [SELECT Id, Method__c, Details__c, Entry_Date__c, CreatedBy.Name
                                      FROM Renewal_Activity__c WHERE Lease_Renewal__c = :renewalId
                                      ORDER BY Entry_Date__c DESC NULLS LAST, Name DESC]) {
            Entry e = new Entry();
            e.id = a.Id; e.method = a.Method__c; e.details = a.Details__c;
            e.enteredBy = a.CreatedBy.Name; e.entryDate = a.Entry_Date__c;
            v.entries.add(e);
        }
        return v;
    }

    @AuraEnabled
    public static void addUpdate(Id renewalId, String method, String details) {
        if (String.isBlank(details)) throw ahe('Enter the outcome before saving.');
        if (String.isBlank(method) || !METHODS.contains(method)) throw ahe('Choose a valid contact method.');
        insert new Renewal_Activity__c(
            Lease_Renewal__c = renewalId, Method__c = method,
            Details__c = details.trim(), Entry_Date__c = Datetime.now());
        // A Yardi/system note is not tenant contact — only human methods reset the clock.
        if (method != 'System') {
            update new Lease_Renewal__c(Id = renewalId, Last_Contact_Date__c = Date.today());
        }
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }
}