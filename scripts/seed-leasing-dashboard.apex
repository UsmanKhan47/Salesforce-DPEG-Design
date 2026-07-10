// Seeds Leasing dashboard demo data. Idempotent: inquiries marked Initial_Notes__c starting 'LEASESEED',
// renewals marked Tenant_Name__c starting 'LSEED-'. Delete-by-marker then re-insert.
// NOTE: Property_Name__c (Lease_Inquiry), Days_In_Stage__c (Lease_Inquiry), Property_Display_Name__c
// (Lease_Renewal) are FORMULA/read-only — never set them. Set the Property_Asset__c lookup (they derive)
// and set Stage_Start_Date__c so Days_In_Stage computes. Requires the 4 PM-seed properties (find-or-create).
// Initial_Notes__c is a Long Text Area — SOQL forbids WHERE-clause filtering on it (any operator),
// so query all rows and filter client-side in Apex instead.
List<Lease_Inquiry__c> oldInq = new List<Lease_Inquiry__c>();
for (Lease_Inquiry__c li : [SELECT Id, Initial_Notes__c FROM Lease_Inquiry__c]) {
    if (li.Initial_Notes__c != null && li.Initial_Notes__c.startsWith('LEASESEED')) oldInq.add(li);
}
Set<Id> oldInqIds = new Map<Id,Lease_Inquiry__c>(oldInq).keySet();
delete [SELECT Id FROM Lease__c WHERE Lease_Inquiry__c IN :oldInqIds];
delete oldInq;
delete [SELECT Id FROM Lease_Renewal__c WHERE Tenant_Name__c LIKE 'LSEED-%'];

Map<String,Id> props = new Map<String,Id>();
for (Property_Asset__c p : [SELECT Id, Name FROM Property_Asset__c
        WHERE Name IN ('Park North Retail','Riverside Commons','Oak Street Center','Sunset Mixed-Use')]) {
    props.put(p.Name, p.Id);
}
for (String nm : new String[]{'Park North Retail','Riverside Commons','Oak Street Center','Sunset Mixed-Use'}) {
    if (!props.containsKey(nm)) { Property_Asset__c p = new Property_Asset__c(Name = nm); insert p; props.put(nm, p.Id); }
}

Date today = Date.today();
List<Lease_Inquiry__c> inq = new List<Lease_Inquiry__c>();

// 5 at LOI Received (LOIs Outstanding = 5)
for (Integer i = 1; i <= 5; i++) {
    inq.add(new Lease_Inquiry__c(Tenant_Name__c='LOI Prospect ' + i, Property_Asset__c=props.get('Park North Retail'),
        Space_Required__c=1500 + i*100, Stage__c='LOI Received', Status__c='Active',
        Inquiry_Date__c=today.addDays(-40), Stage_Start_Date__c=today.addDays(-8 - i), Initial_Notes__c='LEASESEED'));
}
// 10 more active spread across open stages (Prospects in Pipeline); Stage_Start_Date drives Days_In_Stage
String[] openStages = new String[]{'Inquiry Received','LOI Signed','Lease Drafting','Inquiry Received','LOI Signed'};
for (Integer i = 1; i <= 10; i++) {
    inq.add(new Lease_Inquiry__c(Tenant_Name__c='Prospect ' + i, Property_Asset__c=props.get('Riverside Commons'),
        Space_Required__c=800 + i*120, Stage__c=openStages[Math.mod(i, openStages.size())], Status__c='Active',
        Inquiry_Date__c=today.addDays(-30 - i), Stage_Start_Date__c=today.addDays(-i*3), Initial_Notes__c='LEASESEED'));
}
// 3 signed THIS MONTH, inquiry ~47 days before signing (Leases Signed MTD = 3; Avg Days to Lease ~47)
Integer[] gaps = new Integer[]{45, 47, 49};
for (Integer i = 0; i < 3; i++) {
    Date signed = today.addDays(-i*2);           // all within this month (i in 0..2)
    if (signed < today.toStartOfMonth()) signed = today.toStartOfMonth();
    inq.add(new Lease_Inquiry__c(Tenant_Name__c='Signed MTD ' + (i+1), Property_Asset__c=props.get('Oak Street Center'),
        Space_Required__c=2000, Stage__c='Lease Signed', Status__c='Closed Won',
        Inquiry_Date__c=signed.addDays(-gaps[i]), Signed_Date__c=signed, Initial_Notes__c='LEASESEED'));
}
// 4 signed in prior months (velocity chart trend): last month, 2mo, 3mo, 4mo ago
for (Integer m = 1; m <= 4; m++) {
    Date signed = today.addMonths(-m).toStartOfMonth().addDays(9);
    inq.add(new Lease_Inquiry__c(Tenant_Name__c='Signed M-' + m, Property_Asset__c=props.get('Sunset Mixed-Use'),
        Space_Required__c=1800, Stage__c='Lease Signed', Status__c='Closed Won',
        Inquiry_Date__c=signed.addDays(-47), Signed_Date__c=signed, Initial_Notes__c='LEASESEED'));
}
insert inq;
update inq; // re-apply the in-memory Stage_Start_Date__c values (flow only stamps on insert / stage change)

// Renewals: 6 confirmed (Renewed) + 4 active negotiations with a proposed rate
// Lease_End__c is required (not in the original brief draft) — Renewed rows get a post-renewal
// end date ~2yr out; negotiation rows get a near-term end date driving the negotiation urgency.
List<Lease_Renewal__c> ren = new List<Lease_Renewal__c>();
for (Integer i = 1; i <= 6; i++) {
    ren.add(new Lease_Renewal__c(Tenant_Name__c='LSEED-Renewed ' + i, Property_Asset__c=props.get('Park North Retail'),
        Stage__c='Renewed', Status__c='Closed Won', Proposed_Rate__c=25 + i, Lease_End__c=today.addMonths(24)));
}
String[] negStages = new String[]{'Notice Sent','Awaiting Tenant Response','Negotiating','Notice Sent'};
for (Integer i = 0; i < 4; i++) {
    ren.add(new Lease_Renewal__c(Tenant_Name__c='LSEED-Neg ' + (i+1), Property_Asset__c=props.get('Riverside Commons'),
        Stage__c=negStages[i], Status__c='Active', Proposed_Rate__c=28 + i, Lease_End__c=today.addDays(20 + i*10)));
}
insert ren;

// LOI/signed-MTD counts computed from the just-inserted list (Initial_Notes__c isn't filterable in SOQL,
// but every record in `inq` is a LEASESEED row we just built, so this is equivalent).
Integer loiCount = 0, signedMtdCount = 0;
for (Lease_Inquiry__c li : inq) {
    if (li.Stage__c == 'LOI Received') loiCount++;
    if (li.Stage__c == 'Lease Signed' && li.Signed_Date__c != null
        && li.Signed_Date__c.year() == today.year() && li.Signed_Date__c.month() == today.month()) signedMtdCount++;
}
System.debug('Leasing seed: ' + inq.size() + ' inquiries, ' + ren.size() + ' renewals. '
    + loiCount + ' LOIs, ' + signedMtdCount + ' signed MTD, '
    + [SELECT COUNT() FROM Lease_Renewal__c WHERE Stage__c='Renewed' AND Tenant_Name__c LIKE 'LSEED-%'] + ' renewed.');
