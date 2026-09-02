/**
 * Tests for `LoanService` — the provisioning half of the group F capture.
 *
 * ⚠ WHAT THIS CLASS DELIBERATELY DOES **NOT** TEST: writing `Lender_Name__c`, `Loan_Amount__c` or
 * any other captured field. That is not an omission and it is not untested behaviour — Phase 5 has
 * no Apex writer for those fields at all. They are written by `lightning-record-edit-form` through
 * Lightning Data Service, so the coverage that matters for them is the LWC Jest suite plus the
 * platform's own form handling. Asserting here that a hand-built `update` sets a field would prove
 * something about Apex DML, not about the feature.
 *
 * 🔴 251, NOT 20. `Loan__c` is an ordinary custom object, so
 * `.claude/rules/content-publication-rule.md`'s reduced ceiling does not apply and
 * `.claude/rules/bulk-test-rule.md`'s default volume stands. `ensureFor` performs DML and takes a
 * collection, which is exactly the shape that rule is for.
 */
@isTest
private class LoanServiceTest {

    private static final Integer BULK_DEALS = 251;

    @isTest
    static void ensureForCreatesExactlyOneLoanPerDeal() {
        List<Transaction__c> deals = TestDataFactory.createTransactionsOnChecklistModel(2, true);

        Test.startTest();
        Map<Id, Loan__c> loans =
            LoanService.ensureFor(new Set<Id>{ deals[0].Id, deals[1].Id });
        Test.stopTest();

        Assert.areEqual(2, loans.size(), 'One loan resolved per deal');
        Assert.areEqual(2, [SELECT COUNT() FROM Loan__c], 'And exactly two rows exist');
        for (Transaction__c deal : deals) {
            Assert.isNotNull(loans.get(deal.Id), 'Every requested deal is in the map');
            Assert.areEqual(deal.Id, loans.get(deal.Id).Transaction__c,
                'The new loan is parented to its own deal');
        }
    }

