/**
 * Tests the LOI gate: the two-principal FirstResponse LOI approval, and the
 * ApprovalAuditService audit trail stamped onto the primary LOI.
 *
 * -- REPOINTED 2026-09-03 -- THE APPROVAL MOVED OBJECTS -----------------------------------------
 * These tests used to drive Opportunity.LOI_Approval (entry criterion StageName = 'LOI'). That
 * process is RETIRED at W5 of the LOI approval cutover: measured against usman-dpeg on
 * 2026-09-03, ProcessDefinition 04aiw0000001sxdAAA (LOI_Approval, TableEnumOrId = Opportunity)
 * is State = 'Obsolete', and there are ZERO active approval processes on Opportunity of any
 * kind. Every Approval.process call aimed at an Opportunity therefore returns
 * NO_APPLICABLE_PROCESS, which is exactly how both methods below were failing.
 *
 * The principal LOI approval now runs on LOI__c.LOI_Approval (ProcessDefinition
 * 04aiw0000005ub3AAA, State = 'Active'), and the LOI is where these tests now submit. That is
 * not an arbitrary choice of a convenient host object -- this class tests LOI GATE behaviour, so
 * the LOI record is load-bearing, and LOI__c is the only object that owns this approval.
 *
 * ENTRY CRITERIA, read from the ORG's own copy of the process on 2026-09-03 (not from the repo
 * file, and not from the design pack):
 *     booleanFilter '1 AND 2'
 *       1. LOI__c.Stage__c    equals 'Under Review'
 *       2. LOI__c.RecordType  equals 'Acquisition LOI'   (the record type LABEL, not its
 *                                                         DeveloperName Acquisition_LOI, and not
 *                                                         its Id -- a RecordType criterion is
 *                                                         label-valued)
 *     allowedSubmitters type = owner
 * The fixture satisfies all three: TestDataFactory.createLoi seeds the Acquisition_LOI record
 * type at Stage__c = 'Draft', the helper drives Stage__c to 'Under Review', and because the
 * test-running user INSERTS the LOI it also owns it.
 *
 * 🔴 THE FIXTURE MUST BUILD ITS OWN LOI AND MUST NOT USE THE ONE THE DEAL AUTO-CREATES. Entering
 * StageName = 'LOI' makes OpportunityReviewService create an LOI owned by the Acquisition QUEUE,
 * and allowedSubmitters = owner means a submission of that record is refused by the PLATFORM
 * before entry criteria are even considered -- a green-for-the-wrong-reason trap. Same fixture
 * shape, and same reasoning, as OpportunityApprovalServiceTest.makeSubmittableLoi.
 *
 * WHAT THE APPROVAL CAN AND CANNOT WRITE, because it shapes every assertion below. An approval
 * process can field-update only its own record or a MASTER-DETAIL parent, and
 * LOI__c.Opportunity__c is a LOOKUP -- so this process STRUCTURALLY cannot touch the Opportunity.
 * The deal-level mirror arrives indirectly, through Apex, in one chain:
 *     approve -> finalApprovalActions write LOI__c.LOI_Status__c = 'Approved'
 *       -> flows/LOI_Approval_Sync -> LoiApprovalStampService sets Opportunity.LOI_Approved__c
 *         -> flows/LOI_Approval_Stamp fires on that TRANSITION
 *           -> ApprovalAuditService (gate = 'LOI') stamps the primary LOI from the LOI's OWN
 *              approval history
 * That last hop is why Primary_LOI__c is designated in both fixtures: ApprovalAuditService maps
 * deal -> primary LOI to know which record to stamp, and with it blank the stamp writes nothing
 * and fails SILENTLY (the class swallows its own failures by design).
 *
 * ⚠ REJECTION: see rejectionLeavesLoiUnderReviewAndDoesNotRewindTheDeal. The deal rewind was
 * deliberately dropped (decision D-3) and that test now pins the loss on purpose. It was renamed
 * from rejectionReturnsDealToUnderwriting because that name had become a description of a defect.
 *
 * (Historic note, retained: FirstResponse since 2026-08-05 -- EITHER principal decides. The
 * platform WITHDRAWS the other principal work item on the first response, so a loop over every
 * work item throws INVALID_CROSS_REFERENCE_KEY on its second iteration. That hazard is unchanged
 * and is why decide() acts on exactly one.)
 */
