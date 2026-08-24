/**
 * @description Tests BovSubmissionTriggerHandler — the on-market broker-appointment hand-off from
 * `Broker_Finalize_Approval` (which runs on the SUBMISSION) back onto the parent Disposition.
 * Added 2026-08-19 with the disposition flow redesign (DEV-4).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 251-RECORD BULK MANDATE APPLIES — NO EXEMPTION (trigger-driven). .claude/rules/bulk-test-rule.md
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Budget per the class header: ONE selector query and ONE `Database.update` per chunk, CONSTANT in
 * the number of submissions. `bulk251ApprovesAtConstantCost` asserts the governor counters directly
 * (never across `Test.stopTest()`, which would silently zero them), not merely the row counts.
 *
 * ── THE CURRENT-STAGE GUARD IS THE FEATURE, NOT A SAFETY NET ────────────────
 * `guardBlocksAReApprovalAfterTheStageAlreadyAdvanced` is the falsifier: approving a REPLACEMENT
 * broker on a disposition that has already moved past BOV Outreach must stamp the new broker name
 * (unconditional) but must NOT drag the sale back to Broker Selection (guarded).
 *
 * These tests simulate the approval's own field update (`Approval_Status__c` -> 'Approved') with
 * a direct DML write, exactly as `Set_Broker_Approval_Approved`'s FieldUpdate would produce — the
 * end-to-end Approval.process walk (submit + approve/reject through the real process) lives in
 * DispositionApprovalProcessesTest, which is this class's complement, not a duplicate.
 *
 * @see force-app/main/default/classes/BovSubmissionTriggerHandler.cls
 * @author Unit Testing Agent
 */
