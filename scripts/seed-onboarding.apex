// Seed the 6 onboardings shown on Screen 1.
//
// ⚠⚠ THIS SCRIPT CREATES ~270 TASKS. READ THIS BEFORE RUNNING IT. ⚠⚠
// `Onboarding_Task_Fanout` is an ACTIVE record-triggered flow (Start_Date__c != null AND
// Tasks_Fanned_Out__c = false, RecordAfterSave, CreateAndUpdate). Every row below sets
// Start_Date__c, and Tasks_Fanned_Out__c defaults to false, so the insert at the bottom fires
// that flow for all six — it calls OnboardingFanoutService, which creates the 45-row PM
// checklist per property (6 x 45 = ~270 Tasks) and then runs OnboardingTaskRollupService.recalc.
// That is EXPECTED and is the real production path; it is stated here so whoever runs this is
// not surprised by 270 new Tasks appearing in the org.
//
// ── COUNTERS ARE OWNED BY THE FAN-OUT, NOT BY THIS SCRIPT (fixed 2026-08-29) ──────────────
// This script used to hand-set twelve counters (Tasks_Total/Complete/In_Progress/Not_Started/
// Blocked/NA/Open/Overdue/Blocked_Now/Stalled/Due_7d and Completion_Pct) to hit the mockup's
// aggregates. Those are exactly the twelve fields OnboardingTaskRollupService.recalc writes, and
// recalc runs at the END of the fan-out this insert triggers (OnboardingFanoutService.fanOut
// ENQUEUES OnboardingFanoutQueueable, so the write-back lands in the next async transaction,
// seconds later) — so the hand-set values were OVERWRITTEN and the mockup numbers never survived.
// They are removed rather than the fan-out suppressed, so the demo shows the real, self-consistent
// production numbers instead of figures that silently disagree with the Tasks actually in the org.
// The counters below are the FOUR the rollup does NOT own (verified against
// OnboardingTaskRollupService.cls / OnboardingFanoutService.cls): Days_To_Onboard__c, Age_Days__c,
// Oldest_Open_Days__c, Is_Past_Target__c.
// ⚠ Consequence: the Screen-1 aggregates are now driven by the checklist (6 x 45 = 270 total,
// 0 complete, 0%), NOT by the mockup's 412/605 = 68%. If the mockup numbers are required for the
// demo, set them with a SEPARATE update AFTER this script (and after the fan-out has committed) —
// do not put them back on the insert, where the rollup will simply overwrite them again.
//
// ── SCOPED DELETE (fixed 2026-08-29) ──────────────────────────────────────────────────────
// The delete below used to be `delete [SELECT Id FROM Onboarding__c];` — completely unfiltered.
// On usman-dpeg (a real, non-sandbox Enterprise Edition org) that destroys live rows this script
// never created, e.g. ONB-0008 and its 45 real Tasks. It is now scoped to the SIX demo property
// names this script itself defines, so it can only remove its own prior runs.
// ⚠ Task.Onboarding__c is a Lookup with deleteConstraint=SetNull, so the previous run's checklist
// Tasks are NOT deleted with their parent — they are orphaned. Re-running therefore accumulates
// ~270 orphaned Tasks per run. Prefer running this ONCE.
// Reuses Property_Asset__c by name; never deletes a Property_Asset__c.

List<String> names = new List<String>{
    'Apex Beset Mall','Park North','The Fountains','Riverside Commons','Westgate Plaza','Dollar Tree Center'
};

// Scoped to this script's own six demo assets — never a bare `FROM Onboarding__c`.
delete [SELECT Id FROM Onboarding__c WHERE Property_Asset__r.Name IN :names];

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
        Status__c='In Progress', Onboarding_Lead__c='Isha Patel',
        Start_Date__c=Date.newInstance(2026,5,2), Target_Completion_Date__c=Date.newInstance(2026,7,15),
        Days_To_Onboard__c=20, Age_Days__c=10, Oldest_Open_Days__c=20, Is_Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idPark, Stage__c='NNN Reconciliation & Billing Setup',
        Status__c='In Progress', Onboarding_Lead__c='Fernando Ruiz',
        Start_Date__c=Date.newInstance(2026,4,18), Target_Completion_Date__c=Date.newInstance(2026,6,30),
        Days_To_Onboard__c=28, Age_Days__c=14, Oldest_Open_Days__c=30, Is_Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idFnt, Stage__c='Unit & Tenant Setup',
        Status__c='At Risk', Onboarding_Lead__c='Endya Williams',
        Start_Date__c=Date.newInstance(2026,6,1), Target_Completion_Date__c=Date.newInstance(2026,8,10),
        Days_To_Onboard__c=22, Age_Days__c=8, Oldest_Open_Days__c=15, Is_Past_Target__c=true),
    new Onboarding__c(Property_Asset__c=idRiv, Stage__c='Tenant Communication & Transition',
        Status__c='On Track', Onboarding_Lead__c='Isha Patel',
        Start_Date__c=Date.newInstance(2026,3,22), Target_Completion_Date__c=Date.newInstance(2026,5,30),
        Days_To_Onboard__c=18, Age_Days__c=16, Oldest_Open_Days__c=12, Is_Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idWest, Stage__c='Unit & Tenant Setup',
        Status__c='In Progress', Onboarding_Lead__c='Fernando Ruiz',
        Start_Date__c=Date.newInstance(2026,5,20), Target_Completion_Date__c=Date.newInstance(2026,7,28),
        Days_To_Onboard__c=30, Age_Days__c=12, Oldest_Open_Days__c=28, Is_Past_Target__c=false),
    new Onboarding__c(Property_Asset__c=idDoll, Stage__c='Property Set up',
        Status__c='Blocked', Onboarding_Lead__c='Endya Williams',
        Start_Date__c=Date.newInstance(2026,6,10), Target_Completion_Date__c=Date.newInstance(2026,8,22),
        Days_To_Onboard__c=26, Age_Days__c=12, Oldest_Open_Days__c=41, Is_Past_Target__c=true)
};
insert obs;   // fires Onboarding_Task_Fanout -> ~270 Tasks + the 12 rollup counters
System.debug('Inserted ' + obs.size() + ' onboardings. Onboarding_Task_Fanout will create ~'
    + (obs.size() * 45) + ' checklist Tasks and populate the Tasks_* / Completion_Pct__c counters.');
