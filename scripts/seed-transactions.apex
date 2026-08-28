// Seed the 5 Active Transactions shown in both mockups (KPI row + table) and the record page.
//   Prices: 31.5 + 52.2 + 18.9 + 41.7 + 14.4 = $158.7M → KPI "In Contract" rounds to $159M
//   TTC spans (Target − Executed): 70 + 55 + 60 + 75 + 60 = 320 / 5 = 64d avg
//   Earnest at risk: 0.9M (Magnolia) + 1.5M (Cypress) = $2.4M
//   Wire approvals due: Magnolia + Beltway = 2 ; Missed feasibility YTD = 0
//   EM Wired Date = Contract Executed + 4d (drives the EM Wired highlights tile)
// Destructive on Transaction__c demo data — clears then reseeds. SCRATCH ORG / SANDBOX ONLY; enforced by the guard below.
Date toughDay = Date.today();

// ─────────────────────────────────────────────────────────────────────────────
// 🔴 REFUSE-TO-RUN GUARD (added 2026-08-28). The `delete` below is UNGUARDED and
// UNFILTERED — it removes EVERY Transaction__c row in the org, not just seeded
// demo rows. Line 7 calls this file "(scratch org)" but nothing enforced it, and
// `usman-dpeg` is a real non-sandbox Enterprise Edition org holding live data.
//
// ⚠ DO NOT "SIMPLIFY" THIS TO `TrialExpirationDate != null`, THE USUAL SCRATCH-ORG
// HEURISTIC. MEASURED on usman-dpeg 2026-08-28: IsSandbox=false,
// TrialExpirationDate=2027-07-16 (NON-NULL), OrganizationType='Enterprise Edition'.
// It is a TRIAL EE org, so that heuristic evaluates true here and would wave the
// delete straight through. `IsSandbox` is the only field that discriminates:
// scratch orgs and sandboxes report true, this org reports false.
Organization seedOrgCheck = [SELECT Name, IsSandbox, OrganizationType FROM Organization LIMIT 1];
System.assert(
    seedOrgCheck.IsSandbox == true,
    'REFUSED: seed-transactions.apex deletes EVERY Transaction__c row and only runs on a scratch '
    + 'org or sandbox. This org is "' + seedOrgCheck.Name + '" (' + seedOrgCheck.OrganizationType
    + ', IsSandbox=false). Nothing was deleted. If you really mean to reseed here, delete the '
    + 'specific rows by hand first.');
// ─────────────────────────────────────────────────────────────────────────────

delete [SELECT Id FROM Transaction__c];

Date dMagnolia = Date.newInstance(2026, 7, 17);
Date dCypress  = Date.newInstance(2026, 8, 4);
Date dBeltway  = Date.newInstance(2026, 5, 2);
Date dMemorial = Date.newInstance(2026, 9, 30);
Date dPasadena = Date.newInstance(2026, 4, 3);

List<Transaction__c> txns = new List<Transaction__c>{
    new Transaction__c(Status__c = 'Active', Property_Name__c = 'Magnolia Crossing',
        Stage__c = 'Due Diligence', Risk__c = 'Watch', Owner_Name__c = 'Danish',
        Contract_Value__c = 31500000, Tasks_Complete__c = 42,
        Target_Close_Date__c = dMagnolia, Contract_Executed_Date__c = dMagnolia.addDays(-70),
        EM_Wired_Date__c = dMagnolia.addDays(-66),
        Earnest_Money__c = 900000, Is_Earnest_At_Risk__c =true, Is_Wire_Approval_Due__c =true,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false),
    new Transaction__c(Status__c = 'Active', Property_Name__c = 'Cypress Grove MF',
        Stage__c = 'Closing Prep', Risk__c = 'High', Owner_Name__c = 'Danish',
        Contract_Value__c = 52200000, Tasks_Complete__c = 61,
        Target_Close_Date__c = dCypress, Contract_Executed_Date__c = dCypress.addDays(-55),
        EM_Wired_Date__c = dCypress.addDays(-51),
        Earnest_Money__c = 1500000, Is_Earnest_At_Risk__c =true, Is_Wire_Approval_Due__c =false,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false),
    new Transaction__c(Status__c = 'Active', Property_Name__c = 'Beltway Plaza',
        Stage__c = 'Closing Prep', Risk__c = 'Low', Owner_Name__c = 'Danish',
        Contract_Value__c = 18900000, Tasks_Complete__c = 71,
        Target_Close_Date__c = dBeltway, Contract_Executed_Date__c = dBeltway.addDays(-60),
        EM_Wired_Date__c = dBeltway.addDays(-56),
        Earnest_Money__c = 500000, Is_Earnest_At_Risk__c =false, Is_Wire_Approval_Due__c =true,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false),
    new Transaction__c(Status__c = 'Active', Property_Name__c = 'Memorial City Office',
        Stage__c = 'Open Contract', Risk__c = 'Low', Owner_Name__c = 'Danish',
        Contract_Value__c = 41700000, Tasks_Complete__c = 8,
        Target_Close_Date__c = dMemorial, Contract_Executed_Date__c = dMemorial.addDays(-75),
        EM_Wired_Date__c = dMemorial.addDays(-71),
        Earnest_Money__c = 600000, Is_Earnest_At_Risk__c =false, Is_Wire_Approval_Due__c =false,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false),
    new Transaction__c(Status__c = 'Active', Property_Name__c = 'Pasadena Industrial',
        Stage__c = 'Closed', Risk__c = 'Closed', Owner_Name__c = 'Danish',
        Contract_Value__c = 14400000, Tasks_Complete__c = 75,
        Target_Close_Date__c = dPasadena, Contract_Executed_Date__c = dPasadena.addDays(-60),
        EM_Wired_Date__c = dPasadena.addDays(-56),
        Earnest_Money__c = 300000, Is_Earnest_At_Risk__c =false, Is_Wire_Approval_Due__c =false,
        Feasibility_Deadline__c = toughDay.addDays(30), Feasibility_Missed__c = false)
};
insert txns;
System.debug('Inserted ' + txns.size() + ' active transactions.');
