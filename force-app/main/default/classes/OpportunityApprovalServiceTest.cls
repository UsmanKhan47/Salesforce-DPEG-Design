/**
 * Tests OpportunityApprovalService — the approval-submission orchestration extracted from
 * OpportunityApprovalController in the W3 controller-thinning fix.
 *
 * Covers every resolveDealId branch (Opportunity / LOI / Underwriting / Contract Review /
 * unsupported), every user-actionable path that raises the TYPED ApprovalException (no
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

    // ---- happy paths (try/return + resolveDealId branches) ----

    @isTest
    static void submitsEligibleOpportunityDirectly() {
        Opportunity o = makeOpp('LOI');

        Test.startTest();
        String msg = OpportunityApprovalService.submitForApproval(o.Id);
        Test.stopTest();

        Assert.areEqual('The deal has been submitted for approval.', msg,
            'An eligible deal returns the confirmation message');
        Assert.areEqual(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'A pending approval instance exists after submit');
    }

    @isTest
    static void submitsFromUnderwritingRecordResolvesParent() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        o.Underwriting_Complete__c = true;
        insert o; // stage entry auto-creates the Underwriting record
        Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :o.Id];

        Test.startTest();
        String msg = OpportunityApprovalService.submitForApproval(uw.Id);
        Test.stopTest();

        Assert.areEqual('The deal has been submitted for approval.', msg, 'Confirmation returned');
        Assert.areEqual(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id AND Status = 'Pending'],
            'Submitting from the Underwriting record routes the PARENT deal into approval');
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
        // A deal at neither Underwriting nor LOI meets no entry criteria -> Approval.process
        // throws -> the catch re-reads the stage and raises the friendly ApprovalException.
        Opportunity o = makeOpp('Under Review');

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(o.Id);
            Assert.fail('A deal that meets no entry criteria should throw');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.isNotNull(e.getMessage(), 'no-applicable-process raises a typed ApprovalException');
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
            // Proves resolveDealId routed the Contract Review submission to its PARENT deal:
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
        // path — resolveDealId short-circuits on the Opportunity key prefix without querying, and
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
