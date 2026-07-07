/**
 * Tests the Phase-3 underwriting gate: the NDA-signed validation rule, the
 * Initiate Underwriting checkbox flow, and the Underwriting_Approval process
 * (approve -> Initiate LOI + audit stamps; reject -> Dead/Pass + Dead category).
 */
@isTest
private class UnderwritingGateTest {

    private static Opportunity newOpp(String stage) {
        return new Opportunity(
            Name = 'Gate Test',
            StageName = stage,
            CloseDate = Date.today().addDays(30)
        );
    }

    private static void linkSignedNda(Opportunity o) {
        NDA__c nda = new NDA__c(
            Opportunity__c = o.Id, Status__c = 'Signed', NDA_Signed__c = true,
            Counterparty_Name__c = 'Seller LLC'
        );
        insert nda;
        o.Primary_NDA__c = nda.Id;
    }

    @isTest
    static void ndaGateBlocksUnderwritingEntry() {
        Opportunity o = newOpp('Under Review');
        insert o;

        Boolean blocked = false;
        try {
            o.StageName = 'Underwriting';
            update o;
        } catch (DmlException e) {
            blocked = true;
        }
        System.assert(blocked, 'Entering Underwriting without a signed primary NDA must be blocked');

        linkSignedNda(o);
        o.StageName = 'Underwriting';
        update o;
        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Signed NDA unlocks the Underwriting stage');
    }

    @isTest
    static void initiateUnderwritingCheckboxAdvancesStage() {
        Opportunity o = newOpp('Under Review');
        insert o;
        linkSignedNda(o);

        Test.startTest();
        o.Initiate_Underwriting__c = true;
        update o;
        Test.stopTest();

        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Initiate Underwriting checkbox (12B.I) advances the stage');
    }

    @isTest
    static void principalApprovalAdvancesToInitiateLoi() {
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
        insert o;

        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(o.Id);
        Approval.ProcessResult submitted = Approval.process(req);
        System.assert(submitted.isSuccess(), 'Completed underwrite should enter Underwriting_Approval');

        Test.startTest();
        ProcessInstanceWorkitem wi = [
            SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :o.Id LIMIT 1
        ];
        Approval.ProcessWorkitemRequest wr = new Approval.ProcessWorkitemRequest();
        wr.setWorkitemId(wi.Id);
        wr.setAction('Approve');
        wr.setComments('Numbers work.');
        Approval.process(wr);
        Test.stopTest();

        o = [
            SELECT StageName, UW_Approved__c, Underwriting_Status__c,
                   UW_Approved_By__c, UW_Approval_Date__c
            FROM Opportunity WHERE Id = :o.Id
        ];
        System.assertEquals('Initiate LOI', o.StageName, 'Approval advances the deal to Initiate LOI');
        System.assert(o.UW_Approved__c, 'Approved checkbox set by the final-approval action');
        System.assertEquals('Approved by Principals', o.Underwriting_Status__c, 'Status stamped');
        System.assertEquals(UserInfo.getUserId(), o.UW_Approved_By__c,
            'ApprovalAuditService stamps the actual approver from approval history');
        System.assertNotEquals(null, o.UW_Approval_Date__c, 'Approval date stamped');
    }

    @isTest
    static void principalRejectionKillsDeal() {
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
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
        wr.setComments('Cap rate too thin.');
        Approval.process(wr);
        Test.stopTest();

        o = [SELECT StageName, Deal_Category__c, Deal_Bucket__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('Dead/Pass', o.StageName, 'Rejection sends the deal to Dead/Pass');
        System.assertEquals('Dead', o.Deal_Category__c, 'Rejection marks the deal category Dead');
        System.assertEquals('Dead', o.Deal_Bucket__c, 'Dead deals leave the active tracker buckets');
    }

    @isTest
    static void incompleteUnderwriteCannotSubmit() {
        Opportunity o = newOpp('Underwriting');
        insert o; // Underwriting_Complete__c = false

        Boolean threw = false;
        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(o.Id);
            Approval.process(req);
        } catch (Exception e) {
            threw = true;
        }
        System.assert(threw, 'Section 12B: an incomplete underwrite meets no entry criteria');
    }
}
