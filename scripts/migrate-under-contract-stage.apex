// One-time data migration for the Phase 2 stage-model change: 'Under Contract'
// was replaced in both business processes by 'PSA Negotiation' + 'PSA Executed'.
// Existing deals at 'Under Contract' move to the stage matching their state:
// contract already signed -> 'PSA Executed', otherwise -> 'PSA Negotiation'.
// Idempotent: no-op once no records remain at 'Under Contract'.
List<Opportunity> toMove = [
    SELECT Id, Contract_Signed__c, Contract_Executed_Date__c
    FROM Opportunity WHERE StageName = 'Under Contract'
];
for (Opportunity o : toMove) {
    Boolean executed = o.Contract_Signed__c == true || o.Contract_Executed_Date__c != null;
    o.StageName = executed ? 'PSA Executed' : 'PSA Negotiation';
}
update toMove;
System.debug('Migrated ' + toMove.size() + ' opportunities off Under Contract');
