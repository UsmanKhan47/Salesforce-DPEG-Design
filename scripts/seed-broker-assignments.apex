// Seeds the Broker Assignments demo dataset to match the prototype.
// Idempotent: if any Broker_Assignment__c records already exist, exits immediately.
Date TODAY_ANCHOR = Date.newInstance(2026, 6, 30);

if ([SELECT COUNT() FROM Broker_Assignment__c] > 0) {
    System.debug('already seeded');
    return;
}

// ─── 1) Brokers as Contacts ─────────────────────────────────────────────────
// Query existing by email to avoid duplicates; insert only missing ones.
List<String> brokerEmails = new List<String>{
    'marcus.webb@lee-associates.com',
    'priya.nair@cbre.com',
    'daniel.reyes@colliers.com',
    'sandra.koch@naipartners.com'
};

Map<String, Contact> existingByEmail = new Map<String, Contact>();
for (Contact c : [SELECT Id, Email FROM Contact WHERE Email IN :brokerEmails]) {
    existingByEmail.put(c.Email, c);
}

List<Contact> toInsert = new List<Contact>();
Map<String, Contact> brokerSeed = new Map<String, Contact>();
brokerSeed.put('marcus.webb@lee-associates.com',  new Contact(LastName='Webb',  FirstName='Marcus',  Email='marcus.webb@lee-associates.com',  Phone='(713) 555-0142', Is_Broker__c=true, Broker_Firm__c='Lee & Associates', Broker_Status__c='Active'));
brokerSeed.put('priya.nair@cbre.com',             new Contact(LastName='Nair',  FirstName='Priya',   Email='priya.nair@cbre.com',             Phone='(281) 555-0198', Is_Broker__c=true, Broker_Firm__c='CBRE Houston',      Broker_Status__c='Active'));
brokerSeed.put('daniel.reyes@colliers.com',       new Contact(LastName='Reyes', FirstName='Daniel',  Email='daniel.reyes@colliers.com',       Phone='(832) 555-0173', Is_Broker__c=true, Broker_Firm__c='Colliers',          Broker_Status__c='Active'));
brokerSeed.put('sandra.koch@naipartners.com',     new Contact(LastName='Koch',  FirstName='Sandra',  Email='sandra.koch@naipartners.com',     Phone='(713) 555-0226', Is_Broker__c=true, Broker_Firm__c='NAI Partners',      Broker_Status__c='Active'));

for (String email : brokerSeed.keySet()) {
    if (!existingByEmail.containsKey(email)) {
        toInsert.add(brokerSeed.get(email));
    }
}
if (!toInsert.isEmpty()) {
    insert toInsert;
}

// Rebuild full email→id map after any inserts
Map<String, Id> brokerIdByEmail = new Map<String, Id>();
for (Contact c : [SELECT Id, Email FROM Contact WHERE Email IN :brokerEmails]) {
    brokerIdByEmail.put(c.Email, c.Id);
}

Id b1 = brokerIdByEmail.get('marcus.webb@lee-associates.com');
Id b2 = brokerIdByEmail.get('priya.nair@cbre.com');
Id b3 = brokerIdByEmail.get('daniel.reyes@colliers.com');
Id b4 = brokerIdByEmail.get('sandra.koch@naipartners.com');

// ─── 2) Properties (Property__c) ────────────────────────────────────────────
// p1 Westgate Plaza      – Retail,    42000 sqft
// p2 Sterling Crossing   – Retail,    28500 sqft
// p3 Magnolia Commons    – Retail,    65200 sqft
// p4 Bayou Bend Center   – Mixed-Use, 19800 sqft
// p5 Katy Mills Strip    – Retail,    51400 sqft
// p6 Heights Marketplace – Retail,    33750 sqft

