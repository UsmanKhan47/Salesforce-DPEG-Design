/**
 * Backs the leaseNegotiationLog LWC on the Lease Inquiry record page. Reads the
 * append-only Lease_Activity__c log (newest first) and appends a new entry. Saving
 * an update sets the parent's Ball in Court and can advance the Stage to the next
 * step; the Stage Start Date reset is handled by the before-save Stage Timer flow.
 */
public with sharing class LeaseInquiryController {

    private static final List<String> STAGES = new List<String>{
        'Inquiry Received', 'LOI Received', 'LOI Negotiation', 'LOI Signed', 'Lease Drafting', 'Lease Ready', 'Lease Signed'
    };
    private static final List<String> LEASE_STAGES = new List<String>{ 'Draft', 'Prepare/Review', 'Completed' };

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
            SELECT Id, Details__c, Ball_In_Court__c, Entry_DateTime__c, Logged_By__r.Name
            FROM Lease_Activity__c
            WHERE Lease_Inquiry__c = :inquiryId
            ORDER BY Entry_DateTime__c DESC NULLS LAST, Name DESC
        ]) {
            Entry e = new Entry();
            e.id = a.Id;
            e.details = a.Details__c;
            e.ball = a.Ball_In_Court__c;
            e.enteredBy = a.Logged_By__r != null ? a.Logged_By__r.Name : null;
            e.entryDate = a.Entry_DateTime__c;
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

        // MIGRATION (D1) — dual-write Entry_Date__c (legacy, rule-9 violating _Date
        // suffix on a DateTime) and its replacement Entry_DateTime__c from ONE stamp,
        // so the pair can never disagree. Readers stay on Entry_Date__c until D3.
        Datetime entryStamp = System.now();
        insert new Lease_Activity__c(
            Lease_Inquiry__c = inquiryId,
            Details__c = details.trim(),
            Ball_In_Court__c = ball,
            Logged_By__c = UserInfo.getUserId(),
            Entry_Date__c = entryStamp,
            Entry_DateTime__c = entryStamp
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

    // ───────────────── Home page (Lease Activity Tracker) ─────────────────

    public class HomeKpis {
        @AuraEnabled public Integer active = 0;
        @AuraEnabled public Integer waitingLandlord = 0;
        @AuraEnabled public Integer stalled = 0;
        @AuraEnabled public Integer signed = 0;
    }

    @AuraEnabled(cacheable=true)
    public static HomeKpis getHomeKpis() {
        HomeKpis k = new HomeKpis();
        Date today = Date.today();
        Date yearStart = Date.newInstance(today.year(), 1, 1);
        for (Lease_Inquiry__c q : [
            SELECT Status__c, Ball_In_Court__c, Stage_Start_Date__c, Signed_Date__c FROM Lease_Inquiry__c
        ]) {
            Boolean closed = q.Status__c == 'Closed Won' || q.Status__c == 'Closed Lost';
            // Signed Leases (YTD): Closed Won with a Signed Date in the current calendar year.
            if (q.Status__c == 'Closed Won' && q.Signed_Date__c != null && q.Signed_Date__c >= yearStart) k.signed++;
            if (!closed) {
                k.active++;
                if (q.Ball_In_Court__c == 'Landlord') k.waitingLandlord++;
                if (q.Stage_Start_Date__c != null && q.Stage_Start_Date__c.daysBetween(today) > 14) k.stalled++;
            }
        }
        return k;
    }

    public class InquiryRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String tenant;
        @AuraEnabled public String property;
        @AuraEnabled public String broker;
        @AuraEnabled public String stage;
        @AuraEnabled public String ball;
        @AuraEnabled public String status;
        @AuraEnabled public Integer days;
        @AuraEnabled public Boolean closed;
        @AuraEnabled public Datetime received;
    }

    private static InquiryRow toRow(Lease_Inquiry__c q) {
        InquiryRow r = new InquiryRow();
        r.id = q.Id;
        r.tenant = q.Tenant_Name__c;
        r.property = q.Property_Name__c;
        r.broker = q.Broker_Name__c;
        r.stage = q.Stage__c;
        r.ball = q.Ball_In_Court__c;
        r.status = q.Status__c;
        r.closed = q.Status__c == 'Closed Won' || q.Status__c == 'Closed Lost';
        r.days = (!r.closed && q.Stage_Start_Date__c != null) ? q.Stage_Start_Date__c.daysBetween(Date.today()) : null;
        r.received = q.CreatedDate;
        return r;
    }

    @AuraEnabled(cacheable=true)
    public static List<InquiryRow> getRecentInquiries() {
        List<InquiryRow> rows = new List<InquiryRow>();
        for (Lease_Inquiry__c q : [
            SELECT Id, Tenant_Name__c, Property_Name__c, Broker_Name__c, Stage__c, Ball_In_Court__c, Status__c, Stage_Start_Date__c, CreatedDate
            FROM Lease_Inquiry__c
            ORDER BY LastModifiedDate DESC
            LIMIT 6
        ]) {
            rows.add(toRow(q));
        }
        return rows;
    }

    public class StageCount {
        @AuraEnabled public String stage;
        @AuraEnabled public Integer count;
    }

    @AuraEnabled(cacheable=true)
    public static List<StageCount> getPipelineByStage() {
        Map<String, Integer> byStage = new Map<String, Integer>();
        for (String s : STAGES) {
            byStage.put(s, 0);
        }
        // Mirror Portfolio Status: only inquiries from the last 5 years.
        Datetime fiveYearsAgo = Datetime.now().addYears(-5);
        for (Lease_Inquiry__c q : [
            SELECT Stage__c FROM Lease_Inquiry__c WHERE Status__c = 'Active' AND CreatedDate >= :fiveYearsAgo
        ]) {
            if (byStage.containsKey(q.Stage__c)) {
                byStage.put(q.Stage__c, byStage.get(q.Stage__c) + 1);
            }
        }
        List<StageCount> out = new List<StageCount>();
        for (String s : STAGES) {
            StageCount sc = new StageCount();
            sc.stage = s;
            sc.count = byStage.get(s);
            out.add(sc);
        }
        return out;
    }

    // Active deals needing attention: with the landlord, or aging (> 7 days in stage).
    // Oldest-in-stage first; capped at 6.
    @AuraEnabled(cacheable=true)
    public static List<InquiryRow> getAttention() {
        List<InquiryRow> rows = new List<InquiryRow>();
        Date today = Date.today();
        for (Lease_Inquiry__c q : [
            SELECT Id, Tenant_Name__c, Property_Name__c, Broker_Name__c, Stage__c, Ball_In_Court__c, Status__c, Stage_Start_Date__c, CreatedDate
            FROM Lease_Inquiry__c
            WHERE Status__c = 'Active'
            ORDER BY Stage_Start_Date__c ASC NULLS LAST
        ]) {
            Integer d = q.Stage_Start_Date__c != null ? q.Stage_Start_Date__c.daysBetween(today) : 0;
            if (q.Ball_In_Court__c == 'Landlord' || d > 7) {
                rows.add(toRow(q));
                if (rows.size() == 6) {
                    break;
                }
            }
        }
        return rows;
    }

    // ───────────────── Lease status (legal team) for the record page ─────────────────

    public class LeaseStageStep {
        @AuraEnabled public String label;
        @AuraEnabled public Boolean done;
        @AuraEnabled public Boolean current;
    }

    public class LeaseSummary {
        @AuraEnabled public Boolean exists = false;
        @AuraEnabled public Id leaseId;
        @AuraEnabled public String leaseName;
        @AuraEnabled public String stage;
        @AuraEnabled public String legalOwner;
        @AuraEnabled public Date targetDate;
        @AuraEnabled public Date executedDate;
        @AuraEnabled public List<LeaseStageStep> steps = new List<LeaseStageStep>();
    }

    @AuraEnabled(cacheable=true)
    public static LeaseSummary getLeaseSummary(Id inquiryId) {
        LeaseSummary s = new LeaseSummary();
        if (inquiryId == null) {
            return s;
        }
        List<Lease__c> leases = [
            SELECT Id, Name, Stage__c, Legal_Owner__r.Name, Target_Execution_Date__c, Executed_Date__c
            FROM Lease__c
            WHERE Lease_Inquiry__c = :inquiryId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (leases.isEmpty()) {
            return s;
        }
        Lease__c l = leases[0];
        s.exists = true;
        s.leaseId = l.Id;
        s.leaseName = l.Name;
        s.stage = l.Stage__c;
        s.legalOwner = l.Legal_Owner__r != null ? l.Legal_Owner__r.Name : null;
        s.targetDate = l.Target_Execution_Date__c;
        s.executedDate = l.Executed_Date__c;
        Integer idx = LEASE_STAGES.indexOf(l.Stage__c);
        for (Integer i = 0; i < LEASE_STAGES.size(); i++) {
            LeaseStageStep st = new LeaseStageStep();
            st.label = LEASE_STAGES[i];
            st.done = i < idx;
            st.current = i == idx;
            s.steps.add(st);
        }
        return s;
    }
}