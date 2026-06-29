Property__c pRetail  = new Property__c(Name = 'Sienna Town Center',       Asset_Type__c = 'Retail');
Property__c pCStore  = new Property__c(Name = 'Westheimer C-Stores',       Asset_Type__c = 'C-Store');
Property__c pMF      = new Property__c(Name = 'Heights Apartments',         Asset_Type__c = 'Multifamily');
Property__c pStorage = new Property__c(Name = 'Texas City Self-Storage',    Asset_Type__c = 'Storage');
Property__c pOffice  = new Property__c(Name = 'Beltway Office Park',        Asset_Type__c = 'Office');
insert new List<Property__c>{ pRetail, pCStore, pMF, pStorage, pOffice };

insert new List<Property_Asset__c>{
    new Property_Asset__c(
        Name = 'Sienna Town Center',      Property__c = pRetail.Id,
        NOI__c = 1800000,  Market_Cap_Rate__c = 6.5,  Target_Sale_Price__c = 26900000,
        Argus_Signal__c = 'Sell Now'
    ),
    new Property_Asset__c(
        Name = 'Westheimer C-Stores x9',  Property__c = pCStore.Id,
        NOI__c = 2900000,  Market_Cap_Rate__c = 6.8,  Target_Sale_Price__c = 40000000,
        Argus_Signal__c = 'Sell Now'
    ),
    new Property_Asset__c(
        Name = 'Heights Apartments',       Property__c = pMF.Id,
        NOI__c = 4200000,  Market_Cap_Rate__c = 5.8,  Target_Sale_Price__c = 75000000,
        Argus_Signal__c = '12 mo'
    ),
    new Property_Asset__c(
        Name = 'Texas City Self-Storage',  Property__c = pStorage.Id,
        NOI__c = 980000,   Market_Cap_Rate__c = 7.1,  Target_Sale_Price__c = 16000000,
        Argus_Signal__c = 'Hold'
    ),
    new Property_Asset__c(
        Name = 'Beltway Office Park',      Property__c = pOffice.Id,
        NOI__c = 2000000,  Market_Cap_Rate__c = 9.2,  Target_Sale_Price__c = 24000000,
        Argus_Signal__c = 'Hold'
    )
};
System.debug('Seeded 5 Property__c + 5 Property_Asset__c records.');
