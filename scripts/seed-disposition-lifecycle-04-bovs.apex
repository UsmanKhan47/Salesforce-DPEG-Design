// seed-disposition-lifecycle-04-bovs.apex   PHASE 4 of 4
//
// DOES: creates BOV_Submission__c rows against the On_Market Disposition until it holds
// BOV_TARGET_COUNT, clearing the >= 3 threshold behind the "Matrix Generated" badge. Then prints
// the consolidated end-of-run report for all four phases.
//
// NEEDS FIRST: phases 1-3. It does NOT trust them - it finds the On_Market Disposition by record
// type from the org and bails if there is none.
//
// ASSERTS: FLS; an On_Market Disposition exists; >= 3 Broker Contacts; every insert committed;
// Responses_Received__c >= 3 afterwards (the matrix gate).
//
// The badge is earned by inserting real child rows: Responses_Received__c is owned by
// DispositionCounterRollupService and recalculated by the BOV trigger, so writing it directly is
// a lie that gets overwritten in the same transaction.
// Submission_Status__c and Is_Preferred_Broker__c are deliberately OMITTED so the field default
// applies and BovAutoSelectionService picks the winner itself.
// Details: scripts/seed-disposition-lifecycle-2026-09-01.md

Boolean DRY_RUN = true;
Boolean STRICT = true;
Integer BOV_TARGET_COUNT = 4;

String TAG = 'SEED4 | ';
Integer totalWrites = 0;
List<String> gateFailures = new List<String>();

System.debug(LoggingLevel.ERROR, TAG + '===== PHASE 4 / 4  BOV SUBMISSIONS =====');
System.debug(LoggingLevel.ERROR, TAG + 'MODE: ' + (DRY_RUN
    ? '*** DRY RUN - NOTHING WILL BE WRITTEN ***' : '*** COMMITTING ***'));

// ---------------------------------------------------------------------------------------
// FLS
// ---------------------------------------------------------------------------------------
List<String> myFields = new List<String>{
    'Disposition__c', 'Broker__c', 'BOV_Amount__c', 'Commission_Rate__c', 'Days_To_Market__c',
    'Hist_Success_Rate__c', 'Cap_Rate__c', 'Is_Buyer_Ready__c', 'Is_Known_Performer__c' };
Schema.DescribeSObjectResult bd = Schema.SObjectType.BOV_Submission__c;
Map<String, Schema.SObjectField> fm = bd.fields.getMap();
List<String> accessGaps = new List<String>();
if (!bd.isCreateable()) {
    accessGaps.add('BOV_Submission__c -> no Create');
}
for (String fn : myFields) {
    Schema.SObjectField f = fm.get(fn.toLowerCase());   // map keys are lowercase
    if (f == null) {
        accessGaps.add('BOV_Submission__c.' + fn + ' -> ABSENT from this user\'s schema');
    } else if (!f.getDescribe().isCreateable()) {
        accessGaps.add('BOV_Submission__c.' + fn + ' -> not createable for this user');
    }
}
for (String g : accessGaps) {
    System.debug(LoggingLevel.ERROR, TAG + 'ACCESS GAP: ' + g);
}
System.assert(accessGaps.isEmpty(),
    'ABORTED - ' + accessGaps.size() + ' access gap(s). Assign DPEG_Disposition_Edit.');

// ---------------------------------------------------------------------------------------
// PRECONDITION: find the On_Market Disposition from the ORG.
// ---------------------------------------------------------------------------------------
Map<String, Schema.RecordTypeInfo> rts =
    Schema.SObjectType.Disposition__c.getRecordTypeInfosByDeveloperName();
Schema.RecordTypeInfo onInfo = rts.get('On_Market');
Schema.RecordTypeInfo offInfo = rts.get('Off_Market');
System.assert(onInfo != null && offInfo != null,
    'ABORTED - a Disposition__c record type is missing.');
Id onRt = onInfo.getRecordTypeId();
Id offRt = offInfo.getRecordTypeId();

