/**
 * Tests OpportunityDocStatusController.getDocStatus — the data behind the
 * Deal Summary card: NDA, LOI, Development/Construction review, and Contract review.
 */
@isTest
private class OpportunityDocStatusControllerTest {

    @isTest
    static void returnsAllDealArtifacts() {
        // Land deal that reaches PSA: the trigger spins off a
        // Development review (at Development Review) and a Contract review (at PSA).
        Opportunity opp = TestDataFactory.createOpportunity(null, false);
        opp.StageName = 'Development Review';
        insert opp;
        opp.StageName = 'PSA';
        update opp;

        // OpportunityReviewService.ensureNda() already auto-created a Pending NDA on
        // insert and stamped it onto Opportunity.Primary_NDA__c. The controller reads
        // the primary, so sign that record rather than inserting a rival NDA.
        NDA__c nda = [SELECT Id FROM NDA__c WHERE Opportunity__c = :opp.Id LIMIT 1];
        nda.Status__c = 'Signed';
        nda.Date_Sent__c = Date.today();
        nda.NDA_Expiry_Date__c = Date.today().addDays(365);
        update nda;

        LOI__c loi = TestDataFactory.createLoi(opp.Id, false);
        loi.LOI_Status__c = 'Submitted';
        loi.Offer_Price__c = 18000000;
        loi.Offer_Cap_Rate__c = 7;
        insert loi;

        Underwriting__c uw = TestDataFactory.createUnderwriting(opp.Id, false);
        uw.Stage__c = 'In Progress';
        uw.My_Price__c = 17000000;
        insert uw;

        Test.startTest();
        OpportunityDocStatusController.DocStatus d =
            OpportunityDocStatusController.getDocStatus(opp.Id);
        Test.stopTest();

        System.assert(d.hasNda, 'NDA should be found');
        System.assertEquals('Signed', d.ndaStatus);
        System.assert(d.hasLoi, 'LOI should be found');
        System.assertEquals('Submitted', d.loiStatus);
        System.assertEquals(18000000, d.loiOfferPrice);

        System.assert(d.hasUnderwriting, 'Underwriting should be found');
        System.assertEquals('In Progress', d.underwritingStage);
        System.assertEquals(17000000, d.underwritingPrice);

        System.assert(d.hasDevelopment, 'Development review should be found');
        System.assertEquals('Requested', d.developmentStage);
        System.assert(!d.hasConstruction, 'No Construction review for a Land deal');

        System.assert(d.hasContract, 'Contract review should be found');
        System.assertEquals('PSA Drafting', d.contractStage);
    }

    @isTest
    static void nullOpportunityReturnsEmpty() {
        Test.startTest();
        OpportunityDocStatusController.DocStatus d =
            OpportunityDocStatusController.getDocStatus(null);
        Test.stopTest();

        System.assert(!d.hasNda && !d.hasLoi && !d.hasUnderwriting && !d.hasDevelopment
            && !d.hasConstruction && !d.hasContract, 'Empty status for null opp');
    }
}
