/**
 * Phase 2 of the Unit__c -> Unit_Label__c migration (ARCHITECTURE.md §1 rule 9).
 *
 * Copies the legacy Text field Unit__c into the new Unit_Label__c on:
 *   - Lease_Renewal__c
 *   - Work_Order__c
 *
 * DOES NOT TOUCH Rent_Step__c.Unit__c - that is a MasterDetail to the Unit__c
 * object and is CORRECT. It is not part of this migration.
 *
 * Safe to re-run (idempotent): only rows where the copy has not already landed
 * are updated, so a partial run can simply be repeated.
 *
 * Run:  sf apex run --file scripts/backfill-unit-label.apex --target-org <alias>
 * Then read the VERIFY block at the bottom of the debug log. Every line must
 * report remaining=0. If any line reports remaining>0, the backfill is INCOMPLETE
 * - do not proceed to Phase 3/4.
 */

// ---------------------------------------------------------------- Lease_Renewal__c
List<Lease_Renewal__c> lrToFix = [
    SELECT Id, Unit__c, Unit_Label__c
    FROM Lease_Renewal__c
    WHERE Unit__c != null AND Unit_Label__c = null
];
for (Lease_Renewal__c r : lrToFix) {
    r.Unit_Label__c = r.Unit__c;
}
if (!lrToFix.isEmpty()) {
    update lrToFix;   // single DML, bulk-safe for any volume via chunked re-runs
}
System.debug('Lease_Renewal__c   rows updated: ' + lrToFix.size());

// ---------------------------------------------------------------- Work_Order__c
List<Work_Order__c> woToFix = [
    SELECT Id, Unit__c, Unit_Label__c
    FROM Work_Order__c
    WHERE Unit__c != null AND Unit_Label__c = null
];
for (Work_Order__c w : woToFix) {
    w.Unit_Label__c = w.Unit__c;
}
if (!woToFix.isEmpty()) {
    update woToFix;
}
System.debug('Work_Order__c      rows updated: ' + woToFix.size());

// ================================================================ VERIFY
// Prove the copy, do not assume it. Three independent checks per object:
//   total      - every row, for context
//   populated  - rows where the source had a value
//   mismatch   - rows where source has a value but target does not equal it
//   remaining  - rows still needing the copy  (MUST be 0)
System.debug('======================= VERIFY =======================');

Integer lrTotal     = [SELECT COUNT() FROM Lease_Renewal__c];
Integer lrPopulated = [SELECT COUNT() FROM Lease_Renewal__c WHERE Unit__c != null];
Integer lrRemaining = [SELECT COUNT() FROM Lease_Renewal__c WHERE Unit__c != null AND Unit_Label__c = null];
Integer lrMismatch  = 0;
for (Lease_Renewal__c r : [SELECT Unit__c, Unit_Label__c FROM Lease_Renewal__c WHERE Unit__c != null]) {
    if (r.Unit_Label__c != r.Unit__c) lrMismatch++;
}
System.debug('Lease_Renewal__c  total=' + lrTotal + '  populated=' + lrPopulated +
             '  copied=' + (lrPopulated - lrRemaining) + '  remaining=' + lrRemaining +
             '  value-mismatch=' + lrMismatch);

Integer woTotal     = [SELECT COUNT() FROM Work_Order__c];
Integer woPopulated = [SELECT COUNT() FROM Work_Order__c WHERE Unit__c != null];
Integer woRemaining = [SELECT COUNT() FROM Work_Order__c WHERE Unit__c != null AND Unit_Label__c = null];
Integer woMismatch  = 0;
for (Work_Order__c w : [SELECT Unit__c, Unit_Label__c FROM Work_Order__c WHERE Unit__c != null]) {
    if (w.Unit_Label__c != w.Unit__c) woMismatch++;
}
System.debug('Work_Order__c     total=' + woTotal + '  populated=' + woPopulated +
             '  copied=' + (woPopulated - woRemaining) + '  remaining=' + woRemaining +
             '  value-mismatch=' + woMismatch);

Boolean clean = (lrRemaining == 0 && woRemaining == 0 && lrMismatch == 0 && woMismatch == 0);
System.debug('BACKFILL VERDICT: ' + (clean ? 'COMPLETE - every populated row copied, zero mismatches'
                                           : 'INCOMPLETE - DO NOT PROCEED. Re-run, then investigate.'));
if (!clean) {
    // Fail loudly. A silent partial backfill is how data quietly goes missing.
    throw new IllegalArgumentException(
        'Unit_Label__c backfill incomplete: Lease_Renewal remaining=' + lrRemaining +
        ' mismatch=' + lrMismatch + '; Work_Order remaining=' + woRemaining +
        ' mismatch=' + woMismatch);
}
