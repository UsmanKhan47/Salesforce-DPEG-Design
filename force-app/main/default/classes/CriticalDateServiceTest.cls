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
 *
 * ⚠ EVERY DEAL IS BUILT BY `TestDataFactory.createTransactionsOnChecklistModel`, WHICH NULLS
 * `Contract_Executed_Date__c` AND SUPPRESSES THE DAY-0 FAN-OUT. `createTransactions` populates that
 * field, which is the first entry filter of `flows/Transaction_Task_Fanout`; since the 2026-09-03
 * repoint onto `ChecklistFanoutService` each such deal materialises ~96 `Checklist_Item__c` rows,
 * and `ChecklistOutcomeService` calls `CriticalDateService.ensureFor` off one of them (item A5).
 * That puts a second, unasserted writer behind every count below.
 *
 * THE DATE IS NOT LOAD-BEARING FOR ANYTHING HERE, AND THAT WAS CHECKED RATHER THAN ASSUMED. The
 * service projects only `Target_Close_Date__c` and `Feasibility_Deadline__c`, gated on `Stage__c`,
 * `Status__c` and `Feasibility_Missed__c`; `Contract_Executed_Date__c` appears in neither
 * `CriticalDateService` nor `TransactionSelector.CRITICAL_DATE_FIELDS`, so it is not even read into
 * the projection. No assertion below reads it or a value derived from it, and `Transaction__c`
 * carries no validation rule and no other active flow keyed on it, so nulling it cannot refuse the
 * stage and status moves these tests perform.
 */
@isTest
private class CriticalDateServiceTest {

    @isTest
    static void projectsThePinnedDatesFromTheDealsOwnFields() {
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

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
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
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
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        insert new Critical_Date__c(
            Transaction__c = deal.Id, Type__c = 'Closing Date', Due_Date__c = Date.today().addDays(75));

        Test.startTest();
        Integer created = CriticalDateService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(1, created, 'Only the missing Feasibility End is created');
    }

    @isTest
    static void skipsClosedAndPostClosingDeals() {
        List<Transaction__c> deals = TestDataFactory.createTransactionsOnChecklistModel(2, true);
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
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
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
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
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
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];
        update new Transaction__c(
            Id = deal.Id, Target_Close_Date__c = null, Feasibility_Deadline__c = null);

        Test.startTest();
        Integer created = CriticalDateService.ensureFor(new Set<Id>{ deal.Id });
        Test.stopTest();

        Assert.areEqual(0, created,
            'The service PROJECTS the deal record and never invents a deadline from an offset');
    }

    @isTest
    static void isNotWiredToTheTransactionTriggerAtAll() {
        // 🔴 THIS TEST ASSERTED REMOVED BEHAVIOUR AND IS NOW INVERTED, DELIBERATELY.
        // It used to be `firesFromTheTriggerOnAStageChangeButNotOnACounterWrite` and expected two
        // Critical Dates after a stage change. The `afterUpdate` arm that produced them was REMOVED
        // from `TransactionTriggerHandler` by user decision on 2026-09-01, so the old expectation
        // was asserting a call site that no longer exists - the test was wrong, the code was right.
        // Inverting it rather than deleting it is the point: an unwired service is a DECISION with
        // two named preconditions (GATE-B2, the missing `Contract Executed` restricted-picklist
        // value; and GATE-B4, the unsettled source of truth), and this test is what makes re-wiring
        // it a conscious act. Anyone who adds the arm back will see this fail and has to come here
        // and read why it was withheld.
        // ⚠ IT ALSO GUARDS THE `deleteConstraint=Restrict` HAZARD: the moment a Critical Date exists
        // its Transaction can never be deleted, so an accidentally-wired projection would make
        // DELETE_FAILED the default for every deal that ever changes stage.
        Transaction__c deal = TestDataFactory.createTransactionsOnChecklistModel(1, true)[0];

        Test.startTest();
        update new Transaction__c(Id = deal.Id, Tasks_Complete__c = 3);
        update new Transaction__c(Id = deal.Id, Stage__c = 'Due Diligence');
        update new Transaction__c(Id = deal.Id, Target_Close_Date__c = Date.today().addDays(90));
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Critical_Date__c WHERE Transaction__c = :deal.Id],
            'CriticalDateService must NOT be reachable from TransactionTrigger - not on a counter '
            + 'write, not on a stage change, and not on a pinned-date change. If this fails, the '
            + 'arm was re-added: read the withheld-arm note in TransactionTriggerHandler before '
            + 'deciding that is correct. NOTE (2026-09-02): this message used to claim the seed '
            + 'script was the ONLY production caller. It is not - ChecklistOutcomeService calls '
            + 'ensureFor when a user completes checklist item A5. That is a SERVICE path, not a '
            + 'trigger path, so it does not weaken what this test asserts; the deal below never '
            + 'gets a checklist item, let alone a completed A5.');
    }

    @isTest
    static void isBulkSafeAtAFlatQueryCost() {
        // 🔴 251, THE MANDATE — NOT 50. `.claude/rules/bulk-test-rule.md` applies unreduced here:
        // `ensureFor` takes a collection, performs DML, and no carve-out in that rule covers it.
        // The two deviations elsewhere in this feature ARE justified and are not precedent for this
        // one: the fan-out asserts at the 50/51 CHUNK BOUNDARY because 251 deals is 23,594 DML rows
        // and unreachable, and the content-selector reads are capped at 20 by
        // `.claude/rules/content-publication-rule.md`. Neither applies to two projected rows per
        // deal — 251 deals is ~502 rows, comfortably inside every limit — so the number was simply
        // low, and 50 would not have forced the second trigger chunk that makes a per-record
        // regression visible.
        // 🔴 AND THE FACTORY MUST BE THE SUPPRESSING ONE AT THIS VOLUME. `createTransactions` sets
        // `Contract_Executed_Date__c`, so 251 plain deals would each enter
        // `flows/Transaction_Task_Fanout` and hand ~96 checklist rows apiece to
        // `ChecklistFanoutService` - roughly 24,000 rows at `Test.stopTest()`, past the 10,000-row
        // DML ceiling, and the method would die on a limit that has nothing to do with the
        // projection under test. The volume stays at 251; the rows the test does not need go.
        Integer bulkDeals = 251;
        List<Transaction__c> deals =
            TestDataFactory.createTransactionsOnChecklistModel(bulkDeals, true);
        Set<Id> dealIds = new Map<Id, Transaction__c>(deals).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        Integer created = CriticalDateService.ensureFor(dealIds);
        Integer queries = Limits.getQueries() - queriesBefore;
        Integer dml = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(bulkDeals * 2, created, 'Two projected rows for each of the 251 deals');
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
