// Seed Disposition record + related data for Sienna Town Center
//
// ═══════════════════════════════════════════════════════════════════════════════════════
// 🔴 ADDED 2026-08-20 (code-review finding C2). THE 4 BOV ROWS NOW NAME A BROKER CONTACT.
// ═══════════════════════════════════════════════════════════════════════════════════════
// Tranche A added `BOV_Submission__c.Broker_Required_On_Submission` — `ISBLANK(Broker__c)`,
// ACTIVE, no ISNEW/ISCHANGED guard. The four BOV rows below used to set `Broker_Firm__c` and
// `Contact_Name__c` as free text and leave `Broker__c` NULL, so the first insert after that rule
// deploys is refused on all four rows with FIELD_CUSTOM_VALIDATION_EXCEPTION and rolls the whole
// run back — after this script has already DELETED the prior Sienna disposition. The org ends
// with neither the old demo data nor the new, silently, until the next rebuild.
//
// HOW A BROKER IS CHOSEN. `Broker__c` carries an ACTIVE, NON-OPTIONAL lookupFilter on
// the `Contact.Broker` RECORD TYPE, enforced on Apex DML and not only in the UI, so an arbitrary
// Contact is REFUSED. (⚠ CORRECTED 2026-08-20: this read `Contact.Is_Broker__c = true`. The broker
// definition MOVED to the record type. 🔴 CONSEQUENCE FOR THIS SCRIPT SPECIFICALLY: the roster
// query below matched ZERO rows on `usman-dpeg` under the old predicate, so this script ABORTED
// at the gate below on every run. It will now find the org's real broker roster and DO REAL WORK
// - including the deletes further down. That is intended, and it is the first run in a long time
// where this script is not a no-op. Read the SEED VERDICT line.)
// The broker roster that `scripts/seed-broker-contacts.apex` maintains is
// queried ONCE up front — BEFORE the delete below, so an abort is a genuine no-op — indexed by
// `Contact.Broker_Firm__c`, and each BOV row asks for the firm it represents. A firm absent from
// the roster falls back to the roster in name order and says so in its log line.
//
// ⚠ `Broker_Firm__c` AND `Contact_Name__c` ARE NO LONGER SET ON THESE ROWS, DELIBERATELY.
// `BovSubmissionBrokerStampService` is a BEFORE-context stamp keyed on `Broker__c` CHANGING; on
// insert a non-null `Broker__c` is a change, so it overwrites both Text fields from the chosen
// Contact in the same save. Literals left here would be dead on arrival and would imply this
// fixture produces names ('K. Rao', 'T. Black', 'S. Rivera') that it cannot produce. The firm
// string survives as the RESOLUTION KEY in `bovBrokerFirm` — a lookup input, not a field value.
//   ⚠ DEPENDENCY: that service must be deployed, or these rows insert with a valid lookup and
//     BLANK firm/contact text and `Broker_Display__c` renders " — ". Deploy the tranche together.
//   ⚠ ONE FIRM WAS SUBSTITUTED so every row resolves deterministically: 'Cushman' ->
//     'Cushman & Wakefield', which is the name the roster actually uses.
//
// ⚠ KNOWN, ACCEPTED DIVERGENCE. `Selected_Broker__c` on the Disposition and the
// `Broker_Listing__c` row below still carry the old hand-typed 'CBRE · Mark Chen' / 'Mark Chen'.
// Neither has a broker lookup, a stamp or a validation rule, so neither was at risk and neither
// was rewritten with this fix. After a run the BOV rows name ROSTER brokers and those two name
// Mark Chen. Reconciling them is a separate demo-data decision, not part of C2.

// ── BROKER CONTACT ROSTER — QUERIED UP FRONT, BEFORE ANY DML ────────────────────────
List<Contact> brokerRoster = [
    SELECT Id, Name, Broker_Firm__c
    FROM Contact
    WHERE RecordType.DeveloperName = 'Broker'
    ORDER BY Name
];
if (brokerRoster.isEmpty()) {
    System.debug(LoggingLevel.ERROR,
        'ABORT: this org holds no Contact on the Contact.Broker record type. Every BOV submission this '
        + 'script creates would be refused twice over - by the Broker_Required_On_Submission '
        + 'validation rule and by the ACTIVE non-optional lookup filter on BOV_Submission__c'
        + '.Broker__c - and the failure would roll the whole run back. RUN '
        + 'scripts/seed-broker-contacts.apex FIRST, then re-run this script. Nothing was '
        + 'deleted, nothing was created, no DML was performed.');
    System.debug(LoggingLevel.ERROR,
        'SIENNA_SEED VERDICT: ABORTED (no broker Contacts, no DML performed)');
    return;
}

