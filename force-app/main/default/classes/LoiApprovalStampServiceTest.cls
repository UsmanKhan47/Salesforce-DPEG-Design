/**
 * Tests LoiApprovalStampService — the invocable that mirrors an approved LOI__c record's decision
 * onto its parent Opportunity (W1 of the LOI approval cutover,
 * agent-output/loi-approval-cutover-design.md).
 *
 * ── 🔴 THE TWO LOAD-BEARING TESTS IN THIS CLASS ───────────────────────────────────────────────
 * Everything else here is ordinary coverage of skip paths and degenerate input.
 *
 * 1. `nonOwningReadOnlyApproverStillUnblocksTheDeal` — the SHARING axis, and it is the test this
 *    suite has never had. Every approval test in this repo runs as the admin, who OWNS every
 *    fixture record and therefore always holds record-level edit, so `with sharing` was never
 *    asked the question. That is precisely how two production bugs got through here: an approval's
 *    parent write "silently wrote nothing" for every approver who did not own the record, and
 *    passed in every test. This test fails RED against FOUR separate regressions — dropping
 *    `without sharing` from `ParentStampWriter`, dropping `AccessLevel.SYSTEM_MODE` from its DML,
 *    dropping `without sharing` from `LoiSelector.ApprovalAutomationReads`, and dropping
 *    `WITH SYSTEM_MODE` from its query — and three of those four fail SILENTLY in production.
 *    ⚠ `System.runAs` is test-context only and always rolls back, so it cannot prove the LIVE
 *    approval path (that is the design's W3 P-3, on a real record, and it is still required). What
 *    it CAN prove is the sharing/FLS axis, which nothing in this repo currently does for LOI.
 *
 * 2. `approvedLoiUnblocksEntryToUnderContractPsa` — the REASON this class exists, pinned end to
 *    end with a presence control. `Opportunity.LOI_Approved__c` has exactly ONE production writer
 *    today (the retiring approval's `Set_LOI_Approved_Flag` field update) and
 *    `Approved_LOI_Before_PSA` reads it. If this class does not write that field, deactivating the
 *    old process blocks EVERY deal in the org out of `Under Contract (PSA)`, permanently, with no
 *    route out. The test asserts the block FIRST (so it cannot pass vacuously against a gate that
 *    is not actually live) and then asserts the stamp lifts it.
 *
 * ── METHOD NAMING ─────────────────────────────────────────────────────────────────────────────
 * Methods are named for the INVARIANT they prove, not for the mechanism that happens to implement
 * it today. That is deliberate: the Underwriting cutover found the ORG's deployed test class had
 * different method names from the repo's and had been passing against OLD behaviour, so three
 * predicted failures never existed. A name that describes an invariant survives a mechanism change
 * and stays honest; a name that describes a mechanism quietly becomes a lie.
 *
 * ── BULK POSTURE (.claude/rules/bulk-test-rule.md) — STATED SO REVIEW DOES NOT DEMAND 251 ──────
 * The 251-record mandate is NOT applied here, deliberately, and the reasoning is recorded in place
 * as that rule requires. This method is invoked from a record-triggered flow on a per-approval
 * path: one human decision on one LOI produces one transition, so 251 LOIs each carrying its own
 * granted principal approval in a single transaction is not a state production can reach. The bug
 * class the 251 threshold exists to expose is "a second trigger batch reveals SOQL or DML in a
 * loop", and that is falsified here directly and more cheaply by
 * `perRecordCostDoesNotGrowWithBatchSize`, which asserts a NON-GROWING query/DML budget across
 * batch sizes — so adding a per-record query or update reds the test at any N, including N = 2.
 * (⚠ said "a FLAT budget" until 2026-09-01; strict flatness was measured to be a claim about the
 * DOWNSTREAM cascade rather than about this class, and it reds for reasons unrelated to bulk
 * safety. That method's own docstring records the measurement.) Inflating
 * the fixture to 251 would prove nothing further and would risk tripping unrelated governor limits
 * inside the downstream cascade this save deliberately fires.
 *
 * ⚠ WHY THE BULK TEST ASSERTS A DELTA AND NOT AN ABSOLUTE COUNT — and why this class
 * deliberately diverges from its sibling `UnderwritingApprovalStampServiceTest` here. That class
 * asserts an absolute `2`, because its service writes TWO fields and "split across two saves" is a
 * real, reachable regression that only an absolute count catches. This service writes exactly ONE
 * field, so there is no split-across-saves shape to catch; an absolute number here would be a
 * measurement of unrelated downstream automation (`flows/LOI_Approval_Stamp` ->
 * `ApprovalAuditService` + two `GroupNotifier` calls, plus the Opportunity triggers) and would go
 * red every time any of that changed, for reasons that have nothing to do with this class.
 *
 * ⚠ Limits counters are RESTORED by `Test.stopTest()`, so every budget measurement here is taken
 * immediately either side of the invocation, never after `stopTest()`. The obvious form of that
 * assertion is silently vacuous.
 *
 * @see force-app/main/default/classes/LoiApprovalStampService.cls
 * @see force-app/main/default/classes/UnderwritingApprovalStampServiceTest.cls (the sibling)
 */
