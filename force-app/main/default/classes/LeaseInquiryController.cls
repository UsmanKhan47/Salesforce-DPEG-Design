/**
 * Backs the leaseNegotiationLog LWC on the Lease Inquiry record page. Reads the
 * append-only Lease_Activity__c log (newest first) and appends a new entry. Saving
 * an update sets the parent's Ball in Court and can advance the Stage to the next
 * step; the Stage Start Date reset is handled by the before-save Stage Timer flow.
 *
 * All SOQL is delegated to selectors per ARCHITECTURE.md §2 (P4 cleanup wave F1):
 * Lease_Inquiry__c -> LeaseInquirySelector, Lease_Activity__c -> LeaseActivitySelector,
 * Lease__c -> LeaseSelector. This controller holds no inline SOQL.
 *
 * KNOWN LAYERING DEVIATION — an accepted deferral, NOT a sanctioned pattern.
 * .claude/rules/apex-layering-rule.md scopes a Controller to "Thin: call service, catch
 * AuraHandledException" and prohibits business logic. addUpdate() breaches that contract:
 * it carries the stage-advance rule, DML across three objects, and its own savepoint /
 * rollback transaction management. That is Service work and belongs behind a
 * LeaseInquiryService. It remains here only because the P4 cleanup wave scoped itself to
 * SOQL extraction and consciously left DML in place. The layering rule does not permit
 * this arrangement; it is simply not fixed yet. Do not copy this shape into a new
 * controller, and do not cite this class as precedent.
 */
