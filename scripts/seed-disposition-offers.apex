// Disposition_Offer__c seed — rewritten 2026-08-19. The prior version hardcoded two
// property names ("Maple Grove Shopping Center", "Summit Business Park") that do not exist
// among the current 6 real Property_Asset__c records. This version looks up the actual
// Active Listing / Closing Dispositions created by seed-disposition-bulk.apex (run that
// script first) and seeds offers against those real records instead.
//
// 1 offer on each Active Listing disposition (still under negotiation), 1 Accepted offer on
// each Closing disposition (matching the Accepted_Offer_Price__c already stamped on the
// Disposition by seed-disposition-bulk.apex). Idempotent-ish: deletes any offers it
// previously created against these same 4 dispositions before re-inserting.

Map<String, Disposition__c> dispByAssetName = new Map<String, Disposition__c>();
for (Disposition__c d : [
    SELECT Id, Disposition_Stage__c, Property_Asset__r.Name, Accepted_Offer_Price__c
    FROM Disposition__c
    WHERE Property_Asset__r.Name IN ('Copperfield Town Center', 'Universal City Retail Row',
                                       'Canyon Lake Land Holdings', 'Terrell Hills Medical Plaza')
      AND Disposition_Stage__c IN ('Active Listing', 'Closing')
]) {
    dispByAssetName.put(d.Property_Asset__r.Name, d);
}

List<Id> targetDispositionIds = new List<Id>();
for (Disposition__c d : dispByAssetName.values()) { targetDispositionIds.add(d.Id); }
if (!targetDispositionIds.isEmpty()) {
    delete [SELECT Id FROM Disposition_Offer__c WHERE Disposition__c IN :targetDispositionIds];
}

Date today = Date.today();
List<Disposition_Offer__c> offers = new List<Disposition_Offer__c>();

// Copperfield Town Center — Active Listing, 1 offer under review
Disposition__c copperfield = dispByAssetName.get('Copperfield Town Center');
if (copperfield != null) {
    offers.add(new Disposition_Offer__c(
        Disposition__c = copperfield.Id, Buyer_Name__c = 'Sterling Bay Partners',
        Offer_Amount__c = 26900000, Offer_Date__c = today.addDays(-8),
        Offer_Status__c = 'Under Review', NDA_Status__c = 'Signed',
        Offer_Financing_Type__c = 'Financed (with contingency)',
        Due_Diligence_Days__c = 45, Earnest_Money_Proposed__c = 1000000
    ));
}

// Universal City Retail Row — Active Listing, 2 competing offers
Disposition__c universalCity = dispByAssetName.get('Universal City Retail Row');
if (universalCity != null) {
    offers.add(new Disposition_Offer__c(
        Disposition__c = universalCity.Id, Buyer_Name__c = 'Brookfield Asset Management',
        Offer_Amount__c = 19600000, Offer_Date__c = today.addDays(-10),
        Offer_Status__c = 'Received', NDA_Status__c = 'Signed',
        Offer_Financing_Type__c = 'All Cash',
        Due_Diligence_Days__c = 30, Earnest_Money_Proposed__c = 750000
    ));
    offers.add(new Disposition_Offer__c(
        Disposition__c = universalCity.Id, Buyer_Name__c = 'Prologis, Inc.',
        Offer_Amount__c = 19300000, Offer_Date__c = today.addDays(-5),
        Offer_Status__c = 'Under Review', NDA_Status__c = 'Pending',
        Offer_Financing_Type__c = 'Financed (no contingency)',
        Due_Diligence_Days__c = 35, Earnest_Money_Proposed__c = 700000
    ));
}

// Canyon Lake Land Holdings — Closing, 1 accepted offer
Disposition__c canyonLake = dispByAssetName.get('Canyon Lake Land Holdings');
if (canyonLake != null) {
    offers.add(new Disposition_Offer__c(
        Disposition__c = canyonLake.Id, Buyer_Name__c = 'Crow Holdings',
        Offer_Amount__c = 8900000, Offer_Date__c = today.addDays(-30),
        Offer_Status__c = 'Accepted', Final_Agreed_Price__c = canyonLake.Accepted_Offer_Price__c,
        NDA_Status__c = 'Signed', Offer_Financing_Type__c = 'All Cash',
        Closing_Period_Days__c = 45, Due_Diligence_Days__c = 30,
        Earnest_Money_Proposed__c = 445000,
        Buyer_Counter_Price__c = 8900000, DPEG_Counter_Price__c = canyonLake.Accepted_Offer_Price__c,
        DPEG_Counter_Date__c = today.addDays(-25)
    ));
}

// Terrell Hills Medical Plaza — Closing, 1 accepted offer
Disposition__c terrellHills = dispByAssetName.get('Terrell Hills Medical Plaza');
if (terrellHills != null) {
    offers.add(new Disposition_Offer__c(
        Disposition__c = terrellHills.Id, Buyer_Name__c = 'Welltower Inc.',
        Offer_Amount__c = 14600000, Offer_Date__c = today.addDays(-35),
        Offer_Status__c = 'Accepted', Final_Agreed_Price__c = terrellHills.Accepted_Offer_Price__c,
        NDA_Status__c = 'Signed', Offer_Financing_Type__c = 'Financed (no contingency)',
        Closing_Period_Days__c = 60, Due_Diligence_Days__c = 40,
        Earnest_Money_Proposed__c = 737500,
        Buyer_Counter_Price__c = 14600000, DPEG_Counter_Price__c = terrellHills.Accepted_Offer_Price__c,
        DPEG_Counter_Date__c = today.addDays(-28)
    ));
}

insert offers;
System.debug(LoggingLevel.ERROR, 'DISPOSITION_OFFER_SEED inserted=' + offers.size());
