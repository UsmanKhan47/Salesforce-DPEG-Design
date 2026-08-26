/**
 * Tests for `DispositionApprovalHistoryService` AND its thin controller
 * `DispositionApprovalHistoryController` — the consolidated Approval History card on the
 * Disposition record page. Built 2026-08-26.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE ONE PROPERTY THIS CLASS EXISTS TO PROVE
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * The disposition flow's approvals target THREE objects, and the platform's Approval History
 * related list can only show the ones whose `TargetObjectId` IS the record it renders on:
 *
 *   Sale_Decision_Approval      -> Disposition__c
 *   Broker_Selection_Approval   -> Disposition__c        (off-market only)
 *   Closing_Approval            -> Disposition__c
 *   Broker_Finalize_Approval    -> BOV_Submission__c     <- INVISIBLE on the parent page
 *   Offer_Selection_Approval    -> Disposition_Offer__c  <- INVISIBLE on the parent page
 *
 * User report, 2026-08-25: *"I sent the disposition for approval on BOV Outreach but it is not
 * appearing on the disposition record."* Nothing was broken — `BOV Outreach` is exactly the stage
 * whose approval targets a `BOV_Submission__c`.
 * 🔴 SO "THE SERVICE RETURNS SOME ROWS" IS NOT THE PROPERTY UNDER TEST. The property is that the
 * two CHILD-TARGETED approvals come back, keyed to the CHILD they target. A fixture in which every
 * approval targeted the Disposition would pass a naive assertion while the card was still broken
 * in precisely the reported way — which is why `threeApprovals_acrossThreeObjects...` below
 * asserts on the target Id SET and not merely on a row count.
 *
 * ── ⚠ THESE ARE REAL APPROVAL SUBMISSIONS, NOT FABRICATED ProcessInstance ROWS ────────────────
 * `ProcessInstance` / `ProcessInstanceHistory` are NOT createable — no fixture can insert one — so
 * every row here is produced by a genuine `Approval.ProcessSubmitRequest`, exactly as the platform
 * would. That is a feature: it means the entry criteria in the five `approvalProcesses/` files are
 * part of what these tests hold in place. `submit()` asserts `result.isSuccess()` as a PRECONDITION
 * for that reason — a silently refused submit would leave every downstream assertion measuring an
 * empty list, and "0 rows" is the very answer this card exists to disprove.
 *
 * ── WHY THE FIXTURE SITS AT `Closing` ────────────────────────────────────────────────────────
 * It is the one stage at which all three approvals can be pending AT ONCE, which is what makes a
 * single-disposition, three-row assertion possible:
 *   • `Closing_Approval` needs `Disposition_Stage__c = 'Closing'` AND
 *     `Wire_Verification_Completed__c = true`;
 *   • `Broker_Finalize_Approval` needs only `Submission_Status__c = 'Selected'` on the BOV;
 *   • `Offer_Selection_Approval` needs only `Is_Selected__c = true` on the offer.
 * It is also the honest end-state: a sale at Closing really has had a broker selected and an offer
 * accepted. The signed NDA is required by `All_NDAs_Signed_Before_Progression` and is copied from
 * `DispositionApprovalProcessesTest.closingApproved_advancesToSaleCloses`, which is the proven
 * recipe for getting a Disposition into `Closing_Approval`.
 *
 * ⚠ THE PARENT IS SUBMITTED **LAST** IN EVERY TEST THAT SUBMITS IT. These approvals carry
 * `recordEditability = AdminOnly`, so a submitted Disposition LOCKS; inserting or approving a child
 * that writes back to the parent after that point fails on the lock, not on anything under test.
 * Order the submits parent-last and the problem does not arise.
 *
 * ── BULK ──
 * ⚠ `.claude/rules/bulk-test-rule.md`'s 251-record mandate does NOT attach to this class, and that
 * is an argued position rather than an omission: nothing here is a trigger, a batch, a queueable or
 * a DML-performing service — it is a READ invoked once per page view, and it performs no DML at
 * all. 🔴 THE PROPERTY THAT MATTERS AT VOLUME IS A **CONSTANT QUERY COUNT ACROSS MANY CHILDREN**,
 * and it IS asserted (`manyChildren_costsExactlyFourQueries`). A sale with a dozen BOVs and a dozen
 * offers is ordinary; a per-child lookup would be SOQL in a loop on a page render, and a row-count
 * assertion would never catch it.
 *
 * @see force-app/main/default/classes/DispositionApprovalHistoryService.cls
 * @see force-app/main/default/classes/DispositionApprovalProcessesTest.cls (the submit/decide
 *      recipe and the entry criteria this class depends on)
 */
