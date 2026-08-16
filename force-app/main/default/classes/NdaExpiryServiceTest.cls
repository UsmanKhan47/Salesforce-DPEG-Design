/**
 * Tests for `NdaExpiryService` — the pure NDA expiry ladder and the pure idempotency rule.
 *
 * ── WHY THIS CLASS NEEDS NO FIXTURES AND NO CLOCK HACK ──────────────────────
 * Every method under test is PURE: no SOQL, no DML, and the clock is an argument. So every band
 * and every rung is reachable by passing two Dates, and no test here inserts a record or freezes a
 * clock. That property is the reason the ladder lives in a service rather than inside the batch,
 * and `.claude/rules/bulk-test-rule.md`'s 251-record mandate has nothing to bite on here — there is
 * no DML, no trigger, no batch and no queueable in this class. The mandate is met, with no
 * exemption claimed, in `NdaExpiryAlertBatchTest` and `NdaSelectorTest`, which is where the volume
 * actually exists.
 *
 * 🔴 THE TWO TESTS THAT MATTER MOST ARE `everyRungOfTheLadderMapsToExactlyOneBand` (the only thing
 * coupling the three independently-declared constants) and the `shouldFire` re-arm pair (the
 * falsifier for dropping `NDA_Alert_Expiry_Date__c`, whose absence is silent and permanent).
 */
@isTest
private class NdaExpiryServiceTest {

    /** A fixed clock. Nothing here reads `Date.today()` except the tests that exist to prove it. */
    private static final Date TODAY = Date.newInstance(2026, 8, 16);

