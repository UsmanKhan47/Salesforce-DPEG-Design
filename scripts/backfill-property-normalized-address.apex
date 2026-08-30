/**
 * WS3 (2026-08-30) — one-off backfill of Property__c.Normalized_Address__c.
 *
 * WHAT IT DOES
 * Stamps every existing Property__c with the reuse key derived from its Address__c, using
 * PropertyMatchingService.normalizeAddress — the SOLE definition of that key. Without this,
 * LeadConvertService's reuse lookup can only ever find Properties created AFTER the WS3 deploy,
 * so every building the org already knows about would be duplicated once more before it started
 * working. This script is what makes the feature retroactive.
 *
 * 🔴 IT CALLS normalizeAddress. IT DOES NOT REIMPLEMENT IT.
 * Copying the four-line regex chain in here would produce a key that agrees today and diverges the
 * first time either copy is touched — after which the same building keys two ways, the lookup
 * misses, a duplicate Property is created, and nothing anywhere reports it. A formula is not an
 * option either (P14: the normalization is regex; Salesforce formulas have none), which is why the
 * field is stored Text and why this script exists at all.
 *
 * SCALE — MEASURED, NOT ESTIMATED (usman-dpeg, 2026-08-30)
 *   61 Property__c rows in the org, all 61 with a non-null Address__c.
 *   Normalizing all 61 offline produced 61 DISTINCT keys — ZERO collisions today. So this org has
 *   no pre-existing duplicate buildings to reconcile; the field's unique=false is protecting a
 *   scenario that has not happened HERE yet, not one already present. The duplicate-key report at
 *   the bottom is what will say when that changes.
 *
 * IDEMPOTENT AND RE-RUNNABLE. The work list is "rows whose stored key does not equal the key
 * recomputed from their current Address__c" — which covers a null key (never stamped), a stale key
 * (Address__c edited by hand since), and a key written by an older normalizeAddress. A second run
 * therefore finds nothing and updates nothing. A partial run can simply be repeated.
 *
 * ═══ 🔴 RUN-AS PRECONDITIONS. THIS SCRIPT CANNOT ESCAPE FLS OR SHARING, AND MUST NOT PRETEND TO ═══
 * Anonymous Apex REFUSES `WITH SYSTEM_MODE` and `AccessLevel.SYSTEM_MODE` outright
 * ("Cannot use SYSTEM_MODE access level in anonymous execution of Apex"), and has no
 * `without sharing`. So both enforcement layers that LeadConvertService's own SYSTEM_MODE read
 * escapes are fully in force here, and under allOrNone = false they fail QUIETLY, PER ROW:
 *
 *   1. FLS — 🔴 THIS IS A HARD BLOCKER TODAY, AND IT IS MEASURED, NOT PREDICTED.
 *      Normalized_Address__c is deployed by the Metadata API and therefore arrives with NO field
 *      permissions for ANY profile, System Administrator included. With zero FieldPermissions rows
 *      the field is not merely denied, it is ABSENT from the running user's schema. Measured on
 *      usman-dpeg at API 67.0 on 2026-08-30: a plain `insert` of a Property__c carrying this field
 *      — as a System Administrator — was refused with
 *          System.DmlException: Operation failed due to fields being inaccessible on
 *          Sobject Property__c
 *      and the deployed Apex had to state `AccessLevel.SYSTEM_MODE` to write it. THIS SCRIPT
 *      CANNOT DO THAT (see above), so it has no route around the grant. Run too early it will
 *      either fail to compile (`Variable does not exist` / `No such column`) or refuse every row.
 *      Those are the expected symptoms of running it early — they are not bugs in the script.
 *      ⇒ RUN IT ONLY AFTER the P8 permission-set pass has granted `editable = true` on
 *        Property__c.Normalized_Address__c, and run it as a user who HOLDS that set.
 *      ⇒ THE FEATURE ITSELF DOES NOT WAIT FOR THAT GRANT — `LeadConvertService` states its access
 *        level, so new conversions key and reuse correctly from the moment they deploy. Only the
 *        RETROACTIVE half (this script, i.e. the 61 buildings the org already holds) is blocked.
 *   2. SHARING — Property__c OWD is Private. `viewAllRecords` grants READ on every row while WRITE
 *      still needs ownership or a share, so a runner without Modify All Data would silently stamp
 *      only the subset it owns and the VERIFY block would report the rest as remaining.
 *      ⇒ RUN AS A SYSTEM ADMINISTRATOR (Modify All Data), not as an Acquisitions persona.
 *
 * If it ever needs to run unattended or as a non-admin, it has to become a DEPLOYED class, where
 * SYSTEM_MODE is legal. That is a different change, not a flag on this one.
 *
 * VOLUME CEILING. Anonymous Apex allows 10,000 DML rows per transaction, so the work list is
 * capped at MAX_ROWS below. At 61 rows the cap is nowhere near binding; it is here so that a future
 * run against a grown org fails SAFELY (does part of the work, says so, asks to be re-run) instead
 * of throwing halfway through. Because the script is idempotent, "re-run until remaining = 0" is a
 * complete procedure.
 *
 * Run:  sf apex run --file scripts/backfill-property-normalized-address.apex --target-org <alias>
 * Then read the VERIFY block at the bottom of the debug log. `remaining` MUST be 0.
 */

