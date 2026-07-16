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
