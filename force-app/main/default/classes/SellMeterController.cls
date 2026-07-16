public with sharing class SellMeterController {

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
        MeterSummary s = new MeterSummary();
        for (Property_Asset__c a : PropertyAssetSelector.selectAllForMeterSummary()) {
            String band = bandForPeak(a.Peak_Sell_Date__c);
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
    }

    // Maps a peak sell date to a readiness band by days-until-peak:
    //   <= 30 days (including already past) → GREEN (sell now)
    //   31-90 days                          → YELLOW (getting close)
    //   > 90 days, or no peak date          → RED (hold - not yet)
    private static String bandForPeak(Date peak) {
        if (peak == null) {
            return 'RED';
        }
        Integer days = Date.today().daysBetween(peak);
        if (days <= 30) {
            return 'GREEN';
        } else if (days <= 90) {
            return 'YELLOW';
        }
        return 'RED';
    }

    @AuraEnabled(cacheable=true)
    public static List<PropertyRow> getPortfolio() {
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
            r.projectedValueAtPeak = a.Projected_Value_at_Peak__c;
            // Readiness band is driven by days until the peak sell date (see bandForPeak).
            r.sellMeter = bandForPeak(a.Peak_Sell_Date__c);
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
    }
}