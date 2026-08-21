/**
 * @description Tests DispositionApprovalAdvanceService — the D-1 semaphore-driven stage advance
 * that runs AFTER a Disposition-target approval (Sale_Decision_Approval, Broker_Selection_Approval,
 * Closing_Approval) completes. Added 2026-08-19 with the disposition flow redesign (DEV-3).
 *
 * ─────────────────────────────────────────────────────────────────────────────────────
 * 251-RECORD BULK MANDATE APPLIES IN FULL — NO EXEMPTION. .claude/rules/bulk-test-rule.md
 * ─────────────────────────────────────────────────────────────────────────────────────
 * Both `enqueuePendingAdvances` (trigger-driven, DispositionTriggerHandler.afterUpdate) and
 * `advance` (Queueable-driven) are trigger-chain machinery, not per-click singletons — the class's
 * own header states the budget is CONSTANT in the number of dispositions per chunk (ONE selector
 * query, ONE Database.update, AT MOST ONE enqueue) and that constancy, not merely "251 rows
 * produced 251 advances", is the property under test. `bulk251AdvancesEveryRowAtConstantCost`
 * below asserts the governor counters directly rather than only the row counts.
 *
 * ── THE TWO EASY-TO-WRITE-VACUOUSLY FALSIFIERS THIS CLASS EXISTS FOR ────────
 *   1. A REFUSED ADVANCE MUST LEAVE Approval_Advance_Pending__c TRUE **AND** THE STAGE UNCHANGED.
 *      The stage write and the semaphore clear are ONE Database.update — refusalLeavesTheFlagTrue
 *      AndTheStageUnchanged asserts BOTH in the SAME test, because asserting only one half would
 *      pass even if the class quietly cleared the flag while failing the write (or vice versa).
 *   2. AN APPROVAL FIRING ON AN ALREADY-ADVANCED PARENT MUST NOT MOVE IT A SECOND HOP.
 *      alreadyAdvancedParentIsLeftAlone proves this on a row whose CURRENT stage no longer matches
 *      what the semaphore was set for — the re-read (never Trigger.new) is what makes an
 *      already-advanced row find no mapping and stay put.
 *
 * ── GOVERNOR-COUNTER TRAP, AVOIDED DELIBERATELY ─────────────────────────────
 * Every governor assertion here calls `DispositionApprovalAdvanceService.advance(...)` DIRECTLY,
 * synchronously, with `Limits.getQueries()` / `Limits.getDmlStatements()` snapshotted immediately
 * before and after that one call — never across `Test.stopTest()`, which restores the pre-test
 * counters and would make the obvious assertion silently vacuous.
 *
 * ── ALL_NDAs_SIGNED_BEFORE_PROGRESSION ──────────────────────────────────────
 * `Sale Closes` is one of the VR's gated target stages (since the 2026-08-19 redesign dropped its
 * Off_Market-only term), so every fixture that legitimately advances INTO Sale Closes signs a
 * buyer NDA first. `Broker Selection`, `BOV Outreach` and `NDA` are not gated — no NDA is needed
 * to reach those.
 *
 * @see force-app/main/default/classes/DispositionApprovalAdvanceService.cls
 * @see force-app/main/default/classes/DispositionApprovalAdvanceQueueable.cls
 * @author Unit Testing Agent
 */
