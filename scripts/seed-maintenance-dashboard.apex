// Seeds Maintenance dashboard demo data. Idempotent: work orders marked Subject__c starting 'WOSEED-'.
// Required fields: Subject__c, Reported_Date__c. Vendor__c is text; Property_Asset__c optional (Property_Display_Name is a formula).
delete [SELECT Id FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%'];

Datetime now = Datetime.now();
String[] vendors = new String[]{'AirPro HVAC','TopShield Roofing','ProPlumb','Elec Solutions'};
String[] cats = new String[]{'HVAC','Plumbing','Electrical','Refrigeration','General'};
List<Work_Order__c> wos = new List<Work_Order__c>();

// ---- OPEN work orders (~37): staggered ages drive aging buckets + escalation ----
// 6 escalated (>15d old, Critical/High) — reported 16-26 days ago
for (Integer i = 0; i < 6; i++) {
    wos.add(new Work_Order__c(Subject__c='WOSEED- Escalated ' + i,
        Reported_Date__c=now.addDays(-(16 + i*2)), Priority__c=(Math.mod(i,2)==0?'Critical':'High'),
        Status__c=(Math.mod(i,2)==0?'In Progress':'New'), Category__c=cats[Math.mod(i,cats.size())],
        Vendor__c=vendors[Math.mod(i,vendors.size())]));
}
// 20 In Progress (Vendor Dispatched), varied recent ages for aging spread
for (Integer i = 0; i < 20; i++) {
    Integer ageDays = new Integer[]{1,2,3,5,6,9,11,13}[Math.mod(i,8)];
    wos.add(new Work_Order__c(Subject__c='WOSEED- InProg ' + i,
        Reported_Date__c=now.addDays(-ageDays), Priority__c=new String[]{'Medium','High','Low','Medium'}[Math.mod(i,4)],
        Status__c='In Progress', Category__c=cats[Math.mod(i,cats.size())], Vendor__c=vendors[Math.mod(i,vendors.size())]));
}
// 8 On Hold
for (Integer i = 0; i < 8; i++) {
    wos.add(new Work_Order__c(Subject__c='WOSEED- OnHold ' + i,
        Reported_Date__c=now.addDays(-(4 + i)), Priority__c=new String[]{'Low','Medium'}[Math.mod(i,2)],
        Status__c='On Hold', Category__c=cats[Math.mod(i,cats.size())], Vendor__c=vendors[Math.mod(i,vendors.size())]));
}
// 3 New (to round open toward ~37)
for (Integer i = 0; i < 3; i++) {
    wos.add(new Work_Order__c(Subject__c='WOSEED- New ' + i,
        Reported_Date__c=now.addDays(-i), Priority__c='Medium', Status__c='New',
        Category__c=cats[Math.mod(i,cats.size())], Vendor__c=vendors[Math.mod(i,vendors.size())]));
}

// ---- RESOLVED this month (~40): Completed_Date this month, Reported a few days earlier -> Resolution_Days ----
// Per-vendor average resolution days differ: AirPro 3.2, TopShield 5.8, ProPlumb 8.1, Elec 12.0 (approx)
Decimal[] vAvg = new Decimal[]{3, 6, 8, 12};
Date monthStart = Date.today().toStartOfMonth();
for (Integer i = 0; i < 40; i++) {
    Integer v = Math.mod(i, 4);
    Integer resDays = (Integer)vAvg[v] + Math.mod(i, 3) - 1;   // small spread around the vendor average
    if (resDays < 1) resDays = 1;
    // completed on a day within this month (day 1..min(today, 28))
    Integer maxDay = Math.min(Date.today().day(), 28);
    Datetime completed = Datetime.newInstance(monthStart.addDays(Math.mod(i, maxDay)), Time.newInstance(12,0,0,0));
    wos.add(new Work_Order__c(Subject__c='WOSEED- Resolved ' + i,
        Reported_Date__c=completed.addDays(-resDays), Completed_Date__c=completed,
        Priority__c=new String[]{'Medium','High','Low'}[Math.mod(i,3)],
        Status__c=(Math.mod(i,4)==0?'Closed':'Completed'), Category__c=cats[Math.mod(i,cats.size())],
        Vendor__c=vendors[v]));
}

// Assign a property round-robin so the Active Work Orders table's Property column populates
// (Property_Display_Name__c is a formula off Property_Asset__c). Uses the 4 PM-seed properties if present.
List<Id> propIds = new List<Id>();
for (Property_Asset__c p : [SELECT Id FROM Property_Asset__c
        WHERE Name IN ('Park North Retail','Riverside Commons','Oak Street Center','Sunset Mixed-Use') ORDER BY Name]) {
    propIds.add(p.Id);
}
if (!propIds.isEmpty()) {
    for (Integer i = 0; i < wos.size(); i++) wos[i].Property_Asset__c = propIds[Math.mod(i, propIds.size())];
}
insert wos;

System.debug('Maintenance seed: ' + wos.size() + ' work orders. '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Is_Open__c=true] + ' open, '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Status__c='In Progress'] + ' in progress, '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Status__c='On Hold'] + ' on hold, '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Completed_Date__c = THIS_MONTH] + ' resolved MTD, '
    + [SELECT COUNT() FROM Work_Order__c WHERE Subject__c LIKE 'WOSEED-%' AND Is_Escalation__c=true] + ' escalated.');
