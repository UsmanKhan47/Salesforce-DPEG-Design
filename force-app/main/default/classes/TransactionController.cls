public with sharing class TransactionController {

    // Aggregated KPI figures for the Active Transactions header.
    public class TxnKpis {
        @AuraEnabled public Integer activeCount;          // # of Active transactions
        @AuraEnabled public Decimal inContractValue;      // Σ Contract Value (Active)
        @AuraEnabled public Decimal earnestAtRisk;        // Σ Earnest Money where At Risk (Active)
        @AuraEnabled public Integer avgTimeToCloseDays;   // avg(Target Close − Contract Executed) (Active)
        @AuraEnabled public Integer wireApprovalsDue;     // # Active with Wire Approval Due
        @AuraEnabled public Integer missedFeasibilityYtd; // # Feasibility Missed this calendar year
    }

    @AuraEnabled(cacheable=true)
    public static TxnKpis getKpis() {
        TxnKpis k = new TxnKpis();
        k.activeCount = 0;
        k.inContractValue = 0;
        k.earnestAtRisk = 0;
        k.avgTimeToCloseDays = 0;
        k.wireApprovalsDue = 0;
        k.missedFeasibilityYtd = 0;

        Integer ttcSum = 0;
        Integer ttcCount = 0;
        Integer currentYear = Date.today().year();

        for (Transaction__c t : [
            SELECT Status__c, Contract_Value__c, Earnest_Money__c, Earnest_At_Risk__c,
                   Contract_Executed_Date__c, Target_Close_Date__c, Wire_Approval_Due__c,
                   Feasibility_Missed__c, Feasibility_Deadline__c
            FROM Transaction__c
        ]) {
            Boolean isActive = (t.Status__c == 'Active');

            if (isActive) {
                k.activeCount++;
                if (t.Contract_Value__c != null) {
                    k.inContractValue += t.Contract_Value__c;
                }
                if (t.Earnest_At_Risk__c && t.Earnest_Money__c != null) {
                    k.earnestAtRisk += t.Earnest_Money__c;
                }
                if (t.Wire_Approval_Due__c) {
                    k.wireApprovalsDue++;
                }
                if (t.Contract_Executed_Date__c != null && t.Target_Close_Date__c != null) {
                    ttcSum += t.Contract_Executed_Date__c.daysBetween(t.Target_Close_Date__c);
                    ttcCount++;
                }
            }

            // Missed feasibility is a year-to-date count across all transactions.
            if (t.Feasibility_Missed__c && t.Feasibility_Deadline__c != null
                    && t.Feasibility_Deadline__c.year() == currentYear) {
                k.missedFeasibilityYtd++;
            }
        }

        if (ttcCount > 0) {
            k.avgTimeToCloseDays = Integer.valueOf(Math.round((Double) ttcSum / ttcCount));
        }
        return k;
    }

    // One row of the Active Transactions table.
    public class TxnRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String propertyName;
        @AuraEnabled public String stage;
        @AuraEnabled public Decimal price;
        @AuraEnabled public Date targetClose;
        @AuraEnabled public Integer tasksComplete;
        @AuraEnabled public String risk;
        @AuraEnabled public String owner;
    }

    // Overall task posture across Active transactions — sidebar summary cards.
    public class TaskSummary {
        @AuraEnabled public Integer totalTasks;    // Σ Tasks_Total__c
        @AuraEnabled public Integer pendingTasks;  // Σ (Total − Complete), floored at 0
        @AuraEnabled public Integer overdueTasks;  // Σ Tasks_Overdue__c (at-risk)
        @AuraEnabled public Integer wireTasks;     // Σ Wire_Open_Risks__c (open wire verifications)
    }

    @AuraEnabled(cacheable=true)
    public static TaskSummary getTaskSummary() {
        TaskSummary s = new TaskSummary();
        s.totalTasks = 0;
        s.pendingTasks = 0;
        s.overdueTasks = 0;
        s.wireTasks = 0;

        for (Transaction__c t : [
            SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_Overdue__c, Wire_Open_Risks__c
            FROM Transaction__c
            WHERE Status__c = 'Active'
        ]) {
            Integer tot  = t.Tasks_Total__c    != null ? Integer.valueOf(t.Tasks_Total__c)    : 0;
            Integer comp = t.Tasks_Complete__c != null ? Integer.valueOf(t.Tasks_Complete__c) : 0;
            s.totalTasks   += tot;
            s.pendingTasks += Math.max(0, tot - comp);
            s.overdueTasks += t.Tasks_Overdue__c   != null ? Integer.valueOf(t.Tasks_Overdue__c)   : 0;
            s.wireTasks    += t.Wire_Open_Risks__c != null ? Integer.valueOf(t.Wire_Open_Risks__c) : 0;
        }
        return s;
    }

    // One stage of the sidebar donut.
    public class StageSlice {
        @AuraEnabled public String stage;
        @AuraEnabled public Integer count;
    }

    // Stage-wise count of Active transactions for the sidebar donut.
    @AuraEnabled(cacheable=true)
    public static List<StageSlice> getStageBreakdown() {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (Transaction__c t : [
            SELECT Stage__c FROM Transaction__c WHERE Status__c = 'Active'
        ]) {
            String st = String.isBlank(t.Stage__c) ? 'Unspecified' : t.Stage__c;
            counts.put(st, (counts.containsKey(st) ? counts.get(st) : 0) + 1);
        }
        List<StageSlice> out = new List<StageSlice>();
        for (String st : counts.keySet()) {
            StageSlice s = new StageSlice();
            s.stage = st;
            s.count = counts.get(st);
            out.add(s);
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<TxnRow> getActiveTransactions() {
        List<TxnRow> rows = new List<TxnRow>();
        for (Transaction__c t : [
            SELECT Id, Name, Property_Name__c, Stage__c, Contract_Value__c,
                   Target_Close_Date__c, Tasks_Complete__c, Risk__c, Owner_Name__c
            FROM Transaction__c
            WHERE Status__c = 'Active'
            ORDER BY Name
        ]) {
            TxnRow r = new TxnRow();
            r.id = t.Id;
            r.name = t.Name;
            r.propertyName = t.Property_Name__c;
            r.stage = t.Stage__c;
            r.price = t.Contract_Value__c;
            r.targetClose = t.Target_Close_Date__c;
            r.tasksComplete = t.Tasks_Complete__c != null ? Integer.valueOf(t.Tasks_Complete__c) : 0;
            r.risk = t.Risk__c;
            r.owner = t.Owner_Name__c;
            rows.add(r);
        }
        return rows;
    }
}