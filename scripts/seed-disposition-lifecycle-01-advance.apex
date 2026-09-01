// seed-disposition-lifecycle-01-advance.apex   PHASE 1 of 4
//
// DOES: advances up to MAX_OPPS_TO_ADVANCE Opportunities 'New' -> 'Closed Won' so
// PropertyAssetService.ensureOnClosedWon creates the Property_Asset__c rows through the app's
// real handoff path. Signs each deal's NDA and ticks Contract_Signed__c first - two ACTIVE
// validation rules gate the stage.
//
// NEEDS FIRST: nothing. This is phase 1.
//
// ASSERTS: FLS on every field ALL FOUR phases write; both Disposition record types available;
// >= 3 Broker Contacts; a three-band spread is achievable; the NDA gate is open (re-read from
// the database, not trusted); assets were actually created; >= MIN_OPPS_LEFT_AT_NEW deals remain
// at 'New'; Dead/Pass unmoved; no Transaction__c created.
//
// ðŸ”´ THE ONLY IRREVERSIBLE PHASE. Fires automation no later phase can undo: SharePoint folder
// claims (real Microsoft Graph callouts, async), 2 notifications per deal, and one Onboarding__c
// per new asset -> ~45 Tasks EACH. Creates NO Transaction__c.
// Full blast radius + the approval decision (do not submit, zero emails), and why this run is
// split at all:  scripts/seed-disposition-lifecycle-2026-09-01.md  <- READ FIRST.

Boolean DRY_RUN = true;
Boolean STRICT = true;
Integer MAX_OPPS_TO_ADVANCE = 3;
Integer MIN_OPPS_LEFT_AT_NEW = 2;

String TAG = 'SEED1 | ';
Integer totalWrites = 0;
List<String> gateFailures = new List<String>();

System.debug(LoggingLevel.ERROR, TAG + '===== PHASE 1 / 4  ADVANCE TO CLOSED WON =====');
System.debug(LoggingLevel.ERROR, TAG + 'MODE: ' + (DRY_RUN
    ? '*** DRY RUN - NOTHING WILL BE WRITTEN ***' : '*** COMMITTING - IRREVERSIBLE ***'));

Organization theOrg = [SELECT Id, Name, IsSandbox, OrganizationType FROM Organization LIMIT 1];
System.debug(LoggingLevel.ERROR, TAG + 'Org: ' + theOrg.Name + ' (' + theOrg.Id + ') IsSandbox='
    + theOrg.IsSandbox + ' Type=' + theOrg.OrganizationType);
if (!theOrg.IsSandbox) {
    System.debug(LoggingLevel.ERROR, TAG + '!! NOT A SANDBOX. Everything below is permanent. !!');
}

// ---------------------------------------------------------------------------------------
// FEASIBILITY PRE-FLIGHT FOR THE WHOLE RUN.
// A split into four transactions removed the cross-script rollback: if phase 4 fails, phase 1
// is already committed and cannot be undone. So the irreversible phase refuses to fire unless
// what phases 2-4 need is present NOW. See the companion .md, "THE COST OF SPLITTING".
// ---------------------------------------------------------------------------------------

Map<String, List<String>> fieldsNeeded = new Map<String, List<String>>();
fieldsNeeded.put('Opportunity', new List<String>{
    'StageName', 'Contract_Signed__c', 'Primary_NDA__c' });
fieldsNeeded.put('NDA__c', new List<String>{ 'Status__c' });
fieldsNeeded.put('Property_Asset__c', new List<String>{
    'Peak_Sell_Date__c', 'NOI__c', 'Market_Cap_Rate__c', 'Target_Sale_Price__c',
    'Projected_Value_At_Peak__c', 'Argus_Value__c', 'Argus_Signal__c', 'Property_Type__c' });
