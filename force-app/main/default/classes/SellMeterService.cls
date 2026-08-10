/**
 * The single source of truth for the Sell Meter readiness band.
 *
 * ONE BAND FUNCTION, TWO CALLERS. bandForPeak was previously a private method on
 * SellMeterController, so the readiness band existed only on the READ path that
 * paints the dashboard. The write path (DispositionService.findOrCreate) had no
 * band at all, which is why the red-band block lived exclusively in
 * lwc/sellMeterList (`actionDisabled: meter === 'RED'`) and was bypassed by any
 * caller invoking the @AuraEnabled method directly. Moving the function here and
 * having BOTH the controller and the service call it makes it structurally
 * impossible for the client's band and the server's gate to disagree.
 *
 * ⚠ bandForPeak's BODY IS A VERBATIM MOVE from SellMeterController — the
 * thresholds (<= 30 GREEN, <= 90 YELLOW, else RED; null peak -> RED) are an exact
 * match to the client document and are the one part of this module already
 * verified correct. Do not "tidy" or re-tune them here. Any change to a threshold
 * changes what the dashboard shows AND what the server refuses, in lockstep, which
 * is the point.
 *
 * No SOQL, no DML, no state — a pure function plus its band constants. The caller
 * supplies the peak sell date (SellMeterController from its portfolio scan,
 * DispositionService from PropertyAssetSelector.selectPeakSellDateById).
 *
 * @see force-app/main/default/classes/SellMeterController.cls (read path)
 * @see force-app/main/default/classes/DispositionService.cls (write gate)
 */
public with sharing class SellMeterService {

    /** Peak sell date is 30 days out or less (including already past) - sell now. */
    public static final String BAND_GREEN = 'GREEN';
    /** Peak sell date is 31-90 days out - getting close; creation is permitted via Override. */
    public static final String BAND_YELLOW = 'YELLOW';
    /** Peak sell date is more than 90 days out, or unknown - hold. */
    public static final String BAND_RED = 'RED';

    /**
     * Maps a peak sell date to a readiness band by days-until-peak:
     *   <= 30 days (including already past) -> GREEN (sell now)
     *   31-90 days                          -> YELLOW (getting close)
     *   > 90 days, or no peak date          -> RED (hold - not yet)
     *
     * A null peak date bands RED deliberately: an asset with no modelled peak is
     * not yet "on the meter", so it is not a sell candidate either.
     *
     * @param peak the asset's Peak_Sell_Date__c; null is allowed and bands RED.
     * @return one of BAND_GREEN / BAND_YELLOW / BAND_RED; never null.
     * @example
     * String band = SellMeterService.bandForPeak(asset.Peak_Sell_Date__c);
     */
    public static String bandForPeak(Date peak) {
        if (peak == null) {
            return BAND_RED;
        }
        Integer days = Date.today().daysBetween(peak);
        if (days <= 30) {
            return BAND_GREEN;
        } else if (days <= 90) {
            return BAND_YELLOW;
        }
        return BAND_RED;
    }
}
