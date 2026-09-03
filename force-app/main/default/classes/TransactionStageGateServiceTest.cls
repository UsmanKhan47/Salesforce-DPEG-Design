/**
 * Tests for the stage-advancement gate on `Transaction__c`
 * (`TransactionStageGateService`, `ChecklistItemSelector.selectOpenForStageGate`,
 * `TransactionTriggerHandler.beforeUpdate`'s second arm). Design
 * `agent-output/design-checklist-cutover-and-stage-gate.md` Part B.
 *
 * layer=test.
 *
 * =============================================================================================
 * THE FIXTURE TRAP THIS SUITE EXISTS TO NOT FALL INTO
 * =============================================================================================
 * `TestDataFactory.createTransactionsOnChecklistModel` does NOT set `Checklist_Fanned_Out__c`,
 * despite its name. (Until M5, 2026-09-03, it set `Tasks_Fanned_Out__c` — the LEGACY guard — which
 * made the trap easier to fall into; that field is now deleted and the factory sets no guard flag
 * at all. The trap itself is UNCHANGED: the factory still leaves deals UNCLAIMED, deliberately.)
 * The gate fails OPEN on any deal where `Checklist_Fanned_Out__c != true`. Every fixture in this
 * class that is meant to be GATED sets `Checklist_Fanned_Out__c = true` EXPLICITLY via the
 * `claimedDeal` helper below - never relies on the factory alone. A "must refuse" test built only
 * on the factory would leave the deal unclaimed, refuse nothing, and pass while measuring nothing.
 * `TestDataFactory.createChecklists` / `createChecklistItems` also both stamp
 * `Stage__c = 'Open Contract'` on every row unconditionally, so any group at another stage (or at
 * no stage) is built with `buildGroup` / `buildItems` below, which override it explicitly.
 *
 * ⚠ 2026-09-03: that factory now ALSO nulls `Contract_Executed_Date__c`, and `tBulk1` below is the
 * test that depends on it. A7 repointed `flows/Transaction_Task_Fanout` onto
 * `ChecklistFanoutService` with the entry filter `Contract_Executed_Date__c != null AND
 * Checklist_Fanned_Out__c = false`, and `doesRequireRecordChangedToMeetCriteria` does not apply on
 * INSERT - so without the null date `tBulk1`'s 251 UNCLAIMED deals would each enqueue a checklist
 * fan-out, which both blows the row budget and destroys the "unclaimed" premise the test measures.
 * The suppression is deliberately NOT `Checklist_Fanned_Out__c = true`: that is the very flag N7a
 * and `tBulk1` need to be false.
 *
 * =============================================================================================
 * THE THREE MANDATORY PAIRS - NEITHER HALF OF ANY PAIR IS THE TEST ON ITS OWN
 * =============================================================================================
 *   N5a / N5b - the isDone pair. N5a (one item Verified rather than Completed, still ALLOWED)
 *       reds if `isDone` is ever replaced with `Flag__c == 'Completed'`. N5b (one item CRITICAL,
 *       REFUSED) is what excludes an always-allow gate from passing N5a for the wrong reason.
 *   N6a / N6b - the anti-hardcode pair, at REAL group sizes taken from the CMDT-derived spread
 *       (A6 B5 C7 D5 E6 F12 G6 H5 H2:5 I10 J15 = 82; Due Diligence = C+D+E+G+H+H2 = 34, +F(12
 *       loan-only) = 46 - `agent-output/design-checklist-cutover-and-stage-gate.md` A0.1/A3).
 *       N6a (no-loan, 34 done, ALLOWED) reds a gate hardcoded to 46. N6b (loan, same 34 done, all
 *       12 group-F items open, REFUSED naming "12 of 46") is what N6a alone cannot prove - an
 *       always-allow gate also passes N6a.
 *   N7a / N7b - the fail-open pair. N7a (unclaimed, zero rows, ALLOWED at zero queries) is the
 *       fixture trap above turned into an assertion - it is TRIVIAL to pass by accident if the
 *       gate never fires at all. N7b (the SAME shape, claimed, one open item, REFUSED) is the
 *       existence proof that the gate is actually installed. Without N7b this whole suite could be
 *       green while the gate does nothing.
 *
 * =============================================================================================
 * THE 251 MANDATE, AND ITS ONE CARVE-OUT (.claude/rules/bulk-test-rule.md)
 * =============================================================================================
 * This is a trigger, so 251 is mandatory. `tBulk1...` satisfies it LITERALLY: 251 UNCLAIMED
 * `Transaction__c` rows, cheap to build (one factory insert, no checklist rows at all), forward-
 * moved in one `Database.update`, forcing two before-update chunks (200 + 51).
 *
 * A CLAIMED 251-deal volume test is arithmetically impossible, not merely expensive: 251 deals x
 * 82 real Checklist_Item__c rows/deal = 20,582 rows in ONE insert, against the 10,000-row-per-DML
 * -statement limit. Per `.claude/rules/bulk-test-rule.md`'s own "Exemption: Per-Transaction-
 * Singleton Async Pipelines" reasoning - testing a volume production cannot reach proves nothing
 * and risks tripping an UNRELATED limit instead - `tBulk2...` / `tBulk3...` run the claimed-volume
 * proof at the CHUNK BOUNDARY (25 deals, comfortably under the 200-row before-update chunk size)
 * with a full-size single Open-Contract group per deal, the same device
 * `ChecklistFanoutServiceTest.staysWithinBudgetAtTheChunkBoundary` uses for the identical
 * arithmetic problem on the fan-out itself. 25 was chosen over a smaller number so the mixed-
 * outcome assertion (some deals refused, some allowed, in the SAME chunk) has room to be
 * meaningful; it is still two orders of magnitude under the row count that would be impossible.
 *
 * `tBulk2...` additionally carries a 5-deal CONTROL SET of the identical shape and refusal
 * pattern, updated in its own measured window, so the query cost is asserted as an INVARIANCE
 * ACROSS TWO VOLUMES rather than as a literal. That method's header records why a literal was
 * never achievable for a partial-failure update and why the invariance is the stronger control.
 *
 * =============================================================================================
 * THE FIXTURE FOR AN ANTI-SOQL-IN-LOOP TEST MUST NOT ITSELF BE DML-IN-A-LOOP
 * =============================================================================================
 * `Test.startTest()` hands the measured block a FRESH limit set. Everything before it runs on the
 * test method's OWN 100 SOQL / 150 DML, and every `Checklist_Item__c` DML statement fires
 * `ChecklistItemTrigger` -> `ChecklistItemTriggerHandler.recalcFor` (the suppression flag is FALSE
 * on this path) -> `ChecklistRollupService.recalcForChecklistIds`, which costs 4 SOQL
 * (`ChecklistSelector.selectByIds`, then `recalc`'s `ChecklistSelector.selectByTransactionIds` +
 * `ChecklistItemSelector.selectByTransactionIds` + `TransactionSelector.selectForChecklistFanout`)
 * and 2 DML PER CHUNK - both non-empty here, because `Items_Total__c` moves null->11 and the deal
 * is claimed.
 *
 * `tBulk2`/`tBulk3` originally built their 25 deals in a PER-DEAL LOOP: 8 SOQL/8 DML and
 * 4 SOQL/5 DML per iteration respectively, i.e. 200 SOQL for tBulk2 (a LimitException at roughly
 * iteration 13, before its assertions were ever reached) and EXACTLY 100 SOQL for tBulk3 (green at
 * the ceiling, with zero headroom, one added query away from a red naming nothing to do with this
 * feature). Both fixtures are now hoisted out of the loop: deals, then groups, then EVERY item in
 * one statement, plus (tBulk2 only) one completion update. That is FOUR own DML statements for
 * tBulk2 and THREE for tBulk3; because tBulk2's 330-row item insert and 314-row completion update,
 * and tBulk3's 275-row item insert, each fire the after-trigger in exactly two chunks
 * (200 + 130, 200 + 114, 200 + 75), the cascade adds 8 SOQL and 4 DML apiece.
 * Measured budget before `Test.startTest()`: tBulk2 = 16 SOQL / 12 DML, tBulk3 = 8 SOQL / 7 DML,
 * against 100 / 150.
 *
 * 🔴 THE VOLUME DID NOT DROP AND MUST NOT. tBulk2 still measures 25 claimed deals x 11 items, and
 * now carries a 5-deal control set of the same shape alongside it (30 deals, 330 items). The
 * control adds ROWS to the four statements that already exist - never a fifth statement, and not
 * enough rows to cross a new 200-row trigger chunk in any of them - so the budget above is
 * unchanged by it. The fix is the
 * fixture's SHAPE, which also keeps it honest about how these objects really behave in bulk.
 * `ChecklistRollupService.suppressTriggerRecalc(true)` would also buy the headroom and is
 * deliberately NOT used: it would hide the cascade rather than survive it, and it is not needed.
 * Any future addition to this fixture goes in the same bulk statements, never in a new loop.
 *
 * =============================================================================================
 * GOVERNOR INSTRUMENTATION - READ INSIDE THE METHOD BODY, NEVER AFTER Test.stopTest()
 * =============================================================================================
 * `Test.stopTest()` restores the pre-test governor counters, so a `Limits.getQueries()` read after
 * it is silently vacuous (this repo has paid for that mistake before -
 * `ChecklistFanoutServiceTest.cls:158-161` et al.). Every counter assertion below reads
 * `TransactionStageGateService.lastRun*` INSIDE the `Test.startTest()/stopTest()` block, which is
 * how the service itself measures its own body. The counters are CUMULATIVE ACROSS THE
 * TRANSACTION, not per invocation, so `resetRunCounters()` is called immediately before every
 * measured DML statement and never anywhere else.
 */
