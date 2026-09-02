// ═══════════════════════════════════════════════════════════════════════════════════════════
// PHASE 4 — M1 REVERSAL. Puts the named deals back on the legacy `Task` checklist.
//
//   sf apex run --file scripts/rollback-transaction-checklist-migration.apex --target-org usman-dpeg
//
// WHAT IT DOES, IN THIS ORDER (ChecklistMigrationService.rollback owns the order and the order
// is the method):
//   1. clears `Checklist_Fanned_Out__c`  — FIRST, because the Phase 4 counter guard in
//      `TaskRollupService.recalc` skips CLAIMED deals. Recomputing before this line is a
//      silent no-op and would leave the deal showing the checklist model's numbers with no
//      checklist behind them.
//   2. deletes the deal's `Checklist__c` rows — master-detail cascades the items — with the
//      rollup suppressed.
//   3. recomputes the four counters from the `Task` rows, WHICH WERE NEVER TOUCHED.
//
// 🔴 DELETING THE TRANSACTION IS NOT THE ROLLBACK, even though it is now possible.
// Design §7 RISK 2 said deal deletion was unavailable because `Critical_Date__c.Transaction__c`
// was `required=true` + `deleteConstraint=Restrict`. THAT IS STALE — the field was relaxed to
// `SetNull` + optional on 2026-08-31 under GATE-B3. But availability is not suitability:
// deleting the deal destroys the very `Task` rows this entire strategy exists to preserve, plus
// its `Wire__c` links, its field history and its Opportunity gate flags. Use this script.
//
// 🔴 THIS SCRIPT IS SAFE ONLY BEFORE M3. AFTER THE FLOW REPOINT IT UNDOES ITSELF.
// Step 1 writes `Checklist_Fanned_Out__c` true -> false. M3 repoints
// `flows/Transaction_Task_Fanout` to filter on that field being false, and the flow declares
// `doesRequireRecordChangedToMeetCriteria = true` - so the un-claim IS a record changing INTO
// the criteria, the flow fires, `ChecklistFanoutService` sees its only dedupe guard now false,
// and the deal is re-fanned with a brand new checklist and re-claimed. `Tasks_Complete__c` is
// overwritten with 0, destroying the recompute step 3 just did and every completion carried
// over by M1.
// ⇒ AFTER M3, DEACTIVATE OR RE-FILTER THAT FLOW BEFORE RUNNING THIS, AND RESTORE IT AFTER.
//   That is a deploy, not a script argument. It is also why M3 is sequenced only after M2 reads
//   CUTOVER: CLEAR - by that point a rollback should not be needed.
//
// ⚠ SAME SHARING PREREQUISITE AS THE MIGRATION: you must be able to EDIT the deal (member of
// `DPEG_Transactions_Team`, or Modify All Data). Deleting a master-detail child requires it.
// ⚠ SYNCHRONOUS AND UNCHUNKED ON PURPOSE — a rollback is an incident response on a handful of
// deals, not a bulk operation. Keep TARGET_IDS small (<= 10). If you genuinely need to roll
// back the whole org, do it in pages rather than raising this limit.
// ═══════════════════════════════════════════════════════════════════════════════════════════

Set<Id> TARGET_IDS = new Set<Id>{
    // '0Q0xx0000000001AAA'
};

if (TARGET_IDS.isEmpty()) {
    System.debug(LoggingLevel.ERROR,
        'TARGET_IDS is empty. THIS SCRIPT DELIBERATELY HAS NO "ALL DEALS" MODE - a rollback is '
        + 'an incident response and every deal in it should have been chosen deliberately. '
        + 'Paste the Transaction Ids you mean.');
} else if (TARGET_IDS.size() > 10) {
    System.debug(LoggingLevel.ERROR,
        'Refusing ' + TARGET_IDS.size() + ' deals in one synchronous run. Page it at 10.');
} else {
    System.debug(LoggingLevel.ERROR, '== CHECKLIST MIGRATION ROLLBACK ==');
    System.debug(LoggingLevel.ERROR, 'deals asked : ' + TARGET_IDS.size());

    Set<Id> rolledBack = ChecklistMigrationService.rollback(TARGET_IDS);

    System.debug(LoggingLevel.ERROR, 'rolled back : ' + rolledBack.size());
    Set<Id> untouched = new Set<Id>(TARGET_IDS);
    untouched.removeAll(rolledBack);
    if (!untouched.isEmpty()) {
        System.debug(LoggingLevel.ERROR,
            'NOT ROLLED BACK (had no checklist and no claim, or you cannot see them): '
            + untouched);
    }
    System.debug(LoggingLevel.ERROR,
        'VERIFY: query Checklist_Fanned_Out__c, Tasks_Complete__c, Tasks_Overdue__c and '
        + 'Wire_Open_Risks__c on these deals. A NON-ZERO Wire_Open_Risks__c on a deal with open '
        + 'wire tasks is the signal that the legacy rollup ran; a zero there is the RISK 1 '
        + 'failure mode and means step 3 was skipped or the counter guard ate it.');
}