    private static NdaExpiryService.NdaExpiry at(Integer daysOut) {
        return NdaExpiryService.evaluate(TODAY.addDays(daysOut), TODAY);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // THE BANDS
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void noExpiryDateIsItsOwnStateAndIsNotUrgent() {
        // RETURN EARLY, and the reason: collapsing "no expiry" into "expires today" or "expired" is
        // how a non-expiring NDA ends up in a reminder queue it has no business being in.
        NdaExpiryService.NdaExpiry state = NdaExpiryService.evaluate(null, TODAY);

        Assert.areEqual(NdaExpiryService.Urgency.NO_EXPIRY_DATE.name(), state.urgency,
            'No expiry date is NOT "expired" and NOT "expires today"');
        Assert.isFalse(state.hasExpiryDate, 'and the caller can tell that apart from "0 days"');
        Assert.isFalse(state.isUrgent, 'so nothing is painted red');
        Assert.isNull(state.dueInterval, 'and no rung fires');
        Assert.isNull(state.daysRemaining, 'days remaining is null, not zero');
    }

    /**
     * 🔴 THE TEST THAT COUPLES THE THREE CONSTANTS. `ALERT_INTERVALS` ({5, 2}), `CRITICAL_DAYS` (2)
     * and `APPROACHING_DAYS` (5) are declared SEPARATELY and merely happen to agree — nothing in
     * the code derives one from another, so editing the ladder alone compiles and silently
     * decouples any future badge from the bell. This walk over every boundary day is what holds
     * them together, and it is the thing that must stay green if any of the three moves.
     */
    @isTest
    static void everyRungOfTheLadderMapsToExactlyOneBand() {
        // ── outside the ladder ──
        Assert.areEqual(NdaExpiryService.Urgency.SCHEDULED.name(), at(6).urgency, '6 days out');
        Assert.isNull(at(6).dueInterval, 'and 6 days out is outside the ladder — no rung');

        // ── the 5 rung ──
        Assert.areEqual(NdaExpiryService.Urgency.APPROACHING.name(), at(5).urgency, '5 days out');
        Assert.areEqual(5, at(5).dueInterval, 'sits in the 5 rung');
        Assert.isFalse(at(5).isUrgent,
            'but is AMBER, not red — the reminded population is deliberately WIDER than the '
            + 'urgent one, exactly as CallForOffersService §2 records for its own top rung');
        Assert.areEqual(5, at(3).dueInterval, '3 days out is still the 5 rung');
        Assert.areEqual(NdaExpiryService.Urgency.APPROACHING.name(), at(3).urgency, '3 days out');

        // ── the 2 rung ──
        Assert.areEqual(NdaExpiryService.Urgency.CRITICAL.name(), at(2).urgency, '2 days out');
        Assert.areEqual(2, at(2).dueInterval, 'drops to the 2 rung');
        Assert.isTrue(at(2).isUrgent, 'and is urgent from here on');
        Assert.areEqual(2, at(1).dueInterval, '1 day out is still the 2 rung');

        // ── today, and past it ──
        Assert.areEqual(NdaExpiryService.Urgency.EXPIRES_TODAY.name(), at(0).urgency, 'today');
        Assert.areEqual(2, at(0).dueInterval,
            '🔴 today sits in the 2 rung, because the ladder has NO 0 rung — that is a product '
            + 'decision (the FSD asks for two reminders, not three), not an omission');
        Assert.areEqual(NdaExpiryService.Urgency.EXPIRED.name(), at(-1).urgency, 'yesterday');
        Assert.areEqual(2, at(-1).dueInterval,
            'an already-expired NDA still sits in the smallest rung, so one CATCH-UP reminder is '
            + 'owed and — the marker being monotone — exactly one');
        Assert.isTrue(at(-1).isUrgent, 'and it is urgent');
    }

    @isTest
    static void daysRemainingGoesNegativeOnceExpired() {
        Assert.areEqual(4, at(4).daysRemaining, 'Whole days ahead');
        Assert.areEqual(0, at(0).daysRemaining, 'Zero on the day itself');
        Assert.areEqual(-3, at(-3).daysRemaining,
            'and NEGATIVE past it — a caller must be able to tell "expired" from "expires today"');
    }

    @isTest
    static void labelsAndDetailsAreSingularAndPluralCorrectly() {
        // Small, but this text goes into a notification title a human reads at 7am.
        Assert.areEqual('Expires in 1 day', at(1).label, 'singular at one day');
        Assert.areEqual('Expires in 2 days', at(2).label, 'plural at two');
        Assert.areEqual('Expires today', at(0).label, 'today is its own wording');
        Assert.areEqual('Expired 1 day ago', at(-1).label, 'singular in the past too');
        Assert.areEqual('Expired 3 days ago', at(-3).label, 'and plural');
    }

    @isTest
    static void dateFormattingIsFixedAndNotLocaleDependent() {
        // ⚠ DELIBERATELY NOT DateTime.format. That renders in the RUNNING USER's locale and time
        // zone, so the same expiry reads differently for two people and any assertion on it is
        // silently machine-dependent — green here, red on a CI box with another default locale.
        Assert.areEqual('Aug 16, 2026', NdaExpiryService.formatDate(TODAY),
            'One fixed format, so a future badge and the notification body cannot disagree');
        Assert.areEqual('—', NdaExpiryService.formatDate(null), 'and null renders as an em dash');
        Assert.isTrue(at(2).detail.contains('Aug 18, 2026'),
            'the detail sentence carries the real expiry date, not a relative phrase');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PURITY
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void evaluateReadsNoClockWhenGivenOneAndNoDatabaseEver() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        NdaExpiryService.evaluate(TODAY.addDays(3), TODAY);
        NdaExpiryService.shouldFire(5, null, TODAY, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(0, queriesUsed, 'The ladder never queries');
        Assert.areEqual(0, dmlUsed, 'and never writes — the marker stamp belongs to the batch');
        // The clock-as-argument property, asserted rather than described: the same expiry read
        // against two different "todays" must give two different answers, which is exactly what a
        // batch chunk needs so two NDAs cannot straddle midnight.
        Date expiry = TODAY.addDays(3);
        Assert.areEqual(3, NdaExpiryService.evaluate(expiry, TODAY).daysRemaining, 'as of today');
        Assert.areEqual(1, NdaExpiryService.evaluate(expiry, TODAY.addDays(2)).daysRemaining,
            'and as of two days later — the clock is an ARGUMENT, not a read');
    }

    @isTest
    static void aNullAsOfFallsBackToTodayRatherThanThrowing() {
        // The one deliberate impurity inside evaluate(Date, Date), pinned so it stays deliberate:
        // a careless caller must get today's answer, not a NullPointerException inside a batch
        // chunk that would then take the whole chunk's fail-soft catch.
        NdaExpiryService.NdaExpiry state = NdaExpiryService.evaluate(Date.today().addDays(2), null);
        Assert.areEqual(2, state.daysRemaining, 'A null asOf is treated as today');
        Assert.areEqual(2, state.dueInterval, 'and lands in the right rung');
    }

    @isTest
    static void theSingleArgumentOverloadSuppliesTodaysClock() {
        NdaExpiryService.NdaExpiry state = NdaExpiryService.evaluate(Date.today().addDays(4));
        Assert.areEqual(4, state.daysRemaining, 'evaluate(Date) counts from today');
        Assert.areEqual(5, state.dueInterval, 'and places the rung accordingly');
    }

    @isTest
    static void intervalForIsNullSafe() {
        Assert.isNull(NdaExpiryService.intervalFor(null),
            'A null countdown has no rung — reachable whenever there is no expiry date');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 🔴 shouldFire — THE IDEMPOTENCY RULE
    // ═══════════════════════════════════════════════════════════════════════

    @isTest
    static void aNeverRemindedNdaInsideTheLadderFires() {
        Assert.isTrue(NdaExpiryService.shouldFire(5, null, TODAY.addDays(5), null),
            'No marker at all means nothing has fired yet');
    }

    @isTest
    static void anNdaOutsideTheLadderNeverFires() {
        Assert.isFalse(NdaExpiryService.shouldFire(null, null, TODAY.addDays(30), null),
            'A null rung means the NDA is outside the ladder — 30 days out is not "in the 5-day '
            + 'window"');
    }

    @isTest
    static void theSameRungNeverFiresTwice() {
        Date expiry = TODAY.addDays(5);
        Assert.isFalse(NdaExpiryService.shouldFire(5, 5, expiry, expiry),
            'STRICTLY smaller, not smaller-or-equal — otherwise the team gets the same reminder '
            + 'every day and stops reading them');
    }

    @isTest
    static void aSmallerRungFiresOverALargerMarker() {
        Date expiry = TODAY.addDays(2);
        Assert.isTrue(NdaExpiryService.shouldFire(2, 5, expiry, expiry),
            'The 2 rung fires after the 5 rung has been stamped');
    }

    @isTest
    static void aMissedDayCatchesUpRatherThanSkippingARungForever() {
        // The monotone property, and the reason the cadence is a quality-of-service choice rather
        // than a correctness one: if the job does not run for three days, the NDA does not lose its
        // reminder — the next pass fires the rung it is now in.
        Date expiry = TODAY.addDays(1);
        Assert.isTrue(NdaExpiryService.shouldFire(2, null, expiry, null),
            'An NDA that jumped from 6 days out to 1 day out still gets the 2 rung');
    }

    @isTest
    static void anExpiredNdaDoesNotSpamOnceItsRungIsStamped() {
        Date expiry = TODAY.addDays(-10);
        Assert.isFalse(NdaExpiryService.shouldFire(2, 2, expiry, expiry),
            'Past the expiry the rung is 2 forever, so once 2 is stamped the strictly-smaller test '
            + 'can never pass again — the locator deliberately has NO floor and relies on this');
    }

    /**
     * 🔴 THE FALSIFIER FOR DROPPING `NDA_Alert_Expiry_Date__c`. Without the snapshot this assertion
     * is FALSE and the failure is silent AND permanent: the countdown restarts, the rung goes back
     * UP, the strictly-smaller test can never pass again, and the NDA is never reminded about
     * again — on exactly the NDAs someone cared enough about to extend.
     */
    @isTest
    static void extendingTheExpiryReArmsTheWholeLadder() {
        Date originalExpiry = TODAY.addDays(2);
        Date extendedExpiry = TODAY.addDays(45);

        // Marker says "rung 2 already fired, against the ORIGINAL expiry".
        Assert.isFalse(NdaExpiryService.shouldFire(2, 2, originalExpiry, originalExpiry),
            'baseline: with the expiry unchanged, rung 2 does not fire twice');

        // Now the expiry moves out and the countdown re-enters the 5 rung 40 days later.
        Assert.isTrue(
            NdaExpiryService.shouldFire(5, 2, extendedExpiry, originalExpiry),
            '🔴 An expiry that MOVED re-arms everything: the marker is measured against a date '
            + 'that no longer exists, so it is treated as blank. Delete the snapshot field and '
            + 'this NDA is never reminded about again, silently');
    }

    @isTest
    static void aStampedIntervalWithNoSnapshotAlsoReArms() {
        // The anomalous shape — an interval stamped with no snapshot, which a partial data fix or
        // a hand edit can produce. It deliberately RE-ARMS: an extra reminder is recoverable, a
        // permanently silent NDA is not.
        Assert.isTrue(NdaExpiryService.shouldFire(2, 2, TODAY.addDays(1), null),
            'A marker with no snapshot is treated as blank and fires again');
    }
}
