/**
 * @description Tests `BovSubmissionSelectionGuardService.enforceSingleSelected` — the before-context
 * trigger guard that REFUSES any save leaving a Disposition with more than one
 * `Submission_Status__c = 'Selected'` submission. Added 2026-08-20 with the disposition redesign,
 * Tranche 2 Workstream A2 (`agent-output/disposition-tranche-2-requirements.md` §1.2).
 *
 * ── ⚠ THE CLASS NAME DROPS "Service", AND THAT IS FORCED, NOT SLOPPY ──
 * The repo convention is `<ClassUnderTest>Test`, which would be
 * `BovSubmissionSelectionGuardServiceTest`. Apex caps an identifier at 40 CHARACTERS and the twin
 * suite's equivalent name is 41, so `DispositionOfferSelectionGuardServiceTest` DOES NOT COMPILE.
 * Both suites therefore drop `Service` and stay symmetric — a matched pair is easier to trust than
 * one conforming name beside one mangled one. 🔴 DO NOT "RESTORE" THE CONVENTION HERE: it makes this
 * file inconsistent with its twin and gains nothing. The class under test is
 * `BovSubmissionSelectionGuardService`.
 *
 * ── ⚠ AND THE STATUS CONSTANTS ARE `STATUS_*` FOR A MEASURED REASON ──
 * A constant named `SELECTED` beside a local variable named `selected` DOES NOT COMPILE: Apex
 * identifiers are CASE-INSENSITIVE, so the local shadows the constant and the compiler reports
 * `Illegal assignment from BOV_Submission__c to String` — an error that names neither identifier and
 * points at the DML keyword. Measured on this file, 2026-08-20.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 🔴 THE 251-RECORD MANDATE APPLIES IN FULL — NO EXEMPTION. This is a trigger path
 * (`BovSubmissionTriggerHandler.beforeInsert` / `beforeUpdate`) that loops over a collection. The
 * per-transaction-singleton exemption in `.claude/rules/bulk-test-rule.md` does NOT apply, and
 * neither does the `.claude/rules/content-publication-rule.md` carve-out (no content object).
 * ─────────────────────────────────────────────────────────────────────────────────────
 *
 * ── 🔴 THE FOUR TESTS THAT MUST NEVER BE DELETED, AND WHAT EACH ONE FALSIFIES ──
 *   `existingReplaceSelectedBrokerService_stillSucceeds`
 *        The single most important test in this class. `BovSubmissionService.replaceSelectedBroker`
 *        demotes the incumbent and promotes the challenger in ONE bulk DML, so a correctly written
 *        guard sees both rows and permits it. A guard that consulted only committed data — the
 *        obvious implementation — would refuse the module's central feature outright. If this ever
 *        goes red, the guard is wrong, OR that service was split into two DML statements; check
 *        which before "fixing" anything.
 *   `alreadySelectedRowSavedForAnUnrelatedReason_isNotBlocked`
 *        A pre-existing duplicate pair must not become FROZEN. A row that is already Selected and
 *        is being saved for some other reason is not BECOMING Selected and must never be judged.
 *   `demotingTheSelectedRow_isAlwaysPermitted`
 *        The remedy path. A guard that blocks the way OUT of a bad state is worse than no guard.
 *   `insertingASecondSelected_isRejectedWithAnActionableMessage`
 *        The guard's actual job — and the assertion is on the MESSAGE, not merely on the refusal,
 *        because a refusal that does not name a remedy is a dead end for the user.
 *
 * ── ⚠ WHY NO TEST BUILDS A GENUINE PRE-EXISTING DOUBLE-SELECTED PAIR ──
 * Once this guard is live that state is UNREACHABLE through any DML — which is the point. Building
 * one would require a `@TestVisible` bypass switch inside the production class, i.e. adding a
 * permanent escape hatch to prove a branch that does not exist: the pair is never EVALUATED at all,
 * because no row in such a save is becoming Selected, so it exits on the zero-query fast path that
 * `alreadySelectedRowSavedForAnUnrelatedReason_isNotBlocked` already pins. Considered and rejected.
 *
 * ── ⚠ WHY THE ERROR-BEHAVIOUR TESTS ALL USE REAL DML, AND ONLY THE COST TESTS INVOKE DIRECTLY ──
 * `addError` is a trigger-context API. Every test that expects a REFUSAL therefore performs genuine
 * DML and reads the platform's own error, rather than calling the service in-memory and inspecting
 * `hasErrors()`. The two direct-invocation tests exist solely to measure the PER-CHUNK query budget,
 * and neither of them produces an error — a real 251-row DML spans TWO trigger chunks, so asserting
 * "1 query" around it would be asserting a falsehood and asserting "2" would pin the chunk size
 * rather than the service. Same split, same reason, as `BovSubmissionBrokerStampServiceTest`.
 *
 * ⚠ COUNTERS ARE SNAPSHOTTED INSIDE `Test.startTest()` / `Test.stopTest()`, never across
 * `stopTest()` — which restores the pre-test counters and would make the assertion silently vacuous.
 *
 * ⚠ FIXTURES NEVER ASSUME AN EMPTY ORG. Every test creates its own Disposition and asserts scoped to
 * it; the org's one live `BOV_Submission__c` (`BOV-0014`, all-null, `Backup`) hangs off a different
 * parent and is invisible to every assertion here.
 *
 * @see force-app/main/default/classes/BovSubmissionSelectionGuardService.cls
 * @see force-app/main/default/classes/DispositionOfferSelectionGuardTest.cls (the twin suite)
 */
