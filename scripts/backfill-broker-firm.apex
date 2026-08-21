/**
 * ONE-TIME DATA REPAIR — backfill `Contact.Broker_Firm__c` from the parent `Account.Name` for
 * every Contact on the `Contact.Broker` record type whose `Broker_Firm__c` is currently blank.
 *
 * Run:  sf apex run --file scripts/backfill-broker-firm.apex --target-org usman-dpeg
 * Then read the per-row log and the final "BACKFILL VERDICT" line.
 *
 * =====================================================================================
 * 🔴 WHY THIS EXISTS
 * =====================================================================================
 * `BovSubmissionBrokerStampService.stampBrokerFields` copies `Contact.Broker_Firm__c` VERBATIM
 * onto `BOV_Submission__c.Broker_Firm__c` when `Broker__c` is set and resolves to a Contact — see
 * that class's "THE BLANK-FIRM DECISION" block: a blank source firm is copied, not skipped, on
 * purpose. `Contact.Broker_Firm__c` is blank on ALL 19 broker Contacts in this org (measured
 * 2026-08-21), so every BOV submission that picks a broker stamps an empty firm. Two live rows
 * already show it: `BOV-0015` (Derek Simmons) and `BOV-0016` (Usman Khan) both carry
 * `Broker_Firm__c = ''` while `Contact_Name__c` stamped correctly, and `Broker_Display__c`
 * (`Broker_Firm__c & " — " & Contact_Name__c`) renders `" — Derek Simmons"` / `" — Usman Khan"`.
 * The off-market `Disposition__c.Selected_Broker__c` stamp (`DispositionBrokerStampService`,
 * `"Person - Firm"`) is degraded the same way, trailing a bare hyphen.
 *
 * Every broker Contact already has a parent Account whose Name IS the firm (measured: 19/19).
 * This script copies that Name across — the same "verbatim copy, no composition" shape
 * `BovSubmissionBrokerStampService`'s header insists on for its own field, applied one layer
 * upstream at the actual source of truth.
 *
 * =====================================================================================
 * 🔴 SCOPE — BLANK-ONLY, NEVER OVERWRITE
 * =====================================================================================
 * The query below does NOT filter on `Broker_Firm__c` in SOQL (a Text field's "blank" includes
 * both NULL and empty string, and mixing that into a WHERE clause is easy to get subtly wrong).
 * Instead every candidate is read and `String.isBlank(c.Broker_Firm__c)` is checked in Apex before
 * it is ever added to the update list. A Contact with ANY existing value — including a value this
 * script itself wrote on a prior run — is skipped and logged, never touched. This is what makes
 * the script idempotent: a second run finds nothing left to do.
 *
 * =====================================================================================
 * WHAT IS SCANNED AND REPORTED, NOT SILENTLY "FIXED" (per the operator's explicit ask)
 * =====================================================================================
 * The org's broker roster is not uniformly clean, and cleaning it is NOT this script's job:
 *
 *   1. JUNK FIRMS — Acme (x3), Global Media (x2), salesforce.com (x1, Marc Benioff),
 *      "Unknown - Via Email" (x1, Usman Khan — created by the inbound email pipeline) are
 *      sample/test/pipeline artefacts, not real brokerage firms. STEP 2 flags every one of these
 *      seven rows by name with a 🔴 JUNK FIRM marker. They are BACKFILLED ANYWAY — the firm will
 *      be exactly as junk as the Contact already is, which is honest, and refusing to backfill
 *      them would leave BOV_Submission__c blank for whichever of them gets picked as a broker.
 *      Whether these Contacts belong on the Broker record type at all is a separate decision for
 *      a human, not this script.
 *
 *   2. DUPLICATE NAME+FIRM PAIRS — six Contacts share both a Name and an Account.Name with
 *      another Contact in the roster: Derek Simmons / Colliers Houston, Priya Nair / Cushman &
 *      Wakefield Dallas, Marcus Whitfield / Matthews Real Estate Investment Services, Katie
 *      Osborne / Newmark Knight Frank, Ryan O'Connell / Stream Realty Partners, Sofia Delgado /
 *      Transwestern. STEP 2 flags every duplicate pair by both Contact Ids. This script does NOT
 *      deduplicate — a lookup (Disposition__c.Broker__c, BOV_Submission__c.Broker__c,
 *      Broker_Assignment__c.Broker__c, etc.) may already point at one specific Id in a pair, and
 *      merging or deleting either one is a decision with real referential consequences that
 *      belongs to a human, not a backfill script.
 *
 *   3. RECORD-TYPE INCONSISTENCY ON THE PARENT ACCOUNTS — the genuine firm Accounts (Colliers
 *      Houston, Cushman & Wakefield Dallas, Transwestern, Newmark Knight Frank, Stream Realty
 *      Partners, Matthews Real Estate Investment Services) sit on Account's DEFAULT record type
 *      (`Account.RecordType.DeveloperName` reads null via the API for these), while the junk
 *      Accounts (Acme, Global Media, salesforce.com, "Unknown - Via Email") are the ones actually
 *      stamped onto the `Broker_Firm` record type. STEP 2 reports this inconsistency; STEP 4
 *      changes NO record type on ANY object.
 *
 * =====================================================================================
 * TRUNCATION GUARD
 * =====================================================================================
 * `Contact.Broker_Firm__c` is Text(120) (`objects/Contact/fields/Broker_Firm__c.field-meta.xml`).
 * The longest Account name on the roster today is "Matthews Real Estate Investment Services" at
 * 40 characters, well inside the limit — but the guard is unconditional, not contingent on that
 * measurement staying true. Any Account.Name over 120 characters is truncated to 120 with
 * `.left(120)` and logged as TRUNCATED, by name, with both the original length and the truncated
 * value, so a future over-length firm name is caught rather than silently cut.
 *
 * =====================================================================================
 * SKIP: NO PARENT ACCOUNT
 * =====================================================================================
 * There are zero such rows today (measured: 19/19 broker Contacts have an AccountId), but the
 * script does not assume that stays true. A Contact with `AccountId = null` is skipped and logged
 * — there is no firm to copy from, and inventing one would be worse than leaving the field blank.
 *
 * =====================================================================================
 * PREVIEW_ONLY — READ WHAT IT WOULD DO BEFORE IT DOES IT
 * =====================================================================================
 * Defaults to **true**, matching `scripts/repair-onmarket-nda-baseline.apex` (a repair script
 * writing to live data, not a rebuild seed — see that file's header for why the two script
 * families default this flag oppositely). In PREVIEW mode every candidate is resolved, every skip
 * rule applied, every JUNK FIRM / DUPLICATE / TRUNCATED note printed, and the script STOPS before
 * `Database.update` and returns. No DML of any kind. Flip to false only after reading the full
 * PREVIEW output and confirming the operator has been shown the junk-firm and duplicate lists.
 *
 * =====================================================================================
 * 🔴 WHAT THIS SCRIPT DELIBERATELY DOES NOT DO
 * =====================================================================================
 * It does NOT re-stamp `BOV_Submission__c.Broker_Firm__c` on `BOV-0015` / `BOV-0016` (or any other
 * existing submission). `BovSubmissionBrokerStampService.stampBrokerFields` is CHANGE-KEYED on
 * `Broker__c` — it fires only when that lookup's value differs from before. Backfilling the source
 * Contact field does not touch `BOV_Submission__c.Broker__c` at all, so the two live rows will
 * STILL read `Broker_Firm__c = ''` after this script runs. That is expected, not a bug in this
 * script, and is called out again in the verification block at the bottom rather than silently
 * left for someone to discover. Re-stamping those two rows (e.g. re-saving `Broker__c` to itself,
 * or a narrow one-off Apex touch) is a SEPARATE, smaller action this script does not take.
 *
 * =====================================================================================
 * SYSTEM MODE IS DELIBERATE (no WITH USER_MODE)
 * =====================================================================================
 * ARCHITECTURE.md §2 mandates `WITH USER_MODE` for SELECTOR CLASSES in force-app. This is
 * anonymous Apex run by an administrator against live data, is not part of the deployed codebase,
 * and is not a selector; the surrounding scripts/ files follow the same convention.
 *
 * ROLLBACK: none from here. This only ever WRITES into a field that was blank, so the only undo is
 * setting `Broker_Firm__c` back to null by hand on the specific Ids logged as UPDATED below.
 */

