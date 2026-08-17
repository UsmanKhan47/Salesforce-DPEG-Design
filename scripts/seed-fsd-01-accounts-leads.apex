/**
 * FSD demo data - Part 1: broker firms/contacts + standalone (never-converted) Leads
 * spread across the Lead Status picklist. Idempotent: skips the whole batch if the
 * marker record (first broker firm / first Lead address) already exists.
 */

// ---------- Broker firms + contacts ----------
List<String> firmNames = new List<String>{
    'Colliers Houston', 'Cushman & Wakefield Dallas', 'Stream Realty Partners',
    'Transwestern', 'Matthews Real Estate Investment Services', 'Newmark Knight Frank'
};
Map<String, Id> firmIdByName = new Map<String, Id>();
for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :firmNames]) {
    firmIdByName.put(a.Name, a.Id);
}
List<Account> newAccts = new List<Account>();
for (String n : firmNames) {
    if (!firmIdByName.containsKey(n)) {
        newAccts.add(new Account(Name = n, Type = 'Broker Firm'));
    }
}
if (!newAccts.isEmpty()) {
    insert newAccts;
    for (Account a : newAccts) { firmIdByName.put(a.Name, a.Id); }
}

Map<String, List<String>> contactPlan = new Map<String, List<String>>{
    // firm => firstName, lastName, title, emailLocal, phone
    'Colliers Houston' => new List<String>{ 'Derek', 'Simmons', 'Senior Vice President', 'derek.simmons@colliers.com', '713-555-0142' },
    'Cushman & Wakefield Dallas' => new List<String>{ 'Priya', 'Nair', 'Executive Director', 'priya.nair@cushwake.com', '214-555-0187' },
    'Stream Realty Partners' => new List<String>{ 'Ryan', 'O\'Connell', 'Managing Director', 'ryan.oconnell@streamrealty.com', '512-555-0163' },
    'Transwestern' => new List<String>{ 'Sofia', 'Delgado', 'Senior Associate', 'sofia.delgado@transwestern.com', '469-555-0119' },
    'Matthews Real Estate Investment Services' => new List<String>{ 'Marcus', 'Whitfield', 'Vice President', 'marcus.whitfield@matthews.com', '972-555-0154' },
    'Newmark Knight Frank' => new List<String>{ 'Katie', 'Osborne', 'Director', 'katie.osborne@nmrk.com', '214-555-0198' }
};
Set<Id> existingContactAcctIds = new Set<Id>();
for (Contact c : [SELECT AccountId FROM Contact WHERE AccountId IN :firmIdByName.values()]) {
    existingContactAcctIds.add(c.AccountId);
}
List<Contact> newContacts = new List<Contact>();
for (String firm : contactPlan.keySet()) {
    Id acctId = firmIdByName.get(firm);
    if (acctId != null && !existingContactAcctIds.contains(acctId)) {
        List<String> p = contactPlan.get(firm);
        newContacts.add(new Contact(
            FirstName = p[0], LastName = p[1], Title = p[2],
            Email = p[3], Phone = p[4], AccountId = acctId
        ));
    }
}
if (!newContacts.isEmpty()) { insert newContacts; }

System.debug('Broker firms ready: ' + firmIdByName.size() + '  New contacts: ' + newContacts.size());