fieldsNeeded.put('Disposition__c', new List<String>{
    'Property_Asset__c', 'Disposition_Stage__c', 'Sell_Decision_Trigger__c',
    'Sell_Meter_Override_Reason__c', 'Brokers_Contacted__c', 'Package_Sent__c',
    'Submission_Deadline__c' });
fieldsNeeded.put('BOV_Submission__c', new List<String>{
    'Disposition__c', 'Broker__c', 'BOV_Amount__c', 'Commission_Rate__c', 'Days_To_Market__c',
    'Hist_Success_Rate__c', 'Cap_Rate__c', 'Is_Buyer_Ready__c', 'Is_Known_Performer__c' });

Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
List<String> accessGaps = new List<String>();
for (String objName : fieldsNeeded.keySet()) {
    // globalDescribe keys are LOWERCASE and an Apex String-keyed Map is case sensitive.
    Schema.SObjectType t = gd.get(objName.toLowerCase());
    if (t == null) {
        accessGaps.add(objName + ' -> object not visible to this user at all');
        continue;
    }
    Schema.DescribeSObjectResult od = t.getDescribe();
    if (!od.isAccessible()) {
        accessGaps.add(objName + ' -> no Read');
    }
    Map<String, Schema.SObjectField> fm = od.fields.getMap();
    for (String fn : fieldsNeeded.get(objName)) {
        Schema.SObjectField f = fm.get(fn.toLowerCase());
        if (f == null) {
            accessGaps.add(objName + '.' + fn
                + ' -> ABSENT from this user\'s schema (0 FieldPermissions rows)');
            continue;
        }
        Schema.DescribeFieldResult fd = f.getDescribe();
        if (!fd.isUpdateable() && !fd.isCreateable()) {
            accessGaps.add(objName + '.' + fn + ' -> not writable for this user');
        }
    }
}
Schema.SObjectType dispType = gd.get('disposition__c');
if (dispType == null || !dispType.getDescribe().isCreateable()) {
    accessGaps.add('Disposition__c -> no Create (needed by phase 3)');
}
Schema.SObjectType bovType = gd.get('bov_submission__c');
if (bovType == null || !bovType.getDescribe().isCreateable()) {
    accessGaps.add('BOV_Submission__c -> no Create (needed by phase 4)');
}
for (String g : accessGaps) {
    System.debug(LoggingLevel.ERROR, TAG + 'ACCESS GAP: ' + g);
}
System.assert(accessGaps.isEmpty(),
    'ABORTED - this user cannot write everything the 4-phase run needs (' + accessGaps.size()
    + ' gaps above). Assign DPEG_Acquisition_Edit, DPEG_PropertyMgmt_Edit, DPEG_Disposition_Edit.');

// Record types must exist AND be available - isAvailable() is what DispositionService tests.
Map<String, Schema.RecordTypeInfo> rts =
    Schema.SObjectType.Disposition__c.getRecordTypeInfosByDeveloperName();
Schema.RecordTypeInfo onInfo = rts.get('On_Market');
Schema.RecordTypeInfo offInfo = rts.get('Off_Market');
System.assert(onInfo != null && onInfo.isAvailable() && offInfo != null && offInfo.isAvailable(),
    'ABORTED - a Disposition__c record type is missing or unavailable. Phase 3 would fail.');

// Phase 4 needs >= 3 Broker Contacts: BOV_Submission__c.Broker__c has an ACTIVE non-optional
// lookup filter on Contact.RecordType.DeveloperName = 'Broker', and the matrix badge needs 3.
Integer brokerCount = [SELECT COUNT() FROM Contact WHERE RecordType.DeveloperName = 'Broker'];
System.debug(LoggingLevel.ERROR, TAG + 'Broker Contacts (phase 4 needs 3): ' + brokerCount);
System.assert(brokerCount >= 3,
    'ABORTED - only ' + brokerCount + ' Broker Contacts. Phase 4 could not clear the matrix '
    + 'threshold, so this irreversible phase will not fire. Run seed-broker-contacts.apex first.');

