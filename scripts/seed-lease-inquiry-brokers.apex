// Populate the Broker column on the Lease Activity Tracker.
//
// The list LWC (leaseInquiryList) shows Broker_Name__c, a formula = Broker__r.FirstName & " " &
// Broker__r.LastName. It resolves only when the Broker__c (Contact lookup) is set — and neither
// the lease-inquiry seed nor the leasing-dashboard seed set it, so the column was all '—'.
// This assigns an existing broker Contact (round-robin, for firm/name variety) to every
// Lease_Inquiry__c that currently has no broker.
//
// Safe to run: it sets ONLY Broker__c, and Stage__c is untouched — so the before-save
// Lease_Inquiry_Stage_Timer (fires on ISNEW || ISCHANGED(Stage)) does NOT re-stamp
// Stage_Start_Date__c (Days in Stage / "Stalled >14d" preserved), and Lease_Inquiry_Create_Lease
// (fires only when a record newly meets Stage='Lease Drafting') does not create duplicate Lease__c.
//
// Idempotent: only touches inquiries where Broker__c is null.
// Run: sf apex run -f scripts/seed-lease-inquiry-brokers.apex

// Broker contacts = Contacts carrying a Broker_Firm__c (seeded by seed-broker-contacts.apex etc.).
List<Contact> brokers = [SELECT Id FROM Contact WHERE Broker_Firm__c != null ORDER BY LastName];
if (brokers.isEmpty()) {
    System.debug('Seed aborted — no broker Contacts (Broker_Firm__c populated) exist to assign.');
    return;
}

List<Lease_Inquiry__c> toFix = [SELECT Id FROM Lease_Inquiry__c WHERE Broker__c = null];
if (toFix.isEmpty()) {
    System.debug('Nothing to do — every Lease_Inquiry__c already has a Broker.');
    return;
}

Integer i = 0;
for (Lease_Inquiry__c q : toFix) {
    q.Broker__c = brokers[Math.mod(i, brokers.size())].Id;  // round-robin for variety
    i++;
}
update toFix;
System.debug('Assigned brokers to ' + toFix.size() + ' lease inquiries from ' + brokers.size() + ' broker contacts.');