@isTest
private class TransactionStageGateServiceTest {

    /**
     * Due Diligence groups EXCLUDING the loan-only group F, at their real sizes: C7 D5 E6 G6 H5
     * H2:5 = 34. Group F (12) is added separately by `addOpenGroupF` so N6a/N6b can include or
     * omit it without duplicating the other six groups.
     */
    private static final Map<String, Integer> DUE_DILIGENCE_NO_LOAN_GROUPS = new Map<String, Integer>{
        'C' => 7, 'D' => 5, 'E' => 6, 'G' => 6, 'H' => 5, 'H2' => 5
    };

    // ── FIXTURE HELPERS ─────────────────────────────────────────────────────────────────────

    /**
     * A deal claimed by the checklist model, at the given stage, inserted in one statement.
     *
     * Delegates to the `doInsert` overload so the single-record call sites below read unchanged.
     */
    private static Transaction__c claimedDeal(String stage, Boolean loanRequired) {
        return claimedDeal(stage, loanRequired, true);
    }

    /**
     * As above, but able to RETURN THE ROW UNSAVED so a volume fixture can insert 25 of them in
     * ONE statement. See the fixture-budget block in the class header: an insert-per-iteration
     * helper is what put `tBulk2` over the pre-`startTest` SOQL ceiling.
     *
     * @param stage        `Transaction__c.Stage__c`, byte-identical to the restricted picklist.
     * @param loanRequired Drives whether group F belongs on the deal.
     * @param doInsert     False to build only.
     * @return The deal, saved or unsaved.
     */
    private static Transaction__c claimedDeal(String stage, Boolean loanRequired, Boolean doInsert) {
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, false)[0];
        deal.Stage__c = stage;
        deal.Checklist_Fanned_Out__c = true;
        deal.Loan_Required__c = loanRequired;
        if (doInsert) {
            insert deal;
        }
        return deal;
    }

    /** A deal at the given stage, NEVER claimed - `Checklist_Fanned_Out__c` left at its default. */
    private static Transaction__c unclaimedDeal(String stage) {
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, false)[0];
        deal.Stage__c = stage;
        insert deal;
        return deal;
    }

    /** One checklist group, letter/stage/sequence all explicit - the factory default is overridden. */
    private static Checklist__c buildGroup(Id dealId, String letter, String stage, Integer sequence) {
        return buildGroup(dealId, letter, stage, sequence, true);
    }

    /**
     * As above, with the insert made optional so a volume fixture can save every group at once.
     *
     * @param dealId   Master-detail parent.
     * @param letter   `Group_Letter__c`, which is half of the item coordinate (`A1`).
     * @param stage    `Checklist__c.Stage__c`. Explicitly nullable - N12 needs a stageless group.
     * @param sequence `Sequence__c`.
     * @param doInsert False to build only.
     * @return The group, saved or unsaved.
     */
    private static Checklist__c buildGroup(
        Id dealId,
        String letter,
        String stage,
        Integer sequence,
        Boolean doInsert
    ) {
        Checklist__c checklistGroup = TestDataFactory.createChecklist(dealId, false);
        checklistGroup.Group_Letter__c = letter;
        checklistGroup.Group_Name__c = 'Test Group ' + letter;
        checklistGroup.Stage__c = stage;
        checklistGroup.Sequence__c = sequence;
        if (doInsert) {
            insert checklistGroup;
        }
        return checklistGroup;
    }

    /** `count` items under one group, all stamped to `stage`, all open (`Flag__c = 'None'`). */
    private static List<Checklist_Item__c> buildItems(Id checklistId, Integer count, String stage) {
        return buildItems(checklistId, count, stage, true);
    }

    /**
     * As above, with the insert made optional.
     *
     * 🔴 THIS IS THE ONE THAT MATTERS FOR THE FIXTURE BUDGET. Every `Checklist_Item__c` DML
     * statement fires `ChecklistItemTrigger` -> `ChecklistItemTriggerHandler.recalcFor` (the
     * suppression flag is FALSE on this path) -> `ChecklistRollupService.recalcForChecklistIds`,
     * which is 4 SOQL and up to 2 DML PER CHUNK. Inserting items once per deal in a 25-iteration
     * loop therefore costs 100 SOQL on its own - the whole pre-`startTest` budget. Building all
     * 275 rows and inserting them ONCE costs 8 SOQL and 5 DML for the same fixture.
     *
     * @param checklistId Master-detail parent.
     * @param count       Number of items.
     * @param stage       `Checklist_Item__c.Stage__c` stamped on every row.
     * @param doInsert    False to build only.
     * @return The items, saved or unsaved.
     */
    private static List<Checklist_Item__c> buildItems(
        Id checklistId,
        Integer count,
        String stage,
        Boolean doInsert
    ) {
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(count, checklistId, false);
        for (Checklist_Item__c item : items) {
            item.Stage__c = stage;
        }
        if (doInsert) {
            insert items;
        }
        return items;
    }

    /** A single Open Contract group (letter A) with `count` items, all left open. */
    private static List<Checklist_Item__c> buildOpenContractItems(Id dealId, Integer count) {
        Checklist__c checklistGroup = buildGroup(dealId, 'A', 'Open Contract', 1);
        return buildItems(checklistGroup.Id, count, 'Open Contract');
    }

    /** Marks every supplied item Completed in one bulk statement. */
    private static void completeAll(List<Checklist_Item__c> items) {
        List<Checklist_Item__c> updates = new List<Checklist_Item__c>();
        for (Checklist_Item__c item : items) {
            updates.add(new Checklist_Item__c(Id = item.Id, Flag__c = 'Completed'));
        }
        update updates;
    }

    /** The real 34-item no-loan Due Diligence checklist (C D E G H H2), every item COMPLETED. */
    private static void buildCompletedDueDiligenceNoLoan(Id dealId) {
        Integer sequence = 1;
        for (String letter : DUE_DILIGENCE_NO_LOAN_GROUPS.keySet()) {
            Checklist__c checklistGroup = buildGroup(dealId, letter, 'Due Diligence', sequence++);
            List<Checklist_Item__c> items = buildItems(
                checklistGroup.Id, DUE_DILIGENCE_NO_LOAN_GROUPS.get(letter), 'Due Diligence');
            completeAll(items);
        }
    }

    /** The real 12-item loan-only group F, added on top of the six above, left OPEN. */
    private static void addOpenGroupF(Id dealId, Integer sequence) {
        Checklist__c groupFRecord = buildGroup(dealId, 'F', 'Due Diligence', sequence);
        buildItems(groupFRecord.Id, 12, 'Due Diligence');
    }

    // ── N1 ──────────────────────────────────────────────────────────────────────────────────

    /**
     * THE SINGLE REVERT THAT TURNS THIS RED: delete the coordinate/subject/count composition in
     * `TransactionStageGateService.composeRefusal` or `describeItem` (e.g. compose only "items are
     * still open" with no numbers or names).
     */
    @isTest
    static void n1_refusesAndNamesCoordinateSubjectAndCount() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        List<Checklist_Item__c> items = buildOpenContractItems(deal.Id, 11);
        List<Checklist_Item__c> toComplete = new List<Checklist_Item__c>();
        for (Integer i = 1; i < items.size(); i++) {
            toComplete.add(new Checklist_Item__c(Id = items[i].Id, Flag__c = 'Completed'));
        }
        update toComplete; // items[0] stays open (factory default Flag__c = 'None')

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'One outstanding Open Contract item must refuse the move');
        String message = result.getErrors()[0].getMessage();
        Assert.isTrue(message.contains('A1'), 'Must name the coordinate: ' + message);
        Assert.isTrue(message.contains('Test Checklist Item 0'), 'Must name the subject: ' + message);
        Assert.isTrue(message.contains('1 of 11'), 'Must name the count: ' + message);
    }

    // ── N2 ──────────────────────────────────────────────────────────────────────────────────

    /**
     * Drives the SAME refusal through `RecordStageAdvanceService.advance` (the quick-action route)
     * and asserts the thrown message equals a directly-computed gate decision VERBATIM - proving
     * `setStage`'s `getDmlMessage(0)` is not mangling it (design SS1.1).
     *
     * THE SINGLE REVERT THAT TURNS THIS RED: change `setStage`'s catch to use `e.getMessage()`
     * instead of `e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage()`, which prepends the
     * platform's generic DML-exception preamble to the addError text.
     */
    @isTest
    static void n2_quickActionMessageMatchesGateDecisionVerbatim() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        List<Checklist_Item__c> items = buildOpenContractItems(deal.Id, 11);
        List<Checklist_Item__c> toComplete = new List<Checklist_Item__c>();
        for (Integer i = 1; i < items.size(); i++) {
            toComplete.add(new Checklist_Item__c(Id = items[i].Id, Flag__c = 'Completed'));
        }
        update toComplete;

        // Compute the expected refusal by calling the SAME algorithm directly (Trigger.isExecuting
        // is false here, so this reads the returned decision map rather than depending on
        // addError - exactly the reason that guard exists). Nothing is written to the database.
        Transaction__c priorState = [
            SELECT Id, Stage__c, Checklist_Fanned_Out__c FROM Transaction__c WHERE Id = :deal.Id];
        Transaction__c attempted = priorState.clone(true, true, true, true);
        attempted.Stage__c = 'Due Diligence';
        Map<Id, String> expected = TransactionStageGateService.enforceOnUpdate(
            new List<Transaction__c>{ attempted },
            new Map<Id, Transaction__c>{ priorState.Id => priorState });
        String expectedMessage = expected.get(deal.Id);
        Assert.isNotNull(expectedMessage, 'Precondition: the direct call must itself refuse');

        // `advance` routes through `passesGate` -> `TransactionActionPermissionService
        // .hasTransactionActionAccess()`, which is a `FeatureManagement.checkPermission` plus a
        // Modify All Data bypass. Without this seed the test passes only because the DEPLOYING
        // user happens to hold Modify All Data, so it would go red the day it is validated by a
        // persona that does not - and it would go red on the PERMISSION, not on the message path
        // it exists to prove. Pre-seeding the @TestVisible cache is the in-repo precedent
        // (`RecordStageAdvanceServiceTest.cls:3280`) and isolates what is being measured.
        TransactionActionPermissionService.cachedHasTransactionActionAccess = true;

        Test.startTest();
        String actualMessage;
        try {
            RecordStageAdvanceService.advance(deal.Id);
            Assert.fail('Expected RecordStageAdvanceException was not thrown');
        } catch (RecordStageAdvanceService.RecordStageAdvanceException e) {
            actualMessage = e.getMessage();
        }
        Test.stopTest();

        Assert.areEqual(expectedMessage, actualMessage,
            'The quick-action route must surface the gate message VERBATIM: expected ['
                + expectedMessage + '] actual [' + actualMessage + ']');
    }

    // ── N3 ──────────────────────────────────────────────────────────────────────────────────

    /**
     * THE SINGLE REVERT THAT TURNS THIS RED: call `deal.addError(message)` unconditionally instead
     * of only under `Trigger.isExecuting` would not itself break this - the real regression this
     * guards is `allOrNone=false` being changed to `allOrNone=true` somewhere upstream, or the
     * refusal being wrapped in a try/catch that swallows the `DmlException` rather than letting
     * `Database.update(..., false)` report it in the result.
     */
    @isTest
    static void n3_dataLoaderShapeIsRefusedNotSwallowedByAllOrNoneFalse() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        List<Checklist_Item__c> items = buildOpenContractItems(deal.Id, 3);
        update new List<Checklist_Item__c>{
            new Checklist_Item__c(Id = items[1].Id, Flag__c = 'Completed'),
            new Checklist_Item__c(Id = items[2].Id, Flag__c = 'Completed')
        }; // items[0] stays open

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'allOrNone=false must not swallow the refusal');
        Assert.isFalse(result.getErrors().isEmpty(), 'Errors must be populated, not silently empty');
    }

    // ── N4 ──────────────────────────────────────────────────────────────────────────────────

    /** The single highest-consequence hop - proven to fire, not assumed. */
    @isTest
    static void n4_refusesPostClosingToClosedWithOneOpenGroupJItem() {
        Transaction__c deal = claimedDeal('Post-Closing', false);
        Checklist__c postClosingGroup = buildGroup(deal.Id, 'J', 'Post-Closing', 1);
        List<Checklist_Item__c> items = buildItems(postClosingGroup.Id, 15, 'Post-Closing');
        List<Checklist_Item__c> toComplete = new List<Checklist_Item__c>();
        for (Integer i = 1; i < items.size(); i++) {
            toComplete.add(new Checklist_Item__c(Id = items[i].Id, Flag__c = 'Completed'));
        }
        update toComplete; // items[0] (J1) stays open

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Closed'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'The Post-Closing to Closed hop must refuse on one open group-J item, including the '
                + 'terminal move that no automation ever performs');
    }

    // ── N5a / N5b - the isDone pair ─────────────────────────────────────────────────────────

    @isTest
    static void n5a_verifiedCountsAsDone_isDoneControl() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        List<Checklist_Item__c> items = buildOpenContractItems(deal.Id, 11);
        List<Checklist_Item__c> updates = new List<Checklist_Item__c>();
        for (Integer i = 0; i < items.size(); i++) {
            updates.add(new Checklist_Item__c(
                Id = items[i].Id, Flag__c = (i == 0 ? 'Verified' : 'Completed')));
        }
        update updates;

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(),
            'Verified is a DONE state - a gate testing Flag__c == \'Completed\' would refuse this: '
                + (result.isSuccess() ? '' : result.getErrors()[0].getMessage()));
    }

    @isTest
    static void n5b_criticalIsStillOpen_mirrorOfN5a() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        List<Checklist_Item__c> items = buildOpenContractItems(deal.Id, 11);
        List<Checklist_Item__c> updates = new List<Checklist_Item__c>();
        for (Integer i = 0; i < items.size(); i++) {
            updates.add(new Checklist_Item__c(
                Id = items[i].Id, Flag__c = (i == 0 ? 'CRITICAL' : 'Completed')));
        }
        update updates;

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'CRITICAL is still open - without this half, N5a alone would also pass an always-'
                + 'allow gate');
    }

    // ── N6a / N6b - the anti-hardcode pair ──────────────────────────────────────────────────

    @isTest
    static void n6a_noLoanDealAllowedWithRealThirtyFourItemsDone() {
        Transaction__c deal = claimedDeal('Due Diligence', false);
        buildCompletedDueDiligenceNoLoan(deal.Id);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Closing Prep'), false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(),
            'A no-loan deal has no group F - all 34 real Due Diligence items done must allow the '
                + 'move. A gate hardcoded to 46 (or to any constant) would refuse this: '
                + (result.isSuccess() ? '' : result.getErrors()[0].getMessage()));
    }

    /**
     * THE SINGLE REVERT THAT TURNS N6a OR N6b RED: introduce ANY stage-size constant into
     * `TransactionStageGateService` (e.g. `private static final Integer DUE_DILIGENCE_TOTAL = 46;`
     * used in place of the counted `stageTotal`). N6a reds immediately (34 != 46); N6b's message
     * would still coincidentally say 46 but for the wrong reason, which is exactly why N6a exists.
     */
    @isTest
    static void n6b_loanDealRefusedWithGroupFOpen_namesFortySixAsCountedNotConstant() {
        Transaction__c deal = claimedDeal('Due Diligence', true);
        buildCompletedDueDiligenceNoLoan(deal.Id);
        addOpenGroupF(deal.Id, 7);

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Closing Prep'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'All 12 group-F items are open on a loan deal');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('12 of 46'),
            'The denominator must be COUNTED from the rows read (34 + 12 = 46), never a constant: '
                + result.getErrors()[0].getMessage());
    }

    // ── N7a / N7b - the fail-open pair ──────────────────────────────────────────────────────

    @isTest
    static void n7a_unclaimedDealAllowedAtZeroQueries() {
        Transaction__c deal = unclaimedDeal('Open Contract');
        TransactionStageGateService.resetRunCounters();

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'), false);
        Integer queries = TransactionStageGateService.lastRunQueryCount;
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'A deal with no checklist must never be blocked');
        Assert.areEqual(0, queries,
            'The fail-open must cost zero SOQL - Pass 1 exits before any query is reachable');
    }

    /**
     * THE SINGLE REVERT THAT TURNS THIS RED: comment out (or invert) the
     * `deal.Checklist_Fanned_Out__c != true` continue in `TransactionStageGateService.enforceChunk`
     * so every deal is treated as a candidate regardless of claim state - N7a would then also
     * refuse (a false positive there), and this test would flip from refused to allowed. This test
     * is what makes N7a meaningful: without it, "allowed" in N7a is indistinguishable from "the
     * gate never runs".
     */
    @isTest
    static void n7b_theControlForN7a_sameShapeClaimedRefuses() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        buildOpenContractItems(deal.Id, 1); // one item, left open

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'The identical shape, claimed, with one open item, must be REFUSED - proving the gate '
                + 'actually fires and N7a was a real fail-open, not a silent no-op');
    }

    // ── N8 ──────────────────────────────────────────────────────────────────────────────────

    @isTest
    static void n8_backwardMoveAllowedAtZeroQueriesEvenWithEverythingOpen() {
        Transaction__c deal = claimedDeal('Due Diligence', false);
        Checklist__c checklistGroup = buildGroup(deal.Id, 'C', 'Due Diligence', 1);
        buildItems(checklistGroup.Id, 7, 'Due Diligence'); // all left open
        TransactionStageGateService.resetRunCounters();

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Open Contract'), false);
        Integer queries = TransactionStageGateService.lastRunQueryCount;
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'Backward moves are never gated, whatever is open');
        Assert.areEqual(0, queries, 'Backward is filtered in Pass 1, before any query is reachable');
    }

    // ── N9 ──────────────────────────────────────────────────────────────────────────────────

    @isTest
    static void n9_insertAtDueDiligenceWithNoChecklistIsAllowed() {
        Transaction__c deal = TestDataFactory.createTransactions(1, false)[0];
        deal.Stage__c = 'Due Diligence';
        // Suppress the unrelated Day-0 fan-out flow. Transaction_Task_Fanout filters on
        // Checklist_Fanned_Out__c, and this deal must stay UNCLAIMED for the insert to be the
        // thing under test - so the OTHER entry filter (a null contract execution date) is what
        // suppresses it. Setting the claim flag here would make the test measure nothing.
        deal.Contract_Executed_Date__c = null;

        Test.startTest();
        Database.SaveResult result = Database.insert(deal, false);
        Test.stopTest();

        Assert.isTrue(result.isSuccess(),
            'beforeInsert is deliberately not gated - protects every seed script and scratch '
                + 'rebuild that inserts a Transaction directly at a later stage');
    }

    // ── N10 ─────────────────────────────────────────────────────────────────────────────────

    @isTest
    static void n10_nonStageSaveOnClaimedDealWithOpenItemsAllowedAtZeroQueries() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        buildOpenContractItems(deal.Id, 1); // left open
        TransactionStageGateService.resetRunCounters();

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Contract_Value__c = 2000000), false);
        Integer queries = TransactionStageGateService.lastRunQueryCount;
        Test.stopTest();

        Assert.isTrue(result.isSuccess(), 'A non-stage save must never be blocked by this gate');
        Assert.areEqual(0, queries,
            'Stage unchanged -> Pass 1 exits before any query - this is the pin on the handler\'s '
                + 'zero-cost promise for every counter/flag/owner write in the Day-0 cascade');
    }

    // ── N11 ─────────────────────────────────────────────────────────────────────────────────

    @isTest
    static void n11_nullItemStageFallsBackToParentChecklistStage_refuses() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        Checklist__c checklistGroup = buildGroup(deal.Id, 'A', 'Open Contract', 1);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false);
        items[0].Stage__c = null; // unstamped, as if the fan-out failed to stamp the phase
        insert items;

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(),
            'A null item Stage__c must fall back to the parent Checklist Stage__c and still gate '
                + 'on an item that is genuinely in the stage being left');
    }

    // ── N12 ─────────────────────────────────────────────────────────────────────────────────

    /**
     * THE SINGLE REVERT THAT TURNS THIS RED: remove the `String.isBlank(effectiveStage)` branch in
     * `TransactionStageGateService.enforceChunk` (Pass 3) so an item with no attributable stage on
     * either side falls through to the outstanding-count logic instead of being counted separately
     * - the deal would then be permanently un-advanceable with no instruction a user can follow.
     */
    @isTest
    static void n12_bothItemAndParentNullStage_allowedAndCounted() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        Checklist__c checklistGroup = buildGroup(deal.Id, 'A', null, 1);
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(1, checklistGroup.Id, false);
        items[0].Stage__c = null;
        insert items;
        TransactionStageGateService.resetRunCounters();

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'), false);
        Integer unattributed = TransactionStageGateService.lastRunUnattributedItemCount;
        Test.stopTest();

        Assert.isTrue(result.isSuccess(),
            'An item that cannot be attributed to ANY stage must not brick the deal');
        Assert.areEqual(1, unattributed,
            'The fail-open must be COUNTED, not silent - production tooling asserts this stays '
                + 'zero after every fan-out');
    }

    // ── N13 ─────────────────────────────────────────────────────────────────────────────────

    @isTest
    static void n13_messageIsPurePrintableAsciiWithNoMarkupCharacters() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        List<Checklist_Item__c> items = buildOpenContractItems(deal.Id, 11);
        List<Checklist_Item__c> toComplete = new List<Checklist_Item__c>();
        for (Integer i = 1; i < items.size(); i++) {
            toComplete.add(new Checklist_Item__c(Id = items[i].Id, Flag__c = 'Completed'));
        }
        update toComplete;

        Test.startTest();
        Database.SaveResult result = Database.update(
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'Precondition: the move must be refused to have a message');
        String message = result.getErrors()[0].getMessage();
        Assert.areEqual(message, message.replaceAll('[^\\x20-\\x7E]', ''),
            'Message must be pure printable ASCII, or addError HTML-escaping mangles both the '
                + 'toast and any contains() assertion written against it: ' + message);
        Assert.isFalse(message.contains('&'), 'No ampersand: ' + message);
        Assert.isFalse(message.contains('<'), 'No angle bracket: ' + message);
        Assert.isFalse(message.contains('>'), 'No angle bracket: ' + message);
        Assert.isFalse(message.contains('"'), 'No double quote: ' + message);
    }

    // ── N15 ─────────────────────────────────────────────────────────────────────────────────

    @isTest
    static void n15_twoDealsOneUpdateOneRefusedOneAllowed_perRecordAddError() {
        Transaction__c refusedDeal = claimedDeal('Open Contract', false);
        List<Checklist_Item__c> refusedItems = buildOpenContractItems(refusedDeal.Id, 2);
        update new Checklist_Item__c(Id = refusedItems[1].Id, Flag__c = 'Completed');
        // refusedItems[0] stays open

        Transaction__c allowedDeal = claimedDeal('Open Contract', false);
        List<Checklist_Item__c> allowedItems = buildOpenContractItems(allowedDeal.Id, 2);
        completeAll(allowedItems);

        List<Transaction__c> updates = new List<Transaction__c>{
            new Transaction__c(Id = refusedDeal.Id, Stage__c = 'Due Diligence'),
            new Transaction__c(Id = allowedDeal.Id, Stage__c = 'Due Diligence')
        };

        Test.startTest();
        List<Database.SaveResult> results = Database.update(updates, false);
        Test.stopTest();

        Assert.isFalse(results[0].isSuccess(), 'The deal with an open item must be refused');
        Assert.isTrue(results[1].isSuccess(),
            'The OTHER deal in the SAME statement must still save - addError is per-record, not a '
                + 'chunk abort');
        Transaction__c reQueriedAllowed = [
            SELECT Stage__c FROM Transaction__c WHERE Id = :allowedDeal.Id];
        Assert.areEqual('Due Diligence', reQueriedAllowed.Stage__c, 'The allowed deal actually moved');
    }

    // ── Unknown-stage control (ALSO REQUIRED, design B2.3/B3.3) ────────────────────────────

    /**
     * A restricted picklist cannot store an invented value via ordinary DML, so this calls
     * `enforceOnUpdate` directly with hand-built in-memory records rather than persisting one -
     * the same technique the returned-decision-map contract exists to enable.
     */
    @isTest
    static void unknownStageIsNotGatedAndIsCounted() {
        Transaction__c deal = claimedDeal('Open Contract', false);
        Map<Id, Transaction__c> oldMap = new Map<Id, Transaction__c>{
            deal.Id => new Transaction__c(
                Id = deal.Id, Stage__c = 'Not A Real Stage', Checklist_Fanned_Out__c = true)
        };
        List<Transaction__c> newDeals = new List<Transaction__c>{
            new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence', Checklist_Fanned_Out__c = true)
        };
        TransactionStageGateService.resetRunCounters();

        Test.startTest();
        Map<Id, String> refusals = TransactionStageGateService.enforceOnUpdate(newDeals, oldMap);
        Integer unknownCount = TransactionStageGateService.lastRunUnknownStageCount;
        Integer queries = TransactionStageGateService.lastRunQueryCount;
        Test.stopTest();

        Assert.isTrue(refusals.isEmpty(), 'An unrecognised prior stage must not be gated');
        Assert.areEqual(1, unknownCount,
            'Must be COUNTED so a picklist value added without updating TransactionStageDomain is '
                + 'assertable rather than silent');
        Assert.areEqual(0, queries, 'Unknown-stage moves are filtered in Pass 1, before any query');
    }

    // ── VOLUME ──────────────────────────────────────────────────────────────────────────────

    @isTest
    static void tBulk1_251UnclaimedDealsForcesTwoChunksAtZeroCost() {
        List<Transaction__c> deals = TestDataFactory.createTransactionsOnChecklistModel(251, true);
        List<Transaction__c> updates = new List<Transaction__c>();
        for (Transaction__c deal : deals) {
            updates.add(new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence'));
        }
        TransactionStageGateService.resetRunCounters();

        Test.startTest();
        List<Database.SaveResult> results = Database.update(updates, false);
        Integer chunkCount = TransactionStageGateService.lastRunChunkCount;
        Integer queries = TransactionStageGateService.lastRunQueryCount;
        Integer dmlStatements = TransactionStageGateService.lastRunDmlCount;
        Integer refusals = TransactionStageGateService.lastRunRefusalCount;
        Test.stopTest();

        Integer succeeded = 0;
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                succeeded++;
            }
        }
        Assert.areEqual(251, succeeded, 'Every unclaimed deal must save - none has a checklist');
        Assert.isTrue(chunkCount >= 2,
            'A 251-record update must fire before-update at least twice (200 + 51); fired '
                + chunkCount);
        Assert.areEqual(0, queries,
            'Every candidate fails open on Checklist_Fanned_Out__c before any query is reachable');
        Assert.areEqual(0, dmlStatements,
            'ZERO DML, at any record count, on every path - the invariant this class runs in a '
                + 'BEFORE context to keep. It is stated in TransactionStageGateService:180 and '
                + 'repeated in TransactionTriggerHandler, and until it is asserted here it is a '
                + 'comment rather than a control. Actual: ' + dmlStatements);
        Assert.areEqual(0, refusals, 'Nothing can be refused when nothing was queried');
    }

    /**
     * The claimed-volume proof, at the chunk boundary (25 deals in ONE before-update chunk) - see
     * the class header for why a literal 251 claimed deals cannot be built.
     *
     * =========================================================================================
     * WHY THIS ASSERTS AN INVARIANCE AND NOT THE LITERAL 1. READ BEFORE "SIMPLIFYING" IT.
     * =========================================================================================
     * This method asserted `Assert.areEqual(1, queries, ...)` and went RED at 2 on deploy
     * 0Afiw000000W3qnCAC - against a service that is correct. The literal was never achievable
     * for this shape, and the evidence is structural, not a guess:
     *
     *   1. `Database.update(updates, false)` is a PARTIAL save. When some records are refused,
     *      the runtime engine removes the failed rows and RETRIES the save for the SURVIVING
     *      subset, re-running before-update triggers on that second pass. 13 of the 25 deals
     *      here are refused, so 12 survive and the gate is entered TWICE - once with 25 rows,
     *      once with 12 - at one query each.
     *   2. Chunking cannot explain it: 25 rows is a single 200-row chunk.
     *   3. No automation re-saves `Transaction__c` on this path either.
     *      `workflows/Transaction__c` holds an ALERT and no field update (a workflow field update
     *      is the other thing that re-fires before-update triggers);
     *      `Transaction_Stage_Closed_Sets_Status` is `RecordBeforeSave`, which by definition does
     *      not re-trigger; and `Transaction_Complete_Close` is gated on `Status__c = 'Closed'`
     *      (these deals are Active) and updates the OPPORTUNITY, not the deal.
     *   4. `TransactionStageGateService` contains exactly ONE reachable SOQL statement -
     *      `ChecklistItemSelector.selectOpenForStageGate`, called once in Pass 2, outside every
     *      loop, and itself a single `[SELECT ...]`. So 2 queries means 2 FIRINGS, and cannot
     *      mean 2 queries inside one firing.
     *
     * `n3_dataLoaderShapeIsRefusedNotSwallowedByAllOrNoneFalse` never caught this because it is
     * SINGLE-RECORD: when the only record fails there is no surviving subset, so no retry pass.
     *
     * The number of SAVE PASSES is therefore a platform property, and a magic number matching
     * today's value is exactly the assertion that just broke - it would also silently absorb a
     * future regression in which the count grows WITH DEAL COUNT. What this test exists to prove
     * is that the query cost DOES NOT SCALE WITH THE NUMBER OF DEALS, so that is what is
     * asserted, in two independent forms:
     *   (1) PER FIRING - `queries == chunkCount`, i.e. one query per entry into the gate whatever
     *       the row count, asserted on BOTH volumes;
     *   (2) ACROSS VOLUMES - the identical path at 5 deals and at 25 deals costs the SAME total.
     * Neither form contains a literal cost and both are immune to how many passes the platform
     * makes. The 5-deal control is built from the SAME statements and the SAME refusal pattern as
     * the 25-deal measurement, so both windows make the same number of save passes and the only
     * difference between them is row count.
     *
     * THE SINGLE REVERT THAT TURNS THE QUERY-COUNT ASSERTIONS RED: move the
     * `ChecklistItemSelector.selectOpenForStageGate` call from Pass 2 (once, for the whole chunk)
     * into a per-deal loop - the classic SOQL-in-loop regression this instrumentation exists to
     * catch immediately rather than in production at Data-Loader scale. Under it the 5-deal
     * window reads 5 + 2 = 7 queries against 2 firings and the 25-deal window 25 + 12 = 37
     * against 2, so form (1) reds on both volumes and form (2) reds on 7 != 37.
     */
    @isTest
    static void tBulk2_oneQueryPerFiringFlatAcrossVolumeAndRefusesOnlyTheRightDeals() {
        // The two volumes the invariance is measured across. Materially different (5x), both
        // comfortably inside one 200-row before-update chunk so neither is measuring chunking.
        Integer controlVolume = 5;
        Integer measuredVolume = 25;

        List<Id> controlRefusedDealIds = new List<Id>();
        List<Id> controlAllowedDealIds = new List<Id>();
        List<Transaction__c> controlUpdates = new List<Transaction__c>();
        List<Id> refusedDealIds = new List<Id>();
        List<Id> allowedDealIds = new List<Id>();
        List<Transaction__c> updates = new List<Transaction__c>();

        // ── FIXTURE, BULKIFIED. FOUR DML STATEMENTS TOTAL - SEE THE CLASS HEADER. ──────────
        // Deals first (master-detail parents), then one group per deal, then every item, then
        // one completion update. Nothing is inserted inside a loop. BOTH volumes are built by the
        // SAME four statements, which is what makes the control a like-for-like comparison and
        // what keeps the pre-`startTest` budget at 16 SOQL / 12 DML: the extra 5 deals add rows,
        // not statements, and do not push any statement across a new 200-row trigger chunk.
        List<Transaction__c> deals = new List<Transaction__c>();
        for (Integer i = 0; i < controlVolume + measuredVolume; i++) {
            deals.add(claimedDeal('Open Contract', false, false));
        }
        insert deals; // 30 rows, ONE statement

        List<Checklist__c> groups = new List<Checklist__c>();
        for (Transaction__c deal : deals) {
            groups.add(buildGroup(deal.Id, 'A', 'Open Contract', 1, false));
        }
        insert groups;

        // Held per deal so the refuse/allow split below is decided on THIS deal's own rows.
        List<List<Checklist_Item__c>> itemsByDealIndex = new List<List<Checklist_Item__c>>();
        List<Checklist_Item__c> allItems = new List<Checklist_Item__c>();
        for (Checklist__c checklistGroup : groups) {
            List<Checklist_Item__c> items =
                buildItems(checklistGroup.Id, 11, 'Open Contract', false);
            itemsByDealIndex.add(items);
            allItems.addAll(items);
        }
        insert allItems; // 330 rows, ONE statement

        List<Checklist_Item__c> toComplete = new List<Checklist_Item__c>();
        for (Integer i = 0; i < deals.size(); i++) {
            // The first `controlVolume` deals are the control set. The refusal pattern is decided
            // on the index WITHIN each set, so both sets alternate refuse/allow from their own
            // first deal and both therefore produce failures AND survivors - the precondition for
            // the two windows to make the same number of save passes.
            Boolean isControl = i < controlVolume;
            Integer indexWithinSet = isControl ? i : i - controlVolume;
            Boolean refuse = Math.mod(indexWithinSet, 2) == 0;
            List<Checklist_Item__c> items = itemsByDealIndex[i];
            // refuse: leave items[0] open (complete 1..10). allow: complete all 11.
            Integer startAt = refuse ? 1 : 0;
            for (Integer j = startAt; j < items.size(); j++) {
                toComplete.add(new Checklist_Item__c(Id = items[j].Id, Flag__c = 'Completed'));
            }
            if (isControl) {
                if (refuse) {
                    controlRefusedDealIds.add(deals[i].Id);
                } else {
                    controlAllowedDealIds.add(deals[i].Id);
                }
                controlUpdates.add(
                    new Transaction__c(Id = deals[i].Id, Stage__c = 'Due Diligence'));
            } else {
                if (refuse) {
                    refusedDealIds.add(deals[i].Id);
                } else {
                    allowedDealIds.add(deals[i].Id);
                }
                updates.add(new Transaction__c(Id = deals[i].Id, Stage__c = 'Due Diligence'));
            }
        }
        update toComplete; // 314 rows, ONE statement
        TransactionStageGateService.resetRunCounters();

        Test.startTest();
        // WINDOW 1 - the 5-deal control, same shape and same refusal pattern.
        List<Database.SaveResult> controlResults = Database.update(controlUpdates, false);
        Integer controlQueries = TransactionStageGateService.lastRunQueryCount;
        Integer controlChunkCount = TransactionStageGateService.lastRunChunkCount;

        // CRITICAL: THE COUNTERS ARE CUMULATIVE ACROSS THE TRANSACTION, not per invocation.
        // Without this reset window 2 would report the SUM of both updates, would exceed window 1
        // by construction, and the invariance below could never go red.
        TransactionStageGateService.resetRunCounters();

        // WINDOW 2 - the 25-deal measurement.
        List<Database.SaveResult> results = Database.update(updates, false);
        Integer queries = TransactionStageGateService.lastRunQueryCount;
        Integer chunkCount = TransactionStageGateService.lastRunChunkCount;
        Integer dmlStatements = TransactionStageGateService.lastRunDmlCount;
        Test.stopTest();

        Assert.isTrue(queries >= 1,
            'NON-VACUITY GUARD, and it is not decoration: a fixture regression that leaves the '
                + 'deals unclaimed (the trap in this class header) makes the gate fail open, '
                + 'drives every counter to 0, and lets both equalities below pass while measuring '
                + 'nothing at all. Actual: ' + queries);
        Assert.areEqual(chunkCount, queries,
            'ONE QUERY PER FIRING, whatever the row count - Pass 2 issues the single '
                + 'ChecklistItemSelector.selectOpenForStageGate call for the WHOLE chunk. The '
                + 'gate was entered ' + chunkCount + ' times and spent ' + queries + ' queries. '
                + 'Entries above one are the platform retrying the survivors of a partial save, '
                + 'not this class querying twice; a per-deal query would read 37 here');
        Assert.areEqual(controlChunkCount, controlQueries,
            'The same one-query-per-firing invariant on the 5-deal control: entered '
                + controlChunkCount + ' times, spent ' + controlQueries + ' queries');
        Assert.areEqual(controlQueries, queries,
            'NEVER A FUNCTION OF DEAL COUNT: the identical path must cost the same total at 5 '
                + 'deals (' + controlQueries + ') as at 25 (' + queries + '). Asserted as an '
                + 'INVARIANCE rather than as a literal because the number of SAVE PASSES is a '
                + 'platform property - Database.update(..., false) removes the refused rows and '
                + 'retries the survivors, so a partial-failure update legitimately enters the '
                + 'gate more than once. See this method header before changing this to a number');
        Assert.areEqual(0, dmlStatements,
            'ZERO DML even on the path that DOES query and DOES refuse - the gate refuses through '
                + 'addError on records the platform is already saving, and must never write. '
                + 'Actual: ' + dmlStatements);

        Set<Id> actuallyRefused = new Set<Id>();
        Set<Id> actuallyAllowed = new Set<Id>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                actuallyAllowed.add(updates[i].Id);
            } else {
                actuallyRefused.add(updates[i].Id);
            }
        }
        Assert.areEqual(new Set<Id>(refusedDealIds), actuallyRefused,
            'Refusals must land on exactly the deals with an open item');
        Assert.areEqual(new Set<Id>(allowedDealIds), actuallyAllowed,
            'The rest must save - a whole-chunk refusal would fail deals with nothing outstanding');

        // The control window is held to the SAME correctness standard, and not only because it is
        // free: if it refused nothing it would make a single save pass, window 1 and window 2
        // would differ in pass count, and the invariance above would red for a reason that has
        // nothing to do with per-deal querying.
        Set<Id> controlActuallyRefused = new Set<Id>();
        Set<Id> controlActuallyAllowed = new Set<Id>();
        for (Integer i = 0; i < controlResults.size(); i++) {
            if (controlResults[i].isSuccess()) {
                controlActuallyAllowed.add(controlUpdates[i].Id);
            } else {
                controlActuallyRefused.add(controlUpdates[i].Id);
            }
        }
        Assert.areEqual(new Set<Id>(controlRefusedDealIds), controlActuallyRefused,
            'The control set must refuse exactly the deals with an open item, or the two windows '
                + 'are not the same shape and the invariance compares nothing');
        Assert.areEqual(new Set<Id>(controlAllowedDealIds), controlActuallyAllowed,
            'The control set must also produce SURVIVORS - a window with no survivors makes one '
                + 'save pass instead of two and is not comparable to the 25-deal window');
    }

    /**
     * The pin on the handler's zero-cost promise, at the same 25-deal volume as tBulk2 - a
     * counter-only save on a chunk full of claimed, checklist-bearing deals must still cost zero
     * SOQL, because Pass 1's "stage did not change" branch exits before Pass 2 is ever reachable.
     */
    @isTest
    static void tBulk3_sameVolumeCounterOnlyUpdateCostsZeroQueries() {
        // Same bulkified fixture shape as tBulk2, minus the completion update: the items are left
        // OPEN on purpose and are irrelevant to the outcome, because the stage does not move.
        List<Transaction__c> deals = new List<Transaction__c>();
        for (Integer i = 0; i < 25; i++) {
            deals.add(claimedDeal('Open Contract', false, false));
        }
        insert deals;

        List<Checklist__c> groups = new List<Checklist__c>();
        for (Transaction__c deal : deals) {
            groups.add(buildGroup(deal.Id, 'A', 'Open Contract', 1, false));
        }
        insert groups;

        List<Checklist_Item__c> allItems = new List<Checklist_Item__c>();
        for (Checklist__c checklistGroup : groups) {
            allItems.addAll(buildItems(checklistGroup.Id, 11, 'Open Contract', false));
        }
        insert allItems; // 275 rows, ONE statement

        List<Transaction__c> updates = new List<Transaction__c>();
        for (Integer i = 0; i < deals.size(); i++) {
            updates.add(new Transaction__c(Id = deals[i].Id, Contract_Value__c = 3000000 + i));
        }
        TransactionStageGateService.resetRunCounters();

        Test.startTest();
        List<Database.SaveResult> results = Database.update(updates, false);
        Integer queries = TransactionStageGateService.lastRunQueryCount;
        Test.stopTest();

        for (Database.SaveResult result : results) {
            Assert.isTrue(result.isSuccess(), 'A counter-only save must never be refused');
        }
        Assert.areEqual(0, queries,
            'A non-stage save on 25 claimed, checklist-bearing deals in one chunk must cost ZERO '
                + 'SOQL - this is the pin on TransactionTriggerHandler\'s cost promise');
    }
}