    @isTest
    static void ensureForIsIdempotentAcrossCalls() {
        // 🔴 THE CENTRAL PROPERTY. The dialog can be opened on F5, then F6, then F9, then F12 — four
        // separate `ensureFor` calls on the same deal. A non-idempotent provisioner would leave four
        // Loan__c rows and the four dialogs would write to four different records.
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        Map<Id, Loan__c> first = LoanService.ensureFor(new Set<Id>{ deal.Id });
        Map<Id, Loan__c> second = LoanService.ensureFor(new Set<Id>{ deal.Id });
        Map<Id, Loan__c> third = LoanService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Loan__c],
            'Three calls, one row — the second and third must find the first');
        Assert.areEqual(first.get(deal.Id).Id, second.get(deal.Id).Id, 'Same record each time');
        Assert.areEqual(first.get(deal.Id).Id, third.get(deal.Id).Id, 'Still the same on the third');
    }

    @isTest
    static void ensureForCreatesOnlyForDealsThatHaveNone() {
        List<Transaction__c> deals = TestDataFactory.createTransactionsOnChecklistModel(2, true);
        Loan__c existing = new Loan__c(Transaction__c = deals[0].Id, Lender_Name__c = 'Incumbent');
        insert existing;

        Test.startTest();
        Map<Id, Loan__c> loans = LoanService.ensureFor(new Set<Id>{ deals[0].Id, deals[1].Id });
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Loan__c], 'One created, one reused');
        Assert.areEqual(existing.Id, loans.get(deals[0].Id).Id,
            'The deal that already had a loan keeps it — with its captured lender intact');
        Assert.areEqual('Incumbent', loans.get(deals[0].Id).Lender_Name__c,
            'And the previously captured value is not overwritten by the provisioner');
    }

    @isTest
    static void existingByDealNeverCreatesAnything() {
        // 🔴 THE GUARD MUST NOT PROVISION. `assertCaptureSatisfied` calls this method on every
        // refused completion; if it created a row, a user who kept getting refused would leave a
        // trail of empty Loan__c records behind them.
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        Map<Id, Loan__c> loans = LoanService.existingByDeal(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.isTrue(loans.isEmpty(), 'No loan exists, so the map is empty');
        Assert.areEqual(0, [SELECT COUNT() FROM Loan__c], 'And none was created as a side effect');
    }

    @isTest
    static void existingByDealPicksTheSameLoanEnsureForDoes() {
        // If the guard and the dialog ever chose differently, a user who filled the form in
        // correctly would still be refused — and nothing on the screen would explain why.
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        Loan__c older = new Loan__c(Transaction__c = deal.Id, Lender_Name__c = 'Older');
        insert older;
        insert new Loan__c(Transaction__c = deal.Id, Lender_Name__c = 'Newer');

        Test.startTest();
        Map<Id, Loan__c> viaEnsure = LoanService.ensureFor(new Set<Id>{ deal.Id });
        Map<Id, Loan__c> viaGuard = LoanService.existingByDeal(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(older.Id, viaEnsure.get(deal.Id).Id, 'ensureFor takes the oldest');
        Assert.areEqual(older.Id, viaGuard.get(deal.Id).Id, 'and so does the guard');
    }

    @isTest
    static void nullAndEmptyInputsAreNoOps() {
        Test.startTest();
        Map<Id, Loan__c> fromNull = LoanService.ensureFor(null);
        Map<Id, Loan__c> fromEmpty = LoanService.ensureFor(new Set<Id>());
        Map<Id, Loan__c> guardNull = LoanService.existingByDeal(null);
        Test.stopTest();

        Assert.isTrue(fromNull.isEmpty(), 'Null input returns an empty map, never null');
        Assert.isTrue(fromEmpty.isEmpty(), 'Empty input returns an empty map');
        Assert.isTrue(guardNull.isEmpty(), 'And the guard read is null-safe too');
        Assert.areEqual(0, [SELECT COUNT() FROM Loan__c], 'Nothing was created');
    }

    @isTest
    static void ensureForAt251DealsCostsOneQueryAndOneDml() {
        // `.claude/rules/bulk-test-rule.md` volume case for a DML-performing service method. The
        // COST assertion is the load-bearing half: a read or an insert moved inside the loop would
        // still produce 251 correct rows, and only this number would notice.
        List<Transaction__c> deals =
            TestDataFactory.createTransactionsOnChecklistModel(BULK_DEALS, true);
        Set<Id> dealIds = new Map<Id, Transaction__c>(deals).keySet();

        Test.startTest();
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        Map<Id, Loan__c> loans = LoanService.ensureFor(dealIds);
        Integer queries = Limits.getQueries() - q0;
        Integer dml = Limits.getDmlStatements() - d0;
        Test.stopTest();

        Assert.areEqual(BULK_DEALS, loans.size(), 'A loan resolved for every one of the 251 deals');
        Assert.areEqual(BULK_DEALS, [SELECT COUNT() FROM Loan__c], 'And 251 rows exist');
        Assert.areEqual(1, queries, 'ONE read for 251 deals, not one per deal');
        Assert.areEqual(1, dml, 'ONE insert statement for 251 deals, not one per deal');
    }

    @isTest
    static void ensureForAt251DealsIsStillIdempotent() {
        // The second pass must find all 251 and insert nothing. A `containsKey` bug would show as a
        // silent doubling here and nowhere else.
        List<Transaction__c> deals =
            TestDataFactory.createTransactionsOnChecklistModel(BULK_DEALS, true);
        Set<Id> dealIds = new Map<Id, Transaction__c>(deals).keySet();

        Test.startTest();
        LoanService.ensureFor(dealIds);
        Integer d0 = Limits.getDmlStatements();
        LoanService.ensureFor(dealIds);
        Integer secondPassDml = Limits.getDmlStatements() - d0;
        Test.stopTest();

        Assert.areEqual(BULK_DEALS, [SELECT COUNT() FROM Loan__c], 'Still 251 rows, not 502');
        Assert.areEqual(0, secondPassDml,
            'The second pass must spend NO DML at all — everything was already there');
    }
}
