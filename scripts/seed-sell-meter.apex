// ─────────────────────────────────────────────────────────────────────────────
// Sell Meter seed — UPDATE-based, band-spread. Rewritten 2026-08-19 for the
// current 6-record Property_Asset__c pool (previously targeted a 12-record pick
// list against a larger, now-superseded portfolio).
//
// Populates the 6 EXISTING, Property__c-parented Property_Asset__c records so the
// Disposition "Sell Meter" shows a clean 2/2/2 spread across GREEN / YELLOW / RED
// readiness bands. It NEVER inserts and NEVER deletes.
//
// The selector filter (PropertyAssetSelector) is:
//     Property__c != null AND Peak_Sell_Date__c != null
// so ONLY the records this script stamps with a Peak_Sell_Date__c appear on the
// meter. All 6 current records already carry a Property__c lookup.
//
// Band = days until Peak_Sell_Date__c (SellMeterController.bandForPeak):
//     <= 30 days -> GREEN | 31-90 -> YELLOW | > 90 (or null) -> RED
//
// NOI / cap rate are chosen so implied fair value (NOI / (cap/100)) roughly
// matches each asset's Argus_Value__c (set by seed-sell-readiness.apex). Target
// sits a few % below fair value so the portfolio-upside tile (implied - target)
// shows a real, positive number; projected sits a bit above target.
// ─────────────────────────────────────────────────────────────────────────────

List<Property_Asset__c> pool = [
    SELECT Id, Name
    FROM Property_Asset__c
    WHERE Property__c != null
    ORDER BY Name
];

// Parallel data keyed by Name — daysOut drives the band (2 GREEN, 2 YELLOW, 2 RED).
Map<String, Integer> daysOutByName = new Map<String, Integer>{
    'Copperfield Town Center'     => 15,   // GREEN
    'Universal City Retail Row'   => 25,   // GREEN
    'Lakeline Corporate Center'   => 55,   // YELLOW
    'Windcrest Business Park'     => 75,   // YELLOW
    'Canyon Lake Land Holdings'   => 180,  // RED
    'Terrell Hills Medical Plaza' => 280   // RED
};
Map<String, Decimal> noiByName = new Map<String, Decimal>{
    'Copperfield Town Center'     => 1608000,
    'Universal City Retail Row'   => 1212500,
    'Lakeline Corporate Center'   => 2223000,
    'Windcrest Business Park'     => 1559250,
    'Canyon Lake Land Holdings'   => 712500,
    'Terrell Hills Medical Plaza' => 1076400
};
Map<String, Decimal> capByName = new Map<String, Decimal>{
    'Copperfield Town Center'     => 6.0,
    'Universal City Retail Row'   => 6.25,
    'Lakeline Corporate Center'   => 6.5,
    'Windcrest Business Park'     => 6.75,
    'Canyon Lake Land Holdings'   => 7.5,
    'Terrell Hills Medical Plaza' => 6.9
};
Map<String, Decimal> targetDiscountByName = new Map<String, Decimal>{
    'Copperfield Town Center'     => 0.93,
    'Universal City Retail Row'   => 0.95,
    'Lakeline Corporate Center'   => 0.90,
    'Windcrest Business Park'     => 0.92,
    'Canyon Lake Land Holdings'   => 0.88,
    'Terrell Hills Medical Plaza' => 0.90
};
Map<String, Decimal> upliftPctByName = new Map<String, Decimal>{
    'Copperfield Town Center'     => 1.08,
    'Universal City Retail Row'   => 1.06,
    'Lakeline Corporate Center'   => 1.10,
    'Windcrest Business Park'     => 1.07,
    'Canyon Lake Land Holdings'   => 1.05,
    'Terrell Hills Medical Plaza' => 1.06
};

Date today = Date.today();
List<Property_Asset__c> toUpdate = new List<Property_Asset__c>();
Integer g = 0, y = 0, r = 0;

for (Property_Asset__c a : pool) {
    if (!daysOutByName.containsKey(a.Name)) {
        continue; // not one of the 6 known demo assets — leave untouched
    }
    Decimal noi = noiByName.get(a.Name);
    Decimal cap = capByName.get(a.Name);
    Decimal impliedFair = noi * 100 / cap;
    Decimal target = (impliedFair * targetDiscountByName.get(a.Name)).setScale(0);
    Decimal projected = (target * upliftPctByName.get(a.Name)).setScale(0);
    Integer d = daysOutByName.get(a.Name);

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
    + ' green=' + g + ' yellow=' + y + ' red=' + r);
