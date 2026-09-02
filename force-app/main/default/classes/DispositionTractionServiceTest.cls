/**
 * @description Tests DispositionTractionService — the Active Listing traction monitor
 * (user decision A2, 2026-09-02: Week 2/4/6 thresholds — the first rung moved 7 -> 14. User
 * decisions 2026-08-21: the Week x/4/6 ladder shape + the first-offer clock pause. D28-Q1
 * offers-only rule, unchanged throughout).
 *
 * ── 🔴 THIS SUITE IS THE PERMANENT FALSIFIER FOR THE 14/28/42 CLOCK ─────────
 * THREE ladders have now been retired from this application, and the first two drifted because the
 * numbers lived in more than one place and no single test went red when they moved: 21/28/42
 * (retired 2026-08-10) and 30/40/60 (retired 2026-08-21). 7/28/42 (retired 2026-09-02) did NOT
 * drift — it was changed by an explicit decision, which is what this suite is for. Every boundary
 * below is asserted on BOTH sides — 13/14, 27/28, 41/42 — because an off-by-one in a threshold is
 * the defect a "does it roughly work" test cannot see, and
 * `theLadderIsExactly14_28_42_andTheBandFlipsAtEachOfThem` pins the three numbers themselves so
 * that moving one without a decision fails HERE rather than in front of a client.
 *
 * ⚠ THE 2026-09-02 MOVE LEFT A FALSIFIER BEHIND ON PURPOSE: day 7 is now asserted to be
 * `ON_TRACK`. It is the exact day the retired ladder escalated on, so a change that renames the
 * enum member without moving the number goes red on that one clause and on nothing else.
 *
 * ── WHY THE BOUNDARY TESTS DRIVE `evaluate` DIRECTLY ────────────────────────
 * `evaluate(Date, Integer, Date)` takes the listing date, the offer count and the first offer date
 * as ARGUMENTS and reads the clock exactly once against them. That is what makes every band and
 * every rung state reachable without seeding aged data, without `Test.setCreatedDate`, and without a
 * clock fixture — and it is why the pure/orchestrating split exists at all rather than one method
 * doing both.
 *
 * ── ⚠ THE FACTORY DATES EVERY OFFER `Date.today()`, WHICH MAKES THE OBVIOUS PAUSE TEST VACUOUS ──
 * `TestDataFactory.createDispositionOffers` sets `Offer_Date__c = Date.today()` on every fixture, so
 * an offer inserted the ordinary way pauses the clock AT TODAY — i.e. does not visibly pause it at
 * all. The pause tests below therefore build offers with `doInsert = false`, back-date them, and
 * insert them in one DML. A test that forgot would pass while proving nothing.
 *
 * ── WHAT THIS SUITE DELIBERATELY DOES NOT DO ───────────────────────────────
 * It does not assert exact label prose word-for-word beyond the parts that carry MEANING (the day
 * number, the week number, the band, the offer count, the word "paused"). Pinning marketing copy
 * makes a suite red for a typo fix; the LWC suite asserts that whatever the server sends is what
 * renders.
 *
 * `.claude/rules/bulk-test-rule.md`: `evaluate` and the rung builders are pure functions over
 * scalars with no DML and no collection input, so the 251 mandate does not reach them — every rung
 * and every boundary is asserted instead. `evaluateAll` IS bulk-tested at 251, and the assertion
 * that matters there is the QUERY BUDGET.
 *
 * @see force-app/main/default/classes/DispositionTractionService.cls
 * @see force-app/main/default/lwc/listingAlerts/__tests__/listingAlerts.test.js
 * @author Salesforce Developer
 */
@isTest
private class DispositionTractionServiceTest {

    private static final Integer BULK_N = 251;

    /** A listing date exactly N days in the past, i.e. "day N of the marketing clock". */
    private static Date dayN(Integer n) {
        return Date.today().addDays(-n);
    }

    private static DispositionTractionService.Traction atDay(Integer n, Integer offers) {
        return DispositionTractionService.evaluate(dayN(n), offers);
    }