// ---------------------------------------------------------------------------------------
// BASELINE - every delta below is measured, never assumed from a brief.
// ---------------------------------------------------------------------------------------
Integer baseAssets = [SELECT COUNT() FROM Property_Asset__c];
Integer baseOnboardings = [SELECT COUNT() FROM Onboarding__c];
Integer baseTasks = [SELECT COUNT() FROM Task];
Integer baseTransactions = [SELECT COUNT() FROM Transaction__c];
Integer newCount = 0;
Integer deadPassCount = 0;
for (Opportunity o : [SELECT Id, StageName FROM Opportunity]) {
    if (o.StageName == 'New') {
        newCount++;
    } else if (o.StageName == 'Dead/Pass') {
        deadPassCount++;
    }
}
System.debug(LoggingLevel.ERROR, TAG + 'BASELINE asset=' + baseAssets + ' onboarding='
    + baseOnboardings + ' task=' + baseTasks + ' txn=' + baseTransactions + ' | Opp New='
    + newCount + ' Dead/Pass=' + deadPassCount + ' (Dead/Pass is NEVER touched)');

// ---------------------------------------------------------------------------------------
// CHOOSE. 'Dead/Pass' and 'Closed Won' are excluded by the WHERE clause itself, not by a
// downstream check.
// ---------------------------------------------------------------------------------------
List<Opportunity> raw = [
    SELECT Id, Name, StageName, CloseDate, Contract_Signed__c,
           Property__c, Property__r.Name, Property__r.Asset_Type__c,
           Primary_NDA__c, Primary_NDA__r.NDA_Signed__c
    FROM Opportunity
    WHERE StageName = 'New' AND Property__c != null
    ORDER BY CreatedDate ASC];
Set<Id> rawPropIds = new Set<Id>();
for (Opportunity o : raw) {
    rawPropIds.add(o.Property__c);
}
Set<Id> propsWithAsset = new Set<Id>();
for (Property_Asset__c pa : [
        SELECT Property__c FROM Property_Asset__c WHERE Property__c IN :rawPropIds]) {
    propsWithAsset.add(pa.Property__c);
}
List<Opportunity> eligible = new List<Opportunity>();
Set<Id> seenProps = new Set<Id>();
for (Opportunity o : raw) {
    // Both skips mirror PropertyAssetService: it keys on Property__c and creates at most one
    // asset per property, so advancing either kind pays the whole cascade for zero new assets.
    if (propsWithAsset.contains(o.Property__c) || seenProps.contains(o.Property__c)) {
        System.debug(LoggingLevel.ERROR, TAG + '  skip "' + o.Name
            + '" - its Property already has, or is already covered by, an asset');
        continue;
    }
    seenProps.add(o.Property__c);
    eligible.add(o);
}
Integer floorCap = newCount - MIN_OPPS_LEFT_AT_NEW;
Integer target = Math.min(Math.min(MAX_OPPS_TO_ADVANCE, floorCap), eligible.size());
System.debug(LoggingLevel.ERROR, TAG + 'Eligible=' + eligible.size() + ' cap(MAX)='
    + MAX_OPPS_TO_ADVANCE + ' cap(pipeline floor ' + newCount + '-' + MIN_OPPS_LEFT_AT_NEW + ')='
    + floorCap + ' => TAKING ' + target);
System.assert(target >= 1,
    'ABORTED - nothing can be advanced without breaking a stated constraint. Eligible='
    + eligible.size() + ', at New=' + newCount + ', floor=' + MIN_OPPS_LEFT_AT_NEW + '.');

// Feasibility for phase 2: three bands need three stampable assets. Assets with a null
// Peak_Sell_Date__c are invisible to the Sell Meter today, so phase 2 may top up from them.
Integer nullPeakAssets = [
    SELECT COUNT() FROM Property_Asset__c WHERE Peak_Sell_Date__c = null AND Property__c != null];
