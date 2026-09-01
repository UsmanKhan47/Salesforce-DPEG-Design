// seed-disposition-lifecycle-02-assets.apex   PHASE 2 of 4
//
// DOES: stamps the Sell Meter inputs (Peak_Sell_Date__c, NOI__c, Market_Cap_Rate__c,
// Target_Sale_Price__c, Projected_Value_At_Peak__c, Argus_Value__c, Argus_Signal__c,
// Property_Type__c) onto the assets phase 1 produced, using a three-profile table that
// guarantees one GREEN, one YELLOW and one RED band and makes the two upside tiles differ.
//
// NEEDS FIRST: phase 1. It does NOT trust that phase 1 ran - it re-derives its own asset set by
// querying "assets whose Property__c belongs to a Closed Won Opportunity", and bails if that
// comes back too small.
//
// ASSERTS: enough stampable assets exist; every stamp committed; all three readiness bands are
// present afterwards; Portfolio Upside > 0; Portfolio Upside != Sell-Ready Upside.
//
// Reversible: this phase writes only field updates and is fully re-runnable. A STRICT failure
// here rolls back THIS PHASE ONLY - phase 1's cascade is already committed and cannot be undone.
// Band thresholds, the profile arithmetic and the tile formulas:
//   scripts/seed-disposition-lifecycle-2026-09-01.md

Boolean DRY_RUN = true;
Boolean STRICT = true;
// Opt-in. FALSE leaves any asset that already has a Peak_Sell_Date__c completely alone, so no
// curated data is overwritten and a second run is a no-op.
Boolean RESTAMP_EXISTING_SELL_METER_INPUTS = false;

String TAG = 'SEED2 | ';
Integer totalWrites = 0;
List<String> gateFailures = new List<String>();

System.debug(LoggingLevel.ERROR, TAG + '===== PHASE 2 / 4  SELL-METER INPUTS =====');
System.debug(LoggingLevel.ERROR, TAG + 'MODE: ' + (DRY_RUN
    ? '*** DRY RUN - NOTHING WILL BE WRITTEN ***' : '*** COMMITTING ***'));

// ---------------------------------------------------------------------------------------
// FLS for this phase's own fields. Anonymous Apex cannot use SYSTEM_MODE, so FLS and sharing
// both apply; a metadata-deployed field has no FieldPermissions for anyone, sysadmin included.
// ---------------------------------------------------------------------------------------
List<String> myFields = new List<String>{
    'Peak_Sell_Date__c', 'NOI__c', 'Market_Cap_Rate__c', 'Target_Sale_Price__c',
    'Projected_Value_At_Peak__c', 'Argus_Value__c', 'Argus_Signal__c', 'Property_Type__c' };
Map<String, Schema.SObjectField> fm =
    Schema.SObjectType.Property_Asset__c.fields.getMap();
List<String> accessGaps = new List<String>();
for (String fn : myFields) {
    Schema.SObjectField f = fm.get(fn.toLowerCase());   // the map's keys are lowercase
    if (f == null) {
        accessGaps.add('Property_Asset__c.' + fn + ' -> ABSENT from this user\'s schema');
    } else if (!f.getDescribe().isUpdateable()) {
        accessGaps.add('Property_Asset__c.' + fn + ' -> not updateable for this user');
    }
}
for (String g : accessGaps) {
    System.debug(LoggingLevel.ERROR, TAG + 'ACCESS GAP: ' + g);
}
System.assert(accessGaps.isEmpty(),
    'ABORTED - ' + accessGaps.size() + ' field(s) this phase writes are not writable. Assign '
    + 'DPEG_PropertyMgmt_Edit. Nothing was written.');

