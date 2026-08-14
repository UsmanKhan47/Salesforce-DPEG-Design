/**
 * Tests for `CallForOffersAlertBatch` — the daily call-for-offers deadline alert.
 *
 * ── WHAT CAN AND CANNOT BE ASSERTED HERE ────────────────────────────────────
 * 🔴 **A CUSTOM NOTIFICATION CANNOT BE QUERIED IN APEX.** There is no SObject for a delivered
 * notification, so no test in this org can assert that the `Acquisition` queue received anything.
 * `GroupNotifier` has carried a `@TestVisible sentCount` static since it was written for exactly
 * this reason. What these tests assert instead is the thing that IS observable and IS the design:
 * **the two marker fields**, which are the durable record of what was alerted and the entire
 * mechanism by which an alert happens once rather than daily.
 *
 * ── 🔴 WHY MOST TESTS CALL `execute()` DIRECTLY INSTEAD OF `Database.executeBatch` ──────────
 * In a test context a batch does not run when it is submitted — it runs at `Test.stopTest()`. So
 * TWO passes with a data change in between (yesterday's run, then today's) is **unexpressible**
 * through `Database.executeBatch`: both submissions would queue and then run back-to-back at
 * `stopTest`, after every data change had already been made, and the test would silently measure
 * something else entirely. Every sequencing test therefore drives `execute(null, scope)` directly,
 * synchronously, which is the same code path the framework calls.
 *
 * `Database.executeBatch` is still used where the LOCATOR is the thing under test — its ceiling, its
 * `IsClosed` filter and its ordering — because that is the half a direct `execute` call skips.
 *
 * ⚠ GOVERNOR / OUTCOME COUNTERS are asserted on the batch's own `chunk*` statics, captured INSIDE
 * the transaction. `Test.stopTest()` restores the pre-test governor counters, so a `Limits.*`
 * assertion after it is silently vacuous (the `ExtractAddressQueueable.lastRunQueryCount`
 * precedent). The batch's INSTANCE fields cannot be read at all: `Database.Stateful` serialises the
 * object, so the instance the test handed to `Database.executeBatch` is not the instance that ran.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies (this is a batch) and is met. Note
 * exactly what 251 proves: a test method executes only ONE chunk, so at `SCOPE = 200` a 251-row
 * fixture proves the LOCATOR selects, filters and orders 251 rows and that a full 200-deal chunk
 * behaves. It does not drive two `execute()` calls, and no test can.
 */
@isTest
private class CallForOffersAlertBatchTest {

    /** The field set the locator produces, so a direct `execute()` call gets the same shape. */
    private static List<Opportunity> scopeFor(Set<Id> dealIds) {
        return [
            SELECT Id, Name, Offer_Due_Date__c, Offer_Alert_Last_Interval__c,
                   Offer_Alert_Due_Date__c, Sale_Process__c, Listing_Broker_Name__c
            FROM Opportunity
            WHERE Id IN :dealIds
            ORDER BY Offer_Due_Date__c ASC, Id ASC
        ];
    }

    private static List<Opportunity> scopeFor(Id dealId) {
        return scopeFor(new Set<Id>{ dealId });
    }

    /** Load a deal's two marker fields back from the database. */
    private static Opportunity marker(Id dealId) {
        return [
            SELECT Id, Offer_Due_Date__c, Offer_Alert_Last_Interval__c, Offer_Alert_Due_Date__c
            FROM Opportunity WHERE Id = :dealId
        ];
    }

