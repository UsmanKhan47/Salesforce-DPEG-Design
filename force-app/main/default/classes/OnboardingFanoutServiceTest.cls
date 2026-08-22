/**
 * Tests OnboardingFanoutService + OnboardingFanoutQueueable — the PM onboarding checklist
 * fan-out and its idempotency guard.
 *
 * ═══ ⚠ THREE TESTING FACTS THAT SHAPE EVERY METHOD BELOW ═══
 *
 * 1. THE CMDT IS INJECTED, NEVER READ FROM THE ORG. `Onboarding_Task_Def__mdt` rows cannot be
 *    inserted in a test, and the 45 real rows are loaded asynchronously by
 *    `scripts/load-onboarding-task-defs.apex` rather than deployed (the customMetadata
 *    directory glob is force-ignored). A test that read the org's rows would assert a
 *    different number in every org and would red in a fresh scratch org for reasons having
 *    nothing to do with this class. Every test here sets
 *    `OnboardingFanoutService.taskDefsOverride` from `TestDataFactory.buildOnboardingTaskDefs`,
 *    which is exactly what `TaskFanoutServiceTest` does one module over.
 *
 * 2. CHAINED QUEUEABLE JOBS DO NOT EXECUTE IN TEST CONTEXT. `ChainFinalizer` returns early
 *    under `Test.isRunningTest()`. So the bulk test asserts (a) that the work was ENQUEUED and
 *    (b) that ONE chunk's checklist content is correct — it does NOT assert 251 x N Tasks,
 *    because that assertion could never fire and a test that cannot fail is worse than no
 *    test. This is stated here rather than discovered later.
 *
 * 3. THE FLOW IS ACTIVE, SO FIXTURES MUST OPT IN. `Onboarding_Task_Fanout` fires on any
 *    Onboarding with a non-null `Start_Date__c` and `Tasks_Fanned_Out__c = false`.
 *    `TestDataFactory.createOnboardings` ships the flag TRUE precisely so the rest of the suite
 *    is immune; the tests here that want a fan-out clear it explicitly, and the tests that
 *    invoke the service DIRECTLY leave it true and use the `bypassDedupe` seam so the flow
 *    cannot race the call being measured.
 *
 * 4. THE CHUNK'S BUDGET IS 2 SOQL / 3 DML, AND IT IS CONSTANT BY CONSTRUCTION, NOT BY LUCK.
 *    `TaskRollupTrigger` routes `Onboarding__c` (added 2026-08-22), so the chunk's single
 *    bulk Task insert would otherwise fire `TaskRollupTriggerHandler` once per 200-row
 *    trigger batch — 23 firings, 23 SOQL and 23 DML, at the production definition count of
 *    45. `fanOutNow` suppresses that cascade and recomputes once per chunk instead. The
 *    budget assertions in `bulk251Onboardings_enqueuesOnceAndBuildsExactlyOneChunk` name
 *    that cascade explicitly so a reader is never told "constant" without being told what
 *    the constant is protecting against.
 *
 * `.claude/rules/bulk-test-rule.md` applies at 251 and is met by
 * `bulk251Onboardings_enqueuesOnceAndBuildsExactlyOneChunk` and
 * `bulk251AlreadyFlagged_createsNothing`.
 */
@isTest
private class OnboardingFanoutServiceTest {

    /** .claude/rules/bulk-test-rule.md — 251 forces a SECOND trigger/flow batch. */
    private static final Integer BULK_N = 251;

    /** Small enough to keep fixtures readable, large enough to prove ordering and mapping. */
    private static final Integer DEF_COUNT = 5;

    /**
     * The REAL number of `Onboarding_Task_Def__mdt` rows in production, loaded by
     * `scripts/load-onboarding-task-defs.apex`. The tests inject DEF_COUNT (5) for
     * readability, so every production-scale claim below must be computed from THIS
     * number instead — otherwise the sizing proofs describe the fixture, not the org.
     */
    private static final Integer PROD_DEF_COUNT = 45;

    /**
     * The platform's trigger batch size. A DML statement touching N rows fires each after-
     * context ceil(N / 200) times — which is the entire reason the onboarding rollup cascade
     * was expensive, and the reason `.claude/rules/bulk-test-rule.md` mandates 251 rather
     * than 200. Named rather than inlined so the arithmetic below is legible.
     */
    private static final Integer TRIGGER_BATCH_SIZE = 200;

