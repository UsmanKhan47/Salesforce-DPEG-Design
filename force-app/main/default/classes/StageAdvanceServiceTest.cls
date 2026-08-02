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
 * ALLOW-LIST (design doc D7): the final block covers the explicit-target allow-list added to
 * advanceTo. It is a behaviour change to a shared service — strictly a tightening — so both halves
 * are pinned: every legitimate branch/off-ramp target still writes, and a VALID-but-not-allowed
 * stage ('Closed Won', 'Underwriting') is refused with the record left untouched. Note that
 * nullRecordThrowsOnBothMethods was also updated: its old 'Under Review' target is now rejected by
 * the allow-list before the record is loaded, so it would have kept passing while no longer testing
 * the null-record branch it is named for.
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
    static void advanceFromUnderwritingWrapsApprovalRuleViolation() {
        // The approval hand-off now calls OpportunityApprovalService, which raises a typed
        // ApprovalException for a user-actionable reason (here: an already-pending deal). The
        // service re-wraps it as a StageAdvanceException so the controller surfaces the same
        // user-safe message (behaviour-preserving). Deterministic: the first submit creates the
        // pending ProcessInstance the second submit detects in the same transaction.
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
        update o;
        StageAdvanceService.advance(o.Id); // first submit -> now pending

        Test.startTest();
        try {
            StageAdvanceService.advance(o.Id); // second submit -> already pending
            Assert.fail('A second submit while pending should throw');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(),
                'the approval rule violation is surfaced as a StageAdvanceException');
        }
        Test.stopTest();
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
            // The target MUST be an allowed explicit target ('Development Review'), not just any
            // stage. This used to pass 'Under Review', which the allow-list added for D7 now rejects
            // BEFORE the record is loaded — the test would still have "passed" while silently
            // testing the allow-list instead of the null-record branch it is named for.
            StageAdvanceService.advanceTo(null, 'Development Review');
            Assert.fail('advanceTo with no record should throw');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'advanceTo null-record block carries a message');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Explicit-target allow-list (design doc D7) — a tightening of a shared service.
    //
    // Before this, advanceTo wrote any non-blank string it was handed, so a direct @AuraEnabled call
    // could move a deal to ANY stage — skipping every hop in NEXT_STAGE and the signed-NDA gate.
    // These tests pin both halves: the legitimate targets still work, and the bypass targets do not.
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void advanceToAcceptsEveryAllowedExplicitTarget() {
        // One deal per target so each write is independent. The two BRANCH targets are pinned to an
        // explicit record type because they are mutually exclusive by business process — Development
        // Review exists only on Land, Construction Review only on Commercial — so relying on the
        // running user's DEFAULT record type would make this test pass or fail on org configuration
        // rather than on the allow-list. 'About to Close' and 'Dead/Pass' are in BOTH processes, so
        // the default-record-type helper is safe for those.
        Opportunity landDeal = TestDataFactory.createOpportunitiesByRecordType(1, 'Land', null, false)[0];
        landDeal.StageName = 'Under Review';
        Opportunity constructionDeal =
            TestDataFactory.createOpportunitiesByRecordType(1, 'Commercial', null, false)[0];
        constructionDeal.StageName = 'Under Review';
        insert new List<Opportunity>{ landDeal, constructionDeal };
        Opportunity psaDeal = newOpp('PSA');
        Opportunity deadDeal = newOpp('Under Review');

        Test.startTest();
        StageAdvanceService.advanceTo(landDeal.Id, 'Development Review');
        StageAdvanceService.advanceTo(constructionDeal.Id, 'Construction Review');
        StageAdvanceService.advanceTo(psaDeal.Id, 'About to Close');
        StageAdvanceService.advanceTo(deadDeal.Id, 'Dead/Pass');
        Test.stopTest();

        Map<Id, Opportunity> saved = new Map<Id, Opportunity>([
            SELECT Id, StageName FROM Opportunity
            WHERE Id IN (:landDeal.Id, :constructionDeal.Id, :psaDeal.Id, :deadDeal.Id)
        ]);
        Assert.areEqual('Development Review', saved.get(landDeal.Id).StageName,
            'Development Review is the Land branch target and must remain allowed');
        Assert.areEqual('Construction Review', saved.get(constructionDeal.Id).StageName,
            'Construction Review is the Commercial branch target and must remain allowed');
        Assert.areEqual('About to Close', saved.get(psaDeal.Id).StageName,
            'About to Close is the PSA off-ramp behind the Move to About to Close action');
        Assert.areEqual('Dead/Pass', saved.get(deadDeal.Id).StageName,
            'Dead/Pass uses the DECODED runtime value — the metadata form Dead%2FPass would silently never match');
    }

    /**
     * The bypass this allow-list exists to close. 'Closed Won' is the worst case: it is a real,
     * valid stage on both record types, so nothing else in the stack would have rejected it — the
     * write would simply have succeeded and closed the deal as Won, skipping LOI, PSA, the approval,
     * and the signed-NDA gate.
     */
    @isTest
    static void advanceToRejectsAStageOutsideTheAllowListEvenWhenTheStageIsValid() {
        Opportunity o = newOpp('Under Review');

        Test.startTest();
        try {
            StageAdvanceService.advanceTo(o.Id, 'Closed Won');
            Assert.fail('advanceTo must refuse Closed Won: it is a valid stage but not an allowed explicit target');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'The allow-list rejection carries a user-safe message');
        }
        Test.stopTest();

        Assert.areEqual('Under Review',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'The rejected call must leave the stage untouched — a partial write here would be the '
            + 'bypass succeeding anyway');
    }

    @isTest
    static void advanceToRejectsAForwardStageThatBelongsToTheDerivedRoute() {
        // 'Underwriting' is deliberately NOT an allowed explicit target: it is reachable only through
        // advance(), which routes via NEXT_STAGE and therefore cannot skip the signed-NDA gate.
        Opportunity o = newOpp('Under Review');

        Test.startTest();
        try {
            StageAdvanceService.advanceTo(o.Id, 'Underwriting');
            Assert.fail('advanceTo must refuse Underwriting — it belongs to the derived advance() route');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'The allow-list rejection carries a user-safe message');
        }
        Test.stopTest();

        Assert.areEqual('Under Review',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Routing a gated forward hop through advanceTo must not work — that is how the signed-NDA '
            + 'gate would be skipped');
    }

    @isTest
    static void advanceToRejectsAnUnknownStageWithoutQueryingTheRecord() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        try {
            StageAdvanceService.advanceTo(null, 'Not A Real Stage');
            Assert.fail('advanceTo must refuse a stage that does not exist at all');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'The allow-list rejection carries a user-safe message');
        }
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'The allow-list check must run BEFORE the record is loaded: a rejected target should cost no '
            + 'query and should reveal nothing about whether the record exists');
    }
}
