/**
 * Tests for the Apex checklist rollups.
 *
 * The two predicates that fail silently in the unsafe direction each get their own named test:
 *   • `countsVerifiedItemsAsComplete`  - DONE means Completed OR Verified. A rollup written against
 *     `Completed` alone undercounts every verified item with no error anywhere.
 *   • `countsOpenWireRisksFromTheBooleanNotTheSubject` - the RISK 1 canary. The legacy service reads
 *     `Subject.contains('anti-fraud')`; this one must read `Is_Wire_Verification__c`.
 * Plus the dual-model guard, which is what lets Phase 2 deploy without disturbing a single live deal.
 *
 * BULK: 251 `Checklist_Item__c` rows per `.claude/rules/bulk-test-rule.md` - the object under test
 * is the item, the trigger chunks at 200, and 251 is what forces the second after-insert firing.
 */
@isTest
private class ChecklistRollupServiceTest {

    @TestSetup
    static void setupTestData() {
        // 🔴 `createTransactionsOnChecklistModel`, NOT `createTransactions`. A plain test deal
        // enqueues the LEGACY Task fan-out, which writes Tasks_Total__c = 70 at `Test.stopTest()`
        // and makes every deal-counter assertion below assert against the wrong writer. See that
        // factory method for the full arithmetic.
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        // The rollup writes the Transaction counters ONLY for a fanned-out deal, so the fixture
        // sets the guard directly - the single-writer discriminator is the production rule, and a
        // test that ignored it would assert against a branch production never takes.
        update new Transaction__c(Id = deal.Id, Checklist_Fanned_Out__c = true);
        Checklist__c checklistGroup = TestDataFactory.createChecklist(deal.Id, true);
        TestDataFactory.createChecklistItems(4, checklistGroup.Id, true);
    }

    /** @return The single fixture deal, with its four counters. */
    private static Transaction__c reloadDeal() {
        return [
            SELECT Tasks_Total__c, Tasks_Complete__c, Tasks_Overdue__c, Wire_Open_Risks__c,
                   Checklist_Fanned_Out__c
            FROM Transaction__c LIMIT 1
        ];
    }

    @isTest
    static void recomputesBothLevelsOnInsert() {
        Test.startTest();
        Checklist__c checklistGroup = [SELECT Id, Items_Total__c, Items_Complete__c FROM Checklist__c LIMIT 1];
        Test.stopTest();

        Assert.areEqual(4, checklistGroup.Items_Total__c, 'The group counter is written by the trigger');
        Assert.areEqual(0, checklistGroup.Items_Complete__c, 'Nothing is complete yet');
        Assert.areEqual(4, reloadDeal().Tasks_Total__c, 'And the deal counter rolls up from it');
    }

    @isTest
    static void countsVerifiedItemsAsComplete() {
        List<Checklist_Item__c> items = [SELECT Id FROM Checklist_Item__c ORDER BY Sequence__c];

        Test.startTest();
        update new List<Checklist_Item__c>{
            new Checklist_Item__c(Id = items[0].Id, Flag__c = 'Completed'),
            new Checklist_Item__c(Id = items[1].Id, Flag__c = 'Verified')
        };
        Test.stopTest();

        Checklist__c checklistGroup = [SELECT Items_Complete__c FROM Checklist__c LIMIT 1];
        Assert.areEqual(2, checklistGroup.Items_Complete__c,
            'DONE means Completed OR Verified - counting Completed alone silently undercounts '
                + 'every verified item');
        Assert.areEqual(2, reloadDeal().Tasks_Complete__c, 'Same test at the deal level');
    }

    @isTest
    static void countsOpenWireRisksFromTheBooleanNotTheSubject() {
        // 🔴 RISK 1. The item's SUBJECT deliberately does NOT contain 'anti-fraud', so a service
        // that still parsed the subject would read zero here and this test would fail - which is
        // exactly the silent failure it exists to make loud.
        Checklist__c checklistGroup = [SELECT Id FROM Checklist__c LIMIT 1];
        Checklist_Item__c wireItem = TestDataFactory.createChecklistItem(checklistGroup.Id, false);
        wireItem.Sequence__c = 90;
        wireItem.Subject__c = 'Call the title company and confirm the account details by phone';
        wireItem.Is_Wire_Verification__c = true;

        Test.startTest();
        insert wireItem;
        Test.stopTest();

        Assert.areEqual(1, reloadDeal().Wire_Open_Risks__c,
            'An open wire-verification item must be counted from Is_Wire_Verification__c');
    }

    @isTest
    static void clearsAWireRiskWhenTheVerbalVerificationIsRecorded() {
        // The predicate deliberately mirrors the LEGACY one (verbal verification, not Flag__c) so
        // the Phase 4 M2 reconciliation can compare the two mechanisms on the same deal.
        Checklist__c checklistGroup = [SELECT Id FROM Checklist__c LIMIT 1];
        Checklist_Item__c wireItem = TestDataFactory.createChecklistItem(checklistGroup.Id, false);
        wireItem.Sequence__c = 91;
        wireItem.Is_Wire_Verification__c = true;
        insert wireItem;

        Test.startTest();
        update new Checklist_Item__c(Id = wireItem.Id, Verbal_Verification_Completed__c = true);
        Test.stopTest();

        Assert.areEqual(0, reloadDeal().Wire_Open_Risks__c,
            'A verified wire item is no longer an open risk');
    }