// ── PREVIEW_ONLY: true = resolve, scan, apply every skip rule, print the full plan (including
//    the junk-firm and duplicate-pair reports), then RETURN before any DML. Flip to false only
//    after reading the PREVIEW output. See the header.
//
// ⚠ RESTORED TO `true` ON 2026-08-21 AFTER ITS LIVE RUN. It was left at `false` once the backfill
//    had been executed, which silently turns this file into a script that WRITES TO LIVE DATA ON
//    ITS FIRST EXECUTION — the reader who opens it next has to notice a one-word divergence from
//    the header three paragraphs up ("Defaults to **true**") to avoid an unintended write. The
//    safe-by-default state is the DEFAULT, not the state the last operator happened to leave.
//    Flip it deliberately, per run; do not commit it flipped.
final Boolean PREVIEW_ONLY = true;

// ── Known sample/test/pipeline firm names, reported (not excluded) per the operator's request.
final Set<String> JUNK_FIRM_NAMES = new Set<String>{
    'Acme', 'Global Media', 'salesforce.com', 'Unknown - Via Email'
};

final Integer BROKER_FIRM_MAX_LENGTH = 120;

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 1. Every Contact on the Broker record type, with its parent Account's Name and
// record type — the full roster, not pre-filtered on Broker_Firm__c (see header: blank
// detection happens in Apex, not SOQL, on purpose).
// ═════════════════════════════════════════════════════════════════════════════════════
List<Contact> roster = [
    SELECT Id, Name, Broker_Firm__c, AccountId, Account.Name, Account.RecordType.DeveloperName
    FROM Contact
    WHERE RecordType.DeveloperName = 'Broker'
    ORDER BY Name
];

