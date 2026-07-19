/**
 * @description Tests StageAdvanceService — the Opportunity stage-routing + stage-write
 * workflow (and the Underwriting -> approval hand-off) extracted from StageAdvanceController
 * in P6 controller thinning.
 *
 * Covers every routed transition, the explicit-target advanceTo branch, the approval
 * hand-off from Underwriting, and every StageAdvanceException branch: no record, no target,
 * no next step, and the signed-NDA validation gate (a DmlException converted to a
 * StageAdvanceException carrying the surfaced platform message). The service does a single
 * update per call with no Savepoint and no collection DML, so there is no rollback catch to
 * force and no 251-record bulk scenario applies (advance/advanceTo are single-record
 * @AuraEnabled operations invoked once per quick-action click).
 *
 * @see force-app/main/default/classes/StageAdvanceService.cls
 * @author Salesforce Developer
 */
@isTest
private class StageAdvanceServiceTest {

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        insert o;
        return o;
    }

    private static void linkSignedNda(Opportunity o) {
        NDA__c nda = TestDataFactory.createSignedNdas(1, o.Id, true)[0];
        o.Primary_NDA__c = nda.Id;
        update o;
    }

    @isTest
    static void advanceMovesNewToUnderReview() {
        Opportunity o = newOpp('New');

        Test.startTest();
        String msg = StageAdvanceService.advance(o.Id);
        Test.stopTest();

        Assert.areEqual('Deal moved to Under Review.', msg, 'Confirmation message returned');
        Assert.areEqual('Under Review',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Begin Review advances New -> Under Review');
    }

    @isTest
    static void advanceMovesLoiToPsaAndPsaToClosedWon() {
        Opportunity loiDeal = newOpp('LOI');
        Opportunity psaDeal = newOpp('PSA');

        Test.startTest();
        StageAdvanceService.advance(loiDeal.Id);
        StageAdvanceService.advance(psaDeal.Id);
        Test.stopTest();

        Assert.areEqual('PSA',
            [SELECT StageName FROM Opportunity WHERE Id = :loiDeal.Id].StageName, 'LOI -> PSA');
        Assert.areEqual('Closed Won',
            [SELECT StageName FROM Opportunity WHERE Id = :psaDeal.Id].StageName, 'PSA -> Closed Won');
    }

    @isTest
    static void advanceFromUnderwritingSubmitsForApproval() {
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
        update o;

        Test.startTest();
        StageAdvanceService.advance(o.Id);
        Test.stopTest();

        Assert.areEqual(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'Initiate LOI submits the deal into the principal approval process');
    }

    @isTest
    static void advanceToMovesLandDealToDevelopmentReview() {
        Opportunity o = TestDataFactory.createOpportunitiesByRecordType(1, 'Land', null, false)[0];
        o.StageName = 'Under Review';
        insert o;

        Test.startTest();
        String msg = StageAdvanceService.advanceTo(o.Id, 'Development Review');
        Test.stopTest();

        Assert.areEqual('Deal moved to Development Review.', msg, 'Confirmation message returned');
        Assert.areEqual('Development Review',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Send to Development Review moves the deal to Development Review');
    }

    @isTest
    static void signedNdaGateBlocksUnderwritingAndSurfacesMessage() {
        Opportunity o = newOpp('Under Review');

        Test.startTest();
        try {
            StageAdvanceService.advance(o.Id);
            Assert.fail('Initiate Underwriting is blocked without a signed NDA');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'The validation-gate block surfaces a message');
        }

        // With a signed NDA the same call advances cleanly.
        linkSignedNda(o);
        StageAdvanceService.advance(o.Id);
        Test.stopTest();

        Assert.areEqual('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A signed NDA lets the deal advance to Underwriting');
    }

    @isTest
    static void noNextStepFromTerminalStageThrows() {
        Opportunity o = newOpp('Closed Won');

        Test.startTest();
        try {
            StageAdvanceService.advance(o.Id);
            Assert.fail('A terminal stage has no next step');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'The no-next-step block carries a message');
        }
        Test.stopTest();
    }

    @isTest
    static void blankTargetThrows() {
        Opportunity o = newOpp('Under Review');

        Test.startTest();
        try {
            StageAdvanceService.advanceTo(o.Id, '');
            Assert.fail('A blank target stage is rejected');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'The blank-target block carries a message');
        }
        Test.stopTest();
    }

    @isTest
    static void nullRecordThrowsOnBothMethods() {
        Test.startTest();
        try {
            StageAdvanceService.advance(null);
            Assert.fail('advance with no record should throw');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'advance null-record block carries a message');
        }
        try {
            StageAdvanceService.advanceTo(null, 'Under Review');
            Assert.fail('advanceTo with no record should throw');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'advanceTo null-record block carries a message');
        }
        Test.stopTest();
    }
}
