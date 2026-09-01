// Seed demo data for the NDA Tracker and Underwriting Outputs dashboard tables.
// Three deals matched to the prototype screenshots, each with a broker (Account),
// an NDA (Status), and an Underwriting record (cap rate / IRR / price / target).
// Verdict__c is a formula: "Go" when Year 5 IRR >= Target Return, else "—".
// NOTE: Opportunity CloseDate must fall in the CURRENT quarter or the dashboard
// reports (current-quarter close-date default) won't show them.
Date today = Date.today();

// ⚠ NDA RECORD TYPE / STATUS (fixed 2026-08-29). The NDAs built below set NO RecordTypeId, so
// they land on the running user's DEFAULT NDA__c record type. `Status__c` is a RESTRICTED
// picklist whose allowed subset differs per record type, and that subset IS enforced by Apex DML
// (see the XML comment in objects/NDA__c/recordTypes/Acquisition_NDA.recordType-meta.xml):
//     Acquisition_NDA : Pending, Received, Signed        ('Sent' REMOVED 2026-08-27)
//     Disposition_NDA : Prepare, Approved, Sent, Signed, Declined
// The third deal's 'Sent' was repointed to 'Received', NOT stamped as Disposition_NDA. Reason:
// every NDA here is created WITH an Opportunity__c parent, which is the buy-side/acquisition
// shape by definition, and the second deal's 'Pending' is valid ONLY on Acquisition_NDA — so a
// Disposition_NDA stamp would just move the INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST to that row.
//
// Deal blueprint: { dealName, brokerName, ndaStatus, daysSent, daysSigned,
//                   capRate, year5Irr, price, targetReturn }
List<Map<String, Object>> deals = new List<Map<String, Object>>{
    new Map<String, Object>{
        'deal' => 'Oak Street, Chicago',     'broker' => 'Marcus & Millichap',
        'status' => 'Signed',  'sent' => 5, 'signed' => 3,
        'cap' => 6.8,  'irr' => 19.2, 'price' => 4200000,  'target' => 19
    },
    new Map<String, Object>{
        'deal' => 'Riverside Commons, Dallas', 'broker' => 'CBRE',
        'status' => 'Pending', 'sent' => 2, 'signed' => null,
        'cap' => 5.9,  'irr' => 17.8, 'price' => 7800000,  'target' => 17
    },
    new Map<String, Object>{
        'deal' => 'NW Industrial, Houston',  'broker' => 'JLL',
        'status' => 'Received', 'sent' => 1, 'signed' => null,
        'cap' => 7.1,  'irr' => 21.0, 'price' => 11200000, 'target' => 22
    }
};

// Find-or-create broker Accounts by name.
Set<String> brokerNames = new Set<String>();
for (Map<String, Object> d : deals) brokerNames.add((String) d.get('broker'));

Map<String, Id> brokerByName = new Map<String, Id>();
for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :brokerNames]) {
    brokerByName.put(a.Name, a.Id);
}
List<Account> newBrokers = new List<Account>();
for (String n : brokerNames) {
    if (!brokerByName.containsKey(n)) newBrokers.add(new Account(Name = n));
}
if (!newBrokers.isEmpty()) {
    insert newBrokers;
    for (Account a : newBrokers) brokerByName.put(a.Name, a.Id);
}

// Create the Opportunities (deals).
List<Opportunity> opps = new List<Opportunity>();
for (Map<String, Object> d : deals) {
    opps.add(new Opportunity(
        Name             = (String) d.get('deal'),
        AccountId        = brokerByName.get((String) d.get('broker')),
        StageName        = 'Underwriting',
        CloseDate        = today,
        Asking_Price__c  = (Decimal) d.get('price'),
        My_Price__c      = (Decimal) d.get('price'),
        My_Cap_Rate__c   = (Decimal) d.get('cap'),
        Deal_Status__c   = 'Working',
        Deal_Category__c = 'Live'
    ));
}
insert opps;

// Child NDA + Underwriting records, keyed by deal name.
Map<String, Id> oppByName = new Map<String, Id>();
for (Opportunity o : opps) oppByName.put(o.Name, o.Id);

List<NDA__c> ndas = new List<NDA__c>();
List<Underwriting__c> uws = new List<Underwriting__c>();
for (Map<String, Object> d : deals) {
    Id oppId = oppByName.get((String) d.get('deal'));
    Integer sent   = (Integer) d.get('sent');
    Object  signedObj = d.get('signed');

    ndas.add(new NDA__c(
        Opportunity__c = oppId,
        Status__c      = (String) d.get('status'),
        NDA_Signed__c  = ((String) d.get('status') == 'Signed'),
        Date_Sent__c   = today.addDays(-sent),
        Date_Signed__c = (signedObj == null) ? null : today.addDays(-((Integer) signedObj))
    ));

    uws.add(new Underwriting__c(
        Opportunity__c  = oppId,
        My_Cap_Rate__c  = (Decimal) d.get('cap'),
        Year_5_IRR__c   = (Decimal) d.get('irr'),
        My_Price__c     = (Decimal) d.get('price'),
        Target_Return__c = (Decimal) d.get('target')
    ));
}
insert ndas;
insert uws;

System.debug('Seeded ' + opps.size() + ' deals, ' + ndas.size() + ' NDAs, ' + uws.size() + ' underwriting records.');
