// Sell Readiness seed — rewritten 2026-08-19 for the current (6-record) Property_Asset__c
// pool. The org was previously re-seeded down to a small, realistically-named set of 6
// Active properties (Canyon Lake Land Holdings, Copperfield Town Center, Lakeline Corporate
// Center, Terrell Hills Medical Plaza, Universal City Retail Row, Windcrest Business Park);
// the prior version of this script targeted a stale 24-record / $392M portfolio that no
// longer exists. This version backfills Argus_Signal__c / Argus_Value__c /
// Sell_Readiness_Score__c (and Property_Type__c only where it is still blank) on the actual
// 6 records so the native Disposition Dashboard widgets (Properties in AUM, Sell Ready
// (ARGUS), Total Argus Value, Portfolio Sell Readiness, Readiness Mix, Sell Readiness by
// Property Type) all render non-trivial data. UPDATE-only — never inserts/deletes.
//
// Signal mix: 1 Sell Now / 2 12 mo / 3 Hold (proportional to the original 3/8/13-of-24 ratio).
// Property_Type__c is left untouched where it is already set (Retail/Office/Industrial on 4
// of the 6) — only the 2 blank ones are backfilled here.

Map<String, Decimal> argusValueByName = new Map<String, Decimal>{
    'Canyon Lake Land Holdings'  => 9500000,
    'Copperfield Town Center'    => 26800000,
    'Lakeline Corporate Center'  => 34200000,
    'Terrell Hills Medical Plaza'=> 15600000,
    'Universal City Retail Row'  => 19400000,
    'Windcrest Business Park'    => 23100000
};
Map<String, String> argusSignalByName = new Map<String, String>{
    'Canyon Lake Land Holdings'  => 'Hold',
    'Copperfield Town Center'    => 'Sell Now',
    'Lakeline Corporate Center'  => '12 mo',
    'Terrell Hills Medical Plaza'=> 'Hold',
    'Universal City Retail Row'  => '12 mo',
    'Windcrest Business Park'    => 'Hold'
};
Map<String, Integer> readinessScoreByName = new Map<String, Integer>{
    'Canyon Lake Land Holdings'  => 38,
    'Copperfield Town Center'    => 88,
    'Lakeline Corporate Center'  => 66,
    'Terrell Hills Medical Plaza'=> 44,
    'Universal City Retail Row'  => 61,
    'Windcrest Business Park'    => 40
};
// Only used for records that come in with a blank Property_Type__c.
Map<String, String> propertyTypeIfBlankByName = new Map<String, String>{
    'Canyon Lake Land Holdings'   => 'Mixed-Use',
    'Terrell Hills Medical Plaza' => 'Office'
};

List<Property_Asset__c> assets = [
    SELECT Id, Name, Property_Type__c
    FROM Property_Asset__c
    WHERE Status__c = 'Active'
];

List<Property_Asset__c> toUpdate = new List<Property_Asset__c>();
for (Property_Asset__c a : assets) {
    if (!argusValueByName.containsKey(a.Name)) {
        continue; // not one of the 6 known demo assets — leave untouched
    }
    a.Argus_Value__c = argusValueByName.get(a.Name);
    a.Argus_Signal__c = argusSignalByName.get(a.Name);
    a.Sell_Readiness_Score__c = readinessScoreByName.get(a.Name);
    if (a.Property_Type__c == null && propertyTypeIfBlankByName.containsKey(a.Name)) {
        a.Property_Type__c = propertyTypeIfBlankByName.get(a.Name);
    }
    toUpdate.add(a);
}
update toUpdate;

System.debug(LoggingLevel.ERROR, 'SELL_READINESS_SEED updated=' + toUpdate.size());
