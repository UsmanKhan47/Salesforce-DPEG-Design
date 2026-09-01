/**
 * Read-only data provider for the Sell Meter dashboard: a portfolio-level readiness
 * roll-up (getMeterSummary) and the per-asset table (getPortfolio). Readiness bands are
 * derived from days-until the peak sell date (see SellMeterService.bandForPeak).
 *
 * ⚠ THE BAND FUNCTION NO LONGER LIVES HERE. bandForPeak was moved VERBATIM to
 * SellMeterService so the write path (DispositionService.findOrCreate's sell-meter gate)
 * and this read path share one implementation and can never disagree. Do not re-add a
 * private copy: a second copy is exactly the drift the move exists to prevent. Thresholds
 * are unchanged (<= 30 GREEN, <= 90 YELLOW, else RED; null peak -> RED).
 *
 * All SOQL is delegated to PropertyAssetSelector per ARCHITECTURE.md §2 — this controller
 * holds no inline SOQL.
 *
 * ⚠ "Read-only: there are no mutation methods here" IS STILL TRUE AND IS QUOTED RATHER THAN
 * DELETED, because `hasOverrideAccess` (2026-08-31) looks like a departure and is not. It writes
 * nothing; it answers a question about the RUNNING USER so the Sell Meter can disable a button it
 * would otherwise render enabled to someone the server is going to refuse. The gate itself is
 * enforced by DispositionService on both create paths — this method is a UX affordance, not the
 * control.
 *
 * Thin controller (P6 controller thinning — boundaries only, no DML to extract). Every
 * @AuraEnabled read wraps its work in a try/catch that maps a failure to a user-safe
 * AuraHandledException at the LWC boundary (ARCHITECTURE.md §5): platform detail goes to
 * the debug log (admin-only) and the user gets a fixed, generic message with no exception
 * detail concatenated into it.
 */
