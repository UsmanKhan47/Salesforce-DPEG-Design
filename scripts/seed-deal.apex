// One-off demo seed: a single Acquisition deal with its 1:1 child records,
// values matched to the Underwriting prototype screenshot.
Opportunity opp = new Opportunity(
    Name = 'Magnolia Crossing',
    StageName = 'LOI',            // NOT 'LOI Signed' — that is a Deal_Status__c value, set below
    CloseDate = Date.today().addDays(60),
    Asking_Price__c = 33000000,
    My_Price__c = 31500000,
    My_Cap_Rate__c = 6.5,
    Market_Cap_Rate__c = 6.5,
    Deal_Status__c = 'LOI Signed',
    Asset_Type__c = 'Retail Strip',
    // WS2 (2026-08-30): DateTime now, not Date — a Date literal no longer compiles here.
    Broker_First_Seen__c = Datetime.now().addDays(-38)
);
insert opp;

insert new Underwriting__c(
    Opportunity__c = opp.Id,
    My_Price__c = 31500000,
    My_Cap_Rate__c = 6.5,
    Market_Cap_Rate__c = 6.5,
    Underwritten_NOI__c = 2050000,
    Target_Return__c = 18,
    Hold_Period__c = 5,
    Equity_Required__c = 8400000,
    Projected_Loan__c = 23100000,
    GRM__c = 14.2,
    Underwriting_OneDrive_URL__c = 'https://onedrive.live.com/magnolia-uw-v3'
);

insert new NDA__c(
    Opportunity__c = opp.Id,
    Status__c = 'Signed',
    Method__c = 'DocuSign',
    NDA_Signed__c = true,
    Date_Sent__c = Date.today().addDays(-34),
    Date_Signed__c = Date.today().addDays(-33),
    NDA_Expiry_Date__c = Date.today().addDays(332),
    OneDrive_URL__c = 'https://onedrive.live.com/magnolia-nda'
);

insert new LOI__c(
    Opportunity__c = opp.Id,
    LOI_Status__c = 'Signed',
    Offer_Price__c = 31500000,
    Offer_Cap_Rate__c = 6.5,
    Submitted_Date__c = Date.today().addDays(-20),
    Counter_Price__c = 32250000,
    Counter_Cap_Rate__c = 6.35,
    Counter_Received_Date__c = Date.today().addDays(-15),
    Counter_Response_Due__c = Date.today().addDays(-10),
    LOI_Signed__c = true,
    LOI_Signed_Date__c = Date.today().addDays(-6),
    Approved_Date__c = Date.today().addDays(-8),
    OneDrive_URL__c = 'https://onedrive.live.com/magnolia-loi'
);

System.debug('Seeded deal ' + opp.Id);
