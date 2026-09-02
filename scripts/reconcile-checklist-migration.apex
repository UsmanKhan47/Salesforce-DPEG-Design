// ═══════════════════════════════════════════════════════════════════════════════════════════
// PHASE 4 — M2. THE RECONCILIATION REPORT THAT GATES CUTOVER. Read-only: zero DML.
//
//   sf apex run --file scripts/reconcile-checklist-migration.apex --target-org usman-dpeg
//
// Per deal, per check, per coordinate: does the Checklist_Item__c model agree with the Task
// model it replaced? The last line of the output is the whole answer:
//
//     CUTOVER: CLEAR     -> M3 (the flow repoint) may proceed
//     CUTOVER: BLOCKED   -> it may not. Every blocking finding is named, with its coordinate.
//
// 🔴 THIS IS A GATE, NOT A DASHBOARD. There are no percentages in the output on purpose:
// "97% agreement" hides which 3%, and the 3% is the part that matters.
//
// TWO MODES, chosen per deal automatically and printed on its header line:
//   PERSISTED — the deal IS migrated; compared against the rows actually in the database.
//               This is the mode that gates cutover.
//   PROJECTED — the deal is NOT migrated; compared against a fresh projection, which explains
//               exactly why the M1 gate refused it.
//
// ⚠ CAPPED AT 25 DEALS PER RUN, and the cap THROWS rather than truncating. It is a HEAP
// bound (both models are held in memory at once, against a 6 MB synchronous ceiling), not a
// SOQL one. To cover a larger population, move OFFSET down the list and run again — the
// report is per deal, so the runs concatenate cleanly.
// ═══════════════════════════════════════════════════════════════════════════════════════════

Integer PAGE_SIZE = 25;   // 🔴 BOUND BY THE QUERY *AND* BY THE ADVICE BELOW. It was hardcoded as
                          // `LIMIT 25` here while the trailer told the operator to advance by
                          // PAGE_SIZE - so changing PAGE_SIZE alone silently skipped or repeated
                          // deals, in the one script whose whole job is proving nothing was
                          // missed. Do not raise above 25: ChecklistMigrationAuditService THROWS.
Integer OFFSET = 0;       // advance by PAGE_SIZE and re-run to page through the org

// Leave empty to page through every deal that has EITHER model; populate to target specific ones.
List<Id> EXPLICIT_IDS = new List<Id>{
    // '0Q0xx0000000001AAA'
};

List<Id> targets = new List<Id>();
if (!EXPLICIT_IDS.isEmpty()) {
    targets.addAll(EXPLICIT_IDS);
} else {
    // Deals that have been through EITHER fan-out. A deal that has never been fanned out at all
    // has nothing to reconcile and is deliberately out of scope — including it would report a
    // vacuous CLEAN and inflate the denominator on the one line anybody reads.
    List<Transaction__c> page = [
        SELECT Id
        FROM Transaction__c
        WHERE Tasks_Fanned_Out__c = true OR Checklist_Fanned_Out__c = true
        ORDER BY CreatedDate
        LIMIT :PAGE_SIZE
        OFFSET :OFFSET
    ];
    for (Transaction__c deal : page) {
        targets.add(deal.Id);
    }
}

if (targets.isEmpty()) {
    System.debug(LoggingLevel.ERROR,
        '== CHECKLIST MIGRATION RECONCILIATION ==\n'
        + 'No deals in scope at OFFSET ' + OFFSET + '.\n'
        + 'NOTHING WAS CHECKED - THIS IS NOT A PASS. If OFFSET is 0, either no deal has been '
        + 'fanned out on either model, or you cannot SEE them (check DPEG_Transactions_Team '
        + 'membership). Those are not the same thing.\n'
        + 'CUTOVER: BLOCKED');
} else {
    List<ChecklistMigrationAuditService.DealVerdict> verdicts =
        ChecklistMigrationAuditService.compare(targets);
    // LoggingLevel.ERROR so the report survives a default debug-level run. This is the whole
    // point of the script; it is not a stray debug on a production path.
    System.debug(LoggingLevel.ERROR, ChecklistMigrationAuditService.format(verdicts));
    System.debug(LoggingLevel.ERROR,
        'page: OFFSET ' + OFFSET + ' size ' + targets.size()
        + '. Re-run with OFFSET ' + (OFFSET + PAGE_SIZE) + ' to continue. '
        + 'EVERY page must read CUTOVER: CLEAR before M3.');
}
