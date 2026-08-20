// Disposition / BOV / Broker Listing seed — rewritten 2026-08-19 for the current
// 6-record Property_Asset__c pool (Canyon Lake Land Holdings, Copperfield Town Center,
// Lakeline Corporate Center, Terrell Hills Medical Plaza, Universal City Retail Row,
// Windcrest Business Park). The prior version of this script assumed a larger, now-gone
// property pool addressed by CreatedDate order. Idempotent-ish: it deletes any Dispositions
// (and their child BOV/Broker Listing rows) it previously created against these 6 assets
// before re-inserting, so re-running never duplicates.
//
// 8 Dispositions spread across all 4 On_Market stage values (2 each):
//   Disposition Readiness : Canyon Lake Land Holdings, Terrell Hills Medical Plaza
//   BOV Outreach          : Windcrest Business Park, Lakeline Corporate Center
//   Active Listing        : Copperfield Town Center, Universal City Retail Row
//   Closing                : Canyon Lake Land Holdings, Terrell Hills Medical Plaza
//                             (a second, later disposition cycle on the same 2 assets —
//                              only way to cover Closing with just 6 real properties)
//
// ═══════════════════════════════════════════════════════════════════════════════════════
// 🔴 ADDED 2026-08-20 (code-review finding C2). EVERY BOV ROW NOW NAMES A BROKER CONTACT.
// ═══════════════════════════════════════════════════════════════════════════════════════
// Tranche A added `BOV_Submission__c.Broker_Required_On_Submission` — `ISBLANK(Broker__c)`,
// ACTIVE, no ISNEW/ISCHANGED guard. The 14 BOV rows below used to set `Broker_Firm__c` and
// `Contact_Name__c` as free text and leave `Broker__c` NULL, so the FIRST `insert bovs;` after
// that rule deploys is refused on ALL 14 rows with FIELD_CUSTOM_VALIDATION_EXCEPTION and takes
// the whole run down — AFTER the deletes near the top have already destroyed the previous demo
// dispositions. Net effect: the org loses its demo data and gains nothing, and nobody finds out
// until the next rebuild, which is typically the morning of a demo. Tranche A's own A1
// acceptance criterion is "this script runs clean"; until this change it did not.
//
// HOW A BROKER IS CHOSEN. `Broker__c` carries an ACTIVE, NON-OPTIONAL lookupFilter on
// the `Contact.Broker` RECORD TYPE, and a non-optional lookup filter is enforced on Apex DML, not
// only in the UI — an arbitrary Contact is REFUSED.
// ⚠ CORRECTED 2026-08-20: this read `Contact.Is_Broker__c = true`. The broker definition MOVED to
// the record type. 🔴 CONSEQUENCE FOR THIS SCRIPT SPECIFICALLY: on `usman-dpeg` the roster query
// below matched ZERO rows under the old predicate, so this script ABORTED at its gate on every
// run. It will now find the org's real broker roster and DO REAL WORK — including the deletes
// near the top that this file's own header warns about. Intended, but it is the first run in a
// long time that is not a no-op; read the SEED VERDICT line.
// Every row therefore resolves against the
// broker-Contact population that `scripts/seed-broker-contacts.apex` maintains: that roster is
// queried ONCE up front, indexed by `Contact.Broker_Firm__c`, and each BOV row asks for the firm
// it is meant to represent. A row whose firm is absent from the roster falls back to the roster
// in name order and SAYS SO on its own log line — a fallback here is a visible degradation,
// never a silent one.
//
// 🔴 THE GUARD RUNS BEFORE THE FIRST DELETE, NOT BEFORE THE FIRST INSERT. If this org holds no
// broker Contacts the script aborts with ZERO DML and names the script to run first. Putting
// that check any later would delete the existing dispositions and then refuse to create their
// replacements — precisely the half-seeded org the abort exists to prevent.
//
// ⚠ `Broker_Firm__c` AND `Contact_Name__c` ARE NO LONGER SET HERE, DELIBERATELY.
// `BovSubmissionBrokerStampService` is a BEFORE-context stamp keyed on `Broker__c` CHANGING; on
// insert a non-null `Broker__c` counts as a change, so it OVERWRITES both Text fields from the
// chosen Contact in the same save. Any literal left in this file would be dead on arrival and
// would tell a reader that this fixture produces firm/person names it cannot produce. The firm
// string survives one line below each row as the RESOLUTION KEY in `bovBrokerFirm` — a lookup
// input, not a field value.
//   ⚠ DEPENDENCY: that service must be deployed. If it is not, these rows insert with a valid
//     broker lookup and BLANK firm/contact text, and `Broker_Display__c` (a formula over both)
//     renders " — ". Deploy the tranche together; do not re-add the literals to paper over it.
//   ⚠ ONE FIRM WAS SUBSTITUTED so every row resolves deterministically rather than falling back:
//     'Stream Realty Partners' -> 'Eastdil Secured'. No Contact at Stream Realty Partners exists
//     in the roster `seed-broker-contacts.apex` creates.
//   ⚠ ANONYMOUS APEX COMPILES AGAINST THE ORG. A Metadata-API-deployed field arrives with no FLS
//     for anyone, System Administrator included, so if this script fails naming `Broker__c` the
//     fix is assigning `DPEG_Disposition_Edit` to the running user — not editing this file.
//
// ⚠ KNOWN, ACCEPTED DIVERGENCE — NOT A BUG TO CHASE. The `Broker_Listing__c` rows and the
// `Disposition__c.Selected_Broker__c` literals further down still name the old HAND-TYPED broker
// people ('Dana Pierce' at Marcus & Millichap, 'Mark Chen' at CBRE, 'Alex Whitfield' at Stream
// Realty Partners). Those two objects have no broker lookup, no stamp and no validation rule, so
// they were never at risk and were deliberately left out of this fix rather than rewritten with
// it. After a run, the BOV rows name ROSTER brokers and those siblings name the old ones — the
// firms agree everywhere except the substituted Closing row, and the PEOPLE agree nowhere.
// Rewriting them is a separate demo-data decision, not part of C2.
//
// ── On_Market record type (decision D11 / Gate 1 Q1) ────────────────────────────────
// Every Disposition seeded below is stamped On_Market — see prior scripts in this repo
// for the full rationale. A DESCRIBE, NOT A QUERY, so a missing record type degrades to
// null (MASTER default) instead of aborting the whole script.
Schema.RecordTypeInfo onMarketInfo =
    Schema.SObjectType.Disposition__c.getRecordTypeInfosByDeveloperName().get('On_Market');
