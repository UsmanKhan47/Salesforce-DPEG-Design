/**
 * Tests for ProcessInstanceSelector. Covers selectPendingByTargetId — the sole
 * method — for the found / none / null-input branches.
 *
 * ProcessInstance is a system approval object with no TestDataFactory equivalent;
 * a "found" row can only exist after a live Approval.process() submission against
 * an active, deployed ApprovalProcess. This test reuses the exact live-submission
 * pattern already established and passing in OpportunityApprovalControllerTest
 * (Opportunity.LOI_Approval, entry criteria StageName = 'LOI'), submitting via
 * Approval.ProcessSubmitRequest directly rather than through the controller so
 * this test exercises the selector in isolation.
 *
 * NO 251-BULK_N SCENARIO — documented, not omitted by oversight:
 *   1. selectPendingByTargetId(Id) takes a single Id, not a Set<Id>, so the
 *      Set<Id>-bulk-read trigger this gap-fill's instructions call for does not
 *      apply to this signature.
 *   2. Salesforce enforces at most ONE open (Pending) ProcessInstance per target
 *      record — the exact platform invariant OpportunityApprovalController's
 *      duplicate-submission guard depends on, and proven in this org by
 *      OpportunityApprovalControllerTest.secondSubmitThrows. "251 pending
 *      ProcessInstance rows for one target Id" is therefore not a producible
 *      state. Producing 251 pending rows across 251 distinct target Ids would
 *      require 251 live Approval.process() submissions inside one test
 *      transaction, which Salesforce's per-transaction governor limit on
 *      approval submissions blocks well before 251 is reached. This is
 *      documented rather than forced, in the same spirit as the P4 pilot's
 *      documented uncoverable canary branch.
 */
@isTest
private class ProcessInstanceSelectorTest {

    private static Opportunity makeEligibleOpp() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        return o;
    }

    @isTest
    static void selectPendingByTargetId_found_returnsPendingInstance() {
        Opportunity o = makeEligibleOpp();

        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(o.Id);
        Approval.process(req);

        Test.startTest();
        List<ProcessInstance> result = ProcessInstanceSelector.selectPendingByTargetId(o.Id);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'A live-submitted approval must appear as a Pending ProcessInstance for its target');
    }

    @isTest
    static void selectPendingByTargetId_none_returnsEmptyList() {
        Opportunity o = makeEligibleOpp(); // eligible for approval but never submitted

        Test.startTest();
        List<ProcessInstance> result = ProcessInstanceSelector.selectPendingByTargetId(o.Id);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'A target with no submitted approval has no Pending ProcessInstance rows');
    }

    @isTest
    static void selectPendingByTargetId_nullInput_returnsEmptyList() {
        Test.startTest();
        List<ProcessInstance> result = ProcessInstanceSelector.selectPendingByTargetId(null);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'Null input returns an empty list, not null');
    }
}
