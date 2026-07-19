/**
 * @description Tests DispositionTaskService — the closing-checklist write workflows
 * extracted from DispositionTaskController in P6 controller thinning: the find-or-create
 * of the three standard closing Tasks, and the complete/re-open toggle.
 *
 * Covers create, idempotency and the toggle. The service does a single (bounded, three-row)
 * collection insert and a single update, with no savepoint/rollback, so there is no
 * rollback catch to force. No 251-record scenario applies — the checklist is fixed at the
 * three SUBJECTS, so the collection DML never scales with input.
 *
 * @see force-app/main/default/classes/DispositionTaskService.cls
 * @author Unit Testing Agent
 */
@isTest
private class DispositionTaskServiceTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'Closing';
        insert d;
    }

    @isTest
    static void findOrCreateSeedsTheThreeSubjects() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        Map<String, Task> bySubject = DispositionTaskService.findOrCreateClosingTasks(d.Id);
        Test.stopTest();

        Assert.areEqual(3, bySubject.size(), 'All three checklist subjects should be present');
        for (String subject : DispositionTaskService.SUBJECTS) {
            Assert.isTrue(bySubject.containsKey(subject), 'Expected a Task for subject: ' + subject);
        }
        Integer count = [SELECT COUNT() FROM Task WHERE WhatId = :d.Id AND Subject IN :DispositionTaskService.SUBJECTS];
        Assert.areEqual(3, count, 'Exactly three closing Tasks should be inserted');
    }

    @isTest
    static void findOrCreateIsIdempotent() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        DispositionTaskService.findOrCreateClosingTasks(d.Id);
        Map<String, Task> again = DispositionTaskService.findOrCreateClosingTasks(d.Id);
        Test.stopTest();

        Assert.areEqual(3, again.size(), 'Still three tasks after a second call');
        Integer count = [SELECT COUNT() FROM Task WHERE WhatId = :d.Id AND Subject IN :DispositionTaskService.SUBJECTS];
        Assert.areEqual(3, count, 'No duplicate Tasks are created on the second call');
    }

    @isTest
    static void setTaskDoneTogglesStatus() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Map<String, Task> bySubject = DispositionTaskService.findOrCreateClosingTasks(d.Id);
        Id taskId = bySubject.get('PSA Executed').Id;

        Test.startTest();
        DispositionTaskService.setTaskDone(taskId, true);
        Task done = [SELECT Status, IsClosed FROM Task WHERE Id = :taskId];
        DispositionTaskService.setTaskDone(taskId, false);
        Task reopened = [SELECT Status, IsClosed FROM Task WHERE Id = :taskId];
        Test.stopTest();

        Assert.areEqual('Completed', done.Status, 'setTaskDone(true) marks the Task Completed');
        Assert.isTrue(done.IsClosed, 'A Completed Task is closed');
        Assert.areEqual('Not Started', reopened.Status, 'setTaskDone(false) re-opens the Task');
        Assert.isFalse(reopened.IsClosed, 'A re-opened Task is not closed');
    }
}
