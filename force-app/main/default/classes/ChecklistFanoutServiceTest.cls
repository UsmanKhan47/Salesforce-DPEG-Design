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
            SELECT Checklist_Fanned_Out__c, Tasks_Total__c, Wire_Open_Risks__c
            FROM Transaction__c WHERE Id = :deal.Id
        ];
        // ⚠ AMENDED 2026-09-03 (M5). A second assertion stood here: that the LEGACY guard
        // `Tasks_Fanned_Out__c` was STILL TRUE after this fan-out, which proved the checklist
        // fan-out ran to completion despite the other model's flag being set — i.e. that it is
        // keyed on Checklist_Fanned_Out__c and on nothing else. That field is deleted at M5, so
        // the assertion could not survive. It was NOT dropped: the same property is now proved,
        // without a second flag to lean on, by
        // `guardIsKeyedOnTheFlagAloneNotOnPreExistingChecklists` below. Read that test before
        // deleting either of them — the pair is the guard's only two-sided discriminator.
        Assert.isTrue(reloaded.Checklist_Fanned_Out__c, 'The NEW guard must be set');
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

    /**
     * 🔴 THE ONLY TEST IN THE SUITE THAT NEEDS A REAL `Contract_Executed_Date__c`, AND THEREFORE
     * THE ONLY ONE THAT CANNOT USE THE FACTORY DEAL AS-IS (changed 2026-09-03, A7).
     *
     * `buildItem` derives `Due_Date__c` from the deal's `Contract_Executed_Date__c`, and
     * `TestDataFactory.createTransactionsOnChecklistModel` now NULLS that field - that null is what
     * suppresses `flows/Transaction_Task_Fanout`, which since A7 fires
     * `ChecklistFanoutService` on `Contract_Executed_Date__c != null AND
     * Checklist_Fanned_Out__c = false`. Restoring the date here re-opens the first half of that
     * criteria, so the second half is closed instead: the deal is inserted ALREADY CLAIMED, which
     * the flow's entry filter excludes, and `bypassDedupe` re-opens the service's own guard so
     * `fanOutNow` still builds. Same seam, same reason, as
     * `OnboardingFanoutServiceTest` and `TaskFanoutServiceTest` use on their fan-outs.
     *
     * Do NOT "simplify" this back to a plain factory call plus a post-insert date update: an update
     * that sets the date on an unclaimed deal is a record changing INTO the flow's criteria, which
     * is a second, async fan-out racing this one.
     */
    @isTest
    static void seedsTheFlagAndTheWireMarkersFromTheDefinition() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, false)[0];
        deal.Contract_Executed_Date__c = Date.today(); // Day 0 for the offset arithmetic below
        deal.Checklist_Fanned_Out__c = true;           // closes the flow's second entry filter
        insert deal;

        Test.startTest();
        ChecklistFanoutService.bypassDedupe = true;    // ...and re-opens the service's own guard
        try {
            ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        } finally {
            ChecklistFanoutService.bypassDedupe = false;
        }
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

    /**
     * 🔴 THE REPLACEMENT GUARD-INDEPENDENCE PROOF, ADDED 2026-09-03 (M5). THE FAN-OUT IS KEYED ON
     * `Checklist_Fanned_Out__c` AND ON NOTHING ELSE — AND THAT MUST STAY PINNED SOMEWHERE.
     *
     * Until M5 that property was pinned by `createsChecklistsAndItemsForALoanDeal`, which asserted
     * the LEGACY `Tasks_Fanned_Out__c` was still TRUE after a successful checklist fan-out: the
     * fan-out had run to completion with the OTHER model's flag set, so it provably was not reading
     * it. `Tasks_Fanned_Out__c` was deleted at M5 (it is the legacy Task model's one-shot guard and
     * nothing writes it any more), which removed the only second flag available to lean on.
     *
     * ⚠ LOSING THAT ASSERTION WITHOUT A REPLACEMENT WOULD HAVE BEEN A SILENT COVERAGE LOSS, NOT A
     * TIDY-UP. `isIdempotentBehindTheChecklistGuard` above proves the guard STOPS a second run, but
     * it cannot say WHAT the guard reads: a service that instead short-circuited on "does this deal
     * already have Checklist__c rows?" would pass it identically. That alternative is not
     * hypothetical — it is the obvious refactor a future reader would reach for, and it would break
     * `reconcile`, which deliberately re-enters deals that already HAVE checklists.
     *
     * SO THIS TEST FALSIFIES EXACTLY THAT: it fans a deal out, leaves all 2 checklists in place, and
     * flips ONLY the flag back to false. If the guard reads the flag, PASS 1 re-enters and builds a
     * second set of groups. If it reads row existence, nothing happens and this test reds.
     * Together with `isIdempotentBehindTheChecklistGuard` (flag true -> refuses) this is a
     * two-sided discriminator on one named field, which is what the deleted assertion provided.
     *
     * ⚠ Duplicate checklists are the EXPECTED outcome here and are not a defect being enshrined —
     * clearing the guard by hand is not a supported operation; it is the mutation that makes the
     * key observable. Nothing in production clears this flag (see `ChecklistFanoutService`'s header
     * and the field's own description: single-writer by construction).
     */
    @isTest
    static void guardIsKeyedOnTheFlagAloneNotOnPreExistingChecklists() {
        useTestDefinitions();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        update new Transaction__c(Id = deal.Id, Loan_Required__c = true);

        Test.startTest();
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        Integer afterFirstRun = [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id];

        // POSITIVE CONTROL: without this, a fixture that built nothing would let the assertion
        // below pass for the wrong reason (0 -> 0 is not "the flag was not read", it is "nothing
        // ever worked").
        Assert.areEqual(2, afterFirstRun,
            'PRECONDITION: the first fan-out built both groups. If this is not 2 the mutation '
            + 'below proves nothing.');

        // THE MUTATION: rows stay, flag goes. Nothing else about the deal changes.
        update new Transaction__c(Id = deal.Id, Checklist_Fanned_Out__c = false);
        ChecklistFanoutService.fanOutNow(new List<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(4, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :deal.Id],
            'With the flag cleared and the checklists left in place, the fan-out must re-enter and '
            + 'build a second set. A result of 2 means the dedupe guard is reading ROW EXISTENCE '
            + 'rather than Checklist_Fanned_Out__c — which would also break reconcile(), whose '
            + 'whole job is to re-enter deals that already have checklists.');
        Assert.isTrue([SELECT Checklist_Fanned_Out__c FROM Transaction__c WHERE Id = :deal.Id]
                .Checklist_Fanned_Out__c,
            'And PASS 4 re-armed the flag, so the deal is not left permanently re-fannable.');
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

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE 2026-09-02 DAY-0 ROLLUP SHARING FIX — ITEM 2' (Finding B re-scope). See
    // agent-output/design-rollup-sharing-fix.md §0 Finding B and §2.3, and
    // ChecklistFanoutService.FanoutWrites's own header for the full argument.
    //
    // This is PRE-EMPTIVE — Checklist_Fanned_Out__c is false on every deal today and the Flow is
    // not repointed to this model until M3 — but it is evidence-based, not speculative: the
    // SIBLING model on the SAME chain, with the SAME `with sharing` + `SYSTEM_MODE` shape and the
    // SAME principal, was MEASURED failing on 2026-09-02 (AsyncApexJob 707iw0000046Rh6AAE). A deal
    // born on this model after M3 would fail at PASS 1 for a cause already observed on the model
    // it replaces.
    //
    // ✅ UNLIKE THE TASK MODEL, NO READ MOVES HERE. The four counters come from DealTally — rows
    // this method builds in memory from selectForChecklistFanout's own read, which is COMPLETE for
    // any principal who can read the deal (Checklist__c / Checklist_Item__c are ControlledByParent
    // with no OwnerId at all). So this control needs no positive-control companion the way
    // TaskRollupServiceTest's does: there is no read-side asymmetry for a broken fixture to hide
    // behind — a wrong number here can only mean the WRITE was refused.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 REAL DEPLOYED CMDT (11 groups / 82 items), NOT the scaled-down `useTestDefinitions()`
     * override used by every other test in this file — the design's stated 82/Wire_Open_Risks__c
     * numbers are production values, not fixture-chosen ones. Deal OWNED by `ownerUser`, fanned
     * out by `driverUser`, who holds Read (not Edit) via `DPEG_Transaction_View` — the identical
     * persona shape as `TaskRollupServiceTest`'s and `TaskFanoutServiceTest`'s non-owner controls.
     *
     * HOW THIS GOES RED WITHOUT THE FIX: revert `ChecklistFanoutService.FanoutWrites` so PASS 1's
     * `Database.insert(checklists, ...)` runs plain `SYSTEM_MODE` with no `without sharing`
     * escape -> it throws `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY` for a driver with
     * Read-not-Edit on the master `Transaction__c` (`writeRequiresMasterRead=false` requires Edit
     * on the master to insert the detail), and nothing after PASS 1 ever runs — zero Checklist__c,
     * zero Checklist_Item__c, `Checklist_Fanned_Out__c` stays false. That failure landing at
     * PASS 1 rather than PASS 4 is the proof that Finding B's re-scope
     * (`ChecklistFanoutService`, not `ChecklistRollupService`) is where the M3 blocker actually
     * lives.
     */
    @isTest
    static void fanOutNow_nonOwnerDriver_11Checklists82Items_pinsFinding2Preemptively() {
        // Canary — see TaskFanoutServiceTest.testFanOut_bulk251_chunksAsyncAtProductionDefCount
        // for the identical guard and why a silent CMDT-loader gap must fail loudly here rather
        // than just produce a smaller, still-green number.
        Assert.areEqual(11, [SELECT COUNT() FROM Task_Group_Def__mdt],
            'Assumes the 11 deployed Task_Group_Def__mdt records (scripts/load-task-group-defs.apex); '
            + 're-run the loader if this fails.');
        Assert.areEqual(82, [SELECT COUNT() FROM Transaction_Task_Def__mdt],
            'Assumes the 82 deployed Transaction_Task_Def__mdt records '
            + '(scripts/load-transaction-task-defs.apex); re-run the loader if this fails.');

        User ownerUser = TestDataFactory.createStandardUserNoFls('cklShrOwn');
        User driverUser = TestDataFactory.createStandardUserNoFls('cklShrDrv');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ ownerUser, driverUser };
            // Read, not Edit — the exact production shape (DPEG_Transaction_View: allowEdit=false,
            // viewAllRecords=true, modifyAllRecords=false).
            TestDataFactory.assignPermissionSets(driverUser.Id, new Set<String>{ 'DPEG_Transaction_View' });
        }

        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, false)[0];
        deal.OwnerId = ownerUser.Id;
        deal.Loan_Required__c = true; // every group applies, including the conditional Financing group
        insert deal;
        Id dealId = deal.Id;

        // 🔴 FIXTURE GUARD.
        System.runAs(driverUser) {
            UserRecordAccess access = [
                SELECT RecordId, HasReadAccess, HasEditAccess
                FROM UserRecordAccess
                WHERE UserId = :UserInfo.getUserId() AND RecordId = :dealId
            ];
            Assert.isTrue(access.HasReadAccess,
                'FIXTURE PRECONDITION: driverUser must be able to READ the deal.');
            Assert.isFalse(access.HasEditAccess,
                '🔴 FIXTURE PRECONDITION: driverUser must NOT be able to EDIT the deal — the exact '
                + 'production shape. If true, every assertion below is vacuous.');
        }

        Test.startTest();
        System.runAs(driverUser) {
            ChecklistFanoutService.fanOutNow(new List<Id>{ dealId });
        }
        Test.stopTest();

        Assert.areEqual(11, [SELECT COUNT() FROM Checklist__c WHERE Transaction__c = :dealId],
            '0 here means PASS 1 was refused for a driver with Read-not-Edit on the deal — the '
            + '`without sharing` escalation (FanoutWrites) is missing or reverted.');
        Assert.areEqual(82,
            [SELECT COUNT() FROM Checklist_Item__c WHERE Checklist__r.Transaction__c = :dealId],
            'PASS 2 (item insert) never runs if PASS 1 was refused, so this is the same '
            + 'discriminator one statement later.');

        Transaction__c reloaded = [
            SELECT Checklist_Fanned_Out__c, Tasks_Total__c, Wire_Open_Risks__c
            FROM Transaction__c WHERE Id = :dealId
        ];
        Assert.isTrue(reloaded.Checklist_Fanned_Out__c,
            'PASS 4 must complete under the non-owner driver too — this is the checklist model\'s '
            + 'counterpart to the FanoutFlagWrites escape the retired TaskFanoutService carried.');
        Assert.areEqual(82, reloaded.Tasks_Total__c, 'All 82 items counted across both groups.');
        Assert.areEqual(2, reloaded.Wire_Open_Risks__c,
            'B2 and I7 are the two Is_Wire_Verification__c items in the real deployed definitions '
            + '(scripts/load-transaction-task-defs.apex).');
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
