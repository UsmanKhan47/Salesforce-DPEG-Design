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
        // Entering PSA crosses the signed-NDA gate (which covers PSA) and the approved-LOI gate.
        TestDataFactory.signPrimaryNda(o);
        TestDataFactory.placeApprovedLoi(o);
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
        // Closed Won is inside the signed-NDA gate's stage list and behind the signed-contract gate.
        TestDataFactory.signPrimaryNda(o);
        TestDataFactory.signContract(o);
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
        // Same two gates as the PSA -> Closed Won hop above: Closed Won is in the signed-NDA
        // gate's stage list and behind the signed-contract gate. (This method is NOT in the design
        // doc's Category-A list — it was found by sweeping every stage-changing UPDATE in the
        // suite. The doc traced Closed Won only from PSA and missed the About-to-Close entry.)
        TestDataFactory.signPrimaryNda(o);
        TestDataFactory.signContract(o);
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
            // The target must be an ALLOWED explicit target ('Development Review'). The previous
            // 'Under Review' is now rejected by the D7 allow-list before the record is loaded, so
            // this assertion would have kept passing while no longer reaching the read-failure catch
            // it exists to cover.
            StageAdvanceController.advanceTo(deletedId, 'Development Review');
            Assert.fail('advanceTo on a deleted deal should throw an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'advanceTo read failure maps to AuraHandledException');
        }
        Test.stopTest();
    }

    /**
     * The server-side permission assertion (design doc F5). Until this existed the deal-driver gate
     * was purely the Dynamic Actions visibility rule, which is a UX affordance — a user with
     * Opportunity edit access and class access could call these @AuraEnabled methods directly and
     * drive a deal through every stage.
     *
     * Runs as a bare Standard User (no Acquisition_Deal_Driver, no Modify All Data) and asserts BOTH
     * methods refuse AND that nothing was written.
     *
     * MIXED DML: this test needs a non-setup record (Opportunity) AND a setup record (User) in one
     * transaction, which normally raises MIXED_DML_OPERATION. Wrapping the User insert in
     * System.runAs(<the current user>) opens a fresh DML context and is the supported way to do both.
     * The refusal calls themselves perform no DML at all — that is the point of the assertions.
     */
    @isTest
    static void bothMethodsRefuseAUserWhoIsNotADealDriver() {
        Opportunity o = newOpp('New');
        Id dealId = o.Id;
        User bareUser = buildStandardUser('sacT');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert bareUser;   // setup DML, isolated from the Opportunity DML above
        }

        Test.startTest();
        Integer refusals = 0;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                StageAdvanceController.advance(dealId);
                // Reached only if NO exception was raised, i.e. the gate did not run at all. Failing
                // HERE, by name, is the whole point: without it a missing gate lets the stage write
                // proceed and the test reds much later on whatever the downstream cascade happens to
                // throw first (measured 2026-08-04: a WITH USER_MODE selector inside
                // OpportunityReviewTrigger), which reads like a selector/permission-set defect and
                // sends the reader hunting in the wrong class.
                Assert.fail('advance must REFUSE a non-deal-driver. It returned normally, so '
                    + 'OpportunityActionPermissionService.assertDealActionAccess did not run — check that '
                    + 'the StageAdvanceController being executed is the one carrying the assert');
            } catch (AuraHandledException e) {
                refusals++;
                Assert.areEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE, e.getMessage(),
                    'advance must surface the agreed denial wording — not the generic read-failure message, '
                    + 'which would tell the user to refresh the page over a permissions problem');
            }
            try {
                StageAdvanceController.advanceTo(dealId, 'Development Review');
                Assert.fail('advanceTo must REFUSE a non-deal-driver — see the note on advance above');
            } catch (AuraHandledException e) {
                refusals++;
                Assert.areEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE, e.getMessage(),
                    'advanceTo must surface the agreed denial wording');
            }
        }
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        Assert.areEqual(2, refusals, 'BOTH @AuraEnabled entry points must refuse a non-deal-driver');
        Assert.areEqual('New',
            [SELECT StageName FROM Opportunity WHERE Id = :dealId].StageName,
            'A refused call must not write: the stage must still be New. A changed stage here would mean '
            + 'the assert ran after the DML instead of before it');
    }

    /**
     * Builds (but does not insert) a bare Standard User for the permission-refusal test. Mirrors the
     * helper in OpportunityActionPermissionServiceTest — User is a setup object whose required-field
     * shape TestDataFactory deliberately does not cover.
     */
    private static User buildStandardUser(String tag) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = tag + String.valueOf(Datetime.now().getTime())
            + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        return new User(
            FirstName = 'Std',
            LastName = 'StageAdv',
            Alias = 'sadv',
            Email = 'std.stageadv@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
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
