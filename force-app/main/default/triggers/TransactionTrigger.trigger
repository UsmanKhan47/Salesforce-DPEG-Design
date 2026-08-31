/**
 * One trigger per object, one line, delegating to a handler that extends `TriggerHandler`
 * (ARCHITECTURE.md §2, .claude/rules/apex-layering-rule.md). All logic lives in
 * `TransactionTriggerHandler`.
 *
 * 🔴 THE FIRST TRIGGER ON THIS OBJECT. `Transaction__c` sits in the middle of the Day-0 chain and is
 * updated several times per deal creation by the fan-out and the rollups. Read
 * `TransactionTriggerHandler`'s header before adding a context here: the cost control is that every
 * arm is gated on a real field change, and an ungated arm would fire on every rollup write.
 * ⚠ `after insert` is declared but NOT overridden, deliberately - see that header for why
 * `CriticalDateService` must not run at insert while design GATE-B3 is open.
 */
trigger TransactionTrigger on Transaction__c (
    before insert, before update,
    after insert, after update
) {
    new TransactionTriggerHandler().run();
}
