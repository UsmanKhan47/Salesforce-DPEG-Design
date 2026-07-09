// Backfill: every Opportunity without a Primary NDA gets one. Deals that already
// have an NDA child are stamped to it; the rest get a fresh Pending NDA. Stamping
// Primary_NDA__c leaves StageName untouched, so the ISCHANGED-gated
// NDA_Signed_Before_Underwriting rule never fires. Idempotent - safe to re-run.
Map<Id, Id> oppToExistingNda = new Map<Id, Id>();
for (NDA__c n : [SELECT Id, Opportunity__c FROM NDA__c WHERE Opportunity__c != null ORDER BY CreatedDate]) {
    if (!oppToExistingNda.containsKey(n.Opportunity__c)) {
        oppToExistingNda.put(n.Opportunity__c, n.Id);
    }
}

List<NDA__c> toCreate = new List<NDA__c>();
List<Opportunity> toStamp = new List<Opportunity>();
for (Opportunity o : [SELECT Id FROM Opportunity WHERE Primary_NDA__c = null]) {
    if (oppToExistingNda.containsKey(o.Id)) {
        toStamp.add(new Opportunity(Id = o.Id, Primary_NDA__c = oppToExistingNda.get(o.Id)));
    } else {
        toCreate.add(new NDA__c(Opportunity__c = o.Id, Status__c = 'Pending'));
    }
}

if (!toCreate.isEmpty()) {
    insert toCreate;
    for (NDA__c n : toCreate) {
        toStamp.add(new Opportunity(Id = n.Opportunity__c, Primary_NDA__c = n.Id));
    }
}
if (!toStamp.isEmpty()) {
    update toStamp;
}
System.debug('Backfill complete: created ' + toCreate.size() + ' NDAs, stamped ' + toStamp.size() + ' Opportunities.');
