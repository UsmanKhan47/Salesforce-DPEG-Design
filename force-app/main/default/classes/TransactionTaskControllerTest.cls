@isTest
private class TransactionTaskControllerTest {

    @isTest
    static void testGroupsAndToggle() {
        // No Contract_Executed_Date so the fan-out Flow doesn't fire; tasks inserted directly.
        Transaction__c t = new Transaction__c(Status__c = 'Active');
        insert t;

        insert new List<Task>{
            new Task(Transaction_Deal__c = t.Id, Subject = 'A1', Task_Group__c = 'A. Contract Execution & Title Opening',
                Task_Sequence__c = 1, Task_Owner_Label__c = 'Danish', Status = 'Completed'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'A2', Task_Group__c = 'A. Contract Execution & Title Opening',
                Task_Sequence__c = 2, Task_Owner_Label__c = 'Danish', Status = 'Not Started'),
            new Task(Transaction_Deal__c = t.Id, Subject = 'F1', Task_Group__c = 'F. Loan Package & Financing',
                Task_Sequence__c = 1, Task_Owner_Label__c = 'CFO', Status = 'Not Started')
        };

        Test.startTest();
        List<TransactionTaskController.GroupRow> groups = TransactionTaskController.getTaskGroups(t.Id);
        Id a2Id = [SELECT Id FROM Task WHERE Subject = 'A2' AND Transaction_Deal__c = :t.Id LIMIT 1].Id;
        TransactionTaskController.setTaskStatus(a2Id, true);
        Test.stopTest();

        Map<String, TransactionTaskController.GroupRow> byLetter = new Map<String, TransactionTaskController.GroupRow>();
        for (TransactionTaskController.GroupRow g : groups) {
            byLetter.put(g.letter, g);
        }
        System.assert(byLetter.containsKey('A'), 'Group A present');
        System.assertEquals(2, byLetter.get('A').total, 'Group A has 2 tasks');
        System.assertEquals(1, byLetter.get('A').complete, 'Group A had 1 complete at query time');
        System.assertEquals(50, byLetter.get('A').pct, 'Group A 50% complete');
        System.assert(byLetter.containsKey('F'), 'Group F present');
        System.assertEquals(true, byLetter.get('F').conditional, 'F is the conditional Financing group');

        // toggle persisted
        System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :a2Id].Status, 'A2 marked complete');
    }

    @isTest
    static void testWireVerificationGate() {
        Transaction__c t = new Transaction__c(Status__c = 'Active');
        insert t;
        Task wire = new Task(Transaction_Deal__c = t.Id, Status = 'Not Started',
            Subject = 'Verify wiring instructions by phone (anti-fraud)',
            Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = 2);
        insert wire;

        Test.startTest();
        Boolean threw = false;
        try {
            TransactionTaskController.completeWireVerification(wire.Id, '', '');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank name/phone must block closure');

        TransactionTaskController.completeWireVerification(wire.Id, 'Jane Doe', '713-555-0100');
        Test.stopTest();

        Task r = [
            SELECT Status, IsClosed, Verbal_Verification_Completed__c, Verified_By__c,
                   Verification_Phone__c, Verified_At__c, Description
            FROM Task WHERE Id = :wire.Id
        ];
        System.assertEquals('Completed', r.Status, 'Task closed after verification');
        System.assertEquals(true, r.Verbal_Verification_Completed__c, 'Verification flag set');
        System.assertEquals('Jane Doe', r.Verified_By__c);
        System.assertEquals('713-555-0100', r.Verification_Phone__c);
        System.assertNotEquals(null, r.Verified_At__c, 'Timestamp stamped');
        System.assert(r.Description != null && r.Description.contains('Verified by phone with Jane Doe'),
            'Step-6 note logged to comments');
    }
}