/**
 * Tests for the Critical Date projection.
 *
 * The rules under test are lifted verbatim from `scripts/seed-critical-dates.apex`, which is the
 * specification; these tests are what stop the service and the script drifting apart now that the
 * script calls the service.
 *
 * ⚠ NOT A 251-RECORD TEST, AND THAT IS DELIBERATE. The service is bulk-safe by construction (2
 * selector calls and 1 DML statement regardless of deal count, asserted below), but every
 * `Critical_Date__c` this test creates makes its parent `Transaction__c` PERMANENTLY UNDELETABLE
 * (`required=true` + `deleteConstraint=Restrict`) - design RISK 2 / GATE-B3. Test rows roll back, so
 * that costs nothing here; the number is kept small anyway because the volume proves nothing the
 * governor assertion does not.
 */
@isTest
private class CriticalDateServiceTest {

    @isTest
    static void projectsThePinnedDatesFromTheDealsOwnFields() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];

        Test.startTest();
        Integer created = CriticalDateService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Map<String, Date> byType = new Map<String, Date>();
        for (Critical_Date__c row : [
            SELECT Type__c, Due_Date__c FROM Critical_Date__c WHERE Transaction__c = :deal.Id
        ]) {
            byType.put(row.Type__c, row.Due_Date__c);
        }
        Assert.areEqual(2, created, 'Closing Date and Feasibility End are both pinned and projected');
        Assert.areEqual(Date.today().addDays(75), byType.get('Closing Date'),
            'Closing Date must EQUAL Target_Close_Date__c - a critical date that disagrees with the '
                + 'deal record is a defect, not a variant');
        Assert.areEqual(Date.today().addDays(45), byType.get('Feasibility End'),
            'Feasibility End must EQUAL Feasibility_Deadline__c');
    }

    @isTest
    static void isIdempotentOnTheTransactionPlusTypeKey() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        CriticalDateService.ensureFor(new Set<Id>{ deal.Id });

        Test.startTest();
        Integer created = CriticalDateService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(0, created, 'A second identical run must create nothing');
        Assert.areEqual(2, [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id],
            'And must not duplicate - a sharing-filtered idempotency guard would silently double '
                + 'these rows, which is why the read runs without sharing');
    }

    @isTest
    static void selfHealsAfterAPartialRun() {
        // The key is per (Transaction + Type), NOT a coarse "any rows exist?" early exit - so a
        // deal that somehow has only one of its rows gets the missing one on the next run.
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        insert new Critical_Date__c(
            Transaction__c = deal.Id, Type__c = 'Closing Date', Due_Date__c = Date.today().addDays(75));

        Test.startTest();
        Integer created = CriticalDateService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, created, 'Only the missing Feasibility End is created');
    }

    @isTest
    static void skipsClosedAndPostClosingDeals() {
        List<Transaction__c> deals = TestDataFactory.createTransactions(2, true);
        update new List<Transaction__c>{
            new Transaction__c(Id = deals[0].Id, Stage__c = 'Post-Closing'),
            new Transaction__c(Id = deals[1].Id, Status__c = 'Closed')
        };

        Test.startTest();
        Integer created = CriticalDateService.ensureFor(
            new Set<Id>{ deals[0].Id, deals[1].Id });
        Test.stopTest();

        Assert.areEqual(0, created, 'A closed or post-closing deal has no UPCOMING critical dates');
    }

    @isTest
    static void dropsFeasibilityEndAtClosingPrep() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        update new Transaction__c(Id = deal.Id, Stage__c = 'Closing Prep');

        Test.startTest();
        CriticalDateService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Critical_Date__c
            WHERE Transaction__c = :deal.Id AND Type__c = 'Feasibility End'],
            'By closing prep the feasibility period has demonstrably ended');
    }

    @isTest
    static void dropsFeasibilityEndWhenFeasibilityWasMissed() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        update new Transaction__c(Id = deal.Id, Feasibility_Missed__c = true);

        Test.startTest();
        CriticalDateService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Critical_Date__c
            WHERE Transaction__c = :deal.Id AND Type__c = 'Feasibility End'],
            'A future feasibility end on a deal that already missed feasibility is a contradiction');
    }

    @isTest
    static void createsNothingWhenTheDealHasNoPinnedDates() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        update new Transaction__c(
            Id = deal.Id, Target_Close_Date__c = null, Feasibility_Deadline__c = null);

        Test.startTest();
        Integer created = CriticalDateService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(0, created,
            'The service PROJECTS the deal record and never invents a deadline from an offset');
    }

    @isTest
    static void firesFromTheTriggerOnAStageChangeButNotOnACounterWrite() {
        Transaction__c deal = TestDataFactory.createTransactions(1, true)[0];
        Assert.areEqual(0, [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id],
            'NOT wired to after-insert: a freshly created deal must stay deletable while GATE-B3 is '
                + 'open (Critical_Date__c.Transaction__c is Restrict)');

        Test.startTest();
        update new Transaction__c(Id = deal.Id, Tasks_Complete__c = 3);
        Assert.areEqual(0, [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id],
            'A counter write must not enter the service at all - that is what keeps the fan-out '
                + 'budget valid');
        update new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence');
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id],
            'A stage change projects the deal dates');
    }

    @isTest
    static void isBulkSafeAtAFlatQueryCost() {
        List<Transaction__c> deals = TestDataFactory.createTransactions(50, true);
        Set<Id> dealIds = new Map<Id, Transaction__c>(deals).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        Integer created = CriticalDateService.ensureFor(dealIds);
        Integer queries = Limits.getQueries() - queriesBefore;
        Integer dml = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(100, created, 'Two projected rows for each of the 50 deals');
        Assert.areEqual(2, queries,
            'Two selector calls regardless of deal count - no SOQL in a loop. Actual: ' + queries);
        Assert.areEqual(1, dml, 'One insert for the whole collection. Actual: ' + dml);
    }

    @isTest
    static void isNullSafe() {
        Test.startTest();
        Assert.areEqual(0, CriticalDateService.ensureFor(null), 'Null is a no-op');
        Assert.areEqual(0, CriticalDateService.ensureFor(new Set<Id>()), 'Empty is a no-op');
        Assert.areEqual(0, CriticalDateService.ensureFor(new Set<Id>{ null }),
            'A set of nulls is a no-op');
        Assert.isTrue(CriticalDateSelector.selectExistingKeysByTransactionIds(null).isEmpty(),
            'The idempotency read returns an empty set, never null');
        Assert.isTrue(
            CriticalDateSelector.selectExistingKeysByTransactionIds(new Set<Id>()).isEmpty(),
            'Empty in, empty out');
        Test.stopTest();
    }
}
