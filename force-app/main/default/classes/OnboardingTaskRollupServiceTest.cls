@isTest
private class OnboardingTaskRollupServiceTest {
    @isTest static void recalcComputesRollups() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Stage__c = 'Unit & Tenant Setup'; o.Status__c = 'In Progress';
        insert o;
        Date td = Date.today();
        List<Task> tasks = TestDataFactory.createOnboardingTasks(4, o.Id, false);
        tasks[0].Subject='a'; tasks[0].Onboarding_Category__c='Unit & Tenant Setup';
        tasks[0].Onboarding_Status__c='Complete'; tasks[0].Status='Completed'; tasks[0].ActivityDate=td.addDays(-30);

        tasks[1].Subject='b'; tasks[1].Onboarding_Category__c='Unit & Tenant Setup';
        tasks[1].Onboarding_Status__c='In Progress'; tasks[1].Status='Open'; tasks[1].ActivityDate=td.addDays(3);

        tasks[2].Subject='c'; tasks[2].Onboarding_Category__c='Unit & Tenant Setup';
        tasks[2].Onboarding_Status__c='Blocked'; tasks[2].Status='Open'; tasks[2].ActivityDate=td.addDays(-5);

        tasks[3].Subject='d'; tasks[3].Onboarding_Category__c='Unit & Tenant Setup';
        tasks[3].Onboarding_Status__c='Not Applicable'; tasks[3].Status='Open'; tasks[3].ActivityDate=null;
        insert tasks;

        Test.startTest();
        OnboardingTaskRollupService.recalc(new Set<Id>{ o.Id });
        Test.stopTest();
        Onboarding__c r = [SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_NA__c, Tasks_Open__c,
                                  Tasks_Overdue__c, Tasks_Blocked_Now__c, Completion_Pct__c
                           FROM Onboarding__c WHERE Id = :o.Id];
        System.assertEquals(4, r.Tasks_Total__c);
        System.assertEquals(1, r.Tasks_Complete__c);
        System.assertEquals(1, r.Tasks_NA__c);
        System.assertEquals(2, r.Tasks_Open__c, 'in-progress + blocked');
        System.assertEquals(1, r.Tasks_Overdue__c, 'only the open, past-due blocked task (−5d); complete excluded, in-progress is future, N/A has no date');
        System.assertEquals(1, r.Tasks_Blocked_Now__c);
        System.assertEquals(25, r.Completion_Pct__c, '1 of 4 = 25%');
    }

    /**
     * Bulk scenario per .claude/rules/bulk-test-rule.md: 251 Tasks under one
     * Onboarding__c, forcing a second 200-record batch chunk through recalc's
     * single SOQL-then-single-DML shape (no SOQL/DML growth per task).
     */
    @isTest static void recalcHandlesBulk251Tasks() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, true);
        List<Task> tasks = TestDataFactory.createOnboardingTasks(251, o.Id, false);
        TestDataFactory.applyOverrides(tasks, new Map<String, Object>{
            'Onboarding_Status__c' => 'Not Started',
            'ActivityDate' => Date.today().addDays(7)
        });
        insert tasks;

        Test.startTest();
        OnboardingTaskRollupService.recalc(new Set<Id>{ o.Id });
        Test.stopTest();

        Onboarding__c r = [SELECT Tasks_Total__c, Tasks_Not_Started__c, Tasks_Open__c,
                                  Tasks_Complete__c, Completion_Pct__c
                           FROM Onboarding__c WHERE Id = :o.Id];
        System.assertEquals(251, r.Tasks_Total__c, 'all 251 tasks counted across the second batch chunk');
        System.assertEquals(251, r.Tasks_Not_Started__c);
        System.assertEquals(251, r.Tasks_Open__c);
        System.assertEquals(0, r.Tasks_Complete__c);
        System.assertEquals(0, r.Completion_Pct__c, '0 of 251 complete = 0%');
    }
}
