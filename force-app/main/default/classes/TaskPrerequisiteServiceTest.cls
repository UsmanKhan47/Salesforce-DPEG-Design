/**
 * Tests the Phase 0 wire-fraud prerequisite gate — `TaskPrerequisiteService`, fired from
 * `TaskRollupTriggerHandler.beforeUpdate`, plus the `Prerequisite_Must_Be_Met_To_Complete`
 * validation rule that backstops it on INSERT. Story 28; design
 * `agent-output/design-transaction-fsd-gaps.md` §5.1 / §10.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * WHAT THIS SUITE IS ACTUALLY TRYING TO FALSIFY
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * The requirement is "enforced in automation, not by UI convention", so the tests that matter are
 * the ones that DO NOT go through the LWC's service:
 *
 *   • `refusesPlainDmlCompletion`   — the Data Loader / REST / Flow shape: a bare `update`.
 *   • `refusesSystemModeCompletion` — 🔴 THE LOAD-BEARING ONE. Task object EDIT is UN-GRANTABLE by
 *     permission set on this platform (`ObjectPermissions.SobjectType` excludes
 *     Task/Event/Activity; such a set deploys green then is silently discarded), which is why
 *     `TransactionTaskService` authorizes with the `Transaction_Task_Actions` custom permission and
 *     then writes with `AccessLevel.SYSTEM_MODE`. A refusal implemented inside that service would
 *     cover ONE path. This proves the refusal survives the org's own SYSTEM_MODE write instead of
 *     assuming that a before-trigger fires for one. It deliberately does NOT call
 *     `TransactionTaskService`: that would only re-prove the path which already had a check, and it
 *     would make this suite depend on the running user holding a custom permission.
 *   • `refusesInsertingAnAlreadyCompleteBlockedItem` — the INSERT half, which the trigger
 *     deliberately does not cover (see `enforceOnUpdate`'s governor arithmetic) and the validation
 *     rule's `ISNEW()` arm does, via `Is_Prerequisite_Met__c`'s `false` default. Without this test
 *     the two halves look redundant and someone deletes one.
 *   • `refusesCompletingPrerequisiteAndDependentInOneDml` — pins as DELIBERATE the fact that closing
 *     B2 and B3 in a single write is refused. That single write IS the fraud pattern.
 *   • `refusesClearingTheKeyAndCompletingInOneDml` / `refusesRepointingTheKeyAndCompletingInOneDml`
 *     / `refusesDisarmingTheGateOnAnOpenItem` — 🔴 THE THREE SHAPES OF THE SAME ATTACK, each found
 *     in a separate review pass, each ONE STATEMENT, each defeating the validation rule as well as
 *     the trigger: BLANK the key, MOVE it to an already-complete item, or DISARM it now and complete
 *     in a later save. All are available to the exact personas who work this checklist
 *     (`DPEG_Task_Edit` grants `editable=true`) and none leaves a trace — `Task` field history is not
 *     tracked. The move variant is the nastiest: it made the trigger STAMP
 *     `Is_Prerequisite_Met__c = true`, arming the backstop in the attacker's favour rather than
 *     merely evading it.
 *   • `refusesReparentingTheDealAndCompletingInOneDml` / `refusesReparentingAnOpenGatedItem` — 🔴 THE
 *     FOURTH SHAPE, found once the key half was hardened: `Blocked_By__c` is only HALF the
 *     coordinate, so moving `Transaction_Deal__c` re-scopes the lookup to a deal whose B2 is already
 *     complete. Cheaper than all three above — it never touches the key at all.
 *     ⚠ These four are the reason `enforceOnUpdate` resolves the STORED COORDINATE — both halves —
 *     while a row is open. If a future change makes either incoming value win again, they go red
 *     together; none is redundant with the others, and a fifth identity component would need its own.
 *   • `overrideHolderMayMoveALiveGateButStillCannotCompletePastIt` — the administrative escape hatch
 *     exists (branch B) and does NOT reach the completion refusal (branch A).
 *
 * 🔴 EVERY BRANCH-B TEST CALLS `withoutOverride()` FIRST, INCLUDING THE `allows…` ONES. The runner is
 * an administrator and therefore holds the override, so without that seam the refusal tests go red
 * AND the permissive tests pass vacuously — proving the admin bypass instead of the narrowing each
 * one is named for. See that helper.
 *   • `clampsSuppliedPrerequisiteMetOnInsert` — a supplied `Is_Prerequisite_Met__c = true` beats a
 *     `<defaultValue>`, which applies only to an ABSENT field.
 *   • `lwcSetTaskStatusSurfacesTheRefusalVerbatim` / `lwcCompleteTaskSurfacesTheRefusalVerbatim` —
 *     the refusal must reach the human, not the debug log. These assert the TEXT;
 *     `TransactionTaskControllerTest`'s existing failure tests assert `isNotNull` only and therefore
 *     cannot tell the verbatim message from the generic "refresh the page" one.
 *
 * ⚠ THE COUNTERWEIGHTS ARE AS LOAD-BEARING AS THE REFUSALS, because every one of them is a way the
 * gate could brick real data instead of protecting it:
 * `allowsRepairingAnUnresolvableKeyOnAnOpenItem` (a typo must stay fixable),
 * `allowsClearingTheKeyOnAnAlreadyCompleteRow` and `allowsBackfillOfAnAlreadyCompleteDependent` (the
 * backfill and ordinary maintenance), `allowsChangingTheKeyOnceThePrerequisiteIsComplete` (the
 * refusal must not outlive the risk), `allowsEditAndReopenOfACompletedDependent`. Tightening the
 * disarm rule without re-running these is how this feature stops being shippable.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * GOVERNOR BUDGET — NAMED, DERIVED, AND ASSERTED (see the constants below)
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * A throw in this trigger rolls back the saving user's own work, and routing a query into
 * `TaskRollupTrigger` is measured in this org to cost `ceil(rows/200)` SOQL AND DML at fan-out
 * scale. So the budget is asserted two ways, deliberately:
 *   1. EXACTLY, on `TaskPrerequisiteService.readCount` — a counter incremented at the call site
 *      inside the trigger. Immune to unrelated automation, and the only thing that can tell
 *      "one read per CHUNK" from "one read per RECORD".
 *   2. As a CEILING, on `Limits.getQueries()` / `getDmlStatements()` deltas across the whole
 *      cascade. Not an equality: `TaskRollupService` also runs, and a `Transaction__c` update can
 *      wake unrelated automation. A ceiling still fails loudly if anyone adds a per-record query.
 * ⚠ Both are captured around SYNCHRONOUS DML, not across `Test.stopTest()`. `stopTest` restores the
 * pre-test counters, which is what makes the obvious version of assertion 2 pass vacuously.
 *
 * 🔴 EVERY CEILING BELOW IS DERIVED FROM ITS TERM LIST, AND HAS NOT YET BEEN RUN. This tranche was
 * written without an org (the `salesforce` MCP server was down) and has never been compiled. So:
 *   - each ceiling states its terms and DECLARES its slack rather than hiding slack inside a number
 *     that calls itself derived. Re-derive from the TERMS if a future change adds one — never from
 *     the previous bound, which launders the old slack into the new figure;
 *   - `Assert.isTrue(x <= N)` CANNOT GO RED FOR AN N THAT IS TOO LARGE, so no run will ever surface a
 *     ceiling that is too generous. That is why the load-bearing budget assertion is the EXACT
 *     `Assert.areEqual(MAX_PREREQ_READS_AT_BULK, readCount, ...)`, on the one counter this feature
 *     owns. If you tighten a ceiling, tighten it on the strength of an actual run, not a comment.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * ⚠ BULK VOLUME IS 251, PER `.claude/rules/bulk-test-rule.md`, AND IT IS LOAD-BEARING HERE
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 251 forces a SECOND before-update trigger chunk, which is the only way to tell a correct
 * once-per-chunk read from a once-per-transaction one that would silently mis-evaluate rows
 * 201-251. This class is NOT covered by that rule's per-transaction-singleton exemption: the method
 * takes a collection and is driven by a trigger. No content objects are touched, so
 * `.claude/rules/content-publication-rule.md` does not apply.
 *
 * ⚠ FIXTURES SUPPRESS THE DAY-0 FAN-OUT. `TestDataFactory.createTransactions` ships a
 * `Contract_Executed_Date__c`; leaving it would materialise 82 extra Tasks per Transaction at
 * `Test.stopTest()` and every count below would be measuring those instead. Same suppression
 * `TaskRollupTriggerHandlerTest` uses, for the same reason.
 *
 * 🔴 FIELD SHAPE: `Blocked_By__c` is `Text(20)` holding `<GroupLetter>|<Sequence>` (`B|2`, `I|7`) —
 * NOT a lookup, which is undeployable against Task on this platform (measured 2026-08-31; see the
 * field's `<description>`). The prerequisite is the SIBLING Task under the same
 * `Transaction_Deal__c`. One consequence shows up all over this file: the key can be written AT
 * INSERT, because it needs no target Id.
 *
 * @see force-app/main/default/classes/TaskPrerequisiteService.cls
 * @see force-app/main/default/classes/TaskRollupTriggerHandler.cls
 * @see force-app/main/default/objects/Activity/validationRules/Prerequisite_Must_Be_Met_To_Complete.validationRule-meta.xml
 * @see scripts/backfill-task-blocked-by.apex
 */
@isTest
private class TaskPrerequisiteServiceTest {

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // NAMED GOVERNOR BUDGET
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /** Rows in every bulk scenario. 251 forces a second 200-record trigger chunk. */
    private static final Integer BULK_ROWS = 251;