@isTest
private class BovSubmissionTriggerHandlerTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c dispositionAt(String stage) {
        Disposition__c d = TestDataFactory.createDisposition(
            assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    private static Disposition__c reread(Id dispositionId) {
        return [SELECT Disposition_Stage__c, Selected_Broker__c FROM Disposition__c WHERE Id = :dispositionId];
    }

    @isTest
    static void approvedAndSelectedAtBovOutreach_advancesParentAndStampsBroker() {
        Disposition__c d = dispositionAt('BOV Outreach');
        // Pinned via Broker__c, not a hand-typed literal — see TestDataFactory.createBrokerContactWithFirm.
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(d.Id, false);
        sub.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE - Mark Chen', true).Id;
        sub.Submission_Status__c = 'Selected';
        insert sub;

        Test.startTest();
        update new BOV_Submission__c(Id = sub.Id, Approval_Status__c = 'Approved');
        Test.stopTest();

        Disposition__c after = reread(d.Id);
        Assert.areEqual('Broker Selection', after.Disposition_Stage__c,
            'BOV Outreach must advance to Broker Selection on an Approved+Selected submission');
        Assert.areEqual('CBRE - Mark Chen', after.Selected_Broker__c,
            'The parent must be stamped with the approved broker\'s firm');
    }

    /**
     * 🔴 THE REPLACE-BROKER FEATURE, NOT A SAFETY NET. A fresh approval on a submission whose
     * disposition has ALREADY moved past BOV Outreach — because `BovSubmissionService
     * .replaceSelectedBroker` cleared the challenger's own Approval_Status__c and it was just
     * re-approved — must stamp the new broker name and NOT drag the sale backwards.
     */
    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THE ROUTING VERIFICATION THE TWO-SLOT MODEL MADE NECESSARY (2026-08-24).
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * `Broker_Finalize_Approval`'s entry criterion is `Submission_Status__c = 'Selected'`, and a
     * disposition may now hold TWO Selected rows — the preferred broker and the scored winner. So
     * the question that had to be answered before shipping was: can BOTH advance the parent, or
     * stamp `Selected_Broker__c` with the wrong broker?
     *
     * **NO — AND THIS TEST IS THE PROOF RATHER THAN THE ARGUMENT.** The detection here is an
     * `Approval_Status__c` TRANSITION, not a status: the sibling's field is never written, so it
     * fails the `prior` test and is never even a candidate. Being Selected is necessary and never
     * sufficient. (`DispositionApprovalService` independently submits only ONE of the two, and
     * `handleApprovedSelections`' own header records all three reasons.)
     *
     * ⚠ THE FIXTURE MUST HAVE BOTH SLOTS GENUINELY FILLED, or this passes vacuously against a
     * version that stamps every Selected row. The precondition asserts it, and the two brokers
     * carry DIFFERENT firm names so "the right one" is distinguishable from "one of them".
     */
    @isTest
    static void approvingOneOfTwoSelectedRows_stampsOnlyTheApprovedBroker() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c scored = TestDataFactory.createBovSubmission(d.Id, false);
        scored.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE - Scored', true).Id;
        scored.Submission_Status__c = 'Selected';
        insert scored;
        BOV_Submission__c preferred = TestDataFactory.createBovSubmission(d.Id, false);
        preferred.Broker__c = TestDataFactory.createBrokerContactWithFirm('JLL - Preferred', true).Id;
        preferred.Is_Preferred_Broker__c = true;
        preferred.BOV_Amount__c = null;
        preferred.Cap_Rate__c = null;
        preferred.Commission_Rate__c = null;
        preferred.Days_To_Market__c = null;
        preferred.Hist_Success_Rate__c = null;
        insert preferred;

        Map<Id, BOV_Submission__c> before = new Map<Id, BOV_Submission__c>([
            SELECT Id, Submission_Status__c, Is_Preferred_Broker__c
            FROM BOV_Submission__c WHERE Disposition__c = :d.Id WITH SYSTEM_MODE
        ]);
        Assert.areEqual('Selected', before.get(scored.Id).Submission_Status__c,
            '🔴 PREMISE: the non-preferred row is Selected...');
        Assert.areEqual('Selected', before.get(preferred.Id).Submission_Status__c,
            '🔴 ...AND SO IS THE PREFERRED ROW. Both match Broker_Finalize_Approval s entry '
            + 'criterion, which is the whole hazard being tested. A Backup here makes this test '
            + 'vacuous.');

        Test.startTest();
        // ONLY the preferred row is approved — exactly what DispositionApprovalService routes.
        update new BOV_Submission__c(Id = preferred.Id, Approval_Status__c = 'Approved');
        Test.stopTest();

        Disposition__c after = reread(d.Id);
        Assert.areEqual('JLL - Preferred', after.Selected_Broker__c,
            '🔴 THE PARENT NAMES THE BROKER THAT WAS ACTUALLY APPROVED. "CBRE - Scored" here means '
            + 'the handler is reacting to the Selected STATUS rather than to the approval '
            + 'TRANSITION, and the sale would be stamped with a broker nobody approved.');
        Assert.areEqual('Broker Selection', after.Disposition_Stage__c,
            'and the stage advances once, for that one approval');
        Assert.areEqual(new List<String>(),
            BovSubmissionTriggerHandler.lastRunParentWriteFailures,
            'with no refused parent write hiding behind the assertions above');
    }

    @isTest
    static void guardBlocksAReApprovalAfterTheStageAlreadyAdvanced() {
        Disposition__c d = dispositionAt('NDA'); // already advanced well past BOV Outreach
        // Pinned via Broker__c, not a hand-typed literal — see TestDataFactory.createBrokerContactWithFirm.
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Broker__c = TestDataFactory.createBrokerContactWithFirm('JLL - K. Rao', true).Id;
        challenger.Submission_Status__c = 'Selected';
        insert challenger;

        Test.startTest();
        update new BOV_Submission__c(Id = challenger.Id, Approval_Status__c = 'Approved');
        Test.stopTest();

        Disposition__c after = reread(d.Id);
        Assert.areEqual('NDA', after.Disposition_Stage__c,
            'The stage must NOT move backwards — the guard is out-of, and only out-of, BOV Outreach');
        Assert.areEqual('JLL - K. Rao', after.Selected_Broker__c,
            '🔴 THE BROKER STAMP IS UNCONDITIONAL EVEN THOUGH THE STAGE MOVE IS NOT — the replacement '
            + 'broker must still be named on the disposition');
    }

    @isTest
    static void approvedButNoLongerSelected_doesNothing() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(d.Id, false);
        sub.Submission_Status__c = 'Backup'; // demoted before the approval could complete
        insert sub;

        Test.startTest();
        update new BOV_Submission__c(Id = sub.Id, Approval_Status__c = 'Approved');
        Test.stopTest();

        Assert.areEqual('BOV Outreach', reread(d.Id).Disposition_Stage__c,
            'Approved-but-no-longer-Selected must not appoint a broker the business has since '
            + 'replaced');
        Assert.isNull(reread(d.Id).Selected_Broker__c, 'No broker should be stamped');
    }

