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

        Opportunity opp = [
            SELECT Id, AccountId, Account.Name
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (opp.AccountId == null) {
            return bf;
        }

        bf.hasFirm = true;
        bf.firmName = opp.Account.Name;

        // Broker person: the broker Contact linked to the firm Account.
        List<Contact> cs = [
            SELECT Name FROM Contact WHERE AccountId = :opp.AccountId ORDER BY CreatedDate LIMIT 1
        ];
        if (!cs.isEmpty()) {
            bf.brokerName = cs[0].Name;
        }

        // Firm-level deal counts across every Opportunity from this brokerage.
        for (AggregateResult ar : [
            SELECT StageName st, COUNT(Id) c
            FROM Opportunity
            WHERE AccountId = :opp.AccountId
            GROUP BY StageName
        ]) {
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