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
        List<Transaction__c> rows = TestDataFactory.createTransactions(5, false);
        Transaction__c alpha = rows[0];
        Transaction__c beta = rows[1];
        Transaction__c gamma = rows[2];
        Transaction__c closed = rows[3];
        Transaction__c feasibilityMissed = rows[4];

        TestDataFactory.applyOverrides(alpha, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Value__c' => 52000000,
            'Earnest_Money__c' => 1500000, 'Earnest_At_Risk__c' => true, 'Wire_Approval_Due__c' => true,
            'Contract_Executed_Date__c' => today, 'Target_Close_Date__c' => today.addDays(45),
            'Feasibility_Deadline__c' => today.addDays(20), 'Feasibility_Missed__c' => false,
            'Property_Name__c' => 'Alpha Tower', 'Stage__c' => 'Due Diligence', 'Risk__c' => 'Watch',
            'Tasks_Complete__c' => 42, 'Owner_Name__c' => 'Danish'
        });
        TestDataFactory.applyOverrides(beta, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Value__c' => 41000000,
            'Earnest_Money__c' => 900000, 'Earnest_At_Risk__c' => true, 'Wire_Approval_Due__c' => false,
            'Contract_Executed_Date__c' => today, 'Target_Close_Date__c' => today.addDays(75),
            'Feasibility_Deadline__c' => today.addDays(30), 'Feasibility_Missed__c' => false
        });
        TestDataFactory.applyOverrides(gamma, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Value__c' => 28000000,
            'Earnest_Money__c' => 700000, 'Earnest_At_Risk__c' => false, 'Wire_Approval_Due__c' => true,
            'Contract_Executed_Date__c' => today, 'Target_Close_Date__c' => today.addDays(78),
            'Feasibility_Deadline__c' => today.addDays(40), 'Feasibility_Missed__c' => false
        });
        TestDataFactory.applyOverrides(closed, new Map<String, Object>{
            'Status__c' => 'Closed', 'Contract_Value__c' => 99000000,
            'Earnest_Money__c' => 5000000, 'Earnest_At_Risk__c' => true, 'Wire_Approval_Due__c' => true,
            'Contract_Executed_Date__c' => today.addDays(-200), 'Target_Close_Date__c' => today.addDays(-120)
        });
        TestDataFactory.applyOverrides(feasibilityMissed, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Value__c' => null,
            'Contract_Executed_Date__c' => null, 'Target_Close_Date__c' => null,
            'Feasibility_Deadline__c' => today.addDays(-5), 'Feasibility_Missed__c' => true
        });

        insert rows;
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
    static void testKpis_noTransactions_returnsAllZero() {
        delete [SELECT Id FROM Transaction__c];

        Test.startTest();
        TransactionController.TxnKpis k = TransactionController.getKpis();
        Test.stopTest();

        System.assertEquals(0, k.activeCount, 'No transactions at all');
        System.assertEquals(0, k.inContractValue, 'Zero contract value with nothing Active');
        System.assertEquals(0, k.earnestAtRisk, 'Zero earnest at risk with nothing Active');
        System.assertEquals(0, k.wireApprovalsDue, 'Zero wire approvals due');
        System.assertEquals(0, k.avgTimeToCloseDays, 'Average stays 0 when there is no data to average (ttcCount = 0 branch)');
        System.assertEquals(0, k.missedFeasibilityYtd, 'Zero feasibility misses');
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
        Transaction__c bigClosed = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(bigClosed, new Map<String, Object>{
            'Status__c' => 'Closed', 'Stage__c' => 'Closed Won', 'Contract_Executed_Date__c' => null,
            'Tasks_Total__c' => 999, 'Tasks_Complete__c' => 0, 'Tasks_Overdue__c' => 500, 'Wire_Open_Risks__c' => 99
        });
        insert bigClosed;

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
        List<Transaction__c> postClosing = TestDataFactory.createTransactions(3, false);
        TestDataFactory.applyOverrides(postClosing, new Map<String, Object>{
            'Status__c' => 'Active', 'Stage__c' => 'Post-Closing', 'Contract_Executed_Date__c' => null
        });
        Transaction__c closedWon = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(closedWon, new Map<String, Object>{
            'Status__c' => 'Closed', 'Stage__c' => 'Closed Won', 'Contract_Executed_Date__c' => null
        });
        postClosing.add(closedWon);
        insert postClosing;

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

    /**
     * Bulk: 251 Active Transactions in one DML, proving the controller's aggregation loops
     * (no SOQL in a loop, no list truncation) hold at scale per .claude/rules/bulk-test-rule.md.
     * Starts from a clean slate so the count assertions aren't coupled to @testSetup's fixture.
     */
    @isTest
    static void testKpisAndActiveList_bulk251ActiveTransactions() {
        delete [SELECT Id FROM Transaction__c];

        List<Transaction__c> bulkTxns = TestDataFactory.createTransactions(251, false);
        TestDataFactory.applyOverrides(bulkTxns, new Map<String, Object>{
            'Status__c' => 'Active',
            'Tasks_Fanned_Out__c' => true, // suppress the Day-0 fan-out Flow; irrelevant to this controller
            'Wire_Approval_Due__c' => false,
            'Earnest_At_Risk__c' => false
        });
        insert bulkTxns;

        Decimal expectedContractValue = 0;
        for (Transaction__c t : bulkTxns) {
            expectedContractValue += t.Contract_Value__c;
        }

        Test.startTest();
        TransactionController.TxnKpis k = TransactionController.getKpis();
        List<TransactionController.TxnRow> rows = TransactionController.getActiveTransactions();
        Test.stopTest();

        System.assertEquals(251, k.activeCount, 'All 251 bulk-inserted Transactions are Active and counted without truncation');
        System.assertEquals(expectedContractValue, k.inContractValue, 'Σ contract value sums correctly across all 251 records');
        System.assertEquals(0, k.earnestAtRisk, 'No Earnest_At_Risk__c records in this bulk set');
        System.assertEquals(0, k.wireApprovalsDue, 'No Wire_Approval_Due__c records in this bulk set');
        System.assertEquals(75, k.avgTimeToCloseDays, 'Every bulk row has the same 75-day TTC (factory default), so the average is exactly 75');
        System.assertEquals(251, rows.size(), 'getActiveTransactions returns all 251 rows, not capped at 200');
    }
}