    /** One deal with a deadline `days` from today and a blank marker. */
    private static Opportunity dealDueIn(Integer days) {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        deal.Offer_Due_Date__c = Date.today().addDays(days);
        deal.Listing_Broker_Name__c = 'Jane Broker';
        update deal;
        return deal;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE MARKER — what is stamped, and when
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void aDealInsideTheLadderIsAlertedAndMarked() {
        Opportunity deal = dealDueIn(3);

        Test.startTest();
        new CallForOffersAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Opportunity after = marker(deal.Id);
        Assert.areEqual(3, after.Offer_Alert_Last_Interval__c,
            'The rung the deal sits in must be stamped');
        Assert.areEqual(deal.Offer_Due_Date__c, after.Offer_Alert_Due_Date__c,
            'and the SNAPSHOT of the deadline it was computed against — without this a later '
            + 'extension can never re-arm the ladder');
        Assert.areEqual(1, CallForOffersAlertBatch.chunkNotified, 'One notification went out');
        Assert.areEqual(1, CallForOffersAlertBatch.chunkStamped, 'and one marker was written');
    }

    @isTest
    static void aSecondRunOnTheSameDayIsAGenuineNoOp() {
        // 🔴 THE FAILURE THE WHOLE MARKER DESIGN EXISTS TO PREVENT: "the team gets the same alert
        // every day and stops reading them". Asserted on ZERO sends, not merely on the marker being
        // unchanged — an implementation that re-sent and re-stamped the SAME value would leave the
        // marker identical and pass a weaker test.
        Opportunity deal = dealDueIn(3);
        CallForOffersAlertBatch batch = new CallForOffersAlertBatch();

        Test.startTest();
        batch.execute(null, scopeFor(deal.Id));
        Integer sentAfterFirstPass = GroupNotifier.sentCount;
        batch.execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(0, CallForOffersAlertBatch.chunkOwed,
            'The second pass must decide nothing is owed');
        Assert.areEqual(0, CallForOffersAlertBatch.chunkNotified, 'so it sends nothing');
        Assert.areEqual(sentAfterFirstPass, GroupNotifier.sentCount,
            'and the notifier is never even reached');
        Assert.areEqual(3, marker(deal.Id).Offer_Alert_Last_Interval__c, 'The marker is unchanged');
    }

    @isTest
    static void eachSmallerRungFiresOnceAsTheDeadlineApproaches() {
        Opportunity deal = dealDueIn(3);
        CallForOffersAlertBatch batch = new CallForOffersAlertBatch();

        Test.startTest();
        // Day 1: three days out.
        batch.execute(null, scopeFor(deal.Id));
        Assert.areEqual(3, marker(deal.Id).Offer_Alert_Last_Interval__c, 'Rung 3 fires first');

        // Two days later. The clock cannot be moved, so the DEADLINE is moved in and the snapshot is
        // moved with it — which is byte-for-byte the row state a real day-2 run would find (marker
        // interval 3, snapshot equal to the live due date), without the re-arm branch being involved.
        Date nearer = Date.today().addDays(1);
        update new Opportunity(
            Id = deal.Id, Offer_Due_Date__c = nearer, Offer_Alert_Due_Date__c = nearer
        );

        batch.execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(1, marker(deal.Id).Offer_Alert_Last_Interval__c,
            'Rung 1 fires once the deal is one day out, and the marker moves DOWN — monotone');
    }

    @isTest
    static void aMissedRunCatchesUpInsteadOfSkippingARungForEver() {
        // The job did not run for days: the deal is already 2 days out with a blank marker. A
        // stateless "fire when daysRemaining is exactly 7/3/1/0" rule would have skipped the 7 and 3
        // rungs SILENTLY and for ever. The monotone marker fires the smallest rung it is now inside.
        Opportunity deal = dealDueIn(2);

        Test.startTest();
        new CallForOffersAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(3, marker(deal.Id).Offer_Alert_Last_Interval__c,
            'Two days out sits in the 3-day rung and must alert, not be skipped');
    }

    @isTest
    static void anExtendedDeadlineReArmsTheLadderInTheRunningJob() {
        // 🔴 THE O2 FAILURE, END TO END. `CallForOffersStampService` is last-email-wins on
        // Offer_Due_Date__c ON PURPOSE ("extended to Friday"), so this is the ORDINARY case, not an
        // edge one. Without the snapshot field the extended deal would never alert again — silently,
        // on exactly the deals whose deadline someone cared enough about to move.
        Opportunity deal = dealDueIn(1);
        CallForOffersAlertBatch batch = new CallForOffersAlertBatch();

        Test.startTest();
        batch.execute(null, scopeFor(deal.Id));
        Assert.areEqual(1, marker(deal.Id).Offer_Alert_Last_Interval__c, 'Rung 1 fired');

        // The broker extends. NOTHING resets the marker — that is the whole point of the snapshot.
        update new Opportunity(Id = deal.Id, Offer_Due_Date__c = Date.today().addDays(7));

        batch.execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Opportunity after = marker(deal.Id);
        Assert.areEqual(7, after.Offer_Alert_Last_Interval__c,
            'The ladder RE-ARMED and rung 7 of the NEW deadline fired. A marker still reading 1 '
            + 'means the snapshot comparison was lost and this deal would never alert again');
        Assert.areEqual(Date.today().addDays(7), after.Offer_Alert_Due_Date__c,
            'and the snapshot moved with it');
    }

    @isTest
    static void anOverdueDealAlertsOnceAndThenStaysQuiet() {
        Opportunity deal = dealDueIn(-5);
        CallForOffersAlertBatch batch = new CallForOffersAlertBatch();

        Test.startTest();
        batch.execute(null, scopeFor(deal.Id));
        Assert.areEqual(0, marker(deal.Id).Offer_Alert_Last_Interval__c,
            'An overdue deal that was never alerted is still owed its one alert — the locator has '
            + 'no lower bound precisely so this deal is not silently skipped');

        batch.execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(0, CallForOffersAlertBatch.chunkOwed,
            'and then it goes quiet for ever rather than notifying the queue every single day');
    }

    @isTest
    static void aDealWithNoDeadlineIsNeverAlerted() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);