Id onMarketRtId = (onMarketInfo != null && onMarketInfo.isAvailable())
    ? onMarketInfo.getRecordTypeId()
    : null;

Map<String, Id> assetIdByName = new Map<String, Id>();
for (Property_Asset__c a : [
    SELECT Id, Name FROM Property_Asset__c
    WHERE Name IN ('Canyon Lake Land Holdings', 'Copperfield Town Center',
                    'Lakeline Corporate Center', 'Terrell Hills Medical Plaza',
                    'Universal City Retail Row', 'Windcrest Business Park')
]) {
    assetIdByName.put(a.Name, a.Id);
}

Date today = Date.today();

// ── BROKER CONTACT ROSTER — QUERIED UP FRONT, BEFORE ANY DML (code-review C2) ───────
// Read-only. This block is deliberately ABOVE the deletes below: aborting here is a genuine
// no-op, aborting after them would leave the org with neither the old demo data nor the new.
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
        'DISPOSITION_BULK_SEED VERDICT: ABORTED (no broker Contacts, no DML performed)');
    return;
}

// Firm -> the first broker Contact at that firm in name order. Keyed lower-case because both
// sides are hand-typed strings; a case mismatch would silently become a fallback.
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

// ── Clean up any prior run's output for these 6 assets (idempotent re-run) ──────────
List<Disposition__c> priorDs = [
    SELECT Id FROM Disposition__c WHERE Property_Asset__c IN :assetIdByName.values()
];
if (!priorDs.isEmpty()) {
    delete [SELECT Id FROM BOV_Submission__c WHERE Disposition__c IN :priorDs];
    delete [SELECT Id FROM Broker_Listing__c WHERE Disposition__c IN :priorDs];
    delete priorDs;
}

// --- Disposition Readiness (2) ---
Disposition__c dReady1 = new Disposition__c(
    Disposition_Stage__c = 'Disposition Readiness',
    Property_Asset__c = assetIdByName.get('Canyon Lake Land Holdings'));
