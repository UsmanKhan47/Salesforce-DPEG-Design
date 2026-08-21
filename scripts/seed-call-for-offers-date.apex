/**
 * ONE-TIME DATA SEED — populate `Broker_Listing__c.Call_For_Offers_Date__c` for every listing
 * that is missing it, so the Call For Offers card has something plausible to render in UAT.
 *
 * Run:  sf apex run --file scripts/seed-call-for-offers-date.apex --target-org usman-dpeg
 * Then read the per-row log and the final "SEED VERDICT" line.
 *
 * =====================================================================================
 * 🔴 WHY THIS EXISTS
 * =====================================================================================
 * The operator reported "can't see data in call for offers" — measured 2026-08-21: the org's
 * only `Broker_Listing__c` (`BL-0009`, Colliers Houston, `List_Date__c` = 2026-08-21) has
 * `Call_For_Offers_Date__c` blank. `CallForOffersService.buildCountdown` (the single derivation
 * of call-for-offers state — see that class's header) treats a null due date as
 * `hasDueDate = false` and renders nothing to count down: this IS a data gap, not a bug, exactly
 * as diagnosed. The operator confirmed this field will eventually be populated by an upstream
 * automation, not logged by hand — "right now can just seed data in it."
 *
 * =====================================================================================
 * OFFSET CHOSEN: 30 DAYS AFTER List_Date__c
 * =====================================================================================
 * `CallForOffersService`'s own alert ladder (`ALERT_INTERVALS` = {7, 3, 1, 0} days;
 * `APPROACHING_DAYS` = 7, `CRITICAL_DAYS` = 3) tops out at 7 days out — anything further out
 * renders as a plain "Due in N days" badge with no urgency colour. A freshly-listed asset
 * (`List_Date__c` = today) sitting inside that 7-day critical window would be a misleading seed:
 * it would paint the card red/amber for a listing that has not even started its marketing period.
 * 30 days mirrors the standard CRE call-for-offers cadence — roughly a 4-week marketing and
 * buyer-outreach window between going to market and a bid deadline — and lands well outside the
 * alert ladder, so the seeded card shows a calm "Due in 30 days" instead of a fabricated crisis.
 *
 * =====================================================================================
 * SCOPE — BLANK-ONLY, NEVER OVERWRITE; REQUIRES A LIST DATE
 * =====================================================================================
 * Every candidate is read and `Call_For_Offers_Date__c == null` is checked in Apex before it is
 * added to the update list — a listing that already has a date (including one this script wrote
 * on a prior run) is skipped and logged, never touched. A listing with no `List_Date__c` is also
 * skipped and logged: there is no anchor to offset from, and inventing one would be worse than
 * leaving the field blank. This makes the script idempotent — a second run finds nothing to do.
 *
 * =====================================================================================
 * WHAT THIS SCRIPT DELIBERATELY DOES NOT DO
 * =====================================================================================
 * It does not touch `Offers_Received__c` (already correctly `0` — no offers exist yet, and this
 * is not a script about offers) or any other field. It does not change the layout's
 * `Readonly` behaviour on `Call_For_Offers_Date__c` (a Lightning Record Page / Dynamic Forms
 * setting, not enforced by the DML engine — this anonymous Apex script bypasses it exactly the
 * way any admin backfill does).
 *
 * =====================================================================================
 * PREVIEW_ONLY — READ WHAT IT WOULD DO BEFORE IT DOES IT
 * =====================================================================================
 * Defaults to **true**, matching `scripts/backfill-broker-firm.apex`. In PREVIEW mode every
 * candidate is resolved, every skip rule applied, every planned date printed, and the script
 * STOPS before `Database.update` and returns. No DML of any kind. Flip to false only after
 * reading the full PREVIEW output.
 *
 * =====================================================================================
 * SYSTEM MODE IS DELIBERATE (no WITH USER_MODE)
 * =====================================================================================
 * ARCHITECTURE.md §2 mandates `WITH USER_MODE` for SELECTOR CLASSES in force-app. This is
 * anonymous Apex run by an administrator against live data, is not part of the deployed
 * codebase, and is not a selector; the surrounding scripts/ files follow the same convention.
 *
 * ROLLBACK: none from here. This only ever writes into a field that was blank, so the only undo
 * is setting `Call_For_Offers_Date__c` back to null by hand on the specific Ids logged as
 * UPDATED below.
 */

// ── PREVIEW_ONLY: true = resolve, scan, apply every skip rule, print the full plan, then RETURN
//    before any DML. Flip to false only after reading the PREVIEW output. See the header.
final Boolean PREVIEW_ONLY = true;