// ---------------------------------------------------------------------------------------
// PRECONDITION: re-derive the seed set from the ORG. A split run must never assume the previous
// phase wrote anything - "assets on properties of Closed Won deals" is the stable definition.
// ---------------------------------------------------------------------------------------
Set<Id> wonPropIds = new Set<Id>();
for (Opportunity o : [
        SELECT Id, Property__c FROM Opportunity
        WHERE StageName = 'Closed Won' AND Property__c != null]) {
    wonPropIds.add(o.Property__c);
}
System.debug(LoggingLevel.ERROR, TAG + 'Properties on Closed Won deals: ' + wonPropIds.size());
System.assert(!wonPropIds.isEmpty(),
    'ABORTED - no Closed Won Opportunity carries a Property__c. Phase 1 either has not run or '
    + 'wrote nothing. Run seed-disposition-lifecycle-01-advance.apex first and check its '
    + 'summary line actually reports rows written.');

List<Property_Asset__c> seedAssets = [
    SELECT Id, Name, Property__c, Peak_Sell_Date__c
    FROM Property_Asset__c
    WHERE Property__c IN :wonPropIds
    ORDER BY Name];
System.debug(LoggingLevel.ERROR, TAG + 'Assets on those properties: ' + seedAssets.size());
System.assert(!seedAssets.isEmpty(),
    'ABORTED - Closed Won deals exist but NO Property_Asset__c hangs off their properties. '
    + 'PropertyAssetService.ensureOnClosedWon did not fire. This is the "reports success, writes '
    + 'zero rows" case - do not proceed to phase 3.');

// Build the stamp set. Top up from assets with NO peak date only if the seed set is short:
// those are invisible to both PropertyAssetSelector meter queries today, so giving them a peak
// date adds a row to the widget and takes nothing away.
List<Property_Asset__c> candidates = new List<Property_Asset__c>();
Set<Id> candidateIds = new Set<Id>();
for (Property_Asset__c a : seedAssets) {
    candidates.add(a);
    candidateIds.add(a.Id);
}
if (candidates.size() < 3) {
    for (Property_Asset__c a : [
            SELECT Id, Name, Property__c, Peak_Sell_Date__c
            FROM Property_Asset__c
            WHERE Peak_Sell_Date__c = null AND Property__c != null
            ORDER BY Name LIMIT 10]) {
        if (candidateIds.contains(a.Id)) {
            continue;
        }
        candidates.add(a);
        candidateIds.add(a.Id);
        System.debug(LoggingLevel.ERROR, TAG + '  top-up: "' + a.Name
            + '" (no peak date, so invisible on the Sell Meter today)');
        if (candidates.size() >= 3) {
            break;
        }
    }
}
System.assert(candidates.size() >= 3,
    'ABORTED - only ' + candidates.size() + ' stampable asset(s). Three are needed for a '
    + 'GREEN/YELLOW/RED spread; without it the Sell Meter, both dashboard donuts and the '
    + 'readiness legend are unverifiable.');

// ---------------------------------------------------------------------------------------
// THE PROFILE TABLE.
// Band is DAYS-TO-PEAK (SellMeterService.bandForPeak): <=30 GREEN, <=90 YELLOW, else RED.
// Profile 2 uses +210 days rather than null because PropertyAssetSelector filters
// Peak_Sell_Date__c != null - a null-peak asset bands RED but never appears on the widget.
// Profile 1 is in the money AND yellow, which is what makes Portfolio Upside (all bands) differ
// from Sell-Ready Upside (green only). Expected: 8,500,000 vs 6,000,000.
// Argus_Signal__c and Property_Type__c values are read from their own value sets.
// ---------------------------------------------------------------------------------------
List<String> pBand = new List<String>{ 'GREEN', 'YELLOW', 'RED' };
List<Integer> pPeak = new List<Integer>{ 12, 55, 210 };
List<Decimal> pNoi = new List<Decimal>{ 2400000, 1650000, 900000 };
List<Decimal> pCap = new List<Decimal>{ 6.00, 5.50, 7.25 };
List<Decimal> pTarget = new List<Decimal>{ 34000000, 27500000, 15000000 };
List<Decimal> pProj = new List<Decimal>{ 41000000, 31000000, 13000000 };
List<Decimal> pArgus = new List<Decimal>{ 40500000, 29800000, 12200000 };
List<String> pSignal = new List<String>{ 'Sell Now', '12 mo', 'Hold' };
List<String> pType = new List<String>{ 'Retail', 'Office', 'Industrial' };

