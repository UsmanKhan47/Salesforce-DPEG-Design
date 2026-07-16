/**
 * Tests ContractExecutionService: executing the PSA stamps the parent
 * Opportunity (Day 0), creates exactly ONE Transaction (arming the existing
 * Day-0 task fan-out), and never duplicates on re-execution.
 */
@isTest
private class ContractExecutionServiceTest {

    private static Contract_Review__c dealAtPsa() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        // Entering PSA auto-creates the Contract Review + Primary_Contract__c stamp.
        o.StageName = 'PSA';
        update o;
        return [SELECT Id, Opportunity__c FROM Contract_Review__c WHERE Opportunity__c = :o.Id];
    }

    @isTest
    static void executionStampsOppAndOpensTransaction() {
        Contract_Review__c cr = dealAtPsa();
        cr.Contract_Value__c = 12000000;
        update cr;

        Test.startTest();
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Test.stopTest();

        Opportunity o = [
            SELECT StageName, Contract_Signed__c, Contract_Executed_Date__c, Deal_Status__c, Deal_Bucket__c
            FROM Opportunity WHERE Id = :cr.Opportunity__c
        ];
        // The deal stays at the coarse PSA stage; Deal_Status marks it executed.
        System.assertEquals('PSA', o.StageName, 'Deal stays at PSA on execution');
        System.assert(o.Contract_Signed__c, 'Contract Signed stamped');
        System.assertNotEquals(null, o.Contract_Executed_Date__c, 'Day 0 stamped');
        System.assertEquals('Contract Signed', o.Deal_Status__c, 'Deal status stamped');
        System.assertEquals('PSA', o.Deal_Bucket__c, 'Tracker bucket follows');

        List<Transaction__c> txns = [
            SELECT Status__c, Stage__c, Contract_Value__c, Contract_Executed_Date__c
            FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c
        ];
        System.assertEquals(1, txns.size(), 'Exactly one Transaction created');
        System.assertEquals('Active', txns[0].Status__c, 'Transaction opens Active');
        System.assertEquals(12000000, txns[0].Contract_Value__c, 'Contract value carried over');
        System.assertNotEquals(null, txns[0].Contract_Executed_Date__c,
            'Executed date set on the Transaction - arms the Day-0 fan-out flow');

        // Contract Review itself synced by the before-save flow.
        cr = [SELECT Stage__c, Execution_Date__c FROM Contract_Review__c WHERE Id = :cr.Id];
        System.assertEquals('Contract Execution', cr.Stage__c, 'CR stage synced');
        System.assertEquals(Date.today(), cr.Execution_Date__c, 'CR execution date stamped');
    }

    @isTest
    static void reExecutionNeverDuplicatesTheTransaction() {
        Contract_Review__c cr = dealAtPsa();
        cr.Negotiation_Status__c = 'Executed';
        update cr;

        Test.startTest();
        cr.Negotiation_Status__c = 'Revised';
        update cr;
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c],
            'Re-executing must not open a second Transaction');
    }

    /**
     * Bulk-safety per .claude/rules/bulk-test-rule.md: 251 Contract Reviews
     * executed in one transaction (forces a second 200-record trigger batch).
     *
     * This test found TWO INDEPENDENT governor breaks in the execution cascade.
     * Do not shrink the record count, weaken the assertions, or inject
     * TaskFanoutService.taskDefsOverride to make it pass - it must run against
     * production-representative data (82 checklist defs) or it proves nothing.
     *
     * Both breaks are fixed; the numbers below are what was measured on
     * DPEG-Acq-5 before the fix, and are recorded so the next reader does not
     * have to re-derive them:
     *
     *  1. SOQL - handleExecution called the single-request GroupNotifier.send()
     *     wrapper 3x inside a loop over Opportunities. Each call re-entered the
     *     already-bulkified notify() and paid 3 fresh queries, so the cost was
     *     9 queries per Opportunity (measured: 90 for 10 Opportunities). Neither
     *     class was individually wrong - notify() is O(1) in queries (600
     *     notifications = 3 queries); the defect lived only in the seam between
     *     them, which is why a per-class review declared the code clean and was
     *     right. Fixed by batching into one notify() call.
     *
     *  2. DML - the Day-0 fan-out is 82 Tasks per Transaction and ran
     *     synchronously, so a 200-record trigger chunk attempted 16,400 Task
     *     rows against the 10,000 limit. Fixed by chunking it into an async
     *     Queueable chain (TaskFanoutQueueable).
     *
     * Which limit fired depended purely on scale, because the fan-out (line 74)
     * ran before the notification loop (line 77):
     *     N <= ~10      passes
     *     ~11 - ~90     Too many SOQL queries: 101   (notification loop)
     *     ~100          Apex CPU time limit exceeded (fan-out)
     *     >= ~120       Too many DML rows: 10001     (fan-out)
     * At the 251 this test uses, chunk 1 is 200 records, so DML broke FIRST -
     * the SOQL fix alone would never have made this test pass.
     *
     * The synchronous fan-out ceiling was ~116 Transactions per transaction
     * (10,000 rows / ~86 rows per deal). That is ARITHMETIC, NOT INEFFICIENCY:
     * no query tuning could move it, which is why the fan-out had to go async
     * rather than be optimised in place.
     */
    @isTest
    static void bulkExecution251ContractsHandsOffToTransactions() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);
        for (Opportunity o : opps) {
            o.StageName = 'LOI';
        }
        insert opps;

        for (Opportunity o : opps) {
            o.StageName = 'PSA';
        }
        update opps; // auto-creates 251 Contract Reviews (+ Primary_Contract__c stamp)

        List<Contract_Review__c> reviews = [
            SELECT Id FROM Contract_Review__c WHERE Opportunity__c IN :opps
        ];
        System.assertEquals(251, reviews.size(), 'A Contract Review opens for every deal entering PSA');

        Test.startTest();
        for (Contract_Review__c cr : reviews) {
            cr.Negotiation_Status__c = 'Executed';
        }
        update reviews;
        Test.stopTest();

        System.assertEquals(251,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c IN :opps],
            'Every executed deal opens exactly one Transaction');
    }
}
