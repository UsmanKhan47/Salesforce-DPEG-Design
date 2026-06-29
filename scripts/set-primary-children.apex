// Point the demo deal's Primary_* lookups at its child records so the
// standard Related Record components render data.
Opportunity o = [SELECT Id FROM Opportunity WHERE Name = 'Magnolia Crossing' LIMIT 1];
o.Primary_Underwriting__c = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :o.Id ORDER BY CreatedDate DESC LIMIT 1].Id;
o.Primary_NDA__c = [SELECT Id FROM NDA__c WHERE Opportunity__c = :o.Id ORDER BY CreatedDate DESC LIMIT 1].Id;
o.Primary_LOI__c = [SELECT Id FROM LOI__c WHERE Opportunity__c = :o.Id ORDER BY CreatedDate DESC LIMIT 1].Id;
update o;
System.debug('Linked primary children for ' + o.Id);
