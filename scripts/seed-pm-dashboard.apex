// Seeds PM dashboard dummy data (Yardi ETL later). Idempotent by Yardi_*_Id__c prefix + property name.
String P = 'PMSEED';
String pat = P + '-%';

// --- 4 properties + units (count-based occupancy) ---
Map<String,Integer> propUnits = new Map<String,Integer>{
    'Park North Retail'=>24, 'Riverside Commons'=>26, 'Oak Street Center'=>22, 'Sunset Mixed-Use'=>18 };
Map<String,Integer> propVac = new Map<String,Integer>{
    'Park North Retail'=>1, 'Riverside Commons'=>3, 'Oak Street Center'=>2, 'Sunset Mixed-Use'=>4 };
Map<String,Id> propIds = new Map<String,Id>();
for (String nm : propUnits.keySet()) {
    List<Property_Asset__c> ex = [SELECT Id FROM Property_Asset__c WHERE Name = :nm LIMIT 1];
    Property_Asset__c pa = ex.isEmpty() ? new Property_Asset__c(Name = nm) : ex[0];
    if (ex.isEmpty()) insert pa;
    propIds.put(nm, pa.Id);
    delete [SELECT Id FROM Unit__c WHERE Property_Asset__c = :pa.Id AND Yardi_Unit_Id__c LIKE :pat];
}
List<Unit__c> units = new List<Unit__c>();
for (String nm : propUnits.keySet()) {
    Integer total = propUnits.get(nm), vac = propVac.get(nm);
    String pre = nm.left(3).toUpperCase();
    for (Integer i = 1; i <= total; i++) {
        units.add(new Unit__c(
            Property_Asset__c = propIds.get(nm),
            Suite_Number__c = String.valueOf(100 + i),
            Status__c = (i <= vac) ? 'Vacant' : 'Occupied',
            Yardi_Unit_Id__c = P + '-' + pre + '-' + i));
    }
}
insert units;

Id pn = propIds.get('Park North Retail');
Id rc = propIds.get('Riverside Commons');
Id os = propIds.get('Oak Street Center');
Id su = propIds.get('Sunset Mixed-Use');

// --- Delinquency: 5 tenants (1-30 sums 8200 / 31-60 = 5800 / 61-90 = 12400) ---
delete [SELECT Id FROM Delinquency__c WHERE Yardi_AR_Id__c LIKE :pat];
insert new List<Delinquency__c>{
    new Delinquency__c(Property_Asset__c=pn, Tenant_Name__c='Bluebell Bakery', Balance__c=3000, Aging_Bucket__c='1-30 Days', Yardi_AR_Id__c=P+'-AR-1'),
    new Delinquency__c(Property_Asset__c=rc, Tenant_Name__c='FitLife Gym',     Balance__c=2700, Aging_Bucket__c='1-30 Days', Yardi_AR_Id__c=P+'-AR-2'),
    new Delinquency__c(Property_Asset__c=os, Tenant_Name__c='Java Junction',   Balance__c=2500, Aging_Bucket__c='1-30 Days', Yardi_AR_Id__c=P+'-AR-3'),
    new Delinquency__c(Property_Asset__c=pn, Tenant_Name__c='Metro Bank',      Balance__c=5800, Aging_Bucket__c='31-60 Days', Yardi_AR_Id__c=P+'-AR-4'),
    new Delinquency__c(Property_Asset__c=rc, Tenant_Name__c='Cyprus Retail',   Balance__c=12400, Aging_Bucket__c='61-90 Days', Yardi_AR_Id__c=P+'-AR-5')
};

// --- CAM: 4 rows, 3 not-Approved ---
delete [SELECT Id FROM CAM_Reconciliation__c WHERE Yardi_CAM_Id__c LIKE :pat];
insert new List<CAM_Reconciliation__c>{
    new CAM_Reconciliation__c(Property_Asset__c=pn, Reconciliation_Year__c='2024', Status__c='Approved',  Yardi_CAM_Id__c=P+'-CAM-1'),
    new CAM_Reconciliation__c(Property_Asset__c=rc, Reconciliation_Year__c='2024', Status__c='In Review', Yardi_CAM_Id__c=P+'-CAM-2'),
    new CAM_Reconciliation__c(Property_Asset__c=os, Reconciliation_Year__c='2024', Status__c='Pending',   Yardi_CAM_Id__c=P+'-CAM-3'),
    new CAM_Reconciliation__c(Property_Asset__c=su, Reconciliation_Year__c='2024', Status__c='Pending',   Yardi_CAM_Id__c=P+'-CAM-4')
};

// --- Insurance: 4 policies, 2 expiring ≤60d ---
delete [SELECT Id FROM Insurance_Policy__c WHERE Yardi_Policy_Id__c LIKE :pat];
insert new List<Insurance_Policy__c>{
    new Insurance_Policy__c(Policy_Name__c='Maple Portfolio',   Carrier__c='Northwind Mutual', Expiry_Date__c=Date.today().addDays(18),  Yardi_Policy_Id__c=P+'-POL-1'),
    new Insurance_Policy__c(Policy_Name__c='NW Industrial',     Carrier__c='Sentinel P&C',     Expiry_Date__c=Date.today().addDays(44),  Yardi_Policy_Id__c=P+'-POL-2'),
    new Insurance_Policy__c(Policy_Name__c='Park North Retail', Property_Asset__c=pn, Carrier__c='Sentinel P&C', Expiry_Date__c=Date.today().addDays(120), Yardi_Policy_Id__c=P+'-POL-3'),
    new Insurance_Policy__c(Policy_Name__c='Riverside Commons', Property_Asset__c=rc, Carrier__c='Northwind Mutual', Expiry_Date__c=Date.today().addDays(200), Yardi_Policy_Id__c=P+'-POL-4')
};

System.debug('PM seed: '
  + [SELECT COUNT() FROM Delinquency__c WHERE Yardi_AR_Id__c LIKE :pat] + ' delinquency, '
  + [SELECT COUNT() FROM CAM_Reconciliation__c WHERE Yardi_CAM_Id__c LIKE :pat] + ' CAM, '
  + [SELECT COUNT() FROM Insurance_Policy__c WHERE Yardi_Policy_Id__c LIKE :pat] + ' insurance, '
  + units.size() + ' units across ' + propIds.size() + ' properties.');
