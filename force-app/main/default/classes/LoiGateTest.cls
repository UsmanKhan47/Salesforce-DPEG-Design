/**
 * Tests the Phase-4 LOI gates: the Acquisitions prep-approval validation rule +
 * stamp flow, and the two-principal unanimous LOI_Approval process with the
 * ApprovalAuditService audit trail stamped onto the primary LOI.
 */
@isTest
private class LoiGateTest {

    private static Opportunity newOpp(String stage) {
        return new Opportunity(
            Name = 'LOI Gate Test',
            StageName = stage,
            CloseDate = Date.today().addDays(30)
        );
    }

    @isTest
    static void prepApprovalGatesLoiUnderApproval() {
        Opportunity o = newOpp('Initiate LOI');
        insert o;

        Boolean blocked = false;
        try {
            o.StageName = 'LOI Under Approval';
            update o;
        } catch (DmlException e) {
            blocked = true;
        }
        System.assert(blocked, 'Moving to LOI Under Approval without Acquisitions prep approval must be blocked');

        Test.startTest();
        o.LOI_Prep_Approved__c = true;
        o.StageName = 'LOI Under Approval';
        update o;
        Test.stopTest();

        o = [SELECT StageName, LOI_Prep_Approved_By__c, LOI_Prep_Approval_Date__c
             FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('LOI Under Approval', o.StageName, 'Prep approval unlocks the stage');
        System.assertEquals(UserInfo.getUserId(), o.LOI_Prep_Approved_By__c, 'Prep approver auto-stamped');
        System.assertNotEquals(null, o.LOI_Prep_Approval_Date__c, 'Prep approval date auto-stamped');
    }

    @isTest
    static void unanimousApprovalStampsLoiAuditTrail() {
        Opportunity o = newOpp('LOI Under Approval');
        insert o;
        LOI__c loi = new LOI__c(Opportunity__c = o.Id, Offer_Price__c = 9000000,
            LOI_Status__c = 'Pending Approval');
        insert loi;
        o.Primary_LOI__c = loi.Id;
        update o;

        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(o.Id);
        Approval.ProcessResult submitted = Approval.process(req);
        System.assert(submitted.isSuccess(), 'Deal at LOI Under Approval should enter LOI_Approval');

        Test.startTest();
        // Unanimous step: both principals must approve; the admin acts on every
        // pending workitem (Modify All Data can process any approval request).
        for (ProcessInstanceWorkitem wi : [
            SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :o.Id
        ]) {
            Approval.ProcessWorkitemRequest wr = new Approval.ProcessWorkitemRequest();
            wr.setWorkitemId(wi.Id);
            wr.setAction('Approve');
            wr.setComments('Terms cleared.');
            Approval.process(wr);
        }
        Test.stopTest();

        o = [SELECT StageName FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('LOI Submitted', o.StageName, 'Unanimous approval advances to LOI Submitted');

        loi = [SELECT LOI_Status__c, Approved_By__c, Approved_Date__c, Approval_Comments__c
               FROM LOI__c WHERE Id = :loi.Id];
        System.assertEquals('Approved', loi.LOI_Status__c, 'LOI status stamped by the audit service');
        System.assertEquals(UserInfo.getUserId(), loi.Approved_By__c, 'Final approver stamped from history');
        System.assertEquals(Date.today(), loi.Approved_Date__c, 'Approval date stamped');
        System.assertEquals('Terms cleared.', loi.Approval_Comments__c, 'Approver comments preserved (audit trail)');
    }

    @isTest
    static void rejectionReturnsDealToUnderwriting() {
        Opportunity o = newOpp('LOI Under Approval');
        insert o;

        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(o.Id);
        Approval.process(req);

        Test.startTest();
        ProcessInstanceWorkitem wi = [
            SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :o.Id LIMIT 1
        ];
        Approval.ProcessWorkitemRequest wr = new Approval.ProcessWorkitemRequest();
        wr.setWorkitemId(wi.Id);
        wr.setAction('Reject');
        wr.setComments('Rework the terms.');
        Approval.process(wr);
        Test.stopTest();

        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Rejection returns the deal to Underwriting');
    }
}
