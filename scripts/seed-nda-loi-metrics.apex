// Top up NDA + LOI activity for the "NDAs This Month" and "LOIs Submitted"
// dashboard metric tiles. Standalone (no Opportunity) so they only affect the
// activity counts, not the deal-based tiles or the NDA Tracker table
// (which filters Opportunity != blank). Dates fall in the current month.
//
// ⚠ RECORD TYPE / STATUS (fixed 2026-08-29). These rows set NO RecordTypeId, so they land on the
// running user's DEFAULT NDA__c record type — and `Status__c` is a RESTRICTED picklist whose
// allowed subset differs per record type (measured; enforced by Apex DML, not just the UI — see
// the XML comment in objects/NDA__c/recordTypes/Acquisition_NDA.recordType-meta.xml):
//     Acquisition_NDA : Pending, Received, Signed        ('Sent' REMOVED 2026-08-27)
//     Disposition_NDA : Prepare, Approved, Sent, Signed, Declined
// The two `Status__c = 'Sent'` rows below were repointed to 'Received', NOT stamped as
// Disposition_NDA. Reason: the 'Pending' row below is valid ONLY on Acquisition_NDA, so forcing
// these onto Disposition_NDA would swap one INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST for another
// — this is an acquisition-side metric seed and every value here must be acquisition-valid.
Date t = Date.today();

List<NDA__c> ndas = new List<NDA__c>{
    new NDA__c(Status__c = 'Received', Date_Sent__c = t.addDays(-1)),
    new NDA__c(Status__c = 'Pending',  Date_Sent__c = t.addDays(-3)),
    new NDA__c(Status__c = 'Signed',   Date_Sent__c = t.addDays(-5),
               NDA_Signed__c = true,   Date_Signed__c = t.addDays(-2)),
    new NDA__c(Status__c = 'Received', Date_Sent__c = t.addDays(-8))
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
