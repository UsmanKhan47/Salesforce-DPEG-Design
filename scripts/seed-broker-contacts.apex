// Seed broker Contacts for the Acquisition Broker Hub.
// Brokers are standard Contacts flagged with Is_Broker__c = true.
// Re-runnable: clears existing broker contacts first.
delete [SELECT Id FROM Contact WHERE Is_Broker__c = true];

List<Contact> brokers = new List<Contact>{
    new Contact(FirstName='Dana',   LastName='Pierce',    Is_Broker__c=true, Broker_Firm__c='CBRE',                 Broker_Specialty__c='Retail',      Broker_Status__c='Active',   Active_Listings__c=12, Offers_Received__c=18, Closed_Volume__c=48000000, Avg_Days_On_Market__c=88),
    new Contact(FirstName='Marcus', LastName='Whitfield', Is_Broker__c=true, Broker_Firm__c='Marcus & Millichap',   Broker_Specialty__c='Retail',      Broker_Status__c='Active',   Active_Listings__c=9,  Offers_Received__c=14, Closed_Volume__c=36000000, Avg_Days_On_Market__c=95),
    new Contact(FirstName='Priya',  LastName='Nair',      Is_Broker__c=true, Broker_Firm__c='JLL',                  Broker_Specialty__c='Office',      Broker_Status__c='Active',   Active_Listings__c=8,  Offers_Received__c=11, Closed_Volume__c=41000000, Avg_Days_On_Market__c=102),
    new Contact(FirstName='Carlos', LastName='Alvarez',   Is_Broker__c=true, Broker_Firm__c='Newmark',              Broker_Specialty__c='Industrial',  Broker_Status__c='Active',   Active_Listings__c=7,  Offers_Received__c=9,  Closed_Volume__c=33000000, Avg_Days_On_Market__c=70),
    new Contact(FirstName='Sofia',  LastName='Marchetti', Is_Broker__c=true, Broker_Firm__c='Cushman & Wakefield',  Broker_Specialty__c='Multifamily', Broker_Status__c='Active',   Active_Listings__c=6,  Offers_Received__c=8,  Closed_Volume__c=52000000, Avg_Days_On_Market__c=65),
    new Contact(FirstName='Ethan',  LastName='Brooks',    Is_Broker__c=true, Broker_Firm__c='Colliers',             Broker_Specialty__c='Office',      Broker_Status__c='Active',   Active_Listings__c=5,  Offers_Received__c=6,  Closed_Volume__c=22000000, Avg_Days_On_Market__c=120),
    new Contact(FirstName='Hannah', LastName='Cole',      Is_Broker__c=true, Broker_Firm__c='Eastdil Secured',      Broker_Specialty__c='Mixed-Use',   Broker_Status__c='Active',   Active_Listings__c=4,  Offers_Received__c=5,  Closed_Volume__c=60000000, Avg_Days_On_Market__c=58),
    new Contact(FirstName='Liam',   LastName='O\'Donnell', Is_Broker__c=true, Broker_Firm__c='Berkadia',            Broker_Specialty__c='Multifamily', Broker_Status__c='Active',   Active_Listings__c=3,  Offers_Received__c=4,  Closed_Volume__c=28000000, Avg_Days_On_Market__c=75),
    new Contact(FirstName='Grace',  LastName='Sullivan',  Is_Broker__c=true, Broker_Firm__c='Walker & Dunlop',      Broker_Specialty__c='Industrial',  Broker_Status__c='Active',   Active_Listings__c=3,  Offers_Received__c=3,  Closed_Volume__c=19000000, Avg_Days_On_Market__c=84),
    new Contact(FirstName='Noah',   LastName='Bennett',   Is_Broker__c=true, Broker_Firm__c='Lee & Associates',     Broker_Specialty__c='Land',        Broker_Status__c='Active',   Active_Listings__c=2,  Offers_Received__c=2,  Closed_Volume__c=9000000,  Avg_Days_On_Market__c=140),
    new Contact(FirstName='Olivia', LastName='Reyes',     Is_Broker__c=true, Broker_Firm__c='Avison Young',         Broker_Specialty__c='Retail',      Broker_Status__c='Active',   Active_Listings__c=2,  Offers_Received__c=1,  Closed_Volume__c=12000000, Avg_Days_On_Market__c=110),
    new Contact(FirstName='Walter', LastName='Kim',       Is_Broker__c=true, Broker_Firm__c='Northmarq',            Broker_Specialty__c='Office',      Broker_Status__c='Inactive', Active_Listings__c=0,  Offers_Received__c=0,  Closed_Volume__c=0,        Avg_Days_On_Market__c=0)
};
insert brokers;
System.debug('Seeded ' + brokers.size() + ' broker Contacts.');
