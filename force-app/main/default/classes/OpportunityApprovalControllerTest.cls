/**
 * Tests OpportunityApprovalController: an eligible Opp (Stage = LOI)
 * submits into the LOI approval process, and a second submit is blocked.
 */
@isTest
private class OpportunityApprovalControllerTest {

    private static Opportunity makeOpp() {
        Opportunity o = new Opportunity(
            Name = 'Approval Test',
            StageName = 'LOI',
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
        // A deal at neither Underwriting nor LOI meets no entry criteria ->
        // Approval.process throws -> the catch branch surfaces a friendly error.
        Opportunity o = new Opportunity(
            Name = 'Not Eligible',
            StageName = 'Under Review',
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
    static void submitsFromUnderwritingRecord() {
        Opportunity o = new Opportunity(
            Name = 'UW Child Submit', StageName = 'Underwriting',
            Underwriting_Complete__c = true, CloseDate = Date.today().addDays(10)
        );
        insert o; // stage entry auto-creates the Underwriting record
        Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :o.Id];

        Test.startTest();
        String msg = OpportunityApprovalController.submitForApproval(uw.Id);
        Test.stopTest();

        System.assertNotEquals(null, msg, 'A success message should be returned');
        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id AND Status = 'Pending'],
            'Submitting from the Underwriting record routes the PARENT deal into approval');
    }

    @isTest
    static void submitsFromLoiRecord() {
        Opportunity o = makeOpp(); // Stage = LOI
        LOI__c loi = new LOI__c(Opportunity__c = o.Id, Offer_Price__c = 1000000);
        insert loi;

        Test.startTest();
        OpportunityApprovalController.submitForApproval(loi.Id);
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id AND Status = 'Pending'],
            'Submitting from the LOI record routes the PARENT deal into approval');
    }

    @isTest
    static void unlinkedChildThrows() {
        LOI__c orphan = new LOI__c(Offer_Price__c = 500000);
        insert orphan;

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(orphan.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'An LOI with no parent deal cannot be submitted');
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