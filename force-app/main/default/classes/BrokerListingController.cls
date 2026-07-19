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

    // Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never
    // interpolate platform text or exception detail into it — the detail goes to the
    // debug log (admin-only) and the user gets this.
    private static final String READ_FAILURE_MESSAGE =
        'The broker listing could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    @AuraEnabled(cacheable=true)
    public static ListingRow getListing(Id dispositionId) {
        try {
            Broker_Listing__c bl = BrokerListingSelector.selectMostRecentByDispositionId(dispositionId);
            if (bl == null) return null;
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerListingController.getListing on ' + dispositionId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}