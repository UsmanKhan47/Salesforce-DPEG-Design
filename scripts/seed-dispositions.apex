// Seed Disposition dashboard demo data to match mockup KPIs.
// Targets: Properties in AUM = 24 (Active), Sell Ready (ARGUS) = 3 (Sell Now),
//          BOVs Ordered = 5 (BOV Outreach), Listed with Broker = 2 (Active Listing),
//          Broker Alert Due = 1 (check-in within 7 days), Avg Days on Market = 38.

// --- Property Assets: top up to 24 Active, 3 Sell Now ---
Integer activeNow = [SELECT COUNT() FROM Property_Asset__c WHERE Status__c = 'Active'];
Integer sellNow   = [SELECT COUNT() FROM Property_Asset__c WHERE Argus_Signal__c = 'Sell Now'];
Integer needActive  = 24 - activeNow;
Integer needSellNow = 3 - sellNow;

List<Property_Asset__c> props = new List<Property_Asset__c>();
for (Integer i = 0; i < needActive; i++) {
    String signal = 'Hold';
    if (i < needSellNow) {
        signal = 'Sell Now';
    } else if (Math.mod(i, 2) == 0) {
        signal = '12 mo';
    }
    props.add(new Property_Asset__c(
        Name = 'DPEG Seed Asset ' + (i + 1),
        Status__c = 'Active',
        Argus_Signal__c = signal
    ));
}
if (!props.isEmpty()) { insert props; }

// ── On_Market record type (decision D11 / Gate 1 Q1) ────────────────────────────────
// Every Disposition seeded below is stamped On_Market. Leaving RecordTypeId unset lands
// the record on MASTER: no Path, and all ten stage values selectable — precisely the
// state post-deploy gate A2 exists to eliminate, so an unstamped seed would recreate the
// problem the migration fixes.
//
// A DESCRIBE, NOT A QUERY. `[SELECT Id FROM RecordType WHERE ...].Id` throws a
// QueryException when the record type is absent, and in an anonymous-Apex script that
// aborts mid-run and leaves the org half-seeded. The describe returns null instead, which
// is a legitimate answer (§4 record-type metadata not deployed yet, or not available to
// the running user) and the platform default then applies. Same shape as
// DispositionService.onMarketRecordTypeId() and TestDataFactory.dispositionRecordTypeId(),
// so all three agree. Costs no SOQL.
//
// 'BOV Outreach' and 'Active Listing' below are On_Market-only stage values, so the stamp
// and the stages agree.
Schema.RecordTypeInfo onMarketInfo =
    Schema.SObjectType.Disposition__c.getRecordTypeInfosByDeveloperName().get('On_Market');
Id onMarketRtId = (onMarketInfo != null && onMarketInfo.isAvailable())
    ? onMarketInfo.getRecordTypeId()
    : null;

// --- Dispositions: 5 BOV Outreach, 2 Active Listing (1 alert due), avg 38 days on market ---
List<Property_Asset__c> assets = [SELECT Id FROM Property_Asset__c WHERE Status__c = 'Active' ORDER BY CreatedDate ASC LIMIT 2];
Id pa0 = assets[0].Id;
Id pa1 = assets.size() > 1 ? assets[1].Id : assets[0].Id;

Integer bovNow    = [SELECT COUNT() FROM Disposition__c WHERE Disposition_Stage__c = 'BOV Outreach'];
Integer listedNow = [SELECT COUNT() FROM Disposition__c WHERE Disposition_Stage__c = 'Active Listing'];

List<Disposition__c> ds = new List<Disposition__c>();
for (Integer i = 0; i < (5 - bovNow); i++) {
    ds.add(new Disposition__c(Disposition_Stage__c = 'BOV Outreach', Property_Asset__c = (i < 2 ? pa0 : pa1)));
}
Integer needListed = 2 - listedNow;
if (needListed >= 1) {
    ds.add(new Disposition__c(
        Disposition_Stage__c = 'Active Listing', Property_Asset__c = pa0,
        Listing_Date__c = Date.today().addDays(-35), Next_Broker_Checkin__c = Date.today().addDays(3)));
}
if (needListed >= 2) {
    ds.add(new Disposition__c(
        Disposition_Stage__c = 'Active Listing', Property_Asset__c = pa1,
        Listing_Date__c = Date.today().addDays(-41)));
}
if (onMarketRtId != null) {
    for (Disposition__c d : ds) { d.RecordTypeId = onMarketRtId; }
}
if (!ds.isEmpty()) { insert ds; }

System.debug('Seed complete. Active props now: ' + [SELECT COUNT() FROM Property_Asset__c WHERE Status__c='Active']);
