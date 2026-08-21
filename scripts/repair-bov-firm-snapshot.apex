/**
 * ONE-TIME DATA REPAIR — write `BOV_Submission__c.Broker_Firm__c` directly on the two live rows
 * left degraded by the Contact backfill: `BOV-0015` (Derek Simmons) and `BOV-0016` (Usman Khan).
 *
 * Run:  sf apex run --file scripts/repair-bov-firm-snapshot.apex --target-org usman-dpeg
 * Then read the per-row log and the final "REPAIR VERDICT" line.
 *
 * =====================================================================================
 * 🔴 WHY THIS EXISTS, AND WHY "RE-SAVE Broker__c" DOES NOT WORK
 * =====================================================================================
 * `scripts/backfill-broker-firm.apex` backfilled `Contact.Broker_Firm__c` on all 19 broker
 * Contacts, but its own header says plainly it does NOT re-stamp any existing
 * `BOV_Submission__c` row — `BovSubmissionBrokerStampService.stampBrokerFields` is CHANGE-KEYED
 * on `Broker__c` (line 214: `if (submission.Broker__c == priorBroker) { continue; }`). Re-saving
 * the same Id back onto itself is `new == prior`, so the stamp skips the record and writes
 * nothing. Clearing `Broker__c` first to force a change is also refused — the
 * `Broker_Required_On_Submission` validation rule rejects a save with no broker.
 *
 * The correct fix is the one the stamp service itself performs on a genuine broker change: copy
 * `Broker__r.Broker_Firm__c` straight across. This script does that directly, one layer below the
 * trigger, for exactly the rows the trigger will never revisit.
 *
 * =====================================================================================
 * 🔴 WHY THIS IS SAFE AND DOES NOT FIGHT THE TRIGGER
 * =====================================================================================
 * The stamp only fires when `Broker__c` CHANGES. This script writes `Broker_Firm__c` only, never
 * touching `Broker__c` — so on this very update the before-trigger reads `Broker__c` unchanged
 * (`new == prior`), takes the same skip branch quoted above, and never re-evaluates or overwrites
 * what this script writes. Confirmed structurally, not merely assumed: `Broker__c` does not appear
 * anywhere in this script's update payload.
 *
 * =====================================================================================
 * SCOPE — BLANK-ONLY, BROKER-PRESENT-ONLY, NEVER OVERWRITE
 * =====================================================================================
 * Targets `BOV_Submission__c` rows where `Broker_Firm__c` is blank AND `Broker__c` is not null.
 * `String.isBlank()` is applied in Apex (not as a SOQL filter) so both NULL and empty-string are
 * caught identically. A row that already carries any `Broker_Firm__c` value is left untouched,
 * whether this script wrote it, the trigger wrote it, or a human typed it before the picker
 * existed.
 *
 * =====================================================================================
 * SKIP: BROKER CONTACT HAS NO FIRM OF ITS OWN
 * =====================================================================================
 * A submission whose broker Contact's OWN `Broker_Firm__c` is still blank (never in this org as of
 * the companion backfill, but not assumed to stay that way) is skipped and logged. Writing a blank
 * onto a field that is already blank would produce no visible change and no audit value; this
 * script only writes when the destination is going to visibly improve.
 *
 * =====================================================================================
 * TRUNCATION GUARD — CHECKED, NOT ASSUMED EQUAL
 * =====================================================================================
 * `BOV_Submission__c.Broker_Firm__c` is Text(255)
 * (`objects/BOV_Submission__c/fields/Broker_Firm__c.field-meta.xml`) — a DIFFERENT length than the
 * source `Contact.Broker_Firm__c`, which is Text(120)
 * (`objects/Contact/fields/Broker_Firm__c.field-meta.xml`). A 120-char source can never overflow a
 * 255-char destination, but the guard below is unconditional in the same style as
 * `backfill-broker-firm.apex`'s guard: any source value over 255 characters is truncated to 255
 * with `.left(255)` and logged as TRUNCATED, so a future widening of either field is caught rather
 * than silently assumed safe.
 *
 * =====================================================================================
 * PREVIEW_ONLY — READ WHAT IT WOULD DO BEFORE IT DOES IT
 * =====================================================================================
 * Defaults to **true**. In PREVIEW mode every candidate is resolved, every skip rule applied, and
 * every PLAN / SKIP / TRUNCATED line printed; the script STOPS before `Database.update` and
 * returns. No DML of any kind. Flip to false only after reading the full PREVIEW output.
 *
 * =====================================================================================
 * SYSTEM MODE IS DELIBERATE (no WITH USER_MODE)
 * =====================================================================================
 * ARCHITECTURE.md §2 mandates `WITH USER_MODE` for SELECTOR CLASSES in force-app. This is
 * anonymous Apex run by an administrator against live data, is not part of the deployed codebase,
 * and is not a selector; it follows the same convention as `backfill-broker-firm.apex`.
 *
 * ROLLBACK: none from here. This only ever writes into a field that was blank on rows named in the
 * log below; undo by hand-setting `Broker_Firm__c` back to null on those specific Ids.
 */