@isTest
private class LoiApprovalStampServiceTest {

    /** The terminal acquisition LOI stage `Completed_LOI_Before_PSA` requires. */
    private static final String LOI_STAGE_SIGNED = 'Signed';
    /** The deal stage `Approved_LOI_Before_PSA` guards entry to. */
    private static final String STAGE_PSA = 'Under Contract (PSA)';

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Fixtures
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * A deal parked at the LOI stage with an acquisition LOI hanging off it.
     *
     * ⚠ It deliberately does NOT use `TestDataFactory.placeApprovedLoi`, even though that helper
     * exists and is what every other LOI fixture in this suite reaches for. That helper sets
     * `LOI_Approved__c = true` ITSELF — which is the exact field this service exists to write — so
     * a test built on it would assert a value its own fixture had already supplied and would stay
     * green against a service that did nothing at all. Vacuous by construction.
     */
    private static Opportunity dealAtLoi() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        return o;
    }

    private static LOI__c loiOn(Id dealId) {
        return TestDataFactory.createLoi(dealId, true);
    }

    private static LoiApprovalStampService.Request request(Id loiId) {
        LoiApprovalStampService.Request r = new LoiApprovalStampService.Request();
        r.loiId = loiId;
        return r;
    }

    private static void stamp(List<Id> loiIds) {
        List<LoiApprovalStampService.Request> requests =
            new List<LoiApprovalStampService.Request>();
        for (Id loiId : loiIds) {
            requests.add(request(loiId));
        }
        LoiApprovalStampService.stampParent(requests);
    }

    private static Boolean loiApprovedOn(Id dealId) {
        return [SELECT LOI_Approved__c FROM Opportunity WHERE Id = :dealId].LOI_Approved__c;
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // The invariant the class exists for
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * The mirror field lands on the parent deal.
     *
     * The plainest statement of the contract: an approved LOI's decision becomes visible on the
     * deal. Kept separate from the end-to-end gate test below so that a failure is localisable —
     * this one failing means the write itself is broken, that one failing while this passes means
     * the gate moved.
     */
    @isTest
    static void anApprovedLoiMarksItsParentDealApproved() {
        Opportunity deal = dealAtLoi();
        LOI__c loi = loiOn(deal.Id);
        Assert.isFalse(loiApprovedOn(deal.Id),
            'FIXTURE PRECONDITION: the deal must NOT already be marked approved, or the assertion '
            + 'below proves nothing. If this fails, something in the fixture chain started writing '
            + 'LOI_Approved__c and every test in this class is now vacuous.');

        Test.startTest();
        stamp(new List<Id>{ loi.Id });
        Test.stopTest();

        Assert.isTrue(loiApprovedOn(deal.Id),
            'LOI_Approved__c must be true on the parent deal after the stamp. This is the ONE '
            + 'field the retiring Set_LOI_Approved_Flag wrote and the only one Approved_LOI_Before_PSA '
            + 'reads.');
    }

    /**
     * 🔴 THE REASON THIS CLASS EXISTS, END TO END, WITH A PRESENCE CONTROL.
     *
     * `Approved_LOI_Before_PSA` blocks entry to `Under Contract (PSA)` on
     * `ISBLANK(Primary_LOI__c) OR NOT(LOI_Approved__c)`. Verified 2026-09-01: that flag has exactly
     * ONE production writer, the retiring approval's field update, and no Apex writer at all. So
     * this service is the ONLY thing that will satisfy that gate once the old process is
     * deactivated, and a failure here is not a test failure — it is every deal in the org
     * permanently unable to reach PSA.
     *
     * 🔴 THE FIRST ASSERTION IS THE CONTROL AND IS NOT DECORATION. Without it, this test would pass
     * identically in an org where `Approved_LOI_Before_PSA` had been deactivated or its formula
     * changed — i.e. it would go green while proving nothing. Asserting the BLOCK first is what
     * makes the subsequent success meaningful.
     *
     * ⚠ The fixture reproduces the same gate chain `ContractExecutionServiceTest.dealAtPsa` walks
     * (signed NDA + primary LOI designated + the LOI's own Stage__c driven to 'Signed' for
     * `Completed_LOI_Before_PSA`), minus the one step that would vacuate it. If this fixture
     * suddenly fails to reach the PSA attempt at all, read those two validation rules before
     * suspecting this service.
     */
    @isTest
    static void approvedLoiUnblocksEntryToUnderContractPsa() {
        Opportunity deal = dealAtLoi();
        TestDataFactory.signPrimaryNda(deal);
        LOI__c loi = loiOn(deal.Id);
        update new Opportunity(Id = deal.Id, Primary_LOI__c = loi.Id);
        // Completed_LOI_Before_PSA reads the LOI's OWN Stage__c and requires the acquisition
        // terminal. Driven through the real production route rather than written directly, so the
        // fixture cannot reach a stage combination the application itself would refuse.
        RecordStageAdvanceService.advanceTo(loi.Id, LOI_STAGE_SIGNED);

        Test.startTest();

        // ── CONTROL: the gate is live and this deal is behind it. ──
        Boolean blockedBeforeStamp = false;
        String refusal = '';
        try {
            update new Opportunity(Id = deal.Id, StageName = STAGE_PSA);
        } catch (DmlException e) {
            blockedBeforeStamp = true;
            refusal = e.getDmlMessage(0);
        }
        Assert.isTrue(blockedBeforeStamp,
            '🔴 CONTROL FAILED — the deal entered ' + STAGE_PSA + ' with LOI_Approved__c still '
            + 'false, so Approved_LOI_Before_PSA is not actually gating this transition in this '
            + 'org. Everything after this line is vacuous until that is explained.');

        // ── The stamp. ──
        stamp(new List<Id>{ loi.Id });

        update new Opportunity(Id = deal.Id, StageName = STAGE_PSA);

        Test.stopTest();

        Assert.areEqual(STAGE_PSA,
            [SELECT StageName FROM Opportunity WHERE Id = :deal.Id].StageName,
            'After the stamp the deal must be able to enter ' + STAGE_PSA + '. The refusal it was '
            + 'previously getting was: ' + refusal);
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE SHARING / ACCESS AXIS — the gap that let two production bugs through here
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 KEEPS THE TEST BELOW HONEST. Run INSIDE `System.runAs`.
     *
     * ⚠ `RecordId` must be in the SELECT — `UserRecordAccess` rejects a query without it at COMPILE
     * time. ⚠ AND IT MUST BE `UserRecordAccess`, NEVER A PLAIN SOQL PROBE: an Apex test class
     * carries no sharing keyword and therefore runs `without sharing`, so a `SELECT ... FROM
     * Opportunity` inside `runAs` would succeed regardless and prove nothing.
     */
    private static void assertDealIsReadableButNotEditable(Id dealId) {
        UserRecordAccess access = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :dealId
        ];
        Assert.isTrue(access.HasReadAccess,
            'FIXTURE PRECONDITION: the persona must be able to READ the deal — '
            + 'DPEG_Opportunity_View.viewAllRecords is what grants it. Without read access the '
            + 'failure mode under test is not the one that reaches production.');
        Assert.isFalse(access.HasEditAccess,
            '🔴 FIXTURE PRECONDITION: the persona must NOT be able to EDIT the deal. That refusal '
            + 'is the whole point. If this is true, the persona gained record-level edit from '
            + 'somewhere (a role, an OWD change, a widened permission set) and this test is '
            + 'vacuous — it would pass with `without sharing` removed.');
    }

    /**
     * An approver who can SEE every deal, OWNS none of them, and cannot EDIT any still unblocks the
     * deal.
     *
     * ── WHY THIS PERSONA, AND WHY IT IS NOT LITERALLY THE APPROVING PRINCIPAL ─────────────────
     * `TestDataFactory.createNonOwnerLoiSubmitter` is a `Minimum Access - Salesforce` user holding
     * `DPEG_Base_Access` + `DPEG_Opportunity_View`. Verified in the permission set on 2026-09-01,
     * it matches the real approving principal (`DPEG_Acquisition_View`) on the three axes that
     * decide this test, and is STRICTER on a fourth:
     *   - Opportunity: `allowRead=true`, `viewAllRecords=true`, `allowEdit=false`,
     *     `modifyAllRecords=false` — identical shape to DPEG_Acquisition_View (:1866-1874);
     *   - `Opportunity.LOI_Approved__c`: `readable=true`, `editable=false` — so the FLS axis is
     *     live too, not just CRUD;
     *   - owns nothing, and has NO role (so "Grant Access Using Hierarchies" cannot leak edit in);
     *   - it has NO `LOI__c` object permission at all, where the real principal has
     *     `viewAllRecords` — which makes the selector's escape falsifiable here as well.
     * `Minimum Access` and not `Standard User` per `.claude/rules` — Standard User carries broad
     * standard-object grants that would mask the denial and pass for the wrong reason.
     *
     * ── WHAT THIS FAILS RED AGAINST. Four separate regressions, three of them silent: ─────────
     *   1. `ParentStampWriter` losing `without sharing` — the persona has read-only record access
     *      to an OWD-Private deal it does not own, so the update is refused. (Under the historical
     *      `allOrNone = false` shape this was SILENT; with `allOrNone = true` it throws, which is
     *      why the class insists on true.)
     *   2. `ParentStampWriter` losing `AccessLevel.SYSTEM_MODE` — `allowEdit=false` on Opportunity
     *      raises `System.TypeException` ('DML operation UPDATE not allowed'), which is not even a
     *      DmlException, plus `LOI_Approved__c` is `editable=false`.
     *   3. `LoiSelector.ApprovalAutomationReads` losing `WITH SYSTEM_MODE` — no LOI__c CRUD at all
     *      for this persona, so the read throws `QueryException: No such column`, an FLS denial
     *      wearing a schema error.
     *   4. `LoiSelector.ApprovalAutomationReads` losing `without sharing` — the read returns an
     *      EMPTY LIST, the service skips, nothing is written, and NOTHING IS RAISED. That is the
     *      most dangerous of the four and the only assertion that catches it is the value below.
     *   5. 🔴 ADDED 2026-09-01 AFTER THIS TEST FOUND A REAL, PRE-EXISTING DEFECT IN A CLASS IT
     *      DOES NOT NAME — `OpportunitySelector.selectPrimaryLoiByIds` reverting to
     *      `WITH USER_MODE`, or `ApprovalAuditService` moving its selector reads back OUTSIDE the
     *      try that wraps its DML. This test was RED on the W1 deploy and the diagnosis was NOT a
     *      fixture problem: the parent stamp fires `flows/LOI_Approval_Stamp`, whose Apex action
     *      read `Opportunity.Primary_LOI__c` in user mode, threw
     *      `System.QueryException: No such column 'Primary_LOI__c' on entity 'Opportunity'` for
     *      this persona, escaped that class's degrade-by-design catch, and came back as
     *      `CANNOT_EXECUTE_FLOW_TRIGGER` — rolling back the stamp entirely.
     *      ⚠ AND THE FLS GRANT WAS PRESENT: `DPEG_Opportunity_View` carries
     *      `Opportunity.Primary_LOI__c` readable (measured). It carries no `LOI__c`
     *      objectPermissions, and a lookup field is inaccessible when its referenced object is.
     *      So the persona was NOT weakened and no grant was added — the code was fixed. If this
     *      goes red again, read the failure: a `CANNOT_EXECUTE_FLOW_TRIGGER` naming a QueryException
     *      is regression 5, not regressions 1-4.
     *
     * ⚠ `System.runAs` always rolls back and is test-context only, so this does not prove the live
     * approval path. The design's W3 P-3 — a real approval, granted by the non-administrator named
     * principal, on a record they do not own — is still required and is not replaced by this.
     */
    @isTest
    static void nonOwningReadOnlyApproverStillUnblocksTheDeal() {
        Opportunity deal = dealAtLoi();
        LOI__c loi = loiOn(deal.Id);
        User approver = TestDataFactory.createNonOwnerLoiSubmitter('lapx');

        System.runAs(approver) {
            assertDealIsReadableButNotEditable(deal.Id);
            // ⚠ Queried as a LIST, not a single row: a persona with no object access at all may
            // simply have no UserRecordAccess row for the LOI, and a single-row assignment would
            // throw a QueryException that looks like a defect in the code under test.
            List<UserRecordAccess> loiAccess = [
                SELECT RecordId, HasReadAccess
                FROM UserRecordAccess
                WHERE UserId = :UserInfo.getUserId() AND RecordId = :loi.Id
            ];
            Assert.isTrue(loiAccess.isEmpty() || !loiAccess[0].HasReadAccess,
                '🔴 FIXTURE PRECONDITION: this persona must NOT be able to read the LOI, or the '
                + 'selector-side half of this test (regressions 3 and 4 in the docstring) is '
                + 'vacuous.');

            Test.startTest();
            stamp(new List<Id>{ loi.Id });
            Test.stopTest();
        }

        Assert.isTrue(loiApprovedOn(deal.Id),
            '🔴 THE PARENT STAMP DID NOT LAND FOR A NON-OWNING, READ-ONLY APPROVER. This is the '
            + 'exact shape of the incident this project already shipped once: the write works when '
            + 'approver == owner (which is what every other test in this suite does) and silently '
            + 'does nothing otherwise. Check, in order: `without sharing` on '
            + 'LoiSelector.ApprovalAutomationReads (a sharing-filtered read returns EMPTY and the '
            + 'service skips with no error), then `without sharing` on '
            + 'LoiApprovalStampService.ParentStampWriter, then AccessLevel.SYSTEM_MODE on its DML.');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Bulk safety
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * The bulk-safety proof that stands in for a 251-record run (see the class header for why 251
     * is neither reachable nor informative on this path).
     *
     * ⚠ IT ASSERTS FLATNESS, NOT AN ABSOLUTE COUNT, AND THAT IS THE WHOLE DESIGN. `Limits`
     * counters are transaction-wide, so any absolute number here would be measuring the downstream
     * cascade this save deliberately fires (`LOI_Approval_Stamp` -> `ApprovalAuditService` + two
     * `GroupNotifier` calls) plus the Opportunity triggers, and would red every time any of that
     * changed for reasons unrelated to this class.
     *
     * So the test calibrates itself: it stamps ONE deal, measures, then stamps FIVE OTHER deals and
     * measures again. A bulk-safe implementation spends the same amount both times, because its
     * cost is per-BATCH. An implementation that queries or updates per record spends four more on
     * the second call. The deals are disjoint and none has been stamped before, so both calls are
     * genuine first-time transitions and the downstream cascade is directly comparable.
     *
     * ══ 🔴 TWO CORRECTIONS, 2026-09-01. THE TEST WAS RED, AND IT WAS THE ASSERTION THAT WAS
     *      WRONG — THE SERVICE WAS ALWAYS BULK-SAFE. ═══════════════════════════════════════════
     * Measured, test run `707iw000003unI3`:
     *     Assertion Failed: Five LOIs must cost the same number of queries as one (5).
     *     Expected: 5, Actual: 3
     * FIVE LOIs cost THREE queries and ONE LOI cost FIVE. Fewer, not more — the opposite of the
     * bug this test exists to catch. So the last sentence of the paragraph above ("the downstream
     * cascade is directly comparable") was simply FALSE:
     *
     *   1. THE FIRST CALL PAYS ONE-TIME COSTS THE SECOND DOES NOT. The cascade this save fires
     *      (`flows/LOI_Approval_Stamp` -> `ApprovalAuditService` + two `GroupNotifier` calls)
     *      contains per-TRANSACTION work — static caches warmed, groups resolved once — that is
     *      paid on whichever call happens to run first and never again. Measuring call #1 against
     *      call #2 therefore measures warm-up, not per-record cost. 🔴 FIXED BY A THROWAWAY WARM-UP
     *      STAMP BEFORE EITHER MEASUREMENT, on a seventh deal that is never asserted on. That is
     *      the whole reason the fixture grew from 6 deals to 7.
     *   2. THE COMPARISON IS NOW `<=`, NOT `==`. This is the weaker assertion and it is the RIGHT
     *      one, because it states the invariant exactly: **per-record cost must not GROW with N**.
     *      Equality additionally asserts that the downstream cascade costs the same for 1 record
     *      as for 5, which is a claim about `ApprovalAuditService` and `GroupNotifier`, not about
     *      this class, and which is what went red here. ⚠ It cannot go vacuous: a query or an
     *      update moved inside the loop makes the five-record call cost exactly four more than
     *      the one-record call, which fails `<=` immediately, at N = 5 and at any larger N.
     *   ⚠ WHAT WAS NOT DONE: the number 5 was NOT updated to 3. An absolute count here measures
     *      unrelated downstream automation and would drift again the next time any of it changes
     *      — which is exactly how this assertion came to be red without a defect behind it.
     */
    @isTest
    static void perRecordCostDoesNotGrowWithBatchSize() {
        List<Opportunity> deals = new List<Opportunity>();
        for (Integer i = 0; i < 7; i++) {
            Opportunity o = TestDataFactory.createOpportunity(null, false);
            o.StageName = 'LOI';
            deals.add(o);
        }
        insert deals;

        List<LOI__c> lois = new List<LOI__c>();
        for (Opportunity o : deals) {
            lois.addAll(TestDataFactory.createLois(1, o.Id, false));
        }
        insert lois;

        List<Id> warmUp = new List<Id>{ lois[0].Id };
        List<Id> single = new List<Id>{ lois[1].Id };
        List<Id> batchOfFive = new List<Id>();
        for (Integer i = 2; i < 7; i++) {
            batchOfFive.add(lois[i].Id);
        }

        Test.startTest();
        // ── WARM-UP. Not measured, not asserted on. Its only job is to pay the transaction's
        // one-time downstream costs so that the two measurements below are comparable. Without
        // it the FIRST measurement is inflated and this test reds with the batch looking CHEAPER
        // than the single — which is what happened on 2026-09-01.
        stamp(warmUp);

        Integer soqlBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        stamp(single);
        Integer soqlForOne = Limits.getQueries() - soqlBefore;
        Integer dmlForOne = Limits.getDmlStatements() - dmlBefore;

        soqlBefore = Limits.getQueries();
        dmlBefore = Limits.getDmlStatements();
        stamp(batchOfFive);
        Integer soqlForFive = Limits.getQueries() - soqlBefore;
        Integer dmlForFive = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.isTrue(soqlForFive <= soqlForOne,
            'Five LOIs must not cost MORE queries than one. One cost ' + soqlForOne
            + ', five cost ' + soqlForFive + '. A per-record query would make the five-record '
            + 'call cost exactly four more than the one-record call. (Cheaper is fine and is not '
            + 'this class\'s doing — it is the downstream cascade; see the docstring.)');
        Assert.isTrue(dmlForFive <= dmlForOne,
            'Five LOIs must not cost MORE DML statements than one. One cost ' + dmlForOne
            + ', five cost ' + dmlForFive + '. A per-record update would make the five-record '
            + 'call cost exactly four more.');

        Set<Id> dealIds = new Map<Id, Opportunity>(deals).keySet();
        Assert.areEqual(7, [
            SELECT COUNT() FROM Opportunity WHERE Id IN :dealIds AND LOI_Approved__c = true
        ], 'Every deal across all three calls is stamped');
    }

    /**
     * Two LOIs on ONE deal must not put the same row in an update list twice
     * (`DUPLICATE_VALUE` / "Duplicate id in list"), which is what a naive List accumulator does.
     *
     * ⚠ Not hypothetical on this object: `OpportunityReviewService` auto-creates an LOI on entry to
     * the LOI stage and a driver can create more, so two LOIs under one deal is an ordinary state
     * — and both could be approved.
     */
    @isTest
    static void twoLoisOnOneDealCollapseToASingleUpdateShell() {
        Opportunity deal = dealAtLoi();
        List<LOI__c> lois = TestDataFactory.createLois(2, deal.Id, true);

        Test.startTest();
        stamp(new List<Id>{ lois[0].Id, lois[1].Id });
        Test.stopTest();

        Assert.isTrue(loiApprovedOn(deal.Id),
            'Two LOIs on one deal stamp it once, without a duplicate-id DML failure');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Skip paths — every one of these is a LEGAL state, not a tolerated failure
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * An LOI with no parent deal is a LEGAL state — `Opportunity__c` is a Lookup with
     * `deleteConstraint SetNull`, and a sell-side LOI hangs off `Disposition__c` and has no
     * Opportunity at all — so it must be skipped, not thrown on.
     *
     * A throw here would abort the whole batch and, because this runs from an after-save flow, the
     * APPROVAL SAVE with it: the approver would see an unintelligible platform error and the
     * decision would roll back.
     */
    @isTest
    static void anLoiWithNoParentDealIsSkippedNotThrown() {
        LOI__c orphan = TestDataFactory.createLois(1, (Id) null, true)[0];

        Test.startTest();
        stamp(new List<Id>{ orphan.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity WHERE LOI_Approved__c = true],
            'An LOI with no parent stamps nothing and raises nothing');
    }

    /**
     * A mixed batch must not be all-or-nothing on the SELECTION side: one parentless LOI must not
     * stop the valid rows in the same invocation from being stamped.
     */
    @isTest
    static void aValidLoiIsStampedEvenWhenBatchedWithAParentlessOne() {
        Opportunity deal = dealAtLoi();
        LOI__c loi = loiOn(deal.Id);
        LOI__c orphan = TestDataFactory.createLois(1, (Id) null, true)[0];

        Test.startTest();
        stamp(new List<Id>{ orphan.Id, loi.Id });
        Test.stopTest();

        Assert.isTrue(loiApprovedOn(deal.Id),
            'The valid LOI in a mixed batch is still stamped');
    }

    /**
     * An Id that no longer resolves to a row is skipped rather than thrown on.
     *
     * ⚠ This is why the service uses `LoiSelector.ApprovalAutomationReads.selectByIds` and NOT
     * `LoiSelector.selectOpportunityIdRequiredById`, which carries a THROWING fetch-for-use
     * contract. Routing approval automation through the throwing method would turn a deleted LOI
     * into a rolled-back approval.
     */
    @isTest
    static void anIdThatNoLongerResolvesIsSkippedNotThrown() {
        Opportunity deal = dealAtLoi();
        LOI__c loi = loiOn(deal.Id);
        Id deletedId = loi.Id;
        delete loi;

        Test.startTest();
        stamp(new List<Id>{ deletedId });
        Test.stopTest();

        Assert.isFalse(loiApprovedOn(deal.Id),
            'A vanished LOI stamps nothing and raises nothing');
    }

    /**
     * Degenerate inputs. A Flow can hand over an empty collection, and a `Request` whose `loiId`
     * was never set arrives with a null member despite `required=true` — required is a design-time
     * affordance in the Flow builder, not a runtime guarantee for an Apex caller.
     */
    @isTest
    static void nullEmptyAndBlankRequestsDoNothing() {
        Test.startTest();
        LoiApprovalStampService.stampParent(null);
        LoiApprovalStampService.stampParent(new List<LoiApprovalStampService.Request>());
        LoiApprovalStampService.stampParent(new List<LoiApprovalStampService.Request>{
            null, new LoiApprovalStampService.Request()
        });
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, dmlUsed, 'Degenerate input performs no DML at all');
    }

    /**
     * Idempotence. Re-running the stamp writes the same value rather than failing or flipping
     * anything back.
     *
     * ⚠ This is not theoretical tidiness. The consumer, `flows/LOI_Approval_Stamp`, is
     * transition-scoped (`doesRequireRecordChangedToMeetCriteria = true`), so a repeat save must
     * leave the value as-is and fire nothing — a stamp that toggled or re-announced would send the
     * two human-facing `GroupNotifier` messages a second time.
     */
    @isTest
    static void reStampingLeavesTheDealApprovedAndUnchanged() {
        Opportunity deal = dealAtLoi();
        LOI__c loi = loiOn(deal.Id);
        List<Id> ids = new List<Id>{ loi.Id };

        Test.startTest();
        stamp(ids);
        stamp(ids);
        Test.stopTest();

        Assert.isTrue(loiApprovedOn(deal.Id), 'Re-stamping leaves LOI_Approved__c true');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // Scope fence — what this class must NOT grow into (D-3, and the audit-stamp boundary)
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE STAMP TOUCHES THE PARENT AND NOTHING ELSE — the fence around decision D-3.
     *
     * D-3 (user, 2026-09-01, verbatim): *"The LOI stage will remain on Under review after
     * rejection."* The deal-stage rewind the retiring process performed on rejection is an ACCEPTED
     * LOSS, and there is to be no compensating automation. The natural way that decision gets
     * quietly reversed is somebody "completing" this service by having it also drive the LOI's own
     * Stage__c / LOI_Status__c, at which point a rejection branch looks like the obvious next step.
     *
     * This test makes that reversal fail loudly. It also fences the second boundary: the approver,
     * approval date and comments belong to `ApprovalAuditService`, stamped from REAL approval
     * history one save later. Inventing them here would produce plausible-looking audit data with
     * no approval behind it.
     *
     * ⚠ A future change may legitimately want the LOI's own fields written — but that is a decision
     * to take with the user and this test is the place to record it, not a nuisance to delete.
     */
    @isTest
    static void theStampWritesTheParentOnlyAndNeverTouchesTheLoi() {
        Opportunity deal = dealAtLoi();
        LOI__c loi = loiOn(deal.Id);
        LOI__c loiBefore = [
            SELECT Stage__c, LOI_Status__c, Approved_By__c, Approved_Date__c, Approval_Comments__c
            FROM LOI__c WHERE Id = :loi.Id
        ];

        Test.startTest();
        stamp(new List<Id>{ loi.Id });
        Test.stopTest();

        LOI__c loiAfter = [
            SELECT Stage__c, LOI_Status__c, Approved_By__c, Approved_Date__c, Approval_Comments__c
            FROM LOI__c WHERE Id = :loi.Id
        ];
        Assert.areEqual(loiBefore.Stage__c, loiAfter.Stage__c,
            'The stamp must not move the LOI\'s own Stage__c. Per D-3 the LOI stays where the '
            + 'approval found it; a stage write here is how the declined rejection rewind gets '
            + 'rebuilt by accident.');
        Assert.areEqual(loiBefore.LOI_Status__c, loiAfter.LOI_Status__c,
            'The stamp must not write LOI_Status__c. The approval\'s own finalApprovalActions '
            + 'writes it (it is the marker the mirror flow keys on) and ApprovalAuditService '
            + 'confirms it; a third writer here would race both.');
        Assert.isNull(loiAfter.Approved_By__c,
            'Approved_By__c belongs to ApprovalAuditService, stamped from real approval history. '
            + 'A value here means this class invented audit data.');
        Assert.isNull(loiAfter.Approved_Date__c, 'Approved_Date__c likewise belongs to the audit stamp');
        Assert.isNull(loiAfter.Approval_Comments__c,
            'Approval_Comments__c likewise belongs to the audit stamp');
    }
}
