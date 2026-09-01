// ─────────────────────────────────────────────────────────────────────────────
// Sell-signal backfill for the 18 statusless Property_Asset__c rows — 2026-08-29.
//
// WHY: the demo org `usman-dpeg` holds 23 Active Property_Asset__c rows, but only 5
// carry a sell-meter signal (Copperfield Town Center, Universal City Retail Row,
// Terrell Hills Medical Plaza, Windcrest Business Park, Canyon Lake Land Holdings —
// stamped by seed-sell-readiness.apex + seed-sell-meter.apex). The other 18 have
// Argus_Signal__c and Sell_Readiness_Score__c blank, so they render statusless in the
// Sell Meter / Disposition app. This script gives those 18 a coherent status.
//
// ⚠ IT NEVER TOUCHES THE 5 EXISTING ONES. The filter is `Argus_Signal__c == null`,
// which is also what makes the script idempotent: a second run selects nothing and
// exits as a loud, labelled no-op. The demo narrative depends on the existing 5
// (2 GREEN / 1 YELLOW / 2 RED on the meter today) staying exactly as they are.
//
// UPDATE-ONLY. No inserts, no deletes. ONE DML for the whole collection; no SOQL and
// no DML inside any loop.
//
// ── FIELD SAFETY (verified against force-app/main/default/objects/Property_Asset__c/fields/) ──
// WRITTEN (all plain, writable, non-formula):
//   Argus_Signal__c              Picklist, restricted=true, values EXACTLY
//                                {Sell Now, 12 mo, Hold} — DML-enforced on this
//                                project, so every literal below is one of those three.
//   Sell_Readiness_Score__c      Percent(3,0)   — integer 0-999; we write 30-92.
//   Argus_Value__c               Currency(18,2)
//   NOI__c                       Currency(18,2)
//   Market_Cap_Rate__c           Percent(5,2)   — we write 6.00-7.85.
//   Peak_Sell_Date__c            Date
//   Projected_Value_At_Peak__c   Currency(18,0) — scale 0, hence .setScale(0) below.
//   Target_Sale_Price__c         Currency(18,2)
//   Property_Type__c             Picklist (NOT restricted), values EXACTLY
//                                {Retail, Industrial, Multifamily, Office, Mixed-Use}
//                                — written ONLY where it is currently null.
//
// 🔴 DELIBERATELY NOT WRITTEN — these are FORMULA fields and any write attempt would
// fail at runtime, mid-script, after earlier DML in the same statement:
//   Readiness_Score__c       formula: IF(ISPICKVAL(Argus_Signal__c,"Sell Now"),1,0)
//   Sell_Readiness_Band__c   formula: CASE(TEXT(Argus_Signal__c), ...)
//   Property_Name__c         formula: Name
// [RETRACTED 2026-08-31, Disposition Gap Closure TRANCHE 2 item 1a/1b — see
//  agent-output/disposition-gap-closure-t2-design.md §3 item 1. THE TWO FORMULAS QUOTED ABOVE
//  ARE NO LONGER CURRENT and the line below ("They are DERIVED from Argus_Signal__c...") is now
//  FALSE for Sell_Readiness_Band__c/Readiness_Score__c — kept struck-through, not deleted:]
// [FALSE AS OF 2026-08-31] They are DERIVED from Argus_Signal__c, so stamping the signal
// populates them for free. [END FALSE]
// CORRECTED: Sell_Readiness_Band__c now derives from Peak_Sell_Date__c (days-until-peak,
// mirroring SellMeterService.bandForPeak — <=30 GREEN/"Sell now", <=90 YELLOW/"Getting Close",
// else or null RED/"Hold - Not yet"), and Readiness_Score__c now derives from
// Sell_Readiness_Band__c. Argus_Signal__c drives neither formula any longer. Property_Name__c
// (formula: Name) is UNCHANGED and still derives from what this script writes.
// This script still populates both fields "for free" in practice, but through a DIFFERENT
// mechanism than stated above: it also writes Peak_Sell_Date__c (line ~28 below), which is what
// now drives Sell_Readiness_Band__c. The signal (Argus_Signal__c) and the resulting band are no
// longer guaranteed to tell the same story — see this script's "BANDS" section further down,
// which already computes bands independently from the peak dates chosen here.
//
// ALSO NOT WRITTEN, on purpose:
//   Status__c            — all 23 rows are already Active; instructed not to touch it.
//   Closing_Date__c      — 🔴 see the trigger note below. Writing it would have side effects.
//   Vacant_Area__c, Final_Purchase_Price__c, Property__c — out of scope for the sell meter.
//
// ── TRIGGER SIDE EFFECTS: NONE (checked, not assumed) ──
// PropertyAssetTrigger -> PropertyAssetTriggerHandler.afterUpdate ->
// OnboardingAutoCreateService.ensureOnClosing, whose discriminator is a TRANSITION of
// Closing_Date__c to non-null. This script does not write Closing_Date__c, so the guard
// returns before any read: 0 extra SOQL, 0 extra DML, and no Onboarding__c rows minted.
//
// ── INTERNAL CONSISTENCY (mirrors seed-sell-meter.apex, inverted) ──
// seed-sell-meter.apex picks NOI + cap so that NOI / (cap/100) lands EXACTLY on the
// Argus_Value__c that seed-sell-readiness.apex wrote (verified on all 5 existing rows,
// e.g. Copperfield 1,608,000 / 0.06 = 26,800,000). This script states the round
// Argus_Value__c and the cap rate and DERIVES NOI = value * cap / 100, which is the same
// relationship expressed the other way round and cannot drift through a typo. Then, as in
// seed-sell-meter.apex:
//     target    = argusValue * targetDiscount   (0.87-0.95, below fair value, so the
//                                                portfolio-upside tile shows a positive number)
//     projected = target * uplift               (1.05-1.10, above target)
//
// ── BANDS: what this does to the Sell Meter ──
// PropertyAssetSelector filters the meter to `Property__c != null AND Peak_Sell_Date__c
// != null`, and SellMeterService.bandForPeak bands on days-until-peak:
// <= 30 GREEN, 31-90 YELLOW, > 90 (or null) RED. Peak dates below are set relative to
// TODAY and ordered Sell Now (soonest) < 12 mo < Hold (furthest out), so the signal and
// the band tell the same story. The 18 contribute 4 GREEN / 5 YELLOW / 9 RED, giving a
// full-portfolio meter of 6 GREEN / 6 YELLOW / 11 RED — for whichever of the 18 carry a
// Property__c lookup; the final debug reports how many do, since a row without one is
// invisible to the meter no matter what we stamp on it.
// [NOTE 2026-08-31, Disposition Gap Closure TRANCHE 2, S4 — the 6/6/11 stated just above
//  disagrees with the 5/7/11 implied by the "SIGNAL DISTRIBUTION" section below. This is
//  the exact contradiction the Tranche 2 design cited as the reason no band count in this
//  repo is quotable; the Tranche 2 pass edited this file (the CORRECTED block above) and
//  left the contradiction unmarked until now. NEITHER figure is trustworthy — do not
//  compute or guess which is "right"; this script is time-relative (bands are derived from
//  TODAY() at run time via Peak_Sell_Date__c, see Sell_Readiness_Band__c.field-meta.xml),
//  so there is no correct static answer. Band counts must be MEASURED in the org (query
//  Property_Asset__c.Sell_Readiness_Band__c directly), never quoted from this comment.]
//
// ── SIGNAL DISTRIBUTION CHOSEN FOR THE 18 ──
//   4 x Sell Now  (score band 80-92)
//   6 x 12 mo     (score band 55-70)
//   8 x Hold      (score band 30-50)
// Plus the untouched 5 (1 Sell Now / 1 12 mo / 3 Hold) = 5 / 7 / 11 across all 23.
//
// ⚠ SIX OF THE 18 ARE NAME-TWINS ("Bayou Bend Center" / "Bayou Bend Center Asset", and
// the same for Heights Marketplace, Katy Mills Strip, Magnolia Commons, Sterling
// Crossing, Westgate Plaza). Each twin pair is given the SAME Argus_Signal__c — a demo
// viewer reading "Westgate Plaza = Sell Now, Westgate Plaza Asset = Hold" would report it
// as a bug. Their scores and values differ so the rows are still distinguishable.
// ─────────────────────────────────────────────────────────────────────────────

