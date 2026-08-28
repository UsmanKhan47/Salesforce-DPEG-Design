/**
 * Tests the Phase-3 underwriting gate: the NDA-signed validation rule, the Initiate Underwriting
 * checkbox flow, and the principal approval.
 *
 * ── REWRITTEN 2026-08-28 — THE APPROVAL MOVED OBJECTS ────────────────────────────────────────
 * This class used to drive Opportunity.Underwriting_Approval (entry criteria StageName =
 * 'Underwriting'). That process is RETIRED (active = false, kept for its history; DO NOT
 * REACTIVATE). The principal approval now runs on Underwriting__c.Underwriting_Approval, entry
 * criteria Stage__c = 'In Progress', still FirstResponse and still the same two principals (D1).
 *
 * Three consequences shape every approval test below, and each is asserted rather than assumed:
 *   1. THE SUBMISSION TARGETS THE CHILD. ProcessInstance.TargetObjectId is the Underwriting Id;
 *      the deal has no approval history at all any more.
 *   2. APPROVAL NO LONGER ADVANCES THE DEAL. The old process wrote StageName = 'LOI' in its
 *      finalApprovalActions. Moving to LOI is now a separate act (Initiate LOI), refused by
 *      Underwriting_Approved_Before_LOI until the child reaches Approved/Completed. The stage
 *      assertion is INVERTED, not dropped.
 *   3. THE DEAL'S MIRROR FIELDS ARRIVE INDIRECTLY, through Apex, one save:
 *      approval -> Underwriting_Approval_Sync -> UnderwritingApprovalStampService -> the deal ->
 *      Opportunity_UW_Approved_Notify -> ApprovalAuditService + MarketDataSnapshotService.
 *      These tests exercise that whole chain, which is why they assert UW_Approved_By__c and
 *      Market_Data_As_Of_Date__c and not merely the two fields the stamp writes directly.
 *
 * ⚠ REJECTION: see principalRejectionLeavesTheUnderwritingInProgressAndClearsNothing. The reject
 * direction was deliberately dropped (D2) and that test pins the loss on purpose.
 *
 * (Historic note, retained: FirstResponse since 2026-08-05 — EITHER principal approves; one
 * reject ends it. It was Unanimous before that, and the approve test had to be rewritten because
 * the platform withdraws the second work item on the first response, so a loop over every work
 * item throws on its second iteration. That hazard is unchanged and is why `decide` acts on
 * exactly one.)
 */
@isTest
private class UnderwritingGateTest {

    private static Opportunity newOpp(String stage) {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = stage;
        return o;
    }

    private static void linkSignedNda(Opportunity o) {
        NDA__c nda = TestDataFactory.createSignedNdas(1, o.Id, true)[0];
        o.Primary_NDA__c = nda.Id;
    }

    @isTest
    static void ndaGateBlocksUnderwritingEntry() {
        Opportunity o = newOpp('Under Review');
        insert o;

        Boolean blocked = false;
        try {
            o.StageName = 'Underwriting';
            update o;
        } catch (DmlException e) {
            blocked = true;
        }
        System.assert(blocked, 'Entering Underwriting without a signed primary NDA must be blocked');

        linkSignedNda(o);
        o.StageName = 'Underwriting';
        update o;
        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Signed NDA unlocks the Underwriting stage');
    }

