// Load the 45 Onboarding_Task_Def__mdt records (PM Onboarding checklist, D-ON-3/D-ON-5) via the
// Apex Metadata API. Each row = { category, sequence, ownerLabel, sourceSystem, dueDayOffset,
// defaultStatus, conditional, subject }.
//
// Source of the 45 rows: scripts/seed-onboarding-tasks.apex:8-58, verbatim subject/category/owner/
// source-system text. Counts: Property Set up 7, Unit & Tenant Setup 14, Vendor & Expense
// Management 8, NNN Reconciliation & Billing Setup 6, Tenant Communication & Transition 6,
// Performance Tracking 1, Leasing 3 = 45.
//
// KNOWN GAP (D-ON-5, binding user decision): the FSD (5.1.5) specifies 3 Performance Tracking
// tasks; the seed only carries 1 ("Track KPIs in Salesforce"). The 2 missing task names are NOT
// invented here. Ship 45 now; add the 2 Performance Tracking rows later as a DATA-ONLY change
// (new CMDT records, no code, no deploy) once the user supplies the missing subjects.
//
// Due_Day_Offset__c is DERIVED, not client-supplied (OQ-2, option (a) from
// agent-output/design-onboarding-checklist.md). scripts/seed-onboarding-tasks.apex carries
// absolute demo dates, not offsets. Base date = Park North's Onboarding__c.Start_Date__c =
// 2026-04-18 (scripts/seed-onboarding.apex:36, the ONLY place that date is set for Park North).
// offset = seed task's absolute ActivityDate minus that base date, rounded to whole days.
// Range: +2 (Create new property record) to +90 (Set up lockbox services). ASSUMPTION FLAGGED
// FOR USER REVIEW: these are demo-data-derived SLAs, not client-authored ones, treat as a v1
// baseline pending real per-task offsets from the user.
//
// One exception: "Set up lockbox services" (Vendor & Expense Management) carries Status =
// 'Not Applicable' and a NULL ActivityDate in the seed (Park North does not use a lockbox), so
// there is no demo date to derive from. Placed at offset 90 (after every other Vendor & Expense
// Management task) as a reasonable default; flagged as an assumption, not a derivation.
//
// Default_Status__c is 'Not Started' for EVERY row, deliberately NOT copied from the seed's
// per-task Status column. The seed's Complete/In Progress/Blocked/Not Applicable values describe
// Park North's CURRENT demo state (a checklist already in progress), not the state a brand-new
// checklist should be CREATED in. Copying them would mean every future onboarding fans out with
// tasks already marked complete.
//
// Conditional__c is false for all 45 rows, no category in this checklist gates on another
// field today (parity note in agent-output/design-onboarding-checklist.md, A1).
//
// Restricted-picklist safety: Category__c values match
// objects/Activity/fields/Onboarding_Category__c.field-meta.xml character-for-character (note
// "Property Set up", lowercase "up", and the "&" characters). Source_System__c values match
// objects/Activity/fields/Source_System__c.field-meta.xml (Yardi/Excel/Salesforce/Email).
// OnboardingFanoutService must insert Tasks via these exact literals or the restricted-picklist
// DML enforcement on Task.Onboarding_Category__c / Task.Source_System__c fails the insert at
// RUNTIME, not at deploy (measured 4x elsewhere in this org, restricted picklists ARE enforced
// by DML here, not UI-only).
//
// Deploy recommendation: run THIS SCRIPT, not the customMetadata/*.md-meta.xml sibling files.
// .forceignore:16 (**/customMetadata/**) excludes force-app/main/default/customMetadata/** from
// every deploy/retrieve in this org, with the reason recorded in the file itself: file-based CMDT
// record deploys throw UNKNOWN_EXCEPTION here. The .md-meta.xml files under
// force-app/main/default/customMetadata/ are shipped alongside this script for documentation and
// diffability only, they are NOT a working deploy path in this org. Run this script with
// `sf apex run --file scripts/load-onboarding-task-defs.apex` from PowerShell (verified working
// 2026-08-22; an earlier note here claimed sf apex run was classifier-blocked for other agents in
// this repo, that is NOT true). Metadata.Operations.enqueueDeployment is ASYNCHRONOUS, so the
// 45 records are not queryable the instant this script returns; poll or wait before reading back.

