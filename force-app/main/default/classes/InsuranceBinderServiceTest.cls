/**
 * Tests for `InsuranceBinderService` — the provisioning half of the group G capture. The twin of
 * `LoanServiceTest`; read that class's header for why the CAPTURED FIELDS are deliberately not
 * tested here (Phase 5 has no Apex writer for them — LDS does that write).
 *
 * 🔴 251, NOT 20. `Insurance_Binder__c` is an ordinary custom object, so
 * `.claude/rules/content-publication-rule.md`'s reduced ceiling does not apply.
 */
@isTest
private class InsuranceBinderServiceTest {

    private static final Integer BULK_DEALS = 251;

    @isTest
    static void ensureForCreatesExactlyOneBinderPerDeal() {
        List<Transaction__c> deals = TestDataFactory.createTransactionsOnChecklistModel(2, true);

        Test.startTest();
        Map<Id, Insurance_Binder__c> binders =
            InsuranceBinderService.ensureFor(new Set<Id>{ deals[0].Id, deals[1].Id });
        Test.stopTest();

        Assert.areEqual(2, binders.size(), 'One binder resolved per deal');
        Assert.areEqual(2, [SELECT COUNT() FROM Insurance_Binder__c], 'And exactly two rows exist');
        for (Transaction__c deal : deals) {
            Assert.areEqual(deal.Id, binders.get(deal.Id).Transaction__c,
                'The new binder is parented to its own deal');
        }
    }

    @isTest
    static void ensureForRunsOnNoLoanDealsToo() {
        // 🔴 GROUP G IS UNCONDITIONAL, UNLIKE GROUP F. `TestDataFactory` builds deals with
        // `Loan_Required__c = false`, which is exactly the case that must still get a binder — a
        // cash deal still needs insurance. If this ever starts failing, somebody has copied
        // `LoanService`'s (inherited, group-F-only) condition into the wrong service.
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        Assert.areEqual(false,
            [SELECT Loan_Required__c FROM Transaction__c WHERE Id = :deal.Id].Loan_Required__c,
            'Fixture control: this deal needs no loan');

        Test.startTest();
        Map<Id, Insurance_Binder__c> binders =
            InsuranceBinderService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, binders.size(), 'A cash deal still gets an insurance binder');
    }

    @isTest
    static void ensureForIsIdempotentAcrossCalls() {
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        Map<Id, Insurance_Binder__c> first =
            InsuranceBinderService.ensureFor(new Set<Id>{ deal.Id });
        Map<Id, Insurance_Binder__c> second =
            InsuranceBinderService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Insurance_Binder__c],
            'G2 and G5 both open the dialog on the same deal — that must be one binder, not two');
        Assert.areEqual(first.get(deal.Id).Id, second.get(deal.Id).Id, 'Same record each time');
    }

    @isTest
    static void existingByDealNeverCreatesAnything() {
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        Map<Id, Insurance_Binder__c> binders =
            InsuranceBinderService.existingByDeal(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.isTrue(binders.isEmpty(), 'No binder exists, so the map is empty');
        Assert.areEqual(0, [SELECT COUNT() FROM Insurance_Binder__c],
            'And the guard read created nothing as a side effect');
    }

    @isTest
    static void nullAndEmptyInputsAreNoOps() {
        Test.startTest();
        Assert.isTrue(InsuranceBinderService.ensureFor(null).isEmpty(), 'Null input is safe');
        Assert.isTrue(InsuranceBinderService.ensureFor(new Set<Id>()).isEmpty(), 'Empty is safe');
        Assert.isTrue(InsuranceBinderService.existingByDeal(null).isEmpty(), 'Guard is null-safe');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Insurance_Binder__c], 'Nothing was created');
    }

    @isTest
    static void ensureForAt251DealsCostsOneQueryAndOneDml() {
        List<Transaction__c> deals =
            TestDataFactory.createTransactionsOnChecklistModel(BULK_DEALS, true);
        Set<Id> dealIds = new Map<Id, Transaction__c>(deals).keySet();

        Test.startTest();
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        Map<Id, Insurance_Binder__c> binders = InsuranceBinderService.ensureFor(dealIds);
        Integer queries = Limits.getQueries() - q0;
        Integer dml = Limits.getDmlStatements() - d0;
        Test.stopTest();

        Assert.areEqual(BULK_DEALS, binders.size(), 'A binder resolved for all 251 deals');
        Assert.areEqual(1, queries, 'ONE read for 251 deals');
        Assert.areEqual(1, dml, 'ONE insert statement for 251 deals');
    }

    @isTest
    static void ensureForAt251DealsIsStillIdempotent() {
        List<Transaction__c> deals =
            TestDataFactory.createTransactionsOnChecklistModel(BULK_DEALS, true);
        Set<Id> dealIds = new Map<Id, Transaction__c>(deals).keySet();

        Test.startTest();
        InsuranceBinderService.ensureFor(dealIds);
        Integer d0 = Limits.getDmlStatements();
        InsuranceBinderService.ensureFor(dealIds);
        Integer secondPassDml = Limits.getDmlStatements() - d0;
        Test.stopTest();

        Assert.areEqual(BULK_DEALS, [SELECT COUNT() FROM Insurance_Binder__c],
            'Still 251 rows, not 502');
        Assert.areEqual(0, secondPassDml, 'The second pass spends no DML');
    }
}
