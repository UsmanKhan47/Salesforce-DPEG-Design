/**
 * PM onboarding checklist fan-out: creates the 45-item standard checklist as
 * standard `Task` records when an `Onboarding__c` is opened. Driven by
 * `Onboarding_Task_Def__mdt` and invoked from the `Onboarding_Task_Fanout`
 * record-triggered Flow.
 *
 * Mirrors `TaskFanoutService` (the Transaction Day-0 fan-out) in SKELETON only.
 * The Transaction body's group-letter join and conditional-group gate have NO
 * counterpart here: the onboarding categories carry no letters, are already an
 * enumerated restricted picklist on both `Task.Onboarding_Category__c` and
 * `Onboarding__c.Stage__c`, and no category is conditional. One CMDT, no join.
 *
 * ═══ 🔴 IDEMPOTENCY IS THE WHOLE POINT OF THIS CLASS ═══
 * `Onboarding__c.Tasks_Fanned_Out__c` is the marker. It is read in
 * `OnboardingSelector.selectByIdsForFanout` and written here in the SAME
 * transaction as the Task insert, so a re-save creates nothing. Read that
 * selector's `IdempotencyReads` header before changing either statement:
 * `Onboarding__c` is PRIVATE OWD, `SYSTEM_MODE` lifts CRUD/FLS but NEVER sharing,
 * and a sharing-filtered idempotency read does not disable this feature — it
 * INVERTS it into a machine that mints 45 duplicate Tasks on every save, forever.
 * This repo has a live incident of exactly that shape one object up.
 *
 * ═══ WHY ASYNC — the arithmetic, which differs from the Transaction case ═══
 * At 45 Tasks per Onboarding a 200-record trigger chunk is 9,000 Task rows, which
 * FITS under the 10,000 DML-row limit — unlike the Transaction fan-out's 16,400,
 * which does not. So "it blows the row limit" would be a false claim here and is
 * deliberately not made. It fits with 10% headroom and nothing else in the
 * cascade, and three things immediately consume that headroom:
 *   1. the `Tasks_Fanned_Out__c` flag update (another N rows);
 *   2. `TaskRollupTrigger`, which now routes `Onboarding__c` and therefore fires
 *      after-insert on all 9,000 new Tasks, spending its own SOQL + DML;
 *   3. the 10s SYNCHRONOUS CPU ceiling versus 60s async — the real binding
 *      constraint, which caps the synchronous path at roughly 222 Onboardings.
 * That is arithmetic, not inefficiency: no query tuning moves it, and any fix that
 * kept the work inline would only relocate the break. Hence one enqueue and a
 * chunked chain at `OnboardingFanoutQueueable.CHUNK_SIZE` = 100 (~4,500 rows/job).
 *
 * @see force-app/main/default/classes/TaskFanoutService.cls (the mirrored skeleton)
 * @see force-app/main/default/classes/OnboardingSelector.cls (both idempotency reads)
 * @see force-app/main/default/classes/OnboardingTaskDefProvider.cls (the 45 definitions)
 */
