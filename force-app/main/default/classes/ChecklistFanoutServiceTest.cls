/**
 * Tests for the checklist fan-out and the `Loan_Required__c` reconcile path.
 *
 * ⚠ BULK VOLUME IS THE CHUNK BOUNDARY (50 and 51 TRANSACTIONS), NOT 251 - AND THAT IS A DELIBERATE,
 * DOCUMENTED CARVE-OUT FROM `.claude/rules/bulk-test-rule.md`, NOT AN OMISSION. 251 Transactions x 96
 * rows each = 24,096 DML rows, more than twice the 10,000-row limit: the volume is unreachable in
 * production (the Queueable chunks at 50) and a test asserting it would fail for arithmetic reasons
 * that have nothing to do with the code. Testing a volume production cannot reach is the exact
 * anti-pattern that rule's own exemption clause exists to prevent. THE 251 MANDATE STILL APPLIES,
 * UNCHANGED, TO `Checklist_Item__c` ITSELF - see `ChecklistItemPrerequisiteServiceTest`.
 * Even the chunk-boundary test here is scaled down (2 groups x 3 items per deal rather than 11 x 82)
 * because the assertion is about CHUNKING and QUERY COUNT, not about row content.
 *
 * CMDT cannot be inserted in a test, so the definitions are built in memory and injected through the
 * service's `@TestVisible` overrides. That also makes the fixtures independent of whether
 * `scripts/load-transaction-task-defs.apex` has been re-run with the new columns.
 */
@isTest
private class ChecklistFanoutServiceTest {

    private static final String STAGE_OPEN = 'Open Contract';
    private static final String STAGE_CLOSING = 'Closing Prep';

