// Top up DISP-0002 with outreach summary fields, BOV submissions, a Broker Listing and a Wire.
//
// ═══════════════════════════════════════════════════════════════════════════════════════
// 🔴 ADDED 2026-08-20 (code-review finding C2). THE 4 BOV ROWS NOW NAME A BROKER CONTACT.
// ═══════════════════════════════════════════════════════════════════════════════════════
// Tranche A added `BOV_Submission__c.Broker_Required_On_Submission` — `ISBLANK(Broker__c)`,
// ACTIVE, no ISNEW/ISCHANGED guard. The four BOV rows below used to set `Broker_Firm__c` and
// `Contact_Name__c` as free text and leave `Broker__c` NULL, so the first insert after that rule
// deploys is refused on all four rows with FIELD_CUSTOM_VALIDATION_EXCEPTION and rolls the whole
// run back — after this script has already updated DISP-0002 and DELETED its existing BOV rows.
// The disposition ends stripped of its submissions with nothing put back, silently.
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
// queried ONCE up front — BEFORE the update and the delete, so an abort is a genuine no-op —
// indexed by `Contact.Broker_Firm__c`, and each BOV row asks for the firm it represents. A firm
// absent from the roster falls back to the roster in name order and says so in its log line.
//
// ⚠ `Broker_Firm__c` AND `Contact_Name__c` ARE NO LONGER SET ON THESE ROWS, DELIBERATELY.
// `BovSubmissionBrokerStampService` is a BEFORE-context stamp keyed on `Broker__c` CHANGING; on
// insert a non-null `Broker__c` is a change, so it overwrites both Text fields from the chosen
// Contact in the same save. Literals left here would be dead on arrival and would imply this
// fixture produces names ('Michael Torres', 'James Liu') that it cannot produce. The firm string
// survives as the RESOLUTION KEY in `bovBrokerFirm` — a lookup input, not a field value.
//   ⚠ DEPENDENCY: that service must be deployed, or these rows insert with a valid lookup and
//     BLANK firm/contact text and `Broker_Display__c` renders " — ". Deploy the tranche together.
//   ⚠ No firm substitution was needed here: all four firms exist in the roster.
//
// ⚠ KNOWN, ACCEPTED DIVERGENCE. `Selected_Broker__c` below and the `Broker_Listing__c` row still
// carry the old hand-typed 'Marcus & Millichap · Dana Pierce' / 'Dana Pierce'. Neither has a
// broker lookup, a stamp or a validation rule, so neither was at risk and neither was rewritten
// with this fix — and `seed-broker-contacts.apex` already documents this exact literal as demo
// residue that disagrees with the roster (it seeds Dana Pierce at CBRE, not Marcus & Millichap).
// Reconciling them is a separate demo-data decision, not part of C2.

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
        + 'updated, nothing was deleted, nothing was created, no DML was performed.');
    System.debug(LoggingLevel.ERROR,
        'DISP0002_SEED VERDICT: ABORTED (no broker Contacts, no DML performed)');
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

Disposition__c disp = [SELECT Id FROM Disposition__c WHERE Name = 'DISP-0002' LIMIT 1];

// Update outreach summary fields
disp.Package_Sent__c         = Date.newInstance(2026, 5, 15);
disp.Submission_Deadline__c  = Date.newInstance(2026, 5, 30);
// 🔴 `Responses_Received__c` IS TRIGGER-OWNED SINCE 2026-08-31 (Tranche 1 item 7).
// `DispositionCounterRollupService` recomputes it from the live `BOV_Submission__c` row count, so
// this assignment is overwritten — twice — by the two statements below it: first the
// `delete [SELECT Id FROM BOV_Submission__c ...]` drives it to 0, then the four-row insert drives
// it back to 4. The end state matches this literal, which is why it is kept rather than removed.
// ⚠ THE INTERMEDIATE 0 IS REAL AND IS VISIBLE TO ANYTHING WATCHING. Harmless in a seed script;
// worth knowing before this delete-then-reinsert shape is copied into anything that is not one.
// ⚠ `Brokers_Contacted__c` is NOT trigger-owned and stays manual — it counts brokers ASKED, which
// no child row records.
disp.Responses_Received__c   = 4;
disp.Brokers_Contacted__c    = 7;
disp.Selected_Broker__c      = 'Marcus & Millichap · Dana Pierce';
update disp;

// Remove existing BOV submissions for this disposition
delete [SELECT Id FROM BOV_Submission__c WHERE Disposition__c = :disp.Id];

