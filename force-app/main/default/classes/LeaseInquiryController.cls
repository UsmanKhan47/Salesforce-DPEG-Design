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
 * Thin controller (P6 controller thinning). The append-an-update workflow — the DML
 * across three objects, the stage-advance rule and the savepoint / rollback
 * transaction management — lives in LeaseInquiryService per
 * .claude/rules/apex-layering-rule.md. addUpdate() only marshals input, delegates to
 * the service, and maps the service's typed exceptions to an AuraHandledException at
 * the LWC boundary (ARCHITECTURE.md §5). The read methods below shape selector results
 * into view DTOs and hold no DML.
 */
public with sharing class LeaseInquiryController {

    private static final List<String> LEASE_STAGES = new List<String>{ 'Draft', 'Prepare/Review', 'Completed' };

    // The user-safe message for a failed save. Fixed and generic on purpose — never
    // interpolate platform text or exception detail into it (ARCHITECTURE.md §5). The test
    // asserts the literal rather than this constant, so a text change has to be a deliberate
    // edit in two places instead of a silent tautology. The controller owns this message
    // because the AuraHandledException boundary is here, not in the service.
    private static final String DML_FAILURE_MESSAGE =
        'This update could not be saved. Check your entry and try again, or contact your administrator.';

    // Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Same policy as
    // DML_FAILURE_MESSAGE: never interpolate platform text or exception detail into it — a
    // selector failure (FLS/sharing) must not leak field API names or rule internals to the page.
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';

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
        try {
            LogView v = new LogView();
            v.entries = new List<Entry>();
            if (inquiryId == null) {
                return v;
            }
            Lease_Inquiry__c inq = LeaseInquirySelector.selectRequiredById(inquiryId);
            v.stage = inq.Stage__c;
            v.ballInCourt = inq.Ball_In_Court__c;
            v.closed = inq.Status__c == 'Closed Won' || inq.Status__c == 'Closed Lost';
            Integer idx = LeaseInquiryService.STAGES.indexOf(inq.Stage__c);
            v.canAdvance = !v.closed && idx >= 0 && idx < LeaseInquiryService.STAGES.size() - 1;
            v.nextStage = v.canAdvance ? LeaseInquiryService.STAGES[idx + 1] : null;
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseInquiryController.getLog on ' + inquiryId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
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
        try {
            return LeaseInquiryService.addUpdate(
                inquiryId, details, ball, advance, reminder, reminderName, reminderDate);
        } catch (LeaseInquiryService.LeaseInquiryException e) {
            // Validation failure — the service's message is already user-safe. Surface it
            // unchanged through the AuraHandledException boundary (ARCHITECTURE.md §5).
            throw ahe(e.getMessage());
        } catch (DmlException e) {
            // The raw platform text is user-VISIBLE but not user-SAFE: a validation rule or an
            // FLS failure leaks field API names and rule internals to whoever is on the page.
            // ARCHITECTURE.md §5 requires a user-safe message at the LWC boundary, so the detail
            // goes to the debug log (admin-only) and the user gets a fixed, generic string with
            // no exception detail concatenated into it. The service has already rolled back.
            System.debug(LoggingLevel.ERROR, 'LeaseInquiryController.addUpdate DML failure on '
                + inquiryId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(DML_FAILURE_MESSAGE);
        }
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
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseInquiryController.getHomeKpis: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
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
        try {
            List<InquiryRow> rows = new List<InquiryRow>();
            for (Lease_Inquiry__c q : LeaseInquirySelector.selectRecent()) {
                rows.add(toRow(q));
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseInquiryController.getRecentInquiries: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class StageCount {
        @AuraEnabled public String stage;
        @AuraEnabled public Integer count;
    }

    @AuraEnabled(cacheable=true)
    public static List<StageCount> getPipelineByStage() {
        try {
            Map<String, Integer> byStage = new Map<String, Integer>();
            for (String s : LeaseInquiryService.STAGES) {
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
            for (String s : LeaseInquiryService.STAGES) {
                StageCount sc = new StageCount();
                sc.stage = s;
                sc.count = byStage.get(s);
                out.add(sc);
            }
            return out;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseInquiryController.getPipelineByStage: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    // Active deals needing attention: with the landlord, or aging (> 7 days in stage).
    // Oldest-in-stage first; capped at 6.
    @AuraEnabled(cacheable=true)
    public static List<InquiryRow> getAttention() {
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseInquiryController.getAttention: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
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
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'LeaseInquiryController.getLeaseSummary on ' + inquiryId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}