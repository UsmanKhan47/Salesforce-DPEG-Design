// Top up NDA + LOI activity for the "NDAs This Month" and "LOIs Submitted"
// dashboard metric tiles. Standalone (no Opportunity) so they only affect the
// activity counts, not the deal-based tiles or the NDA Tracker table
// (which filters Opportunity != blank). Dates fall in the current month.
Date t = Date.today();

List<NDA__c> ndas = new List<NDA__c>{
    new NDA__c(Status__c = 'Sent',    Date_Sent__c = t.addDays(-1)),
    new NDA__c(Status__c = 'Pending', Date_Sent__c = t.addDays(-3)),
    new NDA__c(Status__c = 'Signed',  Date_Sent__c = t.addDays(-5),
               NDA_Signed__c = true,  Date_Signed__c = t.addDays(-2)),
    new NDA__c(Status__c = 'Sent',    Date_Sent__c = t.addDays(-8))
};
insert ndas;

List<LOI__c> lois = new List<LOI__c>{
    new LOI__c(LOI_Status__c = 'Submitted',        Submitted_Date__c = t.addDays(-1),
               Offer_Price__c = 4100000,  Offer_Cap_Rate__c = 6.7),
    new LOI__c(LOI_Status__c = 'Pending Approval', Submitted_Date__c = t.addDays(-3),
               Offer_Price__c = 7600000,  Offer_Cap_Rate__c = 5.8),
    new LOI__c(LOI_Status__c = 'Submitted',        Submitted_Date__c = t.addDays(-6),
               Offer_Price__c = 10800000, Offer_Cap_Rate__c = 7.0)
};
insert lois;

System.debug('Seeded ' + ndas.size() + ' NDAs and ' + lois.size() + ' LOIs for the metric tiles.');