// BOV Submissions
// 🔴 `bovBrokerFirm` IS PARALLEL TO `bovs` — index i of one is index i of the other. It holds
// the FIRM each row represents and is a RESOLUTION KEY, not a field value; the loop below turns
// it into `Broker__c` and the before-save stamp writes the two Text fields from the Contact it
// resolved to. Add a row here and you MUST add its firm in the same position below.
//
// ⚠ `BOV_Score__c` IS NO LONGER SEEDED (removed 2026-08-21) AND MUST NOT BE ADDED BACK — it is
// being recreated as a FORMULA and cannot be assigned. Anonymous Apex is not compile-checked by a
// deploy, so an assignment here would fail only when someone RUNS this script. See the fuller
// note in `seed-disposition.apex`; the score derives from the inputs already set below plus the
// parent disposition's asking price.
List<BOV_Submission__c> bovs = new List<BOV_Submission__c>{
    new BOV_Submission__c(
        Disposition__c = disp.Id,
        BOV_Amount__c = 31200000, Commission_Rate__c = 2.8, Days_To_Market__c = 42,
        Hist_Success_Rate__c = 88, Submission_Status__c = 'Selected'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id,
        BOV_Amount__c = 30500000, Commission_Rate__c = 3.0, Days_To_Market__c = 48,
        Hist_Success_Rate__c = 83, Submission_Status__c = 'Backup'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id,
        BOV_Amount__c = 29800000, Commission_Rate__c = 2.5, Days_To_Market__c = 55,
        Hist_Success_Rate__c = 79, Submission_Status__c = 'Backup'
    ),
    new BOV_Submission__c(
        Disposition__c = disp.Id,
        BOV_Amount__c = 28900000, Commission_Rate__c = 3.2, Days_To_Market__c = 60,
        Hist_Success_Rate__c = 72, Submission_Status__c = 'Backup'
    )
};
List<String> bovBrokerFirm = new List<String>{
    'Marcus & Millichap', 'CBRE', 'JLL', 'Cushman & Wakefield'
};

if (bovs.size() != bovBrokerFirm.size()) {
    System.debug(LoggingLevel.ERROR, 'ABORT: bovs (' + bovs.size() + ') and bovBrokerFirm ('
        + bovBrokerFirm.size() + ') are no longer parallel, so every row after the mismatch '
        + 'would get the wrong broker. Fix the two lists above and re-run. DISP-0002 HAS already '
        + 'been updated and its old BOV rows deleted by this point.');
    System.debug(LoggingLevel.ERROR, 'DISP0002_SEED VERDICT: ABORTED (bov/firm lists out of step)');
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
        + ' DISP-0002 wants "' + wantedFirm + '" -> ' + chosen.Name
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

// Broker Listing
// ⚠ `Days_On_Market__c` BELOW IS THE **STORED** NUMBER AND IS STILL ASSIGNABLE. Checked 2026-08-31
// (Tranche 1 item 6): decision D-4 added `Days_On_Market_Live__c` as a NEW formula field ALONGSIDE
// this one; the stored field is untouched, still writable, and NOT deleted (additive retirement).
// 🔴 DO NOT REPOINT THIS LINE — a formula field cannot be assigned, and anonymous Apex only finds
// that out at run time.
// ⚠ THE 7 IS A SNAPSHOT AGAINST A FIXED `List_Date__c` OF 2026-06-01 and has already diverged from
// what the formula computes. Expected: that divergence is the reason the formula exists.
delete [SELECT Id FROM Broker_Listing__c WHERE Disposition__c = :disp.Id];
insert new Broker_Listing__c(
    Disposition__c = disp.Id,
    Broker_Firm__c = 'Marcus & Millichap', Contact_Name__c = 'Dana Pierce',
    List_Date__c = Date.newInstance(2026, 6, 1),
    Call_For_Offers_Date__c = Date.newInstance(2026, 7, 14),
    Days_On_Market__c = 7, Listing_Status__c = 'On Track', Offers_Received__c = 0
);

// Wire record for Closing stage
delete [SELECT Id FROM Wire__c WHERE Disposition__c = :disp.Id];
insert new Wire__c(Disposition__c = disp.Id, Verbal_Verification_Completed__c = false);

System.debug(LoggingLevel.INFO, 'DISP0002_SEED SUMMARY: disposition ' + disp.Id + ', bovs '
    + bovs.size() + ' (broker firm-matched=' + firmMatched + ', fell-back=' + fellBack + ').');
System.debug(LoggingLevel.INFO, 'DISP0002_SEED VERDICT: '
    + (fellBack == 0
        ? 'COMPLETE'
        : 'COMPLETE (' + fellBack + ' BOV row(s) took a fallback broker - read the BOV BROKER lines)'));
