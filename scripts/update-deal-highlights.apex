// Backfill the demo deal for the new Deal Highlights bar.
Opportunity o = [SELECT Id FROM Opportunity WHERE Name = 'Magnolia Crossing' LIMIT 1];
o.Asking_Price__c = 31500000;
update o;

Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :o.Id ORDER BY CreatedDate DESC LIMIT 1];
uw.Year_5_IRR__c = 17.4;
update uw;

System.debug('Updated highlights for ' + o.Id);
