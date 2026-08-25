// ─────────────────────────────────────────────────────────────────────────────
// Reset the GREEN band of the Sell Meter (2026-08-25).
//
// GREEN = Peak_Sell_Date__c within 30 days (SellMeterService.bandForPeak). On the
// day this ran, five assets were GREEN, every one carrying a Disposition:
//   Copperfield Town Center   DISP-0011 (Sale Closes)
//   Bandera Crossing Center   DISP-0019 (Offer Selection)
//   Schertz Gateway Plaza     DISP-0022 (BOV Outreach)
//   Live Oak Commerce Park    DISP-0023 (LOI)
//   Universal City Retail Row DISP-0020 (Readiness, PENDING Sale Decision approval)
//
// Every child lookup to Disposition__c and Property_Asset__c is SetNull, so a bare
// delete of the assets would leave the dispositions and ~35 child rows orphaned and
// still visible in the Disposition app. This script removes the whole subtree.
// PSA_Version__c -> Contract_Review__c is RESTRICT, so it goes first. A record under
// a pending approval cannot be deleted, so that approval is recalled first.
//
// Then two fresh GREEN assets are created (Property__c parent + Property_Asset__c),
// shaped exactly like Bandera was: Stone Oak Village Center (testing) and
// Alamo Ranch Marketplace (demo).
// ─────────────────────────────────────────────────────────────────────────────

Set<Id> assetIds = new Set<Id>{
    'a0Niw000004KE4XEAW', // Copperfield Town Center
    'a0Niw0000057nU9EAI', // Bandera Crossing Center
    'a0Niw000005Tn45EAC', // Schertz Gateway Plaza
    'a0Niw000005ULCDEA4', // Live Oak Commerce Park
    'a0Niw000004KHC5EAO'  // Universal City Retail Row
};

List<Property_Asset__c> assets = [SELECT Id, Name FROM Property_Asset__c WHERE Id IN :assetIds];
List<Disposition__c> disps = [SELECT Id, Name FROM Disposition__c WHERE Property_Asset__c IN :assetIds];
Set<Id> dispIds = new Map<Id, Disposition__c>(disps).keySet();
System.debug(LoggingLevel.ERROR, 'Assets: ' + assets.size() + ' | Dispositions: ' + disps);

// 1. Recall pending approvals on the dispositions and on their approval-bearing children.
Set<Id> approvalTargets = new Set<Id>(dispIds);
for (BOV_Submission__c b : [SELECT Id FROM BOV_Submission__c WHERE Disposition__c IN :dispIds]) approvalTargets.add(b.Id);
for (Disposition_Offer__c o : [SELECT Id FROM Disposition_Offer__c WHERE Disposition__c IN :dispIds]) approvalTargets.add(o.Id);
for (LOI__c l : [SELECT Id FROM LOI__c WHERE Disposition__c IN :dispIds]) approvalTargets.add(l.Id);
for (Contract_Review__c c : [SELECT Id FROM Contract_Review__c WHERE Disposition__c IN :dispIds]) approvalTargets.add(c.Id);

List<Approval.ProcessWorkitemRequest> recalls = new List<Approval.ProcessWorkitemRequest>();
for (ProcessInstanceWorkitem w : [
    SELECT Id, ProcessInstance.TargetObjectId
    FROM ProcessInstanceWorkitem
    WHERE ProcessInstance.Status = 'Pending' AND ProcessInstance.TargetObjectId IN :approvalTargets
]) {
    Approval.ProcessWorkitemRequest r = new Approval.ProcessWorkitemRequest();
    r.setWorkitemId(w.Id);
    r.setAction('Removed');
    r.setComments('Recalled by sell-meter reset script');
    recalls.add(r);
}
if (!recalls.isEmpty()) {
    for (Approval.ProcessResult pr : Approval.process(recalls, false)) {
        System.debug(LoggingLevel.ERROR, 'Recall: success=' + pr.isSuccess() + ' ' + pr.getErrors());
    }
}

