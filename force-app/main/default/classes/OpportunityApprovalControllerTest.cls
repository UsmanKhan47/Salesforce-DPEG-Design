/**
 * Tests OpportunityApprovalController: an eligible Opp (Stage = LOI)
 * submits into the LOI approval process, and a second submit is blocked.
 */
@isTest
private class OpportunityApprovalControllerTest {

    private static Opportunity makeOpp() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
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
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Under Review';
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
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        o.Underwriting_Complete__c = true;
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
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);

        Test.startTest();
        OpportunityApprovalController.submitForApproval(loi.Id);
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id AND Status = 'Pending'],
            'Submitting from the LOI record routes the PARENT deal into approval');
    }

    @isTest
    static void unlinkedChildThrows() {
        LOI__c orphan = TestDataFactory.createLoi(null, false);
        orphan.Offer_Price__c = 500000;
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

    @isTest
    static void resolvesDealFromContractReviewRecord() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'PSA';
        insert o; // stage entry auto-creates a Contract_Review__c
        Contract_Review__c cr = [SELECT Id FROM Contract_Review__c WHERE Opportunity__c = :o.Id LIMIT 1];

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(cr.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        // Proves resolveDealId routes a Contract Review submission to its PARENT deal:
        // PSA meets neither approval process's entry criteria, so the no-applicable-process
        // branch throws (not the "not linked to a deal" error), proving the parent
        // Opportunity was resolved correctly before Approval.process ever ran.
        System.assert(threw, 'A deal at PSA meets no approval entry criteria');
        System.assertEquals(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'No pending approval should be created for an ineligible stage');
    }

    @isTest
    static void unsupportedObjectThrows() {
        Contact c = TestDataFactory.createContact(null, true);

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(c.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Submit for Approval is not available on an unsupported object type');
    }
}