    /** The rung carrying `key`, or null. Reads the payload the way the LWC does. */
    private static DispositionTractionService.Rung rung(
        DispositionTractionService.Traction t,
        String key
    ) {
        for (DispositionTractionService.Rung r : t.rungs) {
            if (r.key == key) {
                return r;
            }
        }
        return null;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE THRESHOLDS THEMSELVES — the mutation falsifier
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE HIGHEST-VALUE TEST IN THIS CLASS. It pins the three numbers AND the fact that the band
     * flips exactly at them, so a change to any threshold constant fails here even if every other
     * test in the suite were somehow written loosely. Both previous ladders drifted for want of
     * exactly this assertion.
     *
     * The numbers are read back off the PAYLOAD (`rung.days`, `marketingPeriodDays`) rather than off
     * the private constants, because that is the surface every consumer sees — if `evaluate` ever
     * compared against one number and published another, this would catch it and a
     * `@TestVisible`-constant assertion would not.
     */
    @isTest
    static void theLadderIsExactly14_28_42_andTheBandFlipsAtEachOfThem() {
        DispositionTractionService.Traction t = atDay(0, 0);

        Assert.areEqual(3, t.rungs.size(), 'The ladder has exactly three rungs');
        Assert.areEqual(14, t.rungs[0].days, 'Rung 1 is day 14 (Week 2)');
        Assert.areEqual(28, t.rungs[1].days, 'Rung 2 is day 28 (Week 4)');
        Assert.areEqual(42, t.rungs[2].days, 'Rung 3 is day 42 (Week 6)');
        Assert.areEqual(42, t.marketingPeriodDays,
            'The marketing period IS week 6 - two names for one number must never drift apart');

        // The flip points, read off the bands rather than the constants.
        // 🔴 DAY 7 IS THE FALSIFIER FOR THE 2026-09-02 MOVE (user decision A2). Under the retired
        // 7/28/42 ladder day 7 was the FIRST RUNG; under 14/28/42 it is ON_TRACK. A build that
        // renamed the enum member without moving the number would pass every other clause here and
        // fail this one.
        Assert.areEqual('ON_TRACK', atDay(7, 0).band,
            'Day 7 is BELOW the week-2 rung — this is the exact day the retired ladder escalated on');
        Assert.areEqual('ON_TRACK', atDay(13, 0).band, 'Day 13 is below the week-2 rung');
        Assert.areEqual('WEEK_2', atDay(14, 0).band, 'Day 14 IS the week-2 rung');
        Assert.areEqual('WEEK_2', atDay(27, 0).band, 'Day 27 is below the week-4 rung');
        Assert.areEqual('WEEK_4', atDay(28, 0).band, 'Day 28 IS the week-4 rung');
        Assert.areEqual('WEEK_4', atDay(41, 0).band, 'Day 41 is below the week-6 rung');
        Assert.areEqual('WEEK_6', atDay(42, 0).band, 'Day 42 IS the week-6 rung');
    }

    /**
     * 🔴 THE AT-RISK LINE IS AT WEEK 4, NOT AT THE FIRST RUNG. The retired ladder's first rung was
     * the day-30 half-way checkpoint and WAS at-risk; the first rung is now day FOURTEEN, and
     * marking a listing at risk a fortnight after it goes to market makes the flag meaningless. If
     * someone "restores consistency" by making every rung at-risk, this fails.
     *
     * ⚠ RENAMED FROM `weekOneIsACheckInAndIsNotAnAtRiskState` ON 2026-09-02 (user decision A2). The
     * assertion set is unchanged in shape; only the day the first rung fires moved, 7 -> 14.
     */
    @isTest
    static void weekTwoIsACheckInAndIsNotAnAtRiskState() {
        Assert.isFalse(atDay(14, 0).isAtRisk, 'Week 2 is a check-in, not a risk state');
        Assert.isFalse(atDay(27, 0).isAtRisk, 'Still a check-in on the last day of the week-2 band');
        Assert.isTrue(atDay(28, 0).isAtRisk, 'Week 4 IS an at-risk state');
        Assert.isTrue(atDay(42, 0).isAtRisk, 'Week 6 IS an at-risk state');
        Assert.areEqual('On Track', atDay(14, 0).listingStatusValue,
            'Week 2 stores On Track - the flag and the stored value follow ONE rule, not two');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE CLOCK HAS NOT STARTED — the state the whole item exists to make visible
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE DEFECT THIS FEATURE WAS BUILT TO REMOVE. `Disposition__c.Days_On_Market__c` carries
     * `formulaTreatBlanksAs = BlankAsZero`, so a disposition with no listing date reads 0 — which
     * is indistinguishable from "listed today". Reading the raw date instead is what lets a blank
     * be NOT_LISTED, and this test is the only thing that keeps it that way.
     */
    @isTest
    static void blankListingDateIsNotListed_neverAHealthyLookingDayZero() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(null, 0);

        Assert.areEqual(DispositionTractionService.Band.NOT_LISTED.name(), t.band,
            'A blank listing date must be NOT_LISTED, not day 0');
        Assert.isNull(t.daysOnMarket,
            'daysOnMarket must be null when the clock has not started - a 0 here is the BlankAsZero defect');
        Assert.isFalse(t.isListed, 'isListed must be false with no listing date');
        Assert.isFalse(t.isAtRisk, 'A listing that never started cannot be at risk');
        Assert.isFalse(t.isPaused, 'A clock that never started cannot be paused');
        Assert.areEqual('On Track', t.listingStatusValue,
            'NOT_LISTED maps to On Track - nothing is wrong yet');
    }

    /**
     * The rungs are rendered even before the clock starts, because the panel's job is to show the
     * SCHEDULE as well as the position on it. All three must read Ahead with no due date — an
     * undated rung is honest; a rung dated off a null listing date would not be.
     */
    @isTest
    static void notListedStillPublishesThreeUndatedRungsAllAhead() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(null, 0);

        Assert.areEqual(3, t.rungs.size(), 'The schedule is shown before the clock starts');
        for (DispositionTractionService.Rung r : t.rungs) {
            Assert.areEqual('Ahead', r.state, r.key + ' cannot be passed before the clock starts');
            Assert.isFalse(r.isReached, r.key + ' is not reached');
            Assert.isFalse(r.isCurrent, r.key + ' cannot be current');
            Assert.isNull(r.dueDate,
                r.key + ' must have NO due date - a date derived from a null listing date would be '
                + 'invented, which is the fixed-lie defect this panel exists to not repeat');
        }
    }

    /** A blank date with offers on it is still NOT_LISTED — the date is what starts the clock. */
    @isTest
    static void blankListingDateWithOffersIsStillNotListed() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(null, 4, dayN(3));

