/**
 * Tests for `ChecklistOutcomeService` — the Phase 5 DERIVED outcomes (A5 critical dates, B5 earnest
 * money) and the `Is_Earnest_At_Risk__c` derivation.
 *
 * ── THE TRUTH TABLE IS THE MOST VALUABLE THING HERE ────────────────────────────────────────
 * `isEarnestAtRisk` is a pure function with an injected `today`, so every branch is exercised
 * directly and deterministically rather than through a deal fixture whose calendar could drift.
 * Two of its rows are ones the design document got the other way round, so they are asserted
 * explicitly with the reasoning in the message: a MISSED feasibility deadline makes the deposit MORE
 * at risk, not less.
 *
 * 🔴 251, NOT 20. This service performs DML and takes a collection, so
 * `.claude/rules/bulk-test-rule.md`'s default volume applies; it touches no `ContentVersion` /
 * `ContentNote` / `ContentDocument`, so `.claude/rules/content-publication-rule.md`'s reduced
 * ceiling does not. ⚠ The volume test uses 251 ITEMS on ONE deal rather than 251 deals: the cost
 * this class can get wrong is per-ITEM (a read or a `CriticalDateService` call moved inside the
 * loop), and 251 deals would additionally drag 251 Transaction updates through
 * `TransactionTrigger`, measuring that trigger rather than this service.
 *
 * ⚠ THE RUNNING TEST USER IS AN ADMINISTRATOR, so the sharing-filtered spanning read that
 * `applyForCompletedItems` fails closed on cannot occur naturally here. It is forced through the
 * `outcomeRowsOverride` seam, WITH a presence control so the seam cannot pass vacuously.
 */
@isTest
private class ChecklistOutcomeServiceTest {