@isTest
private class BovSubmissionSelectionGuardTest {

    private static final Integer BULK_N = 251;
    private static final String STATUS_SELECTED = 'Selected';
    private static final String STATUS_BACKUP = 'Backup';

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

    /** An INSERTED submission at the given status. */
    private static BOV_Submission__c submissionAt(Id dispositionId, String status) {
        BOV_Submission__c submission = TestDataFactory.createBovSubmission(dispositionId, false);
        submission.Submission_Status__c = status;
        insert submission;
        return submission;
    }

    private static Map<Id, BOV_Submission__c> statusesOn(Id dispositionId) {
        return new Map<Id, BOV_Submission__c>([
            SELECT Id, Submission_Status__c
            FROM BOV_Submission__c
            WHERE Disposition__c = :dispositionId
        ]);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 CONSEQUENCE 1 — THE EXISTING SERVICE MUST STILL SUCCEED
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE REQUIRED FALSIFIER. `replaceSelectedBroker` demotes and promotes in ONE bulk DML, so
     * the before-update context holds BOTH rows and the incumbent's IN-MEMORY 'Backup' supersedes
     * its COMMITTED 'Selected'. An implementation that counted committed rows only would refuse
     * this — and would take the whole Replace Broker feature down with it.
     */
    @isTest
    static void existingReplaceSelectedBrokerService_stillSucceeds() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = TestDataFactory.createBovSubmission(d.Id, false);
        incumbent.Broker_Firm__c = 'CBRE - Old Incumbent';
        incumbent.Submission_Status__c = STATUS_SELECTED;
        incumbent.Approval_Status__c = 'Approved';
        BOV_Submission__c challenger = TestDataFactory.createBovSubmission(d.Id, false);
        challenger.Broker_Firm__c = 'JLL - New Challenger';
        challenger.Submission_Status__c = STATUS_BACKUP;
        insert new List<BOV_Submission__c>{ incumbent, challenger };

        Test.startTest();
        // ⚠ The 4-parameter signature dates from 2026-08-20 (Tranche 2 Workstream B): the reason is
        // now REQUIRED by the service, so a 2-parameter call here would fail on the missing reason
        // and this falsifier would go green for the wrong reason — proving nothing about the guard.
        String message = BovSubmissionService.replaceSelectedBroker(
            d.Id, challenger.Id, 'Performance Issue', null);
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = statusesOn(d.Id);
        Assert.areEqual(STATUS_SELECTED, after.get(challenger.Id).Submission_Status__c,
            '🔴 THE GUARD MUST NOT REFUSE THE REPLACE SERVICE\'S OWN SWAP. The challenger must be '
            + 'promoted — a guard reading only committed data would have blocked this save');
        Assert.areEqual(STATUS_BACKUP, after.get(incumbent.Id).Submission_Status__c,
            'And the incumbent must be demoted in the same save, which is exactly what makes the '
            + 'promotion legal');
        Assert.isTrue(message.contains('must be approved'),
            'The service\'s authored confirmation must still be returned: ' + message);
    }

