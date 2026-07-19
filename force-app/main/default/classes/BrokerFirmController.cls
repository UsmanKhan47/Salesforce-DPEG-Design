/**
 * Sidebar data provider for the Opportunity record page: returns the brokerage
 * firm (Account) behind the deal, the broker contact, and firm-level deal
 * counts (submitted / won / lost) aggregated across the firm's Opportunities.
 */
public with sharing class BrokerFirmController {

    // Fixed, generic user-safe message for a failed read (ARCHITECTURE.md §5). Never
    // interpolate platform text or exception detail into it — the detail goes to the
    // debug log (admin-only) and the user gets this.
    private static final String READ_FAILURE_MESSAGE =
        'The brokerage firm summary could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    @AuraEnabled(cacheable=true)
    public static BrokerFirm getBrokerFirm(Id opportunityId) {
        try {
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
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerFirmController.getBrokerFirm on ' + opportunityId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
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