List<Disposition__c> onMarket = [
    SELECT Id, Name, Disposition_Stage__c, Responses_Received__c, Brokers_Contacted__c,
           Selected_Broker__c, Property_Asset__r.Name
    FROM Disposition__c
    WHERE RecordTypeId = :onRt
    ORDER BY CreatedDate DESC
    LIMIT 1];
System.assert(!onMarket.isEmpty(),
    'ABORTED - no On_Market Disposition__c exists. Phase 3 has not run or wrote nothing. Run '
    + 'seed-disposition-lifecycle-03-dispositions.apex and check its summary reports rows '
    + 'written before running this phase.');
Disposition__c target = onMarket[0];
System.debug(LoggingLevel.ERROR, TAG + 'On_Market disposition: ' + target.Name + ' ('
    + target.Id + ') asset="' + target.Property_Asset__r.Name + '" stage='
    + target.Disposition_Stage__c);

// Broker__c has an ACTIVE, non-optional lookup filter on Contact.RecordType.DeveloperName =
// 'Broker', and Broker_Required_On_Submission blocks a blank one. The query guarantees both.
List<Contact> brokers = [
    SELECT Id, Name FROM Contact
    WHERE RecordType.DeveloperName = 'Broker'
    ORDER BY CreatedDate ASC LIMIT 20];
System.debug(LoggingLevel.ERROR, TAG + 'Broker Contacts available: ' + brokers.size());
System.assert(brokers.size() >= 3,
    'ABORTED - only ' + brokers.size() + ' Broker Contacts. The matrix badge needs 3 responses. '
    + 'Run scripts/seed-broker-contacts.apex first.');

// ---------------------------------------------------------------------------------------
// BUILD - top up to BOV_TARGET_COUNT, never reusing a broker already on this disposition.
// ---------------------------------------------------------------------------------------
List<Decimal> bAmount = new List<Decimal>{ 39500000, 38250000, 40100000, 37400000 };
List<Decimal> bComm = new List<Decimal>{ 2.00, 1.75, 2.25, 1.50 };
List<Integer> bDays = new List<Integer>{ 120, 150, 95, 180 };
List<Decimal> bSuccess = new List<Decimal>{ 82.00, 68.00, 91.00, 55.00 };
List<Decimal> bCap = new List<Decimal>{ 6.10, 6.25, 5.95, 6.40 };
List<Boolean> bReady = new List<Boolean>{ true, false, true, false };
List<Boolean> bKnown = new List<Boolean>{ true, true, false, false };

Set<Id> brokersOn = new Set<Id>();
Integer existingBovs = 0;
for (BOV_Submission__c b : [
        SELECT Id, Broker__c FROM BOV_Submission__c WHERE Disposition__c = :target.Id]) {
    brokersOn.add(b.Broker__c);
    existingBovs++;
}
System.debug(LoggingLevel.ERROR, TAG + 'Existing BOVs on it: ' + existingBovs
    + ' | target: ' + BOV_TARGET_COUNT);

List<BOV_Submission__c> toInsert = new List<BOV_Submission__c>();
Integer idx = existingBovs;
for (Contact c : brokers) {
    if (toInsert.size() + existingBovs >= BOV_TARGET_COUNT) {
        break;
    }
    if (brokersOn.contains(c.Id)) {
        continue;
    }
    Integer p = Math.mod(idx, bAmount.size());
    toInsert.add(new BOV_Submission__c(
        Disposition__c = target.Id,
        Broker__c = c.Id,
        BOV_Amount__c = bAmount[p],
        Commission_Rate__c = bComm[p],
        Days_To_Market__c = bDays[p],
        Hist_Success_Rate__c = bSuccess[p],
        Cap_Rate__c = bCap[p],
        Is_Buyer_Ready__c = bReady[p],
        Is_Known_Performer__c = bKnown[p]));
    System.debug(LoggingLevel.ERROR, TAG + '  BOV for "' + c.Name + '" amount=' + bAmount[p]
        + ' comm=' + bComm[p] + ' days=' + bDays[p] + ' cap=' + bCap[p]);
    idx++;
}

