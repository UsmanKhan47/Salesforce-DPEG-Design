// Seeds the Lease Activity Tracker demo dataset to match the prototype.
// Idempotent: if any Lease_Inquiry__c already exist, exits immediately.
// Reuses the broker Contacts and Property Assets from the Broker Tracker seed,
// creating any that are missing so this runs standalone too.
if ([SELECT COUNT() FROM Lease_Inquiry__c] > 0) {
    System.debug('lease inquiries already seeded');
    return;
}
Id ME = UserInfo.getUserId();

// ─── Brokers (reuse by email; create if missing) ────────────────────────────
Map<String, Contact> brokerByEmail = new Map<String, Contact>();
brokerByEmail.put('marcus.webb@lee-associates.com', new Contact(LastName='Webb', FirstName='Marcus', Email='marcus.webb@lee-associates.com', Phone='(713) 555-0142', Is_Broker__c=true, Broker_Firm__c='Lee & Associates'));
brokerByEmail.put('priya.nair@cbre.com',            new Contact(LastName='Nair', FirstName='Priya', Email='priya.nair@cbre.com', Phone='(281) 555-0198', Is_Broker__c=true, Broker_Firm__c='CBRE Houston'));
brokerByEmail.put('daniel.reyes@colliers.com',      new Contact(LastName='Reyes', FirstName='Daniel', Email='daniel.reyes@colliers.com', Phone='(832) 555-0173', Is_Broker__c=true, Broker_Firm__c='Colliers'));
brokerByEmail.put('sandra.koch@naipartners.com',    new Contact(LastName='Koch', FirstName='Sandra', Email='sandra.koch@naipartners.com', Phone='(713) 555-0226', Is_Broker__c=true, Broker_Firm__c='NAI Partners'));
Set<String> haveEmails = new Set<String>();
for (Contact c : [SELECT Email FROM Contact WHERE Email IN :brokerByEmail.keySet()]) haveEmails.add(c.Email);
List<Contact> newBrokers = new List<Contact>();
for (String e : brokerByEmail.keySet()) if (!haveEmails.contains(e)) newBrokers.add(brokerByEmail.get(e));
if (!newBrokers.isEmpty()) insert newBrokers;
Map<String, Id> bId = new Map<String, Id>();
for (Contact c : [SELECT Id, Email FROM Contact WHERE Email IN :brokerByEmail.keySet()]) bId.put(c.Email, c.Id);
Id b1 = bId.get('marcus.webb@lee-associates.com');
Id b2 = bId.get('priya.nair@cbre.com');
Id b3 = bId.get('daniel.reyes@colliers.com');
Id b4 = bId.get('sandra.koch@naipartners.com');

// ─── Property Assets (reuse by name; create property + asset if missing) ─────
Map<String, String> assetToProp = new Map<String, String>{
    'Westgate Plaza Asset'      => 'Westgate Plaza|8420 Westheimer Rd|Houston|Retail|42000',
    'Sterling Crossing Asset'   => 'Sterling Crossing|1205 N Shepherd Dr|Houston|Retail|28500',
    'Magnolia Commons Asset'    => 'Magnolia Commons|3340 FM 1960|Spring|Retail|65200',
    'Bayou Bend Center Asset'   => 'Bayou Bend Center|770 Studemont St|Houston|Mixed-Use|19800',
    'Katy Mills Strip Asset'    => 'Katy Mills Strip|5000 Katy Fwy|Katy|Retail|51400',
    'Heights Marketplace Asset' => 'Heights Marketplace|1820 W 18th St|Houston|Retail|33750'
};
Map<String, Id> assetIdByName = new Map<String, Id>();
for (Property_Asset__c a : [SELECT Id, Name FROM Property_Asset__c WHERE Name IN :assetToProp.keySet()]) assetIdByName.put(a.Name, a.Id);
List<Property__c> newProps = new List<Property__c>();
Map<String, String> propNameToAsset = new Map<String, String>();
for (String an : assetToProp.keySet()) {
    if (!assetIdByName.containsKey(an)) {
        List<String> p = assetToProp.get(an).split('\\|');
        newProps.add(new Property__c(Name=p[0], Address__c=p[1], City__c=p[2], State__c='TX', Asset_Type__c=p[3], Square_Footage__c=Decimal.valueOf(p[4])));
        propNameToAsset.put(p[0], an);
    }
}
if (!newProps.isEmpty()) {
    insert newProps;
    List<Property_Asset__c> newAssets = new List<Property_Asset__c>();
    for (Property__c pr : newProps) {
        newAssets.add(new Property_Asset__c(Name=propNameToAsset.get(pr.Name), Property__c=pr.Id, Property_Type__c='Retail', Status__c='Active', Vacant_Area__c=8000));
    }
    insert newAssets;
    for (Property_Asset__c a : newAssets) assetIdByName.put(a.Name, a.Id);
}
Id pa1 = assetIdByName.get('Westgate Plaza Asset');
Id pa2 = assetIdByName.get('Sterling Crossing Asset');
Id pa3 = assetIdByName.get('Magnolia Commons Asset');
Id pa4 = assetIdByName.get('Bayou Bend Center Asset');
Id pa5 = assetIdByName.get('Katy Mills Strip Asset');
Id pa6 = assetIdByName.get('Heights Marketplace Asset');

