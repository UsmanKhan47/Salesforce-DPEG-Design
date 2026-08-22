/**
 * Tests OnboardingService (extracted from OnboardingController.completeTask in P6). Proves
 * the checklist completion behaviour: the Task is marked Complete/Completed, the optional
 * note is appended, and the parent Onboarding__c rollup lands. Also covers the null-parent
 * branch (a Task with no Onboarding__c produces no rollup).
 *
 * ═══ 🔴 AMENDED 2026-08-22 — THIS CLASS USED TO ASSERT THE DEFECT ═══
 * `completeTaskMarksCompleteAppendsNoteAndRollsUp` asserted
 * `Assert.areEqual(Date.today(), after.ActivityDate, 'completion stamps today')` — a green
 * test PINNING the bug: `ActivityDate` IS the checklist item's due date, so "completion
 * stamps today" was the deadline being destroyed by its own completion. That assertion is
 * INVERTED below: the original due date must SURVIVE, and the completion now lands on
 * `Onboarding_Completed_Date__c`.
 *
 * ⚠ The completion date is stamped by `OnboardingTaskDomain` in the Task BEFORE contexts, NOT
 * by this service — so the assertion here is an integration read-back through the trigger,
 * and `OnboardingTaskDomainTest` owns the unit-level proof (including the reopen-clears case
 * and the non-LWC write paths this service cannot reach).
 *
 * ⚠ The rollup is likewise no longer called explicitly by the service; `TaskRollupTrigger`
 * fires it on the same `update t`. That the counters still move is asserted below precisely
 * because the explicit call was removed — this is the test that would catch its removal
 * having been a silent regression rather than a de-duplication.
 *
 * This is a single-record operation, so — like the CounterOfferService precedent — there is
 * no collection DML to bulk-test here. The controller-level tests separately cover the
 * AuraHandledException mapping.
 */
@isTest
private class OnboardingServiceTest {

