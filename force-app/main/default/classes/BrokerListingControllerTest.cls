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
 *   THE LADDER — 21/28/42 was the 6-week clock D27.1 overturned. A suite asserting those strings
 *                was the falsifier for the defect rather than for the feature.
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

    @isTest
    static void testGetListing_insideMonthOne_isOnTrack() {
        Id dispId = listedDaysAgo(12);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual(12, row.daysOnMarket,
            'Days on market is computed from the PARENT listing date, not the hand-keyed field '
            + '(which the factory left at 0)');
        Assert.areEqual('ON_TRACK', row.tractionBand, 'Day 12 with no offers is On Track');
        Assert.isFalse(row.isAtRisk, 'Day 12 is not at risk');
        Assert.isTrue(row.tractionLabel.contains('12'),
            'The badge must name the day: ' + row.tractionLabel);
    }

    @isTest
    static void testGetListing_pastTheThirtyDayCheckpoint_isAtRisk() {
        Id dispId = listedDaysAgo(34);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('CHECKPOINT_DUE', row.tractionBand,
            'Day 34 with zero offers is the day-30 traction checkpoint');
        Assert.isTrue(row.isAtRisk, 'The checkpoint band drives the amber styling');
        Assert.isNotNull(row.tractionDetail, 'The badge tooltip copy must be populated');
    }

    @isTest
    static void testGetListing_pastTheSixtyDayPeriod_isHardStop() {
        Id dispId = listedDaysAgo(65);
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('HARD_STOP', row.tractionBand,
            'Day 65 with zero offers is past the 60-day marketing period');
        Assert.isTrue(row.isAtRisk, 'Hard Stop is an at-risk state');
        Assert.areEqual(65, row.daysOnMarket, 'The elapsed count is not clamped');
    }

    /**
     * 🔴 THE OFFERS-ONLY RULE, AT THE CONTROLLER BOUNDARY (D28/Q1). The retired ladder had no
     * offers branch at all, so this exact record would have been labelled "Week 6 — Hard Stop"
     * while three buyers were in negotiation.
     */
    @isTest
    static void testGetListing_offersSuppressTheCheckpointEvenPastDaySixty() {
        Id dispId = listedDaysAgo(65);
        TestDataFactory.createBrokerListing(dispId, true);
        TestDataFactory.createDispositionOffers(3, dispId, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(dispId);
        Test.stopTest();

        Assert.areEqual('ON_TRACK', row.tractionBand,
            'An offer is traction, so no checkpoint fires at any day');
        Assert.isFalse(row.isAtRisk, 'A listing in negotiation must not be flagged');
        Assert.areEqual(3, row.offersReceived,
            'The count comes from the real Disposition_Offer__c children, not the hand-keyed '
            + 'Broker_Listing__c.Offers_Received__c (which the factory left at 0)');
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
            + 'path it already traversed) and one aggregate for the offer count');
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
