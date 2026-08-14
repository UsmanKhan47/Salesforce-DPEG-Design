/**
 * Tests for `CallForOffersService` — the single derivation of call-for-offers state.
 *
 * ── WHAT THIS CLASS IS ACTUALLY TRYING TO FALSIFY ───────────────────────────
 * Two things, and they are worth naming because the easy tests here prove neither:
 *
 *   1. THE LADDER IS ONE LADDER. `dueInterval` (what the alert job fires on) and `urgency` (what the
 *      UI paints) are derived from the same numbers, so a change that moves one and not the other
 *      must go red. `everyRungOfTheLadderMapsToExactlyOneBand` walks every boundary day.
 *   2. THE MARKER RE-ARMS WHEN A DEADLINE MOVES. That is the half of O2 that is easy to omit and
 *      impossible to notice: without it, an extended deadline silently never alerts again.
 *      `movedDeadlineReArmsTheWholeLadder` is the falsifier and it fails loudly if
 *      `shouldFire` stops comparing the snapshot.
 *   3. (2026-08-14) `receivedDate` IS THE STAMPED FIELD AND NOT THE OLD PROXY. Restoring
 *      `Broker_First_Seen__c ?? CreatedDate` into it is one innocuous-looking `? :` whose symptom
 *      is a column that still shows a plausible date — so it cannot be caught by looking.
 *      `receivedDateIsTheStampedFieldAndNeverTheProxy` asserts in BOTH directions (stamp absent ->
 *      null, stamp present -> stamp wins) because either one alone is satisfiable by a wrong
 *      implementation.
 *
 * ── NO FROZEN CLOCK, ANYWHERE ───────────────────────────────────────────────
 * Every band test calls `evaluate(dueDate, asOf)` with BOTH dates supplied, so not one assertion
 * here depends on what day it is. That is the whole reason the pure function takes the clock as an
 * argument (see the class header §1). The only tests that touch `Date.today()` are the two that
 * exist to pin the convenience overload and the record-backed entry points.
 *
 * ── BULK ────────────────────────────────────────────────────────────────────
 * `.claude/rules/bulk-test-rule.md`'s 251-record mandate applies to `upcoming()` (a service method
 * that reads) and is met by `upcomingAt251DealsIsOneQuery`, which pins the query budget as CONSTANT
 * rather than merely asserting the row count — that is the assertion a future
 * one-query-per-record regression fails.
 */
@isTest
private class CallForOffersServiceTest {

    // ═══════════════════════════════════════════════════════════════════════
    // THE PURE LADDER
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void noDueDateIsItsOwnStateAndIsNotOverdue() {
        Date asOf = Date.newInstance(2026, 8, 14);

        CallForOffersService.CallForOffers c = CallForOffersService.evaluate(null, asOf);

        Assert.areEqual('NO_DUE_DATE', c.urgency, 'A deal with no deadline is NO_DUE_DATE');
        Assert.isFalse(c.hasDueDate, 'hasDueDate must be false so the UI can render it differently');
        Assert.isFalse(c.isUrgent, 'No deadline is never urgent — collapsing it into OVERDUE would '
            + 'paint every non-campaign deal red');
        Assert.isNull(c.daysRemaining, 'daysRemaining must be null, not 0');
        Assert.isNull(c.dueInterval, 'Nothing can be owed an alert when there is no deadline');
    }

    @isTest
    static void everyRungOfTheLadderMapsToExactlyOneBand() {
        Date asOf = Date.newInstance(2026, 8, 14);

        // days out -> expected urgency, expected dueInterval.
        // The boundaries (8/7, 4/3, 1/0, 0/-1) are the whole point; the interior days are here so a
        // future off-by-one inside a band is caught too.
        Map<Integer, String> expectedBand = new Map<Integer, String>{
            30 => 'SCHEDULED', 9 => 'SCHEDULED', 8 => 'SCHEDULED',
            7 => 'APPROACHING', 5 => 'APPROACHING', 4 => 'APPROACHING',
            3 => 'CRITICAL', 2 => 'CRITICAL', 1 => 'CRITICAL',
            0 => 'DUE_TODAY',
            -1 => 'OVERDUE', -30 => 'OVERDUE'
        };
        Map<Integer, Integer> expectedInterval = new Map<Integer, Integer>{
            30 => null, 9 => null, 8 => null,
            7 => 7, 5 => 7, 4 => 7,
            3 => 3, 2 => 3, 1 => 1,
            0 => 0,
            -1 => 0, -30 => 0
        };

        for (Integer days : expectedBand.keySet()) {
            CallForOffersService.CallForOffers c =
                CallForOffersService.evaluate(asOf.addDays(days), asOf);
            Assert.areEqual(expectedBand.get(days), c.urgency,
                'Wrong band at ' + days + ' days out');
            Assert.areEqual(expectedInterval.get(days), c.dueInterval,
                'Wrong alert rung at ' + days + ' days out');
            Assert.areEqual(days, c.daysRemaining,
                'daysRemaining must be signed — negative once overdue — at ' + days);
        }
    }