    @isTest
    static void initiateUnderwritingCheckboxAdvancesStage() {
        Opportunity o = newOpp('Under Review');
        insert o;
        linkSignedNda(o);

        Test.startTest();
        o.Initiate_Underwriting__c = true;
        update o;
        Test.stopTest();

        System.assertEquals('Underwriting',
            [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
            'Initiate Underwriting checkbox (12B.I) advances the stage');
    }

    /**
     * Walks the deal's auto-created Underwriting record to the stage the approval accepts.
     * The trigger creates it at Stage__c = 'Requested'; Underwriting_Approval's entryCriteria is
     * Stage__c = 'In Progress'.
     */
    private static Underwriting__c underwritingReadyForApproval(Opportunity o) {
        Underwriting__c uw = [
            SELECT Id, Stage__c, Status__c FROM Underwriting__c WHERE Opportunity__c = :o.Id LIMIT 1
        ];
        uw.Stage__c = 'In Progress';
        update uw;
        return uw;
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
     * REWRITTEN 2026-08-28, and RENAMED FROM principalApprovalAdvancesToLoi BECAUSE THE OLD
     * NAME NOW DESCRIBES A DEFECT. Approval no longer advances the deal at all: the retired
     * Opportunity.Underwriting_Approval set StageName = 'LOI' in its finalApprovalActions, and
     * moving to LOI is now a separate, deliberate act by the deal driver (Initiate LOI), gated by
     * the Underwriting_Approved_Before_LOI validation rule. The stage assertion is therefore
     * INVERTED rather than deleted - that the deal stays put is now a requirement, and a test that
     * merely stopped checking would not notice if the old auto-advance came back.
     *
     * This drives the WHOLE new chain in one transaction, which is the point:
     *   approve the underwriting -> finalApprovalActions write Stage__c / Status__c on the child
     *     -> flows/Underwriting_Approval_Sync -> UnderwritingApprovalStampService stamps the parent
     *       -> flows/Opportunity_UW_Approved_Notify fires on the TRANSITION
     *         -> ApprovalAuditService stamps the approver + timestamp from the CHILD's history
     *         -> MarketDataSnapshotService freezes the market data
     */
    @isTest
    static void principalApprovalStampsTheDealMirrorWithoutAdvancingTheStage() {
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
        insert o;
        Underwriting__c uw = underwritingReadyForApproval(o);

        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(uw.Id);
        Approval.ProcessResult submitted = Approval.process(req);
        System.assert(submitted.isSuccess(),
            'An underwriting at In Progress should enter Underwriting__c.Underwriting_Approval');

        // FirstResponse (D1, unchanged): ONE principal decides and the platform WITHDRAWS the
        // other's work item, so exactly one may be actioned - a loop over every work item throws
        // INVALID_CROSS_REFERENCE_KEY on the second iteration.
        Test.startTest();
        decide(uw.Id, 'Approve', 'Numbers work.');
        Test.stopTest();

        System.assertEquals(0, [
            SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :uw.Id
        ], 'One approval must complete the process and withdraw the second principal work item');

        Underwriting__c decided = [
            SELECT Stage__c, Status__c FROM Underwriting__c WHERE Id = :uw.Id
        ];
        System.assertEquals('Approved', decided.Stage__c,
            'finalApprovalActions advance the underwriting record itself');
        System.assertEquals('Approved by Principals', decided.Status__c,
            'finalApprovalActions stamp the underwriting record status');

        o = [
            SELECT StageName, UW_Approved__c, Underwriting_Status__c,
                   UW_Approved_By__c, UW_Approval_Date__c, Market_Data_As_Of_Date__c
            FROM Opportunity WHERE Id = :o.Id
        ];
        // THE INVERSION. The old process wrote StageName = 'LOI' here.
        System.assertEquals('Underwriting', o.StageName,
            'Approval must NOT advance the deal any more - Initiate LOI is a separate act');
        System.assert(o.UW_Approved__c,
            'UnderwritingApprovalStampService mirrors the decision onto the deal (D4)');
        System.assertEquals('Approved by Principals', o.Underwriting_Status__c,
            'The mirror status is stamped - this is what the market-data freeze keys on');
        System.assertEquals(UserInfo.getUserId(), o.UW_Approved_By__c,
            'ApprovalAuditService stamps the real approver, read from the UNDERWRITING record '
            + 'approval history (the deal has none any more)');
        System.assertNotEquals(null, o.UW_Approval_Date__c, 'Approval date stamped');
        System.assertEquals(Date.today(), o.Market_Data_As_Of_Date__c,
            'The market-data freeze fires off the mirror stamp single save');
    }

    /**
     * REWRITTEN AND RENAMED 2026-08-28 from principalRejectionSendsBackForRevision.
     *
     * THIS TEST PINS AN ACCEPTED, DOCUMENTED REGRESSION (decision D2). Read this before
     * "fixing" it - the assertions below are deliberate and describe a capability that was
     * knowingly given up, not a bug.
     *
     * The retired Opportunity.Underwriting_Approval had a finalRejectionActions field update
     * (UW_Reopen_For_Revision) that cleared Opportunity.Underwriting_Complete__c, so a rejected
     * deal visibly came back for rework. The replacement process has NO finalRejectionActions at
     * all, and no new field was added to carry a rejection. Therefore, on rejection:
     *   - the underwriting record stays exactly where it was, at Stage__c = 'In Progress'
     *     (its Stage__c never changes during the pending window - 'In Progress' IS the entry
     *     criterion), so NO record-triggered automation can even detect the rejection;
     *   - Opportunity.Underwriting_Complete__c is NOT cleared by anything;
     *   - the ONLY durable evidence of the rejection is the approval history on the child.
     *
     * The forward gate is unaffected and still fail-closed: a rejected underwriting is not
     * 'Approved', so Underwriting_Approved_Before_LOI still refuses Initiate LOI. What was lost is
     * the REOPEN signal, not the gate.
     */
    @isTest
    static void principalRejectionLeavesTheUnderwritingInProgressAndClearsNothing() {
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
        insert o;
        Underwriting__c uw = underwritingReadyForApproval(o);

        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(uw.Id);
        Approval.process(req);

        Test.startTest();
        decide(uw.Id, 'Reject', 'Cap rate too thin.');
        Test.stopTest();

        System.assertEquals(0, [
            SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :uw.Id
        ], 'A single rejection ends the approval and withdraws the second principal work item');

        Underwriting__c rejected = [
            SELECT Stage__c, Status__c FROM Underwriting__c WHERE Id = :uw.Id
        ];
        System.assertEquals('In Progress', rejected.Stage__c,
            'D2: rejection leaves the underwriting at In Progress - nothing moves it');
        System.assertNotEquals('Approved by Principals', rejected.Status__c,
            'A rejected underwriting must never carry the approved status');

        o = [
            SELECT StageName, UW_Approved__c, Underwriting_Complete__c, Underwriting_Status__c,
                   Deal_Category__c
            FROM Opportunity WHERE Id = :o.Id
        ];
        System.assertEquals('Underwriting', o.StageName, 'The deal stays at Underwriting to rework');
        System.assertEquals(false, o.UW_Approved__c,
            'No mirror stamp on rejection - UnderwritingApprovalStampService only runs on approval');
        System.assertNotEquals('Approved by Principals', o.Underwriting_Status__c,
            'The deal must not show a principal approval that did not happen');
        System.assertNotEquals('Dead', o.Deal_Category__c, 'Rejection does not kill the deal');
        // THE DOCUMENTED LOSS, pinned so it is visible rather than merely absent.
        System.assertEquals(true, o.Underwriting_Complete__c,
            'ACCEPTED REGRESSION (D2): Underwriting_Complete__c is NO LONGER cleared on rejection. '
            + 'The retired UW_Reopen_For_Revision action did this; nothing replaces it. If this '
            + 'ever reads false, a reject path was added and D2 needs revisiting.');
    }

    /**
     * REWRITTEN 2026-08-28: the submission now targets the UNDERWRITING record, and the entry
     * criterion moved from the DEAL StageName to the CHILD Stage__c. The fact under test is
     * unchanged and still worth pinning: the Underwriting Complete (12B) checkbox is tracked on
     * the deal but does NOT gate submission.
     */
    @isTest
    static void underwritingSubmitsFromInProgressWithoutCompleteFlag() {
        Opportunity o = newOpp('Underwriting');
        insert o; // Underwriting_Complete__c = false
        Underwriting__c uw = underwritingReadyForApproval(o);

        Test.startTest();
        OpportunityApprovalController.submitForApproval(uw.Id);
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance
             WHERE TargetObjectId = :uw.Id AND Status = 'Pending'],
            'An underwriting at In Progress submits even with Underwriting Complete unchecked');
        System.assertEquals(0,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id],
            'and the parent deal is never submitted');
    }
}