Disposition__c dReady2 = new Disposition__c(
    Disposition_Stage__c = 'Disposition Readiness',
    Property_Asset__c = assetIdByName.get('Terrell Hills Medical Plaza'));

// --- BOV Outreach (2) ---
Disposition__c dBov1 = new Disposition__c(
    Disposition_Stage__c = 'BOV Outreach',
    Property_Asset__c = assetIdByName.get('Windcrest Business Park'),
    Package_Sent__c = today.addDays(-18), Submission_Deadline__c = today.addDays(6),
    Responses_Received__c = 3, Brokers_Contacted__c = 6);
Disposition__c dBov2 = new Disposition__c(
    Disposition_Stage__c = 'BOV Outreach',
    Property_Asset__c = assetIdByName.get('Lakeline Corporate Center'),
    Package_Sent__c = today.addDays(-27), Submission_Deadline__c = today.addDays(2),
    Responses_Received__c = 4, Brokers_Contacted__c = 7,
    Selected_Broker__c = 'CBRE · Mark Chen');

// --- Active Listing (2) — one Broker Alert Due within 7 days ---
Disposition__c dList1 = new Disposition__c(
    Disposition_Stage__c = 'Active Listing',
    Property_Asset__c = assetIdByName.get('Copperfield Town Center'),
    Listing_Date__c = today.addDays(-42), Next_Broker_Checkin__c = today.addDays(3),
    Selected_Broker__c = 'Marcus & Millichap · Dana Pierce');
Disposition__c dList2 = new Disposition__c(
    Disposition_Stage__c = 'Active Listing',
    Property_Asset__c = assetIdByName.get('Universal City Retail Row'),
    Listing_Date__c = today.addDays(-55), Next_Broker_Checkin__c = today.addDays(12),
    Selected_Broker__c = 'JLL · Sarah Kim');

// --- Closing (2) ---
Disposition__c dClose1 = new Disposition__c(
    Disposition_Stage__c = 'Closing',
    Property_Asset__c = assetIdByName.get('Canyon Lake Land Holdings'),
    PSA_Executed__c = true, Title_Company__c = 'First American Title',
    Closing_Statement_Uploaded__c = true, Closing_Date__c = today.addDays(12),
    Accepted_Offer_Price__c = 8950000, Gross_Sale_Proceeds__c = 8950000,
    Selling_Costs__c = 268500);
Disposition__c dClose2 = new Disposition__c(
    Disposition_Stage__c = 'Closing',
    Property_Asset__c = assetIdByName.get('Terrell Hills Medical Plaza'),
    PSA_Executed__c = true, Title_Company__c = 'Fidelity National Title',
    Closing_Statement_Uploaded__c = false, Closing_Date__c = today.addDays(22),
    Accepted_Offer_Price__c = 14750000, Gross_Sale_Proceeds__c = 14750000,
    Selling_Costs__c = 442500);

List<Disposition__c> allD = new List<Disposition__c>{
    dReady1, dReady2, dBov1, dBov2, dList1, dList2, dClose1, dClose2
};
if (onMarketRtId != null) {
    for (Disposition__c d : allD) { d.RecordTypeId = onMarketRtId; }
}
insert allD;

// DispositionTrigger auto-creates a bare-bones Broker_Listing__c stub (Broker_Firm__c copied
// from Selected_Broker__c, no Contact_Name__c/Days_On_Market__c/Commission_Percent__c) as soon
// as a Disposition is inserted directly at 'Active Listing' with Selected_Broker__c already
// set — both dList1 and dList2 qualify. Delete those stubs before inserting the fully-detailed
// Broker_Listing__c records below, or each Active Listing disposition ends up with two listing
// rows (one blank, one real) on its related list.
delete [
    SELECT Id FROM Broker_Listing__c
    WHERE Disposition__c IN (:dList1.Id, :dList2.Id)
];

