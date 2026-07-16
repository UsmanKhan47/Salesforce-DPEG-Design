/**
 * @description Test class for DispositionTaskController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Reported coverage was 0% going into this pass; the prior single test method
 * already exercised the create/toggle/idempotency path reasonably well, so the
 * 0% most likely reflects "not yet executed by RunLocalTests" rather than a
 * defect — see the final report. Split into focused methods and added a
 * negative scenario.
 *
 * getClosingTasks/setTaskDone carry inline SOQL + DML with no Selector/Service
 * delegation (apex-layering-rule.md violation). NOT tested here at 251 calls:
 * both are single-record @AuraEnabled methods invoked once per LWC click, and
 * a user cannot click 251 times in one transaction — a sequential-call loop
 * would test a state production cannot produce. Logged as a layering finding
 * for Phase 4 (Selectors) / Phase 6 (controller thinning) instead.
 *
 * ⚠ KNOWN PRODUCTION DEFECT — testSetTaskDone_toggleOnAndOff's re-open
 * assertion is EXPECTED TO FAIL until getClosingTasks(...) is fixed; this is
 * not an invented requirement. getClosingTasks returns
 * `r.completedDate = t.CompletedDateTime` unguarded. Task.CompletedDateTime
 * is a standard, platform-managed field: Salesforce auto-stamps it when
 * Status closes and never auto-clears it when Status reopens, and nothing
 * else in this codebase touches it (no trigger, no Flow) — so a task marked
 * done then reopened keeps a stale completion date. The sibling class this
 * controller's own doc comment says it "mirrors" —
 * TransactionTaskController.getTaskGroups — already guards against exactly
 * this: `r.completedDate = t.IsClosed ? t.LastModifiedDate : null`.
 * DispositionTaskController.getClosingTasks omits that guard. That
 * inconsistency with an established sibling pattern in the same codebase,
 * solving the same UI problem, is the evidence this is an oversight, not a
 * deliberate design. Currently masked in the LWC (dispositionClosingTasks.js
 * only renders the date when `t.done` is true, so a reopened row shows
 * nothing today), but the API keeps returning stale data. Left asserting
 * the correct behavior on purpose; do not weaken this assertion to route
 * around the bug. Fix belongs in getClosingTasks, out of this agent's
 * test-classes-only boundary.
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
    static void testSetTaskDone_nullTaskId_throwsDmlException() {
        Test.startTest();
        try {
            DispositionTaskController.setTaskDone(null, true);
            System.assert(false, 'Expected a DmlException when no Task Id is supplied');
        } catch (System.DmlException e) {
            System.assertEquals(true, e.getMessage().toLowerCase().contains('not specified'),
                'Exception should indicate the missing Id: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