// ── Parallel data keyed by Name (same shape as seed-sell-meter.apex) ──────────
// Every literal here is one of the three restricted Argus_Signal__c values.
Map<String, String> signalByName = new Map<String, String>{
    'Westgate Plaza'             => 'Sell Now',
    'Westgate Plaza Asset'       => 'Sell Now',
    'Sunridge Marketplace'       => 'Sell Now',
    'Cypresswood Retail'         => 'Sell Now',
    'Heights Marketplace'        => '12 mo',
    'Heights Marketplace Asset'  => '12 mo',
    'Park North Retail'          => '12 mo',
    'Katy Mills Strip'           => '12 mo',
    'Katy Mills Strip Asset'     => '12 mo',
    'Sunset Mixed-Use'           => '12 mo',
    'Sterling Crossing'          => 'Hold',
    'Sterling Crossing Asset'    => 'Hold',
    'Bayou Bend Center'          => 'Hold',
    'Bayou Bend Center Asset'    => 'Hold',
    'Magnolia Commons'           => 'Hold',
    'Magnolia Commons Asset'     => 'Hold',
    'Oak Street Center'          => 'Hold',
    'Riverside Commons'          => 'Hold'
};

// Sell Now 80-92 | 12 mo 55-70 | Hold 30-50 — matching the observed bands on the 5
// existing rows (88 Sell Now, 61 12 mo, 44/40/38 Hold). All 18 values are distinct.
Map<String, Integer> scoreByName = new Map<String, Integer>{
    'Westgate Plaza'             => 90,
    'Westgate Plaza Asset'       => 86,
    'Sunridge Marketplace'       => 83,
    'Cypresswood Retail'         => 81,
    'Heights Marketplace'        => 69,
    'Heights Marketplace Asset'  => 65,
    'Park North Retail'          => 67,
    'Katy Mills Strip'           => 63,
    'Katy Mills Strip Asset'     => 59,
    'Sunset Mixed-Use'           => 56,
    'Sterling Crossing'          => 49,
    'Sterling Crossing Asset'    => 45,
    'Bayou Bend Center'          => 47,
    'Bayou Bend Center Asset'    => 43,
    'Magnolia Commons'           => 41,
    'Magnolia Commons Asset'     => 36,
    'Oak Street Center'          => 33,
    'Riverside Commons'          => 31
};

