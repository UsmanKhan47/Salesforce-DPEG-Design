// Copy underwriting values from each Opportunity's Primary Underwriting record
// into the new editable Opportunity underwriting fields, so the Underwriting tab
// shows data instead of blanks.
List<Opportunity> opps = [
    SELECT Id,
        Primary_Underwriting__r.Underwritten_NOI__c,
        Primary_Underwriting__r.Target_Return__c,
        Primary_Underwriting__r.Hold_Period__c,
        Primary_Underwriting__r.Equity_Required__c,
        Primary_Underwriting__r.Projected_Loan__c,
        Primary_Underwriting__r.Underwriting_OneDrive_URL__c,
        Primary_Underwriting__r.GRM__c,
        Primary_Underwriting__r.Principal_Price_Decision__c,
        Primary_Underwriting__r.Cash_on_Cash_Return__c,
        Primary_Underwriting__r.Equity_Multiple__c
    FROM Opportunity
    WHERE Primary_Underwriting__c != null
];
for (Opportunity o : opps) {
    Underwriting__c uw = o.Primary_Underwriting__r;
    o.Underwritten_NOI__c = uw.Underwritten_NOI__c;
    o.Target_Return__c = uw.Target_Return__c;
    o.Hold_Period__c = uw.Hold_Period__c;
    o.Equity_Required__c = uw.Equity_Required__c;
    o.Projected_Loan__c = uw.Projected_Loan__c;
    o.Underwriting_OneDrive_URL__c = uw.Underwriting_OneDrive_URL__c;
    o.GRM__c = uw.GRM__c;
    // 🔴 REMOVED 2026-09-02, AND DELIBERATELY NOT REPOINTED ONTO Stage__c. This line used to read:
    //     if (uw.Status__c != null) { o.Underwriting_Status__c = uw.Status__c; }
    // It was the ONLY place in the codebase that copied the CHILD's coarse status into the PARENT
    // mirror. The child field Underwriting__c.Status__c is retired; the parent field
    // Opportunity.Underwriting_Status__c is KEPT and is not redundant.
    //
    // Two independent reasons not to substitute `uw.Stage__c` here:
    //
    //  1. THE VALUE SETS DO NOT MATCH AND THE TARGET IS RESTRICTED. Stage__c is
    //     {Requested, In Progress, Approved, Completed}; Opportunity.Underwriting_Status__c is
    //     {In Progress, Complete, Approved by Principals} with <restricted>true</restricted>.
    //     'Requested' and 'Completed' are on neither list, so a naive copy throws
    //     INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST on the bulk `update opps` below and backfills
    //     NOTHING. A correct copy would need an explicit map: Approved -> 'Approved by Principals',
    //     Completed -> 'Complete', In Progress -> 'In Progress', Requested -> leave null.
    //
    //  2. 🔴 EVEN A CORRECT MAP SHOULD NOT RUN FROM HERE. Writing Underwriting_Status__c is not an
    //     inert data copy: flows/Opportunity_UW_Approved_Notify has
    //     doesRequireRecordChangedToMeetCriteria = true and fires on the TRANSITION into
    //     'Approved by Principals', which is the SOLE trigger of the market-data freeze
    //     (MarketDataSnapshotService). A backfill sweeping every deal would fire that freeze en
    //     masse and overwrite Market_Data_Snapshot__c / Market_Data_As_Of_Date__c across the org
    //     with today's data. TestDataFactory refuses to write this field in fixtures for exactly
    //     this reason. The field's only legitimate writer is UnderwritingApprovalStampService,
    //     driven by a real approval.
    //
    // If a genuine parent-status backfill is ever needed, it is its own script with its own
    // decision about the freeze — not a line inside a numeric-field copy.
    o.Principal_Price_Decision__c = uw.Principal_Price_Decision__c;
    o.Cash_on_Cash_Return__c = uw.Cash_on_Cash_Return__c;
    o.Equity_Multiple__c = uw.Equity_Multiple__c;
}
update opps;
System.debug('Backfilled underwriting on ' + opps.size() + ' opportunities');