List<Property_Asset__c> stamps = new List<Property_Asset__c>();
Integer skippedStamped = 0;
for (Integer i = 0; i < candidates.size(); i++) {
    Property_Asset__c a = candidates[i];
    Integer p = Math.mod(i, 3);
    if (a.Peak_Sell_Date__c != null && !RESTAMP_EXISTING_SELL_METER_INPUTS) {
        skippedStamped++;
        System.debug(LoggingLevel.ERROR, TAG + '  skip "' + a.Name + '" - Peak_Sell_Date__c '
            + 'already ' + a.Peak_Sell_Date__c + '. Set RESTAMP_EXISTING_SELL_METER_INPUTS = true '
            + 'to overwrite.');
        continue;
    }
    stamps.add(new Property_Asset__c(
        Id = a.Id,
        Peak_Sell_Date__c = Date.today().addDays(pPeak[p]),
        NOI__c = pNoi[p],
        Market_Cap_Rate__c = pCap[p],
        Target_Sale_Price__c = pTarget[p],
        Projected_Value_At_Peak__c = pProj[p],
        Argus_Value__c = pArgus[p],
        Argus_Signal__c = pSignal[p],
        Property_Type__c = pType[p]));
    System.debug(LoggingLevel.ERROR, TAG + '  stamp "' + a.Name + '" -> ' + pBand[p] + ' peak=+'
        + pPeak[p] + 'd NOI=' + pNoi[p] + ' cap=' + pCap[p] + ' target=' + pTarget[p]
        + ' type=' + pType[p]);
}

// ---------------------------------------------------------------------------------------
// WRITE
// ---------------------------------------------------------------------------------------
Integer wroteStamps = 0;
if (DRY_RUN) {
    System.debug(LoggingLevel.ERROR, TAG + '[DRY RUN] would UPDATE ' + stamps.size()
        + ' Property_Asset__c (skipped as already stamped: ' + skippedStamped + ')');
} else if (!stamps.isEmpty()) {
    List<Database.SaveResult> rs = Database.update(stamps, false);
    for (Integer i = 0; i < rs.size(); i++) {
        if (rs[i].isSuccess()) {
            wroteStamps++;
        } else {
            for (Database.Error e : rs[i].getErrors()) {
                System.debug(LoggingLevel.ERROR, TAG + '  STAMP FAIL ' + stamps[i].Id + ': '
                    + e.getStatusCode() + ' - ' + e.getMessage() + ' fields='
                    + String.valueOf(e.getFields()));
            }
        }
    }
    System.debug(LoggingLevel.ERROR, TAG + 'Stamps written: ' + wroteStamps + '/' + stamps.size()
        + ' (skipped as already stamped: ' + skippedStamped + ')');
    System.assert(wroteStamps == stamps.size(),
        'ABORTED - ' + (stamps.size() - wroteStamps) + ' stamp(s) failed. Without them the assets '
        + 'stay invisible to PropertyAssetSelector and the whole demo has no inputs. Phase 2 is '
        + 'rolled back; phase 1 is NOT.');
    totalWrites += wroteStamps;
}

