// seed-disposition-lifecycle-03-dispositions.apex   PHASE 3 of 4
//
// DOES: creates ONE On_Market and ONE Off_Market Disposition__c, both at 'Disposition Readiness',
// on the GREEN and YELLOW assets respectively - so both Paths, both record types and the
// record-type-dependent Approval Tracker row are all observable.
//
// NEEDS FIRST: phases 1 and 2. It does NOT trust them - it re-reads peak sell dates from the org
// and picks green/yellow deterministically (ORDER BY Peak_Sell_Date__c, Name), bailing if either
// band is missing.
//
// ASSERTS: FLS; both record types available; a GREEN and a YELLOW asset exist; every insert
// committed; both record types end up with at least one Disposition.
//
// 🔴 SUBMITS NOTHING. No approval is submitted, zero approval emails. Both records stay at
// 'Disposition Readiness', which IS Sale_Decision_Approval's entryCriteria - so the real Submit
// for Approval button works whenever you want it, and the emails go out at a moment you choose.
// Full reasoning: scripts/seed-disposition-lifecycle-2026-09-01.md

Boolean DRY_RUN = true;
Boolean STRICT = true;
// Leave FALSE. Advancing past 'Disposition Readiness' takes the record OUT of
// Sale_Decision_Approval's entry criteria and permanently removes your ability to run the real
// approval from the UI. Flip only if you would rather see the BOV panel on-stage.
Boolean ADVANCE_ON_MARKET_TO_BOV_OUTREACH = false;

String TAG = 'SEED3 | ';
Integer totalWrites = 0;
List<String> gateFailures = new List<String>();

System.debug(LoggingLevel.ERROR, TAG + '===== PHASE 3 / 4  DISPOSITIONS =====');
System.debug(LoggingLevel.ERROR, TAG + 'MODE: ' + (DRY_RUN
    ? '*** DRY RUN - NOTHING WILL BE WRITTEN ***' : '*** COMMITTING ***'));

// ---------------------------------------------------------------------------------------
// FLS + record types
// ---------------------------------------------------------------------------------------
List<String> myFields = new List<String>{
    'Property_Asset__c', 'Disposition_Stage__c', 'Sell_Decision_Trigger__c',
    'Sell_Meter_Override_Reason__c', 'Brokers_Contacted__c', 'Package_Sent__c',
    'Submission_Deadline__c' };
Schema.DescribeSObjectResult dd = Schema.SObjectType.Disposition__c;
Map<String, Schema.SObjectField> fm = dd.fields.getMap();
List<String> accessGaps = new List<String>();
if (!dd.isCreateable()) {
    accessGaps.add('Disposition__c -> no Create');
}
for (String fn : myFields) {
    Schema.SObjectField f = fm.get(fn.toLowerCase());   // map keys are lowercase
    if (f == null) {
        accessGaps.add('Disposition__c.' + fn + ' -> ABSENT from this user\'s schema');
    } else if (!f.getDescribe().isCreateable()) {
        accessGaps.add('Disposition__c.' + fn + ' -> not createable for this user');
    }
}
for (String g : accessGaps) {
    System.debug(LoggingLevel.ERROR, TAG + 'ACCESS GAP: ' + g);
}
System.assert(accessGaps.isEmpty(),
    'ABORTED - ' + accessGaps.size() + ' access gap(s). Assign DPEG_Disposition_Edit.');

Map<String, Schema.RecordTypeInfo> rts =
    Schema.SObjectType.Disposition__c.getRecordTypeInfosByDeveloperName();
Schema.RecordTypeInfo onInfo = rts.get('On_Market');
Schema.RecordTypeInfo offInfo = rts.get('Off_Market');
System.assert(onInfo != null && onInfo.isAvailable() && offInfo != null && offInfo.isAvailable(),
    'ABORTED - a Disposition__c record type is missing or unavailable to this user. Never assign '
    + 'a null RecordTypeId: an explicit null on an Id-typed system field is REFUSED, not ignored.');
Id onRt = onInfo.getRecordTypeId();
Id offRt = offInfo.getRecordTypeId();

