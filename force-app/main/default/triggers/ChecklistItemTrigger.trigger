/**
 * One trigger per object, one line, delegating to a handler that extends `TriggerHandler`
 * (ARCHITECTURE.md §2, .claude/rules/apex-layering-rule.md). All logic lives in
 * `ChecklistItemTriggerHandler`.
 *
 * All seven contexts are declared even though the handler overrides six: the base class dispatches
 * on `Trigger.operationType` and inherits a safe no-op for any context a future change does not
 * need, so adding one later is a handler edit rather than a trigger edit.
 */
trigger ChecklistItemTrigger on Checklist_Item__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new ChecklistItemTriggerHandler().run();
}
