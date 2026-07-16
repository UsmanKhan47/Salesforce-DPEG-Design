/**
 * Tests StageAdvanceController: each per-stage "advance" quick action moves the
 * deal to the next stage, the signed-NDA gate blocks Underwriting entry, and the
 * Underwriting -> LOI step routes through the principal approval process.
 */
@isTest
private class StageAdvanceControllerTest {

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
    static void beginReviewMovesNewToUnderReview() {
        Opportunity o = newOpp('New');
        Test.startTest();
        StageAdvanceController.advance(o.Id);
        Test.stopTest();
        System.assertEquals('Under Review',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Begin Review advances New -> Under Review');
    }

    @isTest
    static void initiateUnderwritingRequiresSignedNda() {
        Opportunity o = newOpp('Under Review');

        Boolean blocked = false;
        try {
            StageAdvanceController.advance(o.Id);
        } catch (Exception e) {
            blocked = true;
        }
        System.assert(blocked, 'Initiate Underwriting is blocked without a signed NDA');

        linkSignedNda(o);
        Test.startTest();
        StageAdvanceController.advance(o.Id);
        Test.stopTest();
        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A signed NDA lets the deal advance to Underwriting');
    }

    @isTest
    static void initiateLoiSubmitsForApproval() {
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
        update o;

        Test.startTest();
        StageAdvanceController.advance(o.Id);
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'Initiate LOI submits the deal into the principal approval process');
    }

    @isTest
    static void advanceToPsaMovesLoiToPsa() {
        Opportunity o = newOpp('LOI');
        Test.startTest();
        StageAdvanceController.advance(o.Id);
        Test.stopTest();
        System.assertEquals('PSA',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Advance to PSA moves LOI -> PSA');
    }

    @isTest
    static void closeDealMovesPsaToClosedWon() {
        Opportunity o = newOpp('PSA');
        Test.startTest();
        StageAdvanceController.advance(o.Id);
        Test.stopTest();
        System.assertEquals('Closed Won',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Close Deal moves PSA -> Closed Won');
    }

    @isTest
    static void closeDealMovesAboutToCloseToClosedWon() {
        Opportunity o = newOpp('About to Close');
        Test.startTest();
        StageAdvanceController.advance(o.Id);
        Test.stopTest();
        System.assertEquals('Closed Won',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Close Deal moves About to Close -> Closed Won');
    }

    @isTest
    static void noNextStepFromTerminalStageThrows() {
        Opportunity o = newOpp('Closed Won');
        Boolean threw = false;
        try {
            StageAdvanceController.advance(o.Id);
        } catch (Exception e) {
            threw = true;
        }
        System.assert(threw, 'A terminal stage has no next step');
    }

    @isTest
    static void advanceToSendsLandDealToDevelopmentReview() {
        Opportunity o = TestDataFactory.createOpportunitiesByRecordType(1, 'Land', null, false)[0];
        o.StageName = 'Under Review';
        insert o;

        Test.startTest();
        StageAdvanceController.advanceTo(o.Id, 'Development Review');
        Test.stopTest();

        System.assertEquals('Development Review',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Send to Development Review moves the deal to Development Review');
    }

    @isTest
    static void advanceToBlankTargetThrows() {
        Opportunity o = newOpp('Under Review');
        Boolean threw = false;
        try {
            StageAdvanceController.advanceTo(o.Id, '');
        } catch (Exception e) {
            threw = true;
        }
        System.assert(threw, 'A blank target stage is rejected');
    }
}
