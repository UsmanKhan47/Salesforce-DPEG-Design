// Seeds the Cypresswood Retail rent roll with the design's dummy data (future: Yardi sync).
// Idempotent: deletes the asset's existing units (steps cascade via master-detail), re-inserts.
Property_Asset__c pa;
List<Property_Asset__c> existing = [SELECT Id FROM Property_Asset__c WHERE Name = 'Cypresswood Retail' LIMIT 1];
if (existing.isEmpty()) {
    pa = new Property_Asset__c(Name = 'Cypresswood Retail');
    insert pa;
} else {
    pa = existing[0];
}
delete [SELECT Id FROM Unit__c WHERE Property_Asset__c = :pa.Id];

Unit__c u200 = new Unit__c(Property_Asset__c = pa.Id, Yardi_Unit_Id__c = 'Y-CW-200',
    Suite_Number__c = '200', Tenant_Name__c = 'Yei Dental', Square_Feet__c = 2600,
    Status__c = 'Occupied', Lease_Start__c = Date.newInstance(2020, 12, 18),
    Lease_End__c = Date.newInstance(2030, 12, 31), Current_Monthly_Rent__c = 6196.67,
    Current_Rent_PSF__c = 28.60, NNN_Property_Tax__c = 704.15, NNN_Insurance__c = 270.83,
    NNN_CAM__c = 325.00, NNN_Monthly_Total__c = 1299.98, NNN_PSF__c = 6.00);
Unit__c u103 = new Unit__c(Property_Asset__c = pa.Id, Yardi_Unit_Id__c = 'Y-CW-103',
    Suite_Number__c = '103', Tenant_Name__c = 'Vape City', Square_Feet__c = 990,
    Status__c = 'Occupied', Lease_Start__c = Date.newInstance(2026, 1, 1),
    Lease_End__c = Date.newInstance(2031, 1, 1), Current_Monthly_Rent__c = 2640.00,
    Current_Rent_PSF__c = 32.00, NNN_Property_Tax__c = 170.00, NNN_Insurance__c = 140.00,
    NNN_CAM__c = 350.00, NNN_Monthly_Total__c = 660.00, NNN_PSF__c = 8.00);
Unit__c u100 = new Unit__c(Property_Asset__c = pa.Id, Yardi_Unit_Id__c = 'Y-CW-100',
    Suite_Number__c = '100', Tenant_Name__c = 'Premiumrx Pharmacy', Square_Feet__c = 1200,
    Status__c = 'Occupied', Lease_Start__c = Date.newInstance(2023, 3, 6),
    Lease_End__c = Date.newInstance(2028, 9, 30), Current_Monthly_Rent__c = 2400.00,
    Current_Rent_PSF__c = 24.00, NNN_Property_Tax__c = 300.00, NNN_Insurance__c = 50.00,
    NNN_CAM__c = 350.00, NNN_Monthly_Total__c = 700.00, NNN_PSF__c = 7.00);
Unit__c u101 = new Unit__c(Property_Asset__c = pa.Id, Yardi_Unit_Id__c = 'Y-CW-101',
    Suite_Number__c = '101', Tenant_Name__c = 'Cell Phone Store', Square_Feet__c = 750,
    Status__c = 'Occupied', Lease_Start__c = Date.newInstance(2026, 1, 1),
    Lease_End__c = Date.newInstance(2028, 12, 31), Current_Monthly_Rent__c = 1312.50,
    Current_Rent_PSF__c = 21.00, NNN_Property_Tax__c = 250.00, NNN_Insurance__c = 40.00,
    NNN_CAM__c = 210.00, NNN_Monthly_Total__c = 500.00, NNN_PSF__c = 8.00);
Unit__c u210 = new Unit__c(Property_Asset__c = pa.Id, Yardi_Unit_Id__c = 'Y-CW-210',
    Suite_Number__c = '210', Square_Feet__c = 1235, Status__c = 'Vacant');
Unit__c uPad = new Unit__c(Property_Asset__c = pa.Id, Yardi_Unit_Id__c = 'Y-CW-PAD',
    Square_Feet__c = 2241, Status__c = 'Vacant',
    Asking_Rent_PSF__c = 27.00, Estimated_NNN_PSF__c = 7.25);
insert new List<Unit__c>{ u200, u103, u100, u101, u210, uPad };

