/**
 * Tests for `ChecklistSelector` and `ChecklistItemSelector`.
 *
 * ⚠ BULK VOLUME IS 20, NOT 251, AND THAT IS DELIBERATE. Both classes under test are pure SELECTOR
 * READS: a query has no batch chunking, so its behaviour at 251 rows is identical to its behaviour
 * at 20. The 251 mandate in `.claude/rules/bulk-test-rule.md` exists to force a SECOND TRIGGER
 * FIRING, which does not apply to a query - and here every one of those rows would also fire the
 * `Checklist_Item__c` trigger and its rollup, so the volume would be testing the rollup rather than
 * the selector. The 251 tests that matter live in `ChecklistItemPrerequisiteServiceTest` and
 * `ChecklistRollupServiceTest`, against the objects whose triggers actually chunk.
 *
 * ⚠ THE `SYSTEM_MODE` READS ARE NOT PROVEN BY THESE TESTS AND CANNOT BE. The test runner is an
 * administrator, so a `USER_MODE` version of the same query would pass here too. What SYSTEM_MODE
 * buys is survival for a Minimum Access persona against a field with zero FieldPermissions, and that
 * is only observable against a real org with a real permission set - it is called out in the report
 * as unverifiable without running.
 */
@isTest
private class ChecklistSelectorTest {

    private static final Integer BULK_ROWS = 20;

    @TestSetup
    static void setupTestData() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        Checklist__c group = TestDataFactory.createChecklist(deal.Id, true);
        TestDataFactory.createChecklistItems(BULK_ROWS, group.Id, true);
    }

    @isTest
    static void selectsChecklistsByTransactionWithTheFieldsTheRollupNeeds() {
        Transaction__c deal = [SELECT Id FROM Transaction__c LIMIT 1];

        Test.startTest();
        List<Checklist__c> checklists =
            ChecklistSelector.selectByTransactionIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, checklists.size(), 'One group on the fixture deal');
        Assert.areEqual('A', checklists[0].Group_Letter__c, 'Group_Letter__c is populated');
        Assert.areEqual(BULK_ROWS, checklists[0].Items_Total__c,
            'Items_Total__c is populated, and the trigger has already written it');
        Assert.isNotNull(checklists[0].Stage__c, 'Stage__c is populated');
    }

    @isTest
    static void selectsChecklistsByIdKeyedForTheHandler() {
        Checklist__c group = [SELECT Id, Transaction__c FROM Checklist__c LIMIT 1];

        Test.startTest();
        Map<Id, Checklist__c> byId = ChecklistSelector.selectByIds(new Set<Id>{ group.Id });
        Test.stopTest();

        Assert.areEqual(group.Transaction__c, byId.get(group.Id).Transaction__c,
            'The checklist-to-deal projection is what the item trigger cannot get from Trigger.new');
    }

    @isTest
    static void selectsItemsByTransactionWithTheGrandparentTraversed() {
        Transaction__c deal = [SELECT Id FROM Transaction__c LIMIT 1];

        Test.startTest();
        List<Checklist_Item__c> items =
            ChecklistItemSelector.selectByTransactionIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(BULK_ROWS, items.size(), 'Every item on the deal');
        Assert.areEqual(deal.Id, items[0].Checklist__r.Transaction__c,
            'The grandparent traversal is what lets the rollup group by deal in one query');
        Assert.areEqual(1, items[0].Sequence__c, 'Ordered by group sequence then item sequence');
    }

    @isTest
    static void selectsItemsByIdWithTheDealForTheGate() {
        List<Checklist_Item__c> items = [SELECT Id FROM Checklist_Item__c LIMIT 2];
        Set<Id> ids = new Set<Id>{ items[0].Id, items[1].Id };

        Test.startTest();
        Map<Id, Checklist_Item__c> byId = ChecklistItemSelector.selectByIdsWithDeal(ids);
        Map<Id, Checklist_Item__c> forCompletion = ChecklistItemSelector.selectForCompletion(ids);
        Test.stopTest();

        Assert.areEqual(2, byId.size(), 'Both rows come back, keyed by Id');
        Assert.isNotNull(byId.get(items[0].Id).Checklist__r.Transaction__c,
            'The gate needs the deal on BOTH sides to refuse a cross-deal prerequisite');
        Assert.areEqual(2, forCompletion.size(), 'The USER_MODE read returns the same rows for an admin');
    }

    @isTest
    static void allSelectorsAreNullAndEmptySafe() {
        Test.startTest();
        Assert.isTrue(ChecklistSelector.selectByTransactionIds(null).isEmpty(), 'null in, empty out');
        Assert.isTrue(ChecklistSelector.selectByTransactionIds(new Set<Id>()).isEmpty(), 'empty in');
        Assert.isTrue(ChecklistSelector.selectByIds(null).isEmpty(), 'null in, empty map out');
        Assert.isTrue(ChecklistSelector.selectByIds(new Set<Id>()).isEmpty(), 'empty in');
        Assert.isTrue(ChecklistItemSelector.selectByTransactionIds(null).isEmpty(), 'null in');
        Assert.isTrue(
            ChecklistItemSelector.selectByTransactionIds(new Set<Id>()).isEmpty(), 'empty in');
        Assert.isTrue(ChecklistItemSelector.selectByIdsWithDeal(null).isEmpty(), 'null in');
        Assert.isTrue(ChecklistItemSelector.selectByIdsWithDeal(new Set<Id>()).isEmpty(), 'empty in');
        Assert.isTrue(ChecklistItemSelector.selectForCompletion(null).isEmpty(), 'null in');
        Assert.isTrue(ChecklistItemSelector.selectForCompletion(new Set<Id>()).isEmpty(), 'empty in');
        Test.stopTest();
    }

    @isTest
    static void transactionSelectorReadsTheChecklistGuardAndTheConditionField() {
        Transaction__c deal = [SELECT Id FROM Transaction__c LIMIT 1];

        Test.startTest();
        Map<Id, Transaction__c> deals = TransactionSelector.selectForChecklistFanout(
            new Set<Id>{ deal.Id },
            // A real field and a bogus one: the bogus one must be describe-rejected, not injected.
            new Set<String>{ 'Loan_Required__c', 'No_Such_Field__c', '  ', null });
        Map<Id, Transaction__c> forDates =
            TransactionSelector.selectForCriticalDates(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.isFalse(deals.get(deal.Id).Checklist_Fanned_Out__c,
            'The NEW guard is readable and starts false');
        Assert.isFalse((Boolean) deals.get(deal.Id).get('Loan_Required__c'),
            'A valid condition field is added to the SELECT');
        Assert.isNotNull(forDates.get(deal.Id).Target_Close_Date__c,
            'The critical-date read carries the pinned source fields');
        Assert.isTrue(TransactionSelector.selectForChecklistFanout(null, null).isEmpty(),
            'null in, empty map out');
    }
}
