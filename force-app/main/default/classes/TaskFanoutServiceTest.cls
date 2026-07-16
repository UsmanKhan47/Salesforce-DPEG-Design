@isTest
private class TaskFanoutServiceTest {

    @isTest
    static void testFanOutWithConditional() {
        // In-memory CMDT defs (group names match the deployed Task_Group__c picklist):
        // group A (always) + group F (conditional on Loan_Required__c).
        TaskFanoutService.groupDefsOverride = new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(Letter__c = 'A', Group_Name__c = 'Contract Execution & Title Opening',
                Owner_Label__c = 'Danish', Conditional__c = false),
            new Task_Group_Def__mdt(Letter__c = 'F', Group_Name__c = 'Loan Package & Financing',
                Owner_Label__c = 'Danish', Conditional__c = true, Condition_Field__c = 'Loan_Required__c')
        };
        TaskFanoutService.taskDefsOverride = new List<Transaction_Task_Def__mdt>{
            new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = 1, Subject__c = 'Sign PSA', Due_Day_Offset__c = 0),
            new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = 2, Subject__c = 'Open Escrow', Due_Day_Offset__c = 2),
            new Transaction_Task_Def__mdt(Group_Letter__c = 'F', Sequence__c = 1, Subject__c = 'Submit Loan App', Due_Day_Offset__c = 5)
        };

        // Insert with the flag already set so the active record-triggered Flow doesn't fire;
        // the test invokes the service directly with the dedupe bypass.
        Transaction__c withLoan = new Transaction__c(Status__c = 'Active', Tasks_Fanned_Out__c = true,
            Contract_Executed_Date__c = Date.today(), Loan_Required__c = true);
        Transaction__c noLoan = new Transaction__c(Status__c = 'Active', Tasks_Fanned_Out__c = true,
            Contract_Executed_Date__c = Date.today(), Loan_Required__c = false);
        insert new List<Transaction__c>{ withLoan, noLoan };

        TaskFanoutService.bypassDedupe = true;
        Test.startTest();
        TaskFanoutService.fanOutNow(new List<Id>{ withLoan.Id, noLoan.Id });
        Test.stopTest();
        TaskFanoutService.bypassDedupe = false;

        List<Task> wl = [
            SELECT Subject, Task_Group__c, Task_Sequence__c, Conditional__c, Task_Owner_Label__c, ActivityDate
            FROM Task WHERE Transaction_Deal__c = :withLoan.Id ORDER BY Task_Group__c, Task_Sequence__c
        ];
        System.assertEquals(3, wl.size(), 'withLoan gets A(2) + conditional F(1)');
        System.assertEquals('A. Contract Execution & Title Opening', wl[0].Task_Group__c, 'Group label = letter + name');
        System.assertEquals('Danish', wl[0].Task_Owner_Label__c, 'Owner label carried through');
        System.assertEquals(Date.today().addDays(2), wl[1].ActivityDate, 'Due date = executed + offset');
        Task financing = wl[2];
        System.assertEquals('F. Loan Package & Financing', financing.Task_Group__c);
        System.assertEquals(true, financing.Conditional__c, 'Financing task flagged conditional');

        System.assertEquals(2, [SELECT COUNT() FROM Task WHERE Transaction_Deal__c = :noLoan.Id],
            'noLoan skips the conditional Financing group');

        Transaction__c reloaded = [SELECT Tasks_Fanned_Out__c, Tasks_Total__c FROM Transaction__c WHERE Id = :withLoan.Id];
        System.assertEquals(true, reloaded.Tasks_Fanned_Out__c, 'Dedupe flag set');
        System.assertEquals(3, reloaded.Tasks_Total__c, 'Tasks_Total set to count created for this deal');

        // Re-run is a no-op (already fanned out).
        TaskFanoutService.fanOutNow(new List<Id>{ withLoan.Id });
        System.assertEquals(3, [SELECT COUNT() FROM Task WHERE Transaction_Deal__c = :withLoan.Id], 'No duplicate fan-out');
    }

    @isTest
    static void testEmptyInput() {
        TaskFanoutService.fanOutNow(new List<Id>());
        TaskFanoutService.fanOutNow(null);
        System.assertEquals(0, [SELECT COUNT() FROM Task], 'No tasks created for empty input');
    }

    /**
     * Covers the Flow entry point (@InvocableMethod fanOut) end to end at small scale:
     * one enqueueJob, one synchronous Queueable execution in test context, checklist
     * created, dedupe flag set. Uses in-memory CMDT overrides (fast, deterministic) —
     * the bulk test below is what proves production def-count behavior.
     */
    @isTest
    static void testFanOut_smallScale_enqueuesAndProcessesSynchronously() {
        TaskFanoutService.groupDefsOverride = new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(Letter__c = 'A', Group_Name__c = 'Contract Execution & Title Opening',
                Owner_Label__c = 'Danish', Conditional__c = false)
        };
        TaskFanoutService.taskDefsOverride = new List<Transaction_Task_Def__mdt>{
            new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = 1, Subject__c = 'Sign PSA', Due_Day_Offset__c = 0)
        };

        // No Contract_Executed_Date__c so the record-triggered Flow doesn't also fire and
        // race the direct fanOut() call this test is exercising.
        List<Transaction__c> transactions = TestDataFactory.createTransactions(3, false);
        TestDataFactory.applyOverrides(transactions, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert transactions;

        List<TaskFanoutService.InputDTO> requests = new List<TaskFanoutService.InputDTO>();
        for (Transaction__c t : transactions) {
            TaskFanoutService.InputDTO d = new TaskFanoutService.InputDTO();
            d.transactionId = t.Id;
            requests.add(d);
        }

        Test.startTest();
        TaskFanoutService.fanOut(requests);
        Test.stopTest();

        System.assertEquals(3, [SELECT COUNT() FROM Task WHERE Transaction_Deal__c IN :transactions],
            'All 3 Transactions (well under CHUNK_SIZE) get their single checklist Task via the synchronous first-level Queueable execution');
        for (Transaction__c t : [SELECT Tasks_Fanned_Out__c FROM Transaction__c WHERE Id IN :transactions]) {
            System.assertEquals(true, t.Tasks_Fanned_Out__c, 'Dedupe flag set for every Transaction fanned out via the async path');
        }
    }

    @isTest
    static void testFanOut_nullAndEmptyAndAllNullIdInputs_areNoOps() {
        Integer before = [SELECT COUNT() FROM Task];

        Test.startTest();
        TaskFanoutService.fanOut(null);
        TaskFanoutService.fanOut(new List<TaskFanoutService.InputDTO>());
        TaskFanoutService.fanOut(new List<TaskFanoutService.InputDTO>{ new TaskFanoutService.InputDTO() }); // transactionId left null
        Test.stopTest();

        System.assertEquals(before, [SELECT COUNT() FROM Task],
            'Null input, an empty list, and a request with no transactionId never enqueue any work');
    }

    @isTest
    static void testFanOut_duplicateTransactionIdsInOneCall_areDeduped() {
        TaskFanoutService.groupDefsOverride = new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(Letter__c = 'A', Group_Name__c = 'Contract Execution & Title Opening',
                Owner_Label__c = 'Danish', Conditional__c = false)
        };
        TaskFanoutService.taskDefsOverride = new List<Transaction_Task_Def__mdt>{
            new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = 1, Subject__c = 'Sign PSA', Due_Day_Offset__c = 0)
        };
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert t;

        TaskFanoutService.InputDTO d1 = new TaskFanoutService.InputDTO();
        d1.transactionId = t.Id;
        TaskFanoutService.InputDTO d2 = new TaskFanoutService.InputDTO();
        d2.transactionId = t.Id; // same Id again

        Test.startTest();
        TaskFanoutService.fanOut(new List<TaskFanoutService.InputDTO>{ d1, d2 });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE Transaction_Deal__c = :t.Id],
            'A duplicate Transaction Id passed twice in one fanOut() call must not fan out its checklist twice');
    }

    /**
     * Hits fanOutNow's branches that testFanOutWithConditional doesn't: a Transaction_Task_Def__mdt
     * whose Group_Letter__c has no matching Task_Group_Def__mdt (silently skipped, not an error),
     * a blank task-level Owner_Label__c (falls back to the group's), a blank Default_Status__c
     * (falls back to 'Not Started'), a blank Due_Day_Offset__c (falls back to a 0-day offset), and
     * a null Contract_Executed_Date__c (ActivityDate is never derived).
     */
    @isTest
    static void testFanOutNow_skipsUnknownGroupAndAppliesFallbackDefaults() {
        TaskFanoutService.groupDefsOverride = new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(Letter__c = 'A', Group_Name__c = 'Contract Execution & Title Opening',
                Owner_Label__c = 'Danish', Conditional__c = false)
        };
        TaskFanoutService.taskDefsOverride = new List<Transaction_Task_Def__mdt>{
            // No Due_Day_Offset__c, no Default_Status__c, no Owner_Label__c -> exercise every fallback.
            new Transaction_Task_Def__mdt(Group_Letter__c = 'A', Sequence__c = 1, Subject__c = 'Sign PSA'),
            // Group letter with no matching override -> must be skipped, not error.
            new Transaction_Task_Def__mdt(Group_Letter__c = 'Z', Sequence__c = 1, Subject__c = 'Orphaned def')
        };

        Transaction__c withDate = TestDataFactory.createTransaction(null, null, false); // Contract_Executed_Date__c = today (factory default)
        Transaction__c noDate = TestDataFactory.createTransaction(null, null, false);
        // Suppress the Flow on both (this test drives fanOutNow directly) and null out noDate's date.
        TestDataFactory.applyOverrides(withDate, new Map<String, Object>{ 'Tasks_Fanned_Out__c' => true });
        TestDataFactory.applyOverrides(noDate, new Map<String, Object>{ 'Tasks_Fanned_Out__c' => true, 'Contract_Executed_Date__c' => null });
        insert new List<Transaction__c>{ withDate, noDate };

        TaskFanoutService.bypassDedupe = true;
        Test.startTest();
        TaskFanoutService.fanOutNow(new List<Id>{ withDate.Id, noDate.Id });
        Test.stopTest();
        TaskFanoutService.bypassDedupe = false;

        List<Task> withDateTasks = [
            SELECT Subject, Task_Owner_Label__c, Status, ActivityDate FROM Task WHERE Transaction_Deal__c = :withDate.Id
        ];
        System.assertEquals(1, withDateTasks.size(), 'The Z-group orphaned def is silently skipped; only the A-group def is created');
        System.assertEquals('Danish', withDateTasks[0].Task_Owner_Label__c, 'Blank task-level Owner_Label__c falls back to the group Owner_Label__c');
        System.assertEquals('Not Started', withDateTasks[0].Status, 'Blank Default_Status__c falls back to Not Started');
        System.assertEquals(Date.today(), withDateTasks[0].ActivityDate, 'Blank Due_Day_Offset__c falls back to a 0-day offset from Contract_Executed_Date__c');

        Task noDateTask = [SELECT ActivityDate FROM Task WHERE Transaction_Deal__c = :noDate.Id LIMIT 1];
        System.assertEquals(null, noDateTask.ActivityDate, 'No Contract_Executed_Date__c means ActivityDate is never derived');
    }

    /**
     * THE bulk test: proves the async chunking fix holds at 251 Transactions using the
     * real, deployed CMDT checklist (82 Transaction_Task_Def__mdt / 11 Task_Group_Def__mdt
     * records — see scripts/load-transaction-task-defs.apex and scripts/load-task-group-defs.apex,
     * the only source of truth for this data; it is not source-tracked metadata). Deliberately
     * does NOT use taskDefsOverride/groupDefsOverride — shrinking the def count would hide
     * exactly the production break this test exists to catch (see class header / CLAUDE
     * instructions "THE TRAP").
     *
     * Drives TaskFanoutService.fanOut() directly (bypassing the Transaction_Task_Fanout Flow)
     * so this test controls exactly one System.enqueueJob call and its result is deterministic,
     * rather than depending on how many trigger/flow batches Salesforce internally splits 251
     * records into (unverifiable without org access — see report).
     */
    @isTest
    static void testFanOut_bulk251_chunksAsyncAtProductionDefCount() {
        // Canary: fail loudly, not silently, if the org's CMDT shape has drifted from what
        // this test's arithmetic assumes.
        System.assertEquals(11, [SELECT COUNT() FROM Task_Group_Def__mdt],
            'This test assumes the 11 deployed Task_Group_Def__mdt records exist (scripts/load-task-group-defs.apex); re-run the loader if this fails.');
        System.assertEquals(82, [SELECT COUNT() FROM Transaction_Task_Def__mdt],
            'This test assumes the 82 deployed Transaction_Task_Def__mdt records exist (scripts/load-transaction-task-defs.apex); re-run the loader if this fails.');

        // Loan_Required__c = true so every group applies, including the conditional Financing
        // group (12 of the 82 defs) — the full worst-case shape the fan-out math assumes.
        List<Transaction__c> transactions = TestDataFactory.createTransactions(251, false);
        TestDataFactory.applyOverrides(transactions, new Map<String, Object>{
            'Loan_Required__c' => true,
            'Tasks_Fanned_Out__c' => true // suppress the Flow; this test drives TaskFanoutService directly
        });
        insert transactions;

        List<TaskFanoutService.InputDTO> requests = new List<TaskFanoutService.InputDTO>();
        for (Transaction__c t : transactions) {
            TaskFanoutService.InputDTO d = new TaskFanoutService.InputDTO();
            d.transactionId = t.Id;
            requests.add(d);
        }

        Integer chunkSize = TaskFanoutQueueable.CHUNK_SIZE;

        TaskFanoutService.bypassDedupe = true;
        Test.startTest();
        TaskFanoutService.fanOut(requests); // exactly ONE System.enqueueJob call, regardless of the 251 count
        Test.stopTest(); // runs the first-level Queueable synchronously; the chain continuation is
                          // intentionally blocked by TaskFanoutQueueable.ChainFinalizer when
                          // Test.isRunningTest() — proven here by counting what did NOT run, not assumed
        TaskFanoutService.bypassDedupe = false;

        Integer fannedOut = [SELECT COUNT() FROM Transaction__c WHERE Id IN :transactions AND Tasks_Total__c = 82];
        Integer notFannedOut = [SELECT COUNT() FROM Transaction__c WHERE Id IN :transactions AND Tasks_Total__c = null];
        Integer totalTasks = [SELECT COUNT() FROM Task WHERE Transaction_Deal__c IN :transactions];

        System.assertEquals(chunkSize, fannedOut,
            'Exactly CHUNK_SIZE Transactions are processed by the single Queueable execution that runs synchronously at Test.stopTest()');
        System.assertEquals(251 - chunkSize, notFannedOut,
            'The remaining Transactions stay un-processed in test context because chain continuation is blocked — proof the chain, not a shortcut, is what would finish the rest in production');
        System.assertEquals(chunkSize * 82, totalTasks,
            'CHUNK_SIZE x 82 defs Task rows are created in one DML insert — comfortably under the 10,000-row limit, which is the entire reason the fan-out is chunked at 100 and not attempted at 251 synchronously (251 x 82 = 20,582 would blow it)');
        System.assert(totalTasks <= 10000,
            'A single chunk fan-out must never approach the 10,000 DML-row limit — this is the governor-limit safety property the async redesign exists to guarantee');

        List<AsyncApexJob> jobs = [SELECT Id, JobType FROM AsyncApexJob WHERE ApexClass.Name = 'TaskFanoutQueueable'];
        System.assert(!jobs.isEmpty(), 'The chunked fan-out ran as a Queueable job');
    }
}