    @isTest
    static void countsOverdueOpenItemsOnly() {
        List<Checklist_Item__c> items = [SELECT Id FROM Checklist_Item__c ORDER BY Sequence__c];

        Test.startTest();
        update new List<Checklist_Item__c>{
            new Checklist_Item__c(Id = items[0].Id, Due_Date__c = Date.today().addDays(-3)),
            new Checklist_Item__c(Id = items[1].Id, Due_Date__c = Date.today().addDays(-3),
                Flag__c = 'Completed')
        };
        Test.stopTest();

        Assert.areEqual(1, reloadDeal().Tasks_Overdue__c,
            'A past-due item that is DONE is not overdue');
    }

    @isTest
    static void recomputesOnDelete() {
        Checklist_Item__c doomed = [SELECT Id FROM Checklist_Item__c LIMIT 1];

        Test.startTest();
        delete doomed;
        Test.stopTest();

        Assert.areEqual(3, [SELECT Items_Total__c FROM Checklist__c LIMIT 1].Items_Total__c,
            'Deleting an item must move the group counter');
        Assert.areEqual(3, reloadDeal().Tasks_Total__c, 'And the deal counter');
    }

    @isTest
    static void recomputesOnUndelete() {
        Checklist_Item__c doomed = [SELECT Id FROM Checklist_Item__c LIMIT 1];
        delete doomed;

        Test.startTest();
        undelete doomed;
        Test.stopTest();

        Assert.areEqual(4, [SELECT Items_Total__c FROM Checklist__c LIMIT 1].Items_Total__c,
            'Undelete must restore the counter');
    }

    @isTest
    static void doesNotWriteTheDealCountersForANonFannedOutDeal() {
        // 🔴 THE DUAL-MODEL GUARD. `TaskRollupService` writes these same four fields from the Task
        // model and is still live; without this guard the two would fight and the winner would be
        // whichever fired last. A deal the checklist fan-out has not claimed must be left alone.
        // Legacy-model deal: the Task fan-out guard is set, so the hand-written counters below
        // stand in for what `TaskRollupService` wrote, exactly as a real cut-over-pending deal looks.
        Transaction__c legacyDeal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        update new Transaction__c(Id = legacyDeal.Id, Tasks_Total__c = 82, Tasks_Complete__c = 7);
        Checklist__c checklistGroup = TestDataFactory.createChecklist(legacyDeal.Id, true);

        Test.startTest();
        TestDataFactory.createChecklistItems(3, checklistGroup.Id, true);
        Test.stopTest();

        Transaction__c reloaded = [
            SELECT Tasks_Total__c, Tasks_Complete__c FROM Transaction__c WHERE Id = :legacyDeal.Id
        ];
        Assert.areEqual(82, reloaded.Tasks_Total__c,
            'A deal still on the Task model must keep the counters TaskRollupService wrote');
        Assert.areEqual(7, reloaded.Tasks_Complete__c, 'Both of them');
        Assert.areEqual(3, [SELECT Items_Total__c FROM Checklist__c WHERE Id = :checklistGroup.Id].Items_Total__c,
            'The CHECKLIST level is still maintained - only the deal level is guarded');
    }

    @isTest
    static void suppressionStopsTheTriggerRecalc() {
        Checklist__c checklistGroup = [SELECT Id FROM Checklist__c LIMIT 1];

        Test.startTest();
        Boolean prior = ChecklistRollupService.isTriggerRecalcSuppressed();
        try {
            ChecklistRollupService.suppressTriggerRecalc(true);
            TestDataFactory.createChecklistItems(2, checklistGroup.Id, true);
        } finally {
            ChecklistRollupService.suppressTriggerRecalc(prior);
        }
        Test.stopTest();

        Assert.areEqual(4, [SELECT Items_Total__c FROM Checklist__c LIMIT 1].Items_Total__c,
            'While suppressed the trigger must not recompute - the fan-out writes the counters '
                + 'itself, once, instead of 21 times');
    }

    @isTest
    static void bulkInsertRecomputesEveryItem() {
        // 251 crosses the 200-row trigger chunk boundary, which is the entire point of the number.
        Checklist__c checklistGroup = [SELECT Id FROM Checklist__c LIMIT 1];
        List<Checklist_Item__c> items = TestDataFactory.createChecklistItems(251, checklistGroup.Id, false);
        for (Integer i = 0; i < items.size(); i++) {
            items[i].Sequence__c = i + 100;
            if (Math.mod(i, 2) == 0) {
                items[i].Flag__c = 'Completed';
            }
        }

        Test.startTest();
        insert items;
        Test.stopTest();

        Checklist__c reloadedGroup = [SELECT Items_Total__c, Items_Complete__c FROM Checklist__c LIMIT 1];
        Assert.areEqual(255, reloadedGroup.Items_Total__c, '251 new items plus the 4 from the fixture');
        Assert.areEqual(126, reloadedGroup.Items_Complete__c,
            'Every even-indexed item of the 251 was created Completed');
        Assert.areEqual(255, reloadDeal().Tasks_Total__c, 'And the deal counter agrees');
    }

    @isTest
    static void entryPointsAreNullSafe() {
        Test.startTest();
        ChecklistRollupService.recalc(null);
        ChecklistRollupService.recalc(new Set<Id>{ null });
        ChecklistRollupService.recalcForChecklistIds(null);
        ChecklistRollupService.recalcForChecklistIds(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(4, [SELECT Items_Total__c FROM Checklist__c LIMIT 1].Items_Total__c,
            'Null and empty inputs must be no-ops, never throws and never a recompute to zero');
    }
}
