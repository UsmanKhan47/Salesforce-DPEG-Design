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
 * ── 🔴 W4 OF THE LOI APPROVAL CUTOVER (2026-09-01) — WHAT MOVED, AND WHAT WOULD HAVE GONE
 *      VACUOUS IF IT HAD NOT ────────────────────────────────────────────────────────────────
 * `resolveApprovalTargetId` now routes an `LOI__c` click to the LOI ITSELF
 * (`approvalProcesses/LOI__c.LOI_Approval`, active since W2) instead of to its parent deal. Six
 * tests here changed, and the reason each one changed is recorded at the method:
 *   RE-AIMED   `submitsFromLoiRecordResolvesParent` -> `submitsFromLoiRecordTargetsTheLoiItself`
 *              (inverted: it asserted the behaviour being removed)
 *   RE-AIMED   `unlinkedChildThrowsApprovalException` ->
 *              `unlinkedContractReviewThrowsApprovalException` (an orphan LOI no longer reaches
 *              that branch; Contract_Review__c is the only child that still can)
 *   RENAMED    `theNdaGateDoesNotFireAtAnyStageButLoi` ->
 *              `aDealAtANonLoiStageIsRefusedForItsStageNotItsNda` (the old NAME became false)
 *   REPOINTED  `secondSubmitThrowsApprovalException` onto the LOI (the guard's only live path)
 *   ASSERTIONS `resolveApprovalTargetIdRoutesEachObjectToItsApprovalTarget` and
 *              `ineligibleStageThrowsApprovalException` (routing table; refusal wording)
 * Four tests were ADDED: the LOI-target NDA gate group (unsigned, blank, and the two-hop sharing
 * axis) plus `anLoiWithNoParentDealSubmitsItselfAndSkipsTheNdaGate`.
 *
 * 🔴 THE POINT OF THAT LIST IS THE ONES THAT DID **NOT** HAVE TO CHANGE, BECAUSE THAT IS THE
 * TRAP. Every one of the five original signed-NDA tests submits an OPPORTUNITY. Had
 * `assertNdaSignedForLoiSubmission` been left pointing at Opportunity targets only — the exact
 * omission the design pack predicted — the gate would have stopped firing for every real
 * submission and ALL FIVE WOULD STILL BE GREEN. They are kept (the Opportunity branch is still
 * live for the escape hatch and for Contract_Review__c) but they are no longer evidence about the
 * button, and the four new tests are.
 *
 * ══ ✅ W5 APPLIED 2026-09-01 — `Opportunity.LOI_Approval` IS DEACTIVATED ════════════════════
 * ⚠ RETRACTED, VERBATIM: "TWO TESTS ARE SCHEDULED TO GO RED AT W5, BY DESIGN, AND ARE MARKED AT
 * THEIR DECLARATIONS: `submitsEligibleOpportunityDirectly` and `signedNdaAtLoiStillSubmits`."
 * W5 has run. There are now ZERO active approval processes on `Opportunity`, so NO Opportunity
 * submission can succeed by any route. FOUR tests changed, not two:
 *   INVERTED   `submitsEligibleOpportunityDirectly`
 *              -> `anOpportunityAtLoiIsNowRefusedAndSentToTheLoiRecord`. It now pins the
 *                 RETIREMENT: reactivating the old process (a one-line redeploy) reds it, and
 *                 nothing else in the suite would notice.
 *   REPOINTED  `signedNdaAtLoiStillSubmits` -> `signedNdaAtLoiIsNotRefusedByTheNdaGate`. Same job
 *                 (positive control for the two NDA refusals), new evidence — see its docstring.
 *   REPOINTED  `aSubmitterWhoCannotSeeTheNdaIsNotFalselyBlocked`'s internals. Its discriminator
 *                 was the exception TYPE and is now the exception MESSAGE.
 *   🔴 REPOINTED `secondSubmitThrowsApprovalException` ONTO THE LOI — **AND IT WAS NOT ON ANYONE'S
 *                 LIST**. Its first line submitted an Opportunity OUTSIDE any try, purely to build
 *                 the fixture, so W5 broke it before it reached its subject. Neither the two
 *                 markers above nor the design pack's §6.1 named it.
 *
 * 🔴 THE LESSON, AND IT IS THE REUSABLE PART: "TESTS SCHEDULED TO GO RED" MARKERS ARE NOT AN
 * INVENTORY. They catch the tests whose ASSERTIONS encode the old behaviour; they miss the ones
 * that merely USE the old behaviour to build a fixture. The reliable check is to trace every
 * `submitForApproval` call site that passes an Opportunity Id — including the ones outside a
 * try/catch, which are the easiest to overlook and the loudest when they break.
 *
 * ⚠ TWO TESTS IN `LoiGateTest` GO RED AND ARE **NOT** FIXED HERE — see this deploy's report.
 * `firstResponseApprovalStampsLoiAuditTrail` and `rejectionReturnsDealToUnderwriting` both submit
 * an Opportunity into the now-retired process. They are out of W5's authorised scope (a repoint
 * there is a coverage decision, not a mechanical fix: the LOI-side chain they assert is already
 * covered by `LoiApprovalStampServiceTest`). Do not "fix" them by deletion.
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
     * The `LOI__c.Stage__c` value `approvalProcesses/LOI__c.LOI_Approval` accepts, together with
     * record type Acquisition_LOI. Duplicated from the service's own private constant on purpose:
     * a test that imported the constant could not tell "the service and the process agree" from
     * "the service and the test agree".
     */
    private static final String LOI_STAGE_UNDER_REVIEW = 'Under Review';

    /**
     * An acquisition LOI parked at the stage its own approval accepts, under `deal`.
     *
     * ⚠ IT CREATES ITS OWN LOI RATHER THAN USING THE ONE `OpportunityReviewService` AUTO-CREATES
     * on entry to the LOI stage, and that is load-bearing rather than convenience: the
     * auto-created one is owned by the `Acquisition` QUEUE, and `LOI__c.LOI_Approval` declares
     * `allowedSubmitters type=owner`. The test-running user is not a member of that queue, so a
     * submission of the auto-created LOI is refused by the PLATFORM before entry criteria are
     * considered — a green-for-the-wrong-reason trap, and the same one
     * `aSubmitterWhoCannotSeeTheNdaIsNotFalselyBlocked` records for the Opportunity side.
     *
     * @param deal The parent deal.
     * @return The inserted LOI, at 'Under Review', owned by the test-running user.
     */
    private static LOI__c makeSubmittableLoi(Opportunity deal) {
        LOI__c loi = TestDataFactory.createLoi(deal.Id, true);
        update new LOI__c(Id = loi.Id, Stage__c = LOI_STAGE_UNDER_REVIEW);
        return loi;
    }

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

    /**
     * ⚠ INVERTED AND RENAMED AT W5, 2026-09-01. Was `submitsEligibleOpportunityDirectly`, and it
     * asserted that an Opportunity at 'LOI' SUCCESSFULLY entered an approval. That was true only
     * while `approvalProcesses/Opportunity.LOI_Approval` was active, which W5 ended — so the test
     * was not repaired, it was REVERSED, exactly as
     * `submitsFromUnderwritingRecordTargetsTheUnderwritingItself` was at the equivalent point of
     * the underwriting cutover.
     *
     * 🔴 IT IS KEPT RATHER THAN DELETED BECAUSE THE NEW ASSERTION IS THE MORE VALUABLE ONE. It now
     * pins the RETIREMENT itself: if anyone reactivates `Opportunity.LOI_Approval` (the file says
     * DO NOT REACTIVATE, and reactivation is a one-line redeploy), this test goes red immediately.
     * Nothing else in the suite would notice.
     *
     * ⚠ IT ASSERTS THE EXACT MESSAGE, NOT A SUBSTRING, ON PURPOSE. `LOI_MOVED_MESSAGE` alone is
     * the 'LOI'-stage refusal; the non-'LOI' stages carry the same text PREFIXED with 'No approval
     * applies to this deal at the X stage. ' (see `ineligibleStageThrowsApprovalException`).
     * Exact equality is what keeps those two branches distinguishable.
     *
     * The live path this test used to represent is now `submitsFromLoiRecordTargetsTheLoiItself`.
     */
    @isTest
    static void anOpportunityAtLoiIsNowRefusedAndSentToTheLoiRecord() {
        Opportunity o = makeOpp('LOI');

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(o.Id);
            Assert.fail('W5 deactivated Opportunity.LOI_Approval — a deal at LOI must no longer '
                + 'enter any approval. If this line is reached, that process is ACTIVE again.');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.areEqual(OpportunityApprovalService.LOI_MOVED_MESSAGE, e.getMessage(),
                'A deal at LOI must be refused with the bare LOI_MOVED_MESSAGE, sending the '
                + 'submitter to the LOI record. Got: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'and NO approval instance may be created on the deal');
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
        // 🔴 THE LINE THE WHOLE W4 CHANGE COMES DOWN TO. It read, until 2026-09-01:
        //     Assert.areEqual(o.Id, fromLoi,
        //         'UNCHANGED: an LOI still resolves to its parent deal — LOI_Approval runs on the deal');
        // Routing the click to the deal is what blocked the deal driver: the deal's approval is
        // `allowedSubmitters type=owner` and the deal is owned by someone else.
        Assert.areEqual(loi.Id, fromLoi,
            'CHANGED 2026-09-01 (W4): an LOI is its OWN approval target. LOI_Approval now runs on '
            + 'the LOI record, not on the deal.');
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

    /**
     * 🔴 THE USER'S REQUEST, ASSERTED END TO END — *"Make sure that we must have approval on LOI
     * record page not on opportunity."*
     *
     * ⚠ INVERTED AND RENAMED 2026-09-01 (W4). Was `submitsFromLoiRecordResolvesParent`, and it
     * asserted the EXACT OPPOSITE of the required behaviour: that submitting from an LOI put the
     * PARENT DEAL into approval. That is what this change exists to stop, so — exactly as
     * `submitsFromUnderwritingRecordTargetsTheUnderwritingItself` records for its own cutover —
     * the old test was not repaired, it was reversed.
     *
     * ⚠ BOTH HALVES ARE LOAD-BEARING AND NEITHER IS REDUNDANT. The positive (an instance on the
     * LOI) proves the new process is reachable; the negative (none on the deal) proves the old
     * routing is gone. The negative alone would pass if the submission simply failed, and the
     * positive alone would pass if the submission landed on BOTH.
     *
     * ⚠ THE NEGATIVE IS NOT VACUOUS DURING THE W4 -> W5 WINDOW, WHICH IS PRECISELY WHEN IT IS
     * WORTH HAVING. `Opportunity.LOI_Approval` is STILL ACTIVE and the deal here really is at
     * StageName = 'LOI', which really is that process's entry criterion — so the wrong
     * destination is a live, reachable one and only the routing keeps the submission away from
     * it. Reverting `resolveApprovalTargetId`'s LOI branch reds this immediately. (After W5 it
     * weakens to "the old process is deactivated"; that is the same decay
     * `underwritingWithParentAtLoiNeverEntersLoiApproval` already carries and is noted there.)
     *
     * ══ 🔴 IT DOES NOT ASSERT THAT THE LOI ENTERS THE APPROVAL, AND THAT IS NOT A CHOICE —
     *      `LOI__c.LOI_Approval` CURRENTLY ACCEPTS NOTHING AT ALL. MEASURED 2026-09-01. ════════
     * A throwaway diagnostic (validate-only, run `0Afiw000000UrjdCAC` and successors) built an LOI
     * that satisfies the deployed entry criteria LITERALLY —
     *     Stage__c = 'Under Review', RecordTypeId = 012iw0000009yeXAAQ (= Acquisition_LOI),
     *     OwnerId = the submitting user (so `allowedSubmitters type=owner` is satisfied)
     * — called `Approval.process(req, false)` directly, and got
     *     success=false | NO_APPLICABLE_PROCESS: No applicable approval process was found.
     * Corroborated: `SELECT COUNT() FROM ProcessInstance WHERE ProcessDefinitionId =
     * '04aiw0000005ub3AAA'` returns **0** — nothing has ever entered this process since W2
     * activated it.
     * 🔴 THE CAUSE LIVES IN THE APPROVAL PROCESS FILE, NOT IN THIS CLASS OR IN ITS SERVICE. A
     * retrieve of the ORG's copy shows Salesforce normalised the criterion field
     * `LOI__c.RecordTypeId` to **`LOI__c.RecordType`** while keeping the 18-character Id as the
     * value — and a `RecordType` filter criterion compares against the record type's NAME
     * ("Acquisition LOI"), never its Id. The criterion is therefore permanently FALSE. The W2 file
     * records that this shape was proven by a CHECK-ONLY DRY-RUN, which is a deploy-time check and
     * says nothing about runtime evaluation; the design pack's own §8.5 says exactly that.
     * ⇒ 🔴 UPGRADE THIS TEST THE MOMENT THAT CRITERION IS FIXED. Add, and they are the real
     * acceptance criteria for the user's request:
     *     Assert.areEqual('The record has been submitted for approval.', msg, ...);
     *     Assert.areEqual(1, [SELECT COUNT() FROM ProcessInstance
     *                         WHERE TargetObjectId = :loi.Id AND Status = 'Pending'], ...);
     * Until then this test proves the ROUTING and the ABSENCE of a wrong-target submission, which
     * is everything W4 itself controls.
     */
    @isTest
    static void submitsFromLoiRecordTargetsTheLoiItself() {
        Opportunity o = makeOpp('LOI'); // signs the primary NDA — the gate now fires on this path
        LOI__c loi = makeSubmittableLoi(o);

        Assert.areEqual(loi.Id, OpportunityApprovalService.resolveApprovalTargetId(loi.Id),
            'THE ROUTING. An LOI is its own approval target.');

        Test.startTest();
        String refusal = null;
        try {
            OpportunityApprovalService.submitForApproval(loi.Id);
        } catch (OpportunityApprovalService.ApprovalException e) {
            refusal = e.getMessage();
        } catch (Exception e) {
            // The platform refusing the submission is OUT OF SCOPE for this test — see the
            // 🔴 block in the docstring. What matters is which record it was aimed at.
        }
        Test.stopTest();

        Assert.isNull(refusal,
            'No gate in this service may refuse a legitimate LOI submission. Got: ' + refusal);
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            '🔴 THE FALSIFIER. Nothing may land on the parent deal. This deal is at StageName = '
            + '\'LOI\' with a signed NDA and is owned by the running user, so '
            + 'Opportunity.LOI_Approval — still ACTIVE until W5 — would ACCEPT it. Reverting '
            + 'resolveApprovalTargetId\'s LOI branch to return the parent puts an instance here '
            + 'immediately.');
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

    /**
     * The "not linked to a deal" refusal, still pinned — but through the only child that still
     * resolves to a parent.
     *
     * ⚠ REPOINTED FROM `LOI__c` TO `Contract_Review__c`, 2026-09-01 (W4), AND RENAMED FROM
     * `unlinkedChildThrowsApprovalException`. 🔴 IT WOULD HAVE STAYED GREEN IF LEFT ALONE, WHICH
     * IS EXACTLY WHY IT HAD TO MOVE. After the repoint an orphan LOI resolves to ITSELF, so
     * `targetId` is no longer null and the branch this test names is never reached — the
     * submission instead fails at `Approval.process` and is refused by the catch's new LOI
     * stage derivation. A typed `ApprovalException` with a non-null message is still thrown, so
     * the old assertions would have passed while testing a completely different line.
     * `Contract_Review__c` is now the ONLY object whose branch can return null, so it is where
     * this coverage belongs. The LOI's new behaviour gets its own test below.
     */
    @isTest
    static void unlinkedContractReviewThrowsApprovalException() {
        Contract_Review__c orphan = TestDataFactory.createContractReview(null, true);

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(orphan.Id);
            Assert.fail('A Contract Review with no parent deal cannot be submitted');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.isNotNull(e.getMessage(), 'not-linked-to-a-deal raises a typed ApprovalException');
        }
        Test.stopTest();
    }

    /**
     * An LOI with no parent deal is no longer refused as "not linked to a deal" — it submits
     * ITSELF, and the signed-NDA gate is skipped because there is no deal to read an NDA from.
     *
     * ⚠ THIS IS A DELIBERATE CONSEQUENCE OF W4, NOT AN OVERSIGHT, and it is the identical
     * consequence the Underwriting cutover accepted and recorded in `resolveApprovalTargetId`'s
     * docstring: "the approval targets the child, which does not need a parent to be approved".
     * A blank `Opportunity__c` is a LEGAL state — the lookup is `SetNull`, and a sell-side LOI
     * hangs off `Disposition__c` instead.
     *
     * 🔴 IT ASSERTS THE SERVICE DOES NOT REFUSE, WHICH IS THE UNCOMFORTABLE HALF. A parentless
     * acquisition LOI at 'Under Review' is now allowed as far as `Approval.process`. If that is
     * ever judged wrong, the fix is a criterion in the approval process or a new guard — and this
     * test is where the decision is recorded, not a nuisance to delete.
     *
     * ⚠ IT DOES NOT ASSERT THE SUBMISSION SUCCEEDS, for the reason recorded on
     * `submitsFromLoiRecordTargetsTheLoiItself`: `LOI__c.LOI_Approval`'s record-type entry
     * criterion is currently unsatisfiable, so NO LOI enters it. Add
     * `Assert.areEqual(1, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :orphan.Id])`
     * once that is fixed.
     */
    @isTest
    static void anLoiWithNoParentDealIsNoLongerRefusedAsUnlinked() {
        LOI__c orphan = TestDataFactory.createLoi(null, false);
        orphan.Offer_Price__c = 500000;
        insert orphan; // no parent Opportunity
        update new LOI__c(Id = orphan.Id, Stage__c = LOI_STAGE_UNDER_REVIEW);

        Assert.areEqual(orphan.Id, OpportunityApprovalService.resolveApprovalTargetId(orphan.Id),
            'A parentless LOI resolves to ITSELF — it no longer resolves to a null parent');

        Test.startTest();
        String refusal = null;
        try {
            OpportunityApprovalService.submitForApproval(orphan.Id);
        } catch (OpportunityApprovalService.ApprovalException e) {
            refusal = e.getMessage();
        } catch (Exception e) {
            // The platform refusing the submission is out of scope; only a SERVICE refusal is.
        }
        Test.stopTest();

        Assert.isNull(refusal,
            'Neither the "not linked to a deal" refusal nor the NDA gate may fire for a '
            + 'parentless LOI: it submits itself, and there is no deal to read an NDA from. '
            + 'Got: ' + refusal);
    }

    /**
     * ✅ REPOINTED ONTO THE LOI AT W5, 2026-09-01, EXACTLY AS THIS DOCSTRING PREVIOUSLY INSTRUCTED.
     * ⚠ RETRACTED, VERBATIM:
     *     "IT STAYS ON THE OPPORTUNITY, AND THAT IS FORCED, NOT PREFERRED. ... This test was
     *      repointed onto the LOI for exactly that reason and then REVERTED, because the guard
     *      needs a FIRST submission to succeed and `LOI__c.LOI_Approval` currently accepts nothing
     *      ... 🔴 REPOINT IT ONTO THE LOI ONCE THAT ENTRY CRITERION IS FIXED."
     * The entry criterion IS fixed (the record-type criterion is now label-valued,
     * `LOI__c.RecordType equals 'Acquisition LOI'`), and it is PROVEN at runtime rather than by a
     * green deploy: `LOI__c.LOI_Approval` holds a real Approved ProcessInstance
     * (04giw0000003Yzd, on an LOI__c target, 2026-09-01). So the blocker named above is gone.
     *
     * 🔴 IT WAS ALSO NO LONGER OPTIONAL — THIS TEST WAS A W5 CASUALTY THAT NOBODY LISTED. Its
     * first line submitted an OPPORTUNITY at 'LOI' OUTSIDE any try, purely to create the pending
     * instance the guard needs. W5 deactivated `Opportunity.LOI_Approval`, so that line now throws
     * `ApprovalException(LOI_MOVED_MESSAGE)` and the whole test errors before reaching its subject.
     * It is not in the design pack's §6.1 list and it is not in the two "scheduled to go red"
     * markers in this class's header — it was found by tracing every `submitForApproval` call site
     * that passes an Opportunity Id, which is the check those lists are a substitute for.
     *
     * 🟢 THE REPOINT IS A STRICT UPGRADE, NOT DAMAGE CONTROL. Two things improve: the guard is now
     * tested on the path a human can actually take (the LOI button), and the test stops depending
     * on any Opportunity approval being active, so it is no longer fragile to this class of
     * change. That matters more than it sounds: the page's `LOI_Status__c NE 'Pending Approval'`
     * visibility criterion is INERT (nothing in production writes that value), so after a
     * submission the button STAYS VISIBLE and a second click is refused HERE, in Apex, or not at
     * all. This is the only thing standing between a double-click and a duplicate submission.
     */
    @isTest
    static void secondSubmitThrowsApprovalException() {
        Opportunity o = makeOpp('LOI');       // signs the primary NDA — the gate fires on this path
        LOI__c loi = makeSubmittableLoi(o);   // Acquisition_LOI, 'Under Review', owned by the runner
        OpportunityApprovalService.submitForApproval(loi.Id); // first -> now pending

        Assert.areEqual(1, [
            SELECT COUNT() FROM ProcessInstance
            WHERE TargetObjectId = :loi.Id AND Status = 'Pending'
        ], 'FIXTURE PRECONDITION: the FIRST submission must really have created a pending instance '
            + 'on the LOI. If this fails, LOI__c.LOI_Approval is not accepting the submission and '
            + 'the duplicate-pending assertion below would pass for the wrong reason.');

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(loi.Id); // second -> already pending
            Assert.fail('Submitting an already-pending LOI should throw');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.isNotNull(e.getMessage(), 'already-pending raises a typed ApprovalException');
        }
        Test.stopTest();

        Assert.areEqual(1, [
            SELECT COUNT() FROM ProcessInstance
            WHERE TargetObjectId = :loi.Id AND Status = 'Pending'
        ], 'and exactly ONE instance exists — the guard refused, it did not create a second');
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
            // ⚠ ASSERTION REPOINTED 2026-09-01 (W4). It read
            //     contains('LOI approval runs at the LOI stage')
            // and that sentence described a process that no longer accepts an Opportunity at all.
            // The message now says WHERE the approval lives, which is the only thing this catch
            // can honestly tell the submitter.
            Assert.isTrue(e.getMessage().contains('LOI approval runs on the LOI record'),
                'The ineligible-stage message must send the submitter to the LOI record, got: '
                    + e.getMessage());
            Assert.isTrue(e.getMessage().contains('Under Review'),
                'and it must still name the stage the deal is actually at, got: ' + e.getMessage());
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

    /**
     * ⚠ REPOINTED AT W5, 2026-09-01. Was `signedNdaAtLoiStillSubmits`, asserting that an
     * Opportunity submission SUCCEEDED — which depended on `Opportunity.LOI_Approval` being
     * active, and W5 deactivated it.
     *
     * 🔴 ITS JOB IS UNCHANGED AND IT STILL DOES IT. This is the POSITIVE CONTROL for the two
     * refusals below (`unsignedPrimaryNdaAtLoiIsRefusedWithTheTypedException` and
     * `blankPrimaryNdaAtLoiIsRefused`): without it, a gate that refused EVERY Opportunity
     * submission at LOI would pass both refusal tests and look correct. What changed is only the
     * EVIDENCE available for "the NDA gate did not refuse this one".
     *   - BEFORE W5: the submission succeeded, so no refusal at all.
     *   - AFTER W5:  the submission is refused unconditionally by the platform (no active
     *                Opportunity approval), so "not refused" is no longer observable. Instead the
     *                gate is proven not to have fired by WHICH refusal came back:
     *                `LOI_MOVED_MESSAGE` is thrown INSIDE the catch, i.e. only after
     *                `Approval.process` was actually called — so receiving it proves the signed
     *                deal got PAST the NDA gate, which runs BEFORE the submit.
     *                `NDA_UNSIGNED_MESSAGE` would prove the opposite.
     * That distinction is exactly as strong as the old one, and it is the same substitution made
     * in `aSubmitterWhoCannotSeeTheNdaIsNotFalselyBlocked`.
     *
     * Its LOI-target counterpart is `submitsFromLoiRecordTargetsTheLoiItself`, which is the
     * positive control for the LOI gate group further down and still asserts a real success.
     */
    @isTest
    static void signedNdaAtLoiIsNotRefusedByTheNdaGate() {
        Opportunity o = makeOpp('LOI'); // signs the primary NDA — see the helper

        Test.startTest();
        try {
            OpportunityApprovalService.submitForApproval(o.Id);
            Assert.fail('W5 deactivated Opportunity.LOI_Approval, so no Opportunity submission '
                + 'can succeed. Reaching here means that process is ACTIVE again.');
        } catch (OpportunityApprovalService.ApprovalException e) {
            Assert.areNotEqual(OpportunityApprovalService.NDA_UNSIGNED_MESSAGE, e.getMessage(),
                'THE GATE FIRED ON A SIGNED NDA. A signed primary NDA must not stand in the way '
                + 'of a legitimate LOI submission — this is the positive control for the two '
                + 'refusal tests below, and if it fails they are green for the wrong reason.');
            Assert.areEqual(OpportunityApprovalService.LOI_MOVED_MESSAGE, e.getMessage(),
                'and the refusal must be the post-Approval.process one, which proves the '
                + 'submission got PAST the NDA gate rather than being stopped by it. Got: '
                + e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'and no approval instance exists on the deal — the process is retired');
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

    /**
     * ⚠ RENAMED 2026-09-01 (W4) from `theNdaGateDoesNotFireAtAnyStageButLoi`, because that name
     * became FALSE as a universal statement while the test itself stayed correct. The gate now
     * fires for ANY `LOI__c` target that has a parent deal, whatever stage the deal is at — the
     * deal-stage condition survives only on the OPPORTUNITY path, which is what this test
     * exercises. A name that describes a mechanism quietly becomes a lie; this one describes the
     * invariant instead.
     */
    @isTest
    static void aDealAtANonLoiStageIsRefusedForItsStageNotItsNda() {
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
            Assert.isTrue(e.getMessage().contains('LOI approval runs on the LOI record'),
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
    // 🔴 THE SIGNED-NDA GATE ON THE **LOI** TARGET (W4, 2026-09-01)
    //
    // The five tests above all submit an OPPORTUNITY. After W4 that is no longer the path a
    // human can take — there is no Submit for Approval quick action on the Opportunity anywhere
    // in this repo, and the LOI button now submits the LOI. Those five are KEPT (the Opportunity
    // branch is still live for the W5 escape hatch and for Contract_Review__c resolution), but
    // 🔴 THEY WOULD HAVE GONE ON PASSING IF THE GATE HAD SIMPLY STOPPED FIRING FOR LOIs, WHICH IS
    // THE FAILURE THE DESIGN PACK PREDICTED: "several of its tests would go VACUOUS rather than
    // red, so nothing would tell you." These three are what makes the button path falsifiable.
    //
    // THE POSITIVE CONTROL FOR THIS GROUP IS `submitsFromLoiRecordTargetsTheLoiItself` ABOVE —
    // a signed-NDA deal whose LOI submits successfully. It is deliberately not duplicated here;
    // without it, a gate that refused EVERY LOI submission would pass both refusals below.
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void anLoiWhoseDealsNdaIsUnsignedIsRefused() {
        Opportunity o = makeLoiOppWithUnsignedNda();
        LOI__c loi = makeSubmittableLoi(o);

        Test.startTest();
        Boolean refused = false;
        try {
            OpportunityApprovalService.submitForApproval(loi.Id);
            Assert.fail('An LOI whose deal has an UNSIGNED primary NDA must be refused');
        } catch (OpportunityApprovalService.ApprovalException e) {
            refused = true;
            Assert.areEqual(OpportunityApprovalService.NDA_UNSIGNED_MESSAGE, e.getMessage(),
                'and the refusal must carry the actionable NDA wording verbatim — the SAME '
                + 'wording as the Opportunity path, because to the submitter it is one rule');
        }
        Test.stopTest();

        Assert.isTrue(refused, 'the typed ApprovalException is what was thrown');
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :loi.Id],
            '🔴 AND NOTHING WAS SUBMITTED. This is the half that makes it a GATE rather than a '
            + 'message: the throw must happen BEFORE Approval.process, because there is no way to '
            + 'un-submit an approval afterwards');
    }

    @isTest
    static void anLoiWhoseDealHasNoNdaIsRefused() {
        // The OTHER refusal shape, and on this path it is even less redundant than on the
        // Opportunity one: the LOI-rooted read spans TWO relationships
        // (`Opportunity__r.Primary_NDA__r.NDA_Signed__c`), so there are two independent ways to
        // arrive at a null parent. An implementation that tested only the spanning value would
        // NullPointerException here and the user would get the controller's generic mask instead
        // of an actionable message.
        Opportunity o = makeLoiOppWithUnsignedNda();
        update new Opportunity(Id = o.Id, Primary_NDA__c = null);
        Assert.isNull([SELECT Primary_NDA__c FROM Opportunity WHERE Id = :o.Id].Primary_NDA__c,
            'Fixture precondition: the deal must really have NO primary NDA, or this test proves '
            + 'nothing the unsigned test did not already prove');
        LOI__c loi = makeSubmittableLoi(o);

        Test.startTest();
        Boolean refused = false;
        try {
            OpportunityApprovalService.submitForApproval(loi.Id);
            Assert.fail('An LOI whose deal has NO primary NDA must be refused');
        } catch (OpportunityApprovalService.ApprovalException e) {
            refused = true;
            Assert.areEqual(OpportunityApprovalService.NDA_UNSIGNED_MESSAGE, e.getMessage(),
                'and it shares the unsigned case\'s wording deliberately');
        }
        Test.stopTest();

        Assert.isTrue(refused, 'a blank lookup refuses rather than NPEs');
        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :loi.Id],
            'and nothing was submitted');
    }

    /**
     * 🔴 THE SHARING AXIS ON THE NEW PATH, AND IT IS A BIGGER SURFACE THAN THE ONE IT REPLACES.
     *
     * `LoiSelector.selectNdaGateByLoiId` spans TWO Private-OWD parents — `Opportunity`, then
     * `NDA__c`. A `WITH SYSTEM_MODE` spanning read IS sharing-filtered on the parent; that was
     * MEASURED on 2026-08-30 (run `707iw000003bQwp`) on the Opportunity-rooted twin, with ONE hop,
     * and it made the gate REFUSE a deal whose NDA was signed. With two hops there are two
     * independent ways to get a null, and BOTH fabricate "this deal has no signed NDA" — the gate
     * INVERTING into a false block rather than degrading, which is strictly worse than the failure
     * it exists to prevent and would appear only in production, only for non-owners.
     *
     * The persona is `DPEG_Opportunity_View` on `Minimum Access - Salesforce`: Opportunity read +
     * viewAllRecords, no `NDA__c` object permission, NO `LOI__c` object permission at all, and it
     * owns nothing. So it exercises both hops at once.
     *
     * ⚠ IT ASSERTS "REACHED `Approval.process`", NOT "SUBMITTED SUCCESSFULLY", for the reason
     * `aSubmitterWhoCannotSeeTheNdaIsNotFalselyBlocked` records at length: `LOI__c.LOI_Approval`
     * declares `allowedSubmitters type=owner`, so the PLATFORM refuses a non-owner before entry
     * criteria are considered. Asserting success would be wrong BY CONSTRUCTION and could only be
     * made green by weakening the persona until it stopped testing sharing.
     * ⚠ Reaching the generic `catch (Exception)` is therefore a PASS: it means every gate in this
     * service let the submission through. On this persona that exception is most likely the
     * catch-block's own `LoiSelector.selectStageRequiredById` (USER_MODE, and this persona has no
     * `LOI__c` access) — which is downstream of `Approval.process` and so still proves the point.
     */
    @isTest
    static void anLoiSubmitterWhoCannotSeeTheDealsNdaIsNotFalselyBlocked() {
        Opportunity signedDeal = makeOpp('LOI');                  // signed NDA, owned by the ADMIN
        LOI__c signedLoi = makeSubmittableLoi(signedDeal);
        Opportunity unsignedDeal = makeLoiOppWithUnsignedNda();
        LOI__c unsignedLoi = makeSubmittableLoi(unsignedDeal);

        Id ndaId = [SELECT Primary_NDA__c FROM Opportunity WHERE Id = :signedDeal.Id].Primary_NDA__c;
        Assert.isNotNull(ndaId, 'Fixture precondition: the deal must have a primary NDA');

        User submitter = TestDataFactory.createNonOwnerLoiSubmitter('nlsl');

        // 🔴 `UserRecordAccess`, NOT a SOQL probe. An Apex test class carries no sharing keyword
        // and therefore runs `without sharing`, so `[SELECT COUNT() FROM NDA__c ...]` under runAs
        // would return the row regardless of access and "prove" the opposite of the truth.
        UserRecordAccess ndaAccess = [
            SELECT RecordId, HasReadAccess
            FROM UserRecordAccess
            WHERE UserId = :submitter.Id AND RecordId = :ndaId
        ];
        Assert.isFalse(ndaAccess.HasReadAccess,
            'FIXTURE PRECONDITION: the submitter must NOT be able to read the NDA, or this test '
            + 'measures nothing.');

        Boolean signedRefusedByNda = false;
        Boolean signedRefusedByAnyGate = false;
        Boolean signedReachedApprovalProcess = false;
        Boolean unsignedRefusedByNda = false;
        String unexpected = null;

        Test.startTest();
        System.runAs(submitter) {
            try {
                OpportunityApprovalService.submitForApproval(signedLoi.Id);
                signedReachedApprovalProcess = true;
            } catch (OpportunityApprovalService.ApprovalException e) {
                signedRefusedByNda =
                    e.getMessage() == OpportunityApprovalService.NDA_UNSIGNED_MESSAGE;
                signedRefusedByAnyGate = true;
                unexpected = e.getMessage();
            } catch (Exception e) {
                signedReachedApprovalProcess = true;
                unexpected = e.getTypeName() + ': ' + e.getMessage();
            }

            // 🔴 THE CONTROL THAT STOPS THE ASSERTION ABOVE PASSING VACUOUSLY. "The signed LOI was
            // not refused" is ALSO true of a gate that never ran at all — which, on this path, is
            // the single most likely defect (see the gate's own docstring: leave the method
            // untouched and it returns on its first line for every LOI). Running the UNSIGNED
            // deal's LOI through the SAME persona in the SAME runAs block proves the gate is live
            // for this user AND can still tell the two states apart.
            try {
                OpportunityApprovalService.submitForApproval(unsignedLoi.Id);
            } catch (OpportunityApprovalService.ApprovalException e) {
                unsignedRefusedByNda =
                    e.getMessage() == OpportunityApprovalService.NDA_UNSIGNED_MESSAGE;
            } catch (Exception e) {
                // Any other platform failure is not this test's subject.
            }
        }
        Test.stopTest();

        Assert.isFalse(signedRefusedByNda,
            'THE GATE INVERTED. A submitter who cannot READ the deal\'s NDA was refused an LOI '
            + 'whose deal\'s NDA IS SIGNED, which means the two-hop SYSTEM_MODE spanning read in '
            + 'LoiSelector.selectNdaGateByLoiId is being SHARING-FILTERED and yielding a null '
            + 'parent. FIX: it must stay inside the narrow private-without-sharing NdaGateReads '
            + 'inner class on LoiSelector. DO NOT put without-sharing on the whole selector.');
        Assert.isTrue(unsignedRefusedByNda,
            'CONTROL: the same persona must still be REFUSED the LOI whose deal\'s NDA is '
            + 'unsigned. If this fails the gate is not running for this user at all — or not '
            + 'running for LOI targets at all — and the assertion above is green for the wrong '
            + 'reason.');
        Assert.isFalse(signedRefusedByAnyGate,
            'No gate in this service may refuse the signed deal\'s LOI for this persona. Got: '
            + unexpected);
        Assert.isTrue(signedReachedApprovalProcess,
            'The signed deal\'s LOI must get PAST every gate in this service and reach '
            + 'Approval.process. Outcome was: ' + unexpected);
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
                // ═══ 🔴 REPOINTED AT W5, 2026-09-01 — READ THIS BEFORE "SIMPLIFYING" IT ═══
                // This branch used to be an unconditional `signedRefusedByAnyGate = true`, because
                // before W5 the ONLY way an ApprovalException came back was a gate in this service
                // refusing. THE EXCEPTION TYPE WAS THE DISCRIMINATOR, and W5 destroyed it: the
                // catch's 'LOI'-stage branch now throws a typed ApprovalException too, so EVERY
                // Opportunity target ends in one.
                // 🟢 THE DISCRIMINATOR MOVED TO THE MESSAGE AND IS EXACTLY AS STRONG.
                // `LOI_MOVED_MESSAGE` is thrown from INSIDE the service's catch block, which is
                // only entered if `Approval.process` was actually called and threw. Receiving it
                // therefore PROVES the submission got past every gate this service owns — the null
                // check, the duplicate-pending guard and the signed-NDA gate — which is precisely
                // what this test measures. Any OTHER ApprovalException is a real gate refusal.
                // ⚠ DO NOT relax this to a `contains(...)`: the non-'LOI' stages throw the same
                // text PREFIXED, and treating that as "reached Approval.process" would be wrong.
                unexpected = e.getMessage();
                signedRefusedByNda =
                    e.getMessage() == OpportunityApprovalService.NDA_UNSIGNED_MESSAGE;
                if (e.getMessage() == OpportunityApprovalService.LOI_MOVED_MESSAGE) {
                    signedReachedApprovalProcess = true;
                } else {
                    signedRefusedByAnyGate = true;
                }
            } catch (Exception e) {
                // ═══ 🔴 REACHING HERE IS A PASS, NOT A FAILURE, AND THAT IS MEASURED ═══
                // A raw platform exception means the service's own gates ALL let the submission
                // through and `Approval.process` itself was reached — which is exactly what this
                // test needs to prove. See the assertion block below for why this persona cannot
                // get further than that, and why that is the platform's rule and not the gate's.
                // ⚠ AFTER W5 an Opportunity target no longer reaches here (the 'LOI'-stage branch
                // wraps it), but the branch is KEPT: `Contract_Review__c` still resolves to a
                // parent Opportunity, and a genuinely unexpected failure must still land here.
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
