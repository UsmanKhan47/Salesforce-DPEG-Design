// ─────────────────────────────────────────────────────────────────────────────
// Sell Meter seed — UPDATE-based, band-spread (canonical Sell Meter seed).
//
// Populates a curated set of EXISTING Property_Asset__c records so the
// Disposition "Sell Meter" showcases a clean spread across the GREEN / YELLOW /
// RED readiness bands. It NEVER inserts and NEVER deletes — inserting is how the
// ~48-record junk pile accumulated, and Property_Asset__c is the parent of Units /
// Onboarding / Leases / Work Orders, so deletes would cascade.
//
// The selector filter (PropertyAssetSelector) is:
//     Property__c != null AND Peak_Sell_Date__c != null
// so ONLY the records this script stamps with a Peak_Sell_Date__c appear on the
// meter; every other (junk / un-parented) Property_Asset__c stays hidden.
//
// Band = days until Peak_Sell_Date__c (SellMeterController.bandForPeak):
//     <= 30 days -> GREEN | 31-90 -> YELLOW | > 90 (or null) -> RED
//
// Idempotent-ish: it re-selects the first N Property-parented assets by Name
// (deduped by Name), then re-stamps the same values, so re-running never creates
// new rows — it just re-sets the same curated set.
// ─────────────────────────────────────────────────────────────────────────────

final Integer TARGET_COUNT = 12;

// 1. Candidate pool: existing assets that already have a Property lookup.
List<Property_Asset__c> pool = [
    SELECT Id, Name
    FROM Property_Asset__c
    WHERE Property__c != null
    ORDER BY Name NULLS LAST
];

// 2. Dedupe by Name (avoid two same-named rows on the meter); preserve order.
Map<String, Property_Asset__c> byName = new Map<String, Property_Asset__c>();
for (Property_Asset__c a : pool) {
    String key = (a.Name == null ? 'unnamed' : a.Name);
    if (!byName.containsKey(key)) {
        byName.put(key, a);
    }
}
List<Property_Asset__c> distinctNamed = byName.values();
List<Property_Asset__c> picks = new List<Property_Asset__c>();
for (Integer i = 0; i < distinctNamed.size() && picks.size() < TARGET_COUNT; i++) {
    picks.add(distinctNamed[i]);
}

// 3. Band spread — parallel arrays, one entry per pick (12 max):
//      4 GREEN (<=30d), 4 YELLOW (31-90d), 4 RED (>90d).
//    daysOut drives the band; noi/cap drive the money; uplift sits above target.
List<Integer> daysOut = new List<Integer>{  10,  18,  25,  28,   45,  60,  75,  85,   150, 250, 330, 400 };
List<Decimal> noiList = new List<Decimal>{ 1800000, 2400000, 3100000, 1250000,
                                           2900000, 4200000, 1650000, 3600000,
                                           980000,  2000000, 5200000, 1400000 };
List<Decimal> capList = new List<Decimal>{ 5.5, 6.0, 6.25, 5.75,
                                           6.5, 5.8, 6.75, 6.1,
                                           7.1, 6.9, 5.6, 7.0 };
List<Decimal> upliftPct = new List<Decimal>{ 1.08, 1.10, 1.06, 1.12,
                                             1.07, 1.09, 1.05, 1.11,
                                             1.04, 1.06, 1.08, 1.05 };
// Target sits a few % BELOW the fair implied value (NOI/cap), so each asset is
// "in the money" and the portfolio-upside tile (implied - target) shows a real,
// realistic number instead of ~$0. Still "target ~ NOI/(cap/100)" (within ~10%).
List<Decimal> targetDiscount = new List<Decimal>{ 0.94, 0.90, 0.93, 0.95,
                                                  0.92, 0.88, 0.96, 0.91,
                                                  0.97, 0.93, 0.89, 0.95 };

Date today = Date.today();
List<Property_Asset__c> toUpdate = new List<Property_Asset__c>();
Integer g = 0, y = 0, r = 0;

for (Integer i = 0; i < picks.size(); i++) {
    Property_Asset__c a = picks[i];
    Decimal noi = noiList[i];
    Decimal cap = capList[i];
    // Fair implied value = NOI / (cap%) ; multiply-first avoids a tiny-divisor intermediate.
    Decimal impliedFair = noi * 100 / cap;
    // Target a few % below fair value -> positive upside; projected a bit above target.
    Decimal target = (impliedFair * targetDiscount[i]).setScale(0);
    Decimal projected = (target * upliftPct[i]).setScale(0);
    Integer d = daysOut[i];

    a.NOI__c = noi;
    a.Market_Cap_Rate__c = cap;
    a.Target_Sale_Price__c = target;
    a.Projected_Value_At_Peak__c = projected;
    a.Peak_Sell_Date__c = today.addDays(d);
    toUpdate.add(a);

    if (d <= 30) { g++; } else if (d <= 90) { y++; } else { r++; }
}

update toUpdate;

System.debug(LoggingLevel.ERROR, 'SELL_METER_SEED updated=' + toUpdate.size()
    + ' green=' + g + ' yellow=' + y + ' red=' + r
    + ' (pool_with_Property=' + pool.size() + ', distinct_names=' + byName.size() + ')');