public with sharing class OnboardingFanoutService {

    /** Fallback when a definition row leaves `Default_Status__c` blank. */
    @TestVisible private static final String DEFAULT_ONBOARDING_STATUS = 'Not Started';

    /**
     * Standard `Task.Status` for a freshly fanned-out checklist item.
     * ⚠ 'Open', NOT the CMDT's `Default_Status__c` — the two fields are different
     * axes. `Task.Status` is the platform's open/closed flag (and drives
     * `IsClosed`); `Task.Onboarding_Status__c` is the checklist's own restricted
     * picklist. `scripts/seed-onboarding-tasks.apex` uses exactly this convention:
     * `Status = 'Completed'` only when the checklist item is actually complete.
     */
    @TestVisible private static final String DEFAULT_TASK_STATUS = 'Open';

    // Test injection point: CMDT cannot be inserted in tests, but CAN be built in
    // memory. Same seam, same reason, as TaskFanoutService.taskDefsOverride.
    @TestVisible static List<Onboarding_Task_Def__mdt> taskDefsOverride;

    /** Test seam: forces a re-fan-out of an already-flagged Onboarding. Never set from production code. */
    @TestVisible static Boolean bypassDedupe = false;

    // ═════════════════════════════════════════════════════════════════════════════
    // RUN COUNTERS — governor instrumentation, captured INSIDE the async context.
    //
    // ⚠ These exist because `Limits.getQueries()` asserted AFTER `Test.stopTest()`
    // is SILENTLY VACUOUS: stopTest restores the pre-test counters, so the obvious
    // assertion passes no matter what the job did. A test that wants to pin this
    // job's budget must assert on these.
    // ═════════════════════════════════════════════════════════════════════════════

    /** SOQL queries `fanOutNow` consumed, measured via `Limits`. Cumulative. */
    @TestVisible private static Integer runQueryCount = 0;
    /** DML statements `fanOutNow` consumed, measured via `Limits`. Cumulative. */
    @TestVisible private static Integer runDmlCount = 0;
    /** Tasks this transaction actually built. Cumulative. */
    @TestVisible private static Integer runTasksBuilt = 0;
    /** Onboardings skipped because `Tasks_Fanned_Out__c` was already true. Cumulative. */
    @TestVisible private static Integer runSkippedAlreadyFanned = 0;

    /** Zeroes every counter. Test-only; each test that asserts a budget calls it first. */
    @TestVisible
    private static void resetRunCounters() {
        runQueryCount = 0;
        runDmlCount = 0;
        runTasksBuilt = 0;
        runSkippedAlreadyFanned = 0;
    }

    /**
     * Flow entry point. Does NOT fan out inline — it hands the work to a chunked
     * Queueable chain and returns. See the class header for why.
     *
     * ⚠ `List<InputDTO>` in, `void` out, DTO as an inner class with
     * `@InvocableVariable` — mandated by `.claude/rules/invocable-rule.md`. A Flow
     * calls an invocable ONCE PER BATCH with every matching record; a single-record
     * signature would receive only the first and silently drop the rest, which on
     * this feature means "44 of 45 onboardings never get a checklist and nothing
     * says so".
     *
     * @param requests One request per Onboarding to fan out; null/empty-safe.
     */
    @InvocableMethod(label='Fan Out Onboarding Checklist Tasks'
        description='Queues creation of the standard PM onboarding checklist for an Onboarding record.')
    public static void fanOut(List<InputDTO> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        List<Id> onboardingIds = new List<Id>();
        Set<Id> seen = new Set<Id>();
        for (InputDTO request : requests) {
            if (request != null && request.onboardingId != null && seen.add(request.onboardingId)) {
                onboardingIds.add(request.onboardingId);
            }
        }
        if (onboardingIds.isEmpty()) {
            return;
        }
        // Exactly ONE enqueue per invocation; the Queueable chains the rest. A
        // per-record enqueue would hit the 50-jobs-per-transaction cap at 51
        // Onboardings, which is why the de-dupe above happens BEFORE the enqueue.
        System.enqueueJob(new OnboardingFanoutQueueable(onboardingIds, 0));
    }

    /** Flow input: one Onboarding to fan out. */
    public class InputDTO {
        @InvocableVariable(required=true label='Onboarding Id'
            description='The Onboarding whose checklist should be created.')
        public Id onboardingId;
    }

    /**
     * The synchronous worker. Called by `OnboardingFanoutQueueable` per chunk (and
     * directly by tests that assert checklist content). Callers are responsible for
     * keeping the chunk small enough to fit the DML-row limit — at 45 Tasks each,
     * the ceiling is 222 Onboardings and the shipped chunk is 100.
     *
     * ⚠ STATEMENT ORDER IS DELIBERATE: the flag update runs BEFORE the Task insert.
     * The Task insert fires `TaskRollupTrigger`, which writes back to the same
     * `Onboarding__c`; flagging first means that write-back happens with
     * `Tasks_Fanned_Out__c` ALREADY true, so it cannot possibly re-satisfy the
     * `Onboarding_Task_Fanout` flow's start filter and re-enter this method. Both
     * statements are `allOrNone = true` in one transaction, so a failed insert still
     * rolls the flag back — ordering buys re-entry safety at no cost to atomicity.
     *
     * @param onboardingIds Onboardings to fan out (chunked by the caller); null/empty-safe.
     */
    public static void fanOutNow(List<Id> onboardingIds) {
        if (onboardingIds == null || onboardingIds.isEmpty()) {
            return;
        }
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        // CMDT via the provider's getAll() — costs ZERO SOQL. The @TestVisible
        // override still wins in tests.
        List<Onboarding_Task_Def__mdt> taskDefs = taskDefsOverride != null
            ? taskDefsOverride
            : OnboardingTaskDefProvider.getAllOrderedByCategoryAndSequence();
        if (taskDefs.isEmpty()) {
            // Not configured yet (the CMDT loader is asynchronous — see the provider
            // header). Do NOTHING, and in particular do NOT flag: flagging an
            // Onboarding whose checklist was never built would suppress it forever.
            runQueryCount += Limits.getQueries() - queriesBefore;
            runDmlCount += Limits.getDmlStatements() - dmlBefore;
            return;
        }

        // SOQL 1 of 1 — SYSTEM_MODE + without sharing, argued in the selector.
        Map<Id, Onboarding__c> onboardings =
            OnboardingSelector.selectByIdsForFanout(new Set<Id>(onboardingIds));

        List<Task> toInsert = new List<Task>();
        List<Onboarding__c> toFlag = new List<Onboarding__c>();

        for (Onboarding__c o : onboardings.values()) {
            if (o.Tasks_Fanned_Out__c == true && !bypassDedupe) {
                runSkippedAlreadyFanned++;
                continue;
            }
            Integer createdForOnboarding = 0;
            for (Onboarding_Task_Def__mdt d : taskDefs) {
                toInsert.add(buildTask(o, d));
                createdForOnboarding++;
            }
            toFlag.add(new Onboarding__c(
                Id = o.Id,
                Tasks_Fanned_Out__c = true,
                Tasks_Total__c = createdForOnboarding
            ));
        }
        runTasksBuilt += toInsert.size();

        // 🔴 EXPLICIT SYSTEM MODE, same argument as TaskFanoutService. The
        // Onboarding_Task_Fanout flow runs in DefaultMode, i.e. as whoever saved the
        // Onboarding — on the auto-create path that is the deal driver who just
        // closed the Opportunity, who holds read-only DPEG_PropertyMgmt_View and no
        // Create on Task. Both statements would throw System.TypeException under the
        // caller's own CRUD. allOrNone = true because a silently-absent checklist is
        // the bug being fixed.
        if (!toFlag.isEmpty()) {
            Database.update(toFlag, true, AccessLevel.SYSTEM_MODE);
        }
        if (!toInsert.isEmpty()) {
            Database.insert(toInsert, true, AccessLevel.SYSTEM_MODE);
        }

        runQueryCount += Limits.getQueries() - queriesBefore;
        runDmlCount += Limits.getDmlStatements() - dmlBefore;
    }

    /**
     * Maps one checklist definition onto one Task for one Onboarding. Pure — no
     * SOQL, no DML — extracted so the field mapping reads in one screen.
     *
     * @param o The parent Onboarding (needs Id, OwnerId, Start_Date__c).
     * @param d The checklist definition row.
     * @return An unsaved Task.
     */
    private static Task buildTask(Onboarding__c o, Onboarding_Task_Def__mdt d) {
        Task tk = new Task();
        // Relate via the custom lookup, NEVER WhatId — that is what keeps 45
        // checklist rows per property off the Activity timeline.
        tk.Onboarding__c = o.Id;
        // OwnerId, not Onboarding_Lead__c: that field is Text(120), not Lookup(User),
        // so it cannot be assigned as an owner. Mirrors TaskFanoutService.
        tk.OwnerId = o.OwnerId;
        tk.Subject = d.Subject__c;
        tk.Onboarding_Category__c = d.Category__c;
        tk.Task_Sequence__c = d.Sequence__c;
        tk.Task_Owner_Label__c = d.Owner_Label__c;
        tk.Source_System__c = d.Source_System__c;
        tk.Conditional__c = (d.Conditional__c == true);
        tk.Onboarding_Status__c = String.isNotBlank(d.Default_Status__c)
            ? d.Default_Status__c
            : DEFAULT_ONBOARDING_STATUS;
        tk.Status = DEFAULT_TASK_STATUS;
        // Due date = the onboarding's own start date plus the definition's offset. A
        // blank Start_Date__c leaves ActivityDate NULL rather than defaulting to
        // today: a wrong deadline is worse than an absent one, and the flow's start
        // filter (Start_Date__c IsNull false) means production never reaches here
        // with a blank one anyway.
        if (o.Start_Date__c != null) {
            Integer offset = d.Due_Day_Offset__c != null ? Integer.valueOf(d.Due_Day_Offset__c) : 0;
            tk.ActivityDate = o.Start_Date__c.addDays(offset);
        }
        return tk;
    }
}
