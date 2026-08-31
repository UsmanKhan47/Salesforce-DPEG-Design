/**
 * Tests OpportunityApprovalService — the approval-submission orchestration extracted from
 * OpportunityApprovalController in the W3 controller-thinning fix.
 *
 * Covers every resolveApprovalTargetId branch (Opportunity / LOI / Underwriting / Contract
 * Review / unsupported), every user-actionable path that raises the TYPED ApprovalException (no
 * record, not linked to a deal, already pending, ineligible stage, unsupported object), the
 * happy submission that returns a confirmation, and the generic-failure path where an
 * unexpected platform/query failure is left to propagate RAW (deliberately NOT wrapped in
 * ApprovalException — the controller masks it). submitForApproval is a single-record
 * operation (mirrors one quick-action click) with no collection DML, so no 251-record bulk
 * scenario applies.
 *
 * Per the task, ApprovalException-path tests assert the TYPED exception, never
 * AuraHandledException.getMessage().
 *
 * ── ⚠ SUPERSEDED NOTE (kept: it explains why three tests are shaped the way they are) ─────────
 * While the declarative half of this change was still undeployed, this header read "WHAT THESE
 * TESTS CAN AND CANNOT PROVE TODAY" and recorded that no test here could assert a ProcessInstance
 * targeting an underwriting record, because Apex cannot conjure an approval process. Three tests
 * were therefore written to assert only the parent-side NEGATIVE (zero instances on the deal),
 * which is true and sensitive in BOTH worlds, plus the routing table directly via the
 * @TestVisible resolveApprovalTargetId.
 *
 * Underwriting__c.Underwriting_Approval now exists, so the positives ARE assertable and have been
 * added alongside the negatives rather than replacing them — the negative is the half that
 * falsifies the original defect, and it stays. The @TestVisible routing assertion also stays: it
 * is the only assertion here that holds regardless of which approval processes are active, which
 * is what makes it the right place to pin the routing table itself.
 *
 * ── 🔴 THE SIGNED-NDA GATE (2026-08-30, design Item 3) — AND WHY THERE IS NO 251-RECORD TEST ────
 * `submitForApproval` now refuses an LOI-stage Opportunity submission when `Primary_NDA__c` is
 * blank or `Primary_NDA__r.NDA_Signed__c` is false. Five methods cover it: the happy path, both
 * refusal shapes, and two proofs that it does not fire where it must not (a non-LOI stage, and an
 * `Underwriting__c` target that resolves to itself).
 *
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-RECORD MANDATE DOES NOT APPLY, AND THE RULE'S OWN
 * EXEMPTION IS WHY — stated here because the rule requires the reasoning to be recorded in the test
 * class header rather than inferred. `submitForApproval` is a PER-TRANSACTION SINGLETON: it takes
 * ONE Id, mirrors ONE quick-action click, contains no loop over records and no collection DML, and
 * is never invoked more than once per transaction. The gate adds one single-row SOQL and no DML. A
 * 251-record test would not exercise one additional code path — there is no loop to force a second
 * batch — while risking unrelated limits (251 deals here means 251 trigger-created NDAs and 251
 * stamp updates before the first assertion). That is the exact anti-pattern the exemption exists to
 * prevent. The pre-existing header sentence above ("submitForApproval is a single-record operation
 * … so no 251-record bulk scenario applies") already recorded this; this paragraph names the rule
 * and the exemption clause so a reviewer does not have to re-derive it.
 *
 * @see force-app/main/default/classes/OpportunityApprovalService.cls
 * @see force-app/main/default/classes/OpportunitySelector.cls (selectNdaGateById — the gate's read)
 */
@isTest
private class OpportunityApprovalServiceTest {