System.debug(LoggingLevel.INFO, 'SCAN BASIS: ' + roster.size()
    + ' Contact(s) on the Contact.Broker record type.');

if (roster.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Nothing to do: no broker Contacts in this org.');
    System.debug(LoggingLevel.INFO, 'BACKFILL VERDICT: NOTHING TO DO');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 2. THE GUARD SCAN — duplicate-pair and junk-firm detection, read-only, before any DML.
// Grouped by Name + '|' + Account.Name so "same person, same firm, twice" is detected exactly
// as the operator described it (not merely same Name, and not merely same Account).
// ═════════════════════════════════════════════════════════════════════════════════════
Map<String, List<Contact>> byNameAndFirm = new Map<String, List<Contact>>();
for (Contact c : roster) {
    String firmForKey = (c.Account != null) ? c.Account.Name : '(no account)';
    String key = c.Name + '|' + firmForKey;
    if (!byNameAndFirm.containsKey(key)) {
        byNameAndFirm.put(key, new List<Contact>());
    }
    byNameAndFirm.get(key).add(c);
}

Integer duplicatePairs = 0;
for (String key : byNameAndFirm.keySet()) {
    List<Contact> dupGroup = byNameAndFirm.get(key);
    if (dupGroup.size() < 2) {
        continue;
    }
    duplicatePairs++;
    List<String> ids = new List<String>();
    for (Contact c : dupGroup) {
        ids.add(c.Id);
    }
    System.debug(LoggingLevel.WARN, '🔴 DUPLICATE NAME+FIRM PAIR: ' + dupGroup.size() + ' Contacts share '
        + '"' + key.replace('|', '" at "') + '" — Ids: ' + String.join(ids, ', ')
        + '. NOT deduplicated by this script; a lookup may already point at one specific Id. '
        + 'Report only.');
}

Integer junkFirmCount = 0;
for (Contact c : roster) {
    String firmName = (c.Account != null) ? c.Account.Name : null;
    if (firmName != null && JUNK_FIRM_NAMES.contains(firmName)) {
        junkFirmCount++;
        String acctRt = (c.Account.RecordType != null) ? c.Account.RecordType.DeveloperName : '(default/none)';
        System.debug(LoggingLevel.WARN, '🔴 JUNK FIRM: ' + c.Name + ' -> Account "' + firmName
            + '" (Account.RecordType = ' + acctRt + ', Contact Id ' + c.Id + '). This is a '
            + 'sample/test/pipeline artefact, not a real brokerage firm. Will be backfilled anyway '
            + '(the firm will be as junk as the Contact) — whether this Contact belongs on the '
            + 'Broker record type at all is a decision for a human, not this script.');
    }
}

// Record-type inconsistency note — genuine firm Accounts vs. junk firm Accounts on Broker_Firm RT.
// Report only; STEP 4 changes no record type on any object.
Set<String> genuineRtSeen = new Set<String>();
Set<String> junkRtSeen = new Set<String>();
for (Contact c : roster) {
    if (c.Account == null) {
        continue;
    }
    String acctRt = (c.Account.RecordType != null) ? c.Account.RecordType.DeveloperName : '(default/none)';
    if (JUNK_FIRM_NAMES.contains(c.Account.Name)) {
        junkRtSeen.add(c.Account.Name + '=' + acctRt);
    } else {
        genuineRtSeen.add(c.Account.Name + '=' + acctRt);
    }
}
System.debug(LoggingLevel.WARN, '🔴 RECORD-TYPE INCONSISTENCY (report only, nothing changed): '
    + 'genuine firm Accounts read [' + String.join(new List<String>(genuineRtSeen), ', ')
    + '] while junk-name Accounts read [' + String.join(new List<String>(junkRtSeen), ', ')
    + ']. The junk firms are the ones actually on the Broker_Firm record type; the genuine firms '
    + 'are on Account\'s default type. Confirm and decide separately — this script does not touch '
    + 'any Account record type.');

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 3. Build the update list — blank-only, has-account-only, with the truncation guard.
// Every row is logged (UPDATE PLAN / SKIP) regardless of PREVIEW_ONLY, so the plan is fully
// visible before any DML runs.
// ═════════════════════════════════════════════════════════════════════════════════════
List<Contact> toUpdate = new List<Contact>();
Integer skippedAlreadySet = 0;
Integer skippedNoAccount = 0;
Integer truncatedCount = 0;

for (Contact c : roster) {
    if (!String.isBlank(c.Broker_Firm__c)) {
        skippedAlreadySet++;
        System.debug(LoggingLevel.INFO, 'SKIP (already has a firm) ' + c.Name + ' -> "'
            + c.Broker_Firm__c + '". Never overwritten.');
        continue;
    }
    if (c.AccountId == null || c.Account == null) {
        skippedNoAccount++;
        System.debug(LoggingLevel.WARN, 'SKIP (no parent Account) ' + c.Name + ' (' + c.Id
            + '). No firm source to copy from.');
        continue;
    }

    String firmValue = c.Account.Name;
    if (firmValue != null && firmValue.length() > BROKER_FIRM_MAX_LENGTH) {
        truncatedCount++;
        System.debug(LoggingLevel.WARN, 'TRUNCATED ' + c.Name + ': Account.Name is '
            + firmValue.length() + ' chars, exceeds Broker_Firm__c\'s 120-char limit. Original: "'
            + firmValue + '"');
        firmValue = firmValue.left(BROKER_FIRM_MAX_LENGTH);
    }

    Contact upd = new Contact(Id = c.Id, Broker_Firm__c = firmValue);
    toUpdate.add(upd);
    System.debug(LoggingLevel.INFO, 'PLAN ' + c.Name + ' -> "' + firmValue + '"'
        + (JUNK_FIRM_NAMES.contains(c.Account.Name) ? ' [JUNK FIRM]' : ''));
}

System.debug(LoggingLevel.INFO, 'SCAN SUMMARY: ' + roster.size() + ' broker Contact(s) total, '
    + toUpdate.size() + ' to update, ' + skippedAlreadySet + ' already set (skipped), '
    + skippedNoAccount + ' with no Account (skipped), ' + truncatedCount + ' truncated, '
    + junkFirmCount + ' junk-firm row(s) [included in update plan], ' + duplicatePairs
    + ' duplicate name+firm pair(s) [report only].');

if (toUpdate.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Nothing to update. All broker Contacts already have a firm, '
        + 'or have no parent Account.');
    System.debug(LoggingLevel.INFO, 'BACKFILL VERDICT: NOTHING TO DO');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 4. THE PREVIEW GATE. Everything above is reads and in-memory building; the first DML
// in this script is the update below. Returning here is a genuine dry run, not a partial one.
// ═════════════════════════════════════════════════════════════════════════════════════
if (PREVIEW_ONLY) {
    System.debug(LoggingLevel.WARN, 'PREVIEW ONLY - NO RECORDS WERE UPDATED. Would update '
        + toUpdate.size() + ' Contact(s). Read every PLAN / JUNK FIRM / DUPLICATE line above, '
        + 'confirm the operator has seen the junk-firm and duplicate-pair reports, then set '
        + 'PREVIEW_ONLY = false and re-run.');
    System.debug(LoggingLevel.WARN, 'BACKFILL VERDICT: PREVIEW (no DML performed)');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 5. Update. allOrNone = false so one refused row cannot cost the others their backfill;
// every outcome is logged against its Contact.
// ═════════════════════════════════════════════════════════════════════════════════════
List<Database.SaveResult> results = Database.update(toUpdate, false);
Integer updated = 0;
Integer failed = 0;
for (Integer i = 0; i < results.size(); i++) {
    Contact target = toUpdate[i];
    if (results[i].isSuccess()) {
        updated++;
        System.debug(LoggingLevel.INFO, 'UPDATED ' + target.Id + ' -> "' + target.Broker_Firm__c + '"');
    } else {
        failed++;
        String detail = '';
        for (Database.Error err : results[i].getErrors()) {
            detail += err.getStatusCode() + ': ' + err.getMessage() + ' ';
        }
        System.debug(LoggingLevel.ERROR, 'FAILED for ' + target.Id + ' -> ' + detail);
    }
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 6. Verify from the database, not from what we intended.
// ═════════════════════════════════════════════════════════════════════════════════════
Integer nowPopulated = [
    SELECT COUNT()
    FROM Contact
    WHERE RecordType.DeveloperName = 'Broker' AND Broker_Firm__c != null
];
Integer totalBrokers = [SELECT COUNT() FROM Contact WHERE RecordType.DeveloperName = 'Broker'];

System.debug(LoggingLevel.INFO, 'VERIFY: ' + nowPopulated + ' of ' + totalBrokers
    + ' broker Contact(s) now have Broker_Firm__c populated.');
System.debug(LoggingLevel.WARN, '🔴 REMINDER: BOV-0015 and BOV-0016 (and any other EXISTING '
    + 'BOV_Submission__c row) will STILL read Broker_Firm__c = \'\' after this run. '
    + 'BovSubmissionBrokerStampService fires only when Broker__c CHANGES, and this script never '
    + 'touched that lookup. This was NOT executed here — see the header.');

System.debug(LoggingLevel.INFO, 'BACKFILL SUMMARY: ' + roster.size() + ' scanned, ' + updated
    + ' updated, ' + failed + ' failed, ' + skippedAlreadySet + ' already-set, ' + skippedNoAccount
    + ' no-account, ' + truncatedCount + ' truncated, ' + junkFirmCount + ' junk-firm, '
    + duplicatePairs + ' duplicate pair(s) reported.');
System.debug(LoggingLevel.INFO, 'BACKFILL VERDICT: '
    + (failed == 0 ? 'COMPLETE' : 'INCOMPLETE - read the FAILED lines above'));
