/**
 * Read-only data provider for the "Top 5 Largest Deals" home-page card
 * (`lwc/topLargestDeals`) — FSD §24.2: *the five biggest active deals, any stage except
 * Closed*.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * 🔴 RE-RANKED ONTO `Asking_Price__c` AND CUT TO TWO COLUMNS (user decision, 2026-08-17)
 * ═════════════════════════════════════════════════════════════════════════════
 * The card shows **Property Name and Asking Price, and nothing else**, ranked by
 * `Asking_Price__c`. That is a deliberate change to the question it answers, taken with the
 * alternatives on the table: "the five highest ASKING PRICES among active deals", not "the
 * five biggest deal Amounts". Different deals appear.
 *
 * ⚠ RETRACTED, verbatim, so the next reader cannot restore it from the argument:
 *
 *     "**THAT WAS OVERRULED BY THE USER (2026-08-16): the two stay SEPARATE, and this one
 *      ranks on `Opportunity.Amount`.** ... ⇒ Do NOT 'consolidate' these two cards, and do
 *      NOT re-point this controller at `selectTopByAskingPrice`. Either change silently
 *      turns this card into a duplicate of a card that is already on the same page."
 *
 * 🔴 WHAT SURVIVES OF THAT ARGUMENT, AND WHAT DOES NOT. The two cards now rank on the SAME
 * field, so "they answer different questions" is no longer the separation. What still
 * separates them is narrower and is the FSD requirement itself:
 *
 *   `lwc/recentOpportunities`  every stage, closed deals included; Asking Price + NOI.
 *   `lwc/topLargestDeals`      ACTIVE deals only — `OpportunitySelector.CLOSED_STAGES`
 *                              excluded, which IS FSD §24.2; Property Name + Asking Price.
 *
 * ⇒ The tranche-2 proposal (add the stage filter to `selectTopByAskingPrice` and relabel
 *   the existing card) is STILL not available: it would break that method's own caller,
 *   which shows deals at any stage. `lwc/recentOpportunities`,
 *   `OpportunityFunnelController.getRecentOpportunities` and
 *   `OpportunitySelector.selectTopByAskingPrice` remain UNTOUCHED.
 *
 * ⚠ THE SELECTOR METHOD WAS RENAMED WITH THE RANKING: `selectTopByAmount` →
 * `selectTopActiveByAskingPrice`. A method named for a field it no longer orders by is the
 * stale-header defect ARCHITECTURE.md §2 records for `LoiSelector` / `NdaSelector`; this
 * controller was its only production caller, so the rename cost one call site.
 *
 * ═════════════════════════════════════════════════════════════════════════════
 * "PROPERTY NAME" IS `Opportunity.Name`, RELABELLED — NOT `Property__r.Name`
 * ═════════════════════════════════════════════════════════════════════════════
 * User decision, 2026-08-17. `LeadConvertService` names the deal after the property
 * (marketing name, else the address), so `Name` already IS the property name on every
 * lead-converted deal. Traversing would add a cross-object CRUD/FLS dependency under
 * `WITH USER_MODE` — which throws for the WHOLE ROW rather than blanking one column — and
 * would render an empty cell on any deal with a null `Property__c`. `OpportunitySelector`'s
 * call-for-offers block comment records the identical decision for that surface.
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
 * ⚠ THE MOST LIKELY REASON THIS CARD ERRORS IN PRODUCTION IS AN FLS GAP — the read selects
 * `Asking_Price__c`, and `selectTopActiveByAskingPrice` is `WITH USER_MODE` — correctly,
 * because this backs a read a human asked for — so it throws on the WHOLE ROW for ONE
 * inaccessible field. The remedy is a permission-set grant, NOT a mode change; the full
 * argument is at the selector method. The failure is LOUD (the card renders its error
 * banner), which is the intended posture.
 *
 * ✅ THAT SURFACE SHRANK ON 2026-08-17. This paragraph used to name `Amount` (a
 * PERMISSIONABLE standard field), `Deal_Type__c` and `Asset_Type__c` as well; the two-column
 * cut removed the columns that read them, and the SELECT with them. `Asking_Price__c` is
 * granted on `DPEG_Acquisition_Edit` / `DPEG_Acquisition_View` / `DPEG_Opportunity_View`,
 * and `selectTopByAskingPrice` has read it in production for months, so it is the
 * best-proven field this card could depend on.
 *
 * ⚠ HISTORICAL, kept because it is the REASON the `Opportunity.Amount` grants exist rather
 * than a live dependency of this class: `Amount` was found granted by NO permission set in
 * this repo on 2026-08-16 (it appeared only in `profiles/**`, which is `.forceignore`d and
 * never deploys), and the remedy was applied and verified in SOURCE on 2026-08-17. 🔴 This
 * controller no longer reads `Amount` at all — do not re-raise that gate, and do not infer
 * from its closure that anything here still depends on it.
 *
 * ⚠ STILL TRUE: a persona holding none of those sets is denied BY DESIGN, and that denial
 * arriving as the fixed message below (never a raw `QueryException`) is pinned by
 * `TopDealsControllerTest.anUnprovisionedPersonaGetsTheUserSafeMessageNotARawQueryException`.
 */
