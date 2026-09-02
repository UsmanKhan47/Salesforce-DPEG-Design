// ═══════════════════════════════════════════════════════════════════════════════════════════
// PHASE 4 — M1. Migrates live deals from the legacy `Task` checklist onto the
// `Checklist__c` / `Checklist_Item__c` model. ADDITIVE: the Task rows are NEVER touched.
//
//   sf apex run --file scripts/migrate-transaction-checklists.apex --target-org usman-dpeg
//
// 🔴 READ ALL FOUR PREREQUISITES BEFORE RUNNING. Three of them fail SILENTLY if unmet.
//
// 1. 🔴 SHARING. You must be a member of the `DPEG_Transactions_Team` public group, or hold
//    Modify All Data. `Checklist__c` is master-detail under `Transaction__c` with
//    `writeRequiresMasterRead=false` — the STRICTER setting — so creating one needs EDIT
//    sharing on the deal, and `AccessLevel.SYSTEM_MODE` does NOT lift sharing. Group
//    membership is not deployable, so this cannot be checked from the repo.
//    A deal you cannot see is reported as NOT_VISIBLE rather than skipped — that is the
//    guard, not a reason to skip this step.
// 2. 🔴 THE CMDT LOADERS MUST HAVE BEEN RUN, WITH THE PHASE 1 COLUMNS.
//    `Transaction_Task_Def__mdt` RECORDS are force-ignored and load only via
//    `scripts/load-transaction-task-defs.apex`. Without `Is_Wire_Verification__c` populated
//    every deal is REFUSED with `WIRE_ITEM_COUNT` — which is the guard working, not a bug.
// 3. ⚠ DO NOT GRANT YOURSELF `Transaction_Prereq_Override`. The migration does not need it:
//    it inserts every item with `Blocked_By__c` blank and stamps the links in a second pass,
//    and gaining a first link is not a "change" to the wire gate. Granting it would only
//    widen what you can do by accident. See `ChecklistMigrationService`'s header.
// 4. ⚠ RUN THE PILOT FIRST. Set PILOT_IDS below to three deals, run, then run
//    `scripts/reconcile-checklist-migration.apex` on those three before widening. The pilot
//    is the SAME code path as the full run.
//
// REVERSAL: `scripts/rollback-transaction-checklist-migration.apex`. Per deal, total, and the
// Task rows were never touched — so the legacy model is authoritative again the instant the
// flag clears.
// ═══════════════════════════════════════════════════════════════════════════════════════════

// 🔴 W5 — VERIFY THE ORG EDITION BEFORE RUNNING THIS AT SCOPE. CHAINED-QUEUEABLE DEPTH IS CAPPED
// AT 5 ON DEVELOPER AND **TRIAL** ORGS, and `usman-dpeg` is recorded in this project as a TRIAL
// EE org. If that cap applies, the chain dies after 5 links = 125 deals, and it dies QUIETLY:
// the enqueued jobs simply stop, every remaining deal keeps `Checklist_Fanned_Out__c = false`,
// and that is indistinguishable at a glance from deals the reconciliation gate REFUSED.
//   ⇒ Before a full run, confirm the edition, and either:
//      (a) page this script — set PILOT_IDS to at most ~100 deals at a time and re-run; or
//      (b) confirm the org is production EE, where chain depth is unlimited.
//   ⇒ Either way, AFTER the run compare the count of deals still at
//      `Checklist_Fanned_Out__c = false` against the count the reconciliation report says were
//      REFUSED. A gap between those two numbers is the chain having stopped, not a refusal.
// ⚠ The `LIMIT 5000` below is a scope bound, not a safety bound. It permits up to 200 chunks.
//
// ── SCOPE ───────────────────────────────────────────────────────────────────────────────
// Leave PILOT_IDS empty to migrate every eligible deal; populate it to migrate just those.
List<Id> PILOT_IDS = new List<Id>{
    // '0Q0xx0000000001AAA'
};

List<Id> targets = new List<Id>();
if (!PILOT_IDS.isEmpty()) {
    targets.addAll(PILOT_IDS);
} else {
    // Eligible = fanned out on the LEGACY model and not yet claimed by the checklist model.
    // Inline SOQL is correct in a script (the selector-only rule governs classes); rooting the
    // scope here rather than in a QueryLocator is also what keeps `TransactionSelector`
    // untouched while a concurrent workstream owns it.
    for (Transaction__c deal : [
        SELECT Id
        FROM Transaction__c
        WHERE Tasks_Fanned_Out__c = true
          AND Checklist_Fanned_Out__c = false
        ORDER BY CreatedDate
        LIMIT 5000
    ]) {
        targets.add(deal.Id);
    }
}

System.debug(LoggingLevel.ERROR, '== CHECKLIST MIGRATION M1 ==');
System.debug(LoggingLevel.ERROR, 'deals in scope : ' + targets.size());

if (targets.isEmpty()) {
    System.debug(LoggingLevel.ERROR,
        'NOTHING IN SCOPE. Either every deal is already migrated, or none was ever fanned out '
        + 'on the Task model, or you cannot SEE them (check DPEG_Transactions_Team membership). '
        + 'These three are not the same thing - query Transaction__c yourself before assuming '
        + 'the first.');
} else {
    // ONE enqueue. The chain advances from the Finalizer, 25 deals per chunk, so a chunk that
    // fails does not strand the chunks behind it.
    Id jobId = System.enqueueJob(new ChecklistMigrationQueueable(targets, 0));
    System.debug(LoggingLevel.ERROR, 'enqueued job  : ' + jobId);
    System.debug(LoggingLevel.ERROR,
        'chunks        : ' + Math.ceil(Decimal.valueOf(targets.size()) / 25).intValue()
        + ' (25 deals each)');
    System.debug(LoggingLevel.ERROR,
        'NEXT: watch AsyncApexJob, then run scripts/reconcile-checklist-migration.apex. '
        + 'A deal that did NOT flip Checklist_Fanned_Out__c was REFUSED by the reconciliation '
        + 'gate - that is the mechanism, not a failure, and the audit report says why.');
}
