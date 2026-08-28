/**
 * Tests the Phase-3 underwriting gate: the NDA-signed validation rule, the
 * Initiate Underwriting checkbox flow, and the Underwriting_Approval process
 * (FirstResponse since 2026-08-05 - EITHER principal approves -> LOI + audit stamps;
 * one reject ends it -> deal stays at Underwriting with Underwriting Complete cleared
 * to rework. Was Unanimous; the approve test looped over every workitem and had to be
 * rewritten, because the platform withdraws the second one on the first response).
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

    @isTest
    static void principalApprovalAdvancesToLoi() {
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
        insert o;

        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(o.Id);
        Approval.ProcessResult submitted = Approval.process(req);
        System.assert(submitted.isSuccess(), 'Completed underwrite should enter Underwriting_Approval');

        // FirstResponse (changed from Unanimous 2026-08-05): ONE principal decides. Approving a
        // single workitem completes the process and the platform WITHDRAWS the other principal's
        // workitem. This must approve exactly one — the previous loop over every workitem now
        // throws INVALID_CROSS_REFERENCE_KEY on the second iteration, because that row no longer
        // exists by the time the loop reaches it.
        Test.startTest();
        ProcessInstanceWorkitem wi = [
            SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :o.Id LIMIT 1
        ];
        Approval.ProcessWorkitemRequest wr = new Approval.ProcessWorkitemRequest();
        wr.setWorkitemId(wi.Id);
        wr.setAction('Approve');
        wr.setComments('Numbers work.');
        Approval.process(wr);
        Test.stopTest();

        // Pins the FirstResponse rule itself: the second principal is never waited for.
        System.assertEquals(0, [
            SELECT COUNT() FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :o.Id
        ], 'One approval must complete the process and withdraw the other principal\'s work item');

        o = [
            SELECT StageName, UW_Approved__c, Underwriting_Status__c,
                   UW_Approved_By__c, UW_Approval_Date__c
            FROM Opportunity WHERE Id = :o.Id
        ];
        System.assertEquals('LOI', o.StageName, 'Approval advances the deal to LOI');
        System.assert(o.UW_Approved__c, 'Approved checkbox set by the final-approval action');
        System.assertEquals('Approved by Principals', o.Underwriting_Status__c, 'Status stamped');

        // ── 🔴 FOUR ASSERTIONS REMOVED HERE 2026-08-28. READ THIS BEFORE RE-ADDING THEM. ────────
        // They were:
        //     System.assertEquals(UserInfo.getUserId(), o.UW_Approved_By__c,
        //         'ApprovalAuditService stamps the actual approver from approval history');
        //     System.assertNotEquals(null, o.UW_Approval_Date__c, 'Approval date stamped');
        //     Underwriting__c uw = [SELECT Stage__c, Status__c FROM Underwriting__c
        //                           WHERE Opportunity__c = :o.Id LIMIT 1];
        //     System.assertEquals('Approved', uw.Stage__c, '…advances the underwriting record…');
        //     System.assertEquals('Approved by Principals', uw.Status__c, '…stamps the status');
        //
        // All four described work that THIS approval (the one on the Opportunity) no longer does:
        //   - UW_Approved_By__c / UW_Approval_Date__c: ApprovalAuditService was repointed to read
        //     the UNDERWRITING record's approval history, so an approval taken on the OPPORTUNITY
        //     — which is what this test performs — correctly stamps nothing.
        //   - uw.Stage__c / uw.Status__c: the block in ApprovalAuditService that wrote them was
        //     deleted; the writer is now the new Underwriting_Approval process's own
        //     finalApprovalActions, on the record itself.
        //
        // They are NOT replaced in place because an Apex test cannot perform the new approval
        // until the declarative stream deploys Underwriting__c.Underwriting_Approval. Their
        // replacements are:
        //   - the deal-mapping and stamp mechanics -> ApprovalAuditServiceTest;
        //   - the real end-to-end (approver identity, timestamp, child stage/status)
        //     -> post-deploy checks P-3 and P-4 in agent-output/design-requirements.md §8.
        //
        // ⚠ THIS WHOLE TEST CLASS IS SCHEDULED FOR REWRITE. Every approval test here submits the
        // OPPORTUNITY, which stops working the moment Opportunity.Underwriting_Approval is
        // deactivated (execution-order step 9). That rewrite is step 12 and belongs with the
        // declarative deploy — not to this Apex-only change, which would otherwise leave the suite
        // red for the entire window between the two.
    }

    @isTest
    static void principalRejectionSendsBackForRevision() {
        Opportunity o = newOpp('Underwriting');
        o.Underwriting_Complete__c = true;
        insert o;

        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(o.Id);
        Approval.process(req);

        // A single rejection ends the approval immediately and the other principal's pending
        // item is withdrawn. This was already true under Unanimous and is unchanged by the move
        // to FirstResponse, which is why this test needed no rewrite - it always acted on one item.
        Test.startTest();
        ProcessInstanceWorkitem wi = [
            SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :o.Id LIMIT 1
        ];
        Approval.ProcessWorkitemRequest wr = new Approval.ProcessWorkitemRequest();
        wr.setWorkitemId(wi.Id);
        wr.setAction('Reject');
        wr.setComments('Cap rate too thin.');
        Approval.process(wr);
        Test.stopTest();

        o = [SELECT StageName, Deal_Category__c, Underwriting_Complete__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('Underwriting', o.StageName, 'Rejection keeps the deal at Underwriting to rework');
        System.assertEquals(false, o.Underwriting_Complete__c,
            'Rejection clears Underwriting Complete so the 12B gate re-opens for resubmission');
        System.assertNotEquals('Dead', o.Deal_Category__c, 'Rejection no longer kills the deal');
    }

    @isTest
    static void underwritingStageSubmitsWithoutCompleteFlag() {
        // Entry criteria is Stage = Underwriting only; the Underwriting Complete
        // (12B) checkbox is tracked on the deal but no longer gates submission.
        Opportunity o = newOpp('Underwriting');
        insert o; // Underwriting_Complete__c = false

        Test.startTest();
        OpportunityApprovalController.submitForApproval(o.Id);
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM ProcessInstance WHERE TargetObjectId = :o.Id AND Status = 'Pending'],
            'A deal at Underwriting submits even with Underwriting Complete unchecked');
    }
}