        Assert.areEqual(DispositionTractionService.Band.NOT_LISTED.name(), t.band,
            'Offers do not start the marketing clock; a listing date does');
        Assert.areEqual(4, t.offerCount, 'The count still passes through');
        Assert.isFalse(t.isPaused,
            'There is no clock to pause, so isPaused must be false even with a dated offer');
    }

    /** A null count is 0, never a NullPointerException from an @AuraEnabled boundary. */
    @isTest
    static void nullOfferCountIsTreatedAsZero() {
        DispositionTractionService.Traction t = DispositionTractionService.evaluate(dayN(35), null);

        Assert.areEqual(0, t.offerCount, 'A null offer count must normalise to 0');
        Assert.areEqual(DispositionTractionService.Band.WEEK_4.name(), t.band,
            'A null count must behave like zero offers, i.e. fire the week-4 rung');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // THE LADDER — every boundary asserted on BOTH sides
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void dayZeroIsOnTrack() {
        DispositionTractionService.Traction t = atDay(0, 0);

        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'Day 0 with no offers is On Track - nothing is due yet');
        Assert.areEqual(0, t.daysOnMarket, 'Day 0 is day 0');
        Assert.isTrue(t.isListed, 'A listing dated today HAS started its clock');
        Assert.isFalse(t.isAtRisk, 'Day 0 is not at risk');
        Assert.areEqual(42, t.daysRemaining, 'A 42-day period with 0 elapsed leaves 42');
    }

    /** BOUNDARY 1, LOW SIDE. Day 13 is the last day before the first check-in. */
    @isTest
    static void dayThirteenIsStillOnTrack() {
        DispositionTractionService.Traction t = atDay(13, 0);

        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'Day 13 is inside the first fortnight, so the check-in has not fallen due');
        Assert.isFalse(t.isAtRisk, 'Day 13 must not be flagged');
        Assert.isTrue(t.detail.contains('1 day'),
            'On the eve of the rung the copy must be singular: ' + t.detail);
        Assert.isTrue(t.detail.contains('week-2'),
            'The countdown sentence names the rung it is counting down to: ' + t.detail);
    }

    /**
     * 🔴 THE RETIRED RUNG'S DAY, KEPT AS A TEST OF ITS OWN (2026-09-02, user decision A2).
     * Day 7 escalated under the 7/28/42 ladder and must NOT escalate under 14/28/42. This is the
     * single clause that separates "the first rung moved" from "the enum member was renamed and the
     * number was left at 7", which is otherwise indistinguishable across the whole suite.
     */
    @isTest
    static void daySevenNoLongerFiresACheckIn() {
        DispositionTractionService.Traction t = atDay(7, 0);

        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'Day 7 is BELOW the week-2 rung. Under the retired 7/28/42 ladder this was WEEK_1.');
        Assert.isFalse(t.isAtRisk, 'Day 7 must not be flagged');
        Assert.isTrue(t.detail.contains('7 days'),
            'Seven days still to run to the week-2 check-in: ' + t.detail);
    }

    /** BOUNDARY 1, HIGH SIDE. */
    @isTest
    static void dayFourteenFiresTheWeekTwoCheckIn() {
        DispositionTractionService.Traction t = atDay(14, 0);

        Assert.areEqual(DispositionTractionService.Band.WEEK_2.name(), t.band,
            'Day 14 with zero offers is the week-2 check-in');
        Assert.isFalse(t.isAtRisk, 'The check-in is not an at-risk state');
        Assert.isTrue(t.label.contains('Week 2'), 'The badge must name the week: ' + t.label);
        Assert.isTrue(t.detail.startsWith('Two weeks on the market'),
            'The detail sentence must name the fortnight, not a week: ' + t.detail);
    }

    /** BOUNDARY 2, LOW SIDE. */
    @isTest
    static void dayTwentySevenIsStillTheWeekTwoBand() {
        Assert.areEqual(DispositionTractionService.Band.WEEK_2.name(), atDay(27, 0).band,
            'Day 27 has not reached the week-4 rung');
    }

    /**
     * BOUNDARY 2, HIGH SIDE. Day 28 is the ONE threshold the user named verbatim, together with the
     * label it must carry: "Week 4 — At Risk".
     */
    @isTest
    static void dayTwentyEightIsWeekFourAtRisk() {
        DispositionTractionService.Traction t = atDay(28, 0);

        Assert.areEqual(DispositionTractionService.Band.WEEK_4.name(), t.band,
            'Day 28 is four weeks on the market with nothing to show');
        Assert.isTrue(t.isAtRisk, 'WEEK_4 is an at-risk state');
        Assert.areEqual('At Risk', t.listingStatusValue,
            'WEEK_4 maps to the At Risk picklist value');
        Assert.areEqual('Week 4 — At Risk', t.label,
            'THE ONE LABEL GIVEN VERBATIM BY THE USER. Do not reword it.');
        Assert.areEqual(14, t.daysRemaining, 'Day 28 of 42 leaves 14');
    }

    /** BOUNDARY 3, LOW SIDE. */
    @isTest
    static void dayFortyOneIsStillWeekFour() {
        Assert.areEqual(DispositionTractionService.Band.WEEK_4.name(), atDay(41, 0).band,
            'Day 41 has not yet elapsed the marketing period');
    }

    /** BOUNDARY 3, HIGH SIDE. */
    @isTest
    static void dayFortyTwoIsWeekSixHardStop() {
        DispositionTractionService.Traction t = atDay(42, 0);

        Assert.areEqual(DispositionTractionService.Band.WEEK_6.name(), t.band,
            'Day 42 with zero offers is the end of the marketing period');
        Assert.isTrue(t.isAtRisk, 'WEEK_6 is an at-risk state');
        Assert.areEqual('Hard Stop', t.listingStatusValue,
            'WEEK_6 maps to the Hard Stop picklist value');
        Assert.areEqual('Week 6 — Hard Stop', t.label, 'The badge names the week and the state');
        Assert.areEqual(0, t.daysRemaining, 'Nothing remains once the period has elapsed');
    }

    /** Well past the period: still WEEK_6, and daysRemaining never goes negative. */
    @isTest
    static void wellPastTheHardStopStaysHardStopAndClampsDaysRemaining() {
        DispositionTractionService.Traction t = atDay(400, 0);

        Assert.areEqual(DispositionTractionService.Band.WEEK_6.name(), t.band,
            'There is no band beyond Week 6');
        Assert.areEqual(0, t.daysRemaining, 'daysRemaining is clamped at 0, never negative');
        Assert.areEqual(400, t.daysOnMarket, 'The elapsed count itself is not clamped');
    }

    /**
     * A listing date in the FUTURE. `Date.daysBetween` is signed, so without the clamp this would
     * report a negative day and a daysRemaining above the period.
     */
    @isTest
    static void aFutureListingDateClampsToDayZero() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(Date.today().addDays(7), 0);

        Assert.areEqual(0, t.daysOnMarket, 'A future listing date is day 0, never a negative day');
        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'A listing that has not started yet is On Track');
        Assert.areEqual(42, t.daysRemaining, 'daysRemaining cannot exceed the marketing period');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE RUNGS — user decision 3: passed / current / ahead, as REAL state
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE ANTI-MOCK TEST. The component this feeds once shipped a hardcoded four-row table of
     * this exact ladder and it was deleted for "rendering a fixed lie". These assertions are what
     * make the rows data: the same three keys carry DIFFERENT states on different records.
     *
     * ═════════════════════════════════════════════════════════════════════════════════════════
     * 🔴 RE-DERIVED 2026-09-02 FOR THE WEEK-2 RUNG (user decision A2). IT WAS THE ONE TEST IN
     *    THIS CLASS THAT STILL ENCODED THE 7-DAY BOUNDARY, AND IT FAILED THE VALIDATE
     *    (`0Afiw000000VWmnCAG`): *"Day 7: WEEK_2 must read Current: Expected: Current, Actual:
     *    Ahead"*. The production change was right; this matrix had not been moved with it.
     * ═════════════════════════════════════════════════════════════════════════════════════════
     * ⚠ THE LAZY REPAIR WOULD HAVE BEEN TO RELABEL DAY 7 AS `Ahead` AND STOP. That passes, and it
     * proves NOTHING about where the boundary sits — it would pass just as happily with the first
     * rung at 20 days, or at 30. An off-by-one is the defect most likely to survive a rename, and
     * this class is the ONLY proof this item has: there are 0 `Broker_Listing__c` rows in
     * `usman-dpeg`, so `Listing_Date__c` is null everywhere and the rung cannot be rendered in any
     * state. Precision here is the whole guarantee.
     *
     * 🔴 SO EVERY ROW IS NOW A PAIR STRADDLING A THRESHOLD — the day BEFORE and the day OF, for
     * all three rungs. The three "before" rows look redundant against their neighbours and are
     * not: each is the last day on which its rung must still read `Ahead`.
     *
     *   day  |  WEEK_2  |  WEEK_4  |  WEEK_6  |  why this row exists
     *   -----+----------+----------+----------+-------------------------------------------------
     *    0   | Ahead    | Ahead    | Ahead    | the clock has started and nothing is due
     *   13   | Ahead    | Ahead    | Ahead    | LAST day below rung 1. Under 7/28/42 this read
     *        |          |          |          | `Current` — the low side of the moved boundary
     *   14   | Current  | Ahead    | Ahead    | rung 1 fires HERE, not on day 7
     *   27   | Current  | Ahead    | Ahead    | last day below rung 2 — rung 1 stays Current
     *   28   | Passed   | Current  | Ahead    | rung 2 fires; rung 1 is reached but not current
     *   41   | Passed   | Current  | Ahead    | last day below rung 3
     *   42   | Passed   | Passed   | Current  | rung 3 fires
     *
     * ⚠ DAY 7 IS DELIBERATELY ABSENT FROM THIS MATRIX AND IS **NOT** MISSING COVERAGE. It has two
     * dedicated falsifiers of its own — `daySevenNoLongerFiresACheckIn` here and
     * `testGetListing_dayTwelve_isBackInsideTheFirstRung` in `BrokerListingControllerTest` — which
     * exist precisely so a change that renames the enum without moving the number goes red. Adding
     * day 7 back here as an all-`Ahead` row would duplicate day 13 and weaken nothing, but it
     * would also read as though this matrix were the day-7 fence, which it is not.
     */
    @isTest
    static void everyRungCarriesExactlyOneStateAndTheStatesMoveWithTheClock() {
        Map<Integer, List<String>> expectedByDay = new Map<Integer, List<String>>{
            0  => new List<String>{ 'Ahead',   'Ahead',   'Ahead' },
            13 => new List<String>{ 'Ahead',   'Ahead',   'Ahead' },
            14 => new List<String>{ 'Current', 'Ahead',   'Ahead' },
            27 => new List<String>{ 'Current', 'Ahead',   'Ahead' },
            28 => new List<String>{ 'Passed',  'Current', 'Ahead' },
            41 => new List<String>{ 'Passed',  'Current', 'Ahead' },
            42 => new List<String>{ 'Passed',  'Passed',  'Current' }
        };
        Set<String> allowed = new Set<String>{ 'Passed', 'Current', 'Ahead' };

        for (Integer day : expectedByDay.keySet()) {
            DispositionTractionService.Traction t = atDay(day, 0);
            List<String> expected = expectedByDay.get(day);
            Integer currents = 0;
            for (Integer i = 0; i < 3; i++) {
                DispositionTractionService.Rung r = t.rungs[i];
                Assert.isTrue(allowed.contains(r.state),
                    'Day ' + day + ' rung ' + r.key + ' has an unknown state: ' + r.state);
                Assert.areEqual(expected[i], r.state,
                    'Day ' + day + ': ' + r.key + ' must read ' + expected[i]);
                Assert.areEqual(r.state == 'Current', r.isCurrent,
                    'isCurrent must agree with state on ' + r.key + ' at day ' + day);
                Assert.areEqual(r.state != 'Ahead', r.isReached,
                    'isReached must be true for Passed and Current only, on ' + r.key);
                if (r.isCurrent) {
                    currents++;
                }
            }
            Assert.isTrue(currents <= 1,
                'At most ONE rung may be Current; day ' + day + ' had ' + currents);
        }
    }

    /** The current rung is always the one matching the band — one derivation, not two. */
    @isTest
    static void theCurrentRungIsAlwaysTheBandsOwnRung() {
        for (Integer day : new List<Integer>{ 14, 28, 42, 100 }) {
            DispositionTractionService.Traction t = atDay(day, 0);
            DispositionTractionService.Rung r = rung(t, t.band);
            Assert.isNotNull(r, 'Day ' + day + ' band ' + t.band + ' must have a matching rung');
            Assert.isTrue(r.isCurrent,
                'Day ' + day + ': the rung named by the band must be the Current one');
        }
    }

    /** Rung due dates are the listing date plus the threshold — absolute, so the panel can show them. */
    @isTest
    static void rungDueDatesAreDerivedFromTheListingDate() {
        Date listed = Date.newInstance(2026, 3, 15);

        DispositionTractionService.Traction t = DispositionTractionService.evaluate(listed, 0);

        Assert.areEqual(listed.addDays(14), t.rungs[0].dueDate, 'Week 2 falls 14 days after listing');
        Assert.areEqual(listed.addDays(28), t.rungs[1].dueDate, 'Week 4 falls 28 days after listing');
        Assert.areEqual(listed.addDays(42), t.rungs[2].dueDate, 'Week 6 falls 42 days after listing');
        Assert.areEqual(listed, t.listingDate, 'The listing date passes through verbatim');
    }

    /** An unreached rung counts down in days, and says "day" not "days" at one. */
    @isTest
    static void anUnreachedRungCountsDownAndIsSingularAtOne() {
        Assert.areEqual('In 1 day.', rung(atDay(13, 0), 'WEEK_2').note,
            'One day short of the rung reads singular');
        Assert.areEqual('In 2 days.', rung(atDay(12, 0), 'WEEK_2').note,
            'Two days short reads plural');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE PAUSE (user decision, 2026-08-21) — offers stop the clock
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE PAUSE ITSELF, AND IT IS ASSERTED AGAINST THE UNPAUSED ANSWER FOR THE SAME RECORD. Both
     * calls carry the same listing date and the same offer count; the ONLY difference is whether a
     * first-offer date is supplied. If the pause were ever "implemented" as the pre-existing
     * suppress-the-level rule, both would read day 50 and this fails.
     */
    @isTest
    static void anOfferStopsTheClockAtTheOfferDateRatherThanSuppressingTheLevelOnly() {
        DispositionTractionService.Traction paused =
            DispositionTractionService.evaluate(dayN(50), 1, dayN(10));
        DispositionTractionService.Traction unpaused =
            DispositionTractionService.evaluate(dayN(50), 1, null);

        Assert.areEqual(40, paused.daysOnMarket,
            'The clock stopped 40 days after listing, on the day the offer arrived');
        Assert.areEqual(50, unpaused.daysOnMarket,
            'Without an offer date the clock is still running - this is the control');
        Assert.isTrue(paused.isPaused, 'A dated offer pauses the clock');
        Assert.isFalse(unpaused.isPaused,
            'An undated offer suppresses the level but cannot pause the clock at a day it does not know');
        Assert.areEqual(dayN(10), paused.firstOfferDate, 'The pause date is published');
        Assert.isTrue(paused.label.contains('paused'),
            'The badge must SAY it is paused, not just stop moving: ' + paused.label);
    }

    /**
     * 🔴 THE PAUSE OUTRANKS EVERY RUNG, INCLUDING WEEK 6. A listing 400 days old with an offer on
     * day 3 is not "Hard Stop" — that was precisely the defect the offers-only rule (D28/Q1) was
     * written to remove, and the pause makes the day number honest as well as the band.
     */
    @isTest
    static void aPausedClockNeverEscalatesNoMatterHowMuchRealTimePasses() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(dayN(400), 2, dayN(397));

        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'A paused listing is On Track at any real-world age');
        Assert.areEqual(3, t.daysOnMarket, 'The clock reads day 3 - where the offer stopped it');
        Assert.isFalse(t.isAtRisk, 'A listing in negotiation must never be flagged');
        Assert.areEqual('On Track', t.listingStatusValue, 'And it stores On Track');
    }

    /**
     * While paused, no rung is Current — nothing is escalating — and the notes say why.
     *
     * 🔴 THE FIXTURE MOVED ON 2026-09-02 AND THE MOVE IS THE POINT, NOT AN ADJUSTMENT. It read
     * `evaluate(dayN(60), 1, dayN(50))` — paused at day 10 — which under the retired 7/28/42 ladder
     * put the clock PAST the first rung. Under 14/28/42 day 10 is BEFORE it, so the "Passed before
     * the clock paused" assertion below would have gone vacuous-by-inversion: it would have failed
     * loudly (state `Ahead`), but a lazier repair — deleting the clause, or relaxing it to
     * `Ahead` — would have silently retired the only test that proves a rung can be BOTH reached
     * AND not current. The fixture is re-aged to day 15 instead, one day past the new first rung,
     * so the three-way distinction (Passed / not-Current / Ahead) is still exercised.
     */
    @isTest
    static void whilePausedNoRungIsCurrentAndTheUnreachedOnesSayTheClockIsPaused() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(dayN(60), 1, dayN(45));

        Assert.areEqual(15, t.daysOnMarket, 'Paused at day 15 — one day past the week-2 rung');
        for (DispositionTractionService.Rung r : t.rungs) {
            Assert.isFalse(r.isCurrent,
                r.key + ' must not be Current while the clock is paused - nothing is escalating');
        }
        Assert.areEqual('Passed', rung(t, 'WEEK_2').state,
            'Week 2 was genuinely reached before the offer arrived, so it still reads Passed');
        Assert.areEqual('Passed before the clock paused.', rung(t, 'WEEK_2').note,
            'And the note explains why it is Passed but not Current');
        Assert.areEqual('Ahead', rung(t, 'WEEK_4').state, 'Week 4 was never reached');
        Assert.areEqual('Clock paused.', rung(t, 'WEEK_4').note,
            'An unreached rung must NOT count down while paused - "In 18 days." would be a lie');
    }

    /**
     * An offer dated in the FUTURE does not run the clock forward past today. Without the
     * `min(today, firstOfferDate)` clamp the listing would report more days on market than have
     * actually elapsed.
     */
    @isTest
    static void aFutureDatedOfferPausesAtTodayAndNeverRunsTheClockForward() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(dayN(10), 1, Date.today().addDays(30));

        Assert.areEqual(10, t.daysOnMarket,
            'The clock stops at today, never at a date that has not happened');
        Assert.isTrue(t.isPaused, 'It is still paused - forward from here it does not move');
    }

    /**
     * 🔴 A DATE WITH NO OFFER BEHIND IT IS NOT A PAUSE. `evaluate` normalises it away, so a caller
     * that hands over a stale date from a deleted offer cannot silently freeze a listing that has
     * nothing in negotiation. This is also the accepted "deleting the last offer un-pauses and the
     * level jumps" behaviour, expressed as a unit: zero offers escalates, whatever date is passed.
     */
    @isTest
    static void aFirstOfferDateWithZeroOffersIsIgnoredAndTheListingStillEscalates() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(dayN(50), 0, dayN(10));

        Assert.areEqual(DispositionTractionService.Band.WEEK_6.name(), t.band,
            'No offers means the clock runs, whatever date is handed over');
        Assert.isFalse(t.isPaused, 'Nothing is paused when nothing is in negotiation');
        Assert.isNull(t.firstOfferDate, 'The orphan date is normalised away, not republished');
        Assert.areEqual(50, t.daysOnMarket, 'The clock reads the real elapsed time');
    }

    /**
     * SUPPRESSED BUT NOT PAUSED — the undated-offer case. `MIN` ignores nulls, so this state is
     * reachable in production the moment someone logs an offer without a date. The band must still
     * be On Track (an offer is traction) while the panel says plainly that the clock is running.
     */
    @isTest
    static void anUndatedOfferSuppressesTheLevelButSaysTheClockIsStillRunning() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(dayN(50), 1, null);

        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'An offer is traction whether or not it carries a date (D28/Q1)');
        Assert.isFalse(t.isPaused, 'There is no date to pause at');
        Assert.isTrue(t.detail.contains('no offer carries an offer date'),
            'The panel must explain why the clock is still moving: ' + t.detail);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE OFFERS-ONLY RULE (D28/Q1) — unchanged by the 2026-08-21 revision
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE RETIRED LADDER IGNORED OFFERS ENTIRELY, so a listing with five offers at day 42 was
     * labelled "Hard Stop". Under D28/Q1 an offer IS traction, so it short-circuits every
     * threshold. If this test is ever "simplified" away, the feature reverts to prompting a broker
     * change on listings that are actively in negotiation.
     *
     * 🔴 RE-AGED 2026-09-02 (decision A2): the day list was `{ 7, 28, 42, 400 }` and the 7 became
     * VACUOUS rather than failing, which is why the validate did not catch it and why this comment
     * exists. Day 7 with one offer reads `ON_TRACK` whether or not the offer branch exists — under
     * 14/28/42 it is below every rung, so the row asserted nothing about suppression at all. Day 14
     * WOULD read `WEEK_2` without the short-circuit, so it is a real falsifier again. ⚠ THE DAYS IN
     * THIS LIST MUST BE THE THRESHOLDS THEMSELVES; a day between rungs silently stops testing the
     * thing the method is named for.
     */
    @isTest
    static void oneOfferSuppressesEveryRungAtEveryThreshold() {
        for (Integer day : new List<Integer>{ 14, 28, 42, 400 }) {
            DispositionTractionService.Traction t = atDay(day, 1);
            Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
                'Day ' + day + ' with one offer must be On Track - an offer is traction');
            Assert.isFalse(t.isAtRisk, 'Day ' + day + ' with one offer must not be at risk');
            Assert.areEqual('On Track', t.listingStatusValue,
                'Day ' + day + ' with one offer maps to On Track');
        }
    }

    /** The same day, the same clock, opposite verdicts — the offer count is the only difference. */
    @isTest
    static void theOnlyDifferenceAtDayThirtyFiveIsTheOfferCount() {
        DispositionTractionService.Traction noOffers = atDay(35, 0);
        DispositionTractionService.Traction oneOffer = atDay(35, 1);

        Assert.areEqual(DispositionTractionService.Band.WEEK_4.name(), noOffers.band,
            'Zero offers at day 35 sits on the week-4 rung');
        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), oneOffer.band,
            'One offer at day 35 does not');
        Assert.areEqual(noOffers.daysOnMarket, oneOffer.daysOnMarket,
            'With no offer DATE supplied the clock itself is identical in both cases');
    }

    /** Singular/plural is the one piece of prose worth pinning — it appears in the panel. */
    @isTest
    static void offerWordingIsSingularForOneAndPluralOtherwise() {
        Assert.isTrue(atDay(35, 1).detail.contains('1 offer '),
            'One offer must read "1 offer": ' + atDay(35, 1).detail);
        Assert.isTrue(atDay(35, 2).detail.contains('2 offers'),
            'Two offers must read "2 offers": ' + atDay(35, 2).detail);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // listingStatusValue — the seam a future stamping job writes through
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE THREE VALUES ARE THE WHOLE RESTRICTED VALUE SET OF `Broker_Listing__c.Listing_Status__c`
     * (measured in the field file). This test is what proves the mapping needs NO new picklist
     * value — which matters more after 2026-08-21, not less: the ladder now has FOUR levels against
     * three values, and the user's instruction for that change was to create or modify no field.
     * `WEEK_2 => On Track` is the deliberate collapse. See `listingStatusValue`'s javadoc.
     */
    @isTest
    static void everyBandMapsToAnExistingListingStatusValue() {
        Map<DispositionTractionService.Band, String> expected =
            new Map<DispositionTractionService.Band, String>{
                DispositionTractionService.Band.NOT_LISTED => 'On Track',
                DispositionTractionService.Band.ON_TRACK => 'On Track',
                DispositionTractionService.Band.WEEK_2 => 'On Track',
                DispositionTractionService.Band.WEEK_4 => 'At Risk',
                DispositionTractionService.Band.WEEK_6 => 'Hard Stop'
            };
        Set<String> allowed = new Set<String>{ 'On Track', 'At Risk', 'Hard Stop' };

        for (DispositionTractionService.Band b : DispositionTractionService.Band.values()) {
            String actual = DispositionTractionService.listingStatusValue(b);
            Assert.isTrue(allowed.contains(actual),
                b + ' maps to "' + actual + '", which is not a Listing_Status__c value');
            Assert.areEqual(expected.get(b), actual, b + ' must map to ' + expected.get(b));
        }
        Assert.areEqual(5, DispositionTractionService.Band.values().size(),
            'A new Band was added without deciding what Listing_Status__c value it maps to');
    }

    /**
     * The stored value and the computed flag must agree on every band. Two rules would let the
     * dashboard tile and the card contradict each other the day a job starts stamping.
     *
     * ⚠ 13 AND 14 ADDED 2026-09-02 (decision A2). This walk asserts an INVARIANT, so it held at
     * every day under both ladders and did not fail — but its day sample was chosen to straddle
     * 7/28/42, and after the move it no longer touched the first rung's boundary at all. Day 7 is
     * KEPT rather than replaced: it is still a real day, it is now `ON_TRACK`, and the invariant
     * must hold there too.
     */
    @isTest
    static void theStoredStatusAndTheAtRiskFlagNeverDisagree() {
        for (Integer day : new List<Integer>{ 0, 7, 13, 14, 27, 28, 41, 42, 400 }) {
            DispositionTractionService.Traction t = atDay(day, 0);
            Boolean storedSaysRisk = (t.listingStatusValue != 'On Track');
            Assert.areEqual(storedSaysRisk, t.isAtRisk,
                'Day ' + day + ': listingStatusValue "' + t.listingStatusValue
                + '" disagrees with isAtRisk ' + t.isAtRisk);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // evaluateAll — the orchestrating half
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void evaluateAllIsNullAndEmptySafe() {
        Assert.areEqual(0, DispositionTractionService.evaluateAll(null).size(),
            'A null input returns an empty map, never a NullPointerException');
        Assert.areEqual(0, DispositionTractionService.evaluateAll(new Set<Id>()).size(),
            'An empty input returns an empty map');
    }

    @isTest
    static void evaluateAllReadsTheListingDateAndCountsRealOffers() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c withOffers = TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        Disposition__c withoutOffers = TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        // ⚠ The factory seeds Listing_Date__c = TODAY on every fixture, so an aged clock has to be
        // set deliberately. Without this both rows would read day 0 and the bands would be
        // identical for a reason that has nothing to do with offers.
        withOffers.Listing_Date__c = Date.today().addDays(-45);
        withoutOffers.Listing_Date__c = Date.today().addDays(-45);
        insert new List<Disposition__c>{ withOffers, withoutOffers };
        TestDataFactory.createDispositionOffers(2, withOffers.Id, true);

        Test.startTest();
        Map<Id, DispositionTractionService.Traction> byId =
            DispositionTractionService.evaluateAll(
                new Set<Id>{ withOffers.Id, withoutOffers.Id });
        Test.stopTest();

        Assert.areEqual(2, byId.size(), 'Both dispositions must resolve');
        Assert.areEqual(2, byId.get(withOffers.Id).offerCount,
            'The offer count must come from the real Disposition_Offer__c children');
        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(),
            byId.get(withOffers.Id).band,
            'Day 45 WITH offers is On Track');
        Assert.areEqual(0, byId.get(withoutOffers.Id).offerCount,
            'A disposition absent from the GROUP BY result must default to 0, not null');
        Assert.areEqual(DispositionTractionService.Band.WEEK_6.name(),
            byId.get(withoutOffers.Id).band,
            'Day 45 with NO offers is past the six-week period');
    }

    /**
     * 🔴 THE PAUSE, END TO END THROUGH THE SELECTOR. The unit tests above hand `evaluate` a date;
     * this one proves the date actually arrives from the aggregate — i.e. that `MIN(Offer_Date__c)`
     * is wired through `selectOfferTractionByDispositionIds` and not quietly dropped.
     *
     * ⚠ THE OFFERS ARE BACK-DATED EXPLICITLY. `TestDataFactory.createDispositionOffers` dates every
     * offer TODAY, which would pause the clock at today — indistinguishable from no pause at all,
     * and this test would pass while proving nothing.
     */
    @isTest
    static void evaluateAllPausesTheClockAtTheEarliestRealOfferDate() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c d = TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Listing_Date__c = Date.today().addDays(-60);
        insert d;

        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(3, d.Id, false);
        offers[0].Offer_Date__c = Date.today().addDays(-20); // the earliest — the pause point
        offers[1].Offer_Date__c = Date.today().addDays(-5);
        offers[2].Offer_Date__c = Date.today();
        insert offers;

        Test.startTest();
        Map<Id, DispositionTractionService.Traction> byId =
            DispositionTractionService.evaluateAll(new Set<Id>{ d.Id });
        Test.stopTest();

        DispositionTractionService.Traction t = byId.get(d.Id);
        Assert.areEqual(3, t.offerCount, 'All three offers are counted');
        Assert.isTrue(t.isPaused, 'A dated offer pauses the clock');
        Assert.areEqual(Date.today().addDays(-20), t.firstOfferDate,
            'MIN() must pick the EARLIEST offer date, not the latest and not the first inserted');
        Assert.areEqual(40, t.daysOnMarket,
            'Listed 60 days ago, first offer 20 days ago: the clock stopped at day 40');
        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'And the paused listing does not escalate');
    }

    /**
     * The undated-offer state, end to end. `MIN` returns null when every offer is undated, so the
     * listing is suppressed but not paused — and this is the test that would catch a future
     * `firstOfferDate == null ? Date.today() : ...` "tidy-up" in the selector, which would silently
     * pause every such listing at today.
     */
    @isTest
    static void evaluateAllReportsNoPauseWhenEveryOfferIsUndated() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c d = TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, false);
        d.Listing_Date__c = Date.today().addDays(-50);
        insert d;

        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(2, d.Id, false);
        offers[0].Offer_Date__c = null;
        offers[1].Offer_Date__c = null;
        insert offers;

        Test.startTest();
        Map<Id, DispositionTractionService.Traction> byId =
            DispositionTractionService.evaluateAll(new Set<Id>{ d.Id });
        Test.stopTest();

        DispositionTractionService.Traction t = byId.get(d.Id);
        Assert.areEqual(2, t.offerCount, 'Undated offers still count as offers');
        Assert.isFalse(t.isPaused, 'MIN over nulls is null, so there is nothing to pause at');
        Assert.isNull(t.firstOfferDate, 'And no date is invented');
        Assert.areEqual(50, t.daysOnMarket, 'The clock is still running');
        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'The level is still suppressed - an offer is traction either way');
    }

    @isTest
    static void evaluateAllOmitsAnIdThatResolvesToNoRow() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        Disposition__c real = TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        Id deleted = real.Id;
        delete real;

        Map<Id, DispositionTractionService.Traction> byId =
            DispositionTractionService.evaluateAll(new Set<Id>{ deleted });

        Assert.areEqual(0, byId.size(),
            'An Id that resolves to no readable row is absent, so a caller must handle a miss');
    }

    /**
     * 🔴 THE BUDGET ASSERTION, AND IT IS THE SECOND-HIGHEST-VALUE TEST IN THIS CLASS. 2 SOQL for 251
     * dispositions is the property that makes `evaluateAll` safe to call from a future Schedulable.
     * A future change that added one query per disposition would still produce correct bands and
     * would fail HERE rather than in production.
     *
     * ⚠ IT IS ALSO WHAT KEPT THE PAUSE HONEST. The obvious way to add a first-offer date was a
     * second selector method — which would have made this 3 and failed here. The count and the MIN
     * come back from ONE aggregate because of this assertion.
     *
     * ⚠ Counters are snapshotted around the call INSIDE the test transaction, not read after
     * `Test.stopTest()` — stopTest restores the pre-test limit counters, which makes the obvious
     * assertion silently vacuous (the `ExtractAddressQueueable.lastRunQueryCount` precedent).
     *
     * ⚠ The fixtures sit at `Disposition Readiness`, deliberately: creating them at
     * `Active Listing` would fire DispositionStageEntryService's auto-create and put its query and
     * DML inside the very window this test is measuring.
     */
    @isTest
    static void evaluateAllAt251IsTwoQueriesRegardlessOfCount() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        Set<Id> ids = new Map<Id, Disposition__c>(dispositions).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        Map<Id, DispositionTractionService.Traction> byId =
            DispositionTractionService.evaluateAll(ids);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N, byId.size(), 'All ' + BULK_N + ' dispositions must be evaluated');
        Assert.areEqual(2, queriesUsed,
            'evaluateAll must cost exactly 2 SOQL for ANY number of dispositions - one for the '
            + 'listing clocks and ONE aggregate carrying both the offer count and the first offer '
            + 'date');
        Assert.areEqual(0, dmlUsed, 'evaluateAll is read-only and must issue no DML');
    }
}
