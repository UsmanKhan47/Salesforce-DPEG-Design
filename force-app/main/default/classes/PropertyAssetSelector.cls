/**
 * Selector for Property_Asset__c. Encapsulates ALL SOQL against Property_Asset__c
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * P4 cleanup wave E (Disposition module). Consumers:
 *   - SellMeterController.getMeterSummary -> selectAllForMeterSummary
 *   - SellMeterController.getPortfolio    -> selectAllForPortfolio
 *   - DispositionService.findOrCreate     -> selectPeakSellDateById
 *
 * MODE — every query uses `WITH USER_MODE` (API 67). Property_Asset__c is a custom
 * object; P3 proved the custom-field FLS gap is 0, so USER_MODE is safe and
 * enforces the running user's sharing + FLS. There is no guest path here, so no
 * SYSTEM_MODE appears.
 *
 * ⚠ selectPeakSellDateById is USER_MODE and does NOT belong in ARCHITECTURE.md §2's
 * SYSTEM_MODE automation-path table. It backs a read the user explicitly requested by
 * clicking Initiate/Override on the Sell Meter — no trigger, no queueable, no batch. A
 * USER_MODE denial there is a real provisioning gap the user should see, not a silently
 * disabled automation.
 *
 * NOT-FOUND CONTRACT is per-caller and encoded in the method shape:
 *   - read-for-display (selectAllForMeterSummary / selectAllForPortfolio) -> portfolio
 *     scans the caller iterates, so each returns its natural empty List, never null.
 *   - fetch-for-use    (selectPeakSellDateById) -> the caller reads a field off the
 *     result immediately, so a miss is an error. A single-row SOQL assignment throws the
 *     native System.QueryException, matching OpportunitySelector.selectStageRequiredById
 *     and the contract documented in DispositionSelector's header.
 *
 * SELL-CANDIDATE FILTER — both queries share the SAME predicate:
 *     Property__c != null AND Peak_Sell_Date__c != null
 * so the top summary widgets (selectAllForMeterSummary) and the list
 * (selectAllForPortfolio) always agree. Rationale: the Sell Meter is a
 * disposition-evaluation widget, not a raw dump of every Property_Asset__c row.
 * An asset with a null Property__c is an un-parented seed/junk record, and
 * Peak_Sell_Date__c is the field that drives the readiness band
 * (SellMeterService.bandForPeak) — an asset with no peak date is not yet
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

    /**
     * The peak sell date for ONE Property Asset — backs the server-side sell-meter gate
     * in DispositionService.findOrCreate (the create branch only).
     *
     * FETCH-FOR-USE: the caller feeds Peak_Sell_Date__c straight into
     * SellMeterService.bandForPeak, so an Id that resolves to no row is an error, not a
     * normal state. The single-row SOQL assignment throws the native
     * System.QueryException, which the controller maps to its generic write-failure
     * message — deliberately NOT the sell-meter refusal wording, because a missing asset
     * is a platform failure and a red band is a designed refusal.
     *
     * ⚠ The field list is deliberately MINIMAL (Id + Peak_Sell_Date__c). This query runs
     * on every disposition CREATE, so every field added here becomes a new way for a
     * legitimate creation to be refused by an FLS gap under WITH USER_MODE. The gate needs
     * one field; it selects one field.
     *
     * ⚠ Note this method has NO sell-candidate filter, unlike its two siblings. Those
     * filter to Property__c != null AND Peak_Sell_Date__c != null because they paint the
     * meter; this one must be able to READ a null peak date, because a null peak is
     * precisely what bands RED and refuses the creation. Adding the filter here would turn
     * a refusal into a QueryException and the wrong error message.
     *
     * @param assetId Property_Asset__c Id to read; must reference an existing row.
     * @return The Property_Asset__c with Id and Peak_Sell_Date__c populated
     *         (Peak_Sell_Date__c may itself be null).
     * @throws System.QueryException when no Property_Asset__c matches the Id.
     * @example
     * Property_Asset__c a = PropertyAssetSelector.selectPeakSellDateById(assetId);
     * String band = SellMeterService.bandForPeak(a.Peak_Sell_Date__c);
     */
    public static Property_Asset__c selectPeakSellDateById(Id assetId) {
        return [
            SELECT Id, Peak_Sell_Date__c
            FROM Property_Asset__c
            WHERE Id = :assetId
            WITH USER_MODE
            LIMIT 1
        ];
    }
}