// ---------------------------------------------------------------------------------------
// PRECONDITION: find GREEN and YELLOW from the ORG, not from phase 2's memory. Deterministic
// ordering means a re-run picks the same two assets. bandForPeak is reproduced here (same
// thresholds) because anonymous Apex cannot call a private method.
// ---------------------------------------------------------------------------------------
Id greenId = null;
String greenName = null;
Id yellowId = null;
String yellowName = null;
Integer meterRows = 0;
for (Property_Asset__c a : [
        SELECT Id, Name, Peak_Sell_Date__c
        FROM Property_Asset__c
        WHERE Property__c != null AND Peak_Sell_Date__c != null
        ORDER BY Peak_Sell_Date__c ASC, Name ASC]) {
    meterRows++;
    Integer days = Date.today().daysBetween(a.Peak_Sell_Date__c);
    if (days <= 30 && greenId == null) {
        greenId = a.Id;
        greenName = a.Name;
    } else if (days > 30 && days <= 90 && yellowId == null) {
        yellowId = a.Id;
        yellowName = a.Name;
    }
}
System.debug(LoggingLevel.ERROR, TAG + 'Sell-Meter-visible assets: ' + meterRows);
System.debug(LoggingLevel.ERROR, TAG + 'GREEN  -> On_Market  : ' + greenName + ' (' + greenId + ')');
System.debug(LoggingLevel.ERROR, TAG + 'YELLOW -> Off_Market : ' + yellowName + ' (' + yellowId + ')');
System.assert(meterRows > 0,
    'ABORTED - no asset satisfies PropertyAssetSelector\'s predicate (Property__c != null AND '
    + 'Peak_Sell_Date__c != null). Phase 2 has not run or wrote nothing. Run '
    + 'seed-disposition-lifecycle-02-assets.apex and check its summary reports rows written.');
System.assert(greenId != null && yellowId != null,
    'ABORTED - need one GREEN and one YELLOW asset; found green=' + greenId + ' yellow=' + yellowId
    + '. Property_Asset_Required_On_Save makes an asset-less Disposition impossible, and putting '
    + 'both dispositions on the same band would make the two upside tiles indistinguishable.');

// ---------------------------------------------------------------------------------------
// BUILD. Field set is verbatim what DispositionService.initiateAndSubmit STEP 4/4b inserts:
// Property_Asset__c + Disposition_Stage__c + RecordTypeId, plus the override pair on a non-green
// band. NO Asking_Price__c (retired 2026-08-25). NO Broker__c - Broker_Lookup_Is_Off_Market_Only
// refuses it on an On_Market row. NO Responses_Received__c - DispositionCounterRollupService
// owns it and the BOV trigger overwrites any hand-set value seconds later.
// 'Principal Decision' is verified present on BOTH record types' Sell_Decision_Trigger__c
// subsets; restricted picklists are DML-enforced in this org.
// ---------------------------------------------------------------------------------------
Integer wroteDisp = 0;
Id onDispId = null;
Id offDispId = null;

if (DRY_RUN) {
    System.debug(LoggingLevel.ERROR, TAG + '[DRY RUN] would INSERT 2 Disposition__c:');
    System.debug(LoggingLevel.ERROR, TAG + '   On_Market  on "' + greenName + '", stage '
        + 'Disposition Readiness, Brokers_Contacted__c=6, Package_Sent__c=today-14, '
        + 'Submission_Deadline__c=today+7');
    System.debug(LoggingLevel.ERROR, TAG + '   Off_Market on "' + yellowName + '", stage '
        + 'Disposition Readiness, Sell_Decision_Trigger__c=Principal Decision + override reason');
    System.debug(LoggingLevel.ERROR, TAG + '[DRY RUN] 0 approvals submitted, 0 emails.');
} else {
    Set<Id> pair = new Set<Id>{ greenId, yellowId };
    Map<Id, Disposition__c> existingByAsset = new Map<Id, Disposition__c>();
    for (Disposition__c d : [
            SELECT Id, Name, Property_Asset__c FROM Disposition__c
            WHERE Property_Asset__c IN :pair ORDER BY CreatedDate ASC]) {
        existingByAsset.put(d.Property_Asset__c, d);
    }
    List<Disposition__c> toInsert = new List<Disposition__c>();
    Disposition__c haveOn = existingByAsset.get(greenId);
    if (haveOn != null) {
        onDispId = haveOn.Id;
        System.debug(LoggingLevel.ERROR, TAG + '  On_Market disposition already exists ('
            + haveOn.Name + ') - not creating a second one');
    } else {
        toInsert.add(new Disposition__c(
            Property_Asset__c = greenId,
            Disposition_Stage__c = 'Disposition Readiness',
            RecordTypeId = onRt,
            Brokers_Contacted__c = 6,
            Package_Sent__c = Date.today().addDays(-14),
            Submission_Deadline__c = Date.today().addDays(7)));
    }
    Disposition__c haveOff = existingByAsset.get(yellowId);
    if (haveOff != null) {
        offDispId = haveOff.Id;
        System.debug(LoggingLevel.ERROR, TAG + '  Off_Market disposition already exists ('
            + haveOff.Name + ') - not creating a second one');
    } else {
        toInsert.add(new Disposition__c(
            Property_Asset__c = yellowId,
            Disposition_Stage__c = 'Disposition Readiness',
            RecordTypeId = offRt,
            Sell_Decision_Trigger__c = 'Principal Decision',
            Sell_Meter_Override_Reason__c =
                'Seeded 2026-09-01. Yellow band (peak sell date 31-90 days out). Recorded so the '
                + 'sale-decision approval screen does not claim "Sell Meter Green", which would '
                + 'be false for this asset.'));
    }

    if (!toInsert.isEmpty()) {
        List<Database.SaveResult> rs = Database.insert(toInsert, false);
        for (Integer i = 0; i < rs.size(); i++) {
            if (rs[i].isSuccess()) {
                wroteDisp++;
                if (toInsert[i].RecordTypeId == onRt) {
                    onDispId = rs[i].getId();
                } else {
                    offDispId = rs[i].getId();
                }
            } else {
                for (Database.Error e : rs[i].getErrors()) {
                    System.debug(LoggingLevel.ERROR, TAG + '  DISPOSITION FAIL: '
                        + e.getStatusCode() + ' - ' + e.getMessage() + ' fields='
                        + String.valueOf(e.getFields()));
                }
            }
        }
    }
    System.debug(LoggingLevel.ERROR, TAG + 'Dispositions created: ' + wroteDisp + '/'
        + toInsert.size());
    System.assert(wroteDisp == toInsert.size(),
        'ABORTED - ' + (toInsert.size() - wroteDisp) + ' Disposition__c insert(s) failed. See the '
        + 'DISPOSITION FAIL lines. Phase 3 is rolled back; phases 1-2 are NOT.');
    totalWrites += wroteDisp;
    System.assert(onDispId != null && offDispId != null,
        'ABORTED - phase 3 finished without both an On_Market and an Off_Market disposition.');

    if (ADVANCE_ON_MARKET_TO_BOV_OUTREACH) {
        // 'BOV Outreach' is On_Market ONLY and is NOT one of the seven stages
        // All_NDAs_Signed_Before_Progression gates, so this is legal with no NDAs.
        List<Database.SaveResult> rs2 = Database.update(new List<Disposition__c>{
            new Disposition__c(Id = onDispId, Disposition_Stage__c = 'BOV Outreach') }, false);
        if (rs2[0].isSuccess()) {
            totalWrites++;
            System.debug(LoggingLevel.ERROR, TAG + '  On_Market advanced to BOV Outreach. '
                + 'Sale_Decision_Approval is NO LONGER submittable on it.');
        } else {
            for (Database.Error e : rs2[0].getErrors()) {
                System.debug(LoggingLevel.ERROR, TAG + '  STAGE FAIL: ' + e.getStatusCode()
                    + ' - ' + e.getMessage());
            }
        }
    }
}

