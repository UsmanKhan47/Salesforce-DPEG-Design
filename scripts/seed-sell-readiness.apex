// Seed Sell-Readiness data on the 24 active Property Assets so the native
// dashboard components read like the mockup:
//   Avg Sell Readiness = 64%, Mix = Sell Ready 3 / Monitor 8 / Hold 13,
//   Total Argus Value = $392.0M.

List<Property_Asset__c> assets = [
    SELECT Id, Name FROM Property_Asset__c WHERE Status__c = 'Active' ORDER BY CreatedDate ASC
];

// Realistic CRE names used only to replace the generic "DPEG Seed Asset" rows
List<String> names = new List<String>{
    'Park North Retail','Riverside Commons','Oak Street Center','NW Industrial Park',
    'Lakeside Logistics','Cedar Point Plaza','Harbor View Offices','Summit Business Park',
    'Maple Grove Shopping','Brookfield Distribution','Stonebridge Tower','Westgate Commerce',
    'Fairview Medical Plaza','Ironwood Self Storage','Belmont Apartments','Crestline Corporate Center',
    'Pioneer Square Retail','Gateway Logistics Hub','Highland Park Offices','Sunset Industrial',
    'Eastlake Town Center','Granite Ridge Warehouse','Clearwater Business Center','Northgate Pavilion'
};

// Per-band fixed score (only the portfolio AVG is shown on the gauge → 64% exactly):
// 3*90 + 8*72 + 12*53 + 1*54 = 1536; 1536 / 24 = 64
Long valueTotal = 392000000L;
Long valueRunning = 0;
Integer nameIdx = 0;

for (Integer i = 0; i < assets.size(); i++) {
    Property_Asset__c a = assets[i];

    // Band assignment: first 3 Sell Ready, next 8 Monitor, last 13 Hold
    if (i < 3) {
        a.Argus_Signal__c = 'Sell Now';
        a.Sell_Readiness_Score__c = 90;
    } else if (i < 11) {
        a.Argus_Signal__c = '12 mo';
        a.Sell_Readiness_Score__c = 72;
    } else {
        a.Argus_Signal__c = 'Hold';
        a.Sell_Readiness_Score__c = (i == assets.size() - 1) ? 54 : 53; // one 54 to land avg=64
    }

    // Argus value: spread 8M..23M, final record absorbs the remainder to hit $392M
    if (i < assets.size() - 1) {
        Long v = (8 + Math.mod(i * 5, 16)) * 1000000L;
        a.Argus_Value__c = v;
        valueRunning += v;
    } else {
        a.Argus_Value__c = valueTotal - valueRunning;
    }

    // Replace generic seed names only
    if (a.Name != null && a.Name.startsWith('DPEG Seed Asset') && nameIdx < names.size()) {
        a.Name = names[nameIdx];
        nameIdx++;
    }
}
update assets;

System.debug(LoggingLevel.ERROR, 'Updated ' + assets.size() + ' properties.');
