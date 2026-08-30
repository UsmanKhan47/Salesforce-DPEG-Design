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
        // ⚠ THE LADDER IS INJECTED AS OF 2026-08-30 — see `installShippedLadder`. Its values moved
        // to CFO_Alert_Rung__mdt (org state), so without this line every `dueInterval` assertion
        // below would silently become an assertion about the running org's configuration rather
        // than about this class's derivation. The BAND thresholds (CRITICAL_DAYS /
        // APPROACHING_DAYS) are still Apex constants and are still what this test couples the
        // rungs to.
        installShippedLadder();

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
        // Ladder injected for the same reason as `everyRungOfTheLadderMapsToExactlyOneBand`: the
        // `dueInterval` assertion below names a specific rung, which is org state since 2026-08-30.
        installShippedLadder();

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
        //
        // ⚠ `firstSeen` BECAME A `Datetime` ON 2026-08-30 (WS2) — the field changed Date ->
        // DateTime to match its new source, `Lead.First_Seen_Date__c`. The 12:00:00 is not
        // decoration: the service truncates with `Datetime.date()` in the running user's zone, and
        // midday keeps the calendar date identical for any offset from -11 to +11, so these
        // assertions measure the truncation and not the CI box's time zone. The expected values
        // below are written `firstSeen.date()` for the same reason — an assertion against a
        // separately-computed `Date.today().addDays(-120)` would drift from the fixture the moment
        // anyone changed one of the two.
        Datetime firstSeen = Datetime.newInstance(
            Date.today().addDays(-120), Time.newInstance(12, 0, 0, 0));
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
        Assert.areEqual(firstSeen.date(), byId.get(proxyOnly.Id).dealArrivedDate,
            'The old derivation is still computed — under its own name, as a different fact, and '
            + 'TRUNCATED to a Date: the DTO member stays a Date now that the source field is a '
            + 'Datetime, because it feeds a live UI column');
        Assert.areEqual(stamped, byId.get(both.Id).receivedDate,
            'and where the real field IS stamped it wins outright. If this ever reads ' + firstSeen
            + ' the precedence has been inverted');
        Assert.areEqual(firstSeen.date(), byId.get(both.Id).dealArrivedDate,
            'with the two facts still carried side by side, never merged');
    }

    @isTest
    static void dealArrivedDateKeepsTheOldChainUnderItsOwnName() {
        // The demoted proxy's own behaviour, pinned where it now lives.
        //
        // 🔴 THIS COMMENT USED TO READ *"Nothing in this repo writes Broker_First_Seen__c
        // (LeadConvertService does not copy it and no flow touches it), so in production this
        // chain is ALWAYS the CreatedDate leg"*, AND THAT IS FALSE AS OF 2026-08-30 (WS2).
        // `LeadConvertService.applyDealFields` now copies `Lead.First_Seen_Date__c` into it on
        // every conversion, so the FIRST leg is the ordinary production case for newly converted
        // deals and the CreatedDate leg is what older deals and hand-created Opportunities take.
        // Both legs were already asserted below; what changed is which one is rare. The demotion
        // of this chain away from `receivedDate` is unaffected and is if anything more necessary —
        // the value it produces is now real rather than always-null.
        //
        // ⚠ `firstSeen` is a Datetime for the same reason as in the test above (field type change,
        // WS2); midday keeps `.date()` zone-independent.
        Opportunity withBroker = TestDataFactory.createOpportunity(null, true);
        Datetime firstSeen = Datetime.newInstance(
            Date.today().addDays(-40), Time.newInstance(12, 0, 0, 0));
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

        Assert.areEqual(firstSeen.date(), byId.get(withBroker.Id).dealArrivedDate,
            'Broker_First_Seen__c wins when it is populated, truncated to its calendar date');
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
                   Listing_Broker_Email__c, Deal_Room_Link__c, Offer_Status__c
            FROM Opportunity
            WHERE Id IN :dealIds
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE LADDER'S VALUES — Custom Metadata, and the sort that must not be assumed
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Build an in-memory rung row. CMDT rows CANNOT be inserted by a test, which is the whole
     * reason `CallForOffersService.overrideRungsForTest` exists.
     *
     * @param developerName Row name, used only in WARN text.
     * @param days          `Days_Before_Due__c`; null is a legitimate (skipped) input.
     * @param active        `Is_Active__c`.
     * @return The unsaved row.
     */
    private static CFO_Alert_Rung__mdt rung(String developerName, Integer days, Boolean active) {
        return new CFO_Alert_Rung__mdt(
            DeveloperName = developerName,
            Days_Before_Due__c = days,
            Is_Active__c = active
        );
    }

    /**
     * Install the SHIPPED ladder, in a deliberately scrambled order.
     *
     * ═══ 🔴 WHY THE BAND TESTS NOW HAVE TO CALL THIS ═══
     * Until 2026-08-30 the ladder was an Apex constant, so every `dueInterval` assertion in this
     * class was deterministic by construction. The values now live in `CFO_Alert_Rung__mdt`, which
     * is ORG STATE — script-loaded, Setup-editable, and different in every org. Left alone, the two
     * band tests below would silently become assertions about whatever the org happens to be
     * configured with: green here, red on a box where an admin retuned a rung, and — worst —
     * PASSING FOR THE WRONG REASON on a fresh org where the fallback happens to supply the same
     * numbers. Injecting the ladder makes them measure the DERIVATION again rather than the config.
     *
     * ⚠ THE SCRAMBLED ORDER IS THE POINT, NOT AN AFFECTATION. `getAll()` returns a Map with no
     * guaranteed iteration order, so a test that injected `{7, 3, 1, 0}` already sorted would pass
     * against an implementation that never sorts at all.
     */
    private static void installShippedLadder() {
        CallForOffersService.overrideRungsForTest(new List<CFO_Alert_Rung__mdt>{
            rung('Rung_Due_Day', 0, true),
            rung('Rung_7_Day', 7, true),
            rung('Rung_1_Day', 1, true),
            rung('Rung_3_Day', 3, true)
        });
    }

    @isTest
    static void rungsAreSortedDescendingRegardlessOfSourceOrder() {
        // 🔴 THE FALSIFIER FOR THE SINGLE MOST DANGEROUS LINE IN THE 5(d) CHANGE.
        //
        // `intervalFor` walks the ladder and keeps the LAST entry the countdown is inside. That
        // only yields "the SMALLEST rung the deal is still inside" when the list is DESCENDING.
        // The old Apex literal was hand-written descending, so the property was free. `getAll()`
        // returns a Map, and A MAP HAS NO GUARANTEED ITERATION ORDER — so an implementation that
        // forgot to sort would be correct on some orgs and wrong on others, with NO error, NO log
        // and a plausible-looking answer either way.
        //
        // The rows below are injected in the order {0, 7, 1, 3}. Under an UNSORTED implementation a
        // deal 2 days out matches 7, then 3, then... the last match wins, so it would report the
        // `3` rung only by luck of the map's order. The assertion at 2 days is the one that
        // discriminates: 3 is correct, 1 is what a wrongly-ordered ladder produces.
        installShippedLadder();

        Date asOf = Date.newInstance(2026, 8, 14);

        Assert.areEqual(3, CallForOffersService.evaluate(asOf.addDays(2), asOf).dueInterval,
            '2 days out sits in the 3-day rung. A 1 here means the ladder was not sorted '
            + 'descending and the deal would be notified a day late');
        Assert.areEqual(7, CallForOffersService.evaluate(asOf.addDays(5), asOf).dueInterval,
            '5 days out sits in the 7-day rung');
        Assert.areEqual(1, CallForOffersService.evaluate(asOf.addDays(1), asOf).dueInterval,
            '1 day out sits in the 1-day rung');
        Assert.areEqual(0, CallForOffersService.evaluate(asOf, asOf).dueInterval,
            'and the due date itself sits in the 0 rung');
        Assert.isNull(CallForOffersService.evaluate(asOf.addDays(8), asOf).dueInterval,
            'while 8 days out is outside the widest rung entirely');
    }

    @isTest
    static void anEmptyMetadataTypeFallsBackToTheShippedLadder() {
        // 🔴 THE DEPLOY-SAFETY PROPERTY, AND IT IS NOT DEFENSIVE PADDING.
        // A CustomMetadata RECORD cannot be deployed in this repo (.forceignore excludes the tree;
        // file-based record deploy throws UNKNOWN_EXCEPTION), so the rungs are created by
        // scripts/load-cfo-alert-rungs.apex — a MANUAL post-deploy step. "The loader was never
        // run" is therefore a reachable state in every fresh org and in any test run made before
        // it. Without this fallback, shipping Item 5(d) would ship a WORKING feature and silently
        // kill it until somebody remembered a script; the failure would look exactly like a quiet
        // week. Same shape, same reason, as BrokerProtectionConfig's per-accessor defaults.
        CallForOffersService.overrideRungsForTest(new List<CFO_Alert_Rung__mdt>());

        Date asOf = Date.newInstance(2026, 8, 14);

        Assert.areEqual(7, CallForOffersService.evaluate(asOf.addDays(5), asOf).dueInterval,
            'With NO rung rows the shipped {7,3,1,0} ladder is used, so behaviour is identical to '
            + 'the pre-5(d) code');
        Assert.areEqual(3, CallForOffersService.evaluate(asOf.addDays(2), asOf).dueInterval,
            'at every rung');
        Assert.isNull(CallForOffersService.evaluate(asOf.addDays(8), asOf).dueInterval,
            'including the ceiling above it');
    }

    @isTest
    static void everyRungDeactivatedIsHONOUREDRatherThanOverridden() {
        // 🔴 THE DISTINCTION THE FALLBACK ABOVE MUST NOT SWALLOW, AND THE REASON `resolveRungs`
        // counts ROWS and ACTIVE ROWS SEPARATELY.
        //   • no rows at all  = "the loader was never run"      -> fall back (test above)
        //   • rows, none active = "an admin switched it off"    -> HONOUR the empty ladder
        // Collapsing the two into one `isEmpty()` check would make "turn the alerts off" an
        // unexpressible intent: unchecking every Is_Active__c would silently restore the default
        // ladder and the alerts would keep firing, with the Setup screen showing them disabled.
        CallForOffersService.overrideRungsForTest(new List<CFO_Alert_Rung__mdt>{
            rung('Rung_7_Day', 7, false),
            rung('Rung_3_Day', 3, false),
            rung('Rung_1_Day', 1, false),
            rung('Rung_Due_Day', 0, false)
        });

        Date asOf = Date.newInstance(2026, 8, 14);

        Assert.isNull(CallForOffersService.evaluate(asOf.addDays(2), asOf).dueInterval,
            'With every rung deactivated NOTHING sits in a rung');
        Assert.isNull(CallForOffersService.evaluate(asOf, asOf).dueInterval,
            'not even a deal due today');
        Assert.isFalse(CallForOffersService.shouldFire(null, null, asOf, null),
            'and therefore nothing is ever owed an alert — which is what "off" has to mean');
    }

    @isTest
    static void anActiveRowWithNoDayCountIsSkippedRatherThanBreakingTheLadder() {
        // An incomplete Setup row is an admin mid-edit, not an instruction. It must not participate
        // (a null cannot take part in a `<=` comparison) and must not take the rest of the ladder
        // down with it.
        CallForOffersService.overrideRungsForTest(new List<CFO_Alert_Rung__mdt>{
            rung('Rung_7_Day', 7, true),
            rung('Rung_Incomplete', null, true),
            rung('Rung_Due_Day', 0, true)
        });

        Date asOf = Date.newInstance(2026, 8, 14);

        Assert.areEqual(7, CallForOffersService.evaluate(asOf.addDays(5), asOf).dueInterval,
            'The complete rows still form a working ladder');
        Assert.areEqual(0, CallForOffersService.evaluate(asOf, asOf).dueInterval,
            'including the smallest one');
    }

    @isTest
    static void inactiveAndDuplicateRungsAreFilteredOut() {
        // Two facts in one fixture: `Is_Active__c = false` genuinely removes a rung from the
        // ladder, and a duplicated value does not change the outcome (the set de-duplicates, so
        // `intervalFor`'s last-match walk cannot be perturbed by a repeated entry).
        CallForOffersService.overrideRungsForTest(new List<CFO_Alert_Rung__mdt>{
            rung('Rung_7_Day', 7, true),
            rung('Rung_3_Day', 3, false), // deactivated — the 3 rung must vanish
            rung('Rung_1_Day', 1, true),
            rung('Rung_1_Day_Duplicate', 1, true)
        });

        Date asOf = Date.newInstance(2026, 8, 14);

        Assert.areEqual(7, CallForOffersService.evaluate(asOf.addDays(2), asOf).dueInterval,
            'With the 3 rung deactivated, a deal 2 days out falls back to the 7 rung — the next '
            + 'one it is still inside');
        Assert.areEqual(1, CallForOffersService.evaluate(asOf.addDays(1), asOf).dueInterval,
            'and the duplicated 1 rung behaves as a single rung');
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
        deal.Offer_Status__c = 'Submitted';
        update deal;

        installShippedLadder();
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
        Assert.areEqual('Submitted', c.offerStatus,
            'and the offer status, VERBATIM. `Submitted` is deliberately not `Open` here: a DTO '
            + 'member that defaulted or normalised the value would still pass an assertion against '
            + 'the default');
    }

    @isTest
    static void offerStatusIsNeverDefaultedToOpen() {
        // 🔴 THE FALSIFIER FOR A ONE-LINE, INNOCENT-LOOKING EDIT. `Offer_Status__c` carries a
        // picklist <default> of `Open`, and a <default> applies on INSERT ONLY — it does not
        // backfill — so every deal created before 2026-08-30 sends null here for ever. A
        // `?? 'Open'` in `evaluateAll` would look like sensible defensive coding and would assert a
        // campaign state the record does not hold, across the whole legacy population, on both
        // surfaces at once. The symptom would be a plausible value in a plausible place.
        //
        // ⚠ IT ASSERTS IN BOTH DIRECTIONS: absent -> null, present -> the stored value wins.
        // Either alone is satisfiable by a wrong implementation.
        Opportunity noStatus = TestDataFactory.createOpportunity(null, true);
        noStatus.Offer_Due_Date__c = Date.today().addDays(5);

        Opportunity withStatus = TestDataFactory.createOpportunity(null, true);
        withStatus.Offer_Due_Date__c = Date.today().addDays(5);
        withStatus.Offer_Status__c = 'Closed';
        update new List<Opportunity>{ noStatus, withStatus };

        Map<Id, CallForOffersService.CallForOffers> byId =
            new Map<Id, CallForOffersService.CallForOffers>();
        for (CallForOffersService.CallForOffers state : CallForOffersService.evaluateAll(
                reloadForEvaluate(new Set<Id>{ noStatus.Id, withStatus.Id }), Date.today())) {
            byId.put(state.opportunityId, state);
        }

        Assert.isNull(byId.get(noStatus.Id).offerStatus,
            'NULL IS THE HONEST ANSWER for a deal whose campaign nobody has touched');
        Assert.areEqual('Closed', byId.get(withStatus.Id).offerStatus,
            'and a stored status travels verbatim');
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
