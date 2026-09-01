// Creates ONE Disposition__c on the On_Market record type, following the field shape
// TestDataFactory.createDispositions uses for a real (non-test) row: RecordTypeId stamped
// explicitly (never left to inherit the running user's profile default - see
// TestDataFactory.cls:2624-2634), Disposition_Stage__c left at its default 'Disposition
// Readiness' (the only stage a brand-new row is allowed to start at -
// Wire_Complete_Before_Sale_Closes and All_NDAs_Signed_Before_Progression both block anything
// past that on insert).

Id onMarketRtId = Schema.SObjectType.Disposition__c.getRecordTypeInfosByDeveloperName()
    .get('On_Market').getRecordTypeId();

Property_Asset__c target = [
    SELECT Id, Property_Name__c
    FROM Property_Asset__c
    WHERE Property_Name__c = 'Sunset Mixed-Use'
    LIMIT 1
];

Disposition__c disp = new Disposition__c(
    RecordTypeId = onMarketRtId,
    Property_Asset__c = target.Id,
    Disposition_Stage__c = 'Disposition Readiness',
    Listing_Date__c = Date.today(),
    Submission_Deadline__c = Date.today().addDays(30),
    Closing_Date__c = Date.today().addDays(90),
    Brokers_Contacted__c = 0,
    // ⚠ `Responses_Received__c` IS TRIGGER-OWNED SINCE 2026-08-31 (Tranche 1 item 7) —
    // `DispositionCounterRollupService` recomputes it from the live `BOV_Submission__c` count. This
    // script creates NO BOV rows, so nothing ever fires the recompute and this 0 stands. It is kept
    // because a null and a 0 are different on a counter field, and this script's whole point is to
    // produce a row shaped exactly like `TestDataFactory.createDispositions` does.
    // 🔴 THE MOMENT THIS SCRIPT GAINS A BOV INSERT, THIS LITERAL STOPS BEING THE ANSWER.
    Responses_Received__c = 0,
    Gross_Sale_Proceeds__c = 1250000,
    Selling_Costs__c = 62500,
    Title_Company__c = 'Test Title Co',
    PSA_Executed__c = false,
    Closing_Statement_Uploaded__c = false
);
insert disp;

System.debug(LoggingLevel.ERROR, 'Created On_Market Disposition ' + disp.Id
    + ' on property ' + target.Property_Name__c + ' (' + target.Id + ')');
