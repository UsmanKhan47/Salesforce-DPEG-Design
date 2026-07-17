/**
 * Tests for ProcessInstanceStepSelector.AuditReads.selectApprovedStepsByTargetIds —
 * the sole method — covering the null / empty / 251-bulk / real-approval-data branches.
 *
 * ProcessInstanceStep is a system approval-history object with no TestDataFactory
 * equivalent. A row only exists after a live Approval.process() submission against an
 * active, deployed ApprovalProcess; a step with StepStatus = 'Approved' additionally
 * requires an approver to ACT on the resulting work item. This test reuses the exact
 * live-submission pattern already established and passing in ProcessInstanceSelectorTest
 * / OpportunityApprovalControllerTest (Opportunity.LOI_Approval, entry criteria
 * StageName = 'LOI').
 *
 * COVERAGE MODEL (full line coverage, no faked data):
 *   - null / empty input exercises the guard clause.
 *   - a 251-Id set with no approvals exercises the SOQL line (the query runs and
 *     returns empty), proving the IN-bind is bulk-safe at 251.
 *   - a real submitted-but-not-yet-acted approval exercises the SOQL against genuine
 *     ProcessInstanceStep data and proves the StepStatus = 'Approved' filter EXCLUDES
 *     the pending/started step (the submission stays Pending — never auto-approved,
 *     as ProcessInstanceSelectorTest.selectPendingByTargetId_found also asserts).
 *
 * WHY NO "populated Approved step" ASSERTION — documented, not omitted by oversight:
 *   Producing a StepStatus = 'Approved' row requires an approver to Approve the work
 *   item, which depends on the approval process's approver configuration in the target
 *   org and on the running user being an eligible approver — org/config state a unit
 *   test cannot deterministically guarantee. This is documented rather than forced,
 *   in the same spirit as ProcessInstanceSelectorTest's documented uncoverable
 *   live-approval scenario. The query line itself is fully covered by the branches
 *   above; only the assertion that populated rows come back is deferred.
 */
@isTest
private class ProcessInstanceStepSelectorTest {

    private static final Integer BULK_N = 251;

    /** An Opportunity that satisfies the LOI_Approval entry criteria (StageName = 'LOI'). */
    private static Opportunity makeEligibleOpp() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        return o;
    }

    @isTest
    static void selectApprovedStepsByTargetIds_nullInput_returnsEmpty() {
        Test.startTest();
        List<ProcessInstanceStep> result =
            new ProcessInstanceStepSelector.AuditReads().selectApprovedStepsByTargetIds(null);
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'Null input returns an empty list, not null');
    }

    @isTest
    static void selectApprovedStepsByTargetIds_emptyInput_returnsEmpty() {
        Test.startTest();
        List<ProcessInstanceStep> result =
            new ProcessInstanceStepSelector.AuditReads().selectApprovedStepsByTargetIds(new Set<Id>());
        Test.stopTest();

        Assert.isTrue(result.isEmpty(), 'Empty input returns an empty list, not null');
    }

    @isTest
    static void selectApprovedStepsByTargetIds_bulk251NoApprovals_returnsEmpty() {
        // 251 real target Ids with no approval submitted — the SYSTEM_MODE query must
        // execute with a 251-element IN-bind (bulk-safe) and return no Approved steps.
        List<Opportunity> opps = TestDataFactory.createOpportunities(BULK_N, true);
        Set<Id> targetIds = (new Map<Id, Opportunity>(opps)).keySet();

        Test.startTest();
        List<ProcessInstanceStep> result =
            new ProcessInstanceStepSelector.AuditReads().selectApprovedStepsByTargetIds(targetIds);
        Test.stopTest();

        Assert.areEqual(BULK_N, targetIds.size(), 'Guard: the bulk read is exercised at 251 target Ids');
        Assert.isTrue(result.isEmpty(),
            'Targets with no submitted approval have no Approved ProcessInstanceStep rows');
    }

    @isTest
    static void selectApprovedStepsByTargetIds_submittedNotApproved_excludesPendingStep() {
        // A live submission creates the approval trail but leaves it PENDING (no
        // approver has acted), so no step is StepStatus = 'Approved'. This exercises
        // the query against real ProcessInstanceStep data and proves the
        // StepStatus = 'Approved' filter excludes the pending/started step.
        Opportunity o = makeEligibleOpp();
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(o.Id);
        Approval.process(req);

        Test.startTest();
        List<ProcessInstanceStep> result =
            new ProcessInstanceStepSelector.AuditReads()
                .selectApprovedStepsByTargetIds(new Set<Id>{ o.Id });
        Test.stopTest();

        Assert.isTrue(result.isEmpty(),
            'A submitted-but-not-yet-approved deal has no StepStatus = Approved history step');
    }
}
