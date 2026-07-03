// Seed Work Order Tracker demo data. Idempotent: skips when work orders exist.
// Run: sf apex run -f scripts/seed-work-orders.apex
if (![SELECT Id FROM Work_Order__c LIMIT 1].isEmpty()) {
    System.debug('Seed skipped — Work Order records already exist.');
} else {
    List<String> names = new List<String>{ 'Westgate Plaza', 'Sterling Crossing', 'Magnolia Commons', 'Bayou Bend Center', 'Katy Mills Strip', 'Heights Marketplace' };
    Map<String, Property_Asset__c> assets = new Map<String, Property_Asset__c>();
    for (Property_Asset__c a : [SELECT Id, Name FROM Property_Asset__c WHERE Name IN :names]) assets.put(a.Name, a);
    List<Property__c> newProps = new List<Property__c>();
    for (String nm : names) {
        if (!assets.containsKey(nm)) newProps.add(new Property__c(Name=nm, Address__c='100 ' + nm + ' Dr', City__c='Houston', State__c='TX', Square_Footage__c=40000, Asset_Type__c='Retail'));
    }
    insert newProps;
    List<Property_Asset__c> newAssets = new List<Property_Asset__c>();
    for (Property__c p : newProps) newAssets.add(new Property_Asset__c(Name=p.Name, Property__c=p.Id, Property_Type__c='Retail', Status__c='Active'));
    insert newAssets;
    for (Property_Asset__c a : newAssets) assets.put(a.Name, a);

    Datetime n = Datetime.now();
    List<Work_Order__c> ws = new List<Work_Order__c>{
        // 0 Critical breached escalation (30h / 24h SLA), vendor delay
        new Work_Order__c(Subject__c='AC down — no cooling in suite', Category__c='HVAC', Priority__c='Critical', Status__c='In Progress', Description__c='AC stopped completely — thermostat reads 84 and climbing.', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit__c='Suite 120', Tenant_Name__c='Riverside Dental', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-30), First_Touched_Date__c=n.addHours(-29), Delay_Reason__c='Vendor delay'),
        // 1 Critical on-track (fresh 4h)
        new Work_Order__c(Subject__c='Active water leak under sink', Category__c='Plumbing', Priority__c='Critical', Status__c='In Progress', Description__c='Water leaking under the break-room sink, spreading to the hallway.', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit__c='Bay 4', Tenant_Name__c='Sunbelt Rentals', Vendor__c='Rapid Rooter Plumbing', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-4), First_Touched_Date__c=n.addHours(-3)),
        // 2 High breached escalation (60h / 48h SLA), New + UNTOUCHED
        new Work_Order__c(Subject__c='Parking lot lights out on north side', Category__c='Electrical', Priority__c='High', Status__c='New', Description__c='Whole north row of lot lights out for two nights.', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit__c='Common area', Tenant_Name__c='Golden Wok', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-60)),
        // 3 High On Hold, tenant unresponsive (40h / 48h -> due soon)
        new Work_Order__c(Subject__c='Thermostat dead — no cooling control', Category__c='HVAC', Priority__c='High', Status__c='On Hold', Description__c='Thermostat screen blank; unit cycles on its own.', Property_Asset__c=assets.get('Heights Marketplace').Id, Unit__c='Suite 3', Tenant_Name__c='Pearl Nails', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-40), First_Touched_Date__c=n.addHours(-38), Delay_Reason__c='Tenant unresponsive'),
        // 4 High on-track (fresh)
        new Work_Order__c(Subject__c='Walk-in cooler temperature rising', Category__c='Refrigeration', Priority__c='High', Status__c='In Progress', Description__c='Walk-in cooler at 48F and climbing since this morning.', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit__c='Bay 1', Tenant_Name__c='Cafe Verde', Vendor__c='ColdChain Services', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-6), First_Touched_Date__c=n.addHours(-5)),
        // 5 Medium In Progress on-track (72h / 168h)
        new Work_Order__c(Subject__c='Restroom faucet dripping constantly', Category__c='Plumbing', Priority__c='Medium', Status__c='In Progress', Description__c='Patient restroom faucet drips non-stop even when shut tight.', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit__c='Suite 200', Tenant_Name__c='Metro Urgent Care', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-72), First_Touched_Date__c=n.addHours(-48)),
        // 6 Medium On Hold, Other (150h / 168h -> due soon)
        new Work_Order__c(Subject__c='Ceiling tile stained near entry', Category__c='General', Priority__c='Medium', Status__c='On Hold', Description__c='Large brown water stain on the ceiling tile at the entrance.', Property_Asset__c=assets.get('Katy Mills Strip').Id, Unit__c='Floor 2', Tenant_Name__c='TechHub Coworking', Vendor__c='Summit Roofing', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-150), First_Touched_Date__c=n.addHours(-140), Delay_Reason__c='Other'),
        // 7 Medium New UNTOUCHED (fresh)
        new Work_Order__c(Subject__c='Rear exit door closer broken', Category__c='Doors & Locks', Priority__c='Medium', Status__c='New', Description__c='Closer arm snapped; door slams shut hard.', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit__c='Anchor B', Tenant_Name__c='Anytime Fitness', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-10)),
        // 8 Low In Progress on-track
        new Work_Order__c(Subject__c='Monument sign lamp out', Category__c='Electrical', Priority__c='Low', Status__c='In Progress', Description__c='Monument sign panel not lighting at night for one tenant.', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit__c='Suite 210', Tenant_Name__c='Bright Smiles Ortho', Vendor__c='BrightSpark Electric', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-240), First_Touched_Date__c=n.addHours(-180)),
        // 9 Low breached (400h / 360h SLA) In Progress
        new Work_Order__c(Subject__c='Sprinkler head broken at entrance bed', Category__c='Landscaping', Priority__c='Low', Status__c='In Progress', Description__c='Sprinkler head snapped; water pools on the sidewalk.', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit__c='Suite 150', Tenant_Name__c='Prime Insurance', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-400), First_Touched_Date__c=n.addHours(-300)),
        // 10 Critical CLOSED (resolved)
        new Work_Order__c(Subject__c='RTU-2 compressor failure — no AC', Category__c='HVAC', Priority__c='Critical', Status__c='Closed', Description__c='Rooftop unit failed completely; no air movement.', Property_Asset__c=assets.get('Westgate Plaza').Id, Unit__c='Suite 120', Tenant_Name__c='Riverside Dental', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-340), First_Touched_Date__c=n.addHours(-339), Completed_Date__c=n.addHours(-320)),
        // 11 High COMPLETED (resolved)
        new Work_Order__c(Subject__c='Sewer smell in corridor', Category__c='Plumbing', Priority__c='High', Status__c='Completed', Description__c='Strong sewer smell in the shared corridor.', Property_Asset__c=assets.get('Sterling Crossing').Id, Unit__c='Bay 4', Tenant_Name__c='Sunbelt Rentals', Vendor__c='Rapid Rooter Plumbing', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-420), First_Touched_Date__c=n.addHours(-419), Completed_Date__c=n.addHours(-390)),
        // 12 Medium CLOSED (resolved) — Electrical
        new Work_Order__c(Subject__c='Outlet dead in suite kitchen', Category__c='Electrical', Priority__c='Medium', Status__c='Closed', Description__c='Outlet by the kitchen prep counter is dead.', Property_Asset__c=assets.get('Magnolia Commons').Id, Unit__c='Unit 8', Tenant_Name__c='Golden Wok', Vendor__c='BrightSpark Electric', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-560), First_Touched_Date__c=n.addHours(-540), Completed_Date__c=n.addHours(-460)),
        // 13 Medium CLOSED (resolved) — HVAC
        new Work_Order__c(Subject__c='Vent noise and weak airflow', Category__c='HVAC', Priority__c='Medium', Status__c='Closed', Description__c='Vents rattle loudly and push little air.', Property_Asset__c=assets.get('Bayou Bend Center').Id, Unit__c='Suite 200', Tenant_Name__c='Metro Urgent Care', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Property Manager', Reported_Date__c=n.addHours(-500), First_Touched_Date__c=n.addHours(-480), Completed_Date__c=n.addHours(-380)),
        // 14 High CLOSED (resolved) — Refrigeration
        new Work_Order__c(Subject__c='AC intermittent — cycling off', Category__c='HVAC', Priority__c='High', Status__c='Closed', Description__c='AC shuts off every hour, never gets cool.', Property_Asset__c=assets.get('Katy Mills Strip').Id, Unit__c='Unit 12', Tenant_Name__c='Dollar Depot', Vendor__c='Gulf Coast HVAC', Owner_Role__c='Maintenance', Reported_Date__c=n.addHours(-460), First_Touched_Date__c=n.addHours(-450), Completed_Date__c=n.addHours(-410))
    };
    insert ws;

    List<Work_Order_Activity__c> acts = new List<Work_Order_Activity__c>();
    // (work-order index, hours ago, kind, actor, text)
    List<List<Object>> entries = new List<List<Object>>{
        new List<Object>{ 0, 30, 'Sync',   'Yardi', 'Work order created from tenant call — AC not cooling, suite reading 84F.' },
        new List<Object>{ 0, 29, 'Status', 'Yardi', 'Status changed: New → In Progress. Dispatched in Yardi.' },
        new List<Object>{ 0, 26, 'Vendor', 'Yardi', 'Vendor assigned: Gulf Coast HVAC. Site visit completed same day.' },
        new List<Object>{ 0, 8,  'Note',   'Yardi', 'Vendor note: compressor start capacitor on backorder — ETA 2 days.' },
        new List<Object>{ 0, 4,  'Flag',   'System', 'Reason for delay flagged in Salesforce: Vendor delay.' },
        new List<Object>{ 1, 4,  'Sync',   'Yardi', 'Work order created from tenant call — active leak under sink, water spreading.' },
        new List<Object>{ 1, 3,  'Vendor', 'Yardi', 'Vendor assigned: Rapid Rooter Plumbing. Emergency dispatch — shutoff valve closed.' },
        new List<Object>{ 2, 60, 'Sync',   'Yardi', 'Work order created from tenant portal — north lot lights out, tenants closing after dark.' },
        new List<Object>{ 3, 40, 'Sync',   'Yardi', 'Work order created from tenant call — thermostat unresponsive, no cooling control.' },
        new List<Object>{ 3, 30, 'Status', 'Yardi', 'Status changed: In Progress → On Hold. Two access attempts failed — tenant not answering.' },
        new List<Object>{ 3, 12, 'Flag',   'System', 'Reason for delay flagged in Salesforce: Tenant unresponsive.' },
        new List<Object>{ 4, 6,  'Sync',   'Yardi', 'Work order created from tenant call — walk-in cooler at 48F and climbing.' },
        new List<Object>{ 4, 5,  'Vendor', 'Yardi', 'Vendor assigned: ColdChain Services. Technician en route.' },
        new List<Object>{ 5, 72, 'Sync',   'Yardi', 'Work order created from tenant portal — restroom faucet dripping constantly.' },
        new List<Object>{ 6, 150,'Sync',   'Yardi', 'Work order created — ceiling tile stained near entry, likely prior roof leak.' },
        new List<Object>{ 6, 120,'Status', 'Yardi', 'Status changed: In Progress → On Hold. Waiting on roof inspection report.' },
        new List<Object>{ 6, 24, 'Flag',   'System', 'Reason for delay flagged in Salesforce: Other — pending roof inspection.' },
        new List<Object>{ 7, 10, 'Sync',   'Yardi', 'Work order created from tenant portal — rear exit door closer broken, door slamming.' },
        new List<Object>{ 8, 240,'Sync',   'Yardi', 'Work order created during property walk — monument sign lamp out for one tenant.' },
        new List<Object>{ 8, 40, 'Vendor', 'Yardi', 'Vendor assigned: BrightSpark Electric — bundled with other electrical punch items.' },
        new List<Object>{ 9, 400,'Sync',   'Yardi', 'Work order created from tenant portal — sprinkler head broken, water pooling.' },
        new List<Object>{ 10,340,'Sync',   'Yardi', 'Work order created from tenant call — RTU-2 compressor failure, no cooling.' },
        new List<Object>{ 10,320,'Status', 'Yardi', 'Status changed: Completed → Closed. Compressor replaced, cooling restored.' },
        new List<Object>{ 11,420,'Sync',   'Yardi', 'Work order created from tenant call — sewer odor in shared corridor.' },
        new List<Object>{ 11,390,'Status', 'Yardi', 'Status changed: In Progress → Completed. Dried P-trap refilled and sealed.' },
        new List<Object>{ 12,560,'Sync',   'Yardi', 'Work order created from tenant portal — dead outlet in suite kitchen.' },
        new List<Object>{ 13,500,'Sync',   'Yardi', 'Work order created from tenant call — vent noise and weak airflow.' },
        new List<Object>{ 14,460,'Sync',   'Yardi', 'Work order created from tenant call — AC cycling off intermittently.' }
    };
    for (List<Object> e : entries) {
        acts.add(new Work_Order_Activity__c(
            Work_Order__c = ws[(Integer) e[0]].Id,
            Kind__c = (String) e[2],
            Actor__c = (String) e[3],
            Detail__c = (String) e[4],
            Entry_Date__c = n.addHours(-(Integer) e[1])
        ));
    }
    insert acts;
    System.debug('Seeded ' + ws.size() + ' work orders with ' + acts.size() + ' activity entries.');
}