// --- BOV submissions (14 total: 3 for each BOV Outreach disposition, 2 each for the
//     Active Listing / Closing dispositions, reflecting the outreach round that got them
//     there) ---
//
// 🔴 `bovBrokerFirm` IS PARALLEL TO `bovs` AND MUST STAY THAT WAY — index i of one is index i
// of the other. It holds the FIRM each row is meant to come from, and it is a RESOLUTION KEY,
// NOT A FIELD VALUE: the loop below turns it into `Broker__c`, and
// `BovSubmissionBrokerStampService` then writes `Broker_Firm__c` and `Contact_Name__c` from the
// Contact it resolved to. That is why neither Text field is set here any more (see the header).
// If you add a BOV row, add its firm on the very next line or every row after it resolves to the
// wrong broker.
List<BOV_Submission__c> bovs = new List<BOV_Submission__c>();
List<String> bovBrokerFirm = new List<String>();

bovs.add(new BOV_Submission__c(Disposition__c = dBov1.Id,
    BOV_Amount__c = 23400000, Commission_Rate__c = 2.5, Days_To_Market__c = 42, Cap_Rate__c = 6.5,
    Hist_Success_Rate__c = 85, BOV_Score__c = 90, Submission_Status__c = 'Selected'));
bovBrokerFirm.add('Newmark');
bovs.add(new BOV_Submission__c(Disposition__c = dBov1.Id,
    BOV_Amount__c = 22900000, Commission_Rate__c = 2.75, Days_To_Market__c = 48, Cap_Rate__c = 6.6,
    Hist_Success_Rate__c = 81, BOV_Score__c = 86, Submission_Status__c = 'Backup'));
bovBrokerFirm.add('CBRE');
bovs.add(new BOV_Submission__c(Disposition__c = dBov1.Id,
    BOV_Amount__c = 22100000, Commission_Rate__c = 3.0, Days_To_Market__c = 55, Cap_Rate__c = 6.8,
    Hist_Success_Rate__c = 74, BOV_Score__c = 77, Submission_Status__c = 'Backup'));
bovBrokerFirm.add('Cushman & Wakefield');

bovs.add(new BOV_Submission__c(Disposition__c = dBov2.Id,
    BOV_Amount__c = 33800000, Commission_Rate__c = 2.6, Days_To_Market__c = 50, Cap_Rate__c = 6.4,
    Hist_Success_Rate__c = 82, BOV_Score__c = 91, Submission_Status__c = 'Selected'));
bovBrokerFirm.add('CBRE');
bovs.add(new BOV_Submission__c(Disposition__c = dBov2.Id,
    BOV_Amount__c = 32950000, Commission_Rate__c = 2.5, Days_To_Market__c = 58, Cap_Rate__c = 6.6,
    Hist_Success_Rate__c = 79, BOV_Score__c = 85, Submission_Status__c = 'Backup'));
bovBrokerFirm.add('JLL');
bovs.add(new BOV_Submission__c(Disposition__c = dBov2.Id,
    BOV_Amount__c = 32100000, Commission_Rate__c = 2.85, Days_To_Market__c = 62, Cap_Rate__c = 6.7,
    Hist_Success_Rate__c = 71, BOV_Score__c = 76, Submission_Status__c = 'Backup'));
bovBrokerFirm.add('Colliers');

bovs.add(new BOV_Submission__c(Disposition__c = dList1.Id,
    BOV_Amount__c = 27300000, Commission_Rate__c = 2.9, Days_To_Market__c = 40, Cap_Rate__c = 6.1,
    Hist_Success_Rate__c = 88, BOV_Score__c = 93, Submission_Status__c = 'Selected'));
bovBrokerFirm.add('Marcus & Millichap');
bovs.add(new BOV_Submission__c(Disposition__c = dList1.Id,
    BOV_Amount__c = 26400000, Commission_Rate__c = 3.0, Days_To_Market__c = 46, Cap_Rate__c = 6.3,
    Hist_Success_Rate__c = 80, BOV_Score__c = 83, Submission_Status__c = 'Backup'));
bovBrokerFirm.add('CBRE');

bovs.add(new BOV_Submission__c(Disposition__c = dList2.Id,
    BOV_Amount__c = 19850000, Commission_Rate__c = 2.7, Days_To_Market__c = 44, Cap_Rate__c = 6.2,
    Hist_Success_Rate__c = 84, BOV_Score__c = 89, Submission_Status__c = 'Selected'));
