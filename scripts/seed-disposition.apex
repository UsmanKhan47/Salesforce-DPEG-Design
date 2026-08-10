// Seed Disposition record + related data for Sienna Town Center
Property_Asset__c sienna = [
    SELECT Id, Name FROM Property_Asset__c WHERE Name = 'Sienna Town Center' LIMIT 1
];

// Remove any existing Disposition for this asset
delete [SELECT Id FROM Disposition__c WHERE Property_Asset__c = :sienna.Id];

// ── On_Market record type (decision D11 / Gate 1 Q1) ────────────────────────────────
// Every Disposition seeded below is stamped On_Market. Leaving RecordTypeId unset lands
// the record on MASTER: no Path, and all ten stage values selectable — precisely the
// state post-deploy gate A2 exists to eliminate, so an unstamped seed would recreate the
// problem the migration fixes.
//
// A DESCRIBE, NOT A QUERY. `[SELECT Id FROM RecordType WHERE ...].Id` throws a
// QueryException when the record type is absent, and in an anonymous-Apex script that
// aborts mid-run and leaves the org half-seeded. The describe returns null instead, which
// is a legitimate answer (§4 record-type metadata not deployed yet, or not available to
// the running user) and the platform default then applies. Same shape as
// DispositionService.onMarketRecordTypeId() and TestDataFactory.dispositionRecordTypeId(),
// so all three agree. Costs no SOQL.
//
// 'BOV Outreach' below is an On_Market-only stage value, so the stamp and the stage agree.
Schema.RecordTypeInfo onMarketInfo =
    Schema.SObjectType.Disposition__c.getRecordTypeInfosByDeveloperName().get('On_Market');
Id onMarketRtId = (onMarketInfo != null && onMarketInfo.isAvailable())
    ? onMarketInfo.getRecordTypeId()
    : null;

// Stage 2 Disposition (BOV Outreach) — shows matrix + outreach panel
Disposition__c disp = new Disposition__c(
    Property_Asset__c = sienna.Id,
    Disposition_Stage__c = 'BOV Outreach',
    Package_Sent__c = Date.newInstance(2026, 5, 1),
    Submission_Deadline__c = Date.newInstance(2026, 5, 16),
    Responses_Received__c = 4,
    Brokers_Contacted__c = 6,
    Selected_Broker__c = 'CBRE · Mark Chen'
);
if (onMarketRtId != null) {
    disp.RecordTypeId = onMarketRtId;
}
insert disp;
System.debug('Created Disposition: ' + disp.Id);

// BOV Submissions
insert new List<BOV_Submission__c>{
    new BOV_Submission__c(
        Disposition__c = disp.Id, Broker_Firm__c = 'CBRE', Contact_Name__c = 'Mark Chen',
        BOV_Amount__c = 28500000, Commission_Rate__c = 3.0, Days_To_Market__c = 45,
        Hist_Success_Rate__c = 82, BOV_Score__c = 91, Submission_Status__c = 'Selected'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id, Broker_Firm__c = 'JLL', Contact_Name__c = 'K. Rao',
        BOV_Amount__c = 27900000, Commission_Rate__c = 2.5, Days_To_Market__c = 52,
        Hist_Success_Rate__c = 78, BOV_Score__c = 84, Submission_Status__c = 'Backup'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id, Broker_Firm__c = 'Newmark', Contact_Name__c = 'T. Black',
        BOV_Amount__c = 26800000, Commission_Rate__c = 2.8, Days_To_Market__c = 60,
        Hist_Success_Rate__c = 71, BOV_Score__c = 73, Submission_Status__c = 'Backup'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id, Broker_Firm__c = 'Cushman', Contact_Name__c = 'S. Rivera',
        BOV_Amount__c = 26200000, Commission_Rate__c = 3.2, Days_To_Market__c = 55,
        Hist_Success_Rate__c = 69, BOV_Score__c = 68, Submission_Status__c = 'Backup'
    )
};

// Broker Listing (Active Listing stage data)
insert new Broker_Listing__c(
    Disposition__c = disp.Id, Broker_Firm__c = 'CBRE', Contact_Name__c = 'Mark Chen',
    List_Date__c = Date.newInstance(2026, 4, 24),
    Call_For_Offers_Date__c = Date.newInstance(2026, 6, 10),
    Days_On_Market__c = 40, Listing_Status__c = 'At Risk', Offers_Received__c = 0
);

// Wire record (Closing stage data)
insert new Wire__c(
    Disposition__c = disp.Id,
    Verbal_Verification_Completed__c = false
);

System.debug('Seed complete. Disposition ID: ' + disp.Id);
