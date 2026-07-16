public with sharing class BrokerAssignmentController {
    public static final Integer WARN_DAYS = 14;
    public static final Integer OVERDUE_DAYS = 21;

    // SOQL relocated to BrokerAssignmentSelector (ARCHITECTURE.md §2). This stays as
    // a thin delegate so the six dashboard reads that buffer it keep one call-site.
    private static List<Broker_Assignment__c> queryAll() {
        return BrokerAssignmentSelector.selectAllOrderedByCreatedDateDesc();
    }
    private static Integer idle(Broker_Assignment__c a) {
        return a.Days_Since_Check_In__c == null ? null : (Integer) a.Days_Since_Check_In__c;
    }
    // Stale = an Active listing whose last check-in is at least 7 days ago (matches the Alerts 7-day tile).
    private static Boolean isStale(Broker_Assignment__c a) {
        Integer d = idle(a); return a.Status__c == 'Active' && d != null && d >= 7;
    }

    public class Kpis { @AuraEnabled public Integer total; @AuraEnabled public Integer active; @AuraEnabled public Integer stale; @AuraEnabled public Integer leased; }
    @AuraEnabled(cacheable=true)
    public static Kpis getKpis() {
        Kpis k = new Kpis(); k.total=0; k.active=0; k.stale=0; k.leased=0;
        for (Broker_Assignment__c a : queryAll()) {
            k.total++;
            if (a.Status__c == 'Active') k.active++;
            if (a.Status__c == 'Fully Leased') k.leased++;
            if (isStale(a)) k.stale++;
        }
        return k;
    }

    public class Row {
        @AuraEnabled public Id id; @AuraEnabled public Id brokerId;
        @AuraEnabled public String propertyName; @AuraEnabled public String propertyAddr;
        @AuraEnabled public String brokerName; @AuraEnabled public String brokerFirm;
        @AuraEnabled public String status; @AuraEnabled public Date startDate; @AuraEnabled public Date endDate;
        @AuraEnabled public Date lastCheckIn; @AuraEnabled public Integer daysIdle; @AuraEnabled public String reason;
    }
    @AuraEnabled(cacheable=true)
    public static List<Row> getAssignments() {
        List<Row> out = new List<Row>();
        for (Broker_Assignment__c a : queryAll()) {
            Row r = new Row();
            r.id=a.Id; r.brokerId=a.Broker__c;
            r.propertyName=a.Property_Display_Name__c; r.propertyAddr=a.Address_Display__c;
            r.brokerName=a.Broker_Name__c; r.brokerFirm=a.Broker_Firm__c;
            r.status=a.Status__c; r.startDate=a.Listing_Start_Date__c; r.endDate=a.Listing_End_Date__c;
            r.lastCheckIn=a.Last_Check_In_Date__c; r.daysIdle=idle(a); r.reason=a.Reason_Ended__c;
            out.add(r);
        }
        return out;
    }

    public class Portfolio { @AuraEnabled public Integer total; @AuraEnabled public Integer active; @AuraEnabled public Integer leased; @AuraEnabled public Integer disposed; }
    @AuraEnabled(cacheable=true)
    public static Portfolio getPortfolio() {
        Portfolio p = new Portfolio(); p.total=0; p.active=0; p.leased=0; p.disposed=0;
        for (Broker_Assignment__c a : queryAll()) {
            p.total++;
            if (a.Status__c=='Active') p.active++;
            else if (a.Status__c=='Fully Leased') p.leased++;
            else if (a.Status__c=='Disposed') p.disposed++;
        }
        return p;
    }

    public class Alerts { @AuraEnabled public Integer stale7; @AuraEnabled public Integer stale30; }
    @AuraEnabled(cacheable=true)
    public static Alerts getAlerts() {
        // Stale = Active listings whose last check-in is at least N days ago (cumulative: stale30 is a subset of stale7).
        Alerts al = new Alerts(); al.stale7=0; al.stale30=0;
        for (Broker_Assignment__c a : queryAll()) {
            if (a.Status__c != 'Active') continue;
            Integer d = idle(a);
            if (d == null) continue;
            if (d >= 7) al.stale7++;
            if (d >= 30) al.stale30++;
        }
        return al;
    }

    public class BrokerCard {
        @AuraEnabled public Id brokerId; @AuraEnabled public String name; @AuraEnabled public String firm;
        @AuraEnabled public Integer active; @AuraEnabled public Integer leased; @AuraEnabled public Integer disposed;
        @AuraEnabled public Integer total;
    }
    @AuraEnabled(cacheable=true)
    public static List<BrokerCard> getScorecard() {
        Map<Id, BrokerCard> byBroker = new Map<Id, BrokerCard>();
        for (Broker_Assignment__c a : queryAll()) {
            if (a.Broker__c == null) continue;
            BrokerCard c = byBroker.get(a.Broker__c);
            if (c == null) { c = new BrokerCard(); c.brokerId=a.Broker__c; c.name=a.Broker_Name__c; c.firm=a.Broker_Firm__c; c.active=0; c.leased=0; c.disposed=0; c.total=0; byBroker.put(a.Broker__c, c); }
            c.total++;
            if (a.Status__c=='Active') c.active++;
            else if (a.Status__c=='Fully Leased') c.leased++;
            else if (a.Status__c=='Disposed') c.disposed++;
        }
        return byBroker.values();
    }

    public class BrokerTotal {
        @AuraEnabled public Id brokerId; @AuraEnabled public String name; @AuraEnabled public String firm; @AuraEnabled public Integer totalProperties;
    }
    @AuraEnabled(cacheable=true)
    public static List<BrokerTotal> getBrokerTotals() {
        Map<Id, BrokerTotal> byBroker = new Map<Id, BrokerTotal>();
        Map<Id, Set<Id>> propsByBroker = new Map<Id, Set<Id>>();
        for (Broker_Assignment__c a : queryAll()) {
            if (a.Broker__c == null) continue;
            BrokerTotal bt = byBroker.get(a.Broker__c);
            if (bt == null) { bt = new BrokerTotal(); bt.brokerId=a.Broker__c; bt.name=a.Broker_Name__c; bt.firm=a.Broker_Firm__c; bt.totalProperties=0; byBroker.put(a.Broker__c, bt); propsByBroker.put(a.Broker__c, new Set<Id>()); }
            if (a.Property_Asset__c != null) propsByBroker.get(a.Broker__c).add(a.Property_Asset__c);
        }
        for (Id bid : byBroker.keySet()) byBroker.get(bid).totalProperties = propsByBroker.get(bid).size();
        List<BrokerTotal> out = byBroker.values();
        out.sort(new BrokerTotalComparator());
        return out;
    }
    // Sorts brokers by distinct-property count, highest first.
    private class BrokerTotalComparator implements Comparator<BrokerTotal> {
        public Integer compare(BrokerTotal a, BrokerTotal b) { return b.totalProperties - a.totalProperties; }
    }
    // Sorts Broker_Assignment__c records by Listing_Start_Date__c ascending; null treated as earliest.
    private class StartDateAscComparator implements Comparator<Broker_Assignment__c> {
        public Integer compare(Broker_Assignment__c a, Broker_Assignment__c b) {
            if (a.Listing_Start_Date__c == b.Listing_Start_Date__c) return 0;
            if (a.Listing_Start_Date__c == null) return -1;
            if (b.Listing_Start_Date__c == null) return 1;
            return a.Listing_Start_Date__c < b.Listing_Start_Date__c ? -1 : 1;
        }
    }

    public class HistoryRow {
        @AuraEnabled public Id id; @AuraEnabled public String brokerName; @AuraEnabled public String brokerFirm;
        @AuraEnabled public String status; @AuraEnabled public Date startDate; @AuraEnabled public Date endDate;
        @AuraEnabled public String reason; @AuraEnabled public String notes; @AuraEnabled public Boolean current;
    }
    public class Detail {
        @AuraEnabled public Id id; @AuraEnabled public Id propertyAssetId;
        @AuraEnabled public String propertyName; @AuraEnabled public String propertyType; @AuraEnabled public String propertyAddr;
        @AuraEnabled public Integer grossSqFt; @AuraEnabled public Integer vacantArea; @AuraEnabled public Integer leasedArea; @AuraEnabled public Integer activeDays;
        @AuraEnabled public String brokerName; @AuraEnabled public String brokerFirm; @AuraEnabled public String brokerEmail; @AuraEnabled public String brokerPhone;
        @AuraEnabled public String status; @AuraEnabled public Date startDate; @AuraEnabled public Date endDate; @AuraEnabled public Date lastCheckIn;
        @AuraEnabled public Integer daysIdle; @AuraEnabled public String reason; @AuraEnabled public List<HistoryRow> history;
    }
    @AuraEnabled(cacheable=true)
    public static Detail getDetail(Id assignmentId) {
        List<Broker_Assignment__c> recs = queryAll();
        Broker_Assignment__c a;
        for (Broker_Assignment__c r : recs) if (r.Id == assignmentId) { a = r; break; }
        if (a == null) return null;
        Detail d = new Detail();
        d.id=a.Id; d.propertyAssetId=a.Property_Asset__c;
        d.propertyName=a.Property_Display_Name__c; d.propertyType=a.Property_Type_Display__c; d.propertyAddr=a.Address_Display__c;
        d.grossSqFt = a.Gross_Sq_Ft__c == null ? null : (Integer) a.Gross_Sq_Ft__c;
        d.vacantArea = a.Vacant_Area__c == null ? null : (Integer) a.Vacant_Area__c;
        d.leasedArea = a.Leased_Area__c == null ? null : (Integer) a.Leased_Area__c;
        d.activeDays = a.Listing_Active_Days__c == null ? null : (Integer) a.Listing_Active_Days__c;
        d.brokerName=a.Broker_Name__c; d.brokerFirm=a.Broker_Firm__c; d.brokerEmail=a.Broker_Email__c; d.brokerPhone=a.Broker_Phone__c;
        d.status=a.Status__c; d.startDate=a.Listing_Start_Date__c; d.endDate=a.Listing_End_Date__c; d.lastCheckIn=a.Last_Check_In_Date__c;
        d.daysIdle=idle(a); d.reason=a.Reason_Ended__c;
        // history = same Property Asset, oldest -> newest; built from queryAll() result already in memory
        List<Broker_Assignment__c> same = new List<Broker_Assignment__c>();
        for (Broker_Assignment__c r : recs) {
            if (r.Property_Asset__c == a.Property_Asset__c) same.add(r);
        }
        same.sort(new StartDateAscComparator());
        List<HistoryRow> hist = new List<HistoryRow>();
        for (Broker_Assignment__c h : same) {
            HistoryRow hr = new HistoryRow();
            hr.id=h.Id; hr.brokerName=h.Broker_Name__c; hr.brokerFirm=h.Broker_Firm__c; hr.status=h.Status__c;
            hr.startDate=h.Listing_Start_Date__c; hr.endDate=h.Listing_End_Date__c;
            hr.reason=h.Reason_Ended__c; hr.notes=h.Replacement_Notes__c;
            hr.current = (h.Id == a.Id);
            hist.add(hr);
        }
        d.history = hist;
        return d;
    }

    @AuraEnabled
    public static void logCheckIn(Id assignmentId) {
        update new Broker_Assignment__c(Id=assignmentId, Last_Check_In_Date__c=Date.today());
    }
    @AuraEnabled
    public static void closeOut(Id assignmentId, String status, Date endDate, String reason) {
        update new Broker_Assignment__c(Id=assignmentId, Status__c=status,
            Listing_End_Date__c = endDate == null ? Date.today() : endDate, Reason_Ended__c=reason);
    }
    public class BrokerOption { @AuraEnabled public Id id; @AuraEnabled public String label; }
    @AuraEnabled(cacheable=true)
    public static List<BrokerOption> getBrokerOptions() {
        List<BrokerOption> out = new List<BrokerOption>();
        for (Contact c : ContactSelector.selectBrokersOrderedByName()) {
            BrokerOption o = new BrokerOption(); o.id=c.Id; o.label = c.Broker_Firm__c == null ? c.Name : (c.Name + ' · ' + c.Broker_Firm__c); out.add(o);
        }
        return out;
    }

    // ===== Notes (native Salesforce Notes / ContentNote) =====
    public class NoteRow {
        @AuraEnabled public Id id; @AuraEnabled public String title; @AuraEnabled public String preview;
        @AuraEnabled public String author; @AuraEnabled public Datetime createdDate;
    }
    // Notes attached to this record, newest first. ContentNote shares its Id with the
    // underlying ContentDocument, so filtering ContentNote by the record's linked document
    // Ids returns only notes (files are naturally excluded).
    @AuraEnabled(cacheable=true)
    public static List<NoteRow> getNotes(Id recordId) {
        List<NoteRow> out = new List<NoteRow>();
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : ContentDocumentLinkSelector.selectByLinkedEntityId(recordId)) {
            docIds.add(l.ContentDocumentId);
        }
        if (docIds.isEmpty()) return out;
        for (ContentNote n : ContentNoteSelector.selectByIdsOrderedByCreatedDateDesc(docIds)) {
            NoteRow r = new NoteRow();
            r.id = n.Id; r.title = n.Title; r.preview = String.isBlank(n.TextPreview) ? n.Title : n.TextPreview;
            r.author = n.CreatedBy.Name; r.createdDate = n.CreatedDate;
            out.add(r);
        }
        return out;
    }
    // Creates a native Note from free text and links it to the record. Title is derived
    // from the first 50 chars so the note is identifiable in the standard Notes UI too.
    @AuraEnabled
    public static void addNote(Id recordId, String body) {
        String text = body == null ? '' : body.trim();
        if (String.isBlank(text)) throw new AuraHandledException('Note cannot be empty.');
        String flat = text.replaceAll('\\s+', ' ');
        String title = flat.length() > 50 ? flat.substring(0, 50) : flat;
        String html = text.escapeHtml4().replace('\n', '<br>');
        ContentNote n = new ContentNote(Title = title, Content = Blob.valueOf(html));
        insert n;
        insert new ContentDocumentLink(ContentDocumentId = n.Id, LinkedEntityId = recordId, ShareType = 'V', Visibility = 'AllUsers');
    }

    @AuraEnabled
    public static Id replaceBroker(Id assignmentId, Id newBrokerId, Date effectiveDate, String reason, String notes) {
        Date eff = effectiveDate == null ? Date.today() : effectiveDate;
        Broker_Assignment__c cur = BrokerAssignmentSelector.selectRequiredById(assignmentId);
        // Snapshot the outgoing broker's stint as a closed (Disposed) history record,
        // carrying the reason and notes for the replacement.
        if (cur.Broker__c != null) {
            insert new Broker_Assignment__c(
                Property_Asset__c=cur.Property_Asset__c,
                Broker__c=cur.Broker__c,
                Status__c='Disposed',
                Listing_Start_Date__c=cur.Listing_Start_Date__c,
                Listing_End_Date__c=eff,
                Last_Check_In_Date__c=cur.Last_Check_In_Date__c,
                Reason_Ended__c=reason,
                Replacement_Notes__c=notes);
        }
        // Swap the current listing in place to the incoming broker — it stays Active.
        // The incoming broker's tenure starts on the effective date; the check-in
        // clock resets and any prior end date / reason / notes are cleared.
        update new Broker_Assignment__c(
            Id=assignmentId,
            Broker__c=newBrokerId,
            Status__c='Active',
            Listing_Start_Date__c=eff,
            Last_Check_In_Date__c=eff,
            Listing_End_Date__c=null,
            Reason_Ended__c=null,
            Replacement_Notes__c=null);
        return assignmentId;
    }
}