        Test.startTest();
        new CallForOffersAlertBatch().execute(null, scopeFor(deal.Id));
        Test.stopTest();

        Assert.areEqual(0, CallForOffersAlertBatch.chunkOwed, 'No deadline, nothing owed');
        Assert.isNull(marker(deal.Id).Offer_Alert_Last_Interval__c, 'and nothing stamped');
    }

    @isTest
    static void aFailedSendIsNotStampedSoTheAlertIsRetriedRatherThanLost() {
        // 🔴 THE REASON `GroupNotifier.notifyWithOutcome` EXISTS. Simulated by pointing the batch at
        // a group that does not exist, which is exactly the shape GroupNotifier reports as "no
        // recipients" and swallows. Under the old void `notify` the batch COULD NOT TELL, and would
        // have stamped a marker for an alert nobody received — losing it silently and for ever.
        Opportunity deal = dealDueIn(3);
        String realGroup = CallForOffersAlertBatch.RECIPIENT_GROUP;
        CallForOffersAlertBatch.RECIPIENT_GROUP =
            'No_Such_Group_' + Math.abs(Crypto.getRandomInteger());

        Test.startTest();
        try {
            new CallForOffersAlertBatch().execute(null, scopeFor(deal.Id));
        } finally {
            CallForOffersAlertBatch.RECIPIENT_GROUP = realGroup;
        }
        Test.stopTest();

        Assert.areEqual(1, CallForOffersAlertBatch.chunkOwed, 'The deal was owed an alert');
        Assert.areEqual(0, CallForOffersAlertBatch.chunkNotified, 'but nothing was sent');
        Assert.areEqual(1, CallForOffersAlertBatch.chunkSendFailures, 'and the failure was counted');
        Assert.areEqual(0, CallForOffersAlertBatch.chunkStamped, 'so NOTHING was stamped');
        Assert.isNull(marker(deal.Id).Offer_Alert_Last_Interval__c,
            'The deal stays unmarked, so the next pass retries. A stamp here would lose the alert '
            + 'permanently and silently — the exact defect notifyWithOutcome was added to prevent');
    }

    @isTest
    static void aDealDeletedUnderTheChunkDoesNotAbortThePass() {
        // A locator row can be minutes old by the time its chunk runs, so a deal can vanish between
        // selection and execution. Whatever the platform does with the send, the chunk must not
        // throw and must not stamp a marker onto a row that no longer exists — and the pass must
        // survive to handle the deals either side of it.
        Opportunity doomed = dealDueIn(3);
        Opportunity survivor = dealDueIn(1);
        List<Opportunity> scope = scopeFor(new Set<Id>{ doomed.Id, survivor.Id });
        delete doomed;

        Test.startTest();
        new CallForOffersAlertBatch().execute(null, scope);
        Test.stopTest();

        Assert.areEqual(2, CallForOffersAlertBatch.chunkEvaluated, 'Both rows were evaluated');
        Assert.areEqual(1, marker(survivor.Id).Offer_Alert_Last_Interval__c,
            'The surviving deal is alerted and marked despite its neighbour disappearing');
    }

    @isTest
    static void anEmptyChunkCostsNothing() {
        // The ordinary state of a quiet pipeline. It must not write, send or throw.
        Test.startTest();
        CallForOffersAlertBatch batch = new CallForOffersAlertBatch();
        batch.execute(null, new List<Opportunity>());
        batch.execute(null, null);
        Test.stopTest();

        Assert.areEqual(0, CallForOffersAlertBatch.chunkEvaluated, 'Nothing evaluated');
        Assert.areEqual(0, CallForOffersAlertBatch.chunkNotified, 'Nothing sent');
    }

    @isTest
    static void aChunkOfNullRowsIsSkippedRatherThanThrowing() {
        Test.startTest();
        new CallForOffersAlertBatch().execute(null, new List<Opportunity>{ null });
        Test.stopTest();
        Assert.areEqual(0, CallForOffersAlertBatch.chunkEvaluated, 'A null row is skipped');
    }

    @isTest
    static void finishRunsWithoutTheBatchHavingProcessedAnything() {
        // finish() runs in its own transaction even on an empty locator; it must not throw.
        Test.startTest();
        new CallForOffersAlertBatch().finish(null);
        Test.stopTest();
        Assert.isTrue(true, 'finish() on an untouched batch is a summary line, never a failure');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE LOCATOR — the half a direct execute() call skips
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void theLocatorExcludesDealsPastTheCeilingClosedDealsAndDealsWithNoDeadline() {
        Opportunity inLadder = dealDueIn(3);
        Opportunity pastCeiling = dealDueIn(30);
        Opportunity noDeadline = TestDataFactory.createOpportunity(null, true);

        // Closed at INSERT rather than by an update, so no ISCHANGED(StageName) validation rule is
        // involved in setting up a test that is not about validation rules.
        Opportunity closedDeal = TestDataFactory.createOpportunity(null, false);
        closedDeal.StageName = 'Dead/Pass';
        insert closedDeal;
        update new Opportunity(Id = closedDeal.Id, Offer_Due_Date__c = Date.today().addDays(2));

        Test.startTest();
        Database.executeBatch(new CallForOffersAlertBatch(), CallForOffersAlertBatch.SCOPE);
        Test.stopTest();

        Assert.areEqual(3, marker(inLadder.Id).Offer_Alert_Last_Interval__c,
            'The in-ladder deal is selected and alerted');
        Assert.isNull(marker(pastCeiling.Id).Offer_Alert_Last_Interval__c,
            'A deal 30 days out is past the TODAY+7 ceiling and is never even read');
        Assert.isNull(marker(noDeadline.Id).Offer_Alert_Last_Interval__c,
            'A deal with no deadline is excluded');
        Assert.isNull(marker(closedDeal.Id).Offer_Alert_Last_Interval__c,
            'A closed deal has no live deadline to chase');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BULK — .claude/rules/bulk-test-rule.md
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void alertBatchAt251DealsIsBulkSafe() {
        // 251 deals: 200 inside the ladder (they must alert), 51 past the ceiling (they must not).
        // Mixing both populations is what proves the locator's ceiling and the in-memory ladder
        // agree — a fixture of 251 identical deals would pass even with no ceiling at all.
        List<Opportunity> deals = TestDataFactory.createOpportunities(251, true);
        for (Integer i = 0; i < deals.size(); i++) {
            deals[i].Offer_Due_Date__c = (i < 200)
                ? Date.today().addDays(Math.mod(i, 8))   // 0-7 days out: inside the ladder
                : Date.today().addDays(20 + i);          // well past the TODAY+7 ceiling
        }
        update deals;

        Test.startTest();
        Database.executeBatch(new CallForOffersAlertBatch(), CallForOffersAlertBatch.SCOPE);
        Test.stopTest();

        // The locator orders by due date ascending, so the 200 in-ladder deals sort first and fill
        // exactly one SCOPE = 200 chunk. A test method runs one chunk, so that chunk is what is
        // measured — see the class header.
        Assert.areEqual(200, CallForOffersAlertBatch.chunkEvaluated,
            'One chunk is exactly SCOPE deals');
        Assert.areEqual(200, CallForOffersAlertBatch.chunkOwed,
            'and every one of them is inside the ladder and owed its first alert');
        Assert.areEqual(200, CallForOffersAlertBatch.chunkNotified, 'all sent');
        Assert.areEqual(200, CallForOffersAlertBatch.chunkStamped,
            'and all stamped in ONE bulk DML — a per-record update would blow the 150-statement '
            + 'limit long before reaching 200');

        Integer marked = [
            SELECT COUNT() FROM Opportunity WHERE Offer_Alert_Last_Interval__c != NULL
        ];
        Assert.areEqual(200, marked,
            'Exactly the in-ladder population is marked; the 51 deals past the ceiling are not');
    }
}