// ── PREVIEW_ONLY: true = resolve, scan, apply every skip rule, print the full plan, then RETURN
//    before any DML. Flip to false only after reading the PREVIEW output. See the header.
//
// ⚠ RESTORED TO `true` ON 2026-08-21 AFTER ITS LIVE RUN, for the same reason recorded in
//    `backfill-broker-firm.apex`: a repair script left at `false` writes to live data the first
//    time anyone executes it, and contradicts its own header ("Defaults to **true**") four lines
//    above. Flip it deliberately, per run; do not commit it flipped.
final Boolean PREVIEW_ONLY = true;

final Integer BROKER_FIRM_MAX_LENGTH = 255; // BOV_Submission__c.Broker_Firm__c's OWN length, not Contact's.

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 1. Every BOV_Submission__c row with a broker Contact set, pulling the broker's OWN
// Broker_Firm__c through the Broker__r relationship. Blank detection happens in Apex below,
// not in this WHERE clause, so both NULL and empty-string are caught identically.
// ═════════════════════════════════════════════════════════════════════════════════════
List<BOV_Submission__c> candidates = [
    SELECT Id, Name, Broker_Firm__c, Contact_Name__c, Broker__c,
           Broker__r.Name, Broker__r.Broker_Firm__c
    FROM BOV_Submission__c
    WHERE Broker__c != null
    ORDER BY Name
];

System.debug(LoggingLevel.INFO, 'SCAN BASIS: ' + candidates.size()
    + ' BOV_Submission__c row(s) with Broker__c set.');

