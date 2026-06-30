public with sharing class OnboardingController {

    private static final String DONE_STAGE = 'Onboarding Complete';
    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }

    // Active = still onboarding (not the terminal stage).
    private static List<Onboarding__c> activeOnboardings() {
        return [
            SELECT Id, Name, Property_Name__c, Stage__c, Status__c,
                   Start_Date__c, Target_Completion_Date__c, Onboarding_Lead__c,
                   Completion_Pct__c, Tasks_Total__c, Tasks_Complete__c, Tasks_In_Progress__c,
                   Tasks_Not_Started__c, Tasks_Blocked__c, Tasks_NA__c, Tasks_Open__c,
                   Tasks_Overdue__c, Tasks_Blocked_Now__c, Tasks_Stalled__c, Tasks_Due_7d__c,
                   Days_To_Onboard__c, Age_Days__c, Oldest_Open_Days__c, Past_Target__c
            FROM Onboarding__c
            WHERE Stage__c != :DONE_STAGE
            ORDER BY Target_Completion_Date__c NULLS LAST
        ];
    }

    public class Kpis {
        @AuraEnabled public Integer propertiesInOnboarding;
        @AuraEnabled public Integer avgCompletionPct;
        @AuraEnabled public Integer overdueTasks;
        @AuraEnabled public Integer avgDaysToOnboard;
    }

    @AuraEnabled(cacheable=true)
    public static Kpis getKpis() {
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
    }

    public class RiskAlerts {
        @AuraEnabled public Integer overdue;
        @AuraEnabled public Integer pastTarget;
        @AuraEnabled public Integer stalled;
        @AuraEnabled public Integer due7d;
    }

    @AuraEnabled(cacheable=true)
    public static RiskAlerts getRiskAlerts() {
        RiskAlerts a = new RiskAlerts();
        a.overdue = 0; a.pastTarget = 0; a.stalled = 0; a.due7d = 0;
        for (Onboarding__c o : activeOnboardings()) {
            a.overdue += (Integer) nz(o.Tasks_Overdue__c);
            if (o.Past_Target__c == true) a.pastTarget += 1;
            a.stalled += (Integer) nz(o.Tasks_Stalled__c);
            a.due7d += (Integer) nz(o.Tasks_Due_7d__c);
        }
        return a;
    }

    public class TimeSla {
        @AuraEnabled public Integer avgDaysToOnboard;
        @AuraEnabled public Integer avgAge;
        @AuraEnabled public Integer pastTarget;
        @AuraEnabled public Integer oldestOpen;
    }

    @AuraEnabled(cacheable=true)
    public static TimeSla getTimeSla() {
        TimeSla t = new TimeSla();
        Decimal dtoSum = 0; Integer dtoCount = 0; Decimal ageSum = 0; Integer ageCount = 0;
        Integer pastTarget = 0; Integer oldest = 0;
        for (Onboarding__c o : activeOnboardings()) {
            if (o.Days_To_Onboard__c != null) { dtoSum += o.Days_To_Onboard__c; dtoCount++; }
            if (o.Age_Days__c != null) { ageSum += o.Age_Days__c; ageCount++; }
            if (o.Past_Target__c == true) pastTarget++;
            if (o.Oldest_Open_Days__c != null && o.Oldest_Open_Days__c > oldest) {
                oldest = (Integer) o.Oldest_Open_Days__c;
            }
        }
        t.avgDaysToOnboard = dtoCount > 0 ? (Integer) Math.round(dtoSum / dtoCount) : 0;
        t.avgAge = ageCount > 0 ? (Integer) Math.round(ageSum / ageCount) : 0;
        t.pastTarget = pastTarget;
        t.oldestOpen = oldest;
        return t;
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
        Map<String, ChecklistGroup> byCat = new Map<String, ChecklistGroup>();
        for (String c : CATEGORY_ORDER) {
            ChecklistGroup g = new ChecklistGroup();
            g.category = c; g.total = 0; g.complete = 0; g.items = new List<ChecklistItem>();
            byCat.put(c, g);
        }
        Date today = Date.today();
        for (Task t : [
            SELECT Id, Subject, Onboarding_Category__c, Onboarding_Status__c, Source_System__c,
                   Task_Owner_Label__c, ActivityDate, Blocked_Reason__c, Description
            FROM Task
            WHERE Onboarding__c = :onboardingId
            ORDER BY Onboarding_Category__c, ActivityDate NULLS LAST
        ]) {
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
    }

    // Mark a checklist task complete (from the interactive checkbox), append any note, and
    // roll the change up onto the parent Onboarding so the rings/bars/KPIs reflect it.
    @AuraEnabled
    public static void completeTask(Id taskId, String notes) {
        Task t = [
            SELECT Id, Onboarding__c, Onboarding_Status__c, Status, Description
            FROM Task WHERE Id = :taskId LIMIT 1
        ];
        t.Onboarding_Status__c = 'Complete';
        t.Status = 'Completed';
        t.ActivityDate = Date.today();
        if (String.isNotBlank(notes)) {
            t.Description = String.isBlank(t.Description) ? notes : (t.Description + '\n\n' + notes);
        }
        update t;
        if (t.Onboarding__c != null) {
            OnboardingTaskRollupService.recalc(new Set<Id>{ t.Onboarding__c });
        }
    }
}