/**
 * Tests TransactionTaskService (extracted from TransactionTaskController in P6). Proves the
 * checklist write behaviour is preserved end-to-end at the service layer: the status toggle,
 * the notes-preserving completion, and the wire-verification close (including its
 * name/phone gate, which the service now raises as a typed WireVerificationException rather
 * than an AuraHandledException — the AuraHandledException boundary moved to the controller).
 *
 * These are single-record operations (one Task update per method), so — like the
 * CounterOfferService precedent — there is no collection DML to bulk-test and no Savepoint
 * to force a rollback on. The controller-level tests separately cover the AuraHandledException
 * mapping.
 */
@isTest
private class TransactionTaskServiceTest {

    /** An Active Transaction with the fan-out Flow suppressed (no Contract_Executed_Date__c). */
    private static Transaction__c newSuppressedTransaction() {
        Transaction__c t = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(t, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert t;
        return t;
    }

    @isTest
    static void setTaskStatusToggles() {
        Transaction__c t = newSuppressedTransaction();
        Task tsk = new Task(Transaction_Deal__c = t.Id, Subject = 'A1',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1, Status = 'Not Started');
        insert tsk;

        Test.startTest();
        TransactionTaskService.setTaskStatus(tsk.Id, true);
        Assert.areEqual('Completed', [SELECT Status FROM Task WHERE Id = :tsk.Id].Status, 'done=true marks Completed');
        TransactionTaskService.setTaskStatus(tsk.Id, false);
        Assert.areEqual('Not Started', [SELECT Status FROM Task WHERE Id = :tsk.Id].Status, 'done=false reverts to Not Started');
        Test.stopTest();
    }

    @isTest
    static void completeTaskWithNotesTrimsAndSaves() {
        Transaction__c t = newSuppressedTransaction();
        Task tsk = new Task(Transaction_Deal__c = t.Id, Subject = 'A1',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1, Status = 'Not Started');
        insert tsk;

        Test.startTest();
        TransactionTaskService.completeTask(tsk.Id, '  Called the seller to confirm.  ');
        Test.stopTest();

        Task r = [SELECT Status, Description FROM Task WHERE Id = :tsk.Id];
        Assert.areEqual('Completed', r.Status, 'Task closed');
        Assert.areEqual('Called the seller to confirm.', r.Description, 'Notes trimmed and saved');
    }

    @isTest
    static void completeTaskBlankNotesLeavesDescriptionUntouched() {
        Transaction__c t = newSuppressedTransaction();
        Task tsk = new Task(Transaction_Deal__c = t.Id, Subject = 'A1',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1,
            Status = 'Not Started', Description = 'Pre-existing comment');
        insert tsk;

        Test.startTest();
        TransactionTaskService.completeTask(tsk.Id, '   ');
        Test.stopTest();

        Task r = [SELECT Status, Description FROM Task WHERE Id = :tsk.Id];
        Assert.areEqual('Completed', r.Status, 'Task closed even with no new notes');
        Assert.areEqual('Pre-existing comment', r.Description, 'Blank notes must not overwrite existing comments');
    }

    @isTest
    static void completeWireVerificationStampsAndLogs() {
        Transaction__c t = newSuppressedTransaction();
        Task wire = new Task(Transaction_Deal__c = t.Id, Status = 'Not Started',
            Subject = 'Verify wiring instructions by phone (anti-fraud)',
            Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = 2);
        insert wire;

        Test.startTest();
        TransactionTaskService.completeWireVerification(wire.Id, 'Jane Doe', '713-555-0100', null);
        Test.stopTest();

        Task r = [
            SELECT Status, Verbal_Verification_Completed__c, Verified_By__c,
                   Verification_Phone__c, Verified_At__c, Description
            FROM Task WHERE Id = :wire.Id
        ];
        Assert.areEqual('Completed', r.Status, 'Task closed after verification');
        Assert.areEqual(true, r.Verbal_Verification_Completed__c, 'Verification flag set');
        Assert.areEqual('Jane Doe', r.Verified_By__c, 'Confirmer name stamped');
        Assert.areEqual('713-555-0100', r.Verification_Phone__c, 'Phone stamped');
        Assert.isNotNull(r.Verified_At__c, 'Timestamp stamped');
        Assert.isTrue(r.Description != null && r.Description.contains('Verified by phone with Jane Doe'),
            'Standard verification note logged to comments');
    }

    @isTest
    static void completeWireVerificationWithCommentsAndExistingDescriptionAppendsInOrder() {
        Transaction__c t = newSuppressedTransaction();
        Task wire = new Task(Transaction_Deal__c = t.Id, Status = 'Not Started',
            Subject = 'Verify wiring instructions by phone (anti-fraud)',
            Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = 2,
            Description = 'Prior note from earlier in the deal.');
        insert wire;

        Test.startTest();
        TransactionTaskService.completeWireVerification(wire.Id, 'Jane Doe', '713-555-0100',
            'Called title company twice to confirm.');
        Test.stopTest();

        Task r = [SELECT Description FROM Task WHERE Id = :wire.Id];
        Assert.isTrue(r.Description.startsWith('Prior note from earlier in the deal.'),
            'Existing Description preserved, not overwritten');
        Assert.isTrue(r.Description.contains('Called title company twice to confirm.'),
            'Verifier comments appended');
        Assert.isTrue(r.Description.contains('Verified by phone with Jane Doe'),
            'Standard note appended after the comments');
    }

    @isTest
    static void completeWireVerificationBlankNamePhoneThrowsTypedException() {
        Transaction__c t = newSuppressedTransaction();
        Task wire = new Task(Transaction_Deal__c = t.Id, Status = 'Not Started',
            Subject = 'Verify wiring instructions by phone (anti-fraud)',
            Task_Group__c = 'B. Earnest Money Wire', Task_Sequence__c = 2);
        insert wire;

        Test.startTest();
        // The service raises a TYPED exception (not AuraHandledException) — the boundary moved
        // to the controller. Blank name and blank phone both trip the gate.
        try {
            TransactionTaskService.completeWireVerification(wire.Id, '', '', null);
            Assert.fail('Blank name/phone must raise WireVerificationException');
        } catch (TransactionTaskService.WireVerificationException e) {
            Assert.isNotNull(e.getMessage(), 'gate raises a typed WireVerificationException');
        }
        // Blank phone only (name present) also trips it.
        try {
            TransactionTaskService.completeWireVerification(wire.Id, 'Jane Doe', '', null);
            Assert.fail('Blank phone must raise WireVerificationException');
        } catch (TransactionTaskService.WireVerificationException e) {
            Assert.isNotNull(e.getMessage(), 'blank phone raises a typed WireVerificationException');
        }
        Test.stopTest();

        Assert.areEqual('Not Started', [SELECT Status FROM Task WHERE Id = :wire.Id].Status,
            'Task stays open when the gate blocks closure');
    }
}