if (candidates.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Nothing to do: no BOV_Submission__c rows have a broker set.');
    System.debug(LoggingLevel.INFO, 'REPAIR VERDICT: NOTHING TO DO');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 2. Build the update list — blank-destination-only, broker-has-firm-only, with the
// truncation guard. Every row is logged (PLAN / SKIP) regardless of PREVIEW_ONLY.
// ═════════════════════════════════════════════════════════════════════════════════════
List<BOV_Submission__c> toUpdate = new List<BOV_Submission__c>();
Integer skippedAlreadySet = 0;
Integer skippedBrokerHasNoFirm = 0;
Integer truncatedCount = 0;

for (BOV_Submission__c s : candidates) {
    if (!String.isBlank(s.Broker_Firm__c)) {
        skippedAlreadySet++;
        System.debug(LoggingLevel.INFO, 'SKIP (already has a firm) ' + s.Name + ' -> "'
            + s.Broker_Firm__c + '". Never overwritten.');
        continue;
    }

    String brokerFirm = s.Broker__r != null ? s.Broker__r.Broker_Firm__c : null;
    if (String.isBlank(brokerFirm)) {
        skippedBrokerHasNoFirm++;
        System.debug(LoggingLevel.WARN, 'SKIP (broker Contact has no firm) ' + s.Name
            + ' -> broker "' + (s.Broker__r != null ? s.Broker__r.Name : '(unresolved)')
            + '" (' + s.Broker__c + ') still has a blank Broker_Firm__c. Nothing to copy.');
        continue;
    }

    String firmValue = brokerFirm;
    if (firmValue.length() > BROKER_FIRM_MAX_LENGTH) {
        truncatedCount++;
        System.debug(LoggingLevel.WARN, 'TRUNCATED ' + s.Name + ': source firm is '
            + firmValue.length() + ' chars, exceeds Broker_Firm__c\'s ' + BROKER_FIRM_MAX_LENGTH
            + '-char limit. Original: "' + firmValue + '"');
        firmValue = firmValue.left(BROKER_FIRM_MAX_LENGTH);
    }

    BOV_Submission__c upd = new BOV_Submission__c(Id = s.Id, Broker_Firm__c = firmValue);
    toUpdate.add(upd);
    System.debug(LoggingLevel.INFO, 'PLAN ' + s.Name + ' (broker ' + s.Broker__r.Name + ') -> "'
        + firmValue + '"');
}

System.debug(LoggingLevel.INFO, 'SCAN SUMMARY: ' + candidates.size() + ' row(s) with a broker set, '
    + toUpdate.size() + ' to update, ' + skippedAlreadySet + ' already set (skipped), '
    + skippedBrokerHasNoFirm + ' broker-has-no-firm (skipped), ' + truncatedCount + ' truncated.');

if (toUpdate.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Nothing to update. All rows already have a firm, or their '
        + 'broker Contact still has none.');
    System.debug(LoggingLevel.INFO, 'REPAIR VERDICT: NOTHING TO DO');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 3. THE PREVIEW GATE. Everything above is reads and in-memory building; the first DML in
// this script is the update below. Returning here is a genuine dry run, not a partial one.
// ═════════════════════════════════════════════════════════════════════════════════════
if (PREVIEW_ONLY) {
    System.debug(LoggingLevel.WARN, 'PREVIEW ONLY - NO RECORDS WERE UPDATED. Would update '
        + toUpdate.size() + ' BOV_Submission__c row(s). Read every PLAN / SKIP line above, then '
        + 'set PREVIEW_ONLY = false and re-run.');
    System.debug(LoggingLevel.WARN, 'REPAIR VERDICT: PREVIEW (no DML performed)');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 4. Update. allOrNone = false so one refused row cannot cost the others their repair;
// every outcome is logged against its record. Broker__c is NOT in this payload — see the header
// "WHY THIS IS SAFE" block for why that is what keeps the stamp service from re-firing.
// ═════════════════════════════════════════════════════════════════════════════════════
List<Database.SaveResult> results = Database.update(toUpdate, false);
Integer updated = 0;
Integer failed = 0;
for (Integer i = 0; i < results.size(); i++) {
    BOV_Submission__c target = toUpdate[i];
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
// STEP 5. Verify from the database, not from what we intended.
// ═════════════════════════════════════════════════════════════════════════════════════
List<BOV_Submission__c> verify = [
    SELECT Id, Name, Broker_Firm__c, Contact_Name__c, Broker_Display__c
    FROM BOV_Submission__c
    WHERE Id IN :toUpdate
    ORDER BY Name
];
for (BOV_Submission__c v : verify) {
    System.debug(LoggingLevel.INFO, 'VERIFY ' + v.Name + ': Broker_Firm__c="' + v.Broker_Firm__c
        + '", Contact_Name__c="' + v.Contact_Name__c + '", Broker_Display__c="'
        + v.Broker_Display__c + '"');
}

System.debug(LoggingLevel.INFO, 'REPAIR SUMMARY: ' + candidates.size() + ' scanned, ' + updated
    + ' updated, ' + failed + ' failed, ' + skippedAlreadySet + ' already-set, '
    + skippedBrokerHasNoFirm + ' broker-has-no-firm, ' + truncatedCount + ' truncated.');
System.debug(LoggingLevel.INFO, 'REPAIR VERDICT: '
    + (failed == 0 ? 'COMPLETE' : 'INCOMPLETE - read the FAILED lines above'));