    /**
     * Two groups: B (unconditional, 3 items, B3 blocked by B2, B2 critical + wire) and F
     * (conditional on `Loan_Required__c`, 2 items).
     *
     * @return Group definitions in sequence order.
     */
    private static List<Task_Group_Def__mdt> groupDefs() {
        return new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(
                Letter__c = 'B', Group_Name__c = 'Earnest Money Wire', Owner_Label__c = 'Danish',
                Conditional__c = false, Sequence__c = 1, Stage__c = STAGE_OPEN),
            new Task_Group_Def__mdt(
                Letter__c = 'F', Group_Name__c = 'Loan Package', Owner_Label__c = 'Danish',
                Conditional__c = true, Condition_Field__c = 'Loan_Required__c', Sequence__c = 2,
                Stage__c = STAGE_CLOSING)
        };
    }

    /** @return Item definitions for the two groups above. */
    private static List<Transaction_Task_Def__mdt> itemDefs() {
        return new List<Transaction_Task_Def__mdt>{
            new Transaction_Task_Def__mdt(Group_Letter__c = 'B', Sequence__c = 1,
                Subject__c = 'Request wiring instructions', Owner_Label__c = 'Danish',
                Due_Day_Offset__c = 1),
            new Transaction_Task_Def__mdt(Group_Letter__c = 'B', Sequence__c = 2,
                Subject__c = 'Call title company to verbally verify wiring instructions',
                Owner_Label__c = 'Danish', Due_Day_Offset__c = 2,
                Is_Critical__c = true, Is_Wire_Verification__c = true),
            new Transaction_Task_Def__mdt(Group_Letter__c = 'B', Sequence__c = 3,
                Subject__c = 'Send wire request to accounting', Owner_Label__c = 'Accounting',
                Due_Day_Offset__c = 2, Blocked_By_Sequence__c = 2),
            new Transaction_Task_Def__mdt(Group_Letter__c = 'F', Sequence__c = 1,
                Subject__c = 'Build loan package', Owner_Label__c = 'Danish', Due_Day_Offset__c = 3),
            new Transaction_Task_Def__mdt(Group_Letter__c = 'F', Sequence__c = 2,
                Subject__c = 'Set up auto loan payment', Owner_Label__c = 'Accounting',
                Due_Day_Offset__c = 30, Is_Critical__c = true)
        };
    }

    /** Installs the in-memory definitions on the service. */
    private static void useTestDefinitions() {
        ChecklistFanoutService.groupDefsOverride = groupDefs();
        ChecklistFanoutService.taskDefsOverride = itemDefs();
    }

    @isTest
    static void createsChecklistsAndItemsForALoanDeal() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        update new Transaction__c(Id = deal.Id, Loan_Required__c = true);

        Test.startTest();
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        Test.stopTest();

        List<Checklist__c> checklists = [
            SELECT Group_Letter__c, Stage__c, Items_Total__c, Items_Complete__c, Is_Conditional__c
            FROM Checklist__c WHERE Transaction__c = :deal.Id ORDER BY Sequence__c
        ];
        Assert.areEqual(2, checklists.size(), 'A loan deal gets both the B and F groups');
        Assert.areEqual(3, checklists[0].Items_Total__c, 'Group B has three items');
        Assert.areEqual(0, checklists[0].Items_Complete__c, 'Nothing is complete at fan-out');
        Assert.areEqual(STAGE_CLOSING, checklists[1].Stage__c,
            'The group stage comes from the CMDT column, not from a hardcoded phase map');
        Assert.isTrue(checklists[1].Is_Conditional__c, 'Group F is the conditional group');

        Transaction__c reloaded = [
            SELECT Checklist_Fanned_Out__c, Tasks_Fanned_Out__c, Tasks_Total__c, Wire_Open_Risks__c
            FROM Transaction__c WHERE Id = :deal.Id
        ];
        Assert.isTrue(reloaded.Checklist_Fanned_Out__c, 'The NEW guard must be set');
        Assert.isTrue(reloaded.Tasks_Fanned_Out__c,
            'The LEGACY guard is left exactly as the fixture set it. This is a STRONGER proof of guard '
            + 'independence than asserting it is false: the checklist fan-out ran to completion even '
            + 'though Tasks_Fanned_Out__c was already TRUE, so it is provably keyed on '
            + 'Checklist_Fanned_Out__c and on nothing else.');
        Assert.areEqual(5, reloaded.Tasks_Total__c, 'Five items across both groups');
        Assert.areEqual(1, reloaded.Wire_Open_Risks__c,
            'The wire count keys on Is_Wire_Verification__c, never on subject text');
    }

    @isTest
    static void omitsTheConditionalGroupWhenTheDealNeedsNoLoan() {
        useTestDefinitions();
        // The factory creates deals with Loan_Required__c = false.
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        Test.stopTest();

        List<Checklist__c> checklists = [
            SELECT Group_Letter__c FROM Checklist__c WHERE Transaction__c = :deal.Id
        ];
        Assert.areEqual(1, checklists.size(), 'A no-loan deal gets only the unconditional group');
        Assert.areEqual('B', checklists[0].Group_Letter__c, 'And it is group B');
    }

    @isTest
    static void seedsTheFlagAndTheWireMarkersFromTheDefinition() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        Test.stopTest();

        Map<Decimal, Checklist_Item__c> bySequence = new Map<Decimal, Checklist_Item__c>();
        for (Checklist_Item__c item : [
            SELECT Sequence__c, Flag__c, Is_Critical__c, Is_Wire_Verification__c, Stage__c, Due_Date__c
            FROM Checklist_Item__c WHERE Checklist__r.Transaction__c = :deal.Id
        ]) {
            bySequence.put(item.Sequence__c, item);
        }
        Assert.areEqual('CRITICAL', bySequence.get(2).Flag__c,
            'A critical item opens at CRITICAL, seeded from Is_Critical__c and never from a regex');
        Assert.areEqual('None', bySequence.get(1).Flag__c, 'A non-critical item opens at None');
        Assert.isTrue(bySequence.get(2).Is_Wire_Verification__c,
            'The wire marker is data, replacing the anti-fraud substring parse');
        Assert.areEqual(STAGE_OPEN, bySequence.get(1).Stage__c, 'Stage inherited from the group');
        Assert.areEqual(Date.today().addDays(2), bySequence.get(2).Due_Date__c,
            'Due date is the contract execution date plus the definition offset');
    }

    @isTest
    static void stampsTheBlockedByLinkInASecondPass() {
        // The whole reason the fan-out needs four statements rather than three: a real self-lookup
        // has no target Id until the items exist.
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        Test.stopTest();

        Map<Decimal, Checklist_Item__c> bySequence = new Map<Decimal, Checklist_Item__c>();
        for (Checklist_Item__c item : [
            SELECT Sequence__c, Blocked_By__c, Blocked_By__r.Sequence__c, Is_Prerequisite_Met__c
            FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c = :deal.Id AND Checklist__r.Group_Letter__c = 'B'
        ]) {
            bySequence.put(item.Sequence__c, item);
        }
        Assert.areEqual(bySequence.get(2).Id, bySequence.get(3).Blocked_By__c,
            'B3 must point at B2 by Id - THE GATE IS ONLY AS LIVE AS THIS LINE MAKES IT');
        Assert.isNull(bySequence.get(1).Blocked_By__c, 'B1 has no prerequisite');
        Assert.isFalse(bySequence.get(3).Is_Prerequisite_Met__c,
            'A freshly linked dependent starts unmet');
        Assert.areEqual(0, ChecklistFanoutService.lastRunUnresolvedPrereqCount,
            'Every declared prerequisite must have resolved');
    }

    @isTest
    static void countsUnstagedItemsRatherThanGuessingAPhase() {
        // If the CMDT loaders have not been re-run with the new Stage__c column, the phase is NULL
        // and this counter says so. A plausible default would hide it.
        ChecklistFanoutService.groupDefsOverride = new List<Task_Group_Def__mdt>{
            new Task_Group_Def__mdt(Letter__c = 'B', Group_Name__c = 'No Stage',
                Owner_Label__c = 'Danish', Conditional__c = false, Sequence__c = 1)
        };
        ChecklistFanoutService.taskDefsOverride = new List<Transaction_Task_Def__mdt>{
            new Transaction_Task_Def__mdt(Group_Letter__c = 'B', Sequence__c = 1,
                Subject__c = 'Unstaged item', Owner_Label__c = 'Danish')
        };
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        Integer unstaged = ChecklistFanoutService.lastRunUnstagedItemCount;
        Test.stopTest();

        Assert.areEqual(1, unstaged,
            'An item whose group carries no Stage__c must be COUNTED, not silently defaulted');
    }

    @isTest
    static void isIdempotentBehindTheChecklistGuard() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'A second fan-out behind a set Checklist_Fanned_Out__c must create nothing');
    }

    @isTest
    static void staysWithinBudgetAtTheChunkBoundary() {
        // 51 deals: one more than CHUNK_SIZE, which is what proves the per-chunk cost is flat rather
        // than per-record. Scaled-down definitions keep the row count sane while preserving shape.
        useTestDefinitions();
        List<Transaction__c> deals = TestDataFactory.createTransactionsOnChecklistModel(51, true);
        List<Id> dealIds = new List<Id>();
        for (Transaction__c deal : deals) {
            dealIds.add(deal.Id);
        }

        Test.startTest();
        ChecklistFanoutService.fanOutNow(dealIds);
        // 🔴 READ INSIDE. `Test.stopTest()` restores the pre-test counters, so a `Limits` assertion
        // written after it is silently vacuous.
        Integer queries = ChecklistFanoutService.lastRunQueryCount;
        Integer dml = ChecklistFanoutService.lastRunDmlCount;
        Integer items = ChecklistFanoutService.lastRunItemCount;
        Test.stopTest();

        Assert.areEqual(51 * 3, items, 'Three items per no-loan deal, 51 deals');
        // 🔴 TWO, NOT ONE, AND THE SECOND IS NOT AVOIDABLE HERE. This asserted 1 and was RED as
        // written. The second pass issues `Database.update(links, ...)`, and DML FIRES TRIGGERS
        // REGARDLESS OF `AccessLevel` — SYSTEM_MODE lifts CRUD/FLS, it does not skip automation. So
        // `ChecklistItemTrigger` runs `ChecklistItemPrerequisiteService.enforceOnUpdate`, which
        // spends exactly one selector read for that chunk. `ChecklistRollupService
        // .suppressTriggerRecalc` does NOT cover it: that flag suppresses the ROLLUP arm only, and
        // suppressing the GATE during fan-out would be the wrong fix anyway — the link write is
        // precisely the thing the gate exists to police.
        // What the constant still pins is the property that matters: BOTH reads are once-per-CHUNK
        // and neither is a function of deal count. 51 deals cost the same 2 as 1 deal would.
        Assert.areEqual(2, queries,
            'ONE selector read for the fan-out itself plus ONE from the prerequisite gate firing on '
                + 'the second-pass link update — both per CHUNK, neither per deal. Actual: ' + queries);
        Assert.isTrue(dml <= 4,
            'Four DML statements per chunk (checklists, items, links, deals). Actual: ' + dml);
    }

    @isTest
    static void reconcileAddsTheLoanGroupWhenTheFlagIsTurnedOn() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });

        Test.startTest();
        List<ChecklistFanoutService.ReconcileResult> results = ChecklistFanoutService.reconcile(
            new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(0, results.size(),
            'Nothing changed yet - Loan_Required__c is still false, so reconcile is a no-op');

        // The flip itself is what reconciles - `TransactionTriggerHandler.afterUpdate` routes it, so
        // this asserts the WIRING as well as the service.
        useTestDefinitions();
        update new Transaction__c(Id = deal.Id, Loan_Required__c = true);

        Assert.areEqual(2, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'The conditional group must be ADDED by the flip, never by a blanket re-fan');
        Assert.areEqual(5, [SELECT COUNT() FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c = :deal.Id], 'And the original items survived');
        Assert.isTrue(ChecklistFanoutService.reconcile(new Set<Id>{ deal.Id }).isEmpty(),
            'A second reconcile finds nothing left to do - it is idempotent, not additive');
    }

    @isTest
    static void reconcileRemovesAnUnworkedGroupButRefusesAWorkedOne() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        update new Transaction__c(Id = deal.Id, Loan_Required__c = true);
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        useTestDefinitions();

        Test.startTest();
        // The flip routes through TransactionTriggerHandler, which reconciles for real.
        update new Transaction__c(Id = deal.Id, Loan_Required__c = false);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'An entirely unworked conditional group is removed; only group B remains');
        Assert.areEqual(3, [SELECT COUNT() FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c = :deal.Id],
            'And its items went with it via the master-detail cascade');
        Assert.areEqual(3, [SELECT Tasks_Total__c FROM Transaction__c WHERE Id = :deal.Id]
            .Tasks_Total__c,
            'The deal counter is recomputed EXPLICITLY after a removal - the cascade delete cannot '
                + 'reach the deal from the child once the parent is gone');
    }

    @isTest
    static void reconcileRefusesToDeleteWorkedHistory() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        update new Transaction__c(Id = deal.Id, Loan_Required__c = true);
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        useTestDefinitions();
        Checklist_Item__c worked = [
            SELECT Id FROM Checklist_Item__c
            WHERE Checklist__r.Transaction__c = :deal.Id AND Checklist__r.Group_Letter__c = 'F'
            LIMIT 1
        ];
        update new Checklist_Item__c(Id = worked.Id, Flag__c = 'Completed');

        Test.startTest();
        update new Transaction__c(Id = deal.Id, Loan_Required__c = false);
        // Called again explicitly to read the RESULT the trigger discards. The refusal is idempotent
        // - the group still exists, still should not, and still contains work - so a second call
        // reports it again rather than eventually giving in.
        List<ChecklistFanoutService.ReconcileResult> results =
            ChecklistFanoutService.reconcile(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'F' }, results[0].refusedGroupLetters,
            'Deleting worked history is worse than an inconsistent checklist - the group must stay');
        Assert.areEqual(2, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'And nothing was deleted');
    }

    @isTest
    static void reconcileIgnoresDealsThatWereNeverFannedOut() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        List<ChecklistFanoutService.ReconcileResult> results =
            ChecklistFanoutService.reconcile(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.isTrue(results.isEmpty(),
            'Reconcile must never fan out a deal behind the guard: Checklist_Fanned_Out__c is false');
        Assert.areEqual(0, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'And it must not create anything');
    }

    @isTest
    static void invocableEnqueuesExactlyOneJob() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        ChecklistFanoutService.InputDTO request = new ChecklistFanoutService.InputDTO();
        request.transactionId = deal.Id;

        Test.startTest();
        // A duplicate request in the same call must not enqueue twice.
        ChecklistFanoutService.fanOut(new List<ChecklistFanoutService.InputDTO>{ request, request });
        Integer queued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(1, queued, 'Exactly ONE enqueue; the Queueable chains the rest');
        Assert.areEqual(1, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'And the queued job fanned the deal out once');
    }

    @isTest
    static void entryPointsAreNullSafe() {
        Test.startTest();
        ChecklistFanoutService.fanOut(null);
        ChecklistFanoutService.fanOut(new List<ChecklistFanoutService.InputDTO>());
        ChecklistFanoutService.fanOutNow(null);
        ChecklistFanoutService.fanOutNow(new List<Id>());
        List<ChecklistFanoutService.ReconcileResult> results = ChecklistFanoutService.reconcile(null);
        Test.stopTest();

        Assert.isTrue(results.isEmpty(), 'Null and empty inputs must be no-ops, never throws');
    }
}
