/**
 * @description Test class for BrokerListingController.
 *
 * ── 🔴 REWRITTEN 2026-08-10 (Tranche 5B). WHAT CHANGED AND WHY IT HAD TO ────
 * The retired suite drove the risk ladder by SETTING `Broker_Listing__c.Days_On_Market__c` to
 * 10 / 25 / 40 / 45 and asserting `Week 3` / `Week 4` / `Week 6`. Both halves were wrong:
 *
 *   THE INPUT  — `Broker_Listing__c.Days_On_Market__c` is a hand-keyed Number that NOTHING in the
 *                application writes. Typing a value into it in a test made the ladder look
 *                exercised while proving nothing about a clock that, in production, never moved.
 *   THE LADDER — the assertions were a SECOND COPY of the thresholds, living here rather than in
 *                the service.
 *
 * ⚠ ONE HALF OF THAT 2026-08-10 REASONING IS RETRACTED (2026-08-21). It said "21/28/42 was the
 * 6-week clock D27.1 overturned" — the user has since settled the third dispute over these numbers
 * in favour of a six-week clock with rungs at weeks 1, 4 and 6 (7/28/42), overriding
 * `DPEG-Stage-by-Stage.docx`. The DURATION objection is dead; the INPUT objection and the
 * second-copy objection both stand, and they are the ones that shaped this suite. Every band
 * asserted below is asserted through the controller, and the ladder itself is proven exactly once,
 * in `DispositionTractionServiceTest`.
 *
 * The clock is now `Disposition__c.Listing_Date__c` on the PARENT, so these tests age the parent's
 * date. `Broker_Listing__c.Days_On_Market__c` is deliberately left at the factory's 0 throughout —
 * if the controller ever reads it again, the assertions below fail immediately.
 *
 * ⚠ THE FACTORY SEEDS `Listing_Date__c = Date.today()` ON EVERY DISPOSITION, so an aged clock must
 * be set explicitly. A test that forgot would read day 0 and pass for the wrong reason.
 *
 * The band LADDER itself is proven once, in DispositionTractionServiceTest. What this suite proves
 * is that the controller wires the right inputs into it and maps the result onto the DTO.
 *
 * @author Unit Testing Agent
 */