bovBrokerFirm.add('JLL');
bovs.add(new BOV_Submission__c(Disposition__c = dList2.Id,
    BOV_Amount__c = 18900000, Commission_Rate__c = 2.95, Days_To_Market__c = 52, Cap_Rate__c = 6.4,
    Hist_Success_Rate__c = 73, BOV_Score__c = 78, Submission_Status__c = 'Backup'));
bovBrokerFirm.add('Avison Young');

bovs.add(new BOV_Submission__c(Disposition__c = dClose1.Id,
    BOV_Amount__c = 9100000, Commission_Rate__c = 3.2, Days_To_Market__c = 70, Cap_Rate__c = 7.4,
    Hist_Success_Rate__c = 68, BOV_Score__c = 79, Submission_Status__c = 'Selected'));
// ⚠ WAS 'Stream Realty Partners' (with contact 'Alex Whitfield'). No Contact at that firm exists
// in the roster seed-broker-contacts.apex creates, so it would have taken the fallback path on
// every run. Substituted for a real roster firm so this row resolves deterministically. The
// Broker_Listing__c row for dClose1 further down still says Stream Realty Partners - see the
// "KNOWN, ACCEPTED DIVERGENCE" note in the header.
bovBrokerFirm.add('Eastdil Secured');
bovs.add(new BOV_Submission__c(Disposition__c = dClose1.Id,
    BOV_Amount__c = 8700000, Commission_Rate__c = 3.0, Days_To_Market__c = 75, Cap_Rate__c = 7.6,
    Hist_Success_Rate__c = 65, BOV_Score__c = 71, Submission_Status__c = 'Backup'));
bovBrokerFirm.add('Cushman & Wakefield');

bovs.add(new BOV_Submission__c(Disposition__c = dClose2.Id,
    BOV_Amount__c = 15400000, Commission_Rate__c = 2.8, Days_To_Market__c = 48, Cap_Rate__c = 6.85,
    Hist_Success_Rate__c = 83, BOV_Score__c = 88, Submission_Status__c = 'Selected'));
bovBrokerFirm.add('Newmark');
bovs.add(new BOV_Submission__c(Disposition__c = dClose2.Id,
    BOV_Amount__c = 14900000, Commission_Rate__c = 3.1, Days_To_Market__c = 54, Cap_Rate__c = 7.0,
    Hist_Success_Rate__c = 70, BOV_Score__c = 75, Submission_Status__c = 'Backup'));
bovBrokerFirm.add('Colliers');

// ── Resolve a broker Contact per BOV row (code-review C2) ───────────────────────────
// A mismatched pair here would silently shift every subsequent row onto the wrong broker, so it
// is checked rather than assumed. Anonymous Apex is not compile-checked by a deploy; this is the
// only place the mistake can be caught.
if (bovs.size() != bovBrokerFirm.size()) {
    System.debug(LoggingLevel.ERROR, 'ABORT: bovs (' + bovs.size() + ') and bovBrokerFirm ('
        + bovBrokerFirm.size() + ') are no longer parallel, so broker resolution below would '
        + 'assign the wrong broker to every row after the mismatch. Someone added a BOV row '
        + 'without adding its firm on the next line. Fix the list above and re-run. The '
        + 'dispositions and their cleanup HAVE already been written by this point.');
    System.debug(LoggingLevel.ERROR,
        'DISPOSITION_BULK_SEED VERDICT: ABORTED (bov/firm lists out of step)');
    return;
}

// Readable labels for the per-row log; raw Ids in a debug log tell a reader nothing.
Map<Id, String> dispLabelById = new Map<Id, String>{
    dBov1.Id   => 'BOV Outreach / Windcrest Business Park',
    dBov2.Id   => 'BOV Outreach / Lakeline Corporate Center',
    dList1.Id  => 'Active Listing / Copperfield Town Center',
    dList2.Id  => 'Active Listing / Universal City Retail Row',
    dClose1.Id => 'Closing / Canyon Lake Land Holdings',
    dClose2.Id => 'Closing / Terrell Hills Medical Plaza'
};

