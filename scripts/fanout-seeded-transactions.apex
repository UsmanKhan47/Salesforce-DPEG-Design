// Fan out the full PDF checklist across the 5 seeded Active transactions.
// Idempotent: clears any prior fanned-out tasks first. Sets Loan Required = true so the
// conditional Financing group is included (full 82 tasks per deal).
//
// ── EXACTLY-ONE-FAN-OUT (fixed 2026-08-29) ────────────────────────────────────────────
// Two defects were fixed here.
//
// 1. `TaskFanoutService.fanOut(ids)` DID NOT COMPILE. `fanOut` is the @InvocableMethod and
//    takes `List<TaskFanoutService.InputDTO>`, not `List<Id>` — and it only ENQUEUES a
//    TaskFanoutQueueable, it does not create anything inline. The synchronous worker that
//    actually writes the Tasks is `TaskFanoutService.fanOutNow(List<Id>)`
//    (classes/TaskFanoutService.cls:62), which is what this script wants: the rows exist the
//    moment the script returns, so a demo presenter can verify them immediately instead of
//    waiting on an async chain.
//
// 2. The `Tasks_Fanned_Out__c = false` reset below RE-ARMS the ACTIVE record-triggered flow
//    `Transaction_Task_Fanout` (Contract_Executed_Date__c != null AND Tasks_Fanned_Out__c =
//    false, RecordAfterSave, CreateAndUpdate). That flow calls TaskFanoutService.fanOut, which
//    enqueues a TaskFanoutQueueable — so the update below and the fanOutNow call below are two
//    potential fan-out paths in one script.
//
//    The reset is NOT removable: `fanOutNow` skips any Transaction whose Tasks_Fanned_Out__c is
//    already true (its dedupe guard), so without the reset this script would create nothing. And
//    the flow cannot be dodged: any DML that sets the flag false necessarily satisfies its entry
//    criteria. So the two paths are sequenced instead, and the ordering makes it deterministic:
//
//      a. `update ups` sets the flag false -> the flow fires and ENQUEUES a queueable. A
//         Queueable NEVER executes before its enqueuing transaction commits, so it has not run.
//      b. `fanOutNow(ids)` runs SYNCHRONOUSLY, creates the 82 Tasks per deal, and writes
//         Tasks_Fanned_Out__c = true — still inside this same, uncommitted transaction.
//      c. This transaction commits. Only now does the queueable dequeue, re-read the
//         Transactions, see Tasks_Fanned_Out__c = true, and skip every one of them.
//
//    Net: exactly one fan-out, performed by step (b). Step (a)'s queueable is a no-op by
//    construction, not by luck.
//
//    ⚠ IF YOU EVER REMOVE OR REORDER THE fanOutNow CALL, the flow's queueable becomes the only
//    fan-out and this stays correct — but if you remove the flag reset instead, NOTHING fans
//    out. Do not "simplify" this by deleting either half without re-reading
//    force-app/main/default/flows/Transaction_Task_Fanout.flow-meta.xml.
// ──────────────────────────────────────────────────────────────────────────────────────
List<Id> ids = new List<Id>();
for (Transaction__c t : [SELECT Id FROM Transaction__c WHERE Status__c = 'Active']) {
    ids.add(t.Id);
}
delete [SELECT Id FROM Task WHERE WhatId IN :ids OR Transaction_Deal__c IN :ids];

List<Transaction__c> ups = new List<Transaction__c>();
for (Id i : ids) {
    ups.add(new Transaction__c(Id = i, Loan_Required__c = true, Tasks_Fanned_Out__c = false));
}
update ups;   // (a) re-arms Transaction_Task_Fanout; its queueable cannot run until commit

TaskFanoutService.fanOutNow(ids);   // (b) the ONE real fan-out — synchronous, flags each row done
System.debug('FANOUT done for ' + ids.size() + ' transactions');