    /** ceil(251 / 200). The number of before-update firings a 251-row update produces. */
    private static final Integer CHUNKS_AT_BULK = 2;

    /**
     * Selector reads this feature may spend on a 251-row completion: ONE PER CHUNK, never a function
     * of row count. A per-record regression would read 251 times.
     */
    private static final Integer MAX_PREREQ_READS_AT_BULK = CHUNKS_AT_BULK;

    /**
     * Ceiling on TOTAL queries across a 251-row completion. Derived:
     *   2  this feature      (1 per before-update chunk)
     * + 4  TaskRollupService (2 per after-update chunk, via TaskSelector)
     * + 2  slack for unrelated automation woken by the Transaction__c rollup update
     *
     * 🔴 CORRECTED 2026-09-02 AND THE CEILING WAS RAISED WITH IT. The TaskRollupService term was
     * 2, and the slack was the only thing absorbing the difference. Phase 4 M0 added the
     * DUAL-MODEL COUNTER GUARD to `TaskRollupService.recalc`: it now reads `Transaction__c`
     * BEFORE the Task read, to skip deals the checklist model has claimed. This fixture inserts
     * 251 Tasks CARRYING `Transaction_Deal__c`, so `recalcDeals` is entered on both after-update
     * chunks and each spends 2 queries, not 1.
     * ⚠ THE OLD `<=` ASSERTION STILL PASSED AT 6, WHICH IS EXACTLY THE PROBLEM: the true total
     * had risen to the ceiling with ZERO margin and nothing went red, so the derivation above
     * would have quietly become fiction. Raised to 8 so the stated terms and the stated total
     * agree again AND the declared slack still exists. Do not re-tighten it to 6 without first
     * re-deriving the TaskRollupService term - and note it drops back to 2 at M5, when the
     * counter guard is deleted along with the class.
     */
    private static final Integer MAX_QUERIES_AT_BULK = 8;

    /**
     * Ceiling on TOTAL queries for the SMALL (two-Task) unblocked-update scenario. Derived:
     *   1  this feature      (one before-update chunk)
     * + 2  TaskRollupService (one after-update chunk, x2 since the Phase 4 counter guard)
     * + 1  OnboardingTaskRollupService (the same statement touches both parents)
     * + 6  slack for anything those two parent updates wake
     *
     * 🔴 SEPARATE FROM `MAX_QUERIES_AT_BULK`, AND THAT SEPARATION IS THE WHOLE POINT. This scenario
     * was a bare literal `8` while the bulk one used its constant, so the 6 -> 8 correction made for
     * the Phase 4 counter guard silently did not apply here. Two budgets that look alike are not
     * alike; both are named now so a future change has to consider each on purpose.
     */
    private static final Integer MAX_QUERIES_AT_SMALL_UPDATE = 10;

    /**
     * Ceiling on TOTAL DML statements across a 251-row completion. Derived:
     *   1  the caller's own update
     * + 2  TaskRollupService (1 Transaction__c update per after-update chunk)
     * + 2  slack for unrelated automation
     * + 0  THIS FEATURE, which is before-context and mutates records in memory. If this ceiling is
     *      ever raised for this class, check first whether DML was added to a before trigger.
     */
    private static final Integer MAX_DML_AT_BULK = 5;

    /**
     * Reads allowed on the 251-row REFUSAL path. Larger than the success path ON PURPOSE: with
     * `allOrNone = false` the runtime removes records a before trigger rejected and RE-FIRES the
     * trigger for what remains, so a chunk can legitimately be processed more than once. Two passes
     * per chunk is the allowance, and it still falsifies a per-record query by two orders of
     * magnitude — which is the fact under test.
     */
    private static final Integer MAX_PREREQ_READS_AT_BULK_REFUSAL = CHUNKS_AT_BULK * 2;

    /** The real group letter/sequence pair from `scripts/load-transaction-task-defs.apex`. */
    private static final String GROUP_B = 'B. Earnest Money Wire';

    /** The key B3 carries in production: "complete B2 first". */
    private static final String KEY_B2 = 'B|2';

    /**
     * A SECOND real group, for the bulk fixtures.
     *
     * 🔴 IT MUST BE A REAL VALUE AND A DIFFERENT ONE-CHARACTER LETTER. `Task_Group__c` is a
     * RESTRICTED picklist, so an invented label (this was `Z. Bulk Dependents` until the first
     * deploy) dies at insert with INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and the test NEVER RUNS —
     * neither passing nor failing, which is worse than red. A different letter from GROUP_B is what
     * stops each dependent key (`B|n`) colliding with the dependent row that carries it.
     */
    private static final String GROUP_J = 'J. Post-Closing Checklist';