// Round Argus values in the same 9M-34M range as the existing 5.
Map<String, Decimal> argusValueByName = new Map<String, Decimal>{
    'Westgate Plaza'             => 31200000,
    'Westgate Plaza Asset'       => 28500000,
    'Sunridge Marketplace'       => 21600000,
    'Cypresswood Retail'         => 17800000,
    'Heights Marketplace'        => 24900000,
    'Heights Marketplace Asset'  => 22400000,
    'Park North Retail'          => 18700000,
    'Katy Mills Strip'           => 26300000,
    'Katy Mills Strip Asset'     => 20100000,
    'Sunset Mixed-Use'           => 33400000,
    'Sterling Crossing'          => 16900000,
    'Sterling Crossing Asset'    => 14300000,
    'Bayou Bend Center'          => 19800000,
    'Bayou Bend Center Asset'    => 15400000,
    'Magnolia Commons'           => 12600000,
    'Magnolia Commons Asset'     => 11200000,
    'Oak Street Center'          => 10400000,
    'Riverside Commons'          =>  8900000
};

// Cap rate rises as the signal weakens (prime sell-now assets trade tightest), matching
// the existing rows' 6.00 (Sell Now) -> 6.25 (12 mo) -> 6.90 / 7.50 (Hold) progression.
Map<String, Decimal> capByName = new Map<String, Decimal>{
    'Westgate Plaza'             => 6.00,
    'Westgate Plaza Asset'       => 6.10,
    'Sunridge Marketplace'       => 6.15,
    'Cypresswood Retail'         => 6.20,
    'Heights Marketplace'        => 6.35,
    'Heights Marketplace Asset'  => 6.40,
    'Park North Retail'          => 6.45,
    'Katy Mills Strip'           => 6.50,
    'Katy Mills Strip Asset'     => 6.60,
    'Sunset Mixed-Use'           => 6.70,
    'Sterling Crossing'          => 6.80,
    'Sterling Crossing Asset'    => 6.90,
    'Bayou Bend Center'          => 7.00,
    'Bayou Bend Center Asset'    => 7.10,
    'Magnolia Commons'           => 7.25,
    'Magnolia Commons Asset'     => 7.40,
    'Oak Street Center'          => 7.60,
    'Riverside Commons'          => 7.85
};

