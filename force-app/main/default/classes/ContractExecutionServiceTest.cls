/**
 * Tests ContractExecutionService: executing the PSA stamps the parent
 * Opportunity (Day 0), creates exactly ONE Transaction (arming the existing
 * Day-0 task fan-out), and never duplicates on re-execution.
 *
 * ── 🔴 SINCE TRANCHE 3C (2026-08-09) handleExecution HAS TWO ARMS, AND THE TESTS BELOW ARE SPLIT
 *      ACCORDINGLY ────────────────────────────────────────────────────────────
 * `Contract_Review__c` gained an Acquisition_PSA / Disposition_PSA record-type pair, so one
 * `Executed` event now means two different things:
 *
 *   ACQUISITION  (Opportunity__c set)  -> stamp the Opportunity (Contract Signed, Day 0) + notify
 *   DISPOSITION  (Disposition__c set)  -> move Disposition__c.Disposition_Stage__c to 'Closing'
 *
 * ⚠ THE ACQUISITION TESTS MATTER MORE THAN THE DISPOSITION ONES, NOT LESS. The acquisition arm is
 * LIVE, DEPLOYED behaviour; the disposition arm is new. Every acquisition test in this class was
 * left byte-identical on purpose, and two of the new tests
 * (acquisitionExecutionLeavesUnrelatedDispositionsAlone, mixedChunkRunsBothArmsIndependently) exist
 * specifically to prove the new arm did not reach into the old one.
 *
 * ── 🔴 THE ONE THING THIS SUITE CANNOT REPRODUCE, STATED RATHER THAN IMPLIED ──
 * THE APPROVAL LOCK. `Disposition__c` is the entry object of three approval processes, all
 * `recordEditability = AdminOnly`, and the sharpest case is self-inflicted: `Closing_Approval`'s
 * entry criteria is `Disposition_Stage__c equals Closing`, which is exactly the value this arm
 * writes. NO TEST IN THIS REPO RUNS A LIVE APPROVAL, so ENTITY_IS_LOCKED is not reachable from
 * Apex here — the same honest limit `DispositionStageEntryService`'s header and
 * `OpportunityReviewServiceTest.loiRecordCreatesOnStageEntry` both record about themselves.
 * What IS pinned instead, and what a future "tidy-up" would break:
 *   - dispositionAlreadyAtClosingIsSkippedByTheNoChangeFilter — the no-change filter, measured on
 *     DML ROWS, which is the half that makes the locked case a genuine no-op rather than a
 *     swallowed error;
 *   - reExecutingADispositionPsaIsANoOp — its user-visible consequence (idempotency).
 * The `allOrNone = false` half is NOT test-provable here and is carried by the service header.
 */
@isTest
private class ContractExecutionServiceTest {

    /**
     * A deal legitimately parked at PSA, with its Contract Review.
     *
     * The LOI -> PSA hop crosses TWO stage gates: the signed-NDA gate (which covers PSA) and the
     * approved-LOI gate. Both are prepared here rather than at each call site because every test
     * in this class starts from this fixture — the deal is put into the state the real pipeline
     * would have left it in, not exempted from the rules.
     */
    private static Contract_Review__c dealAtPsa() {
        Opportunity o = TestDataFactory.createOpportunity(null, false);
        o.StageName = 'LOI';
        insert o;
        TestDataFactory.signPrimaryNda(o);
        TestDataFactory.placeApprovedLoi(o);
        // Entering PSA auto-creates the Contract Review + Primary_Contract__c stamp.
        o.StageName = 'PSA';
        update o;
        return [SELECT Id, Opportunity__c FROM Contract_Review__c WHERE Opportunity__c = :o.Id];
    }

    /** The stage every Disposition fixture starts at (TestDataFactory.createDispositions). */
    private static final String READINESS = 'Disposition Readiness';