// 2. Capture child rows BEFORE the parents go (all lookups are SetNull).
List<SObject> grandchildren = new List<SObject>();
grandchildren.addAll([SELECT Id FROM PSA_Version__c WHERE Contract_Review__r.Disposition__c IN :dispIds]);
grandchildren.addAll([SELECT Id FROM Counter_Offer__c WHERE LOI__r.Disposition__c IN :dispIds]);
grandchildren.addAll([SELECT Id FROM Deal_Message__c WHERE LOI__r.Disposition__c IN :dispIds OR Contract_Review__r.Disposition__c IN :dispIds]);

List<SObject> children = new List<SObject>();
children.addAll([SELECT Id FROM BOV_Broker_Change__c WHERE Disposition__c IN :dispIds]);
children.addAll([SELECT Id FROM Release_Materials_Response__c WHERE Disposition__c IN :dispIds]);
children.addAll([SELECT Id FROM Wire__c WHERE Disposition__c IN :dispIds]);
children.addAll([SELECT Id FROM Contract_Review__c WHERE Disposition__c IN :dispIds]);
children.addAll([SELECT Id FROM LOI__c WHERE Disposition__c IN :dispIds]);
children.addAll([SELECT Id FROM Disposition_Offer__c WHERE Disposition__c IN :dispIds]);
children.addAll([SELECT Id FROM NDA__c WHERE Disposition__c IN :dispIds]);
children.addAll([SELECT Id FROM Broker_Listing__c WHERE Disposition__c IN :dispIds]);
children.addAll([SELECT Id FROM BOV_Submission__c WHERE Disposition__c IN :dispIds]);

List<SObject> assetChildren = new List<SObject>();
assetChildren.addAll([SELECT Id FROM Onboarding__c WHERE Property_Asset__c IN :assetIds]);
assetChildren.addAll([SELECT Id FROM Vendor_Contract__c WHERE Property_Asset__c IN :assetIds]);

System.debug(LoggingLevel.ERROR, 'To delete — grandchildren ' + grandchildren.size()
    + ', disposition children ' + children.size() + ', asset children ' + assetChildren.size());

// 3. Delete bottom-up. Dispositions go before their children so no child-side
//    trigger (BOV auto-selection, offer advance) writes to a parent mid-teardown.
delete grandchildren;
delete disps;
delete children;
delete assetChildren;
delete assets;
System.debug(LoggingLevel.ERROR, 'Teardown complete.');

// 4. Create two fresh GREEN assets, Bandera-shaped.
List<Property__c> props = new List<Property__c>{
    new Property__c(Name = 'Stone Oak Village Center', City__c = 'San Antonio', State__c = 'TX'),
    new Property__c(Name = 'Alamo Ranch Marketplace',  City__c = 'San Antonio', State__c = 'TX')
};
insert props;

List<Property_Asset__c> newAssets = new List<Property_Asset__c>{
    new Property_Asset__c(  // ── for testing ──
        Name = 'Stone Oak Village Center',
        Property__c = props[0].Id, Property_Type__c = 'Retail', Status__c = 'Active',
        Argus_Signal__c = 'Sell Now', Argus_Value__c = 19800000,
        NOI__c = 1287000, Market_Cap_Rate__c = 6.5,
        Target_Sale_Price__c = 19800000, Projected_Value_At_Peak__c = 20400000,
        Peak_Sell_Date__c = Date.today().addDays(8),
        Sell_Readiness_Score__c = 92,
        Closing_Date__c = Date.today().addDays(-30)
    ),
    new Property_Asset__c(  // ── for demo ──
        Name = 'Alamo Ranch Marketplace',
        Property__c = props[1].Id, Property_Type__c = 'Retail', Status__c = 'Active',
        Argus_Signal__c = 'Sell Now', Argus_Value__c = 24600000,
        NOI__c = 1599000, Market_Cap_Rate__c = 6.5,
        Target_Sale_Price__c = 24600000, Projected_Value_At_Peak__c = 25300000,
        Peak_Sell_Date__c = Date.today().addDays(12),
        Sell_Readiness_Score__c = 94,
        Closing_Date__c = Date.today().addDays(-45)
    )
};
insert newAssets;
for (Property_Asset__c a : newAssets) {
    System.debug(LoggingLevel.ERROR, 'Created ' + a.Name + ' ' + a.Id + ' peak ' + a.Peak_Sell_Date__c);
}