public with sharing class LeaseInquiryController {

    private static final List<String> STAGES = new List<String>{
        'Inquiry Received', 'LOI Received', 'LOI Negotiation', 'LOI Signed', 'Lease Drafting', 'Lease Ready', 'Lease Signed'
    };
    private static final List<String> LEASE_STAGES = new List<String>{ 'Draft', 'Prepare/Review', 'Completed' };

    // The user-safe message for a failed save. Fixed and generic on purpose — never
    // interpolate platform text or exception detail into it (ARCHITECTURE.md §5). The test
    // asserts the literal rather than this constant, so a text change has to be a deliberate
    // edit in two places instead of a silent tautology.
    private static final String DML_FAILURE_MESSAGE =
        'This update could not be saved. Check your entry and try again, or contact your administrator.';

    // Task.Subject is a 255-char combobox (verified against the org: 255 inserts, 256 fails
    // with 'Subject: data value too large'). The composer's max-length="255" is a
    // client-side control only and binds no other caller.
    private static final Integer REMINDER_NAME_MAX = 255;

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
        Lease_Inquiry__c inq = LeaseInquirySelector.selectRequiredById(inquiryId);
        v.stage = inq.Stage__c;
        v.ballInCourt = inq.Ball_In_Court__c;
        v.closed = inq.Status__c == 'Closed Won' || inq.Status__c == 'Closed Lost';
        Integer idx = STAGES.indexOf(inq.Stage__c);
        v.canAdvance = !v.closed && idx >= 0 && idx < STAGES.size() - 1;
        v.nextStage = v.canAdvance ? STAGES[idx + 1] : null;
        for (Lease_Activity__c a : LeaseActivitySelector.selectByInquiryId(inquiryId)) {
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

    /**
     * Appends a log entry, optionally sets the parent's Ball in Court / advances the Stage,
     * and optionally raises a standard Task as a reminder against the INQUIRY.
     *
     * The reminder Task targets the Lease Inquiry (WhatId) because Lease_Inquiry__c has
     * activities enabled and Lease_Activity__c does not — the log entry itself cannot carry
     * a Task. Only Subject / ActivityDate / OwnerId / WhatId are set: IsReminderSet and
     * ReminderDateTime are deliberately left unset (no bell popup was requested), and
     * Status / Priority / Description are left to their field defaults.
     *
     * @param inquiryId    the Lease Inquiry being logged against; required
     * @param details      what changed; required, trimmed onto Details__c
     * @param ball         who the ball is in court with next; sets the parent when non-blank
     * @param advance      true to move the parent to the next Stage (ignored when closed)
     * @param reminder     true to create the reminder Task; null/false creates nothing
     * @param reminderName reminder Task Subject; required when reminder is true
     * @param reminderDate reminder Task ActivityDate (Due Date, date-only); required when reminder is true
     * @return the inquiry Id, so the caller can refresh the record
     */
    @AuraEnabled
    public static Id addUpdate(Id inquiryId, String details, String ball, Boolean advance,
                               Boolean reminder, String reminderName, Date reminderDate) {
        if (inquiryId == null) {
            throw ahe('No inquiry specified.');
        }
        if (String.isBlank(details)) {
            throw ahe('Enter what changed before saving.');
        }
        // Server-side length guard. Without it, a caller other than the composer (Flow, API,
        // a future component) that passes an over-length name fails on the Task insert with
        // STRING_TOO_LONG and gets DML_FAILURE_MESSAGE — a generic string that names nothing
        // the user can act on. Measured on the TRIMMED value, because reminderName.trim() is
        // what the Task insert below actually stores: a 250-char name padded to 260 with
        // whitespace fits, and must not be rejected here.
        if (reminder == true && reminderName != null
                && reminderName.trim().length() > REMINDER_NAME_MAX) {
            throw ahe('The reminder name is too long. Shorten it to '
                + REMINDER_NAME_MAX + ' characters or fewer.');
        }
        Lease_Inquiry__c inq = LeaseInquirySelector.selectStageStatusById(inquiryId);
        Boolean closed = inq.Status__c == 'Closed Won' || inq.Status__c == 'Closed Lost';

        // The log entry, the parent update and the reminder Task are one unit of work: a
        // caught DmlException converted to AuraHandledException at the LWC boundary
        // (ARCHITECTURE.md §5) suppresses the platform's automatic rollback, which would
        // otherwise leave the Lease_Activity__c committed without its Task.
        Savepoint sp = Database.setSavepoint();
        try {
            // Entry_DateTime__c is the ARCHITECTURE.md §1 rule-9 stamp for this log entry.
            Datetime entryStamp = System.now();
            insert new Lease_Activity__c(
                Lease_Inquiry__c = inquiryId,
                Details__c = details.trim(),
                Ball_In_Court__c = ball,
                Logged_By__c = UserInfo.getUserId(),
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

            if (reminder == true) {
                // Backstops the composer's client-side validation; it does not replace it.
                if (String.isBlank(reminderName) || reminderDate == null) {
                    throw ahe('Add a reminder name and due date, or clear the reminder.');
                }
                insert new Task(
                    Subject = reminderName.trim(),
                    ActivityDate = reminderDate,
                    OwnerId = UserInfo.getUserId(),
                    WhatId = inquiryId
                );
            }
        } catch (AuraHandledException e) {
            // Already user-safe — roll back explicitly, since catching it here means the
            // platform will not do it for us, then surface it unchanged.
            Database.rollback(sp);
            throw e;
        } catch (DmlException e) {
            Database.rollback(sp);
            // The raw platform text (e.getDmlMessage(0)) is user-VISIBLE but not user-SAFE:
            // a validation rule or an FLS failure leaks field API names and rule internals to
            // whoever is on the page. ARCHITECTURE.md §5 requires a user-safe message at the
            // LWC boundary, so the detail goes to the debug log (admin-only) and the user gets
            // a fixed, generic string with no exception detail concatenated into it.
            System.debug(LoggingLevel.ERROR, 'LeaseInquiryController.addUpdate DML failure on '
                + inquiryId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(DML_FAILURE_MESSAGE);
        }
        return inquiryId;
    }

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
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
        for (Lease_Inquiry__c q : LeaseInquirySelector.selectForKpis()) {
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
        for (Lease_Inquiry__c q : LeaseInquirySelector.selectRecent()) {
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
        for (Lease_Inquiry__c q : LeaseInquirySelector.selectActiveStagesCreatedSince(fiveYearsAgo)) {
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
        for (Lease_Inquiry__c q : LeaseInquirySelector.selectActive()) {
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
        Lease__c l = LeaseSelector.selectMostRecentByInquiryId(inquiryId);
        if (l == null) {
            return s;
        }
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