// Days from today to Peak_Sell_Date__c. Sell Now <= 30 (GREEN), 12 mo mostly 31-90
// (YELLOW), Hold well past 90 (RED). See the band note in the header.
Map<String, Integer> daysOutByName = new Map<String, Integer>{
    'Westgate Plaza'             => 11,
    'Westgate Plaza Asset'       => 18,
    'Sunridge Marketplace'       => 23,
    'Cypresswood Retail'         => 29,
    'Heights Marketplace'        => 44,
    'Heights Marketplace Asset'  => 52,
    'Park North Retail'          => 61,
    'Katy Mills Strip'           => 73,
    'Katy Mills Strip Asset'     => 84,
    'Sunset Mixed-Use'           => 118,
    'Sterling Crossing'          => 165,
    'Sterling Crossing Asset'    => 178,
    'Bayou Bend Center'          => 205,
    'Bayou Bend Center Asset'    => 221,
    'Magnolia Commons'           => 255,
    'Magnolia Commons Asset'     => 272,
    'Oak Street Center'          => 320,
    'Riverside Commons'          => 400
};

// Target sits below Argus value so portfolio upside (implied - target) is positive.
Map<String, Decimal> targetDiscountByName = new Map<String, Decimal>{
    'Westgate Plaza'             => 0.94,
    'Westgate Plaza Asset'       => 0.95,
    'Sunridge Marketplace'       => 0.93,
    'Cypresswood Retail'         => 0.94,
    'Heights Marketplace'        => 0.92,
    'Heights Marketplace Asset'  => 0.93,
    'Park North Retail'          => 0.94,
    'Katy Mills Strip'           => 0.91,
    'Katy Mills Strip Asset'     => 0.92,
    'Sunset Mixed-Use'           => 0.90,
    'Sterling Crossing'          => 0.90,
    'Sterling Crossing Asset'    => 0.91,
    'Bayou Bend Center'          => 0.89,
    'Bayou Bend Center Asset'    => 0.90,
    'Magnolia Commons'           => 0.88,
    'Magnolia Commons Asset'     => 0.89,
    'Oak Street Center'          => 0.88,
    'Riverside Commons'          => 0.87
};

// Projected value at peak sits above target.
Map<String, Decimal> upliftPctByName = new Map<String, Decimal>{
    'Westgate Plaza'             => 1.09,
    'Westgate Plaza Asset'       => 1.08,
    'Sunridge Marketplace'       => 1.09,
    'Cypresswood Retail'         => 1.07,
    'Heights Marketplace'        => 1.08,
    'Heights Marketplace Asset'  => 1.07,
    'Park North Retail'          => 1.06,
    'Katy Mills Strip'           => 1.09,
    'Katy Mills Strip Asset'     => 1.07,
    'Sunset Mixed-Use'           => 1.10,
    'Sterling Crossing'          => 1.06,
    'Sterling Crossing Asset'    => 1.05,
    'Bayou Bend Center'          => 1.07,
    'Bayou Bend Center Asset'    => 1.06,
    'Magnolia Commons'           => 1.06,
    'Magnolia Commons Asset'     => 1.05,
    'Oak Street Center'          => 1.05,
    'Riverside Commons'          => 1.05
};

// Only the 5 of the 18 whose Property_Type__c is currently blank. Every literal is a
// member of Property_Type__c's value set {Retail, Industrial, Multifamily, Office,
// Mixed-Use}. Applied ONLY when the field is actually null, so the other 13 keep theirs.
Map<String, String> propertyTypeIfBlankByName = new Map<String, String>{
    'Cypresswood Retail' => 'Retail',
    'Oak Street Center'  => 'Retail',
    'Park North Retail'  => 'Retail',
    'Riverside Commons'  => 'Multifamily',
    'Sunset Mixed-Use'   => 'Mixed-Use'
};

