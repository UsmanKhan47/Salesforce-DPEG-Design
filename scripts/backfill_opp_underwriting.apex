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
        Primary_Underwriting__r.Status__c,
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
    if (uw.Status__c != null) { o.Underwriting_Status__c = uw.Status__c; }
    o.Principal_Price_Decision__c = uw.Principal_Price_Decision__c;
    o.Cash_on_Cash_Return__c = uw.Cash_on_Cash_Return__c;
    o.Equity_Multiple__c = uw.Equity_Multiple__c;
}
update opps;
System.debug('Backfilled underwriting on ' + opps.size() + ' opportunities');
