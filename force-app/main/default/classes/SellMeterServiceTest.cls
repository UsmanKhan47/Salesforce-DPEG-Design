/**
 * @description Tests SellMeterService.bandForPeak — the readiness-band function moved
 * VERBATIM out of SellMeterController so the dashboard's band and the server-side
 * disposition gate share one implementation.
 *
 * WHAT THESE TESTS ARE FOR. bandForPeak's thresholds are an exact match to the client
 * document and are the one part of this module already verified correct, so this suite is
 * a REGRESSION FENCE around them rather than a discovery exercise. Every boundary is
 * pinned on BOTH sides (30/31 and 90/91), so a future "tidy" that turns <= into < goes red
 * here instead of silently changing what the dashboard shows AND what the server refuses.
 *
 * NO DML, NO SOQL, NO FIXTURES. bandForPeak is a pure function of (today, peak), so every
 * case is a direct call with a relative date. That is also why there is no bulk scenario:
 * .claude/rules/bulk-test-rule.md targets triggers, batches and DML-performing services,
 * and a pure function has no per-record cost to expose at 251. Its bulk behaviour is
 * covered where it actually loops — SellMeterControllerTest's 251-asset portfolio test.
 *
 * @see force-app/main/default/classes/SellMeterService.cls
 * @see force-app/main/default/classes/SellMeterControllerTest.cls (the 251-asset loop)
 */
@isTest
private class SellMeterServiceTest {

    @isTest
    static void bandForPeak_nullPeak_isRed() {
        Assert.areEqual(
            SellMeterService.BAND_RED,
            SellMeterService.bandForPeak(null),
            'An asset with no modelled peak sell date is not on the meter, so it bands RED'
        );
    }

    @isTest
    static void bandForPeak_pastPeak_isGreen() {
        Assert.areEqual(
            SellMeterService.BAND_GREEN,
            SellMeterService.bandForPeak(Date.today().addDays(-400)),
            'A peak date already in the past is at or past peak, so it bands GREEN (sell now)'
        );
    }

    @isTest
    static void bandForPeak_today_isGreen() {
        Assert.areEqual(
            SellMeterService.BAND_GREEN,
            SellMeterService.bandForPeak(Date.today()),
            'Zero days to peak bands GREEN'
        );
    }

    // ── GREEN / YELLOW boundary. Both sides pinned so <= 30 cannot silently become < 30. ──

    @isTest
    static void bandForPeak_exactly30Days_isGreen() {
        Assert.areEqual(
            SellMeterService.BAND_GREEN,
            SellMeterService.bandForPeak(Date.today().addDays(30)),
            'Exactly 30 days out is still GREEN (the threshold is <= 30, not < 30)'
        );
    }

    @isTest
    static void bandForPeak_31Days_isYellow() {
        Assert.areEqual(
            SellMeterService.BAND_YELLOW,
            SellMeterService.bandForPeak(Date.today().addDays(31)),
            'One day past the GREEN threshold is YELLOW'
        );
    }

    // ── YELLOW / RED boundary. Same treatment: this is the line the server gate refuses on. ──

    @isTest
    static void bandForPeak_exactly90Days_isYellow() {
        Assert.areEqual(
            SellMeterService.BAND_YELLOW,
            SellMeterService.bandForPeak(Date.today().addDays(90)),
            'Exactly 90 days out is still YELLOW (the threshold is <= 90, not < 90)'
        );
    }

    @isTest
    static void bandForPeak_91Days_isRed() {
        Assert.areEqual(
            SellMeterService.BAND_RED,
            SellMeterService.bandForPeak(Date.today().addDays(91)),
            'One day past the YELLOW threshold is RED - and RED is what DispositionService refuses'
        );
    }

    /**
     * The band constants are not decoration: DispositionService compares against
     * BAND_RED and lwc/sellMeterList keys its METER map on the same three literals.
     * Pinning the STRING VALUES here means a rename of a constant cannot silently
     * desynchronise the Apex gate from the client's colour map.
     */
    @isTest
    static void bandConstants_areTheLiteralsTheClientKeysOn() {
        Assert.areEqual('GREEN', SellMeterService.BAND_GREEN, 'lwc/sellMeterList METER keys on the literal GREEN');
        Assert.areEqual('YELLOW', SellMeterService.BAND_YELLOW, 'lwc/sellMeterList METER keys on the literal YELLOW');
        Assert.areEqual('RED', SellMeterService.BAND_RED, 'lwc/sellMeterList METER keys on the literal RED');
    }
}