Integer stampable = target + nullPeakAssets;
System.debug(LoggingLevel.ERROR, TAG + 'Stampable for phase 2: ' + target + ' new + '
    + nullPeakAssets + ' no-peak existing = ' + stampable + ' (need 3)');
System.assert(stampable >= 3,
    'ABORTED - only ' + stampable + ' stampable asset(s); phase 2 could not produce a '
    + 'GREEN/YELLOW/RED spread. Refusing to fire the irreversible phase for a run that '
    + 'cannot finish.');

List<Opportunity> chosen = new List<Opportunity>();
for (Integer i = 0; i < target; i++) {
    chosen.add(eligible[i]);
    System.debug(LoggingLevel.ERROR, TAG + '  CHOSEN: "' + eligible[i].Name + '" -> Property "'
        + eligible[i].Property__r.Name + '" (Asset_Type__c='
        + eligible[i].Property__r.Asset_Type__c + ', CloseDate=' + eligible[i].CloseDate + ')');
}

// ---------------------------------------------------------------------------------------
// PREPARE THE VALIDATION-RULE GATE.
// Contract_Signed_Before_Closed_Won reads a Checkbox on the same record (post-save values, so
// it could ride along) - set early anyway so a failure is attributable.
// NDA_Signed_Before_Deal_Progression spans to Primary_NDA__r.NDA_Signed__c, read from the
// DATABASE, so the NDA must be signed in a SEPARATE EARLIER statement. Hence three DML.
// Sign by writing Status__c = 'Signed': NDA_Signed__c is DERIVED by the ACTIVE before-save flow
// NDA_Signed_Status_Sync. 'Signed' is valid on Acquisition_NDA (checked in the recordType XML,
// not the field describe, which hides record-type subsets).
// ---------------------------------------------------------------------------------------
Set<Id> chosenIds = new Set<Id>();
for (Opportunity o : chosen) {
    chosenIds.add(o.Id);
}
Map<Id, NDA__c> ndaByOpp = new Map<Id, NDA__c>();
for (NDA__c n : [
        SELECT Id, Name, Opportunity__c, Status__c, NDA_Signed__c
        FROM NDA__c WHERE Opportunity__c IN :chosenIds ORDER BY CreatedDate ASC]) {
    ndaByOpp.put(n.Opportunity__c, n);   // ASC + overwrite leaves the NEWEST per deal
}
List<NDA__c> ndaUpdates = new List<NDA__c>();
List<Opportunity> oppPrep = new List<Opportunity>();
List<Opportunity> toAdvance = new List<Opportunity>();
for (Opportunity o : chosen) {
    Id ndaId = o.Primary_NDA__c;
    Boolean signed = (o.Primary_NDA__c != null && o.Primary_NDA__r.NDA_Signed__c == true);
    NDA__c fallback = ndaByOpp.get(o.Id);
    if (ndaId == null) {
        if (fallback == null) {
            // Deliberately does not CREATE one: NDA record-type / restricted-picklist hazards.
            System.debug(LoggingLevel.ERROR, TAG + '  DROP "' + o.Name
                + '" - no NDA__c on the deal. Create one and re-run.');
            continue;
        }
        ndaId = fallback.Id;
        signed = (fallback.NDA_Signed__c == true);
    }
    if (!signed) {
        ndaUpdates.add(new NDA__c(Id = ndaId, Status__c = 'Signed'));
    }
    Opportunity prep = new Opportunity(Id = o.Id);
    Boolean needed = false;
    if (o.Primary_NDA__c != ndaId) {
        prep.Primary_NDA__c = ndaId;
        needed = true;
    }
    if (o.Contract_Signed__c != true) {
        prep.Contract_Signed__c = true;
        needed = true;
    }
    if (needed) {
        oppPrep.add(prep);
    }
    toAdvance.add(new Opportunity(Id = o.Id, StageName = 'Closed Won'));
}
System.assert(!toAdvance.isEmpty(),
    'ABORTED - every chosen Opportunity was dropped for having no NDA. See the DROP lines.');