    @isTest
    static void isUrgentIsTrueFromCriticalOnwardAndNowhereElse() {
        Date asOf = Date.newInstance(2026, 8, 14);

        // The enum's ORDER is load-bearing (see its doc comment); this is the assertion that goes
        // red if someone inserts a new member in the wrong place and quietly moves the boundary.
        Map<Integer, Boolean> expected = new Map<Integer, Boolean>{
            30 => false, 8 => false, 7 => false, 4 => false,
            3 => true, 1 => true, 0 => true, -1 => true
        };
        for (Integer days : expected.keySet()) {
            Assert.areEqual(expected.get(days),
                CallForOffersService.evaluate(asOf.addDays(days), asOf).isUrgent,
                'isUrgent wrong at ' + days + ' days out');
        }
    }

    @isTest
    static void labelsAndDetailUseOneFixedDateFormat() {
        Date asOf = Date.newInstance(2026, 8, 14);
        Date due = Date.newInstance(2026, 8, 17);

        CallForOffersService.CallForOffers c = CallForOffersService.evaluate(due, asOf);

        Assert.areEqual('Due in 3 days', c.label, 'The badge label must name the countdown');
        Assert.isTrue(c.detail.contains('Aug 17, 2026'),
            'The detail must carry the fixed Mmm d, yyyy format so the bell, the badge and the '
            + 'table cannot render one deadline three ways. Got: ' + c.detail);

        // Singular/plural is the kind of thing that is only ever noticed on screen.
        Assert.areEqual('Due in 1 day',
            CallForOffersService.evaluate(asOf.addDays(1), asOf).label, 'Singular at 1 day');
        Assert.areEqual('Overdue by 1 day',
            CallForOffersService.evaluate(asOf.addDays(-1), asOf).label, 'Singular when 1 day over');
        Assert.areEqual('Overdue by 2 days',
            CallForOffersService.evaluate(asOf.addDays(-2), asOf).label, 'Plural when 2 days over');
    }

    @isTest
    static void aNullClockFallsBackToTodayRatherThanThrowing() {
        // A careless caller inside a batch chunk must not get a NullPointerException.
        CallForOffersService.CallForOffers c =
            CallForOffersService.evaluate(Date.today().addDays(2), null);

        Assert.areEqual('CRITICAL', c.urgency, 'A null asOf is treated as today');
        Assert.areEqual(2, c.daysRemaining, 'and produces today\'s countdown');
    }

    @isTest
    static void theSingleArgOverloadUsesTodaysClock() {
        CallForOffersService.CallForOffers c =
            CallForOffersService.evaluate(Date.today().addDays(5));

        Assert.areEqual(5, c.daysRemaining, 'The convenience overload supplies Date.today()');
        Assert.areEqual('APPROACHING', c.urgency, 'and lands in the same band as the pure form');
    }