    private static void injectDefs(Integer count) {
        OnboardingFanoutService.taskDefsOverride = TestDataFactory.buildOnboardingTaskDefs(count);
    }

    /** An Onboarding that the ACTIVE flow will pick up (flag cleared). */
    private static Onboarding__c fanOutReadyOnboarding(Date startDate) {
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Tasks_Fanned_Out__c = false;
        o.Start_Date__c = startDate;
        insert o;
        return o;
    }

    /** An Onboarding the flow will IGNORE, for tests that invoke the service directly. */
    private static Onboarding__c inertOnboarding(Date startDate) {
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Tasks_Fanned_Out__c = true; // flow start filter requires false
        o.Start_Date__c = startDate;
        insert o;
        return o;
    }

    /**
     * An Onboarding that is genuinely UNFLAGGED — so the real idempotency guard, not the
     * `bypassDedupe` seam, is what the test exercises — but which the Flow still ignores.
     *
     * ⚠ THE FLOW IS SUPPRESSED VIA THE *OTHER* START FILTER (`Start_Date__c IsNull false`),
     * because the flag one is the very thing under test. Clearing the flag on an already-saved
     * record would make it newly MEET the criteria and fire the flow, whose job then runs at
     * `Test.stopTest()` and adds a second, unaccounted invocation to every counter asserted.
     * Due dates are null here, which is irrelevant to a guard test and is covered separately.
     */
    private static Onboarding__c unflaggedFlowInertOnboarding() {
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Tasks_Fanned_Out__c = false;
        o.Start_Date__c = null;
        insert o;
        return o;
    }

