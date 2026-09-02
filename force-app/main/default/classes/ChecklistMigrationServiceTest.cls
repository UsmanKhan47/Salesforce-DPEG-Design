/**
 * Pins `ChecklistMigrationService` - Phase 4 M1 and its reversal.
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 🔴 THE FOUR PROPERTIES THIS CLASS EXISTS TO PROVE. EVERYTHING ELSE IS SUPPORTING.
 * ═══════════════════════════════════════════════════════════════════════════════════════════
 * 1. THE MIGRATION GETS PAST THE WIRE GATE - and the two-pass ordering is what does it.
 *    `refusesAOnePassInsertOfACompletedGatedItem` proves the alternative is REFUSED, so the
 *    ordering is a requirement rather than a style choice.
 * 2. A COMPLETED DEPENDENT WHOSE PREREQUISITE IS STILL OPEN MIGRATES ANYWAY. That is real live
 *    data - Phase 0 shipped the gate on 2026-08-31, so every older deal predates it - and it is
 *    the case a naive migration silently drops.
 * 3. IDEMPOTENCY. Running M1 twice must not double anything.
 * 4. THE RECONCILIATION IS A MECHANISM. A deal that does not reconcile is not migrated AT ALL:
 *    zero checklists, zero items, flag still false.
 *
 * ⚠ THE PERMISSION SEAM, AND WHY NO TEST HERE NEEDS TO FORCE IT FALSE.
 * `TransactionActionPermissionService.hasPrereqOverrideAccess()` returns TRUE for the test runner,
 * because it retains a Modify All Data bypass and the runner is an administrator. A refusal test
 * that depended on it would therefore pass vacuously - it would be proving the admin bypass, not
 * the migration path. Every refusal asserted below is on a branch that HAS NO OVERRIDE AT ALL:
 *   - the INSERT refusal is the `ISNEW()` arm of `Prerequisite_Must_Be_Met_To_Complete` reading
 *     the value `clampOnInsert` forced to false. A validation rule is not bypassed by a custom
 *     permission, by Modify All Data, or by `AccessLevel.SYSTEM_MODE`.
 *   - branch (A) of the gate is documented as having no override and never will.
 * The branch that DOES have an override - (B), the disarm refusal - is gated on
 * `candidate.linkChanged`, which is false for a null to non-null write. The migration never
 * reaches it, and `stampsPrerequisiteLinkOnASecondPass` is the positive proof: the link write is
 * ALLOWED, which under branch (B) it would not be.
 *
 * ⚠ 251 IS UNREACHABLE FOR TRANSACTIONS AND MEANINGLESS HERE, so this class asserts at the
 * CHUNK BOUNDARY instead, exactly as `ChecklistFanoutServiceTest` does. 251 deals x 96 rows =
 * 24,096 DML rows against the 10,000-row limit - testing a volume production cannot reach is the
 * anti-pattern `.claude/rules/bulk-test-rule.md` exists to prevent. The 251-record mandate IS
 * honoured where it is reachable and meaningful: `migratesTwoHundredFiftyOneItemsOnOneDeal`
 * inserts 251 `Checklist_Item__c` rows in one statement, which crosses the 200-row trigger batch
 * boundary and fires the after-insert trigger twice.
 *
 * @see force-app/main/default/classes/ChecklistMigrationService.cls
 * @see agent-output/phase4-migration-design.md
 */
@isTest
private class ChecklistMigrationServiceTest {

    private static final String GROUP_A = 'A. Contract Execution & Title Opening';
    private static final String GROUP_B = 'B. Earnest Money Wire';
    private static final String WIRE_SUBJECT =
        'Call title company to verbally verify wiring instructions (anti-fraud)';
    private static final String GATED_SUBJECT =
        'Send wire request to accounting with verified instructions';
    private static final Integer BULK_ITEMS = 251;

    /**
     * `createTransactionsOnChecklistModel` pre-sets `Tasks_Fanned_Out__c`, which is what stops
     * `flows/Transaction_Task_Fanout` enqueuing the legacy 70-Task fan-out and writing the very
     * counters these tests assert on.
     */
    @TestSetup
    static void setupTestData() {
        TestDataFactory.createTransactionsOnChecklistModel(2, true);
    }

    @isTest
    static void migratesOneChecklistPerGroupAndOneItemPerTask() {
        Transaction__c deal = dealAt(0);
        insertStandardTasks(deal.Id);
        applyDefinitionOverrides();

        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual('MIGRATED', results[0].outcome, discrepancyText(results[0]));
        Assert.areEqual(2, results[0].checklistCount, 'Groups A and B were both present.');
        Assert.areEqual(4, results[0].itemCount, 'One item per Task, never per definition.');
        Assert.areEqual(2, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'Two checklists should exist in the database.');
        Assert.areEqual(4, itemsFor(deal.Id).size(), 'Four items should exist in the database.');
    }