Integer wroteBovs = 0;
if (DRY_RUN) {
    System.debug(LoggingLevel.ERROR, TAG + '[DRY RUN] would INSERT ' + toInsert.size()
        + ' BOV_Submission__c. BovAutoSelectionService would then pick the winner and '
        + 'DispositionCounterRollupService would set Responses_Received__c.');
} else if (!toInsert.isEmpty()) {
    List<Database.SaveResult> rs = Database.insert(toInsert, false);
    for (Integer i = 0; i < rs.size(); i++) {
        if (rs[i].isSuccess()) {
            wroteBovs++;
        } else {
            for (Database.Error e : rs[i].getErrors()) {
                System.debug(LoggingLevel.ERROR, TAG + '  BOV FAIL (broker '
                    + toInsert[i].Broker__c + '): ' + e.getStatusCode() + ' - ' + e.getMessage()
                    + ' fields=' + String.valueOf(e.getFields()));
            }
        }
    }
    System.debug(LoggingLevel.ERROR, TAG + 'BOVs created: ' + wroteBovs + '/' + toInsert.size());
    System.assert(wroteBovs == toInsert.size(),
        'ABORTED - ' + (toInsert.size() - wroteBovs) + ' BOV insert(s) failed. Phase 4 is rolled '
        + 'back; phases 1-3 are NOT.');
    totalWrites += wroteBovs;
}

// ---------------------------------------------------------------------------------------
// CONSOLIDATED END-OF-RUN REPORT - read back from the org, nothing echoed from a payload.
// ---------------------------------------------------------------------------------------
System.debug(LoggingLevel.ERROR, TAG + '===== END-OF-RUN STATE (all 4 phases) =====');

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
Integer onCount = 0;
Integer offCount = 0;
for (Disposition__c d : [SELECT Id, RecordTypeId FROM Disposition__c]) {
    if (d.RecordTypeId == onRt) {
        onCount++;
    } else if (d.RecordTypeId == offRt) {
        offCount++;
    }
}
Integer newCount = 0;
Integer wonCount = 0;
Integer deadCount = 0;
for (Opportunity o : [SELECT Id, StageName FROM Opportunity]) {
    if (o.StageName == 'New') {
        newCount++;
    } else if (o.StageName == 'Closed Won') {
        wonCount++;
    } else if (o.StageName == 'Dead/Pass') {
        deadCount++;
    }
}
Disposition__c fin = [
    SELECT Id, Name, Responses_Received__c, Brokers_Contacted__c, Selected_Broker__c,
           Disposition_Stage__c
    FROM Disposition__c WHERE Id = :target.Id LIMIT 1];
Integer responses = (fin.Responses_Received__c == null) ? 0 : fin.Responses_Received__c.intValue();

System.debug(LoggingLevel.ERROR, TAG + 'Sell Meter  GREEN=' + green + ' YELLOW=' + yellow
    + ' RED=' + red + '  (all three must be > 0)');
System.debug(LoggingLevel.ERROR, TAG + 'Portfolio Upside tile  : ' + portfolioUpside);
System.debug(LoggingLevel.ERROR, TAG + 'Sell-Ready Upside tile : ' + sellReadyUpside
    + '   (must differ from the line above)');
System.debug(LoggingLevel.ERROR, TAG + 'Disposition__c  On_Market=' + onCount + ' Off_Market='
    + offCount);
System.debug(LoggingLevel.ERROR, TAG + 'On_Market ' + fin.Name + ' stage=' + fin.Disposition_Stage__c
    + ' Responses_Received__c=' + responses + ' Brokers_Contacted__c=' + fin.Brokers_Contacted__c
    + ' Selected_Broker__c=' + fin.Selected_Broker__c);
System.debug(LoggingLevel.ERROR, TAG + '"Matrix Generated" badge (responses >= 3): '
    + (responses >= 3));
