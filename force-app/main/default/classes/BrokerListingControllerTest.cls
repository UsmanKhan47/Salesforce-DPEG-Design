/**
 * @description Test class for BrokerListingController.
 * Migrated onto TestDataFactory (Phase 2 conformance program, Disposition module).
 * Reported coverage was 75.9% going into this pass — the prior test only
 * exercised the "Week 4 - At Risk" branch of getListing's daysOnMarket ladder.
 * Adds the missing branches (no listing, under-3-weeks, Week 3, Week 6 hard
 * stop), a null-defaults scenario, a most-recent-wins scenario, and a
 * 251-record data-volume read test per .claude/rules/bulk-test-rule.md.
 * @author Unit Testing Agent
 */
@isTest
private class BrokerListingControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(asset.Id, true);
    }

    @isTest
    static void testGetListing_noListings_returnsNull() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();

        System.assertEquals(null, row, 'No Broker_Listing__c exists yet, so getListing should return null');
    }

    @isTest
    static void testGetListing_underThreeWeeks_noRiskLabel() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Broker_Listing__c bl = TestDataFactory.createBrokerListing(d.Id, false);
        bl.Days_On_Market__c = 10;
        insert bl;

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();

        System.assertEquals(10, row.daysOnMarket, 'Days on market should pass through');
        System.assertEquals(null, row.weekLabel, 'Under 21 days should carry no week label');
        System.assertEquals(false, row.isAtRisk, 'Under 21 days should not be at risk');
    }

    @isTest
    static void testGetListing_weekThree_onTrack() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Broker_Listing__c bl = TestDataFactory.createBrokerListing(d.Id, false);
        bl.Days_On_Market__c = 25;
        insert bl;

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();

        System.assertEquals('Week 3 — On Track', row.weekLabel, '21-27 days should be Week 3 On Track');
        System.assertEquals(false, row.isAtRisk, 'Week 3 On Track should not be flagged at-risk');
    }

    @isTest
    static void testGetListing_weekFour_atRisk() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Broker_Listing__c bl = TestDataFactory.createBrokerListing(d.Id, false);
        bl.Days_On_Market__c = 40;
        bl.Listing_Status__c = 'At Risk';
        insert bl;

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();

        System.assertEquals('Week 4 — At Risk', row.weekLabel, '28-41 days should be Week 4 At Risk');
        System.assertEquals(true, row.isAtRisk, 'Week 4 should be flagged at-risk');
    }

    @isTest
    static void testGetListing_weekSix_hardStop() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Broker_Listing__c bl = TestDataFactory.createBrokerListing(d.Id, false);
        bl.Days_On_Market__c = 45;
        bl.Listing_Status__c = 'Hard Stop';
        insert bl;

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();

        System.assertEquals('Week 6 — Hard Stop', row.weekLabel, '42+ days should be Week 6 Hard Stop');
        System.assertEquals(true, row.isAtRisk, 'Week 6 Hard Stop should be flagged at-risk');
    }

    @isTest
    static void testGetListing_nullDaysAndOffers_defaultToZero() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Broker_Listing__c bl = TestDataFactory.createBrokerListing(d.Id, false);
        bl.Days_On_Market__c = null;
        bl.Offers_Received__c = null;
        insert bl;

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();

        System.assertEquals(0, row.daysOnMarket, 'Null Days_On_Market__c should default to 0');
        System.assertEquals(0, row.offersReceived, 'Null Offers_Received__c should default to 0');
        System.assertEquals(null, row.weekLabel, '0 days should carry no week label');
    }

    @isTest
    static void testGetListing_multipleListings_returnsMostRecent() {
        // All records inserted within one test transaction share an identical
        // CreatedDate (no wall-clock time actually elapses), so ORDER BY
        // CreatedDate DESC has no defined winner between them by default.
        // Test.setCreatedDate forces distinct values so the scenario the
        // controller's ORDER BY is meant to handle can actually be expressed.
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Broker_Listing__c older = TestDataFactory.createBrokerListing(d.Id, false);
        older.Broker_Firm__c = 'CBRE';
        older.Days_On_Market__c = 5;
        insert older;
        Broker_Listing__c newer = TestDataFactory.createBrokerListing(d.Id, false);
        newer.Broker_Firm__c = 'JLL';
        newer.Days_On_Market__c = 1;
        insert newer;
        Test.setCreatedDate(older.Id, DateTime.now().addDays(-1));
        Test.setCreatedDate(newer.Id, DateTime.now());

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();

        System.assertEquals('JLL', row.brokerFirm, 'ORDER BY CreatedDate DESC should return the most recently created listing');
    }

    /**
     * Data-volume read scenario per .claude/rules/bulk-test-rule.md: 251
     * Broker_Listing__c rows under one Disposition, inserted via a single bulk
     * DML statement, to prove the ORDER BY CreatedDate DESC ... LIMIT 1
     * pattern still resolves to exactly one row at volume.
     */
    @isTest
    static void testGetListing_251Listings_limitOneStillResolves() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        TestDataFactory.createBrokerListings(251, d.Id, true);

        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();

        Integer listingCount = [SELECT COUNT() FROM Broker_Listing__c WHERE Disposition__c = :d.Id];
        System.assertEquals(251, listingCount, 'All 251 listings should have been inserted');
        System.assertNotEquals(null, row, 'getListing should still resolve exactly one row at volume');
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
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
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