    @isTest
    static void claimsTheDealAndWritesTheFourCountersItself() {
        Transaction__c deal = dealAt(0);
        insertStandardTasks(deal.Id);
        applyDefinitionOverrides();

        Test.startTest();
        ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Transaction__c reloadedDeal = reloaded(deal.Id);
        Assert.isTrue(reloadedDeal.Checklist_Fanned_Out__c,
            'The claim flag is what hands the deal to the checklist model and what the counter '
            + 'guard in TaskRollupService keys on.');
        Assert.areEqual(4, reloadedDeal.Tasks_Total__c, 'Four Tasks became four items.');
        Assert.areEqual(1, reloadedDeal.Tasks_Complete__c, 'A2 was the only closed Task.');
        Assert.areEqual(1, reloadedDeal.Wire_Open_Risks__c,
            'B2 is the wire-verification item and its verbal verification is not recorded. A ZERO '
            + 'here is the RISK 1 failure mode: silent, and in the safe-looking direction.');
    }

    /**
     * 🔴 REGRESSION, 2026-09-02. `Checklist_Item__c.Checklist__c` is a MASTER-DETAIL parent and was
     * never stamped: `buildItem` correctly leaves it blank (the parent is unsaved and has no Id at
     * projection time) and `persist` flattened the pending items, discarding the only parent
     * reference. Every deal failed `REQUIRED_FIELD_MISSING: [Checklist__c]`. It compiled, and three
     * review rounds read past it.
     * ⚠ The existing tests could not catch it: `migratesOneChecklistPerGroupAndOneItemPerTask`
     * counts rows and `stampsPrerequisiteLinkOnASecondPass` reads a DIFFERENT lookup. This asserts
     * the PARENTAGE itself, per item, and that each item hangs under the RIGHT group - a stamp that
     * pointed every child at one parent would pass a mere not-null check.
     */
    @isTest
    static void stampsTheMasterDetailParentOnEveryMigratedItem() {
        Transaction__c deal = dealAt(0);
        insertStandardTasks(deal.Id);
        applyDefinitionOverrides();

        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual('MIGRATED', results[0].outcome, discrepancyText(results[0]));
        Map<Id, String> letterByChecklistId = new Map<Id, String>();
        for (Checklist__c checklist : [
            SELECT Id, Group_Letter__c FROM Checklist__c WHERE Transaction__c = :deal.Id
        ]) {
            letterByChecklistId.put(checklist.Id, checklist.Group_Letter__c);
        }
        Assert.areEqual(2, letterByChecklistId.size(), 'Two groups were present in the fixture.');

        List<Checklist_Item__c> items = itemsFor(deal.Id);
        Assert.areEqual(4, items.size(), 'All four items must have been inserted.');
        for (Checklist_Item__c item : items) {
            Assert.isNotNull(item.Checklist__c,
                'Every item needs its master-detail parent. A null here is the exact defect: the '
                + 'insert fails REQUIRED_FIELD_MISSING and M1 fails on every deal.');
            Assert.areEqual(item.Checklist__r.Group_Letter__c,
                letterByChecklistId.get(item.Checklist__c),
                'And it must hang under the RIGHT group - stamping every child with one parent Id '
                + 'would satisfy a not-null check while silently merging the whole checklist.');
        }
    }

    /**
     * 🔴 THE WIRE-GATE PASSAGE, POSITIVE HALF. The link is written on a SECOND pass and the gate
     * ALLOWS it, because gaining a first link is not a change under
     * `ChecklistItemPrerequisiteService.linkChanged`. If branch (B) were reachable here this save
     * would be refused and this test would go red.
     */
    @isTest
    static void stampsPrerequisiteLinkOnASecondPass() {
        Transaction__c deal = dealAt(0);
        insertStandardTasks(deal.Id);
        applyDefinitionOverrides();

        Test.startTest();
        ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Map<String, Checklist_Item__c> byCoordinate = itemsByCoordinate(deal.Id);
        Checklist_Item__c dependent = byCoordinate.get('B3');
        Checklist_Item__c prerequisite = byCoordinate.get('B2');
        Assert.areEqual(prerequisite.Id, dependent.Blocked_By__c,
            'B3 must end up pointing at B2. A null here means the wire-fraud gate is DISARMED on '
            + 'this deal and nothing would stop the closing wire going out unverified.');
        Assert.isFalse(dependent.Is_Prerequisite_Met__c,
            'B2 is open, so the denormalised backstop the validation rule reads must be false.');
    }