System.debug(LoggingLevel.ERROR, TAG + 'Property_Asset__c=' + [SELECT COUNT() FROM Property_Asset__c]
    + ' BOV_Submission__c=' + [SELECT COUNT() FROM BOV_Submission__c]
    + ' Onboarding__c=' + [SELECT COUNT() FROM Onboarding__c]
    + ' Task=' + [SELECT COUNT() FROM Task]
    + ' Transaction__c=' + [SELECT COUNT() FROM Transaction__c]);
System.debug(LoggingLevel.ERROR, TAG + 'Opportunity  New=' + newCount + ' ClosedWon=' + wonCount
    + ' Dead/Pass=' + deadCount);

if (!DRY_RUN) {
    if (responses < 3) {
        gateFailures.add('the On_Market disposition has ' + responses + ' BOV responses; the '
            + 'matrix badge needs 3');
    }
    if (green < 1 || yellow < 1 || red < 1) {
        gateFailures.add('the three bands are not all present (GREEN=' + green + ' YELLOW='
            + yellow + ' RED=' + red + ') - phase 2 did not achieve its spread');
    }
    if (portfolioUpside == sellReadyUpside) {
        gateFailures.add('both upside tiles read ' + portfolioUpside
            + ' - they cannot be told apart on screen');
    }
    if (onCount < 1 || offCount < 1) {
        gateFailures.add('a record type has no Disposition (On_Market=' + onCount + ' Off_Market='
            + offCount + ')');
    }
}
for (String q : gateFailures) {
    System.debug(LoggingLevel.ERROR, TAG + 'QUALITY GATE: ' + q);
}

if (DRY_RUN) {
    System.debug(LoggingLevel.ERROR, TAG + '*** DRY RUN COMPLETE - ZERO ROWS WRITTEN ***');
    System.debug(LoggingLevel.ERROR, TAG + '*** The state above is the org AS IT IS NOW. ***');
} else if (totalWrites == 0) {
    System.debug(LoggingLevel.ERROR, TAG + '*** ZERO ROWS WRITTEN BY PHASE 4 ***');
    System.debug(LoggingLevel.ERROR, TAG + '*** The disposition already held ' + existingBovs
        + ' BOV(s), or no unused Broker Contact was left. ***');
} else {
    System.debug(LoggingLevel.ERROR, TAG + 'PHASE 4 WROTE ' + totalWrites + ' BOV submission(s).');
    System.debug(LoggingLevel.ERROR, TAG + 'RUN COMPLETE. APPROVALS SUBMITTED ACROSS ALL FOUR '
        + 'PHASES: 0.  APPROVAL EMAILS SENT: 0.');
    System.debug(LoggingLevel.ERROR, TAG + 'To populate the Sale Decision row on the Approval '
        + 'Tracker, click Submit for Approval on a disposition - both are still at Disposition '
        + 'Readiness, which is that process\'s entry criterion. THAT mails 3 approvers.');
    System.debug(LoggingLevel.ERROR, TAG + 'RE-COUNT Task IN A MINUTE: the ~45-per-Onboarding '
        + 'fan-out from phase 1 is asynchronous.');
}
System.debug(LoggingLevel.ERROR, TAG + 'Limits: SOQL ' + Limits.getQueries() + ' DML '
    + Limits.getDmlStatements() + ' CPU ' + Limits.getCpuTime() + 'ms');

// 🔴 Throwing here rolls back PHASE 4 ONLY. Phases 1-3 are separate committed transactions and
// CANNOT be rolled back from here - phase 1's Closed Won cascade (assets, Onboardings, ~45 Tasks
// each, SharePoint folder claims) is permanent regardless of what this gate says. That is the
// stated cost of splitting the run; see the companion .md. A gate failure here means: fix the
// input, re-run the phase it names, then re-run this one. It does NOT mean the org is clean.
if (STRICT) {
    System.assert(gateFailures.isEmpty(),
        'ROLLED BACK (phase 4 only) - ' + String.join(gateFailures, ' || ')
        + '  ==> phase 4 wrote NOTHING, but phases 1-3 REMAIN COMMITTED and phase 1 is not '
        + 'reversible. Fix the named input, re-run the phase that owns it, then re-run phase 4.');
}
