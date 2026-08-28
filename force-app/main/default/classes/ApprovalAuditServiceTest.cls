/**
 * Tests ApprovalAuditService, focused on the UNDERWRITING gate that was repointed on 2026-08-28
 * to read the approval history of the deal's UNDERWRITING CHILD instead of the deal's own.
 *
 * ── WHAT THIS CLASS PINS ──────────────────────────────────────────────────────────────────────
 *
 *   1. THE REPOINT ITSELF, as a POSITIVE: a real approval granted on the UNDERWRITING record
 *      stamps the DEAL's UW_Approved_By__c / UW_Approval_Date__c, with preconditions proving the
 *      approved step exists on the child and NOT on the deal. This is the single most dangerous
 *      behaviour in the change, because the class swallows every failure by design AND because
 *      "no approved step found" is not a failure at all — it is the ordinary pending state. Had
 *      the repoint been forgotten, retiring the Opportunity approval would have killed the stamp
 *      with nothing thrown and nothing logged.
 *
 *   2. GRACEFUL DEGRADATION. Every no-history and degenerate path must complete silently without
 *      touching the deal and without throwing — because this runs inside the approval's own
 *      transaction, and a throw here would roll the approval back. That contract is why the class
 *      catches Exception rather than DmlException (see its own header, incident 2026-08-05).
 *
 * ⚠ SUPERSEDED NOTE, kept because it explains a deleted test. While the declarative half was
 * undeployed this header read "WHAT THIS CLASS CAN AND CANNOT PROVE" and stated that no test here
 * could assert the approver's Id reaching UW_Approved_By__c, since ProcessInstanceStep cannot be
 * inserted, mocked or backdated from Apex. Item 1 was therefore written as a NEGATIVE against an
 * Opportunity-side approval. That fixture is now unbuildable (the old process is inactive), which
 * is precisely why it was written to fail loudly rather than pass vacuously.
 *
 * ⚠ Post-deploy check P-4 (agent-output/design-requirements.md §8) is STILL REQUIRED and is not
 * made redundant by item 1: it verifies the stamp against a real principal approving in the UI,
 * whereas this test's approver is the test-running user.
 *
 * ⚠ THE LOI GATE IS DELIBERATELY NOT RE-TESTED HERE. It is unchanged — LOI_Approval still runs on
 * the Opportunity and still reads the Opportunity's history — and its coverage lives in
 * LoiGateTest, which drives a real LOI approval end to end. Adding a shallow duplicate here would
 * imply the LOI half moved too.
 *
 * @see force-app/main/default/classes/ApprovalAuditService.cls
 * @see force-app/main/default/classes/UnderwritingApprovalStampService.cls
 */
@isTest
private class ApprovalAuditServiceTest {

    private static ApprovalAuditService.Request request(Id recordId, String gate) {
        ApprovalAuditService.Request r = new ApprovalAuditService.Request();
        r.recordId = recordId;
        r.gate = gate;
        return r;
    }

