/**
 * Tests StageAdvanceController (thinned in P6). The happy paths prove the delegated
 * behaviour is preserved end-to-end: each per-stage "advance" quick action moves the deal
 * to the next stage, the signed-NDA gate blocks Underwriting entry, and the
 * Underwriting -> LOI step routes through the principal approval process.
 *
 * P6 controller thinning: the stage-routing map, stage write, and approval hand-off now
 * live in StageAdvanceService, and each @AuraEnabled method wraps its work in a try/catch
 * that maps failures to an AuraHandledException at the LWC boundary (ARCHITECTURE.md §5).
 * The negative tests below therefore now expect an AuraHandledException.
 * missingRecordThrowsAuraHandledException covers the generic (read-failure) catch via a
 * deleted Opportunity Id — Opportunity is a standard object a bare user CAN read under
 * USER_MODE, so a bare user would not throw; a deleted Id makes the single-row selector
 * SOQL throw instead. advanceRethrowsAlreadyPendingApproval proves an already-pending
 * approval surfaces its message: StageAdvanceService re-wraps the service's typed
 * ApprovalException as a StageAdvanceException, which advance maps to an AuraHandledException.
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

        // P6: the signed-NDA validation DmlException is now surfaced as an AuraHandledException.
        try {
            StageAdvanceController.advance(o.Id);
            Assert.fail('Initiate Underwriting is blocked without a signed NDA');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'the signed-NDA gate maps to AuraHandledException');
        }

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
        try {
            StageAdvanceController.advance(o.Id);
            Assert.fail('A terminal stage has no next step');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'no-next-step maps to AuraHandledException');
        }
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
        try {
            StageAdvanceController.advanceTo(o.Id, '');
            Assert.fail('A blank target stage is rejected');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'blank target maps to AuraHandledException');
        }
    }

    // Covers both methods' generic (read-failure) catch: a deleted Opportunity Id makes the
    // single-row selector SOQL throw System.QueryException, which the controller maps to a
    // user-safe AuraHandledException. Run under admin (no bare user) — the only record DML is
    // the insert+delete of the Opportunity, so no MIXED_DML_OPERATION arises.
    @isTest
    static void missingRecordThrowsAuraHandledException() {
        Opportunity o = newOpp('New');
        Id deletedId = o.Id;
        delete o;

        Test.startTest();
        try {
            StageAdvanceController.advance(deletedId);
            Assert.fail('advance on a deleted deal should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'advance read failure maps to AuraHandledException');
        }
        try {
            StageAdvanceController.advanceTo(deletedId, 'Under Review');
            Assert.fail('advanceTo on a deleted deal should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'advanceTo read failure maps to AuraHandledException');
        }
        Test.stopTest();
    }

    // Proves an already-pending approval surfaces its message through advance: the second
    // submit makes OpportunityApprovalService throw a typed ApprovalException, which
    // StageAdvanceService re-wraps as a StageAdvanceException, which advance maps to an
    // AuraHandledException. Deterministic: the first submit creates the pending ProcessInstance
    // the second submit detects in the same transaction.
    @isTest
    static void advanceRethrowsAlreadyPendingApproval() {
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
        update o;

        Test.startTest();
        StageAdvanceController.advance(o.Id); // first submit -> now pending
        try {
            StageAdvanceController.advance(o.Id); // second submit -> already pending -> throws
            Assert.fail('A second submit while pending should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'the already-pending approval message propagates as AuraHandledException');
        }
        Test.stopTest();
    }
}
