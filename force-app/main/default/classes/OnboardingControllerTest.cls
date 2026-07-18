@isTest
private class OnboardingControllerTest {
    @testSetup static void setup() {
        List<Onboarding__c> obs = TestDataFactory.createOnboardings(3, null, false);
        obs[0].Stage__c='Unit & Tenant Setup'; obs[0].Status__c='In Progress';
        obs[0].Onboarding_Lead__c='Isha Patel'; obs[0].Completion_Pct__c=80; obs[0].Tasks_Open__c=5;
        obs[0].Start_Date__c=Date.newInstance(2026,5,1); obs[0].Target_Completion_Date__c=Date.newInstance(2026,7,1);
        obs[0].Tasks_Total__c=100; obs[0].Tasks_Complete__c=80; obs[0].Tasks_In_Progress__c=10; obs[0].Tasks_Not_Started__c=6;
        obs[0].Tasks_Blocked__c=2; obs[0].Tasks_NA__c=2; obs[0].Tasks_Overdue__c=6; obs[0].Tasks_Blocked_Now__c=2;
        obs[0].Tasks_Stalled__c=3; obs[0].Tasks_Due_7d__c=4; obs[0].Days_To_Onboard__c=20; obs[0].Age_Days__c=10;
        obs[0].Oldest_Open_Days__c=15; obs[0].Is_Past_Target__c=false;

        obs[1].Stage__c='Leasing'; obs[1].Status__c='At Risk';
        obs[1].Onboarding_Lead__c='Endya Williams'; obs[1].Completion_Pct__c=40; obs[1].Tasks_Open__c=12;
        obs[1].Start_Date__c=Date.newInstance(2026,6,1); obs[1].Target_Completion_Date__c=Date.newInstance(2026,8,1);
        obs[1].Tasks_Total__c=100; obs[1].Tasks_Complete__c=40; obs[1].Tasks_In_Progress__c=30; obs[1].Tasks_Not_Started__c=24;
        obs[1].Tasks_Blocked__c=4; obs[1].Tasks_NA__c=2; obs[1].Tasks_Overdue__c=8; obs[1].Tasks_Blocked_Now__c=3;
        obs[1].Tasks_Stalled__c=5; obs[1].Tasks_Due_7d__c=6; obs[1].Days_To_Onboard__c=28; obs[1].Age_Days__c=14;
        obs[1].Oldest_Open_Days__c=41; obs[1].Is_Past_Target__c=true;

        obs[2].Stage__c='Onboarding Complete'; obs[2].Status__c='Complete';  // terminal — excluded from active
        obs[2].Tasks_Total__c=50; obs[2].Tasks_Complete__c=50;
        insert obs;
    }
    @isTest static void kpis() {
        Test.startTest();
        OnboardingController.Kpis k = OnboardingController.getKpis();
        Test.stopTest();
        System.assertEquals(2, k.propertiesInOnboarding, 'only active counted');
        System.assertEquals(60, k.avgCompletionPct, '(80+40)/(100+100) = 60%');
        System.assertEquals(14, k.overdueTasks, '6+8');
        System.assertEquals(24, k.avgDaysToOnboard, '(20+28)/2');
    }
    @isTest static void rows() {
        List<OnboardingController.Row> rows = OnboardingController.getOnboardings();
        System.assertEquals(2, rows.size());
        System.assertEquals('Isha Patel', rows[0].owner);
    }
    @isTest static void portfolio() {
        OnboardingController.Portfolio p = OnboardingController.getPortfolio();
        System.assertEquals(200, p.tasksTotal);
        System.assertEquals(120, p.complete);
        System.assertEquals(6, p.blocked);
    }
    @isTest static void riskAndSla() {
        OnboardingController.RiskAlerts a = OnboardingController.getRiskAlerts();
        System.assertEquals(14, a.overdue);
        System.assertEquals(1, a.pastTarget, 'one active onboarding is past target');
        OnboardingController.TimeSla t = OnboardingController.getTimeSla();
        System.assertEquals(1, t.pastTarget);
        System.assertEquals(41, t.oldestOpen);
    }
    @isTest static void checklist() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Stage__c = 'Property Set up'; o.Status__c = 'In Progress';
        insert o;
        List<Task> tasks = TestDataFactory.createOnboardingTasks(2, o.Id, false);
        tasks[0].Subject='Task A'; tasks[0].Onboarding_Category__c='Property Set up';
        tasks[0].Onboarding_Status__c='Complete'; tasks[0].Status='Completed'; tasks[0].Source_System__c='Yardi';
        tasks[0].Task_Owner_Label__c='Isha Patel'; tasks[0].ActivityDate=Date.today().addDays(-10);

        tasks[1].Subject='Task B'; tasks[1].Onboarding_Category__c='Leasing';
        tasks[1].Onboarding_Status__c='Not Started'; tasks[1].Status='Open'; tasks[1].Source_System__c='Excel';
        tasks[1].Task_Owner_Label__c='Fernando Ruiz'; tasks[1].ActivityDate=Date.today().addDays(-2);
        insert tasks;

        List<OnboardingController.ChecklistGroup> groups = OnboardingController.getChecklist(o.Id);
        System.assertEquals(7, groups.size(), 'all 7 categories returned in order');
        System.assertEquals('Property Set up', groups[0].category);
        System.assertEquals(1, groups[0].total);
        System.assertEquals(1, groups[0].complete);
        OnboardingController.ChecklistGroup leasing = groups[6];
        System.assertEquals('Leasing', leasing.category);
        System.assertEquals(true, leasing.items[0].overdue, 'open & past due');
    }
    @isTest static void completeTaskMarksCompleteAndRollsUp() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Stage__c = 'Property Set up'; o.Status__c = 'In Progress';
        insert o;
        List<Task> tasks = TestDataFactory.createOnboardingTasks(1, o.Id, false);
        Task t = tasks[0];
        t.Subject='Open task'; t.Onboarding_Category__c='Property Set up';
        t.Onboarding_Status__c='Not Started'; t.Status='Open'; t.Source_System__c='Yardi';
        t.Task_Owner_Label__c='Isha Patel'; t.ActivityDate=Date.today().addDays(3);
        insert t;
        Test.startTest();
        OnboardingController.completeTask(t.Id, 'Done via checkbox');
        Test.stopTest();
        Task after = [SELECT Onboarding_Status__c, Status, Description FROM Task WHERE Id = :t.Id];
        System.assertEquals('Complete', after.Onboarding_Status__c, 'status flips to Complete');
        System.assertEquals('Completed', after.Status, 'std status closed');
        System.assert(after.Description != null && after.Description.contains('Done via checkbox'), 'note appended');
        Onboarding__c rolled = [SELECT Tasks_Complete__c FROM Onboarding__c WHERE Id = :o.Id];
        System.assertEquals(1, rolled.Tasks_Complete__c, 'rollup sees the completed task');
    }
}
