// Seed realistic checklist Tasks for every onboarding EXCEPT Park North (which already has a
// curated 45-task checklist). Status is derived from each record's Path stage so the checklist
// stays coherent with the stage shown on the page; due dates produce a natural overdue spread.
// Re-runnable: deletes and rebuilds tasks for the 5 target records, then rolls up.

// Category order MUST match OnboardingController.CATEGORY_ORDER.
List<String> CATS = new List<String>{
    'Property Set up','Unit & Tenant Setup','Vendor & Expense Management',
    'NNN Reconciliation & Billing Setup','Tenant Communication & Transition',
    'Performance Tracking','Leasing'
};
Map<String,Integer> CAT_IDX = new Map<String,Integer>();
for (Integer i = 0; i < CATS.size(); i++) CAT_IDX.put(CATS[i], i);

// Template row = {categoryIndex, subject, ownerLabel, sourceSystem, hasNotes}
List<List<Object>> T = new List<List<Object>>{
    // Property Set up (7)
    new List<Object>{0,'Create new property record','Isha Patel','Salesforce',true},
    new List<Object>{0,'Enter basic property details (name, address, sq ft, type)','Isha Patel','Salesforce',true},
    new List<Object>{0,'Link bank accounts for rent & expenses','Fernando Ruiz','Yardi',false},
    new List<Object>{0,'Set up property GL accounts','Accounting Queue','Yardi',false},
    new List<Object>{0,'Configure property management settings','Isha Patel','Yardi',false},
    new List<Object>{0,'Upload property photos & documents','Endya Williams','Salesforce',false},
    new List<Object>{0,'Assign onboarding owner & timeline','Isha Patel','Salesforce',true},
    // Unit & Tenant Setup (14)
    new List<Object>{1,'Enter unit inventory (all units)','Fernando Ruiz','Yardi',false},
    new List<Object>{1,'Enter tenant leases (all tenants)','Fernando Ruiz','Yardi',true},
    new List<Object>{1,'Verify lease terms vs abstracts','Endya Williams','Excel',true},
    new List<Object>{1,'Enter base rent schedules','Fernando Ruiz','Yardi',false},
    new List<Object>{1,'Enter rent escalations / bumps','Fernando Ruiz','Yardi',false},
    new List<Object>{1,'Set up recurring charges','Fernando Ruiz','Yardi',false},
    new List<Object>{1,'Enter security deposits','Accounting Queue','Yardi',false},
    new List<Object>{1,'Map tenants to units','Fernando Ruiz','Yardi',false},
    new List<Object>{1,'Verify occupancy / vacancy status','Endya Williams','Yardi',false},
    new List<Object>{1,'Reconcile rent roll to closing statement','Accounting Queue','Excel',false},
    new List<Object>{1,'Set up CAM pro-rata share per tenant','Fernando Ruiz','Excel',true},
    new List<Object>{1,'Enter lease options & renewals','Endya Williams','Excel',false},
    new List<Object>{1,'Import outstanding tenant balances (A/R)','Accounting Queue','Yardi',true},
    new List<Object>{1,'Enter co-tenancy / exclusivity clauses','Endya Williams','Salesforce',false},
    // Vendor & Expense Management (8)
    new List<Object>{2,'Enter vendor list & W-9s','Accounting Queue','Yardi',false},
    new List<Object>{2,'Set up recurring vendor payments','Accounting Queue','Yardi',false},
    new List<Object>{2,'Map expense GL accounts','Accounting Queue','Yardi',false},
    new List<Object>{2,'Enter service contracts (landscaping, security)','Endya Williams','Excel',false},
    new List<Object>{2,'Enter insurance policies & premiums','Accounting Queue','Yardi',false},
    new List<Object>{2,'Load historical operating expenses','Accounting Queue','Excel',false},
    new List<Object>{2,'Set up utility accounts & transfers','Endya Williams','Email',true},
    new List<Object>{2,'Set up lockbox services','Accounting Queue','Email',false}, // always N/A
    // NNN Reconciliation & Billing Setup (6)
    new List<Object>{3,'Define NNN charges (CAM, taxes, insurance)','Accounting Queue','Yardi',true},
    new List<Object>{3,'Enter prior-year reconciliation true-ups','Accounting Queue','Excel',false},
    new List<Object>{3,'Set tenant billing schedules','Fernando Ruiz','Yardi',false},
    new List<Object>{3,'Set up NNN recovery pools','Accounting Queue','Yardi',true},
    new List<Object>{3,'Configure gross-up & recovery caps','Accounting Queue','Excel',false},
    new List<Object>{3,'Generate first NNN tenant statements','Accounting Queue','Yardi',false},
    // Tenant Communication & Transition (6)
    new List<Object>{4,'Send tenant welcome letters','Isha Patel','Email',false},
    new List<Object>{4,'Notify tenants of new payment instructions','Isha Patel','Email',false},
    new List<Object>{4,'Update tenant portal access','Endya Williams','Salesforce',false},
    new List<Object>{4,'Schedule tenant transition meetings','Endya Williams','Email',true},
    new List<Object>{4,'Collect updated tenant contact info','Endya Williams','Excel',false},
    new List<Object>{4,'Send estoppel confirmation follow-ups','Isha Patel','Email',false},
    // Performance Tracking (3)
    new List<Object>{5,'Track KPIs in Salesforce','Isha Patel','Salesforce',true},
    new List<Object>{5,'Set up monthly owner reporting package','Isha Patel','Excel',false},
    new List<Object>{5,'Configure variance / budget tracking','Accounting Queue','Yardi',false},
    // Leasing (3)
    new List<Object>{6,'Sign listing agreement with brokerage','Isha Patel','Email',false},
    new List<Object>{6,'Set up available space listings','Endya Williams','Salesforce',false},
    new List<Object>{6,'Define leasing commission schedule','Fernando Ruiz','Excel',false}
};

