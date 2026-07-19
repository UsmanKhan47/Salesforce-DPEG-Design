/**
 * @description Test class for DispositionTaskController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Split into focused methods with positive create/toggle/idempotency scenarios plus
 * negative scenarios.
 *
 * P6 controller thinning: the find-or-create and toggle DML now live in
 * DispositionTaskService, and every @AuraEnabled method wraps its work in a try/catch
 * that maps failures to an AuraHandledException at the LWC boundary (ARCHITECTURE.md §5).
 * getClosingTasks reads the standard Task object (which a bare Standard User can read, so
 * a bare-user probe would not throw) AND inserts Tasks, so its catch is exercised by
 * passing a deleted Disposition Id — the checklist insert then fails on the invalid
 * cross-reference WhatId. setTaskDone's catch is exercised with a null Task Id.
 *
 * The completed-date guard (r.completedDate = t.IsClosed ? t.LastModifiedDate : null) is
 * in place in the controller and TaskSelector selects LastModifiedDate, so the
 * clear-on-reopen behaviour holds — testSetTaskDone_toggleOnAndOff asserts it directly.
 * @author Unit Testing Agent
 */
@isTest
private class DispositionTaskControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, false);
        d.Disposition_Stage__c = 'Closing';
        insert d;
    }

    @isTest
    static void testGetClosingTasks_firstCall_createsThreeInOrder() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        List<DispositionTaskController.ClosingTask> rows = DispositionTaskController.getClosingTasks(d.Id);
        Test.stopTest();

        System.assertEquals(3, rows.size(), 'Three closing tasks should be created');
        System.assertEquals('PSA Executed', rows[0].subject, 'First task is PSA Executed');
        System.assertEquals('Title Company Engaged', rows[1].subject, 'Second task is Title Company Engaged');
        System.assertEquals('Closing Statement Received', rows[2].subject, 'Third task is Closing Statement Received');
        System.assertEquals(false, rows[0].done, 'New tasks start not done');
        System.assertEquals(null, rows[0].completedDate, 'New tasks have no completed date');
    }

    @isTest
    static void testGetClosingTasks_secondCall_isIdempotent() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        DispositionTaskController.getClosingTasks(d.Id);
        List<DispositionTaskController.ClosingTask> again = DispositionTaskController.getClosingTasks(d.Id);
        Test.stopTest();

        System.assertEquals(3, again.size(), 'Still three tasks after a second call');
        Integer taskCount = [
            SELECT COUNT() FROM Task
            WHERE WhatId = :d.Id
              AND Subject IN ('PSA Executed', 'Title Company Engaged', 'Closing Statement Received')
        ];
        System.assertEquals(3, taskCount, 'No duplicate tasks should be created on the second call');
    }

    @isTest
    static void testSetTaskDone_toggleOnAndOff() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        List<DispositionTaskController.ClosingTask> rows = DispositionTaskController.getClosingTasks(d.Id);

        Test.startTest();
        DispositionTaskController.setTaskDone(rows[0].id, true);
        List<DispositionTaskController.ClosingTask> afterDone = DispositionTaskController.getClosingTasks(d.Id);
        DispositionTaskController.setTaskDone(rows[0].id, false);
        List<DispositionTaskController.ClosingTask> afterReopen = DispositionTaskController.getClosingTasks(d.Id);
        Test.stopTest();

        System.assertEquals(true, afterDone[0].done, 'First task should be marked done');
        System.assertNotEquals(null, afterDone[0].completedDate, 'Completed date should be set once done');
        System.assertEquals(false, afterReopen[0].done, 'Task should be re-opened');
        System.assertEquals(null, afterReopen[0].completedDate, 'Completed date should clear on re-open');
    }

    @isTest
    static void testSetTaskDone_nullTaskId_throwsAuraHandledException() {
        // P6: the raw DmlException (no Id specified) is now caught in the controller and
        // re-thrown as a user-safe AuraHandledException at the LWC boundary.
        Test.startTest();
        try {
            DispositionTaskController.setTaskDone(null, true);
            Assert.fail('Expected an AuraHandledException when no Task Id is supplied');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'setTaskDone DML failure maps to AuraHandledException');
        }
        Test.stopTest();
    }

    @isTest
    static void testGetClosingTasks_deletedDisposition_throwsAuraHandledException() {
        // A deleted Disposition Id: the checklist Tasks are inserted with WhatId = that Id,
        // so the insert fails on the invalid cross-reference — reaching the service's DML,
        // which the controller maps to a user-safe AuraHandledException (P6). Task is a
        // standard object a bare Standard User CAN read, so a bare-user probe would not
        // throw here; the deleted-Id write path is the deterministic route to this catch.
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c d = TestDataFactory.createDisposition(asset.Id, true);
        Id deletedId = d.Id;
        delete d;

        Test.startTest();
        try {
            DispositionTaskController.getClosingTasks(deletedId);
            Assert.fail('Expected an AuraHandledException when the WhatId Disposition no longer exists');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'getClosingTasks DML failure maps to AuraHandledException');
        }
        Test.stopTest();
    }
}
