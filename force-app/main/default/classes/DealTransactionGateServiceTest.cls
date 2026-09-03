/**
 * Tests for `DealTransactionGateService` — the maintainer of
 * `Opportunity.Has_Open_Transaction__c` / `Has_Closed_Transaction__c`, the two flags the
 * `Transaction_Closed_Before_Closed_Won` validation rule reads.
 *
 * ┌───────────────────────────────────────────────────────────────────────────────────────────┐
 * │ WHAT THIS CLASS DOES AND DOES NOT OWN                                                     │
 * └───────────────────────────────────────────────────────────────────────────────────────────┘
 * It owns the FLAGS: given some Transaction DML, do the parent's two booleans end up describing
 * the database? It does NOT own the validation rule — no Apex test can observe a rule's formula
 * except by provoking it, and provoking it is `StageApprovalGatesTest`'s job
 * (`transactionGate_*`, four methods, including the fail-closed "no transaction at all" case and
 * its positive control). Keeping the two apart is deliberate: a flag bug and a formula bug produce
 * different failures and should fail in different classes.
 *
 * ── 🔴 NO @TestSetup, AND THAT IS NOT AN OVERSIGHT ────────────────────────────────────────────
 * Half these methods measure GOVERNOR COST inside a trigger context and the other half work at
 * 251 records. A shared `@TestSetup` would put fixture rows into every method's starting state,
 * which is fine for assertions and fatal for budgets: the 251-row methods must control exactly
 * what is in the database when the measured DML runs, or the aggregate's group count and the
 * update's row count stop being derivable. Each method builds what it needs.
 *
 * ── 🔴 THE FIXTURES SUPPRESS THE DAY-0 FAN-OUT ON PURPOSE ─────────────────────────────────────
 * `flows/Transaction_Task_Fanout` fires on create when `Contract_Executed_Date__c` is non-null and
 * a fan-out guard flag is false, and `TestDataFactory.createTransactions` sets the date. Left
 * alone, the 251-record methods below would enqueue a fan-out of roughly 20,600 child rows and
 * would not run.
 *
 * 🔴 THE DEVICE CHANGED TWICE ON 2026-09-03 AND THE OLD ONES NO LONGER EXIST. Until that day
 * these fixtures set `Tasks_Fanned_Out__c = true`, because that WAS the flow's second entry
 * filter. A7 of `agent-output/design-checklist-cutover-and-stage-gate.md` repointed the flow onto
 * `ChecklistFanoutService` and moved that filter to `Checklist_Fanned_Out__c = false`, so a
 * `Tasks_Fanned_Out__c` flag suppressed nothing at all and 251 deals would fan out. M5 then
 * DELETED that field outright.
 * ⇒ THE FIXTURES NULL `Contract_Executed_Date__c`, which is the filter BOTH the old and
 * the new flow share, so it survives the next repoint too. It must be in the INSERT payload, not
 * applied afterwards - setting it later is a race with the Queueable, not a guard. Nothing under
 * test here reads the date.
 *
 * ⚠ Do NOT suppress by setting `Checklist_Fanned_Out__c = true` instead: that flag is the
 * discriminator `ChecklistFanoutService` and `TransactionStageGateService` branch on, and
 * claiming a deal that is not on the checklist model changes behaviour rather than suppressing it.
 *
 * ── ⚠ THE 251 IS THE RULE'S LITERAL 251 AND IT STANDS ─────────────────────────────────────────
 * `.claude/rules/bulk-test-rule.md`'s per-transaction-singleton exemption does NOT apply: this is
 * a trigger path with a real loop over `Trigger.new`, and 251 rows is exactly what forces the
 * platform's second 200-record chunk — which is the only way to catch a recompute that is bulk-safe
 * within one chunk but not across two.
 *
 * ── 🔴 GOVERNOR ASSERTIONS READ THE SERVICE'S OWN COUNTERS, NEVER `Limits` AFTER `stopTest` ────
 * `Test.stopTest()` restores the pre-test governor counters, so `Limits.getQueries()` measured
 * after it is silently vacuous. Every budget assertion below reads
 * `DealTransactionGateService.lastRun*`, captured INSIDE the trigger body and accumulated across
 * chunks.
 *
 * @see force-app/main/default/classes/DealTransactionGateService.cls
 * @see force-app/main/default/classes/StageApprovalGatesTest.cls (the validation rule itself)
 */
@isTest
private class DealTransactionGateServiceTest {

    private static final Integer BULK_N = 251;
    private static final String CLOSED = 'Closed';
    private static final String ACTIVE = 'Active';

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // FIXTURES
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * `count` inserted Opportunities at their factory-default stage, one per intended Transaction.
     *
     * @param count How many deals.
     * @return The inserted deals.
     */
    private static List<Opportunity> deals(Integer count) {
        return TestDataFactory.createOpportunities(count, true);
    }