    /**
     * 🔴 THE WIRE-GATE PASSAGE, NEGATIVE HALF - AND THE REASON THE TWO-PASS ORDERING IS A
     * REQUIREMENT RATHER THAN A PREFERENCE. A one-statement insert of an already-complete item
     * that also carries its link is REFUSED, whatever the running user holds.
     *
     * ⚠ THE RUNNER IS AN ADMINISTRATOR AND IT IS STILL REFUSED. That is the point: `clampOnInsert`
     * forces `Is_Prerequisite_Met__c` false whenever a link is present at insert, and the `ISNEW()`
     * arm of the validation rule then refuses the row WITHOUT CONSULTING THE PREREQUISITE STATE.
     * No custom permission, no Modify All Data and no `AccessLevel.SYSTEM_MODE` bypasses a
     * validation rule. Under `allOrNone = false` this would SILENTLY DROP exactly the B3/I8 rows.
     */
    @isTest
    static void refusesAOnePassInsertOfACompletedGatedItem() {
        Transaction__c deal = dealAt(0);
        Checklist__c checklist = new Checklist__c(
            Transaction__c = deal.Id, Group_Letter__c = 'B', Group_Name__c = 'Earnest Money Wire',
            Sequence__c = 2, Stage__c = 'Open Contract', Items_Total__c = 2, Items_Complete__c = 0);
        insert checklist;
        Checklist_Item__c prerequisite = new Checklist_Item__c(
            Checklist__c = checklist.Id, Subject__c = WIRE_SUBJECT, Sequence__c = 2,
            Stage__c = 'Open Contract', Flag__c = ChecklistItemDomain.FLAG_COMPLETED);
        insert prerequisite;

        Checklist_Item__c dependent = new Checklist_Item__c(
            Checklist__c = checklist.Id, Subject__c = GATED_SUBJECT, Sequence__c = 3,
            Stage__c = 'Open Contract', Flag__c = ChecklistItemDomain.FLAG_COMPLETED,
            Blocked_By__c = prerequisite.Id);

        Test.startTest();
        Boolean refused = false;
        try {
            insert dependent;
        } catch (DmlException e) {
            refused = true;
        }
        Test.stopTest();

        Assert.isTrue(refused,
            'A completed item inserted WITH its link must be refused even though its prerequisite '
            + 'is genuinely complete. If this ever goes green the two-pass ordering in '
            + 'ChecklistMigrationService.persist has stopped being load-bearing - but do not '
            + 'collapse the passes on that evidence alone, because allOrNone=false would then '
            + 'drop these rows silently instead of failing.');
    }

    /**
     * 🔴 THE AWKWARD REAL CASE. B3 was completed while B2 is still open - possible on any deal
     * older than the Phase 0 gate. It must migrate WITH its history, not be dropped.
     */
    @isTest
    static void migratesACompletedDependentWhosePrerequisiteIsStillOpen() {
        Transaction__c deal = dealAt(0);
        List<Task> tasks = standardTasks(deal.Id);
        tasks[3].Status = 'Completed';
        insert tasks;
        applyDefinitionOverrides();

        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual('MIGRATED', results[0].outcome, discrepancyText(results[0]));
        Checklist_Item__c dependent = itemsByCoordinate(deal.Id).get('B3');
        Assert.areEqual(ChecklistItemDomain.FLAG_COMPLETED, dependent.Flag__c,
            'The completion history must survive the migration.');
        Assert.isNotNull(dependent.Blocked_By__c,
            'And it must still receive its link - the second pass is not skipped for a row that '
            + 'is already complete.');
        Assert.isFalse(dependent.Is_Prerequisite_Met__c,
            'Its prerequisite is genuinely open, so the backstop is false. Visible and '
            + 'reportable, which is the correct outcome for pre-gate history.');
    }

    @isTest
    static void preservesCompletionHistoryRatherThanStampingTheRunner() {
        Transaction__c deal = dealAt(0);
        insertStandardTasks(deal.Id);
        applyDefinitionOverrides();
        Task closed = [
            SELECT Id, LastModifiedById, LastModifiedDate
            FROM Task
            WHERE Transaction_Deal__c = :deal.Id
              AND Task_Sequence__c = 2
              AND Task_Group__c = :GROUP_A
        ];

        Test.startTest();
        ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Checklist_Item__c item = itemsByCoordinate(deal.Id).get('A2');
        Assert.areEqual(closed.LastModifiedById, item.Completed_By__c,
            'ChecklistItemDomain.stampCompletion fills Completed_By__c only IF NULL, so supplying '
            + 'it is what stops the MIGRATION RUNNER being stamped onto every historical '
            + 'completion in the org.');
        Assert.areEqual(closed.LastModifiedDate, item.Completed_DateTime__c,
            'Same reasoning for the timestamp.');
    }

    /** 🔴 IDEMPOTENCY - the property most likely to be assumed rather than tested. */
    @isTest
    static void doesNotDoubleAnything_WhenRunTwice() {
        Transaction__c deal = dealAt(0);
        insertStandardTasks(deal.Id);
        applyDefinitionOverrides();

        Test.startTest();
        ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        List<ChecklistMigrationService.MigrationResult> second =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual('ALREADY_MIGRATED', second[0].outcome,
            'The second run must recognise the claim rather than re-migrating.');
        Assert.areEqual(2, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'Still two checklists, not four.');
        Assert.areEqual(4, itemsFor(deal.Id).size(), 'Still four items, not eight.');
    }

    /**
     * The idempotency probe is deliberately BROADER than the claim flag: a hand-created checklist
     * on an unclaimed deal is a documented coexistence case, and migrating on top of one would
     * duplicate the whole checklist with no error.
     */
    @isTest
    static void skipsDeal_WhenItAlreadyHasAChecklistButNoClaim() {
        Transaction__c deal = dealAt(0);
        insertStandardTasks(deal.Id);
        applyDefinitionOverrides();
        insert new Checklist__c(
            Transaction__c = deal.Id, Group_Letter__c = 'A', Group_Name__c = 'Hand made',
            Sequence__c = 1, Stage__c = 'Open Contract', Items_Total__c = 0, Items_Complete__c = 0);

        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual('ALREADY_MIGRATED', results[0].outcome,
            'The flag alone is not enough - the probe must see the existing checklist.');
        Assert.areEqual(1, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'Nothing should have been added on top of it.');
    }

