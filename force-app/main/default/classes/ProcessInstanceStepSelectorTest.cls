/**
 * Tests for ProcessInstanceStepSelector.AuditReads.selectApprovedStepsByTargetIds —
 * the sole method — covering the null / empty / 251-bulk / real-approval-data branches.
 *
 * ProcessInstanceStep is a system approval-history object with no TestDataFactory
 * equivalent. A row only exists after a live Approval.process() submission against an
 * active, deployed ApprovalProcess; a step with StepStatus = 'Approved' additionally
 * requires an approver to ACT on the resulting work item.
 *
 * -- REPOINTED 2026-09-03 ONTO LOI__c.LOI_Approval ---------------------------------------------
 * This class used to submit an Opportunity at StageName = 'LOI' into Opportunity.LOI_Approval.
 * That process is RETIRED. Measured against usman-dpeg on 2026-09-03: ProcessDefinition
 * 04aiw0000001sxdAAA (LOI_Approval on Opportunity) is State = 'Obsolete', and there are ZERO
 * active approval processes on Opportunity of any kind, so the submission below returned
 * NO_APPLICABLE_PROCESS.
 *
 * 🔴 THE OBJECT UNDER TEST IS THE SELECTOR, NOT THE APPROVAL. The selector filters on
 * StepStatus and ProcessInstance.TargetObjectId and knows nothing about which object an approval
 * targets, so the target here is pure scaffolding - any object with a live approval process would
 * do. LOI__c was chosen to keep the fixture identical to its sibling
 * ProcessInstanceSelectorTest.makeSubmittableLoi, so the two classes cannot drift apart. No
 * assertion in this class names a process, a label or an object, so the repoint moves the
 * fixture only.
 *
 * FIXTURE CONTRACT, read from the ORG's own copy of the process on 2026-09-03:
 *   entry criteria '1 AND 2': LOI__c.Stage__c equals 'Under Review'
 *                         AND LOI__c.RecordType equals 'Acquisition LOI' (the record type LABEL)
 *   allowedSubmitters type = owner - so the LOI must be inserted BY the running user. The one the
 *   deal auto-creates on entry to the LOI stage is owned by the Acquisition QUEUE and could never
 *   be submitted here, which is why the parent deal is left at the factory default 'New'.
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

    /**
     * The LOI__c.Stage__c value approvalProcesses/LOI__c.LOI_Approval accepts, together with
     * record type Acquisition_LOI. A literal on purpose - sharing a production constant would
     * make "the process and the fixture agree" indistinguishable from "the fixture agrees with
     * itself".
     */
    private static final String LOI_STAGE_UNDER_REVIEW = 'Under Review';

    /**
     * An acquisition LOI that satisfies LOI__c.LOI_Approval's entry criteria and is OWNED BY THE
     * RUNNING USER (allowedSubmitters = owner), so a submission is not refused by the platform
     * before entry criteria are considered.
     */
    private static LOI__c makeSubmittableLoi() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true); // StageName 'New'
        LOI__c loi = TestDataFactory.createLoi(deal.Id, true); // Acquisition_LOI, seeded 'Draft'
        update new LOI__c(Id = loi.Id, Stage__c = LOI_STAGE_UNDER_REVIEW);
        return loi;
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
        LOI__c loi = makeSubmittableLoi();
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(loi.Id);
        Approval.ProcessResult submitted = Approval.process(req);
        // 🔴 THE PRECONDITION IS THE WHOLE TEST. This method asserts an EMPTY list, which is also
        // what a submission that never happened produces - so without this line a broken fixture
        // reads as a passing filter. It is the exact failure mode that hid the retired-process
        // breakage until a production RunLocalTests surfaced it.
        Assert.isTrue(submitted.isSuccess(),
            'PRECONDITION FAILED: the LOI was not accepted into LOI__c.LOI_Approval, so there is '
            + 'no approval trail at all and the assertion below would pass vacuously.');

        Test.startTest();
        List<ProcessInstanceStep> result =
            new ProcessInstanceStepSelector.AuditReads()
                .selectApprovedStepsByTargetIds(new Set<Id>{ loi.Id });
        Test.stopTest();

        Assert.isTrue(result.isEmpty(),
            'A submitted-but-not-yet-approved LOI has no StepStatus = Approved history step');
    }
}