    /**
     * A sell-side PSA parked on its own Disposition, with the two PARENT LOOKUPS read back before
     * the caller is allowed to proceed.
     *
     * 🔴 IT DELIBERATELY DOES **NOT** ASSERT RecordTypeId, AND THAT IS A DESIGN DECISION RATHER THAN
     * AN OMISSION — read this before "completing" it with a record-type check.
     * `handleExecution` branches on the parent LOOKUP, never on the record type. That is mandated by
     * `Contract_Review__c.Disposition__c`'s own field metadata ("this lookup, NOT the record type,
     * is the discriminator anything outside the record page should test") and it is the only
     * discriminator that works during the migration window, when every row still sits on Master.
     * So the lookups ARE this fixture's preconditions and the record type is not one.
     *
     * Asserting the record type here would make EVERY behaviour test in this section red on
     * post-deploy gate T-A1 — a record type assigned to no profile resolves a real Id and is
     * available to nobody, System Administrator included, so `TestDataFactory`'s deliberate
     * `isAvailable()` guard no-ops and the stamp is silently absent (D13 residual 1). That would
     * hide any real regression in the arm behind unrelated gate noise, and it would contradict the
     * discriminator the service actually uses.
     *
     * ⇒ THE RECORD-TYPE STAMP IS STILL PROVEN, JUST NOT HERE. `TestDataFactoryTest
     * .createDispositionContractReview_stampsDispositionRecordTypeAndParent` asserts it
     * UNCONDITIONALLY and is expected to be RED until T-A1 runs. One owner per fact.
     */
    private static Contract_Review__c salePsa(Id dispositionId) {
        Contract_Review__c cr =
            TestDataFactory.createDispositionContractReview(dispositionId, true);

        Contract_Review__c stored = [
            SELECT Id, RecordTypeId, Disposition__c, Opportunity__c, Negotiation_Status__c
            FROM Contract_Review__c WHERE Id = :cr.Id
        ];
        Assert.areEqual(dispositionId, stored.Disposition__c,
            'PRECONDITION FAILED: the sell-side fixture must carry the Disposition lookup — that '
            + 'lookup, not the record type, is what handleExecution branches on.');
        Assert.isNull(stored.Opportunity__c,
            'PRECONDITION FAILED: the sell-side fixture must carry NO Opportunity, or BOTH arms '
            + 'run and the two behaviours become indistinguishable.');
        return stored;
    }

    /** Executes a set of Contract Reviews in ONE update — the real trigger path. */
    private static void execute(List<Contract_Review__c> reviews) {
        for (Contract_Review__c cr : reviews) {
            cr.Negotiation_Status__c = 'Executed';
        }
        update reviews;
    }

    private static String stageOf(Id dispositionId) {
        return [
            SELECT Disposition_Stage__c FROM Disposition__c WHERE Id = :dispositionId
        ].Disposition_Stage__c;
    }

    @isTest
    static void executionStampsOppButOpensNoTransaction() {
        Contract_Review__c cr = dealAtPsa();
        cr.Contract_Value__c = 12000000;
        update cr;

        Test.startTest();
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Test.stopTest();

        Opportunity o = [
            SELECT StageName, Contract_Signed__c, Contract_Executed_Date__c, Deal_Status__c, Deal_Bucket__c
            FROM Opportunity WHERE Id = :cr.Opportunity__c
        ];
        // The deal stays at the coarse PSA stage; Deal_Status marks it executed.
        System.assertEquals('PSA', o.StageName, 'Deal stays at PSA on execution');
        System.assert(o.Contract_Signed__c, 'Contract Signed stamped');
        System.assertNotEquals(null, o.Contract_Executed_Date__c, 'Day 0 stamped');
        System.assertEquals('Contract Signed', o.Deal_Status__c, 'Deal status stamped');
        System.assertEquals('PSA', o.Deal_Bucket__c, 'Tracker bucket follows');

        // 🔴 EXECUTION NO LONGER OPENS THE TRANSACTION (moved 2026-08-05). The trigger point is now
        // the Opportunity entering 'About to Close'. Asserting ZERO here is what stops the creation
        // being quietly re-added to handleExecution, which would give a deal two creators racing on
        // the same idempotency read inside one transaction.
        System.assertEquals(0,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c],
            'Contract execution stamps and notifies, but must NOT open the Transaction');

