for (BOV_Submission__c b : [SELECT Id, Broker_Firm__c, BOV_Score__c, Disposition__r.Name FROM BOV_Submission__c ORDER BY Disposition__r.Name, BOV_Score__c DESC]) {
    System.debug('BOV: ' + b.Disposition__r.Name + ' | ' + b.Broker_Firm__c + ' | Score: ' + b.BOV_Score__c);
}
for (Broker_Listing__c bl : [SELECT Id, Broker_Firm__c, Days_On_Market__c, Disposition__r.Name FROM Broker_Listing__c]) {
    System.debug('Listing: ' + bl.Disposition__r.Name + ' | ' + bl.Broker_Firm__c + ' | DOM: ' + bl.Days_On_Market__c);
}