// ─── Lease Inquiries (7) ─────────────────────────────────────────────────────
Lease_Inquiry__c i1 = new Lease_Inquiry__c(Tenant_Name__c='Sunrise Cafe', Broker__c=b1, Property_Asset__c=pa1, Space_Required__c=1800, Stage__c='LOI Negotiation', Ball_In_Court__c='Landlord', Handling_Person__c=ME, Status__c='Active', LOI_Date__c=Date.newInstance(2026,6,8));
Lease_Inquiry__c i2 = new Lease_Inquiry__c(Tenant_Name__c='FitZone Gym', Broker__c=b2, Property_Asset__c=pa3, Space_Required__c=6500, Stage__c='Inquiry Received', Ball_In_Court__c='Broker', Handling_Person__c=ME, Status__c='Active');
Lease_Inquiry__c i3 = new Lease_Inquiry__c(Tenant_Name__c='Metro Bank', Broker__c=b3, Property_Asset__c=pa2, Space_Required__c=3200, Stage__c='LOI Signed', Ball_In_Court__c='Legal', Handling_Person__c=ME, Status__c='Active', LOI_Date__c=Date.newInstance(2026,5,20), Base_Rent__c='$34.00 / sq ft NNN', Lease_Term__c='7 years', Free_Rent__c='4 months', TI_Allowance__c='$45.00 / sq ft', Commencement_Date__c=Date.newInstance(2026,9,1));
Lease_Inquiry__c i4 = new Lease_Inquiry__c(Tenant_Name__c='QuickMart', Broker__c=b4, Property_Asset__c=pa5, Space_Required__c=2400, Stage__c='Lease Drafting', Ball_In_Court__c='Tenant', Handling_Person__c=ME, Status__c='Active', LOI_Date__c=Date.newInstance(2026,5,10), Base_Rent__c='$26.00 / sq ft NNN', Lease_Term__c='5 years', Free_Rent__c='2 months', TI_Allowance__c='$30.00 / sq ft', Commencement_Date__c=Date.newInstance(2026,8,15));
Lease_Inquiry__c i5 = new Lease_Inquiry__c(Tenant_Name__c='The Nail Bar', Broker__c=b1, Property_Asset__c=pa6, Space_Required__c=1200, Stage__c='LOI Received', Ball_In_Court__c='Landlord', Handling_Person__c=ME, Status__c='Active', LOI_Date__c=Date.newInstance(2026,6,20));
Lease_Inquiry__c i6 = new Lease_Inquiry__c(Tenant_Name__c='Bella Boutique', Broker__c=b2, Property_Asset__c=pa4, Space_Required__c=1500, Stage__c='Lease Signed', Ball_In_Court__c='Tenant', Handling_Person__c=ME, Status__c='Closed Won', LOI_Date__c=Date.newInstance(2026,1,15), Base_Rent__c='$30.00 / sq ft NNN', Lease_Term__c='5 years', Free_Rent__c='3 months', TI_Allowance__c='$35.00 / sq ft', Commencement_Date__c=Date.newInstance(2026,3,1));
Lease_Inquiry__c i7 = new Lease_Inquiry__c(Tenant_Name__c='Corner Coffee Co.', Broker__c=b3, Property_Asset__c=pa1, Space_Required__c=1900, Stage__c='Lease Signed', Ball_In_Court__c='Tenant', Handling_Person__c=ME, Status__c='Closed Won', LOI_Date__c=Date.newInstance(2025,12,20), Base_Rent__c='$29.00 / sq ft NNN', Lease_Term__c='5 years', Free_Rent__c='2 months', TI_Allowance__c='$28.00 / sq ft', Commencement_Date__c=Date.newInstance(2026,2,1));
List<Lease_Inquiry__c> inqs = new List<Lease_Inquiry__c>{ i1, i2, i3, i4, i5, i6, i7 };
insert inqs;

// The Open Log flow created one opener per inquiry — clear them, we insert the full histories below.
Set<Id> inqIds = new Map<Id, Lease_Inquiry__c>(inqs).keySet();
delete [SELECT Id FROM Lease_Activity__c WHERE Lease_Inquiry__c IN :inqIds];

// Backdate the days-in-stage timer (Stage unchanged → Stage Timer flow is a no-op).
i1.Stage_Start_Date__c = Date.newInstance(2026,6,15); // 16d → Overdue
i2.Stage_Start_Date__c = Date.newInstance(2026,6,28); // 3d  → On track
i3.Stage_Start_Date__c = Date.newInstance(2026,6,22); // 9d  → Aging
i4.Stage_Start_Date__c = Date.newInstance(2026,6,26); // 5d  → On track
i5.Stage_Start_Date__c = Date.newInstance(2026,6,20); // 11d → Aging
i6.Stage_Start_Date__c = Date.newInstance(2026,3,1);
i7.Stage_Start_Date__c = Date.newInstance(2026,2,1);
update inqs;