// ── Guard: seven parallel maps are seven chances for a key typo, and anonymous Apex is
//    not compiled ahead of time. Abort BEFORE any DML if the keys disagree, rather than
//    silently half-populating a row. ────────────────────────────────────────────
Set<String> expectedNames = signalByName.keySet();
Map<String, Set<String>> parallelKeySets = new Map<String, Set<String>>{
    'scoreByName'          => scoreByName.keySet(),
    'argusValueByName'     => argusValueByName.keySet(),
    'capByName'            => capByName.keySet(),
    'daysOutByName'        => daysOutByName.keySet(),
    'targetDiscountByName' => targetDiscountByName.keySet(),
    'upliftPctByName'      => upliftPctByName.keySet()
};
for (String mapName : parallelKeySets.keySet()) {
    Set<String> actualNames = parallelKeySets.get(mapName);
    if (actualNames.size() != expectedNames.size() || !actualNames.containsAll(expectedNames)) {
        Set<String> missing = new Set<String>(expectedNames);
        missing.removeAll(actualNames);
        Set<String> extra = new Set<String>(actualNames);
        extra.removeAll(expectedNames);
        throw new HandledException('ABORT before DML — ' + mapName
            + ' keys do not match signalByName. missing=' + missing + ' extra=' + extra);
    }
}

// ── Read: ONLY the statusless rows. This single predicate is what makes a second run a
//    clean no-op, and what protects the 5 existing signals. ────────────────────
List<Property_Asset__c> blanks = [
    SELECT Id, Name, Property__c, Property_Type__c, Argus_Signal__c
    FROM Property_Asset__c
    WHERE Argus_Signal__c = null
    ORDER BY Name
];

Date today = Date.today();
List<Property_Asset__c> toUpdate = new List<Property_Asset__c>();
List<String> unmatchedRows = new List<String>();
Integer withProperty = 0;
Integer typesFilled = 0;
Integer g = 0, y = 0, r = 0;

for (Property_Asset__c a : blanks) {
    if (!signalByName.containsKey(a.Name)) {
        unmatchedRows.add(a.Name);   // blank signal but not in our list — left untouched
        continue;
    }

    Decimal argusValue = argusValueByName.get(a.Name);
    Decimal cap        = capByName.get(a.Name);
    // NOI derived from value x cap so that value == NOI / (cap/100) EXACTLY — the same
    // relationship seed-sell-meter.apex holds on the existing 5 rows, stated in reverse.
    Decimal noi        = (argusValue * cap / 100).setScale(2);
    Decimal target     = (argusValue * targetDiscountByName.get(a.Name)).setScale(2);
    Decimal projected  = (target * upliftPctByName.get(a.Name)).setScale(0);
    Integer d          = daysOutByName.get(a.Name);

    a.Argus_Signal__c            = signalByName.get(a.Name);
    a.Sell_Readiness_Score__c    = scoreByName.get(a.Name);
    a.Argus_Value__c             = argusValue;
    a.NOI__c                     = noi;
    a.Market_Cap_Rate__c         = cap;
    a.Peak_Sell_Date__c          = today.addDays(d);
    a.Projected_Value_At_Peak__c = projected;
    a.Target_Sale_Price__c       = target;

    if (a.Property_Type__c == null && propertyTypeIfBlankByName.containsKey(a.Name)) {
        a.Property_Type__c = propertyTypeIfBlankByName.get(a.Name);
        typesFilled++;
    }
    if (a.Property__c != null) {
        withProperty++;
    }
    if (d <= 30) { g++; } else if (d <= 90) { y++; } else { r++; }

    toUpdate.add(a);
}

// ── Write: ONE DML for the whole collection. No DML inside the loop above. ─────
if (!toUpdate.isEmpty()) {
    Database.SaveResult[] saveResults = Database.update(toUpdate, true);
    Integer ok = 0;
    for (Database.SaveResult sr : saveResults) {
        if (sr.isSuccess()) { ok++; }
    }
    System.debug(LoggingLevel.ERROR, 'ASSET_SELL_SIGNAL_SEED updated=' + ok + ' of ' + toUpdate.size());
} else {
    System.debug(LoggingLevel.ERROR,
        'ASSET_SELL_SIGNAL_SEED NO-OP — zero rows had a blank Argus_Signal__c. '
        + 'Either this script has already run, or the 18 target rows are named differently. '
        + 'This is EXPECTED on a second run.');
}