// ---------------------------------------------------------------------------------------
// VERIFY + GATES - reproduce PropertyAssetSelector's own predicate and
// SellMeterController.getMeterSummary's own arithmetic against the org.
// ---------------------------------------------------------------------------------------
Integer green = 0;
Integer yellow = 0;
Integer red = 0;
Decimal portfolioUpside = 0;
Decimal sellReadyUpside = 0;
for (Property_Asset__c a : [
        SELECT Id, NOI__c, Market_Cap_Rate__c, Target_Sale_Price__c, Peak_Sell_Date__c
        FROM Property_Asset__c
        WHERE Property__c != null AND Peak_Sell_Date__c != null]) {
    Integer days = Date.today().daysBetween(a.Peak_Sell_Date__c);
    String band = (days <= 30) ? 'GREEN' : ((days <= 90) ? 'YELLOW' : 'RED');
    if (band == 'GREEN') {
        green++;
    } else if (band == 'YELLOW') {
        yellow++;
    } else {
        red++;
    }
    if (a.NOI__c != null && a.Market_Cap_Rate__c != null && a.Market_Cap_Rate__c != 0
            && a.Target_Sale_Price__c != null) {
        Decimal up = (a.NOI__c / (a.Market_Cap_Rate__c / 100)) - a.Target_Sale_Price__c;
        if (up > 0) {
            portfolioUpside += up;
            if (band == 'GREEN') {
                sellReadyUpside += up;
            }
        }
    }
}
System.debug(LoggingLevel.ERROR, TAG + 'Sell Meter rows visible: ' + (green + yellow + red)
    + '  GREEN=' + green + ' YELLOW=' + yellow + ' RED=' + red);
System.debug(LoggingLevel.ERROR, TAG + 'Portfolio Upside tile  will read: ' + portfolioUpside);
System.debug(LoggingLevel.ERROR, TAG + 'Sell-Ready Upside tile will read: ' + sellReadyUpside);

if (!DRY_RUN) {
    if (green < 1 || yellow < 1 || red < 1) {
        gateFailures.add('the three bands are not all present (GREEN=' + green + ' YELLOW='
            + yellow + ' RED=' + red + ')');
    }
    if (portfolioUpside <= 0) {
        gateFailures.add('Portfolio Upside is ' + portfolioUpside
            + ' - no asset is in the money, so both tiles read zero');
    }
    if (portfolioUpside == sellReadyUpside) {
        gateFailures.add('both upside tiles read ' + portfolioUpside + ' - they cannot be told '
            + 'apart on screen. At least one in-the-money asset must be outside the GREEN band');
    }
}
for (String q : gateFailures) {
    System.debug(LoggingLevel.ERROR, TAG + 'QUALITY GATE: ' + q);
}

if (DRY_RUN) {
    System.debug(LoggingLevel.ERROR, TAG + '*** DRY RUN COMPLETE - ZERO ROWS WRITTEN ***');
    System.debug(LoggingLevel.ERROR, TAG + '*** The band/upside numbers above are the org AS IT '
        + 'IS NOW, not the post-seed state. Set DRY_RUN = false to stamp. ***');
} else if (totalWrites == 0) {
    System.debug(LoggingLevel.ERROR, TAG + '*** ZERO ROWS WRITTEN BY PHASE 2 ***');
    System.debug(LoggingLevel.ERROR, TAG + '*** Every candidate already had a Peak_Sell_Date__c. '
        + 'If the bands above look wrong, set RESTAMP_EXISTING_SELL_METER_INPUTS = true. ***');
} else {
    System.debug(LoggingLevel.ERROR, TAG + 'PHASE 2 WROTE ' + totalWrites + ' asset stamp(s).');
    System.debug(LoggingLevel.ERROR, TAG + 'NEXT: seed-disposition-lifecycle-03-dispositions.apex');
}
System.debug(LoggingLevel.ERROR, TAG + 'Limits: SOQL ' + Limits.getQueries() + '/'
    + Limits.getLimitQueries() + ' DML ' + Limits.getDmlStatements() + ' CPU '
    + Limits.getCpuTime() + 'ms');

// Throwing rolls back THIS PHASE ONLY. Phase 1's Closed Won cascade is already committed and is
// not recoverable - that is the stated cost of splitting. Phase 2 is safely re-runnable.
if (STRICT) {
    System.assert(gateFailures.isEmpty(),
        'ROLLED BACK (phase 2 only) - the stamps committed but did not produce a usable meter: '
        + String.join(gateFailures, ' || ') + '  ==> phase 2 wrote NOTHING; phase 1 is unaffected '
        + 'and still committed. Fix the inputs and re-run phase 2.');
}