// Firm -> the first broker Contact at that firm in name order. Lower-cased because both sides
// are hand-typed strings and a case mismatch would silently become a fallback.
Map<String, Contact> brokerByFirm = new Map<String, Contact>();
for (Contact b : brokerRoster) {
    if (String.isBlank(b.Broker_Firm__c)) {
        continue;
    }
    String firmKey = b.Broker_Firm__c.toLowerCase();
    if (!brokerByFirm.containsKey(firmKey)) {
        brokerByFirm.put(firmKey, b);
    }
}
System.debug(LoggingLevel.INFO, 'BROKER ROSTER: ' + brokerRoster.size()
    + ' broker Contact(s) across ' + brokerByFirm.size() + ' distinct firm(s).');

Property_Asset__c sienna = [
    SELECT Id, Name FROM Property_Asset__c WHERE Name = 'Sienna Town Center' LIMIT 1
];

// Remove any existing Disposition for this asset
delete [SELECT Id FROM Disposition__c WHERE Property_Asset__c = :sienna.Id];

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
// 'BOV Outreach' below is an On_Market-only stage value, so the stamp and the stage agree.
Schema.RecordTypeInfo onMarketInfo =
    Schema.SObjectType.Disposition__c.getRecordTypeInfosByDeveloperName().get('On_Market');
Id onMarketRtId = (onMarketInfo != null && onMarketInfo.isAvailable())
    ? onMarketInfo.getRecordTypeId()
    : null;

// Stage 2 Disposition (BOV Outreach) — shows matrix + outreach panel
Disposition__c disp = new Disposition__c(
    Property_Asset__c = sienna.Id,
    Disposition_Stage__c = 'BOV Outreach',
    Package_Sent__c = Date.newInstance(2026, 5, 1),
    Submission_Deadline__c = Date.newInstance(2026, 5, 16),
    // 🔴 `Responses_Received__c` IS NO LONGER A SEED VALUE — IT IS TRIGGER-OWNED SINCE 2026-08-31
    // (Tranche 1 item 7). `DispositionCounterRollupService` RECOMPUTES it from the actual
    // `BOV_Submission__c` row count on every BOV insert / update / delete / undelete, so the four
    // submissions this script inserts below WILL overwrite whatever is written here, silently and
    // with no error. This literal is retained rather than deleted for two reasons: it is correct
    // (this script inserts exactly FOUR BOV rows for this disposition, so the trigger converges on
    // 4), and it is what the record reads between its own insert and the BOV insert.
    // ⚠ IF YOU ADD OR REMOVE A BOV ROW BELOW, THIS NUMBER BECOMES A LIE THAT LASTS ONE STATEMENT
    // AND THEN CORRECTS ITSELF. Change it to match anyway — a seed whose literals disagree with
    // its own output is the thing that makes the next reader distrust the whole file.
    // ⚠ `Brokers_Contacted__c` IS NOT TRIGGER-OWNED AND STAYS MANUAL. It records how many brokers
    // were ASKED, which is not derivable from any child row (design item 7, as directed).
    Responses_Received__c = 4,
    Brokers_Contacted__c = 6,
    Selected_Broker__c = 'CBRE · Mark Chen'
);
if (onMarketRtId != null) {
    disp.RecordTypeId = onMarketRtId;
}
insert disp;
System.debug('Created Disposition: ' + disp.Id);

// BOV Submissions
// 🔴 `bovBrokerFirm` IS PARALLEL TO `bovs` — index i of one is index i of the other. It holds
// the FIRM each row represents and is a RESOLUTION KEY, not a field value; the loop below turns
// it into `Broker__c` and the before-save stamp writes the two Text fields from the Contact it
// resolved to. Add a row here and you MUST add its firm in the same position below.
//
// ⚠ `BOV_Score__c` IS NO LONGER SEEDED (removed 2026-08-21) AND MUST NOT BE ADDED BACK. It is
// being recreated as a FORMULA, and a formula field cannot be assigned — anonymous Apex is not
// compile-checked by a deploy, so an assignment here would not fail until someone RUNS this
// script against a converted org. The score is derived from the five broker-side inputs already
// set below (`BOV_Amount__c`, `Commission_Rate__c`, `Days_To_Market__c`, `Hist_Success_Rate__c`,
// `Cap_Rate__c`) plus the parent's asking price. Until `Disposition__c.Asking_Price__c` exists
// and is set on `disp` above, every seeded row will display an em dash in the comparison matrix
// — that is the honest rendering of "not scorable", not a broken seed.
List<BOV_Submission__c> bovs = new List<BOV_Submission__c>{
    new BOV_Submission__c(
        Disposition__c = disp.Id,
        BOV_Amount__c = 28500000, Commission_Rate__c = 3.0, Days_To_Market__c = 45,
        Hist_Success_Rate__c = 82, Submission_Status__c = 'Selected'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id,
        BOV_Amount__c = 27900000, Commission_Rate__c = 2.5, Days_To_Market__c = 52,
        Hist_Success_Rate__c = 78, Submission_Status__c = 'Backup'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id,
        BOV_Amount__c = 26800000, Commission_Rate__c = 2.8, Days_To_Market__c = 60,
        Hist_Success_Rate__c = 71, Submission_Status__c = 'Backup'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id,
        BOV_Amount__c = 26200000, Commission_Rate__c = 3.2, Days_To_Market__c = 55,
        Hist_Success_Rate__c = 69, Submission_Status__c = 'Backup'
    )
};
// ⚠ Row 4 was 'Cushman'. Substituted for 'Cushman & Wakefield', the name the broker roster
// actually uses, so it resolves by firm instead of taking the fallback path on every run.
List<String> bovBrokerFirm = new List<String>{
    'CBRE', 'JLL', 'Newmark', 'Cushman & Wakefield'
};