System.debug(LoggingLevel.ERROR, TAG + 'PLAN: sign ' + ndaUpdates.size() + ' NDA, prep '
    + oppPrep.size() + ' Opportunity, advance ' + toAdvance.size() + ' to Closed Won');

// ---------------------------------------------------------------------------------------
// WRITE
// ---------------------------------------------------------------------------------------
Integer wroteNdas = 0;
Integer wrotePrep = 0;
Integer wroteAdv = 0;

if (DRY_RUN) {
    System.debug(LoggingLevel.ERROR, TAG + '[DRY RUN] would UPDATE ' + ndaUpdates.size()
        + ' NDA__c (Status__c = Signed)');
    System.debug(LoggingLevel.ERROR, TAG + '[DRY RUN] would UPDATE ' + oppPrep.size()
        + ' Opportunity (Primary_NDA__c / Contract_Signed__c)');
    System.debug(LoggingLevel.ERROR, TAG + '[DRY RUN] would UPDATE ' + toAdvance.size()
        + ' Opportunity (StageName = Closed Won) <- cascade fires HERE: ~45 Tasks per new asset '
        + 'via Onboarding_Task_Fanout, plus SharePoint callouts. NO Transaction__c.');
} else {
    if (!ndaUpdates.isEmpty()) {
        List<Database.SaveResult> rs = Database.update(ndaUpdates, false);
        for (Integer i = 0; i < rs.size(); i++) {
            if (rs[i].isSuccess()) {
                wroteNdas++;
            } else {
                // Every error on the row, not getErrors()[0] - an access refusal and a
                // validation rule arrive together and reporting one misdirects the reader.
                for (Database.Error e : rs[i].getErrors()) {
                    System.debug(LoggingLevel.ERROR, TAG + '  NDA FAIL ' + ndaUpdates[i].Id + ': '
                        + e.getStatusCode() + ' - ' + e.getMessage() + ' fields='
                        + String.valueOf(e.getFields()));
                }
            }
        }
    }
    System.debug(LoggingLevel.ERROR, TAG + 'NDAs signed: ' + wroteNdas + '/' + ndaUpdates.size());
    System.assert(wroteNdas == ndaUpdates.size(),
        'ABORTED before the stage advance - ' + (ndaUpdates.size() - wroteNdas) + ' NDA(s) refused '
        + 'the Signed status. Advancing now would trip NDA_Signed_Before_Deal_Progression. '
        + 'This throw rolls back everything phase 1 has written so far.');
    totalWrites += wroteNdas;

    if (!oppPrep.isEmpty()) {
        List<Database.SaveResult> rs = Database.update(oppPrep, false);
        for (Integer i = 0; i < rs.size(); i++) {
            if (rs[i].isSuccess()) {
                wrotePrep++;
            } else {
                for (Database.Error e : rs[i].getErrors()) {
                    System.debug(LoggingLevel.ERROR, TAG + '  PREP FAIL ' + oppPrep[i].Id + ': '
                        + e.getStatusCode() + ' - ' + e.getMessage() + ' fields='
                        + String.valueOf(e.getFields()));
                }
            }
        }
    }
    System.debug(LoggingLevel.ERROR, TAG + 'Opportunity prep: ' + wrotePrep + '/' + oppPrep.size());
    System.assert(wrotePrep == oppPrep.size(),
        'ABORTED before the stage advance - ' + (oppPrep.size() - wrotePrep) + ' prep row(s) '
        + 'failed. See the PREP FAIL lines. Everything is rolled back.');
    totalWrites += wrotePrep;

    // CONFIRM THE GATE FROM THE DATABASE. The NDA flow is before-save on another object and
    // the VR spans to it; re-reading is the only proof the gate is open.
    List<String> notReady = new List<String>();
    for (Opportunity o : [
            SELECT Id, Name, Contract_Signed__c, Primary_NDA__c, Primary_NDA__r.NDA_Signed__c
            FROM Opportunity WHERE Id IN :chosenIds]) {
        if (o.Contract_Signed__c != true) {
            notReady.add(o.Name + ' -> Contract_Signed__c still false');
        }
        if (o.Primary_NDA__c == null) {
            notReady.add(o.Name + ' -> Primary_NDA__c still blank');
        } else if (o.Primary_NDA__r.NDA_Signed__c != true) {
            notReady.add(o.Name + ' -> NDA_Signed__c still false (NDA_Signed_Status_Sync did not '
                + 'derive it from Status__c)');
        }
    }
    for (String s : notReady) {
        System.debug(LoggingLevel.ERROR, TAG + '  NOT READY: ' + s);
    }
    System.assert(notReady.isEmpty(),
        'ABORTED - the Closed Won gate is still closed on ' + notReady.size()
        + ' condition(s) after the prep writes. See the NOT READY lines. Everything rolled back.');

    System.debug(LoggingLevel.ERROR, TAG + 'ADVANCING ' + toAdvance.size()
        + ' Opportunity row(s) - CASCADE STARTS HERE');
    List<Database.SaveResult> rs2 = Database.update(toAdvance, false);
    for (Integer i = 0; i < rs2.size(); i++) {
        if (rs2[i].isSuccess()) {
            wroteAdv++;
        } else {
            for (Database.Error e : rs2[i].getErrors()) {
                System.debug(LoggingLevel.ERROR, TAG + '  ADVANCE FAIL ' + toAdvance[i].Id + ': '
                    + e.getStatusCode() + ' - ' + e.getMessage() + ' fields='
                    + String.valueOf(e.getFields()));
            }
        }
    }
    System.debug(LoggingLevel.ERROR, TAG + 'Advanced: ' + wroteAdv + '/' + toAdvance.size());
    System.assert(wroteAdv == toAdvance.size(),
        'ABORTED - ' + (toAdvance.size() - wroteAdv) + ' Opportunity/ies refused the advance. '
        + 'The whole phase is rolled back rather than leaving a partial handoff.');
    totalWrites += wroteAdv;
}