// Per-property completion fraction within the active (current-stage) category — adds variety.
Map<String,Decimal> FRAC = new Map<String,Decimal>{
    'Apex Beset Mall' => 0.5, 'The Fountains' => 0.45, 'Riverside Commons' => 0.4,
    'Westgate Plaza' => 0.75, 'Dollar Tree Center' => 0.65
};
Map<String,String> BLOCK_REASON = new Map<String,String>{
    'Apex Beset Mall' => 'Blocked: awaiting tenant signature',
    'The Fountains' => 'Blocked: missing executed lease abstract',
    'Riverside Commons' => 'Blocked: bank account verification pending',
    'Westgate Plaza' => 'Blocked: seller has not delivered rent roll',
    'Dollar Tree Center' => 'Blocked: GL mapping under review'
};

Date today = Date.today();
List<Onboarding__c> targets = [
    SELECT Id, Property_Name__c, Stage__c FROM Onboarding__c WHERE Property_Name__c != 'Park North'
];
Set<Id> targetIds = new Map<Id,Onboarding__c>(targets).keySet();
delete [SELECT Id FROM Task WHERE Onboarding__c IN :targetIds];

List<Task> tasks = new List<Task>();
for (Onboarding__c o : targets) {
    Integer stageIdx = CAT_IDX.containsKey(o.Stage__c) ? CAT_IDX.get(o.Stage__c) : CATS.size(); // not found => all complete
    Decimal frac = FRAC.containsKey(o.Property_Name__c) ? FRAC.get(o.Property_Name__c) : 0.5;
    String blockReason = BLOCK_REASON.containsKey(o.Property_Name__c) ? BLOCK_REASON.get(o.Property_Name__c) : 'Blocked: awaiting upstream input';

    // Count rows in the active category to find the done-cutoff.
    Integer activeCount = 0;
    for (List<Object> row : T) if ((Integer) row[0] == stageIdx) activeCount++;
    Integer activeDone = (Integer) Math.floor(activeCount * frac);

    Integer activePos = 0;
    Integer ri = 0;
    for (List<Object> row : T) {
        Integer cat = (Integer) row[0];
        String subject = (String) row[1];
        Boolean hasNotes = (Boolean) row[4];
        String status;
        String blocked = null;

        if (cat < stageIdx) {
            status = 'Complete';
        } else if (cat > stageIdx) {
            status = 'Not Started';
        } else {
            if (activePos < activeDone) status = 'Complete';
            else if (activePos == activeDone) { status = 'Blocked'; blocked = blockReason; }
            else if (activePos == activeDone + 1) status = 'In Progress';
            else status = 'Not Started';
            activePos++;
        }
        // Lockbox is universally not applicable for these centers.
        if (subject == 'Set up lockbox services') { status = 'Not Applicable'; blocked = null; }

        // Due date: completed in the past; blocked overdue; open spread with a few overdue.
        Date due;
        if (status == 'Not Applicable') due = null;
        else if (status == 'Complete') due = today.addDays(-(18 + Math.mod(ri, 30)));
        else if (status == 'Blocked') due = today.addDays(-6);
        else if (status == 'In Progress') due = (Math.mod(ri, 3) == 0) ? today.addDays(-4) : today.addDays(5 + Math.mod(ri, 6));
        else /* Not Started */ due = (Math.mod(ri, 4) == 0) ? today.addDays(-3) : today.addDays(9 + Math.mod(ri, 14));

        tasks.add(new Task(
            OwnerId = UserInfo.getUserId(),
            Onboarding__c = o.Id,
            Onboarding_Category__c = CATS[cat],
            Subject = subject,
            Onboarding_Status__c = status,
            Task_Owner_Label__c = (String) row[2],
            Source_System__c = (String) row[3],
            ActivityDate = due,
            Blocked_Reason__c = blocked,
            Status = (status == 'Complete') ? 'Completed' : 'Open',
            Description = hasNotes ? 'See onboarding notes.' : null
        ));
        ri++;
    }
}
insert tasks;
OnboardingTaskRollupService.recalc(targetIds);
System.debug('Inserted ' + tasks.size() + ' checklist tasks across ' + targets.size() + ' onboardings.');
