/**
 * Tests ApprovalAuditService, focused on the UNDERWRITING gate that was repointed on 2026-08-28
 * to read the approval history of the deal's UNDERWRITING CHILD instead of the deal's own.
 *
 * ── 🔴 WHAT THIS CLASS CAN AND CANNOT PROVE, AND WHY IT IS SHAPED THIS WAY ────────────────────
 * The stamp's inputs are ProcessInstanceStep rows, which are created only by a real approval. The
 * new Underwriting__c.Underwriting_Approval process is owned by the parallel declarative stream
 * and is not deployed yet, and ProcessInstanceStep cannot be inserted, mocked or backdated from
 * Apex. So NO test in this file can assert "the approver's Id landed in UW_Approved_By__c" — that
 * is post-deploy check P-4 in agent-output/design-requirements.md §8, and it must not be skipped
 * on the strength of a green suite here.
 *
 * The tests below therefore pin the two things that ARE decidable in Apex and that carry the
 * actual regression risk:
 *
 *   1. THE REPOINT ITSELF, asserted as a NEGATIVE. An approval taken on the OPPORTUNITY must no
 *      longer stamp anything. That is exactly the state the repoint creates, it is sensitive
 *      TODAY (Opportunity.Underwriting_Approval is still active, so the fixture can really be
 *      built), and reverting the repoint turns it red immediately. It is also the single most
 *      dangerous behaviour in this change, because the class swallows every failure by design:
 *      before the repoint this stamp read the deal's history and worked; after the old process is
 *      deactivated it would find nothing and stamp nothing, with no error anywhere.
 *
 *   2. GRACEFUL DEGRADATION. Every no-history and degenerate path must complete silently without
 *      touching the deal and without throwing — because this runs inside the approval's own
 *      transaction, and a throw here would roll the approval back. That contract is why the class
 *      catches Exception rather than DmlException (see its own header, incident 2026-08-05).
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
     * 🔴 THE REPOINT, asserted as the negative it creates.
     *
     * A real, granted approval on the OPPORTUNITY (still possible today — the old process is
     * active until the declarative stream deactivates it) must produce NO audit stamp, because
     * the underwriting gate no longer looks at the deal's approval history.
     *
     * ⚠ This is not "asserting a bug". It is asserting that the read moved: the deal's own history
     * is now the wrong place to look for an underwriting decision, and stamping from it would mean
     * the repoint never happened. Revert ApprovalAuditService's mapping and this reds.
     */
    @isTest
    static void anApprovalOnTheOpportunityNoLongerStampsTheAudit() {
        Opportunity deal = dealWithUnderwriting();

        Approval.ProcessSubmitRequest submit = new Approval.ProcessSubmitRequest();
        submit.setObjectId(deal.Id);
        Approval.process(submit);

        Test.startTest();
        ProcessInstanceWorkitem item = [
            SELECT Id FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :deal.Id LIMIT 1
        ];
        Approval.ProcessWorkitemRequest decide = new Approval.ProcessWorkitemRequest();
        decide.setWorkitemId(item.Id);
        decide.setAction('Approve');
        Approval.process(decide);
        Test.stopTest();

        // Precondition — if this ever returns 0, the fixture stopped building a real approval and
        // the assertion below would be vacuously green.
        Assert.areEqual(1, [
            SELECT COUNT() FROM ProcessInstanceStep
            WHERE ProcessInstance.TargetObjectId = :deal.Id AND StepStatus = 'Approved'
        ], 'Fixture precondition: a genuine approved step must exist ON THE OPPORTUNITY');

        Opportunity after = [
            SELECT UW_Approved_By__c, UW_Approval_Date__c FROM Opportunity WHERE Id = :deal.Id
        ];
        Assert.isNull(after.UW_Approved_By__c,
            'The underwriting gate must read the UNDERWRITING record\'s history, not the deal\'s');
        Assert.isNull(after.UW_Approval_Date__c,
            'No approval date may be stamped from an Opportunity-side approval any more');
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