    private static Onboarding__c newActiveOnboarding() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Stage__c = 'Property Set up'; o.Status__c = 'In Progress';
        insert o;
        return o;
    }

    @isTest
    static void completeTaskMarksCompleteAppendsNoteAndRollsUp() {
        Onboarding__c o = newActiveOnboarding();
        Task t = TestDataFactory.createOnboardingTasks(1, o.Id, false)[0];
        t.Subject = 'Open task'; t.Onboarding_Category__c = 'Property Set up';
        t.Onboarding_Status__c = 'Not Started'; t.Status = 'Open'; t.Source_System__c = 'Yardi';
        // A DUE DATE THAT IS NOT TODAY, deliberately: if the assertion below compared against
        // today it could not tell "the due date survived" from "the due date was overwritten
        // with today", which is the exact defect under test.
        Date originalDue = Date.today().addDays(3);
        t.Task_Owner_Label__c = 'Isha Patel'; t.ActivityDate = originalDue;
        insert t;

        Test.startTest();
        OnboardingService.completeTask(t.Id, 'Done via checkbox');
        Test.stopTest();

        Task after = [
            SELECT Onboarding_Status__c, Status, ActivityDate, Onboarding_Completed_Date__c, Description
            FROM Task WHERE Id = :t.Id
        ];
        Assert.areEqual('Complete', after.Onboarding_Status__c, 'onboarding status flips to Complete');
        Assert.areEqual('Completed', after.Status, 'standard status closed');
        // 🔴 THE DEFECT FIX. This line previously read `areEqual(Date.today(), after.ActivityDate)`.
        Assert.areEqual(originalDue, after.ActivityDate,
            'THE ORIGINAL DUE DATE MUST SURVIVE COMPLETION. ActivityDate is what the checklist '
            + 'renders as "due" and what the Overdue / Stalled / Due-in-7d rollups are computed '
            + 'from; overwriting it on completion destroyed the deadline being measured against');
        Assert.areEqual(Date.today(), after.Onboarding_Completed_Date__c,
            'and the completion lands on its OWN field, stamped by the Task trigger — so late '
            + 'completion stays derivable as Onboarding_Completed_Date__c - ActivityDate');
        Assert.isTrue(after.Description != null && after.Description.contains('Done via checkbox'), 'note appended');

        Onboarding__c rolled = [SELECT Tasks_Complete__c FROM Onboarding__c WHERE Id = :o.Id];
        Assert.areEqual(1, rolled.Tasks_Complete__c, 'rollup sees the completed task');
    }

    @isTest
    static void completeTaskAppendsNoteToExistingDescription() {
        Onboarding__c o = newActiveOnboarding();
        Task t = TestDataFactory.createOnboardingTasks(1, o.Id, false)[0];
        t.Onboarding_Category__c = 'Property Set up'; t.Onboarding_Status__c = 'Not Started';
        t.Description = 'Earlier note.';
        insert t;

        Test.startTest();
        OnboardingService.completeTask(t.Id, 'Second note');
        Test.stopTest();

        Task after = [SELECT Description FROM Task WHERE Id = :t.Id];
        Assert.isTrue(after.Description.startsWith('Earlier note.'), 'existing description preserved');
        Assert.isTrue(after.Description.contains('Second note'), 'new note appended');
    }

    @isTest
    static void completeTaskBlankNotesLeavesDescriptionUntouched() {
        Onboarding__c o = newActiveOnboarding();
        Task t = TestDataFactory.createOnboardingTasks(1, o.Id, false)[0];
        t.Onboarding_Category__c = 'Property Set up'; t.Onboarding_Status__c = 'Not Started';
        t.Description = 'Only note';
        insert t;

        Test.startTest();
        OnboardingService.completeTask(t.Id, '   ');
        Test.stopTest();

        Task after = [SELECT Onboarding_Status__c, Description FROM Task WHERE Id = :t.Id];
        Assert.areEqual('Complete', after.Onboarding_Status__c, 'still completes with blank notes');
        Assert.areEqual('Only note', after.Description, 'blank notes must not overwrite existing description');
    }

    /**
     * A Task with no parent Onboarding completes normally and triggers no rollup.
     *
     * ⚠ AMENDED 2026-08-22 — WHAT THIS PROVES MOVED, SO ITS NAME AND BODY MOVED WITH IT. The
     * service's own `if (t.Onboarding__c != null)` branch no longer exists (the trigger owns
     * the rollup now), so this is no longer a branch-coverage test of this class. It is now the
     * ORG-WIDE BLAST-RADIUS GUARD for `TaskRollupTriggerHandler`'s new before-contexts, which
     * fire on every Task in the org: a Task with no `Onboarding__c` must come out completely
     * untouched by the onboarding stamp. If `OnboardingTaskDomain` ever loses its
     * `Onboarding__c == null` early return, every hand-created Activity in the org starts
     * carrying an onboarding completion date, and this is the test that says so.
     */
    @isTest
    static void completeTaskWithNoParentIsUntouchedByTheOnboardingStamp() {
        Task t = new Task(Subject = 'Orphan task', Status = 'Not Started', Onboarding_Status__c = 'Not Started');
        insert t;

        Test.startTest();
        OnboardingService.completeTask(t.Id, 'note');
        Test.stopTest();

        Task after = [SELECT Onboarding_Status__c, Status, Onboarding_Completed_Date__c FROM Task WHERE Id = :t.Id];
        Assert.areEqual('Complete', after.Onboarding_Status__c, 'orphan task still completes');
        Assert.areEqual('Completed', after.Status, 'standard status closed');
        Assert.isNull(after.Onboarding_Completed_Date__c,
            'A Task with no Onboarding__c must NOT be stamped — this is the guard that keeps the '
            + 'new before-insert/before-update contexts at one null comparison for every other '
            + 'Task in the org');
    }
}
