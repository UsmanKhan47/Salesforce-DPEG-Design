@isTest
private class TransactionControllerTest {
    @testSetup
    static void setup() {
        Date today = Date.today();
        // 3 Active transactions:
        //  A: $52M, earnest $1.5M AT RISK, wire due,  TTC 45d
        //  B: $41M, earnest $0.9M AT RISK,            TTC 75d
        //  C: $28M, earnest $0.7M (not at risk), wire due, TTC 78d
        //   → activeCount 3, inContract $121M, earnestAtRisk $2.4M,
        //     wireApprovalsDue 2, avgTTC round((45+75+78)/3)=66
        // Plus 1 Closed (ignored) and 1 feasibility-missed-this-year (YTD count 1).
        insert new List<Transaction__c>{
            new Transaction__c(Status__c = 'Active', Contract_Value__c = 52000000,
                Earnest_Money__c = 1500000, Earnest_At_Risk__c = true, Wire_Approval_Due__c = true,
                Contract_Executed_Date__c = today, Target_Close_Date__c = today.addDays(45),
                Feasibility_Deadline__c = today.addDays(20), Feasibility_Missed__c = false,
                Property_Name__c = 'Alpha Tower', Stage__c = 'Due Diligence', Risk__c = 'Watch',
                Tasks_Complete__c = 42, Owner_Name__c = 'Danish'),
            new Transaction__c(Status__c = 'Active', Contract_Value__c = 41000000,
                Earnest_Money__c = 900000, Earnest_At_Risk__c = true, Wire_Approval_Due__c = false,
                Contract_Executed_Date__c = today, Target_Close_Date__c = today.addDays(75),
                Feasibility_Deadline__c = today.addDays(30), Feasibility_Missed__c = false),
            new Transaction__c(Status__c = 'Active', Contract_Value__c = 28000000,
                Earnest_Money__c = 700000, Earnest_At_Risk__c = false, Wire_Approval_Due__c = true,
                Contract_Executed_Date__c = today, Target_Close_Date__c = today.addDays(78),
                Feasibility_Deadline__c = today.addDays(40), Feasibility_Missed__c = false),
            new Transaction__c(Status__c = 'Closed', Contract_Value__c = 99000000,
                Earnest_Money__c = 5000000, Earnest_At_Risk__c = true, Wire_Approval_Due__c = true,
                Contract_Executed_Date__c = today.addDays(-200), Target_Close_Date__c = today.addDays(-120)),
            new Transaction__c(Status__c = 'Active', Contract_Value__c = null,
                Feasibility_Deadline__c = today.addDays(-5), Feasibility_Missed__c = true)
        };
    }

    @isTest
    static void testKpis() {
        Test.startTest();
        TransactionController.TxnKpis k = TransactionController.getKpis();
        Test.stopTest();

        System.assertEquals(4, k.activeCount, 'Four Active transactions (one with null value still counts)');
        System.assertEquals(121000000, k.inContractValue, 'Σ contract value of the 3 valued Active txns');
        System.assertEquals(2400000, k.earnestAtRisk, 'Σ earnest where At Risk = 1.5M + 0.9M');
        System.assertEquals(2, k.wireApprovalsDue, 'Two Active txns flagged Wire Approval Due');
        System.assertEquals(66, k.avgTimeToCloseDays, 'round((45+75+78)/3) = 66');
        System.assertEquals(1, k.missedFeasibilityYtd, 'One feasibility missed this calendar year');
    }