    /**
     * 🔴 THE GATE AS A MECHANISM. A Task whose coordinate has no definition would build an item
     * with `Is_Wire_Verification__c` false - a wire item silently losing its flag - so the deal is
     * refused WHOLE. Nothing is inserted and the claim flag stays false.
     */
    @isTest
    static void migratesNothingAtAll_WhenTheDealDoesNotReconcile() {
        Transaction__c deal = dealAt(0);
        List<Task> tasks = standardTasks(deal.Id);
        tasks.add(buildTask(deal.Id, GROUP_A, 9, 'An orphan task with no definition', false));
        insert tasks;
        applyDefinitionOverrides();

        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual('REFUSED', results[0].outcome, discrepancyText(results[0]));
        Assert.areEqual(0, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'A refused deal must have NOTHING inserted - a partial checklist is worse than none.');
        Assert.isFalse(reloaded(deal.Id).Checklist_Fanned_Out__c,
            'And it must stay on the Task model. That is what makes the refusal visible: the deal '
            + 'simply does not move, and the audit report explains it in PROJECTED mode.');
        Assert.isTrue(hasFinding(results[0], 'NO_DEFINITION'), discrepancyText(results[0]));
    }

    /**
     * A deal the runner cannot see returns no row from the `with sharing` selector. Proven by
     * deleting it, which produces the same shape without needing a second user. It must be
     * REPORTED, never silently skipped - that is the failure mode this migration would otherwise
     * hide behind a green run.
     */
    @isTest
    static void reportsNotVisible_WhenTheSelectorReturnsNoRowForADeal() {
        Transaction__c deal = dealAt(0);
        Id dealId = deal.Id;
        delete deal;
        applyDefinitionOverrides();

        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ dealId });
        Test.stopTest();

        Assert.areEqual('NOT_VISIBLE', results[0].outcome,
            'An unreadable deal must be named, not dropped from the result list.');
        Assert.isTrue(hasFinding(results[0], 'NOT_VISIBLE'), discrepancyText(results[0]));
    }

    /**
     * 🔴 THE ROLLBACK, AND ITS ORDER. Clearing the claim must happen BEFORE the recompute, or the
     * Phase 4 counter guard in `TaskRollupService.recalc` skips the deal and the recompute is a
     * silent no-op. Asserting a NON-ZERO `Wire_Open_Risks__c` afterwards is what catches that:
     * a zero would mean step 3 never ran.
     */
    @isTest
    static void restoresTheTaskModel_WhenRolledBack() {
        Transaction__c deal = dealAt(0);
        insertStandardTasks(deal.Id);
        applyDefinitionOverrides();
        ChecklistMigrationService.migrate(new List<Id>{ deal.Id });

        Test.startTest();
        Set<Id> rolledBack = ChecklistMigrationService.rollback(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, rolledBack.size(), 'One deal was rolled back.');
        Assert.areEqual(0, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'The checklists are gone.');
        Assert.areEqual(0, itemsFor(deal.Id).size(),
            'Master-detail cascade removes the items with them.');
        Transaction__c reloadedDeal = reloaded(deal.Id);
        Assert.isFalse(reloadedDeal.Checklist_Fanned_Out__c, 'The claim is released.');
        Assert.areEqual(1, reloadedDeal.Wire_Open_Risks__c,
            'The LEGACY rollup must have recomputed from the Task rows, which were never touched. '
            + 'A ZERO here means the flag was still set when TaskRollupService ran and the '
            + 'counter guard ate the recompute - i.e. the ordering in rollback was broken.');
        Assert.areEqual(4, [SELECT COUNT() FROM Task WHERE Transaction_Deal__c = :deal.Id],
            'The Task rows are untouched throughout. That is the whole rollback story.');
    }

    /**
     * GOVERNOR SHAPE - CONSTANT PER CHUNK, NOT PER DEAL. Two deals cost the same reads as one.
     * ⚠ Both counters are captured INSIDE `migrate`; `Test.stopTest()` restores the pre-test
     * governor counters, so reading `Limits.getQueries()` out here would measure nothing and the
     * obvious assertion would pass vacuously.
     */
    @isTest
    static void spendsAConstantNumberOfQueriesPerChunk() {
        List<Transaction__c> deals = allDeals();
        insertStandardTasks(deals[0].Id);
        insertStandardTasks(deals[1].Id);
        applyDefinitionOverrides();

        Test.startTest();
        ChecklistMigrationService.migrate(new List<Id>{ deals[0].Id, deals[1].Id });
        Test.stopTest();

        Assert.areEqual(4, ChecklistMigrationService.lastRunQueryCount,
            'FOUR reads per chunk regardless of deal count: Transactions, Tasks, the idempotency '
            + 'probe, and the ONE the prerequisite gate spends when the link update fires it. '
            + 'Suppression covers the ROLLUP arm only and deliberately not the gate. '
            + '⚠ THE LIKELIEST CAUSE OF A HIGHER NUMBER IS NOT A QUERY IN A LOOP HERE. It is a NEW '
            + 'ARM ON TransactionTriggerHandler, which a concurrent workstream owns and which the '
            + 'step-4 Transaction update wakes: every existing arm is change-gated on Stage__c, '
            + 'Loan_Required__c, Opportunity__c or the closed boundary, none of which this write '
            + 'moves. An ungated arm would spend here. Check that handler before this class.');
        Assert.areEqual(4, ChecklistMigrationService.lastRunDmlCount,
            'FOUR statements: checklists, items, links, transactions.');
        Assert.areEqual(2, ChecklistMigrationService.lastRunMigratedCount, 'Both deals migrated.');
    }

    /**
     * The 251-record mandate, honoured where it is REACHABLE: 251 `Checklist_Item__c` rows in one
     * insert crosses the 200-row trigger batch boundary and fires the after-insert trigger twice.
     * See the class header for why 251 TRANSACTIONS is neither reachable nor meaningful.
     */
    @isTest
    static void migratesTwoHundredFiftyOneItemsOnOneDeal() {
        Transaction__c deal = dealAt(0);
        List<Task> tasks = new List<Task>();
        List<Transaction_Task_Def__mdt> defs = new List<Transaction_Task_Def__mdt>();
        for (Integer i = 1; i <= BULK_ITEMS; i++) {
            Boolean isWire = (i == 2);
            String subject = isWire ? WIRE_SUBJECT : 'Bulk subject ' + i;
            tasks.add(buildTask(deal.Id, GROUP_A, i, subject, false));
            defs.add(itemDef('A', i, subject, false, isWire, null, null));
        }
        insert tasks;
        ChecklistMigrationService.groupDefsOverride = groupDefs();
        ChecklistMigrationService.taskDefsOverride = defs;

        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual('MIGRATED', results[0].outcome, discrepancyText(results[0]));
        Assert.areEqual(BULK_ITEMS, itemsFor(deal.Id).size(),
            'All 251 items must land in ONE statement.');
        Assert.areEqual(BULK_ITEMS, reloaded(deal.Id).Tasks_Total__c,
            'The counter the migration writes itself must match what it created.');
        Assert.areEqual(3, ChecklistMigrationService.lastRunDmlCount,
            'THREE statements at 251 rows, not four: this fixture declares no prerequisite pair, '
            + 'so the link pass is skipped entirely. The point of the assertion is that the count '
            + 'is CONSTANT - no DML has crept into a loop.');
    }

    @isTest
    static void doesNothing_WhenInputIsNull() {
        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(null);
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'A null input produces no results and no queries.');
        Assert.areEqual(0, ChecklistMigrationService.lastRunQueryCount, 'And spends nothing.');
    }

    @isTest
    static void doesNothing_WhenInputIsEmpty() {
        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>());
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'An empty input produces no results.');
    }

    @isTest
    static void rollbackDoesNothing_WhenNothingWasMigrated() {
        Transaction__c deal = dealAt(0);

        Test.startTest();
        Set<Id> rolledBack = ChecklistMigrationService.rollback(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(0, rolledBack.size(),
            'A deal with no checklist and no claim has nothing to reverse.');
    }


    /**
     * 🔴 C6 NEGATIVE HALF. A migration chunk carrying historically-completed A5 and B5 items must
     * apply NO outcomes. Without the seam, migrating 25 deals re-applies every historical outcome
     * in bulk — including `CriticalDateService.ensureFor`, the call
     * `TransactionTriggerHandler` deliberately withholds pending GATE-B2/B4 because it can throw
     * inside a trigger and roll back the caller's save.
     *
     * ⚠ ASSERTS ON THE EARNEST **DATE** AND THE CRITICAL DATES, NOT ON `Is_Earnest_At_Risk__c`.
     * Phase 5 deliberately excluded the at-risk refresh from the seam: it derives from a date and
     * nothing saves a deal on the day feasibility expires, so gating it would leave it permanently
     * stale on deals whose items are all already done. Asserting it stays unchanged would pin a
     * behaviour that is intentionally NOT gated.
     */
    @isTest
    static void appliesNoOutcomes_WhenMigratingHistoricallyCompletedItems() {
        Transaction__c deal = dealAt(0);
        insert outcomeTasks(deal.Id);
        applyOutcomeDefinitionOverrides();

        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual('MIGRATED', results[0].outcome, discrepancyText(results[0]));
        Transaction__c reloadedDeal = reloadedWithOutcomes(deal.Id);
        Assert.isNull(reloadedDeal.Earnest_Money_Sent_Date__c,
            'A historically-completed B5 must NOT re-stamp the earnest-money date. A value here '
            + 'means the migration applied an outcome inline, which is exactly what the approved '
            + 'scripts/backfill-checklist-outcomes.apex exists to do deliberately AFTER M1.');
        Assert.areEqual(0, [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id],
            'A historically-completed A5 must NOT re-run CriticalDateService. Rows here mean the '
            + 'migration reached the call TransactionTriggerHandler withholds pending GATE-B2/B4.');
    }

    /**
     * 🔴 C6 POSITIVE CONTROL, AND IT IS THE HALF THAT MAKES THE OTHER ONE MEAN ANYTHING. Run the
     * SAME path with the flag lifted and the outcomes DO apply. Without this, a `finally` that
     * restored the wrong value — or a seam that early-returned unconditionally — would make the
     * negative assertion pass forever while silently disabling the feature for every real user.
     * ⚠ It asserts on `lastRunSuppressed` too, because "suppressed" and "ran and found nothing"
     * leave every other counter at zero and are otherwise indistinguishable.
     */
    @isTest
    static void appliesOutcomes_WhenTheSuppressionFlagIsLifted() {
        Transaction__c deal = dealAt(0);
        insert outcomeTasks(deal.Id);
        applyOutcomeDefinitionOverrides();
        ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Set<Id> itemIds = new Map<Id, Checklist_Item__c>(itemsFor(deal.Id)).keySet();

        Test.startTest();
        // The migration is over; nothing is suppressing now. This is the shape
        // scripts/backfill-checklist-outcomes.apex uses — the no-prior overload, deliberately,
        // because it processes items completed before Phase 5 existed and the transition gate
        // would make the whole script a silent no-op.
        ChecklistOutcomeService.applyForCompletedItems(itemIds);
        Test.stopTest();

        Assert.isFalse(ChecklistOutcomeService.isOutcomeApplicationSuppressed(),
            'The finally block in ChecklistMigrationService.persist must have RESTORED the prior '
            + 'value. A true here means the migration left the flag set and every subsequent '
            + 'outcome in the transaction is silently dead.');
        Assert.isFalse(ChecklistOutcomeService.lastRunSuppressed,
            'And the service must actually have RUN. Suppressed and ran-but-found-nothing both '
            + 'leave every other counter at zero, so this is the only thing that tells them apart.');
        Assert.isNotNull(reloadedWithOutcomes(deal.Id).Earnest_Money_Sent_Date__c,
            'With the flag lifted the completed B5 MUST stamp the earnest-money date. If this is '
            + 'null the seam is not a seam - it is an unconditional off switch, and the negative '
            + 'test above is passing vacuously.');
    }

    /**
     * ⚠ RENAMED 2026-09-02. This was `restoresTheOutcomeFlag_WhenTheChunkFails` and it did NOT test
     * that: an empty `groupDefsOverride` refuses the deal at the RECONCILIATION GATE, so `persist`
     * is never entered and its `finally` is never exercised. The name asserted coverage the fixture
     * could not reach. It still pins something real — the refusal path must not touch the flag — so
     * it is renamed rather than deleted, and the real `finally` case is the test below it.
     */
    @isTest
    static void leavesTheOutcomeFlagClear_WhenTheDealIsRefused() {
        Transaction__c deal = dealAt(0);
        insert outcomeTasks(deal.Id);
        applyOutcomeDefinitionOverrides();
        // No group definitions => every letter reports NO_GROUP_DEFINITION => the deal is refused
        // BEFORE persist. Nothing is inserted, so the flag is never set in the first place.
        ChecklistMigrationService.groupDefsOverride = new List<Task_Group_Def__mdt>();

        Test.startTest();
        List<ChecklistMigrationService.MigrationResult> results =
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual('REFUSED', results[0].outcome, discrepancyText(results[0]));
        Assert.isFalse(ChecklistOutcomeService.isOutcomeApplicationSuppressed(),
            'A refused deal never reaches persist, so the flag must never have been set.');
    }

    /**
     * 🔴 THE REAL `finally` TEST. Forces a genuine `DmlException` INSIDE `persist`, after both
     * suppression flags have been set, and asserts the outcome flag is still restored.
     *
     * ⚠ THE LEVER IS A RESTRICTED PICKLIST, NOT A FIELD LENGTH, AND THAT IS DELIBERATE.
     * `Checklist__c.Stage__c` is restricted, and this repo has measured FOUR TIMES that restricted
     * picklists ARE enforced by Apex DML (the repo elsewhere claims they are "UI-only" - they are
     * not). `buildChecklist` copies `groupDef.Stage__c` straight through, and the group def is an
     * in-memory override here, so an invalid value throws
     * `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` on the FIRST statement inside the try block - the
     * strongest possible place to prove the `finally` runs. A length-based lever would depend on
     * Apex deferring length validation to DML, which is true but is a weaker thing to rely on.
     * ⚠ Apex guarantees `finally`, so this is low-risk by construction. It is here because the
     * cost of being wrong is silent: a leaked static disables outcome application for everything
     * after it in the transaction, and no counter anywhere would show it.
     */
    @isTest
    static void restoresTheOutcomeFlag_WhenPersistThrows() {
        Transaction__c deal = dealAt(0);
        insert outcomeTasks(deal.Id);
        applyOutcomeDefinitionOverrides();
        List<Task_Group_Def__mdt> poisoned = groupDefs();
        for (Task_Group_Def__mdt groupDef : poisoned) {
            groupDef.Stage__c = 'Not A Real Stage';
        }
        ChecklistMigrationService.groupDefsOverride = poisoned;

        Test.startTest();
        Boolean threw = false;
        try {
            ChecklistMigrationService.migrate(new List<Id>{ deal.Id });
        } catch (DmlException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'The fixture must actually reach persist and fail there. If this is false the lever '
            + 'stopped working and the assertion below proves nothing.');
        Assert.isFalse(ChecklistOutcomeService.isOutcomeApplicationSuppressed(),
            'The finally in persist MUST restore the outcome flag even when the chunk throws. A '
            + 'leaked static would silently disable outcome application for everything after it '
            + 'in the transaction, with no counter anywhere showing it.');
        Assert.isFalse(ChecklistRollupService.isTriggerRecalcSuppressed(),
            'And the rollup flag with it - both are restored by the same finally.');
    }

    // ── fixtures ──────────────────────────────────────────────────────────────────────────


    /**
     * Tasks at the two DERIVED outcome coordinates — A5 and B5 — both CLOSED, so the migration
     * carries them over as already-`Completed`. Plus the B2 wire item, without which the deal
     * fails reconciliation on `WIRE_ITEM_COUNT` and never reaches `persist` at all.
     *
     * ⚠ THE COORDINATES ARE `A5` AND `B5` AND THEY ARE NOT ARBITRARY. `ChecklistCaptureDefProvider`
     * hardcodes them (`'A', 5` and `'B', 5`), so they are the ONLY two that produce an outcome.
     * A fixture at any other sequence would make both the negative and the positive test vacuous.
     *
     * @param dealId Parent deal.
     * @return Three unsaved Tasks: A5 closed, B2 open (wire), B5 closed.
     */
    private static List<Task> outcomeTasks(Id dealId) {
        return new List<Task>{
            buildTask(dealId, GROUP_A, 5, 'Log critical dates into Salesforce deal record', true),
            buildTask(dealId, GROUP_B, 2, WIRE_SUBJECT, false),
            buildTask(dealId, GROUP_B, 5, 'Update deal record: Earnest Money Sent = Yes', true)
        };
    }

    /** CMDT overrides matching `outcomeTasks` exactly, on both consumers. */
    private static void applyOutcomeDefinitionOverrides() {
        ChecklistMigrationService.groupDefsOverride = groupDefs();
        ChecklistMigrationService.taskDefsOverride = new List<Transaction_Task_Def__mdt>{
            itemDef('A', 5, 'Log critical dates into Salesforce deal record',
                false, false, null, null),
            itemDef('B', 2, WIRE_SUBJECT, true, true, null, null),
            itemDef('B', 5, 'Update deal record: Earnest Money Sent = Yes',
                false, false, null, null)
        };
    }

    /**
     * @param dealId The deal to reload.
     * @return It, carrying the outcome fields. ⚠ `Is_Earnest_At_Risk__c` is deliberately NOT read
     *         by any caller: Phase 5 excluded the at-risk refresh from the seam because it derives
     *         from a date and nothing saves a deal the day feasibility expires, so gating it would
     *         leave it permanently stale. Asserting on it would pin behaviour that is
     *         intentionally ungated.
     */
    private static Transaction__c reloadedWithOutcomes(Id dealId) {
        return [
            SELECT Id, Earnest_Money_Sent__c, Earnest_Money_Sent_Date__c
            FROM Transaction__c
            WHERE Id = :dealId
        ];
    }
    /** Installs the in-memory CMDT overrides matching `standardTasks`. */
    private static void applyDefinitionOverrides() {
        ChecklistMigrationService.groupDefsOverride = groupDefs();
        ChecklistMigrationService.taskDefsOverride = itemDefs();
    }

    /** @return Group definitions for A and B. */
    private static List<Task_Group_Def__mdt> groupDefs() {
        return new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(Letter__c = 'A', Group_Name__c = 'Contract Execution',
                Owner_Label__c = 'Legal', Sequence__c = 1, Stage__c = 'Open Contract',
                Conditional__c = false),
            new Task_Group_Def__mdt(Letter__c = 'B', Group_Name__c = 'Earnest Money Wire',
                Owner_Label__c = 'CFO', Sequence__c = 2, Stage__c = 'Open Contract',
                Conditional__c = false)
        };
    }

    /** @return Item definitions matching `standardTasks` exactly, B3 gated behind B2. */
    private static List<Transaction_Task_Def__mdt> itemDefs() {
        return new List<Transaction_Task_Def__mdt>{
            itemDef('A', 1, 'Open title', false, false, null, null),
            itemDef('A', 2, 'Log critical dates', false, false, null, null),
            itemDef('B', 2, WIRE_SUBJECT, true, true, null, null),
            itemDef('B', 3, GATED_SUBJECT, false, false, null, 2)
        };
    }

    /**
     * @param letter    Group letter.
     * @param sequence  Sequence.
     * @param subject   Subject text.
     * @param critical  Is_Critical__c.
     * @param wire      Is_Wire_Verification__c.
     * @param blockedByLetter   Prerequisite group letter, or null for the same group.
     * @param blockedBySequence Prerequisite sequence, or null when not gated.
     * @return An in-memory definition row.
     */
    private static Transaction_Task_Def__mdt itemDef(String letter, Integer sequence,
            String subject, Boolean critical, Boolean wire,
            String blockedByLetter, Integer blockedBySequence) {
        return new Transaction_Task_Def__mdt(
            Group_Letter__c = letter, Sequence__c = sequence, Subject__c = subject,
            Owner_Label__c = 'Legal', Is_Critical__c = critical, Is_Wire_Verification__c = wire,
            Blocked_By_Group_Letter__c = blockedByLetter,
            Blocked_By_Sequence__c = blockedBySequence);
    }

    /** @param dealId Parent deal. @return Four unsaved Tasks matching `itemDefs`. */
    private static List<Task> standardTasks(Id dealId) {
        return new List<Task>{
            buildTask(dealId, GROUP_A, 1, 'Open title', false),
            buildTask(dealId, GROUP_A, 2, 'Log critical dates', true),
            buildTask(dealId, GROUP_B, 2, WIRE_SUBJECT, false),
            buildTask(dealId, GROUP_B, 3, GATED_SUBJECT, false)
        };
    }

    /** @param dealId Parent deal. */
    private static void insertStandardTasks(Id dealId) {
        insert standardTasks(dealId);
    }

    /**
     * @param dealId    Parent deal.
     * @param taskGroup Task_Group__c value - a real restricted picklist member.
     * @param sequence  Task_Sequence__c.
     * @param subject   Subject.
     * @param closed    Whether to create it Completed.
     * @return An unsaved checklist Task.
     */
    private static Task buildTask(Id dealId, String taskGroup, Integer sequence, String subject,
            Boolean closed) {
        return new Task(
            Subject = subject,
            Status = closed ? 'Completed' : 'Not Started',
            Priority = 'Normal',
            ActivityDate = Date.today().addDays(14),
            Transaction_Deal__c = dealId,
            Task_Group__c = taskGroup,
            Task_Sequence__c = sequence,
            Task_Owner_Label__c = 'Legal',
            Conditional__c = false,
            Verbal_Verification_Completed__c = false
        );
    }

    /** @param index Position in the deterministic ordering. @return That scaffold deal. */
    private static Transaction__c dealAt(Integer index) {
        return allDeals()[index];
    }

    /** @return Both scaffold deals, ordered deterministically. */
    private static List<Transaction__c> allDeals() {
        return [
            SELECT Id, Checklist_Fanned_Out__c, Tasks_Total__c
            FROM Transaction__c
            ORDER BY Contract_Value__c
        ];
    }

    /**
     * @param dealId The deal to reload.
     * @return It, carrying EVERY field the callers of this helper read. A narrower SELECT throws
     *         SObjectException at the assertion, which then reads as a logic failure.
     */
    private static Transaction__c reloaded(Id dealId) {
        return [
            SELECT Id, Checklist_Fanned_Out__c, Tasks_Total__c, Tasks_Complete__c,
                   Tasks_Overdue__c, Wire_Open_Risks__c
            FROM Transaction__c
            WHERE Id = :dealId
        ];
    }

    /** @param dealId The deal. @return Its persisted items, with every asserted field. */
    private static List<Checklist_Item__c> itemsFor(Id dealId) {
        return [
            SELECT Id, Sequence__c, Subject__c, Flag__c, Blocked_By__c, Is_Prerequisite_Met__c,
                   Is_Critical__c, Is_Wire_Verification__c, Completed_By__c,
                   Completed_DateTime__c, Due_Date__c, Comment__c, Checklist__r.Group_Letter__c
            FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c = :dealId
        ];
    }

    /** @param dealId The deal. @return Its items keyed by coordinate, e.g. B3. */
    private static Map<String, Checklist_Item__c> itemsByCoordinate(Id dealId) {
        Map<String, Checklist_Item__c> byCoordinate = new Map<String, Checklist_Item__c>();
        for (Checklist_Item__c item : itemsFor(dealId)) {
            byCoordinate.put(
                item.Checklist__r.Group_Letter__c + String.valueOf(item.Sequence__c.intValue()),
                item);
        }
        return byCoordinate;
    }

    /**
     * @param result    The outcome to search.
     * @param checkName The check name expected.
     * @return true when a finding carries that name.
     */
    private static Boolean hasFinding(ChecklistMigrationService.MigrationResult result,
            String checkName) {
        for (ChecklistMigrationDomain.Discrepancy finding : result.discrepancies) {
            if (finding.checkName == checkName) {
                return true;
            }
        }
        return false;
    }

    /**
     * @param result The outcome.
     * @return Its findings rendered, so a failed assertion says WHY rather than just showing a
     *         mismatched string.
     */
    private static String discrepancyText(ChecklistMigrationService.MigrationResult result) {
        List<String> rendered = new List<String>();
        for (ChecklistMigrationDomain.Discrepancy finding : result.discrepancies) {
            rendered.add(String.valueOf(finding.impact) + ' ' + finding.checkName + ' '
                + finding.coordinate + ' tasks=' + finding.taskValue
                + ' items=' + finding.itemValue);
        }
        return 'outcome=' + result.outcome + ' findings: ' + String.join(rendered, ' | ');
    }
}