// ---------------------------------------------------------------------------------------
// VERIFY + GATES
// ---------------------------------------------------------------------------------------
Integer nowAssets = baseAssets;
Integer nowOnboardings = baseOnboardings;
Integer nowTasks = baseTasks;
Integer nowTransactions = baseTransactions;
Integer nowNew = newCount;
Integer nowDeadPass = deadPassCount;
Integer nowClosedWon = 0;

if (!DRY_RUN) {
    nowAssets = [SELECT COUNT() FROM Property_Asset__c];
    nowOnboardings = [SELECT COUNT() FROM Onboarding__c];
    nowTasks = [SELECT COUNT() FROM Task];
    nowTransactions = [SELECT COUNT() FROM Transaction__c];
    nowNew = 0;
    nowDeadPass = 0;
    for (Opportunity o : [SELECT Id, StageName FROM Opportunity]) {
        if (o.StageName == 'New') {
            nowNew++;
        } else if (o.StageName == 'Dead/Pass') {
            nowDeadPass++;
        } else if (o.StageName == 'Closed Won') {
            nowClosedWon++;
        }
    }
    // "Reports success, writes nothing" is the exact failure the runbook warns about.
    System.assert(nowAssets > baseAssets,
        'ABORTED - the advance reported success but created ZERO Property_Asset__c rows. '
        + 'PropertyAssetService.ensureOnClosedWon did not run or skipped every deal. Rolled back.');
    if (nowNew < MIN_OPPS_LEFT_AT_NEW) {
        gateFailures.add('only ' + nowNew + ' Opportunities left at New; the floor is '
            + MIN_OPPS_LEFT_AT_NEW);
    }
    if (nowDeadPass != deadPassCount) {
        gateFailures.add('the Dead/Pass count MOVED (' + deadPassCount + ' -> ' + nowDeadPass
            + '). It was supposed to be untouched.');
    }
    if (nowTransactions != baseTransactions) {
        gateFailures.add('Transaction__c moved (' + baseTransactions + ' -> ' + nowTransactions
            + '). This path should create none - if it did, the 82-task Transaction_Task_Fanout '
            + 'is running and the blast radius is far larger than documented.');
    }
}

