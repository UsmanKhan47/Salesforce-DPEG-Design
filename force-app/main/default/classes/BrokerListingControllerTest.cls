@isTest
private class BrokerListingControllerTest {

    @testSetup
    static void setup() {
        Property__c prop = new Property__c(Name = 'Test Property');
        insert prop;
        Property_Asset__c asset = new Property_Asset__c(
            Property__c = prop.Id, Name = 'Sienna Town Center',
            NOI__c = 1800000, Market_Cap_Rate__c = 6.5, Target_Sale_Price__c = 26900000
        );
        insert asset;
        Disposition__c d = new Disposition__c(
            Property_Asset__c = asset.Id, Disposition_Stage__c = 'Active Listing'
        );
        insert d;
        insert new Broker_Listing__c(
            Disposition__c = d.Id, Broker_Firm__c = 'CBRE', Contact_Name__c = 'Mark Chen',
            List_Date__c = Date.today().addDays(-40), Call_For_Offers_Date__c = Date.today().addDays(7),
            Days_On_Market__c = 40, Listing_Status__c = 'At Risk', Offers_Received__c = 0
        );
    }

    @isTest
    static void testGetListing() {
        Disposition__c d = [SELECT Id FROM Disposition__c LIMIT 1];
        Test.startTest();
        BrokerListingController.ListingRow row = BrokerListingController.getListing(d.Id);
        Test.stopTest();
        System.assertNotEquals(null, row);
        System.assertEquals('CBRE', row.brokerFirm);
        System.assertEquals(40, row.daysOnMarket);
        System.assertEquals(true, row.isAtRisk);
        System.assertEquals('Week 4 — At Risk', row.weekLabel);
    }
}