// ---------------------------------------------------------------------------------------
// VERIFY + GATES
// ---------------------------------------------------------------------------------------
Integer allDisp = 0;
Integer onCount = 0;
Integer offCount = 0;
for (Disposition__c d : [SELECT Id, RecordTypeId FROM Disposition__c]) {
    allDisp++;
    if (d.RecordTypeId == onRt) {
        onCount++;
    } else if (d.RecordTypeId == offRt) {
        offCount++;
    }
}
System.debug(LoggingLevel.ERROR, TAG + 'Disposition__c total=' + allDisp + ' On_Market=' + onCount
    + ' Off_Market=' + offCount);
if (!DRY_RUN && (onCount < 1 || offCount < 1)) {
    gateFailures.add('a record type has no Disposition (On_Market=' + onCount + ' Off_Market='
        + offCount + ') - one of the two Paths cannot be demonstrated');
}
for (String q : gateFailures) {
    System.debug(LoggingLevel.ERROR, TAG + 'QUALITY GATE: ' + q);
}

if (DRY_RUN) {
    System.debug(LoggingLevel.ERROR, TAG + '*** DRY RUN COMPLETE - ZERO ROWS WRITTEN ***');
} else if (totalWrites == 0) {
    System.debug(LoggingLevel.ERROR, TAG + '*** ZERO ROWS WRITTEN BY PHASE 3 ***');
    System.debug(LoggingLevel.ERROR, TAG + '*** Both dispositions already existed on those '
        + 'assets. Compare the totals above with what you expected. ***');
} else {
    System.debug(LoggingLevel.ERROR, TAG + 'PHASE 3 WROTE ' + totalWrites + ' row(s).');
    System.debug(LoggingLevel.ERROR, TAG + 'APPROVALS SUBMITTED: 0.  APPROVAL EMAILS SENT: 0.');
    System.debug(LoggingLevel.ERROR, TAG + 'NEXT: seed-disposition-lifecycle-04-bovs.apex');
}
System.debug(LoggingLevel.ERROR, TAG + 'On_Market Id=' + onDispId + '  Off_Market Id=' + offDispId);
System.debug(LoggingLevel.ERROR, TAG + 'Limits: SOQL ' + Limits.getQueries() + ' DML '
    + Limits.getDmlStatements() + ' CPU ' + Limits.getCpuTime() + 'ms');

// Throwing rolls back THIS PHASE ONLY. Phases 1-2 remain committed; phase 1 in particular is
// not recoverable. Phase 3 is safely re-runnable once the input is fixed.
if (STRICT) {
    System.assert(gateFailures.isEmpty(),
        'ROLLED BACK (phase 3 only) - ' + String.join(gateFailures, ' || ')
        + '  ==> phase 3 wrote NOTHING; phases 1-2 are unaffected and still committed.');
}
