/**
 * Tests for `InsuranceBinderSelector`. The twin of `LoanSelectorTest`; read that class's header for
 * the fixture and administrator-context caveats, which apply here unchanged.
 *
 * 🔴 251, NOT 20. `Insurance_Binder__c` is an ordinary custom object, so
 * `.claude/rules/content-publication-rule.md`'s reduced ceiling does not apply and
 * `.claude/rules/bulk-test-rule.md`'s default volume stands.
 */
@isTest
private class InsuranceBinderSelectorTest {

    private static final Integer BULK_ROWS = 251;

    @TestSetup
    static void setup() {
        List<Transaction__c> deals = TestDataFactory.createTransactionsOnChecklistModel(2, true);
        insert new List<Insurance_Binder__c>{
            new Insurance_Binder__c(Transaction__c = deals[0].Id, Carrier_Name__c = 'First Mutual'),
            new Insurance_Binder__c(Transaction__c = deals[1].Id, Carrier_Name__c = 'Second Mutual')
        };
    }

    @isTest
    static void selectByTransactionIdsReturnsOnlyTheRequestedDeals() {
        List<Transaction__c> deals = allDeals();

        Test.startTest();
        List<Insurance_Binder__c> binders =
            InsuranceBinderSelector.selectByTransactionIds(new Set<Id>{ deals[0].Id });
        Test.stopTest();

        Assert.areEqual(1, binders.size(), 'Only the requested deal binder comes back');
        Assert.areEqual('First Mutual', binders[0].Carrier_Name__c, 'With its carrier populated');
    }

    @isTest
    static void everyCaptureFieldIsSelectedAndIsBoundIsDerived() {
        List<Transaction__c> deals = allDeals();

        Test.startTest();
        List<Insurance_Binder__c> binders =
            InsuranceBinderSelector.selectByTransactionIds(new Set<Id>{ deals[0].Id });
        Test.stopTest();

        Integer touched = 0;
        for (ChecklistCaptureDefProvider.CaptureDef def : ChecklistCaptureDefProvider.all().values()) {
            if (!ChecklistCaptureDefProvider.TARGET_BINDER.equals(def.targetObject)) {
                continue;
            }
            for (String apiName : def.captureFields) {
                binders[0].get(apiName);
                touched++;
            }
        }
        Assert.isTrue(touched >= 5,
            'Expected at least the five named binder data points, checked ' + touched);
        Assert.areEqual(false, binders[0].Is_Bound__c,
            'Is_Bound__c is a formula over a blank Bound_Date__c and must read false, not null');
    }

    @isTest
    static void isBoundFollowsBoundDateWithoutBeingWritten() {
        // 🔴 THE FORMULA IS THE POINT. Nothing in Phase 5 ever writes Is_Bound__c; it must move on
        // its own the moment G5 records the bound date, or the two could disagree.
        Transaction__c deal = allDeals()[0];
        Insurance_Binder__c binder =
            [SELECT Id FROM Insurance_Binder__c WHERE Transaction__c = :deal.Id LIMIT 1];

        Test.startTest();
        update new Insurance_Binder__c(Id = binder.Id, Bound_Date__c = Date.today());
        List<Insurance_Binder__c> after =
            InsuranceBinderSelector.selectByTransactionIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(true, after[0].Is_Bound__c,
            'Setting Bound_Date__c alone must flip Is_Bound__c — it is derived, never stamped');
    }

    @isTest
    static void selectByTransactionIdsIsOrderedOldestFirst() {
        // ⚠ Multiple binders per deal is ORDINARY here, not a lost race — property, liability and
        // flood are commonly separate. The ordering picks WHICH ONE the checklist tracks.
        Transaction__c deal = allDeals()[0];
        insert new Insurance_Binder__c(Transaction__c = deal.Id, Carrier_Name__c = 'Flood Mutual');

        Test.startTest();
        List<Insurance_Binder__c> binders =
            InsuranceBinderSelector.selectByTransactionIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(2, binders.size(), 'Both binders come back — no silent LIMIT 1');
        Assert.areEqual('First Mutual', binders[0].Carrier_Name__c, 'Oldest first');
    }

    @isTest
    static void nullAndEmptyInputsReturnEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Insurance_Binder__c> fromNull = InsuranceBinderSelector.selectByTransactionIds(null);
        List<Insurance_Binder__c> fromEmpty =
            InsuranceBinderSelector.selectByTransactionIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'Null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'Empty input returns an empty list');
        Assert.areEqual(0, spent, 'A short-circuited read must not spend a query');
    }

    @isTest
    static void selectByTransactionIdsCosts251RowsExactlyOneQuery() {
        Transaction__c deal = allDeals()[0];
        List<Insurance_Binder__c> bulkRows = new List<Insurance_Binder__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            bulkRows.add(new Insurance_Binder__c(Transaction__c = deal.Id, Carrier_Name__c = 'C ' + i));
        }
        insert bulkRows;

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Insurance_Binder__c> binders =
            InsuranceBinderSelector.selectByTransactionIds(new Set<Id>{ deal.Id });
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_ROWS + 1, binders.size(), 'All rows come back in one read');
        Assert.areEqual(1, spent, 'One query regardless of row count');
    }

    private static List<Transaction__c> allDeals() {
        return [SELECT Id FROM Transaction__c ORDER BY CreatedDate ASC, Id ASC];
    }
}
