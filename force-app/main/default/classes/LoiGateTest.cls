/**
 * Tests the LOI gate: the two-principal unanimous LOI_Approval process (entered
 * at the single coarse LOI stage) with the ApprovalAuditService audit trail
 * stamped onto the primary LOI. On approval the LOI_Approved__c flag is set (the
 * stage stays at LOI); on rejection the deal returns to Underwriting.
 */
@isTest
private class LoiGateTest {

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        return o;
    }

    @isTest
    static void unanimousApprovalStampsLoiAuditTrail() {
        Opportunity o = newOpp('LOI');
        insert o;
        LOI__c loi = TestDataFactory.createLoi(o.Id, false);
        loi.Offer_Price__c = 9000000;
        loi.LOI_Status__c = 'Pending Approval';
        insert loi;
        o.Primary_LOI__c = loi.Id;
        update o;

        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(o.Id);
        Approval.ProcessResult submitted = Approval.process(req);
        System.assert(submitted.isSuccess(), 'Deal at LOI should enter LOI_Approval');

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

        o = [SELECT StageName, LOI_Approved__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('LOI', o.StageName, 'Stage stays at the coarse LOI stage');
        System.assert(o.LOI_Approved__c, 'Unanimous approval sets the LOI Approved flag');

        loi = [SELECT LOI_Status__c, Approved_By__c, Approved_Date__c, Approval_Comments__c
               FROM LOI__c WHERE Id = :loi.Id];
        System.assertEquals('Approved', loi.LOI_Status__c, 'LOI status stamped by the audit service');
        System.assertEquals(UserInfo.getUserId(), loi.Approved_By__c, 'Final approver stamped from history');
        System.assertEquals(Date.today(), loi.Approved_Date__c, 'Approval date stamped');
        System.assertEquals('Terms cleared.', loi.Approval_Comments__c, 'Approver comments preserved (audit trail)');
    }

    @isTest
    static void rejectionReturnsDealToUnderwriting() {
        Opportunity o = newOpp('LOI');
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

    /**
     * Pins CARVE-OUT 1 of the No_Backward_Stage_Movement validation rule (code review W2).
     *
     * rejectionReturnsDealToUnderwriting above does NOT actually pin carve-out 1: per this org's
     * own finding (F2, recorded in the rule's XML comment and in
     * agent-output/design-requirements-stage-validations.md), approval-process field updates
     * bypass custom validation rules entirely here, so that test's PRIORVALUE(StageName) = 'LOI'
     * -> StageName = 'Underwriting' transition never actually reaches No_Backward_Stage_Movement's
     * formula at all - the test would keep passing whether or not carve-out 1 existed. Deleting
     * carve-out 1 from the deployed rule would NOT turn that test red.
     *
     * This test drives the identical LOI -> Underwriting transition through a direct `update`
     * (no approval process involved), which is the one path carve-out 1's formula can actually be
     * evaluated against. Without carve-out 1 this is a plain backward move (LOI rank 5 ->
     * Underwriting rank 4) and would be blocked, so this test DOES red if carve-out 1 is removed.
     */
    @isTest
    static void directLoiToUnderwritingUpdate_isAllowedByCarveOut1_notByApproval() {
        Opportunity o = newOpp('LOI');
        insert o; // ISCHANGED(StageName) is false on insert, so every gate is bypassed here.
        TestDataFactory.signPrimaryNda(o); // isolate: Underwriting entry is ALSO NDA-gated

        Test.startTest();
        o.StageName = 'Underwriting';
        update o; // must NOT throw - carve-out 1 exempts exactly this transition, with no
                  // Approval.process(...) call anywhere in this test
        Test.stopTest();

        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Carve-out 1 must let a LOI -> Underwriting move through a plain update, independent of '
            + 'whether approval-process field updates run validation rules in this org');
    }
}
