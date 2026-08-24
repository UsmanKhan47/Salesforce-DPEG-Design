// Demo/test data for the FSD v1.1 Utility & Meter and AR & Delinquency features (2026-08-22).
// Idempotent by tag: deletes anything it previously created (matched by a 'DEMO-' key prefix)
// before re-inserting, so it is safe to re-run.
//
// Hangs data off 'Cypresswood Retail' (from scripts/seed-rent-roll.apex, run first if its
// Units don't exist yet) plus one other existing Property_Asset__c for the vendor contract.

// ---------- 0. Ensure the rent-roll base data exists (Cypresswood Retail + 3 Units) ----------
List<Property_Asset__c> cw = [SELECT Id, Name FROM Property_Asset__c WHERE Name = 'Cypresswood Retail' LIMIT 1];
if (cw.isEmpty()) {
    throw new System.CalloutException('Run scripts/seed-rent-roll.apex first - Cypresswood Retail not found.');
}
Id propertyId = cw[0].Id;
List<Unit__c> units = [SELECT Id, Suite_Number__c, Tenant_Name__c, Current_Monthly_Rent__c
                        FROM Unit__c WHERE Property_Asset__c = :propertyId ORDER BY Suite_Number__c];
if (units.size() < 3) {
    throw new System.CalloutException('Run scripts/seed-rent-roll.apex first - expected 3 Units on Cypresswood Retail, found ' + units.size());
}
Unit__c uYei = units[0];   // 100 - Premiumrx Pharmacy (order is by Suite_Number__c: 100, 103, 200)
Unit__c uVape = units[1];  // 103 - Vape City
Unit__c uPharmacy = units[2]; // 200 - Yei Dental
System.debug('Units: ' + uYei.Suite_Number__c + '/' + uYei.Tenant_Name__c + ', ' + uVape.Suite_Number__c + '/' + uVape.Tenant_Name__c + ', ' + uPharmacy.Suite_Number__c + '/' + uPharmacy.Tenant_Name__c);

Id secondPropertyId = [SELECT Id FROM Property_Asset__c WHERE Id != :propertyId LIMIT 1].Id;

// ---------- 1. Clean up anything this script created before ----------
delete [SELECT Id FROM Payment_Commitment__c WHERE Case__r.Yardi_AR_Id__c LIKE 'DEMO-%'];
delete [SELECT Id FROM Case WHERE Yardi_AR_Id__c LIKE 'DEMO-%'];
delete [SELECT Id FROM Receivables_Summary__c WHERE Yardi_AR_Id__c LIKE 'DEMO-%'];
delete [SELECT Id FROM Sync_Run__c WHERE Provider_Class_Name__c = 'DemoSeedScript'];
delete [SELECT Id FROM Charge_Line__c WHERE Utility_Bill__r.Meter__r.Utility_Account_Number__c LIKE 'DEMO-%'];
delete [SELECT Id FROM Utility_Bill__c WHERE Meter__r.Utility_Account_Number__c LIKE 'DEMO-%'];
delete [SELECT Id FROM Meter__c WHERE Utility_Account_Number__c LIKE 'DEMO-%'];
delete [SELECT Id FROM Vendor_Contract__c WHERE Provider_Name__c LIKE 'DEMO-%'];

// ================================================================================
// 2. METERS + UTILITY BILLS  (exercises: consumption, rollover, variance formulas)
// ================================================================================

// Meter A - Electricity, whole-building, three months of NORMAL rising consumption.
Meter__c meterElec = new Meter__c(
    Meter_Number__c = 'CW-ELEC-01', Utility_Type__c = 'Electricity', Property_Asset__c = propertyId,
    Utility_Account_Number__c = 'DEMO-ACCT-ELEC-01', Service_Identifier__c = 'ESID-DEMO-ELEC-01',
    Provider_Name__c = 'CenterPoint Energy', Paid_By__c = 'Management',
    Register_Size__c = 6, Service_Status__c = 'Active'
);
insert meterElec;

Utility_Bill__c elecJan = new Utility_Bill__c(
    Meter__c = meterElec.Id, Bill_Date__c = Date.newInstance(2026, 1, 31), Read_Date__c = Date.newInstance(2026, 1, 28),
    Previous_Reading__c = 100000, Current_Reading__c = 104200
);
insert elecJan;
insert new Charge_Line__c(Utility_Bill__c = elecJan.Id, Charge_Type__c = 'Energy', Charge_Amount__c = 612.40);

Utility_Bill__c elecFeb = new Utility_Bill__c(
    Meter__c = meterElec.Id, Bill_Date__c = Date.newInstance(2026, 2, 28), Read_Date__c = Date.newInstance(2026, 2, 25),
    Previous_Reading__c = 104200, Current_Reading__c = 108950
);
insert elecFeb;
insert new Charge_Line__c(Utility_Bill__c = elecFeb.Id, Charge_Type__c = 'Energy', Charge_Amount__c = 701.10);

