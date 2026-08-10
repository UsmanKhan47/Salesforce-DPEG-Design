/**
 * @description Tests DispositionTractionService — the Active Listing traction monitor
 * (decisions D27.1 / D28-Q1 / D28-Q2, Tranche 5 Item B).
 *
 * ── 🔴 THIS SUITE IS THE PERMANENT FALSIFIER FOR THE 60/30 CLOCK ────────────
 * The clock it replaced (21/28/42 days) was pinned by three files and was WRONG in all three. The
 * whole point of moving the ladder into one pure function is that there is now exactly one place
 * to change it and exactly one suite that goes red when it changes. Every boundary below is
 * asserted on BOTH sides — 29/30, 39/40, 59/60 — because an off-by-one in a threshold is the
 * defect a "does it roughly work" test cannot see.
 *
 * ── WHY THE BOUNDARY TESTS DRIVE `evaluate` DIRECTLY ────────────────────────
 * `evaluate(Date, Integer)` takes the listing date and the offer count as ARGUMENTS and calls
 * `Date.today()` exactly once against them. That is what makes every band reachable without
 * seeding aged data, without `Test.setCreatedDate`, and without a clock fixture — and it is why
 * the pure/orchestrating split exists at all rather than one method doing both.
 *
 * ── WHAT THIS SUITE DELIBERATELY DOES NOT DO ───────────────────────────────
 * It does not assert exact label prose word-for-word beyond the parts that carry MEANING (the day
 * number, the band, the offer count). Pinning marketing copy makes a suite red for a typo fix; the
 * LWC suite asserts that whatever the server sends is what renders.
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
        Assert.isNull(t.checkpointDate, 'No listing date means no derivable checkpoint date');
        Assert.isNull(t.hardStopDate, 'No listing date means no derivable hard-stop date');
        Assert.areEqual('On Track', t.listingStatusValue,
            'NOT_LISTED maps to On Track - nothing is wrong yet');
    }

    /** A blank date with offers on it is still NOT_LISTED — the date is what starts the clock. */
    @isTest
    static void blankListingDateWithOffersIsStillNotListed() {
        DispositionTractionService.Traction t =
            DispositionTractionService.evaluate(null, 4);

        Assert.areEqual(DispositionTractionService.Band.NOT_LISTED.name(), t.band,
            'Offers do not start the marketing clock; a listing date does');
        Assert.areEqual(4, t.offerCount, 'The count still passes through');
    }

    /** A null count is 0, never a NullPointerException from an @AuraEnabled boundary. */
    @isTest
    static void nullOfferCountIsTreatedAsZero() {
        DispositionTractionService.Traction t = DispositionTractionService.evaluate(dayN(35), null);

        Assert.areEqual(0, t.offerCount, 'A null offer count must normalise to 0');
        Assert.areEqual(DispositionTractionService.Band.CHECKPOINT_DUE.name(), t.band,
            'A null count must behave like zero offers, i.e. fire the checkpoint');
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
        Assert.areEqual(60, t.daysRemaining, 'A 60-day period with 0 elapsed leaves 60');
    }

    /** BOUNDARY 1, LOW SIDE. Day 29 is the last On Track day. */
    @isTest
    static void dayTwentyNineIsStillOnTrack() {
        DispositionTractionService.Traction t = atDay(29, 0);

        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), t.band,
            'Day 29 is inside month one, so the checkpoint has not fired');
        Assert.isFalse(t.isAtRisk, 'Day 29 must not be flagged');
    }

    /** BOUNDARY 1, HIGH SIDE. Day 30 is the document's own month-1 traction check. */
    @isTest
    static void dayThirtyFiresTheCheckpoint() {
        DispositionTractionService.Traction t = atDay(30, 0);

        Assert.areEqual(DispositionTractionService.Band.CHECKPOINT_DUE.name(), t.band,
            'Day 30 with zero offers is the checkpoint the document names');
        Assert.isTrue(t.isAtRisk, 'CHECKPOINT_DUE is an at-risk state');
        Assert.areEqual('At Risk', t.listingStatusValue,
            'CHECKPOINT_DUE maps to the At Risk picklist value');
        Assert.isTrue(t.label.contains('30'), 'The badge must name the day: ' + t.label);
    }

    /** BOUNDARY 2, LOW SIDE. */
    @isTest
    static void dayThirtyNineIsStillTheCheckpointBand() {
        Assert.areEqual(DispositionTractionService.Band.CHECKPOINT_DUE.name(), atDay(39, 0).band,
            'Day 39 has not reached the two-thirds marker');
    }

    /**
     * BOUNDARY 2, HIGH SIDE. Day 40 is ⅔ of 60 — the derived successor to the retired ladder's
     * day-28 rung, which was ⅔ of 42. It is the ONLY threshold in this class the document does not
     * state, which is why its derivation is written down rather than assumed.
     */
    @isTest
    static void dayFortyIsReviewOverdue() {
        DispositionTractionService.Traction t = atDay(40, 0);

        Assert.areEqual(DispositionTractionService.Band.REVIEW_OVERDUE.name(), t.band,
            'Day 40 is two-thirds of the 60-day clock, the successor to the old day-28 rung');
        Assert.isTrue(t.isAtRisk, 'REVIEW_OVERDUE is an at-risk state');
        Assert.areEqual('At Risk', t.listingStatusValue,
            'REVIEW_OVERDUE also maps to At Risk - there is no fourth picklist value and none was added');
        Assert.areEqual(20, t.daysRemaining, 'Day 40 of 60 leaves 20');
    }

    /** BOUNDARY 3, LOW SIDE. */
    @isTest
    static void dayFiftyNineIsStillReviewOverdue() {
        Assert.areEqual(DispositionTractionService.Band.REVIEW_OVERDUE.name(), atDay(59, 0).band,
            'Day 59 has not yet elapsed the marketing period');
    }

    /** BOUNDARY 3, HIGH SIDE. Day 60 is the document's "about two months". */
    @isTest
    static void daySixtyIsHardStop() {
        DispositionTractionService.Traction t = atDay(60, 0);

        Assert.areEqual(DispositionTractionService.Band.HARD_STOP.name(), t.band,
            'Day 60 with zero offers is the end of the marketing period');
        Assert.isTrue(t.isAtRisk, 'HARD_STOP is an at-risk state');
        Assert.areEqual('Hard Stop', t.listingStatusValue,
            'HARD_STOP maps to the Hard Stop picklist value');
        Assert.areEqual(0, t.daysRemaining, 'Nothing remains once the period has elapsed');
    }

    /** Well past the period: still HARD_STOP, and daysRemaining never goes negative. */
    @isTest
    static void wellPastTheHardStopStaysHardStopAndClampsDaysRemaining() {
        DispositionTractionService.Traction t = atDay(400, 0);

        Assert.areEqual(DispositionTractionService.Band.HARD_STOP.name(), t.band,
            'There is no band beyond Hard Stop');
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
        Assert.areEqual(60, t.daysRemaining, 'daysRemaining cannot exceed the marketing period');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 🔴 THE OFFERS-ONLY RULE (D28/Q1) — the substantive behaviour change
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE RETIRED LADDER IGNORED OFFERS ENTIRELY, so a listing with five offers at day 42 was
     * labelled "Week 6 - Hard Stop". Under D28/Q1 an offer IS traction, so it short-circuits every
     * threshold. If this test is ever "simplified" away, the feature reverts to prompting a broker
     * change on listings that are actively in negotiation.
     */
    @isTest
    static void oneOfferSuppressesTheCheckpointAtEveryThreshold() {
        for (Integer day : new List<Integer>{ 30, 40, 60, 400 }) {
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

        Assert.areEqual(DispositionTractionService.Band.CHECKPOINT_DUE.name(), noOffers.band,
            'Zero offers at day 35 fires the checkpoint');
        Assert.areEqual(DispositionTractionService.Band.ON_TRACK.name(), oneOffer.band,
            'One offer at day 35 does not');
        Assert.areEqual(noOffers.daysOnMarket, oneOffer.daysOnMarket,
            'The clock itself is identical in both cases');
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
    // DERIVED DATES
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void checkpointAndHardStopDatesAreDerivedFromTheListingDate() {
        Date listed = Date.newInstance(2026, 3, 15);

        DispositionTractionService.Traction t = DispositionTractionService.evaluate(listed, 0);

        Assert.areEqual(listed.addDays(30), t.checkpointDate,
            'The checkpoint is 30 days after the listing date');
        Assert.areEqual(listed.addDays(60), t.hardStopDate,
            'The hard stop is 60 days after the listing date');
        Assert.areEqual(listed, t.listingDate, 'The listing date passes through verbatim');
        Assert.areEqual(60, t.marketingPeriodDays,
            'The period is surfaced so no caller hardcodes it a second time');
        Assert.areEqual(30, t.checkpointDays,
            'The checkpoint is surfaced for the same reason');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // listingStatusValue — the seam the deferred D9 job writes through
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * 🔴 THE THREE VALUES ARE THE WHOLE RESTRICTED VALUE SET OF `Broker_Listing__c.Listing_Status__c`
     * (measured in the field file). This test is what proves the mapping needs NO new picklist
     * value, which is why the standing "grep the repo and query the org before touching a picklist"
     * rule is not engaged by this feature.
     */
    @isTest
    static void everyBandMapsToAnExistingListingStatusValue() {
        Map<DispositionTractionService.Band, String> expected =
            new Map<DispositionTractionService.Band, String>{
                DispositionTractionService.Band.NOT_LISTED => 'On Track',
                DispositionTractionService.Band.ON_TRACK => 'On Track',
                DispositionTractionService.Band.CHECKPOINT_DUE => 'At Risk',
                DispositionTractionService.Band.REVIEW_OVERDUE => 'At Risk',
                DispositionTractionService.Band.HARD_STOP => 'Hard Stop'
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
        Assert.areEqual(DispositionTractionService.Band.REVIEW_OVERDUE.name(),
            byId.get(withoutOffers.Id).band,
            'Day 45 with NO offers is Review Overdue');
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
     * 🔴 THE BUDGET ASSERTION, AND IT IS THE HIGHEST-VALUE TEST IN THIS CLASS. 2 SOQL for 251
     * dispositions is the property that makes `evaluateAll` safe to call from the deferred D9
     * Schedulable. A future change that added one query per disposition would still produce correct
     * bands and would fail HERE rather than in production.
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
            + 'listing clocks and one aggregate for the offer counts');
        Assert.areEqual(0, dmlUsed, 'evaluateAll is read-only and must issue no DML');
    }
}
