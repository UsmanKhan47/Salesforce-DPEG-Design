@isTest
private class BrokerControllerTest {

    @testSetup
    static void setup() {
        List<Contact> brokers = new List<Contact>();
        // 3 active brokers with varied listings + 1 inactive + 1 non-broker contact.
        brokers.add(newBroker('Pierce', 'CBRE', 'Retail', 'Active', 8, 12, 24000000, 95));
        brokers.add(newBroker('Nguyen', 'JLL', 'Office', 'Active', 5, 7, 18000000, 110));
        brokers.add(newBroker('Alvarez', 'Newmark', 'Industrial', 'Active', 2, 3, 6000000, 60));
        Contact inactive = newBroker('Cole', 'Colliers', 'Land', 'Inactive', 0, 0, 0, 0);
        brokers.add(inactive);
        brokers.add(new Contact(LastName = 'NotABroker', Is_Broker__c = false));
        insert brokers;
    }

    private static Contact newBroker(String last, String firm, String specialty,
            String status, Integer listings, Integer offers, Decimal volume, Integer dom) {
        return new Contact(
            LastName = last,
            Is_Broker__c = true,
            Broker_Firm__c = firm,
            Broker_Specialty__c = specialty,
            Broker_Status__c = status,
            Active_Listings__c = listings,
            Offers_Received__c = offers,
            Closed_Volume__c = volume,
            Avg_Days_On_Market__c = dom
        );
    }

    @isTest
    static void testStats() {
        Test.startTest();
        BrokerController.BrokerHub hub = BrokerController.getBrokerHub();
        Test.stopTest();

        System.assertEquals(4, hub.stats.totalBrokers, '4 broker contacts (excludes non-broker)');
        System.assertEquals(3, hub.stats.activeBrokers, '3 active brokers');
        System.assertEquals(15, hub.stats.activeListings, '8 + 5 + 2 + 0 listings');
        System.assertEquals(22, hub.stats.offersReceived, '12 + 7 + 3 + 0 offers');
        System.assertEquals(48000000, hub.stats.closedVolume, 'summed closed volume');
    }

    @isTest
    static void testBrokerListAndTop() {
        Test.startTest();
        BrokerController.BrokerHub hub = BrokerController.getBrokerHub();
        Test.stopTest();

        System.assertEquals(4, hub.brokers.size(), 'all broker contacts in the list');
        // top list excludes the 0-listing broker and is ranked by active listings.
        System.assertEquals(3, hub.topBrokers.size(), 'only brokers with listings > 0');
        System.assertEquals(8, hub.topBrokers[0].activeListings, 'highest active listings first');
        System.assertEquals(2, hub.topBrokers[2].activeListings, 'lowest of the three last');
        System.assertEquals('CBRE', hub.topBrokers[0].firm, 'top broker firm carried through');
    }
}