    private static Opportunity dealWithUnderwriting() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'Underwriting';
        insert o;
        return o;
    }

    /**
     * 🔴 THE REPOINT, now asserted as the POSITIVE it produces.
     *
     * ⚠ REPLACES `anApprovalOnTheOpportunityNoLongerStampsTheAudit` (2026-08-28). That test built
     * a real granted approval ON THE OPPORTUNITY and asserted nothing was stamped — the only
     * assertion available while Underwriting__c.Underwriting_Approval was undeployed. Its fixture
     * is now UNBUILDABLE: Opportunity.Underwriting_Approval is inactive, so `Approval.process` on
     * a deal at StageName = 'Underwriting' throws NO_APPLICABLE_PROCESS and the test could never
     * reach its assertions. It was a deliberate tripwire for exactly this moment, and this is the
     * test that supersedes it.
     *
     * This asserts the thing that actually matters and that nothing else in the suite covers:
     * C-3's fix. Retiring the Opportunity approval would have silently killed the
     * UW_Approved_By__c / UW_Approval_Date__c stamp — silently, because this class swallows every
     * failure by design AND because "no approved step found" is not a failure at all, it is the
     * ordinary not-yet-approved state. Nothing would have thrown and nothing would have logged.
     *
     * ⚠ THE TWO PRECONDITIONS ARE LOAD-BEARING, NOT CEREMONY. They establish that the approved
     * step exists on the CHILD and does NOT exist on the DEAL, which is the entire content of the
     * word "repoint". Without them a passing stamp assertion would be equally consistent with the
     * old, unrepointed read.
     */
    @isTest
    static void anApprovalOnTheUnderwritingRecordStampsTheDealsAuditFields() {
        Opportunity deal = dealWithUnderwriting();
        Underwriting__c uw = [
            SELECT Id, Stage__c FROM Underwriting__c WHERE Opportunity__c = :deal.Id LIMIT 1
        ];
        uw.Stage__c = 'In Progress'; // Underwriting_Approval's entry criterion
        update uw;

        Approval.ProcessSubmitRequest submit = new Approval.ProcessSubmitRequest();
        submit.setObjectId(uw.Id);
        Approval.process(submit);

        Test.startTest();
        ProcessInstanceWorkitem item = [
            SELECT Id FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :uw.Id LIMIT 1
        ];
        Approval.ProcessWorkitemRequest decide = new Approval.ProcessWorkitemRequest();
        decide.setWorkitemId(item.Id);
        decide.setAction('Approve');
        Approval.process(decide);
        Test.stopTest();

        Assert.areEqual(1, [
            SELECT COUNT() FROM ProcessInstanceStep
            WHERE ProcessInstance.TargetObjectId = :uw.Id AND StepStatus = 'Approved'
        ], 'Precondition: the approved step must exist on the UNDERWRITING record');
        Assert.areEqual(0, [
            SELECT COUNT() FROM ProcessInstanceStep
            WHERE ProcessInstance.TargetObjectId = :deal.Id AND StepStatus = 'Approved'
        ], 'Precondition: the DEAL must have no approval history — that is what "repointed" means');

        Opportunity after = [
            SELECT UW_Approved_By__c, UW_Approval_Date__c FROM Opportunity WHERE Id = :deal.Id
        ];
        Assert.areEqual(UserInfo.getUserId(), after.UW_Approved_By__c,
            'The approver is read from the CHILD approval history and stamped on the deal (C-3)');
        Assert.isNotNull(after.UW_Approval_Date__c,
            'The approval timestamp is stamped on the deal from the same step');
    }

    /**
     * The ordinary not-yet-approved state: a deal with an underwriting child that has no approval
     * history at all. Must stamp nothing and, above all, must not throw — a throw would roll back
     * whatever transaction invoked it.
     */
    @isTest
    static void anUnderwritingWithNoApprovalHistoryStampsNothingAndDoesNotThrow() {
        Opportunity deal = dealWithUnderwriting();

        Test.startTest();
        ApprovalAuditService.stampApprovalAudit(
            new List<ApprovalAuditService.Request>{ request(deal.Id, null) });
        Test.stopTest();

        Opportunity after = [
            SELECT UW_Approved_By__c, UW_Approval_Date__c FROM Opportunity WHERE Id = :deal.Id
        ];
        Assert.isNull(after.UW_Approved_By__c, 'No approved step -> no approver stamped');
        Assert.isNull(after.UW_Approval_Date__c, 'No approved step -> no date stamped');
    }

    /**
     * A deal with NO underwriting child at all. The mapping query returns nothing, so the target
     * set for the history read is empty and the method must return early rather than reading the
     * deal's own history as a fallback — a fallback would silently re-create the old behaviour.
     */
    @isTest
    static void aDealWithNoUnderwritingChildStampsNothing() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true); // never enters Underwriting

        Assert.areEqual(0, [SELECT COUNT() FROM Underwriting__c WHERE Opportunity__c = :deal.Id],
            'Fixture precondition: this deal must have no underwriting child');

        Test.startTest();
        ApprovalAuditService.stampApprovalAudit(
            new List<ApprovalAuditService.Request>{ request(deal.Id, 'Underwriting') });
        Test.stopTest();

        Assert.isNull(
            [SELECT UW_Approved_By__c FROM Opportunity WHERE Id = :deal.Id].UW_Approved_By__c,
            'A deal with no underwriting child stamps nothing and must not fall back to its own history');
    }

    /**
     * Bulk posture: a multi-deal batch must cost a FIXED query budget. The repoint added the deal
     * -> child mapping read, and the risk it introduces is that someone later resolves the child
     * per deal inside the loop. Asserting a fixed count across five deals falsifies that at any N,
     * which is why this stands in for a 251-record run (.claude/rules/bulk-test-rule.md — the
     * reasoning is recorded here in place, as that rule requires).
     */
    @isTest
    static void aMultiDealBatchKeepsAFixedQueryBudget() {
        List<Opportunity> deals = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            Opportunity o = TestDataFactory.createOpportunity(null, false);
            o.StageName = 'Underwriting';
            deals.add(o);
        }
        insert deals;

        List<ApprovalAuditService.Request> requests = new List<ApprovalAuditService.Request>();
        for (Opportunity o : deals) {
            requests.add(request(o.Id, 'Underwriting'));
        }

        Test.startTest();
        Integer soqlBefore = Limits.getQueries();
        ApprovalAuditService.stampApprovalAudit(requests);
        Integer soqlUsed = Limits.getQueries() - soqlBefore;
        Test.stopTest();

        // 1 mapping read (deal -> underwriting children) + 1 approval-history read. Fixed,
        // regardless of how many deals are in the batch.
        Assert.areEqual(2, soqlUsed,
            'Five deals must cost a FIXED two queries — a per-deal read is SOQL in a loop');
    }

    /**
     * Degenerate inputs a Flow can genuinely produce: an empty collection, a null entry, and an
     * entry whose recordId was never populated.
     */
    @isTest
    static void nullAndEmptyRequestsDoNothing() {
        Test.startTest();
        ApprovalAuditService.stampApprovalAudit(new List<ApprovalAuditService.Request>());
        ApprovalAuditService.stampApprovalAudit(
            new List<ApprovalAuditService.Request>{ null, request(null, 'Underwriting') });
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, dmlUsed, 'Degenerate input performs no DML at all');
    }

    /**
     * The narrow, separately-justified `without sharing` + SYSTEM_MODE read the repoint depends
     * on (UnderwritingSelector.ApprovalAutomationReads). Pinned here rather than only in
     * UnderwritingSelectorTest because its CONSUMER is what breaks if it silently returns empty:
     * an empty list is indistinguishable from "not approved", which turns the whole stamp into a
     * no-op instead of an error.
     */
    @isTest
    static void approvalAutomationReadsResolveBothDirectionsOfTheDealChildEdge() {
        Opportunity deal = dealWithUnderwriting();
        Underwriting__c uw = [
            SELECT Id FROM Underwriting__c WHERE Opportunity__c = :deal.Id LIMIT 1
        ];

        Test.startTest();
        List<Underwriting__c> byDeal = new UnderwritingSelector.ApprovalAutomationReads()
            .selectByOpportunityIds(new Set<Id>{ deal.Id });
        List<Underwriting__c> byChild = new UnderwritingSelector.ApprovalAutomationReads()
            .selectByIds(new Set<Id>{ uw.Id });
        List<Underwriting__c> emptyIn = new UnderwritingSelector.ApprovalAutomationReads()
            .selectByIds(new Set<Id>());
        List<Underwriting__c> nullIn = new UnderwritingSelector.ApprovalAutomationReads()
            .selectByOpportunityIds(null);
        Test.stopTest();

        Assert.areEqual(1, byDeal.size(), 'The deal resolves to its underwriting child');
        Assert.areEqual(uw.Id, byDeal[0].Id, 'and it is the right child');
        Assert.areEqual(1, byChild.size(), 'The child resolves back');
        Assert.areEqual(deal.Id, byChild[0].Opportunity__c,
            'and carries the parent Id the stamp writes to');
        Assert.isTrue(emptyIn.isEmpty(), 'Empty input returns an empty list, never null');
        Assert.isTrue(nullIn.isEmpty(), 'Null input returns an empty list, never null');
    }
}
