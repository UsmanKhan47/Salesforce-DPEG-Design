@isTest
private class OnboardingTaskRollupServiceTest {
    @isTest static void recalcComputesRollups() {
        Onboarding__c o = new Onboarding__c(Stage__c='Unit & Tenant Setup', Status__c='In Progress');
        insert o;
        Date td = Date.today();
        List<Task> tasks = new List<Task>{
            new Task(Onboarding__c=o.Id, Subject='a', Onboarding_Category__c='Unit & Tenant Setup',
                Onboarding_Status__c='Complete', Status='Completed', ActivityDate=td.addDays(-30)),
            new Task(Onboarding__c=o.Id, Subject='b', Onboarding_Category__c='Unit & Tenant Setup',
                Onboarding_Status__c='In Progress', Status='Open', ActivityDate=td.addDays(3)),
            new Task(Onboarding__c=o.Id, Subject='c', Onboarding_Category__c='Unit & Tenant Setup',
                Onboarding_Status__c='Blocked', Status='Open', ActivityDate=td.addDays(-5)),
            new Task(Onboarding__c=o.Id, Subject='d', Onboarding_Category__c='Unit & Tenant Setup',
                Onboarding_Status__c='Not Applicable', Status='Open', ActivityDate=null)
        };
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
}