    private static List<Task> checklistFor(Id onboardingId) {
        return [
            SELECT Subject, Onboarding_Category__c, Task_Sequence__c, Task_Owner_Label__c,
                   Source_System__c, Onboarding_Status__c, Status, ActivityDate, OwnerId,
                   WhatId, Conditional__c
            FROM Task
            WHERE Onboarding__c = :onboardingId
            ORDER BY Task_Sequence__c
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // CHECKLIST CONTENT — every mapped field, read back
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * The core assertion: one Task per definition row, every field mapped, due dates offset
     * from the Onboarding's own Start Date. Read back from the database — the in-memory list
     * the service built is not evidence, and the insert is SYSTEM_MODE so a silent FLS drop
     * would not surface any other way.
     */
    @isTest
    static void fanOutNowBuildsOneTaskPerDefinitionWithEveryValueMapped() {
        injectDefs(DEF_COUNT);
        // A start date that is NOT today, so an offset assertion cannot pass against a
        // hardcoded Date.today() by accident.
        Date start = Date.today().addDays(15);
        Onboarding__c o = inertOnboarding(start);
        OnboardingFanoutService.bypassDedupe = true;

        Test.startTest();
        OnboardingFanoutService.fanOutNow(new List<Id>{ o.Id });
        Test.stopTest();

        List<Task> checklist = checklistFor(o.Id);
        Assert.areEqual(DEF_COUNT, checklist.size(), 'One Task per definition row');

        for (Integer i = 0; i < DEF_COUNT; i++) {
            Task t = checklist[i];
            Assert.areEqual('Test checklist item ' + i, t.Subject, 'Subject carries from the definition');
            Assert.areEqual(i + 1, t.Task_Sequence__c, 'Sequence carries and drives the order');
            Assert.areEqual('Isha Patel', t.Task_Owner_Label__c, 'Owner label carries');
            Assert.areEqual('Not Started', t.Onboarding_Status__c,
                'Default_Status__c drives Onboarding_Status__c');
            Assert.areEqual('Open', t.Status,
                'Task.Status is the PLATFORM open/closed flag and is always Open on creation — a '
                + 'different axis from Onboarding_Status__c, per the seed script convention');
            Assert.areEqual(start.addDays(i), t.ActivityDate,
                'Due date is the Onboarding Start Date plus the definition offset, NOT today');
            Assert.areEqual(UserInfo.getUserId(), t.OwnerId,
                'Tasks inherit the Onboarding OwnerId — Onboarding_Lead__c is Text(120), not a '
                + 'User lookup, so it cannot be an owner');
            Assert.isNull(t.WhatId,
                '🔴 WhatId MUST stay null. The parent is the custom Onboarding__c lookup; using '
                + 'WhatId would put 45 checklist rows per property onto the Activity timeline');
            Assert.isFalse(t.Conditional__c, 'No onboarding category is conditional today');
            Assert.isNotNull(t.Onboarding_Category__c, 'Category carries from the definition');
            Assert.isNotNull(t.Source_System__c, 'Source system carries from the definition');
        }
    }

    /**
     * A blank `Default_Status__c` falls back to 'Not Started', and a null `Due_Day_Offset__c`
     * is read as 0 rather than nulling the due date. Both are restricted-picklist / null-safety
     * edges that a real CMDT row could hit and that no other test covers.
     */
    @isTest
    static void blankDefaultStatusAndNullOffsetFallBackSafely() {
        Date start = Date.today().addDays(5);
        OnboardingFanoutService.taskDefsOverride = new List<Onboarding_Task_Def__mdt>{
            new Onboarding_Task_Def__mdt(Category__c = 'Leasing', Sequence__c = 1,
                Subject__c = 'No status, no offset', Owner_Label__c = 'Isha Patel',
                Source_System__c = 'Salesforce', Default_Status__c = null, Due_Day_Offset__c = null,
                Conditional__c = null)
        };
        Onboarding__c o = inertOnboarding(start);
        OnboardingFanoutService.bypassDedupe = true;

        Test.startTest();
        OnboardingFanoutService.fanOutNow(new List<Id>{ o.Id });
        Test.stopTest();

        List<Task> checklist = checklistFor(o.Id);
        Assert.areEqual(1, checklist.size(), 'The row is still built');
        Assert.areEqual('Not Started', checklist[0].Onboarding_Status__c,
            'A blank Default_Status__c falls back to Not Started — a null there would fail the '
            + 'restricted picklist on Task.Onboarding_Status__c');
        Assert.areEqual(start, checklist[0].ActivityDate,
            'A null offset is read as 0 (due on the start date), not as a null due date');
        Assert.isFalse(checklist[0].Conditional__c, 'A null Conditional__c maps to false, not null');
    }

    /**
     * An Onboarding with NO Start Date gets its checklist with NULL due dates rather than dates
     * anchored on today. A wrong deadline is worse than an absent one, and the flow's start
     * filter means production never reaches this — but a direct Apex or Flow caller can.
     */
    @isTest
    static void aBlankStartDateProducesNullDueDatesRatherThanTodayAnchoredOnes() {
        injectDefs(2);
        Onboarding__c o = TestDataFactory.createOnboarding(null, false);
        o.Tasks_Fanned_Out__c = true;
        o.Start_Date__c = null;
        insert o;
        OnboardingFanoutService.bypassDedupe = true;

        Test.startTest();
        OnboardingFanoutService.fanOutNow(new List<Id>{ o.Id });
        Test.stopTest();

        for (Task t : checklistFor(o.Id)) {
            Assert.isNull(t.ActivityDate,
                'No Start Date means no derivable deadline — leave it blank rather than inventing '
                + 'one anchored on today');
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 IDEMPOTENCY — the property this whole feature turns on
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE GUARD. Running the fan-out twice creates the checklist ONCE. If this reds, the
     * feature is not merely broken — it is a machine that mints a fresh 45-item checklist on
     * every save, forever. This is the exact failure shape the `without sharing` inner class in
     * `OnboardingSelector` exists to prevent.
     */
    @isTest
    static void runningTheFanOutTwiceCreatesTheChecklistOnce() {
        injectDefs(DEF_COUNT);
        // Genuinely unflagged, so the FIRST run is what sets the marker and the SECOND run is
        // stopped by the real guard rather than by a test seam.
        Onboarding__c o = unflaggedFlowInertOnboarding();

        Test.startTest();
        OnboardingFanoutService.fanOutNow(new List<Id>{ o.Id });
        Integer afterFirst = checklistFor(o.Id).size();
        OnboardingFanoutService.fanOutNow(new List<Id>{ o.Id }); // the re-save
        Test.stopTest();

        Assert.areEqual(DEF_COUNT, afterFirst, 'Precondition: the first run really did build it');
        Assert.areEqual(DEF_COUNT, checklistFor(o.Id).size(),
            'The second run creates NOTHING — Tasks_Fanned_Out__c is the marker and it is set in '
            + 'the same transaction as the insert');
        Assert.areEqual(1, OnboardingFanoutService.runSkippedAlreadyFanned,
            'and the skip is counted, so "it did nothing" is distinguishable from "it never ran"');
        Assert.isTrue(
            [SELECT Tasks_Fanned_Out__c FROM Onboarding__c WHERE Id = :o.Id].Tasks_Fanned_Out__c,
            'The marker is persisted, not merely held in memory');
        Assert.areEqual(DEF_COUNT,
            [SELECT Tasks_Total__c FROM Onboarding__c WHERE Id = :o.Id].Tasks_Total__c,
            'and Tasks_Total__c reflects the checklist actually built');
    }

    /**
     * 🔴 AN EMPTY CMDT MUST NOT FLAG THE RECORD. In an org where the async loader has not
     * finished, flagging would permanently suppress the checklist for that property — the one
     * outcome strictly worse than doing nothing.
     */
    @isTest
    static void noDefinitionsMeansNoTasksAndCRITICALLY_noFlag() {
        OnboardingFanoutService.taskDefsOverride = new List<Onboarding_Task_Def__mdt>();
        Onboarding__c o = unflaggedFlowInertOnboarding();

        Test.startTest();
        OnboardingFanoutService.fanOutNow(new List<Id>{ o.Id });
        Test.stopTest();

        Assert.areEqual(0, checklistFor(o.Id).size(), 'No definitions, no Tasks');
        Assert.isFalse(
            [SELECT Tasks_Fanned_Out__c FROM Onboarding__c WHERE Id = :o.Id].Tasks_Fanned_Out__c,
            'and CRITICALLY the record is NOT flagged — flagging here would suppress the checklist '
            + 'forever once the CMDT loader finishes');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // THE INVOCABLE ENTRY POINT
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 ONE ENQUEUE FOR THE WHOLE BATCH, AND DUPLICATE IDS COLLAPSE. A per-record enqueue hits
     * the 50-jobs-per-transaction cap at 51 Onboardings, which is why the de-dupe happens
     * BEFORE the enqueue rather than inside the worker.
     */
    @isTest
    static void theInvocableDeDupesAndEnqueuesExactlyOneJobForTheWholeBatch() {
        injectDefs(DEF_COUNT);
        Onboarding__c a = inertOnboarding(Date.today());
        Onboarding__c b = inertOnboarding(Date.today());

        List<OnboardingFanoutService.InputDTO> requests = new List<OnboardingFanoutService.InputDTO>();
        for (Id oid : new List<Id>{ a.Id, b.Id, a.Id }) { // a repeated on purpose
            OnboardingFanoutService.InputDTO r = new OnboardingFanoutService.InputDTO();
            r.onboardingId = oid;
            requests.add(r);
        }
        OnboardingFanoutService.InputDTO empty = new OnboardingFanoutService.InputDTO();
        requests.add(empty);  // null id
        requests.add(null);   // null request

        Test.startTest();
        OnboardingFanoutService.fanOut(requests);
        Integer enqueued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(1, enqueued,
            'THREE ids (one repeated) plus two junk entries produce exactly ONE job. A per-record '
            + 'enqueue would be 5 and would cap out at 51 Onboardings in production');
    }

    /** Null, empty and all-junk inputs enqueue nothing and throw nothing. */
    @isTest
    static void theInvocableIsNullAndEmptySafeAndEnqueuesNothingForJunk() {
        Test.startTest();
        OnboardingFanoutService.fanOut(null);
        OnboardingFanoutService.fanOut(new List<OnboardingFanoutService.InputDTO>());
        OnboardingFanoutService.fanOut(new List<OnboardingFanoutService.InputDTO>{
            null, new OnboardingFanoutService.InputDTO()
        });
        Integer enqueued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(0, enqueued,
            'Nothing actionable means nothing enqueued — a Flow batch of records that all fail the '
            + 'start filter must not burn a job slot');
    }

    /** The synchronous worker is null/empty safe too. */
    @isTest
    static void fanOutNowIsNullAndEmptySafe() {
        injectDefs(DEF_COUNT);
        Test.startTest();
        OnboardingFanoutService.fanOutNow(null);
        OnboardingFanoutService.fanOutNow(new List<Id>());
        Test.stopTest();

        Assert.areEqual(0, OnboardingFanoutService.runTasksBuilt,
            'Nothing to do means nothing built — and no NullPointerException inside a queueable');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // THE QUEUEABLE
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * The job executes its chunk end-to-end, exercising the Queueable + Finalizer path rather
     * than only the synchronous worker the other tests call.
     */
    @isTest
    static void theQueueableExecutesItsChunkAndBuildsTheChecklist() {
        injectDefs(DEF_COUNT);
        Onboarding__c o = unflaggedFlowInertOnboarding();

        Test.startTest();
        System.enqueueJob(new OnboardingFanoutQueueable(new List<Id>{ o.Id }, 0));
        Test.stopTest(); // the job runs here

        Assert.areEqual(DEF_COUNT, checklistFor(o.Id).size(),
            'The queued job built the checklist — this is the path production actually takes');
    }

    /** Defensive constructor arguments do not throw. */
    @isTest
    static void theQueueableToleratesNullConstructorArguments() {
        Test.startTest();
        System.enqueueJob(new OnboardingFanoutQueueable(null, null));
        Test.stopTest();

        Assert.areEqual(0, OnboardingFanoutService.runTasksBuilt,
            'A job with no ids does nothing and does not throw');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════
    // 🔴 BULK — 251 Onboardings in ONE transaction
    // ═════════════════════════════════════════════════════════════════════════════════════

    /**
     * `.claude/rules/bulk-test-rule.md` at 251: 251 Onboardings inserted in ONE DML, which at
     * the production 45-definitions-per-checklist would be 11,295 Task rows.
     *
     * ⚠ WHAT THIS ASSERTS, AND WHY IT IS NOT "251 x N TASKS". `ChainFinalizer` does not chain
     * under `Test.isRunningTest()`, and it cannot: chained jobs never execute in test context,
     * so an assertion on all 251 checklists could never fire. This test therefore proves the
     * two things that ARE observable and that a governor break would falsify:
     *   (a) the synchronous insert transaction survives — the flow batches the 251 records and
     *       enqueues a bounded number of jobs, NOT one per record;
     *   (b) the first CHUNK_SIZE-bounded chunk builds correct checklists inside limits.
     *
     * 🔴 THE BUDGET ASSERTION IS THE HIGHER-VALUE HALF, and it reads counters captured INSIDE
     * the async context (`OnboardingFanoutService.runQueryCount`). Asserting
     * `Limits.getQueries()` after `Test.stopTest()` would be SILENTLY VACUOUS — stopTest
     * restores the pre-test counters.
     */
    @isTest
    static void bulk251Onboardings_enqueuesOnceAndBuildsExactlyOneChunk() {
        injectDefs(DEF_COUNT);
        // ⚠ THE FLOW IS SUPPRESSED (`Tasks_Fanned_Out__c = true` from the factory) AND
        // `fanOut()` IS CALLED DIRECTLY. Following the TaskFanoutServiceTest precedent
        // verbatim: driving through the record-triggered Flow would make the number of
        // enqueues depend on how Salesforce internally batches 251 records, which is not
        // verifiable from Apex. This test controls exactly ONE enqueue and is therefore
        // deterministic; `theFlowFiresTheFanOutOnInsert` proves the Flow wiring separately,
        // at one record, where the batching question does not arise.
        List<Onboarding__c> onboardings = TestDataFactory.createOnboardings(BULK_N, null, false);
        for (Onboarding__c o : onboardings) {
            o.Start_Date__c = Date.today();
        }
        insert onboardings;

        List<OnboardingFanoutService.InputDTO> requests = new List<OnboardingFanoutService.InputDTO>();
        for (Onboarding__c o : onboardings) {
            OnboardingFanoutService.InputDTO r = new OnboardingFanoutService.InputDTO();
            r.onboardingId = o.Id;
            requests.add(r);
        }
        Integer chunkSize = OnboardingFanoutQueueable.CHUNK_SIZE;

        OnboardingFanoutService.resetRunCounters();
        OnboardingFanoutService.bypassDedupe = true;
        Test.startTest();
        OnboardingFanoutService.fanOut(requests); // exactly ONE System.enqueueJob, whatever N is
        Integer jobsEnqueued = Limits.getQueueableJobs();
        Test.stopTest(); // runs the first chunk; the chain is blocked under Test.isRunningTest()
        OnboardingFanoutService.bypassDedupe = false;

        Assert.areEqual(1, jobsEnqueued,
            'ONE enqueue for 251 records. A per-record enqueue throws at the 50-job cap, which is '
            + 'the production break this assertion exists to catch');

        // Exactly ONE chunk ran, and it built COMPLETE checklists — proof the chain, not a
        // shortcut, is what finishes the rest in production.
        Assert.areEqual(chunkSize * DEF_COUNT, OnboardingFanoutService.runTasksBuilt,
            'Exactly CHUNK_SIZE Onboardings x the definition count are built by the single '
            + 'Queueable execution that runs synchronously at Test.stopTest()');
        Assert.areEqual(chunkSize * DEF_COUNT,
            [SELECT COUNT() FROM Task WHERE Onboarding__c IN :onboardings],
            'and the same number is actually in the database — read back, not inferred from the '
            + 'counter the service maintains about itself');

        // 🔴 SIZING PROOF — DML *ROWS*. At the PRODUCTION definition count of 45 this same
        // chunk is 4,500 Task rows, plus CHUNK_SIZE flag rows, plus CHUNK_SIZE rollup rows.
        // Asserted against the real limit so the chunk size cannot be raised without this
        // arithmetic being re-done.
        Integer prodTaskRows = chunkSize * PROD_DEF_COUNT;
        Assert.isTrue(prodTaskRows + (2 * chunkSize) <= 10000,
            'CHUNK_SIZE x the 45 production definitions, plus the flag update and the rollup '
            + 'update (CHUNK_SIZE rows each), must stay under the 10,000 DML-row limit — that '
            + 'sizing is the entire reason the fan-out is chunked rather than attempted at 251 '
            + 'synchronously (251 x 45 = 11,295 would blow it on Tasks alone). '
            + 'Actual at production scale: ' + (prodTaskRows + (2 * chunkSize)) + ' rows');

        // ═════════════════════════════════════════════════════════════════════════════════
        // 🔴 CONSTANT-COST PROOF, read from counters captured INSIDE the async context.
        // `Limits.getQueries()` after Test.stopTest() is restored to its pre-test value and
        // would make this silently vacuous.
        //
        // ⚠ THE NUMBERS BELOW ARE 2 AND 3, NOT 1 AND 2, AND THE DIFFERENCE IS A REAL CASCADE
        // THAT MUST NOT BE PAPERED OVER. `TaskRollupTrigger` routes `Onboarding__c` (added
        // 2026-08-22), so the chunk's single bulk Task insert fires
        // `TaskRollupTriggerHandler` once per 200-row trigger batch —
        // ceil(chunkSize x defs / 200) firings, each spending its own SOQL and DML. At the
        // PRODUCTION definition count that is 23 firings: 23 SOQL and 23 DML against limits of
        // 100 and 150, for counters the same statement is still creating.
        // `fanOutNow` therefore SUPPRESSES that cascade across its DML window and calls
        // `OnboardingTaskRollupService.recalc` ONCE for the chunk instead. What is left is
        // genuinely constant — the same 2 and 3 in this test at 5 definitions and in
        // production at 45.
        // ═════════════════════════════════════════════════════════════════════════════════
        Integer suppressedTriggerBatches =
            (Integer) Math.ceil((Decimal) (chunkSize * PROD_DEF_COUNT) / TRIGGER_BATCH_SIZE);

        Assert.areEqual(2, OnboardingFanoutService.runQueryCount,
            'CONSTANT 2 SOQL per chunk — one OnboardingSelector.selectByIdsForFanout, one '
            + 'TaskSelector.selectByOnboardingIds inside the single explicit rollup recalc. The '
            + 'CMDT read is getAll() and costs none. THIS IS THE SAME 2 IN PRODUCTION AT 45 '
            + 'DEFINITIONS: it does not scale with the record count or the definition count. If '
            + 'it reads ' + (1 + suppressedTriggerBatches) + ' instead, the TaskRollupTrigger '
            + 'onboarding cascade has been un-suppressed and is firing once per 200-row batch '
            + '(' + suppressedTriggerBatches + ' batches at production scale). If it grew some '
            + 'other way, a query moved into a per-record loop');
        Assert.areEqual(3, OnboardingFanoutService.runDmlCount,
            'CONSTANT 3 DML STATEMENTS per chunk: one flag update, one bulk Task insert, one '
            + 'rollup update. THIS IS THE SAME 3 IN PRODUCTION AT 45 DEFINITIONS. If it reads '
            + (2 + suppressedTriggerBatches) + ' instead, the trigger cascade is back');

        // 🔴 SIZING PROOF — SOQL AND DML *STATEMENT* COUNTS AT PRODUCTION SCALE. The row proof
        // above says nothing about statement counts, and the statement counts are what the
        // cascade actually threatened. Because the cost is constant, the production figure IS
        // the measured figure — which is exactly the property being pinned.
        Assert.isTrue(OnboardingFanoutService.runQueryCount + suppressedTriggerBatches <= 100,
            'Even if the suppression were removed tomorrow, the chunk would need '
            + (OnboardingFanoutService.runQueryCount + suppressedTriggerBatches) + ' SOQL at the '
            + 'production definition count against a limit of 100 — this is the headroom the '
            + 'suppression buys back, and raising CHUNK_SIZE or the definition count without '
            + 'redoing this arithmetic is what would spend it');
        Assert.isTrue(OnboardingFanoutService.runDmlCount + suppressedTriggerBatches <= 150,
            'and ' + (OnboardingFanoutService.runDmlCount + suppressedTriggerBatches)
            + ' DML statements against a limit of 150');
    }

    /**
     * 🔴 THE REGRESSION GUARD FOR THE SUPPRESSION ITSELF. Suppressing the trigger cascade
     * without replacing it would be a silent data defect, not a visible failure:
     * `fanOutNow` writes `Tasks_Total__c` and NOTHING ELSE, so a freshly fanned-out property
     * would read "45 total, 0 open, 0 not started, 0% complete" on the PM dashboard —
     * `OnboardingController` reads Tasks_Open__c, Tasks_Not_Started__c, Tasks_Due_7d__c and
     * Completion_Pct__c — until somebody happened to edit a Task and re-fire the trigger.
     *
     * So this asserts the ELEVEN counters `fanOutNow` does not write, read back from the
     * database. If someone deletes the explicit `recalc` call because "the trigger does it",
     * the constant-cost assertion above goes green and THIS one reds.
     */
    @isTest
    static void fanOutPopulatesEveryRollupCounter_notJustTasksTotal() {
        injectDefs(DEF_COUNT);
        // Due dates land on start + 0..4 days, i.e. today .. today+4 — all inside the
        // 7-day window and none overdue, which makes every counter below predictable.
        Onboarding__c o = inertOnboarding(Date.today());
        OnboardingFanoutService.bypassDedupe = true;

        Test.startTest();
        OnboardingFanoutService.fanOutNow(new List<Id>{ o.Id });
        Test.stopTest();
        OnboardingFanoutService.bypassDedupe = false;

        Onboarding__c after = [
            SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_In_Progress__c, Tasks_Not_Started__c,
                   Tasks_Blocked__c, Tasks_NA__c, Tasks_Open__c, Tasks_Overdue__c,
                   Tasks_Blocked_Now__c, Tasks_Stalled__c, Tasks_Due_7d__c, Completion_Pct__c
            FROM Onboarding__c WHERE Id = :o.Id
        ];
        Assert.areEqual(DEF_COUNT, after.Tasks_Total__c, 'Tasks_Total__c — the one fanOutNow writes itself');
        Assert.areEqual(DEF_COUNT, after.Tasks_Not_Started__c,
            '🔴 Tasks_Not_Started__c — fanOutNow does NOT write this. It can only be right if the '
            + 'rollup actually ran, so this is the assertion that fails if the explicit recalc is '
            + 'removed on the theory that the trigger still covers it');
        Assert.areEqual(DEF_COUNT, after.Tasks_Open__c, 'Tasks_Open__c — every new item is open');
        Assert.areEqual(DEF_COUNT, after.Tasks_Due_7d__c,
            'Tasks_Due_7d__c — offsets 0..4 all fall inside the 7-day window');
        Assert.areEqual(0, after.Tasks_Complete__c, 'Nothing is complete on creation');
        Assert.areEqual(0, after.Tasks_In_Progress__c, 'Nothing is in progress on creation');
        Assert.areEqual(0, after.Tasks_Blocked__c, 'Nothing is blocked on creation');
        Assert.areEqual(0, after.Tasks_Blocked_Now__c, 'Nothing is blocked on creation');
        Assert.areEqual(0, after.Tasks_NA__c, 'Nothing is N/A on creation');
        Assert.areEqual(0, after.Tasks_Overdue__c, 'Nothing is overdue — due dates are today onward');
        Assert.areEqual(0, after.Tasks_Stalled__c, 'Nothing is stalled on creation');
        Assert.areEqual(0, after.Completion_Pct__c, '0 of ' + DEF_COUNT + ' complete = 0%');
    }

    /**
     * 🔴 THE SUPPRESSION IS SCOPED TO THE FAN-OUT AND IS RESTORED. A leaked `true` would
     * disable every onboarding rollup for the rest of the transaction — invisible, because
     * nothing throws. This proves (a) the flag is false again on return and (b) an ORDINARY
     * Task write after a fan-out still rolls up through the trigger, which is the path
     * `TaskRollupTriggerHandlerTest` covers and that work item E existed to create.
     */
    @isTest
    static void theRollupSuppressionIsRestoredAndOrdinaryTaskWritesStillRollUp() {
        injectDefs(DEF_COUNT);
        Onboarding__c o = inertOnboarding(Date.today());
        OnboardingFanoutService.bypassDedupe = true;

        Test.startTest();
        OnboardingFanoutService.fanOutNow(new List<Id>{ o.Id });
        Assert.isFalse(OnboardingTaskRollupService.isTriggerRecalcSuppressed(),
            'fanOutNow restores the flag in a `finally` — a leak here silently disables every '
            + 'onboarding rollup for the remainder of the transaction');

        // An ordinary edit, exactly as the standard UI / API / Data Loader would make it.
        List<Task> checklist = checklistFor(o.Id);
        Task t = checklist[0];
        t.Onboarding_Status__c = 'Complete';
        update t; // must fire TaskRollupTrigger -> OnboardingTaskRollupService.recalc
        Test.stopTest();
        OnboardingFanoutService.bypassDedupe = false;

        Onboarding__c after = [
            SELECT Tasks_Complete__c, Tasks_Open__c, Completion_Pct__c
            FROM Onboarding__c WHERE Id = :o.Id
        ];
        Assert.areEqual(1, after.Tasks_Complete__c,
            'The trigger rollup is LIVE again after the fan-out — routing Onboarding__c into '
            + 'TaskRollupTrigger was the whole point of work item E, and the fan-out suppression '
            + 'must not regress it');
        Assert.areEqual(DEF_COUNT - 1, after.Tasks_Open__c, 'and the open count moved with it');
    }

    /**
     * The FLOW WIRING, proved end to end at ONE record: inserting an Onboarding that meets the
     * start filter results in a checklist, with no Apex call from the test at all. This is the
     * half the bulk test deliberately does not attempt, and without it every other test here
     * could pass while the flow was inactive or pointed at the wrong action.
     */
    @isTest
    static void theFlowFiresTheFanOutOnInsert() {
        injectDefs(DEF_COUNT);

        Test.startTest();
        Onboarding__c o = fanOutReadyOnboarding(Date.today());
        Test.stopTest(); // the flow's enqueued job runs here

        Assert.areEqual(DEF_COUNT, checklistFor(o.Id).size(),
            'Inserting an Onboarding with a Start Date and Tasks_Fanned_Out__c = false builds the '
            + 'checklist with no Apex call from this test — the Flow start filters and the '
            + 'invocable action name are both live');
        Assert.isTrue(
            [SELECT Tasks_Fanned_Out__c FROM Onboarding__c WHERE Id = :o.Id].Tasks_Fanned_Out__c,
            'and the record is flagged, so a later re-save cannot re-fire the flow');
    }

    /**
     * 251 Onboardings that are ALREADY flagged produce NOTHING — the guard holds in bulk, not
     * just for one record. This is the regression guard for the whole rest of the test suite:
     * `TestDataFactory` ships the flag true, so if the guard ever inverted, every fixture in
     * the repo would start minting checklists.
     */
    @isTest
    static void bulk251AlreadyFlagged_createsNothing() {
        injectDefs(DEF_COUNT);
        List<Onboarding__c> onboardings = TestDataFactory.createOnboardings(BULK_N, null, true);
        List<Id> ids = new List<Id>(new Map<Id, Onboarding__c>(onboardings).keySet());
        OnboardingFanoutService.resetRunCounters();

        Test.startTest();
        OnboardingFanoutService.fanOutNow(ids);
        Test.stopTest();

        Assert.areEqual(0, OnboardingFanoutService.runTasksBuilt,
            'Not one Task is built for 251 already-flagged Onboardings');
        Assert.areEqual(BULK_N, OnboardingFanoutService.runSkippedAlreadyFanned,
            'and every one of the 251 is counted as skipped, so this cannot pass because the '
            + 'records were never read');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Task WHERE Onboarding__c IN :ids],
            'Read back: zero checklist Tasks in the database');
    }
}
