/**
 * Read-only data provider for the Broker Hub Lightning page (Acquisitions).
 * Brokers are standard Contacts flagged with Is_Broker__c. Returns header
 * stats, the full broker list, and the top brokers ranked by active listings.
 */
public with sharing class BrokerController {

    private static final Integer TOP_LIMIT = 6;

    @AuraEnabled(cacheable=true)
    public static BrokerHub getBrokerHub() {
        BrokerHub hub = new BrokerHub();

        // --- full broker list (drives the list + header stats) ---
        hub.brokers = new List<BrokerRow>();
        Integer totalBrokers = 0;
        Integer activeBrokers = 0;
        Integer activeListings = 0;
        Integer offersReceived = 0;
        Decimal closedVolume = 0;
        Set<String> firms = new Set<String>();

        for (Contact c : ContactSelector.selectBrokersRankedByClosedVolume()) {
            hub.brokers.add(toRow(c));
            totalBrokers++;
            if (c.Broker_Status__c == 'Active') {
                activeBrokers++;
            }
            activeListings += intOf(c.Active_Listings__c);
            offersReceived += intOf(c.Offers_Received__c);
            closedVolume += (c.Closed_Volume__c == null ? 0 : c.Closed_Volume__c);
            if (String.isNotBlank(c.Broker_Firm__c)) {
                firms.add(c.Broker_Firm__c.trim().toLowerCase());
            }
        }

        hub.stats = new BrokerStats();
        hub.stats.totalFirms = firms.size();
        hub.stats.totalBrokers = totalBrokers;
        hub.stats.activeBrokers = activeBrokers;
        hub.stats.activeListings = activeListings;
        hub.stats.offersReceived = offersReceived;
        hub.stats.closedVolume = closedVolume;

        // --- top brokers ranked by active listings ---
        hub.topBrokers = new List<BrokerRow>();
        for (Contact c : ContactSelector.selectTopBrokersByActiveListings(TOP_LIMIT)) {
            hub.topBrokers.add(toRow(c));
        }

        return hub;
    }

    private static BrokerRow toRow(Contact c) {
        BrokerRow r = new BrokerRow();
        r.id = c.Id;
        r.name = c.Name;
        r.firm = c.Broker_Firm__c;
        r.specialty = c.Broker_Specialty__c;
        r.status = c.Broker_Status__c;
        r.activeListings = intOf(c.Active_Listings__c);
        r.offers = intOf(c.Offers_Received__c);
        r.closedVolume = (c.Closed_Volume__c == null ? 0 : c.Closed_Volume__c);
        r.avgDom = intOf(c.Avg_Days_On_Market__c);
        return r;
    }

    private static Integer intOf(Decimal d) {
        return d == null ? 0 : d.intValue();
    }

    public class BrokerHub {
        @AuraEnabled public BrokerStats stats;
        @AuraEnabled public List<BrokerRow> brokers;
        @AuraEnabled public List<BrokerRow> topBrokers;
    }

    public class BrokerStats {
        @AuraEnabled public Integer totalFirms;
        @AuraEnabled public Integer totalBrokers;
        @AuraEnabled public Integer activeBrokers;
        @AuraEnabled public Integer activeListings;
        @AuraEnabled public Integer offersReceived;
        @AuraEnabled public Decimal closedVolume;
    }

    public class BrokerRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String firm;
        @AuraEnabled public String specialty;
        @AuraEnabled public String status;
        @AuraEnabled public Integer activeListings;
        @AuraEnabled public Integer offers;
        @AuraEnabled public Decimal closedVolume;
        @AuraEnabled public Integer avgDom;
    }
}