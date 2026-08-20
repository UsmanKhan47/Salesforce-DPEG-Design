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
        LOI__c primaryLoi = TestDataFactory.placeApprovedLoi(o);
        // Completed_LOI_Before_PSA (added 2026-08-12) reads the LOI's OWN Stage__c, which
        // placeApprovedLoi deliberately leaves at its factory-default 'Draft'. Drive it to
        // 'Signed' via the real production route (the c/loiMarkCompleted quick action) before
        // entering 'Under Contract (PSA)' — same fix as
        // StageAdvanceServiceTest.advanceMovesLoiToPsaAndPsaToClosedWon.
        // ⚠ 'Signed' since observation 5 (2026-08-14); this was 'Completed' until the acquisition
        // LOI sequence was renamed. It must stay in step with Completed_LOI_Before_PSA, the
        // validation rule this line exists to satisfy — that rule reads the LOI child's OWN
        // Stage__c by string (design collision C2) and is repointed in the same P3-D2 wave. If this
        // line and that rule ever disagree, EVERY deal in the org is blocked from entering
        // 'Under Contract (PSA)' and this fixture is where it shows up first.
        RecordStageAdvanceService.advanceTo(primaryLoi.Id, 'Signed');
        // Entering 'Under Contract (PSA)' auto-creates the Contract Review + Primary_Contract__c
        // stamp.
        o.StageName = 'Under Contract (PSA)';
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
        // The deal stays at the coarse 'Under Contract (PSA)' stage; Deal_Status marks it executed.
        System.assertEquals('Under Contract (PSA)', o.StageName,
            'Deal stays at Under Contract (PSA) on execution');
        System.assert(o.Contract_Signed__c, 'Contract Signed stamped');
        System.assertNotEquals(null, o.Contract_Executed_Date__c, 'Day 0 stamped');
        // 🔴 THIS IS THE DEAL-TRACKER BUCKET, NOT THE STAGE, AND IT MOVED FOR A SEPARATE REASON —
        // do not read it as one repoint. Deal_Bucket__c is a reporting-only formula with its OWN
        // vocabulary, which does NOT track StageName in general ('Closed Won' yields
        // 'Bought/Closed'). Phase 2 moved TWO strings on its one formula line: the ISPICKVAL INPUT
        // (the stage value — mandatory, or every migrated deal falls through to 'Interested
        // Deals' SILENTLY) and the OUTPUT LABEL (a deliberate choice, so the tracker does not show
        // a bucket called 'PSA' full of deals whose stage reads Under Contract (PSA)). This
        // assertion follows the OUTPUT, and it is the loud half of that second decision — the
        // Deal_Tracker_PSA list view's filter value is the silent half, and org-side reports
        // grouping on 'PSA' are not represented in this repo at all (post-deploy gate G8).
        System.assertEquals('Under Contract (PSA)', o.Deal_Bucket__c, 'Tracker bucket follows');

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

    /**
     * 🔴 FOUR NOTIFICATIONS PER EXECUTED ACQUISITION PSA, NOT THREE (FSD §23 gap #7,
     * tranche 2, 2026-08-16). `Acquisitions_Team` — the team that WORKED the deal — was the
     * only one not told it had executed.
     *
     * ⚠ THIS ASSERTS THE BATCH THAT WAS BUILT, NOT THE NOTIFICATIONS THAT WERE SENT, AND THE
     * DISTINCTION IS WHY THE SEAM EXISTS RATHER THAN BEING AN `Assert` ON
     * `GroupNotifier.sentCount`. Custom notifications cannot be queried in Apex, and
     * `sentCount` counts only SUCCESSFUL sends — which is zero in any test org, because
     * group MEMBERSHIP is not deployable metadata, so `Acquisitions_Team` and its three
     * siblings resolve to no users. A `sentCount` assertion would read `0` whether this
     * method built three notifications, four, or none, i.e. it would be VACUOUS and would
     * pass unchanged if gap #7 were reverted. `GroupNotifierTest` already pins the SEND
     * mechanism against a group with real members; this pins the RECIPIENT SET.
     *
     * ⚠ THE COUNT IS ASSERTED AS WELL AS THE MEMBERSHIP. Asserting only "Acquisitions_Team is
     * in there" would stay green if a future edit duplicated a recipient — which is not
     * cosmetic here, because each extra send costs ~6 ms of a 10 s synchronous CPU budget
     * (the arithmetic is in the class header).
     */
    @isTest
    static void executionNotifiesAcquisitionsAlongsideTheOriginalThree() {
        Contract_Review__c cr = dealAtPsa();

        Test.startTest();
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Test.stopTest();

        List<GroupNotifier.Request> built = ContractExecutionService.lastRunNotifications;
        Assert.areEqual(4, built.size(),
            'ONE executed acquisition PSA builds exactly four notifications - one per team. '
            + 'Three means gap #7 was reverted; five means a recipient was duplicated.');

        Set<String> groups = new Set<String>();
        for (GroupNotifier.Request r : built) {
            groups.add(r.recipientGroup);
            Assert.areEqual(cr.Opportunity__c, r.targetRecordId,
                'Every notification points at the deal, so the recipient can open it');
            Assert.isTrue(String.isNotBlank(r.title), 'and carries a title');
            Assert.isTrue(String.isNotBlank(r.body), 'and a body naming the deal');
        }
        Assert.areEqual(
            new Set<String>{ 'Transactions_Team', 'Investor_Relations', 'Due_Diligence', 'Acquisitions_Team' },
            groups,
            'The three original recipients are UNCHANGED and Acquisitions_Team is added. '
            + 'A missing original is a regression, not a rewrite.');
    }

    /**
     * A DISPOSITION PSA still notifies NOBODY. Gap #7 sits inside `stampOpportunities`, which
     * only the acquisition arm reaches, so the sell-side arm is untouched by construction —
     * exactly as the Offering shell is. Asserting it here is what stops a future "just move
     * the notify block up a level" refactor from telling the acquisitions team about a SALE.
     */
    @isTest
    static void anExecutedDispositionPsaBuildsNoAcquisitionNotifications() {
        ContractExecutionService.lastRunNotifications = new List<GroupNotifier.Request>();
        Disposition__c sale =
            TestDataFactory.createDisposition(TestDataFactory.defaultPropertyAsset().Id, true);
        Contract_Review__c psa = salePsa(sale.Id);

        Test.startTest();
        execute(new List<Contract_Review__c>{ psa });
        Test.stopTest();

        Assert.areEqual(0, ContractExecutionService.lastRunNotifications.size(),
            'The disposition arm builds no deal notifications at all - stampOpportunities, '
            + 'which owns them, is unreachable from a Contract Review with a null Opportunity__c');
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

        // Same gates dealAtPsa() prepares, in bulk. Each helper is a single DML statement for
        // the whole collection, so the fixture cost stays O(1) in statements and this test keeps
        // measuring the execution cascade rather than its own setup.
        TestDataFactory.signPrimaryNda(opps);
        List<LOI__c> primaryLois = TestDataFactory.placeApprovedLoi(opps);

        // Completed_LOI_Before_PSA (added 2026-08-12) reads each LOI's OWN Stage__c, which
        // placeApprovedLoi deliberately leaves at its factory-default 'Draft'. dealAtPsa() drives
        // this through the real production route (RecordStageAdvanceService.advanceTo) because it
        // is a single-record fixture, but that route is one DML statement PER CALL — looping it
        // 251 times here would blow the 150-DML-statement transaction limit before Test.startTest()
        // is even reached.
        // 🔴 RETRACTED 2026-08-20 (Tranche 2 code review W1): "LOI__c has no validation rules
        // (confirmed: no objects/LOI__c/validationRules folder)" is NO LONGER TRUE. LOI__c gained
        // four (Workstream A4): Final_Price_Required_Before_Executed, Counter_Price_Is_Positive,
        // Closing_Period_Days_Not_Negative, Due_Diligence_Days_Not_Negative. The bulk write below
        // still passes ALL four — it only writes Stage__c = 'Signed' (not 'Executed', and it never
        // touches Counter_Price__c / Closing_Period_Days__c / Due_Diligence_Days__c, which the other
        // three rules key on) — so the fixture itself needs no change. But the SAFETY ARGUMENT that
        // justified skipping the real service route is gone: the next LOI validation rule added to
        // this object could silently break this 251-row bulk write with no warning here. Re-check
        // this block against objects/LOI__c/validationRules/ before trusting it again.
        List<LOI__c> completedLois = new List<LOI__c>();
        for (LOI__c primaryLoi : primaryLois) {
            completedLois.add(new LOI__c(Id = primaryLoi.Id, Stage__c = 'Signed'));
        }
        update completedLois;

        for (Opportunity o : opps) {
            o.StageName = 'Under Contract (PSA)';
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
        TestDataFactory.signBuyerNdaOn(sale.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
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
        TestDataFactory.signBuyerNdaOn(sale.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
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
        // All_NDAs_Signed_Before_Progression now gates On_Market too — both the update below and
        // execute(psas) inside Test.startTest change Disposition_Stage__c, so both sales need a
        // signed buyer NDA. One bulk insert, before Test.startTest, so it never touches the
        // rowsWritten measurement this test is built around.
        TestDataFactory.signBuyerNdasOn(sales);
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
        TestDataFactory.signBuyerNdaOn(sale.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
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
        // All_NDAs_Signed_Before_Progression now gates On_Market too (2026-08-19 flow redesign) —
        // one bulk insert for the whole 251, same O(1)-in-DML convention as the rest of this
        // fixture, so this test keeps measuring the execution cascade rather than its own setup.
        TestDataFactory.signBuyerNdasOn(sales);

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

    // ═════════════════════════════════════════════════════════════════════════
    // THE IR OFFERING SHELL (FSD Tranche 1, Item 1 — 2026-08-16)
    //
    // 🔴 THESE TESTS OWN THE **SEAM**, NOT THE SERVICE. `OfferingServiceTest` proves the service in
    // isolation (idempotency, the explicit Draft, the null IR_Owner__c, the 1-SOQL/1-DML budget).
    // What only this class can prove is that the call is wired into the real trigger cascade AND
    // that ACQUISITION-ONLY is structural — which is a property of WHERE the call sits
    // (`stampOpportunities`, whose Id set can only hold non-null Opportunity__c parents), not of
    // any guard inside the service. A disposition test in OfferingServiceTest would be meaningless
    // because the service is never handed a disposition.
    // ═════════════════════════════════════════════════════════════════════════

    private static List<Offering__c> offeringsFor(Id opportunityId) {
        return [
            SELECT Id, Opportunity__c, Status__c, IR_Owner__c
            FROM Offering__c WHERE Opportunity__c = :opportunityId
        ];
    }

    @isTest
    static void executingAnAcquisitionPsaOpensTheIrOfferingShell() {
        Contract_Review__c cr = dealAtPsa();
        Assert.areEqual(0, offeringsFor(cr.Opportunity__c).size(),
            'PRECONDITION: reaching PSA does not itself create an Offering — execution does');

        Test.startTest();
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Test.stopTest();

        List<Offering__c> shells = offeringsFor(cr.Opportunity__c);
        Assert.areEqual(1, shells.size(),
            'Executing the PSA opens exactly one Offering shell — before this, IR was notified at '
            + 'this exact moment and handed nothing to work from');
        Assert.areEqual('Draft', shells[0].Status__c, 'at Draft, set explicitly');
        Assert.isNull(shells[0].IR_Owner__c,
            'and with no IR owner named — IR_Owner__c is a User lookup while Investor_Relations is '
            + 'a public GROUP, so no owner is derivable. IR visibility is closed separately, by '
            + 'DPEG_IR_Edit / _View plus the Offering_IR_Visibility owner sharing rule');
    }

    @isTest
    static void reExecutingAnAcquisitionPsaNeverOpensASecondShell() {
        Contract_Review__c cr = dealAtPsa();
        cr.Negotiation_Status__c = 'Executed';
        update cr;
        Assert.areEqual(1, offeringsFor(cr.Opportunity__c).size(), 'PRECONDITION: one shell exists');

        Test.startTest();
        // Back out and re-execute — the real route a deal takes when Legal corrects a status.
        //
        // ═══ 🔴 CORRECTED 2026-08-17. THIS LINE WAS 'Ready for Execution' AND HAD BEEN RED SINCE
        // AT LEAST 2026-08-12 with INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST. The retracted comment
        // read, verbatim: "'Ready for Execution' is a real Negotiation_Status__c value (the
        // picklist is Draft / Negotiation / Signed / Ready for Execution / Initial Draft /
        // Revised / Executed); this must stay a value that actually exists."
        // Every word of that is still true OF THE FIELD, and that is precisely the mistake: it
        // checked the FIELD's value set and not the RECORD TYPE's. `dealAtPsa()` builds an
        // ACQUISITION deal, so its auto-created Contract Review is on Acquisition_PSA, which after
        // P3-D3 exposes only Draft / Negotiation / Signed / Executed. 'Ready for Execution' is a
        // DISPOSITION_PSA value.
        // 🔴 AND NOTE WHAT THE FAILURE ITSELF PROVES, because repo prose says the opposite in
        // several places: 'Ready for Execution' is ACTIVE on the field (verified in the org via
        // the describe — all seven values active, restrictedPicklist = true), so this rejection
        // cannot be field-level restriction. APEX DML DOES ENFORCE RECORD-TYPE-SCOPED PICKLIST
        // VALUES on a restricted picklist. Do not re-derive "record-type restriction is UI-only"
        // from any surviving comment; see RecordStageAdvanceServiceTest.
        // 'Signed' is the acquisition sequence's own immediate predecessor of 'Executed', so the
        // back-out is now BOTH legal and semantically the step Legal would actually take.
        // ═══════════════════════════════════════════════════════════════════════════════════════
        update new Contract_Review__c(Id = cr.Id, Negotiation_Status__c = 'Signed');
        update new Contract_Review__c(Id = cr.Id, Negotiation_Status__c = 'Executed');
        Test.stopTest();

        Assert.areEqual(1, offeringsFor(cr.Opportunity__c).size(),
            'A second execution must never mint a second shell. 🔴 This is the assertion a '
            + 'sharing-filtered guard read would INVERT rather than merely weaken: zero rows means '
            + '"no Offering exists", so the service would create a duplicate — see '
            + 'OfferingSelector.ExecutionHandoffReads');
    }

    /**
     * 🔴 ACQUISITION-ONLY, PROVED ON THE SHAPE THAT WOULD BREAK IT. A sell-side PSA carries
     * `Disposition__c` and a NULL `Opportunity__c`, so it never enters `executedOppIds` and never
     * reaches `OfferingService` at all. There is no record-type test and no guard anywhere — the
     * placement of the call IS the mechanism, and this test is what holds it there.
     */
    @isTest
    static void executingADispositionPsaOpensNoOfferingAtAll() {
        Disposition__c sale = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        Contract_Review__c psa = salePsa(sale.Id);

        Test.startTest();
        psa.Negotiation_Status__c = 'Executed';
        update psa;
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Offering__c],
            'An executed SALE must not mint an acquisition artifact. If this ever goes red, '
            + 'someone moved the OfferingService call out of stampOpportunities');
    }

    @isTest
    static void aMixedChunkOpensShellsOnlyForTheAcquisitionHalf() {
        Contract_Review__c buy = dealAtPsa();
        Disposition__c sale = TestDataFactory.createDisposition(
            TestDataFactory.defaultPropertyAsset().Id, true);
        TestDataFactory.signBuyerNdaOn(sale.Id); // All_NDAs_Signed_Before_Progression now gates On_Market too
        Contract_Review__c sell = salePsa(sale.Id);

        Test.startTest();
        execute(new List<Contract_Review__c>{
            new Contract_Review__c(Id = buy.Id),
            new Contract_Review__c(Id = sell.Id)
        });
        Test.stopTest();

        Assert.areEqual(1, offeringsFor(buy.Opportunity__c).size(),
            'The acquisition half gets its shell');
        Assert.areEqual(1, [SELECT COUNT() FROM Offering__c],
            'and the disposition half contributes none — one chunk, two arms, independently');
        Assert.areEqual('Closing', stageOf(sale.Id),
            'while the disposition arm still ran, so the two are genuinely independent rather '
            + 'than one having short-circuited the other');
    }

    /**
     * 251 acquisition PSAs executed in one transaction produce 251 Offerings.
     *
     * `.claude/rules/bulk-test-rule.md`, no exemption claimed: this is a real trigger path. The
     * budget claim being defended is `+1 SOQL / +1 DML per chunk, CONSTANT in deal count` — a
     * per-record selector call breaks the 100-query limit at this volume and a per-record insert
     * breaks the 150-statement limit, so a regression fails HERE with an exception rather than in
     * production on a real bulk close.
     *
     * ⚠ It deliberately does NOT also drive `About to Close`; that half is covered by
     * `bulkExecution251ContractsHandsOffToTransactions` and adding it here would make a failure
     * ambiguous between two cascades.
     */
    @isTest
    static void bulkExecution251AcquisitionPsasOpen251Offerings() {
        List<Opportunity> opps = TestDataFactory.createOpportunities(251, false);
        for (Opportunity o : opps) {
            o.StageName = 'LOI';
        }
        insert opps;

        TestDataFactory.signPrimaryNda(opps);
        List<LOI__c> primaryLois = TestDataFactory.placeApprovedLoi(opps);
        List<LOI__c> completedLois = new List<LOI__c>();
        for (LOI__c primaryLoi : primaryLois) {
            completedLois.add(new LOI__c(Id = primaryLoi.Id, Stage__c = 'Signed'));
        }
        update completedLois;

        for (Opportunity o : opps) {
            o.StageName = 'Under Contract (PSA)';
        }
        update opps; // auto-creates 251 Contract Reviews (+ Primary_Contract__c stamp)

        List<Contract_Review__c> reviews = [
            SELECT Id FROM Contract_Review__c WHERE Opportunity__c IN :opps
        ];
        Assert.areEqual(251, reviews.size(), 'PRECONDITION: a Contract Review per deal');

        Test.startTest();
        execute(reviews);
        Test.stopTest();

        Assert.areEqual(251, [SELECT COUNT() FROM Offering__c WHERE Opportunity__c IN :opps],
            'Every executed acquisition PSA opens exactly one Offering. A number BELOW 251 with no '
            + 'exception means the guard or the insert is not bulk-safe across the two trigger '
            + 'chunks (200 + 51); an exception means a SOQL or DML statement moved inside a loop.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // REGRESSION PINNING FOR THE `Executed_PSA_Before_Contract_Date` VALIDATION RULE
    // (FSD Tranche 1, Item 3 — the rule itself is admin metadata; these are its falsifiers)
    //
    // ⚠ THE TWO METHODS BELOW COVER THE RULE'S TWO STRUCTURAL HOLES AND THEY ARE DIFFERENT KINDS
    // OF TEST — do not read the second as a sibling of the first.
    //   aPsaExecutionOnADealWithABlankPrimaryContractStillExecutes
    //       a FALSIFIER for desired behaviour. The rule EXEMPTS a blank Primary_Contract__c, and
    //       this goes red if that exemption is ever removed.
    //   aPsaExecutionIsBlockedWhenPrimaryContractPointsAtADifferentUnexecutedReview  (2026-08-16)
    //       🔴 a PIN on a KNOWN LIMITATION accepted in review (W1). Nothing exempts a WRONG-ROW
    //       Primary_Contract__c, so the execution is refused and rolls back. It asserts what the
    //       code DOES, not what it should do, and it is EXPECTED TO GO RED if the hole is ever
    //       closed — its own header says what to do then.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE FALSIFIER FOR REMOVING `NOT(ISBLANK(Primary_Contract__c))` FROM THE RULE.
     *
     * `OpportunityReviewService` stamps `Primary_Contract__c` only for the Contract Review IT
     * creates on entry to `Under Contract (PSA)`. A Contract Review created any other way — by
     * hand, by a data load, on a deal that reached PSA by an unusual route — executes without ever
     * being the primary. Without the ISBLANK clause the rule then fires on
     * `stampOpportunities`'s `Database.update(oppUpdates, true, SYSTEM_MODE)` — and
     * `AccessLevel.SYSTEM_MODE` bypasses CRUD and FLS but **NOT validation rules** — so the
     * all-or-none update throws inside an after-update trigger and **THE ENTIRE PSA EXECUTION
     * ROLLS BACK**.
     *
     * ⚠ AND THE USER WOULD NEVER LEARN WHY: `stampOpportunities` has no catch, so the DmlException
     * propagates out of the trigger, and a user executing through the Advance Stage action hits
     * `RecordStageAdvanceController`, which converts EVERY exception into one fixed generic string.
     *
     * ⚠ THE COST IS STATED RATHER THAN HIDDEN: the rule is unenforceable on exactly these deals, so
     * it protects the ordinary path and fails OPEN on the irregular one. That is the correct trade
     * — a rolled-back PSA execution is worse than an unguarded manual date on an irregular deal —
     * but it is a decision, not an oversight.
     */
    @isTest
    static void aPsaExecutionOnADealWithABlankPrimaryContractStillExecutes() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        // A Contract Review created directly, NOT by the stage-entry auto-create — so nothing ever
        // stamps Primary_Contract__c on the deal.
        Contract_Review__c orphanPsa = TestDataFactory.createContractReviews(
            1, deal.Id, TestDataFactory.CONTRACT_REVIEW_RT_ACQUISITION, true)[0];
        Assert.isNull(
            [SELECT Primary_Contract__c FROM Opportunity WHERE Id = :deal.Id].Primary_Contract__c,
            'PRECONDITION: this deal has NO primary contract — the shape the rule must not block');

        Test.startTest();
        orphanPsa.Negotiation_Status__c = 'Executed';
        update orphanPsa;
        Test.stopTest();

        Opportunity after = [
            SELECT Contract_Signed__c, Contract_Executed_Date__c, Deal_Status__c
            FROM Opportunity WHERE Id = :deal.Id
        ];
        Assert.isTrue(after.Contract_Signed__c, 'The execution stands');
        Assert.isNotNull(after.Contract_Executed_Date__c,
            '🔴 and Day 0 is still stamped. If this goes red, the ISBLANK(Primary_Contract__c) '
            + 'clause was removed from Executed_PSA_Before_Contract_Date and every deal without a '
            + 'primary contract can no longer execute its PSA at all');
        Assert.areEqual(1, offeringsFor(deal.Id).size(),
            'and the Offering shell still opens, because the whole transaction survived');
    }

    /**
     * ═══════════════════════════════════════════════════════════════════════════════════════
     * 🔴 THIS PINS A **KNOWN LIMITATION**, NOT DESIRED BEHAVIOUR.
     *    Accepted in code review on 2026-08-16 (finding W1, "accept and document").
     *    🔴 IF A FUTURE CHANGE FIXES THE HOLE, **THIS TEST SHOULD GO RED** — and that inversion
     *    is the entire point of it existing. See "WHAT TO DO WHEN THIS GOES RED" at the bottom.
     * ═══════════════════════════════════════════════════════════════════════════════════════
     *
     * ── THE SECOND STRUCTURAL HOLE IN `Executed_PSA_Before_Contract_Date` ──
     * `aPsaExecutionOnADealWithABlankPrimaryContractStillExecutes` (directly above) covers the
     * hole the rule DOES exempt: a **BLANK** `Primary_Contract__c`. This is the other one, and
     * nothing exempts it — a **WRONG-ROW** `Primary_Contract__c`.
     *
     * The mismatch is in the code, not in the fixture. `handleExecution` collects
     * `cr.Opportunity__c` for ANY Contract Review that just became `Executed`, while the rule tests
     * `Primary_Contract__r.Negotiation_Status__c` — i.e. the service asks "did SOME PSA on this deal
     * execute?" and the rule asks "did THE PRIMARY one execute?". Those are different questions the
     * moment a deal carries more than one Contract Review, which
     * `aPsaExecutionOnADealWithABlankPrimaryContractStillExecutes` already establishes is a real
     * shape (hand-created, data-loaded, or a deal that reached PSA by an unusual route).
     *
     * So on the shape below the rule fires on a deal whose PSA genuinely DID execute,
     * `stampOpportunities`'s `Database.update(oppUpdates, true, AccessLevel.SYSTEM_MODE)` throws
     * inside a `Contract_Review__c` AFTER-UPDATE trigger — `AccessLevel.SYSTEM_MODE` bypasses CRUD
     * and FLS but **NOT validation rules** — and **THE WHOLE PSA EXECUTION ROLLS BACK**: the
     * `Executed` status, `Contract_Signed__c`, Day 0, the three notifications and the Offering
     * shell. And the user learns nothing: `stampOpportunities` has no catch, so the exception
     * propagates out of the trigger, and a user driving this through the Advance Stage action hits
     * `RecordStageAdvanceController`, which converts EVERY exception into one fixed generic string.
     *
     * ── WHY THIS IS ACCEPTED RATHER THAN FIXED (the decision, so nobody re-litigates it here) ──
     * Narrowing the rule is not cleanly possible: a validation rule cannot aggregate child records,
     * and there is no "has an executed PSA" rollup on `Opportunity` to test instead
     * (`Contract_Review__c.Opportunity__c` is a Lookup, so no roll-up summary field exists).
     * Closing it properly means adding that rollup and re-pointing the rule, which is its own
     * design pass — the same disposition as the `Transaction__c` companion rule the VR's own XML
     * comment defers. The matching paragraph is being added to that comment in parallel.
     *
     * ── WHY THE ASSERTIONS ARE SHAPED THE WAY THEY ARE ──
     * ⚠ A test asserting the execution SUCCEEDS would be red, and a red test cannot ship. This
     * therefore asserts the ACTUAL behaviour. It also deliberately does NOT assert the exception's
     * TYPE or its MESSAGE TEXT: the refusal reaches this caller through a trigger, so its wrapping
     * is a platform property, and its wording belongs to a metadata file this test does not own
     * (a reworded `errorMessage` must not turn this red for the wrong reason). What is asserted is
     * the shape that is true however the platform surfaces it — the DML is refused, and NOTHING the
     * execution should have done actually happened. The captured type and message are carried into
     * the failure messages so a red run is diagnosable without a rerun.
     *
     * ── 🔴 WHAT TO DO WHEN THIS GOES RED ──
     * A red here means one of two things, and they need opposite responses:
     *   1. THE HOLE WAS CLOSED — an executed-PSA rollup was added and the rule re-pointed at it, or
     *      `handleExecution`/`stampOpportunities` was re-keyed on the PRIMARY contract. Then this
     *      test must be REWRITTEN to assert the execution SUCCEEDS (Contract Signed, Day 0, one
     *      Offering) and renamed accordingly. Do not delete it — it becomes the regression pin for
     *      the fix.
     *   2. THE RULE WAS WEAKENED OR DEACTIVATED for an unrelated reason. Then the hole is gone by
     *      accident and `aPsaExecutionOnADealWithABlankPrimaryContractStillExecutes` is the test to
     *      read next, because the two share the rule.
     * Either way, do NOT "repair" this by loosening the assertions.
     */
    @isTest
    static void aPsaExecutionIsBlockedWhenPrimaryContractPointsAtADifferentUnexecutedReview() {
        // CR#1 — created by the stage-entry auto-create, so IT is the deal's Primary_Contract__c,
        // and it is left UN-EXECUTED.
        Contract_Review__c primary = dealAtPsa();
        Id dealId = primary.Opportunity__c;

        Opportunity before = [
            SELECT Primary_Contract__c, Contract_Signed__c, Contract_Executed_Date__c
            FROM Opportunity WHERE Id = :dealId
        ];
        Assert.areEqual(primary.Id, before.Primary_Contract__c,
            'PRECONDITION: entry to Under Contract (PSA) must have stamped CR#1 as the primary — '
            + 'without that this reproduces the BLANK-primary case, which the rule already exempts '
            + 'and which the test above already owns');
        Assert.isNull(before.Contract_Executed_Date__c,
            'PRECONDITION: Day 0 must be unset, or stampOpportunities never assigns it and '
            + 'ISCHANGED(Contract_Executed_Date__c) is false — the rule would then not fire at all '
            + 'and this test would prove nothing');
        Assert.areNotEqual('Executed',
            [SELECT Negotiation_Status__c FROM Contract_Review__c WHERE Id = :primary.Id]
                .Negotiation_Status__c,
            'PRECONDITION: the PRIMARY contract review must NOT be executed — it is the wrong-row '
            + 'value the rule reads through Primary_Contract__r');

        // CR#2 — a second Contract Review on the SAME deal, created by hand exactly as a data load
        // or an unusual route would. It never becomes the primary.
        Contract_Review__c second = TestDataFactory.createContractReviews(
            1, dealId, TestDataFactory.CONTRACT_REVIEW_RT_ACQUISITION, true)[0];
        Assert.areEqual(primary.Id,
            [SELECT Primary_Contract__c FROM Opportunity WHERE Id = :dealId].Primary_Contract__c,
            'PRECONDITION: creating a second Contract Review must NOT re-stamp Primary_Contract__c '
            + '— OpportunityReviewService stamps it only for the review IT creates on stage entry. '
            + 'If this ever changes, the wrong-row shape stops being reachable this way and this '
            + 'test needs a different fixture, not a deletion');

        Exception thrown = null;
        Test.startTest();
        try {
            update new Contract_Review__c(Id = second.Id, Negotiation_Status__c = 'Executed');
        } catch (Exception e) {
            thrown = e;
        }
        Test.stopTest();

        String observed = (thrown == null)
            ? '(no exception was thrown)'
            : thrown.getTypeName() + ' | ' + thrown.getMessage();

        Assert.isNotNull(thrown,
            '🔴 KNOWN LIMITATION (accepted 2026-08-16, review W1): executing a NON-PRIMARY Contract '
            + 'Review on a deal whose Primary_Contract__c points at a DIFFERENT, un-executed review '
            + 'is currently REFUSED, because Executed_PSA_Before_Contract_Date reads the primary '
            + 'while ContractExecutionService keys on any executed review. A pass here means the '
            + 'refusal is gone — read this method\'s "WHAT TO DO WHEN THIS GOES RED" block before '
            + 'changing anything: if the hole was closed on purpose, REWRITE this test to assert '
            + 'success, do not delete it.');

        // The whole statement — and everything its triggers did — rolled back together.
        Opportunity after = [
            SELECT Contract_Signed__c, Contract_Executed_Date__c, Deal_Status__c
            FROM Opportunity WHERE Id = :dealId
        ];
        Assert.isFalse(after.Contract_Signed__c,
            'The refusal takes the ENTIRE execution with it, not just the date: Contract Signed is '
            + 'not stamped. Observed refusal: ' + observed);
        Assert.isNull(after.Contract_Executed_Date__c,
            'and Day 0 is not stamped, so a Transaction opened later would date its ~75-task '
            + 'checklist from today instead. Observed refusal: ' + observed);
        Assert.areNotEqual('Contract Signed', after.Deal_Status__c,
            'and the deal status is not advanced either. Observed refusal: ' + observed);
        Assert.areNotEqual('Executed',
            [SELECT Negotiation_Status__c FROM Contract_Review__c WHERE Id = :second.Id]
                .Negotiation_Status__c,
            '🔴 and the LEGAL STATE is lost too — the Contract Review does not even record that it '
            + 'was executed, because the failing Opportunity update rolls back the very DML that '
            + 'set it. That is what makes this a limitation worth pinning rather than a cosmetic '
            + 'one. Observed refusal: ' + observed);
        Assert.areEqual(0, offeringsFor(dealId).size(),
            'and no Offering shell opens, since the whole transaction was rolled back');
    }
}