// Below the 10,000-row anonymous-Apex DML ceiling with room for the query itself.
Integer MAX_ROWS = 9000;

List<Property__c> candidates = [
    SELECT Id, Name, Address__c, Normalized_Address__c
    FROM Property__c
    WHERE Address__c != null
    ORDER BY CreatedDate ASC
    LIMIT :MAX_ROWS
];

List<Property__c> toFix = new List<Property__c>();
Integer alreadyCorrect = 0;
Integer blankKey = 0;
Map<String, Integer> keyCounts = new Map<String, Integer>();

for (Property__c p : candidates) {
    // THE ONE CALL. See the header — never a local reimplementation of this expression.
    String key = PropertyMatchingService.normalizeAddress(p.Address__c);
    if (String.isBlank(key)) {
        // An Address__c of pure punctuation ('---') normalizes to ''. Storing '' would make every
        // such row match every other one, collapsing them onto a single shared "building". Leave
        // the key null: no key is the honest answer, and a null key is simply invisible to the
        // reuse lookup, which is the pre-WS3 behaviour for that row and no worse.
        blankKey++;
        continue;
    }
    keyCounts.put(key, keyCounts.containsKey(key) ? keyCounts.get(key) + 1 : 1);
    if (key.equals(p.Normalized_Address__c)) {
        alreadyCorrect++;
        continue;
    }
    toFix.add(new Property__c(Id = p.Id, Normalized_Address__c = key));
}

Integer succeeded = 0;
Integer failed = 0;
if (!toFix.isEmpty()) {
    // allOrNone = false so one refused row does not abandon the other 60. The cost is that
    // refusals are silent unless printed — hence the per-row loop below, which prints EVERY error
    // on the row rather than getErrors()[0]: an FLS refusal and a validation rule arrive together,
    // and reporting only the first sends the reader at the wrong precondition.
    Database.SaveResult[] results = Database.update(toFix, false);
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            succeeded++;
            continue;
        }
        failed++;
        for (Database.Error err : results[i].getErrors()) {
            System.debug(LoggingLevel.ERROR,
                'BACKFILL FAILED  Id=' + toFix[i].Id
                + '  key="' + toFix[i].Normalized_Address__c + '"'
                + '  code=' + err.getStatusCode()
                + '  fields=' + err.getFields()
                + '  message=' + err.getMessage());
        }
    }
}

