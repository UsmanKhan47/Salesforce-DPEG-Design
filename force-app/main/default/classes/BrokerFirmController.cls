/**
 * Sidebar data provider for the Opportunity record page: returns the brokerage
 * firm (Account) behind the deal, the broker contact, and firm-level deal
 * counts (submitted / won / lost) across the firm's Opportunities.
 *
 * ═══ 🔴 THE THREE COUNTS ARE READ, NOT COMPUTED (2026-08-30, design Item 6.1) ═══
 * ⚠ RETRACTED, verbatim, from the header and from the body of `getBrokerFirm`:
 *     "aggregated across the firm's Opportunities"
 *     "// Firm-level deal counts across every Opportunity from this brokerage."
 *     for (AggregateResult ar : OpportunitySelector.countByStageForAccount(opp.AccountId)) { ... }
 * That loop summed a `GROUP BY StageName` aggregate and string-compared `'Closed Won'` /
 * `'Dead/Pass'` in Apex. It is GONE. The three numbers now come from native Account roll-up
 * summaries — `Total_Deals_Submitted__c`, `Deals_Won__c`, `Deals_Lost__c` — spanned onto the row
 * this class already loads (`OpportunitySelector.selectAccountRefById`).
 *
 * WHY, AND IT IS NOT PERFORMANCE. The saved query is a bonus (two reads became one); the reason is
 * that the roll-ups exist and are REPORTABLE, so the `Broker_Leaderboard` report and this sidebar
 * card were about to compute the same three numbers two different ways. Two independent
 * derivations of one fact drift, and the drift is invisible — the card and the report simply
 * disagree, on a screen where nobody has both open. One stored source removes the failure mode
 * rather than documenting it. (The design originally logged this repoint as out of scope, Q10 /
 * RESIDUAL-8; the user reversed that on 2026-08-30 for exactly this reason.)
 *
 * 🔴 TWO CONSEQUENCES THE NEXT READER MUST NOT MISTAKE FOR BUGS:
 *   1. THE ROLL-UPS COUNT EVERY OPPORTUNITY ON THE ACCOUNT, not only broker-introduced ones —
 *      but so did the aggregate they replaced (`countByStageForAccount` had no record-type or
 *      source filter either). The number's MEANING is unchanged; only where it is computed moved.
 *      This is design RESIDUAL-5 and it predates this change.
 *   2. A ROLL-UP IS PLATFORM-MAINTAINED, SO IT CAN BE MOMENTARILY BEHIND after a bulk data load
 *      in a way a live aggregate never was. On normal DML it recalculates in the same transaction.
 *
 * ⚠ THE STAGE STRINGS LEFT WITH THE LOOP. `'Closed Won'` and `'Dead/Pass'` no longer appear in
 * this class at all — they are now the roll-up fields' `<summaryFilterItems>`, in metadata. Do not
 * reintroduce either literal here to "double-check" a count.
 *
 * ⚠ FLS: the three roll-ups are read `WITH USER_MODE` and a missing grant throws for the WHOLE ROW
 * — see `OpportunitySelector.selectAccountRefById`'s header for the required permission sets. A
 * gap surfaces here as READ_FAILURE_MESSAGE, not as three zeroes.
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

            // Firm-level deal counts, READ from the Account roll-up summaries carried on the row
            // above — see the class header for why this is a read and no longer an aggregate.
            //
            // ⚠ THE NULL COALESCE IS NOT DEFENSIVE PADDING. A count roll-up settles at 0, but the
            // DTO's members are `Integer` and a null spanning value would NPE nothing here yet
            // would travel to the client as `null`, where `brokerFirmCard` renders it as the string
            // "null" rather than "0". Coalescing at the boundary keeps the card's contract
            // ("always a number") true regardless of what the platform hands back.
            bf.dealsSubmitted = intOf(opp.Account.Total_Deals_Submitted__c);
            bf.dealsWon = intOf(opp.Account.Deals_Won__c);
            bf.dealsLost = intOf(opp.Account.Deals_Lost__c);
            return bf;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BrokerFirmController.getBrokerFirm on ' + opportunityId + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * A roll-up summary arrives as a `Decimal`; the DTO carries `Integer`. Null becomes 0.
     *
     * @param value The roll-up value, possibly null.
     * @return The same count as an Integer, or 0 when the value is null.
     */
    private static Integer intOf(Decimal value) {
        return value == null ? 0 : value.intValue();
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