@isTest
private class BrokerListingControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
    }

    private static Disposition__c disposition() {
        return [SELECT Id, Listing_Date__c FROM Disposition__c LIMIT 1];
    }

    /** Ages the marketing clock on the parent and returns the disposition Id. */
    private static Id listedDaysAgo(Integer days) {
        Disposition__c d = disposition();
        d.Listing_Date__c = (days == null) ? null : Date.today().addDays(-days);
        update d;
        return d.Id;
    }

    @isTest
    static void testGetListing_noListings_returnsNull() {
        Disposition__c d = disposition();

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();

        Assert.isNull(row,
            'No Broker_Listing__c exists yet, so getListing returns null and the card stays empty. '
            + 'That contract is preserved on purpose: a synthesised row would claim a broker '
            + 'engagement that does not exist.');
    }

    /**
     * ⚠ THIS TEST MOVED FROM DAY 12 TO DAY 3 ON 2026-08-21, AND THAT IS THE THRESHOLD CHANGE MADE
     * VISIBLE. Under the retired 30/40/60 ladder day 12 was "inside month one, On Track"; under
     * 7/28/42 day 12 was past the week-1 check-in. The day-12 case now has its own test below
     * asserting the OPPOSITE band — deliberately, so the pair reads as a moved line rather than a
     * loosened assertion.
     *
     * ⚠ AND ON 2026-09-02 THE LINE MOVED AGAIN (user decision A2, 7 -> 14). Day 3 was inside the
     * first WEEK and is now inside the first FORTNIGHT — the assertion is unchanged and is now
     * further from the boundary, which is why this test did not need to move a second time. The
     * day-12 test below is the one that flipped, and it flipped BACK to `ON_TRACK`.
     */
    @isTest
    static void testGetListing_insideTheFirstFortnight_isOnTrack() {
        Id dispId = listedDaysAgo(3);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual(3, row.daysOnMarket,
            'Days on market is computed from the PARENT listing date, not the hand-keyed field '
            + '(which the factory left at 0)');
        Assert.areEqual('ON_TRACK', row.tractionBand, 'Day 3 with no offers is On Track');
        Assert.isFalse(row.isAtRisk, 'Day 3 is not at risk');
        Assert.isTrue(row.tractionLabel.contains('3'),
            'The badge must name the day: ' + row.tractionLabel);
    }

    /**
     * 🔴 DAY 12 HAS NOW BEEN ON BOTH SIDES OF THE FIRST RUNG AND IS KEPT AT 12 FOR EXACTLY THAT
     * REASON. Under the retired 30/40/60 ladder it was comfortably inside month one (ON_TRACK);
     * under 7/28/42 it was past the week-1 check-in (WEEK_1); under 14/28/42 — user decision A2,
     * 2026-09-02 — it is ON_TRACK again. It is the most sensitive day in this file: a threshold
     * change in EITHER direction moves a band here, which is what a boundary test is for.
     *
     * ⚠ IT WOULD HAVE BEEN EASIER TO MOVE THIS FIXTURE TO DAY 20 AND LEAVE THE `WEEK_2` ASSERTION
     * STANDING. That is the repair that hides the change: the suite would stay green, both before
     * and after the move, and nothing would record that the first rung had moved at all. The
     * assertion is INVERTED in place instead, and the rung case is asserted separately below.
     */
    @isTest
    static void testGetListing_dayTwelve_isBackInsideTheFirstRung() {
        Id dispId = listedDaysAgo(12);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('ON_TRACK', row.tractionBand,
            'Day 12 is BELOW the week-2 rung. Under the retired 7/28/42 ladder this read WEEK_1.');
        Assert.isFalse(row.isAtRisk, 'Day 12 is not at risk');
    }

    /**
     * The first rung as this controller publishes it — day 20, comfortably between the week-2 rung
     * (14) and the week-4 one (28). ⚠ ADDED 2026-09-02 with decision A2, because inverting the
     * day-12 assertion above would otherwise have left NO test in this class covering the
     * `tractionBand == 'WEEK_2'` / `isAtRisk == false` combination at all — the exact state the
     * `isAtRisk` note on `BrokerListingController.ListingRow` exists to explain.
     */
    @isTest
    static void testGetListing_pastTheWeekTwoCheckIn_isWeekTwoButNotAtRisk() {
        Id dispId = listedDaysAgo(20);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('WEEK_2', row.tractionBand,
            'Day 20 with zero offers is past the week-2 check-in');
        Assert.isFalse(row.isAtRisk,
            'The week-2 check-in must NOT drive the amber styling - it is a prompt, not a risk');
        Assert.isTrue(row.tractionLabel.contains('Week 2'),
            'The badge must name the week: ' + row.tractionLabel);
    }

    @isTest
    static void testGetListing_pastTheFourWeekMark_isAtRisk() {
        Id dispId = listedDaysAgo(34);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('WEEK_4', row.tractionBand,
            'Day 34 with zero offers is past the four-week mark');
        Assert.isTrue(row.isAtRisk, 'The week-4 band drives the amber styling');
        Assert.areEqual('Week 4 — At Risk', row.tractionLabel,
            'The badge beside the listing facts carries the label the user specified verbatim');
        Assert.isNotNull(row.tractionDetail, 'The badge tooltip copy must be populated');
    }

    @isTest
    static void testGetListing_pastTheSixWeekPeriod_isHardStop() {
        Id dispId = listedDaysAgo(65);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('WEEK_6', row.tractionBand,
            'Day 65 with zero offers is past the six-week marketing period');
        Assert.isTrue(row.isAtRisk, 'Hard Stop is an at-risk state');
        Assert.areEqual(65, row.daysOnMarket, 'The elapsed count is not clamped');
    }

    /**
     * 🔴 THE OFFERS-ONLY RULE, AT THE CONTROLLER BOUNDARY (D28/Q1). The retired ladder had no
     * offers branch at all, so this exact record would have been labelled "Week 6 — Hard Stop"
     * while three buyers were in negotiation.
     *
     * ⚠ A THIRD ASSERTION WAS DELETED HERE ON 2026-08-21, NOT WEAKENED. It read
     * `Assert.areEqual(3, row.offersReceived, ...)` and it can no longer be written: the UAT pass
     * removed the "Offers Received" tile from `lwc/brokerListing` and `offersReceived` from the DTO
     * with it. What that assertion actually PROVED — that the controller counts the real
     * `Disposition_Offer__c` children rather than the hand-keyed
     * `Broker_Listing__c.Offers_Received__c` (which the factory leaves at 0) — is still proven by
     * the two assertions below: three real offers are the ONLY thing that can turn a day-65 listing
     * from WEEK_6 into ON_TRACK, and a count read off the hand-keyed 0 would leave it at WEEK_6.
     */
    @isTest
    static void testGetListing_offersSuppressTheRungsEvenPastTheSixWeekPeriod() {
        Id dispId = listedDaysAgo(65);
        TestDataFactory.createBrokerListing(dispId, true);
        TestDataFactory.createDispositionOffers(3, dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('ON_TRACK', row.tractionBand,
            'An offer is traction, so no rung fires at any day. This is also what now proves the '
            + 'count is read from the real children: the hand-keyed Offers_Received__c is 0 here, '
            + 'and a 0 would have left this listing at WEEK_6');
        Assert.isFalse(row.isAtRisk, 'A listing in negotiation must not be flagged');
    }

    /**
     * 🔴 THE PAUSE, ON THIS CARD SPECIFICALLY — and it exists because the failure it guards against
     * is INVISIBLE. `DispositionTractionService.evaluate` keeps a two-argument overload so older
     * callers compile; calling it from here would produce a perfectly plausible card that simply
     * never paused, while the traction panel beside it — reading the same service through a
     * different controller — did. Two surfaces, one ladder, opposite answers: the exact defect this
     * shared service exists to prevent.
     *
     * ⚠ THE OFFERS ARE BACK-DATED. The factory dates every offer TODAY, which pauses the clock at
     * today and makes the assertion vacuous.
     */
    @isTest
    static void testGetListing_datedOfferPausesTheClockRatherThanJustSuppressingTheBand() {
        Id dispId = listedDaysAgo(65);
        TestDataFactory.createBrokerListing(dispId, true);
        List<Disposition_Offer__c> offers =
            TestDataFactory.createDispositionOffers(2, dispId, false);
        offers[0].Offer_Date__c = Date.today().addDays(-40);
        offers[1].Offer_Date__c = Date.today().addDays(-9);
        insert offers;

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('ON_TRACK', row.tractionBand, 'A paused listing does not escalate');
        Assert.areEqual(25, row.daysOnMarket,
            'Listed 65 days ago, earliest offer 40 days ago: the Days On Market tile must read 25. '
            + 'A 65 here means this card called the unpaused overload while the panel beside it '
            + 'paused - one ladder, two answers');
        Assert.isTrue(row.tractionLabel.contains('paused'),
            'And the badge says so in words: ' + row.tractionLabel);
    }

    /**
     * 🔴 THE "CLOCK THAT LOOKS HEALTHY AND NEVER TICKS" REGRESSION. With a blank listing date the
     * `Disposition__c.Days_On_Market__c` formula reads 0 because of `BlankAsZero`, which is
     * indistinguishable from "listed today". The controller must report null instead.
     */
    @isTest
    static void testGetListing_blankListingDate_reportsNotListedRatherThanDayZero() {
        Id dispId = listedDaysAgo(null);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('NOT_LISTED', row.tractionBand,
            'A blank Listing_Date__c is NOT_LISTED, never a healthy-looking day 0');
        Assert.isNull(row.daysOnMarket,
            'daysOnMarket must be null so the card can render a dash rather than "0 days"');
        Assert.isFalse(row.isAtRisk, 'A clock that never started cannot be at risk');
    }

    @isTest
    static void testGetListing_populatesTheListingFieldsItStillReads() {
        Id dispId = listedDaysAgo(5);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('Test Asset 0', row.assetName,
            'The grandparent asset name feeds the card title');
        Assert.areEqual('Test Brokerage 0', row.brokerFirm, 'Broker firm passes through');
        Assert.areEqual('Test Broker 0', row.contactName, 'Contact name passes through');
        Assert.areEqual(Date.today(), row.listDate, 'The listing row own date passes through');
        Assert.areEqual(Date.today().addDays(30), row.callForOffersDate,
            'The call-for-offers date passes through');
        Assert.areEqual('On Track', row.listingStatus,
            'The STORED Listing_Status__c still passes through - nothing writes it today, and the '
            + 'computed band deliberately does not read it, so a stale value cannot corrupt the '
            + 'traction verdict');
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // TRANCHE 4 ITEM 5 (2026-09-01) — `daysWithThisBroker`, THE SECOND CLOCK
    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // The card now shows TWO elapsed-day numbers and they answer different questions:
    //   daysOnMarket       — the MARKETING clock. Parent-derived, pausable at the first offer, and
    //                        the traction band's only input.
    //   daysWithThisBroker — the BROKER clock. `Broker_Listing__c.Days_On_Market_Live__c`, raw
    //                        elapsed days from THIS row's own List_Date__c, DISPLAY ONLY.
    //
    // 🔴 THE TESTS BELOW DELIBERATELY MAKE THE TWO NUMBERS DIFFERENT. A fixture where the parent
    // and the child carry the same date — which is exactly what the factory produces, and what
    // `openBrokerListings` produces in production on a first listing — would pass whether the
    // controller read the child formula or simply copied `daysOnMarket` into the new member. The
    // divergence IS the assertion.

    /**
     * 🔴 THE FALSIFIER FOR "THE SECOND NUMBER IS JUST A COPY OF THE FIRST".
     *
     * Parent listed 65 days ago, this listing row opened 9 days ago — the shape a broker
     * REPLACEMENT produces, where `BovSubmissionService.replaceSelectedBroker` appends a fresh
     * `Broker_Listing__c` and never touches `Disposition__c.Listing_Date__c`. The card must read
     * 65 and 9, not 65 and 65.
     *
     * ⚠ AND THE BAND MUST STILL COME FROM 65. Asserting `tractionBand` here is not decoration: it
     * is the pin for the field's own prohibition — "NOTHING MAY READ THIS FORMULA TO DRIVE AN ALERT
     * OR ESCALATION". A band computed from the 9-day broker clock would read ON_TRACK and this
     * assertion is what catches it.
     */
    @isTest
    static void testGetListing_brokerClockIsSeparateFromTheMarketingClock() {
        Id dispId = listedDaysAgo(65);
        Broker_Listing__c bl = TestDataFactory.createBrokerListing(dispId, false);
        bl.List_Date__c = Date.today().addDays(-9);
        insert bl;

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual(65, row.daysOnMarket,
            'The MARKETING clock is the parent Listing_Date__c and is unaffected by when this '
            + 'listing row opened');
        Assert.areEqual(9, row.daysWithThisBroker,
            '🔴 THE BROKER clock is THIS row Days_On_Market_Live__c. A 65 here would mean the new '
            + 'member is a copy of daysOnMarket rather than a second, independent fact — which is '
            + 'the whole reason Tranche 4 added it.');
        Assert.areEqual('WEEK_6', row.tractionBand,
            '🔴 AND THE BAND STILL KEYS ON THE MARKETING CLOCK. Days_On_Market_Live__c is DISPLAY '
            + 'ONLY — the field header says "NOTHING MAY READ THIS FORMULA TO DRIVE AN ALERT OR '
            + 'ESCALATION". A band derived from the 9-day broker clock would read ON_TRACK here.');
    }

    /**
     * A listing row with no `List_Date__c` reports null, not 0 — the formula is
     * `IF(ISBLANK(List_Date__c), null, TODAY() - List_Date__c)`, and `c/brokerListing` renders a
     * dash for it.
     *
     * ⚠ IT IS THE SAME DISTINCTION `testGetListing_blankListingDate_reportsNotListedRatherThanDayZero`
     * makes for the marketing clock, on the other clock, and it needs its own test because the two
     * nulls have different causes: that one is a Disposition with no listing date, this one is a
     * listing row with no start date. The parent clock here is deliberately RUNNING (5 days), so
     * the null cannot be inherited from a not-listed parent.
     */
    @isTest
    static void testGetListing_listingWithNoStartDate_reportsANullBrokerClock() {
        Id dispId = listedDaysAgo(5);
        Broker_Listing__c bl = TestDataFactory.createBrokerListing(dispId, false);
        bl.List_Date__c = null;
        insert bl;

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual(5, row.daysOnMarket,
            'PREMISE: the MARKETING clock is running, so the null below is about this listing row '
            + 'and cannot have been inherited from an unlisted parent');
        Assert.isNull(row.daysWithThisBroker,
            'A listing with no start date has no broker clock. Null, never 0 — "this broker has no '
            + 'start date" and "this broker started today" are different facts and the card renders '
            + 'them differently.');
    }

    @isTest
    static void testGetListing_multipleListings_returnsMostRecent() {
        // All records inserted within one test transaction share an identical CreatedDate (no
        // wall-clock time actually elapses), so ORDER BY CreatedDate DESC has no defined winner
        // between them by default. Test.setCreatedDate forces distinct values so the scenario the
        // selector's ORDER BY is meant to handle can actually be expressed.
        //
        // ⚠ This is ALSO the shape the broker-change history model depends on: a second listing
        // row supersedes the first with no schema change, and the card follows the new broker.
        Id dispId = listedDaysAgo(5);
        Broker_Listing__c older = TestDataFactory.createBrokerListing(dispId, false);
        older.Broker_Firm__c = 'CBRE';
        insert older;
        Broker_Listing__c newer = TestDataFactory.createBrokerListing(dispId, false);
        newer.Broker_Firm__c = 'JLL';
        insert newer;
        Test.setCreatedDate(older.Id, DateTime.now().addDays(-1));
        Test.setCreatedDate(newer.Id, DateTime.now());

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('JLL', row.brokerFirm,
            'ORDER BY CreatedDate DESC returns the most recently created listing');
    }

    /**
     * Data-volume read scenario per `.claude/rules/bulk-test-rule.md`: 251 Broker_Listing__c rows
     * under one Disposition, inserted via a single bulk DML statement, to prove the
     * `ORDER BY CreatedDate DESC ... LIMIT 1` pattern still resolves exactly one row at volume.
     *
     * It also pins the QUERY BUDGET at 2 — one listing read plus one offer-count aggregate. A
     * future change that counted offers per row would still return the right band and would fail
     * here.
     */
    @isTest
    static void testGetListing_251Listings_limitOneStillResolvesInTwoQueries() {
        Id dispId = listedDaysAgo(5);
        TestDataFactory.createBrokerListings(251, dispId, true);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Integer listingCount = [SELECT COUNT() FROM Broker_Listing__c WHERE Disposition__c = :dispId];
        Assert.areEqual(251, listingCount, 'All 251 listings should have been inserted');
        Assert.isNotNull(row, 'getListing should still resolve exactly one row at volume');
        Assert.areEqual(2, queriesUsed,
            'getListing costs exactly 2 SOQL: the listing (carrying the clock on the grandparent '
            + 'path it already traversed) and ONE aggregate carrying both the offer count and the '
            + 'first offer date. A separate read for the pause date would fail here');
    }

    // A bare user with no DPEG access: the Broker_Listing__c custom-object read runs WITH
    // USER_MODE and throws for the unprivileged user, exercising getListing's read-failure
    // catch which maps it to a user-safe AuraHandledException at the LWC boundary (P6).
    private static User bareUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'p6bare', Email = 'p6bare@example.com.invalid', EmailEncodingKey = 'UTF-8',
            LastName = 'P6Bare', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Chicago',
            Username = 'p6bare.' + DateTime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000) + '@example.com.invalid');
        insert u;
        return u;
    }

    @isTest
    static void readPathThrowsAuraHandledException() {
        Disposition__c d = disposition();
        User u = bareUser();
        System.runAs(u) {
            Test.startTest();
            try {
                BrokerListingController.getListing(d.Id);
                Assert.fail('expected AuraHandledException from getListing under a restricted user');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e, 'getListing read failure maps to AuraHandledException');
            }
            Test.stopTest();
        }
    }
}