    @isTest
    static void theTwoPrivateGuardsAreDefensiveAndUnreachableFromEvaluate() {
        // ⚠ WHAT THIS TEST IS AND IS NOT. `intervalFor(null)` and `formatDate(null)` cannot be
        // reached through `evaluate`, which returns early on a null due date before either is
        // called. They are guards against a FUTURE caller, and they are covered here directly
        // rather than by inventing a branch in production code whose only purpose is to be false.
        // Without this, both classes carry two permanently-uncovered lines that read like an
        // oversight instead of a decision.
        Assert.isNull(CallForOffersService.intervalFor(null),
            'A null countdown sits in no rung');
        Assert.areEqual('—', CallForOffersService.formatDate(null),
            'A null date renders as an em dash, never as the string "null"');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE IDEMPOTENCY MARKER — the half that is easy to get wrong
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void aDealOutsideTheLadderNeverFires() {
        Assert.isFalse(
            CallForOffersService.shouldFire(null, null, Date.today().addDays(30), null),
            '30 days out is outside the ladder, so nothing is owed even with a blank marker');
    }

    @isTest
    static void firstAlertFiresAndEachSmallerRungFiresExactlyOnce() {
        Date due = Date.newInstance(2026, 9, 1);

        // Rung 7 with a blank marker -> fire.
        Assert.isTrue(CallForOffersService.shouldFire(7, null, due, null),
            'A never-alerted deal inside the ladder must fire');
        // Same rung again (marker now 7, snapshot matches) -> silence. This is the "same alert
        // every day" failure the marker exists to prevent.
        Assert.isFalse(CallForOffersService.shouldFire(7, 7, due, due),
            'The same rung must not fire twice');
        // Next rung down -> fire.
        Assert.isTrue(CallForOffersService.shouldFire(3, 7, due, due), 'Rung 3 fires after rung 7');
        Assert.isFalse(CallForOffersService.shouldFire(3, 3, due, due), 'and then goes quiet');
        Assert.isTrue(CallForOffersService.shouldFire(1, 3, due, due), 'Rung 1 fires after rung 3');
        Assert.isTrue(CallForOffersService.shouldFire(0, 1, due, due), 'Rung 0 fires on the day');
    }

    @isTest
    static void anOverdueDealDoesNotAlertEveryDayForEver() {
        Date due = Date.newInstance(2026, 9, 1);

        // Once rung 0 is stamped, the strictly-smaller test can never pass again — which is what
        // stops a deal that is a month overdue from notifying the queue thirty times.
        Assert.isFalse(CallForOffersService.shouldFire(0, 0, due, due),
            'An already-alerted overdue deal must stay silent');
    }

    @isTest
    static void aMissedRunCatchesUpRatherThanSkippingTheRungForEver() {
        Date asOf = Date.newInstance(2026, 8, 14);
        Date due = asOf.addDays(2);

        // The job did not run for five days: the deal went from 7-days-out straight to 2-days-out.
        // A stateless "fire when daysRemaining is exactly 7/3/1/0" rule would skip the rung SILENTLY
        // and for ever. The monotone marker fires the smallest rung the deal is now inside.
        CallForOffersService.CallForOffers c = CallForOffersService.evaluate(due, asOf);
        Assert.areEqual(3, c.dueInterval, '2 days out sits in the 3-day rung');
        Assert.isTrue(CallForOffersService.shouldFire(c.dueInterval, null, due, null),
            'A missed run must catch up, not skip the rung');
    }

    @isTest
    static void movedDeadlineReArmsTheWholeLadder() {
        Date originalDue = Date.newInstance(2026, 9, 1);
        Date extendedDue = Date.newInstance(2026, 9, 11);

        // The marker says rung 3 already fired, against the ORIGINAL deadline.
        // CallForOffersStampService is last-email-wins on Offer_Due_Date__c ON PURPOSE, so the deal
        // now carries the extended date. Without the snapshot comparison the marker would stay armed
        // at 3 against a date that no longer exists and rung 7 of the NEW deadline would never fire.
        Assert.isTrue(
            CallForOffersService.shouldFire(7, 3, extendedDue, originalDue),
            'A moved deadline must RE-ARM the ladder — this is the O2 failure the snapshot field '
            + 'exists to prevent, and it is silent when it happens');

        // Control: the identical inputs with a MATCHING snapshot must stay silent, or the assertion
        // above would pass for the wrong reason (a shouldFire that always returns true).
        Assert.isFalse(
            CallForOffersService.shouldFire(7, 3, extendedDue, extendedDue),
            'and must NOT re-arm when the deadline did not actually move');
    }

    @isTest
    static void aStampedIntervalWithNoSnapshotReArmsRatherThanGoingSilent() {
        Date due = Date.newInstance(2026, 9, 1);

        // An anomalous shape (interval stamped, snapshot null) can only arise from a partial write
        // or a hand edit. It must fail toward an EXTRA alert, never toward permanent silence.
        Assert.isTrue(CallForOffersService.shouldFire(3, 3, due, null),
            'A marker with no snapshot must re-arm — silence is the unrecoverable direction');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RECORD-BACKED ENTRY POINTS
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void evaluateAllIsNullAndEmptySafe() {
        Assert.areEqual(0, CallForOffersService.evaluateAll(null, Date.today()).size(),
            'A null list returns empty, never null');
        Assert.areEqual(0,
            CallForOffersService.evaluateAll(new List<Opportunity>(), Date.today()).size(),
            'An empty list returns empty');
        // A null ROW inside a real list must be skipped rather than throwing inside a batch chunk.
        Assert.areEqual(0,
            CallForOffersService.evaluateAll(new List<Opportunity>{ null }, Date.today()).size(),
            'A null row is skipped');
    }

    @isTest
    static void receivedDateIsTheStampedFieldAndNeverTheProxy() {
        // 🔴 THE FALSIFIER FOR THE WHOLE 2026-08-14 CHANGE, AND IT POINTS IN BOTH DIRECTIONS.
        // Until then `receivedDate` was `Broker_First_Seen__c ?? CreatedDate.date()` — a real fact
        // about the DEAL rendered under a column headed "Received", months adrift on exactly the
        // deals the column exists for. Reinstating that coalesce is a ONE-LINE, innocent-looking
        // edit whose symptom is invisible (the column still shows a plausible date), so it needs a
        // test that fails on it rather than review.
        //
        // The two fixtures disagree in OPPOSITE directions, which is what makes the pair
        // falsifying rather than merely descriptive:
        //   • proxy present, stamp ABSENT  -> receivedDate must be NULL. Fails if the fallback
        //     comes back.
        //   • both present and DIFFERENT   -> receivedDate must be the STAMP. Fails if the
        //     precedence is ever inverted, which the first fixture alone cannot see.
        Date firstSeen = Date.today().addDays(-120);
        Date stamped = Date.today().addDays(-2);

        Opportunity proxyOnly = TestDataFactory.createOpportunity(null, true);
        proxyOnly.Broker_First_Seen__c = firstSeen;
        proxyOnly.Offer_Due_Date__c = Date.today().addDays(5);

        Opportunity both = TestDataFactory.createOpportunity(null, true);
        both.Broker_First_Seen__c = firstSeen;
        both.Call_For_Offers_Received_Date__c = stamped;
        both.Offer_Due_Date__c = Date.today().addDays(5);
        update new List<Opportunity>{ proxyOnly, both };

        List<CallForOffersService.CallForOffers> states = CallForOffersService.evaluateAll(
            reloadForEvaluate(new Set<Id>{ proxyOnly.Id, both.Id }), Date.today());
        Map<Id, CallForOffersService.CallForOffers> byId =
            new Map<Id, CallForOffersService.CallForOffers>();
        for (CallForOffersService.CallForOffers state : states) {
            byId.put(state.opportunityId, state);
        }

        Assert.areEqual(2, states.size(), 'Both deals evaluate');
        Assert.isNull(byId.get(proxyOnly.Id).receivedDate,
            'NULL IS THE HONEST ANSWER. No call-for-offers email has been stamped on this deal, so '
            + 'there is no received date — even though Broker_First_Seen__c is populated and the '
            + 'pre-2026-08-14 code would have shown it here, 120 days off any email');
        Assert.areEqual(firstSeen, byId.get(proxyOnly.Id).dealArrivedDate,
            'The old derivation is still computed — under its own name, as a different fact');
        Assert.areEqual(stamped, byId.get(both.Id).receivedDate,
            'and where the real field IS stamped it wins outright. If this ever reads ' + firstSeen
            + ' the precedence has been inverted');
        Assert.areEqual(firstSeen, byId.get(both.Id).dealArrivedDate,
            'with the two facts still carried side by side, never merged');
    }

    @isTest
    static void dealArrivedDateKeepsTheOldChainUnderItsOwnName() {
        // The demoted proxy's own behaviour, pinned where it now lives. ⚠ Nothing in this repo
        // writes Broker_First_Seen__c (LeadConvertService does not copy it and no flow touches
        // it), so in production this chain is ALWAYS the CreatedDate leg — which is precisely why
        // it is no longer allowed near `receivedDate`. The first leg is asserted anyway because
        // the field is on the layout and a human can populate it by hand.
        Opportunity withBroker = TestDataFactory.createOpportunity(null, true);
        Date firstSeen = Date.today().addDays(-40);
        withBroker.Broker_First_Seen__c = firstSeen;
        withBroker.Offer_Due_Date__c = Date.today().addDays(5);

        Opportunity withoutBroker = TestDataFactory.createOpportunity(null, true);
        withoutBroker.Offer_Due_Date__c = Date.today().addDays(5);
        update new List<Opportunity>{ withBroker, withoutBroker };

        List<Opportunity> reloaded = reloadForEvaluate(
            new Set<Id>{ withBroker.Id, withoutBroker.Id });
        Map<Id, Opportunity> rowsById = new Map<Id, Opportunity>(reloaded);

        Map<Id, CallForOffersService.CallForOffers> byId =
            new Map<Id, CallForOffersService.CallForOffers>();
        for (CallForOffersService.CallForOffers state
                : CallForOffersService.evaluateAll(reloaded, Date.today())) {
            byId.put(state.opportunityId, state);
        }

        Assert.areEqual(firstSeen, byId.get(withBroker.Id).dealArrivedDate,
            'Broker_First_Seen__c wins when it is populated');
        Assert.areEqual(rowsById.get(withoutBroker.Id).CreatedDate.date(),
            byId.get(withoutBroker.Id).dealArrivedDate,
            'and the created date is the documented fallback — see the class header §4');
        Assert.isNull(byId.get(withBroker.Id).receivedDate,
            'and NEITHER leg leaks into receivedDate');
        Assert.isNull(byId.get(withoutBroker.Id).receivedDate, '');
    }

    /**
     * Reload deals with EXACTLY the field set `OpportunitySelector`'s two USER_MODE
     * call-for-offers reads select.
     *
     * ⚠ IT MUST STAY IN STEP WITH THEM. `evaluateAll` reads every one of these off the row, and a
     * field this query omits throws `SObjectException: SObject row was retrieved via SOQL without
     * querying the requested field` at the point of use rather than here — so a drifted list
     * surfaces as an unrelated-looking failure inside the service.
     *
     * @param dealIds The deals to load.
     * @return The rows, in no guaranteed order — callers index by Id.
     */
    private static List<Opportunity> reloadForEvaluate(Set<Id> dealIds) {
        return [
            SELECT Id, Name, CreatedDate, Offer_Due_Date__c, Call_For_Offers_Received_Date__c,
                   Broker_First_Seen__c, Sale_Process__c, Listing_Broker_Name__c,
                   Listing_Broker_Email__c, Deal_Room_Link__c
            FROM Opportunity
            WHERE Id IN :dealIds
        ];
    }

    @isTest
    static void propertyNameIsTheOpportunityNameAndTheLinkIsBuiltServerSide() {
        Opportunity deal = TestDataFactory.createOpportunity(null, false);
        deal.Name = 'Magnolia Crossing';
        insert deal;
        deal.Offer_Due_Date__c = Date.today().addDays(2);
        update deal;

        CallForOffersService.CallForOffers c = CallForOffersService.evaluateAll(
            reloadForEvaluate(new Set<Id>{ deal.Id }), Date.today())[0];

        Assert.areEqual('Magnolia Crossing', c.propertyName,
            'The deal name IS the property name — see the class header §4 for why this does not '
            + 'traverse Property__r.Name');
        Assert.areEqual('/lightning/r/Opportunity/' + deal.Id + '/view', c.recordUrl,
            'The link is built server-side so the table does not assemble URLs in JS');
        Assert.areEqual(deal.Id, c.opportunityId, 'and the row carries its own Id');
    }

    @isTest
    static void forOpportunityReturnsNoDueDateRatherThanNullForAMiss() {
        // NOT-FOUND CONTRACT. A null would render an empty box indistinguishable from a failure.
        CallForOffersService.CallForOffers fromNull = CallForOffersService.forOpportunity(null);
        Assert.isNotNull(fromNull, 'A null Id must not return null');
        Assert.areEqual('NO_DUE_DATE', fromNull.urgency, 'It returns the no-deadline state');

        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        delete deal;
        CallForOffersService.CallForOffers fromMissing =
            CallForOffersService.forOpportunity(deal.Id);
        Assert.isNotNull(fromMissing, 'An unresolvable Id must not return null either');
        Assert.areEqual('NO_DUE_DATE', fromMissing.urgency, 'It returns the no-deadline state too');
    }

    @isTest
    static void forOpportunityCarriesTheWholeCallForOffersBlock() {
        Opportunity deal = TestDataFactory.createOpportunity(null, true);
        deal.Offer_Due_Date__c = Date.today().addDays(3);
        deal.Call_For_Offers_Received_Date__c = Date.today().addDays(-1);
        deal.Sale_Process__c = 'Call for Offers';
        deal.Listing_Broker_Name__c = 'Jane Broker';
        deal.Listing_Broker_Email__c = 'jane.broker@example.invalid';
        deal.Deal_Room_Link__c = 'https://example.invalid/dealroom';
        update deal;

        CallForOffersService.CallForOffers c = CallForOffersService.forOpportunity(deal.Id);

        Assert.areEqual('CRITICAL', c.urgency, 'Three days out is critical');
        Assert.areEqual(Date.today().addDays(-1), c.receivedDate,
            'The RECORD-PAGE read carries the stamped received date too — the two USER_MODE '
            + 'selector methods share a field list, so a field added to one and not the other is a '
            + 'runtime SObjectException on exactly one of the two surfaces');
        Assert.areEqual('Call for Offers', c.saleProcess, 'Sale process is carried');
        Assert.areEqual('Jane Broker', c.listingBrokerName, 'Listing broker name is carried');
        Assert.areEqual('jane.broker@example.invalid', c.listingBrokerEmail, 'and their email');
        Assert.areEqual('https://example.invalid/dealroom', c.dealRoomLink, 'and the deal room');
    }

    @isTest
    static void upcomingExcludesDealsWithNoDeadlineAndOrdersBySoonestFirst() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(3, true);
        deals[0].Offer_Due_Date__c = Date.today().addDays(10);
        deals[1].Offer_Due_Date__c = Date.today().addDays(2);
        // deals[2] deliberately keeps a null due date.
        update deals;

        List<CallForOffersService.CallForOffers> states = CallForOffersService.upcoming();

        Assert.areEqual(2, states.size(), 'A deal with no deadline is not a call-for-offers deal');
        Assert.areEqual(deals[1].Id, states[0].opportunityId, 'Soonest deadline first');
        Assert.areEqual(deals[0].Id, states[1].opportunityId, 'then the later one');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BULK — .claude/rules/bulk-test-rule.md
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void upcomingAt251DealsIsOneQuery() {
        List<Opportunity> deals = TestDataFactory.createOpportunities(251, true);
        for (Integer i = 0; i < deals.size(); i++) {
            deals[i].Offer_Due_Date__c = Date.today().addDays(Math.mod(i, 30));
        }
        update deals;

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<CallForOffersService.CallForOffers> states = CallForOffersService.upcoming();
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(251, states.size(), 'Every deal with a deadline is evaluated');
        // 🔴 THE ASSERTION THAT ACTUALLY EARNS ITS PLACE. A future change that reads one extra row
        // per deal — a Property lookup, a per-record describe — would still return 251 states and
        // still be green on the count. It fails HERE. Measured INSIDE the transaction rather than
        // via Limits.* after Test.stopTest(), which restores the pre-test counters and would make
        // the obvious assertion silently vacuous.
        Assert.areEqual(1, queriesUsed,
            'upcoming() must be exactly ONE query regardless of how many deals match');

        // Ordering must survive volume too, or the table's "soonest first" promise is only true on
        // small data.
        for (Integer i = 1; i < states.size(); i++) {
            Assert.isTrue(states[i - 1].dueDate <= states[i].dueDate,
                'Rows must stay ordered soonest-deadline-first at 251 rows');
        }
    }
}
