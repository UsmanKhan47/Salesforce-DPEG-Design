// Bulk-seed dispositions across ALL FOUR stages so the Disposition lists, dashboard,
// and per-stage record screens look full. Additive (does not delete existing dispositions).
Date today = Date.today();
List<Property_Asset__c> pool = [SELECT Id FROM Property_Asset__c WHERE Status__c = 'Active' ORDER BY CreatedDate];
Integer n = pool.size();
Integer pi = 0;

List<String> firms    = new List<String>{ 'CBRE', 'JLL', 'Newmark', 'Cushman' };
List<String> contacts = new List<String>{ 'Mark Chen', 'K. Rao', 'T. Black', 'S. Rivera' };

// --- Disposition Readiness (4) ---
List<Disposition__c> dsReady = new List<Disposition__c>();
for (Integer i = 0; i < 4; i++) {
    dsReady.add(new Disposition__c(Disposition_Stage__c = 'Disposition Readiness', Property_Asset__c = pool[Math.mod(pi, n)].Id));
    pi++;
}

// --- BOV Outreach (2) ---
List<Disposition__c> dsBov = new List<Disposition__c>();
List<String> bovSelected = new List<String>{ 'CBRE · Mark Chen', 'JLL · K. Rao' };
for (Integer i = 0; i < 2; i++) {
    dsBov.add(new Disposition__c(
        Disposition_Stage__c = 'BOV Outreach', Property_Asset__c = pool[Math.mod(pi, n)].Id,
        Package_Sent__c = today.addDays(-20 - i * 3), Submission_Deadline__c = today.addDays(5 + i * 2),
        Responses_Received__c = 3 + i, Brokers_Contacted__c = 6 + i, Selected_Broker__c = bovSelected[i]));
    pi++;
}

// --- Active Listing (3) ---
List<Disposition__c> dsList = new List<Disposition__c>();
for (Integer i = 0; i < 3; i++) {
    dsList.add(new Disposition__c(
        Disposition_Stage__c = 'Active Listing', Property_Asset__c = pool[Math.mod(pi, n)].Id,
        Listing_Date__c = today.addDays(-30 - i * 7), Next_Broker_Checkin__c = today.addDays(2 + i * 4)));
    pi++;
}

// --- Closing (4) ---
List<Disposition__c> dsClose = new List<Disposition__c>();
List<String> titleCos = new List<String>{ 'First American Title', 'Fidelity National', 'Stewart Title', 'Chicago Title' };
for (Integer i = 0; i < 4; i++) {
    dsClose.add(new Disposition__c(
        Disposition_Stage__c = 'Closing', Property_Asset__c = pool[Math.mod(pi, n)].Id,
        PSA_Executed__c = true, Title_Company__c = titleCos[i], Closing_Statement_Uploaded__c = (Math.mod(i, 2) == 0)));
    pi++;
}

List<Disposition__c> allD = new List<Disposition__c>();
allD.addAll(dsReady); allD.addAll(dsBov); allD.addAll(dsList); allD.addAll(dsClose);
insert allD;

// --- BOV submissions for each BOV Outreach disposition ---
List<BOV_Submission__c> bovs = new List<BOV_Submission__c>();
List<String> subStatus = new List<String>{ 'Selected', 'Backup', 'Backup', 'Backup' };
for (Disposition__c d : dsBov) {
    for (Integer j = 0; j < 4; j++) {
        bovs.add(new BOV_Submission__c(
            Disposition__c = d.Id, Broker_Firm__c = firms[j], Contact_Name__c = contacts[j],
            BOV_Amount__c = 28000000 - j * 600000, Commission_Rate__c = 2.5 + 0.2 * j,
            Days_To_Market__c = 45 + j * 5, Hist_Success_Rate__c = 82 - j * 4,
            BOV_Score__c = 90 - j * 7, Submission_Status__c = subStatus[j]));
    }
}
insert bovs;

// --- Broker listing for each Active Listing disposition ---
List<Broker_Listing__c> listings = new List<Broker_Listing__c>();
List<String> lStatus = new List<String>{ 'On Track', 'At Risk', 'On Track' };
Integer li = 0;
for (Disposition__c d : dsList) {
    listings.add(new Broker_Listing__c(
        Disposition__c = d.Id, Broker_Firm__c = firms[Math.mod(li, 4)], Contact_Name__c = contacts[Math.mod(li, 4)],
        List_Date__c = today.addDays(-30 - li * 7), Call_For_Offers_Date__c = today.addDays(10 + li * 5),
        Days_On_Market__c = 30 + li * 7, Listing_Status__c = lStatus[li], Offers_Received__c = li));
    li++;
}
insert listings;

// --- Wire for each Closing disposition ---
List<Wire__c> wires = new List<Wire__c>();
Integer wi = 0;
for (Disposition__c d : dsClose) {
    Boolean verified = (Math.mod(wi, 2) == 0);
    wires.add(new Wire__c(
        Disposition__c = d.Id, Verbal_Verification_Completed__c = verified,
        Verifier_Name__c = verified ? contacts[Math.mod(wi, 4)] : null,
        Verifier_Phone__c = verified ? '(713) 555-01' + String.valueOf(10 + wi) : null,
        Verified_DateTime__c = verified ? Datetime.now().addDays(-wi) : null,
        Wire_Instructions_Source__c = 'Title Company (independently verified)',
        Confirmed_Wire_Amount__c = 26000000 + wi * 1500000));
    wi++;
}
insert wires;

System.debug('Added ' + allD.size() + ' dispositions (Readiness ' + dsReady.size() + ', BOV ' + dsBov.size()
    + ', Listing ' + dsList.size() + ', Closing ' + dsClose.size() + '); ' + bovs.size() + ' BOVs, '
    + listings.size() + ' listings, ' + wires.size() + ' wires.');
