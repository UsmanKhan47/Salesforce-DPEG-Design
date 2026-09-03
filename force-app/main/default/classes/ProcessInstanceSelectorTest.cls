/**
 * Tests for ProcessInstanceSelector - all THREE methods.
 *
 * ⚠ CORRECTED 2026-09-01. This line read "Covers selectPendingByTargetId - the sole method - for
 * the found / none / null-input branches." That was true when written and went stale silently:
 * `selectHistoryByTargetIds` and `selectTrackerStatesByTargetIds` landed later and neither was
 * covered, which left the class at 60% against the 75% per-class production gate on a validate run.
 * Nothing warns you - a selector method with no test still compiles, still deploys from a sandbox,
 * and only fails when the class is in a PRODUCTION payload.
 *   selectPendingByTargetId          found / none / null
 *   selectHistoryByTargetIds         found (steps + label) / null+empty
 *   selectTrackerStatesByTargetIds   found (API name) / ordering / null+empty
 *
 * ProcessInstance is a system approval object with no TestDataFactory equivalent; a "found" row
 * can only exist after a live Approval.process() submission against an active, deployed
 * ApprovalProcess.
 *
 * -- REPOINTED 2026-09-03 ONTO LOI__c.LOI_Approval ----------------------------------------------
 * This class used to submit an Opportunity at StageName = 'LOI' into Opportunity.LOI_Approval.
 * That process is RETIRED. Measured against usman-dpeg on 2026-09-03: ProcessDefinition
 * 04aiw0000001sxdAAA (LOI_Approval on Opportunity) is State = 'Obsolete', and there are ZERO
 * active approval processes on Opportunity of any kind, so every submission here returned
 * NO_APPLICABLE_PROCESS.
 *
 * 🔴 THE OBJECT UNDER TEST IS THE SELECTOR, NOT THE APPROVAL. Nothing in ProcessInstanceSelector
 * knows or cares which object an approval targets, so the target here is pure scaffolding and any
 * object with a live approval process would do. LOI__c.LOI_Approval (ProcessDefinition
 * 04aiw0000005ub3AAA, State = 'Active') was chosen for one specific reason and it is worth
 * stating: its DeveloperName is `LOI_Approval` and its Name is `LOI Approval`, IDENTICAL to the
 * retired Opportunity process. So the two assertions that are the entire point of this class --
 * the API-name/label split below -- survive VERBATIM, and this repoint changes no assertion at
 * all, only the fixture. Repointing onto Underwriting__c would have forced both strings to move
 * and made a fixture repair look like a change of intent.
 *
 * FIXTURE CONTRACT, read from the ORG's own copy of the process on 2026-09-03:
 *   entry criteria '1 AND 2': LOI__c.Stage__c equals 'Under Review'
 *                         AND LOI__c.RecordType equals 'Acquisition LOI' (the record type LABEL)
 *   allowedSubmitters type = owner
 * makeSubmittableLoi satisfies all three. The parent deal is deliberately left at the factory
 * default StageName 'New' rather than 'LOI': entering the LOI stage would make
 * OpportunityReviewService auto-create a SECOND, QUEUE-OWNED LOI, and `owner` submitters means
 * that record could never be submitted by the runner - noise this class has no use for.
 *
 * NO 251-BULK_N SCENARIO - documented, not omitted by oversight:
 *   1. selectPendingByTargetId(Id) takes a single Id, not a Set<Id>, so the Set<Id>-bulk-read
 *      trigger this gap-fill's instructions call for does not apply to this signature.
 *   2. Salesforce enforces at most ONE open (Pending) ProcessInstance per target record - the
 *      exact platform invariant OpportunityApprovalController's duplicate-submission guard
 *      depends on, and proven in this org by
 *      OpportunityApprovalServiceTest.secondSubmitThrowsApprovalException. "251 pending
 *      ProcessInstance rows for one target Id" is therefore not a producible state. Producing 251
 *      pending rows across 251 distinct target Ids would require 251 live Approval.process()
 *      submissions inside one test transaction, which Salesforce's per-transaction governor limit
 *      on approval submissions blocks well before 251 is reached. This is documented rather than
 *      forced, in the same spirit as the P4 pilot's documented uncoverable canary branch.
 */
@isTest
private class ProcessInstanceSelectorTest {

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
    static void selectPendingByTargetId_found_returnsPendingInstance() {
        LOI__c loi = submittedLoi();

        Test.startTest();
        List<ProcessInstance> result = ProcessInstanceSelector.selectPendingByTargetId(loi.Id);
        Test.stopTest();

        Assert.areEqual(1, result.size(), 'A live-submitted approval must appear as a Pending ProcessInstance for its target');
    }