final Integer OFFSET_DAYS = 30;

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 1. Every Broker_Listing__c, not pre-filtered on Call_For_Offers_Date__c (blank
// detection happens in Apex, not SOQL, matching scripts/backfill-broker-firm.apex).
// ═════════════════════════════════════════════════════════════════════════════════════
List<Broker_Listing__c> listings = [
    SELECT Id, Name, List_Date__c, Call_For_Offers_Date__c
    FROM Broker_Listing__c
    ORDER BY Name
];

System.debug(LoggingLevel.INFO, 'SCAN BASIS: ' + listings.size() + ' Broker_Listing__c record(s).');

if (listings.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Nothing to do: no Broker_Listing__c records in this org.');
    System.debug(LoggingLevel.INFO, 'SEED VERDICT: NOTHING TO DO');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 2. Build the update list — blank-only, has-list-date-only. Every row is logged
// (PLAN / SKIP) regardless of PREVIEW_ONLY, so the plan is fully visible before any DML runs.
// ═════════════════════════════════════════════════════════════════════════════════════
List<Broker_Listing__c> toUpdate = new List<Broker_Listing__c>();
Integer skippedAlreadySet = 0;
Integer skippedNoListDate = 0;

for (Broker_Listing__c bl : listings) {
    if (bl.Call_For_Offers_Date__c != null) {
        skippedAlreadySet++;
        System.debug(LoggingLevel.INFO, 'SKIP (already has a date) ' + bl.Name + ' -> '
            + bl.Call_For_Offers_Date__c + '. Never overwritten.');
        continue;
    }
    if (bl.List_Date__c == null) {
        skippedNoListDate++;
        System.debug(LoggingLevel.WARN, 'SKIP (no List_Date__c) ' + bl.Name + ' (' + bl.Id
            + '). No anchor date to offset from.');
        continue;
    }

    Date plannedDate = bl.List_Date__c.addDays(OFFSET_DAYS);
    Broker_Listing__c upd = new Broker_Listing__c(Id = bl.Id, Call_For_Offers_Date__c = plannedDate);
    toUpdate.add(upd);
    System.debug(LoggingLevel.INFO, 'PLAN ' + bl.Name + ': List_Date__c ' + bl.List_Date__c
        + ' + ' + OFFSET_DAYS + ' days -> Call_For_Offers_Date__c ' + plannedDate);
}

System.debug(LoggingLevel.INFO, 'SCAN SUMMARY: ' + listings.size() + ' Broker_Listing__c record(s) total, '
    + toUpdate.size() + ' to update, ' + skippedAlreadySet + ' already set (skipped), '
    + skippedNoListDate + ' with no List_Date__c (skipped).');

if (toUpdate.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Nothing to update. All listings already have a call-for-offers '
        + 'date, or have no List_Date__c to offset from.');
    System.debug(LoggingLevel.INFO, 'SEED VERDICT: NOTHING TO DO');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 3. THE PREVIEW GATE. Everything above is reads and in-memory building; the first DML
// in this script is the update below. Returning here is a genuine dry run, not a partial one.
// ═════════════════════════════════════════════════════════════════════════════════════
if (PREVIEW_ONLY) {
    System.debug(LoggingLevel.WARN, 'PREVIEW ONLY - NO RECORDS WERE UPDATED. Would update '
        + toUpdate.size() + ' Broker_Listing__c record(s). Read every PLAN line above, then set '
        + 'PREVIEW_ONLY = false and re-run.');
    System.debug(LoggingLevel.WARN, 'SEED VERDICT: PREVIEW (no DML performed)');
    return;
}

// ═════════════════════════════════════════════════════════════════════════════════════
// STEP 4. Update. allOrNone = false so one refused row cannot cost the others their seed;
// every outcome is logged against its record.
// ═════════════════════════════════════════════════════════════════════════════════════
List<Database.SaveResult> results = Database.update(toUpdate, false);
Integer updated = 0;
Integer failed = 0;
for (Integer i = 0; i < results.size(); i++) {
    Broker_Listing__c target = toUpdate[i];
    if (results[i].isSuccess()) {
        updated++;
        System.debug(LoggingLevel.INFO, 'UPDATED ' + target.Id + ' -> '
            + target.Call_For_Offers_Date__c);
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
Integer nowPopulated = [
    SELECT COUNT()
    FROM Broker_Listing__c
    WHERE Call_For_Offers_Date__c != null
];
Integer totalListings = [SELECT COUNT() FROM Broker_Listing__c];

System.debug(LoggingLevel.INFO, 'VERIFY: ' + nowPopulated + ' of ' + totalListings
    + ' Broker_Listing__c record(s) now have Call_For_Offers_Date__c populated.');

System.debug(LoggingLevel.INFO, 'SEED SUMMARY: ' + listings.size() + ' scanned, ' + updated
    + ' updated, ' + failed + ' failed, ' + skippedAlreadySet + ' already-set, '
    + skippedNoListDate + ' no-list-date.');
System.debug(LoggingLevel.INFO, 'SEED VERDICT: '
    + (failed == 0 ? 'COMPLETE' : 'INCOMPLETE - read the FAILED lines above'));
