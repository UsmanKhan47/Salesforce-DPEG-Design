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
        TaskFanoutService.fanOut(new List<Id>{ withLoan.Id, noLoan.Id });
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
        TaskFanoutService.fanOut(new List<Id>{ withLoan.Id });
        System.assertEquals(3, [SELECT COUNT() FROM Task WHERE Transaction_Deal__c = :withLoan.Id], 'No duplicate fan-out');
    }

    @isTest
    static void testEmptyInput() {
        TaskFanoutService.fanOut(new List<Id>());
        TaskFanoutService.fanOut(null);
        System.assertEquals(0, [SELECT COUNT() FROM Task], 'No tasks created for empty input');
    }
}