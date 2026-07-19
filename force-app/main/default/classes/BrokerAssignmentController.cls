/**
 * Backs the Broker Assignments dashboard, scorecard, detail/history and record-page
 * Notes UI (Property Management → Leasing). Reads buffer a single selector query in
 * memory and derive their own aggregates; the four write actions (check-in, close-out,
 * add-note, replace-broker) delegate to BrokerAssignmentService.
 *
 * All SOQL is delegated to selectors per ARCHITECTURE.md §2: Broker_Assignment__c ->
 * BrokerAssignmentSelector, Contact -> ContactSelector, and the Notes reads ->
 * ContentDocumentLinkSelector / ContentNoteSelector. This controller holds no inline SOQL.
 *
 * Thin controller (P6 controller thinning). The write workflows — the DML, the
 * broker-replacement snapshot-and-swap and the savepoint / rollback transaction
 * management — live in BrokerAssignmentService per .claude/rules/apex-layering-rule.md.
 * Every @AuraEnabled method (read and write) maps failures to an AuraHandledException at
 * the LWC boundary (ARCHITECTURE.md §5): the write methods surface the service's typed
 * validation message unchanged and log-then-mask platform DML failures behind a fixed
 * generic string, and the read methods mask any query-time failure the same way.
 */
public with sharing class BrokerAssignmentController {
    public static final Integer WARN_DAYS = 14;
    public static final Integer OVERDUE_DAYS = 21;

    // Fixed, generic user-safe message for a failed write. Never interpolate platform
    // text or exception detail into it (ARCHITECTURE.md §5) — the raw DmlException text
    // leaks field API names and validation-rule internals. The detail goes to the debug
    // log (admin-only); the user gets this. The controller owns it because the
    // AuraHandledException boundary is here, not in the service.
    private static final String WRITE_FAILURE_MESSAGE =
        'This change could not be saved. Check your entry and try again, or contact your administrator.';
    // Fixed, generic user-safe message for a failed read (a query-time or shaping failure).
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

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
        try {
            Kpis k = new Kpis(); k.total=0; k.active=0; k.stale=0; k.leased=0;
            for (Broker_Assignment__c a : queryAll()) {
                k.total++;
                if (a.Status__c == 'Active') k.active++;
                if (a.Status__c == 'Fully Leased') k.leased++;
                if (isStale(a)) k.stale++;
            }
            return k;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.getKpis: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
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
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.getAssignments: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class Portfolio { @AuraEnabled public Integer total; @AuraEnabled public Integer active; @AuraEnabled public Integer leased; @AuraEnabled public Integer disposed; }
    @AuraEnabled(cacheable=true)
    public static Portfolio getPortfolio() {
        try {
            Portfolio p = new Portfolio(); p.total=0; p.active=0; p.leased=0; p.disposed=0;
            for (Broker_Assignment__c a : queryAll()) {
                p.total++;
                if (a.Status__c=='Active') p.active++;
                else if (a.Status__c=='Fully Leased') p.leased++;
                else if (a.Status__c=='Disposed') p.disposed++;
            }
            return p;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.getPortfolio: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class Alerts { @AuraEnabled public Integer stale7; @AuraEnabled public Integer stale30; }
    @AuraEnabled(cacheable=true)
    public static Alerts getAlerts() {
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.getAlerts: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class BrokerCard {
        @AuraEnabled public Id brokerId; @AuraEnabled public String name; @AuraEnabled public String firm;
        @AuraEnabled public Integer active; @AuraEnabled public Integer leased; @AuraEnabled public Integer disposed;
        @AuraEnabled public Integer total;
    }
    @AuraEnabled(cacheable=true)
    public static List<BrokerCard> getScorecard() {
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.getScorecard: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class BrokerTotal {
        @AuraEnabled public Id brokerId; @AuraEnabled public String name; @AuraEnabled public String firm; @AuraEnabled public Integer totalProperties;
    }
    @AuraEnabled(cacheable=true)
    public static List<BrokerTotal> getBrokerTotals() {
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.getBrokerTotals: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
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
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.getDetail: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled
    public static void logCheckIn(Id assignmentId) {
        try {
            BrokerAssignmentService.logCheckIn(assignmentId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.logCheckIn on ' + assignmentId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled
    public static void closeOut(Id assignmentId, String status, Date endDate, String reason) {
        try {
            BrokerAssignmentService.closeOut(assignmentId, status, endDate, reason);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.closeOut on ' + assignmentId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    public class BrokerOption { @AuraEnabled public Id id; @AuraEnabled public String label; }
    @AuraEnabled(cacheable=true)
    public static List<BrokerOption> getBrokerOptions() {
        try {
            List<BrokerOption> out = new List<BrokerOption>();
            for (Contact c : ContactSelector.selectBrokersOrderedByName()) {
                BrokerOption o = new BrokerOption(); o.id=c.Id; o.label = c.Broker_Firm__c == null ? c.Name : (c.Name + ' · ' + c.Broker_Firm__c); out.add(o);
            }
            return out;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.getBrokerOptions: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
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
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.getNotes: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
    // Creates a native Note from free text and links it to the record. The validation and
    // DML live in BrokerAssignmentService; the controller surfaces the service's user-safe
    // validation message unchanged and masks platform DML failures.
    @AuraEnabled
    public static void addNote(Id recordId, String body) {
        try {
            BrokerAssignmentService.addNote(recordId, body);
        } catch (BrokerAssignmentService.BrokerAssignmentException e) {
            // Validation failure — the service's message is already user-safe. Surface it unchanged.
            throw ahe(e.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.addNote on ' + recordId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled
    public static Id replaceBroker(Id assignmentId, Id newBrokerId, Date effectiveDate, String reason, String notes) {
        try {
            return BrokerAssignmentService.replaceBroker(assignmentId, newBrokerId, effectiveDate, reason, notes);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerAssignmentController.replaceBroker on ' + assignmentId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