Utility_Bill__c elecMar = new Utility_Bill__c(
    Meter__c = meterElec.Id, Bill_Date__c = Date.newInstance(2026, 3, 31), Read_Date__c = Date.newInstance(2026, 3, 28),
    Previous_Reading__c = 108950, Current_Reading__c = 113400
);
insert elecMar;
insert new List<Charge_Line__c>{
    new Charge_Line__c(Utility_Bill__c = elecMar.Id, Charge_Type__c = 'Energy', Charge_Amount__c = 640.00),
    new Charge_Line__c(Utility_Bill__c = elecMar.Id, Charge_Type__c = 'Taxes', Charge_Amount__c = 38.50)
};
// Mar total 678.50 vs Feb 701.10 -> a real drop, will show a negative Total_Variance_Amount__c.

// Meter B - Water, register size 5 (wraps at 100000), engineered ROLLOVER on bill 2.
Meter__c meterWater = new Meter__c(
    Meter_Number__c = 'CW-WATER-01', Utility_Type__c = 'Water', Property_Asset__c = propertyId,
    Utility_Account_Number__c = 'DEMO-ACCT-WATER-01', Service_Identifier__c = 'ESID-DEMO-WATER-01',
    Provider_Name__c = 'City of Houston Water', Paid_By__c = 'Tenant', Paid_By_Reason__c = 'Sub-metered directly to tenant',
    Register_Size__c = 5, Service_Status__c = 'Active'
);
insert meterWater;

Utility_Bill__c waterJan = new Utility_Bill__c(
    Meter__c = meterWater.Id, Bill_Date__c = Date.newInstance(2026, 1, 31), Read_Date__c = Date.newInstance(2026, 1, 28),
    Previous_Reading__c = 98500, Current_Reading__c = 99800
);
insert waterJan;
insert new Charge_Line__c(Utility_Bill__c = waterJan.Id, Charge_Type__c = 'Surface Water', Charge_Amount__c = 210.00);

// Rolls past 99999 -> wraps to 400. Chain-continuous (Previous == prior Current), same register.
Utility_Bill__c waterFeb = new Utility_Bill__c(
    Meter__c = meterWater.Id, Bill_Date__c = Date.newInstance(2026, 2, 28), Read_Date__c = Date.newInstance(2026, 2, 25),
    Previous_Reading__c = 99800, Current_Reading__c = 400
);
insert waterFeb;
insert new Charge_Line__c(Utility_Bill__c = waterFeb.Id, Charge_Type__c = 'Surface Water', Charge_Amount__c = 195.00);

// ================================================================================
// 3. VENDOR CONTRACT  (no meter, fixed monthly - trash/landscaping shape)
// ================================================================================
insert new Vendor_Contract__c(
    Property_Asset__c = secondPropertyId, Provider_Name__c = 'DEMO-Republic Services',
    Service_Type__c = 'Trash', Monthly_Amount__c = 480.00,
    Start_Date__c = Date.newInstance(2026, 1, 1), End_Date__c = Date.newInstance(2027, 12, 31)
);

// ================================================================================
// 4. RECEIVABLES SUMMARY + DELINQUENCY CASES
//    Four tenants across the severity spectrum, so the aging buckets, the two
//    rankings (months vs dollars), and the duplicate-Case guard all have something
//    to show.
// ================================================================================

Sync_Run__c run = new Sync_Run__c(
    Started_DateTime__c = System.now().addHours(-1), Finished_DateTime__c = System.now().addMinutes(-55),
    Status__c = 'Completed', Halt_Reason__c = 'None', Row_Count__c = 4, Rows_Upserted__c = 4, Rows_Failed__c = 0,
    Cases_Opened__c = 2, Cases_Escalated__c = 1, Cases_Closed__c = 0, Lifecycle_Ran__c = true,
    Feed_As_Of_DateTime__c = System.now().addMinutes(-58), Source__c = 'Stub', Provider_Class_Name__c = 'DemoSeedScript'
);
insert run;
insert new Sync_Run__c(
    Started_DateTime__c = System.now().addDays(-1).addHours(-1), Finished_DateTime__c = System.now().addDays(-1).addHours(-1).addMinutes(2),
    Status__c = 'Halted', Halt_Reason__c = 'Stale Feed', Halt_Detail__c = 'Feed_As_Of_DateTime older than the configured tolerance; no Cases opened or escalated on this run.',
    Row_Count__c = 4, Rows_Upserted__c = 0, Rows_Failed__c = 0, Lifecycle_Ran__c = false,
    Source__c = 'Stub', Provider_Class_Name__c = 'DemoSeedScript'
);

// 4a. Current, healthy - no case.
insert new Receivables_Summary__c(
    Yardi_AR_Id__c = 'DEMO-AR-001', Unit__c = uYei.Id, Property_Asset__c = propertyId,
    Tenant_Name__c = uYei.Tenant_Name__c, Monthly_Rent__c = uYei.Current_Monthly_Rent__c,
    Current_Amount__c = uYei.Current_Monthly_Rent__c, Total_Outstanding_Amount__c = uYei.Current_Monthly_Rent__c,
    Base_Rent_Outstanding_Amount__c = uYei.Current_Monthly_Rent__c, Days_Past_Due__c = 0,
    Has_Open_Delinquency_Case__c = false, Sync_Run__c = run.Id, Yardi_Last_Synced_DateTime__c = System.now()
);