    private static final Integer BULK_ITEMS = 251;

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // The earnest-at-risk truth table (pure function, injected clock)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void moneyNotSentIsNeverAtRisk() {
        Date yesterday = Date.today().addDays(-1);
        Assert.isFalse(
            ChecklistOutcomeService.isEarnestAtRisk(
                false, yesterday, false, 'Active', 'Due Diligence', Date.today()),
            'A deposit that has not been wired cannot be at risk, however far the calendar has run'
        );
        Assert.isFalse(
            ChecklistOutcomeService.isEarnestAtRisk(
                null, yesterday, true, 'Active', 'Due Diligence', Date.today()),
            'A null Earnest_Money_Sent__c is not true and must not be read as true'
        );
    }

    @isTest
    static void moneySentBeforeFeasibilityEndsIsNotAtRisk() {
        Assert.isFalse(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, Date.today().addDays(30), false, 'Active', 'Due Diligence', Date.today()),
            'During the feasibility window the buyer can still terminate and recover the deposit'
        );
    }

    @isTest
    static void moneySentOnTheDeadlineItselfIsNotYetAtRisk() {
        // The boundary. The deadline day is still inside the window — the deposit goes hard when
        // the period EXPIRES, not on the morning of the last day.
        Assert.isFalse(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, Date.today(), false, 'Active', 'Due Diligence', Date.today()),
            'On the deadline date itself the buyer can still terminate'
        );
        Assert.isTrue(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, Date.today().addDays(-1), false, 'Active', 'Due Diligence', Date.today()),
            'The day after the deadline the deposit is non-refundable'
        );
    }

    @isTest
    static void missedFeasibilityIsCorroboratingNotExculpatory() {
        // 🔴 THIS INVERTS design §5.8's PARENTHETICAL, DELIBERATELY. That section proposes
        // `Feasibility_Deadline__c < TODAY && Earnest_Money_Sent__c` "(and not
        // Feasibility_Missed__c)". Excluding missed-feasibility deals is backwards: a deal that blew
        // through its feasibility deadline is the MOST at-risk case there is, and excluding it would
        // zero the portfolio KPI on precisely the deals it exists to surface.
        Assert.isTrue(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, Date.today().addDays(-1), true, 'Active', 'Due Diligence', Date.today()),
            'A deal that MISSED feasibility must still count as at risk, not be excluded'
        );
        Assert.isTrue(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, null, true, 'Active', 'Due Diligence', Date.today()),
            'Feasibility_Missed__c alone is enough — a deal with no recorded deadline that is known '
                + 'to have missed it is at risk, and an AND-form condition could never reach it'
        );
    }

    @isTest
    static void aDealWithNoDeadlineAndNoMissFlagIsNotAtRisk() {
        Assert.isFalse(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, null, false, 'Active', 'Open Contract', Date.today()),
            'With no deadline and no miss flag there is no evidence the period has ended — the '
                + 'derivation must not guess in the alarming direction either'
        );
    }

    @isTest
    static void aSettledDealIsNotAtRisk() {
        // At closing the deposit is applied to the purchase price. It stops being at risk and
        // starts being part of the consideration.
        Date yesterday = Date.today().addDays(-1);
        Assert.isFalse(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, yesterday, true, 'Closed', 'Closing Prep', Date.today()),
            'Status Closed settles the deal'
        );
        Assert.isFalse(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, yesterday, true, 'Active', 'Closed', Date.today()),
            'Stage Closed settles the deal'
        );
        Assert.isFalse(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, yesterday, true, 'Active', 'Post-Closing', Date.today()),
            'Post-Closing is AFTER closing, so the deposit has already been applied. Note the '
                + 'hyphen: the value is Post-Closing, not Post Closing'
        );
        Assert.isTrue(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, yesterday, true, 'Active', 'Closing Prep', Date.today()),
            'Closing Prep is BEFORE closing — the control that proves the settled test above is not '
                + 'passing for some other reason'
        );
    }

    @isTest
    static void nullStatusStageAndClockAreSafe() {
        Assert.isTrue(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, Date.today().addDays(-1), false, null, null, Date.today()),
            'A deal with no status or stage is not settled, so an expired deadline still counts'
        );
        Assert.isFalse(
            ChecklistOutcomeService.isEarnestAtRisk(
                true, Date.today().addDays(-1), false, 'Active', 'Due Diligence', null),
            'With no clock there is nothing to compare against — refuse rather than throw'
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // B5 — earnest money sent
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void completingB5StampsSentAndItsDate() {
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);

        Test.startTest();
        completeAndApply(b5);
        Test.stopTest();

        Transaction__c after = reload(deal.Id);
        Assert.areEqual(true, after.Earnest_Money_Sent__c, 'B5 stamps the flag');
        Assert.areEqual(Date.today(), after.Earnest_Money_Sent_Date__c, 'and the date');
    }

    @isTest
    static void completingB5DoesNotTouchTheLegacyEmWiredDate() {
        // ⚠ `EM_Wired_Date__c` is a SEPARATE, pre-existing field that `lwc/transactionCriticalDates`
        // already reads. `Earnest_Money_Sent_Date__c`'s own field XML records that conflating the
        // two is a business decision with its own backfill, not something to do by assumption.
        Transaction__c deal = newDeal();
        update new Transaction__c(Id = deal.Id, EM_Wired_Date__c = Date.today().addDays(-10));
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);

        Test.startTest();
        completeAndApply(b5);
        Test.stopTest();

        Transaction__c after = reload(deal.Id);
        Assert.areEqual(Date.today().addDays(-10), after.EM_Wired_Date__c,
            'The pre-existing EM_Wired_Date__c must be left exactly as it was');
        Assert.areEqual(Date.today(), after.Earnest_Money_Sent_Date__c,
            'while the new field is stamped independently');
    }

    @isTest
    static void reApplyingB5DoesNotOverwriteTheOriginalSentDate() {
        // The date the wire actually went out must survive a re-run — of the service, of a backfill,
        // or of a second completion. Overwriting it with today would quietly rewrite history.
        Transaction__c deal = newDeal();
        update new Transaction__c(
            Id = deal.Id,
            Earnest_Money_Sent__c = true,
            Earnest_Money_Sent_Date__c = Date.today().addDays(-20)
        );
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);

        Test.startTest();
        completeAndApply(b5);
        Test.stopTest();

        Assert.areEqual(Date.today().addDays(-20), reload(deal.Id).Earnest_Money_Sent_Date__c,
            'An existing sent date is history and must not be re-stamped with today');
    }

    @isTest
    static void completingB5OnAnExpiredDealSetsAtRiskInTheSameSave() {
        // 🔴 THE PENDING-VALUE TRAP. When B5 is in the batch, the deal as READ still says
        // `Earnest_Money_Sent__c = false`. Deriving at-risk from the queried value would evaluate
        // the flag against the state BEFORE the write in the very transaction that changes it, and
        // the deal would sit "money sent, not at risk" until something else happened to touch it.
        Transaction__c deal = newDeal();
        update new Transaction__c(Id = deal.Id, Feasibility_Deadline__c = Date.today().addDays(-1));
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);

        Test.startTest();
        completeAndApply(b5);
        Test.stopTest();

        Transaction__c after = reload(deal.Id);
        Assert.areEqual(true, after.Earnest_Money_Sent__c, 'Control: the flag was stamped');
        Assert.areEqual(true, after.Is_Earnest_At_Risk__c,
            'and at-risk was derived from the PENDING value in the same save, not the stale one');
    }

    @isTest
    static void anOrdinaryCompletionRefreshesAtRiskOnAnAlreadySentDeal() {
        // The staleness mitigation. Nothing saves a deal on the day its feasibility expires, so the
        // flag is refreshed by whatever checklist activity happens next — which on a live deal is
        // most working days. This proves a NON-B5 completion still does it.
        Transaction__c deal = newDeal();
        update new Transaction__c(
            Id = deal.Id,
            Earnest_Money_Sent__c = true,
            Earnest_Money_Sent_Date__c = Date.today().addDays(-30),
            Feasibility_Deadline__c = Date.today().addDays(-1)
        );
        Assert.areEqual(false, reload(deal.Id).Is_Earnest_At_Risk__c,
            'Control: nothing has recomputed the flag yet, so it is still false and wrong');
        Checklist_Item__c ordinary = itemAt(deal.Id, 'D', 3);

        Test.startTest();
        completeAndApply(ordinary);
        Test.stopTest();

        Assert.areEqual(true, reload(deal.Id).Is_Earnest_At_Risk__c,
            'Completing ANY item on the deal refreshes the derived flag');
    }

    @isTest
    static void closingTheDealClearsAtRisk() {
        Transaction__c deal = newDeal();
        update new Transaction__c(
            Id = deal.Id,
            Earnest_Money_Sent__c = true,
            Feasibility_Deadline__c = Date.today().addDays(-1),
            Is_Earnest_At_Risk__c = true,
            Stage__c = 'Post-Closing'
        );
        Checklist_Item__c ordinary = itemAt(deal.Id, 'D', 3);

        Test.startTest();
        completeAndApply(ordinary);
        Test.stopTest();

        Assert.areEqual(false, reload(deal.Id).Is_Earnest_At_Risk__c,
            'Once the deal has closed the deposit is part of the consideration, not at risk');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // A5 — critical dates
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void completingA5ProjectsTheDealCriticalDates() {
        Transaction__c deal = newDeal();
        Checklist_Item__c a5 = itemAt(deal.Id, 'A', 5);
        Assert.areEqual(0, [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id],
            'Control: no critical dates exist before A5 is completed');

        Test.startTest();
        completeAndApply(a5);
        Test.stopTest();

        List<Critical_Date__c> dates =
            [SELECT Type__c, Due_Date__c FROM Critical_Date__c WHERE Transaction__c = :deal.Id];
        Assert.isFalse(dates.isEmpty(),
            'Completing "Log critical dates into Salesforce deal record" must actually log them');
        Set<String> types = new Set<String>();
        for (Critical_Date__c row : dates) {
            types.add(row.Type__c);
        }
        Assert.isTrue(types.contains('Closing Date'), 'The closing date is projected');
        Assert.isTrue(types.contains('Feasibility End'), 'and the feasibility end');
        Assert.isFalse(types.contains('Contract Executed'),
            'Contract Executed is NOT a valid Critical_Date__c.Type__c value today (design '
                + 'GATE-B2). Writing it would raise INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST');
    }

    @isTest
    static void completingA5TwiceCreatesNoDuplicates() {
        // `CriticalDateService` is idempotent on (Transaction + Type), so a re-run is a repair
        // rather than a duplicator. This pins that the outcome path inherits that property.
        Transaction__c deal = newDeal();
        Checklist_Item__c a5 = itemAt(deal.Id, 'A', 5);

        Test.startTest();
        completeAndApply(a5);
        Integer afterFirst = [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id];
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ a5.Id });
        Integer afterSecond = [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id];
        Test.stopTest();

        Assert.areEqual(afterFirst, afterSecond, 'A second run creates nothing new');
    }

    @isTest
    static void anIncompleteDerivedItemAppliesNothing() {
        // The outcome is the outcome of COMPLETING the step. An item that is still open must not
        // stamp anything, even though it carries a derived coordinate.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);

        Test.startTest();
        // Deliberately NOT completed — applied directly against an open item.
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ b5.Id });
        Test.stopTest();

        Assert.areEqual(false, reload(deal.Id).Earnest_Money_Sent__c,
            'An open B5 stamps nothing');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Cost, no-op discipline and safety
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void anUnchangedDealIsNotWrittenAtAll() {
        // 🔴 EVERY CHECKLIST COMPLETION CALLS THIS SERVICE. A no-op Transaction__c update on every
        // tick would fire TransactionTrigger and DealTransactionGateService for nothing, on an
        // object whose handler header promises counter-only writes cost zero.
        Transaction__c deal = newDeal();
        Checklist_Item__c ordinary = itemAt(deal.Id, 'D', 3);
        update new Checklist_Item__c(Id = ordinary.Id, Flag__c = 'Completed');

        Test.startTest();
        Integer d0 = Limits.getDmlStatements();
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ ordinary.Id });
        Integer dml = Limits.getDmlStatements() - d0;
        Test.stopTest();

        Assert.areEqual(0, dml,
            'Nothing about the deal changed, so no DML at all should have been spent');
        Assert.areEqual(0, ChecklistOutcomeService.lastRunDealWriteCount,
            'and the in-context counter agrees');
    }

    @isTest
    static void outcomeCostAt200RowsMatchesCostAtOne() {
        // 🔴 THE BULKIFICATION INVARIANT, MEASURED WITH A DERIVED COORDINATE PRESENT IN BOTH CALLS.
        // `ChecklistItemServiceTest`'s equivalent test deliberately uses capture-free groups so it
        // measures the completion service alone; this one is its counterpart, and between them the
        // two properties are proven separately rather than one masking the other.
        // ⚠ BOTH SIDES MUST CARRY THE SAME KIND OF DERIVED COORDINATE, NOT MERELY ONE EACH. A5 and
        // B5 have genuinely different costs — A5 additionally calls `CriticalDateService`, which
        // spends its own 2 SOQL and 1 DML — so pairing an A5 against a B5 would compare two
        // different workloads and fail for a reason that has nothing to do with scaling. Both
        // groups here are `B`, so both calls carry exactly one B5 and nothing else.
        Transaction__c bulkDeal = newDeal();
        List<Checklist_Item__c> many =
            TestDataFactory.createChecklistItems(200, checklistFor(bulkDeal.Id, 'B').Id, true);
        Transaction__c singleDeal = newDeal();
        List<Checklist_Item__c> few =
            TestDataFactory.createChecklistItems(5, checklistFor(singleDeal.Id, 'B').Id, true);

        List<Checklist_Item__c> completions = new List<Checklist_Item__c>();
        for (Checklist_Item__c item : many) {
            completions.add(new Checklist_Item__c(Id = item.Id, Flag__c = 'Completed'));
        }
        for (Checklist_Item__c item : few) {
            completions.add(new Checklist_Item__c(Id = item.Id, Flag__c = 'Completed'));
        }
        update completions;

        Set<Id> bulkIds = new Map<Id, Checklist_Item__c>(many).keySet();
        // The fifth item in a group B is B5 — the same single derived coordinate the 200-row set
        // carries.
        Set<Id> singleIds = new Set<Id>{ few[4].Id };

        Test.startTest();
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        ChecklistOutcomeService.applyForCompletedItems(singleIds);
        Integer singleQueries = Limits.getQueries() - q0;
        Integer singleDml = Limits.getDmlStatements() - d0;

        Integer q1 = Limits.getQueries();
        Integer d1 = Limits.getDmlStatements();
        ChecklistOutcomeService.applyForCompletedItems(bulkIds);
        Integer bulkQueries = Limits.getQueries() - q1;
        Integer bulkDml = Limits.getDmlStatements() - d1;
        Test.stopTest();

        Assert.areEqual(singleQueries, bulkQueries,
            'Query count must not scale with row count (1 derived item cost ' + singleQueries
                + ', 200 rows containing one derived item cost ' + bulkQueries + ')');
        Assert.areEqual(singleDml, bulkDml,
            'DML statement count must not scale with row count (' + singleDml + ' vs ' + bulkDml + ')');
    }

    @isTest
    static void applyAt251ItemsSpendsOneReadAndOneDealWrite() {
        Transaction__c deal = newDeal();
        Checklist__c groupB = checklistFor(deal.Id, 'B');
        List<Checklist_Item__c> items =
            TestDataFactory.createChecklistItems(BULK_ITEMS, groupB.Id, true);
        List<Checklist_Item__c> completions = new List<Checklist_Item__c>();
        for (Checklist_Item__c item : items) {
            completions.add(new Checklist_Item__c(Id = item.Id, Flag__c = 'Completed'));
        }
        update completions;

        Test.startTest();
        Integer q0 = Limits.getQueries();
        ChecklistOutcomeService.applyForCompletedItems(new Map<Id, Checklist_Item__c>(items).keySet());
        Integer queries = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.areEqual(1, queries,
            'ONE read for 251 items — the outcome read must never be per-item');
        Assert.areEqual(1, ChecklistOutcomeService.lastRunDealWriteCount,
            '251 items on ONE deal produce ONE deal write, not 251');
        Assert.areEqual(true, reload(deal.Id).Earnest_Money_Sent__c,
            'and the single B5 among them still did its work');
    }

    @isTest
    static void nullAndEmptyInputsAreNoOps() {
        Test.startTest();
        Integer q0 = Limits.getQueries();
        ChecklistOutcomeService.applyForCompletedItems(null);
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>());
        Integer queries = Limits.getQueries() - q0;
        Test.stopTest();

        Assert.areEqual(0, queries, 'A no-op must not spend a query');
        Assert.areEqual(0, ChecklistOutcomeService.lastRunDealWriteCount, 'and writes nothing');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════════════════════════════════
    // 🔴 THE TWO RE-APPLICATION CONTROLS. They cover DIFFERENT paths and neither substitutes for
    // the other, so each is tested with its own positive control beside it.
    //   • `suppressOutcomeApplication` — the INSERT case (no `Trigger.oldMap` exists there).
    //   • the `priorByItemId` argument  — the UPDATE case (prior state does exist).
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void suppressionMakesTheWholeCallANoOpBeforeAnySoql() {
        // The migration brackets its DML with this flag. The early return must sit BEFORE the
        // outcome read, or a suppressed call still costs a query per chunk on the one path whose
        // governor budget is pinned to the statement.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);
        update new Checklist_Item__c(Id = b5.Id, Flag__c = 'Completed');

        Test.startTest();
        Boolean prior = ChecklistOutcomeService.isOutcomeApplicationSuppressed();
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        try {
            ChecklistOutcomeService.suppressOutcomeApplication(true);
            ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ b5.Id });
        } finally {
            // ⚠ RESTORE THE PRIOR VALUE, never blindly false — the same hazard
            // `ChecklistRollupService.suppressTriggerRecalc` documents.
            ChecklistOutcomeService.suppressOutcomeApplication(prior);
        }
        Integer queries = Limits.getQueries() - q0;
        Integer dml = Limits.getDmlStatements() - d0;
        Test.stopTest();

        Assert.areEqual(0, queries, 'A suppressed call must return before the outcome read');
        Assert.areEqual(0, dml, 'and before any write');
        Assert.areEqual(true, ChecklistOutcomeService.lastRunSuppressed,
            'and say so, because "suppressed" and "ran and found nothing" both leave every other '
                + 'counter at zero and would otherwise be indistinguishable');
        Assert.areEqual(false,
            [SELECT Earnest_Money_Sent__c FROM Transaction__c WHERE Id = :deal.Id]
                .Earnest_Money_Sent__c,
            'B5 stamped nothing while suppressed');
    }

    @isTest
    static void theSameCallAppliesNormallyOnceSuppressionIsLifted() {
        // 🔴 THE POSITIVE CONTROL FOR THE TEST ABOVE, AND IT IS THE HALF THAT MATTERS. A flag that
        // was accidentally left on — or a `finally` that restored the wrong value — would make the
        // suppression test pass forever while silently disabling the feature for everyone. This is
        // also the shape `scripts/backfill-checklist-outcomes.apex` relies on: it runs with the
        // flag at its default and expects outcomes to apply.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);
        update new Checklist_Item__c(Id = b5.Id, Flag__c = 'Completed');

        Test.startTest();
        Boolean prior = ChecklistOutcomeService.isOutcomeApplicationSuppressed();
        try {
            ChecklistOutcomeService.suppressOutcomeApplication(true);
            ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ b5.Id });
        } finally {
            ChecklistOutcomeService.suppressOutcomeApplication(prior);
        }
        // Same ids, same item, flag now restored to its prior (false) value.
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ b5.Id });
        Test.stopTest();

        Assert.areEqual(false, ChecklistOutcomeService.isOutcomeApplicationSuppressed(),
            'The finally restored the PRIOR value, not a blind false');
        Assert.areEqual(false, ChecklistOutcomeService.lastRunSuppressed,
            'so the second call was not suppressed');
        Assert.areEqual(true,
            [SELECT Earnest_Money_Sent__c FROM Transaction__c WHERE Id = :deal.Id]
                .Earnest_Money_Sent__c,
            'and it stamped B5 exactly as an unsuppressed call always did');
    }

    @isTest
    static void anAlreadyDoneItemDoesNotReApplyItsOutcome() {
        // 🔴 THE UPDATE-SIDE CONTROL. Editing a comment on an already-complete A5 must not re-run
        // `CriticalDateService`. The outcomes are internally idempotent today, so nothing visibly
        // breaks without this — which is exactly why it needs pinning at the DISPATCH level rather
        // than being left to luck at the outcome level.
        Transaction__c deal = newDeal();
        Checklist_Item__c a5 = itemAt(deal.Id, 'A', 5);
        update new Checklist_Item__c(Id = a5.Id, Flag__c = 'Completed');
        // The prior state as a service would have read it BEFORE its own DML: already done.
        Map<Id, Checklist_Item__c> priorAlreadyDone = new Map<Id, Checklist_Item__c>{
            a5.Id => new Checklist_Item__c(Id = a5.Id, Flag__c = 'Completed')
        };

        Test.startTest();
        ChecklistOutcomeService.applyForCompletedItems(
            new Set<Id>{ a5.Id }, priorAlreadyDone);
        Test.stopTest();

        Assert.areEqual(1, ChecklistOutcomeService.lastRunAlreadyDoneCount,
            'The item was skipped by the transition gate');
        Assert.areEqual(0, ChecklistOutcomeService.lastRunCriticalDateDealCount,
            'so CriticalDateService was never reached');
        Assert.areEqual(0, [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id],
            'and no critical dates were projected by an unrelated edit');
    }

    @isTest
    static void aNewlyDoneItemStillAppliesWithThePriorMapSupplied() {
        // The positive control for the transition gate. Without it, a gate that skipped EVERYTHING
        // would pass the test above and silently disable A5 and B5 on the only path humans use.
        Transaction__c deal = newDeal();
        Checklist_Item__c a5 = itemAt(deal.Id, 'A', 5);
        // Prior state = OPEN, which is what `selectForCompletion` returns before a real completion.
        Map<Id, Checklist_Item__c> priorOpen = new Map<Id, Checklist_Item__c>{
            a5.Id => new Checklist_Item__c(Id = a5.Id, Flag__c = 'None')
        };
        update new Checklist_Item__c(Id = a5.Id, Flag__c = 'Completed');

        Test.startTest();
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ a5.Id }, priorOpen);
        Test.stopTest();

        Assert.areEqual(0, ChecklistOutcomeService.lastRunAlreadyDoneCount,
            'A genuine transition is not skipped');
        Assert.isTrue(
            [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id] > 0,
            'and its outcome was applied'
        );
    }

    @isTest
    static void theAtRiskRefreshIsNotTransitionGated() {
        // 🔴 THE ONE THING THE GATE MUST NOT CATCH. `Is_Earnest_At_Risk__c` is derived from a DATE
        // and nothing saves a deal on the day feasibility expires — the entire staleness mitigation
        // is that ANY checklist activity refreshes it. Gating that alongside the derived outcomes
        // would make the flag permanently stale on every deal whose items are all already done,
        // which is most deals late in a transaction.
        Transaction__c deal = newDeal();
        update new Transaction__c(
            Id = deal.Id,
            Earnest_Money_Sent__c = true,
            Feasibility_Deadline__c = Date.today().addDays(-1)
        );
        Checklist_Item__c ordinary = itemAt(deal.Id, 'D', 3);
        update new Checklist_Item__c(Id = ordinary.Id, Flag__c = 'Completed');
        Map<Id, Checklist_Item__c> priorAlreadyDone = new Map<Id, Checklist_Item__c>{
            ordinary.Id => new Checklist_Item__c(Id = ordinary.Id, Flag__c = 'Completed')
        };

        Test.startTest();
        ChecklistOutcomeService.applyForCompletedItems(
            new Set<Id>{ ordinary.Id }, priorAlreadyDone);
        Test.stopTest();

        Assert.areEqual(true, reload(deal.Id).Is_Earnest_At_Risk__c,
            'The deal was refreshed even though the item was already done');
    }

    @isTest
    static void theNoPriorOverloadTreatsAnAlreadyDoneItemAsNewlyDone() {
        // 🔴 THIS IS WHAT MAKES `scripts/backfill-checklist-outcomes.apex` WORK AT ALL. Every item
        // that script processes was completed BEFORE Phase 5 existed, so under the gated overload
        // all of them look like re-saves. If the gate were the DEFAULT, the backfill would become a
        // silent no-op that logs success and leaves the cutover-day KPI reading zero.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);
        update new Checklist_Item__c(Id = b5.Id, Flag__c = 'Completed');

        Test.startTest();
        // Single-argument form: prior state unknown.
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ b5.Id });
        Test.stopTest();

        Assert.areEqual(0, ChecklistOutcomeService.lastRunAlreadyDoneCount,
            'With no prior map, an already-done item is treated as newly done');
        Assert.areEqual(true, reload(deal.Id).Earnest_Money_Sent__c,
            'and its outcome IS applied - which is the backfill contract');
    }

    @isTest
    static void anItemMissingFromThePriorMapIsTreatedAsATransition() {
        // The unresolved-key direction, which is deliberately the OPPOSITE of the fail-closed rule
        // used elsewhere in this class. Skipping a legitimate outcome is silent and permanent;
        // re-applying an idempotent one is not. Argued at `isTransitionIntoDone`.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);
        update new Checklist_Item__c(Id = b5.Id, Flag__c = 'Completed');

        Test.startTest();
        // A non-empty map that simply does not contain this item.
        ChecklistOutcomeService.applyForCompletedItems(
            new Set<Id>{ b5.Id },
            new Map<Id, Checklist_Item__c>{
                deal.Id => new Checklist_Item__c(Flag__c = 'Completed')
            }
        );
        Test.stopTest();

        Assert.areEqual(0, ChecklistOutcomeService.lastRunAlreadyDoneCount,
            'A missing key resolves toward applying, not toward skipping');
        Assert.areEqual(true, reload(deal.Id).Earnest_Money_Sent__c, 'so the outcome applied');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Fail-closed on an unresolvable deal (fault seam + presence control)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    @isTest
    static void anUnreadableItemIsCountedRatherThanReturningSilently() {
        // 🔴 THE SILENT-SUCCESS HOLE. An empty or short read is the NATURAL sharing failure here -
        // unlike the null-parent case below, which `selectForOutcomeByIds`'s own header says cannot
        // arise under `ControlledByParent`. Before this counter existed the method returned quietly
        // with every counter at zero, indistinguishable from "ran and found nothing", and the
        // backfill script added the size of the set it PASSED IN to its applied total and logged
        // success over deals it had not touched.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);
        Id vanishedId = b5.Id;
        delete b5;

        Test.startTest();
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ vanishedId });
        Test.stopTest();

        Assert.areEqual(1, ChecklistOutcomeService.lastRunUnreadableItems(),
            'An item that was asked for but not read must be COUNTED, not silently dropped');
        Assert.areEqual(0, ChecklistOutcomeService.lastRunConsideredItems(),
            'and nothing was considered');
        Assert.areEqual(false, ChecklistOutcomeService.lastRunSuppressed,
            'This is NOT the suppressed case - the two must stay distinguishable');
    }

    @isTest
    static void aFullyReadableBatchReportsZeroUnreadable() {
        // 🔴 THE PRESENCE CONTROL. A counter that only ever reported trouble - or one wired to the
        // wrong side of the diff - would make the test above pass while flagging every healthy run,
        // and the backfill script would refuse to ever declare itself clean.
        Transaction__c deal = newDeal();
        Checklist__c groupB = checklistFor(deal.Id, 'B');
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(5, groupB.Id, true);
        Set<Id> itemIds = new Map<Id, Checklist_Item__c>(items).keySet();

        Test.startTest();
        ChecklistOutcomeService.applyForCompletedItems(itemIds);
        Test.stopTest();

        Assert.areEqual(0, ChecklistOutcomeService.lastRunUnreadableItems(),
            'Every item was readable, so nothing is reported unreadable');
        Assert.areEqual(5, ChecklistOutcomeService.lastRunConsideredItems(),
            'and all five were considered - this is the number the backfill script reports as '
                + 'applied, never the size of the set it passed in');
    }

    @isTest
    static void aPartiallyReadableBatchCountsOnlyTheShortfall() {
        // The mixed case, which neither of the two above reaches: some ids resolve and some do not.
        // A counter computed as "all or nothing" would read 0 or 6 here instead of 1.
        Transaction__c deal = newDeal();
        Checklist__c groupB = checklistFor(deal.Id, 'B');
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(5, groupB.Id, true);
        Set<Id> itemIds = new Map<Id, Checklist_Item__c>(items).keySet();
        Checklist_Item__c doomed = TestDataFactory.createChecklistItems(1, groupB.Id, true)[0];
        itemIds.add(doomed.Id);
        delete doomed;

        Test.startTest();
        ChecklistOutcomeService.applyForCompletedItems(itemIds);
        Test.stopTest();

        Assert.areEqual(1, ChecklistOutcomeService.lastRunUnreadableItems(),
            'Exactly the shortfall is reported, not the whole batch');
        Assert.areEqual(5, ChecklistOutcomeService.lastRunConsideredItems(),
            'and the readable five were still processed');
    }

    @isTest
    static void theTestSeamNeverReportsAnUnreadableShortfall() {
        // ⚠ With `outcomeRowsOverride` set, `itemIds` and the row list are unrelated by
        // construction, so a diff between them would be meaningless noise that the backfill script
        // would surface as a sharing alarm. The service must not compute one on that path.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);
        update new Checklist_Item__c(Id = b5.Id, Flag__c = 'Completed');
        ChecklistOutcomeService.outcomeRowsOverride =
            ChecklistItemSelector.selectForOutcomeByIds(new Set<Id>{ b5.Id }).values();

        Test.startTest();
        // Deliberately asking for MORE ids than the seam supplies rows for.
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ b5.Id, deal.Id });
        Test.stopTest();

        Assert.areEqual(0, ChecklistOutcomeService.lastRunUnreadableItems(),
            'The seam supplies rows directly, so no shortfall is computed or reported');
        Assert.areEqual(true, reload(deal.Id).Earnest_Money_Sent__c,
            'and the outcome still applied, so the seam is genuinely live here');
    }

    @isTest
    static void anUnresolvableParentDealIsSkippedNotComputedFromNulls() {
        // 🔴 THE INVERSION THIS PREVENTS. `SYSTEM_MODE` lifts CRUD and FLS and NEVER sharing, and
        // `Transaction__c` is Private OWD, so a spanning read into a deal the caller cannot see
        // returns NULLS rather than throwing. A null `Feasibility_Deadline__c` reads as "feasibility
        // has not passed", which computes at-risk = FALSE — so an ACCESS problem would silently
        // CLEAR the flag on exactly the deals the portfolio KPI exists to surface.
        Transaction__c deal = newDeal();
        update new Transaction__c(
            Id = deal.Id,
            Earnest_Money_Sent__c = true,
            Feasibility_Deadline__c = Date.today().addDays(-1),
            Is_Earnest_At_Risk__c = true
        );
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);
        update new Checklist_Item__c(Id = b5.Id, Flag__c = 'Completed');

        // A row shaped exactly as a sharing-filtered read returns one: the lookup id is present,
        // the traversed record is not.
        Checklist_Item__c filtered = new Checklist_Item__c(
            Id = b5.Id, Sequence__c = 5, Flag__c = 'Completed'
        );
        ChecklistOutcomeService.outcomeRowsOverride = new List<Checklist_Item__c>{ filtered };

        Test.startTest();
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ b5.Id });
        Test.stopTest();

        Assert.areEqual(1, ChecklistOutcomeService.lastRunUnresolvedDealCount,
            'The unreadable deal is COUNTED, so an access problem is visible rather than silent');
        Assert.areEqual(0, ChecklistOutcomeService.lastRunDealWriteCount, 'and nothing was written');
        Assert.areEqual(true, reload(deal.Id).Is_Earnest_At_Risk__c,
            'The pre-existing at-risk flag survives — it must never be cleared by a read that '
                + 'could not see the deal');
    }

    @isTest
    static void theSeamItselfCanStillApplyAnOutcome() {
        // 🔴 THE PRESENCE CONTROL FOR THE TEST ABOVE. A seam that only ever produced "nothing
        // happened" would make that test pass for the wrong reason forever. This feeds a FULLY
        // RESOLVABLE row through the same seam and asserts the outcome IS applied.
        Transaction__c deal = newDeal();
        Checklist_Item__c b5 = itemAt(deal.Id, 'B', 5);
        update new Checklist_Item__c(Id = b5.Id, Flag__c = 'Completed');

        ChecklistOutcomeService.outcomeRowsOverride =
            ChecklistItemSelector.selectForOutcomeByIds(new Set<Id>{ b5.Id }).values();

        Test.startTest();
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ b5.Id });
        Test.stopTest();

        Assert.areEqual(0, ChecklistOutcomeService.lastRunUnresolvedDealCount,
            'A resolvable row is not counted as unresolved');
        Assert.areEqual(1, ChecklistOutcomeService.lastRunDealWriteCount, 'and it is written');
        Assert.areEqual(true, reload(deal.Id).Earnest_Money_Sent__c,
            'B5 stamped the flag through the seam, so the seam is genuinely live');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // Fixtures
    // ═══════════════════════════════════════════════════════════════════════════════════════

    private static Transaction__c newDeal() {
        return TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
    }

    /**
     * A checklist group at a CHOSEN letter. `TestDataFactory.createChecklist` always produces `A`,
     * and Phase 5 keys entirely on the coordinate, so the letter is the fixture's load-bearing part.
     */
    private static Checklist__c checklistFor(Id dealId, String letter) {
        Checklist__c checklistGroup = TestDataFactory.createChecklist(dealId, false);
        checklistGroup.Group_Letter__c = letter;
        insert checklistGroup;
        return checklistGroup;
    }

    /** One item at an exact coordinate. Items 1..sequence are created; the last one is returned. */
    private static Checklist_Item__c itemAt(Id dealId, String letter, Integer sequence) {
        Checklist__c checklistGroup = checklistFor(dealId, letter);
        List<Checklist_Item__c> items =
            TestDataFactory.createChecklistItems(sequence, checklistGroup.Id, true);
        return items[sequence - 1];
    }

    /** Completes the item the way the trigger and the service would, then applies the outcome. */
    private static void completeAndApply(Checklist_Item__c item) {
        update new Checklist_Item__c(Id = item.Id, Flag__c = 'Completed');
        ChecklistOutcomeService.applyForCompletedItems(new Set<Id>{ item.Id });
    }

    private static Transaction__c reload(Id dealId) {
        return [
            SELECT Id, Earnest_Money_Sent__c, Earnest_Money_Sent_Date__c, EM_Wired_Date__c,
                   Is_Earnest_At_Risk__c, Feasibility_Deadline__c, Stage__c, Status__c
            FROM Transaction__c
            WHERE Id = :dealId
        ];
    }
}