@isTest
private class DispositionApprovalAdvanceServiceTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        TestDataFactory.createPropertyAsset(prop.Id, true);
    }

    private static Id assetId() {
        return [SELECT Id FROM Property_Asset__c LIMIT 1].Id;
    }

    private static Disposition__c dispositionAt(String recordType, String stage) {
        Disposition__c d = TestDataFactory.createDisposition(assetId(), recordType, false);
        d.Disposition_Stage__c = stage;
        insert d;
        return d;
    }

    private static void signBuyerNdaOn(Id dispositionId) {
        NDA__c nda = TestDataFactory.createDispositionNda(dispositionId, false);
        nda.Status__c = 'Signed';
        insert nda;
    }

    /**
     * WITH SYSTEM_MODE — Approval_Advance_Pending__c carries NO FLS for anyone by design (see
     * A-3a / the field's own field-meta.xml), so it is genuinely unreadable via a plain query
     * regardless of profile, including System Administrator. No production code reads this field
     * via SOQL at all (only via DML), so this test-only read must bypass FLS explicitly to reach
     * the field a real query never needs to.
     */
    private static Disposition__c reread(Id dispositionId) {
        return [
            SELECT Disposition_Stage__c, Approval_Advance_Pending__c
            FROM Disposition__c
            WHERE Id = :dispositionId
            WITH SYSTEM_MODE
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // advance() — RECORD-TYPE-DEPENDENT TARGETS
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void readinessAdvancesOnMarketToBovOutreach() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');

        Test.startTest();
        DispositionApprovalAdvanceService.advance(new Set<Id>{ d.Id });
        Test.stopTest();

        Disposition__c after = reread(d.Id);
        Assert.areEqual('BOV Outreach', after.Disposition_Stage__c,
            'On_Market at Readiness must advance to BOV Outreach');
        Assert.isFalse(after.Approval_Advance_Pending__c, 'The semaphore must clear on success');
    }

    @isTest
    static void readinessAdvancesOffMarketToBrokerSelection() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_OFF_MARKET, 'Disposition Readiness');

        Test.startTest();
        DispositionApprovalAdvanceService.advance(new Set<Id>{ d.Id });
        Test.stopTest();

        Disposition__c after = reread(d.Id);
        Assert.areEqual('Broker Selection', after.Disposition_Stage__c,
            '🔴 THE SAME APPROVAL, THE SAME ENTRY STAGE, A DIFFERENT TARGET — this is the whole '
            + 'reason the map is keyed on record type AND stage, not stage alone');
        Assert.isFalse(after.Approval_Advance_Pending__c, 'The semaphore must clear on success');
    }

    @isTest
    static void brokerSelectionAdvancesOffMarketToNdaOnly() {
        Disposition__c offMarket = dispositionAt(TestDataFactory.DISPOSITION_RT_OFF_MARKET, 'Broker Selection');
        Disposition__c onMarket = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Broker Selection');

        Test.startTest();
        DispositionApprovalAdvanceService.advance(new Set<Id>{ offMarket.Id, onMarket.Id });
        Test.stopTest();

        Assert.areEqual('NDA', reread(offMarket.Id).Disposition_Stage__c,
            'Off_Market Broker Selection advances to NDA via Broker_Selection_Approval');
        Assert.areEqual('Broker Selection', reread(onMarket.Id).Disposition_Stage__c,
            '🔴 ON_MARKET|Broker Selection IS DELIBERATELY UNMAPPED. That hop is owned by the manual '
            + 'Advance to NDA quick action, and a build that added it here would let an approval '
            + 'that cannot even fire on this record type move it anyway the moment anything else '
            + 'set the semaphore. This row must not move AT ALL — same call, opposite outcome per '
            + 'record type, which no stage-only map could express.');
    }

    @isTest
    static void closingAdvancesBothRecordTypesToSaleCloses() {
        Disposition__c onMarket = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Closing');
        onMarket.Wire_Verification_Completed__c = true;
        update onMarket;
        signBuyerNdaOn(onMarket.Id);

        Disposition__c offMarket = dispositionAt(TestDataFactory.DISPOSITION_RT_OFF_MARKET, 'Closing');
        offMarket.Wire_Verification_Completed__c = true;
        update offMarket;
        signBuyerNdaOn(offMarket.Id);

        Test.startTest();
        DispositionApprovalAdvanceService.advance(new Set<Id>{ onMarket.Id, offMarket.Id });
        Test.stopTest();

        Assert.areEqual('Sale Closes', reread(onMarket.Id).Disposition_Stage__c,
            'On_Market Closing advances to Sale Closes once the wire is verified');
        Assert.areEqual('Sale Closes', reread(offMarket.Id).Disposition_Stage__c,
            'Off_Market Closing advances to Sale Closes too — both record types converge here');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 🔴 THE TWO FALSIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * A refusal (the wire flag flipped back to false between the approval and this Queueable
     * running — the class header's own documented residual) must leave BOTH halves of the ONE
     * `Database.update` exactly where they were: the stage AND the semaphore.
     */
    @isTest
    static void refusalLeavesTheFlagTrueAndTheStageUnchanged() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Closing');
        // Wire_Verification_Completed__c left FALSE — Wire_Complete_Before_Sale_Closes will refuse
        // the write to 'Sale Closes' outright.
        d.Approval_Advance_Pending__c = true;
        // Database.update(..., AccessLevel.SYSTEM_MODE) — Approval_Advance_Pending__c deliberately
        // carries NO FLS for anyone (see its own field-meta.xml), so a plain `update` here would
        // throw for the SAME reason a real user-context write would; only a workflow FieldUpdate
        // (system context) or an explicit SYSTEM_MODE write can set it, which is exactly what this
        // simulates.
        Database.update(d, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        DispositionApprovalAdvanceService.advance(new Set<Id>{ d.Id });
        Test.stopTest();

        Disposition__c after = reread(d.Id);
        Assert.areEqual('Closing', after.Disposition_Stage__c,
            'A validation-rule-blocked write must leave the stage EXACTLY where it was');
        Assert.isTrue(after.Approval_Advance_Pending__c,
            '🔴 AND THE FLAG MUST STILL READ TRUE — the stage write and the flag clear are ONE '
            + 'statement, so a refusal on the write cannot silently clear the flag. A build that '
            + 'split them into two DML statements would fail ONLY this half of the assertion.');
    }

    /**
     * An approval firing on a row whose stage has ALREADY moved on (a legitimate race: the record
     * advanced again between the approval completing and this job running) must not push it a
     * SECOND hop. The re-read (never Trigger.new) is what makes this possible — the semaphore was
     * set for 'Disposition Readiness' but the row now reads 'BOV Outreach', which has no mapping
     * at all for On_Market, so it is left alone.
     */
    @isTest
    static void alreadyAdvancedParentIsLeftAlone() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'BOV Outreach');
        d.Approval_Advance_Pending__c = true; // stale semaphore, as if set while still at Readiness
        Database.update(d, AccessLevel.SYSTEM_MODE); // the field has no FLS for anyone — see above

        Test.startTest();
        DispositionApprovalAdvanceService.advance(new Set<Id>{ d.Id });
        Test.stopTest();

        Disposition__c after = reread(d.Id);
        Assert.areEqual('BOV Outreach', after.Disposition_Stage__c,
            'A row already past Readiness must not be pushed to a second hop');
        Assert.isTrue(after.Approval_Advance_Pending__c,
            'The unmapped pair leaves the semaphore exactly as it was — true, visible, recoverable');
    }

    @isTest
    static void nullAndEmptyInputsAreNoOps() {
        Test.startTest();
        DispositionApprovalAdvanceService.advance(null);
        DispositionApprovalAdvanceService.advance(new Set<Id>());
        Test.stopTest();
        Assert.isTrue(true, 'Null and empty inputs must return quietly, never throw');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // enqueuePendingAdvances() — THE TRANSITION, NOT THE VALUE
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void enqueuesOnlyForAFalseToTrueTransition() {
        Disposition__c stillTrue = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        stillTrue.Approval_Advance_Pending__c = true;
        Database.update(stillTrue, AccessLevel.SYSTEM_MODE); // no FLS for anyone — see the other tests

        List<Disposition__c> newList = new List<Disposition__c>{
            new Disposition__c(Id = stillTrue.Id, Approval_Advance_Pending__c = true)
        };
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>{
            // Already true BEFORE this save — not a transition.
            stillTrue.Id => new Disposition__c(Id = stillTrue.Id, Approval_Advance_Pending__c = true)
        };

        Test.startTest();
        Integer jobsBefore = Limits.getQueueableJobs();
        DispositionApprovalAdvanceService.enqueuePendingAdvances(newList, oldMap);
        Integer jobsUsed = Limits.getQueueableJobs() - jobsBefore;
        Test.stopTest();

        Assert.areEqual(0, jobsUsed,
            'A row ALREADY true before this save must not re-enqueue — an unrelated later save on '
            + 'an already-approved-and-stuck record must not turn one stuck row into an enqueue on '
            + 'every unrelated edit');
    }

    @isTest
    static void insertWithTheFlagAlreadyTrueCountsAsATransition() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        List<Disposition__c> newList = new List<Disposition__c>{
            new Disposition__c(Id = d.Id, Approval_Advance_Pending__c = true)
        };

        Test.startTest();
        Integer jobsBefore = Limits.getQueueableJobs();
        // oldMap == null, simulating an INSERT context — prior is always null there.
        DispositionApprovalAdvanceService.enqueuePendingAdvances(newList, null);
        Integer jobsUsed = Limits.getQueueableJobs() - jobsBefore;
        Test.stopTest();

        Assert.areEqual(1, jobsUsed,
            'A row CREATED with the flag already true (a legitimate data-load shape) counts as a '
            + 'transition — prior == null on insert');
    }

    @isTest
    static void enqueuePendingAdvancesIsNullAndEmptySafe() {
        DispositionApprovalAdvanceService.enqueuePendingAdvances(null, null);
        DispositionApprovalAdvanceService.enqueuePendingAdvances(new List<Disposition__c>(), null);
        Assert.isTrue(true, 'Null and empty inputs must return quietly, never throw');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // END-TO-END: THE REAL TRIGGER (afterUpdate -> enqueue -> Queueable -> advance)
    // ═══════════════════════════════════════════════════════════════════════════

    @isTest
    static void realTriggerFlipEnqueuesAndAdvancesAfterCommit() {
        Disposition__c d = dispositionAt(TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');

        Test.startTest();
        // Database.update(..., AccessLevel.SYSTEM_MODE) — the field has no FLS for anyone; a real
        // approval's finalApprovalActions FieldUpdate writes it in system context, which this
        // simulates. The DML still re-fires DispositionTrigger exactly as a plain `update` would.
        Database.update(new Disposition__c(Id = d.Id, Approval_Advance_Pending__c = true), AccessLevel.SYSTEM_MODE);
        Test.stopTest(); // flushes the enqueued DispositionApprovalAdvanceQueueable

        Disposition__c after = reread(d.Id);
        Assert.areEqual('BOV Outreach', after.Disposition_Stage__c,
            'The real trigger path — DispositionTriggerHandler.afterUpdate -> '
            + 'enqueuePendingAdvances -> Queueable -> advance() — must move the stage after commit');
        Assert.isFalse(after.Approval_Advance_Pending__c, 'And clear the semaphore');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 251-RECORD BULK — CONSTANT COST, NOT MERELY "251 IN, 251 OUT"
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE GOVERNOR ASSERTION IS THE POINT OF THIS TEST, NOT THE ROW COUNT. The class header
     * states the budget is ONE selector query and ONE Database.update per chunk, CONSTANT in the
     * number of dispositions. Both counters are snapshotted around a DIRECT, SYNCHRONOUS call to
     * `advance()` — never across Test.stopTest(), which would silently zero them.
     */
    @isTest
    static void bulk251AdvancesEveryRowAtConstantCost() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        for (Disposition__c d : dispositions) {
            d.Disposition_Stage__c = 'Disposition Readiness';
        }
        insert dispositions;
        Set<Id> ids = new Map<Id, Disposition__c>(dispositions).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        DispositionApprovalAdvanceService.advance(ids);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(1, queriesUsed,
            'EXACTLY ONE query for the whole 251-row set — never one per record');
        Assert.areEqual(1, dmlUsed,
            'EXACTLY ONE Database.update for the whole 251-row set — never one per record');
        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c WHERE Id IN :ids AND Disposition_Stage__c = 'BOV Outreach'],
            'Every one of the 251 dispositions must have advanced');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Disposition__c WHERE Id IN :ids AND Approval_Advance_Pending__c = true WITH SYSTEM_MODE],
            'No stuck semaphores — the whole chunk succeeded');
    }

    /**
     * The end-to-end trigger path at 251, which is what proves the CHUNKING claim: 251 forces a
     * SECOND trigger batch (chunks are 200), so completing this test at all — with every one of
     * the 251 advanced — is the falsifier for "the hook only fires on the first chunk".
     */
    @isTest
    static void bulk251ThroughTheRealTriggerAdvancesBothChunks() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        for (Disposition__c d : dispositions) {
            d.Disposition_Stage__c = 'Disposition Readiness';
        }
        insert dispositions;
        List<Disposition__c> flips = new List<Disposition__c>();
        for (Disposition__c d : dispositions) {
            flips.add(new Disposition__c(Id = d.Id, Approval_Advance_Pending__c = true));
        }

        Test.startTest();
        // Database.update(..., AccessLevel.SYSTEM_MODE) — Approval_Advance_Pending__c has no FLS
        // for anyone; simulates the workflow FieldUpdate's system context. Still 251 rows -> TWO
        // trigger chunks, TWO enqueued Queueables.
        Database.update(flips, AccessLevel.SYSTEM_MODE);
        Test.stopTest();

        Assert.areEqual(BULK_N,
            [SELECT COUNT() FROM Disposition__c WHERE Id IN :dispositions AND Disposition_Stage__c = 'BOV Outreach'],
            'Every one of the 251 dispositions must have advanced — a total below 251 means the '
            + 'second trigger chunk\'s Queueable was dropped');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Disposition__c WHERE Id IN :dispositions AND Approval_Advance_Pending__c = true WITH SYSTEM_MODE],
            'No stuck semaphores across either chunk');
    }

    /**
     * A chunk in which NO row's semaphore transitioned costs zero queries, zero DML and zero
     * enqueues — the overwhelmingly common Disposition save.
     */
    @isTest
    static void aSaveWithNoTransitionCostsNothingAt251() {
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, assetId(), TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        List<Disposition__c> newList = new List<Disposition__c>();
        Map<Id, Disposition__c> oldMap = new Map<Id, Disposition__c>();
        for (Disposition__c d : dispositions) {
            // Flag stays false on both sides of the save — no transition anywhere in the chunk.
            newList.add(new Disposition__c(Id = d.Id, Approval_Advance_Pending__c = false));
            oldMap.put(d.Id, new Disposition__c(Id = d.Id, Approval_Advance_Pending__c = false));
        }

        Test.startTest();
        Integer jobsBefore = Limits.getQueueableJobs();
        DispositionApprovalAdvanceService.enqueuePendingAdvances(newList, oldMap);
        Integer jobsUsed = Limits.getQueueableJobs() - jobsBefore;
        Test.stopTest();

        Assert.areEqual(0, jobsUsed,
            'A 251-row chunk with no false -> true transition anywhere must enqueue nothing at all');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE NON-OWNER APPROVER (2026-08-21) — the fourth site of the `DISP-0011` sharing wave.
    // ═════════════════════════════════════════════════════════════════════════════════════════
    // ⚠ EVERY TEST ABOVE PASSED AGAINST THE PRE-FIX CODE, because they run as the admin test user
    // who OWNS every fixture Disposition. A **Queueable executes as the ENQUEUING user**, and the
    // enqueuing transaction is the approval's own field update — so in production `advance()` runs
    // as the APPROVER, against a record OWNED BY THE SUBMITTER. On an OWD-Private object that is a
    // record-level edit denial, and the async hop moves the LOCK problem while moving nothing at
    // all about identity.
    //
    // ⚠ `advance()` IS CALLED DIRECTLY RATHER THAN THROUGH THE QUEUEABLE, matching every other test
    // in this class and for the reason the service header gives: the mapping and the write live in
    // the service precisely so they are reachable without contriving an approval. The identity the
    // Queueable would carry is supplied here by `System.runAs`, which is the only part that matters
    // to this test.

    /**
     * 🔴 KEEPS THE TEST BELOW HONEST. Run INSIDE `System.runAs` against `UserInfo.getUserId()`.
     * `RecordId` must be in the SELECT — `UserRecordAccess` rejects a query without it at compile
     * time.
     */
    private static void assertReadableButNotEditable(Id dispositionId) {
        UserRecordAccess access = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :dispositionId
        ];
        Assert.isTrue(access.HasReadAccess,
            'FIXTURE PRECONDITION: the approver must READ the row — that is what lets '
            + 'selectStageAndTypeByIds return it, which is why the write failure stays hidden.');
        Assert.isFalse(access.HasEditAccess,
            '🔴 FIXTURE PRECONDITION: the approver must NOT be able to EDIT the row. That is the '
            + 'refusal under test; if this is true every assertion after it is vacuous.');
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴🔴 READ THIS BEFORE TRUSTING THIS TEST. IT IS **NOT** A FALSIFIER, AND THAT IS MEASURED.
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * MUTATION-TESTED 2026-08-21: `SemaphoreAdvanceWrites` was flipped from `without sharing` to
     * `with sharing` — i.e. the fix was fully reverted — and **this test STAYED GREEN**, while the
     * five sibling tests on the other three sites all went RED with
     * `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY`. Its `UserRecordAccess` precondition passed in
     * the same run, so the persona genuinely had `HasEditAccess = false`; the DML succeeded anyway.
     *
     * WHAT THE GREEN RESULT DOES AND DOES NOT SETTLE. The five working tests all reach the write
     * through a real TRIGGER. This one calls `advance()` DIRECTLY from a test method, which is how
     * every other test in this class is written and is what the service header asks for.
     *
     * ⚠ RETRACTED 2026-08-21 (code review W3) — THIS BLOCK REPORTED AN AMBIGUOUS RESULT AS AN
     * UNAMBIGUOUS ONE, AND THAT IS WHY THE CHEAP EXPERIMENT WENT UNTRIED FOR A DAY. It concluded
     * "in that entry shape the `with sharing` declaration did not produce a record-level refusal"
     * and then argued the only repair was circular. A green mutation is consistent with TWO
     * readings and this block asserted the first:
     *   (a) BAD FALSIFIER — the direct call is the wrong entry shape and a better one would red;
     *   (b) NO REFUSAL HERE AT ALL — this site has no record-level refusal to reproduce in ANY
     *       non-trigger shape, in which case the escape at this site is unproven, full stop.
     * 🔴 AND THE CIRCULARITY ARGUMENT WAS ABOUT THE WRONG HOP. It read: "Routing through the real
     * trigger would mean flipping `Approval_Advance_Pending__c` INSIDE `System.runAs(approver)` so
     * the after-update handler enqueues — but that flip is itself a write to the very Disposition
     * the approver cannot edit, so it fails first ... Nothing short of an actual `Approval.process`
     * walk reproduces that." True of the TRIGGER hop and irrelevant to the ESCAPE. What the escape
     * depends on is ASYNC CONTEXT + APPROVER IDENTITY, and
     * `DispositionApprovalAdvanceQueueable` supplies both directly: it takes a plain `Set<Id>`, the
     * semaphore flip stays OUTSIDE `runAs` as admin exactly as it already is, and nothing is
     * circular.
     * ✅ THAT EXPERIMENT WAS RUN ON 2026-08-21 AND IT SETTLED THE QUESTION — AGAINST THE ESCAPE
     * BEING FALSIFIABLE HERE AT ALL, not in favour of reading (a) or (b). The async shape looked
     * green under a reverted mutation and then a `LastModifiedById` assertion showed WHY: 🔴
     * `Test.stopTest()` drains the queue as the TEST-RUNNING user, so `System.runAs` never reached
     * the queueable and the "async" run was the admin path in disguise. Full measurement in
     * queueableEntryShape_doesNotInheritRunAs_soItCannotFalsifyTheSharingEscape below. ⇒ Reading
     * (a) vs (b) above remains OPEN and is not decidable by any unit test in this class; the
     * escape rests on its own argument plus the three trigger-reached sites, as stated below.
     *
     * ⇒ WHAT THIS TEST IS WORTH: it pins the mapping, the stage move and the semaphore clear for a
     * non-admin principal, and it will still catch a regression that breaks the write for everyone.
     * It does NOT on its own prove the sharing escape. **Do not cite this test as evidence the D-1
     * path is sharing-safe, and do not delete `SemaphoreAdvanceWrites` on the strength of this test
     * still passing** — read the queueable test's own banner for what the re-run measured.
     *
     * ⚠ THE SEMAPHORE HALF IS THE SHARPER ASSERTION OF THE TWO. A refused write leaves
     * `Approval_Advance_Pending__c = true` — deliberately, per the class header — so the stuck-flag
     * assertion distinguishes "the write was refused" from "the mapping did not match", which the
     * stage assertion alone cannot.
     */
    @isTest
    static void nonOwnerApprover_advancesTheStageAndClearsTheSemaphore() {
        Disposition__c d = dispositionAt(
            TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        d.Approval_Advance_Pending__c = true;
        // SYSTEM_MODE — the field carries NO FLS for anyone by design (see its own field-meta and
        // the other tests in this class); only a workflow FieldUpdate or a SYSTEM_MODE write sets it.
        Database.update(d, AccessLevel.SYSTEM_MODE);
        User approver = TestDataFactory.createNonOwnerDispositionApprover('daa1');

        System.runAs(approver) {
            assertReadableButNotEditable(d.Id);
            Test.startTest();
            DispositionApprovalAdvanceService.advance(new Set<Id>{ d.Id });
            Test.stopTest();
        }

        Assert.areEqual(new List<String>(),
            DispositionApprovalAdvanceService.lastRunAdvanceFailures,
            '🔴 THE ADVANCE WAS REFUSED. This list carries the platform StatusCode — read it in the '
            + 'message above. INSUFFICIENT_ACCESS_OR_READONLY means the `without sharing` escape '
            + '(SemaphoreAdvanceWrites) has been removed; SYSTEM_MODE cannot satisfy a '
            + 'record-level check.');
        Disposition__c after = reread(d.Id);
        Assert.areEqual('BOV Outreach', after.Disposition_Stage__c,
            'An approver who can SEE but not EDIT the sale must still advance it. Still reading '
            + 'Disposition Readiness means the write was swallowed by allOrNone = false.');
        Assert.isFalse(after.Approval_Advance_Pending__c,
            'and the semaphore must be cleared by that same statement. Still true means the write '
            + 'never landed — which is the production symptom: an approval that completed, a sale '
            + 'that did not move, and a flag nobody can see on the page.');
    }

    /**
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * 🔴🔴 THE ASYNC ENTRY SHAPE IS **NOT REPRODUCIBLE** IN A UNIT TEST, AND THIS METHOD IS THE
     * MEASUREMENT THAT ESTABLISHED IT. ADDED 2026-08-21 (code review W3).
     * ══════════════════════════════════════════════════════════════════════════════════════════
     * WHY IT WAS WRITTEN. Production is NEITHER a direct call NOR a trigger — it is a QUEUEABLE
     * executing as the enqueuing user (the approver) after the approving transaction committed.
     * The sibling test above reproduces the IDENTITY and not the ASYNC CONTEXT, and its banner
     * used to conclude from a green mutation that the direct-call shape was simply a bad falsifier
     * — a conclusion equally consistent with "there is no record-level refusal at this site at
     * all". Review W3 correctly pointed out that `DispositionApprovalAdvanceQueueable` takes a
     * plain `Set<Id>`, that the semaphore flip already happens as admin OUTSIDE `runAs`, and that
     * the experiment was therefore ~3 lines and not circular. It was run. Here is what it found.
     *
     * ── 🔴 MEASURED 2026-08-21, TWO DRY-RUN VALIDATIONS AGAINST usman-dpeg ─────
     * 1. Enqueue + `Test.stopTest()` INSIDE `System.runAs(approver)`, `SemaphoreAdvanceWrites`
     *    MUTATED back to `with sharing` (the fix fully reverted): the stage moved, the semaphore
     *    cleared, `lastRunAdvanceFailures` was empty — **GREEN**, exactly as the direct call had
     *    been. On its face that reads as "the async shape does not falsify the escape either".
     * 2. 🔴 IT IS NOT WHAT HAPPENED. A `LastModifiedById` assertion added to that same mutated run
     *    FAILED: the row was stamped to the **test-running user**, not to `approver`.
     *    `Test.stopTest()` drains the queue in the context of the user running the TEST METHOD —
     *    `System.runAs` does not carry into the async execution. So run 1 never had a non-owner
     *    writing anything; it was the admin path wearing a `runAs` block.
     * ⇒ THE GREEN IN RUN 1 WAS VACUOUS, AND SO WAS THE PROPOSED EXPERIMENT. The async hop cannot
     *   be given the approver's identity from a unit test at all — which is a stronger and much
     *   more useful statement than the old banner's "the obvious repair is circular", because it
     *   is measured and it names the precise mechanism that defeats it.
     *
     * ── WHAT THIS METHOD IS NOW, AND WHY IT IS NOT DELETED ─────────────────────
     * It pins the PLATFORM BEHAVIOUR that makes the experiment impossible. If Salesforce ever
     * makes `Test.stopTest()` honour the enclosing `runAs`, this method goes RED, and the person
     * who reds it should immediately re-run the mutation described above — at that point the
     * sharing escape becomes directly falsifiable for the first time. Until then, this is the
     * documented dead end, kept so it is not rediscovered a third time.
     * ⚠ It also still exercises the real `DispositionApprovalAdvanceQueueable.execute` shell,
     * which nothing else in this class does.
     *
     * 🔴 WHAT THE ESCAPE AT THIS SITE STILL RESTS ON, UNCHANGED AND STATED PLAINLY: the argument
     * at `SemaphoreAdvanceWrites`, plus the MEASURED `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY`
     * failures at the three structurally identical trigger-reached sites. No test in this class
     * proves it, none can, and this method is now the evidence for why — not a substitute.
     * **Do not delete `SemaphoreAdvanceWrites` on the strength of any test here staying green.**
     */
    @isTest
    static void queueableEntryShape_doesNotInheritRunAs_soItCannotFalsifyTheSharingEscape() {
        Disposition__c d = dispositionAt(
            TestDataFactory.DISPOSITION_RT_ON_MARKET, 'Disposition Readiness');
        d.Approval_Advance_Pending__c = true;
        // SYSTEM_MODE and OUTSIDE runAs, deliberately — this is the production
        // `Set_Approval_Advance_Pending` workflow field update's stand-in, which rides the
        // approval's own save and is not subject to the approver's record access.
        Database.update(d, AccessLevel.SYSTEM_MODE);
        Id testRunningUserId = UserInfo.getUserId();
        User approver = TestDataFactory.createNonOwnerDispositionApprover('daa2');

        System.runAs(approver) {
            assertReadableButNotEditable(d.Id);
            Test.startTest();
            System.enqueueJob(new DispositionApprovalAdvanceQueueable(new Set<Id>{ d.Id }));
            Test.stopTest();
        }

        // The job ran and did its work — the shell delegates to advance() correctly.
        Assert.areEqual(new List<String>(),
            DispositionApprovalAdvanceService.lastRunAdvanceFailures,
            'The queueable shell must delegate to advance() and complete. A non-empty list here is '
            + 'a real regression in the async path, independent of everything this method measures '
            + 'about identity.');
        Disposition__c after = reread(d.Id);
        Assert.areEqual('BOV Outreach', after.Disposition_Stage__c,
            'DispositionApprovalAdvanceQueueable.execute must produce the same stage move as a '
            + 'direct advance() call — this is the only coverage the shell has.');
        Assert.isFalse(after.Approval_Advance_Pending__c,
            'and the semaphore must be cleared by that same statement.');

        // 🔴 THE POINT OF THE METHOD. See the banner: this is the measured reason the async shape
        // is not a falsifier for the sharing escape.
        Id writerId = [
            SELECT LastModifiedById FROM Disposition__c WHERE Id = :d.Id WITH SYSTEM_MODE
        ].LastModifiedById;
        Assert.areNotEqual(approver.Id, writerId,
            '🔴 MEASURED 2026-08-21: Test.stopTest() does NOT drain the queue as the runAs user. '
            + 'If this now fails — i.e. the write IS stamped to the approver — the platform has '
            + 'changed and the async entry shape has become falsifiable. RE-RUN THE MUTATION: flip '
            + 'SemaphoreAdvanceWrites to `with sharing` and see whether this method reds. That '
            + 'would be the first direct proof the sharing escape is load-bearing.');
        Assert.areEqual(testRunningUserId, writerId,
            'and the writer is specifically the TEST-RUNNING user, which is what makes the '
            + 'enclosing System.runAs cosmetic for the async hop. Asserted as well as the '
            + 'areNotEqual above so that a third identity (a future execution-context change) '
            + 'cannot satisfy this method by accident.');
    }
}