if (bovs.size() != bovBrokerFirm.size()) {
    System.debug(LoggingLevel.ERROR, 'ABORT: bovs (' + bovs.size() + ') and bovBrokerFirm ('
        + bovBrokerFirm.size() + ') are no longer parallel, so every row after the mismatch '
        + 'would get the wrong broker. Fix the two lists above and re-run. The Disposition HAS '
        + 'already been written by this point.');
    System.debug(LoggingLevel.ERROR, 'SIENNA_SEED VERDICT: ABORTED (bov/firm lists out of step)');
    return;
}

Integer firmMatched = 0;
Integer fellBack = 0;
Integer fallbackCursor = 0;
for (Integer i = 0; i < bovs.size(); i++) {
    BOV_Submission__c row = bovs.get(i);
    String wantedFirm = bovBrokerFirm.get(i);
    // Written as statements, not a ternary: `cond ? null : someContact` is the kind of expression
    // Apex is entitled to argue with, and this file is not compile-checked by a deploy.
    Contact chosen = null;
    if (!String.isBlank(wantedFirm)) {
        chosen = brokerByFirm.get(wantedFirm.toLowerCase());
    }
    String how;
    if (chosen != null) {
        firmMatched++;
        how = 'firm match';
    } else {
        // Deterministic and ordered, never random: an unstable fixture is worse than a
        // wrong-but-stable one.
        chosen = brokerRoster.get(Math.mod(fallbackCursor, brokerRoster.size()));
        fallbackCursor++;
        fellBack++;
        how = 'NO broker Contact at this firm -> FELL BACK to the roster in name order';
    }
    row.Broker__c = chosen.Id;
    System.debug(LoggingLevel.INFO, 'BOV BROKER ' + (i + 1) + '/' + bovs.size()
        + ' Sienna Town Center wants "' + wantedFirm + '" -> ' + chosen.Name
        + ' (' + chosen.Broker_Firm__c + ') [' + how + ']');
}
if (fellBack > 0) {
    System.debug(LoggingLevel.WARN, 'BOV BROKER NOTE: ' + fellBack + ' of ' + bovs.size()
        + ' row(s) did not find their firm in this org\'s broker roster and were given an '
        + 'arbitrary broker. The rows are VALID and the seed still completes, but the comparison '
        + 'matrix will show a broker the fixture did not intend. Re-run '
        + 'scripts/seed-broker-contacts.apex if the roster is not the twelve it maintains.');
}

insert bovs;

// Broker Listing (Active Listing stage data)
// ⚠ `Days_On_Market__c` BELOW IS THE **STORED** NUMBER AND IS STILL ASSIGNABLE. Checked
// 2026-08-31 (Tranche 1 item 6): decision D-4 added a NEW formula field,
// `Days_On_Market_Live__c`, ALONGSIDE this one rather than converting it (Salesforce cannot
// convert an existing field into a Formula — that is a delete + create), so this line compiles and
// runs unchanged and is deliberately left alone.
// 🔴 DO NOT REPOINT IT TO `Days_On_Market_Live__c` — assigning a formula field is a runtime failure
// in anonymous Apex, which nothing catches until somebody runs this script.
// ⚠ THIS LITERAL IS A FIXED 40 AGAINST A FIXED `List_Date__c` OF 2026-04-24, so unlike the
// relative-dated bulk seed it has ALREADY diverged from what the formula computes. That is the
// stored field being a hand-keyed snapshot, which is precisely why the formula was added.
insert new Broker_Listing__c(
    Disposition__c = disp.Id, Broker_Firm__c = 'CBRE', Contact_Name__c = 'Mark Chen',
    List_Date__c = Date.newInstance(2026, 4, 24),
    Call_For_Offers_Date__c = Date.newInstance(2026, 6, 10),
    Days_On_Market__c = 40, Listing_Status__c = 'At Risk', Offers_Received__c = 0
);

// Wire record (Closing stage data)
insert new Wire__c(
    Disposition__c = disp.Id,
    Verbal_Verification_Completed__c = false
);

System.debug(LoggingLevel.INFO, 'SIENNA_SEED SUMMARY: disposition ' + disp.Id + ', bovs '
    + bovs.size() + ' (broker firm-matched=' + firmMatched + ', fell-back=' + fellBack + ').');
System.debug(LoggingLevel.INFO, 'SIENNA_SEED VERDICT: '
    + (fellBack == 0
        ? 'COMPLETE'
        : 'COMPLETE (' + fellBack + ' BOV row(s) took a fallback broker - read the BOV BROKER lines)'));