    @isTest
    static void testActiveList() {
        Test.startTest();
        List<TransactionController.TxnRow> rows = TransactionController.getActiveTransactions();
        Test.stopTest();

        System.assertEquals(4, rows.size(), 'Four Active transactions returned (Closed one excluded)');

        // Day-0 fan-out automation may recompute Tasks_Complete__c after insert, so compare the
        // mapped row value against the record's live rollup rather than the literal insert value.
        Transaction__c alphaLive = [
            SELECT Tasks_Complete__c FROM Transaction__c WHERE Property_Name__c = 'Alpha Tower' LIMIT 1
        ];
        Integer alphaComplete = alphaLive.Tasks_Complete__c != null
            ? Integer.valueOf(alphaLive.Tasks_Complete__c) : 0;

        Boolean foundAlpha = false;
        for (TransactionController.TxnRow r : rows) {
            if (r.propertyName == 'Alpha Tower') {
                foundAlpha = true;
                System.assertEquals('Due Diligence', r.stage, 'Stage maps through');
                System.assertEquals('Watch', r.risk, 'Risk maps through');
                System.assertEquals(alphaComplete, r.tasksComplete, 'Tasks complete maps through from the live rollup');
                System.assertEquals('Danish', r.owner, 'Owner maps through');
            }
        }
        System.assert(foundAlpha, 'Alpha Tower row should be present');
    }

    @isTest
    static void testTaskSummary() {
        // A Closed txn with large rollups must NOT leak into the Active-only summary.
        insert new Transaction__c(Status__c = 'Closed', Stage__c = 'Closed Won',
            Tasks_Total__c = 999, Tasks_Complete__c = 0, Tasks_Overdue__c = 500, Wire_Open_Risks__c = 99);

        // Expected aggregate computed from the same Active set, so the assertions hold regardless of
        // how many tasks the Day-0 fan-out created for the setup transactions.
        Integer expTotal = 0, expPending = 0, expOver = 0, expWire = 0;
        for (Transaction__c t : [
            SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_Overdue__c, Wire_Open_Risks__c
            FROM Transaction__c WHERE Status__c = 'Active'
        ]) {
            Integer tot  = t.Tasks_Total__c    != null ? Integer.valueOf(t.Tasks_Total__c)    : 0;
            Integer comp = t.Tasks_Complete__c != null ? Integer.valueOf(t.Tasks_Complete__c) : 0;
            expTotal   += tot;
            expPending += Math.max(0, tot - comp);
            expOver    += t.Tasks_Overdue__c   != null ? Integer.valueOf(t.Tasks_Overdue__c)   : 0;
            expWire    += t.Wire_Open_Risks__c != null ? Integer.valueOf(t.Wire_Open_Risks__c) : 0;
        }

        Test.startTest();
        TransactionController.TaskSummary s = TransactionController.getTaskSummary();
        Test.stopTest();

        // Equality against the Active-only expectation also proves the Closed row (1000) is excluded.
        System.assertEquals(expTotal,   s.totalTasks,   'Σ Tasks_Total over Active only');
        System.assertEquals(expPending, s.pendingTasks, 'Σ max(0, Total − Complete) over Active');
        System.assertEquals(expOver,    s.overdueTasks, 'Σ Tasks_Overdue over Active');
        System.assertEquals(expWire,    s.wireTasks,    'Σ Wire_Open_Risks over Active');
    }

    @isTest
    static void testStageBreakdown() {
        // 'Post-Closing' is unused by @testSetup, so its bucket isolates exactly to these inserts.
        insert new List<Transaction__c>{
            new Transaction__c(Status__c = 'Active', Stage__c = 'Post-Closing'),
            new Transaction__c(Status__c = 'Active', Stage__c = 'Post-Closing'),
            new Transaction__c(Status__c = 'Active', Stage__c = 'Post-Closing'),
            new Transaction__c(Status__c = 'Closed', Stage__c = 'Closed Won')
        };
        Integer activeTotal = [SELECT COUNT() FROM Transaction__c WHERE Status__c = 'Active'];

        Test.startTest();
        List<TransactionController.StageSlice> slices = TransactionController.getStageBreakdown();
        Test.stopTest();

        Map<String, Integer> byStage = new Map<String, Integer>();
        Integer gotTotal = 0;
        for (TransactionController.StageSlice s : slices) {
            byStage.put(s.stage, s.count);
            gotTotal += s.count;
        }

        System.assertEquals(3, byStage.get('Post-Closing'), 'Exactly the three Active Post-Closing txns');
        System.assert(!byStage.containsKey('Closed Won'), 'Closed txn excluded from the Active breakdown');
        System.assertEquals(activeTotal, gotTotal, 'Every Active transaction counted exactly once');
    }
}