public with sharing class SellMeterController {

    // Fixed, generic user-safe message for a failed read.
    private static final String READ_FAILURE_MESSAGE =
        'The sell meter could not be loaded. Refresh the page or contact your administrator.';

    private static AuraHandledException ahe(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    public class PropertyRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String assetType;
        @AuraEnabled public Decimal noi;
        @AuraEnabled public Decimal mktCapRate;
        @AuraEnabled public Decimal impliedValue;
        @AuraEnabled public Decimal targetPrice;
        @AuraEnabled public Decimal meterScore;
        @AuraEnabled public String sellMeter;
        @AuraEnabled public String argusSignal;
        @AuraEnabled public Date peakSellDate;
        @AuraEnabled public Decimal projectedValueAtPeak;
    }

    public class MeterSummary {
        @AuraEnabled public Integer green = 0;
        @AuraEnabled public Integer yellow = 0;
        @AuraEnabled public Integer red = 0;
        /**
         * PORTFOLIO-WIDE upside: implied value above target across EVERY in-the-money asset on
         * the meter, whatever its band. Rendered as the "Portfolio Upside" card.
         *
         * 🔴 ITS DEFINITION DID NOT CHANGE ON 2026-08-31 AND MUST NOT. Story 9 asked for a
         * green-only figure and the design recommended NARROWING this one and renaming its card.
         * The user decided otherwise at Gate 1: keep this number exactly as it is and ADD the
         * green-only figure BESIDE it (`sellReadyUpside`). Nothing shrank, nothing was renamed,
         * and every pre-existing assertion on this field still means what it meant. Do not
         * "finish" the recommended narrowing later — it was declined, not deferred.
         */
        @AuraEnabled public Decimal upside = 0;
        /**
         * GREEN-BAND-ONLY upside: the same sum restricted to assets whose peak sell date is 30
         * days out or less. Rendered as the "Sell-Ready Upside" card (story 9).
         *
         * ⚠ IT IS ALWAYS <= `upside`, AND THAT RELATIONSHIP IS THE POINT: the pair says "of the
         * total upside on the meter, this much is actionable today". A figure that ever exceeded
         * the portfolio-wide one would mean the two loops had drifted apart.
         *
         * ⚠ IT IS A SECOND FIGURE, NOT A REPLACEMENT, so the Sell Meter Summary card now shows
         * FIVE tiles rather than the four story 9's AC describes. That divergence is the recorded
         * Gate 1 decision (2026-08-31); story 9's substantive AC — a green-only upside figure
         * exists and is shown — is satisfied by the new tile.
         */
        @AuraEnabled public Decimal sellReadyUpside = 0;
    }

    /**
     * Portfolio-level roll-up for the Sell Meter top widgets: how many assets sit
     * in each readiness band, plus the total dollars of implied value above target
     * across in-the-money assets. Band logic mirrors getPortfolio() (days-until the
     * peak sell date, see bandForPeak); assets with no peak date count as Hold (Red).
     *
     * ⚠ TWO UPSIDE FIGURES SINCE 2026-08-31, COMPUTED IN ONE PASS OVER ONE QUERY. Neither
     * widens the SELECT: `NOI__c`, `Market_Cap_Rate__c` and `Target_Sale_Price__c` were already
     * in `selectAllForMeterSummary`, so this is not an FLS change and costs no extra SOQL.
     */
    @AuraEnabled(cacheable=true)
    public static MeterSummary getMeterSummary() {
        try {
            MeterSummary s = new MeterSummary();
            for (Property_Asset__c a : PropertyAssetSelector.selectAllForMeterSummary()) {
                String band = SellMeterService.bandForPeak(a.Peak_Sell_Date__c);
                if (SellMeterService.BAND_GREEN == band) {
                    s.green++;
                } else if (SellMeterService.BAND_YELLOW == band) {
                    s.yellow++;
                } else {
                    s.red++;
                }
                // Portfolio upside = total implied value above target across in-the-money assets.
                //
                // 🔴 THIS `if` IS A SIBLING OF THE BAND `if/else` ABOVE, NOT NESTED INSIDE IT, AND
                // THAT IS DELIBERATE — the portfolio-wide figure counts EVERY band. The green-only
                // figure is derived by the inner band test below rather than by moving this block,
                // so the two can never disagree about which assets are "in the money" (they share
                // one arithmetic) while disagreeing about which are GREEN (which is the whole
                // difference between them).
                if (a.NOI__c != null && a.Market_Cap_Rate__c != null && a.Market_Cap_Rate__c != 0
                    && a.Target_Sale_Price__c != null && a.Target_Sale_Price__c != 0) {
                    Decimal implied = a.NOI__c / (a.Market_Cap_Rate__c / 100);
                    Decimal up = implied - a.Target_Sale_Price__c;
                    if (up > 0) {
                        s.upside += up;
                        // Sell-Ready upside (story 9): the same money, GREEN band only. Compared
                        // against the constant, never the literal 'GREEN' — SellMeterService owns
                        // the three band strings and this file must not hold a fourth copy.
                        if (SellMeterService.BAND_GREEN == band) {
                            s.sellReadyUpside += up;
                        }
                    }
                }
            }
            return s;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'SellMeterController.getMeterSummary: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<PropertyRow> getPortfolio() {
        try {
            List<Property_Asset__c> assets = PropertyAssetSelector.selectAllForPortfolio();
            List<PropertyRow> rows = new List<PropertyRow>();
            for (Property_Asset__c a : assets) {
                PropertyRow r = new PropertyRow();
                r.id = a.Id;
                r.name = a.Name;
                r.assetType = a.Property__r != null ? a.Property__r.Asset_Type__c : null;
                r.noi = a.NOI__c;
                r.mktCapRate = a.Market_Cap_Rate__c;
                r.targetPrice = a.Target_Sale_Price__c;
                r.argusSignal = a.Argus_Signal__c;
                r.peakSellDate = a.Peak_Sell_Date__c;
                r.projectedValueAtPeak = a.Projected_Value_At_Peak__c;
                // Readiness band is driven by days until the peak sell date (see bandForPeak).
                r.sellMeter = SellMeterService.bandForPeak(a.Peak_Sell_Date__c);
                // Implied value / score still computed for the portfolio-upside metric; no longer drive the band.
                if (a.NOI__c != null && a.Market_Cap_Rate__c != null && a.Market_Cap_Rate__c != 0) {
                    r.impliedValue = a.NOI__c / (a.Market_Cap_Rate__c / 100);
                    if (a.Target_Sale_Price__c != null && a.Target_Sale_Price__c != 0) {
                        r.meterScore = r.impliedValue / a.Target_Sale_Price__c;
                    }
                }
                rows.add(r);
            }
            return rows;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'SellMeterController.getPortfolio: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }

    /**
     * Whether the running user may press Override on a YELLOW (31-90 days to peak) Sell Meter row
     * — story 12 / 14, Tranche 2 item 5a.
     *
     * 🔴 THIS IS A UX AFFORDANCE. IT IS NOT THE GATE. The gate is
     * `SellMeterOverridePermissionService.assertSellMeterOverrideAccess()`, asserted server-side on
     * the YELLOW branch of BOTH `DispositionService` create paths. This method exists only so
     * `lwc/sellMeterList` can render the Override button DISABLED rather than enabled-then-refused
     * (design decision D-11: a non-principal still sees the button, still labelled "Override",
     * mirroring the existing RED "Hold" idiom, so they can see the action exists and who to ask).
     * Deleting it degrades the experience; it does not open a hole.
     *
     * ⚠ `cacheable=true` IS SAFE HERE AND IS NOT A SECURITY DECISION. The answer is a property of
     * the running user, is identical for every row, and cannot change mid-session in a way the
     * server would honour anyway — the server re-asks on every write. A stale `true` in the LWDS
     * cache buys an attacker an enabled button and a server refusal.
     *
     * ⚠ THE GATE IS CRITERIA-BASED, NOT RECORD-BASED, WHICH IS WHY THE USUAL LWC-GATE TRAP DOES
     * NOT APPLY. This repo has a measured incident where `getObjectInfo.updateable` was used as a
     * client gate and could not see SHARING, so a button rendered enabled on 47 of 48 records.
     * `FeatureManagement.checkPermission` asks a question about the USER, so the answer is the same
     * for every row and there is no record context to miss. Do NOT "improve" this into a per-record
     * check — there is no per-record fact to check.
     *
     * ⚠ FAIL CLOSED ON THE CLIENT TOO. The service THROWS on a permission-machinery fault rather
     * than returning false, and that throw is masked here behind the fixed read-failure message;
     * `sellMeterList` treats a wire error exactly like `false`, so the button stays disabled. The
     * wire also resolves asynchronously, so the LWC defaults the flag to `false` — disabled during
     * the round trip, never enabled-then-disabled.
     *
     * @return true when the running user holds `Disposition_Sell_Meter_Override` or "Modify All
     *         Data"; false otherwise.
     * @throws AuraHandledException carrying the fixed generic read-failure message when the
     *         permission lookup itself faults. Never carries platform detail.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean hasOverrideAccess() {
        try {
            return SellMeterOverridePermissionService.hasSellMeterOverrideAccess();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'SellMeterController.hasOverrideAccess: '
                + e.getMessage() + ' | ' + e.getStackTraceString());
            throw ahe(READ_FAILURE_MESSAGE);
        }
    }
}
