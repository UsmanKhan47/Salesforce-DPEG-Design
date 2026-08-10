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
 * holds no inline SOQL. Read-only: there are no mutation methods here.
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
        @AuraEnabled public Decimal upside = 0;
    }

    /**
     * Portfolio-level roll-up for the Sell Meter top widgets: how many assets sit
     * in each readiness band, plus the total dollars of implied value above target
     * across in-the-money assets. Band logic mirrors getPortfolio() (days-until the
     * peak sell date, see bandForPeak); assets with no peak date count as Hold (Red).
     */
    @AuraEnabled(cacheable=true)
    public static MeterSummary getMeterSummary() {
        try {
            MeterSummary s = new MeterSummary();
            for (Property_Asset__c a : PropertyAssetSelector.selectAllForMeterSummary()) {
                String band = SellMeterService.bandForPeak(a.Peak_Sell_Date__c);
                if (band == 'GREEN') {
                    s.green++;
                } else if (band == 'YELLOW') {
                    s.yellow++;
                } else {
                    s.red++;
                }
                // Portfolio upside = total implied value above target across in-the-money assets.
                if (a.NOI__c != null && a.Market_Cap_Rate__c != null && a.Market_Cap_Rate__c != 0
                    && a.Target_Sale_Price__c != null && a.Target_Sale_Price__c != 0) {
                    Decimal implied = a.NOI__c / (a.Market_Cap_Rate__c / 100);
                    Decimal up = implied - a.Target_Sale_Price__c;
                    if (up > 0) {
                        s.upside += up;
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
}