public with sharing class TopDealsController {

    /** How many deals the card shows. FSD §24.2 says five. */
    @TestVisible
    private static final Integer TOP_N = 5;

    /**
     * Fixed, generic user-safe message for a failed read.
     *
     * ⚠ It names no field and no exception. An FLS denial arrives as
     * `System.QueryException: No such column 'Asking_Price__c'`, which reads to a user as a
     * broken app rather than a permissions gap — surfacing it would misdirect rather than
     * help.
     *
     * 🔴 IT IS DUPLICATED VERBATIM IN `TopDealsControllerTest` (this constant is private and
     * not `@TestVisible`) BECAUSE IT IS THE CLIENT-FACING WIRE CONTRACT. Changing the wording
     * should require a deliberate edit in two places. The re-ranking of 2026-08-17 did NOT
     * change it: the message says nothing about how the list is ordered.
     */
    private static final String READ_FAILURE_MESSAGE =
        'The largest deals could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * The five highest ACTIVE deals by `Asking_Price__c`, highest first.
     *
     * ⚠ The stage exclusion lives in the SELECTOR (`OpportunitySelector.CLOSED_STAGES`), not
     * here. Filtering in Apex after the fact would take the LIMIT before the filter and
     * return fewer than five whenever a closed deal happened to be expensive — the classic
     * order-of-operations defect, and one no test with a small fixture would catch.
     *
     * ⚠ `name` IS THE OPPORTUNITY NAME AND THE CARD LABELS IT "Property Name". That is the
     * user's decision of 2026-08-17, argued in the class header — no traversal happens here
     * and none should be added.
     *
     * @return Up to five deal rows, highest `Asking_Price__c` first, price-less deals last.
     *         Empty when nothing matches. Never null.
     */
    @AuraEnabled(cacheable=true)
    public static List<TopDealRow> getTopDeals() {
        try {
            List<TopDealRow> rows = new List<TopDealRow>();
            for (Opportunity o : OpportunitySelector.selectTopActiveByAskingPrice(TOP_N)) {
                TopDealRow r = new TopDealRow();
                r.id = o.Id;
                r.name = o.Name;
                r.askingPrice = o.Asking_Price__c;
                rows.add(r);
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'TopDealsController.getTopDeals: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * One row of the card. Member names are the LWC wire contract — do not rename casually.
     *
     * ⚠ IT IS EXACTLY AS WIDE AS THE CARD, DELIBERATELY. The 2026-08-17 two-column cut
     * removed `stage`, `dealType`, `assetType`, `amount`, `closeDate` and `days` because
     * nothing consumes them any more. Leaving them would have been worse than untidy: every
     * one of them costs a field in the selector's `WITH USER_MODE` SELECT, and USER_MODE
     * throws on the WHOLE ROW for ONE inaccessible field — so an unread member is a live way
     * for the card to fail for a persona, in exchange for nothing on screen. `assetType` was
     * already such a member before this change and is the reason the rule is written down.
     *
     * ⇒ Adding a member here means adding its field to
     * `OpportunitySelector.selectTopActiveByAskingPrice`, and that method's header lists the
     * three permission sets whose grants must then be re-verified.
     */
    public class TopDealRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal askingPrice;
    }
}