    /**
     * Deals that can survive `flows/Transaction_Complete_Close` closing them.
     *
     * 🔴 REQUIRED WHENEVER A FIXTURE PUTS A **CLOSED** TRANSACTION ON A PARENTED DEAL, AND THAT
     * INCLUDES INSERTING ONE. MEASURED, validate `0Afiw000000VDSPCA4` (2026-09-02): seven methods
     * in this class inserted `Status__c = 'Closed'` rows directly and all seven died on
     * `CANNOT_EXECUTE_FLOW_TRIGGER … "Transaction Complete Close" … FIELD_CUSTOM_VALIDATION_
     * EXCEPTION: This deal cannot be marked Closed Won until the contract is signed`.
     *
     * The cause is `Transaction_Complete_Close`'s `recordTriggerType = CreateAndUpdate` with
     * `doesRequireRecordChangedToMeetCriteria = true`: a row that meets `Status__c = 'Closed' AND
     * Opportunity__c != null` AT CREATION counts as having changed to meet them, so the flow fires
     * on the INSERT and immediately tries to write `StageName = 'Closed Won'` on the parent — a
     * write that crosses all five Closed Won validation rules. A test fixture that has not
     * prepared the deal makes the flow throw, and the throw rolls back the Transaction insert.
     *
     * ⚠ SO THE CHEAP-LOOKING FIXTURE IS THE EXPENSIVE ONE. Most methods below deliberately use
     * `'Active'` and never go near this, precisely so their governor budgets measure this service
     * rather than the close cascade. Use this helper only where a CLOSED transaction is the
     * subject.
     *
     * @param count How many deals.
     * @return Inserted deals with a signed primary NDA and a signed contract.
     */
    private static List<Opportunity> dealsThatCanClose(Integer count) {
        List<Opportunity> dealList = deals(count);
        TestDataFactory.signPrimaryNda(dealList);
        TestDataFactory.signContract(dealList);
        return dealList;
    }

    /**
     * Builds `deals.size()` Transactions, one per deal, at the given `Status__c`, with the Day-0
     * fan-out suppressed. Index-aligned to `deals`.
     *
     * @param dealList The parents; one Transaction each.
     * @param status   `Transaction__c.Status__c` for every row.
     * @param doInsert Insert when true.
     * @return The Transactions, index-aligned to `dealList`.
     */
    private static List<Transaction__c> transactionsFor(
        List<Opportunity> dealList, String status, Boolean doInsert
    ) {
        List<Transaction__c> rows =
            TestDataFactory.createTransactions(dealList.size(), null, null, false);
        for (Integer i = 0; i < dealList.size(); i++) {
            rows[i].Opportunity__c = dealList[i].Id;
            rows[i].Status__c = status;
            // Suppresses flows/Transaction_Task_Fanout — see the class header. The NULL DATE is
            // what does the suppressing since the 2026-09-03 repoint.
            rows[i].Contract_Executed_Date__c = null;
        }
        if (doInsert) {
            insert rows;
        }
        return rows;
    }

    /**
     * Re-reads both flags for the given deals, keyed by Id.
     *
     * 🔴 `WITH SYSTEM_MODE` IS MANDATORY AND A PLAIN SELECT DOES NOT WORK. MEASURED, validate
     * `0Afiw000000VDSPCA4` (2026-09-02): the unqualified form threw
     * `System.QueryException: No such column 'Has_Open_Transaction__c' on entity 'Opportunity'`
     * in six methods, as a System Administrator. A field with ZERO `FieldPermissions` rows is not
     * FLS-denied, it is ABSENT from the running user's schema, and "Apex SOQL is system mode by
     * default" governs ENFORCEMENT on a visible field — it does not put back a field that is not
     * there. These two flags are machine-written and are granted read-only at most, so this stays
     * true even after the permission sets land.
     */
    private static Map<Id, Opportunity> flagsFor(List<Opportunity> dealList) {
        return new Map<Id, Opportunity>([
            SELECT Id, Has_Open_Transaction__c, Has_Closed_Transaction__c
            FROM Opportunity
            WHERE Id IN :dealList
            WITH SYSTEM_MODE
        ]);
    }

    /**
     * Writes both flags directly, in system mode. Used only where a test needs to FALSIFY the
     * stored state (the backfill case) — see `flagsFor` for why the mode is explicit.
     *
     * @param deal      The deal to stamp.
     * @param hasOpen   Value for `Has_Open_Transaction__c`.
     * @param hasClosed Value for `Has_Closed_Transaction__c`.
     */
    private static void stampFlags(Opportunity deal, Boolean hasOpen, Boolean hasClosed) {
        Database.update(new Opportunity(
            Id = deal.Id,
            Has_Open_Transaction__c = hasOpen,
            Has_Closed_Transaction__c = hasClosed
        ), true, AccessLevel.SYSTEM_MODE);
    }

    /**
     * A syntactically valid, never-inserted Id of the given type. Same idiom as
     * `CounterOfferControllerTest.fakeId` / `DealMessageControllerTest.fakeId`, with a
     * discriminator so two calls can be told apart — `affectedParents` is a pure function and
     * must be provable without paying for a row.
     *
     * @param sobjectType The type to mint under.
     * @param seed        1-9; makes each Id distinct.
     * @return A 15-character Id of that type.
     */
    private static Id fakeId(Schema.SObjectType sobjectType, Integer seed) {
        return Id.valueOf(sobjectType.getDescribe().getKeyPrefix() + '00000000000' + seed);
    }