// SPLIT DELIBERATELY INTO TWO addAll() CALLS -- DO NOT MERGE BACK INTO ONE LITERAL.
// A single collection-initializer literal holding all 45 nested `new List<Object>{...}` rows
// exceeds an Apex parser complexity threshold and fails to compile with:
//     Compilation failed at Line 57 column 5: Unexpected token '<'.
// (line 57 was the declaration below, before this split)
// That error points at the STATEMENT'S START, up to 45 lines away from where the parser actually
// gives up, so it reads like a syntax error in the declaration itself. It is not. Measured:
// rows 1-22 alone compile, rows 23-45 alone compile, a 2-row literal compiles, all 45 in one
// literal do not. The two addAll() calls below keep all 45 rows byte-identical and compile.
List<List<Object>> defs = new List<List<Object>>();
defs.addAll(new List<List<Object>>{
    new List<Object>{ 'Property Set up', 1, 'Isha Patel', 'Salesforce', 2, 'Not Started', false, 'Create new property record' },
    new List<Object>{ 'Property Set up', 2, 'Isha Patel', 'Salesforce', 3, 'Not Started', false, 'Enter basic property details (name, address, sq ft, type)' },
    new List<Object>{ 'Property Set up', 3, 'Fernando Ruiz', 'Yardi', 6, 'Not Started', false, 'Link bank accounts for rent & expenses' },
    new List<Object>{ 'Property Set up', 4, 'Accounting Queue', 'Yardi', 7, 'Not Started', false, 'Set up property GL accounts' },
    new List<Object>{ 'Property Set up', 5, 'Isha Patel', 'Yardi', 8, 'Not Started', false, 'Configure property management settings' },
    new List<Object>{ 'Property Set up', 6, 'Endya Williams', 'Salesforce', 10, 'Not Started', false, 'Upload property photos & documents' },
    new List<Object>{ 'Property Set up', 7, 'Isha Patel', 'Salesforce', 4, 'Not Started', false, 'Assign onboarding owner & timeline' },
    new List<Object>{ 'Unit & Tenant Setup', 8, 'Fernando Ruiz', 'Yardi', 14, 'Not Started', false, 'Enter unit inventory (all units)' },
    new List<Object>{ 'Unit & Tenant Setup', 9, 'Fernando Ruiz', 'Yardi', 18, 'Not Started', false, 'Enter tenant leases (all tenants)' },
    new List<Object>{ 'Unit & Tenant Setup', 10, 'Endya Williams', 'Excel', 20, 'Not Started', false, 'Verify lease terms vs abstracts' },
    new List<Object>{ 'Unit & Tenant Setup', 11, 'Fernando Ruiz', 'Yardi', 21, 'Not Started', false, 'Enter base rent schedules' },
    new List<Object>{ 'Unit & Tenant Setup', 12, 'Fernando Ruiz', 'Yardi', 24, 'Not Started', false, 'Enter rent escalations / bumps' },
    new List<Object>{ 'Unit & Tenant Setup', 13, 'Fernando Ruiz', 'Yardi', 25, 'Not Started', false, 'Set up recurring charges' },
    new List<Object>{ 'Unit & Tenant Setup', 14, 'Accounting Queue', 'Yardi', 26, 'Not Started', false, 'Enter security deposits' },
    new List<Object>{ 'Unit & Tenant Setup', 15, 'Fernando Ruiz', 'Yardi', 22, 'Not Started', false, 'Map tenants to units' },
    new List<Object>{ 'Unit & Tenant Setup', 16, 'Endya Williams', 'Yardi', 27, 'Not Started', false, 'Verify occupancy / vacancy status' },
    new List<Object>{ 'Unit & Tenant Setup', 17, 'Accounting Queue', 'Excel', 28, 'Not Started', false, 'Reconcile rent roll to closing statement' },
    new List<Object>{ 'Unit & Tenant Setup', 18, 'Fernando Ruiz', 'Excel', 76, 'Not Started', false, 'Set up CAM pro-rata share per tenant' },
    new List<Object>{ 'Unit & Tenant Setup', 19, 'Endya Williams', 'Excel', 78, 'Not Started', false, 'Enter lease options & renewals' },
    new List<Object>{ 'Unit & Tenant Setup', 20, 'Accounting Queue', 'Yardi', 61, 'Not Started', false, 'Import outstanding tenant balances (A/R)' },
    new List<Object>{ 'Unit & Tenant Setup', 21, 'Endya Williams', 'Salesforce', 83, 'Not Started', false, 'Enter co-tenancy / exclusivity clauses' },
    new List<Object>{ 'Vendor & Expense Management', 22, 'Accounting Queue', 'Yardi', 32, 'Not Started', false, 'Enter vendor list & W-9s' }
});
// (continued -- see the SPLIT DELIBERATELY note above; this is one list, not two.)
defs.addAll(new List<List<Object>>{
    new List<Object>{ 'Vendor & Expense Management', 23, 'Accounting Queue', 'Yardi', 34, 'Not Started', false, 'Set up recurring vendor payments' },
    new List<Object>{ 'Vendor & Expense Management', 24, 'Accounting Queue', 'Yardi', 35, 'Not Started', false, 'Map expense GL accounts' },
    new List<Object>{ 'Vendor & Expense Management', 25, 'Endya Williams', 'Excel', 37, 'Not Started', false, 'Enter service contracts (landscaping, security)' },
    new List<Object>{ 'Vendor & Expense Management', 26, 'Accounting Queue', 'Yardi', 38, 'Not Started', false, 'Enter insurance policies & premiums' },
    new List<Object>{ 'Vendor & Expense Management', 27, 'Accounting Queue', 'Excel', 40, 'Not Started', false, 'Load historical operating expenses' },
    new List<Object>{ 'Vendor & Expense Management', 28, 'Endya Williams', 'Email', 75, 'Not Started', false, 'Set up utility accounts & transfers' },
    new List<Object>{ 'Vendor & Expense Management', 29, 'Accounting Queue', 'Email', 90, 'Not Started', false, 'Set up lockbox services' },
    new List<Object>{ 'NNN Reconciliation & Billing Setup', 30, 'Accounting Queue', 'Yardi', 42, 'Not Started', false, 'Define NNN charges (CAM, taxes, insurance)' },
    new List<Object>{ 'NNN Reconciliation & Billing Setup', 31, 'Accounting Queue', 'Excel', 45, 'Not Started', false, 'Enter prior-year reconciliation true-ups' },
    new List<Object>{ 'NNN Reconciliation & Billing Setup', 32, 'Fernando Ruiz', 'Yardi', 48, 'Not Started', false, 'Set tenant billing schedules' },
    new List<Object>{ 'NNN Reconciliation & Billing Setup', 33, 'Accounting Queue', 'Yardi', 65, 'Not Started', false, 'Set up NNN recovery pools' },
    new List<Object>{ 'NNN Reconciliation & Billing Setup', 34, 'Accounting Queue', 'Excel', 58, 'Not Started', false, 'Configure gross-up & recovery caps' },
    new List<Object>{ 'NNN Reconciliation & Billing Setup', 35, 'Accounting Queue', 'Yardi', 63, 'Not Started', false, 'Generate first NNN tenant statements' },
    new List<Object>{ 'Tenant Communication & Transition', 36, 'Isha Patel', 'Email', 16, 'Not Started', false, 'Send tenant welcome letters' },
    new List<Object>{ 'Tenant Communication & Transition', 37, 'Isha Patel', 'Email', 17, 'Not Started', false, 'Notify tenants of new payment instructions' },
    new List<Object>{ 'Tenant Communication & Transition', 38, 'Endya Williams', 'Salesforce', 30, 'Not Started', false, 'Update tenant portal access' },
    new List<Object>{ 'Tenant Communication & Transition', 39, 'Endya Williams', 'Email', 32, 'Not Started', false, 'Schedule tenant transition meetings' },
    new List<Object>{ 'Tenant Communication & Transition', 40, 'Endya Williams', 'Excel', 34, 'Not Started', false, 'Collect updated tenant contact info' },
    new List<Object>{ 'Tenant Communication & Transition', 41, 'Isha Patel', 'Email', 55, 'Not Started', false, 'Send estoppel confirmation follow-ups' },
    new List<Object>{ 'Performance Tracking', 42, 'Isha Patel', 'Salesforce', 88, 'Not Started', false, 'Track KPIs in Salesforce' },
    new List<Object>{ 'Leasing', 43, 'Isha Patel', 'Email', 44, 'Not Started', false, 'Sign listing agreement with brokerage' },
    new List<Object>{ 'Leasing', 44, 'Endya Williams', 'Salesforce', 81, 'Not Started', false, 'Set up available space listings' },
    new List<Object>{ 'Leasing', 45, 'Fernando Ruiz', 'Excel', 85, 'Not Started', false, 'Define leasing commission schedule' }
});

Metadata.DeployContainer container = new Metadata.DeployContainer();
for (List<Object> d : defs) {
    String category = (String) d[0];
    Integer seq = (Integer) d[1];
    String owner = (String) d[2];
    String source = (String) d[3];
    Integer offset = (Integer) d[4];
    String defaultStatus = (String) d[5];
    Boolean conditional = (Boolean) d[6];
    String subject = (String) d[7];

    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
    cm.fullName = 'Onboarding_Task_Def.Task_Def_' + (seq < 10 ? '0' + seq : '' + seq);
    cm.label = subject.length() > 40 ? subject.substring(0, 40) : subject;

    Map<String, Object> fv = new Map<String, Object>{
        'Category__c' => category, 'Subject__c' => subject, 'Sequence__c' => seq,
        'Owner_Label__c' => owner, 'Source_System__c' => source, 'Due_Day_Offset__c' => offset,
        'Default_Status__c' => defaultStatus, 'Conditional__c' => conditional
    };
    for (String f : fv.keySet()) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = f;
        v.value = fv.get(f);
        cm.values.add(v);
    }
    container.addMetadata(cm);
}
System.debug('Enqueued ' + defs.size() + ' onboarding task-def deploy: ' + Metadata.Operations.enqueueDeployment(container, null));
