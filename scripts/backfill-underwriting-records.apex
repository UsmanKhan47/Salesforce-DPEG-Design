// One-time backfill after the Underwriting lifecycle build: deals already AT the
// Underwriting stage never fired the new stage-entry auto-create, so give each
// one its Underwriting record + Primary_Underwriting__c stamp. Idempotent.
List<Opportunity> opps = [
    SELECT Id, Primary_Underwriting__c,
        (SELECT Id FROM Underwritings__r ORDER BY CreatedDate DESC LIMIT 1)
    FROM Opportunity WHERE StageName = 'Underwriting'
];
List<Underwriting__c> toInsert = new List<Underwriting__c>();
List<Opportunity> toStamp = new List<Opportunity>();
for (Opportunity o : opps) {
    if (!o.Underwritings__r.isEmpty()) {
        if (o.Primary_Underwriting__c == null) {
            toStamp.add(new Opportunity(Id = o.Id, Primary_Underwriting__c = o.Underwritings__r[0].Id));
        }
        continue;
    }
    toInsert.add(new Underwriting__c(Opportunity__c = o.Id, Stage__c = 'Requested'));
}
insert toInsert;
for (Underwriting__c uw : toInsert) {
    toStamp.add(new Opportunity(Id = uw.Opportunity__c, Primary_Underwriting__c = uw.Id));
}
update toStamp;
System.debug('Backfilled ' + toInsert.size() + ' Underwriting records, stamped ' + toStamp.size() + ' opps');