// ---------- Standalone Leads (never converted) ----------
final String MARKER_ADDR = '4200 Riverwalk Pkwy';
Integer already = [SELECT COUNT() FROM Lead WHERE Property_Address__c = :MARKER_ADDR];
if (already > 0) {
    System.debug('Standalone leads already seeded - skipping Part 1 Lead insert.');
} else {
    // [Company, PropertyName, Address, Street, City, PostalCode, AssetType, DealType,
    //  GuidancePrice, GuidLow, GuidHigh, CapRate, BrokerName, BrokerEmail, Phone,
    //  Status, LeadSource, ParseConfidence, DaysAgo, DisqReason]
    List<List<Object>> rows = new List<List<Object>>{
        // New (4)
        new List<Object>{ 'Colliers Houston', 'Riverwalk Marketplace', 'San Antonio, TX', '4200 Riverwalk Pkwy', 'San Antonio', '78238', 'Retail', 'Retail', 14200000, 13500000, 14900000, 6.75, 'Derek Simmons', 'derek.simmons@colliers.com', '713-555-0142', 'New', 'Email-to-Lead', 'HIGH', 2, null },
        new List<Object>{ 'Stream Realty Partners', 'Cedar Park Industrial Yard', 'Cedar Park, TX', '1801 Cypress Creek Rd', 'Cedar Park', '78613', 'Industrial', 'Retail', 9800000, 9200000, 10200000, 7.1, 'Ryan O\'Connell', 'ryan.oconnell@streamrealty.com', '512-555-0163', 'New', 'Web', 'MEDIUM', 4, null },
        new List<Object>{ 'Transwestern', 'Legacy West Annex Land', 'Plano, TX', '6400 Legacy Dr', 'Plano', '75024', 'Land', 'Land', 5400000, 5000000, 5800000, null, 'Sofia Delgado', 'sofia.delgado@transwestern.com', '469-555-0119', 'New', 'Broker Portal', 'MEDIUM', 1, null },
        new List<Object>{ 'Matthews Real Estate Investment Services', 'Heights Corner Office', 'Houston, TX', '1500 Heights Blvd', 'Houston', '77008', 'Office', 'Retail', 11600000, 11000000, 12100000, 7.4, 'Marcus Whitfield', 'marcus.whitfield@matthews.com', '972-555-0154', 'New', 'Phone Inquiry', 'HIGH', 6, null },
        // Under Review (3)
        new List<Object>{ 'Cushman & Wakefield Dallas', 'Alamo Ranch Shopping Center', 'San Antonio, TX', '11550 Alamo Ranch Pkwy', 'San Antonio', '78253', 'Retail', 'Retail', 22900000, 21800000, 23900000, 6.4, 'Priya Nair', 'priya.nair@cushwake.com', '214-555-0187', 'Under Review', 'Email-to-Lead', 'HIGH', 9, null },
        new List<Object>{ 'Newmark Knight Frank', 'Round Rock Business Park', 'Round Rock, TX', '2900 Gattis School Rd', 'Round Rock', '78664', 'Industrial', 'Retail', 17300000, 16500000, 18100000, 7.0, 'Katie Osborne', 'katie.osborne@nmrk.com', '214-555-0198', 'Under Review', 'Manual Entry', 'MEDIUM', 11, null },
        new List<Object>{ 'Colliers Houston', 'Fry Road Retail Pad', 'Cypress, TX', '18500 Fry Rd', 'Cypress', '77433', 'Retail', 'Retail', 6750000, 6400000, 7100000, 6.9, 'Derek Simmons', 'derek.simmons@colliers.com', '713-555-0142', 'Under Review', 'Web', 'MEDIUM', 8, null },
        // Qualified (3)
        new List<Object>{ 'Stream Realty Partners', 'Preston Hollow Medical Plaza', 'Dallas, TX', '8300 Walnut Hill Ln', 'Dallas', '75231', 'Medical Office', 'Retail', 28400000, 27200000, 29600000, 6.2, 'Ryan O\'Connell', 'ryan.oconnell@streamrealty.com', '512-555-0163', 'Qualified', 'Email-to-Lead', 'HIGH', 15, null },
        new List<Object>{ 'Transwestern', 'Georgetown Land Assemblage', 'Georgetown, TX', '3400 Williams Dr', 'Georgetown', '78628', 'Land', 'Land', 7900000, 7400000, 8300000, null, 'Sofia Delgado', 'sofia.delgado@transwestern.com', '469-555-0119', 'Qualified', 'Broker Portal', 'MEDIUM', 13, null },
        new List<Object>{ 'Matthews Real Estate Investment Services', 'Katy Crossing Apartments', 'Katy, TX', '22000 Kingsland Blvd', 'Katy', '77450', 'Multifamily', 'Retail', 34600000, 33000000, 36200000, 5.8, 'Marcus Whitfield', 'marcus.whitfield@matthews.com', '972-555-0154', 'Qualified', 'Manual Entry', 'HIGH', 18, null },
        // Disqualified (2)
        new List<Object>{ 'Newmark Knight Frank', 'Baytown Distribution Center', 'Baytown, TX', '5100 N Main St', 'Baytown', '77521', 'Industrial', 'Retail', 19200000, 18300000, 20100000, 7.3, 'Katie Osborne', 'katie.osborne@nmrk.com', '214-555-0198', 'Disqualified', 'Email-to-Lead', 'LOW', 27, 'Wrong Market' },
        new List<Object>{ 'Cushman & Wakefield Dallas', 'Redbird Retail Center', 'Dallas, TX', '3300 W Camp Wisdom Rd', 'Dallas', '75237', 'Retail', 'Retail', 8600000, 8100000, 9000000, 7.6, 'Priya Nair', 'priya.nair@cushwake.com', '214-555-0187', 'Disqualified', 'Web', 'LOW', 22, 'Price Too High' }
    };

    List<Lead> leads = new List<Lead>();
    for (List<Object> r : rows) {
        String brokerFull = (String) r[12];
        Integer sp = brokerFull.lastIndexOf(' ');
        String bFirst = sp > 0 ? brokerFull.substring(0, sp) : brokerFull;
        String bLast = sp > 0 ? brokerFull.substring(sp + 1) : brokerFull;
        Lead ld = new Lead(
            FirstName = bFirst,
            LastName = bLast,
            Company = (String) r[0],
            Property_Name__c = (String) r[1],
            Property_Address__c = (String) r[3] + ', ' + (String) r[4] + ', TX',
            Street = (String) r[3],
            City = (String) r[4],
            State = 'TX',
            PostalCode = (String) r[5],
            Asset_Type__c = (String) r[6],
            Deal_Type__c = (String) r[7],
            Guidance_Price__c = (Decimal) (Integer) r[8],
            Guidance_Price_Low__c = (Decimal) (Integer) r[9],
            Guidance_Price_High__c = (Decimal) (Integer) r[10],
            Guidance_Cap_Rate__c = r[11] == null ? null : (Decimal) r[11],
            Listing_Broker_Name__c = (String) r[12],
            Listing_Broker_Email__c = (String) r[13],
            Broker_First__c = (String) r[12],
            Phone = (String) r[14],
            Status = (String) r[15],
            LeadSource = (String) r[16],
            Parse_Confidence__c = (String) r[17],
            First_Seen_Date__c = DateTime.now().addDays(-(Integer) r[18]),
            Sale_Process__c = 'Off-Market'
        );
        if (r[19] != null) { ld.Disqualification_Reason__c = (String) r[19]; }
        leads.add(ld);
    }
    insert leads;
    System.debug('Inserted ' + leads.size() + ' standalone Leads.');
}
