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
 * SCOPE NOTE — both queries are intentionally unfiltered full-object reads: the
 * Sell Meter is a portfolio-wide widget, so it reads every asset. This mirrors the
 * relocated SellMeterController statements verbatim (no WHERE, no LIMIT); the scan
 * is preserved rather than changed, per the wave-E "relocate SOQL only" scope.
 *
 * @see WireSelector.cls (P4 Module D pilot template)
 */
public with sharing class PropertyAssetSelector {

    /**
     * Every Property Asset with just the fields the readiness-band roll-up needs —
     * backs SellMeterController.getMeterSummary. No ordering: the caller only
     * aggregates (counts per band and sums portfolio upside), so order is
     * irrelevant.
     *
     * @return All Property_Asset__c records with NOI__c, Market_Cap_Rate__c,
     *         Target_Sale_Price__c and Peak_Sell_Date__c; an empty list when there
     *         are no assets.
     * @example
     * for (Property_Asset__c a : PropertyAssetSelector.selectAllForMeterSummary()) { ... }
     */
    public static List<Property_Asset__c> selectAllForMeterSummary() {
        return [
            SELECT NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Peak_Sell_Date__c
            FROM Property_Asset__c
            WITH USER_MODE
        ];
    }

    /**
     * Every Property Asset, name-ordered, with the full field set the Sell Meter
     * portfolio table renders — backs SellMeterController.getPortfolio. ORDER BY
     * Name is preserved from the original query so the table stays alphabetised.
     *
     * @return All Property_Asset__c records ordered by Name, with the portfolio
     *         field set (Id, Name, Property__r.Asset_Type__c, NOI__c,
     *         Market_Cap_Rate__c, Target_Sale_Price__c, Argus_Signal__c,
     *         Peak_Sell_Date__c, Projected_Value_at_Peak__c) populated; an empty
     *         list when there are no assets.
     */
    public static List<Property_Asset__c> selectAllForPortfolio() {
        return [
            SELECT Id, Name, Property__r.Asset_Type__c,
                   NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Argus_Signal__c,
                   Peak_Sell_Date__c, Projected_Value_at_Peak__c
            FROM Property_Asset__c
            WITH USER_MODE
            ORDER BY Name
        ];
    }
}