List<Rent_Step__c> steps = new List<Rent_Step__c>{
    // Suite 200 — Yei Dental
    new Rent_Step__c(Unit__c = u200.Id, Sort_Order__c = 1, Period_Start__c = Date.newInstance(2023, 1, 1),
        Period_End__c = Date.newInstance(2025, 12, 31), Monthly_Rent__c = 5633.33, Rent_PSF__c = 26.00, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u200.Id, Sort_Order__c = 2, Period_Start__c = Date.newInstance(2026, 1, 1),
        Period_End__c = Date.newInstance(2030, 12, 31), Monthly_Rent__c = 6196.67, Rent_PSF__c = 28.60, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u200.Id, Sort_Order__c = 3, Period_Start__c = Date.newInstance(2031, 1, 1),
        Period_End__c = Date.newInstance(2035, 12, 31), Monthly_Rent__c = 6816.33, Rent_PSF__c = 31.46, Type__c = 'Renewal Option'),
    new Rent_Step__c(Unit__c = u200.Id, Sort_Order__c = 4, Period_Start__c = Date.newInstance(2036, 1, 1),
        Period_End__c = Date.newInstance(2040, 12, 31), Monthly_Rent__c = 7498.83, Rent_PSF__c = 34.61, Type__c = 'Renewal Option'),
    // Suite 103 — Vape City
    new Rent_Step__c(Unit__c = u103.Id, Sort_Order__c = 1, Period_Start__c = Date.newInstance(2026, 1, 1),
        Period_End__c = Date.newInstance(2026, 12, 31), Monthly_Rent__c = 2640.00, Rent_PSF__c = 32.00, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u103.Id, Sort_Order__c = 2, Period_Start__c = Date.newInstance(2027, 1, 1),
        Period_End__c = Date.newInstance(2027, 12, 31), Monthly_Rent__c = 2719.20, Rent_PSF__c = 32.96, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u103.Id, Sort_Order__c = 3, Period_Start__c = Date.newInstance(2028, 1, 1),
        Period_End__c = Date.newInstance(2028, 12, 31), Monthly_Rent__c = 2800.88, Rent_PSF__c = 33.95, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u103.Id, Sort_Order__c = 4, Period_Start__c = Date.newInstance(2029, 1, 1),
        Period_End__c = Date.newInstance(2029, 12, 31), Monthly_Rent__c = 2885.03, Rent_PSF__c = 34.97, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u103.Id, Sort_Order__c = 5, Period_Start__c = Date.newInstance(2030, 1, 1),
        Period_End__c = Date.newInstance(2030, 12, 31), Monthly_Rent__c = 2971.65, Rent_PSF__c = 36.02, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u103.Id, Sort_Order__c = 6, Period_Start__c = Date.newInstance(2031, 1, 1),
        Period_End__c = Date.newInstance(2035, 12, 31), Type__c = 'Renewal Option', Note__c = '3% annual bumps'),
    new Rent_Step__c(Unit__c = u103.Id, Sort_Order__c = 7, Period_Start__c = Date.newInstance(2036, 1, 1),
        Period_End__c = Date.newInstance(2040, 12, 31), Type__c = 'Renewal Option', Note__c = '3% annual bumps'),
    // Suite 100 — Premiumrx Pharmacy
    new Rent_Step__c(Unit__c = u100.Id, Sort_Order__c = 1, Period_Start__c = Date.newInstance(2023, 12, 1),
        Period_End__c = Date.newInstance(2024, 10, 31), Monthly_Rent__c = 2200.00, Rent_PSF__c = 22.00, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u100.Id, Sort_Order__c = 2, Period_Start__c = Date.newInstance(2024, 11, 1),
        Period_End__c = Date.newInstance(2025, 10, 31), Monthly_Rent__c = 2300.00, Rent_PSF__c = 23.00, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u100.Id, Sort_Order__c = 3, Period_Start__c = Date.newInstance(2025, 11, 1),
        Period_End__c = Date.newInstance(2028, 10, 31), Monthly_Rent__c = 2400.00, Rent_PSF__c = 24.00, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u100.Id, Sort_Order__c = 4, Period_Label__c = 'Years 6–10',
        Monthly_Rent__c = 2700.00, Rent_PSF__c = 27.00, Type__c = 'Renewal Option'),
    new Rent_Step__c(Unit__c = u100.Id, Sort_Order__c = 5, Period_Label__c = 'Years 11–15',
        Monthly_Rent__c = 3000.00, Rent_PSF__c = 30.00, Type__c = 'Renewal Option'),
    // Suite 101 — Cell Phone Store
    new Rent_Step__c(Unit__c = u101.Id, Sort_Order__c = 1, Period_Start__c = Date.newInstance(2026, 1, 1),
        Period_End__c = Date.newInstance(2026, 12, 31), Monthly_Rent__c = 1312.50, Rent_PSF__c = 21.00, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u101.Id, Sort_Order__c = 2, Period_Start__c = Date.newInstance(2027, 1, 1),
        Period_End__c = Date.newInstance(2027, 12, 31), Monthly_Rent__c = 1338.75, Rent_PSF__c = 21.42, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u101.Id, Sort_Order__c = 3, Period_Start__c = Date.newInstance(2028, 1, 1),
        Period_End__c = Date.newInstance(2028, 12, 31), Monthly_Rent__c = 1365.53, Rent_PSF__c = 21.82, Type__c = 'Current Term'),
    new Rent_Step__c(Unit__c = u101.Id, Sort_Order__c = 4, Period_Label__c = 'Not yet defined',
        Type__c = 'Renewal Option', Note__c = '2 five-year options at Fair Market Rent')
};
insert steps;
System.debug('Seeded ' + [SELECT COUNT() FROM Unit__c WHERE Property_Asset__c = :pa.Id] + ' units, '
    + steps.size() + ' rent steps for ' + pa.Id);