        // Contract Review itself synced by the before-save flow.
        cr = [SELECT Stage__c, Execution_Date__c FROM Contract_Review__c WHERE Id = :cr.Id];
        System.assertEquals('Contract Execution', cr.Stage__c, 'CR stage synced');
        System.assertEquals(Date.today(), cr.Execution_Date__c, 'CR execution date stamped');
    }

    @isTest
    static void aboutToCloseOpensTheTransactionDatedFromDayZero() {
        Contract_Review__c cr = dealAtPsa();
        cr.Contract_Value__c = 12000000;
        update cr;
        cr.Negotiation_Status__c = 'Executed'; // stamps Day 0 on the Opportunity
        update cr;
        Opportunity signed = [
            SELECT Contract_Executed_Date__c FROM Opportunity WHERE Id = :cr.Opportunity__c
        ];

        Test.startTest();
        update new Opportunity(Id = cr.Opportunity__c, StageName = 'About to Close');
        Test.stopTest();

        List<Transaction__c> txns = [
            SELECT Status__c, Stage__c, Contract_Value__c, Contract_Executed_Date__c
            FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c
        ];
        System.assertEquals(1, txns.size(), 'Entering About to Close opens exactly one Transaction');
        System.assertEquals('Active', txns[0].Status__c, 'Transaction opens Active');
        System.assertEquals(12000000, txns[0].Contract_Value__c, 'Contract value carried over');
        // 🔴 Day 0 is the CONTRACT EXECUTION date, not the date the stage changed. Every one of the
        // ~75 checklist tasks is dated by offset from this field, so anchoring it to "now" would
        // silently shift every deadline on a deal that executed weeks before it closed.
        System.assertEquals(signed.Contract_Executed_Date__c.date(), txns[0].Contract_Executed_Date__c,
            'Day 0 comes from the contract execution date, not from today');
    }

    @isTest
    static void aboutToCloseWithoutAnExecutedContractFallsBackToToday() {
        // 'About to Close' is an explicit-target stage the deal driver can set directly
        // (StageAdvanceService.ALLOWED_EXPLICIT_TARGETS), so a deal CAN arrive here with no executed
        // contract and therefore no Day 0 to inherit. The checklist still has to be datable.
        Contract_Review__c cr = dealAtPsa();

        Test.startTest();
        update new Opportunity(Id = cr.Opportunity__c, StageName = 'About to Close');
        Test.stopTest();

        List<Transaction__c> txns = [
            SELECT Contract_Executed_Date__c FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c
        ];
        System.assertEquals(1, txns.size(), 'A Transaction opens even with no executed contract');
        System.assertEquals(Date.today(), txns[0].Contract_Executed_Date__c,
            'Day 0 falls back to today when the deal never had a contract execution date');
    }

    @isTest
    static void reEnteringAboutToCloseNeverDuplicatesTheTransaction() {
        Contract_Review__c cr = dealAtPsa();
        update new Opportunity(Id = cr.Opportunity__c, StageName = 'About to Close');

        // ⚠ DRIVES THE SERVICE DIRECTLY, and it has to. Re-entering the stage the natural way needs
        // a round trip out and back, which the No_Backward_Stage_Movement validation rule correctly
        // refuses ("A deal cannot be moved back to an earlier stage"). Passing a null oldMap is the
        // insert-context shape, so `justEntered` is true and the ONLY thing that can prevent a
        // second Transaction is the alreadyHandedOff idempotency read — which is exactly what this
        // test exists to pin. Same technique, and same reason, as LeadConvertServiceTest's
        // direct-invocation methods.
        List<Opportunity> opps = [
            SELECT Id, StageName FROM Opportunity WHERE Id = :cr.Opportunity__c
        ];

        Test.startTest();
        ContractExecutionService.openTransactionsOnAboutToClose(opps, null);
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c = :cr.Opportunity__c],
            'A second pass over a deal that already has a Transaction must not open another');
    }

    /**
     * Bulk-safety per .claude/rules/bulk-test-rule.md: 251 Contract Reviews
     * executed in one transaction (forces a second 200-record trigger batch).
     *
     * This test found TWO INDEPENDENT governor breaks in the execution cascade.
     * Do not shrink the record count, weaken the assertions, or inject
     * TaskFanoutService.taskDefsOverride to make it pass - it must run against
     * production-representative data (82 checklist defs) or it proves nothing.
     *
     * Both breaks are fixed; the numbers below are what was measured on
     * DPEG-Acq-5 before the fix, and are recorded so the next reader does not
     * have to re-derive them:
     *
     *  1. SOQL - handleExecution called the single-request GroupNotifier.send()
     *     wrapper 3x inside a loop over Opportunities. Each call re-entered the
     *     already-bulkified notify() and paid 3 fresh queries, so the cost was
     *     9 queries per Opportunity (measured: 90 for 10 Opportunities). Neither
     *     class was individually wrong - notify() is O(1) in queries (600
     *     notifications = 3 queries); the defect lived only in the seam between
     *     them, which is why a per-class review declared the code clean and was
     *     right. Fixed by batching into one notify() call.
     *
     *  2. DML - the Day-0 fan-out is 82 Tasks per Transaction and ran
     *     synchronously, so a 200-record trigger chunk attempted 16,400 Task
     *     rows against the 10,000 limit. Fixed by chunking it into an async
     *     Queueable chain (TaskFanoutQueueable).
     *
     * Which limit fired depended purely on scale, because the fan-out (line 74)
     * ran before the notification loop (line 77):
     *     N <= ~10      passes
     *     ~11 - ~90     Too many SOQL queries: 101   (notification loop)
     *     ~100          Apex CPU time limit exceeded (fan-out)
     *     >= ~120       Too many DML rows: 10001     (fan-out)
     * At the 251 this test uses, chunk 1 is 200 records, so DML broke FIRST -
     * the SOQL fix alone would never have made this test pass.
     *
     * The synchronous fan-out ceiling was ~116 Transactions per transaction
     * (10,000 rows / ~86 rows per deal). That is ARITHMETIC, NOT INEFFICIENCY:
     * no query tuning could move it, which is why the fan-out had to go async
     * rather than be optimised in place.
     */
    @isTest
    static void bulkExecution251ContractsHandsOffToTransactions() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);
        for (Opportunity o : opps) {
            o.StageName = 'LOI';
        }
        insert opps;

        // Same two gates dealAtPsa() prepares, in bulk. Each helper is a single DML statement for
        // the whole collection, so the fixture cost stays O(1) in statements and this test keeps
        // measuring the execution cascade rather than its own setup.
        TestDataFactory.signPrimaryNda(opps);
        TestDataFactory.placeApprovedLoi(opps);

        for (Opportunity o : opps) {
            o.StageName = 'PSA';
        }
        update opps; // auto-creates 251 Contract Reviews (+ Primary_Contract__c stamp)

        List<Contract_Review__c> reviews = [
            SELECT Id FROM Contract_Review__c WHERE Opportunity__c IN :opps
        ];
        System.assertEquals(251, reviews.size(), 'A Contract Review opens for every deal entering PSA');

        Test.startTest();
        // BOTH halves of the cascade at 251, because they now live on DIFFERENT triggers and each
        // carries one of the two governor breaks this test was written to catch:
        //   execution      -> the notification loop (the SOQL break)
        //   About to Close -> the Transaction insert + Day-0 fan-out (the DML break)
        // Driving only one of them would silently retire half the coverage.
        for (Contract_Review__c cr : reviews) {
            cr.Negotiation_Status__c = 'Executed';
        }
        update reviews;

        for (Opportunity o : opps) {
            o.StageName = 'About to Close';
        }
        update opps;
        Test.stopTest();

        System.assertEquals(251,
            [SELECT COUNT() FROM Transaction__c WHERE Opportunity__c IN :opps],
            'Every deal entering About to Close opens exactly one Transaction');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE DISPOSITION ARM (Tranche 3C, 2026-08-09)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE PRIMARY TEST FOR THE NEW ARM, AND IT IS DELIBERATELY AN ALL-DISPOSITION CHUNK — ZERO
     * OPPORTUNITY PARENTS. That shape is the falsifier for the single easiest way to build this
     * feature wrong.
     *
     * Before 3C, handleExecution opened with `if (executedOppIds.isEmpty()) { return; }`. Left
     * there, an all-disposition chunk — which is the ORDINARY case for a sale, since a sell-side
     * Contract Review has no Opportunity at all — returns before the disposition arm ever runs. The
     * feature would be completely dead while every acquisition test in this class stayed green. The
     * early return now lives inside the acquisition arm; this test is what holds it there.
     *
     * It also pins the "ADDITIVE, NOT DEFENSIVE" claim in the service header: no Transaction is
     * created and no Opportunity is stamped, not because anything guards against it, but because
     * Transaction creation moved to openTransactionsOnAboutToClose (keyed on an Opportunity stage a
     * sale can never reach) and the acquisition arm receives an empty set.
     */
    @isTest
    static void executedDispositionPsaMovesTheSaleToClosing() {
        Disposition__c sale =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        Assert.areEqual(READINESS, stageOf(sale.Id),
            'PRECONDITION: the fixture must start at Disposition Readiness');
        Contract_Review__c psa = salePsa(sale.Id);

        Test.startTest();
        execute(new List<Contract_Review__c>{ psa });
        Test.stopTest();

        Assert.areEqual('Closing', stageOf(sale.Id),
            'An executed sell-side PSA must move its Disposition to Closing. Still reading '
            + '"Disposition Readiness" means the disposition arm never ran — the most likely cause '
            + 'is the acquisition arm\'s `executedOppIds.isEmpty()` early return having been moved '
            + 'back to the top of handleExecution, where an all-disposition chunk (zero Opportunity '
            + 'parents, i.e. EVERY sale) returns before this arm is reached.');

        Assert.areEqual(0, [SELECT COUNT() FROM Transaction__c],
            'A sell-side PSA must never open a Transaction. ⚠ This passes because Transaction '
            + 'creation lives in openTransactionsOnAboutToClose and is keyed on '
            + 'Opportunity.StageName = About to Close — NOT because anything here guards against '
            + 'it. The branch is additive, not defensive; do not add a guard on the strength of '
            + 'this assertion.');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Opportunity WHERE Contract_Signed__c = true],
            'A sell-side PSA must stamp no Opportunity anywhere in the org');
    }

    /**
     * 🔴 THE REGRESSION GUARD ON LIVE, DEPLOYED BEHAVIOUR — the more important half of this
     * tranche. An executed ACQUISITION PSA must behave exactly as it did before the disposition arm
     * existed, AND must not reach sideways into a Disposition that has nothing to do with it.
     *
     * The unrelated Disposition is the point: it is created, left at Disposition Readiness, and
     * never linked to anything. If a future edit ever keys the disposition arm on something looser
     * than `cr.Disposition__c != null` — a record type, a describe, "any disposition on the
     * property" — this goes red.
     */
    @isTest
    static void acquisitionExecutionLeavesUnrelatedDispositionsAlone() {
        Disposition__c unrelated =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        Contract_Review__c cr = dealAtPsa();

        Test.startTest();
        execute(new List<Contract_Review__c>{ cr });
        Test.stopTest();

        Opportunity o = [
            SELECT Contract_Signed__c, Contract_Executed_Date__c, Deal_Status__c
            FROM Opportunity WHERE Id = :cr.Opportunity__c
        ];
        Assert.isTrue(o.Contract_Signed__c,
            'UNCHANGED BEHAVIOUR: an executed acquisition PSA still stamps Contract Signed');
        Assert.isNotNull(o.Contract_Executed_Date__c,
            'UNCHANGED BEHAVIOUR: Day 0 is still stamped, and openTransactionsOnAboutToClose still '
            + 'reads it back to date the 75-task checklist');
        Assert.areEqual('Contract Signed', o.Deal_Status__c,
            'UNCHANGED BEHAVIOUR: the deal status is still stamped');

        Assert.areEqual(READINESS, stageOf(unrelated.Id),
            'A Disposition with no link to the executed Contract Review must NOT be touched. A '
            + '"Closing" here means the disposition arm stopped keying on the Disposition__c '
            + 'LOOKUP — which is the discriminator the field metadata mandates and the only one '
            + 'that works during the migration window, when every row still sits on Master.');
    }

    /**
     * BOTH ARMS, ONE TRIGGER CHUNK, EACH HITTING ONLY ITS OWN RECORD.
     *
     * This is what the two independent `if`s in handleExecution buy — an `if/else` on the parent
     * lookup would still pass this, but an `if/else` on the RECORD TYPE would not, because during
     * the migration window both rows sit on Master and one of the two arms would be starved.
     */
    @isTest
    static void mixedChunkRunsBothArmsIndependently() {
        Disposition__c sale =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        Contract_Review__c salesidePsa = salePsa(sale.Id);
        Contract_Review__c buysidePsa = dealAtPsa();

        Test.startTest();
        execute(new List<Contract_Review__c>{ salesidePsa, buysidePsa });
        Test.stopTest();

        Assert.areEqual('Closing', stageOf(sale.Id),
            'The disposition arm must run even when the same chunk also carries acquisition rows');
        Assert.isTrue(
            [SELECT Contract_Signed__c FROM Opportunity WHERE Id = :buysidePsa.Opportunity__c]
                .Contract_Signed__c,
            'The acquisition arm must run even when the same chunk also carries disposition rows');
    }

    /**
     * 🔴 THE NO-CHANGE FILTER, AND IT IS THE HALF OF THE APPROVAL-LOCK DECISION THAT IS ACTUALLY
     * TESTABLE HERE.
     *
     * `Closing_Approval`'s entry criteria is `Disposition_Stage__c equals Closing` — the very value
     * this arm writes — and it declares `recordEditability = AdminOnly`. So a re-executed PSA on a
     * disposition already sitting at Closing-under-approval would fire a write that CHANGES NOTHING
     * and CAN ONLY FAIL with ENTITY_IS_LOCKED. `AccessLevel.SYSTEM_MODE` does NOT lift an approval
     * lock (measured twice in this repo: OpportunityReviewService's LOI back-stamp, and Tranche 2's
     * C1 finding), so the filter — not the access mode — is what makes that case a genuine no-op.
     * Same remedy shape as Tranche 2's `Flag_Changed` no-change Decision.
     *
     * ⚠ MEASURED ON DML ROWS, WHICH IS THE ONLY WAY THE SKIP IS OBSERVABLE. A skipped row and a
     * successful write leave the database in the identical state, so asserting the stage proves
     * nothing at all here. The two dispositions differ only in their starting stage:
     *   filter present -> 2 Contract Review rows + 1 Disposition row = 3
     *   filter removed -> 2 Contract Review rows + 2 Disposition rows = 4
     * Nothing else contributes: VERIFIED 2026-08-09 that NO record-triggered flow exists on
     * Disposition__c (the two rollup flows trigger on NDA__c and Wire__c), and DispositionTrigger
     * acts only on entry to the `NDA` stage. If that ever stops being true this number moves and
     * the message below says so.
     */
    @isTest
    static void dispositionAlreadyAtClosingIsSkippedByTheNoChangeFilter() {
        Id assetId = TestDataFactory.defaultPropertyAsset().Id;
        List<Disposition__c> sales = TestDataFactory.createDispositions(2, assetId, true);
        Disposition__c moving = sales[0];
        Disposition__c alreadyClosing = sales[1];
        update new Disposition__c(Id = alreadyClosing.Id, Disposition_Stage__c = 'Closing');

        List<Contract_Review__c> psas = new List<Contract_Review__c>{
            salePsa(moving.Id),
            salePsa(alreadyClosing.Id)
        };

        Test.startTest();
        Integer rowsBefore = Limits.getDmlRows();
        execute(psas);
        Integer rowsWritten = Limits.getDmlRows() - rowsBefore;
        Test.stopTest();

        Assert.areEqual('Closing', stageOf(moving.Id), 'The disposition at PSA still advances');
        Assert.areEqual('Closing', stageOf(alreadyClosing.Id), 'and the other one stays put');
        Assert.areEqual(3, rowsWritten,
            'Expected 2 Contract Review rows + exactly ONE Disposition row. A 4 means the '
            + 'no-change filter in advanceDispositionsToClosing was removed, so a disposition '
            + 'ALREADY at Closing is written again — which, while Closing_Approval holds the '
            + 'record locked (its entry criteria IS Disposition_Stage__c = Closing), can only '
            + 'produce a swallowed ENTITY_IS_LOCKED. SYSTEM_MODE does not lift an approval lock; '
            + 'the filter is what makes that case a real no-op. A different number altogether '
            + 'means new automation now writes on a Disposition stage change — re-derive the '
            + 'arithmetic in this method\'s header before adjusting this constant.');
    }

    /**
     * The user-visible consequence of the filter: re-executing is safe and convergent.
     *
     * ⚠ It drives the SERVICE DIRECTLY with a null oldMap, and it has to — the same technique and
     * the same reason as reEnteringAboutToCloseNeverDuplicatesTheTransaction. Coming back to
     * 'Executed' the natural way needs a round trip out and back, and a null oldMap is the
     * insert-context shape, so `justExecuted` is true and the ONLY thing that can prevent a second
     * write is the no-change filter — which is exactly what is under test.
     */
    @isTest
    static void reExecutingADispositionPsaIsANoOp() {
        Disposition__c sale =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        Contract_Review__c psa = salePsa(sale.Id);
        execute(new List<Contract_Review__c>{ psa });
        Assert.areEqual('Closing', stageOf(sale.Id), 'PRECONDITION: the first execution advanced it');

        List<Contract_Review__c> executed = [
            SELECT Id, Opportunity__c, Disposition__c, Negotiation_Status__c
            FROM Contract_Review__c WHERE Id = :psa.Id
        ];

        Test.startTest();
        ContractExecutionService.handleExecution(executed, null);
        Test.stopTest();

        Assert.areEqual('Closing', stageOf(sale.Id),
            'A second pass over an already-executed sell-side PSA must leave the sale at Closing '
            + 'and must not write it again');
    }

    /**
     * Bulk safety per .claude/rules/bulk-test-rule.md: 251 sell-side PSAs on 251 DISTINCT
     * dispositions, executed in one transaction (forces a second 200-record trigger batch).
     *
     * 🔴 THE PARENTS MUST BE DISTINCT, AND THAT IS THE WHOLE DESIGN OF THIS TEST. 251 Contract
     * Reviews sharing ONE disposition would collapse to a single selector row and a single-row
     * update — it would look like a bulk test and would prove nothing about either the query or the
     * write. Distinct parents are what make the ONE-query / ONE-bulk-update claim falsifiable: a
     * per-record selector call would blow the 100-SOQL limit at 251, and a per-record update would
     * blow the 150-statement limit.
     *
     * ⚠ The exemption in .claude/rules/bulk-test-rule.md does NOT apply here. handleExecution is
     * TRIGGER-DRIVEN, not a per-transaction-singleton @AuraEnabled call, so the literal 251 stands —
     * the same reasoning the design records for this method and the opposite of the one that
     * exempts RecordStageAdvanceService.
     */
    @isTest
    static void bulkExecution251DispositionPsasMoveEverySale() {
        Id assetId = TestDataFactory.defaultPropertyAsset().Id;
        List<Disposition__c> sales = TestDataFactory.createDispositions(251, assetId, true);

        // Built with doInsert = false so the 251 parents can be assigned in memory and committed in
        // ONE statement — the factory's own convention, and it keeps the fixture O(1) in DML so
        // this test keeps measuring the trigger cascade rather than its own setup.
        List<Contract_Review__c> psas = TestDataFactory.createContractReviews(
            251, null, TestDataFactory.CONTRACT_REVIEW_RT_DISPOSITION, false);
        for (Integer i = 0; i < 251; i++) {
            psas[i].Disposition__c = sales[i].Id;
        }
        insert psas;

        Test.startTest();
        execute(psas);
        Test.stopTest();

        Assert.areEqual(251,
            [SELECT COUNT() FROM Disposition__c WHERE Disposition_Stage__c = 'Closing'],
            'Every one of the 251 sales whose PSA executed must reach Closing. A number BELOW 251 '
            + 'with no exception means the arm is not bulk-safe across the two trigger chunks '
            + '(200 + 51); an exception means a SOQL or DML statement moved inside a loop.');
        Assert.areEqual(0, [SELECT COUNT() FROM Transaction__c],
            'and no sell-side PSA opens a Transaction, at any volume');
    }
}
