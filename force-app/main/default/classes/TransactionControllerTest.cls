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
            'Earnest_Money__c' => 1500000, 'Is_Earnest_At_Risk__c' => true, 'Is_Wire_Approval_Due__c' => true,
            'Contract_Executed_Date__c' => today, 'Target_Close_Date__c' => today.addDays(45),
            'Feasibility_Deadline__c' => today.addDays(20), 'Feasibility_Missed__c' => false,
            'Property_Name__c' => 'Alpha Tower', 'Stage__c' => 'Due Diligence', 'Risk__c' => 'Watch',
            'Tasks_Complete__c' => 42, 'Owner_Name__c' => 'Danish'
        });
        TestDataFactory.applyOverrides(beta, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Value__c' => 41000000,
            'Earnest_Money__c' => 900000, 'Is_Earnest_At_Risk__c' => true, 'Is_Wire_Approval_Due__c' => false,
            'Contract_Executed_Date__c' => today, 'Target_Close_Date__c' => today.addDays(75),
            'Feasibility_Deadline__c' => today.addDays(30), 'Feasibility_Missed__c' => false
        });
        TestDataFactory.applyOverrides(gamma, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Value__c' => 28000000,
            'Earnest_Money__c' => 700000, 'Is_Earnest_At_Risk__c' => false, 'Is_Wire_Approval_Due__c' => true,
            'Contract_Executed_Date__c' => today, 'Target_Close_Date__c' => today.addDays(78),
            'Feasibility_Deadline__c' => today.addDays(40), 'Feasibility_Missed__c' => false
        });
        TestDataFactory.applyOverrides(closed, new Map<String, Object>{
            'Status__c' => 'Closed', 'Contract_Value__c' => 99000000,
            'Earnest_Money__c' => 5000000, 'Is_Earnest_At_Risk__c' => true, 'Is_Wire_Approval_Due__c' => true,
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
        // ⚠ `Status__c` and `Stage__c` below BOTH read 'Closed' and they are DIFFERENT FIELDS
        // carrying coincidentally identical values: Status__c has always had Draft|Active|Closed,
        // and Stage__c's terminal value was renamed 'Closed Won' -> 'Closed' on 2026-08-28.
        // Only Status__c drives the Active-only filter under test here.
        Transaction__c bigClosed = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(bigClosed, new Map<String, Object>{
            'Status__c' => 'Closed', 'Stage__c' => 'Closed', 'Contract_Executed_Date__c' => null,
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
        // ⚠ Status__c 'Closed' and Stage__c 'Closed' are DIFFERENT FIELDS that happen to share a
        // value name since the 2026-08-28 'Closed Won' -> 'Closed' stage rename. The breakdown is
        // filtered on Status__c; the Stage__c key is what the absence assertion below looks for.
        Transaction__c closedTxn = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(closedTxn, new Map<String, Object>{
            'Status__c' => 'Closed', 'Stage__c' => 'Closed', 'Contract_Executed_Date__c' => null
        });
        postClosing.add(closedTxn);
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
        System.assert(!byStage.containsKey('Closed'), 'Closed txn excluded from the Active breakdown');
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
            // Suppress the Day-0 fan-out Flow; irrelevant to this controller.
            // 🔴 THE CLAIM FLAG IS WHAT SUPPRESSES IT (2026-09-03). A7 repointed
            // flows/Transaction_Task_Fanout onto ChecklistFanoutService and moved its second entry
            // filter from Tasks_Fanned_Out__c to Checklist_Fanned_Out__c; M5 then deleted
            // Tasks_Fanned_Out__c entirely. Without Checklist_Fanned_Out__c = true all 251 deals
            // would fan out ~96 checklist rows each.
            // ⚠ AND THE USUAL FIX - nulling Contract_Executed_Date__c, the filter both flow
            // versions share - IS WRONG HERE: getKpis derives avgTimeToCloseDays from
            // Contract_Executed_Date__c.daysBetween(Target_Close_Date__c), so a null date drops
            // ttcCount to zero and the `75` assertion below fails. The date is load-bearing in this
            // method; the claim flag is not read by this controller at all.
            'Checklist_Fanned_Out__c' => true,
            'Is_Wire_Approval_Due__c' => false,
            'Is_Earnest_At_Risk__c' => false
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
        System.assertEquals(0, k.earnestAtRisk, 'No Is_Earnest_At_Risk__c records in this bulk set');
        System.assertEquals(0, k.wireApprovalsDue, 'No Is_Wire_Approval_Due__c records in this bulk set');
        System.assertEquals(75, k.avgTimeToCloseDays, 'Every bulk row has the same 75-day TTC (factory default), so the average is exactly 75');
        System.assertEquals(251, rows.size(), 'getActiveTransactions returns all 251 rows, not capped at 200');
    }

    /**
     * 🔴 THE PRECEDENCE RULE IS THE POINT (added 2026-08-12, live UI testing fix item 3).
     * Property__r.Name (the lookup) must WIN, and Property_Name__c (the legacy text field nothing
     * in the app populates) is only a FALLBACK when the lookup gives nothing. The order must never
     * reverse — a stale hand-typed name must not beat the live lookup. All four combinations are
     * built in one method so the winner in each is asserted against the same fixture set, rather
     * than four separate tests that could each individually pass for the wrong reason.
     *
     * scripts/seed-transactions.apex writes hardcoded Property_Name__c values with NO lookup set,
     * which is exactly the "text only" row below and exactly why the fallback must exist at all.
     */
    @isTest
    static void getActiveTransactions_propertyNamePrecedence_allFourCombinations() {
        Property__c property = TestDataFactory.createProperty(true); // Name = 'Test Property 0'

        Transaction__c bothSet = TestDataFactory.createTransaction(null, property.Id, false);
        TestDataFactory.applyOverrides(bothSet, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Executed_Date__c' => null,
            'Property_Name__c' => 'Stale Hand-Typed Name'
        });

        Transaction__c lookupOnly = TestDataFactory.createTransaction(null, property.Id, false);
        TestDataFactory.applyOverrides(lookupOnly, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Executed_Date__c' => null,
            'Property_Name__c' => null
        });

        Transaction__c textOnly = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(textOnly, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Executed_Date__c' => null,
            'Property_Name__c' => 'Seeded Text Name'
        });

        Transaction__c neitherSet = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(neitherSet, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Executed_Date__c' => null,
            'Property_Name__c' => null
        });

        List<Transaction__c> fixtures =
            new List<Transaction__c>{ bothSet, lookupOnly, textOnly, neitherSet };
        insert fixtures;

        Test.startTest();
        List<TransactionController.TxnRow> rows = TransactionController.getActiveTransactions();
        Test.stopTest();

        Map<Id, TransactionController.TxnRow> byId = new Map<Id, TransactionController.TxnRow>();
        for (TransactionController.TxnRow r : rows) {
            byId.put(r.id, r);
        }

        Assert.areEqual('Test Property 0', byId.get(bothSet.Id).propertyName,
            'Both set: the LOOKUP must win over the stale hand-typed text — a stale name must '
            + 'never beat the live lookup');
        Assert.areEqual('Test Property 0', byId.get(lookupOnly.Id).propertyName,
            'Lookup only: the lookup name is used');
        Assert.areEqual('Seeded Text Name', byId.get(textOnly.Id).propertyName,
            'Text only (the seed-script shape — a hardcoded name with NO lookup): the fallback '
            + 'must supply the name, or every seeded Transaction shows a blank Property column');
        Assert.isNull(byId.get(neitherSet.Id).propertyName,
            'Neither set: null is the honest answer (no property exists on this deal — only '
            + 'LeadConvertService creates a Property__c, so a manually-built deal has none). The '
            + 'placeholder ("—") is the CLIENT\'s decision, not the controller\'s — returning an '
            + 'em-dash here would bake UI text into the server response');
    }

    /**
     * 🔴 tasksTotal MUST STAY NULL, NOT 0, BEFORE THE DAY-0 FAN-OUT (added 2026-08-12). This is the
     * fix for the hardcoded '/75' (record page showed '/82') denominator: ChecklistFanoutService writes
     * Tasks_Total__c = createdForTxn, a count gated by each Transaction's OWN condition fields, so
     * no constant is ever right and the client must be able to tell "not fanned out yet" apart from
     * "fanned out and legitimately produced zero tasks". Coalescing to 0 here would erase that
     * distinction and reintroduce a version of the exact defect this field replaced.
     */
    @isTest
    static void getActiveTransactions_tasksTotal_nullBeforeFanOutIsNeverCoalescedToZero() {
        Transaction__c notFannedOut = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(notFannedOut, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Executed_Date__c' => null,
            'Checklist_Fanned_Out__c' => false, 'Tasks_Total__c' => null, 'Tasks_Complete__c' => null
        });
        Transaction__c fannedOut = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(fannedOut, new Map<String, Object>{
            'Status__c' => 'Active', 'Contract_Executed_Date__c' => null,
            'Checklist_Fanned_Out__c' => true, 'Tasks_Total__c' => 42, 'Tasks_Complete__c' => 10
        });
        insert new List<Transaction__c>{ notFannedOut, fannedOut };

        Test.startTest();
        List<TransactionController.TxnRow> rows = TransactionController.getActiveTransactions();
        Test.stopTest();

        Map<Id, TransactionController.TxnRow> byId = new Map<Id, TransactionController.TxnRow>();
        for (TransactionController.TxnRow r : rows) {
            byId.put(r.id, r);
        }

        Assert.isNull(byId.get(notFannedOut.Id).tasksTotal,
            'Not yet fanned out: tasksTotal must be NULL, never 0 — a coalesced 0 is '
            + 'indistinguishable from a fanned-out Transaction that legitimately produced no tasks');
        Assert.areEqual(42, byId.get(fannedOut.Id).tasksTotal,
            'Fanned out: tasksTotal must carry the PER-ROW denominator (42 here), never a shared '
            + 'constant like the retired hardcoded 75/82');
    }

    // A bare Standard User with no DPEG perm sets: WITH USER_MODE SOQL on the custom
    // Transaction__c object (no object access) throws, exercising each read method's
    // failure catch which maps it to a user-safe AuraHandledException (P6 boundaries).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.txn.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    /**
     * Covers the read-failure catch on all four @AuraEnabled reads: under a bare Standard
     * User, WITH USER_MODE on the custom Transaction__c object throws (no object access),
     * and the controller maps it to a user-safe AuraHandledException. Its own method because
     * bareUser() inserts a User (setup DML); the reads throw at the query, so no record DML
     * runs here (avoids MIXED_DML_OPERATION).
     */
    @isTest
    static void readCatchesThrowAuraHandledException() {
        User u = bareUser();
        System.runAs(u) {
            Test.startTest();
            try { TransactionController.getKpis(); Assert.fail('getKpis should throw under a bare user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getKpis maps read failure to AuraHandledException'); }
            try { TransactionController.getTaskSummary(); Assert.fail('getTaskSummary should throw under a bare user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getTaskSummary maps read failure to AuraHandledException'); }
            try { TransactionController.getStageBreakdown(); Assert.fail('getStageBreakdown should throw under a bare user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getStageBreakdown maps read failure to AuraHandledException'); }
            try { TransactionController.getActiveTransactions(); Assert.fail('getActiveTransactions should throw under a bare user'); }
            catch (AuraHandledException e) { Assert.isNotNull(e, 'getActiveTransactions maps read failure to AuraHandledException'); }
            Test.stopTest();
        }
    }
}
