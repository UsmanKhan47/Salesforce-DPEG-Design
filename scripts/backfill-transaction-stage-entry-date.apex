// ═══════════════════════════════════════════════════════════════════════════════════════════
// BACKFILL - Transaction__c.Stage_Entry_Date__c on OPEN deals that have none.
// Design: agent-output/design-transaction-fsd-gaps.md §2.11, §5.4. Modelled on
// scripts/backfill-opp-stage-entry-date.apex, which does the identical job on Opportunity.
//
// Run ONCE, immediately after TransactionStageEntryService goes live. From that moment the
// before-trigger stamps every genuine stage transition, so the only deals that can still have a
// null date are ones that have not been saved since the deploy. Re-running is harmless (the WHERE
// clause excludes anything already stamped), but it is not a recurring job.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 WHAT THIS WRITES IS AN APPROXIMATION, NOT HISTORY. DO NOT PRESENT IT AS HISTORY.
// ═══════════════════════════════════════════════════════════════════════════════════════════
// It writes `LastModifiedDate.date()`. `LastModifiedDate` is the last edit of ANY KIND - a counter
// rollup from the fan-out, an owner reassignment, a seed script, this backfill's own siblings. It is
// NOT the date the deal entered its current stage, and there is no field anywhere in this org that
// records that for a pre-existing row. Field history is not a usable substitute either.
//
// ⚠ TRANSACTIONS ARE ESPECIALLY EXPOSED TO THIS, MORE SO THAN OPPORTUNITIES. Every checklist Task
// completion rolls up to the deal via TaskRollupService, which UPDATES the Transaction - so
// `LastModifiedDate` on an active deal is usually "the last time anybody ticked anything", which can
// be days after the stage actually moved. The consequence, stated plainly: on day 1 a backfilled
// days-in-stage figure UNDERSTATES how long the deal has really been in stage, sometimes badly. That
// is accepted, it is a false silence rather than a false alarm, and it self-corrects the first time
// each deal genuinely changes stage.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 🔴 PRECONDITIONS. THIS SCRIPT CANNOT SATISFY THEM ITSELF - CHECK BOTH BEFORE RUNNING.
// ═══════════════════════════════════════════════════════════════════════════════════════════
// 1. SYSTEM_MODE IS NOT AVAILABLE HERE, AND THE REFUSAL IS RECORDED RATHER THAN QUIETLY WORKED
//    AROUND:  "Cannot use SYSTEM_MODE access level in anonymous execution of Apex"  - it applies to
//    `WITH SYSTEM_MODE` in static SOQL AND to `AccessLevel.SYSTEM_MODE` in Database.query / .update,
//    and there is no `without sharing` in anonymous Apex either. So this runs in the RUNNER'S OWN
//    context and both enforcement layers are live:
//      FLS      - `Stage_Entry_Date__c` is a Metadata-API-deployed field and arrives with ZERO
//                 FieldPermissions rows for anyone, System Administrator included. Until the
//                 permission pass grants it, the UPDATE below fails with
//                 `fields being inaccessible`. THAT IS THE PERMISSION PASS'S JOB, NOT THIS FILE'S.
//                 (Note the asymmetry with the trigger: a before-context assignment is an in-memory
//                 mutation and is NOT FLS-checked, which is why the SERVICE needs no grant and this
//                 SCRIPT does. The difference is who put the field in the DML payload.)
//      SHARING  - Transaction__c is OWD Private. The runner sees only deals they own or are shared
//                 into. Run as an administrator with View All / Modify All, and READ THE COUNTS
//                 BELOW: "scanned" vs "org total" is what exposes a sharing-truncated run.
// 2. THE TRIGGER MUST ALREADY BE DEPLOYED. Running this first would stamp the rows and then leave
//    every subsequent transition unstamped, which looks like success and is not.
//
// ⚠ THIS UPDATE FIRES `TransactionTrigger`. The before-context stamp sees no stage change (this
// script writes only the date) and leaves the value alone, and the after-update arm is gated on a
// stage or pinned-date change so `CriticalDateService` and the reconcile are NOT entered. Cost per
// 200-row chunk is therefore zero queries beyond this script's own.
// ═══════════════════════════════════════════════════════════════════════════════════════════

List<Transaction__c> toStamp = new List<Transaction__c>();
List<String> samples = new List<String>();

for (Transaction__c deal : [
    SELECT Id, Name, Stage__c, Status__c, LastModifiedDate
    FROM Transaction__c
    WHERE Stage_Entry_Date__c = NULL
      AND Status__c != 'Closed'
    ORDER BY Name
]) {
    toStamp.add(new Transaction__c(
        Id = deal.Id,
        Stage_Entry_Date__c = deal.LastModifiedDate.date()
    ));
    if (samples.size() < 10) {
        samples.add(deal.Name + ' | ' + deal.Stage__c + ' | -> ' + deal.LastModifiedDate.date());
    }
}

Integer stamped = 0;
List<String> failures = new List<String>();
if (!toStamp.isEmpty()) {
    // allOrNone = false: one deal blocked by an unrelated validation rule must not discard the rest.
    // Every failure is printed, so a partial result is never silent.
    Database.SaveResult[] results = Database.update(toStamp, false);
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            stamped++;
        } else {
            String message = '';
            for (Database.Error e : results[i].getErrors()) {
                message += e.getStatusCode() + ': ' + e.getMessage() + ' ' + e.getFields() + ' ';
            }
            failures.add(toStamp[i].Id + '  ==> ' + message);
        }
    }
}

Integer orgTotal = [SELECT COUNT() FROM Transaction__c];
Integer stillNull = [SELECT COUNT() FROM Transaction__c
    WHERE Stage_Entry_Date__c = NULL AND Status__c != 'Closed'];

System.debug(LoggingLevel.ERROR, '════ TXN STAGE-ENTRY BACKFILL ═══════════════════════════════');
System.debug(LoggingLevel.ERROR, 'TXNSED candidates (open, unstamped, VISIBLE TO ME) :: ' + toStamp.size());
System.debug(LoggingLevel.ERROR, 'TXNSED STAMPED                                    :: ' + stamped);
System.debug(LoggingLevel.ERROR, 'TXNSED still null after this run                  :: ' + stillNull);
System.debug(LoggingLevel.ERROR, 'TXNSED Transactions VISIBLE to me org-wide        :: ' + orgTotal);
System.debug(LoggingLevel.ERROR, 'TXNSED ⚠ if that last number looks low, this run was SHARING-TRUNCATED '
    + 'and the deals you cannot see are still unstamped. Re-run as an admin with View All.');
if (!failures.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'TXNSED 🔴 FAILURES (' + failures.size() + '):');
    for (String failure : failures) {
        System.debug(LoggingLevel.ERROR, 'TXNSED   FAIL ' + failure);
    }
    System.debug(LoggingLevel.ERROR, 'TXNSED ⚠ `fields being inaccessible` here means the permission '
        + 'pass has not granted Stage_Entry_Date__c yet. Fix that, then re-run.');
}
for (String sample : samples) {
    System.debug(LoggingLevel.ERROR, 'TXNSED   sample ' + sample);
}
System.debug(LoggingLevel.ERROR, '════ TXN STAGE-ENTRY BACKFILL END ═══════════════════════════');
