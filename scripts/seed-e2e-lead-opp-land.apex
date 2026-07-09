/**
 * Seeds a second end-to-end deal: one Lead converted into a LAND Opportunity
 * (Development Review branch), companion to the Commercial Maple Grove seed.
 * Idempotent - clears any prior run (by Company marker) before re-creating.
 */
final String MARKER = 'Prairie Ridge Land Assemblage';

// ---------- 1. Clean up any prior seed ----------
List<Lead> prior = [
    SELECT Id, ConvertedOpportunityId, ConvertedAccountId, ConvertedContactId
    FROM Lead WHERE Company = :MARKER
];
Set<Id> oppIds = new Set<Id>();
Set<Id> acctIds = new Set<Id>();
Set<Id> contactIds = new Set<Id>();
for (Lead l : prior) {
    if (l.ConvertedOpportunityId != null) { oppIds.add(l.ConvertedOpportunityId); }
    if (l.ConvertedAccountId != null) { acctIds.add(l.ConvertedAccountId); }
    if (l.ConvertedContactId != null) { contactIds.add(l.ConvertedContactId); }
}
if (!oppIds.isEmpty()) {
    Set<Id> propIds = new Set<Id>();
    for (Opportunity o : [SELECT Property__c FROM Opportunity WHERE Id IN :oppIds AND Property__c != null]) {
        propIds.add(o.Property__c);
    }
    delete [SELECT Id FROM Counter_Offer__c WHERE LOI__r.Opportunity__c IN :oppIds];
    delete [SELECT Id FROM PSA_Version__c WHERE Contract_Review__r.Opportunity__c IN :oppIds];
    delete [SELECT Id FROM Deal_Message__c
            WHERE LOI__r.Opportunity__c IN :oppIds
               OR Underwriting__r.Opportunity__c IN :oppIds
               OR Contract_Review__r.Opportunity__c IN :oppIds];
    delete [SELECT Id FROM LOI__c WHERE Opportunity__c IN :oppIds];
    delete [SELECT Id FROM Underwriting__c WHERE Opportunity__c IN :oppIds];
    delete [SELECT Id FROM Contract_Review__c WHERE Opportunity__c IN :oppIds];
    delete [SELECT Id FROM Development_Feasibility_Review__c WHERE Opportunity__c IN :oppIds];
    delete [SELECT Id FROM Construction_Feasibility_Review__c WHERE Opportunity__c IN :oppIds];
    delete [SELECT Id FROM NDA__c WHERE Opportunity__c IN :oppIds];
    delete [SELECT Id FROM Opportunity WHERE Id IN :oppIds];
    if (!propIds.isEmpty()) { delete [SELECT Id FROM Property__c WHERE Id IN :propIds]; }
}
if (!prior.isEmpty()) { delete prior; }
if (!contactIds.isEmpty()) { delete [SELECT Id FROM Contact WHERE Id IN :contactIds]; }
if (!acctIds.isEmpty()) { delete [SELECT Id FROM Account WHERE Id IN :acctIds]; }

// ---------- 2. Create the Lead ----------
Lead ld = new Lead(
    FirstName = 'Dana',
    LastName = 'Whitfield',
    Company = MARKER,
    Title = 'Land Broker',
    Email = 'dana.whitfield@example.com',
    Phone = '512-555-0188',
    Status = 'New',
    Deal_Type__c = 'Land',
    Asset_Type__c = 'Land',
    Guidance_Price__c = 8600000,
    Guidance_Cap_Rate__c = 0,
    Property_Address__c = '9100 Prairie Ridge Rd',
    Street = '9100 Prairie Ridge Rd',
    City = 'Buda',
    State = 'TX',
    PostalCode = '78610'
);
insert ld;

// ---------- 3. Convert it ----------
Database.LeadConvert lc = new Database.LeadConvert();
lc.setLeadId(ld.Id);
lc.setOpportunityName(MARKER);
lc.setConvertedStatus([SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel);
Database.LeadConvertResult lcr = Database.convertLead(lc);
System.assert(lcr.isSuccess(), 'Lead conversion failed');

// ---------- 4. Guarantee a clean New-stage start + report ----------
Id oppId = lcr.getOpportunityId();
Opportunity opp = [
    SELECT Id, Name, StageName, RecordType.Name, Deal_Type__c, Property__r.Name, Primary_NDA__c
    FROM Opportunity WHERE Id = :oppId
];
if (opp.StageName != 'New') {
    update new Opportunity(Id = oppId, StageName = 'New');
    opp.StageName = 'New';
}

System.debug('================ SEEDED DEAL (LAND) ================');
System.debug('Opportunity : ' + opp.Name + '  (' + opp.Id + ')');
System.debug('Stage       : ' + opp.StageName);
System.debug('Record Type : ' + opp.RecordType.Name + '   Deal Type: ' + opp.Deal_Type__c);
System.debug('Property    : ' + opp.Property__r.Name);
System.debug('Primary NDA : ' + opp.Primary_NDA__c);
System.debug('Lead        : ' + ld.Id + '  (converted)');
System.debug('====================================================');
