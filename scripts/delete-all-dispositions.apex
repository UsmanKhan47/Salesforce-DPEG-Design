// Deletes EVERY Disposition__c in the org with its whole subtree (all child lookups are
// SetNull, so a bare delete would orphan the children), after recalling any pending
// approvals on the dispositions or their approval-bearing children. Then removes the
// duplicate Stone Oak / Alamo Ranch asset pair created by the 2026-08-25 double run.
// Written 2026-08-25 so the user can re-initiate from a clean Sell Meter.

List<Disposition__c> disps = [SELECT Id, Name FROM Disposition__c];
Set<Id> dispIds = new Map<Id, Disposition__c>(disps).keySet();
System.debug(LoggingLevel.ERROR, 'Dispositions to delete: ' + disps);

// 1. Recall pending approvals.
Set<Id> approvalTargets = new Set<Id>(dispIds);
for (BOV_Submission__c b : [SELECT Id FROM BOV_Submission__c WHERE Disposition__c IN :dispIds]) approvalTargets.add(b.Id);
for (Disposition_Offer__c o : [SELECT Id FROM Disposition_Offer__c WHERE Disposition__c IN :dispIds]) approvalTargets.add(o.Id);
for (LOI__c l : [SELECT Id FROM LOI__c WHERE Disposition__c IN :dispIds]) approvalTargets.add(l.Id);
for (Contract_Review__c c : [SELECT Id FROM Contract_Review__c WHERE Disposition__c IN :dispIds]) approvalTargets.add(c.Id);

List<Approval.ProcessWorkitemRequest> recalls = new List<Approval.ProcessWorkitemRequest>();
for (ProcessInstanceWorkitem w : [
    SELECT Id FROM ProcessInstanceWorkitem
    WHERE ProcessInstance.Status = 'Pending' AND ProcessInstance.TargetObjectId IN :approvalTargets
]) {
    Approval.ProcessWorkitemRequest r = new Approval.ProcessWorkitemRequest();
    r.setWorkitemId(w.Id);
    r.setAction('Removed');
    r.setComments('Recalled by delete-all-dispositions script');
    recalls.add(r);
}
if (!recalls.isEmpty()) {
    for (Approval.ProcessResult pr : Approval.process(recalls, false)) {
        System.debug(LoggingLevel.ERROR, 'Recall: success=' + pr.isSuccess() + ' ' + pr.getErrors());
    }
}

// 2. Capture children before the parents go.
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

// 3. Delete: dispositions first so no child-side trigger writes to a parent mid-teardown.
delete grandchildren;
delete disps;
delete children;
System.debug(LoggingLevel.ERROR, 'Deleted ' + disps.size() + ' dispositions, '
    + children.size() + ' children, ' + grandchildren.size() + ' grandchildren.');

// 4. Remove the duplicate (07:54) asset pair — keep the 07:44 pair.
Set<Id> dupAssets = new Set<Id>{ 'a0Niw000005c3LNEAY', 'a0Niw000005c3LOEAY' };
Set<Id> dupProps  = new Set<Id>{ 'a0Oiw000000TAC5EAO', 'a0Oiw000000TAC6EAO' };
delete [SELECT Id FROM Onboarding__c WHERE Property_Asset__c IN :dupAssets];
delete [SELECT Id FROM Property_Asset__c WHERE Id IN :dupAssets];
delete [SELECT Id FROM Property__c WHERE Id IN :dupProps];

System.debug(LoggingLevel.ERROR, 'Done. Dispositions left: ' + [SELECT COUNT() FROM Disposition__c]
    + ' | assets: ' + [SELECT Id, Name FROM Property_Asset__c WHERE Name IN ('Stone Oak Village Center','Alamo Ranch Marketplace')]);