System.debug('Property__c examined: ' + candidates.size()
    + '  already correct: ' + alreadyCorrect
    + '  blank-key (left null): ' + blankKey
    + '  attempted: ' + toFix.size()
    + '  updated: ' + succeeded
    + '  refused: ' + failed);

// ================================================================ VERIFY
// Prove the stamp, do not assume it. Re-read from the database rather than trusting the in-memory
// list — an allOrNone = false update reports success per row, but only a re-read proves the value
// that actually landed is the value normalizeAddress produces for that row TODAY.
System.debug('======================= VERIFY =======================');

Integer total = [SELECT COUNT() FROM Property__c];
Integer addressed = [SELECT COUNT() FROM Property__c WHERE Address__c != null];

Integer remaining = 0;
Integer mismatch = 0;
Map<String, Integer> finalKeyCounts = new Map<String, Integer>();
for (Property__c p : [
    SELECT Id, Name, Address__c, Normalized_Address__c
    FROM Property__c
    WHERE Address__c != null
]) {
    String expected = PropertyMatchingService.normalizeAddress(p.Address__c);
    if (String.isBlank(expected)) {
        continue; // deliberately un-keyed; see the blank-key branch above
    }
    if (p.Normalized_Address__c == null) {
        remaining++;
    } else if (!expected.equals(p.Normalized_Address__c)) {
        mismatch++;
        System.debug(LoggingLevel.ERROR, 'KEY MISMATCH  Id=' + p.Id
            + '  stored="' + p.Normalized_Address__c + '"  expected="' + expected + '"');
    }
    finalKeyCounts.put(expected,
        finalKeyCounts.containsKey(expected) ? finalKeyCounts.get(expected) + 1 : 1);
}

// DUPLICATE BUILDINGS — the point of the whole workstream, made visible. Every key with a count
// above 1 is a building this org holds MORE THAN ONE Property__c row for. This is NOT a backfill
// failure and must not be "fixed" here: Normalized_Address__c is unique = false precisely so these
// rows can be stamped. From this run on, a new conversion for such a building reuses the OLDEST of
// them (PropertySelector.selectByNormalizedAddresses orders CreatedDate ASC) and stops adding to
// the pile. Merging the existing rows is a separate, human, data decision.
Integer duplicateKeys = 0;
Integer duplicateRows = 0;
for (String key : finalKeyCounts.keySet()) {
    Integer n = finalKeyCounts.get(key);
    if (n > 1) {
        duplicateKeys++;
        duplicateRows += n;
        System.debug(LoggingLevel.WARN,
            'DUPLICATE BUILDING  ' + n + ' Property rows share key "' + key + '"');
    }
}

System.debug('Property__c  total=' + total + '  addressed=' + addressed
    + '  remaining=' + remaining + '  value-mismatch=' + mismatch
    + '  duplicate-keys=' + duplicateKeys + '  rows-in-duplicate-groups=' + duplicateRows);

Boolean clean = (remaining == 0 && mismatch == 0 && failed == 0);
System.debug('BACKFILL VERDICT: ' + (clean
    ? 'COMPLETE - every addressed Property carries the key normalizeAddress produces for it'
    : 'INCOMPLETE - DO NOT rely on Property reuse yet. Re-run; if remaining stays > 0, check the '
      + 'two RUN-AS PRECONDITIONS in this file header (FLS grant, and Modify All Data for a '
      + 'Private-OWD object) before looking anywhere else.'));
if (!clean) {
    // Fail loudly. A silent partial backfill here does not look like a failure — it looks like the
    // reuse feature simply not finding anything, which is indistinguishable from the bug it fixes.
    throw new IllegalArgumentException(
        'Normalized_Address__c backfill incomplete: remaining=' + remaining
        + ' mismatch=' + mismatch + ' refused=' + failed
        + (candidates.size() == MAX_ROWS
            ? ' (the ' + MAX_ROWS + '-row cap was hit - re-run until remaining=0)' : ''));
}
