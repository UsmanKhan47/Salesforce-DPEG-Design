// Seed Disposition_Offer__c records so the dispositionOffer panel (shown in the
// Active Listing stage via dispositionSidebar) reflects each Broker Listing's
// Offers_Received__c rollup. Amounts are anchored just under each asset's Argus value.
//
// Before: only one offer existed (OFFER-0000, blank Buyer/Amount/Date, on a Closing
// disposition where the panel never renders) -> panel showed empty / "—" rows.

// Remove the blank orphan offer
delete [
    SELECT Id FROM Disposition_Offer__c
    WHERE Buyer_Name__c = null AND Offer_Amount__c = null AND Offer_Date__c = null
];

Map<String, Id> dispByAsset = new Map<String, Id>();
for (Disposition__c d : [
    SELECT Id, Property_Asset__r.Name
    FROM Disposition__c
    WHERE Disposition_Stage__c = 'Active Listing'
      AND Property_Asset__r.Name IN ('Maple Grove Shopping', 'Summit Business Park')
]) {
    dispByAsset.put(d.Property_Asset__r.Name, d.Id);
}

List<Disposition_Offer__c> offers = new List<Disposition_Offer__c>();

// Maple Grove Shopping — Argus $16.4M, Offers Received = 2
Id mapleId = dispByAsset.get('Maple Grove Shopping');
if (mapleId != null) {
    offers.add(new Disposition_Offer__c(
        Disposition__c = mapleId, Buyer_Name__c = 'Brookfield Asset Management',
        Offer_Amount__c = 16150000, Offer_Date__c = Date.newInstance(2026, 6, 10),
        Offer_Status__c = 'Under Review'
    ));
    offers.add(new Disposition_Offer__c(
        Disposition__c = mapleId, Buyer_Name__c = 'Sterling Bay Partners',
        Offer_Amount__c = 15750000, Offer_Date__c = Date.newInstance(2026, 6, 16),
        Offer_Status__c = 'Received'
    ));
}

// Summit Business Park — Argus $17.825M, Offers Received = 1
Id summitId = dispByAsset.get('Summit Business Park');
if (summitId != null) {
    offers.add(new Disposition_Offer__c(
        Disposition__c = summitId, Buyer_Name__c = 'Prologis, Inc.',
        Offer_Amount__c = 17400000, Offer_Date__c = Date.newInstance(2026, 6, 12),
        Offer_Status__c = 'Under Review'
    ));
}

insert offers;
System.debug('Seeded ' + offers.size() + ' Disposition_Offer__c records.');
