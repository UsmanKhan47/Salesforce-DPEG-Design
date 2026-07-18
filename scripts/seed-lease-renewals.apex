// Seed Lease Renewal Tracker demo data. Idempotent: skips when renewals exist.
// Run: sf apex run -f scripts/seed-lease-renewals.apex
if (![SELECT Id FROM Lease_Renewal__c LIMIT 1].isEmpty()) {
    System.debug('Seed skipped — Lease Renewal records already exist.');
} else {
    // --- ensure 6 property assets ---
    List<String> names = new List<String>{ 'Westgate Plaza', 'Sterling Crossing', 'Magnolia Commons', 'Bayou Bend Center', 'Katy Mills Strip', 'Heights Marketplace' };
    Map<String, Property_Asset__c> assets = new Map<String, Property_Asset__c>();
    for (Property_Asset__c a : [SELECT Id, Name FROM Property_Asset__c WHERE Name IN :names]) assets.put(a.Name, a);
    List<Property__c> newProps = new List<Property__c>();
    for (String n : names) {
        if (!assets.containsKey(n)) newProps.add(new Property__c(Name=n, Address__c='100 ' + n + ' Dr', City__c='Houston', State__c='TX', Square_Footage__c=40000, Asset_Type__c='Retail'));
    }
    insert newProps;
    List<Property_Asset__c> newAssets = new List<Property_Asset__c>();
    for (Property__c p : newProps) newAssets.add(new Property_Asset__c(Name=p.Name, Property__c=p.Id, Property_Type__c='Retail', Status__c='Active'));
    insert newAssets;
    for (Property_Asset__c a : newAssets) assets.put(a.Name, a);

    Date t = Date.today();
    List<Lease_Renewal__c> rs = new List<Lease_Renewal__c>{
        // 0 Riverside Dental — critical expiry + NON-RESPONSIVE (17d)
        new Lease_Renewal__c(Tenant_Name__c='Riverside Dental', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit_Label__c='Suite 120', Space_Sq_Ft__c=2200, Lease_Start__c=t.addDays(-1800), Lease_End__c=t.addDays(25), Current_Rent__c='$26.00 / sq ft NNN', Has_Renewal_Option__c=false, Proposed_Rate__c=30.00, Stage__c='Awaiting Tenant Response', Last_Contact_Date__c=t.addDays(-17)),
        // 1 Sunbelt Rentals — negotiating, option honored
        new Lease_Renewal__c(Tenant_Name__c='Sunbelt Rentals', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit_Label__c='Bay 4', Space_Sq_Ft__c=5400, Lease_Start__c=t.addDays(-2500), Lease_End__c=t.addDays(70), Current_Rent__c='$18.00 / sq ft NNN', Has_Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 5-yr option', Proposed_Rate__c=18.54, Option_Honored__c=true, Stage__c='Negotiating', Last_Contact_Date__c=t.addDays(-4)),
        // 2 Golden Wok — notice sent, option
        new Lease_Renewal__c(Tenant_Name__c='Golden Wok', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit_Label__c='Unit 8', Space_Sq_Ft__c=1600, Lease_Start__c=t.addDays(-1090), Lease_End__c=t.addDays(49), Current_Rent__c='$24.00 / sq ft NNN', Has_Renewal_Option__c=true, Preset_Terms__c='$25.20 flat, 3-yr option', Proposed_Rate__c=25.20, Option_Honored__c=true, Stage__c='Notice Sent', Last_Contact_Date__c=t.addDays(-12)),
        // 3 Pearl Nails — not started
        new Lease_Renewal__c(Tenant_Name__c='Pearl Nails', Property_Asset__c=assets.get('Heights Marketplace').Id, Unit_Label__c='Suite 3', Space_Sq_Ft__c=1200, Lease_Start__c=t.addDays(-1095), Lease_End__c=t.addDays(105), Current_Rent__c='$22.00 / sq ft NNN', Has_Renewal_Option__c=false, Stage__c='Not Yet Started'),
        // 4 Metro Urgent Care — not started, comfortable
        new Lease_Renewal__c(Tenant_Name__c='Metro Urgent Care', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit_Label__c='Suite 200', Space_Sq_Ft__c=4200, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(151), Current_Rent__c='$28.00 / sq ft NNN', Has_Renewal_Option__c=true, Preset_Terms__c='2.5% annual escalation, 5-yr option', Proposed_Rate__c=28.70, Option_Honored__c=true, Stage__c='Not Yet Started'),
        // 5 TechHub Coworking — negotiating
        new Lease_Renewal__c(Tenant_Name__c='TechHub Coworking', Property_Asset__c=assets.get('Katy Mills Strip').Id, Unit_Label__c='Floor 2', Space_Sq_Ft__c=8800, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(34), Current_Rent__c='$20.00 / sq ft NNN', Has_Renewal_Option__c=false, Proposed_Rate__c=24.00, Stage__c='Negotiating', Last_Contact_Date__c=t.addDays(-7)),
        // 6 Bright Smiles Ortho — amendment drafted
        new Lease_Renewal__c(Tenant_Name__c='Bright Smiles Ortho', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit_Label__c='Suite 210', Space_Sq_Ft__c=2600, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(85), Current_Rent__c='$27.00 / sq ft NNN', Has_Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 5-yr option', Proposed_Rate__c=27.81, Option_Honored__c=true, Stage__c='Amendment Drafted', Last_Contact_Date__c=t.addDays(-2)),
        // 7 Cafe Verde — NON-RESPONSIVE (22d), far expiry
        new Lease_Renewal__c(Tenant_Name__c='Cafe Verde', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit_Label__c='Bay 1', Space_Sq_Ft__c=1900, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(180), Current_Rent__c='$23.00 / sq ft NNN', Has_Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 3-yr option', Proposed_Rate__c=23.69, Option_Honored__c=true, Stage__c='Notice Sent', Last_Contact_Date__c=t.addDays(-22)),
        // 8 Anytime Fitness — RENEWED (flow -> Closed Won + Renewed_Date = today)
        new Lease_Renewal__c(Tenant_Name__c='Anytime Fitness', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit_Label__c='Anchor B', Space_Sq_Ft__c=9200, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(-2), Current_Rent__c='$16.00 / sq ft NNN', Has_Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 5-yr option', Proposed_Rate__c=16.48, Option_Honored__c=true, Stage__c='Renewed', Last_Contact_Date__c=t.addDays(-14)),
        // 9 Dollar Depot — not renewing (flow -> Closed Lost)
        new Lease_Renewal__c(Tenant_Name__c='Dollar Depot', Property_Asset__c=assets.get('Katy Mills Strip').Id, Unit_Label__c='Unit 12', Space_Sq_Ft__c=3100, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(60), Current_Rent__c='$19.00 / sq ft NNN', Has_Renewal_Option__c=false, Proposed_Rate__c=23.00, Stage__c='Not Renewing', Last_Contact_Date__c=t.addDays(-20)),
        // 10 Elite Barbers — not renewing (flow -> Closed Lost); 'Vacating' stage removed 2026-07-15
        new Lease_Renewal__c(Tenant_Name__c='Elite Barbers', Property_Asset__c=assets.get('Heights Marketplace').Id, Unit_Label__c='Suite 7', Space_Sq_Ft__c=900, Lease_Start__c=t.addDays(-1095), Lease_End__c=t.addDays(28), Current_Rent__c='$30.00 / sq ft NNN', Has_Renewal_Option__c=false, Stage__c='Not Renewing', Last_Contact_Date__c=t.addDays(-26)),
        // 11 Prime Insurance — negotiating expansion
        new Lease_Renewal__c(Tenant_Name__c='Prime Insurance', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit_Label__c='Suite 150', Space_Sq_Ft__c=2000, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(95), Current_Rent__c='$25.00 / sq ft NNN', Has_Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 5-yr option', Proposed_Rate__c=26.50, Stage__c='Negotiating', Last_Contact_Date__c=t.addDays(-1))
    };
    insert rs;

    Datetime now = Datetime.now();
    List<Renewal_Activity__c> acts = new List<Renewal_Activity__c>();
    // helper-free: (renewal index, days ago, method, text)
    List<List<Object>> entries = new List<List<Object>>{
        new List<Object>{ 0, 35, 'System', 'Lease flagged for renewal — no pre-set renewal option on file. A new rate must be set before outreach.' },
        new List<Object>{ 0, 28, 'Email',  'Sent renewal notice with a request to schedule a terms discussion.' },
        new List<Object>{ 0, 23, 'Call',   'Owner approved a proposed rate of $30.00/sq ft NNN, 5-yr term.' },
        new List<Object>{ 0, 17, 'Email',  'Emailed the $30.00/sq ft counter to the tenant. Awaiting their response.' },
        new List<Object>{ 1, 43, 'System', 'Renewal window opened — pre-set option in place: 3% annual escalation on a 5-year extension.' },
        new List<Object>{ 1, 21, 'Email',  'Sent the option-rate renewal notice at $18.54/sq ft. Tenant asked about TI for a dock upgrade.' },
        new List<Object>{ 1, 4,  'Call',   'Tenant wants $8/sq ft TI toward the dock. Weighing a longer term for the improvement allowance.' },
        new List<Object>{ 2, 31, 'System', 'Renewal flagged — pre-set option: $25.20/sq ft flat on a 3-year extension.' },
        new List<Object>{ 2, 12, 'Email',  'Delivered the renewal notice at the option rate. Owner reviewing next week.' },
        new List<Object>{ 3, 2,  'System', 'Lease flagged for renewal — 105 days to expiry. No pre-set option; a new rate must be set before outreach.' },
        new List<Object>{ 4, 7,  'System', 'Renewal window opened — 151 days out. Pre-set option in place. Ready to start outreach.' },
        new List<Object>{ 5, 48, 'System', 'Renewal flagged — no pre-set option. Market has moved; a new rate must be established.' },
        new List<Object>{ 5, 14, 'Visit',  'Met the operator on-site. They want to stay but pushed back on any increase above $22. Comps are at $24.' },
        new List<Object>{ 5, 7,  'Note',   'Preparing a counter at $24.00/sq ft given current comps.' },
        new List<Object>{ 6, 34, 'System', 'Renewal flagged — pre-set 3% escalation option.' },
        new List<Object>{ 6, 18, 'Email',  'Tenant elected the renewal option at $27.81/sq ft. Aligned on a 5-year extension.' },
        new List<Object>{ 6, 2,  'Note',   'Amendment drafted with the option rate and updated dates. Sent for signature.' },
        new List<Object>{ 7, 30, 'System', 'Renewal window opened — pre-set 3% escalation option, 3-yr extension.' },
        new List<Object>{ 7, 22, 'Email',  'Sent the option-rate notice at $23.69/sq ft. No reply — followed up once with no response.' },
        new List<Object>{ 8, 73, 'System', 'Renewal flagged — pre-set 3% escalation option.' },
        new List<Object>{ 8, 41, 'Call',   'Tenant confirmed renewal at the option rate of $16.48/sq ft on a 5-year extension.' },
        new List<Object>{ 8, 14, 'Note',   'Amendment fully executed and entered into Yardi. Renewed — closed won.' },
        new List<Object>{ 9, 63, 'System', 'Renewal flagged — no pre-set option.' },
        new List<Object>{ 9, 35, 'Call',   'Owner approved a $23.00/sq ft renewal offer. Presented to the tenant.' },
        new List<Object>{ 9, 20, 'Email',  'Tenant declined — closing this location. Marked not renewing; unit returns to market.' },
        new List<Object>{ 10, 54, 'System', 'Renewal flagged — no pre-set option.' },
        new List<Object>{ 10, 26, 'Visit',  'Tenant confirmed in person they are relocating and will vacate at lease end.' },
        new List<Object>{ 11, 24, 'System', 'Renewal window opened — pre-set 3% escalation option available at $25.75/sq ft.' },
        new List<Object>{ 11, 12, 'Email',  'Tenant wants a larger footprint and will pay above the option rate. Exploring $26.50/sq ft with expansion.' },
        new List<Object>{ 11, 1,  'Call',   'Confirmed the adjacent suite frees up next month. Negotiating combined terms.' }
    };
    for (List<Object> e : entries) {
        Datetime entryStamp = now.addDays(-(Integer) e[1]);
        acts.add(new Renewal_Activity__c(
            Lease_Renewal__c = rs[(Integer) e[0]].Id,
            Method__c = (String) e[2],
            Details__c = (String) e[3],
            Entry_DateTime__c = entryStamp  // ARCHITECTURE.md §1 rule-9 stamp
        ));
    }
    insert acts;
    System.debug('Seeded ' + rs.size() + ' lease renewals with ' + acts.size() + ' timeline entries.');
}
