/**
 * One trigger per object, one line, delegating to a handler that extends `TriggerHandler`
 * (ARCHITECTURE.md §2, .claude/rules/apex-layering-rule.md). All logic lives in
 * `TransactionTriggerHandler`.
 *
 * 🔴 THE FIRST TRIGGER ON THIS OBJECT. `Transaction__c` sits in the middle of the Day-0 chain and is
 * updated several times per deal creation by the fan-out and the rollups. Read
 * `TransactionTriggerHandler`'s header before adding a context here: the cost control is that every
 * arm is gated on a real field change, and an ungated arm would fire on every rollup write.
 * ⚠ RETRACTED 2026-09-02 — this file used to say "`after insert` is declared but NOT overridden,
 * deliberately". THE DECLARATION IS NO LONGER IDLE: `after insert` now routes
 * `DealTransactionGateService`, which maintains the two Opportunity flags the deal-close gate
 * reads. What is still true, and is what that sentence was really protecting, is that
 * `CriticalDateService` must NOT run at insert while design GATE-B3 is open — read
 * `TransactionTriggerHandler`'s header for the full condition set.
 *
 * 🔴 `after delete` AND `after undelete` WERE ADDED 2026-09-02 AND THEY ARE NOT OPTIONAL. A
 * deleted Transaction that left its parent's flags behind would leave that deal either
 * permanently blocked from closing or permanently able to close with no transaction at all —
 * both are the defect the gate exists to prevent, and only the AFTER contexts can see the
 * database as it will actually be (a `before delete` recount still includes the row that is
 * about to vanish).
 */
trigger TransactionTrigger on Transaction__c (
    before insert, before update,
    after insert, after update,
    after delete, after undelete
) {
    new TransactionTriggerHandler().run();
}
