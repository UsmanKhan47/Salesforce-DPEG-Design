String convertedStatus = [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;

Lead landLead = new Lead(FirstName='Demo', LastName='Land Deal', Company='Greenfield Land Partners', Status='New', Deal_Type__c='Land');
Lead commLead = new Lead(FirstName='Demo', LastName='Commercial Deal', Company='Metro Commercial Group', Status='New', Deal_Type__c='Commercial');
insert new List<Lead>{ landLead, commLead };

Database.LeadConvert lc1 = new Database.LeadConvert();
lc1.setLeadId(landLead.Id); lc1.setConvertedStatus(convertedStatus);
Database.LeadConvert lc2 = new Database.LeadConvert();
lc2.setLeadId(commLead.Id); lc2.setConvertedStatus(convertedStatus);

List<Database.LeadConvertResult> results = Database.convertLead(new List<Database.LeadConvert>{ lc1, lc2 });

Set<Id> oppIds = new Set<Id>();
for (Database.LeadConvertResult r : results) { oppIds.add(r.getOpportunityId()); }

for (Opportunity o : [SELECT Id, Name, Deal_Type__c, RecordType.DeveloperName, StageName FROM Opportunity WHERE Id IN :oppIds ORDER BY Deal_Type__c]) {
    System.debug('OPP :: ' + o.Deal_Type__c + ' | RecordType=' + o.RecordType.DeveloperName + ' | Stage=' + o.StageName + ' | Id=' + o.Id);
}
