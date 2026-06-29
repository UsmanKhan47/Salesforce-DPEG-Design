// Seed Park North's 45 onboarding checklist Tasks (Screen 2), then roll up onto the Onboarding.
// Row = {category, subject, onboardingStatus, ownerLabel, sourceSystem, dueDate(or null), blockedReason(or null), hasNotes}
Id parkId = [SELECT Id FROM Onboarding__c WHERE Property_Asset__r.Property_Name__c = 'Park North' LIMIT 1].Id;
delete [SELECT Id FROM Task WHERE Onboarding__c = :parkId];

List<List<Object>> r = new List<List<Object>>{
    // Property Set up (7, all Complete)
    new List<Object>{'Property Set up','Create new property record','Complete','Isha Patel','Salesforce',Date.newInstance(2026,4,20),null,true},
    new List<Object>{'Property Set up','Enter basic property details (name, address, sq ft, type)','Complete','Isha Patel','Salesforce',Date.newInstance(2026,4,21),null,true},
    new List<Object>{'Property Set up','Link bank accounts for rent & expenses','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,4,24),null,false},
    new List<Object>{'Property Set up','Set up property GL accounts','Complete','Accounting Queue','Yardi',Date.newInstance(2026,4,25),null,false},
    new List<Object>{'Property Set up','Configure property management settings','Complete','Isha Patel','Yardi',Date.newInstance(2026,4,26),null,false},
    new List<Object>{'Property Set up','Upload property photos & documents','Complete','Endya Williams','Salesforce',Date.newInstance(2026,4,28),null,false},
    new List<Object>{'Property Set up','Assign onboarding owner & timeline','Complete','Isha Patel','Salesforce',Date.newInstance(2026,4,22),null,true},
    // Unit & Tenant Setup (14)
    new List<Object>{'Unit & Tenant Setup','Enter unit inventory (all units)','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,2),null,false},
    new List<Object>{'Unit & Tenant Setup','Enter tenant leases (all tenants)','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,6),null,true},
    new List<Object>{'Unit & Tenant Setup','Verify lease terms vs abstracts','Complete','Endya Williams','Excel',Date.newInstance(2026,5,8),null,true},
    new List<Object>{'Unit & Tenant Setup','Enter base rent schedules','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,9),null,false},
    new List<Object>{'Unit & Tenant Setup','Enter rent escalations / bumps','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,12),null,false},
    new List<Object>{'Unit & Tenant Setup','Set up recurring charges','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,13),null,false},
    new List<Object>{'Unit & Tenant Setup','Enter security deposits','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,14),null,false},
    new List<Object>{'Unit & Tenant Setup','Map tenants to units','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,5,10),null,false},
    new List<Object>{'Unit & Tenant Setup','Verify occupancy / vacancy status','Complete','Endya Williams','Yardi',Date.newInstance(2026,5,15),null,false},
    new List<Object>{'Unit & Tenant Setup','Reconcile rent roll to closing statement','Complete','Accounting Queue','Excel',Date.newInstance(2026,5,16),null,false},
    new List<Object>{'Unit & Tenant Setup','Set up CAM pro-rata share per tenant','In Progress','Fernando Ruiz','Excel',Date.newInstance(2026,7,3),null,true},
    new List<Object>{'Unit & Tenant Setup','Enter lease options & renewals','In Progress','Endya Williams','Excel',Date.newInstance(2026,7,5),null,false},
    new List<Object>{'Unit & Tenant Setup','Import outstanding tenant balances (A/R)','Blocked','Accounting Queue','Yardi',Date.newInstance(2026,6,18),'Blocked: awaiting seller closing statement',true},
    new List<Object>{'Unit & Tenant Setup','Enter co-tenancy / exclusivity clauses','Not Started','Endya Williams','Salesforce',Date.newInstance(2026,7,10),null,false},
    // Vendor & Expense Management (8)
    new List<Object>{'Vendor & Expense Management','Enter vendor list & W-9s','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,20),null,false},
    new List<Object>{'Vendor & Expense Management','Set up recurring vendor payments','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,22),null,false},
    new List<Object>{'Vendor & Expense Management','Map expense GL accounts','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,23),null,false},
    new List<Object>{'Vendor & Expense Management','Enter service contracts (landscaping, security)','Complete','Endya Williams','Excel',Date.newInstance(2026,5,25),null,false},
    new List<Object>{'Vendor & Expense Management','Enter insurance policies & premiums','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,26),null,false},
    new List<Object>{'Vendor & Expense Management','Load historical operating expenses','Complete','Accounting Queue','Excel',Date.newInstance(2026,5,28),null,false},
    new List<Object>{'Vendor & Expense Management','Set up utility accounts & transfers','In Progress','Endya Williams','Email',Date.newInstance(2026,7,2),null,true},
    new List<Object>{'Vendor & Expense Management','Set up lockbox services','Not Applicable','Accounting Queue','Email',null,'tenants remit via ACH',false},
    // NNN Reconciliation & Billing Setup (6)
    new List<Object>{'NNN Reconciliation & Billing Setup','Define NNN charges (CAM, taxes, insurance)','Complete','Accounting Queue','Yardi',Date.newInstance(2026,5,30),null,true},
    new List<Object>{'NNN Reconciliation & Billing Setup','Enter prior-year reconciliation true-ups','Complete','Accounting Queue','Excel',Date.newInstance(2026,6,2),null,false},
    new List<Object>{'NNN Reconciliation & Billing Setup','Set tenant billing schedules','Complete','Fernando Ruiz','Yardi',Date.newInstance(2026,6,5),null,false},
    new List<Object>{'NNN Reconciliation & Billing Setup','Set up NNN recovery pools','In Progress','Accounting Queue','Yardi',Date.newInstance(2026,6,22),null,true},
    new List<Object>{'NNN Reconciliation & Billing Setup','Configure gross-up & recovery caps','Not Started','Accounting Queue','Excel',Date.newInstance(2026,6,15),null,false},
    new List<Object>{'NNN Reconciliation & Billing Setup','Generate first NNN tenant statements','Not Started','Accounting Queue','Yardi',Date.newInstance(2026,6,20),null,false},
    // Tenant Communication & Transition (6)
    new List<Object>{'Tenant Communication & Transition','Send tenant welcome letters','Complete','Isha Patel','Email',Date.newInstance(2026,5,4),null,false},
    new List<Object>{'Tenant Communication & Transition','Notify tenants of new payment instructions','Complete','Isha Patel','Email',Date.newInstance(2026,5,5),null,false},
    new List<Object>{'Tenant Communication & Transition','Update tenant portal access','Complete','Endya Williams','Salesforce',Date.newInstance(2026,5,18),null,false},
    new List<Object>{'Tenant Communication & Transition','Schedule tenant transition meetings','Complete','Endya Williams','Email',Date.newInstance(2026,5,20),null,true},
    new List<Object>{'Tenant Communication & Transition','Collect updated tenant contact info','Complete','Endya Williams','Excel',Date.newInstance(2026,5,22),null,false},
    new List<Object>{'Tenant Communication & Transition','Send estoppel confirmation follow-ups','Not Started','Isha Patel','Email',Date.newInstance(2026,6,12),null,false},
    // Performance Tracking (1)
    new List<Object>{'Performance Tracking','Track KPIs in Salesforce','In Progress','Isha Patel','Salesforce',Date.newInstance(2026,7,15),null,true},
    // Leasing (3)
    new List<Object>{'Leasing','Sign listing agreement with brokerage','Complete','Isha Patel','Email',Date.newInstance(2026,6,1),null,false},
    new List<Object>{'Leasing','Set up available space listings','In Progress','Endya Williams','Salesforce',Date.newInstance(2026,7,8),null,false},
    new List<Object>{'Leasing','Define leasing commission schedule','Not Started','Fernando Ruiz','Excel',Date.newInstance(2026,7,12),null,false}
};

List<Task> tasks = new List<Task>();
for (List<Object> row : r) {
    String status = (String) row[2];
    tasks.add(new Task(
        OwnerId = UserInfo.getUserId(),
        Onboarding__c = parkId,
        Onboarding_Category__c = (String) row[0],
        Subject = (String) row[1],
        Onboarding_Status__c = status,
        Task_Owner_Label__c = (String) row[3],
        Source_System__c = (String) row[4],
        ActivityDate = (Date) row[5],
        Blocked_Reason__c = (String) row[6],
        Status = (status == 'Complete') ? 'Completed' : 'Open',
        Description = ((Boolean) row[7]) ? 'See onboarding notes.' : null
    ));
}
insert tasks;
OnboardingTaskRollupService.recalc(new Set<Id>{ parkId });
System.debug('Inserted ' + tasks.size() + ' Park North checklist tasks.');