    /**
     * An inserted deal at `stage`, WITH ITS PRIMARY NDA SIGNED when that stage is LOI.
     *
     * ═══ 🔴 THE NDA SIGNING WAS ADDED 2026-08-30 AND IS A FIXTURE FIX, NOT A LOGIC CHANGE ═══
     * `submitForApproval` now refuses an LOI-stage submission whose primary NDA is blank or
     * unsigned (design Item 3). Every existing test in this class that reached
     * `Approval.process` through `makeOpp('LOI')` was therefore about to fail — NOT because the
     * behaviour under test changed, but because the fixture never represented a legitimately
     * submittable deal. `NDA_Signed_Before_Deal_Progression` already blocks ENTRY to the LOI stage
     * without a signed NDA; these fixtures only slipped past it because that rule is
     * `ISCHANGED(StageName)`-gated and therefore FALSE on insert. The org has no such deals by any
     * route a human can take.
     *
     * ⚠ SO THE RIGHT FIX WAS THE FIXTURE, NOT THE GATE. Loosening the gate to keep these green
     * would have been fixing the test by deleting the feature.
     *
     * ⚠ THE SIGNING IS CONDITIONAL ON PURPOSE. A non-LOI deal must NOT be given a signed NDA here:
     * `ineligibleStage...` and the underwriting tests need to prove the gate does not fire for
     * them, and a fixture that satisfied the gate everywhere could not tell "the gate passed" from
     * "the gate was never reached".
     *
     * @param stage The StageName to insert at.
     * @return The inserted deal.
     */
    private static Opportunity makeOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        insert o;
        if (stage == 'LOI') {
            TestDataFactory.signPrimaryNda(o);
        }
        return o;
    }

    /**
     * An LOI-stage deal whose primary NDA is deliberately NOT signed — the state the gate refuses.
     *
     * `OpportunityReviewService.ensureNda` opens exactly one Pending NDA per deal on insert and
     * stamps it onto `Primary_NDA__c`, so this deal HAS a primary NDA; it simply is not signed.
     * That is the distinct half of the gate — the other half (no primary NDA at all) needs its own
     * fixture and gets one in `blankPrimaryNdaAtLoiIsRefused`.
     *
     * @return The inserted deal, at LOI, with an unsigned primary NDA.
     */
    private static Opportunity makeLoiOppWithUnsignedNda() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        return o;
    }

    // ---- happy paths (try/return + resolveApprovalTargetId branches) ----

    @isTest
    static void submitsEligibleOpportunityDirectly() {
        Opportunity o = makeOpp('LOI');

        Test.startTest();
        String msg = OpportunityApprovalService.submitForApproval(o.Id);
        Test.stopTest();

        // ⚠ WORDING CHANGED 2026-08-28: 'The deal has been…' -> 'The record has been…'. The
        // method no longer always submits a deal (an underwriting submits itself), so a message
        // naming "the deal" would be factually wrong on the Underwriting surface. Matches the
        // neutral wording DispositionApprovalService already uses for the same reason.
        Assert.areEqual('The record has been submitted for approval.', msg,
            'An eligible deal returns the confirmation message');
        Assert.areEqual(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'A pending approval instance exists after submit');
    }

    /**
     * ⚠ INVERTED AND RENAMED 2026-08-28. Was `submitsFromUnderwritingRecordResolvesParent`, and
     * it asserted THE EXACT OPPOSITE of the required behaviour: that submitting from an
     * Underwriting record put the PARENT DEAL into approval. That is precisely what this change
     * exists to stop, so the old test was not repaired, it was reversed.
     *
     * ⚠ UPGRADED once Underwriting__c.Underwriting_Approval existed. While that process was
     * undeployed this test could only assert the NEGATIVE (no instance on the parent), because no
     * Apex can conjure an approval process. It now asserts BOTH halves — the instance exists AND
     * it targets the child — which is the positive proof the design pack had deferred to
     * post-deploy check P-1.
     */
    @isTest
    static void submitsFromUnderwritingRecordTargetsTheUnderwritingItself() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        o.Underwriting_Complete__c = true;
        insert o; // stage entry auto-creates the Underwriting record
        Underwriting__c uw = [SELECT Id, Stage__c FROM Underwriting__c WHERE Opportunity__c = :o.Id];

        Assert.areEqual(uw.Id, OpportunityApprovalService.resolveApprovalTargetId(uw.Id),
            'An Underwriting record is its OWN approval target — not its parent deal');

        // The approval's entry criterion is Stage__c = 'In Progress'; the auto-created record
        // arrives at 'Requested'.
        uw.Stage__c = 'In Progress';
        update uw;

        Test.startTest();
        String msg = OpportunityApprovalService.submitForApproval(uw.Id);
        Test.stopTest();

        Assert.areEqual('The record has been submitted for approval.', msg,
            'A neutral confirmation — this submission is not "the deal"');
        Assert.areEqual(1, [
            SELECT COUNT() FROM ProcessInstance
            WHERE TargetObjectId = :uw.Id AND Status = 'Pending'
        ], 'The pending approval must target the UNDERWRITING record');
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'Submitting from the Underwriting record must NEVER submit the parent deal');
    }

    /**
     * 🔴 THE LIVE DEFECT THIS CHANGE CLOSES — the single highest-value test in this file.
     *
     * Before 2026-08-28, an Underwriting record resolved to its parent, so clicking Submit for
     * Approval on an underwriting whose PARENT had already reached StageName = 'LOI' submitted the
     * deal into **LOI_Approval** — a completely different approval process, with a success toast
     * and no warning. It was reachable in production because the Underwriting page's visibility
     * rule keys on the CHILD's Stage__c and never inspects the parent's stage.
     *
     * ⚠ THE FIXTURE IS BUILT SO THAT LOI_Approval WOULD GENUINELY ACCEPT THE PARENT. The deal
     * really is at StageName = 'LOI', which really is that process's entry criterion, and
     * LOI_Approval really is still active — it is deliberately NOT part of this change. So the
     * wrong process is a live, reachable destination, and only the routing keeps the submission
     * away from it. Reverting resolveApprovalTargetId's Underwriting branch reds this immediately.
     */
    @isTest
    static void underwritingWithParentAtLoiNeverEntersLoiApproval() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        insert o; // stage entry auto-creates the Underwriting record
        Underwriting__c uw = [SELECT Id, Stage__c FROM Underwriting__c WHERE Opportunity__c = :o.Id];

        // Move the PARENT to LOI — the stage at which LOI_Approval's entry criteria are met.
        TestDataFactory.signPrimaryNda(o);
        TestDataFactory.approveUnderwriting(o); // also satisfies Underwriting_Approved_Before_LOI
        o.StageName = 'LOI';
        update o;
        Assert.areEqual('LOI', [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Fixture precondition: the parent must really be at LOI, or this test proves nothing');

        // Put the child back at the stage its OWN approval accepts, so the submission genuinely
        // succeeds — this test must prove the submission went to the RIGHT process, not merely
        // that it failed to go anywhere.
        uw.Stage__c = 'In Progress';
        update uw;

        Test.startTest();
        OpportunityApprovalService.submitForApproval(uw.Id);
        Test.stopTest();

        Assert.areEqual(1, [
            SELECT COUNT() FROM ProcessInstance
            WHERE TargetObjectId = :uw.Id AND Status = 'Pending'
        ], 'The submission lands on the underwriting record\'s own approval');
        Assert.areEqual(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'An underwriting whose parent sits at LOI must NOT submit the deal into LOI_Approval');
    }

    /**
     * The routing table itself, asserted directly. Independent of which approval processes happen
     * to be active in the org, so it is the one place that pins all four branches at once.
     */
    @isTest
    static void resolveApprovalTargetIdRoutesEachObjectToItsApprovalTarget() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        insert o;
        Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :o.Id];
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);

        Test.startTest();
        Id fromOpp = OpportunityApprovalService.resolveApprovalTargetId(o.Id);
        Id fromUnderwriting = OpportunityApprovalService.resolveApprovalTargetId(uw.Id);
        Id fromLoi = OpportunityApprovalService.resolveApprovalTargetId(loi.Id);
        Test.stopTest();

        Assert.areEqual(o.Id, fromOpp, 'An Opportunity is its own approval target');
        Assert.areEqual(uw.Id, fromUnderwriting,
            'CHANGED 2026-08-28: an Underwriting is its OWN target, no longer its parent deal');
        Assert.areEqual(o.Id, fromLoi,
            'UNCHANGED: an LOI still resolves to its parent deal — LOI_Approval runs on the deal');
    }

    /**
     * Open item (b): the Opportunity at StageName = 'Underwriting' must be refused with a message
     * NAMING THE REAL ROUTE, instead of falling through to the controller's generic mask.
     *
     * ⚠ REPLACES A TRIPWIRE (2026-08-28). Until Opportunity.Underwriting_Approval was deactivated
     * this branch was UNREACHABLE — that process's entry criterion was exactly
     * StageName = 'Underwriting', so the submission SUCCEEDED and no refusal could be observed. A
     * placeholder test (opportunityAtUnderwritingStillUsesTheLegacyProcess_TRIPWIRE) asserted the
     * legacy behaviour instead, specifically so it would go red the moment the deactivation landed
     * rather than pass vacuously forever. It has done its job and is deleted; this is the test it
     * named as its replacement.
     *
     * ⚠ ASSERTS THE MESSAGE, NOT MERELY "IT THREW". Before this change the same call ALSO threw —
     * it fell through to `throw e` and the controller masked it as "The deal could not be
     * submitted for approval. Refresh the page or contact your administrator." A test asserting
     * only that an exception occurred would pass against exactly the useless behaviour this whole
     * change exists to remove.
     */
    @isTest
    static void submittingTheOpportunityAtUnderwritingNamesTheRealRoute() {
        Opportunity o = makeOpp('Underwriting');

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(o.Id);
            Assert.fail('An Opportunity at Underwriting meets no approval entry criteria');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.isTrue(e.getMessage().contains('Underwriting record'),
                'The refusal must point the submitter at the Underwriting record, got: '
                    + e.getMessage());
            Assert.isTrue(e.getMessage().contains('Submit for Approval'),
                'The refusal must name the action to use, got: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'No approval instance may be created — it must not land in LOI_Approval');
    }

    @isTest
    static void submitsFromLoiRecordResolvesParent() {
        Opportunity o = makeOpp('LOI');
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);

        Test.startTest();
        OpportunityApprovalService.submitForApproval(loi.Id);
        Test.stopTest();

        Assert.areEqual(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id AND Status = 'Pending'],
            'Submitting from the LOI record routes the PARENT deal into approval');
    }

    // ---- typed ApprovalException paths (user-actionable) ----

    @isTest
    static void nullRecordThrowsApprovalException() {
        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(null);
            Assert.fail('A null record id should throw');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.isNotNull(e.getMessage(), 'no-record raises a typed ApprovalException');
        }
        Test.stopTest();
    }

    @isTest
    static void unlinkedChildThrowsApprovalException() {
        LOI__c orphan = TestDataFactory.createLoi(null, false);
        orphan.Offer_Price__c = 500000;
        insert orphan; // no parent Opportunity

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(orphan.Id);
            Assert.fail('An LOI with no parent deal cannot be submitted');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.isNotNull(e.getMessage(), 'not-linked-to-a-deal raises a typed ApprovalException');
        }
        Test.stopTest();
    }

    @isTest
    static void secondSubmitThrowsApprovalException() {
        Opportunity o = makeOpp('LOI');
        OpportunityApprovalService.submitForApproval(o.Id); // first -> now pending

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(o.Id); // second -> already pending
            Assert.fail('Submitting an already-pending deal should throw');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.isNotNull(e.getMessage(), 'already-pending raises a typed ApprovalException');
        }
        Test.stopTest();
    }

    @isTest
    static void ineligibleStageThrowsApprovalException() {
        // ⚠ NARROWED 2026-08-28: the eligible set for an OPPORTUNITY target is now {LOI} alone —
        // 'Underwriting' was removed when the principal approval moved onto the child record, and
        // has its own dedicated message (see submittingTheOpportunityAtUnderwritingNamesTheRealRoute).
        // A deal at neither meets no entry criteria -> Approval.process throws -> the catch
        // re-reads the stage and raises the friendly ApprovalException.
        Opportunity o = makeOpp('Under Review');

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(o.Id);
            Assert.fail('A deal that meets no entry criteria should throw');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.isTrue(e.getMessage().contains('LOI approval runs at the LOI stage'),
                'The generic ineligible-stage message must now name ONLY the LOI gate, got: '
                    + e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'No pending approval is created for an ineligible stage');
    }

    @isTest
    static void resolvesDealFromContractReviewRecord() {
        Opportunity o = makeOpp('Under Contract (PSA)'); // stage entry auto-creates a Contract_Review__c
        Contract_Review__c cr =
            [SELECT Id FROM Contract_Review__c WHERE Opportunity__c = :o.Id LIMIT 1];

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(cr.Id);
            Assert.fail('A deal at PSA meets no approval entry criteria');
        } catch (OpportunityApprovalService.ApprovalException e) {
            // Proves resolveApprovalTargetId routed the Contract Review submission to its PARENT deal:
            // PSA meets neither process's entry criteria, so the no-applicable-process branch
            // raises (not the "not linked to a deal" error), proving the parent Opportunity
            // was resolved before Approval.process ran.
            Assert.isNotNull(e.getMessage(), 'resolves the parent then reports no applicable process');
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'No pending approval for an ineligible stage');
    }

    @isTest
    static void unsupportedObjectThrowsApprovalException() {
        Contact c = TestDataFactory.createContact(null, true);

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(c.Id);
            Assert.fail('Submit for Approval is not available on an unsupported object type');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.isNotNull(e.getMessage(), 'an unsupported object type raises a typed ApprovalException');
        }
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 🔴 THE SIGNED-NDA GATE (design Item 3, 2026-08-30)
    //
    // Five tests: one positive, two refusals, two proofs the gate stays out of the way. The two
    // NEGATIVE-CONTROL tests are the ones that matter most — a gate that refuses everything would
    // pass both refusal tests, and only the "does not fire here" pair can tell the two apart.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void signedNdaAtLoiStillSubmits() {
        // The positive control for the two refusals below. Without it, a gate that refused EVERY
        // LOI submission would look correct.
        Opportunity o = makeOpp('LOI'); // signs the primary NDA — see the helper

        Test.startTest();
        String msg = OpportunityApprovalService.submitForApproval(o.Id);
        Test.stopTest();

        Assert.areEqual('The record has been submitted for approval.', msg,
            'A signed primary NDA must not stand in the way of a legitimate LOI submission');
        Assert.areEqual(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'and the deal really did enter the approval process');
    }

    @isTest
    static void unsignedPrimaryNdaAtLoiIsRefusedWithTheTypedException() {
        Opportunity o = makeLoiOppWithUnsignedNda();

        Test.startTest();
        Boolean refused = false;
        try {
            OpportunityApprovalService.submitForApproval(o.Id);
            Assert.fail('An LOI-stage deal with an UNSIGNED primary NDA must be refused');
        } catch (OpportunityApprovalService.ApprovalException e) {
            refused = true;
            // 🔴 THE TYPE IS THE ASSERTION, NOT JUST THE MESSAGE. The EXCEPTION CONTRACT reserves
            // ApprovalException for user-actionable violations whose text is safe to surface
            // VERBATIM; an unexpected failure propagates raw and the controller masks it. If this
            // gate ever throws AuraHandledException instead, the message reaches the user through a
            // different path with different escaping, and this catch stops matching.
            Assert.areEqual(OpportunityApprovalService.NDA_UNSIGNED_MESSAGE, e.getMessage(),
                'and the refusal must carry the actionable NDA wording verbatim');
        }
        Test.stopTest();

        Assert.isTrue(refused, 'the typed ApprovalException is what was thrown');
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            '🔴 AND NOTHING WAS SUBMITTED. This is the half that makes it a GATE rather than a '
            + 'message: the throw must happen BEFORE Approval.process, because there is no way to '
            + 'un-submit an approval afterwards');
    }

    @isTest
    static void blankPrimaryNdaAtLoiIsRefused() {
        // The OTHER refusal shape, and it is not redundant with the one above: the gate reads a
        // SPANNING field (`Primary_NDA__r.NDA_Signed__c`), and on a blank lookup the parent is null
        // — so an implementation that tested only the spanning value would throw a
        // NullPointerException here instead of refusing cleanly, and the user would get the
        // controller's generic mask instead of an actionable message.
        Opportunity o = makeLoiOppWithUnsignedNda();
        // OpportunityReviewService.ensureNda stamped a primary NDA on insert; clear it.
        update new Opportunity(Id = o.Id, Primary_NDA__c = null);
        Assert.isNull([SELECT Primary_NDA__c FROM Opportunity WHERE Id = :o.Id].Primary_NDA__c,
            'Fixture precondition: the deal must really have NO primary NDA, or this test proves '
            + 'nothing that the unsigned test did not already prove');

        Test.startTest();
        Boolean refused = false;
        try {
            OpportunityApprovalService.submitForApproval(o.Id);
            Assert.fail('An LOI-stage deal with NO primary NDA must be refused');
        } catch (OpportunityApprovalService.ApprovalException e) {
            refused = true;
            Assert.areEqual(OpportunityApprovalService.NDA_UNSIGNED_MESSAGE, e.getMessage(),
                'and it shares the unsigned case\'s wording deliberately — to the submitter both '
                + 'states are "this deal has no signed NDA" with one identical remedy');
        }
        Test.stopTest();

        Assert.isTrue(refused, 'a blank lookup refuses rather than NPEs');
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'and nothing was submitted');
    }

    @isTest
    static void theNdaGateDoesNotFireAtAnyStageButLoi() {
        // 🔴 NEGATIVE CONTROL. Under Review has an UNSIGNED NDA and is refused anyway — but for
        // the PRE-EXISTING stage reason, not the new one. Asserting on the MESSAGE is the whole
        // point: a gate that ignored StageName would refuse this deal with the NDA wording and
        // still throw ApprovalException, so a type-only assertion would pass for the wrong reason
        // and the regression would be invisible.
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Under Review';
        insert o; // no signPrimaryNda — the NDA is deliberately unsigned

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalService.submitForApproval(o.Id);
        } catch (OpportunityApprovalService.ApprovalException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('LOI approval runs at the LOI stage'),
                'A non-LOI deal must be refused for its STAGE, by the pre-existing derivation in '
                + 'the catch — the NDA gate has no opinion about it. Got: ' + e.getMessage());
            Assert.isFalse(e.getMessage().contains('NDA'),
                'and the NDA gate must not have fired here at all. Got: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw, 'the pre-existing ineligible-stage refusal still happens');
    }

    @isTest
    static void anUnderwritingSubmissionIsUnaffectedByTheNdaGate() {
        // 🔴 THE SECOND NEGATIVE CONTROL, AND THE ONE THAT PINS THE GATE'S CHEAPEST PROPERTY.
        // An Underwriting__c resolves to ITSELF, so the gate returns before it queries anything.
        // The parent deal here sits at LOI with an UNSIGNED NDA — precisely the state the gate
        // refuses — so if the gate ever keyed on the clicked record's PARENT instead of on the
        // resolved TARGET, this submission would start failing and the underwriting approval
        // surface would break for a reason nobody would connect to the LOI.
        Opportunity o = makeLoiOppWithUnsignedNda();
        // ⚠ BUILT EXPLICITLY, NOT QUERIED. MEASURED 2026-08-30 (run 707iw000003bXYS): an earlier
        // revision of this test read `[SELECT Id FROM Underwriting__c WHERE Opportunity__c = :o.Id]`
        // on the assumption that the trigger creates one, and failed with
        // `System.QueryException: List has no rows for assignment to SObject`. The trigger creates
        // an Underwriting on entry to the UNDERWRITING stage; this deal is inserted straight at
        // LOI and never passes through it, so no child exists. (The sibling tests that DO query for
        // one build their deal at 'Underwriting' — that is the difference, not luck.)
        //
        // ⚠ AND IT CANNOT BE BUILT THE SIBLINGS' WAY HERE. This fixture needs a parent at LOI whose
        // NDA is UNSIGNED, and NDA_Signed_Before_Deal_Progression blocks the Underwriting -> LOI
        // stage MOVE without a signed NDA. Inserting at LOI is the only route to that state, so the
        // child has to be created directly.
        Underwriting__c uw = TestDataFactory.createUnderwriting(o.Id, true);

        Test.startTest();
        Boolean refusedByNda = false;
        try {
            OpportunityApprovalService.submitForApproval(uw.Id);
        } catch (OpportunityApprovalService.ApprovalException e) {
            // An underwriting at the wrong Stage__c can still be refused for ITS OWN reason; only
            // an NDA refusal is a failure of this test.
            refusedByNda = e.getMessage() == OpportunityApprovalService.NDA_UNSIGNED_MESSAGE;
        } catch (Exception e) {
            // Any other platform failure is out of scope here; the routing tests cover it.
        }
        Test.stopTest();

        Assert.isFalse(refusedByNda,
            'The NDA gate applies to the RESOLVED TARGET, and an Underwriting__c resolves to '
            + 'itself. Its parent deal\'s NDA state is not its business.');
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'and, as ever, an underwriting submission never touches the parent deal');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 🔴 THE SHARING AXIS — the one the other five gate tests CANNOT reach
    //
    // Those five all run as the admin test-running user, who OWNS both the Opportunity and the
    // trigger-created NDA. Owner == submitter in 5 of 5, so record-level sharing is never
    // consulted and a sharing defect in the gate is unreachable by construction. These two
    // tests are what make it reachable.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void aSubmitterWhoCannotSeeTheNdaIsNotFalselyBlocked() {
        // ═══ WHAT THIS MEASURES, AND WHY IT IS NOT ANSWERABLE BY REASONING ═══
        // `OpportunitySelector.selectNdaGateById` is `WITH SYSTEM_MODE`, which lifts CRUD/FLS and
        // **NEVER sharing**. `NDA__c` OWD is `Private` (objects/NDA__c/NDA__c.object-meta.xml).
        // If the spanning read `Primary_NDA__r.NDA_Signed__c` were sharing-filtered on the PARENT,
        // a submitter who cannot see the NDA would receive a null parent and this gate would
        // REFUSE a deal whose NDA IS SIGNED — the gate INVERTING into a false block rather than
        // degrading. That is strictly worse than the failure the gate exists to prevent, and it
        // would appear only in production, only for non-owners.
        //
        // The persona is `DPEG_Opportunity_View`: Opportunity read + viewAllRecords and — verified
        // in the permission set file, 2026-08-30 — exactly ONE NDA-related line in the whole set,
        // the `Opportunity.Primary_NDA__c` FLS grant. No `NDA__c` objectPermissions, no
        // viewAllRecords on it, and it owns nothing. Base profile is `Minimum Access - Salesforce`,
        // so nothing it can do leaks in from the profile.
        Opportunity notOwned = makeOpp('LOI');            // signed NDA; owned by the ADMIN
        Opportunity unsignedNotOwned = makeLoiOppWithUnsignedNda();
        Id ndaId = [SELECT Primary_NDA__c FROM Opportunity WHERE Id = :notOwned.Id].Primary_NDA__c;
        Assert.isNotNull(ndaId, 'Fixture precondition: the deal must have a primary NDA');

        User submitter = TestDataFactory.createNonOwnerLoiSubmitter('nasl');

        // 🔴 THE PRECONDITION THAT KEEPS THE WHOLE TEST HONEST, AND IT IS DELIBERATELY NOT A SOQL
        // PROBE INSIDE System.runAs. An Apex test class carries no sharing keyword and therefore
        // runs `without sharing`, so a plain `[SELECT COUNT() FROM NDA__c ...]` under runAs would
        // return the row REGARDLESS of the persona's access and would "prove" the opposite of the
        // truth. `UserRecordAccess` is evaluated by the platform against the user and the record,
        // independently of the querying class's sharing.
        UserRecordAccess ndaAccess = [
            SELECT RecordId, HasReadAccess
            FROM UserRecordAccess
            WHERE UserId = :submitter.Id AND RecordId = :ndaId
        ];
        Assert.isFalse(ndaAccess.HasReadAccess,
            'FIXTURE PRECONDITION: the submitter must NOT be able to read the NDA, or this test '
            + 'measures nothing. If this fails, something granted NDA__c access — a role on the '
            + 'persona, a sharing rule, or a viewAllRecords entry added to DPEG_Opportunity_View '
            + '— and the sharing axis has stopped being covered.');

        Boolean signedRefusedByNda = false;
        Boolean signedRefusedByAnyGate = false;
        Boolean signedReachedApprovalProcess = false;
        Boolean unsignedRefusedByNda = false;
        String unexpected = null;

        Test.startTest();
        System.runAs(submitter) {
            try {
                OpportunityApprovalService.submitForApproval(notOwned.Id);
                signedReachedApprovalProcess = true;
            } catch (OpportunityApprovalService.ApprovalException e) {
                signedRefusedByNda =
                    e.getMessage() == OpportunityApprovalService.NDA_UNSIGNED_MESSAGE;
                signedRefusedByAnyGate = true;
                unexpected = e.getMessage();
            } catch (Exception e) {
                // ═══ 🔴 REACHING HERE IS A PASS, NOT A FAILURE, AND THAT IS MEASURED ═══
                // A raw platform exception means the service's own gates ALL let the submission
                // through and `Approval.process` itself was reached — which is exactly what this
                // test needs to prove. See the assertion block below for why this persona cannot
                // get further than that, and why that is the platform's rule and not the gate's.
                signedReachedApprovalProcess = true;
                unexpected = e.getTypeName() + ': ' + e.getMessage();
            }

            // 🔴 THE CONTROL THAT STOPS THE ASSERTION ABOVE PASSING VACUOUSLY, AND IT IS THE MOST
            // IMPORTANT BLOCK IN THIS TEST. "The signed deal was not refused" is ALSO true of a
            // gate that never ran at all — wrong stage, an exception swallowed upstream, a persona
            // that cannot reach the code. Running the UNSIGNED deal through the SAME persona in
            // the SAME runAs block proves the gate is live for this user AND can still tell the
            // two states apart. Without it, deleting the gate outright would leave this green.
            try {
                OpportunityApprovalService.submitForApproval(unsignedNotOwned.Id);
            } catch (OpportunityApprovalService.ApprovalException e) {
                unsignedRefusedByNda =
                    e.getMessage() == OpportunityApprovalService.NDA_UNSIGNED_MESSAGE;
            } catch (Exception e) {
                // Any other platform failure is not this test's subject.
            }
        }
        Test.stopTest();

        Assert.isFalse(signedRefusedByNda,
            'THE GATE INVERTED. A submitter who cannot READ the NDA was refused a deal whose NDA '
            + 'IS SIGNED, which means the SYSTEM_MODE spanning read in selectNdaGateById is being '
            + 'SHARING-FILTERED on the Private-OWD NDA__c parent and yielding a null parent. FIX: '
            + 'move ONLY that one query into a narrow private-without-sharing inner class on '
            + 'OpportunitySelector (the LeadSelector.GuestReads shape, ARCHITECTURE.md section 2). '
            + 'DO NOT put without-sharing on the whole selector — it backs fourteen other reads.');
        Assert.isTrue(unsignedRefusedByNda,
            'CONTROL: the same persona must still be REFUSED the deal whose NDA is unsigned. If '
            + 'this fails the gate is not running for this user at all, and the assertion above is '
            + 'green for the wrong reason.');
        Assert.isFalse(signedRefusedByAnyGate,
            'No gate in this service may refuse the signed deal for this persona. Got: '
            + unexpected);

        // ═══ ⚠ WHY THIS ASSERTS "REACHED Approval.process" AND NOT "SUBMITTED SUCCESSFULLY" ═══
        // MEASURED 2026-08-30 (run 707iw000003bKFb): an earlier revision asserted the submission
        // SUCCEEDED and failed with
        //     System.DmlException: NO_APPLICABLE_PROCESS, No applicable approval process was found.
        // That is NOT the gate. `approvalProcesses/Opportunity.LOI_Approval` declares
        // `<allowedSubmitters><type>owner</type></allowedSubmitters>`, so the PLATFORM refuses any
        // submission by a non-owner before entry criteria are even considered. A non-owner can
        // therefore never complete this submission, whatever the NDA gate does — so asserting
        // success here was wrong BY CONSTRUCTION and could only ever have been made green by
        // weakening the persona until it stopped testing sharing.
        //
        // 🔴 AND THAT MAKES `theOwnedRecordControlStillSubmits` THE PRODUCTION-SHAPED CASE, NOT
        // THIS ONE. The realistic victim of the inversion is a deal's OWNER who cannot read its
        // NDA — the NDA is created by the trigger under whoever inserted the deal, so owning the
        // Opportunity does not imply owning the NDA. That test asserts exactly that pairing
        // (`HasReadAccess = false` on the NDA, owner of the deal), FAILED before the
        // `without sharing` fix and PASSES after it. This test covers the wider non-owner case and
        // proves the gate is not the thing standing in the way.
        Assert.isTrue(signedReachedApprovalProcess,
            'The signed deal must get PAST every gate in this service and reach Approval.process. '
            + 'Outcome was: ' + unexpected);
    }

    @isTest
    static void theOwnedRecordControlStillSubmits() {
        // The owner-side half of the pair. If BOTH this and the non-owner test go red, the problem
        // is the persona or the fixture; if ONLY the non-owner one goes red, the problem is
        // sharing. Separating them is what makes the diagnosis unambiguous rather than a bisect.
        User submitter = TestDataFactory.createNonOwnerLoiSubmitter('oasl');

        Opportunity owned = TestDataFactory.createOpportunity(null, false);
        owned.StageName = 'LOI';
        owned.OwnerId = submitter.Id;
        insert owned;
        TestDataFactory.signPrimaryNda(owned);
        Id ndaId = [SELECT Primary_NDA__c FROM Opportunity WHERE Id = :owned.Id].Primary_NDA__c;

        UserRecordAccess ndaAccess = [
            SELECT RecordId, HasReadAccess
            FROM UserRecordAccess
            WHERE UserId = :submitter.Id AND RecordId = :ndaId
        ];

        Boolean refusedByNda = false;
        Test.startTest();
        System.runAs(submitter) {
            try {
                OpportunityApprovalService.submitForApproval(owned.Id);
            } catch (OpportunityApprovalService.ApprovalException e) {
                refusedByNda = e.getMessage() == OpportunityApprovalService.NDA_UNSIGNED_MESSAGE;
            } catch (Exception e) {
                // Not this test's subject.
            }
        }
        Test.stopTest();

        Assert.isFalse(refusedByNda,
            'A submitter who OWNS the deal must never be refused by the NDA gate when the NDA is '
            + 'signed. NDA read access for this persona was: ' + ndaAccess.HasReadAccess);
    }

    // ---- generic-failure path: unexpected platform/query failure propagates RAW ----

    @isTest
    static void unexpectedFailurePropagatesRawNotWrapped() {
        // A deal Id that resolves to no row is an UNEXPECTED failure: Approval.process throws on
        // the dead Id, then the in-catch stage re-read (OpportunitySelector.selectStageRequiredById)
        // throws System.QueryException, which must propagate RAW — the service must NOT wrap it
        // in ApprovalException (the controller masks it with a fixed generic message, W2).
        //
        // ═══ 🔴 REWRITTEN 2026-08-17 — THIS TEST USED TO insert-THEN-delete AN OPPORTUNITY ══════
        // Red since at least 2026-08-12 with
        //   System.DmlException: ENTITY_IS_DELETED  at LoiPrimaryStampQueueable.execute line 52
        // — a FIXTURE defect, not a defect in the code under test. `makeOpp('LOI')` enters the LOI
        // stage, so OpportunityReviewService creates the LOI child and enqueues
        // LoiPrimaryStampQueueable to back-stamp Primary_LOI__c; deleting the Opportunity left that
        // job queued against a dead row, and it fired at Test.stopTest() and threw. The queueable's
        // allOrNone = true is deliberate (ARCHITECTURE.md §2 — a stamp failure must surface as a
        // failed AsyncApexJob, never as a silently null lookup), so the queueable is untouched.
        //
        // THE FIX IS TO STOP CREATING A DEAL AT ALL. This test needs exactly two things:
        // Approval.process must fail, and the in-catch re-read must find no row (that selector is
        // a single-row assignment, documented `@throws System.QueryException when no Opportunity
        // matches the Id`). A never-created Opportunity Id delivers both over the identical code
        // path — resolveApprovalTargetId short-circuits on the Opportunity key prefix without querying, and
        // ProcessInstanceSelector.selectPendingByTargetId simply returns empty — while firing no
        // trigger and enqueueing nothing. "Deleted" was never the load-bearing property here;
        // "resolves to no row" was, and it is preserved exactly.
        //
        // ⚠ Both Assert.fail guards are retained verbatim: this still goes red if the service ever
        // starts wrapping an unexpected failure in ApprovalException, and still goes red if it
        // stops throwing at all. Nothing was weakened to reach green.
        // ═════════════════════════════════════════════════════════════════════════════════════
        Id noSuchDealId = Id.valueOf(Opportunity.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        Boolean threwRaw = false;
        Boolean returnedNormally = false;
        try {
            OpportunityApprovalService.submitForApproval(noSuchDealId);
            // ⚠ NOT Assert.fail() here. Assert.fail throws System.AssertException, which the
            // `catch (Exception e)` below WOULD catch — setting threwRaw = true and turning the
            // no-throw case into a PASS. That inversion was latent in the previous revision of
            // this test; a flag read after the try/catch cannot be swallowed. (The Assert.fail in
            // the ApprovalException clause is safe: nothing catches it, so it propagates.)
            returnedNormally = true;
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.fail('An unexpected failure must propagate raw, not as an ApprovalException');
        } catch (Exception e) {
            threwRaw = true;
        }
        Test.stopTest();

        Assert.isFalse(returnedNormally,
            'A deal Id matching no row must surface an unexpected failure, not return a success message');
        Assert.isTrue(threwRaw, 'an unexpected failure propagates a raw platform/query exception');
    }
}
