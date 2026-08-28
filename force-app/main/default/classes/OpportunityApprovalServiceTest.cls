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
 * ── ⚠ WHAT THESE TESTS CAN AND CANNOT PROVE TODAY (2026-08-28) ───────────────────────────────
 * The principal approval moved onto Underwriting__c, but the Underwriting__c.Underwriting_Approval
 * PROCESS is owned by the parallel declarative stream and is not deployed yet. An Apex test cannot
 * conjure an approval process, so nothing here can assert a ProcessInstance whose TargetObjectId
 * is an underwriting record.
 *
 * That is a narrower limitation than it sounds, and it is deliberately NOT worked around with a
 * conditional assertion (which would go vacuously green the moment the process lands). Every test
 * below asserts something that is TRUE AND SENSITIVE IN BOTH STATES:
 *   - the routing table itself, asserted directly against resolveApprovalTargetId (@TestVisible),
 *     which needs no approval process at all and is the actual unit under change;
 *   - the NEGATIVE that matters most — that submitting an underwriting NEVER creates a
 *     ProcessInstance against its PARENT. That count is 0 today because resolution goes to the
 *     child, and it stays 0 forever after. It was 1 before this change.
 * The positive end-to-end (a pending instance targeting the underwriting record) is post-deploy
 * check P-1 in agent-output/design-requirements.md §8, not an Apex test.
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
     * exists to stop, so the old test is not repaired, it is reversed.
     *
     * The assertion is the parent-side NEGATIVE (see the class header): zero ProcessInstance
     * against the Opportunity. Under the old resolver this count was 1.
     */
    @isTest
    static void submitsFromUnderwritingRecordTargetsTheUnderwritingItself() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        o.Underwriting_Complete__c = true;
        insert o; // stage entry auto-creates the Underwriting record
        Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :o.Id];

        Assert.areEqual(uw.Id, OpportunityApprovalService.resolveApprovalTargetId(uw.Id),
            'An Underwriting record is its OWN approval target — not its parent deal');

        // The submission itself cannot complete until the declarative stream deploys
        // Underwriting__c.Underwriting_Approval, so it raises. What matters is WHICH raise, and
        // above all that the parent was never submitted anywhere.
        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(uw.Id);
        } catch (Exception e) {
            // Intentionally tolerant of the exception TYPE only. The auto-created underwriting is
            // at Stage__c = 'Requested', so today this is the typed "submit from In Progress"
            // guard; once the approval process is live and the record is walked to 'In Progress'
            // it becomes a successful submission. Neither outcome may create the instance below.
        }
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
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
     * ⚠ THIS TEST IS SENSITIVE TODAY AND STAYS SENSITIVE. It does NOT depend on the new
     * Underwriting approval process existing: LOI_Approval is live NOW, the parent genuinely
     * satisfies its entry criteria, and reverting resolveApprovalTargetId's Underwriting branch
     * turns this red immediately.
     */
    @isTest
    static void underwritingWithParentAtLoiNeverEntersLoiApproval() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        insert o; // stage entry auto-creates the Underwriting record
        Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :o.Id];

        // Move the PARENT to LOI — the stage at which LOI_Approval's entry criteria are met.
        TestDataFactory.signPrimaryNda(o);
        TestDataFactory.approveUnderwriting(o);
        o.StageName = 'LOI';
        update o;
        Assert.areEqual('LOI', [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Fixture precondition: the parent must really be at LOI, or this test proves nothing');

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(uw.Id);
        } catch (Exception e) {
            // See sibling test — the type is not the point here.
        }
        Test.stopTest();

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
     * ── 🔴 DELIBERATE TRIPWIRE. THIS TEST IS WRITTEN TO GO RED, ON PURPOSE, LATER. ─────────────
     *
     * Open item (b) — an Opportunity submitted at StageName = 'Underwriting' must be refused with
     * a message NAMING THE REAL ROUTE (UNDERWRITING_MOVED_MESSAGE), instead of falling through to
     * the controller's useless generic mask.
     *
     * THAT BRANCH IS UNREACHABLE TODAY AND CANNOT BE TESTED YET. The refusal only happens when
     * Approval.process FAILS, and Opportunity.Underwriting_Approval is STILL ACTIVE in the org —
     * its entry criterion is exactly StageName = 'Underwriting', so the submission SUCCEEDS. The
     * new branch begins working the instant the declarative stream runs execution-order step 9
     * (deactivate that process). Nothing in Apex can simulate that.
     *
     * A conditional "if the process is gone, assert the message; otherwise pass" would go
     * VACUOUSLY GREEN forever and quietly retire the requirement. So this asserts the CURRENT
     * reality instead, with a precondition that inverts the moment the world changes:
     *
     *   🔴 WHEN THIS TEST FAILS WITH "Expected: 1, Actual: 0", NOTHING IS BROKEN. It means
     *      Opportunity.Underwriting_Approval has been deactivated as planned. DELETE this method
     *      and paste in the real one, which is written out below and is ready to use verbatim:
     *
     *      @isTest
     *      static void submittingTheOpportunityAtUnderwritingNamesTheRealRoute() {
     *          Opportunity o = makeOpp('Underwriting');
     *          Test.startTest();
     *          try {
     *              OpportunityApprovalService.submitForApproval(o.Id);
     *              Assert.fail('An Opportunity at Underwriting meets no approval entry criteria');
     *          } catch (OpportunityApprovalService.ApprovalException e) {
     *              Assert.isTrue(e.getMessage().contains('Underwriting record'),
     *                  'The refusal must point the submitter at the Underwriting record, got: '
     *                      + e.getMessage());
     *              Assert.isTrue(e.getMessage().contains('Submit for Approval'),
     *                  'The refusal must name the action to use, got: ' + e.getMessage());
     *          }
     *          Test.stopTest();
     *          Assert.areEqual(0,
     *              [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
     *              'No approval instance may be created — it must not land in LOI_Approval');
     *      }
     *
     *   ⚠ Note what that replacement asserts: THE MESSAGE, not merely "it threw". Before this
     *     change the same call also threw (it fell through to `throw e` and the controller masked
     *     it as "The deal could not be submitted for approval. Refresh the page or contact your
     *     administrator."). A test asserting only that an exception occurred would pass against
     *     exactly the useless behaviour this whole change exists to remove.
     */
    @isTest
    static void opportunityAtUnderwritingStillUsesTheLegacyProcess_TRIPWIRE() {
        Opportunity o = makeOpp('Underwriting');

        Test.startTest();
        OpportunityApprovalService.submitForApproval(o.Id);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'TRIPWIRE (not a defect): this asserts the LEGACY Opportunity.Underwriting_Approval '
                + 'is still active. A count of 0 means it has been deactivated — replace this '
                + 'method with submittingTheOpportunityAtUnderwritingNamesTheRealRoute, written '
                + 'out verbatim in this method\'s doc comment.');
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