    @isTest
    static void selectPendingByTargetId_none_returnsEmptyList() {
        LOI__c loi = makeSubmittableLoi(); // eligible for approval but never submitted

        Test.startTest();
        List<ProcessInstance> result = ProcessInstanceSelector.selectPendingByTargetId(loi.Id);
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

    // =========================================================================================
    // selectHistoryByTargetIds / selectTrackerStatesByTargetIds
    //
    // ⚠ ADDED 2026-08-31. This class's opening comment called selectPendingByTargetId "the sole
    // method" - true when written, false since the two Set<Id> reads landed, and the gap put the
    // class at 60% against the 75% per-class production gate. The header's NO-251-BULK argument
    // still stands and now stands for a SECOND reason: these two take a Set<Id>, but a pending
    // ProcessInstance can only be produced by a live Approval.process() submission, and the
    // per-transaction cap on approval submissions is reached long before 251.
    // =========================================================================================

    /** Submits an eligible LOI into LOI__c.LOI_Approval and asserts the platform accepted it. */
    private static LOI__c submittedLoi() {
        LOI__c loi = makeSubmittableLoi();
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(loi.Id);
        Approval.ProcessResult result = Approval.process(req);
        Assert.isTrue(result.isSuccess(),
            'PRECONDITION FAILED: the LOI was not accepted into LOI__c.LOI_Approval. Every '
            + 'assertion below would then be measuring an empty list, which on a selector test '
            + 'looks like a legitimate "nothing submitted" answer rather than a broken fixture.');
        return loi;
    }

    /**
     * 🔴 THE API NAME, NOT THE LABEL - the entire reason selectTrackerStatesByTargetIds exists as
     * a separate method from selectHistoryByTargetIds.
     *
     * `ProcessDefinition.Name` is display copy and has already moved inside this programme: FOUR of
     * the five disposition approvals were relabelled on 2026-08-26 with no `<fullName>` change. A
     * consumer that identified an approval by the label would have silently stopped matching. This
     * asserts the DeveloperName verbatim, so a build that swapped the field back to `Name` fails
     * here - `LOI_Approval` and `LOI Approval` are different strings.
     *
     * ⚠ BOTH EXPECTED STRINGS ARE UNCHANGED BY THE 2026-09-03 REPOINT, AND THAT IS VERIFIED, NOT
     * ASSUMED. The org's ProcessDefinition 04aiw0000005ub3AAA (TableEnumOrId = LOI__c) carries
     * DeveloperName = 'LOI_Approval' and Name = 'LOI Approval' - the same pair the retired
     * Opportunity definition carried. The underscore-versus-space discriminator is therefore
     * exactly as sharp as it was.
     */
    @isTest
    static void selectTrackerStatesByTargetIds_carriesTheApiNameNotTheLabel() {
        LOI__c loi = submittedLoi();

        Test.startTest();
        List<ProcessInstance> rows =
            ProcessInstanceSelector.selectTrackerStatesByTargetIds(new Set<Id>{ loi.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'One live submission must produce exactly one ProcessInstance for its target');
        Assert.areEqual('LOI_Approval', rows[0].ProcessDefinition.DeveloperName,
            'The row must carry the process API NAME. Reading "LOI Approval" here means the query '
            + 'selects ProcessDefinition.Name - the LABEL - and every consumer keyed on the API '
            + 'name silently stops matching the day someone relabels a process in Setup');
        Assert.areEqual('Pending', rows[0].Status,
            'and the live state of a just-submitted approval is Pending');
        Assert.areEqual(loi.Id, rows[0].TargetObjectId,
            'and it must name the record the approval targets - the LOI itself since the cutover, '
            + 'never its parent deal');
        Assert.isNotNull(rows[0].CreatedDate, 'the submission timestamp is selected');
        Assert.isNull(rows[0].CompletedDate,
            'and there is no completion timestamp while pending - null IS the live state here, so '
            + 'a consumer must not treat a blank date as "missing data"');
    }

    /**
     * ⚠ NEWEST SUBMISSION FIRST, AND THE `Id DESC` TIE-BREAK IS WHAT MAKES IT A TOTAL ORDER.
     * `CreatedDate` is second-granular and both submissions here happen inside one transaction, so
     * `CreatedDate DESC` alone leaves the order arbitrary - this test is precisely the case the
     * selector's tie-break exists for, and it fails RED (not silently) if the tie-break is removed.
     *
     * ⚠ TWO SEPARATE TARGETS, NOT TWO SUBMISSIONS OF ONE. The platform allows at most one open
     * ProcessInstance per record, so "two submissions" can only mean two records. Each
     * submittedLoi() call builds its own deal and its own LOI, and `second` is created and
     * submitted strictly after `first`, which is what makes the ordering claim meaningful.
     */
    @isTest
    static void selectTrackerStatesByTargetIds_ordersNewestSubmissionFirst() {
        LOI__c first = submittedLoi();
        LOI__c second = submittedLoi();

        Test.startTest();
        List<ProcessInstance> rows = ProcessInstanceSelector.selectTrackerStatesByTargetIds(
            new Set<Id>{ first.Id, second.Id }
        );
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both submissions must come back');
        Assert.areEqual(second.Id, rows[0].TargetObjectId,
            'The MOST RECENTLY submitted approval must be first. The consumer takes the FIRST row '
            + 'seen per key as "the newest", so a reversed or arbitrary order here makes a '
            + 'resubmitted approval report its ORIGINAL state forever');
        Assert.areEqual(first.Id, rows[1].TargetObjectId, 'and the older one second');
    }

    /**
     * ⚠ THE EMPTY-INPUT CONTRACT IS "NO QUERY", NOT MERELY "EMPTY LIST", and the query count is
     * what pins it. Both methods are called once per page render; a selector that ran a query to
     * discover it had nothing to look for would spend a SOQL on every view of a sale with no
     * children. Asserted for both Set<Id> methods in one place because they share the guard shape.
     */
    @isTest
    static void nullAndEmptyInputs_returnEmptyAndIssueNoQuery() {
        Set<Id> empty = new Set<Id>();

        Test.startTest();
        Integer before = Limits.getQueries();
        List<ProcessInstance> historyNull = ProcessInstanceSelector.selectHistoryByTargetIds(null);
        List<ProcessInstance> historyEmpty = ProcessInstanceSelector.selectHistoryByTargetIds(empty);
        List<ProcessInstance> statesNull =
            ProcessInstanceSelector.selectTrackerStatesByTargetIds(null);
        List<ProcessInstance> statesEmpty =
            ProcessInstanceSelector.selectTrackerStatesByTargetIds(empty);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.isTrue(historyNull.isEmpty(), 'null input to selectHistoryByTargetIds is empty');
        Assert.isTrue(historyEmpty.isEmpty(), 'empty input to selectHistoryByTargetIds is empty');
        Assert.isTrue(statesNull.isEmpty(), 'null input to selectTrackerStatesByTargetIds is empty');
        Assert.isTrue(statesEmpty.isEmpty(), 'empty input is empty');
        Assert.areEqual(0, used,
            'FOUR guarded calls must issue ZERO queries. Any number above zero means a guard was '
            + 'removed and the empty case now costs a SOQL on every render. Used: ' + used);
    }

    /**
     * The history read carries the STEP rows, which is what distinguishes it from the tracker read
     * - the card it backs renders one line per step, not one line per approval.
     *
     * ⚠ IT ALSO PINS THE LABEL SIDE OF THE SPLIT. This method selects `ProcessDefinition.Name` and
     * the tracker one selects `DeveloperName`, deliberately: this card SHOWS the process to a human
     * and wants the human-readable label. Asserting both here and above is what makes the split
     * legible - harmonising the two queries onto one field would break exactly one of these tests.
     */
    @isTest
    static void selectHistoryByTargetIds_carriesStepsAndTheDisplayLabel() {
        LOI__c loi = submittedLoi();

        Test.startTest();
        List<ProcessInstance> rows =
            ProcessInstanceSelector.selectHistoryByTargetIds(new Set<Id>{ loi.Id });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'One submission, one ProcessInstance');
        Assert.areEqual('LOI Approval', rows[0].ProcessDefinition.Name,
            'This method must carry the human-readable LABEL. Reading "LOI_Approval" here means it '
            + 'was harmonised onto DeveloperName and the history card now shows an API name to a '
            + 'user');
        Assert.isNotNull(rows[0].SubmittedById, 'the submitter is selected for display');
        // ⚠ A child subquery that matches nothing comes back NULL, not as an empty list, so the
        // null check must come FIRST - otherwise a dropped subquery arrives as a
        // NullPointerException on the line below instead of as this named failure.
        List<ProcessInstanceHistory> steps = rows[0].StepsAndWorkitems;
        Assert.isNotNull(steps,
            'The STEP subquery is the whole point of this method versus the tracker one. Null here '
            + 'means it was dropped from the query and the history card renders headers with no '
            + 'rows');
        Assert.areEqual(false, steps.isEmpty(),
            'and a PENDING approval has at least one outstanding step/workitem, so an empty list '
            + 'means the subquery ran but matched nothing - a different defect from a dropped one');
    }
}
