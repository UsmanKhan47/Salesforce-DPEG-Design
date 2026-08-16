/**
 * Read-only data provider for the "Top 5 Largest Deals" home-page card
 * (`lwc/topLargestDeals`) — FSD §24.2: *the five biggest active deals, any stage except
 * Closed*.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 WHY THIS IS A SECOND CARD RATHER THAN A FILTER ON THE EXISTING ONE
 * ═════════════════════════════════════════════════════════════════════════════
 * `lwc/recentOpportunities` (backed by `OpportunityFunnelController.getRecentOpportunities`
 * → `OpportunitySelector.selectTopByAskingPrice`) already ranks deals — BY ASKING PRICE,
 * with no stage filter. The tranche-2 design proposed closing §24.2 by adding a stage
 * filter to that method and relabelling that card.
 *
 * **THAT WAS OVERRULED BY THE USER (2026-08-16): the two stay SEPARATE, and this one ranks
 * on `Opportunity.Amount`.** The reason is not cosmetic — the two lists answer different
 * questions and a deal can top one and not the other:
 *
 *   `Asking_Price__c`  what the SELLER wants for the asset.
 *   `Amount`           what the DEAL is worth to DPEG.
 *
 * ⇒ Do NOT "consolidate" these two cards, and do NOT re-point this controller at
 *   `selectTopByAskingPrice`. Either change silently turns this card into a duplicate of a
 *   card that is already on the same page, which is worse than not having built it.
 *   `lwc/recentOpportunities`, `OpportunityFunnelController.getRecentOpportunities` and
 *   `OpportunitySelector.selectTopByAskingPrice` are deliberately UNTOUCHED by this change.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * LAYERING AND BOUNDARY
 * ═════════════════════════════════════════════════════════════════════════════
 * Thin controller: all SOQL is delegated to `OpportunitySelector` per ARCHITECTURE.md §2
 * and `.claude/rules/apex-layering-rule.md`. There is deliberately NO service class — this
 * is a read with no orchestration and no DML to extract, which is the P6
 * read-only-controller precedent (`LeadFunnelController`, `OpportunityFunnelController`,
 * `SellMeterController`). Adding a service here would be a file that forwards one call.
 *
 * Every `@AuraEnabled` read wraps its work in a try/catch that maps failure to a user-safe
 * `AuraHandledException` (ARCHITECTURE.md §5): platform detail goes to the debug log
 * (admin-only) and the user gets a fixed, generic message with no exception detail
 * concatenated into it.
 *
 * ⚠ THE MOST LIKELY REASON THIS CARD ERRORS IN PRODUCTION IS AN FLS GAP ON
 * `Opportunity.Amount`, WHICH IS GRANTED BY NO PERMISSION SET IN THIS REPO as at
 * 2026-08-16. `selectTopByAmount` is `WITH USER_MODE` — correctly, because this backs a
 * read a human asked for — and USER_MODE throws on the WHOLE ROW for ONE inaccessible
 * field. The remedy is a permission-set grant, NOT a mode change; the full argument is at
 * the selector method. The failure is LOUD (the card renders its error banner), which is
 * the intended posture.
 */
public with sharing class TopDealsController {

    /** How many deals the card shows. FSD §24.2 says five. */
    @TestVisible
    private static final Integer TOP_N = 5;

    /**
     * Fixed, generic user-safe message for a failed read.
     *
     * ⚠ It names no field and no exception. An FLS denial arrives as
     * `System.QueryException: No such column 'Amount'`, which reads to a user as a broken
     * app rather than a permissions gap — surfacing it would misdirect rather than help.
     */
    private static final String READ_FAILURE_MESSAGE =
        'The largest deals could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The five largest ACTIVE deals by `Amount`, largest first.
     *
     * ⚠ The stage exclusion lives in the SELECTOR (`OpportunitySelector.CLOSED_STAGES`), not
     * here. Filtering in Apex after the fact would take the LIMIT before the filter and
     * return fewer than five whenever a closed deal happened to be large — the classic
     * order-of-operations defect, and one no test with a small fixture would catch.
     *
     * @return Up to five deal rows, largest `Amount` first, amount-less deals last.
     *         Empty when nothing matches. Never null.
     */
    @AuraEnabled(cacheable=true)
    public static List<TopDealRow> getTopDeals() {
        try {
            List<TopDealRow> rows = new List<TopDealRow>();
            for (Opportunity o : OpportunitySelector.selectTopByAmount(TOP_N)) {
                TopDealRow r = new TopDealRow();
                r.id = o.Id;
                r.name = o.Name;
                r.stage = o.StageName;
                r.dealType = o.Deal_Type__c;
                r.assetType = o.Asset_Type__c;
                r.amount = o.Amount;
                r.closeDate = o.CloseDate;
                r.days = o.CreatedDate.date().daysBetween(Date.today());
                rows.add(r);
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'TopDealsController.getTopDeals: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /** One row of the card. Member names are the LWC wire contract — do not rename casually. */
    public class TopDealRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String stage;
        @AuraEnabled public String dealType;
        @AuraEnabled public String assetType;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Date closeDate;
        @AuraEnabled public Integer days;
    }
}
