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
 *
 * ══ ⚠ W5, 2026-09-01: THE TWO HAPPY PATHS NOW SUBMIT AN `LOI__c`, NOT AN `Opportunity` ═══════
 * `approvalProcesses/Opportunity.LOI_Approval` is DEACTIVATED, leaving ZERO active approval
 * processes on `Opportunity`, so `submitsEligibleOpp` and `secondSubmitThrows` both failed with
 * `AuraHandledException: LOI approval runs on the LOI record...`. They were repointed onto the LOI
 * (`submitsEligibleOpp` -> `submitsEligibleLoi`); see each method's docstring.
 * 🔴 NEITHER WAS ON ANY "SCHEDULED TO GO RED" LIST — not the design pack's §6.1, not the markers
 * in `OpportunityApprovalServiceTest`'s header. Both broke on a FIXTURE line (`makeOpp()` then
 * submit), not on an assertion encoding old behaviour, and that is the blind spot those lists
 * share: they enumerate tests that ASSERT the old behaviour, never tests that merely USE it to
 * build a fixture. Only running the suite finds the second kind.
 * ⚠ The NEGATIVE tests below still submit an Opportunity and still pass — they expect a throw, and
 * they still get one (a different one). Their green is therefore weaker than it looks: several now
 * pass because the process is retired rather than because of the condition they name. Do not read
 * them as evidence about the stage/orphan/unsupported branches without checking which exception
 * actually arrived.
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

    /**
     * An acquisition LOI parked at the stage its own approval accepts, under `deal`.
     *
     * ══ 🔴 ADDED AT W5, 2026-09-01, BECAUSE THE HAPPY PATH HAD TO MOVE OFF THE OPPORTUNITY ══
     * `approvalProcesses/Opportunity.LOI_Approval` is DEACTIVATED, so there are now ZERO active
     * approval processes on `Opportunity` and no Opportunity submission can succeed by any route.
     * The two happy-path tests below therefore had to be repointed onto the LOI — which is also
     * the only path a human can now take, so they test more than they did before.
     *
     * ⚠ IT CREATES ITS OWN LOI RATHER THAN USING THE ONE `OpportunityReviewService` AUTO-CREATES
     * on entry to the LOI stage, and that is load-bearing rather than convenience: the auto-created
     * one is owned by the `Acquisition` QUEUE, and `LOI__c.LOI_Approval` declares
     * `allowedSubmitters type=owner`, so a submission of the auto-created LOI is refused by the
     * PLATFORM before entry criteria are considered — green for the wrong reason. Same fixture
     * shape, and same reasoning, as `OpportunityApprovalServiceTest.makeSubmittableLoi`.
     *
     * @param deal The parent deal (from `makeOpp()`, so its primary NDA is signed and the
     *             service's NDA gate passes).
     * @return The inserted LOI, at 'Under Review', owned by the test-running user.
     */
    private static LOI__c makeSubmittableLoi(Opportunity deal) {
        LOI__c loi = TestDataFactory.createLoi(deal.Id, true);
        update new LOI__c(Id = loi.Id, Stage__c = 'Under Review');
        return loi;
    }

    /**
     * ⚠ REPOINTED ONTO THE LOI AT W5, 2026-09-01. Was `submitsEligibleOpp`, submitting an
     * Opportunity at 'LOI'. That succeeded only while `Opportunity.LOI_Approval` was active.
     *
     * 🔴 THIS CLASS WAS NOT ON ANY "SCHEDULED TO GO RED" LIST — not the design pack's §6.1, not
     * the markers in `OpportunityApprovalServiceTest`'s header. It was found by RUNNING the suite
     * after the W5 deploy, which is the only check that would have caught it: both failures here
     * are fixture lines (`makeOpp()` + submit) rather than assertions encoding old behaviour.
     *
     * The test's JOB is unchanged — prove the controller's delegation is TRANSPARENT on the happy
     * path — and it is now proven on the live path instead of a retired one.
     */
    @isTest
    static void submitsEligibleLoi() {
        Opportunity o = makeOpp();
        LOI__c loi = makeSubmittableLoi(o);

        Test.startTest();
        String msg = OpportunityApprovalController.submitForApproval(loi.Id);
        Test.stopTest();

        System.assertNotEquals(null, msg, 'A success message should be returned');
        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :loi.Id],
            'A pending approval instance should exist on the LOI after submit');
        System.assertEquals(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'and NOTHING may land on the parent deal — Opportunity.LOI_Approval is retired');
    }

    /**
     * ⚠ REPOINTED ONTO THE LOI AT W5, 2026-09-01, for the same reason as `submitsEligibleLoi`:
     * its first line built the fixture by submitting an Opportunity, which now throws.
     *
     * 🔴 THE GUARD MATTERS MORE ON THIS PATH THAN IT DID ON THE OLD ONE. The LOI page's
     * `LOI_Status__c NE 'Pending Approval'` visibility criterion is INERT (nothing in production
     * writes that value), so the Submit button STAYS VISIBLE after a submission and a second click
     * is refused in Apex or not at all.
     */
    @isTest
    static void secondSubmitThrows() {
        Opportunity o = makeOpp();
        LOI__c loi = makeSubmittableLoi(o);
        OpportunityApprovalController.submitForApproval(loi.Id);

        System.assertEquals(1, [
            SELECT COUNT() FROM ProcessInstance
            WHERE TargetObjectId = :loi.Id AND Status = 'Pending'
        ], 'FIXTURE PRECONDITION: the FIRST submission must really have created a pending instance, '
            + 'or the assertion below passes for the wrong reason.');

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(loi.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Submitting an already-pending LOI should throw');
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

    /**
     * ⚠ INVERTED 2026-09-01 (W4 of the LOI approval cutover). It asserted that submitting from an
     * LOI put the PARENT DEAL into approval; the LOI now submits ITSELF, which is the whole point
     * of that change, so the old assertion was reversed rather than repaired. The service-level
     * twin, with the full reasoning, is
     * `OpportunityApprovalServiceTest.submitsFromLoiRecordTargetsTheLoiItself`.
     *
     * ⚠ `Stage__c` IS DRIVEN TO 'Under Review' — the factory inserts an acquisition LOI at
     * 'Draft', and `LOI__c.LOI_Approval`'s entry criteria are Stage = 'Under Review' AND record
     * type Acquisition_LOI.
     *
     * 🔴 IT ASSERTS ONLY THE NEGATIVE, BECAUSE `LOI__c.LOI_Approval` CURRENTLY ACCEPTS NOTHING.
     * Measured 2026-09-01: an LOI satisfying its entry criteria literally still gets
     * NO_APPLICABLE_PROCESS, and zero ProcessInstances exist against that definition. The cause is
     * in the approval process file (the org normalised the criterion field to `LOI__c.RecordType`
     * and kept an 18-character Id as its value; a `RecordType` criterion compares the record type
     * NAME). The full measurement is on
     * `OpportunityApprovalServiceTest.submitsFromLoiRecordTargetsTheLoiItself`.
     * ⇒ ADD THE POSITIVE ONCE THAT IS FIXED:
     *     System.assertEquals(1, [SELECT COUNT() FROM ProcessInstance
     *         WHERE TargetObjectId = :loi.Id AND Status = 'Pending'], ...);
     */
    @isTest
    static void submitsFromLoiRecord() {
        Opportunity o = makeOpp(); // Stage = LOI, primary NDA signed
        LOI__c loi = TestDataFactory.createLoi(o.Id, true);
        update new LOI__c(Id = loi.Id, Stage__c = 'Under Review');

        Test.startTest();
        try {
            OpportunityApprovalController.submitForApproval(loi.Id);
        } catch (AuraHandledException e) {
            // The controller masking a PLATFORM refusal is out of scope here; this test is about
            // WHICH RECORD the submission was aimed at.
        }
        Test.stopTest();

        System.assertEquals(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            '🔴 THE FALSIFIER. Nothing may land on the parent deal — and this deal WOULD be '
            + 'accepted by Opportunity.LOI_Approval (StageName = LOI, signed NDA, owned by the '
            + 'running user, process still active until W5), so reverting the routing puts an '
            + 'instance here immediately.');
    }

    /**
     * ⚠ REPOINTED FROM `LOI__c` TO `Contract_Review__c`, 2026-09-01 (W4), for the reason its
     * service-level twin `unlinkedContractReviewThrowsApprovalException` records: after the
     * repoint an orphan LOI resolves to ITSELF, so `targetId` is not null and the "not linked to
     * a deal" branch is never reached. 🔴 THIS TEST WOULD HAVE STAYED GREEN — the orphan LOI is
     * still refused, by a different line, for a different reason, and a bare `catch (Exception)`
     * cannot tell the two apart. `Contract_Review__c` is now the only child whose branch can
     * return null.
     */
    @isTest
    static void unlinkedChildThrows() {
        Contract_Review__c orphan = TestDataFactory.createContractReview(null, true);

        Test.startTest();
        Boolean threw = false;
        try {
            OpportunityApprovalController.submitForApproval(orphan.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'A Contract Review with no parent deal cannot be submitted');
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
