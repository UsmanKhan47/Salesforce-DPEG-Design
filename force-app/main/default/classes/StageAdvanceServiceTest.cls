/**
 * @description Tests StageAdvanceService — the Opportunity stage-routing + stage-write
 * workflow extracted from StageAdvanceController in P6 controller thinning.
 *
 * ⚠ CHANGED 2026-08-28: this header used to advertise "(and the Underwriting -> approval
 * hand-off)" and "the approval hand-off from Underwriting". THAT HAND-OFF NO LONGER EXISTS —
 * the principal approval moved onto the Underwriting__c record and Initiate LOI became a plain
 * NEXT_STAGE write, gated by the Underwriting_Approved_Before_LOI validation rule. The two tests
 * that covered the hand-off were replaced (not repaired) by
 * advanceFromUnderwritingWritesTheLoiStage and
 * advanceFromUnderwritingIsRefusedWhenUnderwritingNotApproved.
 *
 * Covers every routed transition, the explicit-target advanceTo branch, the underwriting-approved
 * gate on the Underwriting -> LOI hop, and every StageAdvanceException branch: no record, no target,
 * no next step, and the signed-NDA validation gate (a DmlException converted to a
 * StageAdvanceException carrying the surfaced platform message). The service does a single
 * update per call with no Savepoint and no collection DML, so there is no rollback catch to
 * force and no 251-record bulk scenario applies (advance/advanceTo are single-record
 * @AuraEnabled operations invoked once per quick-action click).
 *
 * ALLOW-LIST (design doc D7): the final block covers the explicit-target allow-list added to
 * advanceTo. It is a behaviour change to a shared service — strictly a tightening — so both halves
 * are pinned: every legitimate branch/off-ramp target still writes, and a VALID-but-not-allowed
 * stage ('Closed Won', 'Underwriting', 'Under Contract (PSA)') is refused with the record left
 * untouched. The third was added 2026-08-14 (review W3): it is the stage whose omission from the
 * allow-list is the most load-bearing — it gates three validation rules at once — and it was the
 * one with no falsifier, so adding it to ALLOWED_EXPLICIT_TARGETS turned nothing red. Note that
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
        Opportunity psaDeal = newOpp('Under Contract (PSA)');

        // Both hops now cross stage gates, so both fixtures are brought up to the state the real
        // pipeline would have left them in. The signed-NDA gate covers PSA and Closed Won, so it
        // applies to BOTH deals; the approved-LOI gate applies only to the deal entering PSA, and
        // the signed-contract gate only to the deal entering Closed Won. (psaDeal is INSERTED at
        // PSA, so it never crosses the approved-LOI gate — ISCHANGED is false on insert.)
        //
        // loiDeal ALSO crosses Completed_LOI_Before_PSA (added 2026-08-12), a third gate that reads
        // the primary LOI's OWN Stage__c rather than the Opportunity's Primary_LOI__c/LOI_Approved__c
        // flags. placeApprovedLoi leaves the newly-created LOI at its factory-default Stage__c =
        // 'Draft', so the primary LOI is separately driven to its TERMINAL stage via
        // RecordStageAdvanceService.advanceTo — the real production route behind the
        // c/loiMarkCompleted quick action — mirroring the identical fix in
        // StageAdvanceControllerTest.advanceToPsaMovesLoiToPsa.
        //
        // ⚠ 'Signed' since observation 5 (2026-08-14), NOT 'Completed'. The acquisition LOI sequence
        // was renamed (Counter -> Negotiation, Completed -> Signed) and LOI_ACQUISITION_EXPLICIT_
        // TARGETS is now {Negotiation, Signed}, so the old literal is refused by the allow-list
        // BEFORE the record is loaded — this line would throw, not merely write a stale value.
        //
        // 🔴 WHAT THIS LINE MEANS, so the constant is not swapped mechanically again: it exists ONLY
        // to satisfy Completed_LOI_Before_PSA, which demands the primary LOI be at its TERMINAL
        // stage. 'Signed' is that terminal; 'Negotiation' — the other allowed explicit target — is
        // the mid-sequence BRANCH target and would leave this deal blocked by that very rule. The
        // choice is therefore forced by the gate, not by which literal happens to be allowed. Must
        // stay in step with Completed_LOI_Before_PSA, whose formula names BOTH terminals only until
        // the P3-D3 migration retires 'Completed'.
        TestDataFactory.signPrimaryNda(new List<Opportunity>{ loiDeal, psaDeal });
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(loiDeal);
        RecordStageAdvanceService.advanceTo(primaryLoi.Id, 'Signed');
        TestDataFactory.signContract(psaDeal);

        Test.startTest();
        StageAdvanceService.advance(loiDeal.Id);
        StageAdvanceService.advance(psaDeal.Id);
        Test.stopTest();

        Assert.areEqual('Under Contract (PSA)',
            [SELECT StageName FROM Opportunity WHERE Id = :loiDeal.Id].StageName, 'LOI -> PSA');
        Assert.areEqual('Closed Won',
            [SELECT StageName FROM Opportunity WHERE Id = :psaDeal.Id].StageName, 'PSA -> Closed Won');
    }

    /**
     * ⚠ REPLACES `advanceFromUnderwritingSubmitsForApproval` (2026-08-28), which asserted that
     * Initiate LOI created a ProcessInstance on the deal. That is no longer what the button does:
     * the principal approval moved onto the Underwriting__c record, and Initiate LOI became an
     * ordinary NEXT_STAGE write. The old assertion is not repaired, it is replaced — a
     * ProcessInstance count of 1 would now be a DEFECT, so it is asserted at 0.
     */
    @isTest
    static void advanceFromUnderwritingWritesTheLoiStage() {
        Opportunity o = newOpp('Underwriting');
        linkSignedNda(o);                          // isolate: LOI entry is ALSO NDA-gated
        update o;                                  // ⚠ linkSignedNda only sets the field in memory
        TestDataFactory.approveUnderwriting(o);    // satisfies the underwriting-approved gate

        Test.startTest();
        StageAdvanceService.advance(o.Id);
        Test.stopTest();

        Assert.areEqual('LOI', [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Initiate LOI is now a plain stage write: Underwriting -> LOI');
        Assert.areEqual(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'Initiate LOI must NOT submit the deal into any approval process any more');
    }

    /**
     * 🔴 THE GATE ITSELF — requirement (i). An unapproved underwriting must refuse Initiate LOI,
     * and the VALIDATION RULE'S OWN MESSAGE must reach the user verbatim.
     *
     * ⚠ REPLACES `advanceFromUnderwritingWrapsApprovalRuleViolation`, which exercised the
     * ApprovalException -> StageAdvanceException re-wrap. That branch was deleted with the
     * Underwriting hand-off; the surviving wrap is DmlException -> StageAdvanceException in
     * setStage, and it is now the entire Initiate-LOI gate.
     *
     * ⚠ THE MESSAGE ASSERTION IS ON A SUBSTRING COMMON TO BOTH VERSIONS OF THE RULE, ON PURPOSE.
     * Opportunity.Underwriting_Approved_Before_LOI is owned by the parallel declarative stream and
     * is being rewritten from `NOT(UW_Approved__c)` to a read of Primary_Underwriting__r.Stage__c:
     *     current : "This deal cannot enter LOI until the underwriting has been approved by the
     *                principals. Submit it for approval from the Underwriting stage."
     *     incoming: "This deal cannot enter LOI until its Underwriting record has been approved by
     *                the principals. Open the deal's Underwriting record and use Submit for
     *                Approval."
     * Pinning either full string would red this test on the other side of that deploy for no good
     * reason. 'cannot enter LOI until' is invariant across both and still falsifies everything
     * that matters here: that the platform refused the write, and that setStage surfaced the
     * RULE'S text rather than a generic "could not be advanced". Once the rewritten rule is
     * deployed and verified, tighten this to the full incoming string.
     *
     * The fixture fails BOTH versions of the rule simultaneously (UW_Approved__c is false AND the
     * auto-created underwriting is at 'Requested', neither 'Approved' nor 'Completed'), so the
     * test is sensitive whichever one is live.
     */
    @isTest
    static void advanceFromUnderwritingIsRefusedWhenUnderwritingNotApproved() {
        Opportunity o = newOpp('Underwriting');
        linkSignedNda(o); // isolate: leave the underwriting gate as the ONLY unmet gate
        update o;

        Test.startTest();
        try {
            StageAdvanceService.advance(o.Id);
            Assert.fail('Initiate LOI must be refused while the underwriting is unapproved');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isTrue(e.getMessage().contains('cannot enter LOI until'),
                'The validation rule\'s own message must be surfaced verbatim, got: '
                    + e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'A refused Initiate LOI must leave the deal where it was');
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
        // Review exists only on Land, Construction Review only on Retail — so relying on the
        // running user's DEFAULT record type would make this test pass or fail on org configuration
        // rather than on the allow-list. 'About to Close' and 'Dead/Pass' are in BOTH processes, so
        // the default-record-type helper is safe for those.
        Opportunity landDeal = TestDataFactory.createOpportunitiesByRecordType(1, 'Land', null, false)[0];
        landDeal.StageName = 'Under Review';
        Opportunity constructionDeal =
            TestDataFactory.createOpportunitiesByRecordType(1, 'Retail', null, false)[0];
        constructionDeal.StageName = 'Under Review';
        insert new List<Opportunity>{ landDeal, constructionDeal };
        Opportunity psaDeal = newOpp('Under Contract (PSA)');
        Opportunity deadDeal = newOpp('Under Review');

        // Only psaDeal needs preparing: 'About to Close' is inside the signed-NDA gate's stage
        // list, and the NDA auto-created on insert is Pending. Nothing else here crosses a gate —
        // the two branch targets are ungated, and the Dead/Pass leg is deliberately left bare
        // because it is a live assertion that the off-ramp is ALWAYS reachable. Giving deadDeal an
        // NDA it does not need would silently stop testing that.
        TestDataFactory.signPrimaryNda(psaDeal);

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
            'Construction Review is the Retail branch target and must remain allowed');
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

    /**
     * The stage this class had no falsifier for until 2026-08-14.
     *
     * 'Under Contract (PSA)' is deliberately ABSENT from ALLOWED_EXPLICIT_TARGETS, and that absence
     * is what forces every deal to reach it through advance() -> NEXT_STAGE, i.e. from 'LOI' and
     * from nowhere else. Three gates hang off that single hop and ALL of them are ISCHANGED- or
     * stage-keyed, so an explicit write straight to this stage skips all three at once:
     * Approved_LOI_Before_PSA, Completed_LOI_Before_PSA and NDA_Signed_Before_Deal_Progression.
     * That is a strictly worse bypass than the 'Closed Won' case above, because a deal parked at
     * 'Under Contract (PSA)' looks legitimate on the Path and in every report.
     *
     * 🔴 WHY THIS TEST EXISTS AT ALL. The two rejection tests above pin 'Closed Won' and
     * 'Underwriting', so ADDING this stage to ALLOWED_EXPLICIT_TARGETS turned nothing red — the
     * allow-list's most dangerous omission was the one with no test on it. The risk is not
     * hypothetical: Acquisition Observations phase 2 rewrote this literal from 'PSA' to
     * 'Under Contract (PSA)' across 45 files, and a rename sweep touching NEXT_STAGE and
     * ALLOWED_EXPLICIT_TARGETS in the same file is exactly when a line lands in the wrong
     * collection. The gap pre-dates that rename; the rename is why it was worth closing now.
     *
     * The fixture is at 'LOI' on purpose — the ONE stage from which this target is legitimately
     * reachable. Refusing it here is the strong claim: not even the record whose derived next stage
     * IS the target may take the explicit route to it.
     *
     * 🔴 THE QUERY-COUNT ASSERTION IS THE FALSIFIER; THE CAUGHT EXCEPTION IS NOT. This is the one
     * thing to preserve if this test is ever edited. `setStage` converts a DmlException into the
     * SAME StageAdvanceException type the allow-list throws, and this fixture has no approved LOI,
     * no completed LOI and no signed NDA — so if 'Under Contract (PSA)' WERE added to the
     * allow-list, the write would be refused by those three validation rules and re-thrown as a
     * StageAdvanceException anyway. A `catch` + `Assert.isNotNull(message)` therefore passes under
     * BOTH readings and pins nothing, and the "stage untouched" assertion is vacuous for the same
     * reason. What discriminates is WHERE the refusal came from: the allow-list check runs BEFORE
     * `load()`, so a rejection costs ZERO queries, whereas any refusal downstream of the allow-list
     * has already spent one loading the record. Same idiom as
     * advanceToRejectsAnUnknownStageWithoutQueryingTheRecord below.
     */
    @isTest
    static void advanceToRejectsUnderContractPsaEvenFromTheStageThatDerivesIt() {
        Opportunity o = newOpp('LOI');

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        try {
            StageAdvanceService.advanceTo(o.Id, 'Under Contract (PSA)');
            Assert.fail('advanceTo must refuse Under Contract (PSA) — it is reachable only through '
                + 'advance(), which routes via NEXT_STAGE and so cannot skip the LOI-approved, '
                + 'LOI-completed and signed-NDA gates');
        } catch (StageAdvanceService.StageAdvanceException e) {
            Assert.isNotNull(e.getMessage(), 'The allow-list rejection carries a user-safe message');
        }
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            'The refusal must come from the ALLOW-LIST, not from a validation rule downstream of it. '
            + 'The allow-list check runs before load(), so a rejected target costs no query; a '
            + 'non-zero count here means Under Contract (PSA) was accepted as an explicit target and '
            + 'only the gates stopped it — which is the bypass this set exists to close, and which '
            + 'would still be open for any deal that happens to satisfy them');

        Assert.areEqual('LOI',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'The rejected call must leave the deal at LOI — no partial write');
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
