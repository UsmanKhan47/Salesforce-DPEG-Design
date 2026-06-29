Disposition__c disp = [SELECT Id FROM Disposition__c WHERE Name = 'DISP-0002' LIMIT 1];

// Update outreach summary fields
disp.Package_Sent__c         = Date.newInstance(2026, 5, 15);
disp.Submission_Deadline__c  = Date.newInstance(2026, 5, 30);
disp.Responses_Received__c   = 4;
disp.Brokers_Contacted__c    = 7;
disp.Selected_Broker__c      = 'Marcus & Millichap · Dana Pierce';
update disp;

// Remove existing BOV submissions for this disposition
delete [SELECT Id FROM BOV_Submission__c WHERE Disposition__c = :disp.Id];

// BOV Submissions
insert new List<BOV_Submission__c>{
    new BOV_Submission__c(
        Disposition__c = disp.Id, Broker_Firm__c = 'Marcus & Millichap', Contact_Name__c = 'Dana Pierce',
        BOV_Amount__c = 31200000, Commission_Rate__c = 2.8, Days_To_Market__c = 42,
        Hist_Success_Rate__c = 88, BOV_Score__c = 94, Submission_Status__c = 'Selected'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id, Broker_Firm__c = 'CBRE', Contact_Name__c = 'Michael Torres',
        BOV_Amount__c = 30500000, Commission_Rate__c = 3.0, Days_To_Market__c = 48,
        Hist_Success_Rate__c = 83, BOV_Score__c = 87, Submission_Status__c = 'Backup'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id, Broker_Firm__c = 'JLL', Contact_Name__c = 'Sarah Kim',
        BOV_Amount__c = 29800000, Commission_Rate__c = 2.5, Days_To_Market__c = 55,
        Hist_Success_Rate__c = 79, BOV_Score__c = 81, Submission_Status__c = 'Backup'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id, Broker_Firm__c = 'Cushman & Wakefield', Contact_Name__c = 'James Liu',
        BOV_Amount__c = 28900000, Commission_Rate__c = 3.2, Days_To_Market__c = 60,
        Hist_Success_Rate__c = 72, BOV_Score__c = 74, Submission_Status__c = 'Backup'
    )
};

// Broker Listing
delete [SELECT Id FROM Broker_Listing__c WHERE Disposition__c = :disp.Id];
insert new Broker_Listing__c(
    Disposition__c = disp.Id,
    Broker_Firm__c = 'Marcus & Millichap', Contact_Name__c = 'Dana Pierce',
    List_Date__c = Date.newInstance(2026, 6, 1),
    Call_For_Offers_Date__c = Date.newInstance(2026, 7, 14),
    Days_On_Market__c = 7, Listing_Status__c = 'On Track', Offers_Received__c = 0
);

// Wire record for Closing stage
delete [SELECT Id FROM Wire__c WHERE Disposition__c = :disp.Id];
insert new Wire__c(Disposition__c = disp.Id, Verbal_Verification_Completed__c = false);

System.debug('Seed complete for ' + disp.Id);