// ─── Negotiation history ─────────────────────────────────────────────────────
Datetime dt(Integer y, Integer mo, Integer d, Integer h, Integer mi) { return Datetime.newInstance(y, mo, d, h, mi, 0); }
List<Lease_Activity__c> log = new List<Lease_Activity__c>();
void entry(Id inq, Datetime at, String ball, String txt) {
    // Entry_DateTime__c is the ARCHITECTURE.md §1 rule-9 stamp read by the timeline.
    log.add(new Lease_Activity__c(Lease_Inquiry__c=inq, Entry_DateTime__c=at, Ball_In_Court__c=ball, Logged_By__c=ME, Details__c=txt));
}
entry(i1.Id, dt(2026,6,3,9,12),  'Landlord', 'Marcus Webb (Lee & Associates) introduced Sunrise Cafe. Toured the 1,800 sq ft end-cap at Westgate Plaza — patio frontage, wants a full-service cafe.');
entry(i1.Id, dt(2026,6,8,15,40), 'Landlord', 'LOI received: $28.00/sq ft NNN, 5-year term, 3 months free rent, $40/sq ft TI. Forwarded to the landlord for response.');
entry(i1.Id, dt(2026,6,12,11,5), 'Tenant',   'Landlord countered: $32.00/sq ft NNN, 2 months free, $25/sq ft TI, 3% annual escalations. Sent back through the broker.');
entry(i1.Id, dt(2026,6,15,16,22),'Landlord', 'Tenant counter via broker: $30.00/sq ft, 2.5 months free, $30/sq ft TI — holding firm on TI for the kitchen build-out.');
entry(i1.Id, dt(2026,6,24,10,15),'Landlord', 'Nudged the landlord — broker following up daily. Deal is stalling; still awaiting the decision on the $30/sq ft counter.');

entry(i2.Id, dt(2026,6,28,13,30),'Broker',   'Priya Nair (CBRE) brought FitZone Gym looking for ~6,500 sq ft at Magnolia Commons. Requested tenant financials and concept deck before we respond.');

entry(i3.Id, dt(2026,5,15,10,0), 'Landlord', 'Daniel Reyes (Colliers) introduced Metro Bank for a 3,200 sq ft branch at Sterling Crossing corner pad.');
entry(i3.Id, dt(2026,5,20,14,15),'Landlord', 'LOI received: $32/sq ft, 7-year term. Sent to the landlord.');
entry(i3.Id, dt(2026,6,10,16,0), 'Tenant',   'Countered to $34/sq ft with 4 months free and $45/sq ft TI given the vault build-out. Approved.');
entry(i3.Id, dt(2026,6,22,9,45), 'Legal',    'Both sides signed the LOI at $34/sq ft NNN, 7-year term, commencement Sep 1. Terms locked — handed to legal for the lease draft.');

entry(i4.Id, dt(2026,5,5,11,20), 'Landlord', 'Sandra Koch (NAI) brought QuickMart for a 2,400 sq ft convenience unit at Katy Mills Strip.');
entry(i4.Id, dt(2026,5,10,15,0), 'Landlord', 'LOI received and negotiated over two rounds. Landlord approved final terms.');
entry(i4.Id, dt(2026,6,4,10,30), 'Legal',    'LOI signed at $26/sq ft NNN, 5-year term. Legal began drafting the lease.');
entry(i4.Id, dt(2026,6,26,14,40),'Tenant',   'First lease draft with redlines sent to tenant counsel. Awaiting their markup on the CAM cap and signage exhibit.');

entry(i5.Id, dt(2026,6,14,9,0),  'Broker',   'Marcus Webb introduced The Nail Bar for a 1,200 sq ft inline suite at Heights Marketplace.');
entry(i5.Id, dt(2026,6,20,13,10),'Landlord', 'LOI received: $27/sq ft NNN, 3-year term, 1 month free, $15/sq ft TI. Forwarded to the landlord for first response.');

entry(i6.Id, dt(2026,1,10,10,0), 'Landlord', 'Bella Boutique inquiry for 1,500 sq ft at Bayou Bend Center.');
entry(i6.Id, dt(2026,2,14,15,30),'Legal',    'LOI signed after two counter rounds. Handed to legal.');
entry(i6.Id, dt(2026,2,28,17,0), 'Tenant',   'Lease fully executed. Closed won — handed to the PM team for Yardi setup.');

entry(i7.Id, dt(2025,12,15,9,30),'Landlord', 'Corner Coffee Co. inquiry for 1,900 sq ft at Westgate Plaza.');
entry(i7.Id, dt(2026,1,20,14,0), 'Legal',    'LOI signed. Lease drafting begun.');
entry(i7.Id, dt(2026,1,31,16,45),'Tenant',   'Lease executed. Closed won.');
insert log;

System.debug('Seeded ' + inqs.size() + ' lease inquiries and ' + log.size() + ' negotiation log entries.');
