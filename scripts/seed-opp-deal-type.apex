// Seed Deal_Type__c + matching record type on existing opportunities (balanced ~50/50).
// Targets only opps with no Deal Type yet, so it's safe to re-run.
Id landRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Opportunity' AND DeveloperName = 'Land' LIMIT 1].Id;
Id commRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Opportunity' AND DeveloperName = 'Commercial' LIMIT 1].Id;

List<Opportunity> opps = [SELECT Id, Asset_Type__c FROM Opportunity WHERE Deal_Type__c = null];

Integer alt = 0;
Integer landCount = 0, commCount = 0;
List<Opportunity> updates = new List<Opportunity>();
for (Opportunity o : opps) {
    Boolean isLand;
    if (o.Asset_Type__c == 'Land') {
        isLand = true;                       // honour real Land assets
    } else {
        isLand = (Math.mod(alt, 2) == 0);    // alternate the rest evenly
        alt++;
    }
    o.Deal_Type__c = isLand ? 'Land' : 'Commercial';
    o.RecordTypeId = isLand ? landRt : commRt;
    if (isLand) { landCount++; } else { commCount++; }
    updates.add(o);
}
update updates;
System.debug('SEEDED :: total=' + updates.size() + ' land=' + landCount + ' commercial=' + commCount);