if (!unmatchedRows.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'ASSET_SELL_SIGNAL_SEED ⚠ blank-signal rows NOT in our '
        + 'name list, left untouched (' + unmatchedRows.size() + '): ' + unmatchedRows);
}
Set<String> notFound = new Set<String>(signalByName.keySet());
for (Property_Asset__c a : toUpdate) {
    notFound.remove(a.Name);
}
if (!notFound.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'ASSET_SELL_SIGNAL_SEED ⚠ names in our list with NO blank-signal '
        + 'row in the org (already populated, renamed, or absent) — ' + notFound.size() + ': ' + notFound);
}
System.debug(LoggingLevel.ERROR, 'ASSET_SELL_SIGNAL_SEED property-types filled (were blank)=' + typesFilled
    + ' | rows carrying Property__c (i.e. eligible for the Sell Meter)=' + withProperty + ' of ' + toUpdate.size()
    + ' | new-row bands GREEN=' + g + ' YELLOW=' + y + ' RED=' + r);

// ── Verify: full-portfolio readback so a silent no-op cannot be mistaken for success ──
List<Property_Asset__c> allAssets = [
    SELECT Id, Name, Status__c, Property__c, Property_Type__c, Argus_Signal__c,
           Sell_Readiness_Score__c, Sell_Readiness_Band__c, Argus_Value__c, NOI__c,
           Market_Cap_Rate__c, Peak_Sell_Date__c, Projected_Value_At_Peak__c, Target_Sale_Price__c
    FROM Property_Asset__c
    ORDER BY Argus_Signal__c NULLS LAST, Name
];

Map<String, Integer> countBySignal = new Map<String, Integer>{
    'Sell Now' => 0, '12 mo' => 0, 'Hold' => 0, '(blank)' => 0
};
Integer meterGreen = 0, meterYellow = 0, meterRed = 0, onMeter = 0;

System.debug(LoggingLevel.ERROR, '───── ASSET_SELL_SIGNAL_SEED per-row (' + allAssets.size() + ' rows) ─────');
for (Property_Asset__c a : allAssets) {
    String sig = (a.Argus_Signal__c == null) ? '(blank)' : a.Argus_Signal__c;
    countBySignal.put(sig, countBySignal.get(sig) + 1);

    // Mirror of SellMeterService.bandForPeak + PropertyAssetSelector's sell-candidate filter.
    String band = 'not-on-meter';
    if (a.Property__c != null && a.Peak_Sell_Date__c != null) {
        onMeter++;
        Integer days = today.daysBetween(a.Peak_Sell_Date__c);
        if (days <= 30) { band = 'GREEN'; meterGreen++; }
        else if (days <= 90) { band = 'YELLOW'; meterYellow++; }
        else { band = 'RED'; meterRed++; }
    }
    System.debug(LoggingLevel.ERROR, 'ROW | ' + a.Name
        + ' | signal=' + sig
        + ' | score=' + a.Sell_Readiness_Score__c
        + ' | band(formula)=' + a.Sell_Readiness_Band__c
        + ' | type=' + a.Property_Type__c
        + ' | argusValue=' + a.Argus_Value__c
        + ' | NOI=' + a.NOI__c
        + ' | cap=' + a.Market_Cap_Rate__c
        + ' | peak=' + a.Peak_Sell_Date__c
        + ' | target=' + a.Target_Sale_Price__c
        + ' | projected=' + a.Projected_Value_At_Peak__c
        + ' | meter=' + band);
}

System.debug(LoggingLevel.ERROR, '───── ASSET_SELL_SIGNAL_SEED totals ─────');
System.debug(LoggingLevel.ERROR, 'SIGNAL COUNTS across all ' + allAssets.size() + ' Property_Asset__c rows: '
    + 'Sell Now=' + countBySignal.get('Sell Now')
    + ' | 12 mo=' + countBySignal.get('12 mo')
    + ' | Hold=' + countBySignal.get('Hold')
    + ' | STILL BLANK=' + countBySignal.get('(blank)') + '  (blank must be 0)');
System.debug(LoggingLevel.ERROR, 'SELL METER (Property__c != null AND Peak_Sell_Date__c != null): '
    + onMeter + ' rows on the meter — GREEN=' + meterGreen + ' YELLOW=' + meterYellow + ' RED=' + meterRed);
