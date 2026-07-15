@isTest
private class DispositionTaskControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = new Property__c(Name = 'Test Property');
        insert prop;
        Property_Asset__c asset = new Property_Asset__c(
            Property__c = prop.Id, Name = 'Test Asset',
            NOI__c = 1000000, Market_Cap_Rate__c = 6.0, Target_Sale_Price__c = 15000000
        );
        insert asset;
        insert new Disposition__c(Property_Asset__c = asset.Id, Disposition_Stage__c = 'Closing');
    }

    @isTest
    static void createsTogglesAndIsIdempotent() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        List<DispositionTaskController.ClosingTask> rows = DispositionTaskController.getClosingTasks(d.Id);
        System.assertEquals(3, rows.size(), 'Three closing tasks should be created');
        System.assertEquals('PSA Executed', rows[0].subject, 'First task is PSA Executed');
        System.assertEquals('Closing Statement Received', rows[2].subject, 'Third task is Closing Statement Received');
        System.assertEquals(false, rows[0].done, 'New tasks start not done');

        // find-or-create is idempotent: a second call does not duplicate.
        List<DispositionTaskController.ClosingTask> again = DispositionTaskController.getClosingTasks(d.Id);
        System.assertEquals(3, again.size(), 'Still three tasks after a second call');

        DispositionTaskController.setTaskDone(rows[0].id, true);
        Test.stopTest();

        List<DispositionTaskController.ClosingTask> after = DispositionTaskController.getClosingTasks(d.Id);
        System.assertEquals(true, after[0].done, 'First task should be marked done');
        System.assertNotEquals(null, after[0].completedDate, 'Completed date should be set');

        // Re-open toggles it back.
        DispositionTaskController.setTaskDone(rows[0].id, false);
        List<DispositionTaskController.ClosingTask> reopened = DispositionTaskController.getClosingTasks(d.Id);
        System.assertEquals(false, reopened[0].done, 'Task should be re-opened');

        Integer taskCount = [
            SELECT COUNT() FROM Task
            WHERE WhatId = :d.Id
              AND Subject IN ('PSA Executed', 'Title Company Engaged', 'Closing Statement Received')
        ];
        System.assertEquals(3, taskCount, 'No duplicate tasks created');
    }
}