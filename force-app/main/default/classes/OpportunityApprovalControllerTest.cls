/**
 * Tests OpportunityApprovalController: an eligible Opp (Stage = LOI Under Approval)
 * submits into the LOI approval process, and a second submit is blocked.
 */
@isTest
private class OpportunityApprovalControllerTest {

    private static Opportunity makeOpp() {
        Opportunity o = new Opportunity(
            Name = 'Approval Test',
            StageName = 'LOI Under Approval',
            CloseDate = Date.today().addDays(10)
        );
        insert o;
        return o;
    }

    @isTest
    static void submitsEligibleOpp() {
        Opportunity o = makeOpp();
        Test.startTest();
        String msg = OpportunityApprovalController.submitForApproval(o.Id);
        Test.stopTest();

        System.assertNotEquals(null, msg, 'A success message should be returned');
        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'A pending approval instance should exist after submit');
    }

    @isTest
    static void secondSubmitThrows() {
        Opportunity o = makeOpp();
        OpportunityApprovalController.submitForApproval(o.Id);

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(o.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Submitting an already-pending deal should throw');
    }

    @isTest
    static void ineligibleStageThrows() {
        // A deal not at "LOI Under Approval" meets no entry criteria -> Approval.process
        // throws -> the catch branch surfaces a friendly error.
        Opportunity o = new Opportunity(
            Name = 'Not Eligible',
            StageName = 'Underwriting',
            CloseDate = Date.today().addDays(10)
        );
        insert o;

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(o.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Submitting a deal that meets no entry criteria should throw');
    }

    @isTest
    static void nullRecordThrows() {
        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(null);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'A null record id should throw');
    }
}