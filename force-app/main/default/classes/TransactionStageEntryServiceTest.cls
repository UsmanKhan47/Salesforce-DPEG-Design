/**
 * Tests for the `Transaction__c.Stage_Entry_Date__c` stamp.
 *
 * The three claims that matter, each with its own test:
 *   • ENTRY, not presence - re-entering a stage RESTARTS the clock, so the stamp is unconditional
 *     on a genuine transition. A `if (field == null)` guard would silently reintroduce the bug the
 *     field exists to avoid (`OpportunityStageEntryService.cls:212` records that incident).
 *   • A save that does not move the stage leaves the date ALONE - which is what makes it safe to
 *     put this on an object the fan-out and both rollups update several times per deal creation.
 *   • ZERO SOQL AND ZERO DML AT ANY RECORD COUNT, asserted from counters captured INSIDE the trigger
 *     context. `Test.stopTest()` restores the pre-test governor counters, so the obvious
 *     `Limits.getQueries()` assertion after it is silently vacuous.
 *
 * BULK: 251 records, forcing a second before-trigger firing (`.claude/rules/bulk-test-rule.md`).
 *
 * ⚠ EVERY DEAL IS BUILT BY `TestDataFactory.createTransactionsOnChecklistModel`, WHICH NULLS
 * `Contract_Executed_Date__c` AND SUPPRESSES THE DAY-0 FAN-OUT. That field is the first entry
 * filter of `flows/Transaction_Task_Fanout`, repointed onto `ChecklistFanoutService` on 2026-09-03.
 * The date is load-bearing for nothing here - the stamp reads `Stage__c` and `Trigger.oldMap` and
 * writes `Stage_Entry_Date__c`, and no assertion below reads the contract execution date or any
 * value derived from it. It matters most at 251, where the fan-out would be fatal rather than
 * merely wasteful; see the note on that test.
 */
@isTest
private class TransactionStageEntryServiceTest {

    @isTest
    static void stampsOnInsertAtTheCreationStage() {
        Test.startTest();
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        Test.stopTest();

        Transaction__c reloaded = [
            SELECT Stage__c, Stage_Entry_Date__c FROM Transaction__c WHERE Id = :deal.Id
        ];
        Assert.areEqual(Date.today(), reloaded.Stage_Entry_Date__c,
            'Every inserted deal counts as ENTERING the stage it was created at');
    }

    @isTest
    static void stampsOnAGenuineStageChange() {
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        // Backdate so the re-stamp is observable rather than coincidentally equal.
        update new Transaction__c(Id = deal.Id, Stage_Entry_Date__c = Date.today().addDays(-30));

        Test.startTest();
        update new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence');
        Test.stopTest();

        Assert.areEqual(Date.today(),
            [SELECT Stage_Entry_Date__c FROM Transaction__c WHERE Id = :deal.Id].Stage_Entry_Date__c,
            'A stage change restamps the date');
    }

    @isTest
    static void overwritesAnExistingDateOnReEntry() {
        // THE DELIBERATE DIVERGENCE FROM `stampListingDates`: unconditional, not fill-if-blank. A
        // deal that leaves a stage and comes back has ENTERED it again, and any days-in-stage clock
        // must restart. Fill-if-blank would report a revived deal as stuck since the first visit.
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        update new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence');
        update new Transaction__c(Id = deal.Id, Stage_Entry_Date__c = Date.today().addDays(-90));

        Test.startTest();
        update new Transaction__c(Id = deal.Id, Stage__c = 'Open Contract');
        Test.stopTest();

        Assert.areEqual(Date.today(),
            [SELECT Stage_Entry_Date__c FROM Transaction__c WHERE Id = :deal.Id].Stage_Entry_Date__c,
            'Re-entering a stage RESTARTS the clock, overwriting the older value');
    }

    @isTest
    static void leavesTheDateAloneWhenTheStageDoesNotMove() {
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        Date pinned = Date.today().addDays(-14);
        update new Transaction__c(Id = deal.Id, Stage_Entry_Date__c = pinned);

        Test.startTest();
        // A counter write of exactly the shape `ChecklistRollupService` and the fan-out perform.
        update new Transaction__c(Id = deal.Id, Tasks_Complete__c = 5, Wire_Open_Risks__c = 1);
        Test.stopTest();

        Assert.areEqual(pinned,
            [SELECT Stage_Entry_Date__c FROM Transaction__c WHERE Id = :deal.Id].Stage_Entry_Date__c,
            'A rollup write must not disturb the stage clock - this is what keeps a trigger on this '
                + 'object affordable');
    }

    @isTest
    static void costsZeroQueriesAndZeroDmlAcross251Records() {
        // 🔴 VOLUME STAYS AT 251; THE FACTORY IS THE SUPPRESSING ONE. `createTransactions` sets
        // `Contract_Executed_Date__c`, so all 251 deals would enter
        // `flows/Transaction_Task_Fanout` on this single insert and hand ~96 checklist rows apiece
        // to `ChecklistFanoutService` - roughly 24,000 rows at `Test.stopTest()`, well past the
        // 10,000-row DML ceiling, and the method would die on a limit that has nothing to do with
        // the stamp. Suppressing costs the test nothing: the stamp reads `Stage__c` and writes
        // `Stage_Entry_Date__c`, and touches neither the contract execution date nor anything
        // derived from it.
        List<Transaction__c> deals = TestDataFactory.createTransactionsOnChecklistModel(251, false);

        Test.startTest();
        TransactionStageEntryService.resetRunCounters();
        insert deals;
        // 🔴 CAPTURED INSIDE. stopTest restores the pre-test counters.
        Integer queries = TransactionStageEntryService.runQueryCount;
        Integer dml = TransactionStageEntryService.runDmlCount;
        Integer chunks = TransactionStageEntryService.runChunkCount;
        Integer stamps = TransactionStageEntryService.runStampCount;
        Test.stopTest();

        Assert.isTrue(chunks >= 2,
            'A 251-record insert must fire the before-trigger at least twice; fired ' + chunks);
        Assert.areEqual(0, queries, 'The stamp must never query, at any record count');
        Assert.areEqual(0, dml, 'The stamp must never perform DML, at any record count');
        Assert.areEqual(251, stamps, 'Every inserted deal is a stage entry');
    }

    @isTest
    static void isNullSafeOutsideATriggerContext() {
        Test.startTest();
        TransactionStageEntryService.stampStageEntryDates(null, null);
        TransactionStageEntryService.stampStageEntryDates(new List<Transaction__c>(), null);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Transaction__c],
            'A null or empty collection is a no-op, never a throw');
    }
}