Integer firmMatched = 0;
Integer fellBack = 0;
Integer fallbackCursor = 0;
for (Integer i = 0; i < bovs.size(); i++) {
    BOV_Submission__c row = bovs.get(i);
    String wantedFirm = bovBrokerFirm.get(i);
    // Written as statements, not a ternary. A `cond ? null : someContact` is the kind of
    // expression Apex is entitled to argue with, and this file is not compile-checked by a
    // deploy - the mistake would only surface mid-run, after the deletes above.
    Contact chosen = null;
    if (!String.isBlank(wantedFirm)) {
        chosen = brokerByFirm.get(wantedFirm.toLowerCase());
    }
    String how;
    if (chosen != null) {
        firmMatched++;
        how = 'firm match';
    } else {
        // Deterministic, ordered fallback so a re-run against the same roster produces the same
        // assignment. Never random: an unstable fixture is worse than a wrong-but-stable one.
        chosen = brokerRoster.get(Math.mod(fallbackCursor, brokerRoster.size()));
        fallbackCursor++;
        fellBack++;
        how = 'NO broker Contact at this firm -> FELL BACK to the roster in name order';
    }
    row.Broker__c = chosen.Id;
    System.debug(LoggingLevel.INFO, 'BOV BROKER ' + (i + 1) + '/' + bovs.size() + ' '
        + dispLabelById.get(row.Disposition__c) + ' wants "' + wantedFirm + '" -> '
        + chosen.Name + ' (' + chosen.Broker_Firm__c + ') [' + how + ']');
}
if (fellBack > 0) {
    System.debug(LoggingLevel.WARN, 'BOV BROKER NOTE: ' + fellBack + ' of ' + bovs.size()
        + ' row(s) did not find their firm in this org\'s broker roster and were given an '
        + 'arbitrary broker. Those rows are VALID and the seed still completes - the validation '
        + 'rule and the lookup filter are both satisfied - but the comparison matrix will show a '
        + 'broker the fixture did not intend. Re-run scripts/seed-broker-contacts.apex if the '
        + 'roster is not the twelve it maintains.');
}

insert bovs;

// --- Broker Listing (one per Active Listing / Closing disposition = 4) ---
List<Broker_Listing__c> listings = new List<Broker_Listing__c>{
    new Broker_Listing__c(
        Disposition__c = dList1.Id, Broker_Firm__c = 'Marcus & Millichap', Contact_Name__c = 'Dana Pierce',
        List_Date__c = today.addDays(-42), Call_For_Offers_Date__c = today.addDays(14),
        Days_On_Market__c = 42, Listing_Status__c = 'On Track', Offers_Received__c = 2,
        Commission_Percent__c = 2.9),
    new Broker_Listing__c(
        Disposition__c = dList2.Id, Broker_Firm__c = 'JLL', Contact_Name__c = 'Sarah Kim',
        List_Date__c = today.addDays(-55), Call_For_Offers_Date__c = today.addDays(7),
        Days_On_Market__c = 55, Listing_Status__c = 'At Risk', Offers_Received__c = 1,
        Commission_Percent__c = 2.7),
    new Broker_Listing__c(
        Disposition__c = dClose1.Id, Broker_Firm__c = 'Stream Realty Partners', Contact_Name__c = 'Alex Whitfield',
        List_Date__c = today.addDays(-95), Call_For_Offers_Date__c = today.addDays(-20),
        Days_On_Market__c = 95, Listing_Status__c = 'On Track', Offers_Received__c = 1,
        Commission_Percent__c = 3.2),
    new Broker_Listing__c(
        Disposition__c = dClose2.Id, Broker_Firm__c = 'Newmark', Contact_Name__c = 'Priya Nair',
        List_Date__c = today.addDays(-110), Call_For_Offers_Date__c = today.addDays(-30),
        Days_On_Market__c = 110, Listing_Status__c = 'On Track', Offers_Received__c = 1,
        Commission_Percent__c = 2.8)
};
insert listings;

System.debug(LoggingLevel.ERROR, 'DISPOSITION_BULK_SEED dispositions=' + allD.size()
    + ' bovs=' + bovs.size() + ' listings=' + listings.size()
    + ' bov-brokers firm-matched=' + firmMatched + ' fell-back=' + fellBack);
System.debug(LoggingLevel.INFO, 'DISPOSITION_BULK_SEED VERDICT: '
    + (fellBack == 0
        ? 'COMPLETE'
        : 'COMPLETE (' + fellBack + ' BOV row(s) took a fallback broker - read the BOV BROKER lines)'));
