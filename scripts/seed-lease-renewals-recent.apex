// Seed 6 recent ACTIVE lease renewals so the Lease Renewals home page
// "Recent Renewals" list shows real Last Contact values.
//
// Why this exists: getRecentRenewals() is ORDER BY CreatedDate DESC LIMIT 6, and the
// Leasing-dashboard seed (seed-leasing-dashboard.apex) creates 6 closed "LSEED-Renewed"
// records that, being newest, fill all 6 slots — and the renewalList LWC renders '—' for
// Last Contact on any CLOSED renewal by design. Inserting these active renewals (newest)
// pushes them to the top of the list, where Last_Contact_Date__c drives "Xd ago".
//
// Kept invisible to the dashboards: Lease_End__c is > 180 days out, so both PM reports
// (Renewal_Pipeline_Buckets ≤180d, Renewals_Due_90d ≤90d) are unaffected. Only the
// "Active Renewals" KPI (+6), the Non-Responsive KPI (+1), and the Leasing
// "Renewal Negotiations" list (Status=Active, +6 rows) grow — all benign for a demo.
//
// Idempotent: deletes by the exact tenant-name set below, then re-inserts.
// Re-run this AFTER any re-run of seed-leasing-dashboard.apex (which would otherwise
// re-take the top-6 by CreatedDate).
// Run: sf apex run -f scripts/seed-lease-renewals-recent.apex

Date t = Date.today();

// Property assets created by seed-lease-renewals.apex (present in the org).
List<String> preferred = new List<String>{
    'Westgate Plaza', 'Sterling Crossing', 'Magnolia Commons',
    'Bayou Bend Center', 'Katy Mills Strip', 'Heights Marketplace'
};
Map<String, Id> propByName = new Map<String, Id>();
for (Property_Asset__c a : [SELECT Id, Name FROM Property_Asset__c WHERE Name IN :preferred]) {
    propByName.put(a.Name, a.Id);
}
// Fallback so the seed still runs if a preferred property is missing.
List<Id> anyAssets = new List<Id>();
for (Property_Asset__c a : [SELECT Id FROM Property_Asset__c ORDER BY CreatedDate LIMIT 6]) {
    anyAssets.add(a.Id);
}
if (anyAssets.isEmpty()) {
    System.debug('Seed aborted — no Property_Asset__c records exist to attach renewals to.');
    return;
}

// Resolve a property id by name, falling back to a rotating existing asset.
Map<String, Id> pick = new Map<String, Id>();
Integer ri = 0;
for (String nm : preferred) {
    pick.put(nm, propByName.containsKey(nm) ? propByName.get(nm) : anyAssets.get(Math.mod(ri, anyAssets.size())));
    ri++;
}

// (tenant, propertyName, unit, sqft, currentRent, hasOption, proposedRate, stage, daysAgoLastContact, daysToExpiry)
List<String> tenants = new List<String>{
    'Coastal Eye Care', 'Urban Threads Boutique', 'Summit Physical Therapy',
    'Bella Vista Grill', 'QuickPrint Services', 'Harbor Financial'
};

// Idempotent: clear any prior run of this seed (cascade removes their activities).
delete [SELECT Id FROM Lease_Renewal__c WHERE Tenant_Name__c IN :tenants];

List<Lease_Renewal__c> rs = new List<Lease_Renewal__c>{
    // Negotiating, contacted 3d ago
    new Lease_Renewal__c(Tenant_Name__c='Coastal Eye Care', Property_Asset__c=pick.get('Westgate Plaza'), Unit_Label__c='Suite 105', Space_Sq_Ft__c=2400, Lease_Start__c=t.addDays(-1700), Lease_End__c=t.addDays(240), Current_Rent__c='$27.00 / sq ft NNN', Renewal_Option__c=false, Proposed_Rate__c=27.80, Stage__c='Negotiating', Last_Contact_Date__c=t.addDays(-3)),
    // Notice Sent, contacted 6d ago
    new Lease_Renewal__c(Tenant_Name__c='Urban Threads Boutique', Property_Asset__c=pick.get('Sterling Crossing'), Unit_Label__c='Bay 2', Space_Sq_Ft__c=3100, Lease_Start__c=t.addDays(-1500), Lease_End__c=t.addDays(300), Current_Rent__c='$21.00 / sq ft NNN', Renewal_Option__c=true, Preset_Terms__c='3% annual escalation, 3-yr option', Proposed_Rate__c=21.60, Option_Honored__c=true, Stage__c='Notice Sent', Last_Contact_Date__c=t.addDays(-6)),
    // Awaiting Tenant Response, contacted 9d ago
    new Lease_Renewal__c(Tenant_Name__c='Summit Physical Therapy', Property_Asset__c=pick.get('Magnolia Commons'), Unit_Label__c='Suite 14', Space_Sq_Ft__c=3600, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(210), Current_Rent__c='$25.00 / sq ft NNN', Renewal_Option__c=false, Proposed_Rate__c=25.75, Stage__c='Awaiting Tenant Response', Last_Contact_Date__c=t.addDays(-9)),
    // Awaiting Tenant Response, contacted 18d ago -> NON-RESPONSIVE (red pill)
    new Lease_Renewal__c(Tenant_Name__c='Bella Vista Grill', Property_Asset__c=pick.get('Bayou Bend Center'), Unit_Label__c='Pad C', Space_Sq_Ft__c=4500, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(200), Current_Rent__c='$29.00 / sq ft NNN', Renewal_Option__c=false, Proposed_Rate__c=30.00, Stage__c='Awaiting Tenant Response', Last_Contact_Date__c=t.addDays(-18)),
    // Negotiating, contacted 2d ago
    new Lease_Renewal__c(Tenant_Name__c='QuickPrint Services', Property_Asset__c=pick.get('Katy Mills Strip'), Unit_Label__c='Unit 9', Space_Sq_Ft__c=1500, Lease_Start__c=t.addDays(-1200), Lease_End__c=t.addDays(330), Current_Rent__c='$20.00 / sq ft NNN', Renewal_Option__c=true, Preset_Terms__c='2.5% annual escalation, 5-yr option', Proposed_Rate__c=20.50, Option_Honored__c=true, Stage__c='Negotiating', Last_Contact_Date__c=t.addDays(-2)),
    // Amendment Drafted (rate negotiated; the old 'Escalated for Approval' gate was removed 2026-07-15), contacted 12d ago
    new Lease_Renewal__c(Tenant_Name__c='Harbor Financial', Property_Asset__c=pick.get('Heights Marketplace'), Unit_Label__c='Suite 240', Space_Sq_Ft__c=2800, Lease_Start__c=t.addDays(-1825), Lease_End__c=t.addDays(260), Current_Rent__c='$26.00 / sq ft NNN', Renewal_Option__c=false, Proposed_Rate__c=30.00, Stage__c='Amendment Drafted', Last_Contact_Date__c=t.addDays(-12))
};
insert rs;
System.debug('Seeded ' + rs.size() + ' recent active renewals (newest -> top of Recent Renewals list).');
