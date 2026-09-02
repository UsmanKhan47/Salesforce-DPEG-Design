/**
 * Tests for `LoanSelector`.
 *
 * ⚠ FIXTURES ARE BUILT HERE RATHER THAN IN `TestDataFactory`. There is no `createLoans` helper and
 * one is not added by this phase: `TestDataFactory` is a hub file that a concurrent session is
 * editing, and a second writer in it is how two features silently become one broken file. The rows
 * are three fields wide, so the cost of building them locally is trivial.
 *
 * ⚠ THE RUNNING TEST USER IS AN ADMINISTRATOR, so every `USER_MODE` read here passes on CRUD, FLS
 * and sharing regardless of whether the permission sets are correct. That is a real blind spot and
 * it is NOT closed by adding more admin-context assertions — the denial coverage that matters is
 * `runAs` against a `Minimum Access` persona, and it belongs with the permission pass rather than
 * with a selector that has no branch to take. What IS asserted here is everything the selector
 * itself decides: the filter, the ordering, and the null-safety.
 */
@isTest
private class LoanSelectorTest {

    /**
     * 🔴 251, NOT 20. `.claude/rules/content-publication-rule.md`'s reduced ceiling applies only to
     * `ContentVersion` / `ContentNote` / `ContentDocument`, whose inserts consume a non-refundable
     * org-wide quota. `Loan__c` is an ordinary custom object with no such cost, so
     * `.claude/rules/bulk-test-rule.md`'s default volume stands.
     */
    private static final Integer BULK_ROWS = 251;

    @TestSetup
    static void setup() {
        List<Transaction__c> deals = TestDataFactory.createTransactionsOnChecklistModel(2, true);
        insert new List<Loan__c>{
            new Loan__c(Transaction__c = deals[0].Id, Lender_Name__c = 'First Bank'),
            new Loan__c(Transaction__c = deals[1].Id, Lender_Name__c = 'Second Bank')
        };
    }

    @isTest
    static void selectByTransactionIdsReturnsOnlyTheRequestedDeals() {
        List<Transaction__c> deals = allDeals();

        Test.startTest();
        List<Loan__c> loans =
            LoanSelector.selectByTransactionIds(new Set<Id>{ deals[0].Id });
        Test.stopTest();

        Assert.areEqual(1, loans.size(), 'Only the requested deal loan comes back');
        Assert.areEqual(deals[0].Id, loans[0].Transaction__c, 'And it is that deal loan');
        Assert.areEqual('First Bank', loans[0].Lender_Name__c,
            'Lender_Name__c must be in the SELECT — the capture guard reads it');
    }

    @isTest
    static void everyCaptureFieldIsSelected() {
        // 🔴 A FIELD THE CAPTURE MAP NAMES BUT THE SELECTOR DOES NOT SELECT throws
        // `System.SObjectException: SObject row was retrieved via SOQL without querying the
        // requested field` — at runtime, inside the completion guard, with no compile-time warning.
        // This walks the map and touches every field, so the two cannot drift apart.
        List<Transaction__c> deals = allDeals();

        Test.startTest();
        List<Loan__c> loans = LoanSelector.selectByTransactionIds(new Set<Id>{ deals[0].Id });
        Test.stopTest();

        Integer touched = 0;
        for (ChecklistCaptureDefProvider.CaptureDef def : ChecklistCaptureDefProvider.all().values()) {
            if (!ChecklistCaptureDefProvider.TARGET_LOAN.equals(def.targetObject)) {
                continue;
            }
            for (String apiName : def.captureFields) {
                // Throws if the field was not selected. The value itself is irrelevant.
                loans[0].get(apiName);
                touched++;
            }
        }
        Assert.isTrue(touched >= 7,
            'Expected at least the seven named loan data points to be checked, checked ' + touched);
    }

    @isTest
    static void selectByTransactionIdsIsOrderedOldestFirst() {
        // The ordering is what makes "the deal loan" a stable choice rather than a different record
        // on every page load. Two rows inserted in separate statements have distinct CreatedDate.
        Transaction__c deal = allDeals()[0];
        Loan__c second = new Loan__c(Transaction__c = deal.Id, Lender_Name__c = 'Later Bank');
        insert second;

        Test.startTest();
        List<Loan__c> loans = LoanSelector.selectByTransactionIds(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(2, loans.size(), 'Both loans on the deal come back — no silent LIMIT 1');
        Assert.areEqual('First Bank', loans[0].Lender_Name__c,
            'The OLDEST loan is first, so LoanService.existingByDeal picks it deterministically');
    }

    @isTest
    static void nullAndEmptyInputsReturnEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Loan__c> fromNull = LoanSelector.selectByTransactionIds(null);
        List<Loan__c> fromEmpty = LoanSelector.selectByTransactionIds(new Set<Id>());
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(0, fromNull.size(), 'Null input returns an empty list, never null');
        Assert.areEqual(0, fromEmpty.size(), 'Empty input returns an empty list');
        Assert.areEqual(0, spent,
            'A short-circuited read must not spend a query — this method is called on every '
                + 'completion batch, most of which contain no capture item at all');
    }

    @isTest
    static void selectByTransactionIdsCosts251RowsExactlyOneQuery() {
        Transaction__c deal = allDeals()[0];
        List<Loan__c> bulkRows = new List<Loan__c>();
        for (Integer i = 0; i < BULK_ROWS; i++) {
            bulkRows.add(new Loan__c(Transaction__c = deal.Id, Lender_Name__c = 'Bank ' + i));
        }
        insert bulkRows;

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Loan__c> loans = LoanSelector.selectByTransactionIds(new Set<Id>{ deal.Id });
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(BULK_ROWS + 1, loans.size(),
            'All 251 bulk rows plus the setup row come back in one read');
        Assert.areEqual(1, spent, 'One query regardless of row count');
    }

    private static List<Transaction__c> allDeals() {
        return [SELECT Id FROM Transaction__c ORDER BY CreatedDate ASC, Id ASC];
    }
}
