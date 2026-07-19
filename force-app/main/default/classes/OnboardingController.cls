/**
 * Backs the Property Management Onboarding dashboard (KPI header, row table, portfolio /
 * risk / SLA cards) and the record-page checklist, plus the checklist complete-and-rollup
 * write for the onboardingChecklist LWC.
 *
 * All SOQL is delegated to OnboardingSelector and TaskSelector per ARCHITECTURE.md §2 —
 * this controller holds no inline SOQL.
 *
 * Thin controller (P6 controller thinning). The checklist completion DML and its rollup
 * orchestration live in OnboardingService per .claude/rules/apex-layering-rule.md;
 * completeTask only marshals input, delegates, and maps failures to an AuraHandledException
 * at the LWC boundary (ARCHITECTURE.md §5). Every @AuraEnabled method (read and write) maps
 * failures the same way: platform detail goes to the debug log (admin-only) and the user
 * gets a fixed, generic message with no exception detail concatenated into it.
 */
public with sharing class OnboardingController {

    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'This information could not be loaded. Refresh the page or contact your administrator.';
    // Fixed, generic user-safe message for an unexpected failed write. Never interpolate
    // platform text or exception detail into it (ARCHITECTURE.md §5).
    private static final String WRITE_FAILURE_MESSAGE =
        'This task could not be updated. Refresh the page and try again, or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }

    // Active = still onboarding (not the terminal stage). All Onboarding__c SOQL
    // lives in OnboardingSelector (ARCHITECTURE.md §2 / apex-layering-rule).
    private static List<Onboarding__c> activeOnboardings() {
        return OnboardingSelector.selectActive();
    }

    public class Kpis {
        @AuraEnabled public Integer propertiesInOnboarding;
        @AuraEnabled public Integer avgCompletionPct;
        @AuraEnabled public Integer overdueTasks;
        @AuraEnabled public Integer avgDaysToOnboard;
    }

    @AuraEnabled(cacheable=true)
    public static Kpis getKpis() {
        try {
            Kpis k = new Kpis();
            Integer count = 0; Decimal totTasks = 0, compTasks = 0; Integer overdue = 0;
            Decimal dtoSum = 0; Integer dtoCount = 0;
            for (Onboarding__c o : activeOnboardings()) {
                count++;
                totTasks += nz(o.Tasks_Total__c);
                compTasks += nz(o.Tasks_Complete__c);
                overdue += (Integer) nz(o.Tasks_Overdue__c);
                if (o.Days_To_Onboard__c != null) { dtoSum += o.Days_To_Onboard__c; dtoCount++; }
            }
            k.propertiesInOnboarding = count;
            k.avgCompletionPct = totTasks > 0 ? (Integer) Math.round(100 * compTasks / totTasks) : 0;
            k.overdueTasks = overdue;
            k.avgDaysToOnboard = dtoCount > 0 ? (Integer) Math.round(dtoSum / dtoCount) : 0;
            return k;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OnboardingController.getKpis: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class Row {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String propertyName;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date targetDate;
        @AuraEnabled public String stage;
        @AuraEnabled public Integer completionPct;
        @AuraEnabled public Integer openTasks;
        @AuraEnabled public String status;
        @AuraEnabled public String owner;
    }

    @AuraEnabled(cacheable=true)
    public static List<Row> getOnboardings() {
        try {
            List<Row> rows = new List<Row>();
            for (Onboarding__c o : activeOnboardings()) {
                Row r = new Row();
                r.id = o.Id; r.name = o.Name; r.propertyName = o.Property_Name__c;
                r.startDate = o.Start_Date__c; r.targetDate = o.Target_Completion_Date__c;
                r.stage = o.Stage__c; r.completionPct = (Integer) nz(o.Completion_Pct__c);
                r.openTasks = (Integer) nz(o.Tasks_Open__c); r.status = o.Status__c;
                r.owner = o.Onboarding_Lead__c;
                rows.add(r);
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OnboardingController.getOnboardings: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class Portfolio {
        @AuraEnabled public Integer tasksTotal;
        @AuraEnabled public Integer complete;
        @AuraEnabled public Integer inProgress;
        @AuraEnabled public Integer notStarted;
        @AuraEnabled public Integer blocked;
        @AuraEnabled public Integer na;
    }

    @AuraEnabled(cacheable=true)
    public static Portfolio getPortfolio() {
        try {
            Portfolio p = new Portfolio();
            p.tasksTotal = 0; p.complete = 0; p.inProgress = 0;
            p.notStarted = 0; p.blocked = 0; p.na = 0;
            for (Onboarding__c o : activeOnboardings()) {
                p.tasksTotal += (Integer) nz(o.Tasks_Total__c);
                p.complete += (Integer) nz(o.Tasks_Complete__c);
                p.inProgress += (Integer) nz(o.Tasks_In_Progress__c);
                p.notStarted += (Integer) nz(o.Tasks_Not_Started__c);
                p.blocked += (Integer) nz(o.Tasks_Blocked__c);
                p.na += (Integer) nz(o.Tasks_NA__c);
            }
            return p;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OnboardingController.getPortfolio: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class RiskAlerts {
        @AuraEnabled public Integer overdue;
        @AuraEnabled public Integer pastTarget;
        @AuraEnabled public Integer stalled;
        @AuraEnabled public Integer due7d;
    }

    @AuraEnabled(cacheable=true)
    public static RiskAlerts getRiskAlerts() {
        try {
            RiskAlerts a = new RiskAlerts();
            a.overdue = 0; a.pastTarget = 0; a.stalled = 0; a.due7d = 0;
            for (Onboarding__c o : activeOnboardings()) {
                a.overdue += (Integer) nz(o.Tasks_Overdue__c);
                if (o.Is_Past_Target__c == true) a.pastTarget += 1;
                a.stalled += (Integer) nz(o.Tasks_Stalled__c);
                a.due7d += (Integer) nz(o.Tasks_Due_7d__c);
            }
            return a;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OnboardingController.getRiskAlerts: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class TimeSla {
        @AuraEnabled public Integer avgDaysToOnboard;
        @AuraEnabled public Integer avgAge;
        @AuraEnabled public Integer pastTarget;
        @AuraEnabled public Integer oldestOpen;
    }

    @AuraEnabled(cacheable=true)
    public static TimeSla getTimeSla() {
        try {
            TimeSla t = new TimeSla();
            Decimal dtoSum = 0; Integer dtoCount = 0; Decimal ageSum = 0; Integer ageCount = 0;
            Integer pastTarget = 0; Integer oldest = 0;
            for (Onboarding__c o : activeOnboardings()) {
                if (o.Days_To_Onboard__c != null) { dtoSum += o.Days_To_Onboard__c; dtoCount++; }
                if (o.Age_Days__c != null) { ageSum += o.Age_Days__c; ageCount++; }
                if (o.Is_Past_Target__c == true) pastTarget++;
                if (o.Oldest_Open_Days__c != null && o.Oldest_Open_Days__c > oldest) {
                    oldest = (Integer) o.Oldest_Open_Days__c;
                }
            }
            t.avgDaysToOnboard = dtoCount > 0 ? (Integer) Math.round(dtoSum / dtoCount) : 0;
            t.avgAge = ageCount > 0 ? (Integer) Math.round(ageSum / ageCount) : 0;
            t.pastTarget = pastTarget;
            t.oldestOpen = oldest;
            return t;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OnboardingController.getTimeSla: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    public class ChecklistItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String sourceSystem;
        @AuraEnabled public String owner;
        @AuraEnabled public Date due;
        @AuraEnabled public String reason;
        @AuraEnabled public Boolean hasNotes;
        @AuraEnabled public Boolean overdue;
    }
    public class ChecklistGroup {
        @AuraEnabled public String category;
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer complete;
        @AuraEnabled public List<ChecklistItem> items;
    }

    private static final List<String> CATEGORY_ORDER = new List<String>{
        'Property Set up','Unit & Tenant Setup','Vendor & Expense Management',
        'NNN Reconciliation & Billing Setup','Tenant Communication & Transition',
        'Performance Tracking','Leasing'
    };

    @AuraEnabled(cacheable=true)
    public static List<ChecklistGroup> getChecklist(Id onboardingId) {
        try {
            Map<String, ChecklistGroup> byCat = new Map<String, ChecklistGroup>();
            for (String c : CATEGORY_ORDER) {
                ChecklistGroup g = new ChecklistGroup();
                g.category = c; g.total = 0; g.complete = 0; g.items = new List<ChecklistItem>();
                byCat.put(c, g);
            }
            Date today = Date.today();
            for (Task t : TaskSelector.selectChecklistByOnboardingId(onboardingId)) {
                ChecklistGroup g = byCat.get(t.Onboarding_Category__c);
                if (g == null) continue;
                ChecklistItem it = new ChecklistItem();
                it.id = t.Id; it.name = t.Subject; it.status = t.Onboarding_Status__c;
                it.sourceSystem = t.Source_System__c; it.owner = t.Task_Owner_Label__c;
                it.due = t.ActivityDate; it.reason = t.Blocked_Reason__c;
                it.hasNotes = String.isNotBlank(t.Description);
                Boolean isOpen = (t.Onboarding_Status__c != 'Complete' && t.Onboarding_Status__c != 'Not Applicable');
                it.overdue = isOpen && t.ActivityDate != null && t.ActivityDate < today;
                g.items.add(it);
                g.total += 1;
                if (t.Onboarding_Status__c == 'Complete') g.complete += 1;
            }
            List<ChecklistGroup> out = new List<ChecklistGroup>();
            for (String c : CATEGORY_ORDER) out.add(byCat.get(c));
            return out;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OnboardingController.getChecklist on ' + onboardingId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    // Mark a checklist task complete (from the interactive checkbox), append any note, and
    // roll the change up onto the parent Onboarding so the rings/bars/KPIs reflect it. The
    // DML + rollup orchestration lives in OnboardingService (P6 controller thinning).
    @AuraEnabled
    public static void completeTask(Id taskId, String notes) {
        try {
            OnboardingService.completeTask(taskId, notes);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OnboardingController.completeTask on ' + taskId
                + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(WRITE_FAILURE_MESSAGE);
        }
    }
}