List<Property__c> properties = new List<Property__c>{
    new Property__c(Name='Westgate Plaza',      Address__c='8420 Westheimer Rd', City__c='Houston', State__c='TX', Square_Footage__c=42000, Asset_Type__c='Retail'),
    new Property__c(Name='Sterling Crossing',   Address__c='1205 N Shepherd Dr', City__c='Houston', State__c='TX', Square_Footage__c=28500, Asset_Type__c='Retail'),
    new Property__c(Name='Magnolia Commons',    Address__c='3340 FM 1960',       City__c='Spring',  State__c='TX', Square_Footage__c=65200, Asset_Type__c='Retail'),
    new Property__c(Name='Bayou Bend Center',   Address__c='770 Studemont St',   City__c='Houston', State__c='TX', Square_Footage__c=19800, Asset_Type__c='Mixed-Use'),
    new Property__c(Name='Katy Mills Strip',    Address__c='5000 Katy Fwy',      City__c='Katy',    State__c='TX', Square_Footage__c=51400, Asset_Type__c='Retail'),
    new Property__c(Name='Heights Marketplace', Address__c='1820 W 18th St',     City__c='Houston', State__c='TX', Square_Footage__c=33750, Asset_Type__c='Retail')
};
insert properties;

// ─── 3) Property Assets (Property_Asset__c) ─────────────────────────────────
// Vacant_Area__c ≈ 25–35% of Square_Footage__c (rounded).
// p1 42000 → vacant 11000
// p2 28500 → vacant 7500
// p3 65200 → vacant 18000
// p4 19800 → vacant 5500
// p5 51400 → vacant 14000
// p6 33750 → vacant 9000

List<Property_Asset__c> assets = new List<Property_Asset__c>{
    new Property_Asset__c(Name='Westgate Plaza Asset',      Property__c=properties[0].Id, Property_Type__c='Retail',    Status__c='Active', Vacant_Area__c=11000),
    new Property_Asset__c(Name='Sterling Crossing Asset',   Property__c=properties[1].Id, Property_Type__c='Retail',    Status__c='Active', Vacant_Area__c=7500),
    new Property_Asset__c(Name='Magnolia Commons Asset',    Property__c=properties[2].Id, Property_Type__c='Retail',    Status__c='Active', Vacant_Area__c=18000),
    new Property_Asset__c(Name='Bayou Bend Center Asset',   Property__c=properties[3].Id, Property_Type__c='Mixed-Use', Status__c='Active', Vacant_Area__c=5500),
    new Property_Asset__c(Name='Katy Mills Strip Asset',    Property__c=properties[4].Id, Property_Type__c='Retail',    Status__c='Active', Vacant_Area__c=14000),
    new Property_Asset__c(Name='Heights Marketplace Asset', Property__c=properties[5].Id, Property_Type__c='Retail',    Status__c='Active', Vacant_Area__c=9000)
};
insert assets;

// Convenience aliases (index matches p1..p6)
Property_Asset__c pa1 = assets[0]; // Westgate Plaza      – 42000 sqft, vacant 11000 → leased 31000
Property_Asset__c pa2 = assets[1]; // Sterling Crossing   – 28500 sqft, vacant 7500  → leased 21000
Property_Asset__c pa3 = assets[2]; // Magnolia Commons    – 65200 sqft, vacant 18000 → leased 47200
Property_Asset__c pa4 = assets[3]; // Bayou Bend Center   – 19800 sqft, vacant 5500  → leased 14300
Property_Asset__c pa5 = assets[4]; // Katy Mills Strip    – 51400 sqft, vacant 14000 → leased 37400
Property_Asset__c pa6 = assets[5]; // Heights Marketplace – 33750 sqft, vacant 9000  → leased 24750

// ─── 4) Broker Assignments (10) ─────────────────────────────────────────────
// Leased_Area__c is set on Active assignments only (null on Fully Leased/Disposed).
// Active leased area = (sqft − vacant):
//   a1 p1 b1 Active – leased 31000  (42000 − 11000)
//   a2 p2 b2 Active – leased 21000  (28500 −  7500)
//   a3 p3 b3 Active – leased 47200  (65200 − 18000)
//   a6 p5 b2 Active – leased 37400  (51400 − 14000)
//   a8 p6 b4 Active – leased 24750  (33750 −  9000)

