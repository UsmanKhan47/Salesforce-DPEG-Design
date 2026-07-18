// Seed the 6 onboardings shown on Screen 1. Aggregates hit the mockup:
//   6 properties; Σcomplete/Σtotal = 412/605 = 68%; Σoverdue = 14; avg days-to-onboard = 24.
//   Portfolio breakdown Σ: complete 412, in-progress 96, not-started 61, blocked 14, N/A 22.
//   Risk Σ: overdue 14, blocked-now 5, stalled 8, due-7d 19. SLA: avg age 12, past-target 2, oldest 41.
// Destructive on Onboarding__c demo data (scratch org); reuses Property_Asset__c by name.
delete [SELECT Id FROM Onboarding__c];

List<String> names = new List<String>{
    'Apex Beset Mall','Park North','The Fountains','Riverside Commons','Westgate Plaza','Dollar Tree Center'
};
Map<String, Property_Asset__c> assetByName = new Map<String, Property_Asset__c>();
for (Property_Asset__c a : [SELECT Id, Property_Name__c FROM Property_Asset__c WHERE Property_Name__c IN :names]) {
    assetByName.put(a.Property_Name__c, a);
}
List<Property_Asset__c> newAssets = new List<Property_Asset__c>();
for (String n : names) {
    if (!assetByName.containsKey(n)) newAssets.add(new Property_Asset__c(Name = n));
}
if (!newAssets.isEmpty()) { insert newAssets; for (Property_Asset__c a : newAssets) assetByName.put(a.Name, a); }
Id idApex = assetByName.get('Apex Beset Mall').Id;
Id idPark = assetByName.get('Park North').Id;
Id idFnt  = assetByName.get('The Fountains').Id;
Id idRiv  = assetByName.get('Riverside Commons').Id;
Id idWest = assetByName.get('Westgate Plaza').Id;
Id idDoll = assetByName.get('Dollar Tree Center').Id;

List<Onboarding__c> obs = new List<Onboarding__c>{
    new Onboarding__c(Property_Asset__c=idApex, Stage__c='Tenant Communication & Transition',
        Status__c='In Progress', Onboarding_Lead__c='Isha Patel', Completion_Pct__c=84, Tasks_Open__c=7,
        Start_Date__c=Date.newInstance(2026,5,2), Target_Completion_Date__c=Date.newInstance(2026,7,15),
        Tasks_Total__c=120, Tasks_Complete__c=95, Tasks_In_Progress__c=12, Tasks_Not_Started__c=9,
        Tasks_Blocked__c=2, Tasks_NA__c=2, Tasks_Overdue__c=2, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=1,
        Tasks_Due_7d__c=4, Days_To_Onboard__c=20, Age_Days__c=10, Oldest_Open_Days__c=20, Is_Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idPark, Stage__c='NNN Reconciliation & Billing Setup',
        Status__c='In Progress', Onboarding_Lead__c='Fernando Ruiz', Completion_Pct__c=72, Tasks_Open__c=13,
        Start_Date__c=Date.newInstance(2026,4,18), Target_Completion_Date__c=Date.newInstance(2026,6,30),
        Tasks_Total__c=45, Tasks_Complete__c=32, Tasks_In_Progress__c=6, Tasks_Not_Started__c=5,
        Tasks_Blocked__c=1, Tasks_NA__c=1, Tasks_Overdue__c=5, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=0,
        Tasks_Due_7d__c=3, Days_To_Onboard__c=28, Age_Days__c=14, Oldest_Open_Days__c=30, Is_Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idFnt, Stage__c='Unit & Tenant Setup',
        Status__c='At Risk', Onboarding_Lead__c='Endya Williams', Completion_Pct__c=41, Tasks_Open__c=22,
        Start_Date__c=Date.newInstance(2026,6,1), Target_Completion_Date__c=Date.newInstance(2026,8,10),
        Tasks_Total__c=130, Tasks_Complete__c=70, Tasks_In_Progress__c=30, Tasks_Not_Started__c=22,
        Tasks_Blocked__c=5, Tasks_NA__c=3, Tasks_Overdue__c=4, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=3,
        Tasks_Due_7d__c=4, Days_To_Onboard__c=22, Age_Days__c=8, Oldest_Open_Days__c=15, Is_Past_Target__c=true),
    new Onboarding__c(Property_Asset__c=idRiv, Stage__c='Tenant Communication & Transition',
        Status__c='On Track', Onboarding_Lead__c='Isha Patel', Completion_Pct__c=95, Tasks_Open__c=3,
        Start_Date__c=Date.newInstance(2026,3,22), Target_Completion_Date__c=Date.newInstance(2026,5,30),
        Tasks_Total__c=90, Tasks_Complete__c=80, Tasks_In_Progress__c=5, Tasks_Not_Started__c=2,
        Tasks_Blocked__c=1, Tasks_NA__c=2, Tasks_Overdue__c=0, Tasks_Blocked_Now__c=0, Tasks_Stalled__c=0,
        Tasks_Due_7d__c=2, Days_To_Onboard__c=18, Age_Days__c=16, Oldest_Open_Days__c=12, Is_Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idWest, Stage__c='Unit & Tenant Setup',
        Status__c='In Progress', Onboarding_Lead__c='Fernando Ruiz', Completion_Pct__c=58, Tasks_Open__c=15,
        Start_Date__c=Date.newInstance(2026,5,20), Target_Completion_Date__c=Date.newInstance(2026,7,28),
        Tasks_Total__c=110, Tasks_Complete__c=70, Tasks_In_Progress__c=25, Tasks_Not_Started__c=10,
        Tasks_Blocked__c=3, Tasks_NA__c=2, Tasks_Overdue__c=1, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=2,
        Tasks_Due_7d__c=3, Days_To_Onboard__c=30, Age_Days__c=12, Oldest_Open_Days__c=28, Is_Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idDoll, Stage__c='Property Set up',
        Status__c='Blocked', Onboarding_Lead__c='Endya Williams', Completion_Pct__c=12, Tasks_Open__c=28,
        Start_Date__c=Date.newInstance(2026,6,10), Target_Completion_Date__c=Date.newInstance(2026,8,22),
        Tasks_Total__c=110, Tasks_Complete__c=65, Tasks_In_Progress__c=18, Tasks_Not_Started__c=13,
        Tasks_Blocked__c=2, Tasks_NA__c=12, Tasks_Overdue__c=2, Tasks_Blocked_Now__c=1, Tasks_Stalled__c=2,
        Tasks_Due_7d__c=3, Days_To_Onboard__c=26, Age_Days__c=12, Oldest_Open_Days__c=41, Is_Past_Target__c=true)
};
insert obs;
System.debug('Inserted ' + obs.size() + ' onboardings.');
