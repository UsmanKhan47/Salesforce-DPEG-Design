/**
 * Tests for BrokerListingSelector (P4 cleanup wave E — Disposition module).
 *
 * Covers the one relocated query: field population (including the
 * Disposition__r.Property_Asset__r.Name grandparent path), most-recent ordering
 * (deterministic via Test.setCreatedDate — no Id tiebreak in the query), the
 * no-listing -> null contract, and a 251-record LIMIT-1 read.
 *
 * @TestSetup builds Property -> Property_Asset -> Disposition with explicit parent
 * Ids; test methods QUERY that data (TestDataFactory ⚠1 cache trap). No runAs
 * USER_MODE test — Broker_Listing__c is custom, FLS gap 0.
 */
@isTest
private class BrokerListingSelectorTest {

    private static final Integer BULK_N = 251;

    @testSetup
    static void setup() {
        Property__c prop = TestDataFactory.createProperty(true);
        Property_Asset__c asset = TestDataFactory.createPropertyAsset(prop.Id, true);
        TestDataFactory.createDisposition(asset.Id, true);
    }

    private static Id dispositionId() {
        return [SELECT Id FROM Disposition__c LIMIT 1].Id;
    }

    @isTest
    static void selectMostRecentByDispositionId_populatesFieldsIncludingGrandparentName() {
        Id dispId = dispositionId();
        TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        Broker_Listing__c result = BrokerListingSelector.selectMostRecentByDispositionId(dispId);
        Test.stopTest();

        Assert.isNotNull(result, 'A listing exists for the Disposition, so a row should return');
        Assert.areEqual('Test Asset 0', result.Disposition__r.Property_Asset__r.Name,
            'The Disposition__r.Property_Asset__r.Name grandparent path should be selected');
        Assert.areEqual('Test Brokerage 0', result.Broker_Firm__c, 'Broker_Firm__c should be selected');
        Assert.areEqual('Test Broker 0', result.Contact_Name__c, 'Contact_Name__c should be selected');
        Assert.areEqual(Date.today(), result.List_Date__c, 'List_Date__c should be selected');
        Assert.areEqual(Date.today().addDays(30), result.Call_For_Offers_Date__c, 'Call_For_Offers_Date__c should be selected');
        Assert.areEqual(0, result.Days_On_Market__c, 'Days_On_Market__c should be selected');
        Assert.areEqual('On Track', result.Listing_Status__c, 'Listing_Status__c should be selected');
        Assert.areEqual(0, result.Offers_Received__c, 'Offers_Received__c should be selected');
        // Tranche 5B: the MARKETING CLOCK the traction badge is computed from. It rides the
        // grandparent path this query already traverses, so it costs BrokerListingController no
        // extra SOQL — which is the reason the band could be added to the card at all.
        Assert.areEqual(Date.today(), result.Disposition__r.Listing_Date__c,
            'Disposition__r.Listing_Date__c should be selected - it is the clock, and narrowing '
            + 'the field list would silently return the card to a dead one');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // selectByDispositionIds — the Active Listing auto-create idempotency guard
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void selectByDispositionIds_nullAndEmptyReturnEmpty() {
        Assert.areEqual(0, BrokerListingSelector.selectByDispositionIds(null).size(),
            'A null input returns an empty list, never a NullPointerException');
        Assert.areEqual(0, BrokerListingSelector.selectByDispositionIds(new Set<Id>()).size(),
            'An empty input returns an empty list');
    }

    @isTest
    static void selectByDispositionIds_scopesToTheRequestedDispositions() {
        Id dispId = dispositionId();
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        Disposition__c other = TestDataFactory.createDisposition(
            asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        TestDataFactory.createBrokerListing(dispId, true);
        TestDataFactory.createBrokerListing(other.Id, true);

        Test.startTest();
        List<Broker_Listing__c> rows =
            BrokerListingSelector.selectByDispositionIds(new Set<Id>{ dispId });
        Test.stopTest();

        Assert.areEqual(1, rows.size(),
            'Only the requested Disposition may return - an unscoped guard would suppress '
            + 'auto-create on every disposition the moment ANY listing existed');
        Assert.areEqual(dispId, rows[0].Disposition__c,
            'The parent lookup must be selected - it is the key the guard removes entrants by');
    }

    /**
     * BULK per `.claude/rules/bulk-test-rule.md`. The guard is called once per trigger chunk, so
     * what matters is that ONE query covers 251 dispositions.
     */
    @isTest
    static void selectByDispositionIds_bulk251IsOneQuery() {
        Property_Asset__c asset = [SELECT Id FROM Property_Asset__c LIMIT 1];
        List<Disposition__c> dispositions = TestDataFactory.createDispositions(
            BULK_N, asset.Id, TestDataFactory.DISPOSITION_RT_ON_MARKET, true);
        List<Broker_Listing__c> listings = new List<Broker_Listing__c>();
        for (Disposition__c d : dispositions) {
            listings.add(TestDataFactory.createBrokerListing(d.Id, false));
        }
        insert listings;
        Set<Id> ids = new Map<Id, Disposition__c>(dispositions).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Broker_Listing__c> rows = BrokerListingSelector.selectByDispositionIds(ids);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(), 'All ' + BULK_N + ' listings must return');
        Assert.areEqual(1, queriesUsed, 'ONE query for the whole chunk, never one per record');
    }

    @isTest
    static void selectMostRecentByDispositionId_returnsMostRecent() {
        Id dispId = dispositionId();
        Broker_Listing__c older = TestDataFactory.createBrokerListing(dispId, true);
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-5));
        Broker_Listing__c newer = TestDataFactory.createBrokerListing(dispId, true);

        Test.startTest();
        Broker_Listing__c result = BrokerListingSelector.selectMostRecentByDispositionId(dispId);
        Test.stopTest();

        Assert.areEqual(newer.Id, result.Id,
            'ORDER BY CreatedDate DESC should return the most recently created listing');
    }

    @isTest
    static void selectMostRecentByDispositionId_noListing_returnsNull() {
        Id dispId = dispositionId();

        Test.startTest();
        Broker_Listing__c result = BrokerListingSelector.selectMostRecentByDispositionId(dispId);
        Test.stopTest();

        Assert.isNull(result, 'A Disposition with no listing should return null, not throw');
    }

    @isTest
    static void selectMostRecentByDispositionId_bulk251_resolvesOne() {
        Id dispId = dispositionId();
        TestDataFactory.createBrokerListings(BULK_N, dispId, true);

        Test.startTest();
        Broker_Listing__c result = BrokerListingSelector.selectMostRecentByDispositionId(dispId);
        Test.stopTest();

        Integer total = [SELECT COUNT() FROM Broker_Listing__c WHERE Disposition__c = :dispId];
        Assert.areEqual(BULK_N, total, 'All 251 listings should exist under the Disposition');
        Assert.isNotNull(result, 'LIMIT 1 should still resolve exactly one row at 251-record volume');
    }
}
