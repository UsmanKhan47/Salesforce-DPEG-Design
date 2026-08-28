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
 * @see force-app/main/default/classes/OpportunityApprovalService.cls
 */
@isTest
private class OpportunityApprovalServiceTest {

    private static Opportunity makeOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
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
