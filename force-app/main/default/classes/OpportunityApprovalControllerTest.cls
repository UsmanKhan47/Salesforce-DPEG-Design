/**
 * Tests OpportunityApprovalController — the thin @AuraEnabled boundary over
 * OpportunityApprovalService (W3 controller-thinning fix). The happy paths prove delegation
 * is transparent (an eligible Opp submits into the approval process, resolving from a child
 * record where needed); the negative paths prove the boundary maps failures to an
 * AuraHandledException. Both catch branches are covered: a user-actionable
 * OpportunityApprovalService.ApprovalException is surfaced (the null / orphan / already-pending
 * / ineligible-stage / unsupported-object tests), and an UNEXPECTED failure maps to the fixed
 * generic SUBMIT_FAILURE_MESSAGE with no raw platform text leaked (submitFailureMapsToGenericMessage,
 * code-review W2). Per the task, negative tests assert only that an AuraHandledException is
 * thrown — never its message.
 */
@isTest
private class OpportunityApprovalControllerTest {

    /**
     * An inserted deal at the LOI stage WITH ITS PRIMARY NDA SIGNED.
     *
     * ⚠ THE SIGNING WAS ADDED 2026-08-30 AND IS A FIXTURE FIX, NOT A BEHAVIOUR CHANGE.
     * `OpportunityApprovalService.submitForApproval` now refuses an LOI-stage submission whose
     * primary NDA is blank or unsigned (design Item 3), so a deal inserted straight at LOI with no
     * NDA is no longer submittable. It never should have been: `NDA_Signed_Before_Deal_Progression`
     * blocks ENTRY to LOI without a signed NDA and this fixture only slipped past it because that
     * rule is `ISCHANGED(StageName)`-gated and therefore false on insert. Every test here is about
     * the CONTROLLER's delegation and error mapping, so the fixture must represent a deal that is
     * otherwise submittable — otherwise the "happy path" tests would be measuring the NDA refusal.
     *
     * ⚠ The gate's own coverage lives in `OpportunityApprovalServiceTest`, where the refusal
     * belongs. Do not add an NDA case here; this class must not start testing the service.
     *
     * @return The inserted, submittable deal.
     */
    private static Opportunity makeOpp() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        TestDataFactory.signPrimaryNda(o);
        return o;
    }

    @isTest
    static void submitsEligibleOpp() {
        Opportunity o = makeOpp();
        Test.startTest();
        String msg = OpportunityApprovalController.submitForApproval(o.Id);
        Test.stopTest();

        System.assertNotEquals(null, msg, 'A success message should be returned');
        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'A pending approval instance should exist after submit');
    }

    @isTest
    static void secondSubmitThrows() {
        Opportunity o = makeOpp();
        OpportunityApprovalController.submitForApproval(o.Id);

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(o.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Submitting an already-pending deal should throw');
    }

    @isTest
    static void ineligibleStageThrows() {
        // A deal at neither Underwriting nor LOI meets no entry criteria ->
        // Approval.process throws -> the catch branch surfaces a friendly error.
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Under Review';
        insert o;

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(o.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Submitting a deal that meets no entry criteria should throw');
    }

    /**
     * ⚠ INVERTED 2026-08-28, mirroring
     * OpportunityApprovalServiceTest.submitsFromUnderwritingRecordTargetsTheUnderwritingItself.
     * It asserted that submitting from an Underwriting record put the PARENT DEAL into approval;
     * that is the behaviour this change removes, so the assertion is reversed rather than fixed.
     *
     * Controller-level angle: a refusal must arrive as an AuraHandledException (the LWC boundary
     * contract), never as a raw platform error, and the parent must be untouched either way.
     */
    @isTest
    static void submitsFromUnderwritingRecordNeverSubmitsTheParent() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        o.Underwriting_Complete__c = true;
        insert o; // stage entry auto-creates the Underwriting record
        Underwriting__c uw = [SELECT Id FROM Underwriting__c WHERE Opportunity__c = :o.Id];

        // The auto-created underwriting is at Stage__c = 'Requested', so the submission is refused
        // by the "submit from In Progress" guard. Once the declarative stream deploys
        // Underwriting__c.Underwriting_Approval and the record is walked to 'In Progress', this
        // becomes a success — the ProcessInstance assertion below holds in BOTH cases.
        Test.startTest();
        try {
            OpportunityApprovalController.submitForApproval(uw.Id);
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage(),
                'A refusal must reach the LWC as an AuraHandledException with a message');
        }
        Test.stopTest();

        System.assertEquals(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'Submitting from the Underwriting record must NEVER submit the parent deal');
    }

    @isTest
    static void submitsFromLoiRecord() {
        Opportunity o = makeOpp(); // Stage = LOI
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);

        Test.startTest();
        OpportunityApprovalController.submitForApproval(loi.Id);
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id AND Status = 'Pending'],
            'Submitting from the LOI record routes the PARENT deal into approval');
    }

    @isTest
    static void unlinkedChildThrows() {
        LOI__c orphan = TestDataFactory.createLoi(null, false);
        orphan.Offer_Price__c = 500000;
        insert orphan;

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(orphan.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'An LOI with no parent deal cannot be submitted');
    }

    @isTest
    static void nullRecordThrows() {
        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(null);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'A null record id should throw');
    }

    @isTest
    static void resolvesDealFromContractReviewRecord() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Under Contract (PSA)';
        insert o; // stage entry auto-creates a Contract_Review__c
        Contract_Review__c cr = [SELECT Id FROM Contract_Review__c WHERE Opportunity__c = :o.Id LIMIT 1];

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(cr.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        // Proves resolveApprovalTargetId routes a Contract Review submission to its PARENT deal:
        // PSA meets neither approval process's entry criteria, so the no-applicable-process
        // branch throws (not the "not linked to a deal" error), proving the parent
        // Opportunity was resolved correctly before Approval.process ever ran.
        System.assert(threw, 'A deal at PSA meets no approval entry criteria');
        System.assertEquals(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'No pending approval should be created for an ineligible stage');
    }

    @isTest
    static void unsupportedObjectThrows() {
        Contact c = TestDataFactory.createContact(null, true);

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(c.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Submit for Approval is not available on an unsupported object type');
    }

    @isTest
    static void submitFailureMapsToGenericMessage() {
        // An UNEXPECTED failure (a deal Id that resolves to no row) must surface the fixed generic
        // message, not raw platform text: the service lets the QueryException propagate raw and
        // the controller's generic catch maps it to SUBMIT_FAILURE_MESSAGE (code-review W2). Do
        // not assert the message text (AuraHandledException.getMessage() is unreliable in tests)
        // — only that an AuraHandledException is thrown via the generic catch.
        //
        // ═══ 🔴 REWRITTEN 2026-08-17 — THIS TEST USED TO insert-THEN-delete AN OPPORTUNITY ══════
        // It had been red since at least 2026-08-12 with
        //   System.DmlException: ENTITY_IS_DELETED  at LoiPrimaryStampQueueable.execute line 52
        // and the failure was in the FIXTURE, not in the code under test. Inserting an Opportunity
        // at StageName = 'LOI' enters the LOI stage, so OpportunityReviewService creates the LOI
        // child and enqueues LoiPrimaryStampQueueable to back-stamp Primary_LOI__c. Deleting the
        // Opportunity left that job queued against a dead row; it fired at Test.stopTest() and its
        // `Database.update(stamps, true, AccessLevel.SYSTEM_MODE)` threw. The queueable is CORRECT
        // — allOrNone = true is deliberate so a stamp failure surfaces as a failed AsyncApexJob
        // rather than a silently null Primary_LOI__c (ARCHITECTURE.md §2) — so it must not change.
        //
        // THE FIX IS TO STOP CREATING A DEAL AT ALL. What this test needs is only that
        // Approval.process fails AND the service's in-catch stage re-read
        // (OpportunitySelector.selectStageRequiredById, a single-row assignment documented
        // `@throws System.QueryException when no Opportunity matches the Id`) finds no row. A
        // never-created Opportunity Id delivers BOTH, over the byte-identical code path, and fires
        // no trigger, creates no LOI and enqueues nothing — so there is no orphaned job to explode.
        // "Deleted" was never the load-bearing property; "resolves to no row" was.
        //
        // ⚠ Nothing here is swallowed or softened: the assertion is unchanged, and if the
        // controller ever stopped mapping an unexpected failure to an AuraHandledException the
        // raw QueryException would escape this narrow catch and fail the method, exactly as before.
        // ═════════════════════════════════════════════════════════════════════════════════════
        Id noSuchDealId = Id.valueOf(Opportunity.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(noSuchDealId);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'An unexpected submission failure maps to an AuraHandledException');
    }

    /**
     * The server-side permission assertion (design doc F5). Submitting a deal into the principal
     * approval is a deal-driver action — Deal_Driver__c's own description names "Submit for Approval
     * on Underwriting/LOI" — but until this existed the only gate was the Dynamic Actions visibility
     * rule, which a direct @AuraEnabled call bypasses entirely.
     *
     * Asserts the denial WORDING (unlike the sibling negative tests, which assert only that a throw
     * happened): the AccessDeniedException clause is ordered ahead of the generic catch precisely so
     * a denial is not masked as SUBMIT_FAILURE_MESSAGE, and only a message assertion can prove the
     * ordering is right.
     *
     * MIXED DML: the test needs a non-setup Opportunity and a setup User in one transaction, so the
     * User insert is wrapped in System.runAs(<the current user>) to open a fresh DML context.
     */
    @isTest
    static void refusesAUserWhoIsNotADealDriver() {
        Opportunity o = makeOpp();            // Stage = LOI, i.e. otherwise eligible
        Id dealId = o.Id;
        User bareUser = buildStandardUser('oacT');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert bareUser;
        }

        Test.startTest();
        Boolean refused = false;
        OpportunityActionPermissionService.clearCache();
        System.runAs(bareUser) {
            try {
                OpportunityApprovalController.submitForApproval(dealId);
            } catch (AuraHandledException e) {
                refused = true;
                Assert.areEqual(OpportunityActionPermissionService.NO_PERMISSION_MESSAGE, e.getMessage(),
                    'A denial must surface the agreed permission wording, NOT the generic submit-failure '
                    + 'message — the AccessDeniedException catch is ordered ahead of the generic one for '
                    + 'exactly this reason');
            }
        }
        OpportunityActionPermissionService.clearCache();
        Test.stopTest();

        Assert.isTrue(refused, 'A non-deal-driver must be refused even on an otherwise eligible deal');
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :dealId],
            'A refused submission must create NO approval instance — the assert must run before '
            + 'Approval.process, not after it');
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
            LastName = 'OppAppr',
            Alias = 'oappr',
            Email = 'std.oppappr@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
