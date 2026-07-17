/**
 * Sidebar data provider for the Opportunity record page: returns the brokerage
 * firm (Account) behind the deal, the broker contact, and firm-level deal
 * counts (submitted / won / lost) aggregated across the firm's Opportunities.
 */
public with sharing class BrokerFirmController {

    @AuraEnabled(cacheable=true)
    public static BrokerFirm getBrokerFirm(Id opportunityId) {
        BrokerFirm bf = new BrokerFirm();
        if (opportunityId == null) {
            return bf;
        }

        Opportunity opp = OpportunitySelector.selectAccountRefById(opportunityId);
        if (opp.AccountId == null) {
            return bf;
        }

        bf.hasFirm = true;
        bf.firmName = opp.Account.Name;

        // Broker person: the broker Contact linked to the firm Account.
        Contact broker = ContactSelector.selectEarliestByAccountId(opp.AccountId);
        if (broker != null) {
            bf.brokerName = broker.Name;
        }

        // Firm-level deal counts across every Opportunity from this brokerage.
        for (AggregateResult ar : OpportunitySelector.countByStageForAccount(opp.AccountId)) {
            Integer c = (Integer) ar.get('c');
            String st = (String) ar.get('st');
            bf.dealsSubmitted += c;
            if (st == 'Closed Won') {
                bf.dealsWon += c;
            } else if (st == 'Dead/Pass') {
                bf.dealsLost += c;
            }
        }
        return bf;
    }

    public class BrokerFirm {
        @AuraEnabled public Boolean hasFirm = false;
        @AuraEnabled public String firmName;
        @AuraEnabled public String brokerName;
        @AuraEnabled public Integer dealsSubmitted = 0;
        @AuraEnabled public Integer dealsWon = 0;
        @AuraEnabled public Integer dealsLost = 0;
    }
}