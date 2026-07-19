/**
 * Selector for Property_Asset__c. Encapsulates ALL SOQL against Property_Asset__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumer:
 *   - SellMeterController.getMeterSummary -> selectAllForMeterSummary
 *   - SellMeterController.getPortfolio    -> selectAllForPortfolio
 *
 * MODE — every query uses `WITH USER_MODE` (API 67). Property_Asset__c is a custom
 * object; P3 proved the custom-field FLS gap is 0, so USER_MODE is safe and
 * enforces the running user's sharing + FLS. There is no guest path here, so no
 * SYSTEM_MODE appears.
 *
 * NOT-FOUND CONTRACT — both methods are read-for-display portfolio scans that the
 * caller iterates, so each returns its natural empty List, never null.
 *
 * SELL-CANDIDATE FILTER — both queries share the SAME predicate:
 *     Property__c != null AND Peak_Sell_Date__c != null
 * so the top summary widgets (selectAllForMeterSummary) and the list
 * (selectAllForPortfolio) always agree. Rationale: the Sell Meter is a
 * disposition-evaluation widget, not a raw dump of every Property_Asset__c row.
 * An asset with a null Property__c is an un-parented seed/junk record, and
 * Peak_Sell_Date__c is the field that drives the readiness band
 * (SellMeterController.bandForPeak) — an asset with no peak date is not yet
 * "on the meter". Excluding both keeps the widget to real sell candidates.
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 */
public with sharing class PropertyAssetSelector {

    /**
     * Sell-candidate Property Assets with just the fields the readiness-band
     * roll-up needs — backs SellMeterController.getMeterSummary. Filtered to
     * Property__c != null AND Peak_Sell_Date__c != null (see class header) so the
     * summary counts match the getPortfolio list exactly. No ordering: the caller
     * only aggregates (counts per band and sums portfolio upside), so order is
     * irrelevant.
     *
     * @return Sell-candidate Property_Asset__c records (non-null Property and
     *         Peak_Sell_Date) with NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c
     *         and Peak_Sell_Date__c; an empty list when none qualify.
     * @example
     * for (Property_Asset__c a : PropertyAssetSelector.selectAllForMeterSummary()) { ... }
     */
    public static List<Property_Asset__c> selectAllForMeterSummary() {
        return [
            SELECT NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Peak_Sell_Date__c
            FROM Property_Asset__c
            WHERE Property__c != null AND Peak_Sell_Date__c != null
            WITH USER_MODE
        ];
    }

    /**
     * Sell-candidate Property Assets, name-ordered, with the full field set the
     * Sell Meter portfolio table renders — backs SellMeterController.getPortfolio.
     * Filtered to Property__c != null AND Peak_Sell_Date__c != null (see class
     * header) so the list matches the summary counts exactly. ORDER BY Name keeps
     * the table alphabetised.
     *
     * @return Sell-candidate Property_Asset__c records (non-null Property and
     *         Peak_Sell_Date) ordered by Name, with the portfolio field set (Id,
     *         Name, Property__r.Asset_Type__c, NOI__c, Market_Cap_Rate__c,
     *         Target_Sale_Price__c, Argus_Signal__c, Peak_Sell_Date__c,
     *         Projected_Value_At_Peak__c) populated; an empty list when none qualify.
     */
    public static List<Property_Asset__c> selectAllForPortfolio() {
        return [
            SELECT Id, Name, Property__r.Asset_Type__c,
                   NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Argus_Signal__c,
                   Peak_Sell_Date__c, Projected_Value_At_Peak__c
            FROM Property_Asset__c
            WHERE Property__c != null AND Peak_Sell_Date__c != null
            WITH USER_MODE
            ORDER BY Name
        ];
    }
}