    /** A save that leaves Approval_Status__c unchanged (already Approved) must not re-fire the write. */
    @isTest
    static void notATransition_alreadyApprovedBeforeThisSave_doesNothingAgain() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(d.Id, false);
        sub.Submission_Status__c = 'Selected';
        sub.Approval_Status__c = 'Approved';
        insert sub;
        // First transition already ran on insert? No — Approval_Status__c is set on INSERT here,
        // which is an afterInsert context this handler does not hook (afterUpdate only), so the
        // parent has NOT yet moved. Move it here by hand to the state a real approval would have
        // already produced, then prove an UNRELATED subsequent save does not re-fire.
        update new Disposition__c(Id = d.Id, Disposition_Stage__c = 'Broker Selection');

        Test.startTest();
        update new BOV_Submission__c(Id = sub.Id, Broker_Firm__c = 'Renamed Firm');
        Test.stopTest();

        Assert.areEqual('Broker Selection', reread(d.Id).Disposition_Stage__c,
            'An unrelated save on an already-approved submission must not re-stamp or re-advance');
    }

    /**
     * 🔴 GOVERNOR ASSERTION, THE POINT OF THIS TEST. Snapshotted immediately around the real DML
     * that fires the trigger, never across Test.stopTest().
     *
     * ✅ W9 (code review, 2026-08-20, Unit Testing Agent): this class's own header and this
     * method's doc comment above BOTH promised "asserts the governor counters directly (never
     * across Test.stopTest()), not merely the row counts" since this class was added on
     * 2026-08-19 — but the method body previously contained ONLY the COUNT() row-count assertion
     * below. Checked against `git log -- <this file>`: ZERO commits exist for this path — the
     * whole class is still untracked (Tranche A is written but not yet deployed OR committed), so
     * there is no prior version to have regressed from. FINDING: the promise was NEVER
     * IMPLEMENTED, not removed or lost in a later edit. Closed here by adding it rather
     * than retracting the claim, because the claim is the more valuable instrument: a future
     * change that made `handleApprovedSelections` issue one query or one `Database.update` PER
     * RECORD instead of PER CHUNK would still pass the row-count assertion (all 251 dispositions
     * would still end up advanced) and go undetected until it silently burned governor limits at
     * a slightly larger volume than this test reaches.
     */
    @isTest
    static void bulk251ApprovesAtConstantCost() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        for (Disposition__c d : dispositions) {
            d.Disposition_Stage__c = 'BOV Outreach';
        }
        insert dispositions;
        List<BOV_Submission__c> subs = new List<BOV_Submission__c>();
        for (Disposition__c d : dispositions) {
            BOV_Submission__c s = TestDataFactory.createBovSubmission(d.Id, false);
            s.Submission_Status__c = 'Selected';
            subs.add(s);
        }
        insert subs;
        List<BOV_Submission__c> approvals = new List<BOV_Submission__c>();
        for (BOV_Submission__c s : subs) {
            approvals.add(new BOV_Submission__c(Id = s.Id, Approval_Status__c = 'Approved'));
        }

        Test.startTest();
        // Snapshotted immediately around the triggering DML, both reads still inside
        // Test.startTest()/Test.stopTest() — Test.stopTest() flushes async work and is not itself
        // where the counters are read, but reading AFTER it would let unrelated framework/async
        // activity between here and stopTest() pollute the delta, so both snapshots stay tight
        // around the one statement under test.
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        update approvals; // 251 rows -> TWO trigger chunks
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(2, queriesUsed,
            'afterUpdate must cost exactly ONE DispositionSelector.selectStagesByIds query PER '
            + 'CHUNK, never one per record. 251 rows is TWO chunks, so exactly 2 — the class '
            + 'header\'s own budget line. A per-record query would read closer to 251');
        Assert.areEqual(3, dmlUsed,
            'ONE for this line\'s own `update approvals`, plus ONE Database.update PER CHUNK from '
            + 'handleApprovedSelections — 251 rows is TWO chunks, so exactly 1 + 2 = 3. A '
            + 'per-record parent write would read far higher and would exhaust the 150-statement '
            + 'limit long before reaching 251');

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c WHERE Id IN :dispositions AND Disposition_Stage__c = 'Broker Selection'],
            'Every one of the 251 dispositions must have advanced — a total below 251 means the '
            + 'second trigger chunk was dropped');
    }

    @isTest
    static void unrelatedFieldSaveOnATransitionedRowDoesNotDoubleFire() {
        // A negative-control: creating and later editing a submission that never touches
        // Approval_Status__c at all must never move the parent.
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(d.Id, true);

        Test.startTest();
        update new BOV_Submission__c(Id = sub.Id, BOV_Amount__c = 9999999);
        Test.stopTest();

        Assert.areEqual('BOV Outreach', reread(d.Id).Disposition_Stage__c,
            'An edit unrelated to Approval_Status__c must never advance the parent');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE NON-OWNER APPROVER (2026-08-21) — see DispositionOfferTriggerHandlerTest for the
    //    measured incident this fixture generalises from (`DISP-0011` / `OFFER-0007`).
    // ═════════════════════════════════════════════════════════════════════════════════════════
    // ⚠ EVERY TEST ABOVE THIS LINE PASSED AGAINST THE BROKEN CODE. They run as the admin test user,
    // who OWNS every fixture record, and an owner of an OWD-Private record always holds record-level
    // edit — so the `with sharing` `Database.update` in `handleApprovedSelections` was never asked
    // the question that fails in production. Here the PARENT stays with the admin and the RUNNING
    // USER is a Minimum-Access principal with `DPEG_Disposition_View`: sees every disposition,
    // owns and can edit none.
    //
    // ⚠ THE SUBMISSION'S OWNERSHIP IS TRANSFERRED TO THE APPROVER AND THE PARENT'S IS NOT. That is
    // scaffolding so the simulated `Set_Broker_Approval_Approved` field update is performable in the
    // persona's context; in production the platform performs it. The parent's ownership is the
    // subject.

    private static User approverOwning(String aliasSeed, List<Id> submissionIds) {
        User approver = TestDataFactory.createNonOwnerDispositionApprover(aliasSeed);
        List<BOV_Submission__c> transfers = new List<BOV_Submission__c>();
        for (Id submissionId : submissionIds) {
            transfers.add(new BOV_Submission__c(Id = submissionId, OwnerId = approver.Id));
        }
        update transfers;
        return approver;
    }

    /**
     * 🔴 KEEPS EVERY TEST BELOW HONEST. Run INSIDE `System.runAs` against `UserInfo.getUserId()`, so
     * it needs no "View All Data" and cannot answer for the wrong principal. `RecordId` must be in
     * the SELECT — `UserRecordAccess` rejects a query without it at compile time.
     */
    private static void assertReadableButNotEditable(Id dispositionId) {
        UserRecordAccess access = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :dispositionId
        ];
        Assert.isTrue(access.HasReadAccess,
            'FIXTURE PRECONDITION: the approver must be able to READ the parent — that is what '
            + '`DPEG_Disposition_View.viewAllRecords` grants, and it is why the idempotency read '
            + 'succeeds and hides the write failure.');
        Assert.isFalse(access.HasEditAccess,
            '🔴 FIXTURE PRECONDITION: the approver must NOT be able to EDIT the parent. That is the '
            + 'whole defect. If this is true the persona gained record-level edit from somewhere '
            + '(modifyAllRecords, a role, a widened Disposition_Team_RW) and every assertion after '
            + 'it is vacuous. Investigate the org; do NOT delete this assertion.');
    }

    /**
     * Fails RED against the pre-2026-08-21 code, in which `handleApprovedSelections` ended with a
     * bare `Database.update(parentUpdates, false, AccessLevel.SYSTEM_MODE)` inside this
     * `with sharing` class. `SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing (ARCHITECTURE.md §2).
     */
    @isTest
    static void nonOwnerApprover_advancesTheParentAndStampsTheBroker() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c sub = TestDataFactory.createBovSubmission(d.Id, false);
        sub.Broker__c = TestDataFactory.createBrokerContactWithFirm('CBRE - Mark Chen', true).Id;
        sub.Submission_Status__c = 'Selected';
        insert sub;
        User approver = approverOwning('bva1', new List<Id>{ sub.Id });

        System.runAs(approver) {
            assertReadableButNotEditable(d.Id);
            Test.startTest();
            // 🔴 `AccessLevel.SYSTEM_MODE`, NOT A PLAIN `update`. MEASURED: a plain `update` fails
            // with `System.DmlException: Operation failed due to fields being inaccessible on
            // Sobject BOV_Submission__c` — no persona has FLS EDIT on `Approval_Status__c`. In
            // production this write is `Broker_Finalize_Approval`'s `finalApprovalActions` FIELD
            // UPDATE, which runs in system context and consults no FLS.
            // ⚠ IT DOES NOT WEAKEN THE TEST: SYSTEM_MODE lifts CRUD and FLS and NEVER sharing, so
            // the parent write below is still refused unless `ParentAdvanceWrites` escapes it.
            Database.update(
                new BOV_Submission__c(Id = sub.Id, Approval_Status__c = 'Approved'),
                AccessLevel.SYSTEM_MODE);
            Test.stopTest();
        }

        Assert.areEqual(new List<String>(),
            BovSubmissionTriggerHandler.lastRunParentWriteFailures,
            '🔴 THE PARENT WRITE WAS REFUSED. This list carries the platform StatusCode — read it in '
            + 'the message above. INSUFFICIENT_ACCESS_OR_READONLY means the `without sharing` escape '
            + '(ParentAdvanceWrites) has been removed or bypassed.');
        Disposition__c after = reread(d.Id);
        Assert.areEqual('Broker Selection', after.Disposition_Stage__c,
            'An approver who can SEE but not EDIT the sale must still appoint the broker on it. '
            + 'Still reading BOV Outreach means the parent update was swallowed by '
            + 'allOrNone = false, exactly as the sibling handler did in production.');
        Assert.isNotNull(after.Selected_Broker__c,
            'and the broker firm must be stamped by the same write');
    }

    /**
     * The 251-record twin, per `.claude/rules/bulk-test-rule.md`.
     *
     * ⚠ NOT A DUPLICATE of `bulk251ApprovesAtConstantCost`, which proves the second chunk is not
     * dropped as the OWNER. This proves the sharing escape survives BOTH chunks.
     */
    @isTest
    static void nonOwnerApproverAt251_advancesEveryParent() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        for (Disposition__c d : dispositions) {
            d.Disposition_Stage__c = 'BOV Outreach';
        }
        insert dispositions;

        Id brokerId = TestDataFactory.createBrokerContactWithFirm('JLL - Bulk Broker', true).Id;
        List<BOV_Submission__c> subs = new List<BOV_Submission__c>();
        for (Disposition__c d : dispositions) {
            BOV_Submission__c s = TestDataFactory.createBovSubmission(d.Id, false);
            s.Broker__c = brokerId;
            s.Submission_Status__c = 'Selected';
            subs.add(s);
        }
        insert subs;

        List<Id> subIds = new List<Id>();
        List<BOV_Submission__c> approvals = new List<BOV_Submission__c>();
        for (BOV_Submission__c s : subs) {
            subIds.add(s.Id);
            approvals.add(new BOV_Submission__c(Id = s.Id, Approval_Status__c = 'Approved'));
        }
        User approver = approverOwning('bva2', subIds);

        System.runAs(approver) {
            assertReadableButNotEditable(dispositions[0].Id);
            Test.startTest();
            // SYSTEM_MODE for the FLS reason argued at the single-record twin. Sharing is untouched.
            Database.update(approvals, AccessLevel.SYSTEM_MODE); // 251 rows -> TWO trigger chunks
            Test.stopTest();
        }

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c
             WHERE Id IN :dispositions AND Disposition_Stage__c = 'Broker Selection'],
            'Every one of the 251 parents must advance for a NON-OWNER approver. Zero means the '
            + 'sharing escape is gone; between 1 and 250 means it did not survive the second chunk.');
    }
}