    /** Re-reads both flags for one deal. `WITH SYSTEM_MODE` for the reason above. */
    private static Opportunity flagsFor(Opportunity deal) {
        return [
            SELECT Id, Has_Open_Transaction__c, Has_Closed_Transaction__c
            FROM Opportunity WHERE Id = :deal.Id
            WITH SYSTEM_MODE
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE HAPPY PATH, ONE RECORD AT A TIME
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * The insert arm. A deal starts with both flags false — the fail-closed state — and opening a
     * Transaction moves exactly one of them.
     */
    @isTest
    static void openingATransaction_marksTheDealAsHavingAnOpenOne() {
        Opportunity deal = deals(1)[0];
        Opportunity before = flagsFor(deal);
        Assert.isFalse(before.Has_Open_Transaction__c,
            'Precondition: a deal with no Transaction starts in the BLOCKED state, both false. '
            + 'If either of these two starts true the Checkbox default is wrong and the whole '
            + 'fail-closed argument collapses');
        Assert.isFalse(before.Has_Closed_Transaction__c, 'and false');

        Test.startTest();
        transactionsFor(new List<Opportunity>{ deal }, ACTIVE, true);
        Test.stopTest();

        Opportunity after = flagsFor(deal);
        Assert.isTrue(after.Has_Open_Transaction__c, 'An Active Transaction is an OPEN one');
        Assert.isFalse(after.Has_Closed_Transaction__c,
            'and it is emphatically not a closed one — a single flag would not be able to say '
            + 'both of these things');
    }

    /**
     * A `Draft` Transaction counts as OPEN, not as absent. Pinned separately because `Draft` is
     * the picklist DEFAULT, so it is what a hand-created Transaction carries, and a service that
     * only recognised `Active` would report "no transaction" for it — fail-closed by accident
     * rather than by design, and wrong the moment the row is later closed.
     */
    @isTest
    static void aDraftTransactionCountsAsOpen() {
        Opportunity deal = deals(1)[0];

        Test.startTest();
        transactionsFor(new List<Opportunity>{ deal }, 'Draft', true);
        Test.stopTest();

        Opportunity after = flagsFor(deal);
        Assert.isTrue(after.Has_Open_Transaction__c, 'Draft is not Closed, so it is open');
        Assert.isFalse(after.Has_Closed_Transaction__c, 'and it is not closed');
    }

    /**
     * The update arm crossing the closed boundary — and the whole feature end to end.
     *
     * 🔴 THIS IS THE MOST IMPORTANT METHOD IN THE CLASS. It is the only one that proves the
     * ORDERING assumption the design rests on: this service's after-trigger write lands BEFORE
     * `flows/Transaction_Complete_Close`'s after-save Opportunity update, so the flow's write of
     * `StageName = 'Closed Won'` is validated against flags that are already correct and
     * `Transaction_Closed_Before_Closed_Won` passes. If Apex after-triggers ever stopped running
     * before after-save flows, the legitimate close would start rolling back every transaction
     * save — and this test is what would catch it.
     *
     * The other Closed Won gates are satisfied honestly (a signed NDA and a signed contract),
     * because the flow's update crosses ALL of them, not just the new one.
     */
    @isTest
    static void closingTheTransaction_flipsTheFlagsAndLetsTheFlowCloseTheDeal() {
        Opportunity deal = deals(1)[0];
        TestDataFactory.signPrimaryNda(deal);
        TestDataFactory.signContract(deal);
        Transaction__c txn = transactionsFor(new List<Opportunity>{ deal }, ACTIVE, true)[0];

        Test.startTest();
        update new Transaction__c(Id = txn.Id, Status__c = CLOSED);
        Test.stopTest();

        Opportunity after = [
            SELECT StageName, Has_Open_Transaction__c, Has_Closed_Transaction__c
            FROM Opportunity WHERE Id = :deal.Id
            WITH SYSTEM_MODE
        ];
        Assert.isFalse(after.Has_Open_Transaction__c, 'Nothing is open any more');
        Assert.isTrue(after.Has_Closed_Transaction__c, 'and a closed Transaction now exists');
        Assert.areEqual('Closed Won', after.StageName,
            '🔴 AND THE DEAL CLOSED. flows/Transaction_Complete_Close ran AFTER this service and '
            + 'its Opportunity update passed Transaction_Closed_Before_Closed_Won. A failure here '
            + 'with the two flags correct above means the ORDER changed (Apex after-triggers used '
            + 'to run before after-save flows) and every transaction close is now rolling back');
    }

    /**
     * A deal with two Transactions, one closed and one open, reads BOTH flags true — and the open
     * one keeps it out of the closable state.
     *
     * ⚠ The cardinality really is one-to-many and unenforced — `Transaction__c.Opportunity__c` is
     * a plain Lookup and only `ContractExecutionService` de-duplicates, so a second Transaction is
     * an ordinary data state, not a corruption. A service that stopped at the first row it found
     * would report this deal closable while one of its transactions was still running.
     *
     * ⚠ THE ORDER OF THE TWO INSERTS IS FORCED AND IS NOT COSMETIC. The CLOSED one goes first, on
     * a deal prepared to survive being closed, because `flows/Transaction_Complete_Close` fires on
     * its INSERT and closes the deal — which is what makes the intermediate `afterClose` assertion
     * below (closed = true, open = false) reachable at all. Inserting the OPEN one first would
     * leave that intermediate state unobservable.
     *
     * ⚠ THE SECOND HALF OF THIS NOTE WAS RETIRED ON 2026-09-02 AND MUST NOT BE PUT BACK. It used
     * to say the reverse order would be REFUSED by the transaction gate, and cross-referenced
     * `StageApprovalGatesTest.transactionGate_closingOneOfTwoTransactions_isRefusedAndRollsBack`.
     * That was true until `flows/Transaction_Complete_Close` gained its
     * `Get_Open_Sibling_Transactions` / `No_Open_Sibling_Transactions` guard: the flow now ENDS
     * without touching the Opportunity when a sibling is still open, so nothing is refused and
     * nothing rolls back. The successor pin is
     * `StageApprovalGatesTest.transactionGate_twoTransactions_dealClosesOnlyWhenTheLastOneCloses`.
     */
    @isTest
    static void aDealWithOneClosedAndOneOpenTransaction_readsBothFlagsTrue() {
        Opportunity deal = dealsThatCanClose(1)[0];
        transactionsFor(new List<Opportunity>{ deal }, CLOSED, true);

        Opportunity afterClose = flagsFor(deal);
        Assert.isTrue(afterClose.Has_Closed_Transaction__c, 'Precondition: one closed');
        Assert.isFalse(afterClose.Has_Open_Transaction__c, 'and nothing open yet');

        Test.startTest();
        transactionsFor(new List<Opportunity>{ deal }, ACTIVE, true);
        Test.stopTest();

        Opportunity mixed = flagsFor(deal);
        Assert.isTrue(mixed.Has_Open_Transaction__c,
            'A SECOND, open Transaction must set the open flag even though a closed one already '
            + 'exists — a service that stopped at the first row it found would miss this and '
            + 'report the deal closable while one of its transactions was still running');
        Assert.isTrue(mixed.Has_Closed_Transaction__c,
            'and the closed flag stays: both are true at once, which is the state a single '
            + 'Checkbox could never express');
    }

    /** Removing transactions one at a time: the open flag survives until the LAST open one goes. */
    @isTest
    static void twoOpenTransactions_theOpenFlagSurvivesUntilTheLastOneIsGone() {
        Opportunity deal = deals(1)[0];
        List<Transaction__c> pair =
            transactionsFor(new List<Opportunity>{ deal, deal }, ACTIVE, true);
        Assert.isTrue(flagsFor(deal).Has_Open_Transaction__c, 'Precondition: open');

        Test.startTest();
        delete pair[0];
        Assert.isTrue(flagsFor(deal).Has_Open_Transaction__c,
            'One down, one to go — the recompute must count what is LEFT, not react to what was '
            + 'touched');
        delete pair[1];
        Test.stopTest();

        Assert.isFalse(flagsFor(deal).Has_Open_Transaction__c, 'and only now does it clear');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // DELETE AND UNDELETE — "neither permanently blocked nor permanently unblocked"
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 DELETING A CLOSED TRANSACTION MUST RE-BLOCK THE DEAL. This is the "permanently
     * unblocked" half of the brief's requirement, and it is the dangerous half: without the
     * after-delete arm the deal would keep `Has_Closed_Transaction__c = true` for ever and stay
     * closable with nothing behind it — the exact state the whole feature exists to refuse.
     */
    @isTest
    static void deletingTheClosedTransaction_reBlocksTheDeal() {
        Opportunity deal = dealsThatCanClose(1)[0];
        Transaction__c txn = transactionsFor(new List<Opportunity>{ deal }, CLOSED, true)[0];
        Assert.isTrue(flagsFor(deal).Has_Closed_Transaction__c, 'Precondition: closable');

        Test.startTest();
        delete txn;
        Test.stopTest();

        Opportunity after = flagsFor(deal);
        Assert.isFalse(after.Has_Closed_Transaction__c,
            'The evidence is gone, so the permission is gone. A stale true here is a deal that '
            + 'can be closed with no transaction at all');
        Assert.isFalse(after.Has_Open_Transaction__c, 'and nothing is open either');
    }

    /**
     * The other half: deleting an OPEN transaction must not leave the deal permanently blocked by
     * a transaction that no longer exists.
     */
    @isTest
    static void deletingTheOpenTransaction_clearsTheOpenFlag() {
        Opportunity deal = deals(1)[0];
        Transaction__c txn = transactionsFor(new List<Opportunity>{ deal }, ACTIVE, true)[0];
        Assert.isTrue(flagsFor(deal).Has_Open_Transaction__c, 'Precondition: blocked by an open one');

        Test.startTest();
        delete txn;
        Test.stopTest();

        Assert.isFalse(flagsFor(deal).Has_Open_Transaction__c,
            'A deleted transaction cannot block a deal for ever — the deal is back to "no '
            + 'transaction", which is still refused, but by the right clause and recoverably');
    }

    /**
     * Restoring from the Recycle Bin restores the state it was deleted in.
     *
     * ⚠ An OPEN transaction, not a closed one: an undelete of a CLOSED row would newly meet
     * `flows/Transaction_Complete_Close`'s criteria and drag the whole close cascade into a test
     * about the undelete arm. `deletingTheClosedTransaction_reBlocksTheDeal` covers the closed
     * side; this covers the arm.
     */
    @isTest
    static void undeletingATransaction_restoresTheFlags() {
        Opportunity deal = deals(1)[0];
        Transaction__c txn = transactionsFor(new List<Opportunity>{ deal }, ACTIVE, true)[0];
        delete txn;
        Assert.isFalse(flagsFor(deal).Has_Open_Transaction__c, 'Precondition: cleared by delete');

        Test.startTest();
        undelete txn;
        Test.stopTest();

        Assert.isTrue(flagsFor(deal).Has_Open_Transaction__c,
            'An undelete is a row reappearing, so the parent must be recomputed exactly as an '
            + 'insert is');
    }

    /**
     * Re-parenting: BOTH deals are recomputed, not just the one that gained the row. Without the
     * old parent in the collected set the deal a transaction LEFT keeps a flag it no longer earns
     * — the same permanent-unblock failure as a missed delete, reached a different way.
     */
    @isTest
    static void reparentingATransaction_recomputesBothTheOldAndTheNewDeal() {
        List<Opportunity> pairOfDeals = deals(2);
        Transaction__c txn =
            transactionsFor(new List<Opportunity>{ pairOfDeals[0] }, ACTIVE, true)[0];
        Assert.isTrue(flagsFor(pairOfDeals[0]).Has_Open_Transaction__c, 'Precondition: on deal 0');

        Test.startTest();
        update new Transaction__c(Id = txn.Id, Opportunity__c = pairOfDeals[1].Id);
        Test.stopTest();

        Map<Id, Opportunity> after = flagsFor(pairOfDeals);
        Assert.isFalse(after.get(pairOfDeals[0].Id).Has_Open_Transaction__c,
            'The deal it LEFT must lose the flag — this is the assertion that fails if only '
            + 'Trigger.new\'s parent is collected');
        Assert.isTrue(after.get(pairOfDeals[1].Id).Has_Open_Transaction__c,
            'and the deal it arrived at must gain it');
    }

    /** A Transaction with no parent is ignored rather than throwing on a null Id. */
    @isTest
    static void aTransactionWithNoParent_isIgnored() {
        Test.startTest();
        List<Transaction__c> orphans = TestDataFactory.createTransactions(2, false);
        for (Transaction__c row : orphans) {
            row.Contract_Executed_Date__c = null; // the actual suppression - see the class header
        }
        DealTransactionGateService.resetRunCounters();
        insert orphans; // must NOT throw
        Test.stopTest();

        Assert.areEqual(0, DealTransactionGateService.lastRunInvocationCount,
            'With no parent there is nothing to recompute, so the service is never entered — a '
            + 'null Opportunity__c must be filtered BEFORE the query, not bound into it');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE COST CONTROL — the promise TransactionTriggerHandler's header makes on behalf of the
    // whole Day-0 chain. These are the tests that fail if someone removes the change-gate.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 A COUNTER-ONLY WRITE COSTS ABSOLUTELY NOTHING. `TaskRollupService` and
     * `ChecklistRollupService` update `Transaction__c` several times per deal creation, and
     * `TransactionTriggerHandler`'s header promises those writes are free — a promise the
     * checklist fan-out's own governor budget is calculated against. An ungated arm here would
     * add one query and one DML to every one of them and would break that budget somewhere else
     * entirely, which is why this is asserted at zero rather than "small".
     */
    @isTest
    static void aWriteThatChangesNeitherParentNorClosedness_costsNothing() {
        Opportunity deal = deals(1)[0];
        Transaction__c txn = transactionsFor(new List<Opportunity>{ deal }, ACTIVE, true)[0];

        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        update new Transaction__c(Id = txn.Id, Tasks_Total__c = 82, Tasks_Complete__c = 3);
        Test.stopTest();

        Assert.areEqual(0, DealTransactionGateService.lastRunInvocationCount,
            'A counter write must not enter the service at all');
        Assert.areEqual(0, DealTransactionGateService.lastRunQueryCount, 'zero SOQL');
        Assert.areEqual(0, DealTransactionGateService.lastRunDmlCount, 'zero DML');
    }

    /**
     * The same guarantee for a stage move that does not reach `Closed`. Separate from the counter
     * test because a naive gate written as "did Stage__c change?" instead of "did CLOSEDNESS
     * change?" would pass that one and fail this one.
     */
    @isTest
    static void aStageMoveThatDoesNotReachClosed_costsNothing() {
        Opportunity deal = deals(1)[0];
        Transaction__c txn = transactionsFor(new List<Opportunity>{ deal }, ACTIVE, true)[0];

        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        update new Transaction__c(Id = txn.Id, Stage__c = 'Due Diligence');
        Test.stopTest();

        Assert.areEqual(0, DealTransactionGateService.lastRunInvocationCount,
            'Open Contract -> Due Diligence leaves Status__c on Active both sides, so nothing '
            + 'this gate can see moved');
        Assert.areEqual(0, DealTransactionGateService.lastRunQueryCount, 'zero SOQL');
        Assert.areEqual(0, DealTransactionGateService.lastRunDmlCount, 'zero DML');
    }

    /**
     * The recompute runs but writes nothing when the flags already agree with the database. The
     * skipped DML is the entire reason the stored flags are read before they are written; without
     * this assertion that read would be pure cost.
     */
    @isTest
    static void aRecomputeThatAgreesWithTheStoredFlags_writesNothing() {
        Opportunity deal = deals(1)[0];
        transactionsFor(new List<Opportunity>{ deal }, ACTIVE, true);

        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        DealTransactionGateService.recalculate(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, DealTransactionGateService.lastRunInvocationCount, 'It ran');
        Assert.areEqual(2, DealTransactionGateService.lastRunQueryCount,
            'and it paid its two reads (the Transaction aggregate and the stored flags)');
        Assert.areEqual(0, DealTransactionGateService.lastRunUpdatedCount,
            'but found nothing to change');
        Assert.areEqual(0, DealTransactionGateService.lastRunDmlCount,
            'so it wrote nothing. A non-zero here means the change-detection compare is broken '
            + 'and every Transaction save is now re-entering OpportunityReviewTrigger for nothing');
    }

    /** Null and empty inputs are no-ops, not exceptions and not full-table scans. */
    @isTest
    static void recalculateWithNothingToDo_isANoOp() {
        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        DealTransactionGateService.recalculate(null);
        DealTransactionGateService.recalculate(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, DealTransactionGateService.lastRunInvocationCount, 'Neither ran');
        Assert.areEqual(0, DealTransactionGateService.lastRunQueryCount, 'and neither queried');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // 🔴 BULK — 251 records, TWO trigger chunks, and a CONSTANT budget
    //
    // The literal 251 is `.claude/rules/bulk-test-rule.md`'s, and it is load-bearing rather than
    // ceremonial: for an INSERT or an UPDATE it forces the platform to fire the trigger TWICE
    // (200 + 51), which is the only way to catch a recompute that is bulk-safe inside one chunk
    // and not across two.
    //
    // 🔴 IT DOES NOT DO THAT FOR DELETE AND UNDELETE, AND THAT WAS MEASURED HERE RATHER THAN
    // ASSUMED. A 251-row `delete` / `undelete` fires the after context exactly ONCE on this org
    // at API 67.0 (validate `0Afiw000000VCMgCAO`, 2026-09-02) — the two methods that assert "2"
    // for those arms were written first and went red. So the invocation counts below are 2 for
    // insert/update and 1 for delete/undelete, deliberately and asymmetrically. Do not
    // "harmonise" them.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * The insert arm at volume. Every one of 251 deals is flagged, and the cost is
     * `ceil(251/200) = 2` invocations of two queries and one update each — CONSTANT in the number
     * of records, which is what "no SOQL or DML in a loop" means in practice.
     */
    @isTest
    static void bulk251Inserts_flagEveryParentOnAConstantBudget() {
        List<Opportunity> dealList = deals(BULK_N);
        List<Transaction__c> rows = transactionsFor(dealList, ACTIVE, false);

        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        insert rows;
        Test.stopTest();

        Map<Id, Opportunity> after = flagsFor(dealList);
        Integer flagged = 0;
        for (Opportunity row : after.values()) {
            if (row.Has_Open_Transaction__c && !row.Has_Closed_Transaction__c) {
                flagged++;
            }
        }
        Assert.areEqual(BULK_N, flagged,
            'All 251 deals must be flagged. A number BELOW 251 with no exception means the '
            + 'recompute is not bulk-safe across the two trigger chunks (200 + 51); an exception '
            + 'means a query or a DML moved inside a loop');

        Assert.areEqual(2, DealTransactionGateService.lastRunInvocationCount,
            '251 rows is TWO trigger chunks. A 1 here means the platform stopped chunking and '
            + 'this test has quietly stopped testing what it claims');
        Assert.areEqual(4, DealTransactionGateService.lastRunQueryCount,
            'TWO queries per chunk and no more: the Transaction aggregate and the stored-flag '
            + 'read. Any growth with record count is the defect this test exists to catch');
        Assert.areEqual(2, DealTransactionGateService.lastRunDmlCount,
            'and ONE update statement per chunk');
        Assert.areEqual(BULK_N, DealTransactionGateService.lastRunUpdatedCount,
            'covering all 251 parents');
    }

    /**
     * The update arm at volume: 251 re-parentings move 251 flags off and 251 flags on.
     *
     * ⚠ ACTIVE, NOT CLOSED, AND EVERY BULK METHOD IN THIS CLASS IS THE SAME. A closed Transaction
     * on a parented deal fires flows/Transaction_Complete_Close, which would drag 251 Closed Won
     * cascades into a method whose entire purpose is a precise governor budget. See
     * dealsThatCanClose for the measurement behind that.
     */
    @isTest
    static void bulk251Reparentings_moveEveryFlagToTheNewDeal() {
        List<Opportunity> oldParents = deals(BULK_N);
        List<Opportunity> newParents = deals(BULK_N);
        List<Transaction__c> rows = transactionsFor(oldParents, ACTIVE, true);
        List<Transaction__c> moves = new List<Transaction__c>();
        for (Integer i = 0; i < BULK_N; i++) {
            moves.add(new Transaction__c(Id = rows[i].Id, Opportunity__c = newParents[i].Id));
        }

        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        update moves;
        Test.stopTest();

        Integer vacated = 0;
        for (Opportunity row : flagsFor(oldParents).values()) {
            if (!row.Has_Closed_Transaction__c && !row.Has_Open_Transaction__c) {
                vacated++;
            }
        }
        Integer gained = 0;
        for (Opportunity row : flagsFor(newParents).values()) {
            if (row.Has_Open_Transaction__c) {
                gained++;
            }
        }
        Assert.areEqual(BULK_N, vacated, 'All 251 old parents must be cleared');
        Assert.areEqual(BULK_N, gained, 'and all 251 new parents flagged');

        Assert.areEqual(2, DealTransactionGateService.lastRunInvocationCount, 'Two chunks');
        Assert.areEqual(4, DealTransactionGateService.lastRunQueryCount,
            'still two queries per chunk even though each chunk now carries TWICE the parents '
            + '(the deal left and the deal joined) — the aggregate is one query whatever the set '
            + 'size, which is why the group-count arithmetic in the selector header matters');
        Assert.areEqual(2, DealTransactionGateService.lastRunDmlCount, 'and one update per chunk');
        Assert.areEqual(BULK_N * 2, DealTransactionGateService.lastRunUpdatedCount,
            'writing 502 parents in those two statements');
    }

    /**
     * 🔴 THE MOST VALUABLE BUDGET TEST IN THE CLASS: 251 counter writes, the shape the Day-0
     * chain actually produces, cost NOTHING. A change that removes or weakens the update arm's
     * gate fails here rather than in production, where it would surface as the checklist fan-out
     * breaching a limit it was budgeted under.
     */
    @isTest
    static void bulk251CounterWrites_costNothing() {
        List<Opportunity> dealList = deals(BULK_N);
        List<Transaction__c> rows = transactionsFor(dealList, ACTIVE, true);
        List<Transaction__c> counterWrites = new List<Transaction__c>();
        for (Transaction__c row : rows) {
            counterWrites.add(new Transaction__c(Id = row.Id, Tasks_Total__c = 82));
        }

        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        update counterWrites;
        Test.stopTest();

        Assert.areEqual(0, DealTransactionGateService.lastRunInvocationCount,
            '251 counter writes must not enter the service ONCE');
        Assert.areEqual(0, DealTransactionGateService.lastRunQueryCount, 'zero SOQL at 251 rows');
        Assert.areEqual(0, DealTransactionGateService.lastRunDmlCount, 'zero DML at 251 rows');
    }

    /** The delete arm at volume. ACTIVE for the reason on the re-parenting method above. */
    @isTest
    static void bulk251Deletes_clearEveryParentOnAConstantBudget() {
        List<Opportunity> dealList = deals(BULK_N);
        List<Transaction__c> rows = transactionsFor(dealList, ACTIVE, true);

        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        delete rows;
        Test.stopTest();

        Integer cleared = 0;
        for (Opportunity row : flagsFor(dealList).values()) {
            if (!row.Has_Closed_Transaction__c && !row.Has_Open_Transaction__c) {
                cleared++;
            }
        }
        Assert.areEqual(BULK_N, cleared,
            'All 251 deals must be re-blocked. Any deal left with a flag still set is a deal whose '
            + 'gate state describes transactions that no longer exist');

        // 🔴 ONE, NOT TWO — AND THAT IS A MEASUREMENT, NOT AN EXPECTATION.
        // Every other bulk method here asserts 2, because a 251-row INSERT or UPDATE is chunked
        // 200 + 51 and fires the trigger twice. A 251-row DELETE does NOT: measured on
        // `usman-dpeg` at API 67.0 (validate `0Afiw000000VCMgCAO`, 2026-09-02) the after-delete
        // context ran exactly ONCE for all 251 rows, and this assertion was written expecting 2
        // and went red. The platform's 200-record chunking is a property of the insert/update
        // path, not a universal law, and this class should not pretend otherwise.
        // ⚠ If this ever reads 2, the platform started chunking deletes — that is NOT a defect in
        // this service (the budget is still 2 queries + 1 DML PER invocation and the flag
        // assertion above still holds); update the number and this comment together.
        Assert.areEqual(1, DealTransactionGateService.lastRunInvocationCount,
            'A 251-row delete fires the after-delete context ONCE — measured, see the note above');
        Assert.areEqual(2, DealTransactionGateService.lastRunQueryCount,
            'two queries for the whole 251: the aggregate and the stored-flag read');
        Assert.areEqual(1, DealTransactionGateService.lastRunDmlCount, 'and ONE update statement');
    }

    /** The undelete arm at volume. ACTIVE for the reason on the re-parenting method above. */
    @isTest
    static void bulk251Undeletes_restoreEveryParent() {
        List<Opportunity> dealList = deals(BULK_N);
        List<Transaction__c> rows = transactionsFor(dealList, ACTIVE, true);
        delete rows;

        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        undelete rows;
        Test.stopTest();

        Integer restored = 0;
        for (Opportunity row : flagsFor(dealList).values()) {
            if (row.Has_Open_Transaction__c) {
                restored++;
            }
        }
        Assert.areEqual(BULK_N, restored, 'All 251 deals must be restored');
        // ONE, for the same measured reason as the delete method above — a 251-row undelete fires
        // the after-undelete context once, not twice. Read that note before changing these three.
        Assert.areEqual(1, DealTransactionGateService.lastRunInvocationCount,
            'A 251-row undelete fires the after-undelete context ONCE — measured, not assumed');
        Assert.areEqual(2, DealTransactionGateService.lastRunQueryCount, 'two queries in total');
        Assert.areEqual(1, DealTransactionGateService.lastRunDmlCount, 'and ONE update');
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE FLOW ENTRY POINT
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /**
     * List-in / list-out, one recompute for the whole batch, results index-parallel to the input.
     *
     * ⚠ THE FIXTURE MAKES THE STORED FLAGS WRONG ON PURPOSE, BY WRITING THEM DIRECTLY RATHER THAN
     * THROUGH ANY TRANSACTION DML. That is precisely the state the backfill exists for: a deal
     * that already owns a closed Transaction from before this feature shipped, whose flags nothing
     * has ever populated. If the invocable merely re-wrote what was already there this test would
     * pass without the service having computed anything.
     */
    @isTest
    static void invocableRecalculate_repairsStaleFlagsForEveryRequest() {
        // deal 0 owns a CLOSED transaction, so it must be able to survive the flow closing it.
        Opportunity closedDeal = dealsThatCanClose(1)[0];
        Opportunity openDeal = deals(1)[0];
        List<Opportunity> dealList = new List<Opportunity>{ closedDeal, openDeal };
        transactionsFor(new List<Opportunity>{ closedDeal }, CLOSED, true);
        transactionsFor(new List<Opportunity>{ openDeal }, ACTIVE, true);
        // Falsify both, as a pre-feature backfill would find them. System mode: see flagsFor.
        stampFlags(closedDeal, true, false);
        stampFlags(openDeal, false, true);

        List<DealTransactionGateService.RecalcRequest> requests =
            new List<DealTransactionGateService.RecalcRequest>();
        for (Opportunity deal : dealList) {
            DealTransactionGateService.RecalcRequest request =
                new DealTransactionGateService.RecalcRequest();
            request.opportunityId = deal.Id;
            requests.add(request);
        }

        Test.startTest();
        DealTransactionGateService.resetRunCounters();
        List<DealTransactionGateService.RecalcResult> results =
            DealTransactionGateService.recalculateFlags(requests);
        Test.stopTest();

        Assert.areEqual(2, results.size(),
            'One result per request, in order — a Flow indexes into this list');
        Assert.isTrue(results[0].success, 'both succeeded');
        Assert.isTrue(results[1].success, 'both succeeded');
        Assert.areEqual(1, DealTransactionGateService.lastRunInvocationCount,
            'ONE recompute for the whole batch, not one per request — a per-request loop would '
            + 'blow the SOQL limit the moment a Flow handed this a real batch');

        Map<Id, Opportunity> after = flagsFor(dealList);
        Assert.isTrue(after.get(dealList[0].Id).Has_Closed_Transaction__c,
            'The closed deal is repaired to closed');
        Assert.isFalse(after.get(dealList[0].Id).Has_Open_Transaction__c, 'and not open');
        Assert.isTrue(after.get(dealList[1].Id).Has_Open_Transaction__c,
            'and the open deal is repaired to open');
        Assert.isFalse(after.get(dealList[1].Id).Has_Closed_Transaction__c, 'and not closed');
    }

    /** A request with no Id is reported as a failure rather than silently dropped. */
    @isTest
    static void invocableRecalculate_withABlankId_reportsFailureForThatRow() {
        DealTransactionGateService.RecalcRequest blank =
            new DealTransactionGateService.RecalcRequest();

        Test.startTest();
        List<DealTransactionGateService.RecalcResult> results =
            DealTransactionGateService.recalculateFlags(
                new List<DealTransactionGateService.RecalcRequest>{ blank });
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'The result list stays parallel to the input');
        Assert.isFalse(results[0].success, 'A blank Id cannot be recomputed');
        Assert.isNotNull(results[0].errorMessage, 'and the Flow is told why');
    }

    /** Null and empty request lists return an empty list rather than throwing. */
    @isTest
    static void invocableRecalculate_withNoRequests_returnsAnEmptyList() {
        Test.startTest();
        Assert.areEqual(0, DealTransactionGateService.recalculateFlags(null).size(), 'null');
        Assert.areEqual(0, DealTransactionGateService.recalculateFlags(
            new List<DealTransactionGateService.RecalcRequest>()).size(), 'empty');
        Test.stopTest();
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════
    // THE CHANGE GATE, TESTED DIRECTLY
    //
    // `affectedParents` is @TestVisible so each branch can be driven without a DML per case. The
    // trigger-level tests above prove it is WIRED; these prove it is CORRECT, cheaply.
    // ═════════════════════════════════════════════════════════════════════════════════════════

    /** Every branch of the change gate, one assertion each, with no DML at all. */
    @isTest
    static void affectedParents_collectsExactlyTheDealsWhoseCountsCouldHaveMoved() {
        Id dealA = fakeId(Opportunity.SObjectType, 1);
        Id dealB = fakeId(Opportunity.SObjectType, 2);
        Id txnId = fakeId(Transaction__c.SObjectType, 1);

        // Insert / undelete: no old map, so every non-null parent is collected.
        Assert.areEqual(new Set<Id>{ dealA },
            DealTransactionGateService.affectedParents(
                new List<Transaction__c>{
                    new Transaction__c(Id = txnId, Opportunity__c = dealA, Status__c = ACTIVE)
                }, null),
            'On insert the parent is always collected');

        // Insert with no parent: nothing.
        Assert.areEqual(new Set<Id>(),
            DealTransactionGateService.affectedParents(
                new List<Transaction__c>{ new Transaction__c(Id = txnId, Status__c = ACTIVE) },
                null),
            'A parentless row collects nothing');

        // Update, nothing this gate can see: nothing.
        Assert.areEqual(new Set<Id>(),
            DealTransactionGateService.affectedParents(
                new List<Transaction__c>{
                    new Transaction__c(Id = txnId, Opportunity__c = dealA, Status__c = ACTIVE)
                },
                new Map<Id, Transaction__c>{
                    txnId => new Transaction__c(Id = txnId, Opportunity__c = dealA, Status__c = ACTIVE)
                }),
            'Same parent, same closedness — the counter-write case, and it must collect NOTHING');

        // Update crossing the closed boundary: the one parent.
        Assert.areEqual(new Set<Id>{ dealA },
            DealTransactionGateService.affectedParents(
                new List<Transaction__c>{
                    new Transaction__c(Id = txnId, Opportunity__c = dealA, Status__c = CLOSED)
                },
                new Map<Id, Transaction__c>{
                    txnId => new Transaction__c(Id = txnId, Opportunity__c = dealA, Status__c = ACTIVE)
                }),
            'Active -> Closed is the boundary crossing the gate exists for');

        // Re-parenting: BOTH.
        Assert.areEqual(new Set<Id>{ dealA, dealB },
            DealTransactionGateService.affectedParents(
                new List<Transaction__c>{
                    new Transaction__c(Id = txnId, Opportunity__c = dealB, Status__c = ACTIVE)
                },
                new Map<Id, Transaction__c>{
                    txnId => new Transaction__c(Id = txnId, Opportunity__c = dealA, Status__c = ACTIVE)
                }),
            'A re-parent collects the deal left AND the deal joined');

        // Null / empty input.
        Assert.areEqual(new Set<Id>(),
            DealTransactionGateService.affectedParents(null, null), 'null is a no-op');
        Assert.areEqual(new Set<Id>(),
            DealTransactionGateService.affectedParents(new List<Transaction__c>(), null),
            'empty is a no-op');
    }
}