    /**
     * The ONLY value in the `Task_Group__c` set whose letter half is not a single character.
     *
     * That makes it the only real value `TaskPrerequisiteService.groupLetterOf` discards, which is
     * what `unparseableSiblingDoesNotShadowTheRealPrerequisite` needs — and it is also why no
     * prerequisite pair can ever be defined inside group H2.
     */
    private static final String GROUP_H2 = 'H2. Tenant Interviews & Estoppels';

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // FIXTURES
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * One Active Transaction with the Day-0 fan-out suppressed. Shared by every test; the checklist
     * Tasks themselves are built per test because each test mutates them.
     */
    @TestSetup
    static void setup() {
        Transaction__c deal = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(deal, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert deal;
    }

    /**
     * The shared suppressed Transaction.
     *
     * ⚠ `LIMIT 1` WITH NO ORDER BY. Any test that creates a SECOND Transaction must capture this
     * one's Id BEFORE doing so — afterwards this method may return either row. `newSuppressedDeal`
     * exists for those tests and its Javadoc repeats the warning.
     *
     * @return The deal created by @TestSetup.
     */
    private static Transaction__c deal() {
        return [SELECT Id FROM Transaction__c LIMIT 1];
    }

    /**
     * A SECOND Active Transaction with the Day-0 fan-out suppressed, for the cross-deal tests.
     *
     * ⚠ Capture `deal().Id` BEFORE calling this — see that method.
     *
     * @return The new deal.
     */
    private static Transaction__c newSuppressedDeal() {
        Transaction__c other = TestDataFactory.createTransaction(null, null, false);
        TestDataFactory.applyOverrides(other, new Map<String, Object>{ 'Contract_Executed_Date__c' => null });
        insert other;
        return other;
    }

    /**
     * 🔴 FORCES THE ADMINISTRATIVE OVERRIDE CLOSED, AND EVERY BRANCH-B TEST MUST CALL IT.
     *
     * `refusalFor` branch B is gated on `TransactionActionPermissionService.hasPrereqOverrideAccess`,
     * which returns TRUE for anyone with "Modify All Data" — and the test runner is an administrator.
     * So without this seam:
     *   - every disarm-REFUSAL test would go red (the runner is exempt), and
     *   - worse, every disarm-ALLOWED test would pass VACUOUSLY: `allowsRepairingAnUnresolvableKey…`,
     *     `allowsChangingTheKeyOnceThePrerequisiteIsComplete`, `allowsClearingTheKeyOnAnAlreadyCompleteRow`
     *     and `allowsBackfillOfAnAlreadyCompleteDependent` would prove the ADMIN BYPASS works rather
     *     than the narrowing they are named for, and would keep passing if the narrowing were deleted.
     * Setting the service's transaction-scoped cache is deterministic and needs no user provisioning;
     * Apex resets statics per test method, so it cannot leak between tests.
     */
    private static void withoutOverride() {
        TransactionActionPermissionService.cachedHasPrereqOverrideAccess = false;
    }

    /**
     * The real B2/B3 wire pair, built inline rather than through `TestDataFactory`.
     *
     * ⚠ DELIBERATE, AND NOT A FACTORY GAP TO BE "FIXED": `TestDataFactory` is a hub file shared by
     * every workstream (`agent-output/hub-consolidation-tracker.md` — no implementation stream edits
     * it), and this pair is a two-record structure specific to a phase that is discarded at M5.
     * `createChecklistTasks` IS used for the bulk fixtures below, where subjects are irrelevant.
     *
     * Subjects are the real ones from `scripts/load-transaction-task-defs.apex` so the fixture is
     * recognisable — NOTHING in the code under test reads a Subject to make a decision. That is the
     * point of the whole feature (RISK 1).
     *
     * @param dealId          Parent Transaction.
     * @param dependentStatus Status the DEPENDENT item (B3) is created with.
     * @param blockedByKey    `Blocked_By__c` for the dependent at INSERT; null leaves it blank so a
     *                        test can add it later (the backfill shape).
     *                        ⚠ `dependentStatus = 'Completed'` and a non-null key TOGETHER are
     *                        REFUSED at insert — that is `clampOnInsert` plus the validation rule's
     *                        `ISNEW()` arm doing their job, not a fixture bug. Build that state the
     *                        way production does: insert complete with a blank key, then stamp it.
     * @return { B2 (the prerequisite), B3 (the dependent) }, inserted.
     */
    private static List<Task> wirePair(Id dealId, String dependentStatus, String blockedByKey) {
        Task prerequisite = new Task(
            Transaction_Deal__c = dealId,
            Subject = 'Call title company to verbally verify wiring instructions (anti-fraud)',
            Task_Group__c = GROUP_B,
            Task_Sequence__c = 2,
            Status = 'Not Started'
        );
        Task dependent = new Task(
            Transaction_Deal__c = dealId,
            Subject = 'Send wire request to accounting with verified instructions',
            Task_Group__c = GROUP_B,
            Task_Sequence__c = 3,
            Status = dependentStatus,
            Blocked_By__c = blockedByKey
        );
        insert new List<Task>{ prerequisite, dependent };
        return new List<Task>{ prerequisite, dependent };
    }

    /** Re-reads a Task's gate-relevant state. @param taskId The Task. @return The reloaded Task. */
    private static Task reloaded(Id taskId) {
        return [
            SELECT Id, Status, IsClosed, Transaction_Deal__c, Blocked_By__c, Is_Prerequisite_Met__c
            FROM Task
            WHERE Id = :taskId
        ];
    }

    /**
     * EVERY error on a failed row, joined. Deliberately not `getErrors()[0]`: both the trigger's
     * `addError` and the `Prerequisite_Must_Be_Met_To_Complete` validation rule can register against
     * the same save, and an assertion pinned to the first one would be pinning platform ordering
     * rather than behaviour.
     *
     * @param result The SaveResult to flatten.
     * @return All error messages joined by ' | '.
     */
    private static String allErrors(Database.SaveResult result) {
        List<String> messages = new List<String>();
        for (Database.Error err : result.getErrors()) {
            messages.add(err.getMessage());
        }
        return String.join(messages, ' | ');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 NEGATIVE — THE PATHS UI CONVENTION CANNOT COVER
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * THE DATA-LOADER PATH. A bare `update` — no controller, no service, no custom permission — is
     * refused while the prerequisite is open. This is the hole Story 28 was raised about: before
     * this gate existed, this exact statement completed B3 with no check whatsoever.
     */
    @isTest
    static void refusesPlainDmlCompletion() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);

        Test.startTest();
        Boolean refused = false;
        String message = '';
        try {
            update new Task(Id = pair[1].Id, Status = 'Completed');
        } catch (DmlException e) {
            refused = true;
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(refused, 'A bare DML completion of B3 must be refused while B2 is open');
        Assert.isTrue(
            message.contains('cannot be completed yet'),
            'The refusal must explain itself to whoever ran the write. Got: ' + message
        );
        Assert.isTrue(
            message.contains('Call title company to verbally verify wiring instructions'),
            'The refusal must NAME the blocking step so the user knows what to do. Got: ' + message
        );
        Assert.areEqual(
            'Not Started', reloaded(pair[1].Id).Status,
            'The refused save must not have persisted — B3 is still open'
        );
    }

    /**
     * 🔴 THE LOAD-BEARING TEST. The refusal survives `AccessLevel.SYSTEM_MODE`.
     *
     * Task EDIT cannot be granted by permission set on this platform, so EVERY legitimate write to a
     * checklist Task in this org is a SYSTEM_MODE write issued by `TransactionTaskService` after a
     * custom-permission check. If a before-trigger did not fire for those, this feature would enforce
     * nothing on the one path that is actually used. Proven here, not assumed.
     */
    @isTest
    static void refusesSystemModeCompletion() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = pair[1].Id, Status = 'Completed'),
            false,
            AccessLevel.SYSTEM_MODE
        );
        Test.stopTest();

        Assert.isFalse(
            result.isSuccess(),
            'SYSTEM_MODE lifts CRUD/FLS — it does NOT skip triggers. The gate must still refuse.'
        );
        Assert.isTrue(
            allErrors(result).contains('cannot be completed yet'),
            'SYSTEM_MODE refusal must carry the same user-facing explanation. Got: ' + allErrors(result)
        );
        Assert.areEqual(
            'Not Started', reloaded(pair[1].Id).Status, 'B3 must still be open after the refusal'
        );
    }

    /**
     * THE INSERT HALF, WHICH THE TRIGGER DELIBERATELY DOES NOT COVER.
     *
     * `enforceOnUpdate` runs in before UPDATE only — an insert-context check would add
     * `ceil(rows/200)` SOQL to the Day-0 fan-out cascade for a check that finds nothing (the
     * arithmetic is in that method's Javadoc). The hole is closed instead by
     * `Prerequisite_Must_Be_Met_To_Complete`'s `ISNEW()` arm plus `Is_Prerequisite_Met__c`'s
     * `<defaultValue>false</defaultValue>`: a record created already-Completed with a
     * `Blocked_By__c` is refused by the default value alone, at zero governor cost.
     *
     * Without this test the trigger and the rule look redundant and someone deletes one of them.
     */
    @isTest
    static void refusesInsertingAnAlreadyCompleteBlockedItem() {
        Id dealId = deal().Id;

        Test.startTest();
        Database.SaveResult result = Database.insert(
            new Task(
                Transaction_Deal__c = dealId,
                Subject = 'Send wire request to accounting with verified instructions',
                Task_Group__c = GROUP_B,
                Task_Sequence__c = 3,
                Status = 'Completed',
                Blocked_By__c = KEY_B2
            ),
            false
        );
        Test.stopTest();

        Assert.isFalse(
            result.isSuccess(),
            'Creating a blocked item ALREADY Completed must be refused — this is the insert path the '
                + 'trigger deliberately does not police, and the validation rule does'
        );
        Assert.isTrue(
            allErrors(result).contains('prerequisite'),
            'The validation rule message must surface. Got: ' + allErrors(result)
        );
    }

    /**
     * Closing the verification and the wire request in ONE write is refused, and that is DELIBERATE
     * hardening rather than a limitation — it is precisely the pattern a fraudulent or careless bulk
     * write takes. The read sees committed state, so B2's in-flight completion is correctly invisible
     * to B3. Nobody who actually telephones the title company does both in one save.
     *
     * Pinned as a TEST because it will otherwise be "fixed" by someone merging Trigger.new state in.
     */
    @isTest
    static void refusesCompletingPrerequisiteAndDependentInOneDml() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);

        Test.startTest();
        List<Database.SaveResult> results = Database.update(
            new List<Task>{
                new Task(Id = pair[0].Id, Status = 'Completed'),
                new Task(Id = pair[1].Id, Status = 'Completed')
            },
            false
        );
        Test.stopTest();

        Assert.isTrue(results[0].isSuccess(), 'B2 itself carries no prerequisite and must save');
        Assert.isFalse(
            results[1].isSuccess(),
            'B3 must be refused: B2 was not COMMITTED complete when B3 was evaluated'
        );
        Assert.areEqual('Completed', reloaded(pair[0].Id).Status, 'B2 completed');
        Assert.areEqual('Not Started', reloaded(pair[1].Id).Status, 'B3 did not');
    }

    /**
     * FAILS CLOSED when the key names a row that does not exist. `Blocked_By__c` is Text and is
     * therefore NOT referentially enforced — a typo, a renamed group letter, or a deal whose
     * prerequisite was never fanned out all resolve to nothing. For an anti-fraud control "I cannot
     * find the verification step" must mean no, never "probably fine".
     */
    @isTest
    static void refusesWhenTheKeyNamesNoExistingRow() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', 'B|99');

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = pair[1].Id, Status = 'Completed'), false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'An unresolvable key must refuse, not wave through');
        Assert.isTrue(
            allErrors(result).contains('could not be read'),
            'The unresolved refusal must say so specifically, not blame the user for an open step. Got: '
                + allErrors(result)
        );
        Assert.isFalse(
            reloaded(pair[1].Id).Is_Prerequisite_Met__c,
            'and the denormalised backstop must read false so the validation rule agrees'
        );
    }

    /**
     * A MALFORMED key refuses WITHOUT SPENDING A QUERY. Worth its own test because the cheap thing
     * (query anyway, find nothing) and the correct thing (do not query, refuse) are indistinguishable
     * from the outside — only `readCount` separates them, and this is the one branch where the gate
     * is not inert and still must not query.
     *
     * Invoked directly rather than through DML: `enforceOnUpdate` returns its refusals precisely so a
     * unit test can assert the decision without depending on `addError`, which is only meaningful
     * inside a trigger.
     */
    @isTest
    static void malformedKeyRefusesWithoutQuerying() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', null);
        Id dealId = deal().Id;

        Task dependent = new Task(
            Id = pair[1].Id,
            Transaction_Deal__c = dealId,
            Status = 'Completed',
            Blocked_By__c = 'not-a-key'
        );
        Map<Id, Task> oldMap = new Map<Id, Task>{
            pair[1].Id => new Task(Id = pair[1].Id, Status = 'Not Started')
        };

        Test.startTest();
        TaskPrerequisiteService.resetReadCount();
        Map<Id, String> refusals = TaskPrerequisiteService.enforceOnUpdate(
            new List<Task>{ dependent }, oldMap
        );
        Test.stopTest();

        Assert.areEqual(1, refusals.size(), 'A key that cannot be parsed must refuse');
        Assert.areEqual(
            TaskPrerequisiteService.MSG_UNRESOLVED, refusals.get(pair[1].Id),
            'and must report itself as unresolved rather than as an open prerequisite'
        );
        Assert.isFalse(dependent.Is_Prerequisite_Met__c, 'backstop reads false');
        Assert.areEqual(
            0, TaskPrerequisiteService.readCount,
            'ZERO queries: there was nothing resolvable to look for'
        );
    }

    /**
     * A SELF-REFERENCING key (`B|3` written onto item B3) must not let the item gate itself — which
     * it otherwise would, becoming satisfied the instant it was completed. Cheap guard, silent
     * failure if it is ever removed.
     */
    @isTest
    static void refusesASelfReferencingKey() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', 'B|3');

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = pair[1].Id, Status = 'Completed'), false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'An item pointed at itself must not satisfy its own gate');
        Assert.areEqual('Not Started', reloaded(pair[1].Id).Status, 'and must not complete');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // POSITIVE — THE GATE OPENS, AND STAYS OUT OF THE WAY
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /** Once B2 is complete, B3 completes normally and the denormalised backstop flips to true. */
    @isTest
    static void allowsCompletionOncePrerequisiteIsComplete() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);
        update new Task(Id = pair[0].Id, Status = 'Completed');

        Test.startTest();
        update new Task(Id = pair[1].Id, Status = 'Completed');
        Test.stopTest();

        Task b3 = reloaded(pair[1].Id);
        Assert.areEqual('Completed', b3.Status, 'B3 completes once its verification is done');
        Assert.isTrue(
            b3.Is_Prerequisite_Met__c,
            'Is_Prerequisite_Met__c must be true, or the validation-rule backstop refuses a legitimate save'
        );
    }

    /**
     * THE BACKFILL-SAFETY TEST. On a live deal it is entirely normal to find B3 ALREADY COMPLETE
     * while B2 never was — that unenforced history is what this phase exists to end. Stamping
     * `Blocked_By__c` onto such a row must SUCCEED, because the record is not TRANSITIONING into
     * completion; the gate polices transitions, not steady state. The validation rule agrees, because
     * neither `ISNEW()` nor `ISCHANGED(Status)` is true for that save.
     *
     * If this ever starts failing, `scripts/backfill-task-blocked-by.apex` cannot run at all.
     */
    @isTest
    static void allowsBackfillOfAnAlreadyCompleteDependent() {
        withoutOverride();
        List<Task> pair = wirePair(deal().Id, 'Completed', null);

        Test.startTest();
        update new Task(Id = pair[1].Id, Blocked_By__c = KEY_B2);
        Test.stopTest();

        Task b3 = reloaded(pair[1].Id);
        Assert.areEqual(KEY_B2, b3.Blocked_By__c, 'The backfill key must land');
        Assert.areEqual('Completed', b3.Status, 'and must not disturb the historical status');
        Assert.isFalse(
            b3.Is_Prerequisite_Met__c,
            'The audit signal: a completed wire request whose verification never happened reads false'
        );
    }

    /**
     * An already-complete dependent can still be edited, and REOPENED, without refusal — including
     * after its prerequisite is reopened. A gate that made a completed item permanently
     * uneditable-and-unreopenable would be a worse defect than the one it fixes.
     *
     * Also pins accepted residual 2: `Is_Prerequisite_Met__c` goes stale-true when the prerequisite is
     * reopened, and self-corrects on the dependent's next save. Asserted so the staleness window is a
     * documented property rather than a surprise.
     */
    @isTest
    static void allowsEditAndReopenOfACompletedDependent() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);
        update new Task(Id = pair[0].Id, Status = 'Completed');
        update new Task(Id = pair[1].Id, Status = 'Completed');
        Assert.isTrue(reloaded(pair[1].Id).Is_Prerequisite_Met__c, 'Precondition: gate was satisfied');

        Test.startTest();
        // The prerequisite is reopened. B3's stored flag is now stale-true and nothing saves B3.
        update new Task(Id = pair[0].Id, Status = 'Not Started');
        Assert.isTrue(
            reloaded(pair[1].Id).Is_Prerequisite_Met__c,
            'RESIDUAL 2, pinned: the denormalised flag is stale until B3 is next saved'
        );

        // An unrelated edit to the completed B3 must still save, and it corrects the flag.
        update new Task(Id = pair[1].Id, ActivityDate = Date.today().addDays(3));
        Assert.isFalse(
            reloaded(pair[1].Id).Is_Prerequisite_Met__c,
            'and self-corrects on the next save of B3'
        );

        // Reopening B3 must not be read as "entering completion" and refused.
        update new Task(Id = pair[1].Id, Status = 'Not Started');
        Test.stopTest();

        Assert.areEqual('Not Started', reloaded(pair[1].Id).Status, 'A completed item can be reopened');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 INERTNESS — DO NOT REGRESS THE REST OF THE ORG
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * `TaskRollupTrigger`'s before contexts fire on EVERY Task in the org. For a Task with no
     * `Blocked_By__c` — the Property Management Onboarding checklist, an ordinary Transaction
     * checklist item, a Broker Protection pipeline Task, any hand-created Activity — this feature
     * must cost ONE BLANK CHECK: zero queries, zero DML, and nothing that can throw and roll back an
     * unrelated save.
     *
     * Onboarding is included explicitly because `TaskRollupTriggerHandler` is shared with Property
     * Management and a regression there would land in a different module's checklist.
     */
    @isTest
    static void isInertForTasksWithNoPrerequisite() {
        Onboarding__c onboarding = TestDataFactory.createOnboarding(null, true);
        List<Task> onboardingTasks = TestDataFactory.createOnboardingTasks(2, onboarding.Id, true);
        List<Task> checklistTasks = TestDataFactory.createChecklistTasks(2, deal().Id, true);

        Test.startTest();
        TaskPrerequisiteService.resetReadCount();
        Integer queriesBefore = Limits.getQueries();

        update new List<Task>{
            new Task(Id = onboardingTasks[0].Id, Onboarding_Status__c = 'Complete'),
            new Task(Id = checklistTasks[0].Id, Status = 'Completed')
        };
        Integer queriesSpent = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(
            0, TaskPrerequisiteService.readCount,
            'ZERO reads for Tasks with no Blocked_By__c — this is the org-wide cost control'
        );
        Assert.areEqual(
            'Complete',
            [SELECT Onboarding_Status__c FROM Task WHERE Id = :onboardingTasks[0].Id].Onboarding_Status__c,
            'The Onboarding checklist must be completely unaffected'
        );
        Assert.areEqual(
            'Completed', reloaded(checklistTasks[0].Id).Status,
            'An unblocked Transaction checklist item completes exactly as before'
        );
        // COARSE CEILING, and deliberately so - `readCount == 0` above is the real proof, because it
        // is the only counter this feature owns. This delta also carries TaskRollupService AND
        // OnboardingTaskRollupService (both parents are touched by the one statement) plus anything
        // their Transaction__c / Onboarding__c updates wake. It exists to catch a gross regression,
        // not to pin an exact number another module's change would break.
        //
        // 🔴 RAISED 8 -> 10 AND MOVED OFF A LITERAL, 2026-09-02. This site hardcoded `8` while the
        // BULK site uses `MAX_QUERIES_AT_BULK` - so raising that constant for the Phase 4 dual-model
        // counter guard (which added one `Transaction__c` read per `TaskRollupService.recalc`) did
        // NOT move this one. The two look like the same budget and are not. Both are now named.
        // ⚠ AND A GREEN RUN HERE TELLS YOU NOTHING ABOUT THE MARGIN. `queriesSpent` is interpolated
        // ONLY into the FAILURE message, so a pass reports no number at all - the delta could be 3
        // or 10 and this reads identically. If the headroom ever matters, assert a RANGE (a lower
        // bound as well as this upper one) rather than trusting the green.
        Assert.isTrue(
            queriesSpent <= MAX_QUERIES_AT_SMALL_UPDATE,
            'An update of two unblocked Tasks must stay inside the pre-existing rollup budget. '
                + 'Allowed ' + MAX_QUERIES_AT_SMALL_UPDATE + ', spent: ' + queriesSpent
        );
    }

    /** Null / empty input is safe — the trigger hands over whatever the platform gives it. */
    @isTest
    static void nullAndEmptyInputAreSafe() {
        Test.startTest();
        TaskPrerequisiteService.resetReadCount();
        TaskPrerequisiteService.clampOnInsert(null);
        TaskPrerequisiteService.clampOnInsert(new List<Task>());
        Assert.isNull(
            TaskPrerequisiteService.asRefusal(null),
            'asRefusal(null) must return null, not construct a refusal out of nothing — the caller '
                + 'rethrows the original when it does'
        );
        Assert.areEqual(0, TaskPrerequisiteService.enforceOnUpdate(null, null).size(), 'null is safe');
        Assert.areEqual(
            0, TaskPrerequisiteService.enforceOnUpdate(new List<Task>(), new Map<Id, Task>()).size(),
            'empty is safe'
        );
        Assert.areEqual(
            0, TaskSelector.selectChecklistByDealsAndSequences(null, null).size(),
            'selector: null is safe'
        );
        Assert.areEqual(
            0,
            TaskSelector.selectChecklistByDealsAndSequences(new Set<Id>(), new Set<Decimal>{ 2 }).size(),
            'selector: empty deal set is safe'
        );
        Test.stopTest();

        Assert.areEqual(0, TaskPrerequisiteService.readCount, 'and none of it queried anything');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE CLEARED-KEY BYPASS — the surviving-key control
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 CLEARING THE KEY IN THE SAME WRITE AS THE COMPLETION IS REFUSED.
     *
     * The one-statement bypass that defeated BOTH halves of the control before 2026-08-31 code
     * review: filtering candidates on `Trigger.new` alone dropped this row before any check ran, and
     * the validation rule's `NOT(ISBLANK(Blocked_By__c))` read the NEW blank value and passed. The
     * write is available to the exact personas who work this checklist — `DPEG_Task_Edit` grants
     * `editable=true` on the field — and to any Apex, Flow or SYSTEM_MODE caller regardless of FLS.
     * `Task` field history is not tracked, so it would have left no trace.
     *
     * Also asserts the KEY survived, not just the status: a refusal rolls the whole save back, so a
     * failed attempt cannot quietly strip the gate for a second, unrefused attempt.
     */
    @isTest
    static void refusesClearingTheKeyAndCompletingInOneDml() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = pair[1].Id, Status = 'Completed', Blocked_By__c = null), false
        );
        Test.stopTest();

        Assert.isFalse(
            result.isSuccess(),
            'Completing while blanking the key must be refused — the gate resolves the SURVIVING key'
        );
        Assert.isTrue(
            allErrors(result).contains('cannot be completed yet'),
            'and must refuse for the real reason (B2 is open), not as an unresolved key. Got: '
                + allErrors(result)
        );
        Task b3 = reloaded(pair[1].Id);
        Assert.areEqual('Not Started', b3.Status, 'B3 did not complete');
        Assert.areEqual(
            KEY_B2, b3.Blocked_By__c,
            'and the key SURVIVED — a refused save rolls back wholly, so a failed attempt cannot '
                + 'strip the gate and leave a second attempt unguarded'
        );
    }

    /**
     * 🔴 REPOINTING THE KEY IN THE SAME WRITE AS THE COMPLETION IS REFUSED.
     *
     * The second bypass, found in re-review and STRICTLY CHEAPER than blanking. The first fix
     * resolved `new ?? prior`, so a non-blank new value still won:
     *
     *     update new Task(Id = b3Id, Status = 'Completed', Blocked_By__c = 'A|1');
     *
     * `A|1` names a genuinely complete item on any real deal, so the gate resolved IT, `met` came out
     * true, and — the part that makes this worse than blanking — the trigger then STAMPED
     * `Is_Prerequisite_Met__c = true`, which is the validation rule's own input. The attacker did not
     * evade the backstop, they armed it in their favour. The self-reference guard does not fire,
     * because `A|1` is not the row itself.
     *
     * The fixture deliberately makes `A|1` genuinely complete, so a resolution against the NEW key
     * would pass and this test would go green on the broken code — that is what makes it a
     * discriminator rather than a restatement.
     */
    @isTest
    static void refusesRepointingTheKeyAndCompletingInOneDml() {
        Id dealId = deal().Id;
        List<Task> pair = wirePair(dealId, 'Not Started', KEY_B2);
        // A1 exists and IS complete — the attacker's chosen, genuinely satisfied "prerequisite".
        insert new Task(
            Transaction_Deal__c = dealId, Subject = 'Receive executed contract from legal counsel',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1,
            Status = 'Completed'
        );

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = pair[1].Id, Status = 'Completed', Blocked_By__c = 'A|1'), false
        );
        Test.stopTest();

        Assert.isFalse(
            result.isSuccess(),
            'Completing while REPOINTING the key must be refused — a save must not choose its own '
                + 'examiner. The gate resolves the STORED key while the row is open.'
        );
        Assert.isTrue(
            allErrors(result).contains('Call title company to verbally verify wiring instructions'),
            'and must name B2, the STORED prerequisite — naming A1 would prove it resolved the '
                + 'attacker-supplied key. Got: ' + allErrors(result)
        );
        Task b3 = reloaded(pair[1].Id);
        Assert.areEqual('Not Started', b3.Status, 'B3 did not complete');
        Assert.areEqual(KEY_B2, b3.Blocked_By__c, 'and the repoint rolled back with it');
        Assert.isFalse(
            b3.Is_Prerequisite_Met__c,
            'The stamped flag must NOT have been left true — it is the validation rule input, so a '
                + 'true here would disarm the backstop as well as the trigger'
        );
    }

    /**
     * 🔴 DISARMING A LIVE GATE IS REFUSED, in either shape — the first save of the two-save bypass.
     *
     * Blank or repoint the key on an OPEN item now, complete it in a SEPARATE save later: by that
     * second save neither `Trigger.new`, nor `Trigger.old`, nor the validation rule's
     * `BLANKVALUE(Blocked_By__c, PRIORVALUE(Blocked_By__c))` has anything left to resolve, and
     * `Task` field history is not tracked. Refusing the disarm is the only point at which the
     * sequence can be stopped.
     */
    @isTest
    static void refusesDisarmingTheGateOnAnOpenItem() {
        withoutOverride();
        Id dealId = deal().Id;
        List<Task> pair = wirePair(dealId, 'Not Started', KEY_B2);
        insert new Task(
            Transaction_Deal__c = dealId, Subject = 'Receive executed contract from legal counsel',
            Task_Group__c = 'A. Contract Execution & Title Opening', Task_Sequence__c = 1,
            Status = 'Completed'
        );

        Test.startTest();
        Database.SaveResult blanked = Database.update(
            new Task(Id = pair[1].Id, Blocked_By__c = null), false
        );
        Database.SaveResult repointed = Database.update(
            new Task(Id = pair[1].Id, Blocked_By__c = 'A|1'), false
        );
        Test.stopTest();

        Assert.isFalse(blanked.isSuccess(), 'Blanking a live gate on an open item must be refused');
        Assert.isFalse(repointed.isSuccess(), 'and so must repointing it');
        Assert.isTrue(
            allErrors(blanked).contains('cannot be changed or removed'),
            'with the disarm message, not the completion one. Got: ' + allErrors(blanked)
        );
        Assert.areEqual(
            KEY_B2, reloaded(pair[1].Id).Blocked_By__c,
            'and the stored key is untouched after both attempts'
        );
    }

    /**
     * 🔴 EXPLOIT A — RE-PARENTING THE DEAL IN THE SAME WRITE AS THE COMPLETION IS REFUSED.
     *
     * The third and cheapest bypass, and the one that shows what the others had in common:
     * `Blocked_By__c` is only HALF the coordinate. The prerequisite is the triple
     * (deal, letter, sequence), and after the key half was hardened the DEAL was still read straight
     * off `Trigger.new`:
     *
     *     update new Task(Id = b3Id, Status = 'Completed', Transaction_Deal__c = otherDealId);
     *
     * The key half correctly stayed `B|2`; the QUERY was scoped to the other deal; THAT deal's
     * completed B2 came back; `met` was true; the flag was stamped true; branch A skipped (met) and
     * branch B skipped (`Blocked_By__c` was never touched, so `gateCoordinatesChanged` was false).
     *
     * The other deal's B2 is deliberately COMPLETE, so a resolution scoped to the incoming deal
     * would succeed — that is what makes this a discriminator that goes green on the broken code
     * rather than a restatement of the fix.
     */
    @isTest
    static void refusesReparentingTheDealAndCompletingInOneDml() {
        // ⚠ Capture the setup deal BEFORE creating the second one — `deal()` is an unordered LIMIT 1.
        Id dealId = deal().Id;
        List<Task> pair = wirePair(dealId, 'Not Started', KEY_B2);

        Transaction__c otherDeal = newSuppressedDeal();
        insert new Task(
            Transaction_Deal__c = otherDeal.Id,
            Subject = 'Call title company to verbally verify wiring instructions (anti-fraud)',
            Task_Group__c = GROUP_B, Task_Sequence__c = 2,
            Status = 'Completed'   // the attacker's genuinely satisfied prerequisite, on ANOTHER deal
        );

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = pair[1].Id, Status = 'Completed', Transaction_Deal__c = otherDeal.Id), false
        );
        Test.stopTest();

        Assert.isFalse(
            result.isSuccess(),
            'Completing while RE-PARENTING must be refused — pinning the key half is worthless while '
                + 'the deal half is still taken from Trigger.new'
        );
        Assert.isTrue(
            allErrors(result).contains('Call title company to verbally verify wiring instructions'),
            'and must refuse against the still-open B2 on the ORIGINAL deal. Got: ' + allErrors(result)
        );
        Task b3 = reloaded(pair[1].Id);
        Assert.areEqual('Not Started', b3.Status, 'B3 did not complete');
        Assert.areEqual(dealId, b3.Transaction_Deal__c, 'and the re-parent rolled back with it');
        Assert.isFalse(
            b3.Is_Prerequisite_Met__c,
            'The stamped flag must NOT have been left true — it is the validation rule input, so a '
                + 'true here would disarm the backstop as well as the trigger'
        );
    }

    /**
     * The two-save form of EXPLOIT A: re-parent an OPEN gated item now, complete it later. Refused
     * by the same branch B that catches a key change, because re-parenting moves the coordinate just
     * as effectively as re-keying it.
     *
     * ⚠ This one is BEYOND the literal review instruction (which specified pinning the resolution
     * scope) and is called out in the handover. Pinning alone closes only the ONE-SAVE form; it also
     * leaves the flag being computed against a deal the row no longer belongs to.
     */
    @isTest
    static void refusesReparentingAnOpenGatedItem() {
        withoutOverride();
        Id dealId = deal().Id;
        List<Task> pair = wirePair(dealId, 'Not Started', KEY_B2);
        Transaction__c otherDeal = newSuppressedDeal();

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = pair[1].Id, Transaction_Deal__c = otherDeal.Id), false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Re-parenting a live gate must be refused, like re-keying it');
        Assert.isTrue(
            allErrors(result).contains('cannot be changed or removed'),
            'with the disarm message. Got: ' + allErrors(result)
        );
        Assert.areEqual(
            dealId, reloaded(pair[1].Id).Transaction_Deal__c, 'and the deal is untouched'
        );
    }

    /**
     * 🔴 THE ADMINISTRATIVE ESCAPE HATCH WORKS. A holder of `Transaction_Prereq_Override` may move
     * the coordinate of a live gate — which is what makes the M5 mass key-clear (the documented
     * RETIREMENT path for this whole feature), Phase 1's renumbering, and repair of a
     * wrong-but-RESOLVABLE key possible at all. Branch B refuses every principal and every path
     * including `SYSTEM_MODE` without it.
     *
     * ⚠ PREMISE, ASSERTED FIRST RATHER THAN ASSUMED: this runs as the test user, an administrator,
     * and relies on the "Modify All Data" bypass every sibling gate in
     * `TransactionActionPermissionService` carries. Deliberately does NOT stub the cache — it
     * exercises the REAL `hasPrereqOverrideAccess` computation, so it is also the wiring proof. Same
     * admin premise `TransactionTaskServiceTest`'s original six tests rest on.
     *
     * ⚠ AND THE OVERRIDE DOES NOT REACH BRANCH A: the second half asserts a holder still cannot
     * COMPLETE a row that carries a live gate coordinate. The token maintains the gate's
     * coordinates; it is not a master key for the anti-fraud control.
     * ⚠ READ THAT PRECISELY. A holder CAN disarm in one save and complete in the next, because after
     * the clear the row carries no coordinate and is no longer a candidate. That is not a leak, it is
     * what "may move a live gate" MEANS — the whole point is to let M5 clear every key and then let
     * those items behave like ordinary Tasks. The control the override does not touch is completing
     * a row that is STILL GATED, which is what the second half pins.
     */
    @isTest
    static void overrideHolderMayMoveALiveGateButStillCannotCompletePastIt() {
        Assert.isTrue(
            TransactionActionPermissionService.hasPrereqOverrideAccess(),
            'PREMISE: the test runner must hold Transaction_Prereq_Override or "Modify All Data". '
                + 'If this failed, the runner is not an administrator and the permission is not '
                + 'deployed — that is the cause, not a defect in the gate.'
        );
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);

        Test.startTest();
        update new Task(Id = pair[1].Id, Blocked_By__c = null);

        Database.SaveResult completion = Database.update(
            new Task(Id = pair[1].Id, Status = 'Completed', Blocked_By__c = KEY_B2), false
        );
        Test.stopTest();

        Assert.isTrue(
            String.isBlank(reloaded(pair[1].Id).Blocked_By__c),
            'An override holder may clear a live gate coordinate — without this the feature blocks '
                + 'its own M5 retirement'
        );
        Assert.isFalse(
            completion.isSuccess(),
            'But branch A has NO override: even a holder cannot complete B3 while B2 is open. If '
                + 'this ever passes, the escape hatch has become a master key.'
        );
    }

    /**
     * 🔴 EXPLOIT C — REOPEN-AND-ERASE. Two saves, ORDINARY EDIT ACCESS, NO OVERRIDE.
     *
     *     update new Task(Id = b3, Status = 'Not Started', Blocked_By__c = null);  // save 1
     *     update new Task(Id = b3, Status = 'Completed');                          // save 2
     *
     * Save 1 slipped every branch of the deployed gate: (A) declined because the row was LEAVING
     * completion rather than entering it, and (B) declined on `!wasClosed`, which is false for a row
     * that WAS closed. Save 2 then had a blank key on both sides, so it was not a candidate at all,
     * and the validation rule's `NOT(ISBLANK(BLANKVALUE(new, PRIORVALUE)))` was false for the same
     * reason. Both halves of the control gone, permanently, with no trace.
     *
     * ⚠ THE PRECONDITION IS ORDINARY, WHICH IS WHY THIS RATES CRITICAL: complete B2, complete B3,
     * then reopen B2 — and reopening B2 is unrestricted, because B2 carries no key of its own.
     *
     * Asserts BOTH saves are refused and the coordinate survives. The second assertion is the one
     * that matters: if only save 1 were refused but the key were somehow lost, save 2 would still
     * work.
     */
    @isTest
    static void refusesReopenAndEraseAcrossTwoSaves() {
        withoutOverride();
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);
        // The ordinary precondition: B2 completed, B3 completed legitimately, then B2 reopened.
        update new Task(Id = pair[0].Id, Status = 'Completed');
        update new Task(Id = pair[1].Id, Status = 'Completed');
        update new Task(Id = pair[0].Id, Status = 'Not Started');
        Assert.areEqual('Completed', reloaded(pair[1].Id).Status, 'Precondition: B3 is done');

        Test.startTest();
        Database.SaveResult reopenAndErase = Database.update(
            new Task(Id = pair[1].Id, Status = 'Not Started', Blocked_By__c = null), false
        );
        // Save 2 only reaches a bypass if save 1 succeeded; run it regardless so a regression that
        // lets save 1 through is reported as the COMPLETION it enables, not just as a key edit.
        Database.SaveResult recomplete = Database.update(
            new Task(Id = pair[1].Id, Status = 'Completed'), false
        );
        Test.stopTest();

        Assert.isFalse(
            reopenAndErase.isSuccess(),
            'Erasing the coordinate WHILE REOPENING must be refused — a row walking back through the '
                + 'gate is not past it, so `pastTheGate` must be false here even though `wasClosed` '
                + 'is true'
        );
        Assert.isTrue(
            allErrors(reopenAndErase).contains('cannot be changed or removed'),
            'with the disarm message. Got: ' + allErrors(reopenAndErase)
        );
        Task b3 = reloaded(pair[1].Id);
        Assert.areEqual(
            KEY_B2, b3.Blocked_By__c,
            'THE LOAD-BEARING ASSERTION: the coordinate SURVIVED. A refusal that still lost the key '
                + 'would leave save 2 unguarded, which is the whole exploit'
        );
        Assert.areEqual('Completed', b3.Status, 'and the row never left the completed state');
        Assert.isTrue(
            recomplete.isSuccess(),
            'Save 2 SUCCEEDS, and that is correct rather than alarming: with save 1 refused, it is a '
                + 'no-op re-completion of a row that was already complete and still carries its '
                + 'coordinate. It completes nothing that was not already complete.'
        );
    }

    /**
     * The counterweight to the fix above: REOPENING WITHOUT TOUCHING THE COORDINATE is still allowed.
     *
     * `pastTheGate` deliberately makes a reopen "not past the gate", which pulls it into branch B's
     * scope — so this pins that branch B still declines on `gateCoordinatesChanged`. Without that, a
     * tempting simplification (refuse any save that reopens a gated item) would look correct and
     * would quietly make completed checklist items unreopenable.
     *
     * ⚠ Partly overlaps `allowsEditAndReopenOfACompletedDependent`, which would also redden if the
     * reopen were refused. Kept anyway, and deliberately adjacent to the exploit test: it adds the
     * two assertions that one does not make — the coordinate SURVIVES the reopen, and the flag
     * re-derives against the now-open prerequisite, so the row comes back RE-ARMED rather than
     * reopened-and-defanged.
     */
    @isTest
    static void allowsReopeningWithoutTouchingTheCoordinate() {
        withoutOverride();
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);
        update new Task(Id = pair[0].Id, Status = 'Completed');
        update new Task(Id = pair[1].Id, Status = 'Completed');
        update new Task(Id = pair[0].Id, Status = 'Not Started');

        Test.startTest();
        update new Task(Id = pair[1].Id, Status = 'Not Started');
        Test.stopTest();

        Task b3 = reloaded(pair[1].Id);
        Assert.areEqual('Not Started', b3.Status, 'A completed item can still be reopened');
        Assert.areEqual(KEY_B2, b3.Blocked_By__c, 'with its coordinate intact');
        Assert.isFalse(
            b3.Is_Prerequisite_Met__c,
            'and the flag re-derives against the now-open B2, so the row is correctly re-armed'
        );
    }

    /**
     * ⚠ THE NARROWINGS THAT KEEP THE FEATURE OPERABLE. An UNRESOLVABLE key must stay repairable, or
     * a typo — or a deal whose prerequisite was never fanned out — would brick that checklist item
     * permanently, with no route back for anyone including an administrator.
     *
     * This is the exact case that ruled out the first proposal for closing the two-save gap
     * ("refuse a blanking save when the key resolves" would have been fine here but refused the
     * documented repair of a COMPLETED row instead). Both survive the shipped narrowing.
     */
    @isTest
    static void allowsRepairingAnUnresolvableKeyOnAnOpenItem() {
        withoutOverride();
        List<Task> pair = wirePair(deal().Id, 'Not Started', 'B|99');

        Test.startTest();
        update new Task(Id = pair[1].Id, Blocked_By__c = KEY_B2);
        Test.stopTest();

        Assert.areEqual(
            KEY_B2, reloaded(pair[1].Id).Blocked_By__c,
            'A key pointing at nothing must stay correctable on an open item — otherwise a typo is '
                + 'unfixable and the gate has bricked the data it depends on'
        );
    }

    /** Once the verification is done there is nothing left to protect, so re-keying is allowed. */
    @isTest
    static void allowsChangingTheKeyOnceThePrerequisiteIsComplete() {
        withoutOverride();
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);
        update new Task(Id = pair[0].Id, Status = 'Completed');

        Test.startTest();
        update new Task(Id = pair[1].Id, Blocked_By__c = null);
        Test.stopTest();

        Assert.isTrue(
            String.isBlank(reloaded(pair[1].Id).Blocked_By__c),
            'A satisfied gate may be re-keyed or removed — the disarm refusal is scoped to an OPEN '
                + 'prerequisite, so it does not outlive the risk it exists for'
        );
    }

    /**
     * Clearing the key on an ALREADY-COMPLETE row must still pass. The surviving-key rule must not
     * turn ordinary maintenance — or the backfill's own corrections — into a refusal, because the
     * gate polices TRANSITIONS into completion and this save is not one.
     *
     * Walks the full realistic sequence: historical complete item -> backfill stamps the key ->
     * someone later removes it.
     */
    @isTest
    static void allowsClearingTheKeyOnAnAlreadyCompleteRow() {
        withoutOverride();
        List<Task> pair = wirePair(deal().Id, 'Completed', null);

        Test.startTest();
        update new Task(Id = pair[1].Id, Blocked_By__c = KEY_B2);   // the backfill
        Assert.areEqual(KEY_B2, reloaded(pair[1].Id).Blocked_By__c, 'Precondition: key stamped');

        update new Task(Id = pair[1].Id, Blocked_By__c = null);     // later removal
        Test.stopTest();

        Task b3 = reloaded(pair[1].Id);
        Assert.isTrue(String.isBlank(b3.Blocked_By__c), 'The key can be removed from a completed item');
        Assert.areEqual('Completed', b3.Status, 'and the status is undisturbed');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE INSERT CLAMP
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 A SUPPLIED `Is_Prerequisite_Met__c = true` IS OVERWRITTEN ON INSERT.
     *
     * `<defaultValue>false</defaultValue>` applies only when the field is ABSENT from the payload, so
     * before `clampOnInsert` existed any writer that MAPPED that column — Data Loader, a Flow
     * assignment, an Apex `insert` — satisfied all four conjuncts of the validation rule and created
     * a completed, ungated wire request in one statement. The header claimed the insert path was
     * "fail-closed by construction"; it was not.
     *
     * Two halves, and the second is what proves the CLAMP rather than the rule did the work:
     * the completed insert is refused, AND an open insert succeeds with the flag forced back to false.
     */
    @isTest
    static void clampsSuppliedPrerequisiteMetOnInsert() {
        Id dealId = deal().Id;

        Test.startTest();
        Database.SaveResult refused = Database.insert(
            new Task(
                Transaction_Deal__c = dealId,
                Subject = 'Send wire request to accounting with verified instructions',
                Task_Group__c = GROUP_B, Task_Sequence__c = 3,
                Status = 'Completed', Blocked_By__c = KEY_B2,
                Is_Prerequisite_Met__c = true
            ), false);

        Task openItem = new Task(
            Transaction_Deal__c = dealId,
            Subject = 'Send wire request to accounting with verified instructions',
            Task_Group__c = GROUP_B, Task_Sequence__c = 3,
            Status = 'Not Started', Blocked_By__c = KEY_B2,
            Is_Prerequisite_Met__c = true
        );
        insert openItem;
        Test.stopTest();

        Assert.isFalse(
            refused.isSuccess(),
            'Supplying Is_Prerequisite_Met__c = true must NOT let a completed, gated item be created '
                + '— the default value cannot stop this, only the clamp can'
        );
        Assert.isFalse(
            reloaded(openItem.Id).Is_Prerequisite_Met__c,
            'and the clamp is what did it: a supplied true is overwritten with false on any insert '
                + 'carrying a Blocked_By__c, whatever the status'
        );
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE LWC BOUNDARY — the only path a human actually uses
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE REFUSAL REACHES THE USER, INSTEAD OF "Refresh the page and try again".
     *
     * `TransactionTaskController` catches `Exception` and throws a fixed generic write-failure
     * message, so before this fix the one message that tells the user what to do — it NAMES the
     * blocking anti-fraud step — went to the debug log, and the checklist told them to refresh, which
     * can never help. An enforced control looked like a broken page on the only path a human uses.
     *
     * Asserts the TEXT, not merely that something threw. `TransactionTaskControllerTest`'s existing
     * failure tests assert `isNotNull` only, which cannot tell the verbatim message from the generic
     * one — so nothing there would have caught this.
     *
     * ⚠ Runs as the test user (an administrator), who passes
     * `TransactionActionPermissionService.assertTaskActionAccess` through the "Modify All Data"
     * bypass. That is the same premise the six original `TransactionTaskServiceTest` tests rest on.
     *
     * ⚠ THIS IS ALSO THE PIN ON THE ASCII-ONLY MESSAGE CONSTANTS. `asRefusal` recognises the refusal
     * by matching `MSG_BLOCKED` / `MSG_UNRESOLVED` against the DML message, and `addError`
     * HTML-ESCAPES — so adding an em-dash or a quotation mark to either constant breaks the match,
     * and the ONLY symptom is this test going red. The pair of assertions below is what makes that
     * loud: the first fails if the match broke, the second fails if the generic message came through
     * instead. Do not weaken either into an `isNotNull`.
     */
    @isTest
    static void lwcSetTaskStatusSurfacesTheRefusalVerbatim() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);

        Test.startTest();
        String surfaced = '';
        try {
            TransactionTaskController.setTaskStatus(pair[1].Id, true);
            Assert.fail('The controller must not report success for a refused completion');
        } catch (AuraHandledException e) {
            surfaced = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            surfaced.contains('cannot be completed yet'),
            'The LWC must receive the prerequisite refusal VERBATIM. Got: ' + surfaced
        );
        Assert.isTrue(
            surfaced.contains('Call title company to verbally verify wiring instructions'),
            'including the name of the step the user has to finish. Got: ' + surfaced
        );
        Assert.isFalse(
            surfaced.contains('Refresh the page'),
            'and NOT the generic write-failure advice, which cannot possibly work here'
        );
    }

    /** Same for the notes/confirm-dialog path. Both LWC completion entry points, not just one. */
    @isTest
    static void lwcCompleteTaskSurfacesTheRefusalVerbatim() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', KEY_B2);

        Test.startTest();
        String surfaced = '';
        try {
            TransactionTaskController.completeTask(pair[1].Id, 'wire sent, honest');
            Assert.fail('The controller must not report success for a refused completion');
        } catch (AuraHandledException e) {
            surfaced = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            surfaced.contains('cannot be completed yet'),
            'completeTask must surface the refusal verbatim too. Got: ' + surfaced
        );
        Assert.isFalse(
            surfaced.contains('Refresh the page'), 'not the generic advice'
        );
    }

    /**
     * The translation must NOT become a route for raw platform errors to reach the UI.
     * A non-prerequisite failure still gets the generic message — `asRefusal` returns null and the
     * original exception falls through to the controller's existing catch.
     */
    @isTest
    static void unrelatedFailureStillGetsTheGenericMessage() {
        List<Task> pair = wirePair(deal().Id, 'Not Started', null);
        Id deletedId = pair[1].Id;
        delete pair[1];

        Test.startTest();
        String surfaced = '';
        try {
            TransactionTaskController.setTaskStatus(deletedId, true);
            Assert.fail('A write to a deleted Task must fail');
        } catch (AuraHandledException e) {
            surfaced = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(
            surfaced.contains('Refresh the page'),
            'An unrelated DML failure must still get the generic message — the re-typing is narrow '
                + 'and must not leak platform error text. Got: ' + surfaced
        );
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // FAIL-CLOSED BRANCHES — each one is a way to resolve NOTHING, and none may read as "met"
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /** A blocked Task with no `Transaction_Deal__c` has no sibling scope to search, so it refuses. */
    @isTest
    static void refusesWhenTheBlockedItemHasNoDeal() {
        Task orphan = new Task(
            Subject = 'Send wire request to accounting with verified instructions',
            Task_Group__c = GROUP_B, Task_Sequence__c = 3,
            Status = 'Not Started', Blocked_By__c = KEY_B2
        );
        insert orphan;

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = orphan.Id, Status = 'Completed'), false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'No deal means no resolvable sibling — refuse, never allow');
        Assert.isTrue(
            allErrors(result).contains('could not be read'),
            'reported as unresolved. Got: ' + allErrors(result)
        );
    }

    /**
     * 🔴 REPLACES `refusesWhenTheGroupLabelIsUnparsable`, WHICH TESTED AN UNREACHABLE SCENARIO.
     *
     * That test asserted "a prerequisite whose `Task_Group__c` has no leading letter is unmatchable,
     * so the dependent refuses", using the fixture value `Earnest Money Wire`. `Task_Group__c` is a
     * RESTRICTED picklist, so that value cannot be stored: the test died in setup with
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and was never actually running. It was not fixable by
     * choosing a different value either — the scenario itself does not exist:
     *
     *   - every value in the set is `"<Letter>. <Name>"`, and the only one whose letter half is not a
     *     single character is `H2. Tenant Interviews & Estoppels`;
     *   - a key naming H2 (`H2|3`) is rejected by the key parser for the SAME one-character rule, so
     *     an H2 row can never be the TARGET of a resolvable key.
     *   So `groupLetterOf` returning null can never change a gate DECISION while the picklist stays
     *   restricted. The production guard is kept as defence (the restriction could be relaxed), but
     *   pretending to test its decision effect would be theatre.
     *
     * WHAT THIS TEST DOES INSTEAD, and it is worth having: it puts a COMPLETED `H2` row at the same
     * `Task_Sequence__c` as the real, OPEN `B2`, so both come back from the one query. It covers the
     * `groupLetterOf` null-skip line with a real picklist value, and it excludes a plausible
     * regression the original never touched — indexing siblings by `(deal, sequence)` and dropping
     * the letter. Under that simplification the completed H2 row could satisfy B3's `B|2` and this
     * save would SUCCEED.
     *
     * ⚠ A REAL CONSTRAINT SURFACED BY THIS, recorded at `TaskFanoutService.PREREQUISITE_SEQUENCES`:
     * no prerequisite pair can ever be defined inside group H2. Harmless today (no H2 pair exists),
     * but it is a silent no-op waiting for whoever adds one.
     */
    @isTest
    static void unparseableSiblingDoesNotShadowTheRealPrerequisite() {
        Id dealId = deal().Id;
        // H2 sits at the SAME sequence as the real B2, so it is returned by the same query and is
        // the row `groupLetterOf` discards. The real prerequisite is deliberately left OPEN, so the
        // refusal below is attributable to B2 and not to a failure to find anything at all.
        insert new Task(
            Transaction_Deal__c = dealId, Subject = 'Interview anchor tenant',
            Task_Group__c = GROUP_H2, Task_Sequence__c = 2, Status = 'Completed'
        );
        List<Task> pair = wirePair(dealId, 'Not Started', KEY_B2);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = pair[1].Id, Status = 'Completed'), false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Still gated by the real B2');
        Assert.isTrue(
            allErrors(result).contains('Call title company to verbally verify wiring instructions'),
            'and the COMPLETED H2 row at the same sequence must not be mistaken for the '
                + 'prerequisite — if it were, this save would have succeeded. Got: '
                + allErrors(result)
        );
    }

    /** A prerequisite with no Subject still produces a readable refusal, never the literal "null". */
    @isTest
    static void refusalReadsWellWhenThePrerequisiteHasNoSubject() {
        Id dealId = deal().Id;
        insert new Task(
            Transaction_Deal__c = dealId, Subject = null,
            Task_Group__c = GROUP_B, Task_Sequence__c = 2, Status = 'Not Started'
        );
        Task dependent = new Task(
            Transaction_Deal__c = dealId,
            Subject = 'Send wire request to accounting with verified instructions',
            Task_Group__c = GROUP_B, Task_Sequence__c = 3,
            Status = 'Not Started', Blocked_By__c = KEY_B2
        );
        insert dependent;

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Task(Id = dependent.Id, Status = 'Completed'), false
        );
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Still refused');
        Assert.isTrue(
            allErrors(result).contains('Waiting on: the preceding checklist item'),
            'and falls back to a readable phrase. Got: ' + allErrors(result)
        );
        Assert.isFalse(
            allErrors(result).contains('Waiting on: null'),
            'never interpolates the literal "null" into a user-facing error'
        );
    }

    /**
     * Turns the `COMPLETED_STATUSES` maintenance comment into an assertion: the constant must equal
     * the `closed = true` members of the org's Task status metadata.
     *
     * ⚠ THIS COVERS ONE DIRECTION ONLY, and the constant's own Javadoc explains the other. A new
     * closed status reds this test (good — the DEPENDENT side would otherwise complete unchecked).
     * It CANNOT catch the prerequisite side, where `IsClosed` would silently accept the new status as
     * proof the phone call happened; nothing in Apex exposes the INTENT of a closed status.
     */
    @isTest
    static void completedStatusesMatchesTaskStatusMetadata() {
        List<TaskStatus> all = [SELECT ApiName, IsClosed FROM TaskStatus];
        Assert.isFalse(
            all.isEmpty(),
            'TaskStatus returned no rows in a test context. If that is a platform restriction rather '
                + 'than an org problem, DELETE this test rather than letting it pass vacuously.'
        );

        Set<String> closedInMetadata = new Set<String>();
        for (TaskStatus s : all) {
            if (s.IsClosed) {
                closedInMetadata.add(s.ApiName);
            }
        }

        Assert.areEqual(
            closedInMetadata, TaskPrerequisiteService.COMPLETED_STATUSES,
            'COMPLETED_STATUSES must list exactly the closed Task statuses. If this went red, a '
                + 'closed value was added to standardValueSets/TaskStatus: add it HERE and to '
                + 'Prerequisite_Must_Be_Met_To_Complete in the same change, or the gate fails OPEN '
                + 'for that status with nothing throwing.'
        );
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // BULK — 251 ROWS, TWO CHUNKS (.claude/rules/bulk-test-rule.md)
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * `BULK_ROWS` prerequisite/dependent pairs on one deal.
     *
     * Prerequisites go in group `B` at sequences 1..N; dependents in group `Z` at the same sequences,
     * each keyed `B|<n>`. Two different letters because the key is `<letter>|<sequence>` and a shared
     * letter would make every dependent's key collide with its own row. The key is set AT INSERT,
     * which the Text shape allows and a lookup could not have.
     *
     * @param dealId              Parent Transaction.
     * @param prerequisitesClosed Whether the prerequisites are created already complete.
     * @return The dependent Tasks.
     */
    private static List<Task> bulkPairs(Id dealId, Boolean prerequisitesClosed) {
        List<Task> prerequisites = TestDataFactory.createChecklistTasks(BULK_ROWS, dealId, false);
        Map<String, Object> prerequisiteOverrides = new Map<String, Object>{ 'Task_Group__c' => GROUP_B };
        if (prerequisitesClosed) {
            prerequisiteOverrides.put('Status', 'Completed');
        }
        TestDataFactory.applyOverrides(prerequisites, prerequisiteOverrides);

        List<Task> dependents = TestDataFactory.createChecklistTasks(BULK_ROWS, dealId, false);
        TestDataFactory.applyOverrides(
            dependents, new Map<String, Object>{ 'Task_Group__c' => GROUP_J }
        );
        for (Task t : dependents) {
            t.Blocked_By__c = 'B|' + String.valueOf(t.Task_Sequence__c.intValue());
        }

        insert prerequisites;
        insert dependents;
        return dependents;
    }

    /**
     * 251 dependents whose prerequisites are all complete, completed in ONE DML.
     *
     * Two facts under test, and the second is the reason the rule says 251 rather than 200:
     *   - all 251 are allowed through (nothing is silently dropped past the first chunk);
     *   - the feature spends EXACTLY ONE selector read PER CHUNK. A per-record regression would read
     *     251 times and blow the query limit outright; a once-per-transaction regression would read
     *     once and silently mis-evaluate rows 201-251.
     */
    @isTest
    static void bulk251CompletionsSpendOneReadPerChunk() {
        List<Task> dependents = bulkPairs(deal().Id, true);
        List<Task> completions = new List<Task>();
        for (Task t : dependents) {
            completions.add(new Task(Id = t.Id, Status = 'Completed'));
        }

        Test.startTest();
        TaskPrerequisiteService.resetReadCount();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        update completions; // 251 rows, one statement, two before-update chunks

        Integer queriesSpent = Limits.getQueries() - queriesBefore;
        Integer dmlSpent = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(
            MAX_PREREQ_READS_AT_BULK, TaskPrerequisiteService.readCount,
            'EXACTLY one selector read per trigger chunk — not per record, and not once per transaction'
        );
        Assert.areEqual(
            BULK_ROWS,
            [SELECT COUNT() FROM Task WHERE Id IN :dependents AND Status = 'Completed'],
            'All 251 dependents completed, including the 51 in the second chunk'
        );
        Assert.areEqual(
            BULK_ROWS,
            [SELECT COUNT() FROM Task WHERE Id IN :dependents AND Is_Prerequisite_Met__c = true],
            'and all 251 carry the denormalised backstop the validation rule reads'
        );
        Assert.isTrue(
            queriesSpent <= MAX_QUERIES_AT_BULK,
            'Query budget exceeded. Allowed ' + MAX_QUERIES_AT_BULK + ', spent ' + queriesSpent
                + '. See MAX_QUERIES_AT_BULK for the derivation before raising it.'
        );
        Assert.isTrue(
            dmlSpent <= MAX_DML_AT_BULK,
            'DML budget exceeded. Allowed ' + MAX_DML_AT_BULK + ', spent ' + dmlSpent
                + '. This feature contributes ZERO — check whether DML was added to a before trigger.'
        );
    }

    /**
     * 251 dependents whose prerequisites are all OPEN: every one is refused, and the refusal path is
     * bulk-safe too. A gate that queried per record on the way to saying "no" would be just as broken
     * as one that did so on the way to saying "yes".
     *
     * Read allowance is doubled here — with `allOrNone = false` the runtime removes records a before
     * trigger rejected and re-fires the trigger for the remainder. See
     * `MAX_PREREQ_READS_AT_BULK_REFUSAL`.
     */
    @isTest
    static void bulk251RefusalsAreAlsoBulkSafe() {
        List<Task> dependents = bulkPairs(deal().Id, false);
        List<Task> completions = new List<Task>();
        for (Task t : dependents) {
            completions.add(new Task(Id = t.Id, Status = 'Completed'));
        }

        Test.startTest();
        TaskPrerequisiteService.resetReadCount();
        List<Database.SaveResult> results = Database.update(completions, false);
        Test.stopTest();

        Integer refused = 0;
        for (Database.SaveResult r : results) {
            if (!r.isSuccess()) {
                refused++;
            }
        }
        Assert.areEqual(BULK_ROWS, refused, 'All 251 completions refused while their prerequisites are open');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Task WHERE Id IN :dependents AND Status = 'Completed'],
            'and nothing persisted — not even the first chunk'
        );
        Assert.isTrue(
            TaskPrerequisiteService.readCount <= MAX_PREREQ_READS_AT_BULK_REFUSAL,
            'The refusal path must not query per record. Allowed '
                + MAX_PREREQ_READS_AT_BULK_REFUSAL + ', spent ' + TaskPrerequisiteService.readCount
        );
    }
}