// 4b. 1-30 days, small balance - below the opening threshold, no case yet.
insert new Receivables_Summary__c(
    Yardi_AR_Id__c = 'DEMO-AR-002', Unit__c = uVape.Id, Property_Asset__c = propertyId,
    Tenant_Name__c = uVape.Tenant_Name__c, Monthly_Rent__c = uVape.Current_Monthly_Rent__c,
    Aging_1_30_Amount__c = 850.00, Total_Outstanding_Amount__c = 850.00,
    Base_Rent_Outstanding_Amount__c = 850.00, Days_Past_Due__c = 12,
    Has_Open_Delinquency_Case__c = false, Sync_Run__c = run.Id, Yardi_Last_Synced_DateTime__c = System.now()
);

// 4c. 61-90 days, mid-severity, open Case at PM Follow-Up, resolution path Collect.
Receivables_Summary__c rs3 = new Receivables_Summary__c(
    Yardi_AR_Id__c = 'DEMO-AR-003', Unit__c = uPharmacy.Id, Property_Asset__c = propertyId,
    Tenant_Name__c = uPharmacy.Tenant_Name__c, Monthly_Rent__c = uPharmacy.Current_Monthly_Rent__c,
    Aging_61_90_Amount__c = 12400.00, NNN_CAM_Outstanding_Amount__c = 900.00,
    Total_Outstanding_Amount__c = 13300.00, Base_Rent_Outstanding_Amount__c = 12400.00,
    Days_Past_Due__c = 74, Has_Open_Delinquency_Case__c = true,
    Sync_Run__c = run.Id, Yardi_Last_Synced_DateTime__c = System.now()
);
insert rs3;
Id delinquencyRT = [SELECT Id FROM RecordType WHERE SObjectType = 'Case' AND DeveloperName = 'Delinquency' LIMIT 1].Id;
insert new Case(
    RecordTypeId = delinquencyRT, Yardi_AR_Id__c = 'DEMO-AR-003', Receivables_Summary__c = rs3.Id,
    Unit__c = uPharmacy.Id, Property_Asset__c = propertyId, Subject = 'Delinquency - ' + uPharmacy.Tenant_Name__c,
    Status = 'PM Follow-Up', Reason = 'Non-payment', Resolution_Path__c = 'Collect',
    Balance_At_Open_Amount__c = 13300.00, Days_Past_Due_At_Open__c = 74,
    Current_Balance_Amount__c = 13300.00, Current_Days_Past_Due__c = 74,
    Last_Follow_Up_DateTime__c = System.now().addDays(-3), Next_Follow_Up_Date__c = Date.today().addDays(4)
);

// 4d. 90+, worst by BOTH views, escalated to principal, resolution path Correct
//     (billed in error by a prior owner) - to show the two rankings can diverge in
//     origin story even when both are severe.
Receivables_Summary__c rs4 = new Receivables_Summary__c(
    Yardi_AR_Id__c = 'DEMO-AR-004', Unit__c = uVape.Id, Property_Asset__c = propertyId,
    Tenant_Name__c = 'Prior Tenant (vacated suite)', Monthly_Rent__c = 2200.00,
    Aging_90_Plus_Amount__c = 22660.00, Other_Outstanding_Amount__c = 22660.00,
    Total_Outstanding_Amount__c = 22660.00, Days_Past_Due__c = 143,
    Has_Open_Delinquency_Case__c = true, Sync_Run__c = run.Id, Yardi_Last_Synced_DateTime__c = System.now()
);
insert rs4;
Case c4 = new Case(
    RecordTypeId = delinquencyRT, Yardi_AR_Id__c = 'DEMO-AR-004', Receivables_Summary__c = rs4.Id,
    Unit__c = uVape.Id, Property_Asset__c = propertyId, Subject = 'Delinquency - Prior Tenant (vacated suite)',
    Status = 'Escalated to Principal', Reason = 'Prior-owner balance', Resolution_Path__c = 'Correct',
    Balance_At_Open_Amount__c = 22660.00, Days_Past_Due_At_Open__c = 90, Escalation_Level__c = 2,
    Escalated_DateTime__c = System.now().addDays(-10), Escalation_Basis_Days__c = 90,
    Current_Balance_Amount__c = 22660.00, Current_Days_Past_Due__c = 143,
    Last_Follow_Up_DateTime__c = System.now().addDays(-15), Next_Follow_Up_Date__c = Date.today().addDays(-1)
);
insert c4;
insert new Payment_Commitment__c(
    Case__c = c4.Id, Commitment_Type__c = 'Promise to Pay', Promised_Amount__c = 5000.00,
    Due_Date__c = Date.today().addDays(-2), Instalment_Number__c = 1,
    Status__c = 'Breached', Breached_Date__c = Date.today().addDays(-2), Breach_Notified__c = false
);

System.debug(LoggingLevel.ERROR, 'SEEDED: 2 Meters (5 bills, 5 charge lines), 1 Vendor Contract, '
    + '4 Receivables Summary rows, 2 Delinquency Cases, 1 Payment Commitment, 2 Sync Runs.');
