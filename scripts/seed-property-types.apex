// Re-seed the 24 active Property Assets by type so Widget 1 (Sell Readiness by
// Property Type) matches the mockup, while preserving total Argus Value ($392M)
// and the 3 Sell Now / 8 Monitor / 13 Hold band mix used by existing widgets.
//
//   Type        Props  Total Value   Score  Ready(Sell Now)
//   Retail        8     $142.6M       76      2
//   Industrial    6      $98.4M       58      1
//   Multifamily   5      $76.2M       62      0
//   Office        3      $43.8M       41      0
//   Mixed-Use     2      $31.0M       55      0

List<Property_Asset__c> assets = [
    SELECT Id FROM Property_Asset__c WHERE Status__c = 'Active' ORDER BY CreatedDate ASC
];

List<String>  types  = new List<String>{ 'Retail','Industrial','Multifamily','Office','Mixed-Use' };
List<Integer> counts = new List<Integer>{ 8, 6, 5, 3, 2 };
List<Decimal> sums   = new List<Decimal>{ 142600000, 98400000, 76200000, 43800000, 31000000 };
List<Integer> scores = new List<Integer>{ 76, 58, 62, 41, 55 };
List<Integer> ready  = new List<Integer>{ 2, 1, 0, 0, 0 };

Integer idx = 0;
Integer twelveMoLeft = 8; // of the 21 non-Sell-Now, 8 are Monitor, remainder Hold

for (Integer t = 0; t < types.size(); t++) {
    Integer cnt = counts[t];
    Decimal per = (sums[t] / cnt).setScale(0);
    Decimal acc = 0;
    for (Integer j = 0; j < cnt; j++) {
        Property_Asset__c a = assets[idx];
        a.Property_Type__c = types[t];
        a.Sell_Readiness_Score__c = scores[t];
        if (j < cnt - 1) { a.Argus_Value__c = per; acc += per; }
        else            { a.Argus_Value__c = sums[t] - acc; }

        if (j < ready[t]) {
            a.Argus_Signal__c = 'Sell Now';
        } else if (twelveMoLeft > 0) {
            a.Argus_Signal__c = '12 mo';
            twelveMoLeft--;
        } else {
            a.Argus_Signal__c = 'Hold';
        }
        idx++;
    }
}
update assets;
System.debug(LoggingLevel.ERROR, 'Re-seeded ' + assets.size() + ' properties by type.');