List<Broker_Assignment__c> assignments = new List<Broker_Assignment__c>{
    // a1  p1/b1  Active
    new Broker_Assignment__c(
        Property_Asset__c   = pa1.Id,
        Broker__c           = b1,
        Status__c           = 'Active',
        Listing_Start_Date__c = Date.newInstance(2026, 5, 12),
        Last_Check_In_Date__c = Date.newInstance(2026, 6, 25),
        Leased_Area__c      = 31000
    ),
    // a2  p2/b2  Active
    new Broker_Assignment__c(
        Property_Asset__c   = pa2.Id,
        Broker__c           = b2,
        Status__c           = 'Active',
        Listing_Start_Date__c = Date.newInstance(2026, 4, 2),
        Last_Check_In_Date__c = Date.newInstance(2026, 6, 4),
        Leased_Area__c      = 21000
    ),
    // a3  p3/b3  Active
    new Broker_Assignment__c(
        Property_Asset__c   = pa3.Id,
        Broker__c           = b3,
        Status__c           = 'Active',
        Listing_Start_Date__c = Date.newInstance(2026, 3, 15),
        Last_Check_In_Date__c = Date.newInstance(2026, 6, 12),
        Leased_Area__c      = 47200
    ),
    // a4  p4/b4  Fully Leased
    new Broker_Assignment__c(
        Property_Asset__c   = pa4.Id,
        Broker__c           = b4,
        Status__c           = 'Fully Leased',
        Listing_Start_Date__c = Date.newInstance(2025, 9, 1),
        Listing_End_Date__c   = Date.newInstance(2026, 2, 20),
        Reason_Ended__c     = 'Leased Up',
        Last_Check_In_Date__c = Date.newInstance(2026, 2, 15)
    ),
    // a5  p5/b1  Disposed
    new Broker_Assignment__c(
        Property_Asset__c   = pa5.Id,
        Broker__c           = b1,
        Status__c           = 'Disposed',
        Listing_Start_Date__c = Date.newInstance(2025, 6, 10),
        Listing_End_Date__c   = Date.newInstance(2025, 11, 30),
        Reason_Ended__c     = 'Performance Issue',
        Last_Check_In_Date__c = Date.newInstance(2025, 11, 20)
    ),
    // a6  p5/b2  Active
    new Broker_Assignment__c(
        Property_Asset__c   = pa5.Id,
        Broker__c           = b2,
        Status__c           = 'Active',
        Listing_Start_Date__c = Date.newInstance(2025, 12, 1),
        Last_Check_In_Date__c = Date.newInstance(2026, 6, 28),
        Leased_Area__c      = 37400
    ),
    // a7  p6/b3  Disposed
    new Broker_Assignment__c(
        Property_Asset__c   = pa6.Id,
        Broker__c           = b3,
        Status__c           = 'Disposed',
        Listing_Start_Date__c = Date.newInstance(2025, 8, 15),
        Listing_End_Date__c   = Date.newInstance(2026, 1, 10),
        Reason_Ended__c     = 'Company Decision',
        Last_Check_In_Date__c = Date.newInstance(2026, 1, 5)
    ),
    // a8  p6/b4  Active
    new Broker_Assignment__c(
        Property_Asset__c   = pa6.Id,
        Broker__c           = b4,
        Status__c           = 'Active',
        Listing_Start_Date__c = Date.newInstance(2026, 1, 15),
        Last_Check_In_Date__c = Date.newInstance(2026, 6, 8),
        Leased_Area__c      = 24750
    ),
    // a9  p1/b3  Disposed
    new Broker_Assignment__c(
        Property_Asset__c   = pa1.Id,
        Broker__c           = b3,
        Status__c           = 'Disposed',
        Listing_Start_Date__c = Date.newInstance(2024, 11, 1),
        Listing_End_Date__c   = Date.newInstance(2025, 4, 30),
        Reason_Ended__c     = 'Performance Issue',
        Last_Check_In_Date__c = Date.newInstance(2025, 4, 20)
    ),
    // a10 p3/b4  Fully Leased
    new Broker_Assignment__c(
        Property_Asset__c   = pa3.Id,
        Broker__c           = b4,
        Status__c           = 'Fully Leased',
        Listing_Start_Date__c = Date.newInstance(2024, 5, 1),
        Listing_End_Date__c   = Date.newInstance(2025, 2, 28),
        Reason_Ended__c     = 'Leased Up',
        Last_Check_In_Date__c = Date.newInstance(2025, 2, 20)
    )
};

insert assignments;
System.debug('Seeded ' + assignments.size() + ' broker assignments.');
