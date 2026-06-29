@isTest
private class OnboardingControllerTest {
    @testSetup static void setup() {
        List<Onboarding__c> obs = new List<Onboarding__c>{
            new Onboarding__c(Stage__c='Unit & Tenant Setup', Status__c='In Progress',
                Onboarding_Lead__c='Isha Patel', Completion_Pct__c=80, Tasks_Open__c=5,
                Start_Date__c=Date.newInstance(2026,5,1), Target_Completion_Date__c=Date.newInstance(2026,7,1),
                Tasks_Total__c=100, Tasks_Complete__c=80, Tasks_In_Progress__c=10, Tasks_Not_Started__c=6,
                Tasks_Blocked__c=2, Tasks_NA__c=2, Tasks_Overdue__c=6, Tasks_Blocked_Now__c=2,
                Tasks_Stalled__c=3, Tasks_Due_7d__c=4, Days_To_Onboard__c=20, Age_Days__c=10,
                Oldest_Open_Days__c=15, Past_Target__c=false),
            new Onboarding__c(Stage__c='Leasing', Status__c='At Risk',
                Onboarding_Lead__c='Endya Williams', Completion_Pct__c=40, Tasks_Open__c=12,
                Start_Date__c=Date.newInstance(2026,6,1), Target_Completion_Date__c=Date.newInstance(2026,8,1),
                Tasks_Total__c=100, Tasks_Complete__c=40, Tasks_In_Progress__c=30, Tasks_Not_Started__c=24,
                Tasks_Blocked__c=4, Tasks_NA__c=2, Tasks_Overdue__c=8, Tasks_Blocked_Now__c=3,
                Tasks_Stalled__c=5, Tasks_Due_7d__c=6, Days_To_Onboard__c=28, Age_Days__c=14,
                Oldest_Open_Days__c=41, Past_Target__c=true),
            new Onboarding__c(Stage__c='Onboarding Complete', Status__c='Complete',
                Tasks_Total__c=50, Tasks_Complete__c=50)  // terminal — excluded from active
        };
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
        System.assertEquals(5, a.blocked);
        OnboardingController.TimeSla t = OnboardingController.getTimeSla();
        System.assertEquals(1, t.pastTarget);
        System.assertEquals(41, t.oldestOpen);
    }
    @isTest static void checklist() {
        Onboarding__c o = new Onboarding__c(Stage__c='Property Set up', Status__c='In Progress');
        insert o;
        insert new List<Task>{
            new Task(Onboarding__c=o.Id, Subject='Task A', Onboarding_Category__c='Property Set up',
                Onboarding_Status__c='Complete', Status='Completed', Source_System__c='Yardi',
                Task_Owner_Label__c='Isha Patel', ActivityDate=Date.today().addDays(-10)),
            new Task(Onboarding__c=o.Id, Subject='Task B', Onboarding_Category__c='Leasing',
                Onboarding_Status__c='Not Started', Status='Open', Source_System__c='Excel',
                Task_Owner_Label__c='Fernando Ruiz', ActivityDate=Date.today().addDays(-2))
        };
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
        Onboarding__c o = new Onboarding__c(Stage__c='Property Set up', Status__c='In Progress');
        insert o;
        Task t = new Task(Onboarding__c=o.Id, Subject='Open task', Onboarding_Category__c='Property Set up',
            Onboarding_Status__c='Not Started', Status='Open', Source_System__c='Yardi',
            Task_Owner_Label__c='Isha Patel', ActivityDate=Date.today().addDays(3));
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
