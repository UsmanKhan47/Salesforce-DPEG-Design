List<Disposition__c> disps = [SELECT Id, Name, Disposition_Stage__c, Property_Asset__r.Name FROM Disposition__c ORDER BY Name];
for (Disposition__c d : disps) {
    System.debug(d.Name + ' | ' + d.Disposition_Stage__c + ' | Asset: ' + d.Property_Asset__r.Name + ' | Id: ' + d.Id);
}
Integer bovCount = [SELECT COUNT() FROM BOV_Submission__c];
Integer blCount  = [SELECT COUNT() FROM Broker_Listing__c];
System.debug('BOV Submissions total: ' + bovCount);
System.debug('Broker Listings total: ' + blCount);
