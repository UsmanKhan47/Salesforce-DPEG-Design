/**
 * Tests OnboardingService (extracted from OnboardingController.completeTask in P6). Proves
 * the checklist completion + rollup behaviour is preserved at the service layer: the Task is
 * marked Complete/Completed with today's ActivityDate, the optional note is appended, and
 * the parent Onboarding__c rollup is recomputed. Also covers the null-parent branch (a Task
 * with no Onboarding__c skips the rollup).
 *
 * This is a single-record operation (one Task update + one delegated rollup), so — like the
 * CounterOfferService precedent — there is no collection DML to bulk-test. The
 * controller-level tests separately cover the AuraHandledException mapping.
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
        t.Task_Owner_Label__c = 'Isha Patel'; t.ActivityDate = Date.today().addDays(3);
        insert t;

        Test.startTest();
        OnboardingService.completeTask(t.Id, 'Done via checkbox');
        Test.stopTest();

        Task after = [SELECT Onboarding_Status__c, Status, ActivityDate, Description FROM Task WHERE Id = :t.Id];
        Assert.areEqual('Complete', after.Onboarding_Status__c, 'onboarding status flips to Complete');
        Assert.areEqual('Completed', after.Status, 'standard status closed');
        Assert.areEqual(Date.today(), after.ActivityDate, 'completion stamps today');
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
     * Covers the `Onboarding__c != null` FALSE branch: a Task with no parent Onboarding is
     * completed but no rollup is triggered. (Exercises the guard the pre-thinning controller
     * carried, preserving its behaviour.)
     */
    @isTest
    static void completeTaskWithNoParentSkipsRollup() {
        Task t = new Task(Subject = 'Orphan task', Status = 'Not Started', Onboarding_Status__c = 'Not Started');
        insert t;

        Test.startTest();
        OnboardingService.completeTask(t.Id, 'note');
        Test.stopTest();

        Task after = [SELECT Onboarding_Status__c, Status FROM Task WHERE Id = :t.Id];
        Assert.areEqual('Complete', after.Onboarding_Status__c, 'orphan task still completes');
        Assert.areEqual('Completed', after.Status, 'standard status closed');
    }
}