    /**
     * The same shape as the service, performed with RAW DML rather than through it — so the guard's
     * contract is pinned independently of `BovSubmissionService`. A data loader or an integration
     * that demotes and promotes in one call is doing something legitimate and must be allowed.
     */
    @isTest
    static void demoteAndPromoteInOneSave_isPermitted() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = submissionAt(d.Id, STATUS_SELECTED);
        BOV_Submission__c challenger = submissionAt(d.Id, STATUS_BACKUP);

        Test.startTest();
        update new List<BOV_Submission__c>{
            new BOV_Submission__c(Id = incumbent.Id, Submission_Status__c = STATUS_BACKUP),
            new BOV_Submission__c(Id = challenger.Id, Submission_Status__c = STATUS_SELECTED)
        };
        Test.stopTest();

        Map<Id, BOV_Submission__c> after = statusesOn(d.Id);
        Assert.areEqual(STATUS_SELECTED, after.get(challenger.Id).Submission_Status__c,
            'A demote-and-promote in ONE DML must be permitted — the in-memory demotion supersedes '
            + 'the committed row');
        Assert.areEqual(STATUS_BACKUP, after.get(incumbent.Id).Submission_Status__c,
            'And the demotion must have applied');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 CONSEQUENCE 2 — AN ALREADY-SELECTED ROW IS NEVER BLOCKED
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE ANTI-FREEZE FALSIFIER. Saving an already-Selected row for an unrelated reason must be
     * permitted, and must not even reach the query. An implementation that judged "is Selected now"
     * rather than "is BECOMING Selected" would find the row's own committed copy and refuse it —
     * making every Selected submission in the org permanently unsavable.
     */
    @isTest
    static void alreadySelectedRowSavedForAnUnrelatedReason_isNotBlocked() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = submissionAt(d.Id, STATUS_SELECTED);

        Test.startTest();
        update new BOV_Submission__c(Id = incumbent.Id, BOV_Amount__c = 9999999);
        Test.stopTest();