System.debug(LoggingLevel.ERROR, TAG + '--- COUNTS (baseline -> now) ---');
System.debug(LoggingLevel.ERROR, TAG + '  Property_Asset__c  ' + baseAssets + ' -> ' + nowAssets);
System.debug(LoggingLevel.ERROR, TAG + '  Onboarding__c      ' + baseOnboardings + ' -> '
    + nowOnboardings + '  (side effect of the asset creation)');
System.debug(LoggingLevel.ERROR, TAG + '  Task               ' + baseTasks + ' -> ' + nowTasks
    + '  (SYNCHRONOUS only - the ~45-per-Onboarding fan-out lands AFTER commit. RECOUNT.)');
System.debug(LoggingLevel.ERROR, TAG + '  Transaction__c     ' + baseTransactions + ' -> '
    + nowTransactions + '  (expected UNCHANGED)');
System.debug(LoggingLevel.ERROR, TAG + '  Opportunity  New=' + nowNew + ' ClosedWon=' + nowClosedWon
    + ' Dead/Pass=' + nowDeadPass + ' (Dead/Pass baseline was ' + deadPassCount + ')');
for (String q : gateFailures) {
    System.debug(LoggingLevel.ERROR, TAG + 'QUALITY GATE: ' + q);
}

if (DRY_RUN) {
    System.debug(LoggingLevel.ERROR, TAG + '*** DRY RUN COMPLETE - ZERO ROWS WRITTEN ***');
    System.debug(LoggingLevel.ERROR, TAG + '*** Read the plan above, then set DRY_RUN = false. ***');
} else if (totalWrites == 0) {
    System.debug(LoggingLevel.ERROR, TAG + '*** ZERO ROWS WRITTEN BY PHASE 1 ***');
    System.debug(LoggingLevel.ERROR, TAG + '*** Nothing needed doing, or every guard skipped. ***');
} else {
    System.debug(LoggingLevel.ERROR, TAG + 'PHASE 1 WROTE ' + totalWrites + ' row(s): NDAs='
        + wroteNdas + ' prep=' + wrotePrep + ' advanced=' + wroteAdv);
    System.debug(LoggingLevel.ERROR, TAG + 'Trigger-created rows (assets, Onboardings) are NOT '
        + 'in that total - read the COUNTS block.');
    System.debug(LoggingLevel.ERROR, TAG + 'APPROVALS SUBMITTED: 0.  APPROVAL EMAILS SENT: 0.');
    System.debug(LoggingLevel.ERROR, TAG + 'STILL ASYNC AFTER COMMIT: DealFolderQueueable '
        + 'SharePoint callouts, and ~45 Tasks per new Onboarding.');
    System.debug(LoggingLevel.ERROR, TAG + 'NEXT: seed-disposition-lifecycle-02-assets.apex');
}
System.debug(LoggingLevel.ERROR, TAG + 'Limits: SOQL ' + Limits.getQueries() + '/'
    + Limits.getLimitQueries() + ' DML ' + Limits.getDmlStatements() + '/'
    + Limits.getLimitDmlStatements() + ' CPU ' + Limits.getCpuTime() + 'ms');

// Last statement: throwing here rolls back everything THIS PHASE wrote. It cannot roll back a
// previous phase - there is no previous phase, which is why the heavy gates live here.
if (STRICT) {
    System.assert(gateFailures.isEmpty(),
        'ROLLED BACK - phase 1 committed its DML but broke a stated invariant: '
        + String.join(gateFailures, ' || ') + '  ==> NOTHING was kept.');
}