@isTest
private class LoiGateTest {

    /**
     * The LOI__c.Stage__c value approvalProcesses/LOI__c.LOI_Approval accepts, together with
     * record type Acquisition_LOI. Written as a literal rather than imported from any production
     * constant on purpose: a test that shared the constant could not tell "the process and the
     * fixture agree" from "the fixture and itself agree".
     */
    private static final String LOI_STAGE_UNDER_REVIEW = 'Under Review';

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        return o;
    }

    /**
     * An acquisition LOI under `deal`, parked at the stage its own approval accepts, owned by the
     * test-running user, and DESIGNATED as the deal primary LOI.
     *
     * The Primary_LOI__c designation is written through a fresh sObject rather than by mutating
     * and re-updating the in-memory deal: `deal` is stale after its own insert (before-triggers
     * and defaulting have moved on) and re-sending its whole field set would push stale literals
     * back over whatever the insert produced.
     *
     * @param deal  The parent deal, already inserted.
     * @return The inserted LOI, at 'Under Review', owned by the runner, primary on the deal.
     */
    private static LOI__c makeSubmittablePrimaryLoi(Opportunity deal) {
        LOI__c loi = TestDataFactory.createLoi(deal.Id, true);
        update new LOI__c(Id = loi.Id, Stage__c = LOI_STAGE_UNDER_REVIEW);
        update new Opportunity(Id = deal.Id, Primary_LOI__c = loi.Id);
        return loi;
    }

    /** Submits `targetId` and proves the platform accepted it, so nothing below is vacuous. */
    private static void submit(Id targetId) {
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(targetId);
        Approval.ProcessResult submitted = Approval.process(req);
        System.assert(submitted.isSuccess(),
            'PRECONDITION FAILED: an Acquisition LOI at Under Review, owned by the running user, '
            + 'must enter LOI__c.LOI_Approval. If this is NO_APPLICABLE_PROCESS the fixture no '
            + 'longer satisfies the deployed entry criteria and every assertion below would be '
            + 'measuring an approval that never happened.');
    }

    /** Acts on the single outstanding work item for a target record. */
    private static void decide(Id targetId, String action, String comments) {
        ProcessInstanceWorkitem wi = [
            SELECT Id FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :targetId LIMIT 1
        ];
        Approval.ProcessWorkitemRequest wr = new Approval.ProcessWorkitemRequest();
        wr.setWorkitemId(wi.Id);
        wr.setAction(action);
        wr.setComments(comments);
        Approval.process(wr);
    }

    /**
     * REPOINTED 2026-09-03 ONTO LOI__c.LOI_Approval. Name unchanged -- it still describes exactly
     * what is under test, because the audit trail is still stamped onto the LOI and the decision
     * is still FirstResponse.
     *
     * EVERY ORIGINAL ASSERTION SURVIVES, and that is the point: the deal still ends at StageName
     * 'LOI', LOI_Approved__c is still set, and the four audit fields are still stamped with the
     * real approver, date and comments. Only the SUBMISSION TARGET moved. The route those values
     * arrive by changed completely (see the class header chain), so this test now walks the whole
     * new chain end to end rather than a single approval field update.
     *
     * TWO ASSERTIONS ARE NEW, both of them falsifiers the old shape could not carry:
     *   - LOI_Status__c = 'Pending Approval' WHILE PENDING. The process gained
     *     initialSubmissionActions on 2026-09-02; the value used to be hand-set by this fixture at
     *     the old line 22, which made it unobservable. Deleting that fixture line and asserting
     *     the value instead converts a hand-fed constant into a real acceptance criterion.
     *   - ZERO ProcessInstance rows on the parent deal. Nothing may land on the Opportunity any
     *     more; a revert of the routing puts a row there immediately.
     */
    @isTest
    static void firstResponseApprovalStampsLoiAuditTrail() {
        Opportunity o = newOpp('LOI');
        insert o;
        LOI__c loi = makeSubmittablePrimaryLoi(o);
        update new LOI__c(Id = loi.Id, Offer_Price__c = 9000000);

        submit(loi.Id);

        System.assertEquals('Pending Approval',
            [SELECT LOI_Status__c FROM LOI__c WHERE Id = :loi.Id].LOI_Status__c,
            'initialSubmissionActions (LOI_Status_Pending) must stamp the LOI while the decision '
            + 'is outstanding. This is no longer a fixture value - the process writes it.');

        Test.startTest();
        // FirstResponse: EITHER principal decides, so exactly one work item is approved. The
        // platform withdraws the other principal work item as soon as the first response lands.
        decide(loi.Id, 'Approve', 'Terms cleared.');
        Test.stopTest();

        // Pins the FirstResponse rule itself: the second principal is never waited for.
        System.assertEquals(0, [
            SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :loi.Id
        ], 'One approval must complete the process and withdraw the second principal work item');

        System.assertEquals(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'THE FALSIFIER. The approval lives on the LOI now - nothing may land on the parent '
            + 'deal, and there is no active Opportunity approval left that could accept it.');

        o = [SELECT StageName, LOI_Approved__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('LOI', o.StageName, 'Stage stays at the coarse LOI stage');
        System.assert(o.LOI_Approved__c,
            'A single principal approval sets the LOI Approved flag on the deal - now through '
            + 'LOI_Approval_Sync -> LoiApprovalStampService, not through an approval field update');

        loi = [SELECT Stage__c, LOI_Status__c, Approved_By__c, Approved_Date__c, Approval_Comments__c
               FROM LOI__c WHERE Id = :loi.Id];
        System.assertEquals('Approved', loi.LOI_Status__c, 'LOI status stamped by the audit service');
        System.assertEquals(UserInfo.getUserId(), loi.Approved_By__c,
            'Final approver stamped from history - read from the LOI OWN approval history, which '
            + 'is the only place an LOI decision is recorded now');
        System.assertEquals(Date.today(), loi.Approved_Date__c, 'Approval date stamped');
        System.assertEquals('Terms cleared.', loi.Approval_Comments__c,
            'Approver comments preserved (audit trail)');
        System.assertEquals(LOI_STAGE_UNDER_REVIEW, loi.Stage__c,
            'and the approval must not move the LOI own Stage__c - Under Review IS the entry '
            + 'criterion, and nothing in finalApprovalActions touches the stage');
    }

    /**
     * RENAMED AND INVERTED 2026-09-03, from rejectionReturnsDealToUnderwriting.
     *
     * 🔴 READ THIS BEFORE "FIXING" IT. THE ASSERTIONS BELOW PIN AN ACCEPTED, DOCUMENTED
     * REGRESSION -- a capability that was knowingly given up, not a bug. This test was not
     * repaired, it was reversed, exactly as
     * UnderwritingGateTest.principalRejectionLeavesTheUnderwritingInProgressAndClearsNothing was
     * reversed for the identical cutover on the sibling object.
     *
     * The old name asserted that an LOI rejection rewound the deal LOI -> Underwriting. The
     * retired Opportunity.LOI_Approval did that through a Set_Stage_Underwriting
     * finalRejectionAction. THAT BEHAVIOUR IS GONE and is not coming back. User decision D-3,
     * quoted rather than paraphrased: "The LOI stage will remain on Under review after
     * rejection." An approval parented by LOI__c structurally cannot write an Opportunity field,
     * and an Apex substitute would newly have to satisfy NDA_Signed_Before_Deal_Progression and
     * No_Backward_Stage_Movement -- validation rules the old approval field update BYPASSED -- so
     * a rejection could be REFUSED outright. The user chose the visible loss over the refusable
     * rebuild. Anyone proposing a compensating flow or trigger is reopening D-3 and needs the
     * user, not a code change. See LoiApprovalStampService.cls, which names this test.
     *
     * ⚠ IT NEVER PINNED CARVE-OUT 1 OF No_Backward_Stage_Movement, WHATEVER ITS OLD NAME
     * SUGGESTED. Approval-process field updates bypass validation rules in this org, so the old
     * LOI -> Underwriting rewind never reached that rule formula at all. The real pin is
     * directLoiToUnderwritingUpdate_isAllowedByCarveOut1_notByApproval below, which is now the
     * ONLY one. Protect it; do not delete it while tidying its neighbour.
     *
     * What is asserted, and why each line is load-bearing:
     *   - the LOI stays at 'Under Review' (D-3, the stage story);
     *   - LOI_Status__c = 'Rejected' -- the "free rejection marker" added 2026-09-02, verified
     *     present in the ORG copy of the process (finalRejectionActions -> LOI_Status_Rejected)
     *     on 2026-09-03. This is the ONLY durable, queryable evidence of a rejection outside the
     *     approval history;
     *   - the deal does NOT move -- the documented loss, pinned so it is visible rather than
     *     merely absent. If StageName ever reads 'Underwriting' here, a rewind was rebuilt and
     *     D-3 needs revisiting with the user;
     *   - LOI_Approved__c stays false, so a rejection cannot be mistaken for an approval by the
     *     PSA gate (Approved_LOI_Before_PSA still reads that field -- decision D-2).
     */
    @isTest
    static void rejectionLeavesLoiUnderReviewAndDoesNotRewindTheDeal() {
        Opportunity o = newOpp('LOI');
        insert o;
        LOI__c loi = makeSubmittablePrimaryLoi(o);

        submit(loi.Id);

        Test.startTest();
        decide(loi.Id, 'Reject', 'Rework the terms.');
        Test.stopTest();

        System.assertEquals(0, [
            SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :loi.Id
        ], 'A single rejection ends the approval and withdraws the second principal work item');

        LOI__c rejected = [SELECT Stage__c, LOI_Status__c FROM LOI__c WHERE Id = :loi.Id];
        System.assertEquals(LOI_STAGE_UNDER_REVIEW, rejected.Stage__c,
            'D-3: rejection leaves the LOI at Under Review - nothing moves it');
        System.assertEquals('Rejected', rejected.LOI_Status__c,
            'finalRejectionActions (LOI_Status_Rejected) is the only durable rejection marker '
            + 'outside the approval history. If this reads Pending Approval, the process lost its '
            + 'finalRejectionActions block and every rejected LOI is stuck showing as pending.');

        Opportunity deal = [SELECT StageName, LOI_Approved__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('LOI', deal.StageName,
            'ACCEPTED REGRESSION (D-3): the deal is NO LONGER rewound to Underwriting on an LOI '
            + 'rejection. The retired Set_Stage_Underwriting field update did this; nothing '
            + 'replaces it. If this ever reads Underwriting, a rewind was rebuilt and D-3 needs '
            + 'revisiting with the user.');
        System.assertEquals(false, deal.LOI_Approved__c,
            'No mirror stamp on rejection - LoiApprovalStampService only runs off the transition '
            + 'to LOI_Status__c = Approved, so the PSA gate stays closed');
    }

    /**
     * Pins CARVE-OUT 1 of the No_Backward_Stage_Movement validation rule (code review W2).
     *
     * 🔴 UNTOUCHED BY THE 2026-09-03 REPOINT, DELIBERATELY: it calls no Approval.process at all,
     * so the approval cutover cannot reach it. It is now the ONLY remaining pin on carve-out 1 --
     * its former companion above pinned nothing of the sort (see that method header). Protect it.
     *
     * Per this org own finding (F2, recorded in the rule XML comment and in
     * agent-output/design-requirements-stage-validations.md), approval-process field updates
     * bypass custom validation rules here, so no approval-driven LOI -> Underwriting transition
     * ever reached No_Backward_Stage_Movement formula. This test drives the identical transition
     * through a direct `update`, which is the one path carve-out 1 formula can actually be
     * evaluated against. Without carve-out 1 this is a plain backward move (LOI rank 5 ->
     * Underwriting rank 4) and would be blocked, so this test DOES red if carve-out 1 is removed.
     */
    @isTest
    static void directLoiToUnderwritingUpdate_isAllowedByCarveOut1_notByApproval() {
        Opportunity o = newOpp('LOI');
        insert o; // ISCHANGED(StageName) is false on insert, so every gate is bypassed here.
        TestDataFactory.signPrimaryNda(o); // isolate: Underwriting entry is ALSO NDA-gated

        Test.startTest();
        o.StageName = 'Underwriting';
        update o; // must NOT throw - carve-out 1 exempts exactly this transition, with no
                  // Approval.process(...) call anywhere in this test
        Test.stopTest();

        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Carve-out 1 must let a LOI -> Underwriting move through a plain update, independent of '
            + 'whether approval-process field updates run validation rules in this org');
    }
}