        BOV_Submission__c after = [
            SELECT Submission_Status__c, BOV_Amount__c
            FROM BOV_Submission__c WHERE Id = :incumbent.Id
        ];
        Assert.areEqual(STATUS_SELECTED, after.Submission_Status__c,
            'The row must still be Selected — the save was about something else entirely');
        Assert.areEqual(9999999, after.BOV_Amount__c,
            '🔴 AND THE UNRELATED EDIT MUST HAVE COMMITTED. A guard that counts "Selected NOW" '
            + 'instead of "BECOMING Selected" freezes every Selected submission in the org');
    }

    /**
     * The same guarantee for a save that re-states the SAME status. `Selected -> Selected` is not a
     * transition, so it must not be judged even though the field itself appears in the update.
     */
    @isTest
    static void rewritingTheSameSelectedValue_isNotBlocked() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = submissionAt(d.Id, STATUS_SELECTED);

        Test.startTest();
        update new BOV_Submission__c(Id = incumbent.Id, Submission_Status__c = STATUS_SELECTED);
        Test.stopTest();

        Assert.areEqual(STATUS_SELECTED,
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :incumbent.Id]
                .Submission_Status__c,
            'Re-writing the same value is not a transition and must not be refused');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 CONSEQUENCE 3 — A SAVE THAT REDUCES THE SELECTED COUNT ALWAYS PASSES
    // ═════════════════════════════════════════════════════════════════════════

    /** The remedy path. A guard that blocks the way out of a bad state is worse than no guard. */
    @isTest
    static void demotingTheSelectedRow_isAlwaysPermitted() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = submissionAt(d.Id, STATUS_SELECTED);

        Test.startTest();
        update new BOV_Submission__c(Id = incumbent.Id, Submission_Status__c = STATUS_BACKUP);
        Test.stopTest();

        Assert.areEqual(STATUS_BACKUP,
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :incumbent.Id]
                .Submission_Status__c,
            'Demoting is a REDUCTION in the Selected count and must always be permitted');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE GUARD'S ACTUAL JOB — GENUINE DUPLICATES ARE REFUSED
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The headline case, and the one the BOV half exists for: `Submission_Status__c` is granted
     * READ + EDIT in `DPEG_Disposition_Edit`, so this is breakable BY HAND today.
     *
     * ⚠ THE MESSAGE IS ASSERTED, NOT JUST THE REFUSAL. A refusal that does not name a remedy leaves
     * the user with a dead end, and "use Replace Broker" is the whole reason this is a refusal
     * rather than a silent self-heal.
     */
    @isTest
    static void insertingASecondSelected_isRejectedWithAnActionableMessage() {
        Disposition__c d = dispositionAt('BOV Outreach');
        submissionAt(d.Id, STATUS_SELECTED);
        BOV_Submission__c intruder = TestDataFactory.createBovSubmission(d.Id, false);
        intruder.Submission_Status__c = STATUS_SELECTED;

        Test.startTest();
        Database.SaveResult result = Database.insert(intruder, false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            '🔴 A SECOND Selected SUBMISSION MUST BE REFUSED — this invariant was previously '
            + 'guaranteed only by service code and was breakable by hand');
        String message = result.getErrors()[0].getMessage();
        Assert.isTrue(message.contains('only one is allowed'),
            'The refusal must state the rule: ' + message);
        Assert.isTrue(message.contains('Replace Broker'),
            'And it must name the remedy — a refusal without one is a dead end: ' + message);
        Assert.areEqual(1, statusesOn(d.Id).size(),
            'The intruder must not have been saved at all');
    }

    /** The update half of the same case: promoting a Backup row while an incumbent still stands. */
    @isTest
    static void promotingASecondSelectedByUpdate_isRejected() {
        Disposition__c d = dispositionAt('BOV Outreach');
        BOV_Submission__c incumbent = submissionAt(d.Id, STATUS_SELECTED);
        BOV_Submission__c challenger = submissionAt(d.Id, STATUS_BACKUP);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new BOV_Submission__c(Id = challenger.Id, Submission_Status__c = STATUS_SELECTED),
            false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'Promoting a second broker WITHOUT demoting the incumbent in the same save must be '
            + 'refused — that is the difference between this and the replace service');
        Map<Id, BOV_Submission__c> after = statusesOn(d.Id);
        Assert.areEqual(STATUS_BACKUP, after.get(challenger.Id).Submission_Status__c,
            'The challenger must be left exactly as it was');
        Assert.areEqual(STATUS_SELECTED, after.get(incumbent.Id).Submission_Status__c,
            'And the incumbent must be untouched — the guard REFUSES, it never self-heals');
    }

    /**
     * ⚠ THE DELIBERATE EXTENSION OF THE WRITTEN RULE, PINNED. A row that is ALREADY Selected and is
     * REPARENTED onto a disposition that already has one arrives Selected there without its status
     * ever "changing to Selected". The literal rule would miss it; the implemented condition is
     * "newly Selected ON THIS DISPOSITION". Delete this test together with the
     * `prior.Disposition__c != ...` clause if the narrower rule is ever preferred — nothing else
     * depends on it.
     */
    @isTest
    static void reparentingASelectedRowOntoAnOccupiedDisposition_isRejected() {
        Disposition__c origin = dispositionAt('BOV Outreach');
        Disposition__c destination = dispositionAt('BOV Outreach');
        BOV_Submission__c mover = submissionAt(origin.Id, STATUS_SELECTED);
        submissionAt(destination.Id, STATUS_SELECTED);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new BOV_Submission__c(Id = mover.Id, Disposition__c = destination.Id), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'Moving an already-Selected submission onto a disposition that already has one creates '
            + 'exactly the state this guard exists to prevent, so it must be refused even though '
            + 'the status never changed');
        Assert.areEqual(origin.Id,
            [SELECT Disposition__c FROM BOV_Submission__c WHERE Id = :mover.Id].Disposition__c,
            'The move must not have committed');
    }

    /** Reparenting onto an EMPTY disposition is legitimate and must still be allowed. */
    @isTest
    static void reparentingASelectedRowOntoAnEmptyDisposition_isPermitted() {
        Disposition__c origin = dispositionAt('BOV Outreach');
        Disposition__c destination = dispositionAt('BOV Outreach');
        BOV_Submission__c mover = submissionAt(origin.Id, STATUS_SELECTED);

        Test.startTest();
        update new BOV_Submission__c(Id = mover.Id, Disposition__c = destination.Id);
        Test.stopTest();

        Assert.areEqual(destination.Id,
            [SELECT Disposition__c FROM BOV_Submission__c WHERE Id = :mover.Id].Disposition__c,
            'The extension must block only a move onto an OCCUPIED disposition, never every move');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SCOPE — THE GUARD IS PER DISPOSITION, AND PARENTLESS ROWS ARE OUT OF SCOPE
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void firstSelectedOnADispositionThatHasNone_isPermitted() {
        Disposition__c d = dispositionAt('BOV Outreach');
        submissionAt(d.Id, STATUS_BACKUP);
        BOV_Submission__c winner = TestDataFactory.createBovSubmission(d.Id, false);
        winner.Submission_Status__c = STATUS_SELECTED;

        Test.startTest();
        insert winner;
        Test.stopTest();

        Assert.areEqual(STATUS_SELECTED,
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :winner.Id]
                .Submission_Status__c,
            'The FIRST Selected submission on a disposition is the normal case and must pass');
    }

    /**
     * 🔴 THE SCOPE FALSIFIER. Two Selected submissions on DIFFERENT dispositions is the ordinary
     * state of a healthy org. A guard keyed on the object rather than on the parent would refuse
     * every disposition in the system after the first.
     */
    @isTest
    static void selectedRowsOnDifferentDispositions_doNotInterfere() {
        Disposition__c first = dispositionAt('BOV Outreach');
        Disposition__c second = dispositionAt('BOV Outreach');
        submissionAt(first.Id, STATUS_SELECTED);
        BOV_Submission__c other = TestDataFactory.createBovSubmission(second.Id, false);
        other.Submission_Status__c = STATUS_SELECTED;

        Test.startTest();
        insert other;
        Test.stopTest();

        Assert.areEqual(STATUS_SELECTED,
            [SELECT Submission_Status__c FROM BOV_Submission__c WHERE Id = :other.Id]
                .Submission_Status__c,
            'A Selected submission on ANOTHER disposition must be irrelevant — the invariant is '
            + 'per parent, not per object');
    }

    /** A submission with no parent has no siblings, so there is no invariant to enforce. */
    @isTest
    static void selectedSubmissionWithNoDisposition_isNeverBlocked() {
        List<BOV_Submission__c> orphans = TestDataFactory.createBovSubmissions(2, null, false);
        for (BOV_Submission__c orphan : orphans) {
            orphan.Submission_Status__c = STATUS_SELECTED;
        }

        Test.startTest();
        insert orphans;
        Test.stopTest();

        Assert.areEqual(2,
            [SELECT COUNT() FROM BOV_Submission__c WHERE Id IN :orphans],
            'Parentless submissions have no siblings and must never be judged');
    }

    /** Null/empty-safe per the method's own ApexDoc — a no-op, not an error. */
    @isTest
    static void nullOrEmptyList_returnsWithoutError() {
        Boolean completedWithoutThrowing = false;

        Test.startTest();
        BovSubmissionSelectionGuardService.enforceSingleSelected(null, null);
        BovSubmissionSelectionGuardService.enforceSingleSelected(
            new List<BOV_Submission__c>(), null);
        completedWithoutThrowing = true; // reached only if neither call above threw
        Test.stopTest();

        Assert.isTrue(completedWithoutThrowing,
            'Both calls must return without throwing — the guard is a no-op, not an error');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BULK — 251 RECORDS, .claude/rules/bulk-test-rule.md
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE PER-CHUNK BUDGET, MEASURED BY DIRECT INVOCATION (see the class header for why not
     * through the trigger). 251 records becoming Selected across 251 DISTINCT dispositions must
     * cost EXACTLY ONE query — the whole point of keying the selector on a `Set<Id>`. A per-record
     * implementation would issue 251 and die at the 101st.
     *
     * ⚠ IT ALSO PROVES 251 LEGITIMATE FIRST-SELECTIONS ALL PASS: every disposition is empty, so no
     * row may be refused.
     */
    @isTest
    static void bulk251BecomingSelected_costsExactlyOneQueryForTheWholeChunk() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        List<BOV_Submission__c> newList = new List<BOV_Submission__c>();
        for (Disposition__c d : dispositions) {
            BOV_Submission__c submission = TestDataFactory.createBovSubmission(d.Id, false);
            submission.Submission_Status__c = STATUS_SELECTED;
            newList.add(submission); // Id null — the true before-insert shape
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BovSubmissionSelectionGuardService.enforceSingleSelected(newList, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for 251 records across 251 dispositions — the sibling read is keyed '
            + 'on the whole Set<Id>. Anything above 1 means it moved into the per-record loop.');
        Integer refused = 0;
        for (BOV_Submission__c submission : newList) {
            if (submission.hasErrors()) {
                refused++;
            }
        }
        Assert.areEqual(0, refused,
            '251 FIRST selections on 251 empty dispositions must all be permitted');
    }

    /**
     * The other half of the constant-cost claim, and the one that matters most in practice: a chunk
     * in which NO row is becoming Selected costs NOTHING even at 251. These before contexts fire on
     * every `BOV_Submission__c` write in the org, so this is the overwhelmingly common path.
     */
    @isTest
    static void bulk251NoRowBecomesSelected_costsNothing() {
        Id dispositionId = dispositionAt('BOV Outreach').Id;
        List<BOV_Submission__c> baseline =
            TestDataFactory.createBovSubmissions(BULK_N, dispositionId, true);

        List<BOV_Submission__c> newList = new List<BOV_Submission__c>();
        Map<Id, BOV_Submission__c> priorById = new Map<Id, BOV_Submission__c>();
        for (BOV_Submission__c submission : baseline) {
            // Every record is "saved" with a field OTHER than the status changing.
            newList.add(new BOV_Submission__c(
                Id = submission.Id,
                Disposition__c = dispositionId,
                Submission_Status__c = STATUS_BACKUP,
                BOV_Amount__c = 5000000
            ));
            priorById.put(submission.Id, new BOV_Submission__c(
                Id = submission.Id,
                Disposition__c = dispositionId,
                Submission_Status__c = STATUS_BACKUP
            ));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BovSubmissionSelectionGuardService.enforceSingleSelected(newList, priorById);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed,
            '🔴 THE ZERO-QUERY FAST PATH. A save in which no row becomes Selected must cost NOTHING '
            + 'even at 251 records — this is what keeps the guard invisible to the bulk tests of '
            + 'every unrelated feature');
    }

    /**
     * The real-DML bulk proof: 251 rows through the genuine trigger, spanning TWO chunks.
     * COMPLETING AT ALL is part of the falsifier — a per-record query would need 251 SOQL and would
     * blow the 100-query limit long before finishing.
     */
    @isTest
    static void bulk251FirstSelectionsOnDistinctDispositions_allSave() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        List<BOV_Submission__c> submissions = new List<BOV_Submission__c>();
        for (Disposition__c d : dispositions) {
            BOV_Submission__c submission = TestDataFactory.createBovSubmission(d.Id, false);
            submission.Submission_Status__c = STATUS_SELECTED;
            submissions.add(submission);
        }

        Test.startTest();
        insert submissions; // 251 rows -> TWO trigger chunks
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM BOV_Submission__c
             WHERE Id IN :submissions AND Submission_Status__c = :STATUS_SELECTED],
            'All 251 must have saved — a total below 251 means the second trigger chunk refused '
            + 'rows it should not have, or the query budget blew');
    }

    /**
     * The bulk REFUSAL: 251 rows all claiming the same disposition. Every one must be rejected and
     * named individually — "tell the loader which rows are wrong" is reason 3 in the guard's
     * reject-not-self-heal argument.
     *
     * ⚠ ALL 251, NOT 250. No row here has a prior claim: each is judged against the other 250 in
     * its own chunk, so none is "the first". Refusing them all is correct — a human must say which
     * broker is appointed, which is the whole point of refusing rather than self-healing.
     */
    @isTest
    static void bulk251SelectedOnOneDisposition_everyRowIsRejected() {
        Id dispositionId = dispositionAt('BOV Outreach').Id;
        List<BOV_Submission__c> submissions =
            TestDataFactory.createBovSubmissions(BULK_N, dispositionId, false);
        for (BOV_Submission__c submission : submissions) {
            submission.Submission_Status__c = STATUS_SELECTED;
        }

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(submissions, false);
        Test.stopTest();

        Integer refused = 0;
        for (Database.SaveResult result : results) {
            if (!result.isSuccess()
                    && result.getErrors()[0].getMessage().contains('only one is allowed')) {
                refused++;
            }
        }
        Assert.areEqual(BULK_N, refused,
            'Every one of the 251 rows must be refused BY NAME with the authored message — a bulk '
            + 'load must be told which rows are wrong, not silently have some rewritten');
        Assert.areEqual(0,
            [SELECT COUNT() FROM BOV_Submission__c WHERE Disposition__c = :dispositionId],
            'And nothing may have been saved');
    }
}
