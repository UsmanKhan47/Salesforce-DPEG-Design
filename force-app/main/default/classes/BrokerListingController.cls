public with sharing class BrokerListingController {

    public class ListingRow {
        @AuraEnabled public String id;
        @AuraEnabled public String assetName;
        @AuraEnabled public String brokerFirm;
        @AuraEnabled public String contactName;
        @AuraEnabled public Date listDate;
        @AuraEnabled public Date callForOffersDate;
        @AuraEnabled public Integer daysOnMarket;
        @AuraEnabled public String listingStatus;
        @AuraEnabled public Integer offersReceived;
        @AuraEnabled public String weekLabel;
        @AuraEnabled public Boolean isAtRisk;
    }

    @AuraEnabled(cacheable=true)
    public static ListingRow getListing(Id dispositionId) {
        List<Broker_Listing__c> listings = [
            SELECT Id, Disposition__r.Property_Asset__r.Name,
                   Broker_Firm__c, Contact_Name__c, List_Date__c,
                   Call_For_Offers_Date__c, Days_On_Market__c, Listing_Status__c,
                   Offers_Received__c
            FROM Broker_Listing__c
            WHERE Disposition__c = :dispositionId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (listings.isEmpty()) return null;
        Broker_Listing__c bl = listings[0];
        ListingRow r = new ListingRow();
        r.id = bl.Id;
        r.assetName = bl.Disposition__r != null && bl.Disposition__r.Property_Asset__r != null
                      ? bl.Disposition__r.Property_Asset__r.Name : '';
        r.brokerFirm = bl.Broker_Firm__c;
        r.contactName = bl.Contact_Name__c;
        r.listDate = bl.List_Date__c;
        r.callForOffersDate = bl.Call_For_Offers_Date__c;
        r.daysOnMarket = bl.Days_On_Market__c != null ? bl.Days_On_Market__c.intValue() : 0;
        r.listingStatus = bl.Listing_Status__c;
        r.offersReceived = bl.Offers_Received__c != null ? bl.Offers_Received__c.intValue() : 0;
        // derive week label from days on market
        Integer dom = r.daysOnMarket;
        if (dom >= 42) {
            r.weekLabel = 'Week 6 — Hard Stop';
            r.isAtRisk = true;
        } else if (dom >= 28) {
            r.weekLabel = 'Week 4 — At Risk';
            r.isAtRisk = true;
        } else if (dom >= 21) {
            r.weekLabel = 'Week 3 — On Track';
            r.isAtRisk = false;
        } else {
            r.weekLabel = null;
            r.isAtRisk = false;
        }
        return r;
    }
}