@isTest
private class DispositionApprovalHistoryServiceTest {

    private static final String STAGE_CLOSING = 'Closing';
    private static final String STAGE_BOV_OUTREACH = 'BOV Outreach';
    private static final String SUBMIT_COMMENT = 'Please review — wire is verified.';

    /**
     * ONE disposition at `Closing`, with the signed NDA the progression rule requires, ONE selected
     * BOV submission and ONE selected offer. Nothing is submitted here — the approvals are raised
     * inside each test method, so a test that needs a clean, never-submitted sale (see
     * `nothingSubmitted_returnsNoRows`) simply does not submit.
     */
    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);

        Disposition__c disposition = TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, false
        );
        disposition.Disposition_Stage__c = STAGE_CLOSING;
        insert disposition;

        NDA__c nda = TestDataFactory.createDispositionNda(disposition.Id, false);
        nda.Status__c = 'Signed';
        insert nda;

        BOV_Submission__c submission = TestDataFactory.createBovSubmission(disposition.Id, false);
        submission.Submission_Status__c = 'Selected';
        insert submission;

        Disposition_Offer__c offer = TestDataFactory.createDispositionOffer(disposition.Id, false);
        offer.Is_Selected__c = true;
        offer.Offer_Amount__c = 6100000;
        insert offer;

        // Last, so `Closing_Approval`'s second entry criterion holds without the record being
        // locked while its children are created.
        disposition.Wire_Verification_Completed__c = true;
        update disposition;
    }

    /** The scaffold sale. Keyed on the stage so a disposition created INSIDE a test cannot match. */
    private static Disposition__c scaffold() {
        return [
            SELECT Id, Name
            FROM Disposition__c
            WHERE Disposition_Stage__c = :STAGE_CLOSING
            LIMIT 1
        ];
    }

    private static BOV_Submission__c scaffoldBov() {
        return [SELECT Id, Name FROM BOV_Submission__c LIMIT 1];
    }

    private static Disposition_Offer__c scaffoldOffer() {
        return [SELECT Id, Name FROM Disposition_Offer__c LIMIT 1];
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    /**
     * Submits a record into whichever active approval process it satisfies, and ASSERTS that it was
     * accepted. The assertion is the point: `Approval.process` reporting failure would leave the
     * card with nothing to show, and "nothing to show" is the exact wrong answer under test.
     *
     * @param targetId The record to submit.
     * @param comments The submit-dialog note, which lands on the `Started` step and nowhere else.
     */
    private static void submit(Id targetId, String comments) {
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(targetId);
        req.setComments(comments);
        Approval.ProcessResult result = Approval.process(req);
        Assert.isTrue(result.isSuccess(),
            'PRECONDITION FAILED: ' + targetId + ' was not accepted into an approval process. '
            + 'Every downstream assertion in this test is meaningless until this passes.');
    }

    /**
     * Acts on the one outstanding workitem for a target.
     *
     * @param targetId The record under approval.
     * @param action   'Approve' or 'Reject'.
     * @param comments The approver's note.
     */
    private static void decide(Id targetId, String action, String comments) {
        ProcessInstanceWorkitem item = [
            SELECT Id FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :targetId LIMIT 1
        ];
        Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
        req.setWorkitemId(item.Id);
        req.setAction(action);
        req.setComments(comments);
        Approval.process(req);
    }

    private static Map<Id, DispositionApprovalHistoryService.ApprovalRow> byTarget(
        List<DispositionApprovalHistoryService.ApprovalRow> rows
    ) {
        Map<Id, DispositionApprovalHistoryService.ApprovalRow> byId =
            new Map<Id, DispositionApprovalHistoryService.ApprovalRow>();
        for (DispositionApprovalHistoryService.ApprovalRow row : rows) {
            byId.put(row.targetId, row);
        }
        return byId;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE HEADLINE TEST
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * Three approvals raised against three DIFFERENT objects all appear on the Disposition, each
     * naming and linking to the record it actually targets.
     *
     * 🔴 THE TARGET-ID SET IS THE ASSERTION THAT MATTERS. A row count of three would be satisfied
     * by three approvals all targeting the Disposition — which is the state the platform's own
     * related list already handles, and therefore proves nothing about the defect.
     */
    @isTest
    static void threeApprovals_acrossThreeObjects_allAppearOnTheDisposition() {
        Disposition__c disposition = scaffold();
        BOV_Submission__c submission = scaffoldBov();
        Disposition_Offer__c offer = scaffoldOffer();

        // Parent LAST — a submitted Disposition locks (recordEditability = AdminOnly).
        submit(submission.Id, 'Broker selected on score.');
        submit(offer.Id, 'Best price received.');
        submit(disposition.Id, SUBMIT_COMMENT);

        Test.startTest();
        List<DispositionApprovalHistoryService.ApprovalRow> rows =
            DispositionApprovalHistoryService.getHistory(disposition.Id);
        Test.stopTest();

        Assert.areEqual(3, rows.size(),
            'All three approvals must be on the card. Two of them target a CHILD record and are '
            + 'invisible in the standard Approval History related list — that is the whole defect.');

        Map<Id, DispositionApprovalHistoryService.ApprovalRow> byId = byTarget(rows);
        Assert.isTrue(byId.containsKey(submission.Id),
            'THE REPORTED DEFECT: the BOV Outreach approval targets the BOV_Submission__c, not the '
            + 'Disposition. If this key is missing the card reproduces the bug it was built to fix.');
        Assert.isTrue(byId.containsKey(offer.Id),
            'The offer-selection approval targets the Disposition_Offer__c and must be here too.');
        Assert.isTrue(byId.containsKey(disposition.Id),
            'The disposition-level approval must NOT be lost while adding the child ones.');

        Assert.areEqual('BOV-', byId.get(submission.Id).targetLabel.left(4),
            'A BOV row must be labelled with its own AutoNumber, not the parent\'s: '
            + byId.get(submission.Id).targetLabel);
        Assert.areEqual(disposition.Name, byId.get(disposition.Id).targetLabel,
            'The disposition row must carry the DISP- number');
        Assert.areEqual(6100000, byId.get(offer.Id).targetAmount,
            'The offer row carries its amount as a NUMBER — the component formats it exactly, '
            + 'because an abbreviated "$6.1M" cannot distinguish two nearby offers');

        Assert.isTrue(
            byId.get(submission.Id).targetUrl.contains('/BOV_Submission__c/'),
            'The link must point at the CHILD record. A link back to the Disposition would be '
            + 'indistinguishable from the defect: ' + byId.get(submission.Id).targetUrl);
        Assert.isTrue(
            byId.get(offer.Id).targetUrl.contains('/Disposition_Offer__c/'),
            'and likewise for the offer: ' + byId.get(offer.Id).targetUrl);

        Assert.areEqual(
            new Set<String>{
                'Closing Approval', 'Broker Finalize Approval', 'Offer Selection Approval'
            },
            new Set<String>{
                byId.get(disposition.Id).processName,
                byId.get(submission.Id).processName,
                byId.get(offer.Id).processName
            },
            'Each row is headlined by its approval process LABEL (ProcessDefinition.Name). '
            + 'Underscored values here would mean Name is returning the DeveloperName in this org.');

        for (DispositionApprovalHistoryService.ApprovalRow row : rows) {
            Assert.areEqual('Pending', row.status,
                'Nothing was decided, so every row must be Pending: ' + row.processName);
            Assert.isNull(row.completedDateTime,
                'A pending approval has no completion time — null here is the live state, and the '
                + 'component must not be handed a fabricated one');
            Assert.isNotNull(row.submittedBy, 'The submitter must be resolved for every row');
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE OTHER HALF OF THE CONTRACT
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * A sale nothing has ever been submitted against returns ZERO rows — not null, not an error.
     * This is the majority state of a disposition for most of its life, and the component renders
     * it as "Approval History (0)" with no prose.
     *
     * ⚠ THE PRECONDITION IS ASSERTED. The fixture carries a selected BOV and a selected offer, so
     * "no rows" here must mean "no approvals", not "no children" — without the second assertion a
     * service that silently failed to find any target would pass this test.
     */
    @isTest
    static void nothingSubmitted_returnsNoRows() {
        Disposition__c disposition = scaffold();

        Assert.areEqual(0, [SELECT COUNT() FROM ProcessInstance],
            'PRECONDITION: the fixture submits nothing, so the org must hold no approvals at all');
        Assert.areEqual(1, [SELECT COUNT() FROM BOV_Submission__c WHERE Disposition__c = :disposition.Id],
            'PRECONDITION: the sale DOES have a child. An empty result must mean "no approvals", '
            + 'not "no targets were found".');

        Test.startTest();
        List<DispositionApprovalHistoryService.ApprovalRow> rows =
            DispositionApprovalHistoryService.getHistory(disposition.Id);
        Test.stopTest();

        Assert.isNotNull(rows, 'The not-found contract is an EMPTY LIST, never null');
        Assert.areEqual(0, rows.size(), 'Nothing was submitted, so there is nothing to show');
    }

    /**
     * A decided approval carries its outcome, its completion time and the approver's step — and the
     * `Started` step is NOT one of the steps, while the SUBMITTER'S COMMENT survives on the row.
     *
     * 🔴 THAT PAIR IS THE POINT. Excluding `Started` avoids printing the submitter and the
     * submission time twice inside a 340px tile; hoisting its `Comments` is what keeps the exclusion
     * free of data loss, because the submit-dialog note lands on that step and NOWHERE else. A
     * change that drops one half without the other is exactly what this test catches.
     *
     * ⚠ RUN ON A SEPARATE `BOV Outreach` SALE, not the `Closing` scaffold. Approving a BOV advances
     * its PARENT (`handleApprovedSelections`), and the scaffold's parent is a `Closing` record one
     * step away from being locked by its own approval — approving into that is a fixture problem,
     * not a behaviour under test. `BOV Outreach -> Broker Selection` is the proven path in
     * `DispositionApprovalProcessesTest`.
     */
    @isTest
    static void approvedApproval_carriesTheDecisionStepAndHoistsTheSubmitComment() {
        Disposition__c fresh = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false
        );
        fresh.Disposition_Stage__c = STAGE_BOV_OUTREACH;
        insert fresh;

        BOV_Submission__c submission = TestDataFactory.createBovSubmission(fresh.Id, false);
        submission.Submission_Status__c = 'Selected';
        insert submission;

        submit(submission.Id, 'Recommend appointing this broker.');

        Test.startTest();
        decide(submission.Id, 'Approve', 'Approved by principal.');
        Test.stopTest();

        List<DispositionApprovalHistoryService.ApprovalRow> rows =
            DispositionApprovalHistoryService.getHistory(fresh.Id);

        Assert.areEqual(1, rows.size(), 'One approval was raised on this sale');
        DispositionApprovalHistoryService.ApprovalRow row = rows[0];

        Assert.areEqual('Approved', row.status, 'The outcome must be reported as Approved');
        Assert.isNotNull(row.completedDateTime,
            'A decided approval carries a completion time; a null here would render as still open');
        Assert.areEqual('Recommend appointing this broker.', row.submittedComments,
            'THE HOISTED HALF: the submit-dialog note lives ONLY on the excluded Started step. '
            + 'Null here means excluding that step silently deleted the submitter\'s comment.');

        Assert.isTrue(!row.steps.isEmpty(), 'The approver\'s decision must appear as a step');
        Set<String> stepStatuses = new Set<String>();
        for (DispositionApprovalHistoryService.StepRow step : row.steps) {
            stepStatuses.add(step.stepStatus);
        }
        Assert.isTrue(stepStatuses.contains('Approved'),
            'The decision step must be in the trail. Found: ' + stepStatuses);
        Assert.isFalse(stepStatuses.contains('Started'),
            'THE EXCLUDED HALF: the Started step duplicates submittedBy/submittedDateTime, which '
            + 'the row header already renders. Found: ' + stepStatuses);

        Boolean sawApproverComment = false;
        for (DispositionApprovalHistoryService.StepRow step : row.steps) {
            if ('Approved.'.equals(step.comments) || 'Approved by principal.'.equals(step.comments)) {
                sawApproverComment = true;
                Assert.isNotNull(step.createdDateTime, 'Every step carries its timestamp');
                Assert.isNotNull(step.stepId, 'Every step carries an Id — the component\'s key');
            }
        }
        Assert.isTrue(sawApproverComment,
            'The approver\'s own comment must reach the card, distinct from the submitter\'s');
    }

    /**
     * 🔴 THE HIGHEST-VALUE GOVERNOR ASSERTION IN THIS CLASS. The cost of the card is FOUR queries —
     * three target lookups and one `ProcessInstance` read — regardless of how many BOVs, offers or
     * approvals the sale carries. A future change that resolves one child per row would be SOQL in
     * a loop on a page render, and no row-count assertion would notice.
     *
     * ⚠ THE FIXTURE IS BUILT AND THE ID RESOLVED **BEFORE** THE MEASUREMENT WINDOW OPENS. A helper
     * called inside `Limits.getQueries()` brackets counts its own SELECTs and quietly inflates the
     * budget until the assertion means nothing.
     * ⚠ AND NO APPROVALS ARE SUBMITTED HERE ON PURPOSE: the query count is a property of the
     * SHAPE of the read, not of how many rows come back, and submitting would only add fixture
     * cost and lock records for no gain.
     */
    @isTest
    static void manyChildren_costsExactlyFourQueries() {
        Disposition__c busy = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true
        );
        TestDataFactory.createBovSubmissions(5, busy.Id, true);
        TestDataFactory.createDispositionOffers(5, busy.Id, true);
        Id busyId = busy.Id;

        Test.startTest();
        Integer before = Limits.getQueries();
        DispositionApprovalHistoryService.getHistory(busyId);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(4, used,
            'The card must cost a FIXED four queries — Disposition name, BOV targets, offer '
            + 'targets, ProcessInstance — for any number of children. Used: ' + used);
    }

    /**
     * A null Id is a legitimate transient state on a record page (the wire fires before `recordId`
     * is provisioned) and must cost nothing and throw nothing.
     */
    @isTest
    static void nullDispositionId_returnsEmptyAndQueriesNothing() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<DispositionApprovalHistoryService.ApprovalRow> rows =
            DispositionApprovalHistoryService.getHistory(null);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A null Id yields an empty list');
        Assert.areEqual(0, used, 'and issues no query at all. Used: ' + used);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE CONTROLLER — the `@AuraEnabled` boundary
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * The controller returns what the service returns. Deliberately thin: it exists to prove the
     * boundary is wired and the `cacheable` method is invocable, not to re-test the service.
     */
    @isTest
    static void controller_returnsTheServiceRows() {
        Disposition__c disposition = scaffold();
        BOV_Submission__c submission = scaffoldBov();
        submit(submission.Id, 'Broker selected on score.');

        Test.startTest();
        List<DispositionApprovalHistoryService.ApprovalRow> rows =
            DispositionApprovalHistoryController.getHistory(disposition.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The controller must pass the service result straight out');
        Assert.areEqual(submission.Id, rows[0].targetId,
            'and it must be the CHILD-targeted approval, unchanged by the boundary');
    }

    /** A null Id short-circuits before the type guard and before any read. */
    @isTest
    static void controller_nullId_returnsEmpty() {
        Test.startTest();
        List<DispositionApprovalHistoryService.ApprovalRow> rows =
            DispositionApprovalHistoryController.getHistory(null);
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A null Id is a transient wire state, not an error');
    }

    /**
     * 🔴 AN ID OF THE WRONG SOBJECT TYPE IS REFUSED, LOUDLY.
     *
     * Binding a foreign Id into `WHERE Disposition__c = :id` throws NOTHING — it matches no rows —
     * so without the guard a component wired to the wrong `record-id` would render a confident,
     * permanent "Approval History (0)". On THIS card that is indistinguishable from the very defect
     * it was built to fix, which is why the guard is worth a test of its own.
     *
     * ⚠ THE FIXTURE IS A REAL `Property__c` ID, NOT A MALFORMED STRING. A malformed Id throws
     * `System.StringException` at the METHOD-CALL boundary, before a single line of the method
     * runs, so it would prove the platform's Id coercion rather than this guard.
     */
    @isTest
    static void controller_wrongSObjectType_throwsAuraHandledException() {
        Id foreignId = [SELECT Id FROM Property__c LIMIT 1].Id;

        Test.startTest();
        Boolean threw = false;
        try {
            DispositionApprovalHistoryController.getHistory(foreignId);
            Assert.fail('A non-Disposition Id must be refused, not silently answered with 0 rows');
        } catch (AuraHandledException e) {
            threw = true;
            Assert.areEqual('Approval history can only be read for a Disposition.', e.getMessage(),
                'The refusal must name the actual problem — the generic read-failure message would '
                + 'send an admin hunting for a permission gap that does not exist');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'The wrong-type guard must fire');
    }
}
